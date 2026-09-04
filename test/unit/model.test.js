// Unit tests for Model.js -- the pure parsing/formatting/URL layer. No QML,
// no runtime, no network: these run anywhere node does, in well under a second.
// The integration tier (test/qml) covers the parts that need a real socket.
const { test } = require('node:test');
const assert = require('node:assert');
const M = require('../../Model.js');

// ------------------------------------------------------------ host parsing

test('parseHostInput accepts the forms a user might paste', () => {
  // An unspecified port stays null so normalizePrinter can apply the default.
  assert.deepEqual(M.parseHostInput('voron.lan'), { host: 'voron.lan', port: null, scheme: '' });
  assert.deepEqual(M.parseHostInput('voron.lan:7125'), { host: 'voron.lan', port: 7125, scheme: '' });
  // An explicit scheme is a deliberate choice and must be pinned, not probed.
  assert.deepEqual(M.parseHostInput('https://voron.lan'), { host: 'voron.lan', port: null, scheme: 'https' });
  assert.deepEqual(M.parseHostInput('http://voron.lan:7125/'), { host: 'voron.lan', port: 7125, scheme: 'http' });
  // Mainsail's own URL pasted straight from the address bar.
  assert.equal(M.parseHostInput('http://voron.lan/#/dashboard').host, 'voron.lan');
  assert.equal(M.parseHostInput('   voron.lan  ').host, 'voron.lan');
});

test('normalizePrinter fills defaults and rejects unusable records', () => {
  const p = M.normalizePrinter({ host: 'voron.lan' }, 'abc');
  assert.equal(p.id, 'abc');
  assert.equal(p.port, M.DEFAULT_PORT);
  assert.deepEqual(p.webcams, []);
  assert.deepEqual(p.displaySensors, []);
  // Name falls back to something displayable rather than being blank.
  assert.equal(M.printerDisplayName(p), 'voron.lan');
  assert.equal(M.printerDisplayName(M.normalizePrinter({ host: 'h', name: 'Voron' }, 'x')), 'Voron');
  assert.equal(M.printerDisplayName(null), '');
});

test('clonePrinterWith preserves fields it does not know about', () => {
  // This helper exists because three separate call sites rebuilt printer
  // records by hand and silently dropped whatever field was added last.
  const original = { id: 'a', host: 'h', port: 7125, somethingNew: { deep: 1 } };
  const clone = M.clonePrinterWith(original, { port: 80 });
  assert.equal(clone.port, 80);
  assert.deepEqual(clone.somethingNew, { deep: 1 }, 'unknown field survived');
  assert.equal(original.port, 7125, 'original not mutated');
});

// ------------------------------------------------------------ persistence

test('parsePrinters degrades instead of throwing', () => {
  for (const bad of ['', '{{{', 'null', '[]', '{"printers":"nope"}']) {
    const parsed = M.parsePrinters(bad);
    assert.deepEqual(parsed.printers, [], `input ${JSON.stringify(bad)}`);
    assert.equal(parsed.activePrinterId, '');
    assert.ok(parsed.settings, 'settings always present');
  }
});

test('parsePrinters drops records that could never connect', () => {
  const parsed = M.parsePrinters(JSON.stringify({
    printers: [{ id: 'a', host: 'good.lan' }, { id: 'b' }, { host: 'no-id.lan' }],
  }));
  assert.deepEqual(parsed.printers.map(p => p.host), ['good.lan']);
  assert.equal(parsed.activePrinterId, 'a', 'falls back to the first usable printer');
});

test('state file round-trips, and a pre-settings file upgrades in place', () => {
  const state = {
    activePrinterId: 'a',
    printers: [M.normalizePrinter({ id: 'a', host: 'voron.lan', name: 'Voron' }, 'a')],
    settings: { gcodeWatchDir: '/mnt/unraid/GCodes', deferScanWhilePrinting: false },
  };
  const back = M.parsePrinters(M.serializePrinters(state));
  assert.equal(back.activePrinterId, 'a');
  assert.equal(back.printers[0].name, 'Voron');
  assert.equal(back.settings.gcodeWatchDir, '/mnt/unraid/GCodes');
  assert.equal(back.settings.deferScanWhilePrinting, false);

  const legacy = M.parsePrinters(JSON.stringify({ activePrinterId: '', printers: [] }));
  assert.deepEqual(legacy.settings, M.normalizeAppSettings(null));
});

