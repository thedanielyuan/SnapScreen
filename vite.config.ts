import { defineConfig } from 'vite';
import { configDefaults } from 'vitest/config';
import { crx, type CrxPlugin } from '@crxjs/vite-plugin';
import packageJson from './package.json';
import manifest from './src/manifest.json';

// CRX makes every `?script` import web-accessible, but the worker injects the
// content script with chrome.scripting, which needs no webpage access. Ship
// exactly the web-accessible resources that src/manifest.json declares.
const declaredWebResources = new Set(
  manifest.web_accessible_resources.flatMap(({ resources }) => resources),
);
const keepDeclaredWebResources: CrxPlugin = {
  name: 'snapscreen:declared-web-resources',
  apply: 'build',
  enforce: 'post',
  renderCrxManifest(builtManifest) {
    builtManifest.web_accessible_resources = builtManifest.web_accessible_resources
      ?.map((entry) => ({
        ...entry,
        resources: entry.resources.filter((resource) => declaredWebResources.has(resource)),
      }))
      .filter((entry) => entry.resources.length > 0);
    return builtManifest;
  },
};

export default defineConfig({
  // package.json is the single source of the extension version.
  plugins: [
    crx({ manifest: { ...manifest, version: packageJson.version } }),
    keepDeclaredWebResources,
  ],
  // Vite 8 uses Rolldown. Both packaged pages must be explicit HTML entries;
  // only the injected result frame is web-accessible.
  build: {
    rolldownOptions: {
      input: {
        resultFrame: 'src/ui/result-frame.html',
        workspace: 'src/workspace/workspace.html',
      },
    },
  },
  // Retained acceptance evidence under release/ can include saved Node tests
  // that are not Vitest suites.
  test: {
    exclude: [...configDefaults.exclude, 'release/**'],
  },
});
