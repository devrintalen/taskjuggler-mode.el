;;; taskjuggler-mode-test-helpers.el --- shared test helpers -*- lexical-binding: t -*-

;; Bootstrap (load-path setup, source load) plus the macros and fixtures
;; shared by all subsystem test files.

(require 'ert)
(require 'cl-lib)
(require 'man)
(require 'flymake)

(defvar taskjuggler-mode-test--here
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the test files.")

;; Add the repo root to `load-path' so `require' finds split sub-files
;; (taskjuggler-mode-cal.el etc.) without needing them already installed.
(add-to-list 'load-path (expand-file-name ".." taskjuggler-mode-test--here))
;; Add the test directory so subsystem test files can `require' each other.
(add-to-list 'load-path taskjuggler-mode-test--here)

(load (expand-file-name "../taskjuggler-mode.el" taskjuggler-mode-test--here))

;;; Helper

;; TJP content used by all tests below.  Each # MARK comment is a unique
;; search target used to position point inside a specific block.
(defconst test-tjp-content
  "project proj \"Project\" 2024-01-01 +1y {
  # IN-PROJECT
}

resource dev \"Developer\" {
  # IN-RESOURCE
}

taskreport report \"\" {
  # IN-REPORT
}

task outer \"Outer\" {
  # IN-OUTER
  task middle \"Middle\" {
    # IN-MIDDLE
    task inner \"Inner\" {
      # IN-INNER
    }
  }
}

task my-task \"Hyphenated\" {
  # IN-HYPHEN
}

task top \"Top\" {
  task sibling \"Sibling\" {
    task sib-a \"Sib A\" {
      length 3d
    }
    task sib-b \"Sib B\" {
      length 5d
    }
    task sib-c \"Sib C\" {
      length 2d
    }
  }
  task parent \"Parent\" {
    task child \"Child\" {
      # IN-CHILD-WITH-SIBLING
    }
  }
}
")
(defmacro with-tjp-at-mark (mark &rest body)
  "Run BODY in a taskjuggler-mode temp buffer with point after MARK.
MARK is a string searched with `re-search-forward'; point is left at
the end of the match so it sits on the line containing the marker."
  (declare (indent 1))
  `(with-temp-buffer
     (insert test-tjp-content)
     (taskjuggler-mode)
     ;; syntax-ppss results depend on propertization having run.
     (syntax-propertize (point-max))
     (goto-char (point-min))
     (re-search-forward ,mark)
     ,@body))
;;; Tests: indentation — taskjuggler-mode--calculate-indent

(defmacro with-indent-buffer (content &rest body)
  "Run BODY in a taskjuggler-mode temp buffer containing CONTENT.
Point starts at the beginning of the buffer.  Propertization is forced
so that syntax-ppss returns correct depth on every line."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (taskjuggler-mode)
     (syntax-propertize (point-max))
     (goto-char (point-min))
     ,@body))
(defun indent-at-line (n)
  "Return `taskjuggler-mode--calculate-indent' for line N (1-based) in current buffer."
  (goto-char (point-min))
  (forward-line (1- n))
  (taskjuggler-mode--calculate-indent))
(defmacro with-clean-tj3d-state (&rest body)
  "Run BODY with tj3d diagnostics, queue, and tracked state freshly bound.
Each invocation gets isolated hash tables and queue variables so tests
don't leak state into one another."
  (declare (indent 0))
  `(let ((taskjuggler-mode--tj3d-diagnostics (make-hash-table :test 'equal))
         (taskjuggler-mode--tj3d-diag-files-by-project (make-hash-table :test 'equal))
         (taskjuggler-mode--tj3d-tracked-projects (make-hash-table :test 'equal))
         (taskjuggler-mode--tj3d-refresh-queue nil)
         (taskjuggler-mode--tj3d-refresh-in-flight nil))
     ,@body))

;;; Integration-test support
;;
;; Tests that exercise the real tj3/tj3d/tj3webd/tj3man binaries are
;; opt-in: they run only when the TASKJUGGLER_BIN_DIR environment
;; variable points at a directory containing the executables.  Unit
;; tests stay isolated and fast; integration tests are skipped via
;; `ert-skip' when the env var is unset.

(defvar taskjuggler-mode-test-bin-dir
  (let ((env (getenv "TASKJUGGLER_BIN_DIR")))
    (when (and env (file-directory-p env))
      (file-name-as-directory (expand-file-name env))))
  "Directory containing real tj3 binaries for integration tests.
Read once at load from the TASKJUGGLER_BIN_DIR environment variable;
nil when the variable is unset or does not name a directory.  When
nil, integration tests skip themselves with `ert-skip' so the unit
suite can still run.")

(defmacro taskjuggler-mode-test--with-tj3 (binaries &rest body)
  "Run BODY with `taskjuggler-mode-tj3-bin-dir' bound for an integration test.
BINARIES is a list of executable name strings (e.g. (\"tj3\" \"tj3man\"))
that the test requires.  Skip the surrounding test via `ert-skip'
when `taskjuggler-mode-test-bin-dir' is unset or any required binary
is missing or non-executable in that directory."
  (declare (indent 1))
  `(progn
     (unless taskjuggler-mode-test-bin-dir
       (ert-skip "TASKJUGGLER_BIN_DIR not set; integration test skipped"))
     (dolist (bin ',binaries)
       (unless (file-executable-p
                (expand-file-name bin taskjuggler-mode-test-bin-dir))
         (ert-skip (format "%s not found in %s" bin
                           taskjuggler-mode-test-bin-dir))))
     (let ((taskjuggler-mode-tj3-bin-dir taskjuggler-mode-test-bin-dir))
       ,@body)))

(defun taskjuggler-mode-test--wait-until (predicate timeout label)
  "Spin the event loop until PREDICATE is non-nil or TIMEOUT elapses.
LABEL is included in the timeout error message.  Polls every 100ms."
  (with-timeout (timeout (error "Timed out waiting for %s" label))
    (while (not (funcall predicate))
      (accept-process-output nil 0.1))))

(defmacro taskjuggler-mode-test--with-fresh-tj3d (&rest body)
  "Start tj3d in a sandbox dir, run BODY, and stop tj3d on exit.
Creates a temp dir with a `.taskjugglerrc' so tj3d/tj3client can
authenticate, binds `default-directory' to that dir for the test body
\(so any .tjp fixtures land alongside the rc file), and tears down
the daemon plus the dir on exit.  Skips the test when tj3d is already
alive — starting a second instance would clash with the user's daemon."
  (declare (indent 0))
  `(progn
     (when (taskjuggler-mode--tj3d-alive-p)
       (ert-skip "tj3d already running; skipping to avoid interfering"))
     (with-clean-tj3d-state
       (let* ((dir (make-temp-file "tj3d-test-" t))
              (default-directory (file-name-as-directory dir)))
         (with-temp-file (expand-file-name ".taskjugglerrc" dir)
           (insert "_global:\n  authKey: tj-mode-test-key\n"))
         (taskjuggler-mode-tj3d-start)
         (unwind-protect
             (progn
               (taskjuggler-mode-test--wait-until
                #'taskjuggler-mode--tj3d-alive-p 10 "tj3d to start")
               ,@body)
           (when (taskjuggler-mode--tj3d-alive-p)
             (ignore-errors (taskjuggler-mode-tj3d-stop))
             (taskjuggler-mode-test--wait-until
              (lambda () (not (taskjuggler-mode--tj3d-alive-p)))
              10 "tj3d to stop"))
           (delete-directory dir t))))))

(defmacro taskjuggler-mode-test--with-fresh-tj3webd (port &rest body)
  "Start tj3webd on PORT, run BODY, and stop on exit.
Skips when the port is already in use (e.g. the user is running their
own tj3webd, or a previous test leaked one)."
  (declare (indent 1))
  `(let ((taskjuggler-mode-tj3webd-port ,port))
     (when (taskjuggler-mode--tj3webd-alive-p)
       (ert-skip (format "Something is already listening on port %d"
                         taskjuggler-mode-tj3webd-port)))
     (taskjuggler-mode-tj3webd-start)
     (unwind-protect
         (progn
           (taskjuggler-mode-test--wait-until
            #'taskjuggler-mode--tj3webd-alive-p 10 "tj3webd to start")
           ,@body)
       (when (taskjuggler-mode--tj3webd-alive-p)
         (ignore-errors (taskjuggler-mode-tj3webd-stop))
         (taskjuggler-mode-test--wait-until
          (lambda () (not (taskjuggler-mode--tj3webd-alive-p)))
          10 "tj3webd to stop"))
       (let ((pidfile (taskjuggler-mode--tj3webd-pidfile
                       taskjuggler-mode-tj3webd-port)))
         (when (file-exists-p pidfile)
           (ignore-errors (delete-file pidfile)))))))

(provide 'taskjuggler-mode-test-helpers)

;;; taskjuggler-mode-test-helpers.el ends here
