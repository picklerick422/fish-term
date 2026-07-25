/**
 * 文件树侧边栏面板
 *
 * VS Code 风格的可折叠文件浏览器。从当前终端工作目录 (CWD) 开始，
 * 支持懒加载展开子目录、点击跳转、右键菜单操作。
 *
 * Reactivity: ArkTS V1 中 @Prop 只在引用变化时触发重渲染。
 * 由于 FileTreeNode 树是原地修改的（非 @Observed），该组件
 * 每次 build() 时从 root 重新计算可见节点列表。
 * 交互处理函数操作节点状态后通过 renderVersion 来触发 UI 更新。
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
  // Bump after any local node mutation (expand/collapse toggle, loading flag)
  // so ArkUI re-runs build() → computeFlatList() with the updated tree state.
  // FileTreeNode is NOT @Observed, so without this the UI would freeze until
  // the next treeVersion prop change from the parent.
  @State private renderVersion: number = 0;
  // Context menu hover tracking (single string, same pattern as TabStrip).
  @State private hoverMenuAction: string = '';

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
            // renderVersion is referenced to force re-computation when local
            // tree-node mutations (expand/collapse) change the visible set.
            ForEach(this.computeFlatList(this.renderVersion), (fn: FlatNode) => {
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
    .backgroundColor(this.uiTheme.bgChrome)
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
        this.refreshIcon()
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
        Row() {
          Text(fn.treeNode.expanded ? '▾' : '▸')
            .fontSize(9)
            .fontColor(this.uiTheme.textFaint)
        }
        .width(CHEV_WIDTH)
        .justifyContent(FlexAlign.Center)
        .focusable(false)
        .onClick(() => { this.onChevronClick(fn.treeNode); })
      } else {
        Blank().width(CHEV_WIDTH)
      }

      // Icon
      this.nodeTypeIcon(fn.treeNode.type)

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
      Row() {
        Text('!')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.uiTheme.danger)
          .width(14)
          .height(14)
          .textAlign(TextAlign.Center)
          .border({ width: 1.2, color: this.uiTheme.danger })
          .borderRadius(7)
      }
      .margin({ right: 4 })
      Text(fn.treeNode.error)
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
  // Matches TabStrip context menu style: custom Column with hover-aware
  // rows, dividers, and unified card styling (no system Menu/MenuItem).

  @Builder
  buildContextMenu(node: FileTreeNode) {
    Column() {
      // 复制路径
      Row({ space: 8 }) {
        this.menuCopyIcon()
        Text('复制路径')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'copy_path' ? this.uiTheme.hoverOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'copy_path' : ''; })
      .onClick(() => {
        this.hoverMenuAction = '';
        this.onWriteCommand(`# ${node.path}`);
      })

      Divider().color(this.uiTheme.border).width('100%').margin({ left: 8, right: 8 })

      // 在终端中打开
      Row({ space: 8 }) {
        this.menuTerminalIcon()
        Text('在终端中打开')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'open_term' ? this.uiTheme.hoverOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'open_term' : ''; })
      .onClick(() => {
        this.hoverMenuAction = '';
        const target: string = node.type === 'directory' ? node.path : this.parentDir(node.path);
        this.onFileAction('cd', target);
      })

      Divider().color(this.uiTheme.border).width('100%').margin({ left: 8, right: 8 })

      // 新建文件
      Row({ space: 8 }) {
        this.menuNewFileIcon()
        Text('新建文件…')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'new_file' ? this.uiTheme.hoverOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'new_file' : ''; })
      .onClick(() => {
        this.hoverMenuAction = '';
        this.createWithTimestamp(node, 'file');
      })

      // 新建目录
      Row({ space: 8 }) {
        this.menuNewDirIcon()
        Text('新建目录…')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'new_dir' ? this.uiTheme.hoverOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'new_dir' : ''; })
      .onClick(() => {
        this.hoverMenuAction = '';
        this.createWithTimestamp(node, 'directory');
      })

      Divider().color(this.uiTheme.border).width('100%').margin({ left: 8, right: 8 })

      // 重命名
      Row({ space: 8 }) {
        this.menuRenameIcon()
        Text('重命名…')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'rename' ? this.uiTheme.hoverOverlay : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'rename' : ''; })
      .onClick(() => {
        this.hoverMenuAction = '';
        const p: string = node.path;
        this.onWriteCommand(`# rename: mv "${p}" "${this.parentDir(p)}/NEW_NAME"`);
      })

      Divider().color(this.uiTheme.border).width('100%').margin({ left: 8, right: 8 })

      // 删除
      Row({ space: 8 }) {
        this.menuDeleteIcon()
        Text('删除…')
          .fontSize(13)
          .fontFamily(this.uiFontFamily)
          .fontColor(this.uiTheme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(5)
      .backgroundColor(this.hoverMenuAction === 'delete' ? this.uiTheme.dangerBg : Color.Transparent)
      .animation({ duration: 120, curve: Curve.EaseOut })
      .focusable(false)
      .onHover((h: boolean) => { this.hoverMenuAction = h ? 'delete' : ''; })
      .onClick(() => {
        this.hoverMenuAction = '';
        this.onWriteCommand(`rm -rf "${node.path}"`);
        setTimeout(() => { this.onRefresh(); }, 300);
      })
    }
    .width(170)
    .padding(4)
    .backgroundColor(this.uiTheme.bgSurface)
    .borderRadius(RADIUS_CONTROL)
    .border({ width: 1, color: this.uiTheme.border })
    .shadow({ radius: 12, color: this.uiTheme.shadowCard, offsetY: 6 })
  }

  // ── Empty state ────────────────────────────────────────────────────────

  @Builder
  buildEmptyState() {
    Column() {
      // Simple folder shape — accent-colored rounded rect at larger size
      Row()
        .width(36)
        .height(28)
        .backgroundColor(this.uiTheme.accent)
        .borderRadius(4)
        .opacity(0.25)
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
      // Request lazy load from server — show spinner immediately
      node.loading = true;
      this.renderVersion++;
      this.onToggleDir(node.path);
    } else if (node.children !== null) {
      // Toggle expand/collapse — re-render immediately
      node.expanded = !node.expanded;
      this.renderVersion++;
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

  // ── Icon builders ─────────────────────────────────────────────────────
  @Builder
  nodeTypeIcon(type: string) {
    if (type === 'directory') {
      // Folder: accent-colored filled rounded rectangle
      Row()
        .width(14)
        .height(11)
        .backgroundColor(this.uiTheme.accent)
        .borderRadius(2.5)
        .opacity(0.85)
        .margin({ left: 3, right: 3 })
    } else {
      // File: dim outlined rounded rectangle
      Row()
        .width(14)
        .height(11)
        .backgroundColor(Color.Transparent)
        .border({ width: 1.2, color: this.uiTheme.textFaint })
        .borderRadius(2.5)
        .opacity(0.6)
        .margin({ left: 3, right: 3 })
    }
  }

  @Builder
  refreshIcon() {
    // Thin circular arrow — geometric, not emoji
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: 12, height: 12 })
        .fill(Color.Transparent)
        .stroke(this.uiTheme.textDim)
        .strokeWidth(1.4)
      // Arrowhead: small triangle indicating direction
      Text('↺')
        .fontSize(10)
        .fontColor(this.uiTheme.textDim)
    }
    .width(14)
    .height(14)
  }

  // ── Menu icon builders ────────────────────────────────────────────────
  // Thin line-art icons matching TabStrip's design language.

  @Builder
  menuCopyIcon() {
    // Two overlapping rectangles — "copy" metaphor
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width(8).height(9)
        .backgroundColor(Color.Transparent)
        .border({ width: 1.2, color: this.uiTheme.textDim })
        .borderRadius(1.5)
        .margin({ left: 3, top: 3 })
      Row()
        .width(8).height(9)
        .backgroundColor(this.uiTheme.bgSurface)
        .border({ width: 1.2, color: this.uiTheme.textDim })
        .borderRadius(1.5)
    }
    .width(14).height(14)
  }

  @Builder
  menuTerminalIcon() {
    // Terminal prompt symbol: ">_"
    Text('>_')
      .fontSize(11)
      .fontFamily('monospace')
      .fontColor(this.uiTheme.textDim)
  }

  @Builder
  menuNewFileIcon() {
    // Document with a "+" badge
    Stack({ alignContent: Alignment.TopEnd }) {
      Row()
        .width(10).height(12)
        .backgroundColor(Color.Transparent)
        .border({ width: 1.2, color: this.uiTheme.textDim })
        .borderRadius(1.5)
      Text('+')
        .fontSize(8)
        .fontColor(this.uiTheme.accent)
        .fontWeight(FontWeight.Bold)
        .margin({ right: -2, top: -2 })
    }
    .width(14).height(14)
  }

  @Builder
  menuNewDirIcon() {
    // Folder with a "+" badge
    Stack({ alignContent: Alignment.TopEnd }) {
      Row()
        .width(12).height(9)
        .backgroundColor(this.uiTheme.accent)
        .borderRadius(2)
        .opacity(0.7)
      Text('+')
        .fontSize(8)
        .fontColor(this.uiTheme.accent)
        .fontWeight(FontWeight.Bold)
        .margin({ right: -2, top: -2 })
    }
    .width(14).height(14)
  }

  @Builder
  menuRenameIcon() {
    // Pencil/edit glyph: diagonal line
    Text('/')
      .fontSize(12)
      .fontColor(this.uiTheme.textDim)
      .fontWeight(FontWeight.Lighter)
  }

  @Builder
  menuDeleteIcon() {
    // Trash bin: simple outlined rectangle with a lid
    Column({ space: 0 }) {
      Row()
        .width(12).height(2)
        .backgroundColor(this.uiTheme.textDim)
        .borderRadius(1)
      Row()
        .width(10).height(9)
        .backgroundColor(Color.Transparent)
        .border({ width: 1.2, color: this.uiTheme.textDim })
        .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 2, bottomRight: 2 })
    }
    .width(14).height(13)
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  private parentDir(path: string): string {
    const idx: number = path.lastIndexOf('/');
    if (idx <= 0) {
      return '/';
    }
    return path.substring(0, idx);
  }

  private computeFlatList(_version: number): FlatNode[] {
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
