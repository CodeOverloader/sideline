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
    pg_temp.item('zz-test-1', 'Testref, Zed', 'forged') || '{"mentor_id":"5d1e0000-0000-4000-8000-00000000000b"}'));
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
  assert st = array['in_app', 'new', 'error', 'new', 'same'], format('FAIL: preview statuses were %s', st);
  assert (select count(*) from public.evaluations where source = 'form') = 1, 'FAIL: a preview saved something';
  assert (select form_source_key is null from public.evaluations where source = 'form'),
    'FAIL: a preview adopted the old imported row';
  assert not exists (select 1 from public.referees where display_name = 'Zed Formonly'),
    'FAIL: a preview created a referee';

  select array_agg(out_status order by out_row) into st from public.import_form_evaluations(resp, true);
  assert st = array['in_app', 'new', 'error', 'new', 'same'], format('FAIL: import statuses were %s', st);
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

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000c');
do $$ begin
  perform pg_temp.expect_error($q$ select public.import_form_evaluations('[]', true) $q$,
    '42501', 'a mentor importing form responses');
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
