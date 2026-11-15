# M01-13 — `AutomationPolicy` for the scheduled safe clean (design)

Status: revision 4, **for review** (no code in this PR). §9 records the reviewer's decisions; §10 answers their five
follow-up findings and the `mc-reviewer` findings (revision 3 was reviewed; revision 4 answers that review). Base: `main` at 800c3cd. Closes RISK-017; implements
ARCHITECTURE_V2 §3a and D-011.

Why a design first: this changes what is deleted with nobody present and what counts as an approval, so
`.claude/CLAUDE.md` makes it a reviewed design before code (like M01-04C_DESIGN.md). It is **safety-critical**
(approval + permanent delete); the implementation PRs need the user's approval and `SAFETY-CRITICAL APPROVED`.

## 1. Today (audited at 800c3cd)

- **The scheduled clean does not use the executor.** `AutomationModel.tick` → `runClean(automatic: true)` →
  `AutoClean.run` (`MacCleaner/Automation.swift`) → `Scanner.plan/measure/finalize` → `AutoClean.select` →
  `Cleaner.run` (old direct path). No plan digest, no identity snapshot, no approval, no ledger.
- **Its scope is "everything recommended, minus exceptions".** `AutoClean.select` keeps every `CleanTarget` that is
  `recommended`, `isCleanable`, not `.trash`, a file/folder action, and allowed by `SafetyGuard`/`ProtectedPaths`;
  `narrowed` then drops non-allow-listed `~/.cache` tools, `DiagnosticReports` and running apps' caches. So **any new
  recommended target added to `Scanner.plan()` joins the unattended clean automatically** — that is RISK-017.
- **"On" is one boolean.** `auto.weeklyClean` (`AutoKeys.weekly`, UserDefaults). It stores no scope, no version, no time of consent. Turning
  it on shows no list of what will be deleted.
- **History says nothing about who approved.** `CleanupRecord` (`History.swift`) has title, bytes, outcome,
  measured free change; the run is one row "Scheduled Safe Clean", no item list, no approver.
- **The executor already has a `.standingPolicy(id:version:)` approver**, and the ledger already refuses a policy
  approval for any entry that isn't `safeRegenerable` + `permanentDelete` + file targets
  (`CleanupPlan.swift:401`, `outsidePolicyScope`; tests `CleanupContractTests.swift:264`, `CleanupExecutorTests.swift:345`).
  But nothing creates one, and the ledger knows nothing about **which** policy, its categories, its version, or
  whether it is enabled. Any caller can pass any id/version string.
- Caches are not on the executor yet (M01-06). The `CleanTarget` → `CleanupCandidate` builder for caches does not exist.
- CLI and MCP never run the scheduled clean; `AutomationModel` exists only in the GUI process.

## 2. Goals (from the roadmap row) and non-goals

Acceptance: (a) scheduled runs only under an **explicit, versioned, revocable** policy; (b) **a code change that adds
a category does not widen an enabled policy**; (c) runs recorded with `approvedBy: .standingPolicy`.

