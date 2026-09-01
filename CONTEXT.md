# School App

A personal macOS study companion: record lectures, turn them into study materials locally, and stay organized around courses. Phase 1 is lecture capture and study-material generation; Phase 2 adds calendar/task productivity via Canvas.

## Language

### Study

**Course**:
A class the student is enrolled in; the parent grouping for Lectures.
_Avoid_: Class, subject

**Lecture**:
A single class meeting that is recorded and studied as one unit; belongs to exactly one Course.
_Avoid_: Session, class meeting

**Unfiled**:
The holding state of a Lecture recorded before its Course was assigned; filing moves it into exactly one Course.
_Avoid_: Inbox, orphan

**Recording**:
The raw audio captured during a Lecture.
_Avoid_: Audio file, take

**Raw Transcript**:
The verbatim output of transcribing a Recording, including filler words and transcription errors.
_Avoid_: ASR text, transcript draft

**Cleaned Transcript**:
A repaired Raw Transcript: fillers removed and garbled or cut-off words reconstructed from context, trusting that what was said is true; wording stays faithful to the Lecture.
_Avoid_: Edited transcript, summary

**Notes**:
Bullet-point study notes rewritten from a Lecture's content with a summary at the end; the Lecture is the baseline and any added information stays close to it. May include generated diagrams and images where applicable.
_Avoid_: Summary, minutes

**Flashcard**:
An atomic question-and-answer study item generated from a Lecture's content, exported to Anki.
_Avoid_: Card, quiz item

**Quiz**:
A set of practice questions generated from a Lecture's content for self-testing.
_Avoid_: Test, exam
