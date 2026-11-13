# The page against Apple's HIG Foundations

Checked November 2026 against the Foundations pages, by page and rule, without
copying their text (the repository is public). Contrast is measured, not
guessed.

| Item | Page | Verdict |
| --- | --- | --- |
| Text 7:1 | Accessibility, Color | Met: body 11.4:1, secondary 7.4:1 (8.3:1 on panels), warnings 8.5:1, ink on buttons 8.2:1, on yellow 15.4:1, canvas labels 9.1:1. |
| Shapes that mean something 3:1 | Accessibility, Color | Met: sound level 4.0:1, written marks 8.4:1, field and drop edges 4.7-5.3:1. Neighbouring notes in the close-up are 1.8:1 on purpose: context, not information. |
| Colour never alone | Color | Met: written and heard differ in shape and position as well as colour; *Check* is a word; warnings have a bar and words. |
| One meaning per colour | Color | Met: yellow is only *chosen*. Focus is white. |
| System font, sizes | Typography | Met: San Francisco on Mac, Segoe UI on Windows, 13 px body, nothing under 12 px. |
| Keyboard alone | Accessibility | Met: native buttons, radios, fields; segmented choices with the arrow keys; table rows with ↑ ↓ Page Up/Down Home End; visible focus ring. Dropping files has *Choose … File…* buttons. |
| Screen readers | Accessibility | Met where the browser does it: labelled controls, radiogroups, `role=status` and `alert` messages, the drawings as images whose labels describe the selected note. |
| Control size and spacing | Layout | Met: 28 px controls, 12 px apart. |
| Nothing important at the bottom | Layout | Met: Download sits at the top of the results. |
| Recover from mistakes | Design principles | Met: nothing changes your files; the download is a new file; deleting a profile asks first. |
| Errors near the problem, saying what to do | Writing | Met: errors show in the card they belong to ("… Choose a Standard MIDI File (.mid)."). |
| Time limits | Accessibility | Met: none. |
| Motion | Motion | Met: only colour fades, off under Reduce Motion. |
| Dark appearance | Dark Mode | User's decision: always dark, the house scheme (0005). |
| Increase Contrast, Dynamic Type | Accessibility | Not met: the page follows browser zoom only. |
| Accessibility Inspector, VoiceOver pass | Accessibility | Not run: needs a Mac. |

## The REAPER windows (Note Fixer)

| Item | Verdict |
| --- | --- |
| Text 7:1, ink on every button, grey or yellow buttons | Met, and checked every frame by `tests/lua/test_scripts.lua`. |
| Chosen not by colour alone | Met: a chosen button also has a bar under its words (as Good Idea). |
| Field and tick-box edges 3:1 | Met: `#8A919C` edges (4.7:1). |
| Keyboard alone | Met as far as ReaImGui goes: keyboard navigation on, Esc closes (not during a run). |
| Control size | Met: 28-point controls, 12 apart. |
| Recover from mistakes | Met: fixing is one undo point; removing an instrument asks first and keeps its profiles; a stopped run carries on with *Skip ones already measured*. |
| Messages say what to do | Met: e.g. a test with notes missing says to check the switch, the keys and that the patch sounds. |
| Long work shows progress and can be stopped | Met: a progress bar, the step in words, and Stop. |
| Text size | Not met: no 100-200% choice yet, which Good Idea has. |
| VoiceOver | Not possible: ReaImGui draws its own window. |
