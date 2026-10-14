import { saveSourceCache } from "../../../server/source-cache.ts";
import { getDb } from "../../../db/index.ts";
import { profiles } from "../../../db/schema.ts";
import { errorResponse, privateHeaders, readBoundedBody } from "../../lib/errors.ts";
import { validateProfile, transformSource } from "../../lib/profile.ts";
import { fetchSource } from "../../lib/source.ts";
import { hashKey, randomKey } from "../../lib/store.ts";
import { subscriptionPath } from "../../lib/subscription-name.ts";

export async function POST(request: Request) {
  try {
    const profile = validateProfile(await readBoundedBody(request));
    const live = await fetchSource(profile.sourceUrl);
    const { config } = live;
    transformSource(config, profile);
    const id = randomKey().slice(0, 32);
    const manageKey = randomKey();
    const downloadKey = randomKey();
    const now = Date.now();
    await getDb().insert(profiles).values({ id, editHash: await hashKey(manageKey), downloadHash: await hashKey(downloadKey), profileJson: JSON.stringify(profile), createdAt: now, updatedAt: now });
    await saveSourceCache(id, profile, live);
    return Response.json({ id, manageKey, downloadKey, subscriptionPath: subscriptionPath(profile.name, id, downloadKey) }, { status: 201, headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}
