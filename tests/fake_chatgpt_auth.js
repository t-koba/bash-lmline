#!/usr/bin/env node
'use strict';

// Offline mock of the OpenAI authorization server for the ChatGPT sign-in
// client. It signs real RS256 ID tokens so the client validation runs.

const fs = require('fs');
const http = require('http');
const crypto = require('crypto');

const mode = process.env.LMLINE_FAKE_AUTH_MODE || '';
const expiresIn = Number(process.env.LMLINE_FAKE_AUTH_EXPIRES_IN || 3600);
const refreshDelayMs = Number(process.env.LMLINE_FAKE_AUTH_DELAY_MS || 400);
const logFile = process.env.LMLINE_FAKE_CHATGPT_LOG || '';
const issuedClientId = 'oaiapp_mock_client';
const fullScope = 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';
const reducedScope = 'openid profile email offline_access resource.invoke';

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const publicJwk = publicKey.export({ format: 'jwk' });
const keyId = 'mock-key-1';

let counter = 0;
let lastNonce = '';
let currentRefreshToken = '';

function base64url(value) {
  return Buffer.from(value).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function record(key, value) {
  const line = `${key}=${value === undefined || value === null ? '' : value}`;
  process.stdout.write(`${line}\n`);
  if (logFile) {
    try { fs.appendFileSync(logFile, `${line}\n`); }
    catch (_) {}
  }
}

function signIdToken(claims) {
  const header = { alg: 'RS256', typ: 'JWT', kid: keyId };
  const encoded = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(encoded), privateKey);
  return `${encoded}.${base64url(signature)}`;
}

function readBody(request) {
  return new Promise(resolve => {
    let data = '';
    request.setEncoding('utf8');
    request.on('data', chunk => { data += chunk; });
    request.on('end', () => resolve(data));
    request.on('error', () => resolve(''));
  });
}

function sendJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
  response.end(body);
}

function tokenPayload(clientId) {
  counter += 1;
  const now = Math.floor(Date.now() / 1000);
  const scope = mode === 'no_plan_scope' ? reducedScope : fullScope;
  return {
    access_token: `mock_access_token_${counter}`,
    refresh_token: `mock_refresh_token_${counter}`,
    id_token: signIdToken({
      iss: baseUrl,
      aud: clientId,
      sub: 'mock_subject',
      email: 'lmline.mock@example.invalid',
      nonce: lastNonce,
      scope,
      iat: now,
      exp: now + expiresIn
    }),
    token_type: 'Bearer',
    expires_in: expiresIn,
    scope,
    earliest_refresh_at: now + Math.floor(expiresIn / 2)
  };
}

let baseUrl = '';

const server = http.createServer(async (request, response) => {
  const requestUrl = new URL(request.url, baseUrl || 'http://127.0.0.1');
  if (request.method === 'GET' && requestUrl.pathname === '/.well-known/openid-configuration') {
    sendJson(response, 200, {
      issuer: baseUrl,
      authorization_endpoint: `${baseUrl}/api/accounts/authorize`,
      token_endpoint: `${baseUrl}/api/accounts/oauth/token`,
      revocation_endpoint: `${baseUrl}/api/accounts/oauth/revoke`,
      jwks_uri: `${baseUrl}/.well-known/jwks.json`
    });
    return;
  }
  if (request.method === 'GET' && requestUrl.pathname === '/.well-known/jwks.json') {
    sendJson(response, 200, {
      keys: [{ ...publicJwk, kid: keyId, use: 'sig', alg: 'RS256' }]
    });
    return;
  }
  if (request.method === 'GET' && requestUrl.pathname === '/api/accounts/authorize') {
    const clientId = requestUrl.searchParams.get('client_id') || '';
    const redirectUri = requestUrl.searchParams.get('redirect_uri') || '';
    const state = requestUrl.searchParams.get('state') || '';
    lastNonce = requestUrl.searchParams.get('nonce') || '';
    record('authorize_client_id', clientId);
    record('authorize_agent_name_hint', requestUrl.searchParams.get('agent_name_hint') || '');
    record('authorize_id_token_hint', requestUrl.searchParams.get('id_token_hint') ? 'present' : 'absent');
    record('authorize_login_hint', requestUrl.searchParams.get('login_hint') ? 'present' : 'absent');
    record('authorize_code_challenge_method', requestUrl.searchParams.get('code_challenge_method') || '');
    record('authorize_scope', requestUrl.searchParams.get('scope') || '');
    record('authorize_ext_agent_host_id', requestUrl.searchParams.get('ext_agent_host_id') || '');
    record('authorize_resource', requestUrl.searchParams.get('resource') || '');
    if (!redirectUri) {
      sendJson(response, 400, { error: 'invalid_request' });
      return;
    }
    const target = new URL(redirectUri);
    if (mode === 'deny') {
      target.searchParams.set('error', 'access_denied');
      target.searchParams.set('state', state);
    } else {
      counter += 1;
      target.searchParams.set('code', `mock_code_${counter}`);
      target.searchParams.set('state', state);
      target.searchParams.set('client_id', issuedClientId);
    }
    response.writeHead(302, { location: target.toString() });
    response.end();
    return;
  }
  if (request.method === 'POST' && requestUrl.pathname === '/api/accounts/oauth/token') {
    const params = new URLSearchParams(await readBody(request));
    const grantType = params.get('grant_type') || '';
    const clientId = params.get('client_id') || '';
    record('token_grant_type', grantType);
    record('token_client_id', clientId);
    if (grantType === 'refresh_token') {
      if (mode === 'refresh_error') {
        sendJson(response, 400, { error: 'invalid_grant', error_description: 'the refresh token is not valid' });
        return;
      }
      if (mode === 'rotate_refresh') {
        // The documented rotation: a refresh token is invalid after its
        // first use, so a second use of the same token fails.
        const presented = params.get('refresh_token') || '';
        if (!currentRefreshToken || presented !== currentRefreshToken) {
          sendJson(response, 400, { error: 'invalid_grant', error_description: 'the refresh token was already used' });
          return;
        }
        // The slow answer makes the overlap of two refreshes real.
        await new Promise(resolve => setTimeout(resolve, refreshDelayMs));
      }
      const refreshed = tokenPayload(clientId || issuedClientId);
      if (mode === 'rotate_refresh') currentRefreshToken = refreshed.refresh_token;
      sendJson(response, 200, refreshed);
      return;
    }
    if (grantType === 'authorization_code') {
      if (!params.get('code')) {
        sendJson(response, 400, { error: 'invalid_request' });
        return;
      }
      const issued = tokenPayload(clientId || issuedClientId);
      if (mode === 'rotate_refresh') currentRefreshToken = issued.refresh_token;
      sendJson(response, 200, issued);
      return;
    }
    sendJson(response, 400, { error: 'unsupported_grant_type' });
    return;
  }
  if (request.method === 'POST' && requestUrl.pathname === '/api/accounts/oauth/revoke') {
    const params = new URLSearchParams(await readBody(request));
    record('revoke_client_id', params.get('client_id') || '');
    record('revoke_token_type_hint', params.get('token_type_hint') || '');
    if (mode === 'revoke_error') {
      sendJson(response, 500, { error: 'server_error' });
      return;
    }
    response.writeHead(200, { 'content-length': '0' });
    response.end();
    return;
  }
  sendJson(response, 404, { error: 'not_found' });
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
  process.stdout.write(`port=${address.port}\n`);
  process.stdout.write(`base_url=${baseUrl}\n`);
});

process.on('SIGTERM', () => { server.close(); process.exit(0); });
process.on('SIGINT', () => { server.close(); process.exit(0); });
