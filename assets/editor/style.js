// The editor's colours, taken from the dashboard's own palette rather than a
// stock CodeMirror theme, so the editor looks like part of the page it sits in.
//
// #cc342d is already the dashboard's accent and happens to be Ruby's red, which
// is why keywords get it. Everything else is the greys, the blue and the green
// the surrounding pages already use.
import { EditorView } from "@codemirror/view";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags } from "@lezer/highlight";

const INK = "#1c232b";
const MUTED = "#6b7684";
const RUBY = "#cc342d";
const BLUE = "#2b6cb0";
const GREEN = "#12662f";
const RULE = "#d7dce2";
const WASH = "#eceff2";

export const editorStyle = EditorView.theme(
  {
    "&": { color: INK, backgroundColor: "#fff", border: `1px solid ${RULE}`, borderRadius: "6px" },
    ".cm-content": {
      caretColor: RUBY,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: "13px",
      padding: "8px 0",
    },
    "&.cm-focused": { outline: "none", borderColor: MUTED },
    ".cm-gutters": { backgroundColor: WASH, color: MUTED, border: "none", borderRight: `1px solid ${RULE}` },
    ".cm-activeLine": { backgroundColor: "#f7f9fb" },
    ".cm-activeLineGutter": { backgroundColor: WASH, color: INK },
    "&.cm-focused .cm-selectionBackground, ::selection": { backgroundColor: "#dbe7f3" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: RUBY },
    ".cm-tooltip": { backgroundColor: "#fff", border: `1px solid ${RULE}`, color: INK },
    ".cm-tooltip-autocomplete ul li[aria-selected]": { backgroundColor: WASH, color: INK },
    ".cm-completionDetail": { color: MUTED, fontStyle: "normal" },
  },
  { dark: false }
);

export const rubottyHighlight = syntaxHighlighting(
  HighlightStyle.define([
    { tag: tags.keyword, color: RUBY, fontWeight: "600" },
    { tag: tags.controlKeyword, color: RUBY, fontWeight: "600" },
    { tag: tags.operatorKeyword, color: RUBY },
    { tag: tags.atom, color: RUBY },
    { tag: tags.bool, color: RUBY },
    { tag: tags.null, color: RUBY },
    { tag: tags.comment, color: MUTED, fontStyle: "italic" },
    { tag: tags.string, color: GREEN },
    { tag: tags.number, color: BLUE },
    { tag: tags.operator, color: MUTED },
    { tag: tags.typeName, color: BLUE, fontWeight: "600" },
    { tag: tags.className, color: BLUE, fontWeight: "600" },
    { tag: tags.propertyName, color: BLUE },
    { tag: tags.variableName, color: INK },
    { tag: tags.function(tags.variableName), color: INK },
    { tag: tags.invalid, color: RUBY, textDecoration: "underline wavy" },
  ])
);
