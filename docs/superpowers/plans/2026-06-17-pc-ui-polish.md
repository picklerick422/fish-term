# wand-term PC 界面打磨与体验优化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 wand-term 的连接表单与终端界面重做成"现代开发者工具风(青色 accent)",并在鸿蒙 PC 上加入字号调节(按钮 + 记忆 + 尽力而为的快捷键)。

**Architecture:** 不动传输层与渲染 HAR。新增集中调色板 `theme/Palette.ets` 和纯逻辑字号助手 `theme/FontScale.ets`(可在 node 下 TDD);`ConnectionStore` 增加字号持久化;`pages/Index.ets` 重做表单(居中卡片 + 聚焦反馈 + token 显隐 + Enter 提交)与状态栏(色点 + host:port + A-/字号/A+ + 断开),字号通过 `controller.updateConfig({fontSize})` 实时生效。

**Tech Stack:** ArkTS / ArkUI(stageMode)、`@kit.ArkData` preferences、libghostty_ohos HAR(`TerminalController.updateConfig/getConfig`)、node:test(纯逻辑验证)。

---

## 环境与约定(务必先读)

- **本沙箱无法编译鸿蒙工程**。纯逻辑(字号 clamp/step)用 `tools/verify/` 的 node 测试做 TDD,在本环境跑;UI 与存储改动由用户在 **DevEco + 真机/PC** 验证,验证步骤会写明"观察什么"。
- **HAR 只读不改**:`libghostty_ohos/**` 不动。复制/粘贴已由 HAR 右键菜单提供(Copy / Paste / Copy Screen),本轮不实现。
- **git 未初始化**(FUSE 限制,见 `tools/git-init.sh`)。计划里的 `commit` 步骤为**可选**,git init 后再补;不阻塞实现。
- 终端是 XComponent,获焦时原生接管按键 → `Ctrl+=/-/0` 可能到不了 ArkUI 层。**A-/A+ 按钮是可靠主路径,快捷键为 bonus,DevEco 验证。**
- `TerminalConfigPatch.fontSize` 为可选 number;`controller.getConfig().fontSize` 可读;HAR 默认 14,本 App 默认 **16**。

## 文件结构

- 新建 `entry/src/main/ets/theme/Palette.ets` — 集中调色板常量(唯一颜色来源)。
- 新建 `entry/src/main/ets/theme/FontScale.ets` — 纯函数:字号 clamp/step + 常量。
- 新建 `tools/verify/_fontscale.mjs` — `FontScale.ets` 的 node 等价镜像(无类型)。
- 新建 `tools/verify/fontscale.test.mjs` — 字号逻辑测试。
- 改 `entry/src/main/ets/store/ConnectionStore.ets` — 加 `font_size` 读写。
- 改 `entry/src/main/ets/pages/Index.ets` — 表单卡片化 + 状态栏改版 + 字号控制 + 快捷键 + Enter 提交。

---

## Task 1: 调色板常量 `theme/Palette.ets`

**Files:**
- Create: `entry/src/main/ets/theme/Palette.ets`

- [ ] **Step 1: 写文件**

```ts
// Centralized palette for the modern developer-tool look (accent = cyan).
// Single source of truth for colors — do not scatter hex values elsewhere.
export class Palette {
  static readonly base: string = '#0B0D10';     // page background
  static readonly surface: string = '#11161D';  // cards / status bar
  static readonly inputBg: string = '#0E1318';   // text input fill
  static readonly border: string = '#1E2630';    // hairline borders
  static readonly text: string = '#F4F7FB';      // primary text
  static readonly textDim: string = '#8A94A6';   // placeholder / subtitle
  static readonly accent: string = '#3DD6C4';    // cyan: focus, connect btn, connected dot
  static readonly warn: string = '#FFB454';      // reconnecting
  static readonly danger: string = '#FF6B6B';    // error / disconnect
}
```

- [ ] **Step 2: 验证(DevEco)**

无独立测试;颜色在后续任务里被引用并在 DevEco 中目视确认。确认文件能被 import(`import { Palette } from '../theme/Palette';`)无编译错误。

