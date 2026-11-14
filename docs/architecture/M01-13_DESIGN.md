# M01-13 — `AutomationPolicy` for the scheduled safe clean (design)

Status: revision 1, **for review** (no code in this PR). Base: `main` at 800c3cd. Closes RISK-017; implements
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
- **"On" is one boolean.** `auto.weekly` (UserDefaults). It stores no scope, no version, no time of consent. Turning
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

### 3a. Model (MacCleanerCore, pure, no I/O)

```
AutomationPolicy { id: String ("safe-clean"), version: Int, scope: AutomationScope }
AutomationScope  { rules: [ScopeRule] }              // an ALLOW-list; nothing outside it is ever admitted
ScopeRule        { name, selector: IDSelector, roots: [PathRoot], excludedNames: Set<String>,
                   skipIfAppRunning: Bool, shapes: Set<TargetShape> }
IDSelector       = .exact(Set<String>) | .prefix(String)         // candidate.id
TargetShape      = .file | .directoryContents                    // never .command, never .tree
AutomationScope.digest: String                                   // SHA-256, length-prefixed, like CleanupPlan.digest
AutomationPolicy.admits(candidate:disposition:) -> Admission     // .admitted | .refused(Reason)
```

`admits` is true only when **all** hold: `risk == .safeRegenerable`; `recommended`; disposition `.permanentDelete`;
module `"caches"`; every target is a `.file`/`.directoryContents` (no `.command`, `.tree`); a rule's selector matches
the id; **every** target path is inside one of the rule's roots (after the plan's resolved identity path), none under
an `excludedNames` component; a candidate matching no rule is `.refused(.outsideScope)`. Rules are an allow-list:
there is no "everything except".

### 3b. Versioned, frozen catalog (what "does not widen" means)

`AutomationCatalog.versions: [Int: AutomationPolicy]` is code. **A published version's scope never changes.**
v1 reproduces today's effective scope exactly (from `AutoClean.select` + `narrowed`):

| v1 rule | selector | roots | notes |
|---|---|---|---|
| fixed dev caches | `.exact` of the static recommended ids in `Scanner.plan()` at 800c3cd (Xcode `xcode.derived/previews/simcaches/cache`, `npm`, `yarn`, `pnpm`, `bun`, `brew`, `pods`, `pip`, `cargo.*`, `go.modcache`, `gem.specs`, `bundler`, `nuget.http`, `hex`, `cabal`, `composer`, `jetbrains.*`, …) | each id's own folder under home | the exact list is generated once from `Scanner.plan()` during 13-1 and pinned by the golden test (§6); items with `recommended: false` (maven, ivy, nuget, conda, cocoapods repos, simulators, archives, Gradle distributions) are **not** in it |
| device support | `.prefix("xcode.ds.")` | `~/Library/Developer/Xcode/* DeviceSupport` | |
| editor caches | `.prefix("editor.")` | `~/Library/Application Support/<editor>/{Cache,CachedData,logs…}` | |
| `~/.cache` tools | `.exact` of `cache.<name>` for the 12 names in `autoDotCache` | `~/.cache/<name>` | model caches (huggingface, torch) stay manual |
| app caches | `.prefix("appcache.")`, `.prefix("container.")`, `.prefix("web.")` | `~/Library/{Caches,Containers/*/Data/Library/Caches,…}` | `skipIfAppRunning` |
| logs | `.exact("logs.user")` | `~/Library/Logs` | `excludedNames: ["DiagnosticReports"]` |

(Prefix rules are bounded by their roots and shapes, not only by the id: a new code path inventing an `appcache.*`
id outside `~/Library/Caches` is still refused.)

**Adding a category = adding `v2`** (a new entry; `v1` untouched). The Scanner/executor gaining a recommended target
changes nothing for an enabled v1 policy because v1 is an allow-list of ids and roots, not a filter over "recommended".
A mistake in a shipped version is fixed by **retiring** it (a `revoked: Bool` flag on the catalog entry, §3d), never by editing it.

### 3c. Consent record (what is stored)

