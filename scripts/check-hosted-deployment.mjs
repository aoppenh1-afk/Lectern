// Public, read-only smoke check. Never sends lectures or credentials.
import assert from 'node:assert/strict';
const origin=process.env.LECTERN_ORIGIN ?? 'https://lectern-app.vercel.app';
const get=path=>fetch(origin+path,{redirect:'error',signal:AbortSignal.timeout(15000)});
try {
  const resource=await get('/.well-known/oauth-protected-resource/mcp');
  assert.equal(resource.status,200,'Resource metadata must be public JSON.');
  assert.equal((await resource.json()).resource,origin+'/mcp');
  const discovery=await get('/.well-known/oauth-authorization-server');
  assert.equal(discovery.status,200);
  const metadata=await discovery.json();
  assert.equal(metadata.issuer,origin);
  assert.ok(metadata.code_challenge_methods_supported.includes('S256'));
  const mcp=await get('/mcp');
  assert.equal(mcp.status,401,'Unauthenticated MCP must not expose data.');
  assert.ok(mcp.headers.get('www-authenticate')?.includes('resource_metadata'));
  const page=await get('/connect');
  assert.equal(page.status,200,'Connect page must load.');
  console.log('Public discovery, connect page and authentication boundary passed. Real Google, Mac, ChatGPT and Claude sign-in still need account testing.');
} catch (error) {
  console.error('Hosted deployment check failed:',error.message);
  process.exitCode=1;
}
