"use client";

import SubscriptionWizard from "./components/SubscriptionWizard";

declare global {
  interface Window {
    __SUBSCRIPTION_DESKTOP__?: boolean;
    __flushSubscriptionDraft?: () => Promise<void>;
    webkit?: { messageHandlers?: { desktop?: { postMessage: (message: { action: "importClash"; url: string } | { action: "copy"; text: string } | { action: "quitReady"; ok: boolean; error?: string } | { action: "getLoginItem" | "openLoginSettings" } | { action: "setLoginItem"; enabled: boolean }) => void } } };
  }
}

export default function Home() { return <SubscriptionWizard />; }
