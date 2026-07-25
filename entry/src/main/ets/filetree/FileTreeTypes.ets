/**
 * 文件树功能共享类型定义
 *
 * 定义 WebSocket list_dir 协议的请求/响应结构，
 * 以及客户端 UI 树节点（含交互状态）。
 */

// 服务端返回的单个目录条目
export interface FileEntry {
  name: string;
  type: 'file' | 'directory' | 'symlink';
  size?: number;
  mtime?: number;   // unix timestamp millis
  mode?: string;     // e.g. "drwxr-xr-x"
}

// 服务端 list_dir 响应
export interface ListDirResult {
  type: 'list_dir_result';
  path: string;
  entries: FileEntry[];
  truncated?: boolean;
  error?: string;
}

// 客户端 UI 树节点（含交互状态）
// 注意：ArkTS 中 class 字段必须初始化，否则 Strict Mode 报错
export class FileTreeNode {
  name: string = '';
  type: 'file' | 'directory' | 'symlink' = 'file';
  path: string = '';
  size?: number;
  mtime?: number;
  children: FileTreeNode[] | null = null;  // null=未加载, []=已加载但无子节点
  expanded: boolean = false;
  loading: boolean = false;
  error: string = '';
  depth: number = 0;
}
