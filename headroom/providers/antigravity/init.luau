--!nonstrict
-- Google Antigravity (the `agy` CLI and the Antigravity apps share one quota).
--
-- Credentials: strictly read-only from Secret Service
-- (`secret-tool lookup service gemini username antigravity`, go-keyring) or
-- the `agy` CLI token file `~/.gemini/antigravity-cli/antigravity-oauth-token`.
-- Never spawns `agy models` in the background: non-interactive auth prompts
-- hang until timeout and can race with active sessions. When a token expires,
-- we report E.Expired (keeping cached numbers visible) until `agy` / Antigravity
-- refreshes the session itself.
--
-- Endpoints:
--   1. POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
--      (cached 6h per token) for plan name and cloudaicompanionProject.
--   2. POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
--      for grouped 5h / weekly quota buckets.
--   3. POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels
--      as supplement (when summary omits Gemini pools, e.g. on Google AI Ultra)
--      and fallback (when summary fails or returns no usable buckets).

local provider = require("../../lib/provider.luau")
local model = require("../../lib/model.luau")
local time = require("../../lib/time.luau")
local jwt = require("../../lib/jwt.luau")

local E = model.ErrorCode

local CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
local CLIENT_METADATA = '{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}'
-- Plan and project rarely change; cache per token for 6 hours.
local PLAN_TTL = 6 * 3600
local QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
local MODELS_URL = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
local SESSION_SECONDS = model.SESSION_SECONDS
local WEEK_SECONDS = model.WEEK_SECONDS

local KEYRING_LOOKUP = { "secret-tool", "lookup", "service", "gemini", "username", "antigravity" }
local TOKEN_FILE = "~/.gemini/antigravity-cli/antigravity-oauth-token"
local CLI_SETTINGS = "~/.gemini/antigravity-cli/settings.json"
local IDE_CONFIG_DIR = "~/.config/Antigravity"

-- Shorter rest windows so a transient keyring lock at login recovers promptly.
local KEYRING_REST = 5 * 60
local KEYRING_MISS_REST = 60
local keyringRestUntil = -math.huge

-- Cached loadCodeAssist metadata per auth header.
local assistCache: { plan: string?, project: string?, at: number, auth: string? } = {
  plan = nil,
  project = nil,
  at = -math.huge,
  auth = nil,
}

type Session = { accessToken: string, expiry: any }

-- Accepts go-keyring's "go-keyring-base64:" wrapper, a { token = {...} }
-- envelope or a flat token object, with snake_case or camelCase keys.
local function parseSession(raw: string?, ctx): Session?
  if type(raw) ~= "string" then
    return nil
  end
  raw = raw:match("^%s*(.-)%s*$")
  local wrapped = raw:match("^go%-keyring%-base64:(.*)$")
  if wrapped then
    raw = jwt.base64Decode(wrapped)
    if raw == nil then
      return nil
    end
  end
  local data = ctx.decodeJson(raw)
  if type(data) ~= "table" then
    return nil
  end
  local token = if type(data.token) == "table" then data.token else data
  local access = token.access_token or token.accessToken
  if type(access) ~= "string" or access == "" then
    return nil
  end
  return { accessToken = access, expiry = token.expiry or token.expires_at or token.expiresAt }
end

local function tokenFilePath(ctx): string
  local cfgDir = ctx.env("AGY_CONFIG_DIR")
  if type(cfgDir) == "string" and cfgDir ~= "" then
    return `{cfgDir}/antigravity-oauth-token`
  end
  return ctx.expandPath(TOKEN_FILE)
end

