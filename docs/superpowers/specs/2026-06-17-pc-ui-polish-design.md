# wand-term PC 界面打磨与体验优化 — 设计文档

- 日期:2026-06-17
- 范围:外观重设计 + 桌面级交互 + 字号体验功能
- 目标平台:**鸿蒙 PC**(物理键盘 + 鼠标 + 可缩放窗口;不考虑手机/软键盘)
- 前置状态:P1(wand-agent WebSocket)已可用并通过真机测试;本轮**不加新传输**,只打磨现有功能

## 1. 背景与动机

P1 功能已跑通(连接 / 中文 / resize / 断开 / 重连 / 配置持久化 / token 加密存储),
但界面仍然很朴素:一个铺满的连接表单 + 一条状态栏 + 终端。用户在鸿蒙 PC 上使用,
当前体验缺乏桌面级的精致度和便利性。本轮聚焦三件事(按优先级):

1. **外观**(最高优先)— 现代开发者工具风,精致、克制、专业
2. **交互**(最高优先)— 桌面级:hover/聚焦反馈、物理快捷键、窗口缩放 reflow
3. **体验功能** — 字号调节 + 字号记忆

明确**不做**(YAGNI):手机辅助按键工具栏、软键盘避让(PC 无关);多服务器管理(体量大,留下一轮)。

## 2. 视觉基调(已确认)

- 风格:**A 现代开发者工具风**(类 Warp / 现代 iTerm)
- 主强调色:**青色 `#3DD6C4`**(accent)
- 调色板:
  - 背景 base `#0B0D10`
  - 卡片 surface `#11161D`
  - 边框 border `#1E2630`
  - 主文字 `#F4F7FB`
  - 次文字 `#8A94A6`(占位符/副标题)
  - accent 青 `#3DD6C4`(聚焦边框、连接按钮、连接态色点、字号高亮)
  - 状态色:连接绿沿用 accent 青 / 重连 warn 黄 `#FFB454` / 错误 danger 红 `#FF6B6B`
- 特征:卡片化、圆角 12、细边框、聚焦/hover 反馈、状态用"色点 + 文案"。

### 2.1 未连接(居中卡片)

连接表单从"铺满屏幕"改为**居中卡片**:标题 `◐ wand-term` + 副标题 `connect to wand-agent`,
卡片内含 主机/端口(同行)、Token(带 👁 显隐)、TLS 开关、记住 token 开关、错误行(有才显示)、
青色填充的"连接"按钮(hover 提亮)。输入框聚焦时边框转青色。

### 2.2 已连接(状态栏 + 终端)

状态栏:`● 已连接  host:port    A- <字号> A+    [断开]`
- 左:色点(连接=青 / 重连=黄 / 错误=红)+ 状态文案 + `host:port`
- 中:字号控制 `A-` `<当前字号>` `A+`
- 右:`断开`(危险色描边按钮)
- 终端区:**始终挂载**(沿用现有 TerminalSurface 生命周期约束,见 terminalsurface-lifecycle 记忆),layoutWeight 1

## 3. 交互(桌面级)

- **聚焦反馈**:输入框聚焦→边框青色高亮;按钮 hover 提亮、按下变暗(`.stateStyles` / hover 事件)。
- **快捷键**(连接后,终端获焦):
  - `Ctrl` + `=` → 放大字号
  - `Ctrl` + `-` → 缩小字号
  - `Ctrl` + `0` → 复位字号(默认 16)
- **复制/粘贴**:终端惯例走 `Ctrl+Shift+C/V`(避开 `Ctrl+C`=SIGINT)。
  **先验证 HAR(TerminalSurface)是否已接管**,已带则不重复实现,不与 HAR 抢按键;未带再补。
- **窗口缩放**:PC 窗口拖拽改大小→终端自动 reflow。现有 size listener 已驱动 resize;
  **先验证** PC 窗口 resize 时 listener 是否触发,触发即无需新增代码。
- **表单**:任意输入框 `Enter`→触发"连接";`Esc` 不绑(留给终端)。

## 4. 体验功能:字号

- 状态栏 `A-` / `A+` 调节,中间显示当前字号;范围 **10–28**,步进 2。
- 实现:`controller.updateConfig({ fontSize })`。
- **字号记忆**:字号写入 `@ohos.data.preferences`(与连接配置同库 `wand_conn`,新增 key `font_size`),
  下次启动沿用;`ConnectionStore` 增加 font size 的读写。
- 默认字号 16。

## 5. 受影响文件(预估)

- `entry/src/main/ets/pages/Index.ets` — 主改:卡片化表单、状态栏改版、字号控制、快捷键绑定、Enter 提交。
- `entry/src/main/ets/store/ConnectionStore.ets` — 增加 `font_size` 读写(load/save 扩展 ConnectionProfile 或单独方法)。
- 可能新增样式/常量文件(如 `entry/src/main/ets/theme/Palette.ets`)集中调色板,避免色值散落。
- HAR(`libghostty_ohos/.../TerminalSurface.ets`)**只读不改**:仅用于验证复制粘贴/字号/resize 现状。

## 6. 验证要点(本环境不能编译,交付后用户在 DevEco 真机验证)

1. 外观:卡片居中、青色 accent、聚焦/hover 反馈到位,深色和谐。
2. 字号:A-/A+ 与 Ctrl+=/-/0 都能调,显示同步;重启 App 字号被记住。
3. 快捷键不与终端输入冲突(尤其 Ctrl+C 仍是 SIGINT)。
4. 复制粘贴:确认走 Ctrl+Shift+C/V(HAR 已带或本轮补的)。
5. 窗口缩放:拖大/拖小窗口,终端内容 reflow 正常。
6. 回归:连接/中文/resize/断开/重连/配置回填/token 记忆 全部未被改坏。

## 7. 风险与待验证项

- 复制粘贴与窗口 resize 行为依赖 HAR/现有实现,**实现前先验证**,避免重复造轮子或抢按键。
- `controller.updateConfig({ fontSize })` 运行时改字号后是否平滑重排 — 需真机确认。
- 快捷键监听方式(页面级 `onKeyEvent` vs 终端获焦时)需在 ArkUI 上确认不会吞掉终端按键。

## 8. 不在本轮范围

- 多服务器/连接管理(下一轮单独 spec)。
- 任何新传输(P2:本地 PTY / SSH)。
- 主题切换 / 自定义配色 / 字体族选择(未来可选)。
