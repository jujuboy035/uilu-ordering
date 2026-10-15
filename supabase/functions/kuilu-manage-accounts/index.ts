import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const allowedOrigins=new Set(["https://kuilu-ordering.wavypond9.chatgpt.site"]);
const roles=new Set(["customer","china","admin","driver"]);
const usernamePattern=/^[a-z0-9][a-z0-9._-]{2,31}$/;
function createHandler(admin) {
 return async(req)=>{
  const origin=req.headers.get("origin");
  const headers={"Content-Type":"application/json","Cache-Control":"no-store","Vary":"Origin",
   "Access-Control-Allow-Origin":origin&&allowedOrigins.has(origin)?origin:"https://kuilu-ordering.wavypond9.chatgpt.site",
   "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info",
   "Access-Control-Allow-Methods":"POST, OPTIONS"};
  const respond=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
  if(origin&&!allowedOrigins.has(origin))return respond({error:"访问来源无效"},403);
  if(req.method==="OPTIONS")return new Response(null,{status:204,headers});
  if(req.method!=="POST")return respond({error:"请求方式无效"},405);
  const match=req.headers.get("authorization")?.match(/^Bearer (\S+)$/i);
  if(!match)return respond({error:"请先登录"},401);
  try {
   const identity=await admin.auth.getUser(match[1]);
   if(identity.error||!identity.data.user)return respond({error:"登录已失效，请重新登录"},401);
   const actor=identity.data.user;
   const profile=await admin.from("kuilu_profiles").select("role").eq("id",actor.id).maybeSingle();
   if(profile.error)return respond({error:"暂时无法核对权限"},503);
   if(profile.data?.role!=="admin")return respond({error:"仅管理员可管理账号"},403);
   const reader=req.body?.getReader();let bytes=0,text="";
   if(!reader)return respond({error:"请求内容无效"},400);
   const decoder=new TextDecoder();
   while(true){const chunk=await reader.read();if(chunk.done)break;bytes+=chunk.value.byteLength;if(bytes>8192){await reader.cancel();return respond({error:"请求内容过大"},413)}text+=decoder.decode(chunk.value,{stream:true})}
   text+=decoder.decode();
   let body;try{body=JSON.parse(text)}catch{return respond({error:"请求内容无效"},400)}
   if(!body||typeof body!=="object"||Array.isArray(body))return respond({error:"请求内容无效"},400);
   const password=body.password;
   if(typeof password!=="string"||password.length<8||new TextEncoder().encode(password).length>72)return respond({error:"密码须为8至72字节"},400);
   if(body.action==="create"){
    const username=typeof body.username==="string"?body.username.trim().toLowerCase():"";
    if(!usernamePattern.test(username)||!roles.has(body.role))return respond({error:"账号或角色格式无效"},400);
    const existing=await admin.from("kuilu_profiles").select("id").eq("username",username).maybeSingle();
    if(existing.error)return respond({error:"暂时无法检查账号"},503);
    if(existing.data)return respond({error:"账号已存在"},409);
    const result=await admin.auth.admin.createUser({
     email:username+"@accounts.kuilu.invalid",password,email_confirm:true,
     app_metadata:{kuilu_provisioned:true,kuilu_username:username,kuilu_role:body.role,kuilu_created_by:actor.id}
    });
    if(result.error||!result.data.user)return respond({error:"创建失败，请检查账号是否重复及密码要求"},400);
    return respond({id:result.data.user.id,username,role:body.role},201);
   }
   if(body.action==="reset_password"){
    if(typeof body.user_id!=="string"||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.user_id))return respond({error:"账号编号无效"},400);
    const target=await admin.auth.admin.getUserById(body.user_id);
    if(target.error||!target.data.user)return respond({error:"账号不存在"},404);
    const result=await admin.auth.admin.updateUserById(body.user_id,{password,email_confirm:true});
    if(result.error)return respond({error:"密码重设失败，请检查密码要求"},400);
    return respond({id:body.user_id,updated:true});
   }
   return respond({error:"账号操作无效"},400);
  }catch{return respond({error:"账号服务暂时不可用"},500)}
 };
}
const admin=createClient(Deno.env.get("SUPABASE_URL"),Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false,autoRefreshToken:false}});
Deno.serve(createHandler(admin));
