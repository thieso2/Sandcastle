import { Controller } from "@hotwired/stimulus"

// Switch visible panel based on the URL hash (#profile, #tokens, etc.).
// Every form inside the controlled element gets a hidden <input name="tab">
// whose value tracks the active tab, so the server can redirect back with
// the correct fragment.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { default: String }

  connect() {
    this.ensureTabInputs()
    this.activate(this.currentTabId(), { updateHash: false })
    this.hashChanged = () => this.activate(this.currentTabId(), { updateHash: false })
    window.addEventListener("hashchange", this.hashChanged)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.hashChanged)
  }

  select(event) {
    event.preventDefault()
    const id = event.currentTarget.dataset.tabId
    this.activate(id, { updateHash: true })
  }

  // Preference order: URL hash (explicit), sessionStorage (last active in this
  // tab), Stimulus default, first panel. sessionStorage is the fallback for
  // Turbo Drive, which strips the redirect Location's fragment on form posts.
  currentTabId() {
    const valid = id => id && this.panelTargets.some(p => p.dataset.tabId === id)
    const hash = window.location.hash.replace(/^#/, "")
    if (valid(hash)) return hash
    const stored = sessionStorage.getItem(this.storageKey)
    if (valid(stored)) return stored
    return this.defaultValue || this.panelTargets[0]?.dataset.tabId
  }

  get storageKey() { return "settings-active-tab" }

  activate(id, { updateHash }) {
    if (!id) return
    this.panelTargets.forEach(panel => {
      panel.hidden = panel.dataset.tabId !== id
    })
    this.tabTargets.forEach(tab => {
      const active = tab.dataset.tabId === id
      tab.classList.toggle("border-blue-600", active)
      tab.classList.toggle("text-blue-600", active)
      tab.classList.toggle("border-transparent", !active)
      tab.classList.toggle("text-gray-500", !active)
      tab.setAttribute("aria-selected", active ? "true" : "false")
    })
    if (updateHash) {
      // replaceState so we don't pile up history entries for every tab click.
      history.replaceState(null, "", `#${id}`)
    }
    sessionStorage.setItem(this.storageKey, id)
    this.syncTabInputs(id)
  }

  // Inject a hidden <input name="tab"> into every form once so it's serialized
  // with the request. We update the value on each tab switch.
  ensureTabInputs() {
    this.element.querySelectorAll("form").forEach(form => {
      if (form.querySelector('input[name="tab"][data-tab-injected]')) return
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "tab"
      input.dataset.tabInjected = "true"
      form.appendChild(input)
    })
  }

  syncTabInputs(id) {
    this.element.querySelectorAll('input[name="tab"][data-tab-injected]').forEach(input => {
      input.value = id
    })
  }
}
