;;; taskjuggler-mode-cal-test.el --- cal subsystem tests -*- lexical-binding: t -*-

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))

(require 'taskjuggler-mode-test-helpers)

;;; Helpers

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

;; Stub taskjuggler-mode--cal-edit and optionally decode-time so date-dwim
;; tests don't trigger overlays, minor-mode hooks, or depend on today's date.
(defmacro with-cal-edit-stubbed (decode-time-result &rest body)
  "Run BODY with `taskjuggler-mode--cal-edit' stubbed to capture its args.
DECODE-TIME-RESULT is a list used as the return value of `decode-time'.
The captured argument list is bound to `cal-args' (a list of
\(date-beg year month day was-inserted)) within BODY."
  (declare (indent 1))
  `(let (cal-args)
     (cl-letf (((symbol-function 'taskjuggler-mode--cal-edit)
                (lambda (date-beg year month day was-inserted)
                  (setq cal-args (list date-beg year month day was-inserted))))
               ((symbol-function 'decode-time)
                (lambda (&rest _) ,decode-time-result)))
       ,@body)
     cal-args))

;;; Tests: date helpers

(ert-deftest taskjuggler-mode-parse-tj-date--basic ()
  "Parses a plain YYYY-MM-DD date string."
  (should (equal '(2024 3 15) (taskjuggler-mode--parse-tj-date "2024-03-15"))))
(ert-deftest taskjuggler-mode-parse-tj-date--with-time ()
  "Parses a YYYY-MM-DD-HH:MM date string, returning only the date part."
  (should (equal '(2024 3 15) (taskjuggler-mode--parse-tj-date "2024-03-15-09:00"))))
(ert-deftest taskjuggler-mode-parse-tj-date--with-seconds ()
  "Parses a YYYY-MM-DD-HH:MM:SS date string, returning only the date part."
  (should (equal '(2024 12 1) (taskjuggler-mode--parse-tj-date "2024-12-01-09:00:00"))))
(ert-deftest taskjuggler-mode-parse-tj-date--invalid ()
  "Returns nil for strings that are not TJ3 date literals."
  (should (null (taskjuggler-mode--parse-tj-date "not-a-date")))
  (should (null (taskjuggler-mode--parse-tj-date ""))))
(ert-deftest taskjuggler-mode-format-tj-date--basic ()
  "Formats year/month/day into YYYY-MM-DD with zero-padding."
  (should (equal "2024-03-05" (taskjuggler-mode--format-tj-date 2024 3 5))))
(ert-deftest taskjuggler-mode-format-tj-date--round-trip ()
  "parse → format round-trips cleanly."
  (let* ((original "2025-11-30")
         (parsed (taskjuggler-mode--parse-tj-date original))
         (formatted (apply #'taskjuggler-mode--format-tj-date parsed)))
    (should (equal original formatted))))
(ert-deftest taskjuggler-mode-date-bounds-at-point--on-date ()
  "Returns the bounds when point is on a date literal."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024")
    (let ((bounds (taskjuggler-mode--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-03-15"
                     (buffer-substring (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-date-bounds-at-point--before-date ()
  "Returns nil when point is before any date on the line."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (taskjuggler-mode)
    (goto-char (point-min))   ; "s" of "start"
    (should (null (taskjuggler-mode--date-bounds-at-point)))))
(ert-deftest taskjuggler-mode-date-bounds-at-point--no-date ()
  "Returns nil on a line with no date literal."
  (with-temp-buffer
    (insert "effort 5d\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (should (null (taskjuggler-mode--date-bounds-at-point)))))
(ert-deftest taskjuggler-mode-date-bounds-at-point--at-end-of-date ()
  "Returns bounds when point is at the last character of the date."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024-03-15")
    ;; Point is now just after the date; step back one char to land on "5".
    (backward-char 1)
    (let ((bounds (taskjuggler-mode--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-03-15"
                     (buffer-substring (car bounds) (cdr bounds)))))))
;;; Tests: calendar math

(ert-deftest taskjuggler-mode-cal-clamp-day--within-range ()
  "Returns the day unchanged when it is valid for that month."
  (should (= 15 (taskjuggler-mode--cal-clamp-day 2024 3 15))))
(ert-deftest taskjuggler-mode-cal-clamp-day--clamps-to-month-end ()
  "Clamps day 31 to 30 for a 30-day month."
  (should (= 30 (taskjuggler-mode--cal-clamp-day 2024 4 31))))
(ert-deftest taskjuggler-mode-cal-clamp-day--february-leap-year ()
  "February in a leap year allows day 29."
  (should (= 29 (taskjuggler-mode--cal-clamp-day 2024 2 29))))
(ert-deftest taskjuggler-mode-cal-clamp-day--february-non-leap-year ()
  "Clamps day 29 to 28 in a non-leap-year February."
  (should (= 28 (taskjuggler-mode--cal-clamp-day 2023 2 29))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-forward ()
  "Adjusting by +1 :day advances one day."
  (should (equal '(2024 3 16) (taskjuggler-mode--cal-adjust-date 2024 3 15 1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-backward ()
  "Adjusting by -1 :day retreats one day."
  (should (equal '(2024 3 14) (taskjuggler-mode--cal-adjust-date 2024 3 15 -1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-crosses-month ()
  "Adjusting by day correctly crosses a month boundary."
  (should (equal '(2024 4 1) (taskjuggler-mode--cal-adjust-date 2024 3 31 1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--week ()
  "Adjusting by 1 :week advances exactly 7 days."
  (should (equal '(2024 3 22) (taskjuggler-mode--cal-adjust-date 2024 3 15 1 :week))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-forward ()
  "Adjusting by +1 :month advances one month."
  (should (equal '(2024 4 15) (taskjuggler-mode--cal-adjust-date 2024 3 15 1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-year-rollover ()
  "Adjusting month forward past December rolls over to next year."
  (should (equal '(2025 1 15) (taskjuggler-mode--cal-adjust-date 2024 12 15 1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-clamps-day ()
  "Month adjustment clamps the day when the target month is shorter."
  ;; March 31 + 1 month = April 30 (April has only 30 days).
  (should (equal '(2024 4 30) (taskjuggler-mode--cal-adjust-date 2024 3 31 1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-backward-year-rollover ()
  "Adjusting month backward past January rolls over to previous year."
  (should (equal '(2023 12 15) (taskjuggler-mode--cal-adjust-date 2024 1 15 -1 :month))))
;;; Corner cases: date-bounds with two dates on same line

(ert-deftest taskjuggler-mode-date-bounds-at-point--second-date-on-line ()
  "Returns bounds for the second date when point is on it."
  (with-temp-buffer
    (insert "period 2024-01-01 2024-12-31\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024-12")
    (let ((bounds (taskjuggler-mode--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-12-31"
                     (buffer-substring (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-date-bounds-at-point--first-of-two-dates ()
  "Returns bounds for the first date when point is on it."
  (with-temp-buffer
    (insert "period 2024-01-01 2024-12-31\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2024-01")
    (let ((bounds (taskjuggler-mode--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-01-01"
                     (buffer-substring (car bounds) (cdr bounds)))))))
;;; Corner cases: calendar math

(ert-deftest taskjuggler-mode-cal-adjust-date--week-backward ()
  "Adjusting by -1 :week retreats exactly 7 days."
  (should (equal '(2024 3 8) (taskjuggler-mode--cal-adjust-date 2024 3 15 -1 :week))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-crosses-year ()
  "Adjusting by +1 :day from Dec 31 rolls into the next year."
  (should (equal '(2025 1 1) (taskjuggler-mode--cal-adjust-date 2024 12 31 1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-forward-13 ()
  "Adjusting by +13 :months advances more than one year."
  (should (equal '(2026 4 15) (taskjuggler-mode--cal-adjust-date 2025 3 15 13 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-backward-13 ()
  "Adjusting by -13 :months retreats more than one year."
  (should (equal '(2024 2 15) (taskjuggler-mode--cal-adjust-date 2025 3 15 -13 :month))))
;; --- taskjuggler-mode--cal-valid-char-at-p ---
;; Two branches: positions 4 and 7 require a hyphen; all others require a digit.

(ert-deftest taskjuggler-mode-cal-valid-char-at-p--hyphen-at-sep-positions ()
  "A hyphen is valid at separator positions 4 and 7."
  (should (taskjuggler-mode--cal-valid-char-at-p ?- 4))
  (should (taskjuggler-mode--cal-valid-char-at-p ?- 7)))
(ert-deftest taskjuggler-mode-cal-valid-char-at-p--digit-invalid-at-sep-positions ()
  "A digit is invalid at separator positions 4 and 7."
  (should (not (taskjuggler-mode--cal-valid-char-at-p ?0 4)))
  (should (not (taskjuggler-mode--cal-valid-char-at-p ?9 7))))
(ert-deftest taskjuggler-mode-cal-valid-char-at-p--digit-valid-at-digit-positions ()
  "A digit is valid at non-separator positions."
  (should (taskjuggler-mode--cal-valid-char-at-p ?2 0))
  (should (taskjuggler-mode--cal-valid-char-at-p ?0 5))
  (should (taskjuggler-mode--cal-valid-char-at-p ?1 8)))
(ert-deftest taskjuggler-mode-cal-valid-char-at-p--hyphen-invalid-at-digit-positions ()
  "A hyphen is invalid at non-separator positions."
  (should (not (taskjuggler-mode--cal-valid-char-at-p ?- 0)))
  (should (not (taskjuggler-mode--cal-valid-char-at-p ?- 5)))
  (should (not (taskjuggler-mode--cal-valid-char-at-p ?- 9))))
;; --- taskjuggler-mode--cal-parse-typed-prefix ---
;; Guards: (>= typed-len 4/7/10), (> y 0), (<= 1 m 12), (>= d 1).

(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--zero-typed-returns-default ()
  "With typed-len=0, no parsing occurs and the default date is returned."
  (with-temp-buffer
    (insert "2024-03-15")
    (should (equal '(2026 1 1)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 0 '(2026 1 1))))))
(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--four-chars-sets-year ()
  "With typed-len=4, the year is parsed from the buffer prefix."
  (with-temp-buffer
    (insert "2024-03-15")
    (should (equal '(2024 1 1)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 4 '(2026 1 1))))))
(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--seven-chars-sets-year-and-month ()
  "With typed-len=7, year and month are parsed."
  (with-temp-buffer
    (insert "2024-06-15")
    (should (equal '(2024 6 1)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 7 '(2026 1 1))))))
(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--ten-chars-sets-all ()
  "With typed-len=10, year, month, and day are all parsed."
  (with-temp-buffer
    (insert "2024-06-15")
    (should (equal '(2024 6 15)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 10 '(2026 1 1))))))
(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--year-zero-rejected ()
  "A parsed year of 0 is rejected; the default year is kept."
  (with-temp-buffer
    (insert "0000-06-15")
    ;; y=0, `(> y 0)' is false → keep default year 2026.
    (should (equal '(2026 1 1)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 4 '(2026 1 1))))))
