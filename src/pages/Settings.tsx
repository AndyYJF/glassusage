import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Cloud, DollarSign, FolderOpen, Info, Layers, Server, Sparkles, Wallet } from "lucide-react";

import { GlassButton } from "../components/glass/GlassButton";
import { GlassCard } from "../components/glass/GlassCard";
import { GlassSegmented } from "../components/glass/GlassSegmented";
import { GlassSlider } from "../components/glass/GlassSlider";
import { GlassSwitch } from "../components/glass/GlassSwitch";
import { RemoteInstances } from "../components/settings/RemoteInstances";
import { api } from "../lib/api";
import { useCursorStatus, usePricingInfo, useSettings, useSourceHealth } from "../lib/hooks";
import { useT, statusKey } from "../lib/i18n";
import { useUi } from "../lib/store";
import { SOURCE_LIST, STATUS_CLASS } from "../lib/sources";
import { percent, relative } from "../lib/format";
import type { AppSettings, LocaleMode } from "../lib/types";

function Section({
  title,
  icon,
  children,
}: {
  title: string;
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <GlassCard variant="lens" className="p-4">
      <div className="mb-3 flex items-center gap-2 text-[0.875rem] font-semibold">
        {icon}
        {title}
      </div>
      <div className="flex flex-col gap-3">{children}</div>
    </GlassCard>
  );
}

function Row({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-center gap-4">
      <div className="min-w-0 flex-1">
        <div className="text-[0.8125rem]">{label}</div>
        {hint && <div className="mt-0.5 text-[0.6875rem] text-[rgb(var(--text-dim))]">{hint}</div>}
      </div>
      <div className="flex shrink-0 items-center gap-2">{children}</div>
    </div>
  );
}

