; ==================================================================================================
; triglog.asm - the trigger pattern log: one cam revolution of the crank (CKP), TDC and cylinder (CYP) sensors
;> feature: FEAT_TRIGLOG
;> name: Trigger pattern log
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> requires: FEAT_DLSTREAM
;> ram: 0FDh bit 6 (capturing), module RAM (28 bytes)
;> about: The distributor's three signals as the ECU sees them, for a sensor that plays up: asked over
;>        the datalog cable, the ECU records one cam revolution - the 24 crank teeth, each one's time,
;>        and which of them the TDC and cylinder pulses came with - and sends it back (Datalogging >
;>        Trigger pattern). A missed or extra crank tooth, a TDC pulse out of place or missing, no
;>        cylinder pulse: each shows in the bars. Nothing runs until a capture is asked for, and then
;>        only for one revolution.
;
;   61h          capture one cam revolution from the next crank tooth. Answer 61h.
;   62h          send what was caught: 62h, the state (0 waiting for the first tooth, 1-24 teeth so far + 1, 25
;                done), the scale (each period shifted right this many places; FFh none yet), the 24 teeth, and
;                the sum of them all with the 62h. A tooth: bits 0-5 the time since the tooth before, shifted
;                right by the scale (set from the engine's crank period as the capture starts, or from its first
;                tooth if the engine was not running, so a tooth reads 13-31: a missed tooth reads about twice
;                that, an extra one about half; 63 is "63 or more"), bit 6 the cylinder (CYP) pulse came
;                with it, bit 7 a TDC pulse came with it.
; The crank's 24 teeth a cam revolution are timed on timer 2's capture (TMR2, 3.2 us), at the end of its interrupt
; (one bit test a tooth while no capture runs); TDC is INT1's flag (every sixth tooth: its interrupt is never enabled,
; the crank task reads the flag), CYP the transition detector's latch (once a revolution, three teeth after cylinder
; 1's TDC). A pulse "came with" a tooth when it arrived after the tooth before.
; ==================================================================================================
ifdef FEAT_TRIGLOG

if XP == XP_DEFS
ifndef NEED_CRANKHOOK
define NEED_CRANKHOOK
endif
TRG_TEETH       EQU     24
TRG_LAST        EQU     ((MODRAM_NEXT + 1) / 2) * 2     ; word (even): the last tooth's capture
TRG_N           EQU     TRG_LAST + 2    ; 0 waiting for the first tooth, 1-24 the slot to fill + 1, 25 done
TRG_SHIFT       EQU     TRG_LAST + 3    ; the scale (FFh: not set yet)
TRG_BUF         EQU     TRG_LAST + 4    ; the 24 teeth
undef MODRAM_NEXT
define MODRAM_NEXT (TRG_BUF + TRG_TEETH)
endif

; a crank tooth (timer 2 interrupt, interrupts off): A (byte) bit 7 TDC came with it, bit 6 CYP; DP is free
if XP == XP_CKP
                CAL     trg_tooth
endif

if XP == XP_CODE
; ------------------------------------------------------------------ a tooth
trg_tooth:      PUSHS   A                      ; the TDC and CYP bits
                MOV     DP, #TRG_N
                LB      A, [DP]
                JNE     trg_more
; the first tooth: its time kept, nothing to measure yet (a TDC or CYP with it is not shown: no slot)
                MOV     DP, #TRG_LAST
                L       A, off(TMR2)
                ST      A, [DP]
                MOV     DP, #TRG_N
                MOVB    [DP], #001h
                POPS    A
                RT
trg_stop:       RB      0fdh.6
                POPS    A
                RT
trg_more:       CMPB    A, #TRG_TEETH + 1
                JGE     trg_stop               ; (done: the hook should be off)
                MOV     DP, #TRG_LAST          ; the time since the last tooth...
                L       A, off(TMR2)
                SUB     A, [DP]
                PUSHS   A
                L       A, off(TMR2)
                ST      A, [DP]                ; ...and this one's kept
                POPS    A
                MOV     DP, #TRG_SHIFT
                MB      C, [DP].7
                JGE     trg_apply
