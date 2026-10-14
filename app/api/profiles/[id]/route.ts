import { saveSourceCache } from "../../../../server/source-cache.ts";
import { and, eq } from "drizzle-orm";
import { getSqlite } from "../../../../db/index.ts";
import { getDb } from "../../../../db/index.ts";
import { profiles } from "../../../../db/schema.ts";
import { errorResponse, privateHeaders, readBoundedBody } from "../../../lib/errors.ts";
import { validateProfile, transformSource } from "../../../lib/profile.ts";
import { fetchSource } from "../../../lib/source.ts";
import { findProfile, managementKey } from "../../../lib/store.ts";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, context: Context) {
  try {
    const { profile } = await findProfile((await context.params).id, managementKey(request));
    return Response.json({ profile }, { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}

export async function PUT(request: Request, context: Context) {
  try {
    const { record } = await findProfile((await context.params).id, managementKey(request));
    const profile = validateProfile(await readBoundedBody(request));
    const live = await fetchSource(profile.sourceUrl);
    const { config } = live;
    transformSource(config, profile);
    await getDb().update(profiles).set({ profileJson: JSON.stringify(profile), updatedAt: Date.now() }).where(and(eq(profiles.id, record.id), eq(profiles.editHash, record.editHash)));
    await saveSourceCache(record.id, profile, live);
    return Response.json({ saved: true }, { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}

export async function DELETE(request: Request, context: Context) {
  try {
    const { record } = await findProfile((await context.params).id, managementKey(request));
    await getDb().delete(profiles).where(and(eq(profiles.id, record.id), eq(profiles.editHash, record.editHash)));
    getSqlite().prepare("DELETE FROM source_caches WHERE id=?").run(record.id);
    return Response.json({ deleted: true }, { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}
