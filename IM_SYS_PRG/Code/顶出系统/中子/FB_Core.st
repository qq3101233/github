(* 
  FB_Core 功能块
  功能：
  1. 负责中子进、中子退及其调试动作的执行状态机。
  2. 根据中子参数输出压力、速度、位置命令，并返回中子进退完成状态。

  说明：
  1. 正常模式使用 1=中子进、2=中子退；调试模式使用 3/4。
  2. 本块支持以时间、行程、位置和计数等条件结束动作。
*)
FUNCTION_BLOCK FB_Core
VAR_IN_OUT
    stCoreAxis: ST_AxisRefHyd;        // 中子共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动中子动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动中子
    uiCoreMode: UINT;                 // 1=中子进 2=中子退 3=中子进调试 4=中子退调试
    stCorePara: ST_CorePara;          // 中子工艺参数
    bCoreInStop: BOOL;                // 中子进停止信号
    bCoreOutStop: BOOL;               // 中子退停止信号
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bCoreIned: BOOL;                  // TRUE=中子进完成
    bCoreOuted: BOOL;                 // TRUE=中子退完成
    uiPresCmd: UINT;                  // 压力命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_CoreState := eState_Idle;
    tPulse: TON;
    udiElapsedMs: UDINT := 0;
    uiStopCount: UINT := 0;
    bPrevInStop: BOOL := FALSE;
    bPrevOutStop: BOOL := FALSE;
    bManualActive: BOOL := FALSE;
    bInRequest: BOOL := FALSE;
    bOutRequest: BOOL := FALSE;
    stSegCmd: ST_CoreSeg;
END_VAR

bManualActive := bManualMode OR (uiCoreMode = 3) OR (uiCoreMode = 4);
bInRequest := (uiCoreMode = 1) OR (uiCoreMode = 3);
bOutRequest := (uiCoreMode = 2) OR (uiCoreMode = 4);

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bCoreIned := FALSE;
    bCoreOuted := FALSE;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    udiElapsedMs := 0;
    uiStopCount := 0;
    bPrevInStop := FALSE;
    bPrevOutStop := FALSE;
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
    uiStopCount := 0;
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
            udiElapsedMs := 0;
            uiStopCount := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := 0;
                bCoreIned := FALSE;
                bCoreOuted := FALSE;
                IF bInRequest THEN
                    eState := eState_CoreIning;
                ELSIF bOutRequest THEN
                    eState := eState_CoreOuting;
                ELSE
                    bAlarm := TRUE;
                    dwAlarmID := DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_CoreIning:
            bBusy := TRUE;
            stSegCmd := stCorePara.stCoreInSeg;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stCorePara.stCoreInDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) THEN
                    stSegCmd := stCorePara.stCoreInSeg;
                END_IF;
                uiActHint := 33;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stCorePara.udiCoreInPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                uiActHint := 11;
                uiPresCmd := stCorePara.stCoreInSeg.uiPres;
                uiSpdCmd := stCorePara.stCoreInSeg.uiSpd;
                udiPosCmd := stCorePara.udiCoreInPos;

                IF bCoreInStop AND (NOT bPrevInStop) THEN
                    uiStopCount := uiStopCount + 1;
                END_IF;

                CASE stCorePara.uiCoreInStopMode OF
                    0:
                        IF (stCorePara.stCoreInSeg.uiTime = 0) OR (udiElapsedMs >= TO_UDINT(stCorePara.stCoreInSeg.uiTime)) THEN
                            eState := eState_CoreIned;
                        END_IF;
                    1:
                        IF bCoreInStop THEN
                            eState := eState_CoreIned;
                        END_IF;
                    2:
                        IF (stCorePara.stCoreInSeg.uiCount = 0) OR (uiStopCount >= stCorePara.stCoreInSeg.uiCount) THEN
                            eState := eState_CoreIned;
                        END_IF;
                ELSE
                    IF bCoreInStop THEN
                        eState := eState_CoreIned;
                    END_IF;
                END_CASE;

                IF (stCorePara.uiCoreInLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stCorePara.uiCoreInLimitTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_CoreIned:
            bBusy := FALSE;
            bDone := TRUE;
            bCoreIned := TRUE;
            uiActHint := 34;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_CoreOuting:
            bBusy := TRUE;
            stSegCmd := stCorePara.stCoreOutSeg;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stCorePara.stCoreOutDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) THEN
                    stSegCmd := stCorePara.stCoreOutSeg;
                END_IF;
                uiActHint := 35;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stCorePara.udiCoreOutPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                uiActHint := 21;
                uiPresCmd := stCorePara.stCoreOutSeg.uiPres;
                uiSpdCmd := stCorePara.stCoreOutSeg.uiSpd;
                udiPosCmd := stCorePara.udiCoreOutPos;

                IF bCoreOutStop AND (NOT bPrevOutStop) THEN
                    uiStopCount := uiStopCount + 1;
                END_IF;

                CASE stCorePara.uiCoreOutStopMode OF
                    0:
                        IF (stCorePara.stCoreOutSeg.uiTime = 0) OR (udiElapsedMs >= TO_UDINT(stCorePara.stCoreOutSeg.uiTime)) THEN
                            eState := eState_CoreOuted;
                        END_IF;
                    1:
                        IF bCoreOutStop THEN
                            eState := eState_CoreOuted;
                        END_IF;
                    2:
                        IF (stCorePara.stCoreOutSeg.uiCount = 0) OR (uiStopCount >= stCorePara.stCoreOutSeg.uiCount) THEN
                            eState := eState_CoreOuted;
                        END_IF;
                ELSE
                    IF bCoreOutStop THEN
                        eState := eState_CoreOuted;
                    END_IF;
                END_CASE;

                IF (stCorePara.uiCoreOutLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stCorePara.uiCoreOutLimitTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0002;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_CoreOuted:
            bBusy := FALSE;
            bDone := TRUE;
            bCoreOuted := TRUE;
            uiActHint := 36;
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

bPrevInStop := bCoreInStop;
bPrevOutStop := bCoreOutStop;

stCoreAxis.rSetPressure := TO_LREAL(uiPresCmd);
stCoreAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
stCoreAxis.rSetPosition := TO_LREAL(udiPosCmd);
stCoreAxis.stPumpRequest.bRequest := bBusy;
stCoreAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
stCoreAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    stCoreAxis.eAxisState := Running;
ELSE
    stCoreAxis.eAxisState := Idle;
END_IF;
stCoreAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
