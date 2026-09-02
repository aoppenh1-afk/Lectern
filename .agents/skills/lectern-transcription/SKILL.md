---
name: lectern-transcription
description: Transcribe Lectern lecture audio or repair a raw transcript. Use for English lectures and mixed English-Hebrew shiurim when audio is referenced with @filepath or transcript text is supplied.
---

# Lectern transcription

Create the faithful text record that later notes and study materials will use. Follow the mode and language branch named in the request. A response schema or output shape stated by the caller overrides the defaults below.

## Select the mode

- **Audio transcription:** listen to the complete referenced audio and transcribe it. When the request supplies a JSON schema, return one object that matches it exactly.
- **Transcript cleanup:** repair the supplied speech-recognition text without changing its substance, then rewrite it as continuous prose paragraphs. Return only the cleaned Markdown transcript.

Do not combine transcription with note-taking. Never summarize, outline, explain, translate, add a title, infer a source, or add a fact that was not spoken.

## Cover the whole recording

- Transcribe from the first spoken word to the last. A 40-minute lecture yields a transcript that reaches its last minute; never stop early, skip a stretch, compress a passage into a paraphrase, or write a placeholder such as `[continues]` or `...`.
- If the recording is long, work through it in one pass and return promptly after the final spoken passage. Partial coverage is a failed transcription.
- Include student questions and the speaker's replies. They are part of the lecture.

## Preserve the record

- Keep the speaker's meaning, order, claims, questions, answers, examples, source references, and repetitions that carry meaning.
- In audio mode, retain natural spoken wording and false starts when they affect meaning. In cleanup mode, remove filler, stutters, abandoned false starts, and accidental duplicate fragments.
- Repair only what the audio or nearby context supports. Mark unintelligible audio as `[unclear]`. Use `[unclear: likely TERM]` only when the evidence supports that likely reading.
- Represent a meaningful sound such as `[laughter]` or `[long pause]` sparingly. Do not narrate ordinary silence or room noise.
- Preserve code-switching where it occurs. Keep surrounding English in English and recognizable Hebrew or Aramaic terminology in Hebrew script.

## English lecture branch

- Write in English and preserve isolated foreign terms, technical vocabulary, names, formulas, and quotations accurately.
- Do not make spoken student language sound like an essay. Correct recognition errors and punctuation without polishing away the speaker's voice. In cleanup mode, paragraphing is a layout change only.

## English-Hebrew shiur branch

Expect English, Hebrew, Aramaic, and Yeshivish vocabulary inside the same sentence.

- Render recognizable Torah terms, source names, masechtos, sefarim, pesukim, and halachic vocabulary in standard Hebrew script, even when speech recognition used Latin transliteration or a similar-sounding English word.
- Use English for the connective reasoning. A natural mixed sentence looks like: `The גמ׳ asks on תוס׳, and רש״י answers that the מוחזק keeps the ממון.`
- Prefer the user's established forms: `גמ׳`, `תוס׳`, `רש״י`, `רמב״ן`, `רמב״ם`, `רא״ש`, `רשב״א`, `משנה`, `מיגו`, `שבועה`, `חזקה`, `עדים`, `ספק`, `מוחזק`, `יחלוקו`, `ממון`, `תפיסה`, `קנין`, `טענה`, `הלכה`, `דין`, `ק״ו`, `ד״ה`, `ב״ד`, `נ״מ`, and `המע״ה`.
- Use the exact source abbreviation when it is recognizable. Do not expand `גמ׳` to `גמרא` or `תוס׳` to `תוספות` merely for formality.
- Write the Hebrew gershayim `״` and geresh `׳`, not ASCII `"` or `'`. Write daf references the way the student does: `דף ב.` for the first עמוד and `דף ב:` for the second.
- Do not add ניקוד. Do not append an English translation after every Hebrew term.
- Keep a Latin transliteration only when the speaker explicitly discusses that spelling or the intended Hebrew form cannot be established safely.
- Preserve separate שיטות, קושיות, תירוצים, and cases as separate speech. Do not resolve a מחלוקת for the speaker.
- When the speaker reads a line of גמ׳, רש״י, or תוס׳ aloud, transcribe the quoted line in Hebrew script and keep the explanation that follows in English.

