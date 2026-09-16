-- ============================================================
-- Sideline: shared database for mentor accounts + referee profiles
-- ------------------------------------------------------------
-- Applied by the Supabase GitHub integration when this reaches `main`
-- (with "Deploy to production" switched on), or paste it into the SQL
-- editor by hand. Either way it is safe to run more than once: every
-- object is created with IF NOT EXISTS or CREATE OR REPLACE, and
-- policies are dropped before re-creation.
--
-- The security model in one paragraph: the browser app talks to the
-- database directly with the public "publishable" key, so the rules below
-- ARE the security. Every table has Row Level Security on. Nobody can
-- read anything until an admin approves them. Approved mentors can
-- read every evaluation (that is the point of shared profiles) but can
-- only write their own, and only through save_evaluations(), which
-- stamps the caller's id itself. Roles change only through
-- set_mentor_role(), which only an admin may call.
--
-- Bootstrap the first admin after signing in once from the app:
--   update public.mentors set role = 'admin', approved_at = now()
--   where email = 'you@example.com';
-- ============================================================

create extension if not exists unaccent with schema extensions;

-- ------------------------------------------------------------
-- TABLES
-- ------------------------------------------------------------

-- One row per signed-in person. Created automatically on first sign-in
-- (see handle_new_user) as 'pending', which can read nothing.
create table if not exists public.mentors (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text not null default '',
  display_name text not null default '' check (char_length(display_name) <= 80),
  role         text not null default 'pending' check (role in ('pending', 'mentor', 'admin')),
  created_at   timestamptz not null default now(),
  approved_at  timestamptz,
  approved_by  uuid references public.mentors (id) on delete set null
);

-- One row per referee. name_key is the normalised name used to match
-- "Gavin Boor", "gavin boor" and "Boor, Gavin" to the same person.
-- A merged row keeps its name_key (so future saves under that spelling
-- still find it) and points at the surviving row through merged_into.
create table if not exists public.referees (
  id           uuid primary key default gen_random_uuid(),
  display_name text not null check (char_length(display_name) between 1 and 120),
  name_key     text not null unique,
  merged_into  uuid references public.referees (id) on delete set null,
  created_by   uuid references public.mentors (id) on delete set null,
  created_at   timestamptz not null default now()
);

-- One row per saved evaluation, i.e. one Google Form submission.
-- client_id is the id the app gave the record on the phone, so saving
-- the same evaluation again (or restoring a backup) updates this row
-- instead of adding a duplicate. mentor_id is nulled, not cascaded, if
-- a mentor's account is removed: the evaluation stays, attributed by
-- mentor_name.
create table if not exists public.evaluations (
  id           uuid primary key default gen_random_uuid(),
  mentor_id    uuid references public.mentors (id) on delete set null,
  client_id    text not null check (char_length(client_id) between 1 and 64),
  referee_id   uuid not null references public.referees (id),
  referee_name text not null check (char_length(referee_name) between 1 and 120),
  mentor_name  text not null default '' check (char_length(mentor_name) <= 80),
  eval_date    date,
  field        text not null default '' check (char_length(field) <= 80),
  pitch        text not null default '' check (char_length(pitch) <= 8),
  kickoff      time,
  division     text not null default '' check (char_length(division) <= 40),
  position     text not null check (position in ('CR', 'AR')),
  appearance   smallint check (appearance between 1 and 4),
  workrate     smallint check (workrate between 1 and 4),
  commands     smallint check (commands between 1 and 4),
  teamwork     smallint check (teamwork between 1 and 4),
  fouls        smallint check (fouls between 1 and 4),
  offsides     smallint check (offsides between 1 and 4),
  move_up      text check (move_up in ('Yes', 'No')),
  comments     text not null default '' check (char_length(comments) <= 20000),
  notes        jsonb not null default '[]'::jsonb
                 check (jsonb_typeof(notes) = 'array' and jsonb_array_length(notes) <= 500),
  saved_at     timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (mentor_id, client_id)
);
create index if not exists evaluations_referee_idx on public.evaluations (referee_id);
create index if not exists evaluations_updated_idx on public.evaluations (updated_at);

