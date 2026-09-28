# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Two parts exist:
- The hymn data pipeline, `tools/hymnpdf`, converts the Church's hymn PDFs into JSON. The
  development set is 20 hymns (2, 6 and 18 popular ones; 86 and 124 have no music). All
  convert with no warnings and are hand-checked. None of it is in the repository: the
  files live in the gitignored `hymns/pdf`, `hymns/json`, `hymns/beatmaps` and
  `hymns/audio` of each developer's checkout (see the README for fetching them), and the
  tests that need them skip when they're absent.
- The iOS app, `ios/`, is a first prototype. Its logic lives in the Swift package
  `ios/Packages/SingItCore`, which builds and is tested on Linux. The SwiftUI/AVFoundation
  layer in `ios/SingIt` can't be compiled on Linux; it's built on a Mac over SSH (below).

Development happens on a Linux machine, where Xcode and the iOS toolchain can't run. The
host's libraries are too new for swift.org's Linux toolchain, so Swift runs in Docker.

## Commands

```bash
python3 -m venv .venv && .venv/bin/pip install -r tools/requirements.txt   # one-time setup

.venv/bin/pytest                                    # all tests
.venv/bin/pytest tools/tests/test_hymn_0002.py::test_tie_merges_notes   # one test

# Convert a hymn PDF (also regenerates the golden JSON checked by the tests)
PYTHONPATH=tools .venv/bin/python -m hymnpdf hymns/pdf/0002-the-spirit-of-god.pdf \
    -o hymns/json/0002-the-spirit-of-god.json --strict
# Checking aids: --dump (measure-by-measure listing), --overlay PREFIX (PNGs of the pages
# with each extracted note circled and labelled by part), --midi FILE [--full-form]
PYTHONPATH=tools .venv/bin/python tools/check_all.py   # one status line per hymn PDF
# Beat map of an accompaniment MP3 (practice mode's position; ground truth for testing)
.venv/bin/python tools/beatmap.py hymns/json/NNNN-slug.json hymns/audio/NNNN-slug.accompaniment.mp3 \
    --url <mp3 url> -o hymns/beatmaps/NNNN-slug.json
# A PDF with no music (86, 124) prints "nothing to convert" and writes no JSON (exit 0).

# SingItCore (Swift) in Docker. Run as your user so .build isn't owned by root.
alias swiftd='docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src -w /src/ios/Packages/SingItCore swift:6.3 swift'
swiftd test                                   # all core tests (about 5 s)
swiftd test --filter ScoreFollowerTests       # one test class
# Follower tuning table (prints results, asserts nothing):
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e SWEEP=1 -v "$PWD":/src \
    -w /src/ios/Packages/SingItCore swift:6.3 swift test -c release --filter FollowerSweep
# Syntax-only check of app files (SwiftUI can't be type-checked on Linux):
docker run --rm -v "$PWD":/src -w /src/ios swift:6.3 sh -c 'for f in $(find SingIt -name "*.swift"); do swiftc -parse "$f"; done'
```

The app builds on a Mac reached over SSH (host in `ios/local.env`: `SINGIT_MAC=<host>`;
XcodeGen via Homebrew in /opt/homebrew/bin). From Linux:

```bash
ios/scripts/mac.sh build    # rsync the repo to ~/Code/sing-it on the Mac, xcodegen, simulator build
ios/scripts/mac.sh device   # build, sign, install and launch on the plugged-in iPhone (unlock it)
ios/scripts/mac.sh test     # SingItCore tests on macOS
ios/scripts/mac.sh ssh CMD  # run CMD in the Mac's copy of ios/
```

Signing settings live in `ios/project.local.yml` (not committed): it `include`s
`project.yml` and overrides `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER`; the
scripts generate from it when it exists. Code signing can't reach the login keychain over SSH, so `device` runs the build through
Terminal.app in the Mac's desktop session (`ios/scripts/device-build.command`). Never run
`-allowProvisioningUpdates` builds over plain SSH while Xcode has the project open: they
race Xcode for a free personal team's limited certificates and revoke each other's.
`ios/project.yml` is the source of truth for the Xcode project; never commit or hand-edit
the generated `.xcodeproj`. The Mac's copy is overwritten on every sync, so make edits here.

CI (`.github/workflows/tests.yml`) runs pytest and the SingItCore tests (Linux, `swift:6.3`
container) on every push, and an unsigned simulator build of the app on `main` (macOS
minutes are expensive on a private repo). CI has no hymn files, so only the test-hymn and
synthetic tests really run there; run the full suite locally with the hymns present.

