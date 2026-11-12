import {test, expect} from '../mcloud';

test('Chrome of the device opens a page', async ({page}) => {
  await page.goto('https://example.com');
  await expect(page).toHaveTitle('Example Domain');
  await expect(page.getByText('documentation examples').first()).toBeVisible();
});

test('a page of the test itself, its input', async ({page}) => {
  await page.setContent('<input id="q"><button onclick="document.title = q.value">Go</button>');
  await page.locator('#q').fill('MCloud');
  await page.getByRole('button', {name: 'Go'}).click();
  await expect(page).toHaveTitle('MCloud');
});

test('the page is rendered for the screen of the device', async ({page}) => {
  await page.goto('https://example.com');
  const width = await page.evaluate(() => window.innerWidth);
  expect(width).toBeLessThan(600);
  expect((await page.screenshot()).length).toBeGreaterThan(1000);
});

test('the device itself: adb shell and the Android UI', async ({device}) => {
  expect((await device.shell('getprop ro.build.version.sdk')).toString().trim()).toMatch(/^\d+$/);
  expect(device.serial()).not.toBe('');
});
