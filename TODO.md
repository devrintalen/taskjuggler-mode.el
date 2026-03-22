# taskjuggler-mode TODO

## Movement features

- [ ] `taskjuggler-goto-first-child` / `taskjuggler-goto-last-child` — from a
  block header, jump into its first (or last) child block at depth+1. Complement
  to the existing `taskjuggler-goto-parent`.

- [ ] `beginning-of-defun` / `end-of-defun` integration — set
  `beginning-of-defun-function` and `end-of-defun-function` to delegate to the
  existing `taskjuggler--current-block-header` and `taskjuggler--block-end`
  helpers. Unlocks `C-M-a`, `C-M-e`, `C-M-h` (mark-defun), and
  `narrow-to-defun` for free.

- [ ] Imenu support — add `imenu-generic-expression` or a custom
  `imenu-create-index-function` that builds a hierarchical index of all named
  declarations (`task foo`, `resource bar`, etc.) using
  `taskjuggler--named-declaration-re`. Enables `M-x imenu`, `consult-imenu`,
  and `which-function-mode`.

- [ ] `taskjuggler-forward-block` / `taskjuggler-backward-block` — jump to the
  next/previous moveable block at any nesting depth (linear scan through the
  file). Bind to `C-M-n` / `C-M-p`.

## Editing features

- [ ] `taskjuggler-mark-block` — select the current block (including preceding
  comments) as an active region. Bind to `C-M-h` or wire up via `mark-defun`
  once defun integration is done.

- [ ] `taskjuggler-clone-block` — duplicate the current block immediately after
  itself with a blank-line separator, leaving point on the clone's header.
  Useful for creating a new task based on an existing one.

- [ ] `taskjuggler-narrow-to-block` — narrow the buffer to the current block
  (header through closing `}`). Thin wrapper around `narrow-to-region` using
  the existing bounds helpers. Bind to `C-x n b`.

- [ ] Date bump at point — `taskjuggler-date-increment` /
  `taskjuggler-date-decrement` bump the date literal under point by one day
  (prefix arg for weeks/months). Detect via `taskjuggler--date-re`, parse with
  `date-to-time` / `format-time-string`. Bind to `C-c C-<up>` / `C-c C-<down>`.

- [ ] `taskjuggler-cycle-complete` — when point is on a `complete` property
  line, cycle the value through 0 → 25 → 50 → 75 → 100 → 0. Bind to `C-c C-c`.

## Infrastructure

- [ ] `which-func` breadcrumb — set `which-func-functions` to a function that
  walks up via `taskjuggler-goto-parent` and returns a path like
  `project > task foo > task bar` for display in the header line.
