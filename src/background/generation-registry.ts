export interface ActiveGeneration {
  captureId: string;
  controller: AbortController;
  requestId: string;
}

export class GenerationRegistry {
  private static readonly MAX_SEEN_REQUESTS = 100;
  private readonly activeByTab = new Map<number, ActiveGeneration>();
  private readonly seenByDocument = new Map<string, Set<string>>();

  start(
    tabId: number,
    documentId: string | undefined,
    captureId: string,
    requestId: string,
  ): ActiveGeneration | null {
    const seen = this.getSeen(tabId, documentId);
    if (seen.has(requestId)) return null;

    if (seen.size >= GenerationRegistry.MAX_SEEN_REQUESTS) {
      const oldest = seen.values().next().value;
      if (oldest !== undefined) seen.delete(oldest);
    }
    seen.add(requestId);
    const previous = this.activeByTab.get(tabId);
    previous?.controller.abort();

    const generation = {
      captureId,
      controller: new AbortController(),
      requestId,
    };
    this.activeByTab.set(tabId, generation);
    return generation;
  }

  finish(tabId: number, requestId: string): void {
    if (this.activeByTab.get(tabId)?.requestId === requestId) {
      this.activeByTab.delete(tabId);
    }
  }

  cancel(tabId: number, requestId?: string): boolean {
    const current = this.activeByTab.get(tabId);
    if (!current || (requestId && current.requestId !== requestId)) return false;

    current.controller.abort();
    this.activeByTab.delete(tabId);
    return true;
  }

  cancelCapture(tabId: number, captureId: string): boolean {
    const current = this.activeByTab.get(tabId);
    if (!current || current.captureId !== captureId) return false;

    current.controller.abort();
    this.activeByTab.delete(tabId);
    return true;
  }

  clearTab(tabId: number): void {
    this.cancel(tabId);
    for (const key of this.seenByDocument.keys()) {
      if (key.startsWith(`${tabId}:`)) this.seenByDocument.delete(key);
    }
  }

  isCurrent(tabId: number, requestId: string): boolean {
    const current = this.activeByTab.get(tabId);
    return current?.requestId === requestId && !current.controller.signal.aborted;
  }

  private getSeen(tabId: number, documentId: string | undefined): Set<string> {
    const key = `${tabId}:${documentId ?? 'unknown'}`;
    let seen = this.seenByDocument.get(key);
    if (!seen) {
      seen = new Set();
      this.seenByDocument.set(key, seen);
    }
    return seen;
  }
}
