/**
 * Navigation dock. The lit pill behind the active item is one shared element animated
 * with `layoutId`, so it glides between entries the way a macOS sidebar selection does.
 */
import { motion } from "framer-motion";
import { Activity, Cpu, GitCompare, LayoutDashboard, Settings as SettingsIcon } from "lucide-react";

import { SOURCE_LIST, STATUS_CLASS, rollupSourceStatus } from "../../lib/sources";
import { useSourceHealth } from "../../lib/hooks";
import { useT, statusKey } from "../../lib/i18n";
import type { Route } from "../../routes";
import type { MessageKey } from "../../lib/i18n";

const NAV: { route: Route; labelKey: MessageKey; icon: React.ReactNode }[] = [
  { route: "dashboard", labelKey: "nav.dashboard", icon: <LayoutDashboard size={16} /> },
  { route: "usage", labelKey: "nav.usage", icon: <Activity size={16} /> },
  { route: "compare", labelKey: "nav.compare", icon: <GitCompare size={16} /> },
  { route: "agents", labelKey: "nav.agents", icon: <Cpu size={16} /> },
  { route: "settings", labelKey: "nav.settings", icon: <SettingsIcon size={16} /> },
];

interface Props {
  route: Route;
  onNavigate: (route: Route, source?: string) => void;
  activeSource?: string;
}

export function Sidebar({ route, onNavigate, activeSource }: Props) {
  const { t } = useT();
  const { data: health } = useSourceHealth();

  const statusOf = (id: string) =>
    rollupSourceStatus(health?.filter((h) => h.source === id));

  return (
    <nav className="glass flex w-[212px] shrink-0 flex-col gap-1 p-2.5">
      {NAV.map((item) => {
        const active = route === item.route;
        return (
          <button
            key={item.route}
            type="button"
            data-active={active}
            className="dock-item no-drag"
            onClick={() => onNavigate(item.route)}
          >
            {active && (
              <motion.span
                layoutId="dock-highlight"
                className="dock-highlight"
                transition={{ type: "spring", stiffness: 480, damping: 40, mass: 0.6 }}
              />
            )}
            <span className="relative z-[1] flex items-center gap-2.5">
              {item.icon}
              {t(item.labelKey)}
            </span>
          </button>
        );
      })}

      <div className="mx-2 my-2 h-px bg-white/8" />

      <div className="px-2 pb-1 text-[0.625rem] font-semibold uppercase tracking-[0.08em] text-[rgb(var(--text-faint))]">
        {t("nav.sources")}
      </div>

      <div className="scroll-area flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto pb-1">
        {SOURCE_LIST.map((s) => {
          const status = statusOf(s.id);
          const active = route === "agents" && activeSource === s.id;
          return (
            <button
              key={s.id}
              type="button"
              data-active={active}
              className="dock-item no-drag py-1.5 text-[0.78rem]"
              onClick={() => onNavigate("agents", s.id)}
            >
              {active && (
                <motion.span
                  layoutId="dock-source-highlight"
                  className="dock-highlight"
                  transition={{ type: "spring", stiffness: 480, damping: 40, mass: 0.6 }}
                />
              )}
              <span className="relative z-[1] flex w-full items-center gap-2.5">
                <span
                  className="h-2 w-2 shrink-0 rounded-full"
                  style={{ background: `rgb(var(${s.colorVar}))` }}
                />
                <span className="truncate">{s.label}</span>
                <span
                  className={`status-dot ml-auto ${STATUS_CLASS[status]}`}
                  title={t(statusKey(status))}
                  aria-label={t(statusKey(status))}
                />
              </span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}
