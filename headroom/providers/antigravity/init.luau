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

local DAILY_BASE = "https://daily-cloudcode-pa.googleapis.com"
local PROD_BASE = "https://cloudcode-pa.googleapis.com"
-- Matches Antigravity IDE/Hub 2.24.0 so retrieveUserQuotaSummary returns both
-- Gemini (5h/weekly/Argon/Carbon) and 3p (Claude & GPT) buckets without gating.
local USER_AGENT = "antigravity/hub/2.24.0 (aidev_client; os_type=linux; arch=x64; cl=963137146)"
local CLIENT_METADATA = '{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}'
-- Plan and project rarely change; cache per token for 6 hours.
local PLAN_TTL = 6 * 3600
local CODE_ASSIST_PATH = "/v1internal:loadCodeAssist"
local QUOTA_PATH = "/v1internal:retrieveUserQuotaSummary"
local MODELS_PATH = "/v1internal:fetchAvailableModels"
local SESSION_SECONDS = model.SESSION_SECONDS
local WEEK_SECONDS = model.WEEK_SECONDS

local KEYRING_LOOKUP = { "secret-tool", "lookup", "service", "gemini", "username", "antigravity" }
local TOKEN_FILE = "~/.gemini/antigravity-cli/antigravity-oauth-token"
local CLI_SETTINGS = "~/.gemini/antigravity-cli/settings.json"
local IDE_CONFIG_DIR = "~/.config/Antigravity"
local T3_PROVIDERS_DIR = "~/.t3/userdata/providers/antigravity"
local OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
-- Refresh an expiring access token 60s before expiry to avoid mid-request 401s.
local EXPIRY_SKEW_SECONDS = 60

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

-- In-memory access token minted from T3's acp_token.json when all on-disk
-- access tokens have expired. Never written back to disk; Google OAuth refresh
-- tokens are reusable and do not rotate away active T3 / agy sessions.
local memoryTokenCache: { fingerprint: string?, accessToken: string?, expiresAt: number, project: string? } = {
  fingerprint = nil,
  accessToken = nil,
  expiresAt = -math.huge,
  project = nil,
}

type Session = { accessToken: string, expiry: any, project: string? }
type AcpCredentials = { clientId: string, clientSecret: string, refreshToken: string, project: string?, fingerprint: string }

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

local function expiryUnix(expiry: any): number?
  local at = time.toUnix(expiry)
  if at == nil then
    return nil
  end
  if at > 1e11 then
    at /= 1000
  end
  return at
end

local function isFresh(session: Session?, now: number): boolean
  if session == nil then
    return false
  end
  local at = expiryUnix(session.expiry)
  if at == nil then
    return true
  end
  return at > now + EXPIRY_SKEW_SECONDS
end

local function t3ProfileDirs(ctx): { string }
  local root = ctx.expandPath(T3_PROVIDERS_DIR)
  if type(ctx.listDir) ~= "function" then
    return {}
  end
  local entries = ctx.listDir(root)
  if type(entries) ~= "table" then
    return {}
  end
  table.sort(entries)
  local dirs = {}
  for _, name in entries do
    if type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "." then
      table.insert(dirs, `{root}/{name}/antigravity-acp`)
    end
  end
  return dirs
end

local function readFileSessions(ctx): { Session }
  local sessions = {}
  local paths = { tokenFilePath(ctx) }
  for _, dir in t3ProfileDirs(ctx) do
    table.insert(paths, `{dir}/antigravity-oauth-token`)
  end
  for _, path in paths do
    if ctx.fileExists(path) then
      local s = parseSession(ctx.readFile(path), ctx)
      if s then
        table.insert(sessions, s)
      end
    end
  end
  return sessions
end

local function readAcpCredentials(ctx): AcpCredentials?
  for _, dir in t3ProfileDirs(ctx) do
    local path = `{dir}/acp_token.json`
    if ctx.fileExists(path) then
      local data = ctx.readJson(path)
      if type(data) == "table"
        and type(data.client_id) == "string" and data.client_id ~= ""
        and type(data.client_secret) == "string" and data.client_secret ~= ""
        and type(data.refresh_token) == "string" and data.refresh_token ~= ""
      then
        local proj = if type(data.project_id) == "string" and data.project_id ~= "" and data.project_id ~= "aicode-consumers"
          then data.project_id
          else nil
        return {
          clientId = data.client_id,
          clientSecret = data.client_secret,
          refreshToken = data.refresh_token,
          project = proj,
          fingerprint = `{data.client_id}\0{data.refresh_token}\0{proj or ""}`,
        }
      end
    end
  end
  return nil
