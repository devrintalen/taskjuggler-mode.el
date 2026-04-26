;;; taskjuggler-mode-tj3man.el --- tj3man documentation lookup -*- lexical-binding: t -*-

;; Copyright (C) 2025 Devrin Talen <devrin@fastmail.com>

;; Author: Devrin Talen <devrin@fastmail.com>
;; Keywords: languages, project-management
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
;; `taskjuggler-mode-man' looks up TJ3 keyword documentation via the `tj3man'
;; CLI and renders it with man-style faces and clickable cross-references.

;;; Code:

(require 'man)

;; Defined in `taskjuggler-mode' proper.
(declare-function taskjuggler-mode--tj3-executable "taskjuggler-mode" (program))

(defvar taskjuggler-mode--tj3man-keywords nil
  "Cached list of keywords returned by `tj3man' with no arguments.
Populated the first time `taskjuggler-mode' starts with a working tj3man.")

(defun taskjuggler-mode--populate-tj3man-keywords ()
  "Populate `taskjuggler-mode--tj3man-keywords' by calling tj3man.
Does nothing if the cache is already filled or tj3man cannot be found.
Only lines that look like TJ3 identifiers (lowercase, may contain
dots and hyphens) are kept; the copyright header is discarded."
  (unless taskjuggler-mode--tj3man-keywords
    (let ((tj3man (taskjuggler-mode--tj3-executable "tj3man")))
      (when (executable-find tj3man)
        (setq taskjuggler-mode--tj3man-keywords
              (seq-filter
               (lambda (s) (string-match-p "\\`[a-z][a-z0-9._-]*\\'" s))
               (split-string (shell-command-to-string tj3man) "\n" t)))))))

(defun taskjuggler-mode--make-tj3man-button (start end keyword)
  "Make a button from START to END that opens the tj3man page for KEYWORD."
  (make-text-button start end
                    'action (let ((kw keyword))
                              (lambda (_btn) (taskjuggler-mode-man kw)))
                    'follow-link t
                    'help-echo (format "tj3man %s" keyword)
                    'face 'button))

(defun taskjuggler-mode--fontify-tj3man-headers ()
  "Apply Man-overstrike to the six section-header labels in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward
            "^\\(Keyword\\|Purpose\\|Syntax\\|Arguments\\|Context\\|Attributes\\):"
            nil t)
      (put-text-property (match-beginning 0) (match-end 0)
                         'face 'Man-overstrike))))

(defun taskjuggler-mode--fontify-tj3man-syntax ()
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

(defun taskjuggler-mode--fontify-tj3man-arguments (tag-width)
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

(defun taskjuggler-mode--fontify-tj3man-attributes ()
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
            (taskjuggler-mode--make-tj3man-button
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

(defun taskjuggler-mode--fontify-tj3man-links ()
  "Linkify known tj3man keywords throughout the buffer as clickable buttons.
Skips positions already styled with buttons, Man-overstrike, or
Man-underline, and skips the documented keyword on the Keyword: and
Syntax: lines."
  (when taskjuggler-mode--tj3man-keywords
    (let ((kw-table (make-hash-table :test 'equal)))
      (dolist (kw taskjuggler-mode--tj3man-keywords)
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
              (taskjuggler-mode--make-tj3man-button start end word))))))))

(defun taskjuggler-mode--fontify-tj3man ()
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
    (taskjuggler-mode--fontify-tj3man-headers)
    (taskjuggler-mode--fontify-tj3man-syntax)
    (taskjuggler-mode--fontify-tj3man-arguments tag-width)
    (taskjuggler-mode--fontify-tj3man-attributes)
    (taskjuggler-mode--fontify-tj3man-links)))

(defun taskjuggler-mode-man (keyword)
  "Show tj3man documentation for KEYWORD in a help window.
Prompts with completion over the keywords listed by `tj3man',
defaulting to the word at point."
  (interactive
   (let* ((tj3man (taskjuggler-mode--tj3-executable "tj3man"))
          (_ (unless (executable-find tj3man)
               (user-error "Cannot find tj3man executable: %s" tj3man)))
          (default (thing-at-point 'word t))
          (prompt  (if default
                       (format "tj3man keyword (default %s): " default)
                     "tj3man keyword: ")))
     (list (completing-read prompt taskjuggler-mode--tj3man-keywords
                            nil nil nil nil default))))
  (let ((tj3man (taskjuggler-mode--tj3-executable "tj3man")))
    (with-help-window "*tj3man*"
      (princ (shell-command-to-string
              (concat tj3man " " (shell-quote-argument keyword))))
      (with-current-buffer standard-output
        (taskjuggler-mode--fontify-tj3man)))))

(provide 'taskjuggler-mode-tj3man)

;;; taskjuggler-mode-tj3man.el ends here
