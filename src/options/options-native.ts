import { initializeOptionsPage } from './options-controller';

export function initializeNativeOptionsPage(doc: Document = document): Promise<void> {
  return initializeOptionsPage(doc, { variant: 'native-only' });
}

if (
  typeof document !== 'undefined' &&
  document.getElementById('settings-form')
) {
  void initializeNativeOptionsPage(document).catch(() => undefined);
}
