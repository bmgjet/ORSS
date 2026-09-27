; ==================================================================================================
; tpscal.asm - throttle sensor end points (HTS "TPS sensor" page)
;> feature: FEAT_TPSCAL
;> name: TPS sensor end points
;> category: Sensors
;> pages: tpssensor
;> ram: none
;> about: Rescales the throttle sensor to the volts it gives closed and wide open, so a sensor that does
;>        not read like the stock one still gives 0-100 % to everything that uses the throttle. Off
;>        until enabled.
; ==================================================================================================
ifdef FEAT_TPSCAL

if XP == XP_DEFS
ifndef NEED_TPSCAL
define NEED_TPSCAL
endif

endif

if XP == XP_CAL
;@ TPSCalEnable type=u8 flag=1 on=1 off=0 category="TPS sensor" slot=tpssensor.custom desc="Use these end points."
tpscal_enable:          DB  000h
;@ TPSCalMin type=u8 formula=volts_5v_byte category="TPS sensor" slot=tpssensor.min desc="Sensor volts at 0 % (closed)."
tpscal_min:             DB  019h
;@ TPSCalMax type=u8 formula=volts_5v_byte category="TPS sensor" slot=tpssensor.max desc="Sensor volts at 100 % (wide open)."
tpscal_max:             DB  0e5h
endif

if XP == XP_CODE
; The skeleton calls it with the throttle's A/D reading in er0 (crank task, after the fault check). Out:
; er0 on the stock scale, 1900h at the closed point to E500h wide open. er1 and er2 are kept.
mod_tpscal:     CLRB    A
                LCB     A, tpscal_enable
                CMPB    A, #000h
                JEQ     tpscal_ret
                L       A, er2
                PUSHS   A
                L       A, er1
                PUSHS   A
                CLR     A
                LCB     A, tpscal_min
                ST      A, er1                 ; closed
                CLR     A
                LCB     A, tpscal_max
                SUB     A, er1                 ; the span: none (or backwards) leaves the reading alone
                JLT     tpscal_done
                JEQ     tpscal_done
                ST      A, er2
                L       A, er1
                SWAP                           ; closed x 256
                ST      A, er1
                L       A, er0
                SUB     A, er1                 ; past the closed point...
                JGE     tpscal_pos
                CLR     A
tpscal_pos:     ST      A, er1
                L       A, er2
                SWAP                           ; ...and no further than the open point
                CMP     A, er1
                JGE     tpscal_in
                ST      A, er1
tpscal_in:      L       A, er1
                MOV     er0, #000cch           ; x (E5h - 19h) / span
                MUL
                MOV     er0, er1
                DIV
                ADD     A, #01900h
                ST      A, er0
tpscal_done:    POPS    A
                L       A, ACC
                ST      A, er1
                POPS    A
                L       A, ACC
                ST      A, er2
tpscal_ret:     RT
endif

endif
