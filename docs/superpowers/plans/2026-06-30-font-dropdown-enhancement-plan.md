# 字体选择功能增强实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `docs/` 下的两个 Claude 字体接入设置面板的字体选择器，并优化下拉选择栏的动画与交互行为。

**Architecture:** 保持现有自定义下拉结构，改用 HarmonyOS 物理弹簧曲线 `curves.springMotion()` 实现展开/收起动画；通过根容器 `onClick` 关闭下拉、下拉容器空 `onClick` 阻止冒泡，实现“点选项不收起、点外部收起”。

**Tech Stack:** ArkTS / ArkUI / HarmonyOS API 24

## Global Constraints

- 仅修改 `entry/` 模块，不侵入 `libghostty_ohos/` 公共库。
- 字体资源统一放在 `entry/src/main/resources/rawfile/fonts/`。
- 使用 `this.getUIContext().getFont().registerFont()` 注册自定义字体（API 18+ 推荐方式）。
- 注册失败时静默回退，不影响应用启动。
- 保持现有深色主题样式与 Palette 颜色系统。

---

## Task 1: 复制并重命名字体资源

**Files:**
- Create: `entry/src/main/resources/rawfile/fonts/ClaudeSans-Regular.ttf`
- Create: `entry/src/main/resources/rawfile/fonts/ClaudeSans-LET-Plain10.ttf`

**Interfaces:**
- Produces: 两个无空格文件名的 .ttf 字体资源。

- [ ] **Step 1: 复制 `docs/claude sans regular.ttf`**

```bash
cp "docs/claude sans regular.ttf" "entry/src/main/resources/rawfile/fonts/ClaudeSans-Regular.ttf"
```

- [ ] **Step 2: 复制 `docs/claude-sans-let-plain10.ttf`**

```bash
cp "docs/claude-sans-let-plain10.ttf" "entry/src/main/resources/rawfile/fonts/ClaudeSans-LET-Plain10.ttf"
```

- [ ] **Step 3: 确认文件存在**

```bash
ls -la entry/src/main/resources/rawfile/fonts/
```

Expected: 看到 `ClaudeSans-Regular.ttf` 与 `ClaudeSans-LET-Plain10.ttf`。

---

## Task 2: 注册字体并扩展字体选项

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets:103-121`
- Modify: `entry/src/main/ets/theme/FontScale.ets:35-49`

**Interfaces:**
- Consumes: 新增字体资源路径 `$rawfile('fonts/ClaudeSans-Regular.ttf')` / `$rawfile('fonts/ClaudeSans-LET-Plain10.ttf')`。
- Produces: `UI_FONT_OPTIONS` 增加 `Claude Sans`；`TERM_FONT_OPTIONS` 增加 `Claude Sans LET Plain10`。

- [ ] **Step 1: 在 `Index.ets` 注册两个新字体**

在 `aboutToAppear()` 的 `try` 块中，现有 `registerFont` 调用之后追加：

```typescript
fontMgr.registerFont({
  familyName: 'Claude Sans',
  familySrc: $rawfile('fonts/ClaudeSans-Regular.ttf')
});
fontMgr.registerFont({
  familyName: 'Claude Sans LET Plain10',
  familySrc: $rawfile('fonts/ClaudeSans-LET-Plain10.ttf')
});
```

- [ ] **Step 2: 在 `FontScale.ets` 增加选项**

```typescript
export const UI_FONT_OPTIONS: FontOption[] = [
  { family: 'Inter', label: 'Inter (无衬线)', category: 'ui' },
  { family: 'Source Serif 4', label: 'Source Serif 4 (衬线)', category: 'ui' },
  { family: 'HarmonyOS Sans', label: 'HarmonyOS Sans', category: 'ui' },
  { family: 'Noto Sans SC', label: 'Noto Sans SC', category: 'ui' },
  { family: 'Claude Sans', label: 'Claude Sans', category: 'ui' },
  { family: 'monospace', label: 'Monospace (等宽)', category: 'ui' },
];

