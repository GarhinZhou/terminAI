// Settings window, ported from herdrm's SettingsView: horizontal tab bar +
// macOS-Form-style grouped rows inside rounded cards, width 420.
import { Theme } from '../common/Theme';
import { BrandIcon } from '../common/BrandIcon';
import { IconName, UiIcon } from '../common/Icons';
import { CustomAgentInfo, decodeCustomAgents, encodeCustomAgents } from '../model/CustomAgent';

interface KindRow {
  kind: string;
  label: string;
}

@Component
struct SettingChoiceChip {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop isDark: boolean = true;
  onSelect: () => void = () => {};

  build() {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Text(this.label)
        .fontSize(13)
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selected ? Theme.onAccent(this.isDark) : Theme.text(this.isDark))
    }
    .height(30)
    .padding({ left: 12, right: 12 })
    .margin({ left: 6 })
    .backgroundColor(this.selected ? Theme.accent(this.isDark) : Theme.button(this.isDark))
    .border({
      width: 1,
      color: this.selected ? Theme.accent(this.isDark) : Theme.border(this.isDark),
      radius: 15
    })
    .onClick(() => { this.onSelect(); })
    .accessibilityText(this.label)
    .accessibilitySelected(this.selected)
  }
}

@CustomDialog
export struct SettingsView {
  controller?: CustomDialogController;
  onCustomAgentsChanged: (value: string) => void = () => {};

  @StorageLink('fontSize') fontSize: number = 14;
  @StorageLink('fontBold') fontBold: boolean = false;
  @StorageLink('lineHeight') lineHeight: number = 1.0;
  @StorageLink('fontFamily') fontFamily: string = '';
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('notifyEnabled') notifyEnabled: boolean = true;
  @StorageLink('cursorStyle') cursorStyle: string = 'block';
  @StorageLink('colorScheme') colorScheme: string = 'default';
  @StorageLink('scrollback') scrollback: number = 10000;
  @StorageLink('autoNewSession') autoNewSession: boolean = true;
  @StorageLink('agentOverrides') agentOverrides: string = '';
  @StorageLink('customAgents') customAgents: string = '';
  @StorageProp('isDark') isDark: boolean = true;
  @State private tab: number = 0;
  @State private drafts: Map<string, string> = new Map();
  @State private customAgentItems: CustomAgentInfo[] = [];
  @State private customAgentName: string = '';
  @State private customAgentCommand: string = '';

  private kinds: KindRow[] = [
    { kind: 'claude', label: 'Claude' },
    { kind: 'codex', label: 'Codex' },
    { kind: 'cursor', label: 'Cursor' },
    { kind: 'gemini', label: 'Gemini' },
    { kind: 'grok', label: 'Grok' },
    { kind: 'kimi', label: 'Kimi' },
    { kind: 'opencode', label: 'OpenCode' },
    { kind: 'copilot', label: 'Copilot' },
  ];
  private fontOptions: SelectOption[] = [
    { value: '系统等宽字体' },
    { value: 'Noto Sans Mono' },
    { value: 'Roboto' }
  ];
  private paletteOptions: SelectOption[] = [
    { value: '系统' },
    { value: 'Solarized' },
    { value: 'Dracula' },
    { value: 'Gruvbox' },
    { value: '浅色纸张' }
  ];

  aboutToAppear(): void {
    const m = new Map<string, string>();
    try {
      const obj = JSON.parse(this.agentOverrides.length > 0 ? this.agentOverrides : '{}') as Record<string, string>;
      Object.keys(obj).forEach((k: string) => { m.set(k, obj[k]); });
    } catch (e) {
      console.error('TERMINAI agentOverrides parse failed: ' + JSON.stringify(e));
    }
    this.drafts = m;
    this.customAgentItems = decodeCustomAgents(this.customAgents);
  }

  private commitOverrides(): void {
    const obj: Record<string, string> = {};
    this.drafts.forEach((v: string, k: string) => {
      if (v.trim().length > 0) obj[k] = v.trim();
    });
    this.agentOverrides = JSON.stringify(obj);
  }

  private overrideOf(kind: string): string {
    return this.drafts.get(kind) ?? '';
  }

