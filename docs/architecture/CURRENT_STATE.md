# MacCleaner — Current State (audit)

| | |
|---|---|
| Audited commit | `8b483b2ad893bd2ee2a184a205f7c97c6a706ce5` (main, 2026-11-13) |
| Toolchain on the audit host | Xcode 26.3 (17C529), Apple Swift 6.2.4, macOS 26.0 (25A354), arm64 |
| CI host | `macos-15` GitHub runner, default Xcode of that image |
| Auditor | Claude Code session, read-only audit followed by M00 fixes |

Everything below was read from source at the commit above. Where a statement is a judgement rather than a
read fact, it says so.

## 1. Repository layout

| Path | What it is |
|---|---|
| `MacCleaner.xcodeproj` | One Xcode project, **one target** (`MacCleaner`), no test target, no Swift packages |
| `MacCleaner/*.swift` | 47 Swift files, ~15,000 lines, all compiled into the one app binary |
| `MacCleaner/MacCleaner.entitlements` | Entitlements used only by the signed release build |
| `build.sh` | Build → self-test → ad-hoc sign → install to `/Applications` |
| `release.sh`, `scripts/make-dmg.sh`, `scripts/sign-release.sh`, `scripts/release-key.swift` | Local release tooling, Ed25519 release key kept in the maintainer keychain |
| `.github/workflows/ci.yml` | Build (ad-hoc), `--selftest`, read-only CLI checks, MCP `tools/list` |
| `.github/workflows/release.yml` | Tag-driven release; Developer ID signing + notarization **only when secrets exist** |
| `.github/workflows/pages.yml` | Website deploy |
| `website/` | Static product site |
| `docs/DESIGN.md`, `docs/screenshots/` | Visual design notes and screenshots |
| `README.md`, `DEVELOPMENT.md`, `ROADMAP.md` | User docs, developer notes, the v1 roadmap |

## 2. Build settings (both configurations)

| Setting | Value | Note |
|---|---|---|
| `SWIFT_VERSION` | `5.0` | Swift 6 language mode **not** enabled |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | Keep (requirement) |
| `ENABLE_HARDENED_RUNTIME` | `NO` | Turned on only by `release.yml` flags when signing secrets exist |
| `ENABLE_APP_SANDBOX` | `NO` | Required: the app needs to reach `~/Library`, `/Applications`, run `simctl`, `docker`, `tmutil` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `io.github.wahdanz.maccleaner` | |
| `MARKETING_VERSION` | `1.2.0` | |
| Strict concurrency | default (minimal) | |

## 3. Process entry points (`MacCleaner/MacCleanerApp.swift`, `Entry.main`)

One binary, four modes chosen by arguments:

| Mode | Trigger | Code |
|---|---|---|
| SwiftUI app (window + `MenuBarExtra`) | no args | `MacCleanerApp` |
| CLI | `--cli <cmd>` | `CLI.run` (`CLI.swift`) — routes destructive commands through `MCPServer.call` with an interactive y/N prompt; exits 2 without a TTY |
| MCP server (stdio JSON-RPC) | `--mcp` | `MCPServer.run` (`MCPServer.swift`), 21 tools |
| Self-test | `--selftest` | `SelfTest.run` (`SelfTest.swift`, ~850 lines, ~199 checks) |
| Benchmark | `--cli bench` | `Bench.run` (`Bench.swift`) |

There is no separate menu-bar helper process; the menu bar panel (`MenuBarPopover.swift`) lives in the app.

## 4. Feature modules (as built)

