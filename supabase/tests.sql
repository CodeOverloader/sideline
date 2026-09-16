-- ============================================================
-- Sideline access-rule tests
-- ------------------------------------------------------------
-- Run AFTER schema.sql, in the Supabase SQL editor.
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
    'client_id', p_client, 'referee_name', p_referee, 'mentor_name', 'Test Mentor',
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
  perform pg_temp.expect_error($q$ select public.save_evaluations(jsonb_build_array(pg_temp.item('zz-test-x', '  '))) $q$,
    '22023', 'a blank referee name');
end $$;

-- ---------- mentor 2: shared reads, no writes to others ----------

reset role;
select pg_temp.act_as('5d1e0000-0000-4000-8000-00000000000c');

do $$
declare gavin uuid;
begin
  assert (select count(*) from public.evaluations where client_id = 'zz-test-1') = 1,
    'FAIL: an approved mentor cannot read another mentor''s evaluation';

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
  update public.mentors set display_name = 'Renamed' where id = '5d1e0000-0000-4000-8000-00000000000c';
  assert (select display_name from public.mentors) = 'Renamed', 'FAIL: a mentor cannot rename themselves';
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
