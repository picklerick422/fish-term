# 设置页字体部分重构实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重构设置页字体部分：两个字体选择器并排、覆盖式下拉、Claude Sans 缩放参数可编辑、异常提示

**Architecture:** 自底向上修改 — 先在数据层（常量、类型、持久化）增加字段，再改 native 层支持可配置参数，最后改 UI 层布局。每条参数走完整链路 ArkTS → NAPI → C++ Renderer。

**Tech Stack:** ArkTS (ArkUI), C++ (NAPI / Native Drawing)

---

### Task 1: FontScale.ets — 新增缩放字体参数常量

**Files:**
- Modify: `entry/src/main/ets/theme/FontScale.ets`

- [ ] **Step 1: 在文件末尾追加缩放字体参数常量**

在 `TERM_FONT_OPTIONS` 定义之后追加：

```ets
// Scale-font tuning parameters, only applicable when the terminal font is Claude Sans.
export const DEFAULT_FONT_SCALE_BOOST: number = 1.20;
export const MIN_FONT_SCALE_BOOST: number = 1.00;
export const MAX_FONT_SCALE_BOOST: number = 2.00;
export const FONT_SCALE_BOOST_STEP: number = 0.05;

export const DEFAULT_CJK_VERTICAL_OFFSET: number = -2.0;
export const MIN_CJK_VERTICAL_OFFSET: number = -10.0;
export const MAX_CJK_VERTICAL_OFFSET: number = 10.0;
export const CJK_VERTICAL_OFFSET_STEP: number = 0.5;

export const DEFAULT_CHARACTER_SPACING: number = 1.5;
export const MIN_CHARACTER_SPACING: number = 0.0;
export const MAX_CHARACTER_SPACING: number = 5.0;
export const CHARACTER_SPACING_STEP: number = 0.5;

// The only terminal font that uses scale-font rendering.
export function isScaledFont(family: string): boolean {
  return family === 'Claude Sans';
}

export function clampFontScaleBoost(n: number): number {
  if (!Number.isFinite(n)) { return DEFAULT_FONT_SCALE_BOOST; }
  const steps = Math.round(n / FONT_SCALE_BOOST_STEP);
  const r = steps * FONT_SCALE_BOOST_STEP;
  return Math.max(MIN_FONT_SCALE_BOOST, Math.min(MAX_FONT_SCALE_BOOST, parseFloat(r.toFixed(2))));
}

export function clampCjkVerticalOffset(n: number): number {
  if (!Number.isFinite(n)) { return DEFAULT_CJK_VERTICAL_OFFSET; }
  const steps = Math.round(n / CJK_VERTICAL_OFFSET_STEP);
  const r = steps * CJK_VERTICAL_OFFSET_STEP;
  return Math.max(MIN_CJK_VERTICAL_OFFSET, Math.min(MAX_CJK_VERTICAL_OFFSET, parseFloat(r.toFixed(1))));
}

export function clampCharacterSpacing(n: number): number {
  if (!Number.isFinite(n)) { return DEFAULT_CHARACTER_SPACING; }
  const steps = Math.round(n / CHARACTER_SPACING_STEP);
  const r = steps * CHARACTER_SPACING_STEP;
  return Math.max(MIN_CHARACTER_SPACING, Math.min(MAX_CHARACTER_SPACING, parseFloat(r.toFixed(1))));
}
```

同时更新 SettingsPanel.ets 的 import：

```ets
import {
  ...
  DEFAULT_FONT_SCALE_BOOST, MIN_FONT_SCALE_BOOST, MAX_FONT_SCALE_BOOST, FONT_SCALE_BOOST_STEP,
  DEFAULT_CJK_VERTICAL_OFFSET, MIN_CJK_VERTICAL_OFFSET, MAX_CJK_VERTICAL_OFFSET, CJK_VERTICAL_OFFSET_STEP,
  DEFAULT_CHARACTER_SPACING, MIN_CHARACTER_SPACING, MAX_CHARACTER_SPACING, CHARACTER_SPACING_STEP,
  isScaledFont,
  clampFontScaleBoost, clampCjkVerticalOffset, clampCharacterSpacing,
} from '../theme/FontScale';
```

