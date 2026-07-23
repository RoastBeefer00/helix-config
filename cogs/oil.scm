;; oil.hx — an oil.nvim-style file manager, built entirely on top of
;; helix/buffer-types.scm (define-buffer-type + create-buffer!) instead of
;; the raw component API. The directory listing is a real, modally-editable
;; buffer: navigate it with normal Helix motions, edit lines to rename
;; things, delete a line to delete an entry, add a line to create one - then
;; `:w` shows what would happen and applies it only if you confirm.
;;
;; Copying uses Helix's own yank/paste (y/p), unmodified - there is no
;; oil-specific keybinding or command for it. A `post-command` hook
;; passively watches for the native "yank"/"paste_after"/"paste_before"
;; commands firing while an oil buffer is focused, reads what was
;; actually yanked/pasted via the register (register->value), and if it
;; matches an entry, stages a copy the same way a rename gets staged: `:w`
;; sees it in the diff and asks for confirmation like everything else. See
;; oil-observe-yank!/oil-observe-paste! below.
;;
;; Scope, deliberately: this is not a port of oil.nvim's full feature set
;; (no git-status hints, no hidden-file toggle, no cut - only copy). It
;; exists to exercise the new buffer-native plugin primitives end to end:
;; buffer-set-text!, buffer-set-keymap!, document-will-save (via on-write),
;; buffer-mark-saved!, and define-buffer-type/create-buffer! themselves.

(require "helix/buffer-types.scm")
(require "helix/keymaps.scm")
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require "helix/components.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)
;; add-scoped-inlay-hint has no helix/misc.scm wrapper (unlike its neighbors
;; add-inlay-hint/remove-inlay-hint-by-id, which do and are already in scope
;; via helix/misc.scm above) - reach it directly through the builtin module.
(require-builtin helix/core/misc as helix.core.)

(provide oil
         oil-enter
         oil-up
         oil-refresh
         oil-close)

(define OIL-TYPE "oil")
(define OIL-HIGHLIGHT-NS "oil-dirs")
(define OIL-PENDING-NS "oil-pending")

