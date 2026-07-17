import { UiTheme, REFINED_DARK_THEME, RADIUS_CARD, RADIUS_CONTROL } from '../theme/UiTheme';
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
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  build() {
    Column() {
      // cancel affordance when opened as a "new connection" overlay
      if (this.showNewConnection) {
        Row() {
          Text('✕ 取消')
            .fontSize(14)
            .fontColor(this.uiTheme.textDim)
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
          .fontColor(this.uiTheme.textPrimary)
        Text('connect to fish-agent')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
      }
      .margin({ bottom: 20 })

      Column({ space: 14 }) {
        Row({ space: 10 }) {
          TextInput({ text: this.host, placeholder: '主机 host' })
            .layoutWeight(2)
            .height(44)
            .fontColor(this.uiTheme.textPrimary)
            .placeholderColor(this.uiTheme.textDim)
            .backgroundColor(this.uiTheme.bgInput)
            .caretColor(this.uiTheme.accent)
            .borderRadius(RADIUS_CONTROL)
            .borderWidth(1)
            .borderColor(this.focusedField === 'host' ? this.uiTheme.accent : this.uiTheme.border)
            .onFocus(() => { this.focusedField = 'host'; })
            .onBlur(() => { if (this.focusedField === 'host') { this.focusedField = ''; } })
            .onChange((v: string) => { this.host = v; })
            .onSubmit(() => { this.onConnect(); })
          TextInput({ text: this.port, placeholder: '端口' })
            .layoutWeight(1)
            .height(44)
            .type(InputType.Number)
            .fontColor(this.uiTheme.textPrimary)
            .placeholderColor(this.uiTheme.textDim)
            .backgroundColor(this.uiTheme.bgInput)
            .caretColor(this.uiTheme.accent)
            .borderRadius(RADIUS_CONTROL)
            .borderWidth(1)
            .borderColor(this.focusedField === 'port' ? this.uiTheme.accent : this.uiTheme.border)
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
            .fontColor(this.uiTheme.textPrimary)
            .placeholderColor(this.uiTheme.textDim)
            .backgroundColor(this.uiTheme.bgInput)
            .caretColor(this.uiTheme.accent)
            .borderRadius(RADIUS_CONTROL)
            .borderWidth(1)
            .borderColor(this.focusedField === 'token' ? this.uiTheme.accent : this.uiTheme.border)
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
            .fontColor(this.uiTheme.textPrimary)
          Toggle({ type: ToggleType.Switch, isOn: this.tls })
            .selectedColor(this.uiTheme.accent)
            .onChange((on: boolean) => { this.tls = on; })
        }
        .width('100%')

        Row() {
          Text('记住 token（加密存储）')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(this.uiTheme.textPrimary)
          Toggle({ type: ToggleType.Switch, isOn: this.rememberToken })
            .selectedColor(this.uiTheme.accent)
            .onChange((on: boolean) => { this.rememberToken = on; })
        }
        .width('100%')

        if (this.formError.length > 0) {
          Text('⚠ ' + this.formError)
            .fontSize(13)
            .fontColor(this.uiTheme.danger)
            .width('100%')
        }

        Button('连 接')
          .width('100%')
          .height(46)
          .fontSize(16)
          .fontColor(this.uiTheme.bgBase)
          .backgroundColor(this.uiTheme.accent)
          .borderRadius(RADIUS_CARD)
          .onClick(() => { this.onConnect(); })
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding(20)
      .backgroundColor(this.uiTheme.bgSurface)
      .borderRadius(12)
      .borderWidth(1)
      .borderColor(this.uiTheme.border)
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.uiTheme.bgBase)
  }
}
