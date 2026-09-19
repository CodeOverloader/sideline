-- ============================================================
-- Sideline: stop the form import filing a second copy of an
-- evaluation the mentor already submitted from the app
-- ------------------------------------------------------------
-- The league takes ONE evaluation per referee per day per mentor, and the app
-- follows that rule: a referee who worked three games on Saturday produces a
-- single evaluation covering all three. The form has one Field, one Time and
-- one Position, so that evaluation can only put one of those games in them.
--
-- The import's "already in the app" check asked for the kickoff and the
-- position to match as well, which is exactly what a whole-day evaluation
-- cannot promise - the mentor may well have typed the second game's time into
-- the form. The check missed, the response imported, and the referee's profile
-- counted one evaluation twice: once from the mentor's upload, once from the
-- form.
--
-- The check now matches on what identifies an evaluation: referee, date and
-- mentor. Kickoff and position describe one of possibly several games and no
-- longer take part. Everything else about the import is untouched.
--
-- This is a forward migration; historical migrations are not rerun manually.
-- ============================================================

-- The surviving referee for an id, following merges. find_referee() answers
-- this for a NAME; this answers it for an id you already hold, and touches no
-- row. The hop limit is a guard, not a feature: merge_referees never creates
-- chains longer than one.
create or replace function public.canonical_referee(p_referee uuid)
returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  rid  uuid := p_referee;
  nxt  uuid;
  hops int := 0;
begin
  while rid is not null and hops < 10 loop
    select merged_into into nxt from public.referees where id = rid;
    exit when nxt is null;
    rid := nxt;
    hops := hops + 1;
  end loop;
  return rid;
end;
$$;

create or replace function public.import_form_evaluations(p_items jsonb, p_apply boolean default false)
returns table (out_row integer, out_status text, out_error text)
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
  source_key text;
  row_no integer;
  owner_id uuid;
  stamp timestamptz;
  moved_from integer;
  legacy boolean;
  cur public.evaluations%rowtype;
  have boolean;
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
      stamp := nullif(it ->> 'saved_at', '')::timestamptz;
      cid := public.form_client_id(source_key, row_no);
      rid := public.find_referee(nm);

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
      -- account under the form's mentor name.
      --
      -- Referee, date and mentor, and deliberately NOT kickoff or position.
      -- One app evaluation covers a referee's whole day and can only carry one
      -- of its games in the form's single Time and Position answers, so asking
      -- those to match made this miss whenever the mentor typed a different
      -- game's details on the form - and the response then imported beside the
      -- upload as a second copy of one evaluation.
      --
      -- The referee is compared through the merge chain, so an app evaluation
      -- filed under a spelling that has since been merged still matches.
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
        elsif (cur.referee_name, cur.mentor_name, cur.eval_date, cur.field, cur.pitch, cur.kickoff, cur.division,
               cur.position, cur.move_up, cur.comments, cur.appearance, cur.workrate, cur.commands, cur.teamwork,
               cur.fouls, cur.offsides, cur.saved_at)
              is not distinct from
              (nm, mentor, d, coalesce(it ->> 'field', ''), '', k, coalesce(it ->> 'division', ''), pos,
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
          rid := public.ensure_referee(nm);
          insert into public.evaluations as e (
            mentor_id, client_id, source, form_source_key, form_row, form_owner_mentor_id,
            referee_id, referee_name, mentor_name, eval_date, field, pitch, kickoff, division, position,
            appearance, workrate, commands, teamwork, fouls, offsides, move_up, comments, notes, saved_at)
          values (
            null, cid, 'form', source_key, row_no, owner_id,
            rid, nm, mentor, d, coalesce(it ->> 'field', ''), '', k, coalesce(it ->> 'division', ''), pos,
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
      when others then out_status := 'error'; out_error := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- Clearing up the copies that are already here
-- ------------------------------------------------------------
-- The check above stops new duplicates; it cannot remove the ones imported
-- before it existed. This lists every form-imported evaluation that duplicates
-- a mentor's own app evaluation - same referee, same date, same mentor - and,
-- only when asked, deletes it.
--
-- It removes the FORM row and never the app row: the mentor's own copy carries
-- their notes, and a form response can always be imported again. Deletes go
-- through the tombstone trigger, so mentors' phones drop the copy on their
-- next pull.
--
-- Dry run, which is the default - shows what it would remove and changes
-- nothing:
--   select * from public.prune_duplicate_form_evaluations();
-- Then, once the list looks right:
--   select * from public.prune_duplicate_form_evaluations(true);
--
-- Two FORM responses duplicating each other are deliberately left alone: that
-- means the form was submitted twice and only a person can say which answers
-- to keep. Delete the extra from the admin console.
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
        and public.name_key(a.mentor_name) = public.name_key(f.mentor_name)
      order by a.saved_at desc, a.id
      limit 1
    ) a on true
    where f.source = 'form' and f.eval_date is not null and f.referee_id is not null
      and public.name_key(f.mentor_name) <> ''
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

-- create or replace keeps existing grants, but say it plainly rather than
-- relying on that: these are admin-only entry points.
revoke execute on function
  public.canonical_referee(uuid),
  public.import_form_evaluations(jsonb, boolean),
  public.prune_duplicate_form_evaluations(boolean)
  from public, anon, authenticated;
grant execute on function
  public.import_form_evaluations(jsonb, boolean),
  public.prune_duplicate_form_evaluations(boolean)
  to authenticated;
