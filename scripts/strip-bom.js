#!/usr/bin/env node
// Strips a leading UTF-8 BOM from each file named on the command line, in
// place. dart-sass writes one in compressed mode whenever the output holds a
// non-ASCII character (see assets/dashboard/*/style.scss's "\25B8" arrow), and
// a BOM inlined into a style tag corrupts the first CSS rule.
"use strict";

const fs = require("fs");

const BOM = Buffer.from([0xef, 0xbb, 0xbf]);

for (const path of process.argv.slice(2)) {
  const contents = fs.readFileSync(path);
  if (contents.subarray(0, 3).equals(BOM)) {
    fs.writeFileSync(path, contents.subarray(3));
  }
}
