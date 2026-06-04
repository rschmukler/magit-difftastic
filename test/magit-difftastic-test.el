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
  "`--chunk-patch' (no region) stages every change the chunk covers."
  (skip-unless dst-test--have-tools)
  (dst-test--with-repo `(("sample.txt" . ,dst-test--old))
      `(("sample.txt" . ,dst-test--new))
    (let* ((value (list :file "sample.txt" :index 0 :staged nil
                        :diff-args magit-difftastic--diff-base))
           (sec (dst-test--make-section 1 1 1 value))
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
        (should (string-match-p "^\\+golf-added$" staged))))))

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

;;;; Unit tests: major-mode detection -------------------------------------

(ert-deftest magit-difftastic--mode-for-file/recognizes-and-rejects ()
  (let ((mode (magit-difftastic--mode-for-file "foo.el")))
    (should (and mode (fboundp mode))))
  (should-not (magit-difftastic--mode-for-file "foo.no-such-ext-zzz")))

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

(provide 'magit-difftastic-test)
;;; magit-difftastic-test.el ends here
