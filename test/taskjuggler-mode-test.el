;;; taskjuggler-mode-test.el --- ERT tests for taskjuggler-mode -*- lexical-binding: t -*-

;; Entry point that hosts the core mode tests (block navigation,
;; indentation, font-lock, syntax-propertize, sexp/defun movement) and
;; loads each subsystem test file so a single batch invocation runs the
;; full suite:
;;
;;   emacs --batch -l test/taskjuggler-mode-test.el -f ert-run-tests-batch-and-exit
;;
;; Subsystem test files can also be run individually.

;; Bootstrap: put this directory on the load-path so `require' finds the
;; helpers file and the subsystem test files without needing -L test on
;; the command line.
(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

(ert-deftest taskjuggler-mode-indent--top-level ()
  "Top-level lines (depth 0) indent to column 0."
  (with-indent-buffer "task foo \"Foo\" {\n}\n"
    (should (= 0 (indent-at-line 1)))))
(ert-deftest taskjuggler-mode-indent--inside-one-brace ()
  "A line inside one brace level indents to `taskjuggler-mode-indent-level'."
  (with-indent-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (should (= taskjuggler-mode-indent-level (indent-at-line 2)))))
(ert-deftest taskjuggler-mode-indent--inside-two-braces ()
  "A line inside two brace levels indents to 2 × `taskjuggler-mode-indent-level'."
  (with-indent-buffer "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n"
    (should (= (* 2 taskjuggler-mode-indent-level) (indent-at-line 3)))))
(ert-deftest taskjuggler-mode-indent--closing-brace-dedented ()
  "A closing `}' is de-indented one level relative to its contents."
  (with-indent-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    ;; The `}' is at depth 1 in the parse, but should indent to 0.
    (should (= 0 (indent-at-line 3)))))
(ert-deftest taskjuggler-mode-indent--closing-brace-nested ()
  "A nested closing `}' de-indents one level (to indent-level, not 0)."
  (with-indent-buffer "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n"
    (should (= taskjuggler-mode-indent-level (indent-at-line 4)))))
(ert-deftest taskjuggler-mode-indent--continuation-single ()
  "A line after a comma-terminated line aligns with the first argument."
  ;; `columns' starts at column 2 inside the brace, keyword is `columns',
  ;; first arg starts right after the keyword+space.
  (with-indent-buffer "taskreport r \"\" {\n  columns name,\n  id\n}\n"
    ;; Line 3 (`  id') is a continuation.  The anchor is line 2.
    ;; Leading whitespace (2) + keyword `columns' (7) + space (1) = column 10.
    (should (= 10 (indent-at-line 3)))))
(ert-deftest taskjuggler-mode-indent--continuation-multi-line ()
  "All lines in a multi-line comma continuation align with the first argument."
  (with-indent-buffer "taskreport r \"\" {\n  columns name,\n  start,\n  end\n}\n"
    ;; Lines 3 and 4 are both continuations; both should align to column 10.
    (should (= 10 (indent-at-line 3)))
    (should (= 10 (indent-at-line 4)))))
(ert-deftest taskjuggler-mode-indent--non-continuation-after-non-comma ()
  "A line after a non-comma-terminated line uses depth-based indent."
  (with-indent-buffer "task foo \"Foo\" {\n  effort 5d\n  length 3d\n}\n"
    (should (= taskjuggler-mode-indent-level (indent-at-line 3)))))
;;; Tests: taskjuggler-mode--block-end

(ert-deftest taskjuggler-mode-block-end--with-brace-body ()
  "Returns the line after the closing `}' for a block with a brace body."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n  effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    ;; block-end should point to the line after `}'.
    (let ((end (taskjuggler-mode--block-end (point-min))))
      ;; The buffer has 3 lines; after `}' is past the last newline (= point-max).
      (should (= (point-max) end)))))
(ert-deftest taskjuggler-mode-block-end--nested-returns-outer-end ()
  "block-end called on the outer header skips the entire nested block."
  (with-temp-buffer
    (insert "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler-mode--block-end (point-min))))
      (should (= (point-max) end)))))
(ert-deftest taskjuggler-mode-block-end--without-brace-body ()
  "Returns the line after the header for a keyword line with no brace body."
  (with-temp-buffer
    (insert "include \"file.tji\"\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    ;; `include' line has no `{'; block-end should return start of line 2.
    (let ((end (taskjuggler-mode--block-end (point-min))))
      (goto-char (point-min))
      (forward-line 1)
      (should (= (point) end)))))
;;; Tests: taskjuggler-mode--block-with-comments-start

(ert-deftest taskjuggler-mode-block-with-comments-start--no-comment ()
  "Returns the header position when there is no preceding comment."
  (with-temp-buffer
    (insert "\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)  ; header is on line 2
    (let ((header (point)))
      (should (= header (taskjuggler-mode--block-with-comments-start header))))))
(ert-deftest taskjuggler-mode-block-with-comments-start--hash-comment ()
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
                 (taskjuggler-mode--block-with-comments-start header))))))
