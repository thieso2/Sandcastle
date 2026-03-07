// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Close any open modals before Turbo caches the page, so they don't
// reappear when navigating back via the Turbo page cache.
document.addEventListener("turbo:before-cache", () => {
  document.querySelectorAll("[id^='snap-modal-']").forEach(el => el.classList.add("hidden"))
})