### Common recognizer spellings and their intended forms

Speech recognizers usually emit these as transliterations or as similar-sounding English words. Restore the Hebrew form whenever the audio or context supports it.

| Heard as | Write |
| --- | --- |
| Gemara, gemora, "camera", "grandma" | גמ׳ |
| Rashi, "rush he" | רש״י |
| Tosfos, Tosafot, "toss those" | תוס׳ |
| Ramban, Rambam, Rosh, Rashba, Ran, Rashbam, Riva, Rabbeinu Yonah | רמב״ן, רמב״ם, רא״ש, רשב״א, ר״ן, רשב״ם, ריב״א, רבינו יונה |
| Mishna, sugya, daf, amud, perek | משנה, סוגיא, דף, עמוד, פרק |
| migo, shevua, chazaka, eidim, safek, muchzak, mamon, tefisa, kinyan, taana, neemanus | מיגו, שבועה, חזקה, עדים, ספק, מוחזק, ממון, תפיסה, קנין, טענה, נאמנות |
| yachloku, yehei munach, kol de'alim gvar, shuda dedayni | יחלוקו, יהא מונח, כל דאלים גבר, שודא דדייני |
| hamotzi mechavero alav hareaya, anan sahadi, mara kama, nafka mina, kal vachomer, beis din | המע״ה, אנן סהדי, מרא קמא, נ״מ, ק״ו, ב״ד |
| machlokes, shita, kushya, teretz, svara, pshat, chiluk, yesod, din, halacha | מחלוקת or מח׳, שיטה, קושיא, תירוץ, סברא, פשט, חילוק, יסוד, דין, הלכה |
| Bava Metzia, Bava Basra, Bava Kama, Kesubos, Shevuos, Pesachim | ב״מ, ב״ב, ב״ק, כתובות, שבועות, פסחים |
| talis, Reuven, Shimon, shutfin, kosel, chatzer | טלית, ראובן, שמעון, שותפין, כותל, חצר |

Yeshivish verb forms built on Hebrew roots (`be מוציא`, `is מחייב`, `was מתקן`, `to פסקן`) stay as the Hebrew word inside the English sentence.

When the recognizer produced gibberish at a language boundary, use the audio first and nearby Torah context second. If both leave a real ambiguity, keep it visible instead of guessing.

## Audio transcription output

- Segment at natural pauses or stable speaker turns.
- Keep timestamps monotonic and within the recording. Include a timestamp only when it is grounded in the audio.
- Add speaker labels only when distinct speakers can be tracked consistently. Otherwise omit them.
- Use BCP 47 language codes such as `en`, `he`, and `arc` when the requested schema includes language fields.
- When a schema is supplied, set its top-level `text` to the complete transcript in segment order. Every spoken passage in a segment must also appear in `text`.
- Return only the requested JSON object when a schema is supplied. Do not wrap it in a Markdown fence.
- When the caller requests timestamped text instead of JSON, start each natural segment with `[HH:MM:SS]`, add any requested speaker label after it, and return only the transcript immediately after the final segment.

## Transcript cleanup output

- Strip timestamp markers (`[mm:ss]`, `[hh:mm:ss]`, and similar) and do not keep a timed or line-by-line transcript layout.
- Reconstruct garbled or cut-off wording only when context makes the intended wording reasonably clear.
- Write continuous prose paragraphs so the result reads as one article of what was spoken. Break paragraphs at speaker turns, topic shifts, and natural rhetorical units — not at pauses, recognizer line breaks, or former timestamp boundaries.
- Do not add a title, headings, a summary, or an outline. This is still a transcript of the lecture, not notes.
- Keep speaker labels only when the source has distinct speakers and they remain useful as a short prefix on the paragraph they spoke (`Student:` / `Professor:`). Do not keep one line per utterance.
- Return only the cleaned Markdown transcript. Do not add a preamble or closing comment.

## Completion check

Before responding, verify that the entire source is represented in order, every uncertainty remains visible, mixed-language orthography follows the selected branch, and the response parses against any supplied schema.
