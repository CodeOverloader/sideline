# Sideline Beta

A referee mentoring workspace for LSSA: import the matchday schedule, capture observations on a phone, review each referee's daily evaluation, and save it directly in Sideline. The desktop admin console brings together league reports, referee profiles and account management.

Everything needed to take notes works offline and without an account. Mentor accounts add shared referee profiles: every approved mentor's saved evaluations, pooled per referee.

This branch uses the existing league database. Beta's local drafts, sign-in and offline cache are separate from the production app. See [BETA_REDESIGN.md](BETA_REDESIGN.md) for the design decisions, review results and separate GitHub Pages publishing instructions.

## Files

| File | What it is |
| --- | --- |
| `index.html` | Mentor app markup and script. |
| `admin/index.html` | Desktop admin console markup and script. |
| `assets/design-system.css` | Shared colors, typography, controls and accessibility rules. |
| `assets/mentor.css`, `assets/admin.css` | Layouts and components for each workspace. |
| `sw.js` | Service worker that keeps the app working with no signal. |
| `manifest.json`, `icon.svg`, `assets/*.png` | Install-to-home-screen metadata and icons. |
| `scripts/build-pages.cjs` | Packages the public files into `dist/`. |
| `tests/` | Regression checks and a local preview using synthetic records. |
| `supabase/migrations/` | Database tables, access rules and functions for accounts. |
| `supabase/tests.sql` | Checks that the access rules refuse what they should. |

## Running it locally

Use Node.js to preview without accessing the shared league database:

```bash
npm run preview
```

Open `http://127.0.0.1:8765/beta/?scenario=mentor` or `http://127.0.0.1:8765/beta/admin/?scenario=admin`. `?scenario=guest&reset=1` gives a fresh onboarding preview. These pages use sample names and simulated accounts; external connections are blocked by the preview server. The `reset=1` option clears beta preview data on this local origin.

`npm test` runs the JavaScript checks. `npm run build` creates the deployable `dist/` directory. There are no application packages to install. Any static server can serve that output over localhost, but the built app connects to the shared database, so use the sample preview for routine tests.

## Hosting

Publish `dist/` to the separate beta GitHub Pages destination. This branch has no `CNAME`, and its links, manifest and offline assets work from a project subdirectory. The admin console is at `admin/` beneath that same destination. Serve the app over HTTPS; note-taking, installation and clipboard features depend on the browser's secure-origin rules. Publishing is intentionally not automated on this branch. See the [publishing checklist](BETA_REDESIGN.md#publishing-the-beta).

## Setting up mentor accounts (Supabase)

The committed beta already points at the existing league project; do not create a second database for this beta. The steps below describe the existing account setup and are useful when setting up another league. Apply the existing migration set before using the updated pages; this redesign adds no database migration.

