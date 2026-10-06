
### 2026-10-06-editing-rerun.json

macOS 27.0 (26A428); Chrome Chrome/149.0.7827.55; 10 retained entries; 0 dropped.

| Marker → next marker | ms | Focus events / state changes | Visibility events / state changes | DOM records | Page input | Pointer | Viewport | Observations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| (before first marker) | 1 | 0 / 0 | 0 / 0 | 0 | 0 | 0 | 0 | no listed signal recorded; action unverified |
| corrected-editing-launch | 18530 | 3 / 1 | 0 / 0 | 0 | 0 | 0 | 0 | document focus false |
| editing-type | 26311 | 0 / 0 | 0 / 0 | 0 | 0 | 0 | 0 | document focus false |
| editing-paste | 9310 | 0 / 0 | 0 / 0 | 0 | 0 | 0 | 0 | document focus false |
| editing-submit | 13762 | 0 / 0 | 0 / 0 | 0 | 0 | 0 | 0 | document focus false |
| editing-end | 7 | 0 / 0 | 0 / 0 | 0 | 0 | 0 | 0 | document focus false |

State sampling nominally runs every 25 ms; 1 changed-state samples were recorded. Sampling may be throttled and can miss short transitions. Event listeners supplement it. 0 mutation record details were omitted by batch bounds.

Native telemetry correlated by extension receipt time:

- corrected-editing-launch: host.ready (1), selection.moved (1), selection.will_show (1), selection.key_acquired (2), selection.shown (1), selection.key_resigned (1), app.active (1), selection.pointer_down (1), selection.pointer_up (1), selection.key_down (1), selection.confirmed (1), answer.moved (1), answer.key_acquired (1), answer.shown (1), answer.key_up (1), answer.delta (14), answer.complete (1), answer.pointer_move (1), answer.scroll (3)
- editing-type: answer.scroll (5), answer.pointer_move (18), answer.key_resigned (1), answer.pointer_down (1), answer.key_acquired (1), answer.pointer_up (1), answer.key_down (18), followup.edit_begin (1), followup.edited (17), answer.key_up (18)
- editing-paste: answer.key_down (1), followup.edited (1), answer.key_up (1)
- editing-submit: answer.key_down (1), followup.edit_end (1), followup.submitted (1), answer.key_up (1), answer.delta (15), answer.complete (1)

Counts describe observations, not workflow acceptance. Markers delimit intervals but do not establish that real OS actions occurred. Match them to native evidence and the action/environment matrix. Activation signals count toward the complete workflow; untested actions and environments remain not tested.
Even a focusEmulation=false configuration requires positive controls: an actual switch to another application must produce page blur/hasFocus=false, and switching away from the tab must produce hidden/visibilitychange. A successful CDP command alone does not establish that another attached session is no longer emulating focus.