Stored: `{ policyId, grantedVersion, grantedScopeDigest, grantedAt, source: .user | .migrated }`, and
`revokedAt?`. Written only by `AutomationConsentStore` (app target), called only from the Settings › Automation
toggle's confirmation. **The scope itself is never read from storage.** At each run the app looks up
`catalog[grantedVersion]`, recomputes its digest and requires it to equal `grantedScopeDigest`; any mismatch,
unknown version or retired version → **fail closed**: the run does not happen, the policy shows "paused", the user
is notified once. (This catches a bad downgrade/edit of the app's own code and a corrupted store. It is not a defense
against another process running as the user rewriting the store; see §8.)

**Granting** is explicit: turning the schedule on (or re-enabling) opens a sheet that lists the categories and
folders of the version being granted ("Mac Cleaner will delete these caches without asking each time"), plus what
is never touched (Trash, Downloads, anything protected, commands, review items), with an **Enable** button. The
schedule (frequency/time) is not part of the policy; changing it needs no new consent (`armedAt` behaviour unchanged).

**When a newer catalog version exists** (an app update added a category): the enabled policy **keeps running its granted
version** — the new category is not added — and Settings shows "A newer scope is available: *review*". Reviewing
shows the diff against the granted version; the user can enable it (new consent record) or ignore it. Alternative
(pause until reviewed) is Open question 1.

**Revoking** (toggle off, or "Revoke"): writes `revokedAt`, cancels an in-flight run (§3e), and the schedule never
runs again until a new grant. Re-enabling is a new consent record, never an un-revoke.

### 3d. Executor and ledger changes (`MacCleanerFeatures` / `Core`, safety-critical)

- New `CleanupExecutor.approve(_ plan:, under policy: AutomationPolicy, lifetime:)`: for **every** entry calls
  `policy.admits`; if any entry is refused, throws `IssueRefusal.outsidePolicyScope(candidateID:)` and issues nothing.
  It then issues `.standingPolicy(id: policy.id, version: policy.version)`. The approval is single-use, bound to the
  plan digest, short-lived (default 10 min, well under `maxLifetime`), per process, as for every approval.
- The free-form `approve(_, by: .standingPolicy(...))` is **refused** from then on (`IssueRefusal.useAutomationPolicy`),
  so no caller can mint a policy approval with an invented id/version or without `admits`. The ledger's existing generic
  check stays as a second line.
- `AutomationPolicy` has no public initializer outside `AutomationCatalog` (like `CleanupApproval`), so app code
  can't construct a wider policy; it can only fetch `AutomationCatalog.policy(version:)`.
- "Enabled" and "revoked" are app state, not Core: the **scheduled runner** is the only caller and checks consent
  before calling `approve`. To make revocation stop a run between items, the runner passes the executor's existing
  `precondition` closure that reads a lock-protected `PolicyGate` (set on revoke); it returns a reason, the executor
  skips every later item untouched (existing `preconditionFailed` behaviour). Task cancellation also stops the run
  (existing `.cancelled`).
- Running-app skip moves from select time to **execution time**: the same `precondition` re-checks "is the app that
  owns this folder running?" right before each item (`skipIfAppRunning`).

### 3e. The scheduled run (app target)

1. `tick` finds the schedule due (unchanged) and consent valid (§3c); otherwise stops (paused/revoked/off).
2. Plan: scan targets as today (`Scanner.plan/measure/finalize`), build `CleanupCandidate`s through the **caches
   builder** (`.removeContents` → `.directoryContents(folder, kids)`, `.removeItem(s)` → `.file`, identities
   snapshotted now), keep only candidates `policy.admits`; build a `CleanupPlan` of those, disposition
   `.permanentDelete`.
3. `executor.approve(plan, under: policy)` → `execute(plan, approval:, precondition:, progress:)`. Same guards as an
   interactive run: protection, identity revalidation, nothing followed through links; anything changed, protected
   or added after the snapshot is skipped and reported. The snapshot is taken seconds before the run, so the
   review-to-run window is far smaller than interactive.
4. Record (§3f), notify, `check()`, `refreshNextRun()` as today.

### 3f. History

`CleanupRecord` gains two **optional, backward-compatible** fields: `approvedBy: ApprovalRecord?`
(`{ kind: "standingPolicy", policyId, version }`; also `userInApp`, … later) and `items: [RecordItem]?`
(path, outcome per item: removed / skipped(reason) / failed). The scheduled run's row is titled "Scheduled Safe
Clean", `outcome: .deleted`, and lists **every** item, as §3a of ARCHITECTURE_V2 requires. A skipped item
(changed, protected, app running) is listed as skipped, not counted as freed. Freed bytes are the estimate plus
`measuredFreeChange`, as in 04c. Old records decode unchanged (nil). When the JSONL history store lands, the same
fields move with it.

