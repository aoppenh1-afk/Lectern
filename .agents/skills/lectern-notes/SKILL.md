---
name: lectern-notes
description: Turn a Lectern transcript into student notes in the student's own outline style, or revise an existing Notes artifact. Use for English lectures and English-Hebrew shiurim, including notes generated through Gemini, ChatGPT, Codex, OpenCode, or Antigravity CLI.
---

# Lectern notes

Write one grounded Markdown outline that reads like the student's own notes: a deeply nested outline that follows the lecture in order, where every supporting point sits under the point it supports. The notes are a record of what the lecture developed, not a summary of it.

## Source boundary

- The lecture transcript is the authority for what the speaker said.
- When the input contains `<lecture-transcript>`, that block is primary. Use `<reference-source>` blocks or named reference files only to correct names, spellings, citations, and terminology, or to supply course context that is labeled as such. Never present reference material as something the speaker said.
- Do not add facts from general knowledge during initial generation. Add outside context only when the student asks for it in a revision.
- Keep every developed topic, definition, mechanism, example, exception, comparison, question, answer, source, and causal link, in source order.
- Match the density of the source. A 40-minute lecture produces a long outline; a sparse transcript produces a short one. Do not pad, and do not compress a developed argument into one line.

## Markdown contract (Lectern parses this literally)

Lectern renders the outline itself, so the exact list syntax matters.

- Begin with exactly one `#` title taken from the subject, chapter, or sugya. Never `# Notes` or `# Lecture Notes`.
- Use `##` for each major topic or section in lecture order. Use `###` only for a real subsection.
- Put one blank line after every heading. Do not put blank lines between items of the same list.
- Every list item starts on its own line. Never place two items on one line, never use `•`, and never write a list as a comma-separated sentence.
- Bullet marker is `- `. Ordered marker is `1. ` (write `1.` for every item; Lectern renumbers and labels nested levels `1.` → `a.` → `i.`).
- Nest with exactly four spaces per level, relative to the parent item:

```markdown
- **Isotopes:** same number of protons but a different number of neutrons, so the atomic weight changes
    - Sometimes unstable (radioactive) because the atom decays to shed the extra neutrons
        - Main ex: Carbon-14, Hydrogen-3, Potassium-32, Sulfur-35, Nitrogen-15
    - Carbon-14 is used for carbon dating by calculating the half-life of the decay
```

- Nesting is the whole point. Elaborations, reasons, examples, exceptions, and answers go one level under the claim they belong to. A section with ten or more items that all sit at the top level is wrong; a lecture normally produces two to four levels, and a shiur often reaches five or six.
- Bold only the organizing label at the front of an item: a defined term, a source name, `Q:`, `A:`, `Case:`, `נ״מ:`, `Ex:`. Never bold whole sentences or whole items.
- No tables, no HTML, no horizontal rules, no block quotes, no wrapping ```` ```markdown ```` fence, no preamble, no sign-off, no meta-comments about the transcript.
- Do not force generic sections named `Overview`, `Introduction`, `Main Ideas`, `Key Takeaways`, `Summary`, or `Conclusion`. Only the shiur layout has a closing section, and it is called `Cash Torah`.

## Voice

Write the way the student writes in class: compact, sentence-case, mostly without terminal periods, keeping the logical connectors that carry the reasoning (`because`, `so`, `therefore`, `but`, `even though`, `which means`). Familiar shorthand is fine when it reads naturally: `Ex:`, `w/`, `w/o`, `ppl`, `vs`, `acc to`, `~`, `→`, `#`, `$`. Do not invent slang the student did not use, and do not turn the outline into essay paragraphs. Each item is one idea; if an idea needs a reason or an example, that goes in a child item, not in a second sentence.

## English lecture layouts

Pick the layout that fits how the lecturer organized the material and keep it for the whole document.

### Concept, science, or terminology lecture (bullets)

Top-level items introduce a term, structure, or mechanism as `**Term:** definition`; children carry composition, mechanism, examples, exceptions, and comparisons. Grouping the lecturer used (types, factors, functions, steps) becomes a parent item with the members nested under it.

```markdown
# Biological Macromolecules

## Carbohydrates

- **Carbohydrates:** molecules used for both fuel and structural support
    - Contain carbon, hydrogen, and oxygen
    - Types: monosaccharides, disaccharides, and polysaccharides

### Disaccharides

- **Disaccharides:** two monosaccharides joined by a glycosidic bond
    - Glycosidic bond is formed by a dehydration reaction
        - Sucrose is a common ex
        - Doesn't have to be the same two monosaccharides

## Protein Denaturation

- **Protein denaturation:** loss of protein function and higher-order structure
    - Primary structure is unaffected
- Factors that cause denaturation
    - Extreme temp
    - pH changes
    - Salt concentration
```

