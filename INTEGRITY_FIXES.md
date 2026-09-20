# Integrity fix review

Branch: `codex/sideline-integrity-fixes`. No production changes or historical migration edits.

| Review finding | Change |
| --- | --- |
| 1. Malformed notes | Validate note structure, polarity, and timestamp on writes; sanitize old server and cached notes before rendering. |
| 2. Name spoofing | Require the account's display name; remove client-name fallback. |
| 3. Revocation cache | Recheck access before network sync/pull and on foreground/token refresh; clear data on confirmed revocation. |
| 4. Cross-date overwrite | Match saved records only within the session date and compatible account. |
| 5. Merge undone by edit | Preserve canonical referee on updates when the typed name is unchanged. |
| 6. Wrong-owner pruning | Recorded owner takes precedence; names cannot override it. |
| 7. Arrival-order duplicates | Apply the same daily identity to form import and app upload cleanup. |
| 8. Duplicate-only apply | Enable applying previews that contain already-uploaded responses; legacy adoption is actionable. |
| 9. Sheet identity | Require explicit tab number; normalize numeric tab IDs; adopt exact legacy identities safely. |
| 10. Multiple-device duplicate | Reject a second record for the same account/referee/date; retain local data for review. |
| 11. Stale overwrite | Version checks and older-save rejection; identical retries remain safe after lost responses. |
| 12. Wrong profile dedup | Use account ownership, never a shared name, to establish duplicate authors. |
| 13. Inconsistent statistics | Apply matching ownership/day rules to both pages. |
| 14. Ambiguous first name | Do not use upload fallback when the game's schedule has ambiguous or incomplete matching names. |
| 15. Timestamps | Parse AM/PM and fixed league timezone; reject invalid dates and nonexistent DST times. |
| 16. Multiple schedule dates | Refuse mixed-day imports before changing session data. |
| 17. Replacement inherits rating | Protect ratings/comments/move-up/submitted state as well as notes. |
| 18. Deleted records return | Suppress original record identities for future admin referee deletions. |
| 19. Account-switch race | Guard asynchronous results/batches by account generation and validate expected account in upload RPC. |
| 20. Incomplete CSV backup | Add unfiltered recovery JSON with raw records and merge links; clearly document full-backup limits. |

## Validation

- `tests/mentor-regressions.cjs`: save/date/account matching, malformed and cached notes, account-aware profile deduplication, schedule protection, revocation, sync races, and in-flight edit acknowledgements.
- `tests/admin-regressions.cjs`: timestamps/DST, stable tab identity, owner deduplication, recovery export, stale-load protection, and script syntax.
- `tests/run-database.mjs`: all migrations, repeat application of the latest, full access suite, and integrity regressions in isolated PostgreSQL/PGlite.
- Local browser smoke check with a fake account and synthetic records: both pages load, shared profiles render despite a malformed historical note, and a manual evaluation saves locally.

## Operational limits

- Publish the database migration before the updated pages. Production settings, real Supabase Auth behavior, and concurrent multi-connection load were not tested here.
- No existing duplicate evaluations are silently discarded. Historical conflicts and old timezone/tab mismatches require review; local records remain available for backup.
- Recovery JSON is a record export, not a complete database backup or automatic restore format. Auth users, schedules, deletion suppression, and schema are excluded. Use a database backup for full recovery.
- Deletion suppression begins with new admin deletions and follows original record identities. It cannot recognize old deletions, new accounts, copied sheets, or newly generated IDs as the same underlying response.
- Referee identity remains normalized name; two children with the same complete name still need an administrator's identity decision.
