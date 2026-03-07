;;; taskjuggler.el --- Major mode for TaskJuggler project files -*- lexical-binding: t -*-

;; Keywords: languages, project-management
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

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
;;   - Indentation based on { } and [ ] block nesting depth
;;   - Keyword completion via completion-at-point (works with company-capf)

;;; Code:

(defgroup taskjuggler nil
  "Major mode for editing TaskJuggler project files."
  :group 'languages
  :prefix "taskjuggler-")

(defcustom taskjuggler-indent-level 2
  "Number of spaces per indentation level in TaskJuggler files."
  :type 'integer
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

;;; Completion

(defconst taskjuggler--all-keywords
  (delete-dups
   (sort (append taskjuggler-top-level-keywords
                 taskjuggler-report-keywords
                 taskjuggler-property-keywords
                 taskjuggler-value-keywords)
         #'string<))
  "Sorted list of all TaskJuggler keywords, used for completion.")

(defconst taskjuggler--signatures
  (let ((sigs
         '(;; Top-level declarations
           ("project"     . "[<id>] <name> [<version>] <interval> [{ <attributes> }]")
           ("task"         . "<id> [<name>] [{ <attributes> }]")
           ("resource"     . "<id> [<name>] [{ <attributes> }]")
           ("account"      . "<id> [<name>] [{ <attributes> }]")
           ("scenario"     . "<id> <name> [{ <attributes> }]")
           ("shift"        . "<id> [<name>] [{ <attributes> }]")
           ("extend"       . "<id> { <attributes> }")
           ("macro"        . "<id> [ <body> ]")
           ("include"      . "\"<filename>\"")
           ("flags"        . "<id>[, <id>]*")
           ("supplement"   . "(task | resource) <id> { <attributes> }")
           ;; Report types
           ("taskreport"        . "<id> \"<filename>\" [{ <attributes> }]")
           ("resourcereport"    . "<id> \"<filename>\" [{ <attributes> }]")
           ("accountreport"     . "<id> \"<filename>\" [{ <attributes> }]")
           ("textreport"        . "<id> \"<filename>\" [{ <attributes> }]")
           ("tracereport"       . "<id> \"<filename>\" [{ <attributes> }]")
           ("icalreport"        . "<id> \"<filename>\" [{ <attributes> }]")
           ("timesheetreport"   . "<id> \"<filename>\" [{ <attributes> }]")
           ("statussheetreport" . "<id> \"<filename>\" [{ <attributes> }]")
           ;; Scheduling / time
           ("effort"       . "<duration>")
           ("duration"     . "<duration>")
           ("length"       . "<duration>")
           ("start"        . "<date>")
           ("end"          . "<date>")
           ("maxstart"     . "<date>")
           ("minstart"     . "<date>")
           ("maxend"       . "<date>")
           ("minend"       . "<date>")
           ("now"          . "<date>")
           ("period"       . "<interval>")
           ("vacation"     . "<interval>")
           ("booking"      . "<resourceid> <interval>")
           ("workinghours" . "<weekday>[, <weekday>]* (<interval>[, <interval>]* | off)")
           ("scheduling"   . "(asap | alap)")
           ("timingresolution" . "<duration>")
           ;; Task relationships
           ("depends"      . "<taskid>[{<scenario>}][, <taskid>]*")
           ("precedes"     . "<taskid>[, <taskid>]*")
           ("allocate"     . "<resourceid>[, <resourceid>]*")
           ("responsible"  . "<resourceid>[, <resourceid>]*")
           ("managers"     . "<resourceid>[, <resourceid>]*")
           ;; Numeric / text properties
           ("priority"     . "<integer>  (1-1000, default 500)")
           ("complete"     . "<percentage>  (0-100)")
           ("rate"         . "<float>")
           ("efficiency"   . "<float>  (default 1.0)")
           ("dailyworkinghours" . "<float>")
           ("yearlyworkingdays" . "<float>")
           ("dailymax"     . "<duration>")
           ("weeklymax"    . "<duration>")
           ("monthlymax"   . "<duration>")
           ("overtime"     . "<duration>")
           ("limits"       . "{ <attributes> }")
           ("shifts"       . "<id>[{ <attributes> }][, <id>]*")
           ;; Text / rich-text
           ("note"         . "<string>")
           ("summary"      . "<string>")
           ("headline"     . "<string>")
           ("title"        . "<string>")
           ("caption"      . "<rich_text>")
           ("header"       . "<rich_text>")
           ("footer"       . "<rich_text>")
           ("left"         . "<rich_text>")
           ("center"       . "<rich_text>")
           ("right"        . "<rich_text>")
           ("email"        . "\"<address>\"")
           ("currency"     . "\"<symbol>\"")
           ("timezone"     . "\"<tz_name>\"")
           ("projectid"    . "<id>")
           ;; Identifiers
           ("journalentry" . "<date> \"<headline>\" [{ <attributes> }]")
           ("leave"        . "(annual | special | sick | unpaid | holiday) <interval>")
           ("leaveallowance" . "(annual | special | sick | unpaid | holiday) <duration>")
           ("charge"       . "<float> (onstart | onend | perhour | perday | perweek | permonth)")
           ("chargeset"    . "<accountid> [<percent>][, <accountid> [<percent>]]*")
           ("costaccount"  . "<accountid>")
           ("revenueaccount" . "<accountid>")
           ("balance"      . "<accountid> <accountid>")
           ;; Report configuration
           ("columns"      . "<column>[{ <attributes> }][, <column>]*")
           ("sorttasks"    . "<criterion>[up | down][, <criterion>]*")
           ("sortresources" . "<criterion>[up | down][, <criterion>]*")
           ("hidetask"     . "<logical_expr>")
           ("hideresource" . "<logical_expr>")
           ("rolluptask"   . "<logical_expr>")
           ("rollupresource" . "<logical_expr>")
           ("scenarios"    . "<id>[, <id>]*")
           ("timeformat"   . "\"<format_string>\"")
           ("formats"      . "(html | csv | niku | xml | ...)")
           ("loadunit"     . "(days | hours | weeks | months | years | minutes | shortauto | longauto)")
           ("numberformat" . "\"<frac_sep>\" \"<thou_sep>\" \"<prefix>\" \"<suffix>\" <precision>")
           ("currencyformat" . "\"<frac_sep>\" \"<thou_sep>\" \"<prefix>\" \"<suffix>\" <precision>")
           ("opennodes"    . "<integer>")
           ("resourceroot" . "<resourceid>")
           ("taskroot"     . "<taskid>")
           ("showprojectids" . "(yes | no)")
           ("weekstartmonday" . "(yes | no)")
           ("purge"        . "(depends | allocate | chargeset | flags | ...)")
           ;; Boolean-ish value keywords
           ("yes"          . "boolean true")
           ("no"           . "boolean false")
           ("true"         . "boolean true")
           ("false"        . "boolean false")
           ("on"           . "boolean true (alternative)")
           ("off"          . "boolean false (alternative)")
           ("asap"         . "as-soon-as-possible scheduling")
           ("alap"         . "as-late-as-possible scheduling")))
        (tbl (make-hash-table :test #'equal :size 200)))
    (pcase-dolist (`(,k . ,v) sigs) (puthash k v tbl))
    tbl)
  "Hash table mapping TaskJuggler keywords to their argument signatures.")

(defun taskjuggler--keyword-annotation (candidate)
  "Return a category label for CANDIDATE for display in completion popups."
  (cond
   ((member candidate taskjuggler-top-level-keywords) " keyword")
   ((member candidate taskjuggler-report-keywords)    " report")
   ((member candidate taskjuggler-property-keywords)  " property")
   ((member candidate taskjuggler-value-keywords)     " value")
   (t "")))

(defun taskjuggler-completion-at-point ()
  "Provide keyword completion for `taskjuggler-mode'.
Works with `company-capf' and built-in completion (\\[completion-at-point]).
Argument signatures are shown via `:company-docsig' (echo area in company-mode)."
  (let ((ppss (syntax-ppss)))
    ;; Don't offer keyword completion inside strings or comments.
    (unless (or (nth 3 ppss) (nth 4 ppss))
      (let ((end (point))
            (start (save-excursion
                     (skip-chars-backward "[:alpha:]")
                     (point))))
        (when (< start end)
          (list start end taskjuggler--all-keywords
                :exclusive 'no
                :annotation-function #'taskjuggler--keyword-annotation
                :company-docsig
                (lambda (cand)
                  (gethash cand taskjuggler--signatures ""))))))))

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
  ;; Completion
  (add-hook 'completion-at-point-functions #'taskjuggler-completion-at-point nil t)
  ;; Indentation
  (setq-local indent-line-function #'taskjuggler-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width taskjuggler-indent-level))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tjp\\'" . taskjuggler-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.tji\\'" . taskjuggler-mode))

(provide 'taskjuggler)
;;; taskjuggler.el ends here
