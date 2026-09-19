-- ============================================================
-- Sideline: form responses filed under the right referee
-- ------------------------------------------------------------
-- Two problems, both ending in one evaluation counted twice on a profile.
--
-- 1. Mentors type the referee's name into the form, and often type only a
--    first name. "Jordan" on the form and "Jordan Ellis" in the app are two
--    referees, so the import's "already uploaded from the app" check misses
--    and the response comes in beside the upload. An admin who then merges
--    "Jordan" into "Jordan Ellis" sees both copies on one profile.
--
--    The schedule knows who "Jordan" was: it lists every game's field,
--    kickoff and crew. The admin console now saves the schedule here each
--    time it reads it (the league's sheet only ever shows the current week,
--    so this is how older weeks stay answerable), and the import completes a
--    one-word name from it - but only when exactly one referee on that game
--    has that first name. Anything less certain is left as typed: filing one
--    child's ratings and comments on another child's profile is worse than a
--    duplicate. The admin sees every completion in the preview and can turn
--    it off per response.
--
-- 2. Re-importing looked the referee up from the typed name every time. A
--    response an admin had already filed under the full name - by merging -
--    went back to a new bare "Jordan" as soon as its row was edited, because
--    merged one-word spellings are retired (20260919160000). An imported row
--    now keeps the referee it is filed under while its name is unchanged.
--
-- The prune also matches a form response to the app evaluation of the account
-- that owns it, not only by the mentor's typed name.
--
-- This is a forward migration; historical migrations are not rerun manually.
-- ============================================================

-- ------------------------------------------------------------
-- The schedule, one row per referee per game
-- ------------------------------------------------------------
-- Admin-only: no policies, so clients reach it only through the functions
-- below. It names referees, many of them minors - delete_referee_records
-- clears a referee's rows here too.
create table if not exists public.schedule_slots (
  id           bigint generated always as identity primary key,
  game_date    date not null,
  field        text not null default '',
  field_key    text not null default '',
  kickoff      time not null,
  position     text check (position in ('CR', 'AR')),
  referee_name text not null,
  name_key     text not null,
  saved_at     timestamptz not null default now()
);
create index if not exists schedule_slots_game_idx on public.schedule_slots (game_date, field_key, kickoff);
create index if not exists schedule_slots_name_idx on public.schedule_slots (name_key);
alter table public.schedule_slots enable row level security;
revoke all on public.schedule_slots from public, anon, authenticated;

-- "Legacy Park Field 2A" and "Field 2A" are told apart by the console, which
-- turns schedule fields into the form's dropdown names before sending them.
-- This only has to make the two spellings of one dropdown name agree.
create or replace function public.field_key(p_field text)
returns text
language sql immutable
set search_path = ''
as $$
  select regexp_replace(lower(coalesce(p_field, '')), '[^a-z0-9]+', '', 'g')
$$;

-- Saves the games the console read from the schedule. Each date sent replaces
-- what was saved for that date before, so a crew changed during the week is
-- corrected rather than added to. Dates not in the sheet are left alone:
-- that is how last week survives this week's sheet.
create or replace function public.save_schedule(p_rows jsonb)
returns table (out_saved integer, out_dates integer)
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can save the schedule' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'Expected an array of games' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Send at most 5000 schedule rows at a time' using errcode = '22023';
  end if;

  -- Rows that cannot be matched to a form response are dropped, not refused:
  -- a schedule is full of byes, TBDs and header rows. A bad date or time in
  -- one row still refuses the whole call, so the console checks them first.
  return query
  with incoming as (
    select distinct
      (r ->> 'date')::date as game_date, left(btrim(coalesce(r ->> 'field', '')), 80) as field,
      (r ->> 'kickoff')::time as kickoff,
      case when r ->> 'position' in ('CR', 'AR') then r ->> 'position' end as position,
      left(btrim(r ->> 'referee_name'), 120) as referee_name
    from jsonb_array_elements(p_rows) r
    where coalesce(r ->> 'date', '') ~ '^\d{4}-\d{2}-\d{2}$'
      and coalesce(r ->> 'kickoff', '') ~ '^\d{1,2}:\d{2}(:\d{2})?$'
      and public.name_key(r ->> 'referee_name') <> ''
  ),
  cleared as (
    delete from public.schedule_slots s where s.game_date in (select game_date from incoming)
  ),
  added as (
    insert into public.schedule_slots (game_date, field, field_key, kickoff, position, referee_name, name_key)
    select game_date, field, public.field_key(field), kickoff, position, referee_name, public.name_key(referee_name)
    from incoming
    returning game_date
  )
  select count(*)::integer, count(distinct game_date)::integer from added;
