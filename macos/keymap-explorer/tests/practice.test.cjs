const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = path.join(__dirname, '../practice-engine.js');
test('practice engine exists', () => assert.ok(fs.existsSync(source)));
if (fs.existsSync(source)) {
  const E = require(source);
  const card = { id: 'SPC b:buffer', keys: [' ', 'b'], command: 'buffer' };
  test('wrong keys restart the sequence; exact case matters', () => {
    const s = E.begin(card);
    assert.equal(E.press(s, ' '), 'correct');
    assert.equal(E.press(s, 'B'), 'wrong');
    assert.equal(s.cursor, 0);
    E.press(s, ' ');
    assert.equal(E.press(s, 'b'), 'complete');
    assert.equal(s.misses, 1);
    assert.equal(E.press(s, 'b'), 'ignored');
  });
  test('event handling uses emitted Dvorak characters, ignores chords and repeats', () => {
    assert.equal(E.eventKey({ key: 'p', code: 'KeyR' }), 'p');
    assert.equal(E.eventKey({ key: '{', shiftKey: true }), '{');
    for (const e of [{key:'x', ctrlKey:true}, {key:'x', metaKey:true},
      {key:'x', altKey:true}, {key:'a', repeat:true}, {key:'a', isComposing:true}, {key:'Tab'}]) {
      assert.equal(E.eventKey(e), null);
    }
  });
  test('another binding for the same command is a valid answer', () => {
    const alternative = { ...card, id:'SPC x:buffer', keys:[' ', 'x'] };
    const s = E.begin(card, [card, alternative]);
    E.press(s, ' ');
    assert.equal(E.press(s, 'x'), 'complete');
    assert.equal(s.card.id, alternative.id);
  });
  test('new and missed cards precede mastered cards without consecutive duplicates', () => {
    const cards = [card, { ...card, id:'new' }, { ...card, id:'weak' }];
    const progress = { [card.id]:{clean:8, misses:0, seen:8}, weak:{clean:0, misses:3, seen:3} };
    assert.notEqual(E.choose(cards, progress, null, () => 0).id, card.id);
    assert.notEqual(E.choose(cards, progress, 'new', () => 0).id, 'new');
    assert.equal(E.choose([], {}, null), null);
  });
  test('hints do not award unaided recall and corrupt progress is discarded', () => {
    const s = E.begin(card); s.hinted = true;
    E.press(s, ' '); E.press(s, 'b');
    const p = E.record({}, s);
    assert.equal(p[card.id].clean, 0);
    assert.equal(p[card.id].seen, 1);
    assert.deepEqual(E.cleanProgress({ x: {seen:-1}, y:null }), {});
    assert.deepEqual(E.cleanProgress(null), {});
    assert.deepEqual(E.cleanProgress(p), p);
  });
  test('three consecutive unaided recalls graduate a previously missed binding', () => {
    let p = {};
    const answer = hinted => {
      const s = E.begin(card); s.hinted = hinted;
      E.press(s, ' '); E.press(s, 'b'); p = E.record(p, s);
    };
    answer(true);
    assert.equal(E.needsPractice(p[card.id]), true);
    answer(false); answer(false); answer(false);
    assert.equal(E.needsPractice(p[card.id]), false);
    answer(true);
    assert.equal(E.needsPractice(p[card.id]), true);
  });
}
