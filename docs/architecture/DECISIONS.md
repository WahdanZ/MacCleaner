# Architecture Decisions

Format: context → decision → consequence. Newest last.

### D-001 Modular monolith, one binary (2026-11-13)
The app, CLI, MCP and self-test already share one binary with argument dispatch. Splitting into separate
executables would duplicate signing/notarization and risk diverging safety policies.
**Decision:** keep one binary; introduce one local Swift package with four library products (Core, Platform,
Persistence, Features). **Consequence:** CLI/MCP start-up loads SwiftUI frameworks (measured cost acceptable
today; revisit if CLI latency matters).

### D-002 Keep macOS 14 as the floor
**Decision:** `MACOSX_DEPLOYMENT_TARGET = 14.0`. Newer APIs (Liquid Glass, `Mutex`) behind `#available`.
Use `OSAllocatedUnfairLock` rather than `Mutex` for shared state.

### D-003 One cleanup executor
Today seven modules each implement revalidate/execute/record. **Decision:** a single `actor CleanupExecutor`
is the only code allowed to remove/trash/overwrite/quarantine. Modules migrate one PR at a time.

### D-004 Agent confirmation is not human approval
`preview_id` binding (#15) proves what the agent saw, not what a person approved. **Decision:** MCP destructive
confirms require a Mac Cleaner-owned human confirmation (native alert or MCP elicitation). CLI keeps its TTY
prompt. **Consequence:** headless MCP use can preview but not delete — intended.

### D-005 Shredder deletes file-by-file, through open folders and a private staging folder
**Decision:** plan at review; work through folder descriptors; move each file into a private 0700 staging
folder and verify before overwriting; unlink only after overwrite + flush + identity check; overwrite growth
seen through the still-open file; folders removed only when empty. **Consequence:** no rollback once
overwriting starts, so results are partial-aware (kept / damaged). Not atomic against a hostile same-user
process; documented rather than claimed.

### D-006 Test isolation via `CFFIXED_USER_HOME` + in-memory settings
**Decision:** the self-test runs in a throwaway home set through `CFFIXED_USER_HOME`, refuses the real home by
default, and keeps settings in memory (`CFFIXED_USER_HOME` does not redirect `cfprefsd`). Cheaper than making
every guard injectable immediately; XCTest (M01) adds injection.

### D-007 No separate menu bar helper yet
The menu bar lives in the app. A launch-at-login helper adds a second signed executable and IPC.
**Decision:** revisit in M04A only if measurements show the full app's idle footprint is a problem. A helper
would never contain a deletion engine.

### D-008 Clipboard history is local-only, encrypted, never exposed to MCP/CLI
SQLite metadata + AES-GCM payloads with a Keychain key. Search over an in-memory index built after unlock
(no plaintext full-text index on disk). Trade-off: search starts after loading; history size is capped.

### D-009 Universal binary thinning is analysis-first
Thinning signed third-party bundles breaks code signatures and auto-updates. **Decision:** ship read-only
analysis; any thinning is limited to unsigned or user-owned, ad-hoc-signed bundles, with a full backup.

### D-010 No third-party dependencies by default
System frameworks cover SQLite, crypto (CryptoKit), Keychain, IOKit. Any dependency needs a decision entry
with licence review. Mac Sai is a feature reference only; no code copied.

### D-011 Unattended cleanup needs a standing policy, not per-run approval
The scheduled safe clean cannot ask anyone. **Decision:** it runs only under an explicit, versioned, revocable
`AutomationPolicy` with a narrow scope fixed in code (safe regenerable files only, no commands, no review items,
nothing privileged). Widening the scope requires the user to re-enable it. CLI/MCP can't create or widen it.

### D-012 The package starts in Swift 6 mode, tested with Swift Testing, linked statically
`Packages/MacCleanerKit` uses `swift-tools-version: 6.0`, so `MacCleanerCore` compiles in Swift 6 language mode from
its first line while the app target stays in Swift 5 mode until M01-12. Tests use Swift Testing (`swift test`; ships
with the Xcode 16+ toolchains on CI and locally). The library is a static product linked into the one app binary,
so the bundle, signature and CLI/MCP entry points are unchanged. The app keeps `SafetyGuard`, `TrashGuard` and
`ProtectedPaths` as thin wrappers that resolve paths on the Mac and call the pure rules (`PermanentDeleteRules`,
`TrashRules`, `UserProtection`), so no call site changed.

**Build:** the app is built with `-target`, where each project gets its own build folder; the local package's
module then isn't visible to the app ("no such module 'MacCleanerCore'" on a fresh checkout, Xcode 16.4 on CI and
26.3 locally). Every command-line build goes through `scripts/xcbuild.sh`, which sets one absolute `SYMROOT` for
both. `scripts/clean-build-check.sh` builds and tests the committed HEAD in a brand-new worktree, the way CI does.
Building in the Xcode app (scheme/workspace build) is unaffected.
