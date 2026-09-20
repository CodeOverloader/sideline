-- ============================================================
-- Sideline access-rule tests
-- ------------------------------------------------------------
-- Run in the Supabase SQL editor AFTER every migration in
-- supabase/migrations has been applied. Not a migration itself: it
-- lives outside that folder so the GitHub integration never runs it.
--
-- Everything runs inside one transaction that is rolled back at the
-- end, so the fake accounts and rows never persist. The test referee
-- is called "Zed Testref" so no real referee's records are touched.
--
-- Pass: the last result is the row "ALL SIDELINE ACCESS TESTS PASSED".
-- Fail: the script stops with an error beginning "FAIL:".
-- ============================================================

begin;

-- ---------- helpers (temporary; vanish with the session) ----------

-- Become someone. Always call `reset role;` first: a non-superuser role
-- is not allowed to switch straight to another role.
create function pg_temp.act_as(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', p_role)::text, true);
  perform set_config('role', p_role, true);
end $$;

-- Runs a statement and fails the test unless it is refused.
create function pg_temp.expect_error(p_sql text, p_code text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_code then return; end if;
    raise exception 'FAIL: % raised % (%), expected %', p_label, sqlstate, sqlerrm, p_code;
  end;
  raise exception 'FAIL: % was allowed', p_label;
end $$;

-- One evaluation payload, as the app sends it.
create function pg_temp.item(p_client text, p_referee text, p_comments text default 'ok')
returns jsonb language sql as $$
  select jsonb_build_object(
    'client_id', p_client, 'referee_name', p_referee, 'mentor_name', 'Zz Test Mentor',
    'eval_date', '2026-09-12', 'field', 'Field 4', 'pitch', '', 'kickoff', '09:00',
    'division', '5th', 'position', 'CR',
    'appearance', 3, 'workrate', 2, 'commands', 3, 'teamwork', 4, 'fouls', 2, 'offsides', 1,
    'move_up', 'No', 'comments', p_comments,
    'notes', '[{"cat":"offsides","pol":-1,"text":"Flagged late","at":0}]'::jsonb,
    'saved_at', '2026-09-12T15:00:00Z')
$$;

-- ---------- fixtures ----------

insert into auth.users (id, email) values
  ('5d1e0000-0000-4000-8000-00000000000a', 'admin@sideline-test.invalid'),
  ('5d1e0000-0000-4000-8000-00000000000b', 'mentor1@sideline-test.invalid'),
  ('5d1e0000-0000-4000-8000-00000000000c', 'mentor2@sideline-test.invalid'),
  ('5d1e0000-0000-4000-8000-00000000000d', 'pending@sideline-test.invalid');

do $$ begin
  assert (select count(*) from public.mentors where email like '%@sideline-test.invalid') = 4,
    'FAIL: signing up did not create mentors rows';
  assert (select bool_and(role = 'pending') from public.mentors where email like '%@sideline-test.invalid'),
    'FAIL: new accounts must start as pending';
end $$;

-- Real admins are demoted inside this transaction only, so the
-- "last admin" check below has exactly one admin to protect.
update public.mentors set role = 'mentor' where role = 'admin';
update public.mentors set role = 'admin'  where id = '5d1e0000-0000-4000-8000-00000000000a';
update public.mentors set role = 'mentor' where id in ('5d1e0000-0000-4000-8000-00000000000b',
                                                       '5d1e0000-0000-4000-8000-00000000000c');
-- The admin's account name is the name they type on the form.
update public.mentors set display_name = 'Zz Test Mentor' where id = '5d1e0000-0000-4000-8000-00000000000a';
update public.mentors set display_name = 'Zz Mentor One'  where id = '5d1e0000-0000-4000-8000-00000000000b';
update public.mentors set display_name = 'Zz Mentor Two'  where id = '5d1e0000-0000-4000-8000-00000000000c';

-- ---------- name keys (as the owner: clients cannot call name_key) ----------

do $$ begin
  -- Names in any script get a key, and different people stay different.
  assert public.name_key('张伟') = '张伟', 'FAIL: a Chinese name has no key';
  assert public.name_key('Иван Петров') = public.name_key('  ИВАН   петров '),
    'FAIL: a Cyrillic name does not match itself in other capitals';
  assert public.name_key('Олег Zedtest') <> public.name_key('Иван Zedtest'),
    'FAIL: two referees who share a Latin surname got the same key';
  assert public.name_key('ΓΙΏΡΓΟΣ') = public.name_key('Γιώργος'),
    'FAIL: a Greek name does not match itself in capitals';
  -- All-Latin names keep the key they had before names in other scripts counted.
  assert public.name_key('Zoë O’Brien-Łukasz') = 'zoe o brien lukasz', 'FAIL: a Latin name changed key';
  assert public.name_key('Testref, Zed') = 'zed testref', 'FAIL: "Last, First" no longer flips';
  assert public.name_key('Ｇａｖｉｎ') = 'gavin', 'FAIL: full-width letters are not folded';
  assert public.name_key(' — ? ') = '', 'FAIL: punctuation alone should have no key';
end $$;

-- ---------- mentor 1: save, re-save ----------

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');

do $$
declare n int;
begin
  select count(*) into n from public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-1', 'Testref, Zed', 'first'),
    pg_temp.item('zz-test-3', 'Z. Testref'),
    pg_temp.item('zz-test-5', 'Zed Deleteme')));
  assert n = 3, 'FAIL: save_evaluations should return one row per item';

  perform public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-1', 'Testref, Zed', 'updated')));
  assert (select count(*) from public.evaluations
          where client_id = 'zz-test-1') = 1, 'FAIL: re-saving created a duplicate';
  assert (select comments from public.evaluations
          where client_id = 'zz-test-1') = 'updated', 'FAIL: re-saving did not update the row';
  assert (select mentor_id from public.evaluations where client_id = 'zz-test-1')
         = '5d1e0000-0000-4000-8000-00000000000b', 'FAIL: mentor_id not stamped';
  -- The payload says "Zz Test Mentor"; the account is "Zz Mentor One".
  assert (select mentor_name from public.evaluations where client_id = 'zz-test-1') = 'Zz Mentor One',
    'FAIL: an upload kept a mentor name other than the account''s';

  assert (select display_name from public.referees r join public.evaluations e on e.referee_id = r.id
          where e.client_id = 'zz-test-1') = 'Testref, Zed', 'FAIL: referee not created';
  assert (select count(distinct referee_id) from public.evaluations
          where client_id in ('zz-test-1', 'zz-test-3')) = 2, 'FAIL: "Z. Testref" should be a separate referee';

  -- own delete leaves a tombstone
  delete from public.evaluations where client_id = 'zz-test-5';
  assert not exists (select 1 from public.evaluations where client_id = 'zz-test-5'),
    'FAIL: mentor could not delete their own evaluation';
  assert (select count(*) from public.evaluation_deletions where deleted_at >= now()) >= 1,
    'FAIL: deleting did not leave a tombstone';

  perform pg_temp.expect_error($q$ select public.save_evaluations('{"not":"an array"}') $q$,
    '22023', 'a non-array payload');

  -- One refused item is reported and skipped; the rest of the batch saves.
  assert (select out_error from public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-x', '  ')))) is not null,
    'FAIL: a blank referee name was not reported';
  assert not exists (select 1 from public.evaluations where client_id = 'zz-test-x'),
    'FAIL: a blank referee name was saved';
  select count(*) filter (where out_error is null) into n
  from public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-x2', '—'), pg_temp.item('zz-test-8', 'Zed Batchmate')));
  assert n = 1 and exists (select 1 from public.evaluations where client_id = 'zz-test-8'),
    'FAIL: one refused evaluation stopped the rest of the batch';
  delete from public.evaluations where client_id = 'zz-test-8';
end $$;

-- ---------- mentor 2: shared reads, no writes to others ----------

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000c');

do $$
declare gavin uuid;
begin
  assert (select count(*) from public.evaluations where client_id = 'zz-test-1') = 1,
    'FAIL: an approved mentor cannot read shared evaluations';

  select referee_id into gavin from public.evaluations where client_id = 'zz-test-1';
  perform public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-2', '  zed   TESTREF ')));
  assert (select referee_id from public.evaluations where client_id = 'zz-test-2') = gavin,
    'FAIL: name variants did not match the same referee';

  -- a forged mentor_id in the payload is ignored
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-1', 'Testref, Zed', 'forged') || '{"eval_date":"2026-09-13","mentor_id":"5d1e0000-0000-4000-8000-00000000000b"}'));
  assert (select comments from public.evaluations
          where client_id = 'zz-test-1' and mentor_id = '5d1e0000-0000-4000-8000-00000000000b') = 'updated',
    'FAIL: mentor 2 overwrote mentor 1''s evaluation';
  assert (select count(*) from public.evaluations where client_id = 'zz-test-1') = 2,
    'FAIL: forged save should have created mentor 2''s own row';

  perform pg_temp.expect_error($q$ update public.evaluations set comments = 'x' where client_id = 'zz-test-1' $q$,
    '42501', 'a direct update of evaluations');
  perform pg_temp.expect_error($q$ insert into public.evaluations (client_id, referee_id, referee_name, position)
    select 'zz-test-9', id, 'x', 'CR' from public.referees limit 1 $q$,
    '42501', 'a direct insert into evaluations');
  perform pg_temp.expect_error($q$ insert into public.referees (display_name, name_key) values ('x', 'zz x') $q$,
    '42501', 'a direct insert into referees');

  delete from public.evaluations
   where client_id = 'zz-test-1' and mentor_id = '5d1e0000-0000-4000-8000-00000000000b';
  assert exists (select 1 from public.evaluations
                 where client_id = 'zz-test-1' and mentor_id = '5d1e0000-0000-4000-8000-00000000000b'),
    'FAIL: mentor 2 deleted mentor 1''s evaluation';

  assert (select count(*) from public.mentors) = 1, 'FAIL: a mentor can list other accounts';
  update public.mentors set display_name = 'Zz Renamed' where id = '5d1e0000-0000-4000-8000-00000000000c';
  assert (select display_name from public.mentors) = 'Zz Renamed', 'FAIL: a mentor cannot rename themselves';
  perform pg_temp.expect_error($q$ update public.mentors set display_name = ' zz  MENTOR one'
    where id = '5d1e0000-0000-4000-8000-00000000000c' $q$,
    '23505', 'a mentor taking another account''s name');
  update public.mentors set display_name = 'Zz Mentor Two' where id = '5d1e0000-0000-4000-8000-00000000000c';
  perform pg_temp.expect_error($q$ update public.mentors set role = 'admin' $q$,
    '42501', 'a mentor changing their own role');

  perform pg_temp.expect_error($q$ select public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000c', 'admin') $q$,
    '42501', 'set_mentor_role by a mentor');
  perform pg_temp.expect_error($q$ select public.merge_referees(gen_random_uuid(), gen_random_uuid()) $q$,
    '42501', 'merge_referees by a mentor');
  perform pg_temp.expect_error($q$ select public.delete_referee_records(gen_random_uuid()) $q$,
    '42501', 'delete_referee_records by a mentor');
  perform pg_temp.expect_error($q$ select public.remove_mentor('5d1e0000-0000-4000-8000-00000000000d') $q$,
    '42501', 'remove_mentor by a mentor');
  perform pg_temp.expect_error($q$ select public.ensure_referee('Someone') $q$,
    '42501', 'calling ensure_referee directly');
end $$;

-- ---------- pending: nothing at all ----------

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000d');

do $$ begin
  assert (select count(*) from public.evaluations) = 0, 'FAIL: a pending account can read evaluations';
  assert (select count(*) from public.referees) = 0, 'FAIL: a pending account can read referees';
  assert (select count(*) from public.evaluation_deletions) = 0, 'FAIL: a pending account can read tombstones';
  assert (select count(*) from public.mentors) = 1, 'FAIL: a pending account should see only its own row';
  perform pg_temp.expect_error($q$ select public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-p', 'Testref, Zed'))) $q$,
    '42501', 'a pending account saving');
end $$;

-- ---------- anonymous: no table access ----------

reset role;
select pg_temp.act_as(null, 'anon');

do $$ begin
  perform pg_temp.expect_error($q$ select count(*) from public.evaluations $q$, '42501', 'anon reading evaluations');
  perform pg_temp.expect_error($q$ select count(*) from public.mentors $q$, '42501', 'anon reading mentors');
  perform pg_temp.expect_error($q$ select public.save_evaluations('[]') $q$, '42501', 'anon calling save_evaluations');
  -- The keep-awake job's call, the one thing anonymous callers may run.
  assert public.keep_alive(), 'FAIL: anon cannot call keep_alive';
end $$;

-- ---------- admin: approve, merge, delete, guards ----------

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');

do $$
declare gavin uuid; zinit uuid; n int;
begin
  assert (select count(*) from public.mentors where email like '%@sideline-test.invalid') = 4,
    'FAIL: an admin cannot list accounts';

  perform public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000d', 'mentor');
  assert (select approved_by from public.mentors where id = '5d1e0000-0000-4000-8000-00000000000d')
         = '5d1e0000-0000-4000-8000-00000000000a', 'FAIL: approval not recorded';
  perform pg_temp.expect_error($q$ select public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000d', 'owner') $q$,
    '22023', 'an unknown role');
  perform pg_temp.expect_error($q$ select public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000a', 'mentor') $q$,
    '42501', 'demoting the last admin');
  perform pg_temp.expect_error($q$ select public.remove_mentor('5d1e0000-0000-4000-8000-00000000000a') $q$,
    '42501', 'an admin removing themselves');

  select referee_id into gavin from public.evaluations where client_id = 'zz-test-2';
  select referee_id into zinit from public.evaluations where client_id = 'zz-test-3';
  perform public.merge_referees(zinit, gavin);
  assert (select referee_id from public.evaluations where client_id = 'zz-test-3') = gavin,
    'FAIL: merge did not move evaluations';
  perform pg_temp.expect_error(format($q$ select public.merge_referees(%L, %L) $q$, zinit, gavin),
    '22023', 'merging an already-merged referee');
  perform pg_temp.expect_error(format($q$ select public.merge_referees(%L, %L) $q$, gavin, gavin),
    '22023', 'merging a referee into itself');

  -- a later save under the merged spelling lands on the survivor
  perform public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-6', 'Z Testref')));
  assert (select referee_id from public.evaluations where client_id = 'zz-test-6') = gavin,
    'FAIL: saving under a merged name did not follow the merge';

  -- admin may delete anyone's single evaluation
  delete from public.evaluations where client_id = 'zz-test-2';
  assert not exists (select 1 from public.evaluations where client_id = 'zz-test-2'),
    'FAIL: an admin could not delete another mentor''s evaluation';

  select public.delete_referee_records(gavin) into n;
  assert n = 4, format('FAIL: delete_referee_records removed %s evaluations, expected 4', n);
  assert not exists (select 1 from public.referees where id in (gavin, zinit)),
    'FAIL: referee rows (including merged spellings) were not deleted';

  perform public.remove_mentor('5d1e0000-0000-4000-8000-00000000000d');
  assert not exists (select 1 from public.mentors where id = '5d1e0000-0000-4000-8000-00000000000d'),
    'FAIL: remove_mentor did not delete the account';
end $$;

-- ---------- admin: importing the form's responses ----------

-- Mentor 1 uploads a game the admin also sent on the form, with the admin's
-- name in the payload. It is still mentor 1's evaluation, not the admin's.
reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');
select public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-12', 'Zed Spoofed')));

-- A form row imported before rows were keyed by sheet row (inserted as the owner).
reset role;
insert into public.referees (display_name, name_key) values ('Zed Legacy', public.name_key('Zed Legacy'));
insert into public.evaluations (mentor_id, client_id, source, referee_id, referee_name, mentor_name,
                                eval_date, kickoff, position, saved_at)
select null, public.form_client_id('Zz Test Mentor', '2026-09-12'::date, '08:00'::time, 'Zed Legacy', 'CR'), 'form',
       id, 'Zed Legacy', 'Zz Test Mentor', '2026-09-12', '08:00', 'CR', '2026-09-12T14:00:00Z'
from public.referees where name_key = public.name_key('Zed Legacy');

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');

do $$
declare
  resp jsonb := jsonb_build_array(
    -- row 2: also uploaded from the app below, typed a little differently on the form
    jsonb_build_object('row', 2, 'source_key', 'test-sheet|123', 'mentor_name', 'zz test mentor', 'eval_date', '2026-09-12', 'kickoff', '09:00',
      'referee_name', 'Twin, Zed', 'position', 'CR', 'appearance', '3', 'move_up', 'No'),
    -- row 3: only on the form
    jsonb_build_object('row', 3, 'source_key', 'test-sheet|123', 'mentor_name', 'Zz Test Mentor', 'eval_date', '2026-09-12', 'kickoff', '10:15',
      'referee_name', 'Zed Formonly', 'position', 'AR', 'appearance', '2', 'workrate', '4', 'move_up', 'Yes',
      'comments', 'From the form', 'field', 'Field 4', 'division', '5th', 'saved_at', '2026-09-12T16:00:00Z'),
    -- row 4: cannot be imported
    jsonb_build_object('row', 4, 'source_key', 'test-sheet|123', 'mentor_name', 'Zz Test Mentor', 'eval_date', '2026-09-12',
      'referee_name', 'Zed Badrating', 'position', 'CR', 'fouls', '7'),
    -- row 5: the game mentor 1 uploaded under the admin's name - not the admin's upload
    jsonb_build_object('row', 5, 'source_key', 'test-sheet|123', 'mentor_name', 'Zz Test Mentor', 'eval_date', '2026-09-12', 'kickoff', '09:00',
      'referee_name', 'Zed Spoofed', 'position', 'CR', 'comments', 'The admin''s own', 'saved_at', '2026-09-12T17:00:00Z'),
    -- row 6: imported before rows were keyed by sheet row
    jsonb_build_object('row', 6, 'source_key', 'test-sheet|123', 'mentor_name', 'Zz Test Mentor', 'eval_date', '2026-09-12', 'kickoff', '08:00',
      'referee_name', 'Zed Legacy', 'position', 'CR', 'saved_at', '2026-09-12T14:00:00Z'));
  sorted jsonb;
  shifted jsonb;
  st text[];
begin
  perform public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-10', 'Zed Twin')));

  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp);
  assert st = array['in_app', 'new', 'error', 'new', 'changed'], format('FAIL: preview statuses were %s', st);
  assert (select count(*) from public.evaluations where source = 'form') = 1, 'FAIL: a preview saved something';
  assert (select form_source_key is null from public.evaluations where source = 'form'),
    'FAIL: a preview adopted the old imported row';
  assert not exists (select 1 from public.referees where display_name = 'Zed Formonly'),
    'FAIL: a preview created a referee';

  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st = array['in_app', 'new', 'error', 'new', 'changed'], format('FAIL: import statuses were %s', st);
  assert (select count(*) from public.evaluations where source = 'form') = 3, 'FAIL: import did not leave three form rows';
  assert (select form_row from public.evaluations where source = 'form' and referee_name = 'Zed Legacy') = 6,
    'FAIL: an old imported row was not adopted by its sheet row';
  assert (select mentor_id is null and comments = 'From the form' and saved_at = '2026-09-12T16:00:00Z'
          from public.evaluations where source = 'form' and form_row = 3), 'FAIL: the imported row is wrong';

  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st[2] = 'same' and st[4] = 'same' and st[5] = 'same',
    format('FAIL: importing the same sheet again changed something: %s', st);
  assert (select count(*) from public.evaluations where source = 'form') = 3, 'FAIL: re-import duplicated a row';

  -- Rows 3 and 5 trade places, as if the sheet had been sorted: both are
  -- refused, and neither evaluation is overwritten.
  sorted := jsonb_set(jsonb_set(resp, '{1,row}', '5'), '{3,row}', '3');
  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(sorted, true);
  assert st[2] = 'error' and st[4] = 'error', format('FAIL: a sorted sheet was not refused: %s', st);
  assert (select referee_name from public.evaluations where source = 'form' and form_row = 3) = 'Zed Formonly'
     and (select referee_name from public.evaluations where source = 'form' and form_row = 5) = 'Zed Spoofed',
    'FAIL: a sorted sheet overwrote an evaluation';

  -- Sheet row 2 is deleted, so every later response moves up a row. Each
  -- moved row is refused (row 3 for its bad rating), and nothing changes.
  shifted := jsonb_build_array(resp -> 1 || '{"row": 2}', resp -> 2 || '{"row": 3}',
                               resp -> 3 || '{"row": 4}', resp -> 4 || '{"row": 5}');
  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(shifted, true);
  assert st = array['error', 'error', 'error', 'error'], format('FAIL: a sheet with a deleted row was not refused: %s', st);
  assert (select count(*) from public.evaluations where source = 'form') = 3
     and (select referee_name from public.evaluations where source = 'form' and form_row = 3) = 'Zed Formonly'
     and (select referee_name from public.evaluations where source = 'form' and form_row = 5) = 'Zed Spoofed'
     and (select referee_name from public.evaluations where source = 'form' and form_row = 6) = 'Zed Legacy',
    'FAIL: a sheet with a deleted row overwrote or removed an evaluation';

  resp := jsonb_set(resp, '{1,comments}', '"Edited on the form"');
  resp := jsonb_set(resp, '{1,eval_date}', '"2026-09-13"');
  resp := jsonb_set(resp, '{1,kickoff}', '"11:15"');
  -- Google Forms moves the response time forward when a response is edited.
  resp := jsonb_set(resp, '{1,saved_at}', '"2026-09-13T08:00:00Z"');
  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st[2] = 'changed', 'FAIL: an edited response was not seen as changed';
  assert (select comments from public.evaluations where source = 'form' and form_row = 3) = 'Edited on the form',
    'FAIL: an edited response did not update in place';
  assert (select eval_date from public.evaluations where source = 'form' and form_row = 3) = '2026-09-13'::date,
    'FAIL: an edited response date did not update in place';
  assert (select kickoff from public.evaluations where source = 'form' and form_row = 3) = '11:15'::time,
    'FAIL: an edited response kickoff did not update in place';
  assert (select saved_at from public.evaluations where source = 'form' and form_row = 3) = '2026-09-13T08:00:00Z',
    'FAIL: an edited response time did not update in place';
  assert (select form_owner_mentor_id from public.evaluations where source = 'form' and form_row = 3)
         = '5d1e0000-0000-4000-8000-00000000000a',
    'FAIL: a form row did not keep its imported owner';

  -- A response older than the one imported from its row is another response.
  select array_agg(out_status order by out_row) into st
  from public.import_form_evaluations(jsonb_set(resp, '{1,saved_at}', '"2026-09-12T12:00:00Z"'), true);
  assert st[2] = 'error', format('FAIL: an older response on an imported row was not refused: %s', st);
  assert (select comments from public.evaluations where source = 'form' and form_row = 3) = 'Edited on the form',
    'FAIL: an older response overwrote an evaluation';