export const TERM_FONT_OPTIONS: FontOption[] = [
  { family: 'Noto Sans Mono', label: 'Noto Sans Mono', category: 'terminal' },
  { family: 'JetBrains Mono', label: 'JetBrains Mono', category: 'terminal' },
  { family: 'Fira Code', label: 'Fira Code', category: 'terminal' },
  { family: 'Cascadia Code', label: 'Cascadia Code', category: 'terminal' },
  { family: 'Source Code Pro', label: 'Source Code Pro', category: 'terminal' },
  { family: 'Claude Sans LET Plain10', label: 'Claude Sans LET Plain10', category: 'terminal' },
];
```

- [ ] **Step 3: 运行 Node 校验脚本确保未破坏现有逻辑**

```bash
node --test tools/verify/fontscale.test.mjs
```

Expected: 测试通过。

---

## Task 3: 优化下拉选择栏动画与交互

**Files:**
- Modify: `entry/src/main/ets/pages/SettingsPanel.ets:139-215`（根 Column）以及 `552-734`（两个下拉）

**Interfaces:**
- Consumes: `curves` from `@kit.ArkUI`。
- Produces: 展开/收起使用 `curves.springMotion()`；选项点击不关闭下拉；外部点击关闭下拉。

- [ ] **Step 1: 导入 `curves`**

在 `SettingsPanel.ets` 顶部现有 import 后追加：

```typescript
import { curves } from '@kit.ArkUI';
```

- [ ] **Step 2: 在根 Column 添加外部点击关闭**

将 `build()` 中返回的最外层 `Column` 改为：

```typescript
Column() {
  // 现有 header、tab、Tabs 内容保持不变
}
.width('100%')
.height('100%')
.backgroundColor(Palette.base)
.onClick(() => {
  if (this.uiFontDropdownOpen || this.termFontDropdownOpen) {
    this.uiFontDropdownOpen = false;
    this.termFontDropdownOpen = false;
  }
})
```

- [ ] **Step 3: 提取下拉转场效果**

在 `SettingsPanel` 类中添加私有属性：

```typescript
private readonly dropdownEnter: TransitionEffect =
  TransitionEffect.OPACITY
    .combine(TransitionEffect.translate({ y: -8 }))
    .combine(TransitionEffect.scale({ y: 0 }))
    .animation({ curve: curves.springMotion(0.6, 0.8) });

private readonly dropdownExit: TransitionEffect =
  TransitionEffect.OPACITY
    .combine(TransitionEffect.translate({ y: -4 }))
    .animation({ curve: curves.springMotion(0.6, 0.8) });
```

- [ ] **Step 4: 改造 UI 字体下拉**

将 UI 字体下拉区域（当前 `Column({ space: 6 })` 包含头部和展开列表）整体加上 `.onClick(() => {})`，并做以下修改：

1. 头部行 `.animation({ duration: 180, curve: Curve.EaseOut })` 改为 `.animation({ curve: curves.springMotion(0.6, 0.8) })`。
2. 箭头旋转 `.animation({ duration: 220, curve: Curve.EaseOut })` 改为 `.animation({ curve: curves.springMotion(0.6, 0.8) })`。
3. 展开列表的 `.transition(TransitionEffect.asymmetric(...))` 替换为 `.transition(TransitionEffect.asymmetric(this.dropdownEnter, this.dropdownExit))`。
4. 选项行 `.onClick` 中删除 `this.uiFontDropdownOpen = false;` 这一行，只保留字体赋值与回调。

- [ ] **Step 5: 改造终端字体下拉**

对终端字体下拉做与 Step 4 完全相同的修改：

1. 头部行动画改为 `curves.springMotion(0.6, 0.8)`。
2. 箭头旋转动画改为 `curves.springMotion(0.6, 0.8)`。
3. 列表转场改为 `this.dropdownEnter` / `this.dropdownExit`。
4. 选项行 `.onClick` 中删除 `this.termFontDropdownOpen = false;`。

- [ ] **Step 6: 验证编译**

```bash
node --test tools/verify/fontscale.test.mjs
```

Expected: 测试通过（UI 改动无 Node 单测，至少保证工具脚本未受影响）。

---

## Task 4: 手动验证清单

- [ ] 构建 HAP / 使用预览器启动设置面板。
- [ ] 进入“设置 → 外观”。
- [ ] UI 字体下拉中出现 `Claude Sans` 选项，终端字体下拉中出现 `Claude Sans LET Plain10`。
- [ ] 选择 `Claude Sans` 后，设置面板文字渲染为 Claude Sans。
- [ ] 点击 UI 字体下拉头部，下拉以弹簧动画展开；再点击头部，以弹簧动画收起。
- [ ] 展开后点击某个选项：选中态更新，但下拉**保持展开**。
- [ ] 保持展开时点击面板其他区域（如主题搜索框、字号按钮、光标样式区）：下拉收起。
- [ ] 展开 UI 字体下拉后点击终端字体下拉头部：UI 下拉关闭，终端下拉展开。
- [ ] 切换 tab 或关闭设置面板后重新打开：下拉默认关闭。
