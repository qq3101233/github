(* 
  FB_Clamp 功能块
  功能：
  1. 负责开模、合模、低压合模、高压锁模以及调试动作的执行状态机。
  2. 按开合模工艺段生成压力、速度、位置命令，并输出模具开闭状态。

  说明：
  1. 正常自动模式使用 1=开模、2=合模；调试模式使用 3=开模调试、4=合模调试。
  2. 本块只生成工艺层命令，最终轴限幅与诊断由 `FB_HydAxis` 处理。
*)
FUNCTION_BLOCK FB_Clamp
VAR_IN_OUT
    ClampAxis: ST_AxisRefHyd;         // 合模共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动本次合模动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动开合模
    uiClampMode: UINT;                // 1=开模 2=合模 3=开模调试 4=合模调试
    stClampPara: ST_ClampPara;        // 合模工艺参数
    bOpenStop: BOOL;                  // 开模到位/停止信号
    bCloseLowPres: BOOL;              // 低压合模到位信号
    bCloseHighPres: BOOL;             // 高压锁模到位信号
    bCloseStop: BOOL;                 // 合模停止信号
    udiClampElecRulerVal: UDINT;      // 开合模电子尺反馈
    uiClampPresElecRulerVal: UINT;    // 合模压力反馈
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bMoldOpened: BOOL;                // TRUE=开模完成
    bMoldClosed: BOOL;                // TRUE=合模完成
    aCoreAllow: ARRAY[1..8] OF BOOL;  // 中子允许数组
    uiPresCmd: UINT;                  // 压力命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_ClampState := eState_Idle;
    tPulse: TON;
    uiStageIndex: UINT := 0;
    uiStageCount: UINT := 0;
    uiIndex: UINT := 0;
    udiStageElapsedMs: UDINT := 0;
    udiTotalElapsedMs: UDINT := 0;
    bManualActive: BOOL := FALSE;
    bOpenRequest: BOOL := FALSE;
    bCloseRequest: BOOL := FALSE;
    bStepDone: BOOL := FALSE;
    bCloseDone: BOOL := FALSE;
    stSegCmd: ST_ClampSeg;
END_VAR

bManualActive := bManualMode OR (uiClampMode = 3) OR (uiClampMode = 4);
bOpenRequest := (uiClampMode = 1) OR (uiClampMode = 3);
bCloseRequest := (uiClampMode = 2) OR (uiClampMode = 4);
bStepDone := FALSE;
bCloseDone := FALSE;

FOR uiIndex := 1 TO 8 DO
    aCoreAllow[uiIndex] := (stClampPara.aCoreFn[uiIndex] = 1);
