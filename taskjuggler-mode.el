;;; taskjuggler-mode.el --- Major mode for TaskJuggler project files -*- lexical-binding: t -*-

;; Keywords: languages, project-management
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
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

;;; Code:

(declare-function yas-load-directory "yasnippet" (directory &optional recurse))

(defgroup taskjuggler nil
  "Major mode for editing TaskJuggler project files."
  :group 'languages
  :prefix "taskjuggler-")

(defcustom taskjuggler-indent-level 2
  "Number of spaces per indentation level in TaskJuggler files."
  :type 'integer
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

(defun taskjuggler--calculate-indent ()
  "Return the target indentation column for the current line.
Indentation is based on the brace/bracket nesting depth at the start
of the line, as computed by `syntax-ppss'.  A line opening with `}'
or `]' is de-indented one level relative to the enclosing block."
  (save-excursion
    (beginning-of-line)
    (let* ((depth (car (syntax-ppss)))
           (indent (* depth taskjuggler-indent-level)))
      ;; A closing delimiter starts a new (outer) scope.
      (when (looking-at "[ \t]*[]}]")
        (setq indent (max 0 (- indent taskjuggler-indent-level))))
      indent)))

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
  (unless (executable-find "tj3")
    (error "Cannot find tj3 on PATH"))
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
             :command (append (list "tj3") taskjuggler-tj3-extra-args (list file))
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
  ;; Compilation: pre-fill compile-command with tj3 and the current file.
  (when (buffer-file-name)
    (setq-local compile-command
                (concat "tj3 " (shell-quote-argument (buffer-file-name)))))
  ;; Flymake
  (add-hook 'flymake-diagnostic-functions #'taskjuggler-flymake-backend nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tjp\\'" . taskjuggler-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tji\\'" . taskjuggler-mode))

;;; Yasnippet

(with-eval-after-load 'yasnippet
  (let ((snippets-dir (expand-file-name "snippets"
                                        (file-name-directory
                                         (or load-file-name buffer-file-name)))))
    (when (file-directory-p snippets-dir)
      (add-to-list 'yas-snippet-dirs snippets-dir)
      (yas-load-directory snippets-dir))))

(provide 'taskjuggler-mode)
;;; taskjuggler-mode.el ends here