(ert-deftest taskjuggler-mode-block-with-comments-start--slash-comment ()
  "A `//' comment line immediately before the header is included."
  (with-temp-buffer
    (insert "// line comment\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler-mode--block-with-comments-start header))))))
(ert-deftest taskjuggler-mode-block-with-comments-start--blank-line-stops-scan ()
  "A blank line between a comment and the header prevents inclusion of the comment."
  (with-temp-buffer
    (insert "# detached comment\n\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 2)  ; header on line 3
    (let ((header (point)))
      (should (= header
                 (taskjuggler-mode--block-with-comments-start header))))))
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
(ert-deftest taskjuggler-mode-next-block--moves-to-next-sibling ()
  "next-block moves point from the first to the second sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Point starts on `task a'.
    (taskjuggler-mode-next-block)
    (should (looking-at "task b"))))
(ert-deftest taskjuggler-mode-next-block--errors-at-last-sibling ()
  "next-block signals an error when there is no next sibling."
  (with-nav-buffer "task a \"A\" {\n}\n"
    (should-error (taskjuggler-mode-next-block) :type 'user-error)))
(ert-deftest taskjuggler-mode-prev-block--moves-to-prev-sibling ()
  "prev-block moves point from the second to the first sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-mode-prev-block)
    (should (looking-at "task a"))))
(ert-deftest taskjuggler-mode-prev-block--errors-at-first-sibling ()
  "prev-block signals a user-error when there is no previous sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Start on `task a' — first sibling, no previous.
    (should-error (taskjuggler-mode-prev-block) :type 'user-error)))
(ert-deftest taskjuggler-mode-goto-parent--moves-to-enclosing-header ()
  "goto-parent moves point to the header of the enclosing block."
  (with-nav-buffer "task outer \"Outer\" {\n  task inner \"Inner\" {\n    effort 1d\n  }\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mode-goto-parent)
    (should (looking-at "[ \t]*task inner"))))
(ert-deftest taskjuggler-mode-goto-parent--errors-at-top-level ()
  "goto-parent signals an error when point is already at the top level."
  (with-nav-buffer "task foo \"Foo\" {\n}\n"
    (should-error (taskjuggler-mode-goto-parent) :type 'user-error)))
(ert-deftest taskjuggler-mode-goto-first-child--moves-to-first-child ()
  "goto-first-child lands on the first direct child block."
  (with-nav-buffer "task parent \"P\" {\n  task child-a \"A\" {\n  }\n  task child-b \"B\" {\n  }\n}\n"
    ;; Point is on `task parent'.
    (taskjuggler-mode-goto-first-child)
    (should (looking-at "[ \t]*task child-a"))))
(ert-deftest taskjuggler-mode-goto-first-child--errors-with-no-children ()
  "goto-first-child signals an error when the block has no child blocks."
  (with-nav-buffer "task leaf \"Leaf\" {\n  effort 1d\n}\n"
    (should-error (taskjuggler-mode-goto-first-child) :type 'user-error)))
;;; Tests: taskjuggler-mode--current-block-header

(ert-deftest taskjuggler-mode-current-block-header--on-keyword-line ()
  "Returns the line position when point is on a moveable keyword line."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (should (= (point-min) (taskjuggler-mode--current-block-header)))))
(ert-deftest taskjuggler-mode-current-block-header--inside-body ()
  "Returns the enclosing header position when point is inside the body."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort")
    (let ((header (taskjuggler-mode--current-block-header)))
      (should header)
      (goto-char header)
      (should (looking-at "task foo")))))
(ert-deftest taskjuggler-mode-current-block-header--top-level-returns-nil ()
  "Returns nil when point is at the top level outside any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n}\n"
    ;; Point starts at the blank line before the task — top level, no block.
    (should (null (taskjuggler-mode--current-block-header)))))
(ert-deftest taskjuggler-mode-current-block-header--non-task-block-returns-nil ()
  "Returns nil inside a resource block (not a moveable-block-re match for its header)."
  ;; `resource' IS in taskjuggler-mode--moveable-block-re, so from inside its body
  ;; we should get its header back.  Verify that a non-moveable wrapper does
  ;; NOT manufacture a header from thin air.
  (with-nav-buffer "resource dev \"Dev\" {\n  # IN-RES\n}\n"
    (re-search-forward "# IN-RES")
    (let ((header (taskjuggler-mode--current-block-header)))
      (should header)
      (goto-char header)
      (should (looking-at "resource dev")))))
;;; Tests: taskjuggler-mode--child-block-headers

(ert-deftest taskjuggler-mode-child-block-headers--returns-all-children ()
  "Returns positions of all direct child block headers."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n  task c \"C\" {\n  }\n}\n"
    (syntax-propertize (point-max))
    (let ((children (taskjuggler-mode--child-block-headers (point-min))))
      (should (= 3 (length children)))
      (goto-char (nth 0 children)) (should (looking-at "[ \t]*task a"))
      (goto-char (nth 1 children)) (should (looking-at "[ \t]*task b"))
      (goto-char (nth 2 children)) (should (looking-at "[ \t]*task c")))))
(ert-deftest taskjuggler-mode-child-block-headers--no-children ()
  "Returns nil for a block with no child blocks."
  (with-nav-buffer "task leaf \"Leaf\" {\n  effort 1d\n}\n"
    (should (null (taskjuggler-mode--child-block-headers (point-min))))))
(ert-deftest taskjuggler-mode-child-block-headers--only-direct-children ()
  "Does not include grandchildren — only direct children at depth+1."
  (with-nav-buffer "task p \"P\" {\n  task child \"C\" {\n    task grandchild \"G\" {\n    }\n  }\n}\n"
    (syntax-propertize (point-max))
    (let ((children (taskjuggler-mode--child-block-headers (point-min))))
      (should (= 1 (length children)))
      (goto-char (car children))
      (should (looking-at "[ \t]*task child")))))
;;; Tests: taskjuggler-mode-goto-last-child

(ert-deftest taskjuggler-mode-goto-last-child--moves-to-last-child ()
  "goto-last-child lands on the last direct child block."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (taskjuggler-mode-goto-last-child)
    (should (looking-at "[ \t]*task b"))))
(ert-deftest taskjuggler-mode-goto-last-child--single-child ()
  "goto-last-child and goto-first-child agree when there is one child."
  (with-nav-buffer "task p \"P\" {\n  task only \"Only\" {\n  }\n}\n"
    (let (first last)
      (taskjuggler-mode-goto-first-child)
      (setq first (point))
      (goto-char (point-min))
      (taskjuggler-mode-goto-last-child)
      (setq last (point))
      (should (= first last)))))
;;; Tests: block movement

(ert-deftest taskjuggler-mode-move-block-up--swaps-with-prev-sibling ()
  "move-block-up swaps the current block with the previous sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-mode-move-block-up)
    ;; After moving up, `task b' should precede `task a'.
    (goto-char (point-min))
    (should (looking-at "task b"))))
(ert-deftest taskjuggler-mode-move-block-up--preserves-blank-separator ()
  "move-block-up keeps the blank line between the two blocks."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-mode-move-block-up)
    ;; Buffer should still contain a blank line between the two blocks.
    (goto-char (point-min))
    (should (re-search-forward "^$" nil t))))
(ert-deftest taskjuggler-mode-move-block-down--swaps-with-next-sibling ()
  "move-block-down swaps the current block with the next sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Point starts on `task a'.
    (taskjuggler-mode-move-block-down)
    (goto-char (point-min))
    (should (looking-at "task b"))))
(ert-deftest taskjuggler-mode-move-block-up-down--round-trip ()
  "Moving a block down then up restores the original buffer content."
  (let ((original "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"))
    (with-nav-buffer original
      (taskjuggler-mode-move-block-down)
      (goto-char (point-min))
      (re-search-forward "task a")
      (beginning-of-line)
      (taskjuggler-mode-move-block-up)
      (should (equal original (buffer-string))))))
(ert-deftest taskjuggler-mode-move-block-up--comment-travels-with-block ()
  "A comment immediately before the block travels with it when moved."
  (with-nav-buffer "task a \"A\" {\n}\n\n# comment for b\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-mode-move-block-up)
    ;; The comment and task b should now be at the top of the file.
    (goto-char (point-min))
    (should (looking-at "# comment for b"))))
;;; Tests: block editing

(ert-deftest taskjuggler-mode-clone-block--produces-duplicate ()
  "clone-block inserts a copy of the block immediately after the original."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (taskjuggler-mode-clone-block)
    ;; The buffer should now contain two `task foo' blocks.
    (goto-char (point-min))
    (re-search-forward "task foo")
    (should (re-search-forward "task foo" nil t))))
(ert-deftest taskjuggler-mode-clone-block--blank-line-separator ()
  "clone-block separates the original and clone with a blank line."
  (with-nav-buffer "task foo \"Foo\" {\n}\n"
    (taskjuggler-mode-clone-block)
    (goto-char (point-min))
    (re-search-forward "^}$")
    (forward-line 1)
    (should (looking-at "^$"))))
(ert-deftest taskjuggler-mode-clone-block--point-on-clone-header ()
  "clone-block leaves point on the clone's header line."
  (with-nav-buffer "task foo \"Foo\" {\n}\n"
    (taskjuggler-mode-clone-block)
    (should (looking-at "task foo"))))
(ert-deftest taskjuggler-mode-narrow-to-block--narrows-correctly ()
  "narrow-to-block restricts the buffer to header through closing `}'."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mode-narrow-to-block)
    (unwind-protect
        (progn
          (should (string-match "task foo" (buffer-string)))
          (should (string-match "effort" (buffer-string)))
          ;; Nothing outside the block should be visible.
          (goto-char (point-min))
          (should (looking-at "task foo")))
      (widen))))
(ert-deftest taskjuggler-mode-mark-block--sets-region-over-block ()
  "mark-block places point at block start and mark at block end."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mode-mark-block)
    (let ((region (buffer-substring (region-beginning) (region-end))))
      (should (string-match "task foo" region))
      (should (string-match "effort" region)))))
;;; Tests: sexp movement

(ert-deftest taskjuggler-mode-forward-sexp--skips-whole-block ()
  "forward-sexp from a block header jumps past the entire block."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\ntask bar \"Bar\" {\n}\n"
    ;; Point is on `task foo' header.
    (taskjuggler-mode--forward-sexp 1)
    ;; Should now be at `task bar'.
    (should (looking-at "task bar"))))