1. **Create the project.** Sign up at [supabase.com](https://supabase.com) and create a project. Pick a region near the league.

2. **Set up an email provider. This is required, not optional.** Supabase's built-in mailer only delivers to members of your own Supabase team, and only 2 messages an hour, so other mentors would never get their sign-in code. Create a free account with a transactional email service (Resend, Postmark, SendGrid, ...), then enter its SMTP details under **Authentication → Emails → SMTP settings**. While you are there, check **Authentication → Rate Limits**.

3. **Send a code, not a link.** Under **Authentication → Emails → Templates**, edit both **Magic Link** and **Confirm signup** so they include the code:

   ```html
   <h2>Your Sideline sign-in code</h2>
   <p>Enter this code in the app: <strong>{{ .Token }}</strong></p>
   <p>It expires shortly. If you did not ask for it, ignore this email.</p>
   ```

   The app asks for the code rather than using a link because, on an iPhone, email links open in Safari instead of the installed app.

   **Make the code short-lived.** Under **Authentication → Providers → Email**, set **Email OTP Expiration** to `600` seconds (the default is an hour), and consider an **Email OTP Length** of `8` (the app accepts 6 to 10 digits). The short lifetime is what stops someone guessing an admin's code: with an hour to try, guesses from many addresses add up. Under **Authentication → Rate Limits**, keep the limits on sign-in emails and code checks at their defaults or lower. Don't raise them to work around email delivery.

   **Turn on bot protection before inviting people.** Anyone can ask the app for a code for any address, which adds a waiting account to your list and sends an email from your SMTP account. Supabase's CAPTCHA option (**Authentication → Attack Protection**) stops scripts doing that, but the app has to send a CAPTCHA token first, so ask for that change before switching it on. Switching it on without that change blocks every sign-in.

4. **Set the site URL.** Under **Authentication → URL Configuration**, set it to `https://sideline.codeoverload.dev/`.

5. **Create the database.** Either way below works, and running both is harmless:
   - **Through GitHub (recommended once the repo is linked).** Under **Project Settings → Integrations → GitHub**, check that the Supabase directory points at the folder containing `supabase/`, and switch on **Deploy to production** for `main`. From then on, every file in `supabase/migrations/` is applied when it is merged into `main`. Future schema changes arrive the same way, as new migration files.
   - **By hand.** Open **SQL Editor**, then paste and run each file in `supabase/migrations/`, oldest first (the file names start with their date). Run each migration once; do not replay an older file after later migrations have been applied.

6. **Check the access rules.** In a new SQL Editor tab, paste `supabase/tests.sql` and run it. The final result should read `ALL SIDELINE ACCESS TESTS PASSED`. The script cleans up after itself.

7. **Connect the app.** Open **Settings → API Keys** (or the **Connect** button). Copy the **Project URL** into `SUPABASE_URL` and the **publishable** key (`sb_publishable_…`) into `SUPABASE_PUBLISHABLE_KEY` in `index.html`, and the same two values into `admin/index.html`, then deploy.
   - The publishable key is designed to be public. The access rules protect the data, not the key.
   - Never put a **secret** key (`sb_secret_…`) or the legacy **service_role** key in this repository or the app. They bypass every rule. The app refuses to start accounts if it sees a secret key.
   - Don't use the legacy **anon** key either. Supabase is retiring it by the end of 2026.

8. **Make yourself admin.** Sign in once from the app (the account button, top left), then run this in the SQL Editor:

   ```sql
   update public.mentors
   set role = 'admin', approved_at = now()
   where email = 'you@example.com';
   ```

   From then on you approve other mentors, and make other leaders admins, in the [admin console](#the-admin-console).

9. **Keep the project awake, and back it up.** Sideline runs on Supabase's free plan, which pauses a project after a week with little database activity and keeps no backups.
   - **Pausing.** The GitHub job `.github/workflows/keep-supabase-awake.yml` calls the database twice a day, which is enough to stop it. If a run fails, GitHub emails you: the project is probably paused, so resume it from the Supabase dashboard. GitHub switches scheduled jobs off in a public repo after 60 days without commits (it emails about that too). Switch it back on under **Actions → Keep Supabase awake**. While the project is paused, note-taking still works, but signing in, uploading and referee profiles do not.
   - **Backups.** Use **Evaluations → Export recovery JSON** for an unfiltered copy of evaluation fields and notes, mentor records, and referee merge links. Keep it private, never in this repository. CSV is a filtered report, not a backup. The JSON supports manual record recovery but excludes Auth users, schedules, deletion records, and the database schema; use a complete database backup for disaster recovery. There is no automatic JSON restore button.

10. **Get sign-off before inviting others.** Evaluations are written assessments of named referees, many of them minors. Make sure the league knows where they are stored and who can read them before other mentors start uploading.

### Who can see what

| Account | Can do |
| --- | --- |
| Not signed in | Everything on the device: notes, ratings, saved evaluations, backups. Nothing is uploaded. |
| Pending | Nothing on the server. New sign-ups wait here until an admin approves them. |
| Mentor | Upload their own saved evaluations, read every approved mentor's evaluations, see referee profiles. |
| Admin | Everything a mentor can do in the app, plus the admin console: approve or remove mentors, make other admins, merge duplicate referee names, delete a referee's records on request, and league reports. |

Only *saved* evaluations are uploaded. Games and notes you are still working on stay on the phone.

Admin is for league leadership, such as the assignor, not for mentors. The app itself looks the same for an admin as for a mentor, apart from a link to the console on the Account sheet.

An uploaded evaluation is credited to its account's name, which follows the name the mentor types in the app. The phone cannot claim someone else's name, and two accounts cannot share one: the second is asked to add a middle initial. An imported form evaluation belongs to the account that had its mentor name when it was first imported, and only that account's upload of the same game replaces it. Renaming later, or taking a removed mentor's name, does not change who it belongs to.

## The admin console

`admin/` beneath the beta address is a separate page for admins, laid out for a computer and usable on a phone. It shares beta's sign-in, so an admin signed in to either beta workspace in a browser is signed in to both there. Production's sign-in remains separate. Anyone who is not an admin sees a note pointing them back to the app. The database's access rules decide what every account can read and change, whichever page asks.

One filter row (dates, division, position) applies to the reporting views. It is hidden on the import and record-management pages, where those filters do not apply:

| Page | What it is for |
| --- | --- |
| Overview | Totals against the previous period, evaluations over time, league average by skill, who needs the most support, who mentors recommend moving up, the most common things to work on, and who has gone longest without an evaluation. |
| Referees | Every referee with their averages per skill, sortable and searchable, with a CSV export. Selecting one opens their full profile, trend, notes and evaluations. |
| Evaluations | Every evaluation, newest first, with ratings, notes and comments, and a CSV export in the same columns as the app's own. |
| Mentors | Approving or rejecting sign-ups, each mentor's activity and the average rating they give, and changing who is an admin. |
| Manage records | Names that may be one referee typed two ways, to merge, and where to handle a deletion request. |
| Legacy form import | Brings in historical Google Form responses and supports the transition to direct submissions. See below. |

The console keeps no copy of the league's data in the browser; it reads it fresh each time.

### Importing the form's responses

Beta mentors save evaluations in **Review** and no longer need to submit a Google Form. **Legacy form import** remains available for historical responses and mentors still using the original process. References to **Import** below mean this legacy admin tool, not the mentor's unchanged schedule import.

1. In the form, open **Responses** and the linked spreadsheet. Share that sheet as **Anyone with the link: Viewer**, because the console reads it the way the app reads the schedule. Anyone who gets hold of the link can then read every response, so keep it among league leadership. Always copy the link while the responses tab is open, including its explicit `#gid=…` tab number. Spreadsheet-only links are refused because they do not reliably identify a tab.
2. Paste the link into **Import**, and paste the league's schedule sheet into **Link to the schedule sheet** below it (optional, but it is what completes the first names mentors type — see below). Choose **Fetch responses**. Nothing is saved yet. Each response is shown as new, edited on the form since the last import, already imported, already uploaded from the app, or cannot be imported (with the reason).
3. Choose **Apply**. Run it again whenever you like: responses are keyed by the spreadsheet tab and response row, so edited answers are updated in place instead of creating duplicates.

The responses sheet must use the league timezone, **America/Chicago**, and timestamps formatted as `M/D/YYYY H:MM:SS` (24-hour or AM/PM). Imports interpret that timezone consistently on every computer. Older imports created in another timezone, or without a tab number, may require an administrator to reconcile the existing rows. Exact unchanged legacy rows are adopted; uncertain matches are refused instead of overwritten.

**Never sort, delete or insert rows in the responses tab.** Imported evaluations are matched to their sheet row. If rows move, the import recognises each moved response by its time stamp and refuses it (with the reason) rather than overwrite another evaluation. You then have to put the rows back in their original order to go on. To hide or tidy responses, use a filter view or another tab instead.

A response counts as already uploaded when an app evaluation has the same referee, date, and recorded owner account. Kickoff and position do not participate: an evaluation covers the referee's day. The app copy wins in either arrival order. **Apply** also removes existing matching imported copies when there are no new responses. A known owner is never replaced by another account merely because its name matches.

Imported evaluations are credited to the name typed on the form, not to an account. Only admins can change or delete them. **Delete all records** on a referee removes them too.

### Merging two spellings of one referee

**Manage records** lists names that may be one referee typed two ways. Merging moves
every evaluation from the losing spelling to the surviving one.

What happens to *later* saves depends on the losing name:

- **A misspelling** — "Jon Smyth" folded into "Jon Smith" — stays wired to the
  survivor. Every later save under the wrong spelling lands on the right
  referee. That is what merging is for.
- **A single name** — "Jordan" folded into "Jordan Ellis" — does not. The
  records already there move, because the admin doing the merge knows whose
  they are, but the spelling is retired. The next referee the schedule lists
  only as "Jordan" starts a referee of their own.

The second rule exists because a first name is not an identity. Before it, a
merged "Jordan" kept catching saves, so a different child listed the same way
had their ratings and comments filed onto Jordan Ellis's profile weeks later,
with nothing on screen to say so. Merge them again if you know it is the same
person.

Names written without spaces because that is how the script works — Chinese,
Japanese and Korean — count as complete names, not single ones.

This does not make two referees who share a first name safe to tell apart.
Where the schedule only ever gives one name, two children called Jordan still
share a profile until someone types more. The lasting fix is fuller names in
the schedule.

### First names on the form, completed from the schedule

Mentors type the referee's name into the form by hand, and often type only a
first name. "Jordan" and "Jordan Ellis" are two different referees, so the
response used to import beside the mentor's own upload as a second copy of one
evaluation.

When the schedule sheet's link is filled in on **Import**, every fetch saves
that week's games — date, field, kickoff and crew — to the database, and the
import completes a one-word name from them: the referee on **that game** whose
first name it is. The league's sheet only ever shows the current week, which is
why each fetch saves it; older weeks stay behind for older responses.

**When no schedule was saved for that game**, the mentor's own uploads answer
the same question. A mentor filling in the form is writing up a referee they
watched that day, and their app evaluations for that date name the referees they
watched in full — so if the form says "Bradley" and that mentor's uploads for
that day name exactly one Bradley, the response is about him, and it is skipped
as already uploaded from the app instead of importing as a new referee called
"Bradley". This is what catches responses from weeks whose schedule was never
saved. It only ever skips a response; it never files a new one under a guessed
name.

A name is completed **only when exactly one referee on that game has it**. Two
Jordans on the same game, no schedule for that game, or a schedule that lists
only "Jordan" itself: the name is left exactly as typed. Guessing would file one
child's ratings and comments on another child's profile, which is worse than a
duplicate.

Every completion is shown in the preview before anything is saved — "Jordan,
filed as Jordan Ellis (schedule)" — with a box you can clear to import that one
response under the name as typed. The evaluation always keeps the mentor's own
wording; it is the profile it counts towards that changes.

Once an imported response is filed under a referee, it stays there while its
name on the form is unchanged, including when you have merged it onto someone
yourself. The exception is a response still filed under a bare first name: if
the schedule can complete it later, the next import moves it.

The schedule sheet is read exactly like the mentor app reads it (Date, Time,
Field, and CR/AR or Crew columns, found by name), and needs the same
**Anyone with the link can view** sharing. It holds referees' names, so keep the
link among league leadership. **Delete all records** on a referee clears their
schedule rows too.

### Duplicate evaluations from the form import

The league takes one evaluation per referee per day per mentor, and the app
files a referee's whole day as a single evaluation. Because the form has only
one Field, Time and Position, that evaluation can only name one of the games it
covers — so the import decides a response is already in the app by **referee,
date and mentor**, and deliberately ignores kickoff and position.

Responses imported before that check existed can still be sitting beside a
mentor's own upload. To find them, run this in the SQL Editor. On its own it
only reports:

```sql
select * from public.prune_duplicate_form_evaluations();
```

The SQL Editor is not signed in as anyone, so that call answers **"Only an
admin can prune imported evaluations"**. Say which admin you are for the one
transaction, and nothing is left behind afterwards:

```sql
begin;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from public.mentors where role = 'admin' limit 1),
                    'role', 'authenticated')::text, true);
select * from public.prune_duplicate_form_evaluations();
rollback;
```

Run it again with `prune_duplicate_form_evaluations(true)` and `commit;` in
place of `rollback;` once the list looks right. The same applies to any other
admin-only function run from the SQL Editor.

Each row is a form-imported evaluation that duplicates an app one, and names
the app evaluation it duplicates. Once the list looks right, remove them:

```sql
select * from public.prune_duplicate_form_evaluations(true);
```

It only ever deletes the imported copy, never the mentor's own — theirs carries
their notes, and a form response can be imported again. Mentors' phones drop
the removed copy on their next refresh.

Two *form* responses duplicating each other are left alone: that means the form
was submitted twice, and only a person can say which answers to keep. Delete
the extra from the admin console.

### Handling a deletion request

In the admin console, open the referee (from **Referees**, or **Manage records → Deletion requests**) and choose **Delete all records** at the bottom of their profile. This removes every evaluation of that referee, including under merged spellings of the name. New deletions also retain opaque record identities so the same phone record or spreadsheet response cannot recreate the deleted evaluation. This does not erase local phone copies or the Google Sheet, identify records deleted before this protection existed, or prohibit genuinely new evaluations with new identities. You can also run it from the SQL Editor:

```sql
select public.delete_referee_records('<referee id>');
```

Removing a mentor's account keeps their evaluations, attributed by the name they entered on the form. In the admin console, **Revoke** their access, then **Reject** them from the waiting list. If that fails, delete the user under **Authentication → Users** instead.

### A lost or stolen phone

A signed-in phone stays signed in, and keeps a copy of the league's evaluations for use without signal. If one goes missing:

1. **Revoke** that mentor's access in the admin console straight away. The database stops answering that account at once, and the phone deletes its copy of other mentors' evaluations the next time it connects.
2. The mentor signs in on another phone or computer and chooses **Sign out on all devices** on the Account sheet. That ends the lost phone's login too, within the hour.
3. The mentor signs in again, and you approve them again. Approve them only after step 2: the lost phone would otherwise get its access back with them.

On a paid Supabase plan you can also set **Authentication → Sessions → Inactivity timeout** (for example 30 days), so a forgotten phone signs itself out.


## Integrity fixes and regression checks

Deploy `20260922120000_evaluation_integrity.sql` after the earlier migrations, before publishing the updated pages. The migration is repeatable. Existing duplicate app records are retained for review; new saves from another device for the same account/referee/date are refused instead of silently discarding either record. Older or conflicting edits also remain on the device with an upload error. Back up the local record, review the league copy, and have an admin reconcile conflicting records before retrying. A normal profile refresh does not overwrite local notes or automatically resolve a conflict.

Referee profiles use recorded account ownership for duplicate detection. Distinct or unknown authors remain separate even when their typed names match. Changing a session's date creates a new daily save. Schedule import accepts one day at a time and protects existing assessments when a referee assignment changes.

Offline JavaScript checks (Node.js, no application dependencies):

```sh
node tests/mentor-regressions.cjs
node tests/admin-regressions.cjs
node tests/beta-regressions.cjs
```

Database checks use an isolated PostgreSQL engine through PGlite 0.5.8. Extract that package outside the repository, set `PGLITE_MODULE` to its `dist/index.js`, then run:

```sh
node tests/run-database.mjs
```

The runner applies every migration, applies the newest twice, and runs `supabase/tests.sql` plus `supabase/integrity_tests.sql`. It supplies minimal Supabase Auth fixtures and never connects to production. The SQL suites can also run on an isolated Supabase/PostgreSQL test project. See `INTEGRITY_FIXES.md` for review coverage and remaining operational limits.
