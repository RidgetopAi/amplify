"use strict";
// Node host for data/mandrel.js. Loads the same file QML imports (stripping the
// `.pragma library` line) and returns its top-level functions and constants,
// then adds a fetch-based transport, timers, and env config.
const fs = require("node:fs");
const path = require("node:path");

const SRC = path.join(__dirname, "mandrel.js");

function source() {
    return fs.readFileSync(SRC, "utf8").replace(/^\.pragma library\s*$/m, "");
}

function exportedNames(src) {
    const names = [];
    for (const m of src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)) names.push(m[1]);
    return names;
}

function load() {
    const src = source();
    // eslint-disable-next-line no-new-func
    return new Function(`${src}\nreturn { ${exportedNames(src).join(", ")} };`)();
}

const M = load();

// The config file's text, or null when it is missing or unreadable (replay, never a throw).
function readConfigFile(file) {
    if (!file) return null;
    try { return fs.readFileSync(file, "utf8"); } catch { return null; }
}

function config(env) {
    // env-read: MANDREL_URL, MANDREL_VIEWER_TOKEN (the only variables the data layer reads), and XDG_CONFIG_HOME, HOME to find the user's config file (M.configFilePath)
    const e = env || { MANDREL_URL: process.env.MANDREL_URL, MANDREL_VIEWER_TOKEN: process.env.MANDREL_VIEWER_TOKEN, XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME, HOME: process.env.HOME };
    return M.configFrom(e, readConfigFile(M.configFilePath(e)));
}

const timers = {
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (h) => clearTimeout(h),
};

function fetchTransport() {
    return {
        async getJson(url, headers) {
            const r = await fetch(url, { headers });
            if (!r.ok) throw new Error(`HTTP ${r.status} ${url}`);
            return r.json();
        },
        async postJson(url, headers, body) {
            const r = await fetch(url, {
                method: "POST",
                headers: { ...headers, "Content-Type": "application/json" },
                body: JSON.stringify(body || {}),
            });
            if (!r.ok) throw new Error(`HTTP ${r.status} ${url}`);
            return r.json();
        },
        openStream(url, headers, onChunk, onEnd) {
            const ac = new AbortController();
            let done = false;
            const finish = (err) => { if (!done) { done = true; onEnd(err || null); } };
            (async () => {
                try {
                    const r = await fetch(url, { headers, signal: ac.signal });
                    if (!r.ok) throw new Error(`HTTP ${r.status}`);
                    const dec = new TextDecoder();
                    for await (const chunk of r.body) onChunk(dec.decode(chunk, { stream: true }));
                    finish(null);
                } catch (err) {
                    if (!ac.signal.aborted) finish(err);
                }
            })();
            return { close() { done = true; ac.abort(); } };
        },
    };
}

function loadSnapshot(file) {
    return JSON.parse(fs.readFileSync(file || path.join(__dirname, "..", "fixtures", "amplify-snapshot.json"), "utf8"));
}

module.exports = { M, config, timers, fetchTransport, loadSnapshot, load, source, exportedNames };
