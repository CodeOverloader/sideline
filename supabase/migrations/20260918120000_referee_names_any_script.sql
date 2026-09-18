-- ============================================================
-- Sideline: referee names in any script, and one bad evaluation
-- can no longer block the rest of an upload
-- ------------------------------------------------------------
-- Applied after 20260916120000_sideline_accounts.sql. Safe to run more
-- than once.
--
-- 1. name_key() kept only a-z and 0-9, so a name written entirely in
--    another script ("张伟", "Иван Петров", "Γιώργος") had an empty key,
--    and one written partly in one ("Олег Petrov") kept only its Latin
--    part. An empty key made save_evaluations() fail, which failed the
--    whole batch: every evaluation queued on that phone stopped
--    uploading for good. A partial key put different people on one
--    profile ("Олег Petrov" and "Иван Petrov" were both "petrov").
--    Letters and digits of every script now count. Names that were
--    already all Latin get exactly the key they had before.
--
-- 2. save_evaluations() now saves each evaluation on its own. One that
--    the database refuses comes back with out_error set, and the others
--    are saved. Only "not approved" still refuses the whole call.
-- ============================================================

-- "Boor, Gavin" -> "gavin boor";  "José  Núñez-Ruiz" -> "jose nunez ruiz";
-- "ΓΙΏΡΓΟΣ" and "Γιώργος" -> "γιωργοσ".
-- index.html has a JavaScript twin, nameKey(); keep the two in step.
--   NFKC first, so full-width letters, ligatures and decomposed accents
--   reach unaccent in the form its rules expect.
--   Final sigma is folded into sigma, because lower() maps a capital
--   sigma to σ wherever it stands while typed names end in ς.
--   What counts as part of a name: a-z, 0-9, and every code point from
--   U+00C0 up, minus the blocks that hold only punctuation, symbols,
--   spaces and emoji. Everything else separates words.
create or replace function public.name_key(p_name text)
returns text
language sql stable
set search_path = ''
as $$
  select btrim(regexp_replace(
    translate(lower(extensions.unaccent('extensions.unaccent'::regdictionary,
      normalize(
        case when p_name ~ '^[^,]+,[^,]+$'
             then btrim(split_part(p_name, ',', 2)) || ' ' || btrim(split_part(p_name, ',', 1))
             else coalesce(p_name, '')
        end, NFKC))), 'ς', 'σ'),
    '[^a-z0-9\u00c0-\u1fff\u2c00-\u2dff\u2e80-\u2fff\u3040-\ud7ff\uf900-\ufdff\ufe70-\ufefe\uff10-\uff19\uff21-\uff3a\uff41-\uff5a\uff66-\uffef\U00010000-\U0001efff\U00020000-\U0010ffff]+',
    ' ', 'g'))
$$;

-- Referees saved under the old key get the new one, so their next
-- evaluation lands on the same profile instead of starting a second.
-- For all-Latin names the key does not change and nothing happens.
-- A row is left alone if its new key is already taken; an admin can
-- merge the two from the app.
with k as (
  select distinct on (new_key) id, new_key
  from (select id, created_at, public.name_key(display_name) as new_key, name_key as old_key
        from public.referees) r
  where new_key <> '' and new_key <> old_key
  order by new_key, created_at
)
update public.referees r
set name_key = k.new_key
from k
where r.id = k.id
  and not exists (select 1 from public.referees x where x.name_key = k.new_key);

-- The return type gains out_error, which CREATE OR REPLACE cannot do.
drop function if exists public.save_evaluations(jsonb);

-- Upserts a batch of the caller's evaluations. Each item is an object
-- whose keys match the evaluations columns (client_id, referee_name,
-- mentor_name, eval_date, field, pitch, kickoff, division, position,
-- the six ratings, move_up, comments, notes, saved_at). mentor_id is
-- always the caller; anything else sent for it is ignored.
-- Returns one row per item. out_error is null when it was saved, and
-- otherwise says why not; that item was skipped and the rest were saved.
create function public.save_evaluations(p_items jsonb)
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

-- PostgreSQL grants EXECUTE on every new function to PUBLIC, and a
-- per-schema ALTER DEFAULT PRIVILEGES cannot take that away, so each new
-- function has to be closed off by name.
revoke execute on function public.name_key(text), public.save_evaluations(jsonb)
  from public, anon, authenticated;
grant execute on function public.save_evaluations(jsonb) to authenticated;
