#!/usr/bin/env node
import { DatabaseSync } from "node:sqlite";
import os from "node:os";
import path from "node:path";

const db = new DatabaseSync(
  path.join(os.homedir(), "AppData", "Roaming", "com.glassusage.desktop", "usage.db"),
  { readOnly: true },
);

const today = db
  .prepare(
    `SELECT count(*) c,
            datetime(min(ts_ms)/1000,'unixepoch','localtime') fa,
            datetime(max(ts_ms)/1000,'unixepoch','localtime') la
     FROM usage_events
     WHERE date(ts_ms/1000,'unixepoch','localtime') = date('now','localtime')`,
  )
  .get();
console.log("today", today);

const broken = db
  .prepare(
    `SELECT CAST(strftime('%s', datetime(ts_ms/1000, 'unixepoch', 'localtime', 'start of hour')) AS INTEGER) AS b,
            count(*) c
     FROM usage_events
     WHERE date(ts_ms/1000,'unixepoch','localtime') = date('now','localtime')
     GROUP BY b`,
  )
  .all();
console.log("start-of-hour buckets", broken);

const fixed = db
  .prepare(
    `SELECT unixepoch(strftime('%Y-%m-%d %H:00:00', ts_ms/1000, 'unixepoch', 'localtime'), 'utc') AS b,
            count(*) c,
            sum(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens) tok
     FROM usage_events
     WHERE date(ts_ms/1000,'unixepoch','localtime') = date('now','localtime')
     GROUP BY b ORDER BY b`,
  )
  .all();
console.log("fixed hour buckets (utc modifier)", fixed.length);
for (const r of fixed) {
  console.log(" ", new Date(r.b * 1000).toString(), "events=", r.c, "tok=", r.tok);
}
db.close();
