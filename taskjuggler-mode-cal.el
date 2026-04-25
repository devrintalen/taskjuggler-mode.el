;;; taskjuggler-mode-cal.el --- Inline calendar picker for taskjuggler-mode -*- lexical-binding: t -*-

;; Copyright (C) 2025 Devrin Talen <devrin@fastmail.com>

;; Author: Devrin Talen <devrin@fastmail.com>
;; Keywords: languages, project-management
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Inline overlay calendar for editing TJ3 date literals.  Loaded from
;; `taskjuggler-mode'; not intended for direct use.

;;; Code:

(require 'calendar)

;; Symbols defined in `taskjuggler-mode' proper.  Forward-declared so
;; this file byte-compiles cleanly in isolation.
(defvar taskjuggler--date-re)
(defvar taskjuggler-cal-show-week-numbers)
(defvar taskjuggler-auto-cal-on-date-keyword)

;;; Date insertion — inline calendar picker

(defun taskjuggler--date-bounds-at-point ()
  "Return (BEG . END) of the TJ3 date literal at point, or nil."
  (save-excursion
    (let ((pos (point))
          (bol (line-beginning-position))
          (eol (line-end-position)))
      (goto-char bol)
      (catch 'found
        (while (re-search-forward taskjuggler--date-re eol t)
          (when (and (<= (match-beginning 0) pos)
                     (>= (match-end 0) pos))
            (throw 'found (cons (match-beginning 0) (match-end 0)))))))))

(defconst taskjuggler--partial-date-re
  "[0-9]\\{1,4\\}\\(?:-[0-9]\\{0,2\\}\\(?:-[0-9]\\{0,2\\}\\)?\\)?"
  "Regexp matching any prefix of YYYY-MM-DD.
Matches 1-4 year digits optionally followed by a hyphen + 0-2 month
digits + an optional hyphen + 0-2 day digits.")

(defun taskjuggler--partial-date-bounds-at-point ()
  "Return (BEG . END) of a partial date prefix at point, or nil.
Matches any prefix of YYYY-MM-DD (1-9 characters) that contains point
and is not a complete date.  Excludes numeric tokens followed by a digit,
letter, or decimal point to avoid matching durations (e.g. \"5d\") or
larger numbers."
  (save-excursion
    (let ((pos (point))
          (bol (line-beginning-position))
          (eol (line-end-position)))
      (goto-char bol)
      (catch 'found
        (while (re-search-forward taskjuggler--partial-date-re eol t)
          (let ((mbeg (match-beginning 0))
                (mend (match-end 0))
                (mstr (match-string 0)))
            (when (and (<= mbeg pos) (>= mend pos))
              (unless (string-match-p (concat "^" taskjuggler--date-re "$") mstr)
                ;; The regexp can match bare digits (e.g. the "5" in "5d").
                ;; The next-char guard below is what excludes those cases:
                ;; a match immediately followed by a digit, letter, or "."
                ;; is not a partial date.
                (let ((next (and (< mend eol) (char-after mend))))
                  (unless (and next (or (<= ?0 next ?9)
                                        (<= ?a next ?z)
                                        (<= ?A next ?Z)
                                        (= next ?.)))
                    (throw 'found (cons mbeg mend))))))))))))

(defun taskjuggler--parse-partial-date (partial default-date)
  "Parse PARTIAL date prefix string and return (YEAR MONTH DAY).
PARTIAL is a prefix of YYYY-MM-DD; month and day components may be 1 or 2
digits.  Uses DEFAULT-DATE (a (YEAR MONTH DAY) list) for any components not
present in PARTIAL."
  (let* ((year (nth 0 default-date))
         (month (nth 1 default-date))
         (day (nth 2 default-date))
         (parts (split-string partial "-")))
    ;; Year: must be exactly 4 digits.
    (let ((y-str (nth 0 parts)))
      (when (and y-str (= (length y-str) 4))
        (let ((y (string-to-number y-str)))
          (when (> y 0) (setq year y)))))
    ;; Month: 1 or 2 digits, value 1-12.
    (when-let ((m-str (nth 1 parts)))
      (when (>= (length m-str) 1)
        (let ((m (string-to-number m-str)))
          (when (<= 1 m 12) (setq month m)))))
    ;; Day: 1 or 2 digits, clamped to the parsed month.
    (when-let ((d-str (nth 2 parts)))
      (when (>= (length d-str) 1)
        (let ((d (string-to-number d-str)))
          (when (>= d 1)
            (setq day (min d (calendar-last-day-of-month month year)))))))
    (list year month (taskjuggler--cal-clamp-day year month day))))

(defun taskjuggler--parse-tj-date (date-string)
  "Parse TJ3 DATE-STRING into a (YEAR MONTH DAY) list.
Handles YYYY-MM-DD and YYYY-MM-DD-HH:MM[:SS] formats."
  (when (string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
                      date-string)
    (list (string-to-number (match-string 1 date-string))
          (string-to-number (match-string 2 date-string))
          (string-to-number (match-string 3 date-string)))))

(defun taskjuggler--format-tj-date (year month day)
  "Format YEAR, MONTH, DAY as a TJ3 date string YYYY-MM-DD."
  (format "%04d-%02d-%02d" year month day))

;; --- Calendar math ---
;; `calendar-leap-year-p', `calendar-last-day-of-month', and
;; `calendar-day-of-week' come from the built-in `calendar' library.

(defun taskjuggler--cal-clamp-day (year month day)
  "Clamp DAY to the valid range for MONTH of YEAR."
  (min day (calendar-last-day-of-month month year)))

(defun taskjuggler--cal-adjust-date (year month day delta unit)
  "Adjust YEAR-MONTH-DAY by DELTA units (:day, :week, or :month).
Return a (YEAR MONTH DAY) list."
  (pcase unit
    (:day
     (let* ((time (encode-time 0 0 12 day month year))
            (adjusted (time-add time (days-to-time delta)))
            (decoded (decode-time adjusted)))
       (list (nth 5 decoded) (nth 4 decoded) (nth 3 decoded))))
    (:week
     (taskjuggler--cal-adjust-date year month day (* delta 7) :day))
    (:month
     (let* ((new-month (+ month delta))
            ;; Normalise month to 1-12, adjusting year.
            (new-year (+ year (floor (1- new-month) 12)))
            (new-month (1+ (mod (1- new-month) 12)))
            (new-day (taskjuggler--cal-clamp-day new-year new-month day)))
       (list new-year new-month new-day)))))

;; --- Calendar rendering ---
;;
;; The calendar is rendered as a list of propertized strings (one per
;; line).  Each cell carries the appropriate face: header, selected,
;; today, inactive (prev/next month), or the base calendar face.
;; No box border is drawn; the face background provides the visual
;; container.

(defconst taskjuggler--cal-month-names
  ["January" "February" "March" "April" "May" "June"
   "July" "August" "September" "October" "November" "December"]
  "Month names for the calendar header.")

(defconst taskjuggler--cal-day-header " Su Mo Tu We Th Fr Sa "
  "Day-of-week header row for the calendar (22 chars, without week-number prefix).")

(defconst taskjuggler--cal-width 22
  "Base width of the calendar popup in characters (without week-number labels).
When `taskjuggler-cal-show-week-numbers' is non-nil, 5 additional characters
are prepended for the \"WW15 \" label.")

(defvar-local taskjuggler--cal-today nil
  "Today's date as (YEAR MONTH DAY), cached once per edit session.")

(defun taskjuggler--cal-render (year month day)
  "Render a calendar grid for MONTH of YEAR with DAY selected.
Return a list of propertized strings, one per line."
  (let* ((today (or taskjuggler--cal-today
                    (let ((now (decode-time)))
                      (list (nth 5 now) (nth 4 now) (nth 3 now)))))
         (today-year (nth 0 today))
         (today-month (nth 1 today))
         (today-day (nth 2 today))
         (title (taskjuggler--cal-pad-line
                 (taskjuggler--cal-title-line year month)))
         (day-hdr (if taskjuggler-cal-show-week-numbers
                      (concat "    " taskjuggler--cal-day-header)
                    taskjuggler--cal-day-header))
         (weeks (taskjuggler--cal-week-lines year month day
                                             today-year today-month today-day))
         (headers (list (propertize title 'face 'taskjuggler-cal-header-face)
                        (propertize day-hdr 'face 'taskjuggler-cal-header-face))))
    (append headers weeks)))

(defun taskjuggler--cal-title-line (year month)
  "Return the centred title string for MONTH of YEAR."
  (let ((name (aref taskjuggler--cal-month-names (1- month))))
    (format "%s %d" name year)))

(defun taskjuggler--cal-pad-line (text)
  "Pad or centre TEXT to the effective calendar width."
  (let* ((width (+ taskjuggler--cal-width
                   (if taskjuggler-cal-show-week-numbers 4 0)))
         (len (length text))
         (pad-total (max 0 (- width len)))
         (pad-left (/ pad-total 2))
         (pad-right (- pad-total pad-left)))
    (concat (make-string pad-left ?\s) text (make-string pad-right ?\s))))

(defun taskjuggler--cal-week-lines (year month selected-day
                                         today-year today-month today-day)
  "Return a list of propertized week-row strings for MONTH of YEAR.
SELECTED-DAY is highlighted.  TODAY-YEAR, TODAY-MONTH, TODAY-DAY
identify today's date for the today face.  Leading and trailing
cells are filled with days from adjacent months."
  (let* ((days-in-month (calendar-last-day-of-month month year))
         (start-dow (calendar-day-of-week (list month 1 year)))
         (cells '()))
    ;; Leading cells from the previous month.
    (when (> start-dow 0)
      (let* ((prev (taskjuggler--cal-adjust-date year month 1 -1 :month))
             (prev-year (nth 0 prev))
             (prev-month (nth 1 prev))
             (prev-dim (calendar-last-day-of-month prev-month prev-year))
             (first-prev (1+ (- prev-dim start-dow))))
        (dotimes (i start-dow)
          (push (taskjuggler--cal-make-cell
                 (+ first-prev i) 'taskjuggler-cal-inactive-face)
                cells))))
    ;; Days of the current month.
    (dotimes (i days-in-month)
      (let* ((d (1+ i))
             (face (cond
                    ((= d selected-day) 'taskjuggler-cal-selected-face)
                    ((and (= year today-year)
                          (= month today-month)
                          (= d today-day))
                     'taskjuggler-cal-today-face)
                    (t 'taskjuggler-cal-face))))
        (push (taskjuggler--cal-make-cell d face) cells)))
    ;; Trailing cells from the next month.
    (let ((trailing (% (length cells) 7)))
      (when (> trailing 0)
        (let ((need (- 7 trailing)))
          (dotimes (i need)
            (push (taskjuggler--cal-make-cell
                   (1+ i) 'taskjuggler-cal-inactive-face)
                  cells)))))
    ;; Group into weeks of 7 and format.
    ;; For each row, compute the ISO week number from the Thursday of that row.
    ;; Row i (0-indexed) starts on the Sunday at day (1 - start-dow + 7*i)
    ;; relative to the 1st of the month.  Thursday is 4 days later.
    (let ((all-cells (nreverse cells))
          (weeks '())
          (row '())
          (row-idx 0))
      (dolist (cell all-cells)
        (push cell row)
        (when (= (length row) 7)
          (let* ((thursday-rel (+ 1 (- start-dow) (* row-idx 7) 4))
                 (thu (taskjuggler--cal-adjust-date year month 1 (1- thursday-rel) :day))
                 (week-num (car (calendar-iso-from-absolute
                                (calendar-absolute-from-gregorian
                                 (list (nth 1 thu) (nth 2 thu) (nth 0 thu)))))))
            (push (taskjuggler--cal-format-week (nreverse row) week-num) weeks))
          (setq row nil)
          (setq row-idx (1+ row-idx))))
      (nreverse weeks))))

(defun taskjuggler--cal-make-cell (day face)
  "Return a propertized 2-character string for DAY with FACE."
  (propertize (format "%2d" day) 'face face))

(defun taskjuggler--cal-format-week (cells week-num)
  "Join a list of 7 propertized day CELLS into a single week-row string.
WEEK-NUM is the ISO week number; it is prepended as a \"WW%02d\" label when
`taskjuggler-cal-show-week-numbers' is non-nil.
Each cell is separated by a space with the base calendar face."
  (let* ((pad (propertize " " 'face 'taskjuggler-cal-face))
         (body (mapconcat #'identity cells pad)))
    (if taskjuggler-cal-show-week-numbers
        (let ((label (propertize (format "WW%02d" week-num)
                                 'face 'taskjuggler-cal-week-face)))
          (concat label pad body pad))
      (concat pad body pad))))

;; --- Overlay management ---
;;
;; Uses the same technique as company-mode's pseudo-tooltip: a single
;; overlay spans all lines the calendar covers.  The overlay's
;; `display' is set to "" to hide the real text, and `before-string'
;; carries the full popup as a single multi-line string where each
;; calendar row is spliced into the corresponding buffer line,
;; preserving characters to the left and right.

(defvar-local taskjuggler--cal-overlay nil
  "Overlay used by the inline calendar picker.")

(defvar-local taskjuggler--cal-typing-ov nil
  "Overlay for the user-typed portion of the date during calendar editing.")

(defvar-local taskjuggler--cal-pending-ov nil
  "Overlay for the pre-filled portion of the date during calendar editing.")

(defvar-local taskjuggler--cal-column nil
  "Column at which the calendar was first shown.
Captured once so the calendar stays anchored when navigating.")

;; --- Minor mode state ---
;;
;; These variables track the editing session while
;; `taskjuggler-cal-active-mode' is enabled.

(defvar-local taskjuggler--cal-date-beg nil
  "Buffer position where the date string starts during editing.")

(defvar-local taskjuggler--cal-was-inserted nil
  "Non-nil if the date was freshly inserted (should be deleted on cancel).")

(defvar-local taskjuggler--cal-orig-date nil
  "Original (YEAR MONTH DAY) before editing began.")

(defvar-local taskjuggler--cal-year nil
  "Current year displayed by the calendar picker.")

(defvar-local taskjuggler--cal-month nil
  "Current month displayed by the calendar picker.")

(defvar-local taskjuggler--cal-day nil
  "Current day displayed by the calendar picker.")

(defvar-local taskjuggler--cal-debounce-timer nil
  "Idle timer used to debounce calendar overlay updates.")

(defun taskjuggler--cal-expand-tabs-with-props (str)
  "Expand tabs in STR to spaces using `tab-width', preserving text properties.
Each space replacing a tab inherits the text properties of that tab character."
  (let ((parts '())
        (col 0))
    (dotimes (i (length str))
      (let ((ch (aref str i)))
        (if (= ch ?\t)
            (let* ((spaces (- tab-width (% col tab-width)))
                   (props (text-properties-at i str))
                   (pad (apply #'propertize (make-string spaces ?\s) props)))
              (push pad parts)
              (setq col (+ col spaces)))
          (push (substring str i (1+ i)) parts)
          (setq col (1+ col)))))
    (apply #'concat (nreverse parts))))

(defun taskjuggler--cal-splice-line (old new col)
  "Splice NEW into OLD at column COL, preserving surrounding text.
OLD is the original buffer line, NEW is the calendar row to insert.
Tab characters in OLD are expanded to spaces before slicing so that
COL is a visual column, not a character offset.  Text properties on
OLD (including font-lock faces) are preserved in the returned string.
Returns the combined string."
  (let* ((old-exp (taskjuggler--cal-expand-tabs-with-props old))
         (old-len (length old-exp))
         (new-len (length new))
         (left (if (<= col old-len)
                   (substring old-exp 0 col)
                 (concat old-exp (make-string (- col old-len) ?\s))))
         (right-start (+ col new-len))
         (right (if (< right-start old-len)
                    (substring old-exp right-start)
                  "")))
    (concat left new right)))

(defun taskjuggler--cal-build-display (cal-lines old-lines col)
  "Build the multi-line display string for the calendar popup.
CAL-LINES is a list of calendar row strings.  OLD-LINES is a list
of original buffer line strings.  COL is the column offset.
Returns a single string with embedded newlines."
  (let ((result '()))
    (while cal-lines
      (let* ((cal-line (pop cal-lines))
             (old-line (or (pop old-lines) ""))
             (spliced (taskjuggler--cal-splice-line old-line cal-line col)))
        (push spliced result)))
    (mapconcat #'identity (nreverse result) "\n")))

(defun taskjuggler--cal-show-overlay (year month day)
  "Display or update the calendar overlay below the current line.
The calendar is spliced into each line's display at the anchored
column, preserving buffer text to the left and right.  Shows MONTH
of YEAR with DAY highlighted.

On the first call the overlay is created; subsequent calls reuse it
and only update its `before-string'."
  (unless taskjuggler--cal-column
    (setq taskjuggler--cal-column (current-column)))
  (let* ((cal-lines (taskjuggler--cal-render year month day))
         (n-lines (length cal-lines))
         (col taskjuggler--cal-column))
    (save-excursion
      (forward-line 1)
      (let* ((beg (point))
             (old-lines (taskjuggler--cal-collect-lines n-lines))
             (end (point))
             (display-str (taskjuggler--cal-build-display
                           cal-lines old-lines col)))
        (if taskjuggler--cal-overlay
            ;; Reuse existing overlay — just update the display content.
            ;; Move it if the region changed (e.g. different week count).
            (progn
              (move-overlay taskjuggler--cal-overlay beg end)
              (overlay-put taskjuggler--cal-overlay
                           'before-string (concat display-str "\n")))
          ;; First call — create the overlay.
          (let ((ov (make-overlay beg end nil t)))
            (overlay-put ov 'display "")
            (overlay-put ov 'before-string (concat display-str "\n"))
            (overlay-put ov 'line-prefix "")
            (overlay-put ov 'window (selected-window))
            (overlay-put ov 'priority 111)
            (overlay-put ov 'taskjuggler-calendar t)
            (setq taskjuggler--cal-overlay ov)))))))

(defun taskjuggler--cal-collect-lines (n)
  "Collect N buffer lines starting from point, preserving text properties.
Advances point past the collected lines.  Returns a list of strings."
  (let ((lines '())
        (i 0))
    (while (and (< i n) (not (eobp)))
      (push (buffer-substring (line-beginning-position) (line-end-position))
            lines)
      (forward-line 1)
      (setq i (1+ i)))
    (nreverse lines)))

(defun taskjuggler--cal-remove-overlay ()
  "Remove the calendar overlay if it exists."
  (when taskjuggler--cal-overlay
    (delete-overlay taskjuggler--cal-overlay)
    (setq taskjuggler--cal-overlay nil)))

;; --- In-buffer date editing ---
;;
;; The date text lives in the buffer during editing.  A "typed-len"
;; counter tracks how many characters from the left the user has
;; explicitly typed (shown with `taskjuggler-cal-typing-face'); the
;; remainder uses `taskjuggler-cal-pending-face' to indicate the
;; pre-filled value that RET will commit.

(defconst taskjuggler--cal-date-len 10
  "Length of a YYYY-MM-DD date string.")

(defconst taskjuggler--cal-help-message
  "S-arrows: day/week  S-PgUp/Dn: month  Type: YYYY-MM-DD  RET/TAB: confirm  C-g: cancel"
  "Help text shown in the echo area during calendar editing.")

(defun taskjuggler--cal-valid-char-at-p (ch pos)
  "Return non-nil if CH is valid at position POS in a YYYY-MM-DD string."
  (if (or (= pos 4) (= pos 7))
      (= ch ?-)
    (<= ?0 ch ?9)))

(defun taskjuggler--cal-apply-faces (date-beg typed-len)
  "Apply typing and pending face overlays to the date string at DATE-BEG.
The first TYPED-LEN characters get the typing face; the rest get pending.
Overlays are used so font-lock cannot override them.  Existing overlays
are deleted and recreated on each call to avoid stale positions caused
by intervening buffer modifications."
  (let ((typed-end (+ date-beg typed-len))
        (date-end (+ date-beg taskjuggler--cal-date-len)))
    (when taskjuggler--cal-typing-ov
      (delete-overlay taskjuggler--cal-typing-ov)
      (setq taskjuggler--cal-typing-ov nil))
    (when taskjuggler--cal-pending-ov
      (delete-overlay taskjuggler--cal-pending-ov)
      (setq taskjuggler--cal-pending-ov nil))
    (when (> typed-len 0)
      (let ((ov (make-overlay date-beg typed-end)))
        (overlay-put ov 'face 'taskjuggler-cal-typing-face)
        (overlay-put ov 'priority 110)
        (setq taskjuggler--cal-typing-ov ov)))
    (when (< typed-len taskjuggler--cal-date-len)
      (let ((ov (make-overlay typed-end date-end)))
        (overlay-put ov 'face 'taskjuggler-cal-pending-face)
        (overlay-put ov 'priority 110)
        (setq taskjuggler--cal-pending-ov ov)))))

(defun taskjuggler--cal-remove-faces (_date-beg)
  "Remove the typing/pending face overlays."
  (when taskjuggler--cal-typing-ov
    (delete-overlay taskjuggler--cal-typing-ov)
    (setq taskjuggler--cal-typing-ov nil))
  (when taskjuggler--cal-pending-ov
    (delete-overlay taskjuggler--cal-pending-ov)
    (setq taskjuggler--cal-pending-ov nil)))

(defun taskjuggler--cal-update-prefill (date-beg typed-len year month day)
  "Update the pre-filled suffix of the date at DATE-BEG.
The first TYPED-LEN characters are left untouched.  The rest are
filled with the date formatted from YEAR, MONTH, and DAY."
  (let* ((full-date (taskjuggler--format-tj-date year month day))
         (suffix (substring full-date typed-len)))
    (save-excursion
      (goto-char (+ date-beg typed-len))
      (delete-char (length suffix))
      (insert suffix))))

(defun taskjuggler--cal-parse-typed-prefix (date-beg typed-len default-date)
  "Parse the typed prefix at DATE-BEG and return (YEAR MONTH DAY).
Uses DEFAULT-DATE (a (YEAR MONTH DAY) list) for components not yet
typed.  TYPED-LEN is how many characters have been typed so far."
  (let* ((year (nth 0 default-date))
         (month (nth 1 default-date))
         (day (nth 2 default-date))
         (typed (buffer-substring-no-properties
                 date-beg (+ date-beg typed-len))))
    (when (>= typed-len 4)
      (let ((y (string-to-number (substring typed 0 4))))
        (when (> y 0) (setq year y))))
    (when (>= typed-len 7)
      (let ((m (string-to-number (substring typed 5 7))))
        (when (<= 1 m 12) (setq month m))))
    (when (>= typed-len 10)
      (let ((d (string-to-number (substring typed 8 10))))
        (when (>= d 1)
          (setq day (min d (calendar-last-day-of-month month year))))))
    (list year month (taskjuggler--cal-clamp-day year month day))))

;; --- Minor mode for calendar editing ---
;;
;; Instead of a read-event loop, the calendar picker uses a transient
;; minor mode (like company-mode) with its own keymap for explicit
;; actions (commit, cancel, navigation) and a `post-command-hook' for
;; passive monitoring of point and typed text.

(defconst taskjuggler--cal-debounce-delay 0.05
  "Idle-timer delay (seconds) before refreshing the calendar overlay.")

(defun taskjuggler--cal-nav-delta (key)
  "Return (DELTA . UNIT) for a shift-arrow KEY."
  (pcase key
    ('S-right '(1 . :day))
    ('S-left  '(-1 . :day))
    ('S-down  '(1 . :week))
    ('S-up    '(-1 . :week))
    ('S-next  '(1 . :month))
    ('S-prior '(-1 . :month))))

(defun taskjuggler--cal-cleanup ()
  "Tear down calendar picker state and minor mode."
  (when taskjuggler--cal-debounce-timer
    (cancel-timer taskjuggler--cal-debounce-timer)
    (setq taskjuggler--cal-debounce-timer nil))
  (remove-hook 'post-command-hook #'taskjuggler--cal-post-command t)
  (remove-hook 'kill-buffer-hook #'taskjuggler--cal-cancel t)
  (taskjuggler--cal-remove-overlay)
  (taskjuggler--cal-remove-faces taskjuggler--cal-date-beg)
  (setq taskjuggler--cal-column nil
        taskjuggler--cal-today nil)
  (taskjuggler-cal-active-mode -1))

(defun taskjuggler--cal-commit ()
  "Commit the pending date and close the calendar picker."
  (interactive)
  (let ((date-beg taskjuggler--cal-date-beg)
        (year taskjuggler--cal-year)
        (month taskjuggler--cal-month)
        (day taskjuggler--cal-day))
    (taskjuggler--cal-cleanup)
    ;; Write the final date and move point past it.
    (save-excursion
      (goto-char date-beg)
      (delete-char taskjuggler--cal-date-len)
      (insert (taskjuggler--format-tj-date year month day)))
    (goto-char (+ date-beg taskjuggler--cal-date-len))))

(defun taskjuggler--cal-cancel ()
  "Cancel the calendar picker and restore the original buffer state."
  (interactive)
  (let ((date-beg taskjuggler--cal-date-beg)
        (was-inserted taskjuggler--cal-was-inserted)
        (orig-date taskjuggler--cal-orig-date))
    (taskjuggler--cal-cleanup)
    (if was-inserted
        ;; Date was freshly inserted — delete it entirely.
        (delete-region date-beg (+ date-beg taskjuggler--cal-date-len))
      ;; Date existed — restore the original text.
      (save-excursion
        (goto-char date-beg)
        (delete-char taskjuggler--cal-date-len)
        (insert (apply #'taskjuggler--format-tj-date orig-date))))))

(defun taskjuggler--cal-commit-or-cancel ()
  "Commit if a partial date has been typed, otherwise cancel.
Bound to SPC in the calendar picker."
  (interactive)
  (let* ((date-beg taskjuggler--cal-date-beg)
         (typed-len (- (point) date-beg)))
    (if (> typed-len 0)
        (taskjuggler--cal-commit)
      (taskjuggler--cal-cancel))))

(defun taskjuggler--cal-navigate (key)
  "Adjust the selected date by the shift-arrow KEY and refresh."
  (let* ((delta-unit (taskjuggler--cal-nav-delta key))
         (adjusted (taskjuggler--cal-adjust-date
                    taskjuggler--cal-year taskjuggler--cal-month
                    taskjuggler--cal-day
                    (car delta-unit) (cdr delta-unit))))
    (setq taskjuggler--cal-year (nth 0 adjusted)
          taskjuggler--cal-month (nth 1 adjusted)
          taskjuggler--cal-day (nth 2 adjusted))
    ;; Rewrite the full date template and move point back to date-beg.
    (let ((date-beg taskjuggler--cal-date-beg))
      (save-excursion
        (goto-char date-beg)
        (delete-char taskjuggler--cal-date-len)
        (insert (taskjuggler--format-tj-date
                 taskjuggler--cal-year taskjuggler--cal-month
                 taskjuggler--cal-day)))
      (goto-char date-beg)
      (taskjuggler--cal-apply-faces date-beg 0)
      (taskjuggler--cal-show-overlay
       taskjuggler--cal-year taskjuggler--cal-month
       taskjuggler--cal-day))))

(defun taskjuggler--cal-nav-right ()
  "Navigate calendar one day forward."
  (interactive)
  (taskjuggler--cal-navigate 'S-right))

(defun taskjuggler--cal-nav-left ()
  "Navigate calendar one day backward."
  (interactive)
  (taskjuggler--cal-navigate 'S-left))

(defun taskjuggler--cal-nav-down ()
  "Navigate calendar one week forward."
  (interactive)
  (taskjuggler--cal-navigate 'S-down))

(defun taskjuggler--cal-nav-up ()
  "Navigate calendar one week backward."
  (interactive)
  (taskjuggler--cal-navigate 'S-up))

(defun taskjuggler--cal-nav-next ()
  "Navigate calendar one month forward."
  (interactive)
  (taskjuggler--cal-navigate 'S-next))

(defun taskjuggler--cal-nav-prior ()
  "Navigate calendar one month backward."
  (interactive)
  (taskjuggler--cal-navigate 'S-prior))

(defun taskjuggler--cal-overwrite-char ()
  "Overwrite the template character at point with the typed character.
Used for digit and hyphen input during calendar date editing so that
`self-insert-command' does not grow the fixed-length date template."
  (interactive)
  (let* ((date-beg taskjuggler--cal-date-beg)
         (typed-len (- (point) date-beg))
         (ch last-command-event))
    (when (and (< typed-len taskjuggler--cal-date-len)
               (taskjuggler--cal-valid-char-at-p ch typed-len))
      (delete-char 1)
      (insert (char-to-string ch)))))

(defvar taskjuggler-cal-active-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<return>")  #'taskjuggler--cal-commit)
    (define-key map (kbd "<tab>")     #'taskjuggler--cal-commit)
    (define-key map (kbd "SPC")       #'taskjuggler--cal-commit-or-cancel)
    (define-key map (kbd "C-g")       #'taskjuggler--cal-cancel)
    (define-key map (kbd "S-<right>") #'taskjuggler--cal-nav-right)
    (define-key map (kbd "S-<left>")  #'taskjuggler--cal-nav-left)
    (define-key map (kbd "S-<down>")  #'taskjuggler--cal-nav-down)
    (define-key map (kbd "S-<up>")    #'taskjuggler--cal-nav-up)
    (define-key map (kbd "S-<next>")  #'taskjuggler--cal-nav-next)
    (define-key map (kbd "S-<prior>") #'taskjuggler--cal-nav-prior)
    ;; Digits and hyphen use overwrite-style insertion to keep the
    ;; date template at a fixed 10-character length.
    (dolist (ch (append (number-sequence ?0 ?9) (list ?-)))
      (define-key map (vector ch) #'taskjuggler--cal-overwrite-char))
    map)
  "Keymap active while the inline calendar picker is open.")

;; Register our keymap in `emulation-mode-map-alists' so it takes
;; priority over evil-mode's keymaps (which also live there).
;; The variable holds a (CONDITION . MAP) pair; we set CONDITION to t
;; while the picker is active and nil otherwise.
(defvar-local taskjuggler--cal-emulation-alist nil
  "Emulation keymap alist entry for the calendar picker.
Added to `emulation-mode-map-alists' so the picker keymap beats evil.")
(add-to-list 'emulation-mode-map-alists 'taskjuggler--cal-emulation-alist)

(define-minor-mode taskjuggler-cal-active-mode
  "Transient minor mode active while the inline calendar picker is open."
  :lighter " TJ-Cal"
  :keymap taskjuggler-cal-active-mode-map
  (if taskjuggler-cal-active-mode
      (progn
        (setq taskjuggler--cal-emulation-alist
              (list (cons t taskjuggler-cal-active-mode-map)))
        (message "%s" taskjuggler--cal-help-message))
    ;; Deactivate the emulation keymap and cancel any pending timer.
    (setq taskjuggler--cal-emulation-alist nil)
    (when taskjuggler--cal-debounce-timer
      (cancel-timer taskjuggler--cal-debounce-timer)
      (setq taskjuggler--cal-debounce-timer nil))))

;; --- Post-command monitoring ---

(defun taskjuggler--cal-schedule-refresh ()
  "Schedule a debounced calendar overlay refresh."
  (when taskjuggler--cal-debounce-timer
    (cancel-timer taskjuggler--cal-debounce-timer))
  (setq taskjuggler--cal-debounce-timer
        (run-with-idle-timer
         taskjuggler--cal-debounce-delay nil
         #'taskjuggler--cal-deferred-refresh (current-buffer))))

(defun taskjuggler--cal-deferred-refresh (buf)
  "Refresh the calendar overlay in BUF after the debounce delay."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when taskjuggler-cal-active-mode
        (setq taskjuggler--cal-debounce-timer nil)
        (taskjuggler--cal-show-overlay
         taskjuggler--cal-year taskjuggler--cal-month
         taskjuggler--cal-day)))))

(defun taskjuggler--cal-post-command ()
  "Monitor point and buffer text after each command.
Cancels the picker if point moves before `taskjuggler--cal-date-beg'.
Otherwise parses the typed prefix and updates faces and the overlay."
  (when taskjuggler-cal-active-mode
    (let ((date-beg taskjuggler--cal-date-beg)
          (date-end (+ taskjuggler--cal-date-beg taskjuggler--cal-date-len)))
      (cond
       ;; Point moved before the date region — cancel.
       ((< (point) date-beg)
        (taskjuggler--cal-cancel))
       ;; Point moved past the date region — cancel.
       ((> (point) date-end)
        (taskjuggler--cal-cancel))
       ;; Point is within the date region — parse and update.
       (t
        (let ((typed-len (- (point) date-beg)))
          (when (> typed-len 0)
            ;; Only parse the typed prefix when the user has actually
            ;; typed something.  When typed-len is 0 (e.g. after a
            ;; shift-arrow navigation command), the state variables and
            ;; buffer text are already correct — parsing with typed-len=0
            ;; would return orig-date and overwrite the navigated date.
            (let ((parsed (taskjuggler--cal-parse-typed-prefix
                           date-beg typed-len taskjuggler--cal-orig-date)))
              (setq taskjuggler--cal-year (nth 0 parsed)
                    taskjuggler--cal-month (nth 1 parsed)
                    taskjuggler--cal-day (nth 2 parsed))
              (taskjuggler--cal-update-prefill
               date-beg typed-len
               taskjuggler--cal-year taskjuggler--cal-month taskjuggler--cal-day)))
          (taskjuggler--cal-apply-faces date-beg typed-len)
          (taskjuggler--cal-schedule-refresh)))))))

;; --- Calendar edit entry point ---

(defun taskjuggler--cal-edit (date-beg year month day was-inserted)
  "Start the calendar picker for the date at DATE-BEG.
YEAR, MONTH, DAY are the initial date.  WAS-INSERTED is non-nil if
the date was freshly inserted (should be deleted on cancel).
Point must be at DATE-BEG on entry."
  ;; Cache today once so every render during this session is free.
  (let ((now (decode-time)))
    (setq taskjuggler--cal-today (list (nth 5 now) (nth 4 now) (nth 3 now))))
  ;; Store editing state.
  (setq taskjuggler--cal-date-beg date-beg
        taskjuggler--cal-was-inserted was-inserted
        taskjuggler--cal-orig-date (list year month day)
        taskjuggler--cal-year year
        taskjuggler--cal-month month
        taskjuggler--cal-day day)
  ;; Set up faces and overlay.
  (taskjuggler--cal-apply-faces date-beg 0)
  (taskjuggler--cal-show-overlay year month day)
  ;; Install hooks and activate the minor mode.
  (add-hook 'kill-buffer-hook #'taskjuggler--cal-cancel nil t)
  (add-hook 'post-command-hook #'taskjuggler--cal-post-command nil t)
  (taskjuggler-cal-active-mode 1))

;; --- Public date commands ---

(defun taskjuggler-insert-date ()
  "Insert a TaskJuggler date literal at point using an inline calendar.
Inserts today's date with a pending face and opens the calendar picker."
  (interactive)
  (pcase-let ((`(,_ ,_min ,_hour ,day ,month ,year . ,_) (decode-time)))
    (let ((date-beg (point)))
      (insert (taskjuggler--format-tj-date year month day))
      (goto-char date-beg)
      (taskjuggler--cal-edit date-beg year month day t))))

(defun taskjuggler-date-dwim ()
  "Insert or edit a TaskJuggler date literal depending on context.
If point is on a complete date literal, edit it in place.
If point is on a partial date prefix (e.g. \"2026-04-\"), delete it and open
the calendar picker to insert a fresh date.
If point is on whitespace or at end of line, insert a new date.
Otherwise, signal a user-error."
  (interactive)
  (let ((partial-bounds (taskjuggler--partial-date-bounds-at-point)))
    (cond
     ((taskjuggler--date-bounds-at-point)
      (taskjuggler-edit-date-at-point))
     (partial-bounds
      (let* ((partial (buffer-substring-no-properties (car partial-bounds) (cdr partial-bounds)))
             (partial-len (length partial)))
        (pcase-let ((`(,_ ,_min ,_hour ,today-day ,today-month ,today-year . ,_)
                     (decode-time)))
          (let* ((default-date (list today-year today-month today-day))
                 (parsed (taskjuggler--parse-partial-date partial default-date))
                 (year (nth 0 parsed))
                 (month (nth 1 parsed))
                 (day (nth 2 parsed)))
            (delete-region (car partial-bounds) (cdr partial-bounds))
            (goto-char (car partial-bounds))
            (let ((date-beg (point)))
              (insert (taskjuggler--format-tj-date year month day))
              (goto-char date-beg)
              (taskjuggler--cal-edit date-beg year month day t)
              ;; Position point after the typed prefix so post-command-hook
              ;; picks it up as typed-len = partial-len.
              (goto-char (+ date-beg partial-len)))))))
     ((or (eolp) (looking-at-p "[ \t]"))
      (taskjuggler-insert-date))
     (t
      (user-error "No date at point")))))

(defun taskjuggler-edit-date-at-point ()
  "Edit the TJ3 date literal at point using an inline calendar.
The existing date pre-fills the calendar."
  (interactive)
  (let ((bounds (taskjuggler--date-bounds-at-point)))
    (unless bounds
      (user-error "No TaskJuggler date at point"))
    (let* ((date-beg (car bounds))
           (old-string (buffer-substring-no-properties date-beg (cdr bounds)))
           (parsed (taskjuggler--parse-tj-date old-string)))
      (unless parsed
        (user-error "Cannot parse date: %s" old-string))
      (pcase-let ((`(,year ,month ,day) parsed))
        (goto-char date-beg)
        (taskjuggler--cal-edit date-beg year month day nil)))))

;;; Auto-launch calendar on date keywords

(defconst taskjuggler--date-keyword-list
  '("start" "end" "maxend" "maxstart" "minend" "minstart" "now")
  "Property keywords that expect a date literal to immediately follow them.
Used by `taskjuggler--maybe-launch-calendar' to trigger the inline calendar
picker automatically when `taskjuggler-auto-cal-on-date-keyword' is non-nil.")

(defconst taskjuggler--date-keyword-regexp
  (concat (regexp-opt taskjuggler--date-keyword-list 'words) "[ \t]")
  "Regexp matching a date keyword followed by a space or tab.
Pre-computed so `taskjuggler--maybe-launch-calendar' avoids rebuilding it on
every keystroke.")

(defun taskjuggler--maybe-launch-calendar ()
  "Auto-launch the calendar picker after typing a date keyword and a space.
Installed on `post-self-insert-hook'.  When
`taskjuggler-auto-cal-on-date-keyword' is non-nil and the calendar is not
already active, fires when the character just inserted is a space or tab
and the text immediately before it ends with a keyword from
`taskjuggler--date-keyword-list'.  Suppressed inside comments and strings."
  (when (and taskjuggler-auto-cal-on-date-keyword
             (not taskjuggler-cal-active-mode)
             (memq last-command-event '(?\s ?\t))
             (not (nth 8 (syntax-ppss)))
             (looking-back taskjuggler--date-keyword-regexp
                           (line-beginning-position)))
    (taskjuggler-insert-date)))

(provide 'taskjuggler-mode-cal)

;;; taskjuggler-mode-cal.el ends here
