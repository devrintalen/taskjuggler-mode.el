;;; taskjuggler-mode-test.el --- ERT tests for taskjuggler-mode  -*- lexical-binding: t -*-

;; Tests for taskjuggler--full-task-id-at-point and supporting functions.
;; Run with: emacs --batch -l test/taskjuggler-mode-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'man)
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

(ert-deftest taskjuggler-prev-block--errors-at-first-sibling ()
  "prev-block signals a user-error when there is no previous sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Start on `task a' — first sibling, no previous.
    (should-error (taskjuggler-prev-block) :type 'user-error)))

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

;;; Corner cases: next-block / prev-block from inside a body

(ert-deftest taskjuggler-next-block--from-inside-body ()
  "next-block from inside a block body jumps to the next sibling of that block."
  ;; When point is inside `task a', its enclosing header IS `task a'.
  ;; next-block should jump to `task b' (the sibling of `task a').
  (with-nav-buffer "task a \"A\" {\n  effort 1d\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "effort")
    (taskjuggler-next-block)
    (should (looking-at "task b"))))

(ert-deftest taskjuggler-prev-block--from-inside-body ()
  "prev-block from inside a block body jumps to the previous sibling of that block."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n  effort 1d\n}\n"
    (re-search-forward "effort")
    (taskjuggler-prev-block)
    (should (looking-at "task a"))))

;;; Corner cases: move-block error paths

