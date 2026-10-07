const DEFAULT_ACTION_TITLE = 'SnapScreen – Snip and analyze';

/** Browser-owned feedback shared by both extension variants. */
export class ActionFeedback {
  private clearTimers = new Map<number, ReturnType<typeof setTimeout>>();
  private versionByTab = new Map<number, number>();
  private nextVersion = 0;

  async show(tabId: number, message: string): Promise<void> {
    const version = ++this.nextVersion;
    this.versionByTab.set(tabId, version);
    const previousTimer = this.clearTimers.get(tabId);
    if (previousTimer !== undefined) {
      clearTimeout(previousTimer);
      this.clearTimers.delete(tabId);
    }

    const results = await Promise.allSettled([
      chrome.action.setBadgeText({ tabId, text: '!' }),
      chrome.action.setTitle({ tabId, title: message }),
    ]);
    if (this.versionByTab.get(tabId) !== version) return;
    if (results.every((result) => result.status === 'rejected')) {
      this.versionByTab.delete(tabId);
      return;
    }

    const timer = setTimeout(() => {
      if (this.clearTimers.get(tabId) !== timer || this.versionByTab.get(tabId) !== version) return;
      this.clearTimers.delete(tabId);
      this.versionByTab.delete(tabId);
      void this.reset(tabId);
    }, 5000);
    this.clearTimers.set(tabId, timer);
  }

  clear(tabId: number): void {
    const hadFeedback = this.versionByTab.delete(tabId);
    const timer = this.clearTimers.get(tabId);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.clearTimers.delete(tabId);
    }
    if (hadFeedback || timer !== undefined) void this.reset(tabId);
  }

  private async reset(tabId: number): Promise<void> {
    await Promise.allSettled([
      chrome.action.setBadgeText({ tabId, text: '' }),
      chrome.action.setTitle({ tabId, title: DEFAULT_ACTION_TITLE }),
    ]);
  }
}
