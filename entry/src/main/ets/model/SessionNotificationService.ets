import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AgentRunState, TerminalSession } from './TerminalSession';
import { APP_BUNDLE_NAME, ENTRY_ABILITY_NAME } from '../common/AppIdentity';
import { TerminaiPreferences } from './TerminaiPreferences';

const SESSION_NOTIFICATION_ID_BASE = 100000;
const TEST_NOTIFICATION_ID = 99999;
const PREF_NOTIFY_ENABLED = 'notifyEnabled';
const PREF_NOTIFICATION_PERMISSION_ASKED = 'notificationPermissionAsked';

/** Local notifications for agent attention states. */
export class SessionNotificationService {
  private static initialPermissionRequesting: boolean = false;

  static prepareInitialPermission(context: common.Context): boolean {
    let needed = true;
    try {
      const store = TerminaiPreferences.get(context);
      const askedValue = store.getSync(PREF_NOTIFICATION_PERMISSION_ASKED, false);
      needed = typeof askedValue === 'boolean' ? !askedValue : true;
    } catch (error) {
      console.error('TERMINAI load initial notification permission state failed: ' +
        JSON.stringify(error));
    }
    AppStorage.setOrCreate('notificationPermissionPromptPending', needed);
    return needed;
  }

  static async requestInitialPermission(context: common.UIAbilityContext): Promise<void> {
    if (SessionNotificationService.initialPermissionRequesting) {
      return;
    }
    SessionNotificationService.initialPermissionRequesting = true;
    try {
      const store = TerminaiPreferences.get(context);
      const askedValue = store.getSync(PREF_NOTIFICATION_PERMISSION_ASKED, false);
      if (typeof askedValue === 'boolean' && askedValue) {
        return;
      }
      const enabledBefore = await notificationManager.isNotificationEnabled();
      if (enabledBefore) {
        store.putSync(PREF_NOTIFICATION_PERMISSION_ASKED, true);
        store.flushSync();
        return;
      }
      try {
        await notificationManager.requestEnableNotification(context);
      } catch (error) {
        console.info('TERMINAI initial notification permission not granted: ' + JSON.stringify(error));
      }
      const enabledAfter = await notificationManager.isNotificationEnabled();
      store.putSync(PREF_NOTIFICATION_PERMISSION_ASKED, true);
      store.putSync(PREF_NOTIFY_ENABLED, enabledAfter);
      store.flushSync();
      AppStorage.setOrCreate('notifyEnabled', enabledAfter);
    } catch (error) {
      console.error('TERMINAI request initial notification permission failed: ' + JSON.stringify(error));
    } finally {
      SessionNotificationService.initialPermissionRequesting = false;
      AppStorage.setOrCreate('notificationPermissionPromptPending', false);
    }
  }

  static notificationId(sessionUid: number): number {
    return SESSION_NOTIFICATION_ID_BASE + sessionUid;
  }

  static isAttentionState(state: AgentRunState): boolean {
    return state === AgentRunState.WaitingInput ||
      state === AgentRunState.ReturnedShell ||
      state === AgentRunState.Exited;
  }

  private static sessionLabel(session: TerminalSession): string {
    const value = session.isAgentSession() ? session.name : session.displayName();
    return value.length > 80 ? value.substring(0, 80) : value;
  }

  private static notificationTitle(session: TerminalSession, state: AgentRunState): string {
    if (state === AgentRunState.WaitingInput) {
      return 'terminAI · 等待输入';
    }
    if (state === AgentRunState.ReturnedShell) {
      return 'terminAI · 任务已完成';
    }
    return session.exitCode === 0 ? 'terminAI · 会话已退出' : 'terminAI · 会话异常退出';
  }

  private static notificationText(session: TerminalSession, state: AgentRunState): string {
    const name = SessionNotificationService.sessionLabel(session);
    if (state === AgentRunState.WaitingInput) {
      return name + ' 正在等待你的输入';
    }
    if (state === AgentRunState.ReturnedShell) {
      return name + ' 已返回 Shell';
    }
    return name + ' 已退出（退出码 ' + session.exitCode.toString() + '）';
  }

  private static locationText(session: TerminalSession): string {
    return session.deviceName + ' · ' + session.cwd;
  }

  private static async launchAgent(sessionUid: number): Promise<WantAgent | undefined> {
    const launchWant: Want = {
      bundleName: APP_BUNDLE_NAME,
      abilityName: ENTRY_ABILITY_NAME,
      parameters: {
        terminaiSessionUid: sessionUid
      }
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [launchWant],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: SESSION_NOTIFICATION_ID_BASE + sessionUid,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      return await wantAgent.getWantAgent(info);
    } catch (error) {
      console.error('TERMINAI create notification WantAgent failed: ' + JSON.stringify(error));
      return undefined;
    }
  }

  static async publishSession(session: TerminalSession, state: AgentRunState): Promise<boolean> {
    if (!SessionNotificationService.isAttentionState(state)) {
      return false;
    }
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        return false;
      }
    } catch (error) {
      console.error('TERMINAI check notification state failed: ' + JSON.stringify(error));
      return false;
    }
    const launch = await SessionNotificationService.launchAgent(session.uid);
    if (launch === undefined) {
      return false;
    }
    const request: notificationManager.NotificationRequest = {
      id: SessionNotificationService.notificationId(session.uid),
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      isAlertOnce: true,
      groupName: 'terminai-sessions',
      tapDismissed: true,
      wantAgent: launch,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: SessionNotificationService.notificationTitle(session, state),
          text: SessionNotificationService.notificationText(session, state),
          additionalText: SessionNotificationService.locationText(session)
        }
      }
    };
    try {
      await notificationManager.publish(request);
      return true;
    } catch (error) {
      console.error('TERMINAI publish session notification failed: ' + JSON.stringify(error));
      return false;
    }
  }

  static async publishTest(): Promise<boolean> {
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        return false;
      }
    } catch (error) {
      console.error('TERMINAI check test notification state failed: ' + JSON.stringify(error));
      return false;
    }
    const launch = await SessionNotificationService.launchAgent(0);
    if (launch === undefined) {
      return false;
    }
    const request: notificationManager.NotificationRequest = {
      id: TEST_NOTIFICATION_ID,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      isAlertOnce: true,
      tapDismissed: true,
      wantAgent: launch,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'terminAI 通知测试',
          text: '通知功能工作正常',
          additionalText: '点击通知可返回 terminAI'
        }
      }
    };
    try {
      await notificationManager.publish(request);
      return true;
    } catch (error) {
      console.error('TERMINAI publish test notification failed: ' + JSON.stringify(error));
      return false;
    }
  }

  static cancelSession(sessionUid: number): void {
    notificationManager.cancel(SessionNotificationService.notificationId(sessionUid))
      .catch((error: BusinessError) => {
        // 1600007 means that there is no active notification to remove.
        if (error.code !== 1600007) {
          console.error('TERMINAI cancel session notification failed: ' + JSON.stringify(error));
        }
      });
  }

  static cancelAll(): void {
    notificationManager.cancelAll().catch((error: BusinessError) => {
      console.error('TERMINAI cancel notifications failed: ' + JSON.stringify(error));
    });
  }
}
