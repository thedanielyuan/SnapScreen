import { describe, expect, it, vi } from 'vitest';
import {
  ActiveTabChangedError,
  CaptureSupersededError,
  captureInitiatingViewport,
  type CaptureTabDependencies,
} from './capture-session';

const input = {
  tabId: 7,
  windowId: 2,
  isCurrent: () => true,
};

function makeDeps(): CaptureTabDependencies {
  return {
    getActiveTab: vi.fn(async () => ({ id: 7 })),
    getActivationVersion: vi.fn(() => 0),
    captureVisibleTab: vi.fn(async () => 'data:image/png;base64,FULL'),
  };
}

describe('captureInitiatingViewport', () => {
  it('verifies the initiating tab immediately before and after capture', async () => {
    const deps = makeDeps();

    await expect(captureInitiatingViewport(deps, input)).resolves.toBe(
      'data:image/png;base64,FULL',
    );
    expect(deps.getActiveTab).toHaveBeenCalledTimes(2);
    expect(deps.captureVisibleTab).toHaveBeenCalledWith(2);
  });

  it('fails closed if another tab is active before capture', async () => {
    const deps = makeDeps();
    vi.mocked(deps.getActiveTab).mockResolvedValue({ id: 8 });

    await expect(captureInitiatingViewport(deps, input)).rejects.toBeInstanceOf(
      ActiveTabChangedError,
    );
    expect(deps.captureVisibleTab).not.toHaveBeenCalled();
  });

  it('rejects the captured pixels if the active tab changes during capture', async () => {
    const deps = makeDeps();
    vi.mocked(deps.getActiveTab)
      .mockResolvedValueOnce({ id: 7 })
      .mockResolvedValueOnce({ id: 8 });

    await expect(captureInitiatingViewport(deps, input)).rejects.toBeInstanceOf(
      ActiveTabChangedError,
    );
  });

  it('fails closed when the user switches away and back during capture', async () => {
    const deps = makeDeps();
    let version = 0;
    vi.mocked(deps.getActivationVersion).mockImplementation(() => version);
    vi.mocked(deps.captureVisibleTab).mockImplementation(async () => {
      version += 2;
      return 'data:image/png;base64,FULL';
    });

    await expect(captureInitiatingViewport(deps, input)).rejects.toBeInstanceOf(
      ActiveTabChangedError,
    );
  });

  it('drops a superseded capture', async () => {
    const deps = makeDeps();
    let current = true;
    vi.mocked(deps.captureVisibleTab).mockImplementation(async () => {
      current = false;
      return 'data:image/png;base64,FULL';
    });

    await expect(
      captureInitiatingViewport(deps, { ...input, isCurrent: () => current }),
    ).rejects.toBeInstanceOf(CaptureSupersededError);
  });
});
