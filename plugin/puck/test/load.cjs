"use strict";
// Loads plugin/puck/puck.js (a QML `.pragma library`) for node:test, as plugin/orbs/test/load.cjs does.
const fs = require("node:fs");
const path = require("node:path");

const src = fs.readFileSync(path.join(__dirname, "..", "puck.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const names = [...src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)].map((m) => m[1]);
// eslint-disable-next-line no-new-func
module.exports = new Function(`${src}\nreturn { ${names.join(", ")} };`)();
