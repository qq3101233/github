(* 
  FB_Nozzle 功能块
  功能：
  1. 负责座进、座退及其调试动作的执行状态机。
  2. 按段输出座台压力、速度、位置命令，并返回进退完成状态。

  说明：
  1. 正常模式使用 1=座进、2=座退；调试模式使用 3/4。
  2. 本块只处理工艺节拍，不负责最终轴保护。
*)
FUNCTION_BLOCK FB_Nozzle
VAR_IN_OUT
    stNozzleAxis: ST_AxisRefHyd;      // 座台共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动座台动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动座台
    uiNozzleMode: UINT;               // 1=座进 2=座退 3=座进调试 4=座退调试
    stNozzlePara: ST_NozzlePara;      // 座台工艺参数
    bNozzleInStop: BOOL;              // 座进停止信号
    bNozzleOutStop: BOOL;             // 座退停止信号
    udiNozzleElecRulerVal: UDINT;     // 位置反馈
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bNozzleIned: BOOL;                // TRUE=座进完成
    bNozzleOuted: BOOL;               // TRUE=座退完成
    uiPresCmd: UINT;                  // 压力命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_NozzleState := eState_Idle;
    uiStageIndex: UINT := 0;
    tPulse: TON;
    udiElapsedMs: UDINT := 0;
    bManualActive: BOOL := FALSE;
    bInRequest: BOOL := FALSE;
    bOutRequest: BOOL := FALSE;
    stSegCmd: ST_NozzleSeg;
END_VAR

bManualActive := bManualMode OR (uiNozzleMode = 3) OR (uiNozzleMode = 4);
bInRequest := (uiNozzleMode = 1) OR (uiNozzleMode = 3);
bOutRequest := (uiNozzleMode = 2) OR (uiNozzleMode = 4);

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bNozzleIned := FALSE;
    bNozzleOuted := FALSE;
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
            uiActHint := 0;
            uiActTime := 0;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            uiStageIndex := 0;
            udiElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := 0;
                bNozzleIned := FALSE;
                bNozzleOuted := FALSE;
                uiStageIndex := 1;

                IF bInRequest THEN
                    eState := eState_NozzleIning;
                ELSIF bOutRequest THEN
                    eState := eState_NozzleOuting;
                ELSE
                    bAlarm := TRUE;
                    dwAlarmID := DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_NozzleIning:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stNozzlePara.stNozzleInDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stNozzlePara.aNozzleInSeg[1];
                END_IF;
                uiActHint := 113;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > stNozzlePara.uiNozzleInSegCnt THEN
                    eState := eState_NozzleIned;
                ELSE
                    stSegCmd := stNozzlePara.aNozzleInSeg[uiStageIndex];
                    uiActHint := 87 + uiStageIndex; // 88-89
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    IF (stNozzlePara.uiNozzleInMode = 2) AND (udiNozzleElecRulerVal >= stSegCmd.udiPos) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    ELSIF ((stNozzlePara.uiNozzleInMode = 0) AND (stSegCmd.uiTime > 0) AND (udiElapsedMs >= TO_UDINT(stSegCmd.uiTime))) OR ((stNozzlePara.uiNozzleInMode = 1) AND bNozzleInStop) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;

                    IF (stNozzlePara.uiNozzleInLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stNozzlePara.uiNozzleInLimitTime)) THEN
                        dwAlarmID := dwAlarmID OR DWORD#16#0001;
                        eState := eState_Error;
                    END_IF;
                END_IF;
            END_IF;

        eState_NozzleIned:
            bBusy := FALSE;
            bDone := TRUE;
            bNozzleIned := TRUE;
            uiActHint := 6;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_NozzleOuting:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                stSegCmd := stNozzlePara.stNozzleOutDbgSeg;
                IF (stSegCmd.uiPres = 0) AND (stSegCmd.uiSpd = 0) AND (stSegCmd.udiPos = 0) THEN
                    stSegCmd := stNozzlePara.aNozzleOutSeg[1];
                END_IF;
                uiActHint := 114;
                uiPresCmd := stSegCmd.uiPres;
                uiSpdCmd := stSegCmd.uiSpd;
                udiPosCmd := stSegCmd.udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > stNozzlePara.uiNozzleOutSegCnt THEN
                    eState := eState_NozzleOuted;
                ELSE
                    stSegCmd := stNozzlePara.aNozzleOutSeg[uiStageIndex];
                    uiActHint := 85 + uiStageIndex; // 86-87
                    uiPresCmd := stSegCmd.uiPres;
                    uiSpdCmd := stSegCmd.uiSpd;
                    udiPosCmd := stSegCmd.udiPos;

                    IF (stNozzlePara.uiNozzleOutMode = 2) AND (udiNozzleElecRulerVal >= stSegCmd.udiPos) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    ELSIF ((stNozzlePara.uiNozzleOutMode = 0) AND (stSegCmd.uiTime > 0) AND (udiElapsedMs >= TO_UDINT(stSegCmd.uiTime))) OR ((stNozzlePara.uiNozzleOutMode = 1) AND bNozzleOutStop) THEN
                        uiStageIndex := uiStageIndex + 1;
                        udiElapsedMs := 0;
                        tPulse(IN := FALSE, PT := T#100MS);
                    END_IF;

                    IF (stNozzlePara.uiNozzleOutLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stNozzlePara.uiNozzleOutLimitTime)) THEN
                        dwAlarmID := dwAlarmID OR DWORD#16#0002;
                        eState := eState_Error;
                    END_IF;
                END_IF;
            END_IF;

        eState_NozzleOuted:
            bBusy := FALSE;
            bDone := TRUE;
            bNozzleOuted := TRUE;
            uiActHint := 16;
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

stNozzleAxis.rSetPressure := TO_LREAL(uiPresCmd);
stNozzleAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
stNozzleAxis.rSetPosition := TO_LREAL(udiPosCmd);
stNozzleAxis.stPumpRequest.bRequest := bBusy;
stNozzleAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
stNozzleAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    stNozzleAxis.eAxisState := Running;
ELSE
    stNozzleAxis.eAxisState := Idle;
END_IF;
stNozzleAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
