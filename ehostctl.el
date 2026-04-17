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

(defcustom ehostctl-hosts-file "/etc/hosts"
  "Path to the hosts file."
  :type 'file
  :group 'ehostctl)

(defcustom ehostctl-auto-backup t
  "Whether to automatically backup before write operations."
  :type 'boolean
  :group 'ehostctl)

(defcustom ehostctl-backup-directory
  (expand-file-name "~/.ehostctl/backups/")
  "Directory for storing automatic backups."
  :type 'directory
  :group 'ehostctl)

(defcustom ehostctl-backup-max-count 50
  "Maximum number of backup files to retain."
  :type 'integer
  :group 'ehostctl)

(defcustom ehostctl-periodic-backup-interval 3600
  "Interval in seconds for periodic backups, or nil to disable."
  :type '(choice (integer :tag "Seconds")
                 (const :tag "Disabled" nil))
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
  "Run hostctl with ARGS via sudo.  Signal error on failure.
Automatically backs up the hosts file before the first write in an operation."
  (ehostctl--maybe-auto-backup)
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

;;;; Auto Backup

(defvar ehostctl--last-auto-backup-time 0
  "Timestamp of the last automatic pre-write backup.")

(defvar ehostctl--periodic-timer nil
  "Timer for periodic backups.")

(defun ehostctl--backup-ensure-dir ()
  "Ensure `ehostctl-backup-directory' exists."
  (unless (file-directory-p ehostctl-backup-directory)
    (make-directory ehostctl-backup-directory t)))

(defun ehostctl--backup-create (type)
  "Create a backup of the hosts file.
TYPE is \"auto\", \"periodic\", or \"manual\"."
  (ehostctl--backup-ensure-dir)
  (let* ((timestamp (format-time-string "%Y%m%d-%H%M%S"))
         (filename (format "%s-%s.bak" type timestamp))
         (dest (expand-file-name filename ehostctl-backup-directory)))
    (condition-case err
        (progn
          (copy-file ehostctl-hosts-file dest t)
          (ehostctl--backup-cleanup)
          dest)
      (error
       (message "ehostctl: backup failed: %s" (error-message-string err))
       nil))))

(defun ehostctl--backup-create-async (type &optional callback)
  "Create a backup of the hosts file asynchronously.
TYPE is \"auto\", \"periodic\", or \"manual\".
CALLBACK, if non-nil, is called with the destination path on success."
  (ehostctl--backup-ensure-dir)
  (let* ((timestamp (format-time-string "%Y%m%d-%H%M%S"))
         (filename (format "%s-%s.bak" type timestamp))
         (dest (expand-file-name filename ehostctl-backup-directory))
         (src ehostctl-hosts-file))
    (make-process
     :name "ehostctl-backup"
     :buffer nil
     :command (list "cp" "--" src dest)
     :sentinel (lambda (proc _event)
                 (when (and (eq (process-status proc) 'exit)
                            (zerop (process-exit-status proc)))
                   (ehostctl--backup-cleanup)
                   (when callback (funcall callback dest)))))))

(defun ehostctl--backup-cleanup ()
  "Remove oldest backups exceeding `ehostctl-backup-max-count'."
  (let* ((files (ehostctl--backup-files))
         (excess (nthcdr ehostctl-backup-max-count files)))
    (dolist (f excess)
      (delete-file f))))

(defun ehostctl--backup-files ()
  "Return list of backup file paths, newest first."
  (when (file-directory-p ehostctl-backup-directory)
    (let ((files (directory-files ehostctl-backup-directory t
                                 "\\`\\(auto\\|periodic\\|manual\\)-[0-9]\\{8\\}-[0-9]\\{6\\}\\.bak\\'")))
      (sort files (lambda (a b) (string> a b))))))

(defun ehostctl--backup-parse-filename (path)
  "Parse backup PATH into (TYPE TIMESTAMP-STRING).
Return nil if the filename does not match."
  (let ((name (file-name-nondirectory path)))
    (when (string-match "\\`\\(auto\\|periodic\\|manual\\)-\\([0-9]\\{8\\}-[0-9]\\{6\\}\\)\\.bak\\'" name)
      (list (match-string 1 name) (match-string 2 name)))))

(defun ehostctl--backup-list ()
  "Return backup entries as ((PATH TYPE TIMESTAMP SIZE) ...), newest first."
  (mapcar (lambda (path)
            (let ((parsed (ehostctl--backup-parse-filename path)))
              (list path
                    (nth 0 parsed)
                    (nth 1 parsed)
                    (file-attribute-size (file-attributes path)))))
          (ehostctl--backup-files)))

(defun ehostctl--maybe-auto-backup ()
  "Create a pre-write backup if enabled and not already done recently."
  (when (and ehostctl-auto-backup
             (> (- (float-time) ehostctl--last-auto-backup-time) 2.0))
    (ehostctl--backup-create "auto")
    (setq ehostctl--last-auto-backup-time (float-time))))

(defun ehostctl--periodic-backup-start ()
  "Start the periodic backup timer if configured."
  (ehostctl--periodic-backup-stop)
  (when ehostctl-periodic-backup-interval
    (setq ehostctl--periodic-timer
          (run-with-timer ehostctl-periodic-backup-interval
                          ehostctl-periodic-backup-interval
                          (lambda ()
                            (ehostctl--backup-create-async "periodic"))))))

(defun ehostctl--periodic-backup-stop ()
  "Stop the periodic backup timer."
  (when (timerp ehostctl--periodic-timer)
    (cancel-timer ehostctl--periodic-timer)
    (setq ehostctl--periodic-timer nil)))

;;;###autoload
(define-minor-mode ehostctl-backup-mode
  "Global minor mode for periodic hosts file backup.
When enabled, a timer runs in the background at
`ehostctl-periodic-backup-interval' seconds, independent of
whether any ehostctl buffer is open.  Enable in init.el for
daemon-style backup:

  (ehostctl-backup-mode 1)"
  :global t
  :lighter " EhBak"
  :group 'ehostctl
  (if ehostctl-backup-mode
      (ehostctl--periodic-backup-start)
    (ehostctl--periodic-backup-stop)))

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


;;;; Input Validation

(defun ehostctl--valid-ip-p (ip)
  "Return non-nil if IP is a valid IPv4 or IPv6 address."
  (or (ehostctl--valid-ipv4-p ip)
      (ehostctl--valid-ipv6-p ip)))

(defun ehostctl--valid-ipv4-p (ip)
  "Return non-nil if IP is a valid IPv4 address."
  (when (string-match-p "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\'" ip)
    (let ((octets (mapcar #'string-to-number (split-string ip "\\."))))
      (cl-every (lambda (n) (<= 0 n 255)) octets))))

(defun ehostctl--valid-ipv6-p (ip)
  "Return non-nil if IP is a valid IPv6 address."
  (let ((addr (downcase ip)))
    (or (string-match-p
         "\\`\\(?:[0-9a-f]\\{1,4\\}:\\)\\{7\\}[0-9a-f]\\{1,4\\}\\'" addr)
        (string-match-p
         "\\`\\(?:[0-9a-f]\\{1,4\\}:\\)*::\\(?:[0-9a-f]\\{1,4\\}:\\)*[0-9a-f]\\{0,4\\}\\'" addr)
        (string= addr "::"))))

;;;; Multi-line Entry Parsing

(defun ehostctl--parse-host-lines (text)
  "Parse TEXT into list of (IP DOMAIN...) entries.
Each line should be \"IP DOMAIN1 [DOMAIN2 ...]\".
Empty lines and comment lines (starting with #) are skipped.
Signal error on invalid IP or missing domains."
  (let (entries (lineno 0))
    (dolist (line (split-string text "\n"))
      (cl-incf lineno)
      (let* ((trimmed (string-trim line))
             (parts (split-string trimmed)))
        (unless (or (string-empty-p trimmed) (string-prefix-p "#" trimmed))
          (let ((ip (car parts))
                (domains (cdr parts)))
            (unless (ehostctl--valid-ip-p ip)
              (user-error "Line %d: invalid IP address '%s'" lineno ip))
            (unless domains
              (user-error "Line %d: no domains for IP '%s'" lineno ip))
            (push (cons ip domains) entries)))))
    (nreverse entries)))

;;;; Entry Edit Buffer

(defvar-local ehostctl--edit-callback nil
  "Callback invoked with parsed entries on confirmation.")

(defvar-keymap ehostctl-edit-mode-map
  :doc "Keymap for `ehostctl-edit-mode'."
  "C-c C-c" #'ehostctl-edit-confirm
  "C-c C-k" #'ehostctl-edit-cancel)

(define-derived-mode ehostctl-edit-mode text-mode "EhostEdit"
  "Mode for editing host entries before submitting to hostctl."
  (setq header-line-format
        (substitute-command-keys
         "\\<ehostctl-edit-mode-map>\
Edit entries: IP DOMAIN... per line.  \
\\[ehostctl-edit-confirm] confirm, \
\\[ehostctl-edit-cancel] cancel.")))

(defun ehostctl-edit-confirm ()
  "Parse buffer entries and invoke the stored callback."
  (interactive)
  (let ((entries (ehostctl--parse-host-lines (buffer-string)))
        (cb ehostctl--edit-callback))
    (unless entries
      (user-error "No valid entries"))
    (quit-window t)
    (funcall cb entries)))

(defun ehostctl-edit-cancel ()
  "Cancel editing without adding entries."
  (interactive)
  (quit-window t)
  (message "Cancelled"))

(defun ehostctl--pop-edit-buffer (profile callback)
  "Open an edit buffer for PROFILE, calling CALLBACK with parsed entries."
  (let ((buf (get-buffer-create (format "*ehostctl-add: %s*" profile))))
    (with-current-buffer buf
      (ehostctl-edit-mode)
      (erase-buffer)
      (insert "# IP DOMAIN1 [DOMAIN2 ...]\n127.0.0.1 ")
      (setq ehostctl--edit-callback callback))
    (pop-to-buffer buf)))

;;;; Profile Name Normalization

(defun ehostctl--normalize-profile-name (name)
  "Normalize profile NAME to lowercase.
Hostctl silently adds entries to the default profile when given
uppercase names, so all user-supplied names must be downcased."
  (let ((normalized (downcase name)))
    (unless (string= name normalized)
      (message "Profile name lowered to '%s' (hostctl requires lowercase)" normalized))
    normalized))

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
  "R"   #'ehostctl-restore-list
  "U"   #'ehostctl-restore-undo
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
         (target (ehostctl--normalize-profile-name
                  (read-string (format "Copy '%s' to: " source)))))
    (when (string-empty-p target)
      (user-error "Profile name cannot be empty"))
    (ehostctl--copy-profile-entries source target)
    (message "Copied profile '%s' → '%s'" source target)
    (revert-buffer)))

(defun ehostctl-profile-merge ()
  "Merge the profile at point into another, removing the source."
  (interactive)
  (let* ((source (ehostctl--profile-at-point))
         (target (ehostctl--normalize-profile-name
                  (completing-read
                   (format "Merge '%s' into: " source)
                   (remove source (ehostctl--profile-names))
                   nil nil))))
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
         (new-name (ehostctl--normalize-profile-name
                    (read-string (format "Rename '%s' to: " old-name)))))
    (when (string-empty-p new-name)
      (user-error "Profile name cannot be empty"))
    (let ((hosts (ehostctl--copy-profile-entries old-name new-name)))
      (ehostctl--run-sudo! "remove" old-name)
      (ehostctl--remove-profile-annotations old-name hosts))
    (message "Renamed '%s' → '%s'" old-name new-name)
    (revert-buffer)))

(defun ehostctl-profile-add ()
  "Add host entries to a profile via an edit buffer."
  (interactive)
  (let ((profile (ehostctl--normalize-profile-name
                  (read-string "Profile name: "))))
    (ehostctl--pop-edit-buffer
     profile
     (lambda (entries)
       (dolist (e entries)
         (apply #'ehostctl--run-sudo!
                "add" "domains" profile "--ip" (car e) (cdr e)))
       (message "Added %d entr%s to profile: %s"
                (length entries)
                (if (= 1 (length entries)) "y" "ies")
                profile)
       (revert-buffer)))))

(defun ehostctl-backup ()
  "Create a manual backup of the hosts file asynchronously."
  (interactive)
  (ehostctl--backup-create-async
   "manual"
   (lambda (path) (message "Hosts file backed up to: %s" path))))

(defun ehostctl--restore-from (file)
  "Restore the hosts file from backup FILE."
  (let ((ehostctl-auto-backup t)
        (ehostctl--last-auto-backup-time 0))
    (ehostctl--maybe-auto-backup))
  (ehostctl--run-sudo "restore" "--from" (expand-file-name file))
  (message "Hosts file restored from: %s" (file-name-nondirectory file))
  (when-let ((buf (get-buffer "*ehostctl*")))
    (with-current-buffer buf (revert-buffer))))

(defun ehostctl-restore-undo ()
  "Restore from the most recent backup."
  (interactive)
  (let ((backups (ehostctl--backup-files)))
    (unless backups
      (user-error "No backups available"))
    (let* ((latest (car backups))
           (parsed (ehostctl--backup-parse-filename latest))
           (ts (nth 1 parsed)))
      (when (yes-or-no-p (format "Restore from backup %s?  This will OVERWRITE current hosts file." ts))
        (ehostctl--restore-from latest)))))

;;;; Backup List Mode

(defun ehostctl--backup-format-timestamp (ts)
  "Format raw timestamp TS (YYYYMMDD-HHMMSS) for display."
  (if (string-match "\\`\\([0-9]\\{4\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\'" ts)
      (format "%s-%s-%s %s:%s:%s"
              (match-string 1 ts) (match-string 2 ts) (match-string 3 ts)
              (match-string 4 ts) (match-string 5 ts) (match-string 6 ts))
    ts))

(defun ehostctl--backup-format-size (size)
  "Format file SIZE in bytes to human-readable string."
  (cond
   ((> size (* 1024 1024)) (format "%.1fM" (/ size (* 1024.0 1024))))
   ((> size 1024) (format "%.1fK" (/ size 1024.0)))
   (t (format "%dB" size))))

(defun ehostctl--backup-list-entries ()
  "Build `tabulated-list-entries' for backup list."
  (mapcar (lambda (entry)
            (let ((path (nth 0 entry))
                  (type (nth 1 entry))
                  (ts (nth 2 entry))
                  (size (nth 3 entry)))
              (list path (vector (ehostctl--backup-format-timestamp ts)
                                 type
                                 (ehostctl--backup-format-size size)))))
          (ehostctl--backup-list)))

(defvar-keymap ehostctl-backup-list-mode-map
  :doc "Keymap for `ehostctl-backup-list-mode'."
  "RET" #'ehostctl-backup-list-restore
  "d"   #'ehostctl-backup-list-delete
  "q"   #'quit-window)

(define-derived-mode ehostctl-backup-list-mode tabulated-list-mode "Backups"
  "Major mode for browsing ehostctl backup files."
  (setq tabulated-list-format [("Timestamp" 22 t)
                                ("Type" 10 t)
                                ("Size" 10 t)]
        tabulated-list-padding 2
        revert-buffer-function #'ehostctl--backup-list-revert)
  (tabulated-list-init-header)
  (face-remap-add-relative 'header-line 'ehostctl-header-face))

(defun ehostctl--backup-list-revert (&rest _)
  "Revert backup list."
  (setq tabulated-list-entries (ehostctl--backup-list-entries))
  (tabulated-list-print t)
  (ehostctl--apply-stripes))

(defun ehostctl-backup-list-restore ()
  "Restore hosts file from the backup at point."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path (user-error "No backup at point"))
    (when (yes-or-no-p "Restore will OVERWRITE current hosts file.  Continue? ")
      (ehostctl--restore-from path)
      (revert-buffer))))

(defun ehostctl-backup-list-delete ()
  "Delete the backup at point."
  (interactive)
  (let ((path (tabulated-list-get-id)))
    (unless path (user-error "No backup at point"))
    (when (yes-or-no-p (format "Delete backup %s? " (file-name-nondirectory path)))
      (delete-file path)
      (revert-buffer))))

(defun ehostctl-restore-list ()
  "Open the backup list buffer."
  (interactive)
  (let ((buf (get-buffer-create "*ehostctl-backups*")))
    (with-current-buffer buf
      (ehostctl-backup-list-mode)
      (revert-buffer))
    (switch-to-buffer buf)))

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
  "Add host entries to the current profile via an edit buffer."
  (interactive)
  (let ((profile ehostctl--current-profile))
    (ehostctl--pop-edit-buffer
     profile
     (lambda (entries)
       (dolist (e entries)
         (apply #'ehostctl--run-sudo!
                "add" "domains" profile "--ip" (car e) (cdr e)))
       (message "Added %d entr%s to profile: %s"
                (length entries)
                (if (= 1 (length entries)) "y" "ies")
                profile)
       (revert-buffer)))))

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
         (target (ehostctl--normalize-profile-name
                  (completing-read
                   (format "Copy '%s' to profile: " host)
                   (remove ehostctl--current-profile
                           (ehostctl--profile-names))
                   nil nil))))
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
         (target (ehostctl--normalize-profile-name
                  (completing-read
                   (format "Move '%s' to profile: " host)
                   (remove ehostctl--current-profile
                           (ehostctl--profile-names))
                   nil nil))))
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
  ["Backup"
   ("b" "Backup"       ehostctl-backup)
   ("R" "Restore List" ehostctl-restore-list)
   ("U" "Undo"         ehostctl-restore-undo)]
  ["Navigation"
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
(declare-function evil-define-key* "evil-common" (state keymap &rest bindings))

(with-eval-after-load 'evil
  (evil-set-initial-state 'ehostctl-profile-list-mode 'normal)
  (evil-set-initial-state 'ehostctl-host-list-mode 'normal)
  (evil-set-initial-state 'ehostctl-backup-list-mode 'normal)
  (evil-set-initial-state 'ehostctl-edit-mode 'insert)

  (evil-define-key* 'normal ehostctl-profile-list-mode-map
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
    "R"   #'ehostctl-restore-list
    "U"   #'ehostctl-restore-undo
    "gr"  #'revert-buffer
    "q"   #'quit-window
    "?"   #'ehostctl-transient)

  (evil-define-key* 'normal ehostctl-host-list-mode-map
    "a"   #'ehostctl-host-add
    "x"   #'ehostctl-host-remove
    "c"   #'ehostctl-host-copy
    "m"   #'ehostctl-host-move
    "n"   #'ehostctl-host-describe
    "gr"  #'revert-buffer
    "q"   #'quit-window
    "?"   #'ehostctl-host-transient)

  (evil-define-key* 'normal ehostctl-backup-list-mode-map
    (kbd "RET") #'ehostctl-backup-list-restore
    "x"   #'ehostctl-backup-list-delete
    "gr"  #'revert-buffer
    "q"   #'quit-window))

;;;; Entry Point

;;;###autoload
(defun ehostctl ()
  "Open ehostctl profile list."
  (interactive)
  (unless (executable-find ehostctl-hostctl-executable)
    (user-error "Hostctl not found.  Install from https://github.com/guumaster/hostctl"))
  (ehostctl-backup-mode 1)
  (let ((buf (get-buffer-create "*ehostctl*")))
    (with-current-buffer buf
      (ehostctl-profile-list-mode)
      (revert-buffer))
    (switch-to-buffer buf)))

(provide 'ehostctl)
;;; ehostctl.el ends here
