;;; magit-difftastic-test.el --- Tests for magit-difftastic -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; ERT test suite for magit-difftastic.
;;
;; Two kinds of tests live here:
;;
;;   - Unit tests for the pure helpers (diff parsing, hunk overlap, line
;;     classification, width selection).  These have no external dependencies
;;     and always run.
;;
;;   - Integration tests that exercise the real rendering + staging pipeline
;;     against a throwaway git repository using `difft' and `git'.  They are
;;     guarded with `skip-unless' and are skipped automatically when either
;;     executable is missing.
;;
;; Run with `eldev test', or directly:
;;
;;   emacs -batch -L . -L test -l test/magit-difftastic-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'magit-difftastic)

;; Magit 4.6 renamed two diff buffer-locals (`magit-buffer-range' ->
;; `magit-buffer-diff-range', `magit-buffer-typearg' ->
;; `magit-buffer-diff-typearg').  Declare both spellings special so the tests
;; can dynamically bind whichever the running Magit reads (see
;; `dst-test--let-diff-locals').
(defvar magit-buffer-range)
(defvar magit-buffer-diff-range)
(defvar magit-buffer-typearg)
(defvar magit-buffer-diff-typearg)
(defvar magit-buffer-diff-files)

(defmacro dst-test--let-diff-locals (range typearg diff-files &rest body)
  "Bind Magit's diff buffer-locals around BODY, for pre- and post-4.6 Magit.
RANGE, TYPEARG and DIFF-FILES are bound to both the old and the 4.6 names, so
`magit-difftastic--diff-context' sees them whichever Magit is installed."
  (declare (indent 3) (debug (form form form body)))
  `(let ((magit-buffer-range ,range)
         (magit-buffer-diff-range ,range)
         (magit-buffer-typearg ,typearg)
         (magit-buffer-diff-typearg ,typearg)
         (magit-buffer-diff-files ,diff-files))
     ,@body))

;;;; Fixtures --------------------------------------------------------------

(defconst dst-test--old
  "alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\n"
  "Committed (HEAD) content of the sample file.")

(defconst dst-test--new
  "alpha\nBRAVO-changed\ncharlie\ndelta-modified\necho\nfoxtrot\ngolf-added\n"
  "Worktree content of the sample file: a modification on lines 2 and 4
plus an addition at the end.")

(defconst dst-test--displays '("inline" "side-by-side" "side-by-side-show-both")
  "Display modes exercised by the integration tests.")

(defvar dst-test--have-tools
  (and (executable-find "difft") (executable-find "git"))
  "Non-nil when both `difft' and `git' are available.")

;;;; Integration helpers ---------------------------------------------------

(defun dst-test--git (&rest args)
  "Run \"git ARGS...\" in `default-directory'; return output, error on failure."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil args)))
      (unless (eq status 0)
        (error "git %S failed (%s):\n%s" args status (buffer-string))))
    (buffer-string)))

(defun dst-test--write (file content)
  "Write CONTENT to FILE (relative to `default-directory'), creating dirs."
  (when-let* ((dir (file-name-directory file)))
    (make-directory dir t))
  (with-temp-file file (insert content)))

(defmacro dst-test--with-repo (committed worktree &rest body)
  "Run BODY in a fresh temp git repo.
COMMITTED and WORKTREE are alists of (FILE . CONTENT).  COMMITTED is committed
at HEAD, then WORKTREE files are written into the worktree (unstaged).
`default-directory' is bound to the repo root for BODY and the repo is removed
afterwards."
  (declare (indent 2))
  `(let* ((dst-test--dir (make-temp-file "dst-test-" t))
          (default-directory (file-name-as-directory dst-test--dir))
          ;; Keep the test hermetic regardless of the user's global git config.
          (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null"
                                          "GIT_CONFIG_SYSTEM=/dev/null"
                                          "GIT_AUTHOR_NAME=t"
                                          "GIT_AUTHOR_EMAIL=t@t"
                                          "GIT_COMMITTER_NAME=t"
                                          "GIT_COMMITTER_EMAIL=t@t")
                                        process-environment)))
     (unwind-protect
         (progn
           (dst-test--git "init" "-q")
           (pcase-dolist (`(,f . ,c) ,committed) (dst-test--write f c))
           (dst-test--git "add" "-A")
           (dst-test--git "commit" "-qm" "init")
           (pcase-dolist (`(,f . ,c) ,worktree) (dst-test--write f c))
           ,@body)
       (delete-directory dst-test--dir t))))