- [ ] **Step 2: 验证语法**

无独立测试，依赖后续集成。

---

### Task 2: TerminalTypes.ets — TerminalConfig 增加 3 个字段

**Files:**
- Modify: `libghostty_ohos/src/main/ets/TerminalTypes.ets`

- [ ] **Step 1: 在 TerminalConfig 接口中增加字段**

```ets
export interface TerminalConfig {
  fontSize: number;
  fontFamily: string;
  lineSpacing: number;
  scrollbackLines: number;
  bgColor: number;
  fgColor: number;
  cursorStyle: number;
  cursorBlink: boolean;
  fontScaleBoost: number;       // 新增
  cjkVerticalOffset: number;    // 新增
  characterSpacing: number;     // 新增
}
```

- [ ] **Step 2: 在 TerminalConfigPatch 接口中增加可选字段**

```ets
export interface TerminalConfigPatch {
  fontSize?: number;
  fontFamily?: string;
  lineSpacing?: number;
  scrollbackLines?: number;
  bgColor?: number;
  fgColor?: number;
  cursorStyle?: number;
  cursorBlink?: boolean;
  fontScaleBoost?: number;       // 新增
  cjkVerticalOffset?: number;    // 新增
  characterSpacing?: number;     // 新增
}
```

- [ ] **Step 3: 更新 DEFAULT_TERMINAL_CONFIG**

```ets
export const DEFAULT_TERMINAL_CONFIG: TerminalConfig = {
  fontSize: 14,
  fontFamily: '',
  lineSpacing: 1.05,
  scrollbackLines: 10000,
  bgColor: 0xFF1A1A1A,
  fgColor: 0xFFD0D6F0,
  cursorStyle: 0,
  cursorBlink: true,
  fontScaleBoost: 1.20,
  cjkVerticalOffset: -2.0,
  characterSpacing: 1.5
};
```

- [ ] **Step 4: 更新 cloneTerminalConfig**

```ets
export function cloneTerminalConfig(config: TerminalConfig): TerminalConfig {
  return {
    fontSize: config.fontSize,
    fontFamily: config.fontFamily,
    lineSpacing: config.lineSpacing,
    scrollbackLines: config.scrollbackLines,
    bgColor: config.bgColor,
    fgColor: config.fgColor,
    cursorStyle: config.cursorStyle,
    cursorBlink: config.cursorBlink,
    fontScaleBoost: config.fontScaleBoost,
    cjkVerticalOffset: config.cjkVerticalOffset,
    characterSpacing: config.characterSpacing
  };
}
```

---

### Task 3: TerminalController.ets — updateConfig 传递新字段

**Files:**
- Modify: `libghostty_ohos/src/main/ets/TerminalController.ets`

- [ ] **Step 1: 在 updateConfig 方法中增加 3 个字段的处理**

在 `updateConfig` 方法中，在 `cursorBlink` 处理之后添加：

```ets
    if (patch.fontScaleBoost !== undefined) {
      nextConfig.fontScaleBoost = patch.fontScaleBoost;
    }
    if (patch.cjkVerticalOffset !== undefined) {
      nextConfig.cjkVerticalOffset = patch.cjkVerticalOffset;
    }
    if (patch.characterSpacing !== undefined) {
      nextConfig.characterSpacing = patch.characterSpacing;
    }
```

---

### Task 4: renderer.h — 增加成员变量和 setter

**Files:**
- Modify: `libghostty_ohos/src/main/cpp/renderer/renderer.h`

- [ ] **Step 1: 增加 protected 成员变量**

在 `m_primaryFontFamily` 之后添加：

```cpp
    float m_fontScaleBoost = 1.20f;
    float m_cjkVerticalOffset = -2.0f;
    float m_characterSpacing = 1.5f;
```

- [ ] **Step 2: 增加 public setter 方法**

在 `setFontFamily` 之后添加：