| Sidebar page (`SidebarPage`, `Shell.swift`) | Main files | Engine symbols |
|---|---|---|
| Overview (dashboard, Insights, Quick Tools, Recommended Cleanup) | `Overview.swift`, `Insights.swift` | `OverviewModel`, `FreeSpaceLog`, `InsightMath` |
| Junk Files (caches, logs, downloads, app/web caches) | `ContentView.swift`, `Scanner.swift`, `CleanerModel.swift`, `CleanTarget.swift` | `Scanner.plan/measure/finalize`, `Cleaner.run`, `CleanAction` |
| Developer Tools (projects, SDKs, Homebrew, Docker, simulators, Android) | `Projects*.swift`, `DevSDK*.swift`, `DevTools+.swift` | `ProjectEngine`, `SDKEngine` |
| Large & Old Files | `LargeFiles.swift` | `LargeFileScanner` |
| Duplicates | `Duplicates*.swift` | `DupEngine` (size → 64 KB head/tail hash → full SHA-256; `identical` re-check before trash) |
| Applications (uninstall, leftovers, clear cache, last used) | `AppsModel.swift`, `AppsView.swift` | `AppScanner`, `AppEngine`, `AdminStep` (privileged staging), `AdminGuard` |
| Storage Map | `DiskMap*.swift`, `Treemap.swift`, `DirSize.swift` | `DiskScanner` (getattrlistbulk), `DirSize`, `SizeCache`, `WalkPool` |
| System Data (TM snapshots, iOS backups, Messages attachments, Mail) | `SystemData.swift` | `SysItem`, `SysReport` |
| Startup & Extensions (login items, launch agents/daemons, pref panes, plug-ins) | `SystemItems.swift` | `AppEngine.removeSystemItems` |
| Shredder | `Shredder.swift` | `ShredEngine` |
| Trash + Put Back | `Trash.swift`, `TrashView.swift` | `TrashLog`, `TrashOps` |
| Review sheet (all destructive UI flows) | `Review.swift`, `ReviewBuilders.swift` | `ReviewCenter`, `ReviewRequest`, `ReviewBuild` |
| History | `History.swift`, `SharedFile.swift` | `HistoryStore` (JSON file under a lock file) |
| Automation (scheduled safe clean, low-disk alerts, menu bar) | `Automation.swift`, `MenuBarPopover.swift` | `AutoClean.select/narrowed`, `AutoSchedule`, `Notifier` |
| Updates | `Updates.swift` | GitHub latest release → SHA-256 + Ed25519 `.sig` + bundle id + version + `codesign --verify --deep --strict` (+ Gatekeeper when signed) |
| Integrations (CLI install, AI clients, skill text) | `Integrations*.swift`, `CLI.swift` | `CLIInstaller`, `SkillText` |

## 5. Safety architecture (as built)

* **`SafetyGuard`** (`SafetyGuard.swift`) — allow-list for *permanent* cache deletion. Resolves symlinks, refuses
  `protectedRoots`, only allows paths under `allowedRoots`, never the container roots themselves.
* **`TrashGuard`** — rules for *Move to Trash*. Lower-cases and resolves parent symlinks (`key(_:)`), refuses
  structural and sensitive folders, allows only `~` and `/Applications`.
* **`ProtectedPaths`** — user-defined protection list in `UserDefaults`, checked by every guard.
  `reason(_:)` is case-insensitive; `isInsideProtected(_:)` is **case-sensitive** (see RISK-012).
