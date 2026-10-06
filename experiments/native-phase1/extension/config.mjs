// Public test key only. This fixes the unpacked extension's ID across test profiles.
export const EXTENSION_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAohemHTNjceSXJtHKu6UHTD4elzl0/F9OsBDxtuYdKA1hi5oiwAUxMZPZwTZOePgKlK03NlF52ZWtDNp131EXtXue2G3p0ExsXA1A7tvjztAXk488fRm2pXb6j95wArE3UR+PRIwLwN45oEL2o3iw1vFIZaylqw4J5+1D/eUlq+eX7uivbrKWQI6SWGQISaI1PQxAVcPAfCIeg2BLVIlQjeaWbRfKO+YYPDofYSyB3TBS5EAMFGbxMLgK5hGfs0OoYlYGFR+dwdA+V1EvuYXSDvEWGB5GYcFL74Ww3gDA1RRVac62XfKMqDNVmlsvyaGIrlCXh1edjGyp8YR/G53OUwIDAQAB';
export const EXTENSION_ID = 'cdkiemiejgdholedacflfdkgmkfiaaoo';
export const NATIVE_HOST = 'com.snapscreen.phase1';

export const manifest = {
  manifest_version: 3,
  name: 'SnapScreen — native Phase 1 experiment',
  version: '0.0.1',
  minimum_chrome_version: '116',
  description: 'Local interaction experiment with mocked answers. Separate from SnapScreen.',
  key: EXTENSION_KEY,
  permissions: ['activeTab', 'nativeMessaging'],
  background: { service_worker: 'background.mjs', type: 'module' },
  action: { default_title: 'Native Phase 1: capture and select' },
  commands: {
    _execute_action: {
      suggested_key: { default: 'Alt+Shift+S', mac: 'Alt+Shift+S' },
      description: 'Native capture and region selection',
    },
    'capture-baseline': {
      suggested_key: { default: 'Alt+Shift+B', mac: 'Alt+Shift+B' },
      description: 'Capture only: no native host or overlay',
    },
  },
};
