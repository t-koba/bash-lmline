#!/usr/bin/env node
'use strict';

// OpenAI "Sign in with ChatGPT" (SIWC) subscription authentication client.
// Node built-ins only, no npm dependencies. Implements the documented token
// sharing flow: OAuth 2.0 authorization code with PKCE, dynamic client
// registration, refresh, reauthorization and revocation.

const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { URL, URLSearchParams } = require('url');

const configDir = process.env.LMLINE_CONFIG_DIR || path.join(os.homedir(), '.config', 'lmline');
const credentialsFile = process.env.LMLINE_CHATGPT_CREDENTIALS_FILE || path.join(configDir, 'chatgpt', 'credentials.json');
const hostIdFile = process.env.LMLINE_CHATGPT_HOST_ID_FILE || path.join(configDir, 'chatgpt', 'host-id');
const authUrl = trimSlash(process.env.LMLINE_CHATGPT_AUTH_URL || 'https://auth.openai.com');
const apiUrl = trimSlash(process.env.LMLINE_CHATGPT_API_URL || 'https://api.openai.com/v1');
const agentName = process.env.LMLINE_CHATGPT_AGENT_NAME || 'lmline';
const callbackPort = positiveInt(process.env.LMLINE_CHATGPT_CALLBACK_PORT, 1455);
const timeoutSeconds = positiveInt(process.env.LMLINE_CHATGPT_TIMEOUT, 300);
const browserCommand = process.env.LMLINE_CHATGPT_BROWSER_COMMAND || '';
const noBrowser = process.env.LMLINE_CHATGPT_NO_BROWSER === '1';

const DEFAULT_ENDPOINTS = {
  issuer: 'https://auth.openai.com',
  authorization_endpoint: 'https://auth.openai.com/api/accounts/authorize',
  token_endpoint: 'https://auth.openai.com/api/accounts/oauth/token',
  revocation_endpoint: 'https://auth.openai.com/api/accounts/oauth/revoke',
  jwks_uri: 'https://auth.openai.com/.well-known/jwks.json'
};
const REQUESTED_SCOPE = 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';
const PLAN_SCOPE = 'chatgpt.tokens.use.direct';
const DYNAMIC_CLIENT_ID = 'dynamic_agent_client';
const CALLBACK_PATH = '/auth/callback';
const REFRESH_MARGIN = 60;
const REVOCATION_ATTEMPTS = 3;

function trimSlash(value) {
  return String(value || '').replace(/\/+$/, '');
}

function positiveInt(value, fallback) {
  return /^\d+$/.test(value || '') && Number(value) > 0 ? Number(value) : fallback;
}

function fail(message, code = 1) {
  process.stderr.write(`lmline-chatgpt: ${message}\n`);
  process.exit(code);
}

function note(message) {
  process.stderr.write(`lmline-chatgpt: ${message}\n`);
}

// Synchronous stdout writes keep the key=value lines ordered and complete
// even when the process exits right after a failure.
function out(line) {
  try { fs.writeSync(1, `${line}\n`); }
  catch (_) { process.stdout.write(`${line}\n`); }
}

function base64url(buffer) {
  return Buffer.from(buffer).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomToken() {
  return base64url(crypto.randomBytes(32));
}

function uuid() {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const bytes = crypto.randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function sleep(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function httpRequest(target, options = {}) {
  const { method = 'GET', headers = {}, body = null, timeout = 30000 } = options;
  return new Promise((resolve, reject) => {
    let targetUrl;
    try { targetUrl = new URL(target); }
    catch (error) { reject(new Error(`invalid request URL: ${error.message}`)); return; }
    const transport = targetUrl.protocol === 'http:' ? http : https;
    const request = transport.request(targetUrl, { method, headers }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        headers: response.headers,
        body: Buffer.concat(chunks).toString('utf8')
      }));
    });
    request.setTimeout(timeout, () => { request.destroy(new Error(`the request to ${targetUrl.pathname} timed out`)); });
    request.on('error', reject);
    if (body !== null) request.write(body);
    request.end();
  });
}