Worked problems and in-class exchanges use `**Q:**` and `**A:**` items with the work nested under the question.

### Historical, chronological, or argument-driven lecture (ordered outline)

Use nested ordered lists. Top level is the lecturer's major theme or period; the next level is each claim in order; deeper levels hold evidence, examples, qualifications, and the lecturer's asides. Items are full clauses that keep the causal chain (`so`, `because`, `but`).

```markdown
# The Eighteenth Century Before Industrialization

## The Long Shadow of Death

1. Death was part of everyday life even in peacetime because people encountered it constantly
    1. Cemeteries were in churchyards in the heart of town, so anyone going to church saw the dead
        1. The upper class was buried inside the church itself
    1. This matched a very high death rate with high infant and maternal mortality
        1. So the European population was stagnant because births and deaths canceled out
    1. Until around 1740 the population rises, but people don't realize the growth is sustained
1. Death rates were high because widespread famine made people susceptible to plague
    1. Medicine was primitive and did not improve in the 18th century
        1. Doctors catered to the wealthy and very few existed
            1. Knowledge was still based on four humors in equilibrium, so doctors would bleed people
```

Do not convert a chronological argument into disconnected topical bullets, and do not force numbering onto a lecture organized by concepts.

## English-Hebrew shiur layout

Write compact English reasoning around standard Hebrew-script Torah vocabulary, exactly as the student does. Do not produce fully Hebrew prose unless the speaker did.

### Structure

- `#` is the sugya or the דין under discussion (`# דין יחלוקו`, `# מיגו להוציא לא אמרינן`, `# הכל כמנהג המדינה`).
- `##` sections follow the movement of the shiur. The student's own section names are `הקדמה`, `שיטת רש״י`, `שיטת תוס׳`, `שיטת הרמב״ן/רשב״א`, `ביאור מח׳ רש״י ותוס׳`, `שורש המחלוקת`, `נ״מ`, a question used as a heading (`What's the שורש המח׳?`, `Is it a direct or indirect clash?`), `Answering our Questions`, and `Cash Torah`. Use only the ones this shiur actually contains.
- `הקדמה` opens with the משנה or גמ׳ and the case, then the questions the shiur will work on. When the maggid shiur poses numbered problems up front, list them as `**Q1:**`, `**Q2:**`, `**Q3:**` and resolve them later in an `## Answering our Questions` section as `**A to Q1:**`, or end the הקדמה with a `**Summary:**` item that restates the two or three concepts in play.
- `## Cash Torah` closes a sugya only when the shiur reaches a bottom line. It is one to three items stating the יסוד, the שורש המחלוקת, or the map of שיטות, often enumerated inline as `(I) ... (II) ... (III) ...`. Do not write it when the shiur ends mid-inquiry.

### Source-first items

- Each source is its own item, and what it says is nested under it: `- **רש״י ד״ה לפיכך**` then a child with the pshat. Cite the way the student does: `משנה`, `גמ׳ דף ב:`, `רש״י ד״ה משנה יתירא`, `תוס׳ ד״ה וזה נוטל`, `תוס׳ הרא״ש`, `רמב״ן כתובות`, `רשב״א ב״ב דף ד`, `רבינו יונה שם`, `שו״ת הרא״ש`, `קובץ שיעורים`, `נודע ביהודה`, `חתם סופר`, `רב שמואל רוזובסקי`.
- Questions and answers are explicit items: `**Q:**`, `**A:**`, and `**A1:**`, `**A2:**` when a question gets more than one answer. A follow-up question on an answer nests under that answer, so a שקלא וטריא naturally goes four or five levels deep.
- `**Case:**` introduces the fact pattern a דין is tested against.
- `**נ״מ:**` introduces a practical difference, with each consequence nested under it.
- Keep every שיטה, צד, distinction, proof, rejection, and חילוק separate. Never blend two שיטות into one view, and never resolve a מחלוקת the speaker left open.
- Comparisons between שיטות are nested items, one per שיטה, never a table.

### Orthography

