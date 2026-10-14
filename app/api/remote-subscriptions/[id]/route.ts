import { errorResponse, privateHeaders, readBoundedBody } from "../../../lib/errors.ts";
import { MAX_REMOTE_BODY, validateRemoteCache } from "../../../lib/remote-cache.ts";
import { deleteRemoteCache, findRemoteCache, updateRemoteCache } from "../../../lib/remote-store.ts";
import { managementKey } from "../../../lib/store.ts";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, context: Context) {
  try {
    const { record, cache } = await findRemoteCache((await context.params).id, managementKey(request));
    return Response.json({ name: cache.profile.name, updatedAt: record.updatedAt, sourceFetchedAt: cache.sourceFetchedAt }, { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}

export async function PUT(request: Request, context: Context) {
  try {
    const { id } = await context.params;
    const key = managementKey(request);
    await findRemoteCache(id, key);
    const cache = validateRemoteCache(await readBoundedBody(request, MAX_REMOTE_BODY));
    return Response.json(await updateRemoteCache(id, key, cache), { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}

export async function DELETE(request: Request, context: Context) {
  try { return Response.json(await deleteRemoteCache((await context.params).id, managementKey(request)), { headers: privateHeaders }); }
  catch (error) { return errorResponse(error); }
}
