import { UserError, errorResponse } from "../../../lib/errors.ts";
import { remoteDownload } from "../../../lib/remote-cache.ts";
import { findRemoteCache } from "../../../lib/remote-store.ts";

export async function GET(_request: Request, context: { params: Promise<{ id: string; key: string }> }) {
  try {
    const { id, key } = await context.params;
    const value = new URL(_request.url).searchParams.get("format") ?? undefined;
    if (value !== undefined && value !== "clash" && value !== "shadowrocket-nodes" && value !== "shadowrocket-module") throw new UserError("导出格式无效。", 400);
    return await remoteDownload(id, key, async (id, key) => (await findRemoteCache(id, key, true)).cache, { format: value });
  } catch (error) { return errorResponse(error); }
}
