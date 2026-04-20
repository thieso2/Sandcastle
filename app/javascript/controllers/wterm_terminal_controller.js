import { Controller } from "@hotwired/stimulus"
import { WTerm } from "@wterm/dom"

// Bridges @wterm/dom terminal with ttyd's WebSocket protocol.
// Same protocol as ghostty/xterm controllers but using wterm.dev as the renderer.
export default class extends Controller {
  static values = { wsUrl: String, tokenUrl: String }

  async connect() {
    this.encoder = new TextEncoder()
    this.decoder = new TextDecoder()

    this.terminal = new WTerm(this.element, {
      cols: 80,
      rows: 24,
      autoResize: true,
      cursorBlink: true,
      onData: (data) => this.sendInput(data),
      onResize: (cols, rows) => this.sendResize(cols, rows),
      onTitle: (title) => { document.title = title + " — Sandcastle" },
    })

    await this.terminal.init()

    this.token = await this.fetchToken()
    this.connectWebSocket()
  }

  disconnect() {
    this.socket?.close()
    this.terminal?.destroy()
  }

  async fetchToken() {
    try {
      const resp = await fetch(this.tokenUrlValue)
      if (resp.ok) {
        const json = await resp.json()
        return json.token
      }
    } catch (e) {
      console.warn("[wterm] token fetch failed:", e)
    }
    return ""
  }

  connectWebSocket() {
    this.socket = new WebSocket(this.wsUrlValue, ["tty"])
    this.socket.binaryType = "arraybuffer"

    this.socket.addEventListener("open", () => {
      const msg = JSON.stringify({
        AuthToken: this.token,
        columns: this.terminal.cols || 80,
        rows: this.terminal.rows || 24,
      })
      this.socket.send(this.encoder.encode(msg))
      this.terminal.focus()
    })

    this.socket.addEventListener("message", (event) => {
      const rawData = event.data
      const cmd = String.fromCharCode(new Uint8Array(rawData)[0])
      const data = rawData.slice(1)

      switch (cmd) {
        case "0": // OUTPUT
          this.terminal.write(new Uint8Array(data))
          break
        case "1": // SET_WINDOW_TITLE
          document.title = this.decoder.decode(data) + " — Sandcastle"
          break
        case "2": // SET_PREFERENCES (ignored — we use our own theme)
          break
      }
    })

    this.socket.addEventListener("close", (event) => {
      if (event.code !== 1000) {
        console.log("[wterm] connection lost, reconnecting...")
        setTimeout(() => this.connectWebSocket(), 2000)
      }
    })
  }

  sendInput(data) {
    if (this.socket?.readyState !== WebSocket.OPEN) return

    if (typeof data === "string") {
      const payload = new Uint8Array(data.length * 3 + 1)
      payload[0] = "0".charCodeAt(0)
      const stats = this.encoder.encodeInto(data, payload.subarray(1))
      this.socket.send(payload.subarray(0, stats.written + 1))
    } else {
      const payload = new Uint8Array(data.length + 1)
      payload[0] = "0".charCodeAt(0)
      payload.set(data, 1)
      this.socket.send(payload)
    }
  }

  sendResize(cols, rows) {
    if (this.socket?.readyState !== WebSocket.OPEN) return
    const msg = JSON.stringify({ columns: cols, rows: rows })
    this.socket.send(this.encoder.encode("1" + msg))
  }
}