(ert-deftest taskjuggler-move-block-up--errors-at-first-sibling ()
  "move-block-up signals an error when there is no previous sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Point on `task a' — first sibling, no previous.
    (should-error (taskjuggler-move-block-up) :type 'user-error)))

(ert-deftest taskjuggler-move-block-down--errors-at-last-sibling ()
  "move-block-down signals an error when there is no next sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (should-error (taskjuggler-move-block-down) :type 'user-error)))

(ert-deftest taskjuggler-move-block-up--errors-when-not-on-block ()
  "move-block-up signals an error when point is not on a moveable block."
  (with-nav-buffer "\ntask a \"A\" {\n}\n"
    ;; Point starts on the blank line — not inside any block.
    (should-error (taskjuggler-move-block-up) :type 'user-error)))

;;; Corner cases: scissors strings

(ert-deftest taskjuggler-scissors--hash-inside-is-not-comment ()
  "A `#' inside a scissors string is not treated as a comment start."
  (with-temp-buffer
    (insert "note -8<-\n# not a comment\n->8-\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "# not a comment")
    (goto-char (match-beginning 0))
    ;; Inside a scissors string: the `#' starts a comment only outside strings.
    ;; syntax-ppss should show we are inside a string (string fence), not a comment.
    (let ((ppss (syntax-ppss)))
      (should (nth 3 ppss))       ; inside a string
      (should (not (nth 4 ppss)))))) ; NOT inside a comment

(ert-deftest taskjuggler-scissors--unclosed-makes-rest-string ()
  "Without a closing ->8-, everything after -8<- is treated as a string."
  (with-temp-buffer
    (insert "note -8<-\norphaned content\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "orphaned")
    (should (test-tj--in-string-p (point)))))

(ert-deftest taskjuggler-scissors--commented-out-does-not-open-string ()
  "A -8<- inside a # comment does not open a scissors string."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n  # note -8<-\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "effort")
    (should (not (test-tj--in-string-p (point))))))

(ert-deftest taskjuggler-scissors--commented-out-does-not-break-indent ()
  "A task following a block with `# note -8<-' indents to sibling level."
  (with-indent-buffer (concat "task p \"P\" {\n"
                               "  task a \"A\" {\n"
                               "    # note -8<-\n"
                               "  }\n"
                               "  task b \"B\" {\n"
                               "    effort 1d\n"
                               "  }\n"
                               "}\n")
    ;; Line 5 is "task b" — it should indent to depth 1 (inside task p),
    ;; not to depth 2+ as if still inside a scissors string.
    (should (= taskjuggler-indent-level (indent-at-line 5)))))

;;; Corner cases: full-task-id on the closing `}' line

(ert-deftest taskjuggler-full-task-id--on-closing-brace-line ()
  "Returns the task id when point is on the closing `}' of the block.
The `}' is syntactically still inside the block (depth 1), so the
enclosing header is still the task header."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "^}$")
    (beginning-of-line)
    (should (equal "foo" (taskjuggler--full-task-id-at-point)))))

;;; Corner cases: continuation indent with no argument on anchor line

(ert-deftest taskjuggler-indent--continuation-anchor-is-first-comma-line ()
  "The continuation anchor is the first comma-terminated line, not the line above.
When a keyword-only line (`columns') precedes the comma chain, the anchor
for alignment is the first comma-terminated line (`name,'), not `columns'."
  ;; Anchor line is `  name,' (first comma-terminated line).
  ;; `name' starts at col 2, ends at col 6.  The comma follows immediately,
  ;; so continuation-indent returns col 6 (position right after `name').
  (with-indent-buffer "taskreport r \"\" {\n  columns\n  name,\n  id\n}\n"
    (should (= 6 (indent-at-line 4)))))

;;; Corner cases: multiple consecutive comment lines

(ert-deftest taskjuggler-block-with-comments-start--multiple-comments ()
  "All consecutive comment lines before the header are included."
  (with-temp-buffer
    (insert "# first\n# second\n# third\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 3)  ; header on line 4
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler--block-with-comments-start header))))))

(ert-deftest taskjuggler-block-with-comments-start--mixed-comment-types ()
  "A mix of `#' and `//' comment lines before the header are all included."
  (with-temp-buffer
    (insert "// slash comment\n# hash comment\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 2)  ; header on line 3
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler--block-with-comments-start header))))))

;;; Corner cases: block-end with `{' in comment on header line

(ert-deftest taskjuggler-block-end--brace-in-hash-comment-on-header ()
  "block-end ignores a `{' inside a `#' comment on the header line."
  (with-temp-buffer
    (insert "task foo \"Foo\" { # { this brace is in a comment\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler--block-end (point-min))))
      (should (= (point-max) end)))))

(ert-deftest taskjuggler-block-end--brace-in-slash-comment-on-header ()
  "block-end ignores a `{' inside a `// ' comment on the header line."
  (with-temp-buffer
    (insert "task foo \"Foo\" { // another { brace\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler--block-end (point-min))))
      (should (= (point-max) end)))))

;;; Corner cases: goto-parent two levels up

(ert-deftest taskjuggler-goto-parent--two-levels-up ()
  "Two consecutive goto-parent calls reach the outermost block header."
  (with-nav-buffer "task outer \"O\" {\n  task inner \"I\" {\n    effort 1d\n  }\n}\n"
    (re-search-forward "effort")
    (taskjuggler-goto-parent)
    (should (looking-at "[ \t]*task inner"))
    (taskjuggler-goto-parent)
    (should (looking-at "task outer"))))

;;; Corner cases: date-bounds with two dates on same line

(ert-deftest taskjuggler-date-bounds-at-point--second-date-on-line ()
  "Returns bounds for the second date when point is on it."
  (with-temp-buffer
    (insert "period 2024-01-01 2024-12-31\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024-12")
    (let ((bounds (taskjuggler--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-12-31"
                     (buffer-substring (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-date-bounds-at-point--first-of-two-dates ()
  "Returns bounds for the first date when point is on it."
  (with-temp-buffer
    (insert "period 2024-01-01 2024-12-31\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024-01")
    (let ((bounds (taskjuggler--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-01-01"
                     (buffer-substring (car bounds) (cdr bounds)))))))

;;; Corner cases: font-lock comment and string faces

(ert-deftest taskjuggler-font-lock--slash-comment-face ()
  "Text inside a `// ' comment receives a comment face."
  (with-fontified-buffer "// this is a comment\ntask foo \"Foo\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "this is")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (or (eq face 'font-lock-comment-face)
                  (and (listp face) (memq 'font-lock-comment-face face)))))))

(ert-deftest taskjuggler-font-lock--hash-comment-face ()
  "Text inside a `#' comment receives a comment face."
  (with-fontified-buffer "# hash comment\ntask foo \"Foo\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "hash comment")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (or (eq face 'font-lock-comment-face)
                  (and (listp face) (memq 'font-lock-comment-face face)))))))

(ert-deftest taskjuggler-font-lock--string-face ()
  "Double-quoted strings receive a string face."
  (with-fontified-buffer "task foo \"My Task\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "My Task")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (or (eq face 'font-lock-string-face)
                  (and (listp face) (memq 'font-lock-string-face face)))))))

(ert-deftest taskjuggler-font-lock--value-keyword-face ()
  "Value keywords like `asap' receive `font-lock-variable-name-face'."
  (with-fontified-buffer "scheduling asap\n"
    (should (eq 'font-lock-variable-name-face
                (test-tj--face-at-string "asap")))))

(ert-deftest taskjuggler-font-lock--report-keyword-face ()
  "Report type keywords receive `font-lock-function-name-face'."
  (with-fontified-buffer "taskreport r \"\" {\n}\n"
    (should (eq 'font-lock-function-name-face
                (test-tj--face-at-string "taskreport")))))

;;; Corner cases: calendar math

(ert-deftest taskjuggler-cal-adjust-date--week-backward ()
  "Adjusting by -1 :week retreats exactly 7 days."
  (should (equal '(2024 3 8) (taskjuggler--cal-adjust-date 2024 3 15 -1 :week))))

(ert-deftest taskjuggler-cal-adjust-date--day-crosses-year ()
  "Adjusting by +1 :day from Dec 31 rolls into the next year."
  (should (equal '(2025 1 1) (taskjuggler--cal-adjust-date 2024 12 31 1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--month-forward-13 ()
  "Adjusting by +13 :months advances more than one year."
  (should (equal '(2026 4 15) (taskjuggler--cal-adjust-date 2025 3 15 13 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-backward-13 ()
  "Adjusting by -13 :months retreats more than one year."
  (should (equal '(2024 2 15) (taskjuggler--cal-adjust-date 2025 3 15 -13 :month))))

;;; Corner cases: block-header-task-id non-task declaration keywords

(ert-deftest taskjuggler-block-header-task-id--macro-keyword ()
  "Returns nil for a `macro' header line — only `task' lines yield an id."
  (with-temp-buffer
    (insert "macro mymacro [\n]\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (null (taskjuggler--block-header-task-id (point))))))

(ert-deftest taskjuggler-block-header-task-id--supplement-keyword ()
  "Returns nil for a `supplement task' header line."
  (with-temp-buffer
    (insert "supplement task foo {\n}\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    ;; `supplement' is the leading keyword; this line does not start with `task'.
    (should (null (taskjuggler--block-header-task-id (point))))))

;;; Round 6: uncovered logic paths

;; --- taskjuggler--prev-sibling-bounds: (t nil) cond arm ---
;; When the line before the first child is plain content (not a brace block
;; and not a moveable keyword), the cond falls through to (t nil) and
;; prev-sibling-bounds returns nil.

(ert-deftest taskjuggler-prev-sibling-bounds--nil-when-prev-is-plain-content ()
  "Returns nil when the predecessor line is plain content, not a sibling block.
The `(t nil)' arm of the internal cond is taken when the candidate
predecessor is neither a `}'-terminated block nor a moveable keyword line."
  (with-nav-buffer "task p \"P\" {\n  effort 5d\n  task child \"C\" {\n  }\n}\n"
    (syntax-propertize (point-max))
    (re-search-forward "task child")
    (beginning-of-line)
    (should (null (taskjuggler--prev-sibling-bounds (point))))))

;; --- taskjuggler--next-sibling-bounds: /* */ comment skip branch ---
;; Lines 572-574 of the source: when a `/*' line is encountered while
;; scanning forward, re-search-forward is used to skip the entire comment
;; block rather than forward-line 1.

(ert-deftest taskjuggler-next-sibling-bounds--skips-block-comment ()
  "next-sibling-bounds correctly skips a `/* */' comment between siblings."
  (with-nav-buffer "task a \"A\" {\n}\n\n/* inter-block comment */\n\ntask b \"B\" {\n}\n"
    (let ((bounds (taskjuggler--next-sibling-bounds (point-min))))
      (should bounds)
      (goto-char (nth 1 bounds))
      (should (looking-at "task b")))))

(ert-deftest taskjuggler-next-block--skips-block-comment-between-siblings ()
  "next-block finds the next sibling even with a `/* */' comment between them."
  (with-nav-buffer "task a \"A\" {\n}\n\n/* inter-block comment */\n\ntask b \"B\" {\n}\n"
    (taskjuggler-next-block)
    (should (looking-at "task b"))))

;; --- taskjuggler-indent-line: point-restoration branch ---
;; Lines 413-414: when point was inside line content before the call,
;; (- (point-max) pos) > new indented point, so we restore point to the
;; equivalent content position after re-indentation.

(ert-deftest taskjuggler-indent-line--restores-point-inside-content ()
  "indent-line restores point to its content position when past indentation.
When called with point inside the line (not at bol), the `when' guard on
line 413 fires and moves point back to the same logical character."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n        effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    ;; Position point after "effort " — inside content, past the indentation.
    (goto-char (point-min))
    (re-search-forward "effort ")
    ;; Capture the distance from point to point-max before re-indenting.
    (let ((dist-from-end (- (point-max) (point))))
      (taskjuggler-indent-line)
      ;; Point should be at the same logical position relative to point-max.
      (should (= (point) (- (point-max) dist-from-end))))))

;; --- taskjuggler-indent-region: blank-line skip ---
;; Line 424: `(unless (looking-at "[ \t]*$") ...)' skips blank lines.
;; No previous test contained a blank line inside the indented region.

(ert-deftest taskjuggler-indent-region--skips-blank-lines ()
  "indent-region leaves blank lines untouched."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n\n  effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (taskjuggler-indent-region (point-min) (point-max))
    ;; Line 2 is blank; it must remain blank (no spaces inserted).
    (goto-char (point-min))
    (forward-line 1)
    (should (looking-at "^$"))))

;; --- taskjuggler--backward-sexp-1: non-`}' fallback ---
;; Line 880: when char-before (after skipping whitespace) is not `}',
;; the block-detection save-excursion sets block-start to nil and we
;; fall back to the default (forward-sexp -1).

(ert-deftest taskjuggler-backward-sexp--fallback-for-non-brace-token ()
  "backward-sexp from after a plain token falls back to default sexp movement.
When the character before point is not `}', the block-detection is skipped
and `forward-sexp -1' moves back over the token normally."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "5d")
    ;; Point is just after "5d"; char-before = 'd', not `}'.
    (let ((pos-before (point)))
      (taskjuggler--forward-sexp -1)
      (should (< (point) pos-before))
      (should (looking-at "5d")))))

;; --- taskjuggler--cal-valid-char-at-p ---
;; Two branches: positions 4 and 7 require a hyphen; all others require a digit.

(ert-deftest taskjuggler-cal-valid-char-at-p--hyphen-at-sep-positions ()
  "A hyphen is valid at separator positions 4 and 7."
  (should (taskjuggler--cal-valid-char-at-p ?- 4))
  (should (taskjuggler--cal-valid-char-at-p ?- 7)))

(ert-deftest taskjuggler-cal-valid-char-at-p--digit-invalid-at-sep-positions ()
  "A digit is invalid at separator positions 4 and 7."
  (should (not (taskjuggler--cal-valid-char-at-p ?0 4)))
  (should (not (taskjuggler--cal-valid-char-at-p ?9 7))))

(ert-deftest taskjuggler-cal-valid-char-at-p--digit-valid-at-digit-positions ()
  "A digit is valid at non-separator positions."
  (should (taskjuggler--cal-valid-char-at-p ?2 0))
  (should (taskjuggler--cal-valid-char-at-p ?0 5))
  (should (taskjuggler--cal-valid-char-at-p ?1 8)))

(ert-deftest taskjuggler-cal-valid-char-at-p--hyphen-invalid-at-digit-positions ()
  "A hyphen is invalid at non-separator positions."
  (should (not (taskjuggler--cal-valid-char-at-p ?- 0)))
  (should (not (taskjuggler--cal-valid-char-at-p ?- 5)))
  (should (not (taskjuggler--cal-valid-char-at-p ?- 9))))

;; --- taskjuggler--cal-parse-typed-prefix ---
;; Guards: (>= typed-len 4/7/10), (> y 0), (<= 1 m 12), (>= d 1).

(ert-deftest taskjuggler-cal-parse-typed-prefix--zero-typed-returns-default ()
  "With typed-len=0, no parsing occurs and the default date is returned."
  (with-temp-buffer
    (insert "2024-03-15")
    (should (equal '(2026 1 1)
                   (taskjuggler--cal-parse-typed-prefix 1 0 '(2026 1 1))))))

(ert-deftest taskjuggler-cal-parse-typed-prefix--four-chars-sets-year ()
  "With typed-len=4, the year is parsed from the buffer prefix."
  (with-temp-buffer
    (insert "2024-03-15")
    (should (equal '(2024 1 1)
                   (taskjuggler--cal-parse-typed-prefix 1 4 '(2026 1 1))))))

(ert-deftest taskjuggler-cal-parse-typed-prefix--seven-chars-sets-year-and-month ()
  "With typed-len=7, year and month are parsed."
  (with-temp-buffer
    (insert "2024-06-15")
    (should (equal '(2024 6 1)
                   (taskjuggler--cal-parse-typed-prefix 1 7 '(2026 1 1))))))

(ert-deftest taskjuggler-cal-parse-typed-prefix--ten-chars-sets-all ()
  "With typed-len=10, year, month, and day are all parsed."
  (with-temp-buffer
    (insert "2024-06-15")
    (should (equal '(2024 6 15)
                   (taskjuggler--cal-parse-typed-prefix 1 10 '(2026 1 1))))))

(ert-deftest taskjuggler-cal-parse-typed-prefix--year-zero-rejected ()
  "A parsed year of 0 is rejected; the default year is kept."
  (with-temp-buffer
    (insert "0000-06-15")
    ;; y=0, `(> y 0)' is false → keep default year 2026.
    (should (equal '(2026 1 1)
                   (taskjuggler--cal-parse-typed-prefix 1 4 '(2026 1 1))))))

(ert-deftest taskjuggler-cal-parse-typed-prefix--invalid-month-rejected ()
  "A month value outside 1-12 is rejected; the default month is kept."
  (with-temp-buffer
    (insert "2024-13-15")
    ;; m=13, `(<= 1 13 12)' is false → keep default month 5.
    (should (equal '(2024 5 1)
                   (taskjuggler--cal-parse-typed-prefix 1 7 '(2026 5 1))))))

(ert-deftest taskjuggler-cal-parse-typed-prefix--day-clamped-to-month ()
  "Day 31 is clamped to the last valid day of the parsed month."
  (with-temp-buffer
    (insert "2024-02-31")
    ;; Feb 2024 is a leap year; max day = 29.
    (should (equal '(2024 2 29)
                   (taskjuggler--cal-parse-typed-prefix 1 10 '(2026 1 1))))))

;; --- taskjuggler--cal-splice-line ---
;; Branch 1: col <= old-len → take substring for left side.
;; Branch 2: col > old-len  → pad with spaces.
;; Branch 3: right-start < old-len  → right side has content.
;; Branch 4: right-start >= old-len → right side is "".

(ert-deftest taskjuggler-cal-splice-line--normal-insertion ()
  "Splices new text into old at col, preserving text on both sides."
  ;; "leftXXXright" with "CAL" at col 4 → "leftCALright"
  (should (equal "leftCALright"
                 (taskjuggler--cal-splice-line "leftXXXright" "CAL" 4))))

(ert-deftest taskjuggler-cal-splice-line--col-beyond-line-pads-with-spaces ()
  "When col > old-len, spaces are inserted to reach col before new text."
  ;; "ab" (len=2) with "CAL" at col 4: needs 2 padding spaces.
  (should (equal "ab  CAL"
                 (taskjuggler--cal-splice-line "ab" "CAL" 4))))

(ert-deftest taskjuggler-cal-splice-line--no-right-remainder ()
  "When right-start >= old-len, the right portion is empty."
  ;; "leftXX" (len=6) with "CAL" at col 4: right-start=7 >= 6 → right="".
  (should (equal "leftCAL"
                 (taskjuggler--cal-splice-line "leftXX" "CAL" 4))))

;; --- taskjuggler--cal-pad-line: overflow ---

(ert-deftest taskjuggler-cal-pad-line--text-longer-than-width ()
  "When text exceeds cal-width, no padding is added (max 0 guard)."
  (let* ((long-text (make-string (+ taskjuggler--cal-width 5) ?x))
         (result (taskjuggler--cal-pad-line long-text)))
    (should (equal long-text result))))

;; --- taskjuggler--cal-build-display: exhausted old-lines ---
;; Line 1141: `(or (pop old-lines) "")' supplies an empty string when
;; old-lines runs out before cal-lines does.

(ert-deftest taskjuggler-cal-build-display--empty-old-lines ()
  "When old-lines is empty, calendar rows splice into empty strings."
  (let* ((result (taskjuggler--cal-build-display '("ROW1" "ROW2") nil 0)))
    (should (string-match-p "ROW1" result))
    (should (string-match-p "ROW2" result))))

;; --- taskjuggler--cal-week-lines: Sunday start (no leading cells) ---
;; `(when (> start-dow 0))' on line 1018: skipped when a month starts on Sunday.
;; Feb 2015 has 28 days and starts on Sunday → 0 leading cells, 0 trailing
;; cells (28 / 7 = 4 exactly) → exactly 4 week rows.

(ert-deftest taskjuggler-cal-week-lines--sunday-start-no-leading-cells ()
  "A month starting on Sunday produces no leading cells and the minimum row count.
Feb 2015 starts on Sunday (start-dow=0) and has 28 days: 4 rows exactly."
  (let ((weeks (taskjuggler--cal-week-lines 2015 2 15 2015 2 15)))
    (should (= 4 (length weeks)))))

;; --- taskjuggler--cal-week-lines: no trailing fill ---
;; `(when (> trailing 0))' on line 1041: skipped when cells divide evenly by 7.

(ert-deftest taskjuggler-cal-week-lines--no-trailing-fill-needed ()
  "A month whose cell count is a multiple of 7 needs no trailing fill.
Feb 2015 (28 days, Sunday start): 28 cells / 7 = 4 rows, remainder 0."
  ;; Contrast with a month that DOES have trailing fill.
  ;; January 2024 starts on Monday (start-dow=1): 1+31=32 cells, 32%7=4,
  ;; trailing=3 → 35 cells → 5 rows.
  (let ((weeks-jan (taskjuggler--cal-week-lines 2024 1 15 2024 1 15))
        (weeks-feb (taskjuggler--cal-week-lines 2015 2 15 2015 2 15)))
    (should (= 5 (length weeks-jan)))
    (should (= 4 (length weeks-feb)))))

;; --- narrow-to-block / mark-block: not-on-block error ---

(ert-deftest taskjuggler-narrow-to-block--errors-when-not-on-block ()
  "narrow-to-block signals a user-error when point is not inside any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n}\n"
    ;; Point is on the blank line before the task — not inside any block.
    (should-error (taskjuggler-narrow-to-block) :type 'user-error)))

(ert-deftest taskjuggler-mark-block--errors-when-not-on-block ()
  "mark-block signals a user-error when point is not inside any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n}\n"
    (should-error (taskjuggler-mark-block) :type 'user-error)))

;; --- goto-first-child / goto-last-child: not-on-block error ---

(ert-deftest taskjuggler-goto-first-child--errors-when-not-on-block ()
  "goto-first-child signals a user-error when point is not on any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n  task child \"C\" {\n  }\n}\n"
    ;; Point is on the initial blank line — not inside any block.
    (should-error (taskjuggler-goto-first-child) :type 'user-error)))

(ert-deftest taskjuggler-goto-last-child--errors-when-not-on-block ()
  "goto-last-child signals a user-error when point is not on any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n  task child \"C\" {\n  }\n}\n"
    (should-error (taskjuggler-goto-last-child) :type 'user-error)))

;; --- taskjuggler--full-task-id-at-point: `}' line of a non-task block ---
;; The closing `}' of a `resource' block is syntactically inside that block
;; (depth 1), so current-block-header returns the resource header.
;; block-header-task-id returns nil for `resource', so ids stays nil → nil.

(ert-deftest taskjuggler-full-task-id--nil-on-closing-brace-of-resource ()
  "Returns nil when point is on the closing `}' of a non-task block."
  (with-temp-buffer
    (insert "resource dev \"Dev\" {\n  vacation 2024-01-01\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "^}$")
    (beginning-of-line)
    (should (null (taskjuggler--full-task-id-at-point)))))

;;; Round 7: calendar navigation — leap year coverage and nav-delta

;; --- taskjuggler--cal-nav-delta ---
;; Maps the six shift-arrow keys to (delta . unit) cons cells.
;; All six pcase arms are untested.

(ert-deftest taskjuggler-cal-nav-delta--all-keys ()
  "Each shift-arrow key maps to the correct (delta . unit) pair."
  (should (equal '(1  . :day)   (taskjuggler--cal-nav-delta 'S-right)))
  (should (equal '(-1 . :day)   (taskjuggler--cal-nav-delta 'S-left)))
  (should (equal '(1  . :week)  (taskjuggler--cal-nav-delta 'S-down)))
  (should (equal '(-1 . :week)  (taskjuggler--cal-nav-delta 'S-up)))
  (should (equal '(1  . :month) (taskjuggler--cal-nav-delta 'S-next)))
  (should (equal '(-1 . :month) (taskjuggler--cal-nav-delta 'S-prior))))

;; --- :day movement across the February boundary ---

(ert-deftest taskjuggler-cal-adjust-date--day-feb28-to-feb29-leap ()
  "+1 day from Feb 28 in a leap year lands on Feb 29."
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 2 28 1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-feb29-to-mar1-leap ()
  "+1 day from Feb 29 in a leap year crosses into March."
  (should (equal '(2024 3 1) (taskjuggler--cal-adjust-date 2024 2 29 1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-feb28-to-mar1-non-leap ()
  "+1 day from Feb 28 in a non-leap year jumps directly to March 1."
  (should (equal '(2023 3 1) (taskjuggler--cal-adjust-date 2023 2 28 1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-backward-mar1-to-feb29-leap ()
  "-1 day from Mar 1 in a leap year lands on Feb 29."
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 3 1 -1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-backward-mar1-to-feb28-non-leap ()
  "-1 day from Mar 1 in a non-leap year lands on Feb 28."
  (should (equal '(2023 2 28) (taskjuggler--cal-adjust-date 2023 3 1 -1 :day))))

(ert-deftest taskjuggler-cal-adjust-date--day-backward-feb29-to-feb28-leap ()
  "-1 day from Feb 29 lands on Feb 28 in the same leap year."
  (should (equal '(2024 2 28) (taskjuggler--cal-adjust-date 2024 2 29 -1 :day))))

;; --- :week movement across the February boundary ---

(ert-deftest taskjuggler-cal-adjust-date--week-lands-on-feb29 ()
  "+1 week from Feb 22 in a leap year lands on Feb 29."
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 2 22 1 :week))))

(ert-deftest taskjuggler-cal-adjust-date--week-crosses-feb29-leap ()
  "+1 week from Feb 25 in a leap year crosses Feb 29 and lands in March."
  (should (equal '(2024 3 3) (taskjuggler--cal-adjust-date 2024 2 25 1 :week))))

(ert-deftest taskjuggler-cal-adjust-date--week-crosses-feb28-non-leap ()
  "+1 week from Feb 22 in a non-leap year crosses Feb 28 and lands in March."
  (should (equal '(2023 3 1) (taskjuggler--cal-adjust-date 2023 2 22 1 :week))))

(ert-deftest taskjuggler-cal-adjust-date--week-backward-crosses-feb29 ()
  "-1 week from Mar 7 in a leap year crosses Feb 29."
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 3 7 -1 :week))))

;; --- :month movement clamping into February ---

(ert-deftest taskjuggler-cal-adjust-date--month-jan31-to-feb28-non-leap ()
  "Jan 31 + 1 month in a non-leap year clamps to Feb 28."
  (should (equal '(2023 2 28) (taskjuggler--cal-adjust-date 2023 1 31 1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-jan31-to-feb29-leap ()
  "Jan 31 + 1 month in a leap year clamps to Feb 29."
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 1 31 1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-backward-mar31-to-feb28-non-leap ()
  "Mar 31 - 1 month in a non-leap year clamps to Feb 28."
  (should (equal '(2023 2 28) (taskjuggler--cal-adjust-date 2023 3 31 -1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-backward-mar31-to-feb29-leap ()
  "Mar 31 - 1 month in a leap year clamps to Feb 29."
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 3 31 -1 :month))))

;; --- :month movement starting from Feb 29 (the leap day itself) ---

(ert-deftest taskjuggler-cal-adjust-date--month-from-feb29-forward ()
  "Feb 29 + 1 month advances to Mar 29 without clamping."
  (should (equal '(2024 3 29) (taskjuggler--cal-adjust-date 2024 2 29 1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-from-feb29-backward ()
  "Feb 29 - 1 month retreats to Jan 29 without clamping."
  (should (equal '(2024 1 29) (taskjuggler--cal-adjust-date 2024 2 29 -1 :month))))

(ert-deftest taskjuggler-cal-adjust-date--month-from-feb29-to-feb-non-leap ()
  "Feb 29 + 12 months lands in the next year's February, clamping to Feb 28."
  ;; 2024-02-29 + 12 months = 2025-02-28 (2025 is not a leap year).
  (should (equal '(2025 2 28) (taskjuggler--cal-adjust-date 2024 2 29 12 :month))))

;;; Round 8: calendar popup layout properties

;; Week rows are built as:
;;   " " cell0 " " cell1 " " cell2 " " cell3 " " cell4 " " cell5 " " cell6 " "
;; Each cell is a 2-char propertized string; cell i starts at position 1 + 3*i.

(defun test-tj--cell-face (weeks row-idx cell-idx)
  "Return the face of the cell at ROW-IDX, CELL-IDX (0-based) in WEEKS."
  (get-text-property (+ 1 (* 3 cell-idx)) 'face (nth row-idx weeks)))

(defun test-tj--cell-day (weeks row-idx cell-idx)
  "Return the integer day shown at ROW-IDX, CELL-IDX in WEEKS."
  (let* ((row (nth row-idx weeks))
         (pos (+ 1 (* 3 cell-idx))))
    (string-to-number (substring-no-properties row pos (+ pos 2)))))

;; --- Row-count tests ---

(ert-deftest taskjuggler-cal-week-lines--five-week-month ()
  "A month that spans 5 calendar rows returns 5 week rows.
January 2024 starts on Monday (start-dow=1): 1 leading + 31 + 3 trailing = 35 = 5 rows."
  (let ((weeks (taskjuggler--cal-week-lines 2024 1 15 2024 1 15)))
    (should (= 5 (length weeks)))))

(ert-deftest taskjuggler-cal-week-lines--six-week-month ()
  "A month that spans 6 calendar rows returns 6 week rows.
December 2018 starts on Saturday (start-dow=6): 6 + 31 + 5 trailing = 42 = 6 rows."
  (let ((weeks (taskjuggler--cal-week-lines 2018 12 15 2018 12 15)))
    (should (= 6 (length weeks)))))

;; --- Leading-cell tests ---
;; Feb 2024 starts on Thursday (start-dow=4).
;; Previous month is January (31 days): first-prev = 1+(31-4) = 28.
;; Leading cells occupy row 0, positions 0-3 (Jan 28-31).

(ert-deftest taskjuggler-cal-week-lines--leading-cells-have-inactive-face ()
  "Every leading cell from the previous month carries the inactive face."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
    (should (eq 'taskjuggler-cal-inactive-face (test-tj--cell-face weeks 0 0)))
    (should (eq 'taskjuggler-cal-inactive-face (test-tj--cell-face weeks 0 1)))
    (should (eq 'taskjuggler-cal-inactive-face (test-tj--cell-face weeks 0 2)))
    (should (eq 'taskjuggler-cal-inactive-face (test-tj--cell-face weeks 0 3)))))

(ert-deftest taskjuggler-cal-week-lines--leading-cells-start-at-correct-day ()
  "Leading cells show the correct end-of-previous-month day numbers."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
    (should (= 28 (test-tj--cell-day weeks 0 0)))
    (should (= 29 (test-tj--cell-day weeks 0 1)))
    (should (= 30 (test-tj--cell-day weeks 0 2)))
    (should (= 31 (test-tj--cell-day weeks 0 3)))))

(ert-deftest taskjuggler-cal-week-lines--no-leading-first-cell-is-day-1 ()
  "When start-dow=0 (Sunday), no leading cells — first cell of row 0 is day 1.
February 2015 starts on Sunday."
  (let ((weeks (taskjuggler--cal-week-lines 2015 2 15 2026 1 1)))
    (should (= 1 (test-tj--cell-day weeks 0 0)))))

(ert-deftest taskjuggler-cal-week-lines--six-week-leading-cells ()
  "A month with start-dow=6 has 6 leading cells starting at the right day.
December 2018 starts on Saturday; November has 30 days: first-prev = 1+(30-6) = 25."
  (let ((weeks (taskjuggler--cal-week-lines 2018 12 15 2026 1 1)))
    (should (= 25 (test-tj--cell-day weeks 0 0)))
    (should (= 30 (test-tj--cell-day weeks 0 5)))
    ;; Cell 6 of row 0 is Dec 1 — first day of the actual month.
    (should (= 1 (test-tj--cell-day weeks 0 6)))))

;; --- Trailing-cell tests ---
;; Feb 2024: 4 leading + 29 = 33 cells; trailing = 7-(33%7) = 2 (Mar 1-2).
;; They appear at row 4, cells 5-6.

(ert-deftest taskjuggler-cal-week-lines--trailing-cells-have-inactive-face ()
  "Trailing cells from the next month carry the inactive face."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
    (should (eq 'taskjuggler-cal-inactive-face (test-tj--cell-face weeks 4 5)))
    (should (eq 'taskjuggler-cal-inactive-face (test-tj--cell-face weeks 4 6)))))

(ert-deftest taskjuggler-cal-week-lines--trailing-cells-start-at-day-1 ()
  "Trailing cells always count up from day 1 of the following month."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
    (should (= 1 (test-tj--cell-day weeks 4 5)))
    (should (= 2 (test-tj--cell-day weeks 4 6)))))

;; --- Face tests ---
;; All use Feb 2024, selected=15, today either far away or on a specific day.
;; Feb 15 offset: 4 leading + 15 - 1 = 18 = row 2 cell 4.
;; Feb 10 offset: 4 + 10 - 1 = 13 = row 1 cell 6.
;; Feb  1 offset: 4 +  1 - 1 =  4 = row 0 cell 4.

(ert-deftest taskjuggler-cal-week-lines--selected-day-face ()
  "The selected day carries `taskjuggler-cal-selected-face'."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
    (should (eq 'taskjuggler-cal-selected-face (test-tj--cell-face weeks 2 4)))))

(ert-deftest taskjuggler-cal-week-lines--today-face ()
  "Today's date (when not the selected day) carries `taskjuggler-cal-today-face'."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2024 2 10)))
    (should (eq 'taskjuggler-cal-today-face (test-tj--cell-face weeks 1 6)))))

(ert-deftest taskjuggler-cal-week-lines--regular-day-face ()
  "A day that is neither selected nor today carries `taskjuggler-cal-face'."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
    ;; Feb 1 is row 0 cell 4 — neither selected (15) nor today.
    (should (eq 'taskjuggler-cal-face (test-tj--cell-face weeks 0 4)))))

(ert-deftest taskjuggler-cal-week-lines--selected-overrides-today ()
  "When selected and today are the same day, selected face takes priority.
The cond checks `= d selected-day' before `= d today-day'."
  (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2024 2 15)))
    (should (eq 'taskjuggler-cal-selected-face (test-tj--cell-face weeks 2 4)))))

;; --- taskjuggler--cal-title-line ---

(ert-deftest taskjuggler-cal-title-line--format ()
  "Returns `Month YEAR' for any month/year combination."
  (should (equal "February 2024" (taskjuggler--cal-title-line 2024 2)))
  (should (equal "January 2025"  (taskjuggler--cal-title-line 2025 1)))
  (should (equal "December 1999" (taskjuggler--cal-title-line 1999 12))))

;; --- taskjuggler--cal-render ---

(ert-deftest taskjuggler-cal-render--line-count ()
  "cal-render returns 2 header lines plus one line per week row.
February 2024 has 5 week rows, so 7 lines total."
  (let ((lines (taskjuggler--cal-render 2024 2 15)))
    (should (= 7 (length lines)))))

(ert-deftest taskjuggler-cal-render--title-in-first-line ()
  "The first line contains the month name and year."
  (let ((lines (taskjuggler--cal-render 2024 2 15)))
    (should (string-match-p "February" (substring-no-properties (nth 0 lines))))
    (should (string-match-p "2024"     (substring-no-properties (nth 0 lines))))))

(ert-deftest taskjuggler-cal-render--all-lines-have-cal-width ()
  "Every line from cal-render is exactly `taskjuggler--cal-width' characters wide."
  (let ((lines (taskjuggler--cal-render 2024 2 15)))
    (dolist (line lines)
      (should (= taskjuggler--cal-width
                 (length (substring-no-properties line)))))))

;;; taskjuggler-cal-show-week-numbers

;; All tests in this section bind `taskjuggler-cal-show-week-numbers' explicitly
;; so they are independent of the user's configuration.

;; --- nil (default) ---

(ert-deftest taskjuggler-cal-week-numbers--nil-render-width ()
  "With show-week-numbers nil, every rendered line is exactly 22 chars wide."
  (let ((taskjuggler-cal-show-week-numbers nil))
    (dolist (line (taskjuggler--cal-render 2024 2 15))
      (should (= 22 (length (substring-no-properties line)))))))

(ert-deftest taskjuggler-cal-week-numbers--nil-no-ww-prefix ()
  "With show-week-numbers nil, no week row starts with \"WW\"."
  (let ((taskjuggler-cal-show-week-numbers nil))
    (dolist (row (taskjuggler--cal-week-lines 2024 2 15 2026 1 1))
      (should-not (string-prefix-p "WW" (substring-no-properties row))))))

(ert-deftest taskjuggler-cal-week-numbers--nil-day-header-starts-with-space ()
  "With show-week-numbers nil, the day-header line (index 1) starts with \" Su\"."
  (let ((taskjuggler-cal-show-week-numbers nil))
    (let ((hdr (substring-no-properties (nth 1 (taskjuggler--cal-render 2024 2 15)))))
      (should (string-prefix-p " Su" hdr)))))

;; --- t ---

(ert-deftest taskjuggler-cal-week-numbers--t-render-width ()
  "With show-week-numbers t, every rendered line is exactly 26 chars wide.
The base width is 22; the WW label (\"WW%02d\") adds 4 chars, making 26."
  (let ((taskjuggler-cal-show-week-numbers t))
    (dolist (line (taskjuggler--cal-render 2024 2 15))
      (should (= 26 (length (substring-no-properties line)))))))

(ert-deftest taskjuggler-cal-week-numbers--t-ww-prefix ()
  "With show-week-numbers t, every week row starts with \"WW\"."
  (let ((taskjuggler-cal-show-week-numbers t))
    (dolist (row (taskjuggler--cal-week-lines 2024 2 15 2026 1 1))
      (should (string-prefix-p "WW" (substring-no-properties row))))))

(ert-deftest taskjuggler-cal-week-numbers--t-ww-face ()
  "With show-week-numbers t, the \"WW\" label carries `taskjuggler-cal-week-face'."
  (let ((taskjuggler-cal-show-week-numbers t))
    (dolist (row (taskjuggler--cal-week-lines 2024 2 15 2026 1 1))
      (should (eq 'taskjuggler-cal-week-face (get-text-property 0 'face row))))))

(ert-deftest taskjuggler-cal-week-numbers--t-day-header-has-5-space-prefix ()
  "With show-week-numbers t, the day-header line (index 1) starts with 5 spaces."
  (let ((taskjuggler-cal-show-week-numbers t))
    (let ((hdr (substring-no-properties (nth 1 (taskjuggler--cal-render 2024 2 15)))))
      (should (string-prefix-p "     Su" hdr)))))

(ert-deftest taskjuggler-cal-week-numbers--t-correct-iso-weeks ()
  "With show-week-numbers t, Feb 2024 rows show the correct ISO week labels.
Feb 2024 starts on Thursday (start-dow=4).  Thursday of each row:
  Row 0: Thu=Feb  1 → WW05
  Row 1: Thu=Feb  8 → WW06
  Row 2: Thu=Feb 15 → WW07
  Row 3: Thu=Feb 22 → WW08
  Row 4: Thu=Feb 29 → WW09"
  (let ((taskjuggler-cal-show-week-numbers t))
    (let ((weeks (taskjuggler--cal-week-lines 2024 2 15 2026 1 1)))
      (should (string-prefix-p "WW05" (substring-no-properties (nth 0 weeks))))
      (should (string-prefix-p "WW06" (substring-no-properties (nth 1 weeks))))
      (should (string-prefix-p "WW07" (substring-no-properties (nth 2 weeks))))
      (should (string-prefix-p "WW08" (substring-no-properties (nth 3 weeks))))
      (should (string-prefix-p "WW09" (substring-no-properties (nth 4 weeks)))))))

;;; taskjuggler--partial-date-bounds-at-point

;; A partial date is any prefix of YYYY-MM-DD (1-9 chars) that is not a
;; complete date and is not followed by a character that makes it a duration
;; literal (letter) or a larger number (digit) or a float (decimal point).

(ert-deftest taskjuggler-partial-date-bounds-at-point--two-digit-year ()
  "Returns bounds for a 2-digit year prefix at point."
  (with-temp-buffer
    (insert "start 20 end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "20")
    (backward-char 1)                   ; point on "0"
    (let ((bounds (taskjuggler--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "20"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--four-digit-year ()
  "Returns bounds for a standalone 4-digit year at point."
  (with-temp-buffer
    (insert "start 2026 end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026")
    (backward-char 1)                   ; point on last "6"
    (let ((bounds (taskjuggler--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--year-with-dash ()
  "Returns bounds for YYYY- at point."
  (with-temp-buffer
    (insert "start 2026-\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-")
    (backward-char 1)                   ; point on "-"
    (let ((bounds (taskjuggler--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026-"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--year-month ()
  "Returns bounds for YYYY-MM at point."
  (with-temp-buffer
    (insert "start 2026-04\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-04")
    (backward-char 1)
    (let ((bounds (taskjuggler--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026-04"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--year-month-dash ()
  "Returns bounds for YYYY-MM- at point."
  (with-temp-buffer
    (insert "start 2026-04-\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-04-")
    (backward-char 1)
    (let ((bounds (taskjuggler--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026-04-"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--complete-date-excluded ()
  "Returns nil for a complete date (handled by taskjuggler--date-bounds-at-point)."
  (with-temp-buffer
    (insert "start 2026-04-07\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026")
    (should (null (taskjuggler--partial-date-bounds-at-point)))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--duration-excluded ()
  "Returns nil when the digit sequence is immediately followed by a letter."
  ;; \"5d\" — the \"5\" is followed by \"d\", so it must not be matched.
  (with-temp-buffer
    (insert "length 5d\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "5")
    (backward-char 1)
    (should (null (taskjuggler--partial-date-bounds-at-point)))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--float-excluded ()
  "Returns nil when the digit sequence is followed by a decimal point."
  ;; \"2.5\" — the \"2\" is followed by \".\", so it must not be matched.
  (with-temp-buffer
    (insert "effort 2.5h\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2")
    (backward-char 1)
    (should (null (taskjuggler--partial-date-bounds-at-point)))))

(ert-deftest taskjuggler-partial-date-bounds-at-point--non-numeric-text ()
  "Returns nil when point is on non-numeric text."
  (with-temp-buffer
    (insert "task foo\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "foo")
    (backward-char 1)
    (should (null (taskjuggler--partial-date-bounds-at-point)))))

;;; taskjuggler--parse-partial-date

(ert-deftest taskjuggler-parse-partial-date--empty-uses-defaults ()
  "An empty prefix leaves all components at the default values."
  (should (equal '(2026 4 7)
                 (taskjuggler--parse-partial-date "" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--two-digit-year-uses-default ()
  "A 2-digit prefix is too short to parse the year; defaults are used."
  (should (equal '(2026 4 7)
                 (taskjuggler--parse-partial-date "20" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--four-digit-year ()
  "Four typed digits set the year; month and day come from the default."
  (should (equal '(2025 4 7)
                 (taskjuggler--parse-partial-date "2025" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--year-with-dash ()
  "YYYY- (5 chars) sets the year; month and day come from the default."
  (should (equal '(2025 4 7)
                 (taskjuggler--parse-partial-date "2025-" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--year-and-month ()
  "YYYY-MM sets year and month; day comes from the default."
  (should (equal '(2025 3 7)
                 (taskjuggler--parse-partial-date "2025-03" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--year-and-single-digit-month ()
  "YYYY-M (1-digit month) sets year and month; day comes from the default."
  (should (equal '(2026 4 7)
                 (taskjuggler--parse-partial-date "2026-4" '(2026 1 7)))))

(ert-deftest taskjuggler-parse-partial-date--full-ten-chars ()
  "All 10 characters set year, month, and day."
  (should (equal '(2025 3 20)
                 (taskjuggler--parse-partial-date "2025-03-20" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--invalid-month-ignored ()
  "An invalid month value (e.g. 13) leaves the month at the default."
  (should (equal '(2025 4 7)
                 (taskjuggler--parse-partial-date "2025-13" '(2026 4 7)))))

(ert-deftest taskjuggler-parse-partial-date--day-clamped-to-month ()
  "When the default day exceeds the days in the parsed month, it is clamped."
  ;; Default day=31, but February 2025 only has 28 days.
  (should (equal '(2025 2 28)
                 (taskjuggler--parse-partial-date "2025-02" '(2026 4 31)))))

;;; taskjuggler--cal-expand-tabs-with-props

(ert-deftest taskjuggler-cal-expand-tabs--no-tabs ()
  "A string without tabs is returned unchanged."
  (let ((tab-width 8))
    (should (equal "abcdef" (taskjuggler--cal-expand-tabs-with-props "abcdef")))))

(ert-deftest taskjuggler-cal-expand-tabs--tab-at-start ()
  "A leading tab expands to tab-width spaces."
  (let ((tab-width 8))
    (should (equal "        rest"
                   (taskjuggler--cal-expand-tabs-with-props "\trest")))))

(ert-deftest taskjuggler-cal-expand-tabs--tab-after-chars ()
  "A tab after N chars expands to (tab-width - N % tab-width) spaces."
  ;; \"abc\" is 3 chars; next tab stop at 8 requires 5 spaces.
  (let ((tab-width 8))
    (should (equal "abc     def"
                   (taskjuggler--cal-expand-tabs-with-props "abc\tdef")))))

(ert-deftest taskjuggler-cal-expand-tabs--two-tabs ()
  "Two leading tabs expand to 2*tab-width spaces."
  (let ((tab-width 8))
    (should (equal "                rest"
                   (taskjuggler--cal-expand-tabs-with-props "\t\trest")))))

(ert-deftest taskjuggler-cal-expand-tabs--tab-width-4 ()
  "Tab expansion respects a tab-width of 4."
  (let ((tab-width 4))
    (should (equal "    rest" (taskjuggler--cal-expand-tabs-with-props "\trest")))))

;;; taskjuggler--cal-splice-line (tab handling)

(ert-deftest taskjuggler-cal-splice-line--tab-at-start-col-8 ()
  "A leading tab is expanded before splicing; col=8 places new text correctly."
  ;; The tab expands to 8 spaces; splicing at col 8 puts new text right after.
  (let ((tab-width 8))
    (should (equal (concat (make-string 8 ?\s) "CAL")
                   (taskjuggler--cal-splice-line "\t" "CAL" 8)))))

(ert-deftest taskjuggler-cal-splice-line--tab-mid-line ()
  "A tab in the middle of old is expanded before splicing."
  ;; \"abc\\tdef\" with tab-width=8: \"abc\" (3 chars) + tab expands to 5 spaces
  ;; (reaching column 8) + \"def\" = \"abc     def\" (11 chars).
  ;; Splicing \"CAL\" (len=3) at col=4: left=\"abc \" (cols 0-3),
  ;; right=old-vis[7..]=\" def\" (the trailing space of the tab expansion + \"def\").
  (let ((tab-width 8))
    (should (equal "abc CAL def"
                   (taskjuggler--cal-splice-line "abc\tdef" "CAL" 4)))))

(ert-deftest taskjuggler-cal-splice-line--tab-expanded-consistent-width ()
  "Lines with tabs produce the same calendar column as equivalent space lines."
  ;; A line \"\\tX\" with tab-width=8 expands to \"        X\" (9 chars).
  ;; A line with 8 spaces then X also has 9 chars.  Splicing at col 4
  ;; should yield identical results for both.
  (let ((tab-width 8))
    (should (equal (taskjuggler--cal-splice-line "        X" "CAL" 4)
                   (taskjuggler--cal-splice-line "\tX" "CAL" 4)))))

(ert-deftest taskjuggler-cal-splice-line--preserves-text-properties ()
  "Text properties on the OLD string are preserved in the output."
  (let* ((old (propertize "leftXXXright" 'face 'font-lock-keyword-face))
         (result (taskjuggler--cal-splice-line old "CAL" 4)))
    ;; The left portion "left" should still carry the face property.
    (should (equal 'font-lock-keyword-face
                   (get-text-property 0 'face result)))
    ;; The right portion starting at col 7 ("right") should also have it.
    (should (equal 'font-lock-keyword-face
                   (get-text-property 7 'face result)))))

;;; taskjuggler-date-dwim

;; Helper macro: stub taskjuggler--cal-edit and optionally decode-time so
;; tests don't trigger overlays, minor-mode hooks, or depend on today's date.
(defmacro with-cal-edit-stubbed (decode-time-result &rest body)
  "Run BODY with `taskjuggler--cal-edit' stubbed to capture its args.
DECODE-TIME-RESULT is a list used as the return value of `decode-time'.
The captured argument list is bound to `cal-args' (a list of
\(date-beg year month day was-inserted)) within BODY."
  (declare (indent 1))
  `(let (cal-args)
     (cl-letf (((symbol-function 'taskjuggler--cal-edit)
                (lambda (date-beg year month day was-inserted)
                  (setq cal-args (list date-beg year month day was-inserted))))
               ((symbol-function 'decode-time)
                (lambda (&rest _) ,decode-time-result)))
       ,@body)
     cal-args))

(ert-deftest taskjuggler-date-dwim--complete-date-edits-in-place ()
  "On a complete date, opens the calendar for that date with was-inserted=nil."
  (with-temp-buffer
    (insert "start 2026-04-07 end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026")
    (backward-char 1)                   ; point on "2"
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 1 1 2025 1 nil 0)
                      (taskjuggler-date-dwim))))
      (should cal-args)
      (should (equal (list 2026 4 7 nil) (cdr cal-args)))
      ;; date-beg points at the "2" of "2026-04-07"
      (should (equal "2026-04-07"
                     (buffer-substring-no-properties
                      (car cal-args) (+ (car cal-args) 10)))))))

(ert-deftest taskjuggler-date-dwim--partial-date-seeds-calendar ()
  "On a partial date, replaces it with a full date and seeds the calendar."
  ;; Partial \"2026-04-\": year=2026, month=4, day falls back to default (15).
  (with-temp-buffer
    (insert "start 2026-04- end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-04-")
    (backward-char 1)                   ; point on trailing "-"
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 15 6 2025 1 nil 0)
                      (taskjuggler-date-dwim))))
      (should cal-args)
      ;; year and month come from the partial; day from the default.
      (should (equal (list 2026 4 15 t) (cdr cal-args)))
      (let ((date-beg (car cal-args)))
        ;; The partial was replaced with the full date string.
        (should (equal "2026-04-15"
                       (buffer-substring-no-properties
                        date-beg (+ date-beg 10))))
        ;; Point is after the length of the typed prefix (8 chars: "2026-04-").
        (should (= (point) (+ date-beg 8)))))))

(ert-deftest taskjuggler-date-dwim--eol-inserts-new-date ()
  "At end of line, inserts today's date and opens the calendar picker."
  (with-temp-buffer
    (insert "start ")
    (taskjuggler-mode)
    ;; Point is at end of buffer, which satisfies (eolp).
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 15 6 2025 1 nil 0)
                      (taskjuggler-date-dwim))))
      (should cal-args)
      (should (equal (list 2025 6 15 t) (cdr cal-args)))
      (let ((date-beg (car cal-args)))
        (should (equal "2025-06-15"
                       (buffer-substring-no-properties
                        date-beg (+ date-beg 10))))))))

(ert-deftest taskjuggler-date-dwim--whitespace-inserts-new-date ()
  "On a whitespace character, inserts today's date and opens the calendar picker."
  (with-temp-buffer
    (insert "start  end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "start ")
    ;; Point is now on the second space, satisfying (looking-at-p \"[ \\t]\").
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 15 6 2025 1 nil 0)
                      (taskjuggler-date-dwim))))
      (should cal-args)
      (should (equal (list 2025 6 15 t) (cdr cal-args))))))

(ert-deftest taskjuggler-date-dwim--non-date-text-signals-error ()
  "On non-date, non-whitespace text, signals a user-error."
  (with-temp-buffer
    (insert "task foo\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "foo")
    (backward-char 1)                   ; point on "f"
    (should-error (taskjuggler-date-dwim) :type 'user-error)))

;;; taskjuggler--fontify-tj3man tests

;; Sample output that mirrors the structure of real tj3man output.
(defconst test-tj3man-output
  "TaskJuggler v3.8.4 - A Project Management Software

Keyword:     task

Purpose:     Tasks are the central elements of a project plan. Use a task to
             specify the steps of the project.

Syntax:      task [<id>] <name> [<duration>
             <more>...]

Arguments:   id [ID]: An optional ID.

             ID: A unique uppercase ID.

             color name [STRING]: A unique multi-word name.

             name [STRING]: The name of the task

             duration: See 'duration' for details.

Context:     properties, task

Attributes:  allocate[sc:ip], depends[sc:ip], duration[sc],
             milestone[sc]

             [sc] : Attribute is scenario specific
             [ip] : Value can be inherited from parent property
")

(defmacro with-tj3man-buffer (&rest body)
  "Run BODY in a temp buffer containing `test-tj3man-output', fontified."
  `(with-temp-buffer
     (insert test-tj3man-output)
     (let ((taskjuggler--tj3man-keywords '("task" "allocate" "depends"
                                           "duration" "milestone" "properties"
                                           "interval2")))
       (taskjuggler--fontify-tj3man))
     ,@body))

(defun test-face-at-string (str)
  "Return the face text property at the start of STR in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (regexp-quote str))
    (get-text-property (match-beginning 0) 'face)))

(defun test-button-at-string (str)
  "Return the button at the start of STR in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (regexp-quote str))
    (get-text-property (match-beginning 0) 'button)))

(ert-deftest taskjuggler-fontify-tj3man--headers-get-overstrike ()
  "All six section headers receive the Man-overstrike face."
  (with-tj3man-buffer
   (should (eq 'Man-overstrike (test-face-at-string "Keyword:")))
   (should (eq 'Man-overstrike (test-face-at-string "Purpose:")))
   (should (eq 'Man-overstrike (test-face-at-string "Syntax:")))
   (should (eq 'Man-overstrike (test-face-at-string "Arguments:")))
   (should (eq 'Man-overstrike (test-face-at-string "Context:")))
   (should (eq 'Man-overstrike (test-face-at-string "Attributes:")))))

(ert-deftest taskjuggler-fontify-tj3man--syntax-args-get-underline ()
  "<argument> placeholders on the Syntax line receive the Man-underline face."
  (with-tj3man-buffer
   (should (eq 'Man-underline (test-face-at-string "<id>")))
   (should (eq 'Man-underline (test-face-at-string "<name>")))
   (should (eq 'Man-underline (test-face-at-string "<duration>")))))

(ert-deftest taskjuggler-fontify-tj3man--attributes-are-buttons ()
  "Entries in the Attributes section are buttons with the button face."
  (with-tj3man-buffer
   (should (test-button-at-string "allocate[sc:ip]"))
   (should (test-button-at-string "depends[sc:ip]"))
   (should (test-button-at-string "duration[sc]"))
   (should (test-button-at-string "milestone[sc]"))))

(ert-deftest taskjuggler-fontify-tj3man--attributes-legend-not-buttons ()
  "The [sc]/[ip] legend lines after the blank line are not turned into buttons."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     ;; Find the legend line and check it has no button property.
     (re-search-forward "\\[sc\\] : Attribute")
     (should-not (get-text-property (match-beginning 0) 'button)))))

(ert-deftest taskjuggler-fontify-tj3man--argument-names-get-overstrike ()
  "Argument names in the Arguments section receive Man-overstrike face."
  (with-tj3man-buffer
   ;; First argument (on same line as Arguments: header).
   (should (eq 'Man-overstrike (test-face-at-string "id [ID]:")))
   ;; Second argument (on its own indented line).
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "name \\[STRING\\]:")
     (should (eq 'Man-overstrike
                 (get-text-property (match-beginning 0) 'face))))
   ;; Bare argument with no type.
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "duration:")
     (should (eq 'Man-overstrike
                 (get-text-property (match-beginning 0) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--argument-types-get-underline ()
  "Argument types (e.g. ID, STRING) in the Arguments section receive Man-underline face."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "\\[\\(ID\\)\\]")
     (should (eq 'Man-underline
                 (get-text-property (match-beginning 1) 'face))))
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "\\[\\(STRING\\)\\]")
     (should (eq 'Man-underline
                 (get-text-property (match-beginning 1) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--syntax-multiline-gets-underline ()
  "Man-underline is applied to <arg> placeholders on continuation lines of Syntax."
  (with-tj3man-buffer
   ;; <more> is on the second (continuation) line of the Syntax section.
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "^Syntax:")
     (re-search-forward "<more>")
     (should (eq 'Man-underline
                 (get-text-property (match-beginning 0) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--uppercase-argument-name-gets-overstrike ()
  "Argument names starting with an uppercase letter receive Man-overstrike face."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "^             \\(ID\\):")
     (should (eq 'Man-overstrike
                 (get-text-property (match-beginning 1) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--multiword-argument-name-gets-overstrike ()
  "Multi-word argument names receive Man-overstrike across the full name."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "color name")
     ;; Both the start and end of the multi-word name should be overstruck.
     (should (eq 'Man-overstrike
                 (get-text-property (match-beginning 0) 'face)))
     (should (eq 'Man-overstrike
                 (get-text-property (1- (match-end 0)) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--attribute-modifier-content-underlined ()
  "Each colon-separated key inside [...] gets Man-underline; \":\" stays default."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Attributes:")
     ;; Find the [sc:ip] modifier on allocate[sc:ip].
     (re-search-forward "allocate\\[\\(sc\\)\\(:\\)\\(ip\\)\\]")
     ;; First key "sc" is underlined.
     (should (eq 'Man-underline (get-text-property (match-beginning 1) 'face)))
     ;; Colon separator stays default face.
     (should-not (eq 'Man-underline (get-text-property (match-beginning 2) 'face)))
     ;; Second key "ip" is underlined.
     (should (eq 'Man-underline (get-text-property (match-beginning 3) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--attribute-button-on-name-only ()
  "The button in the Attributes section covers only the attribute name, not modifier tags."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Attributes:")
     (re-search-forward "allocate\\(\\[sc:ip\\]\\)")
     ;; The [ of the modifier tag should not carry the button property.
     (should-not (get-text-property (match-beginning 1) 'button)))))

(ert-deftest taskjuggler-fontify-tj3man--legend-modifier-content-underlined ()
  "Modifier keys in the [sc]/[ig]/[ip] legend lines get Man-underline face."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "\\[\\(sc\\)\\] : Attribute")
     (should (eq 'Man-underline
                 (get-text-property (match-beginning 1) 'face))))))

(ert-deftest taskjuggler-fontify-tj3man--argument-keyword-not-linkified ()
  "An argument name that is also a known keyword keeps Man-overstrike, not button face."
  (with-tj3man-buffer
   ;; \"duration\" is in the keyword list AND appears as an argument name.
   ;; It should have Man-overstrike face (not button face).
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "duration:")
     (let ((pos (match-beginning 0)))
       (should (eq 'Man-overstrike (get-text-property pos 'face)))))))

(ert-deftest taskjuggler-fontify-tj3man--keyword-line-value-not-a-button ()
  "The keyword value on the Keyword: line is not linkified."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "^Keyword:[ \t]+")
     (should-not (get-text-property (point) 'button)))))

(ert-deftest taskjuggler-fontify-tj3man--syntax-line-keyword-not-a-button ()
  "The keyword name (first word) on the Syntax: line is not linkified."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "^Syntax:[ \t]+")
     (should-not (get-text-property (point) 'button)))))

(ert-deftest taskjuggler-fontify-tj3man--keywords-in-text-are-buttons ()
  "Known tj3man keywords appearing in the text body are linkified."
  (with-tj3man-buffer
   ;; \"task\" appears as prose in the Purpose section ("Use a task to").
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Purpose:")
     ;; Search for standalone "task" (lowercase, not part of "Tasks").
     (re-search-forward "Use a task")
     (should (get-text-property (- (match-end 0) 4) 'button)))
   ;; \"properties\" appears on the Context line and should be linkified.
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Context:")
     (re-search-forward "properties")
     (should (get-text-property (match-beginning 0) 'button)))))

;;; Calendar picker

;; ---- Clamp day ----

(ert-deftest tj-cal-clamp-day ()
  "Test day clamping to month bounds."
  (should (= 28 (taskjuggler--cal-clamp-day 2023 2 31)))
  (should (= 29 (taskjuggler--cal-clamp-day 2024 2 31)))
  (should (= 15 (taskjuggler--cal-clamp-day 2024 3 15)))
  (should (= 30 (taskjuggler--cal-clamp-day 2024 4 31))))

;; ---- Date adjustment ----

(ert-deftest tj-cal-adjust-day ()
  "Test day-level adjustment, including month/year wrapping."
  (should (equal '(2024 1 2) (taskjuggler--cal-adjust-date 2024 1 1 1 :day)))
  (should (equal '(2023 12 31) (taskjuggler--cal-adjust-date 2024 1 1 -1 :day)))
  (should (equal '(2024 2 1) (taskjuggler--cal-adjust-date 2024 1 31 1 :day)))
  (should (equal '(2024 3 1) (taskjuggler--cal-adjust-date 2024 2 29 1 :day))))

(ert-deftest tj-cal-adjust-week ()
  "Test week-level adjustment."
  (should (equal '(2024 1 8) (taskjuggler--cal-adjust-date 2024 1 1 1 :week)))
  (should (equal '(2023 12 25) (taskjuggler--cal-adjust-date 2024 1 1 -1 :week))))

(ert-deftest tj-cal-adjust-month ()
  "Test month-level adjustment, including day clamping and year wrapping."
  (should (equal '(2024 2 15) (taskjuggler--cal-adjust-date 2024 1 15 1 :month)))
  ;; Jan 31 + 1 month = Feb 29 (2024 is leap).
  (should (equal '(2024 2 29) (taskjuggler--cal-adjust-date 2024 1 31 1 :month)))
  ;; Jan 31 + 1 month in non-leap year = Feb 28.
  (should (equal '(2023 2 28) (taskjuggler--cal-adjust-date 2023 1 31 1 :month)))
  ;; Dec + 1 month = Jan next year.
  (should (equal '(2025 1 15) (taskjuggler--cal-adjust-date 2024 12 15 1 :month)))
  ;; Jan - 1 month = Dec previous year.
  (should (equal '(2023 12 15) (taskjuggler--cal-adjust-date 2024 1 15 -1 :month))))

;; ---- TJ date parsing ----

(ert-deftest tj-cal-parse-tj-date ()
  "Test parsing TJ3 date strings."
  (should (equal '(2024 3 15) (taskjuggler--parse-tj-date "2024-03-15")))
  (should (equal '(2024 3 15) (taskjuggler--parse-tj-date "2024-03-15-10:30")))
  (should (equal '(2024 3 15) (taskjuggler--parse-tj-date "2024-03-15-10:30:45")))
  (should-not (taskjuggler--parse-tj-date "not-a-date")))

;; ---- TJ date formatting ----

(ert-deftest tj-cal-format-tj-date ()
  "Test formatting year/month/day into TJ3 date string."
  (should (equal "2024-03-15" (taskjuggler--format-tj-date 2024 3 15)))
  (should (equal "2024-01-01" (taskjuggler--format-tj-date 2024 1 1))))

;; ---- Typed prefix parsing ----

(ert-deftest tj-cal-parse-typed-prefix-year ()
  "Test parsing after the year portion is typed."
  (with-temp-buffer
    (insert "2025-04-01")
    ;; 4 chars typed → year parsed, month/day from default.
    (should (equal '(2025 3 15)
                   (taskjuggler--cal-parse-typed-prefix 1 4 '(2024 3 15))))
    ;; 7 chars typed → year and month parsed.
    (should (equal '(2025 4 15)
                   (taskjuggler--cal-parse-typed-prefix 1 7 '(2024 3 15))))
    ;; 10 chars typed → full date.
    (should (equal '(2025 4 1)
                   (taskjuggler--cal-parse-typed-prefix 1 10 '(2024 3 15))))))

(ert-deftest tj-cal-parse-typed-prefix-clamps-day ()
  "Test that day is clamped when month changes."
  (with-temp-buffer
    ;; Feb has 28 days in 2025, default day=31 should clamp.
    (insert "2025-02-28")
    (should (equal '(2025 2 28)
                   (taskjuggler--cal-parse-typed-prefix 1 7 '(2025 1 31))))))

(ert-deftest tj-cal-valid-char-at-p ()
  "Test character validation at each position."
  ;; Digits at non-hyphen positions.
  (should (taskjuggler--cal-valid-char-at-p ?2 0))
  (should (taskjuggler--cal-valid-char-at-p ?0 3))
  ;; Hyphens at positions 4 and 7.
  (should (taskjuggler--cal-valid-char-at-p ?- 4))
  (should (taskjuggler--cal-valid-char-at-p ?- 7))
  ;; Digits not valid at hyphen positions.
  (should-not (taskjuggler--cal-valid-char-at-p ?1 4))
  ;; Hyphens not valid at digit positions.
  (should-not (taskjuggler--cal-valid-char-at-p ?- 0)))

;; ---- Face application ----

(ert-deftest tj-cal-apply-faces ()
  "Test that typing and pending faces are applied correctly."
  (with-temp-buffer
    (insert "2024-03-15")
    (taskjuggler--cal-apply-faces 1 4)
    ;; First 4 chars should have typing face (applied via overlays).
    (should (eq 'taskjuggler-cal-typing-face
                (get-char-property 1 'face)))
    ;; Remaining chars should have pending face.
    (should (eq 'taskjuggler-cal-pending-face
                (get-char-property 5 'face)))
    ;; Remove faces.
    (taskjuggler--cal-remove-faces 1)
    (should-not (get-char-property 1 'face))
    (should-not (get-char-property 5 'face))))

;; ---- Calendar rendering ----

(ert-deftest tj-cal-render-returns-list ()
  "Test that render returns a list of strings with expected structure."
  (let ((lines (taskjuggler--cal-render 2026 3 1)))
    ;; Returns a list, not a string.
    (should (listp lines))
    ;; First line is title, second is day header, rest are weeks.
    (should (>= (length lines) 4))
    ;; Title contains month and year.
    (should (string-match-p "March 2026" (substring-no-properties (nth 0 lines))))
    ;; Day header row.
    (should (string-match-p "Su Mo Tu We Th Fr Sa" (substring-no-properties (nth 1 lines))))))

(ert-deftest tj-cal-render-selected-day-face ()
  "Test that the selected day has the selected face."
  (let* ((lines (taskjuggler--cal-render 2024 1 15))
         (all (mapconcat #'identity lines "\n"))
         ;; Find "15" in the output.
         (pos (string-match "15" all)))
    (should pos)
    (should (eq 'taskjuggler-cal-selected-face (get-text-property pos 'face all)))))

(ert-deftest tj-cal-render-inactive-days ()
  "Test that prev/next month fill days have the inactive face."
  ;; March 2026 starts on Sunday — no leading inactive days.
  ;; It has 31 days, and the grid has 5 weeks (35 cells), so 4 trailing.
  (let* ((lines (taskjuggler--cal-render 2026 3 15))
         (last-week (substring-no-properties (car (last lines)))))
    ;; Last week should contain days 1-4 from April (inactive).
    (should (string-match-p " 1" last-week))
    ;; Check the face on a trailing day.
    (let* ((last-line (car (last lines)))
           (pos (string-match " 1" last-line)))
      ;; The "1" character (pos+1) should have inactive face.
      (should (eq 'taskjuggler-cal-inactive-face
                  (get-text-property (1+ pos) 'face last-line))))))

(ert-deftest tj-cal-render-leading-inactive ()
  "Test that leading days from the previous month are shown."
  ;; Feb 2026 starts on Sunday — no leading days.
  ;; Jan 2026 starts on Thursday (dow=4) — 4 leading days from Dec 2025.
  (let* ((lines (taskjuggler--cal-render 2026 1 10))
         (first-week (substring-no-properties (nth 2 lines))))
    ;; First week row should start with Dec 28 (Sun), 29, 30, 31.
    (should (string-match-p "28" first-week))
    (should (string-match-p "31" first-week))))

(ert-deftest tj-cal-render-consistent-width ()
  "Test that all lines have the same width."
  (let* ((lines (taskjuggler--cal-render 2026 3 15))
         (widths (mapcar #'length lines)))
    (should (= 1 (length (delete-dups widths))))))

;; ---- Line splicing ----

(ert-deftest tj-cal-splice-line-middle ()
  "Test splicing calendar content into the middle of a line."
  (should (equal "abcXXXghi"
                 (taskjuggler--cal-splice-line "abcdefghi" "XXX" 3))))

(ert-deftest tj-cal-splice-line-short ()
  "Test splicing when the original line is shorter than the column."
  (should (equal "ab   XXX"
                 (taskjuggler--cal-splice-line "ab" "XXX" 5))))

(ert-deftest tj-cal-splice-line-at-start ()
  "Test splicing at column 0."
  (should (equal "XXXdefghi"
                 (taskjuggler--cal-splice-line "abcdefghi" "XXX" 0))))

(ert-deftest tj-cal-splice-line-past-end ()
  "Test splicing when content extends past the end of the original line."
  (should (equal "abcXXXXX"
                 (taskjuggler--cal-splice-line "abcde" "XXXXX" 3))))

;; ---- Integration: date-bounds-at-point ----

(ert-deftest tj-cal-date-bounds-at-point ()
  "Test finding date bounds in a buffer."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (goto-char (+ 7 (point-min)))  ; position within the date
    (let ((bounds (taskjuggler--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-03-15"
                     (buffer-substring-no-properties (car bounds) (cdr bounds)))))))

(ert-deftest tj-cal-date-bounds-at-point-none ()
  "Test that nil is returned when not on a date."
  (with-temp-buffer
    (insert "start foo\n")
    (goto-char (+ 7 (point-min)))
    (should-not (taskjuggler--date-bounds-at-point))))

;;; Tests: taskjuggler--cursor-parse-field

(ert-deftest taskjuggler-cursor-parse-field--quoted-value ()
  "Parses a quoted string value."
  (should (equal "outer.inner"
                 (taskjuggler--cursor-parse-field
                  "window._tjCursorTaskId = \"outer.inner\";\n"
                  "_tjCursorTaskId"))))

(ert-deftest taskjuggler-cursor-parse-field--numeric-value ()
  "Parses a bare integer value."
  (should (equal "1712844002"
                 (taskjuggler--cursor-parse-field
                  "window._tjCursorTs     = 1712844002;\n"
                  "_tjCursorTs"))))

(ert-deftest taskjuggler-cursor-parse-field--null-value ()
  "Returns nil for null (unquoted non-numeric) assignments."
  (should (null (taskjuggler--cursor-parse-field
                 "window._tjCursorTaskId = null;\n"
                 "_tjCursorTaskId"))))

(ert-deftest taskjuggler-cursor-parse-field--missing-field ()
  "Returns nil when the field is not present."
  (should (null (taskjuggler--cursor-parse-field
                 "window._tjClickTs = 0;\n"
                 "_tjCursorTaskId"))))

(ert-deftest taskjuggler-cursor-parse-field--all-four-fields ()
  "Parses all four fields from a complete tj-cursor.js content string."
  (let ((content (concat "window._tjCursorTaskId = \"foo.bar\";\n"
                         "window._tjCursorTs     = 1000;\n"
                         "window._tjClickTaskId  = \"baz.qux\";\n"
                         "window._tjClickTs      = 999;\n")))
    (should (equal "foo.bar"
                   (taskjuggler--cursor-parse-field content "_tjCursorTaskId")))
    (should (equal "1000"
                   (taskjuggler--cursor-parse-field content "_tjCursorTs")))
    (should (equal "baz.qux"
                   (taskjuggler--cursor-parse-field content "_tjClickTaskId")))
    (should (equal "999"
                   (taskjuggler--cursor-parse-field content "_tjClickTs")))))

;;; Tests: taskjuggler--goto-task-id

(ert-deftest taskjuggler-goto-task-id--top-level ()
  "Navigates to a top-level task."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-max))
    (should (taskjuggler--goto-task-id "outer"))
    (should (looking-at "task outer"))))

(ert-deftest taskjuggler-goto-task-id--nested ()
  "Navigates to a nested task by its full dotted ID."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n  task inner \"Inner\" {\n  }\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-max))
    (should (taskjuggler--goto-task-id "outer.inner"))
    (should (looking-at "[ \t]*task inner"))))

(ert-deftest taskjuggler-goto-task-id--disambiguates-same-leaf-id ()
  "Uses the full hierarchy to distinguish tasks with the same leaf ID."
  (with-temp-buffer
    (insert "task alpha \"Alpha\" {\n  task child \"Child\" {\n  }\n}\n"
            "task beta \"Beta\" {\n  task child \"Child\" {\n  }\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-max))
    (should (taskjuggler--goto-task-id "beta.child"))
    ;; Point should be on the second `task child' line (inside beta).
    (should (looking-at "[ \t]*task child"))
    (should (equal "beta.child" (taskjuggler--full-task-id-at-point)))))

(ert-deftest taskjuggler-goto-task-id--returns-nil-for-unknown ()
  "Returns nil and leaves point unchanged when the task is not found."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (should-not (taskjuggler--goto-task-id "outer.nonexistent"))))

;;; Tests: daemon management

(ert-deftest taskjuggler-find-tjp-file--returns-tjp-directly ()
  "Returns the buffer file when visiting a .tjp file."
  (let ((tjp-file (expand-file-name "test.tjp" temporary-file-directory)))
    (with-temp-buffer
      (setq buffer-file-name tjp-file)
      (should (equal tjp-file (taskjuggler--find-tjp-file))))))

(ert-deftest taskjuggler-find-tjp-file--searches-for-tji ()
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
            (should (equal tjp (taskjuggler--find-tjp-file)))))
      (delete-directory dir t))))

(ert-deftest taskjuggler-find-tjp-file--nil-for-other-files ()
  "Returns nil when not visiting a .tjp or .tji file."
  (with-temp-buffer
    (setq buffer-file-name "/tmp/notes.txt")
    (should-not (taskjuggler--find-tjp-file))))

(ert-deftest taskjuggler-find-tjp-file--nil-for-no-file ()
  "Returns nil when the buffer is not visiting a file."
  (with-temp-buffer
    (should-not (taskjuggler--find-tjp-file))))

(ert-deftest taskjuggler-daemon-update-modeline--no-daemons ()
  "Modeline is empty when neither daemon is running."
  (let ((taskjuggler--daemon-modeline "old"))
    (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () nil))
              ((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () nil)))
      (taskjuggler--daemon-update-modeline)
      (should (equal "" taskjuggler--daemon-modeline)))))

(ert-deftest taskjuggler-daemon-update-modeline--tj3d-only ()
  "Modeline shows tj3d icon when only tj3d is running."
  (let ((taskjuggler--daemon-modeline ""))
    (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () t))
              ((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () nil)))
      (taskjuggler--daemon-update-modeline)
      (should (string-match-p "󰙬" taskjuggler--daemon-modeline))
      (should-not (string-match-p "󰒍" taskjuggler--daemon-modeline)))))

(ert-deftest taskjuggler-daemon-update-modeline--tj3webd-only ()
  "Modeline shows tj3webd icon when only tj3webd is running."
  (let ((taskjuggler--daemon-modeline ""))
    (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () nil))
              ((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () t)))
      (taskjuggler--daemon-update-modeline)
      (should (string-match-p "󰒍" taskjuggler--daemon-modeline))
      (should-not (string-match-p "󰙬" taskjuggler--daemon-modeline)))))

(ert-deftest taskjuggler-daemon-update-modeline--both ()
  "Modeline shows both icons when both daemons are running."
  (let ((taskjuggler--daemon-modeline ""))
    (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () t))
              ((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () t)))
      (taskjuggler--daemon-update-modeline)
      (should (string-match-p "󰙬" taskjuggler--daemon-modeline))
      (should (string-match-p "󰒍" taskjuggler--daemon-modeline)))))

;;; Tests: tj3d diagnostics, scheduling, and Flymake integration

(require 'flymake)

(defmacro with-clean-tj3d-state (&rest body)
  "Run BODY with tj3d diagnostics, queue, and tracked state freshly bound.
Each invocation gets isolated hash tables and queue variables so tests
don't leak state into one another."
  (declare (indent 0))
  `(let ((taskjuggler--tj3d-diagnostics (make-hash-table :test 'equal))
         (taskjuggler--tj3d-diag-files-by-project (make-hash-table :test 'equal))
         (taskjuggler--tj3d-tracked-projects (make-hash-table :test 'equal))
         (taskjuggler--tj3d-refresh-queue nil)
         (taskjuggler--tj3d-refresh-in-flight nil))
     ,@body))

;; taskjuggler--tj3-project-id

(ert-deftest taskjuggler-tj3-project-id--from-buffer ()
  "Reads the project ID from a buffer visiting TJP."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (let ((buf (find-file-noselect tjp)))
          (unwind-protect
              (with-current-buffer buf
                (insert "project myproj \"My Project\" 2024-01-01 +1y {\n}\n")
                (should (equal "myproj" (taskjuggler--tj3-project-id tjp))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
      (delete-directory dir t))))

(ert-deftest taskjuggler-tj3-project-id--from-file ()
  "Reads the project ID from disk when no buffer is visiting TJP."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (progn
          (write-region "project xy.zz \"X\" 2024-01-01 +1y {\n}\n" nil tjp)
          (should (equal "xy.zz" (taskjuggler--tj3-project-id tjp))))
      (delete-directory dir t))))

(ert-deftest taskjuggler-tj3-project-id--no-project ()
  "Returns nil when the file has no project declaration."
  (let* ((dir (make-temp-file "tj-test-" t))
         (tjp (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (progn
          (write-region "task t \"T\" {\n}\n" nil tjp)
          (should-not (taskjuggler--tj3-project-id tjp)))
      (delete-directory dir t))))

(ert-deftest taskjuggler-tj3-project-id--nil-for-missing-file ()
  "Returns nil when TJP cannot be read."
  (should-not (taskjuggler--tj3-project-id "/no/such/file.tjp")))

;; taskjuggler--tj3d-record-diagnostic / clear-diagnostics-for-project

(ert-deftest taskjuggler-tj3d-record-diagnostic--basic ()
  "Records a diagnostic and tracks the file under the project."
  (with-clean-tj3d-state
   (taskjuggler--tj3d-record-diagnostic "/tmp/p.tjp" 7 :error "msg" "/tmp/p.tjp")
   (should (equal (list (list 7 :error "msg"))
                  (gethash "/tmp/p.tjp" taskjuggler--tj3d-diagnostics)))
   (should (equal (list "/tmp/p.tjp")
                  (gethash "/tmp/p.tjp"
                           taskjuggler--tj3d-diag-files-by-project)))))

(ert-deftest taskjuggler-tj3d-record-diagnostic--relative-resolves-to-tjp-dir ()
  "Relative file paths are expanded against the directory of TJP."
  (with-clean-tj3d-state
   (taskjuggler--tj3d-record-diagnostic "tasks.tji" 3 :warning "warn"
                                        "/tmp/proj/p.tjp")
   (should (gethash "/tmp/proj/tasks.tji" taskjuggler--tj3d-diagnostics))))

(ert-deftest taskjuggler-tj3d-record-diagnostic--dedups-files-list ()
  "Recording two diagnostics on the same file lists it once."
  (with-clean-tj3d-state
   (taskjuggler--tj3d-record-diagnostic "/tmp/p.tjp" 7 :error "a" "/tmp/p.tjp")
   (taskjuggler--tj3d-record-diagnostic "/tmp/p.tjp" 8 :error "b" "/tmp/p.tjp")
   (should (equal (list "/tmp/p.tjp")
                  (gethash "/tmp/p.tjp"
                           taskjuggler--tj3d-diag-files-by-project)))
   (should (= 2 (length (gethash "/tmp/p.tjp"
                                 taskjuggler--tj3d-diagnostics))))))

(ert-deftest taskjuggler-tj3d-clear-diagnostics-for-project--isolates-other-projects ()
  "Clearing TJP-A removes only its files, returns them, and leaves TJP-B intact."
  (with-clean-tj3d-state
   (taskjuggler--tj3d-record-diagnostic "/tmp/a.tjp" 1 :error "x" "/tmp/a.tjp")
   (taskjuggler--tj3d-record-diagnostic "/tmp/inc.tji" 2 :error "y"
                                        "/tmp/a.tjp")
   (taskjuggler--tj3d-record-diagnostic "/tmp/b.tjp" 1 :error "z" "/tmp/b.tjp")
   (let ((cleared (taskjuggler--tj3d-clear-diagnostics-for-project
                   "/tmp/a.tjp")))
     (should (equal (sort (copy-sequence cleared) #'string<)
                    '("/tmp/a.tjp" "/tmp/inc.tji")))
     (should-not (gethash "/tmp/a.tjp" taskjuggler--tj3d-diagnostics))
     (should-not (gethash "/tmp/inc.tji" taskjuggler--tj3d-diagnostics))
     (should-not (gethash "/tmp/a.tjp"
                          taskjuggler--tj3d-diag-files-by-project))
     (should (gethash "/tmp/b.tjp" taskjuggler--tj3d-diagnostics)))))

(ert-deftest taskjuggler-tj3d-clear-diagnostics-for-project--unknown-project ()
  "Returns nil and is harmless when TJP has no recorded diagnostics."
  (with-clean-tj3d-state
   (should-not
    (taskjuggler--tj3d-clear-diagnostics-for-project "/tmp/none.tjp"))))

;; taskjuggler--tj3d-scan-include-lines

(ert-deftest taskjuggler-tj3d-scan-include-lines--from-buffer ()
  "Returns line numbers of include statements matching BASENAME."
  (with-temp-buffer
    (insert "project p \"P\" 2024-01-01 +1y {\n}\n"
            "include \"tasks.tji\"\n"
            "include \"sub/tasks.tji\"\n"
            "include \"resources.tji\"\n")
    (should (equal '(3 4)
                   (taskjuggler--tj3d-scan-include-lines
                    (current-buffer) "tasks.tji")))))

(ert-deftest taskjuggler-tj3d-scan-include-lines--from-file ()
  "Reads the file from disk when SOURCE is a path, not a buffer."
  (let* ((dir (make-temp-file "tj-test-" t))
         (file (expand-file-name "p.tjp" dir)))
    (unwind-protect
        (progn
          (write-region "include \"a.tji\"\ninclude \"b.tji\"\n" nil file)
          (should (equal '(2)
                         (taskjuggler--tj3d-scan-include-lines file "b.tji"))))
      (delete-directory dir t))))

(ert-deftest taskjuggler-tj3d-scan-include-lines--unreadable-returns-nil ()
  "Unreadable file paths yield nil rather than an error."
  (should-not (taskjuggler--tj3d-scan-include-lines "/no/such/file.tjp"
                                                    "x.tji")))

(ert-deftest taskjuggler-tj3d-scan-include-lines--no-matches ()
  "Returns nil when no include statement names BASENAME."
  (with-temp-buffer
    (insert "include \"other.tji\"\n")
    (should-not (taskjuggler--tj3d-scan-include-lines
                 (current-buffer) "missing.tji"))))

;; taskjuggler--tj3d-propagate-to-includers

(ert-deftest taskjuggler-tj3d-propagate-to-includers--records-on-include-line ()
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
           (taskjuggler--tj3d-propagate-to-includers tji :error "boom" tjp)
           (let ((entries (gethash tjp taskjuggler--tj3d-diagnostics)))
             (should (= 1 (length entries)))
             (let ((e (car entries)))
               (should (= 3 (nth 0 e)))
               (should (eq :error (nth 1 e)))
               (should (string-match-p "tasks.tji" (nth 2 e)))
               (should (string-match-p "boom" (nth 2 e))))))
       (delete-directory dir t)))))

(ert-deftest taskjuggler-tj3d-propagate-to-includers--skips-self ()
  "Does nothing when CHILD-FILE equals TJP itself."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "p.tjp" dir)))
     (unwind-protect
         (progn
           (write-region "include \"p.tjp\"\n" nil tjp)
           (taskjuggler--tj3d-propagate-to-includers tjp :error "x" tjp)
           (should-not (gethash tjp taskjuggler--tj3d-diagnostics)))
       (delete-directory dir t)))))

;; taskjuggler--tj3d-parse-diagnostics

(ert-deftest taskjuggler-tj3d-parse-diagnostics--records-error-and-warning ()
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
             (taskjuggler--tj3d-parse-diagnostics tjp))
           (let ((entries (gethash tjp taskjuggler--tj3d-diagnostics)))
             (should (member (list 5 :error "bad syntax") entries))
             (should (member (list 9 :warning "smelly") entries))))
       (delete-directory dir t)))))

(ert-deftest taskjuggler-tj3d-parse-diagnostics--propagates-include-errors ()
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
             (taskjuggler--tj3d-parse-diagnostics tjp))
           (should (gethash tji taskjuggler--tj3d-diagnostics))
           (let ((tjp-entries (gethash tjp taskjuggler--tj3d-diagnostics)))
             (should (= 1 (length tjp-entries)))
             (should (= 3 (nth 0 (car tjp-entries))))
             (should (string-match-p "tasks.tji" (nth 2 (car tjp-entries))))))
       (delete-directory dir t)))))

;; taskjuggler--tj3d-owns-current-buffer-p

(ert-deftest taskjuggler-tj3d-owns-current-buffer-p--true-when-loaded ()
  "Returns non-nil when the daemon reports the project as loaded."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler--tj3d-project-loaded-p)
              (lambda (_) t)))
     (with-temp-buffer
       (setq buffer-file-name (expand-file-name "x.tjp"
                                                temporary-file-directory))
       (should (taskjuggler--tj3d-owns-current-buffer-p))))))

(ert-deftest taskjuggler-tj3d-owns-current-buffer-p--true-when-cached-diags ()
  "Returns non-nil when diagnostics were recorded even if not loaded.
This covers the failed-add case where the daemon produced errors but
status doesn't list the project."
  (with-clean-tj3d-state
   (let ((tjp (expand-file-name "x.tjp" temporary-file-directory)))
     (puthash tjp '("dummy") taskjuggler--tj3d-diag-files-by-project)
     (cl-letf (((symbol-function 'taskjuggler--tj3d-project-loaded-p)
                (lambda (_) nil)))
       (with-temp-buffer
         (setq buffer-file-name tjp)
         (should (taskjuggler--tj3d-owns-current-buffer-p)))))))

(ert-deftest taskjuggler-tj3d-owns-current-buffer-p--false-when-neither ()
  "Returns nil when the project is neither loaded nor has cached diags."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler--tj3d-project-loaded-p)
              (lambda (_) nil)))
     (with-temp-buffer
       (setq buffer-file-name (expand-file-name "x.tjp"
                                                temporary-file-directory))
       (should-not (taskjuggler--tj3d-owns-current-buffer-p))))))

;; taskjuggler-tj3d-flymake-backend / taskjuggler-flymake-backend

(ert-deftest taskjuggler-tj3d-flymake-backend--yields-when-not-owned ()
  "Reports nil without inspecting the cache when tj3d does not own the buffer."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler--tj3d-owns-current-buffer-p)
              (lambda () nil)))
     (let (called reported)
       (taskjuggler-tj3d-flymake-backend
        (lambda (diags) (setq called t reported diags)))
       (should called)
       (should (null reported))))))

(ert-deftest taskjuggler-tj3d-flymake-backend--reports-cached-entries ()
  "Cached entries are converted to Flymake diagnostics on the source buffer."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (file (expand-file-name "proj.tjp" dir)))
     (unwind-protect
         (progn
           (write-region "line 1\nline 2\nline 3\n" nil file)
           (puthash (expand-file-name file)
                    (list (list 2 :error "boom"))
                    taskjuggler--tj3d-diagnostics)
           (cl-letf (((symbol-function 'taskjuggler--tj3d-owns-current-buffer-p)
                      (lambda () t)))
             (with-temp-buffer
               (setq buffer-file-name file)
               (insert-file-contents file)
               (let (reported)
                 (taskjuggler-tj3d-flymake-backend
                  (lambda (diags) (setq reported diags)))
                 (should (= 1 (length reported)))
                 (let ((d (car reported)))
                   (should (eq :error (flymake-diagnostic-type d)))
                   (should (equal "boom" (flymake-diagnostic-text d))))))))
       (delete-directory dir t)))))

(ert-deftest taskjuggler-flymake-backend--reports-nil-without-file ()
  "Backend reports nil without spawning a process when buffer has no file."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/tj3"))
            ((symbol-function 'make-process)
             (lambda (&rest _) (error "should not spawn"))))
    (with-temp-buffer
      (let (called reported)
        (taskjuggler-flymake-backend
         (lambda (diags) (setq called t reported diags)))
        (should called)
        (should (null reported))))))

(ert-deftest taskjuggler-flymake-backend--yields-when-tj3d-owns-buffer ()
  "Backend reports nil and skips the subprocess when tj3d owns the buffer."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/tj3"))
            ((symbol-function 'make-process)
             (lambda (&rest _) (error "should not spawn")))
            ((symbol-function 'taskjuggler--tj3d-owns-current-buffer-p)
             (lambda () t)))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "x.tjp"
                                               temporary-file-directory))
      (let (called reported)
        (taskjuggler-flymake-backend
         (lambda (diags) (setq called t reported diags)))
        (should called)
        (should (null reported))))))

;; taskjuggler--tj3d-schedule-refresh

(ert-deftest taskjuggler-tj3d-schedule-refresh--starts-immediately-when-idle ()
  "When nothing is in flight, scheduling kicks off the run synchronously."
  (with-clean-tj3d-state
   (let (calls)
     (cl-letf (((symbol-function 'taskjuggler--tj3d-add-project-run)
                (lambda (tjp quiet) (push (cons tjp quiet) calls))))
       (taskjuggler--tj3d-schedule-refresh "/tmp/proj.tjp" nil)
       (should (equal (expand-file-name "/tmp/proj.tjp")
                      taskjuggler--tj3d-refresh-in-flight))
       (should (equal calls (list (cons (expand-file-name "/tmp/proj.tjp")
                                        nil))))))))

(ert-deftest taskjuggler-tj3d-schedule-refresh--queues-when-other-in-flight ()
  "When a different path is running, the new request goes to the queue."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler--tj3d-add-project-run)
              (lambda (&rest _) nil)))
     (setq taskjuggler--tj3d-refresh-in-flight
           (expand-file-name "/tmp/a.tjp"))
     (taskjuggler--tj3d-schedule-refresh "/tmp/b.tjp" t)
     (should (equal taskjuggler--tj3d-refresh-queue
                    (list (cons (expand-file-name "/tmp/b.tjp") t)))))))

(ert-deftest taskjuggler-tj3d-schedule-refresh--drops-when-same-in-flight ()
  "Re-scheduling the path that's already running is a no-op."
  (with-clean-tj3d-state
   (let (calls)
     (cl-letf (((symbol-function 'taskjuggler--tj3d-add-project-run)
                (lambda (&rest _) (push 'called calls))))
       (setq taskjuggler--tj3d-refresh-in-flight
             (expand-file-name "/tmp/a.tjp"))
       (taskjuggler--tj3d-schedule-refresh "/tmp/a.tjp" t)
       (should (null calls))
       (should (null taskjuggler--tj3d-refresh-queue))))))

(ert-deftest taskjuggler-tj3d-schedule-refresh--drops-when-already-queued ()
  "Re-scheduling a path already in the queue is a no-op."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler--tj3d-add-project-run)
              (lambda (&rest _) nil)))
     (setq taskjuggler--tj3d-refresh-in-flight
           (expand-file-name "/tmp/a.tjp"))
     (setq taskjuggler--tj3d-refresh-queue
           (list (cons (expand-file-name "/tmp/b.tjp") t)))
     (taskjuggler--tj3d-schedule-refresh "/tmp/b.tjp" nil)
     (should (= 1 (length taskjuggler--tj3d-refresh-queue))))))

(ert-deftest taskjuggler-tj3d-drain-refresh-queue--launches-next ()
  "Drain pops the next queued entry, sets it in-flight, and launches it."
  (with-clean-tj3d-state
   (let (calls)
     (cl-letf (((symbol-function 'taskjuggler--tj3d-add-project-run)
                (lambda (tjp quiet) (push (cons tjp quiet) calls))))
       (setq taskjuggler--tj3d-refresh-queue
             (list (cons "/tmp/next.tjp" t)))
       (taskjuggler--tj3d-drain-refresh-queue)
       (should (equal calls (list (cons "/tmp/next.tjp" t))))
       (should (equal "/tmp/next.tjp" taskjuggler--tj3d-refresh-in-flight))
       (should (null taskjuggler--tj3d-refresh-queue))))))

(ert-deftest taskjuggler-tj3d-drain-refresh-queue--clears-when-empty ()
  "With an empty queue, drain just clears in-flight."
  (with-clean-tj3d-state
   (setq taskjuggler--tj3d-refresh-in-flight "/tmp/whatever.tjp")
   (taskjuggler--tj3d-drain-refresh-queue)
   (should (null taskjuggler--tj3d-refresh-in-flight))))

(ert-deftest taskjuggler-tj3d-drain-refresh-queue--resets-on-launch-failure ()
  "If the next launch errors, in-flight is reset so the queue can recover.
Without this guard, every subsequent schedule for that path would
coalesce against the stuck in-flight value forever."
  (with-clean-tj3d-state
   (cl-letf (((symbol-function 'taskjuggler--tj3d-add-project-run)
              (lambda (&rest _) (error "fork failed")))
             ((symbol-function 'message) (lambda (&rest _) nil)))
     (setq taskjuggler--tj3d-refresh-queue
           (list (cons "/tmp/doomed.tjp" t)))
     (taskjuggler--tj3d-drain-refresh-queue)
     (should (null taskjuggler--tj3d-refresh-in-flight))
     (should (null taskjuggler--tj3d-refresh-queue)))))

;; taskjuggler-tj3d-add-project / taskjuggler--tj3d-refresh-on-save

(ert-deftest taskjuggler-tj3d-add-project--errors-when-tj3d-not-running ()
  "Interactive add raises a user-error when the daemon is down."
  (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () nil)))
    (with-temp-buffer
      (should-error (taskjuggler-tj3d-add-project) :type 'user-error))))

(ert-deftest taskjuggler-tj3d-add-project--schedules-refresh ()
  "Interactive add delegates to schedule-refresh non-quietly."
  (with-clean-tj3d-state
   (let* ((dir (make-temp-file "tj-test-" t))
          (tjp (expand-file-name "p.tjp" dir))
          calls)
     (unwind-protect
         (progn
           (write-region "" nil tjp)
           (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p)
                      (lambda () t))
                     ((symbol-function 'taskjuggler--tj3d-schedule-refresh)
                      (lambda (p q) (push (list p q) calls))))
             (with-temp-buffer
               (setq buffer-file-name tjp)
               (taskjuggler-tj3d-add-project))
             (should (equal calls (list (list tjp nil))))))
       (delete-directory dir t)))))

(ert-deftest taskjuggler-tj3d-refresh-on-save--schedules-when-tracked ()
  "Save hook schedules a quiet refresh when the project is tracked."
  (with-clean-tj3d-state
   (let* ((tjp (expand-file-name "test.tjp" temporary-file-directory))
          calls)
     (puthash tjp t taskjuggler--tj3d-tracked-projects)
     (cl-letf (((symbol-function 'taskjuggler--tj3d-schedule-refresh)
                (lambda (p q) (push (list p q) calls))))
       (with-temp-buffer
         (setq buffer-file-name tjp)
         (taskjuggler--tj3d-refresh-on-save))
       (should (equal calls (list (list tjp t))))))))

(ert-deftest taskjuggler-tj3d-refresh-on-save--noop-when-not-tracked ()
  "Save hook does nothing when the project was never added."
  (with-clean-tj3d-state
   (let* ((tjp (expand-file-name "untracked.tjp" temporary-file-directory))
          calls)
     (cl-letf (((symbol-function 'taskjuggler--tj3d-schedule-refresh)
                (lambda (p q) (push (list p q) calls))))
       (with-temp-buffer
         (setq buffer-file-name tjp)
         (taskjuggler--tj3d-refresh-on-save))
       (should (null calls))))))

;; taskjuggler--tj3-process-filter

(ert-deftest taskjuggler-tj3-process-filter--carriage-return-overwrites ()
  "Lone CR collapses progress text down to the final line."
  (skip-unless (executable-find "cat"))
  (let* ((buf (generate-new-buffer " *tj-filter-test*"))
         (proc (make-process :name "tj-filter-cat" :buffer buf
                             :command '("cat") :noquery t
                             :connection-type 'pipe)))
    (unwind-protect
        (progn
          (taskjuggler--tj3-process-filter
           proc "progress 10%\rprogress 50%\rprogress 100%\n")
          (with-current-buffer buf
            (let ((s (buffer-string)))
              (should (string-match-p "progress 100%" s))
              (should-not (string-match-p "progress 10%" s))
              (should-not (string-match-p "progress 50%" s)))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest taskjuggler-tj3-process-filter--ansi-escapes-removed ()
  "ANSI SGR escapes are stripped (converted to text properties)."
  (skip-unless (executable-find "cat"))
  (let* ((buf (generate-new-buffer " *tj-filter-test*"))
         (proc (make-process :name "tj-filter-cat" :buffer buf
                             :command '("cat") :noquery t
                             :connection-type 'pipe)))
    (unwind-protect
        (progn
          (taskjuggler--tj3-process-filter proc "\e[31mred\e[0m text\n")
          (with-current-buffer buf
            (let ((s (buffer-string)))
              (should-not (string-match-p "\e\\[" s))
              (should (string-match-p "red text" s)))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; taskjuggler-tj3d-stop / taskjuggler-tj3webd-stop

(ert-deftest taskjuggler-tj3d-stop--errors-when-not-running ()
  "Stop command signals a user-error if tj3d isn't running."
  (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () nil)))
    (should-error (taskjuggler-tj3d-stop) :type 'user-error)))

(ert-deftest taskjuggler-tj3d-stop--clears-tracked-and-queue ()
  "Stop terminates the daemon and clears tracked-projects + queue."
  (with-clean-tj3d-state
   (puthash "/tmp/x.tjp" t taskjuggler--tj3d-tracked-projects)
   (setq taskjuggler--tj3d-refresh-queue (list (cons "/tmp/y.tjp" nil)))
   (cl-letf (((symbol-function 'taskjuggler--tj3d-alive-p) (lambda () t))
             ((symbol-function 'call-process) (lambda (&rest _) 0))
             ((symbol-function 'taskjuggler--daemon-update-modeline)
              (lambda () nil)))
     (taskjuggler-tj3d-stop)
     (should (zerop (hash-table-count taskjuggler--tj3d-tracked-projects)))
     (should (null taskjuggler--tj3d-refresh-queue)))))

(ert-deftest taskjuggler-tj3webd-stop--errors-when-not-running ()
  "Stop command signals a user-error if tj3webd isn't running."
  (cl-letf (((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () nil)))
    (should-error (taskjuggler-tj3webd-stop) :type 'user-error)))

(ert-deftest taskjuggler-tj3webd-stop--errors-when-pidfile-missing ()
  "Stop command errors when no pidfile is recorded for the port."
  (cl-letf (((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () t))
            ((symbol-function 'taskjuggler--tj3webd-pidfile-pid)
             (lambda (_) nil))
            ((symbol-function 'taskjuggler--daemon-update-modeline)
             (lambda () nil)))
    (should-error (taskjuggler-tj3webd-stop) :type 'user-error)))

(ert-deftest taskjuggler-tj3webd-stop--signals-recorded-pid ()
  "Stop reads the pidfile and sends SIGTERM to that PID."
  (let (signalled)
    (cl-letf (((symbol-function 'taskjuggler--tj3webd-alive-p) (lambda () t))
              ((symbol-function 'taskjuggler--tj3webd-pidfile-pid)
               (lambda (_) 4242))
              ((symbol-function 'signal-process)
               (lambda (pid sig) (push (cons pid sig) signalled)))
              ((symbol-function 'taskjuggler--daemon-update-modeline)
               (lambda () nil)))
      (taskjuggler-tj3webd-stop)
      (should (equal signalled (list (cons 4242 'SIGTERM)))))))

(ert-deftest taskjuggler-tj3webd-pidfile-pid--returns-live-pid ()
  "Helper returns the PID when it's a live process."
  (let* ((dir (make-temp-file "tj-test-" t))
         (port 18080)
         (file (expand-file-name (format "taskjuggler-tj3webd-%d.pid" port)
                                 dir))
         (live-pid (emacs-pid)))
    (unwind-protect
        (progn
          (write-region (number-to-string live-pid) nil file)
          (cl-letf (((symbol-function 'taskjuggler--tj3webd-pidfile)
                     (lambda (_) file)))
            (should (equal live-pid
                           (taskjuggler--tj3webd-pidfile-pid port))))
          (should (file-exists-p file)))
      (delete-directory dir t))))

(ert-deftest taskjuggler-tj3webd-pidfile-pid--cleans-stale-pidfile ()
  "Helper deletes a stale pidfile (PID not running) and returns nil.
Uses PID 0 — `signal-process' rejects it as out-of-range, which the
helper treats the same as a stale entry."
  (let* ((dir (make-temp-file "tj-test-" t))
         (port 18081)
         (file (expand-file-name (format "taskjuggler-tj3webd-%d.pid" port)
                                 dir)))
    (unwind-protect
        (progn
          (write-region "0\n" nil file)
          (cl-letf (((symbol-function 'taskjuggler--tj3webd-pidfile)
                     (lambda (_) file)))
            (should-not (taskjuggler--tj3webd-pidfile-pid port)))
          (should-not (file-exists-p file)))
      (when (file-exists-p dir) (delete-directory dir t)))))

(ert-deftest taskjuggler-tj3webd-pidfile-pid--missing-file-returns-nil ()
  "Helper returns nil with no side effects when the pidfile doesn't exist."
  (cl-letf (((symbol-function 'taskjuggler--tj3webd-pidfile)
             (lambda (_) "/no/such/pidfile")))
    (should-not (taskjuggler--tj3webd-pidfile-pid 18082))))

(ert-deftest taskjuggler-tj3webd-pidfile--returns-fully-expanded-path ()
  "Pidfile path must be `/'-rooted with no literal `~' segment.
Regression: `locate-user-emacs-file' abbreviates HOME back to `~',
which tj3webd's daemon then treats as a relative path and prepends
its cwd to."
  (let ((user-emacs-directory "~/.emacs.d/"))
    (let ((path (taskjuggler--tj3webd-pidfile 8080)))
      (should (file-name-absolute-p path))
      (should (string-prefix-p "/" path))
      (should-not (string-match-p "/~/" path))
      (should-not (string-match-p "/~$" path)))))


;;; Runner

(when noninteractive
  (ert-run-tests-batch-and-exit))

;;; taskjuggler-mode-test.el ends here
