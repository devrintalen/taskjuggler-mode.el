;;; taskjuggler-mode.el --- Major mode for TaskJuggler project files -*- lexical-binding: t -*-

;; Copyright (C) 2025 Devrin Talen <devrin@fastmail.com>

;; Author: Devrin Talen <devrin@fastmail.com>
;; Keywords: languages, project-management
;; Package-Version: 0.6.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/devrintalen/taskjuggler-mode.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Major mode for editing TaskJuggler 3 project files (.tjp, .tji).
;; See https://taskjuggler.org for more information.
;;
;; Features:
;;   - Syntax highlighting for all TJ3 keywords
;;   - Comment support for //, /* */, and # styles
;;   - String highlighting (double-quoted strings)
;;   - Date literal highlighting: YYYY-MM-DD[-hh:mm[:ss]]
;;   - Duration literal highlighting: 5d, 2.5h, 3w, etc.
;;   - Macro reference highlighting: ${MacroName}, $(ENV_VAR)
;;   - Indentation based on { } and [ ] block nesting depth (line and region)
;;   - Compilation support: compile-command pre-filled with tj3, navigable errors
;;   - Flymake integration: on-the-fly error checking via tj3
;;   - tj3man integration: C-c C-t m looks up keyword docs with completion
;;   - Defun navigation: C-M-a/C-M-e jump to block start/end
;;   - Block editing: C-M-h marks block (incl.  comments), C-c C-t n narrows to
;;     block, clone-block duplicates the current block
;;   - Block navigation: C-M-n/C-M-p move to next/prev sibling, C-M-u goes to
;;     parent block, C-M-d goes to first child
;;   - Block movement: M-<up>/M-<down> moves the current block up or down
;;   - Sexp movement: C-M-f/C-M-b treats a keyword block as a single sexp
;;   - Inline calendar picker: C-c C-t d opens an overlay calendar for editing
;;     date literals at point
;;   - Yasnippet integration: snippets from the bundled snippets/ directory
;;   - Evil mode integration: [[ and ]] bound to beginning/end-of-defun

;;; Code:

