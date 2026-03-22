;;; taskjuggler-mode.el --- Major mode for TaskJuggler project files -*- lexical-binding: t -*-

;; Keywords: languages, project-management
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (yasnippet "0.14.0"))
;; License: GPL-3.0-or-later

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
;;   - Keyword completion via completion-at-point (works with company-capf)
;;   - Compilation support: compile-command pre-filled with tj3, navigable errors
;;   - Flymake integration: on-the-fly error checking via tj3
;;   - Defun navigation: C-M-a/C-M-e jump to block start/end; C-M-h marks block;
;;     narrow-to-defun narrows to the current block

;;; Code:

(defgroup taskjuggler nil
  "Major mode for editing TaskJuggler project files."
  :group 'languages
  :prefix "taskjuggler-")

(defcustom taskjuggler-indent-level 2
  "Number of spaces per indentation level in TaskJuggler files."
  :type 'integer
  :group 'taskjuggler)

(defcustom taskjuggler-tj3-program "tj3"
  "Name or path of the tj3 executable used by the Flymake backend and compilation.
If tj3 is not on your PATH, set this to the full path, e.g.:
  (setq taskjuggler-tj3-program \"/opt/tj3/bin/tj3\")"
  :type 'string
  :group 'taskjuggler)

(defcustom taskjuggler-tj3-extra-args nil
  "List of additional command-line arguments passed to tj3 by the flymake backend.
Use this to supply flags your project requires, such as:
  (setq-local taskjuggler-tj3-extra-args \\='(\"--prefix\" \"/opt/tj3\"))
The arguments are inserted between the `tj3' executable and the file name."
  :type '(repeat string)
  :safe #'listp
  :group 'taskjuggler)

;;; Faces

(defface taskjuggler-date-face
  '((t :inherit font-lock-string-face))
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
     (2 font-lock-function-name-face))
    ;; Top-level structural keywords
    (,(regexp-opt taskjuggler-top-level-keywords 'words)
     . font-lock-keyword-face)
    ;; Report type keywords
    (,(regexp-opt taskjuggler-report-keywords 'words)
     . font-lock-builtin-face)
    ;; Property keywords
    (,(regexp-opt taskjuggler-property-keywords 'words)
     . font-lock-type-face)
    ;; Value and constant keywords
    (,(regexp-opt taskjuggler-value-keywords 'words)
     . font-lock-constant-face)
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

;;; Syntax propertize (for # line comments)

(defconst taskjuggler--syntax-propertize
  (syntax-propertize-rules
   ;; # starts a style-b (line) comment, closed by newline ("> b").
   ;; "< b": class=comment-start, match=space (none), flag=b (style b).
   ;; syntax-propertize-rules automatically skips strings and comments.
   ("#" (0 "< b")))
  "Syntax propertize rules to handle # as a line comment in `taskjuggler-mode'.")

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
If the header line contains a `{', uses `forward-sexp' to skip to the matching
`}' and returns the line after that.  Otherwise returns the line after the
header itself (bare keyword with no brace body)."
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
            (forward-sexp)         ; jump to matching }
            (forward-line 1)
            (point))
        (goto-char header-pos)
        (forward-line 1)
        (point)))))

(defun taskjuggler--block-with-comments-start (header-pos)
  "Return the start of the block at HEADER-POS, including preceding comments.
Immediately preceding lines that begin with `#' or `//' (no blank lines
between them and the header) are considered part of the block."
  (save-excursion
    (goto-char header-pos)
    (beginning-of-line)
    (let ((start (point)))
      (while (and (not (bobp))
                  (save-excursion
                    (forward-line -1)
                    (looking-at "[ \t]*\\(#\\|//\\)")))
        (forward-line -1)
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
      ;; Skip backward over blank lines.
      (while (and (not (bobp))
                  (progn (forward-line -1) (looking-at "[ \t]*$"))))
      (when (not (or (and (bobp) (looking-at "[ \t]*$"))
                     (looking-at "[ \t]*$")))
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
                         (backward-sexp)   ; } → matching {
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
      ;; Skip blank lines and comment lines to reach the next keyword.
      (while (and (not (eobp))
                  (looking-at "[ \t]*\\($\\|#\\|//\\)"))
        (forward-line 1))
      (when (and (not (eobp))
                 (looking-at taskjuggler--moveable-block-re)
                 (= (car (syntax-ppss)) depth))
        (let* ((next-header (point))
               (next-start  (taskjuggler--block-with-comments-start next-header))
               (next-end    (taskjuggler--block-end next-header)))
          (list next-start next-header next-end))))))

(defun taskjuggler-move-block-up ()
  "Move the block at point before its previous sibling block.
The block is identified by the moveable keyword line at or enclosing point.
Any comment lines immediately preceding the block travel with it.
The blank-line separator between the two blocks is preserved."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let* ((cur-start (taskjuggler--block-with-comments-start header))
           (cur-end   (taskjuggler--block-end header))
           (prev      (taskjuggler--prev-sibling-bounds header)))
      (unless prev
        (user-error "No previous sibling block to move past"))
      (let* ((prev-start    (nth 0 prev))
             (prev-end      (nth 2 prev))
             (prev-text     (buffer-substring prev-start prev-end))
             (sep-text      (buffer-substring prev-end cur-start))
             (cur-text      (buffer-substring cur-start cur-end))
             (header-offset (- header cur-start)))
        (goto-char prev-start)
        (delete-region prev-start cur-end)
        (insert cur-text sep-text prev-text)
        (goto-char (+ prev-start header-offset))))))

(defun taskjuggler-move-block-down ()
  "Move the block at point after its next sibling block.
The block is identified by the moveable keyword line at or enclosing point.
Any comment lines immediately preceding the next block travel with it.
The blank-line separator between the two blocks is preserved."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let* ((cur-start (taskjuggler--block-with-comments-start header))
           (cur-end   (taskjuggler--block-end header))
           (next      (taskjuggler--next-sibling-bounds header)))
      (unless next
        (user-error "No next sibling block to move past"))
      (let* ((next-start    (nth 0 next))
             (next-end      (nth 2 next))
             (cur-text      (buffer-substring cur-start cur-end))
             (sep-text      (buffer-substring cur-end next-start))
             (next-text     (buffer-substring next-start next-end))
             (header-offset (- header cur-start)))
        (goto-char cur-start)
        (delete-region cur-start next-end)
        (insert next-text sep-text cur-text)
        (goto-char (+ cur-start (length next-text) (length sep-text) header-offset))))))

