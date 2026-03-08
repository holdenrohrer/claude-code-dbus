;;; claude-code-dbus.el --- Track Claude Code sessions via D-Bus -*- lexical-binding: t; -*-

;; Author: czar
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;; URL: https://github.com/holdenrohrer/claude-code-dbus

;;; Commentary:

;; Listens for D-Bus signals emitted by Claude Code hook scripts and
;; maintains a registry of active sessions.  Any Claude Code instance
;; on the machine (Emacs, terminal, VS Code, headless) that has the
;; claude-code-dbus plugin installed will broadcast lifecycle events.
;;
;; When used with claude-code-ide, sessions are correlated via an
;; environment variable so you can jump directly to the right buffer.
;;
;; Enable with `M-x claude-code-dbus-mode'.
;; View sessions with `M-x claude-code-dbus-list-sessions'.

;;; Code:

(require 'dbus)
(require 'notifications nil t)

(defgroup claude-code-dbus nil
  "Track Claude Code sessions via D-Bus."
  :group 'tools
  :prefix "claude-code-dbus-")

(defcustom claude-code-dbus-notify t
  "When non-nil, send desktop notifications for events needing attention."
  :type 'boolean)

(defcustom claude-code-dbus-notify-events '("PermissionRequest" "PostToolUse")
  "Hook events that trigger desktop notifications.
PostToolUse is included because the hook matcher filters to AskUserQuestion."
  :type '(repeat string))

(defcustom claude-code-dbus-event-functions nil
  "Hook run on every Claude Code D-Bus event.
Functions receive: EVENT SESSION-ID TOOL-NAME CWD IDE-SESSION-ID NOTIFICATION-TYPE."
  :type 'hook)

(defcustom claude-code-dbus-list-refresh-interval 5
  "Seconds between auto-refresh of the session list buffer."
  :type 'integer)

;;; Internal state

(defvar claude-code-dbus--sessions (make-hash-table :test 'equal)
  "Hash table mapping CLI session-id (UUID) to plist.
Plist keys: :status :cwd :tool-name :event :last-event-time
            :ide-session-id :notification-type")

(defvar claude-code-dbus--registration nil
  "D-Bus signal registration object.")

(defvar claude-code-dbus--refresh-timer nil
  "Timer for auto-refreshing the session list buffer.")

;;; claude-code-ide integration

(defun claude-code-dbus--inject-session-id-env (orig-fn buffer-name working-dir port continue resume session-id)
  "Advice for `claude-code-ide--create-terminal-session'.
Injects CLAUDE_CODE_IDE_SESSION_ID into the process environment
so hook scripts can correlate CLI sessions with Emacs sessions."
  (let ((process-environment
         (cons (format "CLAUDE_CODE_IDE_SESSION_ID=%s" session-id)
               process-environment)))
    (funcall orig-fn buffer-name working-dir port continue resume session-id)))

(defun claude-code-dbus--find-ide-buffer (ide-session-id)
  "Find the claude-code-ide buffer for IDE-SESSION-ID.
Returns the buffer or nil."
  (when (and ide-session-id
             (not (string-empty-p ide-session-id))
             (boundp 'claude-code-ide-mcp-server--sessions))
    (let ((session-info (gethash ide-session-id claude-code-ide-mcp-server--sessions)))
      (when session-info
        (plist-get session-info :buffer)))))

(defun claude-code-dbus--get-session-title (ide-session-id)
  "Get the conversation title for IDE-SESSION-ID from the eat terminal.
Returns the title string or nil."
  (when-let ((buffer (claude-code-dbus--find-ide-buffer ide-session-id)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (boundp 'eat-terminal) eat-terminal)
          (let ((title (eat-term-title eat-terminal)))
            (when (and title (not (string-empty-p title)))
              title)))))))

(defun claude-code-dbus--setup-ide-integration ()
  "Set up integration with claude-code-ide if available."
  (if (fboundp 'claude-code-ide--create-terminal-session)
      (advice-add 'claude-code-ide--create-terminal-session :around
                  #'claude-code-dbus--inject-session-id-env)
    (with-eval-after-load 'claude-code-ide
      (advice-add 'claude-code-ide--create-terminal-session :around
                  #'claude-code-dbus--inject-session-id-env))))

(defun claude-code-dbus--teardown-ide-integration ()
  "Remove claude-code-ide integration."
  (advice-remove 'claude-code-ide--create-terminal-session
                 #'claude-code-dbus--inject-session-id-env))

;;; D-Bus handler

(defun claude-code-dbus--status-for-event (event tool-name notification-type)
  "Determine session status from EVENT, TOOL-NAME, and NOTIFICATION-TYPE."
  (pcase event
    ("SessionStart" 'active)
    ("UserPromptSubmit" 'active)
    ("Stop" 'idle)
    ("SessionEnd" 'ended)
    ("PermissionRequest" 'blocked)
    ("PostToolUse"
     (if (string= tool-name "AskUserQuestion") 'blocked 'active))
    ("Notification"
     (pcase notification-type
       ("permission_prompt" 'blocked)
       ("elicitation_dialog" 'blocked)
       (_ 'idle)))
    (_ 'unknown)))

(defun claude-code-dbus--handle-event (event session-id tool-name cwd ide-session-id notification-type)
  "Handle a Claude Code D-Bus hook event.
EVENT is the hook_event_name, SESSION-ID is the CLI UUID,
TOOL-NAME is the tool involved (may be empty), CWD is the working directory,
IDE-SESSION-ID is the claude-code-ide session identifier (may be empty),
NOTIFICATION-TYPE is the notification subtype (may be empty)."
  (let ((status (claude-code-dbus--status-for-event event tool-name notification-type)))
    (if (eq status 'ended)
        (remhash session-id claude-code-dbus--sessions)
      (puthash session-id
               (list :status status
                     :cwd cwd
                     :tool-name tool-name
                     :event event
                     :last-event-time (current-time)
                     :ide-session-id ide-session-id
                     :notification-type notification-type)
               claude-code-dbus--sessions))
    ;; Desktop notification
    (when (and claude-code-dbus-notify
               (member event claude-code-dbus-notify-events))
      (claude-code-dbus--notify event session-id tool-name cwd))
    ;; User hook
    (run-hook-with-args 'claude-code-dbus-event-functions
                        event session-id tool-name cwd ide-session-id notification-type)
    ;; Refresh list buffer if visible
    (claude-code-dbus--maybe-refresh-list)))

(defun claude-code-dbus--notify (event session-id tool-name cwd)
  "Send a desktop notification for EVENT from SESSION-ID."
  (let ((project (file-name-nondirectory (directory-file-name cwd)))
        (short-id (substring session-id 0 (min 8 (length session-id)))))
    (if (fboundp 'notifications-notify)
        (notifications-notify
         :title (format "Claude [%s] %s" project event)
         :body (if (string-empty-p tool-name)
                   (format "Session %s needs attention" short-id)
                 (format "Session %s: %s" short-id tool-name))
         :urgency 'normal
         :timeout 5000)
      (message "Claude [%s] %s — %s" project event tool-name))))

;;; Session list UI

(defun claude-code-dbus--format-age (time)
  "Format TIME as a human-readable age string."
  (if time
      (let ((elapsed (float-time (time-subtract (current-time) time))))
        (cond
         ((< elapsed 60) (format "%ds" (truncate elapsed)))
         ((< elapsed 3600) (format "%dm" (truncate (/ elapsed 60))))
         (t (format "%dh" (truncate (/ elapsed 3600))))))
    "?"))

(defun claude-code-dbus--status-string (status)
  "Format STATUS as a display string."
  (pcase status
    ('active  "active")
    ('idle    "idle")
    ('blocked "BLOCKED")
    (_ "unknown")))

(defun claude-code-dbus--list-entries ()
  "Generate entries for `tabulated-list-mode'."
  (let (entries seen-ide-sessions)
    (maphash
     (lambda (session-id plist)
       (let ((ide-session-id (plist-get plist :ide-session-id)))
         ;; Only show Emacs sessions, deduplicate by ide-session-id
         (when (and ide-session-id
                    (not (string-empty-p ide-session-id))
                    (not (member ide-session-id seen-ide-sessions)))
           (push ide-session-id seen-ide-sessions)
           (let* ((status (plist-get plist :status))
                  (event-time (plist-get plist :last-event-time))
                  (buffer (claude-code-dbus--find-ide-buffer ide-session-id))
                  (title (claude-code-dbus--get-session-title ide-session-id))
                  (buf-name (when (and buffer (buffer-live-p buffer))
                              (buffer-name buffer)))
                  (display-name (or title buf-name ide-session-id)))
             (push (list session-id
                         (vector
                          (propertize (claude-code-dbus--status-string status)
                                      'face (pcase status
                                              ('blocked 'warning)
                                              ('active 'success)
                                              (_ 'shadow)))
                          display-name
                          (or buf-name "")
                          (claude-code-dbus--format-age event-time)))
                   entries)))))
     claude-code-dbus--sessions)
    (nreverse entries)))

(defun claude-code-dbus--maybe-refresh-list ()
  "Refresh the session list buffer if it exists and is visible."
  (when-let ((buf (get-buffer "*claude-sessions*")))
    (when (get-buffer-window buf t)
      (with-current-buffer buf
        (tabulated-list-revert)))))

(defun claude-code-dbus-jump-to-session ()
  "Jump to the claude-code-ide buffer for the session at point."
  (interactive)
  (let* ((session-id (tabulated-list-get-id))
         (plist (gethash session-id claude-code-dbus--sessions))
         (ide-session-id (plist-get plist :ide-session-id))
         (buffer (claude-code-dbus--find-ide-buffer ide-session-id)))
    (cond
     ((and buffer (buffer-live-p buffer))
      (let ((window (get-buffer-window buffer t)))
        (if window
            (progn
              (select-frame-set-input-focus (window-frame window))
              (select-window window))
          (when (fboundp 'claude-code-ide--display-buffer-in-side-window)
            (claude-code-ide--display-buffer-in-side-window buffer)))))
     (ide-session-id
      (message "Session %s: buffer no longer exists" ide-session-id))
     (t
      (message "No claude-code-ide session associated")))))

(defvar claude-code-dbus-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-code-dbus-jump-to-session)
    (define-key map (kbd "g") #'tabulated-list-revert)
    map)
  "Keymap for `claude-code-dbus-sessions-mode'.")

(with-eval-after-load 'evil
  (evil-define-key* 'normal claude-code-dbus-sessions-mode-map
    (kbd "RET") #'claude-code-dbus-jump-to-session)
  (evil-define-key* 'motion claude-code-dbus-sessions-mode-map
    (kbd "RET") #'claude-code-dbus-jump-to-session))

(define-derived-mode claude-code-dbus-sessions-mode tabulated-list-mode
  "Claude Sessions"
  "Major mode for viewing Claude Code session status.
\\{claude-code-dbus-sessions-mode-map}"
  (setq tabulated-list-format
        [("Status" 10 t)
         ("Title" 35 t)
         ("Buffer" 25 t)
         ("Age" 6 t)])
  (setq tabulated-list-entries #'claude-code-dbus--list-entries)
  (setq tabulated-list-sort-key '("Status" . nil))
  (tabulated-list-init-header)
  (hl-line-mode 1))

;;;###autoload
(defun claude-code-dbus-list-sessions ()
  "Display a buffer listing all tracked Claude Code sessions."
  (interactive)
  (let ((buf (get-buffer-create "*claude-sessions*")))
    (with-current-buffer buf
      (claude-code-dbus-sessions-mode)
      (tabulated-list-revert))
    (pop-to-buffer buf)))

;;; Global minor mode

;;;###autoload
(define-minor-mode claude-code-dbus-mode
  "Listen for Claude Code lifecycle events via D-Bus."
  :global t
  :lighter " CC-DBus"
  (if claude-code-dbus-mode
      (progn
        (setq claude-code-dbus--registration
              (dbus-register-signal
               :session nil
               "/com/claude/code"
               "com.claude.Code"
               "HookEvent"
               #'claude-code-dbus--handle-event))
        (setq claude-code-dbus--refresh-timer
              (run-with-timer claude-code-dbus-list-refresh-interval
                             claude-code-dbus-list-refresh-interval
                             #'claude-code-dbus--maybe-refresh-list))
        (claude-code-dbus--setup-ide-integration)
        (message "Claude Code D-Bus listener active"))
    (when claude-code-dbus--registration
      (dbus-unregister-object claude-code-dbus--registration)
      (setq claude-code-dbus--registration nil))
    (when claude-code-dbus--refresh-timer
      (cancel-timer claude-code-dbus--refresh-timer)
      (setq claude-code-dbus--refresh-timer nil))
    (claude-code-dbus--teardown-ide-integration)
    (message "Claude Code D-Bus listener stopped")))

(provide 'claude-code-dbus)
;;; claude-code-dbus.el ends here