(require 'ansi-color)
(require 'calendar)
(require 'comint)
(require 'man)
(require 'url)
(require 'json)

(declare-function org-read-date "org" (&optional with-time to-time from-string prompt default-time default-input inactive))
(declare-function yas--load-snippet-dirs "yasnippet" ())

(defgroup taskjuggler-mode nil
  "Major mode for editing TaskJuggler project files."
  :group 'languages
  :prefix "taskjuggler-mode-")

(defcustom taskjuggler-mode-indent-level 2
  "Number of spaces per indentation level in TaskJuggler files."
  :type 'integer
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-tj3-bin-dir nil
  "Directory containing the tj3 executables (tj3, tj3man), or nil to use PATH.
When non-nil, both `tj3' and `tj3man' are resolved relative to this directory.
Example: (setq taskjuggler-mode-tj3-bin-dir \"/opt/tj3/bin\")"
  :type '(choice (const :tag "Use PATH" nil)
                 (directory :tag "Directory"))
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-tj3-extra-args nil
  "List of additional command-line arguments passed to tj3 by the Flymake backend.
Use this to supply flags your project requires, such as:
  (setq-local taskjuggler-mode-tj3-extra-args \\='(\"--prefix\" \"/opt/tj3\"))
The arguments are inserted between the `tj3' executable and the file name."
  :type '(repeat string)
  :safe #'listp
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-cursor-idle-delay 0.3
  "Seconds of Emacs idle time before syncing the cursor position.
Set to nil to disable cursor tracking entirely."
  :type '(choice (number :tag "Idle delay in seconds")
                 (const :tag "Disabled" nil))
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-cal-show-week-numbers nil
  "When non-nil, display ISO week-number labels (e.g. WW15) in the calendar popup."
  :type 'boolean
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-auto-cal-on-date-keyword nil
  "When non-nil, open the calendar popup after typing a date keyword.
Keywords that expect a date value (such as `start' and `end') trigger
the inline calendar picker when the user types a space or tab after them.
See `taskjuggler-mode--date-keyword-list' for the full list of triggering keywords."
  :type 'boolean
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-auto-start-tj3d-tj3webd nil
  "When non-nil, start tj3d and tj3webd when `taskjuggler-mode' activates.
Daemons are only started if they are not already running."
  :type 'boolean
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-auto-add-project-tj3d nil
  "When non-nil, add the current project to tj3d when visiting a TJ3 file.
Uses `taskjuggler-mode--find-tjp-file' to locate the .tjp file and adds it
via `taskjuggler-mode-tj3d-add-project' if it is not already loaded."
  :type 'boolean
  :group 'taskjuggler-mode)

(defcustom taskjuggler-mode-tj3webd-port 8080
  "Port for the tj3webd web server.
Passed via --port to tj3webd and used to construct the browse URL."
  :type 'integer
  :group 'taskjuggler-mode)

;;; Helpers

(defun taskjuggler-mode--tj3-executable (name)
  "Return the path to the tj3 executable NAME.
When `taskjuggler-mode-tj3-bin-dir' is non-nil, NAME is resolved relative to
that directory.  Otherwise NAME is returned as-is for PATH lookup."
  (if taskjuggler-mode-tj3-bin-dir
      (expand-file-name name taskjuggler-mode-tj3-bin-dir)
    name))

;;; Faces

(defface taskjuggler-mode-date-face
  '((t :inherit font-lock-constant-face))
  "Face for TaskJuggler date literals (e.g. 2023-01-15)."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-duration-face
  '((t :inherit font-lock-constant-face))
  "Face for TaskJuggler duration literals (e.g. 5d, 2.5h)."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-macro-face
  '((t :inherit font-lock-preprocessor-face))
  "Face for TaskJuggler macro and environment variable references."
  :group 'taskjuggler-mode)

;; Calendar popup faces

;; Based on the rendering code, here's the mapping:

;; ```
;;   Buffer (in-place date text)
;;   ───────────────────────────
;;   start 2026-04-15
;;         ╔════╗╔══════╗
;;         ║2026║║-04-15║
;;         ╚════╝╚══════╝
;;            │      └── taskjuggler-mode-cal-pending-face
;;            └───────── taskjuggler-mode-cal-typing-face
;;           (typed-len=4 here)

;;   Overlay (popup below current line)
;;   ────────────────────────────────────────────
;;   ╔══════════════════════╗
;;   ║     April 2026       ║  taskjuggler-mode-cal-header-face
;;   ║  Su Mo Tu We Th Fr Sa║  taskjuggler-mode-cal-header-face
;;   ║ 29 30 31  1 [2] 3  4 ║  ┐
;;   ║  5  6  7  8  9 10 11 ║  │  space separators between
;;   ║ 12 13 14[15]16 17 18 ║  │  cells: taskjuggler-mode-cal-face
;;   ║ 19 20 21 22 23 24 25 ║  │
;;   ║ 26 27 28 29 30  1  2 ║  ┘
;;   ╚══════════════════════╝

;;   Cell faces (2-char cells only; spaces use taskjuggler-mode-cal-face):
;;     29 30 31          → taskjuggler-mode-cal-inactive-face  (prev month)
;;      1  3  4 ...      → taskjuggler-mode-cal-face           (regular days)
;;     [2]               → taskjuggler-mode-cal-today-face     (today, not selected)
;;    [15]               → taskjuggler-mode-cal-selected-face  (selected day)
;;      1  2  (last row) → taskjuggler-mode-cal-inactive-face  (next month)
;; ```

;; The box borders are not rendered — they're just here for clarity. The face backgrounds provide the visual container.

(defface taskjuggler-mode-cal-face
  '((t :inherit tooltip))
  "Base face for the calendar popup background and day cells."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-header-face
  '((t :inherit header-line :weight bold))
  "Face for the calendar month title and day-of-week header."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-selected-face
  '((t :inherit highlight))
  "Face for the currently selected day in the calendar."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-today-face
  '((t :inherit warning :weight bold))
  "Face for today's date when visible but not selected."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-inactive-face
  '((t :inherit (shadow tooltip)))
  "Face for days from the previous or next month."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-pending-face
  '((t :inherit secondary-selection))
  "Face for the pre-filled date in the buffer during calendar editing.
This face indicates the date that will be committed on RET."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-typing-face
  '((t :inherit isearch :weight bold))
  "Face for the user-typed portion of the date during calendar editing.
Distinguishes characters the user has typed from the pre-filled suffix."
  :group 'taskjuggler-mode)

(defface taskjuggler-mode-cal-week-face
  '((t :inherit taskjuggler-mode-cal-header-face))
  "Face for ISO week-number labels (e.g. WW15) in the calendar popup."
  :group 'taskjuggler-mode)

;;; Keyword lists

(defconst taskjuggler-mode-top-level-keywords
  '("project" "task" "resource" "account" "scenario"
    "extend" "macro" "include" "flags" "shift")
  "TaskJuggler top-level declaration keywords.")

(defconst taskjuggler-mode-report-keywords
  '("taskreport" "resourcereport" "accountreport" "textreport"
    "tracereport" "icalreport" "timesheetreport" "statussheetreport")
  "TaskJuggler report type keywords.")

(defconst taskjuggler-mode-property-keywords
  '(;; Task properties
    "allocate" "booking" "charge" "chargeset" "complete"
    "depends" "duration" "effort" "end" "journalentry"
    "leave" "leaveallowance" "length" "limits"
    "maxend" "maxstart" "milestone"
    "minend" "minstart" "note" "period" "precedes"
    "priority" "projectid" "purge" "responsible"
    "scheduled" "scheduling" "shifts" "start" "summary"
    "supplement" "vacation" "workinghours"
    ;; Resource properties
    "dailymax" "efficiency" "email" "managers"
    "monthlymax" "overtime" "rate" "timezone" "weeklymax"
    ;; Report properties
    "balance" "caption" "center" "columns" "costaccount"
    "currencyformat" "footer" "formats"
    "headline" "header" "hideresource" "hidetask"
    "left" "loadunit" "numberformat" "opennodes"
    "resourceroot" "revenueaccount" "right"
    "rollupresource" "rolluptask" "scenarios"
    "showprojectids" "sortresources" "sorttasks"
    "taskroot" "timeformat" "title" "weekstartmonday"
    ;; Project-level properties
    "currency" "dailyworkinghours" "now" "timingresolution"
    "yearlyworkingdays")
  "TaskJuggler property keywords.")

(defconst taskjuggler-mode-value-keywords
  '("yes" "no" "true" "false" "off" "on"
    "asap" "alap"
    "annual" "special" "sick" "unpaid" "holiday"
    "onstart" "onend"
    "perhour" "perday" "perweek" "permonth"
    "raise" "lower" "keep"
    "days" "hours" "weeks" "months" "years" "minutes"
    "longauto" "shortauto" "quarters"
    "done" "todo" "inprogress"
    "green" "yellow" "red" "none"
    "max" "min" "sum")
  "TaskJuggler value and constant keywords.")

;;; Font-lock patterns

(defconst taskjuggler-mode--date-re
  (concat "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
          "\\(?:-[0-9]\\{2\\}:[0-9]\\{2\\}"
          "\\(?::[0-9]\\{2\\}\\)?"
          "\\(?:[+-][0-9]\\{4\\}\\)?\\)?")
  "Regexp matching TaskJuggler date literals (YYYY-MM-DD[-hh:mm[:ss]]).")

(defconst taskjuggler-mode--duration-re
  "\\<[0-9]+\\(?:\\.[0-9]+\\)?\\(?:min\\|[hdwmy]\\)\\>"
  "Regexp matching TaskJuggler duration literals (e.g. 5d, 2.5h, 3w).")

(defconst taskjuggler-mode--macro-ref-re
  "\\${[^}\n]+}\\|\\$([A-Z_][A-Z0-9_]*)"
  "Regexp matching TaskJuggler macro (${...}) and env-var ($(VAR)) references.")

(defconst taskjuggler-mode--named-declaration-re
  (concat (regexp-opt '("task" "resource" "account" "scenario"
                        "shift" "macro" "supplement")
                      'words)
          "[ \t]+\\([[:alnum:]_][[:alnum:]_-]*\\)")
  "Regexp matching a declaration keyword followed by its identifier.")

(defvar taskjuggler-mode-font-lock-keywords
  `(;; Named declarations: highlight the identifier after the keyword.
    ;; regexp-opt with 'words wraps in a capturing group, making the keyword
    ;; group 1 and the identifier group 2.
    (,taskjuggler-mode--named-declaration-re
     (2 font-lock-variable-name-face))
    ;; Top-level structural keywords
    (,(regexp-opt taskjuggler-mode-top-level-keywords 'words)
     . font-lock-keyword-face)
    ;; Report type keywords
    (,(regexp-opt taskjuggler-mode-report-keywords 'words)
     . font-lock-function-name-face)
    ;; Property keywords
    (,(regexp-opt taskjuggler-mode-property-keywords 'words)
     . font-lock-function-name-face)
    ;; Value and constant keywords
    (,(regexp-opt taskjuggler-mode-value-keywords 'words)
     . font-lock-variable-name-face)
    ;; Date literals
    (,taskjuggler-mode--date-re . 'taskjuggler-mode-date-face)
    ;; Duration literals
    (,taskjuggler-mode--duration-re . 'taskjuggler-mode-duration-face)
    ;; Macro and environment variable references
    (,taskjuggler-mode--macro-ref-re . 'taskjuggler-mode-macro-face))
  "Font-lock keywords for `taskjuggler-mode'.")

;;; Syntax table

(defvar taskjuggler-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Comments: // line comments (style b) and /* */ block comments (style a)
    ;; This is the standard setup used for C-style comment handling in Emacs.
    (modify-syntax-entry ?/ ". 124b" table)
    (modify-syntax-entry ?* ". 23" table)
    (modify-syntax-entry ?\n "> b" table)
    ;; Double-quoted strings
    (modify-syntax-entry ?\" "\"" table)
    ;; Block delimiters
    (modify-syntax-entry ?{ "(}" table)
    (modify-syntax-entry ?} "){" table)
    ;; Square brackets (macro body delimiters)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    ;; Word constituents: underscore and hyphen are valid in identifiers
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?- "w" table)
    ;; Punctuation characters
    (modify-syntax-entry ?$ "." table)
    (modify-syntax-entry ?! "." table)
    (modify-syntax-entry ?. "." table)
    table)
  "Syntax table for `taskjuggler-mode'.")

;;; Syntax propertize (for # line comments and scissor strings)

(defconst taskjuggler-mode--syntax-comment-start (string-to-syntax "< b"))
(defconst taskjuggler-mode--syntax-string-fence  (string-to-syntax "|"))

(defun taskjuggler-mode--syntax-propertize-extend-region (start end)
  "Extend propertize region backward to cover any enclosing scissors string.
If START falls inside an open -8<- … ->8- scissors string whose opener
precedes START, extend START back to include the opener so the propertize
function can re-establish both delimiters atomically.  END is returned
unchanged when an extension is needed.

This function is added to `syntax-propertize-extend-region-functions',
which Emacs calls BEFORE `remove-text-properties' clears the region —
so `syntax-ppss' is safe to call here and returns the correct state."
  (let ((state (syntax-ppss start)))
    (when (eq t (nth 3 state))
      ;; (nth 8 state) is the fence character (last - of -8<-); back up 3
      ;; to reach the first character of the 4-char -8<- pattern.
      (let ((new-start (max (point-min) (- (nth 8 state) 3))))
        (when (< new-start start)
          (cons new-start end))))))

(defun taskjuggler-mode--syntax-propertize (start end)
  "Propertize region START..END for `taskjuggler-mode'.
Handles # as a line comment and -8<- … ->8- as string delimiters.

Calls `syntax-ppss' at each match to skip occurrences inside existing
comments or strings.  This is safe inside `syntax-propertize-function'
because Emacs binds `syntax-propertize--done' to `most-positive-fixnum'
for the call duration, preventing recursive re-entry.  Scanning
left-to-right means a `#' `comment-start' property is applied before any
-8<- on the same line is reached, so `syntax-ppss' correctly sees the
latter as inside a comment."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "\\(#\\)\\|-8<\\(-\\)" end t)
      (let ((ppss (save-excursion
                    (goto-char (match-beginning 0))
                    (syntax-ppss))))
        (unless (or (nth 3 ppss) (nth 4 ppss))
          (cond
           ((match-beginning 1)
            (put-text-property (match-beginning 1) (match-end 1)
                               'syntax-table taskjuggler-mode--syntax-comment-start))
           ((match-beginning 2)
            (put-text-property (match-beginning 2) (match-end 2)
                               'syntax-table taskjuggler-mode--syntax-string-fence)
            (save-excursion
              (goto-char (match-end 0))
              (when (re-search-forward "->8\\(-\\)" nil t)
                (put-text-property (match-beginning 1) (match-end 1)
                                   'syntax-table taskjuggler-mode--syntax-string-fence))))))))))


;;; Indentation

(defun taskjuggler-mode--continuation-indent ()
  "Return the column for a keyword-argument continuation line, or nil.
When the previous non-blank line ends with a comma, this line is treated
as a continuation of a multi-line argument list.  Walk back to the first
line of the comma-terminated sequence and return the column of its first
argument (the token immediately after the leading keyword word).
Returns nil when the current line is not a continuation."
  (save-excursion
    (beginning-of-line)
    (forward-line -1)
    (while (and (not (bobp)) (looking-at "[ \t]*$"))
      (forward-line -1))
    (when (looking-at ".*,[ \t]*$")
      ;; Walk back while the preceding non-blank line also ends with a comma,
      ;; so we land on the first line of the sequence (the keyword line).
      (let ((continue t))
        (while continue
          (let ((prev-also-comma
                 (save-excursion
                   (forward-line -1)
                   (while (and (not (bobp)) (looking-at "[ \t]*$"))
                     (forward-line -1))
                   (and (not (bobp)) (looking-at ".*,[ \t]*$")))))
            (if prev-also-comma
                (progn
                  (forward-line -1)
                  (while (and (not (bobp)) (looking-at "[ \t]*$"))
                    (forward-line -1)))
              (setq continue nil)))))
      ;; Now on the anchor (keyword) line.  Find the column of the first argument:
      ;; skip leading whitespace, skip the keyword word, skip whitespace after it.
      (beginning-of-line)
      (skip-chars-forward " \t")
      (skip-syntax-forward "w_")
      (skip-chars-forward " \t")
      (unless (eolp)
        (current-column)))))

(defun taskjuggler-mode--calculate-indent ()
  "Return the target indentation column for the current line.
Indentation is based on the brace/bracket nesting depth at the start
of the line, as computed by `syntax-ppss'.  A line opening with `}'
or `]' is de-indented one level relative to the enclosing block.
If the previous non-blank line ends with a comma, the line is treated
as a continuation and aligned with the first argument on the keyword line."
  (save-excursion
    (beginning-of-line)
    (or (taskjuggler-mode--continuation-indent)
        (let* ((depth (car (syntax-ppss)))
               (indent (* depth taskjuggler-mode-indent-level)))
          ;; A closing delimiter starts a new (outer) scope.
          (when (looking-at "[ \t]*[]}]")
            (setq indent (max 0 (- indent taskjuggler-mode-indent-level))))
          indent))))

(defun taskjuggler-mode-indent-line ()
  "Indent the current line of TaskJuggler code."
  (interactive)
  (let ((pos (- (point-max) (point))))
    (indent-line-to (taskjuggler-mode--calculate-indent))
    ;; Restore point position if it was beyond the indentation.
    (when (> (- (point-max) pos) (point))
      (goto-char (- (point-max) pos)))))

(defun taskjuggler-mode-indent-region (beg end)
  "Indent each line in the region from BEG to END."
  (interactive "r")
  (let ((end-marker (copy-marker end)))
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (while (< (point) end-marker)
        (unless (looking-at "[ \t]*$")
          (taskjuggler-mode-indent-line))
        (forward-line 1)))
    (set-marker end-marker nil)))

;;; Block movement

;; Blocks that can be moved are those introduced by top-level or report
;; keywords (task, resource, macro, taskreport, etc.).  The movement
;; functions swap a block with its previous or next *sibling* — another
;; block at the same brace-nesting depth — preserving any blank-line
;; separator between them.  Comment lines (# or //) immediately preceding
;; a block header (with no intervening blank lines) are treated as belonging
;; to that block and travel with it.

(defconst taskjuggler-mode--moveable-block-re
  (concat "[ \t]*"
          (regexp-opt (append taskjuggler-mode-top-level-keywords
                              taskjuggler-mode-report-keywords)
                      'words))
  "Regexp matching a line that starts a moveable TaskJuggler block.")

(defun taskjuggler-mode--current-block-header ()
  "Return position of the block header line at or enclosing point.
If point is on a moveable keyword line, return that line's position.
If point is inside a brace block whose opening line is a moveable keyword,
return that opening line's position.  Return nil otherwise.

Uses `syntax-ppss' (which guarantees `syntax-propertize' has run) rather
than `up-list'/`scan-lists' so that # comment lines containing { are
never mistaken for block openers in un-propertized buffer regions."
  (save-excursion
    (beginning-of-line)
    (if (looking-at taskjuggler-mode--moveable-block-re)
        (point)
      (let ((parent-open (nth 1 (syntax-ppss))))
        (when parent-open
          (goto-char parent-open)
          (beginning-of-line)
          (when (looking-at taskjuggler-mode--moveable-block-re)
            (point)))))))

(defun taskjuggler-mode--block-end (header-pos)
  "Return the position of the line start immediately after the block at HEADER-POS.
If the header line contains a `{', skips to the matching `}' and returns
the line after that.  Otherwise returns the line after the header itself
\(bare keyword with no brace body)."
  (save-excursion
    (goto-char header-pos)
    (let ((eol (line-end-position))
          brace-pos)
      ;; Find the first real { on the header line (not inside string/comment).
      (while (and (not brace-pos)
                  (re-search-forward "{" eol t))
        (let ((pp (save-excursion (syntax-ppss (match-beginning 0)))))
          (when (and (not (nth 3 pp)) (not (nth 4 pp)))
            (setq brace-pos (match-beginning 0)))))
      (if brace-pos
          (progn
            (goto-char brace-pos)
            (let ((forward-sexp-function nil)) (forward-sexp 1)) ; jump to matching }
            (forward-line 1)
            (point))
        (goto-char header-pos)
        (forward-line 1)
        (point)))))

(defun taskjuggler-mode--block-with-comments-start (header-pos)
  "Return the start of the block at HEADER-POS, including preceding comments.
Immediately preceding comment lines (# //, or /* */ blocks) with no blank
lines between them and the header are considered part of the block."
  (save-excursion
    (goto-char header-pos)
    (beginning-of-line)
    (let ((start (point)))
      (while (and (not (bobp))
                  (save-excursion
                    (forward-line -1)
                    (or (looking-at "[ \t]*\\(#\\|//\\|/\\*\\)")
                        (nth 4 (syntax-ppss)))))
        (forward-line -1)
        ;; For lines inside a /* */ comment, walk back to the opening /* line.
        (while (and (not (bobp)) (nth 4 (syntax-ppss)))
          (forward-line -1))
        (setq start (point)))
      start)))

(defun taskjuggler-mode--prev-sibling-bounds (header-pos)
  "Return (start header end) for the previous sibling of the block at HEADER-POS.
A sibling is a moveable block at the same `syntax-ppss' depth.  Returns nil
if there is no previous sibling."
  (save-excursion
    (let* ((depth     (car (syntax-ppss header-pos)))
           (our-start (taskjuggler-mode--block-with-comments-start header-pos)))
      (goto-char our-start)
      ;; Skip backward over blank lines and comment lines.
      (while (and (not (bobp))
                  (progn
                    (forward-line -1)
                    (or (looking-at "[ \t]*$")
                        (looking-at "[ \t]*\\(#\\|//\\|/\\*\\)")
                        (nth 4 (syntax-ppss))))))
      (when (not (or (looking-at "[ \t]*$")
                     (looking-at "[ \t]*\\(#\\|//\\|/\\*\\)")
                     (nth 4 (syntax-ppss))))
        ;; Now on the last content line of the candidate previous block.
        (let ((prev-header
               (cond
                ;; The previous block is a single-line keyword (or its header).
                ((looking-at taskjuggler-mode--moveable-block-re)
                 (point))
                ;; The last line ends with } — walk back to the opening {.
                ((looking-at ".*}[ \t]*$")
                 (save-excursion
                   (end-of-line)
                   (skip-chars-backward " \t")
                   (condition-case nil
                       (progn
                         (let ((forward-sexp-function nil)) (forward-sexp -1)) ; } → matching {
                         (beginning-of-line)
                         (when (looking-at taskjuggler-mode--moveable-block-re)
                           (point)))
                     (error nil))))
                (t nil))))
          (when (and prev-header
                     ;; Guard: don't return the current block as its own sibling.
                     ;; This happens when our-start is at bob and the while loop
                     ;; never moves backward, leaving us on header-pos itself.
                     (/= prev-header header-pos)
                     (= (car (syntax-ppss prev-header)) depth))
            (list (taskjuggler-mode--block-with-comments-start prev-header)
                  prev-header
                  (taskjuggler-mode--block-end prev-header))))))))

(defun taskjuggler-mode--next-sibling-bounds (header-pos)
  "Return (start header end) for the next sibling of the block at HEADER-POS.
A sibling is a moveable block at the same `syntax-ppss' depth.  Returns nil
if there is no next sibling."
  (save-excursion
    (let ((depth   (car (syntax-ppss header-pos)))
          (our-end (taskjuggler-mode--block-end header-pos)))
      (goto-char our-end)
      ;; Skip blank lines and comment lines (including /* */ blocks) to reach
      ;; the next keyword.
      (while (and (not (eobp))
                  (or (looking-at "[ \t]*$")
                      (looking-at "[ \t]*\\(#\\|//\\|/\\*\\)")
                      (nth 4 (syntax-ppss))))
        (if (looking-at "[ \t]*/\\*")
            (progn (re-search-forward "\\*/" nil 'move)
                   (unless (eobp) (forward-line 1)))
          (forward-line 1)))
      (when (and (not (eobp))
                 (looking-at taskjuggler-mode--moveable-block-re)
                 (= (car (syntax-ppss)) depth))
        (let* ((next-header (point))
               (next-start  (taskjuggler-mode--block-with-comments-start next-header))
               (next-end    (taskjuggler-mode--block-end next-header)))
          (list next-start next-header next-end))))))

(defun taskjuggler-mode--move-block (direction)
  "Move the block at point one sibling in DIRECTION (`up' or `down').
The blank-line separator between blocks is preserved and the block header's
comment lines travel with whichever block they precede."
  (let ((header (taskjuggler-mode--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let* ((cur-start (taskjuggler-mode--block-with-comments-start header))
           (cur-end   (taskjuggler-mode--block-end header))
           (sibling   (if (eq direction 'up)
                          (taskjuggler-mode--prev-sibling-bounds header)
                        (taskjuggler-mode--next-sibling-bounds header))))
      (unless sibling
        (user-error "No %s sibling block to move past" direction))
      (let* ((sib-start     (nth 0 sibling))
             (sib-end       (nth 2 sibling))
             (header-offset (- header cur-start)))
        (if (eq direction 'up)
            (let* ((sib-text (buffer-substring sib-start sib-end))
                   (sep-text (buffer-substring sib-end cur-start))
                   (cur-text (buffer-substring cur-start cur-end)))
              (goto-char sib-start)
              (delete-region sib-start cur-end)
              (insert cur-text sep-text sib-text)
              (goto-char (+ sib-start header-offset)))
          (let* ((cur-text (buffer-substring cur-start cur-end))
                 (sep-text (buffer-substring cur-end sib-start))
                 (sib-text (buffer-substring sib-start sib-end)))
            (goto-char cur-start)
            (delete-region cur-start sib-end)
            (insert sib-text sep-text cur-text)
            (goto-char (+ cur-start (length sib-text) (length sep-text) header-offset))))))))

(defun taskjuggler-mode-move-block-up ()
  "Move the block at point before its previous sibling block.
The block is identified by the moveable keyword line at or enclosing point.
Any comment lines immediately preceding the block travel with it.
The blank-line separator between the two blocks is preserved."
  (interactive)
  (taskjuggler-mode--move-block 'up))

(defun taskjuggler-mode-move-block-down ()
  "Move the block at point after its next sibling block.
The block is identified by the moveable keyword line at or enclosing point.
Any comment lines immediately preceding the next block travel with it.
The blank-line separator between the two blocks is preserved."
  (interactive)
  (taskjuggler-mode--move-block 'down))

;;; Block navigation

(defun taskjuggler-mode--navigate-sibling (direction)
  "Move point to the sibling block in DIRECTION (`next' or `prev').
Signals an error if there is no enclosing moveable block or no sibling."
  (let ((header (taskjuggler-mode--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let ((bounds (if (eq direction 'next)
                      (taskjuggler-mode--next-sibling-bounds header)
                    (taskjuggler-mode--prev-sibling-bounds header))))
      (if bounds
          (goto-char (nth 1 bounds))
        (user-error "No %s sibling block" direction)))))

(defun taskjuggler-mode-next-block ()
  "Move point to the next sibling block at the same depth.
Finds the block at or enclosing point and jumps to the header of the
next sibling.  Signals an error if there is no next sibling."
  (interactive)
  (taskjuggler-mode--navigate-sibling 'next))

(defun taskjuggler-mode-prev-block ()
  "Move point to the previous sibling block at the same depth.
Finds the block at or enclosing point and jumps to the header of the
previous sibling.  Signals an error if there is no previous sibling."
  (interactive)
  (taskjuggler-mode--navigate-sibling 'prev))

(defun taskjuggler-mode-goto-parent ()
  "Move point to the keyword line of the enclosing block.
Uses `up-list' to find the opening brace one level up, then moves to
the beginning of that line.  Signals an error at the top level."
  (interactive)
  (if (= (car (syntax-ppss)) 0)
      (user-error "Already at top level")
    (condition-case nil
        (progn
          (up-list -1)
          (beginning-of-line))
      (error (user-error "No enclosing block found")))))

(defun taskjuggler-mode--child-block-headers (header-pos)
  "Return a list of positions of direct child block headers inside HEADER-POS.
Children are moveable-keyword lines at exactly one brace-nesting level deeper
than HEADER-POS.  Returns nil when the block has no brace body or no children."
  (let* ((depth     (car (syntax-ppss header-pos)))
         (block-end (taskjuggler-mode--block-end header-pos))
         children)
    (save-excursion
      (goto-char header-pos)
      (forward-line 1)
      (while (< (point) block-end)
        (when (and (looking-at taskjuggler-mode--moveable-block-re)
                   (= (car (syntax-ppss)) (1+ depth)))
          (push (point) children))
        (forward-line 1)))
    (nreverse children)))

(defun taskjuggler-mode--goto-child (which)
  "Move point to the WHICH child block of the block at point.
WHICH is `first' or `last'.  Signals an error if there is no enclosing
moveable block or the block has no children."
  (let ((header (taskjuggler-mode--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let ((children (taskjuggler-mode--child-block-headers header)))
      (if children
          (goto-char (if (eq which 'first) (car children) (car (last children))))
        (user-error "No child block found")))))

(defun taskjuggler-mode-goto-first-child ()
  "Move point to the first direct child block inside the current block.
Signals an error if point is not on a moveable block header or if the
block contains no child blocks.  Complement to `taskjuggler-mode-goto-parent'."
  (interactive)
  (taskjuggler-mode--goto-child 'first))

(defun taskjuggler-mode-goto-last-child ()
  "Move point to the last direct child block inside the current block.
Signals an error if point is not on a moveable block header or if the
block contains no child blocks.  Complement to `taskjuggler-mode-goto-parent'."
  (interactive)
  (taskjuggler-mode--goto-child 'last))

(defun taskjuggler-mode-forward-block (&optional arg)
  "Move point to the next moveable block header at any nesting depth.
Unlike `taskjuggler-mode-next-block', this is a linear file scan that crosses
nesting boundaries.  With numeric ARG, repeat that many times."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (end-of-line)
    (if (re-search-forward taskjuggler-mode--moveable-block-re nil t)
        (beginning-of-line)
      (user-error "No next block"))))

(defun taskjuggler-mode-backward-block (&optional arg)
  "Move point to the previous moveable block header at any nesting depth.
Unlike `taskjuggler-mode-prev-block', this is a linear file scan that crosses
nesting boundaries.  With numeric ARG, repeat that many times."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (beginning-of-line)
    (if (re-search-backward taskjuggler-mode--moveable-block-re nil t)
        (beginning-of-line)
      (user-error "No previous block"))))

;;; beginning-of-defun / end-of-defun integration

(defun taskjuggler-mode--beginning-of-defun (&optional arg)
  "Move to the beginning of the current or ARGth enclosing/preceding block.
With ARG (default 1) positive, jump to the header of the block containing
point.  If already at a block header, that counts as step one; subsequent
steps search backward for preceding block headers.  With ARG negative,
delegate to `taskjuggler-mode--end-of-defun'.
Implements `beginning-of-defun-function' for `taskjuggler-mode'."
  (let ((count (or arg 1)))
    (cond
     ((> count 0)
      (let ((header (taskjuggler-mode--current-block-header)))
        (if (and header (/= header (line-beginning-position)))
            ;; Inside a block body (not already at its header): jump to the
            ;; header, then do (count-1) additional backward searches.
            (progn
              (goto-char header)
              (dotimes (_ (1- count))
                (when (re-search-backward taskjuggler-mode--moveable-block-re nil 'move)
                  (beginning-of-line))))
          ;; Already at a block header, or not inside any block: search
          ;; backward COUNT times (standard beginning-of-defun behaviour).
          ;; When at a header, step back one char so re-search-backward
          ;; doesn't re-match the current line's keyword.
          (when (and header (not (bobp)))
            (forward-char -1))
          (dotimes (_ count)
            (when (re-search-backward taskjuggler-mode--moveable-block-re nil 'move)
              (beginning-of-line))))))
     ((< count 0)
      (taskjuggler-mode--end-of-defun (- count))))))

(defun taskjuggler-mode--end-of-defun (&optional arg)
  "Move to the end of the current or ARGth following block.
With ARG (default 1) positive, jump past the closing `}' of the block
containing point.  With ARG negative, delegate to
`taskjuggler-mode--beginning-of-defun'.
Implements `end-of-defun-function' for `taskjuggler-mode'."
  (let ((count (or arg 1)))
    (cond
     ((> count 0)
      (dotimes (_ count)
        (let* ((header (taskjuggler-mode--current-block-header))
               (end    (and header (taskjuggler-mode--block-end header))))
          (if (and end (> end (point)))
              ;; Current block ends ahead of point: jump to it.
              (goto-char end)
            ;; Not in a block, or already at/past the block end: find the
            ;; next block and skip past it.
            (when (re-search-forward taskjuggler-mode--moveable-block-re nil 'move)
              (beginning-of-line)
              (goto-char (taskjuggler-mode--block-end (point))))))))
     ((< count 0)
      (taskjuggler-mode--beginning-of-defun (- count))))))

;;; Block editing

(defun taskjuggler-mode-clone-block ()
  "Duplicate the current block immediately after itself.
A blank line separates the original from the clone.  The clone includes any
comment lines immediately preceding the block header.
Point is left on the clone's header line."
  (interactive)
  (let ((header (taskjuggler-mode--current-block-header)))
    (unless header
      (user-error "Not inside a TaskJuggler block"))
    (let* ((start      (taskjuggler-mode--block-with-comments-start header))
           (end        (taskjuggler-mode--block-end header))
           (block-text (buffer-substring start end))
           (header-offset (- header start)))
      ;; end is the position of the first line after the block; insert there.
      (goto-char end)
      (insert "\n" block-text)
      ;; Move point to the clone's header line.
      (goto-char (+ end 1 header-offset)))))

(defun taskjuggler-mode-narrow-to-block ()
  "Narrow the buffer to the current block (header through closing `}').
Signals an error if point is not inside a moveable block."
  (interactive)
  (let ((header (taskjuggler-mode--current-block-header)))
    (unless header
      (user-error "Not inside a TaskJuggler block"))
    (narrow-to-region header (taskjuggler-mode--block-end header))))

(defun taskjuggler-mode-mark-block ()
  "Mark the current block as the active region, including preceding comments.
Point is placed at the start of any immediately preceding comment lines;
mark is placed at the end of the closing `}' line (or the header line for
brace-less blocks).  Signals an error if point is not inside a block."
  (interactive)
  (let ((header (taskjuggler-mode--current-block-header)))
    (unless header
      (user-error "Not inside a TaskJuggler block"))
    (let ((start (taskjuggler-mode--block-with-comments-start header))
          (end   (taskjuggler-mode--block-end header)))
      (goto-char start)
      (push-mark end nil t))))

;;; Sexp movement

(defun taskjuggler-mode--forward-sexp-1 ()
  "Move forward past one sexp.
When point is in the leading whitespace or at the keyword on a moveable
block header line, the entire block (header + brace body) is treated as a
single sexp.  Otherwise falls back to the default sexp movement."
  (let ((indent-end (save-excursion
                      (beginning-of-line)
                      (skip-chars-forward " \t")
                      (point))))
    (if (and (<= (point) indent-end)
             (save-excursion
               (goto-char indent-end)
               (looking-at taskjuggler-mode--moveable-block-re)))
        (goto-char (taskjuggler-mode--block-end indent-end))
      (let ((forward-sexp-function nil)) (forward-sexp 1)))))

(defun taskjuggler-mode--backward-sexp-1 ()
  "Move backward past one sexp.
When the sexp immediately before point is a TJ3 block ending with `}',
jumps back to the start of the block header line (including any preceding
comment lines).  Uses default sexp movement for brace-matching to avoid
reentrancy through `forward-sexp-function'."
  (let (block-start)
    (save-excursion
      (skip-chars-backward " \t\n")
      (when (eq (char-before) ?})
        (condition-case nil
            (progn
              ;; Point is just after `}'; (forward-sexp -1) sees `}' as
              ;; char-before and jumps to the matching `{'.
              (let ((forward-sexp-function nil)) (forward-sexp -1)) ; `}' -> matching `{'
              (beginning-of-line)
              (when (looking-at taskjuggler-mode--moveable-block-re)
                (setq block-start
                      (taskjuggler-mode--block-with-comments-start (point)))))
          (error nil))))
    (if block-start
        (goto-char block-start)
      (let ((forward-sexp-function nil)) (forward-sexp -1)))))

(defun taskjuggler-mode--forward-sexp (&optional arg)
  "Move forward by ARG sexps, treating TJ3 blocks as single units.
Installed as `forward-sexp-function' in `taskjuggler-mode'."
  (let ((count (or arg 1)))
    (cond
     ((> count 0) (dotimes (_ count) (taskjuggler-mode--forward-sexp-1)))
     ((< count 0) (dotimes (_ (- count)) (taskjuggler-mode--backward-sexp-1))))))

(defun taskjuggler-mode-forward-block-sexp (&optional arg)
  "Move forward by ARG blocks, treating each TJ3 block as a single sexp."
  (interactive "p")
  (taskjuggler-mode--forward-sexp (or arg 1)))

(defun taskjuggler-mode-backward-block-sexp (&optional arg)
  "Move backward by ARG blocks, treating each TJ3 block as a single sexp."
  (interactive "p")
  (taskjuggler-mode--forward-sexp (- (or arg 1))))

;;; Compilation

;; TJ3 error format: "filename.tjp:LINE: \e[31mError: message\e[0m"
;; The regexp matches with or without ANSI escape codes so it works whether or
;; not ansi-color-compilation-filter is active.
(defconst taskjuggler-mode--compilation-error-re
  '(taskjuggler
    "^\\([^()\t\n :]+\\):\\([0-9]+\\): \\(?:\e\\[[0-9;]*m\\)?Error:"
    1 2 nil 2)
  "Entry for `compilation-error-regexp-alist-alist' matching TJ3 error output.")

(defvar compilation-error-regexp-alist-alist)
(defvar compilation-error-regexp-alist)

;;; Evil integration

(declare-function evil-define-key* "evil-core")

;; gj/gk   — next/previous sibling at the same depth (mirrors C-M-n/C-M-p)
;; gh       — parent block (mirrors C-M-u)
;; gl/gL    — first/last direct child block (gl mirrors C-M-d)
;; ]t / [t  — skip forward/backward over one block as a unit (mirrors C-M-f/b)
;; ]B / [B  — forward/backward block (linear, crosses depth boundaries)
;; [[ / ]]  — start / end of current block (defun integration)
;; evil-define-key* (function) is used instead of evil-define-key (macro)
;; so the call survives byte-compilation without evil present.
(defvar taskjuggler-mode-map)

(defun taskjuggler-mode--setup-evil-keys ()
  "Set up `evil-mode' keybindings for `taskjuggler-mode' if evil is loaded."
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'normal taskjuggler-mode-map
      (kbd "gj") #'taskjuggler-mode-next-block
      (kbd "gk") #'taskjuggler-mode-prev-block
      (kbd "gh") #'taskjuggler-mode-goto-parent
      (kbd "gl") #'taskjuggler-mode-goto-first-child
      (kbd "gL") #'taskjuggler-mode-goto-last-child
      (kbd "]t") #'taskjuggler-mode-forward-block-sexp
      (kbd "[t") #'taskjuggler-mode-backward-block-sexp
      (kbd "]B") #'taskjuggler-mode-forward-block
      (kbd "[B") #'taskjuggler-mode-backward-block
      (kbd "[[") #'beginning-of-defun
      (kbd "]]") #'end-of-defun)))

;;; Submodules

(require 'taskjuggler-mode-cal)
(require 'taskjuggler-mode-cursor)
(require 'taskjuggler-mode-daemon)
(require 'taskjuggler-mode-flymake)
(require 'taskjuggler-mode-tj3man)

;;; Mode definition

(defcustom taskjuggler-mode-keymap-prefix (kbd "C-c C-t")
  "Prefix key for variable `taskjuggler-mode-command-map'."
  :group 'taskjuggler-mode
  :type 'key-sequence)

(defvar taskjuggler-mode-command-map
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "d") #'taskjuggler-mode-date-dwim)
    (define-key km (kbd "m") #'taskjuggler-mode-man)
    (define-key km (kbd "n") #'taskjuggler-mode-narrow-to-block)
    (define-key km (kbd "D") #'taskjuggler-mode-tj3d-start)
    (define-key km (kbd "a") #'taskjuggler-mode-tj3d-add-project)
    (define-key km (kbd "W") #'taskjuggler-mode-tj3webd-start)
    (define-key km (kbd "b") #'taskjuggler-mode-tj3webd-browse)
    (define-key km (kbd "s") #'taskjuggler-mode-daemon-status)
    km)
  "Keymap for TaskJuggler commands after `taskjuggler-mode-keymap-prefix'.")
(defalias 'taskjuggler-mode-command-map taskjuggler-mode-command-map)

(defvar taskjuggler-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-<up>")   #'taskjuggler-mode-move-block-up)
    (define-key map (kbd "M-<down>") #'taskjuggler-mode-move-block-down)
    (define-key map (kbd "C-M-n")    #'taskjuggler-mode-next-block)
    (define-key map (kbd "C-M-p")    #'taskjuggler-mode-prev-block)
    (define-key map (kbd "C-M-u")    #'taskjuggler-mode-goto-parent)
    (define-key map (kbd "C-M-d")    #'taskjuggler-mode-goto-first-child)
    (define-key map (kbd "C-M-h")    #'taskjuggler-mode-mark-block)
    (when taskjuggler-mode-keymap-prefix
      (define-key map taskjuggler-mode-keymap-prefix 'taskjuggler-mode-command-map))
    map)
  "Keymap for `taskjuggler-mode'.")

(easy-menu-define taskjuggler-mode-menu taskjuggler-mode-map
  "Menu for `taskjuggler-mode'."
  '("TJ3"
    ["Date DWIM" taskjuggler-mode-date-dwim]
    ["Man Lookup" taskjuggler-mode-man]
    ["Narrow to Block" taskjuggler-mode-narrow-to-block]
    "---"
    ("Block Navigation"
     ["Move Block Up" taskjuggler-mode-move-block-up]
     ["Move Block Down" taskjuggler-mode-move-block-down]
     ["Next Block" taskjuggler-mode-next-block]
     ["Prev Block" taskjuggler-mode-prev-block]
     ["Goto Parent" taskjuggler-mode-goto-parent]
     ["Goto First Child" taskjuggler-mode-goto-first-child]
     ["Mark Block" taskjuggler-mode-mark-block])
    "---"
    ("Daemons"
     ["Start tj3d" taskjuggler-mode-tj3d-start]
     ["Stop tj3d" taskjuggler-mode-tj3d-stop]
     ["Add Project to tj3d" taskjuggler-mode-tj3d-add-project]
     ["Start tj3webd" taskjuggler-mode-tj3webd-start]
     ["Stop tj3webd" taskjuggler-mode-tj3webd-stop]
     ["Browse tj3webd" taskjuggler-mode-tj3webd-browse]
     ["Daemon Status" taskjuggler-mode-daemon-status])))

(defvar taskjuggler-mode--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'taskjuggler-mode--show-mode-line-menu)
    map)
  "Keymap for the TJ3 modeline indicator.")

(defun taskjuggler-mode--show-mode-line-menu ()
  "Show `taskjuggler-mode-menu' as a popup from the modeline."
  (interactive)
  (popup-menu taskjuggler-mode-menu))

(define-derived-mode taskjuggler-mode prog-mode "TJ3"
  "Major mode for editing TaskJuggler 3 project files (.tjp, .tji).

TaskJuggler is an open-source project management and scheduling tool.
See URL `https://taskjuggler.org' for more information.

\\{taskjuggler-mode-map}"
  :syntax-table taskjuggler-mode-syntax-table
  ;; Font-lock: nil for KEYWORDS-ONLY means strings/comments use syntax table.
  (setq-local font-lock-defaults
              '(taskjuggler-mode-font-lock-keywords nil nil nil nil))
  ;; Comment configuration: default to # for M-; and comment-region.
  ;; All three styles (//, #, /* */) are recognized for navigation.
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(?://+\\|#+\\|/\\*+\\)[ \t]*")
  ;; Syntax propertize handles # as a line comment character.
  (setq-local syntax-propertize-function #'taskjuggler-mode--syntax-propertize)
  ;; Extend the propertize region to cover any enclosing scissors string so
  ;; that -8<- … ->8- fence pairs are always re-propertized as a unit.
  (add-hook 'syntax-propertize-extend-region-functions
            #'taskjuggler-mode--syntax-propertize-extend-region nil t)
  ;; Indentation
  (setq-local indent-line-function #'taskjuggler-mode-indent-line)
  (setq-local indent-region-function #'taskjuggler-mode-indent-region)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width taskjuggler-mode-indent-level)
  ;; Defun navigation: wire up standard C-M-a / C-M-e / C-M-h / narrow-to-defun.
  (setq-local beginning-of-defun-function #'taskjuggler-mode--beginning-of-defun)
  (setq-local end-of-defun-function #'taskjuggler-mode--end-of-defun)
  ;; Sexp movement: treat a full block (keyword + body) as one sexp for C-M-f/b.
  (setq-local forward-sexp-function #'taskjuggler-mode--forward-sexp)
  ;; Compilation: pre-fill compile-command with tj3 and the current file.
  (when (buffer-file-name)
    (setq-local compile-command
                (concat (taskjuggler-mode--tj3-executable "tj3") " "
                        (shell-quote-argument (buffer-file-name)))))
  ;; Auto-launch calendar popup after date-expecting keywords.
  (add-hook 'post-self-insert-hook #'taskjuggler-mode--maybe-launch-calendar nil t)
  ;; Flymake
  (add-hook 'flymake-diagnostic-functions #'taskjuggler-mode-flymake-backend nil t)
  (add-hook 'flymake-diagnostic-functions #'taskjuggler-mode-tj3d-flymake-backend nil t)
  (add-hook 'after-save-hook #'taskjuggler-mode--tj3d-refresh-on-save nil t)
  ;; Compilation: register TJ3 error regexp when compile is available.
  (when (featurep 'compile)
    (add-to-list 'compilation-error-regexp-alist-alist
                 taskjuggler-mode--compilation-error-re)
    (add-to-list 'compilation-error-regexp-alist 'taskjuggler))
  ;; tj3man: populate keyword cache on first mode activation.
  (taskjuggler-mode--populate-tj3man-keywords)
  ;; Cursor tracking: sync task-at-point via API or js/ fallback.
  (taskjuggler-mode--start-cursor-tracking)
  (add-hook 'kill-buffer-hook #'taskjuggler-mode--stop-cursor-tracking nil t)
  (add-hook 'compilation-finish-functions #'taskjuggler-mode--reset-cursor-file-cache)
  ;; Daemon modeline: combine "TJ3" label with daemon status in one clickable entry.
  (setq mode-line-process nil)
  (setq mode-name
        `(,(propertize "TJ3"
                       'mouse-face 'mode-line-highlight
                       'help-echo "mouse-1: TaskJuggler menu"
                       'local-map taskjuggler-mode--mode-line-map)
          (:eval taskjuggler-mode--daemon-modeline)))
  ;; Auto-start tj3d and tj3webd if configured.
  (when taskjuggler-mode-auto-start-tj3d-tj3webd
    (unless (taskjuggler-mode--tj3d-alive-p)
      (taskjuggler-mode-tj3d-start))
    (unless (taskjuggler-mode--tj3webd-alive-p)
      (taskjuggler-mode-tj3webd-start)))
  ;; Auto-add project to tj3d if configured.
  (when taskjuggler-mode-auto-add-project-tj3d
    (taskjuggler-mode--auto-add-project-tj3d))
  ;; Shut down daemons when Emacs exits (idempotent; safe to add per buffer).
  (add-hook 'kill-emacs-hook #'taskjuggler-mode--stop-daemons)
  ;; Evil: set up normal-state navigation bindings if evil is loaded.
  (taskjuggler-mode--setup-evil-keys)
  ;; Yasnippet: register snippet directory if already loaded.
  (when (featurep 'yasnippet)
    (taskjuggler-mode-snippets-initialize)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tjp\\'" . taskjuggler-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tji\\'" . taskjuggler-mode))

;;; Yasnippet

;; With thanks to @AndreaCrotti. I've taken portions of their
;; yasnippet-snippets code to come up with the below autoloader for
;; the taskjuggler snippets.
;;
;; https://github.com/AndreaCrotti/yasnippet-snippets
(defconst taskjuggler-mode-snippets-dir
  (expand-file-name
   "snippets"
   (file-name-directory
    ;; Copied from ‘f-this-file’ from f.el.
    (cond
     (load-in-progress load-file-name)
     ((and (boundp 'byte-compile-current-file) byte-compile-current-file)
      byte-compile-current-file)
     (:else (buffer-file-name))))))

;;;###autoload
(defun taskjuggler-mode-snippets-initialize ()
  "Load the `taskjuggler-mode-snippets-dir' snippets directory."
  ;; NOTE: we add the symbol `taskjuggler-mode-snippets-dir' rather than its
  ;; value, so that yasnippet will automatically find the directory
  ;; after this package is updated (i.e., moves directory).
  (defvar yas-snippet-dirs)
  (unless (member 'taskjuggler-mode-snippets-dir yas-snippet-dirs)
    (add-to-list 'yas-snippet-dirs 'taskjuggler-mode-snippets-dir t)
    (yas--load-snippet-dirs)))


(provide 'taskjuggler-mode)
;;; taskjuggler-mode.el ends here
