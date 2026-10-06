import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, readFile, readdir, rename, rm, utimes, writeFile } from 'node:fs/promises';
import { isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { buildArchitectures, buildCompanion, buildMetadata, ROOT } from './native-companion-build.mjs';

export function packageOptions(args) {
  const { values } = parseArgs({ args, options: {
    arch: { type: 'string', default: 'native' },
    'output-dir': { type: 'string' },
    'sign-identity': { type: 'string' },
    'notary-profile': { type: 'string' },
    release: { type: 'boolean', default: false },
  } });
  const architectures = buildArchitectures(values.arch);
  const signIdentity = values['sign-identity'];
  const notaryProfile = values['notary-profile'];
  if (signIdentity !== undefined && !/^Developer ID Application: .+ \([A-Z0-9]{10}\)$/.test(signIdentity)) {
    throw new Error('--sign-identity must be a full Developer ID Application identity, including its team ID.');
  }
  if (notaryProfile !== undefined && (!notaryProfile.trim() || !signIdentity)) {
    throw new Error('--notary-profile requires a nonempty stored keychain profile and --sign-identity.');
  }
  if (values.release && (!signIdentity || !notaryProfile)) {
    throw new Error('--release requires both --sign-identity and --notary-profile; unsigned or unnotarized output is not a release.');
  }
  if (values['output-dir'] && !isAbsolute(values['output-dir'])) throw new Error('--output-dir must be absolute.');
  return {
    architecture: values.arch,
    architectureLabel: architectures.length === 2 ? 'universal' : architectures[0],
    outputDirectory: values['output-dir'] ?? resolve(ROOT, 'native/macos/build/package'),
    signIdentity,
    notaryProfile,
    release: values.release,
    signing: notaryProfile ? 'notarized' : signIdentity ? 'signed' : 'unsigned',
  };
}

// `output` combines both streams (codesign and spctl report on stderr); JSON parsing uses stdout.
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.signal}):\n${result.stderr ?? ''}${result.stdout ?? ''}`);
  return { stdout: result.stdout ?? '', output: `${result.stdout ?? ''}${result.stderr ?? ''}` };
}

export function checkProductionSelfTest(output) {
  if (!/^Native companion self-test: \d+ checks passed\s*$/m.test(output) || /test hooks/i.test(output)) {
    throw new Error('The packaged production app did not pass its self-tests without live-test hooks.');
  }
}

export function checkDeveloperSignature(output, expectedTeam) {
  if (!output.includes('Authority=Developer ID Application:')
    || !output.includes(`TeamIdentifier=${expectedTeam}\n`)
    || !/flags=.*\bruntime\b/.test(output)
    || !/^Timestamp=/m.test(output)) {
    throw new Error('The app is not signed by the expected Developer ID team with hardened runtime and a secure timestamp.');
  }
}

export function checkNotarization(output) {
  let result;
  try { result = JSON.parse(output); } catch { result = undefined; }
  if (result?.status !== 'Accepted' || typeof result.id !== 'string' || !result.id) {
    const submission = typeof result?.id === 'string' && result.id ? ` ${result.id} (${result.status})` : '';
    throw new Error(`Apple did not accept the notarization submission${submission}; no release artifact was created. `
      + 'Read its log with xcrun notarytool log <submission-id> --keychain-profile <profile>.');
  }
  return { id: result.id, status: result.status };
}

export function checkGatekeeper(output) {
  if (!/\baccepted\b/.test(output) || !/^source=Notarized Developer ID$/m.test(output)) {
    throw new Error('Gatekeeper did not accept the app as notarized Developer ID software.');
  }
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

// Fixed times and sorted members make local unsigned archives independent of packaging time.
async function archiveMembers(directory, prefix = '') {
  const result = [];
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
    const path = join(directory, entry.name);
    const relative = join(prefix, entry.name);
    if (entry.isDirectory()) result.push(...await archiveMembers(path, relative));
    else if (entry.isFile()) result.push(relative);
    else throw new Error(`Unexpected non-file in package: ${relative}`);
    await utimes(path, new Date('2020-01-01T00:00:00Z'), new Date('2020-01-01T00:00:00Z'));
  }
  return result;
}

export async function packageCompanion(args = process.argv.slice(2)) {
  const options = packageOptions(args);
  if (process.platform !== 'darwin') throw new Error('Native packaging requires macOS and Xcode command-line tools.');
  const metadata = await buildMetadata({ architecture: options.architecture });
  const name = `SnapScreenCompanion-${metadata.version}-macos-${options.architectureLabel}-${options.signing}`;
  await mkdir(options.outputDirectory, { recursive: true });
  const temporary = await mkdtemp(join(options.outputDirectory, '.snapscreen-package-'));
  const directory = join(temporary, name);
  const bundle = join(directory, 'SnapScreenCompanion.app');
  let notarization = null;
  try {
    const executable = await buildCompanion(['--bundle', bundle, '--arch', options.architecture]);
    checkProductionSelfTest(run(executable, ['--self-test']).output);
    const actualArchitectures = run('xcrun', ['lipo', '-archs', executable]).stdout.trim().split(/\s+/).sort();
    if (JSON.stringify(actualArchitectures) !== JSON.stringify([...metadata.architectures].sort())) {
      throw new Error('The packaged executable architectures do not match its build metadata.');
    }
    if (options.signIdentity) {
      run('/usr/bin/codesign', ['--force', '--sign', options.signIdentity, '--options', 'runtime', '--timestamp', bundle]);
      run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle]);
      const signature = run('/usr/bin/codesign', ['--display', '--verbose=4', bundle]).output;
      checkDeveloperSignature(signature, options.signIdentity.match(/\(([A-Z0-9]{10})\)$/)[1]);
    }
    if (options.notaryProfile) {
      // Supplying this option explicitly uploads this signed app to Apple's notary service.
      const submission = join(temporary, 'notarization.zip');
      run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', bundle, submission]);
      notarization = checkNotarization(run('xcrun', ['notarytool', 'submit', submission,
        '--keychain-profile', options.notaryProfile, '--wait', '--output-format', 'json']).stdout);
      run('xcrun', ['stapler', 'staple', bundle]);
      run('xcrun', ['stapler', 'validate', bundle]);
      run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle]);
      checkGatekeeper(run('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', bundle]).output);
      await rm(submission);
    }
    // Hardened runtime and stapling must leave the final executable working.
    if (options.signIdentity) checkProductionSelfTest(run(executable, ['--self-test']).output);
    const installer = join(directory, 'native-companion-install.mjs');
    await copyFile(resolve(ROOT, 'scripts/native-companion-install.mjs'), installer);
    const release = {
      ...metadata,
      signing: options.signing,
      notarization,
      releaseRequested: options.release,
      physicalInteractionAcceptance: 'pending',
      executableSha256: await sha256(executable),
      installerSha256: await sha256(installer),
    };
    await writeFile(join(directory, 'release.json'), `${JSON.stringify(release, null, 2)}\n`);
    await writeFile(join(directory, 'README.txt'), `SnapScreen Companion ${metadata.version}\n\n`
      + `Architecture: ${options.architectureLabel}. Build target: macOS ${metadata.minimumMacOSVersion} or later.\n`
      + `Native protocol: ${metadata.protocolVersion}. Use with SnapScreen extension ${metadata.version}; `
      + `other extension builds work only if they use native protocol ${metadata.protocolVersion}.\n`
      + `Signing status: ${options.signing}. Physical interaction acceptance: pending.\n\n`
      + (options.signing === 'unsigned' ? 'LOCAL ACCEPTANCE BUILD: no Developer ID signature or notarization. Do not distribute as a signed release.\n'
        : options.signing === 'signed' ? 'SIGNED ACCEPTANCE BUILD: notarization is incomplete. Do not distribute as a notarized release.\n'
          : 'The app passed Developer ID, notarization ticket, and local Gatekeeper checks. Interaction acceptance is still required.\n')
      + '\nInstall/upgrade requires Node.js 22+ and an existing browser user-data root from chrome://version.\n'
      + 'From this extracted folder, replace ID and /absolute/browser-root below. For Google Chrome the root\n'
      + 'is usually "$HOME/Library/Application Support/Google/Chrome" (keep the quotes).\n'
      + 'node native-companion-install.mjs --app "$PWD/SnapScreenCompanion.app" --extension-id ID --user-data-dir /absolute/browser-root\n'
      + 'Quit active companion sessions before upgrading. The app is copied to ~/Library/Application Support/SnapScreen.\n'
      + 'Uninstall this registration (the last managed registration also removes the app):\n'
      + 'node native-companion-install.mjs --remove --extension-id ID --user-data-dir /absolute/browser-root\n'
      + '\nThe host receives screenshot and conversation data only during native sessions, never the API key.\n'
      + 'Modifier keys may be observable by the page. Build targets do not establish tested OS/browser support.\n');
    const archive = join(temporary, `${name}.zip`);
    if (options.signIdentity) {
      // Preserve the signed bundle and stapled ticket with Apple's distribution archiver.
      run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', directory, archive]);
    } else {
      const members = await archiveMembers(directory, name);
      run('/usr/bin/zip', ['-X', '-q', archive, '-@'], { cwd: temporary, input: `${members.join('\n')}\n`,
        env: { ...process.env, TZ: 'UTC' } });
    }
    const checksum = await sha256(archive);
    const finalDirectory = join(options.outputDirectory, name);
    const finalArchive = join(options.outputDirectory, `${name}.zip`);
    await rm(finalDirectory, { recursive: true, force: true });
    await rename(directory, finalDirectory);
    await rename(archive, finalArchive);
    await writeFile(`${finalArchive}.sha256`, `${checksum}  ${name}.zip\n`);
    return {
      archive: finalArchive,
      directory: finalDirectory,
      bundle: join(finalDirectory, 'SnapScreenCompanion.app'),
      metadata: join(finalDirectory, 'release.json'),
      sha256: checksum,
      signing: options.signing,
      architectures: metadata.architectures,
      version: metadata.version,
    };
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  console.log(JSON.stringify(await packageCompanion()));
}
