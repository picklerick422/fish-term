import { TerminalController } from 'libghostty_ohos';
import { Palette } from '../theme/Palette';
import { ConnectionStore, TerminalPrefs } from '../store/ConnectionStore';
import { MIN_FONT_SIZE, MAX_FONT_SIZE } from '../theme/FontScale';

interface CursorOpt {
  label: string;
  value: number;
}

// Theme preview colors: [background, foreground, cursor, accent1, accent2, accent3]
interface ThemeColors {
  bg: string;
  fg: string;
  cursor: string;
  a1: string;
  a2: string;
  a3: string;
}

const FALLBACK_COLORS: ThemeColors = {
  bg: '#11161D', fg: '#F4F7FB', cursor: '#3DD6C4',
  a1: '#FF6B6B', a2: '#3DD6C4', a3: '#84B4F8'
};

// Curated, widely-loved dark themes — pinned to the top of the list.
const RECOMMENDED_THEMES: string[] = [
  'Aizen_Dark',
  'Dracula',
  'TokyoNight_Night',
  'Catppuccin_Mocha',
  'Nord',
  'Gruvbox_Dark_Hard',
  'One_Half_Dark',
  'Monokai_Pro',
  'GitHub_Dark_Default',
  'Ayu_Mirage',
  'Night_Owl',
  'Everforest_Dark_Hard',
  'Kanagawa_Wave',
  'Rose_Pine',
  'Nightfox',
  'Snazzy',
  'Cobalt2',
  'Solarized_Dark_Higher_Contrast'
];

@Component
export struct SettingsPanel {
  controller: TerminalController = new TerminalController();
  store: ConnectionStore | null = null;
  @Prop fontSize: number = 16;
  @Prop initialTab: number = 0;
  @Prop statusText: string = '空闲';
  @Prop statusColor: string = '#8A94A6';
  @Prop hostLabel: string = '';
  @Prop themeName: string = '';
  @Prop cursorStyle: number = 0;
  @Prop cursorBlink: boolean = true;
  @Prop scrollbackLines: number = 20000;
  onThemeChange: (name: string) => void = (_name: string) => {};
  onCursorStyleChange: (v: number) => void = (_v: number) => {};
  onCursorBlinkChange: (v: boolean) => void = (_v: boolean) => {};
  onScrollbackChange: (v: number) => void = (_v: number) => {};
  onFontSizeChange: (size: number) => void = (_size: number) => {};
  onReplayGuide: () => void = () => {};
  onClose: () => void = () => {};

  @State private tab: number = 0;
  @State private themeSearch: string = '';
  @State private themeList: string[] = [];
  @State private filteredThemes: string[] = [];
  @State private hoverBack: boolean = false;
  @State private hoverTabIdx: number = -1;
  // Drives the native horizontal slide between sub-pages.
  private subTabs: TabsController = new TabsController();
  @State private hoverTheme: string = '';
  @State private hoverFontMinus: boolean = false;
  @State private hoverFontPlus: boolean = false;
  private recommendedSet: Set<string> = new Set<string>();
  private colorCache: Map<string, ThemeColors> = new Map<string, ThemeColors>();

  aboutToAppear(): void {
    this.tab = this.initialTab;
    const all: string[] = this.controller.getThemeList();
    // Pin recommended themes (that actually exist) to the top, rest follow.
    const present: Set<string> = new Set<string>();
    for (let i: number = 0; i < all.length; i++) {
      present.add(all[i]);
    }
    const ordered: string[] = [];
    for (let i: number = 0; i < RECOMMENDED_THEMES.length; i++) {
      const name: string = RECOMMENDED_THEMES[i];
      if (present.has(name)) {
        ordered.push(name);
        this.recommendedSet.add(name);
      }
    }
    for (let i: number = 0; i < all.length; i++) {
      if (!this.recommendedSet.has(all[i])) {
        ordered.push(all[i]);
      }
    }
    this.themeList = ordered;
    this.filteredThemes = ordered;
  }

