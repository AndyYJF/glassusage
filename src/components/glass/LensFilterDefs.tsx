/**
 * The SVG filters that give the glass its refraction.
 *
 * `feDisplacementMap` shifts every backdrop pixel by the R and G channels of a lookup
 * image, so a map whose edges encode the surface normal makes the backdrop bend exactly
 * where the glass curves. Running that displacement three times at slightly different
 * strengths and recombining one colour channel from each produces chromatic aberration.
 *
 * Injected once at the app root; components reference the filters by id. The filter
 * elements themselves must never remount — WebView2's `backdrop-filter: url(#id)` goes
 * permanently blank if the referenced filter disappears for even one frame (which is
 * exactly what happened when the Settings slider re-rendered this tree).
 */

import { useEffect, useRef } from "react";

interface LensDef {
  id: string;
  map: string;
  /** Base displacement in px, scaled by the user's refraction setting. */
  scale: number;
  /** Per-channel spread that creates the colour fringe. */
  dispersion: number;
}

const LENSES: LensDef[] = [
  { id: "lens-card", map: "/lens/card.png", scale: 44, dispersion: 8 },
  { id: "lens-button", map: "/lens/button.png", scale: 26, dispersion: 4 },
  { id: "lens-pill", map: "/lens/pill.png", scale: 22, dispersion: 4 },
  { id: "lens-pill-strong", map: "/lens/pill-strong.png", scale: 34, dispersion: 6 },
];

/** Keep only one colour channel, preserving alpha, so the three passes can be recombined. */
const CHANNEL_MATRIX = {
  r: "1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0",
  g: "0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0",
  b: "0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0",
} as const;

export function LensFilterDefs({ strength = 1 }: { strength?: number }) {
  const svgRef = useRef<SVGSVGElement>(null);
  const s = Math.max(0, Math.min(1.4, strength));

  // Mutate scale attributes in place. Remounting <filter id="lens-card"> while any
  // element still references it via backdrop-filter leaves those elements blank until
  // the whole WebView is reloaded — which is how "switch material → blank pages" looked.
  useEffect(() => {
    const root = svgRef.current;
    if (!root) return;
    for (const lens of LENSES) {
      const base = -lens.scale * s;
      const spread = lens.dispersion * s;
      const scales = { r: base - spread, g: base, b: base + spread };
      for (const [ch, scale] of Object.entries(scales)) {
        const el = root.querySelector(`#${lens.id}-d${ch.toUpperCase()}`);
        if (el) el.setAttribute("scale", String(scale));
      }
    }
  }, [s]);

  return (
    <svg
      ref={svgRef}
      width="0"
      height="0"
      aria-hidden="true"
      focusable="false"
      style={{ position: "absolute", pointerEvents: "none" }}
    >
      <defs>
        {LENSES.map((lens) => {
          const base = -lens.scale * s;
          const spread = lens.dispersion * s;
          const passes = [
            { key: "r", scale: base - spread },
            { key: "g", scale: base },
            { key: "b", scale: base + spread },
          ] as const;

          return (
            <filter
              key={lens.id}
              id={lens.id}
              x="0"
              y="0"
              width="100%"
              height="100%"
              filterUnits="objectBoundingBox"
              primitiveUnits="userSpaceOnUse"
              colorInterpolationFilters="sRGB"
            >
              <feImage
                href={lens.map}
                result="map"
                x="0"
                y="0"
                width="100%"
                height="100%"
                preserveAspectRatio="none"
              />
              {passes.map((p) => (
                <feDisplacementMap
                  key={p.key}
                  id={`${lens.id}-d${p.key.toUpperCase()}`}
                  in="SourceGraphic"
                  in2="map"
                  scale={p.scale}
                  xChannelSelector="R"
                  yChannelSelector="G"
                  result={`d${p.key.toUpperCase()}`}
                />
              ))}
              {passes.map((p) => (
                <feColorMatrix
                  key={`m${p.key}`}
                  in={`d${p.key.toUpperCase()}`}
                  type="matrix"
                  values={CHANNEL_MATRIX[p.key]}
                  result={`c${p.key.toUpperCase()}`}
                />
              ))}
              <feBlend in="cR" in2="cG" mode="screen" result="cRG" />
              <feBlend in="cRG" in2="cB" mode="screen" />
            </filter>
          );
        })}
      </defs>
    </svg>
  );
}
