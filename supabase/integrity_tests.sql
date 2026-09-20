-- Run after migrations, using the same privileged local harness as tests.sql.
-- All fixtures roll back. No production connection is needed.
begin;
insert into auth.users(id,email) values
 ('5d1e9999-0000-4000-8000-000000000001','integrity1@sideline-test.invalid'),
 ('5d1e9999-0000-4000-8000-000000000002','integrity2@sideline-test.invalid');
update public.mentors set role='admin',display_name='Integrity Mentor One'
 where id='5d1e9999-0000-4000-8000-000000000001';
update public.mentors set role='mentor',display_name='Integrity Mentor Two'
 where id='5d1e9999-0000-4000-8000-000000000002';
select set_config('request.jwt.claims','{"sub":"5d1e9999-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
do $$
declare
 item jsonb := '{"client_id":"integrity-app","referee_name":"Integrity Referee","eval_date":"2026-09-12","position":"CR","notes":[],"saved_at":"2026-09-12T15:00:00Z"}';
 r record;
 rid uuid;
 stamp timestamptz;
begin
 select * into r from public.save_evaluations(jsonb_build_array(item || '{"notes":[null]}'));
 assert r.out_error is not null, 'FAIL: null note accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item || '{"notes":[{"pol":{"toString":"x"},"text":"x"}]}'));
 assert r.out_error is not null, 'FAIL: object polarity accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item || '{"notes":[{"at":{},"text":"x"}]}'));
 assert r.out_error is not null, 'FAIL: object timestamp accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item || '{"expected_mentor_id":"5d1e9999-0000-4000-8000-000000000002"}'));
 assert r.out_error like 'Account changed%', 'FAIL: changed account accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item));
 assert r.out_error is null, 'FAIL: valid save rejected';
 rid := r.out_referee_id; stamp := r.out_updated_at;
 select * into r from public.save_evaluations(jsonb_build_array(item || '{"client_id":"integrity-second-device"}'));
 assert r.out_error like 'You already uploaded%', 'FAIL: second-device daily duplicate accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item || '{"saved_at":"2026-09-11T15:00:00Z"}'));
 assert r.out_error like 'An older save%', 'FAIL: stale save accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item || jsonb_build_object('expected_updated_at',stamp - interval '1 second','comments','stale change')));
 assert r.out_error like 'This evaluation changed%', 'FAIL: stale version accepted';
 select * into r from public.save_evaluations(jsonb_build_array(item || jsonb_build_object('expected_updated_at',stamp,'comments','updated')));
 assert r.out_error is null, 'FAIL: matching version rejected';
 select * into r from public.save_evaluations(jsonb_build_array(item || jsonb_build_object('expected_updated_at',stamp - interval '1 second','comments','updated')));
 assert r.out_error is null, 'FAIL: idempotent retry rejected';
 perform public.delete_referee_records(rid);
 select * into r from public.save_evaluations(jsonb_build_array(item));
 assert r.out_error like 'This evaluation was deleted%', 'FAIL: deleted evaluation resurrected';
end $$;
reset role;
update public.mentors set display_name='' where id='5d1e9999-0000-4000-8000-000000000001';
set local role authenticated;
do $$ declare r record; begin
 select * into r from public.save_evaluations('[{"client_id":"blank","referee_name":"Blank Test","mentor_name":"Integrity Mentor Two","position":"CR"}]');
 assert r.out_error like 'Set your account display name%', 'FAIL: blank account spoof accepted';
end $$;
reset role;
update public.mentors set display_name='Integrity Mentor One' where id='5d1e9999-0000-4000-8000-000000000001';
set local role authenticated;
do $$
declare
 r record;
 bare uuid;
 whole uuid;
 app jsonb := '{"client_id":"integrity-merge-bare","referee_name":"Integritybare","eval_date":"2026-10-01","position":"CR","notes":[],"saved_at":"2026-10-01T15:00:00Z"}';
 form jsonb := '{"row":2,"source_key":"integrity-sheet|42","referee_name":"Integritybare Full","mentor_name":"Integrity Mentor One","eval_date":"2026-10-01","position":"AR","kickoff":"12:00","saved_at":"2026-10-01T15:00:00Z"}';
begin
 select * into r from public.save_evaluations(jsonb_build_array(app));
 assert r.out_error is null, 'FAIL: merge fixture bare save'; bare := r.out_referee_id;
 select * into r from public.save_evaluations(jsonb_build_array(app || '{"client_id":"integrity-merge-full","referee_name":"Integritybare Full","eval_date":"2026-10-02"}'));
 assert r.out_error is null, 'FAIL: merge fixture full save'; whole := r.out_referee_id;
 perform public.merge_referees(bare,whole);
 select * into r from public.save_evaluations(jsonb_build_array(app || '{"comments":"edit after merge","saved_at":"2026-10-02T15:00:00Z"}'));
 assert r.out_error is null and r.out_referee_id=whole, 'FAIL: app edit undid bare-name merge';
 select * into r from public.import_form_evaluations(jsonb_build_array(form),true);
 assert r.out_status='in_app', 'FAIL: form-after-app daily identity differs';
 form := form || '{"row":3,"eval_date":"2026-10-03"}';
 select * into r from public.import_form_evaluations(jsonb_build_array(form),true);
 assert r.out_status='new', 'FAIL: form fixture save';
 select * into r from public.save_evaluations(jsonb_build_array(app || '{"client_id":"integrity-app-after-form","referee_name":"Integritybare Full","eval_date":"2026-10-03","position":"CR","kickoff":"09:00"}'));
 assert r.out_error is null, 'FAIL: app-after-form save';
 assert not exists(select 1 from public.evaluations where source='form' and form_source_key='integrity-sheet|42'), 'FAIL: app-after-form did not use daily identity';
 form := form || '{"row":4,"eval_date":"2026-10-04"}';
 select * into r from public.import_form_evaluations(jsonb_build_array(form),true);
 assert r.out_status='new', 'FAIL: deleted form fixture';
 perform public.delete_referee_records(whole);
 select * into r from public.import_form_evaluations(jsonb_build_array(form),true);
 assert r.out_status='error' and r.out_error like 'This response was deleted%', 'FAIL: deleted form resurrected';
 -- A known ambiguous schedule must suppress own-upload first-name fallback.
 select * into r from public.save_evaluations('[{"client_id":"integrity-ambiguous","referee_name":"Ambiguous One","eval_date":"2026-11-01","position":"CR"}]');
 perform public.save_schedule('[{"date":"2026-11-01","field":"Field 1","kickoff":"09:00","referee_name":"Ambiguous One"},{"date":"2026-11-01","field":"Field 1","kickoff":"09:00","referee_name":"Ambiguous Two"}]');
 select * into r from public.import_form_evaluations('[{"row":2,"source_key":"integrity-ambiguity|42","referee_name":"Ambiguous","mentor_name":"Integrity Mentor One","eval_date":"2026-11-01","field":"Field 1","kickoff":"09:00","position":"CR"}]',false);
 assert r.out_status='new' and r.out_referee is null, 'FAIL: ambiguous schedule fell back to own uploads';
 -- Legacy default-tab rows adopt an explicit tab only when every field agrees.
 form := '{"row":2,"source_key":"integrity-legacy|","referee_name":"Legacy Integrity","mentor_name":"Integrity Mentor One","eval_date":"2026-12-01","position":"CR","saved_at":"2026-12-01T15:00:00Z"}';
 select * into r from public.import_form_evaluations(jsonb_build_array(form),true);
 assert r.out_status='new', 'FAIL: legacy form fixture';
 select * into r from public.import_form_evaluations(jsonb_build_array(form || '{"source_key":"integrity-legacy|0"}'),false);
 assert r.out_status='changed', 'FAIL: legacy-only preview cannot be applied';
 select * into r from public.import_form_evaluations(jsonb_build_array(form || '{"source_key":"integrity-legacy|0"}'),true);
 assert r.out_status='changed', 'FAIL: legacy form not adopted';
 assert (select count(*) from public.evaluations where referee_name='Legacy Integrity')=1, 'FAIL: tab identity duplicated response';
end $$;
reset role;
-- Simulate a historical form owned by another account whose typed name now
-- matches the current uploader (e.g. after account renames).
insert into public.evaluations(mentor_id,client_id,source,form_source_key,form_row,form_owner_mentor_id,
 referee_id,referee_name,mentor_name,eval_date,position,saved_at)
select null,public.form_client_id('integrity-owner|42',2),'form','integrity-owner|42',2,
 '5d1e9999-0000-4000-8000-000000000002',referee_id,referee_name,mentor_name,eval_date,position,'2026-11-01T15:00:00Z'
from public.evaluations where client_id='integrity-ambiguous';
set local role authenticated;
do $$ declare r record; begin
 assert not exists(select 1 from public.prune_duplicate_form_evaluations(true) where referee='Ambiguous One'),
   'FAIL: prune ignored a fixed owner';
 select * into r from public.import_form_evaluations('[{"row":2,"source_key":"integrity-owner|42","referee_name":"Ambiguous One","mentor_name":"Integrity Mentor One","eval_date":"2026-11-01","position":"CR","saved_at":"2026-11-01T15:00:00Z"}]',true);
 assert r.out_status='same', 'FAIL: import ignored fixed owner';
end $$;
reset role;
rollback;
select 'ALL SIDELINE INTEGRITY TESTS PASSED' as result;