(defun dst-test--chunk-buffer-string (file display)
  "Return a chunk buffer string (heading + difft body) for FILE in DISPLAY mode.
Mirrors what `magit-difftastic--insert-chunk' inserts: difft's own
`FILE --- LANG' header line is dropped and our `@@ line N @@' heading prepended.
Assumes FILE's change renders as a single difftastic chunk."
  (let* ((magit-difftastic-display display)
         (rendered (magit-difftastic--file-diff-string
                    file magit-difftastic--diff-base))
         (body (mapconcat #'identity (cdr (split-string rendered "\n")) "\n")))
    (concat "@@ line 1 @@\n" body)))

(defun dst-test--make-section (beg content end &optional value)
  "Build a minimal `magit-difftastic-hunk' section spanning BEG..END.
CONTENT is the body start; VALUE, when given, is stored as the section value."
  (let ((s (magit-section)))
    (oset s type 'magit-difftastic-hunk)
    (oset s start beg)
    (oset s content content)
    (oset s end end)
    (when value (oset s value value))
    s))

(defun dst-test--display-chunk-bodies (file display)
  "Return a list of difft display-chunk body strings for FILE in DISPLAY mode.
Splits FILE's rendered difftastic output on difft's own `FILE --- N/M --- LANG'
chunk headers, exactly as `magit-difftastic--insert-chunks' does, so each
element is one displayed chunk's body (the header line dropped)."
  (let* ((magit-difftastic-display display)
         (rendered (magit-difftastic--file-diff-string
                    file magit-difftastic--diff-base))
         (header-re (difftastic--chunk-regexp t))
         (bodies nil) (chunk nil) (started nil))
    (dolist (line (split-string rendered "\n"))
      (if (magit-difftastic--chunk-header-line-p header-re line)
          (progn (when started (push (string-join (nreverse chunk) "\n") bodies))
                 (setq chunk nil started t))
        (when started (push line chunk))))
    (when started (push (string-join (nreverse chunk) "\n") bodies))
    (nreverse bodies)))

(defmacro dst-test--with-region (beg end &rest body)
  "Evaluate BODY with `region-beginning'/`region-end' stubbed to BEG and END."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'region-beginning) (lambda () ,beg))
             ((symbol-function 'region-end)       (lambda () ,end)))
     ,@body))

;;;; Unit tests: diff parsing ----------------------------------------------

(ert-deftest magit-difftastic--parse-diff/header-and-hunks ()
  "Header is captured and each @@ hunk parsed with correct ranges and text."
  (let* ((diff (concat "diff --git a/f b/f\n"
                       "index 1111111..2222222 100644\n"
                       "--- a/f\n"
                       "+++ b/f\n"
                       "@@ -1,2 +1,2 @@\n"
                       " alpha\n"
                       "-bravo\n"
                       "+BRAVO\n"
                       "@@ -10 +10,2 @@\n"
                       " ctx\n"
                       "+added\n"))
         (parsed (magit-difftastic--parse-diff diff))
         (header (car parsed))
         (hunks (cdr parsed)))
    (should (string-match-p "diff --git a/f b/f" header))
    (should (string-match-p "\\+\\+\\+ b/f" header))
    (should (= (length hunks) 2))
    (let ((h (nth 0 hunks)))
      (should (= (plist-get h :old-beg) 1))
      (should (= (plist-get h :old-len) 2))
      (should (= (plist-get h :new-beg) 1))
      (should (= (plist-get h :new-len) 2))
      (should (string-match-p "^-bravo$" (plist-get h :text)))
      (should (string-match-p "^\\+BRAVO$" (plist-get h :text))))
    (let ((h (nth 1 hunks)))
      ;; A missing `,len' defaults to 1.
      (should (= (plist-get h :old-beg) 10))
      (should (= (plist-get h :old-len) 1))
      (should (= (plist-get h :new-beg) 10))
      (should (= (plist-get h :new-len) 2)))))

(ert-deftest magit-difftastic--parse-diff/empty ()
  "Empty diff text yields an empty header and no hunks."
  (let ((parsed (magit-difftastic--parse-diff "")))
    (should (equal (car parsed) ""))
    (should (null (cdr parsed)))))

(ert-deftest magit-difftastic--split-hunks/counts ()
  "Hunk-only text is split on each @@ boundary."
  (let ((text "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n"))
    (should (= (length (magit-difftastic--split-hunks text)) 2)))
  (should (null (magit-difftastic--split-hunks ""))))

;;;; Unit tests: hunk overlap ----------------------------------------------

(ert-deftest magit-difftastic--hunk-covers-p/old-side ()
  (let ((h (list :old-beg 5 :old-len 3 :new-beg 5 :new-len 0)))
    (should (magit-difftastic--hunk-covers-p h '(5) nil))
    (should (magit-difftastic--hunk-covers-p h '(7) nil))
    (should-not (magit-difftastic--hunk-covers-p h '(8) nil))
    ;; A zero-length new side never matches a new line.
    (should-not (magit-difftastic--hunk-covers-p h nil '(5)))))

(ert-deftest magit-difftastic--hunk-covers-p/new-side ()
  (let ((h (list :old-beg 1 :old-len 0 :new-beg 4 :new-len 2)))
    (should (magit-difftastic--hunk-covers-p h nil '(4)))
    (should (magit-difftastic--hunk-covers-p h nil '(5)))
    (should-not (magit-difftastic--hunk-covers-p h nil '(6)))
    ;; A zero-length old side never matches an old line.
    (should-not (magit-difftastic--hunk-covers-p h '(1) nil))))

;;;; Unit tests: line classification + heading -----------------------------

(ert-deftest magit-difftastic--line-side+num/classifies ()
  (should (equal (magit-difftastic--line-side+num "12 foo") '(old . 12)))
  (should (equal (magit-difftastic--line-side+num "   7 bar") '(new . 7)))
  (should-not (magit-difftastic--line-side+num "@@ line @@"))
  (should-not (magit-difftastic--line-side+num "")))

(ert-deftest magit-difftastic--chunk-start-line/first-number ()
  (should (equal (magit-difftastic--chunk-start-line '("   42 foo" "43 bar")) "42"))
  (should (equal (magit-difftastic--chunk-start-line '("7 x")) "7"))
  (should-not (magit-difftastic--chunk-start-line '("no numbers" "here"))))

;;;; Unit tests: evil key gating (issue #4) --------------------------------

(ert-deftest magit-difftastic--set-evil-keys/honors-option ()
  "Evil staging keys are bound only when the mode is on AND the option is set.
Guards GH #4: `magit-difftastic-bind-evil-keys' must let users opt out of the
`s'/`u'/`x' bindings; when off (or when disabling), the keys are unbound (nil
definitions) so they fall through to the user's own bindings."
  (let (calls)
    (cl-letf (((symbol-function 'evil-define-key*)
               (lambda (_states _map key def) (push (cons key def) calls))))
      ;; mode on + option on -> our staging commands are bound.
      (setq calls nil)
      (let ((magit-difftastic-bind-evil-keys t))
        (magit-difftastic--set-evil-keys t))
      (should calls)
      (should (assoc "s" calls))
      (should (cl-every #'cdr calls))   ; every definition non-nil
      ;; mode on + option off -> keys unbound (every definition nil).
      (setq calls nil)
      (let ((magit-difftastic-bind-evil-keys nil))
        (magit-difftastic--set-evil-keys t))
      (should calls)
      (should-not (cl-some #'cdr calls))
      ;; mode off -> unbound regardless of the option.
      (setq calls nil)
      (let ((magit-difftastic-bind-evil-keys t))
        (magit-difftastic--set-evil-keys nil))
      (should calls)
      (should-not (cl-some #'cdr calls)))))

;;;; Unit tests: default rendering + overrides (issue #16) ------------------

(ert-deftest magit-difftastic--render-with-difftastic-p/xor-truth-table ()
  "The predicate XORs the default renderer with the per-file override.
Guards GH #16: a file follows `magit-difftastic-default-rendering' unless it is
listed in `magit-difftastic--rendering-overrides', which flips it to the other
renderer -- under either default."
  (with-temp-buffer
    ;; Default difftastic: plain files render with difftastic ...
    (let ((magit-difftastic-default-rendering 'difftastic)
          (magit-difftastic--rendering-overrides nil))
      (should (magit-difftastic--render-with-difftastic-p "a.txt")))
    ;; ... and an override flips just the listed file to stock.
    (let ((magit-difftastic-default-rendering 'difftastic)
          (magit-difftastic--rendering-overrides '("a.txt")))
      (should-not (magit-difftastic--render-with-difftastic-p "a.txt"))
      (should (magit-difftastic--render-with-difftastic-p "b.txt")))
    ;; Default stock: plain files render with stock Magit ...
    (let ((magit-difftastic-default-rendering 'stock)
          (magit-difftastic--rendering-overrides nil))
      (should-not (magit-difftastic--render-with-difftastic-p "a.txt")))
    ;; ... and an override flips just the listed file to difftastic.
    (let ((magit-difftastic-default-rendering 'stock)
          (magit-difftastic--rendering-overrides '("a.txt")))
      (should (magit-difftastic--render-with-difftastic-p "a.txt"))
      (should-not (magit-difftastic--render-with-difftastic-p "b.txt")))))

(ert-deftest magit-difftastic--insert-file-sections/stock-default-no-renders ()
  "With a `stock' default every file dispatches to the stock inserter.
No difftastic pre-warm (and hence no difft process) may be spawned for a group
whose files all render stock."
  (with-temp-buffer
    (let ((magit-difftastic-default-rendering 'stock)
          (magit-difftastic--rendering-overrides nil)
          (magit-difftastic-align-columns nil)
          stock difft prewarmed)
      (cl-letf (((symbol-function 'magit-difftastic--insert-stock-file)
                 (lambda (file _context &optional _orig) (push file stock)))
                ((symbol-function 'magit-difftastic--insert-difftastic-file)
                 (lambda (file _context _statuses) (push file difft)))
                ((symbol-function 'magit-difftastic--prewarm)
                 (lambda (&rest _)
                   (setq prewarmed t)
                   (make-hash-table :test 'equal))))
        (magit-difftastic--insert-file-sections
         '("a.txt" "b.txt") (magit-difftastic--context-unstaged)))
      (should (equal (nreverse stock) '("a.txt" "b.txt")))
      (should-not difft)
      (should-not prewarmed))))

(ert-deftest magit-difftastic-integration/stock-rename-survives-toggle ()
  "Stock renames retain both paths when another file changes renderer."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo
      '(("old.txt" . "alpha\nbravo\ncharlie\n")
        ("other.txt" . "one\ntwo\n")) nil
    (dst-test--git "mv" "old.txt" "new.txt")
    (dst-test--write "other.txt" "ONE\ntwo\n")
    (dst-test--git "add" "other.txt")
    (dolist (default '(stock difftastic))
      (dolist (other-difftastic '(nil t))
        (with-temp-buffer
          (magit-status-mode)
          (let ((inhibit-read-only t)
                (magit-difftastic-default-rendering default)
                (magit-difftastic--rendering-overrides
                 (if (eq default 'stock)
                     (and other-difftastic '("other.txt"))
                   (append '("new.txt")
                           (unless other-difftastic '("other.txt"))))))
            (magit-insert-section (root)
              (magit-difftastic--insert-file-sections
               (magit-staged-files) (magit-difftastic--context-staged)))
            (should (equal (magit-difftastic--buffer-files)
                           '("new.txt" "other.txt")))
            (should (string-match-p "renamed +old.txt -> new.txt"
                                    (buffer-string)))
            (should-not (string-match-p "new file +new.txt"
                                        (buffer-string)))))))))

(ert-deftest magit-difftastic--status-advice/renderer-dispatch ()
  "Status advice delegates only untouched stock-default buffers to Magit."
  (dolist (pair '((magit-difftastic--insert-staged-advice
                  . magit-difftastic-insert-staged-changes)
                 (magit-difftastic--insert-unstaged-advice
                  . magit-difftastic-insert-unstaged-changes)))
    (dolist (default '(stock difftastic))
      (dolist (overrides '(nil ("a.txt")))
        (with-temp-buffer
          (let ((magit-difftastic-default-rendering default)
                (magit-difftastic--rendering-overrides overrides)
                called)
            (cl-letf (((symbol-function (cdr pair))
                       (lambda () (setq called 'difftastic))))
              (funcall (car pair)
                       (lambda (&rest args) (setq called args)) 'sentinel)
              (should (equal called
                             (if (and (eq default 'stock) (null overrides))
                                 '(sentinel)
                               'difftastic))))))))))

(ert-deftest magit-difftastic-integration/stock-status-passthrough ()
  "Untouched stock status output matches Magit with the mode disabled."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo
      '(("old.txt" . "alpha\nbravo\ncharlie\n")
        ("other.txt" . "one\ntwo\n"))
      '(("other.txt" . "ONE\ntwo\n"))
    (dst-test--git "mv" "old.txt" "new.txt")
    (let ((was-enabled magit-difftastic-mode)
          (magit-difftastic-default-rendering 'stock))
      (unwind-protect
          (cl-labels ((render ()
                        (with-temp-buffer
                          (magit-status-mode)
                          (let ((inhibit-read-only t))
                            (magit-insert-section (root)
                              (magit-insert-staged-changes)
                              (magit-insert-unstaged-changes)))
                          (list (buffer-substring-no-properties
                                 (point-min) (point-max))
                                (magit-difftastic--buffer-files)))))
            (magit-difftastic-mode -1)
            (let ((native (render)))
              (should (equal (cadr native) '("new.txt" "other.txt")))
              (magit-difftastic-mode 1)
              (cl-letf (((symbol-function 'magit-difftastic--raw-info)
                         (lambda (&rest _) (ert-fail "Unexpected raw-info")))
                        ((symbol-function 'magit-difftastic--insert-file-sections)
                         (lambda (&rest _) (ert-fail "Unexpected per-file rendering")))
                        ((symbol-function 'magit-difftastic--prewarm)
                         (lambda (&rest _) (ert-fail "Unexpected prewarm"))))
                (should (equal (render) native)))
              (magit-difftastic-mode -1)
              (should (equal (render) native))))
        (magit-difftastic-mode (if was-enabled 1 -1))))))

(ert-deftest magit-difftastic-toggle-file-rendering/override-roundtrip ()
  "Toggling records a buffer-local override; toggling again removes it.
The override is what the predicate consults on every (refresh-like) re-render,
so recording it is what makes the choice survive refreshes."
  (with-temp-buffer
    (let ((magit-difftastic-default-rendering 'difftastic)
          (magit-difftastic--rendering-overrides nil)
          (refreshes 0))
      (cl-letf (((symbol-function 'magit-difftastic--enclosing-file)
                 (lambda () "a.txt"))
                ((symbol-function 'magit-refresh)
                 (lambda () (cl-incf refreshes))))
        (magit-difftastic-toggle-file-rendering)
        (should (equal magit-difftastic--rendering-overrides '("a.txt")))
        (should-not (magit-difftastic--render-with-difftastic-p "a.txt"))
        (should (= refreshes 1))
        ;; A second toggle removes the override, back to the default.
        (magit-difftastic-toggle-file-rendering)
        (should-not magit-difftastic--rendering-overrides)
        (should (magit-difftastic--render-with-difftastic-p "a.txt"))
        (should (= refreshes 2))))))

(ert-deftest magit-difftastic-toggle-file-rendering/whole-buffer-prefix ()
  "With a prefix argument the whole buffer toggles via `--buffer-files'.
No overrides -> every changed file is toggled to the non-default renderer; any
override present -> they are all cleared (every file back to the default)."
  (with-temp-buffer
    (let ((magit-difftastic-default-rendering 'difftastic)
          (magit-difftastic--rendering-overrides nil))
      (cl-letf (((symbol-function 'magit-difftastic--buffer-files)
                 (lambda () '("a.txt" "b.txt")))
                ((symbol-function 'magit-refresh) #'ignore))
        (magit-difftastic-toggle-file-rendering '(4))
        (should (equal magit-difftastic--rendering-overrides
                       '("a.txt" "b.txt")))
        (should-not (magit-difftastic--render-with-difftastic-p "a.txt"))
        (magit-difftastic-toggle-file-rendering '(4))
        (should-not magit-difftastic--rendering-overrides)
        (should (magit-difftastic--render-with-difftastic-p "a.txt"))))))

(ert-deftest magit-difftastic--buffer-files/walks-file-sections ()
  "`--buffer-files' collects every `file' section's path, without duplicates.
Both the difftastic file sections and stock `magit-file-section's have type
`file' with the repo-relative path as the section value."
  (with-temp-buffer
    (cl-flet ((section (type &optional value children)
                (let ((s (magit-section)))
                  (oset s type type)
                  (oset s value value)
                  (oset s children children)
                  s)))
      (let ((magit-root-section
             (section 'root nil
                      (list (section 'unstaged nil
                                     (list (section 'file "a.txt")
                                           (section 'file "b.txt")))
                            ;; a.txt also staged: reported once.
                            (section 'staged nil
                                     (list (section 'file "a.txt")))))))
        (should (equal (magit-difftastic--buffer-files)
                       '("a.txt" "b.txt"))))
      ;; No root section (an unrendered buffer) yields no files.
      (let ((magit-root-section nil))
        (should-not (magit-difftastic--buffer-files))))))

(ert-deftest magit-difftastic--insert-diff-advice/stock-default-passthrough ()
  "An untouched diff buffer with a `stock' default goes straight to ORIG.
With `magit-difftastic-default-rendering' set to `stock' and no per-file
override, the around-advice must not even classify the diff: ORIG renders the
whole buffer, byte-identical to stock Magit (diffstat included).  One override
is enough to route back through the difftastic machinery."
  (with-temp-buffer
    (let ((magit-difftastic-diff-buffers t)
          (magit-difftastic-default-rendering 'stock)
          (magit-difftastic--rendering-overrides nil)
          orig-called context-calls)
      (cl-letf (((symbol-function 'magit-difftastic--diff-context)
                 (lambda () (push t context-calls) nil)))
        (magit-difftastic--insert-diff-advice
         (lambda (&rest _) (setq orig-called t)))
        (should orig-called)
        (should-not context-calls)
        ;; With an override present the diff is classified again.
        (setq orig-called nil)
        (setq magit-difftastic--rendering-overrides '("a.txt"))
        (magit-difftastic--insert-diff-advice
         (lambda (&rest _) (setq orig-called t)))
        (should context-calls)
        ;; The stubbed context is nil, so ORIG still runs as the fallback.
        (should orig-called)))))

;;;; Unit tests: section keymap --------------------------------------------

(ert-deftest magit-difftastic-hunk-section-map/parents-magit-hunk-map ()
  "The chunk section map inherits Magit's hunk section map.
A section's keymap replaces Magit's own, so keys bound only there
\(e.g. `C-j') must come through the parent."
  (should (eq (keymap-parent magit-difftastic-hunk-section-map)
              magit-hunk-section-map))
  ;; `C-j' resolves through the parent to a real command.
  (should (commandp (lookup-key magit-difftastic-hunk-section-map
                                (kbd "C-j")))))

;;;; Unit tests: width / wrapping knob -------------------------------------

(ert-deftest magit-difftastic--width/honors-custom ()
  (let ((magit-difftastic-min-width 40))
    (let ((magit-difftastic-width 100))
      (should (= (magit-difftastic--width) 100)))
    ;; Below the floor, clamp to `magit-difftastic-min-width'.
    (let ((magit-difftastic-width 10))
      (should (= (magit-difftastic--width) 40)))
    ;; The window default still respects the floor.
    (let ((magit-difftastic-width 'window))
      (should (>= (magit-difftastic--width) 40))))
  ;; A custom floor is honored too.
  (let ((magit-difftastic-min-width 72)
        (magit-difftastic-width 10))
    (should (= (magit-difftastic--width) 72))))

;;;; Integration: rendering + parsing --------------------------------------

(ert-deftest magit-difftastic-integration/classify-and-parse ()
  "difftastic's parser classifies each rendered chunk and yields line numbers."
  (skip-unless dst-test--have-tools)
  (skip-unless (fboundp 'difftastic--classify-chunk))
  (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
      `(("sample.txt" . ,dst-test--new))
    (dolist (display dst-test--displays)
      (let ((magit-difftastic-display display))
        (with-temp-buffer
          (insert (dst-test--chunk-buffer-string "sample.txt" display))
          (let ((expected (if (equal display "inline")
                              'single-column 'side-by-side))
                (lines (magit-difftastic--parse-chunk-bounds
                        (point-min) (point-max))))
            (should (eq (magit-difftastic--chunk-layout (point-min) (point-max))
                        expected))
            (should lines)
            ;; Every old/new number difft reports is a real file line (1..7).
            (dolist (l lines)
              (pcase-let ((`(,_ ,left ,right) l))
                (when (car left)  (should (<= 1 (car left) 7)))
                (when (car right) (should (<= 1 (car right) 7)))))))))))

;;;; Integration: visiting -------------------------------------------------

(ert-deftest magit-difftastic-integration/visit-line-resolves-row-at-point ()
  "Visiting resolves the worktree line of the row at point in every layout.
On a body row the row's own new-side line wins -- visiting from the middle of
a chunk must not jump to the chunk's first change.  On the chunk heading the
historic first-change fallback applies."
  (skip-unless dst-test--have-tools)
  (skip-unless (fboundp 'difftastic--parse-single-column-chunk))
  (dolist (display dst-test--displays)
    (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
        `(("sample.txt" . ,dst-test--new))
      (let ((magit-difftastic-display display))
        (with-temp-buffer
          (insert (dst-test--chunk-buffer-string "sample.txt" display))
          (goto-char (point-min))
          (let ((sec (dst-test--make-section
                      (point-min) (line-end-position) (point-max))))
            ;; Heading row: no body row at point -> first-change fallback.
            (should-not (magit-difftastic--chunk-line-at-point sec))
            (let ((lines (magit-difftastic--chunk-displayed-lines sec)))
              (should (equal (magit-difftastic--chunk-visit-line sec)
                             (or (car (cdr lines)) (car (car lines))))))
            ;; A change in the middle of the chunk resolves to ITS line.
            (goto-char (point-min))
            (search-forward "delta-modified")
            (should (equal 4 (magit-difftastic--chunk-visit-line sec)))
            (if (equal display "inline")
                ;; An old-side-only row resolves via its old-side line.
                (progn
                  (goto-char (point-min))
                  (re-search-forward "^4 +delta$")
                  (should (equal 4 (magit-difftastic--chunk-visit-line sec))))
              ;; A context row (only displayed side-by-side) likewise.
              (goto-char (point-min))
              (search-forward "charlie")
              (should (equal 3 (magit-difftastic--chunk-visit-line sec))))
            ;; The trailing addition resolves to the last new line.
            (goto-char (point-min))
            (search-forward "golf-added")
            (should (equal 7 (magit-difftastic--chunk-visit-line sec)))))))))

;;;; Integration: region (line-range) staging ------------------------------

(ert-deftest magit-difftastic-integration/region-staging-resolves ()
  "Selecting the modified row stages the correct change in every layout.
In inline the row is new-side only, so only the addition is staged; in
side-by-side the row carries both sides, so the whole modification is staged."
  (skip-unless dst-test--have-tools)
  (dolist (display dst-test--displays)
    (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
        `(("sample.txt" . ,dst-test--new))
      (let ((magit-difftastic-display display))
       (with-temp-buffer
        (insert (dst-test--chunk-buffer-string "sample.txt" display))
        (goto-char (point-min))
        (let ((sec (dst-test--make-section
                    (point-min) (line-end-position) (point-max))))
          (search-forward "delta-modified")
          (dst-test--with-region (line-beginning-position) (line-end-position)
            (let* ((sel (magit-difftastic--region-selected-lines sec))
                   (patch (magit-difftastic--region-patch
                           "sample.txt" nil "-" (car sel) (cdr sel))))
              (should (memq 4 (cdr sel)))   ; new line 4 always selected
              (should patch)
              (with-temp-buffer
                (insert patch)
                (should (eq 0 (call-process-region
                               (point-min) (point-max) "git" nil nil nil
                               "apply" "--cached" "-"))))
              (let ((staged (dst-test--git "--no-pager" "diff" "--cached" "-U0")))
                (should (string-match-p "^\\+delta-modified$" staged))
                ;; The bravo modification and the golf addition were NOT selected.
                (should-not (string-match-p "BRAVO-changed" staged))
                (should-not (string-match-p "golf-added" staged))
                (if (equal display "inline")
                    (should-not (string-match-p "^-delta$" staged))
                  (should (string-match-p "^-delta$" staged))))))))))))

;;;; Integration: whole-chunk staging --------------------------------------

(ert-deftest magit-difftastic-integration/chunk-patch-stages-whole-chunk ()
  "`--chunk-patch' (no region) stages every change the chunk covers.
The chunk's line numbers are read from the SECTION's rendered gutters, so the
section is built over real difftastic-rendered text."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
      `(("sample.txt" . ,dst-test--new))
    (let ((magit-difftastic-display "side-by-side-show-both"))
      (with-temp-buffer
        (insert (dst-test--chunk-buffer-string "sample.txt" "side-by-side-show-both"))
        (let* ((value (list :file "sample.txt" :staged nil))
               (sec (dst-test--make-section
                     (point-min)
                     (save-excursion (goto-char (point-min)) (line-end-position))
                     (point-max) value))
               (patch (magit-difftastic--chunk-patch sec)))
          (should patch)
          (with-temp-buffer
            (insert patch)
            (should (eq 0 (call-process-region
                           (point-min) (point-max) "git" nil nil nil
                           "apply" "--cached" "-"))))
          (let ((staged (dst-test--git "--no-pager" "diff" "--cached")))
            (should (string-match-p "^\\+BRAVO-changed$" staged))
            (should (string-match-p "^\\+delta-modified$" staged))
            (should (string-match-p "^\\+golf-added$" staged))))))))

(ert-deftest magit-difftastic-integration/chunk-patch-maps-displayed-section ()
  "`--chunk-patch' maps a section onto the hunk it DISPLAYS, not its ordinal.
difft's text display can merge several `--display json' chunks into one
displayed section, so a section's display position is NOT a valid index into the
JSON chunk list -- keying off it staged an unrelated hunk (discarding one chunk
reverted a different one).

Here two well-separated changes render as two display chunks.  We build a
section over the SECOND chunk but tag it with a stale `:index 0' (what the buggy
code keyed off); the patch must still target the SECOND change."
  (skip-unless dst-test--have-tools)
  (let* ((base (cl-loop for i from 1 to 20
                        collect (format "(defvar var-%d %d)" i i)))
         (old (concat ";;; m.el -*- lexical-binding: t; -*-\n"
                      (string-join base "\n") "\n"))
         (new (concat
               ";;; m.el -*- lexical-binding: t; -*-\n"
               (string-join
                (cl-loop for i from 1 to 20
                         collect (cond ((= i 3)  "(defvar var-3 999)")
                                       ((= i 17) "(defvar var-17 888)")
                                       (t (format "(defvar var-%d %d)" i i))))
                "\n")
               "\n")))
    (dst-test--with-repo `(("m.el" . ,old)) `(("m.el" . ,new))
      (let ((magit-difftastic-display "side-by-side-show-both"))
        (let ((bodies (dst-test--display-chunk-bodies "m.el" "side-by-side-show-both")))
          ;; The two distant changes render as two separate displayed chunks.
          (should (= (length bodies) 2))
          (with-temp-buffer
            (insert "@@ line 16 @@\n" (nth 1 bodies) "\n")
            (let* ((value (list :file "m.el" :index 0 :staged nil))
                   (sec (dst-test--make-section
                         (point-min)
                         (save-excursion (goto-char (point-min)) (line-end-position))
                         (point-max) value))
                   (patch (magit-difftastic--chunk-patch sec)))
              (should patch)
              ;; The SECOND change is staged ...
              (should (string-match-p "var-17" patch))
              ;; ... and the FIRST change is NOT.
              (should-not (string-match-p "var-3 " patch)))))))))

;;;; Integration: line-number hiding ---------------------------------------

(ert-deftest magit-difftastic-integration/hide-line-numbers ()
  "Hiding blanks the gutter via a `display' property but keeps text and staging."
  (skip-unless dst-test--have-tools)
  (skip-unless (fboundp 'difftastic--classify-chunk))
  (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
      `(("sample.txt" . ,dst-test--new))
    (let ((magit-difftastic-display "side-by-side-show-both"))
     (with-temp-buffer
      (insert (dst-test--chunk-buffer-string "sample.txt" "side-by-side-show-both"))
      (magit-difftastic--hide-line-numbers (point-min) (point-max))
      ;; The first body row's leading digit is visually blanked, text intact.
      (goto-char (point-min))
      (forward-line 1)
      (let* ((p (point))
             (disp (get-text-property p 'display)))
        (should (stringp disp))
        (should (string-blank-p disp))
        (should (string-match-p "[0-9]"
                                (buffer-substring-no-properties p (1+ p)))))
      ;; Staging still resolves with numbers hidden.
      (let ((sec (dst-test--make-section
                  (point-min)
                  (save-excursion (goto-char (point-min)) (line-end-position))
                  (point-max))))
        (goto-char (point-min))
        (search-forward "delta-modified")
        (dst-test--with-region (line-beginning-position) (line-end-position)
          (let ((sel (magit-difftastic--region-selected-lines sec)))
            (should (memq 4 (car sel)))
            (should (memq 4 (cdr sel))))))))))

;;;; Integration: file statuses --------------------------------------------

(ert-deftest magit-difftastic-integration/file-statuses ()
  "`--file-statuses' reports Magit's status words for each change kind."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("keep.txt" . "x\n")
                         ("gone.txt" . "y\n"))
      '(("keep.txt" . "x\nmore\n")
        ("fresh.txt" . "brand new\n"))
    (delete-file "gone.txt")
    (let* ((statuses (magit-difftastic--file-statuses
                      magit-difftastic--diff-base)))
      (should (equal (car (cdr (assoc "keep.txt" statuses))) "modified"))
      (should (equal (car (cdr (assoc "gone.txt" statuses))) "deleted"))
      ;; A brand new file is untracked, so it is not part of the tracked diff.
      (should-not (assoc "fresh.txt" statuses)))))

(ert-deftest magit-difftastic-integration/file-statuses-rename ()
  "A staged rename is reported once as \"renamed\" keyed on the NEW path.
The porcelain diff (`--file-statuses') detects the rename and carries the OLD
path as ORIG, while plumbing (`git diff-index --name-only', what
`magit-staged-files' uses) lists BOTH the OLD (deletion) and NEW paths.  The
renderer relies on the ORIG to drop that stray OLD entry; see
`magit-difftastic--insert-file-sections'."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("original.txt" . "alpha\nbravo\ncharlie\n")) nil
    (dst-test--git "mv" "original.txt" "renamed.txt")
    (dst-test--git "add" "-A")
    (let* ((diff-args (append magit-difftastic--diff-base '("--cached")))
           (statuses (magit-difftastic--file-statuses diff-args))
           (info (cdr (assoc "renamed.txt" statuses)))
           ;; Same extraction the renderer performs to suppress the stray OLD.
           (rename-origins (delq nil
                                 (mapcar (lambda (s)
                                           (and (equal (cadr s) "renamed")
                                                (cddr s)))
                                         statuses))))
      ;; The rename is reported once, keyed on the NEW path, with ORIG = OLD.
      (should (equal (car info) "renamed"))
      (should (equal (cdr info) "original.txt"))
      ;; The OLD path is NOT reported as its own (deleted/modified) entry ...
      (should-not (assoc "original.txt" statuses))
      ;; ... but plumbing DOES list it, so the renderer must filter it out.
      (should (member "original.txt"
                      (split-string
                       (dst-test--git "diff-index" "--name-only" "--cached" "HEAD")
                       "\n" t)))
      (should (member "original.txt" rename-origins)))))

;;;; Integration: diff-mode range rendering (issue #1) ---------------------

(ert-deftest magit-difftastic-integration/diff-context-range ()
  "A `magit-diff-range' buffer is rendered with difftastic, display-only.
Guards GH #1: `magit-diff-range' sets `magit-buffer-range' (with no typearg),
which must yield a non-nil render context -- so difftastic IS used -- but one
that is NOT stageable, since a two-revision range has no index/worktree side to
stage against."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("sample.txt" . "alpha\nbravo\ncharlie\n")) nil
    ;; A second commit, so HEAD~1..HEAD is a real two-revision range.
    (dst-test--write "sample.txt" "alpha\nBRAVO\ncharlie\ndelta\n")
    (dst-test--git "commit" "-aqm" "two")
    (dst-test--let-diff-locals "HEAD~1..HEAD" nil nil
      (let* ((result (magit-difftastic--diff-context))
             (context (car result))
             (files (cdr result)))
        ;; Difftastic IS used: a render context is returned for the range ...
        (should result)
        (should (member "sample.txt" files))
        (should (member "HEAD~1..HEAD" (plist-get context :diff-args)))
        ;; ... but display-only (a revision range has no stageable side).
        (should-not (plist-get context :stageable))
        (should-not (plist-get context :staged))
        (should (equal (plist-get context :old-source) '(blob "HEAD~1")))
        (should (equal (plist-get context :new-source) '(blob "HEAD")))))))

(ert-deftest magit-difftastic-integration/diff-context-single-rev ()
  "A bare-revision `magit-diff-range' diffs that revision against the worktree.
Guards GH #1 for the single-revision form (no `..'): difftastic is still used,
display-only, comparing the revision's blob against the worktree."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("sample.txt" . "alpha\nbravo\ncharlie\n"))
      '(("sample.txt" . "alpha\nBRAVO\ncharlie\ndelta\n"))
    (dst-test--let-diff-locals "HEAD" nil nil
      (let* ((result (magit-difftastic--diff-context))
             (context (car result)))
        (should result)
        (should (member "sample.txt" (cdr result)))
        (should-not (plist-get context :stageable))
        (should (equal (plist-get context :old-source) '(blob "HEAD")))
        (should (equal (plist-get context :new-source) '(worktree)))))))

;;;; Integration: cross-chunk column alignment (issue #2) -------------------

(ert-deftest magit-difftastic-integration/align-columns-aligns-right-col ()
  "Files of different widths get the same right column after alignment.
Guards GH #2: difft sizes each file's columns to its own longest line, so the
divider (and the right-side line numbers) lands at a different column per file;
`--align-chunk-lines' pads the narrower chunk so both right columns start at
the same display column."
  (skip-unless dst-test--have-tools)
  (skip-unless (fboundp 'difftastic--classify-chunk))
  (dst-test--with-repo
      '(("short.txt" . "alpha\nbravo\ncharlie\n")
        ("long.txt"  . "x\nthis is a considerably longer line of text content here\ny\n"))
      '(("short.txt" . "alpha\nBRAVO\ncharlie\n")
        ("long.txt"  . "x\nthis is a considerably longer line of TEXT content here\ny\n"))
    (let* ((magit-difftastic-display "side-by-side-show-both")
           (magit-difftastic-width 160) ; deterministic, no wrapping in batch
           (sbody (car (magit-difftastic--split-chunk-bodies
                        (magit-difftastic--file-diff-string
                         "short.txt" magit-difftastic--diff-base))))
           (lbody (car (magit-difftastic--split-chunk-bodies
                        (magit-difftastic--file-diff-string
                         "long.txt" magit-difftastic--diff-base))))
           (scol (magit-difftastic--chunk-right-col sbody))
           (lcol (magit-difftastic--chunk-right-col lbody)))
      ;; The two files' right columns start at different columns ...
      (should scol)
      (should lcol)
      (should (/= scol lcol))
      ;; ... but after aligning both to the wider target, they match exactly.
      (let* ((target (max scol lcol))
             (spad (magit-difftastic--align-chunk-lines sbody target))
             (lpad (magit-difftastic--align-chunk-lines lbody target)))
        (should (= target (magit-difftastic--chunk-right-col spad)))
        (should (= target (magit-difftastic--chunk-right-col lpad)))))))

(ert-deftest magit-difftastic-integration/compute-align-col-takes-max ()
  "`--compute-align-col' returns the widest chunk's right column across files."
  (skip-unless dst-test--have-tools)
  (skip-unless (fboundp 'difftastic--classify-chunk))
  (dst-test--with-repo
      '(("short.txt" . "alpha\nbravo\ncharlie\n")
        ("long.txt"  . "x\nthis is a considerably longer line of text content here\ny\n"))
      '(("short.txt" . "alpha\nBRAVO\ncharlie\n")
        ("long.txt"  . "x\nthis is a considerably longer line of TEXT content here\ny\n"))
    (let* ((magit-difftastic-display "side-by-side-show-both")
           (magit-difftastic-width 160)
           (files '("short.txt" "long.txt"))
           (magit-difftastic--render-cache
            (let ((h (make-hash-table :test 'equal)))
              (dolist (f files)
                (puthash f (magit-difftastic--file-diff-string
                            f magit-difftastic--diff-base)
                         h))
              h))
           (scol (magit-difftastic--chunk-right-col
                  (car (magit-difftastic--split-chunk-bodies
                        (gethash "short.txt" magit-difftastic--render-cache)))))
           (lcol (magit-difftastic--chunk-right-col
                  (car (magit-difftastic--split-chunk-bodies
                        (gethash "long.txt" magit-difftastic--render-cache))))))
      (should (= (magit-difftastic--compute-align-col files)
                 (max scol lcol))))))

(ert-deftest magit-difftastic-integration/align-columns-preserves-staging ()
  "Aligning a chunk's columns does not break whole-chunk staging.
The padding only widens the gap before the right gutter, so difftastic's parser
still reads the same line numbers and `git apply' stages the right git hunks."
  (skip-unless dst-test--have-tools)
  (skip-unless (fboundp 'difftastic--classify-chunk))
  (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
      `(("sample.txt" . ,dst-test--new))
    (let* ((magit-difftastic-display "side-by-side-show-both")
           (magit-difftastic-width 160)
           (body (car (magit-difftastic--split-chunk-bodies
                       (magit-difftastic--file-diff-string
                        "sample.txt" magit-difftastic--diff-base))))
           (col (magit-difftastic--chunk-right-col body))
           ;; Pad the right column well past its natural position.
           (padded (magit-difftastic--align-chunk-lines body (+ col 30))))
      (should (= (+ col 30) (magit-difftastic--chunk-right-col padded)))
      (with-temp-buffer
        (insert "@@ line 1 @@\n")
        (dolist (l padded) (insert l "\n"))
        (let* ((value (list :file "sample.txt" :staged nil))
               (sec (dst-test--make-section
                     (point-min)
                     (save-excursion (goto-char (point-min)) (line-end-position))
                     (point-max) value))
               (patch (magit-difftastic--chunk-patch sec)))
          (should patch)
          (with-temp-buffer
            (insert patch)
            (should (eq 0 (call-process-region
                           (point-min) (point-max) "git" nil nil nil
                           "apply" "--cached" "-"))))
          (let ((staged (dst-test--git "--no-pager" "diff" "--cached")))
            (should (string-match-p "^\\+BRAVO-changed$" staged))
            (should (string-match-p "^\\+delta-modified$" staged))
            (should (string-match-p "^\\+golf-added$" staged))))))))

(ert-deftest magit-difftastic-integration/align-columns-inline-noop ()
  "Alignment is a no-op for the inline (single-column) layout.
`--two-column-display-p' is nil for inline, `--chunk-right-col' yields nil, and
`--align-chunk-lines' returns a single-column chunk's lines unchanged."
  (skip-unless dst-test--have-tools)
  (let ((magit-difftastic-display "inline")
        (magit-difftastic-width 160))
    (should-not (magit-difftastic--two-column-display-p))
    (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
        `(("sample.txt" . ,dst-test--new))
      (let ((body (car (magit-difftastic--split-chunk-bodies
                        (magit-difftastic--file-diff-string
                         "sample.txt" magit-difftastic--diff-base)))))
        (should-not (magit-difftastic--chunk-right-col body))
        (should (equal (magit-difftastic--align-chunk-lines body 80) body))))))

;;;; Chunk highlighting (issue #3) -----------------------------------------

;; Each exists on only some Magit versions; declared so test bindings are
;; dynamic on any Magit.
(defvar magit-section-selection-overlays)
(defvar magit-section-unhighlight-sections)
(defvar magit-section-unhighlight-hook)

(defun dst-test--highlight (sections)
  "Highlight SECTIONS (the current one first) as Magit's highlight update does.
Magit 4.3.6+ highlights each selected section, then the selection; older Magit
makes one call with the selection."
  (let ((selection (and (cdr sections) sections)))
    (if (fboundp 'magit-section-highlight-range)
        (progn (mapc #'magit-section-highlight sections)
               (when selection
                 (magit-section-highlight-selection selection)))
      (magit-section-highlight (car sections) selection))))

(defun dst-test--overlays ()
  "Return every live section highlight and selection overlay."
  (append magit-section-highlight-overlays magit-section-selection-overlays))

(defun dst-test--heading-highlighted-p (section)
  "Return non-nil when SECTION's heading has the hunk heading highlight."
  (cl-some (lambda (ov)
             (and (= (overlay-start ov) (oref section start))
                  (= (overlay-end ov) (oref section content))
                  (eq (overlay-get ov 'font-lock-face)
                      'magit-diff-hunk-heading-highlight)))
           (dst-test--overlays)))

(defun dst-test--body-overlaid-p (section)
  "Return non-nil when any highlight overlay reaches into SECTION's body."
  (cl-some (lambda (ov)
             (and (< (overlay-start ov) (oref section end))
                  (> (overlay-end ov) (oref section content))))
           (dst-test--overlays)))

(defmacro dst-test--with-highlight-advice (&rest body)
  "Run BODY with `magit-difftastic--highlight-advice' installed."
  (declare (indent 0))
  `(let ((had-advice (advice-member-p #'magit-difftastic--highlight-advice
                                      'magit-section-highlight)))
     (unwind-protect
         (progn
           (advice-add 'magit-section-highlight :around
                       #'magit-difftastic--highlight-advice)
           ,@body)
       (unless had-advice
         (advice-remove 'magit-section-highlight
                        #'magit-difftastic--highlight-advice)))))

(defmacro dst-test--with-chunks (&rest body)
  "Run BODY in a Magit section buffer holding two inserted difftastic chunks.
`chunks' is bound to the two chunk sections, and the highlight advice is
installed, for BODY."
  (declare (indent 0))
  `(with-temp-buffer
     (magit-section-mode)
     (let ((inhibit-read-only t)
           (magit-difftastic--align-col nil)
           (magit-difftastic-line-numbers t)
           (magit-section-highlight-overlays nil)
           (magit-section-selection-overlays nil)
           (magit-section-highlighted-sections nil)
           (magit-section-unhighlight-sections nil)
           (magit-section-unhighlight-hook (list #'magit-difftastic--unhighlight))
           (magit-diff-highlight-hunk-body t)
           (line (magit-difftastic--ansi-color-apply
                  "1 \e[92madded\e[0m \e[91mgone\e[0m")))
       (magit-insert-section (root)
         (magit-difftastic--insert-chunk (list line) "f.txt" nil)
         (magit-difftastic--insert-chunk (list line) "f.txt" nil))
       (let ((chunks (oref magit-root-section children)))
         (dst-test--with-highlight-advice ,@body)))))

(ert-deftest magit-difftastic-hunk-section/class-and-type ()
  "Chunks are `magit-difftastic-hunk-section's whose type stays `magit-difftastic-hunk'."
  (dst-test--with-chunks
    (dolist (chunk chunks)
      (should (cl-typep chunk 'magit-difftastic-hunk-section))
      (should (eq (oref chunk type) 'magit-difftastic-hunk))
      (should (eq (oref chunk keymap) 'magit-difftastic-hunk-section-map)))))

(ert-deftest magit-difftastic-hunk-section/highlight-leaves-body ()
  "Highlighting a chunk overlays only its heading, so difft's colours show."
  (dst-test--with-chunks
    (let ((chunk (car chunks)))
      (dst-test--highlight (list chunk))
      (should (dst-test--heading-highlighted-p chunk))
      (should-not (dst-test--heading-highlighted-p (cadr chunks)))
      (should-not (cl-some #'dst-test--body-overlaid-p chunks)))))

(ert-deftest magit-difftastic-hunk-section/highlight-selection ()
  "With several chunks selected, every heading is highlighted and no body."
  (dst-test--with-chunks
    (dst-test--highlight chunks)
    (should (cl-every #'dst-test--heading-highlighted-p chunks))
    (should-not (cl-some #'dst-test--body-overlaid-p chunks))))

;;;; Change faces (issue #3) -----------------------------------------------

(defun dst-test--focus (sections)
  "Update highlighting as Magit does when SECTIONS become the focused ones.
SECTIONS nil means nothing is focused."
  (mapc #'delete-overlay magit-section-highlight-overlays)
  (setq magit-section-highlight-overlays nil)
  (if (magit-difftastic--magit-paints-p)
      (progn
        (when sections (dst-test--highlight sections))
        (dolist (s (cl-union magit-section-highlighted-sections sections))
          (when (slot-boundp s 'painted)
            (magit-section-update-paint s sections))))
    (setq magit-section-unhighlight-sections magit-section-highlighted-sections
          magit-section-highlighted-sections nil)
    (when sections (dst-test--highlight sections))
    (dolist (s magit-section-unhighlight-sections)
      (run-hook-with-args-until-success 'magit-section-unhighlight-hook s nil))))

(defun dst-test--change-faces (section)
  "Return the added/removed faces used in SECTION's body, in order."
  (let ((pos (oref section content))
        faces)
    (while (< pos (oref section end))
      (dolist (f (magit-difftastic--face-list
                  (get-text-property pos 'font-lock-face)))
        (when (and (symbolp f)
                   (string-prefix-p "magit-difftastic-" (symbol-name f)))
          (cl-pushnew f faces)))
      (setq pos (or (next-single-property-change
                     pos 'font-lock-face nil (oref section end))
                    (oref section end))))
    (nreverse faces)))

(defconst dst-test--plain-faces
  '(magit-difftastic-added magit-difftastic-removed))

(defconst dst-test--highlight-faces
  '(magit-difftastic-added-highlight magit-difftastic-removed-highlight))

(ert-deftest magit-difftastic--ansi-color-apply/marks-changes ()
  "difft's green and red text gets our faces and `magit-difftastic-change'."
  (skip-unless (fboundp 'ansi-color--face-vec-face))
  (let ((s (magit-difftastic--ansi-color-apply
            "\e[2m1 \e[0m\e[92;1m09\e[0m\e[92m-\e[0m \e[91mx\e[0m")))
    (should (equal s "1 09- x"))
    ;; Dim line number: not a change.
    (should-not (get-text-property 0 'magit-difftastic-change s))
    ;; Bold added text keeps its bold.
    (should (eq (get-text-property 2 'magit-difftastic-change s) 'added))
    (let ((faces (magit-difftastic--face-list
                  (get-text-property 2 'font-lock-face s))))
      (should (memq 'magit-difftastic-added faces))
      (should (memq 'ansi-color-bold faces))
      (should-not (cl-find-if #'consp faces)))
    (should (eq (get-text-property 4 'magit-difftastic-change s) 'added))
    (should-not (get-text-property 5 'magit-difftastic-change s))
    (should (eq (get-text-property 6 'magit-difftastic-change s) 'removed))
    (should (memq 'magit-difftastic-removed
                  (magit-difftastic--face-list
                   (get-text-property 6 'font-lock-face s))))))

(ert-deftest magit-difftastic-hunk-section/focus-highlights-changes ()
  "A focused chunk shows highlight faces, and plain ones again once unfocused."
  (skip-unless (fboundp 'ansi-color--face-vec-face))
  (dst-test--with-chunks
    (let ((a (car chunks)) (b (cadr chunks)))
      (should (equal (dst-test--change-faces a) dst-test--plain-faces))
      (dst-test--focus (list a))
      (should (equal (dst-test--change-faces a) dst-test--highlight-faces))
      (should (equal (dst-test--change-faces b) dst-test--plain-faces))
      (dst-test--focus (list b))
      (should (equal (dst-test--change-faces a) dst-test--plain-faces))
      (should (equal (dst-test--change-faces b) dst-test--highlight-faces))
      ;; Staying focused across an update keeps the highlight.
      (dst-test--focus (list b))
      (should (equal (dst-test--change-faces b) dst-test--highlight-faces))
      (dst-test--focus nil)
      (should (equal (dst-test--change-faces b) dst-test--plain-faces)))))

(ert-deftest magit-difftastic--text-diff-p/first-header ()
  "Only output whose first difft header names the `Text' language is a text diff."
  (should (magit-difftastic--text-diff-p "a.txt --- Text\n1 x\n"))
  (should (magit-difftastic--text-diff-p
           "\na.scm --- 1/2 --- Text (1.9 MiB exceeded DFT_BYTE_LIMIT)\n1 x\n"))
  (should-not (magit-difftastic--text-diff-p "a.el --- Emacs Lisp\n1 --- Text\n"))
  (should-not (magit-difftastic--text-diff-p "a.el --- Emacs Lisp\n")))

(defmacro dst-test--with-text-chunk (refine &rest body)
  "Run BODY on a rendered, focusable text-diff chunk with REFINE as the setting.
The chunk changes `bravo 2026-08-15' to `bravo 2026-09-03'; `chunk' is bound
to its section for BODY."
  (declare (indent 1))
  `(dst-test--with-repo '(("a.txt" . "alpha\nbravo 2026-08-15\ncharlie\n"))
       '(("a.txt" . "alpha\nbravo 2026-09-03\ncharlie\n"))
     (with-temp-buffer
       (magit-section-mode)
       (let ((inhibit-read-only t)
             (magit-difftastic-lazy nil)
             (magit-difftastic-display "inline")
             (magit-diff-refine-hunk ,refine)
             (magit-diff-highlight-hunk-body t)
             (magit-section-highlight-overlays nil)
             (magit-section-selection-overlays nil)
             (magit-section-highlighted-sections nil)
             (magit-section-unhighlight-sections nil)
             (magit-section-unhighlight-hook
              (list #'magit-difftastic--unhighlight)))
         (magit-insert-section (root)
           (magit-difftastic--insert-file-sections
            '("a.txt") (magit-difftastic--context-unstaged)))
         (let ((chunk (car (oref (car (oref magit-root-section children))
                                 children))))
           (dst-test--with-highlight-advice ,@body))))))

(defun dst-test--faces-on (section text)
  "Return the faces on the first occurrence of TEXT in SECTION's body."
  (save-excursion
    (goto-char (oref section content))
    (search-forward text (oref section end))
    (magit-difftastic--face-list
     (get-text-property (match-beginning 0) 'font-lock-face))))

(ert-deftest magit-difftastic--refine-chunk/text-diff ()
  "With refinement on, a text diff's changed words get the refine faces.
The rest of each changed line and the bold line-number gutters keep the plain
change faces, and focusing the chunk leaves the refined words alone."
  (skip-unless (and dst-test--have-tools (fboundp 'ansi-color--face-vec-face)))
  (dst-test--with-text-chunk t
    (let ((refined (dst-test--faces-on chunk "08")))
      (should (memq 'magit-difftastic-refine-removed refined))
      (should-not (memq 'magit-difftastic-removed refined))
      (should-not (memq 'ansi-color-bold refined)))
    (should (memq 'magit-difftastic-refine-added (dst-test--faces-on chunk "03")))
    (should (memq 'magit-difftastic-removed (dst-test--faces-on chunk "bravo")))
    ;; The removed line's gutter, "2 ", is bold but not refined.
    (let ((gutter (dst-test--faces-on chunk "2 ")))
      (should (memq 'magit-difftastic-removed gutter))
      (should (memq 'ansi-color-bold gutter)))
    (dst-test--focus (list chunk))
    (should (memq 'magit-difftastic-removed-highlight
                  (dst-test--faces-on chunk "bravo")))
    (should (memq 'magit-difftastic-refine-removed
                  (dst-test--faces-on chunk "08")))))

(ert-deftest magit-difftastic--refine-chunk/off ()
  "With `magit-diff-refine-hunk' nil, changed words keep difft's bold colour."
  (skip-unless (and dst-test--have-tools (fboundp 'ansi-color--face-vec-face)))
  (dst-test--with-text-chunk nil
    (let ((faces (dst-test--faces-on chunk "08")))
      (should (memq 'magit-difftastic-removed faces))
      (should (memq 'ansi-color-bold faces)))))

(ert-deftest magit-difftastic-hunk-section/focus-respects-hunk-body-option ()
  "With `magit-diff-highlight-hunk-body' nil, a focused chunk stays plain."
  (skip-unless (fboundp 'ansi-color--face-vec-face))
  (dst-test--with-chunks
    (let ((magit-diff-highlight-hunk-body nil))
      (dst-test--focus (list (car chunks)))
      (should (equal (dst-test--change-faces (car chunks))
                     dst-test--plain-faces)))))

;;;; Whitespace-ignoring diff flags (issue #5) -----------------------------

(ert-deftest magit-difftastic--whitespace-args/extracts-flags ()
  "Only the whitespace-ignoring flags are picked out of the buffer's diff args."
  (let ((magit-buffer-diff-args
         '("--stat" "-w" "--ignore-blank-lines" "--no-ext-diff")))
    (should (equal (magit-difftastic--whitespace-args)
                   '("-w" "--ignore-blank-lines"))))
  (let ((magit-buffer-diff-args '("--stat" "--no-ext-diff")))
    (should-not (magit-difftastic--whitespace-args))))

(ert-deftest magit-difftastic-integration/drop-whitespace-only ()
  "Whitespace-only files drop out only when a whitespace flag is active.
Guards GH #5: difft cannot ignore whitespace, so we let git decide which files
still differ under the active flags and render only those."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo
      '(("real.txt" . "alpha\nbravo\n")
        ("ws.txt"   . "one\ntwo\n"))
      '(("real.txt" . "alpha\nBRAVO\n")    ; a real change
        ("ws.txt"   . "one  \n  two\n"))   ; whitespace-only change
    (let ((files '("real.txt" "ws.txt")))
      ;; No whitespace flag -> both kept.
      (let ((magit-buffer-diff-args '("--stat")))
        (should (equal (magit-difftastic--drop-whitespace-only files nil)
                       '("real.txt" "ws.txt"))))
      ;; -w active -> the whitespace-only file is dropped, the real one kept.
      (let ((magit-buffer-diff-args '("--ignore-all-space")))
        (should (equal (magit-difftastic--drop-whitespace-only files nil)
                       '("real.txt")))))))

(ert-deftest magit-difftastic-integration/diff-context-ignores-whitespace ()
  "`--diff-context' excludes whitespace-only files when a flag is active.
The worktree (unstaged) diff lists files via `git diff --name-only', to which
the whitespace flags are now forwarded."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo
      '(("real.txt" . "alpha\nbravo\n")
        ("ws.txt"   . "one\ntwo\n"))
      '(("real.txt" . "alpha\nBRAVO\n")
        ("ws.txt"   . "one  \n  two\n"))
    (dst-test--let-diff-locals nil nil nil
      ;; No whitespace flag: both files render.
      (let* ((magit-buffer-diff-args '("--stat"))
             (files (cdr (magit-difftastic--diff-context))))
        (should (member "real.txt" files))
        (should (member "ws.txt" files)))
      ;; -w active: only the file with a real change is rendered.
      (let* ((magit-buffer-diff-args '("-w"))
             (files (cdr (magit-difftastic--diff-context))))
        (should (member "real.txt" files))
        (should-not (member "ws.txt" files))))))

;;;; Integration: parallel rendering ---------------------------------------

(ert-deftest magit-difftastic-integration/render-files-matches-sync ()
  "`--render-files' renders a batch in parallel, matching the sync path.
Each file's parallel result must equal what `--render-raw' produces serially,
and every requested file must be present in the returned hash."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\nbravo\n")
                         ("b.txt" . "one\ntwo\nthree\n")
                         ("c.txt" . "uno\ndos\n"))
      '(("a.txt" . "alpha\nBRAVO\n")
        ("b.txt" . "one\nTWO\nthree\nfour\n")
        ("c.txt" . "uno\nDOS\ntres\n"))
    (let* ((files '("a.txt" "b.txt" "c.txt"))
           (width (magit-difftastic--width))
           (jobs (mapcar (lambda (f) (cons f magit-difftastic--diff-base)) files))
           (parallel (magit-difftastic--render-files jobs width)))
      (should (= (hash-table-count parallel) (length files)))
      (dolist (f files)
        (should (equal (gethash f parallel)
                       (magit-difftastic--render-raw
                        f magit-difftastic--diff-base width)))))))

(ert-deftest magit-difftastic-integration/render-files-serial-limit ()
  "`--render-files' still yields correct output when limited to one job at a time."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\nbravo\n")
                         ("b.txt" . "one\ntwo\n"))
      '(("a.txt" . "alpha\nBRAVO\n")
        ("b.txt" . "ONE\ntwo\n"))
    (let* ((magit-difftastic-render-jobs 1)
           (files '("a.txt" "b.txt"))
           (width (magit-difftastic--width))
           (jobs (mapcar (lambda (f) (cons f magit-difftastic--diff-base)) files))
           (parallel (magit-difftastic--render-files jobs width)))
      (should (= (hash-table-count parallel) (length files)))
      (dolist (f files)
        (should (equal (gethash f parallel)
                       (magit-difftastic--render-raw
                        f magit-difftastic--diff-base width)))))))

(ert-deftest magit-difftastic-integration/render-files-inhibits-refresh ()
  "`--render-files' binds `magit-inhibit-refresh' while pumping the event loop.
Regression for the discard freeze (#6): a foreign sentinel/timer firing during
the render pump must not be able to re-enter `magit-refresh'."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\nbravo\n")
                         ("b.txt" . "one\ntwo\n"))
      '(("a.txt" . "alpha\nBRAVO\n")
        ("b.txt" . "ONE\ntwo\n"))
    (let* ((files '("a.txt" "b.txt"))
           (width (magit-difftastic--width))
           (jobs (mapcar (lambda (f) (cons f magit-difftastic--diff-base)) files))
           (observed 'unset)
           (real (symbol-function 'accept-process-output)))
      ;; The pump calls `accept-process-output' at least once to drain the
      ;; sentinels; capture `magit-inhibit-refresh' as seen from inside it.
      (cl-letf (((symbol-function 'accept-process-output)
                 (lambda (&rest args)
                   (when (eq observed 'unset)
                     (setq observed magit-inhibit-refresh))
                   (apply real args))))
        (magit-difftastic--render-files jobs width))
      (should observed))))

(ert-deftest magit-difftastic-integration/render-files-completes-without-sentinels ()
  "`--render-files' finishes from its wait loop, not from process sentinels.
Regression for the first-render freeze (#9): even when no render process's
sentinel does any work, every job must still be collected with its full output,
because the wait loop drains each process to EOF itself rather than waiting for
a sentinel that the surrounding `magit-refresh' may never schedule."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\nbravo\n")
                         ("b.txt" . "one\ntwo\n"))
      '(("a.txt" . "alpha\nBRAVO\n")
        ("b.txt" . "ONE\ntwo\n"))
    (let* ((files '("a.txt" "b.txt"))
           (width (magit-difftastic--width))
           (jobs (mapcar (lambda (f) (cons f magit-difftastic--diff-base)) files))
           (real (symbol-function 'set-process-sentinel)))
      ;; Force every render process to a do-nothing sentinel, so completion can
      ;; only come from the wait loop draining the process itself.  Reverting to
      ;; sentinel-driven completion would livelock here and trip the timeout.
      (cl-letf (((symbol-function 'set-process-sentinel)
                 (lambda (proc _sentinel) (funcall real proc #'ignore))))
        (let ((rendered (with-timeout (30 (ert-fail "render-files livelocked"))
                          (magit-difftastic--render-files jobs width))))
          (should (= (hash-table-count rendered) (length files)))
          (dolist (f files)
            (should (equal (gethash f rendered)
                           (magit-difftastic--render-raw
                            f magit-difftastic--diff-base width)))))))))

;;;; Unit tests: render cache ----------------------------------------------

(ert-deftest magit-difftastic--cache-key/direct-and-nil ()
  "A real new blob id is embedded directly; nil ids yield no key."
  (let ((magit-difftastic-display "inline"))
    (should (equal (magit-difftastic--cache-key "x" '("aaa" . "bbb") 80)
                   '("inline" 80 "aaa" "bbb"))))
  (should-not (magit-difftastic--cache-key "x" nil 80)))

(ert-deftest magit-difftastic--all-zero-id-p/detects-placeholder ()
  (should (magit-difftastic--all-zero-id-p "0000000000000000000000000000000000000000"))
  (should-not (magit-difftastic--all-zero-id-p "0000abc"))
  (should-not (magit-difftastic--all-zero-id-p nil)))

(ert-deftest magit-difftastic--cache-get-put/roundtrip-and-toggle ()
  "Get/put round-trip; caching off and nil keys are no-ops."
  (let ((magit-difftastic--cache (make-hash-table :test 'equal))
        (magit-difftastic-cache t))
    (should-not (magit-difftastic--cache-get '(:k)))
    (magit-difftastic--cache-put '(:k) "rendered")
    (should (equal (magit-difftastic--cache-get '(:k)) "rendered"))
    ;; A nil key never stores or retrieves.
    (magit-difftastic--cache-put nil "y")
    (should-not (magit-difftastic--cache-get nil))
    ;; With caching disabled, get and put are inert.
    (let ((magit-difftastic-cache nil))
      (should-not (magit-difftastic--cache-get '(:k)))
      (magit-difftastic--cache-put '(:k2) "x"))
    (should-not (gethash '(:k2) magit-difftastic--cache))))

;;;; Integration: render cache ---------------------------------------------

(ert-deftest magit-difftastic-integration/blob-ids ()
  "`--blob-ids' reports a worktree new side as all-zero and staged sides as real."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\n")) '(("a.txt" . "beta\n"))
    ;; Unstaged: old = index blob (real), new = worktree (all-zero placeholder).
    (let ((pair (gethash "a.txt"
                         (magit-difftastic--blob-ids
                          magit-difftastic--diff-base '("a.txt")))))
      (should pair)
      (should-not (magit-difftastic--all-zero-id-p (car pair)))
      (should (magit-difftastic--all-zero-id-p (cdr pair))))
    ;; Staged: both sides are concrete blobs.
    (dst-test--git "add" "a.txt")
    (let ((pair (gethash "a.txt"
                         (magit-difftastic--blob-ids
                          (append magit-difftastic--diff-base '("--cached"))
                          '("a.txt")))))
      (should pair)
      (should-not (magit-difftastic--all-zero-id-p (car pair)))
      (should-not (magit-difftastic--all-zero-id-p (cdr pair))))))

(ert-deftest magit-difftastic-integration/raw-info-merges-ids-and-status ()
  "`--raw-info' resolves blob ids AND the status word in one `--raw' pass.
This is the single plumbing call that replaced the separate `--name-status'
invocation, feeding both the caches (ids) and the file headings (status)."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("keep.txt" . "x\n")
                         ("gone.txt" . "y\n"))
      '(("keep.txt" . "x\nmore\n"))
    (delete-file "gone.txt")
    (let* ((info (magit-difftastic--raw-info magit-difftastic--diff-base))
           (keep (gethash "keep.txt" info))
           (gone (gethash "gone.txt" info)))
      ;; A modified file: status word plus a real old id and an all-zero
      ;; (unhashed worktree) new id -- both keys the caches need.
      (should (equal (plist-get keep :status) "modified"))
      (should-not (magit-difftastic--all-zero-id-p (plist-get keep :old)))
      (should (magit-difftastic--all-zero-id-p (plist-get keep :new)))
      (should (equal (plist-get gone :status) "deleted")))))

(ert-deftest magit-difftastic-integration/cache-reuses-unchanged ()
  "A second pre-warm with unchanged content renders nothing and matches the first."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\nbravo\n")
                         ("b.txt" . "one\ntwo\n"))
      '(("a.txt" . "alpha\nBRAVO\n")
        ("b.txt" . "ONE\ntwo\n"))
    (clrhash magit-difftastic--cache)
    (let* ((magit-difftastic-cache t)
           (context (magit-difftastic--context-unstaged))
           (files '("a.txt" "b.txt"))
           (width (magit-difftastic--width))
           (first (magit-difftastic--prewarm files context width))
           (rendered-again nil))
      (should (= (hash-table-count first) 2))
      (cl-letf (((symbol-function 'magit-difftastic--render-files)
                 (lambda (jobs _w)
                   (setq rendered-again jobs)
                   (make-hash-table :test 'equal))))
        (let ((second (magit-difftastic--prewarm files context width)))
          ;; No misses -> the parallel renderer is never invoked.
          (should-not rendered-again)
          (should (= (hash-table-count second) 2))
          (dolist (f files)
            (should (equal (gethash f first) (gethash f second)))))))))

(ert-deftest magit-difftastic-integration/cache-invalidates-on-change ()
  "Changing one file re-renders only it; the unchanged file stays cached."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("a.txt" . "alpha\nbravo\n")
                         ("b.txt" . "one\ntwo\n"))
      '(("a.txt" . "alpha\nBRAVO\n")
        ("b.txt" . "ONE\ntwo\n"))
    (clrhash magit-difftastic--cache)
    (let* ((magit-difftastic-cache t)
           (context (magit-difftastic--context-unstaged))
           (files '("a.txt" "b.txt"))
           (width (magit-difftastic--width)))
      (magit-difftastic--prewarm files context width)
      ;; Change only a.txt (different length, so its worktree stat key changes).
      (dst-test--write "a.txt" "alpha\nBRAVO-again\n")
      (let (rendered)
        (cl-letf* ((orig (symbol-function 'magit-difftastic--render-files))
                   ((symbol-function 'magit-difftastic--render-files)
                    (lambda (jobs w)
                      (setq rendered (mapcar #'car jobs))
                      (funcall orig jobs w))))
          (magit-difftastic--prewarm files context width))
        (should (equal rendered '("a.txt")))))))

;;;; Unit tests: major-mode detection -------------------------------------

(ert-deftest magit-difftastic--mode-for-file/recognizes-and-rejects ()
  (let ((mode (magit-difftastic--mode-for-file "foo.el")))
    (should (and mode (fboundp mode))))
  (should-not (magit-difftastic--mode-for-file "foo.no-such-ext-zzz")))

(ert-deftest magit-difftastic--mode-for-file/honors-remap ()
  "`--mode-for-file' follows `major-mode-remap-alist' (how `*-ts-mode' is chosen).
We can't assume a tree-sitter grammar is installed, so this checks the same
remap mechanism Emacs uses to swap in `*-ts-mode' with an ordinary mode."
  (skip-unless (boundp 'major-mode-remap-alist))
  (let* ((base (let ((major-mode-remap-alist nil))
                 (magit-difftastic--mode-for-file "foo.el")))
         (major-mode-remap-alist (list (cons base 'lisp-interaction-mode))))
    (should base)
    ;; The user's remap (here standing in for `foo-mode' -> `foo-ts-mode') wins.
    (should (eq (magit-difftastic--mode-for-file "foo.el") 'lisp-interaction-mode))))

;;;; Integration: syntax highlighting --------------------------------------

(defun dst-test--faces-at (pos)
  "Return the `font-lock-face' property at POS as a list.
difft and our syntax highlighting both colour via `font-lock-face'."
  (let ((f (get-text-property pos 'font-lock-face)))
    (if (listp f) f (list f))))

(defun dst-test--face-present-p (face)
  "Return non-nil if FACE appears in any `font-lock-face' property."
  (save-excursion
    (goto-char (point-min))
    (cl-loop while (< (point) (point-max))
             when (memq face (dst-test--faces-at (point))) return t
             do (goto-char (or (next-single-property-change
                                (point) 'font-lock-face)
                               (point-max))))))

(ert-deftest magit-difftastic-integration/syntax-highlight-applies-faces ()
  "Major-mode font-lock faces are layered onto code in every layout."
  (skip-unless dst-test--have-tools)
  (dolist (display dst-test--displays)
    (dst-test--with-repo
        '(("sample.el" . "(defun greet (name)\n  (message \"hi %s\" name))\n"))
        '(("sample.el" . "(defun greet (name greeting)\n  ;; say hi\n  (message \"%s %s\" greeting name))\n"))
      (let ((magit-difftastic-display display))
       (with-temp-buffer
        (insert (dst-test--chunk-buffer-string "sample.el" display))
        (magit-difftastic--apply-syntax "sample.el" (point-min) (point-max)
                                         (magit-difftastic--context-unstaged))
        ;; `defun' is fontified as a keyword ...
        (goto-char (point-min))
        (should (search-forward "defun" nil t))
        (should (memq 'font-lock-keyword-face
                      (dst-test--faces-at (match-beginning 0))))
        ;; ... and the added comment carries the comment face somewhere.
        (should (dst-test--face-present-p 'font-lock-comment-face)))))))

(ert-deftest magit-difftastic-integration/syntax-highlight-docstring-context ()
  "A change inside a multi-line docstring is highlighted as a string/doc.
Per-chunk reconstruction misses this (the opening quote is out of view); the
whole-file fontification path recognizes the enclosing string."
  (skip-unless dst-test--have-tools)
  (dolist (display dst-test--displays)
    (dst-test--with-repo
        '(("d.el" . "(defun foo ()\n  \"Line one.\nLine two old.\nLine three.\"\n  1)\n"))
        '(("d.el" . "(defun foo ()\n  \"Line one.\nLine two NEW.\nLine three.\"\n  1)\n"))
      (let ((magit-difftastic-display display))
       (with-temp-buffer
        (insert (dst-test--chunk-buffer-string "d.el" display))
        (magit-difftastic--apply-syntax "d.el" (point-min) (point-max)
                                         (magit-difftastic--context-unstaged))
        (should (or (dst-test--face-present-p 'font-lock-doc-face)
                    (dst-test--face-present-p 'font-lock-string-face))))))))

(ert-deftest magit-difftastic-integration/syntax-highlight-noop-unknown-mode ()
  "A file with no recognized major mode gets no font-lock faces."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo '(("data.no-such-ext-zzz" . "alpha\nbravo\n"))
      '(("data.no-such-ext-zzz" . "alpha\nBRAVO\ncharlie\n"))
    (let ((magit-difftastic-display "side-by-side-show-both"))
      (with-temp-buffer
        (insert (dst-test--chunk-buffer-string "data.no-such-ext-zzz"
                                               "side-by-side-show-both"))
        (magit-difftastic--apply-syntax "data.no-such-ext-zzz"
                                         (point-min) (point-max)
                                         (magit-difftastic--context-unstaged))
        (should-not (dst-test--face-present-p 'font-lock-keyword-face))))))

(ert-deftest magit-difftastic-integration/syntax-cache-reuses-fontification ()
  "The fontification cache is content-keyed, so each blob is fontified once.
With the blob ids bound (as a real refresh does via
`magit-difftastic--file-ids'), re-running `--apply-syntax' for the same blobs
reuses the cached lines instead of re-fontifying -- what makes a
refresh-after-staging cheap and dedupes the index blob shared by the staged and
unstaged views."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo
      '(("sample.el" . "(defun greet (name)\n  (message \"hi %s\" name))\n"))
      '(("sample.el" . "(defun greet (name greeting)\n  (message \"%s %s\" greeting name))\n"))
    (let* ((magit-difftastic-cache t)
           (display "side-by-side-show-both")
           (magit-difftastic-display display)
           (context (magit-difftastic--context-unstaged))
           (magit-difftastic--file-ids
            (magit-difftastic--blob-ids
             (plist-get context :diff-args) '("sample.el")))
           (calls 0))
      (clrhash magit-difftastic--syntax-cache)
      (cl-letf* ((orig (symbol-function 'magit-difftastic--fontify-lines))
                 ((symbol-function 'magit-difftastic--fontify-lines)
                  (lambda (&rest args) (cl-incf calls) (apply orig args))))
        (with-temp-buffer
          (insert (dst-test--chunk-buffer-string "sample.el" display))
          (magit-difftastic--apply-syntax "sample.el" (point-min) (point-max)
                                           context))
        (should (> calls 0))
        (let ((after-first calls))
          ;; A second identical render is served entirely from the cache.
          (with-temp-buffer
            (insert (dst-test--chunk-buffer-string "sample.el" display))
            (magit-difftastic--apply-syntax "sample.el" (point-min) (point-max)
                                             context))
          (should (= calls after-first)))))))

(ert-deftest magit-difftastic-integration/apply-syntax-sections-one-pass ()
  "`--apply-syntax-sections' highlights every chunk but fontifies each side once.
A multi-chunk file (changes far apart) must cost one fontification per side for
the whole file, not one per chunk -- the fix for the per-chunk re-fontification
regression."
  (skip-unless dst-test--have-tools)
  (let* ((display "side-by-side-show-both")
         (lines (lambda (a b)
                  (concat (mapconcat
                           (lambda (i)
                             (format "(defun f%d () %d)"
                                     i (cond ((= i 1) a) ((= i 20) b) (t i))))
                           (number-sequence 1 20) "\n")
                          "\n"))))
    (dst-test--with-repo `(("m.el" . ,(funcall lines 1 20)))
        `(("m.el" . ,(funcall lines 100 200)))
      (let* ((magit-difftastic-display display)
             (magit-difftastic-cache t)
             (context (magit-difftastic--context-unstaged))
             (magit-difftastic--file-ids
              (magit-difftastic--blob-ids
               (plist-get context :diff-args) '("m.el")))
             (bodies (dst-test--display-chunk-bodies "m.el" display))
             (calls 0))
        ;; The change at line 1 and line 20 should render as separate chunks.
        (skip-unless (> (length bodies) 1))
        (clrhash magit-difftastic--syntax-cache)
        (with-temp-buffer
          (let (sections)
            (dolist (body bodies)
              (let ((beg (point)))
                (insert "@@ line 1 @@\n")
                (let ((content (point)))
                  (insert body "\n")
                  (push (dst-test--make-section beg content (point)) sections))))
            (cl-letf* ((orig (symbol-function 'magit-difftastic--fontify-lines))
                       ((symbol-function 'magit-difftastic--fontify-lines)
                        (lambda (&rest args) (cl-incf calls) (apply orig args))))
              (magit-difftastic--apply-syntax-sections
               "m.el" context (nreverse sections))))
          ;; One fontification per side (old + new) for the whole file, no matter
          ;; how many chunks it split into.
          (should (<= calls 2))
          ;; And the highlighting actually landed.
          (should (dst-test--face-present-p 'font-lock-keyword-face)))))))

(provide 'magit-difftastic-test)
;;; magit-difftastic-test.el ends here
