/** Display formatting. Kept in one place so charts, tables and the widget agree. */

const NUM = new Intl.NumberFormat("en-US");

/** Compact token counts: 1.2K, 45.3M. Full precision below 1000. */
export function tokens(n: number): string {
  const v = Math.round(n);
  if (Math.abs(v) < 1000) return String(v);
  if (Math.abs(v) < 1_000_000) return `${(v / 1000).toFixed(v < 10_000 ? 2 : 1)}K`;
  if (Math.abs(v) < 1_000_000_000) return `${(v / 1_000_000).toFixed(v < 10_000_000 ? 2 : 1)}M`;
  return `${(v / 1_000_000_000).toFixed(2)}B`;
}

export function fullNumber(n: number): string {
  return NUM.format(Math.round(n));
}

/**
 * Costs run from fractions of a cent to hundreds of dollars, so the precision has to
 * follow the magnitude — `$0.00` for a real charge of $0.003 would read as free.
 */
export function usd(n: number | null | undefined): string {
  if (n == null) return "—";
  const v = Math.abs(n);
  if (v === 0) return "$0.00";
  if (v < 0.01) return `$${n.toFixed(4)}`;
  if (v < 1) return `$${n.toFixed(3)}`;
  if (v < 1000) return `$${n.toFixed(2)}`;
  return `$${NUM.format(Math.round(n))}`;
}

export function percent(n: number, digits = 0): string {
  return `${(n * 100).toFixed(digits)}%`;
}

/**
 * Caption warning that a cost total is incomplete, or `undefined` when it is not.
 *
 * A cost figure that silently omits events whose model has no price reads as authoritative
 * when it is not, so the count of omitted events is shown alongside it.
 */
export function unpricedNote(
  b?: { unpricedEvents: number; events: number } | null,
  localize?: (kind: "none" | "partial", count: number) => string,
): string | undefined {
  if (!b || b.unpricedEvents <= 0) return undefined;
  if (localize) {
    return localize(b.unpricedEvents >= b.events ? "none" : "partial", b.unpricedEvents);
  }
  if (b.unpricedEvents >= b.events) return "no price for these models";
  return `excludes ${fullNumber(b.unpricedEvents)} unpriced`;
}

/**
 * Share of a total. A long tail of small entries would all render as "0%", which reads as
 * "nothing" rather than "a little", so anything nonzero gets floored at "<1%".
 */
export function share(n: number): string {
  if (n <= 0) return "0%";
  if (n < 0.01) return "<1%";
  return `${Math.round(n * 100)}%`;
}

export function rate(n: number): string {
  if (n === 0) return "0";
  if (n < 10) return n.toFixed(1);
  return tokens(n);
}

const TIME = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });
const DATE = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
const DATETIME = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

export function time(ms: number): string {
  return TIME.format(new Date(ms));
}

export function date(ms: number): string {
  return DATE.format(new Date(ms));
}

export function dateTime(ms: number): string {
  return DATETIME.format(new Date(ms));
}

export function relative(ms: number | null | undefined): string {
  if (!ms) return "never";
  const diff = Date.now() - ms;
  if (diff < 5_000) return "just now";
  if (diff < 60_000) return `${Math.round(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.round(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.round(diff / 3_600_000)}h ago`;
  return `${Math.round(diff / 86_400_000)}d ago`;
}

/** Signed percentage change, or null when there is no baseline to compare against. */
export function delta(current: number, previous: number): number | null {
  if (previous === 0) return current === 0 ? 0 : null;
  return (current - previous) / previous;
}

/** Last path segment of a project directory, which is the part worth showing. */
export function projectLabel(path: string | null | undefined): string {
  if (!path) return "—";
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? path;
}
