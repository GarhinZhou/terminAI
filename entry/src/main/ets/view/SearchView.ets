// Ctrl+K command palette for local sessions and spaces.
import { canonicalSessionCwd, TerminalSession } from '../model/TerminalSession';
import { Theme } from '../common/Theme';
import { BrandIcon } from '../common/BrandIcon';
import { IconName, UiIcon } from '../common/Icons';
import { SessionNumberBadge } from '../common/SessionNumberBadge';

// Input Kit KeyCode.KEYCODE_DPAD_UP / KEYCODE_DPAD_DOWN.
const KEYCODE_ARROW_UP = 2012;
const KEYCODE_ARROW_DOWN = 2013;
const KEYCODE_ESCAPE = 2070;

class SearchEntry {
  id: string = '';
  idx: number = 0;
  name: string = '';
  sequence: number = 0;
  kind: string = '';
  iconKind: string = '';
  space: string = '';
  deviceId: string = 'local';
  deviceName: string = '本机';
  isSpace: boolean = false;
}

@CustomDialog
export struct SearchView {
  controller?: CustomDialogController;
  getSessions: () => TerminalSession[] = () => [];
  onPick: (idx: number) => void = () => {};
  onPickSpace: (cwd: string, deviceId: string) => void = () => {};

  @State private query: string = '';
  @State private highlighted: number = 0;
  @StorageProp('isDark') isDark: boolean = true;
  private resultScroller: Scroller = new Scroller();

  private displayCwd(path: string): string {
    if (path === '/storage/Users/currentUser') {
      return '~';
    }
    if (path.startsWith('/storage/Users/currentUser/')) {
      return '~/' + path.substring('/storage/Users/currentUser/'.length);
    }
    return path;
  }

  private programLabel(session: TerminalSession): string {
    if (session.agentKind.length > 0) {
      return session.agentKind;
    }
    if (session.cmd.length === 0) {
      return 'zsh';
    }
    const parts = session.cmd.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : session.cmd;
  }

  private results(): SearchEntry[] {
    const query = this.query.trim().toLowerCase();
    const sessions = this.getSessions();
    const result: SearchEntry[] = [];
    for (let index = 0; index < sessions.length; index++) {
      const session = sessions[index];
      const canonicalCwd = canonicalSessionCwd(session);
      if (query.length > 0 &&
        session.name.toLowerCase().indexOf(query) < 0 &&
        session.sequence.toString().indexOf(query) < 0 &&
        this.programLabel(session).toLowerCase().indexOf(query) < 0 &&
        this.displayCwd(canonicalCwd).toLowerCase().indexOf(query) < 0) {
        continue;
      }
      const entry = new SearchEntry();
      entry.id = 'session_' + session.uid.toString();
      entry.idx = index;
      entry.name = session.name;
      entry.sequence = session.sequence;
      entry.kind = this.programLabel(session);
      entry.iconKind = session.agentIconKind.length > 0 ? session.agentIconKind : entry.kind;
      entry.space = this.displayCwd(canonicalCwd);
      entry.deviceId = session.deviceId;
      entry.deviceName = session.deviceName;
      result.push(entry);
    }

    const seen: string[] = [];
    for (const session of sessions) {
      const canonicalCwd = canonicalSessionCwd(session);
      if (query.length > 0 &&
        this.displayCwd(canonicalCwd).toLowerCase().indexOf(query) < 0) {
        continue;
      }
      const spaceKey = session.deviceId + '\t' + canonicalCwd;
      if (seen.indexOf(spaceKey) >= 0) {
        continue;
      }
      seen.push(spaceKey);
      const entry = new SearchEntry();
      entry.id = 'space_' + spaceKey;
      entry.idx = -1;
      entry.name = this.displayCwd(canonicalCwd);
      entry.space = canonicalCwd;
      entry.deviceId = session.deviceId;
      entry.deviceName = session.deviceName;
      entry.isSpace = true;
      result.push(entry);
    }
    return result;
  }

  private choose(entry: SearchEntry): void {
    if (entry.isSpace) {
      this.onPickSpace(entry.space, entry.deviceId);
    } else {
      this.onPick(entry.idx);
    }
    this.controller?.close();
  }

  private chooseHighlighted(): void {
    const result = this.results();
    if (this.highlighted >= 0 && this.highlighted < result.length) {
      this.choose(result[this.highlighted]);
    }
  }

  private moveHighlight(delta: number, count: number): void {
    if (count <= 0) {
      this.highlighted = 0;
      return;
    }
    this.highlighted = Math.max(0, Math.min(this.highlighted + delta, count - 1));
    const target = this.highlighted;
    setTimeout(() => {
      this.resultScroller.scrollToIndex(target, false, ScrollAlign.AUTO);
    }, 0);
  }

