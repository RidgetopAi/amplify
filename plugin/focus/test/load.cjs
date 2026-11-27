"use strict";
// Loads plugin/focus/meridian.js (a QML `.pragma library`) for node:test, the same
// way plugin/orbs/test/load.cjs loads orbs.js.
const fs = require("node:fs");
const path = require("node:path");

const src = fs.readFileSync(path.join(__dirname, "..", "meridian.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const names = [...src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)].map((m) => m[1]);
// eslint-disable-next-line no-new-func
module.exports = new Function(`${src}\nreturn { ${names.join(", ")} };`)();
