# Safety Model

Applies to every operation that removes, moves, overwrites, quarantines or changes ownership of user data,
whether started from the app, the menu bar, the scheduler, the CLI or MCP.

## 1. Invariants

1. **Nothing destructive without a reviewed plan.** The plan shown is the plan executed (ids map back to the
   captured objects; a rescan cannot add items — already true since #18).
2. **Risk ≠ selection.** Visible does not mean recommended. Only `safeRegenerable` items may be preselected.
   `reviewRequired`, `potentialUserData`, `privileged` items are never preselected, never part of
   "Select all safe", never run by the scheduler.
3. **Human approval.** Approval comes from a person: the Review sheet, the terminal y/N, or a Mac Cleaner-owned
   confirmation for MCP. An AI agent's `confirm: true` is a request, not an approval. The only exception is the
   scheduled safe clean, which runs under a separate, explicitly enabled, narrow **automation policy**
   (`ARCHITECTURE_V2.md` §3a), never under an agent's request.
4. **Revalidate at execution.** Protection rules and the target's filesystem identity are re-checked
   immediately before each item. A changed, replaced or newly protected target is skipped and reported.
5. **Never follow unexpected links.** Symlinks are acted on as links, never traversed into, unless the plan
   explicitly targeted the destination.
6. **Fail closed.** If a required step (overwrite, identity check, ownership check, read for comparison) fails,
   the destructive step for that item does not happen.
7. **Honest results.** Report per-item outcome. "Freed" counts only permanent deletions; Trash moves are
   "moved to Trash (not freed until emptied)". Never claim permanently deleted data can be restored.
   **Not everything can be rolled back:** a folder deleted part-way, or a file whose overwrite started, cannot
   be restored. Such outcomes are reported as partial (what was done, what was kept, what was damaged).
8. **Unreadable ≠ empty.** A folder that could not be read is reported as inaccessible, never as 0 bytes or
   "nothing found".
9. **Tests never touch real user data.** Fixtures live in a fresh temporary home; see `TEST_STRATEGY.md`.

## 2. Guard layers (current code, kept and unified in M01)

| Layer | Applies to | Rule |
|---|---|---|
| `SafetyGuard` | permanent cache deletion | allow-list of regenerable roots, symlinks resolved, container roots themselves refused |
| `TrashGuard` | Move to Trash | home + `/Applications` only; structural and sensitive folders refused; case-insensitive, parent links resolved |
| `ProtectedPaths` | everything | user list; protected, inside protected, or containing protected → refused |
| Shredder | overwrite + delete | home only, regular files only, no hard links, every folder readable, every file ≤ 4 GB and writable; per-file overwrite → flush → unlink |
| Admin step | privileged uninstall | random 0700 staging dir, root-owned parent re-check, `mv -n`, chown staging dir only |

## 3. Shredder semantics (PR #26, open — not on `main` yet)

* **Plan at review.** When an item is added, it is listed without following links and every entry's identity
  is recorded (device, inode, type; size and modification time for files). It is refused untouched if any
  folder can't be read completely, any entry is a hard link, locked, unwritable, over 4 GB, a pipe/socket/device,
  or the item itself is a link. Shredding executes this reviewed plan.
* **Work through open folders.** The item's folder is opened once and checked against the plan; everything else
  is relative to open folder descriptors (`openat`, `fstatat`, `renameat`, `unlinkat`, no link following).
* **Move, check, act.** Each file or link is moved into a private staging folder (random name, mode 0700, same
  folder as the item) and checked there. If it isn't the planned object, it is moved back with `RENAME_EXCL`
  (never replacing anything) and kept. Files changed since review are kept.
* **Overwrite → `F_FULLFSYNC` → final identity check → unlink → re-check through the still-open file:** data
  another process appended meanwhile is overwritten before closing.
* **Stop at the first failure.** Already-shredded files are gone; the failed file and the rest stay in place.
  `removed` is reported only when the item is gone **and** the staging folder was removed; otherwise the
  staging folder's path is reported (`leftover`).
  A file whose overwrite started is reported as **damaged**. Folders are removed only when empty (`rmdir`), so
  a swapped folder can never cause data loss.
* **Residual limits (not atomic):** macOS has no "unlink only if unchanged" call. A process of the same user
  that already holds the file open can still write after the last re-check (a warning is shown if growth is
  seen), and could in principle find and alter the staging folder. These require a hostile same-user process,
  which can delete the user's files anyway.
* **Limits (shown in the UI and here):** on APFS and SSDs, an overwrite cannot guarantee the old blocks are
  gone — copy-on-write writes new blocks, snapshots (Time Machine local snapshots) and clones may keep the old
  data, and SSD wear levelling remaps blocks. FileVault (full-disk encryption) is the effective protection.
  Mac Cleaner never promises unrecoverability.

## 4. Duplicates semantics (PR #27, open — not on `main` yet)

* Grouping: size → head/tail hash → full SHA-256. Short (non-empty) reads are continued until the needed byte
  count; any read error, or a file that ends before its listed size, excludes the file from grouping.
* Before moving a copy to the Trash: both files must still be distinct regular local files of the scanned size,
  exactly `size` bytes must compare equal, and both must end there (not truncated, not grown).

## 5. Unattended runs

The scheduled safe clean runs under the automation policy (`ARCHITECTURE_V2.md` §3a): opt-in, narrow fixed scope,
same guards and revalidation, recorded as a session, revocable. It never runs command targets, review items,
Trash-only items or privileged steps.

## 6. Simulators and command targets (PR #30, open — not on `main` yet)

`simctl delete unavailable`, `simctl runtime delete`, `docker … prune` are **command targets**: never
recommended, never scheduled, always reviewed with a description of what is lost (device app data, images,
volumes). Docker volumes are review-only.
