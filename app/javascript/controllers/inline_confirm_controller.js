import { Controller } from "@hotwired/stimulus"

// Inline confirmation controller - replaces buttons with "Are you sure? y/n"
export default class extends Controller {
  static targets = ["buttons", "form"]

  confirm(event) {
    event.preventDefault()
    const button = event.currentTarget
    const form = button.closest("form")
    const message = button.dataset.confirmMessage || "Are you sure?"

    // Store original button HTML
    const container = button.parentElement
    const originalHTML = container.innerHTML

    // Replace with inline confirmation
    container.innerHTML = `
      <div class="flex items-center gap-2">
        <span class="text-xs text-gray-700">${message}</span>
        <button type="button"
                data-action="click->inline-confirm#yes"
                data-inline-confirm-form-param="${form ? 'true' : 'false'}"
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

    // Store original HTML and form for restoration
    container.dataset.originalHtml = originalHTML
    container.dataset.formId = form ? form.id || Math.random().toString(36) : null
    if (form && !form.id) {
      form.id = container.dataset.formId
    }
  }

  yes(event) {
    event.preventDefault()
    const container = event.currentTarget.closest('[data-original-html]')
    const formId = container.dataset.formId
    const form = formId ? document.getElementById(formId) : null

    if (form) {
      // Submit the form
      form.requestSubmit()
    }
  }

  no(event) {
    event.preventDefault()
    const container = event.currentTarget.closest('[data-original-html]')
    const originalHTML = container.dataset.originalHtml

    // Restore original buttons
    if (originalHTML) {
      container.innerHTML = originalHTML
      delete container.dataset.originalHtml
      delete container.dataset.formId
    }
  }
}
