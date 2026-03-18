#!/usr/bin/env node
"use strict";

/**
 * Finds the earliest point where parsing becomes valid if we synthetically add closers.
 * This uses Acorn for correctness (handles regex literals, strings, etc.).
 *
 * Usage:
 *   node find_unclosed_by_acorn.js index.js
 */

const fs = require("fs");
const acorn = require("acorn");

const file = process.argv[2] || "index.js";
const code = fs.readFileSync(file, "utf8");
const lines = code.split(/\r?\n/);

function tryParse(src) {
  try {
    acorn.parse(src, {
      ecmaVersion: "latest",
      sourceType: "script",
      allowHashBang: true,
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, e };
  }
}

// If it parses, we are done
const base = tryParse(code);
if (base.ok) {
  console.log("✅ File parses. No syntax issue.");
  process.exit(0);
}

// At EOF issues, adding the right closers at end will make parse succeed.
// We'll try combinations of common closers.
const candidates = [
  "}\n",
  "})\n",
  "});\n",
  "});\n});\n",
  "});\n});\n});\n",
  "}\n});\n",
  "}\n}\n",
  "}\n}\n});\n",
  "});\n}\n",
  "});\n});\n}\n",
];

let fixed = null;
for (const add of candidates) {
  const res = tryParse(code + "\n" + add);
  if (res.ok) {
    fixed = add;
    break;
  }
}

console.log("❌ Base parse fails:", base.e.message);
console.log("Base error loc:", base.e.loc ? `${base.e.loc.line}:${base.e.loc.column}` : "unknown");

if (!fixed) {
  console.log("\nNo simple closer combination fixed it. We'll bisect the file to find the last fully-parsable prefix.");
} else {
  console.log("\n✅ Parsing succeeds if you append the following at EOF:\n");
  console.log("----- APPEND THIS -----");
  process.stdout.write(fixed);
  console.log("----- END APPEND -----\n");
  console.log("This indicates you're missing these closers (or equivalent) above EOF.");
  process.exit(0);
}

// Bisect for last parsable prefix using Acorn (accurate)
function parsePrefix(n) {
  const prefix = lines.slice(0, n).join("\n");
  const r = tryParse(prefix);
  return r.ok;
}

let lo = 1, hi = lines.length;
while (lo + 1 < hi) {
  const mid = Math.floor((lo + hi) / 2);
  if (parsePrefix(mid)) lo = mid;
  else hi = mid;
}

console.log("\n=== ACORN PREFIX BISECT ===");
console.log("LAST_GOOD_LINE =", lo);
console.log("FIRST_BAD_LINE =", hi);

const start = Math.max(1, hi - 25);
const end = Math.min(lines.length, hi + 25);
console.log(`\n--- CONTEXT lines ${start}..${end} ---`);
for (let i = start; i <= end; i++) {
  const mark = i === hi ? ">>" : "  ";
  console.log(`${mark} ${String(i).padStart(6)} | ${lines[i - 1]}`);
}

process.exit(1);

