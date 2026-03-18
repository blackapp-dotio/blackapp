#!/usr/bin/env node
"use strict";

/**
 * Parse a JS file using Acorn and print the exact syntax error location + context.
 *
 * Usage:
 *   cd functions
 *   node locate_parse_error.js index.js
 */

const fs = require("fs");
const acorn = require("acorn");

const file = process.argv[2] || "index.js";
const code = fs.readFileSync(file, "utf8");
const lines = code.split(/\r?\n/);

function showContext(line, col, radius = 12) {
  const start = Math.max(1, line - radius);
  const end = Math.min(lines.length, line + radius);
  console.log(`\n--- CONTEXT lines ${start}..${end} (error at ${line}:${col}) ---`);
  for (let ln = start; ln <= end; ln++) {
    const mark = ln === line ? ">>" : "  ";
    console.log(`${mark} ${String(ln).padStart(6, " ")} | ${lines[ln - 1]}`);
  }
}

try {
  acorn.parse(code, {
    ecmaVersion: "latest",
    sourceType: "script", // Cloud Functions index.js is usually CommonJS
    allowHashBang: true,
    locations: true,
  });

  console.log("✅ Acorn parsed the file successfully (no syntax error).");
  console.log("If firebase deploy still fails, then it's runtime/module resolution, not syntax.");
  process.exit(0);
} catch (e) {
  console.log("❌ PARSE ERROR:");
  console.log("Message:", e.message);

  // Acorn supplies e.loc (line/column) for syntax errors
  const loc = e.loc || null;
  if (loc) {
    console.log("Location:", `${loc.line}:${loc.column}`);
    showContext(loc.line, loc.column);
  } else {
    console.log("No location data from parser.");
  }

  // Also print a small slice around e.pos if present
  if (typeof e.pos === "number") {
    const pos = e.pos;
    const lo = Math.max(0, pos - 120);
    const hi = Math.min(code.length, pos + 120);
    console.log("\n--- RAW WINDOW around error position ---");
    console.log(code.slice(lo, hi));
  }

  process.exit(1);
}

