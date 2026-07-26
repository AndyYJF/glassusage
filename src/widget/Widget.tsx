/**
 * Always-on-top mini card.
 *
 * This window runs whenever the app does, so it deliberately costs less than the main UI:
 * no displacement lens, no chart library, one query on a one-second interval. The
 * sparkline is a hand-built SVG path over the 60 one-second buckets the backend keeps.
 */
import { useEffect, useMemo, useState } from "react";
import { Maximize2, Pin, X } from "lucide-react";

import { api } from "../lib/api";
import { useLiveRates, useSettings } from "../lib/hooks";
import { useT } from "../lib/i18n";
import { rate, tokens, usd } from "../lib/format";
import { SOURCE_META } from "../lib/sources";
import type { SourceId } from "../lib/types";

function Sparkline({ values }: { values: number[] }) {
  const path = useMemo(() => {
    if (values.length < 2) return "";
    const max = Math.max(1, ...values);
    const w = 100;
    const h = 26;
    const step = w / (values.length - 1);
    // A flat baseline at zero looks broken next to a spiky series, so keep 1px of floor.
    const points = values.map((v, i) => [i * step, h - (v / max) * (h - 2) - 1] as const);
    const line = points.map(([x, y], i) => `${i === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`);
    return `${line.join(" ")} L${w},${h} L0,${h} Z`;
  }, [values]);

  if (!path) return <div className="h-[26px]" />;

  return (
    <svg viewBox="0 0 100 26" preserveAspectRatio="none" className="h-[26px] w-full">
      <defs>
        <linearGradient id="spark" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="rgb(var(--accent))" stopOpacity="0.5" />
          <stop offset="100%" stopColor="rgb(var(--accent))" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={path} fill="url(#spark)" stroke="rgb(var(--accent))" strokeWidth="1" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

export function Widget() {
  const { t } = useT();
  const { data: live } = useLiveRates(1000);
  const { data: settings } = useSettings();
  const [pinned, setPinned] = useState(true);

  useEffect(() => {
    if (settings) setPinned(settings.widgetAlwaysOnTop);
  }, [settings?.widgetAlwaysOnTop]);

  useEffect(() => {
    document.documentElement.classList.add("dark");
    document.body.classList.add("widget-body");
  }, []);

  // Dropping the card near a screen edge snaps it flush, so it can live in a corner.
  useEffect(() => {
    const onUp = () => void api.snapWidget();
    window.addEventListener("pointerup", onUp);
    return () => window.removeEventListener("pointerup", onUp);
  }, []);

  const active = (live?.perSource ?? []).filter((s) => s.active);

  return (
    <div className="glass-lens drag-region flex h-full w-full flex-col gap-1.5 p-3">
      <div className="flex items-center gap-1.5">
        <span className={`status-dot ${(live?.tpm ?? 0) > 0 ? "status-live" : "status-missing"}`} />
        <span className="text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
          {t("widget.live")}
        </span>

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
      </div>

      <div className="flex items-baseline gap-3">
        <div>
          <div className="tnum text-[1.35rem] font-semibold leading-none">
            {rate(live?.tpm ?? 0)}
          </div>
          <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
            {t("widget.tokensMin")}
          </div>
        </div>
        <div>
          <div className="tnum text-[1.35rem] font-semibold leading-none">
            {rate(live?.rpm ?? 0)}
          </div>
          <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
            {t("widget.reqMin")}
          </div>
        </div>
        <div className="ml-auto flex items-baseline gap-3 text-right">
          <div>
            <div className="tnum text-[1.05rem] font-semibold leading-none">
              {tokens(live?.tokensToday ?? 0)}
            </div>
            <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
              {t("widget.tokensToday")}
            </div>
          </div>
          <div>
            <div className="tnum text-[1.05rem] font-semibold leading-none">
              {usd(live?.costToday ?? 0)}
            </div>
            <div className="text-[0.5625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
              {t("widget.costToday")}
            </div>
          </div>
        </div>
      </div>

      <Sparkline values={live?.spark60 ?? []} />

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
                // Polling sources report a backfilled rate, so they pulse instead of
                // showing a steady dot.
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
