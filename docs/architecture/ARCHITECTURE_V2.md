# MacCleaner 2.0 Architecture

Status: **proposed** (M01 implements it). Baseline: commit `8b483b2`. See `CURRENT_STATE.md` for what exists.

## 1. Shape: a modular monolith

One Xcode project, one app bundle, one Swift package (`Packages/MacCleanerKit`) with four library products.
The app, CLI and MCP keep sharing one binary (`Entry.main` argument dispatch) — this keeps a single code
signature and a single set of safety policies, and is how the product already ships.

```
                   ┌──────────────────────────── MacCleaner.app (one binary) ───────────────────────────┐
                   │  App target: SwiftUI/AppKit views, Entry.main, MenuBarExtra, Settings              │
                   │      --cli → CLI front end         --mcp → MCP transport        --selftest         │
                   └───────────────┬───────────────────────────┬─────────────────────────┬─────────────┘
                                   ▼                           ▼                         ▼
                        ┌───────────────────┐       ┌────────────────────┐    ┌────────────────────────┐
                        │ MacCleanerFeatures│──────▶│  MacCleanerCore    │◀───│ MacCleanerPersistence  │
                        │ (use cases, view  │       │ (domain, policies, │    │ (history, settings,    │
                        │  models, modules) │       │  protocols, pure)  │    │  clipboard store, logs)│
                        └─────────┬─────────┘       └─────────▲──────────┘    └────────────────────────┘
                                  │                           │
                                  ▼                           │
                        ┌───────────────────┐                 │
                        │ MacCleanerPlatform│─────────────────┘  implements Core protocols
                        │ (FileManager, APFS│
                        │  Process, IOKit,  │
                        │  NSPasteboard…)   │
                        └───────────────────┘
```

Dependency rules (enforced by package manifest):

* `Core` depends on **nothing** but Foundation. No AppKit, no SwiftUI, no `Process`.
* `Platform` → `Core`. `Persistence` → `Core`. `Features` → `Core`, `Platform`, `Persistence`.
* App target → `Features` (+ `Core` types for display).
* Split further only with a written reason in `DECISIONS.md` (e.g. `MacCleanerClipboard` if clipboard crypto
  grows, or a `MacCleanerMalware` signatures package).

## 2. Core domain model (`MacCleanerCore`)

All types are `Sendable` value types.

| Type | Purpose |
|---|---|
| `FileIdentity` | `path`, `device`, `inode`, `type` (file/dir/link), `size`, `mtime`, `linkCount`, `flags`. Captured at scan, re-captured before execution. |
| `CleanupCandidate` | `id`, `module`, `title`, `targets: [Target]`, `estimatedBytes`, `allocatedBytes`, `risk`, `recommended`, `explanation`. |
| `Target` | `.file(FileIdentity)`, `.directoryContents(FileIdentity)`, `.command(ToolCommand)` (simctl, docker, tmutil) with a human description of what is lost. |
| `CleanupRisk` | `safeRegenerable`, `reviewRequired`, `potentialUserData`, `privileged`, `protected`. |
| `Disposition` | `.trash`, `.permanentDelete`, `.overwriteThenDelete`, `.quarantine`, `.command` — separate from risk. |
| `ScanOutcome<Item>` | `items`, `inaccessible: [AccessProblem]`, `partialErrors`, `wasCancelled`, `isComplete`, `warnings`. |
| `CleanupPlan` | ordered candidates + dispositions + a `planDigest` over *identities*, not just paths. |
| `CleanupApproval` | `planDigest`, `approvedBy: .userInApp / .userInTerminal / .userViaMCPPrompt`, `expires`, single-use nonce. An agent cannot mint one. |
| `CleanupReport` / `ItemOutcome` | per-target `.removed(bytes)`, `.trashed(recoveryURL)`, `.skipped(reason)`, `.failed(error)`; totals split into *freed* vs *moved to Trash*. |
| `ProtectionPolicy` | merges hard-coded structural/sensitive roots, user protection, scan exclusions, module exclusions; one case-insensitive comparison; documented precedence: **hard-coded > user protected > module exclusion > scan exclusion**. |
| `ProgressEvent` | `scanStarted(module)`, `moduleProgress`, `itemsDiscovered`, `accessProblem`, `cleanupStarted`, `itemFinished(ItemOutcome)`, `finished(report)`, `cancelled`. Delivered as `AsyncStream<ProgressEvent>`. |

