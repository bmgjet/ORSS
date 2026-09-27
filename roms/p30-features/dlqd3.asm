; ==================================================================================================
; dlqd3.asm - datalogging: the QD3 frame
;> feature: FEAT_DLQD3
;> name: Datalogging: QD3 frame
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL, FEAT_DATALOG
;> about: The QD3 protocol, for scan tools and loggers that speak it: ABh -> BCh, then 46h -> a 40-byte
;>        frame (46h 26h first) and its checksum, the sum of the 40. Rpm, injector time, timing, knock
;>        retard, O2, VTEC, road speed, battery, MAP, throttle, intake air, coolant and the stored trouble
;>        codes; the other bytes hold what a QD3 ECU sends there. A different protocol from the HTS / ISR
;>        frame on the same pins: one or the other. The channel stream and the service commands go with either.
; ==================================================================================================
ifdef FEAT_DLQD3


if XP == XP_CAL
;@ DatalogQd3Table type=u16 count=40 category="Datalog" desc="RAM address sent as each byte of the 40-byte QD3 frame (FExxh: the constant xx, FF05h: VTEC in bit 0, 0: always 00h)."
dl_qd3_table:
                DW  0fe46h, 0fe26h, 000ach, 000adh, 0fe00h, 0fe00h, 0fe03h, 00146h   ;  0 46h 26h, rpm period lo/hi, 7 injector lo
if defined(FEAT_STOCK_KNOCK)
                DW  00147h, 00246h, 00243h, 003beh, 0fe00h, 0fe00h, 0fe00h, 0fe00h   ;  8 injector hi, advance, knock retard, O2
else
                DW  00147h, 00246h, 00000h, 003beh, 0fe00h, 0fe00h, 0fe00h, 0fe00h   ;  8 injector hi, advance, (no knock), O2
endif
                DW  0fe4fh, 0fe0ah, 0fe49h, 0ff05h, 000b4h, 000c3h, 000a3h, 0fe55h   ; 16 19 VTEC, 20 speed, 21 battery, 22 MAP
                DW  000b9h, 000c0h, 0fe00h, 0feffh, 0feffh, 0fe00h, 0fe75h, 0fee8h   ; 24 throttle, 25 intake air
if defined(FEAT_STOCK_DTC)
                DW  0fe00h, 000c1h, 0fe3ch, 0fe02h, 0031ah, 0031bh, 0031ch, 0031dh   ; 32 33 coolant, 36-39 stored trouble codes
else
                DW  0fe00h, 000c1h, 0fe3ch, 0fe02h, 00000h, 00000h, 00000h, 00000h   ; 32 33 coolant, 36-39 no codes kept
endif
endif

if XP == XP_CODE
; ------------------------------------------------------------------ ABh and 46h (datalog.asm's receive interrupt)
dl_rx_qd3hello: LB      A, #0bch
                J       dl_rx_send
dl_rx_qd3:      MOVB    r2, #006h
                J       dl_rx_start
; ------------------------------------------------------------------ the next byte of the QD3 frame (r2 = 6)
dl_next_qd3:    LB      A, r3
                CMPB    A, #028h
                JGE     dl_qd3_sum
                L       A, ACC
                SLL     A
                MOV     DP, A
                LC      A, dl_qd3_table[DP]
                CAL     dl_fetch
                J       dl_next_put
dl_qd3_sum:     J       dl_next_fsum           ; the sum of the 40 bytes, and the end
endif

endif
