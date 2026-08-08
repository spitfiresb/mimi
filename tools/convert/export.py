"""Export Parakeet-TDT-0.6b-v2 to Core ML.

Three networks, exported separately because they run at different cadences:
the encoder once per audio window, the prediction network once per emitted
token, the joint once per (frame, token) pair. The mel preprocessor is NOT
exported -- torch.stft doesn't survive coremltools, so the Swift side computes
log-mels itself (vDSP), and parity.py pins the reference values it must match.

    .venv/bin/python export.py --precision fp16   # models/ParakeetEncoder.mlpackage etc.
    .venv/bin/python export.py --precision int8

Also writes models/parakeet-meta.json (vocab, durations, dims, mel config) and
models/tokens.txt (one SentencePiece piece per line, id-ordered) for the Swift
decoder.
"""

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import nemo.collections.asr as nemo_asr

OUT = Path(__file__).parent / "models"

# coremltools' torch _cast does `dtype(x.val)` on const-folded casts; with a
# fully static encoder shape the fold produces 1-element arrays, and
# numpy >= 1.25 raises on int(np.array([x])). Scalarize before casting.
from coremltools.converters.mil.frontend.torch import ops as _torch_ops

_orig_cast = _torch_ops._cast

def _cast_scalarize(context, node, dtype, dtype_name):
    inputs = _torch_ops._get_inputs(context, node, expected=1)
    x = inputs[0]
    if x.can_be_folded_to_const():
        val = np.asarray(x.val)
        if val.ndim > 0 and val.size == 1:
            res = _torch_ops.mb.const(val=dtype(val.item()), name=node.name)
            context.add(res, node.name)
            return
    _orig_cast(context, node, dtype, dtype_name)

_torch_ops._cast = _cast_scalarize


class EncoderWrapper(torch.nn.Module):
    """mel [1, 80, T] + length [1] -> encoded [1, T', D] (time-major for the
    decode loop's frame indexing)."""

    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, mel, length):
        encoded, encoded_len = self.encoder(audio_signal=mel, length=length)
        return encoded.transpose(1, 2), encoded_len


class EncoderNoLengthWrapper(torch.nn.Module):
    """mel [1, 80, T] -> encoded [1, T', D]. No int32 length input: the E5/ANE
    compiler dies on it ("Cannot retrieve vector from IRValue format int32",
    2026-08-07), so this variant derives length from the mel shape in-graph.
    The Swift side pads to an enumerated window, so length == T is what the
    engine passes today anyway; validity trimming stays in Swift."""

    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, mel):
        length = torch._shape_as_tensor(mel)[2].reshape(1).to(torch.int32)
        encoded, encoded_len = self.encoder(audio_signal=mel, length=length)
        return encoded.transpose(1, 2), encoded_len


class DecoderWrapper(torch.nn.Module):
    """One prediction-network step: token [1,1] + LSTM state -> out [1, D2] + new state."""

    def __init__(self, decoder):
        super().__init__()
        self.decoder = decoder

    def forward(self, token, h_in, c_in):
        emb = self.decoder.prediction["embed"](token)
        out, (h, c) = self.decoder.prediction["dec_rnn"].lstm(emb, (h_in, c_in))
        return out.squeeze(1), h, c


class JointWrapper(torch.nn.Module):
    """enc frame [1, D] + dec out [1, D2] -> logits [1, vocab+1+durations]."""

    def __init__(self, joint):
        super().__init__()
        self.joint = joint

    def forward(self, enc_frame, dec_out):
        f = self.joint.enc(enc_frame)
        g = self.joint.pred(dec_out)
        return self.joint.joint_net(f + g)


