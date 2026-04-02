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

;; ---- Digit input parsing ----

(ert-deftest tj-cal-parse-digit-input ()
  "Test parsing various digit input formats."
  ;; DD
  (should (equal '(2024 3 15) (taskjuggler--cal-parse-digit-input "15" 2024 3)))
  ;; MMDD
  (should (equal '(2024 4 1) (taskjuggler--cal-parse-digit-input "0401" 2024 3)))
  ;; YYYYMMDD
  (should (equal '(2025 6 15) (taskjuggler--cal-parse-digit-input "20250615" 2024 3)))
  ;; MM-DD
  (should (equal '(2024 4 1) (taskjuggler--cal-parse-digit-input "4-1" 2024 3)))
  ;; YYYY-MM-DD
  (should (equal '(2025 6 15) (taskjuggler--cal-parse-digit-input "2025-6-15" 2024 3)))
  ;; Invalid
  (should-not (taskjuggler--cal-parse-digit-input "abc" 2024 3)))

;; ---- Calendar rendering ----

(ert-deftest tj-cal-render-basic-structure ()
  "Test that rendered calendar has correct structure."
  (let ((output (taskjuggler--cal-render 2026 3 1)))
    ;; Has box borders.
    (should (string-prefix-p "+" output))
    (should (string-suffix-p "+" output))
    ;; Contains the month title.
    (should (string-match-p "March 2026" output))
    ;; Contains the day header.
    (should (string-match-p "Su Mo Tu We Th Fr Sa" output))
    ;; Contains the selected day in brackets.
    (should (string-match-p "\\[1\\]" output))))

(ert-deftest tj-cal-render-selected-day ()
  "Test that the selected day is bracketed and others are not."
  (let ((output (taskjuggler--cal-render 2024 1 15)))
    (should (string-match-p "\\[15\\]" output))
    ;; Day 14 should not be bracketed.
    (should (string-match-p "14" output))
    (should-not (string-match-p "\\[14\\]" output))))

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
