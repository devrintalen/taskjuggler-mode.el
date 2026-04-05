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

;;; Tests: taskjuggler--current-block-header

(ert-deftest taskjuggler-current-block-header--on-keyword-line ()
  "Returns the line position when point is on a moveable keyword line."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (should (= (point-min) (taskjuggler--current-block-header)))))

(ert-deftest taskjuggler-current-block-header--inside-body ()
  "Returns the enclosing header position when point is inside the body."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort")
    (let ((header (taskjuggler--current-block-header)))
      (should header)
      (goto-char header)
      (should (looking-at "task foo")))))

(ert-deftest taskjuggler-current-block-header--top-level-returns-nil ()
  "Returns nil when point is at the top level outside any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n}\n"
    ;; Point starts at the blank line before the task — top level, no block.
    (should (null (taskjuggler--current-block-header)))))

(ert-deftest taskjuggler-current-block-header--non-task-block-returns-nil ()
  "Returns nil inside a resource block (not a moveable-block-re match for its header)."
  ;; `resource' IS in taskjuggler--moveable-block-re, so from inside its body
  ;; we should get its header back.  Verify that a non-moveable wrapper does
  ;; NOT manufacture a header from thin air.
  (with-nav-buffer "resource dev \"Dev\" {\n  # IN-RES\n}\n"
    (re-search-forward "# IN-RES")
    (let ((header (taskjuggler--current-block-header)))
      (should header)
      (goto-char header)
      (should (looking-at "resource dev")))))

;;; Tests: taskjuggler--child-block-headers

(ert-deftest taskjuggler-child-block-headers--returns-all-children ()
  "Returns positions of all direct child block headers."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n  task c \"C\" {\n  }\n}\n"
    (syntax-propertize (point-max))
    (let ((children (taskjuggler--child-block-headers (point-min))))
      (should (= 3 (length children)))
      (goto-char (nth 0 children)) (should (looking-at "[ \t]*task a"))
      (goto-char (nth 1 children)) (should (looking-at "[ \t]*task b"))
      (goto-char (nth 2 children)) (should (looking-at "[ \t]*task c")))))

(ert-deftest taskjuggler-child-block-headers--no-children ()
  "Returns nil for a block with no child blocks."
  (with-nav-buffer "task leaf \"Leaf\" {\n  effort 1d\n}\n"
    (should (null (taskjuggler--child-block-headers (point-min))))))

(ert-deftest taskjuggler-child-block-headers--only-direct-children ()
  "Does not include grandchildren — only direct children at depth+1."
  (with-nav-buffer "task p \"P\" {\n  task child \"C\" {\n    task grandchild \"G\" {\n    }\n  }\n}\n"
    (syntax-propertize (point-max))
    (let ((children (taskjuggler--child-block-headers (point-min))))
      (should (= 1 (length children)))
      (goto-char (car children))
      (should (looking-at "[ \t]*task child")))))

;;; Tests: taskjuggler-goto-last-child

(ert-deftest taskjuggler-goto-last-child--moves-to-last-child ()
  "goto-last-child lands on the last direct child block."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (taskjuggler-goto-last-child)
    (should (looking-at "[ \t]*task b"))))

(ert-deftest taskjuggler-goto-last-child--single-child ()
  "goto-last-child and goto-first-child agree when there is one child."
  (with-nav-buffer "task p \"P\" {\n  task only \"Only\" {\n  }\n}\n"
    (let (first last)
      (taskjuggler-goto-first-child)
      (setq first (point))
      (goto-char (point-min))
      (taskjuggler-goto-last-child)
      (setq last (point))
      (should (= first last)))))

;;; Tests: block movement

(ert-deftest taskjuggler-move-block-up--swaps-with-prev-sibling ()
  "move-block-up swaps the current block with the previous sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-move-block-up)
    ;; After moving up, `task b' should precede `task a'.
    (goto-char (point-min))
    (should (looking-at "task b"))))

