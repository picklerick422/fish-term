import { UiTheme, REFINED_DARK_THEME, RADIUS_CARD, RADIUS_CONTROL } from '../theme/UiTheme';
import { SLOT_TYPE_OPTIONS, CONTENT_TYPE_OPTIONS, OptionEntry } from '../notifications/NotificationService';

@Component
export struct NotificationSettings {
  @Prop uiFontFamily: string = 'Inter';
  @Prop notifyEnabled: boolean = true;
  @Prop notifyCompleted: boolean = true;
  @Prop notifyAwaiting: boolean = true;
  @Prop notifyBackgroundOnly: boolean = true;
  @Prop notifyBell: boolean = false;
  onNotifyEnabledChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyCompletedChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyAwaitingChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyBackgroundOnlyChange: (v: boolean) => void = (_v: boolean) => {};
  onNotifyBellChange: (v: boolean) => void = (_v: boolean) => {};
  onTestNotification: (slotType: number, contentType: number, title: string, text: string) => void = (_s: number, _c: number, _t: string, _x: string) => {};

  @State private hoverTestNotify: boolean = false;
  @State private testSlotIdx: number = 1;       // default: SERVICE_INFORMATION
  @State private testContentIdx: number = 0;     // default: basic text
  @State private testTitle: string = 'fish-term 通知测试';
  @State private testText: string = '如果你能看到这条消息，说明系统通知功能正常。';
  @State private hoverTestSlotIdx: number = -1;
  @State private hoverTestContentIdx: number = -1;
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

