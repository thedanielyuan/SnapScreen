import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const executable = fileURLToPath(new URL('../native/macos/build/SnapScreenCompanion.app/Contents/MacOS/SnapScreenCompanion', import.meta.url));
const result = spawnSync(executable, ['--self-test'], { encoding: 'utf8' });
if (result.error) throw result.error;
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
if (result.status !== 0) process.exit(result.status ?? 1);
if (result.stdout.includes('test hooks')) {
  console.error('The production companion build contains live-test hooks. Run npm run build:native.');
  process.exit(1);
}
const installerTest = fileURLToPath(new URL('./native-companion-install.node-test.mjs', import.meta.url));
const installer = spawnSync(process.execPath, ['--test', installerTest], { stdio: 'inherit' });
if (installer.error) throw installer.error;
process.exit(installer.status ?? 1);
