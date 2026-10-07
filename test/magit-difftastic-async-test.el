;;; magit-difftastic-async-test.el --- Async scheduler tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Isolated ERT tests with deterministic timers and processes, plus real Git
;; output tests.  The scheduler does not require the main package to load.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'magit-difftastic-async)

(defvar native-comp-enable-subr-trampolines)

(defmacro dst-async-test--isolated (&rest body)
  "Evaluate BODY with a fresh scheduler and two live owner buffers."
  (declare (indent 0) (debug t))
  `(let ((magit-difftastic--async-jobs (make-hash-table :test #'equal))
         (magit-difftastic--async-queue nil)
         (magit-difftastic--async-active 0)
         (magit-difftastic--async-ready nil)
         (magit-difftastic--async-timer nil)
         (magit-difftastic--async-idle-timer nil)
         (magit-difftastic--async-token nil)
         (magit-difftastic--async-idle-token nil)
         (magit-difftastic--async-driving nil)
         (magit--refreshing-buffer-p nil)
         (magit-difftastic--refreshing nil)
         (owner-a (generate-new-buffer " *async-owner-a*"))
         (owner-b (generate-new-buffer " *async-owner-b*"))
         (limit 2))
     (cl-letf (((symbol-function 'magit-difftastic--max-jobs)
                (lambda () limit)))
       (unwind-protect (progn ,@body)
         (magit-difftastic--async-cancel-all)
         (kill-buffer owner-a)
         (kill-buffer owner-b)))))

(cl-defstruct dst-async-test--process buffer sentinel (status 'run) (code 0))

(defmacro dst-async-test--mocked (&rest body)
  "Evaluate BODY with isolated scheduler, mock timers, and mock processes."
  (declare (indent 0) (debug t))
  `(dst-async-test--isolated
     (let ((native-comp-enable-subr-trampolines nil)
           timers launches (launch-error nil))
       (cl-letf
           (((symbol-function 'run-at-time)
             (lambda (_delay _repeat callback &rest args)
               (let ((timer (list 'regular callback args t)))
                 (push timer timers) timer)))
            ((symbol-function 'run-with-idle-timer)
             (lambda (delay _repeat callback &rest args)
               (should (= delay magit-difftastic--async-idle-delay))
               (let ((timer (list 'idle callback args t)))
                 (push timer timers) timer)))
            ((symbol-function 'cancel-timer)
             (lambda (timer) (setf (nth 3 timer) nil)))
            ((symbol-function 'start-file-process)
             (lambda (_name buffer program &rest args)
               (should (equal program "git"))
               (should-not process-connection-type)
               (when launch-error (error "Launch failed"))
               (let ((process (make-dst-async-test--process :buffer buffer)))
                 (push (list process default-directory process-environment args)
                       launches)
                 process)))
            ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
            ((symbol-function 'set-process-sentinel)
             (lambda (process sentinel)
               (setf (dst-async-test--process-sentinel process) sentinel)))
            ((symbol-function 'process-status) #'dst-async-test--process-status)
            ((symbol-function 'process-exit-status) #'dst-async-test--process-code)
            ((symbol-function 'process-live-p)
             (lambda (process)
               (eq (dst-async-test--process-status process) 'run)))
            ((symbol-function 'delete-process)
             (lambda (process)
               (setf (dst-async-test--process-status process) 'signal)
               (funcall (dst-async-test--process-sentinel process)
                        process "killed"))))
         (unwind-protect (progn ,@body)
           (magit-difftastic--async-cancel-all))))))

(ert-deftest magit-difftastic-async/terminal-during-sentinel-setup ()
  (dst-async-test--mocked
    (let ((start (symbol-function 'start-file-process))
          (install (symbol-function 'set-process-sentinel))
          result)
      (cl-letf (((symbol-function 'start-file-process)
                 (lambda (&rest args)
                   (let ((process (apply start args)))
                     (setf (dst-async-test--process-status process) 'exit)
                     process)))
                ((symbol-function 'set-process-sentinel)
                 (lambda (process sentinel)
                   (funcall install process sentinel)
                   (unless (eq sentinel #'ignore)
                     (with-current-buffer (dst-async-test--process-buffer process)
                       (insert "last output"))
                     (funcall sentinel process "finished")))))
        (let ((job (dst-async-test--request
                    'fast owner-a (lambda (raw error)
                                    (setq result (list raw error))) t)))
          (should-not result)
          (should (eq (magit-difftastic--async-job-state job) 'done))
          (should (zerop magit-difftastic--async-active))
          (dst-async-test--tick)
          (should (equal result '("last output" nil))))))))

(ert-deftest magit-difftastic-async/canceled-during-process-creation ()
  (dst-async-test--mocked
    (let ((start (symbol-function 'start-file-process)) process)
      (cl-letf (((symbol-function 'start-file-process)
                 (lambda (&rest args)
                   (setq process (apply start args))
                   (magit-difftastic--async-cancel-all)
                   process)))
        (let ((job (dst-async-test--request 'key owner-a #'ignore t)))
          (should (eq (magit-difftastic--async-job-state job) 'done))
          (should-not (process-live-p process))
          (should-not (buffer-live-p (dst-async-test--process-buffer process)))
          (should (zerop magit-difftastic--async-active))
          (should (zerop (hash-table-count magit-difftastic--async-jobs)))
          (should-not magit-difftastic--async-timer))))))

(ert-deftest magit-difftastic-async/sentinel-defers-buffer-kill-hooks ()
  (dst-async-test--mocked
    (let* ((job (dst-async-test--request 'key owner-a #'ignore t))
           (buffer (magit-difftastic--async-job-buffer job))
           killed)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook (lambda () (setq killed t)) nil t))
      (dst-async-test--finish job)
      (should-not killed)
      (should (buffer-live-p buffer))
      (dst-async-test--tick)
      (should killed)
      (should-not (buffer-live-p buffer)))))

(defun dst-async-test--fire (timer)
  "Fire mock TIMER once if it has not been canceled."
  (when (nth 3 timer)
    (setf (nth 3 timer) nil)
    (apply (nth 1 timer) (nth 2 timer))))

(defun dst-async-test--tick ()
  "Fire the scheduler's pending regular mock timer."
  (should magit-difftastic--async-timer)
  (dst-async-test--fire magit-difftastic--async-timer))

(defun dst-async-test--start-background ()
  "Fire the idle gate and its deferred scheduler turn."
  (should magit-difftastic--async-idle-timer)
  (dst-async-test--fire magit-difftastic--async-idle-timer)
  (dst-async-test--tick))

(defun dst-async-test--request (key owner callback &optional urgent)
  "Request test KEY for OWNER and CALLBACK with optional URGENT priority."
  (magit-difftastic--async-request
   key default-directory '("--version") process-environment
   owner callback urgent))

(defun dst-async-test--finish (job &optional output status code)
  "Complete mock JOB with OUTPUT, STATUS and CODE."
  (let ((process (magit-difftastic--async-job-process job)))
    (with-current-buffer (dst-async-test--process-buffer process)
      (insert (or output "output")))
    (setf (dst-async-test--process-status process) (or status 'exit)
          (dst-async-test--process-code process) (or code 0))
    (funcall (dst-async-test--process-sentinel process) process "finished")))

(ert-deftest magit-difftastic-async/dedup-launch-and-subscriptions ()
  (dst-async-test--mocked
    (let* (results
           (callback (lambda (raw error) (push (list raw error) results)))
           (job (dst-async-test--request (list "key") owner-a callback t)))
      (should (eq job (dst-async-test--request
                       (list "key") owner-a callback t)))
      (should (eq job (dst-async-test--request
                       (list "key") owner-b callback)))
      (should (= (length launches) 1))
      (should (equal (nth 1 (car launches)) default-directory))
      (should (equal (nth 2 (car launches)) process-environment))
      (should (equal (nth 3 (car launches)) '("--version")))
      (dst-async-test--finish job "complete")
      (should-not results)
      (should (eq (magit-difftastic--async-job-state job) 'done))
      (should (= (hash-table-count magit-difftastic--async-jobs) 1))
      (magit-difftastic--async-promote job)
      (dst-async-test--tick)
      (should (equal results '(("complete" nil) ("complete" nil))))
      (should (= (hash-table-count magit-difftastic--async-jobs) 0))
      (should-not magit-difftastic--async-timer)
      (should-not magit-difftastic--async-idle-timer)
      (should-not (memq #'magit-difftastic--async-owner-killed
                        (buffer-local-value 'kill-buffer-hook owner-a)))
      (should (= (length launches) 1)))))

(ert-deftest magit-difftastic-async/priority-and-single-slot-refill ()
  (dst-async-test--mocked
    (setq limit 1)
    (let ((a (dst-async-test--request 'a owner-a #'ignore))
          (b (dst-async-test--request 'b owner-a #'ignore))
          (c (dst-async-test--request 'c owner-a #'ignore)))
      (should-not launches)
      (magit-difftastic--async-promote c)
      (should (eq (magit-difftastic--async-job-state c) 'running))
      (dst-async-test--start-background)
      (magit-difftastic--async-promote b)
      (magit-difftastic--async-promote b)
      (should (= (length launches) 1))
      (dst-async-test--finish c)
      (should (= (length launches) 1))
      (dst-async-test--tick)
      (should (eq (magit-difftastic--async-job-state b) 'running))
      (should (eq (magit-difftastic--async-job-state a) 'queued))
      (dst-async-test--finish b)
      (dst-async-test--tick)
      (should (eq (magit-difftastic--async-job-state a) 'running))
      (should (= (length launches) 3))
      (should (= magit-difftastic--async-active 1)))))

(ert-deftest magit-difftastic-async/reserved-slot ()
  (dst-async-test--mocked
    (setq limit 3)
    (let ((a (dst-async-test--request 'a owner-a #'ignore))
          (b (dst-async-test--request 'b owner-a #'ignore))
          (c (dst-async-test--request 'c owner-a #'ignore)))
      (dst-async-test--start-background)
      (should (= magit-difftastic--async-active 2))
      (should (eq (magit-difftastic--async-job-state c) 'queued))
      (let ((urgent (dst-async-test--request 'urgent owner-b #'ignore t)))
        (should (= magit-difftastic--async-active 3))
        (dst-async-test--request 'urgent-2 owner-b #'ignore t)
        (should (= (length launches) 3))
        (dst-async-test--finish urgent)
        (dst-async-test--tick)
        (should (= magit-difftastic--async-active 3))
        (dst-async-test--finish a)
        (dst-async-test--tick)
        (should (eq (magit-difftastic--async-job-state c) 'queued))
        (dst-async-test--finish b)
        (dst-async-test--tick)
        (should (eq (magit-difftastic--async-job-state c) 'running))
        (should (= magit-difftastic--async-active 2))))))

(ert-deftest magit-difftastic-async/refresh-defers-launch-and-delivery ()
  (dst-async-test--mocked
    (let (called job)
      (let ((magit--refreshing-buffer-p t))
        (setq job (dst-async-test--request
                   'key owner-a (lambda (&rest _) (setq called t)) t))
        (dst-async-test--tick)
        (should-not launches))
      (dst-async-test--tick)
      (should (= (length launches) 1))
      (let ((magit--refreshing-buffer-p t))
        (dst-async-test--finish job)
        (dst-async-test--tick)
        (should-not called))
      (dst-async-test--tick)
      (should called))))

(ert-deftest magit-difftastic-async/cancel-owner-and-stale-completion ()
  (dst-async-test--mocked
    (let* ((job (dst-async-test--request 'key owner-a #'ignore t))
           (process (magit-difftastic--async-job-process job))
           (sentinel (dst-async-test--process-sentinel process))
           (buffer (dst-async-test--process-buffer process)))
      (dst-async-test--request 'key owner-b #'ignore)
      (magit-difftastic--async-cancel-buffer owner-a)
      (should (process-live-p process))
      (kill-buffer owner-b)
      (should-not (process-live-p process))
      (should-not (buffer-live-p buffer))
      (should (zerop magit-difftastic--async-active))
      (let ((replacement (dst-async-test--request 'key owner-a #'ignore t)))
        (funcall sentinel process "late signal")
        (should (eq replacement (gethash 'key magit-difftastic--async-jobs)))
        (should (= magit-difftastic--async-active 1)))
      (magit-difftastic--async-cancel-all)
      (should (cl-every (lambda (timer) (not (nth 3 timer))) timers)))))

(ert-deftest magit-difftastic-async/cancel-queued-and-pending-delivery ()
  (dst-async-test--mocked
    (let* ((called nil)
           (job (dst-async-test--request
                 'running owner-a (lambda (&rest _) (setq called t)) t)))
      (dst-async-test--request 'queued owner-a #'ignore)
      (dst-async-test--finish job)
      (let ((timer magit-difftastic--async-timer)
            (idle magit-difftastic--async-idle-timer))
        (magit-difftastic--async-cancel-buffer owner-a)
        ;; Even already-dispatched timer closures must be harmless.
        (apply (nth 1 timer) (nth 2 timer))
        (apply (nth 1 idle) (nth 2 idle)))
      (should-not called)
      (should-not magit-difftastic--async-queue)
      (should (zerop (hash-table-count magit-difftastic--async-jobs)))
      (should (= (length launches) 1))
      (should-not magit-difftastic--async-timer)
      (should-not magit-difftastic--async-idle-timer))))

(ert-deftest magit-difftastic-async/error-delivery-and-callback-isolation ()
  (dst-async-test--mocked
    (let (results)
      (dolist (kind '(exit signal launch))
        (setq launch-error (eq kind 'launch))
        (let* ((callback (lambda (raw error) (push (list raw error) results)))
               (job (dst-async-test--request kind owner-a callback t)))
          (dst-async-test--request kind owner-b
                                   (lambda (&rest _) (error "Bad consumer")))
          (unless launch-error (dst-async-test--finish job "diagnostic" kind 9))
          (should-not (eq (caar results) kind))
          (dst-async-test--tick)
          (should (eq (plist-get (cadar results) :kind) kind))
          (if launch-error
              (should (plist-get (cadar results) :condition))
            (should (= (plist-get (cadar results) :code) 9))
            (should (equal (caar results) "diagnostic")))))
      (should (= (length results) 3))
      (should (zerop magit-difftastic--async-active))
      (should (zerop (hash-table-count magit-difftastic--async-jobs))))))

(ert-deftest magit-difftastic-async/reentrant-subscription-dedup ()
  (dst-async-test--mocked
    (let ((calls 0) callback)
      (setq callback
            (lambda (&rest _)
              (cl-incf calls)
              (dst-async-test--request 'key owner-a callback t)))
      (let ((job (dst-async-test--request 'key owner-a callback t)))
        (dst-async-test--finish job)
        (dst-async-test--tick)
        (should (= calls 1))
        (should (= (length launches) 1))
        (should (zerop (hash-table-count magit-difftastic--async-jobs)))))))

(ert-deftest magit-difftastic-async/nonlocal-callback-exit-keeps-driver ()
  (dst-async-test--mocked
    (let ((job (dst-async-test--request
                'key owner-a (lambda (&rest _) (throw 'consumer 'escaped)) t))
          called)
      (dst-async-test--request 'key owner-b (lambda (&rest _) (setq called t)))
      (dst-async-test--finish job)
      (should (eq (catch 'consumer (dst-async-test--tick)) 'escaped))
      (should-not called)
      (dst-async-test--tick)
      (should called)
      (should (zerop (hash-table-count magit-difftastic--async-jobs))))))

(defun dst-async-test--wait (predicate)
  "Run the event loop until PREDICATE succeeds, with a ten-second deadline."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01)
      (sleep-for 0.01))
    (should (funcall predicate))))

(ert-deftest magit-difftastic-async/real-large-output-is-complete ()
  (skip-unless (executable-find "git"))
  (dst-async-test--isolated
    (let* ((file (make-temp-file "dst-async-output-"))
           (expected (concat (apply #'concat (make-list 20000 "αβ long line\n"))
                             "FINAL-TAIL-WITHOUT-NEWLINE"))
           result done)
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file file (insert expected)))
            (let* ((coding-system-for-read 'utf-8-unix)
                   (job (magit-difftastic--async-request
                         'large default-directory
                         (list "--no-pager" "diff" "--no-index" "--no-ext-diff"
                               "--" null-device file)
                         process-environment owner-a
                         (lambda (raw error) (setq result (list raw error) done t))
                         t)))
              (dst-async-test--wait (lambda () done))
              (should (eq (magit-difftastic--async-job-state job) 'done))
              (should-not (magit-difftastic--async-job-buffer job)))
            (should (equal (cadr result) '(:kind exit :code 1)))
            (let ((expected-diff
                   (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8-unix))
                       (process-file "git" nil t nil "--no-pager" "diff"
                                     "--no-index" "--no-ext-diff"
                                     "--" null-device file))
                     (buffer-string))))
              (should (equal (car result) expected-diff)))
            (should (string-match-p "FINAL-TAIL-WITHOUT-NEWLINE" (car result))))
        (delete-file file)))))

(ert-deftest magit-difftastic-async/real-fast-success ()
  (skip-unless (executable-find "git"))
  (dst-async-test--isolated
    (dotimes (i 12)
      (let (result done)
        (dst-async-test--request
         i owner-a (lambda (raw error) (setq result (list raw error) done t)) t)
        (dst-async-test--wait (lambda () done))
        (should-not (cadr result))
        (should (string-match-p "\\`git version [^\n]+\n\\'" (car result)))))
    (should (zerop magit-difftastic--async-active))
    (should (zerop (hash-table-count magit-difftastic--async-jobs)))))

(ert-deftest magit-difftastic-async/own-refresh-guard-without-magit-variable ()
  (dst-async-test--mocked
    (makunbound 'magit--refreshing-buffer-p)
    (should-not (boundp 'magit--refreshing-buffer-p))
    (let (called job)
      (let ((magit-difftastic--refreshing t))
        (should (magit-difftastic--async-refreshing-p))
        (setq job (dst-async-test--request
                   'key owner-a (lambda (&rest _) (setq called t)) t))
        (dst-async-test--tick)
        (should-not launches))
      (should-not (magit-difftastic--async-refreshing-p))
      (dst-async-test--tick)
      (should (= (length launches) 1))
      (dst-async-test--finish job)
      (let ((magit-difftastic--refreshing t))
        (dst-async-test--tick)
        (should-not called)
        (should (magit-difftastic--async-current-p job)))
      (dst-async-test--tick)
      (should called)
      (should-not (magit-difftastic--async-current-p job)))))

(ert-deftest magit-difftastic-async/validation-dedup-and-selective-unsubscribe ()
  (dst-async-test--mocked
    (let* (results
           (old (lambda (&rest _) (push 'old results)))
           (current (lambda (&rest _) (push 'current results)))
           (other (lambda (&rest _) (push 'other results)))
           (key '(validate (lazy "sample.txt")))
           (job (dst-async-test--request key owner-a old t))
           (process (magit-difftastic--async-job-process job)))
      (should (eq job (dst-async-test--request
                       (copy-tree key) owner-a current t)))
      (should (eq job (dst-async-test--request
                       (copy-tree key) owner-b other)))
      (magit-difftastic--async-unsubscribe owner-a old)
      (should (process-live-p process))
      (should (= magit-difftastic--async-active 1))
      (should (= (length (magit-difftastic--async-job-subscribers job)) 2))
      (should (memq #'magit-difftastic--async-owner-killed
                    (buffer-local-value 'kill-buffer-hook owner-a)))
      (dst-async-test--finish job "metadata")
      (dst-async-test--tick)
      (should (equal results '(other current)))
      (should (= (length launches) 1))
      (should-not (magit-difftastic--async-current-p job))
      (should-not (memq #'magit-difftastic--async-owner-killed
                        (buffer-local-value 'kill-buffer-hook owner-a))))))

(ert-deftest magit-difftastic-async/unsubscribe-last-consumer-aborts ()
  (dst-async-test--mocked
    (dolist (state '(queued running done))
      (let* ((callback (lambda (&rest _) (ert-fail "Unsubscribed callback")))
             (job (dst-async-test--request state owner-a callback
                                           (not (eq state 'queued))))
             (buffer (magit-difftastic--async-job-buffer job)))
        (when (eq state 'done) (dst-async-test--finish job))
        (magit-difftastic--async-unsubscribe owner-a callback)
        (should-not (magit-difftastic--async-current-p job))
        (should-not (buffer-live-p buffer))
        (should (zerop magit-difftastic--async-active))
        (should-not magit-difftastic--async-queue)
        (should-not magit-difftastic--async-timer)
        (should-not magit-difftastic--async-idle-timer)))))

(ert-deftest magit-difftastic-async/completion-budget-and-urgent-first ()
  (dst-async-test--mocked
    (let* ((clock 0.0)
           results
           (background (dst-async-test--request
                        'background owner-a
                        (lambda (&rest _) (push 'background results))))
           urgent)
      (dst-async-test--start-background)
      (setq urgent (dst-async-test--request
                    'urgent owner-b
                    (lambda (&rest _)
                      (push 'urgent results)
                      (setq clock 0.011)) t))
      (dst-async-test--finish background)
      (dst-async-test--finish urgent)
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) clock)))
        (dst-async-test--tick)
        (should (equal results '(urgent)))
        (should (magit-difftastic--async-current-p background))
        (should-not (magit-difftastic--async-current-p urgent))
        (should magit-difftastic--async-timer)
        (dst-async-test--tick)
        (should (equal results '(background urgent)))
        (should (zerop (hash-table-count magit-difftastic--async-jobs)))
        (should-not magit-difftastic--async-timer)))))

(provide 'magit-difftastic-async-test)
;;; magit-difftastic-async-test.el ends here
