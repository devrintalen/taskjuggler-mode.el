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

Open the test fixture to exercise the mode:
```
emacs test/ee.tjp
```

## Architecture

The mode is implemented as a standard Emacs derived mode
(`define-derived-mode` from `prog-mode`). All logic is in
`taskjuggler-mode.el` in this order:

1. **Customization** — `taskjuggler-indent-level` defcustom
2. **Faces** — Three custom faces inheriting from standard font-lock faces: `taskjuggler-date-face`, `taskjuggler-duration-face`, `taskjuggler-macro-face`
3. **Keyword lists** — Four `defconst` lists: top-level keywords, report keywords, property keywords, value keywords
4. **Font-lock patterns** — `taskjuggler-font-lock-keywords` built from the keyword lists plus regex constants for dates, durations, and macro refs
5. **Syntax table** — Handles `//` and `/* */` via standard Emacs style flags; `#` comments via `syntax-propertize-rules`
6. **Indentation** — Brace/bracket depth via `syntax-ppss`; closing delimiters de-indented one level
7. **Mode definition** — Wires everything together, registers `.tjp`/`.tji` extensions

## Key design decisions

- `#` comments cannot be handled in the syntax table (it would conflict with `$` in macro refs), so they use `syntax-propertize-rules` instead. The syntax table handles `//` and `/* */`.
- `-` (hyphen) is a word constituent so TJ3 identifiers like `my-task` work correctly with `\<word\>` boundaries.
- `font-lock-defaults` uses `nil` for KEYWORDS-ONLY so strings and comments are fontified via the syntax table (not overridden by keyword patterns).
- Named declaration IDs (the identifier after `task`, `resource`, etc.) use `font-lock-function-name-face` and are matched by a separate regex that captures group 2.
- Completion uses `completion-at-point-functions` and works with `company-capf` automatically.
