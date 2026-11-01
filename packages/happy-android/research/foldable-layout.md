# Foldable and wide-window layout

Steve, on a Galaxy Z Fold7 unfolded: "Header icons are not aligned with
the content on the foldable. Content everywhere on the unfolded foldable
should have bigger paddings. Check out the Google Play one or the GPT
one."

## The device

`adb shell wm size` / `wm density` on the Fold7 (SM-F966U1): the inner
screen is 1968×2184 px at 420 dpi (2.625), so **750×832 dp held upright
and 832×750 dp on its side**. Both are Material's *medium* class
(600–839). Before this change the app treated 750 as a phone: content
ran edge to edge with 16 dp margins (`.context/fold/fold-inner-chat-no-blur.png`
in the parent task: tool cards 1800 px wide, back arrow and ⋮ in the
corners while the text began elsewhere).

## Material 3 adaptive guidance

From m3.material.io, Foundations › Layout › Breakpoints / Applying layout,
and developer.android.com "Use window size classes":

| Class    | Width      | Margin | Panes                                       |
|----------|------------|--------|---------------------------------------------|
| Compact  | < 600      | 16     | 1                                           |
| Medium   | 600–839    | 24     | 1 (2 only for low-density content, 50/50)   |
| Expanded | 840–1199   | 24     | 1 or 2 (list-detail), 24 spacer             |
| Large    | 1200–1599  | 24     | 2, a fixed 412 pane beside a flexible one   |

- Margins grow with the class; Material does **not** stretch components
  to fill the extra width. Long lines are shortened "with wider margins, a
  narrower container, or more panes". The guidance on line length is
  40–60 characters ideal, up to about 120 with more leading on large
  screens; the adaptive codelab holds body text to a 60-character measure.
- Top app bars on medium and up keep their own 16 dp (navigation slot 4 +
  48 target) structure, but in pane layouts the bar belongs to its pane
  and spans the pane's width, so its glyphs line up with that pane's
  content.
- Side sheets are at most 400 wide; bottom sheets 640 wide, centred;
  basic dialogs 280–560.

## What the references do

I could not drive either app on a device here (the Fold is in use by
another agent; no Play-signed emulator image), so this is from public
coverage and screenshots, and should be checked by eye on the Fold.

**Google Play** (large-screen redesign, 2022–2023; 9to5Google,
Android Police). On tablets and unfolded foldables it moves its tabs into a
navigation rail and uses the room for content, not for stretching: the
home is a grid of cards, the app page is two columns (details, then
recommendations), and search results can sit beside an app page. The
search bar narrows instead of spanning the window. Google also now ranks
letterboxed and stretched phone layouts lower and badges apps "built for
large screens". Exact margins are not published; to be measured on the
Fold.

**ChatGPT for Android.** OpenAI documents nothing about tablet or foldable
layouts; its changelog through 1.2026.293 mentions none, and its help
pages describe the same slide-out history drawer on every Android device.
I found no first-hand description of its unfolded layout, so what it does
there is Steve's observation, not something this research confirmed. For
comparison, other chat clients that adapted to foldables (open-source,
on GitHub) hold the transcript and composer to a centred column of 480–720
dp (Memex 480, Cursor-for-Android 640, Rakazo 720) and go two-pane only
from 700–840.

What Steve asked for, and what Material and those clients agree on: a
centred column with at least Material's margins rather than a phone
layout stretched across the glass, with the bar's icons on the column's
edges.

## Decision

**One shared token set by width class** (`ui/layout/WindowLayout.kt`,
`ContentTokens`, read through `LocalWindowLayout.current.content`):

| class    | margin | max content (keyline to keyline) | column (with its 16 inset) | keyline from the edge |
|----------|--------|----------------------------------|----------------------------|-----------------------|
| compact  | 16     | none                             | window                     | 16 (411)              |
| medium   | 24     | 640                              | 672                        | 24 up to 688, 55 at 750 |
| expanded | 24     | 768                              | 800                        | 36 at 840, 256 at 1280 |

- Content sits in one column, `Modifier.contentMaxWidth(layout)`: it
  keeps `margin − 16` (the *gutter*) from the pane and is held to the
  column width, centred. Cards, settings groups, message text, list rows
  and composer then take their own 16 inset inside it, so all of them
  meet on one keyline per side.
- 640 at medium is about 70 characters of 16 sp body text, inside
  Material's range, and on the Fold upright it gives 55 dp keylines: the
  "bigger paddings" Steve asked for, as a centred column. 768 at expanded
  keeps happy-app's layout.ts 800 column.
- Compact changes nothing: the gutter is 0 and the column is the window.
- **Headers:** every top bar is laid out on the same column, and its
  controls are 48 targets placed 4 in from it, so a 24 glyph lies exactly
  on the keyline (`HeaderSpec.paddingHorizontal = inset − 12`). This
  holds for `Header` (legacy chat, machine, changelog, onboarding, new
  session), `StackHeader`, `AgentTopBar`, and the Material `TopAppBar`s of
  the agent conversation and Chief of Staff. The account menu keeps its 32
  avatar on the keyline (48 target with 4 either side in the navigation
  slot). Home's bar, on both homes, then comes a card's 16 further in
  (Steve: "the avatar/picker should be aligned with the left side of the
  content inside the groups, and the same on the right"): the avatar's
  left is the rows' avatars' and marks', the settings glyph's right the
  rows' content end, keyline + 16 at every width (32, 71, 112, 272 from the
  window at 411, 750, 832, 1280). On compact this also fixed `Header`: it used to put glyphs 28 in
  (16 padding + 12 of slot) while the content below was at 16.
- **Dialogs and sheets:** `ContentTokens.dialogMaxWidth` (560, M3 basic
  dialog) for `PromptModal` and the duplicate sheet,
  `ContentTokens.sheetMaxWidth` (640, M3 bottom sheet) for picker sheets.
- **Browser chrome:** the toolbar (back, forward, reload, share) is on
  the column, its outer glyphs on the keyline; the page itself stays full
  width.

**Single pane on the Fold.** Agreed with the compose and tablet agent: the
Fold upright (750) is one pane with the centred column above. Steve then
moved the two-pane tablet shell from happy-app's 768 to Material's 840
(expanded): `TabletBreakpoint` is now `WidthClass.expandedMin`, one number
for both, so the Fold on its side (832) is also one pane with the medium
column, and the shell and the expanded tokens start together. Under the
shell the same tokens apply inside the detail pane.

## Tests

`ui/layout/FoldableLayoutTest.kt` runs agent home, legacy home, the
agent chat, the legacy chat, settings, artifacts and a surface at 411
(phone), 750 (Fold inner upright), 832 (on its side) and 1280 (tablet) and asserts that content
starts and ends on the keyline the tokens give, and that the bar's
leading glyph's left edge and trailing glyph's right edge are the
content's. `ContentWidthTest` pins the classes, tokens and keylines;
`ContentWidthCallersTest` the modifier through a real `ItemGroup`.
`TabletShellTest` signs in at 750, 768 and 832 (one pane, phone home on
the medium keyline) and at 840 (the shell, a 252 sidebar).
With `HAPPY_SHOTS_DIR` set they write `foldable-<screen>-<width>.png`.