- [ ] **Step 3: Commit(可选,git init 后)**

```bash
git add entry/src/main/ets/theme/Palette.ets
git commit -m "feat(ui): add centralized cyan palette"
```

---

## Task 2: 字号纯逻辑助手 + node 测试(TDD)

**Files:**
- Create: `entry/src/main/ets/theme/FontScale.ets`
- Create: `tools/verify/_fontscale.mjs`(node 镜像)
- Test: `tools/verify/fontscale.test.mjs`

- [ ] **Step 1: 写失败测试** `tools/verify/fontscale.test.mjs`

```js
import assert from 'node:assert';
import { test } from 'node:test';
import { clampFontSize, stepFontSize, DEFAULT_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE } from './_fontscale.mjs';

test('clamp keeps in-range, rounds, and bounds', () => {
  assert.equal(clampFontSize(16), 16);
  assert.equal(clampFontSize(16.4), 16);
  assert.equal(clampFontSize(MIN_FONT_SIZE - 5), MIN_FONT_SIZE);
  assert.equal(clampFontSize(MAX_FONT_SIZE + 5), MAX_FONT_SIZE);
});

test('clamp falls back to default on non-finite', () => {
  assert.equal(clampFontSize(NaN), DEFAULT_FONT_SIZE);
  assert.equal(clampFontSize(Infinity), MAX_FONT_SIZE === Infinity ? DEFAULT_FONT_SIZE : DEFAULT_FONT_SIZE);
});

test('step moves by FONT_STEP and clamps at bounds', () => {
  assert.equal(stepFontSize(16, 1), 18);
  assert.equal(stepFontSize(16, -1), 14);
  assert.equal(stepFontSize(MAX_FONT_SIZE, 1), MAX_FONT_SIZE);
  assert.equal(stepFontSize(MIN_FONT_SIZE, -1), MIN_FONT_SIZE);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node --test tools/verify/fontscale.test.mjs`
Expected: FAIL — `Cannot find module './_fontscale.mjs'`

- [ ] **Step 3: 写 node 镜像** `tools/verify/_fontscale.mjs`

```js
// Kept equivalent to entry/src/main/ets/theme/FontScale.ets
export const DEFAULT_FONT_SIZE = 16;
export const MIN_FONT_SIZE = 10;
export const MAX_FONT_SIZE = 28;
export const FONT_STEP = 2;

export function clampFontSize(n) {
  if (!Number.isFinite(n)) return DEFAULT_FONT_SIZE;
  const r = Math.round(n);
  if (r < MIN_FONT_SIZE) return MIN_FONT_SIZE;
  if (r > MAX_FONT_SIZE) return MAX_FONT_SIZE;
  return r;
}

export function stepFontSize(current, deltaSteps) {
  return clampFontSize(current + deltaSteps * FONT_STEP);
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node --test tools/verify/fontscale.test.mjs`
Expected: PASS(3 tests)

- [ ] **Step 5: 写 ArkTS 版本** `entry/src/main/ets/theme/FontScale.ets`(与镜像逐行等价,加类型)

```ts
// Pure font-size helpers. Mirrored in tools/verify/_fontscale.mjs for node tests.
export const DEFAULT_FONT_SIZE: number = 16;
export const MIN_FONT_SIZE: number = 10;
export const MAX_FONT_SIZE: number = 28;
export const FONT_STEP: number = 2;

export function clampFontSize(n: number): number {
  if (!Number.isFinite(n)) {
    return DEFAULT_FONT_SIZE;
  }
  const r: number = Math.round(n);
  if (r < MIN_FONT_SIZE) {
    return MIN_FONT_SIZE;
  }
  if (r > MAX_FONT_SIZE) {
    return MAX_FONT_SIZE;
  }
  return r;
}

export function stepFontSize(current: number, deltaSteps: number): number {
  return clampFontSize(current + deltaSteps * FONT_STEP);
}
```

- [ ] **Step 6: 跑全部 verify 测试确认未回归**

Run: `node --test tools/verify/`
Expected: PASS(原有 + 新增,全绿)

- [ ] **Step 7: Commit(可选)**

