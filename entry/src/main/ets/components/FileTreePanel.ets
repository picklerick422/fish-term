/**
 * 文件树侧边栏面板
 *
 * VS Code 风格的可折叠文件浏览器。从当前终端工作目录 (CWD) 开始，
 * 支持懒加载展开子目录、点击跳转、右键菜单操作。
 *
 * Reactivity: ArkTS V1 中 @Prop 只在引用变化时触发重渲染。
 * 由于 FileTreeNode 树是原地修改的（非 @Observed），该组件
 * 每次 build() 时从 root 重新计算可见节点列表。
 * 交互处理函数操作节点状态后通过重新计算列表来触发 UI 更新。
 */

import { UiTheme, REFINED_DARK_THEME, RADIUS_CONTROL } from '../theme/UiTheme';
import { DEFAULT_UI_FONT } from '../theme/FontScale';
import { FileTreeNode } from '../filetree/FileTreeTypes';

// Layout constants — individual consts to satisfy arkts-no-untyped-obj-literals
const ROW_HEIGHT: number = 28;
const INDENT_WIDTH: number = 14;
const CHEV_WIDTH: number = 16;
const ICON_WIDTH: number = 20;

// Flat node: one visible row in the tree list.  We flatten the tree so
// ForEach can handle rendering without recursive @Builder (which has
// limitations in ArkTS strict mode).
class FlatNode {
  readonly treeNode: FileTreeNode;
  readonly indent: number;

  constructor(treeNode: FileTreeNode, indent: number) {
    this.treeNode = treeNode;
    this.indent = indent;
  }
}

@Component
export struct FileTreePanel {
  @Prop root: FileTreeNode | null = null;
  @Prop cwd: string = '';
  @Prop treeVersion: number = 0;
  @Prop uiFontFamily: string = DEFAULT_UI_FONT;
  @StorageLink('uiTheme') uiTheme: UiTheme = REFINED_DARK_THEME;

  onToggleDir: (path: string) => void = (_p: string) => {};
  onFileAction: (action: 'cd' | 'cat', path: string) => void = (_a, _p) => {};
  onWriteCommand: (cmd: string) => void = (_c: string) => {};
  onRefresh: () => void = () => {};

  @State private hoveredPath: string = '';

  // ── build ──────────────────────────────────────────────────────────────