test('app settings keep intent separate from ability to run', () => {
  const fresh = M.normalizeAppSettings(null);
  assert.equal(fresh.gcodeWatchDir, '');
  assert.equal(fresh.deferScanWhilePrinting, true, 'defer defaults on');

  // Regression: normalizing twice used to turn "not configured yet" into an
  // explicit false, so setting a folder for the first time left the watcher
  // switched off with no indication why.
  let s = M.normalizeAppSettings(M.normalizeAppSettings(null));
  s.gcodeWatchDir = '/mnt/unraid/GCodes';
  s = M.normalizeAppSettings(s);
  assert.equal(s.gcodeWatchEnabled, true, 'setting a folder leaves watching enabled');

  // An explicit opt-out still survives a round trip.
  const off = M.normalizeAppSettings(M.normalizeAppSettings({ gcodeWatchDir: '/x', gcodeWatchEnabled: false }));
  assert.equal(off.gcodeWatchEnabled, false);

  assert.equal(M.normalizeAppSettings({ gcodeWatchDir: '/x/' }).gcodeWatchDir, '/x', 'trailing slash trimmed');
  assert.equal(M.normalizeAppSettings({ lastSeenEpoch: 'garbage' }).lastSeenEpoch, 0);
});

test('video overlay selection', () => {
  // Absent means "never customized" and gets a sensible default set; an empty
  // array means the user turned every overlay off and must survive as such.
  assert.deepEqual(M.normalizePrinter({ host: 'h' }, 'x').videoOverlays, M.DEFAULT_VIDEO_OVERLAYS);
  assert.deepEqual(M.normalizePrinter({ host: 'h', videoOverlays: [] }, 'x').videoOverlays, []);

  // Unknown keys would render as blank overlay rows, and duplicates as
  // repeated ones, so both are dropped on the way in.
  assert.deepEqual(M.normalizeVideoOverlays(['name', 'bogus', 'name', 'progress']), ['name', 'progress']);
  assert.deepEqual(M.normalizeVideoOverlays('not an array'), M.DEFAULT_VIDEO_OVERLAYS);

  for (const f of M.VIDEO_OVERLAY_FIELDS) {
    assert.ok(M.isVideoOverlayKey(f.key), f.key);
    assert.equal(M.videoOverlayLabel(f.key), f.label);
  }
  assert.ok(!M.isVideoOverlayKey('nope'));
  // Every default has to be a real field, or it would silently do nothing.
  for (const key of M.DEFAULT_VIDEO_OVERLAYS) assert.ok(M.isVideoOverlayKey(key), key);

  // Survives a save/load cycle rather than reverting to defaults.
  const saved = M.parsePrinters(M.serializePrinters({
    activePrinterId: 'a',
    printers: [M.normalizePrinter({ id: 'a', host: 'h', videoOverlays: ['status'] }, 'a')],
  }));
  assert.deepEqual(saved.printers[0].videoOverlays, ['status']);
});

test('cameraTiles flattens every printer camera into one list', () => {
  const printers = [
    { id: 'a', name: 'Voron', webcams: [{ name: 'C270' }] },
    { id: 'b', name: 'MK3-1', webcams: [] },
    { id: 'c', name: 'MK3-2', webcams: [{ name: 'Front' }, { name: 'Side' }] },
  ];
  const tiles = M.cameraTiles(printers);
  assert.equal(tiles.length, 3, 'a camera-less printer contributes no tile');
  assert.deepEqual(tiles.map(t => t.printerName), ['Voron', 'MK3-2', 'MK3-2']);
  assert.deepEqual(tiles.map(t => t.webcamIndex), [0, 0, 1]);
  assert.deepEqual(tiles.map(t => t.printerId), ['a', 'c', 'c']);

  // A single camera is already identified by its printer's name; only label
  // the camera when a printer has more than one.
  assert.equal(tiles[0].cameraName, '');
  assert.deepEqual([tiles[1].cameraName, tiles[2].cameraName], ['Front', 'Side']);

  assert.deepEqual(M.cameraTiles([]), []);
  assert.deepEqual(M.cameraTiles(null), []);
  assert.deepEqual(M.cameraTiles([{ name: 'no id', webcams: [{}] }]), [], 'skips records with no id');
  assert.deepEqual(M.cameraTiles([{ id: 'x', webcams: 'nope' }]), []);
});

