;;; taskjuggler-mode-cursor-test.el --- cursor subsystem tests -*- lexical-binding: t -*-

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

;;; Tests: nil cases

(ert-deftest taskjuggler-mode-full-task-id--nil-at-top-level ()
  "Returns nil when point is between top-level blocks."
  (with-temp-buffer
    (insert test-tjp-content)
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    ;; Position point on the blank line between `project' and `resource'.
    (goto-char (point-min))
    (re-search-forward "^$")           ; first blank line after project block
    (should (null (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--nil-in-project-block ()
  "Returns nil when point is inside a `project' block."
  (with-tjp-at-mark "# IN-PROJECT"
    (should (null (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--nil-in-resource-block ()
  "Returns nil when point is inside a `resource' block."
  (with-tjp-at-mark "# IN-RESOURCE"
    (should (null (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--nil-in-taskreport-block ()
  "Returns nil when point is inside a `taskreport' block."
  (with-tjp-at-mark "# IN-REPORT"
    (should (null (taskjuggler-mode--full-task-id-at-point)))))
;;; Tests: single-level task

(ert-deftest taskjuggler-mode-full-task-id--top-level-task-body ()
  "Returns the task id when point is in a top-level task body (not nested)."
  (with-tjp-at-mark "# IN-OUTER"
    (should (equal "outer" (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--on-task-header-line ()
  "Returns the task id when point is on the `task' keyword line itself."
  (with-tjp-at-mark "task outer"
    ;; Point is now right after the match, still on the `task outer' line.
    (beginning-of-line)
    (should (equal "outer" (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--hyphenated-id ()
  "Returns the full id when the task identifier contains a hyphen."
  (with-tjp-at-mark "# IN-HYPHEN"
    (should (equal "my-task" (taskjuggler-mode--full-task-id-at-point)))))
;;; Tests: multi-level nesting

(ert-deftest taskjuggler-mode-full-task-id--two-levels ()
  "Returns the dotted path for a task nested one level deep."
  (with-tjp-at-mark "# IN-MIDDLE"
    (should (equal "outer.middle" (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--three-levels ()
  "Returns the dotted path for a task nested two levels deep."
  (with-tjp-at-mark "# IN-INNER"
    (should (equal "outer.middle.inner" (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-full-task-id--on-nested-task-header-line ()
  "Returns the dotted path when point is on the header line of a nested task."
  (with-tjp-at-mark "task middle"
    (beginning-of-line)
    (should (equal "outer.middle" (taskjuggler-mode--full-task-id-at-point)))))
;;; Regression: # comments containing { must not corrupt block detection

(ert-deftest taskjuggler-mode-full-task-id--hash-comment-with-brace ()
  "A # comment containing { must not be counted as a block opener.
If syntax-propertize has not yet run for the comment line, scan-lists
would miscount depth and taskjuggler-mode--current-block-header would return nil.
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
    (should (equal "outer.inner" (taskjuggler-mode--full-task-id-at-point)))))
;;; Regression: sibling block preceding parent must not appear in path

(ert-deftest taskjuggler-mode-full-task-id--sibling-not-included-in-path ()
  "A closed sibling block must not appear in the task id path.
Regression test: up-list could land on a sibling's { when scanning
backward past its balanced braces."
  (with-tjp-at-mark "# IN-CHILD-WITH-SIBLING"
    (should (equal "top.parent.child"
                   (taskjuggler-mode--full-task-id-at-point)))))
;;; Tests: helper function taskjuggler-mode--block-header-task-id

(ert-deftest taskjuggler-mode-block-header-task-id--task-keyword ()
  "Extracts the id from a `task' header line."
  (with-temp-buffer
    (insert "task my-task \"My Task\" {\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (equal "my-task" (taskjuggler-mode--block-header-task-id (point))))))
(ert-deftest taskjuggler-mode-block-header-task-id--non-task-keyword ()
  "Returns nil for non-`task' block keywords."
  (with-temp-buffer
    (insert "resource dev \"Developer\" {\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (null (taskjuggler-mode--block-header-task-id (point))))))
(ert-deftest taskjuggler-mode-block-header-task-id--indented-task ()
  "Handles leading whitespace on a nested task header line."
  (with-temp-buffer
    (insert "  task inner \"Inner\" {\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (equal "inner" (taskjuggler-mode--block-header-task-id (point))))))
;;; Corner cases: full-task-id on the closing `}' line

(ert-deftest taskjuggler-mode-full-task-id--on-closing-brace-line ()
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
    (should (equal "foo" (taskjuggler-mode--full-task-id-at-point)))))
;;; Corner cases: block-header-task-id non-task declaration keywords

(ert-deftest taskjuggler-mode-block-header-task-id--macro-keyword ()
  "Returns nil for a `macro' header line — only `task' lines yield an id."
  (with-temp-buffer
    (insert "macro mymacro [\n]\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (null (taskjuggler-mode--block-header-task-id (point))))))
(ert-deftest taskjuggler-mode-block-header-task-id--supplement-keyword ()
  "Returns nil for a `supplement task' header line."
  (with-temp-buffer
    (insert "supplement task foo {\n}\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    ;; `supplement' is the leading keyword; this line does not start with `task'.
    (should (null (taskjuggler-mode--block-header-task-id (point))))))
;; --- taskjuggler-mode--full-task-id-at-point: `}' line of a non-task block ---
;; The closing `}' of a `resource' block is syntactically inside that block
;; (depth 1), so current-block-header returns the resource header.
;; block-header-task-id returns nil for `resource', so ids stays nil → nil.

(ert-deftest taskjuggler-mode-full-task-id--nil-on-closing-brace-of-resource ()
  "Returns nil when point is on the closing `}' of a non-task block."
  (with-temp-buffer
    (insert "resource dev \"Dev\" {\n  vacation 2024-01-01\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "^}$")
    (beginning-of-line)
    (should (null (taskjuggler-mode--full-task-id-at-point)))))
;;; Tests: taskjuggler-mode--cursor-parse-field

(ert-deftest taskjuggler-mode-cursor-parse-field--quoted-value ()
  "Parses a quoted string value."
  (should (equal "outer.inner"
                 (taskjuggler-mode--cursor-parse-field
                  "window._tjCursorTaskId = \"outer.inner\";\n"
                  "_tjCursorTaskId"))))
(ert-deftest taskjuggler-mode-cursor-parse-field--numeric-value ()
  "Parses a bare integer value."
  (should (equal "1712844002"
                 (taskjuggler-mode--cursor-parse-field
                  "window._tjCursorTs     = 1712844002;\n"
                  "_tjCursorTs"))))
(ert-deftest taskjuggler-mode-cursor-parse-field--null-value ()
  "Returns nil for null (unquoted non-numeric) assignments."
  (should (null (taskjuggler-mode--cursor-parse-field
                 "window._tjCursorTaskId = null;\n"
                 "_tjCursorTaskId"))))
(ert-deftest taskjuggler-mode-cursor-parse-field--missing-field ()
  "Returns nil when the field is not present."
  (should (null (taskjuggler-mode--cursor-parse-field
                 "window._tjClickTs = 0;\n"
                 "_tjCursorTaskId"))))
(ert-deftest taskjuggler-mode-cursor-parse-field--all-four-fields ()
  "Parses all four fields from a complete tj-cursor.js content string."
  (let ((content (concat "window._tjCursorTaskId = \"foo.bar\";\n"
                         "window._tjCursorTs     = 1000;\n"
                         "window._tjClickTaskId  = \"baz.qux\";\n"
                         "window._tjClickTs      = 999;\n")))
    (should (equal "foo.bar"
                   (taskjuggler-mode--cursor-parse-field content "_tjCursorTaskId")))
    (should (equal "1000"
                   (taskjuggler-mode--cursor-parse-field content "_tjCursorTs")))
    (should (equal "baz.qux"
                   (taskjuggler-mode--cursor-parse-field content "_tjClickTaskId")))
    (should (equal "999"
                   (taskjuggler-mode--cursor-parse-field content "_tjClickTs")))))
;;; Tests: taskjuggler-mode--goto-task-id

(ert-deftest taskjuggler-mode-goto-task-id--top-level ()
  "Navigates to a top-level task."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-max))
    (should (taskjuggler-mode--goto-task-id "outer"))
    (should (looking-at "task outer"))))
(ert-deftest taskjuggler-mode-goto-task-id--nested ()
  "Navigates to a nested task by its full dotted ID."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n  task inner \"Inner\" {\n  }\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-max))
    (should (taskjuggler-mode--goto-task-id "outer.inner"))
    (should (looking-at "[ \t]*task inner"))))
(ert-deftest taskjuggler-mode-goto-task-id--disambiguates-same-leaf-id ()
  "Uses the full hierarchy to distinguish tasks with the same leaf ID."
  (with-temp-buffer
    (insert "task alpha \"Alpha\" {\n  task child \"Child\" {\n  }\n}\n"
            "task beta \"Beta\" {\n  task child \"Child\" {\n  }\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-max))
    (should (taskjuggler-mode--goto-task-id "beta.child"))
    ;; Point should be on the second `task child' line (inside beta).
    (should (looking-at "[ \t]*task child"))
    (should (equal "beta.child" (taskjuggler-mode--full-task-id-at-point)))))
(ert-deftest taskjuggler-mode-goto-task-id--returns-nil-for-unknown ()
  "Returns nil and leaves point unchanged when the task is not found."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (should-not (taskjuggler-mode--goto-task-id "outer.nonexistent"))))

(provide 'taskjuggler-mode-cursor-test)

;;; taskjuggler-mode-cursor-test.el ends here