end $$;

-- Historical ownership survives account deletion and same-name reuse.
reset role;
insert into auth.users (id, email) values
  ('5d1e0000-0000-4000-8000-00000000000e', 'oldname@sideline-test.invalid'),
  ('5d1e0000-0000-4000-8000-00000000000f', 'newname@sideline-test.invalid');
update public.mentors set role = 'mentor', approved_at = now(),
  display_name = 'Zz Reused Name' where id = '5d1e0000-0000-4000-8000-00000000000e';
update public.mentors set role = 'pending', display_name = 'Zz Someone Else'
  where id = '5d1e0000-0000-4000-8000-00000000000f';

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
select public.import_form_evaluations(jsonb_build_array(
  jsonb_build_object('row', 7, 'source_key', 'test-sheet|123', 'mentor_name', 'Zz Reused Name',
    'eval_date', '2026-09-12', 'kickoff', '07:00', 'referee_name', 'Zed Reuse', 'position', 'CR',
    'appearance', '3', 'saved_at', '2026-09-12T13:00:00Z')), true);
select public.remove_mentor('5d1e0000-0000-4000-8000-00000000000e');
select public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000f', 'mentor');

-- Mentor 1 uploads the admin's form games claiming the admin's name: the
-- imported evaluations stay.
reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');
do $$ begin
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-13', 'Zed Formonly') || '{"position": "AR", "eval_date": "2026-09-13", "kickoff": "11:15"}',
    pg_temp.item('zz-test-12', 'Zed Spoofed', 'again')));
  assert (select count(*) from public.evaluations where source = 'form') = 4,
    'FAIL: a mentor''s upload removed evaluations imported under someone else''s name';