```cpp
    void setFontScaleBoost(float boost) {
        m_fontScaleBoost = boost > 0.0f ? boost : 1.20f;
        clearGlyphCache();
        updateCellDimensions();
    }

    void setCjkVerticalOffset(float offset) {
        m_cjkVerticalOffset = offset;
    }

    void setCharacterSpacing(float spacing) {
        m_characterSpacing = spacing >= 0.0f ? spacing : 1.5f;
        clearGlyphCache();
        updateCellDimensions();
    }
```

同时需要让 `m_fontScaleBoost`、`m_cjkVerticalOffset`、`m_characterSpacing` 对子类可见（已经是 protected）：

需要将 setter 声明为 public，并确保 `clearGlyphCache()` 和 `updateCellDimensions()` 可被子类访问。`clearGlyphCache()` 已经是 public pure virtual，`updateCellDimensions()` 已经是 protected virtual。

---

### Task 5: native_drawing_renderer.cpp — 用成员变量替换硬编码

**Files:**
- Modify: `libghostty_ohos/src/main/cpp/renderer/native_drawing_renderer.cpp`

- [ ] **Step 1: 修改 effectiveFontSize()**

将 L693-701：
```cpp
float NativeDrawingRenderer::effectiveFontSize() const
{
    // Claude Sans has a relatively small visual size; give it a gentle boost
    // so English text does not look tiny next to CJK glyphs or other fonts.
    if (m_primaryFontFamily.find("Claude Sans") != std::string::npos) {
        return m_fontSize * 1.20f;
    }
    return m_fontSize;
}
```

改为：
```cpp
float NativeDrawingRenderer::effectiveFontSize() const
{
    // Claude Sans has a relatively small visual size; give it a gentle boost
    // so English text does not look tiny next to CJK glyphs or other fonts.
    if (m_primaryFontFamily.find("Claude Sans") != std::string::npos) {
        return m_fontSize * m_fontScaleBoost;
    }
    return m_fontSize;
}
```

- [ ] **Step 2: 修改 CJK 垂直偏移**

将 L585-588：
```cpp
                const float cjkNudge = (isClaudeSans && isCJKCodepoint(cell.codepoint))
                    ? -2.0f * m_density
                    : 0.0f;
```

改为：
```cpp
                const float cjkNudge = (isClaudeSans && isCJKCodepoint(cell.codepoint))
                    ? m_cjkVerticalOffset * m_density
                    : 0.0f;
```

- [ ] **Step 3: 修改字间距**

将 L794-796：
```cpp
                    // proportional glyphs so the terminal grid does not feel
                    // cramped; leave wide (CJK) glyphs at their natural width.
                    const float extra = (span == 1) ? 1.5f : 0.0f;
```

改为：
```cpp
                    // proportional glyphs so the terminal grid does not feel
                    // cramped; leave wide (CJK) glyphs at their natural width.
                    const float extra = (span == 1) ? m_characterSpacing : 0.0f;
```

---

### Task 6: napi_init.cpp — SetConfig 传递新参数

**Files:**
- Modify: `libghostty_ohos/src/main/cpp/napi_init.cpp`

- [ ] **Step 1: 修改 SetConfig 方法签名，增加 3 个参数**

将 L1635-1636：
```cpp
    void SetConfig(int fontSize, float lineSpacing, int scrollbackLines, uint32_t bgColor, uint32_t fgColor,
                   int cursorStyle, bool cursorBlink, const std::string& fontFamily) {
```

改为：
```cpp
    void SetConfig(int fontSize, float lineSpacing, int scrollbackLines, uint32_t bgColor, uint32_t fgColor,
                   int cursorStyle, bool cursorBlink, const std::string& fontFamily,
                   float fontScaleBoost, float cjkVerticalOffset, float characterSpacing) {
```

- [ ] **Step 2: 在 SetConfig 方法体中调用新 setter**

在 `m_renderer->setFontFamily(m_fontFamily);` 之后（L1643 之后）添加：

