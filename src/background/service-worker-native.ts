import { initializeStorageAccess } from '../lib/storage';
import { ActionFeedback } from './action-feedback';
import { CaptureSourceTracker, getActiveTab } from './capture-source';
import { NativeCaptureController } from './native-capture';

const sources = new CaptureSourceTracker();
const feedback = new ActionFeedback();
const nativeCapture = new NativeCaptureController(sources,
  (tabId, message) => feedback.show(tabId, message));

void initializeStorageAccess();

async function startSnip(tab?: chrome.tabs.Tab): Promise<void> {
  const source = tab ?? await getActiveTab();
  if (source) await nativeCapture.start(source);
}

// First-install onboarding is independent of capture and its badge-only failures.
chrome.runtime.onInstalled.addListener((details) => {
  if (details.reason === 'install') void chrome.runtime.openOptionsPage();
});

chrome.action.onClicked.addListener((tab) => { void startSnip(tab); });
chrome.commands.onCommand.addListener((command, tab) => {
  if (command === 'snip') void startSnip(tab);
});

chrome.tabs.onActivated.addListener(({ windowId }) => { sources.activated(windowId); });
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  // Hash/history changes keep the document and its unfinished selection alive.
  if (changeInfo.status !== 'loading') return;
  nativeCapture.invalidateSource(tabId);
  sources.navigated(tabId);
  feedback.clear(tabId);
});
chrome.tabs.onRemoved.addListener((tabId) => {
  nativeCapture.invalidateSource(tabId);
  sources.removed(tabId);
  feedback.clear(tabId);
});

// Settings owns its storage and companion check directly. There are no runtime
// message/port handlers for pages or former injected UI to invoke in this variant.
