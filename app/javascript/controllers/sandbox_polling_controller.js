import { Controller } from "@hotwired/stimulus"

// Polls the server for the latest sandbox card HTML when a job is in progress.
// Provides a fallback for cases where the Turbo Stream broadcast is missed
// (e.g. WebSocket not yet connected when the job completes).
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.timer = setInterval(() => this.refresh(), 3000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  refresh() {
    fetch(this.urlValue, {
      headers: {
        "Accept": "text/vnd.turbo-stream.html",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
      }
    })
      .then(r => r.text())
      .then(html => Turbo.renderStreamMessage(html))
      .catch(() => {})
  }
}
