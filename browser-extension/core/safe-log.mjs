/**
 * Structured diagnostics without raw session IDs, full URLs, tokens, or routing secrets.
 */

/**
 * @typedef {{ level: string, event: string, ts: number, fields: Record<string, string|number|boolean|null|undefined> }} LogRecord
 */

const FORBIDDEN_FIELD_NAMES = new Set([
  'sessionid',
  'rawsessionid',
  'session',
  'url',
  'fullurl',
  'href',
  'token',
  'notifytoken',
  'routesecret',
  'authorization',
  'password',
  'cookie',
]);

/**
 * @param {string} name
 * @returns {boolean}
 */
function isForbiddenField(name) {
  const n = String(name).toLowerCase().replace(/[^a-z0-9]/g, '');
  return FORBIDDEN_FIELD_NAMES.has(n);
}

/**
 * @param {unknown} value
 * @returns {boolean}
 */
export function looksLikeSessionOrUrl(value) {
  if (typeof value !== 'string') return false;
  if (/https?:\/\//i.test(value)) return true;
  if (/[?&]session=/i.test(value)) return true;
  // Long opaque session-looking strings in free-form fields are blocked if labeled poorly.
  return false;
}

/**
 * Create a logger that records to an optional sink (tests) and console (browser).
 * @param {{ sink?: (rec: LogRecord) => void, console?: Pick<Console, 'info'|'warn'|'error'|'debug'> }} [opts]
 */
export function createSafeLogger(opts = {}) {
  const sink = opts.sink;
  const cons = opts.console ?? globalThis.console;

  /**
   * @param {string} level
   * @param {string} event
   * @param {Record<string, unknown>} [fields]
   */
  function write(level, event, fields = {}) {
    /** @type {Record<string, string|number|boolean|null|undefined>} */
    const safe = {};
    for (const [k, v] of Object.entries(fields)) {
      if (isForbiddenField(k)) continue;
      if (typeof v === 'string' && looksLikeSessionOrUrl(v)) {
        safe[k] = '[redacted]';
        continue;
      }
      if (v == null || typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        safe[k] = /** @type {string|number|boolean|null|undefined} */ (v);
      } else {
        safe[k] = String(v);
      }
    }

    /** @type {LogRecord} */
    const rec = { level, event, ts: Date.now(), fields: safe };
    if (sink) sink(rec);

    const line = `[pi-notify-ext] ${event} ${JSON.stringify(safe)}`;
    if (level === 'error' && cons?.error) cons.error(line);
    else if (level === 'warn' && cons?.warn) cons.warn(line);
    else if (level === 'debug' && cons?.debug) cons.debug(line);
    else if (cons?.info) cons.info(line);
  }

  return {
    info: (event, fields) => write('info', event, fields),
    warn: (event, fields) => write('warn', event, fields),
    error: (event, fields) => write('error', event, fields),
    debug: (event, fields) => write('debug', event, fields),
  };
}

/**
 * Assert a log payload does not contain forbidden material (for tests).
 * @param {unknown} payload
 * @returns {{ ok: true } | { ok: false, reason: string }}
 */
export function assertNoSensitiveLogMaterial(payload) {
  const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
  if (/https?:\/\//i.test(text)) {
    return { ok: false, reason: 'contains-url' };
  }
  if (/[?&]session=/i.test(text)) {
    return { ok: false, reason: 'contains-session-query' };
  }
  // Detect UUID-shaped session ids only when labeled as session — raw hex routing keys are OK.
  if (/"sessionId"\s*:/i.test(text) || /"rawSessionId"\s*:/i.test(text)) {
    return { ok: false, reason: 'contains-session-field' };
  }
  if (/"token"\s*:/i.test(text) && !/"fingerprint"/i.test(text)) {
    // allow non-token fields; block explicit token
    if (/"token"\s*:\s*"[^"]+"/i.test(text)) {
      return { ok: false, reason: 'contains-token-field' };
    }
  }
  return { ok: true };
}
