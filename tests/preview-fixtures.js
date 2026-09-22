/* Injected only by preview-server.cjs. All names and evaluations are synthetic. */
(() => {
  const params = new URLSearchParams(location.search);
  const scenario = params.get('scenario') || (location.pathname.includes('/admin') ? 'admin' : 'guest');
  const now = new Date();
  const date = [now.getFullYear(), String(now.getMonth()+1).padStart(2,'0'), String(now.getDate()).padStart(2,'0')].join('-');
  const account = {id:'preview-mentor',email:'preview@example.test',display_name:'Alex Morgan',role:scenario === 'admin' ? 'admin' : 'mentor',created_at:now.toISOString()};
  const cats = ['appearance','workrate','commands','teamwork','fouls','offsides'];
  const names = ['Jordan Ellis', 'Sam Rivera', 'Taylor Brooks', 'Avery Chen', 'Cameron Lee', 'Morgan Patel'];
  const referees = names.map((name,i) => ({id:'ref-'+i,display_name:name,name_key:name.toLowerCase(),merged_into:null,updated_at:now.toISOString()}));
  const mentors = [account, {id:'second-mentor',email:'casey@example.test',display_name:'Casey Wilson',role:'mentor',created_at:now.toISOString()},
    {id:'pending-mentor',email:'new@example.test',display_name:'Drew Parker',role:'pending',created_at:now.toISOString()}];
  const rows = Array.from({length:24}, (_,i) => {
    const day = new Date(now); day.setDate(day.getDate() - Math.floor(i/6)*7);
    return {id:'eval-'+i,client_id:'client-'+i,referee_id:referees[i%6].id,referee_name:names[i%6],mentor_id:i%2 ? 'second-mentor' : account.id,
      mentor_name:i%2 ? 'Casey Wilson' : account.display_name,eval_date:day.toISOString().slice(0,10),field:'Field 4',kickoff:'09:00',division:i%3 ? '4th' : '2nd',
      position:i%3 ? 'AR' : 'CR',source:'app',move_up:i%4 ? 'No' : 'Yes',comments:'Clear communication with the crew. Continue working on the angle of view near the penalty area.',
      ...Object.fromEntries(cats.map((c,j) => [c, 1+(i+j)%4])),
      notes:[{cat:'commands',pol:1,text:'Clear, confident signals',at:now.getTime()},{cat:'workrate',pol:-1,text:'Find a better angle near the penalty area',at:now.getTime()}],
      saved_at:day.toISOString(),updated_at:now.toISOString()};
  });
  function ref(i,slot,role) {return {id:'draft-'+i,name:names[i],slot,role,notes:[],ratings:Object.fromEntries(cats.map(c => [c,null])),comments:'',commentsEdited:false,noOffsides:false,moveUp:null,submitted:false};}
  const initial = {mentor:account.display_name,date,fields:[
    {id:'game-1',name:'Field 4',sub:'',time:'09:00',division:'4th',crewSize:3,done:false,refs:[ref(0,'CR','CR'),ref(1,'AR1','AR'),ref(2,'AR2','AR')]},
    {id:'game-2',name:'Field 2A',sub:'',time:'10:30',division:'5th',crewSize:3,done:false,refs:[ref(3,'CR','CR'),ref(4,'AR1','AR'),ref(5,'AR2','AR')]}
  ],activeRefId:'draft-0',ui:{tab:'fields',fieldId:'game-1',cat:'workrate',pol:1,draftText:'',showDone:false,keepDate:null}};
  const seeded = 'preview-seeded-'+scenario;
  if ((!localStorage.getItem('sideline-beta:session') && scenario !== 'guest') || params.get('reset') === '1') {
    if (params.get('reset') === '1') for (const k of Object.keys(localStorage)) if (k.startsWith('sideline-beta:')) localStorage.removeItem(k);
    if (scenario !== 'guest') {
      localStorage.setItem('sideline-beta:session', JSON.stringify(initial));
      localStorage.setItem('sideline-beta:mentor', JSON.stringify(account.display_name));
      localStorage.setItem('sideline-beta:uploadConsent', JSON.stringify({[account.id]:true}));
    }
    sessionStorage.setItem(seeded,'1');
  }
  let session = scenario === 'guest' ? null : {user:{id:account.id,email:account.email}};
  const subscribers = [];
  function query(table) {
    let values = table === 'mentors' ? mentors : table === 'referees' ? referees : table === 'evaluations' ? rows : [];
    let one = false;
    const q = {select(){return q;},order(){return q;},limit(n){values=values.slice(0,n);return q;},
      eq(k,v){values=values.filter(x=>x[k]===v);return q;},in(k,v){values=values.filter(x=>v.includes(x[k]));return q;},
      gt(){return q;},gte(){return q;},or(){return q;},is(){return q;},range(a,b){values=values.slice(a,b+1);return q;},
      maybeSingle(){one=true;return q;},single(){one=true;return q;},update(){return q;},delete(){values=[];return q;},
      then(resolve,reject){return Promise.resolve({data:one ? values[0] || null : values,error:null}).then(resolve,reject);}};
    return q;
  }
  window.supabase = {createClient:() => ({from:query,auth:{
    onAuthStateChange(fn){subscribers.push(fn); setTimeout(()=>fn('INITIAL_SESSION',session),0); return {data:{subscription:{unsubscribe(){}}}};},
    async getSession(){return {data:{session},error:null};},
    async signInWithOtp(){return {error:null};},
    async verifyOtp(){session={user:{id:account.id,email:account.email}};subscribers.forEach(fn=>fn('SIGNED_IN',session));return {error:null};},
    async signOut(){session=null;subscribers.forEach(fn=>fn('SIGNED_OUT',null));return {error:null};}
  },async rpc(name,args){
    if (name === 'save_evaluations') return {data:args.p_items.map(r => {
      let referee = referees.find(x => x.display_name.toLowerCase() === r.referee_name.toLowerCase());
      if (!referee) {
        referee = {id:'ref-'+referees.length,display_name:r.referee_name,name_key:r.referee_name.toLowerCase(),merged_into:null,updated_at:new Date().toISOString()};
        referees.push(referee);
      }
      return {out_client_id:r.client_id,out_referee_id:referee.id,out_updated_at:new Date().toISOString(),out_error:null};
    }),error:null};
    return {data:[],error:null};
  }})};
})();
