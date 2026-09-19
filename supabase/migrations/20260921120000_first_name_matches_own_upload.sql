-- ============================================================
-- Sideline: a first name on the form, matched to the mentor's own uploads
-- ------------------------------------------------------------
-- 20260920120000 completes a one-word name from the schedule. That works
-- from the week the schedule was first saved onwards; it cannot help a
-- response from a month ago, because the league's sheet only ever showed the
-- current week and those games were never saved.
--
-- The mentor's own uploads answer the same question for exactly the
-- responses that matter. A mentor filling in the form is writing up a
-- referee they watched that day, and their app evaluations of that day name
-- the referees they watched, in full. So when the form says "Bradley" and
-- that mentor's uploads for that date name exactly one referee whose first
-- name is Bradley - Bradley Shull - the response is about him, and it is
-- already in the app: it is skipped instead of importing as a new referee
-- called "Bradley".
--
-- "Exactly one" is the whole safety of it, as with the schedule. Two
-- Bradleys evaluated by that mentor that day, or none, and the name stays
-- as typed.
--
-- This never files a NEW evaluation under a completed name: a match means an
-- app evaluation of that referee, that mentor and that date exists, which is
-- what "already uploaded from the app" means. It only ever skips.
--
-- This is a forward migration; historical migrations are not rerun manually.
-- ============================================================

-- The one referee that mentor evaluated on that date whose first name this
-- is, or null. p_owner is the account the response belongs to; the typed
-- mentor name covers evaluations uploaded by an account since removed.
create or replace function public.upload_first_name_match(
  p_date date, p_owner uuid, p_mentor text, p_name text)
returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  k    text := public.name_key(p_name);
  hits uuid[];
begin
  if p_date is null or not public.name_is_one_word(p_name) then
    return null;
  end if;
  select array_agg(distinct public.canonical_referee(a.referee_id)) into hits
  from public.evaluations a
  where a.source = 'app' and a.eval_date = p_date
    and (a.mentor_id = p_owner
         or (a.mentor_id is null and public.name_key(p_mentor) <> ''
             and public.name_key(a.mentor_name) = public.name_key(p_mentor)))
    and public.name_key(a.referee_name) like k || ' %';
  if coalesce(array_length(hits, 1), 0) <> 1 then
    return null;
  end if;
  return hits[1];
end;
$$;

-- As 20260920120000, with one addition: when the schedule cannot complete a
-- one-word name, the mentor's own uploads for that day are asked. Everything
-- else is unchanged.
create or replace function public.import_form_evaluations(p_items jsonb, p_apply boolean default false)
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
  own uuid;
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

      -- The account this response belongs to, fixed when it is first
      -- imported: the account that then has the form's mentor name. Only
      -- that account's uploads replace it (see save_evaluations).
      owner_id := case when have then cur.form_owner_mentor_id end;
      if owner_id is null and public.name_key(mentor) <> '' then
        select m.id into owner_id from public.mentors m
        where public.name_key(m.display_name) = public.name_key(mentor)
        limit 1;
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
      own := null;
      if coalesce(it ->> 'use_schedule', 'true') <> 'false'
         and (kept is null or public.name_is_one_word((select r.display_name from public.referees r where r.id = kept))) then
        full_name := public.schedule_full_name(d, fld, k, nm);
        -- No schedule saved for that game: the mentor's own uploads of that
        -- day can still say who a bare first name was.
        if full_name is null then
          own := public.upload_first_name_match(d, owner_id, mentor, nm);
        end if;
      end if;
      if full_name is not null then
        rid := public.find_referee(full_name);
        out_referee := full_name;
        out_from_schedule := true;
      elsif own is not null then
        rid := own;
        select r.display_name into out_referee from public.referees r where r.id = own;
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

revoke execute on function
  public.upload_first_name_match(date, uuid, text, text),
  public.import_form_evaluations(jsonb, boolean)
  from public, anon, authenticated;
grant execute on function public.import_form_evaluations(jsonb, boolean) to authenticated;