Screenshots in `docs/screenshots` come from `ios/scripts/screenshots.sh`: a debug-only
screenshot mode (`ios/SingIt/App/ScreenshotMode.swift`, launch argument `-screenshot
setup|singing|summary|range|demo`) that opens a screen with the test hymn from the package's
test fixtures (bundled into the app) and a simulated singer. `demo` sings in real time
(`SingController.runDemo`) and the script records it to `build/screenshots/demo.mp4`, the
source of `docs/demo.gif` (ffmpeg command in the README). Only the made-up test hymn
may appear in anything published. `tools/make_icon.py` draws the app icon.

## Hymn data pipeline (`tools/hymnpdf`)

- Source PDFs live in `hymns/pdf/NNNN-slug.pdf`, and their extracted JSON in
  `hymns/json/NNNN-slug.json`.
- The PDFs are vector engravings, so extraction reads exact coordinates and does no OCR.
  Noteheads, rests, dots, flags and accidentals are glyphs in the Maestro music font (`œ`
  filled notehead, `˙` half, `j`/`J` eighth flag, `b`/`n`/`#`, `Œ` quarter rest, `‰` eighth
  rest, `U`/`u` fermata above/below). Stems, barlines, beams and ties/slurs are vector
  paths. Lyrics are text. A notehead glyph's origin y is its vertical centre.
