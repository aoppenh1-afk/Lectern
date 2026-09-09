// Seeded sample content for the Lectern website demo.
// Static sample data only. No network, microphone, file, or auth access.
export const DEMO_DATA = {
  term: "Fall 2026",
  courses: [
    { id: "c-bio", code: "BIO 101", name: "Biology 101: Memory and Learning", instructor: "Dr. A. Reyes", color: "#7A9471", score: 91.5, grade: "A−" },
    { id: "c-tanach", code: "TAN 201", name: "Tanach Shiur: Sefer Yonah", instructor: "Rabbi D. Levi", color: "#5E81AC", score: 88.0, grade: "B+" },
    { id: "c-psych", code: "PSY 210", name: "Psychology 210: Cognition", instructor: "Prof. M. Hale", color: "#906FA6", score: 94.2, grade: "A" }
  ],
  lectures: [
    { id: "l-memory", courseId: "c-bio", title: "How memory forms", date: "Mon, Sep 7", duration: "42:10", sampleSet: "memory" },
    { id: "l-shiur", courseId: "c-tanach", title: "Yonah 1: Running and returning", date: "Thu, Sep 3", duration: "38:24", sampleSet: "shiur" }
  ],
  schedule: [
    { time: "9:00 AM", title: "Biology 101 lecture", meta: "BIO 101 · Room 204" },
    { time: "11:30 AM", title: "Psychology 210 lecture", meta: "PSY 210 · Hall B" },
    { time: "2:00 PM", title: "Tanach Shiur: Sefer Yonah", meta: "TAN 201 · Beit Midrash" }
  ],
  deadlines: [
    { course: "BIO 101", title: "Memory chapter review", due: "Due Wed, 11:59 PM", tag: "In 2 days", points: "20 pts" },
    { course: "PSY 210", title: "Cognition problem set 4", due: "Due Fri, 5:00 PM", tag: "In 4 days", points: "30 pts" },
    { course: "TAN 201", title: "Yonah 1 source sheet", due: "Due Sun, 9:00 PM", tag: "Next week", points: "10 pts" }
  ],
  announcements: [
    { course: "BIO 101", author: "Dr. A. Reyes", when: "2h ago", title: "Midterm study guide posted", body: "The guide covers encoding, storage, and retrieval. Bring one page of notes." },
    { course: "TAN 201", author: "Rabbi D. Levi", when: "Yesterday", title: "Thursday shiur moved", body: "This week only: shiur starts at 2:15 PM in the Beit Midrash." }
  ],
  // Coherent memory lecture: transcript, notes, cards, and quiz share facts.
  memory: {
    transcript: [
      { speaker: "Dr. Reyes", time: "00:00", text: "Today we trace how a memory forms: first encoding, then storage, then retrieval. If any step fails, recall fails." },
      { speaker: "Dr. Reyes", time: "04:12", text: "Encoding needs attention. Multitasking splits attention, so less enters memory. Connecting a new idea to something you already know, called elaborative encoding, strengthens the trace." },
      { speaker: "Student", time: "11:47", text: "Does rereading count as studying?" },
      { speaker: "Dr. Reyes", time: "11:55", text: "Rereading feels fluent but tests poorly. Retrieval practice, closing the book and recalling the answer, builds far stronger recall than rereading." },
      { speaker: "Dr. Reyes", time: "24:03", text: "Storage consolidates with spacing and sleep. Short sessions across days beat one long night, and sleep stabilizes what you practiced." },
      { speaker: "Dr. Reyes", time: "36:40", text: "To review: attend to encode, space and sleep to store, and self-test to retrieve. Next week we apply this to lab protocols." }
    ],
    notes: [
      { heading: "Encoding: getting it in", points: ["Attention gates entry; multitasking weakens encoding.", "Elaborative encoding: link each new idea to known ideas."] },
      { heading: "Storage: keeping it", points: ["Spaced sessions across days beat cramming.", "Sleep consolidates what you practiced."] },
      { heading: "Retrieval: getting it back out", points: ["Retrieval practice (self-test) beats rereading.", "Recall before checking notes; fluency is not mastery."] }
    ],
    cards: [
      { id: "m1", front: "Name the three stages of memory formation.", back: "Encoding, storage, retrieval. A failure at any stage breaks recall." },
      { id: "m2", front: "What is elaborative encoding?", back: "Connecting a new idea to something you already know, which strengthens the memory trace." },
      { id: "m3", front: "Why does retrieval practice beat rereading?", back: "Actively recalling the answer strengthens recall; rereading only adds a feeling of fluency." },
      { id: "m4", front: "Which two factors consolidate storage?", back: "Spacing (sessions across days) and sleep." }
    ],
    quiz: [
      { id: "q1", stem: "Which study action demonstrates retrieval practice?", options: ["Closing the book and recalling the answer", "Rereading the chapter once more", "Highlighting key sentences"], answer: 0, explain: "Retrieval practice means recalling without looking. Rereading and highlighting skip that step." },
      { id: "q2", stem: "Linking a new term to a familiar example is an example of…", options: ["Elaborative encoding", "Spacing", "Consolidation"], answer: 0, explain: "Elaborative encoding ties new ideas to known ones at entry." },
      { id: "q3", stem: "Two study plans: one long night, or short sessions across four days with sleep. Which stores better?", options: ["One long night", "Short spaced sessions with sleep", "They are equal"], answer: 1, explain: "Spacing plus sleep consolidates storage; cramming fades." }
    ]
  },
  // Separate English/Hebrew sample (pending fluent-reader review, not launch copy).
  shiur: {
    transcript: [
      { speaker: "Rabbi Levi", time: "00:00", text: "We open Sefer Yonah, chapter one. Yonah hears a calling and runs the other way." },
      { speaker: "Rabbi Levi", time: "03:20", text: "The verse says:", quoteHe: "ויקם יונה לברח תרשישה", textAfter: "Yonah rises to flee toward Tarshish. Read the direction first, then ask why." },
      { speaker: "Student", time: "09:41", text: "Is running here physical, or refusing the mission?" },
      { speaker: "Rabbi Levi", time: "09:58", text: "The commentaries keep both readings. Hold the question; chapter three answers it." }
    ],
    notes: [
      { heading: "Opening: the flight", points: ["Yonah 1: the prophet runs toward Tarshish.", { he: "ויקם יונה לברח תרשישה", en: "\"Yonah rises to flee to Tarshish\" (Yonah 1:3)." }] },
      { heading: "Question to carry", points: ["Is the flight physical escape, refusal of the mission, or both?", "Revisit after chapter three; do not settle it early."] }
    ],
    cards: [
      { id: "s1", front: "Where does Yonah flee, per Yonah 1:3?", backHe: "תרשישה", back: "Tarshish." },
      { id: "s2", front: "Which question should stay open until chapter three?", back: "Whether Yonah's flight is physical escape, refusal, or both." }
    ],
    quiz: [
      { id: "sq1", stem: "According to the shiur, how should you first read the flight verse?", options: ["Read the direction first, then ask why", "Settle the meaning immediately", "Skip to chapter three"], answer: 0, explain: "Direction first, interpretation after. The question stays open." }
    ]
  },
  week: [
    { day: "Mon", items: ["BIO 101 lecture · 9:00 AM", "PSY 210 lecture · 11:30 AM"] },
    { day: "Tue", items: ["TAN 201 shiur prep · 8:00 PM"] },
    { day: "Wed", items: ["BIO 101 review due · 11:59 PM"] },
    { day: "Thu", items: ["TAN 201 shiur · 2:00 PM"] },
    { day: "Fri", items: ["PSY 210 problem set due · 5:00 PM"] }
  ],
  assignments: [
    { course: "BIO 101", title: "Memory chapter review", due: "Wed, 11:59 PM", status: "Not started", points: "20 pts" },
    { course: "PSY 210", title: "Cognition problem set 4", due: "Fri, 5:00 PM", status: "In progress", points: "30 pts" },
    { course: "TAN 201", title: "Yonah 1 source sheet", due: "Sun, 9:00 PM", status: "Not started", points: "10 pts" }
  ],
  resources: [
    { name: "Memory chapter slides (PDF)", meta: "BIO 101 · Sample file" },
    { name: "Cognition lab protocol (Pages)", meta: "PSY 210 · Sample file" },
    { name: "Yonah 1 source sheet (PDF)", meta: "TAN 201 · Sample file" }
  ],
  subscriptions: [
    { name: "BIO 101 lecture series", meta: "New recordings · Sample subscription" },
    { name: "TAN 201 weekly shiur", meta: "New shiurim · Sample subscription" }
  ],
  chatPairs: [
    { match: ["retrieval", "reread"], reply: "From the sample lecture: retrieval practice (closing the book and self-testing) builds stronger recall than rereading. Rereading adds fluency, not mastery." },
    { match: ["encoding", "attention"], reply: "From the sample lecture: encoding needs attention. Linking a new idea to something known strengthens the trace." },
    { match: ["sleep", "spacing", "storage"], reply: "From the sample lecture: storage consolidates with spaced sessions across days plus sleep." }
  ],
  chatFallback: "This is a local sample answer, not AI. Try asking about retrieval practice, encoding, or sleep."
};
