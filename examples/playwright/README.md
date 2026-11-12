# Playwright tests on the devices of MCloud

The fixtures of `@playwright/test` for the Android devices of MCloud (`mcloud.ts`), an example test and the workflow of
GitHub Actions that runs them (`github-actions.yml`); see [Playwright](../../README.md#playwright). The Playwright
sessions are an option of the farm: `PLAYWRIGHT_ENABLED=true` of MCloud.

```bash
npm ci
MCLOUD_URL=https://mcloud.example.com MCLOUD_DEVICES=2 npx playwright test
```

| Variable | Description |
| --- | --- |
| `MCLOUD_URL` | the address of MCloud, `https://user:password@...` with the basic authentication of the grid |
| `MCLOUD_DEVICES` | the workers of Playwright: every worker takes its own device for its tests, 1 by default |
| `MCLOUD_CAPS` | more capabilities of the devices as JSON, e.g. `{"appium:platformVersion": "14+"}`, `{"appium:deviceName": "Pixel_8"}`; `{"zebrunner:STF_TOKEN": "<access token>"}` reserves the devices as that user of STF |

A test gets Chrome of the device as `page` and `context` (a new Chrome for every test) and the device itself as
`device` (`device.shell()`, the Android UI, the WebViews of the apps). The device of a worker waits in the queue of the
grid while all the matching devices are busy, it is returned to the farm when the worker ends; MCloud keeps the video
of every session.
