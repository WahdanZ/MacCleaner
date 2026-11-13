# Risk Register

Audited commit: `8b483b2ad893bd2ee2a184a205f7c97c6a706ce5`. Each entry is either **Verified** (read in source and,
where marked, reproduced) or **Design gap** (a missing guarantee, not a bug in what exists). Speculative issues are
not listed as defects.

Severity: **Critical** = silent loss of unrecoverable user data in a default flow · **High** = unrecoverable data
loss or privilege/approval bypass in a reachable flow · **Medium** = recoverable loss, misleading result, or a
safety guarantee weaker than stated · **Low** = inconsistency with no known loss path.

| ID | Sev | Status | Area | Summary | Fix plan |
|---|---|---|---|---|---|
| RISK-001 | High | **Fixed in M00-01** | Shredder (SAFE-01) | `ShredEngine.shred` deletes the item even when overwriting a file failed (write error, `fsync` error, file > 4 GB, file changed). Unreadable sub-folders are skipped by the enumerator (`errorHandler: { true }`) and their files are deleted by `removeItem` without being overwritten. | Fail closed: plan every file first, refuse the whole item on any unreadable folder, oversize file or non-regular entry; delete each file only right after its own overwrite succeeded; never call recursive `removeItem`. |
| RISK-002 | Medium | **Fixed in M00-02** | Duplicates (SAFE-05) | `partialHash`/`fullHash` ignore read errors, so two unreadable files hash equal and are grouped as duplicates. `DupEngine.identical` returns `true` when both reads throw (`(try? read) ?? Data()` on both sides), and never checks that `size` bytes were compared. Loss is recoverable (copies go to the Trash). | Hashes return `nil` on any read error or short read; `identical` compares exactly `size` bytes and returns `false` on any error. |
| RISK-003 | High | **Fixed in M00-03** | Self-test (SAFE-02) | `SelfTest.run` creates fixtures at fixed paths in the developer's real home (`~/.maccleaner-selftest`, `~/.cache/maccleaner-selftest-*`) and removes them unconditionally, including anything already there; it rewrites the real `ProtectedPaths` setting. | Self-test refuses to run against the real home unless explicitly overridden; `scripts/selftest.sh` runs it under `CFFIXED_USER_HOME=$(mktemp -d)`; CI uses the script. |
| RISK-004 | High | Design gap | MCP approval (SAFE-03) | The agent that receives a preview also sends the confirm: a `preview_id` proves the plan was *shown to the agent*, not that a human approved it. `empty_trash` digests only item count + total size. Digests use paths/ids, not filesystem identity, so an item replaced at the same path between preview and confirm passes. | M00-04: human-in-the-loop approval for MCP (approval prompt shown by Mac Cleaner itself, or MCP elicitation where the client supports it), identity digests (`dev`/`ino`/size/mtime), and execution-time revalidation through the shared executor. |
| RISK-005 | Medium | Verified | Simulators (SAFE-04) | `Scanner.plan` adds `xcode.sims` ("Unavailable simulators", `simctl delete unavailable`) with the default `recommended = true`, so it is preselected in Junk Files / Recommended Cleanup. Unavailable devices still hold app data containers. The weekly clean already refuses it (#15). | M00-05: `recommended: false`, review-required, review row lists the device names and states that their app data is deleted. |
| RISK-006 | Medium | Verified | Scans (SAFE-05, CLEAN-10) | Four enumerators (`Scanner.swift`, `Projects.swift`, `Duplicates.swift`, `Shredder.swift`) use `errorHandler: { _, _ in true }`: unreadable folders are skipped and the scan is presented as complete. Sizes and duplicate sets can be under-reported without warning. | M01: shared `ScanOutcome` with `isComplete`, `inaccessible[]`, surfaced in UI/CLI/MCP. |
| RISK-007 | Medium | Design gap | All executors (SAFE-05) | No module records filesystem identity at scan time. A cache folder replaced by a different folder at the same path between review and execution is deleted. `SafetyGuard` still resolves symlinks, so the replacement must be a real folder in an allowed root. | M01 shared `CleanupExecutor` with `FileIdentity` (`dev`, `ino`, type, size/mtime) checked immediately before each operation. |
| RISK-008 | Medium | Verified | Release (SAFE-06) | `ENABLE_HARDENED_RUNTIME = NO` in the project; hardened runtime and notarization happen only when release secrets exist, otherwise the DMG is ad-hoc signed. The release workflow does not produce the `.sig` asset, so the in-app updater (correctly) offers nothing until the maintainer signs locally. | M09: hardened runtime on in the project for Release, release job fails instead of silently publishing ad-hoc when signing is expected, `.sig` produced in a protected job or documented manual step. |
| RISK-009 | Low | Verified | MCP state | `MCPServer.cacheScan`, `appCache`, `previews` are unsynchronised `static var`s. Safe today because the stdio loop is serial; becomes a data race if requests are handled concurrently. | M01: move into an `actor MCPSession`. |
| RISK-010 | Medium | Verified | Tests/CI | No XCTest/Swift Testing target; CI runs only on `macos-15`; no macOS 14 coverage (deployment target). | M01 test target per package; M09 compatibility matrix (manual on 14 if no runner). |
| RISK-011 | Info | Documented | Shredder | Overwriting on APFS/SSD cannot guarantee unrecoverability (copy-on-write, snapshots, wear levelling, clones). UI already says so. | Keep the disclosure; document in SAFETY_MODEL. |
| RISK-012 | Low | Verified | Protection | `ProtectedPaths.isInsideProtected` is case-sensitive while `reason` is case-insensitive. Used only to *hide* protected projects/SDK roots in listings; deletion goes through `reason`. | M01: one case-insensitive comparison in the policy type. |
| RISK-013 | Low | Design gap | History (CLEAN-07) | `CleanupRecord` stores title/bytes/outcome only, no session id, targets, errors or recovery locations. | M02 session-based history. |
| RISK-014 | Low | Open | Storage Map test | "Storage Map keeps a non-ASCII name exactly as stored" fails when the self-test runs under a long relocated home path; passes on the real home (per #18). Not yet diagnosed — could be a real long-path bug in `DirSize.fileURL`. | Investigate in M00-03 follow-up. |
| RISK-015 | Low | Verified | Concurrency | Swift 6 mode not enabled; 15 `@unchecked Sendable`, 3 `nonisolated(unsafe)`; 4 warnings that become errors in Swift 6. | M01 migration plan. |

## Verified as already fixed (re-checked at this commit)

| Earlier finding | Where fixed | Evidence |
|---|---|---|
| Admin uninstall staging privilege escalation | #16 | `AdminStep.script` uses `mktemp -d` in `/private/var/tmp`, re-checks root-owned parent, `mv -n`, chown of staging dir only |
| TrashGuard case/symlink bypass | #15 | `TrashGuard.key` lower-cases and resolves parent symlinks |
| Weekly clean runs simulator commands | #15 | `AutoClean.select` only accepts file/folder actions |
| MCP confirm without preview | #15 | `MCPServer.approve` single-use id, tool + digest bound (see RISK-004 for what remains) |
| Shredder hard links / locked files | #15 | `ShredEngine.shred` refuses items with `st_nlink > 1` or unwritable files (see RISK-001 for what remains) |
| Unsigned updates | #15 | `Updater.offerable` requires `.sig`; `prepare` checks SHA-256, Ed25519, bundle id, version, `codesign --verify --deep --strict`; swap with restore on failure |
| Review runs live selection | #18 | `ReviewRequest.perform` receives reviewed ids |
| Concurrent history/Trash log writes | #18 | `SharedFile` lock + re-read + write |
| Subprocess hangs | #18 | `Shell.run` timeouts, process-group kill |
