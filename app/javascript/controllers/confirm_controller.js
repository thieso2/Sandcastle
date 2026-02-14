import { Controller } from "@hotwired/stimulus"

// Global confirm modal controller - attached to the modal in the layout
export default class extends Controller {
  static targets = ["modal", "message"]

  connect() {
    // Listen for clicks on elements with data-confirm-message
    document.addEventListener("click", this.handleConfirmClick.bind(this), true)
  }

  disconnect() {
    document.removeEventListener("click", this.handleConfirmClick.bind(this), true)
  }

  handleConfirmClick(event) {
    const element = event.target.closest("[data-confirm-message]")

    if (!element) return

    // Prevent the default action
    event.preventDefault()
    event.stopPropagation()

    // Store the triggering element
    this.triggeringElement = element
    this.originalEvent = event

    // Get confirmation message from data attribute
    const message = element.dataset.confirmMessage

    if (message) {
      this.messageTarget.textContent = message
    }

    // Show the modal
    this.modalTarget.classList.remove("hidden")
    this.modalTarget.classList.add("flex")
  }

  confirm(event) {
    event.preventDefault()

    // Hide the modal first
    this.hide()

    // Trigger the original action
    if (this.triggeringElement) {
      // For button_to forms (which create a form with a button)
      if (this.triggeringElement.tagName === "BUTTON" && this.triggeringElement.form) {
        const form = this.triggeringElement.form
        const button = this.triggeringElement

        // Remove the confirm message to prevent re-triggering
        const confirmMessage = button.dataset.confirmMessage
        delete button.dataset.confirmMessage

        // Submit the form (Turbo will intercept it)
        form.requestSubmit(button)

        // Restore the confirm message for future use
        setTimeout(() => {
          if (confirmMessage) {
            button.dataset.confirmMessage = confirmMessage
          }
        }, 100)
      }
      // For regular links with data-turbo-method
      else if (this.triggeringElement.hasAttribute("data-turbo-method")) {
        const confirmMessage = this.triggeringElement.dataset.confirmMessage
        delete this.triggeringElement.dataset.confirmMessage

        // Click the link (Turbo will handle it)
        this.triggeringElement.click()

        // Restore the confirm message
        setTimeout(() => {
          if (confirmMessage) {
            this.triggeringElement.dataset.confirmMessage = confirmMessage
          }
        }, 100)
      }
      // For regular links
      else {
        this.triggeringElement.click()
      }
    }
  }

  cancel(event) {
    event.preventDefault()
    this.hide()
  }

  hide() {
    // Hide the modal
    this.modalTarget.classList.add("hidden")
    this.modalTarget.classList.remove("flex")

    // Clear the triggering element
    this.triggeringElement = null
    this.originalEvent = null
  }

  // Close modal when clicking backdrop
  closeBackdrop(event) {
    if (event.target === this.modalTarget) {
      this.cancel(event)
    }
  }
}
