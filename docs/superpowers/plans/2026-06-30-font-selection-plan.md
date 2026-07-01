# 字体选择功能 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置→外观页面增加字体选择功能，支持切换 UI 字体（Source Serif 4 / Inter）和终端等宽字体（JetBrains Mono / 系统默认）。

**Architecture:** 终端字体通过 native 层 `OH_Drawing_RegisterFont` 在启动时注册所有字体到共享 font collection，运行时切换只改 `m_primaryFontFamily` + 清 glyph cache + 重算 cell dimensions；UI 字体通过 ArkUI `font.registerFont()` 注册，`fontFamily()` 属性应用到全局 Text 组件。

**Tech Stack:** HarmonyOS ArkTS + C++ NAPI (native_drawing, OH_Drawing_RegisterFont)

---

### 前置准备：字体文件

```bash
# 下载开源字体并放入 rawfile/fonts/
libghostty_ohos/src/main/resources/rawfile/fonts/
├── SymbolsNerdFontMono-Regular.ttf  # 已有
├── JetBrainsMono-Regular.ttf        # 新增
├── SourceSerif4-Regular.ttf         # 新增
└── Inter-Regular.ttf                # 新增
```

字体下载链接：
- JetBrains Mono: https://github.com/JetBrains/JetBrainsMono/releases (取 `fonts/ttf/JetBrainsMono-Regular.ttf`)
- Source Serif 4: https://github.com/adobe-fonts/source-serif/releases (取 `OTF/SourceSerif4-Regular.otf`)
- Inter: https://github.com/rsms/inter/releases (取 `Inter-Regular.ttf`)

**注意:** 此步骤为手动前置操作，不在代码任务中。

---

### Task 1: Native 渲染器 — 支持多字体注册与切换

**Files:**
- Modify: `libghostty_ohos/src/main/cpp/renderer/native_drawing_renderer.h:113-115`
- Modify: `libghostty_ohos/src/main/cpp/renderer/native_drawing_renderer.cpp:252-294`
- Modify: `libghostty_ohos/src/main/cpp/renderer/renderer.h:37-39`

- [ ] **Step 1: 在 `renderer.h` 基类添加 `<string>` include、`clearGlyphCache()` 声明和 `setFontFamily()`**

先在文件头部 `#include <cstdint>` 之后添加 `#include <string>`。

然后在 `renderer.h` 第 37 行 `setFontSize` 之后增加：

```cpp
    virtual void clearGlyphCache() = 0;

    virtual void setFontFamily(const std::string& family) {
        m_primaryFontFamily = family;
        clearGlyphCache();
        updateCellDimensions();
    }

    const std::string& getFontFamily() const { return m_primaryFontFamily; }
```

同时在 `protected` 区域（约第 93 行，`m_cursorBlink` 之后）增加：

```cpp
    std::string m_primaryFontFamily = "Noto Sans Mono";
```

原 `native_drawing_renderer.h` 中的 `m_primaryFontFamily` 需要删除，改用基类的。

- [ ] **Step 2: 更新 `native_drawing_renderer.h` — 删除重复成员，更新 `destroyGlyphCache` 为 `clearGlyphCache`**

删除第 113 行：
```cpp
    std::string m_primaryFontFamily = "libghostty Mono";
```

将第 79 行声明：
```cpp
    void destroyGlyphCache();
```
改为：
```cpp
    void clearGlyphCache() override;
```

- [ ] **Step 3: 修改 `loadFontAtlas()` — 注册所有终端字体**

替换 `native_drawing_renderer.cpp` 第 252-294 行整个函数体：

