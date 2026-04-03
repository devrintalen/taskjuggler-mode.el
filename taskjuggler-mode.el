;;; taskjuggler-mode.el --- Major mode for TaskJuggler project files -*- lexical-binding: t -*-

;; Copyright (C) 2025 Devrin Talen <devrin@fastmail.com>

;; Author: Devrin Talen
;; Keywords: languages, project-management
;; Version: 0.1.0
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
;;   - tj3man integration: C-c C-m looks up keyword docs with completion
;;   - Defun navigation: C-M-a/C-M-e jump to block start/end
;;   - Block editing: C-M-h marks block (incl.  comments), C-x n b narrows to
;;     block, clone-block duplicates the current block

;;; Code:

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

(defconst taskjuggler--syntax-propertize
  (syntax-propertize-rules
   ;; # starts a style-b (line) comment, closed by newline ("> b").
   ;; "< b": class=comment-start, match=space (none), flag=b (style b).
   ;; syntax-propertize-rules automatically skips strings and comments.
   ("#" (0 "< b"))
   ;; Scissors multi-line strings: -8<- ... ->8-
   ;; Mark the last char of -8<- as a string-fence opener, then search
   ;; forward for ->8- and mark its last char as the matching closer.
   ;; syntax-propertize-rules skips matches inside strings/comments, so
   ;; the opening -8<- only fires outside strings; the closing ->8- is
   ;; inside the string we just opened, so it must be handled here.
   ("-8<\\(-\\)"
    (1 (prog1 (string-to-syntax "|")
         (goto-char (match-end 0))
         (when (re-search-forward "->8\\(-\\)" nil t)
           (put-text-property (match-beginning 1) (match-end 1)
                              'syntax-table (string-to-syntax "|")))))))
  "Syntax propertize rules for `taskjuggler-mode'.
Handles # as a line comment and -8<- … ->8- as string delimiters.")

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
return that opening line's position.  Return nil otherwise."
  (save-excursion
    (beginning-of-line)
    (cond
     ((looking-at taskjuggler--moveable-block-re)
      (point))
     ((> (car (syntax-ppss)) 0)
      (condition-case nil
          (progn
            (up-list -1)           ; jump to the innermost opening {
            (beginning-of-line)
            (when (looking-at taskjuggler--moveable-block-re)
              (point)))
        (error nil)))
     (t nil))))

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
nesting boundaries.  With numeric ARG, repeat that many times.
Bound to \\[taskjuggler-forward-block]."
  (interactive "p")
  (dotimes (_ (or arg 1))
    (end-of-line)
    (if (re-search-forward taskjuggler--moveable-block-re nil t)
        (beginning-of-line)
      (user-error "No next block"))))

(defun taskjuggler-backward-block (&optional arg)
  "Move point to the previous moveable block header at any nesting depth.
Unlike `taskjuggler-prev-block', this is a linear file scan that crosses
nesting boundaries.  With numeric ARG, repeat that many times.
Bound to \\[taskjuggler-backward-block]."
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
        (backward-char)
        (condition-case nil
            (progn
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
  "Move forward by ARG blocks as sexps.
Interactive wrapper around `taskjuggler--forward-sexp' for key binding.
Bound to \\[taskjuggler-forward-block-sexp]."
  (interactive "p")
  (taskjuggler--forward-sexp (or arg 1)))

(defun taskjuggler-backward-block-sexp (&optional arg)
  "Move backward by ARG blocks as sexps.
Interactive wrapper around `taskjuggler--forward-sexp' for key binding.
Bound to \\[taskjuggler-backward-block-sexp]."
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

(defun taskjuggler--cal-days-in-month (year month)
  "Return the number of days in MONTH of YEAR."
  (pcase month
    ((or 1 3 5 7 8 10 12) 31)
    ((or 4 6 9 11) 30)
    (2 (if (taskjuggler--cal-leap-year-p year) 29 28))))

(defun taskjuggler--cal-leap-year-p (year)
  "Return non-nil if YEAR is a leap year."
  (or (and (zerop (% year 4))
           (not (zerop (% year 100))))
      (zerop (% year 400))))

(defun taskjuggler--cal-day-of-week (year month day)
  "Return the DAY of week for YEAR-MONTH-DAY (0=Sunday .. 6=Saturday).
Uses `encode-time' and `decode-time' for correctness.
Argument YEAR 4-digit year.
Argument MONTH 2-digit month."
  (nth 6 (decode-time (encode-time 0 0 12 day month year))))

(defun taskjuggler--cal-clamp-day (year month day)
  "Clamp DAY to the valid range for MONTH of YEAR."
  (min day (taskjuggler--cal-days-in-month year month)))

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
  "Day-of-week header row for the calendar (padded to full width).")

(defconst taskjuggler--cal-width 22
  "Width of the calendar popup in characters.")

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
         (day-hdr taskjuggler--cal-day-header)
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
  "Pad or centre TEXT to `taskjuggler--cal-width'."
  (let* ((len (length text))
         (pad-total (max 0 (- taskjuggler--cal-width len)))
         (pad-left (/ pad-total 2))
         (pad-right (- pad-total pad-left)))
    (concat (make-string pad-left ?\s) text (make-string pad-right ?\s))))

(defun taskjuggler--cal-week-lines (year month selected-day
                                         today-year today-month today-day)
  "Return a list of propertized week-row strings for MONTH of YEAR.
SELECTED-DAY is highlighted.  TODAY-YEAR, TODAY-MONTH, TODAY-DAY
identify today's date for the today face.  Leading and trailing
cells are filled with days from adjacent months."
  (let* ((days-in-month (taskjuggler--cal-days-in-month year month))
         (start-dow (taskjuggler--cal-day-of-week year month 1))
         (cells '()))
    ;; Leading cells from the previous month.
    (when (> start-dow 0)
      (let* ((prev (taskjuggler--cal-adjust-date year month 1 -1 :month))
             (prev-year (nth 0 prev))
             (prev-month (nth 1 prev))
             (prev-dim (taskjuggler--cal-days-in-month prev-year prev-month))
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
    (let ((all-cells (nreverse cells))
          (weeks '())
          (row '()))
      (dolist (cell all-cells)
        (push cell row)
        (when (= (length row) 7)
          (push (taskjuggler--cal-format-week (nreverse row)) weeks)
          (setq row nil)))
      (nreverse weeks))))

(defun taskjuggler--cal-make-cell (day face)
  "Return a propertized 2-character string for DAY with FACE."
  (propertize (format "%2d" day) 'face face))

(defun taskjuggler--cal-format-week (cells)
  "Join a list of 7 propertized day CELLS into a single week-row string.
Each cell is separated by a space with the base calendar face.
The row is padded to `taskjuggler--cal-width'."
  (let* ((pad (propertize " " 'face 'taskjuggler-cal-face))
         (body (mapconcat #'identity cells pad)))
    (concat pad body pad)))

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

(defun taskjuggler--cal-splice-line (old new col)
  "Splice NEW into OLD at column COL, preserving surrounding text.
OLD is the original buffer line, NEW is the calendar row to insert.
Returns the combined string."
  (let* ((old-len (length old))
         (new-len (length new))
         (left (if (<= col old-len)
                   (substring old 0 col)
                 (concat old (make-string (- col old-len) ?\s))))
         (right-start (+ col new-len))
         (right (if (< right-start old-len)
                    (substring old right-start)
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
  "S-arrows: day/week  S-PgUp/Dn: month  Type: YYYY-MM-DD  RET: confirm  C-g: cancel"
  "Help text shown in the echo area during calendar editing.")

(defun taskjuggler--cal-valid-char-at-p (ch pos)
  "Return non-nil if CH is valid at position POS in a YYYY-MM-DD string."
  (if (or (= pos 4) (= pos 7))
      (= ch ?-)
    (<= ?0 ch ?9)))

(defun taskjuggler--cal-apply-faces (date-beg typed-len)
  "Apply typing and pending face overlays to the date string at DATE-BEG.
Characters 0..TYPED-LEN-1 get the typing face; the rest get pending.
Overlays are used so font-lock cannot override them.  Existing overlays
are deleted and recreated on each call to avoid stale positions caused
by intervening buffer modifications.
Argument TYPED-LEN Length of user-typed string."
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
filled with the formatted YEAR-MONTH-DAY date.
Argument YEAR 4-digit year.
Argument MONTH 2-digit month.
Argument DAY 2-digit day."
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
          (setq day (min d (taskjuggler--cal-days-in-month year month))))))
    (list year month (taskjuggler--cal-clamp-day year month day))))

;; --- Main event loop ---

(defun taskjuggler--cal-refresh (date-beg typed-len year month day)
  "Update buffer faces, point, and calendar overlay after a date change.
Argument DATE-BEG Beginning date.
Argument TYPED-LEN Length of user-typed portion of string.
Argument YEAR 4-digit year.
Argument MONTH 2-digit month.
Argument DAY 2-digit day."
  (taskjuggler--cal-update-prefill date-beg typed-len year month day)
  (taskjuggler--cal-apply-faces date-beg typed-len)
  (goto-char (+ date-beg typed-len))
  (taskjuggler--cal-show-overlay year month day))

(defun taskjuggler--cal-classify-event (event)
  "Classify EVENT into an action keyword for the calendar event loop.
Returns one of: `confirm', `cancel', `backspace', a shift-arrow
symbol (S-right etc.), `digit', or nil for unrecognised events."
  (cond
   ;; Confirm: RET / C-m / Enter.
   ((or (eq event 'return) (equal event ?\C-m))
    'confirm)
   ;; Cancel: C-g / Escape.
   ((or (equal event ?\C-g) (eq event 'escape)
        (equal event ?\e))
    'cancel)
   ;; Backspace / DEL — symbol in GUI Emacs, integer in terminal.
   ((or (eq event 'backspace)
        (and (integerp event) (or (= event ?\C-?) (= event ?\C-h))))
    'backspace)
   ;; Shift-arrows and shift-pgup/pgdn.
   ((memq event '(S-right S-left S-down S-up S-next S-prior))
    event)
   ;; Digit or hyphen for date input.
   ((and (integerp event) (or (<= ?0 event ?9) (= event ?-)))
    'digit)
   (t nil)))

(defun taskjuggler--cal-nav-delta (event)
  "Return (DELTA . UNIT) for a shift-arrow EVENT."
  (pcase event
    ('S-right '(1 . :day))
    ('S-left  '(-1 . :day))
    ('S-down  '(1 . :week))
    ('S-up    '(-1 . :week))
    ('S-next  '(1 . :month))
    ('S-prior '(-1 . :month))))

(defun taskjuggler--cal-edit (date-beg year month day was-inserted)
  "Run the calendar editing loop with the date at DATE-BEG.
YEAR, MONTH, DAY are the initial date.  WAS-INSERTED is non-nil if
the date was freshly inserted (should be deleted on cancel).
Point is at DATE-BEG on entry.  Returns non-nil if the date was
committed, nil if cancelled."
  (let ((typed-len 0)
        (orig-date (list year month day))
        (committed nil))
    ;; Cache today once so every render during this session is free.
    (let ((now (decode-time)))
      (setq taskjuggler--cal-today (list (nth 5 now) (nth 4 now) (nth 3 now))))
    ;; Remove overlay on buffer kill so stale overlays never persist.
    (add-hook 'kill-buffer-hook #'taskjuggler--cal-remove-overlay nil t)
    (taskjuggler--cal-apply-faces date-beg typed-len)
    (taskjuggler--cal-show-overlay year month day)
    (unwind-protect
        (catch 'taskjuggler--cal-done
          (while t
            (message "%s" taskjuggler--cal-help-message)
            (let* ((event (read-event))
                   (action (taskjuggler--cal-classify-event event)))
              (pcase action
                ;; --- Confirm ---
                ('confirm
                 (setq committed t)
                 (throw 'taskjuggler--cal-done t))
                ;; --- Cancel ---
                ('cancel
                 (throw 'taskjuggler--cal-done nil))
                ;; --- Backspace while typing ---
                ('backspace
                 (when (> typed-len 0)
                   (setq typed-len (1- typed-len))
                   ;; Re-derive date from remaining typed prefix.
                   (let ((parsed (taskjuggler--cal-parse-typed-prefix
                                  date-beg typed-len orig-date)))
                     (setq year (nth 0 parsed)
                           month (nth 1 parsed)
                           day (nth 2 parsed)))
                   (taskjuggler--cal-refresh date-beg typed-len year month day)))
                ;; --- Navigation: shift-arrows ---
                ((and (pred symbolp)
                      (pred (lambda (a) (taskjuggler--cal-nav-delta a))))
                 (let* ((delta-unit (taskjuggler--cal-nav-delta action))
                        (adjusted (taskjuggler--cal-adjust-date
                                   year month day
                                   (car delta-unit) (cdr delta-unit))))
                   (setq year (nth 0 adjusted)
                         month (nth 1 adjusted)
                         day (nth 2 adjusted))
                   ;; Reset typing state — arrow nav replaces entire date.
                   (setq typed-len 0)
                   (taskjuggler--cal-refresh date-beg typed-len year month day)))
                ;; --- Digit / hyphen input ---
                ('digit
                 (when (and (< typed-len taskjuggler--cal-date-len)
                            (taskjuggler--cal-valid-char-at-p
                             event typed-len))
                   ;; Write the character into the buffer.
                   (save-excursion
                     (goto-char (+ date-beg typed-len))
                     (delete-char 1)
                     (insert (char-to-string event)))
                   (setq typed-len (1+ typed-len))
                   ;; Parse what's been typed and update.
                   (let ((parsed (taskjuggler--cal-parse-typed-prefix
                                  date-beg typed-len orig-date)))
                     (setq year (nth 0 parsed)
                           month (nth 1 parsed)
                           day (nth 2 parsed)))
                   (taskjuggler--cal-refresh date-beg typed-len year month day)))
                ;; --- Unknown key — ignore ---
                (_ nil)))))
      ;; Cleanup.
      (remove-hook 'kill-buffer-hook #'taskjuggler--cal-remove-overlay t)
      (taskjuggler--cal-remove-overlay)
      (setq taskjuggler--cal-column nil
            taskjuggler--cal-today nil)
      (if committed
          ;; Commit: remove editing faces, leave the date text, and
          ;; move point to just after the date.
          (progn
            (taskjuggler--cal-remove-faces date-beg)
            (goto-char (+ date-beg taskjuggler--cal-date-len)))
        ;; Cancel: restore original state.
        (if was-inserted
            ;; Date was freshly inserted — delete it.
            (progn
              (taskjuggler--cal-remove-faces date-beg)
              (delete-region date-beg (+ date-beg taskjuggler--cal-date-len)))
          ;; Date existed — restore the original text.
          (save-excursion
            (goto-char date-beg)
            (delete-char taskjuggler--cal-date-len)
            (insert (apply #'taskjuggler--format-tj-date orig-date)))
          (taskjuggler--cal-remove-faces date-beg))))))

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
If point is on a date literal, edit it via `taskjuggler-edit-date-at-point'.
Otherwise, insert a new date via `taskjuggler-insert-date'."
  (interactive)
  (if (taskjuggler--date-bounds-at-point)
      (taskjuggler-edit-date-at-point)
    (taskjuggler-insert-date)))

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
         (file   (buffer-file-name))
         (fname  (and file (file-name-nondirectory file))))
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
                           (goto-char (point-min))
                           (let (diags)
                             (while (re-search-forward
                                     (concat "^" (regexp-quote fname)
                                             ":\\([0-9]+\\): Error: \\(.*\\)")
                                     nil t)
                               (let* ((lnum (string-to-number (match-string 1)))
                                      (msg  (match-string 2))
                                      (reg  (flymake-diag-region source lnum)))
                                 (push (flymake-make-diagnostic
                                        source (car reg) (cdr reg) :error msg)
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
              (concat tj3man " " (shell-quote-argument keyword)))))))

;;; Mode definition

(defvar taskjuggler-command-map (make-sparse-keymap)
  "Keymap for TaskJuggler commands.")
(define-prefix-command 'taskjuggler-command-prefix 'taskjuggler-command-map)
(define-key taskjuggler-command-map (kbd "d") #'taskjuggler-date-dwim)
(define-key taskjuggler-command-map (kbd "m") #'taskjuggler-man)

;;;###autoload
(defvar taskjuggler-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-<up>")   #'taskjuggler-move-block-up)
    (define-key map (kbd "M-<down>") #'taskjuggler-move-block-down)
    (define-key map (kbd "C-M-n")    #'taskjuggler-next-block)
    (define-key map (kbd "C-M-p")    #'taskjuggler-prev-block)
    (define-key map (kbd "C-M-u")    #'taskjuggler-goto-parent)
    (define-key map (kbd "C-M-d")    #'taskjuggler-goto-first-child)
    (define-key map (kbd "C-M-h")    #'taskjuggler-mark-block)
    (define-key map (kbd "C-x n b")  #'taskjuggler-narrow-to-block)
    (define-key map (kbd "C-c C-g")  'taskjuggler-command-prefix)
    map)
  "Keymap for `taskjuggler-mode'.")

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
  (setq-local syntax-propertize-function taskjuggler--syntax-propertize)
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
  ;; Flymake
  (add-hook 'flymake-diagnostic-functions #'taskjuggler-flymake-backend nil t)
  ;; Compilation: register TJ3 error regexp when compile is available.
  (when (featurep 'compile)
    (add-to-list 'compilation-error-regexp-alist-alist
                 taskjuggler--compilation-error-re)
    (add-to-list 'compilation-error-regexp-alist 'taskjuggler))
  ;; tj3man: populate keyword cache on first mode activation.
  (taskjuggler--populate-tj3man-keywords)
  ;; Evil: set up normal-state navigation bindings if evil is loaded.
  (taskjuggler--setup-evil-keys)
  ;; Yasnippet: register snippet directory if already loaded (the top-level
  ;; `yas-minor-mode-hook' handles the case where yasnippet loads later).
  (when (featurep 'yasnippet)
    (taskjuggler-mode-snippets-initialize)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tjp\\'" . taskjuggler-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tji\\'" . taskjuggler-mode))

(declare-function evil-define-key* "evil-core")

;; Evil-mode navigation bindings (normal state).
;; gj/gk   — next/previous sibling at the same depth (mirrors C-M-n/C-M-p)
;; gh       — parent block (mirrors C-M-u)
;; gl/gL    — first/last direct child block (gl mirrors C-M-d)
;; ]t / [t  — skip forward/backward over one block as a unit (mirrors C-M-f/b)
;; ]B / [B  — forward/backward block (linear, crosses depth boundaries)
;; [[ / ]]  — start / end of current block (defun integration)
;; evil-define-key* (function) is used instead of evil-define-key (macro)
;; so the call survives byte-compilation without evil present.
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

;; Register snippets when yas-minor-mode activates (handles lazy yasnippet loading).
(defvar yas-minor-mode-hook)
(add-hook 'yas-minor-mode-hook #'taskjuggler-mode-snippets-initialize)

(provide 'taskjuggler-mode)
;;; taskjuggler-mode.el ends here
