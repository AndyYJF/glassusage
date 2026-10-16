#!/usr/bin/env node
/**
 * Antigravity IDE stores trajectory steps as protobuf blobs. There is no public .proto,
 * so this walks the raw wire format and prints the *field-number tree* with value types
 * (strings reduced to length only) to find where per-generation token counts live.
 */
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const WIRE = { 0: "varint", 1: "i64", 2: "len", 5: "i32" };

function readVarint(buf, pos) {
  let result = 0n;
  let shift = 0n;
  while (pos < buf.length) {
    const b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) return [result, pos];
    shift += 7n;
    if (shift > 70n) return null;
  }
  return null;
}

function looksUtf8(buf) {
  if (buf.length === 0) return true;
  let printable = 0;
  for (const b of buf) if (b === 9 || b === 10 || b === 13 || (b >= 32 && b < 127)) printable++;
  return printable / buf.length > 0.9;
}

/** Decode a protobuf message; returns null when the bytes are not a valid message. */
function decode(buf, depth = 0) {
  const fields = [];
  let pos = 0;
  while (pos < buf.length) {
    const kv = readVarint(buf, pos);
    if (!kv) return null;
    let [key, p] = kv;
    pos = p;
    const fieldNo = Number(key >> 3n);
    const wire = Number(key & 7n);
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
      fields.push({ fieldNo, wire, value: nested ?? (looksUtf8(sub) ? `str(${len})` : `bytes(${len})`), nested: !!nested });
    } else {
      return null;
    }
  }
  return fields;
}

function render(fields, indent = "  ") {
  const out = [];
  for (const f of fields) {
    if (Array.isArray(f.value)) {
      out.push(`${indent}${f.fieldNo} (msg):`);
      out.push(render(f.value, indent + "  "));
    } else {
      out.push(`${indent}${f.fieldNo} (${WIRE[f.wire]}): ${f.value}`);
    }
  }
  return out.join("\n");
}

/** Token counts are plausible mid-range integers; flag messages holding several of them. */
function findTokenLikeGroups(fields, pathStr = "", found = []) {
  const varints = fields.filter((f) => f.wire === 0).map((f) => ({ n: f.fieldNo, v: Number(f.value) }));
  const plausible = varints.filter((x) => x.v >= 10 && x.v <= 5_000_000);
  if (plausible.length >= 2) found.push({ path: pathStr || "(root)", fields: plausible });
  for (const f of fields) {
    if (Array.isArray(f.value)) findTokenLikeGroups(f.value, `${pathStr}.${f.fieldNo}`, found);
  }
  return found;
}

const convDir = path.join(os.homedir(), ".gemini", "antigravity", "conversations");
const dbFile = fs
  .readdirSync(convDir)
  .filter((f) => f.endsWith(".db"))
  .map((f) => ({ f, size: fs.statSync(path.join(convDir, f)).size }))
  .sort((a, b) => b.size - a.size)[0].f;

console.log(`db: ${dbFile}`);
const db = new DatabaseSync(path.join(convDir, dbFile), { readOnly: true });

console.log("\n######## gen_metadata (first 3 rows, full tree) ########");
for (const row of db.prepare("SELECT idx, data, size FROM gen_metadata ORDER BY idx LIMIT 3").all()) {
  console.log(`\n--- idx=${row.idx} size=${row.size} bytes=${row.data?.length} ---`);
  const f = decode(Buffer.from(row.data));
  console.log(f ? render(f) : "  (not decodable as protobuf)");
}

console.log("\n######## token-like varint groups across all gen_metadata ########");
const tally = new Map();
for (const row of db.prepare("SELECT idx, data FROM gen_metadata").all()) {
  const f = decode(Buffer.from(row.data));
  if (!f) continue;
  for (const g of findTokenLikeGroups(f)) {
    const sig = `${g.path} :: fields[${g.fields.map((x) => x.n).join(",")}]`;
    if (!tally.has(sig)) tally.set(sig, { count: 0, samples: [] });
    const t = tally.get(sig);
    t.count++;
    if (t.samples.length < 4) t.samples.push(g.fields.map((x) => `${x.n}=${x.v}`).join(" "));
  }
}
for (const [sig, t] of [...tally.entries()].sort((a, b) => b[1].count - a[1].count).slice(0, 15)) {
  console.log(`\n  ${sig}  (seen ${t.count}x)`);
  for (const s of t.samples) console.log(`      ${s}`);
}

db.close();
