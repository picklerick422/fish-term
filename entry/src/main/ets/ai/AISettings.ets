import { UiTheme, REFINED_DARK_THEME, RADIUS_CONTROL } from '../theme/UiTheme';
import { AIConnectConfig, DEFAULT_AI_CONFIG } from './AITypes';

/**
 * AI 配置子面板
 *
 * 配置 fish-ai 连接参数：host / port / token / model / API provider。
 * 可嵌入 SettingsPanel 或作为独立 sheet 使用。
 */
@Component
export struct AISettings {
  @Prop aiHost: string = DEFAULT_AI_CONFIG.host;
  @Prop aiPort: string = DEFAULT_AI_CONFIG.port.toString();
  @Prop aiToken: string = DEFAULT_AI_CONFIG.token;
  @Prop aiModel: string = '';
  @Prop aiBaseUrl: string = '';
  @Prop aiApiKey: string = '';
  onHostChange: (host: string) => void = (_h: string) => {};
  onPortChange: (port: string) => void = (_p: string) => {};
  onTokenChange: (token: string) => void = (_t: string) => {};
  onModelChange: (model: string) => void = (_m: string) => {};
  onBaseUrlChange: (url: string) => void = (_u: string) => {};
  onApiKeyChange: (key: string) => void = (_k: string) => {};
  @Prop uiFontFamily: string = 'Inter';
  @StorageLink('uiTheme') uiTheme: UiTheme = REFINED_DARK_THEME;

  build() {
    Column({ space: 14 }) {
      // 标题
      Text('AI 连接配置')
        .fontSize(15)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textPrimary)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      // Host
      Column({ space: 4 }) {
        Text('fish-ai 主机地址')
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
        TextInput({ text: this.aiHost, placeholder: '172.16.105.2' })
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .placeholderColor(this.uiTheme.textFaint)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })
          .height(36)
          .width('100%')
          .onChange((value: string) => { this.onHostChange(value); })
      }

      // Port
      Column({ space: 4 }) {
        Text('端口')
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
        TextInput({ text: this.aiPort, placeholder: '8766' })
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .placeholderColor(this.uiTheme.textFaint)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })
          .height(36)
          .width('100%')
          .type(InputType.Number)
          .onChange((value: string) => { this.onPortChange(value); })
      }

      // Token
      Column({ space: 4 }) {
        Text('认证 Token')
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
        TextInput({ text: this.aiToken, placeholder: '自动生成则留空' })
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .placeholderColor(this.uiTheme.textFaint)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })
          .height(36)
          .width('100%')
          .type(InputType.Password)
          .onChange((value: string) => { this.onTokenChange(value); })
      }

      Divider()
        .color(this.uiTheme.divider)
        .height(1)
        .width('100%')

      // 模型
      Column({ space: 4 }) {
        Text('模型 (可选)')
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
        TextInput({ text: this.aiModel, placeholder: '默认: claude-sonnet-5-20250929' })
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .placeholderColor(this.uiTheme.textFaint)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })
          .height(36)
          .width('100%')
          .onChange((value: string) => { this.onModelChange(value); })
      }

      // API Base URL
      Column({ space: 4 }) {
        Text('API Base URL (可选，DeepSeek 填 https://api.deepseek.com/anthropic)')
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
        TextInput({ text: this.aiBaseUrl, placeholder: '留空使用 Anthropic 默认' })
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .placeholderColor(this.uiTheme.textFaint)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })
          .height(36)
          .width('100%')
          .onChange((value: string) => { this.onBaseUrlChange(value); })
      }

      // API Key
      Column({ space: 4 }) {
        Text('API Key (可选，覆盖环境变量)')
          .fontSize(12)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textDim)
          .width('100%')
        TextInput({ text: this.aiApiKey, placeholder: '留空使用 fish-ai 服务器环境变量' })
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .placeholderColor(this.uiTheme.textFaint)
          .backgroundColor(this.uiTheme.bgInput)
          .borderRadius(RADIUS_CONTROL)
          .border({ width: 1, color: this.uiTheme.border })
          .height(36)
          .width('100%')
          .type(InputType.Password)
          .onChange((value: string) => { this.onApiKeyChange(value); })
      }
    }
    .width('100%')
  }
}
