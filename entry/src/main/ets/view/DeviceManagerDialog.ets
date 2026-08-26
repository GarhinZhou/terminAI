import { Theme } from '../common/Theme';
import { IconName, UiIcon } from '../common/Icons';
import { ManagedDevice, decodeDevices, encodeDevices, isValidSshTarget,
  localDevice, newDeviceId } from '../model/ManagedDevice';
import { SshConnectionState, connectionStateOf } from '../model/RemoteSshState';
import { SshCredentialStore } from '../model/SshCredentialStore';

@CustomDialog
export struct DeviceManagerDialog {
  controller?: CustomDialogController;
  getDeviceStatus: (id: string) => string = () => '未连接';
  onSelect: (id: string) => void = () => {};
  onDevicesChanged: (value: string) => void = () => {};
  onDeviceSaved: (device: ManagedDevice, password: string, isNew: boolean) => Promise<boolean> =
    async () => false;
  onDeviceRemoved: (device: ManagedDevice) => void = () => {};
  onConnect: (device: ManagedDevice) => void = () => {};

  @StorageLink('devicesEncoded') devicesEncoded: string = '';
  @StorageLink('selectedDeviceId') selectedDeviceId: string = '';
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('accent') accent: string = '';
  @StorageProp('sshConnectionStates') sshConnectionStates: string = '';
  @State private devices: ManagedDevice[] = [localDevice()];
  @State private editingId: string = '';
  @State private name: string = '';
  @State private target: string = '';
  @State private password: string = '';
  @State private formVisible: boolean = false;
  @State private errorText: string = '';
  @State private hoveredKey: string = '';
  @State private storedPassword: boolean = false;
  @State private storedPasswordLength: number = 0;
  @State private checkingPassword: boolean = false;
  @State private saving: boolean = false;

  aboutToAppear(): void {
    this.devices = decodeDevices(this.devicesEncoded);
  }

  private accentOf(): string {
    return this.accent.length > 0 ? this.accent : Theme.accent(this.isDark);
  }

  private connectionState(device: ManagedDevice): SshConnectionState {
    return connectionStateOf(this.sshConnectionStates, device.id);
  }

  private deviceStatusText(device: ManagedDevice): string {
    if (device.isLocal()) {
      return this.getDeviceStatus(device.id);
    }
    const state = this.connectionState(device);
    return state === SshConnectionState.Disconnected ? this.getDeviceStatus(device.id) : state;
  }

  private connectionBusy(device: ManagedDevice): boolean {
    const state = this.connectionState(device);
    return state === SshConnectionState.Connecting || state === SshConnectionState.Scanning;
  }

  private connectionReady(device: ManagedDevice): boolean {
    const state = this.connectionState(device);
    return state === SshConnectionState.Connected || state === SshConnectionState.ConnectedScanFailed;
  }

  private connectButtonLabel(device: ManagedDevice): string {
    if (this.connectionBusy(device)) {
      return '连接中';
    }
    return this.connectionReady(device) ? '打开终端' : '连接';
  }

  private statusColor(device: ManagedDevice): string {
    if (device.isLocal() || this.connectionReady(device)) {
      return Theme.success(this.isDark);
    }
    const state = this.connectionState(device);
    if (state === SshConnectionState.Connecting || state === SshConnectionState.Scanning) {
      return this.accentOf();
    }
    if (state === SshConnectionState.AuthFailed || state === SshConnectionState.NeedsPassword ||
      state === SshConnectionState.Failed) {
      return Theme.danger(this.isDark);
    }
    return Theme.tertiary(this.isDark);
  }

  private beginAdd(): void {
    this.editingId = '';
    this.name = '';
    this.target = '';
    this.password = '';
    this.storedPassword = false;
    this.storedPasswordLength = 0;
    this.checkingPassword = false;
    this.saving = false;
    this.errorText = '';
    this.formVisible = true;
  }

  private beginEdit(device: ManagedDevice): void {
    this.editingId = device.id;
    this.name = device.name;
    this.target = device.sshTarget;
    this.password = '';
    this.storedPassword = false;
    this.storedPasswordLength = 0;
    this.checkingPassword = true;
    this.saving = false;
    this.errorText = '';
    this.formVisible = true;
    this.refreshStoredPassword(device.id);
  }

