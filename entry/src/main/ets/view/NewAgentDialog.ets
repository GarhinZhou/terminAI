// New Agent sheet, ported from herdrm NewAgentSheet:
// SheetHeader + 4-column kind grid + space picker + footer actions.
import { picker, fileUri } from '@kit.CoreFileKit';
import libterminal from 'libterminal.so';
import { Theme } from '../common/Theme';
import { BrandIcon } from '../common/BrandIcon';
import { IconName, UiIcon } from '../common/Icons';
import { CustomAgentInfo, decodeCustomAgents } from '../model/CustomAgent';
import { remoteAgentsForDevice } from '../model/RemoteSshState';
import { overridesForDevice } from '../model/AgentOverrides';
import { LOCAL_DEVICE_ID } from '../model/ManagedDevice';

/** An executable discovered on PATH (shell or coding-agent CLI). */
class ProgramInfo {
  name: string = '';
  path: string = '';
  iconKind: string = '';

  constructor(name: string, path: string, iconKind: string) {
    this.name = name;
    this.path = path;
    this.iconKind = iconKind;
  }
}

@CustomDialog
export struct NewAgentDialog {
  controller?: CustomDialogController;
  onConfirm: (cwd: string, cmd: string, label: string, iconKind: string) => void = () => {};

  @StorageLink('defaultCwd') cwd: string = '~';
  @StorageProp('recentPaths') recentPaths: string[] = [];
  @State private programs: ProgramInfo[] = [];
  @State private selectedIdx: number = 0;
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('programOrder') programOrder: string = '';
  @StorageProp('defaultProgram') defaultProgram: string = '';
  @StorageProp('agentOverrides') agentOverrides: string = '';
  @StorageProp('customAgents') customAgents: string = '';
  @StorageProp('accent') accent: string = '';
  @StorageProp('selectedDeviceName') selectedDeviceName: string = '本机';
  @StorageProp('selectedDeviceTarget') selectedDeviceTarget: string = '';
  @StorageProp('selectedDeviceId') selectedDeviceId: string = '';
  @StorageProp('remoteAgentsEncoded') remoteAgentsEncoded: string = '';
  @State private hoveredProgram: string = '';
  private documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();

  aboutToAppear(): void {
    const pending = AppStorage.get<string>('pendingNewCwd');
    if (pending !== undefined && pending.length > 0) {
      this.cwd = pending;
      AppStorage.setOrCreate('pendingNewCwd', '');
    }
    this.selectedIdx = 0;
    if (this.selectedDeviceTarget.length > 0) {
      if (pending === undefined || pending.length === 0) {
        this.cwd = '~';
      }
      this.programs = this.remotePrograms();
      if (this.defaultProgram.length > 0) {
        const selected = this.programs.findIndex((item: ProgramInfo) => item.name === this.defaultProgram);
        if (selected >= 0) {
          this.selectedIdx = selected;
        }
      }
      return;
    }
    try {
      const probed: ProgramInfo[] = [];
      for (const item of libterminal.listPrograms()) {
        if (item.name !== 'sh' && item.name !== 'zsh') {
          probed.push(new ProgramInfo(item.name, item.path, item.name));
        }
      }
      const order = this.programOrder.split(',').filter((s: string) => s.length > 0);
      const list: ProgramInfo[] = [new ProgramInfo('zsh', '/usr/bin/zsh', 'zsh')];
      for (const name of order) {
        if (name === 'zsh') continue;
        const hit = probed.find((p: ProgramInfo) => p.name === name);
        if (hit) list.push(new ProgramInfo(hit.name, hit.path, hit.iconKind));
      }
      for (const p of probed) {
        if (!list.some((it: ProgramInfo) => it.name === p.name)) {
          list.push(new ProgramInfo(p.name, p.path, p.iconKind));
        }
      }
      // Settings → Agents binary-path overrides (local device) win over probed paths.
      const ov = overridesForDevice(this.agentOverrides, LOCAL_DEVICE_ID);
      Object.keys(ov).forEach((k: string) => {
        const hit = list.findIndex((it: ProgramInfo) => it.name === k);
        if (hit >= 0) {
          list[hit] = new ProgramInfo(k, ov[k], k);
        } else {
          list.push(new ProgramInfo(k, ov[k], k));
        }
      });
      for (const custom of decodeCustomAgents(this.customAgents)
        .filter((item: CustomAgentInfo) => item.deviceId === LOCAL_DEVICE_ID)) {
        const hit = list.findIndex((it: ProgramInfo) =>
          it.name.toLowerCase() === custom.name.toLowerCase());
        const customProgram = new ProgramInfo(custom.name, custom.command, 'gemini');
        if (hit >= 0) {
          list[hit] = customProgram;
        } else {
          list.push(customProgram);
        }
      }
      this.programs = list;
      if (this.defaultProgram.length > 0) {
        const di = list.findIndex((p: ProgramInfo) => p.name === this.defaultProgram);
        if (di >= 0) this.selectedIdx = di;
      }
    } catch (e) {
      console.error('TERMINAI listPrograms failed: ' + JSON.stringify(e));
      const fallback: ProgramInfo[] = [new ProgramInfo('zsh', '/usr/bin/zsh', 'zsh')];
      for (const custom of decodeCustomAgents(this.customAgents)
        .filter((item: CustomAgentInfo) => item.deviceId === LOCAL_DEVICE_ID)) {
        fallback.push(new ProgramInfo(custom.name, custom.command, 'gemini'));
      }
      this.programs = fallback;
    }
  }

