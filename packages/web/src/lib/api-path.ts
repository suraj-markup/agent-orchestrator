/**
 * Prefixes an API path with `NEXT_PUBLIC_BASE_PATH` so fetches resolve through
 * reverse proxies that mount the app under a subpath (e.g. `/terminal/*`).
 *
 * Without the prefix, `fetch("/api/...")` from a page served at
 * `https://host/terminal/sessions/abc` resolves to `https://host/api/...`
 * — which hits the wrong upstream and surfaces as `TypeError: Failed to fetch`.
 * See issue #935 for the incident.
 *
 * Defaults to an empty string, so root-served deployments keep the existing
 * behavior.
 */
export function apiPath(path: string): string {
  const base = (process.env.NEXT_PUBLIC_BASE_PATH ?? "").replace(/\/+$/, "");
  if (!base) return path;
  return path.startsWith("/") ? `${base}${path}` : `${base}/${path}`;
}
