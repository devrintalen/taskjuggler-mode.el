;;; taskjuggler-mode-daemon-test.el --- daemon subsystem tests -*- lexical-binding: t -*-

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

;;; Tests: daemon management

(ert-deftest taskjuggler-mode-find-tjp-file--returns-tjp-directly ()
  "Returns the buffer file when visiting a .tjp file."
  (let ((tjp-file (expand-file-name "test.tjp" temporary-file-directory)))
    (with-temp-buffer
      (setq buffer-file-name tjp-file)
      (should (equal tjp-file (taskjuggler-mode--find-tjp-file))))))
(ert-deftest taskjuggler-mode-find-tjp-file--searches-for-tji ()
  "Searches directory for a .tjp file when visiting a .tji file."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "project.tjp" dir))
         (tji (expand-file-name "include.tji" dir)))
    (unwind-protect
        (progn
          (write-region "" nil tjp)
          (write-region "" nil tji)
          (with-temp-buffer
            (setq buffer-file-name tji)
            (setq default-directory (file-name-as-directory dir))
            (should (equal tjp (taskjuggler-mode--find-tjp-file)))))
      (delete-directory dir t))))
(ert-deftest taskjuggler-mode-find-tjp-file--nil-for-other-files ()
  "Returns nil when not visiting a .tjp or .tji file."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/notes.txt")
    (should-not (taskjuggler-mode--find-tjp-file))))
(ert-deftest taskjuggler-mode-find-tjp-file--nil-for-no-file ()
  "Returns nil when the buffer is not visiting a file."
  (with-temp-buffer
    (should-not (taskjuggler-mode--find-tjp-file))))
(ert-deftest taskjuggler-mode-daemon-update-modeline--no-daemons ()
  "Modeline is empty when neither daemon is running."
  (let ((taskjuggler-mode--daemon-modeline "old"))
    (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () nil))
              ((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () nil)))
      (taskjuggler-mode--daemon-update-modeline)
      (should (equal "" taskjuggler-mode--daemon-modeline)))))
(ert-deftest taskjuggler-mode-daemon-update-modeline--tj3d-only ()
  "Modeline shows tj3d icon when only tj3d is running."
  (let ((taskjuggler-mode--daemon-modeline ""))
    (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () t))
              ((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () nil)))
      (taskjuggler-mode--daemon-update-modeline)
      (should (string-match-p "󰙬" taskjuggler-mode--daemon-modeline))
      (should-not (string-match-p "󰒍" taskjuggler-mode--daemon-modeline)))))
(ert-deftest taskjuggler-mode-daemon-update-modeline--tj3webd-only ()
  "Modeline shows tj3webd icon when only tj3webd is running."
  (let ((taskjuggler-mode--daemon-modeline ""))
    (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () nil))
              ((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () t)))
      (taskjuggler-mode--daemon-update-modeline)
      (should (string-match-p "󰒍" taskjuggler-mode--daemon-modeline))
      (should-not (string-match-p "󰙬" taskjuggler-mode--daemon-modeline)))))
(ert-deftest taskjuggler-mode-daemon-update-modeline--both ()
  "Modeline shows both icons when both daemons are running."
  (let ((taskjuggler-mode--daemon-modeline ""))
    (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () t))
              ((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () t)))
      (taskjuggler-mode--daemon-update-modeline)
      (should (string-match-p "󰙬" taskjuggler-mode--daemon-modeline))
      (should (string-match-p "󰒍" taskjuggler-mode--daemon-modeline)))))
;; taskjuggler-mode--tj3-project-id

(ert-deftest taskjuggler-mode-tj3-project-id--from-buffer ()
  "Reads the project ID from a buffer visiting TJP."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (let ((buf (find-file-noselect tjp)))
          (unwind-protect
              (with-current-buffer buf
                (insert "project myproj \"My Project\" 2024-01-01 +1y {\n}\n")
                (should (equal "myproj" (taskjuggler-mode--tj3-project-id tjp))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (delete-directory dir t))))
(ert-deftest taskjuggler-mode-tj3-project-id--from-file ()
  "Reads the project ID from disk when no buffer is visiting TJP."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (progn
          (write-region "project xy.zz \"X\" 2024-01-01 +1y {\n}\n" nil tjp)
          (should (equal "xy.zz" (taskjuggler-mode--tj3-project-id tjp))))
      (delete-directory dir t))))
