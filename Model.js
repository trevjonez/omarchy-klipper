// Pure parsing/formatting helpers for the Klipper tray plugin. No QML/Quickshell
// APIs here so this stays testable in isolation, matching the discipline of the
// first-party weather/tailscale plugins' Model.js files.

var DEFAULT_PORT = 7125;

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "");
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(String(value), 10);
  if (!isFinite(n)) n = fallback;
  if (min !== undefined && n < min) n = min;
  if (max !== undefined && n > max) n = max;
  return n;
}

// ---------------------------------------------------------------- printers

// Users paste all sorts of things into a "host" field: a bare hostname, a
// full URL with scheme, one with an embedded port, a trailing slash/path.
// Pull out whatever is actually there so the rest of the plugin only ever
// deals with a clean host, and an explicit scheme/port when the user gave one.
function parseHostInput(rawHost) {
  var value = trimmed(rawHost);
  var scheme = "";
  var schemeMatch = value.match(/^(https?):\/\//i);
  if (schemeMatch) {
    scheme = schemeMatch[1].toLowerCase();
    value = value.slice(schemeMatch[0].length);
  }
  var slash = value.indexOf("/");
  if (slash !== -1) value = value.slice(0, slash);
  var port = null;
  var colon = value.lastIndexOf(":");
  if (colon !== -1) {
    var maybePort = value.slice(colon + 1);
    if (/^\d+$/.test(maybePort)) {
      port = parseInt(maybePort, 10);
      value = value.slice(0, colon);
    }
  }
  return { host: value, scheme: scheme, port: port };
}

// Normalizes one printer entry, filling in a stable shape so the rest of the
// plugin never has to guard against missing fields. `scheme` is "" (unknown —
// probe http then https and remember whichever answers) whenever neither the
// host field nor an already-stored scheme pins one down.
function normalizePrinter(raw, fallbackId) {
  var p = isPlainObject(raw) ? raw : {};
  var parsedHost = parseHostInput(p.host);
  var scheme = trimmed(p.scheme).toLowerCase();
  if (scheme !== "http" && scheme !== "https") scheme = "";
  if (!scheme && parsedHost.scheme) scheme = parsedHost.scheme;
  var port = parsedHost.port !== null ? parsedHost.port : p.port;
  return {
    id: trimmed(p.id) || trimmed(fallbackId) || "",
    name: trimmed(p.name),
    host: parsedHost.host,
    port: clampInt(port, DEFAULT_PORT, 1, 65535),
    scheme: scheme,
    apiKey: trimmed(p.apiKey),
    // Last known camera list, persisted so the panel can reserve the right
    // amount of space for it immediately on switching to this printer,
    // instead of the layout jumping once a fresh fetch completes.
    webcams: Array.isArray(p.webcams) ? p.webcams.map(normalizeCachedWebcam).filter(Boolean) : [],
    // Which temperature/sensor objects to show, and which field of each
    // (for a multi-output sensor like bme280). [] means "not customized
    // yet" — the connection auto-seeds this to the printer's heaters on
    // first successful connect.
    displaySensors: Array.isArray(p.displaySensors) ? p.displaySensors.map(normalizeDisplaySensorEntry).filter(Boolean) : [],
    // Which fields to draw over this printer's fullscreen camera feed.
    videoOverlays: normalizeVideoOverlays(p.videoOverlays)
  };
}

// Every place that patches one field of an already-normalized printer
// record (pinning a discovered scheme, caching webcams, saving a sensor
// selection) needs to carry every *other* field forward, or that patch
// silently wipes whatever it didn't know about. Centralizing it here means
// adding a new persisted field only ever requires one edit, not one at
// every call site that happens to construct a printer record by hand.
function clonePrinterWith(printer, overrides) {
  // Copies whatever the record actually has rather than a fixed field list:
  // this helper exists because hand-rebuilt printer records kept dropping the
  // most recently added field, and enumerating fields here would reintroduce
  // exactly that failure the next time one is added.
  var base = {};
  for (var key in (printer || {})) base[key] = printer[key];
  if (!base.webcams) base.webcams = [];
  if (!base.displaySensors) base.displaySensors = [];
  for (var override in (overrides || {})) base[override] = overrides[override];
  return base;
}

// ------------------------------------------------------- video overlays

// What can be drawn over a fullscreen camera feed. A fixed catalogue rather
// than free text: each key maps to a value the panel already has live, and
// the picker renders straight from this list.
var VIDEO_OVERLAY_FIELDS = [
  { key: "name", label: "Printer name" },
  { key: "status", label: "Status" },
  { key: "filename", label: "File name" },
  { key: "progress", label: "Progress" },
  { key: "elapsed", label: "Elapsed time" },
  { key: "remaining", label: "Time remaining" },
  { key: "temps", label: "Temperatures" }
];

// Enough to identify the feed and see how the job is going, without covering
// much of the picture.
var DEFAULT_VIDEO_OVERLAYS = ["name", "status", "filename", "progress"];

function isVideoOverlayKey(key) {
  for (var i = 0; i < VIDEO_OVERLAY_FIELDS.length; i++) {
    if (VIDEO_OVERLAY_FIELDS[i].key === key) return true;
  }
  return false;
}

function videoOverlayLabel(key) {
  for (var i = 0; i < VIDEO_OVERLAY_FIELDS.length; i++) {
    if (VIDEO_OVERLAY_FIELDS[i].key === key) return VIDEO_OVERLAY_FIELDS[i].label;
  }
  return key;
}

// An absent key means "never customized" and gets the defaults; an empty
// array means the user deliberately turned everything off, and is preserved.
function normalizeVideoOverlays(raw) {
  if (!Array.isArray(raw)) return DEFAULT_VIDEO_OVERLAYS.slice();
  var seen = {};
  var out = [];
  for (var i = 0; i < raw.length; i++) {
    var key = trimmed(raw[i]);
    if (!isVideoOverlayKey(key) || seen[key]) continue;
    seen[key] = true;
    out.push(key);
  }
  return out;
}

// ------------------------------------------------------- camera wall

// Flattens every configured printer's cameras into one list of tiles, so the
// all-cameras view can iterate a single model. A printer contributes one tile
// per camera, and printers with none contribute nothing rather than an empty
// placeholder.
function cameraTiles(printers) {
  var tiles = [];
  var list = printers || [];
  for (var i = 0; i < list.length; i++) {
    var p = list[i];
    if (!p || !p.id) continue;
    var cams = Array.isArray(p.webcams) ? p.webcams : [];
    for (var j = 0; j < cams.length; j++) {
      if (!cams[j]) continue;
      tiles.push({
        printerId: p.id,
        printerName: printerDisplayName(p),
        webcamIndex: j,
        // Only worth labelling the camera when a printer has more than one;
        // otherwise the printer name already identifies the feed.
        cameraName: cams.length > 1 ? trimmed(cams[j].name) : "",
        webcam: cams[j]
      });
    }
  }
  return tiles;
}

// Squarest grid that holds `count` tiles. Keeps cells as large as possible,
// which matters more than filling the last row when the tiles are video.
function gridColumnsFor(count) {
  var n = parseInt(String(count), 10);
  if (!isFinite(n) || n <= 1) return 1;
  return Math.ceil(Math.sqrt(n));
}

function gridRowsFor(count, columns) {
  var n = parseInt(String(count), 10);
  var c = parseInt(String(columns), 10);
  if (!isFinite(n) || n <= 0 || !isFinite(c) || c <= 0) return 0;
  return Math.ceil(n / c);
}

// Validates one persisted {object, field?} selection entry.
function normalizeDisplaySensorEntry(entry) {
  if (!isPlainObject(entry)) return null;
  var object = trimmed(entry.object);
  if (!object) return null;
  var field = trimmed(entry.field);
  return field ? { object: object, field: field } : { object: object };
}

function printerDisplayName(printer) {
  if (!printer) return "";
  return printer.name || printer.host || "Printer";
}

// ---------------------------------------------------------------- app settings

var DEFAULT_APP_SETTINGS = {
  gcodeWatchDir: "",
  gcodeWatchEnabled: false,
  deferScanWhilePrinting: true,
  lastSeenEpoch: 0
};

function normalizeAppSettings(raw) {
  var data = isPlainObject(raw) ? raw : {};
  var dir = trimmed(data.gcodeWatchDir).replace(/\/+$/, "");
  var epoch = parseInt(String(data.lastSeenEpoch), 10);
  return {
    gcodeWatchDir: dir,
    // Records only whether the user wants watching, NOT whether it can
    // currently run — GcodeWatcher pairs this with a non-empty directory.
    // Folding "no directory" into false here instead would make the flag
    // indistinguishable from an explicit opt-out after one normalize round
    // trip, so setting a folder for the first time would leave the watcher
    // silently switched off.
    gcodeWatchEnabled: data.gcodeWatchEnabled !== false,
    deferScanWhilePrinting: data.deferScanWhilePrinting !== false,
    lastSeenEpoch: isFinite(epoch) && epoch > 0 ? epoch : 0
  };
}

// Parses the plugin's own printers.json state file. Always returns a usable
// shape (empty list) rather than throwing, so a corrupt/missing file degrades
// to "no printers configured" instead of breaking the panel.
function parsePrinters(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    if (!isPlainObject(data)) return { activePrinterId: "", printers: [], settings: normalizeAppSettings(null) };
    var list = Array.isArray(data.printers) ? data.printers : [];
    var printers = [];
    for (var i = 0; i < list.length; i++) {
      var normalized = normalizePrinter(list[i], list[i] && list[i].id);
      if (normalized.id && normalized.host) printers.push(normalized);
    }
    var activePrinterId = trimmed(data.activePrinterId);
    if (!activePrinterId || !findPrinter(printers, activePrinterId)) {
      activePrinterId = printers.length > 0 ? printers[0].id : "";
    }
    return {
      activePrinterId: activePrinterId,
      printers: printers,
      settings: normalizeAppSettings(data.settings)
    };
  } catch (e) {
    return { activePrinterId: "", printers: [], settings: normalizeAppSettings(null) };
  }
}