end $$;

-- A new account reusing a historical name cannot replace the old account's row.
reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000f');
do $$ begin
  -- The removed account's name is free again, so this account can take it.
  update public.mentors set display_name = 'Zz Reused Name' where id = '5d1e0000-0000-4000-8000-00000000000f';
  assert (select display_name from public.mentors) = 'Zz Reused Name', 'FAIL: a freed name could not be taken';
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-14', 'Zed Reuse') || '{"eval_date": "2026-09-12", "kickoff": "07:00"}'));
  assert exists (select 1 from public.evaluations where source = 'form' and form_row = 7),
    'FAIL: reusing a historical name replaced another account''s imported row';
end $$;

-- The admin uploads the same evaluation from the app afterwards: the app copy wins.
reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$ begin
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-11', 'Zed Formonly') || '{"position": "AR", "eval_date": "2026-09-13", "kickoff": "11:15"}'));
  assert not exists (select 1 from public.evaluations where source = 'form' and form_row = 3),
    'FAIL: an app upload did not replace the imported copy';
  assert exists (select 1 from public.evaluations where client_id = 'zz-test-11'), 'FAIL: the app copy is missing';
end $$;

-- ---------- a one-word name is not an identity ----------
-- Merging keeps a misspelling wired to the right person, which is the point.
-- A bare first name is not a misspelling of anything, so merging it must move
-- the records that are already there WITHOUT leaving the spelling pointed at
-- the survivor - otherwise the next child the schedule lists only as "Jordan"
-- is silently filed under Jordan Ellis.

