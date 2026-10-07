import { captureInitiatingViewport } from './capture-session';

/** Tracks document replacement and even a switch away and back during capture. */
export class CaptureSourceTracker {
  private documentVersionByTab = new Map<number, number>();
  private activationVersionByWindow = new Map<number, number>();

  documentVersion(tabId: number): number {
    return this.documentVersionByTab.get(tabId) ?? 0;
  }

  navigated(tabId: number): void {
    this.documentVersionByTab.set(tabId, this.documentVersion(tabId) + 1);
  }

  removed(tabId: number): void {
    this.documentVersionByTab.delete(tabId);
  }

  activated(windowId: number): void {
    this.activationVersionByWindow.set(windowId,
      (this.activationVersionByWindow.get(windowId) ?? 0) + 1);
  }

  capture(
    source: { tabId: number; windowId: number; documentVersion: number },
    isCurrent: () => boolean = () => true,
  ): Promise<string> {
    return captureInitiatingViewport({
      getActiveTab: async (windowId) => {
        const [tab] = await chrome.tabs.query({ active: true, windowId });
        return tab ?? null;
      },
      getActivationVersion: (windowId) => this.activationVersionByWindow.get(windowId) ?? 0,
      captureVisibleTab: (windowId) => chrome.tabs.captureVisibleTab(windowId, { format: 'png' }),
    }, {
      ...source,
      isCurrent: () => this.documentVersion(source.tabId) === source.documentVersion && isCurrent(),
    });
  }
}

export async function getActiveTab(): Promise<chrome.tabs.Tab | null> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab ?? null;
}
