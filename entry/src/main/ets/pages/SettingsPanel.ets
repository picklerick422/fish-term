import { TerminalController } from 'libghostty_ohos';
import { Palette } from '../theme/Palette';
import { ConnectionStore, TerminalPrefs } from '../store/ConnectionStore';
import { MIN_FONT_SIZE, MAX_FONT_SIZE } from '../theme/FontScale';

// Deterministic swatch color from theme name
function swatchColor(name: string): string {
  let hash: number = 0;
  for (let i: number = 0; i < name.length; i++) {
    hash = (hash * 31 + name.charCodeAt(i)) & 0xFFFFFF;
  }
  const r: number = ((hash >> 16) & 0xFF);
  const g: number = ((hash >> 8) & 0xFF);
  const b: number = (hash & 0xFF);
  const toHex = (n: number): string => {
    const h: string = n.toString(16);
    return h.length === 1 ? '0' + h : h;
  };
  return '#' + toHex(r) + toHex(g) + toHex(b);
}

@Component
export struct SettingsPanel {
  controller: TerminalController = new TerminalController();
  store: ConnectionStore | null = null;
  fontSize: number = 16;
  @Link themeName: string;
  @Link cursorStyle: number;
  @Link cursorBlink: boolean;
  @Link scrollbackLines: number;
  onFontSizeChange: (size: number) => void = (_size: number) => {};
  onClose: () => void = () => {};

  @State private tab: number = 0;
  @State private themeSearch: string = '';
  @State private themeList: string[] = [];
  @State private filteredThemes: string[] = [];

  aboutToAppear(): void {
    this.themeList = this.controller.getThemeList();
    this.filteredThemes = this.themeList;
  }

  private filterThemes(query: string): void {
    this.themeSearch = query;
    if (query.length === 0) {
      this.filteredThemes = this.themeList;
    } else {
      const q: string = query.toLowerCase();
      this.filteredThemes = this.themeList.filter((t: string) => t.toLowerCase().includes(q));
    }
  }

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
        .focusable(false)
        .onClick(() => { this.onClose(); })

