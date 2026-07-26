/**
 * Ranked breakdown with an inline proportion bar.
 *
 * A bar list beats a pie here: these distributions are usually dominated by one or two
 * entries, and exact ordering plus a readable number matters more than the wedge shape.
 */
import { motion } from "framer-motion";
import type { GroupStat } from "../../lib/types";
import { resolveSourceColor, sourceLabel } from "../../lib/sources";
import { share, tokens, usd } from "../../lib/format";
import { useT } from "../../lib/i18n";

interface Props {
  items: GroupStat[];
  metric?: "tokens" | "cost";
  colorBy?: "source" | "accent";
  limit?: number;
  onSelect?: (key: string) => void;
  emptyText?: string;
}

export function ShareList({
  items,
  metric = "tokens",
  colorBy = "accent",
  limit = 8,
  onSelect,
  emptyText,
}: Props) {
  const { t } = useT();
  const empty = emptyText ?? t("common.nothingYet");
  if (!items.length) {
    return (
      <div className="py-6 text-center text-[0.8125rem] text-[rgb(var(--text-faint))]">
        {empty}
      </div>
    );
  }

  // Sort by the metric currently on screen. The SQL default is token volume, but toggling
  // to Cost must re-rank without another round trip — Cursor can dominate tokens with few
  // events, so ordering by event count would put it at the bottom of a token list.
  const ranked = [...items].sort((a, b) =>
    metric === "cost" ? b.costUsd - a.costUsd : b.totalTokens - a.totalTokens,
  );
  const shown = ranked.slice(0, limit);
  // Shares are relative to the largest entry so the top bar always fills the row; the
  // percentage label still reports the true share of the total.
  const max = Math.max(...shown.map((i) => (metric === "cost" ? i.costUsd : i.totalTokens)), 1);

  return (
    <div className="flex flex-col gap-0.5">
      {shown.map((item, i) => {
        const value = metric === "cost" ? item.costUsd : item.totalTokens;
        const color = colorBy === "source" ? resolveSourceColor(item.key) : "rgb(var(--accent))";
        // Grouping by source yields bare ids from SQL; show the product names instead.
        const label = colorBy === "source" ? sourceLabel(item.key) : item.label;
        return (
          <button
            key={item.key}
            type="button"
            disabled={!onSelect}
            onClick={() => onSelect?.(item.key)}
            className="group relative flex items-center gap-2.5 rounded-[10px] px-2 py-1.5 text-left transition-colors enabled:hover:bg-white/[0.06]"
          >
            <span
              className="h-2 w-2 shrink-0 rounded-full"
              style={{ background: color }}
              aria-hidden
            />
            <span className="min-w-0 flex-1">
              <span className="flex items-baseline gap-2">
                <span className="truncate text-[0.8125rem]" title={label}>
                  {label}
                </span>
                <span className="tnum ml-auto shrink-0 text-[0.8125rem] font-medium">
                  {metric === "cost" ? usd(value) : tokens(value)}
                </span>
                <span className="tnum w-9 shrink-0 text-right text-[0.6875rem] text-[rgb(var(--text-faint))]">
                  {share(item.share)}
                </span>
              </span>
              <span className="mt-1 block h-[3px] w-full overflow-hidden rounded-full bg-white/8">
                <motion.span
                  className="block h-full rounded-full"
                  style={{ background: color }}
                  initial={{ width: 0 }}
                  animate={{ width: `${(value / max) * 100}%` }}
                  transition={{ duration: 0.5, delay: i * 0.03, ease: [0.22, 1, 0.36, 1] }}
                />
              </span>
            </span>
            {item.unpriced && metric === "cost" && (
              <span className="chip shrink-0" title="No price entry matched this model">
                unpriced
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}