  private isBuiltInAgent(name: string): boolean {
    const normalized = name.trim().toLowerCase();
    return this.kinds.some((item: KindRow) => item.kind === normalized);
  }

  private canAddCustomAgent(): boolean {
    return this.customAgentName.trim().length > 0 &&
      this.customAgentCommand.trim().length > 0 &&
      !this.isBuiltInAgent(this.customAgentName);
  }

  private commitCustomAgents(items: CustomAgentInfo[]): void {
    const encoded = encodeCustomAgents(items);
    this.customAgentItems = items;
    this.customAgents = encoded;
    this.onCustomAgentsChanged(encoded);
  }

  private addCustomAgent(): void {
    if (!this.canAddCustomAgent()) {
      return;
    }
    const name = this.customAgentName.trim();
    const command = this.customAgentCommand.trim();
    const next = this.customAgentItems.slice();
    const existing = next.findIndex((item: CustomAgentInfo) =>
      item.name.toLowerCase() === name.toLowerCase());
    const custom = new CustomAgentInfo(name, command);
    if (existing >= 0) {
      next[existing] = custom;
    } else {
      next.push(custom);
    }
    this.commitCustomAgents(next);
    this.customAgentName = '';
    this.customAgentCommand = '';
  }

  private removeCustomAgent(name: string): void {
    this.commitCustomAgents(this.customAgentItems.filter((item: CustomAgentInfo) =>
      item.name.toLowerCase() !== name.toLowerCase()));
  }

  @Builder
  tabItem(icon: IconName, label: string, idx: number) {
    Column() {
      UiIcon({
        name: icon,
        iconSize: 17,
        color: this.tab === idx ? Theme.accent(this.isDark) : Theme.tertiary(this.isDark)
      })
      Text(label)
        .fontSize(12)
        .fontWeight(this.tab === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === idx ? Theme.accent(this.isDark) : Theme.tertiary(this.isDark))
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.tab === idx ? Theme.selected(this.isDark) : '#00000000')
    .borderRadius(9)
    .onClick(() => { this.tab = idx; })
    .accessibilityText(label)
    .accessibilitySelected(this.tab === idx)
  }

  /** Row inside a form card: label left, control right. */

  @Builder
  cardDivider() {
    Divider()
      .color(Theme.divider(this.isDark))
      .strokeWidth(1)
      .margin({ left: 12, right: 12 })
  }

  @Builder
  caption(text: string) {
    Text(text)
      .fontSize(13)
      .lineHeight(19)
      .fontColor(Theme.subText(this.isDark))
      .width('100%')
      .padding({ left: 4, right: 4, top: 6 })
  }