def convert(model, args):
    OUT.mkdir(exist_ok=True)
    cfg = model.cfg
    mel_dim = cfg.preprocessor.features
    pred_hidden = cfg.model_defaults.pred_hidden
    pred_layers = cfg.decoder.prednet.pred_rnn_layers
    durations = list(cfg.joint.get("tdt_durations", cfg.model_defaults.get("tdt_durations", [0, 1, 2, 3, 4])))
    vocab = model.tokenizer.vocab_size

    compute = {"fp16": ct.precision.FLOAT16, "int8": ct.precision.FLOAT16}[args.precision]
    suffix = "" if args.precision == "fp16" else "-int8"

    # --- encoder: enumerated time axis ---
    # Three fixed windows (3s / 15s / 30s), matching ParakeetEngine.windows.
    # A RangeDim axis produces an E5 program with no FlexibleShapeInformation:
    # the ANE can't run it (BNNS crashes outright on .cpuOnly / .cpuAndNeuralEngine)
    # and every previously unseen shape pays a 40-90s runtime re-specialization.
    # Enumerated shapes are precompiled per-variant and ANE-eligible.
    T = 1501  # 15s of 10ms mel frames as the trace example
    mel = torch.randn(1, mel_dim, T)
    length = torch.tensor([T], dtype=torch.int32)
    enc_shapes = ct.EnumeratedShapes(
        shapes=[(1, mel_dim, t) for t in (301, 1501, 3001)], default=(1, mel_dim, T)
    )
    if args.window:
        # Single fixed shape, matching FluidInference's working ANE recipe —
        # their Parakeet encoder ships one fixed 15s window, no EnumeratedShapes.
        # (EnumeratedShapes and RangeDim both crash the E5/ANE compiler in BNNS.)
        # Combine with --no-length to derive length in-graph instead of masking.
        mel_w = torch.randn(1, mel_dim, args.window)
        if args.no_length:
            enc = EncoderNoLengthWrapper(model.encoder).eval()
            traced = torch.jit.trace(enc, (mel_w,))
            enc_inputs = [ct.TensorType(name="mel", shape=(1, mel_dim, args.window), dtype=np.float32)]
            enc_name = f"ParakeetEncoderW{args.window}NL"
        else:
            enc = EncoderWrapper(model.encoder).eval()
            traced = torch.jit.trace(enc, (mel_w, torch.tensor([args.window], dtype=torch.int32)))
            enc_inputs = [
                ct.TensorType(name="mel", shape=(1, mel_dim, args.window), dtype=np.float32),
                ct.TensorType(name="length", shape=(1,), dtype=np.int32),
            ]
            enc_name = f"ParakeetEncoderW{args.window}"
    elif args.no_length:
        enc = EncoderNoLengthWrapper(model.encoder).eval()
        traced = torch.jit.trace(enc, (mel,))
        enc_inputs = [ct.TensorType(name="mel", shape=enc_shapes, dtype=np.float32)]
        enc_name = "ParakeetEncoderNL"
    else:
        enc = EncoderWrapper(model.encoder).eval()
        traced = torch.jit.trace(enc, (mel, length))
        enc_inputs = [
            ct.TensorType(name="mel", shape=enc_shapes, dtype=np.float32),
            ct.TensorType(name="length", shape=(1,), dtype=np.int32),
        ]
        enc_name = "ParakeetEncoder"
    mlmodel = ct.convert(
        traced,
        inputs=enc_inputs,
        outputs=[ct.TensorType(name="encoded"), ct.TensorType(name="encoded_len")],
        compute_precision=compute,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
        minimum_deployment_target=ct.target.macOS15,
    )
    if args.precision == "int8":
        mlmodel = quantize_int8(mlmodel)
    mlmodel.save(str(OUT / f"{enc_name}{suffix}.mlpackage"))
    print("encoder saved")
    if args.only == "encoder":
        return

    # --- decoder step ---
    dec = DecoderWrapper(model.decoder).eval()
    token = torch.zeros(1, 1, dtype=torch.int64)
    h = torch.zeros(pred_layers, 1, pred_hidden)
    c = torch.zeros(pred_layers, 1, pred_hidden)
    traced = torch.jit.trace(dec, (token, h, c))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="token", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="h_in", shape=h.shape, dtype=np.float32),
            ct.TensorType(name="c_in", shape=c.shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="dec_out"), ct.TensorType(name="h_out"), ct.TensorType(name="c_out")],
        compute_precision=compute,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
        minimum_deployment_target=ct.target.macOS15,
    )
    if args.precision == "int8":
        mlmodel = quantize_int8(mlmodel)
    mlmodel.save(str(OUT / f"ParakeetDecoder{suffix}.mlpackage"))
    print("decoder saved")

    # --- joint ---
    with torch.no_grad():
        d_model = model.encoder(audio_signal=mel, length=length)[0].shape[1]
    joint = JointWrapper(model.joint).eval()
    ef = torch.randn(1, d_model)
    do = torch.randn(1, pred_hidden)
    traced = torch.jit.trace(joint, (ef, do))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="enc_frame", shape=(1, d_model), dtype=np.float32),
            ct.TensorType(name="dec_out", shape=(1, pred_hidden), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits")],
        compute_precision=compute,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
        minimum_deployment_target=ct.target.macOS15,
    )
    if args.precision == "int8":
        mlmodel = quantize_int8(mlmodel)
    mlmodel.save(str(OUT / f"ParakeetJoint{suffix}.mlpackage"))
    print("joint saved")

    # --- metadata + tokens for the Swift decoder ---
    meta = {
        "vocab_size": vocab,
        "blank_id": vocab,  # NeMo convention: blank is the last token logit
        "durations": durations,
        "mel_dim": mel_dim,
        "pred_hidden": pred_hidden,
        "pred_layers": pred_layers,
        "d_model": d_model,
        "sample_rate": cfg.preprocessor.sample_rate,
        "window_size": cfg.preprocessor.window_size,
        "window_stride": cfg.preprocessor.window_stride,
        "n_fft": cfg.preprocessor.n_fft,
        "encoder_subsampling": 8,
        "precision": args.precision,
    }
    (OUT / "parakeet-meta.json").write_text(json.dumps(meta, indent=2))
    with open(OUT / "tokens.txt", "w") as f:
        for i in range(vocab):
            f.write(model.tokenizer.ids_to_tokens([i])[0] + "\n")
    print("meta + tokens saved")


def quantize_int8(mlmodel):
    """Linear per-channel int8 weight quantization. Weights only -- activations
    stay fp16, which is the standard deploy recipe and what 'int8' claims."""
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )
    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
    )
    return linear_quantize_weights(mlmodel, config)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--precision", choices=["fp16", "int8"], default="fp16")
    parser.add_argument("--only", choices=["encoder", "all"], default="all")
    parser.add_argument("--no-length", action="store_true",
                        help="export the encoder without the int32 length input (ANE experiment)")
    parser.add_argument("--window", type=int, default=None,
                        help="export the encoder with a single fixed mel-frame window (ANE experiment)")
    args = parser.parse_args()

    model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v2")
    model.eval()
    convert(model, args)
