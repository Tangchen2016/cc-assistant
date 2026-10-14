import { errorResponse, privateHeaders } from "../../../lib/errors.ts";
import { transformSource } from "../../../lib/profile.ts";
import { fetchProfileSource } from "../../../../server/source-cache.ts";
import { findProfile } from "../../../lib/store.ts";
import { titleFilename } from "../../../lib/subscription-name.ts";

export async function GET(_request: Request, context: { params: Promise<{ id: string; key: string }> }) {
  try {
    const { id, key } = await context.params;
    const { profile } = await findProfile(id, key, true);
    const { config, userInfo, mode, fetchedAt } = await fetchProfileSource(id, profile);
    const { yaml, warnings } = transformSource(config, profile);
    const headers = new Headers({ ...privateHeaders, "Content-Type": "application/yaml; charset=utf-8", "Content-Disposition": titleFilename(profile.name), "X-Subscription-Warnings": String(warnings.length), "X-Subscription-Source": mode, "X-Source-Updated-At": fetchedAt });
    if (userInfo) headers.set("Subscription-Userinfo", userInfo);
    return new Response(yaml, { headers });
  } catch (error) { return errorResponse(error); }
}