test('camera grid stays as square as possible', () => {
  // Squarest grid keeps cells large, which matters more for video than
  // filling the final row.
  const expected = { 0: 1, 1: 1, 2: 2, 3: 2, 4: 2, 5: 3, 6: 3, 9: 3, 10: 4 };
  for (const [count, cols] of Object.entries(expected)) {
    assert.equal(M.gridColumnsFor(Number(count)), cols, `count ${count}`);
  }
  assert.equal(M.gridRowsFor(4, 2), 2);
  assert.equal(M.gridRowsFor(5, 3), 2);
  assert.equal(M.gridRowsFor(0, 1), 0);
  // Every tile must have a cell, or some cameras would simply not be drawn.
  for (let n = 1; n <= 20; n++) {
    const c = M.gridColumnsFor(n);
    assert.ok(c * M.gridRowsFor(n, c) >= n, `grid too small for ${n}`);
  }
});

test('power devices', () => {
  // Shape taken verbatim from a real Moonraker with a gpio device.
  const real = JSON.stringify({ result: { devices: [
    { device: 'printer', status: 'off', locked_while_printing: true, type: 'gpio' },
  ] } });
  assert.deepEqual(M.parsePowerDevices(real), [
    { device: 'printer', status: 'off', lockedWhilePrinting: true, type: 'gpio' },
  ]);
  // A printer without the [power] component answers 404, which is normal.
  assert.deepEqual(M.parsePowerDevices('{"error":{"message":"Not Found"}}'), []);
  assert.deepEqual(M.parsePowerDevices('garbage'), []);

  // notify_power_changed carries one device in the same shape.
  const push = JSON.stringify({ jsonrpc: '2.0', method: 'notify_power_changed',
    params: [{ device: 'printer', status: 'on', locked_while_printing: true, type: 'gpio' }] });
  assert.equal(M.parsePowerChanged(push).status, 'on');
  assert.equal(M.parsePowerChanged(JSON.stringify({ method: 'notify_status_update', params: [{}] })), null);

  assert.equal(M.powerActionUrl({ host: 'h', port: 7125, scheme: 'http' }, 'printer', 'on'),
    'http://h:7125/machine/device_power/device?device=printer&action=on');
});

test('a printer switched off reads as off, not as a Klipper fault', () => {
  // "Klipper disconnected" is true when the power is off, and useless.
  assert.equal(M.effectiveStateLabel('klippy_disconnected', 'off'), 'Printer off');
  assert.equal(M.effectiveStateLabel('klippy_shutdown', 'off'), 'Printer off');
  assert.equal(M.effectiveStateLabel('offline', 'off'), 'Printer off');
  assert.equal(M.effectiveStateTone('klippy_disconnected', 'off'), 'normal',
    'being switched off is not an alarm');

  // With power on, a disconnect is a real fault and must still say so.
  assert.equal(M.effectiveStateLabel('klippy_disconnected', 'on'), 'Klipper disconnected');
  // warning rather than urgent: only klippy_error / offline / error are urgent.
  assert.equal(M.effectiveStateTone('klippy_disconnected', 'on'), 'warning');
  // And a printer with no power component behaves exactly as before.
  assert.equal(M.effectiveStateLabel('klippy_disconnected', ''), 'Klipper disconnected');
  assert.equal(M.effectiveStateLabel('printing', 'on'), 'Printing');
});

