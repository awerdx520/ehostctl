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

;;;; Faces

(defface ehostctl-stripe-face
  '((((class color) (background light))
     :background "#e8ecf1" :extend t)
    (((class color) (background dark))
     :background "#232830" :extend t))
  "Face for alternating row stripes."
  :group 'ehostctl)

(defface ehostctl-header-face
  '((((class color) (background light))
     :background "#d0d5dd" :foreground "#1a1a2e"
     :weight bold :extend t)
    (((class color) (background dark))
     :background "#3a3f4b" :foreground "#e0e0e0"
     :weight bold :extend t))
  "Face for table header line."
  :group 'ehostctl)

(defface ehostctl-status-on-face
  '((((class color) (background light))
     :foreground "#2e7d32" :weight bold)
    (((class color) (background dark))
     :foreground "#66bb6a" :weight bold))
  "Face for enabled (on) status."
  :group 'ehostctl)

(defface ehostctl-status-off-face
  '((((class color) (background light))
     :foreground "#c62828" :weight bold)
    (((class color) (background dark))
     :foreground "#ef5350" :weight bold))
  "Face for disabled (off) status."
  :group 'ehostctl)

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

(defcustom ehostctl-notes-file
  (locate-user-emacs-file "ehostctl-notes.eld")
  "File to persist host annotations."
  :type 'file
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
      (user-error "Hostctl failed: %s" (string-trim (cdr result))))
    (cdr result)))

(defun ehostctl--parse-json (json-string)
  "Parse JSON-STRING from hostctl output into a list of alists."
  (let ((trimmed (string-trim json-string)))
    (if (or (string-empty-p trimmed) (string= trimmed "null"))
        nil
      (json-read-from-string trimmed))))

;;;; Stripe Overlay

