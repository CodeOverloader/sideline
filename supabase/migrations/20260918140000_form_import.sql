-- ============================================================
-- Sideline: importing the Referee Evaluation form's responses
-- ------------------------------------------------------------
-- Applied after 20260918120000_referee_names_any_script.sql. Safe to run
-- more than once.
--
-- Not every evaluation is saved in the app: some mentors only fill in the
-- Google Form. Admins can now bring the form's responses sheet into the
-- database from the admin console, so those evaluations count in the
-- referee profiles too.
--
--  - An imported row has source = 'form' and no mentor_id: it is credited
--    to the name typed on the form. Only admins can change or delete it.
--  - Its identity is the evaluation itself - mentor, date, kickoff, referee
--    and position - not the response's timestamp, so importing the sheet
--    again updates rows in place (Google Forms rewrites the timestamp when
--    a response is edited).
--  - An evaluation that was also uploaded from the app is skipped: the
--    app's copy carries the notes, so it is the one kept. When the app copy
--    is uploaded after the form's was imported, the imported one is removed.
-- ============================================================

alter table public.evaluations add column if not exists source text not null default 'app';
do $$ begin
  alter table public.evaluations add constraint evaluations_source_check check (source in ('app', 'form'));
exception when duplicate_object then null;
end $$;
create unique index if not exists evaluations_form_client_idx on public.evaluations (client_id) where source = 'form';

-- The surviving referee for a name, or null when there is none yet.
-- ensure_referee() without the insert, for previews that change nothing.
create or replace function public.find_referee(p_name text)
returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  rid  uuid;
  nxt  uuid;
  hops int := 0;
begin
  select id into rid from public.referees where name_key = public.name_key(p_name);
  while rid is not null and hops < 10 loop
    select merged_into into nxt from public.referees where id = rid;
    exit when nxt is null;
    rid := nxt;
    hops := hops + 1;
  end loop;
  return rid;
end;
$$;

-- The client_id of an imported evaluation, from what identifies it.
create or replace function public.form_client_id(p_mentor text, p_date date, p_kickoff time, p_referee text, p_position text)
returns text
language sql stable
set search_path = ''
as $$
  select 'form:' || md5(concat_ws('|', public.name_key(p_mentor), coalesce(p_date::text, ''),
    coalesce(to_char(p_kickoff, 'HH24:MI'), ''), public.name_key(p_referee), p_position))
$$;

-- Previews (p_apply = false) or imports (p_apply = true) a batch of form
-- responses. Each item is an object with row (the sheet row, echoed back),
-- mentor_name, eval_date, field, kickoff, division, referee_name, position,
-- the six ratings, move_up, comments and saved_at (the response time).
-- Returns one row per item with out_status:
--   new       not in the database yet          (imported when applied)
--   changed   imported before, and edited since (updated when applied)
--   same      imported before, nothing changed
--   in_app    the mentor uploaded it from the app, so it is skipped
--   error     out_error says why; nothing was saved for it
create or replace function public.import_form_evaluations(p_items jsonb, p_apply boolean default false)
returns table (out_row integer, out_status text, out_error text)
language plpgsql security definer
set search_path = ''
as $$
declare
  it     jsonb;
  rid    uuid;
  cid    text;
  nm     text;
  mentor text;
  d      date;
  k      time;
  pos    text;
  cur    public.evaluations%rowtype;
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
    begin
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
      cid := public.form_client_id(mentor, d, k, nm, pos);
      rid := public.find_referee(nm);

      if d is not null and rid is not null and exists (
          select 1 from public.evaluations a
          where a.source = 'app' and a.referee_id = rid and a.eval_date = d and a.position = pos
            and public.name_key(a.mentor_name) = public.name_key(mentor)
            and (a.kickoff is null or k is null or a.kickoff = k)) then
        out_status := 'in_app';
        -- A copy imported before the app one arrived goes now.
        if p_apply then
          delete from public.evaluations where source = 'form' and client_id = cid;
        end if;
      else
        select * into cur from public.evaluations where source = 'form' and client_id = cid;
        if not found then
          out_status := 'new';
        elsif (cur.referee_name, cur.mentor_name, cur.field, cur.division, cur.move_up, cur.comments,
               cur.appearance, cur.workrate, cur.commands, cur.teamwork, cur.fouls, cur.offsides)
              is not distinct from
              (nm, mentor, coalesce(it ->> 'field', ''), coalesce(it ->> 'division', ''),
               nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''),
               (it ->> 'appearance')::smallint, (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint,
               (it ->> 'teamwork')::smallint, (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint) then
          out_status := 'same';
        else
          out_status := 'changed';
        end if;

        if p_apply and out_status in ('new', 'changed') then
          rid := public.ensure_referee(nm);
          insert into public.evaluations as e (
            mentor_id, client_id, source, referee_id, referee_name, mentor_name,
            eval_date, field, pitch, kickoff, division, position,
            appearance, workrate, commands, teamwork, fouls, offsides,
            move_up, comments, notes, saved_at)
          values (
            null, cid, 'form', rid, nm, mentor,
            d, coalesce(it ->> 'field', ''), '', k, coalesce(it ->> 'division', ''), pos,
            (it ->> 'appearance')::smallint, (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint,
            (it ->> 'teamwork')::smallint, (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint,
            nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''), '[]'::jsonb,
            coalesce(nullif(it ->> 'saved_at', '')::timestamptz, now()))
          on conflict (client_id) where source = 'form' do update set
            referee_id   = excluded.referee_id,
            referee_name = excluded.referee_name,
            mentor_name  = excluded.mentor_name,
            field        = excluded.field,
            division     = excluded.division,
            appearance   = excluded.appearance,
            workrate     = excluded.workrate,
            commands     = excluded.commands,
            teamwork     = excluded.teamwork,
            fouls        = excluded.fouls,
            offsides     = excluded.offsides,
            move_up      = excluded.move_up,
            comments     = excluded.comments,
            saved_at     = excluded.saved_at;
        end if;
      end if;
    exception
      when insufficient_privilege then
        raise;
      when others then
        out_status := 'error';
        out_error := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

-- save_evaluations() as in 20260918120000, plus one step: an app upload
-- removes the imported form copy of the same evaluation.
create or replace function public.save_evaluations(p_items jsonb)
returns table (out_client_id text, out_referee_id uuid, out_updated_at timestamptz, out_error text)
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
    out_client_id := it ->> 'client_id';
    out_referee_id := null;
    out_updated_at := null;
    out_error := null;
    -- Each item in its own block: a refused item rolls back alone.
    begin
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

      -- The same evaluation imported from the form's responses gives way to
      -- this copy, which has the notes: same referee, date, position and
      -- mentor name, and the same kickoff when both have one.
      delete from public.evaluations f
      where f.source = 'form' and f.referee_id = rid
        and f.eval_date = nullif(it ->> 'eval_date', '')::date
        and f.position = it ->> 'position'
        and public.name_key(f.mentor_name) = public.name_key(coalesce(it ->> 'mentor_name', ''))
        and (f.kickoff is null or nullif(it ->> 'kickoff', '') is null
             or f.kickoff = nullif(it ->> 'kickoff', '')::time);
    exception
      when insufficient_privilege then
        raise;
      when others then
        out_referee_id := null;
        out_updated_at := null;
        out_error := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

-- New functions are executable by PUBLIC until revoked by name.
revoke execute on function
  public.find_referee(text),
  public.form_client_id(text, date, time, text, text),
  public.import_form_evaluations(jsonb, boolean)
  from public, anon, authenticated;
grant execute on function public.import_form_evaluations(jsonb, boolean) to authenticated;
