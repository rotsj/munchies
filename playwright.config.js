import { defineConfig, devices } from '@playwright/test';

const host = '127.0.0.1';
const port = Number(process.env.MUNCHIES_TEST_PORT ?? 4173);

export default defineConfig({
  testDir: './Tests/Browser',
  fullyParallel: true,
  workers: 2,
  timeout: 25_000,
  reporter: 'list',
  preserveOutput: 'never',
  use: {
    baseURL: `http://${host}:${port}`,
    trace: 'off',
    screenshot: 'off',
    video: 'off',
  },
  projects: [
    { name: 'package', testMatch: 'package.spec.js' },
    ...['iPhone 14 Pro Max', 'iPhone 17 Pro Max', 'Pixel 7'].map(name => ({
      name,
      testIgnore: 'package.spec.js',
      use: { ...devices[name] },
    })),
  ],
  webServer: {
    command: `python3 -m http.server ${port} --bind ${host} --directory dist`,
    url: `http://${host}:${port}/`,
  },
});
