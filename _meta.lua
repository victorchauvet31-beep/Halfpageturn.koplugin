local _ = require("gettext")
return {
    name = "halfpageturn",
    fullname = _("Half-page turn"),
    description = _([[Half-page turns for sheet music, inspired by forScore. On marked pages, the first tap shows the top of the next page above the bottom of the current one, so you can keep playing while you turn; the second tap shows the full next page. Only the half of the screen that changes is refreshed, which avoids a full-screen flash.

Turns are normal by default. Mark the pages that need a half-page turn with the "Half-page turn: toggle on current page" action, for example assigned to a corner tap in Taps and gestures; a small symbol shows that a page is marked. In a half-page turn, drag the handle on the dividing line to move it; its position is saved for each turn in the document's settings. The status bar can be hidden in documents that use half-page turns.

Works with fixed-layout documents (PDF, DjVu, CBZ) in page or content zoom mode, not in continuous scroll mode. Half-page turns are paused while Ink Away's drawing mode is open.]]),
}
