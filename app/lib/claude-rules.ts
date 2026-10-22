// Domains that keep Claude, and the third-party services its pages load, on the dedicated exit.
// From a community Surge list (2026-04-10) minus IP rules (domain rules only here), the over-broad
// DOMAIN-KEYWORD,datadoghq and bulk storage.googleapis.com downloads.
// Keep in sync with desktop/native/ClaudeRules.swift.
export const claudeOwnedRoots = ["claude.ai", "anthropic.com", "claude.com", "clau.de", "claudeusercontent.com", "claudemcpclient.com"];
const keywords = ["claude", "anthropic"];
export const recommendedClaudeRules: { type: "DOMAIN" | "DOMAIN-SUFFIX" | "DOMAIN-KEYWORD"; value: string }[] = [
  ...claudeOwnedRoots.map(value => ({ type: "DOMAIN-SUFFIX" as const, value })),
  ...["servd-anthropic-website.b-cdn.net", "anthropic.com.cdn.cloudflare.net", "cdn.usefathom.com", "anthropic.auth0.com", "anthropic-com.ghost.io", "browser-intake-us5-datadoghq.com"].map(value => ({ type: "DOMAIN" as const, value })),
  ...["intercom.io", "intercomcdn.com", "statsigapi.net", "sentry.io"].map(value => ({ type: "DOMAIN-SUFFIX" as const, value })),
  { type: "DOMAIN-KEYWORD", value: "sift" },
  ...["t0.gstatic.com", "t1.gstatic.com", "t2.gstatic.com", "t3.gstatic.com"].map(value => ({ type: "DOMAIN" as const, value })),
  ...keywords.map(value => ({ type: "DOMAIN-KEYWORD" as const, value })),
];

/** Allowed on Shadowrocket lines: an Anthropic-owned domain or an exact recommended domain entry; never a keyword,
 *  so a module delivered to a phone can never grow beyond listed domains. */
export function allowedClaudeRule(rule: { type: string; value: string }) {
  if (rule.type === "DOMAIN-KEYWORD") return false;
  const value = rule.value.toLowerCase();
  return recommendedClaudeRules.some(entry => entry.type === rule.type && entry.value === value) || claudeOwnedRoots.some(root => value === root || value.endsWith(`.${root}`));
}
