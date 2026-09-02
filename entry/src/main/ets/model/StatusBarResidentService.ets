import { common, contextConstant, StartOptions, Want } from '@kit.AbilityKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { emitter } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { APP_BUNDLE_NAME, ENTRY_ABILITY_NAME, ENTRY_MODULE_NAME,
  RESIDENT_ABILITY_NAME } from '../common/AppIdentity';

const DOMAIN = 0x0000;
const WHITE_ICON_PATH = 'statusbar/terminai_status_white.svg';
const BLACK_ICON_PATH = 'statusbar/terminai_status_black.svg';

/**
 * Owns the HarmonyOS PC status-bar item and the hidden UIAbility that keeps the
 * process attached to it. The visible EntryAbility can therefore be destroyed
 * without moving its window into the Dock or tearing down native PTY sessions.
 */
export class StatusBarResidentService {
  private static installed: boolean = false;
  private static residentStarted: boolean = false;
  private static installInFlight: Promise<boolean> | undefined = undefined;
  private static startInFlight: Promise<boolean> | undefined = undefined;
  private static mainContext: common.UIAbilityContext | undefined = undefined;
  private static residentContext: common.UIAbilityContext | undefined = undefined;
  private static whitePixelMap: image.PixelMap | undefined = undefined;
  private static blackPixelMap: image.PixelMap | undefined = undefined;
  private static exiting: boolean = false;

  private static iconClickHandler = (eventData: emitter.EventData): void => {
    if (eventData.data === undefined) {
      hilog.debug(DOMAIN, 'terminAI', 'status bar icon clicked');
    }
    StatusBarResidentService.showMainWindow();
  };

  static configureMainContext(context: common.UIAbilityContext): void {
    StatusBarResidentService.mainContext = context;
    StatusBarResidentService.exiting = false;
  }

  static clearMainContext(context: common.UIAbilityContext): void {
    if (StatusBarResidentService.mainContext === context) {
      StatusBarResidentService.mainContext = undefined;
    }
  }

  static bindResidentContext(context: common.UIAbilityContext): void {
    StatusBarResidentService.residentContext = context;
    StatusBarResidentService.residentStarted = true;
  }

  static unbindResidentContext(context: common.UIAbilityContext): void {
    if (StatusBarResidentService.residentContext === context) {
      StatusBarResidentService.residentContext = undefined;
      StatusBarResidentService.residentStarted = false;
    }
  }

  static async ensureResident(context: common.UIAbilityContext): Promise<boolean> {
    StatusBarResidentService.configureMainContext(context);
    const installed = await StatusBarResidentService.ensureInstalled(context);
    if (!installed) {
      return false;
    }
    return await StatusBarResidentService.ensureResidentAbility(context);
  }

  static showMainWindow(): void {
    const context = StatusBarResidentService.residentContext ?? StatusBarResidentService.mainContext;
    if (context === undefined || StatusBarResidentService.exiting) {
      return;
    }
    const want: Want = {
      bundleName: APP_BUNDLE_NAME,
      moduleName: ENTRY_MODULE_NAME,
      abilityName: ENTRY_ABILITY_NAME
    };
    context.startAbility(want)
      .catch((error: Error) => {
        hilog.error(DOMAIN, 'terminAI', 'restore main window failed: %{public}s', error.message);
      });
  }

  /** Remove the status item while a foreground window still exists. */
  static async prepareForExit(context: common.UIAbilityContext): Promise<void> {
    StatusBarResidentService.exiting = true;
    if (StatusBarResidentService.installed) {
      try {
        statusBarManager.off('statusBarIconClick', StatusBarResidentService.iconClickHandler);
        statusBarManager.removeFromStatusBar(context);
      } catch (error) {
        hilog.warn(DOMAIN, 'terminAI', 'remove status bar item failed: %{public}s', JSON.stringify(error));
      }
      StatusBarResidentService.installed = false;
    }
    const resident = StatusBarResidentService.residentContext;
    StatusBarResidentService.residentContext = undefined;
    StatusBarResidentService.residentStarted = false;
    if (resident !== undefined && resident !== context) {
      try {
        await resident.terminateSelf();
      } catch (error) {
        hilog.warn(DOMAIN, 'terminAI', 'terminate resident ability failed: %{public}s', JSON.stringify(error));
      }
    }
    await StatusBarResidentService.releaseIcons();
  }

