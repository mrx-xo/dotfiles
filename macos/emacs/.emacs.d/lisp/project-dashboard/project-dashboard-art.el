;;; project-dashboard-art.el --- ASCII art collection for project dashboard -*- lexical-binding: t; -*-

;;; Commentary:

;; Collection of ASCII art for the project dashboard.
;; A random piece is selected each time the dashboard is opened.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar project-dashboard-art-collection
  '(
    ;; Rainy cloud
    ("                         000      00"
     "                       0000000   0000"
     "          0      00  00000000000000000"
     "        0000 0  000000000000000000000000       0"
     "     000000000000000000000000000000000000000 000"
     "    0000000000000000000000000000000000000000000000"
     "000000000000000000000000000000000000000000000000"
     "0000000000000000000000000000000000000000000000000000"
     "          / / / / / / / / / / / / / / / /"
     "        / / / / / / / / / / / / / / /"
     "        / / / / / / / / / / / / / / /"
     "      / / / / / / / / / / / / / /"
     "      / / / / / / / / / / / / /"
     "    / / / / / / / / / / / /"
     "    / / / / / / / / / /"
     ""
     "     ...........IT'S RAINING AGAIN.")

    ;; Winter snowflakes
    ("                     *  .  *"
     "                   . _\\/ \\/_ ."
     "                    \\  \\ /  /             .      ."
     "      ..    ..    -==>: X :<==-           _\\/  \\/_"
     "      '\\    /'      / _/ \\_ \\              _\\/\\/_"
     "        \\\\//       '  /\\ /\\  '         _\\_\\_\\/\\/_/_/_"
     "   _.__\\\\\\///__._    *  '  *            / /_/\\/\\_\\ \\"
     "    '  ///\\\\\\  '                           _/\\/\\_"
     "        //\\\\                               /\\  /\\"
     "      ./    \\.             ._    _.       '      '"
     "      ''    ''             (_)  (_)                  <> \\  / <>"
     "                            .\\::/. "
     "           .:.          _.=._\\\\//_.=._                  \\\\// "
     "      ..   \\o/   ..      '=' //\\\\ '='             _<>_\\_\\<>/_/_<>_"
     "      :o|   |   |o:         '/::\'                 <> / /<>\\ \\ <>"
     "       ~ '. ' .' ~         (_)  (_)      _    _       _ //\\\\ _"
     "           >O<             '      '     /_/  \\_\\     / /\\  /\\ \\"
     "       _ .' . '. _                        \\\\//       <> /  \\ <>"
     "      :o|   |   |o:                   /\\_\\\\><//_/\\"
     "      ''   /o\\   ''     '.|  |.'      \\/ //><\\\\ \\/"
     "           ':'        . ~~\\  /~~ .       _//\\\\_"
     "jgs                   _\\_._\\/_._/_      \\_\\  /_/"
     "                       / ' /\\ ' \\                   \\o/"
     "       o              ' __/  \\__ '              _o/.:|:.\\.o_"
     "  o    :    o         ' .'|  |'.                  .\\:|:/."
     "    '.\\'/.'                 .                 -=>>::>o<::<<=-"
     "    :->@<-:                 :                   _ '/:|:\\' _"
     "    .'/.\\'."
     "  o    :    o")

    ;; City skyline (original)
    ("──────────────▄▀█▀█▀▄"
     "─────────────▀▀▀▀▀▀▀▀▀"
     "─────────────▄─░░░░░▄"
     "───█──▄─▄───▐▌▌░░░░░▌▌"
     "▌▄█▐▌▐█▐▐▌█▌█▌█░░░░░▌▌")

    ;; Sailboat at sea
    ("                               _"
     "                           ,--.\`-. __"
     "                         _,.\`. \\:/,\"  `-._"
     "                     ,-*\" _,.-;-*`-.+\"*._ )"
     "                    ( ,.\"* ,-\" / `.  \\.  `."
     "                   ,\"   ,;\"  ,\"\\../\\  \\:   \\"
     "                  (   ,\"/   / \\.,' :   ))  /"
     "                   \\  |/   / \\.,'  /  // ,'"
     "                    \\_)\\ ,' \\.,'  (  / )/"
     "                        `  \\._,'   `\""
     "                           \\../"
     "                           \\../"
     "                 ~        ~\\../           ~~"
     "          ~~          ~~   \\../   ~~   ~      ~~"
     "     ~~    ~   ~~  __...---\\../-...__ ~~~     ~~"
     "       ~~~~  ~_,--'        \\../      `--.__  ~~    ~~"
     "   ~~~  __,--'              `\"             `--.__   ~~~"
     "~~  ,--'                                         `--."
     "   '------......______             ______......------` ~~"
     " ~~~   ~    ~~      ~ `````---\"\"\"\"\"  ~~   ~     ~~"
     "        ~~~~    ~~  ~~~~       ~~~~~~  ~ ~~   ~~ ~~~  ~"
     "     ~~   ~   ~~~     ~~~ ~         ~~       ~~   SSt"
     "              ~        ~~       ~~~       ~")

    ;; Palm tree island
    ("                                                   .       ."
     "                                                    \\     /"
     "                                                 ._  '   '  _."
     "                                                   '  o@o  '"
     "                                                     o@@@o"
     "                                                 .-'  o@o  '-."
     "                                                     .   ."
     "                                                    /     \\"
     "                                                   .       ."
     ""
     "                             'Xx  xX*,"
     "                          ,*xXXx_xXx"
     "                            _xXXXXXxx*,"
     "                          ,*XXx@x@Xx"
     "                            X @|@@ `x"
     "                            '  ||    '"
     "                               ||"
     "                               ||"
     "                               ||"
     "                               ||"
     "                            /ssssssss."
     "                      /sssssssSSSSssssssssss."
     "        /\\         /sssssSSSSSSSSSSSSSSSssssssssssss.              Dani"
     "~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~"
     " ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~")

    ;; Tornado
    ("                              _____,,,\\//,,\\\\,/,"
     "                             /-- --- --- -----"
     "                            ///--- --- -- - ----"
     "                           o////- ---- --- --"
     "                           !!//o/---  -- --"
     "                         o*) !///,~,,\\\\,\\/,,/,//,,"
     "                           o!*!o'(\\          /\\"
     "                         | ! o \",) \\/\\  /\\  /  \\/\\"
     "                        o  !o! !!|    \\/  \\/     /"
     "                       ( * (  o!'; |\\   \\       /"
     "                        o o ! * !` | \\  /       \\"
     "                       o  |  o 'o| | :  \\       /"
     "                        *  o !*!': |o|  /      /"
     "                            (o''| `| : /      /"
     "                            ! *|'`  \\|/       \\\\"
     "                           ' !o!':\\  \\\\        \\"
     "                            ( ('|  \\  `._______/"
     "////\\\\\\,,\\///,,,,\\,/oO._*  o !*!'`  `.________/"
     "  ---- -- ------- - -oO*OoOo (o''|           /"
     "    --------  ------ 'oO*OoO!*|'o!!          \\"
     "-------  -- - ---- --* oO*OoO *!'| '         /"
     " ---  -   -----  ---- - oO*OoO!!':o!'       /"
     " - -  -----  -  --  - *--oO*OoOo!`         /"
     "   \\\\\\\\\\,,,\\\\,//////,\\,,\\\\\\/,,,\\,,ejm/AMC")

    ;; Lighthouse
    ("             ,__--~~-_."
     "      ,__--~~ ;__--_ : ~-_."
     "  _--~ ;__--~~   .|:~-_. .`~-_."
     " ~-_`( ~-_      ..|:::::~-_.'`.~-_."
     " |::~-_`. ~-_  ...|:::::::::~-_'. ~-_."
     " |:::::~-_))))..._|:::::::::::::~-_. .'~-_."
     " |::::::::;!)!)~~..~-_(().::::::::::~-_. ` ~-_."
     " |::::::::;!!!)......((o))::::::::::::::~-_.) ;~-_."
     " |::::::::;'!!!  .....(())-_::::::::::;_-~  ',_-~ |"
     " |::::::::; !!!     ...!!...~-_:::;_-~ , ,_-~     |"
     " |::::::::;.!!!        .......,_-~.  ,_-~         |   ()"
     " |::::::::; !!!          .,_-~  ~,_-~             |  (())"
     " |:::::::.( !!!.)     ,_-~ . ,_-~                 | ((()o)"
     " |::::::(:;`!!!,'),_-~.  ,_-~                  _-~.. (())"
     " |::::::.({,!!!_}~.,~,_-~            ()     _-~  :::..!!"
     " |:::::::',{!!!},~;_-~              (o)) _-~      ''"
     " |::::::(.:~(_;_-~ )            :  ((()o)     ()"
     " |:::::::::\"::|  .)            :::,_(o))     (o))"
     " |::::::::.:::|                 ;-:..!!     ((()o)"
     " |::::::::::::|              _-~         ..  (())"
     " |::()):::::::|           _-~           ::::..!!"
     "..~(()o)::::::|        _-~               ''"
     "..((o)))):::::|     _-~"
     "...((())~-_:::|  _-~"
     "..  '||    ~-_|-~ mn"
     ":::..!!")

    ;; Ship at sea
    ("                                                           ---\\=,</"
     "..,.,.,,.,.,.,,.,._,,,____,,,...,.,.,,.....,....,.,..,,.  ,-=--'\\_\\/"
     "\"\"\"\"\"\"\"\"\"\"############z_ _`\"\"\"########################' ,---'>__,>,_`-.     |"
     "       :  |  `\"\"\"V#######,,_ `-  \"\"##################' --z--;\" /_/  `. `.   |"
     "          |          `/\"\"\"\".`|`|| } }|.\"\"\"\"\"\"\"\"|\"\"\"\"\"  --'//`/'  `    \\  '. |"
     "    :          :      |:     ||   |  |  :   :  |   :   ,_\\---_\\._   :  `.\\ |/"
     "                   :  /  :   |  |   || :  :      :    //--'> ___ ``-,_   \\  \\"
     "         `\"^            :  ` ||   || |   :  :         '=-`',' / `-, __`-. |"
     "      :    :          : :  : |  |    ||    :     ---  //7;<\\     / ,--._ ` |"
     "         .,      :        :  |   ||| || '       :     -/;\\'/' -='/|(    \\ \\"
     "        %#'            :    `| |||    |  :   :      :  // '\\   // | `    | |"
     "    :         :   `'   :  :  || # | |||    :            `    .        :  |"
     "                         :   | ||#|#| | ':    :    :             :       `"
     "         '#\"      :   :    : | ||,|, ||   :      /        :           |:  ||"
     "  \"\"'                    :  \\\\|\\  X XX///`      :|   :    |   :      : |   |"
     "        :             :  / >\\\\> <\\/\\< </</==::_ |' ,`  ,.|_____|______|`--|"
     "   :         :   |    ,''{` /\"^\"/'/\\^\\'\"\\  --  \"\"\"==;:zz,,_;__ ,; : , ,,hjm|"
     "        |'       |`--', ',`--,,_    -_ --.  `--.     __ \"\"`\"=;;--=--=;;-==||"
     "        |    ,,--' ''  ,` ,',' ,'`--,._    -=-  /%%\\.___     ---          |"
     "  :     |---'  '  ' ,' ,`` , .'`.,,` , ';'--,._   `-=='  ~~  __ __ _,  ~~ |"
     "     :,-',' '` `` ,  .`, ,',' ', ` , ,','',`, `'\"`--,,_____..__          / |"
     ",,---',  ' ' , , '  ', , ` ' ,' `, ,  , ` '` ',`,`,")
    )
  "Collection of ASCII art pieces for the project dashboard.")

