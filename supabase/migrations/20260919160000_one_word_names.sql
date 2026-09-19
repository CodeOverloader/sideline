-- ============================================================
-- Sideline: a merged one-word name stops capturing future saves
-- ------------------------------------------------------------
-- Merging exists so a misspelling keeps finding the right person: fold "Jon
-- Smyth" into "Jon Smith" and every later save under the wrong spelling lands
-- on the right referee. That works because the losing row keeps its name_key
-- and points at the survivor.
--
-- It is wrong when the losing name is a single word. "Jordan" is not a
-- misspelling of "Jordan Ellis" - it is an incomplete name that other children
-- share. After folding "Jordan" into "Jordan Ellis", the next referee the
-- schedule lists only as "Jordan" was silently filed under Jordan Ellis:
-- another child's ratings, move-up answer and comments landed on his profile,
-- weeks later, with nothing on screen to say so.
--
-- So: merging still moves the evaluations that are already there, because the
-- admin doing it knows whose they are. What it no longer does is leave that
-- one-word spelling wired to the survivor. A later "Jordan" starts a new
-- referee, and an admin who knows it is the same child can merge again.
--
-- "One word" deliberately means one word IN A SCRIPT THAT SEPARATES NAMES WITH
-- SPACES. A Chinese, Japanese or Korean name is written without one and is
-- complete as it stands, so it is left alone.
--
-- This is a forward migration; historical migrations are not rerun manually.
-- ============================================================

-- Is this name a single word, and therefore not enough to tell two people
-- apart? Works off name_key, so punctuation, case, accents and "Last, First"
-- are already dealt with.
create or replace function public.name_is_one_word(p_name text)
returns boolean
language sql stable
set search_path = ''
as $$
  select k <> ''
     and position(' ' in k) = 0
     -- Han, Hiragana, Katakana, Hangul: complete names, written unspaced.
     and k !~ '[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]'
  from (select public.name_key(p_name) as k) t
$$;

-- A name_key that name_key() can never produce - it emits no colons - so a
-- retired row can never be found by name again. The display name is left
-- exactly as it was: this hides the row from lookups, it does not erase it.
create or replace function public.retired_name_key(p_referee uuid)
returns text
language sql immutable
set search_path = ''
as $$
  select 'merged:' || p_referee::text
$$;

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

  -- The records move; the spelling does not stay wired to the survivor when it
  -- is only a first name. Anything already merged into p_from is retired on the
  -- same rule, since this merge has just moved it too.
  update public.referees
  set name_key = public.retired_name_key(id)
  where merged_into = p_into
    and public.name_is_one_word(display_name)
    and name_key <> public.retired_name_key(id);
end;
$$;

-- ------------------------------------------------------------
-- The one-word spellings already merged
-- ------------------------------------------------------------
-- Every merge made before this is still wired up, so a bare first name folded
-- into someone last month is still catching other people's evaluations today.
-- Retire those keys too. Evaluations are untouched: they were moved to the
-- surviving referee when the merge ran, and they stay there.
update public.referees
set name_key = public.retired_name_key(id)
where merged_into is not null
  and public.name_is_one_word(display_name)
  and name_key <> public.retired_name_key(id);

revoke execute on function
  public.name_is_one_word(text),
  public.retired_name_key(uuid)
  from public, anon, authenticated;
