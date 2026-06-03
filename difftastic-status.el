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
;; Rendering can also be toggled per file: with point on a file (or chunk),
;; `difftastic-status-toggle-file-rendering' (bound to
;; `difftastic-status-toggle-rendering-key', \\`C-c C-d' by default) switches
;; just that file between difftastic and stock Magit rendering, and back.  A
;; file shown with stock Magit sections uses Magit's own per-hunk and per-line
;; staging -- handy when you want fine-grained staging or a file difftastic
;; renders awkwardly.  The choice is buffer-local and survives refreshes.
;;
;; Evil integration is optional and installed gracefully: if `evil' is present
;; the staging keys are bound in the relevant magit maps; if not, nothing is
;; assumed and the package works with stock Emacs keybindings.
;;
;; This package: per-file difftastic sections, split into collapsible per-chunk
;; sub-sections, with both FILE-LEVEL and PER-CHUNK staging.
;;
;;   Each changed file becomes a Magit `file' section.  Its body is the
;;   difftastic-rendered diff, which we split on difftastic's
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
  "Difft layout used to render chunks (passed to difft's `--display').
All three layouts support per-chunk and line-range (region) staging:

  - `inline'                 single column, closest to a classic diff.
  - `side-by-side'           two columns; a chunk that is purely additions
                             or removals collapses back to one column.
  - `side-by-side-show-both' two columns always, so every row is uniform."
  :type '(choice (const :tag "Inline (single column)" "inline")
                 (const :tag "Side by side" "side-by-side")
                 (const :tag "Side by side, always two columns"
                        "side-by-side-show-both"))
  :group 'difftastic-status)

(defcustom difftastic-status-line-numbers t
  "Whether difft's per-line number gutters are shown in rendered chunks.
When nil, the line-number columns are hidden in the status, diff and revision
buffers.  Staging works the same either way."
  :type 'boolean
  :group 'difftastic-status)

(defcustom difftastic-status-chunk-heading-face 'magit-diff-hunk-heading
  "Face used for the per-chunk `@@ line N @@' headings.
Defaults to `magit-diff-hunk-heading', so the headings look like Magit's own
hunk headings (a full-width bar, since that face has `:extend t').  Set to any
face you prefer, e.g. `magit-hash' (the muted face Magit uses for commit hashes)
for understated headings, `magit-section-heading' for a bolder look, or
`font-lock-comment-face' for something comment-like."
  :type 'face
  :group 'difftastic-status)

(defcustom difftastic-status-width 'window
  "Column width passed to difft, controlling where it wraps long lines.

  - `window' (default): fit the current window's width.
  - an integer: use exactly that many columns; a larger value wraps less,
    a smaller value wraps more.

At least `difftastic-status-min-width' columns are always used.  The
`side-by-side' layouts split this width across two columns."
  :type '(choice (const :tag "Fit window width" window)
                 (integer :tag "Fixed number of columns"))
  :group 'difftastic-status)