  private async refreshStoredPassword(deviceId: string): Promise<void> {
    const length = await SshCredentialStore.passwordLength(deviceId);
    if (this.editingId === deviceId && this.formVisible) {
      this.storedPasswordLength = length;
      this.storedPassword = length > 0;
      this.checkingPassword = false;
    }
  }

  private passwordCharacterCount(value: string): number {
    let count = 0;
    for (const character of value) {
      if (character.length > 0) {
        count++;
      }
    }
    return count;
  }

  private storedPasswordPlaceholder(): string {
    let bullets = '';
    for (let index = 0; index < this.storedPasswordLength; index++) {
      bullets += '•';
    }
    return bullets + '（已保存）';
  }

  private async saveDevice(): Promise<void> {
    if (this.saving) {
      return;
    }
    const target = this.target.trim();
    if (!isValidSshTarget(target)) {
      this.errorText = '请输入有效的 SSH 目标，例如 user@host 或 user@host:2222';
      return;
    }
    if (this.password.indexOf('\n') >= 0 || this.password.indexOf('\r') >= 0 ||
      this.password.length > 1024) {
      this.errorText = '密码不能包含换行，且长度不能超过 1024 个字符';
      return;
    }
    const name = this.name.trim().length > 0 ? this.name.trim() : target;
    const isNew = this.editingId.length === 0;
    let savedDevice: ManagedDevice;
    if (!isNew) {
      const index = this.devices.findIndex((item: ManagedDevice) => item.id === this.editingId);
      if (index < 0) {
        this.errorText = '设备不存在，请重新添加';
        return;
      }
      savedDevice = new ManagedDevice(this.editingId, name, target);
      this.devices[index] = savedDevice;
    } else {
      savedDevice = new ManagedDevice(newDeviceId(), name, target);
      this.devices.push(savedDevice);
      // If credential persistence fails, a retry edits this same device rather
      // than appending a duplicate row.
      this.editingId = savedDevice.id;
    }
    this.saving = true;
    this.devices = [...this.devices];
    this.devicesEncoded = encodeDevices(this.devices);
    this.onDevicesChanged(this.devicesEncoded);
    const completed = await this.onDeviceSaved(savedDevice, this.password, isNew);
    if (!completed) {
      this.saving = false;
      this.errorText = '登录密码未能保存，请重试';
      return;
    }
    if (this.password.length > 0) {
      this.storedPassword = true;
      this.storedPasswordLength = this.passwordCharacterCount(this.password);
    }
    this.password = '';
    this.saving = false;
    this.formVisible = false;
  }

  private removeDevice(device: ManagedDevice): void {
    this.devices = this.devices.filter((item: ManagedDevice) => item.id !== device.id);
    this.devicesEncoded = encodeDevices(this.devices);
    if (this.selectedDeviceId === device.id) {
      this.selectedDeviceId = '';
      this.onSelect('');
    }
    this.onDevicesChanged(this.devicesEncoded);
    this.onDeviceRemoved(device);
  }

  private selectDevice(id: string): void {
    this.selectedDeviceId = id;
    this.onSelect(id);
  }

