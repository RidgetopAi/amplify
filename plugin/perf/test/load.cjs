"use strict";
// Loads a QML `.pragma library` file for node:test, the way data/node.cjs loads data/mandrel.js.
const fs = require("node:fs");
const path = require("node:path");

module.exports = function load(file) {
  const src = fs.readFileSync(path.resolve(__dirname, file), "utf8").replace(/^\.pragma library\s*$/m, "");
  const names = [...src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)].map((m) => m[1]);
  // eslint-disable-next-line no-new-func
  return new Function(`${src}\nreturn { ${names.join(", ")} };`)();
};