export function SettingsPage() {
  const { t } = useT();
  const qc = useQueryClient();
  const notify = useUi((s) => s.notify);
  const { data: settings } = useSettings();
  const { data: health } = useSourceHealth();
  const { data: pricing } = usePricingInfo();
  const { data: cursor } = useCursorStatus();

  const [cookie, setCookie] = useState("");
  const [refraction, setRefraction] = useState<number | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const patch = async (p: Partial<AppSettings> | Record<string, unknown>) => {
    try {
      // Paint the CSS underlay *before* asking Rust to clear the native backdrop.
      // Otherwise there is a frame where the window has neither, and every page goes blank.
      if (typeof p.material === "string") {
        document.documentElement.dataset.material = p.material;
        // Two animation frames: one to commit the attribute, one to paint it.
        await new Promise<void>((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
        );
      }
      const next = await api.setSettings(p);
      qc.setQueryData(["settings"], next);
    } catch (e) {
      notify(String(e), "error");
    }
  };

  if (!settings) {
    return (
      <div className="p-4 text-[0.8125rem] text-[rgb(var(--text-faint))]">{t("common.loading")}</div>
    );
  }

  const lens = refraction ?? settings.refraction;
  const locale = (settings.locale ?? "system") as LocaleMode;

  return (
    <div className="scroll-area flex h-full flex-col gap-3 overflow-y-auto pr-1">
      <h1 className="text-[1.05rem] font-semibold tracking-tight">{t("settings.title")}</h1>

      <Section title={t("settings.appearance")} icon={<Sparkles size={15} />}>
        <Row label={t("settings.language")} hint={t("settings.languageHint")}>
          <GlassSegmented
            options={[
              { value: "system", label: t("settings.langSystem") },
              { value: "en", label: t("settings.langEn") },
              { value: "zh", label: t("settings.langZh") },
            ]}
            value={locale}
            onChange={(next) => patch({ locale: next as LocaleMode })}
            size="sm"
          />
        </Row>

        <Row label={t("settings.material")} hint={t("settings.materialHint")}>
          <GlassSegmented
            options={[
              { value: "acrylic", label: t("settings.acrylic") },
              { value: "mica", label: t("settings.mica") },
              { value: "css", label: t("settings.css") },
            ]}
            value={settings.material}
            onChange={(material) => patch({ material })}
            size="sm"
          />
        </Row>

        <Row label={t("settings.theme")}>
          <GlassSegmented
            options={[
              { value: "system", label: t("settings.themeSystem") },
              { value: "dark", label: t("settings.themeDark") },
              { value: "light", label: t("settings.themeLight") },
            ]}
            value={settings.theme}
            onChange={(theme) => patch({ theme })}
            size="sm"
          />
        </Row>

        <Row
          label={t("settings.refraction")}
          hint={
            settings.material === "acrylic" || settings.material === "mica"
              ? t("settings.refractionAcrylic")
              : lens <= 0.01
                ? t("settings.refractionOff")
                : t("settings.refractionOn")
          }
        >
          <GlassSlider
            className="w-[200px]"
            value={lens}
            min={0}
            max={1.2}
            step={0.02}
            label={t("settings.refractionLabel")}
            format={(v) => percent(v / 1.2)}
            onChange={setRefraction}
            // Persist on release: writing settings.json on every pointermove would be
            // a file write per frame.
            onCommit={(v) => {
              setRefraction(null);
              patch({ refraction: v });
            }}
          />
        </Row>

        <Row label={t("settings.animatedBg")} hint={t("settings.animatedBgHint")}>
          <GlassSwitch
            checked={settings.animatedBackground}
            onChange={(animatedBackground) => patch({ animatedBackground })}
            label={t("settings.animatedBg")}
          />
        </Row>
      </Section>

      <Section title={t("settings.sources")} icon={<Layers size={15} />}>
        {SOURCE_LIST.map((meta) => {
          const cfg = settings.sources[meta.id] ?? { enabled: true, customPath: null };
          const h = health?.find((x) => x.source === meta.id && x.instance === "local");
          return (
            <div key={meta.id} className="glass-quiet px-3 py-2.5">
              <div className="flex items-center gap-2.5">
                <span
                  className="h-2 w-2 shrink-0 rounded-full"
                  style={{ background: `rgb(var(${meta.colorVar}))` }}
                />
                <span className="text-[0.8125rem] font-medium">{meta.label}</span>
                <span className={`status-dot ${STATUS_CLASS[h?.status ?? "missing"]}`} />
                <span className="text-[0.6875rem] text-[rgb(var(--text-dim))]">
                  {t(statusKey(h?.status ?? "missing"))}
                  {h?.lastScanMs ? ` · ${relative(h.lastScanMs)}` : ""}
                </span>
                <div className="ml-auto flex items-center gap-2">
                  <GlassButton size="sm" tone="ghost" onClick={() => api.rescanSource(meta.id)}>
                    {t("common.rescan")}
                  </GlassButton>
                  <GlassSwitch
                    checked={cfg.enabled}
                    label={`Enable ${meta.label}`}
                    onChange={(enabled) =>
                      patch({ sources: { [meta.id]: { ...cfg, enabled } } })
                    }
                  />
                </div>
              </div>

              <div className="mt-1.5 flex items-center gap-2">
                <input
                  defaultValue={cfg.customPath ?? ""}
                  placeholder={meta.origin}
                  spellCheck={false}
                  className="no-drag min-w-0 flex-1 rounded-lg border border-white/8 bg-black/15 px-2 py-1 text-[0.6875rem] outline-none placeholder:text-[rgb(var(--text-faint))] focus:border-[rgb(var(--accent)/0.6)]"
                  onBlur={(e) => {
                    const value = e.target.value.trim();
                    if (value === (cfg.customPath ?? "")) return;
                    patch({ sources: { [meta.id]: { ...cfg, customPath: value || null } } });
                  }}
                />
              </div>

              {meta.id === "antigravity" && (
                <div className="mt-1.5 flex items-center gap-2">
                  <GlassSwitch
                    checked={settings.antigravityIdeEnabled}
                    label={t("settings.readIde")}
                    onChange={(antigravityIdeEnabled) => patch({ antigravityIdeEnabled })}
                  />
                  <span className="text-[0.6875rem] text-[rgb(var(--text-dim))]">
                    {t("settings.readIdeHint")}
                  </span>
                </div>
              )}
            </div>
          );
        })}
      </Section>

      <Section title={t("settings.cursor")} icon={<Cloud size={15} />}>
        <Row
          label={t("settings.cursorStatus")}
          hint={
            cursor?.hasAccessToken
              ? t("settings.cursorChannelA")
              : cursor?.hasCookie
                ? t("settings.cursorChannelB")
                : t("settings.cursorNone")
          }
        >
          <span
            className={`status-dot ${cursor?.hasAccessToken || cursor?.hasCookie ? "status-live" : "status-missing"}`}
          />
        </Row>

        <div className="glass-quiet space-y-2 px-3 py-2.5 text-[0.75rem] leading-relaxed text-[rgb(var(--text-dim))]">
          <div className="font-medium text-[rgb(var(--text))]">{t("settings.cursorHow")}</div>
          <ol className="list-decimal space-y-1.5 pl-4">
            <li>{t("settings.cursorStep1")}</li>
            <li>{t("settings.cursorStep2")}</li>
            <li>{t("settings.cursorStep3")}</li>
          </ol>
        </div>

        <div className="flex items-center gap-2">
          <input
            value={cookie}
            onChange={(e) => setCookie(e.target.value)}
            type="password"
            placeholder={t("settings.cursorPlaceholder")}
            spellCheck={false}
            className="no-drag min-w-0 flex-1 rounded-lg border border-white/8 bg-black/15 px-2.5 py-1.5 text-[0.75rem] outline-none placeholder:text-[rgb(var(--text-faint))] focus:border-[rgb(var(--accent)/0.6)]"
          />
          <GlassButton
            size="sm"
            disabled={!cookie.trim()}
            onClick={async () => {
              try {
                await api.setCursorCookie(cookie.trim());
                setCookie("");
                notify(t("settings.cursorSaved"));
                qc.invalidateQueries({ queryKey: ["cursor-status"] });
              } catch (e) {
                notify(String(e), "error");
              }
            }}
          >
            {t("common.save")}
          </GlassButton>
          <GlassButton
            size="sm"
            onClick={async () => {
              try {
                await api.syncCursorNow();
                notify(t("settings.cursorSync"));
                qc.invalidateQueries({ queryKey: ["cursor-status"] });
                qc.invalidateQueries({ queryKey: ["overview"] });
              } catch (e) {
                notify(String(e), "error");
              }
            }}
          >
            {t("settings.syncNow")}
          </GlassButton>
        </div>

        {cursor?.lastError && (
          <div className="text-[0.6875rem] text-[rgb(var(--danger))]">{cursor.lastError}</div>
        )}
      </Section>

      <Section title={t("settings.pricing")} icon={<DollarSign size={15} />}>
        <Row
          label={t("settings.priceTable")}
          hint={t("settings.priceHint", {
            n: pricing?.modelCount ?? 0,
            source: pricing?.source ?? "unknown",
          })}
        >
          <GlassButton
            size="sm"
            disabled={refreshing}
            onClick={async () => {
              setRefreshing(true);
              try {
                const n = await api.refreshPricing();
                notify(t("settings.priceUpdated", { n }));
                qc.invalidateQueries();
              } catch (e) {
                notify(String(e), "error");
              } finally {
                setRefreshing(false);
              }
            }}
          >
            {refreshing ? t("settings.refreshing") : t("settings.refreshPricing")}
          </GlassButton>
        </Row>
        <div className="text-[0.6875rem] text-[rgb(var(--text-dim))]">
          {t("settings.priceNote")}
        </div>
      </Section>

      <Section title={t("settings.budget")} icon={<Wallet size={15} />}>
        <Row label={t("settings.budgetEnable")} hint={t("settings.budgetEnableHint")}>
          <GlassSwitch
            checked={settings.budgetAlertsEnabled ?? false}
            onChange={(budgetAlertsEnabled) => patch({ budgetAlertsEnabled })}
            label={t("settings.budgetEnable")}
          />
        </Row>
        <Row label={t("settings.dailyCostBudget")}>
          <input
            type="number"
            min={0}
            step={0.5}
            defaultValue={settings.dailyCostBudget ?? 10}
            spellCheck={false}
            disabled={!(settings.budgetAlertsEnabled ?? false)}
            className="no-drag w-[120px] rounded-lg border border-white/8 bg-black/15 px-2 py-1 text-[0.75rem] outline-none focus:border-[rgb(var(--accent)/0.6)] disabled:opacity-45"
            onBlur={(e) => {
              const v = Number(e.target.value);
              if (!Number.isFinite(v) || v < 0) return;
              if (v !== settings.dailyCostBudget) patch({ dailyCostBudget: v });
            }}
          />
        </Row>
        <Row label={t("settings.dailyTokenBudget")} hint={t("settings.dailyTokenBudgetHint")}>
          <input
            type="number"
            min={0}
            step={1000}
            defaultValue={settings.dailyTokenBudget ?? 0}
            spellCheck={false}
            disabled={!(settings.budgetAlertsEnabled ?? false)}
            className="no-drag w-[140px] rounded-lg border border-white/8 bg-black/15 px-2 py-1 text-[0.75rem] outline-none focus:border-[rgb(var(--accent)/0.6)] disabled:opacity-45"
            onBlur={(e) => {
              const v = Math.round(Number(e.target.value));
              if (!Number.isFinite(v) || v < 0) return;
              if (v !== settings.dailyTokenBudget) patch({ dailyTokenBudget: v });
            }}
          />
        </Row>
        <div
          className={`flex flex-col gap-2 ${!(settings.budgetAlertsEnabled ?? false) ? "opacity-45 pointer-events-none" : ""}`}
        >
          <div className="min-w-0">
            <div className="text-[0.8125rem] font-medium">{t("settings.budgetAgents")}</div>
            <div className="mt-0.5 text-[0.6875rem] text-[rgb(var(--text-dim))]">
              {t("settings.budgetAgentsHint")}
            </div>
          </div>
          <div className="flex flex-wrap gap-1.5">
            {(() => {
              const selected = settings.budgetAlertSources ?? [];
              const allOn = selected.length === 0;
              return (
                <>
                  <button
                    type="button"
                    className="chip transition-colors"
                    style={
                      allOn
                        ? {
                            background: "rgb(var(--accent) / 0.28)",
                            borderColor: "rgb(var(--accent) / 0.55)",
                            color: "rgb(var(--text))",
                          }
                        : undefined
                    }
                    onClick={() => patch({ budgetAlertSources: [] })}
                  >
                    {t("settings.budgetAgentsAll")}
                  </button>
                  {SOURCE_LIST.map((meta) => {
                    const on = selected.includes(meta.id);
                    return (
                      <button
                        key={meta.id}
                        type="button"
                        className="chip transition-colors"
                        style={
                          on
                            ? {
                                background: "rgb(var(--accent) / 0.28)",
                                borderColor: "rgb(var(--accent) / 0.55)",
                                color: "rgb(var(--text))",
                              }
                            : undefined
                        }
                        onClick={() => {
                          let next: string[];
                          if (allOn) {
                            // Leaving "all": start with only this agent.
                            next = [meta.id];
                          } else if (on) {
                            next = selected.filter((id) => id !== meta.id);
                          } else {
                            next = [...selected, meta.id];
                          }
                          // No chips left → back to all agents.
                          patch({ budgetAlertSources: next });
                        }}
                      >
                        {meta.label}
                      </button>
                    );
                  })}
                </>
              );
            })()}
          </div>
        </div>
      </Section>

      <Section title={t("settings.remote")} icon={<Server size={15} />}>
        <RemoteInstances />
      </Section>

      <Section title={t("settings.general")} icon={<Info size={15} />}>
        <Row label={t("settings.autostart")}>
          <GlassSwitch
            checked={settings.autostart}
            onChange={(autostart) => patch({ autostart })}
            label={t("settings.autostart")}
          />
        </Row>
        <Row label={t("settings.startMinimized")}>
          <GlassSwitch
            checked={settings.startMinimized}
            onChange={(startMinimized) => patch({ startMinimized })}
            label={t("settings.startMinimized")}
          />
        </Row>
        <Row label={t("settings.widgetTop")}>
          <GlassSwitch
            checked={settings.widgetAlwaysOnTop}
            onChange={(on) =>
              api.setWidgetAlwaysOnTop(on).then(() => qc.invalidateQueries({ queryKey: ["settings"] }))
            }
            label={t("settings.widgetTop")}
          />
        </Row>
        <Row label={t("settings.widgetCompact")} hint={t("settings.widgetCompactHint")}>
          <GlassSwitch
            checked={settings.widgetCompact ?? false}
            onChange={(widgetCompact) => patch({ widgetCompact })}
            label={t("settings.widgetCompact")}
          />
        </Row>
        <Row label={t("settings.widgetShortcut")} hint={t("settings.widgetShortcutHint")}>
          <input
            defaultValue={settings.widgetShortcut}
            spellCheck={false}
            className="no-drag w-[180px] rounded-lg border border-white/8 bg-black/15 px-2 py-1 text-[0.75rem] outline-none focus:border-[rgb(var(--accent)/0.6)]"
            onBlur={(e) => {
              const v = e.target.value.trim();
              if (v && v !== settings.widgetShortcut) patch({ widgetShortcut: v });
            }}
          />
        </Row>
        <Row label={t("settings.poll")} hint={t("settings.pollHint")}>
          <GlassSlider
            className="w-[180px]"
            value={settings.pollSecs}
            min={15}
            max={600}
            step={15}
            label={t("settings.poll")}
            format={(v) => `${v}s`}
            onChange={(v) => qc.setQueryData(["settings"], { ...settings, pollSecs: v })}
            onCommit={(pollSecs) => patch({ pollSecs })}
          />
        </Row>
        <Row label={t("settings.dataFolder")} hint={t("settings.dataFolderHint")}>
          <GlassButton size="sm" onClick={() => api.openDataDir()}>
            <FolderOpen size={13} />
            {t("common.open")}
          </GlassButton>
        </Row>
        <Row label={t("settings.quit")} hint={t("settings.quitHint")}>
          <GlassButton size="sm" tone="danger" onClick={() => api.quit()}>
            {t("common.quit")}
          </GlassButton>
        </Row>
      </Section>
    </div>
  );
}
