import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { metricsUrl: String, statsUrl: String, compact: { type: Boolean, default: false } }
  static targets = ["cpuChart", "memChart", "cpuValue", "memValue"]

  connect() {
    this.cpuData = []
    this.memData = []
    this.windowMs = 30 * 60 * 1000

    this.loadHistory()
    this.pollInterval = setInterval(() => this.pollStats(), 5000)
  }

  disconnect() {
    if (this.pollInterval) clearInterval(this.pollInterval)
  }

  async loadHistory() {
    try {
      const resp = await fetch(this.metricsUrlValue)
      if (!resp.ok) return
      const points = await resp.json()
      points.forEach(p => {
        this.cpuData.push({ t: p.t * 1000, v: p.cpu })
        this.memData.push({ t: p.t * 1000, v: p.mem })
      })
      this.render()
    } catch (e) {
      // ignore
    }
  }

  async pollStats() {
    try {
      const resp = await fetch(this.statsUrlValue)
      if (!resp.ok) return
      const data = await resp.json()
      if (data.cpu == null) return
      const now = Date.now()
      this.cpuData.push({ t: now, v: data.cpu })
      this.memData.push({ t: now, v: data.mem })
      this.trim()
      this.render()
    } catch (e) {
      // ignore
    }
  }

  trim() {
    const cutoff = Date.now() - this.windowMs
    this.cpuData = this.cpuData.filter(p => p.t > cutoff)
    this.memData = this.memData.filter(p => p.t > cutoff)
  }

  render() {
    const compact = this.compactValue
    if (this.hasCpuChartTarget) this.renderChart(this.cpuChartTarget, this.cpuData, 0, 100, compact)
    if (this.hasMemChartTarget) this.renderChart(this.memChartTarget, this.memData, 0, null, compact)

    const lastCpu = this.cpuData[this.cpuData.length - 1]
    const lastMem = this.memData[this.memData.length - 1]
    if (lastCpu && this.hasCpuValueTarget) this.cpuValueTarget.textContent = `${lastCpu.v.toFixed(1)}%`
    if (lastMem && this.hasMemValueTarget) this.memValueTarget.textContent = `${Math.round(lastMem.v)} MB`
  }

  renderChart(target, data, fixedMin, fixedMax, compact) {
    if (data.length === 0) {
      target.innerHTML = ""
      return
    }

    const w = compact ? 80 : 200
    const h = compact ? 20 : 36
    const pad = 1
    const min = fixedMin != null ? fixedMin : Math.min(...data.map(p => p.v))
    let max = fixedMax != null ? fixedMax : Math.max(...data.map(p => p.v))
    if (max === min) max = min + 1

    const isBlue = fixedMax === 100
    const strokeColor = isBlue ? "#3b82f6" : "#8b5cf6"
    const fillColor = isBlue ? "rgba(59,130,246,0.1)" : "rgba(139,92,246,0.1)"
    const heightClass = compact ? "h-5" : "h-9"

    // Single point: just show a dot
    if (data.length === 1) {
      const y = h - pad - ((data[0].v - min) / (max - min)) * (h - 2 * pad)
      target.innerHTML = `<svg viewBox="0 0 ${w} ${h}" class="w-full ${heightClass}" preserveAspectRatio="none">
        <circle cx="${w / 2}" cy="${y.toFixed(1)}" r="2" fill="${strokeColor}" />
      </svg>`
      return
    }

    const tMin = data[0].t, tMax = data[data.length - 1].t
    const tRange = tMax - tMin || 1

    const points = data.map(p => {
      const x = pad + ((p.t - tMin) / tRange) * (w - 2 * pad)
      const y = h - pad - ((p.v - min) / (max - min)) * (h - 2 * pad)
      return `${x.toFixed(1)},${y.toFixed(1)}`
    }).join(" ")

    const lastPoint = data[data.length - 1]
    const lastX = pad + ((lastPoint.t - tMin) / tRange) * (w - 2 * pad)
    const lastY = h - pad - ((lastPoint.v - min) / (max - min)) * (h - 2 * pad)

    const fillPoints = `${pad},${h} ${points} ${lastX.toFixed(1)},${h}`
    const sw = compact ? 1 : 1.5
    const r = compact ? 1.5 : 2

    target.innerHTML = `<svg viewBox="0 0 ${w} ${h}" class="w-full ${heightClass}" preserveAspectRatio="none">
      <polygon points="${fillPoints}" fill="${fillColor}" />
      <polyline points="${points}" fill="none" stroke="${strokeColor}" stroke-width="${sw}" stroke-linejoin="round" stroke-linecap="round" />
      <circle cx="${lastX.toFixed(1)}" cy="${lastY.toFixed(1)}" r="${r}" fill="${strokeColor}" />
    </svg>`
  }
}
