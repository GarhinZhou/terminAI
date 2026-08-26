import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private publishTitleButtonInset(rect: window.TitleButtonRect): void {
    const inset: number = rect.width + Math.max(rect.right, 0);
    AppStorage.setOrCreate('titleButtonInset', inset);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'terminAI', 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    this.pushSysDark(this.context.config.colorMode);
    // Best-effort: enable notifications (used for session-exit alerts).
    // If the user declines, we silently degrade to in-app unread badges.
    try {
      notificationManager.requestEnableNotification(this.context).then(() => {
        hilog.info(DOMAIN, 'terminAI', 'notification enabled');
      }).catch(() => {
        hilog.info(DOMAIN, 'terminAI', 'notification declined');
      });
    } catch (err) {
      hilog.warn(DOMAIN, 'terminAI', 'requestEnableNotification unavailable');
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.pushSysDark(newConfig.colorMode);
  }

  /** Publish the system color scheme into AppStorage for the UI to follow. */
  private pushSysDark(mode: ConfigurationConstant.ColorMode | undefined): void {
    const dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('sysDark', dark);
    hilog.info(DOMAIN, 'terminAI', 'system color mode dark=%{public}s mode=%{public}s',
      String(dark), JSON.stringify(mode));
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    let mainWindow: window.Window;
    try {
      mainWindow = windowStage.getMainWindowSync();
    } catch (error) {
      hilog.error(DOMAIN, 'terminAI', 'getMainWindowSync failed: %{public}s', JSON.stringify(error));
      return;
    }
    // The custom title bar needs the real main-window instance for moving,
    // while HarmonyOS continues to own the standard window buttons.
    AppStorage.setOrCreate('mainWindow', mainWindow);
    AppStorage.setOrCreate('titleButtonInset', 0);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'terminAI', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }

      // HarmonyOS requires window-decoration APIs to run after loadContent.
      // The app supplies its own 40vp content strip. HarmonyOS retains the
      // native minimize, maximize/restore and close buttons in that area.
      try {
        mainWindow.setWindowDecorHeight(40);
        mainWindow.setWindowDecorVisible(false);
        mainWindow.setWindowTitleButtonVisible(true, true, true);
        this.publishTitleButtonInset(mainWindow.getTitleButtonRect());
        mainWindow.on('windowTitleButtonRectChange', (rect: window.TitleButtonRect) => {
          this.publishTitleButtonInset(rect);
        });
        mainWindow.setTitleAndDockHoverShown(true, true).catch((error: BusinessError) => {
          hilog.warn(DOMAIN, 'terminAI', 'setTitleAndDockHoverShown failed: %{public}s',
            JSON.stringify(error));
        });
      } catch (error) {
        hilog.error(DOMAIN, 'terminAI', 'configure immersive window failed: %{public}s',
          JSON.stringify(error));
      }
    });
  }
}
