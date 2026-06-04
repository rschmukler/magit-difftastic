;;; magit-difftastic.el --- Difftastic-rendered, stageable sections in Magit -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Ryan Schmukler

;; Author: Ryan Schmukler
;; URL: https://github.com/rschmukler/magit-difftastic
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
;; The package provides `magit-difftastic-mode', a global minor mode.  When
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
;; integrations can be scoped with `magit-difftastic-diff-buffers' and
;; `magit-difftastic-revision-buffers' (both default on); anything difftastic
;; cannot render -- `--no-index' diffs, merge commits shown as combined diffs --
;; falls straight back to Magit's stock rendering.
;;
;; Rendering can also be toggled per file: with point on a file (or chunk),
;; `magit-difftastic-toggle-file-rendering' (bound to
;; `magit-difftastic-toggle-rendering-key', \\`C-c C-d' by default) switches
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
;;   each chunk becomes its own collapsible `magit-difftastic-hunk' sub-section with a
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
;;   Chunk sub-sections are a CUSTOM type (`magit-difftastic-hunk'), deliberately not
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
;; Toggle with `magit-difftastic-mode' (global).  When off, Magit's
;; stock unstaged/staged sections are used, so you can always fall back.

;;; Code:

(require 'cl-lib)
(require 'magit)
(require 'difftastic)

(defgroup magit-difftastic nil
  "Difftastic-rendered, stageable sections in `magit-status'."
  :group 'difftastic
  :group 'magit
  :prefix "magit-difftastic-")