-- as the owner: clients cannot call name_is_one_word, as with name_key
reset role;
do $$ begin
  assert public.name_is_one_word('Jordan'), 'FAIL: a bare first name is not one word';
  assert public.name_is_one_word('  jordan  '), 'FAIL: spacing changed the answer';
  assert public.name_is_one_word('Иван'), 'FAIL: a bare Cyrillic first name is not one word';
  assert not public.name_is_one_word('Jordan Ellis'), 'FAIL: a full name counted as one word';
  assert not public.name_is_one_word('Ellis, Jordan'), 'FAIL: "Last, First" counted as one word';
  assert not public.name_is_one_word('Jordan-Ellis'), 'FAIL: a hyphenated name counted as one word';
  assert not public.name_is_one_word(''), 'FAIL: an empty name counted as one word';
  -- Written without spaces and complete as they stand.
  assert not public.name_is_one_word('张伟'), 'FAIL: a Chinese name counted as one word';
  assert not public.name_is_one_word('田中太郎'), 'FAIL: a Japanese name counted as one word';
  assert not public.name_is_one_word('김민수'), 'FAIL: a Korean name counted as one word';
end $$;

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');
select public.save_evaluations(jsonb_build_array(
  pg_temp.item('zz-word-1', 'Zedbare')         || '{"eval_date": "2026-10-03"}',
  pg_temp.item('zz-word-2', 'Zedbare Fullname')|| '{"eval_date": "2026-10-04"}',
  pg_temp.item('zz-word-3', 'Zedmiss Smyth')   || '{"eval_date": "2026-10-05"}',
  pg_temp.item('zz-word-4', 'Zedmiss Smith')   || '{"eval_date": "2026-10-06"}'));

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare bare uuid; whole uuid; miss uuid; right_one uuid;
begin
  select referee_id into bare      from public.evaluations where client_id = 'zz-word-1';
  select referee_id into whole     from public.evaluations where client_id = 'zz-word-2';
  select referee_id into miss      from public.evaluations where client_id = 'zz-word-3';
  select referee_id into right_one from public.evaluations where client_id = 'zz-word-4';

  perform public.merge_referees(bare, whole);
  perform public.merge_referees(miss, right_one);

  -- Both merges move what was already filed.
  assert (select referee_id from public.evaluations where client_id = 'zz-word-1') = whole,
    'FAIL: merging a one-word name did not move its evaluations';
  assert (select referee_id from public.evaluations where client_id = 'zz-word-3') = right_one,
    'FAIL: merging a misspelling did not move its evaluations';

  -- The one-word spelling is retired; the misspelling stays wired up.
  -- (read as the owner - name_key and retired_name_key are not client calls)
  reset role;
  assert (select name_key from public.referees where id = bare) = public.retired_name_key(bare),
    'FAIL: a merged one-word name kept a live key and will catch other people''s evaluations';
  assert (select name_key from public.referees where id = miss) = public.name_key('Zedmiss Smyth'),
    'FAIL: merging a misspelling retired it, so it will stop finding the right person';
  assert (select display_name from public.referees where id = bare) = 'Zedbare',
    'FAIL: retiring a key changed the display name';