(ert-deftest taskjuggler-mode-tj3-project-id--no-project ()
  "Returns nil when the file has no project declaration."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (progn
          (write-region "task t \"T\" {\n}\n" nil tjp)
          (should-not (taskjuggler-mode--tj3-project-id tjp)))
      (delete-directory dir t))))
(ert-deftest taskjuggler-mode-tj3-project-id--nil-for-missing-file ()
  "Returns nil when TJP cannot be read."
  (should-not (taskjuggler-mode--tj3-project-id "/no/such/file.tjp")))
;; taskjuggler-mode--tj3d-record-diagnostic / clear-diagnostics-for-project

(ert-deftest taskjuggler-mode-tj3d-record-diagnostic--basic ()
  "Records a diagnostic and tracks the file under the project."
  (with-clean-tj3d-state
   (taskjuggler-mode--tj3d-record-diagnostic "/tmp/p.tjp" 7 :error "msg" "/tmp/p.tjp")
   (should (equal (list (list 7 :error "msg"))
                  (gethash "/tmp/p.tjp" taskjuggler-mode--tj3d-diagnostics)))
   (should (equal (list "/tmp/p.tjp")
                  (gethash "/tmp/p.tjp"
                           taskjuggler-mode--tj3d-diag-files-by-project)))))
(ert-deftest taskjuggler-mode-tj3d-record-diagnostic--relative-resolves-to-tjp-dir ()
  "Relative file paths are expanded against the directory of TJP."
  (with-clean-tj3d-state
   (taskjuggler-mode--tj3d-record-diagnostic "tasks.tji" 3 :warning "warn"
                                        "/tmp/proj/p.tjp")
   (should (gethash "/tmp/proj/tasks.tji" taskjuggler-mode--tj3d-diagnostics))))
(ert-deftest taskjuggler-mode-tj3d-record-diagnostic--dedups-files-list ()
  "Recording two diagnostics on the same file lists it once."
  (with-clean-tj3d-state
   (taskjuggler-mode--tj3d-record-diagnostic "/tmp/p.tjp" 7 :error "a" "/tmp/p.tjp")
   (taskjuggler-mode--tj3d-record-diagnostic "/tmp/p.tjp" 8 :error "b" "/tmp/p.tjp")
   (should (equal (list "/tmp/p.tjp")
                  (gethash "/tmp/p.tjp"
                           taskjuggler-mode--tj3d-diag-files-by-project)))
   (should (= 2 (length (gethash "/tmp/p.tjp"
                                 taskjuggler-mode--tj3d-diagnostics))))))
