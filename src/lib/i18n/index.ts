export type { Locale, MessageKey } from "./messages";
export { detectLocale, translate } from "./messages";

import { useCallback, useEffect, useMemo } from "react";
import { useSettings } from "@/lib/hooks";
import { detectLocale, translate, type Locale, type MessageKey } from "./messages";

/** Resolve effective locale from settings (system → detect). */
export function resolveLocale(setting: string | undefined | null): Locale {
  if (setting === "zh" || setting === "en") return setting;
  return detectLocale();
}

export function useT() {
  const { data: settings } = useSettings();
  const locale = useMemo(() => resolveLocale(settings?.locale), [settings?.locale]);

  useEffect(() => {
    document.documentElement.lang = locale === "zh" ? "zh-CN" : "en";
  }, [locale]);

  const t = useCallback(
    (key: MessageKey, vars?: Record<string, string | number>) => translate(locale, key, vars),
    [locale],
  );

  return { t, locale };
}

export function statusKey(status: string): MessageKey {
  switch (status) {
    case "live":
      return "status.live";
    case "polling":
      return "status.polling";
    case "missing":
      return "status.missing";
    case "error":
      return "status.error";
    case "disabled":
      return "status.disabled";
    default:
      return "status.missing";
  }
}

export function rangeKey(range: string): MessageKey {
  switch (range) {
    case "today":
      return "range.today";
    case "7d":
      return "range.7d";
    case "30d":
      return "range.30d";
    case "90d":
      return "range.90d";
    case "all":
      return "range.all";
    default:
      return "range.7d";
  }
}
