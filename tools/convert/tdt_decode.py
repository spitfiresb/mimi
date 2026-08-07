"""Greedy TDT decode over the exported Core ML networks.

This is the reference implementation of the loop Swift will run: joint the
current encoder frame with the prediction-network state, emit the argmax token
if it isn't blank, and jump ahead by the predicted duration. Kept in Python so
parity.py can pin its output against NeMo's own decoder before the Swift port
exists -- if this loop is wrong, the parity test says so now, not in Stage 5.
"""

import json
from pathlib import Path

import numpy as np
import coremltools as ct

MODELS = Path(__file__).parent / "models"


class CoreMLParakeet:
    def __init__(self, suffix=""):
        self.meta = json.loads((MODELS / "parakeet-meta.json").read_text())
        self.tokens = (MODELS / "tokens.txt").read_text().splitlines()
        units = ct.ComputeUnit.ALL  # CPU_AND_NE hits a BNNS compile crash; Stage 5 audits ANE residency
        self.encoder = ct.models.MLModel(str(MODELS / f"ParakeetEncoder{suffix}.mlpackage"), compute_units=units)
        self.decoder = ct.models.MLModel(str(MODELS / f"ParakeetDecoder{suffix}.mlpackage"), compute_units=units)
        self.joint = ct.models.MLModel(str(MODELS / f"ParakeetJoint{suffix}.mlpackage"), compute_units=units)

    # The encoder ships with enumerated shapes (ANE-friendly; a flexible axis
    # crashed the BNNS compiler). Pad up to the smallest allowed window; the
    # length input masks the padding and encoded_len excludes it.
    WINDOWS = (301, 1501, 3001)

    def transcribe_mel(self, mel):
        """mel: np.float32 [1, 128, T] -> text"""
        meta = self.meta
        true_len = mel.shape[2]
        window = next((w for w in self.WINDOWS if w >= true_len), self.WINDOWS[-1])
        if true_len < window:
            mel = np.pad(mel, ((0, 0), (0, 0), (0, window - true_len)))
        elif true_len > window:
            mel = mel[:, :, :window]  # >30s: callers should chunk before this
            true_len = window
        enc = self.encoder.predict({
            "mel": mel.astype(np.float32),
            "length": np.array([true_len], dtype=np.int32),
        })
        encoded = enc["encoded"][0]          # [T', D]
        frames = int(enc["encoded_len"][0])

        blank = meta["blank_id"]
        durations = meta["durations"]
        h = np.zeros((meta["pred_layers"], 1, meta["pred_hidden"]), dtype=np.float32)
        c = np.zeros_like(h)
        # Prediction network starts from the blank/SOS step: NeMo primes with
        # blank, which the embedding table maps to the SOS row.
        dec = self.decoder.predict({
            "token": np.array([[blank]], dtype=np.int32), "h_in": h, "c_in": c,
        })
        dec_out, h, c = dec["dec_out"], dec["h_out"], dec["c_out"]

        ids = []
        t = 0
        emitted_at_t = 0
        MAX_SYMBOLS_PER_FRAME = 10
        while t < frames:
            logits = self.joint.predict({
                "enc_frame": encoded[t:t + 1].astype(np.float32),
                "dec_out": dec_out.astype(np.float32),
            })["logits"][0]
            token_logits = logits[: blank + 1]
            duration_logits = logits[blank + 1:]
            token = int(np.argmax(token_logits))
            jump = durations[int(np.argmax(duration_logits))]

            if token != blank:
                ids.append(token)
                dec = self.decoder.predict({
                    "token": np.array([[token]], dtype=np.int32), "h_in": h, "c_in": c,
                })
                dec_out, h, c = dec["dec_out"], dec["h_out"], dec["c_out"]
                emitted_at_t += 1
                if jump == 0 and emitted_at_t >= MAX_SYMBOLS_PER_FRAME:
                    jump = 1  # stuck-frame guard, mirrors NeMo's max_symbols
            else:
                jump = max(jump, 1)  # blank with duration 0 must still advance

            if jump > 0:
                t += jump
                emitted_at_t = 0

        return self.detokenize(ids)

    def detokenize(self, ids):
        text = "".join(self.tokens[i] for i in ids)
        return text.replace("▁", " ").strip()  # SentencePiece word marker
