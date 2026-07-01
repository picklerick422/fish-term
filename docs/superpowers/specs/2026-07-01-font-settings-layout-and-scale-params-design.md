# 设置页字体部分重构：并排布局 + 缩放字体参数

## 概述

重构设置页「外观」标签下「字体」部分的排版和功能：
1. UI 字体和终端字体两个选择器从上下堆叠改为同一行并排
2. 当终端字体选择 Claude Sans（比例字体）时，显示缩放参数编辑面板
3. "字体"标题旁增加缩放字体的异常提示

## 现状

### 布局
- UI 字体选择器和终端字体选择器是两个独立的 Column，上下堆叠
- 每个选择器包含标签行 + 折叠下拉行 + Stack 裁剪动画展开的选项列表
- 展开时 Stack 高度变化，推开下方内容

### 缩放字体硬编码参数（native_drawing_renderer.cpp）
| 参数 | 位置 | 硬编码值 | 含义 |
|------|------|----------|------|
| fontScaleBoost | L698 effectiveFontSize() | 1.20f | Claude Sans 渲染字号 = fontSize × boost |
| cjkVerticalOffset | L587 cjkNudge | -2.0f * density | CJK 字符垂直上移像素 |
| characterSpacing | L796 extra | 1.5f | 比例字体单宽字符水平额外间距 |

## 目标设计

### 1. 并排布局

```
┌─ 字体  ⚠️ 比例字体可能偏位 ──────────────────────┐
│                                                    │
│  ┌─ UI 字体 ────────┐  ┌─ 终端字体 ──────────────┐ │
│  │ Inter (无衬线) ▼ │  │ Claude Sans (比例)  ▼  │ │
│  └──────────────────┘  └─────────────────────────┘ │
│                                                    │
│  ┌─ 缩放参数 ────────────────────────────────────┐ │
│  │ 缩放比例   ────●───────────  1.20            │ │
│  │ CJK 上移   ──────●─────────  -2.0 dp         │ │
│  │ 字间距     ────●────────────  1.5 dp         │ │
│  └───────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────┘
```

- UI 字体和终端字体选择器用 Row 包裹，各 `layoutWeight(1)` 平分
- 下拉展开使用 Stack + `.position()` 绝对定位覆盖下方内容
- 缩放参数面板仅当 `termFontFamily === 'Claude Sans'` 时显示

### 2. 下拉覆盖式展开

当前实现用 `Stack.clip(true)` + 高度动画，展开时推开下方内容。改为：
- Stack 高度固定为折叠行高度（40vp）
- 展开的选项列表通过 `.offset()` 或 `.position()` 脱离布局流
- 外层容器 `clip(false)` 允许溢出可见
- 保留原有的 `curves.cubicBezierCurve(0.25, 0.1, 0.25, 1.0)` 擦除动画

### 3. 缩放参数编辑

三个 Slider（OutSet 风格），右侧显示当前数值：

| 参数 | 字段名 | 默认值 | 范围 | 步长 | 
|------|--------|--------|------|------|
| 缩放比例 | fontScaleBoost | 1.20 | 1.00 ~ 2.00 | 0.05 |
| CJK上移 | cjkVerticalOffset | -2.0 | -10.0 ~ 10.0 | 0.5 |
| 字间距 | characterSpacing | 1.5 | 0.0 ~ 5.0 | 0.5 |

### 4. 警告提示

当 `termFontFamily === 'Claude Sans'` 时：
- "字体" 标题右侧显示琥珀色圆角标签
- 文字："⚠️ 比例字体渲染可能偏位"
- 字号 10，透明度 0.85

### 5. 数据流全链路

```
SettingsPanel Slider → callback → Index.ets @State
  → broadcastConfig() → TerminalController.updateConfig({fontScaleBoost, cjkVerticalOffset, characterSpacing})
    → NAPI SetConfig() → Renderer setter → 成员变量替换硬编码
```

持久化：ConnectionStore 新增 3 个 preferences key。

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `entry/.../theme/FontScale.ets` | 新增 3 组常量 + clamp 函数 |
| `libghostty_ohos/.../TerminalTypes.ets` | TerminalConfig / TerminalConfigPatch 增加 3 字段 |
| `entry/.../pages/SettingsPanel.ets` | UI 重构（并排布局 + 覆盖下拉 + 缩放面板 + 警告） |
| `entry/.../pages/Index.ets` | 新增 @State + apply 方法 + broadcast |
| `entry/.../store/ConnectionStore.ets` | 持久化 3 个新字段 |
| `libghostty_ohos/.../renderer/renderer.h` | 增加 m_fontScaleBoost / m_cjkVerticalOffset / m_characterSpacing + setter |
| `libghostty_ohos/.../renderer/native_drawing_renderer.cpp` | effectiveFontSize() / cjkNudge / extra 使用成员变量 |
| `libghostty_ohos/.../napi_init.cpp` | SetConfig 解析并传递新参数 |

## 验收标准

1. UI 字体和终端字体选择器在同一行并排显示
2. 下拉展开时不推挤下方内容（覆盖式）
3. 选择 Claude Sans 后，缩放参数面板出现并可编辑
4. 选择其他终端字体后，缩放参数面板消失
5. "字体"标题旁警告提示仅在 Claude Sans 时显示
6. 参数变更后实时生效到终端渲染
7. 关闭/重开设置后参数保持