  @Builder
  deviceRow(device: ManagedDevice) {
    Row() {
      Column() {
        UiIcon({
          name: IconName.Terminal,
          iconSize: 15,
          color: this.selectedDeviceId === device.id ? this.accentOf() : Theme.subText(this.isDark)
        })
      }
      .width(30)
      .height(30)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.input(this.isDark))
      .borderRadius(8)

      Column() {
        Row() {
          Text(device.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text(this.isDark))
            .maxLines(1)
          Text(this.deviceStatusText(device))
            .fontSize(10.5)
            .fontColor(this.statusColor(device))
            .margin({ left: 7 })
        }
        .width('100%')
        Text(device.isLocal() ? '当前 HarmonyOS 设备' : device.sshTarget + ' · SSH')
          .fontSize(11.5)
          .fontColor(Theme.tertiary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 9 })

      if (this.selectedDeviceId === device.id) {
        UiIcon({ name: IconName.Check, iconSize: 13, color: this.accentOf() })
          .margin({ right: 7 })
      }
      if (!device.isLocal()) {
        Button(this.connectButtonLabel(device))
          .fontSize(11.5)
          .height(26)
          .fontColor(this.connectionReady(device) ? Theme.onAccent(this.isDark) : this.accentOf())
          .backgroundColor(this.connectionReady(device) ? this.accentOf() : Theme.accentWash(this.isDark))
          .borderRadius(6)
          .enabled(!this.connectionBusy(device))
          .onClick(() => {
            this.selectDevice(device.id);
            this.onConnect(device);
          })
          .accessibilityText(this.connectButtonLabel(device) + '，' + device.name)
        Button('编辑')
          .fontSize(11.5)
          .height(26)
          .margin({ left: 5 })
          .fontColor(Theme.subText(this.isDark))
          .backgroundColor(Theme.button(this.isDark))
          .borderRadius(6)
          .onClick(() => { this.beginEdit(device); })
        Button('移除')
          .fontSize(11.5)
          .height(26)
          .fontColor(Theme.danger(this.isDark))
          .backgroundColor(Theme.button(this.isDark))
          .borderRadius(6)
          .margin({ left: 5 })
          .onClick(() => { this.removeDevice(device); })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 9, right: 9 })
    .borderRadius(9)
    .backgroundColor(this.selectedDeviceId === device.id ? Theme.accentWash(this.isDark) :
      (this.hoveredKey === device.id ? Theme.hover(this.isDark) : '#00000000'))
    .onHover((hovered: boolean) => { this.hoveredKey = hovered ? device.id : ''; })
    .onClick(() => { this.selectDevice(device.id); })
    .accessibilityText(device.name + '，' + (device.isLocal() ? '本机' : 'SSH ' + device.sshTarget) +
      '，' + this.deviceStatusText(device))
    .accessibilitySelected(this.selectedDeviceId === device.id)
  }

  @Builder
  allDevicesRow() {
    Row() {
      Column() {
        UiIcon({ name: IconName.Grid, iconSize: 15,
          color: this.selectedDeviceId.length === 0 ? this.accentOf() : Theme.subText(this.isDark) })
      }
      .width(30)
      .height(30)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.input(this.isDark))
      .borderRadius(8)
      Column() {
        Text('全部设备')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text(this.isDark))
        Text(this.devices.length.toString() + ' 台设备')
          .fontSize(11.5)
          .fontColor(Theme.tertiary(this.isDark))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 9 })
      if (this.selectedDeviceId.length === 0) {
        UiIcon({ name: IconName.Check, iconSize: 13, color: this.accentOf() })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 9, right: 12 })
    .borderRadius(9)
    .backgroundColor(this.selectedDeviceId.length === 0 ? Theme.accentWash(this.isDark) : '#00000000')
    .onClick(() => { this.selectDevice(''); })
    .accessibilityText('全部设备，' + this.devices.length.toString() + ' 台')
    .accessibilitySelected(this.selectedDeviceId.length === 0)
  }

  @Builder
  editor() {
    Column() {
      Text(this.editingId.length > 0 ? '编辑 SSH 设备' : '添加 SSH 设备')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text(this.isDark))
        .width('100%')
      TextInput({ placeholder: '设备名称，例如 开发机', text: this.name })
        .fontSize(14)
        .height(38)
        .backgroundColor(Theme.input(this.isDark))
        .fontColor(Theme.text(this.isDark))
        .caretColor(this.accentOf())
        .borderRadius(7)
        .enabled(!this.saving)
        .margin({ top: 8 })
        .onChange((value: string) => { this.name = value; })
      TextInput({ placeholder: 'user@host、user@host:2222 或 SSH 配置别名', text: this.target })
        .fontSize(14)
        .height(38)
        .backgroundColor(Theme.input(this.isDark))
        .fontColor(Theme.text(this.isDark))
        .caretColor(this.accentOf())
        .borderRadius(7)
        .enabled(!this.saving)
        .margin({ top: 7 })
        .onChange((value: string) => { this.target = value; this.errorText = ''; })
      TextInput({
        placeholder: this.storedPassword ? this.storedPasswordPlaceholder() :
          (this.editingId.length > 0 ? '密码（留空则不修改）' : '密码（密钥认证可留空）'),
        text: this.password
      })
        .type(InputType.Password)
        .fontSize(14)
        .height(38)
        .backgroundColor(Theme.input(this.isDark))
        .fontColor(Theme.text(this.isDark))
        .caretColor(this.accentOf())
        .borderRadius(7)
        .enabled(!this.saving)
        .margin({ top: 7 })
        .onChange((value: string) => { this.password = value; this.errorText = ''; })
        .onSubmit(() => { this.saveDevice(); })
      Text(this.checkingPassword ? '正在检查已保存的登录密码…' :
        (this.storedPassword ? '已保存登录密码，留空不会修改。' :
          '密码由系统关键资产服务加密保存在本机，仅用于此 SSH 设备。'))
        .fontSize(10.5)
        .fontColor(this.storedPassword ? Theme.success(this.isDark) : Theme.tertiary(this.isDark))
        .width('100%')
        .margin({ top: 5 })
        .accessibilityText(this.storedPassword ? '已保存登录密码，留空不会修改' : '尚未保存登录密码')
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(11.5)
          .fontColor(Theme.danger(this.isDark))
          .width('100%')
          .margin({ top: 6 })
      }
      Row() {
        Blank()
        Button('取消')
          .fontSize(13)
          .height(30)
          .backgroundColor(Theme.button(this.isDark))
          .fontColor(Theme.text(this.isDark))
          .borderRadius(7)
          .enabled(!this.saving)
          .onClick(() => { this.formVisible = false; })
        Button(this.saving ? '保存中…' : (this.editingId.length > 0 ? '保存' : '添加'))
          .fontSize(13)
          .height(30)
          .backgroundColor(this.accentOf())
          .fontColor(Theme.onAccent(this.isDark))
          .borderRadius(7)
          .enabled(!this.saving)
          .margin({ left: 7 })
          .onClick(() => { this.saveDevice(); })
      }
      .width('100%')
      .margin({ top: 9 })
    }
    .width('100%')
    .padding(10)
    .backgroundColor(Theme.windowBg(this.isDark))
    .border({ width: 1, color: Theme.border(this.isDark), radius: 9 })
    .borderRadius(9)
  }

  build() {
    Column() {
      Row() {
        Column() {
          UiIcon({ name: IconName.Grid, iconSize: 19, color: this.accentOf() })
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.accentWash(this.isDark))
        .borderRadius(9)
        Column() {
          Text('设备管理')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.text(this.isDark))
          Text('管理本机与远程 SSH 智能体')
            .fontSize(12.5)
            .fontColor(Theme.tertiary(this.isDark))
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        Blank()
      }
      .width('100%')
      .padding(16)

      Divider().color(Theme.divider(this.isDark)).strokeWidth(1)

      List({ space: 2 }) {
        ListItem() { this.allDevicesRow() }
        ForEach(this.devices, (device: ManagedDevice) => {
          ListItem() { this.deviceRow(device) }
        }, (device: ManagedDevice) => device.id)
      }
      .width('100%')
      .constraintSize({ maxHeight: 310 })
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .scrollBar(BarState.Auto)

      if (this.formVisible) {
        Column() {
          this.editor()
        }
          .width('100%')
          // Padding stays inside the dialog's measured width. A 100%-wide
          // container plus horizontal margin exceeded the dialog boundary.
          .padding({ left: 10, right: 10, bottom: 10 })
      }

      Divider().color(Theme.divider(this.isDark)).strokeWidth(1)

      Row() {
        Button('添加 SSH 设备')
          .fontSize(13.5)
          .height(32)
          .backgroundColor(Theme.button(this.isDark))
          .fontColor(Theme.text(this.isDark))
          .borderRadius(7)
          .onClick(() => { this.beginAdd(); })
        Blank()
        Button('完成')
          .fontSize(13.5)
          .height(32)
          .backgroundColor(this.accentOf())
          .fontColor(Theme.onAccent(this.isDark))
          .borderRadius(7)
          .onClick(() => { this.controller?.close(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
    .width(560)
    .backgroundColor(Theme.panel(this.isDark))
    .border({ width: 1, color: Theme.border(this.isDark), radius: 14 })
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }
}
