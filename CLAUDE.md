# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## What this is

An Emacs major mode (`taskjuggler-mode`) for editing TaskJuggler 3
project files (`.tjp`, `.tji`).

## Development commands

Load and test interactively in Emacs:
```
M-x load-file RET taskjuggler-mode.el RET
```

Byte-compile to check for warnings (the `-L .` puts the repo on the
load path so the submodule files resolve their cross-file `require`s):
```
emacs --batch -L . -f batch-byte-compile *.el
```

Run the ERT test suite:
```
emacs --batch -l test/taskjuggler-mode-test.el -f ert-run-tests-batch-and-exit
```

The entry point hosts the core mode tests and `require`s each subsystem
test file. Subsystem tests can also be run individually, e.g.:
```
emacs --batch -l test/taskjuggler-mode-cal-test.el -f ert-run-tests-batch-and-exit
```
Shared fixtures live in `test/taskjuggler-mode-test-helpers.el`.

Some tests exercise the real `tj3`, `tj3d`, `tj3webd`, and `tj3man`
binaries. They are opt-in via the `TASKJUGGLER_BIN_DIR` environment
variable and skip themselves (`ert-skip`) when it is unset:
```
TASKJUGGLER_BIN_DIR=~/repos/TaskJuggler/bin \
  emacs --batch -l test/taskjuggler-mode-test.el -f ert-run-tests-batch-and-exit
```

The integration suite includes a single `*-scenario-*` test
(`test/taskjuggler-mode-scenario-test.el`) that walks through the full
editing-session loop on `test/tutorial.tjp`: open the buffer, start
tj3d/tj3webd, add the project, sync the cursor, look up `tj3man`,
edit + save and observe the tj3webd listing update, introduce a
syntax error and observe the daemon-mode Flymake backend pick it up,
then stop both daemons.

Open a test fixture to exercise the mode:
```
emacs test/tutorial.tjp
emacs test/gnomes.tjp
```

## Architecture

The package is split across six files. All public symbols use the
`taskjuggler-mode-` prefix (package-lint compliant); internal symbols
use `taskjuggler-mode--`.

- **`taskjuggler-mode.el`** — Entry point. `define-derived-mode` from
  `prog-mode`, plus everything that doesn't have its own subsystem
  file: defcustoms, faces, keyword lists, font-lock, syntax table,
  indentation, block operations, defun integration, evil bindings,
  compilation hookup, mode/keymap/menu definition, and yasnippet
  loader. Loads the five submodules below via `require`.
- **`taskjuggler-mode-cal.el`** — Inline calendar picker (`C-c C-t d`)
  for editing date literals. Auto-launches after date-expecting
  keywords when `taskjuggler-mode-auto-cal-on-date-keyword` is set.
- **`taskjuggler-mode-cursor.el`** — Two-way cursor tracking between
  the open `.tjp` buffer and the tj3webd report server. Uses the
  `/cursor` HTTP endpoint when reachable; falls back to writing
  `js/tj-cursor.js` for `file://` polling.
- **`taskjuggler-mode-daemon.el`** — tj3d/tj3webd daemon lifecycle plus
  the in-memory diagnostic cache populated by `tj3client add` (drained
  by the daemon-mode Flymake backend).
- **`taskjuggler-mode-flymake.el`** — Two mutually-exclusive Flymake
  backends. The standalone backend runs `tj3` on the current file when
  no daemon owns the project; the daemon-mode backend reports the
  cached diagnostics from `taskjuggler-mode-daemon.el` instead.
- **`taskjuggler-mode-tj3man.el`** — `tj3man` keyword lookup
  (`C-c C-t m`) and the populated keyword cache used for completion.

Submodules forward-declare any symbols they depend on from other
files (`defvar`, `declare-function`); they do not `require` each
other except where necessary (`flymake.el` requires `daemon.el`).

## Key design decisions

- `#` comments cannot be handled in the syntax table (it would conflict
  with `$` in macro refs), so they use `syntax-propertize-rules` instead.
  The syntax table handles `//` and `/* */`.
- `-8<-..->8-` scissors strings (TJ3 multi-line string literals) are also
  handled in `syntax-propertize-rules` using a generic string fence
  (`|`). The extend-region hook ensures fence pairs are always
  re-propertized as a unit.
- `-` (hyphen) is a word constituent so TJ3 identifiers like `my-task`
  work correctly with `\<word\>` boundaries.
- `font-lock-defaults` uses `nil` for KEYWORDS-ONLY so strings and
  comments are fontified via the syntax table (not overridden by keyword
  patterns).
- Named declaration IDs (the identifier after `task`, `resource`, etc.)
  use `font-lock-variable-name-face` and are matched by a separate regex
  that captures group 2.
- Completion uses `completion-at-point-functions` and works with
  `company-capf` automatically.