;;; Block navigation

(defun taskjuggler-next-block ()
  "Move point to the next sibling block at the same depth.
Finds the block at or enclosing point and jumps to the header of the
next sibling.  Signals an error if there is no next sibling."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let ((next (taskjuggler--next-sibling-bounds header)))
      (if next
          (goto-char (nth 1 next))
        (user-error "No next sibling block")))))

(defun taskjuggler-prev-block ()
  "Move point to the previous sibling block at the same depth.
Finds the block at or enclosing point and jumps to the header of the
previous sibling.  Signals an error if there is no previous sibling."
  (interactive)
  (let ((header (taskjuggler--current-block-header)))
    (unless header
      (user-error "Not on a moveable TaskJuggler block"))
    (let ((prev (taskjuggler--prev-sibling-bounds header)))
      (if prev
          (goto-char (nth 1 prev))
        (user-error "No previous sibling block")))))

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
        (if header
            ;; In a block (or at its header): jump there and do (count-1)
            ;; additional backward searches.
            (progn
              (goto-char header)
              (dotimes (_ (1- count))
                (when (re-search-backward taskjuggler--moveable-block-re nil 'move)
                  (beginning-of-line))))
          ;; Not inside any block: search backward COUNT times.
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
        (let ((header (taskjuggler--current-block-header)))
          (if header
              (goto-char (taskjuggler--block-end header))
            ;; Not in a block: find the next block and skip past it.
            (when (re-search-forward taskjuggler--moveable-block-re nil 'move)
              (beginning-of-line)
              (goto-char (taskjuggler--block-end (point))))))))
     ((< count 0)
      (taskjuggler--beginning-of-defun (- count))))))

