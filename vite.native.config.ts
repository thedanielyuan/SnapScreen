import { defineConfig } from 'vite';
import { crx } from '@crxjs/vite-plugin';
import packageJson from './package.json' with { type: 'json' };
import manifest from './src/manifest-native.json' with { type: 'json' };

export default defineConfig({
  plugins: [crx({ manifest: { ...manifest, version: packageJson.version } })],
  build: {
    outDir: 'dist-native',
    rolldownOptions: {
      input: {
        settings: 'src/options/options-native.html',
      },
    },
  },
});
