# Recordless iOS: design spec

Exact values for building each screen. Design frame: iPhone 390 x 844 pt, light mode. Token names refer to `tokens.json`. Source for each screen: `screens/<File>.dc.html`.

## Shared patterns

| Pattern | Spec |
| --- | --- |
| Screen background | `background` #FBFAF7 |
| Top inset (no nav bar) | content starts 62 pt from top (status bar + 8) |
| Side padding | 20 pt |
| Large title | 32 pt, weight 700, `foreground` |
| Section label | 12 pt, weight 700, uppercase, tracking 0.06 em, `mutedForeground` |
| Card | `card` fill, 1 pt `border`, radius 14 (16 for large cards), shadow 0 1 2 at 5% #111827 |
| Primary button | height 54 (50 in bottom bars), radius 14, `primary` fill, `primaryForeground` 17 pt / 700 |
| Secondary button | same size, `card` fill, 1 pt `border`, `foreground` text |
| Chip / pill | height 36, horizontal padding 12, full radius, 1 pt `border`, `background` fill, 14 pt |
| Status tag | padding 3 x 10, full radius, 12 to 13 pt / 700 (e.g. Draft: `infoSoft` fill, `primary` text) |
| Bottom sheet | top radius 22, grabber 40 x 5 `border`, padding 8 / 20 / 34, backdrop #4A4F5C |
| Tab bar | height 84, 94% white, 1 pt top `border`; items Listen, Notes, Settings; active `primary` 700, inactive `mutedForeground` 600; label 11 pt |
| Icons | stroke icons, 2 pt stroke, round caps (Lucide style; SF Symbols equivalents are fine) |

## 1. Unlock (`Main.dc.html`; desktop `VaultGate.tsx`)

- Centered: logo 104 pt, wordmark "Recordless" (Instrument Serif 44 pt, -0.5 tracking), tagline "Meeting notes without the recording." 17 pt `mutedForeground`.
- Bottom group: chip "Notebook locked" (lock icon, `secondary` fill); primary "Unlock with Face ID" (Face ID glyph); text link "Use passphrase instead" (16 / 600, 44 pt tall); footnote 13 pt "Your notes are encrypted on this device. Recordless never stores audio or transcripts."
- Face ID failure copy (desktop): "Didn't recognise that. Try again or use your passphrase."

## 2. Home / Listen tab (`Home.dc.html`; desktop `app/page.tsx`, `IdleStage`, `TodayNotes`)

- Header: date (15 pt `mutedForeground`, e.g. "Tuesday, November 3"), greeting 32 / 700 ("Good morning" / "Good afternoon" / "Good evening"); round 44 pt lock button at right.
- Start card: chips "iPhone Microphone" and "English" (mic and language pickers); primary "Start listening" (waveform icon); line 13 pt "**In memory only** — no audio or transcript is saved".
- "Today" label with "All notes" link (opens Notes tab). Cards per note: title 16 / 700, time 13 pt, first summary line 14 pt, and either tag "Notes ready" (`successSoft` / `success`) or "Writing notes on this iPhone…" with a progress ring (`info`).
- "Earlier this week": plain rows 48 pt tall, title left, weekday right, `border` dividers.
- Empty state (desktop): "No notes today." / "Your notes will appear here."

## 3. Live session (`Live.dc.html`; desktop `LiveStage.tsx`, `CapturedCard.tsx`)

Top to bottom, gap 16, padding 54 / 20 / 40:

1. Logo 72 pt, centered.
2. Row: elapsed time (56 pt / 700, tabular figures, -1 tracking) left; status pill right.
3. Mic level card.
4. Captured card (fills remaining height).
5. Controls: round 54 pt Pause button (outline) + primary "End session" (stop icon) filling the rest.

### Status pill

`infoSoft` fill, `primary` text 15 / 700, padding 8 x 14, full radius.

| State | Icon | Label |
| --- | --- | --- |
| listening | 4 rounded voice bars | Listening… |
| transcribing | 3 dashes fading 1.0 / 0.6 / 0.3 | Transcribing… |
| paused | (carry over from desktop) | Paused |
| finishing | spinner | Finishing… |

Show Transcribing for at least 400 ms (desktop `MIN_TRANSCRIBING_MS`) to avoid flicker.

### Mic level card

Card padding 12 x 14, radius 12. Row: mic icon 15, "iPhone Microphone" 14 / 600, level label right (14 / 700). Below: 16 equal segments, height 10, gap 3, radius 2.

| Segments | Zone | Lit color | Unlit color |
| --- | --- | --- | --- |
| 1–12 | good | `success` #2F8A62 | `successSoft` #E9F4EE |
| 13–14 | warm | `meterAmber` #DC9418 | `meterAmberSoft` #FBF4E7 |
| 15–16 | hot | `meterOrange` #E56106 | `meterOrangeSoft` #FCE9DC |

| Label | Color | Shown when (thresholds are an open question; tune on device) |
| --- | --- | --- |
| Good level | `success` | peak in segments 4–12 |
| Too quiet | `warning` #935610 | 3 or fewer segments lit |
| Too loud | `meterHotText` #A84A0A | peak in segments 15–16 |

Lit count = round(level x 16), level 0...1 from smoothed RMS. Never use red.

### Captured card

