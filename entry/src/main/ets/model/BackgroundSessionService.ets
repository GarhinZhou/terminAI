import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { APP_BUNDLE_NAME, ENTRY_ABILITY_NAME } from '../common/AppIdentity';

const DOMAIN = 0x0000;
const BACKGROUND_REQUEST_CODE = 77001;

/** Keeps native PTY/SSH sessions scheduled while the visible PC window is hidden. */
export class BackgroundSessionService {
  private static context: common.UIAbilityContext | undefined = undefined;
  private static foreground: boolean = true;
  private static keepRequested: boolean = false;
  private static liveSessionCount: number = 0;
  private static running: boolean = false;
  private static startInFlight: Promise<boolean> | undefined = undefined;

  static configure(context: common.UIAbilityContext): void {
    BackgroundSessionService.context = context;
    AppStorage.setOrCreate('backgroundSessionActive', BackgroundSessionService.running);
  }

  static setForeground(foreground: boolean): void {
    BackgroundSessionService.foreground = foreground;
    if (foreground) {
      BackgroundSessionService.keepRequested = false;
      BackgroundSessionService.stopIfRunning();
      return;
    }
    if (BackgroundSessionService.liveSessionCount > 0) {
      BackgroundSessionService.ensureStarted();
    }
  }

  static setLiveSessionCount(count: number): void {
    BackgroundSessionService.liveSessionCount = Math.max(0, count);
    AppStorage.setOrCreate('liveSessionCount', BackgroundSessionService.liveSessionCount);
    if (BackgroundSessionService.liveSessionCount === 0) {
      BackgroundSessionService.keepRequested = false;
      BackgroundSessionService.stopIfRunning();
      return;
    }
    if (!BackgroundSessionService.foreground || BackgroundSessionService.keepRequested) {
      BackgroundSessionService.ensureStarted();
    }
  }

  static hasLiveSessions(): boolean {
    return BackgroundSessionService.liveSessionCount > 0;
  }

  /** Start before hiding the visible ability so a failure can still be reported. */
  static async requestKeepRunning(): Promise<boolean> {
    BackgroundSessionService.keepRequested = true;
    if (BackgroundSessionService.liveSessionCount === 0) {
      return true;
    }
    return await BackgroundSessionService.ensureStarted();
  }

  static async prepareForTermination(): Promise<void> {
    BackgroundSessionService.keepRequested = false;
    BackgroundSessionService.liveSessionCount = 0;
    await BackgroundSessionService.stopNow();
    BackgroundSessionService.context = undefined;
  }

  private static async createLaunchAgent(): Promise<WantAgent | undefined> {
    const launchWant: Want = {
      bundleName: APP_BUNDLE_NAME,
      abilityName: ENTRY_ABILITY_NAME
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [launchWant],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: BACKGROUND_REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      return await wantAgent.getWantAgent(info);
    } catch (error) {
      hilog.error(DOMAIN, 'terminAI', 'create background WantAgent failed: %{public}s',
        JSON.stringify(error));
      return undefined;
    }
  }

  private static ensureStarted(): Promise<boolean> {
    if (BackgroundSessionService.running) {
      return Promise.resolve(true);
    }
    if (BackgroundSessionService.startInFlight !== undefined) {
      return BackgroundSessionService.startInFlight;
    }
    const operation = BackgroundSessionService.startNow();
    BackgroundSessionService.startInFlight = operation;
    operation.finally(() => {
      if (BackgroundSessionService.startInFlight === operation) {
        BackgroundSessionService.startInFlight = undefined;
      }
    });
    return operation;
  }

  private static async startNow(): Promise<boolean> {
    const context = BackgroundSessionService.context;
    if (context === undefined || BackgroundSessionService.liveSessionCount === 0) {
      return false;
    }
    const launchAgent = await BackgroundSessionService.createLaunchAgent();
    if (launchAgent === undefined) {
      return false;
    }
    try {
      await backgroundTaskManager.startBackgroundRunning(context, ['taskKeeping'], launchAgent);
      BackgroundSessionService.running = true;
      AppStorage.setOrCreate('backgroundSessionActive', true);
      // Foregrounding while the system request was in flight makes the newly
      // created long task obsolete; tear it down immediately.
      if (BackgroundSessionService.foreground && !BackgroundSessionService.keepRequested) {
        await BackgroundSessionService.stopNow();
      }
      return true;
    } catch (error) {
      BackgroundSessionService.running = false;
      AppStorage.setOrCreate('backgroundSessionActive', false);
      hilog.error(DOMAIN, 'terminAI', 'start taskKeeping failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  private static stopIfRunning(): void {
    BackgroundSessionService.stopNow();
  }

  private static async stopNow(): Promise<void> {
    const pending = BackgroundSessionService.startInFlight;
    if (pending !== undefined && !BackgroundSessionService.running) {
      await pending;
    }
    const context = BackgroundSessionService.context;
    if (!BackgroundSessionService.running || context === undefined) {
      AppStorage.setOrCreate('backgroundSessionActive', false);
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      hilog.warn(DOMAIN, 'terminAI', 'stop taskKeeping failed: %{public}s', JSON.stringify(error));
    }
    BackgroundSessionService.running = false;
    AppStorage.setOrCreate('backgroundSessionActive', false);
  }
}