function serializePrinters(state) {
  return JSON.stringify({
    activePrinterId: state.activePrinterId || "",
    settings: normalizeAppSettings(state.settings),
    printers: state.printers || []
  }, null, 2) + "\n";
}

function findPrinter(printers, id) {
  var list = printers || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id === id) return list[i];
  }
  return null;
}

// ---------------------------------------------------------------- URLs

// scheme argument lets the caller (Service.qml) pin a scheme it already
// pinned/knows works, or override it while probing http vs https. Falls back
// to the printer's own stored scheme, then plain http.
function effectiveScheme(printer, scheme) {
  if (scheme === "http" || scheme === "https") return scheme;
  if (printer.scheme === "http" || printer.scheme === "https") return printer.scheme;
  return "http";
}

function baseUrl(printer, scheme) {
  return effectiveScheme(printer, scheme) + "://" + printer.host + ":" + printer.port;
}

function objectsListUrl(printer, scheme) {
  return baseUrl(printer, scheme) + "/printer/objects/list";
}

function infoUrl(printer, scheme) {
  return baseUrl(printer, scheme) + "/printer/info";
}

function actionUrl(printer, path, scheme) {
  return baseUrl(printer, scheme) + path;
}

function gcodeActionUrl(printer, script, scheme) {
  return baseUrl(printer, scheme) + "/printer/gcode/script?script=" + encodeURIComponent(script);
}

