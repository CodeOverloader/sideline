# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sideline: a referee feedback app for LSSA (youth soccer) mentors. Notes and ratings work offline with no account; optional Supabase accounts add pooled, league-wide referee profiles. README.md has the full setup, roles and admin procedures; DEPLOYMENT_AUDIT.md records the security review.

## Commands

The site is static HTML, CSS and JavaScript, with dependency-free Node scripts for testing and packaging.

- Run locally: `npm run preview` serves synthetic mentor/admin accounts at `http://127.0.0.1:8765/beta/`. Use `?scenario=mentor`, `?scenario=guest` or `admin/?scenario=admin`; `reset=1` clears local beta preview data. The server blocks external connections. See BETA_REDESIGN.md.
- Check: `npm test`. Package: `npm run build` creates the disposable, ignored `dist/` directory. Do not publish preview fixtures or a production-domain CNAME.
- With `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` empty the app runs as the original single-device build. Both committed pages point at the **production** project: never sign in to it to test. Use a fake Supabase (define `window.supabase.createClient` before the page runs; both pages skip the CDN when it exists) or a local Postgres + PostgREST harness.
- Database tests: paste `supabase/tests.sql` into the SQL Editor (or run it against a local Postgres) after all migrations. It runs in one rolled-back transaction and ends with the row `ALL SIDELINE ACCESS TESTS PASSED`; a failure raises an error starting `FAIL:`. It lives outside `supabase/migrations/` on purpose so the GitHub integration never applies it.

## Architecture

- `index.html`: mentor app markup and script; local-first notes, direct evaluation saves, unchanged Google Sheets schedule importer.
- `admin/index.html`: separate desktop-first console for league leadership (admins only). Same beta site, same Supabase login (`storageKey 'sideline-beta:auth'`), same RLS.
- `assets/design-system.css`: shared visual tokens and controls; `assets/mentor.css` and `assets/admin.css` hold workspace-specific styles. Version CSS links and service-worker shell assets together.
- `sw.js`: service worker. Navigations are network-first with a short timeout, same-origin files and fonts cache-first, and everything else (notably the Google Sheet schedule fetch and `*.supabase.co`) is never touched. Bump `CACHE_NAME` when changing the shell. It does not fall back to `index.html` for `/admin` paths.
- `supabase/migrations/`: schema, RLS and `SECURITY DEFINER` functions. All writes go through functions with a pinned `search_path`; the anon key can read nothing.

### Rules that span files

- **Profile code is copied, not shared.** `buildProfile`, `tidyName`, `bestName` and the Supabase config exist in both `index.html` and `admin/index.html`. Change both together. A shared `.js` file was rejected because the cache-first service worker could serve it stale next to a fresh page.
- **Migrations are append-only.** Add a new file named `YYYYMMDDHHMMSS_name.sql`; the GitHub integration applies them by version on merge to `main`, and editing an applied file never reaches production. Migrations must be safe to apply twice.
- **Accounts must never block note-taking.** Only *saved* evaluations sync; in-progress games and notes stay on the device.
- **Beta uses the shared database and separate local storage.** Keep beta keys under `sideline-beta:` and its IndexedDB database under `sideline-beta`. Backup restore translates production preferences without importing authentication. Service-worker cache cleanup must stay within its registration scope.
- **Direct submissions replace the mentor form step.** Keep the Google Sheets schedule pipeline and the admin's legacy response importer. Unobserved offside is null, excluded from averages. Unfinished custom notes belong to their referee and must be resolved before saving a daily evaluation.
- **Roles** are pending / mentor / admin. Admin means league leadership only, never ordinary mentors. Never put a secret or `service_role` key in the repo (the app refuses to start accounts if it sees one).
- **Referee identity is by normalized name** (`name_key`). Merges move records, but a merged bare first name is retired rather than kept wired to the survivor. The form import never guesses a name: it completes a first name only when exactly one referee matches on that game (schedule) or in that mentor's own uploads, and otherwise leaves it as typed.
- **Form import** keys responses by spreadsheet tab and row, and treats an evaluation as already uploaded by referee + date + mentor (kickoff and position are ignored).
- Evaluations concern named minors: keep deletion paths (`delete_referee_records`) in mind.
- Admin-only SQL functions run from the SQL Editor need the JWT claims set for one transaction; see README.md.
