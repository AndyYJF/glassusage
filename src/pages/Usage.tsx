import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Download, Search, X } from "lucide-react";

import { GlassButton } from "../components/glass/GlassButton";
import { GlassCard } from "../components/glass/GlassCard";
import { GlassSegmented } from "../components/glass/GlassSegmented";
import { ShareList } from "../components/charts/ShareList";
import { api, type GroupBy } from "../lib/api";
import { useFilterOptions, useGroupStats, useRange, useUsageLog } from "../lib/hooks";
import { useT, rangeKey } from "../lib/i18n";
import { RANGE_KEYS, useUi, type RangeKey } from "../lib/store";
import { dateTime, projectLabel, tokens, usd } from "../lib/format";
import { sourceLabel } from "../lib/sources";
import type { UsageRow } from "../lib/types";

const PAGE_SIZE = 50;

/** Multi-select chip row. Empty selection means "all", which keeps the filter compact. */
function FilterChips({
  label,
  options,
  selected,
  onToggle,
  format = (v: string) => v,
}: {
  label: string;
  options: string[];
  selected: string[] | undefined;
  onToggle: (value: string) => void;
  format?: (v: string) => string;
}) {
  if (!options.length) return null;
  return (
    <div className="flex items-start gap-2">
      <span className="mt-1 w-16 shrink-0 text-[0.6875rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
        {label}
      </span>
      <div className="flex flex-wrap gap-1.5">
        {options.map((opt) => {
          const on = selected?.includes(opt) ?? false;
          return (
            <button
              key={opt}
              type="button"
              onClick={() => onToggle(opt)}
              className="chip transition-colors"
              style={
                on
                  ? {
                      background: "rgb(var(--accent) / 0.24)",
                      borderColor: "rgb(var(--accent) / 0.5)",
                      color: "rgb(var(--text))",
                    }
                  : undefined
              }
            >
              {format(opt)}
            </button>
          );
        })}
      </div>
    </div>
  );
}

