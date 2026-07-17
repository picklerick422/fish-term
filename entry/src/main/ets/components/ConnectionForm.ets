import { Palette } from '../theme/Palette';
import { DEFAULT_UI_FONT } from '../theme/FontScale';

// Connection form — shown full-screen on first run (no tabs) and as an overlay
// for "新建连接". Extracted from pages/Index.ets (Task 2) — behavior preserved.
//
// Field values are @Link-ed back to the page, which owns validation, profile
// persistence and tab creation (onConnect → connectFromForm). The form only
// keeps purely-local UI state (focusedField).
@Component
export struct ConnectionForm {
  @Link host: string;
  @Link port: string;
  @Link token: string;
  @Link tls: boolean;
  @Link rememberToken: boolean;
  @Link formError: string;
  @Prop uiFontFamily: string = DEFAULT_UI_FONT;
  // true when opened as a "new connection" overlay over existing tabs — shows
  // the cancel affordance and switches the title to 新建连接.
  @Prop showNewConnection: boolean = false;
  onConnect: () => void = () => {};
  onCancel: () => void = () => {};

  @State private focusedField: string = '';

  build() {
    Column() {
      // cancel affordance when opened as a "new connection" overlay
      if (this.showNewConnection) {
        Row() {
          Text('✕ 取消')
            .fontSize(14)
            .fontColor(Palette.textDim)
            .focusable(false)
            .onClick(() => { this.onCancel(); })
        }
        .width('100%')
        .constraintSize({ maxWidth: 420 })
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 10 })
      }

      Column({ space: 10 }) {
        Image($r('app.media.app_logo'))
          .width(72)
          .height(72)
          .borderRadius(16)
        Text(this.showNewConnection ? '新建连接' : 'fish-term')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.text)
        Text('connect to fish-agent')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(Palette.textDim)
      }
      .margin({ bottom: 20 })

      Column({ space: 14 }) {
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
            .onFocus(() => { this.focusedField = 'host'; })
            .onBlur(() => { if (this.focusedField === 'host') { this.focusedField = ''; } })
            .onChange((v: string) => { this.host = v; })
            .onSubmit(() => { this.onConnect(); })
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
            .onFocus(() => { this.focusedField = 'port'; })
            .onBlur(() => { if (this.focusedField === 'port') { this.focusedField = ''; } })
            .onChange((v: string) => { this.port = v; })
            .onSubmit(() => { this.onConnect(); })
        }
        .width('100%')

        Row({ space: 10 }) {
          TextInput({ text: this.token, placeholder: 'token' })
            .layoutWeight(1)
            .height(44)
            .type(InputType.Password)
            .fontColor(Palette.text)
            .placeholderColor(Palette.textDim)
            .backgroundColor(Palette.inputBg)
            .caretColor(Palette.accent)
            .borderRadius(8)
            .borderWidth(1)
            .borderColor(this.focusedField === 'token' ? Palette.accent : Palette.border)
            .onFocus(() => { this.focusedField = 'token'; })
            .onBlur(() => { if (this.focusedField === 'token') { this.focusedField = ''; } })
            .onChange((v: string) => { this.token = v; })
            .onSubmit(() => { this.onConnect(); })
        }
        .width('100%')

        Row() {
          Text('TLS (wss)')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.tls })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => { this.tls = on; })
        }
        .width('100%')

        Row() {
          Text('记住 token（加密存储）')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(Palette.text)
          Toggle({ type: ToggleType.Switch, isOn: this.rememberToken })
            .selectedColor(Palette.accent)
            .onChange((on: boolean) => { this.rememberToken = on; })
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
          .onClick(() => { this.onConnect(); })
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
