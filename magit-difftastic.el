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
;; In the side-by-side layouts difft sizes each file's columns to that file's
;; own longest line, so the center divider (and the right-hand line numbers)
;; would otherwise land at a different column per file.  By default
;; (`magit-difftastic-align-columns') every two-column chunk in a buffer is
;; padded so its right column lines up with the widest chunk's, keeping the
;; divider and right-side line numbers aligned across the whole buffer; the
;; padding only widens the gap between the columns, so staging is unaffected.
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
;; assumed and the package works with stock Emacs keybindings.  Set
;; `magit-difftastic-bind-evil-keys' to nil to opt out of those Evil bindings
;; entirely (e.g. if you remap `s'/`u'/`x' yourself).
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
;;   - `difft' is run once per changed file when its content first needs
;;     rendering.  Files in a section are rendered concurrently (up to
;;     `magit-difftastic-render-jobs' processes at a time) and the result is
;;     cached across refreshes keyed on the compared blobs (see
;;     `magit-difftastic-cache'), so an unchanged file is not re-rendered -- a
;;     refresh costs roughly the slowest file that actually changed.  A very
;;     large set of first-time changes can still make `magit-status' sluggish,
;;     since the refresh waits for that initial batch.
;;   - Untracked files are still rendered by the stock
;;     `magit-insert-untracked-files'.
;;   - In `magit-diff-mode'/`magit-revision-mode' buffers the difftastic
;;     rendering replaces Magit's diff section wholesale, so the usual diffstat
;;     header is not shown there.  Merge commits (combined diffs) and
;;     `--no-index' diffs fall back to Magit's stock rendering.
;;   - Whitespace-ignoring diff flags (`-w', `--ignore-blank-lines', ...) are
;;     honoured at FILE granularity: difft has no whitespace-ignore option (and
;;     Git does not pass these to an external diff tool), so a file whose only
;;     differences are whitespace is dropped from the view, but whitespace noise
;;     mixed with real changes inside a (plain-text) file is still shown.  For
;;     recognised languages difft already ignores whitespace structurally.
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

(defcustom magit-difftastic-align-columns t
  "Whether to align the side-by-side columns across all chunks in a buffer.
difft sizes each file's columns to that file's own longest line, so in a
side-by-side layout the center divider -- and with it the right side's
line-number gutter -- lands at a different column for each file, leaving the
chunks visually ragged (this is what `magit-difftastic-display' renders).

When non-nil (the default), every two-column chunk in a status, diff or
revision buffer is padded so its right column begins at the same column as the
widest chunk's, lining the divider and the right-hand line numbers up across
the whole buffer.  The padding is inserted only in the gap between the two
columns, so the rendered code -- and per-chunk/region staging -- are
unaffected.

Has no effect with the `inline' display (which has no right column) or on
chunks difft collapses to a single column.  Set to nil to keep difftastic's
compact, content-sized columns."
  :type 'boolean
  :group 'magit-difftastic)

(defcustom magit-difftastic-syntax-highlight t
  "Whether to add major-mode syntax highlighting to rendered chunks.
difft only emphasizes keywords and comments (bold/italic) and colours the
changed tokens; when this is non-nil each chunk's code is additionally
fontified with the file's Emacs major mode, so keywords, strings, types, etc.
get their usual faces.  The diff colours difft applies to changed tokens keep
precedence.

This fontifies each rendered file with its major mode, which adds some cost on
top of difft itself.  The cost is contained: only the lines a chunk displays are
fontified (font-lock still scans from the start for correct context), and the
result is cached per blob across refreshes -- and shared between the staged and
unstaged views -- alongside the render cache (see `magit-difftastic-cache' and
`magit-difftastic-clear-cache').  Set to nil to turn it off."
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

(defcustom magit-difftastic-render-jobs nil
  "Maximum number of `difft' processes to run concurrently while rendering.
On every refresh each changed file is rendered by its own `difft' subprocess;
running them concurrently makes the rendering wall-clock time roughly the
slowest single file rather than the sum of all of them.

  - nil (default): use the number of available processors (when Emacs can
    report it), capped at a sensible maximum, else a small fixed number.
  - a positive integer: run at most that many `difft' processes at once.  A
    value of 1 renders serially (the pre-2.x behaviour)."
  :type '(choice (const :tag "Auto (number of processors)" nil)
                 (integer :tag "Fixed maximum"))
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

(defvar magit-difftastic--render-cache nil
  "Dynamically-bound hash of FILE -> pre-rendered difft string for one group.
Bound in `magit-difftastic--insert-file-sections' to the result of rendering
that group's files in parallel (see `magit-difftastic--render-files'), so the
synchronous section-insertion pass reads each file's already-computed difft
output instead of spawning a subprocess inline.  A cache miss falls back to a
direct synchronous render, so the cache is purely an optimisation.")

(defun magit-difftastic--render-raw (file diff-args width)
  "Run `git DIFF-ARGS -- FILE' through difft at WIDTH and return propertized text.
Synchronous; used as the fallback when no pre-warmed entry exists (see
`magit-difftastic--render-cache') and as the worker the parallel runner mirrors."
  (require 'difftastic)
  (let ((raw (with-temp-buffer
               ;; `difftastic--build-git-process-environment' sets
               ;; GIT_EXTERNAL_DIFF=difft ... so plain `git diff --ext-diff'
               ;; routes through difftastic.  We append `--display' per
               ;; `magit-difftastic-display'.
               (let ((process-environment
                      (difftastic--build-git-process-environment
                       width (list "--display" magit-difftastic-display))))
                 (apply #'process-file "git" nil t nil
                        (append diff-args (list "--" file))))
               (buffer-string))))
    ;; Turn difft's ANSI escapes into propertized text using difftastic's
    ;; own colour vectors (so it matches `difftastic-magit-diff').
    (difftastic--ansi-color-apply raw)))

(defun magit-difftastic--file-diff-string (file diff-args)
  "Return the difftastic-rendered, fontified diff STRING for FILE.
DIFF-ARGS is the leading git invocation (including `--no-pager', the
subcommand and `--ext-diff') that selects which diff to render; FILE is
appended as a pathspec.  For example, `(\"--no-pager\" \"diff\" \"--ext-diff\"
\"--cached\")' renders the index against HEAD, while
`(\"--no-pager\" \"show\" \"--ext-diff\" \"--format=\" REV)' renders a commit.

When `magit-difftastic--render-cache' holds a pre-warmed entry for FILE (the
common case during a refresh, where the whole group was rendered in parallel up
front) it is returned directly; otherwise FILE is rendered synchronously now."
  (or (and magit-difftastic--render-cache
           (gethash file magit-difftastic--render-cache))
      (magit-difftastic--render-raw file diff-args (magit-difftastic--width))))

(defun magit-difftastic--max-jobs ()
  "Return the maximum number of concurrent difft processes to run.
Honours `magit-difftastic-render-jobs'; when that is nil, uses the processor
count (capped) when Emacs can report it, else a small fixed default."
  (cond
   ((integerp magit-difftastic-render-jobs)
    (max 1 magit-difftastic-render-jobs))
   ((fboundp 'num-processors) (max 1 (min 16 (num-processors))))
   (t 4)))

(defun magit-difftastic--render-files (jobs width)
  "Render difft for JOBS in parallel; return a hash of FILE -> rendered string.
JOBS is a list of (FILE . DIFF-ARGS).  Each job runs `git DIFF-ARGS -- FILE'
through difft (exactly as `magit-difftastic--render-raw' does synchronously) at
WIDTH columns, but up to `magit-difftastic--max-jobs' of them run concurrently
via `start-file-process' (the TRAMP-aware async counterpart of `process-file'),
so a group's rendering cost is roughly its slowest file rather than the sum.

Blocks until every job has finished, then returns the populated hash; a job
whose process fails simply yields nil for that file, so the caller falls back to
a synchronous render."
  (require 'difftastic)
  (let* ((results (make-hash-table :test 'equal))
         (queue (copy-sequence jobs))
         (max-jobs (magit-difftastic--max-jobs))
         (running 0)
         (pending (length jobs))
         ;; difft is selected purely through the environment (GIT_EXTERNAL_DIFF
         ;; etc.); the same env is reused for every process in the group.
         (env (difftastic--build-git-process-environment
               width (list "--display" magit-difftastic-display))))
    (cl-labels
        ((launch ()
           (while (and queue (< running max-jobs))
             (let* ((job (pop queue))
                    (file (car job))
                    (args (append (cdr job) (list "--" file)))
                    (buf (generate-new-buffer " *magit-difftastic-render*"))
                    (process-environment env)
                    (proc (apply #'start-file-process
                                 "magit-difftastic-render" buf "git" args)))
               (cl-incf running)
               (set-process-query-on-exit-flag proc nil)
               (set-process-sentinel
                proc
                (lambda (p _event)
                  (unless (process-live-p p)
                    (let ((b (process-buffer p)))
                      (when (buffer-live-p b)
                        (with-current-buffer b
                          (puthash file
                                   (difftastic--ansi-color-apply (buffer-string))
                                   results))
                        (kill-buffer b)))
                    (cl-decf running)
                    (cl-decf pending)
                    ;; A finished slot frees room for the next queued job.
                    (launch))))))))
      (launch)
      ;; Pump the event loop until every sentinel has fired.  We run inside a
      ;; `magit-refresh', and `accept-process-output' with a nil process drains
      ;; the whole event loop, so a foreign sentinel/timer can fire here and call
      ;; `magit-refresh' -- which re-enters this renderer and pumps again: an
      ;; unbounded refresh->render loop that freezes Emacs (#6).  Binding
      ;; `magit-inhibit-refresh' (refresh's only reentrancy guard) makes any such
      ;; nested refresh a no-op; the outer refresh already reads fresh state.
      (let ((magit-inhibit-refresh t))
        (while (> pending 0)
          (accept-process-output nil 0.05))))
    results))

;;; Render cache
;;
;; difft output for a file is a pure function of the two blobs being compared
;; plus the display layout and width, so we cache rendered strings across
;; refreshes keyed on exactly those inputs.  The blobs are identified by their
;; git object ids (read once per group with a single plumbing `--raw' call); a
;; worktree side git has not hashed (reported as an all-zero id) is keyed by the
;; file's stat (size + mtime) instead.  After a staging action only the touched
;; file's blob id changes, so every other file is served from the cache and not
;; re-rendered.

(defun magit-difftastic--raw-args (diff-args)
  "Return the plumbing `--raw' form of DIFF-ARGS (difft disabled).
Swaps `--ext-diff' for `--no-ext-diff' and appends `--raw'/`--no-abbrev', so the
same subcommand and selector that renders a diff instead reports each file's
full old/new blob object ids cheaply."
  (append (mapcar (lambda (a) (if (equal a "--ext-diff") "--no-ext-diff" a))
                  diff-args)
          '("--raw" "--no-abbrev")))

(defun magit-difftastic--status-word (code)
  "Return Magit's status word for raw status letter CODE (a character).
\"new file\" for additions/copies, \"deleted\", \"renamed\", else \"modified\"
\(matching what Magit's own porcelain `--name-status' reports)."
  (pcase code
    (?A "new file")
    (?D "deleted")
    (?C "new file")
    (?R "renamed")
    (_  "modified")))

(defun magit-difftastic--raw-info (diff-args &optional files)
  "Return a hash of NEW-PATH -> plist for the DIFF-ARGS diff.
Runs a single `git ... --raw' plumbing call (see `magit-difftastic--raw-args');
when FILES is non-nil it is appended as a pathspec, otherwise every changed file
is reported.  Each value is a plist with:
  :old     the old blob object id;
  :new     the new blob object id (an all-zero placeholder for a worktree side
           git has not hashed -- callers fold the worktree file's stat into the
           cache key for those);
  :status  Magit's status word (see `magit-difftastic--status-word');
  :orig    the source path for a rename/copy, else nil.
A rename/copy entry is keyed on the NEW path (matching how files are rendered).

This is the single plumbing pass both the render/syntax caches (via the blob
ids) and the file headings (via the status word) read from, so a refresh runs it
once instead of a separate `--raw' and `--name-status' call."
  (let ((map (make-hash-table :test 'equal)))
    (with-temp-buffer
      (apply #'process-file "git" nil t nil
             (append (magit-difftastic--raw-args diff-args)
                     (when files (cons "--" files))))
      (dolist (line (split-string (buffer-string) "\n" t))
        ;; A raw line is ":OMODE NMODE OID NID STATUS\tPATH" (rename/copy:
        ;; "...\tOLD\tNEW").  Combined (merge) diffs start with "::" and are
        ;; not rendered by us, so they are ignored here.
        (when (and (string-prefix-p ":" line)
                   (not (string-prefix-p "::" line)))
          (when-let* ((tab (string-search "\t" line))
                      (meta (split-string (substring line 0 tab) " " t))
                      (paths (split-string (substring line (1+ tab)) "\t"))
                      (oid (nth 2 meta))
                      (nid (nth 3 meta))
                      (status (nth 4 meta))
                      (path (car (last paths))))
            (let ((code (aref status 0)))
              (puthash path
                       (list :old oid :new nid
                             :status (magit-difftastic--status-word code)
                             ;; The OLD path of a rename/copy (raw lists it as
                             ;; the first of the two tab-separated paths).
                             :orig (and (memq code '(?C ?R)) (car paths)))
                       map))))))
    map))

(defun magit-difftastic--blob-ids (diff-args files)
  "Return a hash of FILE -> (OLD-ID . NEW-ID) for the DIFF-ARGS diff of FILES.
A thin projection of `magit-difftastic--raw-info' (which see); a rename's entry
is keyed on the NEW path."
  (let ((map (make-hash-table :test 'equal)))
    (when files
      (maphash (lambda (path info)
                 (puthash path (cons (plist-get info :old) (plist-get info :new))
                          map))
               (magit-difftastic--raw-info diff-args files)))
    map))

(defcustom magit-difftastic-cache t
  "Whether to cache rendered difft output across refreshes.
When non-nil, each file's difft output is cached keyed on the two blobs being
compared plus the display layout and width, so a refresh that does not change a
file's content reuses the previous rendering instead of running difft again.
Clear it manually with `magit-difftastic-clear-cache'."
  :type 'boolean
  :group 'magit-difftastic)

(defconst magit-difftastic--cache-max 2048
  "Maximum number of entries kept in `magit-difftastic--cache'.
When exceeded the cache is cleared wholesale; entries are keyed on immutable
blob ids (or a worktree stat), so this only bounds memory -- a kept entry is
never stale.")

(defvar magit-difftastic--cache (make-hash-table :test 'equal)
  "Persistent cache of rendered difft output, surviving across refreshes.
Maps a content-identity key (see `magit-difftastic--cache-key') to the
propertized difft string.  Bounded by `magit-difftastic--cache-max'.")

;; Forward declaration: the fontification cache is defined with the syntax
;; highlighting code further down, but `magit-difftastic-clear-cache' (here,
;; alongside the render cache) clears it too.
(defvar magit-difftastic--syntax-cache)

(defun magit-difftastic-clear-cache ()
  "Empty the difftastic render and fontification caches.
Clears both `magit-difftastic--cache' (rendered difft output) and
`magit-difftastic--syntax-cache' (major-mode fontification)."
  (interactive)
  (clrhash magit-difftastic--cache)
  (clrhash magit-difftastic--syntax-cache)
  (when (called-interactively-p 'interactive)
    (message "magit-difftastic render cache cleared")))

(defun magit-difftastic--all-zero-id-p (id)
  "Return non-nil when git object id ID is the all-zero placeholder."
  (and (stringp id) (string-match-p "\\`0+\\'" id)))

(defun magit-difftastic--worktree-stat (file)
  "Return (SIZE . MTIME) for FILE in the worktree, or nil if unavailable."
  (when-let* ((attrs (ignore-errors
                       (file-attributes
                        (expand-file-name file (magit-toplevel))))))
    (cons (file-attribute-size attrs)
          (file-attribute-modification-time attrs))))

(defun magit-difftastic--cache-key (file ids width)
  "Return the render-cache key for FILE, or nil when it cannot be keyed.
IDS is the (OLD-ID . NEW-ID) pair from `magit-difftastic--blob-ids' and WIDTH is
the column width.  A worktree NEW side (an all-zero id git has not hashed) is
keyed by the file's stat so edits invalidate the entry; when neither the new id
nor the stat is available the file cannot be safely cached (returns nil), so it
is always re-rendered."
  (when ids
    (let* ((old (car ids))
           (new (cdr ids))
           (new-key (if (magit-difftastic--all-zero-id-p new)
                        (when-let* ((st (magit-difftastic--worktree-stat file)))
                          (cons 'stat st))
                      new)))
      (and old new-key
           (list magit-difftastic-display width old new-key)))))

(defun magit-difftastic--cache-get (key)
  "Return the cached render for KEY, or nil (also nil when KEY or caching is off)."
  (and key magit-difftastic-cache (gethash key magit-difftastic--cache)))

(defun magit-difftastic--cache-put (key value)
  "Store VALUE under KEY in the render cache when caching is enabled."
  (when (and key value magit-difftastic-cache)
    (when (> (hash-table-count magit-difftastic--cache)
             magit-difftastic--cache-max)
      (clrhash magit-difftastic--cache))
    (puthash key value magit-difftastic--cache)))

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
  "Visit the file enclosing point, jumping to the chunk's first change.
When on a chunk, jump to its first new-side line (read from the chunk's rendered
gutters); falls back to the chunk's stored gutter line.
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
             (line (or (and chunk (ignore-errors
                                    (magit-difftastic--chunk-visit-line chunk)))
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

(defun magit-difftastic--chunk-displayed-lines (section)
  "Return (OLD-LINES . NEW-LINES) for every row displayed in chunk SECTION.
OLD-LINES/NEW-LINES are the lhs/rhs file line numbers difftastic rendered in
SECTION's own gutters, read straight from the buffer.

We use these -- NOT an index into difft's `--display json' chunks -- to map a
chunk onto git hunks, because difft's text display can merge several JSON chunks
into one displayed section (e.g. a modification immediately followed by an
insertion).  When that happens a section's display ordinal is no longer a valid
index into the JSON chunk list, so indexing it picks an unrelated chunk's lines
and stages/unstages/discards the wrong hunk (discarding one chunk would revert a
different one).  Reading the section's own gutters always reflects exactly what
that section shows.

Uses difftastic's parser (correct for inline and either side-by-side layout,
including wrapped rows); falls back to the inline-only heuristic when the parser
is unavailable."
  (let ((old nil) (new nil))
    (if-let* ((lines (magit-difftastic--parse-chunk-lines section)))
        (dolist (l lines)
          (pcase-let ((`(,_ ,left ,right) l))
            (when (car left)  (push (car left) old))
            (when (car right) (push (car right) new))))
      ;; Legacy fallback (inline only) when difftastic's parser is unavailable.
      (save-excursion
        (goto-char (or (oref section content) (oref section start)))
        (while (< (point) (oref section end))
          (when-let* ((sn (magit-difftastic--line-side+num
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))
            (pcase (car sn)
              ('old (push (cdr sn) old))
              ('new (push (cdr sn) new))))
          (forward-line))))
    (cons (nreverse old) (nreverse new))))

(defun magit-difftastic--chunk-visit-line (section)
  "Return the 1-based worktree line to visit for chunk SECTION, or nil.
Prefers the chunk's first new-side (rhs) displayed line, so visiting lands on
the change in the worktree; falls back to the first old-side (lhs) line for a
pure deletion.

Read from SECTION's rendered gutters (see
`magit-difftastic--chunk-displayed-lines'), so it follows whatever the section
actually shows rather than indexing difft's `--display json' chunks (whose
ordinals can drift from the displayed sections).

\(We deliberately do not try to compute a column: difft only marks changed
tokens for recognized languages -- for plain text every span is `normal' -- so
a derived column would be misleading.  Visiting lands on the line and its first
non-whitespace character instead.)"
  (let ((lines (magit-difftastic--chunk-displayed-lines section)))
    (or (car (cdr lines)) (car (car lines)))))

(defun magit-difftastic--chunk-patch (section)
  "Build a standalone git patch string for the chunk SECTION, or nil.
The patch contains the file header plus exactly the git hunk(s) that the
difftastic chunk maps onto.  The chunk's old/new line numbers are read from
SECTION's rendered gutters (`magit-difftastic--chunk-displayed-lines')."
  (let* ((val (oref section value))
         (file (plist-get val :file))
         (staged (plist-get val :staged))
         (parsed (magit-difftastic--parse-diff (magit-difftastic--git-diff-raw file staged)))
         (header (car parsed))
         (hunks (cdr parsed))
         (lines (magit-difftastic--chunk-displayed-lines section))
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

(defun magit-difftastic--remap-mode (mode)
  "Return MODE remapped per the user's major-mode remapping, or MODE.
Applies `major-mode-remap-alist'/`major-mode-remap-defaults' exactly as
`set-auto-mode' does, so a tree-sitter (`*-ts-mode') -- or any other replacement
the user has opted into -- is used where it would be when visiting the file.  A
no-op on Emacs versions without the remap machinery."
  (cond
   ((null mode) nil)
   ;; Emacs 30.1+: the canonical resolver, also consults `*-remap-defaults'.
   ((fboundp 'major-mode-remap) (major-mode-remap mode))
   ;; Emacs 29: only the user alist exists; a nil value means \"no remap\".
   ((and (boundp 'major-mode-remap-alist)
         (assq mode major-mode-remap-alist))
    (or (cdr (assq mode major-mode-remap-alist)) mode))
   (t mode)))

(defun magit-difftastic--mode-for-file (file)
  "Return the major-mode function Emacs would use for FILE, or nil.
The raw `auto-mode-alist' match is run through `magit-difftastic--remap-mode',
so a configured tree-sitter (`*-ts-mode') mode is picked up just as it would be
when visiting FILE.  Only a callable mode symbol is returned; `fundamental-mode'
and non-symbol entries yield nil (nothing to highlight)."
  (let ((mode (let ((case-fold-search (memq system-type
                                            '(windows-nt cygwin darwin))))
                (assoc-default file auto-mode-alist #'string-match))))
    (when (consp mode) (setq mode (car mode)))
    (setq mode (magit-difftastic--remap-mode mode))
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
;; fix that we fontify the old/new file with full preceding context and map
;; faces by line number.  font-lock always scans from the start of the buffer,
;; so it suffices to fontify only as far down as the lowest line the chunk
;; displays (`magit-difftastic--source-vec' bounds it there) -- a tiny change in
;; a huge file no longer fontifies the whole file.  The old/new content is
;; fetched per the diff context's `:old-source'/`:new-source' specs ((worktree)
;; or (blob REV)) and the fontified lines are cached per blob id across refreshes
;; (`magit-difftastic--syntax-cache'); when no source is available, or fetching
;; or fontifying fails, we fall back to per-chunk reconstruction.

(defconst magit-difftastic--syntax-cache-max 2048
  "Maximum number of entries kept in `magit-difftastic--syntax-cache'.
When exceeded the cache is cleared wholesale; entries are keyed on immutable
blob ids (or a worktree stat), so this only bounds memory -- a kept entry is
never stale.")

(defvar magit-difftastic--syntax-cache (make-hash-table :test 'equal)
  "Persistent cache of fontified source lines, surviving across refreshes.
Keyed on (MODE . CONTENT-ID) -- the major mode plus the side's git blob id
\(or a worktree stat; see `magit-difftastic--side-content-id') -- so a blob's
fontification is computed once and reused on every later refresh, and shared
between the staged and unstaged views of the same blob.  Each value is
\(COVERED . VEC): VEC is the 1-indexed line vector (see
`magit-difftastic--fontify-lines') and COVERED the (LO . HI) line range actually
fontified, so an entry is reused only when it covers the requested window (see
`magit-difftastic--source-vec').  Bounded by
`magit-difftastic--syntax-cache-max' and gated on `magit-difftastic-cache';
cleared by `magit-difftastic-clear-cache'.")

(defvar magit-difftastic--file-ids nil
  "Dynamically-bound hash of FILE -> (OLD-ID . NEW-ID) for the current group.
Bound in `magit-difftastic--insert-file-sections' from the single `--raw'
plumbing pass (`magit-difftastic--raw-info'), so the syntax-highlight layer can
content-key its fontification cache (`magit-difftastic--syntax-cache') by the
same blob ids the render cache uses, instead of recomputing them.")

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

(defun magit-difftastic--fontify-lines (mode text &optional range)
  "Return (COVERED . VEC) for TEXT fontified with major MODE, or nil.
VEC is 1-indexed: element 0 is unused; element N is the propertized Nth line
\(only the lines actually fontified carry faces).  COVERED is the (LO . HI) line
range that was fontified.

RANGE, when non-nil, is the (MIN . MAX) line window to fontify -- only those
lines get the (expensive) face work, while font-lock still derives string and
comment context from `syntax-ppss', which parses from the top of the buffer
cheaply.  So a multi-line string/docstring opened above MIN is still recognized,
but a tiny change deep in a huge file no longer fontifies everything above it.
When RANGE is nil the whole buffer is fontified.  Returns nil on failure."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (let ((inhibit-message t)
              (message-log-max nil))
          (delay-mode-hooks (funcall mode))
          (font-lock-mode 1)
          (let* ((lo (max 1 (if range (car range) 1)))
                 (hi (if range (cdr range)
                       (count-lines (point-min) (point-max))))
                 (beg (progn (goto-char (point-min))
                             (forward-line (1- lo)) (point)))
                 (end (progn (goto-char (point-min))
                             (forward-line hi) (point))))
            (font-lock-ensure beg end)
            (let* ((segs (split-string (buffer-substring beg end) "\n"))
                   ;; The region ends at a line start, so the split has a
                   ;; trailing "" -- drop it so it is not stored as a line.
                   (segs (if (and segs (string-empty-p (car (last segs))))
                             (butlast segs)
                           segs))
                   (last (+ lo (length segs) -1))
                   (vec (make-vector (1+ (max hi last 0)) nil))
                   (i lo))
              (dolist (s segs) (aset vec i s) (setq i (1+ i)))
              (cons (cons lo (max last (1- lo))) vec)))))
    (error nil)))

(defun magit-difftastic--side-content-id (file id)
  "Return the content identity for FILE's side blob ID, or nil.
ID comes from `magit-difftastic--blob-ids'.  A concrete git oid is used
directly; the all-zero placeholder (a worktree side git has not hashed) falls
back to the file's stat so edits invalidate it; a nil ID (the blob ids are
unavailable, e.g. outside a refresh) yields nil, so the side is fontified fresh
and not cached -- never mis-keyed."
  (cond
   ((null id) nil)
   ((magit-difftastic--all-zero-id-p id)
    (when-let* ((st (magit-difftastic--worktree-stat file)))
      (cons 'stat st)))
   (t id)))

(defun magit-difftastic--syntax-cache-put (key entry)
  "Store ENTRY ((COVERED . VEC)) under KEY in the syntax cache."
  (when (> (hash-table-count magit-difftastic--syntax-cache)
           magit-difftastic--syntax-cache-max)
    (clrhash magit-difftastic--syntax-cache))
  (puthash key entry magit-difftastic--syntax-cache))

(defun magit-difftastic--source-vec (mode file spec content-id range)
  "Return the fontified line vector for FILE's SPEC side, content-keyed.
SPEC is the source spec ((worktree) or (blob REV)) used to fetch the side's full
text; CONTENT-ID is its content identity (`magit-difftastic--side-content-id').
RANGE is the (MIN . MAX) line window the chunks display on this side; nil means
nothing is shown on this side, so no source is fetched and nil is returned.

When CONTENT-ID is non-nil and `magit-difftastic-cache' is on, the fontified
vector is cached in `magit-difftastic--syntax-cache' keyed on
\(MODE . CONTENT-ID), so it survives refreshes and is shared between the staged
and unstaged views of the same blob.  Only RANGE's lines are fontified (see
`magit-difftastic--fontify-lines'); a cached entry is reused when it already
covers RANGE, otherwise the union of the cached and requested ranges is
re-fontified and stored (so the covered window only grows)."
  (when (and spec range)
    (let* ((key (and content-id magit-difftastic-cache (cons mode content-id)))
           (cached (and key (gethash key magit-difftastic--syntax-cache)))
           (covered (car cached)))
      (if (and covered (<= (car covered) (car range)) (>= (cdr covered) (cdr range)))
          (cdr cached)
        (let* ((want (if covered
                         (cons (min (car covered) (car range))
                               (max (cdr covered) (cdr range)))
                       range))
               (entry (when-let* ((text (magit-difftastic--source-text file spec)))
                        (magit-difftastic--fontify-lines mode text want))))
          (when (and key entry)
            (magit-difftastic--syntax-cache-put key entry))
          (and entry (cdr entry)))))))

(defun magit-difftastic--entries-line-range (entries side)
  "Return the (MIN . MAX) source line range among ENTRIES for SIDE, or nil.
ENTRIES are (SIDE NUM CODE-BEG CODE-END) tuples (see
`magit-difftastic--syntax-entries'); this is the line window that side's source
must be fontified over to colour every row the chunks display."
  (let (lo hi)
    (pcase-dolist (`(,s ,num ,_cb ,_ce) entries)
      (when (and (eq s side) (integerp num))
        (when (or (null lo) (< num lo)) (setq lo num))
        (when (or (null hi) (> num hi)) (setq hi num))))
    (and lo (cons lo hi))))

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

(defun magit-difftastic--source-vecs (mode file context old-range new-range)
  "Return (OLD-VEC . NEW-VEC): FILE's sides fontified over OLD-RANGE/NEW-RANGE.
Each RANGE is the (MIN . MAX) line window that side displays (nil to skip it).
Each side is fetched per CONTEXT's `:old-source'/`:new-source' and content-keyed
on its blob id (from `magit-difftastic--file-ids') so it is fontified once per
blob and reused across refreshes (see `magit-difftastic--source-vec')."
  (let ((ids (and magit-difftastic--file-ids
                  (gethash file magit-difftastic--file-ids))))
    (cons (magit-difftastic--source-vec
           mode file (plist-get context :old-source)
           (magit-difftastic--side-content-id file (car ids)) old-range)
          (magit-difftastic--source-vec
           mode file (plist-get context :new-source)
           (magit-difftastic--side-content-id file (cdr ids)) new-range))))

(defun magit-difftastic--apply-entries (mode entries old-vec new-vec)
  "Paint ENTRIES from whole-file vectors OLD-VEC/NEW-VEC.
Falls back to per-chunk reconstruction (limited context) when neither vector is
available.  ENTRIES are (SIDE NUM CODE-BEG CODE-END) tuples for one chunk."
  (when entries
    (if (or old-vec new-vec)
        (magit-difftastic--apply-syntax-full entries old-vec new-vec)
      (dolist (side '(old new))
        (when-let* ((side-entries (seq-filter (lambda (e) (eq (car e) side))
                                              entries)))
          (magit-difftastic--apply-syntax-side mode side-entries))))))

(defun magit-difftastic--apply-syntax-sections (file context sections)
  "Syntax-highlight every chunk in SECTIONS of FILE in one pass.
Fetches and fontifies each blob ONCE -- bounded to the deepest line ANY of
SECTIONS displays (font-lock still scans from the start for correct context) --
then paints each section from those shared vectors, so a multi-chunk file costs
one fontification per side rather than one per chunk.  The fontified lines are
content-keyed on the blob id, so they survive refreshes and are shared between
the staged and unstaged views.  No-op when FILE has no recognized major mode."
  (when-let* ((mode (magit-difftastic--mode-for-file file))
              (per-section
               (delq nil
                     (mapcar
                      (lambda (s)
                        (when-let* ((entries (magit-difftastic--syntax-entries
                                              (oref s start) (oref s end))))
                          (cons s entries)))
                      sections))))
    (let* ((all (apply #'append (mapcar #'cdr per-section)))
           (vecs (magit-difftastic--source-vecs
                  mode file context
                  (magit-difftastic--entries-line-range all 'old)
                  (magit-difftastic--entries-line-range all 'new))))
      (pcase-dolist (`(,_s . ,entries) per-section)
        (magit-difftastic--apply-entries mode entries (car vecs) (cdr vecs))))))

(defun magit-difftastic--apply-syntax (file beg end context)
  "Add major-mode syntax highlighting to the chunk FILE between BEG and END.
Fontifies the old/new source driven by CONTEXT's `:old-source'/`:new-source'
\(correct context for strings/docstrings) only as far as the lines this chunk
displays, content-keyed on the side's blob id so it is computed once per blob
and reused across refreshes.  Falls back to per-chunk reconstruction when no
source is available.  No-op when FILE has no recognized major mode.

This highlights a single chunk; the section-insertion path uses
`magit-difftastic--apply-syntax-sections' to highlight a whole file's chunks in
one fontification pass."
  (when-let* ((mode (magit-difftastic--mode-for-file file))
              (entries (magit-difftastic--syntax-entries beg end)))
    (let ((vecs (magit-difftastic--source-vecs
                 mode file context
                 (magit-difftastic--entries-line-range entries 'old)
                 (magit-difftastic--entries-line-range entries 'new))))
      (magit-difftastic--apply-entries mode entries (car vecs) (cdr vecs)))))

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

;;; Cross-chunk column alignment
;;
;; difft sizes each file's side-by-side columns to that file's own longest line,
;; so the right column -- and its line-number gutter -- starts at a different
;; column per file, leaving a buffer's chunks ragged.  When
;; `magit-difftastic-align-columns' is on we pad every two-column chunk so its
;; right column begins at the same display column as the widest chunk's.
;;
;; The padding is plain spaces inserted only in the gap BETWEEN the two columns
;; (just before the right gutter), so: difft's colours and our syntax faces ride
;; on the original text untouched; the gutters difftastic's parser reads stay at
;; a per-chunk-consistent (only wider) column, so chunk/region staging and
;; line-number hiding keep working; and the left column is never touched.

(defvar magit-difftastic--align-col nil
  "Dynamically-bound target display column for the right side-by-side column.
Bound in `magit-difftastic--insert-file-sections' to the widest chunk's
right-column start across the whole group (see
`magit-difftastic--compute-align-col') when `magit-difftastic-align-columns' is
enabled and a side-by-side layout is in use; each chunk's right column is then
padded out to this column by `magit-difftastic--align-chunk-lines'.  nil
disables alignment, so each chunk keeps difftastic's content-sized columns.")

(defun magit-difftastic--two-column-display-p ()
  "Return non-nil when `magit-difftastic-display' is a side-by-side layout."
  (member magit-difftastic-display '("side-by-side" "side-by-side-show-both")))

(defun magit-difftastic--split-chunk-bodies (rendered)
  "Split RENDERED difftastic output into a list of per-chunk body line-lists.
Difftastic's own `FILE --- N/M --- LANG' headers are dropped; each run of lines
between them becomes one element (a list of strings), exactly as
`magit-difftastic--insert-chunks' splits them for insertion."
  (let ((header-re (difftastic--chunk-regexp t))
        (chunk nil) (started nil) (bodies nil))
    (dolist (line (split-string rendered "\n"))
      (if (magit-difftastic--chunk-header-line-p header-re line)
          (progn (when started (push (nreverse chunk) bodies))
                 (setq chunk nil started t))
        (when started (push line chunk))))
    (when started (push (nreverse chunk) bodies))
    (nreverse bodies)))

(defun magit-difftastic--chunk-right-col (body-lines)
  "Return the right column's start display-column for chunk BODY-LINES, or nil.
nil when the chunk is single-column (purely additions/removals, or the inline
layout) or difftastic's parser is unavailable.  The value is measured in
display columns from the line start and is constant across the chunk's rows;
the maximum over rows is returned defensively."
  (when body-lines
    (with-temp-buffer
      ;; difftastic's parsers treat the first line of the bounds as the chunk
      ;; header, so prepend a stand-in heading just as a real chunk has one.
      (insert "@@ @@\n")
      (dolist (l body-lines) (insert l "\n"))
      (let ((beg (point-min)) (end (point-max)))
        (when (eq (magit-difftastic--chunk-layout beg end) 'side-by-side)
          (let ((cols (delq nil
                            (mapcar
                             (lambda (row)
                               (pcase-let ((`((,bol ,_eol) ,_left ,right) row))
                                 (when (and right (cadr right))
                                   (string-width
                                    (buffer-substring-no-properties
                                     bol (cadr right))))))
                             (magit-difftastic--parse-chunk-bounds beg end)))))
            (and cols (apply #'max cols))))))))

(defun magit-difftastic--compute-align-col (files)
  "Return the widest right-column start display-column across FILES, or nil.
Reads each file's rendered output from the dynamically-bound
`magit-difftastic--render-cache' and takes the maximum over every two-column
chunk (see `magit-difftastic--chunk-right-col').  nil when nothing is
two-column, so alignment is skipped."
  (let ((maxc nil))
    (dolist (file files)
      (when-let* ((rendered (and magit-difftastic--render-cache
                                 (gethash file magit-difftastic--render-cache))))
        (dolist (body (magit-difftastic--split-chunk-bodies rendered))
          (when-let* ((c (magit-difftastic--chunk-right-col body)))
            (setq maxc (if maxc (max maxc c) c))))))
    maxc))

(defun magit-difftastic--align-chunk-lines (body-lines target)
  "Return BODY-LINES padded so the right column starts at display column TARGET.
Two-column rows get plain spaces inserted just before their right gutter so its
display column becomes TARGET; the left column and all text properties are
preserved.  Single-column chunks (no right column) are returned unchanged."
  (if (not body-lines)
      body-lines
    (with-temp-buffer
      (insert "@@ @@\n")
      (let ((body-start (point)))
        (dolist (l body-lines) (insert l "\n"))
        (let ((beg (point-min)) (end (point-max)))
          (if (not (eq (magit-difftastic--chunk-layout beg end) 'side-by-side))
              body-lines
            ;; Pad rows back-to-front so an earlier row's parsed positions stay
            ;; valid after a later row is widened.
            (dolist (row (reverse (magit-difftastic--parse-chunk-bounds beg end)))
              (pcase-let ((`((,bol ,_eol) ,_left ,right) row))
                (when (and right (cadr right))
                  (let* ((rbeg (cadr right))
                         (cur (string-width
                               (buffer-substring-no-properties bol rbeg)))
                         (pad (- target cur)))
                    (when (> pad 0)
                      (save-excursion
                        (goto-char rbeg)
                        (insert (make-string pad ?\s))))))))
            ;; Extract the (now padded) body lines back out, properties intact.
            (let (out)
              (goto-char body-start)
              (dotimes (_ (length body-lines))
                (push (buffer-substring (point) (line-end-position)) out)
                (forward-line))
              (nreverse out))))))))

(defun magit-difftastic--insert-chunk (body-lines file context)
  "Insert one collapsible chunk section from BODY-LINES (difft header removed).
FILE is the repo-relative path.  CONTEXT is the diff context plist (see
`magit-difftastic--insert-file-sections'); its `:staged' and `:stageable'
entries are stored on the section value so the staging commands can rebuild the
corresponding git hunk.  The chunk's line numbers are not stored: the staging
and visiting commands read them from the section's rendered gutters (see
`magit-difftastic--chunk-displayed-lines'), which stays aligned with what the
section displays even when difft's text display merges several JSON chunks."
  ;; Drop leading/trailing blank lines that difft puts between chunks.
  (while (and body-lines (string-blank-p (car body-lines)))
    (setq body-lines (cdr body-lines)))
  (let ((rev (reverse body-lines)))
    (while (and rev (string-blank-p (car rev)))
      (setq rev (cdr rev)))
    (setq body-lines (reverse rev)))
  ;; Pad the inter-column gap so this chunk's right column lines up with the
  ;; widest chunk's (a no-op for single-column chunks and when alignment is off).
  (when (and body-lines magit-difftastic--align-col)
    (setq body-lines
          (magit-difftastic--align-chunk-lines
           body-lines magit-difftastic--align-col)))
  (when body-lines
    (let* ((start (magit-difftastic--chunk-start-line body-lines))
           (heading (if start (format "@@ line %s @@" start) "@@ @@")))
      (magit-insert-section section
          (magit-difftastic-hunk
           (list :file file
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
          ;; Syntax highlighting is applied once per file (across all chunks) by
          ;; `magit-difftastic--insert-chunks', so the file's source is fetched
          ;; and fontified a single time rather than once per chunk.
          (unless magit-difftastic-line-numbers
            (magit-difftastic--hide-line-numbers heading-start (point))))))))

(defconst magit-difftastic--chunk-header-trailer-re
  (rx " --- "
      (or (+ (not (any " \n")))      ; a language token, e.g. "Clojure"
          (seq "Text ("              ; the "Text (...)" error/limit form
               (+ (not (any ")\n")))
               ")"))
      eol)
  "Regexp matching the ` --- LANG' or ` --- Text (...)' trailer of a chunk header.
Fallback for `difftastic--chunk-regexp' when the path begins with whitespace.")

(defun magit-difftastic--chunk-header-line-p (header-re line)
  "Return non-nil when LINE is a difftastic chunk header.
Tries HEADER-RE first; falls back to the trailer regexp for lines starting with
whitespace, which `difftastic--chunk-regexp' incorrectly rejects."
  (or (string-match-p header-re line)
      ;; `difftastic--chunk-regexp' anchors the filename group with
      ;; `(not " ")', so it never matches a path that begins with a space.
      ;; Detect those with the trailer regexp instead.
      (and (string-match-p (rx bos " ") line)
           (string-match-p magit-difftastic--chunk-header-trailer-re line))))

(defun magit-difftastic--insert-chunks (rendered file context)
  "Split RENDERED difftastic output for FILE into collapsible per-chunk sections.
Difftastic's own `FILE --- N/M --- LANG' headers are consumed (not shown); each
run of text between them becomes one displayed chunk section.  CONTEXT is the
diff context plist threaded down to each chunk section."
  (let ((sections nil))
    (dolist (body (magit-difftastic--split-chunk-bodies rendered))
      (push (magit-difftastic--insert-chunk body file context) sections))
    ;; Highlight the whole file in one pass: fetch and fontify each blob a single
    ;; time, bounded to the deepest line any chunk displays, then paint every
    ;; chunk from those shared vectors (see `magit-difftastic--apply-syntax-sections').
    (when magit-difftastic-syntax-highlight
      (magit-difftastic--apply-syntax-sections
       file context (delq nil (nreverse sections))))))

(defun magit-difftastic--statuses-from-info (info)
  "Project a `magit-difftastic--raw-info' hash INFO to a statuses alist.
Each element is (PATH . (STATUS . ORIG)); see `magit-difftastic--file-statuses'."
  (let (statuses)
    (when info
      (maphash (lambda (path i)
                 (push (cons path (cons (plist-get i :status)
                                        (plist-get i :orig)))
                       statuses))
               info))
    statuses))

(defun magit-difftastic--file-statuses (diff-args)
  "Return an alist of (PATH . (STATUS . ORIG)) for the DIFF-ARGS diff.
A projection of `magit-difftastic--raw-info' (which see), so the status word is
read from the same `--raw' plumbing pass that resolves the blob ids rather than
a separate `--name-status' call.  STATUS is Magit's own status word (\"modified\",
\"new file\", \"deleted\" or \"renamed\") and ORIG is the source path for a
rename (else nil).  Used so our difftastic file headings mimic Magit's exactly,
and to collapse deleted-file sections like Magit does."
  (magit-difftastic--statuses-from-info
   (magit-difftastic--raw-info diff-args)))

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

(defun magit-difftastic--prewarm (render-files context width &optional ids)
  "Return a FILE -> rendered-string hash for RENDER-FILES of CONTEXT at WIDTH.
Files whose content is unchanged since an earlier refresh are served from the
persistent cache (`magit-difftastic--cache'); the remaining files are rendered
concurrently (`magit-difftastic--render-files') and then stored in that cache.
Files that cannot be content-keyed (or when `magit-difftastic-cache' is nil) are
simply rendered every time.

IDS, when supplied, is the FILE -> (OLD-ID . NEW-ID) hash the caller already
resolved (see `magit-difftastic--insert-file-sections'), reused so the blob ids
are read only once per refresh; otherwise it is computed here with one `--raw'
plumbing call."
  (let* ((diff-args (plist-get context :diff-args))
         (result (make-hash-table :test 'equal))
         ;; One plumbing call resolves every file's old/new blob ids for keys
         ;; (reusing the caller's when provided).
         (ids (and magit-difftastic-cache
                   (or ids
                       (ignore-errors
                         (magit-difftastic--blob-ids diff-args render-files)))))
         (keys (make-hash-table :test 'equal))
         (misses nil))
    (dolist (file render-files)
      (let* ((key (and ids (magit-difftastic--cache-key
                            file (gethash file ids) width)))
             (hit (magit-difftastic--cache-get key)))
        (when key (puthash file key keys))
        (if hit
            (puthash file hit result)
          (push file misses))))
    (when misses
      (let ((rendered (magit-difftastic--render-files
                       (mapcar (lambda (f) (cons f diff-args)) (nreverse misses))
                       width)))
        (maphash (lambda (file str)
                   (puthash file str result)
                   ;; Cache under the key computed above (nil keys are no-ops).
                   (magit-difftastic--cache-put (gethash file keys) str))
                 rendered)))
    result))

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
  ;; One `--raw' plumbing pass per group resolves, for every changed file: its
  ;; status word/rename source (for the Magit-matching heading and initial
  ;; visibility) AND its old/new blob ids -- which key BOTH the difft render
  ;; cache (the pre-warm below) and the major-mode fontification cache (bound via
  ;; `magit-difftastic--file-ids' so the syntax layer reuses these ids).  Doing
  ;; this once folds away the old separate `--name-status' call.
  (let* ((info (and (cl-some (lambda (f)
                               (not (member f magit-difftastic--stock-files)))
                             files)
                    (ignore-errors
                      (magit-difftastic--raw-info (plist-get context :diff-args)))))
         (statuses (magit-difftastic--statuses-from-info info))
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
         ;; Blob ids (FILE -> (OLD-ID . NEW-ID)) shared with the render pre-warm
         ;; and, via this dynamic binding, the fontification cache.
         (ids (and info
                   (let ((m (make-hash-table :test 'equal)))
                     (maphash (lambda (p i)
                                (puthash p (cons (plist-get i :old)
                                                 (plist-get i :new))
                                         m))
                              info)
                     m)))
         (magit-difftastic--file-ids ids)
         (width (magit-difftastic--width))
         ;; Pre-warm: resolve every difftastic-rendered file in this group up
         ;; front (stock-rendered files and rename sources are skipped -- the
         ;; former go through `magit--insert-diff', the latter are not shown).
         ;; Unchanged files are served from the cross-refresh cache and the rest
         ;; rendered in one parallel batch; the synchronous insertion loop below
         ;; then reads each file's output from this hash via
         ;; `magit-difftastic--file-diff-string'.
         (magit-difftastic--render-cache
          (let ((render-files
                 (cl-remove-if
                  (lambda (f) (or (member f magit-difftastic--stock-files)
                                  (member f rename-origins)))
                  files)))
            (when render-files
              (magit-difftastic--prewarm render-files context width ids))))
         ;; With a side-by-side layout, align every chunk's right column to the
         ;; widest chunk's across the whole group (see the "Cross-chunk column
         ;; alignment" commentary); each chunk reads this target while inserting.
         (magit-difftastic--align-col
          (and magit-difftastic-align-columns
               (magit-difftastic--two-column-display-p)
               (magit-difftastic--compute-align-col files))))
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
  (when-let* ((files (magit-difftastic--drop-whitespace-only
                      (magit-unstaged-files) nil)))    ; worktree vs index
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
    (when-let* ((files (magit-difftastic--drop-whitespace-only
                        (magit-staged-files) '("--cached"))))
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

(defcustom magit-difftastic-hidden-revision-buffers nil
  "Whether to render hidden `magit-revision-mode' buffers with difftastic.
Magit can refresh revision buffers that are not displayed in any window, for
example while updating the revision buffer associated with another Magit view.
When this option is nil, such hidden refreshes use Magit's stock revision diff
instead of running difftastic."
  :type 'boolean
  :group 'magit-difftastic)

;; These are buffer-local variables Magit sets in its diff/revision buffers;
;; declare them special to keep the byte-compiler quiet.
(defvar magit-buffer-range)
(defvar magit-buffer-typearg)
(defvar magit-buffer-diff-files)
(defvar magit-buffer-diff-args)
(defvar magit-buffer-revision)

(defun magit-difftastic--git-lines (&rest args)
  "Run \"git ARGS...\" and return its non-empty output lines as a list."
  (with-temp-buffer
    (apply #'process-file "git" nil t nil args)
    (split-string (buffer-string) "\n" t)))

;;; Whitespace-ignoring diff flags
;;
;; difft has no whitespace-ignore option, and Git does not apply its own
;; whitespace flags (`-w', `--ignore-blank-lines', ...) to an external diff tool,
;; so we cannot make difft skip whitespace within a file.  But difft already
;; ignores whitespace structurally for recognised languages, and for the
;; remaining noise -- files whose ONLY differences are whitespace -- we honour
;; the user's intent at file granularity: when such a flag is active in the
;; magit buffer's diff args, we forward it to the plumbing that lists changed
;; files, so a whitespace-only file simply drops out (exactly as stock Magit
;; shows nothing for it) while files with real changes are still rendered.

(defconst magit-difftastic--whitespace-flags
  '("-w" "--ignore-all-space"
    "-b" "--ignore-space-change"
    "--ignore-space-at-eol"
    "--ignore-blank-lines"
    "--ignore-cr-at-eol")
  "Git `diff' flags that ignore some class of whitespace difference.")

(defun magit-difftastic--whitespace-args ()
  "Return the whitespace-ignoring flags active in the current buffer's diff args.
Reads `magit-buffer-diff-args' (Magit's per-buffer `diff' arguments) and keeps
only the entries in `magit-difftastic--whitespace-flags'.  These are forwarded
to the file-listing queries (see `magit-difftastic--drop-whitespace-only' and
`magit-difftastic--diff-context') so whitespace-only files are dropped -- difft
itself cannot honour them."
  (when (boundp 'magit-buffer-diff-args)
    (seq-filter (lambda (a) (member a magit-difftastic--whitespace-flags))
                magit-buffer-diff-args)))

(defun magit-difftastic--drop-whitespace-only (files selector)
  "Return FILES without entries whose only changes are whitespace.
Honours the whitespace-ignoring flags active in the current buffer (see
`magit-difftastic--whitespace-args'); a no-op when none are set or FILES is
empty.  SELECTOR is the git `diff' selector for the view -- nil for the
worktree against the index, `(\"--cached\")' for the index against HEAD, or a
range list.

Uses `git diff --numstat WS SELECTOR': unlike `--name-only', `--numstat'
applies the whitespace flags to the change decision, so a file whose only
differences are whitespace is absent from its output.  We keep only the files
it still reports as changed -- matching what stock Magit shows."
  (let ((ws (magit-difftastic--whitespace-args)))
    (if (or (null ws) (null files))
        files
      (let* ((lines (apply #'magit-difftastic--git-lines
                           (append '("--no-pager" "diff" "--numstat")
                                   ws selector '("--") files)))
             ;; Each line is "ADDED\tDELETED\tPATH" (binary: "-\t-\tPATH").
             (changed (delq nil
                            (mapcar (lambda (l)
                                      (when (string-match
                                             "\\`[^\t]*\t[^\t]*\t\\(.*\\)\\'" l)
                                        (match-string 1 l)))
                                    lines))))
        (seq-filter (lambda (f) (member f changed)) files)))))

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
             ;; difft cannot ignore whitespace, so when the user set a
             ;; whitespace-ignore flag on the diff, drop files whose only
             ;; differences are whitespace (GH #5).
             (files (magit-difftastic--drop-whitespace-only
                     (apply #'magit-difftastic--git-lines
                            (append '("--no-pager" "diff" "--name-only")
                                    selector '("--") diff-files))
                     selector)))
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
                  (or magit-difftastic-hidden-revision-buffers
                      (get-buffer-window (current-buffer) t))
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

(defcustom magit-difftastic-bind-evil-keys t
  "Whether to bind the chunk-staging keys in Evil's normal and visual states.
When non-nil (the default) and `magit-difftastic-mode' is enabled with Evil
loaded, `s', `u' and `x' are bound in `magit-mode-map' and
`magit-section-mode-map' (normal and visual states) to the difftastic chunk
staging commands, so per-chunk and region (line-range) staging work under
`evil-collection-magit' -- which otherwise routes those keys to the
file-prompting `magit-stage-files'/`magit-unstage-files'.

Set to nil if you remap these keys yourself and do not want magit-difftastic to
shadow your bindings.  The staging commands (`magit-difftastic-stage-chunk',
`magit-difftastic-unstage-chunk', `magit-difftastic-discard-chunk') remain
available to bind manually; each falls back to the stock Magit command when
point is not on a difftastic chunk.

This only affects the Evil-state bindings; the command advice that makes the
stock magit stage/unstage/discard commands chunk-aware is unaffected.  Toggling
this re-applies immediately while the mode is on (otherwise it takes effect the
next time `magit-difftastic-mode' is enabled)."
  :type 'boolean
  :group 'magit-difftastic
  :set (lambda (sym val)
         (set-default sym val)
         ;; Re-apply right away when the mode is already active, so turning the
         ;; option off removes our shadowing bindings without a mode toggle.
         (when (and (bound-and-true-p magit-difftastic-mode)
                    (fboundp 'magit-difftastic--set-evil-keys))
           (magit-difftastic--set-evil-keys t))))

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
evil-collection-magit[-section] puts there.

Binding is gated on `magit-difftastic-bind-evil-keys': we install our commands
only when ENABLE and that option are both non-nil; otherwise the keys are
unbound (falling through to Magit), so users who remap `s'/`u'/`x' can opt out."
  (when (fboundp 'evil-define-key*)
    (let ((bind (and enable magit-difftastic-bind-evil-keys)))
      (dolist (map '(magit-mode-map magit-section-mode-map))
        (when (boundp map)
          (pcase-dolist (`(,key . ,cmd) magit-difftastic--evil-keys)
            ;; A nil definition removes our override (falls through to magit's).
            (evil-define-key* '(normal visual) (symbol-value map)
                              key (and bind cmd))))))))

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
diffs).  Evil normal/visual-state keys are also bound so per-chunk and region
\(line-range) staging work; set `magit-difftastic-bind-evil-keys' to nil to opt
out if you remap those keys yourself.

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
