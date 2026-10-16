/**
 * Shared time-range control.
 * Presets apply immediately; only "Custom" opens a draft panel that needs Confirm.
 */
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { CalendarDays, ChevronLeft, ChevronRight, Clock } from "lucide-react";
import clsx from "clsx";

import { GlassButton } from "./glass/GlassButton";
import { useT, rangeKey as rangeMsgKey } from "../lib/i18n";
import { dateTime } from "../lib/format";
import {
  RANGE_PRESETS,
  resolveRange,
  useUi,
  type RangeKey,
} from "../lib/store";

type PresetKey = Exclude<RangeKey, "custom">;

interface Draft {
  from: number;
  to: number;
  endFollowsNow: boolean;
  picking: "start" | "end";
  cursor: Date;
}

function startOfDay(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function combineDateAndTime(dateMs: number, hours: number, minutes: number): number {
  const d = new Date(dateMs);
  d.setHours(hours, minutes, 0, 0);
  return d.getTime();
}

function toDateInput(ms: number): string {
  const d = new Date(ms);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function toTimeInput(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

function parseDateInput(value: string, fallback: number): number {
  const [y, m, d] = value.split("-").map(Number);
  if (!y || !m || !d) return fallback;
  const next = new Date(fallback);
  next.setFullYear(y, m - 1, d);
  return next.getTime();
}

function parseTimeInput(value: string, baseMs: number): number {
  const [h, m] = value.split(":").map(Number);
  if (Number.isNaN(h) || Number.isNaN(m)) return baseMs;
  return combineDateAndTime(baseMs, h, m);
}

function monthLabel(d: Date, locale: string): string {
  return new Intl.DateTimeFormat(locale === "zh" ? "zh-CN" : undefined, {
    year: "numeric",
    month: "long",
  }).format(d);
}

function weekdayLabels(locale: string): string[] {
  const fmt = new Intl.DateTimeFormat(locale === "zh" ? "zh-CN" : undefined, {
    weekday: "narrow",
  });
  const base = new Date(2024, 0, 7);
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(base);
    d.setDate(base.getDate() + i);
    return fmt.format(d);
  });
}

function buildMonthCells(cursor: Date): { ms: number; inMonth: boolean }[] {
  const first = new Date(cursor.getFullYear(), cursor.getMonth(), 1);
  const startPad = first.getDay();
  const start = new Date(first);
  start.setDate(1 - startPad);
  const cells: { ms: number; inMonth: boolean }[] = [];
  for (let i = 0; i < 42; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    d.setHours(0, 0, 0, 0);
    cells.push({ ms: d.getTime(), inMonth: d.getMonth() === cursor.getMonth() });
  }
  return cells;
}

function draftFromStore(
  range: RangeKey,
  customFrom: number,
  customTo: number,
  endFollowsNow: boolean,
): Draft {
  if (range === "custom") {
    const to = endFollowsNow ? Date.now() : customTo;
    return {
      from: customFrom,
      to: Math.max(customFrom, to),
      endFollowsNow,
      picking: "start",
      cursor: new Date(startOfDay(customFrom)),
    };
  }
  const { from, to } = resolveRange(range);
  return {
    from,
    to,
    endFollowsNow: true,
    picking: "start",
    cursor: new Date(startOfDay(from || Date.now())),
  };
}

function triggerLabel(
  range: RangeKey,
  from: number,
  to: number,
  labelFor: (key: RangeKey) => string,
): string {
  if (range !== "custom") return labelFor(range);
  return `${dateTime(from)} – ${dateTime(to)}`;
}

export function RangePicker({ onCommit }: { onCommit?: () => void }) {
  const { t, locale } = useT();
  const range = useUi((s) => s.range);
  const customFrom = useUi((s) => s.customFrom);
  const customTo = useUi((s) => s.customTo);
  const endFollowsNow = useUi((s) => s.endFollowsNow);
  const setRange = useUi((s) => s.setRange);
  const setCustomRange = useUi((s) => s.setCustomRange);

  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<Draft>(() =>
    draftFromStore(range, customFrom, customTo, endFollowsNow),
  );
  const [panelPos, setPanelPos] = useState<{ top: number; right: number }>({ top: 0, right: 0 });
  const rootRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);

  const resolved = useMemo(() => {
    if (range === "custom") {
      const to = endFollowsNow ? Date.now() : customTo;
      return { from: customFrom, to: Math.max(customFrom, to) };
    }
    return resolveRange(range);
  }, [range, customFrom, customTo, endFollowsNow]);

  const label = triggerLabel(range, resolved.from, resolved.to, (key) => t(rangeMsgKey(key)));

  const placePanel = () => {
    const el = rootRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    setPanelPos({
      top: r.bottom + 6,
      right: Math.max(8, window.innerWidth - r.right),
    });
  };

  useLayoutEffect(() => {
    if (!open) return;
    placePanel();
    window.addEventListener("resize", placePanel);
    window.addEventListener("scroll", placePanel, true);
    return () => {
      window.removeEventListener("resize", placePanel);
      window.removeEventListener("scroll", placePanel, true);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      const target = e.target as Node;
      if (rootRef.current?.contains(target) || panelRef.current?.contains(target)) return;
      setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  useEffect(() => {
    if (!open || !draft.endFollowsNow) return;
    const id = window.setInterval(() => {
      setDraft((d) => (d.endFollowsNow ? { ...d, to: Date.now() } : d));
    }, 30_000);
    return () => window.clearInterval(id);
  }, [open, draft.endFollowsNow]);

  const openCustom = () => {
    setDraft(draftFromStore(range, customFrom, customTo, endFollowsNow));
    placePanel();
    setOpen(true);
  };

  /** Presets commit immediately — no confirm step. */
  const applyPreset = (key: PresetKey) => {
    setRange(key);
    setOpen(false);
    onCommit?.();
  };

  const patchDraft = (patch: Partial<Draft>) => {
    setDraft((d) => ({ ...d, ...patch }));
  };

  const onDayClick = (dayMs: number) => {
    setDraft((d) => {
      if (d.picking === "start" || dayMs < startOfDay(d.from)) {
        const from = combineDateAndTime(dayMs, 0, 0);
        const to = d.endFollowsNow
          ? Date.now()
          : Math.max(from, combineDateAndTime(dayMs, 23, 59));
        return { ...d, from, to: Math.max(from, to), picking: "end" };
      }
      const endH = d.endFollowsNow ? new Date().getHours() : 23;
      const endM = d.endFollowsNow ? new Date().getMinutes() : 59;
      const to = d.endFollowsNow ? Date.now() : combineDateAndTime(dayMs, endH, endM);
      const from = combineDateAndTime(
        startOfDay(d.from),
        new Date(d.from).getHours(),
        new Date(d.from).getMinutes(),
      );
      return {
        ...d,
        from,
        to: Math.max(from, to),
        picking: "start",
        endFollowsNow: d.endFollowsNow && startOfDay(dayMs) === startOfDay(Date.now()),
      };
    });
  };

  const confirmCustom = () => {
    let from = draft.from;
    let to = draft.endFollowsNow ? Date.now() : draft.to;
    if (to < from) [from, to] = [to, from];
    setCustomRange(from, to, draft.endFollowsNow);
    setOpen(false);
    onCommit?.();
  };

  const cells = useMemo(() => buildMonthCells(draft.cursor), [draft.cursor]);
  const weekdays = useMemo(() => weekdayLabels(locale), [locale]);
  const fromDay = startOfDay(draft.from);
  const toDay = startOfDay(draft.to);
  const today = startOfDay(Date.now());

  return (
    <div ref={rootRef} className="relative no-drag flex flex-wrap items-center justify-end gap-1.5">
      {RANGE_PRESETS.map((key) => {
        const on = range === key;
        return (
          <GlassButton
            key={key}
            size="sm"
            tone={on ? "accent" : "default"}
            onClick={() => applyPreset(key)}
            aria-pressed={on}
          >
            {t(rangeMsgKey(key))}
          </GlassButton>
        );
      })}

      <GlassButton
        size="sm"
        tone={range === "custom" || open ? "accent" : "default"}
        onClick={() => (open ? setOpen(false) : openCustom())}
        aria-expanded={open}
        aria-haspopup="dialog"
        title={range === "custom" ? label : t("range.custom")}
        className="max-w-[14rem]"
      >
        <CalendarDays size={13} strokeWidth={2} />
        <span className="truncate tnum">
          {range === "custom" ? label : t("range.custom")}
        </span>
      </GlassButton>

      {open &&
        createPortal(
          <div
            ref={panelRef}
            role="dialog"
            aria-label={t("range.pickerTitle")}
            className="range-popover fixed z-[80] w-[min(34rem,calc(100vw-1rem))] p-3"
            style={{
              top: panelPos.top,
              right: panelPos.right,
              maxHeight: "calc(100vh - 1rem)",
              overflow: "auto",
            }}
          >
            <div className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.05fr)]">
              <div className="flex flex-col gap-2.5">
                <FieldBlock label={t("range.start")}>
                  <DateTimeRow
                    dateValue={toDateInput(draft.from)}
                    timeValue={toTimeInput(draft.from)}
                    active={draft.picking === "start"}
                    onFocus={() => patchDraft({ picking: "start" })}
                    onDateChange={(v) =>
                      patchDraft({ from: parseDateInput(v, draft.from), picking: "start" })
                    }
                    onTimeChange={(v) =>
                      patchDraft({ from: parseTimeInput(v, draft.from), picking: "start" })
                    }
                  />
                </FieldBlock>

                <FieldBlock label={t("range.end")}>
                  <DateTimeRow
                    dateValue={toDateInput(draft.to)}
                    timeValue={toTimeInput(draft.to)}
                    active={draft.picking === "end"}
                    disabled={draft.endFollowsNow}
                    onFocus={() => patchDraft({ picking: "end" })}
                    onDateChange={(v) =>
                      patchDraft({
                        to: parseDateInput(v, draft.to),
                        picking: "end",
                        endFollowsNow: false,
                      })
                    }
                    onTimeChange={(v) =>
                      patchDraft({
                        to: parseTimeInput(v, draft.to),
                        picking: "end",
                        endFollowsNow: false,
                      })
                    }
                  />
                </FieldBlock>

                <label className="mt-0.5 flex cursor-pointer items-center gap-2 text-[0.75rem] text-[rgb(var(--text-dim))]">
                  <input
                    type="checkbox"
                    className="accent-[rgb(var(--accent))]"
                    checked={draft.endFollowsNow}
                    onChange={(e) => {
                      const on = e.target.checked;
                      patchDraft({ endFollowsNow: on, to: on ? Date.now() : draft.to });
                    }}
                  />
                  {t("range.endFollowsNow")}
                </label>
              </div>

              <div className="range-popover-cal flex flex-col gap-2 p-2.5">
                <div className="flex items-center gap-1">
                  <button
                    type="button"
                    className="grid h-7 w-7 place-items-center rounded-lg text-[rgb(var(--text-dim))] hover:bg-white/10 hover:text-[rgb(var(--text))]"
                    aria-label={t("range.prevMonth")}
                    onClick={() =>
                      setDraft((d) => {
                        const c = new Date(d.cursor);
                        c.setMonth(c.getMonth() - 1);
                        return { ...d, cursor: c };
                      })
                    }
                  >
                    <ChevronLeft size={14} />
                  </button>
                  <div className="flex-1 text-center text-[0.8125rem] font-semibold tracking-tight">
                    {monthLabel(draft.cursor, locale)}
                  </div>
                  <button
                    type="button"
                    className="grid h-7 w-7 place-items-center rounded-lg text-[rgb(var(--text-dim))] hover:bg-white/10 hover:text-[rgb(var(--text))]"
                    aria-label={t("range.nextMonth")}
                    onClick={() =>
                      setDraft((d) => {
                        const c = new Date(d.cursor);
                        c.setMonth(c.getMonth() + 1);
                        return { ...d, cursor: c };
                      })
                    }
                  >
                    <ChevronRight size={14} />
                  </button>
                </div>

                <div className="grid grid-cols-7 gap-0.5 text-center text-[0.625rem] font-semibold uppercase tracking-[0.04em] text-[rgb(var(--text-faint))]">
                  {weekdays.map((w, i) => (
                    <div key={i} className="py-0.5">
                      {w}
                    </div>
                  ))}
                </div>

                <div className="grid grid-cols-7 gap-0.5">
                  {cells.map(({ ms, inMonth }) => {
                    const inRange = ms >= fromDay && ms <= toDay;
                    const isStart = ms === fromDay;
                    const isEnd = ms === toDay;
                    const isToday = ms === today;
                    return (
                      <button
                        key={ms}
                        type="button"
                        disabled={ms > today}
                        onClick={() => onDayClick(ms)}
                        className={clsx(
                          "relative h-8 rounded-md text-[0.75rem] tnum transition-colors",
                          !inMonth && "opacity-35",
                          ms > today && "cursor-not-allowed opacity-25",
                          inRange && !isStart && !isEnd && "bg-[rgb(var(--accent)/0.22)]",
                          (isStart || isEnd) && "bg-[rgb(var(--accent))] font-semibold text-white",
                          !inRange && inMonth && ms <= today && "hover:bg-white/10",
                          isToday && !isStart && !isEnd && "ring-1 ring-[rgb(var(--accent)/0.55)]",
                        )}
                      >
                        {new Date(ms).getDate()}
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>

            <div className="mt-3 flex items-center justify-end gap-2">
              <GlassButton size="sm" tone="ghost" onClick={() => setOpen(false)}>
                {t("common.cancel")}
              </GlassButton>
              <GlassButton size="sm" tone="accent" onClick={confirmCustom}>
                {t("common.confirm")}
              </GlassButton>
            </div>
          </div>,
          document.body,
        )}
    </div>
  );
}

function FieldBlock({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-[0.6875rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
        {label}
      </span>
      {children}
    </div>
  );
}

function DateTimeRow({
  dateValue,
  timeValue,
  active,
  disabled,
  onFocus,
  onDateChange,
  onTimeChange,
}: {
  dateValue: string;
  timeValue: string;
  active?: boolean;
  disabled?: boolean;
  onFocus?: () => void;
  onDateChange: (v: string) => void;
  onTimeChange: (v: string) => void;
}) {
  return (
    <div
      className={clsx(
        "range-popover-field flex items-center gap-1.5 px-2 py-1.5",
        active && "ring-1 ring-[rgb(var(--accent)/0.65)]",
        disabled && "opacity-55",
      )}
    >
      <CalendarDays size={13} className="shrink-0 text-[rgb(var(--text-faint))]" />
      <input
        type="date"
        value={dateValue}
        disabled={disabled}
        onFocus={onFocus}
        onChange={(e) => onDateChange(e.target.value)}
        className="no-drag min-w-0 flex-1 bg-transparent text-[0.8125rem] outline-none disabled:cursor-not-allowed"
      />
      <Clock size={13} className="shrink-0 text-[rgb(var(--text-faint))]" />
      <input
        type="time"
        value={timeValue}
        disabled={disabled}
        onFocus={onFocus}
        onChange={(e) => onTimeChange(e.target.value)}
        className="no-drag w-[5.5rem] bg-transparent text-[0.8125rem] outline-none disabled:cursor-not-allowed"
      />
    </div>
  );
}
