const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");

const root = path.resolve(__dirname, "..");
const script = path.join(root, "scripts/build-dashboard-bundle.js");
const inventory = JSON.parse(fs.readFileSync(path.join(root, "licenses/dashboard-browser.json"), "utf8"));

function fixture(t, source = 'import { EditorState } from "@codemirror/state"; console.log(EditorState.create().doc.length);') {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "rubotty-browser-notices-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.symlinkSync(path.join(root, "node_modules"), path.join(directory, "node_modules"), "dir");
  fs.cpSync(path.join(root, "licenses"), path.join(directory, "licenses"), { recursive: true });
  fs.writeFileSync(path.join(directory, "entry.js"), source);
  return directory;
}

function build(directory) {
  return spawnSync(process.execPath, [script, "entry.js", "out/bundle.js"], { cwd: directory, encoding: "utf8" });
}

function changeInventory(directory, update) {
  const copy = structuredClone(inventory);
  update(copy);
  fs.writeFileSync(path.join(directory, "licenses/dashboard-browser.json"), JSON.stringify(copy));
}

test("the emitted browser file retains the complete installed upstream notice", (t) => {
  const directory = fixture(t);
  const result = build(directory);
  assert.equal(result.status, 0, result.stderr);
  const bundled = fs.readFileSync(path.join(directory, "out/bundle.js"), "utf8");
  const notice = fs.readFileSync(path.join(root, "node_modules/@codemirror/state/LICENSE"), "utf8").trimEnd();
  assert.ok(bundled.includes(notice));
  assert.ok(bundled.startsWith("/*! Third-party notices"));
  assert.ok(!bundled.includes("w3c-keyname"), "unbundled dependencies add no unrelated notices");
  const execution = spawnSync(process.execPath, [path.join(directory, "out/bundle.js")], { encoding: "utf8" });
  assert.equal(execution.status, 0, execution.stderr);
  assert.equal(execution.stdout.trim(), "0");
});

test("first-party-only bundles keep their executable output", (t) => {
  const directory = fixture(t, 'console.log("project source");');
  const result = build(directory);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!fs.readFileSync(path.join(directory, "out/bundle.js"), "utf8").includes("Third-party notices"));
});

test("a newly bundled package requires a reviewed notice before any file is emitted", (t) => {
  const directory = fixture(t);
  changeInventory(directory, (copy) => { copy.packages = []; });
  assert.notEqual(build(directory).status, 0);
  assert.ok(!fs.existsSync(path.join(directory, "out/bundle.js")));
});

test("a dependency version change requires its notice review", (t) => {
  const directory = fixture(t);
  changeInventory(directory, (copy) => { copy.packages.find((item) => item.name === "@codemirror/state").version = "0.0.0"; });
  assert.notEqual(build(directory).status, 0);
  assert.ok(!fs.existsSync(path.join(directory, "out/bundle.js")));
});

test("missing or truncated upstream text prevents a distributable bundle", (t) => {
  const directory = fixture(t);
  const item = inventory.packages.find((candidate) => candidate.name === "@codemirror/state");
  fs.writeFileSync(path.join(directory, item.notice), "MIT");
  assert.notEqual(build(directory).status, 0);
  assert.ok(!fs.existsSync(path.join(directory, "out/bundle.js")));
  fs.unlinkSync(path.join(directory, item.notice));
  assert.notEqual(build(directory).status, 0);
  assert.ok(!fs.existsSync(path.join(directory, "out/bundle.js")));
});
