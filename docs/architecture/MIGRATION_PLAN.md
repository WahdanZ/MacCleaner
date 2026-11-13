# Swift 6 + Package Migration Plan

Baseline (commit `8b483b2`): Xcode 26.3, Swift 6.2.4 compiler, `SWIFT_VERSION = 5.0`, deployment target
macOS 14.0, one target, 4 Swift-6 warnings already reported (`CURRENT_STATE.md` §6).

**Toolchain rule.** Build with the latest stable Xcode available on CI (`macos-15` image today) and locally
(26.3). Raising Xcode must not change `MACOSX_DEPLOYMENT_TARGET = 14.0`. APIs newer than 14 (Liquid Glass
`glassEffect`, `Mutex`) go behind `if #available` with a 14-compatible fallback.

## Stage A — Baseline (M00, done in this pass)

- [x] Build passes; warnings recorded.
- [x] Self-test passes in an isolated home (197/199; two fixture-environment failures, RISK-014).
- [x] Concurrency inventory (`CURRENT_STATE.md` §6).
- [ ] Performance baseline: app launch to first frame, Junk scan, Storage Map of `~`, duplicates over 10k files,
      menu bar idle CPU. Use `--cli bench` (exists) + Instruments Time Profiler. → task M01-01.

## Stage B — Concurrency preparation (M01)

1. Turn on `SWIFT_STRICT_CONCURRENCY = complete` in Swift 5 mode; fix warnings file by file. Do not add
   `@unchecked Sendable` to silence; each existing one (15) gets a comment naming its lock, or is replaced by
   `OSAllocatedUnfairLock<State>`.
2. Domain models `Sendable` (most already are: `CleanTarget`, `DupGroup`, `SysItem`).
3. `MCPServer` statics → `actor MCPSession`.
4. `SizeCache` `nonisolated(unsafe)` → `OSAllocatedUnfairLock`.
5. Fix the 4 known diagnostics (`Insights.swift:44`, `Updates.swift:195` → `nonisolated static let`;
   `Overview.swift:52,61` → collect into per-index results instead of capturing the buffer).

## Stage C — Structured concurrency (M01–M02, per module as it moves to the executor)

* Replace `DispatchQueue.concurrentPerform` scans with a `ScanCoordinator` using `withTaskGroup` with a width
  limit; propagate `Task.isCancelled` (replaces `DupEngine.Cancel`).
* Replace the 43 `Task.detached` with `async` functions on actors or `nonisolated` functions called from
  `Task {}`; keep `detached` only where priority/actor inheritance must be cut, with a comment.
* Progress via `AsyncStream<ProgressEvent>`.

## Stage D — Swift 6 language mode, incrementally

Order: `MacCleanerCore` (pure, first) → `MacCleanerPersistence` → `MacCleanerPlatform` → `MacCleanerFeatures`
→ app target. Each step is its own PR, and **all tests run after each**. Swift 6 mode is set per package via
`swiftLanguageModes: [.v6]` and for the app target via `SWIFT_VERSION = 6.0`.

## Stage E — Performance verification

Re-run the Stage A measurements after Stage C and after Stage D. A change that regresses a measurement by
> 10 % needs a recorded justification in `DECISIONS.md` or is reverted.

## Package extraction order (M01)

| PR | Moves | Proof |
|---|---|---|
| M01-02 (#32) | Create `Packages/MacCleanerKit` with `MacCleanerCore`; move `ProtectionPolicy` (pure parts of `SafetyGuard`/`TrashGuard`/`ProtectedPaths` with injected home). `ByteText` stays in the app for now | Swift Testing for guards; self-test still green |
| M01-03 | Core contracts: `FileIdentity` (value + match rule), `CleanupRisk`, `Disposition`, `CleanupTarget`, `CleanupCandidate`, `CleanupPlan` (+ identity digest), `CleanupApproval`, `ScanOutcome`, `ItemOutcome`, `CleanupReport`, `ProgressEvent`. Not used by the app yet | package tests |
| M01-04 | `CleanupExecutor` + `FileIdentity` capture in `Platform`; Shredder and Trash moves go through it | adversarial fixtures |
| after M01-04 | `Persistence`: `HistoryStore` → sessions | migration test from v1 `history.json` |
| M01-06… | One module per PR onto the executor: caches, projects, SDKs, apps, duplicates, system data | per-module tests |
