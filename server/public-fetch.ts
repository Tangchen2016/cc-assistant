import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { isPublicAddress, validateSourceUrl } from "../app/lib/source-validation.ts";

// Each redirect is separately checked by fetchSource. Pin the validated DNS
// answer into the socket lookup so DNS rebinding cannot reach private networks.
export const publicFetch: typeof fetch = async (input, init = {}) => {
  const url = validateSourceUrl(String(input));
  const host = url.hostname.replace(/^\[|\]$/g, "");
  const answers = isIP(host) ? [{ address: host, family: isIP(host) }] : await lookup(host, { all: true });
  if (!answers.length || answers.some(({ address }) => !isPublicAddress(address))) throw new Error("Non-public source address");
  init.signal?.throwIfAborted();
  const pinned = answers.find(({ family }) => family === 4) ?? answers[0];
  const headers = Object.fromEntries(new Headers(init.headers).entries());
  delete headers.cookie; delete headers.authorization; delete headers['proxy-authorization'];
  return new Promise<Response>((accept, reject) => {
    const transport = url.protocol === "https:" ? httpsRequest : httpRequest;
    const req = transport(url, {
      method: "GET", headers, signal: init.signal ?? undefined,
      lookup: (_host, options, callback) => {
        if (options.all) callback(null, [pinned]);
        else callback(null, pinned.address, pinned.family);
      },
    }, res => {
      const status = res.statusCode ?? 502;
      const responseHeaders = new Headers();
      for (const [key, value] of Object.entries(res.headers)) if (value) responseHeaders.set(key, Array.isArray(value) ? value.join(", ") : value);
      // The subscription requests omit Accept-Encoding, so bytes remain YAML.
      const chunks: Buffer[] = []; let bytes = 0;
      res.on("data", (chunk: Buffer) => {
        bytes += chunk.length;
        if (bytes > 2 * 1024 * 1024) req.destroy(new Error("Source exceeds limit"));
        else chunks.push(chunk);
      });
      res.on("error", reject);
      res.on("end", () => accept(new Response([204, 205, 304].includes(status) ? null : Buffer.concat(chunks), { status, headers: responseHeaders })));
    });
    req.on("error", reject);
    req.setTimeout(15_000, () => req.destroy(new Error("Source timeout")));
    req.end();
  });
};