-- The app pulls evaluations incrementally by updated_at, which cannot
-- see a row that no longer exists. Deletions leave a tombstone here so
-- every device can drop its cached copy.
create table if not exists public.evaluation_deletions (
  evaluation_id uuid primary key,
  deleted_at    timestamptz not null default now()
);
create index if not exists evaluation_deletions_at_idx on public.evaluation_deletions (deleted_at);

-- ------------------------------------------------------------
-- HELPERS
-- search_path is pinned to '' on every SECURITY DEFINER function so a
-- caller cannot shadow a table or function with their own.
-- ------------------------------------------------------------

-- "Boor, Gavin" -> "gavin boor";  "José  Núñez-Ruiz" -> "jose nunez ruiz".
-- index.html has a JavaScript twin, nameKey(); keep the two in step.
-- The two-argument unaccent names its dictionary explicitly: with an
-- empty search_path the one-argument form cannot find it.
create or replace function public.name_key(p_name text)
returns text
language sql stable
set search_path = ''
as $$
  select btrim(regexp_replace(
    lower(extensions.unaccent('extensions.unaccent'::regdictionary,
      case when p_name ~ '^[^,]+,[^,]+$'
           then btrim(split_part(p_name, ',', 2)) || ' ' || btrim(split_part(p_name, ',', 1))
           else coalesce(p_name, '')
      end)),
    '[^a-z0-9]+', ' ', 'g'))
$$;

create or replace function public.is_approved()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.mentors
    where id = auth.uid() and role in ('mentor', 'admin'))
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.mentors
    where id = auth.uid() and role = 'admin')
$$;