function postForm(endpoint, params, timeout = 30000) {
  const body = new URLSearchParams(params).toString();
  return httpRequest(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'content-length': Buffer.byteLength(body),
      accept: 'application/json'
    },
    body,
    timeout
  });
}

function parseJson(text) {
  try { return JSON.parse(text); }
  catch (_) { return {}; }
}

// The OAuth error code is safe to show; a response body may echo request
// material and is therefore never printed.
function oauthError(response) {
  const payload = parseJson(response.body);
  const code = payload.error || `http_${response.status}`;
  return String(code).replace(/[^A-Za-z0-9_.-]/g, '_');
}

async function loadDiscovery() {
  try {
    const response = await httpRequest(`${authUrl}/.well-known/openid-configuration`, { timeout: 15000 });
    if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
    const document = parseJson(response.body);
    const endpoints = {
      issuer: String(document.issuer || ''),
      authorization_endpoint: String(document.authorization_endpoint || ''),
      token_endpoint: String(document.token_endpoint || ''),
      revocation_endpoint: String(document.revocation_endpoint || ''),
      jwks_uri: String(document.jwks_uri || '')
    };
    for (const key of Object.keys(endpoints)) {
      if (!endpoints[key]) throw new Error(`the discovery document has no ${key}`);
    }
    return endpoints;
  } catch (error) {
    note(`using the default OpenAI endpoints (discovery fetch failed: ${error.message})`);
    return { ...DEFAULT_ENDPOINTS };
  }
}

async function loadJwks(jwksUri) {
  const response = await httpRequest(jwksUri, { timeout: 15000 });
  if (response.status !== 200) throw new Error(`the JWKS request failed (HTTP ${response.status})`);
  const document = parseJson(response.body);
  if (!Array.isArray(document.keys) || !document.keys.length) throw new Error('the JWKS document has no keys');
  return document.keys;
}

function decodeSegment(segment) {
  return Buffer.from(segment.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
}

async function validateIdToken(idToken, { issuer, jwksUri, clientId, nonce }) {
  const parts = String(idToken || '').split('.');
  if (parts.length !== 3) throw new Error('the ID token is malformed');
  let header;
  let payload;
  try {
    header = JSON.parse(decodeSegment(parts[0]));
    payload = JSON.parse(decodeSegment(parts[1]));
  } catch (_) {
    throw new Error('the ID token is malformed');
  }
  if (header.alg !== 'RS256') throw new Error(`the ID token algorithm ${header.alg} is not supported`);
  const keys = await loadJwks(jwksUri);
  const jwk = keys.find(key => key.kid === header.kid);
  if (!jwk) throw new Error('the ID token signing key is unknown');
  const publicKey = crypto.createPublicKey({ key: jwk, format: 'jwk' });
  const signature = Buffer.from(parts[2].replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  const signed = Buffer.from(`${parts[0]}.${parts[1]}`);
  if (!crypto.verify('RSA-SHA256', signed, publicKey, signature)) throw new Error('the ID token signature is invalid');
  if (payload.iss !== issuer) throw new Error('the ID token issuer does not match');
  const audience = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!audience.includes(clientId)) throw new Error('the ID token audience does not match the client');
  if (!Number.isFinite(payload.exp) || payload.exp * 1000 <= Date.now()) throw new Error('the ID token is expired');
  if (nonce !== undefined && payload.nonce !== nonce) throw new Error('the ID token nonce does not match');
  return payload;
}

// --- credential storage -----------------------------------------------------

function ensureDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(directory, 0o700); } catch (_) {}
}

function loadCredentials() {
  let stat;
  try { stat = fs.statSync(credentialsFile); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new Error(`cannot read the credential file: ${error.message}`);
  }
  const mode = stat.mode & 0o777;
  if ((mode & 0o077) !== 0) {
    fail(`the credential file ${credentialsFile} is accessible to other users (mode ${mode.toString(8).padStart(4, '0')}); fix it with: chmod 600 ${credentialsFile}`);
  }
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(credentialsFile, 'utf8')); }
  // The parser's message quotes the input, so it is not printed: the file
  // holds the credentials.
  catch (error) { fail(`the credential file ${credentialsFile} is not valid JSON`); }
  if (!parsed || typeof parsed !== 'object') fail(`the credential file ${credentialsFile} is not valid JSON`);
  return parsed;
}

