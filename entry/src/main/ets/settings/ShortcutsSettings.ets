import { Palette } from '../theme/Palette';

@Component
export struct ShortcutsSettings {
  @Prop uiFontFamily: string = 'Inter';

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

  build() {
    Column({ space: 16 }) {
      Column({ space: 8 }) {
        this.buildSectionHeader('终端快捷键')
        this.buildShortcutRow('Ctrl+Shift+C', '复制选中文本')
        this.buildShortcutRow('Ctrl+Shift+V', '粘贴')
        this.buildShortcutRow('Shift+Tab', '反向制表（back-tab）')
        this.buildShortcutRow('滚轮', '上下滚动缓冲区')
        this.buildShortcutRow('右键', '打开上下文菜单')
        this.buildSectionHeader('应用快捷键')
        this.buildShortcutRow('Ctrl+Shift+T', '新建标签页')
        this.buildShortcutRow('Ctrl+Shift+W', '关闭当前标签页')
        this.buildShortcutRow('Ctrl+Shift+F', '在终端内查找')
        this.buildShortcutRow('Ctrl+Tab', '切换到下一个标签页')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
  }
}
