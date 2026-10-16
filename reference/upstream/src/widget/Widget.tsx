/**
 * Always-on-top mini card.
 *
 * This window runs whenever the app does, so it deliberately costs less than the main UI:
 * no displacement lens, no chart library, one query on a one-second interval. Metrics
 * ease into each sample and roll on an Odometer; the sparkline tracks TPM history.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { listen } from "@tauri-apps/api/event";
import { Maximize2, Pin, X } from "lucide-react";

import { Odometer } from "../components/glass/Odometer";
import { api } from "../lib/api";
import { useLiveRates, useSettings } from "../lib/hooks";
import { useT } from "../lib/i18n";
import { rate, tokens, usd } from "../lib/format";
import { SOURCE_META } from "../lib/sources";
import type { SourceId } from "../lib/types";

/**
 * Ease toward each new live sample so Odometer digits roll on the way,
 * instead of snapping once per poll.
 */
function useJumpValue(target: number, durationMs = 380): number {
  const [value, setValue] = useState(target);
  const display = useRef(target);
  const primed = useRef(false);
  const raf = useRef<number | null>(null);

  useEffect(() => {
    if (!Number.isFinite(target)) return;

    if (!primed.current) {
      primed.current = true;
      display.current = target;
      setValue(target);
      return;
    }

    if (Math.abs(target - display.current) < 1e-6) return;

    const from = display.current;
    const to = target;
    const start = performance.now();

    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / durationMs);
      const eased = 1 - (1 - t) ** 3;
      const next = from + (to - from) * eased;
      display.current = next;
      setValue(next);
      if (t < 1) {
        raf.current = requestAnimationFrame(tick);
      } else {
        display.current = to;
        setValue(to);
        raf.current = null;
      }
    };

    if (raf.current != null) cancelAnimationFrame(raf.current);
    raf.current = requestAnimationFrame(tick);
    return () => {
      if (raf.current != null) cancelAnimationFrame(raf.current);
    };
  }, [target, durationMs]);

  return value;
}

const SPARK_W = 100;
const SPARK_H = 26;
/** ~48 samples × 250ms ≈ 12s of TPM history */
const TPM_HISTORY = 48;
const TPM_SAMPLE_MS = 250;

/** Catmull-Rom → cubic Bezier through a series of points. */
function curvePath(points: ReadonlyArray<readonly [number, number]>): string {
  if (points.length < 2) return "";
  if (points.length === 2) {
    return `M${points[0]![0].toFixed(2)},${points[0]![1].toFixed(2)} L${points[1]![0].toFixed(2)},${points[1]![1].toFixed(2)}`;
  }
  let d = `M${points[0]![0].toFixed(2)},${points[0]![1].toFixed(2)}`;
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[Math.max(0, i - 1)]!;
    const p1 = points[i]!;
    const p2 = points[i + 1]!;
    const p3 = points[Math.min(points.length - 1, i + 2)]!;
    const cp1x = p1[0] + (p2[0] - p0[0]) / 6;
    const cp1y = p1[1] + (p2[1] - p0[1]) / 6;
    const cp2x = p2[0] - (p3[0] - p1[0]) / 6;
    const cp2y = p2[1] - (p3[1] - p1[1]) / 6;
    d += ` C${cp1x.toFixed(2)},${cp1y.toFixed(2)} ${cp2x.toFixed(2)},${cp2y.toFixed(2)} ${p2[0].toFixed(2)},${p2[1].toFixed(2)}`;
  }
  return d;
}

/**
 * Absolute 0→ceiling so a high steady TPM sits near the top (reads as active),
 * and rise/decay of the big number shows as a clear wave.
 */
function toPoints(values: number[]): Array<[number, number]> {
  const max = Math.max(0, ...values);
  const ceiling = Math.max(max * 1.08, 1);
  const step = SPARK_W / Math.max(1, values.length - 1);
  const padTop = 2;
  const padBot = 2;
  const usable = SPARK_H - padTop - padBot;
  return values.map((v, i) => {
    const n = Math.max(0, Math.min(1, v / ceiling));
    return [i * step, SPARK_H - padBot - n * usable] as [number, number];
  });
}