(ert-deftest taskjuggler-mode-tj3d-clear-diagnostics-for-project--isolates-other-projects ()
  "Clearing TJP-A removes only its files, returns them, and leaves TJP-B intact."
  (with-clean-tj3d-state
   (taskjuggler-mode--tj3d-record-diagnostic "/tmp/a.tjp" 1 :error "x" "/tmp/a.tjp")
   (taskjuggler-mode--tj3d-record-diagnostic "/tmp/inc.tji" 2 :error "y"
                                        "/tmp/a.tjp")
   (taskjuggler-mode--tj3d-record-diagnostic "/tmp/b.tjp" 1 :error "z" "/tmp/b.tjp")
   (let ((cleared (taskjuggler-mode--tj3d-clear-diagnostics-for-project
                   "/tmp/a.tjp")))
     (should (equal (sort (copy-sequence cleared) #'string<)
                    '("/tmp/a.tjp" "/tmp/inc.tji")))
     (should-not (gethash "/tmp/a.tjp" taskjuggler-mode--tj3d-diagnostics))
     (should-not (gethash "/tmp/inc.tji" taskjuggler-mode--tj3d-diagnostics))
     (should-not (gethash "/tmp/a.tjp"
                          taskjuggler-mode--tj3d-diag-files-by-project))
     (should (gethash "/tmp/b.tjp" taskjuggler-mode--tj3d-diagnostics)))))
(ert-deftest taskjuggler-mode-tj3d-clear-diagnostics-for-project--unknown-project ()
  "Returns nil and is harmless when TJP has no recorded diagnostics."
  (with-clean-tj3d-state
   (should-not
    (taskjuggler-mode--tj3d-clear-diagnostics-for-project "/tmp/none.tjp"))))
;; taskjuggler-mode--tj3d-scan-include-lines

(ert-deftest taskjuggler-mode-tj3d-scan-include-lines--from-buffer ()
  "Returns line numbers of include statements matching BASENAME."
  (with-temp-buffer
    (insert "project p \"P\" 2024-01-01 +1y {\n}\n"
            "include \"tasks.tji\"\n"
            "include \"sub/tasks.tji\"\n"
            "include \"resources.tji\"\n")
    (should (equal '(3 4)
                   (taskjuggler-mode--tj3d-scan-include-lines
                    (current-buffer) "tasks.tji")))))
(ert-deftest taskjuggler-mode-tj3d-scan-include-lines--from-file ()
  "Reads the file from disk when SOURCE is a path, not a buffer."
  (let* ((dir (make-temp-file "tj-test-" t))
         (file (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (progn
          (write-region "include \"a.tji\"\ninclude \"b.tji\"\n" nil file)
          (should (equal '(2)
                         (taskjuggler-mode--tj3d-scan-include-lines file "b.tji"))))
      (delete-directory dir t))))
(ert-deftest taskjuggler-mode-tj3d-scan-include-lines--unreadable-returns-nil ()
  "Unreadable file paths yield nil rather than an error."
  (should-not (taskjuggler-mode--tj3d-scan-include-lines "/no/such/file.tjp"
                                                    "x.tji")))
(ert-deftest taskjuggler-mode-tj3d-scan-include-lines--no-matches ()
  "Returns nil when no include statement names BASENAME."
  (with-temp-buffer
    (insert "include \"other.tji\"\n")
    (should-not (taskjuggler-mode--tj3d-scan-include-lines
                 (current-buffer) "missing.tji"))))
;; taskjuggler-mode--tj3d-propagate-to-includers

(ert-deftest taskjuggler-mode-tj3d-propagate-to-includers--records-on-include-line ()
  "Diagnostic on an included file shows up on the include line in TJP."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "proj.tjp" dir))
          (tji (expand-file-name "tasks.tji" dir)))
     (unwind-protect
         (progn
           (write-region (concat "project p \"P\" 2024-01-01 +1y {\n}\n"
                                 "include \"tasks.tji\"\n")
                         nil tjp)
           (write-region "" nil tji)
           (taskjuggler-mode--tj3d-propagate-to-includers tji :error "boom" tjp)
           (let ((entries (gethash tjp taskjuggler-mode--tj3d-diagnostics)))
             (should (= 1 (length entries)))
             (let ((e (car entries)))
               (should (= 3 (nth 0 e)))
               (should (eq :error (nth 1 e)))
               (should (string-match-p "tasks.tji" (nth 2 e)))
               (should (string-match-p "boom" (nth 2 e))))))
       (delete-directory dir t)))))
(ert-deftest taskjuggler-mode-tj3d-propagate-to-includers--skips-self ()
  "Does nothing when CHILD-FILE equals TJP itself."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "p.tjp" dir)))
     (unwind-protect
         (progn
           (write-region "include \"p.tjp\"\n" nil tjp)
           (taskjuggler-mode--tj3d-propagate-to-includers tjp :error "x" tjp)
           (should-not (gethash tjp taskjuggler-mode--tj3d-diagnostics)))
       (delete-directory dir t)))))
;; taskjuggler-mode--tj3d-parse-diagnostics

