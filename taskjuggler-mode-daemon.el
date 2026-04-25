;;; taskjuggler-mode-daemon.el --- tj3d/tj3webd daemon integration -*- lexical-binding: t -*-

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
;; Manages the tj3d scheduling daemon and tj3webd report server, plus the
;; in-memory diagnostic cache populated by `tj3client add' that the two
;; Flymake backends consume.  Loaded by `taskjuggler-mode'.

;;; Code:

(require 'ansi-color)
(require 'comint)
(require 'flymake)

;; Defined in `taskjuggler-mode' proper or in the cursor sub-file.
(defvar taskjuggler-tj3webd-port)
(defvar taskjuggler-tj3-extra-args)
(defvar taskjuggler--cursor-api-url)
(defvar taskjuggler--cursor-idle-timer)
(declare-function taskjuggler--tj3-executable "taskjuggler-mode" (program))
(declare-function taskjuggler--cursor-api-probe "taskjuggler-mode-cursor" ())
(declare-function taskjuggler--start-cursor-tracking
                  "taskjuggler-mode-cursor" ())

;;; Diagnostic cache (shared by daemon's tj3client-add sentinel and the
;;; tj3d Flymake backend)

(defvar taskjuggler--tj3d-diagnostics (make-hash-table :test 'equal)
  "Hash table of tj3d-reported diagnostics keyed by absolute file path.
Each value is a list of (LINE TYPE MSG) entries where TYPE is :error or
:warning.  Populated from `tj3client add' output and consumed by
`taskjuggler-tj3d-flymake-backend'.")

(defvar taskjuggler--tj3d-diag-files-by-project (make-hash-table :test 'equal)
  "Hash table mapping a .tjp file to the list of files it annotated.
Used to clear the right subset on re-add so diagnostics from other
projects loaded in the same daemon are preserved.")

(defmacro taskjuggler--with-source-buffer (source &rest body)
  "Run BODY with point at the start of SOURCE's content.
SOURCE is either a live buffer (preserved + widened + position saved)
or a readable file path (loaded into a temp buffer).  When SOURCE is a
path that can't be read, BODY is not run and the form returns nil."
  (declare (indent 1))
  `(let ((source--src ,source))
     (cond
      ((bufferp source--src)
       (with-current-buffer source--src
         (save-excursion
           (save-restriction
             (widen)
             (goto-char (point-min))
             ,@body))))
      ((and (stringp source--src) (file-readable-p source--src))
       (with-temp-buffer
         (insert-file-contents source--src)
         (goto-char (point-min))
         ,@body)))))

(defun taskjuggler--tj3d-resolve-path (file tjp)
  "Resolve FILE to an absolute path.
A relative FILE is expanded against the directory of TJP."
  (if (file-name-absolute-p file)
      (expand-file-name file)
    (expand-file-name file (file-name-directory tjp))))

(defun taskjuggler--tj3d-clear-diagnostics-for-project (tjp)
  "Drop diagnostics previously recorded under project TJP.
Returns the list of file paths that had diagnostics cleared so callers
can refresh Flymake in their buffers."
  (let* ((tjp-abs (expand-file-name tjp))
         (files (gethash tjp-abs taskjuggler--tj3d-diag-files-by-project)))
    (dolist (file files)
      (remhash file taskjuggler--tj3d-diagnostics))
    (remhash tjp-abs taskjuggler--tj3d-diag-files-by-project)
    files))

(defun taskjuggler--tj3d-record-diagnostic (file line type msg tjp)
  "Record a daemon diagnostic on FILE:LINE of TYPE and MSG under project TJP."
  (let ((abs (taskjuggler--tj3d-resolve-path file tjp))
        (tjp-abs (expand-file-name tjp)))
    (push (list line type msg) (gethash abs taskjuggler--tj3d-diagnostics))
    (let ((files (gethash tjp-abs taskjuggler--tj3d-diag-files-by-project)))
      (unless (member abs files)
        (puthash tjp-abs (cons abs files)
                 taskjuggler--tj3d-diag-files-by-project)))))

(defun taskjuggler--tj3d-scan-include-lines (source basename)
  "Return line numbers in SOURCE whose `include' quotes a path ending in BASENAME.
SOURCE is either a live buffer or an absolute file path; a path that
can't be read yields nil."
  (let ((pattern (concat "^[ \t]*include[ \t]+\"[^\"]*"
                         (regexp-quote basename) "\""))
        lines)
    (taskjuggler--with-source-buffer source
      (while (re-search-forward pattern nil t)
        (push (line-number-at-pos (match-beginning 0)) lines)))
    (nreverse lines)))

(defun taskjuggler--tj3d-propagate-to-includers (child-file type msg tjp)
  "Record a diagnostic of TYPE and MSG on every `include' of CHILD-FILE in TJP.
Matches by CHILD-FILE's basename only.  Scans only the .tjp passed to
`tj3client add' (the project root whose add produced the diagnostic) —
not arbitrary open buffers — so an unrelated buffer whose include
happens to share the same basename is not flagged.  Reads TJP from
disk if no buffer is visiting it."
  (let ((tjp-abs (expand-file-name tjp)))
    (unless (equal tjp-abs child-file)
      (let* ((basename (file-name-nondirectory child-file))
             (source (or (find-buffer-visiting tjp-abs) tjp-abs))
             (lines (taskjuggler--tj3d-scan-include-lines source basename)))
        (dolist (line lines)
          (taskjuggler--tj3d-record-diagnostic
           tjp-abs line type
           (format "In %s: %s" basename msg)
           tjp))))))

(defun taskjuggler--tj3d-parse-diagnostics (tjp)
  "Parse tj3client output in the current buffer, recording diags under TJP.
Matches `FILE:LINE: Error|Warning: MSG' lines.  Errors whose FILE
differs from TJP are also propagated to the `include' line in TJP
that references that file's basename."
  (let ((tjp-abs (expand-file-name tjp)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "^\\(.+?\\):\\([0-9]+\\): \\(Error\\|Warning\\): \\(.*\\)$"
              nil t)
        (let* ((file (match-string-no-properties 1))
               (line (string-to-number (match-string 2)))
               (type (if (equal (match-string 3) "Error") :error :warning))
               (msg  (match-string-no-properties 4))
               (abs  (taskjuggler--tj3d-resolve-path file tjp)))
          (taskjuggler--tj3d-record-diagnostic file line type msg tjp)
          (unless (equal abs tjp-abs)
            (taskjuggler--tj3d-propagate-to-includers abs type msg tjp)))))))

(defun taskjuggler--tj3d-refresh-flymake-for-files (files)
  "Re-run Flymake in any taskjuggler-mode buffer visiting one of FILES."
  (dolist (file files)
    (let ((buf (find-buffer-visiting file)))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (when (bound-and-true-p flymake-mode)
            (flymake-start)))))))

;;; Daemon management (tj3d / tj3webd)

;; tj3d is the TaskJuggler scheduling daemon.  Once started, projects can be
;; added to it with `tj3client' and it will re-schedule on file changes.
;; tj3webd is a companion web server that serves reports from tj3d.  Both
;; daemons fork into the background (the launcher process exits immediately),
;; so liveness is checked via `tj3client status' / TCP probe rather than
;; process objects.

(defconst taskjuggler--tj3-no-color "--no-color"
  "Argument that suppresses ANSI escapes from `tj3'/`tj3d'/`tj3client'.
Passed to every invocation we make so subprocess output reads cleanly
in `*compilation*'/`*tj3client*'/captured-string contexts.  The flag
silences tj3client's own output but tj3d still forwards ANSI from the
daemon side, which `taskjuggler--tj3-process-filter' cleans up.")

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

(defun taskjuggler--tj3d-owns-current-buffer-p ()
  "Return non-nil when tj3d is authoritative for the current buffer's project.
Authoritative when we tracked an add for it this session, when an add
recorded diagnostics for it (covers the failed-add case where the
daemon produced errors but `tj3client status' doesn't list the
project), or — as a last resort — when `tj3client status' itself
reports it loaded (covers projects added externally before this Emacs
session).  Cheap hash lookups run before the subprocess query so the
common case stays off the Flymake hot path.  Resolves .tji files to
their sibling .tjp."
  (let ((tjp (taskjuggler--find-tjp-file)))
    (when tjp
      (let ((abs (expand-file-name tjp)))
        (or (gethash abs taskjuggler--tj3d-tracked-projects)
            (gethash abs taskjuggler--tj3d-diag-files-by-project)
            (taskjuggler--tj3d-project-loaded-p tjp))))))

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
      (call-process cmd nil nil nil taskjuggler--tj3-no-color "--auto-update")
      (taskjuggler--daemon-ensure-status-timer)
      (taskjuggler--daemon-update-modeline)
      (message "tj3d started"))))

(defun taskjuggler--tj3-process-filter (proc string)
  "Insert STRING from PROC, handling carriage returns and ANSI colors.
TaskJuggler writes progress bars using lone `\\r' to overwrite the
current line, and tj3d forwards ANSI SGR escapes for progress/error text
over the tj3client socket even when tj3client/tj3d are invoked with
`--no-color' (upstream bug: the flag only silences tj3client's own
banner, not the daemon's forwarded output).  This filter runs
`comint-carriage-motion' and `ansi-color-apply-on-region' over just the
newly inserted text so the buffer reads like a terminal."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((moving (= (point) (process-mark proc)))
              (inhibit-read-only t)
              start)
          (save-excursion
            (goto-char (process-mark proc))
            (setq start (copy-marker (point) nil))
            (insert string)
            (set-marker (process-mark proc) (point))
            (comint-carriage-motion start (process-mark proc))
            (ansi-color-apply-on-region start (process-mark proc))
            (set-marker start nil))
          (when moving (goto-char (process-mark proc))))))))

