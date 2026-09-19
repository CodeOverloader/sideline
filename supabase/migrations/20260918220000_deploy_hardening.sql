-- ============================================================
-- Sideline: hardening before other mentors are invited
-- ------------------------------------------------------------
-- Applied after 20260918160000_form_import_stable_identity.sql. Safe to
-- run more than once.
--
-- 1. An evaluation's mentor name comes from the account, not the upload.
--    save_evaluations() used the mentor_name the phone sent, and deleted
--    any imported form row with that name, the same referee, date and
--    position. Any approved mentor could therefore sign evaluations with
--    someone else's name and delete that person's imported evaluations,
--    which only admins are meant to do. Now:
--      - an uploaded evaluation carries the account's display_name (the
--        sent name is only used while the account has none);
--      - an upload replaces only form rows credited to the account's own
--        name;
--      - an import counts an app evaluation as "already uploaded" only
--        when that evaluation's account has the form's mentor name.
--    Two accounts can no longer take the same name, so a mentor cannot
--    rename themselves into someone else.
--
-- 2. Imports notice when the responses sheet was re-sorted or had rows
--    deleted. Imported rows are keyed by sheet row; if a row now holds a
--    different referee in a different game than the one imported from it,
--    the import refuses that row instead of overwriting another
--    evaluation.
--
-- 3. Rows imported before 20260918160000 (keyed the old way, with no
--    form_source_key) are adopted by the first import that sees them,
--    instead of coming back as duplicates.
--
-- 4. Access rules evaluate is_approved()/is_admin() once per query
--    instead of once per row.
--
-- 5. Two admins demoting each other at the same moment can no longer
--    leave the league with none.
--
-- 6. mentors.email follows a change of sign-in email.
--
-- 7. keep_alive(), for the scheduled GitHub job that keeps a free project
--    from pausing (.github/workflows/keep-supabase-awake.yml). It reads
--    nothing and is the only thing anonymous callers may run.
-- ============================================================

-- ------------------------------------------------------------
-- 1a. One account per name
-- ------------------------------------------------------------
create or replace function public.check_mentor_name()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.display_name := btrim(coalesce(new.display_name, ''));
  if public.name_key(new.display_name) <> '' and exists (
      select 1 from public.mentors m
      where m.id <> new.id and public.name_key(m.display_name) = public.name_key(new.display_name)) then
    raise exception 'Another mentor account already uses the name "%". Add a middle initial or similar so the two of you can be told apart.',
      new.display_name using errcode = '23505';
  end if;
  return new;
end;
$$;

drop trigger if exists mentors_name_check on public.mentors;
create trigger mentors_name_check
  before insert or update of display_name on public.mentors
  for each row execute function public.check_mentor_name();

-- ------------------------------------------------------------
-- 1b. save_evaluations: the account's name, and only its own form rows
-- ------------------------------------------------------------
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

  select btrim(display_name) into my_name from public.mentors where id = me;
  my_name := coalesce(my_name, '');

  for it in select value from jsonb_array_elements(p_items) loop
    out_client_id := it ->> 'client_id';
    out_referee_id := null;
    out_updated_at := null;
    out_error := null;
    -- Each item in its own block: a refused item rolls back alone.
    begin
      rid := public.ensure_referee(it ->> 'referee_name');
      -- The account's name when it has one. The phone's name is only a
      -- fallback for an account that has not been given a name yet.
      who := case when my_name <> '' then my_name else left(btrim(coalesce(it ->> 'mentor_name', '')), 80) end;

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

      -- The same evaluation imported from the form's responses gives way to
      -- this copy, which has the notes: same referee, date and position, the
      -- same kickoff when both have one, and credited on the form to this
      -- account's own name. Only an account with a name replaces anything.
      if public.name_key(my_name) <> '' then
        delete from public.evaluations f
        where f.source = 'form' and f.referee_id = rid
          and f.eval_date = nullif(it ->> 'eval_date', '')::date
          and f.position = it ->> 'position'
          and public.name_key(f.mentor_name) = public.name_key(my_name)
          and (f.kickoff is null or nullif(it ->> 'kickoff', '') is null
               or f.kickoff = nullif(it ->> 'kickoff', '')::time);
      end if;
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