(defcustom difftastic-status-min-width 40
  "Minimum column width requested from difft (see `difftastic-status-width')."
  :type 'integer
  :group 'difftastic-status)

(defun difftastic-status--width ()
  "Width in columns to request from difft for the current buffer."
  (max difftastic-status-min-width
       (if (integerp difftastic-status-width)
           difftastic-status-width
         (- (window-body-width (get-buffer-window (current-buffer) t)) 2))))

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
                ;; routes through difftastic.  We append `--display' per
                ;; `difftastic-status-display'.
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

(defun difftastic-status-visit-file-dwim (&optional display)
  "Visit the file enclosing point, jumping to the chunk's exact change.
When on a chunk, jump to the line and column of its first new-side change
\(via `difft --display json'); falls back to the chunk's stored gutter line.
On a file heading (not a chunk), behaves as if point were on the file's first
chunk.  DISPLAY, when `other-window' or `other-frame', visits the file in
another window or frame (mirroring Magit's `*-other-window'/`*-other-frame'
visit commands); otherwise the file is visited in the selected window.

We avoid Magit's own `magit-diff-visit-*' commands here because they expect the
current section to be a real Magit diff/hunk section (with slots like
`from-range'), which our custom `difftastic-hunk' (and difftastic `file')
sections do not have -- calling them signals an `invalid slot' error."
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
        (funcall (pcase display
                   ('other-window #'find-file-other-window)
                   ('other-frame  #'find-file-other-frame)
                   (_             #'find-file))
                 (expand-file-name file (magit-toplevel)))
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
;; For each selected screen row we need its old- and new-side file line numbers.
;; We get them by reusing difftastic's own parser (`difftastic--classify-chunk'
;; + `difftastic--parse-{side-by-side,single-column}-chunk'), which yields, per
;; row, the left (old) and right (new) line numbers regardless of layout and
;; carries numbers across wrapped (`.') rows.  Non-nil left numbers go into the
;; selected OLD set, non-nil right numbers into the selected NEW set; collecting
;; an unchanged context row's numbers is harmless because the patch builder only
;; keeps git `-'/`+' lines whose numbers are actually selected.
;;
;; We then transform git's own diff hunks the same way
;; `magit-diff-hunk-region-patch' does: keep context and selected +/- lines,
;; turn unselected lines whose marker matches OP into context, drop the rest.
;; `diff-fixup-modifs' recomputes the @@ counts and
;; `magit-apply--adjust-hunk-new-starts' fixes the new-starts.
;;
;; `difftastic-status--line-side+num' is a legacy inline-only fallback for
;; difftastic versions that don't expose the parser.

(defun difftastic-status--line-side+num (line)
  "Classify difft inline display LINE; return (SIDE . NUM) or nil.
SIDE is `old' or `new'; NUM is the 1-based file line."
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

(defun difftastic-status--parse-chunk-bounds (beg end)
  "Return difftastic's per-line parse for the chunk between BEG and END, or nil.
Each element is (BEG-END LEFT RIGHT): BEG-END is (BOL EOL); LEFT and RIGHT are
each (LINE-NUM BEG END) or nil.  Returns nil when difftastic's parser is
unavailable, so callers can fall back."
  ;; difftastic's parsers skip the first line of the bounds (in difft's own
  ;; output that is the `FILE --- N/M --- LANG' header; here it is our heading),
  ;; so BEG must be the chunk heading line's start.
  (when (and (fboundp 'difftastic--classify-chunk)
             (fboundp 'difftastic--parse-side-by-side-chunk)
             (fboundp 'difftastic--parse-single-column-chunk))
    (let ((bounds (cons beg end)))
      (ignore-errors
        (pcase (difftastic--classify-chunk bounds)
          ('side-by-side  (difftastic--parse-side-by-side-chunk bounds))
          ('single-column (difftastic--parse-single-column-chunk bounds)))))))

(defun difftastic-status--parse-chunk-lines (section)
  "Return difftastic's per-line parse of chunk SECTION, or nil.
See `difftastic-status--parse-chunk-bounds'."
  (difftastic-status--parse-chunk-bounds (oref section start) (oref section end)))

(defun difftastic-status--hide-line-numbers (beg end)
  "Visually blank difft's line-number gutters in the chunk between BEG and END.
The underlying buffer text is left intact, so staging is unaffected.  No-op
when difftastic's parser is unavailable."
  ;; Cover each line-number span with an equal-width run of spaces via a
  ;; `display' property, so columns stay aligned while the numbers disappear.
  (dolist (line (difftastic-status--parse-chunk-bounds beg end))
    (pcase-let ((`(,_ ,left ,right) line))
      (dolist (cell (list left right))
        (pcase cell
          (`(,_ ,nbeg ,nend)
           (when (and (integerp nbeg) (integerp nend) (< nbeg nend))
             (put-text-property nbeg nend 'display
                                (make-string (- nend nbeg) ?\s)))))))))

(defun difftastic-status--region-selected-lines (section)
  "Return (OLD-LINES . NEW-LINES) selected by the active region within SECTION.
The region is clamped to SECTION's body and snapped to whole lines."
  ;; Read line numbers via difftastic's parser (correct for inline and either
  ;; side-by-side layout, including wrapped rows): each row overlapping the
  ;; region contributes its non-nil left number to OLD and right to NEW.  Fall
  ;; back to the inline-only heuristic when the parser is unavailable.
  (let ((beg (max (region-beginning)
                  (or (oref section content) (oref section start))))
        (end (min (region-end) (oref section end)))
        (old nil) (new nil))
    (when (< beg end)
      (if-let* ((lines (difftastic-status--parse-chunk-lines section)))
          (dolist (l lines)
            (pcase-let ((`((,bol ,eol) ,left ,right) l))
              ;; Include a row when it overlaps the (whole-line) region.
              (when (and (< bol end) (> eol beg))
                (when (car left)  (push (car left) old))
                (when (car right) (push (car right) new)))))
        ;; Legacy fallback (inline only).
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
            (forward-line)))))
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

