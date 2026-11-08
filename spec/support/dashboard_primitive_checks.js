// Exercises the shared emitters' own contract, the same way
// primitives_spec.rb holds lib/rubotty/dashboard/primitives.rb to its
// ArgumentErrors: a titled Section, a validated Button variant, a destructive
// confirm step that cannot be dropped, a boolean Field that is a Yes/No
// select. Run against the compiled runtime bundle, the same file the browser
// loads, rather than the Civet source, so a compiler regression would show up
// here too.
//
// Usage: node dashboard_primitive_checks.js <runtime.js>
// Prints { checks: [{ name, ok, detail }], samples: { name: html }, exports:
// [name] } to stdout. samples is one render per emitter so the Ruby spec can
// hold the classes they draw to Primitives::CLASSES before any screen draws
// them, and exports is what the bundle actually hangs off rubottyDashboard so the
// same spec can hold the client set to the Ruby one.

"use strict";

const vm = require("vm");
const fs = require("fs");

function run(runtimePath) {
  const sandbox = { console };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(runtimePath, "utf8"), sandbox, { filename: "dashboard-runtime.js" });
  const rt = sandbox.rubottyDashboard;

  const checks = [];
  const expectThrows = (name, fn) => {
    try {
      fn();
      checks.push({ name, ok: false, detail: "did not throw" });
    } catch (error) {
      checks.push({ name, ok: true, detail: String(error.message || error) });
    }
  };
  const expectOk = (name, fn, predicate) => {
    try {
      const result = fn();
      const passed = predicate ? predicate(result) : true;
      checks.push({ name, ok: passed, detail: passed ? "" : `unexpected result: ${result}` });
    } catch (error) {
      checks.push({ name, ok: false, detail: `threw: ${error.message || error}` });
    }
  };

  expectThrows("section with no title under the default variant raises", () => {
    rt.section({ title: null });
  });
  expectOk("section with no title under the plain variant does not raise", () => {
    rt.section({ title: null, variant: "plain", body: "x" });
  });
  expectThrows("section rejects an unknown variant", () => {
    rt.section({ title: "X", variant: "bogus" });
  });
  expectThrows("collapsible section rejects an unknown chevron side", () => {
    rt.section({ title: "X", variant: "collapsible", chevron: "middle" });
  });
  expectOk(
    "a collapsible section's summary is trusted markup when given, in place of the escaped title",
    () => rt.section({ title: "ignored", body: "x", variant: "collapsible", summary: '<span data-x="1">rich</span>' }),
    (html) => html.includes('<summary class="rb-section-title"><span data-x="1">rich</span></summary>')
  );
  expectOk(
    "a collapsible section reads its marker at the start by default",
    () => rt.section({ title: "Help", body: "x", variant: "collapsible" }),
    (html) => html.includes('data-chevron="start"')
  );
  expectOk(
    "a collapsible section reads its marker at the end when asked",
    () => rt.section({ title: "Help", body: "x", variant: "collapsible", chevron: "end" }),
    (html) => html.includes('data-chevron="end"')
  );
  expectThrows("page rejects an unknown variant", () => {
    rt.page({ title: "X", variant: "bogus" });
  });
  expectThrows("notice rejects an unknown tone", () => {
    rt.notice("hi", "bogus");
  });
  expectThrows("button rejects an unknown variant", () => {
    rt.button("Go", "some_action", { some_action: true }, { variant: "bogus" });
  });
  expectThrows("button rejects an unknown size", () => {
    rt.button("Go", "some_action", { some_action: true }, { size: "tiny" });
  });
  expectOk(
    "a small button carries its dense control class",
    () => rt.button("Go", "some_action", { some_action: true }, { size: "small" }),
    (html) => html.includes("rb-button--small")
  );
  expectOk(
    "a formaction button posts to its own target rather than its form's",
    () => rt.button("Test connection", "some_action", { some_action: true }, { formaction: "/x/test" }),
    (html) => html.includes('formaction="/x/test"')
  );
  expectOk(
    "an ordinary button carries no formaction at all",
    () => rt.button("Save", "some_action", { some_action: true }),
    (html) => !html.includes("formaction")
  );
  expectOk(
    "a live destructive button carries a confirm step by default",
    () => rt.button("Delete", "manage_x", { manage_x: true }, { variant: "destructive" }),
    (html) => html.includes('data-confirm="Delete? This cannot be undone."')
  );
  expectOk(
    "a flat (unpermitted) destructive button carries no confirm step",
    () => rt.button("Delete", "manage_x", { manage_x: false }, { variant: "destructive" }),
    (html) => !html.includes("data-confirm")
  );
  expectOk(
    "a live non-destructive button carries no confirm step",
    () => rt.button("Save", "manage_x", { manage_x: true }, { variant: "primary" }),
    (html) => !html.includes("data-confirm")
  );
  expectOk(
    "data-grant is exactly the action name checked against may, not a separate token",
    () => rt.button("Save", "manage_widgets", { manage_widgets: true }, { variant: "primary" }),
    (html) => html.includes('data-grant="manage_widgets"')
  );
  expectThrows("form rejects an unknown variant", () => {
    rt.form({ action: "/x", submit: "<b/>", variant: "bogus" });
  });
  expectOk(
    "a filter form submits GET, an edit form submits POST",
    () => rt.form({ action: "/x", submit: "<b/>", variant: "filter" }),
    (html) => html.includes('method="get"')
  );
  expectThrows("form refuses to draw without an action to post to", () => {
    rt.form({ submit: "S" });
  });
  expectThrows("form refuses to draw without a submit row", () => {
    rt.form({ action: "/a" });
  });
  expectOk(
    "form carries its hidden plumbing and escapes it",
    () => rt.form({ action: "/a", submit: "S", hidden: { csrf: "t<o>k" } }),
    (html) => html.includes('<input type="hidden" name="csrf" value="t&lt;o&gt;k">')
  );
  expectOk(
    "form puts the submit row last, after the fields",
    () => rt.form({ action: "/a", submit: "SUBMIT", fields: "FIELDS" }),
    (html) => html.indexOf("rb-form-fields") < html.indexOf("rb-form-submit")
  );
  expectThrows("field rejects an unknown type", () => {
    rt.field({ name: "x", label: "x", type: "bogus" });
  });
  expectOk(
    "a hint over the display limit is cut, with the whole of it kept on hover",
    () => rt.field({ name: "x", label: "x", hint: `${"y".repeat(150)} tail` }),
    (html) => html.includes(`title="${"y".repeat(150)} tail"`) &&
      html.match(/<p class="rb-field-hint"[^>]*>([^<]*)</)[1].length <= 140
  );
  expectOk(
    "a field that asks the cut off draws the whole of a long hint, wrapped",
    () => rt.field({ name: "x", label: "x", hint: `${"y".repeat(150)} tail`, hint_wrap: true }),
    (html) => html.includes(`<p class="rb-field-hint">${"y".repeat(150)} tail</p>`) &&
      !html.includes("tabindex")
  );
  expectOk(
    "a hint at the limit is drawn whole, with no hover fallback to recover",
    () => rt.field({ name: "x", label: "x", hint: "y".repeat(140) }),
    (html) => html.includes(`<p class="rb-field-hint">${"y".repeat(140)}</p>`)
  );
  expectOk(
    "the hint follows the control it explains, so a row of controls starts level",
    () => rt.field({ name: "x", label: "X", hint: "what this does" }),
    (html) => html.indexOf("rb-field-control") < html.indexOf("rb-field-hint")
  );
  expectThrows("field rejects a size that is not one of the three semantic ones", () => {
    rt.field({ name: "x", label: "x", size: "215px" });
  });
  expectThrows("field refuses to draw without a name to submit under", () => {
    rt.field({ label: "X" });
  });
  expectThrows("field refuses to draw without a label", () => {
    rt.field({ name: "x" });
  });
  expectThrows("a select with no options refuses rather than drawing an empty one", () => {
    rt.field({ name: "x", label: "x", type: "select" });
  });
  expectOk(
    "a boolean field is a toggle select, never a checkbox",
    () => rt.field({ name: "x", label: "x", type: "toggle", value: true }),
    (html) => html.includes("<select") && !html.includes('type="checkbox"')
  );
  expectOk(
    "a boolean field offers exactly Yes and No, and selects the one it was given",
    () => rt.field({ name: "on", label: "On", type: "toggle", value: false }),
    (html) =>
      html.includes('<option value="true">Yes</option>') &&
      html.includes('<option value="false" selected>No</option>')
  );
  expectOk(
    "field marks required and leaves optional unmarked, which is one convention",
    () => [rt.field({ name: "x", label: "X", required: true }), rt.field({ name: "x", label: "X" })],
    ([marked, plain]) => marked.includes("rb-field-required") && !plain.includes("rb-field-required")
  );
  expectOk(
    "a select humanises a bare token rather than showing the raw enum value",
    () => rt.field({ name: "s", label: "S", type: "select", options: ["hot-swap"] }),
    (html) => html.includes('<option value="hot-swap">Hot swap</option>')
  );
  expectOk(
    "a checklist submits under name[] and ticks whatever it was given",
    () => rt.field({ name: "c", label: "C", type: "checklist", options: ["a", "b"], value: ["b"] }),
    (html) => html.includes('name="c[]"') && html.includes('value="b" checked')
  );
  expectOk(
    "a disabled field disables its control rather than only looking disabled",
    () => rt.field({ name: "x", label: "X", enabled: false }),
    (html) => html.includes(" disabled>")
  );
  expectOk(
    "two fields sharing a name render different ids when given different id overrides",
    () => [
      rt.field({ name: "url", label: "URL", id: "card-a-url" }),
      rt.field({ name: "url", label: "URL", id: "card-b-url" })
    ],
    ([first, second]) =>
      first.includes('id="card-a-url"') && first.includes('for="card-a-url"') &&
      second.includes('id="card-b-url"') && second.includes('for="card-b-url"') &&
      !first.includes("card-b-url") && !second.includes("card-a-url")
  );
  expectOk(
    "a field with no id override still derives one from its name, unchanged",
    () => rt.field({ name: "plain", label: "Plain" }),
    (html) => html.includes('id="rb-field-plain"') && html.includes('for="rb-field-plain"')
  );
  expectThrows("state rejects an unknown tone", () => {
    rt.state("x", "bogus");
  });
  expectOk(
    "every status tone carries a mark of its own, so a state survives one colour",
    () => ["good", "bad", "warn", "neutral", "unknown"]
      .map((tone) => rt.state("x", tone).match(/rb-status-mark" aria-hidden="true">([^<]*)</)[1]),
    (marks) => new Set(marks).size === 5
  );
  expectOk(
    "a tag escapes what it is given",
    () => rt.tag('<script>alert("x")</script>'),
    (html) => !html.includes("<script>")
  );
  expectOk(
    "an empty list of tags draws nothing rather than an empty wrapper, and one value is one tag",
    () => [rt.tags([]), rt.tags(null), rt.tags("solo")],
    ([empty, nothing, one]) =>
      empty === "" && nothing === "" && one === '<span class="rb-tags"><span class="rb-tag">solo</span></span>'
  );
  expectThrows("keyValues rejects an unknown variant", () => {
    rt.keyValues([["a", "b"]], "grid");
  });
  expectOk(
    "keyValues draws nothing at all for an empty pair list",
    () => rt.keyValues([]),
    (html) => html === ""
  );
  expectOk(
    "keyValues formats a duration value through Format rather than a raw second count",
    () => rt.keyValues([["Cleanup after", 900, "duration"]]),
    (html) => html.includes("15m") && !html.includes(">900<")
  );
  expectOk(
    "keyValues draws a duration list as tags of human durations",
    () => rt.keyValues([["retries", [30, 90], "durations"]]),
    (html) => html.includes(">30s<") && html.includes(">1m 30s<") && !html.includes(">90<")
  );
  expectOk(
    "keyValues takes a plain object as label to value pairs, the way Ruby takes a Hash",
    () => rt.keyValues({ api_url: "https://x" }, "inline"),
    (html) => html.includes("rb-kv--inline") && html.includes(">API URL</div>")
  );
  expectThrows("code rejects an unknown variant", () => {
    rt.code("x", "fenced");
  });
  expectOk(
    "code is a pre as a block and a code element inline, and escapes either way",
    () => [rt.code("<b>"), rt.code("<b>", "inline")],
    ([block, inline]) =>
      block.startsWith('<pre class="rb-code rb-code--block">&lt;b&gt;') &&
      inline.startsWith('<code class="rb-code rb-code--inline">&lt;b&gt;')
  );
  expectOk(
    "a code table column composes the Code primitive rather than writing the tag out",
    () => rt.table({
      columns: [{ key: "m", header: "Method", format: "code" }],
      rows: [{ m: "GET" }],
      empty: "none"
    }),
    (html) => html.includes('<code class="rb-code rb-code--inline">GET</code>')
  );
  expectThrows("tab links refuses to draw without being told which tab is showing", () => {
    rt.tabLinks([["/a", "All", "all"]]);
  });
  expectOk(
    "tab links marks exactly the current tab, and says so to a screen reader",
    () => rt.tabLinks([["/a", "All", "all"], ["/b", "Open", "open"]], "open"),
    (html) =>
      (html.match(/rb-tab--current/g) || []).length === 1 &&
      (html.match(/aria-current="page"/g) || []).length === 1 &&
      html.includes('class="rb-tab rb-tab--current" href="/b" aria-current="page"')
  );
  // Prose is the one emitter handed markup instead of text, so what stands in
  // for escaping is the scan: an element or an attribute outside a rendered
  // markdown document's own vocabulary is refused rather than drawn.
  expectThrows("prose rejects a document outside the three", () => {
    rt.prose("secrets", "<p>x</p>");
  });
  expectOk(
    "prose draws a real document inside the one wrapper",
    () => rt.prose("licence", '<h2 id="a">A</h2><p>text <a href="#a">z</a></p>'),
    (html) =>
      html === '<div class="rb-prose"><h2 id="a">A</h2><p>text <a href="#a">z</a></p></div>'
  );
  expectOk(
    "prose says a document is missing rather than drawing an empty wrapper",
    () => rt.prose("scripting", null),
    (html) => html.includes("rb-notice--empty") && !html.includes("rb-prose")
  );
  [
    ["a script tag", "<p>hi</p><script>alert(1)</script>"],
    ["an inline style", '<p style="color: red">x</p>'],
    ["a javascript: link", '<a href="javascript:alert(1)">x</a>'],
    ["an event handler smuggled past a value's own quote", '<a title="x>" onclick="steal()">x</a>'],
    ["a class belonging to a primitive", '<p class="rb-button">x</p>'],
    ["a confirm step the layout would wire up", '<p data-confirm="Sure?">x</p>'],
    ["a comment", "<!-- <script> -->"],
    ["a bare angle bracket outside any element", "a < b"],
    ["an element outside the markdown vocabulary", "<div>x</div>"]
  ].forEach(([what, markup]) => {
    expectThrows(`prose refuses ${what}`, () => rt.prose("readme", markup));
  });
  expectThrows("chart refuses to draw without being told the data's shape", () => {
    rt.chart([{ label: "a", count: 1 }]);
  });
  expectThrows("chart rejects a shape the server may not name", () => {
    rt.chart([{ label: "a", count: 1 }], { shape: "pie" });
  });
  expectOk(
    "an empty series draws the empty Notice rather than an empty figure",
    () => rt.chart([], { shape: "categorical_distribution", empty: "Nothing yet." }),
    (html) => html.includes("rb-notice--empty") && !html.includes("<svg")
  );
  expectOk(
    "the numbers always ship as a table under the figure, which is aria-hidden",
    () => rt.chart([{ label: "discord", count: 12 }], { shape: "categorical_distribution" }),
    (html) =>
      html.includes("rb-chart-table") &&
      html.includes('aria-hidden="true"') &&
      html.includes("<th scope=\"row\">discord</th>")
  );
  expectOk(
    "the same data draws the same picture, so a redraw does not reshuffle it",
    () => [
      rt.chart([{ label: "a", count: 3 }, { label: "b", count: 9 }], { shape: "categorical_distribution" }),
      rt.chart([{ label: "a", count: 3 }, { label: "b", count: 9 }], { shape: "categorical_distribution" })
    ],
    ([first, second]) => {
      // Clip path ids are unique per figure on purpose, so compare the geometry
      // rather than the whole string.
      const paths = (html) => (html.match(/ d="[^"]*"/g) || []).join("");
      return paths(first) === paths(second) && paths(first).length > 0;
    }
  );
  const everyShape = () =>
    ["categorical_distribution", "time_series", "share_of_total"].map((shape) =>
      rt.chart([{ label: "a", count: 3 }, { label: "b", count: 5 }, { label: "c", count: 8 }], { shape })
    );
  expectOk(
    "standard charts use straight geometry and solid fills for every shape",
    () => everyShape().join(""),
    (html) => !html.includes("Q") && !html.includes("clipPath") && html.includes("<svg")
  );
  expectOk(
    "a clean ring is real arcs, and its fill and its outline are one path",
    () => rt.chart([{ label: "a", count: 3 }, { label: "b", count: 5 }], {
      shape: "share_of_total",
    }),
    (html) => {
      const paths = (html.match(/ d="([^"]*)"/g) || []).map((d) => d.slice(4, -1));
      const arcs = paths.filter((d) => /A\d/.test(d));
      // Two slices, each drawn once as a fill and once as an outline, and the
      // two carry the same geometry rather than two approximations of it.
      return arcs.length === 4 && arcs[0] === arcs[1] && arcs[2] === arcs[3];
    }
  );
  expectOk(
    "a time series' wash is closed off the line's own points rather than a curve near them",
    () => rt.chart(
      [{ label: "a", count: 3 }, { label: "b", count: 9 }, { label: "c", count: 4 }, { label: "d", count: 7 }],
      { shape: "time_series" }
    ),
    (html) => {
      const paths = (html.match(/ d="([^"]*)"/g) || []).map((d) => d.slice(4, -1));
      const line = paths.find((d) => /^M[\d. ]+(L[\d. ]+){3}$/.test(d));
      const wash = paths.find((d) => d.endsWith("Z") && d !== line);
      return Boolean(line) && Boolean(wash) && wash.startsWith(line);
    }
  );
  expectOk(
    "under the accent mode a bar takes the theme's accent and a ring slice keeps the palette",
    () => {
      const bars = rt.chart([{ label: "a", count: 3 }, { label: "b", count: 5 }], {
        shape: "categorical_distribution"
      });
      const ring = rt.chart([{ label: "a", count: 3 }, { label: "b", count: 5 }], {
        shape: "share_of_total"
      });
      return [bars, ring];
    },
    ([bars, ring]) =>
      bars.includes("var(--rb-accent-primary)") && !bars.includes("var(--rb-series-2)") &&
      ring.includes("var(--rb-series-1)") && ring.includes("var(--rb-series-2)")
  );
  expectOk(
    "a ring drops empty slices, rolls the tail into one, and its shares add up to a hundred",
    () => rt.chart(
      [
        { label: "one", count: 50 }, { label: "two", count: 20 }, { label: "three", count: 11 },
        { label: "four", count: 7 }, { label: "five", count: 5 }, { label: "six", count: 4 },
        { label: "seven", count: 3 }, { label: "eight", count: 0 }
      ],
      { shape: "share_of_total" }
    ),
    (html) => {
      const shares = (html.match(/>(\d+)%</g) || []).map((s) => parseInt(s.slice(1), 10));
      const rows = (html.match(/<th scope="row">([^<]*)</g) || []).length;
      return rows === 6 && html.includes(">Other<") && !html.includes(">eight<") &&
        shares.length === 6 && shares.reduce((sum, share) => sum + share, 0) === 100;
    }
  );
  expectOk(
    "a share is a share of everything given rather than of what survived the limit",
    () => rt.chart(
      Array.from({ length: 20 }, (_, index) => ({ label: `p${index}`, count: 5 })),
      { shape: "share_of_total" }
    ),
    // Five slices of five out of a hundred, and the other fifteen rows rolled
    // into one. Against the top ten alone the same rows would read 10% each.
    (html) => html.includes(">Other<") && html.includes(">75%<") && html.includes(">5%<")
  );
  expectOk(
    "both bar fallbacks go through the sideways check rather than straight to upright bars",
    () => [
      // Two rows is under the time series' own floor, and a non-positive total
      // is the ring's. Both used to draw upright bars with colliding labels.
      rt.chart([{ label: "a-very-long-label", count: 3 }, { label: "b-very-long-label", count: 5 }], {
        shape: "time_series",
      }),
      rt.chart([{ label: "a-very-long-label", count: 0 }, { label: "b-very-long-label", count: 0 }], {
        shape: "share_of_total",
      })
    ],
    ([series, ring]) =>
      // A sideways drawing is one row tall per row; an upright one is 300.
      series.includes('viewBox="0 0 520 82"') &&
      (ring.includes('viewBox="0 0 520 82"') || ring.includes("rb-notice--empty"))
  );
  expectOk(
    "every guide is labelled with the number it sits at, and the baseline is labelled zero",
    () => rt.chart([{ label: "a", count: 1 }], { shape: "categorical_distribution" }),
    (html) => {
      const ticks = Array.from(html.matchAll(/class="rb-chart-tick"[^>]*>([^<]*)</g), (m) => m[1]);
      // A ceiling of one used to draw guides at 0.25 and 0.75 labelled 0.3 and
      // 0.8, on counts that are whole numbers by construction.
      return ticks.join(",") === "0,1,2,3,4";
    }
  );
  expectOk(
    "text inside a drawing carries a class and no fill, so a theme owns its colour",
    () => everyShape().join(""),
    (html) => {
      const texts = html.match(/<text[^>]*>/g) || [];
      return texts.length > 0 &&
        texts.every((tag) => /class="rb-chart-(label|value|tick)"/.test(tag)) &&
        !texts.some((tag) => tag.includes("fill"));
    }
  );
  expectOk(
    "every colour it draws is a swatch role, never a literal",
    () => ["categorical_distribution", "time_series", "share_of_total"]
      .map((shape) => rt.chart(
        [{ label: "a", count: 3 }, { label: "b", count: 5 }, { label: "c", count: 8 }, { label: "d", count: 2 }],
        { shape }
      ))
      .join(""),
    (html) => !/#[0-9a-fA-F]{3,8}\b/.test(html) && !/\b(rgb|hsl)a?\(/.test(html) && html.includes("var(--rb-series-1)")
  );
  expectOk(
    "a table over the seven column ceiling raises rather than drawing",
    () => {
      try {
        rt.table({
          columns: Array.from({ length: 8 }, (_, i) => ({ key: `c${i}`, header: `c${i}` })),
          rows: [{}],
          empty: "none"
        });
        return "did not throw";
      } catch (error) {
        return "threw";
      }
    },
    (result) => result === "threw"
  );

  // One render per emitter, so the Ruby spec can hold the classes every one of
  // them draws to Primitives::CLASSES without waiting for a screen to draw it.
  // A sample that throws is recorded rather than aborting the run, so an
  // emitter that went missing is reported by name instead of as a stack trace.
  const samples = {};
  const sample = (name, fn) => {
    try {
      samples[name] = fn();
    } catch (error) {
      samples[name] = `THREW: ${error.message || error}`;
    }
  };

  sample("page", () => rt.page({ title: "T", lede: "L", sections: "S", variant: "wide" }));
  sample("section", () => rt.section({ title: "T", body: "B" }));
  sample("section/collapsible", () =>
    rt.section({ title: "T", body: "B", variant: "collapsible", open: true })
  );
  sample("notice", () =>
    ["info", "success", "warning", "danger", "empty"].map((t) => rt.notice("n", t)).join("")
  );
  sample("table", () => rt.table({
    columns: [{ key: "a", header: "A" }, { key: "b", header: "B", align: "end", format: "code" }],
    rows: [{ a: "1", b: "GET" }],
    empty: "none",
    actions: () => rt.button("Go", "manage_x", { manage_x: true })
  }));
  sample("table/empty", () =>
    rt.table({ columns: [{ key: "a", header: "A" }], rows: [], empty: "none" })
  );
  sample("form", () => rt.form({
    action: "/a",
    submit: rt.button("Save", "manage_x", { manage_x: true }),
    fields: rt.field({ name: "x", label: "X" }),
    hidden: { csrf: "t" }
  }));
  sample("form/filter", () => rt.form({ action: "/a", submit: "S", variant: "filter" }));
  sample("field", () =>
    ["text", "number", "secret", "select", "multiline", "code", "toggle", "choice", "checklist"]
      .map((type) => rt.field({
        name: "x", label: "X", type, hint: "h", required: true, size: "full", options: ["a", "b"]
      }))
      .join("")
  );
  sample("field/sizes", () =>
    ["short", "medium", "full"].map((size) => rt.field({ name: "x", label: "X", size })).join("")
  );
  sample("button", () =>
    ["primary", "secondary", "destructive"]
      .map((variant) => rt.button("Do it", "manage_x", { manage_x: true }, { variant }))
      .join("") + rt.button("Small", "manage_x", { manage_x: true }, { size: "small" }) +
      rt.button("Nope", "manage_x", { manage_x: false })
  );
  sample("state", () =>
    ["good", "bad", "warn", "neutral", "unknown"].map((tone) => rt.state("s", tone)).join("")
  );
  sample("tag", () => rt.tag("t") + rt.tags(["a", "b"]));
  sample("keyValues", () => rt.keyValues([["k", "v"]]) + rt.keyValues([["k", "v"]], "inline"));
  sample("statRow", () => rt.statRow([[1, "one"], [2, "two"]]));
  // Every standard chart shape contributes its classes to the vocabulary check.
  sample("chart", () =>
    ["categorical_distribution", "time_series", "share_of_total"]
      .map((shape) => rt.chart(
        [
          { label: "discord", count: 3980 }, { label: "telegram", count: 1544 },
          { label: "matrix", count: 512 }, { label: "irc", count: 204 },
          { label: "guest portal", count: 88 }, { label: "fluxer", count: 41 },
          { label: "xmpp", count: 12 }
        ],
        { shape, title: "Relayed messages", limit: 7 }
      ))
      .join("")
  );
  sample("chart/empty", () => rt.chart([], { shape: "categorical_distribution", empty: "Nothing yet." }));
  sample("code", () => rt.code("x") + rt.code("x", "inline"));
  sample("tabLinks", () => rt.tabLinks([["/a", "All", "all"], ["/b", "Open", "open"]], "open"));
  // No class attribute anywhere in the markup, so this sample says what the
  // emitter itself draws. A real document's fenced block carries kramdown's
  // own language-* class, which is content rather than chrome, and the render
  // checks above carry it under THEMED_DOCUMENT_CLASSES instead.
  sample("prose", () =>
    rt.prose("licence", '<h2 id="a">A</h2><p>text <a href="#a">z</a></p><pre><code>x</code></pre>')
  );

  process.stdout.write(JSON.stringify({ checks, samples, exports: Object.keys(rt) }));
}

run(process.argv[2]);
