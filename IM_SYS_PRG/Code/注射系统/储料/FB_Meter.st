(* 
  FB_Meter 功能块
  功能：
  1. 负责储料动作的执行状态机，可按段完成储料过程。
  2. 根据储料参数输出压力、背压、速度和位置命令，并返回储料完成状态。

  说明：
  1. 手动模式下本块工作在点动方式；自动模式下按参数段推进。
  2. 本块只负责工艺层命令，不承担最终轴保护。
*)
FUNCTION_BLOCK FB_Meter
VAR_IN_OUT
    stMeterAxis: ST_AxisRefHyd;       // 储料共享轴结构
END_VAR
VAR_INPUT
    bStart: BOOL;                     // TRUE=启动储料动作
    bStop: BOOL;                      // TRUE=正常停止
    bEStop: BOOL;                     // TRUE=急停
    bReset: BOOL;                     // TRUE=复位状态机与输出
    bManualMode: BOOL;                // TRUE=手动点动储料
    stMeterPara: ST_MeterPara;        // 储料工艺参数
    bMeterStop: BOOL;                 // 储料停止信号
    udiInjElecRulerVal: UDINT;        // 位置反馈
END_VAR
VAR_OUTPUT
    bBusy: BOOL;                      // TRUE=当前动作尚未结束
    bDone: BOOL;                      // TRUE=当前动作完成
    bAlarm: BOOL;                     // TRUE=当前动作报警
    dwAlarmID: DWORD;                 // 模块报警码
    uiActHint: UINT;                  // 当前动作提示码
    uiActTime: UINT;                  // 当前动作持续时间，单位 s
    bMetered: BOOL;                   // TRUE=储料完成
    uiPresCmd: UINT;                  // 压力命令输出
    uiBackPresCmd: UINT;              // 背压命令输出
    uiSpdCmd: UINT;                   // 速度命令输出
    udiPosCmd: UDINT;                 // 位置命令输出
END_VAR
VAR
    eState: E_MeterState := eState_Idle;
    uiStageIndex: UINT := 0;
    tPulse: TON;
    udiElapsedMs: UDINT := 0;
END_VAR

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := 0;
    uiActHint := 0;
    uiActTime := 0;
    bMetered := FALSE;
    uiPresCmd := 0;
    uiBackPresCmd := 0;
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
    uiBackPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSIF bStop THEN
    eState := eState_Idle;
    bBusy := FALSE;
    uiActHint := 0;
    uiPresCmd := 0;
    uiBackPresCmd := 0;
    uiSpdCmd := 0;
    udiPosCmd := 0;
    udiElapsedMs := 0;
    tPulse(IN := FALSE, PT := T#100MS);
ELSE
    CASE eState OF
        eState_Idle:
            bBusy := FALSE;
            uiActHint := 0;
            uiActTime := 0;
            uiPresCmd := 0;
            uiBackPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            uiStageIndex := 0;
            udiElapsedMs := 0;
            tPulse(IN := FALSE, PT := T#100MS);
            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := 0;
                bMetered := FALSE;
                uiStageIndex := 1;
                eState := eState_Metering;
            END_IF;

        eState_Metering:
            bBusy := TRUE;
            tPulse(IN := TRUE, PT := T#100MS);
            IF tPulse.Q THEN
                udiElapsedMs := udiElapsedMs + 100;
                tPulse(IN := FALSE, PT := T#100MS);
            END_IF;
            uiActTime := TO_UINT(udiElapsedMs / 1000);

            IF bManualMode THEN
                uiActHint := 66;
                uiPresCmd := stMeterPara.aMeterSeg[1].uiSPres;
                uiBackPresCmd := stMeterPara.aMeterSeg[1].uiBackPres;
                uiSpdCmd := stMeterPara.aMeterSeg[1].uiSpd;
                udiPosCmd := stMeterPara.aMeterSeg[1].udiPos;
                IF NOT bStart THEN
                    eState := eState_Idle;
                END_IF;
            ELSE
                IF uiStageIndex > stMeterPara.uiMeterSegCnt THEN
                    eState := eState_Metered;
                ELSE
                    uiActHint := 10 + uiStageIndex;
                    uiPresCmd := stMeterPara.aMeterSeg[uiStageIndex].uiSPres;
                    uiBackPresCmd := stMeterPara.aMeterSeg[uiStageIndex].uiBackPres;
                    uiSpdCmd := stMeterPara.aMeterSeg[uiStageIndex].uiSpd;
                    udiPosCmd := stMeterPara.aMeterSeg[uiStageIndex].udiPos;

                    IF (stMeterPara.uiMeterMode = 0) AND (udiInjElecRulerVal >= stMeterPara.aMeterSeg[uiStageIndex].udiPos) THEN
                        uiStageIndex := uiStageIndex + 1;
                    ELSIF (stMeterPara.uiMeterMode <> 0) AND bMeterStop THEN
                        uiStageIndex := uiStageIndex + 1;
                    END_IF;

                    IF (stMeterPara.uiMeterLimitTime > 0) AND (udiElapsedMs >= TO_UDINT(stMeterPara.uiMeterLimitTime)) THEN
                        dwAlarmID := dwAlarmID OR DWORD#16#0001;
                        eState := eState_Error;
                    END_IF;
                END_IF;
            END_IF;

        eState_Metered:
            bBusy := FALSE;
            bDone := TRUE;
            bMetered := TRUE;
            uiActHint := 12;
            uiPresCmd := 0;
            uiBackPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;

        eState_Error:
            bBusy := FALSE;
            bAlarm := TRUE;
            uiActHint := 1;
            uiPresCmd := 0;
            uiBackPresCmd := 0;
            uiSpdCmd := 0;
            udiPosCmd := 0;
            tPulse(IN := FALSE, PT := T#100MS);

    ELSE
        eState := eState_Error;
    END_CASE;
END_IF;

stMeterAxis.rSetPressure := TO_LREAL(uiPresCmd);
stMeterAxis.rSetVelocity := TO_LREAL(uiSpdCmd);
stMeterAxis.rSetPosition := TO_LREAL(udiPosCmd);
stMeterAxis.stPumpRequest.bRequest := bBusy;
stMeterAxis.stPumpRequest.rPressureSet := TO_LREAL(uiPresCmd);
stMeterAxis.stPumpRequest.rFlowSet := TO_LREAL(uiSpdCmd);
IF bBusy THEN
    stMeterAxis.eAxisState := Running;
ELSE
    stMeterAxis.eAxisState := Idle;
END_IF;
stMeterAxis.nFaultCode := TO_INT(dwAlarmID);
END_FUNCTION_BLOCK
