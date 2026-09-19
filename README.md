# Sideline

A referee feedback assistant for LSSA mentors: take notes on several referees at once from the sideline, rate them against the Referee Evaluation form, and copy a ready-to-paste block into the Google Form.

Everything needed to take notes works offline and without an account. Mentor accounts add shared referee profiles: every approved mentor's saved evaluations, pooled per referee.

## Files

| File | What it is |
| --- | --- |
| `index.html` | The whole app: markup, styles and script in one file. |
| `admin/index.html` | The admin console for the assignor and league leadership, also one file. |
| `sw.js` | Service worker that keeps the app working with no signal. |
| `manifest.json`, `icon.svg` | Install-to-home-screen metadata. |
| `supabase/migrations/` | Database tables, access rules and functions for accounts. |
| `supabase/tests.sql` | Checks that the access rules refuse what they should. |

## Running it locally

Any static file server works. Open the app over `http://localhost`, not `file://`, or the service worker and clipboard will not work. For example:

```bash
python -m http.server 8765
```

With `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` left empty in `index.html`, the app runs exactly as it always has, with no account features.

## Hosting

The app is served from `https://sideline.codeoverload.dev/` (see `CNAME`), and the old `codeoverloader.github.io/sideline/` address redirects there. It must be opened over **https**: over plain http a browser gives it no service worker (so nothing works without signal) and no clipboard, and its saved data lives in a separate store from the https site's. If the domain is proxied through Cloudflare, switch on **SSL/TLS → Edge Certificates → Always Use HTTPS**. Until then, the app moves itself from http to https when that http copy holds no Sideline data.

## Setting up mentor accounts (Supabase)

You only do this once. Claude cannot create accounts for you, so the Supabase steps are yours.

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
   - **Backups.** Every week or two, open the admin console's **Evaluations** page and use its CSV export. Keep the file somewhere private, never in this repository: it holds evaluations of named minors. It is the league's copy if a **Delete all records** or a bad change ever has to be undone by hand. Supabase's Pro plan ($25 a month) adds daily backups and never pauses, if the league ever wants that instead.

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

An uploaded evaluation is credited to its account's name, which follows the name the mentor types in the app. The phone cannot claim someone else's name, and two accounts cannot share one: the second is asked to add a middle initial. That is what keeps one mentor's uploads from replacing another's imported form evaluations.

## The admin console

`https://sideline.codeoverload.dev/admin/` is a separate page for admins, laid out for a computer and usable on a phone. It shares the app's sign-in, so an admin signed in to either one in a browser is signed in to both there. Anyone who is not an admin sees a note pointing them back to the app. The page hides nothing that matters: the database's access rules decide what every account can read and change, whichever page asks.

One filter row (dates, division, position) applies to every page:

| Page | What it is for |
| --- | --- |
| Overview | Totals against the previous period, evaluations over time, league average by skill, who needs the most support, who mentors recommend moving up, the most common things to work on, and who has gone longest without an evaluation. |
| Referees | Every referee with their averages per skill, sortable and searchable, with a CSV export. Selecting one opens their full profile, trend, notes and evaluations. |
| Evaluations | Every evaluation, newest first, with ratings, notes and comments, and a CSV export in the same columns as the app's own. |
| Mentors | Approving or rejecting sign-ups, each mentor's activity and the average rating they give, and changing who is an admin. |
| Clean-up | Names that may be one referee typed two ways, to merge, and where to handle a deletion request. |
| Import | Brings in evaluations sent with the Google Form but never saved in the app. See below. |

The console keeps no copy of the league's data in the browser; it reads it fresh each time.

### Importing the form's responses

Some mentors only fill in the Referee Evaluation form. **Import** in the admin console brings those responses into the database, so they count in referee profiles like any other evaluation.

1. In the form, open **Responses** and the linked spreadsheet. Share that sheet as **Anyone with the link: Viewer**, because the console reads it the way the app reads the schedule. Anyone who gets hold of the link can then read every response, so keep it among league leadership. If the sheet has several tabs, copy the link while the responses tab is open, so it carries `#gid=…`.
2. Paste the link into **Import** and choose **Fetch responses**. Nothing is saved yet. Each response is shown as new, edited on the form since the last import, already imported, already uploaded from the app, or cannot be imported (with the reason).
3. Choose **Import**. Run it again whenever you like: responses are keyed by the spreadsheet tab and response row, so edited answers are updated in place instead of creating duplicates.

**Never sort, delete or insert rows in the responses tab.** Imported evaluations are matched to their sheet row. If rows move, the import refuses each row that now holds a different game (with the reason) rather than overwrite another evaluation, and you have to put the rows back in their original order to go on. To hide or tidy responses, use a filter view or another tab instead.

A response counts as already uploaded from the app when the app has an evaluation of the same referee, on the same date, in the same position (and kickoff, when both have one), by a mentor with the same name. It is skipped, because the app's copy has the notes. If a mentor uploads from the app after their form response was imported, the imported copy is replaced by the app's.

Imported evaluations are credited to the name typed on the form, not to an account. Only admins can change or delete them. **Delete all records** on a referee removes them too.

### Handling a deletion request

In the admin console, open the referee (from **Referees**, or **Clean-up → Deletion requests**) and choose **Delete all records** at the bottom of their profile. This removes every evaluation of that referee, including under merged spellings of the name. You can also run it from the SQL Editor:

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
