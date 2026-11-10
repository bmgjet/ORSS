#!/usr/bin/env node
// Copyright (c) bmgjet. All rights reserved.
//
// Rom Sim Studio extension for Claude: a stdio MCP server that gives Claude the Rom Sim Studio toolchain.
//
// It runs in one of two ways:
//   app   - bridge to the HTTP MCP server inside the running desktop app (Settings > MCP server). Claude then works on the
//           ROM open in the app: calibration edits show up live, and the emulator, datalog and simulator tools are available.
//   local - start the head-less server (romsim-mcp.exe, or RomSimStudio.exe --mcp) and pass stdio straight through.
//           Files only: no live ROM, emulator or datalog.
//   auto  - (default) use the app if it answers at startup, otherwise the local server if one is configured, otherwise
//           wait for the app (Claude is told how to start it, and the tools appear once it is up).
//
// Settings come from the environment (the .mcpb manifest fills them in from the extension's settings page):
//   OKIROM_MODE          auto | app | local                     (default auto)
//   OKIROM_APP_URL       the app's MCP endpoint                  (default http://127.0.0.1:8765/mcp)
//   OKIROM_APP_PASSWORD  the password set in the app            (also read from OKIROMSIM_MCP_PASSWORD)
//   OKIROM_EXECUTABLE    romsim-mcp.exe or RomSimStudio.exe   (local mode)
//   OKIROM_READ_ONLY     true to refuse every write              (local mode)
// and the workspace folders for local mode are the command-line arguments.

'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

const VERSION = '0.1.0';
const PROBE_MS = 2000;
const REQUEST_MS = 6 * 60 * 1000; // the app lets a tool run for 5 minutes before giving up on it
const POLL_MS = 5000;

// An optional setting that was left empty can arrive as "" or as the unexpanded "${user_config.x}".
function setting(name) {
  const v = (process.env[name] ?? '').trim();
  return v === '' || v.startsWith('${') ? '' : v;
}

const config = {
  mode: (setting('OKIROM_MODE') || 'auto').toLowerCase(),
  url: setting('OKIROM_APP_URL') || 'http://127.0.0.1:8765/mcp',
  password: setting('OKIROM_APP_PASSWORD') || setting('OKIROMSIM_MCP_PASSWORD'),
  executable: setting('OKIROM_EXECUTABLE'),
  readOnly: /^(1|true|yes|on)$/i.test(setting('OKIROM_READ_ONLY')),
  roots: process.argv.slice(2).map((a) => a.trim()).filter((a) => a !== '' && !a.startsWith('${')),
};