function apiKeyHeaderArgs(printer) {
  return printer.apiKey ? ["-H", "X-Api-Key: " + printer.apiKey] : [];
}

// ---------------------------------------------------------------- gcode watching

// Exactly Moonraker's VALID_GCODE_EXTS (file_manager.py) — it rejects a
// metascan for anything else, so filtering here saves a guaranteed-failing
// request per non-gcode file that lands in the watched tree.
var GCODE_EXTS = [".gcode", ".g", ".gco", ".ufp", ".nc"];

function isGcodePath(path) {
  var lower = String(path || "").toLowerCase();
  for (var i = 0; i < GCODE_EXTS.length; i++) {
    if (lower.length > GCODE_EXTS[i].length && lower.slice(-GCODE_EXTS[i].length) === GCODE_EXTS[i]) return true;
  }
  return false;
}

// Maps an absolute local path under the watched directory onto the `filename`
// Moonraker wants — i.e. the path relative to its own gcodes root. This is the
// single place that mapping lives, and it only holds because the watched
// directory *is* the same share the printers mount as their gcodes root.
// Returns null for anything that shouldn't be scanned: outside the watch root,
// under a hidden segment (.Trash-1000/, .thumbs/), or not a gcode file.
function relativeGcodePath(watchDir, absPath) {
  var root = trimmed(watchDir).replace(/\/+$/, "");
  var full = trimmed(absPath);
  if (!root || !full) return null;
  if (full.slice(0, root.length + 1) !== root + "/") return null;
  var rel = full.slice(root.length + 1).replace(/^\/+/, "");
  if (!rel) return null;
  var segments = rel.split("/");
  for (var i = 0; i < segments.length; i++) {
    if (segments[i] === "" || segments[i].charAt(0) === ".") return null;
  }
  return isGcodePath(rel) ? rel : null;
}