(defvar project-dashboard-art-cat
  '(" /\\_/\\   "
    "( o.o )  "
    " > ^ <   "
    "/|   |\\  "
    "(_|   |_)")
  "Cat ASCII art for testing.")

(defun project-dashboard-art-random ()
  "Return a random ASCII art piece from the collection."
  (nth (random (length project-dashboard-art-collection))
       project-dashboard-art-collection))

(defun project-dashboard-art-by-index (index)
  "Return the ASCII art piece at INDEX from the collection.
Returns nil if INDEX is out of bounds."
  (nth index project-dashboard-art-collection))

(defgroup project-dashboard-art nil
  "Generated art for project dashboards."
  :group 'project-dashboard)

(defcustom project-dashboard-art-width 60
  "Width in characters of generated dashboard art."
  :type 'integer
  :group 'project-dashboard-art)

(defcustom project-dashboard-art-height 12
  "Height in lines of generated dashboard art."
  :type 'integer
  :group 'project-dashboard-art)

(defcustom project-dashboard-art-subjects
  '("mountain range" "sailing ship" "city skyline" "lighthouse"
    "forest" "storm cloud" "desert" "waves")
  "Subjects from which one is chosen for each generated piece."
  :type '(repeat string)
  :group 'project-dashboard-art)

(defvar project-dashboard-art-cache-directory
  (if (fboundp 'no-littering-expand-var-file-name)
      (no-littering-expand-var-file-name "project-dashboard/art/")
    (expand-file-name "project-dashboard/art/" user-emacs-directory))
  "Directory containing generated art and backend state.")

(defvar project-dashboard-art--next-backend nil
  "Backend to try first for the next generation.")

(defvar project-dashboard-art--in-flight (make-hash-table :test #'equal)
  "Projects with an art generation process currently running.")

(defconst project-dashboard-art--charset " .:-=+*#%@"
  "Characters permitted in generated art.")

(defun project-dashboard-art--project-file (project-name)
  "Return the cache file for PROJECT-NAME."
  (expand-file-name
   (concat (replace-regexp-in-string "[^[:alnum:]_.-]" "_" project-name) ".txt")
   project-dashboard-art-cache-directory))

(defun project-dashboard-art--state-file ()
  "Return the backend alternation state file."
  (expand-file-name "state.el" project-dashboard-art-cache-directory))

(defun project-dashboard-art--lines (text)
  "Split TEXT into lines without treating its final newline as a blank line."
  (let ((lines (split-string text "\n" nil)))
    (if (and lines (string-empty-p (car (last lines))))
        (butlast lines)
      lines)))

(defun project-dashboard-art-normalize (text &optional width height)
  "Normalize TEXT to WIDTH columns by HEIGHT lines.
WIDTH and HEIGHT default to `project-dashboard-art-width' and
`project-dashboard-art-height'."
  (let* ((width (or width project-dashboard-art-width))
         (height (or height project-dashboard-art-height))
         (lines (cl-remove-if
                 (lambda (line)
                   (string-match-p "\\`[[:space:]]*```" line))
                 (project-dashboard-art--lines text)))
         normalized)
    (while (< (length normalized) height)
      (let* ((line (or (pop lines) ""))
             (clean (apply #'string
                           (mapcar (lambda (char)
                                     (if (string-search (char-to-string char)
                                                        project-dashboard-art--charset)
                                         char
                                       ?.))
                                   (string-to-list line))))
             (clipped (substring clean 0 (min width (length clean)))))
        (push (concat clipped (make-string (- width (length clipped)) ?\s))
              normalized)))
    (nreverse normalized)))

(defun project-dashboard-art-cache-read (project-name)
  "Return cached art for PROJECT-NAME, or nil when it has no cache entry."
  (let ((file (project-dashboard-art--project-file project-name)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (project-dashboard-art--lines (buffer-string))))))

(defun project-dashboard-art--cache-write (project-name art)
  "Write ART to PROJECT-NAME's cache and return ART."
  (make-directory project-dashboard-art-cache-directory t)
  (with-temp-file (project-dashboard-art--project-file project-name)
    (insert (string-join art "\n") "\n"))
  art)

(defun project-dashboard-art--load-state ()
  "Load and return the next backend from the state file."
  (setq project-dashboard-art--next-backend 'codex)
  (condition-case nil
      (when (file-readable-p (project-dashboard-art--state-file))
        (load (project-dashboard-art--state-file) nil t t))
    (error nil))
  (unless (memq project-dashboard-art--next-backend '(codex claude))
    (setq project-dashboard-art--next-backend 'codex))
  project-dashboard-art--next-backend)

(defun project-dashboard-art--save-next-backend (backend)
  "Persist BACKEND as the backend to try next."
  (make-directory project-dashboard-art-cache-directory t)
  (with-temp-file (project-dashboard-art--state-file)
    (prin1 `(setq project-dashboard-art--next-backend ',backend)
           (current-buffer))
    (insert "\n"))
  (setq project-dashboard-art--next-backend backend))

(defun project-dashboard-art--backend ()
  "Return the backend that should be tried first."
  (or project-dashboard-art--next-backend
      (project-dashboard-art--load-state)))

(defun project-dashboard-art--prompt (project-name subject)
  "Build an art prompt for PROJECT-NAME depicting SUBJECT."
  (format (concat "Draw %s for the project named %s as ASCII art at exactly "
                  "%d lines by %d columns. Use only this character set: "
                  " .:-=+*#%%@. Use no letters, no digits, no title, and no "
                  "code fences. Output the %d lines and nothing else.")
          subject project-name project-dashboard-art-height
          project-dashboard-art-width project-dashboard-art-height))

(defun project-dashboard-art--run-backend (backend prompt callback)
  "Run BACKEND asynchronously with PROMPT, then call CALLBACK with its output.
CALLBACK receives nil when the process fails or produces no output."
  (let* ((codex-p (eq backend 'codex))
         (output-file (when codex-p (make-temp-file "project-dashboard-art-")))
         (buffer (generate-new-buffer " *project-dashboard-art*"))
         (command (if codex-p
                      (list "timeout" "180" "codex" "exec"
                            "--skip-git-repo-check" "-s" "read-only"
                            "--output-last-message" output-file prompt)
                    (list "timeout" "120" "claude" "-p" "--model"
                          "claude-sonnet-5" prompt))))
    (condition-case err
        (let ((process
               (make-process
                :name (format "project-dashboard-art-%s" backend)
                :buffer buffer
                :command command
                :connection-type 'pipe
                :noquery t
                :sentinel
                (lambda (process _event)
                  (when (memq (process-status process) '(exit signal))
                    (let ((success (zerop (process-exit-status process)))
                          output)
                      (when success
                        (setq output
                              (if codex-p
                                  (when (and output-file
                                             (file-readable-p output-file))
                                    (with-temp-buffer
                                      (insert-file-contents output-file)
                                      (buffer-string)))
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (buffer-string))))))
                      (when output-file (delete-file output-file))
                      (when (buffer-live-p buffer) (kill-buffer buffer))
                      (funcall callback
                               (and success output
                                    (not (string-empty-p (string-trim output)))
                                    output))))))))
          ;; Closing the pipe makes the subprocess read stdin as /dev/null.
          (process-send-eof process))
      (error
       (when output-file (delete-file output-file))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (message "Project dashboard art backend failed to start: %s"
                (error-message-string err))
       (funcall callback nil)))))

(defun project-dashboard-art-generate (project-name &optional callback force)
  "Generate and cache art for PROJECT-NAME asynchronously.
Call CALLBACK with generated art, or collection art if both backends fail.
Unless FORCE is non-nil, return cached art through CALLBACK without spawning a
process.  Return non-nil when this call starts generation."
  (let ((cached (and (not force) (project-dashboard-art-cache-read project-name))))
    (cond
     (cached
      (when callback (funcall callback cached))
      nil)
     ((gethash project-name project-dashboard-art--in-flight) nil)
     (t
      (puthash project-name t project-dashboard-art--in-flight)
      (let* ((first (project-dashboard-art--backend))
             (second (if (eq first 'codex) 'claude 'codex))
             (subject (nth (random (length project-dashboard-art-subjects))
                           project-dashboard-art-subjects))
             (prompt (project-dashboard-art--prompt project-name subject)))
        (cl-labels
            ((finish (art backend)
               (remhash project-name project-dashboard-art--in-flight)
               (if art
                   (progn
                     (project-dashboard-art--cache-write project-name art)
                     (project-dashboard-art--save-next-backend
                      (if (eq backend 'codex) 'claude 'codex))
                     (when callback (funcall callback art)))
                 (message "Project dashboard art generation failed for %s"
                          project-name)
                 (when callback
                   (funcall callback
                            (or (project-dashboard-art-cache-read project-name)
                                (project-dashboard-art-random))))))
             (run (backend fallback)
               (project-dashboard-art--run-backend
                backend prompt
                (lambda (output)
                  (if output
                      (finish (project-dashboard-art-normalize output) backend)
                    (if fallback
                        (run fallback nil)
                      (finish nil backend)))))))
          (run first second)))
      t))))

(declare-function project-dashboard--render "project-dashboard")
(defvar project-dashboard--project-root)
(defvar project-dashboard--current-art)

(defun project-dashboard-art-regenerate ()
  "Regenerate art for the project in the current dashboard buffer."
  (interactive)
  (unless (and (derived-mode-p 'project-dashboard-mode)
               (bound-and-true-p project-dashboard--project-root))
    (user-error "This command must run in a project dashboard"))
  (let ((buffer (current-buffer))
        (project-name
         (file-name-nondirectory
          (directory-file-name project-dashboard--project-root))))
    (if (project-dashboard-art-generate
         project-name
         (lambda (art)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq project-dashboard--current-art art)
               (project-dashboard--render))))
         t)
        (message "Generating new dashboard art for %s" project-name)
      (message "Dashboard art generation is already running for %s"
               project-name))))

(provide 'project-dashboard-art)

;;; project-dashboard-art.el ends here