end $$;

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');
do $$
declare whole uuid; right_one uuid;
begin
  select referee_id into whole     from public.evaluations where client_id = 'zz-word-2';
  select referee_id into right_one from public.evaluations where client_id = 'zz-word-4';

  -- A different child, listed only by the same first name, weeks later.
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-word-5', 'Zedbare') || '{"eval_date": "2026-11-07"}'));
  assert (select referee_id from public.evaluations where client_id = 'zz-word-5') <> whole,
    'FAIL: a later one-word name was filed under the referee it was merged into';

  -- A later save under the misspelling still reaches the right person.
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-word-6', 'Zedmiss Smyth') || '{"eval_date": "2026-11-08"}'));
  assert (select referee_id from public.evaluations where client_id = 'zz-word-6') = right_one,
    'FAIL: a later save under a merged misspelling stopped following the merge';
end $$;

-- The backfill statement the migration runs, on a spelling merged before it.
reset role;
do $$
declare bare uuid; whole uuid; n int;
begin
  select id into whole from public.referees where name_key = public.name_key('Zedold Fullname');
  if whole is null then
    insert into public.referees (display_name, name_key)
    values ('Zedold Fullname', public.name_key('Zedold Fullname')) returning id into whole;
  end if;
  insert into public.referees (display_name, name_key, merged_into)
  values ('Zedold', public.name_key('Zedold'), whole) returning id into bare;

  update public.referees
  set name_key = public.retired_name_key(id)
  where merged_into is not null
    and public.name_is_one_word(display_name)
    and name_key <> public.retired_name_key(id);
  get diagnostics n = row_count;
  assert n >= 1, 'FAIL: the backfill retired nothing';
  assert (select name_key from public.referees where id = bare) = public.retired_name_key(bare),
    'FAIL: the backfill left a one-word merged name live';
  assert not exists (
    select 1 from public.referees
    where merged_into is not null and public.name_is_one_word(display_name)
      and name_key <> public.retired_name_key(id)),
    'FAIL: a one-word merged name is still catching saves after the backfill';
end $$;

-- ---------- one evaluation per referee per day per mentor ----------
-- The app files a referee's whole day as one evaluation and can only put one
-- of its games in the form's single Time and Position answers, so the import
-- must not ask those to match before deciding a response is already in the
-- app. Referee, date and mentor are what identify it.

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare st text[];
begin
  -- The admin files a day that began at 08:00 as CR.
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-test-day', 'Zed Allday')
      || '{"eval_date": "2026-09-26", "kickoff": "08:00", "position": "CR"}'));

  -- The same evaluation off the form, carrying the SECOND game's time and
  -- position. Same referee, same date, same mentor: already in the app.
  select array_agg(out_status) into st from public.import_form_evaluations(jsonb_build_array(
    jsonb_build_object('row', 20, 'source_key', 'test-sheet|day', 'mentor_name', 'Zz Test Mentor',
      'eval_date', '2026-09-26', 'kickoff', '09:00', 'referee_name', 'Zed Allday', 'position', 'AR',
      'appearance', '3', 'saved_at', '2026-09-26T16:00:00Z')), true);
  assert st = array['in_app'], format('FAIL: a form response for a day already filed imported anyway: %s', st);
  assert not exists (select 1 from public.evaluations where source = 'form' and referee_name = 'Zed Allday'),
    'FAIL: the duplicate form response was written';

  -- What must still import: another mentor, another date, another referee.
  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(jsonb_build_array(
    jsonb_build_object('row', 22, 'source_key', 'test-sheet|day', 'mentor_name', 'Zz Mentor One',
      'eval_date', '2026-09-26', 'kickoff', '09:00', 'referee_name', 'Zed Allday', 'position', 'AR',
      'appearance', '3', 'saved_at', '2026-09-26T18:00:00Z'),
    jsonb_build_object('row', 23, 'source_key', 'test-sheet|day', 'mentor_name', 'Zz Test Mentor',
      'eval_date', '2026-09-27', 'kickoff', '09:00', 'referee_name', 'Zed Allday', 'position', 'CR',
      'appearance', '3', 'saved_at', '2026-09-27T18:00:00Z'),
    jsonb_build_object('row', 24, 'source_key', 'test-sheet|day', 'mentor_name', 'Zz Test Mentor',
      'eval_date', '2026-09-26', 'kickoff', '09:00', 'referee_name', 'Zed Someoneelse', 'position', 'CR',
      'appearance', '3', 'saved_at', '2026-09-26T19:00:00Z')), true);
  assert st = array['new', 'new', 'new'],
    format('FAIL: a different mentor, date or referee was wrongly treated as already in the app: %s', st);
