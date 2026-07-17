import { curves } from '@kit.ArkUI';
import { UiTheme, REFINED_DARK_THEME, RADIUS_CONTROL } from '../theme/UiTheme';
import { DEFAULT_UI_FONT } from '../theme/FontScale';

// First-run onboarding guide overlay (also replayable from settings → About).
// Extracted from pages/Index.ets (Task 2) — behavior preserved.
//
// Appear/disappear animation replicates the native bindSheet(CENTER) motion:
// card slides up + fades via its TransitionEffect, background mask fades via
// guideBgOpacity. The mask fade-in runs in aboutToAppear (the page used to do
// it in openGuide); the fade-out runs in finishGuide below, simultaneously
// with the card exit transition triggered when the page clears showGuide.
// The page owns showGuide and persists the onboarded flag (onFinish).
@Component
export struct GuideOverlay {
  @Prop uiFontFamily: string = DEFAULT_UI_FONT;
  onFinish: () => void = () => {};

  @State private guideStep: number = 0;
  // Background mask opacity for fade-in/out animation.
  @State private guideBgOpacity: number = 0;
  // Hover state for the guide card buttons.
  @State private guideHover: string = '';
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;
  // Drives the native horizontal slide between guide pages.
  private guideTabs: TabsController = new TabsController();
  private readonly guideCount: number = 5;
  private readonly guideAnimCurve = curves.cubicBezierCurve(0.32, 0.72, 0.0, 1.0);

  aboutToAppear(): void {
    animateTo({ duration: 280, curve: this.guideAnimCurve }, () => {
      this.guideBgOpacity = 1;
    });
  }

  // Fade the mask out, then hand control back to the page (it tears the
  // overlay down — triggering the card exit transition — and persists the
  // onboarded flag). The 250ms fade runs alongside the 250ms card exit,
  // exactly like the old closeGuide() in Index.
  private finishGuide(): void {
    animateTo({ duration: 250, curve: this.guideAnimCurve }, () => {
      this.guideBgOpacity = 0;
    });
    this.onFinish();
  }

  private guideTitle(step: number): string {
    switch (step) {
      case 0: return '欢迎使用 fish-term';
      case 1: return '第 1 步 · 安装 fish-agent';
      case 2: return '第 2 步 · 启动服务 & 获取连接信息';
      case 3: return '第 3 步 · 新建连接';
      default: return '第 4 步 · 开始使用';
    }
  }

  private guideDesc(step: number): string {
    switch (step) {
      case 0:
        return 'fish-term 是一个连接到 fish-agent 的 HarmonyOS 终端。\n只需几步就能在手机/平板上获得完整的远程终端体验。';
      case 1:
        return 'fish-agent 基于 wand-agent 修改，是一个 Go 编写的 WebSocket PTY 代理。\n\n安装方式一：下载预编译二进制（Linux）\n\n  # ARM64（树莓派/ARM 服务器）\n  curl -LO https://github.com/<repo>/releases/latest/download/fish-agent-linux-arm64\n\n  # x86_64（普通 PC/服务器）\n  curl -LO https://github.com/<repo>/releases/latest/download/fish-agent-linux-amd64\n\n  chmod +x fish-agent-linux-*\n\n安装方式二：从源码编译\n\n  git clone <repo-url> && cd fish-agent\n  go build -buildvcs=false -o fish-agent .\n\n编译完成后将 fish-agent 复制到任意目录即可运行。';
      case 2:
        return '启动 fish-agent：\n\n  ./fish-agent --host 0.0.0.0 --port 8765 --token <你的token>\n\n参数说明：\n  --host  监听地址，默认 0.0.0.0（所有网卡）\n  --port  监听端口，默认 8765\n  --token  鉴权令牌，客户端连接时需携带\n\n启动后会输出 host、port、token 三项信息。\n用 ip addr 查看服务器 IP，确保设备和服务器在同一网络可达。\n如开启防火墙，请放行对应端口。';
      case 3:
        return '回到 fish-term，在首页填入 host / 端口 / token，\n如需加密传输可打开 TLS(wss)，点击「连接」即可开启第一个终端标签页。';
      default:
        return '常用操作：\n\n  · 右键终端：复制 / 粘贴 / 查找 / 缓冲区\n  · Ctrl+Shift+F：查找\n  · Ctrl+Shift+T 新建标签，Ctrl+Shift+W 关闭，Ctrl+Tab 切换\n  · 标签可拖拽排序；设置里可换主题、字号、光标样式';
    }
  }

  // Placeholder filename for the screenshot to drop in for each step.
  private guideImageName(step: number): string {
    return 'guide_' + step + '.png';
  }

  // Navigate the guide. The native Tabs slide animation handles the motion;
  // direction is automatic (forward vs back). Past the last step it finishes.
  private goStep(dir: number): void {
    const target: number = this.guideStep + dir;
    if (target >= this.guideCount) {
      this.finishGuide();
      return;
    }
    if (target < 0) {
      return;
    }
    this.guideTabs.changeIndex(target);
  }

