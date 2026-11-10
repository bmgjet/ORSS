// Tests for server/index.js against stand-ins for Rom Sim Studio's two MCP transports:
// the desktop app's HTTP server (McpHttp) and the head-less stdio server (romsim-mcp / RomSimStudio --mcp).
// Run with: node --test test/
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ENTRY = path.join(__dirname, '..', 'server', 'index.js');
const TOOLS = [{ name: 'help', description: 'List every tool', inputSchema: { type: 'object', properties: {} } }];

// Behaves like McpHttp + McpServer: bearer password, 202 for notifications, Mcp-Session-Id on initialize.
function fakeApp(password = '') {
  const calls = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      if (password && req.headers.authorization !== `Bearer ${password}`) {
        res.writeHead(401).end('unauthorized');
        return;
      }
      const msg = JSON.parse(body);
      calls.push({ ...msg, session: req.headers['mcp-session-id'] });
      if (msg.id === undefined) {
        res.writeHead(202).end();
        return;
      }
      let result;
      if (msg.method === 'initialize')
        result = { protocolVersion: msg.params.protocolVersion, capabilities: { tools: { listChanged: false } }, serverInfo: { name: 'romsim-mcp', version: '0.0.0.2' } };
      else if (msg.method === 'tools/list') result = { tools: TOOLS };
      else if (msg.method === 'tools/call') result = { content: [{ type: 'text', text: `ran ${msg.params.name}` }], isError: false };
      else result = {};
      const headers = { 'Content-Type': 'application/json' };
      if (msg.method === 'initialize') headers['Mcp-Session-Id'] = 'abc';
      res.writeHead(200, headers).end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
    });
  });
  return new Promise((resolve) =>
    server.listen(0, '127.0.0.1', () => resolve({ server, calls, url: `http://127.0.0.1:${server.address().port}/mcp` })),
  );
}

async function freePort() {
  const s = http.createServer();
  await new Promise((r) => s.listen(0, '127.0.0.1', r));
  const port = s.address().port;
  await new Promise((r) => s.close(r));
  return port;
}

// A stand-in for romsim-mcp.exe: answers over stdio and reports the arguments it was started with.
function fakeLocalServer(name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'okirom-'));
  const js = path.join(dir, 'fake.js');
  fs.writeFileSync(
    js,
    `const rl=require('readline').createInterface({input:process.stdin});
     rl.on('line',l=>{const m=JSON.parse(l);if(m.id===undefined)return;
       process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{args:process.argv.slice(2),method:m.method}})+'\\n');});`,
  );
  const exe = path.join(dir, name);
  fs.writeFileSync(exe, `#!/bin/sh\nexec "${process.execPath}" "${js}" "$@"\n`, { mode: 0o755 });
  return exe;
}