-- ------------------------------------------------------------
-- 1c, 2, 3. import_form_evaluations
-- ------------------------------------------------------------
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
      cid := public.form_client_id(source_key, row_no);
      rid := public.find_referee(nm);

      -- Already uploaded from the app by the mentor named on the form. The
      -- name is the evaluation's account's name, which its owner cannot set
      -- to someone else's; an evaluation whose account was removed keeps
      -- the name it was saved with.
      if d is not null and rid is not null and exists (
          select 1 from public.evaluations a
          left join public.mentors m on m.id = a.mentor_id
          where a.source = 'app' and a.referee_id = rid and a.eval_date = d and a.position = pos
            and public.name_key(case when a.mentor_id is null then a.mentor_name else m.display_name end)
                = public.name_key(mentor)
            and public.name_key(mentor) <> ''
            and (a.kickoff is null or k is null or a.kickoff = k)) then
        out_status := 'in_app';
        if p_apply then
          delete from public.evaluations where source = 'form' and client_id = cid;
        end if;
      else
        select * into cur from public.evaluations where source = 'form' and client_id = cid;
        have := found;
        if not have then
          -- Imported before rows were keyed by sheet row: adopt it.
          select * into cur from public.evaluations
          where source = 'form' and form_source_key is null
            and client_id = public.form_client_id(mentor, d, k, nm, pos);
          have := found;
          if have and p_apply then
            update public.evaluations set client_id = cid, form_source_key = source_key, form_row = row_no
            where id = cur.id;
          end if;
        end if;

        -- A row that now holds a different referee in a different game than
        -- the response imported from it means rows were deleted or sorted
        -- in the sheet. Updating would overwrite another evaluation.
        if have and public.name_key(cur.referee_name) <> public.name_key(nm)
           and (cur.eval_date is distinct from d or cur.kickoff is distinct from k or cur.position <> pos
                or public.name_key(cur.mentor_name) <> public.name_key(mentor)) then
          raise exception 'Row % no longer holds the response imported from it (that was % by %). Rows in the responses sheet may have been deleted or sorted: put them back in their original order, then import again.',
            row_no, cur.referee_name, cur.mentor_name using errcode = '22023';
        end if;

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

-- ------------------------------------------------------------
-- 4. Access rules: the role check once per query, not once per row
-- ------------------------------------------------------------
drop policy if exists mentors_select on public.mentors;
create policy mentors_select on public.mentors
  for select to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists referees_select on public.referees;
create policy referees_select on public.referees
  for select to authenticated
  using ((select public.is_approved()));

drop policy if exists evaluations_select on public.evaluations;
create policy evaluations_select on public.evaluations
  for select to authenticated
  using ((select public.is_approved()));

drop policy if exists evaluations_delete on public.evaluations;
create policy evaluations_delete on public.evaluations
  for delete to authenticated
  using (
    ((select public.is_approved()) and mentor_id = (select auth.uid()))
    or (select public.is_admin()));

drop policy if exists evaluation_deletions_select on public.evaluation_deletions;
create policy evaluation_deletions_select on public.evaluation_deletions
  for select to authenticated
  using ((select public.is_approved()));

-- ------------------------------------------------------------
-- 5. set_mentor_role: the last-admin check under a lock
-- ------------------------------------------------------------
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
  -- Lock the admin rows, so two admins demoting each other at once take
  -- turns and the second one sees the first one's change.
  perform 1 from public.mentors where role = 'admin' for update;
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

-- ------------------------------------------------------------
-- 6. mentors.email follows the sign-in email
-- ------------------------------------------------------------
create or replace function public.handle_user_email_change()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.mentors set email = coalesce(new.email, '') where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

-- ------------------------------------------------------------
-- 7. keep_alive: a real query for the keep-awake job, touching no data
-- ------------------------------------------------------------
create or replace function public.keep_alive()
returns boolean
language sql stable
set search_path = ''
as $$
  select true
$$;

-- ------------------------------------------------------------
-- GRANTS: new functions are executable by PUBLIC until revoked by name.
-- ------------------------------------------------------------
revoke execute on function public.keep_alive() from public, authenticated;
grant execute on function public.keep_alive() to anon;

revoke execute on function
  public.check_mentor_name(),
  public.handle_user_email_change(),
  public.save_evaluations(jsonb),
  public.import_form_evaluations(jsonb, boolean),
  public.set_mentor_role(uuid, text)
  from public, anon, authenticated;
grant execute on function
  public.save_evaluations(jsonb),
  public.import_form_evaluations(jsonb, boolean),
  public.set_mentor_role(uuid, text)
  to authenticated;
