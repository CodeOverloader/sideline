const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const s=fs.readFileSync(require('node:path').join(__dirname,'../admin/index.html'),'utf8').split('<script>').pop().split('</script>')[0];new vm.Script(s);
const part=(a,b)=>s.slice(s.indexOf(a),s.indexOf(b,s.indexOf(a)));
const c=vm.createContext({Intl,Date,Map,JSON});vm.runInContext(part('const FORM_TIME_ZONE','/* ---------- the schedule')+part('function formSheetKey(','/* RFC 4180')+part('function profileRecords(','function groupRefs('),c);
for(const [input,expected] of [['9/12/2026 1:30:00 AM','2026-09-12T06:30:00.000Z'],['9/12/2026 1:30:00 PM','2026-09-12T18:30:00.000Z'],['1/12/2026 12:00:00 AM','2026-01-12T06:00:00.000Z'],['1/12/2026 12:00:00 PM','2026-01-12T18:00:00.000Z'],['3/8/2026 2:30:00 AM',''],['2/30/2026 9:00:00 AM',''],['11/1/2026 1:30:00 AM','2026-11-01T06:30:00.000Z'],['9/12/2026 25:30','']])assert.equal(c.formStamp(input),expected,input);
const link='https://docs.google.com/spreadsheets/d/abcdefghijklmnopqrstuv/edit';assert.throws(()=>c.formSheetKey(link),/including #gid=/);assert.equal(c.formSheetKey(link+'#gid=00123'),c.formSheetKey(link+'?gid=123'));
const rec=(id,owner,form,savedAt=1)=>({id,refereeId:'ref',date:'2026-09-12',mentorId:owner,mentor:'Same Name',fromForm:form,savedAt,notes:[]});
assert.equal(c.profileRecords([rec('a','one',false),rec('b','two',false)]).length,2);
assert.equal(c.profileRecords([rec('a','',true),rec('b','',true)]).length,2);
assert.equal(c.profileRecords([rec('a','one',false),{...rec('b','',true,2),formOwnerMentorId:'one'}])[0].id,'a');
assert.equal(c.profileRecords([rec('a','one',false),rec('b','one',false,2)])[0].id,'b');
let resolveRows;const deferred=new Promise(r=>resolveRows=r);const ST={auth:'admin',me:{id:'owner'}};const client={from:()=>({select(){return this;},order(){return this;}})};
const race=vm.createContext({ST,sbc:()=>client,paintBusy(){},render(){},pageAll:()=>deferred,ISO_RE:/^\d{4}-\d{2}-\d{2}$/,RATED:[],evalAvg:()=>0,friendly:String});vm.runInContext('let DATA=null,dataVersion=0,authGeneration=0,loadGeneration=0;'+part('async function loadAll(','async function refresh('),race);
async function testRecovery() {
  let blob, clicked = false, appended = false;
  const raw = [{id:'outside-filter',notes:[{pol:1,text:'Preserve note'}],form_owner_mentor_id:'owner'}];
  const refs = new Map([['alias',{id:'alias',merged_into:'survivor',name_key:'alias'}]]);
  const recovery=vm.createContext({ST:{auth:'admin'},DATA:{at:1,rawEvaluations:raw,referees:refs,mentors:[{id:'owner'}]},
    Date,JSON,Blob,URL:{createObjectURL:b=>{blob=b;return 'blob:test';},revokeObjectURL(){}},
    document:{body:{appendChild(){appended=true;}},createElement:()=>({click(){clicked=true;},remove(){}})},
    setTimeout(){},flash(){},todayISO:()=> '2026-09-19'});
  vm.runInContext(part('function exportRecovery()', 'function exportEvals()'),recovery);
  recovery.exportRecovery(); assert(clicked && appended);
  const payload=JSON.parse(await blob.text());
  assert.deepEqual(payload.evaluations,raw); assert.deepEqual(payload.referees,[...refs.values()]);
  assert.equal(payload.mentors[0].id,'owner'); assert.match(payload.scope,/excludes Auth users/);
}
(async()=>{await testRecovery();const pending=race.loadAll();vm.runInContext("authGeneration++;ST.auth='signedOut';ST.me=null;",race);resolveRows([]);await pending;assert.equal(vm.runInContext('DATA',race),null);console.log('Admin regressions passed: timestamp/DST, tab identity, owner deduplication, recovery payload, stale-load guard, inline syntax.');})().catch(e=>{console.error(e);process.exitCode=1;});

