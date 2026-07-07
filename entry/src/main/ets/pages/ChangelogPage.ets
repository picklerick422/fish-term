import { Palette } from '../theme/Palette';
import { ChangelogEntry } from '../data/Changelog';

@Component
export struct ChangelogPage {
  @Prop version: string = '1.0.0';
  @Prop changelog: ChangelogEntry[] = [];
  onBack: () => void = () => {};

  @State private hoverBack: boolean = false;

  build() {
    Column() {
      // Header
      Row() {
        Row() {
          Text('←')
            .fontSize(18)
            .fontColor(Palette.textDim)
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.hoverBack ? '#1FFFFFFF' : Color.Transparent)
        .animation({ duration: 120, curve: Curve.EaseOut })
        .focusable(false)
        .onHover((h: boolean) => { this.hoverBack = h; })
        .onClick(() => { this.onBack(); })

        Text('更新日志')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
          .layoutWeight(1)

        Blank().width(40)
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })

      Scroll() {
        Column({ space: 16 }) {
          // App identity
          Column({ space: 10 }) {
            Image($r('app.media.app_logo'))
              .width(72)
              .height(72)
              .borderRadius(16)
            Text('fish-term')
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor(Palette.text)
            Text('HarmonyOS 终端 · 连接 fish-agent')
              .fontSize(12)
              .fontColor(Palette.textDim)
            Text('版本 ' + this.version)
              .fontSize(13)
              .fontColor(Palette.accent)
          }
          .width('100%')
          .padding({ top: 12, bottom: 8 })

          // Changelog list
          Column({ space: 8 }) {
            Text('历史更新')
              .fontSize(11)
              .fontColor(Palette.textDim)
              .fontWeight(FontWeight.Medium)
              .width('100%')

            ForEach(this.changelog, (entry: ChangelogEntry) => {
              Column({ space: 8 }) {
                Row({ space: 10 }) {
                  Text(entry.version)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Palette.text)
                  Text(entry.date)
                    .fontSize(11)
                    .fontColor(Palette.textDim)
                    .layoutWeight(1)
                }
                .width('100%')

                ForEach(entry.items, (item: string) => {
                  Row({ space: 8 }) {
                    Text('•')
                      .fontSize(12)
                      .fontColor(Palette.accent)
                    Text(item)
                      .fontSize(13)
                      .fontColor(Palette.textDim)
                      .layoutWeight(1)
                  }
                  .width('100%')
                }, (item: string) => item)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(Palette.surface)
              .borderRadius(10)
              .border({ width: 1, color: Palette.border })
              .alignItems(HorizontalAlign.Start)
            }, (entry: ChangelogEntry) => entry.version)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Text('© 2026 fish-term · 基于开源组件构建')
            .fontSize(11)
            .fontColor(Palette.textDim)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
  }
}