test('power toggling respects locked_while_printing', () => {
  const locked = { status: 'on', lockedWhilePrinting: true };
  const unlocked = { status: 'on', lockedWhilePrinting: false };
  // Moonraker refuses the change mid-print, so the button must be disabled.
  assert.equal(M.canTogglePower(locked, 'printing'), false);
  assert.equal(M.canTogglePower(locked, 'paused'), false, 'paused is still a job');
  assert.equal(M.canTogglePower(locked, 'standby'), true);
  // Not locked: the user may cut power whenever they like.
  assert.equal(M.canTogglePower(unlocked, 'printing'), true);
  // Powering *on* is never restricted -- there is no print to interrupt.
  assert.equal(M.canTogglePower({ status: 'off', lockedWhilePrinting: true }, 'printing'), true);
  assert.equal(M.canTogglePower(null, 'standby'), false);
  assert.equal(M.canTogglePower({ status: 'init', lockedWhilePrinting: false }, 'standby'), false);
});

// ------------------------------------------------------------ gcode paths

test('relativeGcodePath maps only files Moonraker could scan', () => {
  const D = '/mnt/unraid/GCodes';
  assert.equal(M.relativeGcodePath(D, D + '/a.gcode'), 'a.gcode');
  assert.equal(M.relativeGcodePath(D, D + '/DB9/Front Insert.gcode'), 'DB9/Front Insert.gcode');
  assert.equal(M.relativeGcodePath(D + '/', D + '/a.gcode'), 'a.gcode', 'watch dir trailing slash');

  // Hidden trees are the share's trash and thumbnail caches; scanning them
  // would be pure noise.
  assert.equal(M.relativeGcodePath(D, D + '/.Trash-1000/files/x.gcode'), null);
  assert.equal(M.relativeGcodePath(D, D + '/DB9/.thumbs/x.gcode'), null);
  assert.equal(M.relativeGcodePath(D, D + '/.hidden.gcode'), null);

  // A sibling directory that merely shares a prefix is not inside the root.
  assert.equal(M.relativeGcodePath(D, '/mnt/unraid/GCodesOther/a.gcode'), null);
  assert.equal(M.relativeGcodePath(D, '/mnt/unraid/NAS/a.gcode'), null);
  assert.equal(M.relativeGcodePath(D, D), null);
  assert.equal(M.relativeGcodePath('', D + '/a.gcode'), null, 'unconfigured watch dir');
  assert.equal(M.relativeGcodePath(D, D + '/a.txt'), null);
});

test('gcode extensions match what Moonraker will accept', () => {
  // Mirrors VALID_GCODE_EXTS in moonraker/components/file_manager/file_manager.py.
  assert.deepEqual(M.GCODE_EXTS, ['.gcode', '.g', '.gco', '.ufp', '.nc']);
  for (const ext of M.GCODE_EXTS) assert.ok(M.isGcodePath('file' + ext), ext);
  assert.ok(M.isGcodePath('FILE.GCODE'), 'case insensitive');
  assert.ok(!M.isGcodePath('.gcode'), 'a bare extension is not a filename');
  assert.ok(!M.isGcodePath('file.gcode.bak'));
});

test('watcher command lines', () => {
  const D = '/mnt/unraid/GCodes';
  // -r so subdirectories (including ones created later) are covered, and the
  // hidden-file exclusion keeps the trash tree out at the source.
  const ino = M.inotifyArgs(D);
  assert.equal(ino[0], 'inotifywait');
  for (const flag of ['-m', '-r', '-q', 'close_write', 'moved_to', '--exclude']) {
    assert.ok(ino.includes(flag), 'missing ' + flag);
  }
  assert.equal(ino[ino.length - 1], D, 'directory is the final argument');

  const find = M.catchUpArgs(D, 1700000000);
  assert.ok(find.includes('-newermt') && find.includes('@1700000000'));
  assert.equal(M.catchUpArgs(D, 0).includes('@0'), true);
});

// ------------------------------------------------------------ urls