```cpp
            m_renderer->setFontScaleBoost(fontScaleBoost);
            m_renderer->setCjkVerticalOffset(cjkVerticalOffset);
            m_renderer->setCharacterSpacing(characterSpacing);
```

- [ ] **Step 3: 修改 NAPI SetConfig 函数解析新参数**

在 NAPI `SetConfig` 函数中（L3400 行附近），将：
```cpp
    host->SetConfig(fontSize, static_cast<float>(lineSpacing), scrollbackLines, bgColor, fgColor, cursorStyle, cursorBlink, fontFamily);
```

替换为首先解析 3 个新字段，然后传递：

在 `fontFamily` 解析之后（L3398 行后），添加解析代码：
```cpp
    double fontScaleBoost = 1.20;
    double cjkVerticalOffset = -2.0;
    double characterSpacing = 1.5;
    napi_value fontScaleBoostVal, cjkVerticalOffsetVal, characterSpacingVal;
    napi_get_named_property(env, args[0], "fontScaleBoost", &fontScaleBoostVal);
    napi_get_named_property(env, args[0], "cjkVerticalOffset", &cjkVerticalOffsetVal);
    napi_get_named_property(env, args[0], "characterSpacing", &characterSpacingVal);
    napi_get_value_double(env, fontScaleBoostVal, &fontScaleBoost);
    napi_get_value_double(env, cjkVerticalOffsetVal, &cjkVerticalOffset);
    napi_get_value_double(env, characterSpacingVal, &characterSpacing);
```

然后将调用改为：
```cpp
    host->SetConfig(fontSize, static_cast<float>(lineSpacing), scrollbackLines, bgColor, fgColor, cursorStyle, cursorBlink, fontFamily,
                    static_cast<float>(fontScaleBoost), static_cast<float>(cjkVerticalOffset), static_cast<float>(characterSpacing));
```

---

### Task 7: ConnectionStore.ets — 持久化新字段

**Files:**
- Modify: `entry/src/main/ets/store/ConnectionStore.ets`

- [ ] **Step 1: 添加 preferences key 常量**

在现有 key 常量后添加：
```ets
const KEY_FONT_SCALE_BOOST: string = 'font_scale_boost';
const KEY_CJK_VERTICAL_OFFSET: string = 'cjk_vertical_offset';
const KEY_CHARACTER_SPACING: string = 'character_spacing';
```

- [ ] **Step 2: 添加 load 和 save 方法**

在文件末尾 `}` 之前添加 3 组方法：

```ets
  async loadFontScaleBoost(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_FONT_SCALE_BOOST, fallback) as number;
    } catch (e) {
      console.error('fish-term load fontScaleBoost failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveFontScaleBoost(value: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_FONT_SCALE_BOOST, value);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save fontScaleBoost failed: ' + JSON.stringify(e));
    }
  }

  async loadCjkVerticalOffset(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_CJK_VERTICAL_OFFSET, fallback) as number;
    } catch (e) {
      console.error('fish-term load cjkVerticalOffset failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveCjkVerticalOffset(value: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_CJK_VERTICAL_OFFSET, value);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save cjkVerticalOffset failed: ' + JSON.stringify(e));
    }
  }

  async loadCharacterSpacing(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_CHARACTER_SPACING, fallback) as number;
    } catch (e) {
      console.error('fish-term load characterSpacing failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveCharacterSpacing(value: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_CHARACTER_SPACING, value);
      await pref.flush();
    } catch (e) {
      console.error('fish-term save characterSpacing failed: ' + JSON.stringify(e));
    }
  }
```

---

### Task 8: Index.ets — 新增状态变量 + apply 方法 + broadcast 扩展

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`

- [ ] **Step 1: 添加 import**

在文件顶部 import 中添加：
```ets
import {
  DEFAULT_FONT_SCALE_BOOST, DEFAULT_CJK_VERTICAL_OFFSET, DEFAULT_CHARACTER_SPACING,
  clampFontScaleBoost, clampCjkVerticalOffset, clampCharacterSpacing
} from '../theme/FontScale';
```

- [ ] **Step 2: 添加 @State 变量**

在现有 `@State scrollbackLines: number = 20000;` 之后添加：
```ets
  @State fontScaleBoost: number = DEFAULT_FONT_SCALE_BOOST;
  @State cjkVerticalOffset: number = DEFAULT_CJK_VERTICAL_OFFSET;
  @State characterSpacing: number = DEFAULT_CHARACTER_SPACING;
