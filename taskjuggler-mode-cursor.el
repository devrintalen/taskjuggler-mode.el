;;; taskjuggler-mode-cursor.el --- task-at-point sync between Emacs and tj3webd -*- lexical-binding: t -*-

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
;; Two-way cursor tracking between an open .tjp buffer and the tj3webd
;; report server.  Uses the /cursor HTTP endpoint when reachable; falls
;; back to writing js/tj-cursor.js for file:// polling.

;;; Code:

(require 'json)
(require 'url)

;; Defined in `taskjuggler-mode' proper.
(defvar taskjuggler-tj3webd-port)
(defvar taskjuggler-cursor-idle-delay)
(declare-function taskjuggler--current-block-header "taskjuggler-mode" ())

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

(provide 'taskjuggler-mode-cursor)

;;; taskjuggler-mode-cursor.el ends here