export function UsagePage() {
  const { t } = useT();
  const range = useUi((s) => s.range);
  const setRange = useUi((s) => s.setRange);
  const filter = useUi((s) => s.filter);
  const setFilter = useUi((s) => s.setFilter);
  const resetFilter = useUi((s) => s.resetFilter);
  const notify = useUi((s) => s.notify);

  const { from, to } = useRange();
  const [page, setPage] = useState(0);
  const [groupBy, setGroupBy] = useState<GroupBy>("model_norm");
  const [search, setSearch] = useState("");

  const rangeOptions = useMemo(
    () => RANGE_KEYS.map((value) => ({ value, label: t(rangeKey(value)) })),
    [t],
  );
  const groups = useMemo(
    () => [
      { value: "model_norm" as const, label: t("usage.groupModel") },
      { value: "provider" as const, label: t("usage.groupProvider") },
      { value: "project" as const, label: t("usage.groupProject") },
      { value: "instance" as const, label: t("usage.groupInstance") },
    ],
    [t],
  );

  // The range selector and the chip filters are separate controls but one query.
  const effective = useMemo(
    () => ({ ...filter, from, to, search: search.trim() || undefined }),
    [filter, from, to, search],
  );

  const { data: log, isFetching } = useUsageLog(effective, page, PAGE_SIZE);
  const { data: groupStats } = useGroupStats(groupBy, effective);
  const { data: options } = useFilterOptions();

  const toggle = (field: "sources" | "providers" | "models" | "instances", value: string) => {
    const current = filter[field] ?? [];
    const next = current.includes(value)
      ? current.filter((v) => v !== value)
      : [...current, value];
    setFilter({ [field]: next.length ? next : undefined });
    setPage(0);
  };

  const exportCsv = async () => {
    try {
      const path = await api.exportCsv(effective);
      notify(t("usage.exported", { path }));
    } catch (e) {
      notify(String(e), "error");
    }
  };

  const totalPages = Math.max(1, Math.ceil((log?.total ?? 0) / PAGE_SIZE));
  const hasFilters =
    Boolean(search) ||
    Boolean(filter.sources?.length || filter.providers?.length || filter.models?.length);

  return (
    <div className="flex h-full min-h-0 flex-col gap-3">
      <div className="flex items-center gap-3">
        <h1 className="text-[1.05rem] font-semibold tracking-tight">{t("usage.title")}</h1>
        <div className="ml-auto flex items-center gap-2">
          <GlassSegmented
            options={rangeOptions}
            value={range}
            onChange={(v) => {
              setRange(v as RangeKey);
              setPage(0);
            }}
            size="sm"
          />
          <GlassButton size="sm" onClick={exportCsv}>
            <Download size={13} />
            {t("usage.export")}
          </GlassButton>
        </div>
      </div>

      <GlassCard variant="plain" className="flex flex-col gap-2 p-3">
        <div className="flex items-center gap-2">
          <div className="glass-quiet flex min-w-0 flex-1 items-center gap-2 px-2.5 py-1.5">
            <Search size={13} className="shrink-0 text-[rgb(var(--text-faint))]" />
            <input
              value={search}
              onChange={(e) => {
                setSearch(e.target.value);
                setPage(0);
              }}
              placeholder={t("usage.search")}
              className="no-drag w-full bg-transparent text-[0.8125rem] outline-none placeholder:text-[rgb(var(--text-faint))]"
            />
          </div>
          {hasFilters && (
            <GlassButton
              size="sm"
              tone="ghost"
              onClick={() => {
                resetFilter();
                setSearch("");
                setPage(0);
              }}
            >
              <X size={13} />
              {t("common.clear")}
            </GlassButton>
          )}
        </div>

        <FilterChips
          label={t("usage.agent")}
          options={options?.source ?? []}
          selected={filter.sources}
          onToggle={(v) => toggle("sources", v)}
          format={sourceLabel}
        />
        <FilterChips
          label={t("usage.provider")}
          options={options?.provider ?? []}
          selected={filter.providers}
          onToggle={(v) => toggle("providers", v)}
        />
        <FilterChips
          label={t("usage.model")}
          options={(options?.model_norm ?? []).slice(0, 18)}
          selected={filter.models}
          onToggle={(v) => toggle("models", v)}
        />
      </GlassCard>

      <div className="grid min-h-0 flex-1 grid-cols-[1fr_300px] gap-3">
        <GlassCard variant="lens" className="flex min-h-0 min-w-0 flex-col p-0">
          {/* Header lives outside the scroller so it never stacks on the first data row
              (sticky + border-collapse + translucent backdrop was painting them together). */}
          <div className="shrink-0 border-b border-white/8 bg-black/25">
            <table className="w-full table-fixed border-collapse text-[0.8125rem]">
              <colgroup>
                <col className="w-[18%]" />
                <col className="w-[14%]" />
                <col className="w-[18%]" />
                <col className="w-[14%]" />
                <col className="w-[9%]" />
                <col className="w-[9%]" />
                <col className="w-[9%]" />
                <col className="w-[9%]" />
              </colgroup>
              <thead>
                <tr className="text-[0.6875rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
                  <th className="px-3 py-2 text-left font-semibold">{t("usage.time")}</th>
                  <th className="px-3 py-2 text-left font-semibold">{t("usage.agent")}</th>
                  <th className="px-3 py-2 text-left font-semibold">{t("usage.model")}</th>
                  <th className="px-3 py-2 text-left font-semibold">{t("usage.project")}</th>
                  <th className="px-3 py-2 text-right font-semibold">{t("usage.in")}</th>
                  <th className="px-3 py-2 text-right font-semibold">{t("usage.out")}</th>
                  <th className="px-3 py-2 text-right font-semibold">{t("usage.cache")}</th>
                  <th className="px-3 py-2 text-right font-semibold">{t("usage.cost")}</th>
                </tr>
              </thead>
            </table>
          </div>

          <div className="scroll-area min-h-0 flex-1 overflow-auto">
            <table className="w-full table-fixed border-collapse text-[0.8125rem]">
              <colgroup>
                <col className="w-[18%]" />
                <col className="w-[14%]" />
                <col className="w-[18%]" />
                <col className="w-[14%]" />
                <col className="w-[9%]" />
                <col className="w-[9%]" />
                <col className="w-[9%]" />
                <col className="w-[9%]" />
              </colgroup>
              <tbody>
                {(log?.rows ?? []).map((row) => (
                  <UsageTableRow key={row.id} row={row} />
                ))}
              </tbody>
            </table>

            {!log?.rows.length && (
              <div className="grid h-40 place-items-center text-[0.8125rem] text-[rgb(var(--text-faint))]">
                {isFetching ? t("common.loading") : t("usage.noMatch")}
              </div>
            )}
          </div>

          <div className="flex shrink-0 items-center gap-2 border-t border-white/8 px-3 py-2 text-[0.75rem] text-[rgb(var(--text-dim))]">
            <span className="tnum">{t("usage.eventsCount", { n: (log?.total ?? 0).toLocaleString() })}</span>
            <div className="ml-auto flex items-center gap-1">
              <GlassButton
                size="sm"
                tone="ghost"
                disabled={page === 0}
                onClick={() => setPage((p) => Math.max(0, p - 1))}
              >
                <ChevronLeft size={14} />
              </GlassButton>
              <span className="tnum px-1">
                {page + 1} / {totalPages}
              </span>
              <GlassButton
                size="sm"
                tone="ghost"
                disabled={page + 1 >= totalPages}
                onClick={() => setPage((p) => p + 1)}
              >
                <ChevronRight size={14} />
              </GlassButton>
            </div>
          </div>
        </GlassCard>

        <GlassCard variant="lens" className="flex min-h-0 flex-col p-3">
          <GlassSegmented
            className="mb-2 self-start"
            options={groups}
            value={groupBy}
            onChange={setGroupBy}
            size="sm"
          />
          <div className="scroll-area min-h-0 flex-1 overflow-y-auto">
            <ShareList items={groupStats ?? []} metric="tokens" limit={20} />
          </div>
        </GlassCard>
      </div>
    </div>
  );
}

