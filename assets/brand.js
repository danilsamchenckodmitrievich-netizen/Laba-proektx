/* Axiora: storage migration and versioned offline result codes. */
(function (root) {
  'use strict';
  // Compatibility identifiers are intentionally isolated here. Do not rename them:
  // existing installations and previously issued result codes depend on these bytes.
  const LEGACY = Object.freeze({prefix: 'lab-sirius-', salt: 'lab-sirius-7', code: 'LS'});
  const PREFIX = 'axiora-';
  const SALT = 'axiora-result-2';

  function migrateStorage(storage) {
    if (!storage || storage.getItem(PREFIX + 'migration-v1') === 'done') return;
    const keys = [];
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i);
      if (key && key.startsWith(LEGACY.prefix)) keys.push(key);
    }
    for (const oldKey of keys) {
      const newKey = PREFIX + oldKey.slice(LEGACY.prefix.length);
      const value = storage.getItem(oldKey);
      // The current installation wins if both versions have written a value.
      if (storage.getItem(newKey) === null && value !== null) storage.setItem(newKey, value);
      // Never discard a source value until a successful destination write.
      if (storage.getItem(newKey) !== null) storage.removeItem(oldKey);
    }
    storage.setItem(PREFIX + 'migration-v1', 'done');
  }

  function migrate(win) {
    // Private browsing, denied access and a full quota must not stop the site.
    for (const name of ['localStorage', 'sessionStorage']) {
      try { migrateStorage(win[name]); } catch (_) { /* Retry on the next load. */ }
    }
  }

  function checksum(value) {
    let hash = 0x811c9dc5;
    for (let i = 0; i < value.length; i++) {
      hash ^= value.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return hash.toString(36);
  }

  function encode(value) {
    let binary = '';
    new TextEncoder().encode(JSON.stringify(value)).forEach(byte => binary += String.fromCharCode(byte));
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function decode(value) {
    let text = value.replace(/-/g, '+').replace(/_/g, '/');
    while (text.length % 4) text += '=';
    const binary = atob(text);
    const bytes = Uint8Array.from(binary, ch => ch.charCodeAt(0));
    return JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
  }

  function makeCode(result) {
    const payload = encode(Object.assign({}, result, {v: 2}));
    return 'AX-' + payload + '-' + checksum(payload + SALT);
  }

  function readCode(value) {
    const match = String(value).trim().match(/^(AX|LS)-([A-Za-z0-9_-]+)-([0-9a-z]+)$/);
    if (!match) return null;
    try {
      const result = decode(match[2]);
      const legacy = match[1] === LEGACY.code;
      if (!result || typeof result !== 'object' || Array.isArray(result) || result.v !== (legacy ? 1 : 2)) return null;
      return {o: result, ok: checksum(match[2] + (legacy ? LEGACY.salt : SALT)) === match[3]};
    } catch (_) { return null; }
  }

  function normalizeBackup(backup) {
    if (!backup || typeof backup !== 'object' || Array.isArray(backup)) return backup;
    if (backup.format === LEGACY.prefix + 'backup-1') return Object.assign({}, backup, {format: PREFIX + 'backup-1'});
    return backup;
  }

  const api = Object.freeze({migrate, migrateStorage, makeCode, readCode, normalizeBackup});
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.AxioraBrand = api;
})(globalThis);
