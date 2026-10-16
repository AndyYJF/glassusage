#!/usr/bin/env node
/**
 * Generate the displacement maps that give the glass its edge refraction.
 *
 * `feDisplacementMap` shifts each pixel by the R and G channels of a lookup image:
 * a value of 128 means no shift, and the distance from 128 sets direction and amount.
 * So the map encodes, per pixel, "which direction is the glass surface bending light".
 *
 * The recipe is a signed distance field for a rounded rectangle, differentiated to get
 * the surface normal, then that normal encoded into R (x) and G (y). Displacement is
 * concentrated in a band just inside the edge, which is where a real lens bends light
 * most, and falls to zero in the flat middle.
 *
 * Blue carries a slightly different falloff so the three channels separate a little at
 * the rim — the faint colour fringing that reads as chromatic aberration.
 *
 *   node scripts/generate-lens-maps.mjs
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";

const OUT_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public", "lens");

/**
 * @param {object} opts
 * @param {number} opts.width      map width in px
 * @param {number} opts.height     map height in px
 * @param {number} opts.radius     corner radius in px (use height/2 for a pill)
 * @param {number} opts.bandRatio  refracting band thickness, as a fraction of the shorter side
 * @param {number} opts.strength   0..1 peak displacement
 */
function buildMap({ width, height, radius, bandRatio = 0.22, strength = 1 }) {
  const png = new PNG({ width, height });
  const band = Math.max(4, Math.min(width, height) * bandRatio);

  const sd = (px, py) => {
    const qx = Math.abs(px - width / 2) - (width / 2 - radius);
    const qy = Math.abs(py - height / 2) - (height / 2 - radius);
    const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
    return outside + Math.min(Math.max(qx, qy), 0) - radius;
  };

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const idx = (width * y + x) << 2;
      const px = x + 0.5;
      const py = y + 0.5;
      const d = sd(px, py);

      // Outside the shape there is no glass, so no displacement.
      if (d > 0) {
        png.data[idx] = 128;
        png.data[idx + 1] = 128;
        png.data[idx + 2] = 128;
        png.data[idx + 3] = 255;
        continue;
      }

      // Numerical gradient of the distance field is the inward surface normal.
      const e = 1;
      const nx = (sd(px + e, py) - sd(px - e, py)) / (2 * e);
      const ny = (sd(px, py + e) - sd(px, py - e)) / (2 * e);
      const len = Math.hypot(nx, ny) || 1;

      // Depth into the glass, 1 at the very edge falling to 0 at the band's inner limit.
      const t = Math.max(0, 1 + d / band);
      // Cubic falloff keeps the centre perfectly flat while the rim bends hard.
      const falloff = t * t * t;

      const ampR = (nx / len) * falloff * strength;
      const ampG = (ny / len) * falloff * strength;
      // Blue lags slightly, producing the coloured rim fringe.
      const ampB = (nx / len) * falloff * falloff * strength;

      png.data[idx] = clampByte(128 + ampR * 127);
      png.data[idx + 1] = clampByte(128 + ampG * 127);
      png.data[idx + 2] = clampByte(128 + ampB * 127);
      png.data[idx + 3] = 255;
    }
  }
  return png;
}

const clampByte = (v) => Math.max(0, Math.min(255, Math.round(v)));

const MAPS = [
  // Primary surfaces: cards, sidebar, popovers.
  { name: "card", width: 512, height: 512, radius: 96, bandRatio: 0.16, strength: 1 },
  // Buttons and small controls.
  { name: "button", width: 256, height: 128, radius: 28, bandRatio: 0.3, strength: 1 },
  // Pills: slider thumbs, segmented selection, switches. `preserveAspectRatio="none"`
  // stretches this one with the element, which is what makes the thumb go elliptical
  // when it is dragged.
  { name: "pill", width: 256, height: 256, radius: 128, bandRatio: 0.42, strength: 1 },
  // Stronger variant swapped in on hover and while dragging.
  { name: "pill-strong", width: 256, height: 256, radius: 128, bandRatio: 0.5, strength: 1.35 },
];

fs.mkdirSync(OUT_DIR, { recursive: true });
for (const spec of MAPS) {
  const png = buildMap(spec);
  const file = path.join(OUT_DIR, `${spec.name}.png`);
  png.pack().pipe(fs.createWriteStream(file)).on("finish", () => console.log(`wrote ${file}`));
}