* **Review sheet** — every UI destructive flow builds a `ReviewRequest`; `perform` receives the ids of the rows
  shown, and builders map them back to the objects captured when the sheet opened (fixed in #18).
* **MCP** — preview/confirm with a single-use `preview_id` bound to tool name + digest of item ids/paths (#15).
* **Admin uninstall** — root script stages into `mktemp -d` under `/private/var/tmp`, re-checks ownership,
  `mv -n`, chowns only the staging dir (#16).
* **Shell** — every subprocess has a time limit and process-group kill (#18).

There is **no shared cleanup executor**: each module (`Cleaner.run`, `SDKEngine.remove`, `ProjectEngine`,
`AppEngine`, `ShredEngine`, `DupFinder`, `TrashOps`) implements its own revalidate/execute/record loop.
There is **no `ScanOutcome`/completeness model**: enumerators in `Scanner.swift`, `Projects.swift`,
`Duplicates.swift`, `Shredder.swift` use `errorHandler: { _, _ in true }`, so unreadable folders are skipped
silently.

## 6. Concurrency inventory (grep counts at the audited commit)

| Pattern | Count |
|---|---|
| `Task.detached` | 43 |
| `Task {` | 63 |
| `DispatchQueue` | 14 |
| `NSLock` / `os_unfair_lock` / `DispatchSemaphore` | 16 |
| `@unchecked Sendable` | 15 |
| `nonisolated(unsafe)` | 3 (`SizeCache` in `DirSize.swift`) |
| `static var` | 36 (incl. `MCPServer.cacheScan`, `appCache`, `previews`) |
| `actor` types | 0 |

Swift 6 diagnostics already emitted in Swift 5 mode (baseline build): `Insights.swift:44`, `Updates.swift:195`
(main-actor statics read off-actor), `Overview.swift:52,61` (non-Sendable buffer captured in `@Sendable`).

## 7. Tests

* No XCTest / Swift Testing target. All automated checks live in `SelfTest.swift` and run via `--selftest`.
* The self-test creates fixtures at **fixed paths inside the real home** (`~/.maccleaner-selftest`,
  `~/.cache/maccleaner-selftest-*`) and removes them unconditionally, and it rewrites the real
  `ProtectedPaths` defaults (restored in `defer`). See RISK-003.
* It can be run against a throwaway home: `CFFIXED_USER_HOME=<dir> "Mac Cleaner" --selftest` relocates
  `homeDirectoryForCurrentUser` (verified on this host). It does **not** relocate `UserDefaults`: `cfprefsd`
  still writes `~/Library/Preferences` (verified), so settings need their own isolation.

## 8. Baseline measurements (audit host, M-series, macOS 26.0)

| Measure | Value | How |
|---|---|---|
| Clean Release build | 73.7 s wall | `xcodebuild … -configuration Release CODE_SIGN_IDENTITY=- build` into a scratch SYMROOT |
| Compiler warnings | 4 unique Swift warnings (+1 AppIntents notice) | build log |
| Self-test (real home not touched) | 197 passed / 2 failed, ~7 s | `CFFIXED_USER_HOME=<tmp>` with `Documents`, `Library/Caches`, `.cache`, `.Trash` pre-created |

The two failures under a relocated home are fixture-environment issues, not product regressions:
`Trash refuses a file reached through a linked folder` needs `~/Library/Keychains` to exist, and
`Storage Map keeps a non-ASCII name exactly as stored` compared full paths, which differ as `/tmp/…` vs
`/private/tmp/…` (same folder) when home is under `/private` (RISK-014; fixed on main by #28).
App startup, scan latency and memory were not measured in this pass; see §8a.

## 8a. Performance baseline (M01-01) — `main` at `73e8d3c`, after M00

Same host. Release build, ad-hoc signed, hardened runtime. Run from a shell without Full Disk Access, against the
real home folder (read-only: `--cli bench` deletes nothing; `SizeCache` off). Home folder: ~2.26 million files,
~256 GB. Every M01 change that touches scanning compares against these numbers (MIGRATION_PLAN Stage E: > 10 %
slower needs a recorded reason).

| Measure | Median of 3 | Min | Max main-thread stall | Result | Command |
|---|---|---|---|---|---|
| Junk Files scan | 9.68 s | 9.51 s | 0.011 s | 63 items, 50.8 GB | `--cli bench junk --runs 3` |
| Storage Map (home) | 20.29 s | 16.16 s | 0.069 s | 2,259,389 files, 255.5 GB | `… storage` |
| Duplicates (default folders) | 0.47 s | 0.47 s | 0.012 s | 25 groups, 155.6 MB | `… duplicates` |
| Large & Old Files | 5.29 s | 5.08 s | 0.121 s | 520 files, 73.1 GB | `… large` |
| Projects | 4.66 s | 3.94 s | 0.035 s | 247 projects, 27.6 GB | `… projects` |
| Developer SDKs | 4.11 s | 3.99 s | 0.012 s | 88 items, 37.0 GB | `… sdks` |
| Applications | 9.56 s | 8.71 s | 0.054 s | 65 apps, 76.4 GB | `… apps` |
| System Data | 0.11 s | 0.09 s | 0.010 s | 0 items (no Full Disk Access) | `… system` |
| Overview | 13.17 s | 12.51 s | 0.036 s | — | `… overview` |
| CLI start (`--cli status`) | 0.03–0.04 s warm, 0.89 s first run | | | 17 MB max resident | `/usr/bin/time -l` |

Peak queued folder jobs in the shared walker: 13,218 (storage/large), 16,685 (overview).

**Not measured yet:** window launch to first frame, memory during a full scan, and menu bar idle CPU (these need
the app running in a session with Instruments; planned before M01-05), and anything with Full Disk Access.

## 9. Pull requests

* Merged and relevant: #8 (shared folder walker), #10 (Clear Cache = review), #15 (P1 audit fixes),
  #16 (admin staging P0), #17 (menu bar panel + schedule), #18 (P2 audit fixes), #24 (docs).
* Closed unmerged, superseded by #15: #11, #12, #13, #14.
* Open: #22 (Dependabot, `actions/upload-pages-artifact` 5.0.0).
* Opened from this audit and merged on 2026-11-13 in this order: #28, #27, #26, #29, #30, #31, then #25 (these docs). #26 (Shredder,
  RISK-001), #27 (Duplicates, RISK-002), #28 (self-test isolation, RISK-003/014), #29 (MCP human approval,
  RISK-004), #30 (simulators, RISK-005), #31 (release baseline, RISK-008).