```cpp
bool NativeDrawingRenderer::loadFontAtlas(NativeResourceManager* resourceManager, const std::string& filesDir)
{
    if (!m_fontCollection) {
        return false;
    }
    if (m_fontsConfigured) {
        return true;
    }

    {
        std::lock_guard<std::mutex> lock(g_fontCollectionMutex);
        static bool s_fontsRegistered = false;
        if (!s_fontsRegistered) {
            // 1. JetBrains Mono — bundled as rawfile, extracted to filesDir
            if (resourceManager && !filesDir.empty()) {
                const std::string fontDir = filesDir + "/fonts";
                const std::string jbPath = fontDir + "/JetBrainsMono-Regular.ttf";
                if (EnsureDirectory(fontDir) &&
                    ExtractRawFileToPath(resourceManager, "fonts/JetBrainsMono-Regular.ttf", jbPath)) {
                    uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection, "JetBrains Mono", jbPath.c_str());
                    OH_LOG_INFO(LOG_APP, "Registered JetBrains Mono rc=%u", rc);
                } else {
                    OH_LOG_WARN(LOG_APP, "JetBrains Mono not found in rawfile, skipping");
                }
            }

            // 2. System Noto Sans Mono — always available on HarmonyOS
            const char* sysMonoPath = "/system/fonts/NotoSansMono[wdth,wght].ttf";
            if (access(sysMonoPath, R_OK) == 0) {
                uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection, "Noto Sans Mono", sysMonoPath);
                OH_LOG_INFO(LOG_APP, "Registered Noto Sans Mono rc=%u", rc);
            } else {
                OH_LOG_WARN(LOG_APP, "System mono font unavailable: %{public}s", sysMonoPath);
            }

            // 3. Nerd Font Symbols (already bundled for powerline / nerd glyphs)
            if (resourceManager && !filesDir.empty()) {
                const std::string fontDir = filesDir + "/fonts";
                const std::string symbolFontPath = fontDir + "/SymbolsNerdFontMono-Regular.ttf";
                if (EnsureDirectory(fontDir) &&
                    ExtractRawFileToPath(resourceManager, "fonts/SymbolsNerdFontMono-Regular.ttf", symbolFontPath)) {
                    uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection,
                        m_symbolFontFamily.c_str(), symbolFontPath.c_str());
                    OH_LOG_INFO(LOG_APP, "Registered symbol font rc=%u", rc);
                } else {
                    OH_LOG_WARN(LOG_APP, "Failed to extract bundled symbol font");
                }
            }

            s_fontsRegistered = true;
        }
    }

    if (m_primaryFontFamily.empty()) {
        m_primaryFontFamily = "Noto Sans Mono";
    }

    m_fontsConfigured = true;
    updateCellDimensions();
    return true;
}
```

- [ ] **Step 4: 将 `destroyGlyphCache()` 重命名为 `clearGlyphCache()` 并标记 override**

`native_drawing_renderer.cpp` 第 628 行附近的函数定义：

```cpp
void NativeDrawingRenderer::clearGlyphCache()
{
    for (auto& entry : m_glyphCache) {
        if (entry.second.typography) {
            OH_Drawing_DestroyTypography(entry.second.typography);
        }
    }
    m_glyphCache.clear();
}
```

同时更新同一文件中所有调用处（第 221、575、643 行）：
- `destroyGlyphCache()` → `clearGlyphCache()`

同步更新 `native_drawing_renderer.h` 第 79 行声明：
- `void destroyGlyphCache();` → `void clearGlyphCache() override;`

- [ ] **Step 5: 构建验证**

```bash
cd /mnt/linux_share/DevEcoStudioProjects/fish-term && hvigorw assembleHap --mode module -p module=libghostty_ohos@default -p product=default 2>&1 | tail -30
```

预期：编译通过。

---

### Task 2: Native NAPI — 传递 fontFamily 参数

**Files:**
- Modify: `libghostty_ohos/src/main/cpp/napi_init.cpp:1630-1656` (SetConfig 方法)
- Modify: `libghostty_ohos/src/main/cpp/napi_init.cpp:3336-3372` (NAPI SetConfig 函数)

- [ ] **Step 1: 扩展 `TerminalHost::SetConfig` 签名和实现**

`napi_init.cpp` 第 1630 行，修改方法签名：

```cpp
    void SetConfig(int fontSize, int scrollbackLines, uint32_t bgColor, uint32_t fgColor,
                   int cursorStyle, bool cursorBlink, const std::string& fontFamily) {
        m_fontSize = static_cast<float>(fontSize);

        if (m_renderer) {
            m_renderer->setFontSize(m_fontSize);
            if (!fontFamily.empty()) {
                m_renderer->setFontFamily(fontFamily);
            }
            m_renderer->setColors(bgColor, fgColor);
            m_renderer->setCursorStyle(cursorStyle, cursorBlink);
        }

        if (m_terminal) {
            // ... 其余逻辑不变 ...
```

方法其余部分（第 1639-1655 行）保持不变。

- [ ] **Step 2: 扩展 NAPI `SetConfig` 函数提取 fontFamily**

