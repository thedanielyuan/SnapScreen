import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const installer = fileURLToPath(new URL('./native-companion-install.mjs', import.meta.url));
const extensionId = 'abcdefghijklmnopabcdefghijklmnop';
const hostName = 'com.snapscreen.companion';

test('registration requires explicit browser root and exact extension identity; removes only its matching fixture',
  { skip: process.platform !== 'darwin' }, async () => {
    const fixture = await mkdtemp(join(tmpdir(), 'snapscreen-native-install-'));
    try {
      const browserRoot = join(fixture, 'browser');
      const executable = join(fixture, 'fixture-executable');
      await mkdir(browserRoot);
      await writeFile(executable, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
      const run = (...args) => spawnSync(process.execPath, [installer, ...args], { encoding: 'utf8' });
      const args = ['--extension-id', extensionId, '--user-data-dir', browserRoot, '--executable', executable];
      for (const invalid of [[], ['--extension-id', extensionId], ['--extension-id', '*', '--user-data-dir', browserRoot],
        ['--extension-id', `${extensionId}\n`, '--user-data-dir', browserRoot],
        ['--extension-id', extensionId, '--user-data-dir', 'relative']]) {
        assert.notEqual(run(...invalid).status, 0);
      }
      assert.equal(run(...args).status, 0);
      const manifestPath = join(browserRoot, 'NativeMessagingHosts', `${hostName}.json`);
      const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
      assert.deepEqual(manifest, { name: hostName, description: 'SnapScreen macOS companion',
        path: await realpath(executable), type: 'stdio',
        allowed_origins: [`chrome-extension://${extensionId}/`] });
      assert.equal(run(...args).status, 0, 'same registration can be upgraded');
      const different = { ...manifest, allowed_origins: ['chrome-extension://pppppppppppppppppppppppppppppppp/'] };
      await writeFile(manifestPath, JSON.stringify(different));
      assert.notEqual(run(...args).status, 0, 'conflicting extension cannot be overwritten');
      assert.notEqual(run(...args, '--remove').status, 0, 'conflicting extension cannot be removed');
      assert.deepEqual(JSON.parse(await readFile(manifestPath, 'utf8')), different);
      await writeFile(manifestPath, JSON.stringify(manifest));
      assert.equal(run(...args, '--remove').status, 0);
      await assert.rejects(readFile(manifestPath), { code: 'ENOENT' });
      assert.equal(run(...args, '--remove').status, 0, 'removing absent registration is harmless');
    } finally {
      await rm(fixture, { recursive: true, force: true });
    }
  });
