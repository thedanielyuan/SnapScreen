export class CaptureSupersededError extends Error {
  constructor() {
    super('Capture was superseded by a newer selection.');
    this.name = 'CaptureSupersededError';
  }
}

export class ActiveTabChangedError extends Error {
  constructor() {
    super('The active tab changed during capture. Switch back and try again.');
    this.name = 'ActiveTabChangedError';
  }
}

export interface CaptureTabDependencies {
  getActiveTab: (windowId: number) => Promise<{ id?: number } | null>;
  getActivationVersion: (windowId: number) => number;
  captureVisibleTab: (windowId: number) => Promise<string>;
}

export interface CaptureViewportInput {
  tabId: number;
  windowId: number;
  isCurrent: () => boolean;
}

async function assertInitiatingTabIsActive(
  deps: Pick<CaptureTabDependencies, 'getActiveTab'>,
  tabId: number,
  windowId: number,
): Promise<void> {
  const activeTab = await deps.getActiveTab(windowId);
  if (activeTab?.id !== tabId) throw new ActiveTabChangedError();
}

function assertCurrent(isCurrent: () => boolean): void {
  if (!isCurrent()) throw new CaptureSupersededError();
}

export async function captureInitiatingViewport(
  deps: CaptureTabDependencies,
  input: CaptureViewportInput,
): Promise<string> {
  assertCurrent(input.isCurrent);
  await assertInitiatingTabIsActive(deps, input.tabId, input.windowId);
  assertCurrent(input.isCurrent);
  const activationVersion = deps.getActivationVersion(input.windowId);

  const dataUrl = await deps.captureVisibleTab(input.windowId);
  assertCurrent(input.isCurrent);
  if (deps.getActivationVersion(input.windowId) !== activationVersion) {
    throw new ActiveTabChangedError();
  }
  await assertInitiatingTabIsActive(deps, input.tabId, input.windowId);
  assertCurrent(input.isCurrent);

  return dataUrl;
}
