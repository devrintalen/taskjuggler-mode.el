;;; taskjuggler-mode-scenario-test.el --- end-to-end editing-session scenario -*- lexical-binding: t -*-

;;; Code:

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

;;; End-to-end editing-session scenario
;;
;; One opt-in test that walks through a realistic taskjuggler-mode
;; session against a real toolchain:
;;
;;   1. Open a copy of test/tutorial.tjp
;;   2. Start tj3d and tj3webd
;;   3. Add the project to tj3d
;;   4. Sync the cursor (point on a task -> POST -> /cursor/state matches)
;;   5. Look up `task' via tj3man
;;   6. Put point on the project's start date and invoke
;;      `taskjuggler-mode-date-dwim'; the calendar popup appears with
;;      the correct date highlighted, navigate one week down, commit,
;;      observe tj3webd's listing update, then restore the date
;;   7. Insert a syntax error, save, observe the daemon-mode Flymake
;;      backend report it
;;   8. Fix the syntax error, save, observe the diagnostics clear
;;   9. Stop tj3d and tj3webd cleanly
;;
;; Skipped via `ert-skip' unless TASKJUGGLER_BIN_DIR is set.

(ert-deftest taskjuggler-mode-scenario--tutorial-end-to-end ()
  "Drive the full edit/sync/refresh/Flymake/stop loop on tutorial.tjp."
  (taskjuggler-mode-test--with-tj3 ("tj3" "tj3d" "tj3webd" "tj3client" "tj3man")
    (taskjuggler-mode-test--with-fresh-tj3d
      (taskjuggler-mode-test--with-fresh-tj3webd 18090
        (let* ((src (expand-file-name "tutorial.tjp"
                                      taskjuggler-mode-test--here))
               (tjp (expand-file-name "tutorial.tjp" default-directory))
               (base-url (format "http://127.0.0.1:%d"
                                 taskjuggler-mode-tj3webd-port))
               (taskjuggler-mode--cursor-api-url base-url)
               buf)
          (copy-file src tjp t)
          (setq buf (find-file-noselect tjp))
          (unwind-protect
              (with-current-buffer buf

                ;; ---- Step 3: add project to tj3d ----
                (taskjuggler-mode-tj3d-add-project)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 60 "tj3client add to complete")
                (should (taskjuggler-mode--tj3d-project-loaded-p tjp))
                (should (gethash (expand-file-name tjp)
                                 taskjuggler-mode--tj3d-tracked-projects))

                ;; ---- Step 4: cursor syncing ----
                ;; Move point inside `task spec' (a child of AcSo) and
                ;; verify --full-task-id-at-point returns the dotted id,
                ;; then round-trip it through the /cursor endpoint.
                (goto-char (point-min))
                (re-search-forward "^[ \t]+task spec ")
                (let ((task-id (taskjuggler-mode--full-task-id-at-point)))
                  (should (equal "AcSo.spec" task-id))
                  (should (taskjuggler-mode--cursor-post-api task-id))
                  (let ((state (taskjuggler-mode-test--cursor-state base-url)))
                    (should state)
                    (should (equal task-id (cdr (assq 'id state))))
                    (should (equal "editor" (cdr (assq 'source state))))))

                ;; ---- Step 5: tj3man lookup ----
                (taskjuggler-mode-man "task")
                (let ((man-buf (get-buffer "*tj3man*")))
                  (should man-buf)
                  (with-current-buffer man-buf
                    (let ((text (buffer-substring-no-properties
                                 (point-min) (point-max))))
                      (should (string-match-p "^Keyword:[ \t]+task" text))
                      (should (string-match-p "^Purpose:" text)))))

                ;; ---- Step 6: date-dwim, navigate, commit, observe update ----
                ;; Move point onto the project's start date "2002-01-16"
                ;; (line 16, column 42 lands inside the date) and invoke
                ;; `taskjuggler-mode-date-dwim'.  The calendar overlay
                ;; appears with January 2002 / day 16 selected.  Press
                ;; S-<up> to step back one week (-> 2002-01-09), commit
                ;; with RET, save the buffer, and observe tj3webd's
                ;; project listing update from the original date to the
                ;; new one.  Finally, manually restore "2002-01-16" so
                ;; step 7 starts from the original on-disk state.
                ;;
                ;; S-<up> (rather than S-<down>) so the project start
                ;; moves earlier rather than later: tutorial.tjp pins
                ;; `delayed:start 2002-01-20' inside `task start', and
                ;; tj3 rejects any project frame that doesn't contain
                ;; that date.  Moving the start to 2002-01-09 widens the
                ;; frame and keeps the file parseable.
                (should-not taskjuggler-mode--cal-overlay)
                (should-not taskjuggler-mode-cal-active-mode)
                (goto-char (point-min))
                (forward-line 15)        ; line 16, 1-based
                (move-to-column 42)
                (should (equal "2002-01-16"
                               (buffer-substring-no-properties
                                (- (point) 6) (+ (point) 4))))
                (let ((before (taskjuggler-mode-test--http-get
                               (concat base-url
                                       "/taskjuggler?project=acso"
                                       ";report=frame.index"))))
                  (should before)
                  (should (string-match-p "2002-01-16" before)))
                (taskjuggler-mode-date-dwim)
                (should taskjuggler-mode-cal-active-mode)
                (should taskjuggler-mode--cal-overlay)
                (should (= 2002 taskjuggler-mode--cal-year))
                (should (= 1    taskjuggler-mode--cal-month))
                (should (= 16   taskjuggler-mode--cal-day))
                (let ((display (overlay-get taskjuggler-mode--cal-overlay
                                            'before-string)))
                  (should (string-match-p
                           "January 2002" (substring-no-properties display)))
                  (let ((pos (string-match "16" display)))
                    (should pos)
                    (should (eq 'taskjuggler-mode-cal-selected-face
                                (get-text-property pos 'face display)))))
                ;; S-<up> -> `taskjuggler-mode--cal-nav-up': step the
                ;; selection back by one week (16 -> 9).
                (taskjuggler-mode--cal-nav-up)
                (should (= 2002 taskjuggler-mode--cal-year))
                (should (= 1    taskjuggler-mode--cal-month))
                (should (= 9    taskjuggler-mode--cal-day))
                ;; RET -> `taskjuggler-mode--cal-commit': write the new
                ;; date into the buffer and tear down the picker.
                (taskjuggler-mode--cal-commit)
                (should-not taskjuggler-mode-cal-active-mode)
                (should-not taskjuggler-mode--cal-overlay)
                (save-excursion
                  (goto-char (point-min))
                  (forward-line 15)
                  (should (re-search-forward "2002-01-09"
                                             (line-end-position) t)))
                (save-buffer)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 60 "tj3d refresh after committing date change")
                ;; tj3webd polls tj3d for project metadata; allow it a
                ;; beat to refresh its rendered listing.
                (taskjuggler-mode-test--wait-until
                 (lambda ()
                   (let ((html (taskjuggler-mode-test--http-get
                                (concat base-url
                                        "/taskjuggler?project=acso"
                                        ";report=frame.index"))))
                     (and html (string-match-p "2002-01-09" html))))
                 30 "tj3webd listing to reflect the new start date")
                (let ((after (taskjuggler-mode-test--http-get
                              (concat base-url
                                      "/taskjuggler?project=acso"
                                      ";report=frame.index"))))
                  (should after)
                  (should (string-match-p "2002-01-09" after)))
                ;; Manually restore the original date so step 7 starts
                ;; from the same on-disk state as the rest of the
                ;; scenario.
                (goto-char (point-min))
                (re-search-forward "2002-01-09")
                (replace-match "2002-01-16")
                (save-buffer)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 60 "tj3d refresh after restoring original date")

                ;; ---- Step 7: syntax error -> daemon Flymake reports it ----
                (goto-char (point-max))
                (insert "\ntask broken\n")
                (save-buffer)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 60 "tj3d refresh after introducing syntax error")
                (let ((entries (gethash (expand-file-name tjp)
                                        taskjuggler-mode--tj3d-diagnostics)))
                  (should entries)
                  (should (cl-some (lambda (e) (eq :error (nth 1 e)))
                                   entries)))
                (let (reported)
                  (taskjuggler-mode-tj3d-flymake-backend
                   (lambda (diags) (setq reported diags)))
                  (should reported)
                  (should (cl-some (lambda (d)
                                     (eq :error (flymake-diagnostic-type d)))
                                   reported)))

                ;; ---- Step 8: fix the syntax error -> diagnostics clear ----
                ;; Remove the `task broken' line we appended above and save;
                ;; refresh-on-save reruns `tj3client add' against a now-clean
                ;; project, the sentinel clears the cache before parsing the
                ;; (empty) error stream, and Flymake should report nothing.
                (goto-char (point-max))
                (re-search-backward "^task broken$")
                (delete-region (line-beginning-position)
                               (min (1+ (line-end-position)) (point-max)))
                (save-buffer)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 60 "tj3d refresh after fixing syntax error")
                (should-not
                 (cl-some
                  (lambda (e) (eq :error (nth 1 e)))
                  (gethash (expand-file-name tjp)
                           taskjuggler-mode--tj3d-diagnostics)))
                (let (called reported)
                  (taskjuggler-mode-tj3d-flymake-backend
                   (lambda (diags) (setq called t reported diags)))
                  (should called)
                  (should-not
                   (cl-some (lambda (d)
                              (eq :error (flymake-diagnostic-type d)))
                            reported)))

                ;; ---- Step 9: stop daemons cleanly ----
                ;; tj3webd first (no rc-file dependency), then tj3d.
                ;; Wait for tj3d's `--auto-update' reschedule (kicked
                ;; off by the most recent save) to settle before
                ;; terminating; otherwise terminate is queued behind
                ;; the in-progress reschedule and tj3d takes tens of
                ;; seconds to exit.
                (taskjuggler-mode-tj3webd-stop)
                (taskjuggler-mode-test--wait-until
                 (lambda () (not (taskjuggler-mode--tj3webd-alive-p)))
                 5 "tj3webd to stop")
                (should-not (taskjuggler-mode--tj3webd-alive-p))
                (taskjuggler-mode-test--wait-until
                 #'taskjuggler-mode-test--tj3d-idle-p 15
                 "tj3d to become idle before stop")
                (taskjuggler-mode-tj3d-stop)
                (taskjuggler-mode-test--wait-until
                 (lambda () (not (taskjuggler-mode--tj3d-alive-p)))
                 5 "tj3d to stop")
                (should-not (taskjuggler-mode--tj3d-alive-p)))

            ;; ---- Buffer cleanup (daemon cleanup is in the fixture) ----
            (when (buffer-live-p buf)
              (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf))
            (when-let ((mb (get-buffer "*tj3man*"))) (kill-buffer mb))))))))

(provide 'taskjuggler-mode-scenario-test)

;;; taskjuggler-mode-scenario-test.el ends here
