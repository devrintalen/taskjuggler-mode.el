;;; taskjuggler-mode-tj3man-test.el --- tj3man subsystem tests -*- lexical-binding: t -*-

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

;;; Helpers

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
     (let ((taskjuggler-mode--tj3man-keywords '("task" "allocate" "depends"
                                           "duration" "milestone" "properties"
                                           "interval2")))
       (taskjuggler-mode--fontify-tj3man))
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

(ert-deftest taskjuggler-mode-fontify-tj3man--headers-get-overstrike ()
  "All six section headers receive the Man-overstrike face."
  (with-tj3man-buffer
   (should (eq 'Man-overstrike (test-face-at-string "Keyword:")))
   (should (eq 'Man-overstrike (test-face-at-string "Purpose:")))
   (should (eq 'Man-overstrike (test-face-at-string "Syntax:")))
   (should (eq 'Man-overstrike (test-face-at-string "Arguments:")))
   (should (eq 'Man-overstrike (test-face-at-string "Context:")))
   (should (eq 'Man-overstrike (test-face-at-string "Attributes:")))))
(ert-deftest taskjuggler-mode-fontify-tj3man--syntax-args-get-underline ()
  "<argument> placeholders on the Syntax line receive the Man-underline face."
  (with-tj3man-buffer
   (should (eq 'Man-underline (test-face-at-string "<id>")))
   (should (eq 'Man-underline (test-face-at-string "<name>")))
   (should (eq 'Man-underline (test-face-at-string "<duration>")))))
(ert-deftest taskjuggler-mode-fontify-tj3man--attributes-are-buttons ()
  "Entries in the Attributes section are buttons with the button face."
  (with-tj3man-buffer
   (should (test-button-at-string "allocate[sc:ip]"))
   (should (test-button-at-string "depends[sc:ip]"))
   (should (test-button-at-string "duration[sc]"))
   (should (test-button-at-string "milestone[sc]"))))
(ert-deftest taskjuggler-mode-fontify-tj3man--attributes-legend-not-buttons ()
  "The [sc]/[ip] legend lines after the blank line are not turned into buttons."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     ;; Find the legend line and check it has no button property.
     (re-search-forward "\\[sc\\] : Attribute")
     (should-not (get-text-property (match-beginning 0) 'button)))))
(ert-deftest taskjuggler-mode-fontify-tj3man--argument-names-get-overstrike ()
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
(ert-deftest taskjuggler-mode-fontify-tj3man--argument-types-get-underline ()
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
(ert-deftest taskjuggler-mode-fontify-tj3man--syntax-multiline-gets-underline ()
  "Man-underline is applied to <arg> placeholders on continuation lines of Syntax."
  (with-tj3man-buffer
   ;; <more> is on the second (continuation) line of the Syntax section.
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "^Syntax:")
     (re-search-forward "<more>")
     (should (eq 'Man-underline
                 (get-text-property (match-beginning 0) 'face))))))
(ert-deftest taskjuggler-mode-fontify-tj3man--uppercase-argument-name-gets-overstrike ()
  "Argument names starting with an uppercase letter receive Man-overstrike face."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Arguments:")
     (re-search-forward "^             \\(ID\\):")
     (should (eq 'Man-overstrike
                 (get-text-property (match-beginning 1) 'face))))))
(ert-deftest taskjuggler-mode-fontify-tj3man--multiword-argument-name-gets-overstrike ()
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
(ert-deftest taskjuggler-mode-fontify-tj3man--attribute-modifier-content-underlined ()
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
(ert-deftest taskjuggler-mode-fontify-tj3man--attribute-button-on-name-only ()
  "The button in the Attributes section covers only the attribute name, not modifier tags."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "Attributes:")
     (re-search-forward "allocate\\(\\[sc:ip\\]\\)")
     ;; The [ of the modifier tag should not carry the button property.
     (should-not (get-text-property (match-beginning 1) 'button)))))
(ert-deftest taskjuggler-mode-fontify-tj3man--legend-modifier-content-underlined ()
  "Modifier keys in the [sc]/[ig]/[ip] legend lines get Man-underline face."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "\\[\\(sc\\)\\] : Attribute")
     (should (eq 'Man-underline
                 (get-text-property (match-beginning 1) 'face))))))
(ert-deftest taskjuggler-mode-fontify-tj3man--argument-keyword-not-linkified ()
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
(ert-deftest taskjuggler-mode-fontify-tj3man--keyword-line-value-not-a-button ()
  "The keyword value on the Keyword: line is not linkified."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "^Keyword:[ \t]+")
     (should-not (get-text-property (point) 'button)))))
(ert-deftest taskjuggler-mode-fontify-tj3man--syntax-line-keyword-not-a-button ()
  "The keyword name (first word) on the Syntax: line is not linkified."
  (with-tj3man-buffer
   (save-excursion
     (goto-char (point-min))
     (re-search-forward "^Syntax:[ \t]+")
     (should-not (get-text-property (point) 'button)))))
(ert-deftest taskjuggler-mode-fontify-tj3man--keywords-in-text-are-buttons ()
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

(provide 'taskjuggler-mode-tj3man-test)

;;; taskjuggler-mode-tj3man-test.el ends here