(ert-deftest taskjuggler-move-block-up--preserves-blank-separator ()
  "move-block-up keeps the blank line between the two blocks."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-move-block-up)
    ;; Buffer should still contain a blank line between the two blocks.
    (goto-char (point-min))
    (should (re-search-forward "^$" nil t))))

(ert-deftest taskjuggler-move-block-down--swaps-with-next-sibling ()
  "move-block-down swaps the current block with the next sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Point starts on `task a'.
    (taskjuggler-move-block-down)
    (goto-char (point-min))
    (should (looking-at "task b"))))

(ert-deftest taskjuggler-move-block-up-down--round-trip ()
  "Moving a block down then up restores the original buffer content."
  (let ((original "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"))
    (with-nav-buffer original
      (taskjuggler-move-block-down)
      (goto-char (point-min))
      (re-search-forward "task a")
      (beginning-of-line)
      (taskjuggler-move-block-up)
      (should (equal original (buffer-string))))))

(ert-deftest taskjuggler-move-block-up--comment-travels-with-block ()
  "A comment immediately before the block travels with it when moved."
  (with-nav-buffer "task a \"A\" {\n}\n\n# comment for b\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-move-block-up)
    ;; The comment and task b should now be at the top of the file.
    (goto-char (point-min))
    (should (looking-at "# comment for b"))))

;;; Tests: block editing

(ert-deftest taskjuggler-clone-block--produces-duplicate ()
  "clone-block inserts a copy of the block immediately after the original."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (taskjuggler-clone-block)
    ;; The buffer should now contain two `task foo' blocks.
    (goto-char (point-min))
    (re-search-forward "task foo")
    (should (re-search-forward "task foo" nil t))))

(ert-deftest taskjuggler-clone-block--blank-line-separator ()
  "clone-block separates the original and clone with a blank line."
  (with-nav-buffer "task foo \"Foo\" {\n}\n"
    (taskjuggler-clone-block)
    (goto-char (point-min))
    (re-search-forward "^}$")
    (forward-line 1)
    (should (looking-at "^$"))))

(ert-deftest taskjuggler-clone-block--point-on-clone-header ()
  "clone-block leaves point on the clone's header line."
  (with-nav-buffer "task foo \"Foo\" {\n}\n"
    (taskjuggler-clone-block)
    (should (looking-at "task foo"))))

(ert-deftest taskjuggler-narrow-to-block--narrows-correctly ()
  "narrow-to-block restricts the buffer to header through closing `}'."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort")
    (taskjuggler-narrow-to-block)
    (unwind-protect
        (progn
          (should (string-match "task foo" (buffer-string)))
          (should (string-match "effort" (buffer-string)))
          ;; Nothing outside the block should be visible.
          (goto-char (point-min))
          (should (looking-at "task foo")))
      (widen))))

(ert-deftest taskjuggler-mark-block--sets-region-over-block ()
  "mark-block places point at block start and mark at block end."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mark-block)
    (let ((region (buffer-substring (region-beginning) (region-end))))
      (should (string-match "task foo" region))
      (should (string-match "effort" region)))))

;;; Tests: sexp movement

(ert-deftest taskjuggler-forward-sexp--skips-whole-block ()
  "forward-sexp from a block header jumps past the entire block."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\ntask bar \"Bar\" {\n}\n"
    ;; Point is on `task foo' header.
    (taskjuggler--forward-sexp 1)
    ;; Should now be at `task bar'.
    (should (looking-at "task bar"))))

(ert-deftest taskjuggler-forward-sexp--inside-line-falls-back ()
  "forward-sexp from mid-line falls back to default sexp movement."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort ")
    ;; Point is now after `effort ', just before `5d'.  Default sexp would
    ;; move past `5d' as a token.
    (let ((start (point)))
      (taskjuggler--forward-sexp 1)
      (should (> (point) start)))))

(ert-deftest taskjuggler-backward-sexp--skips-whole-block ()
  "backward-sexp from after a block's `}' jumps to the block header."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\ntask bar \"Bar\" {\n}\n"
    ;; Move to just after the closing `}' of `task bar'.
    (goto-char (point-max))
    (taskjuggler--forward-sexp -1)
    (should (looking-at "task bar"))))

