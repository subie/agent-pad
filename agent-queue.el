;;; agent-queue.el --- Manage coding agents in tmux from Emacs -*- lexical-binding: t -*-

;; Author: Subie Patel
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (eat "0.9"))
;; Keywords: processes, tools
;; URL: https://github.com/subiepatel/agent-queue

;;; Commentary:

;; agent-queue provides a dashboard for managing coding agents running
;; in tmux windows.  Agents are dispatched into a shared tmux session
;; and their status is tracked via flat files in ~/.agent-state/.
;;
;; Main entry points:
;;   M-x agent-queue     — open the agent dashboard
;;   M-x agent-dispatch  — start a new agent
;;
;; The Emacs package also adds the bundled bin/ scripts to PATH so
;; that agent-start, agent-stop, etc. work from any shell.

;;; Code:

(require 'eat)

;;;; Customization

(defgroup agent-queue nil
  "Manage coding agents in tmux."
  :group 'processes
  :prefix "agent-queue-")

(defcustom agent-queue-session "agents"
  "Name of the tmux session for agent windows."
  :type 'string)

(defcustom agent-queue-state-dir (expand-file-name "~/.agent-state")
  "Directory containing agent state files."
  :type 'directory)

(defcustom agent-queue-silence-seconds 30
  "Seconds of no output before an agent is marked as waiting."
  :type 'integer)

(defcustom agent-queue-refresh-interval 5
  "Seconds between auto-refresh of the queue buffer."
  :type 'integer)

;;;; Setup bin/ PATH

(let ((bin-dir (expand-file-name "bin" (file-name-directory
                                        (or load-file-name buffer-file-name
                                            default-directory)))))
  (when (file-directory-p bin-dir)
    (add-to-list 'exec-path bin-dir)
    (setenv "PATH" (concat bin-dir ":" (getenv "PATH")))))

;;;; State management

(defvar agent-queue--previous-states (make-hash-table :test 'equal)
  "Previous status of each task, for detecting transitions.")

(defvar agent-queue--timer nil
  "Timer for auto-refreshing the queue buffer.")

(defun agent-queue--read-state-file (file)
  "Read and parse a single state FILE. Returns (task status timestamp note window-id)."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let* ((line (string-trim (buffer-string)))
             (parts (split-string line "|")))
        (when (>= (length parts) 3)
          (list (nth 1 parts)              ; task
                (nth 0 parts)              ; status
                (string-to-number (nth 2 parts)) ; timestamp
                (or (nth 3 parts) "")      ; note
                (or (nth 4 parts) "")))))))  ; window-id

(defun agent-queue--window-activity (window-id)
  "Get the last activity timestamp for WINDOW-ID.
Returns epoch seconds, or nil if window not found."
  (when (and window-id (not (string-empty-p window-id)))
    (let ((output (string-trim
                   (shell-command-to-string
                    (format "tmux display -t %s -p '#{window_activity}' 2>/dev/null"
                            (shell-quote-argument window-id))))))
      (unless (string-empty-p output)
        (string-to-number output)))))

(defun agent-queue--derive-status (window-id current-status)
  "Derive effective status for agent with WINDOW-ID based on tmux activity.
CURRENT-STATUS is the status from the state file."
  ;; Don't override explicit done/blocked signals
  (if (member current-status '("done" "blocked"))
      current-status
    (let ((activity (agent-queue--window-activity window-id)))
      (if activity
          (let ((age (- (float-time) activity)))
            (if (> age agent-queue-silence-seconds)
                "waiting"
              "running"))
        ;; No window found — might have exited
        current-status))))

(defun agent-queue--update-state-and-window (task new-status old-status note)
  "Update state file and tmux window name for TASK if status changed."
  (unless (string= new-status old-status)
    ;; Use the shell command which handles emoji prefix matching
    (shell-command-to-string
     (format "agent-signal %s %s %s 2>/dev/null"
             (shell-quote-argument new-status)
             (shell-quote-argument task)
             (shell-quote-argument (or note ""))))
    ;; Notify on attention-needed transitions
    (when (member new-status '("waiting" "done"))
      (message "Agent %s: %s%s" task new-status
               (if (or (null note) (string-empty-p note))
                   ""
                 (format " — %s" note))))))

(defun agent-queue--read-all-state ()
  "Read all agent state files and derive current status.
Returns list of (task status age-string note) entries."
  (let ((dir agent-queue-state-dir)
        (now (float-time))
        entries)
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "^[^.]"))
        (when-let ((state (agent-queue--read-state-file file)))
          (cl-destructuring-bind (task file-status timestamp note window-id) state
            (let* ((derived-status (agent-queue--derive-status window-id file-status))
                   (old-status (gethash task agent-queue--previous-states))
                   (age (/ (- now timestamp) 60.0))
                   (age-str (if (< age 60)
                                (format "%.0fm" age)
                              (format "%.1fh" (/ age 60.0)))))
              ;; Update state file + window if status changed via polling
              (when old-status
                (agent-queue--update-state-and-window
                 task derived-status old-status note))
              (puthash task derived-status agent-queue--previous-states)
              (push (list task
                          (vector derived-status task age-str note))
                    entries))))))
    (nreverse entries)))

;;;; Status priority for sorting

(defun agent-queue--status-priority (status)
  "Return sort priority for STATUS. Lower = more attention needed."
  (pcase status
    ("blocked" 0)
    ("waiting" 1)
    ("done"    2)
    ("running" 3)
    (_         4)))

(defun agent-queue--sort-by-attention (a b)
  "Sort entries A and B by attention priority."
  (let ((sa (aref (cadr a) 0))
        (sb (aref (cadr b) 0)))
    (< (agent-queue--status-priority sa)
       (agent-queue--status-priority sb))))

;;;; Faces

(defface agent-queue-running '((t :inherit default))
  "Face for running agents.")

(defface agent-queue-waiting '((t :inherit warning))
  "Face for agents waiting on input.")

(defface agent-queue-done '((t :inherit success))
  "Face for completed agents.")

(defface agent-queue-blocked '((t :inherit error))
  "Face for blocked agents.")

;;;; Queue buffer

(defun agent-queue--face-for (status)
  "Return the face for STATUS."
  (pcase status
    ("running" 'agent-queue-running)
    ("waiting" 'agent-queue-waiting)
    ("done"    'agent-queue-done)
    ("blocked" 'agent-queue-blocked)
    (_         'default)))

(defun agent-queue-refresh ()
  "Refresh the agent queue buffer."
  (interactive)
  (when-let ((buf (get-buffer "*agent-queue*")))
    (with-current-buffer buf
      (let ((entries (agent-queue--read-all-state)))
        (setq tabulated-list-entries entries)
        (tabulated-list-print t)
        ;; Apply faces per-row
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (when-let ((entry (tabulated-list-get-entry)))
              (let* ((status (aref entry 0))
                     (face (agent-queue--face-for status))
                     (beg (line-beginning-position))
                     (end (line-end-position)))
                (put-text-property beg end 'face face)))
            (forward-line 1)))))))

(defun agent-queue--get-window-id (task)
  "Get the tmux window ID for TASK from its state file."
  (let ((f (expand-file-name task agent-queue-state-dir)))
    (when (file-readable-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (let* ((line (string-trim (buffer-string)))
               (parts (split-string line "|")))
          (when (>= (length parts) 5)
            (nth 4 parts)))))))

(defun agent-queue-jump ()
  "Open an eat buffer attached to the selected agent's tmux window."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let* ((task (aref entry 1))
           (buf-name (format "*agent:%s*" task)))
      (if (get-buffer buf-name)
          (switch-to-buffer buf-name)
        (let ((wid (agent-queue--get-window-id task)))
          (if (and wid (not (string-empty-p wid)))
              (let ((eat-buf (eat-make buf-name
                                      "/bin/bash" nil
                                      "-c"
                                      (format "TMUX='' exec tmux attach -t %s"
                                              (shell-quote-argument wid)))))
                (when eat-buf
                  (switch-to-buffer eat-buf)))
            (message "No window ID found for %s" task)))))))

(defun agent-queue-mark-done ()
  "Mark the selected agent as done and clean up."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((task (aref entry 1)))
      (shell-command (format "agent-signal done %s 'marked done from queue'"
                             (shell-quote-argument task)))
      (agent-queue-refresh))))

(defun agent-queue-kill ()
  "Kill the selected agent's tmux window and state file."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((task (aref entry 1)))
      (when (yes-or-no-p (format "Kill agent '%s'? " task))
        (shell-command (format "agent-stop %s" (shell-quote-argument task)))
        (remhash task agent-queue--previous-states)
        (agent-queue-refresh)))))

(defun agent-queue-dispatch-from-queue ()
  "Dispatch a new agent from the queue buffer."
  (interactive)
  (call-interactively #'agent-dispatch))

(defvar agent-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-queue-jump)
    (define-key map (kbd "+")   #'agent-queue-dispatch-from-queue)
    (define-key map (kbd "g")   #'agent-queue-refresh)
    (define-key map (kbd "d")   #'agent-queue-mark-done)
    (define-key map (kbd "k")   #'agent-queue-kill)
    map)
  "Keymap for `agent-queue-mode'.")

(define-derived-mode agent-queue-mode tabulated-list-mode "AgentQueue"
  "Major mode for managing coding agents."
  (setq tabulated-list-format
        [("Status" 10 agent-queue--sort-by-attention)
         ("Task" 24 t)
         ("Age" 8 t)
         ("Note" 30 t)])
  (setq tabulated-list-sort-key '("Status" . nil))
  (tabulated-list-init-header))

;;;; Entry points

;;;###autoload
(defun agent-queue ()
  "Open the agent queue dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*agent-queue*")))
    (with-current-buffer buf
      (agent-queue-mode)
      (agent-queue-refresh)
      ;; Set up auto-refresh timer
      (when agent-queue--timer
        (cancel-timer agent-queue--timer))
      (setq agent-queue--timer
            (run-at-time t agent-queue-refresh-interval #'agent-queue-refresh)))
    (switch-to-buffer buf)))

;;;###autoload
(defun agent-dispatch (task cmd)
  "Dispatch a new agent with TASK name running CMD.
With prefix arg \\[universal-argument], also open an eat buffer
attached to the agent's tmux window."
  (interactive "sTask name: \nsCommand: ")
  (let ((result (shell-command-to-string
                 (format "agent-start %s %s 2>&1"
                         (shell-quote-argument task)
                         (shell-quote-argument cmd)))))
    (message "%s" (string-trim result))
    ;; Refresh queue if it's open
    (agent-queue-refresh)
    ;; With prefix arg, attach to the agent
    (when current-prefix-arg
      ;; Small delay to let tmux create the window and state file
      (run-at-time 0.5 nil
                   (lambda ()
                     (let* ((buf-name (format "*agent:%s*" task))
                            (wid (agent-queue--get-window-id task)))
                       (if (and wid (not (string-empty-p wid)))
                           (let ((eat-buf (eat-make buf-name
                                                    "/bin/bash" nil
                                                    "-c"
                                                    (format "TMUX='' exec tmux attach -t %s"
                                                            (shell-quote-argument wid)))))
                             (when eat-buf
                               (switch-to-buffer eat-buf)))
                         (message "Could not find window for %s" task))))))))

(provide 'agent-queue)
;;; agent-queue.el ends here
