# 字体选择功能增强设计

**日期**: 2026-06-30  
**状态**: 待审阅  
**依赖**: `docs/superpowers/specs/2026-06-30-font-selection-design.md`（基础字体功能）

## 目标

1. 将 `docs/` 下已下载的两个 Claude 字体实装到字体选择选项中。
2. 优化设置面板的自定义下拉选择栏：
   - 使用更贴近 HarmonyOS 原生的弹簧动画（`curves.springMotion()`）。
   - 选中选项后**不自动收起**。
   - 点击选择栏外部区域才收起。

## 字体清单

| 字体文件（来源） | 注册名 | 目标选择器 | 显示标签 |
|------------------|--------|------------|----------|
| `docs/claude sans regular.ttf` | `Claude Sans` | UI 字体 | `Claude Sans` |
| `docs/claude-sans-let-plain10.ttf` | `Claude Sans LET Plain10` | 终端字体 | `Claude Sans LET Plain10` |

文件将复制并重命名为无空格形式，放入 `entry/src/main/resources/rawfile/fonts/`。

## 改动文件清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `entry/src/main/resources/rawfile/fonts/ClaudeSans-Regular.ttf` | 新增资源 |
| 2 | `entry/src/main/resources/rawfile/fonts/ClaudeSans-LET-Plain10.ttf` | 新增资源 |
| 3 | `entry/src/main/ets/pages/Index.ets` | 在 `aboutToAppear()` 中 `registerFont()` 注册两个新字体 |
| 4 | `entry/src/main/ets/theme/FontScale.ets` | `UI_FONT_OPTIONS` 增加 `Claude Sans`；`TERM_FONT_OPTIONS` 增加 `Claude Sans LET Plain10` |
| 5 | `entry/src/main/ets/pages/SettingsPanel.ets` | 重构两个字体下拉：springMotion 动画、点击选项不关闭、外部点击关闭 |

## 下拉交互设计

### 动画

- 展开：透明度 0→1 + 垂直平移 `-8vp`→`0` + 垂直缩放 `0`→`1`，使用 `curves.springMotion()`。
- 收起：透明度 1→0 + 垂直平移 `0`→`-4vp`，使用较短的 `springMotion()`。
- 头部箭头旋转、边框颜色高亮保持现有逻辑，但动画曲线也改为 `springMotion()`。

### 状态控制

- 保留 `@State uiFontDropdownOpen` 与 `@State termFontDropdownOpen`。
- 点击头部行：切换自身下拉状态，并关闭另一个下拉。
- 点击选项：仅更新 `uiFontFamily` / `termFontFamily` 并回调外部，**不修改下拉开关状态**。
- 外部点击：在 `SettingsPanel.build()` 的根层级 `Column` 添加 `onClick` 处理器，当任意下拉展开时，点击面板空白区域即将两个下拉同时关闭。

### 布局与事件隔离

在 `SettingsPanel.build()` 的根层级 `Column` 添加 `onClick`：

```
Column() {
  // 现有设置面板内容
  // ...
}
.width('100%')
.height('100%')
.onClick(() => {
  if (this.uiFontDropdownOpen || this.termFontDropdownOpen) {
    this.uiFontDropdownOpen = false;
    this.termFontDropdownOpen = false;
  }
})
```

为避免下拉区域内的点击误触发根容器关闭，给下拉整体容器（包含头部行和展开列表的 `Column`）绑定 `.onClick(() => {})`，利用 ArkUI 点击事件默认不冒泡的特性消费掉事件。选项行仍保留自己的 `onClick`，仅负责切换字体并回调外部。

## 数据流

```
用户点击选项
  → SettingsPanel.onXxxFontFamilyChange(family)
  → Index.applyUIFontFamily / applyTermFontFamily
  → store.saveFontFamily(family)
  → controller.updateConfig({ fontFamily: family }) （仅终端）
```

## 回退与边界

- 字体注册失败时静默回退： ArkUI 的 `fontFamily()` 会自动使用系统默认字体。
- 如果用户偏好保存的字体名不在新选项列表中，仍保留原值，下拉会显示“系统默认”。
- 两个下拉同时只能展开一个；打开另一个时自动关闭当前。

## 待验证

- [ ] 新字体在真机/模拟器上渲染正常。
- [ ] 下拉展开/收起动画流畅。
- [ ] 点击选项后下拉保持展开。
- [ ] 点击面板其他区域下拉收起。
- [ ] 切换 tab 或关闭设置面板时状态正确重置。
