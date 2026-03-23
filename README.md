# taskjuggler-mode.el

An Emacs major mode for editing [TaskJuggler v3](https://taskjuggler.org)
project files (`.tjp`, `.tji`).

If you are already at the point that you are using (or considering)
TaskJuggler, then you are *deep* down the rabbit hole and I wish you
good luck. I also offer you this package to help.

🌮

This is not the first Emacs mode written to support TaskJuggler. As
far as I know, these are the projects already out there:

| **Project**                 | **Notes**                                                                                               |
|-----------------------------|---------------------------------------------------------------------------------------------------------|
| csrhodes/tj3-mode           | Provides syntax highlighting                                                                            |
| ska2342/taskjuggler-mode.el | Probably the "original" Emacs mode for TaskJuggler. Written for TJ2 and once packaged with TaskJuggler. |
| ox-taskjuggler              | org export backend, turns org-mode documents into TaskJuggler files.                                    |
| ndwarshuis/org-tj           | Library funtions for org-mode and TaskJuggler integration                                               |

Here is what this mode supports:

- Full TJ3 keyword coverage across four semantic categories (structural,
  report, property, value)
- All three TJ3 comment styles (`//`, `/* */`, `#`) handled correctly
- `syntax-ppss`-based indentation that understands `{}` and `[]` nesting,
  including continuation-line alignment for comma-terminated argument lists
- First-class Flymake integration running `tj3` on-the-fly
- `compilation-mode` error navigation pre-wired for TJ3's error format
- `completion-at-point` / `company-capf` keyword completion
- yasnippet snippet collection for common constructs
- Block movement (`M-<up>` / `M-<down>`) swaps sibling blocks while
  keeping their preceding comments attached
- Block navigation: jump to next/previous sibling, parent, and first/last
  child; linear forward/backward scan across nesting boundaries
- `beginning-of-defun` / `end-of-defun` integration (`C-M-a` / `C-M-e` /
  `C-M-h` / `narrow-to-defun`)
- Date editing with the Org calendar picker (`C-c C-d`) — inserts a new
  date or edits the date under point
- Evil-mode bindings for all navigation and movement commands

## Installation

### `straight.el` with `use-package`

This probably the easiest way, if you already use `straight.el`.

```emacs-lisp

(use-package taskjuggler-mode
  :straight (taskjuggler-mode :type git
                              :host github
                              :repo "devrintalen/taskjuggler-mode.el"
                              :files ("*.el" "snippets"))
  :mode (("\\.tj[ip]\\'" . taskjuggler-mode))
  :hook ((taskjuggler-mode . flymake-mode)
         (taskuggler-mode . electric-pair-local-mode))
  :custom
  (taskjuggler-tj3-program "~/bin/tj3"))

```

## Configuration

All options belong to the `taskjuggler` customization group (`M-x customize-group
RET taskjuggler RET`). The table below lists every option with its default value.
Copying the `use-package` block as-is produces exactly the same behavior as not
setting anything.

| Option                       | Default | Description                                               |
|------------------------------|---------|-----------------------------------------------------------|
| `taskjuggler-indent-level`   | `2`     | Spaces per indentation level                              |
| `taskjuggler-tj3-program`    | `"tj3"` | Name or full path of the `tj3` executable                 |
| `taskjuggler-tj3-extra-args` | `nil`   | Extra CLI flags forwarded to `tj3` by the Flymake backend |

`taskjuggler-tj3-extra-args` is buffer-local safe (`listp`), so you can set it
per-project with a `.dir-locals.el`:

```emacs-lisp
;; .dir-locals.el
((taskjuggler-mode
  . ((taskjuggler-tj3-extra-args . ("--prefix" "/opt/myproject/tj3")))))
```

## Features

### Syntax highlighting

Keywords are divided into four semantic categories, each mapped to a distinct
face so themes can style them independently:

| Category                | Face                                                              | Examples                                          |
|-------------------------|-------------------------------------------------------------------|---------------------------------------------------|
| Structural keywords     | `font-lock-keyword-face`                                          | `project`, `task`, `resource`, `include`, `macro` |
| Report keywords         | `font-lock-builtin-face`                                          | `taskreport`, `resourcereport`, `textreport`      |
| Property keywords       | `font-lock-type-face`                                             | `effort`, `depends`, `allocate`, `start`, `end`   |
| Value/constant keywords | `font-lock-constant-face`                                         | `asap`, `alap`, `yes`, `no`, `done`               |
| Declaration identifiers | `font-lock-function-name-face`                                    | The `my-task` in `task my-task "…"`               |
| Date literals           | `taskjuggler-date-face` (inherits `font-lock-string-face`)        | `2024-03-15`, `2024-03-15-09:00`                  |
| Duration literals       | `taskjuggler-duration-face` (inherits `font-lock-constant-face`)  | `5d`, `2.5h`, `3w`, `30min`                       |
| Macro/env references    | `taskjuggler-macro-face` (inherits `font-lock-preprocessor-face`) | `${MacroName}`, `$(ENV_VAR)`                      |
| Strings                 | `font-lock-string-face`                                           | `"Project Name"`                                  |
| Comments                | `font-lock-comment-face`                                          | `// …`, `/* … */`, `# …`                          |

The three faces (`taskjuggler-date-face`, `taskjuggler-duration-face`,
`taskjuggler-macro-face`) can be customized independently if you want dates or
durations to stand out more than strings or constants in your theme.

### Comment support

All three TJ3 comment syntaxes are recognized for navigation and toggling:

- `//` — line comment
- `/* … */` — block comment
- `#` — line comment (handled via `syntax-propertize-rules` to avoid conflicting
  with `$` in macro references)

`M-;` (`comment-dwim`) and `comment-region` default to `#` style. All three
styles are recognized by `forward-comment`, `comment-search-forward`, and
similar navigation commands.

### Indentation

Indentation is brace/bracket depth–based, computed with `syntax-ppss` so it is
aware of strings and comments:

- Each `{` or `[` increases the indent by `taskjuggler-indent-level` spaces.
- A line that starts with `}` or `]` is de-indented one level relative to the
  surrounding block.
- `TAB` indents the current line (`taskjuggler-indent-line`).
- `C-M-\` indents the active region (`taskjuggler-indent-region`).
- Tabs are never inserted; `indent-tabs-mode` is `nil`.
- Continuation lines (when the previous non-blank line ends with a comma) are
  aligned with the first argument on the keyword line rather than indented by
  one level.

### Block movement

`M-<up>` (`taskjuggler-move-block-up`) and `M-<down>`
(`taskjuggler-move-block-down`) swap the block at point with its previous or
next *sibling* — another block at the same brace-nesting depth.

- Any comment lines (`#` or `//`) immediately preceding a block header (with
  no intervening blank lines) travel with the block.
