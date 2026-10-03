; ==================================================================================================
; dlserialin.asm - datalogging: serial inputs
;> feature: FEAT_DLSERIALIN
;> name: Datalogging: serial inputs
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> pages: serialin
;> ram: 392h-39Ah (the stock trouble codes' own); with FEAT_STOCK_DTC module RAM (9 bytes)
;> about: The datalog cable works both ways: the laptop (or a small board on the ECU's datalog receive
;>        line) sends values to the ECU, and modules use them as extra inputs - a wideband the laptop
;>        reads, a switch with no spare pin for it, a flex sensor. Each value is three bytes: FFh, the
;>        input's number (00h-FDh, 254 inputs) and the value (00h-FEh); nothing comes back, and a running
;>        channel stream carries on. The ROM keeps eight, picked by number on its page. Closed loop, lean
;>        protection and flex fuel can read one as an analog input (inputs 4-11); every module with a
;>        switch input can take one as a switch (on while it is not 0). With none for a while (a cable
;>        pulled out) each reads as its default. Datalog > Channels… sends them from the log.
;
; The receive interrupt (datalog.asm) takes FFh in its command state as the start of one: state 4 the input's
; number (the slot that keeps it, or none, in r1), state 5 its value. FFh is never a number or a value, so a
; byte lost on the line is over by the next FFh. lib.asm's mod_analog reads them as inputs 4-11.
; ==================================================================================================
ifdef FEAT_DLSERIALIN

if XP == XP_DEFS
ifndef NEED_MODLIB
define NEED_MODLIB
endif
if defined(FEAT_STOCK_DTC)
SERIN_RAM           EQU     MODRAM_NEXT         ; the eight inputs' values
undef MODRAM_NEXT
define MODRAM_NEXT (SERIN_RAM + 8)
SERIN_AGE           EQU     MODRAM_NEXT         ; tick slots (32.8 ms) since one came, FFh at most (and at power-up)
undef MODRAM_NEXT
define MODRAM_NEXT (SERIN_AGE + 1)
else
; without the stock trouble codes their own RAM is free (392h-39Ah: nothing else touches it), and module RAM is not
; used up by these
SERIN_RAM           EQU     00392h              ; the eight inputs' values
SERIN_AGE           EQU     0039ah              ; tick slots (32.8 ms) since one came, FFh at most (and at power-up)
endif
endif

if XP == XP_BOOT
                CAL     serin_boot
endif

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #SLOT_DLSERIALIN
                JNE     serin_tick_skip
                CAL     serin_tick
serin_tick_skip:
endif

if XP == XP_CAL
;@ SerialInputNumber type=u8 count=8 formula=raw category="Serial inputs" slot=serialin.number desc="The input number (00h-FDh) each of the eight keeps, as the device sends it; FFh: that one is not used. They are inputs 4-11 where a module asks for an analog input."
serin_inputs:           DB  000h, 001h, 002h, 003h, 004h, 005h, 006h, 007h
;@ SerialInputDefault type=u8 count=8 formula=raw category="Serial inputs" slot=serialin.default desc="What each reads as while none has come for the time below, and from power-up until the first one."
serin_default:          DB  000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
;@ SerialInputTimeout type=u8 formula="x * 32.768" inverse="x / 32.768" unit=ms decimals=0 category="Serial inputs" slot=serialin.timeout desc="How long without any before every input reads as its default; 0 keeps the last value for ever."
serin_timeout:          DB  01eh                   ; about 1 s
endif

if XP == XP_CODE
; ------------------------------------------------------------------ power-up: none yet, so the defaults
serin_boot:     L       A, DP
                PUSHS   A
                MOV     DP, #SERIN_AGE
                MOVB    [DP], #0ffh
                POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ every 16 ticks: the time since one came
; Tick context (the include site): only A is free; DP is kept.
serin_tick:     L       A, DP
                PUSHS   A
                MOV     DP, #SERIN_AGE
                CLRB    A
                LB      A, [DP]
                CMPB    A, #0ffh
                JEQ     serin_tick_ret
                INCB    [DP]
serin_tick_ret: POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ states 4-5 (datalog.asm's receive interrupt)
; In: A (byte) = the byte, bank 6Fh, DP pushed. Leaves through dl_rx_ret; sends nothing.
dl_rx_serin:    CMPB    A, #0ffh               ; FFh only ever starts one: from the beginning
                JNE     dl_si_byte
                MOVB    r0, #004h
                J       dl_rx_ret
dl_si_byte:     CMPB    r0, #004h
                JNE     dl_si_value
                MOV     DP, #serin_inputs      ; which of the eight keeps this input
                MOVB    r1, #000h
dl_si_find:     CMPCB   A, [DP]
                JEQ     dl_si_found
                INC     DP
                INCB    r1
                CMPB    r1, #008h
                JLT     dl_si_find
                MOVB    r1, #0ffh              ; none: its value is let go
dl_si_found:    MOVB    r0, #005h
                J       dl_rx_ret
dl_si_value:    MOVB    r0, #000h
                CMPB    r1, #008h
                JGE     dl_si_done
                L       A, ACC                 ; the value (ACCH clear: the interrupt read the byte with CLR A first)...
                PUSHS   A                      ; ...kept
                CLR     A
                LB      A, r1                  ; the slot
                L       A, ACC
                ADD     A, #SERIN_RAM
                MOV     DP, A
                POPS    A
                LB      A, ACC
                STB     A, [DP]
                MOV     DP, #SERIN_AGE
                MOVB    [DP], #000h            ; one has come
dl_si_done:     J       dl_rx_ret

; ------------------------------------------------------------------ an input for the modules (lib.asm's mod_analog)
; In: A (byte) = 4-11, serial input 1-8. Out: A (byte) = its value, or its default while none has come for the time
; set. Uses DP, r7. Tick context.
serin_read:     SUBB    A, #004h
                CMPB    A, #008h
                JGE     serin_read_none
                STB     A, r7                  ; the slot
                CLRB    A
                LCB     A, serin_timeout
                CMPB    A, #000h
                JEQ     serin_read_ram         ; 0: always the last value
                MOV     DP, #SERIN_AGE
                CMPB    A, [DP]
                JGT     serin_read_ram         ; one came within the time
                MOV     DP, #serin_default
                CAL     serin_at
                LCB     A, [DP]
                RT
serin_read_ram: MOV     DP, #SERIN_RAM
                CAL     serin_at
                LB      A, [DP]
                RT
serin_read_none:
                CLRB    A
                RT
; DP + the slot (r7)
serin_at:       CLR     A
                LB      A, r7
                L       A, ACC
                ADD     DP, A
                CLRB    A                      ; byte mode for the LB / LCB after (LCB leaves the mode as it was)
                RT
endif

endif
