/* Pure recall-round rules. The browser adapter owns focus, timing and storage. */
(function (root) {
  'use strict';
  function begin(card, alternatives = [card]) {
    const answers = [card, ...alternatives.filter(c => c.id !== card.id && c.command === card.command)];
    return { card, answers, candidates:answers, cursor:0, misses:0, hits:0, hinted:false, done:false };
  }
  function press(state, key) {
    if (state.done) return 'ignored';
    const candidates = state.candidates.filter(c => c.keys[state.cursor] === key);
    if (!candidates.length) {
      state.misses++; state.cursor = 0; state.candidates = state.answers;
      state.card = state.answers[0];
      return 'wrong';
    }
    state.candidates = candidates; state.card = candidates[0];
    state.hits++;
    if (++state.cursor === state.card.keys.length) { state.done = true; return 'complete'; }
    return 'correct';
  }
  function eventKey(event) {
    if (event.repeat || event.isComposing || event.ctrlKey || event.metaKey || event.altKey) return null;
    return typeof event.key === 'string' && event.key.length === 1 ? event.key : null;
  }
  function cleanProgress(value) {
    const result = Object.create(null);
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    for (const [id, p] of Object.entries(value)) {
      if (p && ['seen', 'clean', 'misses'].every(k => Number.isSafeInteger(p[k]) && p[k] >= 0)
          && p.clean <= p.seen) result[id] = { seen:p.seen, clean:p.clean, misses:p.misses,
            cleanRun:Number.isSafeInteger(p.cleanRun) && p.cleanRun >= 0 && p.cleanRun <= p.clean ? p.cleanRun : 0 };
    }
    return { ...result };
  }
  const needsPractice = p => !!p && (p.cleanRun || 0) < 3;
  function choose(cards, progress, previous, random = Math.random) {
    // Each card remains reachable. New and rusty bindings get more repetitions.
    const weight = c => {
      const p = progress[c.id];
      return !p ? 8 : 1 + 7 / ((p.cleanRun ?? p.clean) + 1) + Math.min(6, p.misses / (p.seen || 1) * 3);
    };
    const pool = cards.filter(c => cards.length === 1 || c.id !== previous)
      .sort((a, b) => weight(b) - weight(a));
    if (!pool.length) return null;
    const weights = pool.map(weight);
    let target = random() * weights.reduce((a, b) => a + b, 0);
    for (let i = 0; i < pool.length; i++) if ((target -= weights[i]) < 0) return pool[i];
    return pool[pool.length - 1];
  }
  function record(progress, state) {
    const next = cleanProgress(progress);
    const p = next[state.card.id] || { seen:0, clean:0, misses:0 };
    next[state.card.id] = {
      seen: p.seen + 1,
      clean: p.clean + (state.misses === 0 && !state.hinted ? 1 : 0),
      misses: p.misses + state.misses,
      cleanRun: state.misses === 0 && !state.hinted ? (p.cleanRun || 0) + 1 : 0
    };
    return next;
  }
  const api = { begin, press, eventKey, cleanProgress, choose, record, needsPractice };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.IrisPracticeEngine = api;
})(globalThis);
