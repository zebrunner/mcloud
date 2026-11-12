import {defineConfig} from '@playwright/test';

// every worker takes its own device of the farm: the workers are the devices used in parallel
export default defineConfig({
  testDir: './tests',
  workers: Number(process.env.MCLOUD_DEVICES || 1),
  timeout: 120_000,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', {open: 'never'}]],
  use: {
    trace: 'retain-on-failure',
  },
});
