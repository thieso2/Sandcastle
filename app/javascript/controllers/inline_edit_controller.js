import { Controller } from "@hotwired/stimulus"

// Toggle between a display element and an inline edit form
export default class extends Controller {
  static targets = ["display", "form"]

  edit() {
    this.displayTarget.classList.add("hidden")
    this.formTarget.classList.remove("hidden")
    this.formTarget.classList.add("flex")
    const input = this.formTarget.querySelector("input[type=text]")
    if (input) {
      input.focus()
      input.select()
    }
  }

  cancel() {
    this.formTarget.classList.add("hidden")
    this.formTarget.classList.remove("flex")
    this.displayTarget.classList.remove("hidden")
  }
}
