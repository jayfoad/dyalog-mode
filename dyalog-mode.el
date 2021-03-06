;;; dyalog-mode.el --- Major mode for editing Dyalog APL source code -*- coding: utf-8 lexical-binding: t -*-

;; Copyright (C) 2008, 2009, 2010, 2011 Joakim Hårsman

;; Author: Joakim Hårsman <joakim.harsman@gmail.com>
;; Version: 0.7
;; Package-Requires: ((cl-lib "0.2"))
;; Keywords: languages
;; URL: https://bitbucket.org/harsman/dyalog-mode/

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Dyalog-mode is a major mode for editing Dyalog APL source code.
;;
;; It supports syntax highlighting, indentation and convenience function like
;; toggling localization of variables. It can communicate with Dyalog
;; processes over a socket, allowing Emacs to be used as the editor for a
;; Dyalog session.
;;
;; Get the latest version at http://bitbucket.org/harsman/dyalog-mode

;;; Code:



(require 'cl-lib)

;; Set up mode specific keys below
(defvar dyalog-mode-map
  (let ((map(make-keymap)))
    (define-key map (kbd"M-RET") 'comment-indent-new-line)
    (define-key map (kbd"C-c C-c") 'dyalog-editor-fix)
    (define-key map (kbd"C-c C-q") 'dyalog-editor-fix-and-quit)
    (define-key map (kbd"C-c C-e") 'dyalog-editor-edit-symbol-at-point)
    (define-key map (kbd"C-c C-l") 'dyalog-toggle-local)
    map)
  "Keymap for Dyalog APL mode.")

(defvar dyalog-array-mode-map
  (let ((map(make-sparse-keymap)))
    ;;(define-key map (kbd"C-c C-c") 'dyalog-array-fix)
    (define-key map (kbd"C-c C-e") 'dyalog-editor-edit-symbol-at-point)
    map)
  "Keymap for Dyalog Array edit mode.")

;;;###autoload
(defun dyalog-fix-altgr-chars (keymap aplchars regularchars)
  "Fix a key map so AltGr+char isn't confused with C-M-char.

KEYMAP is an Emacs keymap.

APLCHARS is a string of APL-characters produced by pressing AltGr together
with some character.

REGULARCHARS is a string of the characters that when pressed
together with AltGr produce the corresponding apl character in APLCHARS."
  (dolist (pair (cl-mapcar #'cons aplchars regularchars))
    (let* ((aplchar (car pair))
           (char    (cdr pair))
           (aplkey  (vector (list 'control 'meta aplchar)))
           (regkey  (vector (list 'control 'meta char)))
           (fun  (lookup-key (current-global-map) regkey)))
      (when fun
        (define-key keymap aplkey fun)))))

(defconst dyalog-label-regex
  "^ *\\([A-Za-z_]+[A-Za-z0-9_]*:\\)")

(defconst dyalog-keyword-regex
  (concat "\\(\\(?:^\\s-*\\|\\(?5:" dyalog-label-regex " *\\)\\)"
          "\\(?2::[A-Za-z]+\\)\\)\\|\\(⋄\\s-*\\(?2::[A-Za-z]+\\)\\)"))

(defconst dyalog-middle-keyword-regex
  "\\(?: \\|\\_>\\)\\(:\\(In\\|InEach\\)\\)\\_>")

(defconst dyalog-comment-regex
  "^\\s-*⍝")

(defvar dyalog-ascii-chars "][<>+---=/¨~\\?*(){}&|.;"
  "APL symbols also present in ASCII.")

(defvar dyalog-keyword-chars
  "×≤≥≠∨∧÷∊⍴↑↓⍳○←→⌈⌊∘⍎⍕⊂⊃∩∪⊥⊤⍨⍒⍋⌽⍉⊖⍟⍱⍲⍬⌹≡≢⍪⌿⍀⍺⍵⎕⍞⋄⍷⍸⌷⍣⊣⊢⌶")

(defvar dyalog-name  "[A-Za-z∆_]+[A-Za-z∆_0-9]*")

(defvar dyalog-number
  "[^A-Za-z_∆0-9]\\(¯?[0-9]+\\.?[0-9]*\\(E¯?[0-9]+\\.?[0-9]*\\)?\\)")

(defconst dyalog-access-type
  "^\\s-*:Access +\\(WebMethod\\|\\(?:\\(Public\\|Private\\)\\)?\\(?: +\\(Instance\\( +Override\\|Overridable\\)\\|Shared\\)\\)?\\)")

(defconst dyalog-field-def
  (concat "^\\s-*:Field"
          "\\(?: +\\(Public\\|Private\\)\\)?"
          "\\(?: +\\(Instance\\|Shared\\)\\)?"
          "\\(?: +\\(ReadOnly\\)\\)?"
          " +" "\\(" dyalog-name "\\)"))

(defconst dyalog-naked-nabla "^\\s-*∇\\s-*$")

(defconst dyalog-func-start "\\(?:\\`\\|∇[\r\n]*\\)\\s-*")

(defun dyalog-name-list (id)
  "Return a regex with group ID matching a dyalog name list.
Name lists are (optionally) used for naming the elements of the
return value or right argument of a traditional defined function." 
  (concat "( *\\(?" id ":" dyalog-name "\\(?: +" dyalog-name "\\)+\\)"
          "*)"))

(defconst dyalog-func-retval
  (concat "\\(?:"
          "\\(?:" "\\(?2:" dyalog-name "\\)" "\\|"
          "\\(?:" (dyalog-name-list "2") "\\)" "\\|"
          "\\(?:" "{\\(?2:" dyalog-name "\\)}\\)" "\\|"
          "\\(?:" "{ *" (dyalog-name-list "2") " *}\\)"
          "\\) *← *\\)?"))

(defconst dyalog-func-larg
  "\\(?:\\(?3:[A-Za-z_]+\\)\\(?:\\_>\\| +\\)\\|{\\(?3:[A-Za-z_]+\\)} *\\)")

(defconst dyalog-func-name (concat "\\(?1:" dyalog-name "\\)"))

(defconst dyalog-op-def (concat "\\(?:" "( *"
                                "\\(?6:" dyalog-name  "\\)" ; left operand
                                " +"
                                "\\(?7:" dyalog-name "\\)"  ; operator name
                                "\\(?:" " +"
                                "\\(?8:" dyalog-name "\\)"  ; right operand
                                "\\)?" " *)" "\\)"))

(defconst dyalog-func-def (concat "\\(?:" dyalog-func-name "\\|"
                                 dyalog-op-def "\\)"))

(defvar dyalog-func-rarg (concat "\\(?:\\(?:\\(?: +\\|\\_<\\)\\(?4:"
                                 dyalog-name "\\)\\)\\|"
                                   "\\(?: *" (dyalog-name-list "4") "\\)\\)"))

(defconst dyalog-func-header-end "\\s-*\\(?5:;\\|$\\)")

(defconst dyalog-tradfn-header (concat dyalog-func-start dyalog-func-retval
                                       "\\(?:"
                                       "\\(?:" dyalog-func-larg dyalog-func-def
                                       dyalog-func-rarg "\\)" "\\|"
                                       "\\(?:" dyalog-func-def dyalog-func-rarg "?"
                                       "\\)" "\\)"
                                       dyalog-func-header-end))

(defface dyalog-apl-char
  '((t (:inherit font-lock-keyword-face)))
  "Face used for APL characters and punctuation."
  :group 'dyalog)

(defface dyalog-local-name
  '((t (:inherit font-lock-constant-face)))
  "Face used for localized names inside APL functions."
  :group 'dyalog)

(defface dyalog-local-system-name
  '((t (:inherit font-lock-variable-name-face)))
  "Face used for localized system variables inside APL functions."
  :group 'dyalog)

(defvar dyalog-font-lock-keywords
  (list
   ;; See emacs help for `font-lock-keywords' for a description of how the
   ;; below values work
   ;; System functions
   '("⎕[A-Za-z]*" . font-lock-builtin-face)
   ;; Keywords
   `(,dyalog-keyword-regex
     . (2 font-lock-keyword-face nil))
   `(,dyalog-middle-keyword-regex . (2 font-lock-keyword-face nil))
   ;; Labels
   '("^\\s-*\\([A-Za-z_][A-Za-z0-9_]*:\\)" . (1 font-lock-keyword-face t))
   ;; Numerical constans
   `(,dyalog-number (1 font-lock-constant-face nil))
   ;; APL chars
   (cons (concat "[" dyalog-ascii-chars dyalog-keyword-chars ":" "]")
         ''dyalog-apl-char)
   ;; Localizations
   '(";\\([A-Za-z0-9_∆]+\\)" (1 font-lock-constant-face nil))
   ;; Illegal chars (and del/nabla)
   '("[∇$@\"%]+" . font-lock-warning-face)
   `(,dyalog-access-type (1 font-lock-keyword-face))
   `(,dyalog-field-def (1 font-lock-keyword-face t t)
                       (4 font-lock-variable-name-face)
                       (2 font-lock-keyword-face t t)
                       (3 font-lock-keyword-face t t)))
  "Default highlighting mode for Dyalog mode.")

(defvar dyalog-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Make various APL chars punctuation
    (dolist (char
             (string-to-list (concat dyalog-keyword-chars dyalog-ascii-chars)))
      (modify-syntax-entry char "." st))
    ;; Make sure delta, quad and underscore are part of symbol names
    ;; This doesn't seem to work for delta and quad?
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?∆ "_" st)
    (modify-syntax-entry ?⎕ "_" st)
    ;; Comments
    (modify-syntax-entry ?⍝ "<" st)
    (modify-syntax-entry ?\n">" st)
    ;; Strings
    (modify-syntax-entry ?' "\"" st)
    (modify-syntax-entry ?\" "." st)
    ;; Delimiters
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?{ "(}" st)
    (modify-syntax-entry ?\} "){" st)
    st)
  "Syntax table for `dyalog-mode'.")

(defvar dyalog-array-mode-syntax-table
  (let ((st (make-syntax-table)))
    (dolist (char
             (string-to-list (concat dyalog-keyword-chars dyalog-ascii-chars)))
      (modify-syntax-entry char "." st))
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?∆ "_" st)
    (modify-syntax-entry ?⎕ "_" st)
    ;; Delimiters
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?{ "(}" st)
    (modify-syntax-entry ?\} "){" st)
    st)
  "Syntax table for `dyalog-array-mode'.")

(defconst dyalog-dfun-syntax-table
  (let ((st (copy-syntax-table dyalog-mode-syntax-table)))
    (modify-syntax-entry ?\( "." st)
    (modify-syntax-entry ?\) "." st)
    (modify-syntax-entry ?\[ "." st)
    (modify-syntax-entry ?\] "." st)
    st)
  "Syntax table to only consider {} as parens.")

;;;###autoload
(defun dyalog-ediff-forward-word ()
  "Move point forward one word."
  (interactive)
  (or   (> (skip-chars-forward "A-Za-z_∆0-9") 0)  ; name
        (> (skip-chars-forward "⎕:A-Za-z") 0)     ; sys name/keyword
        (> (skip-chars-forward "0-9E¯.") 0)       ; numbers
        (> (skip-chars-forward "⍺⍵∇") 0)          ; meta chars
        (> (skip-chars-forward " ") 0)            ; white space
        (forward-char)))                          ; fallback

(defconst dyalog-delimiter-match
  (let ((h (make-hash-table :test 'equal)))
    (dolist (e '((":if" . ":endif")("{"."}")
                 (":for" . ":endfor")(":repeat" . ":until")
                 (":while" . ":endwhile")(":trap" . ":endtrap")
                 (":hold" . ":endhold")(":with" . ":endwith")
                 (":namespace" . ":endnamespace")(":class" . ":endclass")
                 (":select" . ":endselect")(":interface" . ":endinterface")
                 (":property" . ":endproperty")))
      (puthash (car e) (list (cdr e) 'block-start) h)
      (puthash (cdr e) (list (car e) 'block-end) h))
    (dolist (e '((":andif". ":if")(":orif".":if")(":elseif".":if")))
      (puthash (car e) (list (cdr e) 'block-pause) h))
    (dolist (e '((":else" . ":\\(if\\|select\\|trap\\|hold\\)")
                 (":case" . ":\\(select\\|trap\\)")
                 (":caselist" . ":\\(select\\|trap\\)")))
      (puthash (car e) (list (cdr e) 'block-pause) h))
    (dolist (e '((":field" . ":\\(class\\|interface\\)")))
      (puthash (car e) (list (cdr e) nil) h))
    (dolist (e '(":access"))
      (puthash e (list "" nil) h))
    (puthash ":endrepeat" (list ":repeat" 'block-end) h)
    (puthash ":end" (list nil 'block-end) h)
    h))

(defconst dyalog-any-delimiter
  ":*"
  "A bogus keyword used to indicate a match with any keyword.")

(defgroup dyalog nil
  "Major mode `dyalog-mode' for editing Dyalog APL code."
  :group 'languages
  :prefix "dyalog-")

(defcustom dyalog-mode-hook nil
  "List of functions to be executed on entry to `dyalog-mode'."
  :type 'hook
  :group 'dyalog)

(defcustom dyalog-leading-spaces 1
  "The number of leading spaces to use for unknown buffer types.
Namespaces, classes and interfaces have 0 leading spaces in the left margin, and
functions have 1, but for buffers that cannot be qualified into one of these types,
the number of leading spaces defined here is used."
  :type 'integer
  :group 'dyalog)

(defcustom dyalog-indent-comments t
  "True if comments should be indented according to the surrounding scope."
  :type 'boolean
  :group 'dyalog)

(defcustom dyalog-fix-whitespace-before-save nil
  "If true, indent and delete redundant whitespace before saving."
  :type 'boolean
  :group 'dyalog)

(defvar dyalog-buffer-type nil
  "Whether a buffer contains a function, namespace or something else.
This affects indentation, functions have a leading space on each
line, but namespaces don't. Valid values are 'space-or-class
'function and 'unknown.")

;;; Indentation

(defun dyalog-matching-delimiter (delimiter)
  "Return the match for the given DELIMITER.
For example, if ':EndIf' is provided, return ':If' and vice versa."
  (car (gethash (downcase delimiter) dyalog-delimiter-match nil)))

(defun dyalog-keyword-indent-type (keyword)
  "Return a symbol indicating how a KEYWORD affects indentation.
If KEYWORD introduces a new block, (e.g :If), return
'block-start.  If it ends a block (e.g. :EndIf), return
'block-end.  If it ends a block and immediately starts a new
block (e.g. :Else or :Case), return 'block-pause.  If the keyword
should be indented the same way as everything else, return nil."
  (let ((d (gethash (downcase keyword) dyalog-delimiter-match nil)))
    (and d (nth 1 d))))

(defun dyalog-specific-keyword-regex (keyword)
  "Return a regex mathcing KEYWORD when point is at bol."
  (concat "\\(\\(?:^\\s-*\\|\\(?:" dyalog-label-regex " *\\)\\)"
          keyword "\\)\\|\\(⋄\\s-*" keyword "\\)"))

(defun dyalog-relative-indent (n)
  "Return the no spaces to indent N tabstops relative to the current line."
  (max (+ (current-indentation) (* tab-width n))
       (dyalog-leading-indentation)))

(defun dyalog-previous-logical-line ()
  "Move backwards to the start of the previous logical line.
Assumes point is at the beginning of a logical line."
  (let ((bol (line-beginning-position))
        (done nil))
    (if (eq (point) bol)
        (progn
          (forward-line -1)
          (end-of-line))
      (when (eq (char-before) ?⋄)
        (backward-char)))
    (while (not done)
      (skip-chars-backward "^⋄\r\n")
      (if (eq (char-before) ?⋄)
          (progn
            (setq done (not (dyalog-in-comment-or-string)))
            (when (not done)
              (backward-char)))
        (setq done t)))))

(defun dyalog-next-logical-line ()
  "Move forward to the start of the next logical line.
Assumes point is at the start of a logical line."
  (let ((done nil))
    (when (eq (char-after) ?⋄)
      (forward-char))
    (while (not done)
      (skip-chars-forward "^⋄\r\n")
      (if (eq (char-after) ?⋄)
          (setq done (not (dyalog-in-comment-or-string)))
        (setq done t))
      (if (eobp)
          nil
        (forward-char)))))

(defun dyalog-indent-parse-line (dfunstack on-tradfn-header)
  "Parse the current logical line for indentation purposes.
DFUNSTACK is a list of delimiters of currently open dfun blocks.
This affects the parsing of :. ON-TRADFN-HEADER is true if the
line is a tradfn header, this affects the parsing of { and }.
Return a plist with properties :keyword, the keyword at the head
of the line, :label which is the label at the start of the line
if any, :dfunstack which is a list of dfun delimiters open at end
of line, and finally :next-line which is the character position
the next logical line starts at."
  (let ((done nil)
        (eol (line-end-position))
        (in-dfun (equal "{" (car dfunstack)))
        (dfun-count nil)
        (label nil)
        (keyword nil)
        (indent-type nil)
        (start nil))
    (save-excursion
      (if (eq (char-after) ?⋄)
          (forward-char)
        (if (and (not in-dfun) (looking-at dyalog-label-regex))
            (progn
              (setq label (match-string-no-properties 1))
              (goto-char (match-end 0)))))
      (setq start (point))
      (cond
       ((looking-at-p "[ \t]*$")
        (setq indent-type 'blank))
       ((looking-at-p "[ \t]*⍝")
        (setq indent-type 'comment)))
      (while (not done)
        (skip-chars-forward "^⋄\r\n'{}⍝:")
        (pcase (char-after)
          (?'
           (progn
             (condition-case nil
                 (forward-sexp)
               (scan-error (goto-char eol)))
             (when (> (point) eol)
               (goto-char eol)
               (setq done t))))
          (?⍝
           (progn
             (goto-char eol)
             (setq done t)))
          (?{
           (if on-tradfn-header
               (forward-char)
             (progn
               (push "{" dfunstack)
               (setq dfun-count (1+ (or dfun-count 0)))
               (if (eobp)
                   (setq done t)
                 (forward-char))
               (setq in-dfun t))))
          (?}
           (if on-tradfn-header
               (forward-char)
             (progn
               (when dfunstack
                 (pop dfunstack)
                 (setq dfun-count (1- (or dfun-count 0)))
                 (setq in-dfun (equal (car dfunstack) "{")))
               (if (eobp)
                   (setq done t)
                 (forward-char)))))
          (?:
           (if (or in-dfun keyword)
               (forward-char)
             (progn
               (setq keyword
                      (buffer-substring-no-properties
                       (point)
                       (progn
                         (skip-chars-forward ":A-Za-z")
                         (point)))
                     indent-type
                     (dyalog-keyword-indent-type keyword)))))
          (_
           (setq done t))))
      (cond
       ((and dfun-count (> dfun-count 0))
        (setq indent-type 'dfun-start))
       ((and dfun-count (< dfun-count 0))
        (setq indent-type
              (if (eq (save-excursion
                        (goto-char start)
                        (skip-syntax-forward " ")
                        (char-after))
                      ?})
                  'dfun-end-and-dedent
                'dfun-end))))
      (unless (eobp)
        (forward-char))
      (list :label label :keyword keyword :dfunstack dfunstack
            :indent-type indent-type :next-line (point)))))

(defun dyalog-indent-stop-block-end (match blockstack indent-status _funcount)
  "Return whether we have found root for a block end, and amount of to indent.
MATCH is the keyword that matches the block end (e.g. :For
matches :EndFor), BLOCKSTACK is a stack of currently open blocks,
INDENT-STATUS is the indentation status of the current line (the
return value from `dyalog-indent-status', and FUNCOUNT is the
number of currently open tradfn definitions."
  (let ((indent-type (plist-get indent-status :indent-type)))
    (cond
     ((and (not blockstack)
           (if match
               (looking-at-p (dyalog-specific-keyword-regex match))
             (memq indent-type '(block-start block-pause))))
      (list t (dyalog-relative-indent 0)))
     ((and (memq indent-type '(tradfn-start tradfn-end))
           (not (string-match ":\\(End\\)?\\(Namespace\\|Class\\)" match)))
      (list t (skip-chars-forward " ∇"))))))

(defun dyalog-indent-stop-tradfn (blockstack indent-status _funcount)
  "Return whether we have found root for a tradfn, and chars to indent.
BLOCKSTACK is a stack of currently open blocks, INDENT-STATUS is
the indentation status of the current line (the return value from
`dyalog-indent-status', and FUNCOUNT is the number of currently
open tradfn definitions."
  (cond ((and (not blockstack)
              (looking-at-p (dyalog-specific-keyword-regex
                             ":\\(Class\\|Namespace\\)")))
         (list t (dyalog-relative-indent 1)))
        ((and (not blockstack)
              (memq (plist-get indent-status :indent-type)
                    '(tradfn-start tradfn-end)))
         (list t (current-indentation)))))

(defun dyalog-indent-search-stop-function (keyword
                                           &optional match_ indent-type_)
  "Given a KEYWORD, return a function to check for indentation root.
Optional argument MATCH_ is the matching keyword (e.g. :If
for :EndIf) and only needs to be supplied if it differs from the
default.  INDENT-TYPE_ is also optional, and is the indentation
type for the given keyword (see `dyalog-keyword-indent-type') and
only needs to be supplied if it differs from the default."
  (let* ((match (or match_ (dyalog-matching-delimiter keyword)))
         (indent-type (or indent-type_ (dyalog-keyword-indent-type keyword))))
    (cond
     ((eq 'block-start indent-type)
        #'dyalog-indent-search-stop-generic)
     ((memq indent-type '(block-end block-pause))
      (apply-partially 'dyalog-indent-stop-block-end match))
     (t
      #'dyalog-indent-search-stop-generic))))

(defun dyalog-indent-search-stop-generic (blockstack indent-status funcount)
  "Return if we have found an indentation root, and no chars to indent.
BLOCKSTACK is a stack of currently open blocks, INDENT-TYPE is
the indentation type of the current keyword (if any), and
FUNCOUNT is the number of currently open tradfn definitions."
  (let ((indent-type  (plist-get indent-status :indent-type))
        (label-at-bol (plist-get indent-status :label-at-bol)))
    (cond
     ((and (eq indent-type 'block-start) (not blockstack) (eq funcount 0))
      (list t (+ (dyalog-relative-indent 1)
                 (if label-at-bol 1 0))))
     ((and (eq indent-type 'block-end) (not blockstack) (eq funcount 0))
      (list t (+ (current-indentation)
                 (if label-at-bol 1 0))))
     ((and (eq indent-type 'tradfn-start)
           (eq funcount 0))
      (list t (skip-chars-forward " ∇")))
     ((bobp)
      (list t (dyalog-leading-indentation)))
     (t
      (list nil 0)))))

(defun dyalog-indent-status (dfunstack)
  "Return a list of information on the current indentation status.
DFUNSTACK is a list of open dfun blocks at point. The list of
information returned includes whether we are at the start of a
block, or the end (or at a pause inside a block), and the name of
the delimiter that triggers the starting or ending of a
block (e.g. \":If\" or \"∇\"."
  (let ((next-line (min (point-max) (1+ (line-end-position)))))
    (cond
     ((dyalog-on-tradfn-header)
      (list :indent-type 'tradfn-start :delimiter nil :label-at-bol nil
            :next-line next-line))
     ((looking-at dyalog-naked-nabla)
      (list :indent-type 'tradfn-end :delimiter nil :label-at-bol nil
            :next-line next-line))
     (t
      (let* ((indent-parse (dyalog-indent-parse-line dfunstack nil))
             (keyword      (plist-get indent-parse :keyword))
             (indent-type  (plist-get indent-parse :indent-type))
             (label        (plist-get indent-parse :label))
             (next-line    (plist-get indent-parse :next-line)))
        (list :indent-type indent-type :delimiter keyword
              :label-at-bol label :next-line next-line
              :dfunstack (plist-get indent-parse :dfunstack)))))))

(defun dyalog-search-indent-root (at-root-function)
  "Given function AT-ROOT-FUNCTION, search backwards for the root indent.
AT-ROOT-FUNCTION assumes point is at the beginning of a logical
line and returns t when point is at the line containing the
indentation root.  For example if we are indenting a :EndFor,
AT-ROOT-FUNCTION returns t when we have reached the corresponding :For."
  (let* ((indentation nil)
         (blockstack ())
         (funcount 0))
    (save-excursion
      (while (not indentation)
        ;; TODO: We should probably skip past d-funs
        (dyalog-previous-logical-line)
        (let* ((status (dyalog-indent-status nil))
               (keyword (plist-get status :delimiter))
               (indent-type (plist-get status :indent-type))
               (root (apply at-root-function
                            (list blockstack status funcount)))
               (at-root (car root)))
          (setq indentation
                (cond
                 (at-root
                  (nth 1 root))
                 ((eq 'block-end indent-type)
                  (progn
                    (push (or (dyalog-matching-delimiter keyword)
                              dyalog-any-delimiter)
                          blockstack)
                    nil))
                 ((eq 'block-start indent-type)
                  (progn
                    (when (or (equal dyalog-any-delimiter (car blockstack))
                              (compare-strings keyword  nil nil
                                               (car blockstack) nil nil
                                               'ignore-case))
                      (pop blockstack))
                    nil))
                 ((eq 'tradfn-end indent-type)
                  (setq funcount (1+ funcount))
                  nil)
                 ((eq 'tradfn-start indent-type)
                  (setq funcount (1- funcount))
                  nil)))
          (when (and (not indentation) (bobp))
            (setq indentation (dyalog-leading-indentation)))))
      (list :indent indentation :has-label nil
            :funcount funcount :blockstack blockstack))))

(defun dyalog-calculate-dfun-indent ()
  "Calculate the indentation amount for a line in a dfun."
  (let* ((start (point))
         (line-start (+ start (skip-syntax-forward "-"))))
    (save-excursion
      (let ((containing-brace (scan-lists start -1 1)))
        (if (< containing-brace line-start)
            (progn
              (goto-char containing-brace)
              (dyalog-relative-indent
                      (if (equal (char-after line-start) ?})
                          0 1)))
          (dyalog-leading-indentation))))))

(defun dyalog-calculate-indent ()
  "Calculate the amount of indentation for the current line.
Return a plist with the indent in spaces, and whether the current
line has a label."
  (save-excursion
    (move-beginning-of-line nil)
    (let* ((dfunstack (dyalog-current-dfun-stack))
           (indent-status (dyalog-indent-status dfunstack))
           (indent-type (plist-get indent-status :indent-type))
           (label (plist-get indent-status :label-at-bol))
           (keyword (plist-get indent-status :delimiter))
           (indent-info nil)
           (current-line-indent-info nil))
      (setq indent-info
            (cond
             ((bobp)
              (list :indent (dyalog-leading-indentation)
                    :has-label nil
                    :is-comment nil
                    :funcount 0
                    :blockstack nil))
             (dfunstack
              (list :indent (dyalog-calculate-dfun-indent)
                    :has-label nil
                    :is-comment nil
                    :funcount 0
                    :dfunstack dfunstack))
             (label
              (let* ((label-indent-info (dyalog-search-indent-root
                                         #'dyalog-indent-stop-tradfn))
                     (label-indent      (plist-get label-indent-info :indent))
                     (old-label         (dyalog-remove-label))
                     (rest-indent-info  (dyalog-calculate-indent)))
                ;; A label is always aligned 1 space to the left of the
                ;; surrounding tradfn, and since we search for tradfn
                ;; delimiters, we align to the nabla. So if we've reached the
                ;; beginning of the buffer, we subtract one and if we've
                ;; aligned to the nabla we add one.
                (setq label-indent (max 0 (+ label-indent
                                      (if (= label-indent
                                             (dyalog-leading-indentation))
                                          -1
                                        1))))
                (insert old-label)
                (plist-put rest-indent-info :has-label t)
                (plist-put rest-indent-info :label-indent label-indent)
                rest-indent-info))
             ((eq indent-type 'comment)
              (if dyalog-indent-comments
                  (let ((l (dyalog-search-indent-root
                            #'dyalog-indent-search-stop-generic)))
                    (plist-put l :is-comment t))
                (list :indent (current-indentation)
                      :has-label nil
                      :is-comment t
                      :funcount 0
                      :blockstack nil)))
             (keyword
              (dyalog-search-indent-root
               (dyalog-indent-search-stop-function keyword)))
             ((eq 'tradfn-end indent-type)
              (dyalog-search-indent-root #'dyalog-indent-stop-tradfn))
             ((eq 'tradfn-start indent-type)
              (dyalog-search-indent-root #'dyalog-indent-stop-tradfn))
             (t
              (dyalog-search-indent-root #'dyalog-indent-search-stop-generic))))
      (setq current-line-indent-info
            (dyalog-indent-from-indent-type indent-status indent-info
                                            (current-indentation)))
      (unless (eq 'blank indent-type)
        (plist-put indent-info :next-indent
                   (plist-get current-line-indent-info :next-indent)))
      indent-info)))

(defun dyalog-leading-indentation ()
  "Return the number of spaces to indent by in the current buffer.
This varies depending of the type of object being edited,
namespaces or classes have no extra leading indentation, but functions have
one extra space, to be consistent with separating multiple
functions with ∇."
  (pcase (or dyalog-buffer-type (dyalog-guess-buffer-type))
    (`space-or-class 0)
    (`function 1)
    (`unknown dyalog-leading-spaces)))

(defun dyalog-indent-line-with (indent-info)
  "Indent the current line according to INDENT-INFO.
INDENT-INFO is the return value from `dyalog-calculate-indent'."
  (let* ((indent     (plist-get indent-info :indent))
         (has-label  (plist-get indent-info :has-label))
         (is-comment (plist-get indent-info :is-comment)))
      (if has-label
          (let* ((old-label    (dyalog-remove-label))
                 (label-length (length old-label))
                 (label-indent (plist-get indent-info :label-indent)))
            (if (and (not dyalog-indent-comments) is-comment)
                (setq indent (- indent label-indent))
              (if (> label-length indent)
                  ;; Label is longer than required indentation, so line
                  ;; should be flush with label
                  (setq indent 0)
                (setq indent (max 0
                                  (- indent (+ label-length label-indent))))))
            ;; Keywords are never flush with the label, since they start with
            ;; a colon, and the label ends with one
            (beginning-of-line)
            (when (looking-at-p "^ *:")
              (setq indent (max 1 indent)))
            (indent-line-to indent)
            (beginning-of-line)
            (insert (make-string label-indent ? ))
            (insert old-label)
            (back-to-indentation))
        (indent-line-to indent))))

(defun dyalog-indent-line ()
  "Indent the current line."
  (interactive)
  (let* ((restore-pos (> (current-column) (current-indentation)))
         (old-pos (point))
         (indent-info (dyalog-calculate-indent)))
    (dyalog-indent-line-with indent-info)
    (when restore-pos
      (goto-char (min old-pos (line-end-position))))))

(defun dyalog-current-tradfn-indentation ()
  "Return the column 0 indentation of the tradfn point is in, otherwise nil."
  (let* ((tradfn-info (dyalog-tradfn-info))
         (tradfn-name (car tradfn-info))
         (end-of-header (nth 3 tradfn-info)))
    (when (not (zerop (length tradfn-name)))
      (save-excursion
        (goto-char end-of-header)
        (beginning-of-line)
        (skip-chars-forward " ∇")
        (current-column)))))

(defun dyalog-current-dfun-stack ()
  "Return a list of open dynamic functions delimiters."
  (let ((in-dfun nil)
        (dfunstack ()))
    (save-excursion
      (while (setq in-dfun (dyalog-in-dfun))
        (push "{" dfunstack)
        (goto-char (plist-get in-dfun :start)))
      dfunstack)))

(defun dyalog-indent-region (start end)
  "Indent every line in the current region.
START and END specify the region to indent."
  (let ((deactivate-mark nil)
        (indent-info nil))
    (save-excursion
      (goto-char end)
      (setq end (point-marker))
      (goto-char start)
      (goto-char (setq start (line-beginning-position)))
      (forward-line -1)
      (setq indent-info (dyalog-calculate-indent))
      (plist-put indent-info :tradfn-indent
                 (dyalog-current-tradfn-indentation))
      (plist-put indent-info :nabla-indent
                 (dyalog-current-nabla-indent))
      (when (= (point) start)
        ;; if start is on the first line of the buffer, we zero
        ;; next-indent, since we haven't actually initialized indent-info
        ;; with values from a previous line.
        (plist-put indent-info :next-indent 0))
      (goto-char start)
      (while (< (point) end)
        (setq indent-info (dyalog-indent-update indent-info))
        (when (bolp)
          (save-excursion
            (dyalog-indent-line-with indent-info)))
        (dyalog-next-logical-line))
      (move-marker end nil))
    nil))

(defun dyalog-indent-update (indent-info)
  "Calculate an updated indentation after the current logical line.
INDENT-INFO is a plist of indentation information, on the same
form as the return value from `dyalog-calculate-indent'. Return
the updated plist of indentation information."
  (let* ((dfunstack (plist-get indent-info :dfunstack))
         (indent-status (dyalog-indent-status dfunstack))
         (label         (plist-get indent-status :label-at-bol))
         (current-indent nil))
    (plist-put indent-info :is-comment nil)
    (plist-put indent-info :dfunstack (plist-get indent-status
                                                 :dfunstack))
    (if label
        (let* ((label-indent (max 0 (1- (or (plist-get indent-info
                                                       :tradfn-indent)
                                            (dyalog-leading-indentation))))))
          (plist-put indent-info :has-label t)
          (plist-put indent-info :label-indent label-indent)
          (setq current-indent
                (save-excursion
                  (max
                   (- (+ (skip-chars-forward "^:")
                         (skip-chars-forward ":")
                         (skip-chars-forward " \t"))
                      (length label))
                   0))))
      (progn
        (plist-put indent-info :has-label nil)
        (setq current-indent (current-indentation))))
    (setq indent-info (dyalog-indent-from-indent-type indent-status
                                                      indent-info
                                                      current-indent))
    indent-info))

(defun dyalog-indent-from-indent-type (indent-status indent-info
                                                     current-indent)
  "Calculate an updated indentation, disregarding any label.
INDENT-STATUS is the indentation status of the current logical
line (as returned by `dyalog-indent-status'). INDENT-INFO is a
plist of indentation information, in the same form as the return
value from `dyalog-calculate-indent'. CURRENT-INDENT is the
current indentation in spaces, disregarding any label.  Return the
updated plist of indentation information."
  (let* ((indent-type (plist-get indent-status :indent-type))
         (delimiter     (plist-get indent-status :delimiter))
         (blockstack    (plist-get indent-info :blockstack))
         (next-indent   (or (plist-get indent-info :next-indent) 0))
         (previous-indent (plist-get indent-info :indent))
         (indent        (+ previous-indent
                           next-indent))
         (tradfn-indent (plist-get indent-info :tradfn-indent))
         (nabla-indent  (plist-get indent-info :nabla-indent))
         (ret (copy-sequence indent-info)))
    (cond
     ((eq 'comment indent-type)
      (if (not dyalog-indent-comments)
          (progn
            (setq next-indent (- indent current-indent)
                  indent      current-indent)
            (plist-put ret :is-comment t))
        (setq next-indent 0)))
     ((eq 'block-end indent-type)
      (progn
        ;; (unless (string-equal (car blockstack)
        ;;                       (dyalog-matching-delimiter delimiter))
        ;;   (error "Non matching delimiter"))
        ;; We assume delimiters match, since the region might cover
        ;; only part of matched delimiters
        (when blockstack
          (pop blockstack))
        (setq indent      (- indent tab-width)
              next-indent 0)))
     ((eq 'block-start indent-type)
      (progn
        (push delimiter blockstack)
        (setq next-indent tab-width)))
     ((eq 'block-pause indent-type)
      (setq indent      (- indent tab-width)
            next-indent tab-width))
     ((eq 'dfun-start indent-type)
      (setq next-indent tab-width))
     ((eq 'dfun-end indent-type)
      (setq next-indent (- tab-width)))
     ((eq 'dfun-end-and-dedent indent-type)
      (setq indent      (- indent tab-width)
            next-indent 0))
     ((eq 'tradfn-end indent-type)
      (setq tradfn-indent nil
            indent (or nabla-indent indent)
            next-indent 0
            nabla-indent nil))
     ((eq 'tradfn-start indent-type)
      (let ((nabla-at-bol (looking-at-p " *∇")))
        (setq tradfn-indent (if nabla-at-bol
                                (+ (save-excursion
                                     (skip-chars-forward "^∇")
                                     (skip-chars-forward " ∇"))
                                   indent)
                              (save-excursion
                                (skip-chars-forward " ")))
              next-indent   (- tradfn-indent indent)
              nabla-indent  (if nabla-at-bol
                                indent
                              previous-indent))))
     ((eq 'blank indent-type)
      (setq next-indent indent
            indent 0))
     ;; TODO: dfuns
     (t
      (setq next-indent 0)))
    (plist-put ret :blockstack blockstack)
    (plist-put ret :indent indent)
    (plist-put ret :next-indent next-indent)
    (plist-put ret :tradfn-indent tradfn-indent)
    (plist-put ret :nabla-indent nabla-indent)
    ret))

(defun dyalog-nabla-indent ()
  "Return the current indentation of the nabla preceding a tradfn definition.
Assumes point is at the start of a line with a tradfn header."
  (save-excursion
    (if (looking-at-p "^ *∇")
        (skip-chars-forward " ")
      (forward-line -1)
      (skip-chars-forward " "))))

(defun dyalog-current-nabla-indent ()
  "Return the indentation of the nabla preceding the tradfn defun point is in."
  (let* ((info  (dyalog-tradfn-info))
         (name  (nth 0 info))
         (end-of-header (nth 3 info)))
    (when (and name (not (equal "" name)))
      (save-excursion
        (goto-char end-of-header)
        (beginning-of-line)
        (dyalog-nabla-indent)))))

(defun dyalog-remove-label ()
  "Remove the current label token at beginning of line, and return it."
  (beginning-of-line)
  (skip-chars-forward " \t")
  (let* ((start (point))
         (end (+ start 1 (skip-chars-forward "A-Za-z_0-9")))
         (label (buffer-substring-no-properties start end)))
    (delete-region start end)
    (goto-char start)
    label))

(defun dyalog-guess-buffer-type ()
  "Guess whether the current buffer is a function or namespace/class.
Return 'space-or-class if it looks like a namespace or class, 'unkown if the buffer
type is unknown and 'function if it looks like a function definition."
  (save-excursion
    (goto-char (point-min))
    (cond
     ((looking-at-p " *:")
      'space-or-class)
     ((or (dyalog-on-tradfn-header)
          (looking-at-p (concat " *" dyalog-name " *← *{")))
      'function)
     (t
      'unknown))))

(defun dyalog-fix-whitespace-before-save ()
  "Clean up whitespace in the current buffer before saving."
  (when (and (eq major-mode 'dyalog-mode) dyalog-fix-whitespace-before-save)
    (dyalog-fix-whitespace)))

(defun dyalog-fix-whitespace ()
  "Clean up white space in the current buffer like Dyalog does."
  (interactive)
  (message "Cleaning up whitespace...")
  (let ((dyalog-indent-comments nil)
        (punctuation-char "\\s.\\|\\s(\\|\\s)"))

    (save-excursion
      (delete-trailing-whitespace)
      ;; Reduce all runs of whitespace to a single space, except when
      ;; preceeded by a newline, succeeded by a comment character, or if
      ;; inside a comment or string literal
      (goto-char (point-min))
      (while (re-search-forward "\\([^ \r\n]\\)\\(  +\\)\\([^⍝ \r\n]\\)" (point-max) t)
        (let ((ws-start (match-beginning 2)))
          (unless (dyalog-in-comment-or-string ws-start)
            (replace-match "\\1 \\3"))))
      ;; Remove spaces before punctuation
      (goto-char (point-min))
      (while (re-search-forward (concat "\\([^ \r\n]\\)" "\\( +\\)"
                                        "\\(" punctuation-char "\\)")
                                (point-max)
                                t)
        (let ((start (match-beginning 0))
              (ws-start (match-beginning 2)))
          (unless (or (string-equal "⍝" (match-string 3))
                      (dyalog-in-comment-or-string ws-start)
                      (string-match "[∇⋄⍬]" (match-string 3))
                      (string-match "[∇⋄⍬]" (match-string 1))
                      (and (string-equal ":" (substring (match-string 3) 0 1))
                           (dyalog-in-keyword (match-beginning 3)))
                      (dyalog-in-keyword (match-beginning 1)))
            (replace-match "\\1\\3")
            (goto-char start))))
      ;; Now remove spaces after punctuation unless they are followed by a
      ;; comment. We can't remove spaces both before and after punctuation in
      ;; one pass because matches might overlap.
      (goto-char (point-min))
      (while (re-search-forward (concat "\\(" punctuation-char "\\)"
                                        "\\( +\\)" "\\([^⍝ \r\n]\\)")
                                (point-max)
                                t)
        (let ((start (match-beginning 0))
              (ws-start (match-beginning 2))
              (match-1  (match-string 1))
              (match-3  (match-string 3))
              (match-3-start (match-beginning 3)))
          (unless (or (string-equal "⍝" match-1)
                      (dyalog-in-comment-or-string ws-start)
                      (string-match "[∇⋄⍬]" match-1)
                      (string-match "[∇⋄⍬]" match-3)
                      (and (string-match "[⍺⍵]\\'" match-1)
                           (string-match "\\`⎕" match-3))
                      (and (string-equal ":" (substring match-3 0 1))
                           (dyalog-in-keyword match-3-start)))
            (replace-match "\\1\\3")
            (goto-char start))))
      (dyalog-indent-buffer))))

(defun dyalog-indent-buffer ()
  "Indent the current buffer."
  (save-excursion
    (mark-whole-buffer)
    (indent-region (region-beginning) (region-end))))

;;; Defun recognition and navigation

(defun dyalog-imenu-create-index ()
  (reverse (dyalog-functions-in-buffer)))

(defun dyalog-functions-in-buffer ()
  "Return an alist of names and positions for defuns in the current buffer."
  (save-excursion
    (let ((funs ())
          (done nil)
          (space-scan nil))
      (goto-char (point-min))
      (while (not done)
        (setq space-scan (dyalog-update-space-scan space-scan (point)))
        (let* ((info (cadr (dyalog-defun-info (/= (point) (point-min)))))
               (name (plist-get info :name))
               (start (plist-get info :start))
               (current-space (dyalog-current-space space-scan))
               (space-name (mapconcat 'identity current-space "."))
               (full-name (if current-space
                              (concat space-name "." name)
                            name)))
          (if (not (zerop (length name)))
              (progn
                (push (cons full-name (copy-marker start)) funs)
                (goto-char (plist-get info :end))
                (setq done (unless (looking-at-p dyalog-tradfn-header)
                             (not (dyalog-next-defun)))))
            (setq done (not (dyalog-next-defun))))))
      funs)))

(defun dyalog-update-space-scan (space-scan pos)
  "Update SPACE-SCAN incrementally, given that point is at POS"
  (save-excursion
    (let* ((space-stack (plist-get space-scan :stack))
           (max-reached (plist-get space-scan :max-reached))
           (trimmed-stack (dyalog-trim-passed-spaces space-stack pos))
           (top (car trimmed-stack))
           (start (plist-get top :start))
           (end   (plist-get top :end)))
      (if (and (not end) (or (not start) (> pos start))
               (or (not max-reached) (< max-reached (point-max))))
          (progn
            (goto-char (or max-reached pos))
            (dyalog-add-spaces-to-stack trimmed-stack pos))
        (list :stack trimmed-stack :max-reached max-reached)))))

(defun dyalog-trim-passed-spaces (space-stack pos)
  "Remove any spaces in SPACE-STACK that were closed before position POS."
  (let ((done nil))
    (while (not done)
      (let* ((top (car space-stack))
             (end (plist-get top :end)))
        (if (and end (> pos end))
            (setq space-stack (cdr space-stack))
          (setq done t))))
    space-stack))

(defun dyalog-add-spaces-to-stack (space-stack pos)
  "Add any spaces found between MAX-REACHED and POS to SPACE-STACK."
  (let ((reached nil)
        (done nil)
        (space-scan nil))
    (while (not done)
      (setq space-scan  (dyalog-next-space-or-class space-stack)
            space-stack (plist-get space-scan :stack)
            reached (plist-get space-scan :max-reached)
            done (> reached pos)))
    space-scan))

(defun dyalog-next-space-or-class (&optional space-stack)
  "Move forward to the start or end of the next namepace or class def."
  (let ((done nil)
        (ret )
        (hit nil))
    (dyalog-skip-comment-or-string)
    (while (not done)
      (if (setq hit (re-search-forward
                     (concat ":\\(End\\(Namespace\\|Class\\)\\)\\|"
                             "\\(\\(Namespace\\|Class\\) +"
                             "\\(" dyalog-name "\\)\\)") nil 'no-errors))
          (setq done (not (dyalog-in-comment-or-string)))
        (setq done t)))
    (setq ret
          (if hit
              (let* ((space-name (match-string-no-properties 5))
                     (endword    (match-string-no-properties 1))
                     (startword  (match-string-no-properties 4))
                     (pos        (match-end 0))
                     (start-type (when startword
                                   (dyalog-type-char-to-symbol (aref startword 0))))
                     (end-type   (when endword
                           (dyalog-type-char-to-symbol (aref endword 3)))))
              (if (and space-name hit)
                  (let ((hit
                         (list :name space-name :start pos :type start-type)))
                    (push hit space-stack)
                    (list :stack space-stack :max-reached pos))
                (if space-stack
                    (let* ((top (car space-stack))
                           (type (plist-get top :type)))
                      (if (equal type end-type)
                          (progn
                            (plist-put top :end pos)
                            (list :stack (cons top (cdr space-stack))
                                  :max-reached pos))
                        (list :stack space-stack :max-reached pos)))
                  (list :stack space-stack :max-reached (point)))))
            (list :stack space-stack :max-reached (point))))
    ret))

(defun dyalog-type-char-to-symbol (type-char)
  (cond
   ((= type-char ?N)
    'namespace)
   ((= type-char ?C)
    'class)))

(defun dyalog-current-space (space-scan)
  (let ((pos (point))
        (stack (plist-get space-scan :stack))
        (space nil))
    (while stack
      (let* ((top (car stack))
             (name  (plist-get top :name))
             (start (plist-get top :start))
             (end   (plist-get top :end)))
        (if (and end (> pos end))
            (setq stack ())
          (when (and (> pos start) (or (not end) (< pos end)))
              (push name space))
          (setq stack (cdr stack)))))
    space))


(defun dyalog-beginning-of-dfun ()
  "Move backward to the beginning of a dynamic function definition.
Assumes that point is within a dynamic function definition."
  (dyalog-skip-comment-or-string)
  (with-syntax-table dyalog-dfun-syntax-table
    (condition-case nil
        (goto-char (scan-lists (point) -1 1))
      (scan-error nil))))

(defun dyalog-previous-defun (&optional tradfn-only)
  "Move backward to the start of a function definition.
If TRADFN-ONLY is t, only consider traditional function definitions.
Return t if a function definition was found, otherwise return nil."
  ;; Point can be anywhere when this function is called
  (let ((done nil)
        (first-hit nil)
        (found nil)
        (start (point))
        (dfun-info (dyalog-in-dfun)))
    (if dfun-info
        (progn
          (goto-char (plist-get dfun-info :start))
          t)
      (while (not done)
        (skip-chars-backward (if tradfn-only "^∇" "^∇{}"))
        (if (or (bobp) (not (dyalog-in-comment-or-string)))
            (progn
              (setq done t)
              (if (dyalog-on-tradfn-header 'only-after-nabla)
                  (progn
                    (skip-chars-backward "^∇")
                    (ignore-errors (backward-char))
                    (setq first-hit  nil
                          found      t))
                (progn
                  (cond
                   ((looking-back "{")
                    (backward-char)
                    (if (not first-hit)
                        (setq first-hit (point)))
                    (setq done nil))
                   ((looking-back "}")
                    (backward-sexp)
                    (if (not first-hit)
                        (setq first-hit (point)))
                    (setq done nil))
                   ((looking-back "∇")
                    (backward-char)
                    (if first-hit
                        (progn
                          (setq found t
                                done  t)
                          (goto-char first-hit))
                      (setq done nil)))
                   ((bobp)
                    (when first-hit
                      (setq found t)
                      (goto-char first-hit)))))))
          (ignore-errors (backward-char))))
        (and found (not (= (point) start))))))

(defun dyalog-next-defun (&optional limit)
  "Move to the beginning of the next defun.
If supplied, LIMIT limits the search."
  (let ((lim (or limit (point-max)))
        (done nil)
        (found nil))
    (when (looking-at "[{∇]")
      (ignore-errors (forward-char)))
    (while (not done)
      (skip-chars-forward "^∇{" lim)
      (cond
       ((>= (point) lim)
        (setq found nil
              done  t))
       ((dyalog-in-comment-or-string)
        (ignore-errors (forward-char)))
       ((dyalog-on-tradfn-header 'only-after-nabla)
        (setq found t
              done  t))
       (t
        (cond
         ((looking-at "{")
          (setq found t
                done  t))
         ((looking-at "∇")
          (ignore-errors (forward-char)))))))
    found))

(defun dyalog-beginning-of-defun (&optional arg)
  "Move backward to the beginning of a function definition.
If supplied, ARG moves that many defuns back."
  (interactive "^p")
  (unless arg (setq arg 1))
  (if (< arg 0)
        (while (< arg 0)
          (dyalog-next-defun)
          (cl-incf arg))
      (while (> arg 0)
        (dyalog-previous-defun)
        (cl-decf arg))))

(defun dyalog-end-of-defun (&optional bound)
  "Move forward to the end of a function definition.
If it is supplied, BOUND limits the search."
  ;; We can assume point is at the start of a defun when
  ;; this function is called.
  (let ((end (or bound (point-max)))
        (done nil)
        (dfun-mode
         (and (looking-at "{")
              (not (dyalog-on-tradfn-header 'only-after-nabla)))))
    (if dfun-mode
        (forward-sexp)
      (ignore-errors (forward-char)) ; skip past nabla
      (while (not done)
        (if (not (re-search-forward "^ *∇" end t))
            (progn
              (goto-char end)
              (setq done t))
          (when (setq done (not (dyalog-in-dfun)))
            (ignore-errors (backward-char 1))
            (if (looking-at dyalog-tradfn-header)
                (ignore-errors (backward-char 1))
              (ignore-errors (forward-char 1)))))))))

(defun dyalog-end-of-tradfn (&optional bound)
  "Move forward to the end of the function definition starting at point.
If it is supplied, BOUND limits the search."
  (let ((end (or bound (point-max)))
        (done nil))
    (ignore-errors (forward-char))  ; skip past nabla
    (while (not done)
      (if (not (re-search-forward "{\\|\\(^ *∇\\)" end t))
          (progn
            (goto-char end)
            (setq done t))
        (goto-char (match-beginning 0))
        (skip-chars-forward " ")
        (cond
         ((dyalog-in-comment-or-string)
          (ignore-errors (forward-char)))
         ((looking-at-p "{")
          (forward-sexp))
         ((looking-at-p "∇")
          (setq done t))
         (t
          (ignore-errors (forward-char))))
        (setq done (or done (>= (point) end)))))))

(defun dyalog-skip-comment-or-string (&optional context)
  "If point is in a comment or string, move backward out of it.
CONTEXT is the result of `syntax-ppss' at point, or nil."
  (let ((ctx (syntax-ppss-context (or context (syntax-ppss)))))
    (cond
     ((eq ctx 'string) (re-search-backward "\\s\""))
     ((eq ctx 'comment) (re-search-backward "\\s<")))))

(defun dyalog-dfun-name ()
  "If point is inside a dynamic function return the functions name.
If point is inside an anonymous function, return \"\", and if it
isn't inside a dynamic function, return nil"
  (interactive)
  (plist-get (dyalog-dfun-info) :name))

  
(defun dyalog-dfun-info (&optional point-is-at-dfun-start)
  "Return the name, start and end position of the dfun point is in.
If POINT-IS-AT-START-OF-DEFUN is t, point must be at the nabla or
brace starting the defun, and no backwards search for the
function definition start is made, which improves performance.
The return value is a plist with :name, :start and :end
properties. If point isn't inside a dfun, return nil. If the dfun
is open (i.e. has no closing brace, :end is nil. If the dfun is
anonymous, :name is \"\"."
  (save-excursion
    (let ((in-dfun (dyalog-in-dfun point-is-at-dfun-start))
          (dfun-name nil))
      (if in-dfun
          (progn
            (goto-char (plist-get in-dfun :start))
            (setq dfun-name
                  (if (looking-back (concat "\\_<\\(" dyalog-name "\\) *← *")
                                    (line-beginning-position)
                                    t)
                      (match-string-no-properties 1)
                    ""))
            (setq dfun-name
                  (condition-case nil
                      (progn
                        (forward-sexp)
                        (if (looking-at " *[^\r\n ⋄]")
                            ""
                          dfun-name))
                    (scan-error dfun-name)))
            (plist-put in-dfun :name dfun-name)
            in-dfun)
          nil))))

(defun dyalog-in-dfun (&optional point-is-at-dfun-start)
  "If point is inside a dfun, return a plist with it's start and end position.
If point isn't inside a dfun, return nil."
  (progn ;; with-syntax-table can't be at defun top-level apparently...
    (with-syntax-table dyalog-dfun-syntax-table
      (if (and point-is-at-dfun-start (looking-at-p "{"))
          (list :start (point)
                :end (save-excursion
                       (forward-sexp)
                       (point)))
        (let* ((pos (point))
               (ppss (syntax-ppss))
               (start-of-containing-parens (nth 1 ppss)))
          (when (and start-of-containing-parens
                     (not (eq (char-after start-of-containing-parens) ?{)))
            ;; When syntax-pps is called during jit-lock, it sometimes ignores
            ;; the syntax-table, and treats regular parens as syntactical
            ;; parens. Calling (syntax-ppss-flush-cache) doesn't seem to help,
            ;; so instead fall back on scan-lists, which seems to work. 
            (setq start-of-containing-parens
                  (condition-case nil
                      (goto-char (scan-lists (point) -1 1))
                    (scan-error nil))))
          (if start-of-containing-parens
              (save-excursion
                (goto-char start-of-containing-parens)
                (if (not (dyalog-on-tradfn-header 'only-after-nabla))
                    (let ((end (condition-case nil
                                   (progn
                                     (forward-sexp)
                                     (point))
                                 (scan-error nil))))
                      (unless (or (< pos start-of-containing-parens)
                                  (and end (<= end pos)))
                        ;; Sometimes, when syntax-ppss is called during
                        ;; jit-lock, it breaks and gives erronous results,
                        ;; saying we are inside parens when we are not. We
                        ;; detect this by checking if the the sexp we're
                        ;; supposed to be in ends before, or begins after the
                        ;; position we started parsing at.
                        (list :start start-of-containing-parens
                              :end end)))
                  nil))
            nil))))))

(defun dyalog-current-defun ()
  "Return the name of the defun point is in."
  (let ((dfun-name (dyalog-dfun-name)))
    (or dfun-name (car (dyalog-tradfn-info)))))

(defun dyalog-on-tradfn-header (&optional only-after-nabla)
  "Return t if point is on a tradfn header line, otherwise return nil.
If ONLY-AFTER-NABLA is t, only return t when point is after
the nabla in the tradfn header."
  (save-excursion
    (let ((start (point))
          (min (line-beginning-position 0)))
      (forward-line)
      (end-of-line)
      (if (re-search-backward dyalog-tradfn-header min t)
          (progn
            (goto-char (match-end 0))
            (and (>= start (if only-after-nabla
                               (match-beginning 0)
                             (min (match-beginning 0)
                                  (line-beginning-position))))
                 (<= start (line-end-position))))
        nil))))

(defun dyalog-tradfn-info (&optional point-is-at-start-of-defun)
  "Return a list of information on the tradfn defun point is in.
This name is only valid if point isn't inside a dfn. The list
contains the name of the function a list containing the names of
the arguments, a list containing localized names, the character
position where the function header ends and the character
position where the defun ends. If POINT-IS-AT-START-OF-DEFUN is
t, point must be at the nabla starting the tradfn definition, and
no search for the function definition start is made, which
improves performance."
  (save-excursion
    (let ((start-pos (point)))
      (unless point-is-at-start-of-defun
        (dyalog-previous-defun 'tradfn-only)
        (when (not (looking-at "∇"))
          (forward-line -1)))         ; Nabla is on its own line
      (if (re-search-forward dyalog-tradfn-header nil t)
          (let* ((start-of-defun (match-beginning 0))
                 (tradfn-name (match-string-no-properties 1))
                 (retval (save-match-data
                           (split-string (or (match-string-no-properties 2) ""))))
                 (larg (match-string-no-properties 3))
                 (rarg (save-match-data
                         (split-string (or (match-string-no-properties 4) ""))))
                 (localstart (match-end 5))
                 (left-operand  (match-string-no-properties 6))
                 (tradop-name   (match-string-no-properties 7))
                 (right-operand (match-string-no-properties 8))
                 (name (or tradop-name tradfn-name))
                 (end-of-header (line-end-position))
                 (args (list retval (when larg (list larg)) rarg))
                 (operands (remq nil (list left-operand right-operand)))
                 (locals nil)
                 (end-of-defun 0))
            (dyalog-end-of-tradfn)
            (setq end-of-defun (point))
            (if (or (< end-of-defun start-pos) (< start-pos start-of-defun))
                (list "" nil nil 0 0 0 nil)
              (progn
                (setq locals
                      (split-string
                       (buffer-substring-no-properties localstart end-of-header)
                       "[; ]" 'omit-nulls))
                (list name args locals end-of-header end-of-defun
                      start-of-defun operands))))
        (list "" nil nil 0 0 0 nil)))))

;;; Font Lock

(defun dyalog-defun-info (&optional point-is-at-start-of-defun)
  "Return information on the defun at point. If
POINT-IS-AT-START-OF-DEFUN is t, point must be at the nabla or
brace starting the defun, and no backwards search for the
function definition start is made, which improves performance."
  (save-excursion
    (if (and point-is-at-start-of-defun
             (not (looking-at-p "[{∇]")))
        (list 'tradfn (list "" nil nil 0 0 0 nil))
      (when (and (not point-is-at-start-of-defun) (looking-at-p "{"))
        (forward-char))
      (let ((dfun-info (dyalog-dfun-info point-is-at-start-of-defun)))
        (if dfun-info
            (list 'dfun dfun-info)
          (list 'tradfn
                (progn
                  (unless point-is-at-start-of-defun
                    (ignore-errors (forward-char)))
                  (let* ((info
                          (dyalog-tradfn-info point-is-at-start-of-defun))
                         (start (nth 5 info))
                         (name (car info))
                         (args (nth 1 info))
                         (locals (nth 2 info))
                         (end-of-header (nth 3 info))
                         (end (nth 4 info))
                         (operands (nth 6 info)))
                    (list :start start :name name :args args
                          :locals locals :end-of-header end-of-header
                          :end end :operands operands)))))))))

(defun dyalog-local-names (defun-info)
  "Return a list of local names given return value from `dyalog-defun-info'."
  (let ((args (apply 'append (plist-get defun-info :args)))
        (operands (plist-get defun-info :operands))
        (localizations (plist-get defun-info :locals)))
    (append args operands localizations)))

(defun dyalog-fontify-dfun (dfun-info start end)
  "Fontify the dynamic function defined by DFUN-INFO.
START and END delimit the region to fontify."
  (when dfun-info
    (let* ((dfunstart (plist-get dfun-info :start))
           (dfunend   (plist-get dfun-info :end))
           (rx (concat "\\_<\\(" dyalog-name "\\)\\_>"))
           (limit (min (or dfunend end) end)))
      (goto-char (max dfunstart start))
      (while (re-search-forward rx limit t)
        (let* ((symbol-start (match-beginning 0))
               (symbol-end (match-end 0))
               (state (syntax-ppss))
               (context (syntax-ppss-context state))
               (in-string (eq 'string context))
               (in-comment (eq 'comment context))
               (sysvar (eq ?⎕ (char-after symbol-start)))
               (face (if sysvar
                         'dyalog-local-system-name
                       'dyalog-local-name)))
          (unless (or in-string in-comment)
            (put-text-property symbol-start symbol-end
                               'face
                               face))))
      (goto-char (min dfunend end)))))

(defun dyalog-fontify-tradfn (info start end)
  "Fontify the traditional function defined by INFO.
START and END delimit the region to fontify."
  (let ((fname (plist-get info :name)))
    (when (and fname (not (equal fname "")))
      (let* ((locals (dyalog-local-names info))
             (end-of-header (plist-get info :end-of-header))
             (end-of-defun (plist-get info :end))
             (limit (min end-of-defun end))
             (rx (concat "\\_<\\("
                         (mapconcat 'identity locals "\\|")
                         "\\)\\_>"))
             (fontify-start (max end-of-header start)))
        (goto-char fontify-start)
        (while (re-search-forward rx limit t)
          (let* ((symbol-start (match-beginning 0))
                 (symbol-end (match-end 0))
                 (state (syntax-ppss))
                 (context (syntax-ppss-context state))
                 (in-string (eq 'string context))
                 (in-comment (eq 'comment context))
                 (sysvar (eq ?⎕ (char-after symbol-start)))
                 (face (if sysvar
                           'dyalog-local-system-name
                         'dyalog-local-name)))
            (unless (or in-string in-comment)
              (put-text-property symbol-start symbol-end
                                 'face
                                 face)
              (while (and (equal ?. (char-after symbol-end))
                          (looking-at (concat "\\." dyalog-name)))
                (put-text-property (match-beginning 0)
                                   (match-end 0)
                                   'face
                                   face)
                (goto-char (match-end 0))
                (setq symbol-end (point))))))
        ;; Now we need to fontify any names inside dfns defined inside this
        ;; tradfn
        (goto-char fontify-start)
        (while (< (point) limit)
          (dyalog-next-defun limit)
          (let* ((all-info (dyalog-defun-info t))
                 (type     (car all-info))
                 (info     (cadr all-info)))
            (when (eq 'dfun type)
              (dyalog-fontify-dfun info start limit))))
        (goto-char limit)))))


;; TODO: We need a separate function for getting info on the defun at point,
;; which is something we can use to get an initial state, and moving forward
;; to the next defun and getting info on that. That way we avoid redundant
;; work.
;;
;; TODO: syntax-ppss consumes most of the cpu and does most of the
;; allocations. Try just skipping matches that have already been fontified
;; instead, that way we could cheaply skip matches inside comments, strings
;; and keywords.
(defun dyalog-fontify-locals (start end)
  "Fontify local names in tradfns.
START and END signify the region to fontify."
  (save-excursion
    (let* ((beg-line (progn (goto-char start)(line-beginning-position)))
           (case-fold-search nil)
           (all-info nil)
           (type nil)
           (info nil)
           (at-start-of-defun nil))
      (goto-char beg-line)
      (while (< (point) end)
        (setq all-info (dyalog-defun-info at-start-of-defun)
              type     (car all-info)
              info     (cadr all-info))
        (if (eq type 'dfun)
            (progn
              (dyalog-fontify-dfun info (point) end)
              (setq at-start-of-defun nil))
          (if (equal "" (plist-get info :name))
                ;; We are between tradfn definitions, skip to next function
                (setq at-start-of-defun (dyalog-next-defun))
            (dyalog-fontify-tradfn info (point) end)
            (setq at-start-of-defun nil)))))))

;;; Syntax

(defun dyalog-syntax-propertize-function (start end)
  "Alter syntax table for escaped single quotes within strings.
START and END delimit the region to analyze."
  (save-excursion
    (goto-char start)
    (while (and
            (search-forward "''" end 'no-error)
            (< (point) end))
      (goto-char (match-beginning 0))
      (let* ((endpos (match-end 0))
             (state (syntax-ppss))
             (context (syntax-ppss-context state)))
        (when (eq 'string context)
          (put-text-property (point) (+ 2 (point))
                             'syntax-table
                             (string-to-syntax ".")))
        (goto-char endpos)))))

(defun dyalog-current-keyword (&optional pt in-dfun)
  "Return the current keyword and if the keyword is preceded by a label.
PT is optional and defaults to point and determines where to look
for the keyword. If PT isn't in a keyword, return nil. If
provided, IN-DFUN is t if PT is inside a dynamic function. If it
is not provided, it is computed, which takes some time, so
providing it is an optimization. Return a two element list with
the keyword (or nil) and t if it is preceded by a label."
  (save-excursion
    (when pt
      (goto-char pt))
    (skip-chars-backward "A-Za-z:")
    (skip-syntax-backward "-")
    (when (eq (char-before) ?⋄)
      (backward-char))
    (when (and
           (not (bolp))
           (looking-back dyalog-label-regex (line-beginning-position)))
      (beginning-of-line))
    (pcase-let ((`(,keyword ,label-at-bol)
           (if (or (looking-at dyalog-keyword-regex)
                   (looking-at dyalog-middle-keyword-regex))
               (list (match-string-no-properties 2)
                     (not (not (match-string 5))))
             nil)))
      (if (and keyword (or in-dfun (dyalog-in-dfun)))
          (list nil nil)
        (list keyword label-at-bol)))))

(defun dyalog-in-keyword (&optional pt)
  "Return t if PT (defaults to point) is inside a keyword (e.g. :If)."
  (not (not (car (dyalog-current-keyword (or pt (point)))))))

(defun dyalog-in-comment-or-string (&optional pt)
  "Return t if PT (defaults to point) is inside a string literal or a comment."
  (save-excursion
    (progn
      (when pt
        (goto-char pt))
      (let ((match (match-data))
            (res (not (not
                       (memq (syntax-ppss-context (syntax-ppss))
                             '(string comment))))))
        (set-match-data match)
        res))))
  
(defun dyalog-current-symbol ()
  "Return the full symbol at point, including namespace qualifications."
  (let* ((regex "\\(\\s_\\|\\sw\\|\\.\\)"))
    (when (looking-at-p regex)
      (buffer-substring-no-properties
        (save-excursion
          (while (looking-back regex (1- (point)))
            (backward-char))
          (point))
        (save-excursion
          (while (looking-at-p regex)
            (ignore-errors (forward-char)))
          (point))))))

(defun dyalog-symbol-parts (symbol-name)
  "Return a list of all the parts of a symbol name.
For example, for \"ns1.ns2.name\", return '(\"ns1\" \"ns2\" \"name\").
If there are no parts, just return the name as given."
  (split-string symbol-name "\\." 'omit-nulls))

(defun dyalog-symbol-root (symbol-name)
  "Return the root namespace of the symbol name, or nil if there is none."
  (let ((parts (dyalog-symbol-parts symbol-name)))
    (when (< 1 (length parts))
      (car parts))))

;;; Socket connection
(defvar dyalog-connection ()
  "The connection to a Dyalog process used for this buffer, if any.")

(defvar dyalog-connections ()
  "A list of all connections to Dyalog processes.")

;;;###autoload
(defun dyalog-session-connect (&optional host port)
  "Connect to a Dyalog session.
HOST (defaults to localhost) and PORT (defaults to 7979) give
adress to connect to."
  (interactive (list (read-string "Host (default localhost):"
                                  "127.0.0.1")
                     (read-number "Port (default 7979):" 7979)))
  (make-comint "dyalog" (cons host port))
  (switch-to-buffer "*dyalog*")
  (set-buffer-process-coding-system 'utf-8-dos 'utf-8-dos)
  (setq-default comint-scroll-show-maximum-output nil)
  (define-key (current-local-map)
    (kbd"C-c C-e") 'dyalog-editor-edit-symbol-at-point)
  (run-hooks 'dyalog-session-connect-hook))

;;;###autoload
(defun dyalog-editor-connect (&optional host port)
  "Connect to a Dyalog process as an editor.
HOST (defaults to localhost) and PORT (defaults to 8080) give
adress to connect to."
  (interactive (list (read-string "Host (default localhost):"
                                  "127.0.0.1")
                     (read-number "Port (default 8080):" 8080)))
  (let* ((bufname (generate-new-buffer-name " *dyalog-receive*"))
         (process (make-network-process :name "dyalog-edit"
                                        :buffer bufname
                                        :family 'ipv4 :host host :service port
                                        :sentinel 'dyalog-editor-sentinel
                                        :filter 'dyalog-editor-receive
                                        :coding 'utf-8-dos)))
    (push process dyalog-connections)
    (set-process-query-on-exit-flag process nil)
    process))

(defun dyalog-editor-sentinel (proc msg)
  "Callback for socket errors.
PROC is the socket/process and MSG is a string describing the event/error."
  (when (string= msg "connection broken by remote peer\n")
    (message (format "client %s has quit" proc))
    (setq dyalog-connections (delq proc dyalog-connections))))

(defun dyalog-editor-receive (process output)
  "Receive data from a Dyalog editor connection.
PROCESS is the socket receiving data and OUTPUT is the data received."
  (with-current-buffer (process-buffer process)
    (save-excursion
      ;; Insert the text, advancing the process marker.
      (goto-char (process-mark process))
      (insert output)
      (set-marker (process-mark process) (point))
      (goto-char (point-min))
      (while (search-forward "\e" nil t)
        (backward-char)
        (let ((m (point)))
          (goto-char (point-min))
          (dyalog-editor-munge-command process (point) m)
          (with-current-buffer (process-buffer process)
            (set-marker (process-mark process) 1)))
        (sit-for 0.01)))))

(defun dyalog-editor-munge-command (process start end)
  "Parse and delete a Dyalog editor command in the currently active region.
PROCESS is the socket receiving the command, START is the start
of the command and END is where it ends."
  (cond ((looking-at
          "edit \\([^ []+\\)\\(\\[\\([0-9]+\\)\\]\\)?\0\\([^\0]*\\)\0")
         (let ((name (match-string 1))
               (linetext (match-string 3))
               (lineno nil)
               (path (match-string 4))
               (src  (buffer-substring-no-properties (match-end 0) end)))
           (when linetext
             (set 'lineno (string-to-number linetext)))
           (delete-region start (1+ end))
           (dyalog-open-edit-buffer process name src lineno path)))
        ((looking-at "fxresult \\([^ ]+\\)\e")
         (let* ((result (match-string 1))
                (num    (string-to-number result)))
           (if (eq num 0)
               (message "Fixed as %s" result)
             (message "Can't fix, error in line %d" num))
           (delete-region start (1+ end))))
        ((looking-at "editarray \\([^ ]+\\) \\([^ ]+\\) ")
         (let* ((name (match-string 1))
                (kind (match-string 2))
                (src (buffer-substring-no-properties (match-end 0) end)))
           (delete-region start (1+ end))
           (dyalog-open-edit-array process name kind src)))
        ((looking-at "dyaloghello \n")
         (progn
           (goto-char (match-end 0))
           (while (looking-at "\\([a-z]+\\): \\([^\r\n]+\\)\n")
             (let* ((key (match-string-no-properties 1))
                    (val (match-string-no-properties 2))
                    (propname (concat "dyalog-" key)))
               (process-put process (intern propname) val)
               (goto-char (match-end 0))))
           (delete-region start (1+ end))))
        (t
         (error "Ivalid message received"))))

(defun dyalog-open-edit-buffer (process name src &optional lineno path)
  "Open a buffer to edit object from socket PROCESS named NAME with source SRC.
PROCESS is the socket connection associated with the buffer.
LINENO optionally moves point to the given line and PATH contains
a string with the path to the source file associated with the
edit buffer."
  (let* ((file-name (if (and path (not (string= path "")))
                        path
                      nil))
         (bufname (if file-name
                      (file-name-nondirectory file-name)
                    name)))
    (switch-to-buffer bufname)
    (setq buffer-undo-list t)
    (let ((pos (point)))
      (save-excursion
        (mark-whole-buffer)
        (delete-region (point) (mark))
        (insert src))
      (when file-name
        (set-visited-file-name file-name t)
        (set-buffer-modified-p nil))
      (dyalog-mode)
      (setq dyalog-connection process)
      (font-lock-fontify-buffer)
      (if lineno
          (forward-line (- lineno 1))
        (goto-char (min pos (point-max))))
      (setq buffer-undo-list nil)
      (select-frame-set-input-focus (window-frame (selected-window))))))

(defun dyalog-open-edit-array (process name _kind src)
  "Open a buffer to edit array.
PROCESS is the socket connection associated with the buffer, NAME
is the name of the array, KIND is the type of array and is
\"charvec\", \"charmat\", \"stringvec\" or \"array\". SRC is the
formatted contents of the array"
  (switch-to-buffer name)
  (setq buffer-undo-list t)
  (let ((pos (point))
        (lineno nil))
    (save-excursion
      (when buffer-read-only
        (setq buffer-read-only nil))
      (mark-whole-buffer)
      (delete-region (point) (mark))
      (insert src))
    (dyalog-array-mode)
    (setq dyalog-connection process)
    (if (fboundp 'read-only-mode)    ; Only available in 24.4 and later
        (read-only-mode)
      (setq buffer-read-only t))
    (if lineno
        (forward-line (- lineno 1))
      (goto-char (min pos (point-max))))
    (setq buffer-undo-list nil)
    (select-frame-set-input-focus (window-frame (selected-window)))))

(defun dyalog-connection-desc (process)
  "Return a string describing PROCESS."
  (let ((version (process-get process 'dyalog-version))
        (wsid    (process-get process 'dyalog-wsid))
        (cwd     (process-get process 'dyalog-dir))
        (host (process-contact process :host))
        (port (process-contact process :service)))
    (if (and version wsid cwd)
        (let ((cwd-short (and (string-match "[^/\\]+\\'" cwd)
                              (match-string 0 cwd)))
              (wsid-short (and (string-match "[^/\\]+\\'" wsid)
                               (match-string 0 wsid))))
          (format "%s in %s v%s" wsid-short cwd-short version))
      (format "%s:%s" host port))))

(defun dyalog-connection-select (&optional prompt)
  "Select one of the active connections to Dyalog processes.
PROMPT is the prompt to show to the user."
  (let ((p (or prompt "Select a Dyalog process:"))
        (candidates (mapcar
                     'dyalog-connection-desc dyalog-connections)))
    (or (dyalog-editor-buffer-connected)
        (and (equal 1 (length dyalog-connections))
             (car dyalog-connections))
        (nth (cl-position (completing-read p candidates nil t)
                          candidates :test 'string-equal)
             dyalog-connections))))

(defun dyalog-editor-buffer-connected ()
  "When the current buffer is connected to Dyalog, return the connection.
Otherwise return nil."
  (and (process-live-p dyalog-connection) dyalog-connection))

(defun dyalog-editor-fix (&optional process)
  "Send the contents of the current buffer to the connected Dyalog PROCESS."
  (interactive)
  (let ((process (or process (dyalog-connection-select))))
    (setq dyalog-connection process)
    (process-send-string process "fx ")
    (process-send-region process (point-min) (point-max))
    (process-send-string process "\e")))

(defun dyalog-editor-fix-and-quit ()
  "Fix the current buffer, kill it, and move focus to Dyalog."
  (interactive)
  (let ((process (dyalog-connection-select))
        (kill-buffer-query-functions ()))
    (dyalog-editor-fix process)
    ;; TODO: We really should verify that the fix is successful here...
    (when (kill-buffer)
      (process-send-string process "focus \e"))))

(defun dyalog-editor-edit (name &optional line)
  "Open source of symbol NAME in an edit buffer.
Optional argument LINE specifies which line to move point to."
  (interactive "s")
  (let ((process (dyalog-connection-select))
        (linespec (if line (format "[%d]" line) nil )))
    (setq dyalog-connection process)
    (process-send-string process (concat "src " name linespec "\e"))))

(defun dyalog-editor-edit-symbol-at-point ()
  "Edit the source for the symbol at point."
  (interactive)
  (let ((sym (symbol-at-point))
        (lineno nil))
    (when (looking-at "[A-Za-z∆_0-9]+\\[\\([0-9]+\\)\\]")
      (setq lineno (string-to-number (match-string 1))))
    (dyalog-editor-edit (symbol-name sym) lineno)))

(defun dyalog-toggle-local ()
  "Toggle localization for symbol at point."
  (interactive)
  (let* ((sym   (symbol-at-point))
         (symname  (symbol-name sym))
         (name (substring-no-properties symname))
         (regex   (concat ";" name "\\_>"))
         (info (dyalog-tradfn-info))
         (fname (nth 0 info))
         (end-of-header (nth 3 info)))
    (unless (or (not sym)
                (equal (length fname) 0)
                (dyalog-in-comment-or-string)
                (dyalog-in-keyword)
                (dyalog-in-dfun))
      (save-excursion
        (goto-char end-of-header)
        (beginning-of-line)
        (if (re-search-forward regex end-of-header t)
            (progn
              (goto-char (match-beginning 0))
              (delete-char (length (match-string 0)))
              (message "Made %s non-local in function %s" name fname))
          (progn
            (move-end-of-line nil)
            (insert (concat ";" name))
            (message "Made %s local in function %s" name fname)))))))

(eval-after-load "which-func"
  '(add-to-list 'which-func-modes 'dyalog-mode))

;;;###autoload
(define-derived-mode dyalog-mode prog-mode "Dyalog"
  "Major mode for editing Dyalog APL code.

\\{dyalog-mode-map}"
  :group 'dyalog
  :syntax-table dyalog-mode-syntax-table
  (set (make-local-variable 'syntax-propertize-function)
       #'dyalog-syntax-propertize-function)
  (set (make-local-variable 'parse-sexp-ignore-comments) t)
  (set (make-local-variable 'parse-sexp-lookup-properties) t)
  (set (make-local-variable 'beginning-of-defun-function)
       'dyalog-beginning-of-defun)
  (set (make-local-variable 'end-of-defun-function) 'dyalog-end-of-defun)
  ;; Comments
  (set (make-local-variable 'comment-start) "⍝ ")
  (set (make-local-variable 'comment-start-skip) "⍝+\\s-*")
  (set (make-local-variable 'comment-use-syntax) t)
  (set (make-local-variable 'comment-auto-fill-only-comments) t)
  (set (make-local-variable 'font-lock-defaults) '(dyalog-font-lock-keywords))
  (jit-lock-register #'dyalog-fontify-locals)
  ;; Dyalog always indents with spaces
  (set (make-local-variable 'indent-tabs-mode) nil)
  (set (make-local-variable 'indent-line-function) 'dyalog-indent-line)
  (set (make-local-variable 'indent-region-function) 'dyalog-indent-region)
  (set (make-local-variable 'dyalog-buffer-type) (dyalog-guess-buffer-type))
  ;; Misc
  (set (make-local-variable 'require-final-newline) nil)
  ;; Socket connection
  (set (make-local-variable 'dyalog-connection) nil)
  ;; Imenu and which-func-mode
  (set (make-local-variable 'imenu-create-index-function)
       #'dyalog-imenu-create-index)
  (add-hook 'which-func-functions 'dyalog-current-defun nil 'make-it-local)
  ;; Hooks
  (add-hook 'before-save-hook
            'dyalog-fix-whitespace-before-save nil 'make-it-local))

(define-derived-mode dyalog-array-mode fundamental-mode "DyalogArr"
  "Major mode for editing Dyalog APL arrays.

\\{dyalog-array-mode-map\\}"
  :syntax-table dyalog-array-mode-syntax-table
  (set (make-local-variable 'require-final-newline) nil)
  (set (make-local-variable 'dyalog-connection) nil))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.dyalog$" . dyalog-mode))


(provide 'dyalog-mode)

;;; dyalog-mode.el ends here
