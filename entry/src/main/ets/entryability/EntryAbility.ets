import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackgroundSessionService } from '../model/BackgroundSessionService';
import { ResidentSessionBackend } from '../model/ResidentSessionBackend';
import { StatusBarResidentService } from '../model/StatusBarResidentService';
import { WindowClosePolicy, WindowClosePreference } from '../model/WindowClosePreference';
import { SessionNotificationService } from '../model/SessionNotificationService';
import { TerminaiPreferences } from '../model/TerminaiPreferences';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private backend: ResidentSessionBackend = ResidentSessionBackend.shared();
  private mainWindow: window.Window | undefined = undefined;
  private closeDialogOpen: boolean = false;
  private allowTermination: boolean = false;
  private initialNotificationPermissionNeeded: boolean = false;
  private initialNotificationPermissionTimer: number = -1;

  private publishNotificationSelection(want: Want): void {
    if (want.parameters === undefined) {
      return;
    }
    const value = want.parameters['terminaiSessionUid'];
    if (typeof value !== 'number' || value <= 0) {
      return;
    }
    AppStorage.setOrCreate('notificationSessionRequest', value.toString() + ':' + Date.now().toString());
  }

  private publishTitleButtonInset(rect: window.TitleButtonRect): void {
    const inset: number = rect.width + Math.max(rect.right, 0);
    AppStorage.setOrCreate('titleButtonInset', inset);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const applicationContext = this.context.getApplicationContext();
    TerminaiPreferences.configure(applicationContext);
    AppStorage.setOrCreate('appForeground', false);
    AppStorage.setOrCreate('notificationSessionRequest', '');
    BackgroundSessionService.configure(this.context);
    this.backend.configure(applicationContext);
    StatusBarResidentService.configureMainContext(this.context);
    WindowClosePreference.publish(this.context);
    this.initialNotificationPermissionNeeded =
      SessionNotificationService.prepareInitialPermission(this.context);
    this.backend.sessionManager.onRuntimeChanged = () => {
      this.backend.logRuntimeInvariantFailures();
      BackgroundSessionService.setLiveSessionCount(this.backend.liveSessionCount());
    };
    BackgroundSessionService.setLiveSessionCount(this.backend.liveSessionCount());
    this.publishNotificationSelection(want);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'terminAI', 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
    this.pushSysDark(this.context.config.colorMode);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.allowTermination = false;
    this.backend.configure(this.context.getApplicationContext());
    this.publishNotificationSelection(want);
  }

  onForeground(): void {
    // A status-bar resident process can reuse the visible Ability lifecycle.
    // Rearm both the close interception and the persistence backend whenever
    // the main window becomes active again.
    this.allowTermination = false;
    this.backend.configure(this.context.getApplicationContext());
    AppStorage.setOrCreate('appForeground', true);
    BackgroundSessionService.setForeground(true);
  }

  onBackground(): void {
    // Persist on every transition away from the visible window. During an
    // explicit shutdown this is a guarded no-op, preserving its pre-exit
    // snapshot instead of the already-cleared runtime list.
    this.backend.flushPersistence();
    AppStorage.setOrCreate('appForeground', false);
    BackgroundSessionService.setForeground(false);
  }

  onDestroy(): void {
    if (this.initialNotificationPermissionTimer >= 0) {
      clearTimeout(this.initialNotificationPermissionTimer);
      this.initialNotificationPermissionTimer = -1;
    }
    this.backend.flushPersistence();
    AppStorage.setOrCreate('appForeground', false);
    StatusBarResidentService.clearMainContext(this.context);
    this.mainWindow = undefined;
  }

  /**
   * HarmonyOS PC invokes this before terminating the app from the title bar or
   * another system exit entry. Return immediately, then let the user pick
   * an explicit process exit or a taskKeeping-backed status-bar residence.
   */
  onPrepareToTerminate(): boolean {
    if (this.allowTermination) {
      return false;
    }
    if (this.closeDialogOpen) {
      return true;
    }
    this.closeDialogOpen = true;
    this.applyWindowClosePolicy();
    return true;
  }

  private async applyWindowClosePolicy(): Promise<void> {
    const policy: WindowClosePolicy = WindowClosePreference.publish(this.context);
    if (!policy.configured) {
      await this.showTerminationChoice();
      return;
    }
    try {
      if (policy.keepBackground) {
        await this.keepRunningInStatusBar();
      } else {
        await this.exitProgram();
      }
    } catch (error) {
      hilog.error(DOMAIN, 'terminAI', 'apply close policy failed: %{public}s', JSON.stringify(error));
    } finally {
      this.closeDialogOpen = false;
    }
  }

  private async showTerminationChoice(): Promise<void> {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      this.closeDialogOpen = false;
      return;
    }
    try {
      if (mainWindow.getWindowStatus() === window.WindowStatusType.MINIMIZE) {
        await mainWindow.restore();
      }
      const hasLiveSessions = BackgroundSessionService.hasLiveSessions();
      const message = hasLiveSessions ?
        '关闭主窗口后，会话将在后台继续运行，可从系统状态栏恢复。' :
        '当前没有运行中的会话。可保留状态栏入口，或直接退出程序。';
      const result = await mainWindow.getUIContext().getPromptAction().showDialog({
        title: '关闭 terminAI',
        message: message,
        buttons: [
          { text: '保持后台运行', color: '#2E8B57', primary: true },
          { text: '退出程序', color: '#C42B1C' }
        ]
      });
      if (result.index === 0) {
        WindowClosePreference.save(this.context, true);
        await this.keepRunningInStatusBar();
      } else if (result.index === 1) {
        WindowClosePreference.save(this.context, false);
        await this.exitProgram();
      }
    } catch (error) {
      hilog.error(DOMAIN, 'terminAI', 'show close choice failed: %{public}s', JSON.stringify(error));
    } finally {
      this.closeDialogOpen = false;
    }
  }

  private async keepRunningInStatusBar(): Promise<void> {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    const residentReady = await StatusBarResidentService.ensureResident(this.context);
    if (!residentReady) {
      this.showCloseToast(mainWindow, '无法接入系统状态栏，主窗口已保留');
      return;
    }
    const hasLiveSessions = BackgroundSessionService.hasLiveSessions();
    const started = await BackgroundSessionService.requestKeepRunning();
    if (!started && hasLiveSessions) {
      this.showCloseToast(mainWindow, '无法启动后台长时任务，请检查系统权限后重试');
      return;
    }
    // Do not rely on ArkUI aboutToDisappear ordering for the restart snapshot.
    // The visible Ability can be destroyed while the resident Ability keeps
    // this process alive, so commit immediately before hiding the window.
    this.backend.flushPersistence();
    this.allowTermination = true;
    try {
      await this.context.terminateSelf();
    } catch (error) {
      this.allowTermination = false;
      hilog.error(DOMAIN, 'terminAI', 'hide main ability failed: %{public}s', JSON.stringify(error));
    }
  }

  private async exitProgram(): Promise<void> {
    await BackgroundSessionService.prepareForTermination();
    this.backend.shutdown();
    await StatusBarResidentService.prepareForExit(this.context);
    this.allowTermination = true;
    try {
      await this.context.terminateSelf();
    } catch (error) {
      this.allowTermination = false;
      hilog.error(DOMAIN, 'terminAI', 'terminate main ability failed: %{public}s', JSON.stringify(error));
    }
  }

  private showCloseToast(mainWindow: window.Window, message: string): void {
    try {
      mainWindow.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
      hilog.warn(DOMAIN, 'terminAI', 'show close toast failed: %{public}s', JSON.stringify(error));
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
    this.mainWindow = mainWindow;
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

      StatusBarResidentService.ensureResident(this.context)
        .then((ready: boolean) => {
          if (!ready) {
            hilog.warn(DOMAIN, 'terminAI', 'status-bar resident mode is unavailable');
          }
        })
        .catch((error: Error) => {
          hilog.error(DOMAIN, 'terminAI', 'initialize status-bar resident mode failed: %{public}s',
            error.message);
        });

      if (this.initialNotificationPermissionNeeded && this.initialNotificationPermissionTimer < 0) {
        this.initialNotificationPermissionTimer = setTimeout(() => {
          this.initialNotificationPermissionTimer = -1;
          SessionNotificationService.requestInitialPermission(this.context);
        }, 700);
      }
    });
  }
}
