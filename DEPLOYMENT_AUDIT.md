# Sideline pre-deployment audit (2026-09-18)

Scope: `index.html`, `admin/index.html`, `sw.js`, all four migrations, `supabase/tests.sql`, and live probes of
production (`sideline.codeoverload.dev` and the Supabase REST/Auth endpoints, as an anonymous visitor only).

**Bottom line:** the database design is solid for a hobby-scale app. Row Level Security (RLS) is on for every table,
the anonymous key can read nothing (confirmed live), every write goes through `SECURITY DEFINER` functions with a
pinned `search_path`, and the HTML output is escaped. The **must-fix items** are one database hole
(D1), which lets a mentor delete imported evaluations, and the **Supabase dashboard settings** (A1–A3). Those settings
live outside the repo, so nothing in the code enforces them.

Severity: 🔴 fix before inviting mentors · 🟠 fix soon · 🟡 nice to have

## Status after the fix pass (branch `deploy-hardening`)

`supabase/tests.sql` **was failing on `main`**: the last commit changed the test's form response to a new date
and kickoff but not the matching app upload. That is fixed. The whole suite now passes on the local Postgres 16 +
PostgREST harness with the new migration, including when the migration is applied twice.

| Item | Status |
| --- | --- |
| D1 mentor can delete imported rows / sign as someone else | ✅ Fixed. New migration `20260918220000_deploy_hardening.sql`; tests added |
| D2 sorted or edited sheet overwrites a different evaluation | ✅ Import now refuses a row that holds a different game; README warns. Test added |
| D3 old imports would duplicate | ✅ The first import adopts them automatically. Test added |
| D4 RLS per-row function calls | ✅ Policies rewritten |
| D5 last-admin race, stale `mentors.email` | ✅ Lock added; email follows `auth.users` |
| A1/A2 code expiry, rate limits | ✅ Done in the dashboard (2026-09-18) |
| A3 CAPTCHA | ⚠️ Not done. It needs a Cloudflare Turnstile site key from you, then a small change to both pages. **Don't switch it on in Supabase before that change**, or every sign-in fails |
| A4 admin MFA | Not done (later) |
| A5 lost phone | ✅ New **Sign out on all devices** button; lost-phone procedure in README |
| A6 resend cooldown | ✅ 60 s countdown in both pages |
| A7 custom SMTP | ✅ Done (2026-09-18) |
| W1 security headers | ✅ The admin console refuses to run inside a frame (JS), and Cloudflare now adds the headers (2026-09-18) |
| U1 sign-in affordance | ✅ Signed out, the avatar shows a person icon instead of a dot |
| U5 pending: who to ask | ✅ "Ask your assignor or a league admin to approve <email>" |
| U2, U3, U4, U6 | Not changed (minor) |
| P2 backups | Staying on the free plan: export the Evaluations CSV from the admin console every week or two (README step 9) |
| P3 pausing | ✅ Twice-daily keep-alive GitHub job calling a new `keep_alive()` function |
| P1 league sign-off, P4 branch protection | ⚠️ **Yours** |

Behavior changes to know about:
- An uploaded evaluation is credited to the **account's** name. The account name now follows the name typed in
  the app, and a new phone fills in the name from the account.
- Two accounts can't share a name (matched the same way referee names are). The second one sees "Another mentor
  account already uses the name …" on the Account sheet and is asked to add a middle initial.
- An app upload replaces an imported form row only when the form's mentor name matches the uploader's account
  name. An import treats an app evaluation as "already uploaded" by the same rule.

---

## 1. Database (Supabase / Postgres)

### What's already right
- Live probe: `anon` gets `permission denied` on all four tables and on `save_evaluations` / `form_client_id`.
  The `/rest/v1/` schema listing requires a secret key.
- Pending accounts can read nothing. Mentors can't change their own role (only the `display_name` column is granted).
- No secret or `service_role` key in the repo. The publishable key is meant to be public.
- Last-admin protection, per-item error isolation in batch saves, and tombstones so deletions reach every phone.
- The stable-identity migration (`20260918160000`) **is live** in production (its new function signature exists).

### 🔴 D1. Any mentor can delete imported (Google Form) evaluations, and can sign evaluations with someone else's name
`save_evaluations` trusts the client-sent `mentor_name`. After saving, it **deletes** every `source='form'` row with
the same referee, date and position whose mentor name matches that client-sent name
(`20260918140000_form_import.sql`, the `delete from public.evaluations f ...` block). An approved mentor can therefore:
- upload an evaluation that claims to be "Pat Delgado" and erase Pat's imported form evaluation. The design says only
  admins may change or delete imported rows.
- attribute their own evaluations to another mentor's name, which skews the admin console's per-mentor stats.

