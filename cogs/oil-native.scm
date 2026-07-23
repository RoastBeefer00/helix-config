;; oil-native.hx — an oil.nvim-style file manager, built entirely on top of
;; helix/buffer-types.scm (define-buffer-type + create-buffer!) instead of
;; the raw component API. The directory listing is a real, modally-editable
;; buffer: navigate it with normal Helix motions, edit lines to rename
;; things, delete a line to delete an entry, add a line to create one - then
;; `:w` shows what would happen and applies it only if you confirm.
;;
;; Copying uses Helix's own yank/paste (y/p), unmodified - there is no
;; oil-native-specific keybinding or command for it. A `post-command` hook
;; passively watches for the native "yank"/"paste_after"/"paste_before"
;; commands firing while an oil-native buffer is focused, reads what was
;; actually yanked/pasted via the register (register->value), and if it
;; matches an entry, stages a copy the same way a rename gets staged: `:w`
;; sees it in the diff and asks for confirmation like everything else. See
;; oil-native-observe-yank!/oil-native-observe-paste! below.
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
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)
;; add-scoped-inlay-hint has no helix/misc.scm wrapper (unlike its neighbors
;; add-inlay-hint/remove-inlay-hint-by-id, which do and are already in scope
;; via helix/misc.scm above) - reach it directly through the builtin module.
(require-builtin helix/core/misc as helix.core.)

(provide oil-native
         oil-native-enter
         oil-native-up
         oil-native-refresh
         oil-native-close)

(define OIL-NATIVE-TYPE "oil-native")
(define OIL-NATIVE-BUFFER-NAME "*oil-native*")
(define OIL-NATIVE-HIGHLIGHT-NS "oil-native-dirs")
(define OIL-NATIVE-PENDING-NS "oil-native-pending")

