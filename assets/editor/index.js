// The dashboard's script editor.
//
// CodeMirror 6 is ESM and needs a bundler, so this is built by esbuild into a
// single IIFE at deploy time and served as one file, the same shape the
// dashboard already uses for its chart engines. Nothing compiles at runtime.
// Deliberately a progressive enhancement: the form ships a working
// <textarea> that this upgrades in place, syncing changes back so the
// ordinary POST still submits, and still saves as a plain textarea if this file is missing.
import { EditorView, basicSetup } from "codemirror";
import { EditorState } from "@codemirror/state";
import { autocompletion } from "@codemirror/autocomplete";
import { StreamLanguage } from "@codemirror/language";
import { moonscript } from "./moonscript.js";
import { rubottyHighlight, editorStyle } from "./style.js";
// CodeMirror 6 ships no first-party Lua package. The maintained route is the
// legacy-modes bundle, which carries the CodeMirror 5 Lua mode wrapped for 6.
import { lua } from "@codemirror/legacy-modes/mode/lua";
// Fennel is a Lisp, so Clojure's mode highlights it correctly: the same paren
// nesting, the same `;` comments, the same string rules.
import { clojure } from "@codemirror/legacy-modes/mode/clojure";
// The endpoint editor's query and body boxes are YAML, and so are the examples
// that explain them, so the read only snippets below need it too.
import { yaml } from "@codemirror/legacy-modes/mode/yaml";

// The completion list is handed over by Ruby (Scripting::Sandbox#completions)
// and embedded in the page, so it is generated from the same constants the
// child builds its environment from. Hardcoding it here would drift from what
// the sandbox actually allows, and offering a function that is not there is
// worse than offering nothing.
function completionsFrom(textarea) {
  let entries = [];
  try {
    entries = JSON.parse(document.getElementById("script-completions")?.textContent || "[]");
  } catch (e) {
    entries = [];
  }
  return (context) => {
    const before = context.matchBefore(/[\w.]+/);
    if (!before || (before.from === before.to && !context.explicit)) return null;
    return { from: before.from, options: entries, validFor: /^[\w.]*$/ };
  };
}

// Teal is Lua with annotations, so it needs no mode of its own.
const MODES = { lua, moonscript, fennel: clojure, yaml };

// The editor is upgraded in place on a form whose language select can
// change, so this reads the select rather than deciding once at boot: Ruby
// names the mode per dialect (Scripting::Dialects), so this keeps no second
// list of which is which. A box declaring data-editor-mode is exempt, since
// the data file is YAML whatever dialect the script beside it is written in,
// and without this the Data pane would be highlighted as Fennel for anybody
// writing Fennel.
function languageFor(textarea) {
  const fixed = textarea.dataset.editorMode;
  if (fixed) return StreamLanguage.define(MODES[fixed] || MODES.lua);

  const select = textarea.form && textarea.form.querySelector("select[name='language']");
  const chosen = select ? select.value : textarea.dataset.editor;
  let modes = {};
  try {
    modes = JSON.parse((select && select.dataset.modes) || "{}");
  } catch (e) {
    modes = {};
  }
  return StreamLanguage.define(MODES[modes[chosen]] || MODES.lua);
}

function upgrade(textarea) {
  // Keep the textarea in the DOM and hidden rather than replacing it, so the
  // surrounding form submits exactly as it would without any JavaScript.
  textarea.style.display = "none";

  const sync = EditorView.updateListener.of((update) => {
    if (update.docChanged) textarea.value = update.state.doc.toString();
  });

  const view = new EditorView({
    state: EditorState.create({
      doc: textarea.value,
      extensions: [
        basicSetup,
        editorStyle,
        rubottyHighlight,
        languageFor(textarea),
        autocompletion({ override: [completionsFrom(textarea)] }),
        sync,
        EditorView.lineWrapping,
      ],
    }),
  });

  textarea.parentNode.insertBefore(view.dom, textarea);
  view.dom.classList.add("script-editor");
  return view;
}

// Picking a shipped example fills the whole form, not just the body: the kind,
// the language and the trigger are part of what makes the example work, and
// leaving an operator to guess which trigger it was written for is the fiddly
// half. Nothing is saved by choosing one.
function wireExamplePicker(textarea, reload) {
  const picker = document.getElementById("example-picker");
  if (!picker) return;

  let examples = [];
  try {
    examples = JSON.parse(document.getElementById("script-examples")?.textContent || "[]");
  } catch (e) {
    examples = [];
  }

  // The one line description goes in the option itself, so the list can be
  // read while it is open rather than one entry at a time after choosing.
  // There is no single language to name here: an example ships in every
  // dialect and `sources` is the map, so the old label interpolated
  // example.language and printed "undefined" against all of them.
  for (const example of examples) {
    const option = document.createElement("option");
    option.value = example.id;
    option.textContent = `${example.name} (${example.kind}): ${example.summary}`;
    picker.appendChild(option);
  }
  const form = textarea.form;
  const field = (name) => form && form.querySelector(`[name='${name}']`);
  const set = (name, value) => {
    const target = field(name);
    if (target && value) target.value = value;
  };

  // Somebody writing MoonScript should only ever see MoonScript, so an example
  // is inserted in whichever dialect the language select currently says. Both
  // are hand written; the compilation to Lua is an implementation detail and
  // nobody is shown compiler output.
  const currentLanguage = () => (field("language") ? field("language").value : "lua");

  const apply = () => {
    const example = examples.find((candidate) => candidate.id === picker.value);
    if (!example) return;

    const language = currentLanguage();
    textarea.value = example.sources[language] || example.sources.lua;
    set("kind", example.kind);
    set("trigger_type", example.trigger_type);
    // An example that reads a data file ships one, and picking it without the
    // data would drop somebody into a rule that reads a list nobody gave it.
    // set ignores a blank, so an example needing no data leaves whatever is
    // already in the Data box alone.
    set("yaml_data", example.data);
    reload();
  };

  picker.addEventListener("change", apply);
  // Switching language with an example loaded swaps it for the same example
  // written in the other dialect, rather than leaving the wrong one on screen.
  if (field("language")) field("language").addEventListener("change", () => picker.value && apply());
}

