import { UiTheme, REFINED_DARK_THEME } from '../theme/UiTheme';
import { DEFAULT_UI_FONT } from '../theme/FontScale';

// Severity of the status banner, mapped by the page from the active tab state:
// Connecting/Reconnecting → 'warn', Error/Closed → 'danger', anything else → 'info'.
export type BannerKind = 'info' | 'warn' | 'danger';

// Thin banner over the terminal shown while the active tab is not connected.
// Gives the user live feedback plus a one-tap "立即重连".
// Extracted from pages/Index.ets (Task 2) — behavior preserved.
//
// The action button renders only when actionText is non-empty; the page passes
// '' while Connecting (no manual reconnect offered yet), matching the old
// `state !== DriverState.Connecting` check.
@Component
export struct StatusBanner {
  @Prop visible: boolean = false;
  @Prop text: string = '';
  @Prop kind: BannerKind = 'info';
  @Prop actionText: string = '';
  @Prop uiFontFamily: string = DEFAULT_UI_FONT;
  onAction: () => void = () => {};
  @StorageLink('uiTheme') private uiTheme: UiTheme = REFINED_DARK_THEME;

  // Dot color per kind — same values as the page's old dotColor() for the
  // states this banner can show (warn → uiTheme.warn, danger → uiTheme.danger).
  private dotColor(): string {
    if (this.kind === 'warn') {
      return this.uiTheme.warn;
    }
    if (this.kind === 'danger') {
      return this.uiTheme.danger;
    }
    return this.uiTheme.textDim;
  }

  build() {
    if (this.visible) {
      Row({ space: 8 }) {
        Text('●')
          .fontSize(9)
          .fontColor(this.dotColor())
        Text(this.text)
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.actionText.length > 0) {
          Text(this.actionText)
            .fontSize(12)
            .fontFamily(this.uiFontFamily)
            .fontColor(this.uiTheme.accent)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(6)
            .backgroundColor(this.uiTheme.pressOverlay)
            .focusable(false)
            .onClick(() => { this.onAction(); })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.uiTheme.bgSurface)
      .alignItems(VerticalAlign.Center)
    }
  }
}
