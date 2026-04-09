;;; ehostctl.el --- Manage /etc/hosts with hostctl -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;; Keywords: tools, convenience
;; URL: https://github.com/user/ehostctl

;;; Commentary:

;; Emacs frontend for hostctl (https://github.com/guumaster/hostctl).
;; Provides two-layer tabulated-list views with transient menus
;; for managing /etc/hosts profiles and host entries.
;;
;; Usage: M-x ehostctl

;;; Code:

(require 'json)
(require 'transient)

;;;; Custom Variables

(defgroup ehostctl nil
  "Manage /etc/hosts via hostctl."
  :group 'tools
  :prefix "ehostctl-")

(defcustom ehostctl-hostctl-executable "hostctl"
  "Path to the hostctl executable."
  :type 'string
  :group 'ehostctl)

(defcustom ehostctl-use-sudo t
  "Whether to use sudo for write operations."
  :type 'boolean
  :group 'ehostctl)

(defcustom ehostctl-sudo-executable "sudo"
  "Path to the sudo executable."
  :type 'string
  :group 'ehostctl)

;;;; CLI Interaction Layer

(defun ehostctl--run (&rest args)
  "Run hostctl with ARGS synchronously, return (EXIT-CODE . OUTPUT)."
  (with-temp-buffer
    (let ((exit-code (apply #'call-process ehostctl-hostctl-executable
                            nil (current-buffer) nil args)))
      (cons exit-code (buffer-string)))))

(defun ehostctl--run-sudo (&rest args)
  "Run hostctl with ARGS via sudo, return (EXIT-CODE . OUTPUT)."
  (if ehostctl-use-sudo
      (with-temp-buffer
        (let ((exit-code (apply #'call-process ehostctl-sudo-executable
                                nil (current-buffer) nil
                                ehostctl-hostctl-executable args)))
          (cons exit-code (buffer-string))))
    (apply #'ehostctl--run args)))

(defun ehostctl--run-sudo! (&rest args)
  "Run hostctl with ARGS via sudo.  Signal error on failure."
  (let ((result (apply #'ehostctl--run-sudo args)))
    (unless (zerop (car result))
      (user-error "hostctl failed: %s" (string-trim (cdr result))))
    (cdr result)))

(defun ehostctl--parse-json (json-string)
  "Parse JSON-STRING from hostctl output into a list of alists."
  (let ((trimmed (string-trim json-string)))
    (if (or (string-empty-p trimmed) (string= trimmed "null"))
        nil
      (json-read-from-string trimmed))))

;;;; Data Model

(defun ehostctl--get-profiles ()
  "Return list of (NAME STATUS ENTRY-COUNT) for all profiles."
  (let* ((result (ehostctl--run "list" "-o" "json"))
         (entries (ehostctl--parse-json (cdr result)))
         (table (make-hash-table :test #'equal)))
    (when entries
      (seq-doseq (entry entries)
        (let* ((name (alist-get 'Profile entry))
               (status (alist-get 'Status entry))
               (existing (gethash name table)))
          (if existing
              (puthash name (list name status (1+ (nth 2 existing))) table)
            (puthash name (list name status 1) table)))))
    (hash-table-values table)))

(defun ehostctl--get-hosts (profile)
  "Return list of (IP HOST STATUS) for PROFILE."
  (let* ((result (ehostctl--run "list" "-o" "json"))
         (entries (ehostctl--parse-json (cdr result))))
    (when entries
      (seq-keep
       (lambda (entry)
         (when (string= (alist-get 'Profile entry) profile)
           (list (alist-get 'IP entry)
                 (alist-get 'Host entry)
                 (alist-get 'Status entry))))
       entries))))

;;;; Profile List Mode (First Layer)

(defun ehostctl--profile-entries ()
  "Build `tabulated-list-entries' for profile list."
  (mapcar (lambda (p)
            (let ((name (nth 0 p))
                  (status (nth 1 p))
                  (count (nth 2 p)))
              (list name (vector name status (number-to-string count)))))
          (ehostctl--get-profiles)))

(defvar-keymap ehostctl-profile-list-mode-map
  :doc "Keymap for `ehostctl-profile-list-mode'."
  "RET" #'ehostctl-profile-enter
  "e"   #'ehostctl-profile-enable
  "d"   #'ehostctl-profile-disable
  "t"   #'ehostctl-profile-toggle
  "D"   #'ehostctl-profile-remove
  "a"   #'ehostctl-profile-add
  "b"   #'ehostctl-backup
  "R"   #'ehostctl-restore
  "?"   #'ehostctl-transient)

(define-derived-mode ehostctl-profile-list-mode tabulated-list-mode "Profiles"
  "Major mode for listing hostctl profiles."
  (setq tabulated-list-format [("Profile" 20 t)
                                ("Status" 8 t)
                                ("Entries" 8 t)]
        tabulated-list-padding 2)
  (tabulated-list-init-header)
  (add-hook 'tabulated-list-revert-hook #'ehostctl--profile-refresh nil t))

(defun ehostctl--profile-refresh ()
  "Refresh profile list entries."
  (setq tabulated-list-entries (ehostctl--profile-entries)))

(defun ehostctl--profile-at-point ()
  "Return the profile name at point."
  (or (tabulated-list-get-id)
      (user-error "No profile at point")))

(defun ehostctl-profile-enter ()
  "Enter the profile at point, showing its host entries."
  (interactive)
  (ehostctl-hosts (ehostctl--profile-at-point)))

(defun ehostctl-profile-enable ()
  "Enable the profile at point."
  (interactive)
  (let ((profile (ehostctl--profile-at-point)))
    (ehostctl--run-sudo! "enable" profile)
    (message "Enabled profile: %s" profile)
    (revert-buffer)))

(defun ehostctl-profile-disable ()
  "Disable the profile at point."
  (interactive)
  (let ((profile (ehostctl--profile-at-point)))
    (ehostctl--run-sudo! "disable" profile)
    (message "Disabled profile: %s" profile)
    (revert-buffer)))

(defun ehostctl-profile-toggle ()
  "Toggle the profile at point."
  (interactive)
  (let ((profile (ehostctl--profile-at-point)))
    (ehostctl--run-sudo! "toggle" profile)
    (message "Toggled profile: %s" profile)
    (revert-buffer)))

(defun ehostctl-profile-remove ()
  "Remove the profile at point."
  (interactive)
  (let ((profile (ehostctl--profile-at-point)))
    (when (yes-or-no-p (format "Remove profile '%s'? This cannot be undone. " profile))
      (ehostctl--run-sudo! "remove" profile)
      (message "Removed profile: %s" profile)
      (revert-buffer))))

(defun ehostctl-profile-add ()
  "Add a new host entry to a profile."
  (interactive)
  (let* ((profile (read-string "Profile name: "))
         (ip (read-string "IP address: " "127.0.0.1"))
         (domains (read-string "Domains (space separated): ")))
    (apply #'ehostctl--run-sudo!
           "add" "domains" profile
           "--ip" ip
           (split-string domains))
    (message "Added to profile: %s" profile)
    (revert-buffer)))

(defun ehostctl-backup ()
  "Backup the hosts file."
  (interactive)
  (let ((path (read-directory-name "Backup directory: " "~/")))
    (ehostctl--run-sudo! "backup" "--path" (expand-file-name path))
    (message "Hosts file backed up to: %s" path)))

(defun ehostctl-restore ()
  "Restore hosts file from a backup."
  (interactive)
  (let ((file (read-file-name "Restore from: " "~/")))
    (when (yes-or-no-p "Restore will OVERWRITE current hosts file. Continue? ")
      (ehostctl--run-sudo! "restore" "--from" (expand-file-name file))
      (message "Hosts file restored from: %s" file)
      (revert-buffer))))

(provide 'ehostctl)
;;; ehostctl.el ends here
