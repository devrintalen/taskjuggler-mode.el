;;; taskjuggler-cal-test.el --- Tests for the inline calendar picker  -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for calendar math, rendering, date parsing/formatting,
;; and digit-input parsing used by the taskjuggler-mode date picker.
;;
;; Run with:
;;   emacs --batch -l taskjuggler-mode.el -l test/taskjuggler-cal-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

;; ---- Leap year ----

(ert-deftest tj-cal-leap-year ()
  "Test leap year detection."
  (should (taskjuggler--cal-leap-year-p 2000))
  (should (taskjuggler--cal-leap-year-p 2024))
  (should-not (taskjuggler--cal-leap-year-p 1900))
  (should-not (taskjuggler--cal-leap-year-p 2023)))

;; ---- Days in month ----

(ert-deftest tj-cal-days-in-month ()
  "Test days-in-month for all months and leap year February."
  (should (= 31 (taskjuggler--cal-days-in-month 2024 1)))
  (should (= 29 (taskjuggler--cal-days-in-month 2024 2)))
  (should (= 28 (taskjuggler--cal-days-in-month 2023 2)))
  (should (= 31 (taskjuggler--cal-days-in-month 2024 3)))
  (should (= 30 (taskjuggler--cal-days-in-month 2024 4)))
  (should (= 31 (taskjuggler--cal-days-in-month 2024 5)))
  (should (= 30 (taskjuggler--cal-days-in-month 2024 6)))
  (should (= 31 (taskjuggler--cal-days-in-month 2024 7)))
  (should (= 31 (taskjuggler--cal-days-in-month 2024 8)))
  (should (= 30 (taskjuggler--cal-days-in-month 2024 9)))
  (should (= 31 (taskjuggler--cal-days-in-month 2024 10)))
  (should (= 30 (taskjuggler--cal-days-in-month 2024 11)))
  (should (= 31 (taskjuggler--cal-days-in-month 2024 12))))

;; ---- Day of week ----

(ert-deftest tj-cal-day-of-week ()
  "Test day-of-week calculation against known dates."
  ;; 2024-01-01 is a Monday.
  (should (= 1 (taskjuggler--cal-day-of-week 2024 1 1)))
  ;; 2024-03-01 is a Friday.
  (should (= 5 (taskjuggler--cal-day-of-week 2024 3 1)))
  ;; 2026-03-01 is a Sunday.
  (should (= 0 (taskjuggler--cal-day-of-week 2026 3 1))))

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

;;; taskjuggler-cal-test.el ends here
