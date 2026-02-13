import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    dismissAfter: { type: Number, default: 5000 }, // 5 seconds
    level: String
  }

  connect() {
    // Auto-dismiss notice-level messages after timeout
    if (this.levelValue === "notice") {
      this.timeout = setTimeout(() => {
        this.close()
      }, this.dismissAfterValue)
    }
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
  }

  close() {
    this.element.remove()
  }
}
