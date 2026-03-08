import { Controller } from "@hotwired/stimulus"

// Manages the update flow on the admin dashboard:
//   1. Check for updates (refresh turbo frame)
//   2. Start pull (POST /pull, then poll /status for progress)
//   3. When pull is ready: sandbox-only → refresh frame; app → show "Restart Now" button
//   4. Restart → spawn updater container → fullscreen progress page
export default class extends Controller {
  static targets = ["checkBtn", "pullProgress", "pullSpinner", "pullStatus", "restartBtn"]
  static values  = {
    checkUrl:    String,
    pullUrl:     String,
    statusUrl:   String,
    restartUrl:  String,
    progressUrl: String
  }

  async checkForUpdates() {
    this.checkBtnTarget.disabled    = true
    this.checkBtnTarget.textContent = "Checking…"

    try {
      const resp = await fetch(this.checkUrlValue, {
        method:  "GET",
        headers: { "Accept": "application/json", "X-CSRF-Token": this.#csrfToken() }
      })
      if (resp.ok) {
        const frame = this.element.closest("turbo-frame")
        if (frame) frame.reload()
      }
    } finally {
      this.checkBtnTarget.disabled    = false
      this.checkBtnTarget.textContent = "Check for Updates"
    }
  }

  async startPull(event) {
    const target = event.currentTarget.dataset.updateTarget || "all"
    const labels = { all: "all images", app: "the app image", sandbox: "the sandbox image" }

    if (!confirm(`Pull ${labels[target] || target}?`)) return

    // Disable all update buttons
    this.element.querySelectorAll("[data-action*='startPull']").forEach(btn => {
      btn.disabled = true
      btn.classList.add("opacity-50")
    })

    // Show pull progress
    this.pullProgressTarget.classList.remove("hidden")
    this.pullStatusTarget.textContent = "Starting pull…"
    if (this.hasPullSpinnerTarget) this.pullSpinnerTarget.classList.remove("hidden")
    if (this.hasRestartBtnTarget) this.restartBtnTarget.classList.add("hidden")

    try {
      const resp = await fetch(`${this.pullUrlValue}?target=${target}`, {
        method:  "POST",
        headers: { "Accept": "application/json", "X-CSRF-Token": this.#csrfToken() }
      })

      if (!resp.ok) {
        const body = await resp.json().catch(() => ({}))
        throw new Error(body.error || resp.statusText)
      }

      // Poll for pull completion
      await this.#pollPullStatus(target)
    } catch (e) {
      alert("Update failed: " + e.message)
      this.pullProgressTarget.classList.add("hidden")
      this.element.querySelectorAll("[data-action*='startPull']").forEach(btn => {
        btn.disabled = false
        btn.classList.remove("opacity-50")
      })
    }
  }

  async restartNow() {
    if (this.hasRestartBtnTarget) {
      this.restartBtnTarget.disabled = true
      this.restartBtnTarget.textContent = "Restarting…"
    }
    this.pullStatusTarget.textContent = "Restarting app…"
    if (this.hasPullSpinnerTarget) this.pullSpinnerTarget.classList.remove("hidden")

    try {
      await this.#triggerRestart()
    } catch (e) {
      alert("Restart failed: " + e.message)
      if (this.hasRestartBtnTarget) {
        this.restartBtnTarget.disabled = false
        this.restartBtnTarget.textContent = "Restart Now"
      }
    }
  }

  async #pollPullStatus(target) {
    const needsRestart = target !== "sandbox"

    for (let i = 0; i < 120; i++) {  // up to 6 minutes
      await new Promise(r => setTimeout(r, 2000))

      try {
        const resp = await fetch(this.statusUrlValue, {
          headers: { "Accept": "application/json" },
          cache: "no-store"
        })
        if (!resp.ok) continue

        const data = await resp.json()
        this.pullStatusTarget.textContent = data.step || data.state || "Pulling…"

        if (data.state === "ready") {
          if (needsRestart) {
            // Show "Restart Now" button, hide spinner
            this.pullStatusTarget.textContent = "Images pulled."
            if (this.hasPullSpinnerTarget) this.pullSpinnerTarget.classList.add("hidden")
            if (this.hasRestartBtnTarget) this.restartBtnTarget.classList.remove("hidden")
          } else {
            // Sandbox-only — just refresh the frame
            this.pullStatusTarget.textContent = "Sandbox image updated!"
            await new Promise(r => setTimeout(r, 1000))
            const frame = this.element.closest("turbo-frame")
            if (frame) frame.reload()
          }
          return
        }

        if (data.state === "error") {
          throw new Error(data.step || "Pull failed")
        }
      } catch (e) {
        if (e.message && !e.message.includes("fetch")) throw e
      }
    }

    throw new Error("Pull timed out")
  }

  async #triggerRestart() {
    const resp = await fetch(this.restartUrlValue, {
      method:  "POST",
      headers: { "Accept": "application/json", "X-CSRF-Token": this.#csrfToken() }
    })

    if (!resp.ok) {
      const body = await resp.json().catch(() => ({}))
      throw new Error(body.error || "Restart failed")
    }

    // Navigate to the fullscreen progress page
    window.location.href = this.progressUrlValue
  }

  #csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}