local function readSession(ctx, done: (Session?) -> ())
  local function fromFile()
    local path = tokenFilePath(ctx)
    if not ctx.fileExists(path) then
      done(nil)
      return
    end
    local raw = ctx.readFile(path)
    done(parseSession(raw, ctx))
  end
  if not ctx.which("secret-tool") or ctx.now() < keyringRestUntil then
    fromFile()
    return
  end
  ctx.run(KEYRING_LOOKUP, 5000, function(result)
    local session = result and result.exitCode == 0 and parseSession(result.stdout, ctx) or nil
    if session then
      done(session)
      return
    end
    keyringRestUntil = ctx.now() + (if result == nil then KEYRING_REST else KEYRING_MISS_REST)
    fromFile()
  end)
end

local function isFresh(session: Session?, now: number): boolean
  if session == nil then
    return false
  end
  local at = time.toUnix(session.expiry)
  if at == nil then
    return true
  end
  if at > 1e11 then
    at /= 1000
  end
  return at > now
end

local function groupLabel(name: any): string
  name = if type(name) == "string" then name else ""
  if name:find("Gemini", 1, true) then
    return "Gemini"
  elseif name:find("Claude", 1, true) or name:find("GPT", 1, true) then
    return "Claude & GPT"
  end
  return name
end

local function parseSummaryWindows(data, ctx): { model.Window }
  local body = if type(data) == "table" and type(data.response) == "table" then data.response else data
  local groups = type(body) == "table" and body.groups or nil
  if type(groups) ~= "table" then
    return {}
  end
  local windows = {}
  for _, group in groups do
    local label = groupLabel(group.displayName)
    for _, bucket in (if type(group.buckets) == "table" then group.buckets else {}) do
      local remaining = tonumber(bucket.remainingFraction)
      local id = tostring(bucket.bucketId or "")
      local cadence = bucket.window
      local weekly = cadence == "weekly" or id:sub(-6) == "weekly"
      local session = cadence == "5h" or id:sub(-2) == "5h"
      -- A missing fraction is unknown usage, not 0%: skip it rather than reassure.
      if remaining == nil or remaining ~= remaining or remaining < 0 or remaining > 1 or not (weekly or session) then
        continue
      end
      local kind = if weekly then "weekly" else "session"
      table.insert(windows, model.window({
        id = if id ~= "" then id else `{label}:{kind}`,
        kind = kind,
        label = `{label} · {ctx.tr(`window.{kind}`)}`,
        usedPercent = (1 - remaining) * 100,
        resetsAt = time.parseIso8601(bucket.resetTime),
        periodSeconds = if weekly then WEEK_SECONDS else SESSION_SECONDS,
      }))
    end
  end
  return windows
end

-- Exposed for tests: quota summary -> Snapshot.
local function parse(data, ctx): (model.Snapshot?, model.ProviderError?)
  local windows = parseSummaryWindows(data, ctx)
  if #windows == 0 then
    local body = if type(data) == "table" and type(data.response) == "table" then data.response else data
    if type(body) ~= "table" or type(body.groups) ~= "table" then
      return nil, model.err(E.Parse, "no quota groups")
    end
    return nil, model.err(E.Parse, "no usable quota buckets")
  end
  return model.snapshot({ plan = nil, windows = windows, notes = {}, fetchedAt = ctx.now() }), nil
end

-- Maps a model entry from fetchAvailableModels to a compact family bucket.
-- Internal helper models without displayName (chat_*, tab_*) are skipped.
local function classifyModelFamily(modelId: string, displayName: any): (string?, string?, string?)
  if type(displayName) ~= "string" or displayName == "" then
    return nil, nil, nil
  end
  local idLow = modelId:lower()
  local nameLow = displayName:lower()
  if idLow:find("gemini", 1, true) or nameLow:find("gemini", 1, true) then
    if idLow:find("image", 1, true) or nameLow:find("image", 1, true) then
      return nil, nil, nil
    elseif idLow:find("pro", 1, true) or nameLow:find("pro", 1, true) then
      return "model:gemini-pro", "Gemini Pro", "gemini"
    elseif idLow:find("flash", 1, true) or nameLow:find("flash", 1, true) then
      return "model:gemini-flash", "Gemini Flash", "gemini"
    end
    return "model:gemini", "Gemini", "gemini"
  elseif idLow:find("claude", 1, true) or idLow:find("gpt", 1, true) or nameLow:find("claude", 1, true) or nameLow:find("gpt", 1, true) then
    return "model:claude-gpt", "Claude & GPT", "claude_gpt"
  end
  return nil, nil, nil
