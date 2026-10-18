import preact from '@preact/preset-vite';
import { defineConfig } from 'vite';

// The lessons are read straight from the iPhone app's content folder, so all three apps teach the same thing.
export default defineConfig({
  base: './',
  plugins: [preact()],
  server: { fs: { allow: ['..'] } },
  build: { outDir: 'dist', chunkSizeWarningLimit: 2000 },
  test: { environment: 'node' },
});
