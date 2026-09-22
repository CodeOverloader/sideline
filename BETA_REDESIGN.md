# Sideline beta: design decisions and release notes

The beta is a complete visual and workflow revision for two contexts: mentors working on phones at the field, and league administrators working on desktop. It remains a static app and uses the existing league database. Google Sheets schedule import is preserved.

## What changed and why

| Area | Decision | Result |
| --- | --- | --- |
| Visual system | Standardize | Shared colors, spacing, typography, focus indicators, buttons, cards and status treatments across both workspaces. System fonts remove a font download dependency. |
| Mentor navigation | Simplify | Games → Observe → Review follows the matchday workflow. Referees provides shared history; Saved holds local completed evaluations and upload status. |
| First visit | Replace the empty field board | A short introduction leads to schedule import or manual game entry. Backup restore is available for an existing device's records. |
| Games | Make the schedule the primary view | Chronological game cards show kickoff, field, division, full crew names and progress. The field diagram remains available as an optional detail. |
| Observation | Prioritize capture | Full referee names stay visible. Categories and note types have text labels; custom notes and quick notes share one flow. Each referee keeps their own unfinished text. |
| Review and submission | Keep collection in Sideline | Rate, review feedback, and save directly. Approved mentors who enable sharing upload saved evaluations to the league. The separate Google Form submission and copy/paste instructions are removed. |
| Offside | Separate absence from performance | An unobserved or inapplicable skill has no rating and is excluded from averages. It no longer becomes a misleading score of 1. Historical stored scores are unchanged. |
| Completion | Make missing work visible | Missing game details, ratings, feedback or unfinished note text stop a final save. Drafts continue saving locally. Feedback rebuild asks before replacing a manual edit. |
| Save state | Show the actual outcome | Local save, upload waiting, shared success and upload problems are distinct. Edits to notes or covered games enable Save changes even when feedback text is unchanged. |
| Saved evaluations | Make records easier to find | Search by referee, date or field, expand feedback, and reopen the current session's draft. Backup, restore and CSV export remain available. |
| Admin overview | Clarify the next action | Four summary metrics, matchday preparation and training priorities lead the page. Reports and referee profiles retain their underlying analytics. |
| Admin navigation | Use clearer labels | Workspace views are separated from administration. Manage records and Legacy form import describe their purpose. Filters appear where they apply, with a reset action. |
| Accessibility | Standardize interactions | Visible keyboard focus, skip links, labeled rating groups, modal focus containment, background isolation, reduced motion support and text-based status distinctions. |
| Mobile appearance | Prefer outdoor readability | The mentor app starts in a high-contrast light theme; dark mode remains available. The admin workspace follows the device preference until changed. |

## What stays

- Google Sheets schedule fetching, column mapping, field selection, preview and import safeguards. Pasted schedule cells remain a fallback. Division-specific crew rules are preserved.
- One daily evaluation per referee per mentor, including notes from multiple games.
- Offline notes and drafts without requiring an account; consent before sharing saved evaluations.
- Existing email-code sign-in, account approval, access rules, referee profiles, identity merges, record deletion, recovery exports and upload conflict protection.
- The administrator's legacy response importer, so historical records and mentors using the old process remain supported during the transition.

## Shared data and beta isolation

Both beta workspaces keep the existing Supabase project configuration. A real evaluation saved with sharing enabled, or an administrative change made in the published beta, affects the same league records as production.

Beta has its own `sideline-beta:` local-storage keys, `sideline-beta` IndexedDB database, and path-scoped offline cache. Mentor and admin share a beta sign-in; production sign-in and drafts are separate. Beta does not automatically copy production browser storage. A normal Sideline backup can be restored explicitly, including compatible preferences, without importing an authentication session.

Local isolation is per browser origin, with one beta namespace. Hosting two beta copies on different paths of the same origin makes them share beta drafts and sign-in. Their service-worker caches are scoped separately. Use different origins if multiple independent beta installations are required.

The redesign introduces no database migration. The repository's existing migration set, through `20260922120000_evaluation_integrity.sql`, is a prerequisite for publishing these pages. Its deployment to the shared database was not verified or changed during this work.

## Review and verification

`npm test` runs the existing mentor and admin regressions plus beta checks covering completion validation, offside nulls, meaningful changes, unfinished note handling, portable backups, cache isolation and offline routing. These checks use local fixtures and never connect to production.

The local browser review used synthetic accounts and evaluations. It covered phone layouts at 320 and 390 pixels wide, a 1440-pixel desktop admin layout, light and dark themes, onboarding, schedule paste/import, referee switching, note capture, review validation, simulated shared saves, saved-record search, admin search and profiles, legacy import navigation, and modal keyboard behavior.

Offline cache fallback and isolation are checked with a service-worker harness. Real-device installation, actual loss of network on an installed phone, production email delivery and live database writes were not exercised. The sample preview simulates account and upload responses; it does not establish production connectivity.

## Publishing the beta

1. Confirm the existing database migrations are deployed, including `20260922120000_evaluation_integrity.sql`. Do not create a separate database for this beta.
2. Run `npm test`, then `npm run build` from this branch with Node.js available.
3. Publish the **contents of `dist/`** to the intended separate GitHub Pages destination. The build includes only app files and `.nojekyll`; it excludes preview fixtures, private working files, documentation and `CNAME`. The build replaces its previous `dist/` output each time.
4. Keep the beta destination separate from the production Pages deployment. All assets and the manifest use relative paths, so no source edit is needed for a project subdirectory. The admin workspace is at `admin/` beneath the beta address.
5. Open the published HTTPS address, sign into beta with an existing approved account, and verify that league profiles load. Before a real matchday, check installation and offline note capture on a mentor's phone. Any shared save uses live league records.

No site has been published by this work. The removed beta `CNAME` intentionally avoids claiming the production custom domain. If the destination already has a custom domain configured independently, check that setting when publishing.

## Improvements to evaluate after field use

| Improvement | Why it needs real usage or an operational decision |
| --- | --- |
| Retire the old mentor form | Direct collection is ready in beta, but leadership should choose when every mentor switches. Keep legacy import until historical responses are accounted for. |
| Consistent complete referee names | Schedule names still determine identity. Two people with the same abbreviated name cannot be reliably separated by presentation changes. Encourage complete names at the schedule source. |
| Resolve historical rating and identity issues | Old offside scores of 1 do not say whether a situation was observed. Existing ambiguous names or duplicate records require review; the beta does not rewrite them speculatively. |
| Device-to-device draft continuity | Only saved evaluations sync. Moving unfinished observations between phones still requires a backup. Cloud draft sharing would need an explicit ownership/conflict design. |
| Split shared application logic | Mentor/admin profile helpers are still duplicated to retain existing deployment and regression assumptions. A later module extraction should include a versioned asset strategy and equivalent behavior checks. |
| Validate at a live matchday | Observe one mentor completing a full day and one admin reviewing it. Use that evidence to adjust note defaults, repeated actions and terminology. |
