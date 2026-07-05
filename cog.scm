(define package-name 'mattwparas-helix-package)
(define version "0.1.0")

;; Point to all of the packages that exist
(define dependencies
  '((#:name steel-pty #:git-url "https://github.com/mattwparas/steel-pty.git")
    (#:name helix-file-watcher #:git-url "https://github.com/mattwparas/helix-file-watcher.git")
    (#:name lazygit.hx #:git-url "https://github.com/RoastBeefer00/lazygit.hx.git")
    (#:name sidekick.hx #:git-url "https://github.com/RoastBeefer00/sidekick.hx.git")
    ;; vim.hx — uncomment once PR is merged upstream or install from fork:
    ;; (#:name vim.hx #:git-url "https://github.com/RoastBeefer00/vim.hx.git")
    (#:name fidget.hx #:git-url "https://github.com/RoastBeefer00/fidget.hx.git")
    ))

(define dylibs '())
