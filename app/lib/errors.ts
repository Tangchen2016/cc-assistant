export class UserError extends Error {
  status: number;

  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

export const privateHeaders = {
  "Cache-Control": "no-store, no-cache, must-revalidate",
  Pragma: "no-cache",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

export function errorResponse(error: unknown) {
  const known = error instanceof UserError;
  return Response.json(
    { error: known ? error.message : "服务暂时不可用，请稍后重试。" },
    { status: known ? error.status : 500, headers: privateHeaders },
  );
}

export async function readBoundedBody(request: Request, limit = 65_536) {
  const declared = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declared) && declared > limit) throw new UserError("配置过大。", 413);
  const reader = request.body?.getReader();
  if (!reader) throw new UserError("请求内容不能为空。");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new UserError("配置过大。", 413);
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; }
    catch { throw new UserError("请求必须为有效 JSON。"); }
  } finally { reader.releaseLock(); }
}