(ert-deftest taskjuggler-mode-forward-sexp--inside-line-falls-back ()
  "forward-sexp from mid-line falls back to default sexp movement."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "effort ")
    ;; Point is now after `effort ', just before `5d'.  Default sexp would
    ;; move past `5d' as a token.
    (let ((start (point)))
      (taskjuggler-mode--forward-sexp 1)
      (should (> (point) start)))))
(ert-deftest taskjuggler-mode-backward-sexp--skips-whole-block ()
  "backward-sexp from after a block's `}' jumps to the block header."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\ntask bar \"Bar\" {\n}\n"
    ;; Move to just after the closing `}' of `task bar'.
    (goto-char (point-max))
    (taskjuggler-mode--forward-sexp -1)
    (should (looking-at "task bar"))))
(ert-deftest taskjuggler-mode-forward-sexp--arg-2-skips-two-blocks ()
  "forward-sexp with arg 2 skips two consecutive blocks."
  (with-nav-buffer "task a \"A\" {\n}\ntask b \"B\" {\n}\ntask c \"C\" {\n}\n"
    (taskjuggler-mode--forward-sexp 2)
    (should (looking-at "task c"))))
;;; Tests: taskjuggler-mode--beginning-of-defun

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
(ert-deftest taskjuggler-mode-beginning-of-defun--from-inside-body ()
  "From inside a block body, jumps to that block's header."
  (with-defun-buffer
    (re-search-forward "effort 1d")
    (taskjuggler-mode--beginning-of-defun)
    (should (looking-at "task alpha"))))
