"use strict";
// Node host for the `.pragma library` files under data/amp and plugin/basin:
// loads the same source QML imports and returns its top-level names.
const fs = require("node:fs");
const path = require("node:path");

function loadPragma(file) {
    const src = fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*$/m, "");
    const names = [];
    for (const m of src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)) names.push(m[1]);
    // eslint-disable-next-line no-new-func
    return new Function(`${src}\nreturn { ${names.join(", ")} };`)();
}

const ROOT = path.join(__dirname, "..", "..");
const amp = loadPragma(path.join(__dirname, "amp.js"));
const basin = loadPragma(path.join(ROOT, "plugin", "basin", "basin.js"));

module.exports = { amp, basin, loadPragma, ROOT };
