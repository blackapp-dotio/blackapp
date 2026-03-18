#!/usr/bin/env node
"use strict";

/**
 * Bisects for earliest *real* syntax error by appending synthetic closing braces
 * for the prefix before calling node --check.
 *
 * Usage:
 *   cd functions
 *   node find_syntax_error_v2.js index.js
 */

const fs = require("fs");
const { execSync } = require("child_process");

const file = process.argv[2] || "index.js";
const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
const total = lines.length;

function scanUnclosed(text) {
  let line = 1, col = 0;
  let inLineComment = false, inBlockComment = false;
  let inS = false, inD = false, inT = false;
  let esc = false;

  const stack = [];
  function push(ch){ stack.push(ch); }
  function pop(ch){
    const top = stack[stack.length - 1];
    if (!top) return;
    if ((ch === "}" && top === "{") || (ch === ")" && top === "(") || (ch === "]" && top === "[")) {
      stack.pop();
    }
  }

  for (let i = 0; i < text.length; i++) {
    const ch = text[i], nx = text[i + 1];

    if (ch === "\n") { line++; col = 0; inLineComment = false; continue; }
    col++;

    if (inLineComment) continue;

    if (inBlockComment) {
      if (ch === "*" && nx === "/") { inBlockComment = false; i++; col++; }
      continue;
    }

    if (inS || inD || inT) {
      if (esc) { esc = false; continue; }
      if (ch === "\\") { esc = true; continue; }
      if (inS && ch === "'") inS = false;
      else if (inD && ch === '"') inD = false;
      else if (inT && ch === "`") inT = false;
      continue;
    }

    if (ch === "/" && nx === "/") { inLineComment = true; i++; col++; continue; }
    if (ch === "/" && nx === "*") { inBlockComment = true; i++; col++; continue; }

    if (ch === "'") { inS = true; continue; }
    if (ch === '"') { inD = true; continue; }
    if (ch === "`") { inT = true; continue; }

    if (ch === "{" || ch === "(" || ch === "[") push(ch);
    else if (ch === "}" || ch === ")" || ch === "]") pop(ch);
  }

  return { stack, inBlockComment, inS, inD, inT };
}

function synthClose(prefixText) {
  const st = scanUnclosed(prefixText);
  // If we are inside a string/comment at the cut, synthetic closing is unreliable.
  // But for most Cloud Functions files, the "end of input" is missing braces, not unterminated strings.
  const closers = [];
  for (let i = st.stack.length - 1; i >= 0; i--) {
    const open = st.stack[i];
    if (open === "{") closers.push("}");
    else if (open === "(") closers.push(")");
    else if (open === "[") closers.push("]");
  }
  return prefixText + "\n/*__SYNTH_CLOSE__*/\n" + closers.join("") + "\n";
}

function checkPrefix(n) {
  const tmp = ".__check_tmp.js";
  const prefix = lines.slice(0, n).join("\n");
  const closed = synthClose(prefix);
  fs.writeFileSync(tmp, closed, "utf8");
  try {
    execSync(`node --check ${tmp}`, { stdio: "pipe" });
    fs.unlinkSync(tmp);
    return true;
  } catch {
    fs.unlinkSync(tmp);
    return false;
  }
}

(function main() {
  console.log("File:", file);
  console.log("Total lines:", total);

  // If full file passes, stop.
  try {
    execSync(`node --check ${file}`, { stdio: "pipe" });
    console.log("✅ Full file parses. No syntax error.");
    return;
  } catch (e) {
    console.log("❌ Full file fails node --check (expected). Starting bisect...");
  }

  let lo = 0, hi = total;
  // Ensure lo parses (empty prefix should parse)
  while (lo + 1 < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (checkPrefix(mid)) lo = mid;
    else hi = mid;
  }

  console.log("\n=== SYNTH-CLOSE BISECT RESULT ===");
  console.log("LAST_GOOD_PREFIX_LINE =", lo);
  console.log("FIRST_BAD_PREFIX_LINE =", hi);
  console.log("\nShow context with:");
  console.log(`nl -ba ${file} | sed -n '${Math.max(1, hi - 40)},${Math.min(total, hi + 40)}p'`);
})();