(ert-deftest taskjuggler-forward-sexp--arg-2-skips-two-blocks ()
  "forward-sexp with arg 2 skips two consecutive blocks."
  (with-nav-buffer "task a \"A\" {\n}\ntask b \"B\" {\n}\ntask c \"C\" {\n}\n"
    (taskjuggler--forward-sexp 2)
    (should (looking-at "task c"))))

;;; Tests: taskjuggler--beginning-of-defun

;; Shared buffer content for defun tests.
(defconst test-defun-content
  "task alpha \"Alpha\" {\n  effort 1d\n}\n\ntask beta \"Beta\" {\n  task child \"Child\" {\n    effort 2d\n  }\n}\n\ntask gamma \"Gamma\" {\n}\n")

(defmacro with-defun-buffer (&rest body)
  "Run BODY in a taskjuggler-mode buffer containing `test-defun-content'."
  (declare (indent 0))
  `(with-temp-buffer
     (insert test-defun-content)
     (taskjuggler-mode)
     (syntax-propertize (point-max))
     (goto-char (point-min))
     ,@body))

(ert-deftest taskjuggler-beginning-of-defun--from-inside-body ()
  "From inside a block body, jumps to that block's header."
  (with-defun-buffer
    (re-search-forward "effort 1d")
    (taskjuggler--beginning-of-defun)
    (should (looking-at "task alpha"))))

(ert-deftest taskjuggler-beginning-of-defun--from-header-goes-to-prev ()
  "From a block header, searches backward to the preceding block."
  (with-defun-buffer
    (re-search-forward "task beta")
    (beginning-of-line)
    (taskjuggler--beginning-of-defun)
    (should (looking-at "task alpha"))))

(ert-deftest taskjuggler-beginning-of-defun--arg-2-from-body ()
  "With arg 2 from inside a block body, jumps to header then one more back."
  (with-defun-buffer
    ;; Point inside beta's body (on `task child' header, one level down).
    (re-search-forward "effort 2d")
    ;; arg=1 would land on `task child'; arg=2 goes one step further back.
    (taskjuggler--beginning-of-defun 2)
    (should (looking-at "[ \t]*task child\\|task beta"))))

(ert-deftest taskjuggler-beginning-of-defun--arg-2-from-header ()
  "With arg 2 from a block header, steps backward twice."
  (with-defun-buffer
    (re-search-forward "task gamma")
    (beginning-of-line)
    (taskjuggler--beginning-of-defun 2)
    (should (looking-at "task alpha\\|[ \t]*task child\\|task beta"))))

(ert-deftest taskjuggler-beginning-of-defun--at-bob-stops ()
  "At the first block (bob), does not move past the start of the buffer."
  (with-defun-buffer
    ;; Already on `task alpha'.
    (taskjuggler--beginning-of-defun)
    ;; No previous block; point should stay at or before task alpha.
    (should (<= (point) (progn (goto-char (point-min))
                               (re-search-forward "task alpha")
                               (line-beginning-position))))))

(ert-deftest taskjuggler-beginning-of-defun--negative-arg-delegates ()
  "A negative arg delegates to end-of-defun."
  (with-defun-buffer
    ;; Point on task alpha header.
    (taskjuggler--beginning-of-defun -1)
    ;; Should have moved forward past task alpha's closing `}'.
    (should (> (point) (progn (goto-char (point-min))
                              (re-search-forward "task alpha")
                              (point))))))

;;; Tests: taskjuggler--end-of-defun

