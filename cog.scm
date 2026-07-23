(define package-name 'mattwparas-helix-package)
(define version "0.1.0")

(define dependencies
  '((#:name steel-pty #:git-url "https://github.com/mattwparas/steel-pty.git")
    (#:name helix-file-watcher #:git-url "https://github.com/mattwparas/helix-file-watcher.git")
    (#:name lazygit.hx #:git-url "https://github.com/RoastBeefer00/lazygit.hx.git")
    (#:name sidekick.hx #:git-url "https://github.com/RoastBeefer00/sidekick.hx.git")
    (#:name vim.hx #:git-url "https://github.com/RoastBeefer00/vim.hx.git")
    (#:name surround.hx #:git-url "https://github.com/RoastBeefer00/surround.hx.git")
    (#:name html.hx #:git-url "https://github.com/RoastBeefer00/html.hx.git")
    (#:name crates.hx #:git-url "https://github.com/RoastBeefer00/crates.hx.git")
    (#:name git-conflict.hx #:git-url "https://github.com/RoastBeefer00/git-conflict.hx.git")
    (#:name showkeys #:git-url "https://github.com/HeitorAugustoLN/showkeys.hx.git")
    (#:name fidget.hx #:git-url "https://github.com/RoastBeefer00/fidget.hx.git")
    (#:name notify #:git-url "https://github.com/chuwy/notify.hx.git")
    ))

(define dylibs '())
