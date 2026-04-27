;;; taskjuggler-mode-flymake-test.el --- flymake subsystem tests -*- lexical-binding: t -*-

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

;; taskjuggler-mode--tj3d-owns-current-buffer-p

(ert-deftest taskjuggler-mode-tj3d-owns-current-buffer-p--true-when-loaded ()
  "Returns non-nil when the daemon reports the project as loaded."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-project-loaded-p)
              (lambda (_) t)))
     (with-temp-buffer
       (setq buffer-file-name (expand-file-name "x.tjp"
                                                temporary-file-directory))
       (should (taskjuggler-mode--tj3d-owns-current-buffer-p))))))
(ert-deftest taskjuggler-mode-tj3d-owns-current-buffer-p--true-when-cached-diags ()
  "Returns non-nil when diagnostics were recorded even if not loaded.
This covers the failed-add case where the daemon produced errors but
status doesn't list the project."
  (with-clean-tj3d-state
   (let ((tjp (expand-file-name "x.tjp" temporary-file-directory)))
     (puthash tjp '("dummy") taskjuggler-mode--tj3d-diag-files-by-project)
     (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-project-loaded-p)
                (lambda (_) nil)))
       (with-temp-buffer
         (setq buffer-file-name tjp)
         (should (taskjuggler-mode--tj3d-owns-current-buffer-p)))))))
(ert-deftest taskjuggler-mode-tj3d-owns-current-buffer-p--false-when-neither ()
  "Returns nil when the project is neither loaded nor has cached diags."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-project-loaded-p)
              (lambda (_) nil)))
     (with-temp-buffer
       (setq buffer-file-name (expand-file-name "x.tjp"
                                                temporary-file-directory))
       (should-not (taskjuggler-mode--tj3d-owns-current-buffer-p))))))
;; taskjuggler-mode-tj3d-flymake-backend / taskjuggler-mode-flymake-backend

(ert-deftest taskjuggler-mode-tj3d-flymake-backend--yields-when-not-owned ()
  "Reports nil without inspecting the cache when tj3d does not own the buffer."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-owns-current-buffer-p)
              (lambda () nil)))
     (let (called reported)
       (taskjuggler-mode-tj3d-flymake-backend
        (lambda (diags) (setq called t reported diags)))
       (should called)
       (should (null reported))))))
(ert-deftest taskjuggler-mode-tj3d-flymake-backend--reports-cached-entries ()
  "Cached entries are converted to Flymake diagnostics on the source buffer."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (file (expand-file-name "proj.tjp" dir)))
     (unwind-protect
         (progn
           (write-region "line 1\nline 2\nline 3\n" nil file)
           (puthash (expand-file-name file)
                    (list (list 2 :error "boom"))
                    taskjuggler-mode--tj3d-diagnostics)
           (cl-letf (((symbol-function 'taskjuggler-mode--tj3d-owns-current-buffer-p)
                      (lambda () t)))
             (with-temp-buffer
               (setq buffer-file-name file)
               (insert-file-contents file)
               (let (reported)
                 (taskjuggler-mode-tj3d-flymake-backend
                  (lambda (diags) (setq reported diags)))
                 (should (= 1 (length reported)))
                 (let ((d (car reported)))
                   (should (eq :error (flymake-diagnostic-type d)))
                   (should (equal "boom" (flymake-diagnostic-text d))))))))
       (delete-directory dir t)))))
(ert-deftest taskjuggler-mode-flymake-backend--reports-nil-without-file ()
  "Backend reports nil without spawning a process when buffer has no file."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/tj3"))
            ((symbol-function 'make-process)
             (lambda (&rest _) (error "should not spawn"))))
    (with-temp-buffer
      (let (called reported)
        (taskjuggler-mode-flymake-backend
         (lambda (diags) (setq called t reported diags)))
        (should called)
        (should (null reported))))))
