;; Git merge-conflict resolver.
;;
;; Operates directly on the currently focused document containing standard git
;; conflict markers:
;;
;;   <<<<<<< HEAD          (ours)
;;   ...ours lines...
;;   ||||||| base          (optional, diff3 style)
;;   ...base lines...
;;   =======
;;   ...theirs lines...
;;   >>>>>>> other-branch  (theirs)
;;
;; Provides navigation between conflicts, overlay highlighting of the ours/theirs
;; regions, and resolution actions (accept ours / theirs / both / none). Every
;; provided function is exposed as a `:typable-command`, e.g. `:conflict-next`.

(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/components.scm")
(require-builtin helix/core/text)
(require-builtin steel/process)

(require (only-in "component.scm" cursor-selection))

(provide conflict-highlight
         conflict-clear
         conflict-next
         conflict-prev
         conflict-accept-ours
         conflict-accept-theirs
         conflict-accept-both
         conflict-accept-none
         conflict-list
         conflict-files)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Configuration ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Theme scopes used to highlight the two sides of a conflict. `find_highlight`
;; falls back hierarchically (diff.plus -> diff), and a scope that resolves to
;; nothing is simply not drawn, so these are safe on any theme.
(define OURS-SCOPE "diff.plus")
(define THEIRS-SCOPE "diff.delta")

(define NS-OURS "git-conflict-ours")
(define NS-THEIRS "git-conflict-theirs")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Utilities ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (str-trim s)
  (trim-end (trim-start s)))