function saveCredentials(credential) {
  const directory = path.dirname(credentialsFile);
  ensureDirectory(directory);
  const temporary = path.join(directory, `.credentials.${process.pid}.tmp`);
  const data = `${JSON.stringify(credential, null, 2)}\n`;
  fs.writeFileSync(temporary, data, { mode: 0o600 });
  try { fs.chmodSync(temporary, 0o600); } catch (_) {}
  fs.renameSync(temporary, credentialsFile);
  try { fs.chmodSync(credentialsFile, 0o600); } catch (_) {}
}

// The refresh token rotates: the provider invalidates it after the first
// use. Two processes must not use the same one, so a refresh runs under a
// lock and re-reads the credential inside it.
const LOCK_STALE_MS = positiveInt(process.env.LMLINE_CHATGPT_LOCK_STALE_MS, 60000);
// The wait budget must outlive the stale threshold, otherwise a waiter gives
// up before it can reclaim a lock that its holder left behind.
const LOCK_WAIT_MS = Math.max(
  positiveInt(process.env.LMLINE_CHATGPT_LOCK_WAIT_MS, 180000),
  LOCK_STALE_MS + 30000
);
// The heartbeat keeps a live lock fresh; it must be well inside the stale
// threshold, so a slow holder is never mistaken for a dead one.
const LOCK_HEARTBEAT_MS = Math.min(30000, Math.max(50, Math.floor(LOCK_STALE_MS / 20)));

function credentialLockPath() {
  return path.join(path.dirname(credentialsFile), 'credentials.lock');
}

async function withCredentialLock(action) {
  const file = credentialLockPath();
  ensureDirectory(path.dirname(file));
  const deadline = Date.now() + LOCK_WAIT_MS;
  let handle = null;
  for (;;) {
    try {
      handle = fs.openSync(file, 'wx', 0o600);
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        const stat = fs.statSync(file);
        // A lock left behind by a killed process must not block forever.
        if (Date.now() - stat.mtimeMs > LOCK_STALE_MS) fs.unlinkSync(file);
      } catch (_) { /* the lock is gone */ }
      if (Date.now() > deadline) {
        fail('another lmline ChatGPT token command is in progress; try again in a moment');
      }
      await sleep(100);
    }
  }
  // A live holder keeps the lock fresh, so a slow refresh is never mistaken
  // for a lock left behind by a killed process.
  const heartbeat = setInterval(() => {
    try { fs.utimesSync(file, new Date(), new Date()); } catch (_) {}
  }, LOCK_HEARTBEAT_MS);
  if (typeof heartbeat.unref === 'function') heartbeat.unref();
  // A signal ends the process without running the exit handler, so the
  // signals that end a command release the lock themselves.
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  // The conventional exit code of each signal, so a caller sees why the
  // command ended.
  const signalExitCodes = { SIGHUP: 129, SIGINT: 130, SIGTERM: 143 };
  const handlers = {};
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    clearInterval(heartbeat);
    try { fs.closeSync(handle); } catch (_) {}
    try { fs.unlinkSync(file); } catch (_) {}
    for (const signal of signals) {
      try { process.removeListener(signal, handlers[signal]); } catch (_) {}
    }
    try { process.removeListener('exit', release); } catch (_) {}
  };
  for (const signal of signals) {
    handlers[signal] = () => {
      release();
      process.exit(signalExitCodes[signal] || 143);
    };
    process.on(signal, handlers[signal]);
  }
  // A process that exits inside the lock must not leave the lock behind.
  process.on('exit', release);
  try {
    const result = await action();
    process.removeListener('exit', release);
    release();
    return result;
  } catch (error) {
    process.removeListener('exit', release);
    release();
    throw error;
  }
}

function purgeCredentials() {
  try { fs.unlinkSync(credentialsFile); }
  catch (error) { if (error.code !== 'ENOENT') throw new Error(`cannot remove the credential file: ${error.message}`); }
}

