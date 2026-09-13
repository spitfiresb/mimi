# Mimi battery analysis — September 9, 2026

## Update — September 13, 2026

**The main identified idle issue, always-on microphone capture, is fixed.**
Capture now starts only on hotkey press and stops on release, before transcription
and formatting finish. There is no idle pre-roll/resampling or automatic start
after wake. A “Starting microphone…” / “Speak now” transition handles cold startup;
releasing early cancels, and stale starts/retries cannot reactivate idle capture.
Formatter sessions are also created lazily, and verbatim launch skips prewarming.

Validation: all 46 unit tests passed. The corrected live build logged seven
completed capture starts with seven matching stops, plus a canceled quick tap.
Readiness took 194–521 ms and shutdown took 8–24 ms after release. The user's
sleep/wake check produced no capture start until the next explicit press.
This was a short functional check, not a power or long-duration benchmark.

Battery consumption is **still open**, especially shared model/service costs,
long dictations, and cleanup requests that wait without improving output. Roughly
five monitored minutes contained 47 seconds of requested capture; that is reduced
microphone activity, not a percentage reduction in battery consumption. Nine
recent dictations accumulated about 13 seconds of formatting-stage waits with
no changed outputs; waiting time is not inference time or energy.

Track the remaining measurements in [ROADMAP.md — Battery follow-up](ROADMAP.md#battery-follow-up).
The September 9 audit below describes the earlier implementation; its always-hot
microphone and eager per-utterance formatter findings are superseded by this update.

## Original audit — September 9

Mimi has several credible opportunities to reduce energy consumption, especially while idle. The retained records do **not** support an exact historical wattage, battery percentage, or hours-of-battery-life estimate. Prioritize idle microphone policy, formatter work, and recovery behavior before optimizing the Parakeet model itself.

## Evidence and limits

- Machine inspected: Apple M2, 8 GB RAM, macOS 26.3. Mimi was not running during this audit.
- Local transcript log: `~/Library/Application Support/Mimi/transcripts.jsonl`; 230 entries, August 3–19, 2026, totaling 64.74 minutes in the logged `durationMs` field. Correction from September 13: this field includes processing time in the current implementation, so it must not be described as key-held or microphone-active time. It is not total app uptime or proof of complete session coverage. No transcript contents are reproduced here.
- Read-only inspection of `/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL` and all seven retained compressed archives found no Mimi matches in columns identifying bundles, processes, launchd jobs, or executables. The archives cover August 16–17, August 25–27, and September 2–8 in local time; current coalition data extends through September 9. The August 16 archive's coalition intervals end August 17 at 08:29 PDT, before that day's logged dictations. Archive coverage has substantial gaps.
- Extended-persistence and Xcode-organizer power databases supplied no Mimi-specific records. The August 1–24 unified-log query for `com.zainsaeed.mimi` returned no events; retained `pmset` history starts September 2. No Mimi diagnostic report was found in the current system/user diagnostic-report directories.
- The project explicitly records that a `powermetrics` capture was never taken (`RESUME.md:183`); the roadmap still marks it incomplete. ANE latency measurements are not power measurements.
- Audited the current working tree, including existing uncommitted audio-recovery edits. The bundled executable is dated August 13; exact correspondence between source revisions and every historical session is unverified. No application source or settings were changed, and Mimi was not launched.

Activity Monitor's Energy Impact is relative, and its “12 hr Power” is a recent average, not an August usage archive. See [Apple's explanation](https://support.apple.com/en-ie/guide/activity-monitor/actmntr43697/mac).

## Ranked opportunities

### 1. Reduce idle audio work — largest likely all-day opportunity

`AudioCapture.swift:480` converts and allocates a new audio buffer on every tap callback, even outside dictation. Idle buffers enter a rolling 0.5-second pre-roll. `stop()` ends the dictation stream but leaves the audio engine running. Bootstrap starts the microphone, and wake notifications request recovery immediately (`AppDelegate.swift:197`).

This keeps microphone I/O and conversion active throughout awake idle time. With a requested 4,096-frame buffer at the commonly logged 48 kHz rate, the nominal cadence is about 11.7 callbacks/second; this is a calculation, not a measured callback rate or CPU-wakeup count. Speech recognizers are not continuously transcribing idle audio.

Recommended experiment: keep the microphone warm briefly after a dictation, then suspend capture after inactivity; also suspend on lock/sleep and avoid restarting merely because the Mac woke. Use an explicit “Starting microphone” state on the first subsequent press. The existing code documents roughly one second of lost initial speech with cold, on-demand startup, so first-word capture and readiness feedback are acceptance criteria, not optional polish.

A smaller change that preserves immediate dictation: keep native-format pre-roll in preallocated storage and defer resampling until recording starts. This can remove idle conversion/allocation work, but leaves microphone hardware costs. Profile it before undertaking the larger change. Apple also documents an audio power-saving hint worth evaluating, without assuming a benefit on this machine: [TN2321](https://developer.apple.com/library/archive/technotes/tn2321/).

### 2. Avoid formatter setup and inference without useful output — strongest session-level evidence

Of 164 entries selecting Parakeet:

| Observation | Result |
|---|---:|
| Nonzero recorded formatting-stage duration | 157 |
| Final formatted text differed from raw text | 13 (7.9% of 164) |
| Formatting-stage duration at least 2.5 seconds | 90 |
| Median recorded formatting-stage duration | 2.551 seconds |
| Total recorded formatting-stage duration | 367.364 seconds |

The result persists after the early August 11 outliers: filtering timestamps at or after August 13 00:00 UTC gives 94 Parakeet sessions, 11 changed outputs, and 49 formatting-stage waits of at least 2.5 seconds.

These are wall-clock stage times, not inference durations or joules. A nonzero duration does not prove inference ran; unchanged output can mean no cleaning was needed, a model failure, rejected edits, a timeout, or identical text. The 2.5-second cluster is consistent with the current deadline but is not a logged timeout count.

Nevertheless, `FormatPipeline` eagerly creates/prewarms a model session before sentence-level `needsCleaning` routing (`Formatter.swift:179`). Bootstrap also prewarms the formatter regardless of verbatim mode. Move routing before session creation; lazily initialize only when a sentence needs cleanup, and skip bootstrap prewarming when formatting is disabled. Consider optional cleanup for Parakeet, which already emits punctuation and casing. Measure accepted edits per actual inference to refine routing without losing useful cleanup.

The formatting deadline bounds waiting, not necessarily computation. `abandoning()` does not cancel its job; `pipeline.cancel()` cooperates between sentences, but an in-flight model response may continue. Track actual completion after timeout and prevent overlapping abandoned formatter requests.

### 3. Bound failure recovery — protect against exceptional sustained drain

`AudioCapture.swift:238` documents an August 13 incident with Mimi at 31% CPU and `coreaudiod` at 65%, associated with a wake-time hang. This is a prior observation preserved in source, not a recovered measurement from this audit. Shared `coreaudiod` usage cannot be wholly attributed to Mimi from that observation.

The current source already moves revival off the main thread, coalesces requests, and uses exponential backoff. Those are useful reliability improvements. However, a stuck attempt cannot be cancelled, and recovery continues indefinitely on new threads, with delays capped at 60 seconds plus a 12-second watchdog. Roughly 50 more attempts per hour are possible if every attempt hangs. Blocked threads need not consume much CPU, but resource accumulation and repeated hardware setup remain risks.

Add a cap on unresolved attempts and a circuit breaker that waits for a meaningful device/wake/user event before retrying. Make it observable and test sleep/wake and route changes. Do not treat moving a hang off the main thread as proof its energy cost has disappeared.

### 4. Make the second recognizer optional — useful work with a real cost

Apple recognition provides live preview during recording; Parakeet processes the buffered audio after release (`AppDelegate.swift:323,416`). Apple text was retained in 160 of the 164 Parakeet-selected sessions. This confirms widespread dual recognition, which has user value as preview and fallback, but is not energy-free.

Compare current behavior with Parakeet-only recording plus Apple fallback on failure, and with Apple-only operation. Parakeet-only currently loses live preview, so this should be an explicit product choice or follow a validated preview replacement. Continuously rerunning Parakeet for streaming preview could also increase energy; fewer engines alone does not guarantee savings.

## Measurement corrections and next experiment

The transcript field `parakeetMs` is **not total Parakeet execution time**: its timer starts after waiting for Apple finalization while Parakeet has already been running concurrently. A zero can mean Parakeet finished during Apple's wait. Do not compare its median with `formatMs` to infer relative model efficiency.

Likewise, keeping the encoder loaded does not mean it is executing periodically. The current code loads one window and has no repeating encoder warmup timer. Existing compilation caching and the single-window strategy avoid previously documented reload churn; retain them until measurements justify a change.

Run a controlled before/after experiment on this Mac:

1. Alternate repeated 5–10-minute Mimi-quit and Mimi-idle blocks, holding display brightness and other workloads steady. Record whole-device discharge/power, Mimi and `coreaudiod` CPU/wakeups, and available CPU/GPU/ANE power counters. Exclude startup/model compilation from steady idle, then report startup separately.
2. Replay the same short/medium/long audio set through current dual recognition, each single-engine mode, and formatting enabled/disabled. Measure energy per audio minute, actual per-stage start/end times, quality, and release-to-paste latency. Replay avoids capturing new personal speech and makes runs comparable.
3. Verify lock/unlock, sleep/wake, input-route changes, long inactivity, and timeouts. Check that background work and recovery attempts return to a bounded idle state.

Subtract the matched baseline and integrate excess power over time to estimate incremental energy. Shared-service power and background system activity require repeated trials; whole-device battery decline is not by itself Mimi attribution. Exact savings remain unmeasured until this experiment is run.

Recommended implementation order: lazy formatter setup first as a focused change; idle microphone policy next for likely all-day savings; bounded recovery alongside it; single-engine modes after deciding the live-preview tradeoff.