(ert-deftest taskjuggler-mode-tj3d-parse-diagnostics--records-error-and-warning ()
  "Parses both Error and Warning lines into the diagnostics hash."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "proj.tjp" dir)))
     (unwind-protect
         (progn
           (write-region "project p \"P\" 2024-01-01 +1y {\n}\n" nil tjp)
           (with-temp-buffer
             (insert (format "%s:5: Error: bad syntax\n" tjp))
             (insert (format "%s:9: Warning: smelly\n" tjp))
             (taskjuggler-mode--tj3d-parse-diagnostics tjp))
           (let ((entries (gethash tjp taskjuggler-mode--tj3d-diagnostics)))
             (should (member (list 5 :error "bad syntax") entries))
             (should (member (list 9 :warning "smelly") entries))))
       (delete-directory dir t)))))
(ert-deftest taskjuggler-mode-tj3d-parse-diagnostics--propagates-include-errors ()
  "Errors in an included .tji also annotate the include line in TJP."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "proj.tjp" dir))
          (tji (expand-file-name "tasks.tji" dir)))
     (unwind-protect
         (progn
           (write-region (concat "project p \"P\" 2024-01-01 +1y {\n}\n"
                                 "include \"tasks.tji\"\n")
                         nil tjp)
           (write-region "" nil tji)
           (with-temp-buffer
             (insert (format "%s:1: Error: child broke\n" tji))
             (taskjuggler-mode--tj3d-parse-diagnostics tjp))
           (should (gethash tji taskjuggler-mode--tj3d-diagnostics))
           (let ((tjp-entries (gethash tjp taskjuggler-mode--tj3d-diagnostics)))
             (should (= 1 (length tjp-entries)))
             (should (= 3 (nth 0 (car tjp-entries))))
             (should (string-match-p "tasks.tji" (nth 2 (car tjp-entries))))))
       (delete-directory dir t)))))
;; taskjuggler-mode--tj3d-schedule-refresh

(ert-deftest taskjuggler-mode-tj3d-schedule-refresh--starts-immediately-when-idle ()
  "When nothing is in flight, scheduling kicks off the run synchronously."
  (with-clean-tj3d-state
   (let (calls)
     (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-add-project-run)
                (lambda (tjp quiet) (push (cons tjp quiet) calls))))
       (taskjuggler-mode--tj3d-schedule-refresh "/tmp/proj.tjp" nil)
       (should (equal (expand-file-name "/tmp/proj.tjp")
                      taskjuggler-mode--tj3d-refresh-in-flight))
       (should (equal calls (list (cons (expand-file-name "/tmp/proj.tjp")
                                        nil))))))))
(ert-deftest taskjuggler-mode-tj3d-schedule-refresh--queues-when-other-in-flight ()
  "When a different path is running, the new request goes to the queue."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-add-project-run)
              (lambda (&rest _) nil)))
     (setq taskjuggler-mode--tj3d-refresh-in-flight
           (expand-file-name "/tmp/a.tjp"))
     (taskjuggler-mode--tj3d-schedule-refresh "/tmp/b.tjp" t)
     (should (equal taskjuggler-mode--tj3d-refresh-queue
                    (list (cons (expand-file-name "/tmp/b.tjp") t)))))))
(ert-deftest taskjuggler-mode-tj3d-schedule-refresh--drops-when-same-in-flight ()
  "Re-scheduling the path that's already running is a no-op."
  (with-clean-tj3d-state
   (let (calls)
     (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-add-project-run)
                (lambda (&rest _) (push 'called calls))))
       (setq taskjuggler-mode--tj3d-refresh-in-flight
             (expand-file-name "/tmp/a.tjp"))
       (taskjuggler-mode--tj3d-schedule-refresh "/tmp/a.tjp" t)
       (should (null calls))
       (should (null taskjuggler-mode--tj3d-refresh-queue))))))
(ert-deftest taskjuggler-mode-tj3d-schedule-refresh--drops-when-already-queued ()
  "Re-scheduling a path already in the queue is a no-op."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-add-project-run)
              (lambda (&rest _) nil)))
     (setq taskjuggler-mode--tj3d-refresh-in-flight
           (expand-file-name "/tmp/a.tjp"))
     (setq taskjuggler-mode--tj3d-refresh-queue
           (list (cons (expand-file-name "/tmp/b.tjp") t)))
     (taskjuggler-mode--tj3d-schedule-refresh "/tmp/b.tjp" nil)
     (should (= 1 (length taskjuggler-mode--tj3d-refresh-queue))))))