// The host id identifies this machine to the authorization server and stays
// stable across sign-ins.
function loadHostId() {
  try {
    const value = fs.readFileSync(hostIdFile, 'utf8').trim();
    if (value) return value;
  } catch (error) {
    if (error.code !== 'ENOENT') throw new Error(`cannot read the host id file: ${error.message}`);
  }
  const value = `urn:uuid:${uuid()}`;
  ensureDirectory(path.dirname(hostIdFile));
  fs.writeFileSync(hostIdFile, `${value}\n`, { mode: 0o600 });
  try { fs.chmodSync(hostIdFile, 0o600); } catch (_) {}
  return value;
}

// --- browser and loopback callback ------------------------------------------

function openBrowser(target) {
  if (noBrowser) return Promise.resolve(false);
  let command;
  let args;
  if (browserCommand) {
    const parts = browserCommand.trim().split(/\s+/);
    command = parts[0];
    args = [...parts.slice(1), target];
  } else if (process.platform === 'darwin') {
    command = 'open';
    args = [target];
  } else {
    command = 'xdg-open';
    args = [target];
  }
  return new Promise(resolve => {
    let settled = false;
    const settle = value => { if (!settled) { settled = true; resolve(value); } };
    let child;
    try { child = spawn(command, args, { detached: true, stdio: 'ignore' }); }
    catch (_) { settle(false); return; }
    child.once('error', () => settle(false));
    child.once('spawn', () => { settle(true); child.unref(); });
    setTimeout(() => settle(true), 2000).unref();
  });
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    const onError = error => { server.removeListener('listening', onListening); reject(error); };
    const onListening = () => { server.removeListener('error', onError); resolve(); };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, '127.0.0.1');
  });
}

async function bindCallbackPort(server, firstPort) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const port = firstPort + attempt;
    try {
      await listen(server, port);
      return port;
    } catch (error) {
      if (error.code !== 'EADDRINUSE') throw new Error(`cannot listen on the loopback port ${port}: ${error.message}`);
    }
  }
  throw new Error(`no free loopback port found near ${firstPort}`);
}

// The printed URL never carries the retained ID token.
function redactUrl(target) {
  const url = new URL(target);
  url.searchParams.delete('id_token_hint');
  return url.toString();
}

async function authorize({ discovery, pendingClientId, idTokenHint, loginHint, hostId }) {
  const state = randomToken();
  const nonce = randomToken();
  const verifier = randomToken();
  const challenge = base64url(crypto.createHash('sha256').update(verifier).digest());
  let settle;
  const callback = new Promise(resolve => { settle = resolve; });
  const server = http.createServer((request, response) => {
    const requestUrl = new URL(request.url, 'http://127.0.0.1');
    if (requestUrl.pathname !== CALLBACK_PATH) {
      response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
      response.end('not found\n');
      return;
    }
    const params = {};
    for (const [key, value] of requestUrl.searchParams) params[key] = value;
    response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
    response.end('lmline received the sign-in response. You can close this window.\n');
    settle(params);
  });
  let timer = null;
  try {
    const port = await bindCallbackPort(server, callbackPort);
    const redirectUri = `http://127.0.0.1:${port}${CALLBACK_PATH}`;
    const params = new URLSearchParams();
    params.set('client_id', pendingClientId || DYNAMIC_CLIENT_ID);
    params.set('response_type', 'code');
    params.set('redirect_uri', redirectUri);
    params.set('scope', REQUESTED_SCOPE);
    params.set('resource', apiUrl);
    params.set('state', state);
    params.set('nonce', nonce);
    params.set('code_challenge', challenge);
    params.set('code_challenge_method', 'S256');
    params.set('ext_agent_host_id', hostId);
    if (pendingClientId) {
      // Reauthorization: keep the issued client id, drop the registration
      // hint and point the authorization server at the known account.
      if (idTokenHint) params.set('id_token_hint', idTokenHint);
      if (loginHint) params.set('login_hint', loginHint);
    } else {
      params.set('agent_name_hint', agentName);
    }
    const requestUrl = `${discovery.authorization_endpoint}?${params.toString()}`;
    out(`authorize_url=${redactUrl(requestUrl)}`);
    const opened = await openBrowser(requestUrl);
    if (!opened) note('could not open a browser; open the authorize_url line manually to continue');
    const timeout = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error(`no sign-in callback within ${timeoutSeconds}s`)), timeoutSeconds * 1000);
    });
    const result = await Promise.race([callback, timeout]);
    return { params: result, verifier, redirectUri, nonce, state };
  } finally {
    if (timer) clearTimeout(timer);
    server.close();
  }
}

