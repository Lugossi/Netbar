.pragma library

var KIND_GLYPHS = {
  node:      "\ue718",
  vite:      "\ue718",
  next:      "\ue718",
  nuxt:      "\ue718",
  webpack:   "\ue718",
  storybook: "\ue718",
  nodemon:   "\ue718",
  astro:     "\ue718",
  esbuild:   "\ue718",
  angular:   "\ue718",
  bun:       "\ue718",
  deno:      "\ue718",
  python:    "\ue606",
  django:    "\ue606",
  ruby:      "\ue21e",
  php:       "\ue73d",
  java:      "\ue738",
  dotnet:    "\ue77f",
  rust:      "\ue7a8",
  go:        "\ue627",
  elixir:    "\ue62d",
  postgres:  "\ue76e",
  mysql:     "\ue704",
  redis:     "\ue76d",
  mongo:     "\ue7a4",
  docker:    "\uf308",
  webserver: "\uf0ac",
  ssh:       "\uf023",
  other:     "\uf1e6"
}

var SAFE_GLYPH = "\uf1e6"

function kindGlyph(kind) {
  var g = KIND_GLYPHS[String(kind || "other")]
  return g === undefined ? SAFE_GLYPH : g
}

function exposureGlyph(exposure) {
  return exposure === "local" ? "\uf023" : "\uf0ac"
}

function exposureLabel(exposure) {
  if (exposure === "local") return "localhost only"
  if (exposure === "all") return "exposed on all interfaces"
  return "exposed on this interface"
}

function exposureShort(exposure) {
  if (exposure === "local") return "LOCAL"
  if (exposure === "all") return "PUBLIC"
  return "LAN"
}

function isExposed(entry) {
  return !!entry && entry.exposure !== "local"
}

function formatUptime(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s < 0) return ""
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h " + (m % 60) + "m"
  var d = Math.floor(h / 24)
  return d + "d " + (h % 24) + "h"
}

var NON_HTTP_PORTS = { 22: 1, 25: 1, 53: 1, 143: 1, 993: 1, 995: 1,
                       3306: 1, 5432: 1, 6379: 1, 27017: 1, 11211: 1 }

function isWebLike(entry) {
  if (!entry || entry.proto !== "tcp") return false
  if (NON_HTTP_PORTS[entry.port]) return false
  var kind = String(entry.kind || "")
  if (kind === "postgres" || kind === "mysql" || kind === "redis"
      || kind === "mongo" || kind === "ssh") return false
  return true
}

function urlFor(entry) {
  if (!entry) return ""

  var scheme = (entry.port === 443 || entry.port === 8443) ? "https" : "http"
  return scheme + "://localhost:" + entry.port
}

function ignoreKey(entry) {
  if (!entry) return ""
  return String(entry.proto || "tcp") + "/" + String(entry.port || 0)
}

function titleFor(entry) {
  if (!entry) return ""
  var name = displayName(entry)
  var kind = String(entry.kind || "")
  if (!kind || kind === "other") return name

  if (entry.container) return name
  var n = name.toLowerCase()
  var k = kind.toLowerCase()
  if (n.indexOf(k) === 0 || k.indexOf(n) === 0) return name
  return name + "  ·  " + kind
}

function displayName(entry) {
  if (!entry) return ""
  if (entry.container && entry.container.name) return String(entry.container.name)

  if (entry.needsDockerAccess) return "docker container"
  return String(entry.name || "unknown")
}

function subtitle(entry) {
  if (!entry) return ""
  var bits = []
  if (entry.container && entry.container.image) bits.push(String(entry.container.image))
  else if (entry.project) bits.push(String(entry.project))
  var up = formatUptime(entry.uptimeSec)
  if (up) bits.push("up " + up)
  var c = Number(entry.connections || 0)
  if (c > 0) bits.push(c === 1 ? "1 connection" : c + " connections")
  if (entry.needsDockerAccess) {
    if (entry.containerTarget) bits.push("→ " + String(entry.containerTarget))
    bits.push("enable Docker access to name and stop it")
  } else if (entry.containerTarget) {
    bits.push("→ " + String(entry.containerTarget))
  }
  if (bits.length === 0) {
    if (entry.attributed === false) {
      var owner = String(entry.user || "")
      bits.push(owner === "root" ? "root-owned" : (owner || "another user"))
      bits.push("no process details without root")
    } else {
      bits.push("no details")
    }
  }
  return bits.join("  ·  ")
}

function commandLine(entry) {
  if (!entry) return ""
  var cmd = String(entry.cmdline || "")
  if (cmd.length === 0) return String(entry.name || "")
  return cmd.length > 240 ? cmd.substring(0, 237) + "…" : cmd
}

function matches(entry, needle) {
  var q = String(needle || "").toLowerCase().trim()
  if (q.length === 0) return true
  if (!entry) return false
  var hay = [
    String(entry.port), displayName(entry), String(entry.cmdline || ""),
    String(entry.project || ""), String(entry.kind || ""), String(entry.cwd || "")
  ].join(" ").toLowerCase()
  return hay.indexOf(q) !== -1
}

function plainText(text) {
  return String(text || "").replace(/[<>&]/g, " ").replace(/\s+/g, " ").trim()
}

function barTooltip(strays, exposed, ignored) {
  var lines = []
  if (strays === 0) lines.push("No dev servers listening")
  else lines.push(strays === 1 ? "1 dev server listening" : strays + " dev servers listening")
  if (exposed > 0) lines.push(exposed === 1
    ? "1 is reachable from your network"
    : exposed + " are reachable from your network")
  if (ignored > 0) lines.push(ignored + " ignored")
  return lines.join("\n")
}