```

- [ ] **Step 3: 加载持久化值**

在 `aboutToAppear` 中加载字体缩放参数（在现有字体加载代码后添加）。找到 `aboutToAppear` 中加载 store 的地方，在 `this.store.loadFontFamily(...)` 调用附近追加：

```ets
          this.store.loadFontScaleBoost(DEFAULT_FONT_SCALE_BOOST).then((v: number) => {
            this.fontScaleBoost = v;
          });
          this.store.loadCjkVerticalOffset(DEFAULT_CJK_VERTICAL_OFFSET).then((v: number) => {
            this.cjkVerticalOffset = v;
          });
          this.store.loadCharacterSpacing(DEFAULT_CHARACTER_SPACING).then((v: number) => {
            this.characterSpacing = v;
          });
```

- [ ] **Step 4: 添加 apply 方法**

在 `applyTermFontFamily` 方法之后添加：
```ets
  private applyFontScaleBoost(value: number): void {
    this.fontScaleBoost = clampFontScaleBoost(value);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveFontScaleBoost(this.fontScaleBoost);
    }
  }

  private applyCjkVerticalOffset(value: number): void {
    this.cjkVerticalOffset = clampCjkVerticalOffset(value);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveCjkVerticalOffset(this.cjkVerticalOffset);
    }
  }

  private applyCharacterSpacing(value: number): void {
    this.characterSpacing = clampCharacterSpacing(value);
    this.broadcastConfig();
    if (this.store) {
      this.store.saveCharacterSpacing(this.characterSpacing);
    }
  }
```

- [ ] **Step 5: 扩展 broadcastConfig 和 applySettingsTo**

在 `broadcastConfig` 的 `updateConfig` 调用中增加：
```ets
        fontScaleBoost: this.fontScaleBoost,
        cjkVerticalOffset: this.cjkVerticalOffset,
        characterSpacing: this.characterSpacing,
```

同样修改 `applySettingsTo` 方法中的 `updateConfig` 调用。

- [ ] **Step 6: 传递回调到 SettingsPanel**

在 `buildSettingsSheet` 中 SettingsPanel 的属性列表里，增加：
```ets
      fontScaleBoost: this.fontScaleBoost,
      cjkVerticalOffset: this.cjkVerticalOffset,
      characterSpacing: this.characterSpacing,
      onFontScaleBoostChange: (v: number) => { this.applyFontScaleBoost(v); },
      onCjkVerticalOffsetChange: (v: number) => { this.applyCjkVerticalOffset(v); },
      onCharacterSpacingChange: (v: number) => { this.applyCharacterSpacing(v); },
```

---

### Task 9: SettingsPanel.ets — UI 重构

**Files:**
- Modify: `entry/src/main/ets/pages/SettingsPanel.ets`

这是最大的改动。分为 4 个子步骤：

- [ ] **Step 1: 更新 import 和 Props**

在 import 中添加新的常量导入（已在 Task 1 覆盖）。

在 `@Prop` 声明区域添加新属性（在 `termFontFamily` 之后）：
```ets
  @Prop fontScaleBoost: number = DEFAULT_FONT_SCALE_BOOST;
  @Prop cjkVerticalOffset: number = DEFAULT_CJK_VERTICAL_OFFSET;
  @Prop characterSpacing: number = DEFAULT_CHARACTER_SPACING;
  onFontScaleBoostChange: (v: number) => void = (_v: number) => {};
  onCjkVerticalOffsetChange: (v: number) => void = (_v: number) => {};
  onCharacterSpacingChange: (v: number) => void = (_v: number) => {};