test('URL builders', () => {
  const p = { host: 'voron.lan', port: 7125, scheme: 'http', apiKey: '' };
  assert.equal(M.infoUrl(p), 'http://voron.lan:7125/printer/info');
  assert.equal(M.objectsListUrl(p), 'http://voron.lan:7125/printer/objects/list');
  assert.equal(M.actionUrl(p, '/printer/print/pause'), 'http://voron.lan:7125/printer/print/pause');

  // Filenames contain spaces, brackets and slashes; all must survive.
  assert.equal(M.metascanUrl(p, 'DB9/Front Insert.gcode'),
    'http://voron.lan:7125/server/files/metascan?filename=DB9%2FFront%20Insert.gcode');
  assert.ok(M.metascanUrl(p, '[a]_Tag.gcode').includes('%5Ba%5D'));

  // An explicit scheme argument overrides the stored one (used while probing).
  assert.ok(M.infoUrl(p, 'https').startsWith('https://'));
  assert.ok(M.infoUrl({ host: 'h', port: 1 }).startsWith('http://'), 'defaults to http');

  // Webcams are served by the web UI on its own port, not Moonraker's.
  assert.equal(M.mediaBaseUrl(p), 'http://voron.lan');
  assert.equal(M.resolveWebcamUrl(p, '/webcam/?action=stream'), 'http://voron.lan/webcam/?action=stream');
  assert.equal(M.resolveWebcamUrl(p, 'http://cam.lan/s'), 'http://cam.lan/s', 'absolute url left alone');

  assert.deepEqual(M.apiKeyHeaderArgs({ apiKey: '' }), []);
  assert.deepEqual(M.apiKeyHeaderArgs({ apiKey: 'k' }), ['-H', 'X-Api-Key: k']);
});

test('snapshot cache-buster', () => {
  // The snapshot fallback re-fetches the same URL once a second, so each
  // request needs to be distinct or a cache serves one frame forever.
  assert.equal(M.snapshotUrlWithCacheBust('http://h/webcam/snap', 3),
    'http://h/webcam/snap?_=3');
  // Moonraker's own snapshot URLs already carry a query string.
  assert.equal(M.snapshotUrlWithCacheBust('http://h/webcam/?action=snapshot', 7),
    'http://h/webcam/?action=snapshot&_=7');
  assert.equal(M.snapshotUrlWithCacheBust('', 1), '', 'no url, nothing to fetch');
  assert.equal(M.snapshotUrlWithCacheBust(null, 1), '');
  // Successive counters must differ, or the cache defeats the whole point.
  assert.notEqual(M.snapshotUrlWithCacheBust('http://h/s', 1),
                  M.snapshotUrlWithCacheBust('http://h/s', 2));
});

test('websocketUrl carries the api key as a query token', () => {
  // Headers cannot be set on a QML WebSocket, so the key has to ride the URL.
  const p = { host: 'voron.lan', port: 7125, scheme: 'http', apiKey: 'secret key' };
  assert.equal(M.websocketUrl(p, 'http'), 'ws://voron.lan:7125/websocket?token=secret%20key');
  assert.equal(M.websocketUrl({ host: 'h', port: 1, apiKey: '' }, 'https'), 'wss://h:1/websocket');
});

// ------------------------------------------------------------ sensors

test('sensor classification splits controllable from read-only', () => {
  for (const h of ['extruder', 'extruder1', 'heater_bed', 'heater_generic drybox']) {
    assert.ok(M.isHeaterObject(h), h);
  }
  for (const s of ['temperature_sensor Ambient', 'bme280 Chamber', 'temperature_host', 'htu21d X']) {
    assert.ok(M.isSensorObject(s), s);
    assert.ok(!M.isHeaterObject(s), s + ' is not controllable');
  }
  assert.ok(!M.isSensorObject('gcode_move'));
  assert.equal(M.objectTypeOf('heater_generic drybox'), 'heater_generic');
  assert.equal(M.objectTypeOf('extruder'), 'extruder');
});

test('discoverSensors keeps heaters and sensors apart', () => {
  const found = M.discoverSensors([
    'gcode_move', 'toolhead', 'extruder', 'heater_bed',
    'heater_generic drybox', 'bme280 Chamber', 'temperature_sensor Ambient',
  ]);
  assert.deepEqual(found.heaters.sort(), ['extruder', 'heater_bed', 'heater_generic drybox']);
  assert.deepEqual(found.sensors.sort(), ['bme280 Chamber', 'temperature_sensor Ambient']);
  assert.ok(!found.heaters.includes('toolhead'), 'non-thermal objects excluded');
});

