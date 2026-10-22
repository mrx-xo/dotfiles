// KOMAX (Keychron K0 Max) board page: six legends, nothing else bound.
// Run with PLAYWRIGHT_MODULE=/path/to/playwright and BROWSER_EXECUTABLE.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.BROWSER_EXECUTABLE });
  try {
    const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    const url = pathToFileURL(path.resolve(__dirname, '../komax.html')).href;
    const res = await page.goto(url);
    assert.ok(res && res.ok(), 'komax.html must load');
    const ids = ['m1', 'm2', 'm3', 'm4', 'm5', 'knob'];
    const legends = [], codes = [];
    for (const id of ids) {
      legends.push(await page.locator(`#${id} .legend`).textContent());
      codes.push(await page.locator(`#${id} .code`).textContent());
    }
    assert.deepEqual(legends, ['ROMULUS', 'REMUS', 'NYX', 'POLLUX', 'NEMESIS', 'WORK']);
    assert.deepEqual(codes, ['F13', 'F14', 'F15', 'F16', 'F17', 'F19']);
    assert.equal(await page.locator('.key.bound').count(), 6);
    assert.equal(await page.locator('.key.stock').count(), 21, 'stock numpad keys plus knob turn stay greyed');
    assert.deepEqual(errors, []);
    console.log('PASS komax board renders six legends');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });
