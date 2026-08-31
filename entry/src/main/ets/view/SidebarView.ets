// Compact 2in1 sidebar inspired by herdrm's information hierarchy.
import { AgentRunState, canonicalSessionCwd, TerminalSession } from '../model/TerminalSession';
import { Theme } from '../common/Theme';
import { IconName, UiIcon } from '../common/Icons';
import { BrandIcon } from '../common/BrandIcon';
import { SessionNumberBadge } from '../common/SessionNumberBadge';
import { ManagedDevice, decodeDevices, LOCAL_DEVICE_ID } from '../model/ManagedDevice';

/** A space is represented by its working directory in the local-only port. */
@Component
struct SessionSelectionMark {
  @Prop selected: boolean = false;
  @Prop accent: string = '';

  build() {
    Row()
      .width(3)
      .height(18)
      .borderRadius(2)
      .backgroundColor(this.accent)
      .opacity(this.selected ? 1 : 0)
      .margin({ right: 6 })
      .accessibilityLevel('no')
  }
}

/** Keep a reused ForEach row subscribed to its observed session title. */
@Component
struct SessionTitleLabel {
  @ObjectLink session: TerminalSession;
  @Prop maxWidth: number = 80;
  @Prop medium: boolean = false;
  @StorageProp('isDark') isDark: boolean = true;

  build() {
    Text(this.session.name)
      .fontSize(14)
      .fontWeight(this.medium ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(Theme.text(this.isDark))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: this.maxWidth })
      .accessibilityText(this.session.name)
  }
}

class SpaceLite {
  cwd: string = '';
  deviceId: string = 'local';
  deviceName: string = '本机';
  count: number = 0;

  key(): string {
    return this.deviceId + '\t' + this.cwd;
  }
}

@Component
export struct SidebarView {
  @Prop sidebarWidth: number = 280;
  @Link sessions: TerminalSession[];
  @Link currentId: number;
  onNewAgent: () => void = () => {};
  onNewAgentIn: (cwd: string, deviceId: string) => void = () => {};
  onSelectSpace: (deviceId: string, cwd: string) => void = () => {};
  onCloseSpace: (cwd: string, deviceId: string) => void = () => {};
  onNewSpace: () => void = () => {};
  onSearch: () => void = () => {};
  onCloseSession: (s: TerminalSession) => void = () => {};
  /** Selection by uid so Index resolves against its fresh session array. */
  onSelectSession: (uid: number) => void = () => {};
  onRenameSession: (s: TerminalSession, name: string) => void = () => {};
  onOpenSettings: () => void = () => {};
  onOpenDevices: () => void = () => {};
  onCollapse: () => void = () => {};
  onTitleTouch: (event: TouchEvent) => void = () => {};

  @State private renamingUid: number = -1;
  @State private renameText: string = '';
  @State private renameInputHovered: boolean = false;
  @State private selectedSpace: string = '';
  /** Keep only a stable primitive in V1 state; resolve the row again when a menu action fires. */
  @State private menuSessionUid: number = -1;
  @State private menuSpace: string = '';
  @State private menuSpaceDeviceId: string = 'local';
  @State private hoveredKey: string = '';
  @State private pressedKey: string = '';
  @State private focusedKey: string = '';
  @State private spacesExpanded: boolean = true;
  @State private agentsExpanded: boolean = true;
  @State private terminalsExpanded: boolean = true;
  @StorageProp('selectedSpace') @Watch('onSpaceSync') spaceFromStorage: string = '';
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('accent') accent: string = '';
  @StorageProp('devicesEncoded') devicesEncoded: string = '';
  @StorageProp('selectedDeviceId') selectedDeviceId: string = '';

  onSpaceSync(): void {
    this.selectedSpace = this.spaceFromStorage;
  }

  private accentOf(): string {
    return this.accent.length > 0 ? this.accent : Theme.accent(this.isDark);
  }

  private rowBackground(key: string, selected: boolean): string {
    if (this.pressedKey === key) {
      return Theme.pressed(this.isDark);
    }
    if (this.hoveredKey === key) {
      return Theme.hover(this.isDark);
    }
    return selected ? Theme.accentWash(this.isDark) : '#00000000';
  }

  private rowScale(key: string): number {
    return this.pressedKey === key ? 0.985 : 1;
  }

  private focusWidth(key: string): number {
    return this.focusedKey === key ? 2 : 0;
  }

  private isSectionExpanded(key: string): boolean {
    if (key === 'agents_header') {
      return this.agentsExpanded;
    }
    return this.terminalsExpanded;
  }

  private sessionKey(prefix: string, item: TerminalSession): string {
    return prefix + item.uid.toString();
  }

  private isSessionSelected(item: TerminalSession): boolean {
    const idx = this.sessions.findIndex((s: TerminalSession) => s.uid === item.uid);
    return this.currentId === idx;
  }

  private onFocusKey(key: string): void {
    this.focusedKey = key;
  }

  private onBlurKey(key: string): void {
    if (this.focusedKey === key) {
      this.focusedKey = '';
    }
  }

  private onHoverKey(key: string, isHover: boolean): void {
    this.hoveredKey = isHover ? key : '';
    if (!isHover && this.pressedKey === key) {
      this.pressedKey = '';
    }
  }

  private onMouseFeedback(key: string, event: MouseEvent): void {
    if (event.button !== MouseButton.Left) {
      return;
    }
    this.pressedKey = event.action === MouseAction.Press ? key : '';
  }

  private onTouchFeedback(key: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedKey = key;
    } else if ((event.type === TouchType.Up || event.type === TouchType.Cancel) &&
      this.pressedKey === key) {
      this.pressedKey = '';
    }
  }

  private displayCwd(path: string): string {
    if (path === '/storage/Users/currentUser') {
      return '~';
    }
    if (path.startsWith('/storage/Users/currentUser/')) {
      return '~/' + path.substring('/storage/Users/currentUser/'.length);
    }
    return path;
  }

  private programLabel(s: TerminalSession): string {
    if (s.agentKind.length > 0) {
      return s.agentKind;
    }
    if (s.cmd.length === 0) {
      return s.shellName.length > 0 ? s.shellName : 'zsh';
    }
    const parts = s.cmd.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : s.cmd;
  }

  private programIconKind(s: TerminalSession): string {
    return s.agentIconKind.length > 0 ? s.agentIconKind : this.programLabel(s);
  }

  private stateColor(item: TerminalSession): string {
    if (item.activityState === AgentRunState.Outputting) {
      return Theme.working(this.isDark);
    }
    if (item.activityState === AgentRunState.WaitingInput) {
      return Theme.warning(this.isDark);
    }
    if (item.activityState === AgentRunState.ReturnedShell) {
      return Theme.success(this.isDark);
    }
    if (item.activityState === AgentRunState.Exited) {
      return Theme.danger(this.isDark);
    }
    return Theme.tertiary(this.isDark);
  }

  private stateBackground(item: TerminalSession): string {
    if (item.activityState === AgentRunState.Outputting) {
      return Theme.workingWash(this.isDark);
    }
    if (item.activityState === AgentRunState.ReturnedShell) {
      return Theme.successWash(this.isDark);
    }
    return Theme.input(this.isDark);
  }

  private kindColor(s: TerminalSession): string {
    const kind = this.programLabel(s).toLowerCase();
    if (kind.includes('claude')) {
      return '#D97757';
    }
    if (kind.includes('codex')) {
      return '#21B58B';
    }
    if (kind.includes('kimi')) {
      return '#7D8DF5';
    }
    if (kind.includes('gemini')) {
      return '#5B8DEF';
    }
    if (kind.includes('grok')) {
      return this.isDark ? '#C7C8CC' : '#55565A';
    }
    return this.accentOf();
  }

  /**
   * Keep the source array as an explicit argument. ArkUI V1 then records the
   * @Link read at the build call site, including remote sessions appended
   * asynchronously after SSH initialization.
   */
  private spaces(source: TerminalSession[]): SpaceLite[] {
    const result: SpaceLite[] = [];
    for (const session of source) {
      if (!this.matchesDevice(session)) {
        continue;
      }
      const canonicalCwd = canonicalSessionCwd(session);
      let space = result.find((item: SpaceLite) =>
        item.cwd === canonicalCwd && item.deviceId === session.deviceId);
      if (space === undefined) {
        space = new SpaceLite();
        space.cwd = canonicalCwd;
        space.deviceId = session.deviceId;
        space.deviceName = session.deviceName;
        result.push(space);
      }
      space.count++;
    }
    return result;
  }

  private matchesDevice(session: TerminalSession): boolean {
    return this.selectedDeviceId.length === 0 || session.deviceId === this.selectedDeviceId;
  }

  private currentDevice(): ManagedDevice | null {
    if (this.selectedDeviceId.length === 0) {
      return null;
    }
    const found = decodeDevices(this.devicesEncoded).find((device: ManagedDevice) =>
      device.id === this.selectedDeviceId);
    return found === undefined ? null : found;
  }

  private deviceFooterLabel(): string {
    const device = this.currentDevice();
    return device === null ? '全部设备' : device.name;
  }

  private deviceFooterColor(): string {
    const device = this.currentDevice();
    if (device === null || device.isLocal()) {
      return Theme.success(this.isDark);
    }
    const scoped = this.sessions.filter((session: TerminalSession) => session.deviceId === device.id);
    if (scoped.some((session: TerminalSession) => session.alive)) {
      return Theme.success(this.isDark);
    }
    if (scoped.some((session: TerminalSession) => session.exitCode === 255)) {
      return Theme.danger(this.isDark);
    }
    return Theme.faintText(this.isDark);
  }

  private deviceTagBackground(deviceId: string): string {
    if (deviceId === LOCAL_DEVICE_ID) {
      return this.isDark ? '#8062C987' : '#2B8650';
    }
    return this.isDark ? '#80E0B36A' : '#A96C25';
  }

  private deviceTagTextColor(): string {
    return '#FFFFFF';
  }

  private sessionSpaceKey(session: TerminalSession): string {
    return session.deviceId + '\t' + canonicalSessionCwd(session);
  }

  private scopeSessionCount(source: TerminalSession[]): number {
    return source.filter((session: TerminalSession) => this.matchesDevice(session)).length;
  }

  private agents(source: TerminalSession[]): TerminalSession[] {
    return source.filter((session: TerminalSession) =>
      session.cmd.length > 0 && this.matchesDevice(session) &&
      (this.selectedSpace.length === 0 || this.sessionSpaceKey(session) === this.selectedSpace));
  }

  private shells(source: TerminalSession[]): TerminalSession[] {
    return source.filter((session: TerminalSession) =>
      session.cmd.length === 0 && this.matchesDevice(session) &&
      (this.selectedSpace.length === 0 || this.sessionSpaceKey(session) === this.selectedSpace));
  }

  private beginRename(session: TerminalSession): void {
    this.renamingUid = session.uid;
    this.renameText = session.name;
    setTimeout(() => { this.focusRenameInput(session); }, 0);
  }

  private renameInputId(session: TerminalSession): string {
    return 'session_rename_' + session.uid.toString();
  }

  private focusRenameInput(session: TerminalSession): void {
    if (this.renamingUid !== session.uid) return;
    try {
      this.getUIContext().getFocusController().requestFocus(this.renameInputId(session));
    } catch (error) {
      console.error('TERMINAI focus rename input failed: ' + JSON.stringify(error));
    }
  }

  private menuSession(): TerminalSession | null {
    const found = this.sessions.find((session: TerminalSession) => session.uid === this.menuSessionUid);
    return found === undefined ? null : found;
  }

  private beginMenuFor(session: TerminalSession): void {
    this.menuSessionUid = session.uid;
  }

  private clearSessionMenu(): void {
    this.menuSessionUid = -1;
  }

  private menuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: '重命名',
        action: () => {
          const target = this.menuSession();
          this.clearSessionMenu();
          if (target !== null) {
            this.beginRename(target);
          }
        }
      },
      {
        value: '关闭',
        action: () => {
          const target = this.menuSession();
          this.clearSessionMenu();
          if (target !== null) {
            this.onCloseSession(target);
          }
        }
      }
    ];
    return items;
  }

  @Builder
  contextMenuBuilder() {
    Menu() {
      MenuItem({ content: '重命名' })
        .onClick(() => {
          const target = this.menuSession();
          this.clearSessionMenu();
          if (target !== null) {
            this.beginRename(target);
          }
        })
      MenuItem({ content: '关闭' })
        .onClick(() => {
          const target = this.menuSession();
          this.clearSessionMenu();
          if (target !== null) {
            this.onCloseSession(target);
          }
        })
    }
  }

  @Builder
  spaceMenuBuilder() {
    Menu() {
      MenuItem({ content: '在此空间新建智能体' })
        .onClick(() => {
          if (this.menuSpace.length > 0) {
            this.onNewAgentIn(this.menuSpace, this.menuSpaceDeviceId);
          }
          this.menuSpace = '';
        })
      MenuItem({ content: '关闭空间内全部会话' })
        .onClick(() => {
          if (this.menuSpace.length > 0) {
            this.onCloseSpace(this.menuSpace, this.menuSpaceDeviceId);
          }
          this.menuSpace = '';
        })
    }
  }

  @Builder
  actionRow(icon: IconName, key: string, label: string, shortcut: string, action: () => void) {
    Row() {
      UiIcon({ name: icon, iconSize: 16, color: Theme.subText(this.isDark) })
        .width(24)
      Text(label)
        .fontSize(15)
        .fontColor(Theme.subText(this.isDark))
        .margin({ left: 6 })
      Blank()
      Text(shortcut)
        .fontSize(11)
        .fontColor(Theme.faintText(this.isDark))
    }
    .width('100%')
    .height(36)
    .padding({ left: 7, right: 9 })
    .borderRadius(8)
    .backgroundColor(this.rowBackground(key, false))
    .border({ width: this.focusWidth(key), color: this.accentOf(), radius: 8 })
    .scale({ x: this.rowScale(key), y: this.rowScale(key) })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey(key); })
    .onBlur(() => { this.onBlurKey(key); })
    .onHover((isHover: boolean) => { this.onHoverKey(key, isHover); })
    .onMouse((event: MouseEvent) => { this.onMouseFeedback(key, event); })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback(key, event); })
    .onClick(() => { action(); })
    .accessibilityGroup(true)
    .accessibilityText(label + '，快捷键 ' + shortcut)
  }

  @Builder
  sectionHeader(icon: IconName, title: string, key: string, onToggle: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row() {
        UiIcon({ name: icon, iconSize: 14, color: Theme.subText(this.isDark) })
          .margin({ right: 8 })
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.subText(this.isDark))
        UiIcon({
          name: IconName.ChevronDown,
          iconSize: 11,
          color: Theme.faintText(this.isDark)
        })
          .margin({ left: 6 })
          .rotate({ angle: this.isSectionExpanded(key) ? 0 : -90 })
        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .height(36)
    .padding(0)
    .borderRadius(8)
    .backgroundColor(this.rowBackground(key, false))
    .border({ width: this.focusWidth(key), color: this.accentOf(), radius: 8 })
    .scale({ x: this.rowScale(key), y: this.rowScale(key) })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey(key); })
    .onBlur(() => { this.onBlurKey(key); })
    .onHover((isHover: boolean) => { this.onHoverKey(key, isHover); })
    .onMouse((event: MouseEvent) => { this.onMouseFeedback(key, event); })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback(key, event); })
    .onClick(() => { onToggle(); })
    .accessibilityGroup(true)
    .accessibilityText(title +
      (this.isSectionExpanded(key) ? '，已展开，点击收起' : '，已收起，点击展开'))
  }

  @Builder
  spacesHeader() {
    Row() {
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Row() {
          UiIcon({ name: IconName.Folder, iconSize: 14, color: Theme.subText(this.isDark) })
            .margin({ right: 8 })
          Text('空间')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.subText(this.isDark))
          UiIcon({
            name: IconName.ChevronDown,
            iconSize: 11,
            color: Theme.faintText(this.isDark)
          })
            .margin({ left: 6 })
            .rotate({ angle: this.spacesExpanded ? 0 : -90 })
          Blank()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, right: 6 })
      }
      .height(36)
      .layoutWeight(1)
      .padding(0)
      .borderRadius(8)
      .backgroundColor(this.rowBackground('spaces_header', false))
      .border({ width: this.focusWidth('spaces_header'), color: this.accentOf(), radius: 8 })
      .scale({ x: this.rowScale('spaces_header'), y: this.rowScale('spaces_header') })
      .focusable(true)
      .focusOnTouch(true)
      .onFocus(() => { this.onFocusKey('spaces_header'); })
      .onBlur(() => { this.onBlurKey('spaces_header'); })
      .onHover((isHover: boolean) => { this.onHoverKey('spaces_header', isHover); })
      .onMouse((event: MouseEvent) => { this.onMouseFeedback('spaces_header', event); })
      .onTouch((event: TouchEvent) => { this.onTouchFeedback('spaces_header', event); })
      .onClick(() => { this.spacesExpanded = !this.spacesExpanded; })
      .accessibilityGroup(true)
      .accessibilityText('空间' +
        (this.spacesExpanded ? '，已展开，点击收起' : '，已收起，点击展开'))

      Row() {
        UiIcon({
          name: IconName.FolderAdd,
          iconSize: 15,
          color: Theme.tertiary(this.isDark)
        })
      }
      .width(28)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .borderRadius(7)
      .backgroundColor(this.rowBackground('new_space', false))
      .border({ width: this.focusWidth('new_space'), color: this.accentOf(), radius: 7 })
      .scale({ x: this.rowScale('new_space'), y: this.rowScale('new_space') })
      .focusable(true)
      .focusOnTouch(true)
      .onFocus(() => { this.onFocusKey('new_space'); })
      .onBlur(() => { this.onBlurKey('new_space'); })
      .onHover((isHover: boolean) => { this.onHoverKey('new_space', isHover); })
      .onMouse((event: MouseEvent) => { this.onMouseFeedback('new_space', event); })
      .onTouch((event: TouchEvent) => { this.onTouchFeedback('new_space', event); })
      .onClick(() => { this.onNewSpace(); })
      .accessibilityText('新建空间')
    }
    .width('100%')
    .height(36)
    .padding({ right: 4 })
  }

  @Builder
  selectionMark(selected: boolean) {
    Row()
      .width(3)
      .height(18)
      .borderRadius(2)
      .backgroundColor(this.accentOf())
      .opacity(selected ? 1 : 0)
      .margin({ right: 6 })
      .accessibilityLevel('no')
  }

  @Builder
  spaceRow(space: SpaceLite) {
    Row() {
      this.selectionMark(this.selectedSpace === space.key())
      UiIcon({
        name: IconName.Folder,
        iconSize: 14,
        color: this.selectedSpace === space.key() ? this.accentOf() : Theme.subText(this.isDark)
      })
        .margin({ right: 8 })
      Text(this.displayCwd(space.cwd))
        .fontSize(14)
        .fontColor(this.selectedSpace === space.key() ?
          Theme.text(this.isDark) : Theme.subText(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(space.count.toString())
        .fontSize(12)
        .fontColor(Theme.faintText(this.isDark))
      if (this.selectedDeviceId.length === 0) {
        Text(space.deviceName)
          .fontSize(9.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.deviceTagTextColor())
          .height(17)
          .padding({ left: 5, right: 5 })
          .backgroundColor(this.deviceTagBackground(space.deviceId))
          .borderRadius(5)
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: 9, right: 9 })
    .borderRadius(8)
    .backgroundColor(this.rowBackground('space_' + space.key(), this.selectedSpace === space.key()))
    .border({ width: this.focusWidth('space_' + space.key()), color: this.accentOf(), radius: 8 })
    .scale({ x: this.rowScale('space_' + space.key()), y: this.rowScale('space_' + space.key()) })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey('space_' + space.key()); })
    .onBlur(() => { this.onBlurKey('space_' + space.key()); })
    .onHover((isHover: boolean) => { this.onHoverKey('space_' + space.key(), isHover); })
    .onMouse((event: MouseEvent) => {
      this.onMouseFeedback('space_' + space.key(), event);
      if (event.button === MouseButton.Right && event.action === MouseAction.Press) {
        this.menuSpace = space.cwd;
        this.menuSpaceDeviceId = space.deviceId;
      }
    })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback('space_' + space.key(), event); })
    .onClick(() => {
      this.selectedSpace = space.key();
      AppStorage.setOrCreate('selectedSpace', space.key());
      this.onSelectSpace(space.deviceId, space.cwd);
    })
    .bindContextMenu(this.spaceMenuBuilder, ResponseType.RightClick)
    .accessibilityGroup(true)
    .accessibilityText('空间 ' + this.displayCwd(space.cwd) + '，' +
      space.count.toString() + ' 个会话')
    .accessibilitySelected(this.selectedSpace === space.key())
  }

  @Builder
  moreButton(item: TerminalSession) {
    Row() {
      UiIcon({ name: IconName.More, iconSize: 16, color: Theme.tertiary(this.isDark) })
    }
    .width(24)
    .height(24)
    .justifyContent(FlexAlign.Center)
    .borderRadius(6)
    .backgroundColor(this.rowBackground(this.sessionKey('more_', item), false))
    .border({ width: this.focusWidth(this.sessionKey('more_', item)), color: this.accentOf(), radius: 6 })
    .scale({
      x: this.rowScale(this.sessionKey('more_', item)),
      y: this.rowScale(this.sessionKey('more_', item))
    })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey(this.sessionKey('more_', item)); })
    .onBlur(() => { this.onBlurKey(this.sessionKey('more_', item)); })
    .onHover((isHover: boolean) => { this.onHoverKey(this.sessionKey('more_', item), isHover); })
    .onMouse((event: MouseEvent) => { this.onMouseFeedback(this.sessionKey('more_', item), event); })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback(this.sessionKey('more_', item), event); })
    .onClick(() => { this.beginMenuFor(item); })
    .bindMenu(this.menuItems())
    .accessibilityText('更多会话操作')
  }

  @Builder
  agentRow(item: TerminalSession) {
    Row() {
      SessionSelectionMark({ selected: this.isSessionSelected(item), accent: this.accentOf() })
      Column() {
        Row() {
          SessionTitleLabel({
            session: item,
            maxWidth: Math.max(80, this.sidebarWidth - 100),
            medium: true
          })
          Blank()
          Text(item.activityState)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.stateColor(item))
            .height(19)
            .padding({ left: 6, right: 6 })
            .backgroundColor(this.stateBackground(item))
            .borderRadius(6)
            .maxLines(1)
            .accessibilityText('运行状态：' + item.activityState)
        }
        .width('100%')

        Row() {
          Row() {
            BrandIcon({
              kind: this.programIconKind(item),
              iconSize: 11,
              color: this.kindColor(item),
              isDark: this.isDark
            })
            Text(this.programLabel(item))
              .fontSize(12)
              .fontColor(this.kindColor(item))
              .margin({ left: 4 })
          }
          .height(20)
          .padding({ left: 6, right: 6 })
          .backgroundColor(Theme.input(this.isDark))
          .borderRadius(6)

          Text('·')
            .fontSize(12)
            .fontColor(Theme.faintText(this.isDark))
            .margin({ left: 5, right: 5 })
          UiIcon({ name: IconName.Folder, iconSize: 10, color: Theme.tertiary(this.isDark) })
            .margin({ right: 4 })
          Text(this.displayCwd(item.cwd))
            .fontSize(12)
            .fontColor(Theme.tertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (item.unread) {
            Circle({ width: 6, height: 6 })
              .fill(this.accentOf())
              .margin({ left: 4 })
              .accessibilityText('有新输出')
          }
          if (this.selectedDeviceId.length === 0) {
            Text(item.deviceName)
              .fontSize(9.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.deviceTagTextColor())
              .height(18)
              .padding({ left: 5, right: 5 })
              .backgroundColor(this.deviceTagBackground(item.deviceId))
              .borderRadius(5)
              .margin({ left: 4 })
          }
          this.moreButton(item)
        }
        .width('100%')
        .margin({ top: 5 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(58)
    .padding({ left: 9, right: 6 })
    .borderRadius(9)
    .backgroundColor(this.rowBackground(this.sessionKey('agent_', item), this.isSessionSelected(item)))
    .border({ width: this.focusWidth(this.sessionKey('agent_', item)), color: this.accentOf(), radius: 9 })
    .scale({
      x: this.rowScale(this.sessionKey('agent_', item)),
      y: this.rowScale(this.sessionKey('agent_', item))
    })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey(this.sessionKey('agent_', item)); })
    .onBlur(() => { this.onBlurKey(this.sessionKey('agent_', item)); })
    .onHover((isHover: boolean) => { this.onHoverKey(this.sessionKey('agent_', item), isHover); })
    .onMouse((event: MouseEvent) => {
      this.onMouseFeedback(this.sessionKey('agent_', item), event);
      if (event.button === MouseButton.Right && event.action === MouseAction.Press) {
        this.beginMenuFor(item);
      }
    })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback(this.sessionKey('agent_', item), event); })
    .onClick(() => { this.onSelectSession(item.uid); })
    .bindContextMenu(this.contextMenuBuilder, ResponseType.RightClick)
    .accessibilityText(item.name + '，' + this.programLabel(item) + '，空间 ' +
      this.displayCwd(item.cwd) + '，运行状态 ' + item.activityState)
    .accessibilitySelected(this.isSessionSelected(item))
  }

  @Builder
  shellRow(item: TerminalSession) {
    Row() {
      SessionSelectionMark({ selected: this.isSessionSelected(item), accent: this.accentOf() })
      Column() {
        Row() {
          SessionTitleLabel({
            session: item,
            maxWidth: Math.max(80, this.sidebarWidth - 100),
            medium: true
          })
          Blank()
          SessionNumberBadge({ value: item.sequence, isDark: this.isDark })
        }
        .width('100%')

        Row() {
          Row() {
            UiIcon({
              name: IconName.Folder,
              iconSize: 10,
              color: this.isSessionSelected(item) ? this.accentOf() : Theme.tertiary(this.isDark)
            })
            Text(this.displayCwd(canonicalSessionCwd(item)))
              .fontSize(12)
              .fontColor(Theme.tertiary(this.isDark))
              .margin({ left: 4 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .height(20)
          .padding({ left: 6, right: 6 })
          .constraintSize({
            maxWidth: Math.max(80, this.sidebarWidth -
              (this.selectedDeviceId.length === 0 ? 108 : 54))
          })
          .backgroundColor(Theme.input(this.isDark))
          .borderRadius(6)
          Blank()
          if (item.unread) {
            Circle({ width: 6, height: 6 })
              .fill(this.accentOf())
              .margin({ left: 4 })
              .accessibilityText('有新输出')
          }
          if (this.selectedDeviceId.length === 0) {
            Text(item.deviceName)
              .fontSize(9.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.deviceTagTextColor())
              .height(18)
              .padding({ left: 5, right: 5 })
              .backgroundColor(this.deviceTagBackground(item.deviceId))
              .borderRadius(5)
              .margin({ left: 4 })
          }
          this.moreButton(item)
        }
        .width('100%')
        .margin({ top: 5 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(58)
    .padding({ left: 9, right: 6 })
    .borderRadius(9)
    .backgroundColor(this.rowBackground(this.sessionKey('shell_', item), this.isSessionSelected(item)))
    .border({ width: this.focusWidth(this.sessionKey('shell_', item)), color: this.accentOf(), radius: 9 })
    .scale({
      x: this.rowScale(this.sessionKey('shell_', item)),
      y: this.rowScale(this.sessionKey('shell_', item))
    })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey(this.sessionKey('shell_', item)); })
    .onBlur(() => { this.onBlurKey(this.sessionKey('shell_', item)); })
    .onHover((isHover: boolean) => { this.onHoverKey(this.sessionKey('shell_', item), isHover); })
    .onMouse((event: MouseEvent) => {
      this.onMouseFeedback(this.sessionKey('shell_', item), event);
      if (event.button === MouseButton.Right && event.action === MouseAction.Press) {
        this.beginMenuFor(item);
      }
    })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback(this.sessionKey('shell_', item), event); })
    .onClick(() => { this.onSelectSession(item.uid); })
    .bindContextMenu(this.contextMenuBuilder, ResponseType.RightClick)
    .accessibilityText('终端 ' + item.name + ' ' + item.sequence.toString() + '，空间 ' +
      this.displayCwd(canonicalSessionCwd(item)) + '，设备 ' + item.deviceName)
    .accessibilitySelected(this.isSessionSelected(item))
  }

  @Builder
  renamingRow(item: TerminalSession) {
    TextInput({ text: this.renameText })
      .id(this.renameInputId(item))
      .defaultFocus(true)
      .fontSize(14)
      .height(36)
      .backgroundColor(Theme.input(this.isDark))
      .fontColor(Theme.text(this.isDark))
      .caretColor(this.accentOf())
      .border({ width: 1, color: this.accentOf(), radius: 7 })
      .borderRadius(7)
      .padding({ left: 8, right: 8 })
      .margin({ left: 8, right: 6, bottom: 4 })
      .onChange((value: string) => { this.renameText = value; })
      .onHover((isHover: boolean) => { this.renameInputHovered = isHover; })
      .onVisibleAreaChange([1.0], (isVisible: boolean) => {
        if (isVisible) this.focusRenameInput(item);
      })
      .onSubmit(() => {
        if (this.renameText.trim().length > 0) {
          this.onRenameSession(item, this.renameText.trim());
        }
        this.renamingUid = -1;
      })
      .onBlur(() => {
        this.renamingUid = -1;
        this.renameInputHovered = false;
      })
  }

  /** Read @Link sessions directly: @Builder value parameters are not reactive in ArkUI V1. */
  @Builder
  agentRows() {
    if (this.agents(this.sessions).length === 0) {
      Row() {
        UiIcon({ name: IconName.Spark, iconSize: 13, color: Theme.faintText(this.isDark) })
        Text('此空间中暂无智能体')
          .fontSize(12)
          .fontColor(Theme.faintText(this.isDark))
          .margin({ left: 7 })
      }
      .width('100%')
      .height(34)
      .padding({ left: 9 })
    } else {
      ForEach(this.agents(this.sessions), (item: TerminalSession) => {
        if (this.renamingUid === item.uid) {
          this.renamingRow(item)
        } else {
          this.agentRow(item)
        }
      }, (item: TerminalSession) => 'agent_' + item.uid.toString())
    }
  }

  /** Keep remote terminal additions observable after the asynchronous SSH restore completes. */
  @Builder
  shellRows() {
    if (this.shells(this.sessions).length === 0) {
      Row() {
        UiIcon({ name: IconName.Terminal, iconSize: 13, color: Theme.faintText(this.isDark) })
        Text('此空间中暂无终端')
          .fontSize(12)
          .fontColor(Theme.faintText(this.isDark))
          .margin({ left: 7 })
      }
      .width('100%')
      .height(34)
      .padding({ left: 9 })
    } else {
      ForEach(this.shells(this.sessions), (item: TerminalSession) => {
        if (this.renamingUid === item.uid) {
          this.renamingRow(item)
        } else {
          this.shellRow(item)
        }
      }, (item: TerminalSession) => 'shell_' + item.uid.toString())
    }
  }

  @Builder
  allSpacesRow() {
    Row() {
      this.selectionMark(this.selectedSpace.length === 0)
      UiIcon({
        name: IconName.Grid,
        iconSize: 14,
        color: this.selectedSpace.length === 0 ? this.accentOf() : Theme.subText(this.isDark)
      })
        .margin({ right: 8 })
      Text('全部空间')
        .fontSize(14)
        .fontColor(this.selectedSpace.length === 0 ?
          Theme.text(this.isDark) : Theme.subText(this.isDark))
        .layoutWeight(1)
      Text(this.scopeSessionCount(this.sessions).toString())
        .fontSize(12)
        .fontColor(Theme.faintText(this.isDark))
    }
    .width('100%')
    .height(34)
    .padding({ left: 9, right: 9 })
    .borderRadius(8)
    .backgroundColor(this.rowBackground('all_spaces', this.selectedSpace.length === 0))
    .border({ width: this.focusWidth('all_spaces'), color: this.accentOf(), radius: 8 })
    .scale({ x: this.rowScale('all_spaces'), y: this.rowScale('all_spaces') })
    .focusable(true)
    .focusOnTouch(true)
    .onFocus(() => { this.onFocusKey('all_spaces'); })
    .onBlur(() => { this.onBlurKey('all_spaces'); })
    .onHover((isHover: boolean) => { this.onHoverKey('all_spaces', isHover); })
    .onMouse((event: MouseEvent) => { this.onMouseFeedback('all_spaces', event); })
    .onTouch((event: TouchEvent) => { this.onTouchFeedback('all_spaces', event); })
    .onClick(() => {
      this.selectedSpace = '';
      AppStorage.setOrCreate('selectedSpace', '');
    })
    .accessibilityGroup(true)
    .accessibilityText('全部空间，' + this.scopeSessionCount(this.sessions).toString() + ' 个会话')
    .accessibilitySelected(this.selectedSpace.length === 0)
  }

  build() {
    Column() {
      Row() {
        Row() {
          Image($r('app.media.terminai_icon_concept_white'))
            .width(24)
            .height(24)
            .objectFit(ImageFit.Contain)
            .borderRadius(6)
            .clip(true)
            .accessibilityLevel('no')
          Text('terminAI')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.subText(this.isDark))
            .margin({ left: 8 })
          Blank()
        }
        .height('100%')
        .layoutWeight(1)
        .onTouch((event: TouchEvent) => {
          this.onTitleTouch(event);
        })
        Row() {
          UiIcon({
            name: IconName.SidebarHide,
            iconSize: 16,
            color: Theme.tertiary(this.isDark)
          })
        }
        .width(28)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(7)
        .backgroundColor(this.rowBackground('collapse', false))
        .border({ width: this.focusWidth('collapse'), color: this.accentOf(), radius: 7 })
        .scale({ x: this.rowScale('collapse'), y: this.rowScale('collapse') })
        .focusable(true)
        .focusOnTouch(true)
        .onFocus(() => { this.onFocusKey('collapse'); })
        .onBlur(() => { this.onBlurKey('collapse'); })
        .onHover((isHover: boolean) => { this.onHoverKey('collapse', isHover); })
        .onMouse((event: MouseEvent) => { this.onMouseFeedback('collapse', event); })
        .onTouch((event: TouchEvent) => { this.onTouchFeedback('collapse', event); })
        .onClick(() => { this.onCollapse(); })
        .accessibilityText('隐藏侧边栏')
      }
      .width('100%')
      .height(52)
      .padding({ left: 14, right: 10 })

      Column({ space: 2 }) {
        this.actionRow(IconName.NewAgent, 'new_agent', '新建智能体', 'Ctrl + N',
          () => { this.onNewAgent(); })
        this.actionRow(IconName.Search, 'search', '搜索', 'Ctrl + K',
          () => { this.onSearch(); })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 0, bottom: 6 })

      List() {
        ListItem() {
          Column() {
            this.spacesHeader()
            if (this.spacesExpanded) {
              this.allSpacesRow()

              ForEach(this.spaces(this.sessions), (space: SpaceLite) => {
                this.spaceRow(space)
              }, (space: SpaceLite) => space.key())
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.sectionHeader(IconName.Agents, '智能体', 'agents_header',
              () => { this.agentsExpanded = !this.agentsExpanded; })
            if (this.agentsExpanded) {
              this.agentRows()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        ListItem() {
          Column() {
            this.sectionHeader(IconName.Terminal, '终端', 'terminals_header',
              () => { this.terminalsExpanded = !this.terminalsExpanded; })
            if (this.terminalsExpanded) {
              this.shellRows()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ left: 10, right: 10, bottom: 6 })
      .edgeEffect(EdgeEffect.Spring)

      Divider()
        .color(Theme.divider(this.isDark))
        .strokeWidth(1)

      Row() {
        Row() {
          UiIcon({
            name: this.selectedDeviceId.length === 0 ? IconName.Grid : IconName.Terminal,
            iconSize: 13,
            color: Theme.tertiary(this.isDark)
          })
          Text(this.deviceFooterLabel())
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.subText(this.isDark))
            .margin({ left: 6 })
          Circle({ width: 6, height: 6 })
            .fill(this.deviceFooterColor())
            .margin({ left: 6 })
          UiIcon({ name: IconName.ChevronDown, iconSize: 9, color: Theme.faintText(this.isDark) })
            .margin({ left: 6 })
        }
        .height(28)
        .padding({ left: 8, right: 8 })
        .backgroundColor(this.rowBackground('devices', false))
        .borderRadius(7)
        .border({ width: this.focusWidth('devices'), color: this.accentOf(), radius: 7 })
        .scale({ x: this.rowScale('devices'), y: this.rowScale('devices') })
        .focusable(true)
        .focusOnTouch(true)
        .onFocus(() => { this.onFocusKey('devices'); })
        .onBlur(() => { this.onBlurKey('devices'); })
        .onHover((isHover: boolean) => { this.onHoverKey('devices', isHover); })
        .onMouse((event: MouseEvent) => { this.onMouseFeedback('devices', event); })
        .onTouch((event: TouchEvent) => { this.onTouchFeedback('devices', event); })
        .onClick(() => { this.onOpenDevices(); })
        .accessibilityText('设备：' + this.deviceFooterLabel() + '，点击管理本地和 SSH 设备')

        Blank()

        Row() {
          UiIcon({ name: IconName.Settings, iconSize: 16, color: Theme.tertiary(this.isDark) })
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .borderRadius(7)
        .backgroundColor(this.rowBackground('settings', false))
        .border({ width: this.focusWidth('settings'), color: this.accentOf(), radius: 7 })
        .scale({ x: this.rowScale('settings'), y: this.rowScale('settings') })
        .focusable(true)
        .focusOnTouch(true)
        .onFocus(() => { this.onFocusKey('settings'); })
        .onBlur(() => { this.onBlurKey('settings'); })
        .onHover((isHover: boolean) => { this.onHoverKey('settings', isHover); })
        .onMouse((event: MouseEvent) => { this.onMouseFeedback('settings', event); })
        .onTouch((event: TouchEvent) => { this.onTouchFeedback('settings', event); })
        .onClick(() => { this.onOpenSettings(); })
        .accessibilityText('设置')
      }
      .width('100%')
      .height(44)
      .padding({ left: 10, right: 10 })
    }
    .width(this.sidebarWidth)
    .height('100%')
    .backgroundColor(Theme.panel(this.isDark))
    .focusable(true)
    .focusOnTouch(true)
    .onMouse((event: MouseEvent) => {
      if (this.renamingUid >= 0 && !this.renameInputHovered &&
        event.button === MouseButton.Left && event.action === MouseAction.Press) {
        this.renamingUid = -1;
      }
    })
  }
}