  private remotePrograms(): ProgramInfo[] {
    const shellName = AppStorage.get<string>('remoteShell_' + this.selectedDeviceId);
    const defaultShell = shellName !== undefined && shellName.length > 0 ? shellName : 'sh';
    const list: ProgramInfo[] = [new ProgramInfo(defaultShell, defaultShell, defaultShell)];
    const remoteAgents = remoteAgentsForDevice(this.remoteAgentsEncoded, this.selectedDeviceId);
    for (const agent of remoteAgents) {
      list.push(new ProgramInfo(agent.name, agent.path, agent.iconKind));
    }
    // Per-device binary-path overrides win over the scanned remote paths.
    const overrides = overridesForDevice(this.agentOverrides, this.selectedDeviceId);
    Object.keys(overrides).forEach((k: string) => {
      const hit = list.findIndex((item: ProgramInfo) => item.name === k);
      if (hit >= 0) {
        list[hit] = new ProgramInfo(k, overrides[k], k);
      }
    });
    // Custom agents defined for this device.
    for (const custom of decodeCustomAgents(this.customAgents)
      .filter((item: CustomAgentInfo) => item.deviceId === this.selectedDeviceId)) {
      const hit = list.findIndex((item: ProgramInfo) =>
        item.name.toLowerCase() === custom.name.toLowerCase());
      const customProgram = new ProgramInfo(custom.name, custom.command, 'gemini');
      if (hit >= 0) {
        list[hit] = customProgram;
      } else {
        list.push(customProgram);
      }
    }
    return list;
  }

  private confirm(): void {
    if (this.cwd.trim().length === 0) return;
    // Index 0 is always the default login shell for the selected device.
    if (this.selectedIdx === 0) {
      this.onConfirm(this.cwd.trim(), '', '', '');
    } else {
      const p = this.programs[this.selectedIdx];
      this.onConfirm(this.cwd.trim(), p.path, p.name, p.iconKind);
    }
    this.controller?.close();
  }

