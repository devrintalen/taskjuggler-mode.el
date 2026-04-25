;;; taskjuggler-mode-flymake.el --- Flymake backends for taskjuggler-mode -*- lexical-binding: t -*-

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
;; Two mutually-exclusive Flymake backends:
;;
;; - `taskjuggler-flymake-backend' runs `tj3' on the current file when no
;;   running tj3d daemon owns the project.
;;
;; - `taskjuggler-tj3d-flymake-backend' synchronously reports diagnostics
;;   cached by the daemon's `tj3client add' sentinel when the daemon does
;;   own the project.
;;
;; Ownership is decided by `taskjuggler--tj3d-owns-current-buffer-p'
;; (defined in `taskjuggler-mode-daemon').

;;; Code:

(require 'flymake)
(require 'taskjuggler-mode-daemon)

;; Defined in `taskjuggler-mode' proper.
(defvar taskjuggler-tj3-extra-args)
(declare-function taskjuggler--tj3-executable "taskjuggler-mode" (program))

(defvar-local taskjuggler--flymake-proc nil
  "The currently running flymake process for this buffer.")

(defun taskjuggler-flymake-backend (report-fn &rest _args)
  "Flymake backend for `taskjuggler-mode'.
Runs tj3 on the current file and reports errors via REPORT-FN.
Yields to `taskjuggler-tj3d-flymake-backend' whenever the project is
loaded in tj3d, to avoid duplicate work and conflicting diagnostics."
  (unless (executable-find (taskjuggler--tj3-executable "tj3"))
    (error "Cannot find tj3 executable: %s" (taskjuggler--tj3-executable "tj3")))
  (when (process-live-p taskjuggler--flymake-proc)
    (kill-process taskjuggler--flymake-proc))
  (let* ((source (current-buffer))
         (file   (buffer-file-name)))
    (cond
     ((not file)
      (funcall report-fn nil))
     ((taskjuggler--tj3d-owns-current-buffer-p)
      (funcall report-fn nil))
     (t
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
                   (kill-buffer (process-buffer proc)))))))))))

(defun taskjuggler-tj3d-flymake-backend (report-fn &rest _args)
  "Flymake backend reporting diagnostics cached from `tj3client add'.
Reports diagnostics for the current buffer to REPORT-FN.  Synchronous:
no subprocess.  Reports only when the current buffer's project is
loaded in tj3d; otherwise yields to `taskjuggler-flymake-backend' so
the two are mutually exclusive."
  (if (not (taskjuggler--tj3d-owns-current-buffer-p))
      (funcall report-fn nil)
    (let* ((source (current-buffer))
           (file (and buffer-file-name (expand-file-name buffer-file-name)))
           (entries (and file (gethash file taskjuggler--tj3d-diagnostics)))
           diags)
      (dolist (entry entries)
        (let* ((line (nth 0 entry))
               (type (nth 1 entry))
               (msg  (nth 2 entry))
               (reg  (flymake-diag-region source line)))
          (when reg
            (push (flymake-make-diagnostic source (car reg) (cdr reg) type msg)
                  diags))))
      (funcall report-fn diags))))

(provide 'taskjuggler-mode-flymake)

;;; taskjuggler-mode-flymake.el ends here