(defvar taskjuggler--tj3d-tracked-projects (make-hash-table :test 'equal)
  "Hash of abs-.tjp paths submitted to tj3d this session.
Used as a cheap gate by `taskjuggler--tj3d-refresh-on-save' — no
`tj3client status' probe needed.  Cleared by `taskjuggler-tj3d-stop'.")

(defvar taskjuggler--tj3d-refresh-queue nil
  "Pending tj3d refreshes as a FIFO of (ABS-TJP . QUIET) pairs.
At most one entry per distinct ABS-TJP: duplicate schedule requests
coalesce so rapid saves don't pile up redundant `tj3client add' runs.")

(defvar taskjuggler--tj3d-refresh-in-flight nil
  "ABS-TJP currently being refreshed, or nil.
Guards against two concurrent `tj3client add' runs clobbering the
shared `*tj3client*' buffer.")

(defun taskjuggler--tj3d-add-project-run (tjp quiet)
  "Run `tj3client add' on TJP asynchronously and update diagnostics.
When QUIET, suppress the progress messages (failures still report).
Marks TJP as tracked and, on completion, drains the refresh queue."
  (let* ((cmd (taskjuggler--tj3-executable "tj3client"))
         (buf (get-buffer-create "*tj3client*"))
         (tjp-abs (expand-file-name tjp)))
    (puthash tjp-abs t taskjuggler--tj3d-tracked-projects)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (unless quiet
      (message "Adding %s to tj3d..." (file-name-nondirectory tjp)))
    (make-process
     :name "tj3client-add"
     :buffer buf
     :command (list cmd taskjuggler--tj3-no-color "add" tjp)
     :noquery t
     :filter #'taskjuggler--tj3-process-filter
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         ;; Always release the in-flight lock and drain the queue, even if
         ;; parsing or Flymake refresh errors out — otherwise schedule
         ;; requests for this path silently coalesce away forever.
         (unwind-protect
             (let ((old-files
                    (taskjuggler--tj3d-clear-diagnostics-for-project tjp)))
               (when (buffer-live-p (process-buffer proc))
                 (with-current-buffer (process-buffer proc)
                   (taskjuggler--tj3d-parse-diagnostics tjp)))
               (let ((new-files
                      (gethash tjp-abs
                               taskjuggler--tj3d-diag-files-by-project)))
                 ;; Always refresh the .tjp itself so the tj3 direct backend
                 ;; clears any stale errors now that tj3d owns the project.
                 (taskjuggler--tj3d-refresh-flymake-for-files
                  (delete-dups (cons tjp-abs
                                     (append old-files new-files)))))
               (if (zerop (process-exit-status proc))
                   (unless quiet
                     (message "Project added to tj3d: %s"
                              (file-name-nondirectory tjp)))
                 (message "tj3client add failed (exit %d); see *tj3client*"
                          (process-exit-status proc))))
           (taskjuggler--tj3d-drain-refresh-queue)))))))

(defun taskjuggler--tj3d-drain-refresh-queue ()
  "Pop the next entry off the refresh queue and launch it, or clear in-flight.
Called from the `tj3client-add' sentinel after a run completes.  If the
launched run errors before its sentinel can run (e.g. `tj3client'
vanished from PATH, fork failed), this resets in-flight so subsequent
schedules can recover instead of coalescing away forever."
  (setq taskjuggler--tj3d-refresh-in-flight nil)
  (when taskjuggler--tj3d-refresh-queue
    (let* ((next (pop taskjuggler--tj3d-refresh-queue))
           (next-abs (car next))
           (next-quiet (cdr next)))
      (setq taskjuggler--tj3d-refresh-in-flight next-abs)
      (condition-case err
          (taskjuggler--tj3d-add-project-run next-abs next-quiet)
        (error
         (setq taskjuggler--tj3d-refresh-in-flight nil)
         (message "tj3client add launch failed for %s: %s"
                  (file-name-nondirectory next-abs)
                  (error-message-string err)))))))

(defun taskjuggler--tj3d-schedule-refresh (tjp quiet)
  "Queue a `tj3client add' refresh for TJP, or start one if idle.
Coalesces by path: if TJP is already in-flight or already queued, the
request is dropped.  QUIET propagates through the sentinel's progress
messages."
  (let ((abs (expand-file-name tjp)))
    (cond
     ((equal abs taskjuggler--tj3d-refresh-in-flight) nil)
     ((assoc abs taskjuggler--tj3d-refresh-queue) nil)
     (taskjuggler--tj3d-refresh-in-flight
      (setq taskjuggler--tj3d-refresh-queue
            (append taskjuggler--tj3d-refresh-queue
                    (list (cons abs quiet)))))
     (t
      (setq taskjuggler--tj3d-refresh-in-flight abs)
      (taskjuggler--tj3d-add-project-run abs quiet)))))

(defun taskjuggler-tj3d-add-project ()
  "Add the current project to the running tj3d daemon.
Uses `tj3client add' with the .tjp file for the current buffer.
Serialized through a shared queue so concurrent invocations (e.g.
manual add during a save-triggered refresh) don't race on the
`*tj3client*' buffer."
  (interactive)
  (unless (taskjuggler--tj3d-alive-p)
    (user-error "Process tj3d is not running; start it with `taskjuggler-tj3d-start'"))
  (let ((tjp (taskjuggler--find-tjp-file)))
    (unless tjp
      (user-error "No .tjp file found for the current buffer"))
    (taskjuggler--tj3d-schedule-refresh tjp nil)))

(defun taskjuggler--tj3d-refresh-on-save ()
  "Schedule a tj3d refresh when this buffer's project is tracked.
Runs from `after-save-hook'.  Cheap: no subprocess probe — just a hash
lookup in `taskjuggler--tj3d-tracked-projects'.  The refresh itself
runs asynchronously through the shared queue, which coalesces by path
so rapid saves don't pile up redundant `tj3client add' runs."
  (let ((tjp (taskjuggler--find-tjp-file)))
    (when (and tjp (gethash (expand-file-name tjp)
                            taskjuggler--tj3d-tracked-projects))
      (taskjuggler--tj3d-schedule-refresh tjp t))))

(defun taskjuggler--tj3-project-id (tjp)
  "Return the project ID declared in TJP, or nil if none found.
Reads from a buffer visiting TJP when available; otherwise reads the
file from disk.  Matches the first toplevel `project <id>' statement."
  (when (stringp tjp)
    (let ((source (or (find-buffer-visiting tjp) tjp))
          (pattern "^[ \t]*project[ \t]+\\([A-Za-z_][A-Za-z0-9_.-]*\\)"))
      (taskjuggler--with-source-buffer source
        (when (re-search-forward pattern nil t)
          (match-string-no-properties 1))))))

(defun taskjuggler--tj3d-project-loaded-p (tjp)
  "Return non-nil if TJP is already loaded in the running tj3d daemon.
`tj3client status' lists projects by the ID declared inside the .tjp
\(not by filename), so we extract the ID and look for it in the Project
ID column of the status table."
  (when (and tjp (taskjuggler--tj3d-alive-p))
    (let ((pid (taskjuggler--tj3-project-id tjp)))
      (when pid
        (condition-case nil
            (with-temp-buffer
              (when (zerop (call-process
                            (taskjuggler--tj3-executable "tj3client")
                            nil t nil taskjuggler--tj3-no-color "status"))
                (goto-char (point-min))
                (re-search-forward
                 (concat "^[ \t]*[0-9]+[ \t]*|[ \t]*"
                         (regexp-quote pid)
                         "[ \t]*|")
                 nil t)))
          (error nil))))))

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

(defun taskjuggler--tj3webd-pidfile (port)
  "Return the absolute path of the pidfile we ask tj3webd to write for PORT.
Lives under `user-emacs-directory' so it's user-owned (avoiding the
spoofing surface a world-writable /tmp pidfile would have).
Uses `expand-file-name' rather than `locate-user-emacs-file' because the
latter abbreviates HOME back to a tilde for display, and tj3webd's Ruby
daemon treats any path not starting with `/' as relative to its working
directory — handing it the unexpanded form would silently write the
pidfile under the project tree instead."
  (expand-file-name (format "taskjuggler-tj3webd-%d.pid" port)
                    user-emacs-directory))

(defun taskjuggler--tj3webd-pidfile-pid (port)
  "Return the live PID recorded in the pidfile for PORT, or nil.
Deletes a stale pidfile (file present but PID no longer running) and
returns nil so callers don't signal a stranger that recycled the PID."
  (let ((file (taskjuggler--tj3webd-pidfile port)))
    (when (file-readable-p file)
      (let ((pid (with-temp-buffer
                   (insert-file-contents file)
                   (string-to-number (string-trim (buffer-string))))))
        (cond
         ((<= pid 0)
          (delete-file file) nil)
         ((condition-case nil
              (progn (signal-process pid 0) t)
            (error nil))
          pid)
         (t (delete-file file) nil))))))

(defun taskjuggler-tj3webd-start ()
  "Start the tj3webd web daemon from the current project directory.
The daemon forks into the background automatically.
Uses `taskjuggler-tj3webd-port' for the port number, and asks the
daemon to write its PID to `taskjuggler--tj3webd-pidfile' so
`taskjuggler-tj3webd-stop' can find it without scanning ports."
  (interactive)
  (if (taskjuggler--tj3webd-alive-p)
      (message "tj3webd is already running on port %d"
               taskjuggler-tj3webd-port)
    (let* ((tjp (taskjuggler--find-tjp-file))
           (default-directory (if tjp (file-name-directory tjp)
                                 default-directory))
           (cmd (taskjuggler--tj3-executable "tj3webd"))
           (pidfile (taskjuggler--tj3webd-pidfile
                     taskjuggler-tj3webd-port)))
      (call-process cmd nil nil nil
                    "--webserver-port"
                    (number-to-string taskjuggler-tj3webd-port)
                    "--pidfile" pidfile)
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
     :command (list cmd taskjuggler--tj3-no-color "status")
     :noquery t
     :filter #'taskjuggler--tj3-process-filter
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

(defun taskjuggler-tj3d-stop ()
  "Stop the running tj3d daemon via `tj3client terminate'.
Also clears the session's tracked-projects and pending refresh queue,
since neither is meaningful after the daemon goes away."
  (interactive)
  (unless (taskjuggler--tj3d-alive-p)
    (user-error "Process tj3d is not running"))
  (call-process (taskjuggler--tj3-executable "tj3client")
                nil nil nil taskjuggler--tj3-no-color "terminate")
  (clrhash taskjuggler--tj3d-tracked-projects)
  (setq taskjuggler--tj3d-refresh-queue nil)
  (taskjuggler--daemon-update-modeline)
  (message "tj3d stopped"))

(defun taskjuggler-tj3webd-stop ()
  "Stop the running tj3webd daemon by sending SIGTERM to its recorded PID.
SIGTERM is the daemon's documented graceful-shutdown path: tj3webd's
`WebServer' installs a TERM handler that closes SSE pipes and shuts
WEBrick down cleanly.  The PID is read from the pidfile we asked
tj3webd to write at start time (see `taskjuggler-tj3webd-start');
when the pidfile is missing or stale, tj3webd was started outside
this Emacs session and the user must stop it manually."
  (interactive)
  (unless (taskjuggler--tj3webd-alive-p)
    (user-error "Process tj3webd is not running"))
  (let ((pid (taskjuggler--tj3webd-pidfile-pid
              taskjuggler-tj3webd-port)))
    (unless pid
      (user-error
       "No tj3webd pidfile for port %d; was it started outside Emacs?"
       taskjuggler-tj3webd-port))
    (signal-process pid 'SIGTERM))
  (taskjuggler--daemon-update-modeline)
  (message "tj3webd stopped"))

(defun taskjuggler--stop-daemons ()
  "Stop tj3d and tj3webd if they are running.
Registered on `kill-emacs-hook' so daemons do not outlive the Emacs session."
  (condition-case nil
      (when (taskjuggler--tj3d-alive-p)
        (taskjuggler-tj3d-stop))
    (error nil))
  (condition-case nil
      (when (taskjuggler--tj3webd-alive-p)
        (taskjuggler-tj3webd-stop))
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

(provide 'taskjuggler-mode-daemon)

;;; taskjuggler-mode-daemon.el ends here