- The blank-line separator between the two blocks is preserved.
- Works from anywhere inside a block, not just on the header line.

### Block navigation

Several commands let you move through the block structure without the mouse:

| Key        | Command                             | Description                                           |
|------------|-------------------------------------|-------------------------------------------------------|
| `C-M-n`    | `taskjuggler-forward-block`         | Linear scan to the next block header (any depth)      |
| `C-M-p`    | `taskjuggler-backward-block`        | Linear scan to the previous block header (any depth)  |
| `C-M-a`    | `beginning-of-defun`                | Jump to the header of the current/enclosing block     |
| `C-M-e`    | `end-of-defun`                      | Jump past the closing `}` of the current block        |
| `C-M-h`    | `mark-defun`                        | Mark the current block as a region                    |
| —          | `taskjuggler-next-block`            | Jump to the next *sibling* at the same depth          |
| —          | `taskjuggler-prev-block`            | Jump to the previous *sibling* at the same depth      |
| —          | `taskjuggler-goto-parent`           | Jump to the enclosing block's header                  |
| —          | `taskjuggler-goto-first-child`      | Jump to the first direct child block                  |
| —          | `taskjuggler-goto-last-child`       | Jump to the last direct child block                   |

`narrow-to-defun` also works as expected, narrowing to the current block.

#### Evil-mode bindings

When `evil-mode` is active, additional normal-state bindings are registered:

