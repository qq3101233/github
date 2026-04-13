(* 
  FB_Eject 功能块
  功能：
  1. 负责托模进、托模保持、托模退及其调试动作的执行状态机。
  2. 按托模参数输出压力、速度、位置命令，并返回托模进退完成状态。

  说明：
  1. 正常模式使用 1=托模进、2=托模退；调试模式使用 6/7。
  2. 组合托模模式由 `FB_EjectMode` 复用本块完成具体动作。
*)
FUNCTION_BLOCK FB_Eject
VAR_IN_OUT
    stEjectAxis: ST_AxisRefHyd;       // 托模共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动托模动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动托模
    uiEjectMode: UINT;                // 1=托模进 2=托模退 6=托模进调试 7=托模退调试
    stEjectPara: ST_EjectPara;        // 托模工艺参数
    bEjectInStop: BOOL;               // 托模进停止信号
    bEjectOutStop: BOOL;              // 托模退停止信号
    udiEjectElecRulerVal: UDINT;      // 位置反馈
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bEjectIned: BOOL;                 // TRUE=托模进完成
    bEjectOuted: BOOL;                // TRUE=托模退完成
    uiPresCmd: UINT;                  // 压力命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_EjectState := eState_Idle;
    uiStageIndex: UINT := 0;
    tPulse: TON;
    udiElapsedMs: UDINT := 0;
    bManualActive: BOOL := FALSE;
    bInRequest: BOOL := FALSE;
    bOutRequest: BOOL := FALSE;
    stSegCmd: ST_EjectSeg;
END_VAR

bManualActive := bManualMode OR (uiEjectMode = 6) OR (uiEjectMode = 7);
bInRequest := (uiEjectMode = 1) OR (uiEjectMode = 6);
bOutRequest := (uiEjectMode = 2) OR (uiEjectMode = 7);

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bEjectIned := FALSE;
    bEjectOuted := FALSE;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    uiStageIndex := 0;
    udiElapsedMs := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSIF bEStop THEN
    eState := eState_Error;
    bAlarm := TRUE;
    dwAlarmID := dwAlarmID OR DWORD#16#0010;
    uiActHint := 1;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSIF bStop THEN
    eState := eState_Idle;
    bBusy := FALSE;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    uiActHint := 0;
    udiElapsedMs := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSE
    CASE eState OF
        eState_Idle:
            bBusy := FALSE;
            bDone := FALSE;
            uiActHint := 0;
            uiActTime := 0;
            bEjectIned := FALSE;
            bEjectOuted := FALSE;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            uiStageIndex := 0;
            udiElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bAlarm := FALSE;
                dwAlarmID := 0;
                uiStageIndex := 1;
                IF bInRequest THEN
                    eState := eState_EjectIning;
                ELSIF bOutRequest THEN
                    eState := eState_EjectOuting;
                ELSE
                    bAlarm := TRUE;
                    dwAlarmID := DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_EjectIning:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stEjectPara.stEjectInDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stEjectPara.aEjectInSeg[1];
                END_IF;
                uiActHint := 28;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > stEjectPara.uiEjectInSegCnt THEN
                    IF stEjectPara.stEjectKeepSeg.uiTime > 0 THEN
                        eState := eState_EjectKeeping;
                    ELSE
                        eState := eState_EjectIned;
                    END_IF;
                    udiElapsedMs := 0;
                    tPulse(IN := FALSE, PT := T#100MS);
                ELSE
                    stSegCmd := stEjectPara.aEjectInSeg[uiStageIndex];
                    uiActHint := 89 + uiStageIndex; // 90-92
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    IF (stEjectPara.uiEjectInMode = 2) AND (udiEjectElecRulerVal >= stSegCmd.udiPos) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    ELSIF ((stEjectPara.uiEjectInMode = 0) AND (stSegCmd.uiTime > 0) AND (udiElapsedMs >= TO_UDINT(stSegCmd.uiTime))) OR ((stEjectPara.uiEjectInMode = 1) AND bEjectInStop) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;

                    IF (stEjectPara.uiEjectInLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stEjectPara.uiEjectInLimitTime)) THEN
                        dwAlarmID := dwAlarmID OR DWORD#16#0001;
                        eState := eState_Error;
                    END_IF;
                END_IF;
            END_IF;

        eState_EjectIned:
            bBusy := FALSE;
            bDone := TRUE;
            bEjectIned := TRUE;
            uiActHint := 30;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_EjectKeeping:
            bBusy := TRUE;
            uiActHint := 29;
            uiPresCmd := stEjectPara.stEjectKeepSeg.uiPres;
            uiSpdCmd := stEjectPara.stEjectKeepSeg.uiSpd;
            udiPosCmd := stEjectPara.stEjectKeepSeg.udiPos;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);
            IF (stEjectPara.stEjectKeepSeg.uiTime = 0) OR (udiElapsedMs >= TO_UDINT(stEjectPara.stEjectKeepSeg.uiTime)) THEN
                eState := eState_EjectKept;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;

        eState_EjectKept:
            bBusy := FALSE;
            bDone := TRUE;
            bEjectIned := TRUE;
            uiActHint := 29;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_EjectOuting:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stEjectPara.stEjectOutDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stEjectPara.aEjectOutSeg[1];
                END_IF;
                uiActHint := 31;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > stEjectPara.uiEjectOutSegCnt THEN
                    eState := eState_EjectOuted;
                ELSE
                    stSegCmd := stEjectPara.aEjectOutSeg[uiStageIndex];
                    uiActHint := 91 + uiStageIndex; // 92-94
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    IF (stEjectPara.uiEjectOutMode = 2) AND (udiEjectElecRulerVal >= stSegCmd.udiPos) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    ELSIF ((stEjectPara.uiEjectOutMode = 0) AND (stSegCmd.uiTime > 0) AND (udiElapsedMs >= TO_UDINT(stSegCmd.uiTime))) OR ((stEjectPara.uiEjectOutMode = 1) AND bEjectOutStop) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;

                    IF (stEjectPara.uiEjectOutLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stEjectPara.uiEjectOutLimitTime)) THEN
                        dwAlarmID := dwAlarmID OR DWORD#16#0002;
                        eState := eState_Error;
                    END_IF;
                END_IF;
            END_IF;

        eState_EjectOuted:
            bBusy := FALSE;
            bDone := TRUE;
            bEjectOuted := TRUE;
            uiActHint := 32;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_Error:
            bBusy := FALSE;
            bAlarm := TRUE;
            uiActHint := 1;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            tPulse(IN := FALSE, PT := T#100MS);

    ELSE
        eState := eState_Error;
    END_CASE;
END_IF;

stEjectAxis.rSetPressure := TO_LREAL(uiPresCmd);
stEjectAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
stEjectAxis.rSetPosition := TO_LREAL(udiPosCmd);
stEjectAxis.stPumpRequest.bRequest := bBusy;
stEjectAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
stEjectAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    stEjectAxis.eAxisState := Running;
ELSE
    stEjectAxis.eAxisState := Idle;
END_IF;
stEjectAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
