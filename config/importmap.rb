# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
# Terminal emulators are lazy — only loaded on terminal pages, and only the
# one matching the user's selected emulator. Skip modulepreload so every
# other page isn't paying for a ~1MB download it never uses.
pin "ghostty-web", to: "ghostty-web.js", preload: false # @0.4.0 (WASM embedded inline)
pin "@wterm/dom", to: "https://cdn.jsdelivr.net/npm/@wterm/dom@0.1.9/+esm", preload: false
pin "@xterm/addon-fit", to: "@xterm--addon-fit.js", preload: false # @0.11.0
pin "@xterm/addon-web-links", to: "@xterm--addon-web-links.js", preload: false # @0.12.0
pin "@xterm/xterm", to: "@xterm--xterm.js", preload: false # @6.0.0