```bash
git add entry/src/main/ets/theme/FontScale.ets tools/verify/_fontscale.mjs tools/verify/fontscale.test.mjs
git commit -m "feat(ui): add font-size clamp/step helper with tests"
```

---

## Task 3: `ConnectionStore` 增加字号持久化

**Files:**
- Modify: `entry/src/main/ets/store/ConnectionStore.ets`

- [ ] **Step 1: 加 key 常量**(放在 `const KEY_REMEMBER` 那一行下面)

```ts
const KEY_FONT: string = 'font_size';
```

- [ ] **Step 2: 在 `ConnectionStore` 类内、`load()` 方法之前(或之后)加两个方法**

```ts
  async loadFontSize(fallback: number): Promise<number> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      return await pref.get(KEY_FONT, fallback) as number;
    } catch (e) {
      console.error('wand load fontSize failed: ' + JSON.stringify(e));
      return fallback;
    }
  }

  async saveFontSize(size: number): Promise<void> {
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      const pref: preferences.Preferences = await preferences.getPreferences(this.context, opt);
      await pref.put(KEY_FONT, size);
      await pref.flush();
    } catch (e) {
      console.error('wand save fontSize failed: ' + JSON.stringify(e));
    }
  }
```

- [ ] **Step 3: 验证(DevEco)**

编译通过即可;运行期效果在 Task 5 一起验证(改字号→重启→沿用)。

- [ ] **Step 4: Commit(可选)**

```bash
git add entry/src/main/ets/store/ConnectionStore.ets
git commit -m "feat(store): persist terminal font size in preferences"
```

---

## Task 4: `Index.ets` 整体改版(表单卡片 + 状态栏 + 字号 + 快捷键)

> 本任务整体重写 `entry/src/main/ets/pages/Index.ets`。下面给出**完整新文件内容**,直接替换即可。逻辑(连接/校验/持久化/会话生命周期)保持原行为,只重做视觉与新增字号/Enter/快捷键。

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`(整体替换)

- [ ] **Step 1: 用以下内容整体替换 `Index.ets`**

```ts
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { TerminalController, TerminalSurface } from 'libghostty_ohos';
import { TerminalSession } from '../session/TerminalSession';
import { WandWebSocketDriver } from '../transport/WandWebSocketDriver';
import { DriverState, DriverStatus, WandConnectConfig } from '../transport/TerminalDriver';
import { ConnectionStore, ConnectionProfile } from '../store/ConnectionStore';
import { Palette } from '../theme/Palette';
import { DEFAULT_FONT_SIZE, stepFontSize, clampFontSize } from '../theme/FontScale';

function stateLabel(s: DriverStatus): string {
  switch (s.state) {
    case DriverState.Connecting:
      return '连接中…';
    case DriverState.Connected:
      return '已连接';
    case DriverState.Reconnecting:
      return '重连中…';
    case DriverState.Closed:
      return '已断开';
    case DriverState.Error:
      return '错误：' + (s.message ?? '');
    default:
      return '空闲';
  }
}

@Entry
@Component
struct Index {
  // Controller + XComponent surface live for the whole page lifetime (see
  // terminalsurface-lifecycle memory). Connect/disconnect only start/stop the driver.
  private controller: TerminalController = new TerminalController();
  private session: TerminalSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private store: ConnectionStore | null = null;

