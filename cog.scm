(define package-name 'mattwparas-helix-package)
(define version "0.1.0")

(define dependencies
  '((#:name steel-pty #:git-url "https://github.com/mattwparas/steel-pty.git")
    (#:name helix-file-watcher #:git-url "https://github.com/mattwparas/helix-file-watcher.git")
    (#:name lazygit.hx #:git-url "https://github.com/RoastBeefer00/lazygit.hx.git")
    (#:name sidekick.hx #:git-url "https://github.com/RoastBeefer00/sidekick.hx.git")
    (#:name vim.hx #:git-url "https://github.com/RoastBeefer00/vim.hx.git")
    (#:name surround.hx #:git-url "https://github.com/RoastBeefer00/surround.hx.git")
    (#:name fidget.hx #:git-url "https://github.com/RoastBeefer00/fidget.hx.git")
    ))

(define dylibs '())