        Text('设置')
          .layoutWeight(1)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)
          .textAlign(TextAlign.Center)

        // empty right spacer to balance header
        Row()
          .width(40)
          .height(40)
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })

      // Tab row
      Row({ space: 8 }) {
        Text('外观')
          .fontSize(13)
          .fontColor(this.tab === 0 ? Palette.base : Palette.textDim)
          .fontWeight(this.tab === 0 ? FontWeight.Medium : FontWeight.Normal)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(this.tab === 0 ? Palette.accent : Color.Transparent)
          .borderRadius(20)
          .focusable(false)
          .onClick(() => { this.tab = 0; })

        Text('终端')
          .fontSize(13)
          .fontColor(this.tab === 1 ? Palette.base : Palette.textDim)
          .fontWeight(this.tab === 1 ? FontWeight.Medium : FontWeight.Normal)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(this.tab === 1 ? Palette.accent : Color.Transparent)
          .borderRadius(20)
          .focusable(false)
          .onClick(() => { this.tab = 1; })
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })

      // Tab content
      Scroll() {
        Column({ space: 16 }) {
          if (this.tab === 0) {
            this.buildAppearanceTab()
          } else {
            this.buildTerminalTab()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.base)
  }

  @Builder
  private buildSectionHeader(title: string) {
    Text(title.toUpperCase())
      .fontSize(11)
      .fontColor(Palette.textDim)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ bottom: 6 })
  }

  @Builder
  private buildAppearanceTab() {
    // Font size section
    Column({ space: 0 }) {
      this.buildSectionHeader('字号')
      Row({ space: 2 }) {
        Row() {
          Text('A-')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.fontSize <= MIN_FONT_SIZE ? '#4A5568' : Palette.accent)
        }
        .width(36)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1520')
        .borderRadius(8)
        .focusable(false)
        .enabled(this.fontSize > MIN_FONT_SIZE)
        .onClick(() => {
          if (this.fontSize > MIN_FONT_SIZE) {
            this.onFontSizeChange(this.fontSize - 2);
          }
        })

        Text(this.fontSize.toString())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.accent)
          .width(32)
          .textAlign(TextAlign.Center)

        Row() {
          Text('A+')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.fontSize >= MAX_FONT_SIZE ? '#4A5568' : Palette.accent)
        }
        .width(36)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1520')
        .borderRadius(8)
        .focusable(false)
        .enabled(this.fontSize < MAX_FONT_SIZE)
        .onClick(() => {
          if (this.fontSize < MAX_FONT_SIZE) {
            this.onFontSizeChange(this.fontSize + 2);
          }
        })
      }
      .padding({ left: 4, right: 4, top: 3, bottom: 3 })
      .backgroundColor('#080F18')
      .borderRadius(18)
      .border({ width: 1, color: Palette.border })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')

    // Theme section
    Column({ space: 0 }) {
      this.buildSectionHeader('主题')
      TextInput({ text: this.themeSearch, placeholder: '搜索主题…' })
        .height(36)
        .fontSize(13)
        .fontColor(Palette.text)
        .placeholderColor(Palette.textDim)
        .backgroundColor(Palette.inputBg)
        .caretColor(Palette.accent)
        .borderRadius(8)
        .borderWidth(1)
        .borderColor(Palette.border)
        .margin({ bottom: 8 })
        .onChange((v: string) => { this.filterThemes(v); })

      List() {
        ForEach(this.filteredThemes, (item: string) => {
          ListItem() {
            Row({ space: 10 }) {
              // Color swatch
              Row()
                .width(20)
                .height(20)
                .borderRadius(4)
                .backgroundColor(swatchColor(item))
                .flexShrink(0)

              Text(item)
                .layoutWeight(1)
                .fontSize(13)
                .fontColor(Palette.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              if (this.themeName === item) {
                Text('✓')
                  .fontSize(13)
                  .fontColor(Palette.accent)
              }
            }
            .width('100%')
            .height(44)
            .padding({ left: 10, right: 10 })
            .focusable(false)
            .onClick(() => {
              this.themeName = item;
              this.controller.setTheme(item);
              if (this.store) {
                this.store.saveTheme(item);
              }
            })
          }
        })
      }
      .width('100%')
      .height(280)
      .backgroundColor(Palette.surface)
      .borderRadius(10)
      .border({ width: 1, color: Palette.border })
      .divider({ strokeWidth: 1, color: Palette.border })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')

    // Cursor style section
    Column({ space: 0 }) {
      this.buildSectionHeader('光标样式')
      Row({ space: 0 }) {
        ForEach([{ label: '块状', value: 0 }, { label: '下划线', value: 1 }, { label: '竖线', value: 2 }],
          (opt: { label: string; value: number }) => {
            Text(opt.label)
              .layoutWeight(1)
              .fontSize(13)
              .textAlign(TextAlign.Center)
              .fontColor(this.cursorStyle === opt.value ? Palette.base : Palette.text)
              .height(34)
              .backgroundColor(this.cursorStyle === opt.value ? Palette.accent : Color.Transparent)
              .borderRadius(8)
              .border({
                width: 1,
                color: this.cursorStyle === opt.value ? Palette.accent : Palette.border
              })
              .margin({ right: 4 })
              .focusable(false)
              .onClick(() => {
                this.cursorStyle = opt.value;
                this.controller.updateConfig({ cursorStyle: opt.value });
                if (this.store) {
                  this.store.saveTerminalPrefs({
                    cursorStyle: opt.value,
                    cursorBlink: this.cursorBlink,
                    scrollbackLines: this.scrollbackLines
                  });
                }
              })
          })
      }
      .width('100%')
      .padding(4)
      .backgroundColor(Palette.surface)
      .borderRadius(10)
      .border({ width: 1, color: Palette.border })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')

    // Cursor blink section
    Column({ space: 0 }) {
      this.buildSectionHeader('光标闪烁')
      Row() {
        Text('启用光标闪烁')
          .layoutWeight(1)
          .fontSize(14)
          .fontColor(Palette.text)
        Toggle({ type: ToggleType.Switch, isOn: this.cursorBlink })
          .selectedColor(Palette.accent)
          .focusable(false)
          .onChange((on: boolean) => {
            this.cursorBlink = on;
            this.controller.updateConfig({ cursorBlink: on });
            if (this.store) {
              this.store.saveTerminalPrefs({
                cursorStyle: this.cursorStyle,
                cursorBlink: on,
                scrollbackLines: this.scrollbackLines
              });
            }
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .backgroundColor(Palette.surface)
      .borderRadius(10)
      .border({ width: 1, color: Palette.border })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  private buildTerminalTab() {
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
  }
}
