-- Integrity/security follow-up. Append-only and safe to apply repeatedly.
-- Existing duplicate app records are retained for manual reconciliation.
create table if not exists public.suppressed_evaluations (
  source text not null check (source in ('app', 'form')),
  owner_key text not null,
  client_id text not null,
  primary key (source, owner_key, client_id)
);
alter table public.suppressed_evaluations enable row level security;
revoke all on public.suppressed_evaluations from public, anon, authenticated;

-- Validate new/updated notes without rewriting historical records.
create or replace function public.validate_evaluation_notes()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if jsonb_typeof(new.notes) is distinct from 'array' then
    raise exception 'Notes must be an array' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(new.notes) n
             where jsonb_typeof(n) is distinct from 'object'
                or (n ? 'text' and jsonb_typeof(n -> 'text') is distinct from 'string')
                or (n ? 'cat' and jsonb_typeof(n -> 'cat') is distinct from 'string')
                or (n ? 'pol' and n -> 'pol' not in ('-1'::jsonb, '1'::jsonb, '2'::jsonb))
                or (n ? 'at' and jsonb_typeof(n -> 'at') is distinct from 'number')) then
    raise exception 'Each note must have text/category strings, polarity -1, 1 or 2, and a numeric timestamp' using errcode = '22023';
  end if;
  return new;
end;
$$;
drop trigger if exists evaluations_validate_notes on public.evaluations;
create trigger evaluations_validate_notes before insert or update of notes on public.evaluations
for each row execute function public.validate_evaluation_notes();
revoke execute on function public.validate_evaluation_notes() from public, anon, authenticated;

