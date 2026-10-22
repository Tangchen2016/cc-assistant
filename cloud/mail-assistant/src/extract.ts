export function mailbox(value: unknown, domain: string): string | null {
  if (typeof value !== "string" || value.length > 254) return null;
  const normalized = value.trim().toLowerCase();
  const parts = normalized.split("@");
  return parts.length === 2 && parts[1] === domain && /^[a-z0-9._+-]{1,64}$/.test(parts[0]) ? normalized : null;
}

// Multiple different candidates are deliberately left for the person to read in iCloud.
export function extractCode(subject: string, text: string): string | null {
  const content = `${subject}\n${text}`;
  const found = new Set<string>();
  const pattern = /(?:verification\s+code|security\s+code|login\s+code|sign[ -]?in\s+code|验证码|驗證碼|one[ -]?time\s+(?:code|password))[^\d\n]{0,60}(\d{4,8})(?!\d)/gi;
  for (const match of content.matchAll(pattern)) found.add(match[1]);
  const before = /\b(\d{4,8})\b[^\d\n]{0,40}(?:is your|为您的|是你的)[^\n]{0,30}(?:code|验证码|驗證碼)/gi;
  for (const match of content.matchAll(before)) found.add(match[1]);
  return found.size === 1 ? [...found][0] : null;
}

export function allowedSender(address: string): boolean {
  const domain = address.toLowerCase().split("@")[1];
  return !!domain && ["anthropic.com", "claude.ai", "claude.com"].some(d => domain === d || domain.endsWith(`.${d}`));
}

// Only the observed, direct Claude login endpoint is accepted; never follow tracking redirects.
export function extractLoginURL(text: string, html: string, recipient: string): string | null {
  const found = new Set<string>();
  for (const match of `${text}\n${html}`.matchAll(/https:\/\/[^\s"'<>]+/gi)) {
    try {
      const url = new URL(match[0].replace(/&amp;/g, "&"));
      if (url.origin !== "https://claude.ai" || url.pathname !== "/magic-link" || url.search || url.username || url.password) continue;
      const parts = url.hash.slice(1).split(":");
      if (parts.length !== 2 || !/^[A-Za-z0-9_-]{16,512}$/.test(parts[0]) || !/^[A-Za-z0-9+/=_-]{4,512}$/.test(parts[1])) continue;
      const address = atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")).trim().toLowerCase();
      if (address === recipient.toLowerCase()) found.add(url.href);
    } catch { /* Unrecognized links remain in the forwarded original email. */ }
  }
  return found.size === 1 ? [...found][0] : null;
}
