// Static release notes shipped with the app.
// Add a new entry at the top of the array for each release.

export interface ChangelogEntry {
  version: string;
  date: string;
  items: string[];
}

// Current app version; keep in sync with AppScope/app.json5 versionName.
export const APP_VERSION: string = '1.0.0';

export const CHANGELOG: ChangelogEntry[] = [
  {
    version: '1.0.0',
    date: '2026-06-27',
    items: [
      '初始发布',
      '基于 libghostty-vt 的终端解析与状态管理',
      'HarmonyOS XComponent + Native Drawing 自绘渲染',
      'WebSocket 连接 fish-agent，支持自动重连与心跳',
      '多标签终端，支持切换、关闭与拖拽排序',
      '外接键盘、鼠标、IME、剪贴板、右键菜单、选择、搜索',
      '主题、字号、光标样式、光标闪烁、滚动缓冲行数设置',
      '连接配置与 token 加密持久化',
      'DATA_TRANSFER 后台保活，降低切后台时连接中断的概率',
      '内置新手引导'
    ]
  }
];
