#!/usr/bin/env node
// Mock Moonraker: the HTTP endpoints and websocket JSON-RPC this plugin
// actually calls, and nothing else.
//
// Dependency-free on purpose. Moonraker's websocket only ever sends us
// unfragmented text frames, so a ~60-line RFC6455 reader/writer covers it and
// the repo stays `git clone && ./test/run.sh` with no npm install step.
//
// Prints its port on stdout as the first line, so a caller can bind :0 and
// read back the ephemeral port. Every request is appended to REQUEST_LOG as
// JSONL so a test can assert on what the server was actually asked for,
// separately from what the QML ended up displaying.

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const requestLog = process.env.REQUEST_LOG || '';

// --- scenario knobs -------------------------------------------------------
// Kept as env rather than a config file so a test is one `env A=b` line.
const cfg = {
  // Reported in the subscribe snapshot and mutable at runtime via /__mock/state.
  state: process.env.MOCK_STATE || 'ready',
  filename: process.env.MOCK_FILENAME || '',
  progress: Number(process.env.MOCK_PROGRESS || 0),
  // HTTP status for /server/files/metascan, to exercise the 404 "this printer
  // doesn't have the file" path and the generic-failure path.
  metascanStatus: Number(process.env.MOCK_METASCAN_STATUS || 200),
  // Close every websocket this many ms after subscribing, to drive reconnect.
  dropAfterMs: Number(process.env.MOCK_DROP_AFTER_MS || 0),
  objects: (process.env.MOCK_OBJECTS ||
    'webhooks,print_stats,display_status,virtual_sdcard,extruder,heater_bed,heater_generic drybox,bme280 Chamber,temperature_sensor Ambient').split(','),
};

function log(entry) {
  if (!requestLog) return;
  fs.appendFileSync(requestLog, JSON.stringify(entry) + '\n');
}

// --- RFC6455, text frames only -------------------------------------------

function encodeFrame(str) {
  const payload = Buffer.from(str, 'utf8');
  const n = payload.length;
  let head;
  if (n < 126) {
    head = Buffer.from([0x81, n]);
  } else if (n < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x81; head[1] = 126; head.writeUInt16BE(n, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2);
  }
  return Buffer.concat([head, payload]);
}

// Generator so a single TCP chunk carrying several frames (or a frame split
// across chunks) is handled without the caller tracking state itself.
function* decodeFrames(state, chunk) {
  state.buf = Buffer.concat([state.buf, chunk]);
  for (;;) {
    const b = state.buf;
    if (b.length < 2) return;
    const opcode = b[0] & 0x0f;
    const masked = (b[1] & 0x80) !== 0;
    let len = b[1] & 0x7f;
    let off = 2;
    if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
    else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); off = 10; }
    const maskOff = off;
    if (masked) off += 4;
    if (b.length < off + len) return;
    const payload = Buffer.from(b.subarray(off, off + len));
    if (masked) for (let i = 0; i < len; i++) payload[i] ^= b[maskOff + (i % 4)];
    state.buf = b.subarray(off + len);
    if (opcode === 0x8) { state.closed = true; return; }
    if (opcode === 0x1) yield payload.toString('utf8');
  }
}

// --- printer status -------------------------------------------------------

function statusSnapshot() {
  const status = {
    webhooks: { state: 'ready', state_message: 'Printer is ready' },
    print_stats: {
      state: cfg.state,
      filename: cfg.filename,
      print_duration: 120,
      message: '',
    },
    display_status: { progress: cfg.progress },
    virtual_sdcard: { progress: cfg.progress },
  };
  // Only report objects the scenario says this printer has, so a test can
  // model a plain MK3 (two heaters) or a loaded Voron (bme280s and friends).
  if (cfg.objects.includes('extruder')) status.extruder = { temperature: 210.4, target: 215 };
  if (cfg.objects.includes('heater_bed')) status.heater_bed = { temperature: 59.8, target: 60 };
  if (cfg.objects.includes('heater_generic drybox')) status['heater_generic drybox'] = { temperature: 41, target: 45 };
  if (cfg.objects.includes('bme280 Chamber')) status['bme280 Chamber'] = { temperature: 34.2, humidity: 18.5, pressure: 981.3 };
  if (cfg.objects.includes('temperature_sensor Ambient')) status['temperature_sensor Ambient'] = { temperature: 24.3 };
  return status;
}