| Key   | Command                        |
|-------|--------------------------------|
| `gj`  | `taskjuggler-next-block`       |
| `gk`  | `taskjuggler-prev-block`       |
| `gh`  | `taskjuggler-goto-parent`      |
| `gl`  | `taskjuggler-goto-first-child` |
| `gL`  | `taskjuggler-goto-last-child`  |
| `]B`  | `taskjuggler-forward-block`    |
| `[B`  | `taskjuggler-backward-block`   |
| `[[`  | `beginning-of-defun`           |
| `]]`  | `end-of-defun`                 |

These bindings are registered with `with-eval-after-load 'evil` so the mode
loads cleanly without evil present.

### Date editing

`C-c C-d` (`taskjuggler-date-dwim`) is a unified entry point for working with
TJ3 date literals:

- **Point is on a date**: opens the Org calendar with the existing date
  pre-selected so you can change it in place.
- **Point is not on a date**: inserts a new date literal at point.

Without a prefix argument both commands produce a bare `YYYY-MM-DD`. With
`C-u`, the Org time picker is also shown and the result is
`YYYY-MM-DD-HH:MM`.

`org` must be available (it ships with Emacs).

### Keyword completion

`completion-at-point` (`M-TAB` / `C-M-i`) completes all TJ3 keywords. Because
the backend uses `completion-at-point-functions`, it works automatically with
`company-capf` if you use [Company](https://company-mode.github.io):

```emacs-lisp
(use-package company
  :hook (taskjuggler-mode . company-mode))
```

No extra configuration is needed; `company-capf` is in `company-backends` by
default.

### Compilation support

When you open a `.tjp` file, `compile-command` is pre-filled with
`tj3 <filename>`, so `M-x compile` (or `C-c C-c` if bound) immediately runs
the scheduler on the current file.

TJ3's error format (`filename.tjp:LINE: Error: message`) is registered with
`compilation-error-regexp-alist`, so `next-error` / `previous-error` (`M-g n` /
`M-g p`) jump directly to the offending line. ANSI color codes in TJ3 output
are stripped before parsing so errors are found whether or not
`ansi-color-compilation-filter` is active.

### Flymake integration

The Flymake backend runs `tj3` on the **saved file** whenever Flymake checks the
buffer and reports errors as inline diagnostics. Enable it the standard way:

```emacs-lisp
(add-hook 'taskjuggler-mode-hook #'flymake-mode)
```

Or with `use-package`:

```emacs-lisp
(use-package taskjuggler-mode
  :ensure t
  :hook (taskjuggler-mode . flymake-mode))
```

`tj3` must be on your `PATH`. If your installation is non-standard, point the
mode at it via `taskjuggler-tj3-extra-args` (see Configuration above) or by
adjusting `exec-path`.

Errors in included `.tji` files are reported in those files' own buffers rather
than in the parent `.tjp` buffer, matching TJ3's output behavior.

### yasnippet snippets

| Key      | Expands to                                                                              |
|----------|-----------------------------------------------------------------------------------------|
| `proj`   | `project` block with timezone, timeformat, currency, now, and a scenario                |
| `task`   | `task` block with effort, depends, and allocate                                         |
| `mil`    | Milestone task skeleton                                                                 |
| `res`    | Single `resource` block                                                                 |
| `resgrp` | `resource` group containing two members                                                 |
| `dep`    | `depends` line                                                                          |
| `inc`    | `include` statement                                                                     |
| `mac`    | `macro` definition                                                                      |
| `hdr`    | TJ3 heredoc delimiters (`-8<-` … `->8-`)                                                |
| `je`     | `journalentry` block with author, alert, summary, and details; date pre-filled to today |
| `trep`   | `taskreport` with standard columns                                                      |
| `rrep`   | `resourcereport` with standard columns                                                  |

## Requirements

- Emacs 27.1 or later
- `tj3` on `PATH` (only for Flymake and compilation features)
- `org` (ships with Emacs; required for date editing via `C-c C-d`)
- [yasnippet](https://github.com/joaotavora/yasnippet) (optional; snippets are registered automatically if yasnippet is present)
- [Company](https://company-mode.github.io) (optional, for pop-up completion)
