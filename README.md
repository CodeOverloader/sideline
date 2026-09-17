# Sideline

A referee feedback assistant for LSSA mentors: take notes on several referees at once from the sideline, rate them against the Referee Evaluation form, and copy a ready-to-paste block into the Google Form.

Everything needed to take notes works offline and without an account. Mentor accounts add shared referee profiles: every approved mentor's saved evaluations, pooled per referee.

## Files

| File | What it is |
| --- | --- |
| `index.html` | The whole app: markup, styles and script in one file. |
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

4. **Set the site URL.** Under **Authentication → URL Configuration**, set it to `https://codeoverloader.github.io/sideline/`.

5. **Create the database.** Either way below works, and running both is harmless:
   - **Through GitHub (recommended once the repo is linked).** Under **Project Settings → Integrations → GitHub**, check that the Supabase directory points at the folder containing `supabase/`, and switch on **Deploy to production** for `main`. From then on, every file in `supabase/migrations/` is applied when it is merged into `main`. Future schema changes arrive the same way, as new migration files.
   - **By hand.** Open **SQL Editor**, paste the file from `supabase/migrations/`, and run it.

6. **Check the access rules.** In a new SQL Editor tab, paste `supabase/tests.sql` and run it. The final result should read `ALL SIDELINE ACCESS TESTS PASSED`. The script cleans up after itself.

7. **Connect the app.** Open **Settings → API Keys** (or the **Connect** button). Copy the **Project URL** into `SUPABASE_URL` and the **publishable** key (`sb_publishable_…`) into `SUPABASE_PUBLISHABLE_KEY` in `index.html`, then deploy.
   - The publishable key is designed to be public. The access rules protect the data, not the key.
   - Never put a **secret** key (`sb_secret_…`) or the legacy **service_role** key in this repository or the app. They bypass every rule. The app refuses to start accounts if it sees a secret key.
   - Don't use the legacy **anon** key either. Supabase is retiring it by the end of 2026.

8. **Make yourself admin.** Sign in once from the app (the account button, top left), then run this in the SQL Editor:

   ```sql
   update public.mentors
   set role = 'admin', approved_at = now()
   where email = 'you@example.com';
   ```

   From then on you approve other mentors from the app: account button → Manage mentors.

9. **Keep the project awake.** Supabase pauses free projects after a period without activity, and a Saturday-only app can hit that. Check the current policy on Supabase's pricing page, then either use a paid plan or set up a scheduled request that keeps the project active.

10. **Get sign-off before inviting others.** Evaluations are written assessments of named referees, many of them minors. Make sure the league knows where they are stored and who can read them before other mentors start uploading.

### Who can see what

| Account | Can do |
| --- | --- |
| Not signed in | Everything on the device: notes, ratings, saved evaluations, backups. Nothing is uploaded. |
| Pending | Nothing on the server. New sign-ups wait here until an admin approves them. |
| Mentor | Upload their own saved evaluations, read every approved mentor's evaluations, see referee profiles. |
| Admin | Everything a mentor can do, plus approve or remove mentors, merge duplicate referee names, and delete a referee's records on request. |

Only *saved* evaluations are uploaded. Games and notes you are still working on stay on the phone.

### Handling a deletion request

Open the referee's profile as an admin and choose **Delete all records**. This removes every evaluation of that referee, including under merged spellings of the name. You can also run it from the SQL Editor:

```sql
select public.delete_referee_records('<referee id>');
```

Removing a mentor's account keeps their evaluations, attributed by the name they entered on the form. If **Remove** in the app fails, delete the user under **Authentication → Users** instead.