create or replace function public.save_evaluations(p_items jsonb)
returns table (out_client_id text, out_referee_id uuid, out_updated_at timestamptz, out_error text)
language plpgsql security definer
set search_path = ''
as $$
declare
  it     jsonb;
  rid    uuid;
  me     uuid := auth.uid();
  my_name text;
  who    text;
  cur public.evaluations%rowtype;
  have boolean;
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

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evaluation-integrity-writes', 0));
  select btrim(display_name) into my_name from public.mentors where id = me;
  my_name := coalesce(my_name, '');

  for it in select value from jsonb_array_elements(p_items) loop
    out_client_id := it ->> 'client_id';
    out_referee_id := null;
    out_updated_at := null;
    out_error := null;
    -- Each item in its own block: a refused item rolls back alone.
    begin
      -- Serialize an account's saves across devices before looking up identities.
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evaluation-owner:' || me::text, 0));
      if nullif(it ->> 'expected_mentor_id', '') is not null
         and (it ->> 'expected_mentor_id')::uuid <> me then
        raise exception 'Account changed. Sign back into the account that saved this evaluation.' using errcode = '22023';
      end if;
      if my_name = '' then
        raise exception 'Set your account display name before uploading evaluations.' using errcode = '22023';
      end if;
      if exists (select 1 from public.suppressed_evaluations s
                 where s.source = 'app' and s.owner_key = me::text and s.client_id = it ->> 'client_id') then
        raise exception 'This evaluation was deleted by an administrator and cannot be uploaded again.' using errcode = '22023';
      end if;
      select * into cur from public.evaluations e
      where e.mentor_id = me and e.client_id = it ->> 'client_id' for update;
      have := found;
      -- A response lost after commit may be retried with the old version.
      -- Only a byte-equivalent normalized evaluation is an idempotent retry.
      if have and
        (cur.referee_name, cur.eval_date, cur.field, cur.pitch, cur.kickoff, cur.division, cur.position,
         cur.appearance, cur.workrate, cur.commands, cur.teamwork, cur.fouls, cur.offsides,
         cur.move_up, cur.comments, cur.notes, cur.saved_at)
        is not distinct from
        (btrim(it ->> 'referee_name'), nullif(it ->> 'eval_date', '')::date,
         coalesce(it ->> 'field', ''), coalesce(it ->> 'pitch', ''), nullif(it ->> 'kickoff', '')::time,
         coalesce(it ->> 'division', ''), it ->> 'position',
         (it ->> 'appearance')::smallint, (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint,
         (it ->> 'teamwork')::smallint, (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint,
         nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''), coalesce(it -> 'notes', '[]'::jsonb),
         nullif(it ->> 'saved_at', '')::timestamptz) then
        out_referee_id := cur.referee_id;
        out_updated_at := cur.updated_at;
        return next;
        continue;
      end if;
      if have and nullif(it ->> 'expected_updated_at', '') is not null
         and cur.updated_at <> (it ->> 'expected_updated_at')::timestamptz then
        raise exception 'This evaluation changed on another device. Refresh and review it before saving again.' using errcode = '22023';
      end if;
      if have and coalesce(nullif(it ->> 'saved_at', '')::timestamptz, now()) < cur.saved_at then
        raise exception 'An older save cannot replace a newer evaluation. Refresh and review it.' using errcode = '22023';
      end if;
      rid := case when have and public.name_key(cur.referee_name) = public.name_key(it ->> 'referee_name')
                  then public.canonical_referee(cur.referee_id) end;
      rid := coalesce(rid, public.ensure_referee(it ->> 'referee_name'));
      if exists (select 1 from public.evaluations e where e.source = 'app' and e.mentor_id = me
                 and public.canonical_referee(e.referee_id) = rid
                 and e.eval_date = nullif(it ->> 'eval_date', '')::date
                 and e.client_id <> it ->> 'client_id') then
        raise exception 'You already uploaded an evaluation for this referee and date from another saved record. Review both records before combining them.' using errcode = '22023';
      end if;
      who := my_name;

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
        who,
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

      -- Daily identity agrees with form import; ownership is fixed at import.
      delete from public.evaluations f
      where f.source = 'form' and public.canonical_referee(f.referee_id) = rid
        and f.form_owner_mentor_id = me
        and f.eval_date = nullif(it ->> 'eval_date', '')::date;
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

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evaluation-integrity-writes', 0));

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
      if exists (select 1 from public.suppressed_evaluations s where s.source = 'form'
                 and s.client_id in (cid, public.form_client_id(split_part(source_key, '|', 1) || '|', row_no))) then
        raise exception 'This response was deleted by an administrator and cannot be imported again.' using errcode = '22023';
      end if;
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('form-import:' || source_key, 0));

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

      -- Old clients omitted the tab id. Adopt only a complete, timestamped
      -- match; refuse uncertain identities instead of silently duplicating.
      if not have and source_key ~ '\|[0-9]+$' then
        select * into cur from public.evaluations e where e.source = 'form'
          and e.form_source_key = split_part(source_key, '|', 1) || '|'
          and e.form_row = row_no;
        if found then
          if stamp is null or
             (cur.referee_name, cur.mentor_name, cur.eval_date, cur.field, cur.kickoff, cur.division,
              cur.position, cur.move_up, cur.comments, cur.appearance, cur.workrate, cur.commands,
              cur.teamwork, cur.fouls, cur.offsides, cur.saved_at)
             is distinct from
             (nm, mentor, d, fld, k, coalesce(it ->> 'division', ''), pos,
              nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''),
              (it ->> 'appearance')::smallint, (it ->> 'workrate')::smallint,
              (it ->> 'commands')::smallint, (it ->> 'teamwork')::smallint,
              (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint, stamp) then
            raise exception 'A previous import has no tab identity. Review the existing response before importing this tab.' using errcode = '22023';
          end if;
          have := true;
          legacy := true;
        end if;
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

      if owner_id is not null then
        perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evaluation-owner:' || owner_id::text, 0));
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
        if full_name is null and not exists (
            select 1 from public.schedule_slots s where s.game_date = d and s.kickoff = k
              and s.field_key = public.field_key(fld)
              and (s.name_key = public.name_key(nm) or s.name_key like public.name_key(nm) || ' %')) then
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
                 or (owner_id is null and a.mentor_id is null and public.name_key(mentor) <> ''
                     and public.name_key(a.mentor_name) = public.name_key(mentor)))) then
        out_status := 'in_app';
        -- A copy imported before the app one arrived goes now.
        if p_apply and have then
          delete from public.evaluations where id = cur.id;
        end if;
      else
        if not have then
          out_status := 'new';
        elsif not refile and not legacy
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
             or (f.form_owner_mentor_id is null and public.name_key(f.mentor_name) <> ''
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
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('evaluation-integrity-writes', 0));
  -- Keep only opaque source identities, not names or evaluation contents.
  insert into public.suppressed_evaluations(source, owner_key, client_id)
  select source, coalesce(mentor_id::text, ''), client_id from public.evaluations
  where referee_id = p_referee
  on conflict do nothing;
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
         or (p_owner is null and a.mentor_id is null and public.name_key(p_mentor) <> ''
             and public.name_key(a.mentor_name) = public.name_key(p_mentor)))
    and public.name_key(a.referee_name) like k || ' %';
  if coalesce(array_length(hits, 1), 0) <> 1 then
    return null;
  end if;
  return hits[1];
end;
$$;
