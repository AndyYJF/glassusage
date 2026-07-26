import { useEffect, useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  ChevronLeft,
  ChevronRight,
  Download,
  FileJson,
  Search,
  TableProperties,
  X,
} from "lucide-react";

import { GlassButton } from "../components/glass/GlassButton";
import { GlassCard } from "../components/glass/GlassCard";
import { GlassSegmented } from "../components/glass/GlassSegmented";
import { RangePicker } from "../components/RangePicker";
import { ShareList } from "../components/charts/ShareList";
import { api, type GroupBy } from "../lib/api";
import { useFilterOptions, useGroupStats, useRange, useUsageLog } from "../lib/hooks";
import { useT } from "../lib/i18n";
import { useUi } from "../lib/store";
import { dateTime, projectLabel, tokens, usd } from "../lib/format";
import { sourceLabel } from "../lib/sources";
import type { ModelPrice, UsageRow } from "../lib/types";

const PAGE_SIZE = 50;
const MTOK = 1_000_000;

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
      <span className="mt-1.5 w-16 shrink-0 text-[0.6875rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
        {label}
      </span>
      <div className="flex flex-wrap gap-1.5">
        {options.map((opt) => {
          const on = selected?.includes(opt) ?? false;
          return (
            <GlassButton
              key={opt}
              size="sm"
              tone={on ? "accent" : "default"}
              aria-pressed={on}
              onClick={() => onToggle(opt)}
              className="px-2 py-0.5 text-[0.6875rem]"
            >
              {format(opt)}
            </GlassButton>
          );
        })}
      </div>
    </div>
  );
}

