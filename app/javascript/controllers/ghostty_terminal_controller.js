import { Controller } from "@hotwired/stimulus"
import { init, Terminal } from "ghostty-web"

// Bridges ghostty-web terminal with ttyd's WebSocket protocol.
//
// ttyd protocol:
//   Server→Client: first byte = command ('0'=output, '1'=title, '2'=preferences), rest = data
//   Client→Server: first byte = command ('0'=input, '1'=resize JSON), rest = data
//   On open: send JSON { AuthToken, columns, rows }
//   WebSocket subprotocol: "tty"
export default class extends Controller {
  static values = { wsUrl: String, tokenUrl: String }

  async connect() {
    await init()

    this.encoder = new TextEncoder()
    this.decoder = new TextDecoder()

    this.terminal = new Terminal({
      fontSize: 14,
      theme: {
        background: "#1a1b26",
        foreground: "#a9b1d6",
      },
    })

    this.terminal.open(this.element)

    this.terminal.onData((data) => this.sendInput(data))
    this.terminal.onResize?.(({ cols, rows }) => this.sendResize(cols, rows))

    this.token = await this.fetchToken()
    this.connectWebSocket()

    this.resizeObserver = new ResizeObserver(() => this.fitTerminal())
    this.resizeObserver.observe(this.element)
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    this.socket?.close()
    this.terminal?.dispose?.()
  }

  async fetchToken() {
    try {
      const resp = await fetch(this.tokenUrlValue)
      if (resp.ok) {
        const json = await resp.json()
        return json.token
      }
    } catch (e) {
      console.warn("[ghostty] token fetch failed:", e)
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
      this.terminal.focus?.()
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
        console.log("[ghostty] connection lost, reconnecting...")
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

  fitTerminal() {
    this.terminal.resize?.(
      Math.floor(this.element.clientWidth / 9),
      Math.floor(this.element.clientHeight / 17)
    )
  }
}