```

添加 @State 用于缩放参数 draft：
```ets
  @State private fontScaleBoostDraft: string = this.fontScaleBoost.toFixed(2);
  @State private cjkVerticalOffsetDraft: string = this.cjkVerticalOffset.toFixed(1);
  @State private characterSpacingDraft: string = this.characterSpacing.toFixed(1);
```

添加 sync 方法：
```ets
  private syncScaleParamsDraft(): void {
    this.fontScaleBoostDraft = this.fontScaleBoost.toFixed(2);
    this.cjkVerticalOffsetDraft = this.cjkVerticalOffset.toFixed(1);
    this.characterSpacingDraft = this.characterSpacing.toFixed(1);
  }
```

在 `aboutToAppear` 中调用 `this.syncScaleParamsDraft();`。

- [ ] **Step 2: 重构「字体」section 布局为并排 + 覆盖下拉**

将 L738-931 的 font family section 替换为并排布局。

核心思路：两个字体选择器包裹在一个 `Row({ space: 10 })` 中，每个用 `layoutWeight(1)` 平分宽度。下拉展开使用 Stack + clip(false) + position 覆盖下方内容，不再通过 Stack 高度变化推挤布局。

完整替换代码如下（替换原 L738-931）：

```ets
    // Font family section — two selectors side by side with overlay dropdown
    Column({ space: 8 }) {
      // Section header with conditional warning
      Row({ space: 6 }) {
        Text('字体'.toUpperCase())
          .fontSize(11)
          .fontColor(Palette.textDim)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.uiFontFamily)

        if (isScaledFont(this.termFontFamily)) {
          Row({ space: 3 }) {
            Text('⚠️')
              .fontSize(10)
            Text('比例字体渲染可能偏位')
              .fontSize(10)
              .fontColor('#E8B44F')
          }
          .padding({ left: 6, right: 8, top: 2, bottom: 2 })
          .backgroundColor('#1FE8B44F')
          .borderRadius(4)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // Two selectors side by side
      Row({ space: 10 }) {
        // --- UI font selector ---
        Column({ space: 0 }) {
          Text('UI 字体')
            .fontSize(11)
            .fontFamily(this.uiFontFamily)
            .fontColor(Palette.textDim)
            .width('100%')
            .margin({ bottom: 4 })

          Stack({ alignContent: Alignment.TopStart }) {
            // Collapsed row
            Row() {
              Text(this.fontLabel(this.uiFontFamily, UI_FONT_OPTIONS))
                .fontSize(12)
                .fontColor(Palette.text)
                .fontFamily(this.uiFontFamily.length > 0 ? this.uiFontFamily : 'monospace')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text('▼')
                .fontSize(8)
                .fontColor(Palette.textDim)
                .rotate({ angle: this.uiFontDropdownOpen ? 180 : 0 })
                .animation({ curve: curves.springMotion(0.6, 0.8) })
            }
            .width('100%')
            .height(36)
            .padding({ left: 10, right: 10 })
            .justifyContent(FlexAlign.SpaceBetween)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(Palette.surface)
            .borderRadius(8)
            .border({ width: 1, color: this.uiFontDropdownOpen ? Palette.accent : Palette.border })
            .focusable(false)
            .onClick(() => {
              this.uiFontDropdownOpen = !this.uiFontDropdownOpen;
              if (this.uiFontDropdownOpen) { this.termFontDropdownOpen = false; }
            })

            // Expanded options overlay
            if (this.uiFontDropdownOpen) {
              Column({ space: 2 }) {
                ForEach(UI_FONT_OPTIONS, (opt: FontOption) => {
                  this.fontPickerItem(opt.family, opt.label, true)
                })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ top: 4, left: 4, right: 4, bottom: 4 })
              .backgroundColor(Palette.surface)
              .borderRadius(8)
              .border({ width: 1, color: Palette.accent })
              .shadow({ radius: 12, color: '#40000000', offsetY: 4 })
              .offset({ y: 40 })
            }
          }
          .width('100%')
          .clip(false)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // --- Terminal font selector ---
        Column({ space: 0 }) {
          Text('终端字体')
            .fontSize(11)
            .fontFamily(this.uiFontFamily)
            .fontColor(Palette.textDim)
            .width('100%')
            .margin({ bottom: 4 })

          Stack({ alignContent: Alignment.TopStart }) {
            Row() {
              Text(this.fontLabel(this.termFontFamily, TERM_FONT_OPTIONS))
                .fontSize(12)
                .fontColor(Palette.text)
                .fontFamily(this.termFontFamily.length > 0 ? this.termFontFamily : 'monospace')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text('▼')
                .fontSize(8)
                .fontColor(Palette.textDim)
                .rotate({ angle: this.termFontDropdownOpen ? 180 : 0 })
                .animation({ curve: curves.springMotion(0.6, 0.8) })
            }
            .width('100%')
            .height(36)
            .padding({ left: 10, right: 10 })
            .justifyContent(FlexAlign.SpaceBetween)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(Palette.surface)
            .borderRadius(8)
            .border({ width: 1, color: this.termFontDropdownOpen ? Palette.accent : Palette.border })
            .focusable(false)
            .onClick(() => {
              this.termFontDropdownOpen = !this.termFontDropdownOpen;
              if (this.termFontDropdownOpen) { this.uiFontDropdownOpen = false; }
            })

            if (this.termFontDropdownOpen) {
              Column({ space: 2 }) {
                ForEach(TERM_FONT_OPTIONS, (opt: FontOption) => {
                  this.fontPickerItem(opt.family, opt.label, false)
                })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ top: 4, left: 4, right: 4, bottom: 4 })
              .backgroundColor(Palette.surface)
              .borderRadius(8)
              .border({ width: 1, color: Palette.accent })
              .shadow({ radius: 12, color: '#40000000', offsetY: 4 })
              .offset({ y: 40 })
            }
          }
          .width('100%')
          .clip(false)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // Scale-font parameters panel (only when Claude Sans is selected)
      if (isScaledFont(this.termFontFamily)) {
        Column({ space: 10 }) {
          Text('缩放参数')
            .fontSize(11)
            .fontFamily(this.uiFontFamily)
            .fontColor(Palette.textDim)
            .width('100%')

          // Font scale boost
          Row({ space: 8 }) {
            Text('缩放比例')
              .fontSize(12)
              .fontColor(Palette.text)
              .width(70)
            Slider({
              value: this.fontScaleBoost,
              min: MIN_FONT_SCALE_BOOST,
              max: MAX_FONT_SCALE_BOOST,
              step: FONT_SCALE_BOOST_STEP,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(Palette.accent)
              .trackColor(Palette.border)
              .focusable(false)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.fontScaleBoost = Math.round(value * 100) / 100;
                this.fontScaleBoostDraft = this.fontScaleBoost.toFixed(2);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.onFontScaleBoostChange(this.fontScaleBoost);
                }
              })
            Text(this.fontScaleBoostDraft)
              .fontSize(12)
              .fontColor(Palette.accent)
              .width(40)
              .textAlign(TextAlign.End)
          }
          .width('100%')

          // CJK vertical offset
          Row({ space: 8 }) {
            Text('CJK 上移')
              .fontSize(12)
              .fontColor(Palette.text)
              .width(70)
            Slider({
              value: this.cjkVerticalOffset,
              min: MIN_CJK_VERTICAL_OFFSET,
              max: MAX_CJK_VERTICAL_OFFSET,
              step: CJK_VERTICAL_OFFSET_STEP,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(Palette.accent)
              .trackColor(Palette.border)
              .focusable(false)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.cjkVerticalOffset = Math.round(value * 10) / 10;
                this.cjkVerticalOffsetDraft = this.cjkVerticalOffset.toFixed(1);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.onCjkVerticalOffsetChange(this.cjkVerticalOffset);
                }
              })
            Text(this.cjkVerticalOffsetDraft + ' dp')
              .fontSize(12)
              .fontColor(Palette.accent)
              .width(52)
              .textAlign(TextAlign.End)
          }
          .width('100%')

          // Character spacing
          Row({ space: 8 }) {
            Text('字间距')
              .fontSize(12)
              .fontColor(Palette.text)
              .width(70)
            Slider({
              value: this.characterSpacing,
              min: MIN_CHARACTER_SPACING,
              max: MAX_CHARACTER_SPACING,
              step: CHARACTER_SPACING_STEP,
              style: SliderStyle.OutSet
            })
              .layoutWeight(1)
              .selectedColor(Palette.accent)
              .trackColor(Palette.border)
              .focusable(false)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.characterSpacing = Math.round(value * 10) / 10;
                this.characterSpacingDraft = this.characterSpacing.toFixed(1);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.onCharacterSpacingChange(this.characterSpacing);
                }
              })
            Text(this.characterSpacingDraft + ' dp')
              .fontSize(12)
              .fontColor(Palette.accent)
              .width(52)
              .textAlign(TextAlign.End)
          }
          .width('100%')
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#080F18')
        .borderRadius(10)
        .border({ width: 1, color: Palette.border })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