- Use Hebrew script for every recognizable Torah term, source, and concept, including ones that appear mid-sentence: `מוחזק`, `ספק`, `טענה`, `נאמנות`, `אנן סהדי`, `תקנת חכמים`, `המע״ה`, `מיגו להוציא לא אמרינן`, `חזקת מרא קמא`.
- Prefer the student's forms: `גמ׳`, `תוס׳`, `רש״י`, `רמב״ן`, `רמב״ם`, `רא״ש`, `רשב״א`, `ר״ן`, `רשב״ם`, `ריב״א`, `משנה`, `מח׳`, `מיגו`, `שבועה`, `חזקה`, `עדים`, `מוחזק`, `יחלוקו`, `ממון`, `תפיסה`, `קנין`, `טענה`, `הלכה`, `דין`, `ק״ו`, `ד״ה`, `ב״ד`, `ב״ב`, `ב״מ`, `ב״ק`, `נ״מ`, `המע״ה`, `כד״ג`, `ל״ק`, `ל״ב`.
- Use the Hebrew gershayim `״` and geresh `׳`, not ASCII quotes. Do not add ניקוד.
- English carries the connective reasoning; do not translate every Hebrew term in parentheses. Give a short English gloss only when the speaker gave one or the term is rare.

### Example

```markdown
# דין יחלוקו

## הקדמה

- **משנה**
    - Two ppl are holding a טלית and each claims it's fully his, so each makes a שבועה that at least half is his and they split it
        - יחלוקו is one of several ways we decide a ספק; others include יהא מונח, כל דאלים גבר, and שודא דדייני
- **Q:** is יחלוקו a פשרה, a version of המע״ה, or a תפיסה מוכחת?
    - **Q:** what's the difference between המע״ה and my תפיסה being מוכח?
    - **A:** המע״ה means the burden of proof falls on the מוציא, but it doesn't show the object is mine
        - Like the wall that falls into one guy's רשות: no evidence who built it, but the burden falls on the מוציא
- **תוס׳ הרא״ש**
    - The הלכה is that גודרות don't have חזקות because they move on their own
    - **Q:** why is the fallen wall המע״ה and not like גודרות, since both moved on their own?
    - **A:** by גודרות there was a חזקת מרא קמא, so we don't let you be מוציא from the מרא קמא; by the wall there is no מרא קמא, so המע״ה is enough
        - **A:** to be מוציא from a מוחזק you need a תפיסה מוכחת, but to be מוציא in general you just need a תפיסה
- **Summary:** 2 concepts, (I) המע״ה and (II) תפיסה מוכחת, which is based off the חזקה that ppl don't steal

## שיטת רש״י

- **רש״י**
    - It's a case where both are actually holding the טלית, so both are מוחזק and neither is stronger
        - רש״י says דווקא אוחזין to exclude a case where only one of them is holding it
    - If only one is holding it the הלכה would be המע״ה with עדים, and a שבועה wouldn't help
- **גמ׳ דף ב:**
    - **Q:** the רבנן don't fit our משנה either because they hold המע״ה?
    - **A:** the רבנן only said המע״ה when one guy is holding it; when both hold it they say יחלוקו בשבועה
        - **Q:** what difference does it make if both hold it, they're still being מוציא, so a שבועה shouldn't be enough?
        - **A:** since both are מוחזק, the רבנן held you can't be מוציא with no נאמנות at all, so here a שבועה is enough

## Cash Torah

- Acc to רש״י both are מוחזק on everything and we split מספק; acc to תוס׳ each is מוחזק on half and we split מדין ודאי
```

## Optional visual

Add at most one visual, and only when a spatial structure, anatomy, mechanism, or multi-step relationship is materially easier to learn from a picture. If an image-generation tool is available, create a clean labeled textbook-style diagram, save it in the current workspace, and embed it as `![descriptive alt text](/absolute/local/path.png)`. Otherwise use one fenced `mermaid` block (flow, cycle, hierarchy, or comparison, at most about 12 nodes). Skip the visual when the outline already explains the idea.

## Revising existing notes

- Apply the student's requested operation exactly: append, expand, replace, reorganize, correct, or clarify.
- Preserve unrelated Markdown verbatim. Do not reformat the whole document to change one section.
- Match new material to the existing document's layout, heading depth, and indentation.

## Completion check

Before responding, silently verify:

1. One source-derived `#` title, `##` sections in lecture order, a blank line after each heading.
2. Every list item on its own line, `- ` or `1. ` markers only, four-space nesting, and supporting points actually nested under the point they support.
3. Every developed topic, source, question, answer, and example appears once, in source order, with nothing invented and no שיטות merged.
4. The chosen layout is consistent throughout, and the shiur orthography uses Hebrew script with `״` and `׳`.
5. The response is only the Markdown document.
