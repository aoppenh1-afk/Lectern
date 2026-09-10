import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { Store, hash, random } from '../../server/hosted/store.mjs';
import { createApp } from '../../server/hosted/app.mjs';
import { definitions, snapshotSchema } from '../../server/hosted/library.mjs';

const origin='https://lectern.example';
async function fixture(t) {
  const db=new PGlite();
  await db.exec(await readFile(new URL('../../server/hosted/schema.sql',import.meta.url),'utf8'));
  let lock=Promise.resolve();
  const pool={query:(...args)=>db.query(...args),connect:async()=>{
    const previous=lock; let release; lock=new Promise(resolve=>{release=resolve;}); await previous;
    return {query:(...args)=>db.query(...args),release};
  }};
  const store=new Store(pool);
  const app=createApp({store,config:{origin,googleClientID:'test',googleClientSecret:'test'},identityProvider:{
    authorization:state=>'https://accounts.example/authorize?state='+state,
    exchange:async(code)=>({sub:code,email:code+'@example.com'})
  }});
  t.after(()=>db.close());
  async function request(path,{method='GET',data,cookie,token,headers={}}={}) {
    return app(new Request(origin+path,{method,headers:{...data && {'Content-Type':'application/json'},...cookie && {Cookie:cookie},...token && {Authorization:'Bearer '+token},...headers},...data && {body:JSON.stringify(data)}}));
  }
  async function login(name) {
    const start=await request('/auth/google');
    const state=new URL(start.headers.get('location')).searchParams.get('state');
    const binding=start.headers.getSetCookie()[0].split(';')[0];
    const end=await request('/auth/callback?'+new URLSearchParams({state,code:name}),{cookie:binding});
    assert.equal(end.status,303);
    const cookie=end.headers.getSetCookie()[0].split(';')[0];
    const session=await store.session(cookie.split('=')[1]);
    return {cookie,session};
  }
  async function registerClient(redirect='https://client.example/callback') {
    const r=await request('/oauth/register',{method:'POST',data:{client_name:'Study AI',redirect_uris:[redirect],token_endpoint_auth_method:'none'}});
    assert.equal(r.status,201); return (await r.json()).client_id;
  }
  async function authorize(user,clientID,{scope,resource,redirect='https://client.example/callback',decision='allow'}={}) {
    const native=clientID==='lectern-macos';
    if(native) redirect='http://127.0.0.1:12345/';
    const verifier=random();
    const params=new URLSearchParams({client_id:clientID,redirect_uri:redirect,response_type:'code',scope:scope ?? (native?'library:sync':'library:read'),resource:resource ?? origin+(native?'/api/library':'/mcp'),code_challenge:hash(verifier),code_challenge_method:'S256',state:'client-state'});
    const response=await request('/oauth/authorize?'+params,{cookie:user.cookie});
    if(response.status!==200) return {response,params,verifier,redirect};
    const page=await response.text();
    const consent=page.match(/name="consent" value="([^"]+)"/)[1];
    const approval=await request('/oauth/consent',{method:'POST',cookie:user.cookie,headers:{Origin:origin},data:{csrf:user.session.csrf,consent,decision}});
    assert.equal(approval.status,303);
    const callback=new URL(approval.headers.get('location'));
    assert.equal(callback.searchParams.get('state'),'client-state');
    return {code:callback.searchParams.get('code'),error:callback.searchParams.get('error'),verifier,redirect,params};
  }
  async function token(clientID,authorization,overrides={}) {
    return request('/oauth/token',{method:'POST',data:{grant_type:'authorization_code',client_id:clientID,code:authorization.code,redirect_uri:authorization.redirect,code_verifier:authorization.verifier,...overrides}});
  }
  async function grant(user,clientID) {
    const response=await token(clientID,await authorize(user,clientID)); assert.equal(response.status,200); return response.json();
  }
  async function upload(token,snapshot,revision=0) {
    const begin=await request('/api/library/uploads',{method:'POST',token,data:{revision}});
    assert.equal(begin.status,200,await begin.clone().text());
    const {upload_id}=await begin.json(), bytes=Buffer.from(JSON.stringify(snapshot));
    // Split in the middle of UTF-8 sequences; the server assembles bytes before parsing.
    for(let offset=0;offset<bytes.length;offset+=73) {
      const chunk=bytes.subarray(offset,offset+73).toString('base64');
      const part=await request('/api/library/uploads/'+upload_id,{method:'PUT',token,data:{offset,chunk}});
      assert.equal(part.status,200,await part.clone().text());
    }
    return request('/api/library/uploads/'+upload_id+'/commit',{method:'POST',token,data:{}});
  }
  return {store,request,login,registerClient,authorize,token,grant,upload,app};
}
const library={courses:[{id:'c1',name:'Biology'},{id:'c2',name:'מחשבה'}],lectures:[
  {id:'l1',title:'Cells',courseID:'c1',capturedAt:'2026-09-10T00:00:00Z',documents:{notes:'Cell division\nSecond line\nThird line',raw_transcript:'The cell divides.'}},
  {id:'l2',title:'בחירה חופשית',courseID:'c2',capturedAt:'2026-09-09T00:00:00Z',documents:{notes:'בחירה חופשית'}}
]};

