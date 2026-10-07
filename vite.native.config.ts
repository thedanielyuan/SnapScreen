import { defineConfig } from 'vite';
import { crx } from '@crxjs/vite-plugin';
import packageJson from './package.json';
import manifest from './src/manifest-native.json';

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