function metascanUrl(printer, relPath, scheme) {
  return baseUrl(printer, scheme) + "/server/files/metascan?filename=" + encodeURIComponent(relPath);
}

// Long-lived stream of absolute paths, one per line. -r also picks up
// directories created after start (verified), --exclude '/\.' keeps the
// hidden trash/thumbnail trees out, and -q drops the banner lines so every
// line on stdout is a real path.
function inotifyArgs(dir) {
  return ["inotifywait", "-m", "-r", "-q", "-e", "close_write", "-e", "moved_to",
          "--exclude", "/\\.", "--format", "%w%f", dir];
}

// Catch-up sweep for files that landed while the shell wasn't running —
// inotify can only report what happens while it's watching.
function catchUpArgs(dir, sinceEpoch) {
  return ["find", dir, "-type", "f", "-newermt", "@" + Math.max(0, sinceEpoch || 0),
          "-not", "-path", "*/.*", "-print"];
}

// curl reports the HTTP status separately from the body, so a 404 ("this
// printer's gcodes root doesn't contain that file") is distinguishable from a
// genuine failure and can be reported as a skip rather than an error.
function parseMetascanResult(exitCode, httpCode, stdout) {
  var code = parseInt(String(httpCode), 10);
  if (exitCode !== 0 && !isFinite(code)) return { ok: false, notFound: false, error: "unreachable" };
  if (code === 200) return { ok: true, notFound: false, error: "" };
  if (code === 404) return { ok: false, notFound: true, error: "not on this printer" };
  var detail = "";
  try {
    var parsed = JSON.parse(String(stdout || ""));
    if (isPlainObject(parsed) && isPlainObject(parsed.error)) detail = trimmed(parsed.error.message);
  } catch (e) {
    detail = "";
  }
  return { ok: false, notFound: false, error: detail || ("HTTP " + (isFinite(code) ? code : "error")) };
}

// ---------------------------------------------------------------- webcams

// Moonraker's stream_url/snapshot_url are relative to the web UI's own host
// (crowsnest/nginx on the default web port), NOT Moonraker's own port —
// verified against a real install (stream/snapshot both 200 at
// http://<host>/webcam/..., refused on Moonraker's :7125). So this
// deliberately has no port, unlike baseUrl().
function mediaBaseUrl(printer, scheme) {
  return effectiveScheme(printer, scheme) + "://" + printer.host;
}

function webcamsUrl(printer, scheme) {
  return baseUrl(printer, scheme) + "/server/webcams/list";
}

