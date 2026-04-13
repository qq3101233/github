(* 
  FB_Inject 功能块
  功能：
  1. 负责射出、保压、射退及其调试动作的执行状态机。
  2. 按工艺段输出压力、速度、位置命令，并返回射出/保压/射退完成状态。

  说明：
  1. 正常模式使用 1=射出、2=射退；调试模式使用 3/4。
  2. 本块只生成工艺命令和状态，不承担最终轴限幅与保护。
*)
FUNCTION_BLOCK FB_Inject
VAR_IN_OUT
    stInjectAxis: ST_AxisRefHyd;      // 射胶共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动射胶动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动射出/射退
    uiInjectMode: UINT;               // 1=射出 2=射退 3=射出调试 4=射退调试
    stInjectPara: ST_InjectPara;      // 射胶工艺参数
    bInjSeg1Stop: BOOL;               // 射出第一停止信号
    bInjSeg2Stop: BOOL;               // 射出第二停止信号
    bInjStop: BOOL;                   // 射出结束信号
    bSuckBackStop: BOOL;              // 射退结束信号
    udiInjElecRulerVal: UDINT;        // 位置反馈
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bInjected: BOOL;                  // TRUE=射出完成
    bHeld: BOOL;                      // TRUE=保压完成
    bSuckBacked: BOOL;                // TRUE=射退完成
    uiPresCmd: UINT;                  // 压力命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_InjectState := eState_Idle;
    uiStageIndex: UINT := 0;
    uiHoldIndex: UINT := 0;
    tPulse: TON;
    udiStageElapsedMs: UDINT := 0;
    udiTotalElapsedMs: UDINT := 0;
    bManualActive: BOOL := FALSE;
    bInjectRequest: BOOL := FALSE;
    bSuckBackRequest: BOOL := FALSE;
    bStageDone: BOOL := FALSE;
    bTransferToHold: BOOL := FALSE;
    stSegCmd: ST_InjectSeg;
END_VAR

