import type { CaptureSourceTracker } from './capture-source';
import { NativeSessionController } from './native-session';

/** Native startup has no page UI, permission prompt, or tab-opening fallback. */
export class NativeCaptureController {
  private sessions: NativeSessionController;

  constructor(
    private sources: CaptureSourceTracker,
    private report: (tabId: number, message: string) => Promise<void>,
  ) {
    this.sessions = new NativeSessionController({
      capture: (source, isCurrent) => sources.capture(source, isCurrent),
      isSourceCurrent: (source) => sources.documentVersion(source.tabId) === source.documentVersion,
      report,
    });
  }

  async start(tab: chrome.tabs.Tab, documentVersion?: number): Promise<void> {
    if (typeof tab.id !== 'number') return;
    const sourceVersion = documentVersion ?? this.sources.documentVersion(tab.id);
    if (tab.url?.startsWith('file:')
      && !(await chrome.extension.isAllowedFileSchemeAccess().catch(() => false))) {
      await this.report(tab.id,
        'Enable “Allow access to file URLs” for SnapScreen, then invoke it again.');
      return;
    }
    await this.sessions.start({ tabId: tab.id, windowId: tab.windowId, documentVersion: sourceVersion });
  }

  invalidateSource(tabId: number): void {
    this.sessions.invalidateSource(tabId);
  }
}