(ert-deftest taskjuggler-mode-flymake-backend--yields-when-tj3d-owns-buffer ()
  "Backend reports nil and skips the subprocess when tj3d owns the buffer."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/tj3"))
            ((symbol-function 'make-process)
             (lambda (&rest _) (error "should not spawn")))
            ((symbol-function 'taskjuggler-mode--tj3d-owns-current-buffer-p)
             (lambda () t)))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "x.tjp"
                                               temporary-file-directory))
      (let (called reported)
        (taskjuggler-mode-flymake-backend
         (lambda (diags) (setq called t reported diags)))
        (should called)
        (should (null reported))))))

;;; Integration tests
;;
;; Run the real `tj3' against fixture files in a throwaway temp dir.
;; Skipped via `ert-skip' unless TASKJUGGLER_BIN_DIR is set.

(defmacro taskjuggler-mode-test--with-tjp-fixture (varname content &rest body)
  "Bind VARNAME to a fresh .tjp file containing CONTENT and run BODY.
Creates a temp dir, writes CONTENT to <dir>/p.tjp, sets `default-directory'
to the temp dir so tj3 report output stays sandboxed, and deletes the
dir on exit."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "tj-flymake-" t))
          (,varname (expand-file-name "p.tjp" dir)))
     (unwind-protect
         (progn
           (with-temp-file ,varname (insert ,content))
           (let ((default-directory (file-name-as-directory dir)))
             ,@body))
       (delete-directory dir t))))

(defun taskjuggler-mode-test--run-flymake-sync (file)
  "Run `taskjuggler-mode-flymake-backend' on FILE and return its diagnostics.
Spins the event loop until the backend's REPORT-FN fires, with a 30s
timeout to avoid hanging the suite if tj3 wedges."
  (let ((buf (find-file-noselect file))
        got reported)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (taskjuggler-mode-flymake-backend
             (lambda (diags) (setq reported diags got t))))
          (with-timeout (30 (error "flymake backend did not report within 30s"))
            (while (not got) (accept-process-output nil 0.1)))
          reported)
      (kill-buffer buf))))

(ert-deftest taskjuggler-mode-flymake-integration--valid-tjp-no-diagnostics ()
  "A well-formed project with a report produces no diagnostics."
  (taskjuggler-mode-test--with-tj3 ("tj3")
    (taskjuggler-mode-test--with-tjp-fixture file
        (concat "project p \"P\" 2024-01-01 +1y {\n}\n"
                "task t \"T\" {\n  duration 1d\n}\n"
                "taskreport r \"r\" {\n  formats html\n}\n")
      (let ((diags (taskjuggler-mode-test--run-flymake-sync file)))
        (should (null diags))))))

(ert-deftest taskjuggler-mode-flymake-integration--malformed-tjp-reports-error ()
  "A syntax error produces an :error diagnostic on the offending line."
  (taskjuggler-mode-test--with-tj3 ("tj3")
    ;; Line 4 has a stray `-' where a string is expected, mirroring the
    ;; tj3 grammar: `task <id> <name> ...' wants a quoted name.
    (taskjuggler-mode-test--with-tjp-fixture file
        "project bad \"Bad\" 2024-01-01 +1y {\n}\n\ntask missing-name\n"
      (let ((diags (taskjuggler-mode-test--run-flymake-sync file)))
        (should diags)
        (should (cl-some
                 (lambda (d) (eq :error (flymake-diagnostic-type d)))
                 diags))))))

(ert-deftest taskjuggler-mode-flymake-integration--diagnostic-anchored-to-source ()
  "The reported diagnostic's buffer is the source buffer for FILE."
  (taskjuggler-mode-test--with-tj3 ("tj3")
    (taskjuggler-mode-test--with-tjp-fixture file
        "project bad \"Bad\" 2024-01-01 +1y {\n}\n\ntask missing-name\n"
      (let* ((buf (find-file-noselect file))
             got reported)
        (unwind-protect
            (progn
              (with-current-buffer buf
                (taskjuggler-mode-flymake-backend
                 (lambda (diags) (setq reported diags got t))))
              (with-timeout (30 (error "flymake backend timeout"))
                (while (not got) (accept-process-output nil 0.1)))
              (should reported)
              (dolist (d reported)
                (should (eq buf (flymake-diagnostic-buffer d)))))
          (kill-buffer buf))))))

(provide 'taskjuggler-mode-flymake-test)

;;; taskjuggler-mode-flymake-test.el ends here