bManualActive := bManualMode OR (uiInjectMode = 3) OR (uiInjectMode = 4);
bInjectRequest := (uiInjectMode = 1) OR (uiInjectMode = 3);
bSuckBackRequest := (uiInjectMode = 2) OR (uiInjectMode = 4);
bStageDone := FALSE;
bTransferToHold := FALSE;

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bInjected := FALSE;
    bHeld := FALSE;
    bSuckBacked := FALSE;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    uiStageIndex := 0;
    uiHoldIndex := 0;
    udiStageElapsedMs := 0;
    udiTotalElapsedMs := 0;
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
    uiActHint := 0;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    udiStageElapsedMs := 0;
    udiTotalElapsedMs := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSE
    CASE eState OF
        eState_Idle:
            bBusy := FALSE;
            uiActHint := 0;
            uiActTime := 0;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            uiStageIndex := 0;
            uiHoldIndex := 0;
            udiStageElapsedMs := 0;
            udiTotalElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := 0;
                bInjected := FALSE;
                bHeld := FALSE;
                bSuckBacked := FALSE;

                IF bInjectRequest THEN
                    uiStageIndex := 1;
                    eState := eState_Injecting;
                ELSIF bSuckBackRequest THEN
                    eState := eState_SuckBacking;
                ELSE
                    bAlarm := TRUE;
                    dwAlarmID := DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_Injecting:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                udiTotalElapsedMs := udiTotalElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiTotalElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stInjectPara.stInjDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stInjectPara.aInjSeg[1];
                END_IF;
                uiActHint := 44;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > stInjectPara.uiInjSegCnt THEN
                    eState := eState_Injected;
                    uiPresCmd := 0;
                    uiSpdCmd := 0;
                    udiPosCmd := 0;
                ELSE
                    stSegCmd := stInjectPara.aInjSeg[uiStageIndex];
                    uiActHint := 10 + uiStageIndex;
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    CASE stInjectPara.uiInjMode OF
                        0:
                            IF udiInjElecRulerVal >= stSegCmd.udiPos THEN
                                bStageDone := TRUE;
                            END_IF;
                        1:
                            IF ((uiStageIndex = 1) AND bInjSeg1Stop) OR ((uiStageIndex = 2) AND bInjSeg2Stop) OR ((uiStageIndex >= 3) AND bInjStop) THEN
                                bStageDone := TRUE;
                            END_IF;
                    ELSE
                        IF (stSegCmd.uiTime > 0) AND (udiStageElapsedMs >= TO_UDINT(stSegCmd.uiTime)) THEN
                            bStageDone := TRUE;
                        END_IF;
                    END_CASE;

                    IF (stSegCmd.uiTime > 0) AND (udiStageElapsedMs >= TO_UDINT(stSegCmd.uiTime)) THEN
                        bStageDone := TRUE;
                    END_IF;

                    IF ((stInjectPara.dwInjToHoldMode AND DWORD#16#00000001) <> DWORD#16#00000000) AND (stInjectPara.uiInjToHoldTime > 0) AND (udiTotalElapsedMs >= TO_UDINT(stInjectPara.uiInjToHoldTime)) THEN
                        bTransferToHold := TRUE;
                    END_IF;
                    IF ((stInjectPara.dwInjToHoldMode AND DWORD#16#00000002) <> DWORD#16#00000000) AND (TO_UINT(stInjectAxis.rActualPressure) >= stInjectPara.uiInjToHoldPres) THEN
                        bTransferToHold := TRUE;
                    END_IF;
                    IF ((stInjectPara.dwInjToHoldMode AND DWORD#16#00000004) <> DWORD#16#00000000) AND (udiInjElecRulerVal >= stInjectPara.uiInjToHoldPos) THEN
                        bTransferToHold := TRUE;
                    END_IF;

                    IF bTransferToHold THEN
                        eState := eState_Injected;
                        udiStageElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    ELSIF bStageDone THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiStageElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;
                END_IF;

                IF (stInjectPara.uiInjTotalTime > 0) AND (udiTotalElapsedMs >= TO_UDINT(stInjectPara.uiInjTotalTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_Injected:
            bBusy := TRUE;
            bInjected := TRUE;
            uiActHint := 2;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            udiStageElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);

            IF stInjectPara.uiHoldSegCnt > 0 THEN
                uiHoldIndex := 1;
                eState := eState_Holding;
            ELSE
                eState := eState_Held;
            END_IF;

        eState_Holding:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT((udiTotalElapsedMs + udiStageElapsedMs) / 1000);

            IF uiHoldIndex > stInjectPara.uiHoldSegCnt THEN
                eState := eState_Held;
            ELSE
                uiActHint := 20 + uiHoldIndex;
                uiPresCmd := stInjectPara.aHoldSeg[uiHoldIndex].uiPres;
                uiSpdCmd := stInjectPara.aHoldSeg[uiHoldIndex].uiSpd;
                udiPosCmd := 0;

                IF (stInjectPara.aHoldSeg[uiHoldIndex].uiTime = 0) OR (udiStageElapsedMs >= TO_UDINT(stInjectPara.aHoldSeg[uiHoldIndex].uiTime)) THEN
                    uiHoldIndex := uiHoldIndex + 1;
                    udiStageElapsedMs := 0;
                    tPulse(IN := FALSE, PT := T#100MS);
                END_IF;
            END_IF;

        eState_Held:
            bBusy := FALSE;
            bDone := TRUE;
            bHeld := TRUE;
            uiActHint := 3;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_SuckBacking:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiStageElapsedMs := udiStageElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiStageElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stInjectPara.stSuckBackDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stInjectPara.stSuckBackSeg;
                END_IF;
                uiActHint := 13;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                uiActHint := 5;
                uiPresCmd := stInjectPara.stSuckBackSeg.uiPres;
                uiSpdCmd := stInjectPara.stSuckBackSeg.uiSpd;
                udiPosCmd := stInjectPara.stSuckBackSeg.udiPos;

                CASE stInjectPara.uiSuckBackMode OF
                    0:
                        IF udiInjElecRulerVal >= stInjectPara.stSuckBackSeg.udiPos THEN
                            eState := eState_SuckBacked;
                        END_IF;
                    1:
                        IF (stInjectPara.stSuckBackSeg.uiTime > 0) AND (udiStageElapsedMs >= TO_UDINT(stInjectPara.stSuckBackSeg.uiTime)) THEN
                            eState := eState_SuckBacked;
                        ELSIF (stInjectPara.stSuckBackSeg.uiTime = 0) AND bSuckBackStop THEN
                            eState := eState_SuckBacked;
                        END_IF;
                ELSE
                    IF bSuckBackStop THEN
                        eState := eState_SuckBacked;
                    END_IF;
                END_CASE;
            END_IF;

        eState_SuckBacked:
            bBusy := FALSE;
            bDone := TRUE;
            bSuckBacked := TRUE;
            uiActHint := 14;
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

stInjectAxis.rSetPressure := TO_LREAL(uiPresCmd);
stInjectAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
stInjectAxis.rSetPosition := TO_LREAL(udiPosCmd);
stInjectAxis.stPumpRequest.bRequest := bBusy;
stInjectAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
stInjectAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    stInjectAxis.eAxisState := Running;
ELSE
    stInjectAxis.eAxisState := Idle;
END_IF;
stInjectAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
