;;; haskell-emacs.el --- write emacs extensions in haskell

;; Copyright (C) 2014 Florian Knupfer

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA

;; Author: Florian Knupfer
;; Version: 1.1
;; email: fknupfer@gmail.com
;; Keywords: haskell, emacs, ffi
;; URL: https://github.com/knupfer/haskell-emacs

;;; Commentary:

;; haskell-emacs is a library which allows extending emacs in haskell.
;; It provides an FFI (foreign function interface) for haskell functions.

;; Run `haskell-emacs-init' or put it into your .emacs.  Afterwards just
;; populate your `haskell-emacs-dir' with haskell modules, which
;; export functions.  These functions will be wrapped automatically into
;; an elisp function with the name Module.function.

;; See documentation for `haskell-emacs-init' for a detailed example
;; of usage.

;;; Code:

(defgroup haskell-emacs nil
  "FFI for using haskell in emacs."
  :group 'haskell)

(defcustom haskell-emacs-dir "~/.emacs.d/haskell-fun/"
  "Directory with haskell modules."
  :group 'haskell-emacs
  :type 'string)

(defcustom haskell-emacs-cores 2
  "Number of cores used for haskell Emacs."
  :group 'haskell-emacs
  :type 'integer)

(defvar haskell-emacs--load-dir (file-name-directory load-file-name))
(defvar haskell-emacs--response nil)
(defvar haskell-emacs--count 0)
(defvar haskell-emacs--table (make-hash-table))
(defvar haskell-emacs--proc nil)
(defvar haskell-emacs--fun-list nil)

;;;###autoload
(defun haskell-emacs-init ()
  "Initialize haskell FFI or reload it to reflect changed functions.

It will try to wrap all exported functions within
`haskell-emacs-dir' into an synchronous and an asynchronous elisp
function.

Dependencies:
 - GHC
 - attoparsec
 - atto-lisp
 - text-show

Consider that you've got the following toy program:

---- ~/.emacs.d/haskell-fun/Matrix.hs
module Matrix (transpose, dyadic) where

import qualified Data.List as L

transpose :: [[Int]] -> [[Int]]
transpose = L.transpose

dyadic :: [Int] -> [Int] -> [[Int]]
dyadic xs ys = map (\\x -> map (x*) ys) xs
----