// A config can store an already-absolute URL (e.g. a camera on a different
// host); only relative paths get joined to mediaBaseUrl.
function resolveWebcamUrl(printer, urlValue, scheme) {
  var value = trimmed(urlValue);
  if (value === "") return "";
  if (/^https?:\/\//i.test(value)) return value;
  if (value.charAt(0) !== "/") value = "/" + value;
  return mediaBaseUrl(printer, scheme) + value;
}

// Never throws: older Moonraker without this endpoint, or a printer with no
// cameras configured, both just mean "show nothing" rather than an error.
function parseWebcamsResponse(raw, printer, scheme) {
  try {
    var data = JSON.parse(String(raw || ""));
    var list = data && data.result && data.result.webcams;
    if (!Array.isArray(list)) return [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var cam = list[i];
      if (!isPlainObject(cam) || cam.enabled === false) continue;
      var streamUrl = resolveWebcamUrl(printer, cam.stream_url, scheme);
      if (!streamUrl) continue;
      out.push({
        name: trimmed(cam.name) || "Camera",
        streamUrl: streamUrl,
        snapshotUrl: resolveWebcamUrl(printer, cam.snapshot_url, scheme),
        flipHorizontal: cam.flip_horizontal === true,
        flipVertical: cam.flip_vertical === true,
        rotation: [0, 90, 180, 270].indexOf(cam.rotation) !== -1 ? cam.rotation : 0,
        aspectRatio: parseAspectRatio(cam.aspect_ratio)
      });
    }
    return out;
  } catch (e) {
    return [];
  }
}

// Validates one already-resolved webcam entry from printers.json (the shape
// parseWebcamsResponse produces), so a hand-edited or stale cache entry
// degrades to null (dropped) rather than feeding a malformed object into
// CameraView.
function normalizeCachedWebcam(cam) {
  if (!isPlainObject(cam)) return null;
  var streamUrl = trimmed(cam.streamUrl);
  if (!streamUrl) return null;
  return {
    name: trimmed(cam.name) || "Camera",
    streamUrl: streamUrl,
    snapshotUrl: trimmed(cam.snapshotUrl),
    flipHorizontal: cam.flipHorizontal === true,
    flipVertical: cam.flipVertical === true,
    rotation: [0, 90, 180, 270].indexOf(cam.rotation) !== -1 ? cam.rotation : 0,
    aspectRatio: typeof cam.aspectRatio === "number" && cam.aspectRatio > 0 ? cam.aspectRatio : 0.75
  };
}

// "4:3" -> 0.75 (height/width). Falls back to a plain 4:3 guess.
function parseAspectRatio(value) {
  var match = /^(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)$/.exec(trimmed(value));
  if (!match) return 0.75;
  var w = parseFloat(match[1]);
  var h = parseFloat(match[2]);
  return w > 0 && h > 0 ? h / w : 0.75;
}

// ---------------------------------------------------------------- sensors

// Klipper object names are always "<type>" or "<type> <name>" — the type
// alone tells you whether it's a controllable heater or a read-only
// sensor, without needing to guess per-printer or trust Moonraker's own
// `heaters` object (which hides a bme280's humidity/pressure behind its
// plain temperature_sensor wrapper — see MULTI_FIELD_TYPES below).
var HEATER_TYPES = { extruder: true, extruder1: true, extruder2: true, extruder3: true, heater_bed: true, heater_generic: true };
var SENSOR_ONLY_TYPES = {
  temperature_sensor: true, temperature_probe: true, temperature_host: true,
  bme280: true, bme680: true, htu21d: true, sht3x: true, sht4x: true, aht10: true, si7021: true, lm75: true
};
// Fixed by the Klipper sensor driver itself, not per-instance — anything
// not listed here only ever has one field (temperature), so it's selected
// as a whole object rather than needing a per-field row.
var MULTI_FIELD_TYPES = {
  bme280: ["temperature", "humidity", "pressure"],
  bme680: ["temperature", "humidity", "pressure", "gas"],
  htu21d: ["temperature", "humidity"],
  sht3x: ["temperature", "humidity"],
  sht4x: ["temperature", "humidity"],
  si7021: ["temperature", "humidity"],
  aht10: ["temperature", "humidity"]
};

function objectTypeOf(name) {
  var value = trimmed(name);
  var space = value.indexOf(" ");
  return space === -1 ? value : value.substring(0, space);
}

function objectFriendlyName(name) {
  var value = trimmed(name);
  var space = value.indexOf(" ");
  return space === -1 ? "" : value.substring(space + 1);
}

function isHeaterObject(name) { return !!HEATER_TYPES[objectTypeOf(name)]; }
function isSensorObject(name) { return isHeaterObject(name) || !!SENSOR_ONLY_TYPES[objectTypeOf(name)]; }

// null = single-field/heater (whole-object selection); else the list of
// fields this object's type can be individually selected by.
function selectableFieldsFor(name) {
  return MULTI_FIELD_TYPES[objectTypeOf(name)] || null;
}

function sensorLabel(name) {
  var type = objectTypeOf(name);
  var friendly = objectFriendlyName(name);
  if (type === "extruder") return friendly || "Hotend";
  if (type === "heater_bed") return "Bed";
  if (type === "heater_generic") return friendly || "Heater";
  if (friendly) return SENSOR_ONLY_TYPES[type] && MULTI_FIELD_TYPES[type] ? friendly + " (" + type.toUpperCase() + ")" : friendly;
  return type;
}

var FIELD_LABELS = { temperature: "Temp", humidity: "Humidity", pressure: "Pressure", gas: "Gas" };

function sensorFieldLabel(name, field) {
  var base = sensorLabel(name);
  if (!field) return base;
  return base + " — " + (FIELD_LABELS[field] || field);
}

// Never throws: older Moonraker, or a request that fails, just means
// "nothing discovered" rather than an error.
function parseObjectsList(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    var list = data && data.result && data.result.objects;
    return Array.isArray(list) ? list : [];
  } catch (e) {
    return [];
  }
}

function discoverSensors(objectNames) {
  var heaters = [];
  var sensors = [];
  for (var i = 0; i < objectNames.length; i++) {
    var name = objectNames[i];
    if (isHeaterObject(name)) heaters.push(name);
    else if (isSensorObject(name)) sensors.push(name);
  }
  return { heaters: heaters, sensors: sensors };
}

