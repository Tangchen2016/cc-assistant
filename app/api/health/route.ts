import { getSqlite } from "../../../db/index.ts";
export const dynamic = "force-dynamic";
export function GET() {
  try { getSqlite().prepare("SELECT 1").get(); return Response.json({ status: "ok" }, { headers: { "Cache-Control": "no-store" } }); }
  catch { return Response.json({ status: "unavailable" }, { status: 503 }); }
}