`napi_init.cpp` 第 3336 行，在现有 `napi_get_named_property` 调用之后（第 3355 行后），提取函数参数之前（第 3357 行前），增加：

```cpp
    napi_value fontFamilyVal;
    napi_get_named_property(env, args[0], "fontFamily", &fontFamilyVal);

    // ...

    std::string fontFamily;
    napi_valuetype familyType;
    if (napi_typeof(env, fontFamilyVal, &familyType) == napi_ok && familyType == napi_string) {
        size_t familyLen = 0;
        napi_get_value_string_utf8(env, fontFamilyVal, nullptr, 0, &familyLen);
        fontFamily.resize(familyLen);
        napi_get_value_string_utf8(env, fontFamilyVal, &fontFamily[0], familyLen + 1, &familyLen);
    }
```

第 3370 行调用修改：
```cpp
    host->SetConfig(fontSize, scrollbackLines, bgColor, fgColor, cursorStyle, cursorBlink, fontFamily);
```

完整代码（替换原第 3355-3370 行范围）：

```cpp
    napi_value cursorBlinkVal;
    napi_value fontFamilyVal;
    napi_get_named_property(env, args[0], "cursorStyle", &cursorStyleVal);
    napi_get_named_property(env, args[0], "cursorBlink", &cursorBlinkVal);
    napi_get_named_property(env, args[0], "fontFamily", &fontFamilyVal);

    int32_t fontSize = 14;
    int32_t scrollbackLines = 10000;
    uint32_t bgColor = 0xFF000000;
    uint32_t fgColor = 0xFFFFFFFF;
    int32_t cursorStyle = 0;
    bool cursorBlink = true;
    std::string fontFamily;

    napi_get_value_int32(env, fontSizeVal, &fontSize);
    napi_get_value_int32(env, scrollbackVal, &scrollbackLines);
    napi_get_value_uint32(env, bgColorVal, &bgColor);
    napi_get_value_uint32(env, fgColorVal, &fgColor);
    napi_get_value_int32(env, cursorStyleVal, &cursorStyle);
    napi_get_value_bool(env, cursorBlinkVal, &cursorBlink);
    {
        napi_valuetype familyType;
        if (napi_typeof(env, fontFamilyVal, &familyType) == napi_ok && familyType == napi_string) {
            size_t familyLen = 0;
            napi_get_value_string_utf8(env, fontFamilyVal, nullptr, 0, &familyLen);
            fontFamily.resize(familyLen);
            napi_get_value_string_utf8(env, fontFamilyVal, &fontFamily[0], familyLen + 1, &familyLen);
        }
    }
    host->SetConfig(fontSize, scrollbackLines, bgColor, fgColor, cursorStyle, cursorBlink, fontFamily);
```

- [ ] **Step 3: 构建验证**

```bash
cd /mnt/linux_share/DevEcoStudioProjects/fish-term && hvigorw assembleHap --mode module -p module=libghostty_ohos@default -p product=default 2>&1 | tail -30
```

预期：编译通过。

---

### Task 3: ArkTS — 更新 TerminalTypes 和 TerminalController

**Files:**
- Modify: `libghostty_ohos/src/main/ets/TerminalTypes.ets:28-66`
- Modify: `libghostty_ohos/src/main/ets/TerminalController.ets:125-148`

- [ ] **Step 1: `TerminalTypes.ets` — 添加 `fontFamily` 字段**

`TerminalConfig` 接口（第 28 行）：
```typescript
export interface TerminalConfig {
  fontSize: number;
  fontFamily: string;
  scrollbackLines: number;
  bgColor: number;
  fgColor: number;
  cursorStyle: number;
  cursorBlink: boolean;
}
```

`TerminalConfigPatch` 接口（第 37 行）：
```typescript
export interface TerminalConfigPatch {
  fontSize?: number;
  fontFamily?: string;
  scrollbackLines?: number;
  bgColor?: number;
  fgColor?: number;
  cursorStyle?: number;
  cursorBlink?: boolean;
}
```

`DEFAULT_TERMINAL_CONFIG` 常量（第 49 行）：
```typescript
export const DEFAULT_TERMINAL_CONFIG: TerminalConfig = {
  fontSize: 14,
  fontFamily: '',
  scrollbackLines: 10000,
  bgColor: 0xFF1A1A1A,
  fgColor: 0xFFD0D6F0,
  cursorStyle: 0,
  cursorBlink: true
};
```

