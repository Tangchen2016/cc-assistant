import { createConnection } from "node:net";

function connect(target: { hostname: string; port: number }) {
  const socket = createConnection({ host: target.hostname, port: target.port });
  return { opened: new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); }), close: () => { socket.destroy(); } };
}
import { errorResponse, privateHeaders, readBoundedBody } from "../../lib/errors.ts";
import { pingNodes, validatePingRequest } from "../../lib/ping.ts";
import { fetchSource } from "../../lib/source.ts";

export async function POST(request: Request) {
  try {
    const { sourceUrl, nodes } = validatePingRequest(await readBoundedBody(request));
    const { config } = await fetchSource(sourceUrl);
    const result = await pingNodes(config, nodes, { connect });
    return Response.json(result, { headers: privateHeaders });
  } catch (error) { return errorResponse(error); }
}
