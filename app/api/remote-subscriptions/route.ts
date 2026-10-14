import { errorResponse, privateHeaders, readBoundedBody } from "../../lib/errors.ts";
import { MAX_REMOTE_BODY, validateRemoteCache } from "../../lib/remote-cache.ts";
import { createRemoteCache } from "../../lib/remote-store.ts";

export async function POST(request: Request) {
  try {
    const cache = validateRemoteCache(await readBoundedBody(request, MAX_REMOTE_BODY));
    return Response.json(await createRemoteCache(cache), { status: 201, headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}
