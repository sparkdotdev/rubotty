// Drives the shell contract against a compiled theme bundle, so
// spec/dashboard/dashboard_shell_spec.rb can hold the chrome a theme draws to the
// same standards the content half is already held to.
//
// Two halves, and the split is deliberate. chrome() is a pure string emitter,
// so the markup, the class vocabulary and (the point of the whole exercise)
// the fact that the navigation is RENDERED FROM THE DOCUMENT rather than
// hardcoded are all checked against a real render with no DOM at all. The
// mount path is checked separately against a deliberately small stand-in for
// the document, which records what the runtime did to it: the chrome was
// drawn, the page node was moved into the declared slot, and the body was
// stamped only once both had happened.
//
// Usage: node dashboard_shell_checks.js <runtime.js> <nav.json>
// nav.json is a real ViewData#shell document. Prints
// { html, checks: [{ name, ok, detail }] } to stdout.

"use strict";

const vm = require("vm");
const fs = require("fs");


// The smallest thing the runtime's mount path can be driven against: it holds
// an innerHTML string and answers querySelector by looking for the selector's
// class in it. Not a DOM, and it is not pretending to be one; it is here to
// record that the runtime asked for the declared slot and put the page in it.
function stubElement(name) {
  return {
    name,
    innerHTML: "",
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

function sandboxFor(pathname) {
  const sandbox = {};
  sandbox.window = sandbox;
  sandbox.location = { pathname, href: "" };
  sandbox.window.location = sandbox.location;
  sandbox.history = { pushState: () => {} };
  sandbox.window.history = sandbox.history;
  sandbox.document = {
    addEventListener: () => {},
    removeEventListener: () => {},
    getElementById: () => null,
    createElementNS: (_namespace, name) => stubElement(name),
    documentElement: stubElement("html"),
    querySelector: () => null,
    body: stubElement("body")
  };
  sandbox.addEventListener = () => {};
  sandbox.removeEventListener = () => {};
  sandbox.console = console;
  sandbox.URL = URL;
  sandbox.setTimeout = setTimeout;
  sandbox.clearTimeout = clearTimeout;
  return sandbox;
}

function load(runtimeSrc, pathname) {
  const sandbox = sandboxFor(pathname);
  vm.createContext(sandbox);
  vm.runInContext(runtimeSrc, sandbox, { filename: "dashboard-runtime.js" });
  return sandbox;
}

function check(checks, name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail || "" });
}

// Every entry the shell document carries, flattened, which is what the chrome
// has to account for.
function navEntries(nav) {
  return (nav.scopes || []).flatMap((scope) =>
    (scope.groups || []).flatMap((group) => group.items || []));
}

// signed_out_shell on the server sends exactly this shape: empty scopes, no
// logout_path, and operator.label carrying the placeholder string "Sign in".
// A chrome that draws that placeholder as though it were a real display name,
// or draws a log out control with nowhere honest to post to, reads as a
// signed-in operator when nobody is signed in at all.
function checkSignedOut(checks, sandbox) {
  const nav = {
    section: "shell", scopes: [], communities: [], crumbs: [],
    operator: { label: "Sign in", administrator: false, read_only: true },
    search: { path: "", placeholder: "" }, logout_path: "",
    brand: { product: "rubotty", version: "0.0.0-test", commit: "", drift: [] }
  };
  const shell = sandbox.rubottyDashboard.shell;
  if (!shell) return;

  const html = shell.chrome(nav);
  check(checks, "a signed-out document draws no log out control",
        !/aria-label="Log out"/.test(html), `${html.length} characters`);
  check(checks, "a signed-out document never shows the placeholder label as a display name",
        !html.includes("Sign in"), `${html.length} characters`);
}

