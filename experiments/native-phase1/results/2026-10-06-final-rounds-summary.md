# Final Phase 1 physical rounds: per-session summary

Generated with `node experiments/native-phase1/fixture/sessions.mjs <report>` from the raw reports summarized by the round evidence files in this directory. Metadata only. A failed start or session is not hidden; see the results document for attribution.

### round1-fullscreen-handle.json

macOS 27.0 (26A428); Chrome Chrome/149.0.7827.55; host b5bb02f9af9c; 937 page and 978 extension entries.

| # | Invoked (UTC) | Route | Host | Start valid | Focus | Visibility | Input isolation | DOM | Ended |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 18:08:28.496 | shortcut (Alt+Shift) | cold PID 41898 | yes | pass | pass | pass | pass | native_closed after 16.7 s |
| 2 | 18:09:07.806 | shortcut (Alt+Shift) | warm | yes | pass | pass | **FAIL** | pass | native_closed after 30.1 s |

**Session 1** (18:08:28.496–18:08:45.245)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift
- Unpressed page hover/motion: 69; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×2, selection.drag_end×2, selection.pressed_pointer_left×1, selection.pressed_pointer_returned×1, selection.confirmed×1, answer.shown×1, answer.complete×1, answer.copied×2
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +15949 ms

**Session 2** (18:09:07.806–18:09:37.951)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift
- Pressed-button page pointer events: pointerover[pressed]×12, pointermove[pressed]×12, pointerout[pressed]×12 18:09:30.501–18:09:32.366
- Unpressed page hover/motion: 296; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×2, selection.drag_end×2, selection.confirmed×1, answer.shown×1, answer.complete×2, followup.edit_begin×1, followup.submitted×1, answer.copied×3, preview.shown×1, answer.resize_drag_start×7, answer.resize_drag_end×7, answer.pressed_pointer_left×1, answer.moved×287, answer.pressed_pointer_returned×1, answer.resized×329, answer.closed×1, preview.closed_with_parent×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +1448 ms

Outside sessions (controls and returning to other apps): 18:07:40.548 focus; 18:07:40.548 focus; 18:07:40.548 focusin; 18:08:05.326 mark:round1-ready; 18:09:01.193 blur; 18:09:01.193 focusout; 18:09:01.193 blur; 18:09:02.501 focus; 18:09:02.501 focus; 18:09:02.501 focusin; 18:09:02.502 blur; 18:09:02.502 focusout; 18:09:03.497 blur; 18:09:06.116 focus; 18:09:07.005 focus; 18:09:07.005 focusin; 18:09:39.398 blur; 18:09:39.398 focusout; 18:09:39.398 blur

### round2-edge-resize-partial.json

macOS 27.0 (26A428); Chrome Chrome/149.0.7827.55; host 2cfb51642c1e; 927 page and 971 extension entries.

| # | Invoked (UTC) | Route | Host | Start valid | Focus | Visibility | Input isolation | DOM | Ended |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 18:18:46.119 | shortcut (Alt+Shift) | cold PID 42400 | yes | **FAIL** | **FAIL** | pass | pass | native_closed after 38.8 s |
| 2 | 18:19:28.635 | shortcut (Alt+Shift) | warm | yes | pass | pass | pass | pass | native_closed after 7.8 s |
| 3 | 18:21:16.603 | shortcut (Alt+Shift) | warm | **no** | pass | pass | pass | pass | native_closed after 10.9 s |

**Session 1** (18:18:46.119–18:19:24.960)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Shift, keyup:Alt
- Focus: blur×2, focusout×1, focus×2, focusin×1 18:19:20.858–18:19:23.456; first non-focused state 18:19:20.858
- Visibility: visibilitychange×2, sample-state-change×1 18:19:20.858–18:19:23.455
- Unpressed page hover/motion: 102; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×2, selection.drag_end×2, selection.confirmed×1, answer.shown×1, answer.complete×2, followup.edit_begin×1, followup.submitted×1, answer.pressed_pointer_left×21, answer.live_resize_begin×3, answer.moved×217, answer.resized×273, answer.pressed_pointer_returned×21, answer.live_resize_end×3, answer.scroll_changed×44, preview.shown×1, preview.closed×1, answer.copied×4
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +14234 ms

