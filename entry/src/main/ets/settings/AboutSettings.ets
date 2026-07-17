import { UiTheme, REFINED_DARK_THEME, RADIUS_CARD } from '../theme/UiTheme';

@Component
export struct AboutSettings {
  @Prop uiFontFamily: string = 'Inter';
  @Prop themeCount: number = 0;
  onReplayGuide: () => void = () => {};
  onOpenCrashHistory: () => void = () => {};

  @State private hoverReplayGuide: boolean = false;
  @State private hoverCrashHistory: boolean = false;
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  @Builder
  private buildSectionHeader(title: string) {
    Text(title.toUpperCase())
      .fontSize(11)
      .fontColor(this.uiTheme.textDim)
      .fontWeight(FontWeight.Medium)
      .fontFamily(this.uiFontFamily)
      .width('100%')
      .margin({ bottom: 6 })
  }

  @Builder
  private buildAboutRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textDim)
      Text(value)
        .layoutWeight(1)
        .fontSize(13)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textPrimary)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(40)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CARD)
    .border({ width: 1, color: this.uiTheme.border })
  }

  build() {
    Column({ space: 16 }) {
      Column({ space: 12 }) {
        // App identity
        Column({ space: 10 }) {
          Image($r('app.media.app_logo'))
            .width(64)
            .height(64)
            .borderRadius(14)
          Text('fish-term')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.uiTheme.textPrimary)
          Text('HarmonyOS 终端 · 连接 fish-agent')
            .fontSize(12)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.uiTheme.textDim)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })

        Column({ space: 8 }) {
          this.buildSectionHeader('信息')
          this.buildAboutRow('版本', '1.0.0')
          this.buildAboutRow('终端引擎', 'libghostty (ghostty VT)')
          this.buildAboutRow('渲染', 'Native Drawing')
          this.buildAboutRow('主题数量', this.themeCount.toString())
          this.buildAboutRow('传输', 'WebSocket (fish-agent)')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row() {
          Text('查看新手引导')
            .fontSize(14)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.hoverReplayGuide ? this.uiTheme.accentHover : this.uiTheme.accent)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.hoverReplayGuide ? this.uiTheme.bgElevated : this.uiTheme.bgSurface)
        .borderRadius(RADIUS_CARD)
        .border({ width: 1, color: this.uiTheme.border })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverReplayGuide = h; })
        .onClick(() => { this.onReplayGuide(); })

        // 崩溃历史入口
        Row() {
          Text('崩溃历史')
            .fontSize(14)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.hoverCrashHistory ? this.uiTheme.accentHover : this.uiTheme.accent)
          Blank()
          Text('›')
            .fontSize(16)
            .fontColor(this.uiTheme.textDim)
        }
        .width('100%')
        .height(44)
        .padding({ left: 14, right: 14 })
        .justifyContent(FlexAlign.Start)
        .backgroundColor(this.hoverCrashHistory ? this.uiTheme.bgElevated : this.uiTheme.bgSurface)
        .borderRadius(RADIUS_CARD)
        .border({ width: 1, color: this.uiTheme.border })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverCrashHistory = h; })
        .onClick(() => { this.onOpenCrashHistory(); })

        Text('© 2026 fish-term · 基于开源组件构建')
          .fontSize(11)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .width('100%')
    }
    .width('100%')
  }
}
