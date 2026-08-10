import { webview } from '@kit.ArkWeb';
import { AIChatService } from './AIChatService';
import { AIEvent, AISessionState } from './AITypes';
import { UiTheme, REFINED_DARK_THEME } from '../theme/UiTheme';

/**
 * AI Chat 面板 — WebView 容器 + JS 通信桥
 *
 * 职责：
 * 1. 加载 rawfile/ai_chat/index.html
 * 2. 注册 JS proxy (harmonyOS.postMessage) → 接收前端操作
 * 3. 转发 AI 事件到 WebView (runJavaScript → window.onEvent)
 * 4. 在 onPageEnd 时注入主题 CSS 变量
 * 5. 主题变化时更新 CSS 变量
 */
@Component
export struct AIChatPanel {
  @Prop aiService: AIChatService;
  @StorageLink('uiTheme') uiTheme: UiTheme = REFINED_DARK_THEME;
  private controller: webview.WebviewController = new webview.WebviewController();
  private themeInjected: boolean = false;

  aboutToAppear(): void {
    // 注册 JS → ArkTS 通信桥
    try {
      this.controller.registerJavaScriptProxy({
        postMessage: (json: string): void => {
          this.handleAction(json);
        }
      }, 'harmonyOS', ['postMessage']);
    } catch (e) {
      console.error('fish-ai registerJavaScriptProxy failed: ' + JSON.stringify(e));
    }

    // 页面加载完成后注入主题
    this.controller.onPageEnd = (): void => {
      this.injectTheme();
      this.themeInjected = true;
    };

    // 绑定 AI 事件 → WebView
    this.aiService.onEvent = (event: AIEvent): void => {
      this.postEvent(event);
    };

    // 加载前端页面
    this.controller.loadUrl('resource://rawfile/ai_chat/index.html');
  }

  /**
   * 处理来自 WebView 前端的操作
   */
  private handleAction(json: string): void {
    try {
      const msg: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const action: string = (msg['action'] as string) || '';

      switch (action) {
        case 'send':
          this.aiService.send((msg['text'] as string) || '');
          break;
        case 'cancel':
          this.aiService.cancel();
          break;
        case 'open_file':
          // 把打开文件转为 AI 指令
          const path: string = (msg['path'] as string) || '';
          if (path.length > 0) {
            this.aiService.send('请读取并展示 ' + path + ' 的内容');
          }
          break;
        case 'permission_response':
          // 转发权限响应（预留）
          break;
        default:
          console.error('fish-ai unknown action: ' + action);
      }
    } catch (e) {
      console.error('fish-ai handleAction parse failed: ' + json);
    }
  }

  /**
   * ArkTS → JS: 推送 AI 事件到 WebView
   */
  private postEvent(event: AIEvent): void {
    if (!this.themeInjected) {
      // 页面还没加载完，延迟重试
      setTimeout(() => { this.postEvent(event); }, 100);
      return;
    }
    try {
      const json: string = JSON.stringify(event);
      this.controller.runJavaScript(`window.onEvent(${json})`);
    } catch (e) {
      console.error('fish-ai runJavaScript failed: ' + JSON.stringify(e));
    }
  }

  /**
   * 注入主题 CSS 变量到 WebView
   */
  private injectTheme(): void {
    const t: UiTheme = this.uiTheme;
    const css: string = [
      `--color-accent:${t.accent}`,
      `--color-bg-base:${t.bgBase}`,
      `--color-bg-surface:${t.bgSurface}`,
      `--color-bg-chrome:${t.bgChrome}`,
      `--color-text-primary:${t.textPrimary}`,
      `--color-text-secondary:${t.textDim}`,
      `--color-border:${t.border}`,
      `--color-danger:${t.danger}`,
      `--color-success:${t.success}`,
    ].join(';');

    try {
      this.controller.runJavaScript(
        `var s=document.documentElement.style;` +
        `'${css}'.split(';').forEach(function(p){var kv=p.split(':');if(kv.length===2){s.setProperty(kv[0],kv[1])}});`
      );
    } catch (e) {
      console.error('fish-ai injectTheme failed: ' + JSON.stringify(e));
    }
  }

  build() {
    Web({ src: 'resource://rawfile/ai_chat/index.html', controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .width('100%')
      .height('100%')
      .focusable(false)
  }
}