### 3g. The CLI and MCP cannot create or widen a policy

By construction: no consent-store write API outside the Settings sheet's code path; `AutomationModel` and the
scheduler exist only in the GUI process; the ledger is per-process, so an approval made in the app can never be
redeemed by a CLI/MCP process; MCP/CLI have no tool that runs the scheduled clean or edits consent.
Enforced by `scripts/check-approval-sites.sh` (extended in 13-2): `.standingPolicy` / `approve(_:under:)` only in the
package and the one runner file; `AutomationConsentStore.grant` only from the Settings sheet file and the self-test;
`AutomationCatalog` lookup only from those; nothing under the MCP/CLI files.

## 4. Safety walk-through

| Situation | Result |
|---|---|
| New recommended cache added to `Scanner.plan()` | not in v1's ids/roots → `outsideScope`, not planned |
| App update adds a category as v2 | enabled v1 keeps running v1; v2 needs a new reviewed grant |
| `grantedScopeDigest` ≠ catalog digest, version unknown or retired | no run, "paused", one notification |
| A folder swapped for a symlink / replaced / newly protected between snapshot and delete | executor revalidation skips it (as interactive) |
| App owning a cache starts after the snapshot | `precondition` skips it |
| User turns it off mid-run | `PolicyGate` + cancellation stop before the next item; earlier items stay deleted, reported |
| A command / review / user-data / Trash item reaches the plan | `admits` refuses; ledger's generic check refuses again |
| Any other caller asks for `.standingPolicy` | refused (`useAutomationPolicy`) |
| Two runs for one slot, or run right after enabling | unchanged `isDue`/`armedAt` rules |
| Mac asleep at the slot | catch-up on wake, unchanged |

## 5. Migration of existing installs

Users with `auto.weekly == true` have no consent record. **Recommended:** fail closed — the schedule stays configured
but is *paused*; one notification ("Scheduled clean needs your OK again — see what it covers") and Settings shows the
scope sheet; **Enable** records a consent with `source: .user`. Cost: cleans stop until the user acts once. Alternative:
auto-grant v1 with `source: .migrated` because v1 equals what they already had (Open question 2). `auto.weekly`
remains the schedule's on/off switch for backward compatibility; consent is a separate, additional condition.

## 6. Tests

Package (Swift Testing), no real home: `AutomationPolicyTests` in Core, executor tests in Features.

- **Scope:** every v1 rule admits its cases and refuses `.command`, `.tree`, `.trash`/`.overwriteThenDelete`
  dispositions, non-`safeRegenerable`, non-`recommended`, a path outside its root, an `excludedNames` component
  (`DiagnosticReports`), an empty target list.
- **Golden digest:** v1's `digest` and its rule list are pinned in the test; changing v1 in place fails the test
  ("bump the version instead"). A second test asserts versions are append-only (every `n` in `1...max` exists).
- **Does not widen:** a synthetic catalog with v1 and v2 (v2 adds a category) → a v2-only candidate is refused under v1;
  a candidate added to a fake scanner list that is "recommended" but not in v1 is refused.
- **Approval path:** `approve(under:)` throws, issuing nothing, if one entry is out of scope; success yields
  `.standingPolicy(id:version:)` bound to the digest, single-use, expires; `approve(by: .standingPolicy)` is refused;
  a ledger with an out-of-scope entry still refuses.
- **Execution:** a plan under the policy deletes the admitted real temp files; a swapped/replaced/protected item is
  skipped; `precondition` stops mid-run on revocation and skips the rest untouched; running-app precondition skips.
- **Consent (app, self-test with a temp home):** grant stores version + digest; digest mismatch / unknown / retired
  → paused, nothing deleted; revoke → no run; re-enable = new record; migration pauses an old `auto.weekly`;
  history row has `approvedBy` and lists every item incl. skipped; old records still decode.
- **Sites:** `check-approval-sites.sh` extended and its own cases (a stray `.standingPolicy` fails it).
- The existing `AutoClean.select/narrowed` self-test checks (`SelfTest.swift:294–314, 552–553, 1098–1111`) are
  ported to the package's scope tests (same cases, same expectations) before `AutoClean.select` is deleted; none is
  dropped without an equivalent (the 04c method).

