import { Controller } from "@hotwired/stimulus"

// Inline confirmation controller - replaces buttons with "Are you sure? y/n"
export default class extends Controller {
  confirm(event) {
    event.preventDefault()
    console.log('[InlineConfirm] Confirm clicked', event.target)

    // Find the form - event.target is the button inside the form
    const form = event.target.closest("form")
    if (!form) {
      console.error('[InlineConfirm] No form found')
      return
    }

    // Get message from the form's data attribute
    const message = form.dataset.confirmMessage || event.target.dataset.confirmMessage || "Are you sure?"

    console.log('[InlineConfirm] Message:', message, 'Form:', form.action)

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
    console.log('[InlineConfirm] Yes clicked')

    const originalHTML = this.element.dataset.originalHtml

    if (originalHTML) {
      // Restore the original HTML to get the submit button back
      this.element.innerHTML = originalHTML

      // Find the form in the restored HTML
      const form = this.element.querySelector('form')

      if (form) {
        console.log('[InlineConfirm] Submitting form:', form.action)
        console.log('[InlineConfirm] Form method:', form.method)
        console.log('[InlineConfirm] _method field:', form.querySelector('input[name="_method"]')?.value)

        // Find and click the submit button
        const submitButton = form.querySelector('button[type="submit"]')

        if (submitButton) {
          console.log('[InlineConfirm] Clicking submit button')
          // Small delay to ensure DOM is ready
          setTimeout(() => {
            submitButton.click()
          }, 10)
        } else {
          console.error('[InlineConfirm] Submit button not found')
        }
      } else {
        console.error('[InlineConfirm] Form not found in restored HTML')
      }
    } else {
      console.error('[InlineConfirm] Original HTML not found')
    }
  }

  no(event) {
    event.preventDefault()
    console.log('[InlineConfirm] No clicked')

    const originalHTML = this.element.dataset.originalHtml

    // Restore original buttons
    if (originalHTML) {
      this.element.innerHTML = originalHTML
      delete this.element.dataset.originalHtml
    }
  }
}
