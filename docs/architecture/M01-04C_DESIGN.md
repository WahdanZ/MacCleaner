# M01-04c — Shredder through the cleanup executor (design, for review)

Status: revision 2, approved. **04c-1 (Core, Platform, executor, package tests) is implemented in the PR that adds this
file; 04c-2 (the app) is not started.** Base: `main` at c49f6e7.
Two pull requests:

- **04c-1** adds the Core and Platform pieces with package tests. The app doesn't use them yet.
- **04c-2** moves the app onto them and removes the old path.

**What changed in revision 2:**

- `linkCount == 1` is enforced for the root and every nested file, at planning and at every execution check.
- `linkCount` and `flags` are added to the digest for `.tree` targets (§3).
- The review sheet's size, blocked state and approved tree come from **one** fresh snapshot per item (§1b).
- Platform executes only the approved `.tree` target; it has no rescan and no path-based entry point (§1c).
- Freed bytes are reported as **estimates**, with the measured free-space change alongside (§2b).
- An item that is gone while the staging folder stays is handled explicitly (§2c).
- New tests are added for each of these (§6b).

## Today (audited at 4d65985)

- **Entry point.** The Shredder screen is the only way to shred; MCP and the CLI never shred. Its review sheet uses the old `perform` path, which issues no approval. `ShredderModel.shred` then calls `ShredEngine.shred(plan)`, entirely outside the executor. Graphify lists only `ShredEngine.shred(url)` (called by the self-test) and misses the overload `shred(_ plan:)` that the app actually uses.
- **Plan.** `ShredEngine.plan` runs **when an item is added**. It records the parent folder's `stat` and a full tree (file, link or folder, with `stat`), without following links. It refuses the whole item, changing nothing, for any of:
  - a regular file with more than one hard link (the root file too: `visit` applies the same rule to it)
  - a locked or unwritable file
  - a file over 4 GB
  - a socket, device or pipe
  - an unreadable or unchangeable folder
  - a leftover `.maccleaner-shred-*` folder
  - a link as the item itself
- **Size.** The size shown on the screen and the review sheet is `Scanner.allocatedSize(url)`, measured separately from the plan, at add time.
- **Execution.**
  1. Open the parent folder and check its identity against the plan.
  2. Make a private staging folder next to the item (mode 0700, owned by you).
  3. Process the tree depth-first, relative to open folder descriptors. For each file: check it (the hard-link count is checked only on the open descriptor), move it into staging, check it again there, open it, check it once more, overwrite it, flush it, check the staging name, unlink it, then overwrite any tail another app appended.
  4. Remove each folder with `rmdir` only after its contents are done.
  5. Stop at the first failure. The failing file is put back with `RENAME_EXCL`, and nothing not yet processed is touched.
- **Result.** `removed`, `overwritten`, `kept[]`, `damaged[]`, `warnings[]`, `leftover` (staging folder) and `refused` (nothing changed).
- **What the app does with it.** History records "Files Shredded" with the item's add-time size, as a permanent deletion. The message reads "Overwrote and deleted X" or "… N item(s) only partly", followed by the first two problems. An item that is gone with only its staging folder left counts as shredded, and the message says where the folder is. An item that was only partly shredded is planned again.

## Design

### 1. Parent identity, full-tree snapshot, descriptor-relative operations

**1a. The target.** New Core target **`CleanupTarget.tree(parent: FileIdentity, root: FileIdentity, entries: [FileIdentity])`**:

- `parent` is the folder holding the item, compared at execution as `Plan.parent` is today.
- `root` is the item.
- `entries` is every entry below `root` (files, links, folders), captured without following links, sorted by path so that parents come before their children.

The shred algorithm moves into **`LocalFileSystem.overwriteAndRemove(_ target:, protection:)`** in MacCleanerPlatform, step for step:

- the same private staging folder
- `renameat` / `renameatx_np(RENAME_EXCL)` relative to open descriptors
- `unchanged` checks (device, inode, kind, plus size and nanosecond modification time for files)
- overwrite, flush and tail overwrite
- `rmdir`-only folder removal

The parent folder is opened with `O_NOFOLLOW_ANY` and then compared. That is stricter than today's plain-path open, and still the same identity check.

