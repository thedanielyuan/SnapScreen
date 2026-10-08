# Page observability improvement plan

Updated 8 October 2026. Baseline: `9c78707` on `origin/main`.

Reduce the signals that ordinary webpages can observe when SnapScreen is installed or used,
while preserving capture, accessibility, and the existing credential and conversation
boundaries. The highest-value architecture change, a separate native-only extension, is
already implemented. Physical acceptance of the packaged candidate was partially completed,
and the remaining physical matrix was skipped on 8 October 2026, so interaction claims are
limited to the workflows that were physically tested. Fixes that change interaction behavior
still need physical before/after evidence; the public-resource audit can be verified with
automated checks.

This document records proposed work and acceptance criteria. It does not record new tests or
claim that pending improvements have been implemented. It complements the detailed
[native-only implementation plan](native-only-implementation-plan.md).

## What can observe SnapScreen?

| Observer | Relevant visibility | Practical objective |
| --- | --- | --- |
| Ordinary webpage | Public extension resources, changes to its DOM, focus/visibility transitions, and input events delivered to it | Remove unnecessary exposure and measure remaining interaction effects |
| Another extension with suitable permissions | Installed-extension information through Chrome's management API | Do not claim that webpage isolation conceals installation from privileged extensions |
| Software with sufficient device privileges | Local application/process information and native-host registration files | Keep this outside the ordinary webpage guarantee |

Detecting installation, detecting an individual capture, and observing generic activity are
different outcomes. A modifier-key event or focus transition does not by itself prove that
SnapScreen was used. Absence of those events does not prove universal undetectability.

