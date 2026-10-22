export type Group = { name: string; nodes: string[]; chain?: { entry: string }; fixedExit?: string };
export type Rule = { type: "DOMAIN-SUFFIX" | "DOMAIN" | "DOMAIN-KEYWORD"; value: string; group: string };
export type Profile = { name: string; sourceUrl: string; groups: Group[]; rules: Rule[]; client?: "shadowrocket" };
export type NodeSummary = { name: string; type: string };
export type Inspection = { nodes: NodeSummary[]; sourceGroups: string[]; fetchedAt: string; sourceName?: string };
export type RemoteSubscription = { id: string; manageKey: string; downloadKey: string; subscriptionUrl: string; updatedAt: number; lastError?: string };
export type SavedProfile = { id: string; manageKey: string; downloadKey: string; subscriptionPath: string; remote?: RemoteSubscription };
