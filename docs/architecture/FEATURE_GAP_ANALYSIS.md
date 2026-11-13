# Feature Gap Analysis — MacCleaner 2.0 backlog vs. current code

Audited commit: `8b483b2ad893bd2ee2a184a205f7c97c6a706ce5`.

Legend — **Done**: implemented and working · **Partial**: implemented but incomplete · **Refactor**: works but must move
onto the shared engine · **Missing** · **Unsafe**: defect verified (see RISK_REGISTER) · **Limited**: blocked or
narrowed by the platform.

Mac Sai (`iliyami/MacSai`) was used only as a feature reference; no code was read for reuse.

## A. Cleanup

| ID | Feature | Status | Evidence / gap |
|---|---|---|---|
| CLEAN-01 | Unified Smart Scan | **Missing** | Overview "Recommended Cleanup" aggregates Junk scan only (`Overview.swift`, `OverviewModel`). No orchestration of apps, privacy, storage, performance. |
| CLEAN-02 | Expanded System Junk | **Partial** | User caches, logs, web caches, sandbox caches, Xcode, Android, package managers, editors, `~/.cache` AI-tool caches (`Scanner.plan`, `SafetyGuard.allowedRoots`). Missing: broken preferences, orphaned app files outside the uninstaller, broken login items as junk, deleted-user leftovers, document versions, language resources. |
| CLEAN-03 | Mail attachments | **Partial** | Apple Mail size only, in System Data (`SystemData.swift`, `SysItem.Section.mail`). No per-attachment discovery; Outlook and Spark missing. |
| CLEAN-04 | Trash bins | **Partial** | Home Trash status/empty/Put Back (`Trash.swift`, `TrashOps`, `TrashLog`). No per-volume `.Trashes/<uid>` listing. |
| CLEAN-05 | Project junk | **Done / Partial** | `ProjectEngine` covers Flutter/Dart, Node (+Next/Nuxt/Turbo/SvelteKit), Gradle/Android, CocoaPods, SwiftPM, Rust, Maven, Python, Go, .NET, CMake, Elixir, Terraform (`Projects.swift:35-66`). Deletion is permanent; Trash-first option missing. |
| CLEAN-06 | Disk hogs | **Partial / Unsafe** | Docker groups, simulators, runtimes, device support, Android AVDs/SDKs (`DevSDK.swift`, `DevTools+.swift`). Unavailable simulators are preselected (RISK-005). Docker volumes review-only status to verify in M02. |
| CLEAN-07 | Cleanup history + restore | **Partial** | `HistoryStore` records title/bytes/outcome; Put Back exists for items Mac Cleaner trashed (`TrashLog`). No sessions, targets, errors or recovery locations (RISK-013). |
| CLEAN-08 | Folder exclusions | **Partial** | Global protected paths (`ProtectedPaths`, Settings › Protection), honoured by every guard. No scan-only or per-module exclusions; precedence undocumented. |
| CLEAN-09 | Universal Clipboard archives | **Missing** | No reference to `useractivityd/shared-pasteboard`. |
| CLEAN-10 | Incomplete scan reporting | **Missing / Unsafe** (open on `main`) | Full Disk Access banner exists (`AccessBanner`, `SysReport.needsFDA`), but enumerators swallow errors (RISK-006). |

## B. Applications

