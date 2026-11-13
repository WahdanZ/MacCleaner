# MacCleaner 2.0 Roadmap

Baseline commit `8b483b2`. Architecture: `docs/architecture/ARCHITECTURE_V2.md`. Risks: `RISK_REGISTER.md`.
Feature status: `FEATURE_MATRIX.md`. Each task is one small PR unless noted. Release engineering, tests and docs
are continuous in every milestone.

Status values: `todo` · `in progress` · `in review (#N)` = open PR, **not on `main`** · `done` = merged · `blocked`.

---

## M00 — Audit and safety

**Goal.** Safe existing behaviour and a verified baseline before any new destructive feature.
**Current.** P0/P1/P2 audit fixes merged (#15, #16, #18). Remaining defects: RISK-001…005.
**Dependencies.** None. **Risk.** Touches destructive code; every change gets a failing-first regression check.

| Task | Deliverable | Acceptance | Status |
|---|---|---|---|
| M00-00 | Audit docs + planning docs | 10 docs in `docs/` with commit SHA | in review (#25) |
| M00-01 | Shredder fail-closed + races (RISK-001) | No un-overwritten data deleted; growth, replacement, folder/parent swaps, edits after review handled; partial results reported; residual limits documented | in review (#26) |
| M00-02 | Duplicate read failures (RISK-002) | Errors, truncation, growth never match; valid short reads still match; no scan slowdown | in review (#27) |
| M00-03 | Self-test isolation (RISK-003) | Refuses real home; temp home; in-memory settings; user's list verified unchanged; concurrent runs pass | in review (#28) |
| M00-04 | MCP human approval + identity digest (RISK-004) | Confirm without Mac Cleaner-owned human approval refused; `empty_trash` digest includes listed item identities; replaced-at-same-path item refused | in review (#29) |
| M00-05 | Simulators review-only (RISK-005) | `xcode.sims` not recommended, review row says app data is lost; only reviewed, still-unavailable devices deleted | in review (#30) |
| M00-06 | RISK-014 Storage Map check under `/private` home | Root cause: `/tmp` vs `/private/tmp` spelling; check compares name bytes + identity | in review (#28) |
| M00-07 | Release baseline (RISK-008) | Hardened runtime in project Release config; release job fails if signing expected but missing; doc for `.sig` | in review (#31) |

**Verification.** `scripts/selftest.sh` locally and in CI; Release build; CLI/MCP smoke.

## M01 — Swift 6 and core architecture

**Goal.** Package boundaries, shared contracts, real test targets, Swift 6 mode. No feature change.
**Dependencies.** M00. **Risk.** Large moves → strictly one module per PR, self-test after each.

| Task | Deliverable | Acceptance |
|---|---|---|
| M01-01 | Performance baseline | Launch, Junk scan, Storage Map, duplicates, menu-bar idle recorded in `CURRENT_STATE.md` |
| M01-02 | `MacCleanerKit` package + `Core` + XCTest | Guards and `ProtectionPolicy` with injected home; ≥ the current guard checks as XCTests |
| M01-03 | `FileIdentity`, `ScanOutcome`, `CleanupPlan`, `CleanupApproval`, `ProgressEvent` | Unit tests; `Sendable` |
| M01-04 | `CleanupExecutor` actor | Revalidation tests: identity swap, symlink swap, newly protected → skipped and reported |
| M01-05 | Strict concurrency `complete`, fix diagnostics | 0 concurrency warnings; every `@unchecked Sendable` justified |
| M01-06…11 | Move caches, projects, SDKs, apps, duplicates, system data onto executor | Per-module tests; UI unchanged (screenshots compared) |
| M01-12 | Swift 6 mode: Core → Persistence → Platform → Features → app | Builds and all tests green after each |
| M01-13 | `AutomationPolicy` (RISK-017) | Scheduled clean runs only under an explicit, versioned, revocable policy; a code change that adds a category does not widen an enabled policy; runs recorded with `approvedBy: .standingPolicy` |

## M02 — Cleanup and recovery

| Task | Deliverable | Acceptance |
|---|---|---|
| M02-01 | `ScanOutcome` in UI/CLI/MCP (CLEAN-10) | Unreadable folders listed; FDA link; persists across navigation |
| M02-02 | Session history + restore (CLEAN-07) | Sessions with targets, errors, recovery locations; freed vs trashed separated; v1 history migrated |
| M02-03 | Exclusions with precedence (CLEAN-08) | Global/scan/module exclusions; precedence table tested |
| M02-04 | Universal Clipboard archives (CLEAN-09) | Direct UUID-named regular files only; never preselected; identity revalidated; unknown entries ignored |
| M02-05 | Multi-volume Trash (CLEAN-04) | Per-volume `.Trashes/<uid>` with access status |
| M02-06 | Trash-first project cleanup (CLEAN-05) | Setting; history shows trashed |
| M02-07 | Mail attachments: Apple Mail, Outlook, Spark (CLEAN-03) | Only cache/download folders; messages and accounts untouched |
| M02-08 | Expanded system junk (CLEAN-02) | Broken prefs (unparseable plists, review-only), orphaned files (no matching installed bundle id, review-only), language resources (analysis-only for signed apps) |
| M02-09 | Smart Scan (CLEAN-01) | Runs module scans concurrently with progress; consolidated review; no combined unreviewed action |

## M03 — Applications 2.0

APPS-01 unused filters (unknown ≠ unused) · APPS-02 Reset app (prefs/caches/support/container; app groups and
Keychain excluded) · APPS-03 updater (Sparkle appcast read-only check, Homebrew `outdated`, App Store link;
never silent install) · APPS-04 uninstaller on executor with audit log · APPS-05 extensions (`pluginkit -m`,
`systemextensionsctl list`, open System Settings to change).

## M04A — System health (menu bar)

Re-verify #17 schedule across timezone changes (`NSSystemTimeZoneDidChange`) · CPU/memory/pressure/swap
(`host_statistics64`, `vm.swapusage`) · battery (IOPowerSources; health/cycles/temperature via `AppleSmartBattery`
where readable, else "unavailable") · network rates (`getifaddrs`) · GPU (IOAccelerator utilisation where exposed)
· devices (mounted volumes, `NSScreen`) · alerts with cooldown · dismissible recommendations · helper decision
(D-007). Budget: < 0.5 % CPU idle, sampling ≥ 2 s, paused when panel closed.

## M04B — Clipboard manager

CLIP-01…12 as specified: opt-in monitor (`changeCount` poll at 0.5–1 s, skip `org.nspasteboard.ConcealedType`,
`TransientType`, `AutoGeneratedType`), encrypted SQLite store (D-008), search, quick panel with configurable
hotkey (Carbon `RegisterEventHotKey`, conflict detection), optional paste (Accessibility permission), pins/snippets,
private mode, app exclusions, storage view, tests incl. corruption recovery and 50 MB payload caps.

## M05 — Privacy and permissions

Browser privacy (refuse while browser running; history/cookies/cache separately; never bookmarks/passwords) ·
extension inventory · TCC overview (read-only, FDA required, marked incomplete otherwise) · Wi-Fi list +
forget via `networksetup` with admin prompt.

## M06 — Performance and maintenance

Startup disable vs delete · resource monitor (no auto-kill) · maintenance tasks with honest impact text
(DNS flush, `lsregister` rebuild, `mdutil -E`, `tmutil thinlocalsnapshots`, `diskutil verifyVolume`) ·
file associations (Launch Services read + `NSWorkspace.setDefaultApplication` on 12+) · scheduled scans.

## M07 — Advanced files

APFS clone consolidation (`clonefile` + `renamex_np(RENAME_SWAP)`, metadata copy, verify, rollback) ·
universal binary analysis (Mach-O fat headers) · restricted thinning (D-009) · Storage Map volumes/export/type
breakdown · Large & Old filters · Shredder modes documentation.

## M08 — Malware protection

Signature DB (hash + path/plist patterns) with signed updates, XProtect `XProtect.yara`/`XProtect.plist` read
where present, persistence heuristics (LaunchAgents with unsigned/temp executables), Quick/Balanced/Deep,
confirmed vs heuristic separation, reversible quarantine (move to app-owned 0700 store + strip exec bit +
manifest), false-positive corpus tests.

## M09 — UX, testing, production release

Accessibility audit (VoiceOver, keyboard, Reduced Motion) · localization (String Catalog; en, de, ar with RTL,
then the 11 others) · UI tests · benchmarks vs baseline · macOS 14 manual run · signed + notarized + stapled
DMG · Homebrew cask update · docs match reality.