function UsageTableRow({ row }: { row: UsageRow }) {
  const { t } = useT();
  const cache = row.cacheReadTokens + row.cacheWriteTokens;
  return (
    <tr className="border-b border-white/6 transition-colors hover:bg-white/[0.05]">
      <td className="whitespace-nowrap px-3 py-1.5 text-[rgb(var(--text-dim))]">
        {dateTime(row.tsMs)}
      </td>
      <td className="px-3 py-1.5">
        <span className="flex items-center gap-1.5">
          <span
            className="h-1.5 w-1.5 shrink-0 rounded-full"
            style={{ background: `rgb(var(--src-${row.source}))` }}
          />
          <span className="truncate">{sourceLabel(row.source)}</span>
          {row.instance !== "local" && <span className="chip">{row.instance}</span>}
        </span>
      </td>
      <td className="max-w-[190px] truncate px-3 py-1.5" title={row.model}>
        {row.modelNorm || row.model}
      </td>
      <td
        className="max-w-[140px] truncate px-3 py-1.5 text-[rgb(var(--text-dim))]"
        title={row.project ?? ""}
      >
        {projectLabel(row.project)}
      </td>
      <td className="tnum px-3 py-1.5 text-right">{tokens(row.inputTokens)}</td>
      <td className="tnum px-3 py-1.5 text-right">{tokens(row.outputTokens)}</td>
      <td className="tnum px-3 py-1.5 text-right text-[rgb(var(--text-dim))]">
        {cache > 0 ? tokens(cache) : "—"}
      </td>
      <td
        className="tnum px-3 py-1.5 text-right"
        style={row.unpriced ? { color: "rgb(var(--text-faint))" } : undefined}
        title={row.unpriced ? t("common.unpricedTitle") : undefined}
      >
        {usd(row.costUsd)}
      </td>
    </tr>
  );
}
