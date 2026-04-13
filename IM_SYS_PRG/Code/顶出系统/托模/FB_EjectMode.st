(* 
  FB_EjectMode 功能块
  功能：
  1. 在基础 `FB_Eject` 之上组合出定次、震动、停留三种托模模式。
  2. 通过内部顺序控制，把“托模进/托模退/托模保持”拼成更高层动作。
  3. 对外仍保持与普通托模模块相似的 Busy/Done/Alarm 接口，便于主控统一调用。

  说明：
  1. 本块本身不直接生成液压命令，而是复用 `FB_Eject` 完成具体动作。
  2. `uiSeqPhase` 用来表示当前执行到“复位子块、托进、再次复位、托退”的哪一步。
  3. 只有在手动组合模式被上层明确选择时，才应该让本块接管托模轴输出。
*)
FUNCTION_BLOCK FB_EjectMode
VAR_IN_OUT
    stEjectAxis: ST_AxisRefHyd;
END_VAR
VAR_INPUT
    bStart: BOOL;
    bStop: BOOL;
    bEStop: BOOL;
    bReset: BOOL;
    uiEjectMode: UINT;            // 1=定次 2=震动 3=停留
    uiEjectTimes: UINT;           // 定次/震动次数；震动模式下 0 表示持续循环
    stEjectPara: ST_EjectPara;
    bEjectInStop: BOOL;
    bEjectOutStop: BOOL;
    udiEjectElecRulerVal: UDINT;
END_VAR
VAR_OUTPUT
    bBusy: BOOL;
    bDone: BOOL;
    bAlarm: BOOL;
    dwAlarmID: DWORD;
    uiActHint: UINT;
    uiActTime: UINT;
    bEjectIned: BOOL;
    bEjectOuted: BOOL;
    uiPresCmd: UINT;
    uiSpdCmd: UINT;
    udiPosCmd: UDINT;
END_VAR
VAR
    eState: E_EjectModeState := eState_Idle;
    fbEject: FB_Eject;

    (* 发给内部 `FB_Eject` 的命令。 *)
    bCmdStart: BOOL := FALSE;
    bCmdReset: BOOL := FALSE;
    uiCmdMode: UINT := 0;

    (* 顺序控制变量。 *)
    uiExecCount: UINT := 0;
    uiSeqPhase: UINT := 0;

    (* 内部 `FB_Eject` 状态缓存。 *)
    bSubBusy: BOOL := FALSE;
    bSubDone: BOOL := FALSE;
    bSubAlarm: BOOL := FALSE;
    dwSubAlarmID: DWORD := 0;
    uiSubActHint: UINT := 0;
    uiSubActTime: UINT := 0;
    bSubEjectIned: BOOL := FALSE;
    bSubEjectOuted: BOOL := FALSE;
    uiSubPresCmd: UINT := 0;
    uiSubSpdCmd: UINT := 0;
    udiSubPosCmd: UDINT := 0;
END_VAR

(* 每个扫描周期先清空对子块的控制命令。 *)
bCmdStart := FALSE;
bCmdReset := FALSE;
uiCmdMode := 0;

IF bReset THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := DWORD#0;
    uiActHint := 0;
    uiActTime := 0;
    uiExecCount := 0;
    uiSeqPhase := 0;
    bCmdReset := TRUE;

ELSIF bEStop THEN
    eState := eState_Error;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := TRUE;
    dwAlarmID := DWORD#16#0010;
    uiActHint := 1;
    uiActTime := 0;
    uiExecCount := 0;
    uiSeqPhase := 0;
    bCmdReset := TRUE;

ELSIF bStop THEN
    eState := eState_Idle;
    bBusy := FALSE;
    bDone := FALSE;
    bAlarm := FALSE;
    dwAlarmID := DWORD#0;
    uiActHint := 0;
    uiActTime := 0;
    uiExecCount := 0;
    uiSeqPhase := 0;
    bCmdReset := TRUE;

