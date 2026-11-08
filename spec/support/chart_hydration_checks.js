"use strict";

const fs = require("fs");
const vm = require("vm");
const [, , bundlePath, casesPath] = process.argv;
const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));
const warnings = [];
const figures = cases.map((item) => ({
  outerHTML: item.original,
  querySelector: () => ({ textContent: item.title })
}));
const elements = cases.map((item, index) => ({
  dataset: { chart: item.rows, shape: item.shape },
  closest: () => figures[index]
}));
// One malformed figure must not prevent the valid charts after it from drawing.
elements.unshift({ dataset: { chart: "{broken", shape: "time_series" } });
const sandbox = {
  console: { warn: (warning) => warnings.push(String(warning)) },
  document: { readyState: "complete", querySelectorAll: () => elements }
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(bundlePath, "utf8"), sandbox, { filename: "chart-engine.js" });
process.stdout.write(JSON.stringify({ html: figures.map((figure) => figure.outerHTML), warnings }));
