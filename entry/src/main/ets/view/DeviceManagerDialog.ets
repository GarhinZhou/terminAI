import { picker } from '@kit.CoreFileKit';
import { Theme } from '../common/Theme';
import { IconName, UiIcon } from '../common/Icons';
import { ManagedDevice, SshAuthMode, decodeDevices, encodeDevices, isValidIdentityFile,
  isValidSshTarget, localDevice, newDeviceId } from '../model/ManagedDevice';
import { SshConnectionState, connectionStateOf } from '../model/RemoteSshState';
import { SshCredentialKind, SshCredentialStore } from '../model/SshCredentialStore';
import { SshIdentityStore } from '../model/SshIdentityStore';

@CustomDialog
export struct DeviceManagerDialog {
  controller?: CustomDialogController;
  getDeviceStatus: (id: string) => string = () => '未连接';
  onSelect: (id: string) => void = () => {};
  onDevicesChanged: (value: string) => void = () => {};
  onDeviceSaved: (device: ManagedDevice, credential: string, isNew: boolean) => Promise<boolean> =
    async () => false;
  onDeviceCommitted: (device: ManagedDevice) => void = () => {};
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
  @State private authMode: SshAuthMode = SshAuthMode.Password;
  @State private identityFile: string = '';
  @State private credential: string = '';
  @State private formVisible: boolean = false;
  @State private errorText: string = '';
  @State private hoveredKey: string = '';
  @State private storedCredential: boolean = false;
  @State private storedCredentialLength: number = 0;
  @State private checkingCredential: boolean = false;
  @State private saving: boolean = false;
  @State private pickingIdentity: boolean = false;
  private originalIdentityFile: string = '';
  private pendingImportedIdentity: string = '';

  aboutToAppear(): void {
    this.devices = decodeDevices(this.devicesEncoded);
  }

  aboutToDisappear(): void {
    this.discardPendingIdentity();
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
    if (this.connectionState(device) === SshConnectionState.Reconnecting) {
      return '立即重连';
    }
    return this.connectionReady(device) ? '打开终端' : '连接';
  }

  private statusColor(device: ManagedDevice): string {
    if (device.isLocal() || this.connectionReady(device)) {
      return Theme.success(this.isDark);
    }
    const state = this.connectionState(device);
    if (state === SshConnectionState.Connecting || state === SshConnectionState.Scanning ||
      state === SshConnectionState.Reconnecting) {
      return this.accentOf();
    }
    if (state === SshConnectionState.AuthFailed || state === SshConnectionState.NeedsCredential ||
      state === SshConnectionState.HostKeyFailed || state === SshConnectionState.NetworkFailed ||
      state === SshConnectionState.Failed) {
      return Theme.danger(this.isDark);
    }
    return Theme.tertiary(this.isDark);
  }

  private authModeLabel(device: ManagedDevice): string {
    return device.authMode === SshAuthMode.PrivateKey ? '私钥' : '密码 / 默认密钥';
  }

  private appFilesDir(): string {
    const context = this.getUIContext().getHostContext();
    return context === undefined ? '' : context.filesDir;
  }

  private identityManagedByApp(): boolean {
    return SshIdentityStore.isManaged(this.appFilesDir(), this.identityFile.trim());
  }

  private discardPendingIdentity(): void {
    const pending = this.pendingImportedIdentity;
    this.pendingImportedIdentity = '';
    if (pending.length > 0) {
      SshIdentityStore.removeManaged(this.appFilesDir(), pending).catch(() => {});
    }
  }

  private beginAdd(): void {
    this.discardPendingIdentity();
    this.editingId = '';
    this.name = '';
    this.target = '';
    this.authMode = SshAuthMode.Password;
    this.identityFile = '';
    this.originalIdentityFile = '';
    this.credential = '';
    this.storedCredential = false;
    this.storedCredentialLength = 0;
    this.checkingCredential = false;
    this.saving = false;
    this.pickingIdentity = false;
    this.errorText = '';
    this.formVisible = true;
  }

  private beginEdit(device: ManagedDevice): void {
    this.discardPendingIdentity();
    this.editingId = device.id;
    this.name = device.name;
    this.target = device.sshTarget;
    this.authMode = device.authMode;
    this.identityFile = device.identityFile;
    this.originalIdentityFile = device.identityFile;
    this.credential = '';
    this.storedCredential = false;
    this.storedCredentialLength = 0;
    this.checkingCredential = true;
    this.saving = false;
    this.pickingIdentity = false;
    this.errorText = '';
    this.formVisible = true;
    this.refreshStoredCredential(device.id, device.authMode);
  }

  private credentialKind(mode: SshAuthMode): SshCredentialKind {
    return mode === SshAuthMode.PrivateKey ?
      SshCredentialKind.KeyPassphrase : SshCredentialKind.Password;
  }

