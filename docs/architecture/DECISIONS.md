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

### D-005 Shredder deletes file-by-file, never recursively
**Decision:** each file is unlinked only after its own overwrite and flush succeeded; folders are `rmdir`-ed
only when empty. **Consequence:** a failure leaves a partly shredded folder (already-shredded files gone, the
rest intact) instead of an un-overwritten deletion. Reported to the user.

### D-006 Test isolation via `CFFIXED_USER_HOME`
**Decision:** the self-test runs in a throwaway home set through `CFFIXED_USER_HOME` and refuses the real home
by default. Cheaper than making every guard injectable immediately; XCTest (M01) adds injection.

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
