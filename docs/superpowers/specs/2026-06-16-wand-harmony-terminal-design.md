# wand-term —— HarmonyOS 终端 App 设计文档

- 日期:2026-06-16
- 状态:已复核,进入实现(2026-06-16)
- 作者:Claude + picklerick0422

## 1. 背景与目标

做一个自有的 HarmonyOS 终端 App,组合两个现成件:

- **前端/渲染内核**:[`libghostty-ohos`](https://github.com/wiedymi/libghostty-ohos) —— 把 Ghostty 终端内核(libghostty-vt)移植到鸿蒙的 HAR 库。提供 `TerminalSurface`(渲染组件)+ `TerminalController`(命令式控制),负责终端渲染、输入捕获、VT 转义序列解析。它**不提供**任何传输(PTY/shell/SSH),刻意把 "driver 边界" 留给上层 App。
- **后端/远端 shell**:[`wand-agent`](https://github.com/ystyle/wand-agent) —— Go 写的 WebSocket↔PTY 网关,每个 WS 连接在远端(openEuler 容器)起一个登录 shell,二进制帧转发终端 I/O,文本帧(JSON)做 resize/cwd/fork 等控制。

**目标**:App 用 libghostty 渲染终端,通过一个传输 driver 连到不同后端跑 shell。v1 同时支持三种传输:**wand-agent(WebSocket)、本地 PTY、SSH**,并提供**多标签页 + 连接管理 + 主题设置**。

## 2. 范围

**In(v1)**
- 三种传输:wand-agent WebSocket、本地 PTY、SSH
- 多标签页(每 tab 一个独立 Session)
- 连接管理(profile 增删改、持久化、敏感字段安全存储)
- 设置(主题、字号、scrollback、cursor)
- 移动端终端基础体验:软键盘辅助键条、复制/粘贴、滚动、断线重连

**Out(本期不做,记为后续/后端待办)**
- 断线**续连**(保活同一远端 shell)—— 需改 wand-agent 后端,见 §8/§10
- 窗格分屏(split)
- tab 间用 wand-agent `fork`+`?id=` 续接(v1 用独立连接,见 §5.1)
- 端口转发、SFTP、会话录制等高级功能

## 3. 架构总览

### 3.1 分层

```
┌─────────────────────────────────────────────┐
│  UI 层 (pages/components)                      │
│  主页(tab栏+活动surface) · 连接管理 · 设置      │
├─────────────────────────────────────────────┤
│  Session 层 (session/)                         │
│  TerminalSession = Controller + Surface + Driver│
│  SessionManager  = tab 列表 / 生命周期         │
├─────────────────────────────────────────────┤
│  传输层 (transport/)                           │
│  TerminalDriver 接口                            │
│   ├ WandWebSocketDriver (纯 ArkTS)             │
│   ├ LocalPtyDriver      (包 native .so)        │
│   └ SshDriver           (包 native ssh)        │
├─────────────────────────────────────────────┤
│  libghostty_ohos (HAR, 不改)                   │
│  TerminalController + TerminalSurface + 渲染   │
└─────────────────────────────────────────────┘
```

### 3.2 目录布局

以 libghostty-ohos 整仓为基底,把其中的 `example` 模块进化成正式 App 模块(此处记为 `entry`):

```
wand-term/
├── libghostty_ohos/            # HAR,保持不动(终端内核 + 渲染 + 主题资源)
└── entry/                      # App 模块(由 example 进化)
    └── src/main/
        ├── cpp/                # 保留 example 现成 native
        │   ├── pty/            #   本地 PTY 传输
        │   └── ssh/            #   SSH 传输
        └── ets/
            ├── transport/
            │   ├── TerminalDriver.ets        # 接口 + 类型
            │   ├── WandWebSocketDriver.ets   # 纯 ArkTS
            │   ├── LocalPtyDriver.ets        # 包 native
            │   ├── SshDriver.ets             # 包 native
            │   ├── Utf8Framer.ets            # UTF-8 跨帧拆解(可单测)
            │   └── DriverFactory.ets         # 按 profile 造 driver
            ├── session/
            │   ├── TerminalSession.ets
            │   └── SessionManager.ets
            ├── model/
            │   ├── ConnectionProfile.ets
            │   ├── ProfileStore.ets          # Preferences + Asset
            │   └── AppSettings.ets
            ├── pages/
            │   ├── Index.ets                 # 主页:tab 栏 + 活动 surface
            │   ├── ConnectionList.ets        # 连接管理
            │   ├── ConnectionEdit.ets        # 新建/编辑 profile
            │   └── Settings.ets
            └── components/
                ├── TabBar.ets
                ├── KeyAssistBar.ets          # 软键盘辅助键条
                └── ...
```

### 3.3 数据流(单 Session 内)

```
TerminalSurface ⇄ TerminalController          (HAR 提供)
controller.inputListener(data)  → session → driver.write(data)
driver 输出(bytes→string)       → session → controller.feed(data)
controller.sizeListener(size)   → session → driver.resize(cols, rows)
controller.attachmentListener   → session → driver.start() / stop()
driver.onStatus(status)         → session → 更新 tab 状态
```

## 4. 传输层:`TerminalDriver` 接口与三种实现

### 4.1 统一接口

```ts
export enum DriverState { Idle, Connecting, Connected, Reconnecting, Closed, Error }
export interface DriverStatus { state: DriverState; message?: string }

export interface TerminalDriver {
  start(cols: number, rows: number): void;     // 建立会话
  write(data: string): void;                   // 输入(UTF-8 字节)→ 传输
  resize(cols: number, rows: number): void;
  stop(): void;                                // 结束并释放
  onOutput(cb: (data: string) => void): void;  // 传输输出 → controller.feed
  onStatus(cb: (s: DriverStatus) => void): void;
}
```

### 4.2 编码契约(关键)

经代码核实,libghostty HAR native 用 `napi_get_value_string_utf8`(输入)/ `napi_create_string_utf8`(输出),即 **ArkTS string ⇄ 原始字节走 UTF-8**。因此:

- **输入**:`inputListener` 给 string → `util.TextEncoder` 编码成 UTF-8 字节 → 发送。
- **输出**:收到原始字节 → `util.TextDecoder({ fatal: false, ... }, { stream: true })` 解码 → string → `controller.feed`。`stream: true` 自动缓存跨帧的半个多字节字符。非法字节用替换符,不崩。
- 这套拆帧逻辑抽到 `Utf8Framer.ets`,不依赖 ArkTS UI,可独立单测。

### 4.3 WandWebSocketDriver(纯 ArkTS,`@ohos.net.webSocket`)

- `start(cols,rows)`:连 `ws://host:port/ws?token=<t>&cols=<c>&rows=<r>&cwd=<...>&shell=<...>`。连上后 wand-agent 推初始 cwd 文本帧。
- **收消息**:
  - 二进制帧(ArrayBuffer)= PTY 输出 → 过 `Utf8Framer` → `onOutput`
  - 文本帧 = JSON 控制:`cwd`(更新 tab 标题/路径)、`forked`(本期忽略)、`error`(冒泡为状态/提示)、`shells`、`pong`
- `write(data)`:string → UTF-8 字节 → 二进制帧发出。
- `resize(cols,rows)`:发 `{"type":"resize","cols":c,"rows":r}` 文本帧。
- **心跳**:定时(如 15s)发 `{"type":"ping","ts":<now>}`;配合 WS 状态判断断线。
- **重连**:指数退避(1s→2s→4s…,封顶 30s),可手动停止;重连成功 = 新 shell(见 §10 限制)。
- **传输安全**:wand-agent 目前是明文 HTTP/WS(无 TLS),token 走 query。局域网场景可接受;profile 保留 `tls` 开关为将来经反向代理上 wss 预留。文档需提示明文风险。

### 4.4 LocalPtyDriver / SshDriver

- 各包一层 example 现成 native 桥(`initialize / start / stop / writeInput / setOutputCallback / resize`)。
- 把现在 `ExampleShellDriver.ets` 的逻辑(含 size 就绪重试)重构为实现 `TerminalDriver`。
- `SshDriver` 额外携带 `sshHost / sshPort / user / authType / 凭据`,复用 example 的 `ssh_session` native。
- native 本身**不改**,沿用 prebuilt(`libghostty_vt.a`)与 hvigor CMake 构建,无需 Docker 重建(除非将来动 native)。

## 5. Session / Tab 模型、连接管理与持久化

### 5.1 TerminalSession(一个 tab 的完整单元)

- 持有:`id`、`controller: TerminalController`、`surfaceId`、`driver: TerminalDriver`、`profile`、`title`、`status`。
- 构造时接线(见 §3.3),并把 `driver.onStatus` 映射到 tab 状态指示。
- **tab ↔ wand-agent 多会话**:v1 每个 wand-agent tab 开**独立 WebSocket 连接**(简单、稳健)。`fork`+`?id=` 续接为后续增强,且依赖后端支持。

### 5.2 SessionManager(tab 容器)

- 有序 `sessions[]` + `activeIndex`,以 `@Observed`/AppStorage 暴露给 UI。
- `openSession(profile)`:`DriverFactory` 按 `transport` 造 driver → 建 Session → 加 tab → 激活。
- `closeSession(id)`:停 driver、释放 controller、移除 tab。
- 切 tab = 挂载/卸载对应 `TerminalSurface`(每 controller 一个,`surfaceId` 唯一)。

### 5.3 ConnectionProfile 与设置

```ts
export enum TransportType { Wand, LocalPty, Ssh }
export interface ConnectionProfile {
  id: string; name: string; transport: TransportType;
  // wand:  host, port, token, tls, cwd?, shell?
  // ssh:   sshHost, sshPort, user, authType('password'|'key'), keyRef?
  // local: shellPath?
}
export interface AppSettings {
  theme: string; fontSize: number; scrollbackLines: number; cursorStyle: string; cursorBlink: boolean;
}
```

### 5.4 持久化(ProfileStore.ets)

- 配置元数据(name/host/port/transport/user 等非敏感)→ `@ohos.data.preferences`,序列化为 JSON 列表。
- **敏感字段(wand token、SSH 密码/私钥)→ `@ohos.security.asset`(关键资产)安全存储**,与明文分离;profile 里只存对资产的引用 key。
- `AppSettings` 存 Preferences。

## 6. UI 页面与交互

### 6.1 主页 Index.ets
- 顶部 **TabBar**:标题 + 状态点(连接中/已连/断开/错误)+ 关闭;末尾 `+` 新建(弹连接选择)。
- 中部:活动 Session 的 `TerminalSurface` 全屏。
- 底部 **KeyAssistBar**:`Esc / Tab / Ctrl / Alt / ↑↓←→ / Home/End / PgUp/PgDn` 等软键盘缺失键,按下经 `controller.write()` 注入转义序列;含粘贴按钮。

### 6.2 连接管理 ConnectionList / ConnectionEdit
- profile 列表(按 transport 图标分组),增删改。
- 编辑页按 transport 动态显示字段。点"连接" → `openSession` → 回主页。

### 6.3 设置 Settings.ets
- 主题(`controller.getThemeList()`)、字号、scrollback、cursor;改动实时 apply 到活动 controller(并写回 AppSettings)。

### 6.4 交互细节
- 长按进选择 → 复制(`controller.getSelectedText()` → 剪贴板)。
- 粘贴 → `controller.write()`(wand-agent 端有 bracketed-paste 处理)。
- 拖动滚动(HAR 内置);双指缩放字号(可选)。

## 7. 错误处理与重连

- **WS 连接错误**:状态置 `Error(message)`,tab 顶部横幅提示;触发指数退避自动重连。
- **服务端 error 帧**(`{"type":"error"}`,如 `max sessions reached`):横幅/toast 提示,必要时不新建 tab。
- **鉴权失败(401)**:提示重新输入 token。
- **shell 退出 / PTY EOF**:driver 停,tab 显示"已退出",提供"重启/关闭"。
- **SSH 认证失败**:提示重输凭据。
- **Surface 尺寸未就绪**:沿用 example 的就绪重试(50ms 轮询直到 cols/rows>0 再 start)。
- **编码异常**:`TextDecoder` 用替换符,不中断渲染。
- **渲染器错误**:`controller.getRendererError()` 暴露到诊断信息。

## 8. 已知限制(需告知用户)

1. **重连=新 shell**:wand-agent 在 WS 断开时 `cleanupSession` 会 kill PTY。移动端网络抖动会丢远端会话,重连只能开新 shell。做"断线续连"需改后端(会话保活 + 按 id 续接),超出本 App 范围。
2. **明文传输**:wand-agent 无 TLS,token 走 query。建议仅在可信局域网使用,或将来经反向代理上 wss。
3. **本地 PTY 依赖 example 的 HNP**:example 为本地 shell 打包了 fish/starship/fastfetch HNP(体积较大)。v1 沿用;后续可做成可选/瘦身。

## 9. 风险与依赖

- **【高】wand-agent 并发写崩溃**:本 App 正常使用会**同时**写 WS(输入 + resize + ping)并接收输出,而当前公开版 wand-agent 多 goroutine 并发写同一 `websocket.Conn`,会触发 `concurrent write to websocket connection` panic。**你的后端必须包含该修复**(给 conn 写操作加锁/单 writer)。该修复已在本机 `/tmp/wand-agent-src` 验证可用(race 检测 0 命中),可移植到你的私有后端。
- **签名**:root `build-profile.json5` 不含签名配置;真机运行需本地签名(你环境已具备)。
- **native 重建**:不动 native 则复用 prebuilt,无需 Docker;一旦改 native 需 `tools/build-ghostty-vt-docker.sh`。
- **构建环境**:本协作环境无法编译 HarmonyOS 工程,编译/真机验证由你在 DevEco 完成。
- **共享盘 git**:`/mnt/linux_share` 不支持 git chmod,项目内 git 操作可能需在本地真实文件系统进行。

## 10. 测试与验证策略

因协作环境不能编译鸿蒙工程,采用"纯逻辑单测 + 协议契约校验 + 设备端手测"三层:

1. **纯逻辑单测**:把无 UI 依赖的逻辑抽成可测模块——`Utf8Framer`(跨帧拆解)、WS URL 构造、重连退避、profile 序列化。用 Hypium 单测(在 DevEco 跑),关键算法另可用 node 跑纯 TS 校验。
2. **协议契约校验**:用 `/tmp/wand-agent-src` + 已写的 Go 测试客户端,固定 wand-agent 帧格式(二进制 I/O、cwd/resize/error JSON),保证 driver 实现与之对齐。
3. **端到端手测清单**(你在真机/模拟器跑,我据反馈迭代):连接成功并显示 shell、键入与回显、中文/Emoji 显示(UTF-8 跨帧)、resize 重排、断线重连、多 tab 切换、连接管理增删改、主题/字号生效、复制粘贴、辅助键、`max sessions` 错误提示。

## 11. 分阶段里程碑(实现顺序)

- **P0 基底**:libghostty-ohos 克隆改造为 `wand-term`,`entry` 模块能跑通(先用现状本地 PTY 验证基底 OK)。
- **P1 打通 wand-agent**:`Utf8Framer` + `WandWebSocketDriver` + 单 tab 端到端(输入/输出/resize/编码)。
- **P2 抽象落地**:定义 `TerminalDriver`,把 Local PTY、SSH 重构进接口,`DriverFactory`。
- **P3 多 tab**:`SessionManager` + `TabBar` + 主页多 surface 挂载。
- **P4 连接管理**:`ConnectionProfile` + `ProfileStore`(Preferences + Asset)+ 列表/编辑页。
- **P5 体验**:Settings(主题/字号)+ KeyAssistBar + 复制粘贴。
- **P6 健壮性**:错误处理/重连完善 + 已知限制提示。

每个阶段产出可在真机验证的增量。

## 12. 决议(2026-06-16 确认)

- **SSH 认证**:v1 仅密码认证;私钥导入 UI + Asset 存私钥留作后续增强。
- **本地 PTY**:保留 example 自带 fish/starship/fastfetch HNP(沿用 §8.3)。
- **构建节奏**:按 §11 里程碑 P0→P6 分阶段交付,每阶段产出可在 DevEco 真机验证的增量;用户验证后再进入下一阶段。
- **包名**:模块名 `entry`,bundleName 暂用 `com.wand.term`(可在 DevEco 改),项目名 `wand-term`。
