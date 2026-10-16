/**
 * Day-by-day activity grid, one column per week.
 *
 * Intensity uses a square-root scale: token counts across a quarter routinely span three
 * orders of magnitude, and a linear ramp would leave every day but the busiest looking
 * empty.
 */
import { useMemo } from "react";
import { tokens } from "../../lib/format";

const WEEKDAYS = ["", "Mon", "", "Wed", "", "Fri", ""];

interface Props {
  /** `[YYYY-MM-DD, totalTokens]`, in any order. */
  data: [string, number][];
  weeks?: number;
  color?: string;
}

function isoDay(d: Date) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
    d.getDate(),
  ).padStart(2, "0")}`;
}

export function CalendarHeatmap({ data, weeks = 18, color = "rgb(var(--accent))" }: Props) {
  const { columns, max } = useMemo(() => {
    const byDay = new Map(data);
    const max = Math.max(1, ...data.map(([, v]) => v));

    // Anchor on the Sunday of the current week so the last column is the week in progress.
    const end = new Date();
    end.setHours(0, 0, 0, 0);
    end.setDate(end.getDate() - end.getDay());

    const columns: { day: string; value: number; date: Date }[][] = [];
    for (let w = weeks - 1; w >= 0; w--) {
      const col: { day: string; value: number; date: Date }[] = [];
      for (let d = 0; d < 7; d++) {
        const date = new Date(end);
        date.setDate(end.getDate() - w * 7 + d);
        const day = isoDay(date);
        col.push({ day, value: byDay.get(day) ?? 0, date });
      }
      columns.push(col);
    }
    return { columns, max };
  }, [data, weeks]);

  const now = Date.now();

  return (
    <div className="flex gap-1.5">
      <div className="flex flex-col justify-between py-[1px] text-[0.5625rem] leading-[10px] text-[rgb(var(--text-faint))]">
        {WEEKDAYS.map((d, i) => (
          <span key={i} className="h-[11px]">
            {d}
          </span>
        ))}
      </div>

      <div className="flex gap-[3px]">
        {columns.map((col, ci) => (
          <div key={ci} className="flex flex-col gap-[3px]">
            {col.map((cell) => {
              const future = cell.date.getTime() > now;
              const intensity = cell.value > 0 ? Math.sqrt(cell.value / max) : 0;
              return (
                <div
                  key={cell.day}
                  title={`${cell.day} · ${tokens(cell.value)} tokens`}
                  className="h-[11px] w-[11px] rounded-[3px] transition-transform hover:scale-125"
                  style={{
                    background: future
                      ? "transparent"
                      : intensity === 0
                        ? "rgb(255 255 255 / 0.05)"
                        : color,
                    // Floor at 0.18 so a day with a single call is still visible.
                    opacity: future ? 0.25 : intensity === 0 ? 1 : 0.18 + intensity * 0.82,
                  }}
                />
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}