test('real MCP SDK connects through OAuth and navigates uploaded courses and documents',async t=>{
  const f=await fixture(t), user=await f.login('alice'), clientID=await f.registerClient();
  const sync=await f.grant(user,'lectern-macos');
  assert.equal((await f.upload(sync.access_token,library)).status,200);
  const read=await f.grant(user,clientID);
  const client=new Client({name:'integration-test',version:'1.0'});
  const transport=new StreamableHTTPClientTransport(new URL(origin+'/mcp'),{
    requestInit:{headers:{Authorization:'Bearer '+read.access_token}},
    fetch:async(url,init)=>f.app(new Request(url,init))
  });
  await client.connect(transport);
  const tools=await client.listTools(); assert.equal(tools.tools.length,5);
  assert.ok(tools.tools.every(t=>t.annotations.readOnlyHint));
  const courses=await client.callTool({name:'list_courses',arguments:{}});
  assert.equal(courses.structuredContent.total,2);
  const lectures=await client.callTool({name:'list_lectures',arguments:{course_id:'c1'}});
  assert.equal(lectures.structuredContent.lectures[0].id,'l1');
  const search=await client.callTool({name:'search',arguments:{query:'בחירה'}});
  assert.equal(search.structuredContent.results[0].id,'l2');
  const notes=await client.callTool({name:'read_document',arguments:{lecture_id:'l1',kind:'notes',limit:2}});
  assert.equal(notes.structuredContent.next_start_line,3);
  assert.ok(notes.structuredContent.synced_at);
  await client.close();
});

test('account isolation and separate read/sync audiences',async t=>{
  const f=await fixture(t), alice=await f.login('alice'), bob=await f.login('bob'), id=await f.registerClient();
  const sync=await f.grant(alice,'lectern-macos'), read=await f.grant(alice,id), bobRead=await f.grant(bob,id);
  assert.equal((await f.upload(sync.access_token,library)).status,200);
  assert.equal((await f.request('/api/library',{token:read.access_token})).status,401);
  assert.equal((await f.request('/mcp',{token:sync.access_token})).status,401);
  const result=await f.request('/mcp',{method:'POST',token:bobRead.access_token,headers:{Accept:'application/json, text/event-stream'},data:{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'list_courses',arguments:{}}}});
  assert.equal((await result.json()).result.structuredContent.total,0);
  const elevated=await f.authorize(alice,id,{scope:'library:sync'});
  assert.equal(elevated.response.status,400);
});