(defun ehostctl--apply-stripes ()
  "Apply alternating row background colors to the current buffer."
  (remove-overlays (point-min) (point-max) 'ehostctl-stripe t)
  (save-excursion
    (goto-char (point-min))
    (let ((row 0))
      (while (not (eobp))
        (when (cl-oddp row)
          (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
            (overlay-put ov 'face 'ehostctl-stripe-face)
            (overlay-put ov 'ehostctl-stripe t)))
        (setq row (1+ row))
        (forward-line 1)))))

;;;; Status Propertize

(defun ehostctl--propertize-status (status)
  "Return STATUS string with face applied."
  (propertize status 'face
              (if (string= status "on")
                  'ehostctl-status-on-face
                'ehostctl-status-off-face)))

;;;; Notes Storage

(defvar ehostctl--notes nil
  "Hash table mapping \"PROFILE:HOST\" to note strings.")

(defun ehostctl--notes-key (profile host)
  "Return storage key for PROFILE and HOST."
  (concat profile ":" host))

(defun ehostctl--notes-load ()
  "Load notes from `ehostctl-notes-file'."
  (setq ehostctl--notes (make-hash-table :test #'equal))
  (when (file-exists-p ehostctl-notes-file)
    (let ((alist (with-temp-buffer
                   (insert-file-contents ehostctl-notes-file)
                   (read (current-buffer)))))
      (dolist (pair alist)
        (puthash (car pair) (cdr pair) ehostctl--notes)))))

(defun ehostctl--notes-save ()
  "Save notes to `ehostctl-notes-file'."
  (let ((alist nil))
    (maphash (lambda (k v) (push (cons k v) alist)) ehostctl--notes)
    (with-temp-file ehostctl-notes-file
      (let ((print-level nil)
            (print-length nil))
        (prin1 alist (current-buffer))))))

(defun ehostctl--notes-get (profile host)
  "Get note for HOST in PROFILE, or empty string."
  (unless ehostctl--notes (ehostctl--notes-load))
  (or (gethash (ehostctl--notes-key profile host) ehostctl--notes) ""))

(defun ehostctl--notes-set (profile host note)
  "Set NOTE for HOST in PROFILE.  Empty string remove the note."
  (unless ehostctl--notes (ehostctl--notes-load))
  (let ((key (ehostctl--notes-key profile host)))
    (if (string-empty-p note)
        (remhash key ehostctl--notes)
      (puthash key note ehostctl--notes)))
  (ehostctl--notes-save))

(defun ehostctl--profile-desc-get (profile)
  "Get description for PROFILE, or empty string."
  (ehostctl--notes-get profile ""))

(defun ehostctl--profile-desc-set (profile desc)
  "Set DESC for PROFILE.  Empty string remove the description."
  (ehostctl--notes-set profile "" desc))


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

(defun ehostctl--profile-names ()
  "Return list of all profile names."
  (mapcar #'car (ehostctl--get-profiles)))

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
              (list name (vector name
                                 (ehostctl--propertize-status status)
                                 (number-to-string count)
                                 (ehostctl--profile-desc-get name)))))
          (ehostctl--get-profiles)))

(defvar-keymap ehostctl-profile-list-mode-map
  :doc "Keymap for `ehostctl-profile-list-mode'."
  "RET" #'ehostctl-profile-enter
  "e"   #'ehostctl-profile-enable
  "d"   #'ehostctl-profile-disable
  "t"   #'ehostctl-profile-toggle
  "D"   #'ehostctl-profile-remove
  "a"   #'ehostctl-profile-add
  "c"   #'ehostctl-profile-copy
  "m"   #'ehostctl-profile-merge
  "r"   #'ehostctl-profile-rename
  "n"   #'ehostctl-profile-describe
  "b"   #'ehostctl-backup
  "R"   #'ehostctl-restore
  "?"   #'ehostctl-transient)

(define-derived-mode ehostctl-profile-list-mode tabulated-list-mode "Profiles"
  "Major mode for listing hostctl profiles."
  (setq tabulated-list-format [("Profile" 20 t)
                                ("Status" 8 t)
                                ("Entries" 8 t)
                                ("Description" 30 t)]
        tabulated-list-padding 2
        revert-buffer-function #'ehostctl--profile-revert)
  (tabulated-list-init-header)
  (face-remap-add-relative 'header-line 'ehostctl-header-face))

(defun ehostctl--profile-revert (&rest _)
  "Revert profile list: refresh data, print, then apply stripes."
  (ehostctl--profile-refresh)
  (tabulated-list-print t)
  (ehostctl--apply-stripes))

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
    (when (yes-or-no-p (format "Remove profile '%s' (cannot be undone)? " profile))
      (ehostctl--run-sudo! "remove" profile)
      (message "Removed profile: %s" profile)
      (revert-buffer))))

(defun ehostctl-profile-describe ()
  "Add or edit a description for the profile at point."
  (interactive)
  (let* ((profile (ehostctl--profile-at-point))
         (old-desc (ehostctl--profile-desc-get profile))
         (new-desc (read-string (format "Description for %s: " profile) old-desc)))
    (ehostctl--profile-desc-set profile new-desc)
    (revert-buffer)
    (message (if (string-empty-p new-desc) "Description removed" "Description saved"))))

(defun ehostctl--copy-profile-entries (source target)
  "Copy all host entries and annotations from SOURCE to TARGET profile.
Return the list of hosts copied."
  (let ((hosts (ehostctl--get-hosts source)))
    (dolist (h hosts)
      (ehostctl--run-sudo! "add" "domains" target "--ip" (nth 0 h) (nth 1 h)))
    (let ((pdesc (ehostctl--profile-desc-get source)))
      (when (and (not (string-empty-p pdesc))
                 (string-empty-p (ehostctl--profile-desc-get target)))
        (ehostctl--profile-desc-set target pdesc)))
    (dolist (h hosts)
      (let ((desc (ehostctl--notes-get source (nth 1 h))))
        (when (and (not (string-empty-p desc))
                   (string-empty-p (ehostctl--notes-get target (nth 1 h))))
          (ehostctl--notes-set target (nth 1 h) desc))))
    hosts))

(defun ehostctl--remove-profile-annotations (profile hosts)
  "Remove all annotations for PROFILE and its HOSTS."
  (ehostctl--profile-desc-set profile "")
  (dolist (h hosts)
    (ehostctl--notes-set profile (nth 1 h) "")))

(defun ehostctl-profile-copy ()
  "Copy the profile at point to a new profile."
  (interactive)
  (let* ((source (ehostctl--profile-at-point))
         (target (read-string (format "Copy '%s' to: " source))))
    (when (string-empty-p target)
      (user-error "Profile name cannot be empty"))
    (ehostctl--copy-profile-entries source target)
    (message "Copied profile '%s' → '%s'" source target)
    (revert-buffer)))

(defun ehostctl-profile-merge ()
  "Merge the profile at point into another, removing the source."
  (interactive)
  (let* ((source (ehostctl--profile-at-point))
         (target (completing-read
                  (format "Merge '%s' into: " source)
                  (remove source (ehostctl--profile-names))
                  nil nil)))
    (when (string-empty-p target)
      (user-error "Profile name cannot be empty"))
    (when (yes-or-no-p (format "Merge '%s' into '%s' and remove '%s'? "
                               source target source))
      (let ((hosts (ehostctl--copy-profile-entries source target)))
        (ehostctl--run-sudo! "remove" source)
        (ehostctl--remove-profile-annotations source hosts))
      (message "Merged '%s' into '%s'" source target)
      (revert-buffer))))

(defun ehostctl-profile-rename ()
  "Rename the profile at point."
  (interactive)
  (let* ((old-name (ehostctl--profile-at-point))
         (new-name (read-string (format "Rename '%s' to: " old-name))))
    (when (string-empty-p new-name)
      (user-error "Profile name cannot be empty"))
    (let ((hosts (ehostctl--copy-profile-entries old-name new-name)))
      (ehostctl--run-sudo! "remove" old-name)
      (ehostctl--remove-profile-annotations old-name hosts))
    (message "Renamed '%s' → '%s'" old-name new-name)
    (revert-buffer)))

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
    (when (yes-or-no-p "Restore will OVERWRITE current hosts file.  Continue? ")
      (ehostctl--run-sudo! "restore" "--from" (expand-file-name file))
      (message "Hosts file restored from: %s" file)
      (revert-buffer))))

;;;; Host List Mode (Second Layer)

(defvar-local ehostctl--current-profile nil
  "The profile name displayed in the current host list buffer.")

(defun ehostctl--host-entries ()
  "Build `tabulated-list-entries' for host list."
  (let ((hosts (ehostctl--get-hosts ehostctl--current-profile)))
    (seq-map-indexed (lambda (h idx)
                       (let ((ip (nth 0 h))
                             (host (nth 1 h))
                             (status (nth 2 h))
                             (desc (ehostctl--notes-get
                                    ehostctl--current-profile (nth 1 h))))
                         (list idx (vector ip host
                                          (ehostctl--propertize-status status)
                                          desc))))
                     hosts)))

(defvar-keymap ehostctl-host-list-mode-map
  :doc "Keymap for `ehostctl-host-list-mode'."
  "a" #'ehostctl-host-add
  "d" #'ehostctl-host-remove
  "c" #'ehostctl-host-copy
  "m" #'ehostctl-host-move
  "n" #'ehostctl-host-describe
  "?" #'ehostctl-host-transient)

(define-derived-mode ehostctl-host-list-mode tabulated-list-mode "Hosts"
  "Major mode for listing hosts in a profile."
  (setq tabulated-list-format [("IP" 20 t)
                                ("Host" 40 t)
                                ("Status" 8 t)
                                ("Description" 30 t)]
        tabulated-list-padding 2
        revert-buffer-function #'ehostctl--host-revert)
  (tabulated-list-init-header)
  (face-remap-add-relative 'header-line 'ehostctl-header-face))

(defun ehostctl--host-revert (&rest _)
  "Revert host list: refresh data, print, then apply stripes."
  (ehostctl--host-refresh)
  (tabulated-list-print t)
  (ehostctl--apply-stripes))

(defun ehostctl--host-refresh ()
  "Refresh host list entries."
  (setq tabulated-list-entries (ehostctl--host-entries)))

(defun ehostctl-hosts (profile)
  "Open host list for PROFILE."
  (let ((buf (get-buffer-create (format "*ehostctl: %s*" profile))))
    (with-current-buffer buf
      (ehostctl-host-list-mode)
      (setq ehostctl--current-profile profile)
      (setq header-line-format (format " Profile: %s" profile))
      (revert-buffer))
    (switch-to-buffer buf)))

(defun ehostctl-host-add ()
  "Add a host entry to the current profile."
  (interactive)
  (let* ((ip (read-string "IP address: " "127.0.0.1"))
         (domains (read-string "Domains (space separated): ")))
    (apply #'ehostctl--run-sudo!
           "add" "domains" ehostctl--current-profile
           "--ip" ip
           (split-string domains))
    (message "Added to profile: %s" ehostctl--current-profile)
    (revert-buffer)))

(defun ehostctl-host-describe ()
  "Add or edit a description for the host entry at point."
  (interactive)
  (let* ((entry (or (tabulated-list-get-entry)
                    (user-error "No entry at point")))
         (host (aref entry 1))
         (old-desc (ehostctl--notes-get ehostctl--current-profile host))
         (new-desc (read-string (format "Description for %s: " host) old-desc)))
    (ehostctl--notes-set ehostctl--current-profile host new-desc)
    (revert-buffer)
    (message (if (string-empty-p new-desc) "Description removed" "Description saved"))))

(defun ehostctl-host-copy ()
  "Copy the host entry at point to another profile."
  (interactive)
  (let* ((entry (or (tabulated-list-get-entry)
                    (user-error "No entry at point")))
         (ip (aref entry 0))
         (host (aref entry 1))
         (target (completing-read
                  (format "Copy '%s' to profile: " host)
                  (remove ehostctl--current-profile
                          (ehostctl--profile-names))
                  nil nil)))
    (when (string-empty-p target)
      (user-error "Profile name cannot be empty"))
    (ehostctl--run-sudo! "add" "domains" target "--ip" ip host)
    (let ((desc (ehostctl--notes-get ehostctl--current-profile host)))
      (unless (string-empty-p desc)
        (ehostctl--notes-set target host desc)))
    (message "Copied '%s' → profile '%s'" host target)
    (revert-buffer)))

(defun ehostctl-host-move ()
  "Move the host entry at point to another profile."
  (interactive)
  (let* ((entry (or (tabulated-list-get-entry)
                    (user-error "No entry at point")))
         (ip (aref entry 0))
         (host (aref entry 1))
         (target (completing-read
                  (format "Move '%s' to profile: " host)
                  (remove ehostctl--current-profile
                          (ehostctl--profile-names))
                  nil nil)))
    (when (string-empty-p target)
      (user-error "Profile name cannot be empty"))
    (ehostctl--run-sudo! "add" "domains" target "--ip" ip host)
    (let ((desc (ehostctl--notes-get ehostctl--current-profile host)))
      (unless (string-empty-p desc)
        (ehostctl--notes-set target host desc))
      (ehostctl--notes-set ehostctl--current-profile host ""))
    (ehostctl--run-sudo! "remove" "domains" ehostctl--current-profile host)
    (message "Moved '%s' → profile '%s'" host target)
    (revert-buffer)))

(defun ehostctl-host-remove ()
  "Remove the host entry at point from the current profile."
  (interactive)
  (let* ((entry (tabulated-list-get-entry))
         (host (aref entry 1)))
    (unless entry (user-error "No entry at point"))
    (when (yes-or-no-p (format "Remove '%s' from profile '%s'? "
                               host ehostctl--current-profile))
      (ehostctl--run-sudo! "remove" "domains" ehostctl--current-profile host)
      (message "Removed %s" host)
      (revert-buffer))))

;;;; Transient Menus

(transient-define-prefix ehostctl-transient ()
  "Transient menu for ehostctl profile operations."
  ["Profile Actions"
   ("e" "Enable"   ehostctl-profile-enable)
   ("d" "Disable"  ehostctl-profile-disable)
   ("t" "Toggle"   ehostctl-profile-toggle)
   ("D" "Remove"   ehostctl-profile-remove)
   ("a" "Add"      ehostctl-profile-add)
   ("c" "Copy"     ehostctl-profile-copy)
   ("m" "Merge…"   ehostctl-profile-merge)
   ("r" "Rename"   ehostctl-profile-rename)
   ("n" "Describe" ehostctl-profile-describe)]
  ["Global"
   ("b" "Backup"  ehostctl-backup)
   ("R" "Restore" ehostctl-restore)
   ("g" "Refresh" revert-buffer)])

(transient-define-prefix ehostctl-host-transient ()
  "Transient menu for ehostctl host operations."
  ["Host Actions"
   ("a" "Add"      ehostctl-host-add)
   ("d" "Remove"   ehostctl-host-remove)
   ("c" "Copy to…" ehostctl-host-copy)
   ("m" "Move to…" ehostctl-host-move)
   ("n" "Describe" ehostctl-host-describe)]
  ["Navigation"
   ("g" "Refresh" revert-buffer)
   ("q" "Quit"    quit-window)])

;;;; Evil Integration

(declare-function evil-set-initial-state "evil-core" (state mode))
(declare-function evil-define-key "evil-core" (state keymap &rest bindings))

(with-eval-after-load 'evil
  (evil-set-initial-state 'ehostctl-profile-list-mode 'normal)
  (evil-set-initial-state 'ehostctl-host-list-mode 'normal)

  (evil-define-key 'normal ehostctl-profile-list-mode-map
    (kbd "RET") #'ehostctl-profile-enter
    "e"   #'ehostctl-profile-enable
    "d"   #'ehostctl-profile-disable
    "t"   #'ehostctl-profile-toggle
    "x"   #'ehostctl-profile-remove
    "a"   #'ehostctl-profile-add
    "c"   #'ehostctl-profile-copy
    "m"   #'ehostctl-profile-merge
    "r"   #'ehostctl-profile-rename
    "n"   #'ehostctl-profile-describe
    "b"   #'ehostctl-backup
    "R"   #'ehostctl-restore
    "gr"  #'revert-buffer
    "q"   #'quit-window
    "?"   #'ehostctl-transient)

  (evil-define-key 'normal ehostctl-host-list-mode-map
    "a"   #'ehostctl-host-add
    "x"   #'ehostctl-host-remove
    "c"   #'ehostctl-host-copy
    "m"   #'ehostctl-host-move
    "n"   #'ehostctl-host-describe
    "gr"  #'revert-buffer
    "q"   #'quit-window
    "?"   #'ehostctl-host-transient))

;;;; Entry Point

;;;###autoload
(defun ehostctl ()
  "Open ehostctl profile list."
  (interactive)
  (unless (executable-find ehostctl-hostctl-executable)
    (user-error "Hostctl not found.  Install from https://github.com/guumaster/hostctl"))
  (let ((buf (get-buffer-create "*ehostctl*")))
    (with-current-buffer buf
      (ehostctl-profile-list-mode)
      (revert-buffer))
    (switch-to-buffer buf)))

(provide 'ehostctl)
;;; ehostctl.el ends here
