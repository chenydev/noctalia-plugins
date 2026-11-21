--!nonstrict
-- Headroom bar capsule: a logo, a ring gauge and a percentage per provider
-- (per account, when the bar shows every account).
--
-- Presentation only: it watches the report the service publishes and never
-- fetches. Left click opens the panel; right click asks the service for a
-- refresh (bound in plugin.toml, so users can rebind it).

local state = require("./lib/state.luau")
local theme = require("./lib/theme.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")
local cards = require("./ui/cards.luau")

local ICON_SIZE = 15
local DEFAULT_TICK_MS = 30000
local CYCLE_TICK_MS = 1000

local report = noctalia.state.get(state.REPORT)
local currentTickMs = 0

local function syncUpdateInterval(windowPref: string)
  local wanted = if windowPref == "cycle" then CYCLE_TICK_MS else DEFAULT_TICK_MS
  if wanted ~= currentTickMs then
    currentTickMs = wanted
    noctalia.setUpdateInterval(wanted)
  end
end

local function windowBadge(window): string?
  if window.kind == "session" then
    return noctalia.tr("window.badge_session")
  elseif window.kind == "weekly" then
    return noctalia.tr("window.badge_weekly")
  end
  return nil
end

local function interval(): number
  return if type(report) == "table" and report.interval then report.interval else 300
end

local function itemNodes(item, vertical: boolean, style: string, ringStyle: string, showBadge: boolean, now: number)
  local account, window = item.account, item.window
  local stale = view.isStale(account, interval(), now)
  local nodes = { cards.logo(item.provider, ICON_SIZE, if stale and window == nil then 0.55 else nil) }

  if window == nil then
    -- Signed in but no numbers yet (first fetch running), or a failure.
    if account.phase == "failing" then
      table.insert(nodes, ui.glyph({ name = "alert-triangle", size = ICON_SIZE - 2, color = "error" }))
    else
      table.insert(nodes, ui.label({ text = "…", color = "on_surface_variant" }))
    end
    return nodes
  end

  local severity = view.severity(window, now)
  local showRing = style == "full" or style == "ring"
  local showPercent = style ~= "ring"
  local badge = windowBadge(window)

  if showRing then
    local percent = view.shownPercent(window)
    local color = theme.meterColor(severity)
    local opacity = if stale then 0.6 else 1
    local ring = if ringStyle == "hollow" and not account.busy
      then theme.hollowRing(percent, color, "surface_container")
      else nil
    if ring then
      table.insert(nodes, ui.image({ path = ring, width = ICON_SIZE, height = ICON_SIZE, opacity = opacity }))
    else
      table.insert(nodes, ui.glyph({
        name = if account.busy then "refresh" else theme.ring(percent),
        size = ICON_SIZE,
        color = color,
        opacity = opacity,
      }))
    end
  elseif style == "compact" and badge then
    -- Compact style replaces the pie/ring gauge with the 5h / 7d window tag.
    table.insert(nodes, ui.label({
      text = badge,
      fontSize = 11,
      color = "on_surface_variant",
      opacity = if stale or account.busy then 0.55 else 0.85,
    }))
  end
  if showPercent then
    -- At the limit the percentage says nothing new; when you get it back does.
    local exhausted = window.limitReached and window.resetsAt ~= nil and window.resetsAt > now
    local text = if exhausted then time.duration(window.resetsAt - now)
      elseif vertical and not view.isPastReset(window, now) then view.roundPercent(view.shownPercent(window))
      else view.percent(window)
    table.insert(nodes, ui.label({
      text = text,
      color = view.textColor(severity),
      fontWeight = if severity == "ok" then "medium" else "bold",
      opacity = if stale then 0.7 else 1,
    }))
    if showBadge and style ~= "compact" and badge then
      table.insert(nodes, ui.label({
        text = badge,
        fontSize = 10,
        color = "on_surface_variant",
        opacity = if stale then 0.55 else 0.8,
      }))
    end
  end
  return nodes
end

-- One short row per fact, so the tooltip never truncates:
--   Claude · Weekly   59% used (cached)
--   Resets            6h 5m · 07:59
--   Forecast          ≈ 61% by reset
--   Reset credits     2 · in 6d · Tue 17 Nov
-- With several accounts, the first key names the account: "Claude · Work · Weekly".
local function tooltipRows(items, now: number)
  local rows = {}
  for _, item in items do
    local account, window = item.account, item.window
    if window then
      local value = view.percent(window, true)
      if view.isStale(account, interval(), now) then
        value ..= ` ({noctalia.tr("status.cached")})`
      end
      table.insert(rows, { key = `{item.name} · {window.label}`, value = value })
      local untilReset = view.untilReset(window, now)
      if untilReset then
        table.insert(rows, { key = noctalia.tr("tooltip.resets"), value = untilReset })
      end
      local forecast = view.pace(window, now)
      if forecast and window.usedPercent < 100 then
        table.insert(rows, { key = noctalia.tr("tooltip.forecast"), value = forecast })
      end
      if view.creditCount(account.snapshot) > 0 then
        local count, expires = view.creditSummary(account.snapshot, now)
        table.insert(rows, { key = noctalia.tr("resets.label"), value = if expires then `{count} · {expires}` else count })
      end
    else
      local value = if account.phase == "failing"
        then noctalia.tr(`error.{account.error.code}.title`)
        else noctalia.tr("status.fetching")
      table.insert(rows, { key = item.name, value = value })
    end
  end
  return rows
end

local function render()
  local vertical = barWidget.isVertical()
  local now = view.now()
  local windowPref = state.config("window", "cycle")
  local cycleSeconds = math.clamp(state.config("cycle_seconds", 8), 3, 120)
  syncUpdateInterval(windowPref)
  local items = view.barItems(
    report,
    function(id: string): boolean
      return state.providerMode(id) == "bar"
    end,
    windowPref,
    math.clamp(state.config("max_items", 3), 1, 8),
    now,
    state.config("bar_accounts", "default") == "all",
    cycleSeconds
  )

  if #items == 0 then
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "gauge", size = ICON_SIZE, color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(noctalia.tr("bar.empty"))
    return
  end

  local style = state.config("bar_style", "compact")
  local ringStyle = state.config("ring_style", "filled")
  local showBadge = windowPref == "cycle"
  local container = if vertical then ui.column else ui.row
  local groups = {}
  for _, item in items do
    table.insert(groups, container({ gap = 4, align = "center", key = item.account.key }, itemNodes(item, vertical, style, ringStyle, showBadge, now)))
  end
  barWidget.render(container({ gap = if vertical then 8 else 10, align = "center" }, groups))
  barWidget.setTooltip(tooltipRows(items, now))
end

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

-- Ticks keep cycle alternation, countdowns and the tooltip current; data arrives via watch.
function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel(state.PANEL_ID)
end

render()