`cloneTerminalConfig` 函数（第 57 行）：
```typescript
export function cloneTerminalConfig(config: TerminalConfig): TerminalConfig {
  return {
    fontSize: config.fontSize,
    fontFamily: config.fontFamily,
    scrollbackLines: config.scrollbackLines,
    bgColor: config.bgColor,
    fgColor: config.fgColor,
    cursorStyle: config.cursorStyle,
    cursorBlink: config.cursorBlink
  };
}
```

- [ ] **Step 2: `TerminalController.ets` — `updateConfig` 增加 fontFamily**

`TerminalController.ets` 第 127 行，在 `fontSize` 处理之后插入：

```typescript
    if (patch.fontFamily !== undefined) {
      nextConfig.fontFamily = patch.fontFamily;
    }
```

插入位置：`patch.fontSize` 处理块之后（第 129 行后），`patch.scrollbackLines` 之前（第 130 行前）。

完整 `updateConfig` 方法（第 125 行起）：

```typescript
  updateConfig(patch: TerminalConfigPatch): void {
    const nextConfig = cloneTerminalConfig(this.config);
    if (patch.fontSize !== undefined) {
      nextConfig.fontSize = patch.fontSize;
    }
    if (patch.fontFamily !== undefined) {
      nextConfig.fontFamily = patch.fontFamily;
    }
    if (patch.scrollbackLines !== undefined) {
      nextConfig.scrollbackLines = patch.scrollbackLines;
    }
    if (patch.bgColor !== undefined) {
      nextConfig.bgColor = patch.bgColor;
    }
    if (patch.fgColor !== undefined) {
      nextConfig.fgColor = patch.fgColor;
    }
    if (patch.cursorStyle !== undefined) {
      nextConfig.cursorStyle = patch.cursorStyle;
    }
    if (patch.cursorBlink !== undefined) {
      nextConfig.cursorBlink = patch.cursorBlink;
    }

    this.setConfig(nextConfig);
  }
```

- [ ] **Step 3: 构建验证**

```bash
cd /mnt/linux_share/DevEcoStudioProjects/fish-term && hvigorw assembleHap --mode module -p module=libghostty_ohos@default -p product=default 2>&1 | tail -20
```

预期：编译通过。

---

### Task 4: ArkTS — 添加字体常量定义

**Files:**
- Modify: `entry/src/main/ets/theme/FontScale.ets`

- [ ] **Step 1: 在 `FontScale.ets` 追加字体选项常量**

在文件末尾追加：

```typescript
// Font family options for the settings picker.
export interface FontOption {
  family: string;   // CSS font-family name used in ArkUI / native
  label: string;    // human-readable label in the picker
  category: 'ui' | 'terminal';
}

export const DEFAULT_UI_FONT: string = 'Inter';
export const DEFAULT_TERM_FONT: string = '';  // '' = system default (Noto Sans Mono)

export const UI_FONT_OPTIONS: FontOption[] = [
  { family: 'Inter', label: 'Inter', category: 'ui' },
  { family: 'Source Serif 4', label: 'Source Serif 4', category: 'ui' },
];

export const TERM_FONT_OPTIONS: FontOption[] = [
  { family: '', label: '系统默认', category: 'terminal' },
  { family: 'JetBrains Mono', label: 'JetBrains Mono', category: 'terminal' },
];
```

---

### Task 5: ArkTS — 持久化字体偏好

**Files:**
- Modify: `entry/src/main/ets/store/ConnectionStore.ets`

- [ ] **Step 1: 添加存储 key 常量**

在第 23 行（`KEY_ONBOARDED` 之后）添加：

```typescript
const KEY_FONT_FAMILY_UI: string = 'font_family_ui';
const KEY_FONT_FAMILY_TERM: string = 'font_family_term';
```

- [ ] **Step 2: 添加 `loadFontFamily` / `saveFontFamily` 方法**

在 `saveOnboarded` 方法后（第 203 行后）追加：

```typescript
  async loadFontFamily(fallback: string, isUI: boolean): Promise<string> {
    const key = isUI ? KEY_FONT_FAMILY_UI : KEY_FONT_FAMILY_TERM;
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(key, fallback) as string;
    } catch (e) {
      console.error('fish-term load fontFamily failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveFontFamily(family: string, isUI: boolean): Promise<void> {
    const key = isUI ? KEY_FONT_FAMILY_UI : KEY_FONT_FAMILY_TERM;
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(key, family);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save fontFamily failed: ' + JSON.stringify(e));
    }
  }
```

