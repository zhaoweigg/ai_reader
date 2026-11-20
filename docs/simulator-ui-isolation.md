# Concurrent simulator UI tests

Leaf has five slots (A through E) with one exclusive job per device UUID and at most five jobs total. The canonical registry records the current devices and admission limit. The October 23, 2026 comparison passed the same reader workflows serially and concurrently on two devices. Five-way throughput and isolation have not been benchmarked. The coordinator released both experiment leases immediately after the paired jobs exited, then dispatched independent worker UI jobs on A and B. Reporting and PR work do not hold a simulator.

## What was established

The previous single-UI restriction was a precaution, not a demonstrated Xcode limitation. A prior dispatch race could issue GO before the registry-write command actually finished, and an issued GO could be reassigned before cancellation and process exit were acknowledged. Those are same-device ownership failures. Exclusive leases and the existing `simulator_lease.py` guard address them.

This comparison found no cross-device draft, keyboard-input, clipboard or scene-geometry contamination. It does not establish a cause for every historical orientation failure. Simulated motion delivery and screenshot capture have separate limitations described below.

## Measured comparison

Tested source: `81cb37615457a493302988fb627df9de78c19f5f`. Xcode 26.5 (17F42), iOS Simulator 26.5. Both products were built from this exact source and their app and native-runner signatures verified. Each job used separate DerivedData and result bundles, an assigned UUID, `-parallel-testing-enabled NO`, and a fresh app test-session identifier.

| Execution | A | B | Total elapsed |
| --- | --- | --- | --- |
| Serial | 4 passed, 134.10 s | 4 passed, 157.88 s | 291.98 s |
| Concurrent | 4 passed, 153.69 s | 4 passed, 153.74 s | 153.74 s |

The paired wall time is the latest job finish minus the earliest start, not the sum of overlapping job durations. This wave completed 47.3% sooner than the serial sum. There was one measured paired wave, not a soak test or a general throughput guarantee.

Each device ran three assertion-based workflows with rendered Pages, Scroll and PDF books, plus one observational simulated-motion diagnostic. The workflows:

1. Type a unique slot/run/flow token into Ask Leaf using native keyboard input and assert the exact draft and software-keyboard presence.
2. Close chat and request conflicting orientations: A landscape/B portrait, followed by the reverse. File barriers require both runners to reach each checkpoint. Assert each app's actual frame and public scene geometry independently.
3. Reopen chat, verify its draft survived both scene changes, type at the native insertion point, and verify that only the intended local insertion changed its token.
4. Keep a distinct clipboard token in each simulator throughout its job, using explicit `simctl pbcopy UUID` and `pbpaste UUID`. Verify it remained distinct, then restore the original text. Snapshot and restore the original keyboard key's presence, value and type.

The identical UI source ran in both phases. The serial B run also exercised the barrier code with preseeded peer checkpoints; the paired run began with an empty barrier directory. Separate unique app sessions isolate defaults, library files, drafts and credentials.

Local evidence in the coordinator worktree is retained under `build/ui-isolation-{finalserial,concurrent}-{A,B}.xcresult`, accompanying `.json`/`.log` files, `build/ui-isolation-comparison.json`, and `build/ui-isolation-concurrent-*-attachments/`. Runtime paths are intentionally ignored by Git. The tracked test and this report describe the reproducible scope.

## Limits and excluded diagnostics

All 26 paired screenshots were inspected in a contact sheet. Portrait typing and restored states show each device's own text and keyboard. Landscape `app.screenshot()` captures have rotated/cropped content and a black area, also seen in the serial baseline. Public window/app geometry assertions report 874×402, but these captures do **not** certify landscape visual parity. Do not turn a geometry pass into a claim that landscape screenshots or physical rotation passed.

The observational motion case recorded A entering landscape while B remained portrait after ordinary simulated motion requests. It deliberately does not assert physical motion delivery. The reader workflows use the existing public scene-geometry fixture to validate layout independently of that delivery path. Physical phone rotation remains a separate check.

Three early probe runs were excluded from the measured results: a background-runner `UIPasteboard` access blocked; a typing assertion incorrectly assumed tapping always places the caret at the end; and Scroll setup raced the rendered paragraph. The final probe uses UUID-scoped clipboard commands, verifies insertion without a caret-position assumption, and waits for rendered book text. These were probe defects, not evidence that concurrent UI tests are unsupported.

No production app source changed in this work. After the comparison, host-runner cleanup and opt-in clipboard handling were hardened and covered by Python regressions; the compiled UI probe remained identical. No additional UI soak run was required or performed.

## Isolation and handoff rules