end

-- Parses v1internal:fetchAvailableModels into aggregated family windows.
-- `skipFamilies` avoids duplicating families already reported by summary.
local function parseModels(data, ctx, skipFamilies: { [string]: boolean }?, kindOverride: string?): { model.Window }
  local body = if type(data) == "table" and type(data.response) == "table" then data.response else data
  local models = type(body) == "table" and body.models or nil
  if type(models) ~= "table" then
    return {}
  end

  local grouped: { [string]: { id: string, label: string, minRemaining: number, resetsAt: number? } } = {}
  local order = {}

  for modelId, info in models do
    if type(modelId) ~= "string" or type(info) ~= "table" then
      continue
    end
    local quota = info.quotaInfo
    if type(quota) ~= "table" then
      continue
    end
    local remaining = tonumber(quota.remainingFraction)
    if remaining == nil or remaining ~= remaining or remaining < 0 or remaining > 1 then
      continue
    end
    local id, label, family = classifyModelFamily(modelId, info.displayName)
    if id == nil or label == nil or family == nil then
      continue
    end
    if skipFamilies and skipFamilies[family] then
      continue
    end
    local resetsAt = time.parseIso8601(quota.resetTime)
    local entry = grouped[id]
    if entry == nil then
      grouped[id] = { id = id, label = label, minRemaining = remaining, resetsAt = resetsAt }
      table.insert(order, id)
    else
      if remaining < entry.minRemaining then
        entry.minRemaining = remaining
      end
      if resetsAt and (entry.resetsAt == nil or resetsAt < entry.resetsAt) then
        entry.resetsAt = resetsAt
      end
    end
  end

  table.sort(order)
  local windows = {}
  local kind = kindOverride or "model"
  for _, id in order do
    local entry = grouped[id]
    table.insert(windows, model.window({
      id = entry.id,
      kind = kind,
      label = `{entry.label} · {ctx.tr("window.session")}`,
      usedPercent = (1 - entry.minRemaining) * 100,
      resetsAt = entry.resetsAt,
      periodSeconds = SESSION_SECONDS,
    }))
  end
  return windows
end

local function presentFamilies(windows: { model.Window }): { [string]: boolean }
  local families: { [string]: boolean } = {}
  for _, w in windows do
    local low = w.label:lower()
    if low:find("gemini", 1, true) then
      families.gemini = true
    elseif low:find("claude", 1, true) or low:find("gpt", 1, true) then
      families.claude_gpt = true
    end
  end
  return families
end

-- "Google AI Pro" / "Google AI Ultra" from loadCodeAssist; paidTier wins over
-- currentTier, which reads "free-tier" even for paid Google AI accounts.
local function planFrom(data): string?
  for _, key in { "paidTier", "currentTier" } do
    local tier = data[key]
    if type(tier) == "table" and type(tier.name) == "string" and tier.name ~= "" then
      return tier.name
    end
  end
  return nil
end

local function projectFrom(data): string?
  local proj = data.cloudaicompanionProject
  if type(proj) == "string" and proj ~= "" then
    return proj
  end
  if type(proj) == "table" and type(proj.id) == "string" and proj.id ~= "" then
    return proj.id
  end
  return nil
end

-- Google answers 403 SUBSCRIPTION_REQUIRED when the account's plan has no
-- Antigravity quota: a plan problem, not a sign-in problem.
local function classify(status: number, body: string): string?
  if status == 403 and string.find(body, "SUBSCRIPTION_REQUIRED", 1, true) then
    return E.NoPlan
  end
  return nil