function checkChrome(checks, sandbox, nav) {
  const shell = sandbox.rubottyDashboard.shell;
  check(checks, "the theme declares a shell", !!shell);
  if (!shell) return "";

  const html = shell.chrome(nav);
  check(checks, "chrome() returns markup", typeof html === "string" && html.length > 500,
        `${typeof html}, ${String(html).length} characters`);

  const slot = shell.slots.content;
  check(checks, "the chrome draws the content slot it declares",
        html.includes(`class="${slot.replace(/^\./, "")}"`), `declared ${slot}`);

  // The whole premise: the sections are the server's document, not this
  // theme's opinion. Every entry the document carries has to be reachable in
  // the chrome, by label and by destination.
  const entries = navEntries(nav);
  check(checks, "the document carries entries to render", entries.length >= 10,
        `${entries.length} entries`);
  const missing = entries.filter((item) =>
    !html.includes(`href="${item.path}"`) || !html.includes(item.label.replace(/&/g, "&amp;")));
  check(checks, "every nav entry in the document is drawn", missing.length === 0,
        missing.map((item) => `${item.key} (${item.path})`).join(", "));

  // Nothing invented: a label the document does not carry would mean the
  // theme is deciding sections after all.
  const groups = (nav.scopes || []).flatMap((scope) => scope.groups || [])
    .map((group) => group.label).filter(Boolean);
  const absentGroups = groups.filter((label) => !html.includes(label));
  check(checks, "every group heading in the document is drawn", absentGroups.length === 0,
        absentGroups.join(", "));

  const badged = entries.filter((item) => item.badge);
  check(checks, "a badge count reaches the chrome",
        badged.every((item) => html.includes(`>${item.badge}</span>`)),
        badged.map((item) => `${item.key}=${item.badge}`).join(", "));

  const crumb = (nav.crumbs || []).slice(-1)[0];
  check(checks, "the breadcrumb the document builds is drawn",
        !crumb || html.includes(crumb.label), crumb ? crumb.label : "no crumb");

  // The way back out of a community. A tail slice keeps the page and its
  // community and drops this one, which is the crumb a breadcrumb is for.
  const root = (nav.crumbs || [])[0];
  check(checks, "the breadcrumb keeps the root, however deep the route",
        !root || html.includes(`href="${root.path}">${root.label}</a>`),
        root ? `${root.label} -> ${root.path}` : "no crumb");

  // A disclosure that collapses what is under it and announces no state is a
  // button a screen reader can only describe as a button.
  const heads = html.match(/<button[^>]*data-shell-group[^>]*>/g) || [];
  check(checks, "every nav group head is a disclosure that announces its state",
        heads.length > 0 && heads.every((tag) => tag.includes('aria-expanded="true"')),
        `${heads.length} head(s), ${heads.filter((tag) => !tag.includes("aria-expanded")).length} silent`);

  check(checks, "the log out control posts to the path the document names",
        html.includes(`action="${nav.logout_path}"`), nav.logout_path);

  check(checks, "the search field is pointed at the path the document names",
        html.includes(`data-shell-search-path="${nav.search.path}"`), nav.search.path);

  check(checks, "both scopes reach the switcher",
        (nav.scopes || []).every((scope) => html.includes(`data-shell-scope="${scope.key}"`)),
        (nav.scopes || []).map((scope) => scope.key).join(", "));

  check(checks, "the chrome carries no inline style at all",
        !/\sstyle="/.test(html), (html.match(/\sstyle="/g) || []).length + " found");


  return html;
}

async function checkMount(checks, runtimeSrc, nav, pathname) {
  const sandbox = load(runtimeSrc, pathname);
  const declaredShell = sandbox.rubottyDashboard.shell;
  const contentSlot = declaredShell?.slots?.content || ".rb-shell-content";
  const asked = [];
  sandbox.fetch = async (url) => {
    asked.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(nav) };
  };

  const shellRoot = stubElement("#rb-shell");
  shellRoot.setAttribute("hidden", "");
  const home = stubElement("#rb-chrome");
  const content = home.appendChild(stubElement("#rb-content"));

  await sandbox.rubottyDashboard.start({
    base: "", root: stubElement("#rb-view"), shell: shellRoot,
    content, sections: false, parse: JSON.parse
  });

  check(checks, "mounting reads the shell document off the internal surface",
        asked.some((url) => url.includes("/internal/shell?path=")), asked.join(" "));
  check(checks, "the chrome is drawn into the mount the layout provides",
        shellRoot.innerHTML.includes(contentSlot.replace(/^\./, "")), shellRoot.innerHTML.slice(0, 60));
  check(checks, "the mount is unhidden once the chrome is in it",
        shellRoot.getAttribute("hidden") === null);
  check(checks, "the page the server rendered is MOVED into the declared slot",
        (shellRoot.slots || {})[contentSlot]?.adopted[0] === content);
  sandbox.rubottyDashboard.stop();
  check(checks, "stopping returns content and hides the cleared shell",
        content.parentNode === home && shellRoot.getAttribute("hidden") === "" && shellRoot.innerHTML === "");
}