test('PKCE, exact redirects, audience and one-time authorization codes',async t=>{
  const f=await fixture(t), user=await f.login('alice'), id=await f.registerClient();
  let authorization=await f.authorize(user,id);
  assert.equal((await f.token(id,authorization,{code_verifier:random()})).status,400);
  authorization=await f.authorize(user,id);
  assert.equal((await f.token(id,authorization,{redirect_uri:'https://attacker.example/callback'})).status,400);
  authorization=await f.authorize(user,id);
  assert.equal((await f.token(id,authorization,{resource:origin+'/api/library'})).status,400);
  authorization=await f.authorize(user,id);
  assert.equal((await f.token(id,authorization)).status,200);
  assert.equal((await f.token(id,authorization)).status,400);
  assert.equal((await f.authorize(user,id,{redirect:'https://client.example/callback/changed'})).response.status,400);
  assert.equal((await f.authorize(user,id,{decision:'deny'})).error,'access_denied');
});

test('rotating refresh tokens revoke the grant when an old token is replayed',async t=>{
  const f=await fixture(t), user=await f.login('alice'), id=await f.registerClient(), tokens=await f.grant(user,id);
  const args={method:'POST',data:{grant_type:'refresh_token',client_id:id,refresh_token:tokens.refresh_token}};
  const refreshed=await f.request('/oauth/token',args); assert.equal(refreshed.status,200);
  const fresh=await refreshed.json();
  assert.notEqual(fresh.refresh_token,tokens.refresh_token);
  assert.equal((await f.request('/oauth/token',args)).status,400);
  assert.equal((await f.request('/mcp',{token:fresh.access_token})).status,401);
});

test('browser CSRF and Google state binding are enforced',async t=>{
  const f=await fixture(t), user=await f.login('alice');
  assert.equal((await f.request('/connect/erase',{method:'POST',cookie:user.cookie,data:{csrf:user.session.csrf}})).status,403);
  assert.equal((await f.request('/connect/erase',{method:'POST',cookie:user.cookie,headers:{Origin:origin},data:{csrf:'wrong'}})).status,403);
  assert.equal((await f.request('/auth/callback?state=wrong&code=alice')).status,400);
  const start=await f.request('/auth/google'); const state=new URL(start.headers.get('location')).searchParams.get('state');
  assert.equal((await f.request('/auth/callback?'+new URLSearchParams({state,code:'alice'}))).status,400);
  const evil=await f.request('/oauth/register',{method:'POST',data:{redirect_uris:['http://evil.example/callback']}});
  assert.equal(evil.status,400);
});

test('uploads are private, ordered and atomically replace the library; revisions prevent stale devices overwriting',async t=>{
  const f=await fixture(t), user=await f.login('alice'), bob=await f.login('bob');
  const sync=await f.grant(user,'lectern-macos'), other=await f.grant(bob,'lectern-macos');
  assert.equal((await f.upload(sync.access_token,library)).status,200);
  const start=await f.request('/api/library/uploads',{method:'POST',token:sync.access_token,data:{revision:1}});
  const {upload_id}=await start.json();
  const chunk=Buffer.from('{}').toString('base64');
  assert.equal((await f.request('/api/library/uploads/'+upload_id,{method:'PUT',token:other.access_token,data:{offset:0,chunk}})).status,409);
  assert.equal((await f.request('/api/library/uploads/'+upload_id,{method:'PUT',token:sync.access_token,data:{offset:2,chunk}})).status,409);
  assert.equal((await f.store.library(user.session.user_id)).snapshot.lectures.length,2);
  assert.equal((await f.upload(sync.access_token,{courses:[],lectures:[]},1)).status,200);
  assert.equal((await f.store.library(user.session.user_id)).snapshot.lectures.length,0);
  assert.equal((await f.request('/api/library/uploads',{method:'POST',token:sync.access_token,data:{revision:1}})).status,409);
});

test('deleting hosted data revokes all tokens, staged uploads and pending codes but keeps another account',async t=>{
  const f=await fixture(t), user=await f.login('alice'), bob=await f.login('bob'), id=await f.registerClient();
  const sync=await f.grant(user,'lectern-macos'), read=await f.grant(user,id), other=await f.grant(bob,'lectern-macos');
  await f.upload(sync.access_token,library); await f.upload(other.access_token,library);
  const pending=await f.authorize(user,id);
  assert.equal((await f.request('/api/library',{method:'DELETE',token:sync.access_token})).status,200);
  assert.equal((await f.request('/mcp',{token:read.access_token})).status,401);
  assert.equal((await f.token(id,pending)).status,400);
  assert.equal((await f.store.library(user.session.user_id)).snapshot.lectures.length,0);
  assert.equal((await f.store.library(bob.session.user_id)).snapshot.lectures.length,2);
});

