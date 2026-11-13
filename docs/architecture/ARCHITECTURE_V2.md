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
| `CleanupTarget` | `.file(FileIdentity)` (a folder here means its whole subtree: folder identity revalidated, protection re-checked over the subtree), `.directoryContents(folder:, entries:)` (only the reviewed direct entries, each revalidated; an entry added after review is skipped as `addedAfterReview`), `.command(ToolCommand)` (simctl, docker, tmutil) with a human description of what is lost. |
| `CleanupRisk` | `safeRegenerable`, `reviewRequired`, `potentialUserData`, `privileged`, `protected`. |
| `Disposition` | `.trash`, `.permanentDelete`, `.overwriteThenDelete`, `.quarantine`, `.command` — separate from risk. |
| `ScanOutcome<Item>` | `items`, `inaccessible: [AccessProblem]`, `partialErrors`, `wasCancelled`, `isComplete`, `warnings`. |
| `CleanupPlan` | ordered candidates + dispositions + a `digest` (SHA-256) over ids, module, **risk**, disposition and target *identities* (every reviewed folder entry; a command's executable, arguments and **consequence**), not just paths. Display text (title, explanation, sizes) is left out. |
| `CleanupApproval` | `planDigest`, `approvedBy: .userInApp / .userInTerminal / .userViaMCPPrompt / .standingPolicy(AutomationPolicy.id, version)`, `expires`, single-use nonce. An agent cannot mint one. |
| `ApprovalLedger` | The only maker of `CleanupApproval` (its initializer is internal to Core) and the only place one is accepted. Owned by the executor. `redeem` checks issued here, unused, same plan digest, inside `[issued, expires)`, and consumes the approval whatever the result (fail closed). It does **not** verify that a person approved: the `Approver` is the caller's label, so only calling `CleanupExecutor.approve` from the trusted flows (review sheet, TTY prompt, `HumanApproval` window for MCP, an enabled `AutomationPolicy`) makes it true. That is an open requirement for M01-04b. |
| `AutomationPolicy` | A standing, opt-in authorization for unattended runs (scheduled safe clean). See §3a. |
| `CleanupReport` / `ItemOutcome` | per-target `.removed(bytes)`, `.trashed(recoveryURL)`, `.skipped(reason)`, `.failed(error)`, `.partiallyDone(done, kept, damaged)`; totals split into *freed* vs *moved to Trash*. A report never rounds a partial outcome up to success or down to "nothing happened". |
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
   No symlink is followed anywhere in the path (`O_NOFOLLOW_ANY` / `AT_SYMLINK_NOFOLLOW_ANY`).
   Symlinks are never followed unless the plan targeted the link itself.
3. Perform the disposition without a check-then-delete-by-path race (M01-04a, `LocalFileSystem`): a permanent
   removal first renames the item (relative to its open parent, `RENAME_EXCL`) into a private 0700 staging folder,
   re-checks its identity there and moves it back if it isn't the reviewed item; only then deletes it through
   descriptors (`openat`/`unlinkat`). Protection is asked again for every entry, by its original path, right before
   it is deleted, and for the folder itself before it goes; a protected entry is kept with the folders holding it.
   Below a folder, entries created or changed after the identity was captured (birth/status-change time) and other
   volumes are kept and reported. A staging folder that can't be removed is always reported by path. Trash moves are reversible, so they are
   checked after the move and moved straight back on a mismatch.
4. Emit `itemFinished` with the true outcome. No aggregate "success" unless every item succeeded.
5. Append the item to the open `CleanupSession` in persistence.

Cancellation is checked between items. **Not every operation can be rolled back**, so the executor promises a
truthful result, not atomicity:

* Moves (Trash, quarantine, staging) are atomic per item (`rename`) and reversible.
* Permanent deletion of a folder is a sequence of per-entry steps; if it stops part-way, the entries already
  deleted are gone and the report lists exactly what was kept.
* Overwriting (Shredder) is destructive the moment it starts: a file whose overwrite fails part-way is kept
  but its content is damaged, and the report says so (`damaged`). There is no undo.
* `.partiallyDone` is a first-class outcome in UI, CLI, MCP and history.

### 3a. Unattended runs: the automation policy

The scheduled safe clean (#17) runs with nobody present, so it cannot use per-run approval. It runs under a
separate **`AutomationPolicy`**, which the user turns on explicitly in Settings › Automation:

* **Narrow scope, fixed by code:** only `safeRegenerable` file/folder targets in an allow-list of categories
  (today: `AutoClean.select` / `AutoClean.narrowed` — tool caches, logs except crash reports, caches of apps
  that are not running). Never command targets (simulators, Docker, `tmutil`), never review-required or
  potential-user-data items, never Trash-only items, never anything privileged.
* **Versioned:** the policy records which categories it covers. A new app version that adds a category does not
  extend an existing policy; the user must re-enable it after seeing the new scope.
* **Same executor, same guards:** protection, exclusions and identity revalidation apply exactly as in an
  interactive run; anything changed or protected is skipped.
* **Recorded:** each run is a history session with `approvedBy: .standingPolicy`, listing every item.
* **Revocable:** turning it off cancels future runs; it never runs again until turned back on.
* The CLI and MCP cannot create or widen a policy.

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
