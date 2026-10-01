// Chrome may stop an extension service worker that goes 30 seconds without an
// extension event or API call, even mid-fetch. With adaptive thinking, an
// answer stream can stay silent that long before its first text delta, so a
// trivial API call resets the idle timer until the operation settles.
export const KEEPALIVE_INTERVAL_MS = 25_000;

export async function keepAliveUntilSettled<T>(operation: Promise<T>): Promise<T> {
  const timer = setInterval(() => {
    void chrome.runtime.getPlatformInfo().catch(() => undefined);
  }, KEEPALIVE_INTERVAL_MS);
  try {
    return await operation;
  } finally {
    clearInterval(timer);
  }
}
