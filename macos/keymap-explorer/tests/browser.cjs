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
    // Practice must follow the flashed v3 layout, including its direct ? key.
    assert.equal(await page.evaluate(() => window.IrisLayout.symbols[23].c), 'KC_QUES');
    assert.deepEqual(await page.evaluate(() => window.IrisLayout.base[42].e), ['Scr▲', 'Scr▼']);
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
    // Current v3 is flashed; the changes view compares it with retired v2.
    if (await page.locator('#sel-ir-a option[value="pro"]').count()) {
      await page.locator('#sel-ir-a').selectOption('cur');
      await page.locator('#ir-tabs button[data-l="3"]').click();
      const systemKeys = board => page.locator(`${board} .key`).evaluateAll(keys => keys.map(key => ({
        tap: key.querySelector('.tap').textContent,
        hold: key.querySelector('.hold')?.textContent ?? null,
        title: key.title
      })));
      const currentSystem = await systemKeys('#ir-board');
      assert.deepEqual(currentSystem[34], {tap:'Shot', hold:'Area', title:'#34 · LSG(KC_4)'});
      await page.locator('#sel-ir-a').selectOption('prev');
      const previousSystem = await systemKeys('#ir-board');
      assert.deepEqual(previousSystem[34], {tap:'▽', hold:null, title:'#34 · KC_TRNS'});
      await page.locator('#sel-ir-a').selectOption('pro');
      const shot = page.locator('#ir-board .key').nth(34);
      assert.equal(await shot.locator('.tap').textContent(), 'Shot');
      assert.equal(await shot.locator('.hold').textContent(), 'Area');
      assert.equal(await shot.getAttribute('title'), '#34 · LSG(KC_4)');
      const proposedSystem = await systemKeys('#ir-board');
      assert.deepEqual(proposedSystem.flatMap((key,i) =>
        JSON.stringify(key) === JSON.stringify(previousSystem[i]) ? [] : [i]), [34]);
      assert.deepEqual(await page.locator('#ir-board .key').evaluateAll(keys =>
        keys.flatMap((key,i) => key.classList.contains('pro-change') ? [i] : [])), [34]);
      assert.equal(await page.locator('#ir-tabs button[data-l="3"] .change-count').textContent(), 'Δ 1');
      assert.match(await page.locator('#ir-pro-change-summary').textContent(), /1 release change in System/);
      await page.locator('#sel-ir-a').selectOption('cur');
      assert.deepEqual(await systemKeys('#ir-board'), currentSystem);
      assert.equal(await page.locator('#ir-board .pro-change').count(), 0);
      await page.locator('#btn-ir-both').click();
      await page.locator('#sel-ir-b').selectOption('pro');
      assert.deepEqual(await systemKeys('#ir-board'), currentSystem);
      assert.deepEqual(await systemKeys('#ir-board2'), proposedSystem);
      assert.equal(await page.locator('#ir-board2 .pro-change').count(), 1);
      assert.ok(await page.locator('#ir-board2 .key').nth(34).evaluate(key => key.classList.contains('pro-change')));
      await page.locator('#btn-ir-single').click();
      await page.locator('#sel-ir-a').selectOption('pro');
      await page.locator('#ir-tabs button[data-l="1"]').click();
      // Proposal indicators must stay distinct from every layer/category colour.
      for (const theme of ['gruvbox', 'paper', 'midnight']) {
        await page.locator('#practice-theme').selectOption(theme);
        const colours = await page.evaluate(() => {
          const key = document.querySelector('#ir-board .pro-change');
          const accent = getComputedStyle(key).outlineColor;
          const count = document.querySelector('#ir-tabs .change-count:not(.zero)');
          const summary = document.getElementById('ir-pro-change-summary');
          const delta = getComputedStyle(key, '::after');
          const rgba = value => value.match(/[\d.]+/g).map(Number);
          const composite = (front, back) => back.map((v,i) => v * (1 - (front[3] ?? 1)) + front[i] * (front[3] ?? 1));
          const background = node => node
            ? composite(rgba(getComputedStyle(node).backgroundColor), background(node.parentElement))
            : [255,255,255];
          const luminance = colour => colour.slice(0,3).map(v => v/255)
            .map(v => v <= .04045 ? v/12.92 : ((v+.055)/1.055)**2.4)
            .reduce((n,v,i) => n + v * [.2126,.7152,.0722][i],0);
          const contrast = (a,b) => (Math.max(luminance(a),luminance(b))+.05) / (Math.min(luminance(a),luminance(b))+.05);
          return {
            accent,
            categories: [...document.querySelectorAll('#ir-tabs .dot')].map(n => getComputedStyle(n).backgroundColor),
            indicators: [
              delta.backgroundColor,
              getComputedStyle(count).borderTopColor,
              getComputedStyle(summary).borderLeftColor,
              getComputedStyle(document.querySelector('.l-pro-change i')).borderTopColor
            ],
            textContrast: {
              count: contrast(rgba(getComputedStyle(count).color), background(count)),
              summary: contrast(rgba(getComputedStyle(summary).color), background(summary)),
              delta: contrast(rgba(delta.color), rgba(delta.backgroundColor))
            }
          };
        });
        assert.ok(!colours.categories.includes(colours.accent), `Proposal accent reuses a layer colour in ${theme}`);
        assert.ok(colours.indicators.every(colour => colour === colours.accent), `Proposal indicators disagree in ${theme}`);
        for (const [indicator, contrast] of Object.entries(colours.textContrast))
          assert.ok(contrast >= 4.5, `${indicator} contrast is ${contrast.toFixed(2)}:1 in ${theme}; expected at least 4.5:1`);
      }
      await page.locator('#practice-theme').selectOption('gruvbox');
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
    // KOMAX (Keychron K0 Max): its own board page, Iris untouched.
    await page.setViewportSize({width:1440,height:1100});
    await page.goto(url + '#explore');
    await page.reload();
    await page.locator('#bd-km').click();
    assert.ok(await page.locator('#app-ir').isHidden());
    assert.equal(await page.locator('#km-board .key').count(), 27);
    assert.match(await page.locator('#km-board .key').nth(0).getAttribute('title'), /KC_F19/);
    assert.equal(await page.locator('#km-board .key').nth(8).getAttribute('title'), '#8 · KC_PAST');
    assert.match(await page.locator('#km-board .key').nth(23).getAttribute('title'), /KC_F17/);
    await page.locator('#sel-km-a').selectOption('prev');
    assert.match(await page.locator('#km-board .key').nth(23).getAttribute('title'), /MO\(1\)/);
    await page.locator('#sel-km-a').selectOption('pro');
    const legends = await page.locator('#km-board .key .tap').allTextContents();
    for (const name of ['ROMULUS','REMUS','NYX','POLLUX','NEMESIS','WORK'])
      assert.ok(legends.includes(name), `KOMAX v1 is missing the ${name} legend`);
    assert.deepEqual(await page.locator('#km-board .key').evaluateAll(keys =>
      keys.flatMap((key,i) => key.classList.contains('pro-change') ? [i] : [])), [0,5,10,15,19,23]);
    assert.equal(await page.locator('#km-tabs button[data-l="0"] .change-count').textContent(), 'Δ 6');
    await page.locator('#km-tabs button[data-l="1"]').click();
    assert.match(await page.locator('#km-reach').textContent(), /knob press \+ Enter/);
    assert.equal(await page.locator('#km-board .key').nth(23).getAttribute('title'), '#23 · KC_TRNS');
    assert.match(await page.locator('#km-board .key').nth(24).getAttribute('title'), /UG_TOGG/);
    await page.locator('#sel-km-a').selectOption('cur');
    assert.match(await page.locator('#km-reach').textContent(), /knob press \+ Enter/);
    await page.locator('#bd-ir').click();
    assert.ok(await page.locator('#app-km').isHidden());
    assert.equal(await page.locator('#ir-board .key').count(), 56);
    // Practice hides every board and brings back the one you left.
    await page.locator('#bd-km').click();
    await page.getByRole('button', {name:'Practice',exact:true}).first().click();
    assert.ok(await page.locator('#app-km').isHidden());
    await page.getByRole('button', {name:'Explore',exact:true}).click();
    assert.ok(await page.locator('#app-km').isVisible());
    await page.goto(url + '#komax&widget');
    await page.reload();
    assert.equal(await page.locator('#km-board .key').count(), 27);
    assert.ok(await page.locator('#app-ir').isHidden());
    await page.evaluate(() => { window.__setMods({shift:true}); window.__setLayer(1); window.__flashKey('pad7',true); });
    assert.ok(await page.locator('#km-tabs button[data-l="1"]').evaluate(b => b.classList.contains('on')));
    await page.evaluate(() => window.__setLayer(0));
    await page.evaluate(() => window.__flashKey('pad7',true));
    assert.equal(await page.locator('#km-board .press').count(), 1);
    assert.equal(await page.locator('#km-board .press').getAttribute('title'), '#11 · KC_P7');
    await page.goto(url + '#widget');
    await page.reload();
    assert.equal(await page.locator('#practice').count(), 0);
    assert.ok(await page.locator('#app-km').isHidden());
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
    console.log('Browser checks passed: full round, wrong key, hints, focus/Escape/Tab, persistence, themes, search, layouts, flashed v3 area capture and retired comparisons, narrow screen, KOMAX board and widget, widget, missing catalog, unavailable storage.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
