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
(require 'subr-x)
(require 'url)

;; Defined in `taskjuggler-mode' proper.
(defvar taskjuggler-mode-tj3webd-port)
(defvar taskjuggler-mode-cursor-idle-delay)
(declare-function taskjuggler-mode--current-block-header "taskjuggler-mode" ())

;; Set by `url-http' as a buffer-local in the response buffer; declared
;; here so the byte-compiler does not flag it as a free variable when
;; we read it inside the async response callback.
(defvar url-http-response-status)

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
;; `taskjuggler-mode--start-cursor-tracking' gets a chance to cancel the
;; prior timers, so the old timers stay scheduled forever against the
;; old buffer.  Checking `list-timers' on a long-lived session shows
;; stacks of them.  They are harmless (the handler checks
;; `buffer-live-p') but accumulate.  Proper fix: mark both refs
;; permanent-local and add a `change-major-mode-hook' entry that calls
;; `taskjuggler-mode--stop-cursor-tracking' before kill-all-local-variables
;; can clear them.

(defvar-local taskjuggler-mode--cursor-idle-timer nil
  "Idle timer that updates cursor position while this buffer is live.")

(defvar-local taskjuggler-mode--click-poll-timer nil
  "Repeating timer that polls for browser clicks regardless of focus.")

(defvar-local taskjuggler-mode--cursor-last-id :unset
  "Last task ID sent/written; :unset before the first update.")

(defvar-local taskjuggler-mode--cursor-last-click-ts 0
  "Last click timestamp acted upon; prevents re-navigating the same click.")

(defvar-local taskjuggler-mode--cursor-api-url nil
  "Base URL for the tj3webd cursor API (e.g. \"http://127.0.0.1:8080\"), or nil.
Non-nil means the /cursor endpoint was reachable when tracking started.")

(defvar-local taskjuggler-mode--cursor-js-file-cache :unset
  "Cached path to js/tj-cursor.js (file:// polling fallback), or nil.
:unset before the first lookup.")

(defvar-local taskjuggler-mode--cursor-request-seq 0
  "Monotonic counter used to mint per-request in-flight tokens.")

(defvar-local taskjuggler-mode--cursor-post-inflight nil
  "Token of the currently in-flight async POST, or nil when idle.
A new POST is suppressed while this is non-nil; the next idle tick will
retry once the callback (or watchdog) clears it.")

(defvar-local taskjuggler-mode--cursor-poll-inflight nil
  "Token of the currently in-flight async GET, or nil when idle.
A new poll is suppressed while this is non-nil.")

(defconst taskjuggler-mode--cursor-async-timeout 5
  "Seconds before an in-flight cursor request is considered wedged.
Past this point a watchdog clears the in-flight token so the next timer
tick can issue a fresh request, even if the underlying `url-retrieve'
callback never fires.")

;; ---- Task ID helpers ----

(defun taskjuggler-mode--block-header-task-id (header-pos)
  "If the line at HEADER-POS is a `task' declaration, return its ID string.
Return nil for any other keyword (resource, project, macro, etc.)."
  (save-excursion
    (goto-char header-pos)
    (when (looking-at "[ \t]*task[ \t]+\\([[:alnum:]_][[:alnum:]_-]*\\)")
      (match-string-no-properties 1))))

(defun taskjuggler-mode--full-task-id-at-point ()
  "Return the full dotted TaskJuggler task ID enclosing point, or nil.
Walks up the brace-nesting hierarchy from the innermost block at point,
collecting the IDs of every ancestor `task' block, and joins them with `.'.
Return nil when point is not inside any `task' block."
  (save-excursion
    (when-let ((header (taskjuggler-mode--current-block-header)))
      (goto-char header)
      ;; Prefer (nth 1 (syntax-ppss)) over up-list: scan-lists can land on
      ;; a sibling's { when scanning backward past balanced pairs.
      (let (ids parent)
        (while (progn
                 (when-let ((id (taskjuggler-mode--block-header-task-id (point))))
                   (push id ids))
                 (setq parent (nth 1 (syntax-ppss))))
          (goto-char parent)
          (beginning-of-line))
        (when ids (string-join ids "."))))))

(defun taskjuggler-mode--goto-task-id (dotted-id)
  "Move point to the `task' declaration for DOTTED-ID.
Search for lines beginning with `task <leaf-id>' and verify the full
dotted hierarchy via `taskjuggler-mode--full-task-id-at-point'.  Return t
on success, nil when no matching declaration is found."
  (let* ((leaf (car (last (split-string dotted-id "\\."))))
         (re (concat "^[ \t]*task[ \t]+" (regexp-quote leaf) "\\b"))
         (target (save-excursion
                   (goto-char (point-min))
                   (catch 'found
                     (while (re-search-forward re nil t)
                       (let ((bol (line-beginning-position)))
                         (when (equal dotted-id
                                      (save-excursion
                                        (goto-char bol)
                                        (taskjuggler-mode--full-task-id-at-point)))
                           (throw 'found bol))))))))
    (when target (goto-char target) t)))

;; ---- API transport (tj3webd /cursor endpoint) ----
;;
;; The probe is synchronous because it runs once at mode init.  The post
;; and poll calls run from timers, so they use async `url-retrieve' with
;; callbacks — a synchronous URL call inside a timer opens a recursive
;; event loop that wedged the live poll timer in long sessions.
;;
;; Per-direction in-flight tokens (a monotonic per-buffer counter) suppress
;; new requests while one is pending, so a slow tj3webd does not pile up
;; requests; the next timer tick re-checks state and retries.  A watchdog
;; clears the in-flight token after `--cursor-async-timeout' seconds in
;; case the callback never fires (network wedge, killed daemon, etc.).

(defmacro taskjuggler-mode--with-cursor-api (path &rest body)
  "Run BODY inside the response buffer of a request to PATH on the cursor API.
Caller binds `url-request-method' (and `-data', `-extra-headers' as needed)
in the surrounding `let'.  Returns the value of BODY, or nil on any error
or when `taskjuggler-mode--cursor-api-url' is nil.  The response buffer is
killed before returning.  Synchronous: only safe outside timer handlers."
  (declare (indent 1))
  `(when taskjuggler-mode--cursor-api-url
     (let ((url-show-status nil))
       (condition-case nil
           (with-current-buffer
               (url-retrieve-synchronously
                (concat taskjuggler-mode--cursor-api-url ,path) t nil 2)
             (unwind-protect (progn ,@body) (kill-buffer)))
         (error nil)))))

(defun taskjuggler-mode--cursor-api-probe ()
  "Probe whether the tj3webd cursor API is reachable.
Return the base URL string (e.g. \"http://127.0.0.1:8080\") on success,
or nil when the endpoint is not available."
  (let* ((base (format "http://127.0.0.1:%d" taskjuggler-mode-tj3webd-port))
         (taskjuggler-mode--cursor-api-url base)
         (url-request-method "GET"))
    (taskjuggler-mode--with-cursor-api "/cursor/state"
      (goto-char (point-min))
      (and (re-search-forward "^HTTP/[0-9.]+ 200" nil t) base))))

(defun taskjuggler-mode--cursor-mint-token ()
  "Return a fresh per-buffer request token (a monotonic integer)."
  (setq taskjuggler-mode--cursor-request-seq
        (1+ taskjuggler-mode--cursor-request-seq)))

(defun taskjuggler-mode--cursor-arm-watchdog (buf var token)
  "Clear BUF's buffer-local VAR after the async timeout if it still equals TOKEN.
Safety net for the case where `url-retrieve' never fires its callback."
  (run-at-time taskjuggler-mode--cursor-async-timeout nil
               (lambda ()
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (when (eq (symbol-value var) token)
                       (set var nil)))))))

(defun taskjuggler-mode--cursor-status-ok-p (status)
  "Return non-nil when `url-retrieve' STATUS plist indicates success."
  (and (not (plist-get status :error))
       (or (null (boundp 'url-http-response-status))
           (null url-http-response-status)
           (and (>= url-http-response-status 200)
                (<  url-http-response-status 300)))))

(defun taskjuggler-mode--cursor-post-api (task-id)
  "Asynchronously POST TASK-ID to the tj3webd /cursor endpoint.
TASK-ID may be a string or nil (clears the cursor).  No-op when the cursor
API is unset or a previous POST is still in flight; in either case the
next idle tick will retry.  On HTTP success the buffer-local
`taskjuggler-mode--cursor-last-id' is updated to TASK-ID."
  (when (and taskjuggler-mode--cursor-api-url
             (null taskjuggler-mode--cursor-post-inflight))
    (let* ((token (taskjuggler-mode--cursor-mint-token))
           (buf (current-buffer))
           (sent task-id)
           (url (concat taskjuggler-mode--cursor-api-url "/cursor"))
           (url-request-method "POST")
           (url-request-extra-headers '(("Content-Type" . "application/json")))
           (url-request-data
            (encode-coding-string
             (json-encode `(("id" . ,(or task-id "")) ("source" . "editor")))
             'utf-8))
           (url-show-status nil))
      (setq taskjuggler-mode--cursor-post-inflight token)
      (taskjuggler-mode--cursor-arm-watchdog
       buf 'taskjuggler-mode--cursor-post-inflight token)
      (condition-case nil
          (url-retrieve
           url
           (lambda (status)
             (let ((ok (taskjuggler-mode--cursor-status-ok-p status)))
               (kill-buffer (current-buffer))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (when (eq taskjuggler-mode--cursor-post-inflight token)
                     (setq taskjuggler-mode--cursor-post-inflight nil)
                     (when ok
                       (setq taskjuggler-mode--cursor-last-id sent)))))))
           nil t t)
        (error (setq taskjuggler-mode--cursor-post-inflight nil))))))

(defun taskjuggler-mode--cursor-poll-api ()
  "Asynchronously poll GET /cursor/state.
On a browser-sourced response, hand the (ID . TS) result to
`taskjuggler-mode--apply-click-result' in the originating buffer.  No-op
when the cursor API is unset or a previous poll is still in flight."
  (when (and taskjuggler-mode--cursor-api-url
             (null taskjuggler-mode--cursor-poll-inflight))
    (let* ((token (taskjuggler-mode--cursor-mint-token))
           (buf (current-buffer))
           (url (concat taskjuggler-mode--cursor-api-url "/cursor/state"))
           (url-request-method "GET")
           (url-show-status nil))
      (setq taskjuggler-mode--cursor-poll-inflight token)
      (taskjuggler-mode--cursor-arm-watchdog
       buf 'taskjuggler-mode--cursor-poll-inflight token)
      (condition-case nil
          (url-retrieve
           url
           (lambda (status)
             (let ((result
                    (and (taskjuggler-mode--cursor-status-ok-p status)
                         (condition-case nil
                             (progn
                               (goto-char (point-min))
                               (when (re-search-forward "\n\n" nil t)
                                 (let ((data (json-read)))
                                   (when (equal (cdr (assq 'source data))
                                                "browser")
                                     (cons (cdr (assq 'id data))
                                           (cdr (assq 'ts data)))))))
                           (error nil)))))
               (kill-buffer (current-buffer))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (when (eq taskjuggler-mode--cursor-poll-inflight token)
                     (setq taskjuggler-mode--cursor-poll-inflight nil)
                     (when result
                       (taskjuggler-mode--apply-click-result result)))))))
           nil t t)
        (error (setq taskjuggler-mode--cursor-poll-inflight nil))))))

;; ---- File transport (js/tj-cursor.js fallback) ----

(defun taskjuggler-mode--cursor-js-file ()
  "Return the path to js/tj-cursor.js, or nil when js/ does not exist.
Used as the file-based fallback when the cursor API is unavailable."
  (when (eq taskjuggler-mode--cursor-js-file-cache :unset)
    (setq taskjuggler-mode--cursor-js-file-cache
          (when-let ((file (buffer-file-name)))
            (let ((js-dir (expand-file-name "js" (file-name-directory file))))
              (when (file-directory-p js-dir)
                (expand-file-name "tj-cursor.js" js-dir))))))
  taskjuggler-mode--cursor-js-file-cache)

(defun taskjuggler-mode--read-file-string (file)
  "Return the contents of FILE as a string, or \"\" on any error."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    (error "")))

(defun taskjuggler-mode--cursor-parse-field (content name)
  "Return the value assigned to window.NAME in tj-cursor.js CONTENT.
Handle quoted string values and bare integer values.  Return a string in
both cases, or nil when NAME is not present in CONTENT."
  (when (string-match
         (concat "window\\." (regexp-quote name)
                 "\\s-*=\\s-*\\(?:\"\\([^\"]*\\)\"\\|\\([0-9]+\\)\\)")
         content)
    (or (match-string 1 content) (match-string 2 content))))

(defun taskjuggler-mode--js-quote (val)
  "Render VAL as a JS literal: a quoted string, or null for nil."
  (if val (format "\"%s\"" val) "null"))

(defun taskjuggler-mode--write-cursor-js (task-id)
  "Write TASK-ID to js/tj-cursor.js as file-based fallback.
Does nothing when js/ does not exist.  On success updates
`taskjuggler-mode--cursor-last-id'."
  (when-let ((js-file (taskjuggler-mode--cursor-js-file)))
    (let ((click-id nil) (click-ts "0"))
      ;; Preserve any prior click record so the browser-side polling
      ;; can still see it; we only own the cursor fields here.
      (when task-id
        (let ((existing (taskjuggler-mode--read-file-string js-file)))
          (setq click-id (taskjuggler-mode--cursor-parse-field existing "_tjClickTaskId")
                click-ts (or (taskjuggler-mode--cursor-parse-field existing "_tjClickTs")
                             "0"))))
      (write-region
       (format (concat "window._tjCursorTaskId = %s;\n"
                       "window._tjCursorTs     = %d;\n"
                       "window._tjClickTaskId  = %s;\n"
                       "window._tjClickTs      = %s;\n")
               (taskjuggler-mode--js-quote task-id)
               (floor (float-time))
               (taskjuggler-mode--js-quote click-id)
               click-ts)
       nil js-file nil 'quiet)
      (setq taskjuggler-mode--cursor-last-id task-id))))

(defun taskjuggler-mode--cursor-poll-file ()
  "Read the click record from js/tj-cursor.js as (ID . TS), or nil.
TS defaults to 0 when missing; ID may be nil if the field is absent."
  (when-let ((js-file (taskjuggler-mode--cursor-js-file)))
    (let* ((content (taskjuggler-mode--read-file-string js-file))
           (ts-str (taskjuggler-mode--cursor-parse-field content "_tjClickTs")))
      (cons (taskjuggler-mode--cursor-parse-field content "_tjClickTaskId")
            (if ts-str (string-to-number ts-str) 0)))))

;; ---- Dispatchers ----

(defun taskjuggler-mode--write-cursor-json (task-id)
  "Send TASK-ID to the cursor API, falling back to js/tj-cursor.js."
  (if taskjuggler-mode--cursor-api-url
      (taskjuggler-mode--cursor-post-api task-id)
    (taskjuggler-mode--write-cursor-js task-id)))

(defun taskjuggler-mode--apply-click-result (result)
  "Navigate to the task in (ID . TS) RESULT when it represents a new click."
  (let ((click-id (car result))
        (click-ts (cdr result)))
    (when (and click-ts (> click-ts taskjuggler-mode--cursor-last-click-ts))
      (setq taskjuggler-mode--cursor-last-click-ts click-ts)
      (when (and click-id (not (string-empty-p click-id))
                 (taskjuggler-mode--goto-task-id click-id))
        (when-let ((win (get-buffer-window (current-buffer) t)))
          (with-selected-window win (recenter)))))))

(defun taskjuggler-mode--maybe-navigate-to-click ()
  "Trigger a click poll: async via the API, sync via the JS file fallback.
The async path navigates from its own callback; the sync path applies
the result inline."
  (if taskjuggler-mode--cursor-api-url
      (taskjuggler-mode--cursor-poll-api)
    (when-let ((result (taskjuggler-mode--cursor-poll-file)))
      (taskjuggler-mode--apply-click-result result))))

;; ---- Lifecycle ----

(defun taskjuggler-mode--cursor-update-if-changed ()
  "Send the task ID at point to the browser if it differs from the last sent.
Skips silently when a previous async POST is still in flight; the next idle
tick will retry once the in-flight slot clears.  `--cursor-last-id' is
updated by the post callback (API path) or by `--write-cursor-js' (file
path), so a dropped or failed send naturally retries on the next tick."
  (let ((id (taskjuggler-mode--full-task-id-at-point)))
    (unless (or taskjuggler-mode--cursor-post-inflight
                (equal id taskjuggler-mode--cursor-last-id))
      (taskjuggler-mode--write-cursor-json id))))

(defun taskjuggler-mode--start-cursor-tracking ()
  "Start cursor tracking for the current buffer.
Probes the tj3webd cursor API; if reachable, uses HTTP for both
directions.  Otherwise falls back to js/tj-cursor.js (if the js/
directory exists).  When neither is available, cursor tracking is
silently skipped.

Uses an idle timer for the editor→browser cursor write (so we only write
when the user stops moving) and a regular repeating timer for the
browser→editor click poll (so clicks are noticed even when Emacs does not
have input focus).  Does nothing when `taskjuggler-mode-cursor-idle-delay'
is nil."
  (when taskjuggler-mode-cursor-idle-delay
    ;; Cancel any existing timers first so re-initialization (e.g. via
    ;; revert-buffer or M-x taskjuggler-mode) does not orphan them.
    (when (timerp taskjuggler-mode--cursor-idle-timer)
      (cancel-timer taskjuggler-mode--cursor-idle-timer))
    (when (timerp taskjuggler-mode--click-poll-timer)
      (cancel-timer taskjuggler-mode--click-poll-timer))
    ;; Decide transport: API first, then js/ file, then nothing.
    (setq taskjuggler-mode--cursor-api-url (taskjuggler-mode--cursor-api-probe))
    (when (or taskjuggler-mode--cursor-api-url (taskjuggler-mode--cursor-js-file))
      (let* ((buf (current-buffer))
             (delay taskjuggler-mode-cursor-idle-delay)
             ;; Wrapper used as the timer FUNCTION; the actual work
             ;; function is passed as the timer's single ARG.
             (in-buffer (lambda (fn)
                          (when (buffer-live-p buf)
                            (with-current-buffer buf (funcall fn))))))
        ;; Editor → Browser: idle timer writes cursor position on quiescence.
        (setq taskjuggler-mode--cursor-idle-timer
              (run-with-idle-timer
               delay t in-buffer #'taskjuggler-mode--cursor-update-if-changed))
        ;; Browser → Editor: repeating timer polls for clicks even when
        ;; Emacs is not focused.
        (setq taskjuggler-mode--click-poll-timer
              (run-with-timer
               delay delay in-buffer #'taskjuggler-mode--maybe-navigate-to-click))))))

(defun taskjuggler-mode--stop-cursor-tracking ()
  "Cancel cursor-tracking timers and clear cursor state.
Drops in-flight tokens so any callbacks that still fire become no-ops,
and resets `--cursor-last-id' so a subsequent restart re-syncs the
browser on the next idle tick."
  (when (timerp taskjuggler-mode--cursor-idle-timer)
    (cancel-timer taskjuggler-mode--cursor-idle-timer)
    (setq taskjuggler-mode--cursor-idle-timer nil))
  (when (timerp taskjuggler-mode--click-poll-timer)
    (cancel-timer taskjuggler-mode--click-poll-timer)
    (setq taskjuggler-mode--click-poll-timer nil))
  (taskjuggler-mode--write-cursor-json nil)
  (setq taskjuggler-mode--cursor-api-url nil
        taskjuggler-mode--cursor-post-inflight nil
        taskjuggler-mode--cursor-poll-inflight nil
        taskjuggler-mode--cursor-last-id :unset))

(defun taskjuggler-mode--reset-cursor-file-cache (&rest _)
  "Reset the cursor file cache in all live `taskjuggler-mode' buffers.
Added to `compilation-finish-functions' so the js/ directory is
re-checked after a compile run that may have created it.
Also re-probes the cursor API, which may have become available
after a compile that started tj3webd."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'taskjuggler-mode)
          (setq taskjuggler-mode--cursor-js-file-cache :unset)
          (unless taskjuggler-mode--cursor-api-url
            (setq taskjuggler-mode--cursor-api-url
                  (taskjuggler-mode--cursor-api-probe))))))))

(provide 'taskjuggler-mode-cursor)

;;; taskjuggler-mode-cursor.el ends here