| ID | Feature | Status | Evidence / gap |
|---|---|---|---|
| APPS-01 | Unused apps | **Partial** | `AppInfo.lastUsed` shown and sortable (`AppsModel.swift`, `AppsView.swift`). No 3/6/12-month filters; unknown usage must be shown as unknown. |
| APPS-02 | Reset app | **Missing** | Clear Cache exists (`ReviewBuild` clear cache, #10); no preferences/support/container reset. |
| APPS-03 | App updater | **Missing** | Homebrew outdated is listed in Developer › Homebrew (`DevTools+.swift`); no Sparkle appcast or App Store handoff. |
| APPS-04 | Uninstaller | **Done / Refactor** | Leftovers, launch jobs, receipts, running-app quit, admin staging (`AppEngine`, `AdminStep`). Needs shared executor, identities, audit log. |
| APPS-05 | Extensions manager | **Partial** | Startup & Extensions lists login items, launch agents/daemons, pref panes, internet plug-ins (`SystemItems.swift`). App extensions (`pluginkit`) and system extensions missing. |

## C. Privacy & Protection

| ID | Feature | Status | Evidence / gap |
|---|---|---|---|
| PRIV-01 | Browser privacy | **Missing** | Only browser *caches* are swept (`SafetyGuard.webCacheNames`). History/cookies/site data untouched. |
| PRIV-02 | Browser extensions | **Missing** | |
| PRIV-03 | Permissions overview | **Missing / Limited** | TCC.db readable only with Full Disk Access and its schema is private; must be read-only and best-effort. |
| PRIV-04 | Saved Wi-Fi | **Missing / Limited** | `networksetup -listpreferredwirelessnetworks` lists; removal needs admin. Passwords never read. |
| PRIV-05 | Malware detection | **Missing** | |
| PRIV-06 | Quarantine | **Missing** | |

## D. Performance & Maintenance

| ID | Feature | Status | Evidence / gap |
|---|---|---|---|
| PERF-01 | Startup optimisation | **Partial** | Listing and removal of launch items (`SystemItems.swift`). Disable vs delete not distinguished; `SMAppService` status not read for third-party items. |
| PERF-02 | Maintenance tasks | **Missing** | |
| PERF-03 | Resource hogs | **Missing** | |
| PERF-04 | File associations | **Missing** | |
| PERF-05 | Scheduling | **Partial** | Daily/weekly safe clean with catch-up after sleep, low-disk alerts (`AutoSchedule`, `AutomationModel`, #17). Scope enforced in `AutoClean.select`/`narrowed`, but no explicit versioned automation policy (RISK-017). Scheduled scans (non-destructive) and run history missing. |

## E. Storage & Files

| ID | Feature | Status | Evidence / gap |
|---|---|---|---|
| FILE-01 | Space Lens | **Partial** | Storage Map: home or whole disk, drill-down, treemap, VoiceOver actions (`DiskMap*.swift`). No other volumes, no incomplete markers, no type breakdown/export. |
| FILE-02 | Large & old files | **Partial** | `LargeFileScanner` with size/age; needs type/volume filters. |
| FILE-03 | APFS clone consolidation | **Missing** | No `clonefile` use. |
| FILE-04 | Universal binary analysis | **Missing** | |
| FILE-05 | Binary thinning | **Missing** | Will be restricted by design (DECISIONS D-009). |
| FILE-06 | Shredder | **Unsafe on `main`** | RISK-001; fix in open PR #26. |

## F. Menu bar & health

| ID | Feature | Status | Evidence / gap |
|---|---|---|---|
| MENU-01 | PR #17 | **Done (merged)** | Panel, Clean Now, schedule with wake catch-up and DST-safe times (`AutoSchedule`, self-test schedule checks). Timezone-change re-arming to re-verify in M04A. |
| MENU-02 | System statistics | **Partial** | Free space + forecast only. CPU/GPU/memory/battery/network missing. |
| MENU-03 | Health alerts | **Partial** | Low disk alert with threshold; no memory-pressure alert or cooldown model. |
| MENU-04 | Recommendations | **Missing** | |
| MENU-05 | Connected devices | **Missing** | |
| MENU-06 | Helper | **Not needed yet** | Menu bar lives in the app; decide in M04A (DECISIONS D-007). |

## G. Clipboard (CLIP-01…12)

**Missing entirely.** No `NSPasteboard` monitoring (current uses are copy-to-clipboard only).

## H. Integrations, release, quality

| Area | Status | Evidence / gap |
|---|---|---|
| CLI | **Done / Refactor** | `CLI.swift`, interactive y/N for destructive commands, exits 2 without TTY. |
| MCP | **Done / Unsafe** | 21 tools, preview_id binding (#15); human approval gap RISK-004. |
| Secure updates | **Done** | Ed25519 + SHA-256 + bundle/version + codesign + rollback swap (`Updates.swift`). |
| Signing / notarization | **Partial** | Conditional on secrets (RISK-008). |
| Localization | **Missing** | No `.xcstrings`/`.lproj`; strings are literals (SwiftUI `Text("…")` literals are localizable keys, so extraction is feasible). |
| Automated tests | **Partial** | Executable self-test only (RISK-010). |
| Swift 6 | **Missing** | `SWIFT_VERSION = 5.0` (RISK-015). |