end;
$$;

-- The full name the schedule gives for a one-word name typed on the form, or
-- null. Only when exactly one referee on that game (date, field, kickoff) has
-- that first name - and none of them is listed by the first name alone, since
-- then the schedule does not know either.
create or replace function public.schedule_full_name(p_date date, p_field text, p_kickoff time, p_name text)
returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
  k     text := public.name_key(p_name);
  hits  text[];
begin
  if p_date is null or p_kickoff is null or public.field_key(p_field) = ''
     or not public.name_is_one_word(p_name) then
    return null;
  end if;
  select array_agg(distinct s.name_key) into hits
  from public.schedule_slots s
  where s.game_date = p_date and s.kickoff = p_kickoff and s.field_key = public.field_key(p_field)
    and (s.name_key = k or s.name_key like k || ' %');
  if coalesce(array_length(hits, 1), 0) <> 1 or hits[1] = k then
    return null;
  end if;
  return (select s.referee_name from public.schedule_slots s
          where s.game_date = p_date and s.kickoff = p_kickoff and s.field_key = public.field_key(p_field)
            and s.name_key = hits[1]
          order by s.saved_at desc, s.id limit 1);
end;
$$;

-- ------------------------------------------------------------
-- The import
-- ------------------------------------------------------------
-- Changes from 20260919120000, and nothing else:
--   * out_referee: the name the response is filed under when that is not the
--     name typed on the form, and out_from_schedule when the schedule
--     supplied it. The console shows both before anything is saved.
--   * An item's "use_schedule": false leaves the typed name alone.
--   * An imported row whose name is unchanged stays with its referee,
--     following merges, unless that referee is a bare first name the
--     schedule can now complete.
-- The return type changes, so the function is dropped and made again.
drop function if exists public.import_form_evaluations(jsonb, boolean);

