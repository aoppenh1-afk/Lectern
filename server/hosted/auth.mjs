import { createRemoteJWKSet, jwtVerify } from 'jose';
import { z } from 'zod';
import { random, hash, equal } from './store.mjs';

export const nativeID = 'lectern-macos';
export const sessionCookie = '__Host-lectern-session';
export const googleCookie = '__Host-lectern-google';
export class HttpError extends Error {
  constructor(status, code, message = code) { super(message); this.status = status; this.code = code; }
}
export function check(condition, code = 'invalid_request', message = code, status = 400) {
  if (!condition) throw new HttpError(status, code, message);
}
export function cookies(request) {
  return Object.fromEntries((request.headers.get('cookie') ?? '').split(';').map(pair => pair.trim().split('=')));
}
export const cookie = (name, value, seconds) => `${name}=${value}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${seconds}`;
export const escape = text => String(text).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
export const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type':'application/json', ...headers } });
export const redirect = (url, headers = {}) => new Response(null, { status: 303, headers: { Location:url, ...headers } });
export function html(title, body, status = 200) {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escape(title)} · Lectern</title><link rel="stylesheet" href="/assets/connect.css"></head><body><main><a class="brand" href="/">Lectern</a><h1>${escape(title)}</h1>${body}<footer><a href="/privacy.html">Privacy</a> · <a href="/terms.html">Terms</a></footer></main></body></html>`, { status, headers: { 'Content-Type':'text/html; charset=utf-8' } });
}
export const hidden = (name,value) => `<input type="hidden" name="${escape(name)}" value="${escape(value)}">`;
export function sameOrigin(request, origin) { check(request.headers.get('origin') === origin, 'invalid_origin', 'Please submit this form from the Lectern site.', 403); }
export async function body(request, max = 750000) {
  const reader = request.body?.getReader();
  let length = 0; const chunks = [];
  if (reader) {
    while (true) {
      const { done,value } = await reader.read(); if (done) break;
      length += value.length;
      if (length > max) { await reader.cancel(); throw new HttpError(413,'payload_too_large'); }
      chunks.push(Buffer.from(value));
    }
  }
  const text = Buffer.concat(chunks).toString('utf8');
  if ((request.headers.get('content-type') ?? '').startsWith('application/json')) {
    try { const parsed = JSON.parse(text); check(parsed && typeof parsed === 'object' && !Array.isArray(parsed)); return parsed; } catch { throw new HttpError(400,'invalid_json'); }
  }
  check((request.headers.get('content-type') ?? '').startsWith('application/x-www-form-urlencoded'), 'unsupported_media_type', 'Use JSON or form encoding.', 415);
  const params = new URLSearchParams(text);
  check(new Set(params.keys()).size === [...params.keys()].length);
  return Object.fromEntries(params);
}

const redirects = z.array(z.string().url().max(2048).refine(value => {
  const url = new URL(value);
  return url.protocol === 'https:' && !url.username && !url.password && !url.hash;
})).min(1).max(10);
export async function register(store, data) {
  const input = z.object({
    client_name: z.string().trim().min(1).max(100).default('AI connector'), redirect_uris: redirects,
    token_endpoint_auth_method: z.enum(['none','client_secret_post','client_secret_basic']).default('none'),
    grant_types: z.array(z.enum(['authorization_code','refresh_token'])).default(['authorization_code','refresh_token']),
    response_types: z.array(z.literal('code')).default(['code'])
  }).parse(data);
  const id = random(), secret = input.token_endpoint_auth_method === 'none' ? null : random();
  await store.query('INSERT INTO lectern_clients (id,name,redirects,auth_method,secret_hash) VALUES ($1,$2,$3,$4,$5)',
    [id,input.client_name,JSON.stringify(input.redirect_uris),input.token_endpoint_auth_method,secret ? hash(secret) : null]);
  return { ...input, client_id:id, client_id_issued_at:Math.floor(Date.now()/1000), ...(secret ? { client_secret:secret, client_secret_expires_at:0 } : {}) };
}
export async function getClient(store, id) {
  if (id === nativeID) return { id:nativeID, name:'Lectern for Mac', auth_method:'none' };
  return store.client(id);
}
export async function validateAuthorization(store, params, origin) {
  check(new Set(params.keys()).size === [...params.keys()].length);
  const clientID = params.get('client_id'), redirectURI = params.get('redirect_uri');
  check(clientID && redirectURI);
  const client = await getClient(store,clientID);
  check(client, 'invalid_client');
  const scope = clientID === nativeID ? 'library:sync' : 'library:read';
  const resource = origin + (clientID === nativeID ? '/api/library' : '/mcp');
  let validRedirect = false;
  if (clientID === nativeID) {
    try {
      const url = new URL(redirectURI);
      validRedirect = url.protocol === 'http:' && ['127.0.0.1','[::1]'].includes(url.hostname) && !!url.port && !url.username && !url.password && !url.hash;
    } catch { /* Reject invalid native callbacks. */ }
  } else validRedirect = client.redirects.includes(redirectURI);
  check(validRedirect, 'invalid_redirect_uri');
  check(params.get('response_type') === 'code', 'unsupported_response_type');
  check(params.get('scope') === scope, 'invalid_scope');
  check(params.get('resource') === resource, 'invalid_target');
  check(params.get('code_challenge_method') === 'S256' && /^[A-Za-z0-9_-]{43}$/.test(params.get('code_challenge') ?? ''), 'invalid_request', 'S256 PKCE is required.');
  const state = params.get('state') ?? '';
  check(state.length <= 2048);
  return { client, clientID, redirect:redirectURI, scope, resource, challenge:params.get('code_challenge'), state };
}
export async function authenticateClient(store, request, data) {
  let clientID = data.client_id, secret = data.client_secret, method = secret ? 'client_secret_post' : 'none';
  const header = request.headers.get('authorization');
  if (header) {
    check(header.startsWith('Basic '), 'invalid_client');
    let raw;
    try { raw = Buffer.from(header.slice(6),'base64').toString(); } catch { throw new HttpError(401,'invalid_client'); }
    const colon = raw.indexOf(':'); check(colon > 0, 'invalid_client');
    const decodedID = decodeURIComponent(raw.slice(0,colon));
    check(!clientID || clientID === decodedID, 'invalid_client');
    clientID = decodedID; secret = decodeURIComponent(raw.slice(colon+1)); method = 'client_secret_basic';
  }
  const client = await getClient(store,clientID);
  check(client && client.auth_method === method && (method === 'none' || equal(client.secret_hash,hash(secret))), 'invalid_client', 'Client authentication failed.', 401);
  return client.id;
}

const googleKeys = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));
export function googleProvider(config) {
  return {
    authorization(state, nonce, verifier) {
      return 'https://accounts.google.com/o/oauth2/v2/auth?' + new URLSearchParams({
        client_id:config.googleClientID, redirect_uri:config.origin+'/auth/callback', response_type:'code', scope:'openid email',
        state, nonce, code_challenge:hash(verifier), code_challenge_method:'S256', prompt:'select_account'
      });
    },
    async exchange(code, pending) {
      const response = await fetch('https://oauth2.googleapis.com/token', { method:'POST', signal:AbortSignal.timeout(15000),
        headers:{ 'Content-Type':'application/x-www-form-urlencoded' }, body:new URLSearchParams({
          client_id:config.googleClientID, client_secret:config.googleClientSecret, redirect_uri:config.origin+'/auth/callback',
          grant_type:'authorization_code', code, code_verifier:pending.verifier
        })
      });
      check(response.ok,'login_failed','Google sign-in failed. Please try again.',401);
      const tokens = await response.json();
      const { payload } = await jwtVerify(tokens.id_token, googleKeys, { audience:config.googleClientID, issuer:['https://accounts.google.com','accounts.google.com'], algorithms:['RS256'] });
      check(payload.nonce === pending.nonce && payload.email_verified === true && typeof payload.sub === 'string' && typeof payload.email === 'string', 'login_failed');
      return { sub:payload.sub, email:payload.email };
    }
  };
}
