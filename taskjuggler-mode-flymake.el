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
;; - `taskjuggler-mode-flymake-backend' runs `tj3' on the current file when no
;;   running tj3d daemon owns the project.
;;
;; - `taskjuggler-mode-tj3d-flymake-backend' synchronously reports diagnostics
;;   cached by the daemon's `tj3client add' sentinel when the daemon does
;;   own the project.
;;
;; Ownership is decided by `taskjuggler-mode--tj3d-owns-current-buffer-p'
;; (defined in `taskjuggler-mode-daemon').

;;; Code:

(require 'flymake)
(require 'taskjuggler-mode-daemon)

;; Defined in `taskjuggler-mode' proper.
(defvar taskjuggler-mode-tj3-extra-args)
(declare-function taskjuggler-mode--tj3-executable "taskjuggler-mode" (program))

(defvar-local taskjuggler-mode--flymake-proc nil
  "The currently running flymake process for this buffer.")

(defun taskjuggler-mode--flymake-strip-ansi ()
  "Remove ANSI SGR escape sequences from the current buffer."
  (goto-char (point-min))
  (while (re-search-forward "\e\\[[0-9;]*m" nil t)
    (replace-match "")))

(defun taskjuggler-mode--flymake-parse-file-diagnostics (source file)
  "Parse `FILE:LINE: Error|Warning: MSG' lines in the current buffer.
Return Flymake diagnostics anchored on SOURCE in tj3 output order.
Errors whose path differs from FILE are skipped — those buffers report
them in their own Flymake check."
  (let (diags)
    (goto-char (point-min))
    (while (re-search-forward
            (concat "^" (regexp-quote file)
                    ":\\([0-9]+\\): \\(Error\\|Warning\\): \\(.*\\)")
            nil t)
      (let* ((lnum (string-to-number (match-string 1)))
             (type (if (equal (match-string 2) "Error") :error :warning))
             (msg  (match-string 3))
             (reg  (flymake-diag-region source lnum)))
        (push (flymake-make-diagnostic source (car reg) (cdr reg) type msg)
              diags)))
    (nreverse diags)))

(defun taskjuggler-mode--flymake-parse-prefixless-warnings (source)
  "Parse prefix-less `Warning: MSG' lines in the current buffer.
Return Flymake diagnostics anchored at line 1 of SOURCE in output order.
These are tj3 warnings that arrive without a file:line preamble."
  (let (diags)
    (goto-char (point-min))
    (while (re-search-forward "^Warning: \\(.*\\)" nil t)
      (let* ((msg (match-string 1))
             (reg (flymake-diag-region source 1)))
        (push (flymake-make-diagnostic source (car reg) (cdr reg) :warning msg)
              diags)))
    (nreverse diags)))

(defun taskjuggler-mode--flymake-collect-diagnostics (source file)
  "Return all Flymake diagnostics for SOURCE/FILE from tj3 output.
The current buffer is the tj3 output buffer; this strips ANSI first
then concatenates per-file diagnostics with prefix-less warnings."
  (taskjuggler-mode--flymake-strip-ansi)
  (append (taskjuggler-mode--flymake-parse-file-diagnostics source file)
          (taskjuggler-mode--flymake-parse-prefixless-warnings source)))

(defun taskjuggler-mode--flymake-sentinel (source file report-fn proc _event)
  "Process sentinel for the tj3 Flymake subprocess.
Reports diagnostics for SOURCE/FILE via REPORT-FN once PROC has exited.
Skipped silently when PROC has been superseded by a newer check."
  (when (memq (process-status proc) '(exit signal))
    (unwind-protect
        (if (eq proc (buffer-local-value 'taskjuggler-mode--flymake-proc source))
            (with-current-buffer (process-buffer proc)
              (funcall report-fn
                       (taskjuggler-mode--flymake-collect-diagnostics
                        source file)))
          (flymake-log :debug "Canceling obsolete check %s" proc))
      (kill-buffer (process-buffer proc)))))

(defun taskjuggler-mode--flymake-spawn (source file report-fn)
  "Spawn a tj3 subprocess to check SOURCE/FILE and report via REPORT-FN.
The new process is recorded in `taskjuggler-mode--flymake-proc' so
later sentinel runs can detect that they have been superseded."
  (setq taskjuggler-mode--flymake-proc
        (make-process
         :name "taskjuggler-mode-flymake"
         :noquery t
         :connection-type 'pipe
         :buffer (generate-new-buffer " *taskjuggler-mode-flymake*")
         :command (append (list (taskjuggler-mode--tj3-executable "tj3"))
                          taskjuggler-mode-tj3-extra-args (list file))
         :sentinel
         (lambda (proc event)
           (taskjuggler-mode--flymake-sentinel
            source file report-fn proc event)))))

(defun taskjuggler-mode-flymake-backend (report-fn &rest _args)
  "Flymake backend for `taskjuggler-mode'.
Runs tj3 on the current file and reports errors via REPORT-FN.
Yields to `taskjuggler-mode-tj3d-flymake-backend' whenever the project is
loaded in tj3d, to avoid duplicate work and conflicting diagnostics."
  (unless (executable-find (taskjuggler-mode--tj3-executable "tj3"))
    (error "Cannot find tj3 executable: %s"
           (taskjuggler-mode--tj3-executable "tj3")))
  (when (process-live-p taskjuggler-mode--flymake-proc)
    (kill-process taskjuggler-mode--flymake-proc))
  (let ((source (current-buffer))
        (file (buffer-file-name)))
    (cond
     ((not file) (funcall report-fn nil))
     ((taskjuggler-mode--tj3d-owns-current-buffer-p) (funcall report-fn nil))
     (t (taskjuggler-mode--flymake-spawn source file report-fn)))))

(defun taskjuggler-mode-tj3d-flymake-backend (report-fn &rest _args)
  "Flymake backend reporting diagnostics cached from `tj3client add'.
Reports diagnostics for the current buffer to REPORT-FN.  Synchronous:
no subprocess.  Reports only when the current buffer's project is
loaded in tj3d; otherwise yields to `taskjuggler-mode-flymake-backend' so
the two are mutually exclusive."
  (if (not (taskjuggler-mode--tj3d-owns-current-buffer-p))
      (funcall report-fn nil)
    (let* ((source (current-buffer))
           (file (and buffer-file-name (expand-file-name buffer-file-name)))
           (entries (and file (gethash file taskjuggler-mode--tj3d-diagnostics)))
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
