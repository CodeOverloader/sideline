# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sideline: a referee feedback app for LSSA (youth soccer) mentors. Notes and ratings work offline with no account; optional Supabase accounts add pooled, league-wide referee profiles. README.md has the full setup, roles and admin procedures; DEPLOYMENT_AUDIT.md records the security review.

## Commands

There is no build step, package manager, linter or test runner. The site is static files.

- Run locally: any static server over `http://localhost` (not `file://`, or the service worker and clipboard break), e.g. `python -m http.server 8765`. This Windows machine has no working Node or Python; use a PowerShell `System.Net.HttpListener` server instead.
- With `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` empty the app runs as the original single-device build. Both committed pages point at the **production** project: never sign in to it to test. Use a fake Supabase (define `window.supabase.createClient` before the page runs; both pages skip the CDN when it exists) or a local Postgres + PostgREST harness.
- Database tests: paste `supabase/tests.sql` into the SQL Editor (or run it against a local Postgres) after all migrations. It runs in one rolled-back transaction and ends with the row `ALL SIDELINE ACCESS TESTS PASSED`; a failure raises an error starting `FAIL:`. It lives outside `supabase/migrations/` on purpose so the GitHub integration never applies it.

## Architecture

- `index.html` (~6400 lines): the whole mentor app, with markup, CSS and JS in one file. Supabase config constants are near line 2106.
- `admin/index.html`: separate desktop-first console for league leadership (admins only). Same site, same Supabase login (`storageKey 'sideline:auth'`), same RLS.
- `sw.js`: service worker. Navigations are network-first with a short timeout, same-origin files and fonts cache-first, and everything else (notably the Google Sheet schedule fetch and `*.supabase.co`) is never touched. Bump `CACHE_NAME` when changing the shell. It does not fall back to `index.html` for `/admin` paths.
- `supabase/migrations/`: schema, RLS and `SECURITY DEFINER` functions. All writes go through functions with a pinned `search_path`; the anon key can read nothing.

### Rules that span files

- **Profile code is copied, not shared.** `buildProfile`, `tidyName`, `bestName` and the Supabase config exist in both `index.html` and `admin/index.html`. Change both together. A shared `.js` file was rejected because the cache-first service worker could serve it stale next to a fresh page.
- **Migrations are append-only.** Add a new file named `YYYYMMDDHHMMSS_name.sql`; the GitHub integration applies them by version on merge to `main`, and editing an applied file never reaches production. Migrations must be safe to apply twice.
- **Accounts must never block note-taking.** Only *saved* evaluations sync; in-progress games and notes stay on the device.
- **Roles** are pending / mentor / admin. Admin means league leadership only, never ordinary mentors. Never put a secret or `service_role` key in the repo (the app refuses to start accounts if it sees one).
- **Referee identity is by normalized name** (`name_key`). Merges move records, but a merged bare first name is retired rather than kept wired to the survivor. The form import never guesses a name: it completes a first name only when exactly one referee matches on that game (schedule) or in that mentor's own uploads, and otherwise leaves it as typed.
- **Form import** keys responses by spreadsheet tab and row, and treats an evaluation as already uploaded by referee + date + mentor (kickoff and position are ignored).
- Evaluations concern named minors: keep deletion paths (`delete_referee_records`) in mind.
- Admin-only SQL functions run from the SQL Editor need the JWT claims set for one transaction; see README.md.
