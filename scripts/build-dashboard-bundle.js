// Bundle browser code together with the reviewed upstream notices it requires.
const fs = require("node:fs");
const path = require("node:path");
const esbuild = require("esbuild");

const root = process.cwd();
const [entry, destination, globalName] = process.argv.slice(2);
if (!entry || !destination) throw new Error("Expected an entry point and output file");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "licenses/dashboard-browser.json"), "utf8"));
const reviewed = new Map(manifest.packages.map((item) => [item.name, item]));
if (manifest.schema_version !== 1 || reviewed.size !== manifest.packages.length) {
  throw new Error("Invalid browser notice inventory");
}

const result = esbuild.buildSync({
  absWorkingDir: root,
  entryPoints: [entry],
  outfile: destination,
  bundle: true,
  minify: true,
  format: "iife",
  ...(globalName ? { globalName } : {}),
  metafile: true,
  write: false
});

for (const output of result.outputFiles) {
  const relative = path.relative(root, output.path).split(path.sep).join("/");
  const included = result.metafile.outputs[relative];
  if (!included) throw new Error("Missing bundle input inventory: " + relative);
  const packages = new Map();
  for (const [filename, contribution] of Object.entries(included.inputs)) {
    if (!contribution.bytesInOutput) continue;
    const parts = filename.split("/");
    const marker = parts.lastIndexOf("node_modules");
    if (marker < 0) continue;
    const count = parts[marker + 1].startsWith("@") ? 3 : 2;
    const directory = path.resolve(root, parts.slice(0, marker + count).join("/"));
    const installed = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
    const item = reviewed.get(installed.name);
    if (!item || item.version !== installed.version) {
      throw new Error("Review the browser licence notice for " + installed.name + " " + installed.version);
    }
    const notice = fs.readFileSync(path.join(root, item.notice));
    if (!notice.equals(fs.readFileSync(path.join(directory, item.source_notice)))) {
      throw new Error("Browser licence notice differs from upstream: " + installed.name);
    }
    if (notice.includes(Buffer.from("*/"))) throw new Error("Notice cannot be embedded in a JavaScript comment");
    packages.set(installed.name, { version: installed.version, notice: notice.toString("utf8").trimEnd() });
  }
  const notices = [...packages].sort(([a], [b]) => a.localeCompare(b, "en"))
    .map(([name, item]) => name + " " + item.version + "\n\n" + item.notice);
  const banner = notices.length ? "/*! Third-party notices\n\n" + notices.join("\n\n---\n\n") + "\n*/\n" : "";
  fs.mkdirSync(path.dirname(output.path), { recursive: true });
  fs.writeFileSync(output.path, banner + output.text);
  console.log("Built " + relative + " with " + notices.length + " upstream notices");
}
