# Feature Matrix (tracker)

One row per backlog item. "Now" = status at commit `8b483b2` (see `FEATURE_GAP_ANALYSIS.md` for evidence).
Update the "Status" column in the same PR that changes a feature. "in review (#N)" means the change is in an open
PR and **not on `main`**; "done" is used only after merge.

| ID | Feature | Now | Milestone | Status | CLI/MCP |
|---|---|---|---|---|---|
| SAFE-01 | Shredder fail-closed + race safety | Unsafe | M00-01 | in review (#26) | n/a |
| SAFE-02 | Test isolation | Unsafe | M00-03 | in review (#28) | n/a |
| SAFE-03 | MCP human approval | Unsafe | M00-04 | todo | yes |
| SAFE-04 | Simulator deletion review-only | Unsafe | M00-05 | todo | yes |
| SAFE-05 | Filesystem correctness (dups, scans, identity) | Unsafe | M00-02, M01-04, M02-01 | dups in review (#27); rest todo | yes |
| SAFE-06 | Release/update integrity | Partial | M00-07, M09 | todo | n/a |
| CLEAN-01 | Smart Scan | Missing | M02-09 | todo | read-only |
| CLEAN-02 | Expanded System Junk | Partial | M02-08 | todo | yes |
| CLEAN-03 | Mail attachments | Partial | M02-07 | todo | yes |
| CLEAN-04 | Trash bins (volumes) | Partial | M02-05 | todo | yes |
| CLEAN-05 | Project junk + Trash-first | Done/Partial | M02-06 | todo | yes |
| CLEAN-06 | Disk hogs | Partial | M00-05, M02 | todo | yes |
| CLEAN-07 | Session history + restore | Partial | M02-02 | todo | read-only |
| CLEAN-08 | Exclusions | Partial | M02-03 | todo | yes |
| CLEAN-09 | Universal Clipboard archives | Missing | M02-04 | todo | yes (paths only) |
| CLEAN-10 | Incomplete scan reporting | Missing | M02-01 | todo | yes |
| APPS-01 | Unused apps | Partial | M03 | todo | read-only |
| APPS-02 | Reset app | Missing | M03 | todo | yes |
| APPS-03 | App updater | Missing | M03 | todo | read-only |
| APPS-04 | Uninstaller hardening | Done/Refactor | M01, M03 | todo | yes |
| APPS-05 | Extensions manager | Partial | M03 | todo | read-only |
| PRIV-01 | Browser privacy | Missing | M05 | todo | no |
| PRIV-02 | Browser extensions | Missing | M05 | todo | read-only |
| PRIV-03 | Permissions overview | Missing/Limited | M05 | todo | no |
| PRIV-04 | Saved Wi-Fi | Missing/Limited | M05 | todo | no |
| PRIV-05 | Malware detection | Missing | M08 | todo | read-only |
| PRIV-06 | Quarantine | Missing | M08 | todo | no |
| PERF-01 | Startup optimisation | Partial | M06 | todo | read-only |
| PERF-02 | Maintenance tasks | Missing | M06 | todo | no |
| PERF-03 | Resource hogs | Missing | M06 | todo | read-only |
| PERF-04 | File associations | Missing | M06 | todo | no |
| PERF-05 | Scheduling + automation policy | Partial | M01-13, M06 | todo | no |
| FILE-01 | Space Lens | Partial | M07 | todo | read-only |
| FILE-02 | Large & old files | Partial | M07 | todo | yes |
| FILE-03 | APFS consolidation | Missing | M07 | todo | no |
| FILE-04 | Universal binary analysis | Missing | M07 | todo | read-only |
| FILE-05 | Binary thinning (restricted) | Missing | M07 | todo | no |
| FILE-06 | Shredder modes/docs | Unsafe | M00-01, M07 | in review (#26) | no |
| MENU-01 | Menu bar PR #17 | Done | M04A (TZ re-verify) | todo | n/a |
| MENU-02 | System statistics | Partial | M04A | todo | read-only |
| MENU-03 | Health alerts | Partial | M04A | todo | n/a |
| MENU-04 | Recommendations | Missing | M04A | todo | n/a |
| MENU-05 | Connected devices | Missing | M04A | todo | n/a |
| MENU-06 | Helper evaluation | Not needed yet | M04A | todo | n/a |
| CLIP-01…12 | Clipboard manager | Missing | M04B | todo | **never** (D-008) |
| L10N | Localization | Missing | M09 | todo | n/a |
| SWIFT6 | Swift 6 mode | Missing | M01 | todo | n/a |