Chrome documents both [resource fingerprinting](https://developer.chrome.com/docs/extensions/reference/manifest/web-accessible-resources)
and [extension enumeration](https://developer.chrome.com/docs/extensions/reference/api/management#method-getAll).
Its [native messaging documentation](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
describes the registered local host and process boundary.

## Completed foundations to preserve

- The native-only extension has its own manifest, worker, Settings entry point, and Vite
  configuration. It excludes scripting permission, content scripts, the result frame,
  workspace, and web-accessible resources. See [the manifest](../src/manifest-native.json)
  and [worker](../src/background/service-worker-native.ts).
- `build:extension-native` and `package:extension-native` produce a separate extension build
  and validated ZIP. Generated `dist-native/` output is intentionally ignored by Git; that
  does not mean its build pipeline is missing.
- Package and browser gates already check resource exposure, excluded assets, Settings,
  session behavior, failure handling, and worker restart without replay. Native failures
  do not silently inject page UI or open a workspace or Settings during capture.
- Automated candidate verification is recorded for both extension variants and the
  production companion. The retained native-only ZIP extraction was also tested. These
  passes establish the reported package and functional properties, not physical input
  isolation. See [the candidate verification record](native-only-candidate-verification.md).

The ordinary extension still supports In Chrome mode. Its injected outer host remains
observable even though the closed shadow root and extension-origin frame protect internal
content. Selecting native mode in that package does not remove its static manifest resource
exposure. See [the current isolation boundary](security.md#limits-of-the-isolation-boundary).

## Priorities

| Priority | Work | Status | Expected benefit |
| --- | --- | --- | --- |
| 1 | Physically test the retained native-only candidate and production companion | Partially tested; remaining matrix skipped 8 October; [record](native-only-physical-acceptance.md) | Establish what the packaged interaction actually exposes |
| 2 | Investigate and repair reproducible focus or input leakage | Shortcut modifier leakage reproduced on the candidate; earlier post-close blur not seen in valid repeats; resize leakage unmeasured | Reduce unintended interaction with the source page |
| 3 | Maintain package gates and record a reviewed acceptance matrix for releases | Automated gates implemented; physical matrix partial, remainder skipped | Prevent regressions and keep claims tied to tested artifacts |
| 4 | Audit unnecessary public resources in the ordinary extension | Proposed | Reduce passive installation fingerprinting for users retaining In Chrome mode |
| 5 | Evaluate dynamic URLs for ordinary-mode resources that must remain public | Optional investigation | Reduce probing through a stable resource URL where supported |

### 1. Complete packaged physical acceptance

The [physical acceptance record](native-only-physical-acceptance.md) tracks verified artifact
identities, collector preparation, prior partial evidence, and the physical matrix. The
remaining matrix was skipped on 8 October 2026; the steps below apply if testing resumes.

Use the retained extension extraction and unmodified production app identified by the
[candidate record](native-only-candidate-verification.md#milestone-5-handoff), following the
[physical acceptance procedure](native-phase4-acceptance.md). Select the extension explicitly
with `--extension-dir`; the runner defaults to the ordinary `dist/` variant.

- Verify the candidate hashes before collecting evidence. Keep original artifact identities
  and disposable fixture modifications distinguishable.
- First run positive controls for ordinary page input, application switching, and tab
  switching. The observer must show the expected signals before a quiet trace is meaningful.
- Use a physical keyboard and pointer for toolbar and shortcut activation, selection,
  follow-up typing, copy/paste, moving/resizing, scrolling, preview, cancellation, and closing.
- Exercise cold and concurrent sessions, fullscreen, multiple displays, scaling/zoom, input
  methods, and accessibility settings for each configuration the release intends to support.
- Use synthetic content and the existing metadata-only collector. Record the observed native
  outcome as well as the page trace; no page event is insufficient evidence that an action
  succeeded.

Acceptance: each claimed workflow has a reviewed trace with a valid starting state, no dropped
observations, complete timing coverage, and the expected visible native result. Record every
transient focus/visibility change and input leak. Any unexpected transient focus or visibility
change fails focus preservation; score input isolation separately. Mark unsupported or untested
configurations explicitly. Automation that manipulates controls cannot replace physical acceptance.

### 2. Investigate focus and input leakage

The [Phase 1 results](native-phase1-results.md) record modifier keys reaching page handlers,
one unexplained 2.6-second focus/visibility loss, and earlier pointer leakage during resizing.
The prototype's final resize change improved the observed behavior, but its limited trials
do not establish the packaged companion's behavior across configurations.

- Reproduce each remaining issue against the candidate before selecting a fix.
- Separate invocation-related signals from subsequent native-directed input, while retaining
  both in the report. Generic modifier events must not be silently discarded.
- Investigate window activation, key-release handling, resizing, and input routing using
  supported AppKit behavior. Preserve keyboard navigation and accessibility.
- Repeat the failing interaction after a fix and check adjacent workflows such as preview
  closing, held close keys, concurrent windows, and fullscreen resizing.

Acceptance: document the reproduction, affected configurations, fix, and before/after evidence.
If a limitation remains, narrow the supported claim. Do not falsify the webpage's focus or
visibility APIs to make an observation pass.

### 3. Keep release evidence tied to the shipped artifacts

Extend the existing package and lifecycle gates when a new reproducible regression is found.
Preserve checks for absent injection/public resources and for success, cancellation, and host
failure paths. Resource probes need accessible and inaccessible controls so a page CSP that
blocks every request cannot produce a false pass.

Maintain a reviewed acceptance matrix containing the artifact hashes, OS/browser versions,
display setup, input method, accessibility settings, actions, results, and unresolved issues.
Repeat affected physical scenarios after changes to native controls, activation/input behavior,
or the supported environment. Mocked browser worker-restart checks establish fresh state and
no replay under that test. Production-host cleanup requires the separate native tests; neither
establishes natural suspension or physical focus behavior.

Acceptance: automated package gates pass, the final candidate is identifiable, and every
published interaction claim has matching reviewed evidence. Keep test hooks and collector
shims out of shipped artifacts. The retained extension and unsigned companion archives are
unpublished local acceptance candidates; the tag workflow still publishes only the ordinary
extension.

### 4. Audit the ordinary extension's public resources

The ordinary [manifest](../src/manifest.json) exposes `icon16.png` and `result-frame.html` to
broad webpage origins. The icon appears to be rendered within extension-origin surfaces;
its standalone web-accessible declaration may therefore be unnecessary. Verify that inference
against source usage and the built artifact before removing it.

Audit the built manifest as well as source declarations, since bundling can add resources.
Remove declarations only when the resource is no longer needed by webpage-facing features.
Retain the result frame exposure while In Chrome mode embeds that extension page.

Acceptance: the icon still renders in all relevant extension surfaces, ordinary capture and
workspace flows pass browser checks, and controlled webpage probes cannot load any resource
whose exposure was removed. This reduces installation fingerprinting; the injected DOM host
remains observable during In Chrome use.

### 5. Evaluate dynamic resource URLs where needed

Chrome's `use_dynamic_url` setting restricts a declared resource to a session-specific dynamic
ID. Evaluate it only for resources the ordinary extension must expose. The native-only
package already avoids those declarations.

Check supported Chrome versions, including the declared Chrome 116 minimum, before making a
compatibility claim. Verify URL generation, frame loading under restrictive page CSPs,
origin checks, capability attestation, reloads, and browser restarts. Keep the authenticated
frame channel intact; do not relax origin or capability validation to accommodate URL changes.

Acceptance: required resources load through the intended dynamic URLs on explicitly supported
versions, stable resource probes are denied where the feature is enforced, and security and
browser tests still pass. A dynamic URL does not conceal DOM insertion or interaction effects.

## Validation and completion

Implementation changes must follow [AGENTS.md](../AGENTS.md), including lint, typecheck, unit
tests, a fresh ordinary build, and browser smoke tests. Native-only, shared background,
companion, packaging, or installer changes require the additional variant and native checks
specified there. Use mocked API transport for these checks; a paid live API run requires the
separate approval described in the repository instructions.

Preserve the existing credential, private-channel, exact-origin host, and screenshot handling
boundaries throughout. Update [security documentation](security.md) when a boundary changes,
and [PRIVACY.md](../PRIVACY.md) and [store guidance](chrome-web-store.md) when permissions or
data handling change.

Completion means the selected improvements have passing regression checks and reviewed
evidence for their stated scope. Describe the result as minimal webpage-visible side effects
under the listed tested conditions. Do not assign a detection percentage or promise
undetectability from other extensions or device software without evidence supporting that
specific claim.