(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--invalid-month-rejected ()
  "A month value outside 1-12 is rejected; the default month is kept."
  (with-temp-buffer
    (insert "2024-13-15")
    ;; m=13, `(<= 1 13 12)' is false → keep default month 5.
    (should (equal '(2024 5 1)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 7 '(2026 5 1))))))
(ert-deftest taskjuggler-mode-cal-parse-typed-prefix--day-clamped-to-month ()
  "Day 31 is clamped to the last valid day of the parsed month."
  (with-temp-buffer
    (insert "2024-02-31")
    ;; Feb 2024 is a leap year; max day = 29.
    (should (equal '(2024 2 29)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 10 '(2026 1 1))))))
;; --- taskjuggler-mode--cal-splice-line ---
;; Branch 1: col <= old-len → take substring for left side.
;; Branch 2: col > old-len  → pad with spaces.
;; Branch 3: right-start < old-len  → right side has content.
;; Branch 4: right-start >= old-len → right side is "".

(ert-deftest taskjuggler-mode-cal-splice-line--normal-insertion ()
  "Splices new text into old at col, preserving text on both sides."
  ;; "leftXXXright" with "CAL" at col 4 → "leftCALright"
  (should (equal "leftCALright"
                 (taskjuggler-mode--cal-splice-line "leftXXXright" "CAL" 4))))
(ert-deftest taskjuggler-mode-cal-splice-line--col-beyond-line-pads-with-spaces ()
  "When col > old-len, spaces are inserted to reach col before new text."
  ;; "ab" (len=2) with "CAL" at col 4: needs 2 padding spaces.
  (should (equal "ab  CAL"
                 (taskjuggler-mode--cal-splice-line "ab" "CAL" 4))))
(ert-deftest taskjuggler-mode-cal-splice-line--no-right-remainder ()
  "When right-start >= old-len, the right portion is empty."
  ;; "leftXX" (len=6) with "CAL" at col 4: right-start=7 >= 6 → right="".
  (should (equal "leftCAL"
                 (taskjuggler-mode--cal-splice-line "leftXX" "CAL" 4))))
;; --- taskjuggler-mode--cal-pad-line: overflow ---

(ert-deftest taskjuggler-mode-cal-pad-line--text-longer-than-width ()
  "When text exceeds cal-width, no padding is added (max 0 guard)."
  (let* ((long-text (make-string (+ taskjuggler-mode--cal-width 5) ?x))
         (result (taskjuggler-mode--cal-pad-line long-text)))
    (should (equal long-text result))))
;; --- taskjuggler-mode--cal-build-display: exhausted old-lines ---
;; Line 1141: `(or (pop old-lines) "")' supplies an empty string when
;; old-lines runs out before cal-lines does.

(ert-deftest taskjuggler-mode-cal-build-display--empty-old-lines ()
  "When old-lines is empty, calendar rows splice into empty strings."
  (let* ((result (taskjuggler-mode--cal-build-display '("ROW1" "ROW2") nil 0)))
    (should (string-match-p "ROW1" result))
    (should (string-match-p "ROW2" result))))
;; --- taskjuggler-mode--cal-week-lines: Sunday start (no leading cells) ---
;; `(when (> start-dow 0))' on line 1018: skipped when a month starts on Sunday.
;; Feb 2015 has 28 days and starts on Sunday → 0 leading cells, 0 trailing
;; cells (28 / 7 = 4 exactly) → exactly 4 week rows.

(ert-deftest taskjuggler-mode-cal-week-lines--sunday-start-no-leading-cells ()
  "A month starting on Sunday produces no leading cells and the minimum row count.
Feb 2015 starts on Sunday (start-dow=0) and has 28 days: 4 rows exactly."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2015 2 15 2015 2 15)))
    (should (= 4 (length weeks)))))
;; --- taskjuggler-mode--cal-week-lines: no trailing fill ---
;; `(when (> trailing 0))' on line 1041: skipped when cells divide evenly by 7.

(ert-deftest taskjuggler-mode-cal-week-lines--no-trailing-fill-needed ()
  "A month whose cell count is a multiple of 7 needs no trailing fill.
Feb 2015 (28 days, Sunday start): 28 cells / 7 = 4 rows, remainder 0."
  ;; Contrast with a month that DOES have trailing fill.
  ;; January 2024 starts on Monday (start-dow=1): 1+31=32 cells, 32%7=4,
  ;; trailing=3 → 35 cells → 5 rows.
  (let ((weeks-jan (taskjuggler-mode--cal-week-lines 2024 1 15 2024 1 15))
        (weeks-feb (taskjuggler-mode--cal-week-lines 2015 2 15 2015 2 15)))
    (should (= 5 (length weeks-jan)))
    (should (= 4 (length weeks-feb)))))
;;; Round 7: calendar navigation — leap year coverage and nav-delta

;; --- taskjuggler-mode--cal-nav-delta ---
;; Maps the six shift-arrow keys to (delta . unit) cons cells.
;; All six pcase arms are untested.

(ert-deftest taskjuggler-mode-cal-nav-delta--all-keys ()
  "Each shift-arrow key maps to the correct (delta . unit) pair."
  (should (equal '(1  . :day)   (taskjuggler-mode--cal-nav-delta 'S-right)))
  (should (equal '(-1 . :day)   (taskjuggler-mode--cal-nav-delta 'S-left)))
  (should (equal '(1  . :week)  (taskjuggler-mode--cal-nav-delta 'S-down)))
  (should (equal '(-1 . :week)  (taskjuggler-mode--cal-nav-delta 'S-up)))
  (should (equal '(1  . :month) (taskjuggler-mode--cal-nav-delta 'S-next)))
  (should (equal '(-1 . :month) (taskjuggler-mode--cal-nav-delta 'S-prior))))
