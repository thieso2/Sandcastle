import { Controller } from "@hotwired/stimulus"

// Handles "Check for Updates" and "Update Now" buttons on the admin dashboard.
// After triggering an update it polls /api/info until the version string changes,
// then reloads the page so the new version is visible.
export default class extends Controller {
  static targets = ["checkBtn", "updateBtn", "progressMsg"]
  static values  = { checkUrl: String, performUrl: String, pollUrl: String }

  async checkForUpdates() {
    this.checkBtnTarget.disabled    = true
    this.checkBtnTarget.textContent = "Checking…"

    try {
      const resp = await fetch(this.checkUrlValue, {
        method:  "GET",
        headers: { "Accept": "application/json", "X-CSRF-Token": this.#csrfToken() }
      })
      if (resp.ok) {
        // Reload the turbo frame to show fresh data
        const frame = this.element.closest("turbo-frame")
        if (frame) frame.reload()
      }
    } finally {
      this.checkBtnTarget.disabled    = false
      this.checkBtnTarget.textContent = "Check for Updates"
    }
  }

  async performUpdate() {
    if (!confirm("This will pull the latest images and restart the app. Continue?")) return

    this.updateBtnTarget.disabled    = true
    this.updateBtnTarget.textContent = "Updating…"
    this.progressMsgTarget.classList.remove("hidden")

    try {
      const resp = await fetch(this.performUrlValue, {
        method:  "POST",
        headers: { "Accept": "application/json", "X-CSRF-Token": this.#csrfToken() }
      })

      if (resp.ok) {
        // Poll /api/info until the server comes back (with a new or same version)
        await this.#pollUntilReady()
        window.location.reload()
      } else {
        const body = await resp.json().catch(() => ({}))
        alert("Update failed: " + (body.error || resp.statusText))
        this.progressMsgTarget.classList.add("hidden")
        this.updateBtnTarget.disabled    = false
        this.updateBtnTarget.textContent = "Update Now"
      }
    } catch (e) {
      alert("Update request failed: " + e.message)
      this.progressMsgTarget.classList.add("hidden")
      this.updateBtnTarget.disabled    = false
      this.updateBtnTarget.textContent = "Update Now"
    }
  }

  // Polls the API info endpoint every 3 seconds until it responds successfully,
  // indicating the new container is up.
  async #pollUntilReady(maxAttempts = 60, intervalMs = 3000) {
    for (let i = 0; i < maxAttempts; i++) {
      await new Promise(r => setTimeout(r, intervalMs))
      try {
        const resp = await fetch(this.pollUrlValue, { headers: { "Accept": "application/json" } })
        if (resp.ok) return
      } catch (_) {
        // Server restarting — keep polling
      }
    }
  }

  #csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
