import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    // React Native itself does not run in Node, so tests use small host-component stand-ins.
    alias: { 'react-native': fileURLToPath(new URL('./test/react-native-mock.tsx', import.meta.url)) },
  },
  test: {
    include: ['test/**/*.test.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,tsx}'],
      thresholds: { lines: 95, functions: 93, branches: 80, statements: 93 },
    },
  },
});
