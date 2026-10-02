(function () {
  'use strict';
  if (document.documentElement.classList.contains('widget')) return;
  const E = window.IrisPracticeEngine;
  const layout = window.IrisLayout;
  const $ = id => document.getElementById(id);
  let storageOK = true;
  function read(key, fallback) {
    try { const raw = localStorage.getItem(key); return raw ? JSON.parse(raw) : fallback; }
    catch (_) { storageOK = false; return fallback; }
  }
  function save(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); }
    catch (_) { storageOK = false; }
  }
  let progress = E.cleanProgress(read('iris-practice-v1', {}));
  const catalog = window.IRIS_BINDINGS;
  const cards = Array.isArray(catalog?.cards) ? catalog.cards.filter(c =>
    typeof c.id === 'string' && typeof c.command === 'string' && typeof c.group === 'string'
    && Array.isArray(c.keys) && c.keys.length && c.keys.every(k => typeof k === 'string' && /^[ -~]$/.test(k))) : [];
  const label = card => card.command.replace(/^mr-x\//, '').replace(/^(evil|consult|projectile)-/, '').replace(/[-/]/g, ' ');
  const nav = document.createElement('nav');
  nav.className = 'practice-nav'; nav.setAttribute('aria-label', 'Explorer views');
  nav.innerHTML = `<div><button id="view-explore" type="button">Explore</button> <button id="view-practice" type="button">Practice</button></div>
    <label>Theme <select id="practice-theme"><option value="gruvbox">Gruvbox</option><option value="paper">Gruvbox light</option><option value="midnight">Midnight</option></select></label>`;
  document.querySelector('.masthead').append(nav);
  const theme = read('iris-theme', 'gruvbox');
  $('practice-theme').value = ['gruvbox', 'paper', 'midnight'].includes(theme) ? theme : 'gruvbox';
  function applyTheme() { document.documentElement.dataset.theme = $('practice-theme').value; save('iris-theme', $('practice-theme').value); }
  applyTheme();
  $('practice-theme').addEventListener('change', applyTheme);
  const section = document.createElement('section');
  section.id = 'practice'; section.hidden = true;
  section.innerHTML = `<div class="practice-toolbar"><span class="practice-kicker">A little muscle memory.</span>
      <label>Practice <select id="practice-deck" aria-label="Practice deck"><option value="all">New & rusty</option><option value="new">Not practiced yet</option><option value="weak">Needs practice</option></select></label></div>
    <div id="practice-empty" class="practice-empty" hidden></div>
    <div id="practice-play">
      <div id="practice-pad" class="practice-pad" tabindex="0" role="group" aria-label="Practice keyboard. Type the binding. Enter reveals keys; Escape pauses; Tab leaves the keyboard.">
        <div class="practice-stage">
          <span id="practice-round" class="practice-meta">TEN COMMANDS · YOUR OWN KEYMAP</span>
          <h2 id="practice-title">Make it second nature.</h2>
          <p id="practice-command" class="practice-command">A command. A few keys. A little better each time.</p>
          <div id="practice-sequence" class="practice-sequence" aria-label="Key sequence"></div>
          <div id="practice-feedback" class="practice-feedback" role="status" aria-live="polite">New and missed bindings come around more often.</div>
          <div class="practice-actions"><button id="practice-start" class="practice-primary" type="button">Start a round</button>
            <button id="practice-hint" class="practice-subtle" type="button" aria-label="Reveal keys" aria-keyshortcuts="Enter" hidden>Reveal keys · Enter</button>
            <button id="practice-pause" class="practice-subtle" type="button" hidden>Pause</button>
            <button id="practice-end" class="practice-subtle" type="button" hidden>End round</button></div>
        </div>
        <div id="practice-board" class="practice-board" aria-label="Your Iris keyboard"></div>
        <p id="practice-board-caption" class="practice-board-caption">Iris SE · Dvorak · current v2</p>
      </div>
      <div class="practice-bottom"><div class="practice-stats">
        <span class="practice-stat">Accuracy<strong id="practice-accuracy">—</strong></span>
        <span class="practice-stat">Streak<strong id="practice-streak">0</strong></span>
        <span class="practice-stat">Recalled<strong id="practice-recalled">0 / 10</strong></span>
        </div><div id="practice-progress" class="practice-progress" aria-label="Round progress"></div></div>
    </div>
    <details class="practice-library"><summary id="practice-library-summary">Find a binding to practice</summary>
      <input id="practice-search" type="search" placeholder="Search command or keys…" aria-label="Search bindings">
      <div id="practice-list" class="practice-list"></div></details>
    <p id="practice-source" class="practice-source"></p>`;
  document.querySelector('.wrap').append(section);
  [...new Set(cards.map(c => c.group))].sort().forEach(g => $('practice-deck').add(new Option(g, g)));
  const focusOption = new Option('Single binding', 'focus'); focusOption.hidden = true;
  $('practice-deck').add(focusOption);
  let active = false, running = false, paused = false, transitioning = false, state = null;
  let roundPool = [], completed = 0, hits = 0, misses = 0, streak = 0, recalled = 0, previous = null;
  let timer = null, flashTimer = null, focusCard = null;
  const shiftChars = { '!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
    '"':"'", '<':',', '>':'.', '?':'/', ':':';', '_':'-' };
  function renderBoard() {
    const board = $('practice-board'); board.replaceChildren();
    const next = state && !state.done && state.hinted ? state.card.keys[state.cursor] : null;
    let target = next === ' ' ? 'Space' : next;
    let shift = !!target && /^[A-Z]$/.test(target);
    let symbolLayer = false;
    if (target && !layout.base.some(k => k.t.toLowerCase() === target.toLowerCase())) {
      if (layout.symbols.some(k => k.t === target)) symbolLayer = true;
      else if (shiftChars[target]) { target = shiftChars[target]; shift = true; }
    }
    const legends = symbolLayer ? layout.symbols.map((k,i) => k.k === 'trns' ? layout.base[i] : k) : layout.base;
    legends.forEach((k, i) => {
      const key = document.createElement('div'); key.className = 'practice-key';
      key.dataset.index = i;
      if (i === 42) key.classList.add('knob');
      key.style.left = `${(layout.geometry[i][0] + .05) / 15 * 100}%`;
      key.style.top = `${(layout.geometry[i][1] + .05) / 5.9 * 100}%`;
      key.textContent = k.t;
      if (k.h) { const hold = document.createElement('small'); hold.textContent = k.h; key.append(hold); }
      if (target && k.t.toLowerCase() === target.toLowerCase()) key.classList.add('target');
      if (shift && (k.h === '⇧' || k.t === 'Shift')) key.classList.add('mod-target');
      if (symbolLayer && (i === 51 || i === 43)) key.classList.add('mod-target');
      board.append(key);
    });
    $('practice-board-caption').textContent = symbolLayer ? 'Hold Space / Sym, then tap the highlighted symbol.'
      : shift ? 'Hold Shift, then tap the highlighted key.' : 'Iris SE · Dvorak · current v2';
  }
  function flash(key, wrong) {
    clearTimeout(flashTimer);
    document.querySelectorAll('.practice-key').forEach(n => n.classList.remove('pressed','wrong'));
    const keyName = key === ' ' ? 'space' : key.toLowerCase();
    layout.base.forEach((k,i) => {
      if (k.t.toLowerCase() === keyName) $('practice-board').children[i].classList.add(wrong ? 'wrong' : 'pressed');
    });
    flashTimer = setTimeout(() => document.querySelectorAll('.practice-key').forEach(n => n.classList.remove('pressed','wrong')), 160);
  }
  function feedback(text, type = '') { $('practice-feedback').textContent = text; $('practice-feedback').className = `practice-feedback ${type}`; }
  function renderSequence() {
    $('practice-sequence').replaceChildren();
    if (state) state.card.keys.forEach((key, i) => {
      const k = document.createElement('kbd');
      k.textContent = i < state.cursor || state.hinted ? key === ' ' ? 'SPC' : key : '·';
      k.className = i < state.cursor ? 'done' : i === state.cursor ? 'next' : '';
      $('practice-sequence').append(k);
    });
    renderBoard();
  }
  function stats() {
    $('practice-accuracy').textContent = hits + misses ? Math.round(hits / (hits + misses) * 100) + '%' : '—';
    $('practice-streak').textContent = streak;
    $('practice-recalled').textContent = `${recalled} / 10`;
    $('practice-progress').replaceChildren();
    for (let i=0; i<10; i++) { const dot = document.createElement('i'); dot.className = i < completed ? 'finished' : i === completed && running ? 'current' : ''; $('practice-progress').append(dot); }
    $('practice-progress').setAttribute('aria-label', `${completed} of 10 commands completed`);
  }
  function pool() {
    const choice = $('practice-deck').value;
    return cards.filter(c => choice === 'all' || choice === 'new' && !progress[c.id]
      || choice === 'weak' && E.needsPractice(progress[c.id])
      || c.group === choice);
  }
  function source() {
    $('practice-source').textContent = cards.length
      ? `${cards.length} bindings · ${catalog.context} · Snapshot ${new Date(catalog.generatedAt).toLocaleString()}. ${catalog.skipped || 0} chord/special-key bindings excluded. Refresh after keymap changes: ./practice.sh --refresh-only, then reload. ${storageOK ? 'Progress stays in this browser.' : 'Storage unavailable or unreadable; progress is session-only.'}`
      : 'Practice uses a local export of your Emacs leader bindings. No account or network service.';
  }
  function next() {
    transitioning = false;
    if (completed === 10) { finish(); return; }
    const card = E.choose(roundPool, progress, previous);
    previous = card.id; state = E.begin(card, focusCard ? [card] : cards);
    $('practice-title').textContent = label(card);
    $('practice-command').textContent = card.command;
    $('practice-round').textContent = `COMMAND ${completed + 1} / 10 · ${focusCard ? 'FOCUS ' + focusCard.sequence : 'EVIL NORMAL'}`;
    feedback('Type the binding. Enter to reveal · Escape to pause.');
    $('practice-hint').disabled = false;
    renderSequence(); stats();
  }
  function start() {
    roundPool = focusCard ? [focusCard] : pool();
    if (!roundPool.length) return;
    clearTimeout(timer); running = true; paused = false; transitioning = false;
    completed = hits = misses = streak = recalled = 0; previous = null;
    $('practice-start').hidden = true; $('practice-hint').hidden = false; $('practice-pause').hidden = false;
    $('practice-end').hidden = false;
    $('practice-pause').textContent = 'Pause';
    $('practice-deck').disabled = true;
    next(); $('practice-pad').focus();
  }
  function finish() {
    running = false; state = null; $('practice-deck').disabled = false;
    $('practice-title').textContent = recalled >= 8 ? 'That’s settling in.' : 'A little more familiar.';
    $('practice-command').textContent = `${recalled} recalled without help · ${10 - recalled} to keep practicing`;
    $('practice-round').textContent = 'ROUND COMPLETE';
    feedback('Your progress will shape the next round.');
    $('practice-start').textContent = 'Play another round'; $('practice-start').hidden = false;
    $('practice-start').disabled = !focusCard && !pool().length;
    $('practice-hint').hidden = $('practice-pause').hidden = true;
    $('practice-end').hidden = true;
    renderSequence(); stats(); renderLibrary(); source();
  }
  function pause() {
    if (!running) return;
    paused = true; clearTimeout(timer);
    $('practice-pause').textContent = 'Resume';
    feedback('Paused. Resume when you’re ready.');
  }
  function resume() {
    paused = false; $('practice-pause').textContent = 'Pause';
    if (transitioning) next(); else feedback('Type the binding. Enter to reveal · Escape to pause.');
    $('practice-pad').focus();
  }
  function idle() {
    clearTimeout(timer); running = paused = transitioning = false; state = null;
    if (!focusCard) {
      if ($('practice-deck').value === 'focus') $('practice-deck').value = 'all';
      focusOption.hidden = true;
    }
    $('practice-deck').disabled = false;
    $('practice-title').textContent = focusCard ? label(focusCard) : 'Make it second nature.';
    $('practice-command').textContent = focusCard ? focusCard.command : 'A command. A few keys. A little better each time.';
    $('practice-round').textContent = 'TEN COMMANDS · YOUR OWN KEYMAP';
    $('practice-start').textContent = 'Start a round'; $('practice-start').hidden = false;
    $('practice-hint').hidden = $('practice-pause').hidden = true;
    $('practice-end').hidden = true;
    const available = focusCard ? [focusCard] : pool();
    $('practice-start').disabled = !available.length;
    feedback(available.length ? `${available.length} ${available.length === 1 ? 'binding' : 'bindings'} in this deck. New and missed keys come around more often.` : 'No bindings in this deck yet. Try New & rusty.');
    completed = hits = misses = streak = recalled = 0;
    renderSequence(); stats(); renderLibrary();
  }
  function renderLibrary() {
    const query = $('practice-search').value.toLowerCase().trim();
    const matches = cards.filter(c => `${c.command} ${c.sequence}`.toLowerCase().includes(query));
    $('practice-library-summary').textContent = `Find a binding · ${cards.length} available`;
    $('practice-list').replaceChildren();
    matches.slice(0, 60).forEach(card => {
      const row = document.createElement('div'); row.className = 'practice-row';
      const text = document.createElement('span'); text.textContent = label(card);
      const detail = document.createElement('small'); detail.textContent = `${card.sequence} · ${card.command}`; text.append(detail);
      const button = document.createElement('button'); button.textContent = 'Practice';
      button.setAttribute('aria-label', `Practice ${card.command}`);
      button.onclick = () => {
        focusCard = card; focusOption.textContent = 'Only ' + card.sequence; focusOption.hidden = false;
        $('practice-deck').value = 'focus';
        idle(); section.querySelector('details').open = false; start();
      };
      row.append(text, button); $('practice-list').append(row);
    });
    if (!matches.length) $('practice-list').textContent = 'No matching bindings.';
    if (matches.length > 60) { const more = document.createElement('p'); more.textContent = `Showing 60 of ${matches.length}. Search to narrow down.`; $('practice-list').append(more); }
  }
  $('practice-pad').addEventListener('keydown', event => {
    if (event.target !== $('practice-pad') || !active || !running || paused) return;
    if (event.key === 'Escape') { event.preventDefault(); pause(); return; }
    if (event.key === 'Enter' && !event.ctrlKey && !event.altKey && !event.metaKey && !event.shiftKey) {
      event.preventDefault();
      if (!event.repeat && !event.isComposing && !transitioning) revealKeys();
      return;
    }
    const key = E.eventKey(event); if (key === null) return;
    event.preventDefault();
    if (transitioning) return;
    const result = E.press(state, key);
    if (result === 'wrong') { misses++; streak = 0; feedback('Try that sequence again, from the start.', 'error'); }
    else { hits++; feedback('Keep going.'); }
    if (result === 'complete') {
      completed++;
      if (!state.misses && !state.hinted) { streak++; recalled++; }
      else streak = 0;
      progress = E.record(progress, state); save('iris-practice-v1', progress);
      feedback(!state.misses && !state.hinted ? 'Recalled. Nice.' : 'Got it. We’ll revisit this one.', 'success');
      transitioning = true;
      timer = setTimeout(next, 550);
    }
    renderSequence(); flash(key, result === 'wrong'); stats(); source();
  });
  $('practice-pad').addEventListener('focusout', event => {
    if (event.relatedTarget) {
      if (!$('practice-pad').contains(event.relatedTarget)) pause();
    } else {
      // A hidden focused button briefly leaves focus on body during start/resume.
      setTimeout(() => { if (!$('practice-pad').contains(document.activeElement)) pause(); }, 0);
    }
  });
  $('practice-start').onclick = start;
  $('practice-end').onclick = () => { focusCard = null; idle(); $('practice-start').focus(); };
  function revealKeys() {
    if (!running || !state || state.done) return;
    state.hinted = true; renderSequence(); resume(); feedback('Follow the highlighted keys.');
  }
  $('practice-hint').onclick = revealKeys;
  $('practice-pause').onclick = () => { if (paused) resume(); else pause(); };
  $('practice-search').oninput = renderLibrary;
  $('practice-deck').onchange = () => { focusCard = null; idle(); };
  window.addEventListener('blur', pause);
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  function setView(practice, updateHash = true) {
    active = practice;
    if (!practice) pause();
    document.documentElement.classList.toggle('practicing', practice);
    $('app-ir').hidden = practice; section.hidden = !practice;
    $('view-explore').setAttribute('aria-pressed', String(!practice));
    $('view-practice').setAttribute('aria-pressed', String(practice));
    if (updateHash) history.replaceState(null, '', practice ? '#practice' : '#explore');
    if (!practice) window.dispatchEvent(new Event('resize'));
  }
  $('view-explore').onclick = () => setView(false);
  $('view-practice').onclick = () => setView(true);
  window.addEventListener('hashchange', () => setView(location.hash.includes('practice'), false));
  if (!cards.length) {
    $('practice-play').hidden = true; $('practice-empty').hidden = false;
    $('practice-empty').textContent = 'Bring your current Emacs keymap into the game.';
    const command = document.createElement('code'); command.textContent = '~/.dotfiles/macos/keymap-explorer/practice.sh';
    $('practice-empty').append(command); section.querySelector('details').hidden = true;
  }
  idle(); source(); setView(location.hash.includes('practice'), false);
})();
