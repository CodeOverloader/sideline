-- ============================================================
-- Sideline: keep imported form rows stable when answers are edited
-- ------------------------------------------------------------
-- The linked sheet plus response row is the stable identity. Date, kickoff,
-- names and ratings are answers and may change without creating a duplicate.
-- This is a forward migration; historical migrations are not rerun manually.
-- ============================================================

alter table public.evaluations add column if not exists form_source_key text;
alter table public.evaluations add column if not exists form_row integer;

create unique index if not exists evaluations_form_source_row_idx
  on public.evaluations (form_source_key, form_row)
  where source = 'form' and form_source_key is not null and form_row is not null;

create or replace function public.form_client_id(p_source_key text, p_row integer)
returns text
language sql stable
set search_path = ''
as $$
  select 'form:' || md5(coalesce(p_source_key, '') || '|' || coalesce(p_row::text, ''))
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
  cur public.evaluations%rowtype;
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
      cid := public.form_client_id(source_key, row_no);
      rid := public.find_referee(nm);

      if d is not null and rid is not null and exists (
          select 1 from public.evaluations a
          where a.source = 'app' and a.referee_id = rid and a.eval_date = d and a.position = pos
            and public.name_key(a.mentor_name) = public.name_key(mentor)
            and (a.kickoff is null or k is null or a.kickoff = k)) then
        out_status := 'in_app';
        if p_apply then
          delete from public.evaluations where source = 'form' and client_id = cid;
        end if;
      else
        select * into cur from public.evaluations where source = 'form' and client_id = cid;
        if not found then
          out_status := 'new';
        elsif (cur.referee_name, cur.mentor_name, cur.eval_date, cur.field, cur.pitch, cur.kickoff, cur.division,
               cur.position, cur.move_up, cur.comments, cur.appearance, cur.workrate, cur.commands, cur.teamwork,
               cur.fouls, cur.offsides, cur.saved_at)
              is not distinct from
              (nm, mentor, d, coalesce(it ->> 'field', ''), '', k, coalesce(it ->> 'division', ''), pos,
               nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''), (it ->> 'appearance')::smallint,
               (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint, (it ->> 'teamwork')::smallint,
               (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint,
               coalesce(nullif(it ->> 'saved_at', '')::timestamptz, cur.saved_at)) then
          out_status := 'same';
        else
          out_status := 'changed';
        end if;

        if p_apply and out_status in ('new', 'changed') then
          rid := public.ensure_referee(nm);
          insert into public.evaluations as e (
            mentor_id, client_id, source, form_source_key, form_row,
            referee_id, referee_name, mentor_name, eval_date, field, pitch, kickoff, division, position,
            appearance, workrate, commands, teamwork, fouls, offsides, move_up, comments, notes, saved_at)
          values (
            null, cid, 'form', source_key, row_no,
            rid, nm, mentor, d, coalesce(it ->> 'field', ''), '', k, coalesce(it ->> 'division', ''), pos,
            (it ->> 'appearance')::smallint, (it ->> 'workrate')::smallint, (it ->> 'commands')::smallint,
            (it ->> 'teamwork')::smallint, (it ->> 'fouls')::smallint, (it ->> 'offsides')::smallint,
            nullif(it ->> 'move_up', ''), coalesce(it ->> 'comments', ''), '[]'::jsonb,
            coalesce(nullif(it ->> 'saved_at', '')::timestamptz, now()))
          on conflict (client_id) where source = 'form' do update set
            form_source_key = excluded.form_source_key, form_row = excluded.form_row,
            referee_id = excluded.referee_id, referee_name = excluded.referee_name, mentor_name = excluded.mentor_name,
            eval_date = excluded.eval_date, field = excluded.field, pitch = excluded.pitch, kickoff = excluded.kickoff,
            division = excluded.division, position = excluded.position, appearance = excluded.appearance,
            workrate = excluded.workrate, commands = excluded.commands, teamwork = excluded.teamwork,
            fouls = excluded.fouls, offsides = excluded.offsides, move_up = excluded.move_up,
            comments = excluded.comments, saved_at = excluded.saved_at;
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

revoke execute on function public.form_client_id(text, integer) from public, anon, authenticated;
revoke execute on function public.import_form_evaluations(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.import_form_evaluations(jsonb, boolean) to authenticated;
