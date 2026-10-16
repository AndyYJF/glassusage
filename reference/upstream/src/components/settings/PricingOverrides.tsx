/**
 * Manage custom $/MTok overrides. Values are edited as dollars per million tokens
 * (same as Usage's unpriced batch UI) and stored as per-token rates.
 */
import { useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Plus, Trash2 } from "lucide-react";

import { GlassButton } from "../glass/GlassButton";
import { api } from "../../lib/api";
import { usePricingInfo } from "../../lib/hooks";
import { useT } from "../../lib/i18n";
import { useUi } from "../../lib/store";
import type { ModelPrice } from "../../lib/types";

const MTOK = 1_000_000;

function toMtok(perToken: number): string {
  if (!perToken) return "";
  const v = perToken * MTOK;
  return String(Number(v.toPrecision(6)));
}

export function PricingOverrides() {
  const { t } = useT();
  const notify = useUi((s) => s.notify);
  const qc = useQueryClient();
  const { data: pricing } = usePricingInfo();
  const [drafts, setDrafts] = useState<Record<string, { in: string; out: string }>>({});
  const [newModel, setNewModel] = useState("");
  const [newIn, setNewIn] = useState("");
  const [newOut, setNewOut] = useState("");
  const [busy, setBusy] = useState(false);

  const rows = useMemo(() => {
    const entries = Object.entries(pricing?.overrides ?? {}).sort(([a], [b]) =>
      a.localeCompare(b),
    );
    return entries.map(([model, price]) => {
      const draft = drafts[model];
      return {
        model,
        in: draft?.in ?? toMtok(price.input_cost_per_token),
        out: draft?.out ?? toMtok(price.output_cost_per_token),
      };
    });
  }, [pricing?.overrides, drafts]);

  const patchDraft = (model: string, field: "in" | "out", value: string) => {
    setDrafts((prev) => {
      const cur = prev[model] ?? {
        in: toMtok(pricing?.overrides?.[model]?.input_cost_per_token ?? 0),
        out: toMtok(pricing?.overrides?.[model]?.output_cost_per_token ?? 0),
      };
      return { ...prev, [model]: { ...cur, [field]: value } };
    });
  };

  const saveRow = async (model: string) => {
    const row = rows.find((r) => r.model === model);
    if (!row) return;
    const input = Number(row.in);
    const output = Number(row.out);
    if (!Number.isFinite(input) || !Number.isFinite(output) || (input <= 0 && output <= 0)) {
      notify(t("settings.priceInvalid"), "error");
      return;
    }
    setBusy(true);
    try {
      const price: ModelPrice = {
        input_cost_per_token: Math.max(0, input) / MTOK,
        output_cost_per_token: Math.max(0, output) / MTOK,
      };
      const n = await api.setPricingOverrides({ [model]: price });
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[model];
        return next;
      });
      notify(t("settings.priceSaved", { model, n: String(n) }));
      qc.invalidateQueries();
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setBusy(false);
    }
  };

  const removeRow = async (model: string) => {
    setBusy(true);
    try {
      const n = await api.removePricingOverride(model);
      setDrafts((prev) => {
        const next = { ...prev };
        delete next[model];
        return next;
      });
      notify(t("settings.priceRemoved", { model, n: String(n) }));
      qc.invalidateQueries();
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setBusy(false);
    }
  };

  const addRow = async () => {
    const model = newModel.trim();
    if (!model) {
      notify(t("settings.priceNeedModel"), "error");
      return;
    }
    const input = Number(newIn);
    const output = Number(newOut);
    if (!Number.isFinite(input) || !Number.isFinite(output) || (input <= 0 && output <= 0)) {
      notify(t("settings.priceInvalid"), "error");
      return;
    }
    setBusy(true);
    try {
      const price: ModelPrice = {
        input_cost_per_token: Math.max(0, input) / MTOK,
        output_cost_per_token: Math.max(0, output) / MTOK,
      };
      const n = await api.setPricingOverrides({ [model]: price });
      setNewModel("");
      setNewIn("");
      setNewOut("");
      notify(t("settings.priceSaved", { model, n: String(n) }));
      qc.invalidateQueries();
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="text-[0.6875rem] text-[rgb(var(--text-dim))]">
        {t("settings.overridesHint")}
      </div>

      {rows.length === 0 ? (
        <div className="text-[0.75rem] text-[rgb(var(--text-faint))]">{t("settings.noOverrides")}</div>
      ) : (
        <div className="scroll-area max-h-56 overflow-y-auto">
          <table className="w-full border-collapse text-[0.75rem]">
            <thead>
              <tr className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
                <th className="px-2 py-1 text-left font-semibold">{t("usage.model")}</th>
                <th className="px-2 py-1 text-right font-semibold">{t("usage.priceIn")}</th>
                <th className="px-2 py-1 text-right font-semibold">{t("usage.priceOut")}</th>
                <th className="px-2 py-1 text-right font-semibold" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.model} className="border-t border-white/6">
                  <td className="max-w-[12rem] truncate px-2 py-1.5 font-medium" title={row.model}>
                    {row.model}
                  </td>
                  <td className="px-2 py-1.5 text-right">
                    <input
                      type="number"
                      min={0}
                      step="any"
                      value={row.in}
                      disabled={busy}
                      onChange={(e) => patchDraft(row.model, "in", e.target.value)}
                      className="glass-quiet w-20 rounded-md border border-white/8 bg-black/15 px-1.5 py-1 text-right tnum"
                    />
                  </td>
                  <td className="px-2 py-1.5 text-right">
                    <input
                      type="number"
                      min={0}
                      step="any"
                      value={row.out}
                      disabled={busy}
                      onChange={(e) => patchDraft(row.model, "out", e.target.value)}
                      className="glass-quiet w-20 rounded-md border border-white/8 bg-black/15 px-1.5 py-1 text-right tnum"
                    />
                  </td>
                  <td className="px-2 py-1.5 text-right">
                    <div className="inline-flex items-center gap-1">
                      <GlassButton
                        size="sm"
                        tone="accent"
                        disabled={busy || !drafts[row.model]}
                        onClick={() => void saveRow(row.model)}
                      >
                        {t("common.save")}
                      </GlassButton>
                      <GlassButton
                        size="sm"
                        tone="ghost"
                        disabled={busy}
                        aria-label={t("common.remove")}
                        onClick={() => void removeRow(row.model)}
                      >
                        <Trash2 size={12} />
                      </GlassButton>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="flex flex-wrap items-end gap-2 border-t border-white/6 pt-2">
        <label className="flex min-w-[10rem] flex-1 flex-col gap-1">
          <span className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
            {t("usage.model")}
          </span>
          <input
            value={newModel}
            disabled={busy}
            placeholder="provider/model"
            onChange={(e) => setNewModel(e.target.value)}
            className="glass-quiet rounded-md border border-white/8 bg-black/15 px-2 py-1.5 text-[0.8125rem]"
          />
        </label>
        <label className="flex w-24 flex-col gap-1">
          <span className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
            {t("usage.priceIn")}
          </span>
          <input
            type="number"
            min={0}
            step="any"
            value={newIn}
            disabled={busy}
            onChange={(e) => setNewIn(e.target.value)}
            className="glass-quiet rounded-md border border-white/8 bg-black/15 px-2 py-1.5 text-right tnum text-[0.8125rem]"
          />
        </label>
        <label className="flex w-24 flex-col gap-1">
          <span className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
            {t("usage.priceOut")}
          </span>
          <input
            type="number"
            min={0}
            step="any"
            value={newOut}
            disabled={busy}
            onChange={(e) => setNewOut(e.target.value)}
            className="glass-quiet rounded-md border border-white/8 bg-black/15 px-2 py-1.5 text-right tnum text-[0.8125rem]"
          />
        </label>
        <GlassButton size="sm" tone="accent" disabled={busy} onClick={() => void addRow()}>
          <Plus size={13} />
          {t("settings.addOverride")}
        </GlassButton>
      </div>
    </div>
  );
}