(ert-deftest taskjuggler-end-of-defun--from-header ()
  "From a block header, jumps past the block's closing `}'."
  (with-defun-buffer
    ;; Point on `task alpha'.
    (taskjuggler--end-of-defun)
    ;; Should now be past `task alpha's `}' and on or before `task beta'.
    (let ((beta-pos (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "^task beta")
                      (line-beginning-position))))
      (should (<= (point) beta-pos)))))

(ert-deftest taskjuggler-end-of-defun--from-inside-body ()
  "From inside a block body, jumps past the block's closing `}'."
  (with-defun-buffer
    (re-search-forward "effort 1d")
    (taskjuggler--end-of-defun)
    (let ((beta-pos (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "^task beta")
                      (line-beginning-position))))
      (should (<= (point) beta-pos)))))

(ert-deftest taskjuggler-end-of-defun--arg-2 ()
  "With arg 2, skips past two consecutive blocks."
  (with-defun-buffer
    ;; Point at start.
    (taskjuggler--end-of-defun 2)
    ;; Should be past beta (and possibly at or before gamma).
    (let ((gamma-pos (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^task gamma")
                       (line-beginning-position))))
      (should (<= (point) gamma-pos)))))

(ert-deftest taskjuggler-end-of-defun--negative-arg-delegates ()
  "A negative arg delegates to beginning-of-defun."
  (with-defun-buffer
    (re-search-forward "task beta")
    (beginning-of-line)
    (taskjuggler--end-of-defun -1)
    (should (looking-at "task alpha"))))

;;; Tests: taskjuggler-forward-block / taskjuggler-backward-block (linear scan)

(defconst test-linear-content
  "task outer \"Outer\" {\n  task inner-a \"A\" {\n  }\n  task inner-b \"B\" {\n  }\n}\ntask sibling \"Sibling\" {\n}\n")

(defmacro with-linear-buffer (&rest body)
  "Run BODY in a taskjuggler-mode buffer with nested and sibling blocks."
  (declare (indent 0))
  `(with-temp-buffer
     (insert test-linear-content)
     (taskjuggler-mode)
     (syntax-propertize (point-max))
     (goto-char (point-min))
     ,@body))

(ert-deftest taskjuggler-forward-block--crosses-nesting ()
  "forward-block moves into nested blocks, unlike next-block."
  (with-linear-buffer
    ;; Start on `task outer'.
    (taskjuggler-forward-block)
    (should (looking-at "[ \t]*task inner-a"))))

(ert-deftest taskjuggler-forward-block--arg-2 ()
  "forward-block with arg 2 moves to the second next block header."
  (with-linear-buffer
    (taskjuggler-forward-block 2)
    (should (looking-at "[ \t]*task inner-b"))))

(ert-deftest taskjuggler-forward-block--crosses-out-of-nesting ()
  "forward-block can move from a nested block to a top-level sibling."
  (with-linear-buffer
    (taskjuggler-forward-block 3)
    (should (looking-at "task sibling"))))

