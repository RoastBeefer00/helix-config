;; fidget.scm — fidget.nvim-style LSP progress overlay for helix-steel
;;
;; Shows active LSP WorkDoneProgress tasks in a floating panel in the
;; bottom-right corner. Auto-appears on the first LSP task and
;; disappears when all tasks complete.
;;
;; Requires: lsp-progress hook (mattwparas/helix PR #125)
;;
;; Usage in init.scm (after helix.scm):
;;   (require "fidget.scm")

(require "helix/misc.scm")
(require "helix/editor.scm")
(require-builtin helix/components)

(provide fidget-show! fidget-hide!)

;;;; Spinner

(define *spinner-frames* '("⣾" "⣽" "⣻" "⢿" "⡿" "⣟" "⣯" "⣷"))
(define *fidget-frame* 0)

(define (next-spinner-frame!)
  (define f (list-ref *spinner-frames* (modulo *fidget-frame* (length *spinner-frames*))))
  (set! *fidget-frame* (+ *fidget-frame* 1))
  f)

;;;; Item state
;;
;; *fidget-items* is an assoc list of (key . (list title message percentage)).
;; Mutations use set! since the hook fires from outside the component.

(define *fidget-items* '())
(define *fidget-visible* #f)

(define (fidget-upsert! key title message percentage)
  (define entry (list title message percentage))
  (if (assoc key *fidget-items*)
      (set! *fidget-items*
            (map (lambda (kv)
                   (if (equal? (car kv) key) (cons key entry) kv))
                 *fidget-items*))
      (set! *fidget-items* (append *fidget-items* (list (cons key entry))))))

(define (fidget-remove! key)
  (set! *fidget-items*
        (filter (lambda (kv) (not (equal? (car kv) key))) *fidget-items*)))

;;;; Rendering

(define *fidget-width* 46)

(define (for-each-indexed fn lst i)
  (unless (null? lst)
    (fn i (car lst))
    (for-each-indexed fn (cdr lst) (+ i 1))))

(define (fidget-format-label spin title message percentage)
  (define parts
    (filter string?
            (list (string-append spin " ")
                  (if (string? title) title #f)
                  (if (and (string? title) (string? message)) " · " #f)
                  (if (string? message) message #f)
                  (if (and (int? percentage) (> percentage 0))
                      (string-append " " (number->string percentage) "%")
                      #f))))
  (apply string-append parts))

(define (fidget-truncate str max-len)
  (if (> (string-length str) max-len)
      (string-append (substring str 0 (max 0 (- max-len 1))) "…")
      str))

(define (fidget-render state rect frame)
  (define items *fidget-items*)
  (unless (null? items)
    (define n (length items))
    ;; +2 for top/bottom border, +1 title row "LSP"
    (define height (+ n 3))
    (define x (max 0 (- (area-width rect) *fidget-width* 1)))
    (define y (max 0 (- (area-height rect) height 2)))
    (define block-area (area x y *fidget-width* height))

    (buffer/clear frame block-area)
    (block/render frame
                  block-area
                  (make-block (theme-scope "ui.statusline.inactive")
                              (theme-scope "ui.statusline.inactive")
                              "all"
                              "rounded"))

    (define title-style (theme-scope "ui.statusline"))
    (define label-style (theme-scope "ui.text"))
    (define inner-width (- *fidget-width* 4))
    (define spin (next-spinner-frame!))

    ;; Header row
    (frame-set-string! frame (+ x 2) (+ y 1) "LSP" title-style)

    ;; One row per task
    (for-each-indexed
     (lambda (i kv)
       (define item (cdr kv))
       (define title (car item))
       (define message (cadr item))
       (define percentage (caddr item))
       (define label (fidget-format-label spin title message percentage))
       (define display (fidget-truncate label inner-width))
       (frame-set-string! frame (+ x 2) (+ y 2 i) display label-style))
     items
     0)))

;;;; Event handler — fully transparent, passes everything through

(define (fidget-event-handler state event)
  event-result/ignore)

;;;; Component lifecycle

(define (fidget-show!)
  (unless *fidget-visible*
    (set! *fidget-visible* #t)
    (push-component!
     (new-component! "helix-fidget"
                     #f
                     fidget-render
                     (hash "handle_event" fidget-event-handler)))))

(define (fidget-hide!)
  (when *fidget-visible*
    (set! *fidget-visible* #f)
    (enqueue-thread-local-callback
     (lambda () (pop-last-component! "helix-fidget")))))

;;;; LSP progress hook

(define (fidget-on-lsp-progress server-name token kind title message percentage)
  (define key (string-append server-name ":" token))
  (cond
    [(equal? kind "begin")
     (fidget-upsert! key title message percentage)
     (fidget-show!)]
    [(equal? kind "report")
     ;; On report, preserve the original title if the server doesn't resend it
     (define existing (assoc key *fidget-items*))
     (define existing-title (if existing (car (cdr existing)) #f))
     (fidget-upsert! key (or title existing-title) message percentage)]
    [(equal? kind "end")
     (fidget-remove! key)
     (when (null? *fidget-items*)
       (fidget-hide!))]))

(register-hook! 'lsp-progress fidget-on-lsp-progress)
