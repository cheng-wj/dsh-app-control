# 发布到 npm

> 状态：**已准备好，但尚未发布。** 下面每一步都需要你自己执行，因为我不能替你登录 npm。

---

## 0. 发布前必须改的两处

`package.json` 里有占位符，不改会在 npm 上显示成 `YOUR-GITHUB-USERNAME`：

```json
"repository": { "url": "git+https://github.com/<你的GitHub用户名>/dsh-app-control.git" },
"bugs":       { "url": "https://github.com/<你的GitHub用户名>/dsh-app-control/issues" },
"homepage":   "https://github.com/<你的GitHub用户名>/dsh-app-control#readme",
"author":     "chengwj <chengwjn@126.com>"
```

**包名已经查过并定下来了：`dsh-app-control`。**

> 最初的开发名是 `dsh-tools`，但那个名字在 npm 上已被他人占用（LoKiGGo 的同名 DSH 插件，1.1.5）。改名时必须**同时**改 `package.json` 的 `name` 和 `cordis.patch.yml` 里的 `name:` / `id:`——这两处必须一致，否则装上了挂不进去。
>
> 注意区分：`@deepseek-ai/dsh-tools` 是宿主提供的 peer 包，**不要改**它；`assets/dsh-tools.bat` 是内部脚本文件名，对用户不可见，也保持不变。

发布前再确认一次名字仍可用：

```powershell
npm view dsh-app-control
```

返回 404 才是可用。

---

## 1. 检查清单

```powershell
cd "C:\Users\ZY\Documents\deepseek-harness\默认工作区\dsh-app-control-plugin"

npm pack --dry-run     # 确认 9 个文件、约 20 kB、没有 node_modules
node --check src/index.js
```

打包产物里必须包含 `assets/dsh-tools.bat`，且**它的行尾必须是 CRLF**。已验证过一次：

```
CR=399 LF=399  ✓ CRLF 完好
```

如果哪天它变成纯 LF，插件运行时会由 `ensureCrlf()` 自动修复，所以不算致命——但最好在源头上不要退化。想复查：

```bash
node -e 'const fs=require("fs");const b=fs.readFileSync("assets/dsh-tools.bat");let cr=0,lf=0;for(const x of b){if(x===13)cr++;else if(x===10)lf++}console.log(cr===lf&&cr>0?"CRLF OK":"BROKEN")'
```

---

## 2. 登录

```powershell
npm login
npm whoami      # 确认登录成功
```

---

## 3. 发布

```powershell
npm publish --access public
```

首次发布如果想先验证再正式发，可以先干跑一次：

```powershell
npm publish --dry-run
```

---

## 4. 发布后自测

```powershell
# 从 registry 安装（不是 link:），验证真实安装路径
dsh plugin --profile desktop add dsh-app-control
```

然后重启 DSH，让模型调用一次 `dsh_status` 确认三个工具都活了。

---

## 5. 版本迭代

改了代码之后：

```powershell
npm version patch    # 修 bug
npm version minor    # 加功能
npm version major    # 破坏性改动
npm publish --access public
```

用户端更新走 `dsh_update` 工具或 `dsh plugin add dsh-app-control@<新版本>`。

---

## 6. 可选：推到 GitHub

```powershell
git init
git add .
git commit -m "feat: dsh-app-control — restart/update/status tools for DSH"
git branch -M main
git remote add origin https://github.com/<你的GitHub用户名>/dsh-app-control.git
git push -u origin main
```

`.gitignore` 已经排除了 `node_modules/`、`*.tgz`、`*.log`。

---

## 附：卸载

```powershell
dsh plugin --profile desktop remove dsh-app-control
```

`link:` 装的插件，改完 `src/index.js` 重启就生效，不用重新发布。
