# taskjuggler-mode TODO

## Movement features

- [x] `taskjuggler-goto-first-child` / `taskjuggler-goto-last-child` — from a
  block header, jump into its first (or last) child block at depth+1. Complement
  to the existing `taskjuggler-goto-parent`.

- [x] `beginning-of-defun` / `end-of-defun` integration — set
  `beginning-of-defun-function` and `end-of-defun-function` to delegate to the
  existing `taskjuggler--current-block-header` and `taskjuggler--block-end`
  helpers. Unlocks `C-M-a`, `C-M-e`, `C-M-h` (mark-defun), and
  `narrow-to-defun` for free.

- [x] `taskjuggler-forward-block` / `taskjuggler-backward-block` — jump to the
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

- [x] Insert timestamp at point. Can this be similar to the org mode implementation?
- [ ] Edit timestamp at point. Similar to above, I like the org-mode implementation.


## Infrastructure