test('multi-output sensors are selectable per field', () => {
  assert.deepEqual(M.selectableFieldsFor('bme280 Chamber'), ['temperature', 'humidity', 'pressure']);
  assert.equal(M.selectableFieldsFor('temperature_sensor Ambient'), null, 'single-field stays whole-object');
  assert.equal(M.selectableFieldsFor('extruder'), null, 'a heater is selected as a whole');
});

test('sensor labels and value formatting', () => {
  assert.equal(M.sensorLabel('heater_generic drybox'), 'drybox');
  assert.equal(M.sensorLabel('extruder'), 'Hotend');
  assert.equal(M.sensorLabel('heater_bed'), 'Bed');
  assert.match(M.sensorFieldLabel('bme280 Chamber', 'humidity'), /Humidity/i);

  const reading = { temperature: 210.44, target: 215, humidity: 37.2, pressure: 982.2 };
  // A heater shows current and target together.
  assert.match(M.formatSensorEntry(reading, ''), /210/);
  assert.match(M.formatSensorEntry(reading, ''), /215/);
  // A single selected field shows only that field, with its own unit.
  assert.match(M.formatSensorEntry(reading, 'humidity'), /37/);
  assert.ok(!M.formatSensorEntry(reading, 'humidity').includes('210'));
  assert.match(M.formatSensorEntry(reading, 'pressure'), /982/);
});

test('extractSensorReading only reports fields that are present', () => {
  assert.deepEqual(M.extractSensorReading({ temperature: 24.3 }), { temperature: 24.3 });
  const full = M.extractSensorReading({ temperature: 1, humidity: 2, pressure: 3, target: 4 });
  assert.deepEqual(full, { temperature: 1, target: 4, humidity: 2, pressure: 3 });
  assert.equal(M.extractSensorReading(null), null);
  assert.equal(M.extractSensorReading({}), null);
});

// ------------------------------------------------------------ status stream

test('subscribeRequestJson always includes the base objects', () => {
  const req = JSON.parse(M.subscribeRequestJson(['extruder', 'bme280 Chamber']));
  assert.equal(req.method, 'printer.objects.subscribe');
  assert.ok(req.id, 'json-rpc id present');
  const objects = req.params.objects;
  // Without these the panel has no state, progress or filename at all.
  for (const base of ['webhooks', 'print_stats', 'display_status', 'virtual_sdcard']) {
    assert.ok(base in objects, 'missing base object ' + base);
  }
  assert.ok('extruder' in objects);
  assert.ok('bme280 Chamber' in objects);
});

test('extractStatus reads the fields the panel displays', () => {
  const status = {
    webhooks: { state: 'ready', state_message: 'Printer is ready' },
    print_stats: { state: 'printing', filename: 'demo.gcode', print_duration: 300, message: '' },
    display_status: { progress: 0.425 },
    extruder: { temperature: 210.4, target: 215 },
  };
  const out = M.extractStatus(status, ['extruder']);
  assert.equal(out.ok, true);
  assert.equal(out.state, 'printing');
  assert.equal(out.filename, 'demo.gcode');
  assert.equal(out.progress, 43, 'progress is a rounded percentage');
  assert.equal(out.printDurationSec, 300);
  assert.deepEqual(out.sensors.extruder, { temperature: 210.4, target: 215 });
});

test('mergeStatusObjects merges per object rather than replacing', () => {
  const current = { extruder: { temperature: 210, target: 215 }, print_stats: { state: 'printing' } };
  const merged = M.mergeStatusObjects(current, { extruder: { temperature: 214.9 } });
  assert.equal(merged.extruder.temperature, 214.9, 'updated field applied');
  assert.equal(merged.extruder.target, 215, 'untouched field within the object survives');
  assert.equal(merged.print_stats.state, 'printing', 'untouched object survives');
});

