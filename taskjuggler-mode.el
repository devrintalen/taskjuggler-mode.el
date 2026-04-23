;;; taskjuggler-mode.el --- Major mode for TaskJuggler project files -*- lexical-binding: t -*-

;; Copyright (C) 2025 Devrin Talen <devrin@fastmail.com>

;; Author: Devrin Talen <devrin@fastmail.com>
;; Keywords: languages, project-management
;; Package-Version: 0.5.2
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

(require 'calendar)
(require 'man)
(require 'url)
(require 'json)

(declare-function org-read-date "org" (&optional with-time to-time from-string prompt default-time default-input inactive))
(declare-function yas--load-snippet-dirs "yasnippet" ())

(defgroup taskjuggler nil
  "Major mode for editing TaskJuggler project files."
  :group 'languages
  :prefix "taskjuggler-")

(defcustom taskjuggler-indent-level 2
  "Number of spaces per indentation level in TaskJuggler files."
  :type 'integer
  :group 'taskjuggler)

(defcustom taskjuggler-tj3-bin-dir nil
  "Directory containing the tj3 executables (tj3, tj3man), or nil to use PATH.
When non-nil, both `tj3' and `tj3man' are resolved relative to this directory.
Example: (setq taskjuggler-tj3-bin-dir \"/opt/tj3/bin\")"
  :type '(choice (const :tag "Use PATH" nil)
                 (directory :tag "Directory"))
  :group 'taskjuggler)

(defcustom taskjuggler-tj3-extra-args nil
  "List of additional command-line arguments passed to tj3 by the Flymake backend.
Use this to supply flags your project requires, such as:
  (setq-local taskjuggler-tj3-extra-args \\='(\"--prefix\" \"/opt/tj3\"))
The arguments are inserted between the `tj3' executable and the file name."
  :type '(repeat string)
  :safe #'listp
  :group 'taskjuggler)

(defcustom taskjuggler-cursor-idle-delay 0.3
  "Seconds of Emacs idle time before syncing the cursor position.
Set to nil to disable cursor tracking entirely."
  :type '(choice (number :tag "Idle delay in seconds")
                 (const :tag "Disabled" nil))
  :group 'taskjuggler)

(defcustom taskjuggler-cal-show-week-numbers nil
  "When non-nil, display ISO week-number labels (e.g. WW15) in the calendar popup."
  :type 'boolean
  :group 'taskjuggler)

(defcustom taskjuggler-auto-cal-on-date-keyword nil
  "When non-nil, open the calendar popup after typing a date keyword.
Keywords that expect a date value (such as `start' and `end') trigger
the inline calendar picker when the user types a space or tab after them.
See `taskjuggler--date-keyword-list' for the full list of triggering keywords."
  :type 'boolean
  :group 'taskjuggler)

(defcustom taskjuggler-auto-start-tj3d-tj3webd nil
  "When non-nil, start tj3d and tj3webd when `taskjuggler-mode' activates.
Daemons are only started if they are not already running."
  :type 'boolean
  :group 'taskjuggler)

(defcustom taskjuggler-auto-add-project-tj3d nil
  "When non-nil, add the current project to tj3d when visiting a TJ3 file.
Uses `taskjuggler--find-tjp-file' to locate the .tjp file and adds it
via `taskjuggler-tj3d-add-project' if it is not already loaded."
  :type 'boolean
  :group 'taskjuggler)

(defcustom taskjuggler-tj3webd-port 8080
  "Port for the tj3webd web server.
Passed via --port to tj3webd and used to construct the browse URL."
  :type 'integer
  :group 'taskjuggler)

;;; Helpers

(defun taskjuggler--tj3-executable (name)
  "Return the path to the tj3 executable NAME.
When `taskjuggler-tj3-bin-dir' is non-nil, NAME is resolved relative to
that directory.  Otherwise NAME is returned as-is for PATH lookup."
  (if taskjuggler-tj3-bin-dir
      (expand-file-name name taskjuggler-tj3-bin-dir)
    name))

;;; Faces

(defface taskjuggler-date-face
  '((t :inherit font-lock-constant-face))
  "Face for TaskJuggler date literals (e.g. 2023-01-15)."
  :group 'taskjuggler)

(defface taskjuggler-duration-face
  '((t :inherit font-lock-constant-face))
  "Face for TaskJuggler duration literals (e.g. 5d, 2.5h)."
  :group 'taskjuggler)

(defface taskjuggler-macro-face
  '((t :inherit font-lock-preprocessor-face))
  "Face for TaskJuggler macro and environment variable references."
  :group 'taskjuggler)

;; Calendar popup faces

;; Based on the rendering code, here's the mapping:

;; ```
;;   Buffer (in-place date text)
;;   ───────────────────────────
;;   start 2026-04-15
;;         ╔════╗╔══════╗
;;         ║2026║║-04-15║
;;         ╚════╝╚══════╝
;;            │      └── taskjuggler-cal-pending-face
;;            └───────── taskjuggler-cal-typing-face
;;           (typed-len=4 here)

;;   Overlay (popup below current line)
;;   ────────────────────────────────────────────
;;   ╔══════════════════════╗
;;   ║     April 2026       ║  taskjuggler-cal-header-face
;;   ║  Su Mo Tu We Th Fr Sa║  taskjuggler-cal-header-face
;;   ║ 29 30 31  1 [2] 3  4 ║  ┐
;;   ║  5  6  7  8  9 10 11 ║  │  space separators between
;;   ║ 12 13 14[15]16 17 18 ║  │  cells: taskjuggler-cal-face
;;   ║ 19 20 21 22 23 24 25 ║  │
;;   ║ 26 27 28 29 30  1  2 ║  ┘
;;   ╚══════════════════════╝

;;   Cell faces (2-char cells only; spaces use taskjuggler-cal-face):
;;     29 30 31          → taskjuggler-cal-inactive-face  (prev month)
;;      1  3  4 ...      → taskjuggler-cal-face           (regular days)
;;     [2]               → taskjuggler-cal-today-face     (today, not selected)
;;    [15]               → taskjuggler-cal-selected-face  (selected day)
;;      1  2  (last row) → taskjuggler-cal-inactive-face  (next month)
;; ```

;; The box borders are not rendered — they're just here for clarity. The face backgrounds provide the visual container.

(defface taskjuggler-cal-face
  '((t :inherit tooltip))
  "Base face for the calendar popup background and day cells."
  :group 'taskjuggler)

(defface taskjuggler-cal-header-face
  '((t :inherit header-line :weight bold))
  "Face for the calendar month title and day-of-week header."
  :group 'taskjuggler)

(defface taskjuggler-cal-selected-face
  '((t :inherit highlight))
  "Face for the currently selected day in the calendar."
  :group 'taskjuggler)

(defface taskjuggler-cal-today-face
  '((t :inherit warning :weight bold))
  "Face for today's date when visible but not selected."
  :group 'taskjuggler)

(defface taskjuggler-cal-inactive-face
  '((t :inherit (shadow tooltip)))
  "Face for days from the previous or next month."
  :group 'taskjuggler)

(defface taskjuggler-cal-pending-face
  '((t :inherit secondary-selection))
  "Face for the pre-filled date in the buffer during calendar editing.
This face indicates the date that will be committed on RET."
  :group 'taskjuggler)

(defface taskjuggler-cal-typing-face
  '((t :inherit isearch :weight bold))
  "Face for the user-typed portion of the date during calendar editing.
Distinguishes characters the user has typed from the pre-filled suffix."
  :group 'taskjuggler)

(defface taskjuggler-cal-week-face
  '((t :inherit taskjuggler-cal-header-face))
  "Face for ISO week-number labels (e.g. WW15) in the calendar popup."
  :group 'taskjuggler)

;;; Keyword lists

(defconst taskjuggler-top-level-keywords
  '("project" "task" "resource" "account" "scenario"
    "extend" "macro" "include" "flags" "shift")
  "TaskJuggler top-level declaration keywords.")

(defconst taskjuggler-report-keywords
  '("taskreport" "resourcereport" "accountreport" "textreport"
    "tracereport" "icalreport" "timesheetreport" "statussheetreport")
  "TaskJuggler report type keywords.")

(defconst taskjuggler-property-keywords
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

(defconst taskjuggler-value-keywords
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

(defconst taskjuggler--date-re
  (concat "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
          "\\(?:-[0-9]\\{2\\}:[0-9]\\{2\\}"
          "\\(?::[0-9]\\{2\\}\\)?"
          "\\(?:[+-][0-9]\\{4\\}\\)?\\)?")
  "Regexp matching TaskJuggler date literals (YYYY-MM-DD[-hh:mm[:ss]]).")

(defconst taskjuggler--duration-re
  "\\<[0-9]+\\(?:\\.[0-9]+\\)?\\(?:min\\|[hdwmy]\\)\\>"
  "Regexp matching TaskJuggler duration literals (e.g. 5d, 2.5h, 3w).")

(defconst taskjuggler--macro-ref-re
  "\\${[^}\n]+}\\|\\$([A-Z_][A-Z0-9_]*)"
  "Regexp matching TaskJuggler macro (${...}) and env-var ($(VAR)) references.")

(defconst taskjuggler--named-declaration-re
  (concat (regexp-opt '("task" "resource" "account" "scenario"
                        "shift" "macro" "supplement")
                      'words)
          "[ \t]+\\([[:alnum:]_][[:alnum:]_-]*\\)")
  "Regexp matching a declaration keyword followed by its identifier.")

(defvar taskjuggler-font-lock-keywords
  `(;; Named declarations: highlight the identifier after the keyword.
    ;; regexp-opt with 'words wraps in a capturing group, making the keyword
    ;; group 1 and the identifier group 2.
    (,taskjuggler--named-declaration-re
     (2 font-lock-variable-name-face))
    ;; Top-level structural keywords
    (,(regexp-opt taskjuggler-top-level-keywords 'words)
     . font-lock-keyword-face)
    ;; Report type keywords
    (,(regexp-opt taskjuggler-report-keywords 'words)
     . font-lock-function-name-face)
    ;; Property keywords
    (,(regexp-opt taskjuggler-property-keywords 'words)
     . font-lock-function-name-face)
    ;; Value and constant keywords
    (,(regexp-opt taskjuggler-value-keywords 'words)
     . font-lock-variable-name-face)
    ;; Date literals
    (,taskjuggler--date-re . 'taskjuggler-date-face)
    ;; Duration literals
    (,taskjuggler--duration-re . 'taskjuggler-duration-face)
    ;; Macro and environment variable references
    (,taskjuggler--macro-ref-re . 'taskjuggler-macro-face))
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

(defconst taskjuggler--syntax-comment-start (string-to-syntax "< b"))
(defconst taskjuggler--syntax-string-fence  (string-to-syntax "|"))

(defun taskjuggler--syntax-propertize-extend-region (start end)
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

(defun taskjuggler--syntax-propertize (start end)
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
                               'syntax-table taskjuggler--syntax-comment-start))
           ((match-beginning 2)
            (put-text-property (match-beginning 2) (match-end 2)
                               'syntax-table taskjuggler--syntax-string-fence)
            (save-excursion
              (goto-char (match-end 0))
              (when (re-search-forward "->8\\(-\\)" nil t)
                (put-text-property (match-beginning 1) (match-end 1)
                                   'syntax-table taskjuggler--syntax-string-fence))))))))))


;;; Indentation

(defun taskjuggler--continuation-indent ()
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

(defun taskjuggler--calculate-indent ()
  "Return the target indentation column for the current line.
Indentation is based on the brace/bracket nesting depth at the start
of the line, as computed by `syntax-ppss'.  A line opening with `}'
or `]' is de-indented one level relative to the enclosing block.
If the previous non-blank line ends with a comma, the line is treated
as a continuation and aligned with the first argument on the keyword line."
  (save-excursion
    (beginning-of-line)
    (or (taskjuggler--continuation-indent)
        (let* ((depth (car (syntax-ppss)))
               (indent (* depth taskjuggler-indent-level)))
          ;; A closing delimiter starts a new (outer) scope.
          (when (looking-at "[ \t]*[]}]")
            (setq indent (max 0 (- indent taskjuggler-indent-level))))
          indent))))

(defun taskjuggler-indent-line ()
  "Indent the current line of TaskJuggler code."
  (interactive)
  (let ((pos (- (point-max) (point))))
    (indent-line-to (taskjuggler--calculate-indent))
    ;; Restore point position if it was beyond the indentation.
    (when (> (- (point-max) pos) (point))
      (goto-char (- (point-max) pos)))))

(defun taskjuggler-indent-region (beg end)
  "Indent each line in the region from BEG to END."
  (interactive "r")
  (let ((end-marker (copy-marker end)))
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (while (< (point) end-marker)
        (unless (looking-at "[ \t]*$")
          (taskjuggler-indent-line))
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

(defconst taskjuggler--moveable-block-re
  (concat "[ \t]*"
          (regexp-opt (append taskjuggler-top-level-keywords
                              taskjuggler-report-keywords)
                      'words))
  "Regexp matching a line that starts a moveable TaskJuggler block.")

(defun taskjuggler--current-block-header ()
  "Return position of the block header line at or enclosing point.
If point is on a moveable keyword line, return that line's position.
If point is inside a brace block whose opening line is a moveable keyword,
return that opening line's position.  Return nil otherwise.

Uses `syntax-ppss' (which guarantees `syntax-propertize' has run) rather
than `up-list'/`scan-lists' so that # comment lines containing { are
never mistaken for block openers in un-propertized buffer regions."
  (save-excursion
    (beginning-of-line)
    (if (looking-at taskjuggler--moveable-block-re)
        (point)
      (let ((parent-open (nth 1 (syntax-ppss))))
        (when parent-open
          (goto-char parent-open)
          (beginning-of-line)
          (when (looking-at taskjuggler--moveable-block-re)
            (point)))))))

(defun taskjuggler--block-end (header-pos)
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

(defun taskjuggler--block-with-comments-start (header-pos)
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

(defun taskjuggler--prev-sibling-bounds (header-pos)
  "Return (start header end) for the previous sibling of the block at HEADER-POS.
A sibling is a moveable block at the same `syntax-ppss' depth.  Returns nil
if there is no previous sibling."
  (save-excursion
    (let* ((depth     (car (syntax-ppss header-pos)))
           (our-start (taskjuggler--block-with-comments-start header-pos)))
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
                ((looking-at taskjuggler--moveable-block-re)
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
                         (when (looking-at taskjuggler--moveable-block-re)
                           (point)))
                     (error nil))))
                (t nil))))
          (when (and prev-header
                     ;; Guard: don't return the current block as its own sibling.
                     ;; This happens when our-start is at bob and the while loop
                     ;; never moves backward, leaving us on header-pos itself.
                     (/= prev-header header-pos)
                     (= (car (syntax-ppss prev-header)) depth))
            (list (taskjuggler--block-with-comments-start prev-header)
                  prev-header
                  (taskjuggler--block-end prev-header))))))))

(defun taskjuggler--next-sibling-bounds (header-pos)
  "Return (start header end) for the next sibling of the block at HEADER-POS.
A sibling is a moveable block at the same `syntax-ppss' depth.  Returns nil
if there is no next sibling."
  (save-excursion
    (let ((depth   (car (syntax-ppss header-pos)))
          (our-end (taskjuggler--block-end header-pos)))
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
                 (looking-at taskjuggler--moveable-block-re)
                 (= (car (syntax-ppss)) depth))
        (let* ((next-header (point))
               (next-start  (taskjuggler--block-with-comments-start next-header))
               (next-end    (taskjuggler--block-end next-header)))
          (list next-start next-header next-end))))))

(defun taskjuggler--move-block (direction)
  "Move the block at point one sibling in DIRECTION (`up' or `down').
The blank-line separator between blocks is preserved and the block header's
comment lines travel with whichever block they precede."
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let* ((cur-start (taskjuggler--block-with-comments-start header))
           (cur-end   (taskjuggler--block-end header))
           (sibling   (if (eq direction 'up)
                          (taskjuggler--prev-sibling-bounds header)
                        (taskjuggler--next-sibling-bounds header))))
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

(defun taskjuggler-move-block-up ()
  "Move the block at point before its previous sibling block.
The block is identified by the moveable keyword line at or enclosing point.
Any comment lines immediately preceding the block travel with it.
The blank-line separator between the two blocks is preserved."
  (interactive)
  (taskjuggler--move-block 'up))

(defun taskjuggler-move-block-down ()
  "Move the block at point after its next sibling block.
The block is identified by the moveable keyword line at or enclosing point.
Any comment lines immediately preceding the next block travel with it.
The blank-line separator between the two blocks is preserved."
  (interactive)
  (taskjuggler--move-block 'down))

;;; Block navigation

(defun taskjuggler--navigate-sibling (direction)
  "Move point to the sibling block in DIRECTION (`next' or `prev').
Signals an error if there is no enclosing moveable block or no sibling."
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let ((bounds (if (eq direction 'next)
                      (taskjuggler--next-sibling-bounds header)
                    (taskjuggler--prev-sibling-bounds header))))
      (if bounds
          (goto-char (nth 1 bounds))
        (user-error "No %s sibling block" direction)))))

(defun taskjuggler-next-block ()
  "Move point to the next sibling block at the same depth.
Finds the block at or enclosing point and jumps to the header of the
next sibling.  Signals an error if there is no next sibling."
  (interactive)
  (taskjuggler--navigate-sibling 'next))

(defun taskjuggler-prev-block ()
  "Move point to the previous sibling block at the same depth.
Finds the block at or enclosing point and jumps to the header of the
previous sibling.  Signals an error if there is no previous sibling."
  (interactive)
  (taskjuggler--navigate-sibling 'prev))

(defun taskjuggler-goto-parent ()
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

(defun taskjuggler--child-block-headers (header-pos)
  "Return a list of positions of direct child block headers inside HEADER-POS.
Children are moveable-keyword lines at exactly one brace-nesting level deeper
than HEADER-POS.  Returns nil when the block has no brace body or no children."
  (let* ((depth     (car (syntax-ppss header-pos)))
         (block-end (taskjuggler--block-end header-pos))
         children)
    (save-excursion
      (goto-char header-pos)
      (forward-line 1)
      (while (< (point) block-end)
        (when (and (looking-at taskjuggler--moveable-block-re)
                   (= (car (syntax-ppss)) (1+ depth)))
          (push (point) children))
        (forward-line 1)))
    (nreverse children)))

(defun taskjuggler--goto-child (which)
  "Move point to the WHICH child block of the block at point.
WHICH is `first' or `last'.  Signals an error if there is no enclosing
moveable block or the block has no children."
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let ((children (taskjuggler--child-block-headers header)))
      (if children
          (goto-char (if (eq which 'first) (car children) (car (last children))))
        (user-error "No child block found")))))

(defun taskjuggler-goto-first-child ()
  "Move point to the first direct child block inside the current block.
Signals an error if point is not on a moveable block header or if the
block contains no child blocks.  Complement to `taskjuggler-goto-parent'."
  (interactive)
  (taskjuggler--goto-child 'first))

(defun taskjuggler-goto-last-child ()
  "Move point to the last direct child block inside the current block.
Signals an error if point is not on a moveable block header or if the
block contains no child blocks.  Complement to `taskjuggler-goto-parent'."
  (interactive)
  (taskjuggler--goto-child 'last))

(defun taskjuggler-forward-block (&optional arg)
  "Move point to the next moveable block header at any nesting depth.
Unlike `taskjuggler-next-block', this is a linear file scan that crosses
nesting boundaries.  With numeric ARG, repeat that many times."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (end-of-line)
    (if (re-search-forward taskjuggler--moveable-block-re nil t)
        (beginning-of-line)
      (user-error "No next block"))))

(defun taskjuggler-backward-block (&optional arg)
  "Move point to the previous moveable block header at any nesting depth.
Unlike `taskjuggler-prev-block', this is a linear file scan that crosses
nesting boundaries.  With numeric ARG, repeat that many times."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (beginning-of-line)
    (if (re-search-backward taskjuggler--moveable-block-re nil t)
        (beginning-of-line)
      (user-error "No previous block"))))

;;; beginning-of-defun / end-of-defun integration

(defun taskjuggler--beginning-of-defun (&optional arg)
  "Move to the beginning of the current or ARGth enclosing/preceding block.
With ARG (default 1) positive, jump to the header of the block containing
point.  If already at a block header, that counts as step one; subsequent
steps search backward for preceding block headers.  With ARG negative,
delegate to `taskjuggler--end-of-defun'.
Implements `beginning-of-defun-function' for `taskjuggler-mode'."
  (let ((count (or arg 1)))
    (cond
     ((> count 0)
      (let ((header (taskjuggler--current-block-header)))
        (if (and header (/= header (line-beginning-position)))
            ;; Inside a block body (not already at its header): jump to the
            ;; header, then do (count-1) additional backward searches.
            (progn
              (goto-char header)
              (dotimes (_ (1- count))
                (when (re-search-backward taskjuggler--moveable-block-re nil 'move)
                  (beginning-of-line))))
          ;; Already at a block header, or not inside any block: search
          ;; backward COUNT times (standard beginning-of-defun behaviour).
          ;; When at a header, step back one char so re-search-backward
          ;; doesn't re-match the current line's keyword.
          (when (and header (not (bobp)))
            (forward-char -1))
          (dotimes (_ count)
            (when (re-search-backward taskjuggler--moveable-block-re nil 'move)
              (beginning-of-line))))))
     ((< count 0)
      (taskjuggler--end-of-defun (- count))))))

(defun taskjuggler--end-of-defun (&optional arg)
  "Move to the end of the current or ARGth following block.
With ARG (default 1) positive, jump past the closing `}' of the block
containing point.  With ARG negative, delegate to
`taskjuggler--beginning-of-defun'.
Implements `end-of-defun-function' for `taskjuggler-mode'."
  (let ((count (or arg 1)))
    (cond
     ((> count 0)
      (dotimes (_ count)
        (let* ((header (taskjuggler--current-block-header))
               (end    (and header (taskjuggler--block-end header))))
          (if (and end (> end (point)))
              ;; Current block ends ahead of point: jump to it.
              (goto-char end)
            ;; Not in a block, or already at/past the block end: find the
            ;; next block and skip past it.
            (when (re-search-forward taskjuggler--moveable-block-re nil 'move)
              (beginning-of-line)
              (goto-char (taskjuggler--block-end (point))))))))
     ((< count 0)
      (taskjuggler--beginning-of-defun (- count))))))

;;; Block editing

(defun taskjuggler-clone-block ()
  "Duplicate the current block immediately after itself.
A blank line separates the original from the clone.  The clone includes any
comment lines immediately preceding the block header.
Point is left on the clone's header line."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not inside a TaskJuggler block"))
    (let* ((start      (taskjuggler--block-with-comments-start header))
           (end        (taskjuggler--block-end header))
           (block-text (buffer-substring start end))
           (header-offset (- header start)))
      ;; end is the position of the first line after the block; insert there.
      (goto-char end)
      (insert "\n" block-text)
      ;; Move point to the clone's header line.
      (goto-char (+ end 1 header-offset)))))

(defun taskjuggler-narrow-to-block ()
  "Narrow the buffer to the current block (header through closing `}').
Signals an error if point is not inside a moveable block."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not inside a TaskJuggler block"))
    (narrow-to-region header (taskjuggler--block-end header))))

(defun taskjuggler-mark-block ()
  "Mark the current block as the active region, including preceding comments.
Point is placed at the start of any immediately preceding comment lines;
mark is placed at the end of the closing `}' line (or the header line for
brace-less blocks).  Signals an error if point is not inside a block."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not inside a TaskJuggler block"))
    (let ((start (taskjuggler--block-with-comments-start header))
          (end   (taskjuggler--block-end header)))
      (goto-char start)
      (push-mark end nil t))))

;;; Sexp movement

(defun taskjuggler--forward-sexp-1 ()
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
               (looking-at taskjuggler--moveable-block-re)))
        (goto-char (taskjuggler--block-end indent-end))
      (let ((forward-sexp-function nil)) (forward-sexp 1)))))

(defun taskjuggler--backward-sexp-1 ()
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
              (when (looking-at taskjuggler--moveable-block-re)
                (setq block-start
                      (taskjuggler--block-with-comments-start (point)))))
          (error nil))))
    (if block-start
        (goto-char block-start)
      (let ((forward-sexp-function nil)) (forward-sexp -1)))))

(defun taskjuggler--forward-sexp (&optional arg)
  "Move forward by ARG sexps, treating TJ3 blocks as single units.
Installed as `forward-sexp-function' in `taskjuggler-mode'."
  (let ((count (or arg 1)))
    (cond
     ((> count 0) (dotimes (_ count) (taskjuggler--forward-sexp-1)))
     ((< count 0) (dotimes (_ (- count)) (taskjuggler--backward-sexp-1))))))

(defun taskjuggler-forward-block-sexp (&optional arg)
  "Move forward by ARG blocks, treating each TJ3 block as a single sexp."
  (interactive "p")
  (taskjuggler--forward-sexp (or arg 1)))

(defun taskjuggler-backward-block-sexp (&optional arg)
  "Move backward by ARG blocks, treating each TJ3 block as a single sexp."
  (interactive "p")
  (taskjuggler--forward-sexp (- (or arg 1))))

;;; Date insertion — inline calendar picker

(defun taskjuggler--date-bounds-at-point ()
  "Return (BEG . END) of the TJ3 date literal at point, or nil."
  (save-excursion
    (let ((pos (point))
          (bol (line-beginning-position))
          (eol (line-end-position)))
      (goto-char bol)
      (catch 'found
        (while (re-search-forward taskjuggler--date-re eol t)
          (when (and (<= (match-beginning 0) pos)
                     (>= (match-end 0) pos))
            (throw 'found (cons (match-beginning 0) (match-end 0)))))))))

(defconst taskjuggler--partial-date-re
  "[0-9]\\{1,4\\}\\(?:-[0-9]\\{0,2\\}\\(?:-[0-9]\\{0,2\\}\\)?\\)?"
  "Regexp matching any prefix of YYYY-MM-DD.
Matches 1-4 year digits optionally followed by a hyphen + 0-2 month
digits + an optional hyphen + 0-2 day digits.")

(defun taskjuggler--partial-date-bounds-at-point ()
  "Return (BEG . END) of a partial date prefix at point, or nil.
Matches any prefix of YYYY-MM-DD (1-9 characters) that contains point
and is not a complete date.  Excludes numeric tokens followed by a digit,
letter, or decimal point to avoid matching durations (e.g. \"5d\") or
larger numbers."
  (save-excursion
    (let ((pos (point))
          (bol (line-beginning-position))
          (eol (line-end-position)))
      (goto-char bol)
      (catch 'found
        (while (re-search-forward taskjuggler--partial-date-re eol t)
          (let ((mbeg (match-beginning 0))
                (mend (match-end 0))
                (mstr (match-string 0)))
            (when (and (<= mbeg pos) (>= mend pos))
              (unless (string-match-p (concat "^" taskjuggler--date-re "$") mstr)
                ;; The regexp can match bare digits (e.g. the "5" in "5d").
                ;; The next-char guard below is what excludes those cases:
                ;; a match immediately followed by a digit, letter, or "."
                ;; is not a partial date.
                (let ((next (and (< mend eol) (char-after mend))))
                  (unless (and next (or (<= ?0 next ?9)
                                        (<= ?a next ?z)
                                        (<= ?A next ?Z)
                                        (= next ?.)))
                    (throw 'found (cons mbeg mend))))))))))))

(defun taskjuggler--parse-partial-date (partial default-date)
  "Parse PARTIAL date prefix string and return (YEAR MONTH DAY).
PARTIAL is a prefix of YYYY-MM-DD; month and day components may be 1 or 2
digits.  Uses DEFAULT-DATE (a (YEAR MONTH DAY) list) for any components not
present in PARTIAL."
  (let* ((year (nth 0 default-date))
         (month (nth 1 default-date))
         (day (nth 2 default-date))
         (parts (split-string partial "-")))
    ;; Year: must be exactly 4 digits.
    (let ((y-str (nth 0 parts)))
      (when (and y-str (= (length y-str) 4))
        (let ((y (string-to-number y-str)))
          (when (> y 0) (setq year y)))))
    ;; Month: 1 or 2 digits, value 1-12.
    (when-let ((m-str (nth 1 parts)))
      (when (>= (length m-str) 1)
        (let ((m (string-to-number m-str)))
          (when (<= 1 m 12) (setq month m)))))
    ;; Day: 1 or 2 digits, clamped to the parsed month.
    (when-let ((d-str (nth 2 parts)))
      (when (>= (length d-str) 1)
        (let ((d (string-to-number d-str)))
          (when (>= d 1)
            (setq day (min d (calendar-last-day-of-month month year)))))))
    (list year month (taskjuggler--cal-clamp-day year month day))))

(defun taskjuggler--parse-tj-date (date-string)
  "Parse TJ3 DATE-STRING into a (YEAR MONTH DAY) list.
Handles YYYY-MM-DD and YYYY-MM-DD-HH:MM[:SS] formats."
  (when (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
                      date-string)
    (list (string-to-number (match-string 1 date-string))
          (string-to-number (match-string 2 date-string))
          (string-to-number (match-string 3 date-string)))))

(defun taskjuggler--format-tj-date (year month day)
  "Format YEAR, MONTH, DAY as a TJ3 date string YYYY-MM-DD."
  (format "%04d-%02d-%02d" year month day))

;; --- Calendar math ---
;; `calendar-leap-year-p', `calendar-last-day-of-month', and
;; `calendar-day-of-week' come from the built-in `calendar' library.

(defun taskjuggler--cal-clamp-day (year month day)
  "Clamp DAY to the valid range for MONTH of YEAR."
  (min day (calendar-last-day-of-month month year)))

(defun taskjuggler--cal-adjust-date (year month day delta unit)
  "Adjust YEAR-MONTH-DAY by DELTA units (:day, :week, or :month).
Return a (YEAR MONTH DAY) list."
  (pcase unit
    (:day
     (let* ((time (encode-time 0 0 12 day month year))
            (adjusted (time-add time (days-to-time delta)))
            (decoded (decode-time adjusted)))
       (list (nth 5 decoded) (nth 4 decoded) (nth 3 decoded))))
    (:week
     (taskjuggler--cal-adjust-date year month day (* delta 7) :day))
    (:month
     (let* ((new-month (+ month delta))
            ;; Normalise month to 1-12, adjusting year.
            (new-year (+ year (floor (1- new-month) 12)))
            (new-month (1+ (mod (1- new-month) 12)))
            (new-day (taskjuggler--cal-clamp-day new-year new-month day)))
       (list new-year new-month new-day)))))

;; --- Calendar rendering ---
;;
;; The calendar is rendered as a list of propertized strings (one per
;; line).  Each cell carries the appropriate face: header, selected,
;; today, inactive (prev/next month), or the base calendar face.
;; No box border is drawn; the face background provides the visual
;; container.

(defconst taskjuggler--cal-month-names
  ["January" "February" "March" "April" "May" "June"
   "July" "August" "September" "October" "November" "December"]
  "Month names for the calendar header.")

(defconst taskjuggler--cal-day-header " Su Mo Tu We Th Fr Sa "
  "Day-of-week header row for the calendar (22 chars, without week-number prefix).")

(defconst taskjuggler--cal-width 22
  "Base width of the calendar popup in characters (without week-number labels).
When `taskjuggler-cal-show-week-numbers' is non-nil, 5 additional characters
are prepended for the \"WW15 \" label.")

(defvar-local taskjuggler--cal-today nil
  "Today's date as (YEAR MONTH DAY), cached once per edit session.")

(defun taskjuggler--cal-render (year month day)
  "Render a calendar grid for MONTH of YEAR with DAY selected.
Return a list of propertized strings, one per line."
  (let* ((today (or taskjuggler--cal-today
                    (let ((now (decode-time)))
                      (list (nth 5 now) (nth 4 now) (nth 3 now)))))
         (today-year (nth 0 today))
         (today-month (nth 1 today))
         (today-day (nth 2 today))
         (title (taskjuggler--cal-pad-line
                 (taskjuggler--cal-title-line year month)))
         (day-hdr (if taskjuggler-cal-show-week-numbers
                      (concat "    " taskjuggler--cal-day-header)
                    taskjuggler--cal-day-header))
         (weeks (taskjuggler--cal-week-lines year month day
                                             today-year today-month today-day))
         (headers (list (propertize title 'face 'taskjuggler-cal-header-face)
                        (propertize day-hdr 'face 'taskjuggler-cal-header-face))))
    (append headers weeks)))

(defun taskjuggler--cal-title-line (year month)
  "Return the centred title string for MONTH of YEAR."
  (let ((name (aref taskjuggler--cal-month-names (1- month))))
    (format "%s %d" name year)))

(defun taskjuggler--cal-pad-line (text)
  "Pad or centre TEXT to the effective calendar width."
  (let* ((width (+ taskjuggler--cal-width
                   (if taskjuggler-cal-show-week-numbers 4 0)))
         (len (length text))
         (pad-total (max 0 (- width len)))
         (pad-left (/ pad-total 2))
         (pad-right (- pad-total pad-left)))
    (concat (make-string pad-left ?\s) text (make-string pad-right ?\s))))

(defun taskjuggler--cal-week-lines (year month selected-day
                                         today-year today-month today-day)
  "Return a list of propertized week-row strings for MONTH of YEAR.
SELECTED-DAY is highlighted.  TODAY-YEAR, TODAY-MONTH, TODAY-DAY
identify today's date for the today face.  Leading and trailing
cells are filled with days from adjacent months."
  (let* ((days-in-month (calendar-last-day-of-month month year))
         (start-dow (calendar-day-of-week (list month 1 year)))
         (cells '()))
    ;; Leading cells from the previous month.
    (when (> start-dow 0)
      (let* ((prev (taskjuggler--cal-adjust-date year month 1 -1 :month))
             (prev-year (nth 0 prev))
             (prev-month (nth 1 prev))
             (prev-dim (calendar-last-day-of-month prev-month prev-year))
             (first-prev (1+ (- prev-dim start-dow))))
        (dotimes (i start-dow)
          (push (taskjuggler--cal-make-cell
                 (+ first-prev i) 'taskjuggler-cal-inactive-face)
                cells))))
    ;; Days of the current month.
    (dotimes (i days-in-month)
      (let* ((d (1+ i))
             (face (cond
                    ((= d selected-day) 'taskjuggler-cal-selected-face)
                    ((and (= year today-year)
                          (= month today-month)
                          (= d today-day))
                     'taskjuggler-cal-today-face)
                    (t 'taskjuggler-cal-face))))
        (push (taskjuggler--cal-make-cell d face) cells)))
    ;; Trailing cells from the next month.
    (let ((trailing (% (length cells) 7)))
      (when (> trailing 0)
        (let ((need (- 7 trailing)))
          (dotimes (i need)
            (push (taskjuggler--cal-make-cell
                   (1+ i) 'taskjuggler-cal-inactive-face)
                  cells)))))
    ;; Group into weeks of 7 and format.
    ;; For each row, compute the ISO week number from the Thursday of that row.
    ;; Row i (0-indexed) starts on the Sunday at day (1 - start-dow + 7*i)
    ;; relative to the 1st of the month.  Thursday is 4 days later.
    (let ((all-cells (nreverse cells))
          (weeks '())
          (row '())
          (row-idx 0))
      (dolist (cell all-cells)
        (push cell row)
        (when (= (length row) 7)
          (let* ((thursday-rel (+ 1 (- start-dow) (* row-idx 7) 4))
                 (thu (taskjuggler--cal-adjust-date year month 1 (1- thursday-rel) :day))
                 (week-num (car (calendar-iso-from-absolute
                                (calendar-absolute-from-gregorian
                                 (list (nth 1 thu) (nth 2 thu) (nth 0 thu)))))))
            (push (taskjuggler--cal-format-week (nreverse row) week-num) weeks))
          (setq row nil)
          (setq row-idx (1+ row-idx))))
      (nreverse weeks))))

(defun taskjuggler--cal-make-cell (day face)
  "Return a propertized 2-character string for DAY with FACE."
  (propertize (format "%2d" day) 'face face))

(defun taskjuggler--cal-format-week (cells week-num)
  "Join a list of 7 propertized day CELLS into a single week-row string.
WEEK-NUM is the ISO week number; it is prepended as a \"WW%02d\" label when
`taskjuggler-cal-show-week-numbers' is non-nil.
Each cell is separated by a space with the base calendar face."
  (let* ((pad (propertize " " 'face 'taskjuggler-cal-face))
         (body (mapconcat #'identity cells pad)))
    (if taskjuggler-cal-show-week-numbers
        (let ((label (propertize (format "WW%02d" week-num)
                                 'face 'taskjuggler-cal-week-face)))
          (concat label pad body pad))
      (concat pad body pad))))

;; --- Overlay management ---
;;
;; Uses the same technique as company-mode's pseudo-tooltip: a single
;; overlay spans all lines the calendar covers.  The overlay's
;; `display' is set to "" to hide the real text, and `before-string'
;; carries the full popup as a single multi-line string where each
;; calendar row is spliced into the corresponding buffer line,
;; preserving characters to the left and right.

(defvar-local taskjuggler--cal-overlay nil
  "Overlay used by the inline calendar picker.")

(defvar-local taskjuggler--cal-typing-ov nil
  "Overlay for the user-typed portion of the date during calendar editing.")

(defvar-local taskjuggler--cal-pending-ov nil
  "Overlay for the pre-filled portion of the date during calendar editing.")

(defvar-local taskjuggler--cal-column nil
  "Column at which the calendar was first shown.
Captured once so the calendar stays anchored when navigating.")

;; --- Minor mode state ---
;;
;; These variables track the editing session while
;; `taskjuggler-cal-active-mode' is enabled.

(defvar-local taskjuggler--cal-date-beg nil
  "Buffer position where the date string starts during editing.")

(defvar-local taskjuggler--cal-was-inserted nil
  "Non-nil if the date was freshly inserted (should be deleted on cancel).")

(defvar-local taskjuggler--cal-orig-date nil
  "Original (YEAR MONTH DAY) before editing began.")

(defvar-local taskjuggler--cal-year nil
  "Current year displayed by the calendar picker.")

(defvar-local taskjuggler--cal-month nil
  "Current month displayed by the calendar picker.")

(defvar-local taskjuggler--cal-day nil
  "Current day displayed by the calendar picker.")

(defvar-local taskjuggler--cal-debounce-timer nil
  "Idle timer used to debounce calendar overlay updates.")

(defun taskjuggler--cal-expand-tabs-with-props (str)
  "Expand tabs in STR to spaces using `tab-width', preserving text properties.
Each space replacing a tab inherits the text properties of that tab character."
  (let ((parts '())
        (col 0))
    (dotimes (i (length str))
      (let ((ch (aref str i)))
        (if (= ch ?\t)
            (let* ((spaces (- tab-width (% col tab-width)))
                   (props (text-properties-at i str))
                   (pad (apply #'propertize (make-string spaces ?\s) props)))
              (push pad parts)
              (setq col (+ col spaces)))
          (push (substring str i (1+ i)) parts)
          (setq col (1+ col)))))
    (apply #'concat (nreverse parts))))

(defun taskjuggler--cal-splice-line (old new col)
  "Splice NEW into OLD at column COL, preserving surrounding text.
OLD is the original buffer line, NEW is the calendar row to insert.
Tab characters in OLD are expanded to spaces before slicing so that
COL is a visual column, not a character offset.  Text properties on
OLD (including font-lock faces) are preserved in the returned string.
Returns the combined string."
  (let* ((old-exp (taskjuggler--cal-expand-tabs-with-props old))
         (old-len (length old-exp))
         (new-len (length new))
         (left (if (<= col old-len)
                   (substring old-exp 0 col)
                 (concat old-exp (make-string (- col old-len) ?\s))))
         (right-start (+ col new-len))
         (right (if (< right-start old-len)
                    (substring old-exp right-start)
                  "")))
    (concat left new right)))

(defun taskjuggler--cal-build-display (cal-lines old-lines col)
  "Build the multi-line display string for the calendar popup.
CAL-LINES is a list of calendar row strings.  OLD-LINES is a list
of original buffer line strings.  COL is the column offset.
Returns a single string with embedded newlines."
  (let ((result '()))
    (while cal-lines
      (let* ((cal-line (pop cal-lines))
             (old-line (or (pop old-lines) ""))
             (spliced (taskjuggler--cal-splice-line old-line cal-line col)))
        (push spliced result)))
    (mapconcat #'identity (nreverse result) "\n")))

(defun taskjuggler--cal-show-overlay (year month day)
  "Display or update the calendar overlay below the current line.
The calendar is spliced into each line's display at the anchored
column, preserving buffer text to the left and right.  Shows MONTH
of YEAR with DAY highlighted.

On the first call the overlay is created; subsequent calls reuse it
and only update its `before-string'."
  (unless taskjuggler--cal-column
    (setq taskjuggler--cal-column (current-column)))
  (let* ((cal-lines (taskjuggler--cal-render year month day))
         (n-lines (length cal-lines))
         (col taskjuggler--cal-column))
    (save-excursion
      (forward-line 1)
      (let* ((beg (point))
             (old-lines (taskjuggler--cal-collect-lines n-lines))
             (end (point))
             (display-str (taskjuggler--cal-build-display
                           cal-lines old-lines col)))
        (if taskjuggler--cal-overlay
            ;; Reuse existing overlay — just update the display content.
            ;; Move it if the region changed (e.g. different week count).
            (progn
              (move-overlay taskjuggler--cal-overlay beg end)
              (overlay-put taskjuggler--cal-overlay
                           'before-string (concat display-str "\n")))
          ;; First call — create the overlay.
          (let ((ov (make-overlay beg end nil t)))
            (overlay-put ov 'display "")
            (overlay-put ov 'before-string (concat display-str "\n"))
            (overlay-put ov 'line-prefix "")
            (overlay-put ov 'window (selected-window))
            (overlay-put ov 'priority 111)
            (overlay-put ov 'taskjuggler-calendar t)
            (setq taskjuggler--cal-overlay ov)))))))

(defun taskjuggler--cal-collect-lines (n)
  "Collect N buffer lines starting from point, preserving text properties.
Advances point past the collected lines.  Returns a list of strings."
  (let ((lines '())
        (i 0))
    (while (and (< i n) (not (eobp)))
      (push (buffer-substring (line-beginning-position) (line-end-position))
            lines)
      (forward-line 1)
      (setq i (1+ i)))
    (nreverse lines)))

(defun taskjuggler--cal-remove-overlay ()
  "Remove the calendar overlay if it exists."
  (when taskjuggler--cal-overlay
    (delete-overlay taskjuggler--cal-overlay)
    (setq taskjuggler--cal-overlay nil)))

;; --- In-buffer date editing ---
;;
;; The date text lives in the buffer during editing.  A "typed-len"
;; counter tracks how many characters from the left the user has
;; explicitly typed (shown with `taskjuggler-cal-typing-face'); the
;; remainder uses `taskjuggler-cal-pending-face' to indicate the
;; pre-filled value that RET will commit.

(defconst taskjuggler--cal-date-len 10
  "Length of a YYYY-MM-DD date string.")

(defconst taskjuggler--cal-help-message
  "S-arrows: day/week  S-PgUp/Dn: month  Type: YYYY-MM-DD  RET/TAB: confirm  C-g: cancel"
  "Help text shown in the echo area during calendar editing.")

(defun taskjuggler--cal-valid-char-at-p (ch pos)
  "Return non-nil if CH is valid at position POS in a YYYY-MM-DD string."
  (if (or (= pos 4) (= pos 7))
      (= ch ?-)
    (<= ?0 ch ?9)))

(defun taskjuggler--cal-apply-faces (date-beg typed-len)
  "Apply typing and pending face overlays to the date string at DATE-BEG.
The first TYPED-LEN characters get the typing face; the rest get pending.
Overlays are used so font-lock cannot override them.  Existing overlays
are deleted and recreated on each call to avoid stale positions caused
by intervening buffer modifications."
  (let ((typed-end (+ date-beg typed-len))
        (date-end (+ date-beg taskjuggler--cal-date-len)))
    (when taskjuggler--cal-typing-ov
      (delete-overlay taskjuggler--cal-typing-ov)
      (setq taskjuggler--cal-typing-ov nil))
    (when taskjuggler--cal-pending-ov
      (delete-overlay taskjuggler--cal-pending-ov)
      (setq taskjuggler--cal-pending-ov nil))
    (when (> typed-len 0)
      (let ((ov (make-overlay date-beg typed-end)))
        (overlay-put ov 'face 'taskjuggler-cal-typing-face)
        (overlay-put ov 'priority 110)
        (setq taskjuggler--cal-typing-ov ov)))
    (when (< typed-len taskjuggler--cal-date-len)
      (let ((ov (make-overlay typed-end date-end)))
        (overlay-put ov 'face 'taskjuggler-cal-pending-face)
        (overlay-put ov 'priority 110)
        (setq taskjuggler--cal-pending-ov ov)))))

(defun taskjuggler--cal-remove-faces (_date-beg)
  "Remove the typing/pending face overlays."
  (when taskjuggler--cal-typing-ov
    (delete-overlay taskjuggler--cal-typing-ov)
    (setq taskjuggler--cal-typing-ov nil))
  (when taskjuggler--cal-pending-ov
    (delete-overlay taskjuggler--cal-pending-ov)
    (setq taskjuggler--cal-pending-ov nil)))

(defun taskjuggler--cal-update-prefill (date-beg typed-len year month day)
  "Update the pre-filled suffix of the date at DATE-BEG.
The first TYPED-LEN characters are left untouched.  The rest are
filled with the date formatted from YEAR, MONTH, and DAY."
  (let* ((full-date (taskjuggler--format-tj-date year month day))
         (suffix (substring full-date typed-len)))
    (save-excursion
      (goto-char (+ date-beg typed-len))
      (delete-char (length suffix))
      (insert suffix))))

(defun taskjuggler--cal-parse-typed-prefix (date-beg typed-len default-date)
  "Parse the typed prefix at DATE-BEG and return (YEAR MONTH DAY).
Uses DEFAULT-DATE (a (YEAR MONTH DAY) list) for components not yet
typed.  TYPED-LEN is how many characters have been typed so far."
  (let* ((year (nth 0 default-date))
         (month (nth 1 default-date))
         (day (nth 2 default-date))
         (typed (buffer-substring-no-properties
                 date-beg (+ date-beg typed-len))))
    (when (>= typed-len 4)
      (let ((y (string-to-number (substring typed 0 4))))
        (when (> y 0) (setq year y))))
    (when (>= typed-len 7)
      (let ((m (string-to-number (substring typed 5 7))))
        (when (<= 1 m 12) (setq month m))))
    (when (>= typed-len 10)
      (let ((d (string-to-number (substring typed 8 10))))
        (when (>= d 1)
          (setq day (min d (calendar-last-day-of-month month year))))))
    (list year month (taskjuggler--cal-clamp-day year month day))))

;; --- Minor mode for calendar editing ---
;;
;; Instead of a read-event loop, the calendar picker uses a transient
;; minor mode (like company-mode) with its own keymap for explicit
;; actions (commit, cancel, navigation) and a `post-command-hook' for
;; passive monitoring of point and typed text.

(defconst taskjuggler--cal-debounce-delay 0.05
  "Idle-timer delay (seconds) before refreshing the calendar overlay.")

(defun taskjuggler--cal-nav-delta (key)
  "Return (DELTA . UNIT) for a shift-arrow KEY."
  (pcase key
    ('S-right '(1 . :day))
    ('S-left  '(-1 . :day))
    ('S-down  '(1 . :week))
    ('S-up    '(-1 . :week))
    ('S-next  '(1 . :month))
    ('S-prior '(-1 . :month))))

(defun taskjuggler--cal-cleanup ()
  "Tear down calendar picker state and minor mode."
  (when taskjuggler--cal-debounce-timer
    (cancel-timer taskjuggler--cal-debounce-timer)
    (setq taskjuggler--cal-debounce-timer nil))
  (remove-hook 'post-command-hook #'taskjuggler--cal-post-command t)
  (remove-hook 'kill-buffer-hook #'taskjuggler--cal-cancel t)
  (taskjuggler--cal-remove-overlay)
  (taskjuggler--cal-remove-faces taskjuggler--cal-date-beg)
  (setq taskjuggler--cal-column nil
        taskjuggler--cal-today nil)
  (taskjuggler-cal-active-mode -1))

(defun taskjuggler--cal-commit ()
  "Commit the pending date and close the calendar picker."
  (interactive)
  (let ((date-beg taskjuggler--cal-date-beg)
        (year taskjuggler--cal-year)
        (month taskjuggler--cal-month)
        (day taskjuggler--cal-day))
    (taskjuggler--cal-cleanup)
    ;; Write the final date and move point past it.
    (save-excursion
      (goto-char date-beg)
      (delete-char taskjuggler--cal-date-len)
      (insert (taskjuggler--format-tj-date year month day)))
    (goto-char (+ date-beg taskjuggler--cal-date-len))))

(defun taskjuggler--cal-cancel ()
  "Cancel the calendar picker and restore the original buffer state."
  (interactive)
  (let ((date-beg taskjuggler--cal-date-beg)
        (was-inserted taskjuggler--cal-was-inserted)
        (orig-date taskjuggler--cal-orig-date))
    (taskjuggler--cal-cleanup)
    (if was-inserted
        ;; Date was freshly inserted — delete it entirely.
        (delete-region date-beg (+ date-beg taskjuggler--cal-date-len))
      ;; Date existed — restore the original text.
      (save-excursion
        (goto-char date-beg)
        (delete-char taskjuggler--cal-date-len)
        (insert (apply #'taskjuggler--format-tj-date orig-date))))))

(defun taskjuggler--cal-commit-or-cancel ()
  "Commit if a partial date has been typed, otherwise cancel.
Bound to SPC in the calendar picker."
  (interactive)
  (let* ((date-beg taskjuggler--cal-date-beg)
         (typed-len (- (point) date-beg)))
    (if (> typed-len 0)
        (taskjuggler--cal-commit)
      (taskjuggler--cal-cancel))))

(defun taskjuggler--cal-navigate (key)
  "Adjust the selected date by the shift-arrow KEY and refresh."
  (let* ((delta-unit (taskjuggler--cal-nav-delta key))
         (adjusted (taskjuggler--cal-adjust-date
                    taskjuggler--cal-year taskjuggler--cal-month
                    taskjuggler--cal-day
                    (car delta-unit) (cdr delta-unit))))
    (setq taskjuggler--cal-year (nth 0 adjusted)
          taskjuggler--cal-month (nth 1 adjusted)
          taskjuggler--cal-day (nth 2 adjusted))
    ;; Rewrite the full date template and move point back to date-beg.
    (let ((date-beg taskjuggler--cal-date-beg))
      (save-excursion
        (goto-char date-beg)
        (delete-char taskjuggler--cal-date-len)
        (insert (taskjuggler--format-tj-date
                 taskjuggler--cal-year taskjuggler--cal-month
                 taskjuggler--cal-day)))
      (goto-char date-beg)
      (taskjuggler--cal-apply-faces date-beg 0)
      (taskjuggler--cal-show-overlay
       taskjuggler--cal-year taskjuggler--cal-month
       taskjuggler--cal-day))))

(defun taskjuggler--cal-nav-right ()
  "Navigate calendar one day forward."
  (interactive)
  (taskjuggler--cal-navigate 'S-right))

(defun taskjuggler--cal-nav-left ()
  "Navigate calendar one day backward."
  (interactive)
  (taskjuggler--cal-navigate 'S-left))

(defun taskjuggler--cal-nav-down ()
  "Navigate calendar one week forward."
  (interactive)
  (taskjuggler--cal-navigate 'S-down))

(defun taskjuggler--cal-nav-up ()
  "Navigate calendar one week backward."
  (interactive)
  (taskjuggler--cal-navigate 'S-up))

(defun taskjuggler--cal-nav-next ()
  "Navigate calendar one month forward."
  (interactive)
  (taskjuggler--cal-navigate 'S-next))

(defun taskjuggler--cal-nav-prior ()
  "Navigate calendar one month backward."
  (interactive)
  (taskjuggler--cal-navigate 'S-prior))

(defun taskjuggler--cal-overwrite-char ()
  "Overwrite the template character at point with the typed character.
Used for digit and hyphen input during calendar date editing so that
`self-insert-command' does not grow the fixed-length date template."
  (interactive)
  (let* ((date-beg taskjuggler--cal-date-beg)
         (typed-len (- (point) date-beg))
         (ch last-command-event))
    (when (and (< typed-len taskjuggler--cal-date-len)
               (taskjuggler--cal-valid-char-at-p ch typed-len))
      (delete-char 1)
      (insert (char-to-string ch)))))

(defvar taskjuggler-cal-active-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<return>")  #'taskjuggler--cal-commit)
    (define-key map (kbd "<tab>")     #'taskjuggler--cal-commit)
    (define-key map (kbd "SPC")       #'taskjuggler--cal-commit-or-cancel)
    (define-key map (kbd "C-g")       #'taskjuggler--cal-cancel)
    (define-key map (kbd "S-<right>") #'taskjuggler--cal-nav-right)
    (define-key map (kbd "S-<left>")  #'taskjuggler--cal-nav-left)
    (define-key map (kbd "S-<down>")  #'taskjuggler--cal-nav-down)
    (define-key map (kbd "S-<up>")    #'taskjuggler--cal-nav-up)
    (define-key map (kbd "S-<next>")  #'taskjuggler--cal-nav-next)
    (define-key map (kbd "S-<prior>") #'taskjuggler--cal-nav-prior)
    ;; Digits and hyphen use overwrite-style insertion to keep the
    ;; date template at a fixed 10-character length.
    (dolist (ch (append (number-sequence ?0 ?9) (list ?-)))
      (define-key map (vector ch) #'taskjuggler--cal-overwrite-char))
    map)
  "Keymap active while the inline calendar picker is open.")

;; Register our keymap in `emulation-mode-map-alists' so it takes
;; priority over evil-mode's keymaps (which also live there).
;; The variable holds a (CONDITION . MAP) pair; we set CONDITION to t
;; while the picker is active and nil otherwise.
(defvar-local taskjuggler--cal-emulation-alist nil
  "Emulation keymap alist entry for the calendar picker.
Added to `emulation-mode-map-alists' so the picker keymap beats evil.")
(add-to-list 'emulation-mode-map-alists 'taskjuggler--cal-emulation-alist)

(define-minor-mode taskjuggler-cal-active-mode
  "Transient minor mode active while the inline calendar picker is open."
  :lighter " TJ-Cal"
  :keymap taskjuggler-cal-active-mode-map
  (if taskjuggler-cal-active-mode
      (progn
        (setq taskjuggler--cal-emulation-alist
              (list (cons t taskjuggler-cal-active-mode-map)))
        (message "%s" taskjuggler--cal-help-message))
    ;; Deactivate the emulation keymap and cancel any pending timer.
    (setq taskjuggler--cal-emulation-alist nil)
    (when taskjuggler--cal-debounce-timer
      (cancel-timer taskjuggler--cal-debounce-timer)
      (setq taskjuggler--cal-debounce-timer nil))))

;; --- Post-command monitoring ---

(defun taskjuggler--cal-schedule-refresh ()
  "Schedule a debounced calendar overlay refresh."
  (when taskjuggler--cal-debounce-timer
    (cancel-timer taskjuggler--cal-debounce-timer))
  (setq taskjuggler--cal-debounce-timer
        (run-with-idle-timer
         taskjuggler--cal-debounce-delay nil
         #'taskjuggler--cal-deferred-refresh (current-buffer))))

(defun taskjuggler--cal-deferred-refresh (buf)
  "Refresh the calendar overlay in BUF after the debounce delay."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when taskjuggler-cal-active-mode
        (setq taskjuggler--cal-debounce-timer nil)
        (taskjuggler--cal-show-overlay
         taskjuggler--cal-year taskjuggler--cal-month
         taskjuggler--cal-day)))))

(defun taskjuggler--cal-post-command ()
  "Monitor point and buffer text after each command.
Cancels the picker if point moves before `taskjuggler--cal-date-beg'.
Otherwise parses the typed prefix and updates faces and the overlay."
  (when taskjuggler-cal-active-mode
    (let ((date-beg taskjuggler--cal-date-beg)
          (date-end (+ taskjuggler--cal-date-beg taskjuggler--cal-date-len)))
      (cond
       ;; Point moved before the date region — cancel.
       ((< (point) date-beg)
        (taskjuggler--cal-cancel))
       ;; Point moved past the date region — cancel.
       ((> (point) date-end)
        (taskjuggler--cal-cancel))
       ;; Point is within the date region — parse and update.
       (t
        (let ((typed-len (- (point) date-beg)))
          (when (> typed-len 0)
            ;; Only parse the typed prefix when the user has actually
            ;; typed something.  When typed-len is 0 (e.g. after a
            ;; shift-arrow navigation command), the state variables and
            ;; buffer text are already correct — parsing with typed-len=0
            ;; would return orig-date and overwrite the navigated date.
            (let ((parsed (taskjuggler--cal-parse-typed-prefix
                           date-beg typed-len taskjuggler--cal-orig-date)))
              (setq taskjuggler--cal-year (nth 0 parsed)
                    taskjuggler--cal-month (nth 1 parsed)
                    taskjuggler--cal-day (nth 2 parsed))
              (taskjuggler--cal-update-prefill
               date-beg typed-len
               taskjuggler--cal-year taskjuggler--cal-month taskjuggler--cal-day)))
          (taskjuggler--cal-apply-faces date-beg typed-len)
          (taskjuggler--cal-schedule-refresh)))))))

;; --- Calendar edit entry point ---

(defun taskjuggler--cal-edit (date-beg year month day was-inserted)
  "Start the calendar picker for the date at DATE-BEG.
YEAR, MONTH, DAY are the initial date.  WAS-INSERTED is non-nil if
the date was freshly inserted (should be deleted on cancel).
Point must be at DATE-BEG on entry."
  ;; Cache today once so every render during this session is free.
  (let ((now (decode-time)))
    (setq taskjuggler--cal-today (list (nth 5 now) (nth 4 now) (nth 3 now))))
  ;; Store editing state.
  (setq taskjuggler--cal-date-beg date-beg
        taskjuggler--cal-was-inserted was-inserted
        taskjuggler--cal-orig-date (list year month day)
        taskjuggler--cal-year year
        taskjuggler--cal-month month
        taskjuggler--cal-day day)
  ;; Set up faces and overlay.
  (taskjuggler--cal-apply-faces date-beg 0)
  (taskjuggler--cal-show-overlay year month day)
  ;; Install hooks and activate the minor mode.
  (add-hook 'kill-buffer-hook #'taskjuggler--cal-cancel nil t)
  (add-hook 'post-command-hook #'taskjuggler--cal-post-command nil t)
  (taskjuggler-cal-active-mode 1))

;; --- Public date commands ---

(defun taskjuggler-insert-date ()
  "Insert a TaskJuggler date literal at point using an inline calendar.
Inserts today's date with a pending face and opens the calendar picker."
  (interactive)
  (pcase-let ((`(,_ ,_min ,_hour ,day ,month ,year . ,_) (decode-time)))
    (let ((date-beg (point)))
      (insert (taskjuggler--format-tj-date year month day))
      (goto-char date-beg)
      (taskjuggler--cal-edit date-beg year month day t))))

(defun taskjuggler-date-dwim ()
  "Insert or edit a TaskJuggler date literal depending on context.
If point is on a complete date literal, edit it in place.
If point is on a partial date prefix (e.g. \"2026-04-\"), delete it and open
the calendar picker to insert a fresh date.
If point is on whitespace or at end of line, insert a new date.
Otherwise, signal a user-error."
  (interactive)
  (let ((partial-bounds (taskjuggler--partial-date-bounds-at-point)))
    (cond
     ((taskjuggler--date-bounds-at-point)
      (taskjuggler-edit-date-at-point))
     (partial-bounds
      (let* ((partial (buffer-substring-no-properties (car partial-bounds) (cdr partial-bounds)))
             (partial-len (length partial)))
        (pcase-let ((`(,_ ,_min ,_hour ,today-day ,today-month ,today-year . ,_)
                     (decode-time)))
          (let* ((default-date (list today-year today-month today-day))
                 (parsed (taskjuggler--parse-partial-date partial default-date))
                 (year (nth 0 parsed))
                 (month (nth 1 parsed))
                 (day (nth 2 parsed)))
            (delete-region (car partial-bounds) (cdr partial-bounds))
            (goto-char (car partial-bounds))
            (let ((date-beg (point)))
              (insert (taskjuggler--format-tj-date year month day))
              (goto-char date-beg)
              (taskjuggler--cal-edit date-beg year month day t)
              ;; Position point after the typed prefix so post-command-hook
              ;; picks it up as typed-len = partial-len.
              (goto-char (+ date-beg partial-len)))))))
     ((or (eolp) (looking-at-p "[ \t]"))
      (taskjuggler-insert-date))
     (t
      (user-error "No date at point")))))

(defun taskjuggler-edit-date-at-point ()
  "Edit the TJ3 date literal at point using an inline calendar.
The existing date pre-fills the calendar."
  (interactive)
  (let ((bounds (taskjuggler--date-bounds-at-point)))
    (unless bounds
      (user-error "No TaskJuggler date at point"))
    (let* ((date-beg (car bounds))
           (old-string (buffer-substring-no-properties date-beg (cdr bounds)))
           (parsed (taskjuggler--parse-tj-date old-string)))
      (unless parsed
        (user-error "Cannot parse date: %s" old-string))
      (pcase-let ((`(,year ,month ,day) parsed))
        (goto-char date-beg)
        (taskjuggler--cal-edit date-beg year month day nil)))))

;;; Auto-launch calendar on date keywords

(defconst taskjuggler--date-keyword-list
  '("start" "end" "maxend" "maxstart" "minend" "minstart" "now")
  "Property keywords that expect a date literal to immediately follow them.
Used by `taskjuggler--maybe-launch-calendar' to trigger the inline calendar
picker automatically when `taskjuggler-auto-cal-on-date-keyword' is non-nil.")

(defconst taskjuggler--date-keyword-regexp
  (concat (regexp-opt taskjuggler--date-keyword-list 'words) "[ \t]")
  "Regexp matching a date keyword followed by a space or tab.
Pre-computed so `taskjuggler--maybe-launch-calendar' avoids rebuilding it on
every keystroke.")

(defun taskjuggler--maybe-launch-calendar ()
  "Auto-launch the calendar picker after typing a date keyword and a space.
Installed on `post-self-insert-hook'.  When
`taskjuggler-auto-cal-on-date-keyword' is non-nil and the calendar is not
already active, fires when the character just inserted is a space or tab
and the text immediately before it ends with a keyword from
`taskjuggler--date-keyword-list'.  Suppressed inside comments and strings."
  (when (and taskjuggler-auto-cal-on-date-keyword
             (not taskjuggler-cal-active-mode)
             (memq last-command-event '(?\s ?\t))
             (not (nth 8 (syntax-ppss)))
             (looking-back taskjuggler--date-keyword-regexp
                           (line-beginning-position)))
    (taskjuggler-insert-date)))

;;; Compilation

;; TJ3 error format: "filename.tjp:LINE: \e[31mError: message\e[0m"
;; The regexp matches with or without ANSI escape codes so it works whether or
;; not ansi-color-compilation-filter is active.
(defconst taskjuggler--compilation-error-re
  '(taskjuggler
    "^\\([^()\t\n :]+\\):\\([0-9]+\\): \\(?:\e\\[[0-9;]*m\\)?Error:"
    1 2 nil 2)
  "Entry for `compilation-error-regexp-alist-alist' matching TJ3 error output.")

(defvar compilation-error-regexp-alist-alist)
(defvar compilation-error-regexp-alist)

;;; Flymake

(defvar-local taskjuggler--flymake-proc nil
  "The currently running flymake process for this buffer.")

(defun taskjuggler-flymake-backend (report-fn &rest _args)
  "Flymake backend for `taskjuggler-mode'.
Runs tj3 on the current file and reports errors via REPORT-FN."
  (unless (executable-find (taskjuggler--tj3-executable "tj3"))
    (error "Cannot find tj3 executable: %s" (taskjuggler--tj3-executable "tj3")))
  (when (process-live-p taskjuggler--flymake-proc)
    (kill-process taskjuggler--flymake-proc))
  (let* ((source (current-buffer))
         (file   (buffer-file-name)))
    (if (not file)
        (funcall report-fn nil)
      (setq taskjuggler--flymake-proc
            (make-process
             :name "taskjuggler-flymake"
             :noquery t
             :connection-type 'pipe
             :buffer (generate-new-buffer " *taskjuggler-flymake*")
             :command (append (list (taskjuggler--tj3-executable "tj3"))
                              taskjuggler-tj3-extra-args (list file))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (unwind-protect
                     (if (eq proc (buffer-local-value 'taskjuggler--flymake-proc source))
                         (with-current-buffer (process-buffer proc)
                           ;; Strip ANSI escape codes before parsing.
                           (goto-char (point-min))
                           (while (re-search-forward "\e\\[[0-9;]*m" nil t)
                             (replace-match ""))
                           ;; Collect errors for the current file only.
                           ;; Errors in included files are reported there instead.
                           (let (diags)
                             (goto-char (point-min))
                             (while (re-search-forward
                                     (concat "^" (regexp-quote file)
                                             ":\\([0-9]+\\): \\(Error\\|Warning\\): \\(.*\\)")
                                     nil t)
                               (let* ((lnum (string-to-number (match-string 1)))
                                      (type (if (equal (match-string 2) "Error")
                                                :error :warning))
                                      (msg  (match-string 3))
                                      (reg  (flymake-diag-region source lnum)))
                                 (push (flymake-make-diagnostic
                                        source (car reg) (cdr reg) type msg)
                                       diags)))
                             ;; Prefix-less warnings (no file:line), pinned to line 1.
                             (goto-char (point-min))
                             (while (re-search-forward
                                     "^Warning: \\(.*\\)" nil t)
                               (let* ((msg (match-string 1))
                                      (reg (flymake-diag-region source 1)))
                                 (push (flymake-make-diagnostic
                                        source (car reg) (cdr reg) :warning msg)
                                       diags)))
                             (funcall report-fn (nreverse diags))))
                       (flymake-log :debug "Canceling obsolete check %s" proc))
                   (kill-buffer (process-buffer proc))))))))))

;;; tj3man

(defvar taskjuggler--tj3man-keywords nil
  "Cached list of keywords returned by `tj3man' with no arguments.
Populated the first time `taskjuggler-mode' starts with a working tj3man.")

(defun taskjuggler--populate-tj3man-keywords ()
  "Populate `taskjuggler--tj3man-keywords' by calling tj3man with no arguments.
Does nothing if the cache is already filled or tj3man cannot be found.
Only lines that look like TJ3 identifiers (lowercase, may contain
dots and hyphens) are kept; the copyright header is discarded."
  (unless taskjuggler--tj3man-keywords
    (let ((tj3man (taskjuggler--tj3-executable "tj3man")))
      (when (executable-find tj3man)
        (setq taskjuggler--tj3man-keywords
              (seq-filter
               (lambda (s) (string-match-p "\\`[a-z][a-z0-9._-]*\\'" s))
               (split-string (shell-command-to-string tj3man) "\n" t)))))))

(defun taskjuggler--make-tj3man-button (start end keyword)
  "Make a button from START to END that opens the tj3man page for KEYWORD."
  (make-text-button start end
                    'action (let ((kw keyword))
                              (lambda (_btn) (taskjuggler-man kw)))
                    'follow-link t
                    'help-echo (format "tj3man %s" keyword)
                    'face 'button))

(defun taskjuggler--fontify-tj3man-headers ()
  "Apply Man-overstrike to the six section-header labels in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward
            "^\\(Keyword\\|Purpose\\|Syntax\\|Arguments\\|Context\\|Attributes\\):"
            nil t)
      (put-text-property (match-beginning 0) (match-end 0)
                         'face 'Man-overstrike))))

(defun taskjuggler--fontify-tj3man-syntax ()
  "Apply Man-underline to <argument> placeholders in the Syntax: section.
Covers multi-line Syntax blocks up to the first blank line."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^Syntax:" nil t)
      (let ((section-end (save-excursion
                           (if (re-search-forward "^$" nil t)
                               (match-beginning 0)
                             (point-max)))))
        (while (re-search-forward "<[^>]+>" section-end t)
          (put-text-property (match-beginning 0) (match-end 0)
                             'face 'Man-underline))))))

(defun taskjuggler--fontify-tj3man-arguments (tag-width)
  "Apply faces to argument entries in the Arguments: section.
TAG-WIDTH is the column at which argument entries start (matches tagW
in KeywordDocumentation.rb).  Argument names receive Man-overstrike;
type specs in [BRACKETS] receive Man-underline.  Continuation lines
indented by TAG-WIDTH spaces are intentionally skipped."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^Arguments:" nil t)
      (beginning-of-line)
      (let ((section-end
             (save-excursion
               (if (re-search-forward
                    "^\\(Keyword\\|Purpose\\|Syntax\\|Context\\|Attributes\\):"
                    nil t)
                   (match-beginning 0)
                 (point-max)))))
        (while (re-search-forward
                (concat "^\\(?:Arguments:[ \t]+\\|"
                        (make-string tag-width ?\s)
                        "\\)"
                        "\\([a-zA-Z][a-zA-Z0-9._-]*"
                        "\\(?:[ \t][a-zA-Z][a-zA-Z0-9._-]*\\)*\\)"
                        "\\(?:[ \t]+\\[\\([A-Z][A-Z0-9]*\\)\\]\\)?[ \t]*:")
                section-end t)
          (put-text-property (match-beginning 1) (match-end 1)
                             'face 'Man-overstrike)
          (when (match-beginning 2)
            (put-text-property (match-beginning 2) (match-end 2)
                               'face 'Man-underline)))))))

(defun taskjuggler--fontify-tj3man-attributes ()
  "Linkify attribute names and underline modifier keys in the Attributes: section.
Each attribute name becomes a button; colon-separated keys inside [...]
tags (e.g. sc, ip) receive Man-underline.  The modifier-key pass extends
past the blank line to cover the legend at the end of the buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^Attributes:" nil t)
      (let ((attrs-end (save-excursion
                         (if (re-search-forward "^$" nil t)
                             (match-beginning 0)
                           (point-max)))))
        ;; Button on each attribute name only (not the modifier tags).
        (save-excursion
          (while (re-search-forward
                  "\\([a-z][a-z0-9._-]*\\)\\(\\(?:\\[[^]]*\\]\\)*\\)"
                  attrs-end t)
            (taskjuggler--make-tj3man-button
             (match-beginning 1) (match-end 1)
             (match-string-no-properties 1))))
        ;; Underline modifier keys to end of buffer (includes legend).
        (while (re-search-forward "\\[[a-z][a-z0-9:]*\\]" nil t)
          (let ((b-start (match-beginning 0))
                (b-end   (match-end 0)))
            (save-excursion
              (goto-char (1+ b-start))
              (while (re-search-forward "[a-z]+" (1- b-end) t)
                (put-text-property (match-beginning 0) (match-end 0)
                                   'face 'Man-underline)))))))))

(defun taskjuggler--fontify-tj3man-links ()
  "Linkify known tj3man keywords throughout the buffer as clickable buttons.
Skips positions already styled with buttons, Man-overstrike, or
Man-underline, and skips the documented keyword on the Keyword: and
Syntax: lines."
  (when taskjuggler--tj3man-keywords
    (let ((kw-table (make-hash-table :test 'equal)))
      (dolist (kw taskjuggler--tj3man-keywords)
        (puthash kw t kw-table))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "[a-z][a-z0-9._-]*" nil t)
          (let ((start (match-beginning 0))
                (end   (match-end 0))
                (word  (match-string-no-properties 0)))
            (when (and (gethash word kw-table)
                       (not (get-text-property start 'button))
                       (not (memq (get-text-property start 'face)
                                  '(Man-overstrike Man-underline)))
                       (not (save-excursion
                              (goto-char start)
                              (beginning-of-line)
                              (or (looking-at "Keyword:")
                                  (and (looking-at "Syntax:[ \t]+")
                                       (= (match-end 0) start))))))
              (taskjuggler--make-tj3man-button start end word))))))))

(defun taskjuggler--fontify-tj3man ()
  "Apply man-style faces and buttons to the current *tj3man* buffer."
  (let* ((inhibit-read-only t)
         ;; Detect the tag column width from the Keyword: line.  This matches
         ;; tagW in KeywordDocumentation.rb (currently 13) and controls how
         ;; far argument continuation lines are indented.
         (tag-width (save-excursion
                      (goto-char (point-min))
                      (if (re-search-forward "^Keyword:[ \t]+" nil t)
                          (current-column)
                        13))))
    (taskjuggler--fontify-tj3man-headers)
    (taskjuggler--fontify-tj3man-syntax)
    (taskjuggler--fontify-tj3man-arguments tag-width)
    (taskjuggler--fontify-tj3man-attributes)
    (taskjuggler--fontify-tj3man-links)))

(defun taskjuggler-man (keyword)
  "Show tj3man documentation for KEYWORD in a help window.
Prompts with completion over the keywords listed by `tj3man',
defaulting to the word at point."
  (interactive
   (let* ((tj3man (taskjuggler--tj3-executable "tj3man"))
          (_ (unless (executable-find tj3man)
               (user-error "Cannot find tj3man executable: %s" tj3man)))
          (default (thing-at-point 'word t))
          (prompt  (if default
                       (format "tj3man keyword (default %s): " default)
                     "tj3man keyword: ")))
     (list (completing-read prompt taskjuggler--tj3man-keywords
                            nil nil nil nil default))))
  (let ((tj3man (taskjuggler--tj3-executable "tj3man")))
    (with-help-window "*tj3man*"
      (princ (shell-command-to-string
              (concat tj3man " " (shell-quote-argument keyword))))
      (with-current-buffer standard-output
        (taskjuggler--fontify-tj3man)))))

;;; Cursor tracking (task-at-point → tj3webd / js fallback)

;; When a TJP buffer is live, an idle timer periodically identifies the
;; innermost `task' block enclosing point and sends its full dotted ID to
;; the browser for two-way task highlighting.
;;
;; Transport priority:
;;   1. tj3webd cursor API (POST /cursor, GET /cursor/state) — used when
;;      tj3webd is running and the /cursor endpoint is reachable.
;;   2. js/tj-cursor.js file — written to the js/ subdirectory next to the
;;      TJP file when js/ exists (file:// polling fallback).
;;   3. Neither available — cursor tracking is silently disabled.

;; ---- Variables ----

;; TODO: the timer refs below should be `permanent-local'.
;; `kill-all-local-variables' runs on mode re-activation (M-x
;; taskjuggler-mode by hand, some revert paths, and — observed in
;; practice — the mode getting activated in transient buffers like
;; *company-documentation*).  It wipes these refs BEFORE
;; `taskjuggler--start-cursor-tracking' gets a chance to cancel the
;; prior timers, so the old timers stay scheduled forever against the
;; old buffer.  Checking `list-timers' on a long-lived session shows
;; stacks of them.  They are harmless (the handler checks
;; `buffer-live-p') but accumulate.  Proper fix: mark both refs
;; permanent-local and add a `change-major-mode-hook' entry that calls
;; `taskjuggler--stop-cursor-tracking' before kill-all-local-variables
;; can clear them.

(defvar-local taskjuggler--cursor-idle-timer nil
  "Idle timer that updates cursor position while this buffer is live.")

(defvar-local taskjuggler--click-poll-timer nil
  "Repeating timer that polls for browser clicks regardless of focus.")

(defvar-local taskjuggler--cursor-last-id :unset
  "Last task ID sent/written; :unset before the first update.")

(defvar-local taskjuggler--cursor-last-click-ts 0
  "Last click timestamp acted upon; prevents re-navigating the same click.")

(defvar-local taskjuggler--cursor-api-url nil
  "Base URL for the tj3webd cursor API (e.g. \"http://127.0.0.1:8080\"), or nil.
Non-nil means the /cursor endpoint was reachable when tracking started.")

(defvar-local taskjuggler--cursor-js-file-cache :unset
  "Cached path to js/tj-cursor.js (file:// polling fallback), or nil.
:unset before the first lookup.")

;; ---- Task ID helpers ----

(defun taskjuggler--block-header-task-id (header-pos)
  "If the line at HEADER-POS is a `task' declaration, return its ID string.
Returns nil for any other keyword (resource, project, macro, etc.)."
  (save-excursion
    (goto-char header-pos)
    (when (looking-at "[ \t]*task[ \t]+\\([[:alnum:]_][[:alnum:]_-]*\\)")
      (match-string-no-properties 1))))

(defun taskjuggler--full-task-id-at-point ()
  "Return the full dotted TaskJuggler task ID enclosing point, or nil.
Walks up the brace-nesting hierarchy from the innermost block at point,
collecting the IDs of every ancestor `task' block, and joins them with `.'.
Returns nil when point is not inside any `task' block."
  (save-excursion
    (when-let ((header (taskjuggler--current-block-header)))
      (goto-char header)
      (let (ids parent-open)
        ;; Prefer (nth 1 (syntax-ppss)) over up-list: scan-lists can land
        ;; on a sibling's { when scanning backward past balanced pairs.
        (while (progn
                 (when-let ((id (taskjuggler--block-header-task-id (point))))
                   (push id ids))
                 (setq parent-open (nth 1 (syntax-ppss))))
          (goto-char parent-open)
          (beginning-of-line))
        (when ids
          (mapconcat #'identity ids "."))))))

(defun taskjuggler--goto-task-id (dotted-id)
  "Move point to the `task' declaration for DOTTED-ID.
Searches for lines beginning with `task <leaf-id>' and verifies the full
dotted hierarchy via `taskjuggler--full-task-id-at-point'.  Returns t on
success, nil when no matching declaration is found."
  (let* ((leaf (car (last (split-string dotted-id "\\."))))
         (re (concat "^[ \t]*task[ \t]+" (regexp-quote leaf) "\\b"))
         target)
    (save-excursion
      (goto-char (point-min))
      (while (and (not target)
                  (re-search-forward re nil t))
        (let ((candidate (line-beginning-position)))
          (when (equal (save-excursion
                         (goto-char candidate)
                         (taskjuggler--full-task-id-at-point))
                       dotted-id)
            (setq target candidate)))))
    (when target
      (goto-char target)
      t)))

;; ---- API transport (tj3webd /cursor endpoint) ----

;; TODO: the functions below use `url-retrieve-synchronously' inside
;; the 0.3s repeating click-poll timer.  That opens a recursive event
;; loop from a timer handler, which is fragile.  Observed failure: the
;; live `.tji' poll timer's next-fire-time stopped advancing (showed as
;; ~47 hours overdue in `list-timers') while other timers in the same
;; Emacs kept firing normally, and sync stayed dead until
;; `taskjuggler--stop-cursor-tracking' + `--start-cursor-tracking'
;; replaced the timer.  Orphan poll timers for *company-documentation*
;; showed the same overdue pattern in BOTH broken and working sessions,
;; so the orphans are not the cause — single-timer wedging of the live
;; timer is.  Suspected triggers: C-g during the 2s timeout, or
;; re-entrance when Emacs is busy (save + flymake + company +
;; fontification stacking up).  Proper fix: convert
;; `taskjuggler--cursor-poll-api' and `taskjuggler--cursor-post-api' to
;; async `url-retrieve' with callbacks so no recursive event loop runs
;; from the timer handler.  (`taskjuggler--cursor-api-probe' runs
;; once at mode init, not from a timer, so it's fine.)

(defun taskjuggler--cursor-api-probe ()
  "Probe whether the tj3webd cursor API is reachable.
Returns the base URL string (e.g. \"http://127.0.0.1:8080\") on success,
or nil when the endpoint is not available."
  (let ((url (format "http://127.0.0.1:%d/cursor/state"
                     taskjuggler-tj3webd-port)))
    (condition-case nil
        (let ((url-request-method "GET")
              (url-show-status nil))
          (with-current-buffer (url-retrieve-synchronously url t nil 2)
            (unwind-protect
                (progn
                  (goto-char (point-min))
                  (when (re-search-forward "^HTTP/[0-9.]+ 200" nil t)
                    (format "http://127.0.0.1:%d" taskjuggler-tj3webd-port)))
              (kill-buffer))))
      (error nil))))

(defun taskjuggler--cursor-post-api (task-id)
  "POST TASK-ID to the tj3webd /cursor endpoint.
TASK-ID may be a string or nil (clears the cursor).
Returns non-nil on success."
  (when taskjuggler--cursor-api-url
    (let ((url (concat taskjuggler--cursor-api-url "/cursor"))
          (url-request-method "POST")
          (url-request-extra-headers '(("Content-Type" . "application/json")))
          (url-request-data
           (encode-coding-string
            (json-encode `(("id" . ,(or task-id ""))
                           ("source" . "editor")))
            'utf-8))
          (url-show-status nil))
      (condition-case nil
          (let ((buf (url-retrieve-synchronously url t nil 2)))
            (when buf (kill-buffer buf))
            t)
        (error nil)))))

(defun taskjuggler--cursor-poll-api ()
  "Poll GET /cursor/state and return (ID . TS) when source is \"browser\".
Returns nil on error or when the last event was from the editor."
  (when taskjuggler--cursor-api-url
    (let ((url (concat taskjuggler--cursor-api-url "/cursor/state"))
          (url-request-method "GET")
          (url-show-status nil))
      (condition-case nil
          (with-current-buffer (url-retrieve-synchronously url t nil 2)
            (unwind-protect
                (progn
                  (goto-char (point-min))
                  (when (re-search-forward "\n\n" nil t)
                    (let* ((data (json-read))
                           (source (cdr (assq 'source data))))
                      (when (equal source "browser")
                        (cons (cdr (assq 'id data))
                              (cdr (assq 'ts data)))))))
              (kill-buffer)))
        (error nil)))))

;; ---- File transport (js/tj-cursor.js fallback) ----

(defun taskjuggler--cursor-js-file ()
  "Return the path to js/tj-cursor.js, or nil when js/ does not exist.
Used as the file-based fallback when the cursor API is unavailable."
  (if (not (eq taskjuggler--cursor-js-file-cache :unset))
      taskjuggler--cursor-js-file-cache
    (setq taskjuggler--cursor-js-file-cache
          (when-let ((file (buffer-file-name)))
            (let ((js-dir (expand-file-name "js" (file-name-directory file))))
              (when (file-directory-p js-dir)
                (expand-file-name "tj-cursor.js" js-dir)))))))

(defun taskjuggler--read-file-string (file)
  "Return the contents of FILE as a string, or \"\" on any error."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    (error "")))

(defun taskjuggler--cursor-parse-field (content name)
  "Return the value assigned to window.NAME in tj-cursor.js CONTENT.
Handles quoted string values and bare integer values.  Returns a string
in both cases, or nil when NAME is not present in CONTENT."
  (cond
   ((string-match (concat "window\\." (regexp-quote name)
                          "\\s-*=\\s-*\"\\([^\"]*\\)\"")
                  content)
    (match-string 1 content))
   ((string-match (concat "window\\." (regexp-quote name)
                          "\\s-*=\\s-*\\([0-9]+\\)")
                  content)
    (match-string 1 content))
   (t nil)))

(defun taskjuggler--write-cursor-js (task-id)
  "Write TASK-ID to js/tj-cursor.js as file-based fallback.
Does nothing when js/ does not exist."
  (when-let ((js-file (taskjuggler--cursor-js-file)))
    (let* ((cursor-ts (number-to-string (floor (float-time))))
           (cursor-id-js (if task-id (concat "\"" task-id "\"") "null"))
           (click-id-js "null")
           (click-ts "0"))
      (when task-id
        (let ((existing (taskjuggler--read-file-string js-file)))
          (when-let ((id (taskjuggler--cursor-parse-field existing "_tjClickTaskId")))
            (setq click-id-js (concat "\"" id "\"")))
          (when-let ((ts (taskjuggler--cursor-parse-field existing "_tjClickTs")))
            (setq click-ts ts))))
      (let ((content (concat "window._tjCursorTaskId = " cursor-id-js ";\n"
                             "window._tjCursorTs     = " cursor-ts ";\n"
                             "window._tjClickTaskId  = " click-id-js ";\n"
                             "window._tjClickTs      = " click-ts ";\n")))
        (write-region content nil js-file nil 'quiet)))))

;; ---- Dispatchers ----

(defun taskjuggler--write-cursor-json (task-id)
  "Send TASK-ID to the cursor API, or write js/tj-cursor.js as fallback.
When `taskjuggler--cursor-api-url' is set, POSTs to /cursor.
Otherwise writes to js/tj-cursor.js if the js/ directory exists.
Does nothing when neither method is available."
  (if taskjuggler--cursor-api-url
      (taskjuggler--cursor-post-api task-id)
    (taskjuggler--write-cursor-js task-id)))

(defun taskjuggler--maybe-navigate-to-click ()
  "Navigate to a task clicked in the browser, if the click is new.
Uses the cursor API when available, otherwise reads js/tj-cursor.js."
  (let (click-id click-ts)
    (if taskjuggler--cursor-api-url
        ;; API path: poll /cursor/state, only act on browser-sourced events.
        (when-let ((result (taskjuggler--cursor-poll-api)))
          (setq click-id (car result)
                click-ts (cdr result)))
      ;; File fallback: read js/tj-cursor.js.
      (when-let ((js-file (taskjuggler--cursor-js-file)))
        (let* ((content (taskjuggler--read-file-string js-file))
               (ts-str (taskjuggler--cursor-parse-field content "_tjClickTs")))
          (setq click-ts (if ts-str (string-to-number ts-str) 0)
                click-id (taskjuggler--cursor-parse-field
                          content "_tjClickTaskId")))))
    (when (and click-ts (> click-ts taskjuggler--cursor-last-click-ts))
      (setq taskjuggler--cursor-last-click-ts click-ts)
      (when (and click-id (not (string-empty-p click-id)))
        (when (taskjuggler--goto-task-id click-id)
          (when-let ((win (get-buffer-window (current-buffer) t)))
            (with-selected-window win (recenter))))))))

;; ---- Lifecycle ----

(defun taskjuggler--start-cursor-tracking ()
  "Start cursor tracking for the current buffer.
Probes the tj3webd cursor API; if reachable, uses HTTP for both
directions.  Otherwise falls back to js/tj-cursor.js (if the js/
directory exists).  When neither is available, cursor tracking is
silently skipped.

Uses an idle timer for the editor→browser cursor write (so we only write
when the user stops moving) and a regular repeating timer for the
browser→editor click poll (so clicks are noticed even when Emacs does not
have input focus).  Does nothing when `taskjuggler-cursor-idle-delay' is nil."
  (when taskjuggler-cursor-idle-delay
    ;; Cancel any existing timers first so re-initialization (e.g. via
    ;; revert-buffer or M-x taskjuggler-mode) does not orphan them.
    (when (timerp taskjuggler--cursor-idle-timer)
      (cancel-timer taskjuggler--cursor-idle-timer))
    (when (timerp taskjuggler--click-poll-timer)
      (cancel-timer taskjuggler--click-poll-timer))
    ;; Decide transport: API first, then js/ file, then nothing.
    (setq taskjuggler--cursor-api-url (taskjuggler--cursor-api-probe))
    (when (or taskjuggler--cursor-api-url (taskjuggler--cursor-js-file))
      (let ((buf (current-buffer)))
        ;; Editor → Browser: idle timer writes cursor position on quiescence.
        (setq taskjuggler--cursor-idle-timer
              (run-with-idle-timer
               taskjuggler-cursor-idle-delay t
               (lambda ()
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (let ((id (taskjuggler--full-task-id-at-point)))
                       (unless (equal id taskjuggler--cursor-last-id)
                         (setq taskjuggler--cursor-last-id id)
                         (taskjuggler--write-cursor-json id))))))))
        ;; Browser → Editor: repeating timer polls for clicks even when
        ;; Emacs is not focused.
        (setq taskjuggler--click-poll-timer
              (run-with-timer
               taskjuggler-cursor-idle-delay taskjuggler-cursor-idle-delay
               (lambda ()
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (taskjuggler--maybe-navigate-to-click))))))))))

(defun taskjuggler--stop-cursor-tracking ()
  "Cancel cursor-tracking timers and clear cursor state."
  (when (timerp taskjuggler--cursor-idle-timer)
    (cancel-timer taskjuggler--cursor-idle-timer)
    (setq taskjuggler--cursor-idle-timer nil))
  (when (timerp taskjuggler--click-poll-timer)
    (cancel-timer taskjuggler--click-poll-timer)
    (setq taskjuggler--click-poll-timer nil))
  (taskjuggler--write-cursor-json nil)
  (setq taskjuggler--cursor-api-url nil))

(defun taskjuggler--reset-cursor-file-cache (&rest _)
  "Reset the cursor file cache in all live `taskjuggler-mode' buffers.
Added to `compilation-finish-functions' so the js/ directory is
re-checked after a compile run that may have created it.
Also re-probes the cursor API, which may have become available
after a compile that started tj3webd."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'taskjuggler-mode)
          (setq taskjuggler--cursor-js-file-cache :unset)
          (unless taskjuggler--cursor-api-url
            (setq taskjuggler--cursor-api-url
                  (taskjuggler--cursor-api-probe))))))))

;;; Daemon management (tj3d / tj3webd)

;; tj3d is the TaskJuggler scheduling daemon.  Once started, projects can be
;; added to it with `tj3client' and it will re-schedule on file changes.
;; tj3webd is a companion web server that serves reports from tj3d.  Both
;; daemons fork into the background (the launcher process exits immediately),
;; so liveness is checked via `tj3client status' / TCP probe rather than
;; process objects.

(defvar taskjuggler--daemon-status-timer nil
  "Timer that polls daemon status for modeline updates.")

(defvar taskjuggler--daemon-modeline ""
  "Current modeline string for daemon status.
Updated by `taskjuggler--daemon-update-modeline'.")

(defvar taskjuggler--auto-add-pending nil
  "The .tjp file path for which an auto-add is in progress, or nil.")

(defun taskjuggler--tj3d-alive-p ()
  "Return non-nil if the tj3d daemon is reachable.
Probes via `tj3client status'."
  (condition-case nil
      (zerop (call-process (taskjuggler--tj3-executable "tj3client")
                           nil nil nil "status"))
    (error nil)))

(defun taskjuggler--tj3d-accepting-p ()
  "Return non-nil if tj3d is accepting connections.
Unlike `taskjuggler--tj3d-alive-p', this always probes via
`tj3client status' rather than relying on the process object."
  (condition-case nil
      (zerop (call-process (taskjuggler--tj3-executable "tj3client")
                           nil nil nil "status"))
    (error nil)))

(defun taskjuggler--tj3webd-alive-p ()
  "Return non-nil if tj3webd is running.
Probes the port via TCP."
  (condition-case nil
      (let ((proc (make-network-process
                   :name "tj3webd-probe"
                   :host "127.0.0.1"
                   :service taskjuggler-tj3webd-port
                   :nowait nil)))
        (delete-process proc)
        t)
    (error nil)))

(defun taskjuggler--find-tjp-file ()
  "Return the .tjp file for the current buffer.
If visiting a .tjp file, return it directly.  If visiting a .tji file,
search `default-directory' for a .tjp file.  Returns nil if none found."
  (let ((file (buffer-file-name)))
    (cond
     ((and file (string-suffix-p ".tjp" file)) file)
     ((and file (string-suffix-p ".tji" file))
      (car (directory-files default-directory t "\\.tjp\\'" t)))
     (t nil))))

(defun taskjuggler-tj3d-start ()
  "Start the tj3d daemon from the current project directory.
The daemon forks into the background automatically.
Respects `taskjuggler-tj3-bin-dir' for executable resolution."
  (interactive)
  (if (taskjuggler--tj3d-alive-p)
      (message "tj3d is already running")
    (let* ((tjp (taskjuggler--find-tjp-file))
           (default-directory (if tjp (file-name-directory tjp)
                                default-directory))
           (cmd (taskjuggler--tj3-executable "tj3d")))
      (call-process cmd nil nil nil "--auto-update")
      (taskjuggler--daemon-ensure-status-timer)
      (taskjuggler--daemon-update-modeline)
      (message "tj3d started"))))

(defun taskjuggler-tj3d-add-project ()
  "Add the current project to the running tj3d daemon.
Uses `tj3client add' with the .tjp file for the current buffer."
  (interactive)
  (unless (taskjuggler--tj3d-alive-p)
    (user-error "Process tj3d is not running; start it with `taskjuggler-tj3d-start'"))
  (let ((tjp (taskjuggler--find-tjp-file)))
    (unless tjp
      (user-error "No .tjp file found for the current buffer"))
    (let ((cmd (taskjuggler--tj3-executable "tj3client")))
      (message "Adding %s to tj3d..." (file-name-nondirectory tjp))
      (make-process
       :name "tj3client-add"
       :buffer (get-buffer-create "*tj3client*")
       :command (list cmd "add" tjp)
       :noquery t
       :sentinel (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (if (zerop (process-exit-status proc))
                         (message "Project added to tj3d: %s"
                                  (file-name-nondirectory tjp))
                       (message "tj3client add failed (exit %d); see *tj3client*"
                                (process-exit-status proc)))))))))

(defun taskjuggler--tj3d-project-loaded-p (tjp)
  "Return non-nil if TJP is already loaded in the running tj3d daemon."
  (when (and tjp (taskjuggler--tj3d-alive-p))
    (condition-case nil
        (with-temp-buffer
          (when (zerop (call-process
                        (taskjuggler--tj3-executable "tj3client")
                        nil t nil "status"))
            (goto-char (point-min))
            (search-forward (file-name-nondirectory tjp) nil t)))
      (error nil))))

(defun taskjuggler--auto-add-project-tj3d ()
  "Add the current project to tj3d if not already loaded.
When tj3d is accepting connections and the project is not yet loaded,
adds it immediately.  When tj3d is not yet ready (e.g. just started),
retries up to 5 times at 1-second intervals.
Guards against duplicate attempts via `taskjuggler--auto-add-pending'."
  (let ((tjp (taskjuggler--find-tjp-file)))
    (when (and tjp
               (not (equal tjp taskjuggler--auto-add-pending))
               (not (taskjuggler--tj3d-project-loaded-p tjp)))
      (setq taskjuggler--auto-add-pending tjp)
      (if (taskjuggler--tj3d-accepting-p)
          (progn
            (taskjuggler-tj3d-add-project)
            (setq taskjuggler--auto-add-pending nil))
        ;; tj3d was just started; poll until accepting connections.
        (let ((retries 0)
              (timer nil))
          (setq timer
                (run-with-timer
                 1 1
                 (lambda ()
                   (setq retries (1+ retries))
                   (cond
                    ((taskjuggler--tj3d-project-loaded-p tjp)
                     (cancel-timer timer)
                     (setq taskjuggler--auto-add-pending nil))
                    ((taskjuggler--tj3d-accepting-p)
                     (cancel-timer timer)
                     (taskjuggler-tj3d-add-project)
                     (setq taskjuggler--auto-add-pending nil))
                    ((>= retries 5)
                     (cancel-timer timer)
                     (setq taskjuggler--auto-add-pending nil)
                     (message "tj3d not ready after %d attempts; \
skipping auto-add for %s" retries (file-name-nondirectory tjp))))))))))))

(defun taskjuggler-tj3webd-start ()
  "Start the tj3webd web daemon from the current project directory.
The daemon forks into the background automatically.
Uses `taskjuggler-tj3webd-port' for the port number."
  (interactive)
  (if (taskjuggler--tj3webd-alive-p)
      (message "tj3webd is already running on port %d"
               taskjuggler-tj3webd-port)
    (let* ((tjp (taskjuggler--find-tjp-file))
           (default-directory (if tjp (file-name-directory tjp)
                                 default-directory))
           (cmd (taskjuggler--tj3-executable "tj3webd")))
      (call-process cmd nil nil nil
                    "--webserver-port"
                    (number-to-string taskjuggler-tj3webd-port))
      (taskjuggler--daemon-ensure-status-timer)
      (taskjuggler--daemon-update-modeline)
      (message "tj3webd started on port %d" taskjuggler-tj3webd-port)
      ;; Re-probe the cursor API once the server has had time to bind.
      (run-with-timer
       2 nil
       (lambda ()
         (dolist (buf (buffer-list))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (when (and (derived-mode-p 'taskjuggler-mode)
                          (not taskjuggler--cursor-api-url))
                 (setq taskjuggler--cursor-api-url
                       (taskjuggler--cursor-api-probe))
                 (when (and taskjuggler--cursor-api-url
                            (not taskjuggler--cursor-idle-timer))
                   (taskjuggler--start-cursor-tracking)))))))))))


(defun taskjuggler-daemon-status ()
  "Display `tj3client status' output in a popup buffer."
  (interactive)
  (let ((cmd (taskjuggler--tj3-executable "tj3client"))
        (buf (get-buffer-create "*tj3client status*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (make-process
     :name "tj3client-status"
     :buffer buf
     :command (list cmd "status")
     :noquery t
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (with-current-buffer (process-buffer proc)
                     (special-mode))
                   (display-buffer (process-buffer proc)))))))

(defun taskjuggler-tj3webd-browse ()
  "Open the tj3webd URL in the default browser."
  (interactive)
  (unless (taskjuggler--tj3webd-alive-p)
    (user-error "Process tj3webd is not running"))
  (browse-url (format "http://localhost:%d/taskjuggler" taskjuggler-tj3webd-port)))

(defun taskjuggler--stop-daemons ()
  "Stop tj3d and tj3webd if they are running.
Registered on `kill-emacs-hook' so daemons do not outlive the Emacs session."
  ;; tj3d: use the official tj3client quit command.
  (condition-case nil
      (when (taskjuggler--tj3d-alive-p)
        (call-process (taskjuggler--tj3-executable "tj3client")
                      nil nil nil "terminate"))
    (error nil))
  ;; tj3webd: no quit command; find the listening process by port and
  ;; send SIGTERM.  -sTCP:LISTEN restricts to the server socket so we
  ;; never signal connected clients (Firefox, Emacs, etc.).
  (condition-case nil
      (when (taskjuggler--tj3webd-alive-p)
        (let ((pids (split-string
                     (string-trim
                      (shell-command-to-string
                       (format "lsof -ti tcp:%d -sTCP:LISTEN 2>/dev/null"
                               taskjuggler-tj3webd-port)))
                     "\n" t)))
          (dolist (pid pids)
            (signal-process (string-to-number pid) 'SIGTERM))))
    (error nil)))

(defun taskjuggler--daemon-update-modeline ()
  "Recompute `taskjuggler--daemon-modeline' from current daemon state."
  (let ((d (taskjuggler--tj3d-alive-p))
        (w (taskjuggler--tj3webd-alive-p)))
    (setq taskjuggler--daemon-modeline
          (cond
           ((and d w)
            (propertize "󰙬󰒍" 'face 'success))
           (d
            (propertize "󰙬" 'face 'success))
           (w
            (propertize "󰒍" 'face 'warning))
           (t "")))
    (force-mode-line-update t)))

(defun taskjuggler--daemon-ensure-status-timer ()
  "Ensure the daemon status polling timer is running.
Polls every 5 seconds so the modeline stays current even if a daemon
dies outside of Emacs (e.g. killed from a terminal)."
  (unless (and taskjuggler--daemon-status-timer
               (timerp taskjuggler--daemon-status-timer))
    (setq taskjuggler--daemon-status-timer
          (run-with-timer 5 5 #'taskjuggler--daemon-update-modeline))))


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

(defun taskjuggler--setup-evil-keys ()
  "Set up `evil-mode' keybindings for `taskjuggler-mode' if evil is loaded."
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'normal taskjuggler-mode-map
      (kbd "gj") #'taskjuggler-next-block
      (kbd "gk") #'taskjuggler-prev-block
      (kbd "gh") #'taskjuggler-goto-parent
      (kbd "gl") #'taskjuggler-goto-first-child
      (kbd "gL") #'taskjuggler-goto-last-child
      (kbd "]t") #'taskjuggler-forward-block-sexp
      (kbd "[t") #'taskjuggler-backward-block-sexp
      (kbd "]B") #'taskjuggler-forward-block
      (kbd "[B") #'taskjuggler-backward-block
      (kbd "[[") #'beginning-of-defun
      (kbd "]]") #'end-of-defun)))

;;; Mode definition

(defcustom taskjuggler-keymap-prefix (kbd "C-c C-t")
  "Prefix key for variable `taskjuggler-command-map'."
  :group 'taskjuggler
  :type 'key-sequence)

(defvar taskjuggler-command-map
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "d") #'taskjuggler-date-dwim)
    (define-key km (kbd "m") #'taskjuggler-man)
    (define-key km (kbd "n") #'taskjuggler-narrow-to-block)
    (define-key km (kbd "D") #'taskjuggler-tj3d-start)
    (define-key km (kbd "a") #'taskjuggler-tj3d-add-project)
    (define-key km (kbd "W") #'taskjuggler-tj3webd-start)
    (define-key km (kbd "b") #'taskjuggler-tj3webd-browse)
    (define-key km (kbd "s") #'taskjuggler-daemon-status)
    km)
  "Keymap for TaskJuggler commands after `taskjuggler-keymap-prefix'.")
(defalias 'taskjuggler-command-map taskjuggler-command-map)

(defvar taskjuggler-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-<up>")   #'taskjuggler-move-block-up)
    (define-key map (kbd "M-<down>") #'taskjuggler-move-block-down)
    (define-key map (kbd "C-M-n")    #'taskjuggler-next-block)
    (define-key map (kbd "C-M-p")    #'taskjuggler-prev-block)
    (define-key map (kbd "C-M-u")    #'taskjuggler-goto-parent)
    (define-key map (kbd "C-M-d")    #'taskjuggler-goto-first-child)
    (define-key map (kbd "C-M-h")    #'taskjuggler-mark-block)
    (when taskjuggler-keymap-prefix
      (define-key map taskjuggler-keymap-prefix 'taskjuggler-command-map))
    map)
  "Keymap for `taskjuggler-mode'.")

(easy-menu-define taskjuggler-menu taskjuggler-mode-map
  "Menu for `taskjuggler-mode'."
  '("TJ3"
    ["Date DWIM" taskjuggler-date-dwim]
    ["Man Lookup" taskjuggler-man]
    ["Narrow to Block" taskjuggler-narrow-to-block]
    "---"
    ("Block Navigation"
     ["Move Block Up" taskjuggler-move-block-up]
     ["Move Block Down" taskjuggler-move-block-down]
     ["Next Block" taskjuggler-next-block]
     ["Prev Block" taskjuggler-prev-block]
     ["Goto Parent" taskjuggler-goto-parent]
     ["Goto First Child" taskjuggler-goto-first-child]
     ["Mark Block" taskjuggler-mark-block])
    "---"
    ("Daemons"
     ["Start tj3d" taskjuggler-tj3d-start]
     ["Add Project to tj3d" taskjuggler-tj3d-add-project]
     ["Start tj3webd" taskjuggler-tj3webd-start]
     ["Browse tj3webd" taskjuggler-tj3webd-browse]
     ["Daemon Status" taskjuggler-daemon-status])))

(defvar taskjuggler--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'taskjuggler--show-mode-line-menu)
    map)
  "Keymap for the TJ3 modeline indicator.")

(defun taskjuggler--show-mode-line-menu ()
  "Show `taskjuggler-menu' as a popup from the modeline."
  (interactive)
  (popup-menu taskjuggler-menu))

(define-derived-mode taskjuggler-mode prog-mode "TJ3"
  "Major mode for editing TaskJuggler 3 project files (.tjp, .tji).

TaskJuggler is an open-source project management and scheduling tool.
See URL `https://taskjuggler.org' for more information.

\\{taskjuggler-mode-map}"
  :syntax-table taskjuggler-mode-syntax-table
  ;; Font-lock: nil for KEYWORDS-ONLY means strings/comments use syntax table.
  (setq-local font-lock-defaults
              '(taskjuggler-font-lock-keywords nil nil nil nil))
  ;; Comment configuration: default to # for M-; and comment-region.
  ;; All three styles (//, #, /* */) are recognized for navigation.
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(?://+\\|#+\\|/\\*+\\)[ \t]*")
  ;; Syntax propertize handles # as a line comment character.
  (setq-local syntax-propertize-function #'taskjuggler--syntax-propertize)
  ;; Extend the propertize region to cover any enclosing scissors string so
  ;; that -8<- … ->8- fence pairs are always re-propertized as a unit.
  (add-hook 'syntax-propertize-extend-region-functions
            #'taskjuggler--syntax-propertize-extend-region nil t)
  ;; Indentation
  (setq-local indent-line-function #'taskjuggler-indent-line)
  (setq-local indent-region-function #'taskjuggler-indent-region)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width taskjuggler-indent-level)
  ;; Defun navigation: wire up standard C-M-a / C-M-e / C-M-h / narrow-to-defun.
  (setq-local beginning-of-defun-function #'taskjuggler--beginning-of-defun)
  (setq-local end-of-defun-function #'taskjuggler--end-of-defun)
  ;; Sexp movement: treat a full block (keyword + body) as one sexp for C-M-f/b.
  (setq-local forward-sexp-function #'taskjuggler--forward-sexp)
  ;; Compilation: pre-fill compile-command with tj3 and the current file.
  (when (buffer-file-name)
    (setq-local compile-command
                (concat (taskjuggler--tj3-executable "tj3") " "
                        (shell-quote-argument (buffer-file-name)))))
  ;; Auto-launch calendar popup after date-expecting keywords.
  (add-hook 'post-self-insert-hook #'taskjuggler--maybe-launch-calendar nil t)
  ;; Flymake
  (add-hook 'flymake-diagnostic-functions #'taskjuggler-flymake-backend nil t)
  ;; Compilation: register TJ3 error regexp when compile is available.
  (when (featurep 'compile)
    (add-to-list 'compilation-error-regexp-alist-alist
                 taskjuggler--compilation-error-re)
    (add-to-list 'compilation-error-regexp-alist 'taskjuggler))
  ;; tj3man: populate keyword cache on first mode activation.
  (taskjuggler--populate-tj3man-keywords)
  ;; Cursor tracking: sync task-at-point via API or js/ fallback.
  (taskjuggler--start-cursor-tracking)
  (add-hook 'kill-buffer-hook #'taskjuggler--stop-cursor-tracking nil t)
  (add-hook 'compilation-finish-functions #'taskjuggler--reset-cursor-file-cache)
  ;; Daemon modeline: combine "TJ3" label with daemon status in one clickable entry.
  (setq mode-line-process nil)
  (setq mode-name
        `(,(propertize "TJ3"
                       'mouse-face 'mode-line-highlight
                       'help-echo "mouse-1: TaskJuggler menu"
                       'local-map taskjuggler--mode-line-map)
          (:eval taskjuggler--daemon-modeline)))
  ;; Auto-start tj3d and tj3webd if configured.
  (when taskjuggler-auto-start-tj3d-tj3webd
    (unless (taskjuggler--tj3d-alive-p)
      (taskjuggler-tj3d-start))
    (unless (taskjuggler--tj3webd-alive-p)
      (taskjuggler-tj3webd-start)))
  ;; Auto-add project to tj3d if configured.
  (when taskjuggler-auto-add-project-tj3d
    (taskjuggler--auto-add-project-tj3d))
  ;; Shut down daemons when Emacs exits (idempotent; safe to add per buffer).
  (add-hook 'kill-emacs-hook #'taskjuggler--stop-daemons)
  ;; Evil: set up normal-state navigation bindings if evil is loaded.
  (taskjuggler--setup-evil-keys)
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