## 3. The one cleanup executor

```
Discover → Classify → Plan → Review → Authorize → Revalidate → Execute → Record → (Restore)
```

`actor CleanupExecutor` (in `Features`, using `Platform` file operations) is the **only** code path that removes,
trashes, overwrites or quarantines anything. The app, CLI, MCP and scheduler all call it. For each target:

1. `ProtectionPolicy.check(target)` — refuse protected/structural/sensitive.
2. `FileIdentity.recapture(path)` must equal the planned identity (device, inode, type; size/mtime for files).
   Symlinks are never followed unless the plan targeted the link itself.
3. Perform the disposition with `O_NOFOLLOW`/`openat`-style operations where the platform allows.
4. Emit `itemFinished` with the true outcome. No aggregate "success" unless every item succeeded.
5. Append the item to the open `CleanupSession` in persistence.

Cancellation is checked between items; an item in flight is completed or rolled back, never half-done
(the Shredder's per-file overwrite-then-unlink is the model, see `SAFETY_MODEL.md`).

## 4. Actors and isolation

| Owner | Isolation |
|---|---|
| View models | `@MainActor @Observable` |
| `CleanupExecutor`, `ScanCoordinator` (bounded `TaskGroup`, max = active CPU count) | `actor` |
| `HistoryStore`, `ClipboardStore`, `SettingsStore` | `actor` wrapping a file/SQLite handle; cross-process safety via the existing `SharedFile` lock (history) or SQLite WAL (clipboard) |
| `MCPSession` (cacheScan, appCache, pending approvals) | `actor` (replaces `static var`s, RISK-009) |
| `SizeCache` | `Mutex` (Synchronization, macOS 15+) or `OSAllocatedUnfairLock` (macOS 13+) — **use the latter for macOS 14** |

## 5. Persistence (`MacCleanerPersistence`)

* Cleanup sessions: JSON Lines per session under `~/Library/Application Support/MacCleaner/History/`, written
  through `SharedFile` (keeps CLI/MCP and app consistent). Migration reads the old `history.json`.
* Settings: `UserDefaults` (already shared with CLI/MCP by bundle id) behind a typed `SettingsStore`.
* Clipboard: SQLite (system `libsqlite3`, no dependency) for metadata; payloads AES-GCM encrypted with a key in
  the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); versioned migrations. Details in M04B.
* Logs: `os.Logger` with `privacy: .private` for every path and never any clipboard content.

## 6. UI integration

* Keep current views; replace each module's engine call with a use case returning `ScanOutcome` and a plan.
* The existing Review sheet (`ReviewCenter`) becomes the single "Review → Authorize" step: it produces a
  `CleanupApproval` from exactly the plan it showed.
* Sidebar grouping per the 2.0 IA: Overview · Cleanup · Applications · Privacy & Security · Developer ·
  Files & Storage · Utilities, with progressive disclosure (Developer group collapsible, hidden until tools are
  detected or the user enables it).

## 7. CLI / MCP

* Both call the same use cases and executor.
* CLI: interactive y/N stays the human approval (`.userInTerminal`). No-TTY → preview only, exit 2.
* MCP: preview returns the plan; **confirm requires a human approval** obtained by Mac Cleaner itself
  (native confirmation alert from the app/agent process, or MCP elicitation when the client supports it).
  An agent-supplied `confirm: true` alone is never sufficient (RISK-004).
* Clipboard history and per-file scan data are never exposed through MCP (CLIP-08).

## 8. Migration sequence

See `MIGRATION_PLAN.md`. Short version: create the package with `Core` only → move pure types and guards with
their self-tests → add XCTest target → executor + identities → modules move one PR at a time → Swift 6 mode per
package as each becomes clean → app target last.
