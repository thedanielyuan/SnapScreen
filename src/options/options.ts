import { initializeOptionsPage } from './options-controller';

export { initializeOptionsPage } from './options-controller';

if (
  typeof document !== 'undefined' &&
  document.getElementById('settings-form')
) {
  void initializeOptionsPage(document).catch(() => undefined);
}