---

### Task 6: ArkTS — SettingsPanel 字体选择器 UI

**Files:**
- Modify: `entry/src/main/ets/pages/SettingsPanel.ets`

- [ ] **Step 1: 导入字体常量**

修改第 4 行 import：

```typescript
import { MIN_FONT_SIZE, MAX_FONT_SIZE, FontOption, UI_FONT_OPTIONS, TERM_FONT_OPTIONS } from '../theme/FontScale';
```

- [ ] **Step 2: 添加 Props 和回调**

在 SettingsPanel 的结构体中（约第 61 行 `onFontSizeChange` 之后），新增：

```typescript
  @Prop uiFontFamily: string = 'Inter';
  @Prop termFontFamily: string = '';
  onUIFontFamilyChange: (family: string) => void = (_family: string) => {};
  onTermFontFamilyChange: (family: string) => void = (_family: string) => {};
```

- [ ] **Step 3: 添加字体选择 Builder 和选项渲染**

在 `buildAppearanceTab()` Builder 中（字号 section 之后，约第 518 行），新增字体 section：

在字号 Column 的 `}` 结束和主题 section 的 `Column({ space: 0 })` 开始之间（约第 518 行）插入：

```typescript
    // Font family section
    Column({ space: 0 }) {
      this.buildSectionHeader('字体')

      // UI font options
      Column({ space: 6 }) {
        Text('UI 字体')
          .fontSize(11)
          .fontColor(Palette.textDim)
          .width('100%')
        ForEach(UI_FONT_OPTIONS, (opt: FontOption) => {
          this.buildFontOption(opt, this.uiFontFamily,
            (family: string) => { this.uiFontFamily = family; this.onUIFontFamilyChange(family); })
        })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ bottom: 12 })

      // Terminal font options
      Column({ space: 6 }) {
        Text('终端字体')
          .fontSize(11)
          .fontColor(Palette.textDim)
          .width('100%')
        ForEach(TERM_FONT_OPTIONS, (opt: FontOption) => {
          this.buildFontOption(opt, this.termFontFamily,
            (family: string) => { this.termFontFamily = family; this.onTermFontFamilyChange(family); })
        })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
```

- [ ] **Step 4: 添加 `buildFontOption` Builder**

在类中添加 Builder 方法（可放在 `buildAppearanceTab` 之后）：

```typescript
  @Builder
  private buildFontOption(opt: FontOption, current: string, onSelect: (family: string) => void) {
    Row({ space: 10 }) {
      // Radio indicator
      Row() {
        if (current === opt.family) {
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(Palette.accent)
        }
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .border({ width: current === opt.family ? 2 : 1, color: current === opt.family ? Palette.accent : Palette.border })
      .justifyContent(FlexAlign.Center)

      // Font name rendered in its own font
      Text(opt.label)
        .fontSize(14)
        .fontColor(Palette.text)
        .fontFamily(opt.family.length > 0 ? opt.family : 'monospace')
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .backgroundColor(Palette.surface)
    .borderRadius(10)
    .border({ width: 1, color: Palette.border })
    .focusable(false)
    .onClick(() => { onSelect(opt.family); })
  }
```

---

### Task 7: ArkTS — Index.ets 集成字体状态

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`

- [ ] **Step 1: 导入字体常量**

修改第 10 行 import：

```typescript
import { DEFAULT_FONT_SIZE, clampFontSize, DEFAULT_UI_FONT, DEFAULT_TERM_FONT } from '../theme/FontScale';
```

- [ ] **Step 2: 添加状态变量**

在 `scrollbackLines` 状态变量之后（约第 80 行后）添加：

```typescript
  @State private uiFontFamily: string = DEFAULT_UI_FONT;
  @State private termFontFamily: string = DEFAULT_TERM_FONT;
```

- [ ] **Step 3: `loadSettings` 中加载字体偏好**

在 `loadSettings` 方法的 `store.loadTerminalPrefs` 块之后（约第 155 行后）添加：

```typescript
    store.loadFontFamily(DEFAULT_UI_FONT, true).then((f: string): void => {
      this.uiFontFamily = f;
    });
    store.loadFontFamily(DEFAULT_TERM_FONT, false).then((f: string): void => {
      this.termFontFamily = f;
      if (f.length > 0) {
        this.broadcastConfig();
      }
    });
