#!/usr/bin/env node
/**
 * Draw the source app icon: a liquid-glass rounded square with a specular sweep and a
 * token bar-chart glyph. Written with raw pixels so the build needs no image toolchain.
 *
 *   node scripts/generate-icon.mjs && npx tauri icon src-tauri/icons/source.png
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";

const SIZE = 1024;
const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "src-tauri", "icons", "source.png");

/** Signed distance to a rounded rectangle; negative inside. */
function sdRoundRect(px, py, cx, cy, halfW, halfH, r) {
  const qx = Math.abs(px - cx) - (halfW - r);
  const qy = Math.abs(py - cy) - (halfH - r);
  const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
  return outside + Math.min(Math.max(qx, qy), 0) - r;
}

const lerp = (a, b, t) => a + (b - a) * t;
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const smoothstep = (e0, e1, x) => {
  const t = clamp01((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
};

const png = new PNG({ width: SIZE, height: SIZE });

const margin = SIZE * 0.08;
const half = (SIZE - margin * 2) / 2;
const radius = SIZE * 0.235;
const cx = SIZE / 2;
const cy = SIZE / 2;

// Bars of the glyph, as fractions of the icon box: [x, width, height].
const bars = [
  [0.3, 0.075, 0.2],
  [0.41, 0.075, 0.34],
  [0.52, 0.075, 0.26],
  [0.63, 0.075, 0.44],
];
const barBottom = 0.71;

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const idx = (SIZE * y + x) << 2;
    const d = sdRoundRect(x + 0.5, y + 0.5, cx, cy, half, half, radius);
    const inside = 1 - smoothstep(-1.5, 1.5, d);
    if (inside <= 0.001) {
      png.data[idx + 3] = 0;
      continue;
    }

    const u = x / SIZE;
    const v = y / SIZE;

    // Diagonal blue-violet gradient body.
    const t = clamp01((u + v) / 2);
    let r = lerp(38, 122, t);
    let g = lerp(96, 78, t);
    let b = lerp(220, 214, t);

    // Warm bloom in the lower right, as if light passed through the glass.
    const bloom = smoothstep(0.9, 0.15, Math.hypot(u - 0.78, v - 0.8));
    r = lerp(r, 236, bloom * 0.32);
    g = lerp(g, 132, bloom * 0.32);
    b = lerp(b, 208, bloom * 0.32);

    // Specular sweep across the upper left.
    const sweep = smoothstep(0.42, 0.0, Math.abs(u * 0.75 + v * 0.62 - 0.42));
    const shine = sweep * 0.5;
    r = lerp(r, 255, shine);
    g = lerp(g, 255, shine);
    b = lerp(b, 255, shine);

    // Bright inner rim gives the edge its glass thickness.
    const rim = smoothstep(-14, -1, d) * (1 - smoothstep(-1.5, 0.5, d));
    r = lerp(r, 255, rim * 0.75);
    g = lerp(g, 255, rim * 0.75);
    b = lerp(b, 255, rim * 0.75);

    // Chart glyph, punched in as bright translucent bars.
    for (const [bx, bw, bh] of bars) {
      const left = bx * SIZE;
      const right = (bx + bw) * SIZE;
      const bottom = barBottom * SIZE;
      const top = (barBottom - bh) * SIZE;
      const barR = (bw * SIZE) / 2;
      const inBar =
        1 -
        smoothstep(
          -1.5,
          1.5,
          sdRoundRect(x + 0.5, y + 0.5, (left + right) / 2, (top + bottom) / 2, (right - left) / 2, (bottom - top) / 2, barR),
        );
      if (inBar > 0) {
        const a = inBar * 0.92;
        r = lerp(r, 255, a);
        g = lerp(g, 255, a);
        b = lerp(b, 255, a);
      }
    }

    png.data[idx] = Math.round(clamp01(r / 255) * 255);
    png.data[idx + 1] = Math.round(clamp01(g / 255) * 255);
    png.data[idx + 2] = Math.round(clamp01(b / 255) * 255);
    png.data[idx + 3] = Math.round(inside * 255);
  }
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
png.pack().pipe(fs.createWriteStream(OUT)).on("finish", () => console.log(`wrote ${OUT}`));