```

- [ ] **Step 3: 提取 fontPickerItem 复用方法**

在 class 中添加一个私有方法，生成单个字体选项行（被 UI 和终端字体下拉共用）：

```ets
  @Builder
  private fontPickerItem(family: string, label: string, isUI: boolean) {
    Row() {
      // Radio dot
      Row() {
        const selected = isUI ? (this.uiFontFamily === family) : (this.termFontFamily === family);
        if (selected) {
          Row()
            .width(7).height(7).borderRadius(3.5).backgroundColor(Palette.accent)
        }
      }
      .width(16).height(16).borderRadius(8)
      .border({
        width: (isUI ? (this.uiFontFamily === family) : (this.termFontFamily === family)) ? 2 : 1,
        color: (isUI ? (this.uiFontFamily === family) : (this.termFontFamily === family)) ? Palette.accent : Palette.border
      })
      .justifyContent(FlexAlign.Center)

      Text(label)
        .fontSize(13)
        .fontColor((isUI ? (this.uiFontFamily === family) : (this.termFontFamily === family)) ? Palette.accent : Palette.text)
        .fontFamily(family.length > 0 ? family : 'monospace')
        .margin({ left: 8 })
    }
    .width('100%')
    .height(36)
    .padding({ left: 8, right: 8 })
    .borderRadius(6)
    .backgroundColor((isUI ? (this.uiFontFamily === family) : (this.termFontFamily === family)) ? '#15FFFFFF' : Color.Transparent)
    .focusable(false)
    .onClick(() => {
      if (isUI) {
        this.uiFontFamily = family;
        this.onUIFontFamilyChange(family);
        this.uiFontDropdownOpen = false;
      } else {
        this.termFontFamily = family;
        this.onTermFontFamilyChange(family);
        this.termFontDropdownOpen = false;
      }
    })
  }
```

- [ ] **Step 4: 处理下拉互斥和空白区域点击关闭**

现有的 `build()` 方法中已有 onClick 关闭下拉的处理（L275-280），保持不变。但需要将判断扩展到点击缩放参数面板区域时也关闭下拉：

在缩放参数面板的 Column 上添加：
```ets
      .onClick(() => {})
```

另外需要确保点击面板外部时关闭下拉。已有的 `build()` 最外层 Column 的 onClick 已经处理。

---

### Spec Self-Review

**1. Spec coverage:**
- ✅ 并排布局 — Task 9 Step 2
- ✅ 覆盖式下拉 — Task 9 Step 2 (Stack + offset)
- ✅ 缩放参数面板 — Task 9 Step 2 (Slider 区域)
- ✅ 警告提示 — Task 9 Step 2 (section header row)
- ✅ 数据流全链路 — Tasks 1-8

**2. Placeholder scan:** No TBD/TODO/placeholders found.

**3. Type consistency:**
- `fontScaleBoost` / `fontScaleBoost` — consistent across all files ✅
- `cjkVerticalOffset` / `cjkVerticalOffset` — consistent ✅
- `characterSpacing` / `characterSpacing` — consistent ✅
