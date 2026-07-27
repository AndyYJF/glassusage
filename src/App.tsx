import { lazy, Suspense, useCallback, useEffect, useState } from "react";
import { motion } from "framer-motion";
import { listen } from "@tauri-apps/api/event";

import { LensFilterDefs } from "./components/glass/LensFilterDefs";
import { Onboarding } from "./components/Onboarding";
import { Sidebar } from "./components/layout/Sidebar";
import { TitleBar } from "./components/layout/TitleBar";
import { Toast } from "./components/layout/Toast";
import { Dashboard } from "./pages/Dashboard";
import { useBackendEvents, useSettings } from "./lib/hooks";
import { isRoute, type Route } from "./routes";

const UsagePage = lazy(() =>
  import("./pages/Usage").then((module) => ({ default: module.UsagePage })),
);
const ComparePage = lazy(() =>
  import("./pages/Compare").then((module) => ({ default: module.ComparePage })),
);
const AgentDetail = lazy(() =>
  import("./pages/AgentDetail").then((module) => ({ default: module.AgentDetail })),
);
const SettingsPage = lazy(() =>
  import("./pages/Settings").then((module) => ({ default: module.SettingsPage })),
);

/** Applies theme and background preferences to <html>, where the CSS variables live. */
function useAppearance() {
  const { data: settings } = useSettings();

  useEffect(() => {
    if (!settings) return;
    const root = document.documentElement;

    const apply = () => {
      const dark =
        settings.theme === "dark" ||
        (settings.theme === "system" &&
          window.matchMedia("(prefers-color-scheme: dark)").matches);
      root.classList.toggle("dark", dark);
      root.classList.toggle("light", !dark);
    };
    apply();

    // Only "system" needs to react to the OS switching themes at runtime.
    if (settings.theme !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    mq.addEventListener("change", apply);
    return () => mq.removeEventListener("change", apply);
  }, [settings]);

  useEffect(() => {
    if (!settings) return;
    // At zero refraction the SVG filters still cost a rasterization pass, so swap
    // them for plain blur. Acrylic/Mica leave this off — their CSS path drops
    // backdrop-filter entirely so the native vibrancy shows through the cards.
    document.documentElement.classList.toggle("lens-off", settings.refraction <= 0.01);
  }, [settings?.refraction]);

  useEffect(() => {
    if (!settings) return;
    // Must land on <html> *before* the native backdrop is cleared, otherwise WebView2
    // paints a fully transparent frame and every glass surface looks blank.
    document.documentElement.dataset.material = settings.material;
  }, [settings?.material]);

  return settings;
}

export default function App() {
  const [route, setRoute] = useState<Route>("dashboard");
  const [activeSource, setActiveSource] = useState<string>("claude");
  const settings = useAppearance();

  useBackendEvents();

  const navigate = useCallback((next: Route, source?: string) => {
    setRoute(next);
    if (source) setActiveSource(source);
  }, []);

  // The tray menu and the mini card both ask the main window to open on a given page.
  useEffect(() => {
    const p = listen<string>("navigate", (e) => {
      const [page, source] = e.payload.split(":");
      if (isRoute(page)) navigate(page, source);
    });
    return () => {
      p.then((fn) => fn()).catch(() => {});
    };
  }, [navigate]);

  // The native acrylic backdrop already supplies motion behind the glass; the CSS mesh
  // gradient is only needed when that backdrop is off.
  const showMesh = settings ? settings.animatedBackground && settings.material === "css" : false;

  return (
    <div className="flex h-full flex-col">
      <LensFilterDefs strength={settings?.refraction ?? 0.62} />
      {showMesh && <div className="animated-bg" aria-hidden />}

      <TitleBar />

      <div className="flex min-h-0 flex-1 gap-3 px-3 pb-3">
        <Sidebar route={route} onNavigate={navigate} activeSource={activeSource} />

        <main className="relative min-w-0 flex-1 overflow-hidden">
          {/* Plain keyed remount — no AnimatePresence. Presence was stacking the previous
              Settings page on top of the next route after a material switch, so the sidebar
              highlight moved but the right pane stayed on Settings. */}
          <motion.div
            key={route === "agents" ? `agents:${activeSource}` : route}
            className="h-full"
            initial={{ opacity: 0.92, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.14, ease: [0.22, 1, 0.36, 1] }}
          >
            <Suspense
              fallback={
                <div className="grid h-full place-items-center text-sm text-[rgb(var(--text-dim))]">
                  Loading…
                </div>
              }
            >
              {route === "dashboard" && <Dashboard onOpenAgent={(s) => navigate("agents", s)} />}
              {route === "usage" && <UsagePage />}
              {route === "compare" && <ComparePage />}
              {route === "agents" && <AgentDetail source={activeSource} />}
              {route === "settings" && <SettingsPage />}
            </Suspense>
          </motion.div>
        </main>
      </div>

      <Toast />
      {settings && !settings.firstRunDone && (
        <Onboarding onDone={() => {/* settings query invalidated inside */}} />
      )}
    </div>
  );
}
