# Streaming Parakeet — plan of record

*Written 2026-08-11. The next major arc after Stage 6's field fixes: make
Parakeet the engine that streams, not the engine that batches after the fact.*

---

## Why

Today's shape (`AppDelegate.endRecording`): Apple's SpeechTranscriber paints the
live preview, and Parakeet decodes the whole utterance **after key release**.
Three problems, one root cause:

1. **Release-to-paste scales with dictation length.** Field-measured worst case
   0.50× RTF under load — a 59s dictation meant ~30s of "Transcribing…". The
   press release's fourth principle ("release the key, text is there") fails
   exactly on long dictations.
2. **The preview lies.** The overlay shows Apple's words; Parakeet's words get
   pasted. They can disagree.
3. **The claim is soft.** The press release says *streaming speech model*, and
   the roadmap kept Whisper out for being chunk-based. Parakeet-in-Mimi is
   currently chunk-based. Open question #2 (can TDT decode hit streaming
   latency in Swift?) is still open.

Streaming fixes all three: encode and decode **during** speech, so release-time
work is ~one tick's worth regardless of length; the preview comes from the
model that writes the final text; and the claim becomes measurable
(first-partial latency joins the harness).

**What this does not buy: accuracy.** Same model, same weights. The streaming
approximation can only cost WER, never help it. The whole plan is structured to
measure that cost before building anything user-facing — principle 2.

---

## The mechanism

No new model, no cache-aware re-export. The trick is that the encoder is fast
enough to brute-force:

- **Tick loop (~1s cadence).** Each tick: mel the audio so far (vDSP over even
  60s of audio is milliseconds — recompute, don't do incremental mel),
  re-encode into the always-warm W3001 window (~70ms on the ANE), decode, emit
  a partial. Total tick cost is well under the tick interval.
- **Commit policy.** The conformer is full-context: encoder outputs for *old*
  frames shift as new audio arrives, so text near the frontier is provisional.
  Commit a token only when two consecutive ticks agree on it
  (LocalAgreement-2), and keep the disagreeing tail as the volatile preview.
  Committed text never retracts — same contract the overlay already renders as
  `(committed, volatile)`.
- **Decoder frontier snapshot.** Re-decoding from frame 0 each tick is
  quadratic in utterance length. Instead, snapshot the LSTM `h`/`c` and frame
  index at the committed frontier; each tick re-decodes only the volatile
  region from the snapshot. (Copy the arrays — `MLMultiArray` state is mutated
  in place by the decode loop.)
- **Release = final tick.** At key release, run one last tick over the complete
  audio, decode from the frontier, join committed + tail, paste. The audio the
  final decode sees is identical to what batch would have seen, so *final*
  accuracy is unaffected by the preview's commit policy — only the frontier
  snapshot approximation (frozen encoder context at seams) can differ, and S0
  measures exactly that.
- **The >29.4s seam.** One window means utterances longer than ~29s still need
  a cut. Streaming improves on batch's blind cut: place the seam at the
  lowest-energy hop in the last committed second, reset the mel origin there,
  prime the decoder with the running token state. (Stage 6 VAD will do this
  properly; energy-based is the interim.)

Known gotchas that carry straight over: sync `prediction` only (async overload
returns wrong results on macOS 26), zero the LSTM state explicitly,
`autoreleasepool` **per tick** now, not per utterance (E5 buffer exhaustion),
`Task.checkCancellation` inside the frame loop.

---

## Stages

Ordering principle: **retire the accuracy risk first, on the harness, before
touching the app.** If LocalAgreement + frontier snapshots cost real WER, we
find out in stage S0 for the price of a script, not in stage S2 for the price
of the product.

### S0 — The streaming simulation ⏳

Prove the commit policy is cheap before building it for real. A `mimi-eval`
mode (`--streaming-sim`) that replays each eval file through the tick loop
offline — feed 1s of samples, tick, repeat — using the *existing* batch
`transcribe` internals rearranged, no new session API yet.

- [ ] Tick-loop harness mode: per-tick re-encode + full re-decode (quadratic is
      fine for a simulation), LocalAgreement-2 commit
- [ ] Score three variants on LibriSpeech test-clean: batch (control, must
      reproduce 1.92%), streaming-sim with frontier snapshot, streaming-sim
      committing everything each tick (the reckless bound)
- [ ] Report per-utterance: WER delta vs batch, mean/p95 token commit lag
      (audio-time between a word being spoken and it committing), simulated
      first-partial latency
- [ ] Tick-cost profile on the 8GB machine: encoder ms + decode ms per tick at
      10s/20s/29s of accumulated audio — the number that sets the real cadence

**Gate:** streaming-sim WER within **0.1% absolute** of 1.92% batch. Pass →
S1. Fail → widen the commit margin (LocalAgreement-3, or trail by N frames)
and re-measure; the knob trades preview lag, not final accuracy. If no margin
setting passes, stop and reassess here — that's the cache-aware-model signal,
and it will have cost a week, not the project.

**Done when:** one command prints the streaming-vs-batch WER table and the
commit-lag distribution.

### S1 — `StreamingSession` in EvalKit

The real API, shaped by S0's numbers. Lives beside the batch path;
`EvalEngine.transcribe` stays untouched (the harness still scores batch).

- [ ] `ParakeetEngine.makeStreamingSession()` → `feed(samples:)`,
      `onPartial: (committed, volatile) -> Void`, `finish() -> String`
- [ ] Tick scheduler owned by the session (cadence from S0's tick-cost profile;
      adaptive — skip a tick if the previous one is still running, the 0.50×
      under-load case)
- [ ] Frontier snapshot: committed token ids + `h`/`c` copies + mel frame index
- [ ] Long-utterance seam: energy-based cut in the last committed second, mel
      origin reset (replaces batch's blind 29.4s chunking *on this path*)
- [ ] `finish()`: final tick, join, return — target <500ms after last sample
      for any utterance length
- [ ] Unit tests in `MimiTests`: commit monotonicity (committed text never
      retracts), seam continuity (no dropped/duplicated word across a forced
      seam), snapshot equivalence (decode-from-snapshot == decode-from-zero on
      identical audio)

**Done when:** `mimi-eval --streaming` (real session, not the sim) reproduces
S0's numbers, and first-partial + finish-latency join the report as columns.

### S2 — The app speaks Parakeet

Swap the preview's producer. Apple stays wired, demoted from co-equal racer to
fallback.

- [ ] `AppDelegate` feeds `AudioCapture` samples to a `StreamingSession`;
      overlay partials come from Parakeet (`(committed, volatile)` — the
      overlay contract is unchanged)
- [ ] Apple's session still runs concurrently but only its *final* text is
      kept, as the fallback for an empty/failed Parakeet stream — the existing
      race logic in `endRecording` survives, its inputs change
- [ ] Release path: `finish()` replaces the batch decode; the
      decode-deadline machinery (`max(10, audioSeconds)`) becomes a fixed short
      deadline on `finish()`
- [ ] Log entry gains: `firstPartialMs`, `releaseToPasteMs`, `tickCount`,
      `skippedTicks`, commit-lag p95 — the field evidence for S4's decision
- [ ] Watchdog: a stream that stops emitting partials mid-dictation must fall
      back to Apple at release, not paste a truncated committed prefix.
      A partial-emitting session that dies is now possible in a way batch
      never was.

**Done when:** dictations in `transcripts.jsonl` shows
Parakeet-sourced previews and `releaseToPasteMs` flat across dictation length.

### S3 — The harness receipts

Close the loop on the claims. Small, mostly bookkeeping — but it's what makes
the work publishable (Stage 7 inherits this).

- [ ] First-partial latency and finish latency: report columns for both
      engines (the Stage 3 leftover, finally unblocked — Apple's streaming
      interface gets wrapped for the same metrics)
- [ ] Streaming WER re-run recorded beside 1.92% in the ROADMAP milestone log
- [ ] ROADMAP updated: open question #2 answered with numbers; Stage 3's
      latency checkbox closed; this file's results folded into the Stage 7
      matrix plan

**Done when:** every clause of "streams partials at Xms, finishes in Yms,
at Z% WER" carries a measured number and a command that reproduces it.

### S4 — Demote Apple (decision, not code)

Gated on S2's field log, decided by principle 3 — the harness (and the field
data) decides, not enthusiasm.

- [ ] Criteria to demote Apple to opt-in: ≥1 week of field data, Parakeet
      fallback rate <2%, no watchdog fallbacks caused by Parakeet itself,
      `releaseToPasteMs` p95 under 700ms
- [ ] If demoted: Apple session becomes lazy — created only when Parakeet is
      unavailable. Wins: no Apple spin-up contention at keypress (the
      2026-08-11 hang class), less RAM on the 8GB machine, one flaky
      dependency out of the critical path
- [ ] If the criteria fail: Apple stays, and the field log says why. That
      result is also shippable — it's a benchmark finding.

---

## Risks, ranked

1. **Commit-policy WER cost** — the load-bearing unknown. Bounded in S0, week
   one, before any product code. Mitigation knob: commit margin. Escalation
   path (only with S0 data proving the need): NVIDIA's cache-aware streaming
   FastConformer — a re-run of Stages 4–5, deliberately not the plan.
2. **Tick starvation under load.** The 0.50×-RTF machine state means a tick can
   overrun its interval. Design answer: adaptive cadence (skip, never queue),
   and `finish()` degrades toward batch — slower paste, never wrong text.
3. **Per-tick E5/IOSurface churn.** 60× more Core ML calls per dictation than
   batch. `autoreleasepool` per tick from day one; watch RSS in the S2 field
   log.
4. **Seam quality.** Energy-based cuts are crude; a word straddling a seam can
   still duplicate. Accepted for this arc (rare: >29s utterances only);
   Stage 6 VAD owns the real fix.

## Non-goals of this arc

- No cache-aware model conversion (see risk 1 — data first).
- No ring buffer / VAD (Stage 6 proper) — the session consumes samples the
  same way either way; Stage 6 lands before or after without rework.
- No dropping Apple in code until S4's criteria say so.
- No streaming *insertion* into the target app — the overlay remains the
  preview surface (wishlist, unchanged).