;;; Compilation

;; TJ3 error format: "filename.tjp:LINE: \e[31mError: message\e[0m"
;; The regexp matches with or without ANSI escape codes so it works whether or
;; not ansi-color-compilation-filter is active.
(defconst taskjuggler--compilation-error-re
  '(taskjuggler
    "^\\([^()\t\n :]+\\):\\([0-9]+\\): \\(?:\e\\[[0-9;]*m\\)?Error:"
    1 2 nil 2)
  "Entry for `compilation-error-regexp-alist-alist' matching TJ3 error output.")

(defvar compilation-error-regexp-alist-alist
  "Alist mapping error regexp symbols to their specs; defined in `compile.el'.
Forward-declared here to silence the byte-compiler.")
(defvar compilation-error-regexp-alist
  "List of active error regexp symbols used by `compilation-mode'; defined in `compile.el'.
Forward-declared here to silence the byte-compiler.")
(with-eval-after-load 'compile
  (add-to-list 'compilation-error-regexp-alist-alist
               taskjuggler--compilation-error-re)
  (add-to-list 'compilation-error-regexp-alist 'taskjuggler))

;;; Flymake

(defvar-local taskjuggler--flymake-proc nil
  "The currently running flymake process for this buffer.")

(defun taskjuggler-flymake-backend (report-fn &rest _args)
  "Flymake backend for `taskjuggler-mode'.
Runs tj3 on the current file and reports errors via REPORT-FN."
  (unless (executable-find taskjuggler-tj3-program)
    (error "Cannot find tj3 executable: %s" taskjuggler-tj3-program))
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
             :command (append (list taskjuggler-tj3-program) taskjuggler-tj3-extra-args (list file))
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

;;; Mode definition

;;;###autoload
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
  ;; Compilation: pre-fill compile-command with tj3 and the current file.
  (when (buffer-file-name)
    (setq-local compile-command
                (concat taskjuggler-tj3-program " " (shell-quote-argument (buffer-file-name)))))
  ;; Flymake
  (add-hook 'flymake-diagnostic-functions #'taskjuggler-flymake-backend nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tjp\\'" . taskjuggler-mode))

(define-key taskjuggler-mode-map (kbd "M-<up>")   #'taskjuggler-move-block-up)
(define-key taskjuggler-mode-map (kbd "M-<down>") #'taskjuggler-move-block-down)

(declare-function evil-define-key* "evil-core")

;; Evil-mode navigation bindings (normal state).
;; gj/gk jump to the next/previous sibling block at the same depth;
;; gh moves up to the enclosing block's keyword line.
;; Wrapped in with-eval-after-load so the mode loads cleanly without evil.
;; evil-define-key* (function) is used instead of evil-define-key (macro)
;; so the call survives byte-compilation without evil present.
(with-eval-after-load 'evil
  (evil-define-key* 'normal taskjuggler-mode-map
    (kbd "gj") #'taskjuggler-next-block
    (kbd "gk") #'taskjuggler-prev-block
    (kbd "gh") #'taskjuggler-goto-parent))
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
  (unless (member 'taskjuggler-mode-snippets-dir yas-snippet-dirs)
    (add-to-list 'yas-snippet-dirs 'taskjuggler-mode-snippets-dir t)
    (yas--load-snippet-dirs)))

;;;###autoload
(eval-after-load 'yasnippet
   '(taskjuggler-mode-snippets-initialize))

(provide 'taskjuggler-mode)
;;; taskjuggler-mode.el ends here
