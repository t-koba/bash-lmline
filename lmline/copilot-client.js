#!/usr/bin/env node
'use strict';

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { pathToFileURL } = require('url');

const configDir = process.env.LMLINE_CONFIG_DIR || path.join(os.homedir(), '.config', 'lmline');
const runtimeDir = process.env.LMLINE_COPILOT_RUNTIME_DIR || path.join(configDir, 'copilot', 'runtime');
const socketPath = path.join(runtimeDir, 'daemon.sock');
const pidPath = path.join(runtimeDir, 'daemon.pid');
const logPath = path.join(runtimeDir, 'daemon.log');
const lockPath = path.join(runtimeDir, 'daemon.lock');
const timeoutMs = positiveInt(process.env.LMLINE_COPILOT_TIMEOUT, 15000);

function positiveInt(value, fallback) {
  return /^\d+$/.test(value || '') && Number(value) > 0 ? Number(value) : fallback;
}

function fail(message, code = 1) {
  process.stderr.write(`lmline-copilot: ${message}\n`);
  process.exit(code);
}

function stdinText() {
  return new Promise((resolve, reject) => {
    let value = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { value += chunk; });
    process.stdin.on('end', () => resolve(value));
    process.stdin.on('error', reject);
  });
}

function ensureRuntime() {
  fs.mkdirSync(runtimeDir, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(runtimeDir, 0o700); } catch (_) {}
}

function readJsonLine(socket, timeout = timeoutMs) {
  return new Promise((resolve, reject) => {
    let input = '';
    const timer = setTimeout(() => reject(new Error(`request timed out after ${timeout}ms`)), timeout);
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      input += chunk;
      const newline = input.indexOf('\n');
      if (newline >= 0) {
        clearTimeout(timer);
        try { resolve(JSON.parse(input.slice(0, newline))); }
        catch (error) { reject(new Error(`invalid daemon response: ${error.message}`)); }
      }
    });
    socket.on('error', error => { clearTimeout(timer); reject(error); });
    socket.on('end', () => { if (!input.includes('\n')) { clearTimeout(timer); reject(new Error('daemon closed the connection')); } });
  });
}

function connect(payload, timeout = timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    socket.once('connect', async () => {
      socket.write(`${JSON.stringify(payload)}\n`);
      try { resolve(await readJsonLine(socket, timeout)); } catch (error) { reject(error); }
      socket.end();
    });
    socket.once('error', reject);
  });
}

function daemonAlive() {
  try { process.kill(Number(fs.readFileSync(pidPath, 'utf8')), 0); return true; }
  catch (_) { return false; }
}

async function startDaemon() {
  ensureRuntime();
  if (daemonAlive()) {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && daemonAlive()) {
      if (fs.existsSync(socketPath)) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (daemonAlive()) throw new Error(`daemon is running without a socket; run: lmline copilot restart`);
  }
  try { fs.unlinkSync(socketPath); } catch (_) {}
  const log = fs.openSync(logPath, 'a', 0o600);
  const child = spawn(process.execPath, [__filename, 'daemon'], {
    detached: true, stdio: ['ignore', log, log], env: process.env
  });
  child.unref();
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 50));
    if (fs.existsSync(socketPath)) return;
    if (!daemonAlive() && child.exitCode !== null) break;
  }
  throw new Error(`daemon did not start; see ${logPath}`);
}

async function call(payload, timeout = timeoutMs) {
  try { return await connect(payload, timeout); }
  catch (error) {
    if (error && error.code && (error.code === 'ECONNREFUSED' || error.code === 'ENOENT')) {
      await startDaemon();
      return connect(payload, timeout);
    }
    throw error;
  }
}

function utf16Offset(text, character) {
  if (!Number.isInteger(character) || character < 0) return -1;
  let units = 0;
  let index = 0;
  for (const char of text) {
    if (units === character) return index;
    const width = char.length;
    if (units + width > character) return -1;
    units += width;
    index += width;
  }
  return units === character ? text.length : -1;
}