  // Memoized accurate preview colors pulled from the native theme parser.
  private colorsFor(name: string): ThemeColors {
    const cached: ThemeColors | undefined = this.colorCache.get(name);
    if (cached) {
      return cached;
    }
    const raw: string[] = this.controller.getThemeColors(name);
    let c: ThemeColors = FALLBACK_COLORS;
    if (raw && raw.length >= 6) {
      c = { bg: raw[0], fg: raw[1], cursor: raw[2], a1: raw[3], a2: raw[4], a3: raw[5] };
    }
    this.colorCache.set(name, c);
    return c;
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
      // Header: ← + left-aligned title, with the connection status on the right.
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
        .onClick(() => { this.onClose(); })

        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Palette.text)

        // connection status, pushed to the right
        Row({ space: 6 }) {
          Text('●')
            .fontSize(9)
            .fontColor(this.statusColor)
          Text(this.statusText)
            .fontSize(12)
            .fontColor(Palette.textDim)
          Text(this.hostLabel)
            .fontSize(12)
            .fontColor(Palette.textDim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
        .padding({ right: 8 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })

      // Tab row (fixed under the header)
      Row({ space: 6 }) {
        this.buildTabButton('外观', 0)
        this.buildTabButton('终端', 1)
        this.buildTabButton('快捷键', 2)
        this.buildTabButton('关于', 3)
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })

      // Body: native Tabs gives a smooth horizontal slide between sub-pages.
      // The native bar is hidden (barHeight 0); our pill row above drives it
      // via subTabs.changeIndex(). Each page scrolls independently.
      Tabs({ controller: this.subTabs, index: this.tab }) {
        TabContent() { this.settingsPage(0) }
        TabContent() { this.settingsPage(1) }
        TabContent() { this.settingsPage(2) }
        TabContent() { this.settingsPage(3) }
      }
      .barHeight(0)
      .scrollable(false)
      .animationDuration(280)
      .layoutWeight(1)
      .onChange((i: number) => { this.tab = i; })
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
  private buildTabButton(label: string, index: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.tab === index ? Palette.base : Palette.textDim)
      .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor(this.tab === index ? Palette.accent
        : (this.hoverTabIdx === index ? '#1FFFFFFF' : Color.Transparent))
      .borderRadius(20)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverTabIdx = h ? index : -1; })
      .onClick(() => {
        // Only drive the controller — setting this.tab here would make the
        // Tabs `index` binding jump instantly and skip the slide animation.
        // onChange() updates this.tab once the slide starts.
        if (index !== this.tab) {
          this.subTabs.changeIndex(index);
        }
      })
  }

  // One settings sub-page: each scrolls independently inside its TabContent.
  @Builder
  private settingsPage(t: number) {
    Scroll() {
      Column({ space: 16 }) {
        if (t === 0) {
          this.buildAppearanceTab()
        } else if (t === 1) {
          this.buildTerminalTab()
        } else if (t === 2) {
          this.buildShortcutsTab()
        } else {
          this.buildAboutTab()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // A single "key: description" shortcut row.
  @Builder
  private buildShortcutRow(keys: string, desc: string) {
    Row() {
      Text(keys)
        .fontSize(12)
        .fontColor(Palette.accent)
        .fontWeight(FontWeight.Medium)
      Text(desc)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(Palette.text)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(40)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Palette.surface)
    .borderRadius(10)
    .border({ width: 1, color: Palette.border })
  }

  @Builder
  private buildShortcutsTab() {
    Column({ space: 8 }) {
      this.buildSectionHeader('终端快捷键')
      this.buildShortcutRow('Ctrl+Shift+C', '复制选中文本')
      this.buildShortcutRow('Ctrl+Shift+V', '粘贴')
      this.buildShortcutRow('Shift+Tab', '反向制表（back-tab）')
      this.buildShortcutRow('滚轮', '上下滚动缓冲区')
      this.buildShortcutRow('右键', '打开上下文菜单')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  private buildAboutRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(Palette.textDim)
      Text(value)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(Palette.text)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(40)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Palette.surface)
    .borderRadius(10)
    .border({ width: 1, color: Palette.border })
  }

  @Builder
  private buildAboutTab() {
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
          .fontColor(Palette.text)
        Text('HarmonyOS 终端 · 连接 fish-agent')
          .fontSize(12)
          .fontColor(Palette.textDim)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      Column({ space: 8 }) {
        this.buildSectionHeader('信息')
        this.buildAboutRow('版本', '1.0.0')
        this.buildAboutRow('终端引擎', 'libghostty (ghostty VT)')
        this.buildAboutRow('渲染', 'Native Drawing')
        this.buildAboutRow('主题数量', this.themeList.length.toString())
        this.buildAboutRow('传输', 'WebSocket (fish-agent)')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row() {
        Text('查看新手引导')
          .fontSize(14)
          .fontColor(Palette.accent)
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Palette.surface)
      .borderRadius(10)
      .border({ width: 1, color: Palette.border })
      .focusable(false)
      .onClick(() => { this.onReplayGuide(); })

      Text('© 2026 fish-term · 基于开源组件构建')
        .fontSize(11)
        .fontColor(Palette.textDim)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
    }
    .width('100%')
  }

  // Live preview of the currently selected theme: a mock terminal snippet
  // rendered with that theme's real bg / fg / accent colors.
  @Builder
  private buildThemePreview() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('user@fish')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).a2)
        Text('~/project')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).a3)
        Text('$ ls')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).fg)
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('README.md')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).a1)
        Text('src')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).a2)
        Text('build.zig')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).a3)
      }
      .width('100%')

      Row({ space: 0 }) {
        Text('$ ')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.colorsFor(this.themeName).fg)
        // blinking-cursor stand-in
        Text(' ')
          .fontSize(12)
          .fontFamily('monospace')
          .backgroundColor(this.colorsFor(this.themeName).cursor)
          .width(8)
          .height(15)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(this.colorsFor(this.themeName).bg)
    .borderRadius(10)
    .border({ width: 1, color: Palette.border })
  }

  @Builder
  private buildAppearanceTab() {
    // Live theme preview
    Column({ space: 0 }) {
      this.buildSectionHeader('预览')
      this.buildThemePreview()
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')

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
        .backgroundColor(this.hoverFontMinus ? '#1FFFFFFF' : '#0D1520')
        .borderRadius(8)
        .animation({ duration: 100, curve: Curve.EaseOut })
        .focusable(false)
        .enabled(this.fontSize > MIN_FONT_SIZE)
        .onHover((h: boolean) => { this.hoverFontMinus = h; })
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
        .backgroundColor(this.hoverFontPlus ? '#1FFFFFFF' : '#0D1520')
        .borderRadius(8)
        .animation({ duration: 100, curve: Curve.EaseOut })
        .focusable(false)
        .enabled(this.fontSize < MAX_FONT_SIZE)
        .onHover((h: boolean) => { this.hoverFontPlus = h; })
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
              // Accurate mini preview: theme background tile with fg "A" + accent dots
              Stack({ alignContent: Alignment.Center }) {
                Text('A')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.colorsFor(item).fg)
                Row({ space: 2 }) {
                  Row().width(4).height(4).borderRadius(2).backgroundColor(this.colorsFor(item).a1)
                  Row().width(4).height(4).borderRadius(2).backgroundColor(this.colorsFor(item).a2)
                  Row().width(4).height(4).borderRadius(2).backgroundColor(this.colorsFor(item).a3)
                }
                .position({ x: 4, y: 24 })
              }
              .width(34)
              .height(34)
              .borderRadius(7)
              .backgroundColor(this.colorsFor(item).bg)
              .border({ width: 1, color: Palette.border })
              .flexShrink(0)
              .clip(true)

              Column({ space: 1 }) {
                Text(item.split('_').join(' '))
                  .fontSize(13)
                  .fontColor(Palette.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.recommendedSet.has(item)) {
                  Text('★ 推荐')
                    .fontSize(10)
                    .fontColor(Palette.accent)
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.themeName === item) {
                Text('✓')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Palette.accent)
              }
            }
            .width('100%')
            .height(48)
            .padding({ left: 10, right: 12 })
            .backgroundColor(this.hoverTheme === item ? '#17FFFFFF' : Color.Transparent)
            .animation({ duration: 100, curve: Curve.EaseOut })
            .focusable(false)
            .onHover((h: boolean) => { this.hoverTheme = h ? item : ''; })
            .onClick(() => {
              this.themeName = item;
              this.onThemeChange(item);
              this.controller.setTheme(item);
              if (this.store) {
                this.store.saveTheme(item);
              }
            })
          }
        })
      }
      .width('100%')
      .height(300)
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
          (opt: CursorOpt) => {
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
                this.onCursorStyleChange(opt.value);
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
            this.onCursorBlinkChange(on);
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
  }
}
