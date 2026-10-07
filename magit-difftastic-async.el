;;; magit-difftastic-async.el --- Shared asynchronous Git jobs -*- lexical-binding: t; -*-

;;; Commentary:
;; Internal scheduler for shared Git output.  Consumers own the output cache.
;; Background batches wait for idle time and leave one slot for urgent work.
;; Completion refills the batch without another idle delay.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function magit-difftastic--max-jobs "magit-difftastic" ())
(defvar magit--refreshing-buffer-p nil)
(defvar magit-difftastic--refreshing nil)

(defun magit-difftastic--async-refreshing-p ()
  "Return non-nil while a Magit buffer is being rebuilt."
  (or magit-difftastic--refreshing
      (bound-and-true-p magit--refreshing-buffer-p)))

(defvar magit-difftastic--async-idle-delay 0.2
  "Idle seconds before starting a background batch.")
(defvar magit-difftastic--async-jobs (make-hash-table :test #'equal))
(defvar magit-difftastic--async-queue nil)
(defvar magit-difftastic--async-active 0)
(defvar magit-difftastic--async-ready nil)
(defvar magit-difftastic--async-timer nil)
(defvar magit-difftastic--async-idle-timer nil)
(defvar magit-difftastic--async-token nil)
(defvar magit-difftastic--async-idle-token nil)
(defvar magit-difftastic--async-driving nil)

(cl-defstruct (magit-difftastic--async-job
               (:constructor magit-difftastic--async-job-create))
  key (state 'queued) process directory args env urgent buffer
  subscribers raw error)

(defun magit-difftastic--async-current-p (job)
  "Return non-nil if JOB is still registered."
  (eq job (gethash (magit-difftastic--async-job-key job)
                   magit-difftastic--async-jobs)))

(defun magit-difftastic--async-schedule ()
  "Arrange a deferred scheduler turn."
  (unless magit-difftastic--async-timer
    (let ((token (list t)))
      (setq magit-difftastic--async-token token
            magit-difftastic--async-timer
            (run-at-time 0.01 nil #'magit-difftastic--async-drive token)))))

(defun magit-difftastic--async-idle ()
  "Arrange the start of a background batch."
  (unless (or magit-difftastic--async-ready
              magit-difftastic--async-idle-timer)
    (let ((token (list t)))
      (setq magit-difftastic--async-idle-token token
            magit-difftastic--async-idle-timer
            (run-with-idle-timer
             magit-difftastic--async-idle-delay nil
             (lambda ()
               (when (eq token magit-difftastic--async-idle-token)
                 (setq magit-difftastic--async-idle-timer nil
                       magit-difftastic--async-idle-token nil
                       magit-difftastic--async-ready t)
                 (magit-difftastic--async-schedule))))))))

(defun magit-difftastic--async-stop-timers ()
  "Cancel scheduler timers and reset batch readiness."
  (dolist (timer (list magit-difftastic--async-timer
                       magit-difftastic--async-idle-timer))
    (when timer (cancel-timer timer)))
  (setq magit-difftastic--async-timer nil
        magit-difftastic--async-idle-timer nil
        magit-difftastic--async-token nil
        magit-difftastic--async-idle-token nil
        magit-difftastic--async-ready nil))

(defun magit-difftastic--async-unhook (owner)
  "Remove OWNER's cleanup hook when it has no subscriptions."
  (when (buffer-live-p owner)
    (let (subscribed)
      (maphash (lambda (_key job)
                 (when (assq owner (magit-difftastic--async-job-subscribers job))
                   (setq subscribed t)))
               magit-difftastic--async-jobs)
      (unless subscribed
        (with-current-buffer owner
          (remove-hook 'kill-buffer-hook
                       #'magit-difftastic--async-owner-killed t))))))

(defun magit-difftastic--async-release-buffer (job)
  "Release JOB's output buffer."
  (when-let* ((buffer (magit-difftastic--async-job-buffer job)))
    (setf (magit-difftastic--async-job-buffer job) nil)
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun magit-difftastic--async-forget (job)
  "Unregister JOB and release its subscriptions and output."
  (when (magit-difftastic--async-current-p job)
    (remhash (magit-difftastic--async-job-key job)
             magit-difftastic--async-jobs))
  (setq magit-difftastic--async-queue
        (delq job magit-difftastic--async-queue))
  (let ((subscribers (magit-difftastic--async-job-subscribers job)))
    (setf (magit-difftastic--async-job-subscribers job) nil
          (magit-difftastic--async-job-raw job) nil)
    (dolist (subscription subscribers)
      (magit-difftastic--async-unhook (car subscription))))
  (magit-difftastic--async-release-buffer job)
  (when (zerop (hash-table-count magit-difftastic--async-jobs))
    (magit-difftastic--async-stop-timers)))

(defun magit-difftastic--async-abort (job)
  "Cancel JOB without delivering its subscriptions."
  (when (eq (magit-difftastic--async-job-state job) 'running)
    (cl-decf magit-difftastic--async-active))
  (setf (magit-difftastic--async-job-state job) 'done)
  (when-let* ((process (magit-difftastic--async-job-process job)))
    (set-process-sentinel process #'ignore)
    (when (process-live-p process) (delete-process process)))
  (magit-difftastic--async-forget job))

(defun magit-difftastic--async-finish (job error)
  "Record JOB's complete output and ERROR for deferred delivery."
  (when (and (magit-difftastic--async-current-p job)
             (eq (magit-difftastic--async-job-state job) 'running))
    (cl-decf magit-difftastic--async-active)
    (setf (magit-difftastic--async-job-state job) 'done
          (magit-difftastic--async-job-error job) error
          (magit-difftastic--async-job-raw job)
          (if (buffer-live-p (magit-difftastic--async-job-buffer job))
              (with-current-buffer (magit-difftastic--async-job-buffer job)
                (buffer-substring-no-properties (point-min) (point-max)))
            ""))
    (magit-difftastic--async-schedule)))

(defun magit-difftastic--async-sentinel (job process _event)
  "Record terminal PROCESS output for JOB."
  ;; Emacs delivers pending process output before a terminal sentinel call.
  ;; Polling process-status immediately after launch does not give that promise.
  (when (eq process (magit-difftastic--async-job-process job))
    (pcase (process-status process)
      ('exit
       (let ((code (process-exit-status process)))
         (magit-difftastic--async-finish
          job (unless (zerop code) (list :kind 'exit :code code)))))
      ('signal
       (magit-difftastic--async-finish
        job (list :kind 'signal :code (process-exit-status process)))))))

(defun magit-difftastic--async-launch (job)
  "Start JOB's Git process."
  (setf (magit-difftastic--async-job-state job) 'running)
  (cl-incf magit-difftastic--async-active)
  (condition-case err
      (let* ((default-directory (magit-difftastic--async-job-directory job))
             (process-environment (magit-difftastic--async-job-env job))
             (process-connection-type nil)
             (buffer (generate-new-buffer " *magit-difftastic-async*"))
             (process
              (progn
                (setf (magit-difftastic--async-job-buffer job) buffer)
                (apply #'start-file-process "magit-difftastic-async" buffer
                       "git" (magit-difftastic--async-job-args job)))))
        (setf (magit-difftastic--async-job-process job) process)
        (set-process-query-on-exit-flag process nil)
        ;; A remote file handler can yield during process creation.
        (if (not (magit-difftastic--async-current-p job))
            (progn
              (set-process-sentinel process #'ignore)
              (when (process-live-p process) (delete-process process)))
          (set-process-sentinel
           process (lambda (proc event)
                     (magit-difftastic--async-sentinel job proc event)))))
    ((error quit)
     (when-let* ((process (magit-difftastic--async-job-process job)))
       (set-process-sentinel process #'ignore)
       (when (process-live-p process) (delete-process process)))
     (magit-difftastic--async-finish
      job (list :kind 'launch :condition err)))))

(defun magit-difftastic--async-pump ()
  "Start eligible queued jobs within the global capacity limit."
  (unless (magit-difftastic--async-refreshing-p)
    (let* ((limit (max 1 (magit-difftastic--max-jobs)))
           (background-limit (if (> limit 1) (1- limit) 1))
           job)
      (while
          (and (< magit-difftastic--async-active limit)
               (setq job
                     (or (cl-find-if #'magit-difftastic--async-job-urgent
                                     magit-difftastic--async-queue)
                         (and magit-difftastic--async-ready
                              (< magit-difftastic--async-active background-limit)
                              (car magit-difftastic--async-queue)))))
        (setq magit-difftastic--async-queue
              (delq job magit-difftastic--async-queue))
        (magit-difftastic--async-launch job)))))

(defun magit-difftastic--async-deliver (job)
  "Deliver JOB's result to its remaining live subscribers."
  (unwind-protect
      (let (subscription)
        (while (and (magit-difftastic--async-current-p job)
                    (not (magit-difftastic--async-refreshing-p))
                    (setq subscription
                          (cl-find-if (lambda (sub) (not (nth 2 sub)))
                                      (magit-difftastic--async-job-subscribers job))))
          ;; Retain delivered identities until the job is forgotten, including
          ;; while a callback reenters request with the same stable closure.
          (setf (nth 2 subscription) t)
          (when (buffer-live-p (car subscription))
            (condition-case err
                (funcall (cadr subscription)
                         (magit-difftastic--async-job-raw job)
                         (magit-difftastic--async-job-error job))
              ((error quit)
               (message "Difftastic async callback failed: %S" err))))))
    (when (magit-difftastic--async-current-p job)
      (if (cl-every (lambda (sub) (nth 2 sub))
                    (magit-difftastic--async-job-subscribers job))
          (magit-difftastic--async-forget job)
        (magit-difftastic--async-schedule)))))

(defun magit-difftastic--async-drive (token)
  "Deliver completions and refill capacity for scheduler TOKEN."
  (when (eq token magit-difftastic--async-token)
    (setq magit-difftastic--async-timer nil
          magit-difftastic--async-token nil)
    (if (or magit-difftastic--async-driving
            (magit-difftastic--async-refreshing-p))
        (magit-difftastic--async-schedule)
      (let ((magit-difftastic--async-driving t)
            (deadline (+ (float-time) 0.01)))
        (unwind-protect
            (let ((jobs (sort (hash-table-values magit-difftastic--async-jobs)
                              (lambda (a b)
                                (and (magit-difftastic--async-job-urgent a)
                                     (not (magit-difftastic--async-job-urgent b)))))))
              (magit-difftastic--async-pump)
              (while (and jobs (< (float-time) deadline))
                (let ((job (pop jobs)))
                  (when (and (magit-difftastic--async-current-p job)
                             (eq (magit-difftastic--async-job-state job) 'done))
                    (magit-difftastic--async-deliver job)))))
          (magit-difftastic--async-pump)
          (when (cl-some (lambda (job)
                           (eq (magit-difftastic--async-job-state job) 'done))
                         (hash-table-values magit-difftastic--async-jobs))
            (magit-difftastic--async-schedule)))))))

(defun magit-difftastic--async-request
    (key directory args env owner callback &optional urgent)
  "Subscribe OWNER and CALLBACK to Git ARGS in DIRECTORY using ENV under KEY.
Return a shared job, deduplicated by `equal' KEY.  OWNER must be a live buffer.
Subscriptions are deduplicated by `eq' OWNER and CALLBACK.  URGENT bypasses
background idle delay.  CALLBACK receives (RAW-STRING ERROR) on a later timer
turn outside Magit refresh.  ERROR is nil on success, or a plist with :kind
`exit' or `signal' and :code, or :kind `launch' and :condition.  Cancellation
unsubscribes without calling CALLBACK.  The first request supplies job inputs."
  (unless (buffer-live-p owner) (error "Async owner is not a live buffer"))
  (let ((job (gethash key magit-difftastic--async-jobs)))
    (unless job
      (setq job (magit-difftastic--async-job-create
                 :key key :directory directory :args (copy-sequence args)
                 :env (copy-sequence env)))
      (puthash key job magit-difftastic--async-jobs)
      (setq magit-difftastic--async-queue
            (nconc magit-difftastic--async-queue (list job))))
    (unless (cl-find-if (lambda (sub)
                          (and (eq owner (car sub)) (eq callback (cadr sub))))
                        (magit-difftastic--async-job-subscribers job))
      (setf (magit-difftastic--async-job-subscribers job)
            (nconc (magit-difftastic--async-job-subscribers job)
                   (list (list owner callback nil)))))
    (with-current-buffer owner
      (add-hook 'kill-buffer-hook #'magit-difftastic--async-owner-killed nil t))
    (cond (urgent (magit-difftastic--async-promote job))
          ((eq (magit-difftastic--async-job-state job) 'done)
           (magit-difftastic--async-schedule))
          (magit-difftastic--async-ready (magit-difftastic--async-schedule))
          (t (magit-difftastic--async-idle)))
    job))

(defun magit-difftastic--async-promote (job)
  "Give queued JOB urgent priority without relaunching running or done jobs."
  (when (and (magit-difftastic--async-current-p job)
             (eq (magit-difftastic--async-job-state job) 'queued))
    (setf (magit-difftastic--async-job-urgent job) t)
    (if (or magit-difftastic--async-driving
            (magit-difftastic--async-refreshing-p))
        (magit-difftastic--async-schedule)
      (let ((magit-difftastic--async-driving t))
        (magit-difftastic--async-pump))))
  job)

(defun magit-difftastic--async-owner-killed ()
  "Unsubscribe the buffer being killed."
  (magit-difftastic--async-cancel-buffer (current-buffer)))

(defun magit-difftastic--async-unsubscribe (owner callback)
  "Remove OWNER's CALLBACK subscription, canceling jobs with no consumers."
  (when callback
    (dolist (job (hash-table-values magit-difftastic--async-jobs))
      (setf (magit-difftastic--async-job-subscribers job)
            (cl-delete-if (lambda (sub)
                            (and (eq owner (car sub)) (eq callback (cadr sub))))
                          (magit-difftastic--async-job-subscribers job)))
      (unless (magit-difftastic--async-job-subscribers job)
        (magit-difftastic--async-abort job)))
    (magit-difftastic--async-unhook owner)
    (when magit-difftastic--async-queue (magit-difftastic--async-schedule))))

(defun magit-difftastic--async-cancel-buffer (buffer)
  "Unsubscribe BUFFER and cancel jobs without remaining subscribers."
  (dolist (job (hash-table-values magit-difftastic--async-jobs))
    (setf (magit-difftastic--async-job-subscribers job)
          (cl-delete-if (lambda (sub)
                          (or (eq buffer (car sub))
                              (not (buffer-live-p (car sub)))))
                        (magit-difftastic--async-job-subscribers job)))
    (unless (magit-difftastic--async-job-subscribers job)
      (magit-difftastic--async-abort job)))
  (magit-difftastic--async-unhook buffer)
  (when magit-difftastic--async-queue (magit-difftastic--async-schedule)))

(defun magit-difftastic--async-cancel-all ()
  "Cancel every job and subscription and all scheduler timers."
  (dolist (job (hash-table-values magit-difftastic--async-jobs))
    (magit-difftastic--async-abort job))
  (setq magit-difftastic--async-queue nil)
  (magit-difftastic--async-stop-timers))

(provide 'magit-difftastic-async)
;;; magit-difftastic-async.el ends here
