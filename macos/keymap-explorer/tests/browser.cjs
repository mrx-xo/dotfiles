// Run with PLAYWRIGHT_MODULE=/path/to/playwright if it is not installed locally.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath:process.env.BROWSER_EXECUTABLE });
  try {
    const page = await browser.newPage({ viewport:{width:1440,height:1100} });
    const errors = []; page.on('pageerror', e => errors.push(e.message));
    const url = pathToFileURL(path.resolve(__dirname, '../index.html')).href;
    await page.goto(url + '#practice');
    await page.getByRole('button', {name:'Start a round',exact:true}).click();
    assert.equal(await page.locator('.practice-key').count(), 56);
    const card = async () => page.evaluate(() => window.IRIS_BINDINGS.cards.find(c =>
      c.command === document.getElementById('practice-command').textContent));
    let c = await card();
    await page.keyboard.type('!');
    assert.match(await page.locator('#practice-feedback').textContent(), /again/);
    await page.getByRole('button', {name:'Reveal keys',exact:true}).click();
    assert.ok(await page.locator('.practice-key.target').count() > 0);
    await page.keyboard.type(c.keys.join(''));
    await page.waitForFunction(() => document.getElementById('practice-round').textContent.startsWith('COMMAND 2 /'));
    assert.match(await page.locator('#practice-round').textContent(), /2 \/ 10/);
    await page.getByRole('button', {name:'Pause',exact:true}).click();
    assert.match(await page.locator('#practice-feedback').textContent(), /Paused/);
    await page.getByRole('button', {name:'Resume',exact:true}).click();
    for (let i=1; i<10; i++) {
      if (i === 1) {
        const accuracy = await page.locator('#practice-accuracy').textContent();
        await page.keyboard.press('Enter');
        assert.ok(await page.locator('.practice-key.target').count() > 0);
        const validSequences = await page.evaluate(() => window.IRIS_BINDINGS.cards
          .filter(c => c.command === document.getElementById('practice-command').textContent)
          .map(c => c.keys.map(k => k === ' ' ? 'SPC' : k).join('')));
        assert.ok(validSequences.includes(await page.locator('#practice-sequence').textContent()));
        assert.equal(await page.locator('#practice-accuracy').textContent(), accuracy);
        assert.equal(await page.evaluate(() => document.activeElement.id), 'practice-pad');
      }
      c = await card(); await page.keyboard.type(c.keys.join(''));
      await page.waitForFunction(expected => document.getElementById('practice-round').textContent === expected,
        i === 9 ? 'ROUND COMPLETE' : `COMMAND ${i + 2} / 10 · EVIL NORMAL`);
    }
    assert.equal(await page.locator('#practice-round').textContent(), 'ROUND COMPLETE');
    assert.equal(await page.locator('#practice-recalled').textContent(), '8 / 10');
    assert.equal(await page.locator('#practice-progress .finished').count(), 10);
    const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('iris-practice-v1')));
    assert.equal(Object.values(saved).reduce((n,p) => n + p.seen,0), 10);
    await page.locator('#practice-theme').selectOption('paper');
    await page.reload();
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'paper');
    await page.locator('#practice-theme').selectOption('gruvbox');
    // Capture belongs to the pad: Escape pauses, Tab leaves, search stays text.
    await page.getByRole('button', {name:'Start a round',exact:true}).click();
    await page.keyboard.press('Escape');
    assert.match(await page.locator('#practice-feedback').textContent(), /Paused/);
    await page.getByRole('button', {name:'Resume',exact:true}).click();
    await page.keyboard.press('Tab');
    assert.notEqual(await page.evaluate(() => document.activeElement.id), 'practice-pad');
    await page.locator('.practice-library summary').click();
    await page.locator('#practice-search').fill('consult-buffer');
    assert.equal(await page.locator('#practice-search').inputValue(), 'consult-buffer');
    const sequenceBeforeSearchEnter = await page.locator('#practice-sequence').textContent();
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#practice-sequence').textContent(), sequenceBeforeSearchEnter);
    assert.match(await page.locator('#practice-list').textContent(), /consult-buffer/);
    await page.locator('#practice-list button').first().click();
    assert.equal(await page.locator('#practice-deck').inputValue(), 'focus');
    assert.match(await page.locator('#practice-round').textContent(), /FOCUS SPC/);
    await page.getByRole('button', {name:'End round',exact:true}).click();
    assert.equal(await page.locator('#practice-deck').inputValue(), 'all');
    await page.getByRole('button', {name:'Explore',exact:true}).click();
    assert.equal(await page.locator('#ir-board .key').count(), 56);
    await page.locator('#sel-ir-a').selectOption('fac');
    assert.match(await page.locator('#ir-board').textContent(), /Q/);
    // A local draft may exist independently of the practice feature.
    if (await page.locator('#sel-ir-a option[value="pro"]').count()) {
      await page.locator('#sel-ir-a').selectOption('pro');
      await page.locator('#ir-tabs button[data-l="5"]').click();
      assert.match(await page.locator('#ir-board').textContent(), /imenu/);
    }
    await page.getByRole('button', {name:'Practice',exact:true}).first().click();
    await page.getByRole('button', {name:'Start a round',exact:true}).click();
    await page.getByRole('button', {name:'Reveal keys',exact:true}).click();
    await page.screenshot({path:'/tmp/iris-practice-desktop.png'});
    await page.setViewportSize({width:390,height:844});
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.screenshot({path:'/tmp/iris-practice-mobile.png'});
    await page.goto(url + '#widget');
    await page.reload();
    assert.equal(await page.locator('#practice').count(), 0);
    await page.evaluate(() => { window.__setLayer(2); window.__setMods({shift:true}); window.__flashKey('7',true); });
    assert.equal(await page.locator('#ir-board .key').count(), 56);
    assert.ok(await page.locator('#ir-board .press').count() > 0);
    assert.deepEqual(errors, []);
    const empty = await browser.newPage();
    await empty.route('**/practice-bindings.js', route => route.fulfill({body:'', contentType:'application/javascript'}));
    await empty.goto(url + '#practice');
    assert.match(await empty.locator('#practice-empty').textContent(), /current Emacs keymap/);
    const broken = await browser.newPage();
    await broken.addInitScript(() => {
      Storage.prototype.getItem = () => '{bad json';
      Storage.prototype.setItem = () => { throw new Error('disabled'); };
    });
    await broken.goto(url + '#practice');
    await broken.getByRole('button', {name:'Start a round',exact:true}).click();
    assert.match(await broken.locator('#practice-source').textContent(), /session-only/);
    assert.match(await broken.locator('#practice-round').textContent(), /COMMAND 1/);
    console.log('Browser checks passed: full round, wrong key, hints, focus/Escape/Tab, persistence, themes, search, layouts, narrow screen, widget, missing catalog, unavailable storage.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
