#!/usr/bin/env node
/**
 * Cross-check a model name between the aggregate database and the cached price table,
 * to tell "we have no price for this model" apart from "we failed to apply a price we had".
 */
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const roaming = path.join(os.homedir(), "AppData", "Roaming");
const currentDir = path.join(roaming, "com.glassusage.desktop");
const legacyDir = path.join(roaming, "com.glassusage.app");
const dir = fs.existsSync(path.join(currentDir, "usage.db")) ? currentDir : legacyDir;
const needle = (process.argv[2] ?? "kimi").toLowerCase();

const db = new DatabaseSync(path.join(dir, "usage.db"), { readOnly: true });
console.log(`--- usage_events matching "${needle}" ---`);
for (const r of db
  .prepare(
    `SELECT source, model, model_norm, count(*) events,
            sum(cost_usd IS NULL) unpriced, round(sum(coalesce(cost_usd,0)),4) cost,
            datetime(min(ts_ms)/1000,'unixepoch','localtime') first,
            datetime(max(ts_ms)/1000,'unixepoch','localtime') last
     FROM usage_events WHERE lower(model_norm) LIKE '%' || ? || '%'
     GROUP BY source, model, model_norm ORDER BY events DESC`,
  )
  .all(needle)) {
  console.log(
    `  ${r.source.padEnd(12)} model=${String(r.model).padEnd(28)} norm=${String(r.model_norm).padEnd(22)} ` +
      `events=${String(r.events).padEnd(6)} unpriced=${String(r.unpriced).padEnd(6)} cost=${r.cost}  ${r.first} .. ${r.last}`,
  );
}
db.close();

const cache = path.join(dir, "pricing-cache.json");
console.log(`\n--- price table keys matching "${needle}" ---`);
if (!fs.existsSync(cache)) {
  console.log("  (no pricing-cache.json)");
} else {
  const raw = JSON.parse(fs.readFileSync(cache, "utf8"));
  const table = raw.models ?? raw.entries ?? raw;
  const keys = Object.keys(table).filter((k) => k.toLowerCase().includes(needle));
  console.log(`  cache has ${Object.keys(table).length} entries, ${keys.length} match`);
  for (const k of keys.slice(0, 40)) {
    const v = table[k];
    const inp = v?.input ?? v?.input_cost_per_token;
    const out = v?.output ?? v?.output_cost_per_token;
    console.log(`  ${k.padEnd(46)} in=${inp}  out=${out}`);
  }
}