END_FOR;

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bMoldOpened := FALSE;
    bMoldClosed := FALSE;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    uiStageIndex := 0;
    uiStageCount := 0;
    udiStageElapsedMs := 0;
    udiTotalElapsedMs := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSIF bEStop THEN
    eState := eState_Error;
    bBusy := FALSE;
    bAlarm := TRUE;
    dwAlarmID := dwAlarmID OR DWORD#16#0010;
    uiActHint := 1;
    uiActTime := 0;
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
    udiStageElapsedMs := 0;
    udiTotalElapsedMs := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSE
    CASE eState OF
        eState_Idle:
            bBusy := FALSE;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            uiActHint := 0;
            uiActTime := 0;
            uiStageIndex := 0;
            uiStageCount := 0;
            udiStageElapsedMs := 0;
            udiTotalElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := 0;
                bMoldOpened := FALSE;
                bMoldClosed := FALSE;
                eState := eState_Init;
            END_IF;

        eState_Init:
            bBusy := TRUE;
            uiActTime := 0;
            udiStageElapsedMs := 0;
            udiTotalElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);

            IF bOpenRequest THEN
                uiStageCount := stClampPara.uiOpenSegCnt;
                IF uiStageCount < 1 THEN
                    uiStageCount := 1;
                END_IF;
                IF uiStageCount > 5 THEN
                    uiStageCount := 5;
                END_IF;
                uiStageIndex := 1;

                IF bManualActive THEN
                    eState := eState_Opening;
                ELSE
                    eState := eState_OpenUnload;
                END_IF;
            ELSIF bCloseRequest THEN
                uiStageCount := stClampPara.uiCloseSegCnt;
                IF uiStageCount < 1 THEN
                    uiStageCount := 1;
                END_IF;
                IF uiStageCount > 3 THEN
                    uiStageCount := 3;
                END_IF;
                uiStageIndex := 1;
                eState := eState_Closing;
            ELSE
                bAlarm := TRUE;
                dwAlarmID := DWORD#16#0008;
                eState := eState_Error;
            END_IF;

        eState_OpenUnload:
            bBusy := TRUE;
            uiActHint := 18;
            uiPresCmd := stClampPara.stOpenUnloadPres.uiPres;
            uiSpdCmd := stClampPara.stOpenUnloadPres.uiSpd;
            udiPosCmd := stClampPara.stOpenUnloadPres.udiPos;

            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                udiTotalElapsedMs := udiTotalElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);

            IF (stClampPara.stOpenUnloadPres.uiTime = 0) OR (udiStageElapsedMs >= TO_UDINT(stClampPara.stOpenUnloadPres.uiTime)) THEN
                eState := eState_Opening;
                udiStageElapsedMs := 0;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;

            IF (stClampPara.uiOpenLimitTime > 0) AND (udiTotalElapsedMs >= TO_UDINT(stClampPara.uiOpenLimitTime)) THEN
                dwAlarmID := dwAlarmID OR DWORD#16#0002;
                eState := eState_Error;
            END_IF;

        eState_Opening:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                udiTotalElapsedMs := udiTotalElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stClampPara.stOpenDebug;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stClampPara.aOpenSeg[1];
                END_IF;
                uiActHint := 40;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;

                IF (NOT bStart) OR bOpenStop THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > uiStageCount THEN
                    eState := eState_Opened;
                    uiPresCmd := 0;
                    uiSpdCmd := 0;
                    udiPosCmd := 0;
                ELSE
                    stSegCmd := stClampPara.aOpenSeg[uiStageIndex];
                    uiActHint := 83 + uiStageIndex;
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    IF (stClampPara.uiOpenMode = 0) AND (udiClampElecRulerVal >= stSegCmd.udiPos) THEN
                        bStepDone := TRUE;
                    END_IF;
                    IF (stClampPara.uiOpenMode = 1) AND bOpenStop THEN
                        bStepDone := TRUE;
                    END_IF;
                    IF (stSegCmd.uiTime > 0) AND (udiStageElapsedMs >= TO_UDINT(stSegCmd.uiTime)) THEN
                        bStepDone := TRUE;
                    END_IF;

                    IF bStepDone THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiStageElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;
                END_IF;

                IF (stClampPara.uiOpenLimitTime > 0) AND (udiTotalElapsedMs >= TO_UDINT(stClampPara.uiOpenLimitTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0002;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_Opened:
            bBusy := FALSE;
            bDone := TRUE;
            bMoldOpened := TRUE;
            uiActHint := 2;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            tPulse(IN := FALSE, PT := T#100MS);

        eState_Closing:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                udiTotalElapsedMs := udiTotalElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stClampPara.stCloseDebug;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stClampPara.aCloseSeg[1];
                END_IF;
                uiActHint := 41;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;

                IF (NOT bStart) OR bCloseStop THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex <= uiStageCount THEN
                    stSegCmd := stClampPara.aCloseSeg[uiStageIndex];
                    uiActHint := 80 + uiStageIndex;
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    IF (stClampPara.uiCloseMode = 0) AND (udiClampElecRulerVal >= stSegCmd.udiPos) THEN
                        bStepDone := TRUE;
                    END_IF;
                    IF (stSegCmd.uiTime > 0) AND (udiStageElapsedMs >= TO_UDINT(stSegCmd.uiTime)) THEN
                        bStepDone := TRUE;
                    END_IF;

                    IF bStepDone THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiStageElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;
                ELSE
                    eState := eState_CloseLowPress;
                    udiStageElapsedMs := 0;
                    tPulse(IN := FALSE, PT := T#100MS);
                END_IF;

                IF (stClampPara.uiCloseLimitTime > 0) AND (udiTotalElapsedMs >= TO_UDINT(stClampPara.uiCloseLimitTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0004;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_CloseLowPress:
            bBusy := TRUE;
            uiActHint := 30;
            uiPresCmd := stClampPara.stCloseLowPres.uiPres;
            uiSpdCmd := stClampPara.stCloseLowPres.uiSpd;
            udiPosCmd := stClampPara.stCloseLowPres.udiPos;

            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                udiTotalElapsedMs := udiTotalElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);

            IF bCloseLowPres THEN
                eState := eState_CloseHighPress;
                udiStageElapsedMs := 0;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;

            IF (stClampPara.uiCloseLowPresLimitTime > 0) AND (udiStageElapsedMs >= TO_UDINT(stClampPara.uiCloseLowPresLimitTime)) THEN
                dwAlarmID := dwAlarmID OR DWORD#16#0001;
                eState := eState_Error;
            END_IF;

        eState_CloseHighPress:
            bBusy := TRUE;
            uiActHint := 31;
            uiPresCmd := stClampPara.stCloseHighPres.uiPres;
            uiSpdCmd := stClampPara.stCloseHighPres.uiSpd;
            udiPosCmd := stClampPara.stCloseHighPres.udiPos;

            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                udiTotalElapsedMs := udiTotalElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);

            CASE stClampPara.uiCloseEndMode OF
                0:
                    IF (stClampPara.stCloseHighPres.uiTime = 0) OR (udiStageElapsedMs >= TO_UDINT(stClampPara.stCloseHighPres.uiTime)) THEN
                        bCloseDone := TRUE;
                    END_IF;
                1:
                    IF bCloseStop OR bCloseHighPres THEN
                        bCloseDone := TRUE;
                    END_IF;
                2:
                    IF uiClampPresElecRulerVal >= stClampPara.uiCloseEndHighPres THEN
                        bCloseDone := TRUE;
                    END_IF;
            ELSE
                IF bCloseStop OR bCloseHighPres THEN
                    bCloseDone := TRUE;
                END_IF;
            END_CASE;

            IF bCloseDone THEN
                eState := eState_Closed;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;

            IF (stClampPara.uiCloseLimitTime > 0) AND (udiTotalElapsedMs >= TO_UDINT(stClampPara.uiCloseLimitTime)) THEN
                dwAlarmID := dwAlarmID OR DWORD#16#0004;
                eState := eState_Error;
            END_IF;

        eState_Closed:
            bBusy := FALSE;
            bDone := TRUE;
            bMoldClosed := TRUE;
            uiActHint := 3;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            tPulse(IN := FALSE, PT := T#100MS);

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

ClampAxis.rSetPressure := TO_LREAL(uiPresCmd);
ClampAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
ClampAxis.rSetPosition := TO_LREAL(udiPosCmd);
ClampAxis.stPumpRequest.bRequest := bBusy;
ClampAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
ClampAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    ClampAxis.eAxisState := Running;
ELSE
    ClampAxis.eAxisState := Idle;
END_IF;
ClampAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
