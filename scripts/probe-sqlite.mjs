#!/usr/bin/env node
/**
 * Read-only SQLite schema prober for the agents that store usage in databases.
 * Prints DDL and column names only — never row values.
 */
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = os.homedir();

function dumpSchema(label, file) {
  console.log(`\n======== ${label} ========`);
  console.log(`file: ${path.basename(file)}`);
  if (!fs.existsSync(file)) return console.log("  (missing)");
  let db;
  try {
    db = new DatabaseSync(file, { readOnly: true });
  } catch (e) {
    return console.log("  OPEN ERR: " + e.message);
  }
  try {
    const tables = db.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name").all();
    for (const t of tables) {
      const count = (() => {
        try {
          return db.prepare(`SELECT count(*) AS c FROM "${t.name}"`).get().c;
        } catch {
          return "?";
        }
      })();
      console.log(`\n--- table ${t.name} (rows=${count}) ---`);
      console.log(t.sql);
    }
  } catch (e) {
    console.log("  ERR: " + e.message);
  } finally {
    db.close();
  }
}

/** Print the JSON key skeleton of a JSON-valued column without leaking values. */
function dumpJsonColumn(label, file, table, column, limit = 300) {
  console.log(`\n-------- ${label}: ${table}.${column} JSON shape --------`);
  let db;
  try {
    db = new DatabaseSync(file, { readOnly: true });
  } catch (e) {
    return console.log("  OPEN ERR: " + e.message);
  }
  const paths = new Map();
  try {
    const rows = db.prepare(`SELECT "${column}" AS v FROM "${table}" LIMIT ${limit}`).all();
    for (const r of rows) {
      let o;
      try {
        o = JSON.parse(r.v);
      } catch {
        continue;
      }
      const walk = (x, p = "") => {
        if (x === null || typeof x !== "object") {
          const t = typeof x === "number" ? "number" : x === null ? "null" : typeof x;
          paths.set(p, t);
          return;
        }
        if (Array.isArray(x)) return walk(x[0], p + "[]");
        for (const [k, v] of Object.entries(x)) walk(v, p ? `${p}.${k}` : k);
      };
      walk(o);
    }
  } catch (e) {
    console.log("  ERR: " + e.message);
  } finally {
    db.close();
  }
  for (const [k, v] of [...paths.entries()].sort()) console.log(`  ${k}: ${v}`);
}

const opencode = path.join(HOME, ".local", "share", "opencode", "opencode.db");
dumpSchema("OpenCode", opencode);

const convDir = path.join(HOME, ".gemini", "antigravity", "conversations");
if (fs.existsSync(convDir)) {
  const biggest = fs
    .readdirSync(convDir)
    .filter((f) => f.endsWith(".db"))
    .map((f) => ({ f, size: fs.statSync(path.join(convDir, f)).size }))
    .sort((a, b) => b.size - a.size)[0];
  if (biggest) dumpSchema("Antigravity IDE conversation", path.join(convDir, biggest.f));
}

const agCli = path.join(HOME, ".gemini", "antigravity-cli", "conversations");
if (fs.existsSync(agCli)) {
  const f = fs.readdirSync(agCli).filter((x) => x.endsWith(".db"))[0];
  if (f) dumpSchema("Antigravity CLI conversation", path.join(agCli, f));
}

// Second pass: JSON column shapes, driven by CLI args so it can be re-run per table.
const [, , mode, table, column] = process.argv;
if (mode === "json" && table && column) dumpJsonColumn("OpenCode", opencode, table, column);
