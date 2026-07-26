#!/usr/bin/env node
/**
 * Inspect the aggregate database GlassUsage builds, for verifying a run.
 *
 * Prints row counts, per-source status (including the error each collector recorded), and
 * aggregate token totals. Model names and paths are shown because they are needed to tell
 * a working collector from a silently failing one; no prompt or completion text is stored
 * in this database at all.
 */
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const file =
  process.argv[2] ??
  path.join(os.homedir(), "AppData", "Roaming", "com.glassusage.app", "usage.db");

if (!fs.existsSync(file)) {
  console.log(`missing: ${file}`);
  process.exit(1);
}

const db = new DatabaseSync(file, { readOnly: true });

const table = (name) => {
  try {
    return db.prepare(`SELECT count(*) c FROM "${name}"`).get().c;
  } catch {
    return null;
  }
};

console.log(`db: ${file}\n`);

console.log("--- tables ---");
for (const t of db
  .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
  .all()) {
  console.log(`  ${t.name.padEnd(22)} rows=${table(t.name)}`);
}

const show = (label, sql) => {
  console.log(`\n--- ${label} ---`);
  try {
    const rows = db.prepare(sql).all();
    if (!rows.length) return console.log("  (none)");
    for (const r of rows) {
      console.log(
        "  " +
          Object.entries(r)
            .map(([k, v]) => `${k}=${v === null ? "-" : v}`)
            .join("  "),
      );
    }
  } catch (e) {
    console.log("  ERR: " + e.message);
  }
};

show(
  "source status",
  `SELECT source, instance, file_count, skipped_rows,
          datetime(last_scan_ms/1000,'unixepoch','localtime') AS last_scan,
          substr(coalesce(last_error,'-'),1,140) AS last_error
   FROM source_status ORDER BY source, instance`,
);

show(
  "totals by source",
  `SELECT source, surface, instance, count(*) events,
          sum(input_tokens) inp, sum(output_tokens) outp,
          sum(cache_read_tokens) cread, sum(cache_write_tokens) cwrite,
          round(sum(coalesce(cost_usd,0)),4) cost,
          sum(cost_usd IS NULL) unpriced,
          datetime(min(ts_ms)/1000,'unixepoch','localtime') AS first_seen,
          datetime(max(ts_ms)/1000,'unixepoch','localtime') AS last_seen
   FROM usage_events GROUP BY source, surface, instance ORDER BY 4 DESC`,
);

show(
  "top models",
  `SELECT model_norm, count(*) events,
          sum(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens) tok,
          round(sum(coalesce(cost_usd,0)),4) cost
   FROM usage_events GROUP BY model_norm ORDER BY tok DESC LIMIT 12`,
);

show(
  "daily rollup",
  `SELECT day, count(*) buckets, sum(events) events,
          sum(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens) tok,
          round(sum(cost_usd),4) cost
   FROM daily_rollup GROUP BY day ORDER BY day DESC LIMIT 10`,
);

// Mirrors what the Agents page shows, so a zero on screen can be checked against SQL.
show(
  "last 7 days by source and model",
  `SELECT source, model_norm, count(*) events,
          sum(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens) tok,
          round(sum(coalesce(cost_usd,0)),4) cost,
          sum(cost_usd IS NULL) unpriced
   FROM usage_events
   WHERE ts_ms >= (strftime('%s','now','-7 days') * 1000)
   GROUP BY source, model_norm ORDER BY source, tok DESC`,
);

show("scan watermarks", `SELECT count(*) files, source FROM scan_state GROUP BY source`);

db.close();
