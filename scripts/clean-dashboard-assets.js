// Remove retired generated assets when rebuilding an existing checkout.
// Only these known build outputs are removed; runtime data is outside this directory.
const fs = require("fs");
const path = require("path");
const publicDir = path.join(process.cwd(), "lib/rubotty/dashboard/public");
const retired = /^(?:theme-.+\.(?:js|css)|swatch-(?:ruby|forest|harbour)\.css|chart-engine-.+\.js|rough-viz\.min\.js)$/;
if (fs.existsSync(publicDir)) {
  for (const entry of fs.readdirSync(publicDir, { withFileTypes: true })) {
    if (!entry.isDirectory() && retired.test(entry.name)) fs.rmSync(path.join(publicDir, entry.name), { force: true });
  }
}
const fontDir = path.join(publicDir, "fonts");
for (const name of ["comic-neue-latin-400-normal.woff2", "comic-neue-latin-700-normal.woff2", "OFL.txt"]) {
  fs.rmSync(path.join(fontDir, name), { force: true });
}