(defcustom magit-difftastic-display "side-by-side-show-both"
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
  :group 'magit-difftastic)

(defcustom magit-difftastic-line-numbers t
  "Whether difft's per-line number gutters are shown in rendered chunks.
When nil, the line-number columns are hidden in the status, diff and revision
buffers.  Staging works the same either way."
  :type 'boolean
  :group 'magit-difftastic)

(defcustom magit-difftastic-syntax-highlight t
  "Whether to add major-mode syntax highlighting to rendered chunks.
difft only emphasizes keywords and comments (bold/italic) and colours the
changed tokens; when this is non-nil each chunk's code is additionally
fontified with the file's Emacs major mode, so keywords, strings, types, etc.
get their usual faces.  The diff colours difft applies to changed tokens keep
precedence.

This re-fontifies each rendered file with its major mode, which adds some cost
on top of difft itself; set to nil to turn it off."
  :type 'boolean
  :group 'magit-difftastic)

(defcustom magit-difftastic-chunk-heading-face 'magit-diff-hunk-heading
  "Face used for the per-chunk `@@ line N @@' headings.
Defaults to `magit-diff-hunk-heading', so the headings look like Magit's own
hunk headings (a full-width bar, since that face has `:extend t').  Set to any
face you prefer, e.g. `magit-hash' (the muted face Magit uses for commit hashes)
for understated headings, `magit-section-heading' for a bolder look, or
`font-lock-comment-face' for something comment-like."
  :type 'face
  :group 'magit-difftastic)

(defcustom magit-difftastic-width 'window
  "Column width passed to difft, controlling where it wraps long lines.

  - `window' (default): fit the current window's width.
  - an integer: use exactly that many columns; a larger value wraps less,
    a smaller value wraps more.

At least `magit-difftastic-min-width' columns are always used.  The
`side-by-side' layouts split this width across two columns."
  :type '(choice (const :tag "Fit window width" window)
                 (integer :tag "Fixed number of columns"))
  :group 'magit-difftastic)

(defcustom magit-difftastic-min-width 40
  "Minimum column width requested from difft (see `magit-difftastic-width')."
  :type 'integer
  :group 'magit-difftastic)

(defun magit-difftastic--width ()
  "Width in columns to request from difft for the current buffer."
  (max magit-difftastic-min-width
       (if (integerp magit-difftastic-width)
           magit-difftastic-width
         (- (window-body-width (get-buffer-window (current-buffer) t)) 2))))

(defconst magit-difftastic--diff-base '("--no-pager" "diff" "--ext-diff")
  "Leading git invocation for difftastic `git diff' rendering.
The diff selector (e.g. `--cached', a range) and the `-- FILE' pathspec are
appended to this.")

(defconst magit-difftastic--show-base '("--no-pager" "show" "--ext-diff" "--format=")
  "Leading git invocation for difftastic `git show' (commit) rendering.
The revision and the `-- FILE' pathspec are appended to this.")

(defun magit-difftastic--file-diff-string (file diff-args)
  "Return the difftastic-rendered, fontified diff STRING for FILE.
DIFF-ARGS is the leading git invocation (including `--no-pager', the
subcommand and `--ext-diff') that selects which diff to render; FILE is
appended as a pathspec.  For example, `(\"--no-pager\" \"diff\" \"--ext-diff\"
\"--cached\")' renders the index against HEAD, while
`(\"--no-pager\" \"show\" \"--ext-diff\" \"--format=\" REV)' renders a commit."
  (require 'difftastic)
  (let* ((width (magit-difftastic--width))
         (args (append diff-args (list "--" file)))
         (raw (with-temp-buffer
                ;; `difftastic--build-git-process-environment' sets
                ;; GIT_EXTERNAL_DIFF=difft ... so plain `git diff --ext-diff'
                ;; routes through difftastic.  We append `--display' per
                ;; `magit-difftastic-display'.
                (let ((process-environment
                       (difftastic--build-git-process-environment
                        width (list "--display" magit-difftastic-display))))
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
;; Why one context line (`magit-difftastic-apply-context', default 1) rather
;; than zero?  Zero-context patches REVERSE-apply ambiguously: git cannot tell
;; where to re-insert a deleted line without a neighbouring context line, so
;; unstage/discard of a pure deletion lands in the wrong place.  A single
;; context line disambiguates application (forward AND reverse) while still
;; keeping changes in separate hunks unless they are within two lines of each
;; other.  When several difftastic chunks fall inside one git hunk, staging any
;; of them stages that whole git hunk (the same boundary-snapping that Magit's
;; own hunk staging has).

(defun magit-difftastic--enclosing-file-section ()
  "Return the `file' section enclosing point, if any."
  (let ((s (magit-current-section)))
    (while (and s (not (eq (oref s type) 'file)))
      (setq s (oref s parent)))
    s))

(defun magit-difftastic--enclosing-file ()
  "Return the value (filename) of the `file' section enclosing point, if any."
  (when-let* ((s (magit-difftastic--enclosing-file-section)))
    (oref s value)))

(defun magit-difftastic--first-chunk (file-section)
  "Return the first `magit-difftastic-hunk' child of FILE-SECTION, or nil."
  (and file-section
       (seq-find (lambda (c) (eq (oref c type) 'magit-difftastic-hunk))
                 (oref file-section children))))

(defun magit-difftastic-visit-file-dwim (&optional display)
  "Visit the file enclosing point, jumping to the chunk's exact change.
When on a chunk, jump to the line and column of its first new-side change
\(via `difft --display json'); falls back to the chunk's stored gutter line.
On a file heading (not a chunk), behaves as if point were on the file's first
chunk.  DISPLAY, when `other-window' or `other-frame', visits the file in
another window or frame (mirroring Magit's `*-other-window'/`*-other-frame'
visit commands); otherwise the file is visited in the selected window.

We avoid Magit's own `magit-diff-visit-*' commands here because they expect the
current section to be a real Magit diff/hunk section (with slots like
`from-range'), which our custom `magit-difftastic-hunk' (and difftastic `file')
sections do not have -- calling them signals an `invalid slot' error."
  (interactive)
  (if-let* ((file-section (magit-difftastic--enclosing-file-section)))
      (let* ((file (oref file-section value))
             (chunk (or (magit-difftastic--current-chunk)
                        (magit-difftastic--first-chunk file-section)))
             (val (and chunk (oref chunk value)))
             (line (or (and val (ignore-errors
                                  (magit-difftastic--chunk-visit-line
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

(defcustom magit-difftastic-apply-context 1
  "Number of context lines for the git hunks used to stage/unstage chunks.
Must be >= 1: zero-context patches reverse-apply ambiguously (see commentary
above).  Larger values make application more forgiving but merge nearby
changes into a single stageable hunk."
  :type 'integer
  :group 'magit-difftastic)

(defun magit-difftastic--git-diff-raw (file staged &optional context)
  "Return plain unified diff text for FILE (difftastic disabled).
Uses CONTEXT context lines (default `magit-difftastic-apply-context').
When STAGED is non-nil diff the index against HEAD."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil
           (append (list "--no-pager" "diff" "--no-ext-diff"
                         (format "-U%d" (or context magit-difftastic-apply-context)))
                   (when staged '("--cached"))
                   (list "--" file)))
    (buffer-string)))

(defun magit-difftastic--parse-diff (diff)
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

(defun magit-difftastic--chunk-json (file diff-args index)
  "Return difft's JSON rows (a list) for chunk INDEX of FILE, or nil.
Each row is an alist with `lhs'/`rhs' entries.  DIFF-ARGS is the leading git
invocation that selects the diff (see `magit-difftastic--file-diff-string')."
  (require 'difftastic)
  (let* ((width (magit-difftastic--width))
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

(defun magit-difftastic--json-chunk-lines (file diff-args index)
  "Return (OLD-LINES . NEW-LINES), 1-indexed, for difft chunk INDEX of FILE.
OLD-LINES/NEW-LINES are the lhs/rhs line numbers difftastic reports for the
changed rows of that chunk.  DIFF-ARGS selects the diff (see
`magit-difftastic--file-diff-string')."
  (let ((chunk (magit-difftastic--chunk-json file diff-args index))
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

(defun magit-difftastic--chunk-visit-line (file diff-args index)
  "Return the 1-based line of chunk INDEX's first change in FILE, or nil.
Prefers the first new-side (rhs) line so visiting lands exactly on the change
in the worktree; falls back to the first old-side (lhs) line for a pure
deletion.  DIFF-ARGS selects the diff (see
`magit-difftastic--file-diff-string').

\(We deliberately do not try to compute a column: difft only marks changed
tokens for recognized languages -- for plain text every span is `normal' --
so a JSON-derived column would be misleading.  Visiting lands on the line and
its first non-whitespace character instead.)"
  (let ((chunk (magit-difftastic--chunk-json file diff-args index)))
    (cl-flet ((first-line (side)
                (cl-loop for row in chunk
                         for s = (alist-get side row)
                         for ln = (and s (alist-get 'line_number s))
                         for changes = (and s (alist-get 'changes s))
                         when (and (numberp ln) changes)
                         return (1+ ln))))
      (or (first-line 'rhs) (first-line 'lhs)))))

(defun magit-difftastic--hunk-covers-p (hunk old-lines new-lines)
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

(defun magit-difftastic--chunk-patch (section)
  "Build a standalone git patch string for the chunk SECTION, or nil.
The patch contains the file header plus exactly the git hunk(s) that the
difftastic chunk maps onto."
  (let* ((val (oref section value))
         (file (plist-get val :file))
         (index (plist-get val :index))
         (staged (plist-get val :staged))
         (diff-args (plist-get val :diff-args))
         (parsed (magit-difftastic--parse-diff (magit-difftastic--git-diff-raw file staged)))
         (header (car parsed))
         (hunks (cdr parsed))
         (lines (magit-difftastic--json-chunk-lines file diff-args index))
         (matched (cl-remove-if-not
                   (lambda (h) (magit-difftastic--hunk-covers-p h (car lines) (cdr lines)))
                   hunks)))
    (when (and (not (string-empty-p header)) matched)
      (concat header (mapconcat (lambda (h) (plist-get h :text)) matched "")))))

(defun magit-difftastic--apply-chunk-patch (patch &rest apply-args)
  "Apply PATCH via `git apply APPLY-ARGS -' (reading PATCH on stdin) and refresh."
  (with-temp-buffer
    (insert patch)
    (let ((magit-inhibit-refresh t))
      (apply #'magit-run-git-with-input "apply" (append apply-args '("-")))))
  (magit-refresh))

(defun magit-difftastic--current-chunk ()
  "Return the difftastic chunk section at point, or nil."
  (let ((s (magit-current-section)))
    (and s (eq (oref s type) 'magit-difftastic-hunk) s)))

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
;; `magit-difftastic--line-side+num' is a legacy inline-only fallback for
;; difftastic versions that don't expose the parser.

(defun magit-difftastic--line-side+num (line)
  "Classify difft inline display LINE; return (SIDE . NUM) or nil.
SIDE is `old' or `new'; NUM is the 1-based file line."
  (cond
   ((string-match "\\`\\([0-9]+\\)" line)
    (cons 'old (string-to-number (match-string 1 line))))
   ((string-match "\\`[ \t]+\\([0-9]+\\)" line)
    (cons 'new (string-to-number (match-string 1 line))))))

(defun magit-difftastic--region-active-p (section)
  "Return non-nil if the region is active and overlaps SECTION's body."
  (and (region-active-p)
       (< (region-beginning) (oref section end))
       (> (region-end) (or (oref section content) (oref section start)))))

(defun magit-difftastic--chunk-layout (beg end)
  "Return the layout of the chunk BEG..END: `single-column' or `side-by-side'.
Driven by `magit-difftastic-display', which we control and is therefore
reliable: `inline' is always single column and `side-by-side-show-both' always
two.  Only the plain `side-by-side' mode -- where difft may collapse a chunk
that is purely additions or removals to a single column -- consults difftastic's
own (heuristic) classifier."
  (cond
   ((equal magit-difftastic-display "inline") 'single-column)
   ((equal magit-difftastic-display "side-by-side-show-both") 'side-by-side)
   ((and (fboundp 'difftastic--classify-chunk)
         (ignore-errors (difftastic--classify-chunk (cons beg end)))))
   (t 'side-by-side)))

(defun magit-difftastic--parse-chunk-bounds (beg end)
  "Return difftastic's per-line parse for the chunk between BEG and END, or nil.
Each element is (BEG-END LEFT RIGHT): BEG-END is (BOL EOL); LEFT and RIGHT are
each (LINE-NUM BEG END) or nil.  Returns nil when difftastic's parser is
unavailable, so callers can fall back."
  ;; difftastic's parsers skip the first line of the bounds (in difft's own
  ;; output that is the `FILE --- N/M --- LANG' header; here it is our heading),
  ;; so BEG must be the chunk heading line's start.
  (when (and (fboundp 'difftastic--parse-side-by-side-chunk)
             (fboundp 'difftastic--parse-single-column-chunk))
    (let ((bounds (cons beg end)))
      (ignore-errors
        (pcase (magit-difftastic--chunk-layout beg end)
          ('side-by-side  (difftastic--parse-side-by-side-chunk bounds))
          ('single-column (difftastic--parse-single-column-chunk bounds)))))))

(defun magit-difftastic--parse-chunk-lines (section)
  "Return difftastic's per-line parse of chunk SECTION, or nil.
See `magit-difftastic--parse-chunk-bounds'."
  (magit-difftastic--parse-chunk-bounds (oref section start) (oref section end)))

(defun magit-difftastic--hide-line-numbers (beg end)
  "Visually blank difft's line-number gutters in the chunk between BEG and END.
The underlying buffer text is left intact, so staging is unaffected.  No-op
when difftastic's parser is unavailable."
  ;; Cover each line-number span with an equal-width run of spaces via a
  ;; `display' property, so columns stay aligned while the numbers disappear.
  (dolist (line (magit-difftastic--parse-chunk-bounds beg end))
    (pcase-let ((`(,_ ,left ,right) line))
      (dolist (cell (list left right))
        (pcase cell
          (`(,_ ,nbeg ,nend)
           (when (and (integerp nbeg) (integerp nend) (< nbeg nend))
             (put-text-property nbeg nend 'display
                                (make-string (- nend nbeg) ?\s)))))))))

;;; Syntax highlighting
;;
;; difft only emphasizes keywords/comments (bold/italic) and colours changed
;; tokens; it does not colour by token type.  To add real syntax highlighting we
;; layer the file's Emacs major-mode font-lock faces onto each chunk's code.
;;
;; We do not need the original blobs from git.  difft renders the actual code
;; text for every shown row (changed and context), so per chunk we:
;;
;;   1. find each row's code span(s) and source line number(s) per side, using
;;      difftastic's own parser/classifier (so inline and both side-by-side
;;      layouts, including wrapped rows, are handled uniformly);
;;   2. reconstruct each side's source text from those very spans (joining
;;      wrapped rows back into one line) and fontify it with the major mode;
;;   3. copy the resulting face runs back onto the rendered spans, APPENDED so
;;      difft's diff colours keep precedence over the syntax colour.
;;
;; Because the reconstructed text is built from the same spans we paint, the
;; mapping is exact -- no fuzzy column alignment is needed.

(defun magit-difftastic--mode-for-file (file)
  "Return the major-mode function Emacs would use for FILE, or nil.
Only a callable mode symbol is returned; `fundamental-mode' and non-symbol
entries yield nil (nothing to highlight)."
  (let ((mode (let ((case-fold-search (memq system-type
                                            '(windows-nt cygwin darwin))))
                (assoc-default file auto-mode-alist #'string-match))))
    (when (consp mode) (setq mode (car mode)))
    (and mode (symbolp mode) (fboundp mode)
         (not (eq mode 'fundamental-mode))
         mode)))

(defvar magit-difftastic--single-column-gutter-re nil
  "Cached regexp matching difft's two-column inline gutter (or nil).")

(defun magit-difftastic--single-column-gutter-re ()
  "Return a regexp matching difft's inline (single-column) gutter, or nil.
Built from difftastic's own line-number rx so the code column starts exactly
where difft puts it; nil when difftastic does not expose that rx."
  (or magit-difftastic--single-column-gutter-re
      (and (fboundp 'difftastic--line-num-or-spaces-rx)
           (boundp 'difftastic--line-num-digits)
           (setq magit-difftastic--single-column-gutter-re
                 (ignore-errors
                   (rx-to-string
                    `(seq bol
                          ,(difftastic--line-num-or-spaces-rx
                            difftastic--line-num-digits)
                          ,(difftastic--line-num-or-spaces-rx
                            difftastic--line-num-digits))
                    t))))))

(defun magit-difftastic--code-span (side num beg end)
  "Return (SIDE NUM BEG END') for code BEG..END with trailing blanks trimmed.
Trimming drops difft's inter-column padding so only the code text remains."
  (let ((e end))
    (while (and (> e beg) (memq (char-after (1- e)) '(?\s ?\t)))
      (setq e (1- e)))
    (list side num beg e)))

(defun magit-difftastic--syntax-entries (beg end)
  "Return per-row code spans for the chunk between BEG and END.
Each element is (SIDE NUM CODE-BEG CODE-END): SIDE is `old' or `new', NUM the
1-based source line, and CODE-BEG..CODE-END the buffer span of that row's code
for that side (gutter excluded).  Entries are in display order."
  (let ((layout (magit-difftastic--chunk-layout beg end))
        (lines (magit-difftastic--parse-chunk-bounds beg end))
        entries)
    (pcase layout
      ('side-by-side
       (dolist (l lines)
         (pcase-let ((`((,_bol ,eol) ,left ,right) l))
           (when (car left)
             (push (magit-difftastic--code-span
                    'old (car left) (1+ (caddr left))
                    (if (cadr right) (cadr right) eol))
                   entries))
           (when (car right)
             (push (magit-difftastic--code-span
                    'new (car right) (1+ (caddr right)) eol)
                   entries)))))
      ('single-column
       (let ((re (magit-difftastic--single-column-gutter-re)))
         (dolist (l lines)
           (pcase-let ((`((,bol ,eol) ,left ,right) l))
             (let ((side (if (car left) 'old 'new))
                   (num (or (car left) (car right)))
                   (cb (save-excursion
                         (goto-char bol)
                         (if (and re (looking-at re))
                             (match-end 0)
                           (1+ (caddr (or left right)))))))
               (when num
                 (push (magit-difftastic--code-span side num cb eol)
                       entries))))))))
    (nreverse entries)))

(defun magit-difftastic--fontify-string (mode text)
  "Return TEXT fontified with major MODE as a propertized string, or nil.
Runs MODE in a temp buffer with hooks suppressed and `font-lock-ensure'."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (let ((inhibit-message t)
              (message-log-max nil))
          (delay-mode-hooks (funcall mode))
          (font-lock-mode 1)
          (font-lock-ensure))
        (buffer-string))
    (error nil)))

;; difft applies its colours via the `font-lock-face' property (so they survive
;; font-lock), NOT `face'.  We therefore layer the syntax colour onto
;; `font-lock-face' as well, otherwise it would be invisible (or stripped by
;; font-lock) in Magit buffers.

(defun magit-difftastic--face-list (val)
  "Normalize a `font-lock-face' VAL to a list of face specs."
  (cond ((null val) nil)
        ((keywordp (car-safe val)) (list val)) ; a single anonymous (plist) face
        ((listp val) val)                      ; already a list of specs
        (t (list val))))                       ; a face symbol

(defun magit-difftastic--strip-unspecified (plist)
  "Return anonymous-face PLIST without difft's `unspecified-fg/bg' placeholders.
difft marks emphasis-only (bold/italic) tokens with `:foreground
\"unspecified-fg\"'; dropping it lets the syntax colour show through while real
diff colours (a concrete foreground) are kept."
  (let (out)
    (while plist
      (let ((k (car plist)) (v (cadr plist)))
        (unless (or (and (eq k :foreground) (equal v "unspecified-fg"))
                    (and (eq k :background) (equal v "unspecified-bg")))
          (setq out (append out (list k v)))))
      (setq plist (cddr plist)))
    out))

(defun magit-difftastic--merge-face (existing syntax)
  "Return a `font-lock-face' value layering SYNTAX under EXISTING (difft's).
EXISTING keeps precedence, so a changed token's diff colour wins; SYNTAX fills
in where difft left the foreground unspecified."
  (let ((cleaned (delq nil
                       (mapcar (lambda (e)
                                 (if (and (consp e) (keywordp (car e)))
                                     (magit-difftastic--strip-unspecified e)
                                   e))
                               (magit-difftastic--face-list existing)))))
    (append cleaned (list syntax))))

(defun magit-difftastic--apply-face (beg end syntax)
  "Layer the SYNTAX face under any existing difft `font-lock-face' in BEG..END."
  (let ((pos beg))
    (while (< pos end)
      (let ((nxt (or (next-single-property-change pos 'font-lock-face nil end)
                     end))
            (cur (get-text-property pos 'font-lock-face)))
        (put-text-property pos nxt 'font-lock-face
                           (magit-difftastic--merge-face cur syntax))
        (setq pos nxt)))))

(defun magit-difftastic--copy-faces (src src-off len disp-beg)
  "Copy font-lock face runs from SRC[SRC-OFF..SRC-OFF+LEN) onto DISP-BEG.
SRC is a string fontified by the major mode (faces on its `face' property);
each run is layered onto the display's `font-lock-face' (see
`magit-difftastic--apply-face')."
  (let ((spos src-off)
        (send (+ src-off len))
        (dpos disp-beg))
    (while (< spos send)
      (let* ((nxt (or (next-single-property-change spos 'face src send) send))
             (face (get-text-property spos 'face src))
             (n (- nxt spos)))
        (when face
          (magit-difftastic--apply-face dpos (+ dpos n) face))
        (setq spos nxt dpos (+ dpos n))))))

(defun magit-difftastic--apply-syntax-side (mode entries)
  "Fontify ENTRIES (all one side) with MODE and paint their faces back.
ENTRIES is a list of (SIDE NUM CODE-BEG CODE-END); rows sharing NUM (difft's
wrapped continuations) are joined into one logical source line."
  (let ((src "")
        (placements nil)
        (prev-num nil))
    (pcase-dolist (`(,_side ,num ,cb ,ce) entries)
      (when (and prev-num (not (eql num prev-num)))
        (setq src (concat src "\n")))
      (let ((src-off (length src))
            (text (buffer-substring-no-properties cb ce)))
        (setq src (concat src text))
        (push (list cb (- ce cb) src-off) placements))
      (setq prev-num num))
    (when-let* ((fontified (magit-difftastic--fontify-string mode src)))
      (pcase-dolist (`(,disp-beg ,len ,src-off) (nreverse placements))
        (magit-difftastic--copy-faces fontified src-off len disp-beg)))))

;; Whole-file fontification.
;;
;; Reconstructing a chunk's source from its displayed rows (above) loses the
;; surrounding context, so a change inside a multi-line construct -- most often
;; a docstring/string -- is not recognized as such and stays unhighlighted.  To
;; fix that we fontify the WHOLE old/new file once (with full context) and map
;; faces by line number.  The old/new content is fetched per the diff context's
;; `:old-source'/`:new-source' specs ((worktree) or (blob REV)); when those are
;; absent or fetching/fontifying fails we fall back to per-chunk reconstruction.

(defvar magit-difftastic--syntax-cache nil
  "Dynamically-bound cache of fontified source vectors for one render.
Bound to a fresh hash table in `magit-difftastic--insert-file-sections' so each
changed file's old/new source is fetched and fontified at most once per refresh.")

(defun magit-difftastic--range-sources (range)
  "Return (OLD-SPEC . NEW-SPEC) source specs for a diff RANGE, or nil.
A `A..B'/`A...B' range maps to the two blobs; a bare revision diffs that
revision against the worktree."
  (cond
   ((null range) nil)
   ((string-match "\\`\\(.*?\\)\\.\\.\\.?\\(.*\\)\\'" range)
    (cons (list 'blob (let ((a (match-string 1 range)))
                        (if (string-empty-p a) "HEAD" a)))
          (list 'blob (let ((b (match-string 2 range)))
                        (if (string-empty-p b) "HEAD" b)))))
   (t (cons (list 'blob range) '(worktree)))))

(defun magit-difftastic--source-text (file spec)
  "Return FILE's full text for source SPEC, or nil.
SPEC is (worktree) -- read from disk -- or (blob REV) -- `git show REV:FILE'
\(REV may be \"\" for the index)."
  (pcase spec
    (`(worktree)
     (let ((path (expand-file-name file (magit-toplevel))))
       (when (file-readable-p path)
         (with-temp-buffer (insert-file-contents path) (buffer-string)))))
    (`(blob ,rev)
     (with-temp-buffer
       (and (eq 0 (process-file "git" nil t nil "--no-pager" "show"
                                (concat rev ":" file)))
            (buffer-string))))))

(defun magit-difftastic--fontify-lines (mode text)
  "Return a 1-indexed vector of MODE-fontified lines of TEXT, or nil.
Element 0 is unused; element N is the propertized Nth line."
  (when-let* ((fontified (magit-difftastic--fontify-string mode text)))
    (let* ((lines (split-string fontified "\n"))
           (vec (make-vector (1+ (length lines)) nil))
           (i 0))
      (dolist (l lines) (aset vec (setq i (1+ i)) l))
      vec)))

(defun magit-difftastic--source-vec (mode file spec)
  "Return the fontified line vector for FILE's SPEC side, memoized per render."
  (when spec
    (let ((key (cons file spec)))
      (if (and magit-difftastic--syntax-cache
               (not (eq 'miss (gethash key magit-difftastic--syntax-cache 'miss))))
          (gethash key magit-difftastic--syntax-cache)
        (let ((vec (when-let* ((text (magit-difftastic--source-text file spec)))
                     (magit-difftastic--fontify-lines mode text))))
          (when magit-difftastic--syntax-cache
            (puthash key vec magit-difftastic--syntax-cache))
          vec)))))

(defun magit-difftastic--copy-line-faces (srcline off n disp-beg)
  "Copy face runs from SRCLINE[OFF..OFF+N) onto DISP-BEG in this buffer."
  (let ((spos off) (send (+ off n)) (dpos disp-beg))
    (while (< spos send)
      (let* ((nxt (or (next-single-property-change spos 'face srcline send) send))
             (face (get-text-property spos 'face srcline))
             (k (- nxt spos)))
        (when face (magit-difftastic--apply-face dpos (+ dpos k) face))
        (setq spos nxt dpos (+ dpos k))))))

(defun magit-difftastic--apply-syntax-full (entries old-vec new-vec)
  "Paint faces from whole-file vectors OLD-VEC/NEW-VEC onto ENTRIES.
Each entry (SIDE NUM CODE-BEG CODE-END) is matched against its source line; a
wrapped line's rows advance an offset into that line.  Faces are only copied
when the displayed code matches the source exactly, so any misalignment (e.g.
tab expansion) is skipped rather than mis-highlighted."
  (let ((offsets (make-hash-table :test 'equal)))
    (pcase-dolist (`(,side ,num ,cb ,ce) entries)
      (let ((vec (if (eq side 'old) old-vec new-vec)))
        (when (and vec (integerp num) (< num (length vec)))
          (when-let* ((srcline (aref vec num)))
            (let* ((okey (cons side num))
                   (off (gethash okey offsets 0))
                   (len (- ce cb))
                   (avail (max 0 (- (length srcline) off)))
                   (n (min len avail)))
              (when (and (> n 0)
                         (string= (substring-no-properties srcline off (+ off n))
                                  (buffer-substring-no-properties cb (+ cb n))))
                (magit-difftastic--copy-line-faces srcline off n cb))
              (puthash okey (+ off len) offsets))))))))

(defun magit-difftastic--apply-syntax (file beg end context)
  "Add major-mode syntax highlighting to the chunk FILE between BEG and END.
Uses whole-file fontification driven by CONTEXT's `:old-source'/`:new-source'
\(correct context for strings/docstrings); falls back to per-chunk
reconstruction when no source is available.  No-op when FILE has no recognized
major mode."
  (when-let* ((mode (magit-difftastic--mode-for-file file))
              (entries (magit-difftastic--syntax-entries beg end)))
    (let ((old-vec (magit-difftastic--source-vec
                    mode file (plist-get context :old-source)))
          (new-vec (magit-difftastic--source-vec
                    mode file (plist-get context :new-source))))
      (if (or old-vec new-vec)
          (magit-difftastic--apply-syntax-full entries old-vec new-vec)
        ;; Fallback: fontify each side's reconstructed snippet (limited context).
        (dolist (side '(old new))
          (when-let* ((side-entries (seq-filter (lambda (e) (eq (car e) side))
                                                entries)))
            (magit-difftastic--apply-syntax-side mode side-entries)))))))

(defun magit-difftastic--region-selected-lines (section)
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
      (if-let* ((lines (magit-difftastic--parse-chunk-lines section)))
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
            (when-let* ((sn (magit-difftastic--line-side+num
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))))
              (pcase (car sn)
                ('old (push (cdr sn) old))
                ('new (push (cdr sn) new))))
            (forward-line)))))
    (cons (nreverse old) (nreverse new))))

(defun magit-difftastic--split-hunks (text)
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

(defun magit-difftastic--region-patch (file staged op sel-old sel-new)
  "Build a partial patch for FILE staging only SEL-OLD/SEL-NEW lines, or nil.
OP is \"-\" for forward application (stage/discard) or \"+\" for reverse
\(unstage).  Modeled on `magit-diff-hunk-region-patch'."
  (require 'diff-mode)
  (let* ((parsed (magit-difftastic--parse-diff (magit-difftastic--git-diff-raw file staged 3)))
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
                        (magit-difftastic--split-hunks fixed))))
        (concat header (string-join adjusted))))))

(defun magit-difftastic--patch-for (section op)
  "Return the patch to apply for SECTION and OP.
When a region is active within SECTION, build a partial (line-range) patch
for the selected lines; otherwise build the whole-chunk patch.  Signals a
`user-error' when nothing applicable is found."
  (if (magit-difftastic--region-active-p section)
      (let* ((val (oref section value))
             (sel (magit-difftastic--region-selected-lines section)))
        (or (magit-difftastic--region-patch (plist-get val :file)
                                       (plist-get val :staged)
                                       op (car sel) (cdr sel))
            (user-error "No changes in the selected region")))
    (or (magit-difftastic--chunk-patch section)
        (user-error "Could not map this chunk to a git hunk; use the file heading"))))

;; Core operations -- assume point is on a difftastic chunk SECTION.
;; Each op honors an active region (line-range staging) via
;; `magit-difftastic--patch-for'; with no region it operates on the whole chunk.
(defun magit-difftastic--ensure-stageable (section)
  "Signal a `user-error' unless chunk SECTION supports staging.
Chunks rendered for a diff that merely compares two revisions (a range diff,
or a commit being viewed) carry `:stageable' nil: there is no index or
worktree to apply a patch to."
  (unless (plist-get (oref section value) :stageable)
    (user-error "Staging is not available here; this diff only compares revisions")))

(defun magit-difftastic--stage-chunk-1 (section)
  "Stage the change(s) covered by chunk SECTION (or the selected region)."
  (magit-difftastic--ensure-stageable section)
  (if (plist-get (oref section value) :staged)
      (user-error "This chunk is already staged")
    (magit-difftastic--apply-chunk-patch (magit-difftastic--patch-for section "-") "--cached")))

(defun magit-difftastic--unstage-chunk-1 (section)
  "Unstage the change(s) covered by chunk SECTION (or the selected region)."
  (magit-difftastic--ensure-stageable section)
  (if (plist-get (oref section value) :staged)
      (magit-difftastic--apply-chunk-patch
       (magit-difftastic--patch-for section "+") "--cached" "--reverse")
    (user-error "This chunk is not staged")))

(defun magit-difftastic--discard-chunk-1 (section)
  "Discard the worktree change(s) covered by chunk SECTION (or the region)."
  (magit-difftastic--ensure-stageable section)
  (if (plist-get (oref section value) :staged)
      (user-error "Discarding a staged chunk is not supported; unstage it first")
    (let ((patch (magit-difftastic--patch-for section "+")))
      (when (magit-confirm 'discard "Discard the selected change(s)")
        (magit-difftastic--apply-chunk-patch patch "--reverse")))))

;; Interactive commands (for M-x / direct binding).
(defun magit-difftastic-stage-chunk ()
  "Stage the chunk at point, else fall back to `magit-stage'."
  (interactive)
  (if-let* ((section (magit-difftastic--current-chunk)))
      (magit-difftastic--stage-chunk-1 section)
    (call-interactively #'magit-stage)))

(defun magit-difftastic-unstage-chunk ()
  "Unstage the chunk at point, else fall back to `magit-unstage'."
  (interactive)
  (if-let* ((section (magit-difftastic--current-chunk)))
      (magit-difftastic--unstage-chunk-1 section)
    (call-interactively #'magit-unstage)))

(defun magit-difftastic-discard-chunk ()
  "Discard the chunk at point, else fall back to `magit-discard'."
  (interactive)
  (if-let* ((section (magit-difftastic--current-chunk)))
      (magit-difftastic--discard-chunk-1 section)
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

(defun magit-difftastic--stage-advice (orig &rest args)
  "Around-advice for `magit-stage' (see commentary)."
  (if-let* ((section (magit-difftastic--current-chunk)))
      (magit-difftastic--stage-chunk-1 section)
    (apply orig args)))

(defun magit-difftastic--unstage-advice (orig &rest args)
  "Around-advice for `magit-unstage' (see commentary)."
  (if-let* ((section (magit-difftastic--current-chunk)))
      (magit-difftastic--unstage-chunk-1 section)
    (apply orig args)))

(defun magit-difftastic--discard-advice (orig &rest args)
  "Around-advice for `magit-discard'/`magit-delete-thing' (see commentary)."
  (if-let* ((section (magit-difftastic--current-chunk)))
      (magit-difftastic--discard-chunk-1 section)
    (apply orig args)))

(defun magit-difftastic--on-difftastic-section-p ()
  "Non-nil when point is on a difftastic chunk or difftastic `file' section."
  (or (magit-difftastic--current-chunk)
      (magit-difftastic--first-chunk
       (magit-difftastic--enclosing-file-section))))

(defun magit-difftastic--visit-advice (orig &rest args)
  "Around-advice for the same-window Magit visit commands (see commentary).
On a difftastic chunk or `file' section, visit via
`magit-difftastic-visit-file-dwim'; otherwise call ORIG with ARGS.  Magit's own
visit commands expect a real diff/hunk section (with slots like `from-range')
that our custom sections lack, so calling them would signal an `invalid slot'
error."
  (if (magit-difftastic--on-difftastic-section-p)
      (magit-difftastic-visit-file-dwim)
    (apply orig args)))

(defun magit-difftastic--visit-other-window-advice (orig &rest args)
  "Like `magit-difftastic--visit-advice', but visiting in another window."
  (if (magit-difftastic--on-difftastic-section-p)
      (magit-difftastic-visit-file-dwim 'other-window)
    (apply orig args)))

(defun magit-difftastic--visit-other-frame-advice (orig &rest args)
  "Like `magit-difftastic--visit-advice', but visiting in another frame."
  (if (magit-difftastic--on-difftastic-section-p)
      (magit-difftastic-visit-file-dwim 'other-frame)
    (apply orig args)))

(defconst magit-difftastic--advices
  ;; These commands have simple (non-prompting) interactive forms, so advising
  ;; them is transparent.  We intentionally do NOT advise `magit-stage-files'/
  ;; `magit-unstage-files' (what `magit-mode-map' binds `s'/`u' to): their
  ;; interactive forms prompt for files, which would pop a prompt even when we
  ;; just want to stage the chunk.  Instead the `s'/`u'/`x' keys are bound
  ;; explicitly per evil state (see `magit-difftastic--set-evil-keys').
  ;;
  ;; The whole `magit-diff-visit-*' family is intercepted: depending on the
  ;; keybinding setup, `RET'/`C-j' on a file heading or chunk can resolve to any
  ;; of these (e.g. evil-collection binds `RET' to `magit-diff-visit-worktree-file'
  ;; and vanilla Magit binds `C-j'/`C-<return>' to it), and each would read hunk
  ;; slots our sections lack.  Commands that may be absent on older Magit are
  ;; guarded by `fboundp' where they are advised (see `magit-difftastic-mode').
  '((magit-stage        . magit-difftastic--stage-advice)
    (magit-unstage      . magit-difftastic--unstage-advice)
    (magit-discard      . magit-difftastic--discard-advice)
    (magit-delete-thing . magit-difftastic--discard-advice)
    (magit-visit-thing  . magit-difftastic--visit-advice)
    (magit-diff-visit-file                       . magit-difftastic--visit-advice)
    (magit-diff-visit-worktree-file              . magit-difftastic--visit-advice)
    (magit-diff-visit-file-other-window          . magit-difftastic--visit-other-window-advice)
    (magit-diff-visit-worktree-file-other-window . magit-difftastic--visit-other-window-advice)
    (magit-diff-visit-file-other-frame           . magit-difftastic--visit-other-frame-advice)
    (magit-diff-visit-worktree-file-other-frame  . magit-difftastic--visit-other-frame-advice))
  "Alist of (MAGIT-COMMAND . ADVICE) intercepted while on a difftastic section.")

(defun magit-difftastic--chunk-start-line (body-lines)
  "Return the first line number appearing in BODY-LINES, as a string, or nil.
Difftastic inline rows are prefixed with a right-aligned line number."
  (cl-some (lambda (l)
             (when (string-match "\\`[ \t]*\\([0-9]+\\)" l)
               (match-string 1 l)))
           body-lines))

(defun magit-difftastic--insert-chunk (body-lines file index context)
  "Insert one collapsible chunk section from BODY-LINES (difft header removed).
FILE is the repo-relative path and INDEX is the chunk's 0-based position in the
file's difftastic output (matching `difft --display json' chunk order).
CONTEXT is the diff context plist (see
`magit-difftastic--insert-file-sections'); its `:diff-args', `:staged' and
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
    (let* ((start (magit-difftastic--chunk-start-line body-lines))
           (heading (if start (format "@@ line %s @@" start) "@@ @@")))
      (magit-insert-section section
          (magit-difftastic-hunk
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
        (oset section keymap 'magit-difftastic-hunk-section-map)
        ;; Remember where the heading begins: difftastic's line-number parser
        ;; (used to hide the gutters) treats the first line of its bounds as the
        ;; chunk header, which is exactly this heading.
        (let ((heading-start (point)))
          (magit-insert-heading
            ;; Include the newline in the faced string (as Magit does for its own
            ;; hunk headings) so a face with `:extend t' -- e.g. the default
            ;; `magit-diff-hunk-heading' -- fills the heading bar to the window edge.
            (propertize (concat heading "\n")
                        'font-lock-face magit-difftastic-chunk-heading-face))
          (dolist (l body-lines)
            (insert l "\n"))
          (when magit-difftastic-syntax-highlight
            (magit-difftastic--apply-syntax file heading-start (point) context))
          (unless magit-difftastic-line-numbers
            (magit-difftastic--hide-line-numbers heading-start (point))))))))

(defun magit-difftastic--insert-chunks (rendered file context)
  "Split RENDERED difftastic output for FILE into collapsible per-chunk sections.
Difftastic's own `FILE --- N/M --- LANG' headers are consumed (not shown).
The chunk INDEX passed to `magit-difftastic--insert-chunk' increments once per
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
              (magit-difftastic--insert-chunk (nreverse chunk) file index context))
            (setq chunk nil started t index (1+ index)))
        (when started
          (push line chunk))))
    (when started
      (magit-difftastic--insert-chunk (nreverse chunk) file index context))))

(defun magit-difftastic--file-statuses (diff-args)
  "Return an alist of (PATH . (STATUS . ORIG)) for the DIFF-ARGS diff.
DIFF-ARGS is the leading git invocation (see
`magit-difftastic--file-diff-string'); `--name-status' is appended so each
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

(defun magit-difftastic--file-heading (file status orig)
  "Return the heading string for FILE, mimicking Magit's `file' section heading.
STATUS is Magit's status word and ORIG the rename source (or nil); see
`magit-difftastic--file-statuses'.  Uses `magit-format-file' (so any
icon/format customization applies) with the `magit-diff-file-heading' face, and
falls back to a `magit-format-file-default'-style string on older Magit."
  (let ((orig (and orig (not (equal orig file)) orig)))
    (if (fboundp 'magit-format-file)
        (magit-format-file 'diff file 'magit-diff-file-heading status orig)
      (propertize (concat (and status (format "%-11s" status))
                          (if orig (format "%s -> %s" orig file) file))
                  'font-lock-face 'magit-diff-file-heading))))

(defvar-local magit-difftastic--stock-files nil
  "List of repo-relative paths to render with stock Magit, not difftastic.
Buffer-local to each Magit buffer.  Toggled per file by
`magit-difftastic-toggle-file-rendering' (which see); a file in this list is
rendered with Magit's own `file'/`hunk' sections -- so Magit's native per-hunk
and per-line staging applies -- instead of difftastic chunks.")

(defun magit-difftastic--insert-stock-file (file context)
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
    (magit-difftastic--insert-difftastic-file
     file context
     (magit-difftastic--file-statuses (plist-get context :diff-args)))))

(defun magit-difftastic--insert-difftastic-file (file context statuses)
  "Insert the difftastic `file' section for FILE using CONTEXT.
STATUSES is the (PATH . (STATUS . ORIG)) alist for this diff (see
`magit-difftastic--file-statuses'); it drives the Magit-matching file heading
and the Magit-matching initial visibility (deleted files start collapsed).  This
is the default rendering; see `magit-difftastic--insert-file-sections'."
  (let* ((diff-args (plist-get context :diff-args))
         (info (cdr (assoc file statuses)))
         (status (or (car info) "modified"))
         (orig (cdr info)))
    (magit-insert-section (file file (or (equal status "deleted")
                                         (derived-mode-p 'magit-status-mode)))
      (magit-insert-heading
        (magit-difftastic--file-heading file status orig))
      (magit-difftastic--insert-chunks
       (magit-difftastic--file-diff-string file diff-args)
       file context))))

(defun magit-difftastic--insert-file-sections (files context)
  "Insert a collapsible difftastic `file' section for each of FILES.
Files are contiguous (no blank line between them); the only blank line is
inserted after the whole section (see the top-level inserters).
CONTEXT is a diff context plist with the entries:
  :diff-args  the leading git invocation selecting the diff to render
              (see `magit-difftastic--file-diff-string');
  :stock-args the git invocation Magit's `magit--insert-diff' expects to render
              the same diff with stock Magit sections (see
              `magit-difftastic--insert-stock-file');
  :staged     non-nil when the diff is the index against HEAD;
  :stageable  non-nil when per-chunk staging is meaningful in this buffer.
It is threaded down to every chunk section so the staging commands can rebuild
the corresponding git hunk.

A file listed in `magit-difftastic--stock-files' is rendered with stock Magit
sections instead of difftastic chunks (toggle per file with
`magit-difftastic-toggle-file-rendering').

Initial visibility mirrors Magit: a file section starts collapsed in
`magit-status-mode' buffers (and for deleted files everywhere), and expanded in
the diff/revision buffers.  The chunk sections are always inserted expanded, so
expanding a file reveals its hunk(s) -- the same way a single-hunk file feels
like it expands straight to its diff in Magit."
  ;; Read each file's status once for the whole group (only the difftastic path
  ;; needs it: for the Magit-matching heading and initial visibility).  A fresh
  ;; syntax cache is bound for this group so each file's old/new source is
  ;; fetched and fontified at most once across its chunks.
  (let* ((statuses (and (cl-some (lambda (f)
                                   (not (member f magit-difftastic--stock-files)))
                                 files)
                        (magit-difftastic--file-statuses
                         (plist-get context :diff-args))))
         ;; The porcelain `git diff' used for STATUSES detects renames and
         ;; reports each as a single "renamed: OLD -> NEW" entry.  FILES,
         ;; however, comes from plumbing (`git diff-index --name-only', via
         ;; `magit-{un,}staged-files'), which does NOT detect renames and so
         ;; lists a rename's OLD path as a separate deletion.  Drop those rename
         ;; sources: otherwise OLD -- absent from STATUSES -- would fall back to
         ;; the default "modified" heading and a bogus "Modified: OLD" section
         ;; would render alongside the real "renamed: OLD -> NEW" one.
         (rename-origins (delq nil
                               (mapcar (lambda (s)
                                         (and (equal (cadr s) "renamed")
                                              (cddr s)))
                                       statuses)))
         (magit-difftastic--syntax-cache (make-hash-table :test 'equal)))
    (dolist (file files)
      (unless (member file rename-origins)
        (if (member file magit-difftastic--stock-files)
            (magit-difftastic--insert-stock-file file context)
          (magit-difftastic--insert-difftastic-file file context statuses))))))

(defun magit-difftastic--context-unstaged ()
  "Diff context plist for the worktree-vs-index (unstaged) diff."
  (list :diff-args magit-difftastic--diff-base
        :stock-args '("diff" "-p" "--no-prefix")
        :old-source '(blob "") :new-source '(worktree)
        :staged nil :stageable t))

(defun magit-difftastic--context-staged ()
  "Diff context plist for the index-vs-HEAD (staged) diff."
  (list :diff-args (append magit-difftastic--diff-base '("--cached"))
        :stock-args '("diff" "-p" "--no-prefix" "--cached")
        :old-source '(blob "HEAD") :new-source '(blob "")
        :staged t :stageable t))

(defun magit-difftastic-insert-unstaged-changes ()
  "Difftastic replacement for `magit-insert-unstaged-changes'."
  (when-let* ((files (magit-unstaged-files)))
    (magit-insert-section (unstaged)
      (magit-insert-heading t "Unstaged changes")
      (magit-difftastic--insert-file-sections
       files (magit-difftastic--context-unstaged)))
    ;; Trailing blank line OUTSIDE the section, so it remains a stable
    ;; separator before the next section even when this one is collapsed.
    (insert "\n")))

(defun magit-difftastic-insert-staged-changes ()
  "Difftastic replacement for `magit-insert-staged-changes'."
  (unless (magit-bare-repo-p)
    (when-let* ((files (magit-staged-files)))
      (magit-insert-section (staged)
        (magit-insert-heading t "Staged changes")
        (magit-difftastic--insert-file-sections
         files (magit-difftastic--context-staged)))
      (insert "\n"))))

(defun magit-difftastic-toggle-file-rendering ()
  "Toggle the file at point between difftastic and stock Magit rendering.
Works on a difftastic file heading or chunk, and on a stock Magit file/hunk
section (to switch back).  A toggled-to-stock file is rendered with Magit's own
`file'/`hunk' sections, so Magit's native per-hunk and per-line staging applies
to it; toggling back restores the difftastic chunks.  The choice is buffer-local
\(see `magit-difftastic--stock-files') and survives refreshes."
  (interactive)
  (if-let* ((file (magit-difftastic--enclosing-file)))
      (progn
        (setq magit-difftastic--stock-files
              (if (member file magit-difftastic--stock-files)
                  (remove file magit-difftastic--stock-files)
                (cons file magit-difftastic--stock-files)))
        (magit-refresh)
        (message "%s now rendered with %s"
                 file
                 (if (member file magit-difftastic--stock-files)
                     "stock Magit" "difftastic")))
    (user-error "Point is not on a file in a magit-difftastic section")))

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
;; display-only (`:stageable' nil; see `magit-difftastic--ensure-stageable').

(defcustom magit-difftastic-diff-buffers t
  "Whether to render `magit-diff-mode' buffers with difftastic chunks.
This includes the diff Magit shows while you compose a commit message (which is
itself a `magit-diff-mode' buffer).  When nil, those buffers keep Magit's stock
rendering even while `magit-difftastic-mode' is enabled."
  :type 'boolean
  :group 'magit-difftastic)

(defcustom magit-difftastic-revision-buffers t
  "Whether to render `magit-revision-mode' buffers with difftastic chunks.
When nil, viewing a commit keeps Magit's stock rendering even while
`magit-difftastic-mode' is enabled."
  :type 'boolean
  :group 'magit-difftastic)

;; These are buffer-local variables Magit sets in its diff/revision buffers;
;; declare them special to keep the byte-compiler quiet.
(defvar magit-buffer-range)
(defvar magit-buffer-typearg)
(defvar magit-buffer-diff-files)
(defvar magit-buffer-revision)

(defun magit-difftastic--git-lines (&rest args)
  "Run \"git ARGS...\" and return its non-empty output lines as a list."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil args)
    (split-string (buffer-string) "\n" t)))

(defun magit-difftastic--diff-context ()
  "Return a (CONTEXT . FILES) pair for the current `magit-diff-mode' buffer.
CONTEXT is the diff context plist (see
`magit-difftastic--insert-file-sections') and FILES is the list of changed
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
             (range-src (magit-difftastic--range-sources range))
             (context
              (cond
               ((and (null range) (equal typearg "--cached"))
                (list :diff-args (append magit-difftastic--diff-base selector)
                      :stock-args stock-args
                      :old-source '(blob "HEAD") :new-source '(blob "")
                      :staged t :stageable t))
               ((and (null range) (null typearg))
                (list :diff-args magit-difftastic--diff-base
                      :stock-args stock-args
                      :old-source '(blob "") :new-source '(worktree)
                      :staged nil :stageable t))
               (t
                (list :diff-args (append magit-difftastic--diff-base selector)
                      :stock-args stock-args
                      :old-source (car range-src) :new-source (cdr range-src)
                      :staged nil :stageable nil))))
             (files (apply #'magit-difftastic--git-lines
                           (append '("--no-pager" "diff" "--name-only")
                                   selector '("--") diff-files))))
        (and files (cons context files))))))

(defun magit-difftastic--revision-context ()
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
           (context (list :diff-args (append magit-difftastic--show-base (list commit))
                          :stock-args (append '("show" "-p" "--format=" "--no-prefix")
                                              (list commit))
                          :old-source (list 'blob (concat commit "^"))
                          :new-source (list 'blob commit)
                          :staged nil :stageable nil))
           (files (apply #'magit-difftastic--git-lines
                         (append '("--no-pager" "show" "--name-only" "--format=")
                                 (list commit) '("--") diff-files))))
      (and files (cons context files)))))

(defun magit-difftastic--insert-diff-advice (orig &rest args)
  "Around-advice for `magit-insert-diff' rendering chunks with difftastic.
Falls back to ORIG (called with ARGS) when difftastic should not handle the
current `magit-diff-mode' buffer."
  (let ((ctx (and magit-difftastic-diff-buffers
                  (ignore-errors (magit-difftastic--diff-context)))))
    (if ctx
        (magit-difftastic--insert-file-sections (cdr ctx) (car ctx))
      (apply orig args))))

(defun magit-difftastic--insert-revision-diff-advice (orig &rest args)
  "Around-advice for `magit-insert-revision-diff' rendering chunks with difftastic.
Falls back to ORIG (called with ARGS) when difftastic should not handle the
current `magit-revision-mode' buffer.  Like Magit's own inserter, the per-file
sections are inserted directly (no extra wrapping section)."
  (let ((ctx (and magit-difftastic-revision-buffers
                  (ignore-errors (magit-difftastic--revision-context)))))
    (if ctx
        (magit-difftastic--insert-file-sections (cdr ctx) (car ctx))
      (apply orig args))))

(defcustom magit-difftastic-toggle-rendering-key "C-c C-d"
  "Key bound on magit-difftastic sections to toggle a file's rendering.
A key sequence in `kbd' syntax, bound to
`magit-difftastic-toggle-file-rendering' while `magit-difftastic-mode' is
enabled, so the file at point can be switched between difftastic and stock Magit
rendering (and back).  Set to nil to bind no key.  Changing this takes effect
the next time the mode is toggled."
  :type '(choice (const :tag "No binding" nil)
                 (string :tag "Key"))
  :group 'magit-difftastic)

(defvar magit-difftastic-hunk-section-map
  (make-sparse-keymap)
  "Keymap installed on difftastic chunk (`magit-difftastic-hunk') sections.
Attached via each section's `:keymap' slot (see
`magit-difftastic--insert-chunk').  `magit-difftastic-mode' adds
`magit-difftastic-toggle-rendering-key' here while enabled; unbound keys fall
through to the Magit maps as usual.")

(defun magit-difftastic--set-toggle-key (enable)
  "Bind (ENABLE non-nil) or unbind the file-rendering toggle key.
The key is `magit-difftastic-toggle-rendering-key' and the command is
`magit-difftastic-toggle-file-rendering'.  We bind it in
`magit-difftastic-hunk-section-map' (difftastic chunks) and in Magit's shared
`magit-file-section-map'/`magit-hunk-section-map', so the toggle is reachable
both on difftastic sections and on the stock `file'/`hunk' sections a
toggled-to-stock file produces (difftastic file headings also use
`magit-file-section-map').  The key lives only on these section keymaps, so no
global Magit binding is shadowed."
  (when-let* ((key magit-difftastic-toggle-rendering-key)
              ((stringp key))
              (seq (ignore-errors (kbd key))))
    (dolist (map '(magit-difftastic-hunk-section-map
                   magit-file-section-map
                   magit-hunk-section-map))
      (when (boundp map)
        ;; Use `define-key'/`kbd' (not `keymap-set'/`keymap-unset') to keep the
        ;; Emacs 28.1 minimum; a nil definition removes our binding (the key is
        ;; not otherwise bound in these maps, so this leaves them as before).
        (define-key (symbol-value map) seq
                    (and enable #'magit-difftastic-toggle-file-rendering))))))

(defconst magit-difftastic--evil-keys
  '(("s" . magit-difftastic-stage-chunk)
    ("u" . magit-difftastic-unstage-chunk)
    ("x" . magit-difftastic-discard-chunk))
  "Evil keys bound in magit maps so chunk/region staging works under evil.")

(defun magit-difftastic--set-evil-keys (enable)
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
        (pcase-dolist (`(,key . ,cmd) magit-difftastic--evil-keys)
          ;; A nil definition removes our override (falls through to magit's).
          (evil-define-key* '(normal visual) (symbol-value map)
                            key (and enable cmd)))))))

;;;###autoload
(define-minor-mode magit-difftastic-mode
  "Render unstaged/staged changes in `magit-status' with difftastic.

While enabled, `magit-insert-unstaged-changes' and
`magit-insert-staged-changes' are overridden so the status buffer shows
collapsible, difftastic-rendered, per-file sections.  `magit-insert-diff' and
`magit-insert-revision-diff' are likewise advised so `magit-diff-mode' buffers
\(including the diff shown while composing a commit) and `magit-revision-mode'
buffers (viewing a commit) get the same difftastic chunks; this can be scoped
with `magit-difftastic-diff-buffers' and `magit-difftastic-revision-buffers'.
The magit stage/unstage/discard/visit commands are advised so that, while point
is on a difftastic chunk, they act on just that chunk (otherwise unchanged) --
staging is offered only where it is meaningful (the worktree and `--cached'
diffs).  Evil visual-state keys are also bound so region (line-range) staging
works.

`magit-difftastic-toggle-rendering-key' is bound on the difftastic and stock
sections to `magit-difftastic-toggle-file-rendering', which switches the file
at point between difftastic and stock Magit rendering (a stock-rendered file
uses Magit's native per-hunk/line staging)."
  :global t
  :group 'magit-difftastic
  (if magit-difftastic-mode
      (progn
        (advice-add 'magit-insert-unstaged-changes :override
                    #'magit-difftastic-insert-unstaged-changes)
        (advice-add 'magit-insert-staged-changes :override
                    #'magit-difftastic-insert-staged-changes)
        (advice-add 'magit-insert-diff :around
                    #'magit-difftastic--insert-diff-advice)
        (advice-add 'magit-insert-revision-diff :around
                    #'magit-difftastic--insert-revision-diff-advice)
        (pcase-dolist (`(,cmd . ,advice) magit-difftastic--advices)
          ;; Some `magit-diff-visit-*' variants may be absent on older Magit.
          (when (fboundp cmd)
            (advice-add cmd :around advice)))
        (magit-difftastic--set-evil-keys t)
        (magit-difftastic--set-toggle-key t))
    (advice-remove 'magit-insert-unstaged-changes
                   #'magit-difftastic-insert-unstaged-changes)
    (advice-remove 'magit-insert-staged-changes
                   #'magit-difftastic-insert-staged-changes)
    (advice-remove 'magit-insert-diff
                   #'magit-difftastic--insert-diff-advice)
    (advice-remove 'magit-insert-revision-diff
                   #'magit-difftastic--insert-revision-diff-advice)
    (pcase-dolist (`(,cmd . ,advice) magit-difftastic--advices)
      (when (fboundp cmd)
        (advice-remove cmd advice)))
    (magit-difftastic--set-evil-keys nil)
    (magit-difftastic--set-toggle-key nil))
  ;; Refresh any visible status/diff/revision buffers so the change is
  ;; immediately visible (`magit-revision-mode' derives from `magit-diff-mode').
  (when (fboundp 'magit-refresh)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'magit-status-mode 'magit-diff-mode)
          (magit-refresh))))))

(provide 'magit-difftastic)
;;; magit-difftastic.el ends here