**Fix (new migration):** in `save_evaluations`, ignore the client's `mentor_name` and use the caller's
`mentors.display_name` (or keep the client value for display only but match the form-delete on the server-side
name). The minimum fix is to restrict the auto-delete to rows whose name key matches the caller's `display_name`.
Add a test to `tests.sql`.

### 🟠 D2. Imported rows are keyed by spreadsheet row number, which shifts
The form import now identifies a response by `sheet id | gid | row`. If anyone deletes or sorts rows in the responses
sheet, row 7 becomes a different response. The next import then shows it as "changed" and **overwrites a different
evaluation**, and the last response looks "new". The README should at least say **never delete, sort or insert rows
in the responses tab**. A sturdier key: row plus the original timestamp as a guard. If the row's content no longer
resembles the stored one (for example, a different referee *and* mentor), report it as a conflict instead of updating.

### 🟠 D3. Rows imported before the stable-identity migration will duplicate
Rows imported under migration 3 have the old `client_id` scheme and `form_source_key = null`. Re-importing gives them
new ids, so they come back as "new" and every one is duplicated. Check production:
```sql
select count(*) from public.evaluations where source = 'form' and form_source_key is null;
```
If it's 0, nothing to do. Otherwise, delete those rows and re-import, or backfill them.

### 🟡 D4. RLS performance
Policies call `public.is_approved()` / `is_admin()` once per row. Wrapping them as `(select public.is_approved())`
lets Postgres evaluate them once per query, which Supabase's own linter recommends. Irrelevant at today's size, but
it's a one-line-per-policy migration.

### 🟡 D5. Smaller notes
- `set_mentor_role` "last admin" check can race if two admins demote each other at the same instant. Very unlikely,
  and fixable with `lock table ... in share row exclusive mode` or `for update`.
- Any admin can remove or demote every other admin. That's by design, but it makes the admin accounts the crown jewels
  (see A4).
- `mentors.email` is copied once at sign-up and goes stale if a user changes their email.
- The old 5-arg `form_client_id(text,date,time,text,text)` is still defined. It's harmless (not executable), and the
  fix for D3 now uses it to recognise old imports.
- `remove_mentor` deletes from `auth.users` directly. That works today, but it's worth a real test in production
  once. The README already has a fallback.

---

## 2. Authentication and sessions

### Do logins persist when you lose connection? **Yes. This is handled well.**
`persistSession: true` keeps the login in `localStorage` (`sideline:auth`). When a token refresh fails offline,
`handleSession` keeps the account and shows an "offline" pill instead of signing out. Only a real `SIGNED_OUT` from
the server ends it. The league cache (IndexedDB) stays for the field. The service worker serves the app shell
offline and never caches Supabase API responses. This design is right.

### Can people brute-force the login? **Partly protected. Depends on dashboard settings you must check.**
There are no passwords, only emailed one-time codes. Brute-forcing a code is limited by Supabase, not by the app.
Current live settings: `disable_signup: false`, and there is no CAPTCHA.

- 🔴 **A1. Shorten the code lifetime.** Supabase defaults the email OTP expiry to **1 hour**. A 6-digit code has
  1,000,000 possibilities. Per-IP verify limits slow one attacker, but many IPs over an hour is a realistic attack on
  a known admin email. In **Authentication → Providers → Email**, set **Email OTP expiration** to **600 s** (10 min)
  and consider **OTP length 8**. The app already accepts 6–10 digits.
- 🔴 **A2. Check Rate Limits** (Authentication → Rate Limits): token verifications and emails sent per hour. Keep the
  defaults or tighten them. Don't raise them to "fix" delivery issues.
- 🟠 **A3. Enable CAPTCHA** (Authentication → Attack Protection → Cloudflare Turnstile, which fits since you're
  already on Cloudflare). Without it, anyone can script `signInWithOtp` with `shouldCreateUser: true` to
  (a) fill your Pending list with junk accounts and (b) burn your SMTP quota or reputation by mailing arbitrary
  addresses. That needs small code changes in both pages to pass `captchaToken`.
- 🟠 **A4. Admin accounts are only as safe as the admin's email inbox.** Consider Supabase TOTP MFA for admins
  later. For today, just keep the admin list tiny.
- 🟠 **A5. Sessions never expire by default.** A lost or stolen phone stays signed in indefinitely, and IndexedDB holds
  a copy of the league's evaluations (named minors). Mitigations:
  - an admin demoting the mentor to *pending* cuts server access immediately (RLS). The next time the phone gets
    online it wipes the league cache. Document this as the "lost phone" procedure.
  - on a paid plan, set **Sessions → Inactivity timeout** (for example, 30 days).
