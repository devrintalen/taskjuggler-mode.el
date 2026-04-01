# taskjuggler-mode TODO

## Editing features

- [x] `taskjuggler-mark-block` — select the current block (including preceding
  comments) as an active region. Bind to `C-M-h` or wire up via `mark-defun`
  once defun integration is done.

- [x] `taskjuggler-clone-block` — duplicate the current block immediately after
  itself with a blank-line separator, leaving point on the clone's header.
  Useful for creating a new task based on an existing one.

- [x] `taskjuggler-narrow-to-block` — narrow the buffer to the current block
  (header through closing `}`). Thin wrapper around `narrow-to-region` using
  the existing bounds helpers. Bind to `C-x n b`.

## Date picker

Replace the org-mode dependency in `taskjuggler-date-dwim` /
`taskjuggler-insert-date` / `taskjuggler-edit-date-at-point` with a
custom inline calendar picker. Target UX:

- Calendar popup appears at point (below the current line), e.g.:

  ```
  start _
        +----------------------+
        |      March 2026      |
        | Su Mo Tu We Th Fr Sa |
        |  1  2  3  4  5  6  7 |
        |        ...           |
        +----------------------+
  ```

- `S-<right>` / `S-<left>` — move by day
- `S-<up>` / `S-<down>` — move by week
- `S-<prior>` / `S-<next>` — move by month
- Typing digits narrows / jumps to a date
- `RET` confirms and inserts; `C-g` cancels

### Approaches considered

**Option A — overlay at point** (recommended)
Render the calendar as an `after-string` overlay anchored below the
current line. A `read-key` event loop drives navigation. No external
dependencies. Most complex to implement; overlays can shift if the
window is narrow or the buffer changes.

**Option B — posframe child frame**
Same visual as A but rendered in a real Emacs child frame via the
`posframe` package. Handles edge cases (scrolling, geometry) more
robustly at the cost of an optional dependency.

**Option C — side window**
Open a small dedicated calendar buffer in a side/bottom window. Easier
to implement correctly than overlays; less "at point".

**Option D — minibuffer + echo area** (org-mode's approach)
Show the calendar in the echo area while reading from the minibuffer.
Familiar but the calendar appears far from the edited text.

### Open questions before implementing

- Should Shift+arrows be the primary interaction, with typing as a
  shortcut? Or should typed input be primary with the calendar as a
  visual aid?
- Option A or B? (B needs posframe as an optional dep.)

## Infrastructure

