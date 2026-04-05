;;; taskjuggler-mode-test.el --- ERT tests for taskjuggler-mode  -*- lexical-binding: t -*-

;; Tests for taskjuggler--full-task-id-at-point and supporting functions.
;; Run with: emacs --batch -l test/taskjuggler-mode-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(load (expand-file-name "../taskjuggler-mode.el"
                        (file-name-directory (or load-file-name buffer-file-name))))

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

;;; Tests: nil cases

(ert-deftest taskjuggler-full-task-id--nil-at-top-level ()
  "Returns nil when point is between top-level blocks."
  (with-temp-buffer
    (insert test-tjp-content)
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    ;; Position point on the blank line between `project' and `resource'.
    (goto-char (point-min))
    (re-search-forward "^$")           ; first blank line after project block
    (should (null (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--nil-in-project-block ()
  "Returns nil when point is inside a `project' block."
  (with-tjp-at-mark "# IN-PROJECT"
    (should (null (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--nil-in-resource-block ()
  "Returns nil when point is inside a `resource' block."
  (with-tjp-at-mark "# IN-RESOURCE"
    (should (null (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--nil-in-taskreport-block ()
  "Returns nil when point is inside a `taskreport' block."
  (with-tjp-at-mark "# IN-REPORT"
    (should (null (taskjuggler--full-task-id-at-point)))))

;;; Tests: single-level task

(ert-deftest taskjuggler-full-task-id--top-level-task-body ()
  "Returns the task id when point is in a top-level task body (not nested)."
  (with-tjp-at-mark "# IN-OUTER"
    (should (equal "outer" (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--on-task-header-line ()
  "Returns the task id when point is on the `task' keyword line itself."
  (with-tjp-at-mark "task outer"
    ;; Point is now right after the match, still on the `task outer' line.
    (beginning-of-line)
    (should (equal "outer" (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--hyphenated-id ()
  "Returns the full id when the task identifier contains a hyphen."
  (with-tjp-at-mark "# IN-HYPHEN"
    (should (equal "my-task" (taskjuggler--full-task-id-at-point)))))

;;; Tests: multi-level nesting

(ert-deftest taskjuggler-full-task-id--two-levels ()
  "Returns the dotted path for a task nested one level deep."
  (with-tjp-at-mark "# IN-MIDDLE"
    (should (equal "outer.middle" (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--three-levels ()
  "Returns the dotted path for a task nested two levels deep."
  (with-tjp-at-mark "# IN-INNER"
    (should (equal "outer.middle.inner" (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-full-task-id--on-nested-task-header-line ()
  "Returns the dotted path when point is on the header line of a nested task."
  (with-tjp-at-mark "task middle"
    (beginning-of-line)
    (should (equal "outer.middle" (taskjuggler--full-task-id-at-point)))))

;;; Regression: # comments containing { must not corrupt block detection

(ert-deftest taskjuggler-full-task-id--hash-comment-with-brace ()
  "A # comment containing { must not be counted as a block opener.
If syntax-propertize has not yet run for the comment line, scan-lists
would miscount depth and taskjuggler--current-block-header would return nil.
Using syntax-ppss (which always propertizes first) avoids this."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n"
            "  # This comment has a { brace in it\n"
            "  task inner \"Inner\" {\n"
            "    # IN-INNER-COMMENT-BRACE\n"
            "  }\n"
            "}\n")
    (taskjuggler-mode)
    ;; Deliberately do NOT call syntax-propertize here, simulating a buffer
    ;; region that has not yet been propertized by fontification.
    (goto-char (point-min))
    (re-search-forward "# IN-INNER-COMMENT-BRACE")
    (should (equal "outer.inner" (taskjuggler--full-task-id-at-point)))))

;;; Regression: sibling block preceding parent must not appear in path

(ert-deftest taskjuggler-full-task-id--sibling-not-included-in-path ()
  "A closed sibling block must not appear in the task id path.
Regression test: up-list could land on a sibling's { when scanning
backward past its balanced braces."
  (with-tjp-at-mark "# IN-CHILD-WITH-SIBLING"
    (should (equal "top.parent.child"
                   (taskjuggler--full-task-id-at-point)))))

;;; Tests: helper function taskjuggler--block-header-task-id

(ert-deftest taskjuggler-block-header-task-id--task-keyword ()
  "Extracts the id from a `task' header line."
  (with-temp-buffer
    (insert "task my-task \"My Task\" {\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (equal "my-task" (taskjuggler--block-header-task-id (point))))))

(ert-deftest taskjuggler-block-header-task-id--non-task-keyword ()
  "Returns nil for non-`task' block keywords."
  (with-temp-buffer
    (insert "resource dev \"Developer\" {\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (null (taskjuggler--block-header-task-id (point))))))

(ert-deftest taskjuggler-block-header-task-id--indented-task ()
  "Handles leading whitespace on a nested task header line."
  (with-temp-buffer
    (insert "  task inner \"Inner\" {\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (equal "inner" (taskjuggler--block-header-task-id (point))))))

;;; Tests: indentation — taskjuggler--calculate-indent

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
  "Return `taskjuggler--calculate-indent' for line N (1-based) in current buffer."
  (goto-char (point-min))
  (forward-line (1- n))
  (taskjuggler--calculate-indent))

(ert-deftest taskjuggler-indent--top-level ()
  "Top-level lines (depth 0) indent to column 0."
  (with-indent-buffer "task foo \"Foo\" {\n}\n"
    (should (= 0 (indent-at-line 1)))))

(ert-deftest taskjuggler-indent--inside-one-brace ()
  "A line inside one brace level indents to `taskjuggler-indent-level'."
  (with-indent-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (should (= taskjuggler-indent-level (indent-at-line 2)))))

(ert-deftest taskjuggler-indent--inside-two-braces ()
  "A line inside two brace levels indents to 2 × `taskjuggler-indent-level'."
  (with-indent-buffer "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n"
    (should (= (* 2 taskjuggler-indent-level) (indent-at-line 3)))))

(ert-deftest taskjuggler-indent--closing-brace-dedented ()
  "A closing `}' is de-indented one level relative to its contents."
  (with-indent-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    ;; The `}' is at depth 1 in the parse, but should indent to 0.
    (should (= 0 (indent-at-line 3)))))

(ert-deftest taskjuggler-indent--closing-brace-nested ()
  "A nested closing `}' de-indents one level (to indent-level, not 0)."
  (with-indent-buffer "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n"
    (should (= taskjuggler-indent-level (indent-at-line 4)))))

(ert-deftest taskjuggler-indent--continuation-single ()
  "A line after a comma-terminated line aligns with the first argument."
  ;; `columns' starts at column 2 inside the brace, keyword is `columns',
  ;; first arg starts right after the keyword+space.
  (with-indent-buffer "taskreport r \"\" {\n  columns name,\n  id\n}\n"
    ;; Line 3 (`  id') is a continuation.  The anchor is line 2.
    ;; Leading whitespace (2) + keyword `columns' (7) + space (1) = column 10.
    (should (= 10 (indent-at-line 3)))))

(ert-deftest taskjuggler-indent--continuation-multi-line ()
  "All lines in a multi-line comma continuation align with the first argument."
  (with-indent-buffer "taskreport r \"\" {\n  columns name,\n  start,\n  end\n}\n"
    ;; Lines 3 and 4 are both continuations; both should align to column 10.
    (should (= 10 (indent-at-line 3)))
    (should (= 10 (indent-at-line 4)))))

(ert-deftest taskjuggler-indent--non-continuation-after-non-comma ()
  "A line after a non-comma-terminated line uses depth-based indent."
  (with-indent-buffer "task foo \"Foo\" {\n  effort 5d\n  length 3d\n}\n"
    (should (= taskjuggler-indent-level (indent-at-line 3)))))

;;; Tests: date helpers

(ert-deftest taskjuggler-parse-tj-date--basic ()
  "Parses a plain YYYY-MM-DD date string."
  (should (equal '(2024 3 15) (taskjuggler--parse-tj-date "2024-03-15"))))

(ert-deftest taskjuggler-parse-tj-date--with-time ()
  "Parses a YYYY-MM-DD-HH:MM date string, returning only the date part."
  (should (equal '(2024 3 15) (taskjuggler--parse-tj-date "2024-03-15-09:00"))))

(ert-deftest taskjuggler-parse-tj-date--with-seconds ()
  "Parses a YYYY-MM-DD-HH:MM:SS date string, returning only the date part."
  (should (equal '(2024 12 1) (taskjuggler--parse-tj-date "2024-12-01-09:00:00"))))

(ert-deftest taskjuggler-parse-tj-date--invalid ()
  "Returns nil for strings that are not TJ3 date literals."
  (should (null (taskjuggler--parse-tj-date "not-a-date")))
  (should (null (taskjuggler--parse-tj-date ""))))

(ert-deftest taskjuggler-format-tj-date--basic ()
  "Formats year/month/day into YYYY-MM-DD with zero-padding."
  (should (equal "2024-03-05" (taskjuggler--format-tj-date 2024 3 5))))

(ert-deftest taskjuggler-format-tj-date--round-trip ()
  "parse → format round-trips cleanly."
  (let* ((original "2025-11-30")
         (parsed (taskjuggler--parse-tj-date original))
         (formatted (apply #'taskjuggler--format-tj-date parsed)))
    (should (equal original formatted))))

(ert-deftest taskjuggler-date-bounds-at-point--on-date ()
  "Returns the bounds when point is on a date literal."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024")
    (let ((bounds (taskjuggler--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-03-15"
                     (buffer-substring (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-date-bounds-at-point--before-date ()
  "Returns nil when point is before any date on the line."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (taskjuggler-mode)
    (goto-char (point-min))   ; "s" of "start"
    (should (null (taskjuggler--date-bounds-at-point)))))

(ert-deftest taskjuggler-date-bounds-at-point--no-date ()
  "Returns nil on a line with no date literal."
  (with-temp-buffer
    (insert "effort 5d\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (null (taskjuggler--date-bounds-at-point)))))

(ert-deftest taskjuggler-date-bounds-at-point--at-end-of-date ()
  "Returns bounds when point is at the last character of the date."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024-03-15")
    ;; Point is now just after the date; step back one char to land on "5".
    (backward-char 1)
    (let ((bounds (taskjuggler--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-03-15"
                     (buffer-substring (car bounds) (cdr bounds)))))))

;;; Tests: taskjuggler--block-end

(ert-deftest taskjuggler-block-end--with-brace-body ()
  "Returns the line after the closing `}' for a block with a brace body."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n  effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    ;; block-end should point to the line after `}'.
    (let ((end (taskjuggler--block-end (point-min))))
      ;; The buffer has 3 lines; after `}' is past the last newline (= point-max).
      (should (= (point-max) end)))))

(ert-deftest taskjuggler-block-end--nested-returns-outer-end ()
  "block-end called on the outer header skips the entire nested block."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler--block-end (point-min))))
      (should (= (point-max) end)))))

(ert-deftest taskjuggler-block-end--without-brace-body ()
  "Returns the line after the header for a keyword line with no brace body."
  (with-temp-buffer
    (insert "include \"file.tji\"\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    ;; `include' line has no `{'; block-end should return start of line 2.
    (let ((end (taskjuggler--block-end (point-min))))
      (goto-char (point-min))
      (forward-line 1)
      (should (= (point) end)))))

;;; Tests: taskjuggler--block-with-comments-start

(ert-deftest taskjuggler-block-with-comments-start--no-comment ()
  "Returns the header position when there is no preceding comment."
  (with-temp-buffer
    (insert "\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)  ; header is on line 2
    (let ((header (point)))
      (should (= header (taskjuggler--block-with-comments-start header))))))

(ert-deftest taskjuggler-block-with-comments-start--hash-comment ()
  "A `#' comment line immediately before the header is included."
  (with-temp-buffer
    (insert "# This is a comment\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)  ; header on line 2
    (let ((header (point))
          (comment-start (point-min)))
      (should (= comment-start
                 (taskjuggler--block-with-comments-start header))))))

(ert-deftest taskjuggler-block-with-comments-start--slash-comment ()
  "A `//' comment line immediately before the header is included."
  (with-temp-buffer
    (insert "// line comment\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler--block-with-comments-start header))))))

(ert-deftest taskjuggler-block-with-comments-start--blank-line-stops-scan ()
  "A blank line between a comment and the header prevents inclusion of the comment."
  (with-temp-buffer
    (insert "# detached comment\n\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 2)  ; header on line 3
    (let ((header (point)))
      (should (= header
                 (taskjuggler--block-with-comments-start header))))))

;;; Tests: block navigation

(defmacro with-nav-buffer (content &rest body)
  "Run BODY in a taskjuggler-mode buffer containing CONTENT with point at start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (taskjuggler-mode)
     (syntax-propertize (point-max))
     (goto-char (point-min))
     ,@body))

(ert-deftest taskjuggler-next-block--moves-to-next-sibling ()
  "next-block moves point from the first to the second sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Point starts on `task a'.
    (taskjuggler-next-block)
    (should (looking-at "task b"))))

(ert-deftest taskjuggler-next-block--errors-at-last-sibling ()
  "next-block signals an error when there is no next sibling."
  (with-nav-buffer "task a \"A\" {\n}\n"
    (should-error (taskjuggler-next-block) :type 'user-error)))

(ert-deftest taskjuggler-prev-block--moves-to-prev-sibling ()
  "prev-block moves point from the second to the first sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-prev-block)
    (should (looking-at "task a"))))

(ert-deftest taskjuggler-prev-block--no-move-at-first-sibling ()
  "prev-block does not move point when there is no actual previous sibling.
When the first block in the file has no preceding sibling, calling
prev-block leaves point on the same block header."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Start on `task a' (no previous sibling).
    (let ((pos (point)))
      (taskjuggler-prev-block)
      (should (= pos (point))))))

(ert-deftest taskjuggler-goto-parent--moves-to-enclosing-header ()
  "goto-parent moves point to the header of the enclosing block."
  (with-nav-buffer "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n"
    (re-search-forward "effort")
    (taskjuggler-goto-parent)
    (should (looking-at "[ \t]*task inner"))))

(ert-deftest taskjuggler-goto-parent--errors-at-top-level ()
  "goto-parent signals an error when point is already at the top level."
  (with-nav-buffer "task foo \"Foo\" {\n}\n"
    (should-error (taskjuggler-goto-parent) :type 'user-error)))

(ert-deftest taskjuggler-goto-first-child--moves-to-first-child ()
  "goto-first-child lands on the first direct child block."
  (with-nav-buffer "task parent \"P\" {\n  task child-a \"A\" {\n  }\n  task child-b \"B\" {\n  }\n}\n"
    ;; Point is on `task parent'.
    (taskjuggler-goto-first-child)
    (should (looking-at "[ \t]*task child-a"))))

(ert-deftest taskjuggler-goto-first-child--errors-with-no-children ()
  "goto-first-child signals an error when the block has no child blocks."
  (with-nav-buffer "task leaf \"Leaf\" {\n  effort 1d\n}\n"
    (should-error (taskjuggler-goto-first-child) :type 'user-error)))

;;; Runner

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; taskjuggler-mode-test.el ends here
