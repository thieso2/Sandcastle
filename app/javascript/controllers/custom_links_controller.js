import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template"]

  add(event) {
    event.preventDefault()
    const index = this.listTarget.children.length
    const html = this.templateTarget.innerHTML.replace(/INDEX/g, index)
    this.listTarget.insertAdjacentHTML("beforeend", html)
  }

  remove(event) {
    event.preventDefault()
    event.target.closest("[data-custom-links-row]").remove()
  }
}