Non-goals: new categories or a wider scope (v1 = exactly today's effective scope, frozen); scheduled **scans**;
a rewrite of the schedule/catch-up logic (`AutoSchedule` is unchanged); moving the interactive caches clean onto
the executor (M01-06); the JSONL history store (later persistence task).

## 3. Design

### 3a. Model (MacCleanerCore, pure, no I/O, no reference to app code)

```
AutomationPolicy { id: String ("safe-clean"), version: Int, scope: AutomationScope, retired: Bool }
AutomationScope  { rules: [ScopeRule], maxBytesPerRun: Int64 }        // an ALLOW-list; nothing outside it is admitted
ScopeRule        = .item(PathPattern)         // the matched path itself is removed (a file or a whole folder)
                 | .contentsOf(PathPattern)   // each reviewed entry of the matched folder is removed; the folder stays
                   each with  excluded: [Exclusion], skipIfAppRunning: Bool
PathPattern      = [Component]
Component        = .literal(String)
                 | .oneOf(Set<String>)
                 | .anyOne(excludingNames: Set, excludingPrefixes: [String], excludingExtensions: Set)
                   // exactly one path component; never "", ".", ".."; patterns have a fixed depth
AutomationScope.digest                                   // SHA-256, length-prefixed, like CleanupPlan.digest
AutomationPolicy.admits(entry:, homeDevice:, tightening:) -> Admission     // .admitted | .refused(Reason)
```

**What authorizes and what can only refuse.** *Permission to delete comes only from a path matching a rule.* The
candidate's id, title and name never admit anything. Builder-supplied signals can only **refuse**: `risk` and `module` are
checked as conditions (a candidate that isn't `safeRegenerable` in module `"caches"` is refused, and both are in the
plan digest and re-checked by the ledger), and `tightening` is an input the app may add to over time, which can only add
refusals: a candidate the current scanner marks `recommended: false` (e.g. Spotify's offline-music cache), a name the
scanner's review list or "claimed" list has grown to include, and protected paths. **Tightening never widens**: with an
empty `tightening` the scope is exactly what v1 says, and every input removes admissions. This also lets a later safety
fix (a new review-only app) take effect under frozen v1 without a new version.

`admits` is true only when **all** hold: `risk == .safeRegenerable`; module `"caches"`; disposition `.permanentDelete`; every
target is `.file` or `.directoryContents` (never `.command`, `.tree`); every target path matches a rule: a `.file` target's
path against an `.item` pattern, and for a `.directoryContents` target **the folder against a `.contentsOf` pattern and every
reviewed entry's path against the same rule's exclusions** (so `DiagnosticReports` inside a contents rule is refused); no path
has an excluded component; the target's device equals `homeDevice` (passed in; the function does no I/O); and `tightening`
refuses nothing. Anything else is `.refused(.outsideScope)`. There is no "everything except".

**Letter case.** Literal and `oneOf` components of **allow** patterns match **exactly** on the resolved path (a look-alike
differing in case is not admitted, even on a case-insensitive volume); **exclusions are compared case-folded** (an
exclusion also catches a look-alike). Both fail toward refusing, as in SAFETY_MODEL §2a.

**v1 never references app or Core constants** (`SafetyGuard.*`, `PermanentDeleteRules.*`, `Scanner.claimedLibraryCaches`,
`Scanner.reviewAppCaches`, `AutoClean.autoDotCache`): their values at 800c3cd are **copied as literals** into the
catalog (13-1). A regression test pins this (§6). 13-1 also checks that **every v1 rule is a subset of the executor's own
permanent-delete allow-list** (`PermanentDeleteRules`), so the scope can't name a place the executor would refuse anyway.

### 3b. Versioned, frozen catalog (what "does not widen" means)

`AutomationCatalog.versions: [Int: AutomationPolicy]` is code. **A published version's scope never changes.** v1 reproduces
today's effective scope (`AutoClean.select` + `narrowed` over what `Scanner.plan()` produces at 800c3cd), plus the byte cap
(3c). Where v1 differs from today it is **narrower** and says so. `~` = home.

| v1 rule | pattern | exclusions / notes |
|---|---|---|
| fixed dev caches | the 29 exact paths in **Appendix A** (item or contents, as `Scanner` gives them) | the 9 `recommended: false` statics (archives, Gradle wrapper, Maven, Ivy, NuGet packages, CocoaPods repos, conda) are **not** in it |
| device support | `.contentsOf(~/Library/Developer/Xcode/<oneOf literal [iOS, watchOS, tvOS, macOS, visionOS]> DeviceSupport)` | |
| editor caches | `.item(~/Library/Application Support/<oneOf the literal editor folders>/<oneOf [Cache, CachedData, Code Cache, CachedExtensionVSIXs, GPUCache, logs]>)` | editor folder list copied as literals in 13-1 (golden) |
| `~/.cache` tools | `.item(~/.cache/<oneOf the 12 autoDotCache names>)` | model caches (huggingface, torch) and `uv` (kept by default) stay manual |
| app caches | `.item(~/Library/Caches/<anyOne>)` | excluded: prefix `.`, prefix `com.apple.`, the names Scanner "claims" (`Yarn`, `Homebrew`, `CocoaPods`, `pip`, `JetBrains`, `com.apple.dt.Xcode`, `io.github.wahdanz.maccleaner`, `local.maccleaner`), and **`com.spotify.client`** (review-only today, "offline music"); `skipIfAppRunning` |
| sandboxed app caches | `.contentsOf(~/Library/Containers/<anyOne>/Data/Library/Caches)` | container name excluded when prefix `.` or `com.apple.`; `skipIfAppRunning` |
| web / Electron caches | `.item(~/Library/Application Support/<anyOne>/<0..3 × anyOne>/<oneOf [Cache, Code Cache, GPUCache, DawnCache, DawnGraphiteCache, DawnWebGPUCache, ShaderCache, GrShaderCache]>)` and the same prefix + `Service Worker/<oneOf [CacheStorage, ScriptCache]>`; written out as the explicit fixed-depth patterns for 0, 1, 2 and 3 intermediate folders (Scanner's `collectWebCaches` visits depths 0–3) | top folder excluded: prefix `.`, prefix `com.apple.`, the editor folders, `MobileSync`, `CallHistoryDB`, `AddressBook`; intermediates exclude the extensions `app`, `bundle`, `framework`, `plugin` and links; `skipIfAppRunning` |
| logs | `.item(~/Library/Logs/<anyOne>)` | excluded: `JetBrains` (its own rule), prefix `com.apple.`, **`DiagnosticReports`** (crash reports are kept); matches Scanner, which hands `.removeItems(children of Logs)` after the same filter; loose files directly in `Logs` are children too |

The "app caches" classes are a class **by shape**: the cache of any app installed later at an in-pattern path qualifies. That
is what v1 means. **The scope guarantee, stated precisely: new *locations* and new *categories* always need new consent; a new *member* of an already-permitted path class (a newly installed app's cache folder) does not.** The Enable sheet must say so in plain words ("This also covers the caches of apps you install later, in the same folders") next to the list of folders; the sheet's text is part of the versioned scope (changing it is a new version) and 13-2 has a self-test that the sheet shows it. The class is bounded by depth, literals, exclusions, `safeRegenerable`,
protection, `skipIfAppRunning` and the cap. Everything a *new code path* could add at a **new location** is refused.

**Adding a category = adding `v2`** (a new entry; `v1` untouched). A mistake in a shipped version is fixed by
**retiring** it (`retired: true`: the policy pauses until the user grants a newer version), never by editing it.
`tightening` handles the opposite case, a *safety fix*, without a new consent.

### 3c. Unattended byte cap (a strict limit)

Nobody reviews the run, so v1 has a cap: **`maxBytesPerRun = 20 GB`** (approved by the reviewer as v1's budget; frozen with v1
and in the scope digest; a different number is a new version). It is a **strict limit on what the run may free**, enforced by
**charging before removing**, not a planning estimate:

- **The charge** for a file is its **allocated size**, taken from the entry's identity, **whether or not it is hard-linked** (a
  hard-linked file frees nothing but is still charged, so charged ≥ freed always). Folders and links charge 0.
- **`stop` gets the next entry's charge.** The Platform walk calls `stop(chargedSoFarInItem, nextEntryCharge)` before each entry;
  the gate refuses an entry when `charged + nextEntryCharge > maxBytesPerRun`, and updates its run total as entries are removed.
  A refused entry is kept like any stopped entry (3d). So the run **cannot free more than 20 GB**, whatever the planning estimate
  said; the overshoot is zero by construction. (A file that grew after its identity was captured fails the identity check and is
  skipped, not removed.)
- **Planning** still uses estimates, to choose what to attempt: admitted units are taken **smallest estimate first** (ties by
  path), a greedy fill while the running estimate stays within the cap; the rest are **not planned** and listed as
  `deferred (over the run limit)`. Smallest-first maximizes what the run can clean and doesn't let one rule or path order starve
  the others week after week.
- **Deferral granularity:** a unit is a **candidate's `.file` target** for item rules (one `~/.cache/pip` folder, one app's cache)
  and **one reviewed entry** for contents rules (each entry of DerivedData is its own removal in the executor).
- **A single item bigger than the cap:** not planned when its estimate says so, and listed each run as "larger than the run limit,
  clean it from the app". If the estimate was wrong, the strict charge stops the walk at the cap and the item is `.partiallyDone`
  (kept entries reported). So "never cleaned by the schedule" holds for items known to be over the cap; an item of unknown size
  can be partly cleaned, never beyond the cap.
- It only narrows today's behaviour (today there is none). Notification and history say so when it triggers.

### 3d. Stored consent, policy approval and execution: one chain

```
stored consent --validate--> ValidatedPolicy + PolicyGate --approve(under:gate:)--> GatedApproval --execute--> per-entry stop
 (data)         (Core)        (made together, at run start)   (executor)             (one-shot)      (executor)  (PolicyGate)
```

What enforces it, stated honestly: **access control plus the sites script**, not the type system alone. `ValidatedPolicy`,
`PolicyGate` and `GatedApproval` have initializers that are `package`-internal to MacCleanerKit (like `CleanupApproval`), so
app code can only obtain them through `AutomationConsent.validate`, `approve(under:gate:)`, and the catalog. But
`AutomationConsent` is an ordinary Codable value and `validate` is public, so an app file that builds a consent
with the current catalog digest gets a `ValidatedPolicy`. **That is stopped by `check-approval-sites.sh`** (3g), which is the
same kind of boundary as the existing approval-site check, and by review; the digest check catches
accidents and a stale or corrupted store, not code written to forge it (8.3).

- **`AutomationConsent`** (stored): `{ policyId, grantedVersion, grantedScopeDigest, grantedAt, source: .user, revokedAt? }`.
  The scope is never read from storage. Written only by `AutomationConsentStore` (app target), only from the Settings
  sheet's Enable and Revoke.
- **`validate(in: catalog, now:)`** fails closed (`.revoked`, `.unknownVersion`, `.retired`, `.digestMismatch`,
  `.grantedInTheFuture`) and returns the `ValidatedPolicy` **and creates its `PolicyGate`**. **The gate is created and
  registered at validation, i.e. at the start of a run** (3e step 2), before the minutes-long scan and measure. The app's
  `AutomationGateRegistry` (main actor) holds the live gate. A Revoke at any later moment (during scan, during
  planning, during execution) flips it synchronously, no actor hop, before `revokedAt` is persisted. `approve` refuses an
  inactive gate, so a revoke during the scan means nothing is approved or deleted.
- **`CleanupExecutor.approve(_ plan:, under:, gate:)`** calls `admits` for **every** entry and refuses the whole plan with
  `outsidePolicyScope(candidateID:)` if one is out (the runner filters first, 3e), then issues `.standingPolicy(id:version:)`
  bound to the plan digest, single-use, lifetime 10 minutes. The executor records the issued nonce **in an executor-held map
  `nonce → gate`** and returns a `GatedApproval`.
- **The old entry points can't bypass it.** The public `execute(plan, approval:)` refuses any approval whose approver is
  `.standingPolicy`, or whose nonce is in the gated map, with `Refusal.gateRequired`. The gated overload
  `execute(plan, gated:)` looks the gate up. The free-form `approve(_, by: .standingPolicy(...))` is refused
  (`IssueRefusal.useAutomationPolicy`).
- **The gate is a new input to the run loop.** Today `halt()` reads only the cancellation state and the `stopped` reason
  (`CleanupExecutor.swift` `execute`), and `precondition` runs only after an item's protection check. 13-1 adds the gate to
  `halt()` (so it is read before every target, including the first) and passes it down.
- **Revocation and the cap inside a long deletion.** `CleanupFileSystem.remove` gains a `@Sendable (_ chargedSoFarInItem: Int64, _ nextEntryCharge: Int64) -> String?`
  `stop` parameter (nil for interactive runs, behaviour unchanged), called by the Platform before **each entry** with the bytes
  charged so far in this item and the next entry's charge (3c). The gate is also asked **before the item is moved into its staging folder**, so a revoke before
  an item starts leaves it in place (`LocalFileSystem.remove` renames the item into staging before it visits any entry, so
  without this check the item's path would be absent for the whole walk). A non-nil reason is treated like a refused
  `protection` for the rest of the walk: **fail closed**; the entries not visited are kept, the folders holding them are kept and
  put back with the existing machinery (the put-back already works for a non-empty folder), and the item is `.partiallyDone`.
  After a revoke at most the one entry being removed completes.
  - **Name retaken during the walk.** If an app recreates the item's path while the walk runs, the put-back's
    `RENAME_EXCL` fails and the remainder stays in the staging folder (`~/Library/Caches/.<staging>…`). That is already how the
    Platform reports it (`KeptEntry.Reason.stagingLeftBehind` with the path). Unattended, it is therefore reported in history as a kept entry with its path, and 13-1 tests it.
  - **Size of the report.** A stop doesn't list every unvisited leaf: one `KeptEntry` per folder whose remaining contents
    weren't visited, with the count of entries not visited in its text.
  - **New Core cases (13-1):** `KeptEntry.Reason.stopped(String)`, `SkipReason.revoked`, `SkipReason.runLimit` (instead of
    parsing `preconditionFailed(String)` for history), plus the `stop` parameter on every `CleanupFileSystem` conformer
    (fakes included). Every exhaustive `switch` over these in Core, Features and the app changes in the same PR.
- `precondition` is kept for the per-item running-app check (3e).

### 3e. The scheduled run (app target)

1. `tick` finds the schedule due (unchanged `isDue`/`armedAt`) and `auto.weeklyClean` on; otherwise stops.
2. **Validate the stored consent and create the gate** (3d). On `Invalid`: no scan, no deletion, one "Not run" history row for
   this slot (below) and one notification per reason.
3. Plan: scan as today (`Scanner.plan/measure/finalize`), build `CleanupCandidate`s through the caches builder (M01-06;
   `.removeContents` → `.directoryContents`, `.removeItem(s)` → `.file`, `.webCachesIn` → the `.removeItems` it becomes
   after `measure`, the merged `appcache.small` candidate → one `.file` per path; identities snapshotted now). **Filter per
   target before `approve`**: a target the policy doesn't admit is dropped from its candidate and recorded as
   `skipped(outsideScope)`; a candidate left with no targets isn't planned. This is a behaviour change from
   `Cleaner.run`, where a `.removeItems` list was all-or-nothing: it is now per path, which is narrower or equal. Then apply the byte cap (3c) and
   build the plan, disposition `.permanentDelete`. Check the gate is still active right before `approve`.
4. `approve(under:gate:)` then `execute(plan, gated:)`: protection, identity revalidation, nothing followed through links; a changed,
   protected or added-after-snapshot item is skipped and reported. The snapshot is seconds old.
5. **Running apps, fail conservative.** `skipIfAppRunning` rules skip an item when **any** of these holds: the owning app
   can't be determined from the path; the running-app list can't be read (the whole class is skipped); a running app's bundle
   id, name or executable name equals the folder name, starts with `<folder name>.`, or the folder name starts with `<key>.`
   (helper processes `com.x.app.helper` count). Asked again before each item (`precondition`), not only at planning.
   Best effort, not a lock (8.8).
6. Record (3f), notify with **measured** results, `check()`, `refreshNextRun()`.

**Paused or refused runs.** A run that doesn't start writes at most **one "Not run" row per scheduled slot**: the runner stores
the slot it last reported (`auto.policyReportedSlot`, the `lastSlot` date) because a paused run doesn't set `lastRun` and
`tick` fires every 5 minutes.

**Turning `auto.weeklyClean` off and on.** Off **revokes** the consent (writes `revokedAt`, flips the live gate). On does not
re-arm the old consent: it opens the Enable sheet, and the result is a new consent record. The Settings toggle is therefore no
longer bound directly to the key (today `AutomationSettings` binds `@AppStorage(AutoKeys.weekly)`, `Automation.swift:380`); the key remains the
schedule's on/off switch and is set only together with a valid consent. This is ARCHITECTURE_V2 §3a "never runs again until turned back on".

**Run safe clean now** (decision §9.4). Today `AutomationSettings` (`Automation.swift:446`) and the menu-bar popover
(`MenuBarPopover.swift:123`) call `runClean(automatic: false)` → `AutoClean.run` after a plain confirm alert. 13-2 replaces both
with the normal review sheet, policy-scope items preselected, approved `.userInApp`; `runClean(automatic:)` and `AutoClean.run`
are then deleted. It has its own stage entry and self-test (§6, §7).

### 3f. History: every state the run can end in

`CleanupRecord` gains **optional, backward-compatible** fields (old records decode unchanged; `history.json`, shared file lock as today):

- `approvedBy: ApprovalRecord?` = `{ kind: "standingPolicy", policyId, version }` (later also the other approvers).
- `runStatus: String?` and `statusDetail: String?`. A **string**, not an enum with payloads: an older build or the CLI/MCP
  reading a status it doesn't know shows it as text and doesn't drop the record. Values: `running`, `completed`, `partial`,
  `cancelled`, `stoppedRevoked`, `stoppedRunLimit`, `failed`, `notRun`, `interrupted`.
- `items: [RecordItem]?` and `itemCounts: [String: Int]?`. **What is listed:** **every candidate with its identity (rule, path), scope (policy id, version) and final status**, and every unit that was **not removed**
  (skipped with its reason, kept entries with their reason and path, failed, permission denied, deferred over the run limit,
  outside scope) is listed **individually**, and each **removed** candidate is one row with its entry count and bytes. Exact
  counts of successful, skipped, failed and deferred units are always stored. Item results: `removed`, `partiallyDone`, `skipped(changed | protected | appRunning |
  missing | addedAfterReview | cancelled | revoked | runLimit | outsideScope | preconditionFailed)`, `deferred(overRunLimit)`,
  `permissionDenied`, `failed`.
- `bytes` = the sum over `removed` and `partiallyDone` freed bytes **when the result is known** (`bytesKnown: true`), **never the planned size** (today `AutoClean.run` adds a
  target's whole planned size whenever `Cleaner.run` returns no error, which overstates a run that skipped anything).
  `measuredFreeChange` stays a separate measurement.
- `outcome` is `.deleted` only when something was permanently removed; a `notRun` or fully skipped row has `outcome == nil`
  and 0 bytes (so `totalDeleted` is unaffected).

**Why not every removed entry:** `history.json` keeps the last 300 records (`History.swift`, `insert`) and rewrites the whole
file under the lock on each add, and the CLI and MCP decode it. A record listing 10,000 entries could mean millions of
entries rewritten per add. Hence: candidate rows plus every exception, exact counts for the rest. **This narrows ARCHITECTURE_V2
§3a "listing every item" to "every candidate and every item that was not removed"**; 13-3 changes that sentence, and it is
decision §9.7 for the reviewer. If a run has more than 500 non-removed items, the first 500 are listed and the rest are in
`itemCounts` with the text `N more not listed` (explicit, never silent).

**A run that dies: unknown is not zero.** The record is created at the start with `runStatus: running` (under the file lock,
before the scan), carries `bytesKnown: false`, and is **checkpointed after each candidate finishes** with the progress confirmed
so far (`confirmedBytes`, `confirmedItems`, same lock). At the end it is replaced by the final record (`bytesKnown: true`). If the
app quits, crashes or the Mac sleeps in between, the next launch shows the row as `interrupted`: "at least *confirmedBytes* freed;
the rest is **unknown**". It is **not** shown as "0 freed", and `totalDeleted` counts only `confirmedBytes`, labelled "at least".
A completed run that removed nothing is a **confirmed zero** (`bytesKnown: true`, `bytes: 0`); the two are never merged. There is
no per-item journal (8.11): what survives a crash is progress to the last finished candidate.

A cancelled or revoked run lists what was removed and what was left; skipped items are never counted as freed. The
notification is made from the same data ("Freed 3.2 GB; 4 items skipped" / "Stopped: you turned the policy off after 1.1 GB").

### 3g. The CLI and MCP cannot create or widen a policy

By construction: no consent-store write API outside the Settings sheet's code path; `AutomationModel` and the scheduler exist
only in the GUI process; the ledger, executor map and gate are per-process, so nothing made in the app can be redeemed in a
CLI/MCP process; MCP/CLI have no tool that runs the scheduled clean or edits consent. Enforced by `scripts/check-approval-sites.sh`
(extended in 13-2; this file is a hotspot, see §7): `.standingPolicy`, `approve(_:under:`, `execute(_:gated:`, `PolicyGate` and
`AutomationConsent.validate` only in the package and the one runner file; `AutomationConsentStore` writes only from the Settings
sheet file and the self-test; nothing under the MCP/CLI files; no `AutomationConsent(` initializer call outside the store and the self-test.

## 4. Safety walk-through

| Situation | Result |
|---|---|
| New recommended cache at a new path in `Scanner.plan()` | matches no rule → `outsideScope`, dropped, listed |
| New candidate named `appcache.x` / `web.x` / `xcode.ds.x` at an unexpected path or depth | refused: ids never admit |
| `Spotify` / `com.apple.*` / claimed / `MobileSync` / `CallHistoryDB` / `AddressBook` / `DiagnosticReports` | refused by v1's own exclusions |
| The scanner later marks another app cache review-only | `tightening` refuses it under v1 with no new consent |
| `SafetyGuard`/`PermanentDeleteRules`/`Scanner` lists edited elsewhere | v1 holds literal copies; admissions unchanged (they can only tighten) |
| App update adds a category as v2 | enabled v1 keeps running v1; v2 needs a new reviewed grant |
| Stored digest ≠ catalog digest, version unknown, retired or revoked | no run, "paused", reason shown, one row per slot |
| Folder swapped for a symlink / replaced / newly protected between snapshot and delete | executor revalidation skips it |
| App owning a cache starts after the snapshot, or can't be identified | skipped (`precondition`; unknown owner fails conservative) |
| User turns it off during the scan, before an item, or inside one huge folder | gate refuses `approve`, or stops before the item / next entry; rest kept and reported |
| Estimate too low, or caches are huge | stop at 20 GB freed; remaining units deferred and listed |
| One path of a merged candidate is out of scope | that path dropped and listed; the others run |
| A command / review / user-data / Trash item reaches the plan | `admits` refuses; ledger's generic check refuses again |
| Another caller asks for `.standingPolicy`, or runs one without the gate | refused (`useAutomationPolicy`, `gateRequired`) |
| App quits mid-run | row shows `interrupted`; freed bytes **unknown** (at least the confirmed amount), never 0 |
| Two runs for one slot, or a run right after enabling | unchanged `isDue`/`armedAt` rules |
| Mac asleep at the slot | catch-up on wake, unchanged |

## 5. Migration of existing installs

Users with `auto.weeklyClean == true` have no consent record. Decision (§9.2): **paused until they enable the policy**. The
schedule stays configured but does not run; one notification ("Scheduled clean needs your OK again — see what it covers");
Settings shows the scope sheet; **Enable** records a consent. `auto.weeklyClean` remains the schedule's on/off switch for
backward compatibility; a valid consent is a separate, additional condition. Until then a paused run writes at most one
"Not run: needs your OK" row per slot (3e).

## 6. Tests

Package (Swift Testing), real temp directories only, never the real home: `AutomationPolicyTests` in Core, executor and
Platform tests in Features/Platform.

- **Scope, per rule:** admits its cases; refuses `.command`, `.tree`, non-`permanentDelete` dispositions, non-`safeRegenerable`,
  a path outside its pattern, one level too deep or too shallow, a link, another volume, an empty target list, a letter-case look-alike.
- **Every exclusion is its own test:** `com.spotify.client`, `com.apple.*`, a dot-name, each claimed name, `MobileSync` /
  `CallHistoryDB` / `AddressBook` as an Application Support top folder, `com.apple.*` and `JetBrains` under `Logs`,
  `DiagnosticReports` as a child of `Logs` **and** as a reviewed entry of a `.contentsOf` target, an `app`/`bundle`/`framework`/`plugin` intermediate.
- **Web caches:** `Application Support/<app>/Cache` (depth 0) through `<app>/a/b/c/Cache` (depth 3) admitted, depth 4 refused;
  `Service Worker/CacheStorage` and `ScriptCache` admitted at each depth; `Service Worker/Other` refused; every `webCacheNames` literal.
- **Frozen scope / the prefix finding:** (1) golden: v1's `digest` and rule list are pinned; changing v1 in place fails
  ("bump the version instead"); versions are append-only. (2) Candidates named `appcache.x` at `~/Library/Caches/Foo/Bar` (too
  deep), `container.x` outside `Containers/<id>/Data/Library/Caches`, `web.x` not at a web-cache name, `xcode.ds.x` at a new
  folder, and `newcat.x` at a new path are all refused. (3) A candidate at an in-pattern path with an unknown id **is** admitted
  (documents that ids are not authority). (4) A synthetic catalog `v1 + v2`: a v2-only candidate is refused under v1. (5) A test edits
  the literal lists the app edits (a fake editor list or claimed list gains an entry) and shows v1's digest and admissions don't
  change. (6) **Tightening only narrows:** with `tightening` empty the admissions equal the golden set; adding any tightening only
  removes admissions (checked over the golden cases); a `recommended: false` candidate is refused. (7) Every v1 rule path is
  permitted by `PermanentDeleteRules` (v1 ⊆ executor allow-list).
- **Chain:** `validate` fails closed for revoked / unknown / retired / digest mismatch / future grant, and creates the gate;
  `approve(under:gate:)` throws and issues nothing if one entry is out of scope **or the gate is inactive**; `approve(by: .standingPolicy)` is
  refused; `execute(plan, approval:)` with a `.standingPolicy` approval or a gated nonce is refused (`gateRequired`); single-use
  and expiry as for any approval; the gate is read before the **first** target. The sites script rejects a stray consent
  initializer, `validate`, `.standingPolicy` and `PolicyGate`.
- **Revocation and cap inside long work (real temp trees):** revoke **before the first item** (the item is still in place, not
  in staging); revoke **during the scan** (nothing approved); revoke after N entries of one folder with thousands of entries: no entry past
  N+1 removed, unvisited folders kept and put back, one `KeptEntry` per folder with the count, item `.partiallyDone` with
  `stopped`; **the item's name retaken during the walk**: remainder reported as `stagingLeftBehind` with its path. The same for the
  byte cap: a low estimate **never frees more than the cap** (the next entry is refused when `charged + next > cap`, tested at the boundary), hard-linked files are charged (not 0), smallest-first planning, over-cap candidates deferred and
  listed, a single item over the cap never partly run. Interactive removal with `stop: nil` behaves as before (existing tests unchanged and green).
- **New Core cases:** `KeptEntry.Reason.stopped`, `SkipReason.revoked`, `SkipReason.runLimit` are produced, and every exhaustive
  switch compiles and is tested (Core, Features, app).
- **Scheduled-run mapping (app self-test, temp home):** the merged `appcache.small` candidate with one out-of-pattern path: that
  path dropped and listed, the others run; `.removeItems` → `.file` per path; `.webCachesIn` → the `.removeItems` produced after
  `measure`; logs as `.removeItems` of children.
- **History (self-test):** rows for completed, partial (kept entries), cancelled, stoppedRevoked, stoppedRunLimit, failed, notRun,
  interrupted (a `running` row left behind): shown as unknown with the checkpointed minimum, never as 0, and counted in `totalDeleted` only for the confirmed part; `bytes` = freed only; a 0-byte run is still recorded with `outcome == nil`; skipped,
  kept and deferred items are listed with reasons; counts match; more than 500 exceptions → explicit "N more not listed"; old
  records decode; an unknown `runStatus` string decodes and shows; the notification text comes from the same data.
- **Running apps:** unknown owner skipped; unreadable running list skips the class; a helper-process bundle id skips its app;
  asked again per item.
- **Consent and toggle:** grant stores version + digest; Revoke flips the live gate and persists `revokedAt`; **turning
  `auto.weeklyClean` off then on** leaves it paused until a new Enable and never re-arms the old consent; an old
  `auto.weeklyClean == true` install with no consent is paused with one notification and one row per slot (not per 5-minute tick).
- **Run safe clean now:** opens the review sheet with policy-scope items preselected, approves `.userInApp`, records `userInApp`
  (never `.standingPolicy`); both call sites (Settings, menu-bar popover) use it; `AutoClean.run` is gone.
- **Ported checks:** the `AutoClean.select/narrowed` self-test checks (`SelfTest.swift:294, 304, 551–553, 1098–1111`; lines 313–326
  are `AutoSchedule` tests and stay) are ported to the package scope tests (same cases, same expectations) before
  `AutoClean.select` is deleted; none dropped without an equivalent (the 04c method).

## 7. Staging (each its own reviewed PR; dependencies, not roadmap order)

| Stage | What | Level | Safety-critical |
|---|---|---|---|
| **13-1** | Core: `AutomationPolicy`/scope/patterns/catalog v1 (literals + Appendix A, golden file), `tightening`, `ValidatedPolicy`, `PolicyGate`, `AutomationConsent.validate`; executor `approve(under:gate:)`, nonce→gate map, `execute(_, gated:)`, `gateRequired`, `useAutomationPolicy`, gate in `halt()`; new `KeptEntry.Reason.stopped`, `SkipReason.revoked/.runLimit`; `CleanupFileSystem.remove(stop:)`, Platform walk and the pre-staging check, all conformers; package tests above. **App unchanged, unused** (the new enum cases' exhaustive switches in the app get the minimal update). | Senior | **yes** |
| **13-2** | App: consent store + Settings sheet (toggle revokes/enables), gate registry, scheduled runner on the executor with the per-target filter and cap, history fields (`running` row, statuses, items, counts), migration and per-slot "Not run" row, **"Run safe clean now" through the review sheet** (Settings + menu-bar popover), sites script, self-tests; remove `AutoClean.run/select/narrowed`, `runClean(automatic:)` and the scheduled path's `Cleaner.run` use. **Waits for M01-06's caches candidate builder** (decision §9.3). | Senior | **yes** |
| 13-3 | Docs: ARCHITECTURE_V2 §3a ("must re-enable" applies to the *new* scope; "listing every item" becomes "every candidate and every item not removed"), SAFETY_MODEL, RISK_REGISTER (close RISK-017), CURRENT_STATE, MIGRATION_PLAN, DECISIONS. | Junior | no |

13-1 depends on nothing unmerged (the ledger, executor and Platform exist). 13-2 depends on 13-1 and M01-06. Hotspots 13-2 touches:
`check-approval-sites.sh`, `SelfTest.swift`, `SelfTestSupport.swift`; 13-1 touches the executor, Platform and `CleanupFileSystem`
conformers that M01-06 may also touch (not yet checked: conformer count and overlap, to be done with `worktree.sh overlap` at planning). 13-3 waits for M01-04d to merge.
**No stage starts until this revision is approved and `SAFETY-CRITICAL APPROVED` is given.**

## 8. Trade-offs and limits

1. **Frozen versions in code** cost a little growth per scope change; "enabled" can never mean "whatever the latest code does". `tightening` and retirement cover safety fixes.
2. **Running the old scope after an update** means a user who never reviews keeps v1 forever (safe, possibly stale).
3. **Forgery:** the consent store is ordinary user-writable storage, and `AutomationConsent`/`validate` are callable from app code. The digest check catches a stale or corrupted store and a mismatched version, not code written to forge a consent. That code (and any process running as the user, which can already delete your files) is out of the policy's reach; app code is held by access control, `check-approval-sites.sh` and review.
4. **Classes by shape stay open in membership.** v1 admits the cache of any app installed later at an in-pattern path. Bounded by depth, literals, exclusions, protection, running-app skip and the cap, and stated in the consent sheet.
5. **The 20 GB cap** can defer a cleanup to the next run or a manual clean, and **a single item bigger than the cap is never cleaned by the schedule**. It never deletes more than today, only less.
6. **A stop mid-folder leaves a partly deleted folder** (kept entries stay, reported). If the name was retaken, the remainder stays in a hidden staging folder, reported with its path. No undo for permanently deleted entries.
7. **`CleanupFileSystem.remove` changes** (new `stop` parameter, new Core enum cases) touch the shared executor/Platform, safety-critical, and may overlap with M01-06; sequenced in 13-1 with tests before anything uses it.
8. **Running-app detection is best effort**, not a lock: an app can start between the check and the delete. Unknown or unreadable cases skip.
9. **One executor per process:** the scheduled run and an interactive Trash/Shred wait for each other. Acceptable for an infrequent background run.
10. **Unchanged limits (SAFETY_MODEL.md):** macOS has no "delete only if unchanged"; a process can write to a file it had open after the last check.
11. **A run that dies** leaves an `interrupted` row with `bytesKnown: false` and the progress confirmed at the last checkpoint (per candidate); no per-item journal in this change.
12. **Per-path filtering** replaces `Cleaner.run`'s all-or-nothing `.removeItems` handling: narrower or equal, and shown in the record.

## 9. Decisions (the reviewer's answers)

1. **After an update adds a scope version:** an enabled policy keeps running its granted version and offers a review of the
   new one (A). 13-3 updates ARCHITECTURE_V2 §3a: "must re-enable" applies to the *new* scope only.
2. **Existing installs:** paused until the user grants the new policy (fail closed), with one notification.
3. **Sequencing:** 13-2 waits for M01-06's caches candidate builder; this task does not build a second one.
4. **"Run safe clean now":** opens the normal review sheet with the policy-scope items preselected, approved `.userInApp`,
   never `.standingPolicy`.
5. **History:** `approvedBy` and `items` are added to `history.json` now as optional fields; they move with the JSONL store later.
6. **Running-app check:** best-effort detection is accepted, provided uncertain cases fail conservatively (skip): unknown owner, unreadable list, helper-process ids (§3e.5); re-checked per item.
7. **History detail:** the record lists every candidate and every item that was not removed, with exact counts for the rest, instead of
   every removed entry (§3f). This narrows ARCHITECTURE_V2 §3a "listing every item". *Raised by the design review; open for the reviewer's decision.*
8. **The 20 GB cap value** (§3c) is a proposal. **APPROVED** by the reviewer as v1's budget; the semantics are a strict limit (§3c).

## Appendix A. v1 fixed dev caches (the 29 exact paths)

Generated from `Scanner.plan()` at 800c3cd: every `dir(...)` target with `recommended: true` (the 9 `recommended: false` statics
are excluded). Paths are relative to `~`. 13-1 turns this into the golden file; this table is the list under review.

| shape | path | | shape | path |
|---|---|---|---|---|
| contents | `Library/Developer/Xcode/DerivedData` | | item | `.npm/_cacache` |
| contents | `Library/Developer/Xcode/UserData/Previews` | | item | `Library/Caches/Yarn` |
| contents | `Library/Developer/CoreSimulator/Caches` | | item | `Library/pnpm/store` |
| item | `Library/Caches/com.apple.dt.Xcode` | | item | `.bun/install/cache` |
| item | `.gradle/caches` | | item | `Library/Caches/Homebrew` |
| item | `.gradle/daemon` | | item | `Library/Caches/CocoaPods` |
| item | `.android/cache` | | item | `Library/Caches/pip` |
| item | `.pub-cache/hosted` | | contents | `.cargo/registry` |
| item | `.pub-cache/git` | | contents | `.cargo/git` |
| item | `.dartServer` | | contents | `go/pkg/mod` |
| contents | `.gem/specs` | | contents | `.bundle/cache` |
| contents | `.local/share/NuGet` | | contents | `.hex/packages` |
| contents | `.cabal/packages` | | contents | `.composer/cache` |
| item | `Library/Caches/JetBrains` | | item | `Library/Logs/JetBrains` |

Not in this table, handled by their own v1 rules: device support (5 literal OS folders), editor caches, the 12 `~/.cache` tools,
app / sandboxed / web caches and logs (§3b). (The Xcode device-support folders are listed there, not here.)

## 10. Responses to the review findings

**The user's five required fixes**

| # | Finding | Resolution (where) |
|---|---|---|
| 1 | Prefix rules could admit new candidates under v1 | Ids never admit; allow-rules are fixed-depth path patterns with literal copies of every list; builder signals can only refuse (`tightening`); regression tests (§3a, §3b, §6 "Frozen scope") |
| 2 | Boundary between consent, approval and execution; revocation inside long cleanup | One chain: `validate` (+ gate at run start) → `approve(under:gate:)` → `GatedApproval` → `execute(gated:)`; nonce→gate map, old entry points refuse; gate in `halt()` and a per-entry `stop` in `remove`, plus a check before the staging move (§3d, §6) |
| 3 | No byte cap | 20 GB frozen in v1: smallest-first planning, measured-freed stop, deferral listed (§3c; strict, charge-before-remove; value approved §9.8) |
| 4 | History accuracy | Status string, freed-only bytes, every candidate and every exception listed, 0-byte and not-run rows, `running`/`interrupted` row with unknown (not zero) bytes and per-candidate checkpoints, nil outcome when nothing was deleted (§3f) |
| 5 | `auto.weekly` → `auto.weeklyClean` | Corrected everywhere; the Today section names `AutoKeys.weekly` |

**`mc-reviewer` findings on revision 3** (REQUEST CHANGES; each verified against the code before acting)

| # | Finding | Resolution |
|---|---|---|
| B1 | App-cache and logs rules were wider than today (`com.apple.*`, claimed names, Spotify, App Support exclusions, Logs) | **Confirmed** (`Scanner.swift:144–181`). Exclusions copied into v1 as literals; Spotify excluded; logs as `.item(Logs/<anyOne>)` with its filters; tests per exclusion (§3b, §6) |
| B2 | Web-cache pattern too narrow (depth, Service Worker) | **Confirmed** (`collectWebCaches` depth < 4). Explicit patterns for 0–3 intermediates and the Service Worker shapes (§3b, §6) |
| B3 | Chain over-claimed; gated vs ungated `execute`; `halt()` claim wrong; gate timing | **Confirmed.** Wording corrected to "access control plus the sites script"; nonce→gate map and `gateRequired`; gate added to `halt()`; gate created at validation (§3d, §3e) |
| S4 | `stop` hook incompletely specified (staging rename, retaken name, new enum cases, report size, `@Sendable`) | All adopted (§3d, §7, §8.6, §8.7) |
| S5 | Cap semantics (oversized item, ordering, granularity, hard links) | Smallest-first, defined units, measured freed, oversized item stated as never cleaned by the schedule (§3c, §8.5) |
| S6 | `admits` entry checks, "reads only paths" over-claim, home device, letter case | Per-entry exclusion check, claim reworded, `homeDevice` input, case rule stated (§3a) |
| S7 | History: crash mid-run, 300-record rewrite cost, unknown-tolerant status, `.deleted` on notRun | `running`/`interrupted` row, exceptions + counts (flagged as decision §9.7), string status, nil outcome (§3f) |
| S8 | Run now, off/on, paused-slot key, all-or-nothing behaviour change | Run now stage and tests; off revokes, on re-grants; `auto.policyReportedSlot`; per-path filter before `approve` with tests (§3e, §6, §7, §8.12) |
| S9 | Fixed list ended in "…" | Full list in Appendix A (29 paths) |
| N | SelfTest line citations; weak digest claim; duplicate precondition text; unrelated branch diff | Citations fixed (§6); claim softened (§8.3); duplicate removed; the extra files in the reviewer's diff came from a stale local `main`; against `origin/main` this PR changes **only** `M01-13_DESIGN.md` (`git diff origin/main...HEAD`) |

Not checked by the reviewer and still to do before 13-1: the `CleanupFileSystem` conformer count and overlap with M01-06;
`Staging` prefix interaction with later scans; `package`-init feasibility across Features/Platform. Whether to ask for an Opus
review (`mc-safety-architect`) of this design before 13-1 is the user's call; it has not been requested.