  private async pickDirectory(): Promise<void> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const uris: string[] = await this.documentPicker.select(options);
      if (uris.length > 0) {
        const fu = new fileUri.FileUri(uris[0]);
        this.cwd = fu.path;
      }
    } catch (e) {
      console.error('TERMINAI picker failed: ' + JSON.stringify(e));
    }
  }

  private accentOf(): string {
    return this.accent.length > 0 ? this.accent : Theme.accent(this.isDark);
  }

  /** Distinct space list for the SPACE picker. */
  private spaces(): string[] {
    const out: string[] = [];
    for (const p of this.recentPaths) {
      if (out.indexOf(p) < 0) out.push(p);
    }
    return out;
  }

  /** herdrm kind cell: icon letter + name, 58pt, selected = accent wash+border. */
  @Builder
  kindCell(p: ProgramInfo, idx: number) {
    Column() {
      if (p.iconKind === 'zsh') {
        UiIcon({
          name: IconName.Terminal,
          iconSize: 20,
          color: this.selectedIdx === idx ? Theme.text(this.isDark) : Theme.subText(this.isDark)
        })
      } else {
        BrandIcon({ kind: p.iconKind, iconSize: 20,
          color: this.selectedIdx === idx ? Theme.text(this.isDark) : Theme.subText(this.isDark),
          isDark: this.isDark })
      }
      Text(p.name)
        .fontSize(13)
        .fontWeight(this.selectedIdx === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selectedIdx === idx ? Theme.text(this.isDark) : Theme.subText(this.isDark))
        .maxLines(1)
        .margin({ top: 6 })
    }
    .width('23%')
    .height(64)
    .justifyContent(FlexAlign.Center)
    .borderRadius(9)
    .backgroundColor(this.selectedIdx === idx ? Theme.accentWash(this.isDark) :
      (this.hoveredProgram === p.name ? Theme.hover(this.isDark) : Theme.input(this.isDark)))
    .border({ width: this.selectedIdx === idx ? 1.5 : 0, color: this.accentOf(), radius: 9 })
    .margin({ right: 8, bottom: 8 })
    .onHover((isHover: boolean) => { this.hoveredProgram = isHover ? p.name : ''; })
    .onClick(() => { this.selectedIdx = idx; })
    .accessibilityText(p.name)
    .accessibilitySelected(this.selectedIdx === idx)
  }

  @Builder
  sheetHeader() {
    Row() {
      Column() {
        UiIcon({ name: IconName.Spark, iconSize: 20, color: this.accentOf() })
      }
        .width(34)
        .height(38)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.accentWash(this.isDark))
        .borderRadius(9)
      Column() {
        Text('新建智能体')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text(this.isDark))
        Text('在' + this.selectedDeviceName + '的所选空间中启动，并连接到实时终端')
          .fontSize(13)
          .fontColor(Theme.tertiary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 11 })
      Blank()
    }
    .width('100%')
    .padding(16)
  }

  build() {
    Column() {
      this.sheetHeader()

      Divider().color(Theme.divider(this.isDark)).strokeWidth(1)

      Column() {
        Text('程序')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.tertiary(this.isDark))
          .width('100%')
          .margin({ bottom: 8 })

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.programs, (p: ProgramInfo, idx: number) => {
            this.kindCell(p, idx)
          }, (p: ProgramInfo) => p.name + '_' + p.path)
        }
        .width('100%')

        Text('空间')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.tertiary(this.isDark))
          .width('100%')
          .margin({ top: 8, bottom: 8 })

        Row() {
          TextInput({ text: this.cwd })
            .fontSize(16)
            .height(40)
            .layoutWeight(1)
            .backgroundColor(Theme.input(this.isDark))
            .fontColor(Theme.text(this.isDark))
            .placeholderColor(Theme.faintText(this.isDark))
            .caretColor(this.accentOf())
            .borderRadius(7)
            .onChange((v: string) => { this.cwd = v; })
            .onSubmit(() => { this.confirm(); })
          if (this.selectedDeviceTarget.length === 0) {
            Blank().width(6)
            Row() {
              UiIcon({ name: IconName.Browse, iconSize: 15, color: Theme.text(this.isDark) })
              Text('浏览…')
                .fontSize(14)
                .fontColor(Theme.text(this.isDark))
                .margin({ left: 6 })
            }
              .padding({ left: 12, right: 12 })
              .backgroundColor(Theme.button(this.isDark))
              .height(40)
              .borderRadius(7)
              .onClick(() => { this.pickDirectory(); })
              .accessibilityText('浏览文件夹')
          }
        }
        .width('100%')

        // Recent spaces as quick picks
        if (this.selectedDeviceTarget.length === 0 && this.spaces().length > 0) {
          Text('最近使用的空间')
            .fontSize(12)
            .fontColor(Theme.faintText(this.isDark))
            .margin({ top: 8, bottom: 4 })
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.spaces(), (p: string) => {
              Text(p.length > 40 ? '…' + p.substring(p.length - 38) : p)
                .fontSize(13)
                .fontColor(this.cwd === p ? Theme.onAccent(this.isDark) : Theme.subText(this.isDark))
                .backgroundColor(this.cwd === p ? this.accentOf() : Theme.input(this.isDark))
                .borderRadius(12)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .margin({ right: 8, bottom: 6 })
                .onClick(() => { this.cwd = p; })
            }, (p: string) => p)
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })

      Divider().color(Theme.divider(this.isDark)).strokeWidth(1)

      Row() {
        Blank()
        Button('取消')
          .fontSize(15)
          .fontColor(Theme.text(this.isDark))
          .backgroundColor(Theme.button(this.isDark))
          .height(32)
          .borderRadius(7)
          .margin({ right: 8 })
          .onClick(() => { this.controller?.close(); })
        Button('启动智能体')
          .fontSize(15)
          .fontColor(Theme.onAccent(this.isDark))
          .backgroundColor(this.accentOf())
          .height(32)
          .borderRadius(7)
          .onClick(() => { this.confirm(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
    .width(480)
    .backgroundColor(Theme.panel(this.isDark))
    .border({ width: 1, color: Theme.border(this.isDark), radius: 14 })
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }
}