ELSE
    CASE eState OF
        eState_Idle:
            bBusy := FALSE;
            uiActHint := 0;
            uiActTime := 0;

            IF bStart THEN
                bDone := FALSE;
                bAlarm := FALSE;
                dwAlarmID := DWORD#0;
                uiExecCount := 0;
                uiSeqPhase := 0;

                CASE uiEjectMode OF
                    1: eState := eState_EjectCount;
                    2: eState := eState_EjectVibra;
                    3: eState := eState_EjectHold;
                ELSE
                    bAlarm := TRUE;
                    dwAlarmID := DWORD#16#0001;
                    eState := eState_Error;
                END_CASE;
            END_IF;

        eState_EjectCount:
            bBusy := TRUE;

            IF bSubAlarm THEN
                dwAlarmID := dwSubAlarmID;
                eState := eState_Error;
            ELSE
                CASE uiSeqPhase OF
                    0:
                        (* 子块切换动作前先复位，避免沿用上一个动作的完成态。 *)
                        bCmdReset := TRUE;
                        uiSeqPhase := 1;

                    1:
                        (* 托模进。 *)
                        uiCmdMode := 1;
                        bCmdStart := TRUE;
                        IF bSubDone THEN
                            uiSeqPhase := 2;
                        END_IF;

                    2:
                        (* 进入托模退前再复位一次子块。 *)
                        bCmdReset := TRUE;
                        uiSeqPhase := 3;

                    3:
                        (* 托模退。 *)
                        uiCmdMode := 2;
                        bCmdStart := TRUE;
                        IF bSubDone THEN
                            uiExecCount := uiExecCount + 1;
                            IF uiExecCount >= SEL(uiEjectTimes = 0, uiEjectTimes, 1) THEN
                                bBusy := FALSE;
                                bDone := TRUE;
                                eState := eState_Idle;
                            ELSE
                                uiSeqPhase := 0;
                            END_IF;
                        END_IF;

                ELSE
                    uiSeqPhase := 0;
                END_CASE;
            END_IF;

        eState_EjectVibra:
            bBusy := TRUE;

            IF bSubAlarm THEN
                dwAlarmID := dwSubAlarmID;
                eState := eState_Error;
            ELSE
                CASE uiSeqPhase OF
                    0:
                        bCmdReset := TRUE;
                        uiSeqPhase := 1;

                    1:
                        uiCmdMode := 1;
                        bCmdStart := TRUE;
                        IF bSubDone THEN
                            uiSeqPhase := 2;
                        END_IF;

                    2:
                        bCmdReset := TRUE;
                        uiSeqPhase := 3;

                    3:
                        uiCmdMode := 2;
                        bCmdStart := TRUE;
                        IF bSubDone THEN
                            uiExecCount := uiExecCount + 1;
                            IF (uiEjectTimes > 0) AND (uiExecCount >= uiEjectTimes) THEN
                                bBusy := FALSE;
                                bDone := TRUE;
                                eState := eState_Idle;
                            ELSE
                                uiSeqPhase := 0;
                            END_IF;
                        END_IF;

                ELSE
                    uiSeqPhase := 0;
                END_CASE;
            END_IF;

        eState_EjectHold:
            bBusy := TRUE;

            IF bSubAlarm THEN
                dwAlarmID := dwSubAlarmID;
                eState := eState_Error;
            ELSE
                CASE uiSeqPhase OF
                    0:
                        bCmdReset := TRUE;
                        uiSeqPhase := 1;

                    1:
                        uiCmdMode := 1;
                        bCmdStart := TRUE;
                        IF bSubDone THEN
                            bBusy := FALSE;
                            bDone := TRUE;
                            eState := eState_Idle;
                        END_IF;

                ELSE
                    uiSeqPhase := 0;
                END_CASE;
            END_IF;

        eState_Error:
            bBusy := FALSE;
            bDone := FALSE;
            bAlarm := TRUE;
            uiActHint := 1;
            IF dwAlarmID = DWORD#0 THEN
                dwAlarmID := SEL(dwSubAlarmID = DWORD#0, dwSubAlarmID, DWORD#16#0001);
            END_IF;
            bCmdReset := TRUE;

    ELSE
        dwAlarmID := DWORD#16#7FFF;
        eState := eState_Error;
    END_CASE;
END_IF;

(* 最后再调用内部子块，这样本扫描周期内刚决策出来的命令能立即送到子块。 *)
fbEject(
    stEjectAxis := stEjectAxis,
    bStart := bCmdStart,
    bStop := FALSE,
    bEStop := FALSE,
    bReset := bCmdReset,
    bManualMode := FALSE,
    uiEjectMode := uiCmdMode,
    stEjectPara := stEjectPara,
    bEjectInStop := bEjectInStop,
    bEjectOutStop := bEjectOutStop,
    udiEjectElecRulerVal := udiEjectElecRulerVal,
    bBusy => bSubBusy,
    bDone => bSubDone,
    bAlarm => bSubAlarm,
    dwAlarmID => dwSubAlarmID,
    uiActHint => uiSubActHint,
    uiActTime => uiSubActTime,
    bEjectIned => bSubEjectIned,
    bEjectOuted => bSubEjectOuted,
    uiPresCmd => uiSubPresCmd,
    uiSpdCmd => uiSubSpdCmd,
    udiPosCmd => udiSubPosCmd
);

(* 对外透传内部托模块的实际动作输出，便于主控统一读取。 *)
bEjectIned := bSubEjectIned;
bEjectOuted := bSubEjectOuted;
uiPresCmd := uiSubPresCmd;
uiSpdCmd := uiSubSpdCmd;
udiPosCmd := udiSubPosCmd;

IF (NOT bAlarm) AND (uiSubActHint <> 0) THEN
    uiActHint := uiSubActHint;
END_IF;
uiActTime := uiSubActTime;
END_FUNCTION_BLOCK