end $$;

-- A second spelling of that referee, merged into the first (as the owner:
-- ensure_referee is not something a client may call).
reset role;
select public.merge_referees(public.ensure_referee('Allday, Zed E'), public.find_referee('Zed Allday'));

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare st text[];
begin
  -- The form spells the referee the way that was merged away. It still has to
  -- match the app evaluation filed under the surviving spelling.
  select array_agg(out_status) into st from public.import_form_evaluations(jsonb_build_array(
    jsonb_build_object('row', 21, 'source_key', 'test-sheet|day', 'mentor_name', 'Zz Test Mentor',
      'eval_date', '2026-09-26', 'kickoff', '10:15', 'referee_name', 'Allday, Zed E', 'position', 'AR',
      'appearance', '3', 'saved_at', '2026-09-26T17:00:00Z')), true);
  assert st = array['in_app'], format('FAIL: a merged spelling did not match the app evaluation: %s', st);
end $$;

-- ---------- pruning the copies imported before that check ----------

reset role;
-- A form row duplicating the admin's app evaluation, as the old check left it,
-- and one that duplicates nothing.
insert into public.evaluations (mentor_id, client_id, source, form_source_key, form_row, referee_id,
                                referee_name, mentor_name, eval_date, kickoff, position, saved_at)
select null, 'form:zz-dupe', 'form', 'test-sheet|old', 2, public.find_referee('Zed Allday'),
       'Zed Allday', 'Zz Test Mentor', '2026-09-26', '09:00', 'AR', '2026-09-26T20:00:00Z';
insert into public.evaluations (mentor_id, client_id, source, form_source_key, form_row, referee_id,
                                referee_name, mentor_name, eval_date, kickoff, position, saved_at)
select null, 'form:zz-keep', 'form', 'test-sheet|old', 3, public.find_referee('Zed Allday'),
       'Zed Allday', 'Zz Mentor Two', '2026-09-26', '09:00', 'AR', '2026-09-26T20:00:00Z';

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare n int; dupe_id uuid;
begin
  -- A dry run reports and changes nothing.
  select count(*) into n from public.prune_duplicate_form_evaluations() where form_client = 'form:zz-dupe';
  assert n = 1, 'FAIL: the prune did not find a duplicate imported copy';
  assert exists (select 1 from public.prune_duplicate_form_evaluations() where form_client = 'form:zz-dupe' and not removed),
    'FAIL: a dry run claimed to have removed something';
  assert exists (select 1 from public.evaluations where client_id = 'form:zz-dupe'),
    'FAIL: a dry run deleted an evaluation';
  assert not exists (select 1 from public.prune_duplicate_form_evaluations() where form_client = 'form:zz-keep'),
    'FAIL: the prune matched a form row that duplicates nothing';

  select id into dupe_id from public.evaluations where client_id = 'form:zz-dupe';
  assert exists (select 1 from public.prune_duplicate_form_evaluations(true) where form_client = 'form:zz-dupe' and removed),
    'FAIL: applying the prune did not remove the duplicate';
  assert not exists (select 1 from public.evaluations where client_id = 'form:zz-dupe'),
    'FAIL: the duplicate imported copy is still there';
  assert exists (select 1 from public.evaluations where client_id = 'zz-test-day'),
    'FAIL: the prune removed the mentor''s own evaluation instead of the imported copy';
  assert exists (select 1 from public.evaluations where client_id = 'form:zz-keep'),
    'FAIL: the prune removed a form row that duplicates nothing';
  assert exists (select 1 from public.evaluation_deletions where evaluation_id = dupe_id),
    'FAIL: a pruned evaluation was not tombstoned, so phones would keep it';
end $$;

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000c');
do $$ begin
  perform pg_temp.expect_error($q$ select public.import_form_evaluations('[]', true) $q$,
    '42501', 'a mentor importing form responses');
  perform pg_temp.expect_error($q$ select public.prune_duplicate_form_evaluations(true) $q$,
    '42501', 'a mentor pruning imported evaluations');
end $$;