  @State private connected: boolean = false;
  @State private host: string = '192.168.1.10';
  @State private port: string = '8765';
  @State private token: string = '';
  @State private tls: boolean = false;
  @State private rememberToken: boolean = false;
  @State private showToken: boolean = false;
  @State private fontSize: number = DEFAULT_FONT_SIZE;
  @State private statusText: string = '空闲';
  @State private driverState: DriverState = DriverState.Idle;
  @State private formError: string = '';
  @State private focusedField: string = '';

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new ConnectionStore(this.context);
    this.loadProfile();
    this.loadFontSize();
  }

  private loadProfile(): void {
    const store: ConnectionStore | null = this.store;
    if (!store) {
      return;
    }
    store.load().then((p: ConnectionProfile): void => {
      this.host = p.host;
      this.port = p.port;
      this.tls = p.tls;
      this.rememberToken = p.rememberToken;
      this.token = p.token;
    });
  }

  private loadFontSize(): void {
    const store: ConnectionStore | null = this.store;
    if (!store) {
      this.controller.updateConfig({ fontSize: this.fontSize, scrollbackLines: 20000 });
      return;
    }
    store.loadFontSize(DEFAULT_FONT_SIZE).then((fs: number): void => {
      this.fontSize = clampFontSize(fs);
      this.controller.updateConfig({ fontSize: this.fontSize, scrollbackLines: 20000 });
    });
  }

  aboutToDisappear(): void {
    this.stopSession();
  }

  private connect(): void {
    const host: string = this.host.trim();
    const token: string = this.token.trim();
    const port: number = Number(this.port);
    if (host.length === 0) {
      this.formError = '请输入主机地址';
      return;
    }
    if (!Number.isInteger(port) || port <= 0 || port > 65535) {
      this.formError = '端口无效（1-65535）';
      return;
    }
    if (token.length === 0) {
      this.formError = '请输入 token';
      return;
    }
    this.formError = '';

    if (this.store) {
      const profile: ConnectionProfile = {
        host,
        port: this.port.trim(),
        tls: this.tls,
        rememberToken: this.rememberToken,
        token
      };
      this.store.save(profile);
    }

    this.stopSession();

    const cfg: WandConnectConfig = { host, port, token, tls: this.tls };
    const session: TerminalSession = new TerminalSession(this.controller, new WandWebSocketDriver(cfg));
    session.onStatus((s: DriverStatus): void => {
      this.statusText = stateLabel(s);
      this.driverState = s.state;
    });
    this.session = session;
    this.statusText = '连接中…';
    this.driverState = DriverState.Connecting;
    this.connected = true;
    session.start();
  }

  private disconnect(): void {
    this.stopSession();
    this.connected = false;
    this.statusText = '空闲';
    this.driverState = DriverState.Idle;
  }

  private stopSession(): void {
    if (this.session) {
      this.session.stop();
      this.session = null;
    }
  }

  private applyFontSize(size: number): void {
    this.fontSize = size;
    this.controller.updateConfig({ fontSize: size });
    if (this.store) {
      this.store.saveFontSize(size);
    }
  }

  private adjustFont(deltaSteps: number): void {
    this.applyFontSize(stepFontSize(this.fontSize, deltaSteps));
  }

  private resetFont(): void {
    this.applyFontSize(DEFAULT_FONT_SIZE);
  }

  // Best-effort desktop shortcuts. The terminal XComponent may consume keys
  // while focused, so the A-/A+ buttons are the reliable path. Verify in DevEco.
  private handleKey(e: KeyEvent): boolean {
    if (!this.connected || e.type !== KeyType.Down) {
      return false;
    }
    let ctrl: boolean = false;
    try {
      ctrl = e.getModifierKeyState(['Ctrl']);
    } catch (_e) {
      ctrl = false;
    }
    if (!ctrl) {
      return false;
    }
    if (e.keyCode === KeyCode.KEYCODE_MINUS || e.keyCode === KeyCode.KEYCODE_NUMPAD_SUBTRACT) {
      this.adjustFont(-1);
      return true;
    }
    if (e.keyCode === KeyCode.KEYCODE_EQUALS || e.keyCode === KeyCode.KEYCODE_NUMPAD_ADD) {
      this.adjustFont(1);
      return true;
    }
    if (e.keyCode === KeyCode.KEYCODE_0 || e.keyCode === KeyCode.KEYCODE_NUMPAD_0) {
      this.resetFont();
      return true;
    }
    return false;
  }

  private dotColor(): string {
    switch (this.driverState) {
      case DriverState.Connected:
        return Palette.accent;
      case DriverState.Connecting:
      case DriverState.Reconnecting:
        return Palette.warn;
      case DriverState.Error:
        return Palette.danger;
      default:
        return Palette.textDim;
    }
  }

  build() {
    Stack() {
      Column() {
        if (this.connected) {
          this.buildStatusBar();
        }
        TerminalSurface({
          controller: this.controller,
          surfaceId: 'wandSurface',
          surfaceColor: Palette.base
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (!this.connected) {
        this.buildForm();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
    .onKeyEvent((e: KeyEvent): void => {
      this.handleKey(e);
    })
  }

  @Builder
  private buildStatusBar() {
    Row({ space: 10 }) {
      Text('●')
        .fontSize(12)
        .fontColor(this.dotColor())
      Text(this.statusText)
        .fontSize(13)
        .fontColor(Palette.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.host + ':' + this.port)
        .layoutWeight(1)
        .fontSize(12)
        .fontColor(Palette.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      // Font controls
      Button('A-')
        .height(30)
        .fontSize(13)
        .backgroundColor(Palette.inputBg)
        .fontColor(Palette.text)
        .onClick(() => {
          this.adjustFont(-1);
        })
      Text(this.fontSize.toString())
        .fontSize(13)
        .fontColor(Palette.accent)
        .width(28)
        .textAlign(TextAlign.Center)
      Button('A+')
        .height(30)
        .fontSize(13)
        .backgroundColor(Palette.inputBg)
        .fontColor(Palette.text)
        .onClick(() => {
          this.adjustFont(1);
        })
      Button('断开')
        .height(30)
        .fontSize(13)
        .backgroundColor(Color.Transparent)
        .fontColor(Palette.danger)
        .borderWidth(1)
        .borderColor(Palette.danger)
        .borderRadius(8)
        .onClick(() => {
          this.disconnect();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(Palette.surface)
    .border({ width: { bottom: 1 }, color: Palette.border })
  }

  @Builder
  private buildForm() {
    Column() {
      Column({ space: 6 }) {
        Text('◐ wand-term')
          .fontSize(26)
          .fontColor(Palette.text)
        Text('connect to wand-agent')
          .fontSize(13)
          .fontColor(Palette.textDim)
      }
      .margin({ bottom: 20 })

      // Card
      Column({ space: 14 }) {
        // host + port row
        Row({ space: 10 }) {
          TextInput({ text: this.host, placeholder: '主机 host' })
            .layoutWeight(2)
            .height(44)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'host' ? Palette.accent : Palette.border)
            .onFocus(() => {
              this.focusedField = 'host';
            })
            .onBlur(() => {
              if (this.focusedField === 'host') {
                this.focusedField = '';
              }
            })
            .onChange((v: string) => {
              this.host = v;
            })
            .onSubmit(() => {
              this.connect();
            })
          TextInput({ text: this.port, placeholder: '端口' })
            .layoutWeight(1)
            .height(44)
            .type(InputType.Number)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'port' ? Palette.accent : Palette.border)
            .onFocus(() => {
              this.focusedField = 'port';
            })
            .onBlur(() => {
              if (this.focusedField === 'port') {
                this.focusedField = '';
              }
            })
            .onChange((v: string) => {
              this.port = v;
            })
            .onSubmit(() => {
              this.connect();
            })
        }
        .width('100%')

        // token with show/hide
        Row({ space: 10 }) {
          TextInput({ text: this.token, placeholder: 'token' })
            .layoutWeight(1)
            .height(44)
            .type(this.showToken ? InputType.Normal : InputType.Password)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'token' ? Palette.accent : Palette.border)
            .onFocus(() => {
              this.focusedField = 'token';
            })
            .onBlur(() => {
              if (this.focusedField === 'token') {
                this.focusedField = '';
              }
            })
            .onChange((v: string) => {
              this.token = v;
            })
            .onSubmit(() => {
              this.connect();
            })
          Button(this.showToken ? '隐藏' : '显示')
            .height(44)
            .width(56)
            .fontSize(13)
            .backgroundColor(Palette.inputBg)
            .fontColor(Palette.textDim)
            .borderRadius(8)
            .onClick(() => {
              this.showToken = !this.showToken;
            })
        }
        .width('100%')

        Row() {
          Text('TLS (wss)')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.tls })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => {
              this.tls = on;
            })
        }
        .width('100%')

        Row() {
          Text('记住 token（加密存储）')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.rememberToken })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => {
              this.rememberToken = on;
            })
        }
        .width('100%')

        if (this.formError.length > 0) {
          Text('⚠ ' + this.formError)
            .fontSize(13)
            .fontColor(Palette.danger)
            .width('100%')
        }

        Button('连 接')
          .width('100%')
          .height(46)
          .fontSize(16)
          .fontColor(Palette.base)
          .backgroundColor(Palette.accent)
          .borderRadius(10)
          .onClick(() => {
            this.connect();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding(20)
      .backgroundColor(Palette.surface)
      .borderRadius(12)
      .borderWidth(1)
      .borderColor(Palette.border)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Palette.base)
  }
}
```

- [ ] **Step 2: 编译(DevEco)**

在 DevEco 中 Build。Expected:编译通过,无未定义引用(`Palette`、`FontScale`、`KeyCode` 均已 import)。
若 `KeyCode` 导入报错,改为 `import { KeyCode } from '@ohos.multimodalInput.keyCode';` 并重新 Build。

- [ ] **Step 3: 真机/PC 验证 — 外观**

观察:① 未连接是居中卡片(深炭底 + 青色 accent),标题 `◐ wand-term` + 副标题;② 输入框聚焦时边框变青;③ "连接"按钮青色填充;④ token 右侧"显示/隐藏"可切换明文。

- [ ] **Step 4: 真机/PC 验证 — 连接与状态栏**

填好 host/port/token 连接。观察:状态栏出现 `● 已连接 host:port  A- 16 A+  [断开]`;色点为青;断开按钮红色描边,点击能正常断开回到表单(回归:不崩溃,见 terminalsurface-lifecycle)。

- [ ] **Step 5: 真机/PC 验证 — 字号 + 记忆**

点 `A+`/`A-`:终端字号实时变化、中间数字同步、上下限(10/28)生效。断开并**完全杀掉 App 重开**:重连后字号应沿用上次值(持久化生效)。

- [ ] **Step 6: 真机/PC 验证 — Enter 提交 + 快捷键**

在任一输入框按 `Enter` → 触发连接(等价点"连接")。连接后试 `Ctrl+=` / `Ctrl+-` / `Ctrl+0`:**能用是 bonus**;若终端吞键无反应,属已知限制,以 A-/A+ 按钮为准(记录结果即可,不算失败)。

- [ ] **Step 7: 回归验证**

连接/中文输出/窗口缩放 reflow/断开/重连/配置回填/token 记忆 全部照旧。复制粘贴:终端区**右键**应出现 Copy / Paste / Copy Screen 菜单(HAR 自带)。

- [ ] **Step 8: Commit(可选)**

```bash
git add entry/src/main/ets/pages/Index.ets
git commit -m "feat(ui): redesign connect form and status bar; add font-size control"
```

---

## 自检(对照 spec)

- spec §2.1 未连接卡片 → Task 4 buildForm ✅
- spec §2.2 已连接状态栏(色点/host:port/字号/断开) → Task 4 buildStatusBar + dotColor ✅
- spec §3 聚焦反馈 → focusedField + borderColor ✅;hover → ArkUI 按钮默认 hover 态(PC 生效),Step 3 目视确认
- spec §3 快捷键 Ctrl+=/-/0 → handleKey(best-effort,Step 6 验证)✅
- spec §3 复制粘贴 → HAR 右键菜单已带,Step 7 确认,不重复实现 ✅
- spec §3 窗口 reflow → 现有 size listener,Step 7 验证 ✅
- spec §3 Enter 提交 → onSubmit ✅
- spec §4 字号调节 + 记忆 → Task 2(逻辑)+ Task 3(持久化)+ Task 4(UI/应用)✅
- spec §4 默认 16、范围 10–28、步进 2 → FontScale 常量 ✅
- 调色板集中 → Task 1 Palette ✅

无 TODO/占位符;类型/方法名跨任务一致(`applyFontSize`/`adjustFont`/`resetFont`/`loadFontSize`/`saveFontSize`/`clampFontSize`/`stepFontSize`)。
```
