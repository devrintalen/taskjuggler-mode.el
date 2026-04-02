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
;;   - Block editing: C-M-h marks block (incl. comments), C-x n b narrows to
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

(defcustom taskjuggler-cursor-idle-delay 0.3
  "Seconds of Emacs idle time before updating the tj-cursor.json sidecar file.
Set to nil to disable cursor tracking entirely."
  :type '(choice (number :tag "Idle delay in seconds")
                 (const :tag "Disabled" nil))
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

;;; Date insertion

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

(defun taskjuggler--tj-date-to-org-time (date-string)
  "Parse TJ3 DATE-STRING into an Emacs encoded time for `org-read-date'.
Handles YYYY-MM-DD and YYYY-MM-DD-HH:MM[:SS] formats."
  ;; Replace the hyphen separating date from time with a space so that
  ;; parse-time-string can handle it: "2024-03-15-10:30" → "2024-03-15 10:30"
  (let* ((normalised (replace-regexp-in-string
                      "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)-\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)"
                      "\\1 \\2"
                      date-string))
         (parsed (parse-time-string normalised)))
    ;; parse-time-string leaves unset fields as nil; fill in zeros for time.
    (when (null (nth 0 parsed)) (setf (nth 0 parsed) 0))
    (when (null (nth 1 parsed)) (setf (nth 1 parsed) 0))
    (when (null (nth 2 parsed)) (setf (nth 2 parsed) 0))
    (apply #'encode-time parsed)))

(defun taskjuggler--org-date-to-tj (date-string with-time)
  "Convert an org DATE-STRING to a TJ3 date literal.
When WITH-TIME is non-nil, replace the space between date and time with `-'."
  (if with-time
      (replace-regexp-in-string " " "-" date-string)
    date-string))

(defun taskjuggler-insert-date (arg)
  "Insert a TaskJuggler date literal at point using the Org date picker.
Without prefix ARG, insert a bare date: YYYY-MM-DD.
With prefix ARG, also prompt for a time and insert YYYY-MM-DD-HH:MM."
  (interactive "P")
  (unless (require 'org nil t)
    (user-error "Date editing requires org, which is not available"))
  (insert (taskjuggler--org-date-to-tj (org-read-date arg) arg)))

(defun taskjuggler-date-dwim (arg)
  "Insert or edit a TaskJuggler date literal depending on context.
If point is on a date literal, edit it via `taskjuggler-edit-date-at-point'.
Otherwise, insert a new date via `taskjuggler-insert-date'.
ARG is passed through to the chosen command."
  (interactive "P")
  (if (taskjuggler--date-bounds-at-point)
      (taskjuggler-edit-date-at-point arg)
    (taskjuggler-insert-date arg)))

(defun taskjuggler-edit-date-at-point (arg)
  "Edit the TJ3 date literal at point using the Org date picker.
The existing date pre-fills the calendar.  Without prefix ARG, replace
with a bare date: YYYY-MM-DD.  With prefix ARG, also prompt for a time
and replace with YYYY-MM-DD-HH:MM."
  (interactive "P")
  (unless (require 'org nil t)
    (user-error "Date editing requires org, which is not available"))
  (let ((bounds (taskjuggler--date-bounds-at-point)))
    (unless bounds
      (user-error "No TaskJuggler date at point"))
    (let* ((old-string (buffer-substring-no-properties (car bounds) (cdr bounds)))
           (default-time (taskjuggler--tj-date-to-org-time old-string))
           (new-string (org-read-date arg nil nil nil default-time)))
      (delete-region (car bounds) (cdr bounds))
      (insert (taskjuggler--org-date-to-tj new-string arg)))))

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

;;; Cursor tracking (task-at-point → tj-cursor.json)

;; When a TJP buffer is live, an idle timer periodically identifies the
;; innermost `task' block enclosing point and writes its full dotted ID to
;; tj-cursor.json in the same directory as the buffer file.  A JavaScript
;; polling loop in the generated HTML report reads this file and highlights
;; the matching row in the Gantt chart.

;; TODO: The output directory is assumed to be the same as the TJP file's
;; directory.  Add a defcustom (or derive from taskreport `outputdir') so
;; the sidecar file can land next to the generated HTML when they differ.

(defvar-local taskjuggler--cursor-idle-timer nil
  "Idle timer that updates tj-cursor.json while this buffer is live.")

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
    (let ((header (taskjuggler--current-block-header))
          (ids '()))
      (when header
        (goto-char header)
        (let (done)
          (while (not done)
            ;; Collect this level's task ID (nil for non-task blocks).
            (let ((id (taskjuggler--block-header-task-id (point))))
              (when id (push id ids)))
            ;; Walk up using (nth 1 (syntax-ppss)), which directly gives the
            ;; buffer position of the enclosing {.  This is more reliable than
            ;; up-list, which uses scan-lists and can land on a preceding
            ;; sibling's { when scanning backward through balanced pairs.
            (let* ((ppss (syntax-ppss))
                   (parent-open (nth 1 ppss)))
              (if parent-open
                  (progn
                    (goto-char parent-open)
                    (beginning-of-line))
                (setq done t))))))
      (when ids
        (mapconcat #'identity ids ".")))))

(defun taskjuggler--cursor-file ()
  "Return the absolute path to the tj-cursor.js sidecar file, or nil.
The file is placed in the js/ subdirectory of the buffer's directory when
js/tjchart.js exists there (indicating that is the HTML report output
location), and directly in the buffer's directory otherwise.
Returns nil when the buffer is not visiting a file."
  (when (buffer-file-name)
    (let* ((dir (file-name-directory (buffer-file-name)))
           (js-dir (expand-file-name "js" dir)))
      (if (file-exists-p (expand-file-name "tjchart.js" js-dir))
          (expand-file-name "tj-cursor.js" js-dir)
        (expand-file-name "tj-cursor.js" dir)))))

(defun taskjuggler--write-cursor-json (task-id)
  "Write TASK-ID (a string or nil) to the tj-cursor.js sidecar file.
Writes a JS assignment setting window._tjCursorTaskId to the quoted ID
string or null.  Uses a .js file so the browser can load it via a script
tag, which works under file:// without CORS restrictions.
Does nothing when the buffer is not visiting a file."
  (let ((file (taskjuggler--cursor-file)))
    (when file
      (let ((js (if task-id
                    (concat "window._tjCursorTaskId=\"" task-id "\";\n")
                  "window._tjCursorTaskId=null;\n")))
        (write-region js nil file nil 'quiet)))))

(defun taskjuggler--cursor-update ()
  "Recompute the task at point and write tj-cursor.json."
  (taskjuggler--write-cursor-json (taskjuggler--full-task-id-at-point)))

(defun taskjuggler--start-cursor-tracking ()
  "Start idle-timer-based task-at-point tracking for the current buffer.
Does nothing when `taskjuggler-cursor-idle-delay' is nil."
  (when taskjuggler-cursor-idle-delay
    (let ((buf (current-buffer)))
      (setq taskjuggler--cursor-idle-timer
            (run-with-idle-timer
             taskjuggler-cursor-idle-delay t
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (taskjuggler--cursor-update)))))))))

(defun taskjuggler--stop-cursor-tracking ()
  "Cancel the cursor-tracking timer and write {\"taskId\":null} to the sidecar file."
  (when (timerp taskjuggler--cursor-idle-timer)
    (cancel-timer taskjuggler--cursor-idle-timer)
    (setq taskjuggler--cursor-idle-timer nil))
  (taskjuggler--write-cursor-json nil))

;;; Mode definition

(defvar taskjuggler-command-map (make-sparse-keymap)
  "Keymap for TaskJuggler commands, bound under prefix \\`C-c C-g'.")
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
  ;; Cursor tracking: write tj-cursor.json while this buffer is live.
  (taskjuggler--start-cursor-tracking)
  (add-hook 'kill-buffer-hook #'taskjuggler--stop-cursor-tracking nil t)
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
