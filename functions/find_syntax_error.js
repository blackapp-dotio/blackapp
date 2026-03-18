#!/usr/bin/env node
"use strict";

/**
 * Deterministically pinpoint "Unexpected end of input" / syntax breaks in a huge index.js.
 *
 * Usage:
 *   cd functions
 *   node find_syntax_error.js index.js
 *
 * Output:
 *   - LAST_GOOD_LINE / FIRST_BAD_LINE (binary search with node --check)
 *   - A context window around FIRST_BAD_LINE
 *   - Unclosed bracket stack (ignoring comments/strings)
 *   - Nearby "exports.* =" anchors around the failure
 */

const fs = require("fs");
const { execSync } = require("child_process");
const path = process.argv[2] || "index.js";

if (!fs.existsSync(path)) {
  console.error(`File not found: ${path}`);
  process.exit(1);
}

const lines = fs.readFileSync(path, "utf8").split(/\r?\n/);
const total = lines.length;

function nodeCheck(uptoLine) {
  const tmp = ".__syntax_check_tmp.js";
  fs.writeFileSync(tmp, lines.slice(0, uptoLine).join("\n"), "utf8");
  try {
    execSync(`node --check ${tmp}`, { stdio: "pipe" });
    fs.unlinkSync(tmp);
    return { ok: true };
  } catch (e) {
    fs.unlinkSync(tmp);
    const msg = (e && e.stderr ? String(e.stderr) : String(e)).trim();
    return { ok: false, msg };
  }
}

function bisect() {
  // If full parses, you're done.
  const full = nodeCheck(total);
  if (full.ok) return { fullOk: true };

  let lo = 1, hi = total; // [lo ok] [hi bad]
  // Ensure lo is ok (find a known-good prefix)
  // If line 1 already fails, hi will converge to 1.
  if (!nodeCheck(lo).ok) {
    // Start at 0-length "file"
    lo = 0;
  } else {
    // Grow lo until it fails, to seed the bisect properly
    let step = 64;
    while (lo + step < hi && nodeCheck(lo + step).ok) lo += step, step *= 2;
  }

  while (lo + 1 < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (nodeCheck(mid).ok) lo = mid;
    else hi = mid;
  }
  return { fullOk: false, lastGood: lo, firstBad: hi, fullMsg: full.msg };
}

/**
 * Scan prefix [1..N] for unclosed bracket stack ignoring strings/comments.
 * Returns stack of openings (most recent last).
 */
function scanUnclosed(prefixLine) {
  const s = lines.slice(0, prefixLine).join("\n");
  const stack = [];

  let line = 1, col = 0;
  let inLineComment = false;
  let inBlockComment = false;
  let inS = false, inD = false, inT = false; // ', ", `
  let esc = false;

  function push(ch) { stack.push({ ch, line, col }); }
  function pop(ch) {
    const top = stack[stack.length - 1];
    if (!top) return;
    if ((ch === "}" && top.ch === "{") ||
        (ch === ")" && top.ch === "(") ||
        (ch === "]" && top.ch === "[")) {
      stack.pop();
    }
  }

  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    const nx = s[i + 1];

    if (ch === "\n") {
      line++; col = 0; inLineComment = false;
      continue;
    }
    col++;

    if (inLineComment) continue;

    if (inBlockComment) {
      if (ch === "*" && nx === "/") { inBlockComment = false; i++; col++; }
      continue;
    }

    // string modes
    if (inS || inD || inT) {
      if (esc) { esc = false; continue; }
      if (ch === "\\") { esc = true; continue; }
      if (inS && ch === "'") inS = false;
      else if (inD && ch === '"') inD = false;
      else if (inT && ch === "`") inT = false;
      continue;
    }

    // comment starts
    if (ch === "/" && nx === "/") { inLineComment = true; i++; col++; continue; }
    if (ch === "/" && nx === "*") { inBlockComment = true; i++; col++; continue; }

    // string starts
    if (ch === "'") { inS = true; continue; }
    if (ch === '"') { inD = true; continue; }
    if (ch === "`") { inT = true; continue; }

    // brackets
    if (ch === "{" || ch === "(" || ch === "[") push(ch);
    else if (ch === "}" || ch === ")" || ch === "]") pop(ch);
  }

  return stack;
}