function checkCallback(params, state, pendingClientId) {
  if (String(params.state || '') !== state) throw new Error('the sign-in response state does not match; ignoring it');
  if (params.error) {
    if (params.error === 'access_denied') throw new Error('ChatGPT plan use was not granted; allow plan usage and sign in again');
    throw new Error(`the authorization server returned an error: ${params.error}`);
  }
  if (!params.code) throw new Error('the sign-in response did not include a code');
  if (!params.client_id) {
    if (!pendingClientId) throw new Error('the sign-in response did not include an issued client id');
    return pendingClientId;
  }
  if (params.client_id === DYNAMIC_CLIENT_ID) throw new Error('the authorization server did not issue a client id');
  if (pendingClientId && params.client_id !== pendingClientId) {
    throw new Error('the sign-in response client id does not match the pending request');
  }
  return params.client_id;
}

// --- token grants -----------------------------------------------------------

async function exchangeCode(discovery, clientId, code, verifier, redirectUri) {
  const response = await postForm(discovery.token_endpoint, {
    grant_type: 'authorization_code',
    client_id: clientId,
    code,
    code_verifier: verifier,
    redirect_uri: redirectUri,
    resource: apiUrl
  });
  if (response.status !== 200) throw new Error(`the token request failed (${oauthError(response)})`);
  const payload = parseJson(response.body);
  if (!payload.access_token) throw new Error('the token response did not include an access token');
  return payload;
}

async function refreshTokens(discovery, credential) {
  if (!credential.refresh_token) throw new Error('there is no refresh token; sign in again with: lmline chatgpt login');
  const response = await postForm(discovery.token_endpoint, {
    grant_type: 'refresh_token',
    client_id: credential.client_id,
    refresh_token: credential.refresh_token,
    resource: apiUrl
  });
  if (response.status !== 200) {
    throw new Error(`the refresh request failed (${oauthError(response)}); sign in again with: lmline chatgpt login`);
  }
  const payload = parseJson(response.body);
  if (!payload.access_token) throw new Error('the refresh response did not include an access token; sign in again with: lmline chatgpt login');
  return payload;
}

async function revokeTokens(discovery, credential) {
  if (!credential.refresh_token || !credential.client_id) return false;
  let delay = 250;
  for (let attempt = 1; attempt <= REVOCATION_ATTEMPTS; attempt++) {
    try {
      const response = await postForm(discovery.revocation_endpoint, {
        token: credential.refresh_token,
        token_type_hint: 'refresh_token',
        client_id: credential.client_id
      });
      if (response.status === 200) return true;
      if (response.status < 500 || attempt === REVOCATION_ATTEMPTS) return false;
    } catch (_) {
      if (attempt === REVOCATION_ATTEMPTS) return false;
    }
    await sleep(delay);
    delay *= 2;
  }
  return false;
}

// --- commands ---------------------------------------------------------------

function issuedClientIdOf(credential) {
  const clientId = credential && credential.client_id ? String(credential.client_id) : '';
  return clientId && clientId !== DYNAMIC_CLIENT_ID ? clientId : '';
}

function scopesOf(credential) {
  return Array.isArray(credential?.scopes) ? credential.scopes.map(String) : [];
}

function accountOf(credential) {
  return String(credential?.account || credential?.email || credential?.subject || '');
}

function planUsageOf(credential) {
  return credential?.plan_usage === true ? 'enabled' : 'disabled';
}

