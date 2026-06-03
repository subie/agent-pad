;;; agent-pad-test.el --- Tests for agent-pad -*- lexical-binding: t -*-

;;; Commentary:

;; ERT tests for agent-pad.  Run with:
;;
;;   emacs -Q --batch -l tests/agent-pad-test.el -f ert-run-tests-batch-and-exit
;;
;; or via tests/run-tests.sh.  `eat' is stubbed so the package loads in
;; batch without the dependency; `transient' ships with Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Stub `eat' so agent-pad loads without the real dependency.
(unless (featurep 'eat)
  (provide 'eat)
  (defmacro eat-exec (&rest _) nil))

(require 'transient)

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load-file (expand-file-name "../agent-pad.el" dir)))

;;;; agent-pad--slugify

(ert-deftest agent-pad-test-slugify-basic ()
  (should (equal (agent-pad--slugify "Refactor the auth module!")
                 "refactor-the-auth-module")))

(ert-deftest agent-pad-test-slugify-trims-edges ()
  (should (equal (agent-pad--slugify "  Hello, World  ") "hello-world"))
  (should (equal (agent-pad--slugify "!!!leading and trailing!!!")
                 "leading-and-trailing")))

(ert-deftest agent-pad-test-slugify-empty ()
  (should (equal (agent-pad--slugify "") ""))
  (should (equal (agent-pad--slugify "   ") ""))
  (should (equal (agent-pad--slugify "***") "")))

(ert-deftest agent-pad-test-slugify-truncates-to-40 ()
  (let ((slug (agent-pad--slugify (make-string 100 ?a))))
    (should (= (length slug) 40))))

;;;; agent-pad--build-copilot-command

(ert-deftest agent-pad-test-build-command-interactive-default ()
  (let ((agent-pad-copilot-program "copilot"))
    (should (equal
             (agent-pad--build-copilot-command '() "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\""))))

(ert-deftest agent-pad-test-build-command-non-interactive ()
  (let ((agent-pad-copilot-program "copilot"))
    (should (equal
             (agent-pad--build-copilot-command '("--non-interactive") "/tmp/p")
             "copilot -p \"$(cat /tmp/p)\""))))

(ert-deftest agent-pad-test-build-command-all-flags ()
  (let ((agent-pad-copilot-program "copilot"))
    (should (equal
             (agent-pad--build-copilot-command
              '("-C=/src/proj" "--autopilot" "--allow-all-tools" "--effort=high")
              "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\" -C /src/proj --autopilot --allow-all-tools --effort high"))))

(ert-deftest agent-pad-test-build-command-allow-all-supersedes-tools ()
  ;; --allow-all subsumes --allow-all-tools; only --allow-all is emitted.
  (let ((agent-pad-copilot-program "copilot"))
    (should (equal
             (agent-pad--build-copilot-command
              '("--autopilot" "--allow-all" "--allow-all-tools") "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\" --autopilot --allow-all"))))

(ert-deftest agent-pad-test-build-command-plan-mode ()
  (let ((agent-pad-copilot-program "copilot"))
    (should (equal
             (agent-pad--build-copilot-command '("--plan") "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\" --plan"))))

(ert-deftest agent-pad-test-build-command-autopilot-and-plan-mutually-exclusive ()
  "copilot crashes if both --autopilot and --plan are passed; never emit both."
  (let ((agent-pad-copilot-program "copilot"))
    ;; autopilot wins; --plan is dropped regardless of arg order.
    (should (equal
             (agent-pad--build-copilot-command '("--autopilot" "--plan") "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\" --autopilot"))
    (should (equal
             (agent-pad--build-copilot-command '("--plan" "--autopilot") "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\" --autopilot"))))

(ert-deftest agent-pad-test-dispatch-prefix-marks-modes-incompatible ()
  "The transient must mark --autopilot and --plan as mutually exclusive."
  (let ((proto (get 'agent-pad-dispatch 'transient--prefix)))
    (should proto)
    (should (member '("--autopilot" "--plan")
                    (oref proto incompatible)))))

(ert-deftest agent-pad-test-dispatch-prompts-for-task-when-missing ()
  "With no --task=, dispatch prompts for a name (prefilled with a slug)."
  (let ((agent-pad--prompt "Do the thing")
        (agent-pad-copilot-program "copilot")
        captured)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional initial &rest _)
                 (should (equal initial "do-the-thing"))
                 "my-name"))
              ((symbol-function 'agent-pad--write-prompt-file)
               (lambda (_p) "/tmp/p"))
              ((symbol-function 'agent-pad--run-agent)
               (lambda (task &rest _) (setq captured task))))
      (agent-pad-dispatch-copilot '())
      (should (equal captured "my-name")))))

(ert-deftest agent-pad-test-dispatch-uses-task-arg-without-prompting ()
  "With --task= supplied, dispatch uses it verbatim and never prompts."
  (let ((agent-pad--prompt "Do the thing")
        (agent-pad-copilot-program "copilot")
        captured)
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (error "should not prompt for a task name")))
              ((symbol-function 'agent-pad--write-prompt-file)
               (lambda (_p) "/tmp/p"))
              ((symbol-function 'agent-pad--run-agent)
               (lambda (task &rest _) (setq captured task))))
      (agent-pad-dispatch-copilot '("--task=explicit-name"))
      (should (equal captured "explicit-name")))))

(ert-deftest agent-pad-test-dispatch-empty-task-name-errors ()
  "An empty entered task name is rejected rather than dispatched."
  (let ((agent-pad--prompt "Do the thing")
        (agent-pad-copilot-program "copilot")
        (ran nil))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "   "))
              ((symbol-function 'agent-pad--write-prompt-file)
               (lambda (_p) "/tmp/p"))
              ((symbol-function 'agent-pad--run-agent)
               (lambda (&rest _) (setq ran t))))
      (should-error (agent-pad-dispatch-copilot '()) :type 'user-error)
      (should-not ran))))

(ert-deftest agent-pad-test-build-command-no-ask-user ()
  (let ((agent-pad-copilot-program "copilot"))
    (should (equal
             (agent-pad--build-copilot-command
              '("--autopilot" "--allow-all" "--no-ask-user") "/tmp/p")
             "copilot -i \"$(cat /tmp/p)\" --autopilot --allow-all --no-ask-user"))))

(ert-deftest agent-pad-test-build-command-respects-program-custom ()
  (let ((agent-pad-copilot-program "/opt/bin/copilot"))
    (should (string-prefix-p "/opt/bin/copilot -i "
                             (agent-pad--build-copilot-command '() "/tmp/p")))))

(ert-deftest agent-pad-test-build-command-quotes-dir-with-spaces ()
  (let ((agent-pad-copilot-program "copilot"))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "/my src/proj"))
             (agent-pad--build-copilot-command '("-C=/my src/proj") "/tmp/p")))))

;;;; agent-pad--write-prompt-file

(ert-deftest agent-pad-test-write-prompt-file-roundtrips ()
  (let* ((text "Line one\nLine two with $pecial & chars")
         (file (agent-pad--write-prompt-file text)))
    (unwind-protect
        (progn
          (should (file-readable-p file))
          (should (equal text
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))))
      (delete-file file))))

;;;; agent-pad--prompt-summary

(ert-deftest agent-pad-test-prompt-summary-empty ()
  (let ((agent-pad--prompt ""))
    (should (equal (substring-no-properties (agent-pad--prompt-summary))
                   "not set")))
  (let ((agent-pad--prompt "   \n  "))
    (should (equal (substring-no-properties (agent-pad--prompt-summary))
                   "not set"))))

(ert-deftest agent-pad-test-prompt-summary-multiline ()
  (let ((agent-pad--prompt "first line\nsecond\nthird"))
    (let ((s (substring-no-properties (agent-pad--prompt-summary))))
      (should (string-prefix-p "3 lines:" s))
      (should (string-match-p "first line" s)))))

(ert-deftest agent-pad-test-prompt-summary-truncates-long-first-line ()
  (let ((agent-pad--prompt (make-string 100 ?x)))
    (let ((s (substring-no-properties (agent-pad--prompt-summary))))
      (should (string-match-p "…" s)))))

;;;; agent-pad--read-state-file

(ert-deftest agent-pad-test-read-state-file-full ()
  (let ((file (make-temp-file "agent-state-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "running|my-task|1700000000|some note|@5"))
          (should (equal (agent-pad--read-state-file file)
                         '("my-task" "running" 1700000000 "some note" "@5"))))
      (delete-file file))))

(ert-deftest agent-pad-test-read-state-file-minimal-fields ()
  (let ((file (make-temp-file "agent-state-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "waiting|task2|1700000001"))
          (should (equal (agent-pad--read-state-file file)
                         '("task2" "waiting" 1700000001 "" ""))))
      (delete-file file))))

(ert-deftest agent-pad-test-read-state-file-missing ()
  (should (null (agent-pad--read-state-file "/nonexistent/agent/state/file"))))

;;;; agent-pad--activity-age (content-hash based status detection)

(defmacro agent-pad-test--with-clock (start &rest body)
  "Run BODY with `float-time' returning the mutable variable CLOCK init to START."
  (declare (indent 1))
  `(let ((clock ,start))
     (cl-letf (((symbol-function 'float-time) (lambda (&rest _) clock)))
       ,@body)))

(ert-deftest agent-pad-test-activity-age-first-sight-no-baseline ()
  (clrhash agent-pad--activity-cache)
  (cl-letf (((symbol-function 'agent-pad--pane-content-hash)
             (lambda (_wid) "HASH-A")))
    (agent-pad-test--with-clock 1000.0
      (should (= (agent-pad--activity-age "@1") 0.0)))))

(ert-deftest agent-pad-test-activity-age-first-sight-with-baseline ()
  (clrhash agent-pad--activity-cache)
  (cl-letf (((symbol-function 'agent-pad--pane-content-hash)
             (lambda (_wid) "HASH-A")))
    (agent-pad-test--with-clock 1000.0
      ;; baseline 940 -> agent has been idle 60s already
      (should (= (agent-pad--activity-age "@1" 940) 60.0)))))

(ert-deftest agent-pad-test-activity-age-unchanged-content-ages ()
  (clrhash agent-pad--activity-cache)
  (let ((now 1000.0))
    (cl-letf (((symbol-function 'agent-pad--pane-content-hash)
               (lambda (_wid) "SAME"))
              ((symbol-function 'float-time) (lambda (&rest _) now)))
      ;; First poll seeds last-change = 1000
      (should (= (agent-pad--activity-age "@1") 0.0))
      ;; 45s later, content unchanged -> age grows
      (setq now 1045.0)
      (should (= (agent-pad--activity-age "@1") 45.0)))))

(ert-deftest agent-pad-test-activity-age-changed-content-resets ()
  (clrhash agent-pad--activity-cache)
  (let ((now 1000.0)
        (content "A"))
    (cl-letf (((symbol-function 'agent-pad--pane-content-hash)
               (lambda (_wid) content))
              ((symbol-function 'float-time) (lambda (&rest _) now)))
      (should (= (agent-pad--activity-age "@1") 0.0))
      (setq now 1045.0)
      (setq content "B")                ; new output
      (should (= (agent-pad--activity-age "@1") 0.0)))))

(ert-deftest agent-pad-test-activity-age-nil-when-no-window ()
  (clrhash agent-pad--activity-cache)
  (cl-letf (((symbol-function 'agent-pad--pane-content-hash)
             (lambda (_wid) nil)))
    (should (null (agent-pad--activity-age "@gone")))))

;;;; agent-pad--derive-status

(ert-deftest agent-pad-test-derive-status-passthrough-terminal ()
  (should (equal (agent-pad--derive-status "@1" "done") "done"))
  (should (equal (agent-pad--derive-status "@1" "blocked") "blocked")))

(ert-deftest agent-pad-test-derive-status-running-vs-waiting ()
  (let ((agent-pad-silence-seconds 30))
    (cl-letf (((symbol-function 'agent-pad--activity-age)
               (lambda (&rest _) 5.0)))
      (should (equal (agent-pad--derive-status "@1" "running") "running")))
    (cl-letf (((symbol-function 'agent-pad--activity-age)
               (lambda (&rest _) 90.0)))
      (should (equal (agent-pad--derive-status "@1" "running") "waiting")))))

(ert-deftest agent-pad-test-derive-status-no-window-keeps-current ()
  (cl-letf (((symbol-function 'agent-pad--activity-age)
             (lambda (&rest _) nil)))
    (should (equal (agent-pad--derive-status "@gone" "running") "running"))))

;;;; agent-pad--tmux-switch

(ert-deftest agent-pad-test-tmux-switch-builds-command ()
  (let ((agent-pad-session "agents")
        (captured nil))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (cmd) (setq captured cmd) "")))
      (agent-pad--tmux-switch "@7")
      (should (string-match-p "tmux switch-client -t agents" captured))
      (should (string-match-p
               (concat "select-window -t "
                       (regexp-quote (shell-quote-argument "@7")))
               captured)))))

(ert-deftest agent-pad-test-tmux-attach-cmd-slugifies-session-name ()
  "Session name must be slugified so spaces/specials never reach tmux -s."
  (let* ((agent-pad-session "agents")
         (cmd (agent-pad--tmux-attach-cmd "@21" "diagnostics for slow evals")))
    ;; Grouped onto the agents session and targets the right window.
    (should (string-match-p "new-session -t agents" cmd))
    (should (string-match-p
             (concat "select-window -t " (regexp-quote (shell-quote-argument "@21")))
             cmd))
    ;; The -s argument is a clean kebab slug: no spaces, no shell quoting needed.
    (should (string-match-p
             (format "-s eat-diagnostics-for-slow-evals-%s " (emacs-pid))
             cmd))
    ;; And crucially the raw spaced task name does not appear in the session arg.
    (should-not (string-match-p "eat-diagnostics for slow evals" cmd))))

(provide 'agent-pad-test)
;;; agent-pad-test.el ends here