function log(msg) {
  process.stderr.write(`[okirom-extension] ${msg}\n`);
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function rpcError(id, message, code = -32000) {
  return { jsonrpc: '2.0', id, error: { code, message } };
}

const HOW_TO_START =
  'Open Rom Sim Studio, go to Settings > MCP server, tick "Run the HTTP MCP server while the app is open" and check the ' +
  `port and password match this extension's settings (it is looking for ${config.url}).`;

// ------------------------------------------------------------------------------------------------ bridge to the app

class AppBridge {
  constructor() {
    this.sessionId = null;
    this.protocolVersion = null;
    this.connected = null; // did the last request reach the app (null: not tried yet)
    this.clientInit = null; // the client's initialize params, replayed when the app comes up later
    this.poller = null;
  }

  headers() {
    const h = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' };
    if (config.password) h.Authorization = `Bearer ${config.password}`;
    if (this.sessionId) h['Mcp-Session-Id'] = this.sessionId;
    if (this.protocolVersion) h['MCP-Protocol-Version'] = this.protocolVersion;
    return h;
  }

  // POST one JSON-RPC message; returns the reply messages (none for a notification).
  async post(msg, timeoutMs = REQUEST_MS) {
    const res = await fetch(config.url, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(msg),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const sid = res.headers.get('mcp-session-id');
    if (sid) this.sessionId = sid;
    if (res.status === 401) throw new BridgeError('the app refused the password. Set the same password in the extension settings as in Rom Sim Studio > Settings > MCP server.', true);
    if (res.status === 429) throw new BridgeError('the app locked this address out after too many wrong passwords; wait 5 minutes and fix the password in the extension settings.', true);
    if (res.status === 202 || res.status === 204) return [];
    const text = await res.text();
    if (!res.ok) throw new BridgeError(`the app answered HTTP ${res.status}: ${text.slice(0, 200)}`, true);
    return parseBody(text, res.headers.get('content-type') || '');
  }

  async probe() {
    try {
      await this.post({ jsonrpc: '2.0', id: 'okirom-probe', method: 'ping' }, PROBE_MS);
      return 'up';
    } catch (e) {
      return e instanceof BridgeError && e.reached ? 'refused' : 'down';
    }
  }

  async handle(msg) {
    const isRequest = msg.id !== undefined && msg.method !== undefined;
    if (msg.method === 'initialize') this.clientInit = msg.params ?? {};
    try {
      const replies = await this.post(msg);
      this.markConnected(true);
      for (const r of replies) {
        if (msg.method === 'initialize' && r.result) {
          this.protocolVersion = r.result.protocolVersion ?? null;
          // the bridge can announce tool changes (the app starting or stopping), so say so
          r.result.capabilities = { ...(r.result.capabilities ?? {}), tools: { listChanged: true } };
        }
        send(r);
      }
    } catch (e) {
      const reached = e instanceof BridgeError && e.reached;
      if (!reached) this.markConnected(false);
      if (!isRequest) return;
      const why = reached ? e.message : `Rom Sim Studio is not answering at ${config.url} (${describe(e)}). ${HOW_TO_START}`;
      send(this.offlineReply(msg, why));
    }
  }

  // What to answer when the app cannot be reached: enough for the client to start up and for Claude to explain the problem.
  offlineReply(msg, why) {
    switch (msg.method) {
      case 'initialize':
        return {
          jsonrpc: '2.0',
          id: msg.id,
          result: {
            protocolVersion: msg.params?.protocolVersion ?? '2025-06-18',
            capabilities: { tools: { listChanged: true } },
            serverInfo: { name: 'romsim-mcp (waiting for Rom Sim Studio)', version: VERSION },
            instructions: `Rom Sim Studio is not reachable yet: ${why} Its tools appear as soon as it is.`,
          },
        };
      case 'ping':
        return { jsonrpc: '2.0', id: msg.id, result: {} };
      case 'tools/list':
        return { jsonrpc: '2.0', id: msg.id, result: { tools: [STATUS_TOOL] } };
      case 'tools/call':
        return { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: 'error: ' + why }], isError: true } };
      case 'resources/list':
        return { jsonrpc: '2.0', id: msg.id, result: { resources: [] } };
      case 'prompts/list':
        return { jsonrpc: '2.0', id: msg.id, result: { prompts: [] } };
      default:
        return rpcError(msg.id, why);
    }
  }

  // Tell the client when the app comes and goes, so its tool list follows (the status tool while the app is closed, every tool once it is open).
  markConnected(up) {
    if (up === this.connected) return;
    const first = this.connected === null;
    this.connected = up;
    log(up ? `connected to Rom Sim Studio at ${config.url}` : `Rom Sim Studio is not answering at ${config.url}; waiting for it`);
    if (!first && this.clientInit) send({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' });
    if (up) this.stopPolling();
    else this.startPolling();
  }

  startPolling() {
    if (this.poller) return;
    this.poller = setInterval(async () => {
      if ((await this.probe()) !== 'up') return;
      // the app may have restarted: introduce ourselves again before telling the client the tools changed
      if (this.clientInit) {
        try {
          await this.post({ jsonrpc: '2.0', id: 'okirom-reinit', method: 'initialize', params: this.clientInit }, PROBE_MS);
          await this.post({ jsonrpc: '2.0', method: 'notifications/initialized' }, PROBE_MS);
        } catch { return; }
      }
      this.markConnected(true);
    }, POLL_MS);
    this.poller.unref?.();
  }

  stopPolling() {
    if (this.poller) clearInterval(this.poller);
    this.poller = null;
  }
}

class BridgeError extends Error {
  constructor(message, reached) {
    super(message);
    this.reached = reached; // the app answered, but not usefully (bad password, HTTP error)
  }
}

const STATUS_TOOL = {
  name: 'okirom_status',
  description:
    'Rom Sim Studio is not running (or its MCP server is off), so its tools are not available yet. Call this to find out ' +
    'how to start it; the full tool set (assemble, disassemble, run, cal_*, datalog, emulator, simulator, ...) appears once it is.',
  inputSchema: { type: 'object', properties: {} },
  annotations: { readOnlyHint: true },
};

function parseBody(text, contentType) {
  if (contentType.includes('text/event-stream')) {
    const out = [];
    for (const block of text.split(/\r?\n\r?\n/)) {
      const data = block.split(/\r?\n/).filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trimStart()).join('\n');
      if (data) out.push(...[JSON.parse(data)].flat());
    }
    return out;
  }
  if (!text.trim()) return [];
  return [JSON.parse(text)].flat();
}