-- ---------- completing a first name from the schedule ----------
-- Mentors type only "Jordan" on the form. The schedule says who was on that
-- game; a completion happens only when exactly one referee there has that
-- first name.

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');
do $$ begin
  perform pg_temp.expect_error($q$ select public.save_schedule('[]') $q$, '42501', 'a mentor saving the schedule');
  perform pg_temp.expect_error($q$ select count(*) from public.schedule_slots $q$, '42501', 'a mentor reading the schedule');
  -- Mentor 1 uploads their evaluation of Zedjo Ellis from the app.
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-sched-app', 'Zedjo Ellis') || '{"eval_date": "2026-10-10"}'));
end $$;

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare
  n int; dates int;
  g jsonb := jsonb_build_array(
    -- An earlier version of the day, replaced below.
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 4', 'kickoff', '09:00', 'position', 'CR', 'referee_name', 'Zedold Crew'));
begin
  perform public.save_schedule(g);
  select out_saved, out_dates into n, dates from public.save_schedule(jsonb_build_array(
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 4', 'kickoff', '09:00', 'position', 'CR', 'referee_name', 'Zedjo Ellis'),
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 4', 'kickoff', '09:00', 'position', 'AR', 'referee_name', 'Zedkim Park'),
    -- Two referees on one game with the same first name: no completion.
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 5', 'kickoff', '09:00', 'position', 'CR', 'referee_name', 'Zedam One'),
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 5', 'kickoff', '09:00', 'position', 'AR', 'referee_name', 'Zedam Two'),
    -- Rows that can never match a response are dropped.
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 5', 'kickoff', '', 'referee_name', 'Zedno Time'),
    jsonb_build_object('date', '', 'field', 'Field 5', 'kickoff', '10:00', 'referee_name', 'Zedno Date'),
    jsonb_build_object('date', '2026-10-10', 'field', 'Field 6', 'kickoff', '10:00', 'referee_name', ' — ')));
  assert n = 4 and dates = 1, format('FAIL: save_schedule saved %s rows over %s dates, expected 4 over 1', n, dates);
end $$;

reset role;
do $$ begin
  assert not exists (select 1 from public.schedule_slots where referee_name = 'Zedold Crew'),
    'FAIL: saving a date again did not replace what was saved for it';
end $$;

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare
  resp jsonb := jsonb_build_array(
    -- row 2: mentor 1's form copy of the evaluation they uploaded, first name only
    jsonb_build_object('row', 2, 'source_key', 'test-sheet|sched', 'mentor_name', 'Zz Mentor One', 'eval_date', '2026-10-10',
      'field', 'Field 4', 'kickoff', '09:00', 'referee_name', 'Zedjo', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-10-10T16:00:00Z'),
    -- row 3: only on the form, the field typed another way
    jsonb_build_object('row', 3, 'source_key', 'test-sheet|sched', 'mentor_name', 'Zz Test Mentor', 'eval_date', '2026-10-10',
      'field', 'FIELD  4', 'kickoff', '09:00', 'referee_name', 'zedkim', 'position', 'AR', 'appearance', '3',
      'saved_at', '2026-10-10T16:01:00Z'),
    -- row 4: two Zedams on that game
    jsonb_build_object('row', 4, 'source_key', 'test-sheet|sched', 'mentor_name', 'Zz Test Mentor', 'eval_date', '2026-10-10',
      'field', 'Field 5', 'kickoff', '09:00', 'referee_name', 'Zedam', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-10-10T16:02:00Z'),
    -- row 5: the admin turned the completion off
    jsonb_build_object('row', 5, 'source_key', 'test-sheet|sched', 'mentor_name', 'Zz Mentor Two', 'eval_date', '2026-10-10',
      'field', 'Field 4', 'kickoff', '09:00', 'referee_name', 'Zedkim', 'position', 'AR', 'appearance', '3',
      'saved_at', '2026-10-10T16:03:00Z', 'use_schedule', false),
    -- row 6: right name, wrong kickoff
    jsonb_build_object('row', 6, 'source_key', 'test-sheet|sched', 'mentor_name', 'Zz Mentor Two', 'eval_date', '2026-10-10',
      'field', 'Field 4', 'kickoff', '10:00', 'referee_name', 'Zedjo', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-10-10T16:04:00Z'));
  st text[]; names text[]; sched boolean[];
begin
  select array_agg(out_status order by out_row), array_agg(coalesce(out_referee, '-') order by out_row),
         array_agg(out_from_schedule order by out_row)
  into st, names, sched from public.import_form_evaluations(resp);
  assert st = array['in_app', 'new', 'new', 'new', 'new'], format('FAIL: schedule preview statuses were %s', st);
  assert names = array['Zedjo Ellis', 'Zedkim Park', '-', '-', '-'], format('FAIL: schedule completions were %s', names);
  assert sched = array[true, true, false, false, false], format('FAIL: completions not flagged: %s', sched);
  assert not exists (select 1 from public.referees where display_name = 'Zedkim Park'),
    'FAIL: a preview created a referee';

  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st = array['in_app', 'new', 'new', 'new', 'new'], format('FAIL: schedule import statuses were %s', st);
  assert not exists (select 1 from public.evaluations where source = 'form' and form_source_key = 'test-sheet|sched' and form_row = 2),
    'FAIL: a first-name copy of an app evaluation was imported';
  assert (select r.display_name from public.evaluations e join public.referees r on r.id = e.referee_id
          where e.form_source_key = 'test-sheet|sched' and e.form_row = 3) = 'Zedkim Park',
    'FAIL: a completed name was not filed under the full name';
  assert (select referee_name from public.evaluations where form_source_key = 'test-sheet|sched' and form_row = 3) = 'zedkim',
    'FAIL: the name the mentor typed was not kept on the row';
  assert (select r.display_name from public.evaluations e join public.referees r on r.id = e.referee_id
          where e.form_source_key = 'test-sheet|sched' and e.form_row = 4) = 'Zedam',
    'FAIL: an ambiguous first name was completed';
  assert (select r.display_name from public.evaluations e join public.referees r on r.id = e.referee_id
          where e.form_source_key = 'test-sheet|sched' and e.form_row = 5) = 'Zedkim',
    'FAIL: a completion the admin turned off was applied';

  -- Importing again changes nothing.
  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st = array['in_app', 'same', 'same', 'same', 'same'], format('FAIL: re-importing changed something: %s', st);
end $$;

-- ---------- a first name matched to the mentor's own uploads ----------
-- The real case: a mentor writes up their Saturday on the form typing only
-- "Zedbrad", weeks after that schedule sheet moved on. Their own uploads for
-- the day name exactly one Zedbrad, so the response is theirs and is skipped.

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000b');
select public.save_evaluations(jsonb_build_array(
  pg_temp.item('zz-own-1', 'Zedbrad Shull')    || '{"eval_date": "2026-11-21", "kickoff": "11:40"}',
  pg_temp.item('zz-own-2', 'Zedjudah Steele')  || '{"eval_date": "2026-11-21", "kickoff": "11:40"}',
  -- Two referees share this first name on the same day: never guessed.
  pg_temp.item('zz-own-3', 'Zedtwin Alpha')    || '{"eval_date": "2026-11-21", "kickoff": "09:10"}',
  pg_temp.item('zz-own-4', 'Zedtwin Beta')     || '{"eval_date": "2026-11-21", "kickoff": "12:30"}'));

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare
  resp jsonb := jsonb_build_array(
    -- row 2: mentor 1's own write-up of Zedbrad Shull, first name only, no schedule saved
    jsonb_build_object('row', 2, 'source_key', 'test-sheet|own', 'mentor_name', 'Zz Mentor One', 'eval_date', '2026-11-21',
      'field', 'Field 4', 'kickoff', '11:40', 'referee_name', 'Zedbrad', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-11-28T16:00:00Z'),
    -- row 3: two Zedtwins that day - left as typed
    jsonb_build_object('row', 3, 'source_key', 'test-sheet|own', 'mentor_name', 'Zz Mentor One', 'eval_date', '2026-11-21',
      'field', 'Field 4', 'kickoff', '09:10', 'referee_name', 'Zedtwin', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-11-28T16:01:00Z'),
    -- row 4: ANOTHER mentor's form response naming a first name only. Mentor 1's
    -- uploads say nothing about whose evaluation this is.
    jsonb_build_object('row', 4, 'source_key', 'test-sheet|own', 'mentor_name', 'Zz Mentor Two', 'eval_date', '2026-11-21',
      'field', 'Field 4', 'kickoff', '11:40', 'referee_name', 'Zedjudah', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-11-28T16:02:00Z'),
    -- row 5: a first name nobody that mentor evaluated that day has
    jsonb_build_object('row', 5, 'source_key', 'test-sheet|own', 'mentor_name', 'Zz Mentor One', 'eval_date', '2026-11-21',
      'field', 'Field 4', 'kickoff', '11:40', 'referee_name', 'Zednobody', 'position', 'CR', 'appearance', '3',
      'saved_at', '2026-11-28T16:03:00Z'));
  st text[]; names text[]; sched boolean[];
begin
  select array_agg(out_status order by out_row), array_agg(coalesce(out_referee, '-') order by out_row),
         array_agg(out_from_schedule order by out_row)
  into st, names, sched from public.import_form_evaluations(resp);
  assert st = array['in_app', 'new', 'new', 'new'],
    format('FAIL: a first name matched to the mentor''s own uploads gave %s', st);
  assert names = array['Zedbrad Shull', '-', '-', '-'], format('FAIL: the names matched were %s', names);
  -- It came from the uploads, not the schedule: the console must not offer to
  -- turn a completion off when nothing was completed on the row it writes.
  assert sched = array[false, false, false, false], format('FAIL: an upload match claimed to be from the schedule: %s', sched);

  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st = array['in_app', 'new', 'new', 'new'], format('FAIL: importing changed the statuses: %s', st);
  assert not exists (select 1 from public.evaluations where source = 'form' and form_source_key = 'test-sheet|own' and form_row = 2),
    'FAIL: a first-name response the mentor had already uploaded was imported anyway';
  assert not exists (select 1 from public.referees where display_name = 'Zedbrad'),
    'FAIL: a bare first name became a referee of its own';
  assert (select count(*) from public.evaluations where form_source_key = 'test-sheet|own') = 3,
    'FAIL: the responses that cannot be matched did not import';
end $$;

-- A one-word name is never matched to a LAST name, and a full name typed on
-- the form is left alone even when someone shares its first name.
reset role;
do $$ begin
  assert public.upload_first_name_match('2026-11-21', '5d1e0000-0000-4000-8000-00000000000b', 'Zz Mentor One', 'Shull') is null,
    'FAIL: a one-word name matched a referee''s last name';
  assert public.upload_first_name_match('2026-11-21', '5d1e0000-0000-4000-8000-00000000000b', 'Zz Mentor One', 'Zedbrad Other') is null,
    'FAIL: a full name typed on the form was completed anyway';
  assert public.upload_first_name_match('2026-11-20', '5d1e0000-0000-4000-8000-00000000000b', 'Zz Mentor One', 'Zedbrad') is null,
    'FAIL: a first name matched an upload from another day';
end $$;

-- ---------- a merge made by an admin survives re-importing ----------
reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare
  r jsonb := jsonb_build_object('row', 2, 'source_key', 'test-sheet|merge', 'mentor_name', 'Zz Test Mentor',
    'eval_date', '2026-10-17', 'field', 'Field 9', 'kickoff', '09:00', 'referee_name', 'Zedmerge', 'position', 'CR',
    'appearance', '3', 'saved_at', '2026-10-17T16:00:00Z');
  st text[]; whole uuid; bare uuid; shown text;
begin
  perform public.import_form_evaluations(jsonb_build_array(r), true);
  select referee_id into bare from public.evaluations where form_source_key = 'test-sheet|merge';
  perform public.save_evaluations(jsonb_build_array(
    pg_temp.item('zz-merge-app', 'Zedmerge Fullname') || '{"eval_date": "2026-10-18"}'));
  select referee_id into whole from public.evaluations where client_id = 'zz-merge-app';
  perform public.merge_referees(bare, whole);

  -- The response is edited on the form afterwards.
  r := r || '{"comments": "Edited later", "saved_at": "2026-10-18T08:00:00Z"}';
  select array_agg(out_status), max(out_referee) into st, shown from public.import_form_evaluations(jsonb_build_array(r));
  assert st = array['changed'] and shown = 'Zedmerge Fullname',
    format('FAIL: the preview of a merged row said %s under %s', st, shown);
  perform public.import_form_evaluations(jsonb_build_array(r), true);
  assert (select referee_id from public.evaluations where form_source_key = 'test-sheet|merge') = whole,
    'FAIL: re-importing an edited response undid the admin''s merge';
  assert (select comments from public.evaluations where form_source_key = 'test-sheet|merge') = 'Edited later',
    'FAIL: the edit was not imported';
end $$;

-- ---------- a first-name row imported before its schedule was saved ----------
reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$
declare
  r jsonb := jsonb_build_object('row', 2, 'source_key', 'test-sheet|late', 'mentor_name', 'Zz Test Mentor',
    'eval_date', '2026-10-24', 'field', 'Field 4', 'kickoff', '09:00', 'referee_name', 'Zedlate', 'position', 'CR',
    'appearance', '3', 'saved_at', '2026-10-24T16:00:00Z');
  st text[];
begin
  perform public.import_form_evaluations(jsonb_build_array(r), true);
  perform public.save_schedule(jsonb_build_array(
    jsonb_build_object('date', '2026-10-24', 'field', 'Field 4', 'kickoff', '09:00', 'referee_name', 'Zedlate Newton')));
  select array_agg(out_status) into st from public.import_form_evaluations(jsonb_build_array(r), true);
  assert st = array['changed'], format('FAIL: a completable first-name row was not re-filed: %s', st);
  assert (select r2.display_name from public.evaluations e join public.referees r2 on r2.id = e.referee_id
          where e.form_source_key = 'test-sheet|late') = 'Zedlate Newton',
    'FAIL: a first-name row was not moved to the full name the schedule gives';
  select array_agg(out_status) into st from public.import_form_evaluations(jsonb_build_array(r), true);
  assert st = array['same'], format('FAIL: re-importing a re-filed row changed it again: %s', st);
end $$;

-- ---------- the prune matches the owning account ----------
reset role;
insert into public.evaluations (mentor_id, client_id, source, form_source_key, form_row, form_owner_mentor_id,
                                referee_id, referee_name, mentor_name, eval_date, position, saved_at)
select null, 'form:zz-owned', 'form', 'test-sheet|owned', 2, '5d1e0000-0000-4000-8000-00000000000b',
       referee_id, 'Zedjo Ellis', 'Mentor One Nickname', '2026-10-10', 'CR', '2026-10-10T20:00:00Z'
from public.evaluations where client_id = 'zz-sched-app';

select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
do $$ begin
  assert exists (select 1 from public.prune_duplicate_form_evaluations() where form_client = 'form:zz-owned'),
    'FAIL: the prune missed a copy owned by the uploading account under another typed name';
end $$;

-- ---------- a deletion request clears the schedule too ----------
do $$
declare rid uuid;
begin
  select referee_id into rid from public.evaluations where form_source_key = 'test-sheet|sched' and form_row = 3;
  perform public.delete_referee_records(rid);
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from public.schedule_slots where referee_name = 'Zedkim Park'),
    'FAIL: deleting a referee''s records left their name in the saved schedule';
  assert exists (select 1 from public.schedule_slots where referee_name = 'Zedjo Ellis'),
    'FAIL: deleting one referee''s records removed someone else from the schedule';
end $$;

-- ---------- demote then re-approve: access follows the role ----------

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
select public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-7', 'Zed Keeper')));
select public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000c', 'pending');

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000c');
do $$ begin
  assert (select count(*) from public.evaluations) = 0, 'FAIL: a demoted account can still read';
end $$;

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000a');
select public.set_mentor_role('5d1e0000-0000-4000-8000-00000000000c', 'mentor');

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000c');
do $$ begin
  assert (select count(*) from public.evaluations where client_id = 'zz-test-7') = 1,
    'FAIL: a re-approved account cannot read';
end $$;

reset role;
rollback;

-- Only reached if every assertion above held.
select 'ALL SIDELINE ACCESS TESTS PASSED' as result;
