// New Space sheet, ported from herdrm NewSpaceSheet + DirectoryPickerField:
// path field with up-arrow + Browse… and a 150pt inline folder browser.
import { picker, fileUri } from '@kit.CoreFileKit';
import libterminal from 'libterminal.so';
import { Theme } from '../common/Theme';
import { IconName, UiIcon } from '../common/Icons';

@CustomDialog
export struct NewSpaceDialog {
  controller?: CustomDialogController;
  onConfirm: (cwd: string) => void = () => {};

  @State private directory: string = '/storage/Users/currentUser';
  @State private entries: string[] = [];
  @StorageProp('isDark') isDark: boolean = true;
  @StorageProp('accent') accent: string = '';
  @StorageProp('selectedDeviceName') selectedDeviceName: string = '本机';
  @StorageProp('selectedDeviceTarget') selectedDeviceTarget: string = '';
  @State private hoveredEntry: string = '';
  private documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();

  aboutToAppear(): void {
    if (this.selectedDeviceTarget.length > 0) {
      this.directory = '~';
      this.entries = [];
      return;
    }
    this.directory = '/storage/Users/currentUser';
    this.refreshListing();
  }

  private accentOf(): string {
    return this.accent.length > 0 ? this.accent : Theme.accent(this.isDark);
  }

  private refreshListing(): void {
    if (this.selectedDeviceTarget.length > 0) {
      this.entries = [];
      return;
    }
    try {
      this.entries = libterminal.listDirs(this.directory.length > 0 ? this.directory : '/storage/Users/currentUser');
    } catch (e) {
      this.entries = [];
      console.error('TERMINAI listDirs failed: ' + JSON.stringify(e));
    }
  }

  private parentOf(path: string): string {
    let p = path;
    while (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
    const idx = p.lastIndexOf('/');
    if (idx <= 0) return '/';
    return p.substring(0, idx);
  }

  private descend(name: string): void {
    let base = this.directory;
    while (base.length > 1 && base.endsWith('/')) base = base.substring(0, base.length - 1);
    this.directory = (base === '/' ? '' : base) + '/' + name;
    this.refreshListing();
  }

  private async pickDirectory(): Promise<void> {
    try {
      const options = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      options.maxSelectNumber = 1;
      const uris: string[] = await this.documentPicker.select(options);
      if (uris.length > 0) {
        const fu = new fileUri.FileUri(uris[0]);
        this.directory = fu.path;
        this.refreshListing();
      }
    } catch (e) {
      console.error('TERMINAI picker failed: ' + JSON.stringify(e));
    }
  }

  @Builder
  sheetHeader() {
    Row() {
      Column() {
        UiIcon({ name: IconName.FolderAdd, iconSize: 20, color: this.accentOf() })
      }
      .width(34)
      .height(38)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.accentWash(this.isDark))
      .borderRadius(9)
      Column() {
        Text('新建空间')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text(this.isDark))
        Text('在' + this.selectedDeviceName + '上以项目目录为根目录创建空间')
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
        Text('目录')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.tertiary(this.isDark))
          .width('100%')
          .margin({ bottom: 6 })

        Row() {
          if (this.selectedDeviceTarget.length === 0) {
            Row() {
              UiIcon({ name: IconName.ArrowUp, iconSize: 17, color: Theme.text(this.isDark) })
            }
              .backgroundColor(Theme.button(this.isDark))
              .width(38)
              .height(40)
              .justifyContent(FlexAlign.Center)
              .borderRadius(7)
              .onClick(() => {
                this.directory = this.parentOf(this.directory);
                this.refreshListing();
              })
              .accessibilityText('上一级目录')
          }
          TextInput({ text: this.directory })
            .fontSize(16)
            .height(40)
            .layoutWeight(1)
            .backgroundColor(Theme.input(this.isDark))
            .fontColor(Theme.text(this.isDark))
            .placeholderColor(Theme.faintText(this.isDark))
            .caretColor(this.accentOf())
            .borderRadius(7)
            .margin({ left: this.selectedDeviceTarget.length === 0 ? 6 : 0 })
            .onChange((v: string) => { this.directory = v; })
            .onSubmit(() => {
              this.refreshListing();
            })
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

        // ── Inline folder browser (150pt) ──
        if (this.selectedDeviceTarget.length === 0) {
          List() {
          ForEach(this.entries, (name: string) => {
            ListItem() {
              Row() {
                UiIcon({
                  name: IconName.ChevronRight,
                  iconSize: 12,
                  color: Theme.tertiary(this.isDark)
                })
                UiIcon({
                  name: IconName.Folder,
                  iconSize: 14,
                  color: Theme.tertiary(this.isDark)
                })
                .margin({ left: 5, right: 7 })
                Text(name)
                  .fontSize(14)
                  .fontColor(Theme.text(this.isDark))
                  .maxLines(1)
                  .layoutWeight(1)
              }
              .width('100%')
              .height(34)
              .padding({ left: 8, right: 8 })
              .borderRadius(5)
              .backgroundColor(this.hoveredEntry === name ? Theme.hover(this.isDark) : '#00000000')
              .onHover((isHover: boolean) => { this.hoveredEntry = isHover ? name : ''; })
              .onClick(() => { this.descend(name); })
              .accessibilityText('打开文件夹 ' + name)
            }
          }, (name: string) => name)
          if (this.entries.length === 0) {
            ListItem() {
              Text('没有子文件夹')
                .fontSize(13)
                .fontColor(Theme.faintText(this.isDark))
                .padding(8)
            }
          }
          }
          .width('100%')
          .height(150)
          .margin({ top: 6 })
          .backgroundColor(Theme.windowBg(this.isDark))
          .borderRadius(7)
          .border({ width: 1, color: Theme.divider(this.isDark), radius: 7 })
          .scrollBar(BarState.Auto)
        } else {
          Text('请输入远程主机上的目录；~ 会展开为远程用户主目录。')
            .fontSize(11.5)
            .fontColor(Theme.tertiary(this.isDark))
            .width('100%')
            .margin({ top: 8 })
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
        Button('创建空间')
          .fontSize(15)
          .fontColor(Theme.onAccent(this.isDark))
          .backgroundColor(this.accentOf())
          .height(32)
          .borderRadius(7)
          .onClick(() => {
            if (this.directory.trim().length > 0) {
              this.onConfirm(this.directory.trim());
            }
            this.controller?.close();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
    .width(440)
    .backgroundColor(Theme.panel(this.isDark))
    .border({ width: 1, color: Theme.border(this.isDark), radius: 14 })
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }
}
