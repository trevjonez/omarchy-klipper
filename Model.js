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

// Normalizes one printer entry, filling in a stable shape so the rest of the
// plugin never has to guard against missing fields.
function normalizePrinter(raw, fallbackId) {
  var p = isPlainObject(raw) ? raw : {};
  return {
    id: trimmed(p.id) || trimmed(fallbackId) || "",
    name: trimmed(p.name),
    host: trimmed(p.host),
    port: clampInt(p.port, DEFAULT_PORT, 1, 65535),
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

function baseUrl(printer) {
  return "http://" + printer.host + ":" + printer.port;
}

function queryUrl(printer) {
  return baseUrl(printer) + "/printer/objects/query"
    + "?webhooks&print_stats&display_status&virtual_sdcard&extruder&heater_bed";
}

function infoUrl(printer) {
  return baseUrl(printer) + "/printer/info";
}

function actionUrl(printer, path) {
  return baseUrl(printer) + path;
}

function gcodeActionUrl(printer, script) {
  return baseUrl(printer) + "/printer/gcode/script?script=" + encodeURIComponent(script);
}

function apiKeyHeaderArgs(printer) {
  return printer.apiKey ? ["-H", "X-Api-Key: " + printer.apiKey] : [];
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
    return { ok: true, state: trimmed(result.state) || "unknown", message: trimmed(result.state_message) };
  } catch (e) {
    return { ok: false };
  }
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
    parseStatusResponse: parseStatusResponse,
    parseInfoResponse: parseInfoResponse,
    stateLabel: stateLabel,
    stateTone: stateTone,
    formatDuration: formatDuration,
    estimateRemainingSec: estimateRemainingSec,
    notificationForTransition: notificationForTransition
  };
}
