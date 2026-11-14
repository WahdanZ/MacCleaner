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

### D-013 Removal moves the item out of reach before deleting it (2026-11-13)
A path check followed by a path-based delete can be raced by another process swapping the item. macOS has no
"unlink only if this inode" call. **Decision:** `LocalFileSystem.remove` renames the item (relative to its open
parent, `RENAME_EXCL`) into a private 0700 staging folder with a random name, re-checks the identity there, moves it
back on a mismatch, and only then deletes through descriptors. Paths are opened with `O_NOFOLLOW_ANY`, so a symlink
anywhere in the path is refused; callers pass resolved paths. **Consequence:** a removal needs write access to the
parent (it already did). A staging folder that can't be removed is reported in the result (or in the error), never
dropped silently; a crash mid-removal can still leave a `.maccleaner-rm-*` folder next to the item, which nothing
cleans up yet. Protection is asked again for each entry right before it is deleted, so something protected during
a long removal is kept, with the folders holding it (fail closed).

### D-014 Nothing below a folder newer than its review is deleted (2026-11-13)
A folder's own identity doesn't change when entries are added deep inside it. **Decision:** `FileIdentity` records
when it was captured; removing a folder keeps every entry below it whose birth or status-change time is later
(an unknown capture time keeps everything), and folder-contents targets act only on their reviewed entries.
**Consequence:** caches an app is writing to are often removed only partly; the report says what was kept and why.

### D-015 Approvals are made only by the executor, used once, and never leave the process (2026-11-13)
**Decision:** `ApprovalLedger` is `package`-only and `~Copyable`; `CleanupApproval` has no public initializer. Code
outside MacCleanerKit gets an approval only from `CleanupExecutor.approve`, called from the four trusted flows.
Approvals are in memory and never serialized, so one made in the app can't be used by a `--cli` or `--mcp` process
(each has its own executor and ledger), and none survives a restart. **Consequence:** the CLI prompt and the MCP
confirmation window must approve inside the process that executes (they already do).
**Not guaranteed:** the ledger does not verify that a person or an enabled policy approved. `approve(plan, by:)`
trusts its caller's `Approver` label; the ledger is a record of a claim, not proof of human authorization. Only
calling it from the trusted flows makes the label true, and that is an open requirement for M01-04b.

### D-016 Trash moves are approved at the review sheet, from the identities it shows (2026-11-13)
**Decision:** migrated screens build their review with `ReviewBuild.trashFiles` (or the downloads part of
`overview`), which captures each item's `FileIdentity` when the sheet opens and builds the `CleanupPlan` from exactly
those snapshots. The sheet's confirm button calls `ReviewConfirmation.confirm`, the only place in the app that issues
an approval (`.userInApp`); the plan is approved as built, never rebuilt or extended. `AppCleanup.moveToTrash` runs it
through the executor and records each move in the Trash log as `AppEngine.trash` does. `scripts/check-approval-sites.sh`
(CI) fails on any other approval site; it only finds call sites, so the self-test checks the confirmation behaviour.
**Consequence:** until M01-04b-3 the legacy `AppEngine.trash` stays for unmigrated callers; it is removed then. (Removed in M01-04b-3c: see D-017.)

### D-017 The folders Mac Cleaner makes itself go to the Trash as app-owned, with their operation's proof (2026-11-13)
**Decision:** the last two Trash moves nobody confirms item by item — the uninstall password step's staging folder and
an installed usage skill — go through the cleanup executor too, approved as `.appOwned(kind)` in `AppOwnedTrash`. That
is not a general bypass: the ledger accepts an app-owned approval only for one `.trash` of exactly one folder in the
kind's module (`admin-staging`, `installed-skill`); each move gets its own executor whose protection allows only that
folder; and each needs a proof value only its operation can make (fileprivate initializers): `AdminStep.Staging` (the
`mktemp` folder checked right after the script, its identity, your uid, and the staging names and reviewed identities of
the items the script reported MOVED) and `InstalledSkills.Verified` (an ownership record — folder and SKILL.md
identities, SHA-256 — written only after Mac Cleaner created both, and still matching). The folder's exact contents are
checked before approving and again as the executor's precondition, after which the executor checks its identity.
Staging is logged `restorable: false` (Put Back points to Finder). Connect never overwrites a skill folder that isn't
provably Mac Cleaner's (an unrecorded one, even with matching text, an edited one, one with other files) and never
rewrites one (an older version's skill is kept as it is), installs the skill before changing the config and removes it
again if the config can't be changed — only after moving the folder and its SKILL.md to private names and proving what
was moved is the recorded folder, file and content (anything else is moved back). Claude Code's registration is replaced
only after the old one was removed, and restored if the new one can't be added; Disconnect touches the skill only once
the server is really gone, still disconnects the server when it keeps the skill, and says so; Save skill folder never overwrites and is never recorded. `AppEngine.trash`
is removed. `scripts/check-approval-sites.sh` keeps `.appOwned`, executor creation, these moves and their proofs in
their files. History records an uninstall as moved to the Trash only for what reached it (#41). A move that reached the
Trash but whose Trash-list record couldn't be written is never undone: it is reported as moved but unrecorded, with its
Trash path and how to restore it from Finder (and a skill's ownership record is dropped, since it left its place).
**Not guaranteed (open, not resolved):** (1) another process running as you could change the staging folder (0700,
yours after the step) or the skill folder in the instant between the precondition and the move; the executor still
checks the folder's identity, not every nested file. (2) The staging check covers the folder's direct entries, not the
contents of a moved item such as a bundle. Taking the staging folder's trust check and identity from one stat only
ties the identity to the folder that passed the check; it closes neither of these.