**Session 2** (18:19:28.635–18:19:36.448)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Shift, keyup:Alt
- Unpressed page hover/motion: 1; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×2, selection.drag_end×2, selection.confirmed×1, answer.shown×1, answer.complete×1, answer.closed×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +2746 ms

**Session 3** (18:21:16.603–18:21:27.498)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift, keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift
- Unpressed page hover/motion: 2; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×2, selection.drag_end×2, selection.confirmed×1, answer.shown×1, answer.complete×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +1657 ms

Outside sessions (controls and returning to other apps): 18:18:05.210 focus; 18:18:05.211 focus; 18:18:05.211 focusin; 18:18:07.664 mark:round2-ready; 18:18:21.745 blur; 18:18:21.745 focusout; 18:18:21.745 blur; 18:18:35.086 focus; 18:18:35.086 focus; 18:18:35.086 focusin; 18:19:39.194 blur; 18:19:39.194 focusout; 18:19:39.194 blur; 18:21:14.343 focus; 18:21:14.343 focus; 18:21:14.343 focusin; 18:21:15.280 blur; 18:21:15.280 focusout; 18:21:29.154 blur

### round2b-fullscreen-workflow.json

macOS 27.0 (26A428); Chrome Chrome/149.0.7827.55; host 9ab4d80d182e; 549 page and 539 extension entries.

| # | Invoked (UTC) | Route | Host | Start valid | Focus | Visibility | Input isolation | DOM | Ended |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 18:30:16.573 | shortcut (Alt+Shift) | cold PID 43011 | yes | **FAIL** | pass | **FAIL** | pass | native_closed after 50.3 s |

**Session 1** (18:30:16.573–18:31:06.885)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Shift, keyup:Alt
- Focus: blur×2, focusout×1 18:30:34.262–18:30:34.262; first non-focused state 18:30:34.262
- Page keys: keydown×4, keyup×3 18:30:27.676–18:30:32.354 (keydown:Meta, keyup:Meta, keydown:Meta, keyup:Meta, keydown:Meta, keyup:Meta, keydown:Meta)
- Unpressed page hover/motion: 26; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×1, selection.drag_end×1, selection.confirmed×1, answer.shown×1, answer.complete×4, followup.edit_begin×3, followup.submitted×3, answer.copied×1, followup.paste_matches_copy×2, followup.select_all×2, answer.moved×114, answer.resized×10, answer.pressed_pointer_left×18, answer.pressed_pointer_returned×18, answer.live_resize_begin×1, answer.live_resize_end×1, answer.scroll_changed×1
- Input sources: com.apple.keylayout.US

Outside sessions (controls and returning to other apps): 18:28:22.922 focus; 18:28:22.922 focus; 18:28:22.922 focusin; 18:28:24.523 mark:round2b-ready; 18:28:37.239 blur; 18:28:37.239 focusout; 18:28:37.239 blur; 18:29:53.365 visibilitychange(hidden); 18:30:02.076 focus(hidden); 18:30:02.076 focus(hidden); 18:30:02.076 focusin(hidden); 18:30:02.102 visibilitychange

### round3-true-fullscreen.json

macOS 27.0 (26A428); Chrome Chrome/149.0.7827.55; host 9ab4d80d182e; 1370 page and 1403 extension entries.

| # | Invoked (UTC) | Route | Host | Start valid | Focus | Visibility | Input isolation | DOM | Ended |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 18:37:22.623 | shortcut (Alt+Shift) | cold PID 43266 | **no** | pass | pass | pass | pass | native_cancelled after 1.6 s |
| 2 | 18:37:24.956 | shortcut (Alt+Shift) | warm | **no** | pass | pass | **FAIL** | pass | native_closed after 29.0 s |

