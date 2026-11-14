# Agent Sidebar（agent-sidebar）

Tern 的 coding agent 侧边栏插件：自动发现窗口里每一个正在运行的 AI 编码 agent，按 Tern session 分组实时展示状态，点击直达对应面板。**零配置**——agent 启动即出现、关闭即消失，无需任何手动登记。

![形态](https://img.shields.io/badge/tern-plugin-blue) ![语言](https://img.shields.io/badge/lang-Luau-green)

---

## 功能一览

| 能力 | 说明 |
|---|---|
| **自动发现** | 原生 agent 块（`omp`、`pi` 等被 Tern 收编的块）+ 终端里运行的已知 CLI agent（`claude`、`codex`、`opencode`、`gemini`、`aider`、`amp`、`cursor-agent`、`crush`、`goose`、`hermes`、`kimi`），2 秒一轮刷新 |
| **按 session 分组** | 每个 Tern session 一组，组头显示该组最差状态、agent 数量徽标和会话标识；当前 session 排最前 |
| **实时状态点** | working（脉冲 accent）、idle（空心）、needs you（琥珀）、done（绿）、failed（红）、exited（灰） |
| **厂商图标** | 每行一个圆角品牌方块 + 官方 logo（Anthropic / OpenAI / Codex / Gemini / Kimi / Cursor / omp / Moonshot / opencode 等），同一 agent 开多个聊天时**每个聊天各自带图标** |
| **对话标题** | 行名优先取对话标题（pane title），改标题即时同步；标题只是命令名时回退命令名 |
| **done / failed 标记** | turn 在你看不到的会话里完成后标记绿点（或红点），点击该行、聚焦该面板或 agent 再次工作时清除；标记持久化，重启不丢 |
| **点击直达** | 点击任意行，焦点直达该 agent 面板（自动切到其所在 tab） |
| **完成通知** | agent 进入「等待输入」时弹 Tern toast + macOS 系统通知（5 秒/面板冷却，不刷屏） |
| **面板记忆** | 侧栏钉在当前 tab 左侧，宽度可拖（记忆 0.15–0.6 比例）；跨 tab 跟随，与 Overseer 等其它左侧面板和平共存（自动避让到其右侧）；重启后按保存状态重开 |
| **近乎无感** | 忽略 spinner 动画帧，变更判断只看结构字段，切换 session / agent 流式输出时面板不闪烁、不重排 |

---

## 安装

插件通过 `tern plugin install <源>` 安装，源可以是**本地目录**或 **git URL**。

### 方式一：本地目录（源码安装）

```sh
# 直接安装当前源码目录
tern plugin install /path/to/agent-sidebar

# 或用打包产物（见下文「打包」）
bash pack.sh                      # 产出 dist/agent-sidebar
tern plugin install dist/agent-sidebar
```

### 方式二：git URL（推荐用于分发）

```sh
tern plugin install https://github.com/<owner>/<repo>.git
# 或 GitHub 简写（包在仓库根）
tern plugin install github.com/<owner>/<repo>
# 包在子目录时
tern plugin install github.com/<owner>/<repo>/<子目录>
```

`install` 会把包拷贝到插件目录（`tern plugin dir` 查看路径）。重复安装加 `--force` 覆盖。

### 开发模式（不拷贝，直接链接源码）

```sh
tern plugin link /path/to/agent-sidebar     # 改代码即生效，便于调试
tern plugin unlink agent-sidebar            # 取消链接
```

### 确认安装成功

```sh
tern plugin list        # 应显示:agent-sidebar 0.1.0 … ready
```

---

## 使用

| 操作 | 方式 |
|---|---|
| **显示 / 隐藏** | 快捷键 `⌘⌥⇧A`，或命令面板（`⌘⇧P`）搜「Agent Sidebar」 |
| **定位到某个 agent** | 点击对应行 |
| **清除 done/failed 标记** | 点击该行，或直接聚焦到该 agent 面板 |

侧栏自上而下：大标题 `AGENT` → 各 session 分组（组头 = 会话标识 + 最差状态点 + 会话名 + 数量徽标）→ 每个 agent 一行（厂商图标 + 状态点 + 对话标题/命令名 + 状态与目录）。

### 状态含义

| 状态 | 颜色 | 含义 |
|---|---|---|
| working | accent 脉冲点 | agent 正在工作 |
| idle | 空心点 | 空闲 |
| needs you | 琥珀点 | 等待你输入 / 确认 |
| done | 绿点 | turn 已在视野外完成 |
| failed | 红点 | turn 失败 |
| exited | 灰点 | 程序已退出 |

---

## 打包

`pack.sh` 把运行必需文件收成一个干净的可安装包，并打出压缩包：

```sh
bash pack.sh                 # 默认产出到 dist/
bash pack.sh /tmp/out        # 自定义输出目录
```

产物：

```
dist/agent-sidebar/           plugin.toml + window.luau + styles.css + README.md
dist/agent-sidebar.tar.gz     同内容压缩包，便于上传分发
```

- **本地分发**：直接 `tern plugin install dist/agent-sidebar`。
- **git 分发**：把 `dist/agent-sidebar/` 的内容推到一个 git remote，然后用「方式二」的 URL 安装。

---

## 卸载

```sh
tern plugin remove agent-sidebar     # 移除 install 拷贝的
# 或
tern plugin unlink agent-sidebar     # 移除 link 的
```

---

## 持久化数据

插件只在本机 `kv.json` 存三个键，卸载后可手动清除：

| 键 | 内容 |
|---|---|
| `panel-open` | 面板显隐意愿（布尔） |
| `panel-share` | 面板宽度比例（0.15–0.6） |
| `finished` | 未查看的 done/failed 标记（`{paneId: "done"|"failed"}`） |

---

## 验证（开发者）

仓库自带隔离实例端到端验证器，不触碰你的真实 Tern 会话：

```sh
cd /path/to/agent-sidebar
bash verify/run.sh                        # 9 项检查(done 项跳过)
VERIFY_AGENT_TURN=1 bash verify/run.sh    # 全 10 项,含一次真实 agent turn
```

覆盖：加载、自动出现、状态流转、自动消失、CLI 识别、done 标记、多 session 分组、显隐切换、重启恢复、预算纪律。

---

## 技术要点

- **纯 window half**（无 host block、无自定义 block），单文件 `window.luau`（Luau）。
- 数据源：`cx.agents:list()`（原生 agent 块，跨所有 session）+ `cx.session:panes()` 命令行解析（CLI agent）。
- 事件驱动 + 2 秒 tick 兜底：`agent_state` / `agent_finished` / `title` / `pane_closed` / `focus` 等。
- 预算纪律：事件处理器只改表，重活合并进 0ms timer；绘制按结构指纹跳过未变帧；hook 被暂停后自动追平。
- 厂商图标：Tern 内置 lobe-icons 官方 logo（自 `libtern.dylib` 提取），圆角品牌底色方块 + 白色 glyph，CSS `background-image` 内联。