  build() {
    Column({ space: 16 }) {
      Column({ space: 8 }) {
        // Master switch
        Column({ space: 0 }) {
          this.buildSectionHeader('通知开关')
          Row({ space: 12 }) {
            Text('启用通知')
              .fontSize(14)
              .fontColor(this.uiTheme.textPrimary)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notifyEnabled })
              .selectedColor(this.uiTheme.accent)
              .focusable(false)
              .onChange((on: boolean) => {
                this.notifyEnabled = on;
                this.onNotifyEnabledChange(on);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.uiTheme.bgSurface)
          .borderRadius(RADIUS_CARD)
          .border({ width: 1, color: this.uiTheme.border })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // Task completed notification
        Column({ space: 0 }) {
          this.buildSectionHeader('任务完成')
          Row({ space: 12 }) {
            Text('任务完成时通知')
              .fontSize(14)
              .fontColor(this.notifyEnabled ? this.uiTheme.textPrimary : this.uiTheme.textDim)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notifyCompleted })
              .selectedColor(this.uiTheme.accent)
              .focusable(false)
              .enabled(this.notifyEnabled)
              .onChange((on: boolean) => {
                this.notifyCompleted = on;
                this.onNotifyCompletedChange(on);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.uiTheme.bgSurface)
          .borderRadius(RADIUS_CARD)
          .border({ width: 1, color: this.uiTheme.border })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // Task awaiting input notification
        Column({ space: 0 }) {
          this.buildSectionHeader('任务暂停')
          Row({ space: 12 }) {
            Text('任务需要输入时通知')
              .fontSize(14)
              .fontColor(this.notifyEnabled ? this.uiTheme.textPrimary : this.uiTheme.textDim)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notifyAwaiting })
              .selectedColor(this.uiTheme.accent)
              .focusable(false)
              .enabled(this.notifyEnabled)
              .onChange((on: boolean) => {
                this.notifyAwaiting = on;
                this.onNotifyAwaitingChange(on);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.uiTheme.bgSurface)
          .borderRadius(RADIUS_CARD)
          .border({ width: 1, color: this.uiTheme.border })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // Background-only switch
        Column({ space: 0 }) {
          this.buildSectionHeader('通知策略')
          Row({ space: 12 }) {
            Text('仅在应用后台时通知')
              .fontSize(14)
              .fontColor(this.notifyEnabled ? this.uiTheme.textPrimary : this.uiTheme.textDim)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notifyBackgroundOnly })
              .selectedColor(this.uiTheme.accent)
              .focusable(false)
              .enabled(this.notifyEnabled)
              .onChange((on: boolean) => {
                this.notifyBackgroundOnly = on;
                this.onNotifyBackgroundOnlyChange(on);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.uiTheme.bgSurface)
          .borderRadius(RADIUS_CARD)
          .border({ width: 1, color: this.uiTheme.border })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // Bell detection switch — bell (\x07) is a common terminal signal but too
        // noisy by default (vim, backspace, tab failures, etc. also ring it).
        Column({ space: 0 }) {
          this.buildSectionHeader('通知信号')
          Row({ space: 12 }) {
            Text('检测终端响铃 (BEL)')
              .fontSize(14)
              .fontColor(this.notifyEnabled ? this.uiTheme.textPrimary : this.uiTheme.textDim)
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.notifyBell })
              .selectedColor(this.uiTheme.accent)
              .focusable(false)
              .enabled(this.notifyEnabled)
              .onChange((on: boolean) => {
                this.notifyBell = on;
                this.onNotifyBellChange(on);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.uiTheme.bgSurface)
          .borderRadius(RADIUS_CARD)
          .border({ width: 1, color: this.uiTheme.border })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        // Test notification section
        Column({ space: 8 }) {
          this.buildSectionHeader('通知测试')

          // Slot type selector
          Text('通知渠道')
            .fontSize(12)
            .fontColor(this.uiTheme.textDim)
            .width('100%')
          Row({ space: 0 }) {
            ForEach(SLOT_TYPE_OPTIONS, (opt: OptionEntry, idx: number) => {
              Text(opt.label)
                .fontSize(12)
                .textAlign(TextAlign.Center)
                .fontColor(this.testSlotIdx === idx ? this.uiTheme.bgBase : this.uiTheme.textPrimary)
                .height(30)
                .layoutWeight(1)
                .backgroundColor(this.testSlotIdx === idx ? this.uiTheme.accent
                  : (this.hoverTestSlotIdx === idx ? this.uiTheme.pressOverlay : Color.Transparent))
                .borderRadius(6)
                .margin({ right: 3 })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .focusable(false)
                .onHover((h: boolean) => { this.hoverTestSlotIdx = h ? idx : -1; })
                .onClick(() => { this.testSlotIdx = idx; })
            })
          }
          .width('100%')
          .padding(3)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })

          // Content type selector
          Text('内容类型')
            .fontSize(12)
            .fontColor(this.uiTheme.textDim)
            .width('100%')
          Row({ space: 0 }) {
            ForEach(CONTENT_TYPE_OPTIONS, (opt: OptionEntry, idx: number) => {
              Text(opt.label)
                .fontSize(12)
                .textAlign(TextAlign.Center)
                .fontColor(this.testContentIdx === idx ? this.uiTheme.bgBase : this.uiTheme.textPrimary)
                .height(30)
                .layoutWeight(1)
                .backgroundColor(this.testContentIdx === idx ? this.uiTheme.accent
                  : (this.hoverTestContentIdx === idx ? this.uiTheme.pressOverlay : Color.Transparent))
                .borderRadius(6)
                .margin({ right: 3 })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .focusable(false)
                .onHover((h: boolean) => { this.hoverTestContentIdx = h ? idx : -1; })
                .onClick(() => { this.testContentIdx = idx; })
            })
          }
          .width('100%')
          .padding(3)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })

          // Title input
          TextInput({ text: this.testTitle, placeholder: '通知标题' })
            .width('100%')
            .height(36)
            .fontSize(13)
            .fontColor(this.uiTheme.textPrimary)
            .placeholderColor(this.uiTheme.textDim)
            .backgroundColor(this.uiTheme.bgInput)
            .caretColor(this.uiTheme.accent)
            .borderRadius(RADIUS_CONTROL)
            .borderWidth(1)
            .borderColor(this.uiTheme.border)
            .onChange((v: string) => { this.testTitle = v; })

          // Text input
          TextInput({ text: this.testText, placeholder: '通知内容' })
            .width('100%')
            .height(36)
            .fontSize(13)
            .fontColor(this.uiTheme.textPrimary)
            .placeholderColor(this.uiTheme.textDim)
            .backgroundColor(this.uiTheme.bgInput)
            .caretColor(this.uiTheme.accent)
            .borderRadius(RADIUS_CONTROL)
            .borderWidth(1)
            .borderColor(this.uiTheme.border)
            .onChange((v: string) => { this.testText = v; })

          // Send button
          Row() {
            Text('发送测试通知')
              .fontSize(14)
              .fontColor(this.uiTheme.accent)
          }
          .width('100%')
          .height(40)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.hoverTestNotify ? this.uiTheme.bgElevated : this.uiTheme.bgSurface)
          .borderRadius(RADIUS_CARD)
          .border({ width: 1, color: this.uiTheme.accent })
          .animation({ duration: 120, curve: Curve.EaseOut })
          .focusable(false)
          .onHover((h: boolean) => { this.hoverTestNotify = h; })
          .onClick(() => {
            const st: number = SLOT_TYPE_OPTIONS[this.testSlotIdx].value;
            const ct: number = CONTENT_TYPE_OPTIONS[this.testContentIdx].value;
            this.onTestNotification(st, ct, this.testTitle, this.testText);
          })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
  }
}