// Start the extension; returns helpers to send messages and wait for replies.
function start(env, args = []) {
  const child = spawn(process.execPath, [ENTRY, ...args], {
    env: { PATH: process.env.PATH, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const got = [];
  let waiters = [];
  let buf = '';
  let stderr = '';
  child.stderr.on('data', (c) => (stderr += c));
  child.stdout.on('data', (c) => {
    buf += c;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      got.push(JSON.parse(line));
      waiters = waiters.filter((w) => !w());
    }
  });
  const next = (pred, ms = 15000) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out; got ${JSON.stringify(got)}; stderr ${stderr}`)), ms);
      const check = () => {
        const i = got.findIndex(pred);
        if (i < 0) return false;
        clearTimeout(t);
        resolve(got.splice(i, 1)[0]);
        return true;
      };
      if (!check()) waiters.push(check);
    });
  let id = 0;
  const request = (method, params = {}) => {
    const myId = ++id;
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: myId, method, params }) + '\n');
    return next((m) => m.id === myId);
  };
  const notify = (method) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n');
  const stop = () => {
    child.stdin.end();
    return new Promise((r) => child.on('exit', r));
  };
  return { child, request, notify, next, stop, stderr: () => stderr };
}

const INIT = { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } };

test('app mode: forwards to the running app with the password and session id', async () => {
  const app = await fakeApp('secret-pass');
  const ext = start({ OKIROM_APP_URL: app.url, OKIROM_APP_PASSWORD: 'secret-pass' });
  const init = await ext.request('initialize', INIT);
  assert.equal(init.result.serverInfo.name, 'romsim-mcp');
  assert.equal(init.result.capabilities.tools.listChanged, true);
  ext.notify('notifications/initialized');
  const list = await ext.request('tools/list');
  assert.deepEqual(list.result.tools.map((t) => t.name), ['help']);
  const call = await ext.request('tools/call', { name: 'help', arguments: {} });
  assert.equal(call.result.content[0].text, 'ran help');
  await ext.stop();
  app.server.close();
  assert.equal(app.calls.find((c) => c.method === 'tools/call').session, 'abc');
});

test('app mode: a wrong password is explained, not a crash', async () => {
  const app = await fakeApp('right-password');
  const ext = start({ OKIROM_APP_URL: app.url, OKIROM_APP_PASSWORD: 'wrong' });
  const init = await ext.request('initialize', INIT);
  assert.match(init.result.instructions, /refused the password/);
  const call = await ext.request('tools/call', { name: 'help', arguments: {} });
  assert.equal(call.result.isError, true);
  assert.match(call.result.content[0].text, /password/);
  await ext.stop();
  app.server.close();
});

test('auto mode: waits for the app, then announces its tools once it starts', async () => {
  const port = await freePort();
  const url = `http://127.0.0.1:${port}/mcp`;
  const ext = start({ OKIROM_APP_URL: url, OKIROM_MODE: 'auto', OKIROM_EXECUTABLE: '${user_config.executable}' });
  const init = await ext.request('initialize', INIT);
  assert.match(init.result.instructions, /not reachable yet/);
  ext.notify('notifications/initialized');
  const offline = await ext.request('tools/list');
  assert.deepEqual(offline.result.tools.map((t) => t.name), ['okirom_status']);
  const status = await ext.request('tools/call', { name: 'okirom_status', arguments: {} });
  assert.match(status.result.content[0].text, /Settings > MCP server/);

  // the user opens the app
  const app = await fakeApp();
  await new Promise((r) => app.server.close(r));
  await new Promise((r) => app.server.listen(port, '127.0.0.1', r));
  await ext.next((m) => m.method === 'notifications/tools/list_changed', 15000);
  const online = await ext.request('tools/list');
  assert.deepEqual(online.result.tools.map((t) => t.name), ['help']);
  assert.ok(app.calls.some((c) => c.method === 'initialize'), 'the bridge re-initialised with the app');

  // the user closes it again
  app.server.close();
  app.server.closeAllConnections();
  const gone = await ext.request('tools/call', { name: 'help', arguments: {} });
  assert.equal(gone.result.isError, true);
  await ext.next((m) => m.method === 'notifications/tools/list_changed');
  await ext.stop();
});

// the stand-in server is a POSIX shell script: Windows cannot spawn it (the real one is an .exe)
const NO_SH = process.platform === 'win32' && 'the stand-in local server is a shell script';

test('auto mode: falls back to the local server with workspace roots', { skip: NO_SH }, async () => {
  const exe = fakeLocalServer('romsim-mcp');
  const port = await freePort();
  const ext = start(
    { OKIROM_APP_URL: `http://127.0.0.1:${port}/mcp`, OKIROM_EXECUTABLE: exe, OKIROM_READ_ONLY: 'true' },
    ['/roms/a', '/roms/b'],
  );
  const init = await ext.request('initialize', INIT);
  assert.deepEqual(init.result.args, ['--root', '/roms/a', '--root', '/roms/b', '--read-only']);
  await ext.stop();
});

test('local mode: the desktop app executable is started with --mcp', { skip: NO_SH }, async () => {
  const exe = fakeLocalServer('RomSimStudio');
  const ext = start({ OKIROM_MODE: 'local', OKIROM_EXECUTABLE: exe, OKIROM_READ_ONLY: 'false' }, ['/roms']);
  const r = await ext.request('tools/list');
  assert.deepEqual(r.result.args, ['--mcp', '--root', '/roms']);
  assert.equal(r.result.method, 'tools/list');
  await ext.stop();
});
