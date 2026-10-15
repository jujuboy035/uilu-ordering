const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync('supabase/functions/kuilu-manage-accounts/index.ts','utf8').replace(/^import[^\n]+\n/,'').split('const admin=createClient')[0];
const make=vm.runInNewContext(source+'\ncreateHandler',{Set,Response,Request,TextDecoder,TextEncoder,JSON});
const actor='00000000-0000-4000-8000-000000000001',target='00000000-0000-4000-8000-000000000002';
function mock(role='admin',duplicate=false){const state={creates:[],resets:[]};const admin={auth:{getUser:async(token)=>token==='valid'?{data:{user:{id:actor}}}:{error:true,data:{user:null}},admin:{createUser:async(data)=>{state.creates.push(data);return {data:{user:{id:target}}}},getUserById:async()=>({data:{user:{id:target}}}),updateUserById:async(id,data)=>{state.resets.push({id,data});return {data:{user:{id}}}}}},from(){let key;return {select(){return this},eq(k){key=k;return this},async maybeSingle(){return {data:key==='id'?{role}:duplicate?{id:target}:null}}}}};return {handler:make(admin),state}}
const request=(body,token='valid',origin='https://kuilu-ordering.wavypond9.chatgpt.site')=>new Request('https://test.invalid/',{method:'POST',headers:{origin,...(token?{authorization:'Bearer '+token}:{}),'content-type':'application/json'},body:JSON.stringify(body)});
(async()=>{
 const {handler,state}=mock();
 const payload={action:'create',username:' Customer01 ',password:'test-only-123',role:'customer'};
 assert.equal((await handler(request(payload,''))).status,401);
 assert.equal((await handler(request(payload,'bad'))).status,401);
 assert.equal((await handler(request(payload,'valid','https://evil.invalid'))).status,403);
 assert.equal((await mock('customer').handler(request(payload))).status,403);
 assert.equal((await mock('china').handler(request(payload))).status,403);
 assert.equal((await mock('driver').handler(request(payload))).status,403);
 assert.equal((await mock('admin',true).handler(request(payload))).status,409);
 assert.equal((await handler(request({...payload,username:'a@evil.test'}))).status,400);
 assert.equal((await handler(request({...payload,password:'short'}))).status,400);
 const result=await handler(request(payload));assert.equal(result.status,201);
 const body=await result.json();assert.equal(body.username,'customer01');assert(!('password' in body));assert(!('email' in body));
 assert.equal(state.creates[0].email,'customer01@accounts.kuilu.invalid');assert.equal(state.creates[0].email_confirm,true);
 assert.equal(state.creates[0].app_metadata.kuilu_created_by,actor);assert.equal(state.creates[0].app_metadata.kuilu_provisioned,true);
 const reset=await handler(request({action:'reset_password',user_id:target,password:'another-test-123'}));
 assert.equal(reset.status,200);assert.equal(state.resets[0].data.email_confirm,true);
 assert.equal((await handler(request({action:'reset_password',user_id:'bad',password:'another-test-123'}))).status,400);
 console.log('PASS: backend authentication, admin authorization, validation, duplicate handling, no-email provisioning and password reset.');
})().catch(e=>{console.error(e);process.exitCode=1});
