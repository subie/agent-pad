;;; agent-pad.el --- Manage coding agents in tmux from Emacs -*- lexical-binding: t -*-

;; Author: Subie Patel
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (eat "0.9") (transient "0.4"))
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
(require 'transient)

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

(defcustom agent-pad-copilot-program "copilot"
  "Program name used to launch the Copilot CLI."
  :type 'string)

(defcustom agent-pad-default-directory nil
  "Default source directory for the Copilot \"-C\" option.
If nil, the directory is read interactively starting from
`default-directory'."
  :type '(choice (const :tag "Ask each time" nil) directory))

(defcustom agent-pad-attach-on-dispatch t
  "When non-nil, dispatching via the transient opens an eat buffer.
The eat buffer is attached to the new agent's tmux window so you can
do interactive setup before letting it run on its own.  Set to nil to
dispatch without attaching."
  :type 'boolean)

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
from the main tmux client.  The session name is slugified so task
names containing spaces or special characters do not leak into the
tmux session name."
  (let ((eat-session (format "eat-%s-%s" (agent-pad--slugify task) (emacs-pid))))
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
    (define-key map (kbd "+")   #'agent-pad-dispatch)
    (define-key map (kbd "g")   #'agent-pad-refresh)
    (define-key map (kbd "d")   #'agent-pad-mark-done)
    (define-key map (kbd "k")   #'agent-pad-kill)
    map)
  "Keymap for `agent-pad-mode'.")

(define-derived-mode agent-pad-mode tabulated-list-mode "AgentQueue"
  "Major mode for managing coding agents."
  (setq tabulated-list-format
        [("Status" 10 agent-pad--sort-by-attention)
         ("Task" 48 t)
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
  (agent-pad--run-agent task cmd current-prefix-arg))

(defun agent-pad--run-agent (task cmd &optional attach)
  "Run CMD as agent TASK via agent-start.
When ATTACH is non-nil, open an eat buffer on the agent's window."
  (let ((result (shell-command-to-string
                 (format "agent-start %s %s 2>&1"
                         (shell-quote-argument task)
                         (shell-quote-argument cmd)))))
    (message "%s" (string-trim result))
    ;; Refresh queue if it's open
    (agent-pad-refresh)
    ;; Optionally attach to the agent
    (when attach
      ;; Small delay to let tmux create the window and state file
      (run-at-time 0.5 nil
                   (lambda ()
                     (let* ((buf-name (format "*agent:%s*" task))
                            (wid (agent-pad--get-window-id task)))
                       (if (and wid (not (string-empty-p wid)))
                           (agent-pad--eat-attach buf-name wid task)
                         (message "Could not find window for %s" task))))))))

;;;; Transient dispatch menu

(defvar agent-pad--prompt ""
  "Current composed prompt for the Copilot dispatch transient.")

(defconst agent-pad--prompt-buffer-name "*agent-pad prompt*"
  "Name of the buffer used to compose a Copilot prompt.")

(defvar agent-pad-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-pad-prompt-commit)
    (define-key map (kbd "C-c C-k") #'agent-pad-prompt-abort)
    map)
  "Keymap for `agent-pad-prompt-mode'.")

(define-minor-mode agent-pad-prompt-mode
  "Minor mode for composing a Copilot prompt.
\\<agent-pad-prompt-mode-map>
\\[agent-pad-prompt-commit] stores the prompt and returns to the dispatch menu.
\\[agent-pad-prompt-abort] aborts without changing the prompt."
  :lighter " AgentPrompt"
  :keymap agent-pad-prompt-mode-map)

(defun agent-pad-edit-prompt ()
  "Open a dedicated buffer to compose the Copilot prompt.
Invoked from the dispatch transient, which is suspended while
editing and resumed (with its options intact) on commit/abort."
  (interactive)
  (let ((buf (get-buffer-create agent-pad--prompt-buffer-name)))
    (with-current-buffer buf
      (erase-buffer)
      (insert agent-pad--prompt)
      (goto-char (point-min))
      (agent-pad-prompt-mode 1)
      (setq header-line-format
            "Compose prompt — C-c C-c to save, C-c C-k to cancel"))
    (pop-to-buffer buf)))

(defun agent-pad-prompt-commit ()
  "Store the composed prompt and resume the dispatch menu."
  (interactive)
  (setq agent-pad--prompt (buffer-string))
  (let ((n (length agent-pad--prompt)))
    (quit-window t)
    (message "Prompt stored (%d chars)." n))
  (transient-resume))

(defun agent-pad-prompt-abort ()
  "Abort prompt composition and resume the dispatch menu."
  (interactive)
  (quit-window t)
  (message "Prompt edit aborted.")
  (transient-resume))

(defun agent-pad--prompt-summary ()
  "Return a short one-line summary of the current prompt for display."
  (if (string-empty-p (string-trim agent-pad--prompt))
      (propertize "not set" 'face 'transient-inactive-value)
    (let* ((lines (split-string agent-pad--prompt "\n" t))
           (first (string-trim (or (car lines) "")))
           (preview (if (> (length first) 40)
                        (concat (substring first 0 40) "…")
                      first)))
      (propertize (format "%d line%s: \"%s\""
                          (length lines)
                          (if (= (length lines) 1) "" "s")
                          preview)
                  'face 'transient-value))))

(defun agent-pad--slugify (string)
  "Turn STRING into a kebab-case identifier."
  (let* ((s (downcase (string-trim string)))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (replace-regexp-in-string "^-+\\|-+$" "" s)))
    (if (> (length s) 40) (substring s 0 40) s)))

(defun agent-pad--write-prompt-file (prompt)
  "Write PROMPT to a temp file and return its absolute path."
  (let ((file (make-temp-file "agent-prompt-")))
    (with-temp-file file
      (insert prompt))
    file))

;;;; Transient infixes

(transient-define-infix agent-pad--infix-dir ()
  "Source directory passed to copilot via -C."
  :class 'transient-option
  :key "-C"
  :description "Source dir"
  :argument "-C="
  :reader (lambda (_prompt _init _hist)
            (expand-file-name
             (read-directory-name "Source dir: "
                                  (or agent-pad-default-directory
                                      default-directory)))))

(transient-define-infix agent-pad--infix-task ()
  "Task name (window name); auto-derived from the prompt if blank."
  :class 'transient-option
  :key "-n"
  :description "Task name"
  :argument "--task="
  :reader (lambda (_prompt _init _hist)
            (read-string "Task name: ")))

(transient-define-infix agent-pad--infix-effort ()
  "Reasoning effort for copilot."
  :class 'transient-option
  :key "-E"
  :description "--effort"
  :argument "--effort="
  :choices '("low" "medium" "high"))

;;;; Command builder and dispatch suffixes

(defun agent-pad--build-copilot-command (args promptfile)
  "Build a copilot command string from transient ARGS and PROMPTFILE."
  (let* ((dir (transient-arg-value "-C=" args))
         (effort (transient-arg-value "--effort=" args))
         (non-interactive (member "--non-interactive" args))
         (mode-flag (if non-interactive "-p" "-i"))
         (parts (list agent-pad-copilot-program
                      mode-flag
                      (format "\"$(cat %s)\""
                              (shell-quote-argument promptfile)))))
    (when (and dir (not (string-empty-p dir)))
      (setq parts (append parts (list "-C" (shell-quote-argument dir)))))
    (when (member "--autopilot" args)
      (setq parts (append parts (list "--autopilot"))))
    ;; --autopilot and --plan are mutually exclusive modes; copilot errors
    ;; out if both are passed.  The transient marks them :incompatible, but
    ;; guard here too so programmatic callers can never emit both.
    (when (and (member "--plan" args)
               (not (member "--autopilot" args)))
      (setq parts (append parts (list "--plan"))))
    (cond
     ((member "--allow-all" args)
      (setq parts (append parts (list "--allow-all"))))
     ((member "--allow-all-tools" args)
      (setq parts (append parts (list "--allow-all-tools")))))
    (when (member "--no-ask-user" args)
      (setq parts (append parts (list "--no-ask-user"))))
    (when (and effort (not (string-empty-p effort)))
      (setq parts (append parts (list "--effort" effort))))
    (string-join parts " ")))

(defun agent-pad-dispatch-copilot (&optional args)
  "Dispatch a Copilot agent from the transient ARGS and composed prompt."
  (interactive (list (transient-args 'agent-pad-dispatch)))
  (when (string-empty-p (string-trim agent-pad--prompt))
    (user-error "No prompt set — press \"e\" to compose one"))
  (let* ((task-arg (transient-arg-value "--task=" args))
         (task (if (and task-arg (not (string-empty-p task-arg)))
                   task-arg
                 (let ((slug (agent-pad--slugify
                              (car (split-string agent-pad--prompt "\n" t)))))
                   (if (string-empty-p slug) "copilot" slug))))
         (promptfile (agent-pad--write-prompt-file agent-pad--prompt))
         (cmd (agent-pad--build-copilot-command args promptfile)))
    (agent-pad--run-agent task cmd agent-pad-attach-on-dispatch)))

(defun agent-pad-dispatch-raw (task cmd)
  "Dispatch an arbitrary command CMD as agent TASK."
  (interactive "sTask name: \nsCommand: ")
  (agent-pad--run-agent task cmd agent-pad-attach-on-dispatch))

;;;###autoload (autoload 'agent-pad-dispatch "agent-pad" nil t)
(transient-define-prefix agent-pad-dispatch ()
  "Dispatch a coding agent into a tmux window."
  :incompatible '(("--autopilot" "--plan"))
  [:description
   (lambda () (format "Agent dispatch    prompt: %s" (agent-pad--prompt-summary)))
   ["Copilot options"
    ("e" "Edit prompt" agent-pad-edit-prompt
     :transient transient--do-suspend)
    (agent-pad--infix-dir)
    ("-a" "--autopilot" "--autopilot")
    ("-l" "--plan (plan mode)" "--plan")
    ("-A" "--allow-all-tools" "--allow-all-tools")
    ("-Y" "--allow-all (yolo: tools+paths+urls)" "--allow-all")
    ("-Q" "--no-ask-user (never prompt the user)" "--no-ask-user")
    ("-p" "Non-interactive (-p, default -i)" "--non-interactive")
    (agent-pad--infix-effort)
    (agent-pad--infix-task)]]
  ["Dispatch"
   ("c" "Copilot agent" agent-pad-dispatch-copilot)
   ("r" "Raw command…" agent-pad-dispatch-raw)
   ("q" "Quit" transient-quit-one)])

;;;; Jump by name

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