(ert-deftest taskjuggler-mode-tj3d-drain-refresh-queue--launches-next ()
  "Drain pops the next queued entry, sets it in-flight, and launches it."
  (with-clean-tj3d-state
   (let (calls)
     (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-add-project-run)
                (lambda (tjp quiet) (push (cons tjp quiet) calls))))
       (setq taskjuggler-mode--tj3d-refresh-queue
             (list (cons "/tmp/next.tjp" t)))
       (taskjuggler-mode--tj3d-drain-refresh-queue)
       (should (equal calls (list (cons "/tmp/next.tjp" t))))
       (should (equal "/tmp/next.tjp" taskjuggler-mode--tj3d-refresh-in-flight))
       (should (null taskjuggler-mode--tj3d-refresh-queue))))))
(ert-deftest taskjuggler-mode-tj3d-drain-refresh-queue--clears-when-empty ()
  "With an empty queue, drain just clears in-flight."
  (with-clean-tj3d-state
   (setq taskjuggler-mode--tj3d-refresh-in-flight "/tmp/whatever.tjp")
   (taskjuggler-mode--tj3d-drain-refresh-queue)
   (should (null taskjuggler-mode--tj3d-refresh-in-flight))))
(ert-deftest taskjuggler-mode-tj3d-drain-refresh-queue--resets-on-launch-failure ()
  "If the next launch errors, in-flight is reset so the queue can recover.
Without this guard, every subsequent schedule for that path would
coalesce against the stuck in-flight value forever."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-add-project-run)
              (lambda (&rest _) (error "fork failed")))
             ((symbol-function 'message) (lambda (&rest _) nil)))
     (setq taskjuggler-mode--tj3d-refresh-queue
           (list (cons "/tmp/doomed.tjp" t)))
     (taskjuggler-mode--tj3d-drain-refresh-queue)
     (should (null taskjuggler-mode--tj3d-refresh-in-flight))
     (should (null taskjuggler-mode--tj3d-refresh-queue)))))
;; taskjuggler-mode-tj3d-add-project / taskjuggler-mode--tj3d-refresh-on-save

(ert-deftest taskjuggler-mode-tj3d-add-project--errors-when-tj3d-not-running ()
  "Interactive add raises a user-error when the daemon is down."
  (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () nil)))
    (with-temp-buffer
      (should-error (taskjuggler-mode-tj3d-add-project) :type 'user-error))))
(ert-deftest taskjuggler-mode-tj3d-add-project--schedules-refresh ()
  "Interactive add delegates to schedule-refresh non-quietly."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "p.tjp" dir))
          calls)
     (unwind-protect
         (progn
           (write-region "" nil tjp)
           (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p)
                      (lambda () t))
                     ((symbol-function 'taskjuggler-mode--tj3d-schedule-refresh)
                      (lambda (p q) (push (list p q) calls))))
             (with-temp-buffer
               (setq buffer-file-name tjp)
               (taskjuggler-mode-tj3d-add-project))
             (should (equal calls (list (list tjp nil))))))
       (delete-directory dir t)))))
(ert-deftest taskjuggler-mode-tj3d-refresh-on-save--schedules-when-tracked ()
  "Save hook schedules a quiet refresh when the project is tracked."
  (with-clean-tj3d-state
   (let* ((tjp (expand-file-name "test.tjp" temporary-file-directory))
          calls)
     (puthash tjp t taskjuggler-mode--tj3d-tracked-projects)
     (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-schedule-refresh)
                (lambda (p q) (push (list p q) calls))))
       (with-temp-buffer
         (setq buffer-file-name tjp)
         (taskjuggler-mode--tj3d-refresh-on-save))
       (should (equal calls (list (list tjp t))))))))
