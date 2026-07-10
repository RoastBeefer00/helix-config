(require-builtin steel/random as rand::)

(require "cogs/keymaps.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/configuration.scm")
(require "helix/editor.scm")
(require "splash.scm")
(require "focus.scm")
(require "notify/notify.scm")
(require "oil/oil.scm")

(require "lazygit.hx/lazygit.scm")
(require "sidekick.hx/sidekick.scm")
(require "surround.hx/surround.scm")
(set-surround-keybindings!)
(require "crates.hx/crates.scm")
(enable-crates-auto!)
(require "html.hx/html.scm")
(enable-html-auto-close!)
(require "showkeys/showkeys.scm")
(set-sidekick-backend! 'pty)

;; Override: C-l focuses the sidekick panel when at the right edge instead of
;; falling through to tmux (which can't navigate into a component overlay).
(define (smart-window-right!)
  (define v (editor-focus))
  (helix.static.jump_view_right)
  (when (equal? v (editor-focus))
    (sidekick-focus!)))
(require "vim.hx/init.scm")
(set-vim-keybindings!)
(require "fidget.hx/fidget.scm")

;;;;;;;;;;;;;;;;;;;;;;;; Motion helpers ;;;;;;;;;;;;;;;;;;;;;;

;; C-d / C-u + keep cursor centered (nixvim: <C-d>zz / <C-u>zz)
(define (page-down-center)
  (helix.static.page_cursor_half_down)
  (helix.static.align_view_center))

(define (page-up-center)
  (helix.static.page_cursor_half_up)
  (helix.static.align_view_center))

;; n / N + keep cursor centered (nixvim: nzzzv / Nzzzv)
(define (search-next-center)
  (helix.static.search_next)
  (helix.static.align_view_center))

(define (search-prev-center)
  (helix.static.search_prev)
  (helix.static.align_view_center))

;; Add a blank line below/above without entering insert mode
;; (nixvim: o<Esc>k / O<Esc>k)
(define (open-line-below!)
  (helix.static.open_below)
  (helix.static.normal_mode)
  (helix.static.move_visual_line_up))

(define (open-line-above!)
  (helix.static.open_above)
  (helix.static.normal_mode)
  (helix.static.move_visual_line_down))

;; Vertical / horizontal split then focus the new pane
;; (nixvim: <cmd>vsplit<CR><C-w><right> / <cmd>split<CR><C-w><down>)
(define (vsplit-and-move)
  (helix.vsplit)
  (helix.static.jump_view_right))

(define (hsplit-and-move)
  (helix.hsplit)
  (helix.static.jump_view_down))

;; Launch tmux-sessionizer in a new tmux window (nixvim: <C-f>)
(define (tmux-sessionizer!)
  (helix.run-shell-command "tmux" "neww" "~/.local/scripts/tmux-sessionizer"))

;;;;;;;;;;;;;;;;;;;;;;;;;; Keybindings ;;;;;;;;;;;;;;;;;;;;;;;

(keymap (global)
        (normal
          ;; Window navigation (smart-splits / nixvim: <C-hjkl>)
          (C-h ":smart-window-left!")
          (C-j ":smart-window-down!")
          (C-k ":smart-window-up!")
          (C-l ":smart-window-right!")
          ;; Scroll + center (nixvim: <C-d>zz / <C-u>zz)
          (C-d ":page-down-center")
          (C-u ":page-up-center")
          ;; Tmux sessionizer (nixvim: <C-f>)
          (C-f ":tmux-sessionizer!")
          ;; Search + center (nixvim: nzzzv / Nzzzv)
          (n ":search-next-center")
          (N ":search-prev-center")
          ;; Recent files
          (C-r (f ":recentf-open-files"))
          ;; Git hunk navigation (nixvim: ]c/[c — helix native uses ]g/[g)
          ;; (] (c "goto_next_change"))
          ;; ([ (c "goto_prev_change"))
          (space
            ;; Helix-specific
            (l ":load-buffer")
            ;; Open blank line without entering insert (nixvim: <leader>o/<leader>O)
            (o ":open-line-below!")
            (O ":open-line-above!")
            ;; Sidekick / Claude
            ;; (s ":sidekick")
            ;; (S ":sidekick-send-selection!")
            ;; (B ":sidekick-send-buffer!")
            ;; (p ":sidekick-prompt-picker!")
            ;; Sidekick a-prefix (nixvim: <leader>aa, <leader>at, <leader>af, <leader>ap)
            (a (c ":sidekick")
               (t ":sidekick-send-selection!")
               (f ":sidekick-send-buffer!")
               (v ":sidekick-send-selection!")
               (p ":sidekick-prompt-picker!"))
            ;; Oil file manager (nixvim: -)
            (e ":oil")
            ;; LazyGit (nixvim: <leader>gg) + merge-conflict resolver (space g c ...)
            (g (g ":lazygit")
               (c (n ":conflict-next")
                  (p ":conflict-prev")
                  (o ":conflict-accept-ours")
                  (t ":conflict-accept-theirs")
                  (b ":conflict-accept-both")
                  (d ":conflict-accept-none")
                  (h ":conflict-highlight")
                  (x ":conflict-clear")
                  (l ":conflict-list")
                  (f ":conflict-files")
                  (s ":conflict-diff")
                  (q ":conflict-diff-close")))
            ;; File / search pickers (nixvim: <leader>ff/fg/fw/fd/fo/fc/<leader><leader>)
            (f (f "file_picker")
               (g "global_search")
               (o ":recentf-open-files")
               (w "search_selection")
               (d "workspace_diagnostics_picker")
               (c "changed_file_picker"))
            ;; Buffer picker (nixvim: <leader><leader>)
            (space "buffer_picker")
            ;; Window splits + nav (nixvim: <leader>wv/<leader>ws/<leader>whjkl)
            (w (v ":vsplit-and-move")
               (s ":hsplit-and-move")
               (h ":smart-window-left!")
               (j ":smart-window-down!")
               (k ":smart-window-up!")
               (l ":smart-window-right!"))
            ;; Diagnostics (nixvim: <leader>xx/<leader>xd/<leader>xs)
            (x (x "diagnostics_picker")
               (d "diagnostics_picker")
               (s "workspace_diagnostics_picker"))))
        ;; Move selected lines up/down (nixvim: visual J/K → :m '>+1 / :m '<-2)
        (select
          (J "move_line_down")
          (K "move_line_up")
          ;; Window navigation also from select/visual-line mode (nixvim: <C-hjkl>).
          ;; smart-window-right! normalizes mode before focusing the sidekick, so
          ;; C-l works even from visual line mode.
          (C-h ":smart-window-left!")
          (C-j ":smart-window-down!")
          (C-k ":smart-window-up!")
          (C-l ":smart-window-right!")
          (space
            (a (v ":sidekick-send-selection!")
               (p ":sidekick-prompt-picker!"))
            (S ":sidekick-send-selection!")
            (B ":sidekick-send-buffer!")
            (p ":sidekick-prompt-picker!")))
        ;; jk to exit insert mode (nixvim: jk → <Esc>)
        (insert
          (j (k ":vim-exit-insert-mode"))))

(define scm-keybindings (hash "insert" (hash "ret" ':scheme-indent "C-l" ':insert-lambda)))

;; Grab whatever the existing keybinding map is
(define standard-keybindings (deep-copy-global-keybindings))

(define file-tree-base (deep-copy-global-keybindings))

(merge-keybindings standard-keybindings scm-keybindings)
;; (merge-keybindings file-tree-base FILE-TREE-KEYBINDINGS)

;;;;;;;;;;;;;;;;;;;;;;;;;; Options ;;;;;;;;;;;;;;;;;;;;;;;;;;;

(file-picker (fp-hidden #f))
(cursorline #t)
(soft-wrap (sw-enable #t))

;; New LSP definitions
(define-lsp "steel-language-server" (command "steel-language-server") (args '()))
(define-lsp "rust-analyzer" (config (experimental (hash 'testExplorer #t))))

;; New language definition
(define-language "scheme"
                 (formatter (command "raco") (args '("fmt" "-i")))
                 (auto-format #true)
                 (language-servers '("steel-language-server")))

(when (equal? (command-line) '("hx"))
  (show-splash))