**Session 1** (18:37:22.623–18:37:24.174)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift
- Unpressed page hover/motion: 21; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×1, selection.drag_end×1, selection.cancelled×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +43045 ms

**Session 2** (18:37:24.956–18:37:53.928)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift
- Pressed-button page pointer events: pointerover[pressed]×1, pointermove[pressed]×1, pointerout[pressed]×1 18:37:37.239–18:37:37.239
- Unpressed page hover/motion: 262; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×1, selection.drag_end×1, selection.confirmed×1, answer.shown×1, answer.complete×3, followup.edit_begin×2, followup.submitted×2, followup.rejected×1, answer.copied×1, preview.shown×1, preview.closed×1, answer.pressed_pointer_left×63, answer.live_resize_begin×2, answer.moved×450, answer.resized×526, answer.pressed_pointer_returned×63, answer.live_resize_end×2, answer.scroll_changed×5, answer.closed×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +13291 ms

Outside sessions (controls and returning to other apps): 18:34:04.095 focus; 18:34:04.095 focus; 18:34:04.095 focusin; 18:34:12.527 blur; 18:34:12.528 focusout; 18:34:14.218 blur; 18:34:15.461 visibilitychange(hidden); 18:34:18.237 mark:round3-fullscreen-ready(hidden); 18:37:18.591 focus(hidden); 18:37:18.639 visibilitychange; 18:38:07.219 blur

### round4-fullscreen-fix.json

macOS 27.0 (26A428); Chrome Chrome/149.0.7827.55; host 02acdb70d98d; 786 page and 723 extension entries.

| # | Invoked (UTC) | Route | Host | Start valid | Focus | Visibility | Input isolation | DOM | Ended |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 19:23:44.486 | shortcut (Alt+Shift) | cold PID 44073 | yes | pass | pass | pass | pass | native_cancelled after 1.0 s |
| 2 | 19:23:46.564 | shortcut (Shift+Alt) | warm | yes | pass | pass | pass | pass | native_closed after 22.8 s |

**Session 1** (19:23:44.486–19:23:45.511)
- Activation signals: keydown:Alt, keydown:Shift, keyup:Alt, keyup:Shift
- Unpressed page hover/motion: 1; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.drag_start×1, selection.drag_end×1, selection.cancelled×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +26119 ms

**Session 2** (19:23:46.564–19:24:09.383)
- Activation signals: keydown:Shift, keydown:Alt, keyup:Shift, keyup:Alt
- Unpressed page hover/motion: 37; DOM records: 0; viewport events: 0
- Native: selection.shown×1, selection.modifier_option_down×1, selection.modifier_option_up×1, selection.drag_start×1, selection.drag_end×1, selection.confirmed×1, answer.shown×1, answer.complete×4, answer.copied×4, answer.shield_raised×1, answer.pressed_pointer_left×20, answer.live_resize_begin×1, answer.moved×167, answer.resized×180, answer.pressed_pointer_returned×19, answer.pressed_pointer_released_outside×1, shield.lowered×1, answer.live_resize_end×1, followup.edit_begin×3, followup.submitted×3, followup.rejected×1, preview.shown×1, preview.closed×1
- Input sources: com.apple.keylayout.US
- First page focus/visibility transition after end: blur +2247 ms

Outside sessions (controls and returning to other apps): 18:41:32.860 focus; 18:41:32.860 focus; 18:41:32.860 focusin; 18:41:39.343 mark:round4-ready; 18:42:19.731 mark:round4-ready-lg-fullscreen; 18:55:02.884 blur; 18:55:02.884 focusout; 18:55:02.884 blur; 18:55:04.133 visibilitychange(hidden); 19:23:39.594 focus(hidden); 19:23:39.594 focus(hidden); 19:23:39.594 focusin(hidden); 19:23:39.640 visibilitychange; 19:23:41.017 blur; 19:23:41.017 focusout; 19:23:44.008 focus; 19:23:44.008 focusin; 19:24:11.629 blur; 19:24:11.629 focusout; 19:24:15.731 blur; 19:24:16.985 visibilitychange(hidden)