  private async refreshStoredCredential(deviceId: string, mode: SshAuthMode): Promise<void> {
    const length = await SshCredentialStore.secretLength(deviceId, this.credentialKind(mode));
    if (this.editingId === deviceId && this.formVisible && this.authMode === mode) {
      this.storedCredentialLength = length;
      this.storedCredential = length > 0;
      this.checkingCredential = false;
    }
  }

  private selectAuthMode(mode: SshAuthMode): void {
    if (this.authMode === mode || this.saving) {
      return;
    }
    this.authMode = mode;
    this.credential = '';
    this.storedCredential = false;
    this.storedCredentialLength = 0;
    this.checkingCredential = this.editingId.length > 0;
    this.errorText = '';
    if (this.editingId.length > 0) {
      this.refreshStoredCredential(this.editingId, mode);
    }
  }

  private credentialCharacterCount(value: string): number {
    let count = 0;
    for (const character of value) {
      if (character.length > 0) {
        count++;
      }
    }
    return count;
  }

  private storedCredentialPlaceholder(): string {
    let bullets = '';
    for (let index = 0; index < this.storedCredentialLength; index++) {
      bullets += '•';
    }
    return bullets + '（已保存）';
  }

  private async pickIdentityFile(): Promise<void> {
    if (this.pickingIdentity || this.saving) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.errorText = '无法打开系统文件选择器';
      return;
    }
    this.pickingIdentity = true;
    let uris: string[] = [];
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FILE;
      options.maxSelectNumber = 1;
      const documentPicker = new picker.DocumentViewPicker(context);
      uris = await documentPicker.select(options);
    } catch (e) {
      // Closing the system Picker is a normal cancel path.
      console.info('TERMINAI SSH identity picker closed');
      this.pickingIdentity = false;
      return;
    }
    if (uris.length === 0) {
      this.pickingIdentity = false;
      return;
    }

    try {
      const imported = await SshIdentityStore.importFromPickerUri(context.filesDir, uris[0]);
      const previousPending = this.pendingImportedIdentity;
      this.pendingImportedIdentity = imported;
      this.identityFile = imported;
      this.errorText = '';
      if (previousPending.length > 0 && previousPending !== imported) {
        SshIdentityStore.removeManaged(context.filesDir, previousPending).catch(() => {});
      }
    } catch (e) {
      this.errorText = e instanceof Error ? e.message : '私钥文件导入失败，请重新选择';
      console.error('TERMINAI SSH identity import failed');
    }
    this.pickingIdentity = false;
  }

  private cancelEditor(): void {
    this.discardPendingIdentity();
    this.formVisible = false;
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
    if (this.authMode === SshAuthMode.PrivateKey && !isValidIdentityFile(this.identityFile)) {
      this.errorText = '请输入私钥文件路径，例如 ~/.ssh/id_ed25519';
      return;
    }
    if (this.credential.indexOf('\n') >= 0 || this.credential.indexOf('\r') >= 0 ||
      this.credential.length > 1024) {
      this.errorText = (this.authMode === SshAuthMode.PrivateKey ? '私钥口令' : '密码') +
        '不能包含换行，且长度不能超过 1024 个字符';
      return;
    }
    const name = this.name.trim().length > 0 ? this.name.trim() : target;
    const isNew = this.editingId.length === 0;
    let savedDevice: ManagedDevice;
    const nextDevices: ManagedDevice[] = [...this.devices];
    if (!isNew) {
      const index = nextDevices.findIndex((item: ManagedDevice) => item.id === this.editingId);
      if (index < 0) {
        this.errorText = '设备不存在，请重新添加';
        return;
      }
      const identityPath = this.authMode === SshAuthMode.PrivateKey ? this.identityFile.trim() : '';
      savedDevice = new ManagedDevice(this.editingId, name, target, this.authMode, identityPath);
      nextDevices[index] = savedDevice;
    } else {
      const identityPath = this.authMode === SshAuthMode.PrivateKey ? this.identityFile.trim() : '';
      savedDevice = new ManagedDevice(newDeviceId(), name, target, this.authMode, identityPath);
      nextDevices.push(savedDevice);
    }
    this.saving = true;
    const completed = await this.onDeviceSaved(savedDevice, this.credential, isNew);
    if (!completed) {
      this.saving = false;
      this.errorText = 'SSH 登录凭据未能保存，请重试';
      return;
    }
    // Commit the visible/persisted device list only after credential storage
    // succeeds. updateDevices may close sessions whose target changed, so it
    // must never run on the failure path.
    this.devices = nextDevices;
    this.devicesEncoded = encodeDevices(this.devices);
    this.onDevicesChanged(this.devicesEncoded);
    this.onDeviceCommitted(savedDevice);
    if (this.credential.length > 0) {
      this.storedCredential = true;
      this.storedCredentialLength = this.credentialCharacterCount(this.credential);
    }
    const filesDir = this.appFilesDir();
    const committedIdentity = savedDevice.identityFile;
    const pendingIdentity = this.pendingImportedIdentity;
    this.pendingImportedIdentity = '';
    if (pendingIdentity.length > 0 && pendingIdentity !== committedIdentity) {
      SshIdentityStore.removeManaged(filesDir, pendingIdentity).catch(() => {});
    }
    if (this.originalIdentityFile.length > 0 && this.originalIdentityFile !== committedIdentity) {
      SshIdentityStore.removeManaged(filesDir, this.originalIdentityFile).catch(() => {});
    }
    this.originalIdentityFile = committedIdentity;
    this.credential = '';
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
        Text(device.isLocal() ? '当前 HarmonyOS 设备' :
          device.sshTarget + ' · SSH · ' + this.authModeLabel(device))
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
  authModeButton(mode: SshAuthMode, label: string) {
    Button(label)
      .fontSize(12.5)
      .height(30)
      .layoutWeight(1)
      .fontColor(this.authMode === mode ? this.accentOf() : Theme.subText(this.isDark))
      .backgroundColor(this.authMode === mode ? Theme.accentWash(this.isDark) : Theme.input(this.isDark))
      .borderRadius(7)
      .enabled(!this.saving)
      .onClick(() => { this.selectAuthMode(mode); })
      .accessibilitySelected(this.authMode === mode)
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

      Row({ space: 7 }) {
        this.authModeButton(SshAuthMode.Password, '密码 / 默认密钥')
        this.authModeButton(SshAuthMode.PrivateKey, '指定私钥')
      }
      .width('100%')
      .margin({ top: 7 })

      if (this.authMode === SshAuthMode.PrivateKey) {
        Row({ space: 7 }) {
          TextInput({ placeholder: '私钥路径，例如 ~/.ssh/id_ed25519', text: this.identityFile })
            .fontSize(14)
            .height(38)
            .layoutWeight(1)
            .backgroundColor(Theme.input(this.isDark))
            .fontColor(Theme.text(this.isDark))
            .caretColor(this.accentOf())
            .borderRadius(7)
            .enabled(!this.saving && !this.pickingIdentity)
            .onChange((value: string) => { this.identityFile = value; this.errorText = ''; })
          Button(this.pickingIdentity ? '导入中…' : '选择文件')
            .fontSize(12.5)
            .height(38)
            .width(86)
            .fontColor(this.accentOf())
            .backgroundColor(Theme.accentWash(this.isDark))
            .borderRadius(7)
            .enabled(!this.saving && !this.pickingIdentity)
            .onClick(() => { this.pickIdentityFile(); })
            .accessibilityText('使用系统文件选择器选择 SSH 私钥')
        }
        .width('100%')
        .margin({ top: 7 })
      }

      TextInput({
        placeholder: this.storedCredential ? this.storedCredentialPlaceholder() :
          (this.authMode === SshAuthMode.PrivateKey ? '私钥口令（无口令可留空）' :
            (this.editingId.length > 0 ? '密码（留空则不修改）' : '密码（默认密钥可用时可留空）')),
        text: this.credential
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
        .onChange((value: string) => { this.credential = value; this.errorText = ''; })
        .onSubmit(() => { this.saveDevice(); })
      Text(this.checkingCredential ? '正在检查已保存的 SSH 凭据…' :
        (this.storedCredential ?
          (this.authMode === SshAuthMode.PrivateKey ? '已保存私钥口令，留空不会修改。' :
            '已保存登录密码，留空不会修改。') :
          (this.authMode === SshAuthMode.PrivateKey ?
            (this.identityManagedByApp() ?
              '私钥副本已保存在应用沙箱并限制访问权限；删除设备时会同步清理。' :
              '可手动填写路径，或通过系统选择器将私钥安全导入应用沙箱。请先将公钥加入远端 authorized_keys。') :
            '密码由系统关键资产服务加密保存在本机；也兼容 SSH 配置、默认密钥和 SSH Agent。')))
        .fontSize(10.5)
        .fontColor(this.storedCredential ? Theme.success(this.isDark) : Theme.tertiary(this.isDark))
        .width('100%')
        .margin({ top: 5 })
        .accessibilityText(this.storedCredential ? '已保存 SSH 登录凭据，留空不会修改' :
          '尚未保存 SSH 登录凭据')
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
          .onClick(() => { this.cancelEditor(); })
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
      .constraintSize({ maxHeight: this.formVisible ? 190 : 310 })
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