end

local function withAssist(ctx, headers, done: (string?, string?, model.ProviderError?) -> ())
  local auth = headers["Authorization"]
  if assistCache.auth == auth and ctx.now() - assistCache.at < PLAN_TTL then
    done(assistCache.plan, assistCache.project, nil)
    return
  end
  ctx.postJson(CODE_ASSIST_URL, headers, CLIENT_METADATA, function(data, err)
    if err == nil and type(data) == "table" then
      assistCache = {
        plan = planFrom(data),
        project = projectFrom(data),
        at = ctx.now(),
        auth = auth,
      }
      done(assistCache.plan, assistCache.project, nil)
      return
    end
    if err and (err.code == E.Auth or err.code == E.NoPlan) then
      done(nil, nil, err)
      return
    end
    -- Best effort for transient loadCodeAssist errors: proceed without plan/project.
    if assistCache.auth == auth then
      done(assistCache.plan, assistCache.project, nil)
    else
      done(nil, nil, nil)
    end
  end, classify)
end

local function modelsRequestBody(project: string?): string
  if type(project) == "string" and project ~= "" then
    local escaped = project:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '{"project":"' .. escaped .. '"}'
  end
  return "{}"
end

local function query(ctx, session: Session, done)
  local headers = {
    ["Authorization"] = `Bearer {session.accessToken}`,
    ["User-Agent"] = "antigravity", -- required by the endpoint
  }

  withAssist(ctx, headers, function(plan, project, assistErr)
    if assistErr then
      done(nil, assistErr)
      return
    end

    ctx.postJson(QUOTA_URL, headers, "{}", function(summaryData, summaryErr)
      if summaryErr and (summaryErr.code == E.Auth or summaryErr.code == E.NoPlan) then
        done(nil, summaryErr)
        return
      end

      local summaryWindows = if summaryErr == nil then parseSummaryWindows(summaryData, ctx) else {}
      local families = presentFamilies(summaryWindows)
      local needModels = (#summaryWindows == 0) or (not families.gemini)

      if not needModels then
        done(model.snapshot({ plan = plan, windows = summaryWindows, notes = {}, fetchedAt = ctx.now() }), nil)
        return
      end

      ctx.postJson(MODELS_URL, headers, modelsRequestBody(project), function(modelsData, modelsErr)
        local extraWindows = if modelsErr == nil
          then parseModels(modelsData, ctx, families, if #summaryWindows == 0 then "session" else "model")
          else {}

        local merged = {}
        for _, w in summaryWindows do
          table.insert(merged, w)
        end
        for _, w in extraWindows do
          table.insert(merged, w)
        end

        if #merged > 0 then
          done(model.snapshot({ plan = plan, windows = merged, notes = {}, fetchedAt = ctx.now() }), nil)
        else
          done(nil, summaryErr or modelsErr or model.err(E.Parse, "no usable quota buckets"))
        end
      end, classify)
    end, classify)
  end)
end

return provider.define({
  id = "antigravity",
  name = "Antigravity",
  brand = {
    logo = "providers/antigravity/logo.svg",
  },

  isConfigured = function(ctx)
    return ctx.fileExists(ctx.expandPath(CLI_SETTINGS))
      or ctx.fileExists(tokenFilePath(ctx))
      or ctx.fileExists(ctx.expandPath(IDE_CONFIG_DIR))
      or ctx.which("secret-tool")
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.antigravity.hint")
  end,

  fetch = function(ctx, done)
    readSession(ctx, function(session)
      if session == nil then
        done(nil, model.err(E.NotConfigured))
      elseif isFresh(session, ctx.now()) then
        query(ctx, session, done)
      else
        -- Strictly read-only: never spawn `agy models` in the background.
        done(nil, model.err(E.Expired))
      end
    end)
  end,

  parse = parse,
  parseModels = parseModels,
})