create function public.import_form_evaluations(p_items jsonb, p_apply boolean default false)
returns table (out_row integer, out_status text, out_error text, out_referee text, out_from_schedule boolean)
language plpgsql security definer
set search_path = ''
as $$
declare
  it jsonb;
  rid uuid;
  cid text;
  nm text;
  mentor text;
  d date;
  k time;
  pos text;
  fld text;
  source_key text;
  row_no integer;
  owner_id uuid;
  stamp timestamptz;
  moved_from integer;
  legacy boolean;
  cur public.evaluations%rowtype;
  have boolean;
  full_name text;
  kept uuid;
  refile boolean;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can import evaluations' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Expected an array of responses' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 200 then
    raise exception 'Send at most 200 responses at a time' using errcode = '22023';
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    out_row := case when it ->> 'row' ~ '^\d{1,9}$' then (it ->> 'row')::integer end;
    out_status := null;
    out_error := null;
    out_referee := null;
    out_from_schedule := false;
    begin
      source_key := btrim(coalesce(it ->> 'source_key', ''));
      row_no := out_row;
      if source_key = '' or length(source_key) > 500 or row_no is null or row_no < 2 then
        raise exception 'A valid sheet identity and response row are required' using errcode = '22023';
      end if;
      nm := btrim(coalesce(it ->> 'referee_name', ''));
      if public.name_key(nm) = '' then
        raise exception 'No referee name' using errcode = '22023';
      end if;
      mentor := btrim(coalesce(it ->> 'mentor_name', ''));
      pos := it ->> 'position';
      if pos is null or pos not in ('CR', 'AR') then
        raise exception 'Position must be CR or AR' using errcode = '22023';
      end if;
      if exists (select 1 from jsonb_each_text(it) j
                 where j.key in ('appearance', 'workrate', 'commands', 'teamwork', 'fouls', 'offsides')
                   and j.value is not null and j.value !~ '^[1-4]$') then
        raise exception 'Ratings must be 1 to 4' using errcode = '22023';
      end if;
      if nullif(it ->> 'move_up', '') is not null and it ->> 'move_up' not in ('Yes', 'No') then
        raise exception 'Should they move up must be Yes or No' using errcode = '22023';
      end if;
      d := nullif(it ->> 'eval_date', '')::date;
      k := nullif(it ->> 'kickoff', '')::time;
      fld := coalesce(it ->> 'field', '');
      stamp := nullif(it ->> 'saved_at', '')::timestamptz;
      cid := public.form_client_id(source_key, row_no);

      -- What this sheet row held at the last import, if anything.
      select * into cur from public.evaluations where source = 'form' and client_id = cid;
      have := found;
      legacy := false;
      if not have then
        -- Imported before rows were keyed by sheet row: adopt it.
        select * into cur from public.evaluations
        where source = 'form' and form_source_key is null
          and client_id = public.form_client_id(mentor, d, k, nm, pos);
        have := found;
        legacy := have;
      end if;

      -- Rows moved in the sheet (sorted, deleted or inserted) mean this row
      -- may now hold another response than the evaluation stored for it.
      -- Checked before anything is written or removed. Google Forms moves a
      -- response's time forward when it is edited, never back, and two
      -- responses almost never share a second, so a row has moved when:
      --   its response time was imported from a different row,
      select x.form_row into moved_from from public.evaluations x
      where stamp is not null and x.source = 'form' and x.form_source_key = source_key
        and x.saved_at = stamp and x.form_row <> row_no
      limit 1;
      if found then
        raise exception 'Row % holds the response that was on row % at the last import. Rows in the responses sheet have been moved, sorted or deleted: put them back in their original order, then import again.',
          row_no, moved_from using errcode = '22023';
      end if;
      --   its response is older than the one imported from it,
      --   or it is a different referee in a different game.
      if have and ((stamp is not null and stamp < cur.saved_at)
          or (public.name_key(cur.referee_name) <> public.name_key(nm)
              and (cur.eval_date is distinct from d or cur.kickoff is distinct from k or cur.position <> pos
                   or public.name_key(cur.mentor_name) <> public.name_key(mentor)))) then
        raise exception 'Row % no longer holds the response imported from it (that was % by %). Rows in the responses sheet may have been moved, sorted or deleted: put them back in their original order, then import again.',
          row_no, cur.referee_name, cur.mentor_name using errcode = '22023';
      end if;

      -- Who this response is about.
      --
      -- A row already imported under the same name stays with the referee it
      -- is filed under, following merges: an admin who merged it decided, and
      -- looking the typed name up again would undo that.
      kept := null;
      if have and cur.referee_id is not null and public.name_key(cur.referee_name) = public.name_key(nm) then
        kept := public.canonical_referee(cur.referee_id);
      end if;
      -- A bare first name the schedule can complete, unless the admin said no.
      -- An existing row takes the completion only while it is still filed
      -- under a one-word referee - never over a full name already chosen.
      full_name := null;
      if coalesce(it ->> 'use_schedule', 'true') <> 'false'
         and (kept is null or public.name_is_one_word((select r.display_name from public.referees r where r.id = kept))) then
        full_name := public.schedule_full_name(d, fld, k, nm);
      end if;
      if full_name is not null then
        rid := public.find_referee(full_name);
        out_referee := full_name;
        out_from_schedule := true;
      elsif kept is not null then
        rid := kept;
        select r.display_name into out_referee from public.referees r
        where r.id = kept and public.name_key(r.display_name) <> public.name_key(nm);
      else
        rid := public.find_referee(nm);
      end if;
      -- Filed somewhere else than the last import put it.
      refile := have and full_name is not null
                and (rid is null or rid is distinct from public.canonical_referee(cur.referee_id));

      -- The account this response belongs to, fixed when it is first
      -- imported: the account that then has the form's mentor name. Only
      -- that account's uploads replace it (see save_evaluations).
      owner_id := case when have then cur.form_owner_mentor_id end;
      if owner_id is null and public.name_key(mentor) <> '' then
        select m.id into owner_id from public.mentors m
        where public.name_key(m.display_name) = public.name_key(mentor)
        limit 1;
      end if;

      -- Already uploaded from the app by that account, or by a removed
      -- account under the form's mentor name: same referee (through merges),
      -- same date. Not kickoff or position - see 20260919120000.
      if d is not null and rid is not null and exists (
          select 1 from public.evaluations a
          where a.source = 'app' and a.eval_date = d
            and public.canonical_referee(a.referee_id) = rid
            and (a.mentor_id = owner_id
                 or (a.mentor_id is null and public.name_key(mentor) <> ''
                     and public.name_key(a.mentor_name) = public.name_key(mentor)))) then
        out_status := 'in_app';
        -- A copy imported before the app one arrived goes now.
        if p_apply and have then
          delete from public.evaluations where id = cur.id;
        end if;
      else
        if not have then
          out_status := 'new';
        elsif not refile
          and (cur.referee_name, cur.mentor_name, cur.eval_date, cur.field, cur.pitch, cur.kickoff, cur.division,
               cur.position, cur.move_up, cur.comments, cur.appearance, cur.workrate, cur.commands, cur.teamwork,
               cur.fouls, cur.offsides, cur.saved_at)
              is not distinct from
              (nm, mentor, d, fld, '', k, coalesce(it ->> 'division', ''), pos,
               nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''), (it ->> 'appearance')::smallint,
               (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint, (it ->> 'teamwork')::smallint,
               (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint,
               coalesce(stamp, cur.saved_at)) then
          out_status := 'same';
        else
          out_status := 'changed';
        end if;

        -- An adopted row takes its sheet row, and a row imported before
        -- owners were recorded gets one. Other rows are left untouched, so
        -- phones do not download them again.
        if p_apply and have and (legacy or (cur.form_owner_mentor_id is null and owner_id is not null)) then
          update public.evaluations
          set client_id = cid, form_source_key = source_key, form_row = row_no,
              form_owner_mentor_id = coalesce(form_owner_mentor_id, owner_id)
          where id = cur.id;
        end if;

        if p_apply and out_status in ('new', 'changed') then
          -- The row keeps the name as the mentor typed it; referee_id says
          -- whose profile it counts on.
          rid := case when full_name is null and kept is not null then kept
                      else public.ensure_referee(coalesce(full_name, nm)) end;
          insert into public.evaluations as e (
            mentor_id, client_id, source, form_source_key, form_row, form_owner_mentor_id,
            referee_id, referee_name, mentor_name, eval_date, field, pitch, kickoff, division, position,
            appearance, workrate, commands, teamwork, fouls, offsides, move_up, comments, notes, saved_at)
          values (
            null, cid, 'form', source_key, row_no, owner_id,
            rid, nm, mentor, d, fld, '', k, coalesce(it ->> 'division', ''), pos,
            (it ->> 'appearance')::smallint, (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint,
            (it ->> 'teamwork')::smallint, (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint,
            nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''), '[]'::jsonb,
            coalesce(stamp, now()))
          on conflict (client_id) where source = 'form' do update set
            form_source_key = excluded.form_source_key, form_row = excluded.form_row,
            form_owner_mentor_id = coalesce(e.form_owner_mentor_id, excluded.form_owner_mentor_id),
            referee_id = excluded.referee_id, referee_name = excluded.referee_name, mentor_name = excluded.mentor_name,
            eval_date = excluded.eval_date, field = excluded.field, pitch = excluded.pitch, kickoff = excluded.kickoff,
            division = excluded.division, position = excluded.position, appearance = excluded.appearance,
            workrate = excluded.workrate, commands = excluded.commands, teamwork = excluded.teamwork,
            fouls = excluded.fouls, offsides = excluded.offsides, move_up = excluded.move_up,
            comments = excluded.comments, saved_at = coalesce(stamp, e.saved_at);
        end if;
      end if;
    exception
      when insufficient_privilege then raise;
      when others then
        out_status := 'error'; out_error := sqlerrm; out_referee := null; out_from_schedule := false;
    end;
    return next;
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- The prune, matching the owning account too
-- ------------------------------------------------------------
-- As in 20260919120000, plus: a form response whose owner is known matches
-- that account's app evaluation even when the mentor typed their name on the
-- form differently from their account name.
create or replace function public.prune_duplicate_form_evaluations(p_apply boolean default false)
returns table (
  form_evaluation uuid,
  form_client     text,
  referee         text,
  mentor          text,
  on_date         date,
  duplicates_app  text,
  removed         boolean
)
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin can prune imported evaluations' using errcode = '42501';
  end if;

  return query
  with hits as (
    select f.id, f.client_id, f.referee_name, f.mentor_name, f.eval_date, a.client_id as app_client
    from public.evaluations f
    join lateral (
      select a.client_id
      from public.evaluations a
      where a.source = 'app'
        and a.eval_date = f.eval_date
        and public.canonical_referee(a.referee_id) = public.canonical_referee(f.referee_id)
        and ((f.form_owner_mentor_id is not null and a.mentor_id = f.form_owner_mentor_id)
             or (public.name_key(f.mentor_name) <> ''
                 and public.name_key(a.mentor_name) = public.name_key(f.mentor_name)))
      order by a.saved_at desc, a.id
      limit 1
    ) a on true
    where f.source = 'form' and f.eval_date is not null and f.referee_id is not null
  ),
  gone as (
    delete from public.evaluations e
    using hits h
    where p_apply and e.id = h.id
    returning e.id
  )
  select h.id, h.client_id, h.referee_name, h.mentor_name, h.eval_date, h.app_client,
         exists (select 1 from gone g where g.id = h.id)
  from hits h
  order by h.eval_date, h.referee_name, h.client_id;
end;
$$;

-- ------------------------------------------------------------
-- A deletion request clears the schedule's copies of the name too
-- ------------------------------------------------------------
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
  -- Every spelling of this referee, by display name: a retired spelling's
  -- name_key no longer says what it was. A bare first name merged into them
  -- is skipped - other children are listed by it too.
  delete from public.schedule_slots s
  where s.name_key in (select public.name_key(r.display_name) from public.referees r
                       where r.id = p_referee
                          or (r.merged_into = p_referee and not public.name_is_one_word(r.display_name)));
  delete from public.evaluations where referee_id = p_referee;
  get diagnostics n = row_count;
  delete from public.referees where merged_into = p_referee;
  delete from public.referees where id = p_referee;
  return n;
end;
$$;

revoke execute on function
  public.field_key(text),
  public.save_schedule(jsonb),
  public.schedule_full_name(date, text, time, text),
  public.import_form_evaluations(jsonb, boolean),
  public.prune_duplicate_form_evaluations(boolean),
  public.delete_referee_records(uuid)
  from public, anon, authenticated;
grant execute on function
  public.save_schedule(jsonb),
  public.import_form_evaluations(jsonb, boolean),
  public.prune_duplicate_form_evaluations(boolean),
  public.delete_referee_records(uuid)
  to authenticated;