**1b. One fresh snapshot per item when the review sheet opens. Display and approval both come from it.** Planning moves to Platform as **`LocalFileSystem.shredSnapshot(at:) -> Result<ShredSnapshot, Refusal>`**. One walk, without following links, returns:

- `target`: the `.tree` value above
- `logicalBytes`: the sum of the files' `st_size`
- `allocatedBytes`: the sum of `st_blocks × 512` over the root, the files and the folders

All three come from the **same** `lstat`/`fstatat` calls.

`ReviewBuild.shred` calls it once per item when the sheet opens:

- **Refusal** → a blocked row with that reason, and the item is not in the plan.
- **Success** → the row's size is `allocatedBytes`, and the plan entry is `CleanupCandidate(targets: [snapshot.target], estimatedBytes: logicalBytes, allocatedBytes: allocatedBytes)`.

Nothing captured at add time (the old `Item.plan`, the old `Item.size`) is shown on the sheet or approved. The Shredder screen's own list updates its rows' size and blocked state from the same snapshots when the sheet opens, so the screen and the sheet agree. At add time the screen still shows a quick preview so the list isn't empty, labelled as such, and it never feeds the plan.

**No unapproved fallback:**

- the builder's `perform` is `{ _ in }`
- an item without a snapshot is blocked
- with no approval, or a refused one, nothing is shredded

**1c. Exactly the approved tree, never a new scan.**

- `overwriteAndRemove` takes the `.tree` target only. There is no path- or URL-based entry point, and no planning inside execution.
- It **never lists a folder to decide what to delete**. It visits only `target.entries`, in order.
- An entry that exists on disk but isn't in the target is never opened, moved or deleted. Its folder's `rmdir` then fails with `ENOTEMPTY`, and the folder is kept.
- The executor passes the target **from the plan it just redeemed against the approval's digest**, so what runs is what was approved.
- The app never calls Platform's shred directly (approval-site rule). Planning again after a partial shred produces a **new** plan that needs a new review and approval.

The per-entry rules (hard link, locked, unwritable, 4 GB, special file, unreadable folder, leftover staging, link as the item) live in Platform, shared by planning and execution. A new planning rule refuses an item with **another volume mounted inside it**.

### 2. What the report preserves

**2a. Mapping.** The new Core result is `OverwriteRemovalResult`, with `estimatedFreedBytes`, `filesOverwritten`, `kept: [KeptEntry]`, `damaged: [String]` and `warnings: [String]`.