; no scale yet (the engine was not running at the capture's start): this first period sets it
                CAL     trg_pick
                SJ      trg_put
; later ones by the same scale
trg_apply:      MB      C, [DP].3
                JGE     trg_a4
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
trg_a4:         MB      C, [DP].2
                JGE     trg_a2
                SRL     A
                SRL     A
                SRL     A
                SRL     A
trg_a2:         MB      C, [DP].1
                JGE     trg_a1
                SRL     A
                SRL     A
trg_a1:         MB      C, [DP].0
                JGE     trg_put
                SRL     A
trg_put:        CMP     A, #0003fh             ; 63 at most (a long gap: no tooth, or the engine stopping)
                JLT     trg_put2
                L       A, #0003fh
trg_put2:       PUSHS   A
                MOV     DP, #TRG_N
                CLR     A
                LB      A, [DP]
                L       A, ACC
                ADD     A, #TRG_BUF - 1
                MOV     DP, A                  ; this tooth's slot
                POPS    A
                LB      A, ACC                 ; (byte mode: POPS leaves the mode as it was - word here)
                STB     A, [DP]
                POPS    A
                LB      A, ACC
                ORB     A, [DP]                ; the TDC and CYP bits
                STB     A, [DP]
                MOV     DP, #TRG_N
                INCB    [DP]
                LB      A, [DP]
                CMPB    A, #TRG_TEETH + 1
                JLT     trg_ret
                RB      0fdh.6                 ; all 24: done, the hook off
trg_ret:        RT

; ------------------------------------------------------------------ the scale
; In: A (word) = a period, DP = TRG_SHIFT. Shifts A right until it is under 32 (16-31) and keeps how far: 8 places at
; 1000h and up, then 4 at 100h, 2 at 40h, 1 at 20h. Out: A shifted.
trg_pick:       MOVB    [DP], #000h
                CMP     A, #01000h
                JLT     trg_c4
                SB      [DP].3
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
trg_c4:         CMP     A, #00100h
                JLT     trg_c2
                SB      [DP].2
                SRL     A
                SRL     A
                SRL     A
                SRL     A
trg_c2:         CMP     A, #00040h
                JLT     trg_c1
                SB      [DP].1
                SRL     A
                SRL     A
trg_c1:         CMP     A, #00020h
                JLT     trg_pick_ret
                SB      [DP].0
                SRL     A
trg_pick_ret:   RT

; ------------------------------------------------------------------ 61h: arm (datalog.asm's receive interrupt, bank 6Fh)
dl_rx_trgarm:   RB      0fdh.6                 ; (the hooks off while the buffer is cleared)
                MOV     DP, #TRG_BUF
dl_rx_trgclr:   MOVB    [DP], #000h
                INC     DP
                CMP     DP, #TRG_BUF + TRG_TEETH
                JNE     dl_rx_trgclr
                MOV     DP, #TRG_N
                MOVB    [DP], #000h
                MOV     DP, #TRG_SHIFT
                MOVB    [DP], #0ffh
                L       A, ENG_RPMP                ; the scale from the engine's own (averaged) crank period, so a first tooth
                CMP     A, #0ffffh             ; that is a missed or extra one does not set it; none (FFFFh: not running) - the
                JEQ     dl_rx_trgon            ; first period sets it
                CAL     trg_pick               ; (the period word is 6/5 of a tooth: teeth read 13-26)
dl_rx_trgon:    SB      0fdh.6                 ; from the next tooth
                LB      A, #061h
                J       dl_rx_send
; 62h: send it (r2 = 8)
dl_rx_trgread:  MOVB    r2, #008h
                J       dl_rx_start

; ------------------------------------------------------------------ the next byte (r2 = 8): 62h, the state, the scale, the 24 teeth, their sum
dl_next_trg:    LB      A, r3
                JNE     dl_nt_byte
                LB      A, #062h
                J       dl_next_put
dl_nt_byte:     CMPB    A, #TRG_TEETH + 3
                JGE     dl_nt_sum
                SUBB    A, #001h               ; 0 the state, 1 the scale, 2-25 the teeth
                L       A, ACC                 ; (ACCH clear: dl_next starts with CLR A)
                ADD     A, #TRG_N
                MOV     DP, A
                LB      A, [DP]
                J       dl_next_put
dl_nt_sum:      J       dl_next_fsum           ; the sum, and the end
endif

endif