- 🟡 **A6.** No client-side cooldown on "Send a new code". Supabase will rate-limit, but a 30–60 s disabled
  countdown avoids confusing "too many attempts" errors and wasted emails.
- ✅ The admin console uses `shouldCreateUser: false`, so it never creates accounts.
- 🔴 **A7. Custom SMTP must be set up** (from your README, still on the to-do list). Without it, no mentor outside
  your Supabase team receives a code, so the deployment doesn't work for anyone else.

---

## 3. Web / front-end security

- ✅ **XSS:** every interpolation into `innerHTML` I checked goes through `esc()`, and attribute values use double
  quotes, which `esc()` covers. Referee names, comments and notes come from other users, so this is the main XSS
  surface, and it's handled.
- ✅ **CSV injection:** `csvCell` neutralises `= + - @` prefixes in both exports.
- ✅ **Supabase JS** is pinned to an exact version with SRI.
- ✅ **HTTPS:** http now 301-redirects to https (verified live).
- 🟠 **W1. No security headers.** The live site returns no `Content-Security-Policy`, `Strict-Transport-Security`,
  `X-Frame-Options` or `Referrer-Policy`. Since it's behind Cloudflare, add them with a **Transform Rule (response
  headers)**:
  - `Strict-Transport-Security: max-age=31536000`
  - `X-Frame-Options: DENY`, which matters most for `/admin/`: it prevents clickjacking the "Make admin" and
    "Delete all records" buttons from a framing page.
  - `Referrer-Policy: strict-origin-when-cross-origin`
  - A CSP allowing `self`, `cdn.jsdelivr.net`, `fonts.googleapis.com`, `fonts.gstatic.com`, `*.supabase.co`,
    `docs.google.com` and `*.googleusercontent.com`. Test it on a branch first, because inline scripts need
    `'unsafe-inline'` or hashes.
- 🟡 **W2.** The Google Sheet link for imports must be "Anyone with the link". The README warns about this, and it's
  worth repeating to league leadership. Consider un-sharing the sheet after each import.

---

## 4. UI / UX

Checked live at phone size (375 px). No horizontal overflow and no undersized tap targets. The layout is clean, the
dark theme is consistent and the bottom tab bar follows mobile conventions.

- 🟠 **U1. The account entry point is a blank circle with a dot.** Signed out, the top-left avatar shows "●", and
  nothing tells a new mentor it opens sign-in. The README says "the account button, top left". Show a person icon or
  "Sign in" text when signed out.
- 🟡 **U2. Unlabeled icon buttons** (theme ☀ and settings ⚙) rely on icons alone. They have aria-labels, but a
  first-time user guesses.
- 🟡 **U3. "Your name, as it goes on the form"** appears both on the home card and in the Account sheet. It's the same
  value, which is fine, but on the Account sheet it sits above sign-in and reads like part of the login form.
- 🟡 **U4. Code-entry step:** add a visible countdown or "code expires in 10 min" once A1 is done, and the resend
  cooldown (A6).
- 🟡 **U5. Pending state:** after sign-up, the mentor sees "An admin has to approve…" but has no idea *who* to ask.
  Add one line: "Ask the assignor (name/email) to approve you".
- 🟡 **U6.** The admin console has no cached copy offline (by design). The browser's generic offline page appears
  instead. Acceptable, but a one-line note in the README avoids a surprised admin at the field.

---

## 5. Things "forgotten" / process

- 🔴 **P1. League sign-off** (README step 10): evaluations of named minors. Get written OK and agree on a retention
  period, for example deleting evaluations older than N seasons. There's currently no retention job.
- 🟠 **P2. Backups:** the free plan has no point-in-time recovery. Before real data arrives, decide on either a paid
  plan or a scheduled `pg_dump` / CSV export from the console.
- 🟠 **P3. Project pausing** (README step 9): free projects pause after inactivity. A Saturday-only app is at risk.
- 🟠 **P4. Commit `36456d2` (a migration) went straight to `main` without a PR**, and migrations auto-deploy on
  merge to main. Consider a branch-protection rule on `main` so every schema change gets a review and the
  `tests.sql` run first.
- 🟡 **P5.** `supabase/tests.sql` covers RLS and roles well. Add cases for D1 (mentor can't delete form rows / spoof a
  name) once fixed.

---

## Suggested order for today
1. D1 migration + test (≈30 min)
2. Dashboard: A1, A2, A7 (SMTP), then A3 CAPTCHA if time allows
3. D3 check query in production
4. Cloudflare headers (W1), at least HSTS + X-Frame-Options
5. U1 sign-in affordance, U5 pending message
6. README note for D2 (don't reorder the responses sheet) and the lost-phone procedure (A5)