export function UsagePage() {
  const { t } = useT();
  const qc = useQueryClient();
  const filter = useUi((s) => s.filter);
  const setFilter = useUi((s) => s.setFilter);
  const resetFilter = useUi((s) => s.resetFilter);
  const notify = useUi((s) => s.notify);

  const { from, to } = useRange();
  const [page, setPage] = useState(0);
  const [groupBy, setGroupBy] = useState<GroupBy>("model_norm");
  const [search, setSearch] = useState("");
  const [exportOpen, setExportOpen] = useState(false);
  const [priceDrafts, setPriceDrafts] = useState<Record<string, { in: string; out: string }>>({});
  const [pricingBusy, setPricingBusy] = useState(false);

  const groups = useMemo(
    () => [
      { value: "model_norm" as const, label: t("usage.groupModel") },
      { value: "provider" as const, label: t("usage.groupProvider") },
      { value: "project" as const, label: t("usage.groupProject") },
      { value: "instance" as const, label: t("usage.groupInstance") },
    ],
    [t],
  );

  const unpricedOnly = Boolean(filter.unpricedOnly);

  const effective = useMemo(
    () => ({
      ...filter,
      from,
      to,
      search: search.trim() || undefined,
      unpricedOnly: unpricedOnly || undefined,
    }),
    [filter, from, to, search, unpricedOnly],
  );

  const { data: log, isFetching } = useUsageLog(effective, page, PAGE_SIZE);
  const { data: groupStats } = useGroupStats(groupBy, effective);
  const { data: unpricedModels } = useGroupStats("model_norm", {
    ...effective,
    unpricedOnly: true,
  });
  const { data: options } = useFilterOptions();

  useEffect(() => {
    if (!unpricedOnly || !unpricedModels) return;
    setPriceDrafts((prev) => {
      const next = { ...prev };
      for (const m of unpricedModels) {
        if (!next[m.key]) next[m.key] = { in: "", out: "" };
      }
      return next;
    });
  }, [unpricedOnly, unpricedModels]);

  const toggle = (field: "sources" | "providers" | "models" | "instances", value: string) => {
    const current = filter[field] ?? [];
    const next = current.includes(value)
      ? current.filter((v) => v !== value)
      : [...current, value];
    setFilter({ [field]: next.length ? next : undefined });
    setPage(0);
  };

  const runExport = async (kind: "csv" | "json" | "monthly") => {
    setExportOpen(false);
    try {
      const path =
        kind === "csv"
          ? await api.exportCsv(effective)
          : kind === "json"
            ? await api.exportJson(effective)
            : await api.exportMonthlyReport(effective);
      notify(t("usage.exported", { path }));
    } catch (e) {
      notify(String(e), "error");
    }
  };

  const applyPrices = async () => {
    const overrides: Record<string, ModelPrice> = {};
    for (const [model, draft] of Object.entries(priceDrafts)) {
      const input = Number(draft.in);
      const output = Number(draft.out);
      if (!Number.isFinite(input) || !Number.isFinite(output) || (input <= 0 && output <= 0)) {
        continue;
      }
      // UI is $/MTok; store is per-token.
      overrides[model] = {
        input_cost_per_token: input / MTOK,
        output_cost_per_token: output / MTOK,
      };
    }
    if (!Object.keys(overrides).length) {
      notify(t("usage.priceNeedValues"), "error");
      return;
    }
    setPricingBusy(true);
    try {
      const n = await api.setPricingOverrides(overrides);
      notify(t("usage.priceApplied", { n: String(n), models: String(Object.keys(overrides).length) }));
      qc.invalidateQueries();
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setPricingBusy(false);
    }
  };

  const totalPages = Math.max(1, Math.ceil((log?.total ?? 0) / PAGE_SIZE));
  const hasFilters =
    Boolean(search) ||
    unpricedOnly ||
    Boolean(
      filter.sources?.length ||
        filter.providers?.length ||
        filter.models?.length ||
        filter.instances?.length,
    );

  return (
    <div className="flex h-full min-h-0 flex-col gap-3">
      <div className="flex items-center gap-3">
        <h1 className="text-[1.05rem] font-semibold tracking-tight">{t("usage.title")}</h1>
        <div className="ml-auto flex items-center gap-2">
          <RangePicker onCommit={() => setPage(0)} />
          <div className="relative">
            <GlassButton size="sm" onClick={() => setExportOpen((o) => !o)}>
              <Download size={13} />
              {t("usage.export")}
            </GlassButton>
            {exportOpen && (
              <div className="range-popover absolute right-0 top-[calc(100%+0.35rem)] z-40 flex min-w-[11rem] flex-col gap-0.5 p-1.5">
                <button
                  type="button"
                  className="flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[0.75rem] hover:bg-white/10"
                  onClick={() => void runExport("csv")}
                >
                  <TableProperties size={13} />
                  {t("usage.exportCsv")}
                </button>
                <button
                  type="button"
                  className="flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[0.75rem] hover:bg-white/10"
                  onClick={() => void runExport("json")}
                >
                  <FileJson size={13} />
                  {t("usage.exportJson")}
                </button>
                <button
                  type="button"
                  className="flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[0.75rem] hover:bg-white/10"
                  onClick={() => void runExport("monthly")}
                >
                  <FileJson size={13} />
                  {t("usage.exportMonthly")}
                </button>
              </div>
            )}
          </div>
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
          <GlassButton
            size="sm"
            tone={unpricedOnly ? "accent" : "default"}
            aria-pressed={unpricedOnly}
            onClick={() => {
              setFilter({ unpricedOnly: unpricedOnly ? undefined : true });
              setPage(0);
            }}
          >
            {t("usage.unpricedOnly")}
          </GlassButton>
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
        <FilterChips
          label={t("usage.instance")}
          options={options?.instance ?? []}
          selected={filter.instances}
          onToggle={(v) => toggle("instances", v)}
          format={(v) => (v === "local" ? t("usage.instanceLocal") : v)}
        />
      </GlassCard>

      {unpricedOnly && (unpricedModels?.length ?? 0) > 0 && (
        <GlassCard variant="plain" className="flex flex-col gap-2 p-3">
          <div className="flex items-center gap-2">
            <div className="text-[0.8125rem] font-semibold">{t("usage.fixUnpriced")}</div>
            <span className="text-[0.6875rem] text-[rgb(var(--text-dim))]">
              {t("usage.fixUnpricedHint")}
            </span>
            <GlassButton
              className="ml-auto"
              size="sm"
              tone="accent"
              disabled={pricingBusy}
              onClick={() => void applyPrices()}
            >
              {pricingBusy ? t("common.loading") : t("usage.applyPrices")}
            </GlassButton>
          </div>
          <div className="scroll-area max-h-40 overflow-y-auto">
            <table className="w-full border-collapse text-[0.75rem]">
              <thead>
                <tr className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
                  <th className="px-2 py-1 text-left font-semibold">{t("usage.model")}</th>
                  <th className="px-2 py-1 text-right font-semibold">{t("usage.events")}</th>
                  <th className="px-2 py-1 text-right font-semibold">{t("usage.priceIn")}</th>
                  <th className="px-2 py-1 text-right font-semibold">{t("usage.priceOut")}</th>
                </tr>
              </thead>
              <tbody>
                {(unpricedModels ?? []).slice(0, 40).map((m) => (
                  <tr key={m.key} className="border-t border-white/6">
                    <td className="max-w-[14rem] truncate px-2 py-1.5" title={m.key}>
                      {m.key}
                    </td>
                    <td className="tnum px-2 py-1.5 text-right text-[rgb(var(--text-dim))]">
                      {m.events.toLocaleString()}
                    </td>
                    <td className="px-2 py-1.5 text-right">
                      <input
                        type="number"
                        min={0}
                        step={0.1}
                        placeholder="0"
                        value={priceDrafts[m.key]?.in ?? ""}
                        onChange={(e) =>
                          setPriceDrafts((d) => ({
                            ...d,
                            [m.key]: { in: e.target.value, out: d[m.key]?.out ?? "" },
                          }))
                        }
                        className="no-drag w-[5.5rem] rounded-md border border-white/8 bg-black/15 px-1.5 py-0.5 text-right outline-none"
                      />
                    </td>
                    <td className="px-2 py-1.5 text-right">
                      <input
                        type="number"
                        min={0}
                        step={0.1}
                        placeholder="0"
                        value={priceDrafts[m.key]?.out ?? ""}
                        onChange={(e) =>
                          setPriceDrafts((d) => ({
                            ...d,
                            [m.key]: { in: d[m.key]?.in ?? "", out: e.target.value },
                          }))
                        }
                        className="no-drag w-[5.5rem] rounded-md border border-white/8 bg-black/15 px-1.5 py-0.5 text-right outline-none"
                      />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </GlassCard>
      )}

      <div className="grid min-h-0 flex-1 grid-cols-[1fr_300px] gap-3">
        <GlassCard variant="lens" className="flex min-h-0 min-w-0 flex-col p-0">
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
