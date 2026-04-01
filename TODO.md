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

## Infrastructure