- Header (padding 16 / 18 / 12, bottom `border`): "Captured" 16 / 700 `primary`; word count right ("1,284 words", tabular); line 13 pt "**In memory only** — never written to disk" with a chip icon.
- Body: one `primary` block per transcribed word (height 10, radius 3, width = word length x 7 pt as a stand-in, gap 5, line gap 9). Lines fill from the top; once full, newest stays at the bottom. Opacity by segment age: newest 0.72, previous 0.5, 2–3 back 0.32, older 0.2. New segments draw in word by word (stagger up to 140 ms, max 2 s per segment); with Reduce Motion, no stagger.
- Footer 12 pt: "Words are counted, never shown. The transcript clears when you generate notes or discard."
- Never render actual words.

## 4. Generate notes sheet (`Generate.dc.html`; desktop `GenerateNotesPanel.tsx`, `SessionCompleteCard.tsx`)

- Tag "Session ended" (`successSoft`); title "Generate notes" 26 / 700; "32 min · 4,210 words held in memory. They clear once notes are written or you discard."
- "Write notes with" radio cards: **On this iPhone** ("A local model with no network access. Nothing leaves your device.") selected = 2 pt `primary` border on `primarySoft`; **Private cloud** ("A secure enclave on NEAR AI. Text is sent only after its attestation verifies.").
- Toggle "Scrub identifiers", default on.
- Primary "Generate notes"; text button "Discard session" in `destructive`. Discard confirms first (desktop copy: "Discard this session? The transcript is cleared from memory.").
- Desktop also shows attestation status for private cloud (Checking / Verified / Not verified / Unavailable); add it under the Private cloud card.

## 5. Note, draft (`Note.dc.html`; desktop `SummaryPanel.tsx`, `ReviewDraftBand.tsx`)

- Nav: back "Notes" (chevron), Share and More icon buttons (44 pt).
- Title 30 / 700 (editable), meta "Today · 2:30 PM · 32 min", tags "Written on this iPhone" (`secondary`) and "Draft" (`infoSoft` / `primary`).
- Review band (`primarySoft`, 1 pt `primaryBorder`, radius 14): 30 pt `primary` square with pen icon; "Review your draft" 16 / 700 #1A2C52; "Edit anything, or rewrite it from a template. **Save notes** keeps only your notes and clears the transcript." 14 pt #33415C.
- Sections with section labels: Summary (17 pt, 1.5 line height), Decisions (bullets), Action items (checkbox rows 44 pt).
- Fixed bottom bar (padding 12 / 20 / 34, top `border`): secondary "Edit template" (sliders icon) + primary "Save notes" (check icon), equal widths, height 50.
- Content scrolls; the bottom bar never scrolls away.
- After Save: Draft tag and band go away, transcript is cleared, announce "Notes saved. The transcript was cleared."

## 6. Edit template sheet (`Template.dc.html`; desktop `GenerateNotesPanel.tsx` in edit-template mode)

- Header row: "Cancel" left, title "Edit template" 17 / 700 centered.
- "Template" label + text area (17 pt, 4 rows, radius 12). Default text from desktop: "Summarize the discussion, the decisions and agreements, open questions, and next steps."
- Quick-add chips that append a sentence: "More detail" → "Be more detailed.", "Bullets only" → "Use bullet points only.", "Action items first" → "Put next steps and owners at the top." Added chips show a check and `primarySoft` fill.
- "Rewrite on" segmented control: This iPhone / Private cloud.
- Toggle "Scrub personal info" (names, emails, phone numbers, links, IDs), default on.
- Primary "Rewrite notes"; footnote "The draft is rewritten from this template. The transcript stays in memory until you save."
- Only available while the transcript is still in memory (draft state).

## 7. Notes tab (`Notes.dc.html`; desktop `NotesList.tsx`, `NotesSearchDialog.tsx`)

- Large title "Notes"; search field (height 40, `secondary` fill, radius 12, placeholder "Search notes"); hint 13 pt "Searches your notes only — transcripts are never kept."
- Grouped lists in cards (rows 60 pt, `border` dividers): "Today", "Earlier this week", then older by month. Row: title 16 / 700, meta 13 pt ("2:30 PM · 32 min" or "Mon · 4:00 PM · 45 min"), trailing tag or chevron.
- Row states: Draft tag; "Writing notes…" (`info`, with progress ring, not tappable); "Queued"; saved = chevron only.
- Empty search: "No matching notes."

## Navigation

```
Unlock --Face ID--> Home
Home <--tab bar--> Notes tab
Home --Start listening--> Live session --End session--> Generate notes (sheet)
Generate notes --Generate notes--> Note (draft)
Generate notes --Discard session--> Home
Note (draft) --Edit template--> Edit template (sheet) --Rewrite notes--> Note (draft)
Note (draft) --Save notes--> Notes tab
Any screen --lock / idle / background policy--> Unlock (clears transcript)
```

## Info.plist strings (proposed)

- `NSMicrophoneUsageDescription`: "Recordless listens to write your meeting notes. Audio stays in memory and is never saved."
- `NSFaceIDUsageDescription`: "Unlock your encrypted notebook."

## Open questions (ask before deciding)

- Which on-device notes model, and on which iPhones it runs well enough.
- Level bar thresholds for Too quiet / Too loud.
- Does listening continue with the screen locked or the app in the background? Live Activity?
- Auto-lock policy: idle timeout like desktop, or on every backgrounding.
- Settings and onboarding screens are not designed.
- Notes sync between iPhone and Mac: in scope?
