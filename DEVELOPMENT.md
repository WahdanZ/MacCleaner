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
"build/Release/Mac Cleaner.app/Contents/MacOS/Mac Cleaner" --selftest
```

It runs 126 checks (the safety rules, the Shredder's hard-link, symlink and changed-file refusals, the Insights forecast and history math, and the updater's version, release, checksum and swap logic) using throwaway files in `~/.maccleaner-selftest` and `~/.cache/maccleaner-selftest-*`, cleans up after itself, and restores your protected list.

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
| `Automation.swift` | Low-disk alert, weekly safe clean, open at login |
| `Updates.swift` | In-app updates from GitHub Releases: daily check, Software Update window, download, checks, swap and relaunch |
| `CLI.swift`, `MCPServer.swift`, `Integrations*.swift` | Command line, MCP server, AI app setup |
| `Intro.swift` | Welcome tour |
| `SelfTest.swift` | Safety self-test |

Design decisions and the UI audit are in [docs/DESIGN.md](docs/DESIGN.md). The feature history is in [ROADMAP.md](ROADMAP.md).

---

## Safety rules

These are the project's core promise. Keep them true in the app, the CLI and the MCP server.

1. **Review first.** Nothing is removed until the user has seen every item. In the app this is the Review sheet; in the CLI you type `yes` (or pass `--yes`); over MCP a tool returns a preview until it is called again with `confirm: true`.
2. **Recoverable by default.** Only regenerable data (caches, build output, SDK downloads) is deleted permanently. The user's own files go to the Trash and are logged so Put Back can restore them.
3. **Guards decide, every time.** The engines re-check the guards right before acting, even if the UI already did:
   - **`SafetyGuard`:** permanent deletion only inside known cache roots. Symlinks are resolved first, and root folders themselves are never removed.
   - **`TrashGuard`:** never the home folder, Library, Documents or similar structural folders, and never Keychains, Mail, the Messages database or `.ssh`.
   - **`AdminGuard`:** the password step only touches direct children of a fixed list of system folders. Never `com.apple.*`.
   - **`ProtectedPaths`:** folders and files the user protected. Every guard refuses them and anything inside them. AI tools may add protection but never remove it.
   - **`ShredEngine.reason`:** the Shredder uses the `TrashGuard` rules on both the path as given and its on-disk spelling, and only inside the home folder. It refuses symlinks and files with more than one hard link (overwriting one would wipe the other names), opens each file with `O_NOFOLLOW` and checks it is still the file that was approved (device and inode). A failed write or flush is an error: that file is kept and not counted. The overwrite is best effort on SSDs and APFS, and the UI says so.
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
5. **MCP and CLI:** add a read-only tool and a destructive tool with the preview → `confirm: true` pattern, then a CLI command that maps to them.
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

| Read-only | Changes something (preview, then `confirm: true`) |
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

Push a version tag. The [Release workflow](.github/workflows/release.yml) builds, self-tests, packs a DMG with a SHA-256 checksum and publishes a GitHub Release:

```bash
git tag v1.1.0
git push origin v1.1.0
```

- **Version:** taken from the tag (`v1.1.0` becomes `1.1.0`). A tag with a suffix such as `v1.2.0-beta.1` becomes a pre-release.
- **Release notes:** generated from the commits since the last tag, with install steps on top.
- **Test build:** *Actions › Release › Run workflow* builds a DMG as a download on the run's page, without publishing.
- **In-app updates** read the latest non-pre-release from the GitHub API, so keep the asset names `MacCleaner-<version>.dmg` and `MacCleaner-<version>.dmg.sha256`; without the checksum file the app refuses to install. Before installing, the app checks:
  - the SHA-256;
  - that the app inside has the same app ID and the advertised version;
  - `codesign --verify --strict`;
  - once releases are Developer ID–signed, that the same team signed it.

  A small script then waits for the app to quit, swaps the bundle (putting the old one back on failure) and reopens it. If the app's folder isn't writable, or the app runs from a disk image, it offers the download page instead.

### Signing and notarization (optional)

Without secrets the DMG is ad-hoc signed, and users allow it once in *System Settings › Privacy & Security*. To ship a signed and notarized DMG, add these repository secrets (*Settings › Secrets and variables › Actions*). This needs a paid Apple Developer account.

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

With all five secrets set, the workflow signs with hardened runtime, notarizes and staples the app and the DMG, and checks the DMG with Gatekeeper. The signing keychain is deleted at the end of each run.

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