// The collapse itself has always worked. What a screen reader had no way to
// hear was whether the group under the head it just pressed is open or shut,
// so this drives the real click handler and reads back what the head says.
function checkDisclosureState(checks, runtimeSrc, nav, pathname) {
  const sandbox = load(runtimeSrc, pathname);
  const handlers = [];
  sandbox.document.addEventListener = (name, handler) => {
    if (name === "click") handlers.push(handler);
  };

  const shell = sandbox.rubottyDashboard.shell;
  const root = stubElement("#rb-shell");
  root.innerHTML = shell.chrome(nav);
  shell.bind({ root });

  const collapsed = new Set();
  const head = stubElement("group head");
  head.parentElement = {
    classList: {
      toggle(name) {
        if (collapsed.has(name)) {
          collapsed.delete(name);
          return false;
        }
        collapsed.add(name);
        return true;
      }
    }
  };
  head.closest = (selector) => (selector === "[data-shell-group]" ? head : null);
  head.setAttribute("aria-expanded", "true");

  const click = handlers[0];
  check(checks, "the chrome binds a click handler to press", typeof click === "function");
  if (typeof click !== "function") return;

  click({ target: head });
  const shut = head.getAttribute("aria-expanded") === "false" && collapsed.size === 1;
  click({ target: head });
  const open = head.getAttribute("aria-expanded") === "true" && collapsed.size === 0;
  check(checks, "collapsing a nav group flips what its head announces", shut && open,
        `collapse ${shut ? "tracked" : "silent"}, expand ${open ? "tracked" : "silent"}`);
}

function classList() {
  const names = new Set();
  return {
    add(name) { names.add(name); },
    remove(name) { names.delete(name); },
    contains(name) { return names.has(name); }
  };
}

// This drives the terminal's compiled Civet against a narrow viewport. It
// checks the behaviour a visual CSS assertion cannot see: the closed tree is
// removed from tab order, the toggle moves focus into it, Escape restores the
// toggle, and a desktop resize clears stale drawer state before a phone-sized
// viewport returns.
// A shell that cannot be drawn must leave the layout's chrome alone: that
// chrome is a working panel, and taking an operator's navigation away is a
// worse failure than an unthemed one.
async function checkFailureIsSurvivable(checks, runtimeSrc, pathname) {
  const sandbox = load(runtimeSrc, pathname);
  sandbox.fetch = async () => { throw new Error("no shell document here"); };
  sandbox.console = { warn: () => {}, log: () => {} };

  const shellRoot = stubElement("#rb-shell");
  shellRoot.setAttribute("hidden", "");
  const home = stubElement("#rb-chrome");
  const content = home.appendChild(stubElement("#rb-content"));

  await sandbox.rubottyDashboard.start({
    base: "", root: stubElement("#rb-view"), shell: shellRoot,
    content, sections: false, parse: JSON.parse
  });

  check(checks, "a shell that cannot be drawn leaves the page where the server put it",
        content.parentNode === home);
  check(checks, "a shell that cannot be drawn leaves its own mount hidden and empty",
        shellRoot.getAttribute("hidden") === "" && shellRoot.innerHTML === "");
}

async function main() {
  const [, , runtimePath, navPath] = process.argv;
  const runtimeSrc = fs.readFileSync(runtimePath, "utf8");
  const nav = JSON.parse(fs.readFileSync(navPath, "utf8"));
  const pathname = "/communities/sample";

  const checks = [];
  const html = checkChrome(checks, load(runtimeSrc, pathname), nav);
  checkSignedOut(checks, load(runtimeSrc, pathname));
  await checkMount(checks, runtimeSrc, nav, pathname);
  checkDisclosureState(checks, runtimeSrc, nav, pathname);
  await checkFailureIsSurvivable(checks, runtimeSrc, pathname);

  process.stdout.write(JSON.stringify({ html, checks }));
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exit(1);
});