;; --- :day movement across the February boundary ---

(ert-deftest taskjuggler-mode-cal-adjust-date--day-feb28-to-feb29-leap ()
  "+1 day from Feb 28 in a leap year lands on Feb 29."
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 2 28 1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-feb29-to-mar1-leap ()
  "+1 day from Feb 29 in a leap year crosses into March."
  (should (equal '(2024 3 1) (taskjuggler-mode--cal-adjust-date 2024 2 29 1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-feb28-to-mar1-non-leap ()
  "+1 day from Feb 28 in a non-leap year jumps directly to March 1."
  (should (equal '(2023 3 1) (taskjuggler-mode--cal-adjust-date 2023 2 28 1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-backward-mar1-to-feb29-leap ()
  "-1 day from Mar 1 in a leap year lands on Feb 29."
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 3 1 -1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-backward-mar1-to-feb28-non-leap ()
  "-1 day from Mar 1 in a non-leap year lands on Feb 28."
  (should (equal '(2023 2 28) (taskjuggler-mode--cal-adjust-date 2023 3 1 -1 :day))))
(ert-deftest taskjuggler-mode-cal-adjust-date--day-backward-feb29-to-feb28-leap ()
  "-1 day from Feb 29 lands on Feb 28 in the same leap year."
  (should (equal '(2024 2 28) (taskjuggler-mode--cal-adjust-date 2024 2 29 -1 :day))))
;; --- :week movement across the February boundary ---

(ert-deftest taskjuggler-mode-cal-adjust-date--week-lands-on-feb29 ()
  "+1 week from Feb 22 in a leap year lands on Feb 29."
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 2 22 1 :week))))
(ert-deftest taskjuggler-mode-cal-adjust-date--week-crosses-feb29-leap ()
  "+1 week from Feb 25 in a leap year crosses Feb 29 and lands in March."
  (should (equal '(2024 3 3) (taskjuggler-mode--cal-adjust-date 2024 2 25 1 :week))))
(ert-deftest taskjuggler-mode-cal-adjust-date--week-crosses-feb28-non-leap ()
  "+1 week from Feb 22 in a non-leap year crosses Feb 28 and lands in March."
  (should (equal '(2023 3 1) (taskjuggler-mode--cal-adjust-date 2023 2 22 1 :week))))
(ert-deftest taskjuggler-mode-cal-adjust-date--week-backward-crosses-feb29 ()
  "-1 week from Mar 7 in a leap year crosses Feb 29."
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 3 7 -1 :week))))
;; --- :month movement clamping into February ---

(ert-deftest taskjuggler-mode-cal-adjust-date--month-jan31-to-feb28-non-leap ()
  "Jan 31 + 1 month in a non-leap year clamps to Feb 28."
  (should (equal '(2023 2 28) (taskjuggler-mode--cal-adjust-date 2023 1 31 1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-jan31-to-feb29-leap ()
  "Jan 31 + 1 month in a leap year clamps to Feb 29."
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 1 31 1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-backward-mar31-to-feb28-non-leap ()
  "Mar 31 - 1 month in a non-leap year clamps to Feb 28."
  (should (equal '(2023 2 28) (taskjuggler-mode--cal-adjust-date 2023 3 31 -1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-backward-mar31-to-feb29-leap ()
  "Mar 31 - 1 month in a leap year clamps to Feb 29."
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 3 31 -1 :month))))
;; --- :month movement starting from Feb 29 (the leap day itself) ---

(ert-deftest taskjuggler-mode-cal-adjust-date--month-from-feb29-forward ()
  "Feb 29 + 1 month advances to Mar 29 without clamping."
  (should (equal '(2024 3 29) (taskjuggler-mode--cal-adjust-date 2024 2 29 1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-from-feb29-backward ()
  "Feb 29 - 1 month retreats to Jan 29 without clamping."
  (should (equal '(2024 1 29) (taskjuggler-mode--cal-adjust-date 2024 2 29 -1 :month))))
(ert-deftest taskjuggler-mode-cal-adjust-date--month-from-feb29-to-feb-non-leap ()
  "Feb 29 + 12 months lands in the next year's February, clamping to Feb 28."
  ;; 2024-02-29 + 12 months = 2025-02-28 (2025 is not a leap year).
  (should (equal '(2025 2 28) (taskjuggler-mode--cal-adjust-date 2024 2 29 12 :month))))
;; --- Row-count tests ---

(ert-deftest taskjuggler-mode-cal-week-lines--five-week-month ()
  "A month that spans 5 calendar rows returns 5 week rows.
January 2024 starts on Monday (start-dow=1): 1 leading + 31 + 3 trailing = 35 = 5 rows."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 1 15 2024 1 15)))
    (should (= 5 (length weeks)))))
(ert-deftest taskjuggler-mode-cal-week-lines--six-week-month ()
  "A month that spans 6 calendar rows returns 6 week rows.
December 2018 starts on Saturday (start-dow=6): 6 + 31 + 5 trailing = 42 = 6 rows."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2018 12 15 2018 12 15)))
    (should (= 6 (length weeks)))))
;; --- Leading-cell tests ---
;; Feb 2024 starts on Thursday (start-dow=4).
;; Previous month is January (31 days): first-prev = 1+(31-4) = 28.
;; Leading cells occupy row 0, positions 0-3 (Jan 28-31).

(ert-deftest taskjuggler-mode-cal-week-lines--leading-cells-have-inactive-face ()
  "Every leading cell from the previous month carries the inactive face."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
    (should (eq 'taskjuggler-mode-cal-inactive-face (test-tj--cell-face weeks 0 0)))
    (should (eq 'taskjuggler-mode-cal-inactive-face (test-tj--cell-face weeks 0 1)))
    (should (eq 'taskjuggler-mode-cal-inactive-face (test-tj--cell-face weeks 0 2)))
    (should (eq 'taskjuggler-mode-cal-inactive-face (test-tj--cell-face weeks 0 3)))))
(ert-deftest taskjuggler-mode-cal-week-lines--leading-cells-start-at-correct-day ()
  "Leading cells show the correct end-of-previous-month day numbers."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
    (should (= 28 (test-tj--cell-day weeks 0 0)))
    (should (= 29 (test-tj--cell-day weeks 0 1)))
    (should (= 30 (test-tj--cell-day weeks 0 2)))
    (should (= 31 (test-tj--cell-day weeks 0 3)))))
(ert-deftest taskjuggler-mode-cal-week-lines--no-leading-first-cell-is-day-1 ()
  "When start-dow=0 (Sunday), no leading cells — first cell of row 0 is day 1.
February 2015 starts on Sunday."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2015 2 15 2026 1 1)))
    (should (= 1 (test-tj--cell-day weeks 0 0)))))
(ert-deftest taskjuggler-mode-cal-week-lines--six-week-leading-cells ()
  "A month with start-dow=6 has 6 leading cells starting at the right day.
December 2018 starts on Saturday; November has 30 days: first-prev = 1+(30-6) = 25."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2018 12 15 2026 1 1)))
    (should (= 25 (test-tj--cell-day weeks 0 0)))
    (should (= 30 (test-tj--cell-day weeks 0 5)))
    ;; Cell 6 of row 0 is Dec 1 — first day of the actual month.
    (should (= 1 (test-tj--cell-day weeks 0 6)))))
;; --- Trailing-cell tests ---
;; Feb 2024: 4 leading + 29 = 33 cells; trailing = 7-(33%7) = 2 (Mar 1-2).
;; They appear at row 4, cells 5-6.

(ert-deftest taskjuggler-mode-cal-week-lines--trailing-cells-have-inactive-face ()
  "Trailing cells from the next month carry the inactive face."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
    (should (eq 'taskjuggler-mode-cal-inactive-face (test-tj--cell-face weeks 4 5)))
    (should (eq 'taskjuggler-mode-cal-inactive-face (test-tj--cell-face weeks 4 6)))))
(ert-deftest taskjuggler-mode-cal-week-lines--trailing-cells-start-at-day-1 ()
  "Trailing cells always count up from day 1 of the following month."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
    (should (= 1 (test-tj--cell-day weeks 4 5)))
    (should (= 2 (test-tj--cell-day weeks 4 6)))))
;; --- Face tests ---
;; All use Feb 2024, selected=15, today either far away or on a specific day.
;; Feb 15 offset: 4 leading + 15 - 1 = 18 = row 2 cell 4.
;; Feb 10 offset: 4 + 10 - 1 = 13 = row 1 cell 6.
;; Feb  1 offset: 4 +  1 - 1 =  4 = row 0 cell 4.

(ert-deftest taskjuggler-mode-cal-week-lines--selected-day-face ()
  "The selected day carries `taskjuggler-mode-cal-selected-face'."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
    (should (eq 'taskjuggler-mode-cal-selected-face (test-tj--cell-face weeks 2 4)))))
(ert-deftest taskjuggler-mode-cal-week-lines--today-face ()
  "Today's date (when not the selected day) carries `taskjuggler-mode-cal-today-face'."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2024 2 10)))
    (should (eq 'taskjuggler-mode-cal-today-face (test-tj--cell-face weeks 1 6)))))
(ert-deftest taskjuggler-mode-cal-week-lines--regular-day-face ()
  "A day that is neither selected nor today carries `taskjuggler-mode-cal-face'."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
    ;; Feb 1 is row 0 cell 4 — neither selected (15) nor today.
    (should (eq 'taskjuggler-mode-cal-face (test-tj--cell-face weeks 0 4)))))
(ert-deftest taskjuggler-mode-cal-week-lines--selected-overrides-today ()
  "When selected and today are the same day, selected face takes priority.
The cond checks `= d selected-day' before `= d today-day'."
  (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2024 2 15)))
    (should (eq 'taskjuggler-mode-cal-selected-face (test-tj--cell-face weeks 2 4)))))
;; --- taskjuggler-mode--cal-title-line ---

(ert-deftest taskjuggler-mode-cal-title-line--format ()
  "Returns `Month YEAR' for any month/year combination."
  (should (equal "February 2024" (taskjuggler-mode--cal-title-line 2024 2)))
  (should (equal "January 2025"  (taskjuggler-mode--cal-title-line 2025 1)))
  (should (equal "December 1999" (taskjuggler-mode--cal-title-line 1999 12))))
;; --- taskjuggler-mode--cal-render ---

(ert-deftest taskjuggler-mode-cal-render--line-count ()
  "cal-render returns 2 header lines plus one line per week row.
February 2024 has 5 week rows, so 7 lines total."
  (let ((lines (taskjuggler-mode--cal-render 2024 2 15)))
    (should (= 7 (length lines)))))
(ert-deftest taskjuggler-mode-cal-render--title-in-first-line ()
  "The first line contains the month name and year."
  (let ((lines (taskjuggler-mode--cal-render 2024 2 15)))
    (should (string-match-p "February" (substring-no-properties (nth 0 lines))))
    (should (string-match-p "2024"     (substring-no-properties (nth 0 lines))))))
(ert-deftest taskjuggler-mode-cal-render--all-lines-have-cal-width ()
  "Every line from cal-render is exactly `taskjuggler-mode--cal-width' characters wide."
  (let ((lines (taskjuggler-mode--cal-render 2024 2 15)))
    (dolist (line lines)
      (should (= taskjuggler-mode--cal-width
                 (length (substring-no-properties line)))))))
;;; taskjuggler-mode-cal-show-week-numbers

;; All tests in this section bind `taskjuggler-mode-cal-show-week-numbers' explicitly
;; so they are independent of the user's configuration.

;; --- nil (default) ---

(ert-deftest taskjuggler-mode-cal-week-numbers--nil-render-width ()
  "With show-week-numbers nil, every rendered line is exactly 22 chars wide."
  (let ((taskjuggler-mode-cal-show-week-numbers nil))
    (dolist (line (taskjuggler-mode--cal-render 2024 2 15))
      (should (= 22 (length (substring-no-properties line)))))))
(ert-deftest taskjuggler-mode-cal-week-numbers--nil-no-ww-prefix ()
  "With show-week-numbers nil, no week row starts with \"WW\"."
  (let ((taskjuggler-mode-cal-show-week-numbers nil))
    (dolist (row (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1))
      (should-not (string-prefix-p "WW" (substring-no-properties row))))))
(ert-deftest taskjuggler-mode-cal-week-numbers--nil-day-header-starts-with-space ()
  "With show-week-numbers nil, the day-header line (index 1) starts with \" Su\"."
  (let ((taskjuggler-mode-cal-show-week-numbers nil))
    (let ((hdr (substring-no-properties (nth 1 (taskjuggler-mode--cal-render 2024 2 15)))))
      (should (string-prefix-p " Su" hdr)))))
;; --- t ---

(ert-deftest taskjuggler-mode-cal-week-numbers--t-render-width ()
  "With show-week-numbers t, every rendered line is exactly 26 chars wide.
The base width is 22; the WW label (\"WW%02d\") adds 4 chars, making 26."
  (let ((taskjuggler-mode-cal-show-week-numbers t))
    (dolist (line (taskjuggler-mode--cal-render 2024 2 15))
      (should (= 26 (length (substring-no-properties line)))))))
(ert-deftest taskjuggler-mode-cal-week-numbers--t-ww-prefix ()
  "With show-week-numbers t, every week row starts with \"WW\"."
  (let ((taskjuggler-mode-cal-show-week-numbers t))
    (dolist (row (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1))
      (should (string-prefix-p "WW" (substring-no-properties row))))))
(ert-deftest taskjuggler-mode-cal-week-numbers--t-ww-face ()
  "With show-week-numbers t, the \"WW\" label carries `taskjuggler-mode-cal-week-face'."
  (let ((taskjuggler-mode-cal-show-week-numbers t))
    (dolist (row (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1))
      (should (eq 'taskjuggler-mode-cal-week-face (get-text-property 0 'face row))))))
(ert-deftest taskjuggler-mode-cal-week-numbers--t-day-header-has-5-space-prefix ()
  "With show-week-numbers t, the day-header line (index 1) starts with 5 spaces."
  (let ((taskjuggler-mode-cal-show-week-numbers t))
    (let ((hdr (substring-no-properties (nth 1 (taskjuggler-mode--cal-render 2024 2 15)))))
      (should (string-prefix-p "     Su" hdr)))))
(ert-deftest taskjuggler-mode-cal-week-numbers--t-correct-iso-weeks ()
  "With show-week-numbers t, Feb 2024 rows show the correct ISO week labels.
Feb 2024 starts on Thursday (start-dow=4).  Thursday of each row:
  Row 0: Thu=Feb  1 → WW05
  Row 1: Thu=Feb  8 → WW06
  Row 2: Thu=Feb 15 → WW07
  Row 3: Thu=Feb 22 → WW08
  Row 4: Thu=Feb 29 → WW09"
  (let ((taskjuggler-mode-cal-show-week-numbers t))
    (let ((weeks (taskjuggler-mode--cal-week-lines 2024 2 15 2026 1 1)))
      (should (string-prefix-p "WW05" (substring-no-properties (nth 0 weeks))))
      (should (string-prefix-p "WW06" (substring-no-properties (nth 1 weeks))))
      (should (string-prefix-p "WW07" (substring-no-properties (nth 2 weeks))))
      (should (string-prefix-p "WW08" (substring-no-properties (nth 3 weeks))))
      (should (string-prefix-p "WW09" (substring-no-properties (nth 4 weeks)))))))
;;; taskjuggler-mode--partial-date-bounds-at-point

;; A partial date is any prefix of YYYY-MM-DD (1-9 chars) that is not a
;; complete date and is not followed by a character that makes it a duration
;; literal (letter) or a larger number (digit) or a float (decimal point).

(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--two-digit-year ()
  "Returns bounds for a 2-digit year prefix at point."
  (with-temp-buffer
    (insert "start 20 end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "20")
    (backward-char 1)                   ; point on "0"
    (let ((bounds (taskjuggler-mode--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "20"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--four-digit-year ()
  "Returns bounds for a standalone 4-digit year at point."
  (with-temp-buffer
    (insert "start 2026 end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026")
    (backward-char 1)                   ; point on last "6"
    (let ((bounds (taskjuggler-mode--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--year-with-dash ()
  "Returns bounds for YYYY- at point."
  (with-temp-buffer
    (insert "start 2026-\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-")
    (backward-char 1)                   ; point on "-"
    (let ((bounds (taskjuggler-mode--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026-"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--year-month ()
  "Returns bounds for YYYY-MM at point."
  (with-temp-buffer
    (insert "start 2026-04\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-04")
    (backward-char 1)
    (let ((bounds (taskjuggler-mode--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026-04"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--year-month-dash ()
  "Returns bounds for YYYY-MM- at point."
  (with-temp-buffer
    (insert "start 2026-04-\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-04-")
    (backward-char 1)
    (let ((bounds (taskjuggler-mode--partial-date-bounds-at-point)))
      (should bounds)
      (should (equal "2026-04-"
                     (buffer-substring-no-properties
                      (car bounds) (cdr bounds)))))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--complete-date-excluded ()
  "Returns nil for a complete date (handled by taskjuggler-mode--date-bounds-at-point)."
  (with-temp-buffer
    (insert "start 2026-04-07\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026")
    (should (null (taskjuggler-mode--partial-date-bounds-at-point)))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--duration-excluded ()
  "Returns nil when the digit sequence is immediately followed by a letter."
  ;; \"5d\" — the \"5\" is followed by \"d\", so it must not be matched.
  (with-temp-buffer
    (insert "length 5d\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "5")
    (backward-char 1)
    (should (null (taskjuggler-mode--partial-date-bounds-at-point)))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--float-excluded ()
  "Returns nil when the digit sequence is followed by a decimal point."
  ;; \"2.5\" — the \"2\" is followed by \".\", so it must not be matched.
  (with-temp-buffer
    (insert "effort 2.5h\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2")
    (backward-char 1)
    (should (null (taskjuggler-mode--partial-date-bounds-at-point)))))
(ert-deftest taskjuggler-mode-partial-date-bounds-at-point--non-numeric-text ()
  "Returns nil when point is on non-numeric text."
  (with-temp-buffer
    (insert "task foo\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "foo")
    (backward-char 1)
    (should (null (taskjuggler-mode--partial-date-bounds-at-point)))))
;;; taskjuggler-mode--parse-partial-date

(ert-deftest taskjuggler-mode-parse-partial-date--empty-uses-defaults ()
  "An empty prefix leaves all components at the default values."
  (should (equal '(2026 4 7)
                 (taskjuggler-mode--parse-partial-date "" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--two-digit-year-uses-default ()
  "A 2-digit prefix is too short to parse the year; defaults are used."
  (should (equal '(2026 4 7)
                 (taskjuggler-mode--parse-partial-date "20" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--four-digit-year ()
  "Four typed digits set the year; month and day come from the default."
  (should (equal '(2025 4 7)
                 (taskjuggler-mode--parse-partial-date "2025" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--year-with-dash ()
  "YYYY- (5 chars) sets the year; month and day come from the default."
  (should (equal '(2025 4 7)
                 (taskjuggler-mode--parse-partial-date "2025-" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--year-and-month ()
  "YYYY-MM sets year and month; day comes from the default."
  (should (equal '(2025 3 7)
                 (taskjuggler-mode--parse-partial-date "2025-03" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--year-and-single-digit-month ()
  "YYYY-M (1-digit month) sets year and month; day comes from the default."
  (should (equal '(2026 4 7)
                 (taskjuggler-mode--parse-partial-date "2026-4" '(2026 1 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--full-ten-chars ()
  "All 10 characters set year, month, and day."
  (should (equal '(2025 3 20)
                 (taskjuggler-mode--parse-partial-date "2025-03-20" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--invalid-month-ignored ()
  "An invalid month value (e.g. 13) leaves the month at the default."
  (should (equal '(2025 4 7)
                 (taskjuggler-mode--parse-partial-date "2025-13" '(2026 4 7)))))
(ert-deftest taskjuggler-mode-parse-partial-date--day-clamped-to-month ()
  "When the default day exceeds the days in the parsed month, it is clamped."
  ;; Default day=31, but February 2025 only has 28 days.
  (should (equal '(2025 2 28)
                 (taskjuggler-mode--parse-partial-date "2025-02" '(2026 4 31)))))
;;; taskjuggler-mode--cal-expand-tabs-with-props

(ert-deftest taskjuggler-mode-cal-expand-tabs--no-tabs ()
  "A string without tabs is returned unchanged."
  (let ((tab-width 8))
    (should (equal "abcdef" (taskjuggler-mode--cal-expand-tabs-with-props "abcdef")))))
(ert-deftest taskjuggler-mode-cal-expand-tabs--tab-at-start ()
  "A leading tab expands to tab-width spaces."
  (let ((tab-width 8))
    (should (equal "        rest"
                   (taskjuggler-mode--cal-expand-tabs-with-props "\trest")))))
(ert-deftest taskjuggler-mode-cal-expand-tabs--tab-after-chars ()
  "A tab after N chars expands to (tab-width - N % tab-width) spaces."
  ;; \"abc\" is 3 chars; next tab stop at 8 requires 5 spaces.
  (let ((tab-width 8))
    (should (equal "abc     def"
                   (taskjuggler-mode--cal-expand-tabs-with-props "abc\tdef")))))
(ert-deftest taskjuggler-mode-cal-expand-tabs--two-tabs ()
  "Two leading tabs expand to 2*tab-width spaces."
  (let ((tab-width 8))
    (should (equal "                rest"
                   (taskjuggler-mode--cal-expand-tabs-with-props "\t\trest")))))
(ert-deftest taskjuggler-mode-cal-expand-tabs--tab-width-4 ()
  "Tab expansion respects a tab-width of 4."
  (let ((tab-width 4))
    (should (equal "    rest" (taskjuggler-mode--cal-expand-tabs-with-props "\trest")))))
;;; taskjuggler-mode--cal-splice-line (tab handling)

(ert-deftest taskjuggler-mode-cal-splice-line--tab-at-start-col-8 ()
  "A leading tab is expanded before splicing; col=8 places new text correctly."
  ;; The tab expands to 8 spaces; splicing at col 8 puts new text right after.
  (let ((tab-width 8))
    (should (equal (concat (make-string 8 ?\s) "CAL")
                   (taskjuggler-mode--cal-splice-line "\t" "CAL" 8)))))
(ert-deftest taskjuggler-mode-cal-splice-line--tab-mid-line ()
  "A tab in the middle of old is expanded before splicing."
  ;; \"abc\\tdef\" with tab-width=8: \"abc\" (3 chars) + tab expands to 5 spaces
  ;; (reaching column 8) + \"def\" = \"abc     def\" (11 chars).
  ;; Splicing \"CAL\" (len=3) at col=4: left=\"abc \" (cols 0-3),
  ;; right=old-vis[7..]=\" def\" (the trailing space of the tab expansion + \"def\").
  (let ((tab-width 8))
    (should (equal "abc CAL def"
                   (taskjuggler-mode--cal-splice-line "abc\tdef" "CAL" 4)))))
(ert-deftest taskjuggler-mode-cal-splice-line--tab-expanded-consistent-width ()
  "Lines with tabs produce the same calendar column as equivalent space lines."
  ;; A line \"\\tX\" with tab-width=8 expands to \"        X\" (9 chars).
  ;; A line with 8 spaces then X also has 9 chars.  Splicing at col 4
  ;; should yield identical results for both.
  (let ((tab-width 8))
    (should (equal (taskjuggler-mode--cal-splice-line "        X" "CAL" 4)
                   (taskjuggler-mode--cal-splice-line "\tX" "CAL" 4)))))
(ert-deftest taskjuggler-mode-cal-splice-line--preserves-text-properties ()
  "Text properties on the OLD string are preserved in the output."
  (let* ((old (propertize "leftXXXright" 'face 'font-lock-keyword-face))
         (result (taskjuggler-mode--cal-splice-line old "CAL" 4)))
    ;; The left portion "left" should still carry the face property.
    (should (equal 'font-lock-keyword-face
                   (get-text-property 0 'face result)))
    ;; The right portion starting at col 7 ("right") should also have it.
    (should (equal 'font-lock-keyword-face
                   (get-text-property 7 'face result)))))
(ert-deftest taskjuggler-mode-date-dwim--complete-date-edits-in-place ()
  "On a complete date, opens the calendar for that date with was-inserted=nil."
  (with-temp-buffer
    (insert "start 2026-04-07 end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026")
    (backward-char 1)                   ; point on "2"
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 1 1 2025 1 nil 0)
                      (taskjuggler-mode-date-dwim))))
      (should cal-args)
      (should (equal (list 2026 4 7 nil) (cdr cal-args)))
      ;; date-beg points at the "2" of "2026-04-07"
      (should (equal "2026-04-07"
                     (buffer-substring-no-properties
                      (car cal-args) (+ (car cal-args) 10)))))))
(ert-deftest taskjuggler-mode-date-dwim--partial-date-seeds-calendar ()
  "On a partial date, replaces it with a full date and seeds the calendar."
  ;; Partial \"2026-04-\": year=2026, month=4, day falls back to default (15).
  (with-temp-buffer
    (insert "start 2026-04- end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "2026-04-")
    (backward-char 1)                   ; point on trailing "-"
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 15 6 2025 1 nil 0)
                      (taskjuggler-mode-date-dwim))))
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
(ert-deftest taskjuggler-mode-date-dwim--eol-inserts-new-date ()
  "At end of line, inserts today's date and opens the calendar picker."
  (with-temp-buffer
    (insert "start ")
    (taskjuggler-mode)
    ;; Point is at end of buffer, which satisfies (eolp).
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 15 6 2025 1 nil 0)
                      (taskjuggler-mode-date-dwim))))
      (should cal-args)
      (should (equal (list 2025 6 15 t) (cdr cal-args)))
      (let ((date-beg (car cal-args)))
        (should (equal "2025-06-15"
                       (buffer-substring-no-properties
                        date-beg (+ date-beg 10))))))))
(ert-deftest taskjuggler-mode-date-dwim--whitespace-inserts-new-date ()
  "On a whitespace character, inserts today's date and opens the calendar picker."
  (with-temp-buffer
    (insert "start  end\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "start ")
    ;; Point is now on the second space, satisfying (looking-at-p \"[ \\t]\").
    (let ((cal-args (with-cal-edit-stubbed '(0 0 0 15 6 2025 1 nil 0)
                      (taskjuggler-mode-date-dwim))))
      (should cal-args)
      (should (equal (list 2025 6 15 t) (cdr cal-args))))))
(ert-deftest taskjuggler-mode-date-dwim--non-date-text-signals-error ()
  "On non-date, non-whitespace text, signals a user-error."
  (with-temp-buffer
    (insert "task foo\n")
    (taskjuggler-mode)
    (goto-char (point-min))
    (re-search-forward "foo")
    (backward-char 1)                   ; point on "f"
    (should-error (taskjuggler-mode-date-dwim) :type 'user-error)))
;;; Calendar picker

;; ---- Clamp day ----

(ert-deftest tj-cal-clamp-day ()
  "Test day clamping to month bounds."
  (should (= 28 (taskjuggler-mode--cal-clamp-day 2023 2 31)))
  (should (= 29 (taskjuggler-mode--cal-clamp-day 2024 2 31)))
  (should (= 15 (taskjuggler-mode--cal-clamp-day 2024 3 15)))
  (should (= 30 (taskjuggler-mode--cal-clamp-day 2024 4 31))))
;; ---- Date adjustment ----

(ert-deftest tj-cal-adjust-day ()
  "Test day-level adjustment, including month/year wrapping."
  (should (equal '(2024 1 2) (taskjuggler-mode--cal-adjust-date 2024 1 1 1 :day)))
  (should (equal '(2023 12 31) (taskjuggler-mode--cal-adjust-date 2024 1 1 -1 :day)))
  (should (equal '(2024 2 1) (taskjuggler-mode--cal-adjust-date 2024 1 31 1 :day)))
  (should (equal '(2024 3 1) (taskjuggler-mode--cal-adjust-date 2024 2 29 1 :day))))
(ert-deftest tj-cal-adjust-week ()
  "Test week-level adjustment."
  (should (equal '(2024 1 8) (taskjuggler-mode--cal-adjust-date 2024 1 1 1 :week)))
  (should (equal '(2023 12 25) (taskjuggler-mode--cal-adjust-date 2024 1 1 -1 :week))))
(ert-deftest tj-cal-adjust-month ()
  "Test month-level adjustment, including day clamping and year wrapping."
  (should (equal '(2024 2 15) (taskjuggler-mode--cal-adjust-date 2024 1 15 1 :month)))
  ;; Jan 31 + 1 month = Feb 29 (2024 is leap).
  (should (equal '(2024 2 29) (taskjuggler-mode--cal-adjust-date 2024 1 31 1 :month)))
  ;; Jan 31 + 1 month in non-leap year = Feb 28.
  (should (equal '(2023 2 28) (taskjuggler-mode--cal-adjust-date 2023 1 31 1 :month)))
  ;; Dec + 1 month = Jan next year.
  (should (equal '(2025 1 15) (taskjuggler-mode--cal-adjust-date 2024 12 15 1 :month)))
  ;; Jan - 1 month = Dec previous year.
  (should (equal '(2023 12 15) (taskjuggler-mode--cal-adjust-date 2024 1 15 -1 :month))))
;; ---- TJ date parsing ----

(ert-deftest tj-cal-parse-tj-date ()
  "Test parsing TJ3 date strings."
  (should (equal '(2024 3 15) (taskjuggler-mode--parse-tj-date "2024-03-15")))
  (should (equal '(2024 3 15) (taskjuggler-mode--parse-tj-date "2024-03-15-10:30")))
  (should (equal '(2024 3 15) (taskjuggler-mode--parse-tj-date "2024-03-15-10:30:45")))
  (should-not (taskjuggler-mode--parse-tj-date "not-a-date")))
;; ---- TJ date formatting ----

(ert-deftest tj-cal-format-tj-date ()
  "Test formatting year/month/day into TJ3 date string."
  (should (equal "2024-03-15" (taskjuggler-mode--format-tj-date 2024 3 15)))
  (should (equal "2024-01-01" (taskjuggler-mode--format-tj-date 2024 1 1))))
;; ---- Typed prefix parsing ----

(ert-deftest tj-cal-parse-typed-prefix-year ()
  "Test parsing after the year portion is typed."
  (with-temp-buffer
    (insert "2025-04-01")
    ;; 4 chars typed → year parsed, month/day from default.
    (should (equal '(2025 3 15)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 4 '(2024 3 15))))
    ;; 7 chars typed → year and month parsed.
    (should (equal '(2025 4 15)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 7 '(2024 3 15))))
    ;; 10 chars typed → full date.
    (should (equal '(2025 4 1)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 10 '(2024 3 15))))))
(ert-deftest tj-cal-parse-typed-prefix-clamps-day ()
  "Test that day is clamped when month changes."
  (with-temp-buffer
    ;; Feb has 28 days in 2025, default day=31 should clamp.
    (insert "2025-02-28")
    (should (equal '(2025 2 28)
                   (taskjuggler-mode--cal-parse-typed-prefix 1 7 '(2025 1 31))))))
(ert-deftest tj-cal-valid-char-at-p ()
  "Test character validation at each position."
  ;; Digits at non-hyphen positions.
  (should (taskjuggler-mode--cal-valid-char-at-p ?2 0))
  (should (taskjuggler-mode--cal-valid-char-at-p ?0 3))
  ;; Hyphens at positions 4 and 7.
  (should (taskjuggler-mode--cal-valid-char-at-p ?- 4))
  (should (taskjuggler-mode--cal-valid-char-at-p ?- 7))
  ;; Digits not valid at hyphen positions.
  (should-not (taskjuggler-mode--cal-valid-char-at-p ?1 4))
  ;; Hyphens not valid at digit positions.
  (should-not (taskjuggler-mode--cal-valid-char-at-p ?- 0)))
;; ---- Face application ----

(ert-deftest tj-cal-apply-faces ()
  "Test that typing and pending faces are applied correctly."
  (with-temp-buffer
    (insert "2024-03-15")
    (taskjuggler-mode--cal-apply-faces 1 4)
    ;; First 4 chars should have typing face (applied via overlays).
    (should (eq 'taskjuggler-mode-cal-typing-face
                (get-char-property 1 'face)))
    ;; Remaining chars should have pending face.
    (should (eq 'taskjuggler-mode-cal-pending-face
                (get-char-property 5 'face)))
    ;; Remove faces.
    (taskjuggler-mode--cal-remove-faces 1)
    (should-not (get-char-property 1 'face))
    (should-not (get-char-property 5 'face))))
;; ---- Calendar rendering ----

(ert-deftest tj-cal-render-returns-list ()
  "Test that render returns a list of strings with expected structure."
  (let ((lines (taskjuggler-mode--cal-render 2026 3 1)))
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
  (let* ((lines (taskjuggler-mode--cal-render 2024 1 15))
         (all (mapconcat #'identity lines "\n"))
         ;; Find "15" in the output.
         (pos (string-match "15" all)))
    (should pos)
    (should (eq 'taskjuggler-mode-cal-selected-face (get-text-property pos 'face all)))))
(ert-deftest tj-cal-render-inactive-days ()
  "Test that prev/next month fill days have the inactive face."
  ;; March 2026 starts on Sunday — no leading inactive days.
  ;; It has 31 days, and the grid has 5 weeks (35 cells), so 4 trailing.
  (let* ((lines (taskjuggler-mode--cal-render 2026 3 15))
         (last-week (substring-no-properties (car (last lines)))))
    ;; Last week should contain days 1-4 from April (inactive).
    (should (string-match-p " 1" last-week))
    ;; Check the face on a trailing day.
    (let* ((last-line (car (last lines)))
           (pos (string-match " 1" last-line)))
      ;; The "1" character (pos+1) should have inactive face.
      (should (eq 'taskjuggler-mode-cal-inactive-face
                  (get-text-property (1+ pos) 'face last-line))))))
(ert-deftest tj-cal-render-leading-inactive ()
  "Test that leading days from the previous month are shown."
  ;; Feb 2026 starts on Sunday — no leading days.
  ;; Jan 2026 starts on Thursday (dow=4) — 4 leading days from Dec 2025.
  (let* ((lines (taskjuggler-mode--cal-render 2026 1 10))
         (first-week (substring-no-properties (nth 2 lines))))
    ;; First week row should start with Dec 28 (Sun), 29, 30, 31.
    (should (string-match-p "28" first-week))
    (should (string-match-p "31" first-week))))
(ert-deftest tj-cal-render-consistent-width ()
  "Test that all lines have the same width."
  (let* ((lines (taskjuggler-mode--cal-render 2026 3 15))
         (widths (mapcar #'length lines)))
    (should (= 1 (length (delete-dups widths))))))
;; ---- Line splicing ----

(ert-deftest tj-cal-splice-line-middle ()
  "Test splicing calendar content into the middle of a line."
  (should (equal "abcXXXghi"
                 (taskjuggler-mode--cal-splice-line "abcdefghi" "XXX" 3))))
(ert-deftest tj-cal-splice-line-short ()
  "Test splicing when the original line is shorter than the column."
  (should (equal "ab   XXX"
                 (taskjuggler-mode--cal-splice-line "ab" "XXX" 5))))
(ert-deftest tj-cal-splice-line-at-start ()
  "Test splicing at column 0."
  (should (equal "XXXdefghi"
                 (taskjuggler-mode--cal-splice-line "abcdefghi" "XXX" 0))))
(ert-deftest tj-cal-splice-line-past-end ()
  "Test splicing when content extends past the end of the original line."
  (should (equal "abcXXXXX"
                 (taskjuggler-mode--cal-splice-line "abcde" "XXXXX" 3))))
;; ---- Integration: date-bounds-at-point ----

(ert-deftest tj-cal-date-bounds-at-point ()
  "Test finding date bounds in a buffer."
  (with-temp-buffer
    (insert "start 2024-03-15\n")
    (goto-char (+ 7 (point-min)))  ; position within the date
    (let ((bounds (taskjuggler-mode--date-bounds-at-point)))
      (should bounds)
      (should (equal "2024-03-15"
                     (buffer-substring-no-properties (car bounds) (cdr bounds)))))))
(ert-deftest tj-cal-date-bounds-at-point-none ()
  "Test that nil is returned when not on a date."
  (with-temp-buffer
    (insert "start foo\n")
    (goto-char (+ 7 (point-min)))
    (should-not (taskjuggler-mode--date-bounds-at-point))))

(provide 'taskjuggler-mode-cal-test)

;;; taskjuggler-mode-cal-test.el ends here
