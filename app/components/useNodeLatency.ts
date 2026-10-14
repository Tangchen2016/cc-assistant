"use client";

import { useEffect, useRef, useState } from "react";

export type NodeLatency = { name: string; status: "ok" | "timeout" | "unavailable" | "blocked"; latencyMs?: number; error?: string; measuredAt?: string };
export type PingResponse = { results: NodeLatency[]; measuredAt: string };
export type LatencyState = { results: Record<string, NodeLatency>; pending: string[]; progress: { completed: number; total: number } | null; error: string; check: (names: string[]) => Promise<void>; reset: () => void };

export default function useNodeLatency(request: (names: string[], signal: AbortSignal) => Promise<PingResponse>): LatencyState {
  const [results, setResults] = useState<Record<string, NodeLatency>>({});
  const [pending, setPending] = useState<string[]>([]);
  const [progress, setProgress] = useState<{ completed: number; total: number } | null>(null);
  const [error, setError] = useState("");
  const generation = useRef(0);
  const active = useRef(false);
  const controller = useRef<AbortController | null>(null);

  useEffect(() => () => { generation.current++; controller.current?.abort(); }, []);

  function reset() {
    generation.current++; controller.current?.abort(); controller.current = null; active.current = false;
    setResults({}); setPending([]); setProgress(null); setError("");
  }

  async function check(names: string[]) {
    if (active.current || !names.length) return;
    const unique = [...new Set(names)], version = generation.current;
    active.current = true; setError(""); setProgress({ completed: 0, total: unique.length });
    try {
      for (let offset = 0; offset < unique.length; offset += 10) {
        const batch = unique.slice(offset, offset + 10);
        const abort = new AbortController(); controller.current = abort; setPending(batch);
        try {
          const response = await request(batch, abort.signal);
          if (version !== generation.current || abort.signal.aborted) return;
          const next = Object.fromEntries(batch.map((name): [string, NodeLatency] => {
            const result = response.results.find((item) => item.name === name);
            return [name, result ? { ...result, measuredAt: response.measuredAt } : { name, status: "unavailable", error: "检测未返回结果" }];
          }));
          setResults((previous) => ({ ...previous, ...next }));
        } catch (err) {
          if (version !== generation.current || abort.signal.aborted) return;
          setError(err instanceof Error ? err.message : "检测请求失败，请重试");
          setResults((previous) => ({ ...previous, ...Object.fromEntries(batch.map((name) => [name, { name, status: "unavailable", error: "检测请求失败，请重试" } satisfies NodeLatency])) }));
          break;
        }
        setProgress({ completed: Math.min(offset + 10, unique.length), total: unique.length });
      }
    } finally {
      if (version === generation.current) { active.current = false; controller.current = null; setPending([]); setProgress(null); }
    }
  }
  return { results, pending, progress, error, check, reset };
}
