// A MoonScript mode for CodeMirror 6.
//
// Written here because there is not one to install: @codemirror/legacy-modes
// ships 103 modes including Lua and CoffeeScript, but not MoonScript. This is
// a StreamLanguage tokenizer, the same shape the legacy modes use.
// Deliberately shallow: it colours keywords, strings, comments, numbers, the
// arrows, @self and class names, and skips indentation-based blocks, since
// getting that wrong reads worse than not colouring blocks at all.
const KEYWORDS = new Set([
  "if", "elseif", "else", "then", "for", "while", "do", "return", "break",
  "continue", "local", "export", "import", "from", "with", "switch", "when",
  "class", "extends", "super", "using", "unless", "in", "and", "or", "not",
]);

const ATOMS = new Set(["nil", "true", "false", "self"]);

function tokenBase(stream, state) {
  // Comments.
  if (stream.match("--")) {
    stream.skipToEnd();
    return "comment";
  }

  // Strings, including the long-bracket form.
  const quote = stream.peek();
  if (quote === '"' || quote === "'") {
    stream.next();
    state.tokenize = tokenString(quote);
    return state.tokenize(stream, state);
  }
  if (stream.match(/^\[\[/)) {
    state.tokenize = tokenLongString;
    return state.tokenize(stream, state);
  }

  // Numbers, hex included.
  if (stream.match(/^0x[0-9a-fA-F]+/) || stream.match(/^\d+\.?\d*([eE][-+]?\d+)?/)) {
    return "number";
  }

  // @foo is self.foo and @@foo is the class; both read as a property.
  if (stream.match(/^@@?[A-Za-z_][\w]*/) || stream.match(/^@@?/)) {
    return "propertyName";
  }

  // The arrows are the shape people scan for, so they get their own colour.
  if (stream.match("->") || stream.match("=>")) return "operator";
  // Backslash is a method call and ! calls with no arguments.
  if (stream.match(/^\\[A-Za-z_][\w]*/)) return "propertyName";
  if (stream.match(/^(\.\.\.|\.\.|==|~=|!=|<=|>=|\+=|-=|\*=|\/=|%=|\.\.=|[-+*/%^#<>=!])/)) {
    return "operator";
  }

  const word = stream.match(/^[A-Za-z_][\w]*/);
  if (word) {
    const text = word[0];
    if (KEYWORDS.has(text)) return "keyword";
    if (ATOMS.has(text)) return "atom";
    // Capitalised names are classes by convention in MoonScript.
    if (/^[A-Z]/.test(text)) return "typeName";
    return "variableName";
  }

  stream.next();
  return null;
}

function tokenString(quote) {
  return (stream, state) => {
    let escaped = false;
    let next;
    while ((next = stream.next()) != null) {
      if (next === quote && !escaped) {
        state.tokenize = tokenBase;
        break;
      }
      escaped = !escaped && next === "\\";
    }
    return "string";
  };
}

function tokenLongString(stream, state) {
  if (stream.match(/^.*?\]\]/)) {
    state.tokenize = tokenBase;
  } else {
    stream.skipToEnd();
  }
  return "string";
}

export const moonscript = {
  name: "moonscript",
  startState: () => ({ tokenize: tokenBase }),
  token: (stream, state) => {
    if (stream.eatSpace()) return null;
    return state.tokenize(stream, state);
  },
  languageData: {
    commentTokens: { line: "--" },
  },
};
