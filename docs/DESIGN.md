# Design: "Quiet Utility"

Mac Cleaner should feel like a utility Apple could ship: calm, native, and honest about what it does to your files. This page records the UI audit and the decisions behind the current design.

## Audit (before the redesign)

Ordered by user impact, then safety, then effort. Each finding was checked against the code.

| # | Finding | Evidence | Impact |
|---|---|---|---|
| 1 | **Confirm dialogs truncated their item lists.** | 11 dialogs listed only the first 6–14 items (`prefix(6/12/14)` in ContentView, Projects, SDKs, System Data, Large Files, Shredder, Overview, Apps). | Safety: people approved deletions they couldn't see. |
| 2 | **History mixed up "deleted" and "moved to Trash".** | Every cleanup recorded one `bytes` number. Uninstalls and duplicates (which only go to the Trash) showed "Freed X GB" with confetti. "Trash Emptied" recorded `max(measured, expected)`, which can overstate. | Honesty: space looked freed when it wasn't. |
| 3 | **Custom shell instead of native navigation.** | `HStack` + `.ultraThinMaterial` sidebar, a hidden title bar, a fixed 280 pt sidebar, and a 1240×800 minimum window. | Didn't behave like a Mac app (no sidebar collapse, no toolbar, no ⌘-number navigation). |
| 4 | **Too many destinations, duplicated shortcuts.** | 12 sidebar items, plus 8 Quick Tools tiles on Overview repeating them. | Hard to scan; the Overview was busy. |
| 5 | **Fixed-width panels.** | Junk list 370 pt, Apps list 430 pt, Storage Map side panel 380 pt, and fixed-width pickers in filter bars. | Content overflowed or was clipped in small windows. |
| 6 | **Custom styling everywhere.** | Gradient capsule buttons (85 uses of 4 custom button styles), custom colours, card shadows, a gradient window background. | Ignored the user's accent colour and Increase Contrast; looked like a web dashboard. |
| 7 | **Decorative motion.** | Particle bursts, staggered list entrances, bouncing sidebar icons, hover zoom, pulsing scan rings. | Noise; some of it ignored Reduce Motion. |
| 8 | **Settings in a tall scrolling sheet.** | One sheet with Appearance, Access, Automation, Protected, AI and CLI sections. | Not where Mac users look (⌘,). |
| 9 | **Little accessibility support.** | Zero `accessibilityLabel` uses. Checkboxes were plain shapes, and map tiles and SDK rows were tap gestures with no label, value or action. | VoiceOver couldn't tell what was selected. |
| 10 | **No UI tests.** | Only the safety self-test (no UI automation). | Still true; see Limitations. |

One preliminary finding was only partly right: the Junk page's item list was indeed a fixed 370 pt, but the bigger overflow problems were the filter bars (finding 5).

## Decisions

**Native shell.**
- `NavigationSplitView` with a `.sidebar` list in four groups: Overview / Clean Up / Manage / Utilities.
- The toolbar shows the title and subtitle.
- The Go menu has ⌘1 to ⌘0, and ⌘R scans.
- On macOS 26 the sidebar and toolbar get Liquid Glass from the system.
- Minimum window size is 900×600.

**Fewer destinations (12 → 10), no feature removed.**
- Projects and SDKs became **Developer Tools**, with a segmented switch in the toolbar.
- Startup Items and Extensions became **Startup & Extensions**.
- The underlying engines are unchanged.

**Tokens, not one-off styles** (`Theme.swift`).
- Colours map to system colours, so the user's accent colour, light/dark and Increase Contrast all work.
- Spacing, radius and type roles come from one place.
- Buttons are the native `.bordered` / `.borderedProminent` styles.
- Content cards use the system content background with a hairline border and no shadow.

**Glass only where it belongs.**
- `floatingBar()` applies `glassEffect` on macOS 26 (behind `#if compiler(>=6.2)` and `#available`), with `.regularMaterial` on macOS 14–15.
- It is used only for floating notices, never for content cards.

**Overview keeps its dashboard identity.** The original composition stays, rebuilt with native parts:
- **Storage donut** (Swift Charts `SectorMark`, system colours) with a category breakdown.
- **Scan hero** with a large prominent button.
- **Recommended Cleanup** with native checkboxes, marking each category as *deleted* or *to Trash*.
- **Quick Tools grid**: colourful system-colour symbols on neutral tiles.
- **Trash** and **Recent Cleanups**.

- **Insights** (below Recommended Cleanup): one card with a segmented switch between three Swift Charts: space reclaimed per week (deleted vs Trash, from the cleanup history), the free-space trend with a straight-line forecast to the alert level (from one reading per day, stored as numbers only), and junk by category from the last scan. Every tab keeps the same height, and bars and lines grow once on appear (not under Reduce Motion).