  build() {
    Column() {
      // ── Tab bar ──
      Row() {
        this.tabItem(IconName.Appearance, '外观', 0)
        this.tabItem(IconName.Terminal, '终端', 1)
        this.tabItem(IconName.Agents, '智能体', 2)
        this.tabItem(IconName.Notifications, '通知', 3)
        this.tabItem(IconName.Info, '关于', 4)
      }
      .width('100%')
      .height(62)
      .padding({ left: 8, right: 8, top: 8 })

      Divider().color(Theme.divider(this.isDark)).strokeWidth(1)

      Scroll() {
        Column() {
          if (this.tab === 0) {
            // ── Appearance ──
            Column() {
              Row() {
                Text('主题')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
                  ForEach(['system', 'light', 'dark'], (mode: string) => {
                    SettingChoiceChip({
                      label: mode === 'system' ? '系统' : (mode === 'light' ? '浅色' : '深色'),
                      selected: this.themeMode === mode,
                      isDark: this.isDark,
                      onSelect: () => { this.themeMode = mode; }
                    })
                  }, (m: string) => m)
                }
                .width(220)
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
            }
            .width('100%')
            .backgroundColor(Theme.input(this.isDark))
            .borderRadius(10)
            .padding({ top: 2, bottom: 2 })
            this.caption('终端配色会跟随应用主题。')
          } else if (this.tab === 1) {
            // ── Terminal ──
            Column() {
              Row() {
                Text('字体')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Select(this.fontOptions)
                  .value(this.fontFamily.length > 0 ? this.fontFamily : '系统等宽字体')
                  .fontColor(Theme.text(this.isDark))
                  .font({ size: 14 })
                  .selectedOptionFontColor(Theme.text(this.isDark))
                  .optionFontColor(Theme.text(this.isDark))
                  .optionFont({ size: 14 })
                  .backgroundColor(Theme.button(this.isDark))
                  .borderRadius(6)
                  .height(32)
                  .width(170)
                  .onSelect((idx: number, text: string) => {
                    this.fontFamily = text === '系统等宽字体' ? '' : text;
                  })
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('字号')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Slider({ value: this.fontSize, min: 9, max: 22, step: 0.5 })
                  .width(140)
                  .selectedColor(Theme.accent(this.isDark))
                  .trackColor(Theme.button(this.isDark))
                  .blockColor(Theme.accent(this.isDark))
                  .onChange((v: number) => { this.fontSize = v; })
                Text(this.fontSize.toFixed(1) + ' pt')
                  .fontSize(13)
                  .fontColor(Theme.subText(this.isDark))
                  .width(52)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('字重')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
                  ForEach(['Regular', 'Bold'], (weight: string) => {
                    SettingChoiceChip({
                      label: weight === 'Bold' ? '加粗' : '标准',
                      selected: (weight === 'Bold' && this.fontBold) ||
                        (weight === 'Regular' && !this.fontBold),
                      isDark: this.isDark,
                      onSelect: () => { this.fontBold = weight === 'Bold'; }
                    })
                  }, (w: string) => w)
                }
                .width(150)
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('行距')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Slider({ value: this.lineHeight, min: 1.0, max: 1.4, step: 0.05 })
                  .width(140)
                  .selectedColor(Theme.accent(this.isDark))
                  .trackColor(Theme.button(this.isDark))
                  .blockColor(Theme.accent(this.isDark))
                  .onChange((v: number) => { this.lineHeight = v; })
                Text(Math.round(this.lineHeight * 100) + '%')
                  .fontSize(13)
                  .fontColor(Theme.subText(this.isDark))
                  .width(52)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('光标')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
                  ForEach(['block', 'bar', 'underline'], (style: string) => {
                    SettingChoiceChip({
                      label: style === 'block' ? '方块' : (style === 'bar' ? '竖线' : '下划线'),
                      selected: this.cursorStyle === style,
                      isDark: this.isDark,
                      onSelect: () => { this.cursorStyle = style; }
                    })
                  }, (style: string) => style)
                }
                .width(220)
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('配色方案')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Select(this.paletteOptions)
                  .value(this.colorScheme === 'default' ? '系统' :
                    (this.colorScheme === 'lightpaper' ? '浅色纸张' :
                      this.colorScheme.substring(0, 1).toUpperCase() + this.colorScheme.substring(1)))
                  .fontColor(Theme.text(this.isDark))
                  .font({ size: 14 })
                  .backgroundColor(Theme.button(this.isDark))
                  .borderRadius(6)
                  .height(32)
                  .width(150)
                  .onSelect((idx: number, text: string) => {
                    if (text === '系统') {
                      this.colorScheme = 'default';
                    } else if (text === '浅色纸张') {
                      this.colorScheme = 'lightpaper';
                    } else {
                      this.colorScheme = text.toLowerCase();
                    }
                  })
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('回滚行数')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Slider({ value: this.scrollback, min: 1000, max: 50000, step: 1000 })
                  .width(140)
                  .selectedColor(Theme.accent(this.isDark))
                  .trackColor(Theme.button(this.isDark))
                  .blockColor(Theme.accent(this.isDark))
                  .onChange((value: number) => { this.scrollback = value; })
                Text(this.scrollback.toString())
                  .fontSize(13)
                  .fontColor(Theme.subText(this.isDark))
                  .width(52)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
              this.cardDivider()
              Row() {
                Text('启动时打开终端')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Toggle({ type: ToggleType.Switch, isOn: this.autoNewSession })
                  .selectedColor(Theme.accent(this.isDark))
                  .onChange((isOn: boolean) => { this.autoNewSession = isOn; })
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
            }
            .width('100%')
            .backgroundColor(Theme.input(this.isDark))
            .borderRadius(10)
            .padding({ top: 2, bottom: 2 })

            Row() {
              Blank()
              Button('恢复默认设置')
                .fontSize(14)
                .fontColor(Theme.text(this.isDark))
                .backgroundColor(Theme.button(this.isDark))
                .height(30)
                .borderRadius(6)
                .onClick(() => {
                  this.fontSize = 14;
                  this.fontBold = false;
                  this.lineHeight = 1.0;
                  this.fontFamily = '';
                  this.cursorStyle = 'block';
                  this.colorScheme = 'default';
                  this.scrollback = 10000;
                })
            }
            .width('100%')
            .height(44)
            this.caption('预览')
            Text('❯ herdr agent attach w1:p1 — 中文 ABC 0123')
              .fontSize(this.fontSize)
              .fontWeight(this.fontBold ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(Theme.text(this.isDark))
              .maxLines(1)
              .padding(10)
              .width('100%')
              .backgroundColor(Theme.terminalBg(this.isDark))
              .borderRadius(8)
              .margin({ top: 6 })
          } else if (this.tab === 2) {
            // ── Agents ──
            Column() {
              ForEach(this.kinds, (row: KindRow) => {
                Row() {
                  BrandIcon({
                    kind: row.kind,
                    iconSize: 16,
                    color: Theme.tertiary(this.isDark),
                    isDark: this.isDark
                  })
                  .margin({ right: 8 })
                  Text(row.label)
                    .fontSize(15)
                    .fontColor(Theme.text(this.isDark))
                    .layoutWeight(1)
                    .margin({ right: 10 })
                  TextInput({ text: this.overrideOf(row.kind), placeholder: '自动检测' })
                    .fontSize(14)
                    .height(32)
                    .width(210)
                    .backgroundColor(Theme.button(this.isDark))
                    .fontColor(Theme.text(this.isDark))
                    .placeholderColor(Theme.faintText(this.isDark))
                    .borderRadius(6)
                    .onChange((v: string) => {
                      this.drafts.set(row.kind, v);
                      this.commitOverrides();
                    })
                }
                .width('100%')
                .height(42)
                .padding({ left: 12, right: 12 })
                if (row.kind !== 'copilot') {
                  this.cardDivider()
                }
              }, (row: KindRow) => row.kind + '_' + this.overrideOf(row.kind))
            }
            .width('100%')
            .backgroundColor(Theme.input(this.isDark))
            .borderRadius(10)
            .padding({ top: 2, bottom: 2 })
            this.caption('应用会在登录 Shell 的 PATH 中查找这些程序。自动检测结果不正确时，可在此填写可执行文件路径。')

            Text('自定义智能体')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.subText(this.isDark))
              .width('100%')
              .padding({ left: 4, top: 14, bottom: 6 })

            Column() {
              if (this.customAgentItems.length === 0) {
                Text('暂无自定义智能体')
                  .fontSize(13)
                  .fontColor(Theme.faintText(this.isDark))
                  .width('100%')
                  .height(38)
                  .padding({ left: 12 })
              } else {
                ForEach(this.customAgentItems, (item: CustomAgentInfo, index: number) => {
                  Row() {
                    BrandIcon({
                      kind: 'gemini',
                      iconSize: 16,
                      color: Theme.accent(this.isDark),
                      isDark: this.isDark
                    })
                    .margin({ right: 8 })
                    Column() {
                      Text(item.name)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.text(this.isDark))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(item.command)
                        .fontSize(12)
                        .fontColor(Theme.tertiary(this.isDark))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .margin({ right: 8 })
                    Button('移除')
                      .fontSize(12)
                      .fontColor(Theme.danger(this.isDark))
                      .height(28)
                      .backgroundColor(Theme.button(this.isDark))
                      .borderRadius(6)
                      .onClick(() => { this.removeCustomAgent(item.name); })
                      .accessibilityText('移除自定义智能体 ' + item.name)
                  }
                  .width('100%')
                  .height(52)
                  .padding({ left: 12, right: 12 })
                  if (index < this.customAgentItems.length - 1) {
                    this.cardDivider()
                  }
                }, (item: CustomAgentInfo) => item.name.toLowerCase())
                this.cardDivider()
              }

              Column({ space: 8 }) {
                TextInput({ text: this.customAgentName, placeholder: '智能体名称，例如 Qwen' })
                  .fontSize(14)
                  .height(34)
                  .width('100%')
                  .backgroundColor(Theme.button(this.isDark))
                  .fontColor(Theme.text(this.isDark))
                  .placeholderColor(Theme.faintText(this.isDark))
                  .borderRadius(6)
                  .onChange((value: string) => { this.customAgentName = value; })
                Row({ space: 8 }) {
                  TextInput({ text: this.customAgentCommand, placeholder: '可执行文件或启动命令' })
                    .fontSize(14)
                    .height(34)
                    .layoutWeight(1)
                    .backgroundColor(Theme.button(this.isDark))
                    .fontColor(Theme.text(this.isDark))
                    .placeholderColor(Theme.faintText(this.isDark))
                    .borderRadius(6)
                    .onChange((value: string) => { this.customAgentCommand = value; })
                    .onSubmit(() => { this.addCustomAgent(); })
                  Button('添加')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.canAddCustomAgent() ? Theme.onAccent(this.isDark) :
                      Theme.faintText(this.isDark))
                    .height(34)
                    .width(64)
                    .backgroundColor(this.canAddCustomAgent() ? Theme.accent(this.isDark) :
                      Theme.button(this.isDark))
                    .borderRadius(7)
                    .enabled(this.canAddCustomAgent())
                    .onClick(() => { this.addCustomAgent(); })
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 12 })
            }
            .width('100%')
            .backgroundColor(Theme.input(this.isDark))
            .borderRadius(10)
            this.caption('添加、更新或移除后会立即保存；自定义智能体启动时统一使用 Gemini 标志。')
          } else if (this.tab === 3) {
            // ── Notifications ──
            Column() {
              Row() {
                Text('智能体完成任务或需要输入时通知')
                  .fontSize(15)
                  .fontColor(Theme.text(this.isDark))
                  .layoutWeight(1)
                  .margin({ right: 10 })
                Toggle({ type: ToggleType.Switch, isOn: this.notifyEnabled })
                  .selectedColor(Theme.accent(this.isDark))
                  .onChange((on: boolean) => { this.notifyEnabled = on; })
              }
              .width('100%')
              .height(46)
              .padding({ left: 12, right: 12 })
            }
            .width('100%')
            .backgroundColor(Theme.input(this.isDark))
            .borderRadius(10)
            .padding({ top: 2, bottom: 2 })
            this.caption('仅当你没有查看相应会话时，才会发送任务完成通知。')
            this.caption('可能还需要在 HarmonyOS 系统设置中授予通知权限。')
          } else {
            // ── About ──
            Column() {
              Image($r('app.media.terminai_icon_concept_white'))
                .width(92)
                .height(92)
                .objectFit(ImageFit.Contain)
                .borderRadius(18)
                .clip(true)
                .accessibilityLevel('no')
              Text('terminAI')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.text(this.isDark))
                .margin({ top: 10 })
              Text('面向编程智能体的本地 PTY 控制台')
                .fontSize(14)
                .fontColor(Theme.tertiary(this.isDark))
                .margin({ top: 5 })
              Text('受 herdrm 启发的 HarmonyOS PC 移植版')
                .fontSize(12)
                .fontColor(Theme.faintText(this.isDark))
                .margin({ top: 4 })
            }
            .width('100%')
            .height(250)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.card(this.isDark))
            .border({ width: 1, color: Theme.border(this.isDark), radius: 12 })
            .borderRadius(12)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
      }
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .width('100%')
      .height(420)

      Divider().color(Theme.divider(this.isDark)).strokeWidth(1)

      Row() {
        Text('设置会自动保存')
          .fontSize(12)
          .fontColor(Theme.faintText(this.isDark))
        Blank()
        Button('完成')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.onAccent(this.isDark))
          .backgroundColor(Theme.accent(this.isDark))
          .height(32)
          .borderRadius(7)
          .onClick(() => { this.controller?.close(); })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
    }
    .width(500)
    .backgroundColor(Theme.panel(this.isDark))
    .border({ width: 1, color: Theme.border(this.isDark), radius: 14 })
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }
}
