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

(provide 'taskjuggler-mode-test-helpers)

;;; taskjuggler-mode-test-helpers.el ends here
