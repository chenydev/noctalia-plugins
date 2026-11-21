--!nonstrict
-- Adapters against recorded vendor responses: the endpoints are undocumented
-- and change shape without notice.

local t = require("./support/t")
local env = require("./support/env")

local function ids(windows)
  local out = {}
  for _, w in windows do
    out[w.id] = w
  end
  return out
end

t.group("claude", function()
  t.test("usage, plan from the token's profile, and the reset grants", function()
    local host, p, ctx = env.provider("claude")
    env.claudeCreds(host, "tok")
    env.serveClaude(host, { tok = "a" })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    local w = ids(snapshot.windows)
    t.eq(w.session.usedPercent, 38)
    t.eq(w.weekly.periodSeconds, 7 * 86400)
    t.eq(w["weekly_scoped:Fable"].label, "Weekly · Fable")
    t.eq(snapshot.plan, "Ultra")
    -- Started, unpaused grants with resets left, soonest to expire first.
    t.eq(#snapshot.resetCredits, 2)
    t.eq(snapshot.resetCredits[1].label, "One full limit reset (September 2026)")
    t.eq(snapshot.resetCredits[1].expiresAt, 1790373600)
    t.ok(env.headerOf(host.requests[2], "User-Agent"):match("^claude%-cli/%d+%.%d+%.%d+ %(external, cli%)$"), "Claude Code user agent")
  end)

  t.test("identity comes from the token, asked once per token", function()
    local host, p, ctx = env.provider("claude")
    env.serveClaude(host, { one = "a", two = "b" })
    env.claudeCreds(host, "one")
    t.eq(p.accounts.identity(ctx), nil, "unknown before a fetch")
    env.fetch(p, ctx)
    env.fetch(p, ctx)
    t.eq(env.requestsTo(host, "/oauth/profile"), 1)
    t.eq(p.accounts.identity(ctx).id, "acct-a/org-a")
    -- `/login` as someone else: a new token, so whose it is must be asked again.
    env.claudeCreds(host, "two")
    t.eq(p.accounts.identity(ctx), nil)
    env.fetch(p, ctx)
    t.eq(p.accounts.identity(ctx).id, "acct-b/org-a")
  end)

  t.test("the grants come at most hourly, and a failed profile is asked again", function()
    local host, p, ctx = env.provider("claude")
    env.claudeCreds(host, "tok")
    local profileUp = false
    local serve = host.httpHandler
    env.serveClaude(host, { tok = "a" })
    serve = host.httpHandler
    host.httpHandler = function(req)
      if req.url:find("/oauth/profile", 1, true) and not profileUp then
        return { ok = false }
      end
      return serve(req)
    end
    local first = env.fetch(p, ctx)
    t.eq(first.plan, nil, "no profile, no plan")
    profileUp = true
    host.clock += 600
    local second = env.fetch(p, ctx)
    t.eq(second.plan, "Ultra", "profile asked again")
    t.eq(env.requestsTo(host, "cedar_ember=1"), 1, "grants not re-read within the hour")
    t.eq(#second.resetCredits, 2, "the last grants still shown")
  end)

  t.test("expired token never spawns claude CLI to refresh", function()
    local host, p, ctx = env.provider("claude")
    host.commands.claude = true
    env.write(host, `{env.CLAUDE_HOME}/.credentials.json`, {
      claudeAiOauth = { accessToken = "old-tok", expiresAt = (host.clock - 10) * 1000, subscriptionType = "pro" },
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(snapshot, nil)
    t.ok(err and err.code == "expired", "reports expired")
    t.eq(#host.spawned, 0, "must never spawn background claude refresh")
    t.eq(#host.requests, 0, "no HTTP call with expired token")
  end)
end)

t.group("codex", function()
  t.test("windows, and reset credits with their expiry from the second endpoint", function()
    local host, p, ctx = env.provider("codex")
    env.codexAuth(host)
    env.serve(host, {
      ["wham/usage"] = env.fixture("codex_usage.json"),
      ["wham/rate-limit-reset-credits"] = env.fixture("codex_reset_credits.json"),
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(#snapshot.windows, 2)
    t.eq(#snapshot.resetCredits, 2, "redeemed ones left out")
    t.eq(snapshot.resetCredits[1].expiresAt, 1790100000, "soonest first")
    t.eq(env.headerOf(host.requests[2], "ChatGPT-Account-Id"), "acct-1")
  end)

  t.test("no credits: no second request; credit list unreachable: the count alone", function()
    local host, p, ctx = env.provider("codex")
    env.codexAuth(host)
    local usage = env.decode(host, env.fixture("codex_usage.json"))
    usage.rate_limit_reset_credits.available_count = 0
    env.serve(host, { ["wham/usage"] = host.globals.noctalia.json.encode(usage) })
    local none = env.fetch(p, ctx)
    t.eq(none.resetCredits, nil)
    t.eq(env.requestsTo(host, "reset-credits"), 0)

    env.serve(host, {
      ["wham/usage"] = env.fixture("codex_usage.json"),
      ["wham/rate-limit-reset-credits"] = { ok = true, status = 429, body = "" },
    })
    local counted = env.fetch(p, ctx)
    t.eq(#counted.resetCredits, 1)
    t.eq(counted.resetCredits[1].count, 2)
    t.eq(counted.resetCredits[1].expiresAt, nil)
  end)
end)

t.group("antigravity", function()
  t.test("parses the quota summary", function()
    local host, p, ctx = env.provider("antigravity")
    local snapshot, err = p.parse(env.decode(host, env.fixture("antigravity_quota.json")), ctx)
    t.eq(err, nil)
    t.ok(#snapshot.windows > 0, "windows")
  end)

  t.test("supplements missing Gemini buckets via fetchAvailableModels", function()
    local host, p, ctx = env.provider("antigravity")
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      token = { access_token = "ag-tok", expiry = host.clock + 3600 },
    })
    local summaryOnly3p = env.decode(host, env.fixture("antigravity_quota.json"))
    summaryOnly3p.groups = { summaryOnly3p.groups[2] } -- only Claude & GPT
    env.serve(host, {
      ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Ultra"},"cloudaicompanionProject":"aicode-consumers"}',
      ["retrieveUserQuotaSummary"] = host.globals.noctalia.json.encode(summaryOnly3p),
      ["fetchAvailableModels"] = env.fixture("antigravity_models.json"),
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(snapshot.plan, "Google AI Ultra")
    local w = ids(snapshot.windows)
    t.ok(w["3p-weekly"] ~= nil and w["3p-5h"] ~= nil, "keeps summary Claude & GPT windows")
    t.ok(w["model:gemini-pro"] ~= nil, "adds Gemini Pro from fetchAvailableModels")
    t.ok(w["model:gemini-flash"] ~= nil, "adds Gemini Flash from fetchAvailableModels")
    t.eq(w["model:claude-gpt"], nil, "does not duplicate Claude & GPT")
    t.eq(math.floor(w["model:gemini-pro"].usedPercent + 0.5), 28)
    t.eq(math.floor(w["model:gemini-flash"].usedPercent + 0.5), 15)
  end)

  t.test("falls back to fetchAvailableModels when retrieveUserQuotaSummary fails", function()
    local host, p, ctx = env.provider("antigravity")
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      token = { access_token = "ag-tok-2", expiry = host.clock + 3600 },
    })
    env.serve(host, {
      ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Pro"},"cloudaicompanionProject":"proj-1"}',
      ["retrieveUserQuotaSummary"] = { ok = true, status = 404, body = "" },
      ["fetchAvailableModels"] = env.fixture("antigravity_models.json"),
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(snapshot.plan, "Google AI Pro")
    local w = ids(snapshot.windows)
    t.ok(w["model:claude-gpt"] ~= nil, "fallback includes Claude & GPT")
    t.ok(w["model:gemini-pro"] ~= nil, "fallback includes Gemini Pro")
    t.ok(w["model:gemini-flash"] ~= nil, "fallback includes Gemini Flash")
    t.eq(math.floor(w["model:claude-gpt"].usedPercent + 0.5), 35)
  end)

  t.test("collapses shared Gemini pool when all Gemini models report identical quota", function()
    local host, p, ctx = env.provider("antigravity")
    local shared = {
      models = {
        ["gemini-2.5-pro"] = { displayName = "Gemini 2.5 Pro", quotaInfo = { remainingFraction = 0.965, resetTime = "2026-10-04T06:11:18Z" } },
        ["gemini-3-flash"] = { displayName = "Gemini 3 Flash", quotaInfo = { remainingFraction = 0.965, resetTime = "2026-10-04T06:11:18Z" } },
        ["gemini-4-hydrogen-sonar"] = { quotaInfo = { remainingFraction = 0.965, resetTime = "2026-10-04T06:11:18Z" } },
      },
    }
    local windows = p.parseModels(shared, ctx, { claude_gpt = true }, "model")
    t.eq(#windows, 1, "shared pool collapses into one Gemini bucket")
    t.eq(windows[1].id, "model:gemini")
    t.eq(windows[1].label, "Gemini · Session")
  end)

  t.test("sends hub/2.24.0 User-Agent and project, merging daily and prod summary buckets", function()
    local host, p, ctx = env.provider("antigravity")
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      token = { access_token = "ag-tok-merge", expiry = host.clock + 3600 },
    })
    local seenUa, seenSummaryBody = nil, nil
    host.httpHandler = function(req)
      if req.url:find("loadCodeAssist", 1, true) then
        return { ok = true, status = 200, body = '{"paidTier":{"name":"Google AI Ultra"},"cloudaicompanionProject":"real-proj-42"}' }
      elseif req.url:find("daily-cloudcode-pa", 1, true) and req.url:find("retrieveUserQuotaSummary", 1, true) then
        seenUa = env.headerOf(req, "User-Agent")
        seenSummaryBody = req.body
        return {
          ok = true,
          status = 200,
          body = host.globals.noctalia.json.encode({
            groups = {
              {
                displayName = "Gemini Models",
                buckets = {
                  { bucketId = "gemini-weekly", window = "weekly", remainingFraction = 0.85, resetTime = "2026-10-10T17:06:52Z" },
                  { bucketId = "gemini-5h", window = "5h", remainingFraction = 0.7, resetTime = "2026-10-04T06:11:18Z" },
                  { bucketId = "gemini-disabled-weekly", window = "weekly", remainingFraction = 0.1, disabled = true },
                },
              },
              {
                displayName = "Gemini 4 Argon",
                buckets = {
                  { bucketId = "gemini-argon-wtu-weekly", window = "weekly", remainingFraction = 0.6, resetTime = "2026-10-10T17:06:52Z" },
                },
              },
            },
          }),
        }
      elseif req.url:find("cloudcode-pa.googleapis.com", 1, true) and req.url:find("retrieveUserQuotaSummary", 1, true) then
        return {
          ok = true,
          status = 200,
          body = host.globals.noctalia.json.encode({
            groups = {
              {
                displayName = "Gemini Models",
                buckets = {
                  -- prod reports untouched 100% for consumer tier; daily reading must win
                  { bucketId = "gemini-weekly", window = "weekly", remainingFraction = 1, resetTime = "2026-10-10T17:06:52Z" },
                },
              },
              {
                displayName = "Claude and GPT models",
                buckets = {
                  { bucketId = "3p-weekly", window = "weekly", remainingFraction = 0.9, resetTime = "2026-10-11T01:11:18Z" },
                },
              },
            },
          }),
        }
      end
      return { ok = true, status = 404, body = "" }
    end

    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.ok(seenUa and seenUa:find("antigravity/hub/2.24.0", 1, true) ~= nil, "sends modern hub User-Agent")
    t.eq(seenSummaryBody, '{"project":"real-proj-42"}', "passes resolved project to summary")
    local w = ids(snapshot.windows)
    t.eq(math.floor(w["gemini-weekly"].usedPercent + 0.5), 15, "daily reading wins over prod")
    t.eq(math.floor(w["gemini-5h"].usedPercent + 0.5), 30)
    t.eq(w["gemini-disabled-weekly"], nil, "skips disabled buckets")
    t.eq(w["gemini-argon-wtu-weekly"].label, "Gemini 4 Argon · Weekly", "preserves dedicated subfamily label")
    t.eq(math.floor(w["3p-weekly"].usedPercent + 0.5), 10, "fills omitted buckets from prod")
  end)

  t.test("hides rolling full-window resetTime for untouched summary buckets", function()
    local host, p, ctx = env.provider("antigravity")
    local untouched = {
      groups = {
        {
          displayName = "Claude and GPT models",
          buckets = {
            -- host.clock is 1_790_000_000 (2026-09-21T14:13:20Z); +5h is 2026-09-21T19:13:20Z
            { bucketId = "3p-5h", window = "5h", remainingFraction = 1, resetTime = "2026-09-21T19:13:20Z" },
          },
        },
      },
    }
    local snapshot, err = p.parse(untouched, ctx)
    t.eq(err, nil)
    t.eq(snapshot.windows[1].resetsAt, nil, "suppresses rolling reset on untouched bucket")
  end)

  t.test("extracts weeklyQuotaInfo in fetchAvailableModels fallback", function()
    local host, p, ctx = env.provider("antigravity")
    local payload = {
      models = {
        ["gemini-3-pro"] = {
          displayName = "Gemini 3 Pro",
          quotaInfo = { remainingFraction = 0.8, resetTime = "2026-10-04T06:11:18Z" },
          weeklyQuotaInfo = { remainingFraction = 0.55, resetTime = "2026-10-10T17:06:52Z" },
        },
      },
    }
    local windows = p.parseModels(payload, ctx, nil, "session")
    local w = ids(windows)
    t.eq(w["model:gemini-pro"].kind, "session")
    t.eq(math.floor(w["model:gemini-pro"].usedPercent + 0.5), 20)
    t.eq(w["model:gemini-pro:weekly"].kind, "weekly")
    t.eq(math.floor(w["model:gemini-pro:weekly"].usedPercent + 0.5), 45)
  end)

  t.test("skips prod summary request when daily already returns both Gemini and 3p groups", function()
    local host, p, ctx = env.provider("antigravity")
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      token = { access_token = "ag-tok-single", expiry = host.clock + 3600 },
    })
    env.serve(host, {
      ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Ultra"},"cloudaicompanionProject":"proj-9"}',
      ["retrieveUserQuotaSummary"] = env.fixture("antigravity_quota.json"),
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(#snapshot.windows, 4)
    t.eq(env.requestsTo(host, "daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"), 1)
    t.eq(env.requestsTo(host, "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"), 0, "no redundant prod call")
  end)

  t.test("prefers fresh T3 Code profile token when keyring token has expired", function()
    local host, p, ctx = env.provider("antigravity")
    host.commands["secret-tool"] = true
    host.runHandler = function()
      return {
        exitCode = 0,
        stdout = host.globals.noctalia.json.encode({
          token = { access_token = "expired-keyring-tok", expiry = host.clock - 30 },
        }),
      }
    end
    env.write(host, "/home/test/.t3/userdata/providers/antigravity/prof1/antigravity-acp/antigravity-oauth-token", {
      token = { access_token = "fresh-t3-tok", expiry = host.clock + 3600 },
    })
    local seenAuth = nil
    host.httpHandler = function(req)
      seenAuth = env.headerOf(req, "Authorization")
      if req.url:find("loadCodeAssist", 1, true) then
        return { ok = true, status = 200, body = '{"paidTier":{"name":"Google AI Ultra"}}' }
      elseif req.url:find("retrieveUserQuotaSummary", 1, true) then
        return { ok = true, status = 200, body = env.fixture("antigravity_quota.json") }
      end
      return { ok = true, status = 404, body = "" }
    end
    local snapshot, err = env.fetch(p, ctx)
    t.eq(err, nil)
    t.eq(seenAuth, "Bearer fresh-t3-tok", "picks fresh T3 token without hitting keyring")
    t.eq(#host.spawned, 0, "skips secret-tool when disk token is already fresh")
    t.ok(#snapshot.windows == 4)
  end)

  t.test("refreshes in-memory token from T3 acp_token.json and caches it across polls", function()
    local host, p, ctx = env.provider("antigravity")
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      token = { access_token = "expired-cli-tok", expiry = host.clock - 30 },
    })
    local acpPath = "/home/test/.t3/userdata/providers/antigravity/prof1/antigravity-acp/acp_token.json"
    env.write(host, acpPath, {
      client_id = "cid-1",
      client_secret = "csec-1",
      refresh_token = "rtok-1",
      project_id = "aicode-consumers",
    })
    local originalAcp = host.files[acpPath]
    env.serve(host, {
      ["oauth2.googleapis.com/token"] = '{"access_token":"minted-tok","expires_in":3599}',
      ["loadCodeAssist"] = '{"paidTier":{"name":"Google AI Ultra"}}',
      ["retrieveUserQuotaSummary"] = env.fixture("antigravity_quota.json"),
    })

    local snap1, err1 = env.fetch(p, ctx)
    t.eq(err1, nil)
    t.eq(#snap1.windows, 4)
    t.eq(env.requestsTo(host, "oauth2.googleapis.com/token"), 1, "mints access token once")
    t.eq(host.files[acpPath], originalAcp, "never writes back to acp_token.json")

    -- Second poll 10 minutes later reuses cached in-memory token without another OAuth refresh.
    host.clock += 600
    local snap2, err2 = env.fetch(p, ctx)
    t.eq(err2, nil)
    t.eq(#snap2.windows, 4)
    t.eq(env.requestsTo(host, "oauth2.googleapis.com/token"), 1, "reuses cached in-memory token")
  end)

  t.test("expired token never spawns agy CLI to refresh", function()
    local host, p, ctx = env.provider("antigravity")
    host.commands.agy = true
    env.write(host, "/home/test/.gemini/antigravity-cli/antigravity-oauth-token", {
      token = { access_token = "expired-ag", expiry = host.clock - 10 },
    })
    local snapshot, err = env.fetch(p, ctx)
    t.eq(snapshot, nil)
    t.ok(err and err.code == "expired", "reports expired")
    t.eq(#host.spawned, 0, "must never spawn background agy models")
    t.eq(#host.requests, 0, "no HTTP call with expired token")
  end)
end)

return nil
