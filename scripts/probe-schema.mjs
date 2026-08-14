#!/usr/bin/env node
/**
 * Structure-only schema prober.
 *
 * Prints the *shape* of local agent session files (key paths + value types) so the
 * collectors can be written against real data. Never prints string values, so no
 * conversation content, paths or credentials leave the machine.
 *
 * Usage: node scripts/probe-schema.mjs
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import readline from "node:readline";

const HOME = os.homedir();

/** Value types only. Strings are reduced to "string(len)" so no content leaks. */
function shape(value, depth = 0) {
  if (value === null) return "null";
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    return [shape(value[0], depth + 1) + `[${value.length}]`];
  }
  if (typeof value === "object") {
    if (depth > 4) return "{...}";
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = shape(v, depth + 1);
    return out;
  }
  if (typeof value === "number") return `number(${value})`;
  if (typeof value === "boolean") return "bool";
  return `string(${String(value).length})`;
}

/** Merge many shapes into one union shape so we see all optional keys. */
function merge(a, b) {
  if (a === undefined) return b;
  if (b === undefined) return a;
  if (typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
    const out = { ...a };
    for (const [k, v] of Object.entries(b)) out[k] = merge(out[k], v);
    return out;
  }
  return a;
}

/** A handful of keys are enum-like discriminators and safe to print verbatim. */
const SAFE_KEYS = new Set(["type", "role", "subtype", "kind", "event", "status"]);

function shapeWithDiscriminators(value, depth = 0) {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = SAFE_KEYS.has(k) && typeof v === "string" ? `"${v}"` : shapeWithDiscriminators(v, depth + 1);
    }
    return out;
  }
  return shape(value, depth);
}

function newestFile(dir, ext, recursive = true) {
  let best = null;
  const walk = (d) => {
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        if (recursive) walk(p);
      } else if (e.name.endsWith(ext)) {
        const st = fs.statSync(p);
        if (!best || st.mtimeMs > best.mtimeMs) best = { path: p, mtimeMs: st.mtimeMs, size: st.size };
      }
    }
  };
  walk(dir);
  return best;
}

async function probeJsonl(label, dir, ext = ".jsonl", maxLines = 4000) {
  console.log(`\n=== ${label} ===`);
  if (!fs.existsSync(dir)) return console.log("  (not present)");
  const f = newestFile(dir, ext);
  if (!f) return console.log("  (no matching files)");
  console.log(`  newest file size=${f.size}B`);

  const byType = new Map();
  const rl = readline.createInterface({ input: fs.createReadStream(f.path), crlfDelay: Infinity });
  let n = 0;
  for await (const line of rl) {
    if (++n > maxLines) break;
    if (!line.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    // Discriminate by the outermost type, plus nested payload.type for Codex.
    let key = obj.type ?? "(no type)";
    if (obj.payload && typeof obj.payload === "object" && obj.payload.type) key += `/${obj.payload.type}`;
    byType.set(key, merge(byType.get(key), shapeWithDiscriminators(obj)));
  }
  rl.close();

  for (const [k, v] of [...byType.entries()].sort()) {
    console.log(`  --- type=${k} ---`);
    console.log(
      JSON.stringify(v, null, 2)
        .split("\n")
        .map((l) => "  " + l)
        .join("\n"),
    );
  }
}

function listDir(label, dir, depth = 2) {
  console.log(`\n=== ${label} ===`);
  if (!fs.existsSync(dir)) return console.log("  (not present)");
  const walk = (d, prefix, lvl) => {
    let entries;
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries.slice(0, 40)) {
      const p = path.join(d, e.name);
      const st = (() => {
        try {
          return fs.statSync(p);
        } catch {
          return null;
        }
      })();
      console.log(`  ${prefix}${e.name}${e.isDirectory() ? "/" : ` (${st?.size ?? "?"}B)`}`);
      if (e.isDirectory() && lvl < depth) walk(p, prefix + "  ", lvl + 1);
    }
  };
  walk(dir, "", 0);
}

await probeJsonl("Claude Code — ~/.claude/projects/**/*.jsonl", path.join(HOME, ".claude", "projects"));
await probeJsonl("Codex — ~/.codex/sessions/**/*.jsonl", path.join(HOME, ".codex", "sessions"));
await probeJsonl("Pi — ~/.pi/agent/sessions/**/*.jsonl", path.join(HOME, ".pi", "agent", "sessions"));
await probeJsonl("Kimi Code — ~/.kimi-code/sessions/**/wire.jsonl", path.join(HOME, ".kimi-code", "sessions"));
listDir("OpenCode — ~/.local/share/opencode", path.join(HOME, ".local", "share", "opencode"));
listDir("Gemini/Antigravity — ~/.gemini", path.join(HOME, ".gemini"), 3);
