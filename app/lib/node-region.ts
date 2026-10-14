/** Node labels are hints; they do not verify the actual egress country. */
export function isUSNode(name: string): boolean {
  const normalized = name.normalize("NFKC");
  if (normalized.includes("美国") || normalized.includes("🇺🇸")) return true;
  return /(?:^|[^\p{L}\p{N}])(?:USA|US|UNITED[\s_-]*STATES)(?=$|[^\p{L}\p{N}])/iu.test(normalized)
    || /(?:^|[^\p{L}\p{N}])US\d+(?=$|[^\p{L}\p{N}])/iu.test(normalized);
}

export function prioritizeNodes<T extends { name: string }>(nodes: T[]): T[] {
  const us: T[] = [], others: T[] = [];
  for (const node of nodes) (isUSNode(node.name) ? us : others).push(node);
  return [...us, ...others];
}