function printContext(centerLine, radius = 40) {
  const start = Math.max(1, centerLine - radius);
  const end = Math.min(total, centerLine + radius);
  console.log(`\n--- CONTEXT: lines ${start}..${end} (center=${centerLine}) ---`);
  for (let i = start; i <= end; i++) {
    const n = String(i).padStart(6, " ");
    console.log(`${n} | ${lines[i - 1]}`);
  }
}

/**
 * Find nearest exports.* anchor around a line range.
 */
function findExportsAnchors(aroundLine, lookback = 400, lookahead = 50) {
  const start = Math.max(1, aroundLine - lookback);
  const end = Math.min(total, aroundLine + lookahead);
  const re = /^\s*exports\.[A-Za-z0-9_$]+\s*=/;

  let last = null;
  let next = null;

  for (let i = aroundLine; i >= start; i--) {
    if (re.test(lines[i - 1])) { last = i; break; }
  }
  for (let i = aroundLine; i <= end; i++) {
    if (re.test(lines[i - 1])) { next = i; break; }
  }

  console.log(`\n--- EXPORTS ANCHORS near line ${aroundLine} ---`);
  if (last) console.log(`Last exports.*= at line ${last}: ${lines[last - 1].trim()}`);
  else console.log("No previous exports.*= found in lookback window.");

  if (next && next !== last) console.log(`Next exports.*= at line ${next}: ${lines[next - 1].trim()}`);
  else console.log("No next exports.*= found in lookahead window (or same as last).");
}

(function main() {
  console.log(`File: ${path}`);
  console.log(`Total lines: ${total}`);

  const b = bisect();
  if (b.fullOk) {
    console.log("✅ node --check passes for the full file. No syntax error detected.");
    process.exit(0);
  }

  console.log("\n=== PARSE BISECT RESULT ===");
  console.log("LAST_GOOD_LINE =", b.lastGood);
  console.log("FIRST_BAD_LINE =", b.firstBad);

  // Show node error message from checking full file (often includes line number)
  if (b.fullMsg) {
    console.log("\n=== node --check full-file error (for reference) ===");
    console.log(b.fullMsg.split("\n").slice(-10).join("\n"));
  }

  // Print context around first bad line
  printContext(b.firstBad, 60);

  // Unclosed stack at FIRST_BAD_LINE prefix
  const stack = scanUnclosed(b.firstBad);
  console.log("\n=== UNCLOSED OPENINGS (ignoring strings/comments) ===");
  console.log("Count =", stack.length);
  const head = stack.slice(0, 12);
  const tail = stack.slice(-12);

  console.log("\nFirst 12 unmatched openings:");
  head.forEach((x, i) => {
    const t = (lines[x.line - 1] || "").trim();
    console.log(`${String(i + 1).padStart(2, " ")}. '${x.ch}' at line ${x.line}, col ${x.col} | ${t}`);
  });

  console.log("\nLast 12 unmatched openings (most actionable):");
  tail.forEach((x, i) => {
    const t = (lines[x.line - 1] || "").trim();
    console.log(`${String(i + 1).padStart(2, " ")}. '${x.ch}' at line ${x.line}, col ${x.col} | ${t}`);
  });

  // Show exports anchors near failure
  findExportsAnchors(b.firstBad);

  console.log("\n=== WHAT TO DO NEXT ===");
  console.log("1) Focus on the LAST 12 unmatched openings above. Those are the newest unclosed tokens.");
  console.log("2) Jump to each reported line and verify the block closes (often missing '});' for onRequest/onWrite).");
  console.log("3) After fixing one closure, rerun: node find_syntax_error.js index.js");
})();

