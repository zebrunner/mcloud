// The Playwright fixtures of MCloud (README.md#playwright): every worker of Playwright takes an Android device of the
// farm for its tests, the tests get Chrome of the device (page, context) or the device itself (device).
//
//   MCLOUD_URL   the address of MCloud, e.g. https://mcloud.example.com (https://user:password@... with the basic
//                authentication of the grid)
//   MCLOUD_CAPS  optional JSON of more capabilities of the device, e.g. {"appium:platformVersion": "14+"} or
//                {"appium:deviceName": "Pixel_8", "zebrunner:STF_TOKEN": "<access token of STF>"}
import {test as base, expect, _android, type AndroidDevice, type BrowserContext, type Page} from '@playwright/test';
import http from 'node:http';
import https from 'node:https';

type Session = {id: string; device: AndroidDevice};

const mcloud = new URL(process.env.MCLOUD_URL ?? 'http://localhost');
const authorization = mcloud.username
  ? 'Basic ' + Buffer.from(`${decodeURIComponent(mcloud.username)}:${decodeURIComponent(mcloud.password)}`).toString('base64')
  : undefined;
const hub = `${mcloud.origin}/mcloud/wd/hub`;
// the grid queues a session until a device is free: GRID_NEW_SESSION_WAIT_TIMEOUT of MCloud, 10 minutes
const QUEUE_TIMEOUT_MS = 11 * 60 * 1000;

/**
 * A WebDriver request to the grid; without the timeouts of fetch, a new session waits in the queue of the grid.
 */
function request(method: string, path: string, body?: object): Promise<{status: number; value: any}> {
  const url = new URL(hub + path);
  const data = body ? JSON.stringify(body) : undefined;
  const client = url.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const req = client.request(url, {
      method,
      timeout: QUEUE_TIMEOUT_MS,
      headers: {
        'content-type': 'application/json',
        ...(authorization ? {authorization} : {}),
        ...(data ? {'content-length': Buffer.byteLength(data)} : {}),
      },
    }, (res) => {
      let text = '';
      res.on('data', (chunk) => (text += chunk));
      res.on('end', () => {
        try {
          resolve({status: res.statusCode ?? 0, value: JSON.parse(text).value});
        } catch {
          resolve({status: res.statusCode ?? 0, value: text});
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error(`${method} ${path}: no answer of the grid`)));
    req.on('error', reject);
    req.end(data);
  });
}

async function startSession(): Promise<Session> {
  if (!process.env.MCLOUD_URL) {
    throw new Error('Set MCLOUD_URL, the address of MCloud');
  }
  const capabilities = {
    'platformName': 'Android',
    'appium:automationName': 'Playwright',
    ...JSON.parse(process.env.MCLOUD_CAPS || '{}'),
  };
  const created = await request('POST', '/session', {capabilities: {alwaysMatch: capabilities}});
  if (created.status !== 200 || !created.value?.sessionId) {
    throw new Error(`MCloud did not start a session (HTTP ${created.status}): ${JSON.stringify(created.value)}`);
  }
  const id: string = created.value.sessionId;
  try {
    const ws = `${mcloud.origin.replace(/^http/, 'ws')}/mcloud/playwright/${id}`;
    const device = await _android.connect(ws, {headers: authorization ? {authorization} : {}, timeout: 120_000});
    return {id, device};
  } catch (err) {
    await request('DELETE', `/session/${id}`).catch(() => {});
    throw err;
  }
}

export const test = base.extend<{device: AndroidDevice}, {session: Session}>({
  // the device of the worker: reserved for all its tests, returned to the farm when the worker ends
  session: [async ({}, use) => {
    const session = await startSession();
    try {
      await use(session);
    } finally {
      await session.device.close().catch(() => {});
      await request('DELETE', `/session/${session.id}`).catch(() => {});
    }
  }, {scope: 'worker', timeout: QUEUE_TIMEOUT_MS + 3 * 60 * 1000}],

  device: async ({session}, use) => {
    await use(session.device);
  },

  // Chrome of the device, a clean one for every test
  context: async ({session}, use) => {
    await session.device.shell('am force-stop com.android.chrome');
    const context: BrowserContext = await session.device.launchBrowser();
    await use(context);
    await context.close();
  },

  page: async ({context}, use) => {
    const page: Page = await context.newPage();
    await use(page);
  },
});

export {expect};