;; doc-id (usize) -> (hash 'dir string 'entries (listof string)
;;                         'pending-copies (hash display-name -> source full-path))
;; 'entries is the listing as of the last successful populate/apply - the
;; snapshot `:w` diffs the live buffer text against. 'pending-copies records
;; what a native paste inserted (see oil-observe-paste! below for why
;; it's keyed by name, and the caveat that implies), reset on every fresh
;; render. Entries for closed buffers are never removed (doc-ids aren't
;; reused, so this is a harmless leak, same tradeoff the underlying keymap
;; reverse-mapping table makes).
(define *oil-state* (hash))

;; The most recently observed native yank of an oil entry:
;; (list full-path is-dir? display-name-as-yanked), or #false. Global rather
;; than per-buffer, so yank in one directory and paste after navigating (or
;; in a different oil buffer entirely) works. display-name-as-yanked
;; is what oil-observe-paste! matches the pasted register content
;; against - if you yank something else in between (even outside any
;; oil buffer) before pasting, this no longer matches and the paste
;; is treated as plain text, not a copy.
(define *oil-clipboard* #false)

;; Doc-id of the most recently rendered oil buffer, or #false. Lets
;; oil (the open command) reuse an already-open instance - switching
;; to it and re-rendering for whatever directory was just requested - rather
;; than piling up a new buffer on every invocation.
(define *oil-last-doc-id* #false)

(define (oil-get-state doc-id)
  (define key (doc-id->usize doc-id))
  (if (hash-contains? *oil-state* key) (hash-get *oil-state* key) #false))

(define (oil-set-state! doc-id dir entries)
  (set! *oil-state*
        (hash-insert *oil-state* (doc-id->usize doc-id)
                     (hash 'dir dir 'entries entries 'pending-copies (hash)))))

;; Records that `name` (as it currently reads in the buffer) was inserted by
;; a native paste, sourced from `source`. Leaves 'dir/'entries untouched.
(define (oil-record-copy! doc-id name source)
  (define key (doc-id->usize doc-id))
  (define st (oil-get-state doc-id))
  (when st
    (let* ([pending (hash-get st 'pending-copies)])
      (set! *oil-state*
            (hash-insert *oil-state* key
                         (hash-insert st 'pending-copies (hash-insert pending name source)))))))

;; ---------------------------------------------------------------------
;; Paths
;; ---------------------------------------------------------------------

(define (oil-path-join base name)
  (string-append (trim-end-matches base (path-separator)) (path-separator) name))

(define (oil-basename full-path)
  (define parts (filter (lambda (s) (> (string-length s) 0)) (split-many full-path (path-separator))))
  (if (null? parts) full-path (list-ref parts (- (length parts) 1))))

;; Directories are marked in the listing (and in the buffer text) with a
;; trailing path separator, same convention oil.nvim uses.
(define (oil-dir-entry? name)
  (ends-with? name (path-separator)))

(define (oil-full-path dir name)
  (oil-path-join dir (trim-end-matches name (path-separator))))

;; Removes the first occurrence of `name` from `lst` (used to check whether
;; a just-pasted name collides with anything *other than itself*).
(define (oil-remove-one name lst)
  (cond
    [(null? lst) '()]
    [(string=? (car lst) name) (cdr lst)]
    [else (cons (car lst) (oil-remove-one name (cdr lst)))]))

;; ---------------------------------------------------------------------
;; Icons
;; ---------------------------------------------------------------------
;; REQUIRES a Nerd Font (https://www.nerdfonts.com) in your terminal - these
;; are private-use-area codepoints with no meaning (typically a blank box)
;; outside a patched font. This is the one piece of this plugin I could not
;; visually verify: everything else got checked live (raw text + ANSI color
;; codes), but there's no way to confirm from here that a given PUA
;; codepoint paints the glyph shape it's supposed to. Codepoints below are
;; the standard, widely-used ones for their file kind (Font Awesome where
;; one exists - folder/file/lock/terminal/html5/css3/cog - the
;; language-specific ones are the common devicons codepoints), but if
;; anything renders as a box or the wrong shape in your terminal, this table
;; is the only place that needs fixing.
(define OIL-ICON-DIR (cons "" "info"))
(define OIL-ICON-FILE (cons "" "ui.text"))
(define OIL-ICON-TABLE
  (hash "rs"   (cons "" "keyword")
        "go"   (cons "" "type")
        "py"   (cons "" "function")
        "rb"   (cons "" "constant")
        "php"  (cons "" "variable")
        "js"   (cons "" "attribute")
        "jsx"  (cons "" "attribute")
        "ts"   (cons "" "type.builtin")
        "tsx"  (cons "" "type.builtin")
        "c"    (cons "" "operator")
        "h"    (cons "" "operator")
        "cpp"  (cons "" "namespace")
        "hpp"  (cons "" "namespace")
        "java" (cons "" "keyword.control")
        "md"   (cons "" "markup.heading")
        "json" (cons "" "string")
        "toml" (cons "" "special")
        "yaml" (cons "" "special")
        "yml"  (cons "" "special")
        "lock" (cons "" "warning")
        "sh"   (cons "" "function.builtin")
        "html" (cons "" "tag")
        "css"  (cons "" "constructor")
        "scm"  (cons "" "punctuation.bracket")
        "svelte" (cons "" "keyword.directive")
        "nix"    (cons "" "keyword.storage")
        "lua"    (cons "" "variable.builtin")))

;; The substring after the last "." in `name`, or #false if there isn't one.
(define (oil-extension name)
  (define parts (split-many name "."))
  (if (< (length parts) 2) #false (list-ref parts (- (length parts) 1))))

;; (icon . scope) for `name`. The scope is a best-effort, real-and-confirmed
;; Helix theme scope loosely fitting the language's usual brand color (e.g.
;; "keyword" for Rust, often orange/red-ish) - Helix doesn't expose raw RGB
;; to plugins, only theme scopes, so exact brand-color matching isn't
;; possible; this aims for "visually distinct and roughly fitting; exact
;; hue depends on your theme," not pixel-perfect devicons parity.
(define (oil-icon-and-scope-for name)
  (if (oil-dir-entry? name)
      OIL-ICON-DIR
      (let ([ext (oil-extension (trim-end-matches name (path-separator)))])
        (if (and ext (hash-contains? OIL-ICON-TABLE ext))
            (hash-get OIL-ICON-TABLE ext)
            OIL-ICON-FILE))))

;; ---------------------------------------------------------------------
;; Listing / rendering
;; ---------------------------------------------------------------------

;; Directories (alphabetical) first, then files (alphabetical) - matches the
;; usual file-manager convention. "../" is not part of this list; it's
;; prepended separately, always first regardless.
(define (oil-read-entries dir)
  (define raw (with-handler
               (lambda (err) (error (string-append "oil: cannot read directory: "
                                                    (error-object-message err))))
               (read-dir dir)))
  (define named
    (map (lambda (full)
           (define base (oil-basename full))
           (if (is-file? full) base (string-append base (path-separator))))
         raw))
  (define dirs (sort (filter oil-dir-entry? named) string<?))
  (define files (sort (filter (lambda (n) (not (oil-dir-entry? n))) named) string<?))
  (append dirs files))

;; No header line - the directory is shown as the buffer's name (status
;; line / bufferline) instead, via set-scratch-buffer-name! in render!
;; below, so the buffer's actual text is only ever real entries. "../" is
;; always first, so the parent directory is reachable both by editing the
;; buffer (rare) and via oil-up (normal case).
(define (oil-listing-text entries)
  (string-join (cons "../" entries) "\n"))

;; Icons are virtual text (add-scoped-inlay-hint), never real buffer
;; characters - critical, since real characters would show up in
;; oil-parse-buffer and corrupt the diff. Each call returns a
;; (first-line . last-line) id, same shape remove-inlay-hint-by-id expects.
(define (oil-clear-icons! doc-id)
  (define st (oil-get-state doc-id))
  (when (and st (hash-contains? st 'icon-ids))
    (for-each (lambda (id) (remove-inlay-hint-by-id (list-ref id 0) (list-ref id 1)))
              (hash-get st 'icon-ids))))

(define (oil-set-icon-ids! doc-id ids)
  (define key (doc-id->usize doc-id))
  (define st (oil-get-state doc-id))
  (when st
    (set! *oil-state* (hash-insert *oil-state* key (hash-insert st 'icon-ids ids)))))

;; (name . (start . end)) for every non-blank line in the *current* buffer
;; text, re-parsed live on every call rather than assumed from whatever was
;; last rendered - this is what makes decorations (below) correct after an
;; edit shifts lines around, instead of drifting onto the wrong line the way
;; a one-shot-at-render computation would.
(define (oil-line-ranges doc-id)
  (define lines (split-many (text.rope->string (editor->text doc-id)) "\n"))
  (let loop ([offset 0] [remaining lines] [ranges '()])
    (cond
      [(null? remaining) (reverse ranges)]
      [else
       (let* ([line (car remaining)]
              [end (+ offset (string-length line))]
              [trimmed (trim line)]
              [next (if (> (string-length trimmed) 0)
                        (cons (cons trimmed (cons offset end)) ranges)
                        ranges)])
         (loop (+ end 1) (cdr remaining) next))])))

;; Recomputes and reapplies every visual decoration - directory-name color,
;; per-language icons, and the pending-change (gray) highlight - from
;; scratch, from the buffer's current text. Called after every edit
;; (oil-on-change) as well as after every render, rather than trying
;; to incrementally track individual decorations through arbitrary edits:
;; deleting a line, for instance, doesn't just shift everything after it, it
;; removes a line's worth of *identity*, and a hint or highlight that was
;; "attached" to that line only by character position has no way to know it
;; should disappear rather than land on whatever now occupies that spot.
;; Recomputing fresh sidesteps that class of bug entirely.
(define (oil-refresh-decorations! doc-id)
  (define st (oil-get-state doc-id))
  (when st
    (let* ([line-ranges (oil-line-ranges doc-id)]
           [dir-ranges (map cdr (filter (lambda (p) (oil-dir-entry? (car p))) line-ranges))]
           [new-icon-ids (begin
                           (oil-clear-icons! doc-id)
                           (map (lambda (p)
                                  (let* ([name (car p)]
                                         [start (car (cdr p))]
                                         [icon-scope (oil-icon-and-scope-for name)])
                                    (helix.core.add-scoped-inlay-hint
                                     start (string-append (car icon-scope) " ") (cdr icon-scope))))
                                line-ranges))]
           [diff (oil-compute-diff (hash-get st 'entries) (oil-parse-buffer doc-id)
                                           (hash-get st 'pending-copies))]
           [pending-names (append (map cdr (hash-get diff 'renames))
                                   (hash-get diff 'creates)
                                   (map cdr (hash-get diff 'copies)))]
           [pending-ranges (map cdr (filter (lambda (p) (member (car p) pending-names)) line-ranges))])
      (set-document-highlights! OIL-HIGHLIGHT-NS dir-ranges "info")
      (oil-set-icon-ids! doc-id new-icon-ids)
      (if (null? pending-ranges)
          (clear-document-highlights! OIL-PENDING-NS)
          (set-document-highlights! OIL-PENDING-NS pending-ranges "comment")))))

;; Populate the *currently focused* buffer with a listing for `dir`, name
;; the buffer after `dir`, and record it as the clean state to diff against.
;; Used both for the initial create-buffer! content and for in-place
;; navigation (enter/up/refresh), which reuse the same buffer instead of
;; creating a new one each time.
(define (oil-render! doc-id dir)
  (define entries (oil-read-entries dir))
  (oil-clear-icons! doc-id) ; uses the OLD state's icon-ids, before set-state! below replaces them
  (buffer-set-text! (oil-listing-text entries))
  (set-scratch-buffer-name! dir)
  (set-bufferline-name! "oil")
  (oil-set-state! doc-id dir entries)
  (oil-refresh-decorations! doc-id)
  (set! *oil-last-doc-id* doc-id)
  (helix.goto-line 1))

(define (oil-parse-buffer doc-id)
  (define text (text.rope->string (editor->text doc-id)))
  (define lines (split-many text "\n"))
  (filter (lambda (e) (and (> (string-length e) 0) (not (string=? e "../"))))
          (map trim lines)))

;; ---------------------------------------------------------------------
;; Diffing: buffer text (now) vs the last-rendered listing (then)
;; ---------------------------------------------------------------------

;; Positionally pairs same-type (dir-with-dir, file-with-file) removed/added
;; names as renames; anything left over after one side runs out is a plain
;; delete or create. This is a simple heuristic, not identity tracking - a
;; single-line rename is always paired correctly; several simultaneous
;; renames may pair in an order you didn't intend. The confirm prompt always
;; shows exactly what's about to happen, so nothing is ever silently wrong.
(define (oil-pair-same-type removed added)
  (let loop ([rem removed] [add added] [renames '()])
    (cond
      [(or (null? rem) (null? add)) (list (reverse renames) rem add)]
      [else (loop (cdr rem) (cdr add) (cons (cons (car rem) (car add)) renames))])))

;; `pending-copies` (display-name -> source full-path, from a native paste)
;; is consulted first: any added name found there becomes a copy op instead
;; of a plain create, and is removed from consideration for rename pairing.
;; If a pasted line was renamed before saving, its name no longer matches
;; what's in pending-copies, so it falls back to being treated as a plain
;; create (or gets pulled into rename pairing like any other added name) -
;; paste-then-save without renaming is the supported path.
(define (oil-compute-diff old-names new-names pending-copies)
  (define added-all (filter (lambda (n) (not (member n old-names))) new-names))
  (define copy-names (filter (lambda (n) (hash-contains? pending-copies n)) added-all))
  (define removed (filter (lambda (n) (not (member n new-names))) old-names))
  (define added (filter (lambda (n) (not (member n copy-names))) added-all))
  (define rem-dirs (filter oil-dir-entry? removed))
  (define rem-files (filter (lambda (n) (not (oil-dir-entry? n))) removed))
  (define add-dirs (filter oil-dir-entry? added))
  (define add-files (filter (lambda (n) (not (oil-dir-entry? n))) added))
  (define dir-result (oil-pair-same-type rem-dirs add-dirs))
  (define file-result (oil-pair-same-type rem-files add-files))
  (hash 'renames (append (list-ref dir-result 0) (list-ref file-result 0))
        'deletes (append (list-ref dir-result 1) (list-ref file-result 1))
        'creates (append (list-ref dir-result 2) (list-ref file-result 2))
        'copies (map (lambda (n) (cons (hash-get pending-copies n) n)) copy-names)))

(define (oil-diff-total diff)
  (+ (length (hash-get diff 'renames))
     (length (hash-get diff 'deletes))
     (length (hash-get diff 'creates))
     (length (hash-get diff 'copies))))

;; ---------------------------------------------------------------------
;; Filesystem operations
;; ---------------------------------------------------------------------

(define (oil-run! program args)
  (define proc (~> (command program args) with-stdout-piped with-stderr-piped spawn-process))
  (if (Ok? proc)
      (let ([stderr (trim (read-port-to-string (child-stderr (Ok->value proc))))])
        (when (not (string=? stderr "")) (error stderr)))
      (error (string-append program ": could not spawn process"))))

;; Two-phase (via a temp name) so that e.g. swapping two entries' names in
;; the same batch can't clobber one with the other mid-rename.
(define (oil-apply-renames! dir renames)
  (define actual (filter (lambda (p) (not (string=? (car p) (cdr p)))) renames))
  (for-each (lambda (p)
              (oil-run! "mv"
                                (list (oil-full-path dir (car p))
                                      (string-append (oil-full-path dir (car p)) ".~oil~"))))
            actual)
  (for-each (lambda (p)
              (oil-run! "mv"
                                (list (string-append (oil-full-path dir (car p)) ".~oil~")
                                      (oil-full-path dir (cdr p)))))
            actual))

(define (oil-delete! dir name)
  (define path (oil-full-path dir name))
  (if (oil-dir-entry? name)
      (delete-directory! path) ; only removes empty directories
      (delete-file! path)))

(define (oil-create! dir name)
  (define path (oil-full-path dir name))
  (if (oil-dir-entry? name)
      (oil-run! "mkdir" (list "-p" path))
      (call-with-output-file path (lambda (_p) #t))))

;; -r copies directories recursively and works fine for a plain file too.
(define (oil-copy! source dir name)
  (oil-run! "cp" (list "-r" source (oil-full-path dir name))))

;; Applies a diff, collecting errors from each individual operation instead
;; of aborting on the first one, then reports success/failure and always
;; refreshes the buffer to reflect whatever the filesystem actually ended up
;; as (which, on partial failure, may not match every requested change).
(define (oil-apply! doc-id dir diff)
  (define errors '())
  (define (try! label thunk)
    (with-handler (lambda (err) (set! errors (cons (string-append label ": " (error-object-message err)) errors)))
                  (thunk)))
  (try! "rename" (lambda () (oil-apply-renames! dir (hash-get diff 'renames))))
  (for-each (lambda (n) (try! (string-append "delete " n) (lambda () (oil-delete! dir n))))
            (hash-get diff 'deletes))
  (for-each (lambda (n) (try! (string-append "create " n) (lambda () (oil-create! dir n))))
            (hash-get diff 'creates))
  (for-each (lambda (p) (try! (string-append "copy " (car p) " -> " (cdr p))
                               (lambda () (oil-copy! (car p) dir (cdr p)))))
            (hash-get diff 'copies))
  (oil-render! doc-id dir)
  (if (null? errors)
      (begin (buffer-mark-saved!)
             (set-status! (string-append "oil: applied " (number->string (oil-diff-total diff))
                                          " change(s)")))
      (set-error! (string-join (reverse errors) "; "))))

;; ---------------------------------------------------------------------
;; Confirm dialog
;; ---------------------------------------------------------------------
;; A floating box listing exactly what :w is about to do, built with
;; new-component! instead of a plain (prompt ...) y/N text line, so the
;; user sees every rename/delete/create/copy before approving anything.

(define (oil-diff-lines diff)
  (append
   (map (lambda (p) (cons (string-append "  ~ " (car p) " -> " (cdr p)) "diff.delta"))
        (hash-get diff 'renames))
   (map (lambda (n) (cons (string-append "  - " n) "diff.minus")) (hash-get diff 'deletes))
   (map (lambda (n) (cons (string-append "  + " n) "diff.plus")) (hash-get diff 'creates))
   (map (lambda (p)
          (cons (string-append "  + " (cdr p) " (copy of " (oil-basename (car p)) ")")
                "diff.delta.moved"))
        (hash-get diff 'copies))))

;; Plain recursion instead of (for-each ... (range 0 n)) - `range` here
;; resolves to a Helix selection Range constructor (shadowed by one of the
;; helix/*.scm requires above), not the stdlib integer-range builtin.
(define (oil-confirm-draw-lines frame x y lines i limit)
  (when (and (< i limit) (pair? lines))
    (let ([p (car lines)])
      (frame-set-string! frame (+ x 2) (+ y 2 i) (car p) (theme-scope (cdr p))))
    (oil-confirm-draw-lines frame x y (cdr lines) (+ i 1) limit)))

(define (oil-confirm-render state rect frame)
  (define lines (hash-get state 'lines))
  (define total (length lines))
  (define title (hash-get state 'title))
  (define box-width
    (min (max 10 (- (area-width rect) 4))
         (max 48 (+ 4 (apply max (string-length title) (map (lambda (p) (string-length (car p))) lines))))))
  (define box-height (min (max 10 (- (area-height rect) 4)) (+ total 5)))
  (define x (+ (area-x rect) (quotient (- (area-width rect) box-width) 2)))
  (define y (+ (area-y rect) (quotient (- (area-height rect) box-height) 2)))
  (define box-area (area x y box-width box-height))
  (define visible (max 0 (- box-height 4)))
  (define truncated? (> total visible))
  (define shown (if truncated? (max 0 (- visible 1)) visible))
  (buffer/clear frame box-area)
  (block/render frame box-area (block))
  (frame-set-string! frame (+ x 2) y title (theme-scope "ui.text.focus"))
  (oil-confirm-draw-lines frame x y lines 0 (min shown total))
  (when truncated?
    (frame-set-string! frame (+ x 2)
                        (+ y 2 shown)
                        (string-append "  ... and " (number->string (- total shown)) " more")
                        (theme-scope "comment")))
  (frame-set-string! frame (+ x 2) (+ y box-height -2) "[y] apply     [n / Esc] cancel" (theme-scope "ui.text")))

(define (oil-confirm-event-handler state event)
  (define char (key-event-char event))
  (cond
    [(or (key-event-enter? event) (equal? char #\y) (equal? char #\Y))
     ((hash-get state 'on-confirm))
     event-result/close]
    [(or (key-event-escape? event) (equal? char #\n) (equal? char #\N))
     ((hash-get state 'on-cancel))
     event-result/close]
    [else event-result/consume]))

;; Pushes the floating confirm box. `diff` is applied via `on-confirm` if the
;; user accepts, or silently discarded via `on-cancel` if they don't -
;; nothing touches the filesystem until then.
(define (oil-confirm! doc-id dir diff)
  (define state
    (hash 'lines (oil-diff-lines diff)
          'title
          (string-append "oil: apply " (number->string (oil-diff-total diff)) " change(s)?")
          'on-confirm (lambda () (oil-apply! doc-id dir diff))
          'on-cancel (lambda () (set-status! "oil: cancelled, no changes applied"))))
  (define comp
    (new-component! "oil-confirm"
                     state
                     oil-confirm-render
                     (hash "handle_event" oil-confirm-event-handler)))
  ;; `overlaid` mutates `comp` in place (centers it at 90%x90% of the
  ;; viewport) rather than returning a new value - it does not compose.
  (overlaid comp)
  (push-component! comp))

;; ---------------------------------------------------------------------
;; Buffer type
;; ---------------------------------------------------------------------

(define (oil-on-write doc-id path)
  (define st (oil-get-state doc-id))
  (when st
    (let* ([dir (hash-get st 'dir)]
           [diff (oil-compute-diff (hash-get st 'entries)
                                           (oil-parse-buffer doc-id)
                                           (hash-get st 'pending-copies))])
      (if (= (oil-diff-total diff) 0)
          (begin (buffer-mark-saved!) (set-status! "oil: nothing to do"))
          (oil-confirm! doc-id dir diff))))
  #true) ; always intercept the literal write - this buffer is never a real file

(define (oil-on-change doc-id old-text)
  (oil-refresh-decorations! doc-id))

(define-buffer-type
 OIL-TYPE
 ;; No y/p bindings here on purpose - copy rides on native yank/paste via
 ;; the post-command hook further down, not a buffer-local override.
 (hash 'keymap (keymap (normal (ret ":oil-enter")
                                (- ":oil-up")
                                (q ":oil-close")
                                (R ":oil-refresh")))
       'on-write oil-on-write
       'on-change oil-on-change))

;; ---------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------

;;@doc
;; Open the file manager for the current file's directory (or the Helix cwd
;; for an unnamed buffer), or for an explicit directory if one is passed
;; (e.g. `hx .` calls `(oil ".")` at startup instead of opening the native
;; file picker - see application.rs). If an oil buffer is already open
;; somewhere, switches to that instance and re-renders it for this
;; directory instead of opening a new one.
(define (oil . args)
  (define dir
    (if (pair? args)
        (car args)
        (let* ([doc-id (editor->doc-id (editor-focus))]
               [path (editor-document->path doc-id)])
          (if path (parent-name path) (get-helix-cwd)))))
  (define target-id
    (if (and *oil-last-doc-id* (editor-doc-exists? *oil-last-doc-id*))
        (begin (editor-switch-action! *oil-last-doc-id* (Action/Replace))
               *oil-last-doc-id*)
        (create-buffer! OIL-TYPE)))
  (oil-render! target-id dir))

(define (oil-current-doc-id)
  (editor->doc-id (editor-focus)))

;;@doc
;; Enter the directory under the cursor, or open the file under the cursor.
(define (oil-enter)
  (define doc-id (oil-current-doc-id))
  (define st (oil-get-state doc-id))
  (when st
    (let* ([dir (hash-get st 'dir)]
           [line-n (get-current-line-number)]
           [lines (split-many (text.rope->string (editor->text doc-id)) "\n")]
           [entry (and (< line-n (length lines)) (trim (list-ref lines line-n)))])
      (cond
        [(or (not entry) (string=? entry "")) #f]
        [(string=? entry "../") (oil-render! doc-id (parent-name dir))]
        [(oil-dir-entry? entry)
         (oil-render! doc-id (oil-full-path dir entry))]
        [else (helix.open (oil-full-path dir entry))]))))

;;@doc
;; Go to the parent directory.
(define (oil-up)
  (define doc-id (oil-current-doc-id))
  (define st (oil-get-state doc-id))
  (when st (oil-render! doc-id (parent-name (hash-get st 'dir)))))

;;@doc
;; Reload the current directory from disk, discarding any unsaved edits.
(define (oil-refresh)
  (define doc-id (oil-current-doc-id))
  (define st (oil-get-state doc-id))
  (when st (oil-render! doc-id (hash-get st 'dir))))

;;@doc
;; Close the file manager buffer.
(define (oil-close)
  (helix.buffer-close))

;; ---------------------------------------------------------------------
;; Copy, via native yank/paste
;; ---------------------------------------------------------------------
;; No oil command or keybinding for either half of this - native y
;; yanks a selection to a register as always, native p pastes it as always.
;; A post-command hook (registered below) just watches for those two
;; commands firing while an oil buffer is focused and, if what was
;; yanked/pasted matches a real entry, stages a copy op the same way any
;; other edit gets staged: nothing happens until `:w` confirms it.
;;
;; This means: select the *whole line* before yanking (e.g. `x` then `y`) -
;; a partial-line yank won't match any entry and is just left as a normal
;; text yank. And paste-then-rename-before-saving degrades to a plain
;; create, same caveat as with rename pairing above.

(define (oil-observe-yank! doc-id)
  (define st (oil-get-state doc-id))
  (define dir (hash-get st 'dir))
  (define reg-values (register->value (selected-register!)))
  (define yanked (and (pair? reg-values) (trim (car reg-values))))
  (define known-entries (cons "../" (hash-get st 'entries)))
  (when (and yanked (> (string-length yanked) 0) (member yanked known-entries)
             (not (string=? yanked "../")))
    (set! *oil-clipboard*
          (list (oil-full-path dir yanked) (oil-dir-entry? yanked) yanked))))

(define (oil-observe-paste! doc-id)
  (define reg-values (register->value (selected-register!)))
  (define pasted-text (and (pair? reg-values) (trim (car reg-values))))
  (when (and *oil-clipboard* pasted-text
             (string=? pasted-text (list-ref *oil-clipboard* 2)))
    (let* ([line-n (get-current-line-number)]
           [lines (split-many (text.rope->string (editor->text doc-id)) "\n")]
           [on-line (and (< line-n (length lines)) (trim (list-ref lines line-n)))])
      (when (and on-line (string=? on-line pasted-text))
        (let* ([source (list-ref *oil-clipboard* 0)]
               [current-names (oil-parse-buffer doc-id)]
               [background (oil-remove-one pasted-text current-names)])
          (if (member pasted-text background)
              (set-error! (string-append "oil: \"" pasted-text
                                          "\" already exists here - rename one of them, then paste again"))
              (begin
                (oil-record-copy! doc-id pasted-text source)
                (set-status! (string-append "oil: staged copy of " (oil-basename source)
                                             " as " pasted-text " (pending - :w to apply)")))))))))

(register-hook 'post-command
               (lambda (command-name)
                 ;; `editor->doc-id` can return #false here - e.g. the focused
                 ;; view can already be torn down by the time this fires during
                 ;; quit - so doc-id must be checked before it's used as a key.
                 (let* ([doc-id (editor->doc-id (editor-focus))]
                        [st (and doc-id (oil-get-state doc-id))])
                   (when st
                     (when (string=? command-name "yank") (oil-observe-yank! doc-id))
                     (when (or (string=? command-name "paste_after") (string=? command-name "paste_before"))
                       (oil-observe-paste! doc-id))))))
