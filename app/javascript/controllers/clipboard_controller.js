import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    const text = this.sourceTarget.value || this.sourceTarget.textContent
    if (!text) return

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(() => this.showCopied()).catch(() => this.fallbackCopy(text))
    } else {
      this.fallbackCopy(text)
    }
  }

  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.style.position = "fixed"
    textarea.style.left = "-9999px"
    document.body.appendChild(textarea)
    textarea.focus()
    textarea.select()

    try {
      if (document.execCommand("copy")) this.showCopied()
    } finally {
      document.body.removeChild(textarea)
    }
  }

  showCopied() {
    if (!this.hasButtonTarget) return

    const original = this.buttonTarget.textContent
    this.buttonTarget.textContent = "Copied"
    clearTimeout(this.resetTimeout)
    this.resetTimeout = setTimeout(() => {
      this.buttonTarget.textContent = original
    }, 1500)
  }
}