(defun difftastic-status--on-difftastic-section-p ()
  "Non-nil when point is on a difftastic chunk or difftastic `file' section."
  (or (difftastic-status--current-chunk)
      (difftastic-status--first-chunk
       (difftastic-status--enclosing-file-section))))

(defun difftastic-status--visit-advice (orig &rest args)
  "Around-advice for the same-window Magit visit commands (see commentary).
On a difftastic chunk or `file' section, visit via
`difftastic-status-visit-file-dwim'; otherwise call ORIG with ARGS.  Magit's own
visit commands expect a real diff/hunk section (with slots like `from-range')
that our custom sections lack, so calling them would signal an `invalid slot'
error."
  (if (difftastic-status--on-difftastic-section-p)
      (difftastic-status-visit-file-dwim)
    (apply orig args)))

(defun difftastic-status--visit-other-window-advice (orig &rest args)
  "Like `difftastic-status--visit-advice', but visiting in another window."
  (if (difftastic-status--on-difftastic-section-p)
      (difftastic-status-visit-file-dwim 'other-window)
    (apply orig args)))

(defun difftastic-status--visit-other-frame-advice (orig &rest args)
  "Like `difftastic-status--visit-advice', but visiting in another frame."
  (if (difftastic-status--on-difftastic-section-p)
      (difftastic-status-visit-file-dwim 'other-frame)
    (apply orig args)))

(defconst difftastic-status--advices
  ;; These commands have simple (non-prompting) interactive forms, so advising
  ;; them is transparent.  We intentionally do NOT advise `magit-stage-files'/
  ;; `magit-unstage-files' (what `magit-mode-map' binds `s'/`u' to): their
  ;; interactive forms prompt for files, which would pop a prompt even when we
  ;; just want to stage the chunk.  Instead the `s'/`u'/`x' keys are bound
  ;; explicitly per evil state (see `difftastic-status--set-evil-keys').
  ;;
  ;; The whole `magit-diff-visit-*' family is intercepted: depending on the
  ;; keybinding setup, `RET'/`C-j' on a file heading or chunk can resolve to any
  ;; of these (e.g. evil-collection binds `RET' to `magit-diff-visit-worktree-file'
  ;; and vanilla Magit binds `C-j'/`C-<return>' to it), and each would read hunk
  ;; slots our sections lack.  Commands that may be absent on older Magit are
  ;; guarded by `fboundp' where they are advised (see `difftastic-status-mode').
  '((magit-stage        . difftastic-status--stage-advice)
    (magit-unstage      . difftastic-status--unstage-advice)
    (magit-discard      . difftastic-status--discard-advice)
    (magit-delete-thing . difftastic-status--discard-advice)
    (magit-visit-thing  . difftastic-status--visit-advice)
    (magit-diff-visit-file                       . difftastic-status--visit-advice)
    (magit-diff-visit-worktree-file              . difftastic-status--visit-advice)
    (magit-diff-visit-file-other-window          . difftastic-status--visit-other-window-advice)
    (magit-diff-visit-worktree-file-other-window . difftastic-status--visit-other-window-advice)
    (magit-diff-visit-file-other-frame           . difftastic-status--visit-other-frame-advice)
    (magit-diff-visit-worktree-file-other-frame  . difftastic-status--visit-other-frame-advice))
  "Alist of (MAGIT-COMMAND . ADVICE) intercepted while on a difftastic section.")

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
      (magit-insert-section section
          (difftastic-hunk
           (list :file file :index index
                 :diff-args (plist-get context :diff-args)
                 :staged (plist-get context :staged)
                 :stageable (plist-get context :stageable)
                 :line (and start (string-to-number start)))
           nil
           ;; Match Magit's hunk highlighting: when point is on the chunk, its
           ;; heading gets `magit-diff-hunk-heading-highlight' (and the selection
           ;; face for multi-chunk regions), exactly like a `magit-hunk-section'.
           :heading-highlight-face 'magit-diff-hunk-heading-highlight
           :heading-selection-face 'magit-diff-hunk-heading-selection)
        ;; Set the section keymap here rather than via `magit-insert-section':
        ;; the base `magit-section' `keymap' slot has no initarg, so passing
        ;; `:keymap' would signal `invalid-slot-name'.  It is applied later in
        ;; `magit-insert-section--finish', after this body runs.
        (oset section keymap 'difftastic-status-hunk-section-map)
        ;; Remember where the heading begins: difftastic's line-number parser
        ;; (used to hide the gutters) treats the first line of its bounds as the
        ;; chunk header, which is exactly this heading.
        (let ((heading-start (point)))
          (magit-insert-heading
            ;; Include the newline in the faced string (as Magit does for its own
            ;; hunk headings) so a face with `:extend t' -- e.g. the default
            ;; `magit-diff-hunk-heading' -- fills the heading bar to the window edge.
            (propertize (concat heading "\n")
                        'font-lock-face difftastic-status-chunk-heading-face))
          (dolist (l body-lines)
            (insert l "\n"))
          (unless difftastic-status-line-numbers
            (difftastic-status--hide-line-numbers heading-start (point))))))))

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

(defun difftastic-status--file-statuses (diff-args)
  "Return an alist of (PATH . (STATUS . ORIG)) for the DIFF-ARGS diff.
DIFF-ARGS is the leading git invocation (see
`difftastic-status--file-diff-string'); `--name-status' is appended so each
file's status can be read without rendering a diff.  STATUS is Magit's own
status word (\"modified\", \"new file\", \"deleted\" or \"renamed\") and ORIG is
the source path for a rename (else nil).  Used so our difftastic file headings
mimic Magit's exactly, and to collapse deleted-file sections like Magit does."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil
           (append diff-args '("--name-status")))
    (let (statuses)
      (dolist (line (split-string (buffer-string) "\n" t))
        ;; A status line is "<CODE>\t<PATH>", except rename/copy which is
        ;; "<CODE>\t<OLD>\t<NEW>"; CODE's first letter is the change kind.
        (let* ((fields (split-string line "\t"))
               (code (car fields)))
          (when (and code (> (length code) 0) (cadr fields))
            (pcase (aref code 0)
              (?A (push (cons (cadr fields) (cons "new file" nil)) statuses))
              (?D (push (cons (cadr fields) (cons "deleted" nil)) statuses))
              ;; Magit shows copies as "new file"; renames as "renamed".
              (?C (when (nth 2 fields)
                    (push (cons (nth 2 fields) (cons "new file" (cadr fields)))
                          statuses)))
              (?R (when (nth 2 fields)
                    (push (cons (nth 2 fields) (cons "renamed" (cadr fields)))
                          statuses)))
              (_  (push (cons (cadr fields) (cons "modified" nil)) statuses))))))
      statuses)))

(defun difftastic-status--file-heading (file status orig)
  "Return the heading string for FILE, mimicking Magit's `file' section heading.
STATUS is Magit's status word and ORIG the rename source (or nil); see
`difftastic-status--file-statuses'.  Uses `magit-format-file' (so any
icon/format customization applies) with the `magit-diff-file-heading' face, and
falls back to a `magit-format-file-default'-style string on older Magit."
  (let ((orig (and orig (not (equal orig file)) orig)))
    (if (fboundp 'magit-format-file)
        (magit-format-file 'diff file 'magit-diff-file-heading status orig)
      (propertize (concat (and status (format "%-11s" status))
                          (if orig (format "%s -> %s" orig file) file))
                  'font-lock-face 'magit-diff-file-heading))))

(defvar-local difftastic-status--stock-files nil
  "List of repo-relative paths to render with stock Magit, not difftastic.
Buffer-local to each Magit buffer.  Toggled per file by
`difftastic-status-toggle-file-rendering' (which see); a file in this list is
rendered with Magit's own `file'/`hunk' sections -- so Magit's native per-hunk
and per-line staging applies -- instead of difftastic chunks.")

(defun difftastic-status--insert-stock-file (file context)
  "Render FILE with stock Magit `file'/`hunk' sections, not difftastic.
CONTEXT's `:stock-args' is the git invocation Magit's `magit--insert-diff'
expects (see the context constructors); the `-- FILE' pathspec is appended.
This produces real `magit-file-section'/`magit-hunk-section's, so Magit's native
staging and visibility apply unchanged.  Falls back to difftastic rendering if
`magit--insert-diff' is unavailable."
  (if (and (fboundp 'magit--insert-diff)
           (plist-get context :stock-args))
      (progn
        (magit--insert-diff t (plist-get context :stock-args) "--" file)
        ;; `magit-diff-wash-diffs' appends a trailing blank line after the file
        ;; section (in stock Magit that is the single separator after the whole
        ;; diff block).  We insert one file at a time, so drop it to keep stock
        ;; files contiguous like the difftastic ones; the surrounding inserter
        ;; adds the one separator after the group.
        (when (and (eq (char-before) ?\n)
                   (eq (char-before (1- (point))) ?\n))
          (delete-char -1)))
    (difftastic-status--insert-difftastic-file
     file context
     (difftastic-status--file-statuses (plist-get context :diff-args)))))

(defun difftastic-status--insert-difftastic-file (file context statuses)
  "Insert the difftastic `file' section for FILE using CONTEXT.
STATUSES is the (PATH . (STATUS . ORIG)) alist for this diff (see
`difftastic-status--file-statuses'); it drives the Magit-matching file heading
and the Magit-matching initial visibility (deleted files start collapsed).  This
is the default rendering; see `difftastic-status--insert-file-sections'."
  (let* ((diff-args (plist-get context :diff-args))
         (info (cdr (assoc file statuses)))
         (status (or (car info) "modified"))
         (orig (cdr info)))
    (magit-insert-section (file file (or (equal status "deleted")
                                         (derived-mode-p 'magit-status-mode)))
      (magit-insert-heading
        (difftastic-status--file-heading file status orig))
      (difftastic-status--insert-chunks
       (difftastic-status--file-diff-string file diff-args)
       file context))))

(defun difftastic-status--insert-file-sections (files context)
  "Insert a collapsible difftastic `file' section for each of FILES.
Files are contiguous (no blank line between them); the only blank line is
inserted after the whole section (see the top-level inserters).
CONTEXT is a diff context plist with the entries:
  :diff-args  the leading git invocation selecting the diff to render
              (see `difftastic-status--file-diff-string');
  :stock-args the git invocation Magit's `magit--insert-diff' expects to render
              the same diff with stock Magit sections (see
              `difftastic-status--insert-stock-file');
  :staged     non-nil when the diff is the index against HEAD;
  :stageable  non-nil when per-chunk staging is meaningful in this buffer.
It is threaded down to every chunk section so the staging commands can rebuild
the corresponding git hunk.

A file listed in `difftastic-status--stock-files' is rendered with stock Magit
sections instead of difftastic chunks (toggle per file with
`difftastic-status-toggle-file-rendering').

Initial visibility mirrors Magit: a file section starts collapsed in
`magit-status-mode' buffers (and for deleted files everywhere), and expanded in
the diff/revision buffers.  The chunk sections are always inserted expanded, so
expanding a file reveals its hunk(s) -- the same way a single-hunk file feels
like it expands straight to its diff in Magit."
  ;; Read each file's status once for the whole group (only the difftastic path
  ;; needs it: for the Magit-matching heading and initial visibility).
  (let ((statuses (and (cl-some (lambda (f)
                                  (not (member f difftastic-status--stock-files)))
                                files)
                       (difftastic-status--file-statuses
                        (plist-get context :diff-args)))))
    (dolist (file files)
      (if (member file difftastic-status--stock-files)
          (difftastic-status--insert-stock-file file context)
        (difftastic-status--insert-difftastic-file file context statuses)))))

(defun difftastic-status--context-unstaged ()
  "Diff context plist for the worktree-vs-index (unstaged) diff."
  (list :diff-args difftastic-status--diff-base
        :stock-args '("diff" "-p" "--no-prefix")
        :staged nil :stageable t))

(defun difftastic-status--context-staged ()
  "Diff context plist for the index-vs-HEAD (staged) diff."
  (list :diff-args (append difftastic-status--diff-base '("--cached"))
        :stock-args '("diff" "-p" "--no-prefix" "--cached")
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

(defun difftastic-status-toggle-file-rendering ()
  "Toggle the file at point between difftastic and stock Magit rendering.
Works on a difftastic file heading or chunk, and on a stock Magit file/hunk
section (to switch back).  A toggled-to-stock file is rendered with Magit's own
`file'/`hunk' sections, so Magit's native per-hunk and per-line staging applies
to it; toggling back restores the difftastic chunks.  The choice is buffer-local
\(see `difftastic-status--stock-files') and survives refreshes."
  (interactive)
  (if-let* ((file (difftastic-status--enclosing-file)))
      (progn
        (setq difftastic-status--stock-files
              (if (member file difftastic-status--stock-files)
                  (remove file difftastic-status--stock-files)
                (cons file difftastic-status--stock-files)))
        (magit-refresh)
        (message "%s now rendered with %s"
                 file
                 (if (member file difftastic-status--stock-files)
                     "stock Magit" "difftastic")))
    (user-error "Point is not on a file in a difftastic-status section")))

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
             (stock-args (append '("diff" "-p" "--no-prefix") selector))
             (context
              (cond
               ((and (null range) (equal typearg "--cached"))
                (list :diff-args (append difftastic-status--diff-base selector)
                      :stock-args stock-args :staged t :stageable t))
               ((and (null range) (null typearg))
                (list :diff-args difftastic-status--diff-base
                      :stock-args stock-args :staged nil :stageable t))
               (t
                (list :diff-args (append difftastic-status--diff-base selector)
                      :stock-args stock-args :staged nil :stageable nil))))
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
                          :stock-args (append '("show" "-p" "--format=" "--no-prefix")
                                              (list commit))
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

(defcustom difftastic-status-toggle-rendering-key "C-c C-d"
  "Key bound on difftastic-status sections to toggle a file's rendering.
A key sequence in `kbd' syntax, bound to
`difftastic-status-toggle-file-rendering' while `difftastic-status-mode' is
enabled, so the file at point can be switched between difftastic and stock Magit
rendering (and back).  Set to nil to bind no key.  Changing this takes effect
the next time the mode is toggled."
  :type '(choice (const :tag "No binding" nil)
                 (string :tag "Key"))
  :group 'difftastic-status)

(defvar difftastic-status-hunk-section-map
  (make-sparse-keymap)
  "Keymap installed on difftastic chunk (`difftastic-hunk') sections.
Attached via each section's `:keymap' slot (see
`difftastic-status--insert-chunk').  `difftastic-status-mode' adds
`difftastic-status-toggle-rendering-key' here while enabled; unbound keys fall
through to the Magit maps as usual.")

(defun difftastic-status--set-toggle-key (enable)
  "Bind (ENABLE non-nil) or unbind the file-rendering toggle key.
The key is `difftastic-status-toggle-rendering-key' and the command is
`difftastic-status-toggle-file-rendering'.  We bind it in
`difftastic-status-hunk-section-map' (difftastic chunks) and in Magit's shared
`magit-file-section-map'/`magit-hunk-section-map', so the toggle is reachable
both on difftastic sections and on the stock `file'/`hunk' sections a
toggled-to-stock file produces (difftastic file headings also use
`magit-file-section-map').  The key lives only on these section keymaps, so no
global Magit binding is shadowed."
  (when-let* ((key difftastic-status-toggle-rendering-key)
              ((stringp key))
              (seq (ignore-errors (kbd key))))
    (dolist (map '(difftastic-status-hunk-section-map
                   magit-file-section-map
                   magit-hunk-section-map))
      (when (boundp map)
        ;; Use `define-key'/`kbd' (not `keymap-set'/`keymap-unset') to keep the
        ;; Emacs 28.1 minimum; a nil definition removes our binding (the key is
        ;; not otherwise bound in these maps, so this leaves them as before).
        (define-key (symbol-value map) seq
                    (and enable #'difftastic-status-toggle-file-rendering))))))

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
works.

`difftastic-status-toggle-rendering-key' is bound on the difftastic and stock
sections to `difftastic-status-toggle-file-rendering', which switches the file
at point between difftastic and stock Magit rendering (a stock-rendered file
uses Magit's native per-hunk/line staging)."
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
          ;; Some `magit-diff-visit-*' variants may be absent on older Magit.
          (when (fboundp cmd)
            (advice-add cmd :around advice)))
        (difftastic-status--set-evil-keys t)
        (difftastic-status--set-toggle-key t))
    (advice-remove 'magit-insert-unstaged-changes
                   #'difftastic-status-insert-unstaged-changes)
    (advice-remove 'magit-insert-staged-changes
                   #'difftastic-status-insert-staged-changes)
    (advice-remove 'magit-insert-diff
                   #'difftastic-status--insert-diff-advice)
    (advice-remove 'magit-insert-revision-diff
                   #'difftastic-status--insert-revision-diff-advice)
    (pcase-dolist (`(,cmd . ,advice) difftastic-status--advices)
      (when (fboundp cmd)
        (advice-remove cmd advice)))
    (difftastic-status--set-evil-keys nil)
    (difftastic-status--set-toggle-key nil))
  ;; Refresh any visible status/diff/revision buffers so the change is
  ;; immediately visible (`magit-revision-mode' derives from `magit-diff-mode').
  (when (fboundp 'magit-refresh)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'magit-status-mode 'magit-diff-mode)
          (magit-refresh))))))

(provide 'difftastic-status)
;;; difftastic-status.el ends here
