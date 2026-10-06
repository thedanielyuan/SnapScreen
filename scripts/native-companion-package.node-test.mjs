import assert from 'node:assert/strict';
import test from 'node:test';
import { buildArchitectures, buildMetadata } from './native-companion-build.mjs';
import { checkDeveloperSignature, checkGatekeeper, checkNotarization, checkProductionSelfTest, packageOptions } from './native-companion-package.mjs';

test('build architectures are explicit and protocol metadata agrees on both sides', async () => {
  assert.deepEqual(buildArchitectures('native', 'arm64'), ['arm64']);
  assert.deepEqual(buildArchitectures('native', 'x64'), ['x86_64']);
  assert.deepEqual(buildArchitectures('universal'), ['arm64', 'x86_64']);
  assert.throws(() => buildArchitectures('riscv64'), /--arch/);
  const production = await buildMetadata();
  assert.equal(production.schemaVersion, 1);
  assert.equal(production.bundleIdentifier, 'com.snapscreen.companion');
  assert.equal(production.testHooks, false);
  assert.equal(production.protocolVersion, 3);
  assert.match(production.version, /^\d+\.\d+\.\d+$/);
  assert.equal(production.minimumMacOSVersion, '13.0');
  const fixture = await buildMetadata({ testHooks: true });
  assert.equal(fixture.bundleIdentifier, 'com.snapscreen.companion.test');
  assert.equal(fixture.testHooks, true);
});

test('packaging defaults to local unsigned and cannot accept test hooks or an arbitrary bundle', () => {
  const options = packageOptions([]);
  assert.equal(options.signing, 'unsigned');
  assert.equal(options.release, false);
  assert.equal(options.signIdentity, undefined);
  assert.equal(options.notaryProfile, undefined);
  assert.throws(() => packageOptions(['--test-hooks']), /Unknown option/);
  assert.throws(() => packageOptions(['--bundle', '/tmp/test.app']), /Unknown option/);
  assert.throws(() => packageOptions(['--output-dir', 'relative']), /absolute/);
});

test('release gate requires a Developer ID identity and stored notarization profile', () => {
  const identity = 'Developer ID Application: Example (ABCDEFGHIJ)';
  assert.throws(() => packageOptions(['--release']), /both --sign-identity and --notary-profile/);
  assert.throws(() => packageOptions(['--release', '--sign-identity', identity]), /both --sign-identity and --notary-profile/);
  assert.throws(() => packageOptions(['--notary-profile', 'stored']), /requires/);
  assert.throws(() => packageOptions(['--sign-identity', '-']), /Developer ID/);
  assert.throws(() => packageOptions(['--sign-identity', 'Apple Development: Example (ABCDEFGHIJ)']), /Developer ID/);
  assert.throws(() => packageOptions(['--sign-identity', identity, '--notary-profile', ' ']), /nonempty/);
  assert.equal(packageOptions(['--sign-identity', identity]).signing, 'signed');
  const release = packageOptions(['--release', '--arch', 'universal', '--sign-identity', identity, '--notary-profile', 'stored']);
  assert.equal(release.signing, 'notarized');
  assert.equal(release.architectureLabel, 'universal');
});

test('packaging rejects hooks and failed or unrecognized self-test output', () => {
  checkProductionSelfTest('Native companion self-test: 200 checks passed\n');
  assert.throws(() => checkProductionSelfTest('Native companion self-test: 200 checks passed (test hooks build)\n'), /production app/);
  assert.throws(() => checkProductionSelfTest(''), /production app/);
  assert.throws(() => checkProductionSelfTest('Some unrelated tests passed'), /production app/);
});

test('signature gate rejects ad hoc signatures, wrong teams, a missing hardened runtime, or no secure timestamp', () => {
  // Shape of `codesign --display --verbose=4` for a notarized Developer ID app.
  const signature = 'CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+7 location=embedded\n'
    + 'Authority=Developer ID Application: Example (ABCDEFGHIJ)\nAuthority=Developer ID Certification Authority\n'
    + 'Authority=Apple Root CA\nTimestamp=6 Oct 2026 at 10:25:13\nTeamIdentifier=ABCDEFGHIJ\n';
  checkDeveloperSignature(signature, 'ABCDEFGHIJ');
  assert.throws(() => checkDeveloperSignature(signature, 'ZYXWVUTSRQ'), /expected Developer ID/);
  assert.throws(() => checkDeveloperSignature(signature.replace('0x10000(runtime)', '0x0(none)'), 'ABCDEFGHIJ'), /hardened runtime/);
  assert.throws(() => checkDeveloperSignature(signature.replace('Authority=Developer ID Application:', 'Signature=adhoc'), 'ABCDEFGHIJ'), /Developer ID/);
  assert.throws(() => checkDeveloperSignature(signature.replace('Timestamp=', 'Signed Time='), 'ABCDEFGHIJ'), /secure timestamp/);
});

test('notarization gate accepts only a completed accepted submission', () => {
  assert.deepEqual(checkNotarization('{"id":"submission-id","status":"Accepted","message":"Processing complete"}'),
    { id: 'submission-id', status: 'Accepted' });
  for (const output of ['{"id":"submission-id","status":"Invalid"}', '{"id":"submission-id","status":"In Progress"}',
    '{"status":"Accepted"}', '{"id":"","status":"Accepted"}', 'not JSON', 'null']) {
    assert.throws(() => checkNotarization(output), /did not accept/);
  }
  assert.throws(() => checkNotarization('{"id":"submission-id","status":"Invalid"}'), /submission-id \(Invalid\).*notarytool log/);
});

test('Gatekeeper gate requires a notarized Developer ID assessment', () => {
  checkGatekeeper('/tmp/SnapScreenCompanion.app: accepted\nsource=Notarized Developer ID\n');
  assert.throws(() => checkGatekeeper('/tmp/SnapScreenCompanion.app: accepted\nsource=Developer ID\n'), /notarized/);
  assert.throws(() => checkGatekeeper('/tmp/SnapScreenCompanion.app: rejected\nsource=Unnotarized Developer ID\n'), /notarized/);
});