  private static ensureInstalled(context: common.UIAbilityContext): Promise<boolean> {
    if (StatusBarResidentService.installed) {
      return Promise.resolve(true);
    }
    if (StatusBarResidentService.installInFlight !== undefined) {
      return StatusBarResidentService.installInFlight;
    }
    const operation = StatusBarResidentService.install(context);
    StatusBarResidentService.installInFlight = operation;
    operation.finally(() => {
      if (StatusBarResidentService.installInFlight === operation) {
        StatusBarResidentService.installInFlight = undefined;
      }
    });
    return operation;
  }

  private static async install(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const white = await StatusBarResidentService.loadPixelMap(context, WHITE_ICON_PATH);
      const black = await StatusBarResidentService.loadPixelMap(context, BLACK_ICON_PATH);
      StatusBarResidentService.whitePixelMap = white;
      StatusBarResidentService.blackPixelMap = black;
      const icon: statusBarManager.StatusBarIcon = {
        white: white,
        black: black
      };
      const operation: statusBarManager.QuickOperation = {
        title: 'terminAI',
        height: 1,
        abilityName: ''
      };
      const showAction: statusBarManager.StatusBarMenuAction = {
        abilityName: ENTRY_ABILITY_NAME,
        moduleName: ENTRY_MODULE_NAME
      };
      const showMenu: statusBarManager.StatusBarMenuItem = {
        title: '显示主窗口',
        menuAction: showAction
      };
      const group: statusBarManager.StatusBarGroupMenu = [showMenu];
      const item: statusBarManager.StatusBarItem = {
        icons: icon,
        quickOperation: operation,
        statusBarGroupMenu: [group],
        hoverTips: 'terminAI · 终端会话在后台运行'
      };
      statusBarManager.on('statusBarIconClick', StatusBarResidentService.iconClickHandler);
      statusBarManager.addToStatusBar(context, item);
      StatusBarResidentService.installed = true;
      return true;
    } catch (error) {
      try {
        statusBarManager.off('statusBarIconClick', StatusBarResidentService.iconClickHandler);
      } catch (listenerError) {
        hilog.warn(DOMAIN, 'terminAI', 'remove failed status listener failed: %{public}s',
          JSON.stringify(listenerError));
      }
      await StatusBarResidentService.releaseIcons();
      hilog.error(DOMAIN, 'terminAI', 'add status bar item failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  private static ensureResidentAbility(context: common.UIAbilityContext): Promise<boolean> {
    if (StatusBarResidentService.residentStarted) {
      return Promise.resolve(true);
    }
    if (StatusBarResidentService.startInFlight !== undefined) {
      return StatusBarResidentService.startInFlight;
    }
    const operation = StatusBarResidentService.startResidentAbility(context);
    StatusBarResidentService.startInFlight = operation;
    operation.finally(() => {
      if (StatusBarResidentService.startInFlight === operation) {
        StatusBarResidentService.startInFlight = undefined;
      }
    });
    return operation;
  }

  private static async startResidentAbility(context: common.UIAbilityContext): Promise<boolean> {
    const want: Want = {
      bundleName: APP_BUNDLE_NAME,
      moduleName: ENTRY_MODULE_NAME,
      abilityName: RESIDENT_ABILITY_NAME
    };
    const options: StartOptions = {
      processMode: contextConstant.ProcessMode.ATTACH_TO_STATUS_BAR_ITEM,
      startupVisibility: contextConstant.StartupVisibility.STARTUP_HIDE
    };
    try {
      await context.startAbility(want, options);
      StatusBarResidentService.residentStarted = true;
      return true;
    } catch (error) {
      hilog.error(DOMAIN, 'terminAI', 'start resident ability failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  private static async loadPixelMap(context: common.UIAbilityContext,
    path: string): Promise<image.PixelMap> {
    let fileData: Uint8Array;
    try {
      fileData = context.resourceManager.getRawFileContentSync(path);
    } catch (error) {
      throw new Error('读取状态栏图标失败：' + path + '，' + JSON.stringify(error));
    }
    const source: image.ImageSource = image.createImageSource(fileData.buffer);
    try {
      const options: image.DecodingOptions = {
        desiredSize: {
          width: 24,
          height: 24
        }
      };
      return await source.createPixelMap(options);
    } finally {
      await source.release();
    }
  }

  private static async releaseIcons(): Promise<void> {
    const white = StatusBarResidentService.whitePixelMap;
    const black = StatusBarResidentService.blackPixelMap;
    StatusBarResidentService.whitePixelMap = undefined;
    StatusBarResidentService.blackPixelMap = undefined;
    if (white !== undefined) {
      await white.release();
    }
    if (black !== undefined) {
      await black.release();
    }
  }
}