  // One guide page (image + title + description), inside a Scroll so a tall
  // page (e.g. the shortcuts summary) can scroll within the fixed Tabs height.
  // The image is pinned to the top of the scroll area so its top edge stays at
  // the same position across all steps during horizontal swipe.
  @Builder
  private guideBody(step: number) {
    Scroll() {
      Column() {
        // Image placeholder — replace with real screenshots later.
        Stack({ alignContent: Alignment.Center }) {
          Column({ space: 6 }) {
            Text('🖼')
              .fontSize(34)
              .fontColor(this.uiTheme.textDim)
            Text('图片占位 · ' + this.guideImageName(step))
              .fontSize(12)
              .fontColor(this.uiTheme.textDim)
          }
        }
        .width('100%')
        .height(180)
        .backgroundColor(this.uiTheme.bgInput)
        .borderRadius(12)
        .border({ width: 1, color: this.uiTheme.border })
        .margin({ top: 0, bottom: 18 })

        Text(this.guideTitle(step))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .width('100%')
          .margin({ bottom: 10 })

        Text(this.guideDesc(step))
          .fontSize(14)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .lineHeight(22)
          .width('100%')
      }
      .width('100%')
      .padding({ top: 0 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .align(Alignment.Top)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // Background mask — fades in/out independently via guideBgOpacity.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .opacity(this.guideBgOpacity * 0.8)
        .onClick(() => { /* absorb clicks, close on background tap disabled */ })

      // Card
      Column() {
        // Sliding page area: native Tabs gives a smooth horizontal slide. Swipe
        // between pages is also enabled. Native bar hidden; buttons/dots drive it.
        Tabs({ controller: this.guideTabs, index: this.guideStep }) {
          TabContent() { this.guideBody(0) }
          TabContent() { this.guideBody(1) }
          TabContent() { this.guideBody(2) }
          TabContent() { this.guideBody(3) }
          TabContent() { this.guideBody(4) }
        }
        .barHeight(0)
        .scrollable(true)
        .animationDuration(300)
        .width('100%')
        .height(320)
        .onChange((i: number) => { this.guideStep = i; })

        // Step dots
        Row({ space: 6 }) {
          ForEach(['0', '1', '2', '3', '4'], (s: string) => {
            Circle({ width: 7, height: 7 })
              .fill(Number(s) === this.guideStep ? this.uiTheme.accent : this.uiTheme.border)
          }, (s: string) => s)
        }
        .margin({ top: 20, bottom: 18 })
        .justifyContent(FlexAlign.Center)

        Row({ space: 10 }) {
          Text('跳过')
            .fontSize(14)
            .fontColor(this.guideHover === 'skip' ? this.uiTheme.textPrimary : this.uiTheme.textDim)
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(RADIUS_CONTROL)
            .backgroundColor(this.guideHover === 'skip' ? this.uiTheme.pressOverlay : Color.Transparent)
            .animation({ duration: 120, curve: Curve.EaseOut })
            .focusable(false)
            .onHover((h: boolean) => { this.guideHover = h ? 'skip' : ''; })
            .onClick(() => { this.finishGuide(); })

          Blank()

          if (this.guideStep > 0) {
            Text('上一步')
              .fontSize(14)
              .fontColor(this.uiTheme.textPrimary)
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .borderRadius(9)
              .backgroundColor(this.guideHover === 'prev' ? this.uiTheme.pressOverlay : this.uiTheme.bgSurface)
              .border({ width: 1, color: this.uiTheme.border })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .focusable(false)
              .onHover((h: boolean) => { this.guideHover = h ? 'prev' : ''; })
              .onClick(() => { this.goStep(-1); })
          }

          Text(this.guideStep >= this.guideCount - 1 ? '开始使用' : '下一步')
            .fontSize(14)
            .fontColor(this.uiTheme.bgBase)
            .padding({ left: 18, right: 18, top: 9, bottom: 9 })
            .borderRadius(9)
            .opacity(this.guideHover === 'next' ? 0.85 : 1.0)
            .scale(this.guideHover === 'next' ? { x: 0.97, y: 0.97 } : { x: 1.0, y: 1.0 })
            .backgroundColor(this.uiTheme.accent)
            .animation({ duration: 120, curve: Curve.EaseOut })
            .focusable(false)
            .onHover((h: boolean) => { this.guideHover = h ? 'next' : ''; })
            .onClick(() => { this.goStep(1); })
        }
        .width('100%')
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .constraintSize({ maxWidth: 460 })
      .padding(24)
      .backgroundColor(this.uiTheme.bgBase)
      .borderRadius(16)
      .border({ width: 1, color: this.uiTheme.border })
      // Slide-up + fade transition matching bindSheet(CENTER) feel.
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.translate({ y: 60 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 280, curve: this.guideAnimCurve }),
        TransitionEffect.translate({ y: 60 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 250, curve: this.guideAnimCurve })
      ))
    }
    .width('100%')
    .height('100%')
    .padding(24)
  }
}