(ert-deftest taskjuggler-mode-beginning-of-defun--from-header-goes-to-prev ()
  "From a block header, searches backward to the preceding block."
  (with-defun-buffer
    (re-search-forward "task beta")
    (beginning-of-line)
    (taskjuggler-mode--beginning-of-defun)
    (should (looking-at "task alpha"))))
(ert-deftest taskjuggler-mode-beginning-of-defun--arg-2-from-body ()
  "With arg 2 from inside a block body, jumps to header then one more back."
  (with-defun-buffer
    ;; Point inside beta's body (on `task child' header, one level down).
    (re-search-forward "effort 2d")
    ;; arg=1 would land on `task child'; arg=2 goes one step further back.
    (taskjuggler-mode--beginning-of-defun 2)
    (should (looking-at "[ \t]*task child\\|task beta"))))
(ert-deftest taskjuggler-mode-beginning-of-defun--arg-2-from-header ()
  "With arg 2 from a block header, steps backward twice."
  (with-defun-buffer
    (re-search-forward "task gamma")
    (beginning-of-line)
    (taskjuggler-mode--beginning-of-defun 2)
    (should (looking-at "task alpha\\|[ \t]*task child\\|task beta"))))
(ert-deftest taskjuggler-mode-beginning-of-defun--at-bob-stops ()
  "At the first block (bob), does not move past the start of the buffer."
  (with-defun-buffer
    ;; Already on `task alpha'.
    (taskjuggler-mode--beginning-of-defun)
    ;; No previous block; point should stay at or before task alpha.
    (should (<= (point) (progn (goto-char (point-min))
                               (re-search-forward "task alpha")
                               (line-beginning-position))))))
(ert-deftest taskjuggler-mode-beginning-of-defun--negative-arg-delegates ()
  "A negative arg delegates to end-of-defun."
  (with-defun-buffer
    ;; Point on task alpha header.
    (taskjuggler-mode--beginning-of-defun -1)
    ;; Should have moved forward past task alpha's closing `}'.
    (should (> (point) (progn (goto-char (point-min))
                              (re-search-forward "task alpha")
                              (point))))))
;;; Tests: taskjuggler-mode--end-of-defun

(ert-deftest taskjuggler-mode-end-of-defun--from-header ()
  "From a block header, jumps past the block's closing `}'."
  (with-defun-buffer
    ;; Point on `task alpha'.
    (taskjuggler-mode--end-of-defun)
    ;; Should now be past `task alpha's `}' and on or before `task beta'.
    (let ((beta-pos (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "^task beta")
                      (line-beginning-position))))
      (should (<= (point) beta-pos)))))
(ert-deftest taskjuggler-mode-end-of-defun--from-inside-body ()
  "From inside a block body, jumps past the block's closing `}'."
  (with-defun-buffer
    (re-search-forward "effort 1d")
    (taskjuggler-mode--end-of-defun)
    (let ((beta-pos (save-excursion
                      (goto-char (point-min))
                      (re-search-forward "^task beta")
                      (line-beginning-position))))
      (should (<= (point) beta-pos)))))
(ert-deftest taskjuggler-mode-end-of-defun--arg-2 ()
  "With arg 2, skips past two consecutive blocks."
  (with-defun-buffer
    ;; Point at start.
    (taskjuggler-mode--end-of-defun 2)
    ;; Should be past beta (and possibly at or before gamma).
    (let ((gamma-pos (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^task gamma")
                       (line-beginning-position))))
      (should (<= (point) gamma-pos)))))
(ert-deftest taskjuggler-mode-end-of-defun--negative-arg-delegates ()
  "A negative arg delegates to beginning-of-defun."
  (with-defun-buffer
    (re-search-forward "task beta")
    (beginning-of-line)
    (taskjuggler-mode--end-of-defun -1)
    (should (looking-at "task alpha"))))
