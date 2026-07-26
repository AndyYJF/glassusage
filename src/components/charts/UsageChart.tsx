/**
 * Stacked area of token volume over time, one band per group key.
 *
 * The backend returns long-form rows (`bucket`, `key`, totals); Recharts needs wide-form,
 * so the pivot happens here. Buckets with no data for a key are filled with 0 rather than
 * left undefined, otherwise the stack would collapse and the band would jump.
 */
import { useMemo } from "react";
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import type { SeriesPoint } from "../../lib/types";
import { resolveSourceColor, sourceLabel } from "../../lib/sources";
import { date, dateTime, time, tokens, usd } from "../../lib/format";

type Metric = "tokens" | "cost";

interface Props {
  data: SeriesPoint[];
  bucket: "hour" | "day" | "week";
  metric?: Metric;
  /** Colour keys as sources; anything else falls back to a generated palette. */
  colorBy?: "source" | "palette";
  height?: number;
}

const PALETTE = ["--accent", "--accent-2", "--info", "--success", "--warning", "--danger"];

function paletteColor(index: number, alpha = 1) {
  const v = PALETTE[index % PALETTE.length];
  const triple = getComputedStyle(document.documentElement).getPropertyValue(v).trim();
  const [r, g, b] = (triple || "10 132 255").split(/\s+/);
  return alpha === 1 ? `rgb(${r} ${g} ${b})` : `rgb(${r} ${g} ${b} / ${alpha})`;
}

function GlassTooltip({
  active,
  payload,
  label,
  bucket,
  metric,
}: {
  active?: boolean;
  payload?: { name: string; value: number; color: string }[];
  label?: number;
  bucket: Props["bucket"];
  metric: Metric;
}) {
  if (!active || !payload?.length) return null;

  const rows = payload.filter((p) => p.value > 0).sort((a, b) => b.value - a.value);
  if (!rows.length) return null;
  const total = rows.reduce((sum, p) => sum + p.value, 0);
  const fmt = metric === "cost" ? usd : tokens;

  return (
    <div className="glass-quiet min-w-[168px] px-3 py-2 text-[0.75rem] shadow-[var(--shadow-drop-sm)]">
      <div className="mb-1.5 font-semibold">
        {bucket === "hour" ? time(label ?? 0) : date(label ?? 0)}
      </div>
      {rows.map((p) => (
        <div key={p.name} className="flex items-center gap-2 py-[1px]">
          <span className="h-2 w-2 rounded-full" style={{ background: p.color }} />
          <span className="text-[rgb(var(--text-dim))]">{sourceLabel(p.name)}</span>
          <span className="tnum ml-auto font-medium">{fmt(p.value)}</span>
        </div>
      ))}
      <div className="mt-1.5 flex items-center gap-2 border-t border-white/10 pt-1.5 font-semibold">
        <span>Total</span>
        <span className="tnum ml-auto">{fmt(total)}</span>
      </div>
    </div>
  );
}

export function UsageChart({
  data,
  bucket,
  metric = "tokens",
  colorBy = "source",
  height = 260,
}: Props) {
  const { rows, keys } = useMemo(() => {
    const byBucket = new Map<number, Record<string, number>>();
    const keySet = new Set<string>();

    for (const p of data) {
      keySet.add(p.key);
      let row = byBucket.get(p.bucket);
      if (!row) {
        row = { bucket: p.bucket };
        byBucket.set(p.bucket, row);
      }
      row[p.key] = (row[p.key] ?? 0) + (metric === "cost" ? p.costUsd : p.totalTokens);
    }

    const keys = [...keySet].sort();
    const rows = [...byBucket.values()].sort((a, b) => a.bucket - b.bucket);
    for (const row of rows) {
      for (const k of keys) if (row[k] === undefined) row[k] = 0;
    }
    return { rows, keys };
  }, [data, metric]);

  const colorOf = (key: string, i: number, alpha = 1) =>
    colorBy === "source" ? resolveSourceColor(key, alpha) : paletteColor(i, alpha);

  if (!rows.length) {
    return (
      <div
        className="grid place-items-center text-[0.8125rem] text-[rgb(var(--text-faint))]"
        style={{ height }}
      >
        No usage recorded in this range
      </div>
    );
  }

  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={rows} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
        <defs>
          {keys.map((k, i) => (
            <linearGradient key={k} id={`fill-${k}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={colorOf(k, i)} stopOpacity={0.55} />
              <stop offset="100%" stopColor={colorOf(k, i)} stopOpacity={0.04} />
            </linearGradient>
          ))}
        </defs>

        <CartesianGrid stroke="rgb(255 255 255 / 0.06)" vertical={false} />
        <XAxis
          dataKey="bucket"
          type="number"
          scale="time"
          domain={["dataMin", "dataMax"]}
          tickFormatter={(v) => (bucket === "hour" ? time(v) : date(v))}
          tick={{ fontSize: 11, fill: "rgb(255 255 255 / 0.45)" }}
          axisLine={false}
          tickLine={false}
          // Wide enough gaps that localized date labels never collide with each other or
          // with the value axis.
          minTickGap={44}
          padding={{ left: 6, right: 6 }}
        />
        <YAxis
          tickFormatter={(v) => (metric === "cost" ? usd(v) : tokens(v))}
          tick={{ fontSize: 11, fill: "rgb(255 255 255 / 0.45)" }}
          axisLine={false}
          tickLine={false}
          width={56}
        />
        <Tooltip
          content={<GlassTooltip bucket={bucket} metric={metric} />}
          cursor={{ stroke: "rgb(255 255 255 / 0.22)", strokeWidth: 1 }}
          labelFormatter={(v) => dateTime(Number(v))}
        />
        {keys.map((k, i) => (
          <Area
            key={k}
            type="monotone"
            dataKey={k}
            stackId="1"
            stroke={colorOf(k, i)}
            strokeWidth={1.5}
            fill={`url(#fill-${k})`}
            isAnimationActive={false}
          />
        ))}
      </AreaChart>
    </ResponsiveContainer>
  );
}
