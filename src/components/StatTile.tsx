import { ArrowDownRight, ArrowUpRight, Minus } from "lucide-react";
import { GlassCard } from "./glass/GlassCard";
import { Odometer } from "./glass/Odometer";
import { percent } from "../lib/format";

interface Props {
  label: string;
  value: string;
  /** Signed fraction, e.g. 0.12 for +12%. `null` when there is no baseline. */
  delta?: number | null;
  /** Text under the value, usually what the delta is measured against. */
  caption?: string;
  accent?: string;
  icon?: React.ReactNode;
}

export function StatTile({ label, value, delta, caption, accent, icon }: Props) {
  const dir = delta == null ? "flat" : delta > 0.005 ? "up" : delta < -0.005 ? "down" : "flat";

  return (
    <GlassCard variant="plain" className="relative overflow-hidden p-4">
      {accent && (
        <div
          className="pointer-events-none absolute -right-10 -top-12 h-28 w-28 rounded-full opacity-45 blur-2xl"
          style={{ background: accent }}
          aria-hidden
        />
      )}

      <div className="flex items-center gap-2 text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
        {icon}
        {label}
      </div>

      <div className="mt-2.5 text-[1.75rem] font-semibold leading-none tracking-tight">
        <Odometer value={value} />
      </div>

      <div className="mt-2 flex items-center gap-1.5 text-[0.75rem] text-[rgb(var(--text-dim))]">
        {delta !== undefined && (
          <span
            className="inline-flex items-center gap-0.5 font-semibold"
            style={{
              color:
                dir === "up"
                  ? "rgb(var(--warning))"
                  : dir === "down"
                    ? "rgb(var(--success))"
                    : "rgb(var(--text-faint))",
            }}
          >
            {dir === "up" && <ArrowUpRight size={13} />}
            {dir === "down" && <ArrowDownRight size={13} />}
            {dir === "flat" && <Minus size={13} />}
            {delta == null ? "new" : percent(Math.abs(delta))}
          </span>
        )}
        {caption && <span className="truncate">{caption}</span>}
      </div>
    </GlassCard>
  );
}