const sockets = new Set();

function broadcast(obj) {
  const frame = encodeFrame(JSON.stringify(obj));
  for (const s of sockets) { try { s.write(frame); } catch (e) { /* peer gone */ } }
}

function pushStatus(patch) {
  broadcast({ jsonrpc: '2.0', method: 'notify_status_update', params: [patch, Date.now() / 1000] });
}

// --- HTTP -----------------------------------------------------------------

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  log({ kind: 'http', method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams) });

  const json = (code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  };

  switch (url.pathname) {
    case '/printer/info':
      return json(200, { result: { hostname: 'mock-printer', state: 'ready', state_message: 'Printer is ready' } });

    case '/printer/objects/list':
      return json(200, { result: { objects: cfg.objects } });

    case '/server/webcams/list':
      return json(200, { result: { webcams: [{
        name: 'MockCam', stream_url: '/webcam/?action=stream', snapshot_url: '/webcam/?action=snapshot',
        flip_horizontal: false, flip_vertical: false, rotation: 0, aspect_ratio: '4:3',
      }] } });

    case '/server/files/metascan': {
      const filename = url.searchParams.get('filename') || '';
      if (cfg.metascanStatus !== 200) {
        return json(cfg.metascanStatus, { error: { code: cfg.metascanStatus, message: 'mock metascan failure' } });
      }
      return json(200, { result: { filename, size: 74934, modified: 1788324271, estimated_time: 32, layer_count: 2, object_height: 0.4 } });
    }

    // Lets a test change printer state mid-run (e.g. finish a print to assert
    // a notification, or leave "printing" to release a deferred scan queue).
    case '/__mock/state': {
      const next = url.searchParams.get('state');
      if (next) cfg.state = next;
      if (url.searchParams.has('filename')) cfg.filename = url.searchParams.get('filename');
      if (url.searchParams.has('progress')) cfg.progress = Number(url.searchParams.get('progress'));
      pushStatus({ print_stats: { state: cfg.state, filename: cfg.filename, message: '' },
                   display_status: { progress: cfg.progress } });
      return json(200, { result: 'ok' });
    }

    default:
      // Everything else is an action endpoint (print/pause, emergency_stop,
      // firmware_restart, gcode/script). Moonraker answers these with a bare
      // ok, and the tests assert on the request log rather than the body.
      return json(200, { result: 'ok' });
  }
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const url = new URL(req.url, 'http://localhost');
  log({ kind: 'ws-open', path: url.pathname, query: Object.fromEntries(url.searchParams) });

  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + crypto.createHash('sha1').update(key + WS_GUID).digest('base64') + '\r\n\r\n'
  );
  sockets.add(socket);

  const state = { buf: Buffer.alloc(0) };
  socket.on('data', (chunk) => {
    for (const msg of decodeFrames(state, chunk)) {
      let rpc;
      try { rpc = JSON.parse(msg); } catch (e) { continue; }
      log({ kind: 'rpc', method: rpc.method, params: rpc.params });
      if (rpc.method !== 'printer.objects.subscribe') continue;

      socket.write(encodeFrame(JSON.stringify({
        jsonrpc: '2.0', id: rpc.id,
        result: { eventtime: Date.now() / 1000, status: statusSnapshot() },
      })));

      if (cfg.dropAfterMs > 0) {
        setTimeout(() => { try { socket.destroy(); } catch (e) {} }, cfg.dropAfterMs);
      }
    }
  });
  socket.on('close', () => sockets.delete(socket));
  socket.on('error', () => sockets.delete(socket));
});

server.listen(Number(process.env.MOCK_PORT || 0), '127.0.0.1', () => {
  // First stdout line is the port, so callers can bind :0 and read it back.
  console.log(String(server.address().port));
});