test('websocket frames are recognised, and unrelated ones ignored', () => {
  const sub = M.parseSubscribeResponse(JSON.stringify({
    jsonrpc: '2.0', id: 1, result: { status: { webhooks: { state: 'ready' } } },
  }));
  assert.ok(sub && sub.webhooks);

  const delta = M.parseNotifyStatusUpdate(JSON.stringify({
    jsonrpc: '2.0', method: 'notify_status_update', params: [{ extruder: { temperature: 1 } }, 12],
  }));
  assert.deepEqual(delta, { extruder: { temperature: 1 } });

  // Moonraker pushes plenty of other notifications; none should be mistaken
  // for a status update.
  for (const other of [
    JSON.stringify({ method: 'notify_proc_stat_update', params: [{}] }),
    JSON.stringify({ method: 'notify_gcode_response', params: ['ok'] }),
    'not json',
  ]) {
    assert.equal(M.parseNotifyStatusUpdate(other), null, other);
  }
});

// ------------------------------------------------------------ presentation

test('state labels and tones', () => {
  assert.equal(M.stateTone('printing'), 'active');
  assert.equal(M.stateTone('error'), 'urgent');
  assert.equal(M.stateTone('offline'), 'urgent');
  assert.equal(M.stateTone('ready'), 'normal');
  assert.equal(typeof M.stateLabel('printing'), 'string');
});

test('jobInProgress gates progress-related display', () => {
  // A bar sitting at 0% next to "Ready" reads as a stalled print rather than
  // as no print, so progress/elapsed/ETA only show while a job exists.
  assert.ok(M.jobInProgress('printing'));
  assert.ok(M.jobInProgress('paused'), 'a paused job is still a job');
  for (const idle of ['ready', 'complete', 'cancelled', 'error', 'standby', 'offline', '']) {
    assert.ok(!M.jobInProgress(idle), idle);
  }
});

test('durations and remaining-time estimate', () => {
  assert.equal(M.formatDuration(0), '0s');
  assert.equal(M.formatDuration(90), '1m');
  assert.equal(M.formatDuration(3600), '1h 0m');
  assert.equal(M.formatDuration(3661), '1h 1m');

  // Signature is (progressPercent, elapsedSec): 300s elapsed at 50% implies
  // roughly 300s left.
  assert.equal(M.estimateRemainingSec(50, 300), 300);
  assert.equal(M.estimateRemainingSec(25, 300), 900);
  // Null, not zero, at the extremes -- the panel hides the estimate rather
  // than claiming a print finishes immediately.
  assert.equal(M.estimateRemainingSec(0, 300), null);
  assert.equal(M.estimateRemainingSec(100, 300), null);
  assert.equal(M.estimateRemainingSec(50, 0), null);
});

test('notificationArgs replaces a printer\'s previous toast when it has an id', () => {
  const n = { urgency: 'normal', headline: 'Voron: print complete', body: 'a.gcode finished' };
  assert.deepEqual(M.notificationArgs(n, 0),
    ['omarchy-notification-send', '-u', 'normal', '-p', 'Voron: print complete', 'a.gcode finished']);
  assert.deepEqual(M.notificationArgs(n, 17),
    ['omarchy-notification-send', '-u', 'normal', '-p', '-r', '17', 'Voron: print complete', 'a.gcode finished']);
});

test('notificationForTransition fires only on meaningful changes', () => {
  assert.equal(M.notificationForTransition('printing', 'printing', 'Voron', 'a.gcode', ''), null);
  // First reading after connecting is not a transition -- a printer that was
  // already shut down when the shell started should not announce itself.
  assert.equal(M.notificationForTransition('', 'printing', 'Voron', 'a.gcode', ''), null);
  assert.equal(M.notificationForTransition('', 'klippy_shutdown', 'Voron', '', ''), null);

  const done = M.notificationForTransition('printing', 'complete', 'Voron', 'a.gcode', '');
  assert.ok(done, 'completion notifies');
  assert.match(done.headline, /Voron/);
  assert.match(done.body, /a\.gcode/);

  const err = M.notificationForTransition('printing', 'error', 'Voron', 'a.gcode', 'thermal runaway');
  assert.ok(err);
  assert.equal(err.urgency, 'critical', 'errors are critical');
  assert.match(err.body, /thermal runaway/);

  assert.ok(M.notificationForTransition('printing', 'cancelled', 'Voron', 'a.gcode', ''));
});

