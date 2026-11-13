# Test Strategy

## 1. Today

* `--selftest` (`MacCleaner/SelfTest.swift`): ~200 executable checks over guards, review mapping, schedule,
  admin staging script, updater verification, duplicates, Storage Map, Shredder.
* CI (`ci.yml`, `macos-15`): build, self-test, read-only CLI, MCP `tools/list`.

## 2. Isolation rule (SAFE-02)

Tests must never read or modify the developer's real home, settings or Trash.

* `scripts/selftest.sh` creates a fresh `mktemp -d` home, pre-creates the standard folders, and runs
  `CFFIXED_USER_HOME=<that dir> "Mac Cleaner" --selftest`. Foundation then resolves
  `homeDirectoryForCurrentUser` inside it (verified on macOS 26). `UserDefaults` is **not** moved
  (`cfprefsd` keeps writing `~/Library/Preferences`), so the self-test points `ProtectedPaths.store` at a
  throwaway domain (`io.github.wahdanz.maccleaner.selftest`) that it empties at the end.
* `SelfTest.run` refuses to run when the home it sees is the account's real home (from `getpwuid`), unless
  `MACCLEANER_SELFTEST_ALLOW_REAL_HOME=1` is set explicitly.
* New fixtures are created with `withIntermediateDirectories: false` under a unique name and removed only if
  this run created them.
* XCTest targets (M01) inject the home/root into `ProtectionPolicy` instead of relying on the process home.

## 3. Categories and where they live

| Category | Location | Examples |
|---|---|---|
| Unit | `Packages/MacCleanerKit/Tests/CoreTests` (M01) | risk classification, policy precedence, digest, retention, parsers, locale-independent formatting |
| Integration | `PlatformTests` | real files in a temp dir: executor, Trash, restore, identity revalidation, history sessions |
| Security / adversarial | `PlatformTests/Adversarial` + self-test | symlinks, hard links, protected nested folders, unreadable roots, identity swaps between plan and run, locked files, long paths, sparse files, read failures |
| UI | `MacCleanerUITests` (M09) | navigation, review sheet, keyboard, VoiceOver labels, clipboard panel |
| Performance | `XCTMetric` + `--cli bench` | 100k-file tree walk, 10k-file duplicates, menu bar idle |
| End-to-end | self-test + UI tests | scan → review → execute → history → restore |

## 4. Rules

* Every fix to a destructive path ships with a regression check that fails on the old code.
* Locale: tests set `Locale(identifier:)` explicitly; never assert on a hard-coded thousands separator.
* Report results as **Verified by CI**, **Verified locally**, **Not executed**, or **Blocked** — never "passed"
  for a skipped suite.

## 5. Known gaps

* No macOS 14 runner on GitHub; macOS 14 is verified manually before release (M09).
* Privileged admin step is tested through a non-root `osascript` run with a stand-in `chown`; the real password
  prompt is manual.
