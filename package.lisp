;;;; ---------------------------------------------------------------------------
;;;; Handle ASDF package upgrade, including implementation-dependent magic.
;;
;; See https://bugs.launchpad.net/asdf/+bug/485687
;;
;; CAUTION: we must handle the first few packages specially for hot-upgrade.
;; asdf/package will be frozen as of 2.27
;; to forever export the same exact symbols.
;; Any other symbol must be import-from'ed
;; and reexported in a different package
;; (alternatively the package may be dropped & replaced by one with a new name).

(defpackage :asdf/package
  (:use :common-lisp)
  (:export
   #:find-package* #:find-symbol* #:intern* #:unintern*
   #:symbol-name-package #:package-data
   #:delete-package* #:ensure-package #:define-package))

(in-package :asdf/package)

(declaim (optimize (speed 0) (safety 3) (debug 3)))

(defmacro DBG (tag &rest exprs)
  "simple debug statement macro:
outputs a tag plus a list of variable and their values, returns the last value"
  ;;"if not in debugging mode, just compute and return last value"
  #-DBGXXX (declare (ignore tag)) #-DBGXXX (car (last exprs)) #+DBGXXX
  (let ((res (gensym))(f (gensym)))
  `(let (,res (*print-readably* nil))
    (flet ((,f (fmt &rest args) (apply #'format *error-output* fmt args)))
      (fresh-line *standard-output*) (fresh-line *trace-output*) (fresh-line *error-output*)
      (,f "~&~A~%" ,tag)
      ,@(mapcan
         #'(lambda (x)
            `((,f "~&  ~S => " ',x)
              (,f "~{~S~^ ~}~%" (setf ,res (multiple-value-list ,x)))))
         exprs)
      (apply 'values ,res)))))

;;;; General purpose package utilities

(eval-when (:load-toplevel :compile-toplevel :execute)
  (defun find-package* (package-designator &optional (error t))
    (let ((package (find-package package-designator)))
      (cond
        (package package)
        (error (error "No package named ~S" (string package-designator)))
        (t nil))))
  (defun find-symbol* (name package-designator &optional (error t))
    "Find a symbol in a package of given string'ified NAME;
unless CL:FIND-SYMBOL, work well with 'modern' case sensitive syntax
by letting you supply a symbol or keyword for the name;
also works well when the package is not present.
If optional ERROR argument is NIL, return NIL instead of an error
when the symbol is not found."
    (block nil
      (let ((package (find-package* package-designator error)))
        (when package
          (multiple-value-bind (symbol status) (find-symbol (string name) package)
            (cond
              (status (return (values symbol status)))
              (error (error "There is no symbol ~S in package ~S" name (package-name package))))))
        (values nil nil))))
  (defun intern* (name package-designator &optional (error t))
    (intern (string name) (find-package* package-designator error)))
  (defun unintern* (name package-designator &optional (error t))
    (block nil
      (let ((package (find-package* package-designator error)))
        (when package
          (multiple-value-bind (symbol status) (find-symbol* name package error)
            (cond
              (status (unintern symbol package)
                      (return (values symbol status)))
              (error (error "symbol ~A not present in package ~A"
                            (string symbol) (package-name package))))))
        (values nil nil))))
  (defun symbol-name-package (symbol)
    (cons (symbol-name symbol) (package-name (symbol-package symbol))))
  (defun package-names (package)
    (cons (package-name package) (package-nicknames package)))
  (defun package-data (package-designator &key name-package (error t))
    (let ((package (find-package* package-designator error)))
      (when package
        (labels ((marshall-symbols (symbols)
                   (if name-package (mapcar #'symbol-name-package symbols) symbols))
                 (sort-symbols (symbols)
                   (marshall-symbols (sort symbols #'string<)))
                 (sort-packages (packages)
                   (sort (mapcar #'package-name packages) #'string<)))
          (loop :with internal :with external :with inherited
                :for sym :being :the :symbols :in package
                :for status = (nth-value 1 (find-symbol* sym package)) :do
                  (ecase status
                    (:internal (push sym internal))
                    (:external (push sym external))
                    (:inherited (push sym inherited)))
                :finally
                   (return
                     `(:name ,(package-name package)
                       :nicknames ,(package-nicknames package)
                       :internal ,(sort-symbols internal)
                       :external ,(sort-symbols external)
                       :inherited ,(sort-symbols inherited)
                       :shadowing ,(sort-symbols (package-shadowing-symbols package))
                       :use ,(sort-packages (package-use-list package))
                       :used-by ,(sort-packages (package-used-by-list package))))))))))

(eval-when (:load-toplevel :compile-toplevel :execute)
  (defun soft-upgrade-p (upgrade)
    (ecase upgrade ((:soft nil) t) (:hard nil)))
  (defun ensure-package-unused (package)
    (loop :for p :in (package-used-by-list package) :do
      (unuse-package package p)))
  (defun delete-package* (package)
    (let ((p (find-package package)))
      (when p
        (ensure-package-unused p)
        (delete-package package))))
  (defun ensure-package-fmakunbound (package symbols)
    (loop :for name :in symbols
          :for sym = (find-symbol* name package nil)
          :when sym :do (fmakunbound sym)))
  (defun ensure-package-fmakunbound-setf (package symbols)
    (loop :for name :in symbols
          :for sym = (find-symbol* name package nil)
          :when sym :do #-gcl (fmakunbound `(setf ,sym))))
  (defun ensure-package (name &key
                                upgrade
                                nicknames documentation use
                                shadow shadowing-import-from
                                import-from export intern
                                recycle mix reexport
                                unintern fmakunbound fmakunbound-setf)
    (DBG :ensure-package name nicknames upgrade documentation use
         shadow shadowing-import-from
         import-from export intern
         recycle mix reexport
         unintern fmakunbound fmakunbound-setf)
    (let* ((nicknames (mapcar #'string nicknames))
           (shadow (mapcar #'string shadow))
           (shadowing-import-from (loop :for sif :in shadowing-import-from
                                        :collect (mapcar #'string sif)))
           (import-from (loop :for if :in import-from
                              :collect (mapcar #'string if)))
           (export (mapcar #'string export))
           (recycle (remove nil (mapcar #'find-package recycle)))
           (shadowed (make-hash-table :test 'equal)) ; string to bool
           (imported (make-hash-table :test 'equal)) ; string to bool
           (exported (make-hash-table :test 'equal)) ; string to bool
           (inherited (make-hash-table :test 'equal)) ; string to package name
           (name (string name))
           (nicknames (mapcar #'string nicknames))
           (names (cons name nicknames))
           (previous (remove-duplicates (remove nil (mapcar #'find-package names)) :from-end t))
           (discarded (cdr previous))
           (package (DBG :xxx names previous discarded (or (first previous) (make-package name :nicknames nicknames)))))
      (labels
          ((ensure-shadowing-import (sym p)
             (let* ((name (string sym))
                    (i (find-symbol* name p)))
               (cond
                 ((gethash name shadowed)
                  (unless (eq i (find-symbol* name package))
                    (error "Conflicting shadowings for ~A" name)))
                 (t
                    (setf (gethash name shadowed) t)
                    (setf (gethash name imported) t)
                    (shadowing-import package)))))
           (ensure-import (sym p)
             (let* ((name (string sym))
                    (i (find-symbol* name p)))
               (multiple-value-bind (x xp) (find-symbol name package)
                 (cond
                   ((gethash name imported)
                    (unless (eq i x)
                      (error "Can't import ~S from both ~S and ~S"
                             name (package-name (symbol-package x)) (package-name p))))
                   ((gethash name shadowed)
                    (error "Can't both shadow ~S and import it from ~S" name (package-name p)))
                   (t
                    (when (and xp (not (eq i x)))
                      (unintern* x package))
                    (setf (gethash name imported) t)
                    (import i package))))))
           (ensure-mix (sym p)
             (let* ((name (string sym))
                    (sp (string p)))
               (unless (or (gethash name shadowed) (gethash name imported))
                 (let ((ip (gethash name inherited)))
                   (cond
                     ((eq sp ip))
                     (ip
                      (remhash name inherited)
                      (ensure-shadowing-import name ip))
                     (t
                      (ensure-inherited sym sp)))))))
           (ensure-inherited (sym p)
             (let* ((name (string sym))
                    (sp (string p))
                    (s (find-symbol* name sp))
                    (ip (gethash name inherited)))
               (multiple-value-bind (x xp) (find-symbol name package)
                 (cond
                   (ip
                    (unless (eq ip sp)
                      (error "Can't inherit ~S from ~S, it is inherited from ~S"
                             name sp ip)))
                   ((gethash name imported)
                    (unless (eq s x)
                      (error "Can't inherit ~S from ~S, it is imported from ~S"
                             name sp (package-name (symbol-package x)))))
                   ((gethash name shadowed)
                    (error "Can't inherit ~S from ~S, it is shadowed" name sp))
                   (t
                    (when xp
                      (unintern* x package)))))))
           (recycle-symbol (name)
             (loop :for r :in recycle
                   :for s = (find-symbol* name r nil)
                   :when s :do (return (values s r))))
           (symbol-recycled-p (sym)
             (loop :for r :in recycle
                   :thereis (multiple-value-bind (s sp) (find-symbol* sym r nil) (and sp (eq sym s)))))
           (ensure-symbol (name &optional intern)
             (unless (or (gethash name shadowed)
                         (gethash name imported)
                         (gethash name inherited))
               (multiple-value-bind (recycled previous) (recycle-symbol name)
                 (cond
                   ((eq previous package))
                   ((or (not previous) (not (member (symbol-package recycled) recycle)))
                    (when intern (intern* name package)))
                   (t (unintern* name package nil) (unintern* recycled previous) (import recycled package))))))
           (ensure-export (name p)
             (multiple-value-bind (symbol status) (find-symbol name p)
               (assert status)
               (unless (eq status :external)
                 (ensure-exported name symbol p))))
           (ensure-exported (name sym p)
             (dolist (u (package-used-by-list p))
               (ensure-exported-to-user name sym u))
             (export sym p))
           (ensure-exported-to-user (name sym u)
             (multiple-value-bind (usym ustat) (find-symbol name u)
               (unless (eq sym usym)
                 (let ((shadowing (member usym (package-shadowing-symbols u))))
                   (block nil
                     (cond
                       ((not shadowing)
                        (unintern usym u))
                       ((symbol-recycled-p usym)
                        (shadowing-import sym u))
                       (t (return)))
                     (when (eq ustat :external)
                       (ensure-exported name sym u))))))))
        (assert (soft-upgrade-p upgrade))
        (setf (documentation package t) documentation)
        ;;#+DBG (untrace)(trace find-symbol make-package delete-package use-package unuse-package import export intern shadow shadowing-import unintern unexport)
        (DBG :names names package previous discarded (package-data package :name-package t))
        (loop :for p :in discarded
              :for n = (remove-if #'(lambda (x) (member x names :test 'equal))
                                  (package-names p))
              :do (DBG :baz (package-names p) n)
              :do (if n (rename-package discarded (first n) (rest n))
                      (delete-package* discarded)))
        (rename-package package name nicknames)
        (DBG :unuse)
        (loop :for p :in (set-difference (package-use-list package) (append mix use))
              :do (unuse-package p package))
        (DBG :unintern)
        (dolist (name unintern) (unintern* name package nil))
        (DBG :export?)
        (loop :for sym :in export :for name = (string sym) :do
          (setf (gethash name exported) t))
        (DBG :reexport)
        (loop :for p :in reexport :do
          (do-external-symbols (sym p)
            (let ((name (string sym)))
              (export (find-symbol* name package) package) (setf (gethash name exported) t))))
        (DBG :unexport)
        (do-external-symbols (sym package)
          (unless (gethash (symbol-name sym) exported) (unexport sym package)))
        (DBG :shadow)
        (loop :for s :in shadow :for name = (string s) :do
          (DBG :sha name)
          (setf (gethash name shadowed) t)
          (multiple-value-bind (recycled previous) (recycle-symbol name)
            (cond
              ((or (not previous) (not (member (symbol-package recycle) recycle)))
               (ecase (nth-value 1 (find-symbol* name package nil))
                 ((nil :inherited) (shadow name package))
                 ((:internal :external) (shadowing-import (make-symbol name) package))))
              ((eq previous package) (shadow recycled package))
              (t (unintern* recycled previous) (shadowing-import recycled package)))))
        (loop :for (p . syms) :in shadowing-import-from :do
          (DBG :shaif p syms)
          (dolist (sym syms) (ensure-shadowing-import sym p)))
        (loop :for p :in mix :do
          (DBG :mix p)
          (do-external-symbols (sym p) (ensure-mix sym p)))
        (loop :for (p . syms) :in import-from :do
          (DBG :if p syms)
          (dolist (sym syms) (ensure-import sym p)))
        (loop :for p :in use :for sp = (string p) :for pp = (find-package sp) :do
          (DBG :use p sp pp)
          (do-external-symbols (sym pp) (ensure-inherited sym sp))
          (use-package pp package))
        (DBG :intern)
        (loop :for name :being :the :hash-keys :of exported :do
          (ensure-symbol name t))
        (dolist (name (append intern fmakunbound fmakunbound-setf))
          (ensure-symbol (string name) t))
        (DBG :cleanup)
        (do-symbols (sym package)
          (ensure-symbol (symbol-name sym)))
        (DBG :export)
        (loop :for name :being :the :hash-keys :of exported :do
          (ensure-export name package))
        ;; do away with packages with conflicting (nick)names
        ;; note from ASDF 2.26: ECL might not be liking an early fmakunbound (below #-ecl'ed)
        (ensure-package-fmakunbound package fmakunbound)
        (ensure-package-fmakunbound-setf package fmakunbound-setf)
        ;;#+DBG (untrace)
        package))))

(eval-when (:load-toplevel :compile-toplevel :execute)
  (defun parse-define-package-form (package clauses)
    (loop
      :with use-p = nil :with recycle-p = nil
      :with documentation = nil :with upgrade = nil
      :for (kw . args) :in clauses
      :when (eq kw :nicknames) :append args :into nicknames :else
      :when (eq kw :documentation)
        :do (cond
              (documentation (error "define-package: can't define documentation twice"))
              ((or (atom args) (cdr args)) (error "define-package: bad documentation"))
              (t (setf documentation (car args)))) :else
      :when (eq kw :use) :append args :into use :and :do (setf use-p t) :else
      :when (eq kw :shadow) :append args :into shadow :else
      :when (eq kw :shadowing-import-from) :collect args :into shadowing-import-from :else
      :when (eq kw :import-from) :collect args :into import-from :else
      :when (eq kw :export) :append args :into export :else
      :when (eq kw :intern) :append args :into intern :else
      :when (eq kw :recycle) :append args :into recycle :and :do (setf recycle-p t) :else
      :when (eq kw :mix) :append args :into mix :else
      :when (eq kw :reexport) :append args :into reexport :else
      :when (eq kw :unintern) :append args :into unintern :else
      :when (eq kw :fmakunbound) :append args :into fmakunbound :else
      :when (eq kw :fmakunbound-setf) :append args :into fmakunbound-setf :else
      :when (eq kw :upgrade)
        :do (unless (and (consp args) (null (cdr args)) (member (car args) '(:soft :hard)) (null upgrade))
              (error "define-package: bad :upgrade directive"))
            (setf upgrade (car args)) :else
      :do (error "unrecognized define-package keyword ~S" kw)
      :finally (return `(,package
                         :nicknames ,nicknames :documentation ,documentation
                         :use ,(if use-p use '(:common-lisp))
                         :shadow ,shadow :shadowing-import-from ,shadowing-import-from
                         :import-from ,import-from :export ,export :intern ,intern
                         :recycle ,(if recycle-p recycle (cons package nicknames))
                         :mix ,mix :reexport ,reexport :unintern ,unintern
                         ,@(when upgrade `(:upgrade ,upgrade))
                         :fmakunbound ,fmakunbound :fmakunbound-setf ,fmakunbound-setf)))))

(defmacro define-package (package &rest clauses)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     #+gcl (defpackage ,package (:use))
     (apply 'ensure-package ',(parse-define-package-form package clauses))))
