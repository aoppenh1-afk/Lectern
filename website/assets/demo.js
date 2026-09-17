// Lectern website demo. Faithful sample of the Mac app shell and study flow.
// Simulated locally: no microphone, files, auth, uploads, or network calls.
// Imported by story.js; never self-mounts. Contract:
//   mountDemo(root) -> { showStep(step), setMode(mode), reset(), getState() }
import { DEMO_DATA } from "./demo-data.js";

const D = DEMO_DATA;

const SECTIONS = [
  { id: "overview", title: "Overview" },
  { id: "calendar", title: "Calendar" },
  { id: "assignments", title: "Assignments" },
  { id: "courses", title: "Courses" },
  { id: "subscriptions", title: "Subscriptions" },
  { id: "grades", title: "Grades" },
  { id: "resources", title: "Resources" },
  { id: "announcements", title: "Announcements" },
  { id: "aiChat", title: "AI Chat" }
];

// Fine-line 16px stroke icons (SVG, not emoji).
const ICONS = {
  app: '<path d="M2 5h12L8 2zM2 14h12M3 12h10M4 7v4M8 7v4M12 7v4"/>',
  overview: '<path d="M1.5 7L8 1.5 14.5 7M3.5 6v8h3V9h3v5h3V6"/>',
  calendar: '<rect x="2.5" y="3.5" width="11" height="10" rx="1.5"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/>',
  assignments: '<path d="M4 4.5l1.2 1.2L7.5 3.5M4 9l1.2 1.2 2.3-2.2M4 13.5l1.2 1.2 2.3-2.2M9.5 4.5H14M9.5 9H14M9.5 13.5H14"/>',
  courses: '<path d="M3 4.5A1.5 1.5 0 0 1 4.5 3H13v9.5H4.7A1.7 1.7 0 0 0 3 14.2zM3 4.5v9.7M13 12.5H4.7A1.7 1.7 0 0 0 3 14.2"/>',
  subscriptions: '<path d="M2.5 9.5a5 5 0 0 1 11 0M4.8 11.5a2.2 2.2 0 0 1 6.4 0"/><circle cx="8" cy="13.4" r="1"/>',
  grades: '<path d="M2.5 13.5h11M4.5 13.5V9.5M8 13.5v-6M11.5 13.5V5"/>',
  resources: '<path d="M2.5 4.5A1 1 0 0 1 3.5 3.5h3l1.2 1.5h4.8a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1z"/>',
  announcements: '<path d="M13.5 3.5a5.5 5.5 0 0 0-9.7 2.6L2.5 7l1.3.9a5.5 5.5 0 0 0 9.7 2.6zM5 10v3.5"/>',
  aiChat: '<path d="M8 2.5l1.2 3.3 3.3 1.2-3.3 1.2L8 11.5l-1.2-3.3L3.5 7l3.3-1.2zM12.5 10.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"/>'
};
function icon(id) {
  return '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[id] || "") + "</svg>";
}

// Lecture tabs mirror the native LectureDetailView tab bar (Raw Transcript,
// Notes, Cards, Quiz). Capture and Docs have no native tab; they live as
// toolbar actions, like the native record button and GoogleDocsNotesBar.
const TABS = [
  { id: "transcript", title: "Raw Transcript" },
  { id: "cleaned", title: "Cleaned" },
  { id: "notes", title: "Notes" },
  { id: "cards", title: "Cards" },
  { id: "quiz", title: "Quiz" }
];

const STEP_TO_VIEW = {
  overview: { section: "overview", lectureId: null, tab: "transcript", spot: null },
  capture: { section: "courses", lectureId: "l-memory", tab: "transcript", spot: "capture" },
  transcript: { section: "courses", lectureId: "l-memory", tab: "transcript", spot: null },
  notes: { section: "courses", lectureId: "l-memory", tab: "notes", spot: null },
  flashcards: { section: "courses", lectureId: "l-memory", tab: "cards", spot: null },
  quiz: { section: "courses", lectureId: "l-memory", tab: "quiz", spot: null },
  docs: { section: "courses", lectureId: "l-memory", tab: "notes", spot: "docs" }
};

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function fmtTime(sec) {
  const m = Math.floor(sec / 60), s = sec % 60;
  return String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0");
}
function lectureOf(id) { return D.lectures.find((l) => l.id === id) || D.lectures[0]; }
function courseOf(id) { return D.courses.find((c) => c.id === id) || D.courses[0]; }
function setOf(lectureId) { return lectureOf(lectureId).sampleSet === "shiur" ? D.shiur : D.memory; }
function freshNav() { return { section: "overview", courseId: "c-bio", lectureId: null, tab: "transcript", spot: null }; }
function seedChat() { return [{ who: "bot", text: "Sample chat over the open lecture. Ask about retrieval practice, encoding, or sleep. Local sample, no AI calls." }]; }

function freshWorkspace() { return { calendarMode: 'Month', date: '2026-09-07', assignmentFilter: 'Upcoming', course: {}, search: {}, grade: null, module: 'all', kind: 'All', announcement: null, paused: {}, checked: {}, removed: {}, sources: {}, sourcesOpen: true, notice: '', subscriptionForm: false, settingsTab:'General', preferences:{}, reader:null }; }