end

-- Picks the freshest valid session across keyring, CLI file and T3 profiles.
-- Falls back to an expired session if none are fresh (so caller knows credentials exist).
local function pickBestSession(candidates: { Session }, now: number): Session?
  local bestFresh: Session? = nil
  local bestFreshExp = -math.huge
  local fallback: Session? = nil
  local fallbackExp = -math.huge
  for _, s in candidates do
    local exp = expiryUnix(s.expiry) or math.huge
    if isFresh(s, now) then
      if bestFresh == nil or exp > bestFreshExp then
        bestFresh, bestFreshExp = s, exp
      end
    elseif fallback == nil or exp > fallbackExp then
      fallback, fallbackExp = s, exp
    end
  end
  return bestFresh or fallback
end

local function readSession(ctx, done: (Session?) -> ())
  local fileSessions = readFileSessions(ctx)
  local now = ctx.now()
  local function choose(keyringSession: Session?)
    local candidates = table.clone(fileSessions)
    if keyringSession then
      table.insert(candidates, keyringSession)
    end
    done(pickBestSession(candidates, now))
  end

  -- Fast path: if an on-disk file (e.g. T3 Code's refreshed token) is already fresh,
  -- use it immediately without even waking the OS keyring.
  local bestDisk = pickBestSession(fileSessions, now)
  if bestDisk and isFresh(bestDisk, now) then
    done(bestDisk)
    return
  end

  if not ctx.which("secret-tool") or now < keyringRestUntil then
    choose(nil)
    return
  end
  ctx.run(KEYRING_LOOKUP, 5000, function(result)
    local session = result and result.exitCode == 0 and parseSession(result.stdout, ctx) or nil
    if session == nil then
      keyringRestUntil = ctx.now() + (if result == nil then KEYRING_REST else KEYRING_MISS_REST)
    end
    choose(session)
  end)
end

local function jsonEscape(s: string): string
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Mints a short-lived in-memory access token from T3's acp_token.json.
-- Cached for its ~55m lifetime; never writes anything to disk.
local function refreshFromAcp(ctx, creds: AcpCredentials, done: (Session?, model.ProviderError?) -> ())
  local now = ctx.now()
  if memoryTokenCache.fingerprint == creds.fingerprint
    and type(memoryTokenCache.accessToken) == "string"
    and memoryTokenCache.expiresAt > now + EXPIRY_SKEW_SECONDS
  then
    done({
      accessToken = memoryTokenCache.accessToken,
      expiry = memoryTokenCache.expiresAt,
      project = memoryTokenCache.project,
    }, nil)
    return
  end

  local body = '{"client_id":"'
    .. jsonEscape(creds.clientId)
    .. '","client_secret":"'
    .. jsonEscape(creds.clientSecret)
    .. '","refresh_token":"'
    .. jsonEscape(creds.refreshToken)
    .. '","grant_type":"refresh_token"}'

  ctx.postJson(OAUTH_TOKEN_URL, {}, body, function(data, err)
    if err ~= nil or type(data) ~= "table" or type(data.access_token) ~= "string" or data.access_token == "" then
      done(nil, model.err(E.Expired))
      return
    end
    local expiresIn = tonumber(data.expires_in) or 3600
    local expiresAt = ctx.now() + math.max(120, expiresIn)
    memoryTokenCache = {
      fingerprint = creds.fingerprint,
      accessToken = data.access_token,
      expiresAt = expiresAt,
      project = creds.project,
    }
    done({
      accessToken = data.access_token,
      expiry = expiresAt,
      project = creds.project,
    }, nil)
  end)
end

local function groupLabel(name: any): string
  name = if type(name) == "string" then name:match("^%s*(.-)%s*$") else ""
  if name:find("Gemini", 1, true) then
    return "Gemini"
  elseif name:find("Claude", 1, true) or name:find("GPT", 1, true) then
    return "Claude & GPT"
  end
  return name
end

-- Keeps dedicated Gemini subfamily pools (e.g. Gemini 4 Argon / Carbon) distinct
-- from the default Gemini 5h/weekly pool so they do not share identical labels.
local function bucketFamilyLabel(bucketId: string, groupDisplayName: any): string
  local trimmed = if type(groupDisplayName) == "string" then groupDisplayName:match("^%s*(.-)%s*$") else ""
  if bucketId:sub(1, 13) == "gemini-argon-" then
    return if trimmed ~= "" then trimmed else "Gemini Argon"
  elseif bucketId:sub(1, 14) == "gemini-carbon-" then
    return if trimmed ~= "" then trimmed else "Gemini Carbon"
  elseif bucketId:sub(1, 7) == "gemini-" then
    if bucketId == "gemini-5h" or bucketId == "gemini-weekly" or bucketId == "gemini-quota" then
      return "Gemini"
    end
    return if trimmed ~= "" then trimmed else "Gemini"
  elseif bucketId:sub(1, 3) == "3p-" then
    return "Claude & GPT"
  end
  return groupLabel(trimmed)
end

local function hasGroupBuckets(groups: any): boolean
  if type(groups) ~= "table" then
    return false
  end
  for _, group in groups do
    if type(group) == "table" and type(group.buckets) == "table" and #group.buckets > 0 then
      return true
    end
  end
  return false
end

local function parseSummaryWindows(data, ctx): { model.Window }
  local body = if type(data) == "table" and type(data.response) == "table" then data.response else data
  if type(body) ~= "table" then
    return {}
  end
  local groups
  if hasGroupBuckets(body.groups) then
    groups = body.groups
  elseif type(body.buckets) == "table" then
    groups = { { displayName = "", buckets = body.buckets } }
  else
    return {}
  end
  local now = ctx.now()
  local windows = {}
  for _, group in groups do
    for _, bucket in (if type(group.buckets) == "table" then group.buckets else {}) do
      if bucket.disabled == true then
        continue
      end
      local remaining = tonumber(bucket.remainingFraction)
      local id = tostring(bucket.bucketId or "")
      local cadence = bucket.window
      local weekly = cadence == "weekly" or id:sub(-6) == "weekly"
      local session = cadence == "5h" or id:sub(-2) == "5h"
      -- A missing fraction is unknown usage, not 0%: skip it rather than reassure.
      if remaining == nil or remaining ~= remaining or remaining < 0 or remaining > 1 or not (weekly or session) then
        continue
      end
      local label = bucketFamilyLabel(id, group.displayName)
      local kind = if weekly then "weekly" else "session"
      local periodSeconds = if weekly then WEEK_SECONDS else SESSION_SECONDS
      local resetsAt = time.parseIso8601(bucket.resetTime)
      -- Untouched summary buckets report a rolling full-window reset time; hide it.
      if remaining == 1 and bucket.description == nil and resetsAt ~= nil then
        if math.abs((resetsAt - now) - periodSeconds) <= 60 then
          resetsAt = nil
        end
      end
      table.insert(windows, model.window({
        id = if id ~= "" then id else `{label}:{kind}`,
        kind = kind,
        label = `{label} · {ctx.tr(`window.{kind}`)}`,
        usedPercent = (1 - remaining) * 100,
        resetsAt = resetsAt,
        periodSeconds = periodSeconds,
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
    if type(body) ~= "table" or (type(body.groups) ~= "table" and type(body.buckets) ~= "table") then
      return nil, model.err(E.Parse, "no quota groups")
    end
    return nil, model.err(E.Parse, "no usable quota buckets")
  end
  return model.snapshot({ plan = nil, windows = windows, notes = {}, fetchedAt = ctx.now() }), nil
end

-- Maps a model entry from fetchAvailableModels to a compact family bucket.
-- Internal helper models without displayName or resetTime (chat_*, tab_*) are skipped,
-- while named Gemini/Claude/GPT models and newer gemini-4* models with resetTime are kept.
local function classifyModelFamily(modelId: string, info: any): (string?, string?, string?)
  local idLow = modelId:lower()
  if idLow:sub(1, 5) == "chat_" or idLow:sub(1, 4) == "tab_" then
    return nil, nil, nil
  end
  local displayName = if type(info.displayName) == "string" then info.displayName else ""
  local nameLow = displayName:lower()
  if displayName == "" and not (idLow:find("gemini", 1, true) and type(info.quotaInfo) == "table" and info.quotaInfo.resetTime ~= nil) then
    return nil, nil, nil
  end
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

-- Parses v1internal:fetchAvailableModels into aggregated family windows, reading
-- both `quotaInfo` (5h session) and `weeklyQuotaInfo` (weekly) when present.
-- `skipFamilies` avoids duplicating families already reported by summary.
-- If all Gemini sub-buckets for a cadence share the exact same remainingFraction
-- and resetTime (shared Gemini pool), collapses them into a single "Gemini" window.
local function parseModels(data, ctx, skipFamilies: { [string]: boolean }?, kindOverride: string?): { model.Window }
  local body = if type(data) == "table" and type(data.response) == "table" then data.response else data
  local models = type(body) == "table" and body.models or nil
  if type(models) ~= "table" then
    return {}
  end

  local grouped: { [string]: { id: string, label: string, family: string, cadence: string, minRemaining: number, resetsAt: number? } } = {}
  local order = {}

  local function record(id: string, label: string, family: string, cadence: string, quota: any)
    if type(quota) ~= "table" then
      return
    end
    local remaining = tonumber(quota.remainingFraction)
    if remaining == nil or remaining ~= remaining or remaining < 0 or remaining > 1 then
      return
    end
    local key = if cadence == "weekly" then `{id}:weekly` else id
    local resetsAt = time.parseIso8601(quota.resetTime)
    local entry = grouped[key]
    if entry == nil then
      grouped[key] = {
        id = key,
        label = label,
        family = family,
        cadence = cadence,
        minRemaining = remaining,
        resetsAt = resetsAt,
      }
      table.insert(order, key)
    else
      if remaining < entry.minRemaining then
        entry.minRemaining = remaining
      end
      if resetsAt and (entry.resetsAt == nil or resetsAt < entry.resetsAt) then
        entry.resetsAt = resetsAt
      end
    end
  end

  for modelId, info in models do
    if type(modelId) ~= "string" or type(info) ~= "table" then
      continue
    end
    local id, label, family = classifyModelFamily(modelId, info)
    if id == nil or label == nil or family == nil then
      continue
    end
    if skipFamilies and skipFamilies[family] then
      continue
    end
    record(id, label, family, "session", info.quotaInfo)
    record(id, label, family, "weekly", info.weeklyQuotaInfo)
  end

  -- Collapse identical Gemini sub-pools per cadence into one clean "Gemini" bucket.
  for _, cadence in { "session", "weekly" } do
    local geminiKeys = {}
    for _, key in order do
      local entry = grouped[key]
      if entry and entry.family == "gemini" and entry.cadence == cadence then
        table.insert(geminiKeys, key)
      end
    end
    if #geminiKeys > 1 then
      local first = grouped[geminiKeys[1]]
      local samePool = true
      for i = 2, #geminiKeys do
        local other = grouped[geminiKeys[i]]
        if math.abs(other.minRemaining - first.minRemaining) > 1e-6 or other.resetsAt ~= first.resetsAt then
          samePool = false
          break
        end
      end
      if samePool then
        for _, key in geminiKeys do
          grouped[key] = nil
        end
        local collapsedId = if cadence == "weekly" then "model:gemini:weekly" else "model:gemini"
        grouped[collapsedId] = {
          id = collapsedId,
          label = "Gemini",
          family = "gemini",
          cadence = cadence,
          minRemaining = first.minRemaining,
          resetsAt = first.resetsAt,
        }
        order = {}
        for key in grouped do
          table.insert(order, key)
        end
      end
    end
  end

  table.sort(order)
  local windows = {}
  local sessionKind = kindOverride or "model"
  for _, key in order do
    local entry = grouped[key]
    local isWeekly = entry.cadence == "weekly"
    table.insert(windows, model.window({
      id = entry.id,
      kind = if isWeekly then "weekly" else sessionKind,
      label = `{entry.label} · {ctx.tr(if isWeekly then "window.weekly" else "window.session")}`,
      usedPercent = (1 - entry.minRemaining) * 100,
      resetsAt = entry.resetsAt,
      periodSeconds = if isWeekly then WEEK_SECONDS else SESSION_SECONDS,
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

-- Posts against daily-cloudcode-pa first (where agy/Antigravity actually tracks
-- live quota), falling back to cloudcode-pa on transport/server errors.
local function postApi(ctx, path: string, headers, body: string, done)
  ctx.postJson(`{DAILY_BASE}{path}`, headers, body, function(data, err)
    if err == nil or err.code == E.Auth or err.code == E.NoPlan then
      done(data, err)
      return
    end
    ctx.postJson(`{PROD_BASE}{path}`, headers, body, done, classify)
  end, classify)
end

local function withAssist(ctx, headers, done: (string?, string?, model.ProviderError?) -> ())
  local auth = headers["Authorization"]
  if assistCache.auth == auth and ctx.now() - assistCache.at < PLAN_TTL then
    done(assistCache.plan, assistCache.project, nil)
    return
  end
  postApi(ctx, CODE_ASSIST_PATH, headers, CLIENT_METADATA, function(data, err)
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
  end)
end

local function modelsRequestBody(project: string?): string
  if type(project) == "string" and project ~= "" then
    local escaped = project:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '{"project":"' .. escaped .. '"}'
  end
  return "{}"
end

-- Queries daily-cloudcode-pa first (the metered host for consumer accounts).
-- Only falls through to cloudcode-pa when daily fails, returns nothing, or omits
-- a model family (Gemini or Claude/GPT), avoiding redundant HTTP calls on every poll.
-- Daily readings always win on duplicate bucket ids; prod only fills missing buckets.
local function querySummaryMerged(ctx, headers, body: string, done: ({ model.Window }, model.ProviderError?) -> ())
  ctx.postJson(`{DAILY_BASE}{QUOTA_PATH}`, headers, body, function(dailyData, dailyErr)
    if dailyErr and (dailyErr.code == E.Auth or dailyErr.code == E.NoPlan) then
      done({}, dailyErr)
      return
    end
    local dailyWindows = if dailyErr == nil then parseSummaryWindows(dailyData, ctx) else {}
    local fams = presentFamilies(dailyWindows)
    if #dailyWindows > 0 and fams.gemini and fams.claude_gpt then
      done(dailyWindows, nil)
      return
    end

    ctx.postJson(`{PROD_BASE}{QUOTA_PATH}`, headers, body, function(prodData, prodErr)
      local prodWindows = if prodErr == nil then parseSummaryWindows(prodData, ctx) else {}
      local merged = {}
      local seen: { [string]: boolean } = {}
      for _, w in dailyWindows do
        if not seen[w.id] then
          seen[w.id] = true
          table.insert(merged, w)
        end
      end
      for _, w in prodWindows do
        if not seen[w.id] then
          seen[w.id] = true
          table.insert(merged, w)
        end
      end
      if #merged > 0 then
        done(merged, nil)
        return
      end
      local fatal = if prodErr and (prodErr.code == E.Auth or prodErr.code == E.NoPlan)
        then prodErr
        else dailyErr or prodErr
      done({}, fatal)
    end, classify)
  end, classify)
end

local function query(ctx, session: Session, done)
  local headers = {
    ["Authorization"] = `Bearer {session.accessToken}`,
    ["User-Agent"] = USER_AGENT,
  }

  withAssist(ctx, headers, function(plan, project, assistErr)
    if assistErr then
      done(nil, assistErr)
      return
    end

    local body = modelsRequestBody(project)
    querySummaryMerged(ctx, headers, body, function(summaryWindows, summaryErr)
      if summaryErr and (summaryErr.code == E.Auth or summaryErr.code == E.NoPlan) then
        done(nil, summaryErr)
        return
      end

      local families = presentFamilies(summaryWindows)
      local needModels = (#summaryWindows == 0) or (not families.gemini)

      if not needModels then
        done(model.snapshot({ plan = plan, windows = summaryWindows, notes = {}, fetchedAt = ctx.now() }), nil)
        return
      end

      postApi(ctx, MODELS_PATH, headers, body, function(modelsData, modelsErr)
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
      end)
    end)
  end)
end

return provider.define({
  id = "antigravity",
  name = "Antigravity",
  brand = {
    logo = "providers/antigravity/logo.svg",
  },

  isConfigured = function(ctx)
    if ctx.fileExists(ctx.expandPath(CLI_SETTINGS))
      or ctx.fileExists(tokenFilePath(ctx))
      or ctx.fileExists(ctx.expandPath(IDE_CONFIG_DIR))
      or ctx.which("secret-tool")
    then
      return true
    end
    for _, dir in t3ProfileDirs(ctx) do
      if ctx.fileExists(`{dir}/antigravity-oauth-token`) or ctx.fileExists(`{dir}/acp_token.json`) then
        return true
      end
    end
    return false
  end,

  signInHint = function(ctx)
    return ctx.tr("providers.antigravity.hint")
  end,

  fetch = function(ctx, done)
    readSession(ctx, function(session)
      if session ~= nil and isFresh(session, ctx.now()) then
        query(ctx, session, done)
        return
      end
      local acp = readAcpCredentials(ctx)
      if acp ~= nil then
        refreshFromAcp(ctx, acp, function(refreshed, err)
          if refreshed ~= nil then
            query(ctx, refreshed, done)
          else
            done(nil, err or model.err(E.Expired))
          end
        end)
        return
      end
      if session == nil then
        done(nil, model.err(E.NotConfigured))
      else
        -- Strictly read-only: never spawn `agy models` in the background.
        done(nil, model.err(E.Expired))
      end
    end)
  end,

  parse = parse,
  parseModels = parseModels,
})