// Whichever of temperature/target/humidity/pressure are actually present on
// a raw status object for one printer object (e.g. status.extruder,
// status["bme280 Ambient"]). null if none of them are.
function extractSensorReading(rawObject) {
  if (!isPlainObject(rawObject)) return null;
  var reading = {};
  var found = false;
  ["temperature", "target", "humidity", "pressure"].forEach(function(key) {
    if (typeof rawObject[key] === "number") { reading[key] = rawObject[key]; found = true; }
  });
  return found ? reading : null;
}

// The combined temp/target reading for a whole-object selection (heaters,
// single-field sensors) — e.g. "47° / 0°" or just "24°" with no target.
function formatSensorReading(reading) {
  if (!reading || typeof reading.temperature !== "number") return "—";
  var text = Math.round(reading.temperature) + "°";
  if (typeof reading.target === "number") text += " / " + Math.round(reading.target) + "°";
  return text;
}

// One selection entry's display value: the temp/target combo when `field`
// is omitted, else just that one field in its own unit.
function formatSensorEntry(reading, field) {
  if (!reading) return "—";
  if (!field) return formatSensorReading(reading);
  var value = reading[field];
  if (typeof value !== "number") return "—";
  if (field === "humidity") return Math.round(value) + "% RH";
  if (field === "pressure") return Math.round(value) + " hPa";
  if (field === "temperature") return Math.round(value) + "°";
  return String(value);
}

// ---------------------------------------------------------------- status

var BUSY_STATES = { printing: true, paused: true };
var TERMINAL_STATES = { complete: true, cancelled: true, error: true };

// Normalizes a raw Moonraker status object — the `result.status` shape
// shared by /printer/objects/query's response AND printer.objects.subscribe's
// success reply over the websocket — into the flat shape the panel renders.
// Klipper being up but not "ready" (still booting, or shut down after an
// error) takes priority over whatever print_stats last reported, since that
// state is stale the moment Klippy itself isn't ready. Pure: takes an
// already-parsed object, never touches JSON directly, so both the one-shot
// HTTP path and the websocket delta-merge path can share it.
//
// `sensorObjectNames` is the printer's own configured selection (unique
// object names, not selection entries — see PrinterConnection) — sensors is
// keyed by object, one entry per subscribed object, regardless of how many
// of that object's fields are actually displayed.
function extractStatus(status, sensorObjectNames) {
  if (!isPlainObject(status)) return { ok: false, error: "Unexpected response from Moonraker" };

  var webhooks = status.webhooks || {};
  var klippyState = trimmed(webhooks.state) || "unknown";
  var names = sensorObjectNames || [];

  if (klippyState !== "ready") {
    return {
      ok: true,
      state: "klippy_" + klippyState,
      message: trimmed(webhooks.state_message) || "Klipper is " + klippyState,
      progress: 0,
      filename: "",
      printDurationSec: 0,
      sensors: {}
    };
  }

  var printStats = status.print_stats || {};
  var displayStatus = status.display_status || {};
  var virtualSdcard = status.virtual_sdcard || {};

  var progressFraction = displayStatus.progress;
  if (progressFraction === undefined || progressFraction === null) progressFraction = virtualSdcard.progress;

  var sensors = {};
  for (var i = 0; i < names.length; i++) {
    var reading = extractSensorReading(status[names[i]]);
    if (reading) sensors[names[i]] = reading;
  }

  return {
    ok: true,
    state: trimmed(printStats.state) || "standby",
    message: trimmed(printStats.message) || trimmed(displayStatus.message),
    progress: clampInt(Math.round((Number(progressFraction) || 0) * 100), 0, 0, 100),
    filename: trimmed(printStats.filename),
    printDurationSec: Number(printStats.print_duration) || 0,
    sensors: sensors
  };
}

// Shallow-merges a partial `notify_status_update` delta into the last known
// full set of status objects. Moonraker only sends fields that changed
// (e.g. {extruder: {temperature: 210.1}} with no `target`), so a naive
// object replace would blank out everything the delta didn't mention.
function mergeStatusObjects(current, delta) {
  var base = isPlainObject(current) ? current : {};
  var patch = isPlainObject(delta) ? delta : {};
  var merged = {};
  for (var key in base) merged[key] = base[key];
  for (var deltaKey in patch) {
    var existing = isPlainObject(merged[deltaKey]) ? merged[deltaKey] : {};
    var patchValue = patch[deltaKey];
    merged[deltaKey] = isPlainObject(patchValue) ? Object.assign({}, existing, patchValue) : patchValue;
  }
  return merged;
}