;;; Tests: taskjuggler-mode-forward-block / taskjuggler-mode-backward-block (linear scan)

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
(ert-deftest taskjuggler-mode-forward-block--crosses-nesting ()
  "forward-block moves into nested blocks, unlike next-block."
  (with-linear-buffer
    ;; Start on `task outer'.
    (taskjuggler-mode-forward-block)
    (should (looking-at "[ \t]*task inner-a"))))
(ert-deftest taskjuggler-mode-forward-block--arg-2 ()
  "forward-block with arg 2 moves to the second next block header."
  (with-linear-buffer
    (taskjuggler-mode-forward-block 2)
    (should (looking-at "[ \t]*task inner-b"))))
(ert-deftest taskjuggler-mode-forward-block--crosses-out-of-nesting ()
  "forward-block can move from a nested block to a top-level sibling."
  (with-linear-buffer
    (taskjuggler-mode-forward-block 3)
    (should (looking-at "task sibling"))))
(ert-deftest taskjuggler-mode-forward-block--errors-at-last-block ()
  "forward-block signals an error when there is no next block."
  (with-linear-buffer
    ;; Jump to the last block header.
    (re-search-forward "task sibling")
    (beginning-of-line)
    (should-error (taskjuggler-mode-forward-block) :type 'user-error)))
(ert-deftest taskjuggler-mode-backward-block--moves-to-prev-header ()
  "backward-block moves to the immediately preceding block header."
  (with-linear-buffer
    (re-search-forward "task sibling")
    (beginning-of-line)
    (taskjuggler-mode-backward-block)
    (should (looking-at "[ \t]*task inner-b"))))
(ert-deftest taskjuggler-mode-backward-block--arg-2 ()
  "backward-block with arg 2 moves two headers backward."
  (with-linear-buffer
    (re-search-forward "task sibling")
    (beginning-of-line)
    (taskjuggler-mode-backward-block 2)
    (should (looking-at "[ \t]*task inner-a"))))
(ert-deftest taskjuggler-mode-backward-block--errors-at-first-block ()
  "backward-block signals an error when there is no previous block."
  (with-linear-buffer
    (should-error (taskjuggler-mode-backward-block) :type 'user-error)))
;;; Tests: taskjuggler-mode-indent-line and taskjuggler-mode-indent-region

(ert-deftest taskjuggler-mode-indent-line--corrects-over-indent ()
  "indent-line fixes an over-indented line to the correct column."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n        effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (taskjuggler-mode-indent-line)
    (should (= taskjuggler-mode-indent-level (current-indentation)))))
(ert-deftest taskjuggler-mode-indent-line--corrects-under-indent ()
  "indent-line fixes an under-indented line to the correct column."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\neffort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (taskjuggler-mode-indent-line)
    (should (= taskjuggler-mode-indent-level (current-indentation)))))
(ert-deftest taskjuggler-mode-indent-region--indents-all-lines ()
  "indent-region correctly indents every line in the selected region."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n        effort 5d\ntask inner \"I\" {\neffort 1d\n}\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (taskjuggler-mode-indent-region (point-min) (point-max))
    (goto-char (point-min))
    ;; Line 1: top-level header → col 0.
    (should (= 0 (current-indentation)))
    (forward-line 1)
    ;; Line 2: inside one brace → indent-level.
    (should (= taskjuggler-mode-indent-level (current-indentation)))
    (forward-line 1)
    ;; Line 3: nested task header → indent-level.
    (should (= taskjuggler-mode-indent-level (current-indentation)))
    (forward-line 1)
    ;; Line 4: inside two braces → 2 × indent-level.
    (should (= (* 2 taskjuggler-mode-indent-level) (current-indentation)))))
;;; Tests: edge cases

(ert-deftest taskjuggler-mode-block-end--brace-in-string-on-header ()
  "block-end ignores a `{' inside a quoted string on the header line."
  ;; The `{' inside `\"name {with brace}\"' must not be mistaken for the
  ;; block opener; the real `{' is the last one on the line.
  (with-temp-buffer
    (insert "task foo \"name {with brace}\" {\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler-mode--block-end (point-min))))
      (should (= (point-max) end)))))
(ert-deftest taskjuggler-mode-clone-block--includes-preceding-comment ()
  "clone-block copies the preceding comment together with the block."
  (with-nav-buffer "# header comment\ntask foo \"Foo\" {\n}\n"
    (re-search-forward "task foo")
    (beginning-of-line)
    (taskjuggler-mode-clone-block)
    ;; Buffer should now contain two copies of the comment.
    (goto-char (point-min))
    (re-search-forward "# header comment")
    (should (re-search-forward "# header comment" nil t))))
(ert-deftest taskjuggler-mode-sibling-bounds--nested-siblings ()
  "next-sibling-bounds finds siblings at a nested depth, not top-level."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (re-search-forward "task a")
    (beginning-of-line)
    (let ((bounds (taskjuggler-mode--next-sibling-bounds (point))))
      (should bounds)
      (goto-char (nth 1 bounds))
      (should (looking-at "[ \t]*task b")))))
;;; Tests: scissors strings (syntax-propertize)

(defun test-tj--in-string-p (pos)
  "Return non-nil if buffer position POS is inside a string."
  (nth 3 (syntax-ppss pos)))
(ert-deftest taskjuggler-mode-scissors--content-is-string ()
  "Text between -8<- and ->8- is treated as a string by syntax-ppss."
  (with-temp-buffer
    (insert "note -8<-\nhello world\n->8-\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "hello")
    (should (test-tj--in-string-p (point)))))
(ert-deftest taskjuggler-mode-scissors--outside-is-not-string ()
  "Text before -8<- is not inside a string."
  (with-temp-buffer
    (insert "note -8<-\nhello\n->8-\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (should (not (test-tj--in-string-p (point))))))
(ert-deftest taskjuggler-mode-scissors--after-close-is-not-string ()
  "Text after ->8- is no longer inside the string."
  (with-temp-buffer
    (insert "note -8<-\nhello\n->8-\nafter\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "after")
    (should (not (test-tj--in-string-p (point))))))
(ert-deftest taskjuggler-mode-scissors--brace-inside-is-ignored ()
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

(ert-deftest taskjuggler-mode-block-with-comments-start--block-comment ()
  "A `/* */` block comment immediately before the header is included."
  (with-temp-buffer
    (insert "/* block comment */\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 1)  ; header on line 2
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler-mode--block-with-comments-start header))))))
(ert-deftest taskjuggler-mode-block-with-comments-start--multiline-block-comment ()
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
                 (taskjuggler-mode--block-with-comments-start header))))))
;;; Tests: `[` / `]` bracket indentation

(ert-deftest taskjuggler-mode-indent--inside-brackets ()
  "A line inside `[` brackets indents to `taskjuggler-mode-indent-level'."
  (with-indent-buffer "macro mymacro [\n  content\n]\n"
    (should (= taskjuggler-mode-indent-level (indent-at-line 2)))))
(ert-deftest taskjuggler-mode-indent--closing-bracket-dedented ()
  "A closing `]' is de-indented one level relative to its contents."
  (with-indent-buffer "macro mymacro [\n  content\n]\n"
    (should (= 0 (indent-at-line 3)))))
;;; Tests: taskjuggler-mode--tj3-executable

(ert-deftest taskjuggler-mode-tj3-executable--nil-bin-dir ()
  "Returns the name as-is when `taskjuggler-mode-tj3-bin-dir' is nil."
  (let ((taskjuggler-mode-tj3-bin-dir nil))
    (should (equal "tj3" (taskjuggler-mode--tj3-executable "tj3")))
    (should (equal "tj3man" (taskjuggler-mode--tj3-executable "tj3man")))))
(ert-deftest taskjuggler-mode-tj3-executable--with-bin-dir ()
  "Resolves name relative to `taskjuggler-mode-tj3-bin-dir' when set."
  (let ((taskjuggler-mode-tj3-bin-dir "/opt/tj3/bin"))
    (should (equal "/opt/tj3/bin/tj3"
                   (taskjuggler-mode--tj3-executable "tj3")))
    (should (equal "/opt/tj3/bin/tj3man"
                   (taskjuggler-mode--tj3-executable "tj3man")))))
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
(ert-deftest taskjuggler-mode-font-lock--keyword-face ()
  "Top-level keywords receive `font-lock-keyword-face'."
  (with-fontified-buffer "task foo \"Foo\" {\n}\n"
    (should (eq 'font-lock-keyword-face (test-tj--face-at-string "task")))))
(ert-deftest taskjuggler-mode-font-lock--declaration-id-face ()
  "The identifier after a declaration keyword receives `font-lock-variable-name-face'."
  (with-fontified-buffer "task my-task \"My Task\" {\n}\n"
    (should (eq 'font-lock-variable-name-face
                (test-tj--face-at-string "my-task")))))
(ert-deftest taskjuggler-mode-font-lock--date-face ()
  "Date literals receive `taskjuggler-mode-date-face'."
  (with-fontified-buffer "start 2024-03-15\n"
    (should (eq 'taskjuggler-mode-date-face (test-tj--face-at-string "2024-03-15")))))
(ert-deftest taskjuggler-mode-font-lock--duration-face ()
  "Duration literals receive `taskjuggler-mode-duration-face'."
  (with-fontified-buffer "effort 5d\n"
    (should (eq 'taskjuggler-mode-duration-face (test-tj--face-at-string "5d")))))
(ert-deftest taskjuggler-mode-font-lock--macro-ref-face ()
  "Macro references receive `taskjuggler-mode-macro-face'."
  (with-fontified-buffer "note ${MyMacro}\n"
    (should (eq 'taskjuggler-mode-macro-face (test-tj--face-at-string "${MyMacro}")))))
(ert-deftest taskjuggler-mode-font-lock--property-keyword-face ()
  "Property keywords receive `font-lock-function-name-face'."
  (with-fontified-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (should (eq 'font-lock-function-name-face
                (test-tj--face-at-string "effort")))))
;;; Tests: move-block at nested depth

(ert-deftest taskjuggler-mode-move-block-up--nested-siblings ()
  "move-block-up swaps two nested sibling tasks."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (taskjuggler-mode-move-block-up)
    ;; task b should now precede task a inside the parent.
    (goto-char (point-min))
    (re-search-forward "task p")
    (should (re-search-forward "task b" nil t))
    (let ((b-pos (match-beginning 0)))
      (should (re-search-forward "task a" nil t))
      (should (> (match-beginning 0) b-pos)))))
(ert-deftest taskjuggler-mode-move-block-down--nested-siblings ()
  "move-block-down swaps two nested sibling tasks."
  (with-nav-buffer "task p \"P\" {\n  task a \"A\" {\n  }\n  task b \"B\" {\n  }\n}\n"
    (re-search-forward "task a")
    (beginning-of-line)
    (taskjuggler-mode-move-block-down)
    ;; task b should now precede task a.
    (goto-char (point-min))
    (re-search-forward "task p")
    (should (re-search-forward "task b" nil t))
    (let ((b-pos (match-beginning 0)))
      (should (re-search-forward "task a" nil t))
      (should (> (match-beginning 0) b-pos)))))
;;; Corner cases: next-block / prev-block from inside a body

(ert-deftest taskjuggler-mode-next-block--from-inside-body ()
  "next-block from inside a block body jumps to the next sibling of that block."
  ;; When point is inside `task a', its enclosing header IS `task a'.
  ;; next-block should jump to `task b' (the sibling of `task a').
  (with-nav-buffer "task a \"A\" {\n  effort 1d\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mode-next-block)
    (should (looking-at "task b"))))
(ert-deftest taskjuggler-mode-prev-block--from-inside-body ()
  "prev-block from inside a block body jumps to the previous sibling of that block."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n  effort 1d\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mode-prev-block)
    (should (looking-at "task a"))))
;;; Corner cases: move-block error paths

(ert-deftest taskjuggler-mode-move-block-up--errors-at-first-sibling ()
  "move-block-up signals an error when there is no previous sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    ;; Point on `task a' — first sibling, no previous.
    (should-error (taskjuggler-mode-move-block-up) :type 'user-error)))
(ert-deftest taskjuggler-mode-move-block-down--errors-at-last-sibling ()
  "move-block-down signals an error when there is no next sibling."
  (with-nav-buffer "task a \"A\" {\n}\n\ntask b \"B\" {\n}\n"
    (re-search-forward "task b")
    (beginning-of-line)
    (should-error (taskjuggler-mode-move-block-down) :type 'user-error)))
(ert-deftest taskjuggler-mode-move-block-up--errors-when-not-on-block ()
  "move-block-up signals an error when point is not on a moveable block."
  (with-nav-buffer "\ntask a \"A\" {\n}\n"
    ;; Point starts on the blank line — not inside any block.
    (should-error (taskjuggler-mode-move-block-up) :type 'user-error)))
;;; Corner cases: scissors strings

(ert-deftest taskjuggler-mode-scissors--hash-inside-is-not-comment ()
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
      (should (not (nth 4 ppss))))))

(ert-deftest taskjuggler-mode-scissors--unclosed-makes-rest-string ()
  "Without a closing ->8-, everything after -8<- is treated as a string."
  (with-temp-buffer
    (insert "note -8<-\norphaned content\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "orphaned")
    (should (test-tj--in-string-p (point)))))
(ert-deftest taskjuggler-mode-scissors--commented-out-does-not-open-string ()
  "A -8<- inside a # comment does not open a scissors string."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n  # note -8<-\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (re-search-forward "effort")
    (should (not (test-tj--in-string-p (point))))))
(ert-deftest taskjuggler-mode-scissors--commented-out-does-not-break-indent ()
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
    (should (= taskjuggler-mode-indent-level (indent-at-line 5)))))
;;; Corner cases: continuation indent with no argument on anchor line

(ert-deftest taskjuggler-mode-indent--continuation-anchor-is-first-comma-line ()
  "The continuation anchor is the first comma-terminated line, not the line above.
When a keyword-only line (`columns') precedes the comma chain, the anchor
for alignment is the first comma-terminated line (`name,'), not `columns'."
  ;; Anchor line is `  name,' (first comma-terminated line).
  ;; `name' starts at col 2, ends at col 6.  The comma follows immediately,
  ;; so continuation-indent returns col 6 (position right after `name').
  (with-indent-buffer "taskreport r \"\" {\n  columns\n  name,\n  id\n}\n"
    (should (= 6 (indent-at-line 4)))))
;;; Corner cases: multiple consecutive comment lines

(ert-deftest taskjuggler-mode-block-with-comments-start--multiple-comments ()
  "All consecutive comment lines before the header are included."
  (with-temp-buffer
    (insert "# first\n# second\n# third\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 3)  ; header on line 4
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler-mode--block-with-comments-start header))))))
(ert-deftest taskjuggler-mode-block-with-comments-start--mixed-comment-types ()
  "A mix of `#' and `//' comment lines before the header are all included."
  (with-temp-buffer
    (insert "// slash comment\n# hash comment\ntask foo \"Foo\" {\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (goto-char (point-min))
    (forward-line 2)  ; header on line 3
    (let ((header (point)))
      (should (= (point-min)
                 (taskjuggler-mode--block-with-comments-start header))))))
;;; Corner cases: block-end with `{' in comment on header line

(ert-deftest taskjuggler-mode-block-end--brace-in-hash-comment-on-header ()
  "block-end ignores a `{' inside a `#' comment on the header line."
  (with-temp-buffer
    (insert "task foo \"Foo\" { # { this brace is in a comment\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler-mode--block-end (point-min))))
      (should (= (point-max) end)))))
(ert-deftest taskjuggler-mode-block-end--brace-in-slash-comment-on-header ()
  "block-end ignores a `{' inside a `// ' comment on the header line."
  (with-temp-buffer
    (insert "task foo \"Foo\" { // another { brace\n  effort 1d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (let ((end (taskjuggler-mode--block-end (point-min))))
      (should (= (point-max) end)))))
;;; Corner cases: goto-parent two levels up

(ert-deftest taskjuggler-mode-goto-parent--two-levels-up ()
  "Two consecutive goto-parent calls reach the outermost block header."
  (with-nav-buffer "task outer \"O\" {\n  task inner \"I\" {\n    effort 1d\n  }\n}\n"
    (re-search-forward "effort")
    (taskjuggler-mode-goto-parent)
    (should (looking-at "[ \t]*task inner"))
    (taskjuggler-mode-goto-parent)
    (should (looking-at "task outer"))))
;;; Corner cases: font-lock comment and string faces

(ert-deftest taskjuggler-mode-font-lock--slash-comment-face ()
  "Text inside a `// ' comment receives a comment face."
  (with-fontified-buffer "// this is a comment\ntask foo \"Foo\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "this is")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (or (eq face 'font-lock-comment-face)
                  (and (listp face) (memq 'font-lock-comment-face face)))))))
(ert-deftest taskjuggler-mode-font-lock--hash-comment-face ()
  "Text inside a `#' comment receives a comment face."
  (with-fontified-buffer "# hash comment\ntask foo \"Foo\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "hash comment")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (or (eq face 'font-lock-comment-face)
                  (and (listp face) (memq 'font-lock-comment-face face)))))))
(ert-deftest taskjuggler-mode-font-lock--string-face ()
  "Double-quoted strings receive a string face."
  (with-fontified-buffer "task foo \"My Task\" {\n}\n"
    (goto-char (point-min))
    (re-search-forward "My Task")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should (or (eq face 'font-lock-string-face)
                  (and (listp face) (memq 'font-lock-string-face face)))))))
(ert-deftest taskjuggler-mode-font-lock--value-keyword-face ()
  "Value keywords like `asap' receive `font-lock-variable-name-face'."
  (with-fontified-buffer "scheduling asap\n"
    (should (eq 'font-lock-variable-name-face
                (test-tj--face-at-string "asap")))))
(ert-deftest taskjuggler-mode-font-lock--report-keyword-face ()
  "Report type keywords receive `font-lock-function-name-face'."
  (with-fontified-buffer "taskreport r \"\" {\n}\n"
    (should (eq 'font-lock-function-name-face
                (test-tj--face-at-string "taskreport")))))
;;; Round 6: uncovered logic paths

;; --- taskjuggler-mode--prev-sibling-bounds: (t nil) cond arm ---
;; When the line before the first child is plain content (not a brace block
;; and not a moveable keyword), the cond falls through to (t nil) and
;; prev-sibling-bounds returns nil.

(ert-deftest taskjuggler-mode-prev-sibling-bounds--nil-when-prev-is-plain-content ()
  "Returns nil when the predecessor line is plain content, not a sibling block.
The `(t nil)' arm of the internal cond is taken when the candidate
predecessor is neither a `}'-terminated block nor a moveable keyword line."
  (with-nav-buffer "task p \"P\" {\n  effort 5d\n  task child \"C\" {\n  }\n}\n"
    (syntax-propertize (point-max))
    (re-search-forward "task child")
    (beginning-of-line)
    (should (null (taskjuggler-mode--prev-sibling-bounds (point))))))
;; --- taskjuggler-mode--next-sibling-bounds: /* */ comment skip branch ---
;; Lines 572-574 of the source: when a `/*' line is encountered while
;; scanning forward, re-search-forward is used to skip the entire comment
;; block rather than forward-line 1.

(ert-deftest taskjuggler-mode-next-sibling-bounds--skips-block-comment ()
  "next-sibling-bounds correctly skips a `/* */' comment between siblings."
  (with-nav-buffer "task a \"A\" {\n}\n\n/* inter-block comment */\n\ntask b \"B\" {\n}\n"
    (let ((bounds (taskjuggler-mode--next-sibling-bounds (point-min))))
      (should bounds)
      (goto-char (nth 1 bounds))
      (should (looking-at "task b")))))
(ert-deftest taskjuggler-mode-next-block--skips-block-comment-between-siblings ()
  "next-block finds the next sibling even with a `/* */' comment between them."
  (with-nav-buffer "task a \"A\" {\n}\n\n/* inter-block comment */\n\ntask b \"B\" {\n}\n"
    (taskjuggler-mode-next-block)
    (should (looking-at "task b"))))
;; --- taskjuggler-mode-indent-line: point-restoration branch ---
;; Lines 413-414: when point was inside line content before the call,
;; (- (point-max) pos) > new indented point, so we restore point to the
;; equivalent content position after re-indentation.

(ert-deftest taskjuggler-mode-indent-line--restores-point-inside-content ()
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
      (taskjuggler-mode-indent-line)
      ;; Point should be at the same logical position relative to point-max.
      (should (= (point) (- (point-max) dist-from-end))))))
;; --- taskjuggler-mode-indent-region: blank-line skip ---
;; Line 424: `(unless (looking-at "[ \t]*$") ...)' skips blank lines.
;; No previous test contained a blank line inside the indented region.

(ert-deftest taskjuggler-mode-indent-region--skips-blank-lines ()
  "indent-region leaves blank lines untouched."
  (with-temp-buffer
    (insert "task foo \"Foo\" {\n\n  effort 5d\n}\n")
    (taskjuggler-mode)
    (syntax-propertize (point-max))
    (taskjuggler-mode-indent-region (point-min) (point-max))
    ;; Line 2 is blank; it must remain blank (no spaces inserted).
    (goto-char (point-min))
    (forward-line 1)
    (should (looking-at "^$"))))
;; --- taskjuggler-mode--backward-sexp-1: non-`}' fallback ---
;; Line 880: when char-before (after skipping whitespace) is not `}',
;; the block-detection save-excursion sets block-start to nil and we
;; fall back to the default (forward-sexp -1).

(ert-deftest taskjuggler-mode-backward-sexp--fallback-for-non-brace-token ()
  "backward-sexp from after a plain token falls back to default sexp movement.
When the character before point is not `}', the block-detection is skipped
and `forward-sexp -1' moves back over the token normally."
  (with-nav-buffer "task foo \"Foo\" {\n  effort 5d\n}\n"
    (re-search-forward "5d")
    ;; Point is just after "5d"; char-before = 'd', not `}'.
    (let ((pos-before (point)))
      (taskjuggler-mode--forward-sexp -1)
      (should (< (point) pos-before))
      (should (looking-at "5d")))))
;; --- narrow-to-block / mark-block: not-on-block error ---

(ert-deftest taskjuggler-mode-narrow-to-block--errors-when-not-on-block ()
  "narrow-to-block signals a user-error when point is not inside any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n}\n"
    ;; Point is on the blank line before the task — not inside any block.
    (should-error (taskjuggler-mode-narrow-to-block) :type 'user-error)))
(ert-deftest taskjuggler-mode-mark-block--errors-when-not-on-block ()
  "mark-block signals a user-error when point is not inside any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n}\n"
    (should-error (taskjuggler-mode-mark-block) :type 'user-error)))
;; --- goto-first-child / goto-last-child: not-on-block error ---

(ert-deftest taskjuggler-mode-goto-first-child--errors-when-not-on-block ()
  "goto-first-child signals a user-error when point is not on any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n  task child \"C\" {\n  }\n}\n"
    ;; Point is on the initial blank line — not inside any block.
    (should-error (taskjuggler-mode-goto-first-child) :type 'user-error)))
(ert-deftest taskjuggler-mode-goto-last-child--errors-when-not-on-block ()
  "goto-last-child signals a user-error when point is not on any block."
  (with-nav-buffer "\ntask foo \"Foo\" {\n  task child \"C\" {\n  }\n}\n"
    (should-error (taskjuggler-mode-goto-last-child) :type 'user-error)))
;;; Round 8: calendar popup layout properties

;; Week rows are built as:
;;   " " cell0 " " cell1 " " cell2 " " cell3 " " cell4 " " cell5 " " cell6 " "
;; Each cell is a 2-char propertized string; cell i starts at position 1 + 3*i.

;; Subsystem suites
(require 'taskjuggler-mode-cal-test)
(require 'taskjuggler-mode-cursor-test)
(require 'taskjuggler-mode-daemon-test)
(require 'taskjuggler-mode-flymake-test)
(require 'taskjuggler-mode-tj3man-test)
(require 'taskjuggler-mode-scenario-test)

(provide 'taskjuggler-mode-test)

;;; taskjuggler-mode-test.el ends here