## 7. Staging (each its own reviewed PR; dependencies, not roadmap order)

| Stage | What | Level | Safety-critical |
|---|---|---|---|
| **13-1** | Core `AutomationPolicy`/`Scope`/catalog v1/`admits`; `approve(under:)` + refusing the free-form policy approver; package tests incl. golden digest. **App unchanged, unused.** | Senior | **yes** |
| **13-2** | App: consent store + Settings sheet, scheduled runner on the executor, history fields, migration, sites script; remove `AutoClean.run/select/narrowed`, `Cleaner.run` use from the scheduled path. **Needs the caches candidate builder from M01-06** (or that builder is built here for the scheduled subset only — Open question 3). | Senior | **yes** |
| 13-3 | Docs: ARCHITECTURE_V2 §3a, SAFETY_MODEL, RISK_REGISTER (close RISK-017), CURRENT_STATE, MIGRATION_PLAN, DECISIONS (D-011 follow-up). | Junior | no |

13-1 depends on nothing unmerged (the ledger and executor exist). 13-2 depends on 13-1 and on M01-06's caches builder.
Hotspots 13-2 will touch: `check-approval-sites.sh`, `SelfTest.swift`, and `SelfTestSupport.swift` — it must not run
alongside another task touching them (`worktree.sh overlap`). M01-04d currently edits `ci.yml`, three architecture docs and the
warnings baseline; 13-3 must wait for it to merge to avoid editing the same docs.

## 8. Trade-offs and limits

1. **Frozen versions in code** cost a little growth per scope change; the benefit is that "enabled" can never mean
   "whatever the latest code does".
2. **Running the old scope after an update** means a user who never reviews keeps v1 forever (safe, possibly stale).
3. **The consent store is ordinary user-writable storage.** A process running as the user can edit it (or the old
   `auto.weekly` key) — but such a process can already delete the user's files directly. The policy defends against
   code drift, the app's own CLI/MCP, and mistakes, not against other malware as the user. The digest check also makes a
   hand-edited "version 2" or scope fail closed.
4. **Permanent delete with no review.** That is the point of a standing policy; hence the narrow, frozen,
   regenerable-only scope, revalidation, full item listing and an easy off switch. There is no undo for caches; reported
   honestly as "deleted", never "restorable".
5. **No per-run byte cap** in v1. A run can delete many GB of regenerable caches (same as today). A cap with "stop and
   ask" is cheap to add later; it is deliberately not part of this change.
6. **Duplicate work if 13-2 builds the caches candidate builder before M01-06.** Avoided by sequencing (Open question 3).
7. **One executor per process:** the scheduled run and an interactive Trash/Shred wait for each other. Acceptable for
   an infrequent background run (same note as 04c); revisit in 04d-style cleanup if it shows.
8. **Unchanged limits (SAFETY_MODEL.md):** macOS has no "delete only if unchanged"; a process can write to a file it had
   open after the last check.

## 9. Open questions for the reviewer

1. **After an update adds a scope version**, an enabled policy should: **(A, recommended)** keep running the granted
   version and offer a review; or (B) pause until re-enabled (matches ARCHITECTURE_V2's "must re-enable"; stricter,
   but a Mac stops cleaning after every scope-adding update). ARCHITECTURE_V2 §3a wording ("the user must re-enable it
   after seeing the new scope") fits A only for the *new* scope; this design updates that sentence if A is chosen.
2. **Existing users:** pause (recommended) or auto-grant v1 as `.migrated`?
3. **Sequencing:** wait for M01-06 (caches onto the executor) before 13-2 (recommended), or build the
   `CleanTarget` → `CleanupCandidate` builder here for the scheduled subset only?
4. **"Run safe clean now" button** (Settings): today a confirm alert then `AutoClean.run`. Recommended: it is a
   person-started run, so it opens the normal review sheet with the policy-scope items preselected and is approved
   `.userInApp`, not `.standingPolicy`. Alternative: keep an alert but record `.userInApp`.
5. **History:** is adding `approvedBy` and `items` to `history.json` now acceptable, or should the scheduled run wait
   for the JSONL session store?
6. **Scope drift on `skipIfAppRunning`:** acceptable that "running" is judged by `NSWorkspace` bundle id/name/executable
   keys as today (best effort, not a lock)?