export function mountDemo(root) {
  if (!root) throw new Error("mountDemo requires a root element");
  let timerId = null;
  const state = {
    mode: "tour",
    tour: freshNav(),
    explored: freshNav(),
    rec: { active: false, seconds: 0, saved: false, lang: "en" },
    flipped: {},
    quiz: {},
    deckIndex: { memory: 0, shiur: 0 },
    docsPushedAt: null,
    workspace: freshWorkspace(),
    chat: seedChat()
  };
  const visible = () => (state.mode === "tour" ? state.tour : state.explored);
  // Which nav last painted the DOM. User actions adopt the visible nav when
  // this is "tour", so a click lands on the tour preview, not stale state.
  let lastRendered = "tour";

  function stopTimer() { if (timerId !== null) { clearInterval(timerId); timerId = null; } }

  // Dispatch before any user-caused state change so story.js can enter Explore mode.
  function interact() {
    root.dispatchEvent(new CustomEvent("lectern:interact", { bubbles: true }));
  }

  function paint(nav, tag) {
    const prev = root.contains(document.activeElement) ? document.activeElement.getAttribute("data-fkey") : null;
    root.innerHTML = shell(nav);
    lastRendered = tag;
    if (prev) {
      const el = root.querySelector('[data-fkey="' + prev + '"]');
      if (el) el.focus({ preventScroll: true });
    }
    // Programmatic paints never move focus elsewhere. No heading focus here.
  }

  function render() {
    paint(visible(), state.mode === "tour" ? "tour" : "explored");
  }

  // ---- user actions (all dispatch lectern:interact first) ----
  // User navigation always writes to state.explored, so the tour preview in
  // state.tour survives intact. A user action also switches visible mode to
  // explore; story.js observes lectern:interact and calls setMode("explore").
  function renderExplored(fkey, navigated) {
    state.mode = "explore";
    const prev = fkey || (root.contains(document.activeElement) ? document.activeElement.getAttribute("data-fkey") : null);
    root.innerHTML = shell(state.explored);
    lastRendered = "explored";
    const head = root.querySelector(".ld-content h2");
    if (head && !head.hasAttribute("tabindex")) head.setAttribute("tabindex", "-1");
    const el = prev ? root.querySelector('[data-fkey="' + prev + '"]') : null;
    if (el && !el.disabled) { el.focus({ preventScroll: true }); return; }
    if (el && el.disabled) {
      // The activated control answered and disabled itself (quiz option).
      // Move focus to the result, not body.
      const fb = root.querySelector('.ld-content .ld-feedback[tabindex="-1"]');
      if (fb) { fb.focus({ preventScroll: true }); return; }
    }
    // The initiating control is gone after navigation. Focus the new panel
    // heading so keyboard users land somewhere meaningful, not body.
    // Only for user navigation, never for scroll-driven previews.
    if (navigated && head) head.focus({ preventScroll: true });
  }

  // Local CSV download of the sample deck. No network, no file picker.
  function downloadCSV(lectureId) {
    const set = setOf(lectureId);
    const rows = [["front", "back"]].concat(set.cards.map((c) => [c.front, [c.backHe, c.back].filter(Boolean).join(" ")]));
    const csv = rows.map((r) => r.map((cell) => '"' + String(cell).replace(/"/g, '""') + '"').join(",")).join("\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    const a = document.createElement("a");
    a.href = url; a.download = "lectern-sample-cards.csv";
    root.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  // ---- templates ----
  function shell(nav) {
    const active = nav;
    const counts = { assignments: D.deadlines.length, announcements: D.announcements.length };
    return (
      '<div class="ld-topbar"><span aria-hidden="true">' + icon("courses") + '</span>' +
      '<span class="ld-appname">Lectern</span>' +
      '<span class="ld-term">Academic term · ' + esc(D.term) + '</span></div>' +
      '<div class="ld-navselect"><label class="ld-sr" for="ld-navsel">Demo section</label>' +
      '<select id="ld-navsel" data-change="mnav" data-fkey="mnav">' +
      SECTIONS.concat([{id:'settings',title:'Settings'}]).map((s) => '<option value="' + s.id + '"' + (s.id === active.section ? " selected" : "") + ">" + esc(s.title) + "</option>").join("") +
      "</select></div>" +
      '<div class="ld-window-dots" aria-hidden="true"><i></i><i></i><i></i></div><div class="ld-body" style="--ld-moss:' + ({Blue:'#2f6bed',Plum:'#7c4a73',Graphite:'#4a4d52'}[state.workspace.preferences.Accent]||'#1a5336') + '"><nav class="ld-side" aria-label="Demo sections">' +
      '<div class="ld-sidebar-brand">' + icon("app") + '<span>Lectern</span></div>' +
      '<div class="ld-sidebar-term"><label for="ld-term-select"><span>ACADEMIC TERM</span></label><select id="ld-term-select" aria-label="Academic term"><option>' + esc(D.term) + '</option></select></div>' +
      SECTIONS.map((s) =>
        '<button type="button" class="ld-navbtn" data-act="nav" data-id="' + s.id + '" data-fkey="nav-' + s.id + '"' +
        (s.id === active.section ? ' aria-current="page"' : "") + ">" + icon(s.id) +
        "<span>" + esc(s.title) + "</span>" +
        (counts[s.id] ? '<span class="ld-count">' + counts[s.id] + "</span>" : "") + "</button>"
      ).join("") +
      '<div class="ld-sidefoot"><button type="button" class="ld-link" data-act="nav" data-id="settings" data-fkey="settings">⚙ &nbsp; Settings</button></div></nav>' +
      '<div class="ld-content' + (nav.section === 'courses' ? ' ld-library-content' : '') + '" role="region" aria-label="Demo content">' + content(active) + "</div></div>"
    );
  }

  function content(nav) {
    switch (nav.section) {
      case "overview": return vOverview();
      case "calendar": return vCalendar();
      case "assignments": return vAssignments();
      case "courses": return vLibrary(nav);
      case "settings": return vSettings();
      case "subscriptions": return vSubscriptions();
      case "grades": return vGrades();
      case "resources": return vResources();
      case "announcements": return vAnnouncements();
      case "aiChat": return vChat();
      default: return vSimple("Unavailable", "Outside the sample", "<div class='ld-empty'>This section is outside the sample. The Mac app shows live data here.</div>", "");
    }
  }

  function vSimple(title, eyebrow, inner, foot) {
    return '<p class="ld-eyebrow">' + esc(eyebrow) + '</p><h2 class="ld-h1 ld-doc-title">' + esc(title) + "</h2>" +
      '<div class="ld-card">' + inner + "</div>" + (foot ? '<p class="ld-note">' + esc(foot) + "</p>" : "");
  }

  function vOverview() {
    const next = D.deadlines[0];
    return '<div class="ld-overview-head"><div><p class="ld-greeting">Good morning</p>' +
      '<h2 class="ld-h1 ld-doc-title">Today’s Command Studio</h2>' +
      '<p class="ld-sub">Monday, September 7</p></div>' +
      '<div class="ld-metrics"><div><strong>3</strong><span>Classes</span></div><div><strong>Memory review</strong><span>' + esc(next.tag) + '</span></div><div><strong>3.67</strong><span>Est. GPA</span></div></div></div>' +
      '<div class="ld-grid">' +
      '<section class="ld-card" aria-label="Active session"><h3>Active session</h3>' +
      '<p style="margin:0 0 4px"><span class="ld-dot' + (state.rec.active ? " live" : "") + '" style="display:inline-block" aria-hidden="true"></span> ' +
      "<strong>" + (state.rec.active ? "SAMPLE RECORDING" : state.rec.saved ? "SAMPLE SAVED" : "READY TO RECORD") + '</strong> <span class="ld-timer" role="timer">' + fmtTime(state.rec.seconds) + "</span></p>" +
      "<p><strong>Biology 101: Memory and Learning</strong></p>" +
      '<p class="ld-note">9:00 AM · Room 204 · Simulated capture, no microphone used.</p>' +
      (state.rec.active
        ? '<button type="button" class="ld-btn danger" data-act="rec-stop" data-fkey="ov-stop">Stop sample</button>'
        : '<button type="button" class="ld-btn ld-btnprimary" data-act="rec-start" data-fkey="ov-start">Start sample recording</button>') +
      (state.rec.saved ? '<p class="ld-note" role="status">Sample saved. <button type="button" class="ld-link" data-act="open-lecture" data-id="l-memory" data-fkey="ov-review">Review transcript</button></p>' : '') +
      "</section>" +
      '<section class="ld-card" aria-label="Today schedule"><h3>Today\u2019s schedule</h3>' +
      D.schedule.map((e) => '<div class="ld-row"><span class="ld-time">' + esc(e.time) + "</span><div><div><strong>" + esc(e.title) + "</strong></div><div class='ld-note'>" + esc(e.meta) + "</div></div></div>").join("") +
      '<button type="button" class="ld-link" data-act="nav" data-id="calendar" data-fkey="ov-cal">View calendar</button></section>' +
      '<section class="ld-card" aria-label="Upcoming work"><h3>Upcoming work &amp; deadlines</h3>' +
      D.deadlines.map((dl) => '<div class="ld-row"><div><div><strong>' + esc(dl.course + ": " + dl.title) + "</strong></div><div class='ld-note'>" + esc(dl.due + " · " + dl.points) + '</div></div><span class="ld-pill">' + esc(dl.tag) + "</span></div>").join("") +
      '<button type="button" class="ld-link" data-act="nav" data-id="assignments" data-fkey="ov-assign">View all</button></section>' +
      '<section class="ld-card" aria-label="Faculty bulletins"><h3>Faculty bulletins</h3>' +
      D.announcements.map((a) => '<div class="ld-row"><div><div><strong>' + esc(a.title) + "</strong></div><div class='ld-note'>" + esc(a.course + " · " + a.when) + "</div></div></div>").join("") +
      '<button type="button" class="ld-link" data-act="nav" data-id="announcements" data-fkey="ov-ann">View all</button></section>' +
      "</div>" +
      '<section class="ld-standing" aria-label="Course standing"><div class="ld-standing-head"><h3>Course standing</h3><button type="button" class="ld-link" data-act="nav" data-id="grades" data-fkey="ov-grades">Open grades</button></div><div class="ld-standing-grid">' +
      D.courses.map((c) => '<div class="ld-card"><div class="ld-standing-head"><strong>' + esc(c.code) + '</strong><span>' + esc(c.grade) + '</span></div><div class="ld-grade">' + c.score.toFixed(1) + '%</div><div class="ld-bar" role="img" aria-label="' + esc(c.code + ' ' + c.score + ' percent') + '"><span style="width:' + c.score + '%"></span></div><p class="ld-note">' + esc(c.instructor) + '</p></div>').join("") +
      '</div><button type="button" class="ld-link" data-act="open-lecture" data-id="l-memory" data-fkey="ov-open">Open the sample lecture</button></section>';

  }

  function pageHeader(title, subtitle) {
    return '<header class="ld-page-head"><h2 class="ld-h1 ld-doc-title">' + title + '</h2><p>' + subtitle + '</p></header>';
  }
  function control(act, id, label, selected = false) {
    const labelText=act==='calendar-move'?(id==='-1'?'Previous period':'Next period'):act==='grade'&&!id?'Close grade details':act==='setting-toggle'?id+': '+label:null;
    return '<button type="button"'+(labelText?' aria-label="'+esc(labelText)+'"':'')+' class="ld-control" data-act="' + act + '" data-id="' + esc(id) + '" data-fkey="' + act + '-' + esc(id) + '" aria-pressed="' + selected + '">' + label + '</button>';
  }
  function courseFilter(section) {
    return '<select aria-label="Course" data-change="filter-course" data-section="' + section + '" data-fkey="filter-' + section + '"><option value="all">All courses</option>' + D.courses.map(c => '<option value="' + c.code + '"' + (state.workspace.course[section] === c.code ? ' selected' : '') + '>' + esc(c.name) + '</option>').join('') + '</select>';
  }
  function searchField(section, label) {
    return '<input type="search" aria-label="' + label + '" placeholder="' + label + '" data-search="' + section + '" data-fkey="search-' + section + '" value="' + esc(state.workspace.search[section] || '') + '">';
  }
  function matches(section, course, text) {
    const w = state.workspace;
    return (!w.course[section] || w.course[section] === 'all' || w.course[section] === course) && text.toLowerCase().includes((w.search[section] || '').toLowerCase());
  }
  function empty(title, text = 'Nothing matches this view.') { return '<div class="ld-unavailable"><h3>' + title + '</h3><p>' + text + '</p></div>'; }
  function eventsFor(date) {
    const day = date.toISOString().slice(0,10);
    const events = {
      '2026-09-07': [{ title: 'Biology 101 lecture', hour: 9 }, { title: 'Psychology 210 lecture', hour: 11 }],
      '2026-09-09': [{ title: 'Memory chapter review', hour: 23, due: true }],
      '2026-09-10': [{ title: 'Tanach shiur', hour: 14 }],
      '2026-09-11': [{ title: 'Cognition problem set 4', hour: 17, due: true }]
    };
    return events[day] || [];
  }
  function vCalendar() {
    const w = state.workspace, date = new Date(w.date + 'T12:00:00Z');
    const title = date.toLocaleDateString('en-US', { month: 'long', year: 'numeric', ...(w.calendarMode === 'Day' ? { day: 'numeric', weekday: 'long' } : {}), timeZone: 'UTC' });
    let grid = '';
    const chip = e => '<span class="ld-calendar-chip' + (e.due ? ' due' : '') + '">' + esc(e.title) + '</span>';
    if (w.calendarMode === 'Month') {
      const start = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1, 12)); start.setUTCDate(start.getUTCDate() - start.getUTCDay());
      grid = '<div class="ld-month">' + ['SUN','MON','TUE','WED','THU','FRI','SAT'].map(d => '<div class="ld-weekday">' + d + '</div>').join('') +
        Array.from({length:42}, (_, i) => { const d = new Date(start); d.setUTCDate(d.getUTCDate()+i); return '<button type="button" class="ld-day' + (d.getUTCMonth() !== date.getUTCMonth() ? ' muted' : '') + '" data-act="calendar-day" data-id="' + d.toISOString().slice(0,10) + '" aria-label="' + d.toDateString() + '"><span class="' + (d.toISOString().startsWith('2026-09-07') ? 'today' : '') + '">' + d.getUTCDate() + '</span>' + eventsFor(d).map(chip).join('') + '</button>'; }).join('') + '</div>';
    } else if (w.calendarMode === 'Week') {
      const start = new Date(date); start.setUTCDate(start.getUTCDate()-start.getUTCDay());
      grid = '<div class="ld-week">' + Array.from({length:7}, (_, i) => { const d = new Date(start);d.setUTCDate(d.getUTCDate()+i); return '<div><header>' + d.toLocaleDateString('en-US',{weekday:'short',timeZone:'UTC'}) + '<strong>' + d.getUTCDate() + '</strong></header>' + (eventsFor(d).map(chip).join('') || '<p>No events</p>') + '</div>'; }).join('') + '</div>';
    } else grid = '<div class="ld-day-agenda">' + Array.from({length:24},(_,h) => '<div><time>' + (h%12||12) + ':00 ' + (h<12?'AM':'PM') + '</time><section>' + eventsFor(date).filter(e=>e.hour===h).map(chip).join('') + '</section></div>').join('') + '</div>';
    return pageHeader('Calendar','Your Fall 2026 schedule and Canvas deadlines') + '<div class="ld-filterbar">' + control('calendar-move','-1','‹') + control('calendar-move','1','›') + control('calendar-today','','Today') + '<h3>' + title + '</h3><span class="ld-library-spacer"></span><div class="ld-segmented">' + ['Day','Week','Month'].map(m=>control('calendar-mode',m,m,w.calendarMode===m)).join('') + '</div></div><div class="ld-panel">' + grid + '</div>';
  }
  function vAssignments() {
    const w=state.workspace;
    const items=D.assignments.map((a,i)=>({...a,id:i})).filter(a=>matches('assignments',a.course,a.title+' '+a.course) && (w.assignmentFilter==='All' || w.assignmentFilter==='Upcoming'));
    return pageHeader('Assignments','Fall 2026 work, filterable by course and status') + '<div class="ld-filterbar"><div class="ld-segmented">' + ['Upcoming','Missing','Submitted','All'].map(f=>control('assignment-filter',f,f,w.assignmentFilter===f)).join('') + '</div><span class="ld-library-spacer"></span>' + courseFilter('assignments') + searchField('assignments','Search assignments') + '</div><div class="ld-results">' + (items.map(a=>'<button type="button" class="ld-assignment ld-panel" data-act="assignment-open" data-id="'+a.id+'"><span class="ld-status-circle">○</span><div><strong>'+esc(a.title)+'</strong><small>'+esc(a.course+' · '+a.due+' · '+a.points)+'</small></div><span class="ld-library-spacer"></span><span>'+esc(a.status)+'</span><span>↗</span></button>').join('') || empty('No assignments')) + '</div>' + notice();
  }
  function notice() { if(state.workspace.reader) return sampleReader(state.workspace.reader.kind,state.workspace.reader.id); return state.workspace.notice ? '<div class="ld-inline-notice" role="status">' + esc(state.workspace.notice) + control('dismiss-notice','','Dismiss') + '</div>' : ''; }
  function vGrades() {
    const w=state.workspace, selected=D.courses.find(c=>c.id===w.grade);
    return pageHeader('Grades','Current Canvas standing with assignment-level results') + '<div class="ld-grades-layout"><div class="ld-grade-grid">' + D.courses.map(c=>'<button type="button" class="ld-panel ld-grade-card" data-act="grade" data-id="'+c.id+'"><header><span class="ld-swatch" style="background:'+c.color+'">'+esc(c.name[0])+'</span><div><strong>'+esc(c.code)+'</strong><small>'+esc(c.instructor)+'</small></div><span class="ld-library-spacer"></span><b>'+esc(c.grade)+'</b></header><div class="ld-score">'+c.score.toFixed(1)+'<small>%</small></div><div class="ld-bar"><span style="width:'+c.score+'%"></span></div><p>Canvas has not returned graded assignments yet.</p></button>').join('') + '</div>' + (selected ? '<aside class="ld-panel ld-grade-detail"><header><h3>'+esc(selected.name)+'</h3>'+control('grade','','×')+'</header><p>All Canvas grades</p>'+D.assignments.filter(a=>a.course===selected.code).map(a=>'<div class="ld-kv"><div>'+esc(a.title)+'<small>'+esc(a.due)+'</small></div><strong>— / '+esc(a.points)+'</strong></div>').join('')+'</aside>' : '')+'</div>';
  }
  function resourceItems() { return D.resources.map((r,i)=>({...r,id:i,course:r.meta.split(' · ')[0],module:['Memory and learning','Cognition lab','Yonah 1'][i],kind:'File'})); }
  function vResources() {
    const w=state.workspace, items=resourceItems().filter(r=>matches('resources',r.course,r.name+' '+r.module+' '+r.course));
    const shown=items.filter(r=>(w.module==='all'||w.module===String(r.id))&&(w.kind==='All'||w.kind===r.kind));
    return pageHeader('Resources','Canvas material organized by course, module, and type')+'<div class="ld-filterbar">'+courseFilter('resources')+'<span class="ld-library-spacer"></span>'+searchField('resources','Search resources')+'</div><div class="ld-resources-layout"><aside class="ld-panel ld-module-sidebar"><h3>MODULES <small>'+items.length+'</small></h3>'+control('module','all','All resources',w.module==='all')+items.map(r=>control('module',String(r.id),esc(r.module)+'<small>'+esc(r.course)+'</small>',w.module===String(r.id))).join('')+'</aside><section class="ld-panel ld-resource-library"><header><div><h3>'+(w.module==='all'?'All resources':esc(resourceItems().find(r=>String(r.id)===w.module)?.module||'All resources'))+'</h3><small>Browse every synced Canvas module</small></div><span class="ld-library-spacer"></span>'+['All','File'].map(k=>control('resource-kind',k,k,w.kind===k)).join('')+'</header>'+ (shown.map(r=>'<div class="ld-resource-group"><header><strong>'+esc(r.module)+'</strong><small>'+esc(r.course)+'</small></header><button type="button" data-act="resource-open" data-id="'+r.id+'">'+icon('resources')+'<div>'+esc(r.name)+'<small>'+r.kind+'</small></div><span class="ld-library-spacer"></span>↗</button></div>').join('')||empty('No resources','Nothing matches this course and search.'))+'</section></div>'+notice();
  }
  function vAnnouncements() {
    const w=state.workspace, items=D.announcements.map((a,i)=>({...a,id:i})).filter(a=>matches('announcements',a.course,a.title));
    const selected=items.find(a=>a.id===w.announcement);
    return pageHeader('Announcements','Complete faculty updates for Fall 2026')+'<div class="ld-filterbar">'+courseFilter('announcements')+'</div><div class="ld-panel ld-announcements"><aside>'+items.map(a=>'<button type="button" data-act="announcement" data-id="'+a.id+'" aria-pressed="'+(a.id===w.announcement)+'"><header>'+esc(a.course)+'<small>'+esc(a.when)+'</small></header><h3>'+esc(a.title)+'</h3><p>'+esc(a.body)+'</p></button>').join('')+'</aside><article>'+(selected?'<p class="ld-eyebrow">'+esc(selected.course)+'</p><h2>'+esc(selected.title)+'</h2><p class="ld-note">'+esc(selected.author+' · '+selected.when)+'</p><hr><p>'+esc(selected.body)+'</p>':empty('Select an announcement','The complete announcement will appear here.'))+'</article></div>';
  }
  function vSubscriptions() {
    const w=state.workspace, items=D.subscriptions.map((a,i)=>({...a,id:i})).filter(a=>!w.removed[a.id]&&a.name.toLowerCase().includes((w.search.subscriptions||'').toLowerCase()));
    return '<div class="ld-subscription-head">'+pageHeader('Subscriptions','Automatically discover, download, and turn new shiurim into notes.')+'<div>'+control('subscription-form','','Paste YU Torah Link…')+control('subscription-check','all','Check All')+'</div></div>'+searchField('subscriptions','Search YU Torah: teachers, shiurim, collections, series…')+'<p class="ld-list-label">ACTIVE SUBSCRIPTIONS ('+items.filter(a=>!w.paused[a.id]).length+')</p>'+items.map(a=>'<div class="ld-panel ld-subscription-row">'+icon('subscriptions')+'<div><strong>'+esc(a.name)+'</strong> <span class="ld-pill">'+(w.paused[a.id]?'Paused':'Collection')+'</span> <small>Every 6 hours</small><p>Auto-transcribe · Clean up transcript &amp; note taking · '+(w.checked[a.id]?'Checked just now · No new sample recordings':'Imported: 1')+'</p></div><span class="ld-library-spacer"></span>'+control('subscription-check',String(a.id),'Check Now')+control('subscription-pause',String(a.id),w.paused[a.id]?'Resume':'Pause')+control('subscription-delete',String(a.id),'Remove')+'</div>').join('')+(!items.length?empty('No subscriptions','No sample subscriptions match your search. Reset the sample to restore removed subscriptions.'):'')+(w.subscriptionForm?'<form data-form="subscription" class="ld-panel ld-subscription-form"><h3>Add a subscription</h3><label>YU Torah link<input required type="url" name="url" placeholder="https://www.yutorah.org/…"></label><p class="ld-note">Preview only. This does not connect to YU Torah.</p><button class="ld-btn" type="submit">Preview subscription</button>'+control('subscription-form','','Cancel')+'</form>':'')+notice();
  }

  function vSettings() {
    const w=state.workspace;
    const sections=['General','Notifications','Appearance','Recording','Transcription','Retention','Canvas','Anki','Google Docs','Agents'];
    const row=(title,caption,field)=>'<div class="ld-setting-row"><div><strong>'+title+'</strong><small>'+caption+'</small></div>'+field+'</div>';
    const toggle=(id,on=true)=>control('setting-toggle',id,w.preferences[id]??on?'On':'Off',w.preferences[id]??on);
    const select=(id,values)=>'<select aria-label="'+id+'" data-change="preference" data-key="'+id+'">'+values.map(v=>'<option'+((w.preferences[id]||values[0])===v?' selected':'')+'>'+v+'</option>').join('')+'</select>';
    const connection=(name)=>row(name,'Sample connection. No account or credentials are used.',control('connection',name,'Preview connection'));
    let panel='';
    switch(w.settingsTab){
      case 'General': panel=row('Lectern','Interactive Mac app sample',control('connection','Updates','Check for updates'))+row('Check automatically','Every time Lectern opens.',toggle('updates'))+row('Status','You are exploring the website sample.','✓');break;
      case 'Notifications': panel=row('Allow notifications','Sample preference only.',toggle('notifications'))+row('Transcription completed','Notify when a lecture is ready.',toggle('transcriptionNotice'))+row('Study materials completed','Notify when notes, cards, and quizzes are ready.',toggle('studyNotice'));break;
      case 'Appearance': panel=row('Theme','This classroom demo shows the light appearance.','Light')+row('Accent','Brand color for selections and highlights.',select('Accent',['Moss','Blue','Plum','Graphite']));break;
      case 'Recording': panel=row('Capture source','Choose what the sample recording represents.',select('Capture source',['Microphone','System audio','Microphone + system audio']))+row('Record hotkey','Start or stop a recording.','⌥ Space')+row('Menu-bar popover','Recording controls from the menu bar icon.',toggle('menuBar'))+row('Notch pill during recording','Show the recording status.',toggle('notch'))+row('Hebrew + English (shiurim)','Use bilingual transcription.',toggle('bilingual',false));break;
      case 'Transcription': panel=row('Transcription provider','Sample preference. No audio is uploaded.',select('Provider',['On this Mac','Gemini','Deepgram','AssemblyAI']))+row('Automatic transcription','Transcribe after a recording finishes.',toggle('autoTranscribe'));break;
      case 'Retention': panel=row('Keep lecture audio','Choose how long recordings stay in the library.',select('Keep audio',['Forever','30 days','7 days']));break;
      case 'Canvas': panel=connection('Canvas')+row('Sync courses','Sample courses and deadlines are loaded.',toggle('sync'));break;
      case 'Anki': panel=row('AnkiConnect port','Default local connection port.','8765')+row('Flashcards','Try a deck in the sample lecture.',control('open-lecture','l-memory','Open lecture'));break;
      case 'Google Docs': panel=row('Google Docs','One document per course and one tab per lecture.','')+connection('Google Docs');break;
      case 'Agents': panel=connection('Antigravity')+connection('ChatGPT (Codex)')+connection('OpenCode');break;
    }
    return '<div class="ld-settings"><nav aria-label="Settings sections"><h3>Settings</h3>'+sections.map(s=>control('settings-tab',s,s,w.settingsTab===s)).join('')+'</nav><section><h2>'+w.settingsTab+'</h2><div class="ld-panel">'+panel+'</div>'+notice()+'</section></div>';
  }
  function sampleReader(kind,id) {
    const a=kind==='assignment'?D.assignments[id]:resourceItems()[id];
    if(!a)return '';
    const course=a.course;
    const paragraphs=course==='BIO 101'?['Explain encoding, storage, and retrieval in your own words. Give one example of each.','Compare retrieval practice with rereading. Plan two short study sessions on different days and leave time for sleep.']:course==='TAN 201'?['Read Yonah 1:1–3. Trace the direction of the journey before interpreting why Yonah leaves.','Keep this question open: is the flight a physical escape, refusal of the mission, or both? Return to it after chapter three.']:['Compare recall after rereading with recall after self-testing. Keep study time equal in both conditions.','Record the number of correct answers, describe one possible confound, and explain how you would control it.'];
    return '<article class="ld-panel ld-sample-reader"><header><div><p class="ld-eyebrow">'+esc(course)+' · SAMPLE '+kind.toUpperCase()+'</p><h3>'+esc(a.title||a.name)+'</h3></div>'+control('reader-close','','Close preview')+'</header>'+(kind==='assignment'?'<p class="ld-note">Due '+esc(a.due)+' · '+esc(a.points)+'</p>':'')+paragraphs.map(p=>'<p>'+esc(p)+'</p>').join('')+control('open-lecture',course==='TAN 201'?'l-shiur':'l-memory','Open related sample lecture')+'</article>';
  }

  function vLibrary(nav) {
    const course = courseOf(nav.courseId);
    const lectures = D.lectures.filter(l => l.courseId === nav.courseId);
    const action = (act, label, id = "", extra = "") => '<button type="button" class="ld-library-action" data-act="' + act + '" data-id="' + id + '" data-fkey="library-' + act + '" ' + extra + '>' + label + '</button>';
    return '<div class="ld-library-toolbar">' +
      action(state.rec.active ? 'rec-stop' : 'rec-start', '<span class="ld-record-dot"></span>' + (state.rec.active ? 'Stop recording' : 'Record')) +
      action('generate', '✧ &nbsp; Generate', '', nav.lectureId ? '' : 'disabled') +
      action('nav', '✧ &nbsp; AI Chat', 'aiChat') + '<span class="ld-library-spacer"></span>' +
      action('share', '↥ &nbsp; Share', '', nav.lectureId ? '' : 'disabled') + '</div>' +
      '<div class="ld-library-columns"><aside class="ld-course-column" aria-label="Course library"><label class="ld-sr" for="ld-course-search">Search courses</label><input id="ld-course-search" data-fkey="course-search" placeholder="Search" type="search">' +
      '<div class="ld-library-heading">Courses</div>' + D.courses.map(c => '<button type="button" class="ld-library-course" data-course-name="' + esc(c.name) + '" data-act="course" data-id="' + c.id + '" data-fkey="course-' + c.id + '" aria-current="' + (c.id === nav.courseId) + '"><span class="ld-swatch" style="color:' + c.color + ';background:' + c.color + '20">' + icon('courses') + '</span><span>' + esc(c.name) + '</span><small>' + D.lectures.filter(l => l.courseId === c.id).length + '</small></button>').join('') + '</aside>' +
      '<aside class="ld-lecture-column" aria-label="Lectures"><div class="ld-library-heading"><strong>' + esc(course.name) + '</strong><small>' + lectures.length + ' lectures</small></div><p class="ld-library-date">This week</p>' +
      lectures.map(l => '<button type="button" class="ld-library-lecture" data-act="open-lecture" data-id="' + l.id + '" data-fkey="open-' + l.id + '" aria-current="' + (l.id === nav.lectureId) + '"><strong>' + esc(l.title) + '</strong><span>' + esc(course.code + ' · ' + l.date + ' · ' + l.duration) + '</span><small>✓ Ready</small></button>').join('') +
      (!lectures.length ? '<p class="ld-note">No sample lectures in this course.</p>' : '') + '</aside>' +
      '<div class="ld-document-column">' + (nav.lectureId ? vLecture(nav) : vLibraryHome()) + '</div></div>';
  }

  function vLibraryHome() {
    return '<h2 class="ld-doc-title ld-h1">Home</h2><div class="ld-library-stats">' +
      [['2','Lectures'],['6','Materials'],['6','Flashcards'],['2','Ready']].map(([n,label]) => '<div class="ld-card"><strong>' + n + '</strong><span>' + label + '</span></div>').join('') +
      '</div><h3>Recent lectures</h3>' + D.lectures.map(l => '<button type="button" class="ld-library-recent" data-act="open-lecture" data-id="' + l.id + '" data-fkey="recent-' + l.id + '"><strong>' + esc(l.title) + '</strong><span>' + esc(courseOf(l.courseId).name + ' · ' + l.date + ' · ' + l.duration) + '</span><small>✓ Ready</small></button>').join('');
  }

  function vLecture(nav) {
    const lec = lectureOf(nav.lectureId);
    const course = courseOf(lec.courseId);
    const set = setOf(lec.id);
    return '<h2 class="ld-doc-title ld-h1">' + esc(lec.title) + '</h2>' +
      '<p class="ld-meta">' + esc(course.name + ' · ' + lec.date + ' · ' + lec.duration + ' · ' + set.cards.length + ' cards · ' + set.quiz.length + ' questions') + '</p>' +
      '<div class="ld-provider"><span>✦</span><div><strong>Transcribed on this Mac</strong><small>Sample transcript · ' + esc(lec.date) + '</small></div></div>' +
      (nav.spot === 'capture' || state.rec.active ? toolbar(lec, nav.spot === 'capture') : '') +
      '<div class="ld-tabs" role="tablist" aria-label="Lecture outputs">' +
      TABS.map((t) => '<button type="button" role="tab" id="ld-tab-' + t.id + '" aria-controls="ld-panel-' + t.id + '" tabindex="' + (nav.tab === t.id ? '0' : '-1') + '" class="ld-tab" data-act="tab" data-id="' + t.id + '" data-fkey="tab-' + t.id + '" aria-selected="' + (nav.tab === t.id) + '">' + esc(t.title) + "</button>").join("") +
      "</div>" +
      '<div role="tabpanel" id="ld-panel-' + nav.tab + '" aria-labelledby="ld-tab-' + nav.tab + '">' + tabPanel(nav, lec, set) + "</div>";
  }

  // Capture entry as a toolbar action, matching the native app where
  // recording is a button, not a tab. Simulated timer, no microphone.
  function toolbar(lec, spot) {
    const r = state.rec;
    return '<div class="ld-toolbar' + (spot ? " ld-spot" : "") + '" role="group" aria-label="Capture, simulated">' +
      '<span class="ld-dot' + (r.active ? " live" : "") + '" aria-hidden="true"></span>' +
      '<span class="ld-timer" role="timer" aria-live="off">' + fmtTime(r.seconds) + "</span>" +
      (r.active
        ? '<button type="button" class="ld-btn danger" data-act="rec-stop" data-fkey="cap-stop">Stop sample</button>'
        : '<button type="button" class="ld-btn ld-btnprimary" data-act="rec-start" data-fkey="cap-start">' + (r.saved ? "Record again" : "Record sample") + "</button>") +
      '<button type="button" class="ld-btn" data-act="rec-reset" data-fkey="cap-reset">Reset</button>' +
      '<span role="group" aria-label="Audio language, sample">' +
      '<button type="button" class="ld-btn' + (r.lang === "en" ? " ld-btnprimary" : "") + '" data-act="lang" data-id="en" data-fkey="lang-en" aria-pressed="' + (r.lang === "en") + '">A</button> ' +
      '<button type="button" class="ld-btn' + (r.lang === "he" ? " ld-btnprimary" : "") + '" data-act="lang" data-id="he" data-fkey="lang-he" aria-pressed="' + (r.lang === "he") + '">A/\u05d0</button></span>' +
      '<span class="ld-note">' + (r.active ? "Recording sample, no microphone." : r.saved ? "Sample saved. Transcription is simulated." : "Simulated capture.") + "</span></div>";
  }

  function tabPanel(nav, lec, set) {
    switch (nav.tab) {
      case "transcript": return pTranscript(lec, set);
      case "cleaned": return '<p class="ld-note">CLEANED TRANSCRIPT · SAMPLE</p><div class="ld-doc">' + set.transcript.map(s => '<p>' + segText(s) + '</p>').join('') + '</div>';
      case "notes": return pNotes(lec, set, nav.spot === "docs");
      case "cards": return pCards(lec, set);
      case "quiz": return pQuiz(lec, set);
      default: return pTranscript(lec, set);
    }
  }

  function segText(s) {
    if (s.quoteHe) {
      return esc(s.text) + ' <span lang="he" dir="rtl">' + esc(s.quoteHe) + "</span> " + esc(s.textAfter || "");
    }
    return esc(s.text);
  }

  function pTranscript(lec, set) {
    return '<p class="ld-note ld-transcript-label">RAW TRANSCRIPT</p>' +
      '<div class="ld-doc">' + set.transcript.map((s) =>
        '<div class="ld-seg"><time>' + esc(s.time) + '</time><div><strong>' + esc(s.speaker) + ':</strong> ' + segText(s) + '</div></div>'
      ).join("") + "</div>";
  }

  function pointHTML(p) {
    if (typeof p === "string") return esc(p);
    return '<span lang="he" dir="rtl">' + esc(p.he) + "</span> " + esc(p.en);
  }

  function pNotes(lec, set, spotDocs) {
    return docsBar(lec, spotDocs) +
      '<p class="ld-note">Outline notes (sample) · left-to-right outline · Hebrew appears in isolated runs</p>' +
      '<div class="ld-doc ld-doc-title" style="font-size:18px;margin-bottom:10px">' + esc(lec.title) + ", outline</div>" +
      '<div class="ld-doc"><ol class="ld-outline" dir="ltr">' + set.notes.map((n) =>
        "<li><strong>" + esc(n.heading) + "</strong><ul class='ld-outline'>" + n.points.map((p) => "<li>" + pointHTML(p) + "</li>").join("") + "</ul></li>"
      ).join("") + "</ol></div>";
  }

  function pCards(lec, set) {
    const key = lec.sampleSet;
    const idx = Math.min(state.deckIndex[key] || 0, set.cards.length - 1);
    const card = set.cards[idx];
    const flipped = !!state.flipped[card.id];
    return '<p class="ld-note">' + set.cards.length + " flashcards · deck, sample · " + set.cards.length + " in deck</p>" +
      '<div class="ld-flash"><p class="ld-flash-q">' + esc(card.front) + "</p>" +
      (card.backHe ? '<p class="ld-note">Answer includes Hebrew:</p>' : "") +
      (flipped ? '<div class="ld-flash-a ld-flashflip">' + (card.backHe ? '<span lang="he" dir="rtl">' + esc(card.backHe) + "</span> " : "") + esc(card.back) + "</div>" : "") +
      '<p style="margin:14px 0 0"><button type="button" class="ld-btn ld-btnprimary" data-act="flip" data-id="' + card.id + '" data-fkey="flip" aria-pressed="' + flipped + '">' + (flipped ? "Hide answer" : "Reveal answer") + "</button></p></div>" +
      '<p style="margin-top:12px"><button type="button" class="ld-btn" data-act="prev-card" data-fkey="prev-card">Previous</button> ' +
      '<span class="ld-note" role="status">Card ' + (idx + 1) + " of " + set.cards.length + "</span> " +
      '<button type="button" class="ld-btn" data-act="next-card" data-fkey="next-card">Next</button> ' +
      '<button type="button" class="ld-btn" data-act="csv" data-fkey="csv">CSV</button></p>';
  }

  function pQuiz(lec, set) {
    let correct = 0, answered = 0;
    const blocks = set.quiz.map((q, qi) => {
      const sel = state.quiz[q.id];
      if (sel !== undefined) { answered++; if (sel === q.answer) correct++; }
      return '<fieldset class="ld-card" style="margin-bottom:10px"><legend><strong>Q' + (qi + 1) + ". " + esc(q.stem) + "</strong></legend>" +
        q.options.map((o, oi) => {
          const cls = sel === undefined ? "" : oi === q.answer ? " ld-right" : oi === sel ? " ld-wrong" : "";
          return '<button type="button" class="ld-quizopt' + cls + '" data-act="answer" data-id="' + q.id + ":" + oi + '" data-fkey="qa-' + q.id + "-" + oi + '"' +
            (sel !== undefined ? " disabled" : "") + (sel === oi ? ' aria-pressed="true"' : "") + ">" + esc(o) + "</button>";
        }).join("") +
        (sel !== undefined
          ? '<div class="ld-feedback ' + (sel === q.answer ? "ok" : "no") + '" role="status" tabindex="-1">' + (sel === q.answer ? "Correct." : "Not quite. The correct answer is highlighted.") + '</div><p class="ld-explain">' + esc(q.explain) + "</p>"
          : "") +
        "</fieldset>";
    }).join("");
    return '<p class="ld-note" role="status">Score: ' + correct + " of " + answered + " answered (" + set.quiz.length + " questions)</p>" + blocks +
      (answered > 0 ? '<p><button type="button" class="ld-btn" data-act="retake" data-fkey="retake">Retake quiz</button></p>' : "");
  }

  // Docs export as a notes-tab bar, matching the native GoogleDocsNotesBar
  // placement: title, "course.doc, tab per lecture", push button. Simulated.
  function docsBar(lec, spot) {
    const course = courseOf(lec.courseId);
    return '<div class="ld-docsbar' + (spot ? " ld-spot" : "") + '">' +
      "<div><strong>Google Docs</strong>" +
      '<div class="ld-note">' + esc(course.name + ".doc · tab per lecture") + "</div></div>" +
      (state.docsPushedAt ? '<span class="ld-pill">Pushed</span>' : "") +
      '<span style="margin-left:auto"></span>' +
      '<button type="button" class="ld-btn ld-btnprimary" data-act="docs-push" data-fkey="docs-push">' + (state.docsPushedAt ? "Push again" : "Push to Docs") + "</button></div>" +
      '<p class="ld-note">Simulated export, no network calls, no Google account. ' +
      (state.docsPushedAt
        ? "Pushed tab \u201c" + esc(lec.title) + "\u201d " + esc(state.docsPushedAt) + ". Pushing again updates the tab."
        : "Not pushed yet in this session.") + "</p>";
  }

  function vChat() {
    const w=state.workspace;
    const lectures=D.lectures.filter(l=>!w.course.aiChat||w.course.aiChat==='all'||courseOf(l.courseId).code===w.course.aiChat);
    const resources=resourceItems().filter(r=>!w.course.aiChat||w.course.aiChat==='all'||r.course===w.course.aiChat);
    return '<div class="ld-ai-workspace"><header><div><h2>✧ &nbsp; AI Assistant</h2><p>Ask questions or create study materials from your sources.</p></div>'+courseFilter('aiChat')+control('sources-panel','','Sources',w.sourcesOpen)+'</header><div class="ld-ai-columns"><section class="ld-ai-conversation"><div class="ld-chatlog" aria-live="polite">'+state.chat.map(m=>'<div class="ld-msg'+(m.who==='user'?' user':'')+'">'+esc(m.text)+'</div>').join('')+'</div><form class="ld-ai-composer" data-form="chat"><label class="ld-sr" for="ld-chatinput">Ask about the sample lecture</label><textarea id="ld-chatinput" data-fkey="chat-input" rows="3" placeholder="Ask about this course…"></textarea><footer><span>✦ Local sample</span><span>Ask</span><span class="ld-library-spacer"></span>'+control('chat-clear','','Clear')+'<button type="submit" class="ld-btn ld-btnprimary" data-fkey="chat-send">Send</button></footer></form></section>'+(w.sourcesOpen?'<aside class="ld-ai-sources ld-panel"><header><strong>Sources</strong><small>'+([...lectures.map(l=>l.id),'canvas'].filter(id=>w.sources[id]!==false).length + resources.filter(r=>w.sources['resource-'+r.id]===true).length)+' selected</small></header><details open><summary>Lectures</summary>'+lectures.map(l=>control('source-toggle',l.id,(w.sources[l.id]!==false?'✓ ':'○ ')+esc(l.title),w.sources[l.id]!==false)).join('')+'</details><details open><summary>Canvas data</summary>'+control('source-toggle','canvas',(w.sources.canvas!==false?'✓ ':'○ ')+'Canvas assignments and grades',w.sources.canvas!==false)+'</details><details open><summary>Course resources</summary>'+resources.map(r=>control('source-toggle','resource-'+r.id,(w.sources['resource-'+r.id]===true?'✓ ':'○ ')+esc(r.module),w.sources['resource-'+r.id]===true)).join('')+'</details></aside>':'')+'</div></div>';
  }

  function chatReply(text) {
    if(state.workspace.course.aiChat==='TAN 201') return state.workspace.sources['l-shiur']===false ? 'Select the Yonah lecture in Sources to ask about this course.' : 'From the sample shiur: Yonah rises to flee to Tarshish. Read the direction first, then ask whether the flight is physical escape, refusal of the mission, or both. Revisit this after chapter three.';
    if(state.workspace.course.aiChat==='PSY 210') return 'This sample course has no recorded lecture yet. Its resources describe comparing recall after rereading with recall after self-testing.';

    if (state.workspace.sources['l-memory'] === false) return "Select the memory lecture in Sources to ask about its sample content.";
    const t = text.toLowerCase();
    for (const p of D.chatPairs) {
      if (p.match.some((k) => t.includes(k))) return p.reply;
    }
    return D.chatFallback;
  }

  // ---- events (delegated; every user-caused path calls interact() first) ----
  // setMode() never renders, so a story pointerdown that flips tour->explore
  // cannot destroy the click target. Adoption below makes the click act on
  // the visible tour lecture/tab instead of stale explored state.
  const NAV_ACTS = { nav: 1, course: 1, "open-lecture": 1, "back-courses": 1, sample: 1, tab: 1 };
  root.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-act]");
    if (!btn || !root.contains(btn)) return;
    const act = btn.getAttribute("data-act");
    const id = btn.getAttribute("data-id");
    interact();
    if (state.mode === "tour") state.mode = "explore";
    if (lastRendered === "tour") state.explored = Object.assign({}, state.tour);
    const t = state.explored;
    t.spot = null;
    if (act === "nav") { state.workspace.reader=null;state.workspace.notice=""; t.section = id; t.lectureId = null; }
    else if (act === "course") { t.section = "courses"; t.courseId = id; t.lectureId = null; }
    else if (act === "open-lecture") { const l = lectureOf(id); t.section = "courses"; t.courseId = l.courseId; t.lectureId = l.id; t.tab = "transcript"; }
    else if (act === "back-courses") { t.section = "courses"; t.lectureId = null; }
    else if (act === "sample") { const l = lectureOf(id); t.section = "courses"; t.courseId = l.courseId; t.lectureId = l.id; }
    else if (act === "tab") { t.tab = id; }
    else if (act === "calendar-mode") state.workspace.calendarMode = id;
    else if (act === "calendar-day") { state.workspace.date=id; state.workspace.calendarMode='Day'; }
    else if (act === "calendar-today") state.workspace.date='2026-09-07';
    else if (act === "calendar-move") { const d=new Date(state.workspace.date+'T12:00:00Z'); const n=Number(id); if(state.workspace.calendarMode==='Month'){d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+n);}else d.setUTCDate(d.getUTCDate()+n*(state.workspace.calendarMode==='Week'?7:1));state.workspace.date=d.toISOString().slice(0,10); }
    else if (act === "assignment-filter") state.workspace.assignmentFilter=id;
    else if (act === "assignment-open") state.workspace.reader={kind:'assignment',id:Number(id)};
    else if (act === "reader-close") state.workspace.reader=null;
    else if (act === "settings-tab") {state.workspace.settingsTab=id;state.workspace.notice='';state.workspace.reader=null;}
    else if (act === "setting-toggle") state.workspace.preferences[id]=!(state.workspace.preferences[id]??!['bilingual'].includes(id));
    else if (act === "connection") state.workspace.notice=id+' preview is ready. Connect your own account in the Mac app.';
    else if (act === "grade") state.workspace.grade=id||null;
    else if (act === "module") state.workspace.module=id;
    else if (act === "resource-kind") state.workspace.kind=id;
    else if (act === "resource-open") state.workspace.reader={kind:'resource',id:Number(id)};
    else if (act === "announcement") state.workspace.announcement=Number(id);
    else if (act === "subscription-check") { for(const i of (id==='all'?D.subscriptions.map((_,i)=>i):[Number(id)])) state.workspace.checked[i]=true; }
    else if (act === "subscription-pause") state.workspace.paused[id]=!state.workspace.paused[id];
    else if (act === "subscription-delete") state.workspace.removed[id]=true;
    else if (act === "subscription-form") state.workspace.subscriptionForm=!state.workspace.subscriptionForm;
    else if (act === "dismiss-notice") state.workspace.notice='';
    else if (act === "source-toggle") state.workspace.sources[id]=id.startsWith("resource-") ? !state.workspace.sources[id] : state.workspace.sources[id]===false;
    else if (act === "sources-panel") state.workspace.sourcesOpen=!state.workspace.sourcesOpen;
    else if (act === "chat-clear") state.chat=seedChat();
    else if (act === "generate") { t.tab = "notes"; }
    else if (act === "share") {
      const lec = lectureOf(t.lectureId);
      const markdown = '# ' + lec.title + '\n\n' + setOf(lec.id).notes.map(n => '## ' + n.heading + '\n' + n.points.map(p => '- ' + (typeof p === 'string' ? p : p.he + ' ' + p.en)).join('\n')).join('\n\n');
      const url = URL.createObjectURL(new Blob([markdown], { type: 'text/markdown' }));
      const link = document.createElement('a'); link.href = url; link.download = 'lectern-sample-notes.md'; root.appendChild(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000); return;
    }
    else if (act === "csv") { downloadCSV(t.lectureId); return; }
    else if (act === "rec-start") {
      state.rec.active = true; state.rec.saved = false;
      stopTimer();
      timerId = setInterval(() => { state.rec.seconds++; paintTimer(); }, 1000);
      renderExplored(btn.getAttribute("data-fkey"), false); return;
    }
    else if (act === "rec-stop") {
      state.rec.active = false; state.rec.saved = true; stopTimer();
      renderExplored(btn.getAttribute("data-fkey"), false); return;
    }
    else if (act === "rec-reset") { state.rec.active = false; state.rec.seconds = 0; state.rec.saved = false; stopTimer(); }
    else if (act === "lang") { state.rec.lang = id; }
    else if (act === "flip") { state.flipped[id] = !state.flipped[id]; }
    else if (act === "next-card") { const k = lectureOf(t.lectureId).sampleSet; state.deckIndex[k] = (state.deckIndex[k] + 1) % setOf(t.lectureId).cards.length; }
    else if (act === "prev-card") { const k = lectureOf(t.lectureId).sampleSet; const n = setOf(t.lectureId).cards.length; state.deckIndex[k] = (state.deckIndex[k] + n - 1) % n; }
    else if (act === "answer") { const parts = id.split(":"); if (state.quiz[parts[0]] === undefined) state.quiz[parts[0]] = Number(parts[1]); }
    else if (act === "retake") { for (const q of setOf(t.lectureId).quiz) delete state.quiz[q.id]; }
    else if (act === "docs-push") { state.docsPushedAt = "just now (simulated)"; }
    else return;
    renderExplored(btn.getAttribute("data-fkey"), !!NAV_ACTS[act]);
  });

  function paintTimer() {
    const els = root.querySelectorAll(".ld-timer");
    for (const el of els) el.textContent = fmtTime(state.rec.seconds);
  }

  root.addEventListener("keydown", (e) => {
    const tab = e.target.closest('[role="tab"]');
    if (!tab || !root.contains(tab)) return;
    const index = TABS.findIndex(t => t.id === tab.getAttribute("data-id"));
    let next;
    if (e.key === "ArrowRight") next = (index + 1) % TABS.length;
    else if (e.key === "ArrowLeft") next = (index + TABS.length - 1) % TABS.length;
    else if (e.key === "Home") next = 0;
    else if (e.key === "End") next = TABS.length - 1;
    else return;
    e.preventDefault();
    root.querySelector('[data-act="tab"][data-id="' + TABS[next].id + '"]')?.click();
    root.querySelector('[data-act="tab"][data-id="' + TABS[next].id + '"]')?.focus({ preventScroll: true });
  });

  root.addEventListener("input", (e) => {
    const section=e.target.getAttribute?.('data-search');
    if(section){ interact(); if(lastRendered==='tour') state.explored={...state.tour};state.mode='explore';state.workspace.search[section]=e.target.value; if(section==='resources')state.workspace.module='all';const key=e.target.getAttribute('data-fkey'),start=e.target.selectionStart,end=e.target.selectionEnd;renderExplored(key,false);root.querySelector('[data-fkey="'+key+'"]')?.setSelectionRange(start,end);return; }

    if (e.target.id !== "ld-course-search") return;
    interact();
    const query = e.target.value.toLowerCase();
    for (const button of root.querySelectorAll('[data-course-name]')) button.hidden = !button.getAttribute('data-course-name').toLowerCase().includes(query);
  });

  root.addEventListener("change", (e) => {
    if(e.target.getAttribute?.('data-change')==='preference'){interact();state.workspace.preferences[e.target.getAttribute('data-key')]=e.target.value;renderExplored(null,false);return;}

    if(e.target.getAttribute?.('data-change')==='filter-course'){interact();if(lastRendered==='tour')state.explored={...state.tour};state.mode='explore';const section=e.target.getAttribute('data-section');state.workspace.course[section]=e.target.value;state.workspace.module='all';state.workspace.announcement=null;renderExplored(e.target.getAttribute('data-fkey'),false);return;}

    const sel = e.target.closest("[data-change]");
    if (!sel || !root.contains(sel)) return;
    if (sel.getAttribute("data-change") === "mnav") {
      interact();
      if (state.mode === "tour") state.mode = "explore";
      if (lastRendered === "tour") state.explored = Object.assign({}, state.tour);
      state.workspace.reader=null;state.workspace.notice="";
      state.explored.section = sel.value;
      state.explored.lectureId = null;
      state.explored.spot = null;
      renderExplored(sel.getAttribute("data-fkey"), true);
    }
  });

  root.addEventListener("submit", (e) => {
    const subscription=e.target.closest('[data-form="subscription"]');
    if(subscription && root.contains(subscription)){e.preventDefault();interact();state.workspace.notice='Subscription preview ready. Live imports are available in the Mac app.';state.workspace.subscriptionForm=false;renderExplored(null,false);return;}

    const form = e.target.closest('[data-form="chat"]');
    if (!form || !root.contains(form)) return;
    e.preventDefault();
    const input = form.querySelector("textarea") || form.querySelector("input");
    const text = (input.value || "").trim();
    if (!text) return;
    interact();
    if (state.mode === "tour") state.mode = "explore";
    if (lastRendered === "tour") state.explored = Object.assign({}, state.tour);
    state.chat.push({ who: "user", text });
    state.chat.push({ who: "bot", text: chatReply(text) });
    renderExplored("chat-send", false);
  });

  // ---- contract ----
  function showStep(step) {
    const view = STEP_TO_VIEW[step];
    if (!view) return;
    // Explicit preview: selects views, never triggers actions (no timers,
    // quiz, flips). Always paints the tour view so story's explicit
    // preview-from-explore and resume paths update the screen; explored
    // state stays preserved untouched for resume/return. Scroll-driven
    // calls only arrive in tour mode (story guards that path).
    state.tour = Object.assign(freshNav(), { courseId: "c-bio" }, view);
    paint(state.tour, "tour");
  }

  // setMode is bookkeeping only. It never touches the DOM, so a story
  // pointerdown that enters explore cannot destroy the click target.
  // Entering explore adopts the visible tour nav when the tour preview is
  // what is on screen; later entries keep the preserved explored state.
  // Rendering happens via user actions (renderExplored) and tour previews
  // (showStep in tour mode). Resume tour = setMode("tour") + showStep(step).
  function setMode(mode) {
    if (mode !== "tour" && mode !== "explore") return;
    if (mode === "explore" && lastRendered === "tour") {
      state.explored = Object.assign({}, state.tour);
    }
    state.mode = mode;
  }

  function reset() {
    stopTimer();
    state.mode = "tour";
    state.tour = freshNav();
    state.explored = freshNav();
    state.rec = { active: false, seconds: 0, saved: false, lang: "en" };
    state.flipped = {};
    state.quiz = {};
    state.deckIndex = { memory: 0, shiur: 0 };
    state.docsPushedAt = null;
    state.workspace = freshWorkspace();
    state.chat = seedChat();
    render();
  }

  function getState() {
    return JSON.parse(JSON.stringify({
      mode: state.mode,
      tour: state.tour,
      explored: state.explored,
      rec: state.rec,
      flipped: state.flipped,
      quiz: state.quiz,
      deckIndex: state.deckIndex,
      docsPushedAt: state.docsPushedAt,
      workspace: state.workspace,
      chat: state.chat
    }));
  }

  render();
  return { showStep, setMode, reset, getState };
}
