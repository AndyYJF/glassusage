export const ROUTES = ["dashboard", "usage", "compare", "agents", "settings"] as const;

export type Route = (typeof ROUTES)[number];

export function isRoute(value: string): value is Route {
  return (ROUTES as readonly string[]).includes(value);
}
