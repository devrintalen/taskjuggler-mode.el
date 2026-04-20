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

Byte-compile to check for warnings:
```
emacs --batch -f batch-byte-compile taskjuggler-mode.el
```

Run the ERT test suite:
```
emacs --batch -l test/taskjuggler-mode-test.el -f ert-run-tests-batch-and-exit
```

Open a test fixture to exercise the mode:
```
emacs test/tutorial.tjp
emacs test/gnomes.tjp
```

## Architecture

The mode is implemented as a standard Emacs derived mode
(`define-derived-mode` from `prog-mode`). All logic is in
`taskjuggler-mode.el` in this order:

1. **Customization** — Eight defcustoms: `taskjuggler-indent-level`,
   `taskjuggler-tj3-bin-dir`, `taskjuggler-tj3-extra-args`,
   `taskjuggler-cursor-idle-delay`, `taskjuggler-cal-show-week-numbers`,
   `taskjuggler-auto-cal-on-date-keyword`,
   `taskjuggler-auto-start-tj3d-tj3webd`,
   `taskjuggler-auto-add-project-tj3d`
2. **Faces** — Three syntax faces (`taskjuggler-date-face`,
   `taskjuggler-duration-face`, `taskjuggler-macro-face`) plus eight
   calendar popup faces (`taskjuggler-cal-face`, `-header-face`,
   `-selected-face`, `-today-face`, `-inactive-face`, `-pending-face`,
   `-typing-face`, `-week-face`)
3. **Keyword lists** — Four `defconst` lists: top-level keywords, report
   keywords, property keywords, value keywords
4. **Font-lock patterns** — `taskjuggler-font-lock-keywords` built from the
   keyword lists plus regex constants for dates, durations, and macro refs
5. **Syntax table** — Handles `//` and `/* */` via standard Emacs style
   flags; `#` comments and `-8<-..->8-` scissors strings via
   `syntax-propertize-rules`
6. **Indentation** — Brace/bracket depth via `syntax-ppss`; closing
   delimiters de-indented one level; comma-terminated lines aligned as
   continuations to the first argument of the keyword line
7. **Block operations** — Movement (`M-<up>`/`M-<down>`), navigation
   (next/prev sibling, parent, first child), editing (mark, narrow,
   clone), sexp movement (`C-M-f`/`C-M-b`)
8. **Defun integration** — `beginning-of-defun-function` /
   `end-of-defun-function` wired to block navigation for standard
   `C-M-a`/`C-M-e` support
9. **Calendar picker** — Inline overlay calendar (`C-c C-t d`) for
   editing date literals at point; auto-launches after date-expecting
   keywords when `taskjuggler-auto-cal-on-date-keyword` is set
10. **Tooling integrations** — Compilation support (pre-filled
    `compile-command`), Flymake backend (on-the-fly `tj3` errors), tj3man
    keyword lookup (`C-c C-t m`), cursor tracking (writes
    `tj-cursor.json` sidecar on idle), Evil mode bindings (`[[`/`]]`),
    Yasnippet snippets from `snippets/`
11. **Mode definition** — Wires everything together via
    `taskjuggler-keymap-prefix` (`C-c C-t`), registers `.tjp`/`.tji`
    extensions

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
