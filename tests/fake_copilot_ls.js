#!/usr/bin/env node
'use strict';

const fs = require('fs');
let buffer = Buffer.alloc(0);
let signedIn = false;

function log(value) {
  if (process.env.LMLINE_FAKE_COPILOT_LOG) fs.appendFileSync(process.env.LMLINE_FAKE_COPILOT_LOG, `${value}\n`);
}

function send(message) {
  const body = Buffer.from(JSON.stringify(message));
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

function handle(message) {
  if (message.id === 900 && !message.method) log('workspace/configuration-response');
  if (message.method) log(message.method);
  if (message.method === 'workspace/executeCommand' && message.params?.command) log(message.params.command);
  if (message.method === 'initialize') {
    send({ jsonrpc: '2.0', id: message.id, result: { capabilities: { textDocumentSync: 2 } } });
  } else if (message.method === 'initialized') {
    send({ jsonrpc: '2.0', id: 900, method: 'workspace/configuration', params: { items: [{ section: 'github.copilot' }] } });
  } else if (message.method === 'textDocument/copilotInlineEdit') {
    const doc = message.params.textDocument;
    send({ jsonrpc: '2.0', id: message.id, result: { edits: [
      { text: 'new', textDocument: doc, range: { start: { line: 0, character: 8 }, end: { line: 0, character: 11 } }, command: { title: 'Accept', command: 'github.copilot.didAcceptCompletionItem', arguments: ['fake-id'] } },
      { text: 'bad\nline', textDocument: doc, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } } },
      { text: 'definitely-not-a-real-lmline-command', textDocument: doc, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 11 } } }
    ] } });
  } else if (message.method === 'checkStatus') {
    if (signedIn) send({ jsonrpc: '2.0', id: message.id, result: { status: 'OK', user: 'fake-user' } });
    else send({ jsonrpc: '2.0', id: message.id, result: { status: 'NotSignedIn' } });
  } else if (message.method === 'signIn') {
    signedIn = true;
    send({ jsonrpc: '2.0', id: message.id, result: {
      userCode: 'TEST-CODE',
      command: { command: 'openExternalBrowser', arguments: ['https://github.com/login/device?user_code=TEST-CODE'] }
    } });
  } else if (message.method === 'workspace/executeCommand' && message.params?.command === 'openExternalBrowser') {
    send({ jsonrpc: '2.0', id: 901, method: 'window/showDocument', params: { uri: 'https://github.com/login/device?user_code=TEST-CODE', external: true } });
    send({ jsonrpc: '2.0', id: 902, method: 'window/showDocument', params: { uri: 'https://github.com/login/device?user_code=TEST-CODE', external: true } });
    send({ jsonrpc: '2.0', id: message.id, result: null });
  } else if (message.method === 'signOut' || message.method === 'workspace/executeCommand') {
    send({ jsonrpc: '2.0', id: message.id, result: null });
  } else if (message.id !== undefined && message.method) {
    send({ jsonrpc: '2.0', id: message.id, result: null });
  }
}

process.stdin.on('data', chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const match = buffer.slice(0, headerEnd).toString().match(/Content-Length:\s*(\d+)/i);
    if (!match) process.exit(2);
    const length = Number(match[1]);
    if (buffer.length < headerEnd + 4 + length) return;
    const body = buffer.slice(headerEnd + 4, headerEnd + 4 + length);
    buffer = buffer.slice(headerEnd + 4 + length);
    handle(JSON.parse(body.toString()));
  }
});
