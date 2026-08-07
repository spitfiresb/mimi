"""Parity: the Core ML export + our TDT decode loop vs NeMo's own pipeline.

    .venv/bin/python parity.py ../../datasets/LibriSpeech/test-clean --limit 20 [--int8]

For each utterance: NeMo transcribes natively (PyTorch, its own decoder); the
Core ML models transcribe via tdt_decode.py, fed the *same* NeMo-computed mels
(the mel frontend is pinned separately once the Swift port exists). Exact-match
rate and per-utterance WER between the two hypotheses are the score. Gate:
>= 95% token agreement means the export and the loop are faithful.
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import soundfile as sf
import nemo.collections.asr as nemo_asr

sys.path.insert(0, str(Path(__file__).parent))
from tdt_decode import CoreMLParakeet


def load_utterances(root, limit):
    utts = []
    for trans in sorted(Path(root).rglob("*.trans.txt")):
        for line in trans.read_text().splitlines():
            uid, _, ref = line.partition(" ")
            flac = trans.parent / f"{uid}.flac"
            if flac.exists():
                utts.append((uid, flac, ref))
            if len(utts) >= limit:
                return utts
    return utts


def word_errors(a, b):
    a, b = a.lower().split(), b.lower().split()
    d = np.zeros((len(a) + 1, len(b) + 1), dtype=int)
    d[:, 0] = np.arange(len(a) + 1)
    d[0, :] = np.arange(len(b) + 1)
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1,
                          d[i - 1, j - 1] + (a[i - 1] != b[j - 1]))
    return d[len(a), len(b)], len(a)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--int8", action="store_true")
    args = parser.parse_args()

    model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v2")
    model.eval()
    coreml = CoreMLParakeet(suffix="-int8" if args.int8 else "")

    utts = load_utterances(args.dataset, args.limit)
    print(f"parity over {len(utts)} utterances ({'int8' if args.int8 else 'fp16'})\n")

    exact = 0
    total_err, total_words = 0, 0
    for uid, flac, _ in utts:
        audio, sr = sf.read(flac, dtype="float32")
        with torch.no_grad():
            reference = model.transcribe([str(flac)], verbose=False)[0].text
            mel, _ = model.preprocessor(
                input_signal=torch.tensor(audio).unsqueeze(0),
                length=torch.tensor([len(audio)]),
            )
        hypothesis = coreml.transcribe_mel(mel.numpy())

        err, words = word_errors(reference, hypothesis)
        total_err += err
        total_words += words
        if reference.strip().lower() == hypothesis.strip().lower():
            exact += 1
        else:
            print(f"  DIFF {uid}")
            print(f"    nemo:   {reference}")
            print(f"    coreml: {hypothesis}")

    agreement = 1 - (total_err / max(total_words, 1))
    print(f"\nexact match: {exact}/{len(utts)}")
    print(f"token agreement: {agreement:.2%}")
    if agreement < 0.95:
        print("FAIL: below the 95% gate")
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
