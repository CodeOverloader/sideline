const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
function between(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert(a >= 0 && b > a, `Cannot extract ${start}`);
  return source.slice(a, b);
}
function context(code, scope = {}) { return vm.createContext({...scope, ...{console}, code}); }
function run(code, scope = {}) { const c = context(code, scope); vm.runInContext(code, c); return c; }
const noop = () => {};
const key = n => String(n || '').toLowerCase();
const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test('all embedded scripts and service worker parse', () => {
  for (const file of ['index.html', 'admin/index.html']) {
    const html = fs.readFileSync(path.join(root, file), 'utf8');
    for (const m of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(m[1], {filename:file});
  }
  new vm.Script(fs.readFileSync(path.join(root, 'sw.js'), 'utf8'));
});

test('saving on a new date never matches prior session IDs or another account', () => {
  const c = run(between('function savedRecordsFor(', 'function savedRecordFor('), {
    HIST: [{id:'old',refId:'r1',date:'2026-09-12',referee:'Jordan'},
      {id:'other',refId:'r1',date:'2026-09-19',referee:'Jordan',syncedBy:'other'},
      {id:'today',refId:'new-id',date:'2026-09-19',referee:'Jordan',syncedBy:'me'}],
    S:{date:'2026-09-19'}, ACCT:{id:'me'}, dayLead:g=>g[0], dayIds:()=>['r1'], nameKey:key
  });
  assert.deepEqual(Array.from(c.savedRecordsFor([{ref:{name:'Jordan'}}]), x=>x.id), ['today']);
});

test('malformed historical notes cannot crash profile rendering', () => {
  const c = run(between('const cleanNotes =', 'function tidyRecord(') + between('function fromRow(', 'let pullNext') + between('function buildProfile(', 'function topConcern('), {
    RATED:[], evalAvg:()=>null, mean:()=>null
  });
  const r = c.fromRow({notes:[null, 2, [], {pol:-1,text:'Positioning'}], saved_at:'2026-09-19', eval_date:'2026-09-19'});
  assert.equal(r.notes.length, 1);
  assert.equal(c.buildProfile([r]).count, 1);
});

function profileRecords(records) {
  const c = run('let profileCache = null;'+between('function profileIndex()', 'function profileFor('), {
    LEAGUE:{referees:new Map([['r',{id:'r',display_name:'Jordan Ellis'}]]),
      evals:new Map(records.map((r,i)=>['s'+i,{serverId:'s'+i,id:'c'+i,refereeId:'r',referee:'Jordan Ellis',date:'2026-09-19',savedAt:i,notes:[],...r}]))},
    HIST:[], isApproved:()=>true, ACCT:{id:'me'}, nameKey:key, nameIsOneWord:()=>false,
    canonicalRef:x=>x, tidyName:x=>x, buildProfile:r=>({count:r.length})
  });
  return [...c.profileIndex().groups.values()][0].records;
}
test('different accounts with the same name stay separate', () => {
  assert.equal(profileRecords([{mentorId:'a',mentor:'Pat'}, {mentorId:'b',mentor:'Pat'}]).length,2);
});
test('one owner under renamed accounts deduplicates, with app preferred', () => {
  const rows = profileRecords([{mentorId:'a',mentor:'New name',source:'app'},
    {formOwnerMentorId:'a',mentor:'Old name',source:'form',savedAt:100}]);
  assert.equal(rows.length,1); assert.equal(rows[0].source,'app');
});
test('unowned form responses are never merged by typed name', () => {
  assert.equal(profileRecords([{mentor:'Pat',source:'form'}, {mentor:'Pat',source:'form'}]).length,2);
});

function importContext(games, fields = []) {
  return run(between('function refHasAssessment(', '/* ---------- source 1:'), {
    S:{date:'2026-09-19',fields,ui:{}}, rowsToGames:()=>games, sessionHasData:()=>fields.length>0,
    flash:noop, FIELDS:[], SUBS:['A','B','C','D'], nameKey:key, save:noop, renderAll:noop,
    seatOrder:()=>[], relabelSlots:noop, plural:(n,s)=>`${n} ${s}`,
    newRef:(slot,role)=>({id:'new-ref',name:'',slot,role,notes:[],ratings:{},comments:''}),
    newField:()=>({id:'new-field',name:'',sub:'',time:'',refs:[]})
  });
}
const game = {key:'g',date:'2026-09-19',field:'Field 4',time:'09:00',sub:'',division:'4th',rule:{crew:1,pitches:1},names:['Replacement']};
test('multi-date imports stop before mutating the session', () => {
  const c = importContext([game,{...game,key:'g2',date:'2026-09-20'}]);
  assert.equal(c.applyGames(['g','g2']),false); assert.equal(c.S.fields.length,0); assert.equal(c.S.date,'2026-09-19');
});
test('single-date import into empty session adopts its date', () => {
  const c = importContext([{...game,date:'2026-09-20'}]);
  c.applyGames(['g']); assert.equal(c.S.date,'2026-09-20'); assert.equal(c.S.fields.length,1);
});
test('ratings and comments protect replacement names and retained extra slots', () => {
  const fields=[{id:'f',name:'Field 4',time:'09:00',sub:'',refs:[
    {name:'Original',role:'AR',notes:[],ratings:{appearance:4},comments:''},
    {name:'Extra',role:'AR',notes:[],ratings:{},comments:'Keep these comments'}]}];
  const c=importContext([game],fields); c.applyGames(['g']);
  assert.equal(fields[0].refs[0].name,'Original'); assert.equal(fields[0].refs[0].role,'AR');
  assert.equal(fields[0].refs.length,2);
});

test('legacy object-valued note fields cannot execute coercion paths', () => {
  const c=run(between('const cleanNotes =', 'function tidyRecord(')+'function sanitize(n) {return cleanNotes(n);}',{});
  const notes=c.sanitize([{text:{toString:'bad'},cat:{toString:'bad'},pol:{toString:'bad'}}]);
  assert.equal(notes[0].text,''); assert.equal(notes[0].cat,''); assert.equal(notes[0].pol,0);
});

test('confirmed revocation clears account approval before sync', async () => {
  const c=run(between('async function checkAccess(', '/* The server credits'),{
    ACCT:{id:'me',status:'mentor'},accountEpoch:1,isApproved:()=>true,
    setAcct:v=>{c.ACCT=v;}
  });
  const client={auth:{getSession:async()=>({data:{session:{user:{id:'me'}}}})},
    from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:{role:'pending'}})})})})};
  assert.equal(await c.checkAccess(client,'me',1),false); assert.equal(c.ACCT.status,'pending');
});