// The plan scope is the authorization for inference: a valid ID token alone
// does not allow a paid request, so a session without the scope is refused
// before a token is handed out.
function requirePlanScope(credential) {
  if (scopesOf(credential).includes(PLAN_SCOPE)) return;
  fail('ChatGPT plan use was not granted for this session; allow plan usage and sign in again with: lmline chatgpt login');
}

function printCredentialState(credential, status) {
  out(`status=${status}`);
  out(`account=${accountOf(credential)}`);
  out(`plan_usage=${planUsageOf(credential)}`);
  out(`scopes=${scopesOf(credential).join(' ')}`);
  out(`expires_at=${Number(credential?.expires_at) || 0}`);
  out(`client_id=${issuedClientIdOf(credential)}`);
  out(`registered=${issuedClientIdOf(credential) ? 1 : 0}`);
}

async function cmdLogin(options) {
  const reauth = options.reauth === true;
  const existing = loadCredentials();
  const savedClientId = issuedClientIdOf(existing);
  if (reauth && !savedClientId) fail('there is no registered ChatGPT account; run: lmline chatgpt login');
  const discovery = await loadDiscovery();
  const hostId = loadHostId();
  const pendingClientId = savedClientId || null;
  // Reauthorization points the authorization server at the known account.
  const idTokenHint = pendingClientId && existing?.id_token ? String(existing.id_token) : '';
  const loginHint = pendingClientId && existing?.email ? String(existing.email) : '';
  const { params, verifier, redirectUri, nonce, state } = await authorize({
    discovery, pendingClientId, idTokenHint, loginHint, hostId
  });
  const clientId = checkCallback(params, state, pendingClientId);
  const payload = await exchangeCode(discovery, clientId, params.code, verifier, redirectUri);
  const claims = await validateIdToken(payload.id_token, {
    issuer: discovery.issuer,
    jwksUri: discovery.jwks_uri,
    clientId,
    nonce
  });
  const scopes = String(payload.scope || '').split(/\s+/).filter(Boolean);
  const credential = {
    client_id: clientId,
    host_id: hostId,
    email: String(claims.email || ''),
    subject: String(claims.sub || ''),
    id_token: String(payload.id_token || ''),
    access_token: String(payload.access_token || ''),
    refresh_token: String(payload.refresh_token || ''),
    token_type: String(payload.token_type || 'Bearer'),
    expires_at: Math.floor(Date.now() / 1000) + Number(payload.expires_in || 3600),
    scopes,
    saved_at: new Date().toISOString(),
    plan_usage: scopes.includes(PLAN_SCOPE),
    account: String(claims.email || claims.sub || '')
  };
  // The sign-in writes under the same lock as the refresh, so an overlapping
  // refresh cannot overwrite a fresh sign-in.
  await withCredentialLock(async () => {
    saveCredentials(credential);
  });
  printCredentialState(credential, 'ok');
  out(`registration=${pendingClientId ? 'reused' : 'created'}`);
}

async function cmdStatus() {
  const credential = loadCredentials();
  if (!credential) {
    out('status=not-signed-in');
    out('account=');
    out('plan_usage=disabled');
    out('scopes=');
    out('expires_at=0');
    out('client_id=');
    out('registered=0');
    out('next=lmline\\ chatgpt\\ login');
    return;
  }
  if (!credential.access_token) {
    printCredentialState(credential, 'signed-out');
    out('next=lmline\\ chatgpt\\ login');
    return;
  }
  if ((Number(credential.expires_at) || 0) <= Math.floor(Date.now() / 1000)) {
    printCredentialState(credential, 'expired');
    out('next=lmline\\ chatgpt\\ refresh');
    return;
  }
  printCredentialState(credential, 'signed-in');
}

