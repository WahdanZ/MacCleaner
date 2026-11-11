# Mac Cleaner — Roadmap

Order: safety first, then the biggest space wins, then automation, then distribution.
Every phase ends with: build → ad-hoc sign → install → read-only test on a real Mac → screenshot check (light + dark).

## Rules for every phase

- **Confirm before acting:** nothing is deleted without a confirm dialog that lists every item.
- **Recoverable by default:** anything that isn't regenerable goes to the Trash, not permanent delete.
- **Protected Folders:** every new deletion path must respect the list (Phase 0).
- **MCP:** new features get a tool there too, using preview → `confirm: true`. The `mac-cleaner` skill is updated to match.
- **History:** each finished cleanup is recorded for Recent Cleanups.
- **Design:** uses the existing `Palette`, `panel()`, `PageHeader` and `IconTile`, so light/dark works automatically.

---

## Phase 0 — Safety foundation (about 1 hour) ✅ done 2026-11-11

**Goal:** you can't lose something you care about, even by mistake.

1. **Protected Folders** (Settings → Protected):
   - Add or remove folders and files.
   - Enforced in `SafetyGuard`, `TrashGuard`, `AdminGuard`, the Shredder, Large & Old Files, Duplicates, Overview › Downloads and every MCP tool.
   - Protected items show a lock and can't be checked.
2. **Self-test mode** (`Mac Cleaner --selftest`): assertions for every guard. Examples:
   - `~`, `~/Library` and Keychains are refused.
   - Cache roots are allowed.
   - Symlinks are resolved before checking.
   - Protected paths are refused.

   Exits non-zero on failure and runs after every build.

**Done when:** a protected folder can't be selected in any section, `move_to_trash` refuses it over MCP, and the self-test passes.

## Phase 1 — Free the space for real (about 1 hour) ✅ done 2026-11-11

1. **Empty Trash:**
   - Trash size on the Overview and in the sidebar disk card.
   - An "Empty Trash" button with confirm, which runs through Finder (macOS asks once for Automation permission).
2. **Put Back list:**
   - Every item the app moves to the Trash is logged with where it came from.
   - A "Recently Trashed" sheet restores items in one click, as long as they're still in the Trash.
3. **MCP tools:** `trash_status`, `empty_trash` and `restore_from_trash`.

**Done when:** the Trash size matches Finder, emptying frees space as shown by `df`, and a test file round-trips (trash, then put back).

## Phase 2 — Project cleaner (about 1.5 hours) ★ biggest win ✅ done 2026-11-11

New sidebar page **Projects**:

1. **Find projects:** scans `~/IdeaProjects`, `~/StudioProjects`, `~/Documents`, `~/Developer` and `~/Projects` (editable). A project is found by its marker file:
   - `package.json`
   - `pubspec.yaml`
   - `build.gradle(.kts)`
   - `Podfile`
   - `Cargo.toml`
   - `pom.xml`
   - `*.xcodeproj`
   - `pyproject.toml`
2. **Regenerable build output** per project:
   - Deleted directly: `node_modules`, `build/`, `.dart_tool`, `.gradle`, `Pods`, `target/`, `.next`, `.turbo`.
   - Marked REVIEW: `dist/` and `.venv`.
3. **"Last worked on"** = the newest edit outside the build-output folders. Filter: untouched for 1, 3 or 6 months.
4. **Clean:** permanent delete, because all of it is regenerable (`npm install`, `flutter pub get`, a Gradle build). Confirm first, lock protected projects, and record it in history.
5. **MCP tools:** `scan_projects` and `clean_projects`.

**Done when:** the total matches `du` for a sample project, and a cleaned project still builds after `npm install` / `flutter pub get`.

## Phase 3 — Developer SDK manager (about 1.5 hours) ✅ done 2026-11-12

1. **Xcode:**
   - Simulator runtimes by version with sizes, deleted with `xcrun simctl runtime delete`.
   - DeviceSupport by iOS version.
   - Old Archives by date.
2. **Android:**
   - `system-images` per API level, NDK versions, `build-tools`, platforms and emulators.
   - Flags which ones your projects' `compileSdk` / `ndkVersion` use (from Phase 2's scan).
3. **Docker** (only while the daemon runs):
   - `docker system df -v` broken into images, containers, volumes and build cache.
   - A separate prune button for each.
   - Volumes are marked REVIEW, because they hold data.

**Done when:** sizes match `du`, the in-use ones are flagged, and nothing is removed without confirm.

## Phase 4 — Explain "System Data" (about 1.5 hours) ✅ done 2026-11-12

1. **Time Machine local snapshots:** `tmutil listlocalsnapshots /` with dates; delete through the existing admin step (`tmutil deletelocalsnapshots`).
2. **iPhone/iPad backups:** `~/Library/Application Support/MobileSync/Backup`, shown with device name and date from each backup's `Info.plist`. Trash only, and marked REVIEW.
3. **Mail and Messages attachments:** sizes, Reveal, and Trash for chosen items. Needs Full Disk Access; the app explains why if it's missing.

**Done when:** each one shows a size, or a clear "needs Full Disk Access" message.

## Phase 5 — Automation (about 1 hour) ✅ done 2026-11-12

1. **Low-disk alert:**
   - A menu bar icon turns orange or red and a notification appears below a limit you set (default 20 GB).
   - Checked every 30 minutes.
   - An optional "Open at login" setting.
2. **Scheduled clean** (off by default):
   - Weekly, recommended caches only, skipping protected folders, never Trash or Downloads.
   - A notification shows how much was freed.
3. **Settings:** threshold, schedule, and the last automatic run.

**Done when:** a temporary high threshold triggers the alert, and a forced scheduled run cleans only recommended caches.

## Phase 6 — Distribution (needs you) ⏳ script ready: `TEAM_ID=… ./release.sh` (needs a Developer ID certificate)

1. Developer ID signing, hardened runtime and notarization. This needs an Apple Developer account and team ID. It stops Full Disk Access from resetting after each rebuild.
2. Optional: in-app updates (Sparkle) and a DMG for installing on other Macs.

**Done when:** `spctl --assess` passes, and Full Disk Access survives an update.

---

## Extra — Motion ✅ done 2026-11-12

- Pages slide and fade in; the sidebar highlight slides between items, and its icon bounces.
- Animated scan ring for every "working" state.
- List rows appear one after another; the donut sweeps in; numbers roll.
- After every cleanup, a "Freed X GB" card appears with a drawn check mark and a burst of particles.
- Respects Reduce motion.

## Not planned (on purpose)

- **Removing language files or slimming app binaries:** breaks code signatures.
- **Browser history and cookie cleaning:** logs you out everywhere, and it's privacy-sensitive.
- **"RAM cleaner" or "speed boost":** macOS manages memory better on its own.
