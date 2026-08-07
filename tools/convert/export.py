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


class EncoderWrapper(torch.nn.Module):
    """mel [1, 80, T] + length [1] -> encoded [1, T', D] (time-major for the
    decode loop's frame indexing)."""

    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, mel, length):
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

    # --- encoder: flexible time axis ---
    enc = EncoderWrapper(model.encoder).eval()
    T = 1501  # 15s of 10ms mel frames as the trace example; RangeDim keeps it flexible
    mel = torch.randn(1, mel_dim, T)
    length = torch.tensor([T], dtype=torch.int32)
    traced = torch.jit.trace(enc, (mel, length))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mel", shape=(1, mel_dim, ct.RangeDim(1, 3001, default=T)), dtype=np.float32),
            ct.TensorType(name="length", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="encoded"), ct.TensorType(name="encoded_len")],
        compute_precision=compute,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
        minimum_deployment_target=ct.target.macOS15,
    )
    if args.precision == "int8":
        mlmodel = quantize_int8(mlmodel)
    mlmodel.save(str(OUT / f"ParakeetEncoder{suffix}.mlpackage"))
    print("encoder saved")

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
    args = parser.parse_args()

    model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v2")
    model.eval()
    convert(model, args)
