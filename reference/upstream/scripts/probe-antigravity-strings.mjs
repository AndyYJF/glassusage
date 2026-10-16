#!/usr/bin/env node
/**
 * Second Antigravity pass: print only short identifier-looking strings at the field
 * paths that surround the token counters, so the collector can label model/provider.
 * Anything longer than 48 chars or not identifier-shaped is reported as a length only.
 */
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function readVarint(buf, pos) {
  let r = 0n;
  let s = 0n;
  while (pos < buf.length) {
    const b = buf[pos++];
    r |= BigInt(b & 0x7f) << s;
    if ((b & 0x80) === 0) return [r, pos];
    s += 7n;
    if (s > 70n) return null;
  }
  return null;
}

function decode(buf, depth = 0) {
  const fields = [];
  let pos = 0;
  while (pos < buf.length) {
    const kv = readVarint(buf, pos);
    if (!kv) return null;
    pos = kv[1];
    const fieldNo = Number(kv[0] >> 3n);
    const wire = Number(kv[0] & 7n);
    if (fieldNo === 0) return null;
    if (wire === 0) {
      const v = readVarint(buf, pos);
      if (!v) return null;
      fields.push({ fieldNo, wire, value: v[0] });
      pos = v[1];
    } else if (wire === 1) {
      if (pos + 8 > buf.length) return null;
      fields.push({ fieldNo, wire, value: buf.readDoubleLE(pos) });
      pos += 8;
    } else if (wire === 5) {
      if (pos + 4 > buf.length) return null;
      fields.push({ fieldNo, wire, value: buf.readFloatLE(pos) });
      pos += 4;
    } else if (wire === 2) {
      const l = readVarint(buf, pos);
      if (!l) return null;
      const len = Number(l[0]);
      pos = l[1];
      if (pos + len > buf.length) return null;
      const sub = buf.subarray(pos, pos + len);
      pos += len;
      const nested = depth < 6 && len > 1 ? decode(sub, depth + 1) : null;
      fields.push({ fieldNo, wire, value: nested ?? sub, raw: sub, nested: !!nested });
    } else return null;
  }
  return fields;
}

const get = (fields, no) => fields?.find((f) => f.fieldNo === no);
const getAll = (fields, no) => fields?.filter((f) => f.fieldNo === no) ?? [];

/** Only surface strings that look like model/provider identifiers. */
const IDENT = /^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,47}$/;
function ident(buf) {
  if (!buf || !Buffer.isBuffer(buf)) return null;
  const s = buf.toString("utf8");
  return IDENT.test(s) ? s : `<${buf.length}B>`;
}

const convDir = path.join(os.homedir(), ".gemini", "antigravity", "conversations");
const dbs = fs
  .readdirSync(convDir)
  .filter((f) => f.endsWith(".db"))
  .map((f) => ({ f, size: fs.statSync(path.join(convDir, f)).size }))
  .sort((a, b) => b.size - a.size)
  .slice(0, 4);

const modelIds = new Map();

for (const { f } of dbs) {
  const db = new DatabaseSync(path.join(convDir, f), { readOnly: true });
  console.log(`\n######## ${f} ########`);
  let printed = 0;
  for (const row of db.prepare("SELECT idx, data FROM gen_metadata ORDER BY idx").all()) {
    const top = decode(Buffer.from(row.data));
    if (!top) continue;
    const m1 = get(top, 1);
    if (!m1?.nested) continue;
    const usage = get(m1.value, 4);
    if (!usage?.nested) continue;
    const u = usage.value;
    const num = (n) => {
      const x = get(u, n);
      return x && x.wire === 0 ? Number(x.value) : 0;
    };
    const sub8 = get(u, 8);
    const names = sub8?.nested ? sub8.value.map((x) => ident(x.raw)) : [];
    const f11 = ident(get(u, 11)?.raw);
    const modelEnum = num(1);
    const ts = (() => {
      const m9 = get(m1.value, 9);
      const t = m9?.nested ? get(m9.value, 4) : null;
      if (!t?.nested) return null;
      const sec = get(t.value, 1);
      return sec ? new Date(Number(sec.value) * 1000).toISOString() : null;
    })();

    const key = `${modelEnum}|${names.join(",")}|${f11}`;
    modelIds.set(key, (modelIds.get(key) ?? 0) + 1);

    if (printed++ < 3) {
      console.log(
        `  idx=${row.idx} modelEnum=${modelEnum} f6=${num(6)} names=[${names.join(", ")}] f11=${f11}\n` +
          `      in=${num(2)} out=${num(3)} cacheRead=${num(5)} reasoning=${num(9)} text=${num(10)} ts=${ts}`,
      );
    }
    // Other identifier-ish top-level strings around the usage message.
    if (printed === 1) {
      for (const n of [7, 19, 21]) {
        const x = get(m1.value, n);
        if (!x) continue;
        console.log(`      m1.${n} = ${x.nested ? x.value.map((y) => ident(y.raw)).join(" | ") : ident(x.raw)}`);
      }
      console.log(`      top.4 = ${ident(get(top, 4)?.raw)}`);
    }
  }
  db.close();
}

console.log("\n######## distinct model signatures (enum | names | f11) ########");
for (const [k, v] of [...modelIds.entries()].sort((a, b) => b[1] - a[1])) console.log(`  ${v.toString().padStart(4)}x  ${k}`);
