;;; agent-pad.el --- Manage coding agents in tmux from Emacs -*- lexical-binding: t -*-

;; Author: Subie Patel
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (eat "0.9"))
;; Keywords: processes, tools
;; URL: https://github.com/subie/agent-pad

;;; Commentary:

;; agent-pad provides a dashboard for managing coding agents running
;; in tmux windows.  Agents are dispatched into a shared tmux session
;; and their status is tracked via flat files in ~/.agent-state/.
;;
;; Main entry points:
;;   M-x agent-pad     — open the agent dashboard
;;   M-x agent-dispatch  — start a new agent
;;
;; The Emacs package also adds the bundled bin/ scripts to PATH so
;; that agent-start, agent-stop, etc. work from any shell.

;;; Code:

(require 'eat)

;;;; Customization

(defgroup agent-pad nil
  "Manage coding agents in tmux."
  :group 'processes
  :prefix "agent-pad-")

(defcustom agent-pad-session "agents"
  "Name of the tmux session for agent windows."
  :type 'string)

(defcustom agent-pad-state-dir (expand-file-name "~/.agent-state")
  "Directory containing agent state files."
  :type 'directory)

(defcustom agent-pad-silence-seconds 30
  "Seconds of no output before an agent is marked as waiting."
  :type 'integer)

(defcustom agent-pad-refresh-interval 5
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

(defvar agent-pad--previous-states (make-hash-table :test 'equal)
  "Previous status of each task, for detecting transitions.")

(defvar agent-pad--timer nil
  "Timer for auto-refreshing the queue buffer.")

(defvar agent-pad--activity-cache (make-hash-table :test 'equal)
  "Maps window-id to (cons content-hash last-change-time).
Used to detect real pane output, since tmux `window_activity'
is also bumped by window selection and cannot distinguish
output from focus changes.")

(defun agent-pad--read-state-file (file)
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

(defun agent-pad--pane-content-hash (window-id)
  "Return a hash of WINDOW-ID's visible pane content.
Returns nil if the window does not exist.  Hashing the pane
content detects actual output, unlike `window_activity' which
tmux also bumps on window selection."
  (when (and window-id (not (string-empty-p window-id)))
    (with-temp-buffer
      (let ((status (call-process
                     "tmux" nil t nil
                     "capture-pane" "-p" "-t" window-id)))
        (when (eq status 0)
          (secure-hash 'md5 (buffer-string)))))))

(defun agent-pad--activity-age (window-id &optional baseline)
  "Return seconds since WINDOW-ID last produced new output.
Tracks pane-content changes across polls in `agent-pad--activity-cache'.
On first sight of a window, BASELINE (epoch seconds, e.g. the
state-file timestamp) seeds the last-change time so a long-idle
agent is not briefly mislabelled as running.  Returns nil if the
window no longer exists."
  (let ((hash (agent-pad--pane-content-hash window-id)))
    (when hash
      (let* ((now (float-time))
             (cached (gethash window-id agent-pad--activity-cache))
             (last-change (cond
                           ((and cached (equal (car cached) hash)) (cdr cached))
                           (cached now)
                           (baseline (float baseline))
                           (t now))))
        (puthash window-id (cons hash last-change) agent-pad--activity-cache)
        (- now last-change)))))

(defun agent-pad--derive-status (window-id current-status &optional baseline)
  "Derive effective status for agent with WINDOW-ID based on pane activity.
CURRENT-STATUS is the status from the state file.  BASELINE is the
state-file timestamp, used to seed activity on first sight."
  ;; Don't override explicit done/blocked signals
  (if (member current-status '("done" "blocked"))
      current-status
    (let ((age (agent-pad--activity-age window-id baseline)))
      (if age
          (if (> age agent-pad-silence-seconds)
              "waiting"
            "running")
        ;; No window found — might have exited
        current-status))))

(defun agent-pad--update-state-and-window (task new-status old-status note)
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

(defun agent-pad--read-all-state ()
  "Read all agent state files and derive current status.
Returns list of (task status age-string note) entries."
  (let ((dir agent-pad-state-dir)
        (now (float-time))
        entries)
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "^[^.]"))
        (when-let ((state (agent-pad--read-state-file file)))
          (cl-destructuring-bind (task file-status timestamp note window-id) state
            (let* ((derived-status (agent-pad--derive-status window-id file-status timestamp))
                   (old-status (gethash task agent-pad--previous-states))
                   (age (/ (- now timestamp) 60.0))
                   (age-str (if (< age 60)
                                (format "%.0fm" age)
                              (format "%.1fh" (/ age 60.0)))))
              ;; Update state file + window if status changed via polling
              (when old-status
                (agent-pad--update-state-and-window
                 task derived-status old-status note))
              (puthash task derived-status agent-pad--previous-states)
              (let ((face (agent-pad--face-for derived-status)))
                (push (list task
                            (vector (propertize derived-status 'face face)
                                    (propertize task 'face face)
                                    (propertize age-str 'face face)
                                    (propertize (or note "") 'face face)))
                      entries)))))))
    (nreverse entries)))

;;;; Status priority for sorting

(defun agent-pad--status-priority (status)
  "Return sort priority for STATUS. Lower = more attention needed."
  (pcase status
    ("blocked" 0)
    ("waiting" 1)
    ("done"    2)
    ("running" 3)
    (_         4)))

(defun agent-pad--sort-by-attention (a b)
  "Sort entries A and B by attention priority."
  (let ((sa (aref (cadr a) 0))
        (sb (aref (cadr b) 0)))
    (< (agent-pad--status-priority sa)
       (agent-pad--status-priority sb))))

;;;; Faces

(defface agent-pad-running '((t :inherit default))
  "Face for running agents.")

(defface agent-pad-waiting '((t :inherit warning))
  "Face for agents waiting on input.")

(defface agent-pad-done '((t :inherit success))
  "Face for completed agents.")

(defface agent-pad-blocked '((t :inherit error))
  "Face for blocked agents.")

;;;; Queue buffer

(defun agent-pad--face-for (status)
  "Return the face for STATUS."
  (pcase status
    ("running" 'agent-pad-running)
    ("waiting" 'agent-pad-waiting)
    ("done"    'agent-pad-done)
    ("blocked" 'agent-pad-blocked)
    (_         'default)))

(defun agent-pad-refresh ()
  "Refresh the agent queue buffer."
  (interactive)
  (when-let ((buf (get-buffer "*agent-pad*")))
    (with-current-buffer buf
      (let ((entries (agent-pad--read-all-state)))
        (setq tabulated-list-entries entries)
        (tabulated-list-print t)))))

(defun agent-pad--get-window-id (task)
  "Get the tmux window ID for TASK from its state file."
  (let ((f (expand-file-name task agent-pad-state-dir)))
    (when (file-readable-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (let* ((line (string-trim (buffer-string)))
               (parts (split-string line "|")))
          (when (>= (length parts) 5)
            (nth 4 parts)))))))

(defun agent-pad--tmux-attach-cmd (window-id task)
  "Build a tmux command that attaches to WINDOW-ID via a grouped session.
Uses a temporary grouped session so eat gets independent sizing
from the main tmux client."
  (let ((eat-session (format "eat-%s-%s" task (emacs-pid))))
    (format "TMUX='' exec tmux new-session -t %s -s %s \\; set-option destroy-unattached on \\; select-window -t %s"
            (shell-quote-argument agent-pad-session)
            (shell-quote-argument eat-session)
            (shell-quote-argument window-id))))

(defun agent-pad--eat-attach (buf-name window-id task)
  "Create an eat buffer BUF-NAME attached to tmux WINDOW-ID for TASK.
Displays the buffer before starting the process so eat picks up
the correct terminal dimensions from the Emacs window."
  (let ((buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      (unless (eq major-mode 'eat-mode)
        (eat-mode)))
    ;; Display first so eat gets correct window dimensions
    (switch-to-buffer buffer)
    ;; Now start the process
    (with-current-buffer buffer
      (unless (and eat-terminal
                   (eat-term-parameter eat-terminal 'eat--process))
        (eat-exec buffer buf-name "/bin/bash" nil
                  (list "-c" (agent-pad--tmux-attach-cmd window-id task)))))
    buffer))

(defun agent-pad-jump ()
  "Open an eat buffer attached to the selected agent's tmux window."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let* ((task (aref entry 1))
           (buf-name (format "*agent:%s*" task)))
      (if (get-buffer buf-name)
          (switch-to-buffer buf-name)
        (let ((wid (agent-pad--get-window-id task)))
          (if (and wid (not (string-empty-p wid)))
              (agent-pad--eat-attach buf-name wid task)
            (message "No window ID found for %s" task)))))))

(defun agent-pad--tmux-switch (window-id)
  "Switch the live tmux client to WINDOW-ID in the agents session.
Returns the trimmed shell output, which is empty on success."
  (string-trim
   (shell-command-to-string
    (format "tmux switch-client -t %s \\; select-window -t %s 2>&1"
            (shell-quote-argument agent-pad-session)
            (shell-quote-argument window-id)))))

(defun agent-pad-jump-tmux ()
  "Switch the live tmux client to the selected agent's window.
Unlike `agent-pad-jump', this does not open an eat buffer; it
moves the attached tmux client to the agent's window directly.
Requires Emacs to be running inside a tmux client."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((task (aref entry 1)))
      (let ((wid (agent-pad--get-window-id task)))
        (if (and wid (not (string-empty-p wid)))
            (let ((result (agent-pad--tmux-switch wid)))
              (if (string-empty-p result)
                  (message "Switched tmux to %s" task)
                (message "tmux: %s" result)))
          (message "No window ID found for %s" task))))))

(defun agent-pad-mark-done ()
  "Mark the selected agent as done and clean up."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((task (aref entry 1)))
      (shell-command (format "agent-signal done %s 'marked done from queue'"
                             (shell-quote-argument task)))
      (agent-pad-refresh))))

(defun agent-pad-kill ()
  "Kill the selected agent's tmux window and state file."
  (interactive)
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((task (aref entry 1)))
      (when (yes-or-no-p (format "Kill agent '%s'? " task))
        (shell-command (format "agent-stop %s" (shell-quote-argument task)))
        (remhash task agent-pad--previous-states)
        (agent-pad-refresh)))))

(defun agent-pad-dispatch-from-queue ()
  "Dispatch a new agent from the queue buffer."
  (interactive)
  (call-interactively #'agent-dispatch))

(defvar agent-pad-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-pad-jump)
    (define-key map (kbd "t")   #'agent-pad-jump-tmux)
    (define-key map (kbd "+")   #'agent-pad-dispatch-from-queue)
    (define-key map (kbd "g")   #'agent-pad-refresh)
    (define-key map (kbd "d")   #'agent-pad-mark-done)
    (define-key map (kbd "k")   #'agent-pad-kill)
    map)
  "Keymap for `agent-pad-mode'.")

(define-derived-mode agent-pad-mode tabulated-list-mode "AgentQueue"
  "Major mode for managing coding agents."
  (setq tabulated-list-format
        [("Status" 10 agent-pad--sort-by-attention)
         ("Task" 24 t)
         ("Age" 8 t)
         ("Note" 30 t)])
  (setq tabulated-list-sort-key '("Status" . nil))
  (tabulated-list-init-header))

;;;; Entry points

;;;###autoload
(defun agent-pad ()
  "Open the agent queue dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*agent-pad*")))
    (with-current-buffer buf
      (agent-pad-mode)
      (agent-pad-refresh)
      ;; Set up auto-refresh timer
      (when agent-pad--timer
        (cancel-timer agent-pad--timer))
      (setq agent-pad--timer
            (run-at-time t agent-pad-refresh-interval #'agent-pad-refresh)))
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
    (agent-pad-refresh)
    ;; With prefix arg, attach to the agent
    (when current-prefix-arg
      ;; Small delay to let tmux create the window and state file
      (run-at-time 0.5 nil
                   (lambda ()
                     (let* ((buf-name (format "*agent:%s*" task))
                            (wid (agent-pad--get-window-id task)))
                       (if (and wid (not (string-empty-p wid)))
                           (agent-pad--eat-attach buf-name wid task)
                         (message "Could not find window for %s" task))))))))

;;;###autoload
(defun agent-pad-jump-to (task)
  "Jump to an agent's eat buffer by TASK name, with completion."
  (interactive
   (list (completing-read "Agent: "
                          (when (file-directory-p agent-pad-state-dir)
                            (directory-files agent-pad-state-dir nil "^[^.]"))
                          nil t)))
  (let ((buf-name (format "*agent:%s*" task)))
    (if (get-buffer buf-name)
        (switch-to-buffer buf-name)
      (let ((wid (agent-pad--get-window-id task)))
        (if (and wid (not (string-empty-p wid)))
            (agent-pad--eat-attach buf-name wid task)
          (message "No window ID found for %s" task))))))

(provide 'agent-pad)
;;; agent-pad.el ends here
