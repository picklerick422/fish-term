import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantAgent, WantAgent as _WantAgent } from '@kit.AbilityKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private bgRunning: boolean = false;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // Stop the background task once we're back in the foreground; the page is
    // visible again and normal foreground execution keeps the socket alive.
    this.stopBackgroundTask();
    emitter.emit({ eventId: 10086 });
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // Request a continuous (data-transfer) background task so the process keeps
    // running while backgrounded. Without this HarmonyOS suspends the app after
    // a few seconds, the heartbeat timer stops, the WebSocket is torn down and
    // the server kills the PTY — so reconnecting lands on a fresh shell. Keeping
    // the task alive holds the existing connection (and terminal state) open.
    this.startBackgroundTask();
  }

  private startBackgroundTask(): void {
    if (this.bgRunning) {
      return;
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((wa: _WantAgent) => {
      backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        wa
      ).then(() => {
        this.bgRunning = true;
        hilog.info(DOMAIN, 'testTag', '%{public}s', 'Background task started');
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'getWantAgent failed: %{public}s', JSON.stringify(err));
    });
  }

  private stopBackgroundTask(): void {
    if (!this.bgRunning) {
      return;
    }
    this.bgRunning = false;
    backgroundTaskManager.stopBackgroundRunning(this.context).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    });
  }
}
