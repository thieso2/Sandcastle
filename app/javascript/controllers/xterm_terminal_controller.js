import { Controller } from "@hotwired/stimulus"
import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"

// Bridges xterm.js terminal with ttyd's WebSocket protocol.
// Same protocol as ghostty_terminal_controller but using xterm.js as the renderer.
export default class extends Controller {
  static values = { wsUrl: String, tokenUrl: String }

  async connect() {
    this.encoder = new TextEncoder()
    this.decoder = new TextDecoder()

    this.fitAddon = new FitAddon()

    this.terminal = new Terminal({
      fontSize: 14,
      fontFamily: "Menlo, Monaco, 'Courier New', monospace",
      cursorBlink: true,
      theme: {
        background: "#1a1b26",
        foreground: "#a9b1d6",
        cursor: "#a9b1d6",
      },
    })

    this.terminal.loadAddon(this.fitAddon)
    this.terminal.loadAddon(new WebLinksAddon())
    this.terminal.open(this.element)
    this.fitAddon.fit()

    this.terminal.onData((data) => this.sendInput(data))
    this.terminal.onBinary((data) => this.sendBinary(data))
    this.terminal.onResize(({ cols, rows }) => this.sendResize(cols, rows))

    this.token = await this.fetchToken()
    this.connectWebSocket()

    this.resizeObserver = new ResizeObserver(() => {
      try { this.fitAddon.fit() } catch {}
    })
    this.resizeObserver.observe(this.element)
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    this.socket?.close()
    this.terminal?.dispose()
  }

  async fetchToken() {
    try {
      const resp = await fetch(this.tokenUrlValue)
      if (resp.ok) {
        const json = await resp.json()
        return json.token
      }
    } catch (e) {
      console.warn("[xterm] token fetch failed:", e)
    }
    return ""
  }

  connectWebSocket() {
    this.socket = new WebSocket(this.wsUrlValue, ["tty"])
    this.socket.binaryType = "arraybuffer"

    this.socket.addEventListener("open", () => {
      const msg = JSON.stringify({
        AuthToken: this.token,
        columns: this.terminal.cols,
        rows: this.terminal.rows,
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
        case "2": // SET_PREFERENCES (ignored)
          break
      }
    })

    this.socket.addEventListener("close", (event) => {
      if (event.code !== 1000) {
        console.log("[xterm] connection lost, reconnecting...")
        setTimeout(() => this.connectWebSocket(), 2000)
      }
    })
  }

  sendInput(data) {
    if (this.socket?.readyState !== WebSocket.OPEN) return
    const payload = new Uint8Array(data.length * 3 + 1)
    payload[0] = "0".charCodeAt(0)
    const stats = this.encoder.encodeInto(data, payload.subarray(1))
    this.socket.send(payload.subarray(0, stats.written + 1))
  }

  sendBinary(data) {
    if (this.socket?.readyState !== WebSocket.OPEN) return
    const bytes = new Uint8Array(data.length + 1)
    bytes[0] = "0".charCodeAt(0)
    for (let i = 0; i < data.length; i++) bytes[i + 1] = data.charCodeAt(i) & 255
    this.socket.send(bytes)
  }

  sendResize(cols, rows) {
    if (this.socket?.readyState !== WebSocket.OPEN) return
    const msg = JSON.stringify({ columns: cols, rows: rows })
    this.socket.send(this.encoder.encode("1" + msg))
  }
}
