// Drives a compiled theme bundle exactly the way a browser does, so
// spec/dashboard/client_rendered_vocabulary_spec.rb can hold the Civet
// rendered DOM to the same invariants rendered_vocabulary_spec.rb holds the
// server rendered ERB to. Node executes the real compiled output (the same
// files `npm run build` produces, compiled fresh into a temp directory by
// the spec so this never depends on a prior build step); nothing here is a
// simulation of what the runtime does, it is the runtime.
//
// Usage: node dashboard_render_harness.js <runtime.js> <cases.json>
// The runtime contains the fixed the dashboard presentation.
//
// cases.json: [{ "path": "/communities/sample", "search": "?scope=all",
//   "dataPath": "/internal/communities/sample", "data": {...} }, ...]
// "search" is optional (a page with no scope selector has none). Prints a
// JSON array of { path, section, html, handedBack } to stdout, one per case,
// in the router's own view.section rather than the case's own label, so a
// route table drift between the two shows up as a mismatch instead of
// silently reading back whatever the caller assumed.
//
// An untouched mount is how a theme says it has not ported that section: in a
// browser the mount still holds the server rendered ERB for the same page, so
// leaving it is what makes the fallback a working page. handedBack is the
// address the theme sent the browser to on its way out, or null when it stayed
// put because that address is already the one in hand. Reported separately so
// the spec can hold the fallback to leaving the reader on the page they asked
// for, rather than only observing that nothing was drawn.

"use strict";

const vm = require("vm");
const fs = require("fs");

function sandboxFor(pathname, search) {
  const sandbox = {};
  const elementsById = new Map();
  const body = {
    children: [],
    appendChild: (node) => {
      body.children.push(node);
      if (node.id) elementsById.set(node.id, node);
      return node;
    }
  };
  sandbox.window = sandbox;
  sandbox.location = { pathname, search: search || "", href: "" };
  sandbox.window.location = sandbox.location;
  sandbox.history = { pushState: () => {} };
  sandbox.window.history = sandbox.history;
  sandbox.document = {
    addEventListener: () => {},
    removeEventListener: () => {},
    documentElement: {
      setAttribute: () => {},
      getAttribute: () => null,
      removeAttribute: () => {}
    },
    querySelector: () => null,
    getElementById: (id) => elementsById.get(id) || null,
    createElementNS: (_namespace, name) => {
      const attributes = {};
      const node = {
        name,
        attributes,
        innerHTML: ""
      };
      node.setAttribute = (key, value) => {
        attributes[key] = String(value);
        if (key === "id") node.id = String(value);
      };
      return node;
    },
    body
  };
  sandbox.addEventListener = () => {};
  sandbox.removeEventListener = () => {};
  sandbox.console = console;
  sandbox.URL = URL;
  return sandbox;
}

async function renderCase(runtimeSrc, testCase) {
  const sandbox = sandboxFor(testCase.path, testCase.search);
  vm.createContext(sandbox);
  vm.runInContext(runtimeSrc, sandbox, { filename: "dashboard-runtime.js" });
  // navigate() falls back to an ordinary page load when a read throws, which
  // is the same observable outcome as a theme handing a section it does not
  // draw back to the server. Keeping the mock's own complaint here means a
  // case whose stub does not match what the runtime asked for is reported as
  // the harness bug it is rather than read back as theme coverage.
  let fetchError = null;

  sandbox.fetch = async (url) => {
    // The query string (a scope selector, so far) rides along on the fetch
    // URL unparsed, so this checks the path ahead of it rather than the
    // whole string, the same way the runtime itself never inspects it. The
    // query itself is still checked, separately, against what the case set
    // on the page's own address: a router that silently dropped it while
    // fetching would otherwise pass this mock by accident.
    const [path, query] = String(url).split("?");
    if (!path.endsWith(testCase.dataPath)) {
      fetchError = new Error(`harness asked for ${url}, case only stubs ${testCase.dataPath}`);
      throw fetchError;
    }
    const expectedQuery = (testCase.search || "").replace(/^\?/, "");
    if ((query || "") !== expectedQuery) {
      fetchError = new Error(`harness asked for ${url} with query ${JSON.stringify(query || "")}, case's own search was ${JSON.stringify(testCase.search || "")}`);
      throw fetchError;
    }
    return { ok: true, status: 200, text: async () => JSON.stringify(testCase.data) };
  };

  const mount = { innerHTML: "" };
  await sandbox.rubottyDashboard.start({ base: "", root: mount, parse: JSON.parse });
  if (fetchError) throw fetchError;

  const view = sandbox.rubottyDashboard.view();
  return {
    path: testCase.path,
    section: view ? view.section : null,
    html: mount.innerHTML,
    handedBack: sandbox.location.href || null
  };
}

async function main() {
  const [, , runtimePath, casesPath] = process.argv;
  if (!casesPath) {
    throw new Error("usage: dashboard_render_harness.js <runtime.js> <cases.json>");
  }
  const runtimeSrc = fs.readFileSync(runtimePath, "utf8");
  const cases = JSON.parse(fs.readFileSync(casesPath, "utf8"));

  const results = [];
  for (const testCase of cases) {
    results.push(await renderCase(runtimeSrc, testCase));
  }

  process.stdout.write(JSON.stringify(results));
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