Now call `haskell-emacs-init' to provide the elisp wrappers.

  (Matrix.transpose '((1 2) (3 4) (5 6)))
    => ((1 3 5) (2 4 6))

  (Matrix.dyadic '(1 2 3) '(4 5 6))
    => ((4 5 6) (8 10 12) (12 15 18))

If you provide bad input, a description of the type error will be
shown to you.

If you call the async pendant of your functions, you'll get a
future which will block on evaluation if the result is not already present.

  (Matrix.transpose-async '((1 2) (3 4) (5 6)))
    => (haskell-emacs--get 7)

  (eval (haskell-emacs--get 7))
    => ((1 3 5) (2 4 6))

Or perhaps more convenient:

  (let ((tr (Matrix.transpose-async '((1 2) (3 4) (5 6)))))

       ;; other elisp stuff, or more asyncs

       (eval tr))

Haskell-emacs can handle functions of arbitrary arity (including
0), but you should note, that only monomorphic functions are
supported, and only about ten different types."
  (interactive)
  (unless (file-directory-p haskell-emacs-dir)
    (mkdir haskell-emacs-dir t))
  (let ((funs (directory-files haskell-emacs-dir nil "^[^.].*\.hs$"))
        (process-connection-type nil)
        (arity-list)
        (heF ".HaskellEmacs.hs")
        (heE (concat haskell-emacs-dir ".HaskellEmacs"))
        (code (with-temp-buffer
                (insert-file-contents
                 (concat haskell-emacs--load-dir "HaskellEmacs.hs"))
                (buffer-string)))
        (start-proc '(progn (when haskell-emacs--proc
                              (set-process-sentinel haskell-emacs--proc nil)
                              (delete-process haskell-emacs--proc))
                            (setq haskell-emacs--proc
                                  (start-process "hask" nil heE))
                            (set-process-filter haskell-emacs--proc
                                                'haskell-emacs--filter))))
    (unless (file-exists-p heE)
      (haskell-emacs--compile code))
    (eval start-proc)
    (setq funs (mapcar (lambda (f) (with-temp-buffer
                                     (insert-file-contents
                                      (concat haskell-emacs-dir f))
                                     (buffer-string)))
                       funs)
          funs (eval (haskell-emacs--fun-body "allExports" (list funs))))
    (dotimes (a 2)
      (setq arity-list (eval (haskell-emacs--fun-body "arityList" nil)))
      (haskell-emacs--compile
       (eval (haskell-emacs--fun-body
              "formatCode"
              (list (list (car funs)
                          (car arity-list)
                          (eval (haskell-emacs--fun-body "arityFormat"
                                                         (cdr funs))))
                    code))))
      (eval start-proc))
    (set-process-sentinel haskell-emacs--proc (lambda (proc sign)
                                    (setq haskell-emacs--response nil)
                                    (haskell-emacs-init)
                                    (let ((debug-on-error t))
                                      (error "Haskell-emacs crashed"))))
    (set-process-query-on-exit-flag haskell-emacs--proc nil)
    (let ((arity (cadr arity-list)))
      (mapc (lambda (func)
              (eval (haskell-emacs--fun-wrapper func (pop arity))))
            (cadr funs))))
  (message "Finished compiling."))

(defun haskell-emacs--filter (process output)
  "Haskell PROCESS filter for OUTPUT from functions."
  (unless (= 0 (length haskell-emacs--response))
    (setq output (concat haskell-emacs--response output)
          haskell-emacs--response nil))
  (let ((header)
        (dataLen)
        (p))
    (while (and (setq p (string-match ")" output))
                (<= (setq header (read output)
                          dataLen (+ (car header) 1 p))
                    (length output)))
      (let ((content (substring output (- dataLen (car header)) dataLen)))
        (setq output (substring output dataLen))
        (when (= 3 (length header)) (error content))
        (puthash (cadr header) content haskell-emacs--table))))
  (unless (= 0 (length output))
    (setq haskell-emacs--response output)))

(defun haskell-emacs--fun-body (fun args)
  "Generate function body for FUN with ARGS."
  (let ((arguments))
    (setq haskell-emacs--count (+ 1 haskell-emacs--count))
    (if (not args)
        (setq arguments "0")
      (setq arguments
            (mapcar
             (lambda (ARG)
               (if (stringp ARG)
                   (format "%S" (substring-no-properties ARG))
                 (if (or (listp ARG) (arrayp ARG))
                     (concat "("
                             (apply 'concat
                                    (mapcar
                                     (lambda (x)
                                       (concat (format "%S" x) "\n"))
                                     (haskell-emacs--array-to-list ARG))) ")")
                   (format "%S" ARG))))
             args))
      (if (= 1 (length arguments))
          (setq arguments (car arguments))
        (setq arguments (mapcar (lambda (x) (concat x " ")) arguments)
              arguments (concat "(" (apply 'concat arguments) ")"))))
    (process-send-string
     haskell-emacs--proc (concat fun "$" (number-to-string haskell-emacs--count)
                                 " " arguments
                                 "\n")))
  (list 'haskell-emacs--get haskell-emacs--count))

(defun haskell-emacs--fun-wrapper (fun args)
  "Take FUN with ARGS and return wrappers in elisp."
  (let ((body `(haskell-emacs--fun-body
                ,fun ,(read (concat "(list " (substring args 1))))))
    `(if (= 1 (length ',(read args)))
         (progn
           (add-to-list 'haskell-emacs--fun-list
                        (eval (haskell-emacs--macros ,fun)))
           (eval (haskell-emacs--macros ,fun t)))
       (progn (add-to-list 'haskell-emacs--fun-list
                           (defun ,(intern fun) ,(read args)
                             (let ((haskell-emacs--count -1)) (eval ,body))))
              (defun ,(intern (concat fun "-async")) ,(read args)
                ,body)))))

(defun haskell-emacs--macros (fun &optional async)
  "Take FUN and return a macro which may be ASYNC."
  `(defmacro ,(intern (concat fun (when async "-async"))) (x1)
     (let ((argsM (make-symbol "args"))
           (funsM (make-symbol "funs")))
       `(let ((,argsM ',x1)
              (,funsM))
          (while (and (listp ,argsM)
                      (member (car ,argsM) haskell-emacs--fun-list)
                      (= 2 (length ,argsM)))
            (setq ,funsM (concat ,funsM (format "$%s" (car ,argsM))))
            (setq ,argsM (cadr ,argsM)))
          (if (and (listp ,argsM)
                   (member (car ,argsM) haskell-emacs--fun-list))
              (progn
                (setq ,funsM (concat ,funsM (format "$%s" (car ,argsM))))
                (setq ,argsM (mapcar 'eval (cdr ,argsM))))
            (setq ,argsM (list (eval ,argsM))))
          (if ,,async
              (progn (haskell-emacs--fun-body (concat ,,fun ,funsM)
                                              ,argsM)
                     (list 'haskell-emacs--get haskell-emacs--count))
            (let ((haskell-emacs--count -1))
              (haskell-emacs--fun-body (concat ,,fun ,funsM)
                                       ,argsM))
            (haskell-emacs--get 0))))))

(defun haskell-emacs--get (id)
  "Retrieve result from haskell process with ID."
  (while (not (gethash id haskell-emacs--table))
    (accept-process-output haskell-emacs--proc))
  (let ((res (gethash id haskell-emacs--table)))
    (remhash id haskell-emacs--table)
    (read res)))

(defun haskell-emacs--array-to-list (array)
  "Take a sequence and turn all ARRAY to lists."
  (mapcar (lambda (x) (if (and (not (stringp x)) (or (arrayp x) (listp x)))
                          (haskell-emacs--array-to-list x) x))
          array))

(defun haskell-emacs--compile (code)
  "Use CODE to compile a new haskell Emacs programm."
  (with-temp-buffer
    (let ((heB "*HASKELL-BUFFER*")
          (heF ".HaskellEmacs.hs"))
      (cd haskell-emacs-dir)
      (unless (and (file-exists-p heF)
                   (equal code (with-temp-buffer (insert-file-contents heF)
                                                 (buffer-string))))
        (insert code)
        (write-file heF))
      (message "Compiling ...")
      (if (eql 0 (call-process "ghc" nil heB nil "-O2" "-threaded" "--make"
                               (concat "-with-rtsopts=-N"
                                       (number-to-string haskell-emacs-cores))
                               heF))
          (kill-buffer heB)
        (let ((bug (with-current-buffer heB (buffer-string))))
          (kill-buffer heB)
          (error bug))))))

(provide 'haskell-emacs)

;;; haskell-emacs.el ends here