test('tool bounds, missing documents, schema allowlist, and long Unicode pagination',()=>{
  assert.throws(()=>snapshotSchema.parse({...library,recordings:['private']}));
  assert.throws(()=>snapshotSchema.parse({...library,courses:[]}));
  for(const [name,,,call] of definitions) if(name==='get_lecture') assert.throws(()=>call(library,{lecture_id:'missing'}));
  const [,,schema,read]=definitions.find(([name])=>name==='read_document');
  assert.throws(()=>schema.parse({lecture_id:'l1',kind:'notes',limit:101}));
  const text='אב👨‍👩‍👧‍👦'.repeat(6000), lib={courses:library.courses,lectures:[{...library.lectures[0],documents:{notes:text}}]};
  let start=1, output='';
  do {
    const result=read(lib,{lecture_id:'l1',kind:'notes',start_line:start,limit:100});
    const chunk=result.lines.map(l=>l.text).join(''); assert.ok([...chunk].length<=24000);
    output+=chunk; start=result.next_start_line;
  } while(start);
  assert.equal(output,text);
});

test('discovery publishes read-only scopes and standard auth methods; consent names are escaped',async t=>{
  const f=await fixture(t);
  const metadata=await (await f.request('/.well-known/oauth-authorization-server')).json();
  assert.deepEqual(metadata.scopes_supported,['library:read']);
  assert.ok(metadata.token_endpoint_auth_methods_supported.includes('client_secret_basic'));
  const protectedResource=await (await f.request('/.well-known/oauth-protected-resource/mcp')).json();
  assert.equal(protectedResource.resource,origin+'/mcp');
  const unauthenticated=await f.request('/mcp');
  assert.equal(unauthenticated.status,401);
  assert.ok(unauthenticated.headers.get('www-authenticate').includes('resource_metadata'));
  const client=await (await f.request('/oauth/register',{method:'POST',data:{client_name:'<script>alert(1)</script>',redirect_uris:['https://client.example/callback'],token_endpoint_auth_method:'client_secret_basic'}})).json();
  const user=await f.login('alice'), code=await f.authorize(user,client.client_id);
  const tokens=await f.request('/oauth/token',{method:'POST',headers:{Authorization:'Basic '+Buffer.from(client.client_id+':'+client.client_secret).toString('base64')},data:{grant_type:'authorization_code',code:code.code,code_verifier:code.verifier,redirect_uri:code.redirect}});
  assert.equal(tokens.status,200);
  const page=await (await f.request('/connect',{cookie:user.cookie})).text();
  assert.ok(page.includes('&lt;script&gt;'));
  assert.ok(!page.includes('<script>alert'));
});

test('cleanup removes expired staging content and Google callback state cannot be replayed',async t=>{
  const f=await fixture(t);
  const start=await f.request('/auth/google'), state=new URL(start.headers.get('location')).searchParams.get('state');
  const cookie=start.headers.getSetCookie()[0].split(';')[0];
  const callback='/auth/callback?'+new URLSearchParams({state,code:'alice'});
  assert.equal((await f.request(callback,{cookie})).status,303);
  assert.equal((await f.request(callback,{cookie})).status,400);
  const user=await f.login('alice'), sync=await f.grant(user,'lectern-macos');
  await f.request('/api/library/uploads',{method:'POST',token:sync.access_token,data:{revision:0}});
  await f.store.query("UPDATE lectern_uploads SET expires_at=now()-interval '1 minute'");
  await f.store.cleanup();
  assert.equal((await f.store.query('SELECT * FROM lectern_uploads')).length,0);
  assert.equal((await f.request('/api/cleanup')).status,401);
});