It uses two columns in wide windows and one in narrow ones. Cards are solid and readable (not glass), with continuous corners; tiles inside a card use the concentric inner radius (`Radius.inner`).

**Review Cleanup** (`Review.swift`). One sheet replaces every multi-item confirm dialog, styled like a native Mac sheet:
- a header with icon, explanation and summary figures, plus filter tabs (All / To Trash / Deleted / Needs Attention);
- a sortable `Table` with colour-coded **safety badges** (Safe, Review, In Use, Blocked);
- an **inspector** with the selected item's icon, full path, what will happen, the note and a Reveal in Finder button;
- a confirmation footer on the system bar material.

For every item it shows:
- every item, never truncated;
- its full path and size;
- Trash vs permanent;
- its risk (safe / review / in use) and a note (what brings it back, which copy stays);
- whether a guard blocks it, and blocked items are skipped.

It also adds Copy List and Reveal. Deleting anything marked Review or In use needs an explicit checkbox, and Cancel is the keyboard default.

The engines still re-check every guard at execution time (`Cleaner.run`, `AppEngine.trash`, `ProjectEngine.clean`, `SDKEngine.remove`, `SystemDataEngine.remove`). The sheet informs the decision; it is not the only check.

**Honest history.**
- `CleanupRecord` has `outcome` (`deleted` / `trashed`) and `measuredFreeChange`.
- The completion note says "Deleted 2.1 GB" or "Moved 1.4 GB to Trash". VoiceOver announces it, and there is no confetti.
- Settings shows deleted, trashed, and older unclassified totals separately.
- Emptying the Trash records the Trash size and, separately, the measured free-space change.

**Native Settings window** (⌘,) with five tabs: General, Protection, Automation, Permissions, Integrations.

**Motion: native and purposeful.**
- Pages slide in softly, dashboard cards rise in a short 40 ms sequence, and the storage donut sweeps around once.
- Numbers roll with `numericText`. Quick Tools icons bounce once on hover; the scan icon pulses while scanning.
- The completion note springs up with an animated check mark.
- Everything goes through the `Motion` roles or checks `accessibilityReduceMotion`, so Reduce Motion turns it all off.

**Accessibility.**
- Checkboxes report "Selected / Not selected".
- Map tiles, SDK rows and System Data rows are single elements with a label, value, button trait and default action.
- Decorative icons are hidden from VoiceOver.
- Summaries (storage bar, sidebar disk) have combined labels.

## What stayed the same

- Every cleaning feature, safety guard, the self-test, the CLI and the MCP server.
- CLI and MCP keep their preview → confirm behaviour. Only their history records now carry an outcome.
- The interactive treemaps (Junk Files, Storage Map) and the welcome tour.

## Layout bugs found during the redesign

- **Unbounded text broke the window.** A long footer text with `.fixedSize(horizontal: false, vertical: true)` beside a `Spacer` made the page taller than the window and blanked the sidebar list (seen on Shredder). Footers and message bars now use `lineLimit` instead.
- **`preferredColorScheme` emptied the sidebar.** Changing appearance at runtime rebuilt the window and left the sidebar list empty. Appearance is now applied through `NSApp.appearance`, the AppKit way.
- **Inside a `NavigationSplitView` detail, `.inspector` and `HSplitView` misbehaved** (blank sidebar, overlapping banner). The Junk Files list uses a proportional-width column instead.
- **SDK filter chips were cut off at the default window size** once Languages and Homebrew were added. The chips now use `ViewThatFits`: with sizes when they fit, without sizes (still in the tooltip and VoiceOver value) when they don't, and only then scrolling.
- **The Storage Map colour key broke words in half** ("Folde r") in narrow windows. Each key item is now fixed-size; the hint text is dropped first, then the items wrap onto a second line (`FlowRow`).

## Limitations and next steps

- **No UI automation yet.** The checks are the 138-check self-test, the CLI and MCP checks in CI, and manual review in light/dark at 900×652 and 1280×840. A next step is an XCUITest target covering navigation and the Review sheet.
- **Not tested on macOS 14 or 15 hardware.** CI builds with Xcode 16 on macOS 15, which proves the macOS 26 APIs are correctly guarded, but the app has only been run on macOS 26.
- **Not native `Table` yet.** Large & Old Files, Duplicates and Applications still use custom rows, though they now share the system colours, buttons and accessibility patterns. Moving them to `Table` (with column sorting and type-to-select) is the next screen-level step.
- **Single-item confirmations stay as alerts.** Removing one extension or startup item, and Empty Trash, keep a standard alert; they never truncate.
