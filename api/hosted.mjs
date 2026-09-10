import pg from 'pg';
import { Store } from '../server/hosted/store.mjs';
import { createApp } from '../server/hosted/app.mjs';

// Keep IncomingMessage untouched so bounded body reads work consistently on Vercel.
export const config = { helpers: false };
let app;
export default async function handler(req,res) {
  const origin=process.env.LECTERN_ORIGIN ?? 'https://lectern-app.vercel.app';
  if (req.headers.host !== new URL(origin).host) { res.statusCode=400; res.end('Invalid host'); return; }
  const incoming=new URL(req.url,origin);
  const route=incoming.searchParams.get('__route');
  // Dispatch only the routes explicitly rewritten by vercel.json.
  const allowed=['mcp','connect','connect/revoke','connect/erase','auth/google','auth/callback','auth/logout','oauth/authorize','oauth/consent','oauth/token','oauth/register','oauth/revoke','.well-known/oauth-protected-resource','.well-known/oauth-protected-resource/mcp','.well-known/oauth-authorization-server','.well-known/oauth-authorization-server/mcp','api/library','api/cleanup'];
  if (!route || (!allowed.includes(route) && !/^api\/library\/uploads(?:\/[A-Za-z0-9_-]{43}(?:\/commit)?)?$/.test(route))) {
    res.statusCode=404; res.end(); return;
  }
  if (!process.env.DATABASE_URL || new URL(origin).protocol !== 'https:') {
    res.statusCode=503; res.setHeader('Cache-Control','no-store'); res.setHeader('Content-Type','application/json');
    res.end(JSON.stringify({error:'not_configured',error_description:'The hosted Lectern service is not configured yet.'})); return;
  }
  if (!app) {
    const pool=new pg.Pool({connectionString:process.env.DATABASE_URL,max:3,connectionTimeoutMillis:10000,idleTimeoutMillis:10000});
    pool.on('error',()=>{}); // Never log connection strings or database parameters.
    app=createApp({store:new Store(pool),config:{origin,googleClientID:process.env.GOOGLE_CLIENT_ID,googleClientSecret:process.env.GOOGLE_CLIENT_SECRET,cronSecret:process.env.CRON_SECRET}});
  }
  incoming.searchParams.delete('__route');
  const url=new URL('/'+route,origin); url.search=incoming.search;
  let length=0; const chunks=[];
  try {
    for await (const chunk of req) {
      length+=chunk.length;
      if (length>750000) { res.statusCode=413; res.end(); return; }
      chunks.push(chunk);
    }
    const headers=new Headers();
    for (const [key,value] of Object.entries(req.headers)) {
      if (value !== undefined) headers.set(key,Array.isArray(value) ? value.join(', ') : value);
    }
    const request=new Request(url,{method:req.method,headers,...(!['GET','HEAD'].includes(req.method) ? {body:Buffer.concat(chunks)} : {})});
    const response=await app(request);
    res.statusCode=response.status;
    for (const [key,value] of response.headers) if (key !== 'set-cookie') res.setHeader(key,value);
    const cookies=response.headers.getSetCookie();
    if (cookies.length) res.setHeader('Set-Cookie',cookies);
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch {
    res.statusCode=503; res.setHeader('Cache-Control','no-store'); res.end('Service unavailable');
  }
}
