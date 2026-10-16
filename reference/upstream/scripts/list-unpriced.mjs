#!/usr/bin/env node
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const file = path.join(os.homedir(), "AppData", "Roaming", "com.glassusage.desktop", "usage.db");
if (!fs.existsSync(file)) {
  console.log("missing db");
  process.exit(1);
}
const db = new DatabaseSync(file, { readOnly: true });
console.log("--- unpriced models ---");
for (const r of db
  .prepare(
    `SELECT model_norm, count(*) c,
            sum(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens) tok
     FROM usage_events WHERE cost_usd IS NULL
     GROUP BY 1 ORDER BY c DESC`,
  )
  .all()) {
  console.log(`  ${r.model_norm.padEnd(28)} events=${r.c}  tok=${r.tok}`);
}
console.log("\n--- cost today ---");
for (const r of db
  .prepare(
    `SELECT round(sum(coalesce(cost_usd,0)),4) cost, count(*) events,
            sum(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens) tok
     FROM usage_events
     WHERE date(ts_ms/1000,'unixepoch','localtime') = date('now','localtime')`,
  )
  .all()) {
  console.log(r);
}
console.log("\n--- cost last 7 days ---");
for (const r of db
  .prepare(
    `SELECT round(sum(coalesce(cost_usd,0)),4) cost, count(*) events,
            sum(cost_usd IS NULL) unpriced
     FROM usage_events
     WHERE ts_ms >= (strftime('%s','now','localtime','-7 days')*1000)`,
  )
  .all()) {
  console.log(r);
}
db.close();
