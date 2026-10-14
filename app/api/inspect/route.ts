import { errorResponse, privateHeaders, readBoundedBody, UserError } from "../../lib/errors.ts";
import { fetchSource, validateSourceUrl } from "../../lib/source.ts";

export async function POST(request: Request) {
  try {
    const input = await readBoundedBody(request);
    if (!input || typeof input !== "object" || Array.isArray(input)) throw new UserError("请输入源订阅地址。");
    const url = validateSourceUrl((input as { sourceUrl?: unknown }).sourceUrl);
    const { config, fetchedAt, sourceName } = await fetchSource(url.href);
    const sourceGroups = (config["proxy-groups"] ?? []) as Array<{ name: string }>;
    return Response.json({ nodes: config.proxies.map(({ name, type }) => ({ name, type })), sourceGroups: sourceGroups.map(({ name }) => name), fetchedAt, sourceName }, { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}
