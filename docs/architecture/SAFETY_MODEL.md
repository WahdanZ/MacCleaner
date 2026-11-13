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
   confirmation for MCP. An AI agent's `confirm: true` is a request, not an approval.
4. **Revalidate at execution.** Protection rules and the target's filesystem identity are re-checked
   immediately before each item. A changed, replaced or newly protected target is skipped and reported.
5. **Never follow unexpected links.** Symlinks are acted on as links, never traversed into, unless the plan
   explicitly targeted the destination.
6. **Fail closed.** If a required step (overwrite, identity check, ownership check, read for comparison) fails,
   the destructive step for that item does not happen.
7. **Honest results.** Report per-item outcome. "Freed" counts only permanent deletions; Trash moves are
   "moved to Trash (not freed until emptied)". Never claim permanently deleted data can be restored.
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

## 3. Shredder semantics (after M00-01)

* The whole item is planned first. It is refused untouched if any folder inside can't be read, any entry is
  not a regular file / directory / symlink, any file is a hard link, locked, unwritable, or larger than 4 GB.
* Symlinks inside a folder are removed as links; their targets are never opened.
* Each file is opened with `O_NOFOLLOW`, checked to be the same inode and still single-linked, overwritten
  with zeros, flushed with `F_FULLFSYNC` (falling back to `fsync`), and **only then** unlinked.
* If any overwrite fails, that file and everything not yet processed are kept; folders are removed only when
  empty. The result lists what was shredded and what was kept.
* **Limits (shown in the UI and here):** on APFS and SSDs, an overwrite cannot guarantee the old blocks are
  gone — copy-on-write writes new blocks, snapshots (Time Machine local snapshots) and clones may keep the old
  data, and SSD wear levelling remaps blocks. FileVault (full-disk encryption) is the effective protection.
  Mac Cleaner never promises unrecoverability.

## 4. Duplicates semantics (after M00-02)

* Grouping: size → head/tail hash → full SHA-256. Any read error or short read excludes the file from grouping.
* Before moving a copy to the Trash: both files must still be distinct regular local files of the scanned size,
  and a byte-for-byte compare of exactly `size` bytes must succeed without error.

## 5. Simulators and command targets

`simctl delete unavailable`, `simctl runtime delete`, `docker … prune` are **command targets**: never
recommended, never scheduled, always reviewed with a description of what is lost (device app data, images,
volumes). Docker volumes are review-only.