- Only the coordinator writes canonical ownership. Commit and read back each fresh lease before GO; retain it through cancellation acknowledgement and actual xcodebuild/native-runner exit.
- Run `simulator_lease.py --require-idle` immediately before launching; revalidate the lease before any later device action or cleanup. Never operate on the peer UUID or reset shared CoreSimulator services.
- Use one job per assigned UUID, separate DerivedData/results, and a unique `LEAF_UI_TEST_ID` per app launch. Do not share a mutable app fixture directory between jobs.
- Use UUID-scoped clipboard commands and app/device-scoped native input and orientation requests. Avoid host clipboard, foreground Simulator menu actions and global recovery commands.
- Keyboard preferences live in a shared host defaults domain. Lock `build/simulator-preferences.lock` around read/modify/write, update only the assigned UUID, and restore only changed keys with their original presence and types. Do not replace the entire `DevicePreferences` map.
- Exit and restore before sending RELEASE. A failed cleanup or surviving runner keeps the lease pending investigation. Do not relabel the slot available simply because a shell command yielded a session ID.
- Retain worker feature-specific verification. The coordinator does not repeat simulator feature tests after merge.

## Guarded job runner

The coordinator grants the lease separately. Then a worker can run `python3 scripts/simulator_job.py path/to/job.json` with a spec like:

```json
{
  "registry": "/Users/weizhao/workspace/ai_reader/build/simulator-coordination.json",
  "slot": "A",
  "owner": "worker-thread-id",
  "lease_id": "fresh-coordinator-issued-lease",
  "head": "full-clean-tested-head",
  "device_uuid": "20E63AE6-36C3-4BC1-B319-06A2FDB902EC",
  "worktree": "/absolute/feature/worktree",
  "derived_data": "build/UniqueDerivedData",
  "result_bundle": "build/UniqueRun.xcresult",
  "log": "build/UniqueRun.log",
  "evidence": "build/UniqueRun.json",
  "tests": ["LeafReaderUITests/SomeClass/someCase"],
  "timeout": 600
}
```

This runner does not acquire or release ownership. Invoke it from the coordinator-managed main checkout: it uses its sibling canonical `simulator_lease.py` to validate the target worktree. Do not copy or replace a tracked guard inside a frozen feature checkout. It guards the lease, snapshots the keyboard key before mutation, starts one pinned xcodebuild process group, waits for actual process/runner exit, restores owned preferences and writes evidence. The coordinator must independently acknowledge START/RELEASE.

Only the controlled isolation experiment sets `"clipboard_probe": true` and provides `test_runner_env` with `LEAF_ISOLATION_SLOT`, a shared unique `LEAF_ISOLATION_RUN`, and (for paired runs) `LEAF_ISOLATION_BARRIER`. Ordinary Copy tests leave this option false; their clipboard is not seeded or required to remain unchanged. The clipboard probe restores text only and should run on disposable test simulators, not a clipboard holding non-text data.

Run the host-only lifecycle regressions with `python3 -m unittest discover -s scripts -p test_simulator_job.py -v`. These do not use a simulator slot. The app-hosted iOS unit-test target still requires one; extracting portable logic into a Mac target is separate work.

## Dashboard job runtime

The read-only dashboard shows elapsed wall time for each xcodebuild job. It does not measure individual test cases or CPU time. Assignment refreshes remain every two seconds; clocks tick locally every second even when the registry has not changed. Only the coordinator persists timing metadata in the canonical registry, after matching the job's lease, head and device to the current assignment:

- On verified START, copy the job metadata's actual `started_at` to the slot. Use ISO UTC, including seconds and a `Z` or `+00:00` suffix; fractional seconds are accepted. Do not use `assigned_at` or `start_acknowledged_at`.
- On actual completion, copy `finished_at` and the metadata's `seconds` as numeric, finite, nonnegative `elapsed_seconds`. A slot with `finished_at` freezes its runtime even while still `testing`, `finalizing` or `completed`. The saved elapsed value is preferred because it comes from the runner's monotonic clock; valid start/finish timestamps provide a fallback if that value is absent or invalid.
- When releasing the slot, preserve `last_run={lease_id,started_at,finished_at,elapsed_seconds}` and set its state to `available` (or `released`). The dashboard labels this frozen value **Last job runtime**. Do not put an unfinished run in `last_run`.
- On a new lease, clear the previous lease's active timing fields. A reserved/assigned slot always shows **Not started**, never a ticking clock or its previous run. `last_run` is displayed only for available/released slots.

Testing slots without a valid actual start show a dash and **Start time unavailable**. A future start, reversed finish/start, malformed timestamp or unfinished historical record never produces a negative or `NaN` clock. A missing completion timestamp does not keep a finalizing/completed run ticking. Completed times are floored to whole seconds in `HH:MM:SS`, with hours allowed to exceed 23.

The server continues to expose only operational slot/queue/agent fields. There is no timing write endpoint. A transient registry read failure leaves the last received assignments visible with a disconnected notice; any ticking value then reflects that last reported testing state until the coordinator's next successful update. Do not infer process liveness from a timer alone.

Run dashboard regressions with `node --test scripts/test_coordination_dashboard.js`. They use a host DOM harness and fake clock; no simulator slot is needed. The dashboard HTML is read by the existing server on every page request, so after merging and safely fast-forwarding the coordinator's clean main checkout, reload the browser tab. The Python server needs no restart for this change.