test('previously cached malformed notes are sanitized before profiles render', async () => {
  const c=run(between('const cleanNotes =', 'function tidyRecord(') + between('function loadLeagueCache()', 'function persistLeague()') + 'function snapshot() {return LEAGUE;}', {
    leagueLoading:null, LEAGUE:{account:'',pulledAt:0}, ACCT:{id:'me'}, isApproved:()=>true,
    invalidateProfiles:noop, idb:{get:async()=>({account:'me',pulledAt:10,evals:[{serverId:'r',notes:[null,{pol:1,text:'Good'}]}],referees:[]})}
  });
  await c.loadLeagueCache(); assert.equal(c.snapshot().evals.get('r').notes.length,1);
});

test('sync stops across account changes and ignores old acknowledgements', async () => {
  let calls=0;
  const c=run(between('function syncNow()', 'function paintSync()'),{
    ACCT:{id:'me'}, accountEpoch:1, isApproved:()=>true, uploadConsent:()=>true,
    pendingDeletes:()=>[], checkAccess:async()=>true,updateMentorName:async()=>true,
    HIST:Array.from({length:51},(_,i)=>({id:'c'+i,savedAt:1})),needsUpload:()=>true,
    SYNC:{running:null}, clearTimeout:noop,setTimeout:noop,paintSync:noop,histChanged:noop,save:noop,
    store:{set:noop},pullLeague:noop,navigator:{onLine:true},friendly:String,
    toPayload:r=>({client_id:r.id}),sbc:()=>({rpc:async()=>{
      calls++;c.ACCT={id:'other'};c.accountEpoch++;
      return {data:[{out_client_id:'c0',out_updated_at:'v2'}]};
    }})
  });
  await c.syncNow(); assert.equal(calls,1); assert.equal(c.HIST[0].syncedAt,undefined);
});

test('an edit during upload retains version ack for the next save', async () => {
  const c=run(between('function syncNow()', 'function paintSync()'),{
    ACCT:{id:'me'}, accountEpoch:1, isApproved:()=>true, uploadConsent:()=>true,
    pendingDeletes:()=>[], checkAccess:async()=>true,updateMentorName:async()=>true,
    HIST:[{id:'c',savedAt:1}],needsUpload:()=>true,SYNC:{running:null},clearTimeout:noop,setTimeout:noop,
    paintSync:noop,histChanged:noop,save:noop,store:{set:noop},pullLeague:noop,navigator:{onLine:true},friendly:String,
    toPayload:r=>({client_id:r.id}),sbc:()=>({rpc:async()=>{
      c.HIST[0].savedAt=2;return {data:[{out_client_id:'c',out_updated_at:'v2',out_referee_id:'r'}]};
    }})
  });
  await c.syncNow(); assert.equal(c.HIST[0].serverUpdatedAt,'v2'); assert.equal(c.HIST[0].syncedAt,undefined);
});

(async()=>{
  for (const [name,fn] of tests) {await fn();console.log('PASS '+name);}
  console.log(`${tests.length} mentor regression checks passed`);
})().catch(e=>{console.error(e);process.exitCode=1;});