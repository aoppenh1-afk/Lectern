import { ZodError } from 'zod';
import { random, hash, equal, expires } from './store.mjs';
import { serveMCP, snapshotSchema } from './library.mjs';
import { HttpError, check, cookies, cookie, sessionCookie, googleCookie, escape, json, redirect, html, hidden, sameOrigin, body, register, validateAuthorization, authenticateClient, googleProvider } from './auth.mjs';

export function createApp({ store, config, identityProvider = googleProvider(config) }) {
  const origin = config.origin;
  const resource = origin+'/mcp';
  const security = {
    'Cache-Control':'no-store', 'Referrer-Policy':'no-referrer', 'X-Content-Type-Options':'nosniff',
    'Content-Security-Policy':"default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
  };
  async function signedIn(request) { return store.session(cookies(request)[sessionCookie]); }
  async function formSession(request, data) {
    sameOrigin(request,origin);
    const session = await signedIn(request);
    check(session && equal(session.csrf,data.csrf),'invalid_session','Your session expired. Sign in again.',403);
    return session;
  }
  async function requireAccess(request, scope, audience) {
    const token = request.headers.get('authorization')?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1];
    const grant = await store.access(token,scope,audience);
    check(grant,'invalid_token','Connect to Lectern to access your shared library.',401);
    check(await store.limit('user:'+grant.user_id,180),'rate_limited','Too many requests. Try again in a minute.',429);
    return grant;
  }
  async function route(request, path, url) {
    if (path === '/api/cleanup' && request.method === 'GET') {
      check(config.cronSecret && equal(request.headers.get('authorization'), 'Bearer '+config.cronSecret), 'invalid_token', 'Unauthorized.', 401);
      await store.cleanup();
      return json({ cleaned: true });
    }
    if (request.method === 'GET' && path.startsWith('/.well-known/')) {
      if (['/.well-known/oauth-protected-resource','/.well-known/oauth-protected-resource/mcp'].includes(path)) {
        return json({ resource, authorization_servers:[origin], scopes_supported:['library:read'], bearer_methods_supported:['header'], resource_name:'Lectern courses and lectures' });
      }
      if (['/.well-known/oauth-authorization-server','/.well-known/oauth-authorization-server/mcp'].includes(path)) {
        return json({ issuer:origin, authorization_endpoint:origin+'/oauth/authorize', token_endpoint:origin+'/oauth/token', registration_endpoint:origin+'/oauth/register', revocation_endpoint:origin+'/oauth/revoke', response_types_supported:['code'], grant_types_supported:['authorization_code','refresh_token'], token_endpoint_auth_methods_supported:['none','client_secret_post','client_secret_basic'], code_challenge_methods_supported:['S256'], scopes_supported:['library:read'] });
      }
      return json({ error:'not_found' },404);
    }
    if (path === '/oauth/register' && request.method === 'POST') {
      // Vercel overwrites this header; local tests use a fixed fallback, not caller-supplied X-Forwarded-For.
      const ip = request.headers.get('x-vercel-forwarded-for') ?? 'local';
      check(await store.limit('register:'+hash(ip),20,3600),'rate_limited','Try again later.',429);
      return json(await register(store,await body(request,16000)),201);
    }
    if (path === '/auth/google' && request.method === 'GET') {
      check(config.googleClientID && config.googleClientSecret,'not_configured','Hosted sign-in is not configured yet.',503);
      const ip = request.headers.get('x-vercel-forwarded-for') ?? 'local';
      check(await store.limit('login:'+hash(ip),20,600),'rate_limited','Try again later.',429);
      const next = url.searchParams.get('next') ?? '/connect';
      check(next === '/connect' || (next.startsWith('/oauth/authorize?') && next.length <= 6000));
      if (next !== '/connect') await validateAuthorization(store,new URL(next,origin).searchParams,origin);
      const nonce=random(), verifier=random(), binding=random();
      const state = await store.putPending('google',{ next,nonce,verifier,binding:hash(binding) });
      return redirect(identityProvider.authorization(state,nonce,verifier),{'Set-Cookie':cookie(googleCookie,binding,600)});
    }
    if (path === '/auth/callback' && request.method === 'GET') {
      const state=url.searchParams.get('state') ?? '', binding=cookies(request)[googleCookie] ?? '';
      const pending=await store.pending(state,'google');
      check(pending && equal(pending.binding,hash(binding)),'invalid_state','Sign-in expired. Start again.',400);
      check(await store.consumePending(state,'google'),'invalid_state');
      const code=url.searchParams.get('code');
      check(code && !url.searchParams.has('error'),'login_cancelled','Sign-in was cancelled. Return to Lectern and try again.');
      const user=await store.user(await identityProvider.exchange(code,pending));
      const token=await store.newSession(user.id);
      const response=redirect(pending.next);
      response.headers.append('Set-Cookie',cookie(sessionCookie,token,86400*7));
      response.headers.append('Set-Cookie',cookie(googleCookie,'',0));
      return response;
    }
    if (path === '/oauth/authorize' && request.method === 'GET') {
      const authorization=await validateAuthorization(store,url.searchParams,origin);
      const session=await signedIn(request);
      if (!session) return redirect('/auth/google?'+new URLSearchParams({next:path+url.search}));
      const consent=await store.putPending('consent',{ ...authorization,userID:session.user_id,sessionHash:session.hash });
      const sync=authorization.scope === 'library:sync';
      const page = html('Connect '+authorization.client.name, `<p>Signed in as <strong>${escape(session.email)}</strong>.</p><p>${sync ? 'Allow this Mac to upload and replace your selected courses, lecture notes and transcripts in your Lectern account.' : 'Allow this app to browse and read the courses, lecture notes and transcripts you have shared with Lectern. It cannot edit your library.'}</p><p class="notice">Return address: <code>${escape(new URL(authorization.redirect).origin)}</code><br>Only approve if you started this connection. The app name is provided by the requesting app.</p><form method="post" action="/oauth/consent">${hidden('csrf',session.csrf)}${hidden('consent',consent)}<div class="actions"><button name="decision" value="allow">Allow access</button><button class="secondary" name="decision" value="deny">Cancel</button></div></form>`);
      page.headers.set('Content-Security-Policy', security['Content-Security-Policy'].replace("form-action 'self'", "form-action 'self' " + new URL(authorization.redirect).origin));
      return page;
    }
    if (path === '/oauth/consent' && request.method === 'POST') {
      const data=await body(request,16000), session=await formSession(request,data);
      const pending=await store.pending(data.consent ?? '','consent');
      check(pending && pending.userID === session.user_id && pending.sessionHash === session.hash,'invalid_consent');
      const code = await store.transaction(async tx => {
        await tx.query('SELECT id FROM lectern_users WHERE id=$1 FOR UPDATE',[session.user_id]);
        check(await tx.consumePending(data.consent,'consent'),'invalid_consent');
        return data.decision === 'allow' ? tx.putPending('code',pending,120) : null;
      });
      const destination=new URL(pending.redirect);
      if (code) destination.searchParams.set('code',code); else destination.searchParams.set('error','access_denied');
      if (pending.state) destination.searchParams.set('state',pending.state);
      destination.searchParams.set('iss',origin);
      return redirect(destination.toString());
    }
    if (['/oauth/token','/oauth/revoke'].includes(path) && request.method === 'POST') {
      const ip = request.headers.get('x-vercel-forwarded-for') ?? 'local';
      check(await store.limit('token:'+hash(ip),120),'rate_limited','Try again in a minute.',429);
      const data=await body(request,16000);
      const clientID=await authenticateClient(store,request,data);
      if (path === '/oauth/revoke') {
        check(typeof data.token === 'string' && data.token.length <= 200);
        await store.revokeToken(data.token,clientID); return json({});
      }
      let tokens;
      if (data.grant_type === 'authorization_code') {
        check(typeof data.code === 'string' && data.code.length<=200 && /^[A-Za-z0-9._~-]{43,128}$/.test(data.code_verifier ?? ''));
        tokens=await store.redeemCode(data.code,clientID,data.redirect_uri,data.code_verifier,data.resource);
      } else if (data.grant_type === 'refresh_token') {
        check(typeof data.refresh_token === 'string' && data.refresh_token.length<=200);
        tokens=await store.refresh(data.refresh_token,clientID,data.resource);
      } else throw new HttpError(400,'unsupported_grant_type');
      check(tokens,'invalid_grant','Authorization expired or was revoked. Connect again.');
      return json(tokens);
    }
    if (path === '/connect' && request.method === 'GET') {
      const session=await signedIn(request);
      if (!session) return html('Your lectures, in your AI chat', `<p>Share selected courses from Lectern for Mac, then read them from ChatGPT or Claude—even when your Mac is closed.</p><p>Your selected notes and transcripts will be stored in your hosted Lectern account. Audio and other study materials stay on your Mac.</p><a class="button" href="/auth/google">Sign in with Google</a>`);
      const saved=await store.library(session.user_id);
      const grants=await store.query(`SELECT g.id,g.scope,g.created_at,c.name FROM lectern_grants g LEFT JOIN lectern_clients c ON c.id=g.client_id WHERE g.user_id=$1 AND NOT g.revoked ORDER BY g.created_at DESC`,[session.user_id]);
      return html('Your AI connections', `<p>Signed in as <strong>${escape(session.email)}</strong>.</p><p>${saved.snapshot.courses.length} shared courses · ${saved.snapshot.lectures.length} lectures.<br>Last synced: ${saved.updated_at ? escape(new Date(saved.updated_at).toISOString()) : 'Not yet synced'}.</p><h2>1. Share from Lectern</h2><p>In Lectern for Mac, open Settings → ChatGPT &amp; Claude. Sign in with this same Google account, choose courses, then select Start sharing.</p><h2>2. Connect your AI</h2><p>Use this server URL in either app:</p><pre>${escape(resource)}</pre><p><strong>ChatGPT:</strong> enable developer mode, create an MCP connection and select OAuth authentication. <strong>Claude:</strong> add a custom connector. Sign in to this same Lectern account and approve read access. Enable Lectern in the conversation.</p><p class="muted">Connector availability depends on your AI account and workspace settings.</p><h2>Connected apps</h2>${grants.length ? grants.map(g=>`<form method="post" action="/connect/revoke">${hidden('csrf',session.csrf)}${hidden('grant',g.id)}<p><strong>${escape(g.name ?? 'Lectern for Mac')}</strong> · ${g.scope === 'library:read' ? 'Read shared lectures' : 'Upload library'}</p><button class="secondary">Disconnect</button></form>`).join('') : '<p>No connected apps.</p>'}<h2>Remove shared data</h2><p>Delete the hosted notes and transcripts and disconnect all apps. Your Mac’s original library is kept. Content already retrieved by an AI service may remain with that service.</p><form method="post" action="/connect/erase">${hidden('csrf',session.csrf)}<button class="danger">Delete hosted library and disconnect all apps</button></form><form method="post" action="/auth/logout">${hidden('csrf',session.csrf)}<button class="secondary">Sign out of this browser</button></form>`);
    }
    if (['/connect/revoke','/connect/erase','/auth/logout'].includes(path) && request.method === 'POST') {
      const data=await body(request,16000), session=await formSession(request,data);
      if (path === '/connect/erase') await store.erase(session.user_id);
      else if (path === '/connect/revoke') await store.query('UPDATE lectern_grants SET revoked=true WHERE id=$1 AND user_id=$2',[data.grant,session.user_id]);
      else { await store.query('DELETE FROM lectern_sessions WHERE hash=$1',[session.hash]); return redirect('/connect',{'Set-Cookie':cookie(sessionCookie,'',0)}); }
      return redirect('/connect');
    }
    if (path === '/mcp') {
      const grant=await requireAccess(request,'library:read',resource);
      if (request.method !== 'POST') return new Response(null,{status:405,headers:{Allow:'POST'}});
      // Parse a bounded body before giving it to the SDK.
      const data=await body(request,65536);
      const copied=new Request(resource,{method:'POST',headers:request.headers,body:JSON.stringify(data)});
      return serveMCP(copied, async () => {
        const token=request.headers.get('authorization').slice(7);
        check(await store.access(token,'library:read',resource),'revoked','Connection revoked. Reconnect to Lectern.',401);
        return store.library(grant.user_id);
      });
    }
    if (path === '/api/library' || path.startsWith('/api/library/')) {
      const grant=await requireAccess(request,'library:sync',origin+'/api/library');
      if (path === '/api/library' && request.method === 'GET') {
        const saved=await store.library(grant.user_id);
        const [user]=await store.query('SELECT email FROM lectern_users WHERE id=$1',[grant.user_id]);
        return json({ revision:saved.revision, updated_at:saved.updated_at, email:user.email, user_id:grant.user_id, lecture_count:saved.snapshot.lectures.length });
      }
      if (path === '/api/library' && request.method === 'DELETE') { await store.erase(grant.user_id); return json({deleted:true}); }
      if (path === '/api/library/uploads' && request.method === 'POST') {
        const data=await body(request,16000);
        check(Number.isInteger(data.revision) && data.revision>=0);
        const id=random();
        await store.transaction(async tx => {
          await tx.query('SELECT id FROM lectern_users WHERE id=$1 FOR UPDATE',[grant.user_id]);
          check((await tx.query('SELECT id FROM lectern_grants WHERE id=$1 AND NOT revoked FOR UPDATE',[grant.id])).length, 'invalid_token', 'Connection revoked.', 401);
          check((await tx.library(grant.user_id)).revision === data.revision,'revision_conflict','Another device changed your shared library. Review and sync again.',409);
          await tx.query('DELETE FROM lectern_uploads WHERE user_id=$1 AND (grant_id=$2 OR expires_at<now())',[grant.user_id,grant.id]);
          const [row]=await tx.query('SELECT count(*) AS count FROM lectern_uploads WHERE user_id=$1',[grant.user_id]);
          check(Number(row.count)<5,'too_many_uploads','Try again later.',429);
          await tx.query('INSERT INTO lectern_uploads (id,user_id,grant_id,revision,expires_at) VALUES ($1,$2,$3,$4,$5)',[id,grant.user_id,grant.id,data.revision,expires(1800)]);
        });
        return json({upload_id:id});
      }
      const match=path.match(/^\/api\/library\/uploads\/([A-Za-z0-9_-]{43})(\/commit)?$/);
      if (match) {
        const id=match[1];
        if (request.method === 'PUT' && !match[2]) {
          const data=await body(request);
          check(Number.isInteger(data.offset) && data.offset>=0 && typeof data.chunk === 'string' && data.chunk.length>0 && data.chunk.length<=700000 && /^[A-Za-z0-9+/]*={0,2}$/.test(data.chunk));
          const chunk=Buffer.from(data.chunk,'base64');
          check(chunk.length>0 && chunk.toString('base64') === data.chunk);
          const [updated]=await store.query(`UPDATE lectern_uploads SET content=content || $1::bytea
            WHERE id=$2 AND user_id=$3 AND grant_id=$4 AND expires_at>now() AND octet_length(content)=$5 AND octet_length(content)+$6<=33554432 RETURNING octet_length(content) AS offset`,[chunk,id,grant.user_id,grant.id,data.offset,chunk.length]);
          check(updated,'upload_conflict','Upload expired, exceeded 32 MiB, or chunks arrived out of order. Retry syncing.',409);
          return json(updated);
        }
        if (request.method === 'POST' && match[2]) {
          const [upload]=await store.query('SELECT * FROM lectern_uploads WHERE id=$1 AND user_id=$2 AND grant_id=$3 AND expires_at>now()',[id,grant.user_id,grant.id]);
          check(upload,'upload_expired');
          let snapshot;
          try { snapshot=snapshotSchema.parse(JSON.parse(Buffer.from(upload.content).toString('utf8'))); }
          catch { throw new HttpError(400,'invalid_library','Invalid library data. Update Lectern and try again.'); }
          const saved=await store.replaceLibrary(grant,snapshot,upload.revision);
          check(!saved.error,saved.error === 'revoked' ? 'invalid_token' : 'revision_conflict','Connection revoked or library changed. Review and reconnect.',saved.error === 'revoked' ? 401 : 409);
          await store.query('DELETE FROM lectern_uploads WHERE id=$1 AND user_id=$2',[id,grant.user_id]);
          return json(saved);
        }
      }
      return json({error:'method_not_allowed'},405);
    }
    return json({error:'not_found'},404);
  }
  return async request => {
    let response;
    try {
      const url=new URL(request.url);
      check(url.origin === origin,'invalid_host','Invalid host.',400);
      const incoming=request.headers.get('origin');
      check(!incoming || incoming === origin,'invalid_origin','Invalid origin.',403);
      response=await route(request,url.pathname,url);
    } catch (error) {
      const known=error instanceof HttpError || error instanceof ZodError;
      const status=error instanceof HttpError ? error.status : error instanceof ZodError ? 400 : 503;
      response=json({error:error.code ?? (known ? 'invalid_request' : 'service_unavailable'), error_description:known ? (error instanceof ZodError ? 'Invalid request fields.' : error.message) : 'Lectern’s hosted connection is temporarily unavailable. Try again later.'},status);
      if (status === 401) response.headers.set('WWW-Authenticate',`Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`);
      if (status === 429) response.headers.set('Retry-After','60');
      // No raw exceptions: database errors can include SQL parameters or credentials.
    }
    for (const [key,value] of Object.entries(security)) if (!response.headers.has(key)) response.headers.set(key,value);
    return response;
  };
}
