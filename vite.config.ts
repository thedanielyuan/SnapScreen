import { defineConfig } from 'vite';
import { crx } from '@crxjs/vite-plugin';
import packageJson from './package.json';
import manifest from './src/manifest.json';

export default defineConfig({
  // package.json is the single source of the extension version.
  plugins: [crx({ manifest: { ...manifest, version: packageJson.version } })],
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
});
