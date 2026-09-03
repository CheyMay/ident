const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..', 'amocrm-widget');

function contentType(filePath) {
  if (filePath.endsWith('.html')) return 'text/html; charset=utf-8';
  if (filePath.endsWith('.js')) return 'application/javascript; charset=utf-8';
  if (filePath.endsWith('.css')) return 'text/css; charset=utf-8';
  return 'application/octet-stream';
}

async function main() {
  const server = http.createServer((request, response) => {
    const requestPath = new URL(request.url, 'http://127.0.0.1').pathname;
    const relativePath = requestPath === '/' ? 'test/lead-harness.html' : requestPath.replace(/^\/+/, '');
    const filePath = path.resolve(root, relativePath);
    if (!filePath.startsWith(root + path.sep) || !fs.existsSync(filePath)) {
      response.writeHead(404).end('Not found');
      return;
    }
    response.writeHead(200, { 'content-type': contentType(filePath) });
    fs.createReadStream(filePath).pipe(response);
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const browser = await chromium.launch({ headless: true });

  try {
    const page = await browser.newPage({ viewport: { width: 1900, height: 1080 } });
    await page.goto(`http://127.0.0.1:${port}/?panel=1`, { waitUntil: 'networkidle' });
    await page.waitForSelector('.ident-widget-smart-launcher');
    const smartLauncherPosition = await page.evaluate(() => {
      const launcher = document.querySelector('.ident-widget-smart-launcher');
      const composer = document.querySelector('.feed-compose');
      return launcher.nextElementSibling === composer;
    });
    if (!smartLauncherPosition) throw new Error('Smart launcher was not inserted above the feed composer');
    await page.click('.ident-widget-smart-launcher__button');
    await page.waitForSelector('.ident-widget-modal-shell');

    const result = await page.evaluate(() => {
      const overlay = document.querySelector('.modal-test-shell');
      const shell = document.querySelector('.ident-widget-modal-shell');
      const workspace = document.querySelector('.ident-widget-workspace');
      const schedule = document.querySelector('.ident-widget-workspace__schedule');
      const overlayRect = overlay.getBoundingClientRect();
      const shellRect = shell.getBoundingClientRect();
      return {
        overlayColor: getComputedStyle(overlay).backgroundColor,
        shellWidth: Math.round(shellRect.width),
        scheduleWidth: Math.round(schedule.getBoundingClientRect().width),
        leftGap: Math.round(shellRect.left - overlayRect.left),
        rightGap: Math.round(overlayRect.right - shellRect.right),
        workspaceOverflow: workspace.scrollWidth > workspace.clientWidth,
        durationValues: Array.from(document.querySelectorAll('[data-ident-duration-select] option')).map((option) => option.value),
        selectedDuration: document.querySelector('[data-ident-duration-select]').value,
        serviceControls: document.querySelectorAll('[data-ident-service-search], [data-ident-service-results], [data-ident-service-selected]').length,
        serviceRows: document.querySelectorAll('[data-ident-action="select_service"]').length,
        doctorOptions: Array.from(document.querySelectorAll('[data-ident-filter-doctor]')).map((item) => item.parentElement.textContent.trim()),
        metricLabels: Array.from(document.querySelectorAll('.ident-widget-workspace__metric span')).map((item) => item.textContent.trim()),
        commentRows: document.querySelector('[data-ident-booking-field="comment"]').rows
      };
    });

    if (result.overlayColor === 'rgb(255, 255, 255)' || result.overlayColor === 'rgba(255, 255, 255, 1)') {
      throw new Error(`Overlay is white: ${result.overlayColor}`);
    }
    if (result.shellWidth < 1120) throw new Error(`Modal is too narrow: ${result.shellWidth}px`);
    if (result.scheduleWidth < 760) throw new Error(`Schedule area is too narrow: ${result.scheduleWidth}px`);
    if (Math.abs(result.leftGap - result.rightGap) > 4) {
      throw new Error(`Modal is not centered: ${result.leftGap}px / ${result.rightGap}px`);
    }
    if (result.workspaceOverflow) throw new Error('Workspace has horizontal overflow');
    if (!result.durationValues.includes('15') || !result.durationValues.includes('30') || !result.durationValues.includes('120') || !result.durationValues.includes('720') || result.durationValues.length !== 48) {
      throw new Error(`Duration selector is incomplete: ${result.durationValues.join(',')}`);
    }
    if (result.selectedDuration !== '30') throw new Error(`Unexpected default duration: ${result.selectedDuration}`);
    if (result.serviceControls < 3 || result.serviceRows !== 6 || result.metricLabels.includes('Услуги')) {
      throw new Error('Full service picker is missing or the service counter is still visible');
    }
    if (result.doctorOptions.length !== 4 || result.doctorOptions.some((name) => /Ахметов/i.test(name))) {
      throw new Error(`Doctor exclusion failed: ${result.doctorOptions.join(', ')}`);
    }
    if (result.commentRows < 5) throw new Error(`Comment field is too small: ${result.commentRows} rows`);

    await page.screenshot({ path: path.join(os.tmpdir(), 'ident-widget-modal-1.18.0.png'), fullPage: true });

    const doctorCheckboxes = page.locator('[data-ident-filter-doctor]');
    await doctorCheckboxes.nth(0).check();
    await doctorCheckboxes.nth(1).check();
    const selectedDoctorState = await page.evaluate(() => ({
      label: document.querySelector('[data-ident-doctor-filter-label]').textContent.trim(),
      checked: document.querySelectorAll('[data-ident-filter-doctor]:checked').length,
      columns: document.querySelectorAll('.ident-widget-workspace-timeline__doctor').length
    }));
    if (selectedDoctorState.label !== 'выбрано: 2' || selectedDoctorState.checked !== 2 || selectedDoctorState.columns !== 2) {
      throw new Error(`Multiple doctor filter failed: ${JSON.stringify(selectedDoctorState)}`);
    }
    await page.selectOption('[data-ident-duration-select]', '120');
    const longSlot = page.locator('[data-ident-action="select_slot"]:not([disabled])').filter({ hasText: 'Свободно' }).first();
    await longSlot.click();
    await page.click('[data-ident-action="select_service"]');
    await page.fill('[data-ident-booking-field="comment"]', 'Комментарий клиента');
    await page.click('[data-ident-action="submit_booking"]');
    await page.waitForFunction(() => Boolean(window.lastBookingRequest));
    const booking = await page.evaluate(() => window.lastBookingRequest);
    if (booking.durationMinutes !== 120) throw new Error(`Unexpected booking duration: ${booking.durationMinutes}`);
    if (!booking.service || !booking.service.Name) throw new Error('Selected service is missing from booking payload');
    if (!String(booking.comment || '').includes('Комментарий клиента')) throw new Error('Booking comment was not preserved');

    result.bookingDuration = booking.durationMinutes;
    result.bookingHasService = Boolean(booking.service && booking.service.Name);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } finally {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
