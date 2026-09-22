const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const s = fs.readFileSync(path.join(root,'index.html'),'utf8');
function part(a,b) {const start=s.indexOf(a),end=s.indexOf(b,start);assert(start>=0&&end>start);return s.slice(start,end);}
const cats = ['appearance','workrate','commands','teamwork','fouls','offsides'].map(id=>({id,short:id}));
const ratings=Object.fromEntries(cats.map(c=>[c.id,3]));
const ref={id:'r',name:'Jordan Ellis',ratings:{...ratings},moveUp:'No',comments:'Clear signals.'};
const field={name:'A newly named field',time:'09:00',division:'4th'};
const c=vm.createContext({JSON,Date,Number,RATED:cats,S:{date:'2026-09-21',mentor:'Alex Morgan'},dayLead:g=>g[0],
  dayHasOffside:g=>g[0].field.division!=='Kindergarten',nameKey:v=>v.toLowerCase().replace(/[^a-z0-9]/g,'')});
vm.runInContext(part('function missingFor(', 'function readyHTML(')+part('function sameEvaluation(', 'function nextReferee('),c);
assert.equal(c.missingFor([{field,ref}]).length,0,'New schedule field names do not depend on the old Google Form’s options');
assert(c.missingFor([{field,ref:{...ref,ratings:{...ratings,fouls:null}}}]).includes('fouls'));
assert(c.missingFor([{field,ref:{...ref,ratings:{...ratings,fouls:8}}}]).includes('fouls'));
assert(c.missingFor([{field,ref:{...ref,name:'!!!'}}]).includes('referee name'));
assert(c.missingFor([{field,ref:{...ref,draftText:'A note still being written'}}]).includes('an unfinished note (Observe)'));
assert.equal(c.missingFor([{field,ref:{...ref,noOffsides:true,ratings:{...ratings,offsides:null}}}]).length,0);
assert.equal(c.missingFor([{field:{...field,division:'Kindergarten'},ref:{...ref,ratings:{...ratings,offsides:null}}}]).length,0);
c.S.date='2026-02-30'; assert(c.missingFor([{field,ref}]).includes('a valid session date')); c.S.date='2026-09-21';
assert(c.missingFor([{field:{...field,time:'25:80'},ref}]).includes('kickoff'));
const record={mentor:'Alex Morgan',date:'2026-09-21',referee:ref.name,ratings,comments:ref.comments,moveUp:'No',
  notes:[{cat:'commands',pol:1,text:'Clear signals',at:1}],games:[{field:'Field 4',time:'09:00',division:'4th',position:'CR',slot:'CR'}]};
assert(c.sameEvaluation(record,structuredClone(record)));
const edit=structuredClone(record);edit.notes.push({cat:'commands',pol:1,text:'Clear signals',at:2});
assert(!c.sameEvaluation(record,edit),'New notes must enable Save changes even with manually edited feedback');
const otherGame=structuredClone(record);otherGame.games.push({...record.games[0],time:'10:00'});
assert(!c.sameEvaluation(record,otherGame),'An additional covered game must enable Save changes');
const saveContext=vm.createContext({activePair:()=>({ref}),dayGroupFor:()=>[{ref,field}],dayLead:g=>g[0],
  missingFor:()=>['feedback'],flash(){},$:()=>null});
vm.runInContext(part('function saveEval()', 'function csvCell('),saveContext);
saveContext.saveEval(); // No state/upload functions exist: incomplete reviews must stop before either.
const payloadContext=vm.createContext({ACCT:{id:'me'},RATED:cats,Date,
  clip:(s,n)=>s.slice(0,n)});
vm.runInContext(part('function toPayload(', 'function queueRemoteDelete('),payloadContext);
assert.equal(payloadContext.toPayload({...record,ratings:{...ratings,offsides:null}}).offsides,null);

const noteRef = {notes:[],draftText:'Custom thought',comments:'',commentsEdited:false};
const noteContext = vm.createContext({Date,activePair:()=>({ref:noteRef}),uid:()=> 'note',save(){},renderAll(){},flash(){},refDisplay:()=> 'Jordan'});
vm.runInContext(part('function addNote(', 'function dropNote('),noteContext);
noteContext.addNote('commands',1,'Clear signals');
assert.equal(noteRef.draftText,'Custom thought','Quick notes must preserve text still being composed');
noteContext.addNote('commands',1,noteRef.draftText,true);
assert.equal(noteRef.draftText,'');
assert.equal(noteRef.notes.length,2);

// Backup preferences cross the production/beta namespace boundary without carrying authentication.
let backupValue;
const backupContext=vm.createContext({JSON,Date,S:{fields:[]},HIST:[],store:{get:()=>undefined},
  tidyRecord:x=>x,normalize(){},histChanged(){},save(){},setTab(){},flash(){},
  askConfirm:(message,label,yes)=>yes(),setTheme:()=>{},});
vm.runInContext(part('const BACKUP_KEYS =', '/* Asks the browser'),backupContext);
const restored=new Map();backupContext.store={get:()=>undefined,set:(k,v)=>restored.set(k,v)};
backupContext.restoreBackup(JSON.stringify({app:'sideline',version:1,session:{fields:[],mentor:'Alex'},history:[],
  prefs:{'sideline:sheet':{id:'test-sheet'},'sideline:theme':'light','sideline:auth':'do-not-import'}}));
assert.equal(restored.get('sideline-beta:sheet').id,'test-sheet');
assert(!restored.has('sideline-beta:auth'));

async function workerChecks() {
  const handlers={},deleted=[],scoped='sideline:/beta/:beta-2'; let shell=[];
  const cache={addAll:async files=>{shell=files;},match:async key=>typeof key==='string'&&key.includes('index.html')?new Response('mentor shell'):undefined,put:async()=>{}};
  const w=vm.createContext({URL,Request,Response,Promise,setTimeout:fn=>{queueMicrotask(fn);return 0;},
    fetch:async()=>{throw new Error('offline');},caches:{open:async()=>cache,
      keys:async()=>[scoped,'sideline:/beta/:old','sideline:/production/:beta-2','another-app','sideline-shell-v4'],
      delete:async k=>deleted.push(k)},self:{registration:{scope:'https://example.test/beta/'},location:{origin:'https://example.test'},
      addEventListener:(type,fn)=>handlers[type]=fn,skipWaiting(){},clients:{claim(){}}}});
  vm.runInContext(fs.readFileSync(path.join(root,'sw.js'),'utf8'),w);
  let pending; handlers.install({waitUntil:p=>pending=p});await pending;
  assert(shell.includes('./assets/design-system.css?v=beta2'));
  for(const asset of shell) if(asset!=='./') assert(fs.existsSync(path.join(root,asset.split('?')[0])),asset);
  handlers.activate({waitUntil:p=>pending=p});await pending;
  assert.deepEqual(deleted,['sideline:/beta/:old'],'Never delete another page’s caches');
  for(const url of ['https://example.test/production/','https://example.supabase.co/rest/v1/evaluations','https://docs.google.com/spreadsheets/d/example']) {
    let intercepted=false;handlers.fetch({request:new Request(url),respondWith(){intercepted=true;}});assert(!intercepted,url);
  }
  assert.equal(await (await w.networkFirst(new Request('https://example.test/beta/'))).text(),'mentor shell');
  await assert.rejects(w.networkFirst(new Request('https://example.test/beta/admin/')),/offline/,'Admin must not fall back to the mentor shell');
}
workerChecks().then(()=>console.log('Beta regressions passed: completion guards, unrated offside, meaningful edits, portable backups, isolated caches and offline paths.')).catch(e=>{console.error(e);process.exitCode=1;});