test('an emergency stop notifies whatever the printer was doing', () => {
  // Hitting e-stop in Mainsail shuts Klipper down, which surfaces as
  // klippy_shutdown rather than a print state. That used to notify nothing at
  // all -- the most alarming event the plugin can see was the silent one.
  for (const prev of ['printing', 'paused', 'standby', 'complete', 'error']) {
    const n = M.notificationForTransition(prev, 'klippy_shutdown', 'Voron', 'a.gcode', '');
    assert.ok(n, `no notification from ${prev}`);
    assert.equal(n.urgency, 'critical', prev);
    assert.match(n.headline, /shut down/i);
  }
  // An e-stop from idle still matters: the machine needs a firmware restart
  // before it will do anything.
  assert.ok(M.notificationForTransition('standby', 'klippy_shutdown', 'Voron', '', ''));

  const fault = M.notificationForTransition('printing', 'klippy_error', 'Voron', 'a.gcode', 'MCU shutdown');
  assert.ok(fault);
  assert.equal(fault.urgency, 'critical');
  assert.match(fault.body, /MCU shutdown/);

  // Recovering is not itself an alarm.
  assert.equal(M.notificationForTransition('klippy_shutdown', 'standby', 'Voron', '', ''), null);
});

test('starting a print notifies, resuming one does not', () => {
  for (const prev of ['standby', 'complete', 'cancelled', 'error']) {
    const n = M.notificationForTransition(prev, 'printing', 'Voron', 'a.gcode', '');
    assert.ok(n, `no notification from ${prev}`);
    assert.match(n.headline, /started/i);
    assert.match(n.body, /a\.gcode/);
    assert.equal(n.urgency, 'low', 'a start is informational, not urgent');
  }
  // Resuming is not a new print.
  assert.equal(M.notificationForTransition('paused', 'printing', 'Voron', 'a.gcode', ''), null);
});

// ------------------------------------------------------------ responses

test('response parsers', () => {
  const info = M.parseInfoResponse(JSON.stringify({
    result: { hostname: 'voron', state: 'ready', state_message: 'Printer is ready' },
  }));
  assert.equal(info.ok, true);
  assert.equal(info.hostname, 'voron');
  assert.equal(M.parseInfoResponse('garbage').ok, false);

  assert.deepEqual(M.parseObjectsList(JSON.stringify({ result: { objects: ['a', 'b'] } })), ['a', 'b']);
  assert.deepEqual(M.parseObjectsList('garbage'), []);

  // Relative stream urls are resolved against the printer, so one is required.
  const cams = M.parseWebcamsResponse(JSON.stringify({
    result: { webcams: [{ name: 'C270', stream_url: '/webcam/?action=stream', aspect_ratio: '4:3' }] },
  }), { host: 'voron.lan', port: 7125, scheme: 'http' }, 'http');
  assert.equal(cams.length, 1);
  assert.equal(cams[0].name, 'C270');
  assert.deepEqual(M.parseWebcamsResponse('garbage', { host: 'h' }, 'http'), []);
  // Returned as height/width, since it is used to reserve vertical space for
  // a feed of known width.
  assert.equal(M.parseAspectRatio('4:3'), 0.75);
  assert.equal(M.parseAspectRatio('16:9'), 0.5625);
  assert.equal(M.parseAspectRatio('nonsense'), 0.75, 'falls back to 4:3');
});

test('parseMetascanResult separates "not here" from "broken"', () => {
  assert.deepEqual(M.parseMetascanResult(0, '200', '{}'), { ok: true, notFound: false, error: '' });

  // 404 means this printer's gcodes root doesn't contain the file -- expected
  // when printers don't all share a share, and not worth alarming about.
  const missing = M.parseMetascanResult(0, '404', '');
  assert.equal(missing.ok, false);
  assert.equal(missing.notFound, true);

  const broken = M.parseMetascanResult(0, '500',
    JSON.stringify({ error: { message: 'Failed to parse metadata' } }));
  assert.equal(broken.notFound, false);
  assert.match(broken.error, /Failed to parse metadata/);

  const refused = M.parseMetascanResult(7, '', '');
  assert.equal(refused.ok, false);
  assert.equal(refused.notFound, false, 'unreachable is not "file absent"');
});