function describe(e) {
  const c = e?.cause?.code || e?.code;
  if (c === 'ECONNREFUSED') return 'connection refused';
  if (e?.name === 'TimeoutError') return 'timed out';
  return c || e?.message || String(e);
}

// ------------------------------------------------------------------------------------------------ local server

function localCommand() {
  const exe = config.executable;
  const args = [];
  // the desktop app needs --mcp to run as a server instead of opening its window; romsim-mcp is always a server
  if (!/romsim-mcp/i.test(path.basename(exe))) args.push('--mcp');
  let roots = config.roots;
  if (roots.length === 0) {
    const docs = path.join(os.homedir(), 'Documents');
    roots = [fs.existsSync(docs) ? docs : os.homedir()];
  }
  for (const r of roots) args.push('--root', r);
  if (config.readOnly) args.push('--read-only');
  return { exe, args };
}

function startLocal(pending, input) {
  const { exe, args } = localCommand();
  log(`starting ${exe} ${args.join(' ')}`);
  const child = spawn(exe, args, { stdio: ['pipe', 'pipe', 'inherit'], windowsHide: true });
  child.on('error', (e) => {
    log(`could not start ${exe}: ${e.message}`);
    process.exit(1);
  });
  child.on('exit', (code) => {
    log(`${path.basename(exe)} exited (${code})`);
    process.exit(code ?? 0);
  });
  child.stdout.pipe(process.stdout);
  child.stdin.on('error', () => {}); // the child going away is reported by 'exit'
  for (const line of pending) child.stdin.write(line + '\n');
  input.on('line', (line) => child.stdin.write(line + '\n'));
  input.on('close', () => child.stdin.end());
}

// ------------------------------------------------------------------------------------------------ main

async function chooseMode() {
  if (config.mode === 'local') {
    if (!config.executable) throw new Error('local mode needs the path to romsim-mcp.exe or RomSimStudio.exe in the extension settings');
    return 'local';
  }
  if (config.mode === 'app') return 'app';
  if (config.mode !== 'auto') log(`unknown mode '${config.mode}', using auto`);
  const state = await new AppBridge().probe();
  if (state !== 'down') return 'app'; // it answered - even with a bad password, the app is what the user is running
  if (config.executable && fs.existsSync(config.executable)) return 'local';
  if (config.executable) log(`${config.executable} does not exist; waiting for the app instead`);
  return 'app';
}

async function main() {
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  // hold what arrives while deciding which way to go
  const pending = [];
  const hold = (line) => pending.push(line);
  input.on('line', hold);

  let mode;
  try {
    mode = await chooseMode();
  } catch (e) {
    log(e.message);
    process.exit(1);
  }
  input.off('line', hold);
  log(`mode: ${mode}${mode === 'app' ? ` (${config.url})` : ''}`);

  if (mode === 'local') return startLocal(pending, input);

  const bridge = new AppBridge();
  // one message at a time, in order: the app runs one tool at a time anyway
  let chain = Promise.resolve();
  const onLine = (line) => {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      send(rpcError(null, 'parse error', -32700));
      return;
    }
    const batch = Array.isArray(msg) ? msg : [msg];
    for (const m of batch) chain = chain.then(() => bridge.handle(m)).catch((e) => log(`request failed: ${e.message}`));
  };
  pending.forEach(onLine);
  input.on('line', onLine);
  input.on('close', () => chain.finally(() => process.exit(0)));
}

main();