// A raw text frame from the websocket, if it's a notify_status_update push.
// Returns null for anything else (other notify_* methods, the subscribe
// response, malformed JSON) so the caller can just skip what it doesn't
// recognize.
function parseNotifyStatusUpdate(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    if (data.method !== "notify_status_update") return null;
    var delta = data.params && data.params[0];
    return isPlainObject(delta) ? delta : null;
  } catch (e) {
    return null;
  }
}

var BASE_SUBSCRIBE_OBJECTS = ["webhooks", "print_stats", "display_status", "virtual_sdcard"];

// `sensorObjectNames` folds in the printer's own configured selection
// (unique object names) alongside the fixed set every printer needs
// regardless of what it displays.
function subscribeRequestJson(sensorObjectNames) {
  var objects = {};
  BASE_SUBSCRIBE_OBJECTS.forEach(function(name) { objects[name] = null; });
  (sensorObjectNames || []).forEach(function(name) { objects[name] = null; });
  return JSON.stringify({
    jsonrpc: "2.0",
    method: "printer.objects.subscribe",
    params: { objects: objects },
    id: 1
  });
}

// The subscribe response has an id matching subscribeRequestJson's (1) and a
// result.status — same shape extractStatus already understands. Returns
// null for anything else (a notify_* push, an error reply).
function parseSubscribeResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    if (data.id !== 1 || !data.result) return null;
    var status = data.result.status;
    return isPlainObject(status) ? status : null;
  } catch (e) {
    return null;
  }
}

function websocketUrl(printer, scheme) {
  var wsScheme = effectiveScheme(printer, scheme) === "https" ? "wss" : "ws";
  var url = wsScheme + "://" + printer.host + ":" + printer.port + "/websocket";
  // A websocket handshake can't carry a custom header the way the HTTP paths
  // send X-Api-Key, so Moonraker accepts the key as a query param instead —
  // the same workaround browsers need for the same reason.
  if (printer.apiKey) url += "?token=" + encodeURIComponent(printer.apiKey);
  return url;
}

function parseInfoResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    var result = data && data.result;
    if (!isPlainObject(result)) return { ok: false };
    return {
      ok: true,
      state: trimmed(result.state) || "unknown",
      message: trimmed(result.state_message),
      hostname: trimmed(result.hostname)
    };
  } catch (e) {
    return { ok: false };
  }
}

// Order to probe an unspecified scheme in: Moonraker's own listener is plain
// HTTP in the overwhelming majority of setups (TLS, when present at all, is
// usually a reverse proxy in front of the web UI, not Moonraker's API port
// itself), so try that first and only fall back to https.
var SCHEME_PROBE_ORDER = ["http", "https"];

// Whether there is a job to report progress on. Progress, elapsed and ETA are
// all meaningless otherwise: an idle printer reports 0%, and a bar sitting at
// zero next to "Ready" reads as a stalled print rather than as no print.
function jobInProgress(state) {
  return state === "printing" || state === "paused";
}

function stateLabel(state) {
  switch (state) {
    case "standby": return "Ready";
    case "printing": return "Printing";
    case "paused": return "Paused";
    case "complete": return "Complete";
    case "cancelled": return "Cancelled";
    case "error": return "Print error";
    case "klippy_error": return "Klipper error";
    case "klippy_shutdown": return "Klipper shut down";
    case "klippy_startup": return "Klipper starting";
    case "offline": return "Unreachable";
    default: return state ? state : "Unknown";
  }
}

// Icon/pill tint bucket for a given state — kept as a small enum so QML picks
// the actual colors from the shared Style/Color singletons.
function stateTone(state) {
  if (state === "printing") return "active";
  if (state === "error" || state === "klippy_error" || state === "offline") return "urgent";
  if (state === "paused" || state.indexOf("klippy_") === 0) return "warning";
  return "normal";
}

function formatDuration(totalSeconds) {
  var seconds = Math.max(0, Math.round(Number(totalSeconds) || 0));
  var hours = Math.floor(seconds / 3600);
  var minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return hours + "h " + minutes + "m";
  if (minutes > 0) return minutes + "m";
  return seconds + "s";
}

