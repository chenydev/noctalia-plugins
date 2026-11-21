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
2. **Antigravity 完整 5h + 周限额支持 + 双 Host 合并 + 禁后台挂起**：
   - 移除后台自动调用 `agy models`（无交互环境下容易卡在 OAuth 登录提示直至超时）。
   - 升级 `User-Agent` 至 `antigravity/hub/2.24.0` 并在 `v1internal:retrieveUserQuotaSummary` 中传递 `loadCodeAssist` 解析到的 `project`，避免后端版本门控省略 `Gemini` 5h/周限额桶；并发查询 `daily-cloudcode-pa` 与 `cloudcode-pa` 按 `bucketId` 合并（`daily` 优先），并保留 `Gemini 4 Argon / Carbon` 等独立子族标签及回退 `fetchAvailableModels`（含 `weeklyQuotaInfo`）。
   - 放宽 `isConfigured` 检测，直接兼容 `secret-tool`（go-keyring）、`~/.gemini/antigravity-cli/antigravity-oauth-token` 与 `~/.config/Antigravity`，并缩短 keyring 瞬态失败后的冷却时间。
3. **状态栏支持 5h / 周限额定时交替展示**：
   - Widget 新增 `window = "cycle"`（默认）与 `cycle_seconds`（默认 8 秒）配置，状态栏同步在 `5h` 与 `7d` 窗口间自动切换展示，并附带 `5h` / `7d` 紧凑标识。
4. **Codex 保持完整只读支持**：
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
location = "~/dev/projects/noctalia-plugins"
enabled = true
```

### 方式二：Git 仓库源（推荐，多机同步）

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
name = "chenydev"
kind = "git"
location = "https://github.com/chenydev/noctalia-plugins"
enabled = true
```

每次更新 `plugin.toml` 后运行 `python3 scripts/update-catalog.py`（或推送到 `main` 由 GitHub Actions 自动刷新 `catalog.toml`）。

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
