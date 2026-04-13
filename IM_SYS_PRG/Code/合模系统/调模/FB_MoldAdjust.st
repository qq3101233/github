(* 
  FB_MoldAdjust 功能块
  功能：
  1. 负责调模进、调模退及其调试动作的执行状态机。
  2. 根据调模参数生成压力、速度与位置命令，并输出调模进退完成状态。

  说明：
  1. 自动/工艺模式使用 1=调模进、2=调模退；手动点动使用 3/4。
  2. 本块输出的是工艺命令，不直接承担轴保护与最终限幅。
*)
FUNCTION_BLOCK FB_MoldAdjust
VAR_IN_OUT
    stMoldAdjustAxis: ST_AxisRefHyd;  // 调模共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动调模动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动调模
    uiMoldAdjustMode: UINT;           // 1=调模进 2=调模退 3=手动调模进 4=手动调模退
    stMoldAdjustPara: ST_MoldAdjustPara; // 调模工艺参数
    bMoldAdjustInStop: BOOL;          // 调模进停止信号
    bMoldAdjustOutStop: BOOL;         // 调模退停止信号
    uiClampPresElecRulerVal: UINT;    // 压力反馈
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bMoldAdjustIned: BOOL;            // TRUE=调模进完成
    bMoldAdjustOuted: BOOL;           // TRUE=调模退完成
    uiPresCmd: UINT;                  // 压力命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_MoldAdjustState := eState_Idle;
    tPulse: TON;
    udiElapsedMs: UDINT := 0;
    bManualActive: BOOL := FALSE;
    bInRequest: BOOL := FALSE;
    bOutRequest: BOOL := FALSE;
END_VAR

bManualActive := bManualMode OR (uiMoldAdjustMode = 3) OR (uiMoldAdjustMode = 4);
bInRequest := (uiMoldAdjustMode = 1) OR (uiMoldAdjustMode = 3);
bOutRequest := (uiMoldAdjustMode = 2) OR (uiMoldAdjustMode = 4);

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bMoldAdjustIned := FALSE;
    bMoldAdjustOuted := FALSE;
    uiPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
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
    uiActHint := 0;
    udiElapsedMs := 0;
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
            udiElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := 0;
                bMoldAdjustIned := FALSE;
                bMoldAdjustOuted := FALSE;
                IF bInRequest THEN
                    eState := eState_MoldAdjustIning;
                ELSIF bOutRequest THEN
                    eState := eState_MoldAdjustOuting;
                ELSE
                    bAlarm := TRUE;
                    dwAlarmID := DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_MoldAdjustIning:
            bBusy := TRUE;
            uiActHint := 55;
            uiPresCmd := stMoldAdjustPara.stMoldAdjustInSeg.uiPres;
            uiSpdCmd := stMoldAdjustPara.stMoldAdjustInSeg.uiSpd;
            udiPosCmd := 0;

            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF (stMoldAdjustPara.uiMoldAdjustInMode = 0) AND (stMoldAdjustPara.stMoldAdjustInSeg.uiTime > 0) AND (udiElapsedMs >= TO_UDINT(stMoldAdjustPara.stMoldAdjustInSeg.uiTime)) THEN
                    eState := eState_MoldAdjustIned;
                ELSIF (stMoldAdjustPara.uiMoldAdjustInMode <> 0) AND bMoldAdjustInStop THEN
                    eState := eState_MoldAdjustIned;
                END_IF;

                IF (stMoldAdjustPara.uiMoldAdjustInLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stMoldAdjustPara.uiMoldAdjustInLimitTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0001;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_MoldAdjustIned:
            bBusy := FALSE;
            bDone := TRUE;
            bMoldAdjustIned := TRUE;
            uiActHint := 56;
            uiPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_MoldAdjustOuting:
            bBusy := TRUE;
            uiActHint := 57;
            uiPresCmd := stMoldAdjustPara.stMoldAdjustOutSeg.uiPres;
            uiSpdCmd := stMoldAdjustPara.stMoldAdjustOutSeg.uiSpd;
            udiPosCmd := 0;

            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualActive THEN
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF (stMoldAdjustPara.uiMoldAdjustOutMode = 0) AND (stMoldAdjustPara.stMoldAdjustOutSeg.uiTime > 0) AND (udiElapsedMs >= TO_UDINT(stMoldAdjustPara.stMoldAdjustOutSeg.uiTime)) THEN
                    eState := eState_MoldAdjustOuted;
                ELSIF (stMoldAdjustPara.uiMoldAdjustOutMode <> 0) AND bMoldAdjustOutStop THEN
                    eState := eState_MoldAdjustOuted;
                END_IF;

                IF (stMoldAdjustPara.uiMoldAdjustOutLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stMoldAdjustPara.uiMoldAdjustOutLimitTime)) THEN
                    dwAlarmID := dwAlarmID OR DWORD#16#0002;
                    eState := eState_Error;
                END_IF;
            END_IF;

        eState_MoldAdjustOuted:
            bBusy := FALSE;
            bDone := TRUE;
            bMoldAdjustOuted := TRUE;
            uiActHint := 58;
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

stMoldAdjustAxis.rSetPressure := TO_LREAL(uiPresCmd);
stMoldAdjustAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
stMoldAdjustAxis.rSetPosition := TO_LREAL(udiPosCmd);
stMoldAdjustAxis.stPumpRequest.bRequest := bBusy;
stMoldAdjustAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
stMoldAdjustAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    stMoldAdjustAxis.eAxisState := Running;
ELSE
    stMoldAdjustAxis.eAxisState := Idle;
END_IF;
stMoldAdjustAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
