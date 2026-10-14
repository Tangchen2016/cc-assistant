import { errorResponse } from "../../../lib/errors.ts";
import { remoteDownload } from "../../../lib/remote-cache.ts";
import { findRemoteCache } from "../../../lib/remote-store.ts";

export async function GET(_request: Request, context: { params: Promise<{ id: string; key: string }> }) {
  try {
    const { id, key } = await context.params;
    return await remoteDownload(id, key, async (id, key) => (await findRemoteCache(id, key, true)).cache);
  } catch (error) { return errorResponse(error); }
}