-- Every new sign-in gets a pending mentors row.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.mentors (id, email)
  values (new.id, coalesce(new.email, ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists evaluations_touch on public.evaluations;
create trigger evaluations_touch
  before update on public.evaluations
  for each row execute function public.touch_updated_at();

create or replace function public.record_evaluation_deletion()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.evaluation_deletions (evaluation_id)
  values (old.id)
  on conflict (evaluation_id) do update set deleted_at = now();
  return old;
end;
$$;

drop trigger if exists evaluations_tombstone on public.evaluations;
create trigger evaluations_tombstone
  after delete on public.evaluations
  for each row execute function public.record_evaluation_deletion();

-- ------------------------------------------------------------
-- RPC FUNCTIONS (the only write paths)
-- ------------------------------------------------------------

-- Returns the surviving referee for a name, creating one if needed.
-- Not callable by clients directly; save_evaluations uses it.
create or replace function public.ensure_referee(p_name text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  k    text;
  rid  uuid;
  nxt  uuid;
  hops int := 0;
begin
  if not public.is_approved() then
    raise exception 'Your account is not approved yet' using errcode = '42501';
  end if;
  p_name := btrim(coalesce(p_name, ''));
  k := public.name_key(p_name);
  if k = '' then
    raise exception 'A referee name is required' using errcode = '22023';
  end if;

  insert into public.referees (display_name, name_key, created_by)
  values (left(p_name, 120), k, auth.uid())
  on conflict (name_key) do nothing
  returning id into rid;
  if rid is null then
    select id into rid from public.referees where name_key = k;
  end if;

  -- Follow merges to the surviving row. The hop limit is a guard, not a
  -- feature: merge_referees never creates chains longer than one.
  loop
    select merged_into into nxt from public.referees where id = rid;
    exit when nxt is null or hops >= 10;
    rid := nxt;
    hops := hops + 1;
  end loop;
  return rid;
end;
$$;

-- Upserts a batch of the caller's evaluations. Each item is an object
-- whose keys match the evaluations columns (client_id, referee_name,
-- mentor_name, eval_date, field, pitch, kickoff, division, position,
-- the six ratings, move_up, comments, notes, saved_at). mentor_id is
-- always the caller; anything else sent for it is ignored.
create or replace function public.save_evaluations(p_items jsonb)
returns table (out_client_id text, out_referee_id uuid, out_updated_at timestamptz)
language plpgsql security definer
set search_path = ''
as $$
declare
  it  jsonb;
  rid uuid;
  me  uuid := auth.uid();
begin
  if not public.is_approved() then
    raise exception 'Your account is not approved yet' using errcode = '42501';
  end if;
  -- Two checks, not one OR: SQL does not promise to evaluate the left side
  -- first, and jsonb_array_length throws on anything that is not an array.
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Expected an array of evaluations' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 100 then
    raise exception 'Send at most 100 evaluations at a time' using errcode = '22023';
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    rid := public.ensure_referee(it ->> 'referee_name');

    insert into public.evaluations as e (
      mentor_id, client_id, referee_id, referee_name, mentor_name,
      eval_date, field, pitch, kickoff, division, position,
      appearance, workrate, commands, teamwork, fouls, offsides,
      move_up, comments, notes, saved_at)
    values (
      me,
      it ->> 'client_id',
      rid,
      btrim(it ->> 'referee_name'),
      coalesce(it ->> 'mentor_name', ''),
      nullif(it ->> 'eval_date', '')::date,
      coalesce(it ->> 'field', ''),
      coalesce(it ->> 'pitch', ''),
      nullif(it ->> 'kickoff', '')::time,
      coalesce(it ->> 'division', ''),
      it ->> 'position',
      (it ->> 'appearance')::smallint,
      (it ->> 'workrate')::smallint,
      (it ->> 'commands')::smallint,
      (it ->> 'teamwork')::smallint,
      (it ->> 'fouls')::smallint,
      (it ->> 'offsides')::smallint,
      nullif(it ->> 'move_up', ''),
      coalesce(it ->> 'comments', ''),
      coalesce(it -> 'notes', '[]'::jsonb),
      coalesce(nullif(it ->> 'saved_at', '')::timestamptz, now()))
    on conflict (mentor_id, client_id) do update set
      referee_id   = excluded.referee_id,
      referee_name = excluded.referee_name,
      mentor_name  = excluded.mentor_name,
      eval_date    = excluded.eval_date,
      field        = excluded.field,
      pitch        = excluded.pitch,
      kickoff      = excluded.kickoff,
      division     = excluded.division,
      position     = excluded.position,
      appearance   = excluded.appearance,
      workrate     = excluded.workrate,
      commands     = excluded.commands,
      teamwork     = excluded.teamwork,
      fouls        = excluded.fouls,
      offsides     = excluded.offsides,
      move_up      = excluded.move_up,
      comments     = excluded.comments,
      notes        = excluded.notes,
      saved_at     = excluded.saved_at
    returning e.client_id, e.referee_id, e.updated_at
      into out_client_id, out_referee_id, out_updated_at;

    return next;
  end loop;
end;
$$;

-- Approve, promote, demote. Refuses to remove the last admin.
create or replace function public.set_mentor_role(p_mentor uuid, p_role text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can change roles' using errcode = '42501';
  end if;
  if p_role not in ('pending', 'mentor', 'admin') then
    raise exception 'Unknown role %', p_role using errcode = '22023';
  end if;
  if p_role <> 'admin'
     and exists (select 1 from public.mentors where id = p_mentor and role = 'admin')
     and (select count(*) from public.mentors where role = 'admin') <= 1 then
    raise exception 'Cannot remove the last admin' using errcode = '42501';
  end if;

  update public.mentors set
    role        = p_role,
    approved_at = case when p_role = 'pending' then null else coalesce(approved_at, now()) end,
    approved_by = case when p_role = 'pending' then null else coalesce(approved_by, auth.uid()) end
  where id = p_mentor;
  if not found then
    raise exception 'No such mentor' using errcode = 'P0002';
  end if;
end;
$$;

-- Deletes a person's sign-in entirely (for rejecting a stranger or
-- removing someone who left). Their evaluations stay, with mentor_id
-- cleared. An admin cannot remove themselves this way.
create or replace function public.remove_mentor(p_mentor uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can remove accounts' using errcode = '42501';
  end if;
  if p_mentor = auth.uid() then
    raise exception 'You cannot remove your own account here' using errcode = '42501';
  end if;
  delete from auth.users where id = p_mentor;
end;
$$;

-- Folds one referee into another: all of p_from's evaluations move to
-- p_into, and p_from (plus anything already merged into it) points at
-- p_into from now on. Both must currently be surviving rows.
create or replace function public.merge_referees(p_from uuid, p_into uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can merge referees' using errcode = '42501';
  end if;
  if p_from = p_into then
    raise exception 'Pick two different referees' using errcode = '22023';
  end if;
  if (select count(*) from public.referees where id in (p_from, p_into) and merged_into is null) <> 2 then
    raise exception 'Both referees must exist and not already be merged' using errcode = '22023';
  end if;

  update public.evaluations set referee_id = p_into where referee_id = p_from;
  update public.referees set merged_into = p_into where id = p_from or merged_into = p_from;
end;
$$;

-- For a deletion request: removes every evaluation of a referee and the
-- referee row itself, including spellings merged into it.
create or replace function public.delete_referee_records(p_referee uuid)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  n integer;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can delete a referee''s records' using errcode = '42501';
  end if;
  delete from public.evaluations where referee_id = p_referee;
  get diagnostics n = row_count;
  delete from public.referees where merged_into = p_referee;
  delete from public.referees where id = p_referee;
  return n;
end;
$$;

-- ------------------------------------------------------------
-- ROW LEVEL SECURITY + GRANTS
-- Supabase grants broad table and function privileges to anon and
-- authenticated by default. Everything is revoked first and then only
-- what the app needs is granted back.
-- ------------------------------------------------------------

alter table public.mentors              enable row level security;
alter table public.referees             enable row level security;
alter table public.evaluations          enable row level security;
alter table public.evaluation_deletions enable row level security;

revoke all on public.mentors, public.referees, public.evaluations, public.evaluation_deletions
  from anon, authenticated;

-- mentors: see your own row (admins see everyone); rename yourself only.
grant select on public.mentors to authenticated;
grant update (display_name) on public.mentors to authenticated;

drop policy if exists mentors_select on public.mentors;
create policy mentors_select on public.mentors
  for select to authenticated
  using (id = (select auth.uid()) or public.is_admin());

drop policy if exists mentors_update_self on public.mentors;
create policy mentors_update_self on public.mentors
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- referees: approved mentors read; writes only through the functions.
grant select on public.referees to authenticated;

drop policy if exists referees_select on public.referees;
create policy referees_select on public.referees
  for select to authenticated
  using (public.is_approved());

-- evaluations: approved mentors read all; writes through
-- save_evaluations; delete your own (admins may delete any).
grant select, delete on public.evaluations to authenticated;

drop policy if exists evaluations_select on public.evaluations;
create policy evaluations_select on public.evaluations
  for select to authenticated
  using (public.is_approved());

drop policy if exists evaluations_delete on public.evaluations;
create policy evaluations_delete on public.evaluations
  for delete to authenticated
  using (
    (public.is_approved() and mentor_id = (select auth.uid()))
    or public.is_admin());

-- tombstones: approved mentors read.
grant select on public.evaluation_deletions to authenticated;

drop policy if exists evaluation_deletions_select on public.evaluation_deletions;
create policy evaluation_deletions_select on public.evaluation_deletions
  for select to authenticated
  using (public.is_approved());

-- functions
revoke execute on function
  public.name_key(text),
  public.is_approved(),
  public.is_admin(),
  public.handle_new_user(),
  public.touch_updated_at(),
  public.record_evaluation_deletion(),
  public.ensure_referee(text),
  public.save_evaluations(jsonb),
  public.set_mentor_role(uuid, text),
  public.remove_mentor(uuid),
  public.merge_referees(uuid, uuid),
  public.delete_referee_records(uuid)
  from public, anon, authenticated;

-- The policies above call these, so the calling role needs EXECUTE.
grant execute on function public.is_approved(), public.is_admin() to authenticated;

grant execute on function
  public.save_evaluations(jsonb),
  public.set_mentor_role(uuid, text),
  public.remove_mentor(uuid),
  public.merge_referees(uuid, uuid),
  public.delete_referee_records(uuid)
  to authenticated;

-- Keep future functions in this schema private unless granted on purpose.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