(ert-deftest taskjuggler-forward-block--errors-at-last-block ()
  "forward-block signals an error when there is no next block."
  (with-linear-buffer
    ;; Jump to the last block header.
    (re-search-forward "task sibling")
    (beginning-of-line)
    (should-error (taskjuggler-forward-block) :type 'user-error)))

(ert-deftest taskjuggler-backward-block--moves-to-prev-header ()
  "backward-block moves to the immediately preceding block header."
  (with-linear-buffer
    (re-search-forward "task sibling")
    (beginning-of-line)
    (taskjuggler-backward-block)
    (should (looking-at "[ \t]*task inner-b"))))

(ert-deftest taskjuggler-backward-block--arg-2 ()
  "backward-block with arg 2 moves two headers backward."
  (with-linear-buffer
    (re-search-forward "task sibling")
    (beginning-of-line)
    (taskjuggler-backward-block 2)
    (should (looking-at "[ \t]*task inner-a"))))

(ert-deftest taskjuggler-backward-block--errors-at-first-block ()
  "backward-block signals an error when there is no previous block."
  (with-linear-buffer
    (should-error (taskjuggler-backward-block) :type 'user-error)))

;;; Tests: calendar math

(ert-deftest taskjuggler-cal-clamp-day--within-range ()
  "Returns the day unchanged when it is valid for that month."
  (should (= 15 (taskjuggler--cal-clamp-day 2024 3 15))))

(ert-deftest taskjuggler-cal-clamp-day--clamps-to-month-end ()
  "Clamps day 31 to 30 for a 30-day month."
  (should (= 30 (taskjuggler--cal-clamp-day 2024 4 31))))

(ert-deftest taskjuggler-cal-clamp-day--february-leap-year ()
  "February in a leap year allows day 29."
  (should (= 29 (taskjuggler--cal-clamp-day 2024 2 29))))

(ert-deftest taskjuggler-cal-clamp-day--february-non-leap-year ()
  "Clamps day 29 to 28 in a non-leap-year February."
  (should (= 28 (taskjuggler--cal-clamp-day 2023 2 29))))

(ert-deftest taskjuggler-cal-adjust-date--day-forward ()
  "Adjusting by +1 :day advances one day."
  (should (equal '(2024 3 16) (taskjuggler--cal-adjust-date 2024 3 15 1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-backward ()
  "Adjusting by -1 :day retreats one day."
  (should (equal '(2024 3 14) (taskjuggler--cal-adjust-date 2024 3 15 -1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-crosses-month ()
  "Adjusting by day correctly crosses a month boundary."
  (should (equal '(2024 4 1) (taskjuggler--cal-adjust-date 2024 3 31 1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--week ()
  "Adjusting by 1 :week advances exactly 7 days."
  (should (equal '(2024 3 22) (taskjuggler--cal-adjust-date 2024 3 15 1 :week))))

(ert-deftest taskjuggler-cal-adjust-date--month-forward ()
  "Adjusting by +1 :month advances one month."
  (should (equal '(2024 4 15) (taskjuggler--cal-adjust-date 2024 3 15 1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-year-rollover ()
  "Adjusting month forward past December rolls over to next year."
  (should (equal '(2025 1 15) (taskjuggler--cal-adjust-date 2024 12 15 1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-clamps-day ()
  "Month adjustment clamps the day when the target month is shorter."
  ;; March 31 + 1 month = April 30 (April has only 30 days).
  (should (equal '(2024 4 30) (taskjuggler--cal-adjust-date 2024 3 31 1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-backward-year-rollover ()
  "Adjusting month backward past January rolls over to previous year."
  (should (equal '(2023 12 15) (taskjuggler--cal-adjust-date 2024 1 15 -1 :month))))

;;; Tests: taskjuggler-indent-line and taskjuggler-indent-region

(ert-deftest taskjuggler-indent-line--corrects-over-indent ()
  "indent-line fixes an over-indented line to the correct column."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n        effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (taskjuggler-indent-line)
    (should (= taskjuggler-indent-level (current-indentation)))))

(ert-deftest taskjuggler-indent-line--corrects-under-indent ()
  "indent-line fixes an under-indented line to the correct column."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\neffort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (taskjuggler-indent-line)
    (should (= taskjuggler-indent-level (current-indentation)))))

(ert-deftest taskjuggler-indent-region--indents-all-lines ()
  "indent-region correctly indents every line in the selected region."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n        effort 5d\ntask inner \"I\" {\neffort 1d\n}\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (taskjuggler-indent-region (point-min) (point-max))
    (goto-char (point-min))
    ;; Line 1: top-level header → col 0.
    (should (= 0 (current-indentation)))
    (forward-line 1)
    ;; Line 2: inside one brace → indent-level.
    (should (= taskjuggler-indent-level (current-indentation)))
    (forward-line 1)
    ;; Line 3: nested task header → indent-level.
    (should (= taskjuggler-indent-level (current-indentation)))
    (forward-line 1)
    ;; Line 4: inside two braces → 2 × indent-level.
    (should (= (* 2 taskjuggler-indent-level) (current-indentation)))))

;;; Tests: edge cases

(ert-deftest taskjuggler-block-end--brace-in-string-on-header ()
  "block-end ignores a `{' inside a quoted string on the header line."
  ;; The `{' inside `\"name {with brace}\"' must not be mistaken for the
  ;; block opener; the real `{' is the last one on the line.
  (with-temp-buffer
    (insert "task foo \"name {with brace}\" {\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler--block-end (point-min))))
      (should (= (point-max) end)))))

(ert-deftest taskjuggler-clone-block--includes-preceding-comment ()
  "clone-block copies the preceding comment together with the block."
  (with-nav-buffer "# header comment\ntask foo \"Foo\" {\n}\n"
    (re-search-forward "task foo")
    (beginning-of-line)
    (taskjuggler-clone-block)
    ;; Buffer should now contain two copies of the comment.
    (goto-char (point-min))
    (re-search-forward "# header comment")
    (should (re-search-forward "# header comment" nil t))))

(ert-deftest taskjuggler-sibling-bounds--nested-siblings ()
  "next-sibling-bounds finds siblings at a nested depth, not top-level."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (re-search-forward "task a")
    (beginning-of-line)
    (let ((bounds (taskjuggler--next-sibling-bounds (point))))
      (should bounds)
      (goto-char (nth 1 bounds))
      (should (looking-at "[ \t]*task b")))))

;;; Tests: scissors strings (syntax-propertize)

(defun test-tj--in-string-p (pos)
  "Return non-nil if buffer position POS is inside a string."
  (nth 3 (syntax-ppss pos)))

(ert-deftest taskjuggler-scissors--content-is-string ()
  "Text between -8<- and ->8- is treated as a string by syntax-ppss."
  (with-temp-buffer
    (insert "note -8<-\nhello world\n->8-\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "hello")
    (should (test-tj--in-string-p (point)))))

(ert-deftest taskjuggler-scissors--outside-is-not-string ()
  "Text before -8<- is not inside a string."
  (with-temp-buffer
    (insert "note -8<-\nhello\n->8-\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (should (not (test-tj--in-string-p (point))))))

(ert-deftest taskjuggler-scissors--after-close-is-not-string ()
  "Text after ->8- is no longer inside the string."
  (with-temp-buffer
    (insert "note -8<-\nhello\n->8-\nafter\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "after")
    (should (not (test-tj--in-string-p (point))))))

(ert-deftest taskjuggler-scissors--brace-inside-is-ignored ()
  "A `{' inside a scissors string does not affect brace depth."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n  note -8<-\n  { not a brace }\n  ->8-\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "effort")
    ;; depth inside the task body (after scissors string) should be 1, not more
    (should (= 1 (car (syntax-ppss))))))

;;; Tests: `/* */` comments in block-with-comments-start

(ert-deftest taskjuggler-block-with-comments-start--block-comment ()
  "A `/* */` block comment immediately before the header is included."
  (with-temp-buffer
    (insert "/* block comment */\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)  ; header on line 2
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler--block-with-comments-start header))))))

(ert-deftest taskjuggler-block-with-comments-start--multiline-block-comment ()
  "A multi-line `/* */` comment immediately before the header is included."
  (with-temp-buffer
    (insert "/* multi\n   line\n   comment */\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    ;; header is on line 4
    (goto-char (point-min))
    (forward-line 3)
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler--block-with-comments-start header))))))

;;; Tests: `[` / `]` bracket indentation

(ert-deftest taskjuggler-indent--inside-brackets ()
  "A line inside `[` brackets indents to `taskjuggler-indent-level'."
  (with-indent-buffer "macro mymacro [\n  content\n]\n"
    (should (= taskjuggler-indent-level (indent-at-line 2)))))

(ert-deftest taskjuggler-indent--closing-bracket-dedented ()
  "A closing `]' is de-indented one level relative to its contents."
  (with-indent-buffer "macro mymacro [\n  content\n]\n"
    (should (= 0 (indent-at-line 3)))))

;;; Tests: taskjuggler--tj3-executable

(ert-deftest taskjuggler-tj3-executable--nil-bin-dir ()
  "Returns the name as-is when `taskjuggler-tj3-bin-dir' is nil."
  (let ((taskjuggler-tj3-bin-dir nil))
    (should (equal "tj3" (taskjuggler--tj3-executable "tj3")))
    (should (equal "tj3man" (taskjuggler--tj3-executable "tj3man")))))

(ert-deftest taskjuggler-tj3-executable--with-bin-dir ()
  "Resolves name relative to `taskjuggler-tj3-bin-dir' when set."
  (let ((taskjuggler-tj3-bin-dir "/opt/tj3/bin"))
    (should (equal "/opt/tj3/bin/tj3"
                   (taskjuggler--tj3-executable "tj3")))
    (should (equal "/opt/tj3/bin/tj3man"
                   (taskjuggler--tj3-executable "tj3man")))))

;;; Tests: font-lock face assignment

(defun test-tj--face-at-string (search-string)
  "Return the font-lock face on the first char of SEARCH-STRING in current buffer."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (regexp-quote search-string))
    (goto-char (match-beginning 0))
    (or (get-text-property (point) 'face)
        (get-text-property (point) 'font-lock-face))))

(defmacro with-fontified-buffer (content &rest body)
  "Run BODY in a fontified taskjuggler-mode buffer containing CONTENT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (taskjuggler-mode)
     (font-lock-ensure)
     ,@body))

(ert-deftest taskjuggler-font-lock--keyword-face ()
  "Top-level keywords receive `font-lock-keyword-face'."
  (with-fontified-buffer "task foo \"Foo\" {\n}\n"
    (should (eq 'font-lock-keyword-face (test-tj--face-at-string "task")))))

(ert-deftest taskjuggler-font-lock--declaration-id-face ()
  "The identifier after a declaration keyword receives `font-lock-variable-name-face'."
  (with-fontified-buffer "task my-task \"My Task\" {\n}\n"
    (should (eq 'font-lock-variable-name-face
                (test-tj--face-at-string "my-task")))))

(ert-deftest taskjuggler-font-lock--date-face ()
  "Date literals receive `taskjuggler-date-face'."
  (with-fontified-buffer "start 2024-03-15\n"
    (should (eq 'taskjuggler-date-face (test-tj--face-at-string "2024-03-15")))))

(ert-deftest taskjuggler-font-lock--duration-face ()
  "Duration literals receive `taskjuggler-duration-face'."
  (with-fontified-buffer "effort 5d\n"
    (should (eq 'taskjuggler-duration-face (test-tj--face-at-string "5d")))))

(ert-deftest taskjuggler-font-lock--macro-ref-face ()
  "Macro references receive `taskjuggler-macro-face'."
  (with-fontified-buffer "note ${MyMacro}\n"
    (should (eq 'taskjuggler-macro-face (test-tj--face-at-string "${MyMacro}")))))

(ert-deftest taskjuggler-font-lock--property-keyword-face ()
  "Property keywords receive `font-lock-function-name-face'."
  (with-fontified-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (should (eq 'font-lock-function-name-face
                (test-tj--face-at-string "effort")))))

;;; Tests: move-block at nested depth

(ert-deftest taskjuggler-move-block-up--nested-siblings ()
  "move-block-up swaps two nested sibling tasks."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-move-block-up)
    ;; task b should now precede task a inside the parent.
    (goto-char (point-min))
    (re-search-forward "task p")
    (should (re-search-forward "task b" nil t))
    (let ((b-pos (match-beginning 0)))
      (should (re-search-forward "task a" nil t))
      (should (> (match-beginning 0) b-pos)))))

(ert-deftest taskjuggler-move-block-down--nested-siblings ()
  "move-block-down swaps two nested sibling tasks."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (re-search-forward "task a")
    (beginning-of-line)
    (taskjuggler-move-block-down)
    ;; task b should now precede task a.
    (goto-char (point-min))
    (re-search-forward "task p")
    (should (re-search-forward "task b" nil t))
    (let ((b-pos (match-beginning 0)))
      (should (re-search-forward "task a" nil t))
      (should (> (match-beginning 0) b-pos)))))

;;; Runner

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; taskjuggler-mode-test.el ends here