- Two producers made the PDFs. InDesign (2, 6) maps every glyph to Unicode. Ghostscript/TeX
  (the rest) leaves two things unmapped, and PyMuPDF then reports a control character that
  differs per file: the half notehead (alone in a Type0 Maestro subset; identified by the
  md5 of its TrueType outline) and the fi/fl ligatures in the text font (identified by the
  glyph names in the font's `/Encoding /Differences`). Never treat control characters as
  whitespace. Ghostscript also draws flat beams as filled rectangles, not polygons. A stem
  gets one beam level for each beam it crosses, so 16th beams and partial-beam stubs count.
- Parts are assigned from close-score conventions. When two parts on a staff share a
  stem, the top notehead is the upper part. A stem to itself means up = upper part, down =
  lower part. A unison is drawn as duplicate overlapping noteheads. A notehead on the
  "wrong" side of a stem belongs to that stem only if it's a second away from another
  note on it; otherwise it belongs to the other part. A rest is for the parts of its staff
  that have no note in its column; with no note there, one on the middle line is for both
  parts and one displaced up or down for the upper or lower part. These rules live in
  `extract.py`.
- Cue-size (3/4 size, thinner stem) notes are optional. Over a printed note of the same
  part, a cue head is an alternative pitch (`alt`, e.g. a low octave for the basses). Over
  a rest, it replaces the rest as a note sung only by the verses with a syllable there
  (`verses`); parentheses around it are ignored.
- Italic labels under a treble staff (`Unison`, `Duet`, `Harmony`) start a passage. In a
  unison passage only the melody (treble upper part) is sung, by everyone: alto copies it
  and the men sing it an octave lower. In a duet the treble staff gives soprano and alto,
  the bass staff is accompaniment, and the men sing the melody an octave lower (a product
  choice; the bass-staff line is not a sung part). `voicing` lists the passages.
- Measures end only at barlines, and a measure can continue across a system break.
  A double or final barline (two lines close together) is one barline. Timing is laid out
  per part, and the extractor warns if the parts disagree at any barline, if heads printed
  in one column get different start times, or if a measure's length doesn't match the
  time signature in force. Those checks are the main guard against misread rhythms. Treat
  any warning as a bug, and use `--strict` when generating data.
- Time signatures can change mid-hymn (30). Each takes effect at the first note after it;
  one with nothing after it on its system is a courtesy signature. A small italic digit
  over a group of notes is a tuplet (227's triplet), scaled before timing.
- Printed pages don't repeat for verses. Page 1 shows the verse music once with all
  verse lyrics stacked, and the chorus follows once. Consecutive systems with the same
  number of lyric lines form a `section`, and `form` lists the sung order (verse 1,
  chorus, verse 2, ...). A form entry's `verse` is null when its section has one lyric line
  (sung for every verse); a men's echo line (`parts`) doesn't count as a verse. A section can end mid-system, at the barline after which only the
  next section's rows continue (60's chorus starts on the middle row of a verse system).
  A lower row whose words sit under bass-staff notes the treble staff doesn't have is a
  men's echo (105, 152), not a verse: it doesn't count as a row for sections.
- Some hymns print extra verses as a poem below the music, with no hyphens. `syllables.py`
  splits those into syllables, taking counts from the CMU Pronouncing Dictionary and choosing
  among a word's alternative pronunciations so the verse fits the printed verses' syllable
  count (an unstressed "er" after a vowel may also glide into it, fi-ery, pow'r, as the
  dictionary lists for "fire"). The syllables are then mapped onto the printed verses' start times, and the lines
  are marked `fromText: true`. Where the printed verses differ in rhythm (an optional note)
  the poem verse takes the first rhythm its words fit exactly. A verse that fits none
  (85's verses 5 and 6 drop two feminine endings) is laid out by stress: stressed syllables
  on strong beats, poem lines starting where printed phrases start, a syllable held over
  the notes it lacks. Such lines are marked `approximate: true`. If a verse can't be
  fitted at all, it keeps its `text` with empty `syllables` and a warning.
- ⌜ ⌝ brackets on the page mark the organ introduction and become `intro` beat ranges.
  ⌜ starts at the first note to its right, and ⌝ ends when the last note to its left ends.
- JSON essentials: times are in quarter-note beats from the start of the written score.
  `parts.{soprano,alto,tenor,bass}` are note lists (`start`, `duration`, `midi`, `pitch`,
  `measure`), with tied notes already merged. Each note's `heads` gives PDF coordinates
  (page, x, y in points), so the app can draw feedback directly over the original page.
  Lyrics are per-section timelines of syllables (`start`, `text`, `syllabic`), not
  attached to notes, because the parts' rhythms sometimes differ under one syllable.
  A tie printed for one verse is merged for all; a verse with a syllable starting inside
  the merged note sings that pitch again there (2's "Saints’ un-", 60's "He has").
  An em dash one word space after a word is punctuation and stays on it; a dash standing
  apart under a note is a placeholder (this verse sings nothing there) and is dropped.
  Times are summed exactly, so after a triplet every part, measure and syllable that
  meets on a beat has the identical float value.
- Keys that appear only when they apply (so older JSON is unchanged):
  - a rest is a part entry `{start, duration, rest: true, measure, heads}` (no midi/pitch),
    so every part stays contiguous;
  - note `fermata: true`; note `alt: [{midi, pitch, heads}]` (cue alternative);
    note `verses: [2]` (optional note, silent for other verses);
  - top-level `timeChanges: [{start, beats, beatType}]` (first at 0; `time` is the opening
    signature) and `voicing: [{start, voicing}]`;
  - `tempo.dotted: true` (105's dotted-quarter beat);
  - a lyric line with `parts: ["tenor", "bass"], start, end` replaces the section's main
    line for those parts from `start` to `end` (a men's echo); `approximate: true` on a
    stress-fitted poem verse.
- Hymns 86 and 124 are licensing notices with no music; `extract()` raises `NoMusicError`
  and `check_all.py` reports them as SKIP.
- The development set's 18 downloaded hymns were chosen to cover varied notation: 2/4, 3/4 and 6/8 time, a meter change (30), fermatas, rests,
  a chorus with echo parts (105, 152), and many poem verses (85). Those PDFs come from a
  Ghostscript/TeX pipeline, not InDesign, but use the same Maestro engraving.
  `tools/tests/test_hymnbook.py` runs over every PDF: no warnings, golden JSON current,
  parts contiguous and ending together, consistent `measure`/`form`, exact times, plus a
  table of hand-checked facts and tests for the engraving rules.
- Hymns 2 and 6 also have their own test files (`tools/tests/test_hymn_NNNN.py`) with
  detailed facts checked by hand against the printed page. When extraction changes,
  regenerate the golden JSON with `--strict` and review the diff against the pages.

## Accompaniment recordings and beat maps

- The Church's music site has an instrumental track per hymn, named `*_accompaniment_eng.mp3`,
  `*-instrumental-*eng.mp3` or `*musica_solo.mp3` (Spanish-titled but instrumental), found
  in the song page's HTML. They're downloaded to `hymns/audio/` (gitignored). The app
  downloads them itself on first use from the URL stored in each beat map.
- `tools/beatmap.py` aligns a recording to the hymn: chroma of the audio against chroma of
  all four parts in playing order (the ⌜ ⌝ introduction, then every pass of the form), by
  slope-constrained DTW (local tempo within 0.5–2×; free DTW races through one verse and
  dawdles in the next, because every verse has the same music), then smoothed by local
  line fits (inside a held chord all moments look alike). `hymns/beatmaps/NNNN-slug.json`
  stores `[seconds, performance beat]` every eighth of a beat.
- Check a new map: its average tempo should sit near the hymn's marked range, and the
  printed verse count should give the lowest `alignmentCost` (all 18 recordings play
  exactly the printed verses, some at the slow end of the marked tempo). Aligning the
  choir version of the same recording independently agreed to within 0.46 s for 90% of
  beats.
- Ground truth for a real practice recording: find the recording's offset in the MP3 by
  sliding chroma correlation (the singer's melody shares the accompaniment's note names),
  then read beats from the beat map. On the first real practice recording, following was
  within 1 beat 97% of the time (median 0.26 beats) after fixing a follower bug this
  exposed: a pause allowance between verse and chorus, where the accompaniment runs on.

## iOS app (`ios/`)

- `SingItCore` holds everything testable, with no UIKit/AVFoundation:
  - `Hymn` decodes the pipeline JSON.
  - `Performance` expands one part into sung order: every `form` pass back to back, times
    in quarter beats. It resolves each pass's lyric line, splices in men's echo lines for
    the parts they name, turns `verses`-restricted notes into rests for other verses, and
    breaks lyrics into display lines at printed system boundaries.
  - `PitchDetector` is YIN on 16 kHz mono (64 ms window, 20 ms hop, 60–1100 Hz).
  - `ScoreFollower` finds where the singer is from their pitch and syllable starts (the app
    follows the singer, not the organ). It is a grid Bayes filter over beat position: mass
    advances at the tempo, waits at fermatas and pass ends, and diffuses (`diffusion`: 3
    with an organ keeping time, 12 singing alone). Pitch matches by note name in any
    octave by default. Per-frame evidence is tempered (`evidenceWeight`) and floored
    (`wrongNoteLikelihood`); silence is neutral (it looks like a breath, not a rest).
    Tempo adapts but stays within 10% of the hymn's marked range: adapting from its own
    lagging estimate once dragged it from 104 to 84 bpm on a real recording. Recovery
    re-spreading and a `reach` limit are implemented but off: both caused more lost or
    stuck followers than they fixed. It doesn't advance until the first pitched frame,
    so the organ introduction is skipped.
  - `Part` has the four printed voices plus `.melody` (the soprano line, meant for any
    octave) and `.anyPart` (every chord note counts). `Performance(.anyPart)` cuts the
    timeline wherever any voice moves and gives each piece all sounding pitches
    (`targets`, with `targetParts` naming the voice of each).
  - Any part scores against that chord line but must not *follow* with it: with every
    chord note acceptable in any octave, almost any pitch fits, and following degraded
    from 0.5 to 6 beats. The session instead runs the four voice followers, leads with
    the one whose evidence has been best over ~4 s (switching only on a clear margin),
    and pulls the others to the leader's position so a switch never moves the position.
  - Practice mode: `BeatMap` converts recording time ↔ performance beat (negative during
    the introduction). The controller calls `SingingSession.setMusicClock(beat:rate:)`
    before each audio block; the session then takes the position from the music instead
    of the follower (hint `.intro` before beat 0). It also measures how far behind the
    music the singer sings (`musicLag`: the lag that best lines up the last 30 s of
    singing with the notes by name) and scores against that; ~0.3–0.5 s is typical.
  - Octaves: `Performance(octaveShift:)` moves a part by whole octaves (a man singing the
    melody is -1). Choosing an octave (`coachOctave`) only aims the singer: notes are drawn
    there and slips get the `.octaveSlip` hint and yellow dots, but still count. Holding
    them to it (`anyOctave` off, the setup's "Other octaves count as misses", off by
    default) is separate: silently making a suggested octave strict zeroed a
    singer's scores when they drifted two octaves down. Strict mode's hint says which way to go; followers always match any octave, so slipping out of it
    doesn't lose the place. `Scorekeeper` records the octave of every note either way,
    and `SessionSummary` reports octave shares and where the singer changed octave.
  - Voice: `VoiceRange` (10th–90th percentile of sung pitches, from session
    `pitchCounts` or a range check) and `VoiceFit.options` (how much of each part, in
    the octaves people really sing it, lies in that range). Never transpose the music to
    fit the singer: practice must match church (see Product intent).
  - `PartSynth` renders one part as a soft organ-like tone on an accompaniment
    recording's timeline (sample 0 = recording time 0, notes placed by the beat map),
    in the singer's chosen octave. Practice mode can play it over the accompaniment or
    alone ("My part only": the accompaniment plays the introduction or lead-in, then is
    muted). `AudioCapture` starts both player nodes at the same host time so they stay
    locked; a buffer can't be scheduled mid-way, so a seek schedules a slice.
  - `SessionSummary.recurring`: the same written note missed in 2+ passes, with whether
    it was sung high/low, wandering (mean |cents| ≫ |mean cents|), or in the wrong octave,
    plus the printed line to practise. The app loops that line with the accompaniment.
  - `SingingSession` ties audio → pitch → follower → `Scorekeeper`, and produces
    `LiveState`, the pitch trace and the `SessionSummary`. With part = nil (Auto) it runs
    four followers and settles on the part with clearly the highest log evidence.
    `process(_:)` runs on the audio queue; the other members are read from the UI (NSLock).
- Tests synthesise singers from the golden hymn JSON, so pipeline changes are exercised
  by the app tests too: `singFrames` (clean, with detune and wrong notes) and
  `SloppySinger` (modelled on real recordings of an untrained singer: an octave down, notes ~1.5
  semitones off with drift, uneven tempo, dropped frames, unreliable syllable starts).
  Tune follower settings with `FollowerSweep` against `SloppySinger`, over several
  seeds: single-seed results were misleading. Tuning for a clean synthetic singer does
  not transfer to untrained singers, who are the app's audience.
- Real recordings: the app saves each session's audio in Documents/Recordings. Pull them
  from the phone (plugged into the Mac) with `xcrun devicectl device copy from --device
  <id> --domain-type appDataContainer --domain-identifier <bundle id> --source
  Documents/Recordings --destination DIR` into `recordings/` (gitignored), decode with
  `ffmpeg -i X.m4a -ac 1 -ar 16000 -f f32le X.f32`, and replay with the `singit-replay`
  executable (`swift build -c release --product singit-replay`; `--onsets`, `--alone`).
  There is no ground truth for where the singer was, so judge by plausibility.
- App layer (`ios/SingIt`): `AudioCapture` (AVAudioEngine tap → 16 kHz analysis samples
  plus a full-rate AAC recording in Documents/Recordings, alongside a JSON summary; in
  practice mode it also plays the accompaniment through an AVAudioPlayerNode on the same
  engine, over Bluetooth A2DP with the phone's mic, and stamps each block with the music
  time the singer heard: player position − block length − output/input latency. Voice
  processing is forced on when the music comes out of the speaker, to cancel its echo),
  `AccompanimentStore` (MP3 download to Caches),
  `SingController` (@Observable, refreshes the UI from the session at ~30 Hz), and SwiftUI
  views: hymn list/search → setup (part incl. Auto, verse, strictness, voice processing)
  → sing screen (`NoteRollView` piano roll with the pitch trace, `TuningMeterView`,
  `LyricsView`; tap a line to re-sync) → `SummaryView` (with "Practise" looping a line),
  plus `RecordingsView` and `RangeCheckView`. `VoiceProfile` (UserDefaults) accumulates
  each session's pitch counts and the range check, and drives the setup screen's
  part/octave suggestions. Hymn JSON
  is bundled as the folder `json` straight from `hymns/json`.

## Product intent

Practice must stay true to church: the hymn in its written key at church tempo. To help
with range or difficulty, diagnose and guide (which octave or part fits, cues to stay in
it, drilling a line); never transpose or simplify the music.


"Sing It" is an iOS app (first platform) for singing LDS hymns during church services.
It should get the singer to sing their part more accurately.

Core features:
- **Hymn selection** by hymn number or title. The source is the LDS hymnbook published on
  ChurchOfJesusChrist.org.
- **Display** the words and the notes while the user sings.
- **Part selection**: hymns are written in four parts (soprano, alto, tenor, bass). The user
  picks a part, or the app detects which part they are singing.
- **Recording** of the user's audio.
- **Real-time pitch feedback**: the user's sung frequency compared with the target note of
  their part, showing where they are and where they need to go.
- **Scoring** that accumulates over the course of the hymn.

## Hard problems

These requirements decide the architecture.

1. **Isolating the user's voice in a noisy room.** The app runs during a live service, with
   the congregation singing and an organ or piano playing, often in the same notes. The pitch
   detector has to follow the user's voice, not the loudest source in the room. The mic
   setup (phone mic or close-talking headset) and any voice processing will strongly affect
   accuracy.
2. **Low-latency pitch tracking.** Feedback has to feel immediate while the user sings, so the
   audio-to-pitch pipeline must run in real time on the device.
3. **Knowing the current position in the hymn.** To compare against "the note I should be
   singing," the app must track where the congregation is in the hymn: which verse, measure,
   and note. Tempo varies from ward to ward and organist to organist.
4. **Structured hymn data.** Each hymn needs machine-readable pitches and rhythms for all four
   parts, aligned to the lyrics of every verse. This comes from the PDF pipeline above.
   Hymn material (PDFs, recordings, and anything derived from them: JSON, beat maps,
   MIDI) is copyrighted by the Church and others and is never committed: each developer
   downloads it for their own use and converts it locally (see the README).