| Shredder result today | Executor outcome |
|---|---|
| `refused`: parent moved or replaced, item missing or replaced | thrown `FileSystemRefusal` → `.skipped(.changed / .missing)` |
| `refused`: staging folder couldn't be made | `.failed("Couldn't prepare the shred (…). Nothing was changed.")` |
| everything went, staging folder removed | `.removed(bytes: estimatedFreedBytes)` |
| stopped part-way | `.partiallyDone(freedBytes: estimatedFreedBytes, kept:, damaged:)` |
| `damaged` (an overwrite failed part-way, file kept) | `damaged` paths and a `KeptEntry(.failed("… partly overwritten, so its content is damaged"))` at the file's current path |
| a file that couldn't be put back (its name was taken) | `KeptEntry(path: <staging>/<n>, reason: .failed("replaced while shredding; it is here"))` |
| `leftover` (staging folder couldn't be removed) | `KeptEntry(path: stagingPath, reason: .stagingLeftBehind)` |
| `warnings` (another app kept writing) | **new** `ItemOutcome.warnings: [String]`, plus `CleanupReport.warnings` across all outcomes |
| `overwritten` count | **new** `ItemOutcome.removedFiles: Int?` (nil for dispositions that don't count files) |

Both new `ItemOutcome` fields are additive and have defaults. No existing enum case changes.

**2b. Freed bytes are estimates, and are labelled as such.**

- `estimatedFreedBytes` adds, for each file, `st_blocks × 512` from `fstat` on the open descriptor right before the unlink, plus each removed folder's own blocks. That is the space those entries occupied, which is **not** necessarily the space returned to the disk:
  - APFS clones share blocks, so deleting one clone frees nothing.
  - Snapshots keep blocks.
  - A file another app holds open frees its blocks only when that app closes it.
- The executor documents `.removed(bytes:)` and `CleanupReport.freedBytes` as estimates for `overwriteThenDelete`.
- **History** records `bytes = report.freedBytes` (the estimate; `CleanupRecord.bytes` already means "size of what was removed, as measured before removing it") and **`measuredFreeChange`** = free space after minus before (`Scanner.freeBytes()`). That is the same pattern Cleaner, Projects and the MCP cleans use. The row already presents that figure as a measurement, not a promise.
- **The message** says "Overwrote and deleted about X" (and "… about X; N item(s) only partly"). The review sheet's size stays a measurement of what is there, as for every module.

**2c. The item is gone, but the staging folder stays.** For each item, the model decides on the outcome **and** a fresh `lstat` of the root path:

| Outcome | Root path | Treated as | History, list and message |
|---|---|---|---|
| `.removed` | gone | shredded | estimate counted; row removed |
| `.partiallyDone`, **kept is only `stagingLeftBehind`**, `damaged` empty, `removedFiles` = all planned files | gone | shredded, with a leftover work folder | estimate counted; row removed; message: "shredded, but its work folder couldn't be removed and may still hold items: <path>" (as today) |
| `.partiallyDone`, any other kept entry (including a file left in staging) or anything damaged | either | partly shredded | only the estimate for what was overwritten is counted; the row is planned again if the root still exists, otherwise removed; the message lists the first kept or damaged entries with **their current paths** (staging paths included) |
| `.skipped` / `.failed` | present | nothing changed | nothing counted; "… Nothing was changed." |

The staging folder is never reported as the item, and the item is never reported as shredded while anything except an empty-or-unknown work folder is left.

### 3. `.tree` targets: strict validation, digest coverage, no links followed, no other volumes

**Plan validation** (`CleanupPlan.init`, before any approval exists). The plan is refused unless all of these hold:

- `overwriteThenDelete` ⇔ every target of the candidate is `.tree`, and there is exactly one per candidate. A `.tree` target with any other disposition is refused, and so is `overwriteThenDelete` with any other target.
- `parent.kind == .directory`, and `root` is a direct child of `parent` on the same device.
- `root.kind` is `.file` or `.directory`. A link or `.other` as the item is refused. A file root has no entries.
- **Every `.file`, the root file included, has `linkCount == 1`.**
- Every entry is strictly below `root`, unique, in canonical order, on `root`'s device, and of kind `.file`, `.directory` or `.symlink`. Each one's own parent is `root` or a `.directory` entry, so nothing sits below a link.

**Hard links and locked files, at both stages:**

- **Planning** (Platform) refuses any regular file, root or nested, with `st_nlink != 1`, or with lock flags (`UF_IMMUTABLE`, `UF_APPEND`, `SF_IMMUTABLE`, `SF_APPEND`).
- **Execution** re-checks `st_nlink == 1` and no lock flags **at every check of a file**:
  1. before the move (`fstatat` in its folder)
  2. after the move (`fstatat` in staging)
  3. on the open descriptor (`fstat`; today the only place it is checked)
  4. at the last staging check before the unlink

  A file that gained a link or a lock is kept, and the item stops.

**Digest coverage.** Today the digest covers path, device, inode, kind, size, modification time and capture time, **not** `linkCount` or `flags`. For `.tree` targets the digest gains a `tree` record: `parent`, `root`, the entry count, and every entry's full identity **including `linkCount` and `flags`**. The approved plan therefore states that every file had one link and no lock bits when it was reviewed.

The digest binds the **reviewed values**. It is computed from the plan, not from the disk, so it doesn't change when the disk does. What happens on disk after review is caught by the execution checks above.

`.file` and `.directoryContents` encodings stay unchanged in this PR, so other modules' behaviour doesn't change. Extending them is listed for 04d. Approvals and digests are never persisted (per-process ledger), so a different encoding can't invalidate anything stored.

**At execution:**

- Links are unlinked as links and never opened or followed (`AT_SYMLINK_NOFOLLOW`, and `O_NOFOLLOW` on every `openat`).
- An entry on another device than `root` is kept (`KeptEntry(.otherVolume)`), and the item stops.
- The ledger already refuses `overwriteThenDelete` for a standing policy, and `.appOwned` allows only `.trash`. Both stay that way.

### 4. Fail closed, stop at the first failure, UI and History

- **Within an item**, it stops at the first failure. Nothing is deleted unless its overwrite succeeded. The failing file is put back with `RENAME_EXCL`, and unprocessed entries are never touched.
- **New:** protection is checked again for each entry right before it moves (the same rule as `AppProtection.refusal(.overwriteThenDelete)`). A newly protected entry is kept, and the item stops.
- **Across items**, each is independent, as today.
- `AppProtection.refusal(path, .overwriteThenDelete)` becomes today's `ShredEngine.reason`: the Trash rules, and inside the home folder only.
- **UI.** The review sheet looks the same: title, explanation, "cannot be recovered", blocked rows, and the permanent-action acknowledgement. Its values now come from the fresh snapshot (§1b). Messages are as today, with "about" for the freed estimate (§2b) and the outcome rules in §2c. A partly shredded item is planned again for a new review.
- **History** records "Files Shredded" as `.deleted` with the estimate, plus the measured free-space change.

### 5. Approval only through `ReviewConfirmation`

- `ReviewBuild.shred` sets `trashPlan` to the `.tree` plan and `performApproved`. Its `perform` is `{ _ in }`.
- `ReviewConfirmation.confirm` approves it as `.userInApp`. No new approval site is added.
- `ShredderModel.shred(reviewed, approval)` runs exactly that plan through `AppCleanup.executor`. With no approval, or a refused one, nothing is shredded and each item says why.
- `ShredEngine.shred(…)` (both overloads) and the in-app overwrite code are **deleted**.
- New `check-approval-sites.sh` rules:
  - `overwriteAndRemove(` only in LocalFileSystem and CleanupExecutor.
  - `shredSnapshot(` only in `ReviewBuild.shred` and the Shredder screen's preview.
  - `.overwriteThenDelete` plans built only in `ReviewBuild.shred`.
  - `ShredEngine.shred(` may not appear anywhere.

**Naming trade-off.** The review plumbing keeps its Trash-specific names (`trashPlan`, `TrashApproval`) in this PR. The rename goes to 04d.

### 6. Tests

#### 6a. Every current Shredder check, mapped

The **package** tests use real files with `LocalFileSystem`'s internal test hooks (no public test seams). The **self-test** runs the app end to end: review → approval → executor → message and History.

| # | Check today | 04c-1 package test | 04c-2 self-test |
|---|---|---|---|
| 1 | Refuses a folder holding a hard link; the other copy is untouched | snapshot refusal; Core `linkCount` validation | blocked row, nothing approved |
| 2 | Re-checks protection right before shredding | per-entry protection stops the item | protected after review → `.skipped(.protected)` |
| 3 | Refuses a locked file | snapshot refusal; execution re-check | blocked row |
| 4 | Overwrites and deletes a folder with sub-folders | tree removed, `removedFiles == 2` | end to end; History "Files Shredded" |
| 5 | Refuses items outside the home folder | — (app rule) | `AppProtection` refusal; blocked row |
| 6 | A failed write keeps that file and everything after it | hook: overwrite fails | — |
| 7 | Partial result says what was kept and how many of the total | `partiallyDone` with `removedFiles` | message "stopped after N file(s)" |
| 8 | A write failing half-way is reported as damaged | hook: partial write → `damaged` | message names the damaged file |
| 9 | A failed flush keeps the file | hook: flush fails | — |
| 10 | Refuses a folder with an unreadable folder inside | snapshot refusal | — |
| 11 | Refuses a file over 4 GB | snapshot refusal (sparse file) | — |
| 12 | Refuses a pipe | snapshot refusal | — |
| 13 | Data appended after the overwrite is overwritten too | hook `afterOverwrite` appends → tail overwritten | — |
| 14 | A file replaced right before the move is put back untouched | hook `beforeMove` replaces → put back | — |
| 15 | A file edited after review is kept as it is | identity mismatch at execution | edited between review and confirm → kept |
| 16 | A file added after review is untouched and the folder stays | not in the target → untouched; `ENOTEMPTY` → kept | — |
| 17 | A sub-folder swapped for a link before shredding: the target is untouched | hook `beforeStart` | — |
| 18 | A sub-folder swapped for a link mid-shred | hooks `beforeFolderRemove` / `beforeMove` | — |
| 19 | The item's folder swapped for a link: refused, nothing changed | parent identity → `.skipped(.changed)` | — |
| 20 | A link inside a folder is removed, its target untouched | link unlinked, target intact | — |
| 21 | Refuses a link as the item itself | snapshot refusal; Core `root.kind` validation | blocked row |
| 22 | Staging folder that can't be removed → not "removed", says where | hook `beforeStagingCleanup` → `stagingLeftBehind` | see 6b, gone + leftover |
| 23 | No staging folders left in the test area | after every package test | after the self-test |

#### 6b. New tests for this revision

| Area | Test | Where |
|---|---|---|
| Hard links | the root **file** with a second link → snapshot refused; a nested file likewise | package |
| Hard links | a link added to a file **after review** → kept at the pre-move check; the same with the link added after the move into staging, and on the open descriptor (hooks `beforeMove` / after move) | package |
| Lock flags | a file locked after review → kept, item stops | package |
| Digest | a plan whose entry differs only in `linkCount`, or only in `flags`, has a different digest → the approval is refused (`planChanged`) | Core |
| Validation | each §3 rule rejects a hand-built bad `.tree` (file root with entries, link root, entry outside the root, out of order, below a link entry, on another device, `.other` kind, `linkCount` 2, `.tree` with `.trash`, `overwriteThenDelete` with `.file`) | Core |
| One snapshot | the sheet's row size, blocked reason and plan target come from the same `shredSnapshot` call (the counted builder calls it once per item; the row's size equals the snapshot's `allocatedBytes`; the plan's target is that snapshot's) | self-test |
| One snapshot | an item changed between add and sheet open: the sheet shows the new size or blocked state, and the add-time preview is not used | self-test |
| No fallback | the builder's `perform` does nothing; a sheet whose plan can't be built (all rows blocked) shreds nothing; a refused approval shreds nothing | self-test |
| Approved tree only | after review, add a file and a sub-folder to the item and replace another file → only the reviewed, unchanged entries are shredded; the added ones are untouched; the replaced one is kept; the folder stays | package and self-test |
| Approved tree only | Platform given a hand-built target that omits an entry existing on disk → that entry is never touched, its folder is kept | package |
| Approved tree only | the executor given plan A with plan B's approval → refused, nothing touched | package |
| Estimates | `estimatedFreedBytes` equals the sum of the removed entries' `st_blocks × 512`; a cloned file (`clonefile`) is still reported by its blocks (documented as an estimate) | package |
| Estimates | History gets `bytes` = the report's estimate **and** `measuredFreeChange` set; the message says "about" | self-test |
| Gone + leftover | everything shredded, staging left (hook) → the outcome has only `stagingLeftBehind` and the root is gone → counted as shredded, row removed, message gives the work-folder path, History counts it | package (outcome) and self-test (the model's pure mapping, real and synthetic outcomes) |
| Gone + kept in staging | a file that couldn't be put back stays in staging, the root is gone → reported as partly shredded with the staging path, not as shredded | package and self-test |

## Trade-offs

1. **Bigger Core contract** (`.tree`, `OverwriteRemovalResult`, two additive `ItemOutcome` fields). A folder target walked at execution was rejected: it would drop the guarantee that only the reviewed tree is shredded.
2. **The parent is opened with `O_NOFOLLOW_ANY`.** An item reached through a symlinked folder is planned at its real path.
3. **Per-entry protection and link/lock re-checks:** new reasons to stop. Fail closed.
4. **Freed bytes are an estimate.** The message says "about", and History also stores the measured free-space change, which itself is affected by other apps and APFS.
5. **The snapshot is taken when the sheet opens,** not when the item is added. An item can become blocked between adding and reviewing, and the screen list updates to match.
6. **The executor is busy during a long shred.** One executor per process means a Trash move waits until the shred finishes. Acceptable for a desktop action the person starts; to revisit in 04d if needed.
7. **Plan size grows with the tree** (one identity per entry, digested once). No new cap; there is none today.
8. **`linkCount`/`flags` are in the digest for `.tree` only.** Other encodings are unchanged, and extending them is a 04d item.
9. **Naming debt** (`trashPlan`, `TrashApproval`) deferred to 04d.

## Unchanged limits (SAFETY_MODEL.md)

A process running as you can still write to a file it already had open after the last check, or change the staging folder. macOS has no "delete only if unchanged" call. On APFS and SSDs an overwrite can't guarantee that the old blocks are unrecoverable (copy-on-write, snapshots, wear levelling).