(ert-deftest taskjuggler-mode-tj3d-refresh-on-save--noop-when-not-tracked ()
  "Save hook does nothing when the project was never added."
  (with-clean-tj3d-state
   (let* ((tjp (expand-file-name "untracked.tjp" temporary-file-directory))
          calls)
     (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-schedule-refresh)
                (lambda (p q) (push (list p q) calls))))
       (with-temp-buffer
         (setq buffer-file-name tjp)
         (taskjuggler-mode--tj3d-refresh-on-save))
       (should (null calls))))))
;; taskjuggler-mode--tj3-process-filter

(ert-deftest taskjuggler-mode-tj3-process-filter--carriage-return-overwrites ()
  "Lone CR collapses progress text down to the final line."
  (skip-unless (executable-find "cat"))
  (let* ((buf (generate-new-buffer " *tj-filter-test*"))
         (proc (make-process :name "tj-filter-cat" :buffer buf
                             :command '("cat") :noquery t
                             :connection-type 'pipe)))
    (unwind-protect
        (progn
          (taskjuggler-mode--tj3-process-filter
           proc "progress 10%\rprogress 50%\rprogress 100%\n")
          (with-current-buffer buf
            (let ((s (buffer-string)))
              (should (string-match-p "progress 100%" s))
              (should-not (string-match-p "progress 10%" s))
              (should-not (string-match-p "progress 50%" s)))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))
(ert-deftest taskjuggler-mode-tj3-process-filter--ansi-escapes-removed ()
  "ANSI SGR escapes are stripped (converted to text properties)."
  (skip-unless (executable-find "cat"))
  (let* ((buf (generate-new-buffer " *tj-filter-test*"))
         (proc (make-process :name "tj-filter-cat" :buffer buf
                             :command '("cat") :noquery t
                             :connection-type 'pipe)))
    (unwind-protect
        (progn
          (taskjuggler-mode--tj3-process-filter proc "\e[31mred\e[0m text\n")
          (with-current-buffer buf
            (let ((s (buffer-string)))
              (should-not (string-match-p "\e\\[" s))
              (should (string-match-p "red text" s)))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))
;; taskjuggler-mode-tj3d-stop / taskjuggler-mode-tj3webd-stop

(ert-deftest taskjuggler-mode-tj3d-stop--errors-when-not-running ()
  "Stop command signals a user-error if tj3d isn't running."
  (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () nil)))
    (should-error (taskjuggler-mode-tj3d-stop) :type 'user-error)))
(ert-deftest taskjuggler-mode-tj3d-stop--clears-tracked-and-queue ()
  "Stop terminates the daemon and clears tracked-projects + queue."
  (with-clean-tj3d-state
   (puthash "/tmp/x.tjp" t taskjuggler-mode--tj3d-tracked-projects)
   (setq taskjuggler-mode--tj3d-refresh-queue (list (cons "/tmp/y.tjp" nil)))
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-alive-p) (lambda () t))
             ((symbol-function 'call-process) (lambda (&rest _) 0))
             ((symbol-function 'taskjuggler-mode--daemon-update-modeline)
              (lambda () nil)))
     (taskjuggler-mode-tj3d-stop)
     (should (zerop (hash-table-count taskjuggler-mode--tj3d-tracked-projects)))
     (should (null taskjuggler-mode--tj3d-refresh-queue)))))
(ert-deftest taskjuggler-mode-tj3webd-stop--errors-when-not-running ()
  "Stop command signals a user-error if tj3webd isn't running."
  (cl-letf (((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () nil)))
    (should-error (taskjuggler-mode-tj3webd-stop) :type 'user-error)))
(ert-deftest taskjuggler-mode-tj3webd-stop--errors-when-pidfile-missing ()
  "Stop command errors when no pidfile is recorded for the port."
  (cl-letf (((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () t))
            ((symbol-function 'taskjuggler-mode--tj3webd-pidfile-pid)
             (lambda (_) nil))
            ((symbol-function 'taskjuggler-mode--daemon-update-modeline)
             (lambda () nil)))
    (should-error (taskjuggler-mode-tj3webd-stop) :type 'user-error)))
(ert-deftest taskjuggler-mode-tj3webd-stop--signals-recorded-pid ()
  "Stop reads the pidfile and sends SIGTERM to that PID."
  (let (signalled)
    (cl-letf (((symbol-function 'taskjuggler-mode--tj3webd-alive-p) (lambda () t))
              ((symbol-function 'taskjuggler-mode--tj3webd-pidfile-pid)
               (lambda (_) 4242))
              ((symbol-function 'signal-process)
               (lambda (pid sig) (push (cons pid sig) signalled)))
              ((symbol-function 'taskjuggler-mode--daemon-update-modeline)
               (lambda () nil)))
      (taskjuggler-mode-tj3webd-stop)
      (should (equal signalled (list (cons 4242 'SIGTERM)))))))
(ert-deftest taskjuggler-mode-tj3webd-pidfile-pid--returns-live-pid ()
  "Helper returns the PID when it's a live process."
  (let* ((dir (make-temp-file "tj-test-" t))
         (port 18080)
         (file (expand-file-name (format "taskjuggler-mode-tj3webd-%d.pid" port)
                                 dir))
         (live-pid (emacs-pid)))
    (unwind-protect
        (progn
          (write-region (number-to-string live-pid) nil file)
          (cl-letf (((symbol-function 'taskjuggler-mode--tj3webd-pidfile)
                     (lambda (_) file)))
            (should (equal live-pid
                           (taskjuggler-mode--tj3webd-pidfile-pid port))))
          (should (file-exists-p file)))
      (delete-directory dir t))))
(ert-deftest taskjuggler-mode-tj3webd-pidfile-pid--cleans-stale-pidfile ()
  "Helper deletes a stale pidfile (PID not running) and returns nil.
Uses PID 0 — `signal-process' rejects it as out-of-range, which the
helper treats the same as a stale entry."
  (let* ((dir (make-temp-file "tj-test-" t))
         (port 18081)
         (file (expand-file-name (format "taskjuggler-mode-tj3webd-%d.pid" port)
                                 dir)))
    (unwind-protect
        (progn
          (write-region "0\n" nil file)
          (cl-letf (((symbol-function 'taskjuggler-mode--tj3webd-pidfile)
                     (lambda (_) file)))
            (should-not (taskjuggler-mode--tj3webd-pidfile-pid port)))
          (should-not (file-exists-p file)))
      (when (file-exists-p dir) (delete-directory dir t)))))
(ert-deftest taskjuggler-mode-tj3webd-pidfile-pid--missing-file-returns-nil ()
  "Helper returns nil with no side effects when the pidfile doesn't exist."
  (cl-letf (((symbol-function 'taskjuggler-mode--tj3webd-pidfile)
             (lambda (_) "/no/such/pidfile")))
    (should-not (taskjuggler-mode--tj3webd-pidfile-pid 18082))))
(ert-deftest taskjuggler-mode-tj3webd-pidfile--returns-fully-expanded-path ()
  "Pidfile path must be `/'-rooted with no literal `~' segment.
Regression: `locate-user-emacs-file' abbreviates HOME back to `~',
which tj3webd's daemon then treats as a relative path and prepends
its cwd to."
  (let ((user-emacs-directory "~/.emacs.d/"))
    (let ((path (taskjuggler-mode--tj3webd-pidfile 8080)))
      (should (file-name-absolute-p path))
      (should (string-prefix-p "/" path))
      (should-not (string-match-p "/~/" path))
      (should-not (string-match-p "/~$" path)))))

;;; Integration tests
;;
;; Spin up real tj3d and tj3webd daemons and exercise the lifecycle.
;; Skipped via `ert-skip' unless TASKJUGGLER_BIN_DIR is set, plus an
;; additional skip for tj3d when one is already running for the user
;; (tj3d binds a per-user unix socket, so starting a second one would
;; fail and disrupt the user's existing session).
;;
;; Shared fixtures (`taskjuggler-mode-test--with-fresh-tj3d',
;; `taskjuggler-mode-test--with-fresh-tj3webd', and
;; `taskjuggler-mode-test--wait-until') live in
;; `taskjuggler-mode-test-helpers.el'.

;; ---- tj3d ----

(ert-deftest taskjuggler-mode-tj3d-integration--start-stop ()
  "`tj3d-start' brings the daemon up; `tj3d-stop' brings it down."
  (taskjuggler-mode-test--with-tj3 ("tj3d" "tj3client")
    (taskjuggler-mode-test--with-fresh-tj3d
      (should (taskjuggler-mode--tj3d-alive-p))
      (taskjuggler-mode-tj3d-stop)
      (taskjuggler-mode-test--wait-until
       (lambda () (not (taskjuggler-mode--tj3d-alive-p)))
       10 "tj3d to stop")
      (should-not (taskjuggler-mode--tj3d-alive-p)))))

(ert-deftest taskjuggler-mode-tj3d-integration--add-project-tracks ()
  "`tj3d-add-project' loads a TJP into the daemon and records it as tracked."
  (taskjuggler-mode-test--with-tj3 ("tj3d" "tj3client")
    (taskjuggler-mode-test--with-fresh-tj3d
      (let ((tjp (expand-file-name "p.tjp" default-directory)))
        (with-temp-file tjp
          (insert "project p \"P\" 2024-01-01 +1y {\n}\n"
                  "task t \"T\" {\n  duration 1d\n}\n"
                  "taskreport r \"r\" {\n  formats html\n}\n"))
        (let ((buf (find-file-noselect tjp)))
          (unwind-protect
              (with-current-buffer buf
                (taskjuggler-mode-tj3d-add-project)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 30 "tj3client add to complete")
                (should (gethash (expand-file-name tjp)
                                 taskjuggler-mode--tj3d-tracked-projects))
                (should (taskjuggler-mode--tj3d-project-loaded-p tjp)))
            (kill-buffer buf)))))))

(ert-deftest taskjuggler-mode-tj3d-integration--add-malformed-records-diagnostics ()
  "Adding a malformed TJP populates the diagnostic cache for that file."
  (taskjuggler-mode-test--with-tj3 ("tj3d" "tj3client")
    (taskjuggler-mode-test--with-fresh-tj3d
      (let ((tjp (expand-file-name "bad.tjp" default-directory)))
        (with-temp-file tjp
          (insert "project bad \"Bad\" 2024-01-01 +1y {\n}\n\n"
                  "task missing-name\n"))
        (let ((buf (find-file-noselect tjp)))
          (unwind-protect
              (with-current-buffer buf
                (taskjuggler-mode-tj3d-add-project)
                (taskjuggler-mode-test--wait-until
                 (lambda () (null taskjuggler-mode--tj3d-refresh-in-flight))
                 30 "tj3client add to complete")
                (let ((entries (gethash (expand-file-name tjp)
                                        taskjuggler-mode--tj3d-diagnostics)))
                  (should entries)
                  (should (cl-some (lambda (e) (eq :error (nth 1 e)))
                                   entries))))
            (kill-buffer buf)))))))

;; ---- tj3webd ----

(ert-deftest taskjuggler-mode-tj3webd-integration--start-stop ()
  "`tj3webd-start' brings the web daemon up and writes its pidfile."
  (taskjuggler-mode-test--with-tj3 ("tj3webd")
    ;; Use a non-default port so we never collide with the user's own
    ;; tj3webd on 8080.
    (taskjuggler-mode-test--with-fresh-tj3webd 18080
      (should (taskjuggler-mode--tj3webd-alive-p))
      (let ((pidfile (taskjuggler-mode--tj3webd-pidfile 18080)))
        (should (file-readable-p pidfile))
        (should (taskjuggler-mode--tj3webd-pidfile-pid 18080))))))

(ert-deftest taskjuggler-mode-tj3webd-integration--port-reachable ()
  "Once tj3webd is up, the configured port accepts TCP connections."
  (taskjuggler-mode-test--with-tj3 ("tj3webd")
    (taskjuggler-mode-test--with-fresh-tj3webd 18081
      (let ((proc (make-network-process
                   :name "tj3webd-probe-test"
                   :host "127.0.0.1"
                   :service 18081
                   :nowait nil)))
        (should (process-live-p proc))
        (delete-process proc)))))

(provide 'taskjuggler-mode-daemon-test)

;;; taskjuggler-mode-daemon-test.el ends here
