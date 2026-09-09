import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.resolve(process.env.IDENT_QA_OUTPUT || path.join(root, 'test/.tmp-widget-preview'));
const files = new Map([
  ['/test/lead-harness.html', ['test/lead-harness.html', 'text/html']],
  ['/front/script.js', ['front/script.js', 'text/javascript']],
  ['/front/style.css', ['front/style.css', 'text/css']]
]);
const server = createServer(async (req, res) => {
  const entry = files.get(new URL(req.url, 'http://localhost').pathname);
  if (!entry) { res.writeHead(404).end(); return; }
  try {
    const body = await readFile(path.join(root, 'amocrm-widget', entry[0]));
    res.writeHead(200, { 'Content-Type': `${entry[1]}; charset=utf-8` }).end(body);
  } catch { res.writeHead(500).end(); }
});
let browser;
try {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  await mkdir(output, { recursive: true });
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1366, height: 900 }, timezoneId: 'Europe/Moscow' });
  // The harness replaces fetch. Still prohibit live backend requests if that replacement fails.
  await context.route('https://ident.code9dev.ru/**', route => route.abort());
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.setDefaultTimeout(12000);
  await page.goto(`${base}/test/lead-harness.html?panel=1`);
  const launcher = page.locator('.ident-widget-smart-launcher__button');
  await launcher.waitFor({ state: 'visible' });
  const launcherBox = await launcher.boundingBox();
  const taskBox = await page.locator('.feed-task-banner').boundingBox();
  assert.ok(launcherBox.y + launcherBox.height <= taskBox.y || launcherBox.y >= taskBox.y + taskBox.height ||
    launcherBox.x + launcherBox.width <= taskBox.x || launcherBox.x >= taskBox.x + taskBox.width, 'Launcher overlaps task banner');
  await launcher.click();
  const workspace = page.locator('.ident-widget-workspace');
  await workspace.waitFor({ state: 'visible' });
  await page.locator('[data-ident-filter-doctor]').first().waitFor();
  assert.equal(await page.locator('[data-ident-action="select_day"]').count(), 31, 'Calendar must show 31 days');
  assert.equal(await page.locator('[data-ident-filter-doctor]').count(), 4, 'Excluded doctor still shown');
  assert.equal(await page.locator('[data-ident-service-search]').count(), 0);
  await page.locator('[data-ident-filter-doctor][value="1904"]').check();
  await page.locator('[data-ident-filter-doctor][value="2361"]').check();
  assert.equal(await page.locator('[data-ident-filter-doctor]:checked').count(), 2, 'Multiple doctors must remain selected');
  await page.locator('[data-ident-filter-doctor-all]').check();
  const durations = await page.locator('[data-ident-duration-select] option').evaluateAll(nodes => nodes.map(node => Number(node.value)));
  assert.deepEqual(durations, Array.from({ length: 24 }, (_, i) => (i + 1) * 15));
  const box = await workspace.boundingBox();
  assert.ok(box.x >= 0 && box.x + box.width <= 1367 && box.y >= 0 && box.y + box.height <= 901, 'Modal leaves viewport');
  await page.screenshot({ path: path.join(output, 'widget-desktop.png') });

  // Six hours of fixture availability: no real patient or appointment is created.
  await page.locator('[data-ident-duration-select]').selectOption('360');
  const slot = page.locator('[data-ident-action="select_slot"][data-ident-slot-key^="2361|"]:not([disabled])').first();
  await slot.click();
  await page.locator('[data-ident-booking-field="fullName"]').fill('Test Patient');
  await page.locator('[data-ident-booking-field="phone"]').fill('+79990000000');
  await page.locator('[data-ident-booking-field="birthDate"]').fill('2099-01-01');
  assert.equal(await page.locator('[data-ident-action="submit_booking"]').isDisabled(), true, 'Future birthday must block submit');
  await page.locator('[data-ident-booking-field="birthDate"]').fill('1990-02-28');
  await page.locator('[data-ident-booking-field="comment"]').fill('Local QA fixture only');
  await page.locator('[data-ident-action="submit_booking"]').click();
  await page.waitForFunction(() => Boolean(window.lastBookingRequest));
  const booking = await page.evaluate(() => window.lastBookingRequest);
  assert.equal(booking.durationMinutes, 360);
  assert.equal(booking.clientBirthDate, '1990-02-28');
  assert.equal(booking.createAmoLead, false);
  assert.equal((Date.parse(booking.planEnd) - Date.parse(booking.planStart)) / 60000, 360);
  await page.waitForFunction(() => document.querySelector('[data-ident-booking-state]').textContent !== 'черновик');
  assert.equal(await page.locator('.ident-widget-workspace-timeline__cell.is-reserved').count(), 24, 'All 24 segments must be reserved');
  assert.equal(await page.locator('[data-ident-action="submit_booking"]').isDisabled(), true, 'Duplicate submit must be disabled');

  await page.goto(`${base}/test/lead-harness.html?advanced=1`);
  await page.locator('[data-ident-workspace-mode="calendar"]').waitFor({ state: 'visible' });
  assert.equal(await page.locator('[data-ident-advanced-tab="calendar"]').getAttribute('aria-selected'), 'true');
  await page.screenshot({ path: path.join(output, 'widget-calendar.png') });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`${base}/test/lead-harness.html?open=1`);
  await workspace.waitFor({ state: 'visible' });
  const mobileBox = await workspace.boundingBox();
  assert.ok(mobileBox.x >= 0 && mobileBox.x + mobileBox.width <= 391 && mobileBox.y + mobileBox.height <= 845, 'Mobile modal leaves viewport');
  await page.screenshot({ path: path.join(output, 'widget-mobile.png') });
  assert.deepEqual(errors, [], 'Uncaught browser errors');
  console.log('WIDGET BROWSER OK: one-click open, task separation, 31 days, multiple doctors, birthday, 6h booking, 24 reserved segments, duplicate guard, default calendar, desktop/mobile framing.');
  console.log(`Screenshots: ${output}`);
} finally {
  await browser?.close();
  await new Promise(resolve => server.close(resolve));
}
