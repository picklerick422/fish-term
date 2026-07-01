# 字体选择功能设计

**日期**: 2026-06-30
**状态**: 已确认

## 目标

在设置 → 外观页面增加字体选择功能，用户可以切换 UI 字体和终端等宽字体。UI 使用 Claude 风格的开源替代字体（Source Serif 4 / Inter），终端使用现代等宽字体（JetBrains Mono）。

## 字体清单

| 用途 | 字体名 | 文件 | 类型 |
|------|--------|------|------|
| UI 标题/正文 | Source Serif 4 | SourceSerif4-Regular.ttf | 衬线 (Claude Serif 替代) |
| UI 组件 | Inter | Inter-Regular.ttf | 无衬线 (Claude Sans 替代) |
| 终端 | JetBrains Mono | JetBrainsMono-Regular.ttf | 等宽 |
| 终端默认 | Noto Sans Mono | /system/fonts (系统内置) | 等宽 |
| 终端符号 | Nerd Font Symbols | SymbolsNerdFontMono-Regular.ttf (已有) | 符号 |

## 架构

```
┌─ 字体文件 (rawfile/fonts/) ─────────────────────────────┐
│  SourceSerif4-Regular.ttf, Inter-Regular.ttf             │
│  JetBrainsMono-Regular.ttf                               │
│  SymbolsNerdFontMono-Regular.ttf (已有)                   │
└──────────────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
  ArkUI font.registerFont()    native OH_Drawing_RegisterFont()
  → Text.fontFamily()           → renderer m_primaryFontFamily
  (UI 文本设置面板等)             (终端文字渲染)
```

**终端字体 fallback 链**: [选定字体, Nerd Symbols, monospace, sans-serif]

## 改动文件清单

| # | 文件 | 改动 |
|---|------|------|
| 1 | `libghostty_ohos/src/main/resources/rawfile/fonts/` | 放入 3 个 .ttf |
| 2 | `renderer/native_drawing_renderer.h` | 新增 `setFontFamily()`，终端字体名列表 |
| 3 | `renderer/native_drawing_renderer.cpp` | 启动时注册所有终端字体；`setFontFamily()` 切换 |
| 4 | `napi_init.cpp` | `SetConfig` 增加 `fontFamily` 参数；NAPI 绑定 |
| 5 | `TerminalTypes.ets` | `TerminalConfig`/`TerminalConfigPatch` 增加 `fontFamily` |
| 6 | `TerminalController.ets` | `updateConfig` 增加 `fontFamily` |
| 7 | `theme/FontScale.ets` | 新增字体选项常量（名称 + 显示名） |
| 8 | `store/ConnectionStore.ets` | 新增 `loadFontFamily()` / `saveFontFamily()` |
| 9 | `pages/SettingsPanel.ets` | 外观 tab 增加字体选择器 UI（分组：UI 字体 / 终端字体） |
| 10 | `pages/Index.ets` | 增加 `uiFontFamily` / `termFontFamily` 状态，加载/保存/广播 |

## 数据流

### 终端字体
```
用户选择字体
  → SettingsPanel.onFontFamilyChange(name)
  → Index.fontFamily = name
  → store.saveFontFamily(name)
  → controller.updateConfig({ fontFamily: name })
  → napi_init SetConfig(fontSize, ..., fontFamily)
  → renderer.setFontFamily(name)
  → 重新计算 cell dimensions → resize → 重新渲染
```

### UI 字体
```
应用启动
  → font.registerFont() 注册 bundled 字体
  → Index.uiFontFamily 加载偏好
  → 全局 fontFamily(uiFontFamily) 应用到 Text 组件
```

## 持久化

- Key: `font_family_ui` / `font_family_term`（在现有 preferences store `fish_conn` 中）
- 默认值: UI = 'Inter', 终端 = ''（空表示使用系统默认 NotoSansMono）

## Native 字体注册策略

启动时一次性注册所有终端字体到共享 font collection:

```cpp
struct TerminalFontOption {
    const char* familyName;   // 用于 OH_Drawing_RegisterFont 的名称
    const char* filePath;     // 字体文件路径
};

// 注册顺序就是优先级顺序
TerminalFontOption fonts[] = {
    {"JetBrains Mono",       "<filesDir>/fonts/JetBrainsMono-Regular.ttf"},
    {"Noto Sans Mono",       "/system/fonts/NotoSansMono[wdth,wght].ttf"},
};
```

运行时切换只改 `m_primaryFontFamily` 字符串并调用 `updateCellDimensions()`，无需重新注册。

## UI 设计

在设置 → 外观选项卡中，字号下方新增"字体"section：

```
  字体
  ┌─────────────────────────────────────────┐
  │ UI 字体                                 │
  │ ○ Inter          (无衬线，简洁现代)      │
  │ ○ Source Serif 4 (衬线，Claude 风格)    │
  │                                         │
  │ 终端字体                                │
  │ ○ 系统默认        (Noto Sans Mono)      │
  │ ○ JetBrains Mono  (现代等宽)            │
  └─────────────────────────────────────────┘
```

每个选项显示：radio 选中态 + 字体名 + 简短描述，用该字体渲染字体名作为即时预览。

## 字体文件获取

字体文件需用户自行下载放入 `libghostty_ohos/src/main/resources/rawfile/fonts/`：
- [JetBrains Mono](https://www.jetbrains.com/lp/mono/) — SIL Open Font License
- [Source Serif 4](https://github.com/adobe-fonts/source-serif) — SIL Open Font License
- [Inter](https://github.com/rsms/inter) — SIL Open Font License
