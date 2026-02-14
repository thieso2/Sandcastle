import { Controller } from "@hotwired/stimulus"

// Inline confirmation controller - replaces buttons with "Are you sure? y/n"
export default class extends Controller {
  connect() {
    this.confirmed = false
  }

  confirm(event) {
    // If already confirmed, let the form submit naturally
    if (this.confirmed) {
      return
    }

    event.preventDefault()

    // Find the form - event.target is the button inside the form
    const form = event.target.closest("form")
    if (!form) {
      return
    }

    // Get message from the form's data attribute
    const message = form.dataset.confirmMessage || event.target.dataset.confirmMessage || "Are you sure?"

    // Store original HTML of the controller element (the wrapper div)
    const originalHTML = this.element.innerHTML

    // Replace with inline confirmation
    this.element.innerHTML = `
      <div class="flex items-center gap-2">
        <span class="text-xs text-gray-700">${message}</span>
        <button type="button"
                data-action="click->inline-confirm#yes"
                class="text-xs px-2 py-1 bg-red-600 text-white rounded hover:bg-red-700 transition-colors">
          Yes
        </button>
        <button type="button"
                data-action="click->inline-confirm#no"
                class="text-xs px-2 py-1 bg-gray-300 text-gray-700 rounded hover:bg-gray-400 transition-colors">
          No
        </button>
      </div>
    `

    // Store original HTML for restoration
    this.element.dataset.originalHtml = originalHTML
  }

  yes(event) {
    event.preventDefault()

    const originalHTML = this.element.dataset.originalHtml

    if (originalHTML) {
      // Restore the original HTML to get the submit button back
      this.element.innerHTML = originalHTML

      // Find the form in the restored HTML
      const form = this.element.querySelector('form')

      if (form) {
        // Find and click the submit button
        const submitButton = form.querySelector('button[type="submit"]')

        if (submitButton) {
          // Set flag to prevent re-triggering confirm handler
          this.confirmed = true
          // Small delay to ensure DOM is ready
          setTimeout(() => {
            submitButton.click()
          }, 10)
        }
      }
    }
  }

  no(event) {
    event.preventDefault()

    const originalHTML = this.element.dataset.originalHtml

    // Restore original buttons
    if (originalHTML) {
      this.element.innerHTML = originalHTML
      delete this.element.dataset.originalHtml
      // Reset confirmation flag
      this.confirmed = false
    }
  }
}
