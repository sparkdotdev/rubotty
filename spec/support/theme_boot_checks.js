// Drives the compiled boot script against the document layout.erb really
// sends, so spec/dashboard/theme_shell_spec.rb can hold the other half of the
// staging contract: the server body is hidden so no unthemed panel flashes,
// and it has to come back into view when the theme it was waiting for never
// takes it over. Hidden is how the panel avoids a flash, and it must never
// become how the panel disappears.
//
// Usage: node theme_boot_checks.js <runtime.js> <boot.js> <nav.json>
// Prints a JSON array of { case, revealed, adoptedBy } to stdout, one per
// scenario: revealed says whether #rb-staging ended up on screen, adoptedBy
// names the slot the page was moved into, or null when nothing moved it, and a
// scenario carrying a notice adds flashScrolledWith, null when nothing scrolled it.

"use strict";

const vm = require("vm");
const fs = require("fs");

// The smallest thing the boot path can be driven against: it records what was
// appended to it and answers querySelector by looking for the selector's class
// in the chrome string. Not a DOM, and not pretending to be one.
function stubElement(name) {
  return {
    name,
    innerHTML: "",
    textContent: "",
    dataset: {},
    attributes: {},
    adopted: [],
    parentNode: null,
    setAttribute(key, value) { this.attributes[key] = value; },
    removeAttribute(key) { delete this.attributes[key]; },
    getAttribute(key) { return key in this.attributes ? this.attributes[key] : null; },
    addEventListener() {},
    appendChild(node) { this.adopted.push(node); node.parentNode = this; return node; },
    querySelector(selector) {
      const wanted = selector.replace(/^\./, "");
      if (!this.innerHTML.includes(`class="${wanted}"`) &&
          !this.innerHTML.includes(`${wanted} `) && !this.innerHTML.includes(`${wanted}"`)) {
        return null;
      }
      this.slots = this.slots || {};
      this.slots[selector] = this.slots[selector] || stubElement(selector);
      return this.slots[selector];
    },
    querySelectorAll() { return []; }
  };
}

// The nodes layout.erb writes, in the shape it writes them: an empty hidden
// mount for the chrome, and the page itself staged out of sight beside it.
function documentFor(options) {
  const byId = new Map();
  const add = (id) => {
    const element = stubElement(id);
    byId.set(id, element);
    return element;
  };

  if (options.shellMount !== false) add("rb-shell").setAttribute("hidden", "");
  const staging = add("rb-staging");
  staging.setAttribute("hidden", "");
  const content = add("rb-content");
  const footer = add("rb-footer");
  staging.appendChild(content);
  const flash = options.flashBox ? flashFor(options.flashBox) : null;
  if (flash) content.appendChild(flash);
  content.appendChild(add("rb-view"));
  staging.appendChild(footer);
  add("rb-shell-data").textContent = options.shellJson;

  return { byId, staging, content, flash };
}

// The notice layout.erb writes above #rb-view, standing where the scenario says
// the theme's layout put it, and recording whether anything scrolled it into view.
function flashFor(box) {
  const flash = stubElement("flash");
  flash.scrolledWith = null;
  flash.getBoundingClientRect = () => box;
  flash.scrollIntoView = (how) => { flash.scrolledWith = how || {}; };
  return flash;
}

function sandboxFor(page, themeName) {
  const sandbox = {};
  sandbox.window = sandbox;
  sandbox.location = { pathname: "/", search: "", href: "" };
  sandbox.window.location = sandbox.location;
  sandbox.history = { pushState: () => {} };
  sandbox.window.history = sandbox.history;

  const root = stubElement("html");
  root.dataset = { rbTheme: themeName, rbBase: "", rbThemedSection: "false" };
  sandbox.document = {
    addEventListener: () => {},
    removeEventListener: () => {},
    getElementById: (id) => page.byId.get(id) || null,
    createElementNS: (_namespace, name) => stubElement(name),
    documentElement: root,
    querySelector: (selector) => (selector.includes(".flash") ? page.flash : null),
    body: stubElement("body")
  };
  // The height of the phone the report came from.
  sandbox.innerHeight = 812;
  sandbox.addEventListener = () => {};
  sandbox.removeEventListener = () => {};
  // Silenced rather than passed through: the failing scenarios below log on
  // their way out, and the caller reads this script's stdout as JSON.
  sandbox.console = { log() {}, warn() {}, error() {} };
  sandbox.URL = URL;
  sandbox.setTimeout = setTimeout;
  sandbox.clearTimeout = clearTimeout;
  sandbox.fetch = async () => {
    throw new Error("the page carries its own shell document, so nothing here reads one");
  };
  return sandbox;
}

// boot() is deferred and async, and nothing on the page waits for it, so the
// scenarios settle on a later turn of the loop rather than on this one.
function settled() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function runCase(sources, scenario) {
  const page = documentFor(scenario);
  const sandbox = sandboxFor(page, scenario.theme);
  vm.createContext(sandbox);
  if (scenario.runtimeMissing !== true) {
    vm.runInContext(sources.runtime, sandbox, { filename: "theme-runtime.js" });
  }
  vm.runInContext(sources.boot, sandbox, { filename: "theme-boot.js" });
  await settled();

  const home = page.content.parentNode;
  const slot = sandbox.rubottyTheme?.shell?.slots?.content;
  const result = {
    case: scenario.case,
    revealed: page.staging.getAttribute("hidden") === null,
    adoptedBy: home === page.staging ? null : home.name,
    intoDeclaredSlot: home !== page.staging && home.name === slot
  };
  if (page.flash) result.flashScrolledWith = page.flash.scrolledWith;
  return result;
}

async function main() {
  const [, , runtimePath, bootPath, navPath] = process.argv;
  if (!navPath) {
    throw new Error("usage: theme_boot_checks.js <runtime.js> <boot.js> <nav.json>");
  }
  const sources = {
    runtime: fs.readFileSync(runtimePath, "utf8"),
    boot: fs.readFileSync(bootPath, "utf8")
  };
  const shellJson = fs.readFileSync(navPath, "utf8");

  const scenarios = [
    { case: "the theme mounts its chrome", theme: "series-a", shellJson },
    { case: "the runtime script never arrived",
      theme: "series-a", shellJson, runtimeMissing: true },
    { case: "the chrome has no mount point to draw into",
      theme: "series-a", shellJson, shellMount: false },
    { case: "the shell document on the page cannot be read",
      theme: "series-a", shellJson: "{not json" },
    // A notice can begin below the fold on a narrow screen.
    { case: "a notice the layout left below the fold",
      theme: "series-a", shellJson, flashBox: { top: 915, bottom: 956 } },
    { case: "a notice already on screen",
      theme: "series-a", shellJson, flashBox: { top: 96, bottom: 137 } }
  ];

  const results = [];
  for (const scenario of scenarios) results.push(await runCase(sources, scenario));

  process.stdout.write(JSON.stringify(results));
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
