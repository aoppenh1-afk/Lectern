// Node-only regression checks for the sample demo. No browser or dependencies.
import assert from 'node:assert/strict';
import { mountDemo } from '../assets/demo.js';
import { DEMO_DATA as D } from '../assets/demo-data.js';
const handlers = new Map();
const timers = new Map();
let timerKey = 0;
globalThis.document = { activeElement: null };
globalThis.setInterval = callback => { timers.set(++timerKey, callback); return timerKey; };
globalThis.clearInterval = key => timers.delete(key);
const root = {
  innerHTML: '',
  contains: node => !!node?.control,
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener: (name, callback) => handlers.set(name, callback),
  dispatchEvent: () => true
};
const demo = mountDemo(root);
function click(act, id) {
  const button = { control: true, getAttribute: name => ({ 'data-act': act, 'data-id': id })[name] ?? null };
  handlers.get('click')({ target: { closest: () => button } });
}
assert.match(root.innerHTML, /Today’s Command Studio/);
assert.match(root.innerHTML, /ld-sidebar-term/);
for (const section of ['overview','calendar','assignments','courses','subscriptions','grades','resources','announcements','aiChat']) {
  click('nav', section);
  assert.equal(demo.getState().explored.section, section);
  assert.ok(root.innerHTML.includes('ld-content'));
  assert.ok(!root.innerHTML.includes('>Unavailable<'));
}
demo.reset();
demo.showStep('transcript');
assert.match(root.innerHTML, /ld-course-column/);
assert.match(root.innerHTML, /ld-lecture-column/);
assert.match(root.innerHTML, /ld-document-column/);
click('tab', 'cleaned');
assert.match(root.innerHTML, /CLEANED TRANSCRIPT/);
click('generate');
assert.equal(demo.getState().explored.tab, 'notes');
demo.showStep('flashcards');
click('flip', 'm1');
assert.equal(demo.getState().explored.tab, 'cards', 'first click adopts the visible tour panel');
assert.equal(demo.getState().flipped.m1, true);
assert.match(root.innerHTML, /Encoding, storage, retrieval/);
click('next-card');
assert.equal(demo.getState().deckIndex.memory, 1);
click('sample', 'l-shiur');
assert.equal(demo.getState().deckIndex.shiur, 0);
click('flip', 's1');
assert.match(root.innerHTML, /lang="he" dir="rtl">תרשישה/);
click('sample', 'l-memory');
assert.equal(demo.getState().deckIndex.memory, 1);
click('tab', 'quiz');
assert.match(root.innerHTML, /id="ld-tab-quiz" aria-controls="ld-panel-quiz" tabindex="0"/);
assert.match(root.innerHTML, /id="ld-panel-quiz" aria-labelledby="ld-tab-quiz"/);
click('answer', 'q1:1');
assert.equal(demo.getState().quiz.q1, 1);
assert.match(root.innerHTML, /Not quite/);
click('answer', 'q1:0');
assert.equal(demo.getState().quiz.q1, 1, 'answered questions cannot be overwritten');
click('retake');
assert.deepEqual(demo.getState().quiz, {});
assert.equal(demo.getState().explored.tab, 'quiz');
for (const q of D.memory.quiz) click('answer', `${q.id}:${q.answer}`);
assert.match(root.innerHTML, /Score: 3 of 3 answered/);
click('nav', 'overview');
click('rec-start');
click('rec-start');
assert.equal(timers.size, 1, 'only one capture timer');
for (const tick of timers.values()) tick();
assert.equal(demo.getState().rec.seconds, 1);
click('rec-stop');
assert.equal(timers.size, 0);
assert.match(root.innerHTML, /Review transcript/);
click('open-lecture', 'l-memory');
assert.equal(demo.getState().explored.tab, 'transcript');
click('tab', 'notes');
click('docs-push');
assert.match(root.innerHTML, /just now \(simulated\)/);
click('nav', 'aiChat');
const form = { control: true, querySelector: () => ({ value: '<img src=x onerror=alert(1)> retrieval' }) };
handlers.get('submit')({ target: { closest: selector => selector === '[data-form="chat"]' ? form : null }, preventDefault() {} });
assert.match(root.innerHTML, /&lt;img/);
assert.ok(!root.innerHTML.includes('<img src=x'));
assert.match(root.innerHTML, /closing the book and self-testing/);
// Workspace controls retain state when navigating between tabs.
click('nav','calendar');
click('calendar-move','1');
assert.equal(demo.getState().workspace.date,'2026-10-01');
click('calendar-day','2026-09-09');
assert.match(root.innerHTML,/Memory chapter review/);
assert.equal(demo.getState().workspace.calendarMode,'Day');
click('calendar-mode','Week');
assert.match(root.innerHTML,/ld-week/);
click('nav','assignments');
click('assignment-filter','Submitted');
assert.match(root.innerHTML,/No assignments/);
click('assignment-filter','Upcoming');
click('assignment-open','0');
assert.match(root.innerHTML,/Explain encoding/);
click('reader-close');
click('nav','grades');
click('grade','c-bio');
assert.match(root.innerHTML,/ld-grade-detail/);
click('nav','resources');
click('module','2');
assert.match(root.innerHTML,/Yonah 1 source sheet/);
click('resource-open','2');
assert.match(root.innerHTML,/Read Yonah/);
click('nav','announcements');
click('announcement','1');
assert.match(root.innerHTML,/Rabbi D. Levi · Yesterday/);
click('nav','subscriptions');
click('subscription-pause','0');
assert.equal(demo.getState().workspace.paused[0],true);
click('subscription-check','all');
assert.equal(demo.getState().workspace.checked[1],true);
click('subscription-delete','0');
assert.ok(!root.innerHTML.includes('BIO 101 lecture series'));
click('nav','settings');
for(const name of ['General','Notifications','Appearance','Recording','Transcription','Retention','Canvas','Anki','Google Docs','Agents']){
 click('settings-tab',name);
 assert.ok(root.innerHTML.includes('ld-setting-row'));
}
click('setting-toggle','notifications');
assert.equal(demo.getState().workspace.preferences.notifications,false);
click('nav','aiChat');
click('source-toggle','resource-0');
assert.match(root.innerHTML,/4 selected/);
click('source-toggle','l-memory');
handlers.get('submit')({target:{closest:selector=>selector==='[data-form="chat"]'?form:null},preventDefault(){}});
assert.match(root.innerHTML,/Select the memory lecture/);
click('chat-clear');
assert.ok(!root.innerHTML.includes('&lt;img'));
// Verify the actual CSV payload without a browser download.
click('open-lecture', 'l-memory');
click('tab', 'cards');
let exported;
const originalCreate = URL.createObjectURL;
const originalRevoke = URL.revokeObjectURL;
URL.createObjectURL = blob => { exported = blob; return 'blob:sample'; };
URL.revokeObjectURL = () => {};
document.createElement = () => ({ click() {}, remove() {} });
root.appendChild = () => {};
click('csv');
assert.match(await exported.text(), /"front","back"/);
assert.match(await exported.text(), /Name the three stages/);
URL.createObjectURL = originalCreate;
URL.revokeObjectURL = originalRevoke;
demo.reset();
demo.reset();
assert.equal(demo.getState().mode, 'tour');
assert.deepEqual(demo.getState().quiz, {});
assert.deepEqual(demo.getState().flipped, {});
assert.equal(demo.getState().rec.seconds, 0);
assert.equal(demo.getState().docsPushedAt, null);
assert.deepEqual(demo.getState().workspace.preferences, {});
assert.deepEqual(demo.getState().workspace.removed, {});
assert.equal(timers.size, 0);
console.log('PASS: 9 workspace sections plus 10 settings panes, calendar navigation, filters, readers, grade details, subscriptions, source selection, tour adoption, bilingual decks, quiz scoring and retake, recording lifecycle, export simulation, chat escaping, reset.');
