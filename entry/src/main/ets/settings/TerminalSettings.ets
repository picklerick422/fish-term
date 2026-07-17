import { TerminalController } from 'libghostty_ohos';
import { Palette } from '../theme/Palette';
import { ConnectionStore } from '../store/ConnectionStore';

@Component
export struct TerminalSettings {
  controller: TerminalController = new TerminalController();
  store: ConnectionStore | null = null;
  @Prop token: string = '';
  @Prop hostLabel: string = '';
  @Prop cursorStyle: number = 0;
  @Prop cursorBlink: boolean = true;
  @Prop scrollbackLines: number = 20000;
  @Prop tabCompact: boolean = false;
  @Prop uiFontFamily: string = 'Inter';
  onTokenChange: (token: string) => void = (_token: string) => {};
  onScrollbackChange: (v: number) => void = (_v: number) => {};
  onTabCompactChange: (v: boolean) => void = (_v: boolean) => {};

  @State private hoverUpdateToken: boolean = false;
  @State private tokenDraft: string = '';
  @State private showCrashOnStartup: boolean = true;
  @State private restoreTabsEnabled: boolean = true;

  aboutToAppear(): void {
    this.tokenDraft = this.token;
    // 加载崩溃提醒偏好
    if (this.store) {
      this.store.loadShowCrashOnStartup().then((v: boolean) => { this.showCrashOnStartup = v; });
      this.store.loadRestoreTabsEnabled().then((v: boolean) => { this.restoreTabsEnabled = v; });
    }
  }

  @Builder
  private buildSectionHeader(title: string) {
    Text(title.toUpperCase())
      .fontSize(11)
      .fontColor(Palette.textDim)
      .fontWeight(FontWeight.Medium)
      .fontFamily(this.uiFontFamily)
      .width('100%')
      .margin({ bottom: 6 })
  }

  build() {
    Column({ space: 16 }) {
      // 连接认证 — 修改 token 并自动新建页签
      Column({ space: 0 }) {
        this.buildSectionHeader('连接认证')
        Column({ space: 12 }) {
          // 当前连接信息
          Row() {
            Text('当前连接')
              .fontSize(13)
              .fontColor(Palette.textDim)
            Text(this.hostLabel.length > 0 ? this.hostLabel : '—')
              .fontSize(13)
              .fontColor(Palette.text)
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 8 })
          }
          .width('100%')

          // Token 输入
          TextInput({ text: this.tokenDraft, placeholder: '输入新 token' })
            .width('100%')
            .height(40)
            .type(InputType.Password)
            .fontSize(13)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(Palette.border)
            .onChange((v: string) => { this.tokenDraft = v; })

          // 更新按钮
          Row() {
            Text('更新 Token 并新建连接')
              .fontSize(14)
              .fontColor(this.tokenDraft.trim().length > 0 ? Palette.accent : Palette.textDim)
          }
          .width('100%')
          .height(42)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.hoverUpdateToken ? '#1FFFFFFF' : Color.Transparent)
          .borderRadius(8)
          .border({ width: 1, color: this.tokenDraft.trim().length > 0 ? Palette.accent : Palette.border })
          .animation({ duration: 120, curve: Curve.EaseOut })
          .focusable(false)
          .onHover((h: boolean) => { this.hoverUpdateToken = h; })
          .onClick(() => {
            const t: string = this.tokenDraft.trim();
            if (t.length > 0) {
              this.onTokenChange(t);
            }
          })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Palette.surface)
        .borderRadius(10)
        .border({ width: 1, color: Palette.border })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // Scrollback lines section
      Column({ space: 0 }) {
        this.buildSectionHeader('滚动缓冲行数')
        Column({ space: 8 }) {
          Row() {
            Text('缓冲行数')
              .layoutWeight(1)
              .fontSize(14)
              .fontColor(Palette.text)
            Text(this.scrollbackLines.toString())
              .fontSize(14)
              .fontColor(Palette.accent)
          }
          .width('100%')

          Slider({
            value: this.scrollbackLines,
            min: 1000,
            max: 100000,
            step: 1000,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .selectedColor(Palette.accent)
            .trackColor(Palette.border)
            .focusable(false)
            .onChange((value: number, mode: SliderChangeMode) => {
              this.scrollbackLines = Math.round(value);
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.onScrollbackChange(Math.round(value));
                this.controller.updateConfig({ scrollbackLines: Math.round(value) });
                if (this.store) {
                  this.store.saveTerminalPrefs({
                    cursorStyle: this.cursorStyle,
                    cursorBlink: this.cursorBlink,
                    scrollbackLines: Math.round(value)
                  });
                }
              }
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Palette.surface)
        .borderRadius(10)
        .border({ width: 1, color: Palette.border })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 启动时崩溃提醒开关 — 与滚动缓冲卡片风格一致
      Column({ space: 0 }) {
        this.buildSectionHeader('崩溃提醒')
        Row({ space: 12 }) {
          Text('启动时显示崩溃提醒')
            .fontSize(14)
            .fontColor(Palette.text)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.showCrashOnStartup })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => {
              this.showCrashOnStartup = on;
              if (this.store) {
                this.store.saveShowCrashOnStartup(on);
              }
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Palette.surface)
        .borderRadius(10)
        .border({ width: 1, color: Palette.border })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 页签恢复开关
      Column({ space: 0 }) {
        this.buildSectionHeader('页签恢复')
        Row({ space: 12 }) {
          Text('启动时恢复上次的页签')
            .fontSize(14)
            .fontColor(Palette.text)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.restoreTabsEnabled })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => {
              this.restoreTabsEnabled = on;
              if (this.store) {
                this.store.saveRestoreTabsEnabled(on);
                if (!on) {
                  // Clear saved session when feature is disabled.
                  this.store.saveSession({ activeIndex: 0, tabs: [] });
                }
              }
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Palette.surface)
        .borderRadius(10)
        .border({ width: 1, color: Palette.border })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 页签紧凑显示开关
      Column({ space: 0 }) {
        this.buildSectionHeader('页签显示')
        Row({ space: 12 }) {
          Text('紧凑显示（等宽均分）')
            .fontSize(14)
            .fontColor(Palette.text)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.tabCompact })
            .selectedColor(Palette.accent)
            .focusable(false)
            .onChange((on: boolean) => {
              this.tabCompact = on;
              this.onTabCompactChange(on);
              if (this.store) {
                this.store.saveTabCompact(on);
              }
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Palette.surface)
        .borderRadius(10)
        .border({ width: 1, color: Palette.border })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
  }
}
