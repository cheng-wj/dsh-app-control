# dsh-app-control

[![npm](https://img.shields.io/npm/v/dsh-app-control.svg)](https://www.npmjs.com/package/dsh-app-control)
[![license](https://img.shields.io/npm/l/dsh-app-control.svg)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Windows-blue.svg)](#平台)

在 DSH 会话内向模型提供三个工具，用来**重启**、**更新**和**体检** DeepSeek Harness 桌面应用本身。

核心卖点不是"能重启"，而是**重启不会把自己弄死**。这件事比看上去难：从 DSH 会话里重启 DSH，要同时躲开四个独立的坑，每一个都会让应用关上之后再也打不开，而且不报错。

---

## 三个工具

| 工具 | 作用 | 是否中断会话 |
|---|---|---|
| `dsh_status` | 列出 DSH 进程、python 记忆桥、已装插件版本（对比 registry 最新版） | 不中断，只读 |
| `dsh_restart` | 干净地关闭全部 DSH 进程，等待退出，然后自动重新打开 | 中断 |
| `dsh_update` | 装指定版本插件（绕开 `already-installed` bug），然后重启 | 中断 |

模型可以直接调用。典型对话：

> "帮我重启 DSH" → 调用 `dsh_restart`
> "dshmarket 更新失败了" → 先 `dsh_status` 看版本，再 `dsh_update` 传 `dshmarket@1.66.44`
> "记忆插件好像没生效" → `dsh_status` 看 python 桥接进程在不在

---

## 安装

### 本地安装（推荐，改代码立刻生效）

```powershell
dsh plugin --profile desktop add link:"C:\Users\ZY\Documents\deepseek-harness\默认工作区\dsh-app-control-plugin"
```

重启 DSH 后生效。用 `link:` 装的是目录软链，改完 `src/index.js` 重启就生效，不需要重新打包。

### 从 npm 安装（发布之后）

```powershell
dsh plugin --profile desktop add dsh-app-control
```

---

## 五个坑（这是本插件的全部价值）

前三个坑在开发过程中都**真实触发过**，第四个是参数层面的隐蔽 bug，第五个是插件发布层面的坑——它让插件「看起来装好了，其实一次都没跑」。

### 坑 1：`taskkill /T` 会杀掉调用者自己

`taskkill /IM "DeepSeek Harness.exe" /T /F` 里的 `/T` 会**向上遍历进程树**。如果调度脚本是 DSH 的子进程，它就是自己的行刑对象：应用被关掉，脚本也被干掉，于是没人负责重新打开。

**解法**：用 WMI 的 `Win32_Process.Create` 启动调度器。新进程的父进程是 `WmiPrvSE.exe`，不在 DSH 树里，`/T` 打不到它。

```powershell
$result = ([wmiclass] 'Win32_Process').Create($cmdLine)
```

### 坑 2：`start "" "app.exe"` 不是脱离

批处理里用 `start` 打开应用，新进程会**继承 cmd 的控制台**。用户关掉那个小黑窗时，Windows 发送 `CTRL_CLOSE_EVENT`，Electron 收到后直接退出——表现就是"关掉脚本窗口，DSH 也跟着退出了"。

**解法**：重开应用同样走 WMI，父进程是 `WmiPrvSE.exe`，没有共享控制台，关任何窗口都不影响它。

### 坑 3：`.bat` 必须是 CRLF（最阴的一个）

纯 LF 的批处理文件**不会报错**。`cmd.exe` 对 `call :LABEL` 是按字节偏移记账的，遇到 LF 只换行不回车时偏移算错，脚本会在中途**静默停止**：

```
[1/2] all DSH processes are gone     ← 走到这里
[2/2] DSH is running again           ← 永远不出现
```

应用被关掉了，再也没有重开，而且**没有任何错误信息**。这个坑排查了很久，最后用 A/B 对照确认：内容完全相同、只有行尾不同的两个文件，LF 版停在中途，CRLF 版完整跑完。

**解法**：`ensureCrlf()` 在每次运行前按**字节**统计 CR/LF 数量，不一致就原地修复。

```js
function crlfCounts(file) {
  const buf = readFileSync(file)
  let cr = 0, lf = 0
  for (const byte of buf) {
    if (byte === 13) cr++
    else if (byte === 10) lf++
  }
  return { cr, lf }
}
```

> ⚠️ 不要用 `awk '/\r$/'` 检查：它匹配的是**字面字母 r**，不是回车符，对正确的 CRLF 文件也会报"没有 CR"。只能用字节计数，或者 `node`。

### 坑 4：`cmd.exe` 把 `=` 当作参数分隔符

传 `--delay=5` 给批处理，实际收到的是**两个参数**：`--delay` 和 `5`。只匹配字面量 `--delay=` 的解析器永远不会命中，选项被静默忽略。

**解法**：匹配裸 `--delay`，从下一个参数取值。

```bat
if /I "!ARG!"=="--delay" (
    set "DELAY=%~2"
    shift
    shift
    goto MAIN_LOOP
)
```

同一个解析器还负责 `--profile`，并且**在倒计时之前**校验包列表非空——否则一个没有包名的 `update` 会先把 DSH 关掉、什么也不装、再重开一遍。

> 顺带一个相关约束：WMI 创建的进程**不继承调用者的环境变量**。所以 `DSH_DELAY` / `DSH_PROFILE` 这类环境变量传不进去，选项必须在命令行上显式传。环境变量只作为手动运行 `.bat` 时的兜底保留。

---

### 坑 5：插件「装好了」但 `apply()` 从未执行（最隐蔽的一个）

现象：`dsh plugin add` 成功，profile 里能看到依赖，重启后也没有任何报错——但工具一个都不出现。日志全绿。

原因有两层，都会让 Loader **静默跳过**整行：

**（a）`Config` 必须是 schemastery Schema，不能是普通对象。**

cordis 会把行的 `Config` 当成校验器**调用**。普通对象不可调用，`apply()` 前就抛错，整行被丢弃。

```js
// ✗ 错误：apply() 永远不会被调用
export const Config = { delaySeconds: { type: 'number', default: 10 } }

// ✓ 正确
import z from '@deepseek-ai/schemastery'
export const Config = z.object({ delaySeconds: z.number().default(10) })
```

**（b）peer 依赖必须惰性 + 可选解析。**

`@deepseek-ai/schemastery` 和 `@deepseek-ai/dsh-tools` 都是 **peer**，只由宿主提供。用**静态 import** 时，只要宿主一解析不到，整个模块导入就失败——而 Loader 把「插件导入失败」当作**非致命跳过**：记一条日志、不建 fiber、其余插件照常工作。于是插件完全隐身。

更麻烦的是 `link:` 安装：`node_modules/dsh-app-control` 指向源码目录，裸包名会按**源码树**解析，而 peer 是 hoist 在 **profile** 里的，所以恰好解析不到。

```js
// ✓ 惰性 + 可选，再从各 profile 目录兜底解析
let z = null
try { z = (await import('@deepseek-ai/schemastery')).default } catch {
  const { createRequire } = await import('node:module')
  z = createRequire(join(DSH_HOME, 'profiles', 'desktop', 'noop.cjs'))('@deepseek-ai/schemastery').default
}
export const Config = typeof z?.object === 'function' ? z.object({ /* ... */ }) : undefined
```

`Config` 缺失时导出 `undefined` 即可——cordis 会把行配置原样透传；工具本身不依赖 schema，代价只是少了设置界面。

> **诊断心法**：这类失败在宿主进程里**完全不可见**。插件应把 `apply()` 的每一步 `writeFileSync` 到一个 trace 日志里，否则「工具没出现」和「插件没加载」无法区分。本插件的 trace 在 `%DSH_HOME%\dsh-app-control\logs\apply-trace.log`。

---

## 配置

在 profile 的 `cordis.patch.yml` 里给这一行加配置即可：

```yaml
- dsh-app-control:
    delaySeconds: 10   # 倒计时秒数，留出取消的余地
    profile: desktop   # dsh_update 的默认 profile
```

`dsh_restart` 和 `dsh_update` 每次调用也可以在参数里覆盖 `delaySeconds`，用 `0` 立即重启。

---

## 文件结构

```
dsh-app-control-plugin/
├── src/index.js            # 插件主体：暂存脚本、驱动调度器、注册三个工具
├── assets/
│   ├── dsh-tools.bat       # 调度器：解析参数 → 倒计时 → taskkill /T → 重开
│   ├── launch-detached.ps1 # 经 WMI 脱离进程树启动，CRLF 守卫
│   ├── launch-app.ps1      # 经 WMI 打开应用本体
│   └── run-visible.ps1     # 输出同时打到控制台和日志（UTF-8 无 BOM）
├── cordis.patch.yml        # bundle 挂载声明
└── package.json
```

运行时会把这四个脚本复制到 `$DSH_HOME/dsh-app-control/scripts/`，日志写到 `$DSH_HOME/dsh-app-control/logs/`。**不写 `node_modules`**（可能只读、升级时被替换），日志也放在插件目录外，所以升级插件不会丢历史记录。

---

## 平台

仅 Windows。调度器依赖 `taskkill` / `tasklist` / WMI / PowerShell，这些没有跨平台等价物。

在非 Windows 宿主上插件行仍会挂载，工具也会注册，但每次调用都会返回明确错误，而不是悄悄什么都不做。

---

## 已知限制

- **会中断正在进行的对话**。`dsh_restart` / `dsh_update` 关闭应用时，当前会话跟着断。模型被告知要先提醒你保存工作。
- **单实例锁**。Electron 的单实例机制会让重复启动落回已有实例，所以不会开出两个 DSH；但也意味着"重开失败"不会以弹窗形式暴露，只能看日志。
- **日志是 UTF-8 无 BOM**。早先用 PowerShell 的 `Tee-Object` 写日志，PowerShell 5.1 下会写成 UTF-16LE，普通编辑器打开每个字符之间都是 `\0`。现在改用 `StreamWriter`，明确指定无 BOM 的 UTF-8。

---

## License

MIT