// Example code, shown the way the thing it is an example OF is shown: these
// are the same editor in read only mode, so the highlighting an example
// promises is the highlighting the editor really gives, instead of a <code>
// element styled to look vaguely like code. The <pre> or <code> stays in the
// DOM until the view is built, so a page with no JavaScript, or a deploy that
// skipped the asset build, still shows the example as plain text.
function upgradeSnippets() {
  var snippets = document.querySelectorAll("[data-code]");
  for (var i = 0; i < snippets.length; i++) {
    var node = snippets[i];
    var mode = MODES[node.dataset.code];
    var text = node.textContent.replace(/\s+$/, "");
    var extensions = [
      editorStyle,
      rubottyHighlight,
      EditorView.editable.of(false),
      EditorState.readOnly.of(true),
      EditorView.lineWrapping,
    ];
    // An unknown language is still worth rendering: it gets the editor's
    // frame and font without any highlighting, rather than being skipped.
    if (mode) extensions.push(StreamLanguage.define(mode));
    var view = new EditorView({ state: EditorState.create({ doc: text, extensions: extensions }) });
    view.dom.classList.add("code-example");
    node.parentNode.insertBefore(view.dom, node);
    node.remove();
  }
}

// The rendered documentation page is markdown, so its examples arrive as
// kramdown's <pre><code class="language-lua">. Tagged here rather than in the
// renderer, so the markdown stays ordinary markdown.
function tagRenderedDocumentation() {
  var blocks = document.querySelectorAll(".rb-prose pre > code[class*='language-']");
  for (var i = 0; i < blocks.length; i++) {
    var named = /language-([\w-]+)/.exec(blocks[i].className);
    var language = named ? named[1] : "";
    var block = blocks[i].parentNode;
    block.textContent = blocks[i].textContent;
    block.dataset.code = language === "teal" ? "lua" : language;
  }
}

// Code and Data, one at a time: two documents belonging to one script, so
// they are panes on one form rather than two pages, and both go up in the
// same POST whichever one is showing. The toggle buttons are hidden in the
// markup and revealed here, so a toggle nothing listens to never hides half
// the form and both boxes just show one after the other with no JavaScript;
// CodeMirror measures itself when built, so a pane built inside a hidden
// container measures nothing and is asked to measure again once its pane is
// shown.
function wirePaneToggle(panes) {
  const toggle = document.getElementById("script-pane-toggle");
  if (!toggle) return;

  const bodies = document.querySelectorAll("[data-pane-body]");
  if (!bodies.length) return;

  const show = (wanted) => {
    bodies.forEach((body) => {
      body.hidden = body.dataset.paneBody !== wanted;
    });
    toggle.querySelectorAll("button[data-pane]").forEach((button) => {
      button.classList.toggle("secondary", button.dataset.pane !== wanted);
    });
    panes.forEach((entry) => entry.view.requestMeasure());
  };

  toggle.querySelectorAll("button[data-pane]").forEach((button) => {
    button.addEventListener("click", () => show(button.dataset.pane));
  });
  toggle.hidden = false;
  show("code");
}

function boot() {
  tagRenderedDocumentation();
  upgradeSnippets();

  const panes = [];
  document.querySelectorAll("textarea[data-editor]").forEach((textarea) => {
    panes.push({ textarea: textarea, view: upgrade(textarea) });
  });

  // Rebuild one editor from its textarea. Both callers below fill the textarea
  // first and then ask for this, so the textarea stays the single source of
  // what the form will submit.
  const reload = (entry) => {
    entry.view.dom.remove();
    entry.view.destroy();
    entry.view = upgrade(entry.textarea);
  };

  // The data pane is one document in one language, so it takes no part in the
  // language select. It is still reloaded when an example is picked, since
  // picking one fills its box too.
  const source = panes.find((entry) => !entry.textarea.dataset.editorMode);
  if (source) {
    wireExamplePicker(source.textarea, () => panes.forEach((entry) => reload(entry)));
    const select = source.textarea.form && source.textarea.form.querySelector("select[name='language']");
    if (select) {
      // Switching the language select reloads the editor so highlighting
      // follows what the operator just said they are writing.
      select.addEventListener("change", () => {
        source.textarea.value = source.view.state.doc.toString();
        reload(source);
      });
    }
  }

  wirePaneToggle(panes);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
