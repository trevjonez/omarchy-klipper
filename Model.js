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
    apiKey: trimmed(p.apiKey)
  };
}

function printerDisplayName(printer) {
  if (!printer) return "";
  return printer.name || printer.host || "Printer";
}

// Parses the plugin's own printers.json state file. Always returns a usable
// shape (empty list) rather than throwing, so a corrupt/missing file degrades
// to "no printers configured" instead of breaking the panel.
function parsePrinters(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    if (!isPlainObject(data)) return { activePrinterId: "", printers: [] };
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
    return { activePrinterId: activePrinterId, printers: printers };
  } catch (e) {
    return { activePrinterId: "", printers: [] };
  }
}

function serializePrinters(state) {
  return JSON.stringify({
    activePrinterId: state.activePrinterId || "",
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

function queryUrl(printer, scheme) {
  return baseUrl(printer, scheme) + "/printer/objects/query"
    + "?webhooks&print_stats&display_status&virtual_sdcard&extruder&heater_bed";
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

// "4:3" -> 0.75 (height/width). Falls back to a plain 4:3 guess.
function parseAspectRatio(value) {
  var match = /^(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)$/.exec(trimmed(value));
  if (!match) return 0.75;
  var w = parseFloat(match[1]);
  var h = parseFloat(match[2]);
  return w > 0 && h > 0 ? h / w : 0.75;
}

// ---------------------------------------------------------------- status

var BUSY_STATES = { printing: true, paused: true };
var TERMINAL_STATES = { complete: true, cancelled: true, error: true };

// Normalizes a /printer/objects/query response into the flat shape the panel
// renders. Klipper being up but not "ready" (still booting, or shut down
// after an error) takes priority over whatever print_stats last reported,
// since that state is stale the moment Klippy itself isn't ready.
function parseStatusResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    var status = data && data.result && data.result.status;
    if (!isPlainObject(status)) return { ok: false, error: "Unexpected response from Moonraker" };

    var webhooks = status.webhooks || {};
    var klippyState = trimmed(webhooks.state) || "unknown";

    if (klippyState !== "ready") {
      return {
        ok: true,
        state: "klippy_" + klippyState,
        message: trimmed(webhooks.state_message) || "Klipper is " + klippyState,
        progress: 0,
        filename: "",
        printDurationSec: 0,
        hotend: readHeater(null),
        bed: readHeater(null)
      };
    }

    var printStats = status.print_stats || {};
    var displayStatus = status.display_status || {};
    var virtualSdcard = status.virtual_sdcard || {};

    var progressFraction = displayStatus.progress;
    if (progressFraction === undefined || progressFraction === null) progressFraction = virtualSdcard.progress;

    return {
      ok: true,
      state: trimmed(printStats.state) || "standby",
      message: trimmed(printStats.message) || trimmed(displayStatus.message),
      progress: clampInt(Math.round((Number(progressFraction) || 0) * 100), 0, 0, 100),
      filename: trimmed(printStats.filename),
      printDurationSec: Number(printStats.print_duration) || 0,
      hotend: readHeater(status.extruder),
      bed: readHeater(status.heater_bed)
    };
  } catch (e) {
    return { ok: false, error: "Could not parse Moonraker response" };
  }
}

function readHeater(heater) {
  if (!isPlainObject(heater)) return { actual: null, target: null };
  return {
    actual: typeof heater.temperature === "number" ? heater.temperature : null,
    target: typeof heater.target === "number" ? heater.target : null
  };
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
    printerDisplayName: printerDisplayName,
    parsePrinters: parsePrinters,
    serializePrinters: serializePrinters,
    findPrinter: findPrinter,
    baseUrl: baseUrl,
    queryUrl: queryUrl,
    infoUrl: infoUrl,
    actionUrl: actionUrl,
    gcodeActionUrl: gcodeActionUrl,
    apiKeyHeaderArgs: apiKeyHeaderArgs,
    mediaBaseUrl: mediaBaseUrl,
    webcamsUrl: webcamsUrl,
    resolveWebcamUrl: resolveWebcamUrl,
    parseWebcamsResponse: parseWebcamsResponse,
    parseAspectRatio: parseAspectRatio,
    parseStatusResponse: parseStatusResponse,
    parseInfoResponse: parseInfoResponse,
    stateLabel: stateLabel,
    stateTone: stateTone,
    formatDuration: formatDuration,
    estimateRemainingSec: estimateRemainingSec,
    notificationForTransition: notificationForTransition
  };
}