// Simple linear projection from elapsed time and current progress. Returns
// null when there isn't enough signal yet (no progress, or not printing).
function estimateRemainingSec(progressPercent, elapsedSec) {
  if (!progressPercent || progressPercent <= 0 || progressPercent >= 100) return null;
  if (!elapsedSec || elapsedSec <= 0) return null;
  var totalEstimate = (elapsedSec / progressPercent) * 100;
  return Math.max(0, Math.round(totalEstimate - elapsedSec));
}

// Decides whether a state transition warrants a one-shot desktop notification.
// Only fires leaving a busy (printing/paused) state for a terminal one, so
// polling noise and the initial load (prevState === "") never notify.
function notificationForTransition(prevState, nextState, printerName, filename, message) {
  if (!prevState || prevState === nextState) return null;
  if (!BUSY_STATES[prevState] || !TERMINAL_STATES[nextState]) return null;

  var subject = filename ? " — " + filename : "";
  if (nextState === "complete") {
    return { urgency: "normal", headline: printerName + ": print complete", body: (filename || "Print") + " finished" };
  }
  if (nextState === "cancelled") {
    return { urgency: "normal", headline: printerName + ": print cancelled", body: "Cancelled" + subject };
  }
  return { urgency: "critical", headline: printerName + ": print error", body: message || ("Failed" + subject) };
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_PORT: DEFAULT_PORT,
    SCHEME_PROBE_ORDER: SCHEME_PROBE_ORDER,
    parseHostInput: parseHostInput,
    normalizePrinter: normalizePrinter,
    clonePrinterWith: clonePrinterWith,
    printerDisplayName: printerDisplayName,
    parsePrinters: parsePrinters,
    serializePrinters: serializePrinters,
    findPrinter: findPrinter,
    baseUrl: baseUrl,
    objectsListUrl: objectsListUrl,
    infoUrl: infoUrl,
    actionUrl: actionUrl,
    gcodeActionUrl: gcodeActionUrl,
    apiKeyHeaderArgs: apiKeyHeaderArgs,
    mediaBaseUrl: mediaBaseUrl,
    webcamsUrl: webcamsUrl,
    resolveWebcamUrl: resolveWebcamUrl,
    parseWebcamsResponse: parseWebcamsResponse,
    parseAspectRatio: parseAspectRatio,
    normalizeDisplaySensorEntry: normalizeDisplaySensorEntry,
    cameraTiles: cameraTiles,
    gridColumnsFor: gridColumnsFor,
    gridRowsFor: gridRowsFor,
    VIDEO_OVERLAY_FIELDS: VIDEO_OVERLAY_FIELDS,
    DEFAULT_VIDEO_OVERLAYS: DEFAULT_VIDEO_OVERLAYS,
    isVideoOverlayKey: isVideoOverlayKey,
    videoOverlayLabel: videoOverlayLabel,
    normalizeVideoOverlays: normalizeVideoOverlays,
    DEFAULT_APP_SETTINGS: DEFAULT_APP_SETTINGS,
    normalizeAppSettings: normalizeAppSettings,
    GCODE_EXTS: GCODE_EXTS,
    isGcodePath: isGcodePath,
    relativeGcodePath: relativeGcodePath,
    metascanUrl: metascanUrl,
    inotifyArgs: inotifyArgs,
    catchUpArgs: catchUpArgs,
    parseMetascanResult: parseMetascanResult,
    objectTypeOf: objectTypeOf,
    isHeaterObject: isHeaterObject,
    isSensorObject: isSensorObject,
    selectableFieldsFor: selectableFieldsFor,
    sensorLabel: sensorLabel,
    sensorFieldLabel: sensorFieldLabel,
    parseObjectsList: parseObjectsList,
    discoverSensors: discoverSensors,
    extractSensorReading: extractSensorReading,
    formatSensorReading: formatSensorReading,
    formatSensorEntry: formatSensorEntry,
    extractStatus: extractStatus,
    mergeStatusObjects: mergeStatusObjects,
    parseNotifyStatusUpdate: parseNotifyStatusUpdate,
    subscribeRequestJson: subscribeRequestJson,
    parseSubscribeResponse: parseSubscribeResponse,
    websocketUrl: websocketUrl,
    parseInfoResponse: parseInfoResponse,
    jobInProgress: jobInProgress,
    stateLabel: stateLabel,
    stateTone: stateTone,
    formatDuration: formatDuration,
    estimateRemainingSec: estimateRemainingSec,
    notificationForTransition: notificationForTransition
  };
}
