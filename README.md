# noctalia-plugins

自维护的 Noctalia v5 插件源仓库（符合官方 `catalog.toml` + `<plugin>/plugin.toml` 规范）。

## 插件清单

| 插件 ID | 说明 |
| --- | --- |
| `chenydev/headroom` | 基于上游 `ayagmar/headroom`（MIT）二开的 AI 套餐配额监控插件（Claude / Codex / Antigravity） |

### `chenydev/headroom` 相对上游的核心改动

1. **Claude 彻底改为纯只读，杜绝凭证并发失效**：
   - 移除过期时后台自动执行 `claude -p /status --no-session-persistence` 的逻辑，避免与正在运行的 Claude Code / T3 Code 并发触发 Anthropic OAuth refresh token rotation 导致会话失效。
   - Token 过期时保留上次缓存数据并温和提示，等待本地 CLI 自行刷新后自动恢复。
2. **Antigravity 双端点融合查询 + 禁后台挂起**：
   - 移除后台自动调用 `agy models`（无交互环境下容易卡在 OAuth 登录提示直至超时）。
   - 同时支持 `v1internal:retrieveUserQuotaSummary` 与 `v1internal:fetchAvailableModels`：汇总接口缺少 Gemini 分组时自动补齐（如 Google AI Ultra），汇总接口失败时无缝降级，保证 Gemini / Claude & GPT 均可见。
   - 放宽 `isConfigured` 检测，直接兼容 `secret-tool`（go-keyring）、`~/.gemini/antigravity-cli/antigravity-oauth-token` 与 `~/.config/Antigravity`，并缩短 keyring 瞬态失败后的冷却时间。
3. **Codex 保持完整只读支持**：
   - 保持多账号发现、5h/Weekly 窗口、Code Review 窗口、Credits 与 Reset Credits 查询，仅严格判定已过期。

## 接入 Noctalia v5

### 方式一：本地路径源（开发或单机推荐）

```toml
[plugins]
enabled = ["chenydev/headroom"]

[[plugins.source]]
name = "official"
kind = "git"
location = "https://github.com/noctalia-dev/official-plugins"
enabled = true

[[plugins.source]]
name = "community"
kind = "git"
location = "https://github.com/noctalia-dev/community-plugins"
enabled = true

[[plugins.source]]
name = "personal"
kind = "path"
location = "/home/chenyong/dev/projects/noctalia-plugins"
enabled = true
```

### 方式二：Git 仓库源（推送到 GitHub 后多机同步）

将 `kind` 改为 `"git"`、`location` 改为你的仓库地址即可（每次更新 `plugin.toml` 后运行 `python3 scripts/update-catalog.py` 刷新 `catalog.toml`）。

Bar 组件配置：

```toml
[widget.headroom]
type = "chenydev/headroom:usage"
```

## 校验与测试

```bash
# 1. 生成/刷新 catalog.toml
python3 scripts/update-catalog.py

# 2. Noctalia 官方离线插件校验
noctalia plugins lint headroom

# 3. 运行 Luau 单元测试
nix shell nixpkgs#luau -c headroom/tests/run.sh
```