  build() {
    Column() {
      // Header
      this.buildHeader()

      // Content
      if (!this.root) {
        this.buildEmptyState()
      } else {
        Scroll() {
          Column() {
            ForEach(this.computeFlatList(), (fn: FlatNode) => {
              this.buildNodeRow(fn)
            }, (fn: FlatNode) => fn.treeNode.path)
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.uiTheme.bgSurface)
  }

  // ── Header ─────────────────────────────────────────────────────────────

  @Builder
  buildHeader() {
    Row() {
      Text(this.cwd || '/')
        .fontSize(12)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textDim)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // Refresh button
      Row() {
        Text('↻')
          .fontSize(14)
          .fontColor(this.uiTheme.textDim)
      }
      .width(22)
      .height(22)
      .justifyContent(FlexAlign.Center)
      .borderRadius(RADIUS_CONTROL)
      .focusable(false)
      .onClick(() => { this.onRefresh(); })
    }
    .width('100%')
    .height(30)
    .padding({ left: 10, right: 6 })
    .border({ width: { bottom: 1 }, color: this.uiTheme.divider })
  }

  // ── Node row ───────────────────────────────────────────────────────────

  @Builder
  buildNodeRow(fn: FlatNode) {
    Row() {
      // Indentation
      if (fn.indent > 0) {
        Blank().width(fn.indent * INDENT_WIDTH)
      }

      // Chevron
      if (fn.treeNode.type === 'directory') {
        Text(fn.treeNode.expanded ? '▼' : '▶')
          .fontSize(10)
          .fontColor(this.uiTheme.textFaint)
          .width(CHEV_WIDTH)
          .textAlign(TextAlign.Center)
          .focusable(false)
          .onClick(() => { this.onChevronClick(fn.treeNode); })
      } else {
        Blank().width(CHEV_WIDTH)
      }

      // Icon
      Text(fn.treeNode.type === 'directory' ? '📁' : '📄')
        .fontSize(14)
        .width(ICON_WIDTH)
        .textAlign(TextAlign.Center)

      // Name
      Text(fn.treeNode.name)
        .fontSize(13)
        .fontFamily(this.uiFontFamily)
        .fontColor(this.uiTheme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .onClick(() => { this.onNameClick(fn.treeNode); })

      // Loading spinner
      if (fn.treeNode.loading) {
        LoadingProgress()
          .width(14)
          .height(14)
          .margin({ right: 4 })
      }
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 4, right: 6 })
    .backgroundColor(
      this.hoveredPath === fn.treeNode.path
        ? this.uiTheme.hoverOverlay
        : Color.Transparent
    )
    .animation({ duration: 100, curve: Curve.EaseOut })
    .focusable(false)
    .onHover((hover: boolean) => {
      this.hoveredPath = hover ? fn.treeNode.path : '';
    })
    .bindContextMenu(this.buildContextMenu(fn.treeNode), ResponseType.RightClick)

    // Error row
    if (fn.treeNode.error.length > 0) {
      this.buildErrorRow(fn)
    }
  }

  @Builder
  buildErrorRow(fn: FlatNode) {
    Row() {
      Blank().width((fn.indent + 1) * INDENT_WIDTH + CHEV_WIDTH)
      Text('⚠ ' + fn.treeNode.error)
        .fontSize(11)
        .fontColor(this.uiTheme.danger)
        .maxLines(2)
      Blank().width(6)
      Text('重试')
        .fontSize(11)
        .fontColor(this.uiTheme.accent)
        .focusable(false)
        .onClick(() => { this.onChevronClick(fn.treeNode); })
    }
    .width('100%')
    .padding({ left: 4, right: 6, bottom: 2 })
  }

  // ── Context menu ───────────────────────────────────────────────────────

  @Builder
  buildContextMenu(node: FileTreeNode) {
    Menu() {
      MenuItem({ content: '复制路径' })
        .onClick(() => {
          // Write path into terminal so user can paste it into a command
          this.onWriteCommand(`# ${node.path}`);
        })
      MenuItem({ content: '在终端中打开' })
        .onClick(() => {
          const target: string = node.type === 'directory' ? node.path : this.parentDir(node.path);
          this.onFileAction('cd', target);
        })
      MenuItem({ content: '新建文件…' })
        .onClick(() => { this.createWithTimestamp(node, 'file'); })
      MenuItem({ content: '新建目录…' })
        .onClick(() => { this.createWithTimestamp(node, 'directory'); })
      MenuItem({ content: '重命名…' })
        .onClick(() => {
          const p: string = node.path;
          this.onWriteCommand(`# rename: mv "${p}" "${this.parentDir(p)}/NEW_NAME"`);
        })
      MenuItem({ content: '删除…' })
        .onClick(() => {
          this.onWriteCommand(`rm -rf "${node.path}"`);
          setTimeout(() => { this.onRefresh(); }, 300);
        })
    }
  }

  // ── Empty state ────────────────────────────────────────────────────────

  @Builder
  buildEmptyState() {
    Column() {
      Text('📂')
        .fontSize(36)
        .opacity(0.3)
        .margin({ bottom: 8 })
      Text(this.cwd ? '加载中…' : '未连接')
        .fontSize(13)
        .fontColor(this.uiTheme.textFaint)
        .fontFamily(this.uiFontFamily)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ── Interaction handlers ──────────────────────────────────────────────

  private onChevronClick(node: FileTreeNode): void {
    if (node.type !== 'directory') {
      return;
    }
    if (node.children === null && !node.loading) {
      // Request lazy load from server
      node.loading = true;
      this.onToggleDir(node.path);
    } else if (node.children !== null) {
      // Toggle expand/collapse
      node.expanded = !node.expanded;
    }
  }

  private onNameClick(node: FileTreeNode): void {
    if (node.type === 'directory') {
      this.onFileAction('cd', node.path);
    } else {
      this.onFileAction('cat', node.path);
    }
  }

  private createWithTimestamp(node: FileTreeNode, kind: 'file' | 'directory'): void {
    const parentPath: string = node.type === 'directory' ? node.path : this.parentDir(node.path);
    const ts: number = Date.now();
    const name: string = kind === 'file' ? `new_file_${ts}.txt` : `new_dir_${ts}`;
    const cmd: string = kind === 'file'
      ? `touch "${parentPath}/${name}"`
      : `mkdir -p "${parentPath}/${name}"`;
    this.onWriteCommand(cmd);
    setTimeout(() => { this.onRefresh(); }, 500);
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  private parentDir(path: string): string {
    const idx: number = path.lastIndexOf('/');
    if (idx <= 0) {
      return '/';
    }
    return path.substring(0, idx);
  }

  private computeFlatList(): FlatNode[] {
    const list: FlatNode[] = [];
    if (this.root) {
      this.collectVisible(this.root, list);
    }
    return list;
  }

  private collectVisible(node: FileTreeNode, out: FlatNode[]): void {
    out.push(new FlatNode(node, node.depth));
    if (node.type === 'directory' && node.expanded && node.children) {
      for (const child of node.children) {
        this.collectVisible(child, out);
      }
    }
  }
}
