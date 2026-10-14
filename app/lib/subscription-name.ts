function cleanName(value: string, limit = 80) {
  const normalized = new TextDecoder().decode(new TextEncoder().encode(value));
  const name = normalized.replace(/[\x00-\x1f\x7f-\x9f\u2028\u2029/\\]/g, "").trim().replace(/\.ya?ml$/i, "").trim().slice(0, limit).replace(/[\uD800-\uDBFF]$/, "");
  return name && name !== "." && name !== ".." ? name : undefined;
}

export function sourceName(headers: Headers, url: string): string | undefined {
  const disposition = headers.get("Content-Disposition") ?? "";
  if (disposition.length <= 4096) {
    const encoded = /(?:^|;)\s*filename\*\s*=\s*"?([^";]+)"?/i.exec(disposition)?.[1]?.trim();
    const utf8 = encoded && /^UTF-8'[^']*'(.*)$/i.exec(encoded)?.[1];
    if (utf8) {
      try { const name = cleanName(decodeURIComponent(utf8)); if (name) return name; }
      catch { /* Invalid encoding falls back to other naming metadata. */ }
    }
    const quoted = /(?:^|;)\s*filename\s*=\s*"((?:\\.|[^"])*)"/i.exec(disposition)?.[1];
    const plain = quoted ?? /(?:^|;)\s*filename\s*=\s*([^;"\s]+)/i.exec(disposition)?.[1];
    if (plain) { const name = cleanName(plain.replace(/\\(.)/g, "$1")); if (name) return name; }
  }
  const title = headers.get("Profile-Title");
  if (title && title.length <= 4096) {
    if (/^base64:/i.test(title)) {
      try {
        const raw = atob(title.slice(7));
        const decoded = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(raw, (character) => character.charCodeAt(0)));
        const name = cleanName(decoded);
        if (name) return name;
      } catch { /* Invalid Base64 or UTF-8 is not a usable title. */ }
    } else {
      const name = cleanName(title);
      if (name) return name;
    }
  }
  try {
    const basename = new URL(url).pathname.split("/").at(-1) ?? "";
    const decoded = decodeURIComponent(basename);
    if (/\.ya?ml$/i.test(decoded)) return cleanName(decoded);
  } catch { /* Never derive a title from malformed URLs or opaque tokens. */ }
  return undefined;
}

function filename(name: string) { return `${cleanName(name, 100) ?? "增强-订阅"}.yaml`; }

export function titleFilename(name: string) {
  const encoded = encodeURIComponent(filename(name)).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
  return `attachment; filename="enhanced.yaml"; filename*=UTF-8''${encoded}`;
}

export function subscriptionPath(name: string, id: string, key: string) {
  return `/sub/${id}/${key}/${encodeURIComponent(filename(name))}`;
}