function applyEdit(line, edit, uri, version) {
  if (!edit || edit.textDocument?.uri !== uri || edit.textDocument?.version !== version) return null;
  const range = edit.range;
  if (!range || range.start?.line !== 0 || range.end?.line !== 0 || /[\r\n]/.test(edit.text || '')) return null;
  const start = utf16Offset(line, range.start.character);
  const end = utf16Offset(line, range.end.character);
  if (start < 0 || end < start) return null;
  return line.slice(0, start) + (edit.text || '') + line.slice(end);
}

function applyInlineItem(line, item, position) {
  const text = item?.insertText || '';
  if (/[\r\n]/.test(text)) return null;
  if (item.range) {
    const range = item.range.replacing || item.range;
    if (range.start?.line !== 0 || range.end?.line !== 0) return null;
    const start = utf16Offset(line, range.start.character);
    const end = utf16Offset(line, range.end.character);
    if (start < 0 || end < start) return null;
    return line.slice(0, start) + text + line.slice(end);
  }
  return line.slice(0, position.character) + text + line.slice(position.character);
}

function openDocument(uri) {
  if (!/^https?:\/\//i.test(uri || '')) return false;
  let command;
  let args;
  if (process.platform === 'darwin') { command = 'open'; args = [uri]; }
  else if (process.platform === 'win32') { command = 'cmd.exe'; args = ['/c', 'start', '', uri]; }
  else { command = 'xdg-open'; args = [uri]; }
  try {
    const child = spawn(command, args, { detached: true, stdio: 'ignore' });
    child.on('error', () => {});
    child.unref();
    return true;
  } catch (_) { return false; }
}

class Lsp {
  constructor() {
    this.child = null;
    this.buffer = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
    this.status = null;
    this.messages = [];
    this.workspaces = new Set();
    this.lastOpenedUri = null;
    this.lastOpenedAt = 0;
  }

  command() {
    if (process.env.LMLINE_COPILOT_COMMAND) {
      const override = process.env.LMLINE_COPILOT_COMMAND;
      return override.endsWith('.js') ? [process.execPath, override, '--stdio'] : [override, '--stdio'];
    }
    const bin = process.platform === 'win32' ? 'copilot-language-server.exe' : 'copilot-language-server';
    const packageDir = path.join(configDir, 'copilot', 'node_modules');
    const candidates = [
      path.join(packageDir, '.bin', bin),
      path.join(packageDir, `@github/copilot-language-server-${process.platform}-${process.arch}`, bin)
    ];
    for (const candidate of candidates) if (fs.existsSync(candidate)) return [candidate, '--stdio'];
    const js = path.join(packageDir, '@github', 'copilot-language-server', 'dist', 'language-server.js');
    if (fs.existsSync(js)) return [process.execPath, js, '--stdio'];
    throw new Error('Language Server not installed; run: lmline copilot setup');
  }

  async start() {
    if (this.child && this.child.exitCode === null) return;
    const [command, ...args] = this.command();
    this.child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
    this.child.stdout.on('data', chunk => this.onData(chunk));
    this.child.stderr.on('data', chunk => fs.appendFileSync(logPath, chunk, { mode: 0o600 }));
    this.child.on('error', error => {
      for (const { reject, timer } of this.pending.values()) { clearTimeout(timer); reject(new Error(`Language Server failed: ${error.message}`)); }
      this.pending.clear();
    });
    this.child.on('exit', code => {
      for (const { reject, timer } of this.pending.values()) { clearTimeout(timer); reject(new Error(`Language Server exited (${code})`)); }
      this.pending.clear();
    });
    await this.request('initialize', {
      processId: process.pid, workspaceFolders: null,
      capabilities: {
        textDocument: { synchronization: { didOpen: true, didChange: true, didClose: true }, inlineCompletion: { dynamicRegistration: true } },
        workspace: { workspaceFolders: true, configuration: true },
        window: { showDocument: { support: true } }
      },
      initializationOptions: { editorInfo: { name: 'lmline', version: '1' }, editorPluginInfo: { name: 'bash-lmline', version: '1' } }
    }, timeoutMs * 2);
    this.notify('initialized', {});
    this.notify('workspace/didChangeConfiguration', { settings: {} });
  }

  send(message) {
    const body = Buffer.from(JSON.stringify(message));
    this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.child.stdin.write(body);
  }

  request(method, params, timeout = timeoutMs) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} timed out`)); }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ jsonrpc: '2.0', id, method, params });
    });
  }

  notify(method, params) { this.send({ jsonrpc: '2.0', method, params }); }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const headerEnd = this.buffer.indexOf('\r\n\r\n');
      if (headerEnd < 0) return;
      const match = this.buffer.slice(0, headerEnd).toString().match(/Content-Length:\s*(\d+)/i);
      if (!match) { this.buffer = this.buffer.slice(headerEnd + 4); continue; }
      const length = Number(match[1]);
      if (this.buffer.length < headerEnd + 4 + length) return;
      const body = this.buffer.slice(headerEnd + 4, headerEnd + 4 + length);
      this.buffer = this.buffer.slice(headerEnd + 4 + length);
      try { this.onMessage(JSON.parse(body.toString())); } catch (_) {}
    }
  }

  onMessage(message) {
    if (message.id !== undefined && !message.method) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timer); this.pending.delete(message.id);
      message.error ? pending.reject(new Error(message.error.message || 'LSP error')) : pending.resolve(message.result);
      return;
    }
    if (message.method === 'didChangeStatus') this.status = message.params;
    if (message.method === 'window/logMessage' || message.method === 'window/showMessage' || message.method === 'window/showMessageRequest') {
      if (message.params?.message) {
        const actions = (message.params.actions || []).map(action => action.title).filter(Boolean);
        this.messages.push(message.params.message + (actions.length ? ` [${actions.join(' / ')}]` : ''));
      }
    }
    if (message.id !== undefined) {
      let result = null;
      if (message.method === 'workspace/configuration') result = (message.params?.items || []).map(() => ({}));
      else if (message.method === 'window/showDocument') result = { success: this.showDocument(message.params) };
      else if (message.method === 'window/showMessageRequest') result = null;
      this.send({ jsonrpc: '2.0', id: message.id, result });
    }
  }

  showDocument(params) {
    const uri = params?.uri;
    if (params?.external !== true || !/^https?:\/\//i.test(uri || '')) return false;
    const now = Date.now();
    if (this.lastOpenedUri === uri && now - this.lastOpenedAt < 30000) return false;
    this.lastOpenedUri = uri;
    this.lastOpenedAt = now;
    if (process.env.LMLINE_COPILOT_OPEN_LOG) {
      try { fs.appendFileSync(process.env.LMLINE_COPILOT_OPEN_LOG, `${uri}\n`, { mode: 0o600 }); } catch (_) { return false; }
      return true;
    }
    return openDocument(uri);
  }

  addWorkspace(cwd) {
    const uri = pathToFileURL(cwd).href;
    if (this.workspaces.has(uri)) return;
    this.workspaces.add(uri);
    this.notify('workspace/didChangeWorkspaceFolders', { event: { added: [{ uri, name: path.basename(cwd) || cwd }], removed: [] } });
  }
}

async function runDaemon() {
  ensureRuntime();
  let ownsLock = false;
  try { fs.mkdirSync(lockPath, { mode: 0o700 }); ownsLock = true; }
  catch (_) {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline && !daemonAlive() && !fs.existsSync(socketPath)) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (daemonAlive() || fs.existsSync(socketPath)) process.exit(0);
    try { fs.rmSync(lockPath, { recursive: true, force: true }); fs.mkdirSync(lockPath, { mode: 0o700 }); ownsLock = true; }
    catch (error) { throw new Error(`cannot acquire daemon lock: ${error.message}`); }
  }
  try { fs.unlinkSync(socketPath); } catch (_) {}
  fs.writeFileSync(pidPath, `${process.pid}\n`, { mode: 0o600 });
  const lsp = new Lsp();
  const accepted = new Map();
  let queue = Promise.resolve();

  async function handle(request) {
    if (request.op === 'restart') { if (lsp.child) lsp.child.kill(); return { ok: true }; }
    await lsp.start();
    if (request.op === 'status') {
      let result;
      try { result = await lsp.request('checkStatus', { localChecksOnly: false }); } catch (_) { result = lsp.status; }
      return { ok: true, status: result, messages: lsp.messages.splice(0) };
    }
    if (request.op === 'login') {
      let current;
      try { current = await lsp.request('checkStatus', { localChecksOnly: false }); } catch (_) { current = null; }
      if (current && ['OK', 'MaybeOk', 'AlreadySignedIn'].includes(current.status)) {
        return { ok: true, alreadySignedIn: true, result: current, messages: lsp.messages.splice(0) };
      }
      const result = await lsp.request('signIn', {});
      return { ok: true, result, messages: lsp.messages.splice(0) };
    }
    if (request.op === 'finishLogin') {
      if (request.command?.command) {
        try { await lsp.request('workspace/executeCommand', { command: request.command.command, arguments: request.command.arguments || [] }); } catch (_) {}
      }
      return { ok: true, uri: lsp.lastOpenedUri, messages: lsp.messages.splice(0) };
    }
    if (request.op === 'logout') return { ok: true, result: await lsp.request('signOut', {}) };
    if (request.op === 'accept') {
      const command = accepted.get(request.token);
      if (command) { accepted.delete(request.token); await lsp.request('workspace/executeCommand', command); }
      return { ok: true };
    }
    if (request.op !== 'edit') throw new Error('unknown operation');
    const mode = (request.mode === 'generate' || request.mode === 'fix') ? request.mode : 'rewrite';
    const line = String(request.line || '');
    const cwd = path.resolve(request.cwd || process.cwd());
    lsp.addWorkspace(cwd);
    const uri = pathToFileURL(path.join(cwd, `.lmline-buffer-${process.pid}.sh`)).href;
    const version = 1;
    let bufferText = line;
    if (mode === 'fix' && request.contextText) {
      bufferText = `${line}\n\n${String(request.contextText).split('\n').map(text => `# ${text}`).join('\n')}`;
    }
    lsp.notify('textDocument/didOpen', { textDocument: { uri, languageId: 'shellscript', version, text: bufferText } });
    lsp.notify('textDocument/didFocus', { uri });
    const position = { line: 0, character: Number(request.pointUtf16) || 0 };
    const candidates = [];
    try {
      if (mode === 'generate') {
        const result = await lsp.request('textDocument/inlineCompletion', {
          textDocument: { uri, version },
          position,
          context: { triggerKind: 1 },
          formattingOptions: { tabSize: 4, insertSpaces: true }
        });
        const prefix = line.slice(0, position.character);
        for (const item of result?.items || []) {
          const text = applyInlineItem(line, item, position);
          if (text === null || !text.startsWith(prefix) || candidates.some(candidate => candidate.text === text)) continue;
          const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
          if (item.command) accepted.set(token, { command: item.command.command, arguments: item.command.arguments || [] });
          lsp.notify('textDocument/didShowCompletion', { item });
          candidates.push({ text, token: item.command ? token : '' });
        }
      } else {
        const result = await lsp.request('textDocument/copilotInlineEdit', { textDocument: { uri, version }, position });
        for (const edit of result?.edits || []) {
          const text = applyEdit(line, edit, uri, version);
          if (text === null || candidates.some(item => item.text === text)) continue;
          const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
          if (edit.command) accepted.set(token, { command: edit.command.command, arguments: edit.command.arguments || [] });
          lsp.notify('textDocument/didShowInlineEdit', { item: edit });
          candidates.push({ text, token: edit.command ? token : '' });
        }
      }
    } finally {
      lsp.notify('textDocument/didClose', { textDocument: { uri } });
      lsp.notify('textDocument/didFocus', {});
    }
    return { ok: true, candidates, messages: lsp.messages.splice(0) };
  }

  const server = net.createServer(socket => {
    let input = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      input += chunk;
      const newline = input.indexOf('\n');
      if (newline < 0) return;
      let request;
      try { request = JSON.parse(input.slice(0, newline)); } catch (error) { socket.end(`${JSON.stringify({ ok: false, error: error.message })}\n`); return; }
      queue = queue.then(() => handle(request)).then(
        response => socket.end(`${JSON.stringify(response)}\n`),
        error => socket.end(`${JSON.stringify({ ok: false, error: error.message })}\n`)
      );
    });
  });
  server.on('error', error => { fs.appendFileSync(logPath, `daemon socket error: ${error.message}\n`, { mode: 0o600 }); process.exit(1); });
  server.listen(socketPath, () => { try { fs.chmodSync(socketPath, 0o600); } catch (_) {} });
  const cleanup = () => {
    if (!ownsLock) return;
    try { fs.unlinkSync(socketPath); } catch (_) {}
    try { fs.unlinkSync(pidPath); } catch (_) {}
    try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch (_) {}
  };
  process.on('exit', cleanup); process.on('SIGTERM', () => { cleanup(); process.exit(0); });
}

async function main() {
  const command = process.argv[2];
  if (command === 'daemon') return runDaemon();
  if (command === 'restart') {
    try { const response = await connect({ op: 'restart' }); if (!response.ok) throw new Error(response.error); } catch (_) {}
    try { process.kill(Number(fs.readFileSync(pidPath, 'utf8')), 'SIGTERM'); } catch (_) {}
    process.stdout.write('copilot daemon stopped\n'); return;
  }
  let payload;
  if (command === 'edit' || command === 'edit-json') {
    let line;
    let point;
    let cwd;
    let mode;
    let contextText;
    if (command === 'edit-json') {
      const input = JSON.parse(await stdinText());
      line = String(input.line || '');
      point = Number(input.point || 0);
      cwd = input.cwd || process.cwd();
      mode = input.mode;
      contextText = input.contextText;
    } else {
      line = process.argv[3] || '';
      point = Number(process.argv[4] || 0);
      cwd = process.argv[5] || process.cwd();
    }
    const prefix = Array.from(line).slice(0, point).join('');
    payload = { op: 'edit', line, pointUtf16: prefix.length, cwd };
    if (mode) payload.mode = String(mode);
    if (contextText) payload.contextText = String(contextText);
  } else if (command === 'accept') payload = { op: 'accept', token: process.argv[3] || '' };
  else if (['status', 'login', 'logout'].includes(command)) payload = { op: command };
  else fail('usage: copilot-client.js edit LINE POINT CWD | accept TOKEN | login | status | logout | restart', 2);
  const timeout = command === 'login' ? timeoutMs * 3 + 5000 : timeoutMs;
  const response = await call(payload, timeout);
  if (!response.ok) throw new Error(response.error || 'request failed');
  if (command === 'edit' || command === 'edit-json') {
    for (const message of response.messages || []) process.stderr.write(`lmline-copilot: ${message}\n`);
    for (const item of response.candidates || []) process.stdout.write(`${item.token}\t${item.text}\n`);
    if (!(response.candidates || []).length) {
      process.stderr.write('lmline-copilot: no candidates from Copilot. The Copilot Free plan does not include completion models, so the language server returns nothing; a paid plan (Pro/Business/Enterprise) is required. Check: lmline copilot status\n');
    }
  } else if (command === 'login') {
    for (const message of response.messages || []) process.stderr.write(`lmline-copilot: ${message}\n`);
    if (response.alreadySignedIn) {
      process.stdout.write('already_signed_in=1\n');
      if (response.result?.user) process.stdout.write(`user=${response.result.user}\n`);
    } else {
      if (response.result?.userCode) process.stdout.write(`user_code=${response.result.userCode}\n`);
      if (response.result?.command) {
        const finish = await call({ op: 'finishLogin', command: { command: response.result.command.command, arguments: response.result.command.arguments || [] } }, timeout);
        if (!finish.ok) throw new Error(finish.error);
        for (const message of finish.messages || []) process.stderr.write(`lmline-copilot: ${message}\n`);
        process.stdout.write('browser_opened=1\n');
        if (finish.uri) process.stderr.write(`lmline-copilot: if the browser did not open, visit: ${finish.uri}\n`);
      }
      process.stderr.write('lmline-copilot: complete the sign-in in the browser, then run: lmline copilot status\n');
    }
  } else if (command === 'status') {
    const status = response.status || {};
    process.stdout.write(`status=${status.status || status.kind || 'unknown'}\n`);
    if (status.user) process.stdout.write(`user=${status.user}\n`);
    if (status.message) process.stdout.write(`message=${status.message}\n`);
  } else process.stdout.write('ok\n');
}

main().catch(error => fail(error.message));