  private handleSearchKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    const result = this.results();
    if (event.keyCode === KEYCODE_ARROW_UP) {
      this.moveHighlight(-1, result.length);
      return true;
    }
    if (event.keyCode === KEYCODE_ARROW_DOWN) {
      this.moveHighlight(1, result.length);
      return true;
    }
    if (event.keyCode === KEYCODE_ESCAPE) {
      this.controller?.close();
      return true;
    }
    return false;
  }

  @Builder
  hint(key: string, label: string) {
    Row() {
      Text(key)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.tertiary(this.isDark))
        .padding({ left: 5, right: 5 })
        .height(18)
        .backgroundColor(Theme.input(this.isDark))
        .border({ width: 1, color: Theme.border(this.isDark), radius: 5 })
        .borderRadius(5)
      Text(label)
        .fontSize(11)
        .fontColor(Theme.faintText(this.isDark))
        .margin({ left: 5 })
    }
  }

  @Builder
  resultRow(entry: SearchEntry, index: number) {
    Row() {
      Column() {
        if (entry.isSpace) {
          UiIcon({ name: IconName.Folder, iconSize: 16, color: Theme.subText(this.isDark) })
        } else if (entry.kind === 'zsh') {
          UiIcon({ name: IconName.Terminal, iconSize: 16, color: Theme.subText(this.isDark) })
        } else {
          BrandIcon({
            kind: entry.iconKind,
            iconSize: 16,
            color: Theme.subText(this.isDark),
            isDark: this.isDark
          })
        }
      }
      .width(28)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.input(this.isDark))
      .borderRadius(7)

      Column() {
        Row() {
          Text(entry.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 300 })
          if (!entry.isSpace) {
            SessionNumberBadge({ value: entry.sequence, isDark: this.isDark })
              .margin({ left: 6 })
          }
          Blank()
        }
        .width('100%')
        Text((entry.isSpace ? '空间' : entry.kind + ' · ' + entry.space) + ' · ' + entry.deviceName)
          .fontSize(12)
          .fontColor(Theme.tertiary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 9 })

      UiIcon({
        name: IconName.ChevronRight,
        iconSize: 13,
        color: Theme.faintText(this.isDark)
      })
    }
    .width('100%')
    .height(52)
    .padding({ left: 9, right: 10 })
    .borderRadius(9)
    .backgroundColor(index === this.highlighted ? Theme.selected(this.isDark) : '#00000000')
    .onHover((isHover: boolean) => {
      if (isHover) {
        this.highlighted = index;
      }
    })
    .onClick(() => { this.choose(entry); })
    .accessibilityText((entry.isSpace ? '空间 ' : '会话 ') + entry.name +
      (entry.isSpace ? '' : ' ' + entry.sequence.toString()))
    .accessibilitySelected(index === this.highlighted)
  }

  build() {
    Column() {
      Row() {
        UiIcon({ name: IconName.Search, iconSize: 17, color: Theme.tertiary(this.isDark) })
          .margin({ right: 9 })
        TextInput({
          placeholder: '搜索智能体、终端和空间…',
          text: this.query
        })
          .fontSize(15)
          .height(48)
          .layoutWeight(1)
          .backgroundColor('#00000000')
          .fontColor(Theme.text(this.isDark))
          .placeholderColor(Theme.tertiary(this.isDark))
          .padding(0)
          .defaultFocus(true)
          .caretColor(Theme.accent(this.isDark))
          .onChange((value: string) => {
            this.query = value;
            this.highlighted = 0;
          })
          .onSubmit(() => { this.chooseHighlighted(); })
          // TextInput owns keyboard focus, so direction/Esc handling must live
          // here instead of relying on the dialog container to receive bubbling.
          .onKeyEvent((event: KeyEvent) => this.handleSearchKey(event))
      }
      .width('100%')
      .height(50)
      .padding({ left: 14, right: 14 })

      Divider()
        .color(Theme.divider(this.isDark))
        .strokeWidth(1)

      if (this.results().length === 0) {
        Column() {
          UiIcon({
            name: this.getSessions().length === 0 ? IconName.EmptyTerminal : IconName.Search,
            iconSize: 28,
            color: Theme.faintText(this.isDark)
          })
          Text(this.getSessions().length === 0 ? '暂无会话' : '未找到结果')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.tertiary(this.isDark))
            .margin({ top: 10 })
          Text(this.getSessions().length === 0 ?
            '请先启动智能体或终端，再使用 Ctrl K 快速切换。' :
            '可尝试输入会话名称、程序或文件夹。')
            .fontSize(12)
            .fontColor(Theme.faintText(this.isDark))
            .textAlign(TextAlign.Center)
            .margin({ top: 5 })
        }
        .width('100%')
        .height(132)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2, scroller: this.resultScroller }) {
          ForEach(this.results(), (entry: SearchEntry, index: number) => {
            ListItem() {
              this.resultRow(entry, index)
            }
          }, (entry: SearchEntry) => entry.id)
        }
        .width('100%')
        .constraintSize({ maxHeight: 330 })
        .scrollBar(BarState.Auto)
        .padding(8)
        .edgeEffect(EdgeEffect.Spring)
      }

      Divider()
        .color(Theme.divider(this.isDark))
        .strokeWidth(1)

      Row({ space: 14 }) {
        this.hint('↑↓', '选择')
        this.hint('↩', '打开')
        Blank()
        this.hint('Esc', '取消')
      }
      .width('100%')
      .height(36)
      .padding({ left: 14, right: 14 })
    }
    .width(480)
    .backgroundColor(Theme.panel(this.isDark))
    .border({ width: 1, color: Theme.border(this.isDark), radius: 14 })
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
    .focusable(true)
  }
}