(define (find-first pred lst)
  (cond
    [(null? lst) #f]
    [(pred (car lst)) (car lst)]
    [else (find-first pred (cdr lst))]))

(define (list-last lst)
  (if (null? (cdr lst)) (car lst) (list-last (cdr lst))))

;; The rope backing the currently focused document.
(define (current-doc-rope)
  (let* ([focus (editor-focus)]
         [focus-doc-id (editor->doc-id focus)])
    (editor->text focus-doc-id)))

;; Current cursor line (0-based) in the given rope.
(define (cursor-line rope)
  (rope-char->line rope (hx.cx->pos)))

;; The text of line `i`, including its trailing newline if present.
(define (line-str rope i)
  (rope->string (rope->line rope i)))

;; The label following a `<<<<<<<` / `>>>>>>>` marker (the 7 marker chars + space).
(define (marker-label line)
  (str-trim (substring line 7 (string-length line))))

;; True when `line` opens with exactly seven `ch` characters followed by either
;; end-of-line or a space — i.e. a real git conflict marker, and not an 8+ run
;; or a heading underline that merely starts with the character.
(define (marker? line ch)
  (and (>= (string-length line) 7)
       (equal? (substring line 0 7) (make-string 7 ch))
       (let ([rest (substring line 7 (string-length line))])
         (or (equal? (str-trim rest) "")
             (char=? (string-ref rest 0) #\space)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Parsing ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; A single parsed conflict block.
;;   start-line   : line index of the `<<<<<<<` marker
;;   base-line    : line index of the `|||||||` marker, or #false (2-way conflict)
;;   sep-line     : line index of the `=======` marker
;;   end-line     : line index of the `>>>>>>>` marker
;;   start-char   : char offset of the first char of the block
;;   last-char    : inclusive char offset of the last char of the block
;;   ours-label   : label from the `<<<<<<<` marker
;;   theirs-label : label from the `>>>>>>>` marker
(struct Conflict
        (start-line base-line sep-line end-line start-char last-char ours-label theirs-label))

(define (finalize-conflict rope partial end-line marker-line)
  (define start-line (hash-ref partial 'start))
  (define n (rope-len-lines rope))
  (define after (+ end-line 1))
  (define next-start
    (if (< after n) (rope-line->char rope after) (rope-len-chars rope)))
  (Conflict start-line
            (hash-ref partial 'base)
            (hash-ref partial 'sep)
            end-line
            (rope-line->char rope start-line)
            (- next-start 1)
            (hash-ref partial 'ours-label)
            (marker-label marker-line)))

;; Parse every well-formed conflict block in the rope, in document order.
(define (parse-conflicts rope)
  (define n (rope-len-lines rope))
  (let loop ([i 0] [partial #false] [acc '()])
    (if (>= i n)
        (reverse acc)
        (let ([line (line-str rope i)])
          (cond
            [(marker? line #\<)
             (loop (+ i 1)
                   (hash 'start i 'base #false 'sep #false 'ours-label (marker-label line))
                   acc)]
            [(and partial (marker? line #\|))
             (loop (+ i 1) (hash-insert partial 'base i) acc)]
            [(and partial (not (hash-ref partial 'sep)) (marker? line #\=))
             (loop (+ i 1) (hash-insert partial 'sep i) acc)]
            [(and partial (hash-ref partial 'sep) (marker? line #\>))
             (loop (+ i 1) #false (cons (finalize-conflict rope partial i line) acc))]
            [else (loop (+ i 1) partial acc)])))))

;; End of the "ours" content (exclusive) is the base marker in diff3 mode,
;; otherwise the separator.
(define (ours-content-end c)
  (or (Conflict-base-line c) (Conflict-sep-line c)))

;; The literal text of the ours / theirs sides (each line keeps its newline).
(define (ours-text rope c)
  (rope->string (rope->slice rope
                             (rope-line->char rope (+ (Conflict-start-line c) 1))
                             (rope-line->char rope (ours-content-end c)))))

(define (theirs-text rope c)
  (rope->string (rope->slice rope
                             (rope-line->char rope (+ (Conflict-sep-line c) 1))
                             (rope-line->char rope (Conflict-end-line c)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Highlighting ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (start . end) char pair for the ours side highlight (marker line through the
;; line before the separator).
(define (ours-range rope c)
  (cons (Conflict-start-char c)
        (rope-line->char rope (Conflict-sep-line c))))

;; (start . end) char pair for the theirs side highlight (separator line through
;; the `>>>>>>>` line).
(define (theirs-range rope c)
  (cons (rope-line->char rope (Conflict-sep-line c))
        (+ (Conflict-last-char c) 1)))

;; Recompute and apply overlay highlights for every conflict in the buffer.
;; Clears the highlights entirely when no conflicts remain.
(define (refresh-conflict-highlights)
  (define rope (current-doc-rope))
  (define conflicts (parse-conflicts rope))
  (if (null? conflicts)
      (begin
        (clear-document-highlights! NS-OURS)
        (clear-document-highlights! NS-THEIRS))
      (begin
        (set-document-highlights! NS-OURS
                                  (map (lambda (c) (ours-range rope c)) conflicts)
                                  OURS-SCOPE)
        (set-document-highlights! NS-THEIRS
                                  (map (lambda (c) (theirs-range rope c)) conflicts)
                                  THEIRS-SCOPE))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Navigation ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Move the primary selection (a zero-width cursor) to `ch`.
(define (goto-char! ch)
  (helix.static.set-current-selection-object!
   (helix.static.range->selection (helix.static.range ch ch))))

;; The conflict the cursor is inside, or the first one starting at/after the
;; cursor line. #false when the cursor is past the last conflict.
(define (conflict-at-cursor rope conflicts)
  (define line (cursor-line rope))
  (or (find-first (lambda (c)
                    (and (>= line (Conflict-start-line c))
                         (<= line (Conflict-end-line c))))
                  conflicts)
      (find-first (lambda (c) (>= (Conflict-start-line c) line)) conflicts)))

;;@doc
;; Jump to the next conflict below the cursor (wraps to the first).
(define (conflict-next)
  (define rope (current-doc-rope))
  (define conflicts (parse-conflicts rope))
  (unless (null? conflicts)
    (define line (cursor-line rope))
    (define target
      (or (find-first (lambda (c) (> (Conflict-start-line c) line)) conflicts)
          (car conflicts)))
    (goto-char! (Conflict-start-char target)))
  (refresh-conflict-highlights))

;;@doc
;; Jump to the previous conflict above the cursor (wraps to the last).
(define (conflict-prev)
  (define rope (current-doc-rope))
  (define conflicts (parse-conflicts rope))
  (unless (null? conflicts)
    (define line (cursor-line rope))
    (define target
      (or (find-first (lambda (c) (< (Conflict-start-line c) line))
                      (reverse conflicts))
          (list-last conflicts)))
    (goto-char! (Conflict-start-char target)))
  (refresh-conflict-highlights))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Resolution ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Select the inclusive char span [start, end] and replace it with `str`.
;; Mirrors surround.hx's `replace-char-range!`.
(define (replace-char-range! start end str)
  (helix.static.set-current-selection-object!
   (helix.static.range->selection (helix.static.range start end)))
  (helix.static.replace-selection-with str))

;; Resolve the conflict under the cursor by replacing the whole block with
;; `resolved` (a function of the rope + conflict producing the replacement text).
(define (resolve-with resolved)
  (define rope (current-doc-rope))
  (define conflicts (parse-conflicts rope))
  (define target (conflict-at-cursor rope conflicts))
  (when target
    (goto-char! (Conflict-start-char target))
    (replace-char-range! (Conflict-start-char target)
                         (Conflict-last-char target)
                         (resolved rope target))
    (refresh-conflict-highlights)))

;;@doc
;; Resolve the current conflict keeping only our (HEAD) side.
(define (conflict-accept-ours)
  (resolve-with ours-text))

;;@doc
;; Resolve the current conflict keeping only their (incoming) side.
(define (conflict-accept-theirs)
  (resolve-with theirs-text))

;;@doc
;; Resolve the current conflict keeping both sides (ours then theirs).
(define (conflict-accept-both)
  (resolve-with (lambda (rope c) (string-append (ours-text rope c) (theirs-text rope c)))))

;;@doc
;; Resolve the current conflict by discarding both sides (delete the block).
(define (conflict-accept-none)
  (resolve-with (lambda (rope c) "")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Highlight commands ;;;;;;;;;;;;;;;;;;;;;;;;;

;;@doc
;; Highlight every conflict in the current buffer.
(define (conflict-highlight)
  (refresh-conflict-highlights))

;;@doc
;; Remove conflict highlighting from the current buffer.
(define (conflict-clear)
  (clear-document-highlights! NS-OURS)
  (clear-document-highlights! NS-THEIRS))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Pickers ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (conflict->label c)
  (string-append "L"
                 (number->string (+ 1 (Conflict-start-line c)))
                 "  "
                 (Conflict-ours-label c)
                 " <> "
                 (Conflict-theirs-label c)))

;;@doc
;; Open a picker over the conflicts in the current buffer; selecting one jumps to it.
(define (conflict-list)
  (define rope (current-doc-rope))
  (define conflicts (parse-conflicts rope))
  (unless (null? conflicts)
    (refresh-conflict-highlights)
    (push-component!
     (cursor-selection conflicts
                       (lambda (c) (goto-char! (Conflict-start-char c)))
                       #:value-formatter conflict->label))))

;; Capture stdout of a git invocation as a string.
(define (git-output args)
  (define cmd (command "git" args))
  (set-piped-stdout! cmd)
  (Ok->value (wait->stdout (Ok->value (spawn-process cmd)))))

;;@doc
;; Open a picker over every file in the repo with unresolved conflicts; selecting
;; one opens it and highlights its conflicts.
(define (conflict-files)
  (define files
    (filter (lambda (s) (not (equal? s "")))
            (map str-trim
                 (split-many (git-output (list "diff" "--name-only" "--diff-filter=U")) "\n"))))
  (unless (null? files)
    (push-component!
     (cursor-selection files
                       (lambda (file)
                         (helix.open file)
                         (enqueue-thread-local-callback-with-delay 10 refresh-conflict-highlights))))))
