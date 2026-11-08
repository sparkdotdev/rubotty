// Drives the compiled condition rule builder the way a browser does, over a
// DOM small enough to write down: the two real controls the form posts, and
// the mount the builder draws into. Nothing here simulates the module; it is
// the real compiled output of assets/dashboard/runtime/script-rules.civet, so a
// change that stops the list serialising back into trigger_type and
// trigger_also[] fails here rather than in somebody's browser.
//
// Usage: node script_rules_harness.js <bundle.js> <script.json>
// script.json: { "trigger_type": "command", "trigger_also": ["contains"],
//                "triggers": [...], "max_conditions": 4, "act": [...] }
// "act" is a list of steps: { "click": "rule-add" }, { "click": "rule-remove",
// "value": "1" }, { "pick": 0, "value": "always" }.
//
// Prints { rules, triggerType, triggerAlso, html } as JSON.

"use strict";

const vm = require("vm");
const fs = require("fs");

function makeElement(tag) {
  const element = {
    tagName: tag.toUpperCase(),
    attributes: {},
    children: [],
    innerHTML: "",
    hidden: false,
    parentNode: null,
    setAttribute(name, value) {
      this.attributes[name] = String(value);
    },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
    },
    hasAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attributes, name);
    },
    closest(selector) {
      return selector === ".rb-field" ? this.field || null : null;
    },
    contains() {
      return true;
    },
    insertBefore(node) {
      node.parentNode = this;
      this.children.push(node);
      return node;
    }
  };
  return element;
}

function buildDocument(state) {
  const picker = makeElement("select");
  picker.id = "rb-field-trigger_type";
  picker.value = state.trigger_type;
  picker.field = makeElement("div");

  const boxes = state.triggers.map((entry) => {
    const box = makeElement("input");
    box.name = "trigger_also[]";
    box.value = entry.name;
    box.checked = (state.trigger_also || []).includes(entry.name);
    box.field = makeElement("div");
    return box;
  });

  const holder = makeElement("div");
  holder.parentNode = makeElement("div");
  holder.parentNode.insertBefore = (node) => {
    node.parentNode = holder.parentNode;
    state.mount = node;
    return node;
  };
  picker.field.parentNode = holder.parentNode;

  return {
    createElement: makeElement,
    querySelector(selector) {
      if (selector === "#rb-field-trigger_type") return picker;
      if (selector === "[data-script-rules]") return state.mount || null;
      return null;
    },
    querySelectorAll(selector) {
      return selector === 'input[name="trigger_also[]"]' ? boxes : [];
    },
    picker,
    boxes
  };
}

function main() {
  const [bundlePath, casePath] = process.argv.slice(2);
  const state = JSON.parse(fs.readFileSync(casePath, "utf8"));
  const root = buildDocument(state);

  const sandbox = { console };
  sandbox.window = sandbox;
  sandbox.document = { createElement: makeElement };
  sandbox.global = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(bundlePath, "utf8"), sandbox);

  const api = sandbox.rubottyScriptRules;
  const data = {
    section: "script_edit",
    triggers: state.triggers,
    max_conditions: state.max_conditions || 4,
    may: { manage_scripts: true }
  };

  api.drawScriptRules(root, data);
  for (const step of state.act || []) {
    if (step.click) {
      api.editScriptRules(root, data, { name: step.click, value: step.value || "" });
    } else {
      api.editScriptRules(root, data, {
        id: `rb-field-rule-${step.pick}`,
        value: step.value,
        name: ""
      });
    }
  }

  process.stdout.write(JSON.stringify({
    rules: api.currentRules(root),
    triggerType: root.picker.value,
    triggerAlso: root.boxes.filter((box) => box.checked).map((box) => box.value),
    html: state.mount ? state.mount.innerHTML : ""
  }));
}

main();
