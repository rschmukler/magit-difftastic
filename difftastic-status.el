;;; difftastic-status.el --- Difftastic-rendered, stageable sections in magit-status -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Ryan Schmukler

;; Author: Ryan Schmukler
;; URL: https://github.com/rschmukler/difftastic-status
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (magit "3.3.0") (difftastic "0.5.0"))
;; Keywords: tools, vc, git, diff

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:
;;
;; Render unstaged/staged changes in the `magit-status' buffer using
;; difftastic, while keeping them as collapsible, navigable Magit sections.
;;
;; The package provides `difftastic-status-mode', a global minor mode.  When
;; enabled it overrides Magit's stock unstaged/staged section inserters so the
;; status buffer shows difftastic-rendered, per-file, per-chunk sections, and
;; advises Magit's stage/unstage/discard/visit commands so they operate on the
;; difftastic chunk (or selected region) at point.  When the mode is off,
;; Magit's stock sections are used, so you can always fall back.
;;
;; Section visibility mirrors Magit: a file section starts collapsed in the
;; `magit-status' buffer (and for deleted files everywhere) and expanded in the
;; diff/revision buffers, while the per-chunk sections always start expanded --
;; so expanding a file reveals its hunk(s), the same way a single-hunk file
;; feels like it expands straight to its diff in stock Magit.
;;
;; The same difftastic chunks are also rendered in `magit-diff-mode' buffers --
;; which includes the diff Magit shows while you compose a commit message -- and
;; in `magit-revision-mode' buffers (viewing a commit), by advising Magit's
;; `magit-insert-diff'/`magit-insert-revision-diff'.  Per-chunk (and region)
;; staging is offered only where it is meaningful: the worktree (unstaged) and
;; `--cached' (staged) diffs.  Diffs that merely compare two revisions (a range
;; diff, or a commit being viewed) are rendered display-only.  These two
;; integrations can be scoped with `difftastic-status-diff-buffers' and
;; `difftastic-status-revision-buffers' (both default on); anything difftastic
;; cannot render -- `--no-index' diffs, merge commits shown as combined diffs --
;; falls straight back to Magit's stock rendering.
;;
;; Evil integration is optional and installed gracefully: if `evil' is present
;; the staging keys are bound in the relevant magit maps; if not, nothing is
;; assumed and the package works with stock Emacs keybindings.
;;
;; This package: per-file difftastic sections, split into collapsible per-chunk
;; sub-sections, with both FILE-LEVEL and PER-CHUNK staging.
;;
;;   Each changed file becomes a Magit `file' section.  Its body is the
;;   difftastic-rendered (inline display) diff, which we split on difftastic's
;;   own `FILE --- N/M --- LANG' chunk headers: those headers are dropped and
;;   each chunk becomes its own collapsible `difftastic-hunk' sub-section with a
;;   minimal, native-looking `@@ line N @@' heading.
;;
;;   On a FILE heading, Magit's commands work at the file level (stage/unstage
;;   via `magit-stage-1 "-u" FILE', purely filename-based):
;;
;;     s / u  -> stage / unstage the whole file
;;     TAB    -> collapse / expand the file (or, on a chunk heading, the chunk)
;;     RET    -> visit the file
;;
;;   On a CHUNK, the same keys act on just that chunk (see the "Per-chunk
;;   staging" section below for how this maps back onto real git hunks).  When
;;   a REGION is active within a chunk, they act on only the selected lines
;;   (see the "Region (line-range) staging" section):
;;
;;     s      -> stage this chunk's change(s) / the selected lines
;;     u      -> unstage this chunk's change(s) / the selected lines
;;     k      -> discard this chunk's worktree change(s) / the selected lines
;;     RET    -> visit the file
;;
;;   Chunk sub-sections are a CUSTOM type (`difftastic-hunk'), deliberately not
;;   Magit's real `hunk' type: real hunk sections trigger Magit's hunk paint
;;   method, which repaints lines by +/- detection and would clobber
;;   difftastic's colours.  Because the custom type is not one Magit's apply
;;   machinery understands -- and because evil-collection-magit makes
;;   `magit-mode-map' an overriding map so a section-keymap `[remap ...]' never
;;   wins -- per-chunk commands are wired by ADVISING the magit commands
;;   themselves (see the "Advice" commentary below), which is binding- and
;;   evil-state-agnostic.
;;
;; KNOWN LIMITATIONS:
;;   - Region staging operates within a single chunk at a time (the chunk at
;;     point); a region spanning multiple chunks/files only affects the chunk
;;     that contains it.  Whole-chunk staging snaps to the underlying git hunk
;;     boundary -- the same boundary Magit's own per-hunk staging uses.
;;   - `difft' is run synchronously, once per changed file, on every status
;;     refresh (plus one extra `difft --display json' per staging action).  On
;;     large change sets this can make `magit-status' sluggish.
;;   - Untracked files are still rendered by the stock
;;     `magit-insert-untracked-files'.
;;   - In `magit-diff-mode'/`magit-revision-mode' buffers the difftastic
;;     rendering replaces Magit's diff section wholesale, so the usual diffstat
;;     header is not shown there.  Merge commits (combined diffs) and
;;     `--no-index' diffs fall back to Magit's stock rendering.
;;
;; Toggle with `difftastic-status-mode' (global).  When off, Magit's
;; stock unstaged/staged sections are used, so you can always fall back.

;;; Code:

(require 'cl-lib)
(require 'magit)
(require 'difftastic)

(defgroup difftastic-status nil
  "Difftastic-rendered, stageable sections in `magit-status'."
  :group 'difftastic
  :group 'magit
  :prefix "difftastic-status-")

(defcustom difftastic-status-display "inline"
  "Value passed to difft's `--display'.
`inline' is strongly recommended: a single-column layout maps one screen
row to one logical diff line, which is what later steps need for
line-range staging.  `side-by-side' renders too, but its two-column
layout makes per-line mapping ambiguous."
  :type 'string
  :group 'difftastic-status)

(defcustom difftastic-status-chunk-heading-face 'magit-hash
  "Face used for the per-chunk `@@ line N @@' headings.
Defaults to `magit-hash' (the muted face Magit uses for commit hashes), to
keep the headings understated.  Set to any face you prefer, e.g.
`magit-section-heading' for a bolder look, `font-lock-comment-face' for
something comment-like, or `magit-diff-hunk-heading' for Magit's default
hunk-heading look."
  :type 'face
  :group 'difftastic-status)

(defun difftastic-status--width ()
  "Width (in columns) to request from difft for the status buffer."
  (max 40 (- (window-body-width (get-buffer-window (current-buffer) t)) 2)))

(defconst difftastic-status--diff-base '("--no-pager" "diff" "--ext-diff")
  "Leading git invocation for difftastic `git diff' rendering.
The diff selector (e.g. `--cached', a range) and the `-- FILE' pathspec are
appended to this.")

(defconst difftastic-status--show-base '("--no-pager" "show" "--ext-diff" "--format=")
  "Leading git invocation for difftastic `git show' (commit) rendering.
The revision and the `-- FILE' pathspec are appended to this.")

(defun difftastic-status--file-diff-string (file diff-args)
  "Return the difftastic-rendered, fontified diff STRING for FILE.
DIFF-ARGS is the leading git invocation (including `--no-pager', the
subcommand and `--ext-diff') that selects which diff to render; FILE is
appended as a pathspec.  For example, `(\"--no-pager\" \"diff\" \"--ext-diff\"
\"--cached\")' renders the index against HEAD, while
`(\"--no-pager\" \"show\" \"--ext-diff\" \"--format=\" REV)' renders a commit."
  (require 'difftastic)
  (let* ((width (difftastic-status--width))
         (args (append diff-args (list "--" file)))
         (raw (with-temp-buffer
                ;; `difftastic--build-git-process-environment' sets
                ;; GIT_EXTERNAL_DIFF=difft ... so plain `git diff --ext-diff'
                ;; routes through difftastic.  We append `--display inline'.
                (let ((process-environment
                       (difftastic--build-git-process-environment
                        width (list "--display" difftastic-status-display))))
                  (apply #'process-file "git" nil t nil args))
                (buffer-string))))
    ;; Turn difft's ANSI escapes into propertized text using difftastic's
    ;; own colour vectors (so it matches `difftastic-magit-diff').
    (difftastic--ansi-color-apply raw)))

;;; Per-chunk staging
;;
;; Strategy: difftastic is DISPLAY only.  Git's own unified diff remains the
;; source of truth for the patch we apply, so every applied patch is a valid
;; git patch.  To stage "the chunk at point" we:
;;
;;   1. read the chunk's (file, index, staged) -- stored on the section value;
;;   2. lazily run `difft --display json' for that file to get the chunk's
;;      exact old/new line numbers (lhs/rhs, 0-indexed -> +1);
;;   3. run `git diff --no-ext-diff -U1' to get fine-grained hunks (one context
;;      line), each with its line ranges and exact patch text;
;;   4. select the git hunk(s) overlapping the chunk's line numbers;
;;   5. apply that mini-patch with `git apply [--cached] [--reverse]'.
;;
;; Why one context line (`difftastic-status-apply-context', default 1) rather
;; than zero?  Zero-context patches REVERSE-apply ambiguously: git cannot tell
;; where to re-insert a deleted line without a neighbouring context line, so
;; unstage/discard of a pure deletion lands in the wrong place.  A single
;; context line disambiguates application (forward AND reverse) while still
;; keeping changes in separate hunks unless they are within two lines of each
;; other.  When several difftastic chunks fall inside one git hunk, staging any
;; of them stages that whole git hunk (the same boundary-snapping that Magit's
;; own hunk staging has).

(defun difftastic-status--enclosing-file-section ()
  "Return the `file' section enclosing point, if any."
  (let ((s (magit-current-section)))
    (while (and s (not (eq (oref s type) 'file)))
      (setq s (oref s parent)))
    s))

(defun difftastic-status--enclosing-file ()
  "Return the value (filename) of the `file' section enclosing point, if any."
  (when-let* ((s (difftastic-status--enclosing-file-section)))
    (oref s value)))

(defun difftastic-status--first-chunk (file-section)
  "Return the first `difftastic-hunk' child of FILE-SECTION, or nil."
  (and file-section
       (seq-find (lambda (c) (eq (oref c type) 'difftastic-hunk))
                 (oref file-section children))))

(defun difftastic-status-visit-file-dwim ()
  "Visit the file enclosing point, jumping to the chunk's exact change.
When on a chunk, jump to the line and column of its first new-side change
\(via `difft --display json'); falls back to the chunk's stored gutter line.
On a file heading (not a chunk), behaves as if point were on the file's first
chunk.  We avoid `magit-diff-visit-file' here because it expects the current
section to be a real Magit diff/hunk section (with slots like `from-range'),
which our custom `difftastic-hunk' sections do not have."
  (interactive)
  (if-let* ((file-section (difftastic-status--enclosing-file-section)))
      (let* ((file (oref file-section value))
             (chunk (or (difftastic-status--current-chunk)
                        (difftastic-status--first-chunk file-section)))
             (val (and chunk (oref chunk value)))
             (line (or (and val (ignore-errors
                                  (difftastic-status--chunk-visit-line
                                   (plist-get val :file)
                                   (plist-get val :diff-args)
                                   (plist-get val :index))))
                       (and val (plist-get val :line)))))
        (find-file (expand-file-name file (magit-toplevel)))
        (when line
          (goto-char (point-min))
          (forward-line (1- line))
          (back-to-indentation)))
    (user-error "No file at point")))

(defcustom difftastic-status-apply-context 1
  "Number of context lines for the git hunks used to stage/unstage chunks.
Must be >= 1: zero-context patches reverse-apply ambiguously (see commentary
above).  Larger values make application more forgiving but merge nearby
changes into a single stageable hunk."
  :type 'integer
  :group 'difftastic-status)

(defun difftastic-status--git-diff-raw (file staged &optional context)
  "Return plain unified diff text for FILE (difftastic disabled).
Uses CONTEXT context lines (default `difftastic-status-apply-context').
When STAGED is non-nil diff the index against HEAD."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil
           (append (list "--no-pager" "diff" "--no-ext-diff"
                         (format "-U%d" (or context difftastic-status-apply-context)))
                   (when staged '("--cached"))
                   (list "--" file)))
    (buffer-string)))

(defun difftastic-status--parse-diff (diff)
  "Parse unified DIFF text into (HEADER . HUNKS).
HEADER is everything before the first hunk (the `diff --git'/`---'/`+++'
lines).  Each hunk is a plist with :old-beg :old-len :new-beg :new-len
and :text (the exact patch text for that hunk, including its @@ line)."
  (let ((lines (split-string diff "\n"))
        (header "")
        (hunks nil)
        (cur nil)
        (cur-lines nil))
    ;; Drop the trailing empty string produced by the final newline so we do
    ;; not append a spurious blank line to the last hunk.
    (when (and lines (string-empty-p (car (last lines))))
      (setq lines (butlast lines)))
    (cl-flet ((flush ()
                (when cur
                  (push (plist-put cur :text
                                   (concat (string-join (nreverse cur-lines) "\n")
                                           "\n"))
                        hunks))))
      (dolist (line lines)
        (cond
         ((string-match
           "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@"
           line)
          (flush)
          (setq cur (list :old-beg (string-to-number (match-string 1 line))
                          :old-len (if (match-string 2 line)
                                       (string-to-number (match-string 2 line))
                                     1)
                          :new-beg (string-to-number (match-string 3 line))
                          :new-len (if (match-string 4 line)
                                       (string-to-number (match-string 4 line))
                                     1))
                cur-lines (list line)))
         (cur (push line cur-lines))
         (t (setq header (concat header line "\n")))))
      (flush))
    (cons header (nreverse hunks))))

(defun difftastic-status--chunk-json (file diff-args index)
  "Return difft's JSON rows (a list) for chunk INDEX of FILE, or nil.
Each row is an alist with `lhs'/`rhs' entries.  DIFF-ARGS is the leading git
invocation that selects the diff (see `difftastic-status--file-diff-string')."
  (require 'difftastic)
  (let* ((width (difftastic-status--width))
         (json (with-temp-buffer
                 (let ((process-environment
                        (cons "DFT_UNSTABLE=yes"
                              (difftastic--build-git-process-environment
                               width '("--display" "json")))))
                   (apply #'process-file "git" nil t nil
                          (append diff-args (list "--" file))))
                 (buffer-string)))
         (data (ignore-errors
                 (json-parse-string json
                                    :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil))))
    (and data (nth index (alist-get 'chunks data)))))

(defun difftastic-status--json-chunk-lines (file diff-args index)
  "Return (OLD-LINES . NEW-LINES), 1-indexed, for difft chunk INDEX of FILE.
OLD-LINES/NEW-LINES are the lhs/rhs line numbers difftastic reports for the
changed rows of that chunk.  DIFF-ARGS selects the diff (see
`difftastic-status--file-diff-string')."
  (let ((chunk (difftastic-status--chunk-json file diff-args index))
        (old nil)
        (new nil))
    (dolist (row chunk)
      (let ((lhs (alist-get 'lhs row))
            (rhs (alist-get 'rhs row)))
        (when (and lhs (numberp (alist-get 'line_number lhs)))
          (push (1+ (alist-get 'line_number lhs)) old))
        (when (and rhs (numberp (alist-get 'line_number rhs)))
          (push (1+ (alist-get 'line_number rhs)) new))))
    (cons (nreverse old) (nreverse new))))

(defun difftastic-status--chunk-visit-line (file diff-args index)
  "Return the 1-based line of chunk INDEX's first change in FILE, or nil.
Prefers the first new-side (rhs) line so visiting lands exactly on the change
in the worktree; falls back to the first old-side (lhs) line for a pure
deletion.  DIFF-ARGS selects the diff (see
`difftastic-status--file-diff-string').

\(We deliberately do not try to compute a column: difft only marks changed
tokens for recognized languages -- for plain text every span is `normal' --
so a JSON-derived column would be misleading.  Visiting lands on the line and
its first non-whitespace character instead.)"
  (let ((chunk (difftastic-status--chunk-json file diff-args index)))
    (cl-flet ((first-line (side)
                (cl-loop for row in chunk
                         for s = (alist-get side row)
                         for ln = (and s (alist-get 'line_number s))
                         for changes = (and s (alist-get 'changes s))
                         when (and (numberp ln) changes)
                         return (1+ ln))))
      (or (first-line 'rhs) (first-line 'lhs)))))

(defun difftastic-status--hunk-covers-p (hunk old-lines new-lines)
  "Return non-nil if HUNK overlaps any of OLD-LINES or NEW-LINES."
  (or (cl-some (lambda (o)
                 (and (> (plist-get hunk :old-len) 0)
                      (<= (plist-get hunk :old-beg)
                          o
                          (+ (plist-get hunk :old-beg) (plist-get hunk :old-len) -1))))
               old-lines)
      (cl-some (lambda (n)
                 (and (> (plist-get hunk :new-len) 0)
                      (<= (plist-get hunk :new-beg)
                          n
                          (+ (plist-get hunk :new-beg) (plist-get hunk :new-len) -1))))
               new-lines)))

(defun difftastic-status--chunk-patch (section)
  "Build a standalone git patch string for the chunk SECTION, or nil.
The patch contains the file header plus exactly the git hunk(s) that the
difftastic chunk maps onto."
  (let* ((val (oref section value))
         (file (plist-get val :file))
         (index (plist-get val :index))
         (staged (plist-get val :staged))
         (diff-args (plist-get val :diff-args))
         (parsed (difftastic-status--parse-diff (difftastic-status--git-diff-raw file staged)))
         (header (car parsed))
         (hunks (cdr parsed))
         (lines (difftastic-status--json-chunk-lines file diff-args index))
         (matched (cl-remove-if-not
                   (lambda (h) (difftastic-status--hunk-covers-p h (car lines) (cdr lines)))
                   hunks)))
    (when (and (not (string-empty-p header)) matched)
      (concat header (mapconcat (lambda (h) (plist-get h :text)) matched "")))))

(defun difftastic-status--apply-chunk-patch (patch &rest apply-args)
  "Apply PATCH via `git apply APPLY-ARGS -' (reading PATCH on stdin) and refresh."
  (with-temp-buffer
    (insert patch)
    (let ((magit-inhibit-refresh t))
      (apply #'magit-run-git-with-input "apply" (append apply-args '("-")))))
  (magit-refresh))

(defun difftastic-status--current-chunk ()
  "Return the difftastic chunk section at point, or nil."
  (let ((s (magit-current-section)))
    (and s (eq (oref s type) 'difftastic-hunk) s)))

;;; Region (line-range) staging
;;
;; When a region is active within a chunk, operate on just the selected lines.
;; We classify each selected difft display line as old- or new-side -- old-side
;; rows begin with a digit (the old line number); new-side rows begin with
;; whitespace then the new line number -- to collect the selected old/new file
;; line numbers.  Then we transform git's OWN diff hunks the same way
;; `magit-diff-hunk-region-patch' does: keep context and selected +/- lines,
;; turn unselected lines whose marker matches OP into context, drop the rest.
;; `diff-fixup-modifs' recomputes the @@ counts and
;; `magit-apply--adjust-hunk-new-starts' fixes the new-starts.

(defun difftastic-status--line-side+num (line)
  "Classify difft inline display LINE; return (SIDE . NUM) or nil.
SIDE is `old' (row begins with a digit) or `new' (row begins with
whitespace then the new line number).  NUM is the 1-based file line."
  (cond
   ((string-match "\\`\\([0-9]+\\)" line)
    (cons 'old (string-to-number (match-string 1 line))))
   ((string-match "\\`[ \t]+\\([0-9]+\\)" line)
    (cons 'new (string-to-number (match-string 1 line))))))

(defun difftastic-status--region-active-p (section)
  "Return non-nil if the region is active and overlaps SECTION's body."
  (and (region-active-p)
       (< (region-beginning) (oref section end))
       (> (region-end) (or (oref section content) (oref section start)))))

(defun difftastic-status--region-selected-lines (section)
  "Return (OLD-LINES . NEW-LINES) selected by the active region within SECTION.
The region is clamped to SECTION's body and snapped to whole lines."
  (let ((beg (max (region-beginning)
                  (or (oref section content) (oref section start))))
        (end (min (region-end) (oref section end)))
        (old nil) (new nil))
    (when (< beg end)
      (save-excursion
        (goto-char beg)
        (beginning-of-line)
        (while (< (point) end)
          (when-let* ((sn (difftastic-status--line-side+num
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))
            (pcase (car sn)
              ('old (push (cdr sn) old))
              ('new (push (cdr sn) new))))
          (forward-line))))
    (cons (nreverse old) (nreverse new))))

(defun difftastic-status--split-hunks (text)
  "Split diff TEXT (hunks only, no file header) into a list of hunk strings."
  (let (hunks)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "^@@" nil t)
        (beginning-of-line)
        (let ((beg (point)))
          (forward-line)
          (if (re-search-forward "^@@" nil t)
              (beginning-of-line)
            (goto-char (point-max)))
          (push (buffer-substring beg (point)) hunks)))
      (nreverse hunks))))

(defun difftastic-status--region-patch (file staged op sel-old sel-new)
  "Build a partial patch for FILE staging only SEL-OLD/SEL-NEW lines, or nil.
OP is \"-\" for forward application (stage/discard) or \"+\" for reverse
\(unstage).  Modeled on `magit-diff-hunk-region-patch'."
  (require 'diff-mode)
  (let* ((parsed (difftastic-status--parse-diff (difftastic-status--git-diff-raw file staged 3)))
         (header (car parsed))
         (out-hunks nil))
    (dolist (h (cdr parsed))
      (let ((old-n (plist-get h :old-beg))
            (new-n (plist-get h :new-beg))
            (lines (split-string (plist-get h :text) "\n"))
            (acc nil)
            (kept nil))
        (let ((hdr (car lines)))
          (dolist (l (cdr lines))
            (unless (string-empty-p l)
              (let ((mark (aref l 0))
                    (content (substring l 1)))
                (cond
                 ((eq mark ?\s) (push l acc) (cl-incf old-n) (cl-incf new-n))
                 ((eq mark ?-)
                  (cond ((member old-n sel-old) (push l acc) (setq kept t))
                        ((string= op "-") (push (concat " " content) acc)))
                  (cl-incf old-n))
                 ((eq mark ?+)
                  (cond ((member new-n sel-new) (push l acc) (setq kept t))
                        ((string= op "+") (push (concat " " content) acc)))
                  (cl-incf new-n))
                 ;; "\ No newline at end of file" and any other marker.
                 (t (push l acc))))))
          (when kept
            (push (concat hdr "\n" (string-join (nreverse acc) "\n") "\n")
                  out-hunks)))))
    (when (and (not (string-empty-p header)) out-hunks)
      (let* ((fixed (with-temp-buffer
                      (dolist (h (nreverse out-hunks)) (insert h))
                      (diff-fixup-modifs (point-min) (point-max))
                      (buffer-string)))
             (adjusted (magit-apply--adjust-hunk-new-starts
                        (difftastic-status--split-hunks fixed))))
        (concat header (string-join adjusted))))))

(defun difftastic-status--patch-for (section op)
  "Return the patch to apply for SECTION and OP.
When a region is active within SECTION, build a partial (line-range) patch
for the selected lines; otherwise build the whole-chunk patch.  Signals a
`user-error' when nothing applicable is found."
  (if (difftastic-status--region-active-p section)
      (let* ((val (oref section value))
             (sel (difftastic-status--region-selected-lines section)))
        (or (difftastic-status--region-patch (plist-get val :file)
                                       (plist-get val :staged)
                                       op (car sel) (cdr sel))
            (user-error "No changes in the selected region")))
    (or (difftastic-status--chunk-patch section)
        (user-error "Could not map this chunk to a git hunk; use the file heading"))))

;; Core operations -- assume point is on a difftastic chunk SECTION.
;; Each op honors an active region (line-range staging) via
;; `difftastic-status--patch-for'; with no region it operates on the whole chunk.
(defun difftastic-status--ensure-stageable (section)
  "Signal a `user-error' unless chunk SECTION supports staging.
Chunks rendered for a diff that merely compares two revisions (a range diff,
or a commit being viewed) carry `:stageable' nil: there is no index or
worktree to apply a patch to."
  (unless (plist-get (oref section value) :stageable)
    (user-error "Staging is not available here; this diff only compares revisions")))

(defun difftastic-status--stage-chunk-1 (section)
  "Stage the change(s) covered by chunk SECTION (or the selected region)."
  (difftastic-status--ensure-stageable section)
  (if (plist-get (oref section value) :staged)
      (user-error "This chunk is already staged")
    (difftastic-status--apply-chunk-patch (difftastic-status--patch-for section "-") "--cached")))

(defun difftastic-status--unstage-chunk-1 (section)
  "Unstage the change(s) covered by chunk SECTION (or the selected region)."
  (difftastic-status--ensure-stageable section)
  (if (plist-get (oref section value) :staged)
      (difftastic-status--apply-chunk-patch
       (difftastic-status--patch-for section "+") "--cached" "--reverse")
    (user-error "This chunk is not staged")))

(defun difftastic-status--discard-chunk-1 (section)
  "Discard the worktree change(s) covered by chunk SECTION (or the region)."
  (difftastic-status--ensure-stageable section)
  (if (plist-get (oref section value) :staged)
      (user-error "Discarding a staged chunk is not supported; unstage it first")
    (let ((patch (difftastic-status--patch-for section "+")))
      (when (magit-confirm 'discard "Discard the selected change(s)")
        (difftastic-status--apply-chunk-patch patch "--reverse")))))

;; Interactive commands (for M-x / direct binding).
(defun difftastic-status-stage-chunk ()
  "Stage the chunk at point, else fall back to `magit-stage'."
  (interactive)
  (if-let* ((section (difftastic-status--current-chunk)))
      (difftastic-status--stage-chunk-1 section)
    (call-interactively #'magit-stage)))

(defun difftastic-status-unstage-chunk ()
  "Unstage the chunk at point, else fall back to `magit-unstage'."
  (interactive)
  (if-let* ((section (difftastic-status--current-chunk)))
      (difftastic-status--unstage-chunk-1 section)
    (call-interactively #'magit-unstage)))

(defun difftastic-status-discard-chunk ()
  "Discard the chunk at point, else fall back to `magit-discard'."
  (interactive)
  (if-let* ((section (difftastic-status--current-chunk)))
      (difftastic-status--discard-chunk-1 section)
    (call-interactively #'magit-discard)))

;; Advice -- the robust dispatch mechanism.
;;
;; Relying on a `[remap magit-stage]' entry in the section's text-property
;; keymap does NOT work under evil-collection-magit: it makes `magit-mode-map'
;; an *overriding* map for the magit evil state, so `s'/`u'/... resolve to the
;; magit commands through a path that bypasses our remap.  Advising the magit
;; commands themselves is binding/state agnostic: whatever key (or M-x) invokes
;; `magit-stage', if point is on a difftastic chunk we handle it, otherwise we
;; call the original command unchanged.

(defun difftastic-status--stage-advice (orig &rest args)
  "Around-advice for `magit-stage' (see commentary)."
  (if-let* ((section (difftastic-status--current-chunk)))
      (difftastic-status--stage-chunk-1 section)
    (apply orig args)))

(defun difftastic-status--unstage-advice (orig &rest args)
  "Around-advice for `magit-unstage' (see commentary)."
  (if-let* ((section (difftastic-status--current-chunk)))
      (difftastic-status--unstage-chunk-1 section)
    (apply orig args)))

(defun difftastic-status--discard-advice (orig &rest args)
  "Around-advice for `magit-discard'/`magit-delete-thing' (see commentary)."
  (if-let* ((section (difftastic-status--current-chunk)))
      (difftastic-status--discard-chunk-1 section)
    (apply orig args)))

(defun difftastic-status--visit-advice (orig &rest args)
  "Around-advice for `magit-visit-thing'/`magit-diff-visit-file' (see commentary).
Handle both a difftastic chunk and a difftastic `file' section (one with
`difftastic-hunk' children): visiting either with the real command expects hunk
slots our sections lack and would signal an `invalid slot' error.

We must advise BOTH commands: on a chunk, `RET' resolves to `magit-visit-thing'
\(our `magit-difftastic-hunk-section-map' adds no remap), but on a `file'
heading Magit's `magit-diff-section-map' remaps `magit-visit-thing' to
`magit-diff-visit-file', so advising only the former never fires there."
  (if (or (difftastic-status--current-chunk)
          (difftastic-status--first-chunk
           (difftastic-status--enclosing-file-section)))
      (difftastic-status-visit-file-dwim)
    (apply orig args)))

(defconst difftastic-status--advices
  ;; These commands have simple (non-prompting) interactive forms, so advising
  ;; them is transparent.  We intentionally do NOT advise `magit-stage-files'/
  ;; `magit-unstage-files' (what `magit-mode-map' binds `s'/`u' to): their
  ;; interactive forms prompt for files, which would pop a prompt even when we
  ;; just want to stage the chunk.  Instead the `s'/`u'/`x' keys are bound
  ;; explicitly per evil state (see `difftastic-status--set-evil-keys').
  '((magit-stage        . difftastic-status--stage-advice)
    (magit-unstage      . difftastic-status--unstage-advice)
    (magit-discard      . difftastic-status--discard-advice)
    (magit-delete-thing . difftastic-status--discard-advice)
    (magit-visit-thing  . difftastic-status--visit-advice)
    ;; On a `file' heading, Magit's `magit-diff-section-map' remaps
    ;; `magit-visit-thing' to `magit-diff-visit-file', so `RET' there bypasses
    ;; the `magit-visit-thing' advice; intercept `magit-diff-visit-file' too.
    (magit-diff-visit-file . difftastic-status--visit-advice))
  "Alist of (MAGIT-COMMAND . ADVICE) intercepted while on a difftastic chunk.")

(defun difftastic-status--chunk-start-line (body-lines)
  "Return the first line number appearing in BODY-LINES, as a string, or nil.
Difftastic inline rows are prefixed with a right-aligned line number."
  (cl-some (lambda (l)
             (when (string-match "\\`[ \t]*\\([0-9]+\\)" l)
               (match-string 1 l)))
           body-lines))

(defun difftastic-status--insert-chunk (body-lines file index context)
  "Insert one collapsible chunk section from BODY-LINES (difft header removed).
FILE is the repo-relative path and INDEX is the chunk's 0-based position in the
file's difftastic output (matching `difft --display json' chunk order).
CONTEXT is the diff context plist (see
`difftastic-status--insert-file-sections'); its `:diff-args', `:staged' and
`:stageable' entries are stored on the section value so the staging commands
can rebuild the corresponding git hunk."
  ;; Drop leading/trailing blank lines that difft puts between chunks.
  (while (and body-lines (string-blank-p (car body-lines)))
    (setq body-lines (cdr body-lines)))
  (let ((rev (reverse body-lines)))
    (while (and rev (string-blank-p (car rev)))
      (setq rev (cdr rev)))
    (setq body-lines (reverse rev)))
  (when body-lines
    (let* ((start (difftastic-status--chunk-start-line body-lines))
           (heading (if start (format "@@ line %s @@" start) "@@ @@")))
      (magit-insert-section (difftastic-hunk
                             (list :file file :index index
                                   :diff-args (plist-get context :diff-args)
                                   :staged (plist-get context :staged)
                                   :stageable (plist-get context :stageable)
                                   :line (and start (string-to-number start))))
        (magit-insert-heading
          (propertize heading 'font-lock-face difftastic-status-chunk-heading-face))
        (dolist (l body-lines)
          (insert l "\n"))))))

(defun difftastic-status--insert-chunks (rendered file context)
  "Split RENDERED difftastic output for FILE into collapsible per-chunk sections.
Difftastic's own `FILE --- N/M --- LANG' headers are consumed (not shown).
The chunk INDEX passed to `difftastic-status--insert-chunk' increments once per
difftastic chunk header so it stays aligned with `difft --display json'.
CONTEXT is the diff context plist threaded down to each chunk section."
  (let ((header-re (difftastic--chunk-regexp t))
        (lines (split-string rendered "\n"))
        (chunk nil)
        (index -1)
        (started nil))
    (dolist (line lines)
      (if (string-match-p header-re line)
          (progn
            (when started
              (difftastic-status--insert-chunk (nreverse chunk) file index context))
            (setq chunk nil started t index (1+ index)))
        (when started
          (push line chunk))))
    (when started
      (difftastic-status--insert-chunk (nreverse chunk) file index context))))

(defun difftastic-status--deleted-files (diff-args)
  "Return the list of paths the DIFF-ARGS diff reports as deleted.
DIFF-ARGS is the leading git invocation (see
`difftastic-status--file-diff-string'); `--name-status' is appended so deletions
can be detected without rendering a diff.  Used to mirror Magit, which collapses
deleted-file sections by default."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil
           (append diff-args '("--name-status")))
    (let (deleted)
      (dolist (line (split-string (buffer-string) "\n" t))
        (let ((fields (split-string line "\t")))
          ;; Status lines are "<STATUS>\t<PATH>" (and "R.../C..." carry an extra
          ;; field); a leading `D' marks a deletion, whose path is the next field.
          (when (and (string-prefix-p "D" (car fields)) (cadr fields))
            (push (cadr fields) deleted))))
      deleted)))

(defun difftastic-status--insert-file-sections (files context)
  "Insert a collapsible difftastic `file' section for each of FILES.
Files are contiguous (no blank line between them); the only blank line is
inserted after the whole section (see the top-level inserters).
CONTEXT is a diff context plist with the entries:
  :diff-args  the leading git invocation selecting the diff to render
              (see `difftastic-status--file-diff-string');
  :staged     non-nil when the diff is the index against HEAD;
  :stageable  non-nil when per-chunk staging is meaningful in this buffer.
It is threaded down to every chunk section so the staging commands can rebuild
the corresponding git hunk.

Initial visibility mirrors Magit: a file section starts collapsed in
`magit-status-mode' buffers (and for deleted files everywhere), and expanded in
the diff/revision buffers.  The chunk sections are always inserted expanded, so
expanding a file reveals its hunk(s) -- the same way a single-hunk file feels
like it expands straight to its diff in Magit."
  (let ((diff-args (plist-get context :diff-args))
        (deleted (difftastic-status--deleted-files (plist-get context :diff-args)))
        (status-buffer (derived-mode-p 'magit-status-mode)))
    (dolist (file files)
      (magit-insert-section (file file (or (and (member file deleted) t)
                                           status-buffer))
        (magit-insert-heading
          (propertize file 'font-lock-face 'magit-filename))
        (difftastic-status--insert-chunks
         (difftastic-status--file-diff-string file diff-args)
         file context)))))

(defun difftastic-status--context-unstaged ()
  "Diff context plist for the worktree-vs-index (unstaged) diff."
  (list :diff-args difftastic-status--diff-base :staged nil :stageable t))

(defun difftastic-status--context-staged ()
  "Diff context plist for the index-vs-HEAD (staged) diff."
  (list :diff-args (append difftastic-status--diff-base '("--cached"))
        :staged t :stageable t))

(defun difftastic-status-insert-unstaged-changes ()
  "Difftastic replacement for `magit-insert-unstaged-changes'."
  (when-let* ((files (magit-unstaged-files)))
    (magit-insert-section (unstaged)
      (magit-insert-heading t "Unstaged changes")
      (difftastic-status--insert-file-sections
       files (difftastic-status--context-unstaged)))
    ;; Trailing blank line OUTSIDE the section, so it remains a stable
    ;; separator before the next section even when this one is collapsed.
    (insert "\n")))

(defun difftastic-status-insert-staged-changes ()
  "Difftastic replacement for `magit-insert-staged-changes'."
  (unless (magit-bare-repo-p)
    (when-let* ((files (magit-staged-files)))
      (magit-insert-section (staged)
        (magit-insert-heading t "Staged changes")
        (difftastic-status--insert-file-sections
         files (difftastic-status--context-staged)))
      (insert "\n"))))

;;; Diff- and revision-buffer rendering
;;
;; The same difftastic chunk sections are inserted into `magit-diff-mode'
;; buffers (which includes the diff Magit shows while you compose a commit
;; message) and `magit-revision-mode' buffers (viewing a commit) by advising
;; Magit's `magit-insert-diff' / `magit-insert-revision-diff' section inserters.
;; We use `:around' advice -- not `:override' -- so that anything difftastic
;; cannot (or should not) render falls straight back to Magit's stock inserter:
;; `--no-index' diffs, merge commits shown as combined diffs, and so on.
;;
;; Per-chunk staging is enabled only where it is meaningful: the worktree
;; (unstaged) and `--cached' (staged) diff buffers.  Anything that compares two
;; revisions -- a range diff, or a commit being viewed -- is rendered
;; display-only (`:stageable' nil; see `difftastic-status--ensure-stageable').

(defcustom difftastic-status-diff-buffers t
  "Whether to render `magit-diff-mode' buffers with difftastic chunks.
This includes the diff Magit shows while you compose a commit message (which is
itself a `magit-diff-mode' buffer).  When nil, those buffers keep Magit's stock
rendering even while `difftastic-status-mode' is enabled."
  :type 'boolean
  :group 'difftastic-status)

(defcustom difftastic-status-revision-buffers t
  "Whether to render `magit-revision-mode' buffers with difftastic chunks.
When nil, viewing a commit keeps Magit's stock rendering even while
`difftastic-status-mode' is enabled."
  :type 'boolean
  :group 'difftastic-status)

;; These are buffer-local variables Magit sets in its diff/revision buffers;
;; declare them special to keep the byte-compiler quiet.
(defvar magit-buffer-range)
(defvar magit-buffer-typearg)
(defvar magit-buffer-diff-files)
(defvar magit-buffer-revision)

(defun difftastic-status--git-lines (&rest args)
  "Run \"git ARGS...\" and return its non-empty output lines as a list."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil args)
    (split-string (buffer-string) "\n" t)))

(defun difftastic-status--diff-context ()
  "Return a (CONTEXT . FILES) pair for the current `magit-diff-mode' buffer.
CONTEXT is the diff context plist (see
`difftastic-status--insert-file-sections') and FILES is the list of changed
files.  Returns nil when the buffer's diff
cannot (or should not) be rendered with difftastic -- e.g. a `--no-index' diff,
or a diff with no files -- so the caller can fall back to Magit's stock
inserter.

The diff is classified from Magit's buffer-locals: with no range, `--cached'
means the index against HEAD (unstaging a chunk is meaningful) and no typearg
means the worktree against the index (staging a chunk is meaningful); anything
that names a range/revision is rendered display-only."
  (let ((range magit-buffer-range)
        (typearg magit-buffer-typearg)
        (diff-files magit-buffer-diff-files))
    (unless (equal typearg "--no-index")
      (let* ((selector (append (and range (list range))
                               (and typearg (list typearg))))
             (context
              (cond
               ((and (null range) (equal typearg "--cached"))
                (list :diff-args (append difftastic-status--diff-base selector)
                      :staged t :stageable t))
               ((and (null range) (null typearg))
                (list :diff-args difftastic-status--diff-base
                      :staged nil :stageable t))
               (t
                (list :diff-args (append difftastic-status--diff-base selector)
                      :staged nil :stageable nil))))
             (files (apply #'difftastic-status--git-lines
                           (append '("--no-pager" "diff" "--name-only")
                                   selector '("--") diff-files))))
        (and files (cons context files))))))

(defun difftastic-status--revision-context ()
  "Return a (CONTEXT . FILES) pair for the current `magit-revision-mode' buffer.
CONTEXT is a display-only diff context plist rendering the commit with
`git show', and FILES is the commit's changed files.  Returns nil when there is
nothing difftastic can render (no revision, or a merge commit shown as a
combined diff, which has no `--name-only' files), so the caller can fall back to
Magit's stock inserter."
  (when-let* ((rev magit-buffer-revision))
    ;; Peel to the underlying commit so viewing a tag shows the commit's diff
    ;; (mirrors Magit's `magit--rev-dereference').
    (let* ((commit (concat rev "^{commit}"))
           (diff-files magit-buffer-diff-files)
           (context (list :diff-args (append difftastic-status--show-base (list commit))
                          :staged nil :stageable nil))
           (files (apply #'difftastic-status--git-lines
                         (append '("--no-pager" "show" "--name-only" "--format=")
                                 (list commit) '("--") diff-files))))
      (and files (cons context files)))))

(defun difftastic-status--insert-diff-advice (orig &rest args)
  "Around-advice for `magit-insert-diff' rendering chunks with difftastic.
Falls back to ORIG (called with ARGS) when difftastic should not handle the
current `magit-diff-mode' buffer."
  (let ((ctx (and difftastic-status-diff-buffers
                  (ignore-errors (difftastic-status--diff-context)))))
    (if ctx
        (difftastic-status--insert-file-sections (cdr ctx) (car ctx))
      (apply orig args))))

(defun difftastic-status--insert-revision-diff-advice (orig &rest args)
  "Around-advice for `magit-insert-revision-diff' rendering chunks with difftastic.
Falls back to ORIG (called with ARGS) when difftastic should not handle the
current `magit-revision-mode' buffer.  Like Magit's own inserter, the per-file
sections are inserted directly (no extra wrapping section)."
  (let ((ctx (and difftastic-status-revision-buffers
                  (ignore-errors (difftastic-status--revision-context)))))
    (if ctx
        (difftastic-status--insert-file-sections (cdr ctx) (car ctx))
      (apply orig args))))

(defconst difftastic-status--evil-keys
  '(("s" . difftastic-status-stage-chunk)
    ("u" . difftastic-status-unstage-chunk)
    ("x" . difftastic-status-discard-chunk))
  "Evil keys bound in magit maps so chunk/region staging works under evil.")

(defun difftastic-status--set-evil-keys (enable)
  "Bind (ENABLE non-nil) or unbind the staging keys in evil normal+visual states.
Why bind explicitly instead of relying solely on the command advice?  On a
difftastic chunk the keys `s'/`u' resolve (via `magit-mode-map') to
`magit-stage-files'/`magit-unstage-files' -- whose interactive forms PROMPT for
files -- rather than to the dwim commands we advise; and evil-collection routes
keys differently between states.  Binding `s'/`u'/`x' directly to our commands
in both normal and visual states makes chunk staging and region (line-range)
staging behave identically and predictably.  The bound commands fall back to
the normal magit commands when point is not on a difftastic chunk, so this is
safe even with the mode's other features off.

We bind in both `magit-mode-map' and `magit-section-mode-map' (the latter has
higher precedence as a minor-mode map) so our binding wins regardless of what
evil-collection-magit[-section] puts there."
  (when (fboundp 'evil-define-key*)
    (dolist (map '(magit-mode-map magit-section-mode-map))
      (when (boundp map)
        (pcase-dolist (`(,key . ,cmd) difftastic-status--evil-keys)
          ;; A nil definition removes our override (falls through to magit's).
          (evil-define-key* '(normal visual) (symbol-value map)
                            key (and enable cmd)))))))

;;;###autoload
(define-minor-mode difftastic-status-mode
  "Render unstaged/staged changes in `magit-status' with difftastic.

While enabled, `magit-insert-unstaged-changes' and
`magit-insert-staged-changes' are overridden so the status buffer shows
collapsible, difftastic-rendered, per-file sections.  `magit-insert-diff' and
`magit-insert-revision-diff' are likewise advised so `magit-diff-mode' buffers
\(including the diff shown while composing a commit) and `magit-revision-mode'
buffers (viewing a commit) get the same difftastic chunks; this can be scoped
with `difftastic-status-diff-buffers' and `difftastic-status-revision-buffers'.
The magit stage/unstage/discard/visit commands are advised so that, while point
is on a difftastic chunk, they act on just that chunk (otherwise unchanged) --
staging is offered only where it is meaningful (the worktree and `--cached'
diffs).  Evil visual-state keys are also bound so region (line-range) staging
works."
  :global t
  :group 'difftastic-status
  (if difftastic-status-mode
      (progn
        (advice-add 'magit-insert-unstaged-changes :override
                    #'difftastic-status-insert-unstaged-changes)
        (advice-add 'magit-insert-staged-changes :override
                    #'difftastic-status-insert-staged-changes)
        (advice-add 'magit-insert-diff :around
                    #'difftastic-status--insert-diff-advice)
        (advice-add 'magit-insert-revision-diff :around
                    #'difftastic-status--insert-revision-diff-advice)
        (pcase-dolist (`(,cmd . ,advice) difftastic-status--advices)
          (advice-add cmd :around advice))
        (difftastic-status--set-evil-keys t))
    (advice-remove 'magit-insert-unstaged-changes
                   #'difftastic-status-insert-unstaged-changes)
    (advice-remove 'magit-insert-staged-changes
                   #'difftastic-status-insert-staged-changes)
    (advice-remove 'magit-insert-diff
                   #'difftastic-status--insert-diff-advice)
    (advice-remove 'magit-insert-revision-diff
                   #'difftastic-status--insert-revision-diff-advice)
    (pcase-dolist (`(,cmd . ,advice) difftastic-status--advices)
      (advice-remove cmd advice))
    (difftastic-status--set-evil-keys nil))
  ;; Refresh any visible status/diff/revision buffers so the change is
  ;; immediately visible (`magit-revision-mode' derives from `magit-diff-mode').
  (when (fboundp 'magit-refresh)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'magit-status-mode 'magit-diff-mode)
          (magit-refresh))))))

(provide 'difftastic-status)
;;; difftastic-status.el ends here
