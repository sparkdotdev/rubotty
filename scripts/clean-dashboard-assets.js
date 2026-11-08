// Remove retired generated assets when rebuilding an existing checkout.
// Only these known build outputs are removed; runtime data is outside this directory.
const fs = require("fs");
const path = require("path");
const publicDir = path.join(process.cwd(), "lib/rubotty/dashboard/public");
const retired = [
  "theme-series-a.js",
  "theme-code-monkey.js", "theme-code-monkey.css",
  "theme-command-centre.js", "theme-command-centre.css",
  "theme-poorly-drawn-scribbles.js", "theme-poorly-drawn-scribbles.css",
  "swatch-ruby.css", "swatch-forest.css", "swatch-harbour.css",
  "chart-engine-in-house.js", "chart-engine-rough-viz.js", "rough-viz.min.js"
];
for (const name of retired) fs.rmSync(path.join(publicDir, name), { force: true });
const fontDir = path.join(publicDir, "fonts");
for (const name of ["comic-neue-latin-400-normal.woff2", "comic-neue-latin-700-normal.woff2", "OFL.txt"]) {
  fs.rmSync(path.join(fontDir, name), { force: true });
}