;; doc-id (usize) -> (hash 'dir string 'entries (listof string)
;;                         'pending-copies (hash display-name -> source full-path))
;; 'entries is the listing as of the last successful populate/apply - the
;; snapshot `:w` diffs the live buffer text against. 'pending-copies records
;; what a native paste inserted (see oil-native-observe-paste! below for why
;; it's keyed by name, and the caveat that implies), reset on every fresh
;; render. Entries for closed buffers are never removed (doc-ids aren't
;; reused, so this is a harmless leak, same tradeoff the underlying keymap
;; reverse-mapping table makes).
(define *oil-native-state* (hash))

;; The most recently observed native yank of an oil-native entry:
;; (list full-path is-dir? display-name-as-yanked), or #false. Global rather
;; than per-buffer, so yank in one directory and paste after navigating (or
;; in a different oil-native buffer entirely) works. display-name-as-yanked
;; is what oil-native-observe-paste! matches the pasted register content
;; against - if you yank something else in between (even outside any
;; oil-native buffer) before pasting, this no longer matches and the paste
;; is treated as plain text, not a copy.
(define *oil-native-clipboard* #false)

(define (oil-native-get-state doc-id)
  (define key (doc-id->usize doc-id))
  (if (hash-contains? *oil-native-state* key) (hash-get *oil-native-state* key) #false))

(define (oil-native-set-state! doc-id dir entries)
  (set! *oil-native-state*
        (hash-insert *oil-native-state* (doc-id->usize doc-id)
                     (hash 'dir dir 'entries entries 'pending-copies (hash)))))

;; Records that `name` (as it currently reads in the buffer) was inserted by
;; a native paste, sourced from `source`. Leaves 'dir/'entries untouched.
(define (oil-native-record-copy! doc-id name source)
  (define key (doc-id->usize doc-id))
  (define st (oil-native-get-state doc-id))
  (when st
    (let* ([pending (hash-get st 'pending-copies)])
      (set! *oil-native-state*
            (hash-insert *oil-native-state* key
                         (hash-insert st 'pending-copies (hash-insert pending name source)))))))

;; ---------------------------------------------------------------------
;; Paths
;; ---------------------------------------------------------------------

(define (oil-native-path-join base name)
  (string-append (trim-end-matches base (path-separator)) (path-separator) name))

(define (oil-native-basename full-path)
  (define parts (filter (lambda (s) (> (string-length s) 0)) (split-many full-path (path-separator))))
  (if (null? parts) full-path (list-ref parts (- (length parts) 1))))

;; Directories are marked in the listing (and in the buffer text) with a
;; trailing path separator, same convention oil.nvim uses.
(define (oil-native-dir-entry? name)
  (ends-with? name (path-separator)))

(define (oil-native-full-path dir name)
  (oil-native-path-join dir (trim-end-matches name (path-separator))))

;; Removes the first occurrence of `name` from `lst` (used to check whether
;; a just-pasted name collides with anything *other than itself*).
(define (oil-native-remove-one name lst)
  (cond
    [(null? lst) '()]
    [(string=? (car lst) name) (cdr lst)]
    [else (cons (car lst) (oil-native-remove-one name (cdr lst)))]))

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
(define OIL-NATIVE-ICON-DIR "")
(define OIL-NATIVE-ICON-FILE "")
(define OIL-NATIVE-ICON-TABLE
  (hash "rs" "" "go" "" "py" "" "rb" "" "php" ""
        "js" "" "jsx" "" "ts" "" "tsx" ""
        "c" "" "h" "" "cpp" "" "hpp" "" "java" ""
        "md" "" "json" "" "toml" "" "yaml" "" "yml" ""
        "lock" "" "sh" "" "html" "" "css" ""))

;; The substring after the last "." in `name`, or #false if there isn't one.
(define (oil-native-extension name)
  (define parts (split-many name "."))
  (if (< (length parts) 2) #false (list-ref parts (- (length parts) 1))))

(define (oil-native-icon-for name)
  (if (oil-native-dir-entry? name)
      OIL-NATIVE-ICON-DIR
      (let ([ext (oil-native-extension (trim-end-matches name (path-separator)))])
        (if (and ext (hash-contains? OIL-NATIVE-ICON-TABLE ext))
            (hash-get OIL-NATIVE-ICON-TABLE ext)
            OIL-NATIVE-ICON-FILE))))

;; ---------------------------------------------------------------------
;; Listing / rendering
;; ---------------------------------------------------------------------

(define (oil-native-read-entries dir)
  (define raw (with-handler
               (lambda (err) (error (string-append "oil-native: cannot read directory: "
                                                    (error-object-message err))))
               (read-dir dir)))
  (map (lambda (full)
         (define base (oil-native-basename full))
         (if (is-file? full) base (string-append base (path-separator))))
       raw))

;; Header (directory path) is line 1 and is never treated as an entry.
;; "../" is always the first entry so the parent directory is reachable both
;; by editing the buffer (rare) and via oil-native-up (normal case).
(define (oil-native-listing-text dir entries)
  (string-append dir "\n" (string-join (cons "../" entries) "\n")))

;; Char ranges for every directory-looking line, to hand to
;; set-document-highlights!. Computed directly while walking the same list
;; used to build the text above, rather than re-parsing the buffer - simpler
;; and always in sync with what was just written.
(define (oil-native-dir-highlight-ranges dir entries)
  (define start0 (+ (string-length dir) 1)) ; skip "dir\n"
  (let loop ([offset start0] [remaining (cons "../" entries)] [ranges '()])
    (cond
      [(null? remaining) (reverse ranges)]
      [else
       (let* ([name (car remaining)]
              [end (+ offset (string-length name))]
              [next (if (oil-native-dir-entry? name) (cons (cons offset end) ranges) ranges)])
         (loop (+ end 1) (cdr remaining) next))])))

;; Icons are virtual text (add-scoped-inlay-hint), never real buffer
;; characters - critical, since real characters would show up in
;; oil-native-parse-buffer and corrupt the diff. Each call returns a
;; (first-line . last-line) id, same shape remove-inlay-hint-by-id expects;
;; tracked per-doc-id in state so navigating (which re-renders in place)
;; clears the previous directory's icons before drawing the new one's.
(define (oil-native-clear-icons! doc-id)
  (define st (oil-native-get-state doc-id))
  (when (and st (hash-contains? st 'icon-ids))
    (for-each (lambda (id) (remove-inlay-hint-by-id (list-ref id 0) (list-ref id 1)))
              (hash-get st 'icon-ids))))

(define (oil-native-apply-icons! dir entries)
  (define start0 (+ (string-length dir) 1)) ; skip "dir\n"
  (let loop ([offset start0] [remaining (cons "../" entries)] [ids '()])
    (cond
      [(null? remaining) ids]
      [else
       (let* ([name (car remaining)]
              [icon (oil-native-icon-for name)]
              [scope (if (oil-native-dir-entry? name) "constant" "ui.text")]
              [id (helix.core.add-scoped-inlay-hint offset (string-append icon " ") scope)])
         (loop (+ offset (string-length name) 1) (cdr remaining) (cons id ids)))])))

(define (oil-native-set-icon-ids! doc-id ids)
  (define key (doc-id->usize doc-id))
  (define st (oil-native-get-state doc-id))
  (when st
    (set! *oil-native-state* (hash-insert *oil-native-state* key (hash-insert st 'icon-ids ids)))))

;; Populate the *currently focused* buffer with a listing for `dir` and
;; record it as the clean state to diff against. Used both for the initial
;; create-buffer! content and for in-place navigation (enter/up/refresh),
;; which reuse the same buffer instead of creating a new one each time.
(define (oil-native-render! doc-id dir)
  (define entries (oil-native-read-entries dir))
  (oil-native-clear-icons! doc-id) ; must run before set-state! below replaces the old icon-ids
  (buffer-set-text! (oil-native-listing-text dir entries))
  (set-document-highlights! OIL-NATIVE-HIGHLIGHT-NS
                             (oil-native-dir-highlight-ranges dir entries)
                             "constant")
  (oil-native-set-state! doc-id dir entries)
  (oil-native-set-icon-ids! doc-id (oil-native-apply-icons! dir entries))
  (helix.goto-line 2))

(define (oil-native-parse-buffer doc-id)
  (define text (text.rope->string (editor->text doc-id)))
  (define lines (split-many text "\n"))
  (define body (if (null? lines) '() (cdr lines))) ; drop the header line
  (filter (lambda (e) (and (> (string-length e) 0) (not (string=? e "../"))))
          (map trim body)))

;; ---------------------------------------------------------------------
;; Diffing: buffer text (now) vs the last-rendered listing (then)
;; ---------------------------------------------------------------------

;; Positionally pairs same-type (dir-with-dir, file-with-file) removed/added
;; names as renames; anything left over after one side runs out is a plain
;; delete or create. This is a simple heuristic, not identity tracking - a
;; single-line rename is always paired correctly; several simultaneous
;; renames may pair in an order you didn't intend. The confirm prompt always
;; shows exactly what's about to happen, so nothing is ever silently wrong.
(define (oil-native-pair-same-type removed added)
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
(define (oil-native-compute-diff old-names new-names pending-copies)
  (define added-all (filter (lambda (n) (not (member n old-names))) new-names))
  (define copy-names (filter (lambda (n) (hash-contains? pending-copies n)) added-all))
  (define removed (filter (lambda (n) (not (member n new-names))) old-names))
  (define added (filter (lambda (n) (not (member n copy-names))) added-all))
  (define rem-dirs (filter oil-native-dir-entry? removed))
  (define rem-files (filter (lambda (n) (not (oil-native-dir-entry? n))) removed))
  (define add-dirs (filter oil-native-dir-entry? added))
  (define add-files (filter (lambda (n) (not (oil-native-dir-entry? n))) added))
  (define dir-result (oil-native-pair-same-type rem-dirs add-dirs))
  (define file-result (oil-native-pair-same-type rem-files add-files))
  (hash 'renames (append (list-ref dir-result 0) (list-ref file-result 0))
        'deletes (append (list-ref dir-result 1) (list-ref file-result 1))
        'creates (append (list-ref dir-result 2) (list-ref file-result 2))
        'copies (map (lambda (n) (cons (hash-get pending-copies n) n)) copy-names)))

(define (oil-native-diff-total diff)
  (+ (length (hash-get diff 'renames))
     (length (hash-get diff 'deletes))
     (length (hash-get diff 'creates))
     (length (hash-get diff 'copies))))

(define (oil-native-summarize diff)
  (define lines
    (append
     (map (lambda (p) (string-append "  rename " (car p) " -> " (cdr p))) (hash-get diff 'renames))
     (map (lambda (n) (string-append "  delete " n)) (hash-get diff 'deletes))
     (map (lambda (n) (string-append "  create " n)) (hash-get diff 'creates))
     (map (lambda (p) (string-append "  copy " (car p) " -> " (cdr p))) (hash-get diff 'copies))))
  (string-join lines "\n"))

;; (name . (start . end)) for every non-header, non-blank line in the
;; *current* buffer text - unlike oil-native-dir-highlight-ranges, which
;; works off a just-rendered entries list, this re-parses live so it stays
;; correct while the buffer is being edited.
(define (oil-native-line-ranges doc-id)
  (define lines (split-many (text.rope->string (editor->text doc-id)) "\n"))
  (let loop ([offset 0] [remaining lines] [line-idx 0] [ranges '()])
    (cond
      [(null? remaining) (reverse ranges)]
      [else
       (let* ([line (car remaining)]
              [end (+ offset (string-length line))]
              [trimmed (trim line)]
              [next (if (and (> line-idx 0) (> (string-length trimmed) 0))
                        (cons (cons trimmed (cons offset end)) ranges)
                        ranges)])
         (loop (+ end 1) (cdr remaining) (+ line-idx 1) next))])))

;; Re-highlights every line that currently represents an uncommitted change
;; (a rename's new name, a create, or a staged copy) with the theme's
;; "comment" scope - muted/gray in effectively every theme, which is the
;; point: a visual "this isn't real yet" marker distinct from the plain text
;; color, without needing to know anything about the active theme's palette.
;; Deletions have no line left to highlight; the gap is the signal for those.
;; Called from oil-native-on-change, so this stays live as you edit, not
;; just at save time.
(define (oil-native-highlight-pending! doc-id st)
  (define diff (oil-native-compute-diff (hash-get st 'entries)
                                         (oil-native-parse-buffer doc-id)
                                         (hash-get st 'pending-copies)))
  (define pending-names
    (append (map cdr (hash-get diff 'renames))
            (hash-get diff 'creates)
            (map cdr (hash-get diff 'copies))))
  (define pending-ranges
    (map cdr (filter (lambda (p) (member (car p) pending-names)) (oil-native-line-ranges doc-id))))
  (if (null? pending-ranges)
      (clear-document-highlights! OIL-NATIVE-PENDING-NS)
      (set-document-highlights! OIL-NATIVE-PENDING-NS pending-ranges "comment")))

;; ---------------------------------------------------------------------
;; Filesystem operations
;; ---------------------------------------------------------------------

(define (oil-native-run! program args)
  (define proc (~> (command program args) with-stdout-piped with-stderr-piped spawn-process))
  (if (Ok? proc)
      (let ([stderr (trim (read-port-to-string (child-stderr (Ok->value proc))))])
        (when (not (string=? stderr "")) (error stderr)))
      (error (string-append program ": could not spawn process"))))

;; Two-phase (via a temp name) so that e.g. swapping two entries' names in
;; the same batch can't clobber one with the other mid-rename.
(define (oil-native-apply-renames! dir renames)
  (define actual (filter (lambda (p) (not (string=? (car p) (cdr p)))) renames))
  (for-each (lambda (p)
              (oil-native-run! "mv"
                                (list (oil-native-full-path dir (car p))
                                      (string-append (oil-native-full-path dir (car p)) ".~oil-native~"))))
            actual)
  (for-each (lambda (p)
              (oil-native-run! "mv"
                                (list (string-append (oil-native-full-path dir (car p)) ".~oil-native~")
                                      (oil-native-full-path dir (cdr p)))))
            actual))

(define (oil-native-delete! dir name)
  (define path (oil-native-full-path dir name))
  (if (oil-native-dir-entry? name)
      (delete-directory! path) ; only removes empty directories
      (delete-file! path)))

(define (oil-native-create! dir name)
  (define path (oil-native-full-path dir name))
  (if (oil-native-dir-entry? name)
      (oil-native-run! "mkdir" (list "-p" path))
      (call-with-output-file path (lambda (_p) #t))))

;; -r copies directories recursively and works fine for a plain file too.
(define (oil-native-copy! source dir name)
  (oil-native-run! "cp" (list "-r" source (oil-native-full-path dir name))))

;; Applies a diff, collecting errors from each individual operation instead
;; of aborting on the first one, then reports success/failure and always
;; refreshes the buffer to reflect whatever the filesystem actually ended up
;; as (which, on partial failure, may not match every requested change).
(define (oil-native-apply! doc-id dir diff)
  (define errors '())
  (define (try! label thunk)
    (with-handler (lambda (err) (set! errors (cons (string-append label ": " (error-object-message err)) errors)))
                  (thunk)))
  (try! "rename" (lambda () (oil-native-apply-renames! dir (hash-get diff 'renames))))
  (for-each (lambda (n) (try! (string-append "delete " n) (lambda () (oil-native-delete! dir n))))
            (hash-get diff 'deletes))
  (for-each (lambda (n) (try! (string-append "create " n) (lambda () (oil-native-create! dir n))))
            (hash-get diff 'creates))
  (for-each (lambda (p) (try! (string-append "copy " (car p) " -> " (cdr p))
                               (lambda () (oil-native-copy! (car p) dir (cdr p)))))
            (hash-get diff 'copies))
  (oil-native-render! doc-id dir)
  (if (null? errors)
      (begin (buffer-mark-saved!)
             (set-status! (string-append "oil-native: applied " (number->string (oil-native-diff-total diff))
                                          " change(s)")))
      (set-error! (string-join (reverse errors) "; "))))

;; ---------------------------------------------------------------------
;; Buffer type
;; ---------------------------------------------------------------------

(define (oil-native-on-enter doc-id)
  (set-scratch-buffer-name! OIL-NATIVE-BUFFER-NAME))

(define (oil-native-on-write doc-id path)
  (define st (oil-native-get-state doc-id))
  (when st
    (let* ([dir (hash-get st 'dir)]
           [diff (oil-native-compute-diff (hash-get st 'entries)
                                           (oil-native-parse-buffer doc-id)
                                           (hash-get st 'pending-copies))])
      (if (= (oil-native-diff-total diff) 0)
          (begin (buffer-mark-saved!) (set-status! "oil-native: nothing to do"))
          (begin
            (set-status! (oil-native-summarize diff))
            (push-component!
             (prompt (string-append "oil-native: apply " (number->string (oil-native-diff-total diff))
                                     " change(s)? [y/N] ")
                     (lambda (answer)
                       (if (member answer (list "y" "Y" "yes" "Yes" "YES"))
                           (oil-native-apply! doc-id dir diff)
                           (set-status! "oil-native: cancelled, no changes applied")))))))))
  #true) ; always intercept the literal write - this buffer is never a real file

(define (oil-native-on-change doc-id old-text)
  (define st (oil-native-get-state doc-id))
  (when st (oil-native-highlight-pending! doc-id st)))

(define-buffer-type
 OIL-NATIVE-TYPE
 ;; No y/p bindings here on purpose - copy rides on native yank/paste via
 ;; the post-command hook further down, not a buffer-local override.
 (hash 'keymap (keymap (normal (ret ":oil-native-enter")
                                (- ":oil-native-up")
                                (q ":oil-native-close")
                                (R ":oil-native-refresh")))
       'on-enter oil-native-on-enter
       'on-write oil-native-on-write
       'on-change oil-native-on-change))

;; ---------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------

;;@doc
;; Open the file manager for the current file's directory (or the Helix cwd
;; for an unnamed buffer). Always opens a fresh buffer - navigate with
;; oil-native-enter/oil-native-up from there to browse without piling up
;; buffers.
(define (oil-native)
  (define doc-id (editor->doc-id (editor-focus)))
  (define path (editor-document->path doc-id))
  (define dir (if path (parent-name path) (get-helix-cwd)))
  (define new-id (create-buffer! OIL-NATIVE-TYPE))
  (oil-native-render! new-id dir))

(define (oil-native-current-doc-id)
  (editor->doc-id (editor-focus)))

;;@doc
;; Enter the directory under the cursor, or open the file under the cursor.
(define (oil-native-enter)
  (define doc-id (oil-native-current-doc-id))
  (define st (oil-native-get-state doc-id))
  (when st
    (let* ([dir (hash-get st 'dir)]
           [line-n (get-current-line-number)]
           [lines (split-many (text.rope->string (editor->text doc-id)) "\n")]
           [entry (and (< line-n (length lines)) (trim (list-ref lines line-n)))])
      (cond
        [(or (not entry) (string=? entry "")) #f]
        [(string=? entry "../") (oil-native-render! doc-id (parent-name dir))]
        [(oil-native-dir-entry? entry)
         (oil-native-render! doc-id (oil-native-full-path dir entry))]
        [else (helix.open (oil-native-full-path dir entry))]))))

;;@doc
;; Go to the parent directory.
(define (oil-native-up)
  (define doc-id (oil-native-current-doc-id))
  (define st (oil-native-get-state doc-id))
  (when st (oil-native-render! doc-id (parent-name (hash-get st 'dir)))))

;;@doc
;; Reload the current directory from disk, discarding any unsaved edits.
(define (oil-native-refresh)
  (define doc-id (oil-native-current-doc-id))
  (define st (oil-native-get-state doc-id))
  (when st (oil-native-render! doc-id (hash-get st 'dir))))

;;@doc
;; Close the file manager buffer.
(define (oil-native-close)
  (helix.buffer-close))

;; ---------------------------------------------------------------------
;; Copy, via native yank/paste
;; ---------------------------------------------------------------------
;; No oil-native command or keybinding for either half of this - native y
;; yanks a selection to a register as always, native p pastes it as always.
;; A post-command hook (registered below) just watches for those two
;; commands firing while an oil-native buffer is focused and, if what was
;; yanked/pasted matches a real entry, stages a copy op the same way any
;; other edit gets staged: nothing happens until `:w` confirms it.
;;
;; This means: select the *whole line* before yanking (e.g. `x` then `y`) -
;; a partial-line yank won't match any entry and is just left as a normal
;; text yank. And paste-then-rename-before-saving degrades to a plain
;; create, same caveat as with rename pairing above.

(define (oil-native-observe-yank! doc-id)
  (define st (oil-native-get-state doc-id))
  (define dir (hash-get st 'dir))
  (define reg-values (register->value (selected-register!)))
  (define yanked (and (pair? reg-values) (trim (car reg-values))))
  (define known-entries (cons "../" (hash-get st 'entries)))
  (when (and yanked (> (string-length yanked) 0) (member yanked known-entries)
             (not (string=? yanked "../")))
    (set! *oil-native-clipboard*
          (list (oil-native-full-path dir yanked) (oil-native-dir-entry? yanked) yanked))))

(define (oil-native-observe-paste! doc-id)
  (define reg-values (register->value (selected-register!)))
  (define pasted-text (and (pair? reg-values) (trim (car reg-values))))
  (when (and *oil-native-clipboard* pasted-text
             (string=? pasted-text (list-ref *oil-native-clipboard* 2)))
    (let* ([line-n (get-current-line-number)]
           [lines (split-many (text.rope->string (editor->text doc-id)) "\n")]
           [on-line (and (< line-n (length lines)) (trim (list-ref lines line-n)))])
      (when (and on-line (string=? on-line pasted-text))
        (let* ([source (list-ref *oil-native-clipboard* 0)]
               [current-names (oil-native-parse-buffer doc-id)]
               [background (oil-native-remove-one pasted-text current-names)])
          (if (member pasted-text background)
              (set-error! (string-append "oil-native: \"" pasted-text
                                          "\" already exists here - rename one of them, then paste again"))
              (begin
                (oil-native-record-copy! doc-id pasted-text source)
                (set-status! (string-append "oil-native: staged copy of " (oil-native-basename source)
                                             " as " pasted-text " (pending - :w to apply)")))))))))

(register-hook 'post-command
               (lambda (command-name)
                 (define doc-id (editor->doc-id (editor-focus)))
                 (define st (oil-native-get-state doc-id))
                 (when st
                   (when (string=? command-name "yank") (oil-native-observe-yank! doc-id))
                   (when (or (string=? command-name "paste_after") (string=? command-name "paste_before"))
                     (oil-native-observe-paste! doc-id)))))
