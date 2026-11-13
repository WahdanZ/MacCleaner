# Developing Mac Cleaner

Everything you need to build, change and release Mac Cleaner. If you only want to use the app, see the [README](README.md).

- [Build and run](#build-and-run)
- [How the app is put together](#how-the-app-is-put-together)
- [Safety rules (read before changing anything that deletes)](#safety-rules)
- [Adding a cleanup feature](#adding-a-cleanup-feature)
- [Command line reference](#command-line-reference)
- [MCP server reference](#mcp-server-reference)
- [Continuous integration](#continuous-integration)
- [Releasing](#releasing)
- [Contribution rules](#contribution-rules)

---

## Build and run

**Requirements:** macOS 14 or later, Xcode 16 or later. No third-party dependencies.

```bash
git clone https://github.com/WahdanZ/MacCleaner.git
cd MacCleaner
./build.sh
```

`build.sh` does four things:
1. Builds a Release version.
2. Runs the safety self-test, and stops if any check fails.
3. Signs the app ad-hoc.
4. Installs it to `/Applications/Mac Cleaner.app`.

You can also open `MacCleaner.xcodeproj` in Xcode and press Run. The project uses a synchronized folder, so new `.swift` files in `MacCleaner/` are picked up automatically.

**Run the self-test on its own:**

```bash
scripts/selftest.sh "build/Release/Mac Cleaner.app"
```

It runs about 200 checks (the safety rules, the audit fixes, the scheduled clean timing, the Insights forecast and history math, the updater's version, release, signature, checksum and swap logic, and the fast folder walk against the old one). The script gives it a fresh, empty home folder (`CFFIXED_USER_HOME` set to a `mktemp -d` folder that is deleted afterwards), so it never reads or changes your own files. The Protected list is kept in a throwaway settings domain for the run. Run directly (`--selftest`) it refuses to start in your real home folder unless `MACCLEANER_SELFTEST_ALLOW_REAL_HOME=1` is set.

> Ad-hoc signed builds get a new signature on every rebuild, so macOS may ask for Full Disk Access again after each build. A Developer ID build avoids that (see [Releasing](#releasing)).

---

## How the app is put together

**One binary, four modes:**

| Launch | Mode |
|---|---|
| `Mac Cleaner` | The window app and the menu bar item |
| `Mac Cleaner --cli <command>` | The `mac-cleaner` command line |
| `Mac Cleaner --mcp` | MCP server on stdio for AI assistants |
| `Mac Cleaner --selftest` | Safety self-test, exits non-zero on failure |

All four share the same engines and guards, so a rule enforced in one place applies everywhere.

| File | What it does |
|---|---|
| `MacCleanerApp.swift` | Entry point, scenes, menus, settings migration from the old app ID |
| `Shell.swift` | Window: sidebar navigation, page routing, Settings window |
| `Theme.swift`, `Motion.swift` | Design tokens (colours, spacing, radii, type) and animation roles |
| `Overview.swift` | Dashboard: storage donut, scan, recommendations, quick tools |
| `Insights.swift` | Insights card (reclaimed per week, free-space trend and forecast, junk by category) and `FreeSpaceLog`, one free-space reading per day in `free-space.json` |
| `Review.swift`, `ReviewBuilders.swift` | The Review Cleanup sheet and the item list each feature passes to it |
| `SafetyGuard.swift` | `SafetyGuard`, `TrashGuard`, `ProtectedPaths` |
| `Scanner.swift`, `CleanTarget.swift`, `CleanerModel.swift`, `ContentView.swift`, `Treemap.swift` | Junk Files: cache locations, measuring, cleaning, the space map |
| `Projects*.swift`, `DevSDK*.swift`, `DevTools+.swift` | Developer Tools: project build files; Xcode, Android, language versions, Homebrew and Docker |
| `LargeFiles.swift`, `Duplicates*.swift`, `DiskMap*.swift` | Large & Old Files, Duplicates, Storage Map |
| `AppsModel.swift`, `AppsView.swift` | Applications: scan, leftovers, uninstall, `AdminGuard` / `AdminStep` |
| `SystemData.swift`, `SystemItems.swift`, `Shredder.swift` | System Data, Startup & Extensions, Shredder |
| `Trash*.swift`, `History.swift` | Trash size, empty, Put Back log; cleanup history |
| `Automation.swift` | Low-disk alert, scheduled safe clean (daily or weekly, catches up after sleep), open at login |
| `MenuBarPopover.swift` | Menu bar panel: free space, Clean Now, last and next clean, recent cleanups; optional text next to the icon |
| `Updates.swift` | In-app updates from GitHub Releases: daily check, Software Update window, download, checks, swap and relaunch |
| `CLI.swift`, `MCPServer.swift`, `Integrations*.swift` | Command line, MCP server, AI app setup |
| `Intro.swift` | Welcome tour |
| `SelfTest.swift` | Safety self-test |
| `DirSize.swift` | Fast folder sizing and listing with `getattrlistbulk`, used by every scan |
| `Bench.swift` | `--cli bench`: times every scan and the longest main-thread stall |
| `SharedFile.swift` | Locked read-change-write for the JSON files the window and the CLI/MCP process share (Put Back log, history) |

### Scanning and threads

Every scan engine is synchronous and runs off the main thread: the `@MainActor` models start it with `Task.detached` or a task group and only copy the result (and throttled progress) back to the main actor. Keep it that way; a scan must never run inline in a model method. `--cli bench` reports the longest main-thread stall during each scan so this stays checked.

- **`WalkPool`** (in `DirSize.swift`) is a fixed set of threads shared by every folder walk. Each folder is one job, so a single huge folder (a build cache with 250k files, say) is read by all the threads instead of one. Jobs must not start another walk and wait for it.
- **Folder sizes** go through `Scanner.allocatedSize`, which uses `DirSize`: one `getattrlistbulk` call returns a batch of entries with their allocated size. It reports the same bytes as the old `FileManager` enumerator (`Scanner.allocatedSizeSlow`, kept for the self-test): hidden files and package contents count, AppleDouble `._` files do not (FileManager never lists them), symlinks are never followed. Build child URLs from path strings with `DirSize.fileURL(path, isDirectory:)` (raw bytes, `URL(fileURLWithFileSystemRepresentation:)`): `appendingPathComponent` on a URL derived from the home folder URL (macOS 26) and `URL(fileURLWithPath:)` (macOS 15) can return a decomposed (NFD) path for non-ASCII names, which would no longer match FileManager's paths, and the guards', byte for byte.
- **Storage Map**, **Large & Old Files** and **Projects** walk folders on the same pool. Storage Map and Large & Old Files read entries with `DirSize.forEachEntry` and make a name, URL or date only for folders and the files they keep, not for every file they count. Large & Old Files keeps the enumerator's rules: no hidden files, no package contents, not ~/Library. Results are sorted with a path tie-break, so the order doesn't depend on which thread finished first.
- **Junk Files** and **Applications** measure up to `DirSize.width` locations or apps at once. One Applications scan shares an `AppScanner.Batch`, so `pkgutil --pkgs` runs once, each Library folder is listed once and each launch agent plist is read once.
- **Duplicates** lists each root on its own thread and hashes same-size groups in parallel (size → first/last 64 KB → full SHA-256). **Projects** finds each project's last edit in parallel, only for projects with build output. **Developer SDKs** runs its Xcode, Android, Homebrew and Docker sections side by side.
- **`SizeCache`** keeps folder sizes for a minute, so scans run one after another (Overview, then Applications or Junk Files) don't walk the same folders twice. Every engine function that deletes, moves to the Trash or restores clears it before and after (`SizeCache.clear(); defer { SizeCache.clear() }`); add that line to any new one. Changes made outside the app show up once an entry is a minute old.
- **Progress** reaches the main actor at most about 8 times a second.

To measure, build Release and run `"build/Release/Mac Cleaner.app/Contents/MacOS/Mac Cleaner" --cli bench --runs 3` (or name scans: `junk storage duplicates large projects sdks apps system overview`). `--dump DIR` writes each scan's ids and sizes so two builds can be diffed; `bench sizer` compares `DirSize` with the old walk on your home and Library folders. Bench turns `SizeCache` off unless you pass `--cache`. It only reads.

Design decisions and the UI audit are in [docs/DESIGN.md](docs/DESIGN.md). The feature history is in [ROADMAP.md](ROADMAP.md).

---

## Safety rules

These are the project's core promise. Keep them true in the app, the CLI and the MCP server.

1. **Review first.** Nothing is removed until the user has seen every item. In the app this is the Review sheet; in the CLI you type `yes` (or pass `--yes`); over MCP a tool returns a preview with a single-use `preview_id`, and only a call with `confirm: true` and that id runs. The id expires after 10 minutes and is tied to the exact items, so a confirm that resolves to a different app, path or selection is refused. The Review sheet runs exactly the rows it showed (captured when it opened), never the screen's live selection.
2. **Recoverable by default.** Only regenerable data (caches, build output, SDK downloads) is deleted permanently. The user's own files go to the Trash and are logged so Put Back can restore them.
3. **Guards decide, every time.** The engines re-check the guards right before acting, even if the UI already did:
   - **`SafetyGuard`:** permanent deletion only inside known cache roots. Symlinks are resolved first, and root folders themselves are never removed.
   - **`TrashGuard`:** never the home folder, Library, Documents or similar structural folders, and never Keychains, Mail, the Messages database or `.ssh`.
   - **`AdminGuard`:** the password step only touches direct children of a fixed list of system folders. Never `com.apple.*`.
   - **`AdminStep`:** the root script stages items in a new `mktemp -d` folder under `/private/var/tmp` (random name, mode 700), never in a folder anyone else can create or reach first. It hands back only that folder (`chown` without `-R`); the items inside keep their system owner. Never add a recursive `chown`, `chmod` or `mkdir -p` on a predictable path to a root script.
   - **`ProtectedPaths`:** folders and files the user protected. Every guard refuses them and anything inside them. AI tools may add protection but never remove it.
4. **Honest history.** Each cleanup is recorded as `deleted` or `trashed`, with the measured free-space change when there is one. Never report space as freed when it only went to the Trash.
5. **Self-test.** Every guard has self-test checks. `build.sh` and CI refuse a build that fails one.

---

## Homebrew

Homebrew items run `brew` itself, never a plain delete, so Homebrew's records stay correct. Only three command shapes are allowed (`SDKEngine.brewArgsValid`): `brew uninstall <name>`, `brew uninstall --cask <token>` and `brew cleanup`. Auto-update and install cleanup are turned off for these runs. Mac Cleaner never passes `--ignore-dependencies`, so brew still refuses to remove a formula another formula needs.

## Adding a cleanup feature

A checklist that keeps a new feature consistent with the rest:

1. **Engine:** put the logic in a synchronous `enum …Engine` that the window, CLI and MCP can all call off the main thread.
2. **Guards:** before deleting or moving anything, call the right guard (`SafetyGuard.isAllowed`, `TrashGuard.reason`, `AdminGuard.isAllowed`) inside the engine, not only in the UI.
3. **Review:** add a builder to `ReviewBuild` that lists every item with its path, size, action (`trash` / `delete` / `command` / `adminTrash`), risk and blocked reason, and open it with `review.present(…)`.
4. **History:** call `HistoryStore.shared.add(…, outcome: .deleted | .trashed, measuredFreeChange:)`.
5. **MCP and CLI:** add a read-only tool and a destructive tool with the preview → `confirm: true` + `preview_id` pattern (`withPreview` / `approve` with a `plan` digest of the exact items), then a CLI command that maps to them.
6. **Self-test:** add checks for every refusal path (protected, outside allowed folders, symlinks).
7. **UI:** use the tokens in `Theme.swift` (`Palette`, `Space`, `Radius`, `.panel()`), native controls, and the `Motion` roles so Reduce Motion is respected. Give custom controls an accessibility label and value.

---

## Command line reference

Install the launcher with `"/Applications/Mac Cleaner.app/Contents/MacOS/Mac Cleaner" --cli install`. It goes into `/opt/homebrew/bin`, `/usr/local/bin` or `~/.local/bin`, whichever is writable. `mac-cleaner uninstall-command` removes it.

| Command | What it does |
|---|---|
| `status` | Free, used and total disk space |
| `scan [--min-mb N]` | Scan 340+ cache locations (read-only) |
| `clean (--recommended \| ID…)` | Delete caches (they rebuild) |
| `usage [PATH] [--limit N]` | Largest folders and files inside a folder |
| `dupes [PATH…] [--min-mb N]` | Duplicate files by content |
| `apps [QUERY] [--sort size\|name\|last_used\|cache]` | Installed apps with sizes |
| `app NAME` | An app's data, helpers, drivers and caches |
| `app-cache NAME` | Clear one app's cache |
| `uninstall NAME [--shared]` | Uninstall an app with its leftovers (to Trash) |
| `projects [PATH…] [--idle MONTHS]` | Build files in code projects |
| `clean-projects (--all \| ID…) [--idle MONTHS]` | Delete project build files |
| `sdks [--group Xcode\|Android\|Languages\|Homebrew\|Docker]` | Simulators, Android SDK parts, language versions, Homebrew formulae and apps, Docker data |
| `remove-sdks ID…` | Remove SDK items |
| `system-data` / `remove-system-data ID…` | Snapshots, backups, Mail and Messages attachments |
| `trash` / `empty-trash` / `put-back (--all \| ID…)` | Trash status, empty, restore |
| `protected` / `protect PATH…` | List or add protected paths |
| `trash-files PATH…` | Move files to the Trash |
| `tools` / `tool NAME '{json}'` | List or call MCP tools directly |
| `mcp` | Run the MCP server |

- **Flags:** `--json` prints machine-readable output; `--yes` skips the question.
- **Exit codes:** `0` done, `1` error or cancelled, `2` nothing changed because no one could confirm (no keyboard and no `--yes`), `64` usage error.

---

## MCP server reference

Manual configuration for any MCP client:

```json
{
  "mcpServers": {
    "mac-cleaner": {
      "command": "/Applications/Mac Cleaner.app/Contents/MacOS/Mac Cleaner",
      "args": ["--mcp"]
    }
  }
}
```

| Read-only | Changes something (preview, then `confirm: true` with its `preview_id`) |
|---|---|
| `disk_status`, `scan_caches`, `disk_usage`, `find_duplicates`, `list_apps`, `app_details`, `scan_projects`, `list_sdks`, `system_data`, `trash_status`, `list_protected` | `clean_caches`, `clear_app_cache`, `uninstall_app`, `clean_projects`, `remove_sdks`, `remove_system_data`, `empty_trash`, `restore_from_trash`, `move_to_trash`, `protect_paths` (adds only) |

The server's `instructions` tell the assistant to show every item to the user and never to pass `confirm: true` on its own. *Settings › Integrations* writes this configuration for Claude Code, Claude Desktop, Cursor, Codex, VS Code, Windsurf and Gemini. It backs up each file first, and can also install a skill with the same rules.

---

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and every pull request:

1. Builds a Release version with the Xcode that ships on the runner (Xcode 16), which also proves the macOS 26-only APIs are correctly guarded.
2. Runs the safety self-test.
3. Checks the command line: `help`, `status --json`, `tools`, and that a delete command without `--yes` and without a keyboard changes nothing.
4. Starts the MCP server and checks it lists at least 21 tools.
5. Uploads the app as a zip on the run's page.

---

## Website

The product page lives in [`website/`](website/) (one `index.html`, one `style.css`, icons and the share image) and is published to GitHub Pages at <https://wahdanz.github.io/MacCleaner/> by [`.github/workflows/pages.yml`](.github/workflows/pages.yml).

- **Build:** [`scripts/build-site.sh`](scripts/build-site.sh) copies `website/` and `docs/screenshots/` into `_site/` and fills `{{VERSION}}` and `{{DMG_SIZE}}` from the newest release tag, so the download button always points at the latest DMG without any JavaScript.
- **When it publishes:** on pushes to `main` that touch `website/`, `docs/screenshots/` or the workflow, and after every release (the Release workflow starts it, because GitHub doesn't let a release made by a workflow trigger other workflows).
- **Rules:** no scripts, trackers, web fonts or third-party requests (a Content-Security-Policy meta tag enforces it). Screenshots come from the app with personal names blurred.
- **Preview locally:** `scripts/build-site.sh /tmp/site && python3 -m http.server -d /tmp/site 8765`.
- **One-time setup:** *Settings › Pages › Build and deployment › Source: GitHub Actions*.

---

## Releasing

### Publish a release

Releases are always Developer ID–signed, notarized and verified; there is no unsigned release path.

1. **Tag.** Push a version tag. The [Release workflow](.github/workflows/release.yml) refuses to run without the five signing and notarization secrets below. With them it builds with hardened runtime, self-tests, notarizes and staples the app and the DMG, writes the SHA-256, runs [`scripts/verify-release.sh`](scripts/verify-release.sh), and creates a **draft** release. A draft is not public, not "latest" and not offered by the in-app updater.
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
2. **Sign for in-app updates.** On your Mac (the Ed25519 release key lives only in your keychain):
   ```bash
   TEAM_ID=YOUR_TEAM_ID scripts/sign-release.sh v1.1.0
   ```
   It downloads the draft's DMG, verifies it again (checksum, Developer ID team, notarization ticket, Gatekeeper, hardened runtime, entitlements, bundle ID, version), signs it, verifies the signature against the public key built into the app (`releasePublicKey` in `Updates.swift`), and uploads `MacCleaner-<version>.dmg.sig`. If any check fails, nothing is signed or uploaded.
3. **Publish.** Check the draft on GitHub, then:
   ```bash
   TEAM_ID=YOUR_TEAM_ID scripts/sign-release.sh v1.1.0 --publish
   ```
   This publishes the draft and starts the website deploy (not for pre-releases).

- **Version:** taken from the tag (`v1.1.0` becomes `1.1.0`); the verification checks the app inside has exactly that version. A tag with a suffix such as `v1.2.0-beta.1` becomes a pre-release.
- **Release notes:** generated from the commits since the last tag, with install steps on top.
- **Test build:** *Actions › Release › Run workflow* builds a DMG as a download on the run's page and never publishes. Without the secrets it is ad-hoc signed and verified in `--dev` mode, which says plainly that it is not releasable.
- **Release key:** create it once with `swift scripts/release-key.swift init`, put the printed public key in `Updates.swift` (`releasePublicKey`) and back the key up. `swift scripts/release-key.swift verify FILE` checks a `.sig` without the keychain.
- **In-app updates** read the latest published non-pre-release from the GitHub API, so keep the asset names `MacCleaner-<version>.dmg`, `.dmg.sha256` and `.dmg.sig`. A release without a valid `.sig` is never offered. Before installing, the app checks:
  - the Ed25519 signature, then the SHA-256;
  - that the app inside has the same app ID and exactly the advertised version (no downgrades are offered);
  - `codesign --verify --deep --strict`;
  - the same Developer ID team as the running copy (or `pinnedTeamID`), and Gatekeeper when signed.

  A small script then waits for the app to quit, swaps the bundle (putting the old one back if the swap fails) and reopens it. If the app's folder isn't writable, or the app runs from a disk image, it offers the download page instead. **Not covered:** if the new version installs but fails to start, it is not rolled back automatically.

### What verify-release checks

| Check | CI (every PR, `--dev`) | Release workflow | `sign-release.sh` |
|---|---|---|---|
| SHA-256 matches `.sha256` | ✓ | ✓ | ✓ |
| Ed25519 `.sig` by the release key | — (no key on CI) | — (added later) | ✓ |
| Bundle ID and exact version | ✓ | ✓ | ✓ |
| Deep, strict code signature | ✓ (ad-hoc) | ✓ | ✓ |
| Hardened runtime on | ✓ | ✓ | ✓ |
| Entitlements exactly `automation.apple-events` (no `get-task-allow`) | ✓ | ✓ | ✓ |
| Developer ID team, secure timestamp | — | ✓ | ✓ |
| Notarization ticket stapled (app and DMG) | — | ✓ | ✓ |
| Gatekeeper accepts app and DMG | — | ✓ | ✓ |

The Release build setting has hardened runtime on and doesn't inject `get-task-allow`. Debug builds and `./build.sh` stay ad-hoc for local development.

### Signing and notarization secrets

A release needs these repository secrets (*Settings › Secrets and variables › Actions*) and a paid Apple Developer account. Without them a tag build fails and nothing is published.

| Secret | What it is |
|---|---|
| `MACOS_CERT_P12` | Your **Developer ID Application** certificate, exported as `.p12` and base64-encoded |
| `MACOS_CERT_PASSWORD` | The password you gave the `.p12` |
| `APPLE_TEAM_ID` | Your 10-character team ID ([developer.apple.com/account](https://developer.apple.com/account) › Membership) |
| `APPLE_ID` | The Apple ID email used for notarization |
| `APPLE_APP_PASSWORD` | An app-specific password ([account.apple.com](https://account.apple.com) › Sign-In and Security) |

To get the certificate and add the secrets:

1. Create the certificate in Xcode: *Settings › Accounts › Manage Certificates › + › Developer ID Application*.
2. In **Keychain Access**, right-click *Developer ID Application: …* under *My Certificates*, choose **Export**, and save `cert.p12` with a password.
3. Add the secrets with the GitHub CLI, or paste them on the web page:
   ```bash
   base64 -i cert.p12 | gh secret set MACOS_CERT_P12
   gh secret set MACOS_CERT_PASSWORD
   gh secret set APPLE_TEAM_ID
   gh secret set APPLE_ID
   gh secret set APPLE_APP_PASSWORD
   ```
4. Delete `cert.p12` from your disk.

With all five secrets set, the workflow signs with hardened runtime and a secure timestamp, notarizes and staples the app and the DMG, and verifies the result. The signing keychain is deleted at the end of each run. The workflow's token can create releases (`contents: write`) but only as drafts; publishing happens from your Mac.

### Build a DMG on your Mac

**Signed and notarized** (needs the certificate in your keychain):

1. Store notarization credentials once:
   ```bash
   xcrun notarytool store-credentials maccleaner-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```
2. Run:
   ```bash
   TEAM_ID=YOUR_TEAM_ID ./release.sh
   ```

**Unsigned, for testing:**

```bash
./build.sh
scripts/make-dmg.sh "build/Release/Mac Cleaner.app" "build/MacCleaner-dev.dmg"
```

### App ID

The app ID is `io.github.wahdanz.maccleaner`; version 1.0.0 used `local.maccleaner`. On the first launch under the new ID, `SettingsMigration` copies the old settings once and merges protected paths (never dropping any). If you fork the project, change `PRODUCT_BUNDLE_IDENTIFIER` to an ID you own.

---

## Contribution rules

- **Keep the safety rules above true,** and add self-test checks for any new deletion path.
- **No personal data in the repository:** no real file names, folder names, disk sizes or app lists from your Mac in code, docs, tests or screenshots. Use made-up examples.
- **Screenshots** for docs come from the welcome tour or from a test account, never from your own files.
- **Commits:** small and focused. CI must pass before merging.
