#!/bin/bash
# Fetch LibriSpeech test-clean (~346MB) from OpenSLR into datasets/.
# 2620 utterances, ~5.4 hours, human-verified transcripts — the standard
# clean-speech ASR benchmark, and the eval set for mimi-eval.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=datasets
URL=https://www.openslr.org/resources/12/test-clean.tar.gz

if [ -d "$DEST/LibriSpeech/test-clean" ]; then
  echo "already present: $DEST/LibriSpeech/test-clean"
  exit 0
fi

mkdir -p "$DEST"
echo "downloading test-clean (~346MB)..."
curl -L --progress-bar -o "$DEST/test-clean.tar.gz" "$URL"
echo "extracting..."
tar -xzf "$DEST/test-clean.tar.gz" -C "$DEST"
rm "$DEST/test-clean.tar.gz"
echo "done: $DEST/LibriSpeech/test-clean"
echo "run: swift run -c release mimi-eval $DEST/LibriSpeech/test-clean --limit 100"