function Sparkline({ values }: { values: number[] }) {
  const gradId = useRef(`spark-${Math.random().toString(36).slice(2, 9)}`);

  const { stroke, fill, idle } = useMemo(() => {
    if (values.length < 2) return { stroke: "", fill: "", idle: true };
    const peak = Math.max(0, ...values);
    const pts = toPoints(values);
    const line = curvePath(pts);
    const fillPath = `${line} L${SPARK_W},${SPARK_H} L0,${SPARK_H} Z`;
    return { stroke: line, fill: fillPath, idle: peak <= 0.5 };
  }, [values]);

  if (!stroke) return <div className="h-[26px]" />;

  const fillId = `${gradId.current}-fill`;
  const strokeColor = idle ? "rgb(255 255 255 / 0.22)" : "#0a84ff";

  return (
    <svg
      viewBox={`0 0 ${SPARK_W} ${SPARK_H}`}
      preserveAspectRatio="none"
      className="h-[26px] w-full"
    >
      <defs>
        <linearGradient id={fillId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#0a84ff" stopOpacity={idle ? 0.08 : 0.38} />
          <stop offset="100%" stopColor="#0a84ff" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={fill} fill={`url(#${fillId})`} stroke="none" />
      <path
        d={stroke}
        fill="none"
        stroke={strokeColor}
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

/**
 * Sample TPM every 250ms, chasing the latest live value.
 * Plots the same quantity as the big number — not the sparse per-second spark60
 * buckets that go to zero while TPM stays high after a burst.
 */
function useTpmHistory(tpm: number | undefined): number[] {
  const target = useRef(0);
  const seeded = useRef(false);
  const [series, setSeries] = useState<number[]>(() => Array(TPM_HISTORY).fill(0));

  useEffect(() => {
    if (tpm == null || !Number.isFinite(tpm)) return;
    target.current = Math.max(0, tpm);
    if (!seeded.current) {
      seeded.current = true;
      setSeries(Array(TPM_HISTORY).fill(target.current));
    }
  }, [tpm]);

  useEffect(() => {
    const id = window.setInterval(() => {
      setSeries((prev) => {
        const last = prev[prev.length - 1] ?? 0;
        const nextVal = last + (target.current - last) * 0.45;
        const next = prev.slice(1);
        next.push(nextVal < 0.05 ? 0 : nextVal);
        return next;
      });
    }, TPM_SAMPLE_MS);
    return () => window.clearInterval(id);
  }, []);

  return series;
}

export function Widget() {
  const { t } = useT();
  const qc = useQueryClient();
  const { data: live } = useLiveRates(1000);
  const { data: settings } = useSettings();
  const [pinned, setPinned] = useState(true);
  const compact = Boolean(settings?.widgetCompact);
  const tpmSeries = useTpmHistory(live?.tpm);

  const jumpTpm = useJumpValue(live?.tpm ?? 0);
  const jumpRpm = useJumpValue(live?.rpm ?? 0);
  const jumpTokensToday = useJumpValue(live?.tokensToday ?? 0, 520);
  const costTarget = Boolean(settings?.budgetAlertsEnabled && (settings?.dailyCostBudget ?? 0) > 0)
    ? (live?.budgetCostToday ?? live?.costToday ?? 0)
    : (live?.costToday ?? 0);
  const jumpCost = useJumpValue(costTarget, 520);

  useEffect(() => {
    const p = listen("settings-changed", () => {
      qc.invalidateQueries({ queryKey: ["settings"] });
    });
    return () => {
      p.then((fn) => fn()).catch(() => {});
    };
  }, [qc]);

  useEffect(() => {
    if (settings) setPinned(settings.widgetAlwaysOnTop);
  }, [settings?.widgetAlwaysOnTop]);

  useEffect(() => {
    document.documentElement.classList.add("dark");
    document.body.classList.add("widget-body");
  }, []);

  useEffect(() => {
    const onUp = () => void api.snapWidget();
    window.addEventListener("pointerup", onUp);
    return () => window.removeEventListener("pointerup", onUp);
  }, []);

  const active = (live?.perSource ?? []).filter((s) => s.active);

  const costLimit = settings?.dailyCostBudget ?? 0;
  const budgetOn = Boolean(settings?.budgetAlertsEnabled && costLimit > 0);
  const budgetCost = live?.budgetCostToday ?? live?.costToday ?? 0;
  const costPct = budgetOn ? Math.min(1, budgetCost / costLimit) : 0;
  const overBudget = budgetOn && costPct >= 1;

  const controls = (
    <div className="no-drag ml-auto flex items-center gap-0.5">
      <button
        type="button"
        aria-label={t("settings.widgetTop")}
        title={pinned ? t("widget.unpin") : t("widget.pin")}
        onClick={() => {
          setPinned(!pinned);
          api.setWidgetAlwaysOnTop(!pinned);
        }}
        className="grid h-6 w-6 place-items-center rounded-md transition-colors hover:bg-white/12"
        style={{ color: pinned ? "rgb(var(--accent))" : "rgb(var(--text-faint))" }}
      >
        <Pin size={12} />
      </button>
      <button
        type="button"
        aria-label={t("widget.open")}
        title={t("widget.open")}
        onClick={() => api.showMainWindow("dashboard")}
        className="grid h-6 w-6 place-items-center rounded-md text-[rgb(var(--text-dim))] transition-colors hover:bg-white/12"
      >
        <Maximize2 size={12} />
      </button>
      <button
        type="button"
        aria-label={t("widget.hide")}
        onClick={() => api.toggleWidgetMode(false)}
        className="grid h-6 w-6 place-items-center rounded-md text-[rgb(var(--text-dim))] transition-colors hover:bg-[rgb(var(--danger)/0.8)] hover:text-white"
      >
        <X size={12} />
      </button>
    </div>
  );

  if (compact) {
    return (
      <div className="glass-lens drag-region flex h-full w-full flex-col justify-center gap-1.5 p-2.5">
        <div className="flex items-center gap-1.5">
          <span className={`status-dot ${(live?.tpm ?? 0) > 0 ? "status-live" : "status-missing"}`} />
          <span className="text-[0.625rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
            {t("widget.today")}
          </span>
          {controls}
        </div>
        <div className="flex items-start gap-4">
          <div>
            <div className="text-[1.25rem] font-semibold leading-none">
              <Odometer value={tokens(jumpTokensToday)} />
            </div>
            <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
              {t("widget.tokensToday")}
            </div>
          </div>
          <div>
            <div
              className="text-[1.25rem] font-semibold leading-none"
              style={overBudget ? { color: "rgb(var(--danger))" } : undefined}
            >
              <Odometer value={usd(jumpCost)} />
            </div>
            <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
              {t("widget.costToday")}
            </div>
          </div>
        </div>
        {budgetOn && (
          <div
            className="h-1 w-full overflow-hidden rounded-full bg-white/10"
            title={`${usd(budgetCost)} / ${usd(costLimit)}`}
          >
            <div
              className="h-full rounded-full transition-[width] duration-500"
              style={{
                width: `${costPct * 100}%`,
                background: overBudget ? "rgb(var(--danger))" : "rgb(var(--accent))",
              }}
            />
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="glass-lens drag-region flex h-full w-full flex-col gap-1.5 p-3">
      <div className="flex items-center gap-1.5">
        <span className={`status-dot ${(live?.tpm ?? 0) > 0 ? "status-live" : "status-missing"}`} />
        <span className="text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
          {t("widget.live")}
        </span>
        {controls}
      </div>

      <div className="flex items-start gap-3">
        <div>
          <div className="text-[1.35rem] font-semibold leading-none">
            <Odometer value={rate(jumpTpm)} />
          </div>
          <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
            {t("widget.tokensMin")}
          </div>
        </div>
        <div>
          <div className="text-[1.35rem] font-semibold leading-none">
            <Odometer value={rate(jumpRpm)} />
          </div>
          <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
            {t("widget.reqMin")}
          </div>
        </div>
        <div className="ml-auto flex items-start gap-3 text-right">
          <div>
            <div className="text-[1.05rem] font-semibold leading-none">
              <Odometer value={tokens(jumpTokensToday)} />
            </div>
            <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
              {t("widget.tokensToday")}
            </div>
          </div>
          <div>
            <div
              className="text-[1.05rem] font-semibold leading-none"
              style={overBudget ? { color: "rgb(var(--danger))" } : undefined}
            >
              <Odometer value={usd(jumpCost)} />
            </div>
            <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
              {t("widget.costToday")}
            </div>
          </div>
        </div>
      </div>

      {budgetOn && (
        <div
          className="h-1 w-full overflow-hidden rounded-full bg-white/10"
          title={`${usd(budgetCost)} / ${usd(costLimit)}`}
        >
          <div
            className="h-full rounded-full transition-[width] duration-500"
            style={{
              width: `${costPct * 100}%`,
              background: overBudget ? "rgb(var(--danger))" : "rgb(var(--accent))",
            }}
          />
        </div>
      )}

      <Sparkline values={tpmSeries} />

      <div className="flex flex-wrap items-center gap-1.5">
        {active.length === 0 && (
          <span className="text-[0.625rem] text-[rgb(var(--text-faint))]">{t("widget.idle")}</span>
        )}
        {active.map((s) => (
          <span
            key={s.source}
            className="chip gap-1 py-[1px] text-[0.5625rem]"
            title={`${rate(s.tpm)} tok/min`}
          >
            <span
              className="h-1.5 w-1.5 rounded-full"
              style={{
                background: `rgb(var(${SOURCE_META[s.source as SourceId]?.colorVar ?? "--accent"}))`,
                animation: s.polling ? "breathe 2.4s ease-in-out infinite" : undefined,
              }}
            />
            {SOURCE_META[s.source as SourceId]?.label ?? s.source}
          </span>
        ))}
      </div>
    </div>
  );
}