```

- [ ] **Step 4: 更新 `broadcastConfig` 包含 fontFamily**

修改 `broadcastConfig` 方法（第 188 行）：

```typescript
  private broadcastConfig(): void {
    this.runtimes.forEach((rt: TerminalRuntime) => {
      rt.controller.updateConfig({
        fontSize: this.fontSize,
        fontFamily: this.termFontFamily,
        scrollbackLines: this.scrollbackLines,
        cursorStyle: this.cursorStyle,
        cursorBlink: this.cursorBlink
      });
    });
  }
```

- [ ] **Step 5: 更新 `applySettingsTo` 包含 fontFamily**

修改 `applySettingsTo` 方法（第 178 行）：

```typescript
  private applySettingsTo(controller: TerminalController): void {
    controller.setTheme(this.themeName);
    controller.updateConfig({
      fontSize: this.fontSize,
      fontFamily: this.termFontFamily,
      scrollbackLines: this.scrollbackLines,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink
    });
  }
```

- [ ] **Step 6: 添加字体切换回调方法**

在 `applyFontSize` 方法之后（约第 528 行后）添加：

```typescript
  private applyUIFontFamily(family: string): void {
    this.uiFontFamily = family;
    if (this.store) {
      this.store.saveFontFamily(family, true);
    }
  }

  private applyTermFontFamily(family: string): void {
    this.termFontFamily = family;
    this.broadcastConfig();
    if (this.store) {
      this.store.saveFontFamily(family, false);
    }
  }
```

- [ ] **Step 7: 更新 SettingsPanel 绑定**

在 `buildSettingsSheet` Builder 中（第 905 行），更新 `SettingsPanel` 构造参数：

```typescript
    SettingsPanel({
      controller: this.activeController(),
      store: this.store,
      fontSize: this.fontSize,
      initialTab: this.settingsInitialTab,
      statusText: this.activeMeta().statusText,
      statusColor: this.dotColor(this.activeMeta().state),
      hostLabel: this.host + ':' + this.port,
      themeName: this.themeName,
      cursorStyle: this.cursorStyle,
      cursorBlink: this.cursorBlink,
      scrollbackLines: this.scrollbackLines,
      uiFontFamily: this.uiFontFamily,
      termFontFamily: this.termFontFamily,
      onThemeChange: (n: string) => { this.themeName = n; this.broadcastTheme(); },
      onCursorStyleChange: (v: number) => { this.cursorStyle = v; this.broadcastConfig(); },
      onCursorBlinkChange: (v: boolean) => { this.cursorBlink = v; this.broadcastConfig(); },
      onScrollbackChange: (v: number) => { this.scrollbackLines = v; this.broadcastConfig(); },
      onFontSizeChange: (s: number) => { this.applyFontSize(s); },
      onUIFontFamilyChange: (f: string) => { this.applyUIFontFamily(f); },
      onTermFontFamilyChange: (f: string) => { this.applyTermFontFamily(f); },
      onReplayGuide: () => { this.showSettings = false; this.guideStep = 0; this.showGuide = true; },
      onClose: () => { this.showSettings = false; }
    })
```

---

### Task 8: 最终构建验证

- [ ] **Step 1: 完整构建**

```bash
cd /mnt/linux_share/DevEcoStudioProjects/fish-term && hvigorw assembleHap --mode module -p product=default 2>&1 | tail -30
```

预期：BUILD SUCCESSFUL，无编译错误。

- [ ] **Step 2: 功能验证清单**

  1. 打开设置 → 外观，验证"字体"section 显示在字号下方
  2. UI 字体有 Inter / Source Serif 4 两个选项，radio 可切换
  3. 终端字体有 系统默认 / JetBrains Mono 两个选项
  4. 切换 UI 字体 → 设置面板自身文字即时变化
  5. 切换终端字体 → 终端文字使用新字体渲染（需要验证 glyphs 重绘正确）
  6. 关闭设置后重新打开 → 字体选择保持
  7. 新建 tab → 新 tab 使用选中的终端字体
  8. 重启应用 → 字体偏好从 preferences 正确加载