// The plan grant must be provable: a token answer that states no scope
// leaves the grant unproven, so it is dropped and the session is refused
// until the user signs in again. One helper serves the refresh and the
// token command, so the two cannot drift.
function applyTokenPayload(credential, payload, claims) {
  const updated = { ...credential };
  updated.access_token = String(payload.access_token || '');
  // The refresh token rotates: the answer replaces the stored one, and the
  // stored one is never a token that was read before the lock.
  updated.refresh_token = String(payload.refresh_token || credential.refresh_token || '');
  updated.token_type = String(payload.token_type || credential.token_type || 'Bearer');
  updated.expires_at = Math.floor(Date.now() / 1000) + Number(payload.expires_in || 3600);
  updated.saved_at = new Date().toISOString();
  updated.scopes = payload.scope
    ? String(payload.scope).split(/\s+/).filter(Boolean)
    : [];
  updated.plan_usage = updated.scopes.includes(PLAN_SCOPE);
  if (claims) {
    updated.id_token = String(payload.id_token || '');
    updated.subject = String(claims.sub || updated.subject || '');
    updated.email = String(claims.email || updated.email || '');
    updated.account = String(claims.email || claims.sub || updated.account || '');
  }
  return updated;
}

async function refreshedCredential(discovery, credential) {
  const payload = await refreshTokens(discovery, credential);
  let claims = null;
  if (payload.id_token) {
    try {
      claims = await validateIdToken(payload.id_token, {
        issuer: discovery.issuer,
        jwksUri: discovery.jwks_uri,
        clientId: issuedClientIdOf(credential)
      });
    } catch (error) {
      note(`the refreshed ID token was not accepted: ${error.message}`);
    }
  }
  return applyTokenPayload(credential, payload, claims);
}

async function cmdRefresh() {
  return withCredentialLock(async () => {
    const credential = loadCredentials();
    if (!credential || !credential.refresh_token) fail('there is no ChatGPT session; run: lmline chatgpt login');
    const discovery = await loadDiscovery();
    const updated = await refreshedCredential(discovery, credential);
    saveCredentials(updated);
    requirePlanScope(updated);
    printCredentialState(updated, 'refreshed');
  });
}

async function cmdLogout(purge) {
  // The logout shares the lock with the refresh, so a refresh that overlaps
  // it cannot write a signed-in session back after the local tokens were
  // cleared.
  return withCredentialLock(async () => {
    const credential = loadCredentials();
    if (!credential) {
      out('status=logged-out');
      out('revoked=yes');
      return;
    }
    const discovery = await loadDiscovery();
    const revoked = await revokeTokens(discovery, credential);
    if (purge) {
      purgeCredentials();
    } else {
      const cleared = { ...credential };
      cleared.id_token = '';
      cleared.access_token = '';
      cleared.refresh_token = '';
      cleared.expires_at = 0;
      // The grant belonged to the revoked session: keeping it would let a
      // report claim a plan usage that no longer exists.
      cleared.scopes = [];
      cleared.plan_usage = false;
      cleared.saved_at = new Date().toISOString();
      saveCredentials(cleared);
    }
    out('status=logged-out');
    out(`revoked=${revoked ? 'yes' : 'no'}`);
    if (!revoked) note('remote revocation was not confirmed; the local tokens were cleared anyway');
  });
}

async function cmdToken() {
  return withCredentialLock(async () => {
    // The credential read under the lock is the only source: another
    // process may have refreshed the session while this one waited.
    const current = loadCredentials();
    if (!current || !current.access_token) fail('there is no ChatGPT session; run: lmline chatgpt login');
    const expiresAt = Number(current.expires_at) || 0;
    if (expiresAt - REFRESH_MARGIN > Math.floor(Date.now() / 1000)) {
      requirePlanScope(current);
      out(String(current.access_token));
      return;
    }
    const discovery = await loadDiscovery();
    const updated = await refreshedCredential(discovery, current);
    saveCredentials(updated);
    requirePlanScope(updated);
    out(String(updated.access_token));
  });
}

async function main() {
  const command = process.argv[2];
  const args = process.argv.slice(3);
  if (command === 'login') return cmdLogin({ reauth: false });
  if (command === 'reauth') return cmdLogin({ reauth: true });
  if (command === 'status') return cmdStatus();
  if (command === 'refresh') return cmdRefresh();
  if (command === 'logout') return cmdLogout(args.includes('--purge'));
  if (command === 'token') return cmdToken();
  fail('usage: chatgpt-client.js login | status | refresh | reauth | logout [--purge] | token', 2);
}

main().catch(error => fail(error.message));
