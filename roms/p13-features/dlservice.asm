; ==================================================================================================
; dlservice.asm - datalogging: service commands
;> feature: FEAT_DLSERVICE
;> name: Datalogging: service commands
;> category: Diagnostics
;> platforms: P13
;> conflicts: FEAT_STOCK_SERIAL
;> ram: 1BDh, 1C7h
;> pages: datalog
;> about: Over the datalog cable (Datalogging > Codes and service…): clear the trouble codes, injectors
;>        off, the timing locked for a timing light, the maps picked, the GIO outputs forced on, and the
;>        cylinder test - one cylinder's injector cut at a time, to find the one that is not firing (cutting
;>        it changes nothing). The check-engine lamp flashes quickly while any of these is on.
;
; The 5xh commands of datalog.asm. Each is one byte, answered with one byte: the command itself when it is
; taken, 7Fh when this ROM cannot do it (the module it needs is not built in). Everything they set is
; forgotten at power-up (RAM), so a key cycle puts the ECU back to normal whatever was left on.
;   50h  clear the stored trouble codes (with FEAT_STOCK_DTC; without it there are none: 50h all the same)
;   51h  injectors off (a flooded engine, a compression test)        52h  injectors back on
;   53h  timing locked at DatalogServiceTiming (a timing light check)  54h  timing back to normal
;   55h  secondary maps as their switch says   56h  the first maps   57h  the secondary maps
;        (FEAT_MAPSWITCH or FEAT_DUALMAPS; the module must be enabled)
;   58h-5Bh  GIO 1-4: forced on, or back to its own conditions (a toggle; the answer is the command when it
;        is now forced on, 00h when it is back to its conditions; the GIO must be enabled, with an output)
;   5Eh  all of the above back to normal (the cylinder test too)   5Fh  the state: the DL_SVC byte below
;   63h  the cylinder test off: every injector back      64h-67h  cylinder 1-4's injector cut (only one at a
;        time: the one cut before comes back first). The engine runs on the other three; on an engine that
;        already runs on three, the cylinder whose cut changes nothing is the one not firing.
; While the injectors are off, the timing is locked or a cylinder is cut, the check-engine lamp flashes quickly
; (about four times a second), whatever else drives it, so a service mode is never left on unnoticed.
; ==================================================================================================
ifdef FEAT_DLSERVICE

if XP == XP_DEFS
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
; two bytes the skeleton and stock P30 never touch (not module RAM: that is full with every module built in)
; DL_SVC (features.inc, by platform): their state: bits 0 injectors off, 1 timing locked, 2 map chosen here, 3 that map is
                                                ;   the secondary one, 4-7 GIO 1-4 forced on. Written by the receive interrupt only.
DL_SVCX             EQU     SVC_MODLIB + 6              ; bits: 0 the lamp is taken for the flashing (tick), 1 clear the codes (set by the
                                                ;   receive interrupt, cleared by the main loop), 4-7 the cylinder test's injector
                                                ;   kept shut (as its P2 bit: 4 P2.0 cylinder 1, 5 P2.1 cylinder 3, 6 P2.2 cylinder 4,
                                                ;   7 P2.3 cylinder 2 - the injectors are wired in firing order). Single-instruction
                                                ;   bit set and clear only, so the three never undo each other.
ifndef NEED_INJCUT
define NEED_INJCUT
endif
; its tick slot (SLOT_DLSERVICE) comes from features.inc: tick mod 16, about 30 times a second
endif

if XP == XP_BOOT
                CAL     dls_boot
endif

if XP == XP_MAIN
                CAL     dls_main
endif

; after igncutmod.asm's (features.inc includes this file after it): a locked timing wins over a static cut timing
if XP == XP_IGN
                CAL     dls_ign
endif

if XP == XP_TICKSLOT
if SLOT_DLSERVICE == TICK_SLOT
                CAL     dls_tick
endif
endif

if XP == XP_CAL
;@ DatalogServiceTiming type=u8 formula=ign_advance category="Datalog" slot=datalog.servicetiming desc="The timing the service command locks it at (53h over the datalog): what a timing light should then see at the crank pulley. The check-engine lamp flashes quickly while it is locked."
dls_timing:             DB  058h                 ; 16 degrees BTDC
endif

if XP == XP_CODE
; ------------------------------------------------------------------ power-up: nothing on
dls_boot:       L       A, DP
                PUSHS   A
                MOV     DP, #DL_SVC
ifdef DLSVC_TEST
                MOVB    [DP], #001h            ; (a diagnostic build: injectors off from power-up, so the lamp flashes at once)
else
                MOVB    [DP], #000h
endif
                MOV     DP, #DL_SVCX
                MOVB    [DP], #000h
                POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ a 5xh command (datalog.asm's receive interrupt)
; In: A (byte) = the command, bank 6Fh (r1 is free while no channel list is being received), DP pushed.
; Leaves through dl_rx_send with the answer in A.
dl_rx_service:  STB     A, r1
                MOV     DP, #DL_SVC
                CMPB    A, #050h
                JNE     dls_c51
                MOV     DP, #DL_SVCX           ; clear the codes: in the main loop, where the stock code writes them too
                SB      [DP].1
                J       dls_ok
dls_c51:        CMPB    A, #051h
                JNE     dls_c52
                LB      A, [DP]
                ORB     A, #001h
                J       dls_store
dls_c52:        CMPB    A, #052h
                JNE     dls_c53
                LB      A, [DP]
                ANDB    A, #0feh
                J       dls_store
dls_c53:        CMPB    A, #053h
                JNE     dls_c54
                LB      A, [DP]
                ORB     A, #002h
                J       dls_store
dls_c54:        CMPB    A, #054h
                JNE     dls_c55
                LB      A, [DP]
                ANDB    A, #0fdh
                J       dls_store
dls_c55:        CMPB    A, #058h
                JGE     dls_gio
                CMPB    A, #055h
                JLT     dls_state
if defined(FEAT_MAPSWITCH) || defined(FEAT_DUALMAPS)
                CMPB    A, #055h               ; the switch decides
                JNE     dls_c56
                LB      A, [DP]
                ANDB    A, #0f3h
                J       dls_store
dls_c56:        CMPB    A, #056h               ; the first maps
                JNE     dls_c57
                LB      A, [DP]
                ANDB    A, #0f3h
                ORB     A, #004h
                J       dls_store
dls_c57:        LB      A, [DP]                ; 57h: the secondary maps
                ORB     A, #00ch
                J       dls_store
else
                J       dls_no                 ; no map switch built in
endif
; 58h-5Bh: GIO 1-4 (5Ch-5Dh: nothing)
dls_gio:        CMPB    A, #05ch
                JGE     dls_state
                SUBB    A, #058h               ; 0-3
                JEQ     dls_gio1
                CMPB    A, #001h
                JEQ     dls_gio2
                CMPB    A, #002h
                JEQ     dls_gio3
if defined(FEAT_GIO4)
                LB      A, #080h
                J       dls_giot
else
                J       dls_no
endif
dls_gio1:
if defined(FEAT_GIO1)
                LB      A, #010h
                J       dls_giot
else
                J       dls_no
endif
dls_gio2:
if defined(FEAT_GIO2)
                LB      A, #020h
                J       dls_giot
else
                J       dls_no
endif
dls_gio3:
if defined(FEAT_GIO3)
                LB      A, #040h
                J       dls_giot
else
                J       dls_no
endif
dls_giot:       STB     A, r0                  ; its bit (r0 is 0 in the command state: put back below; a byte
                XORB    A, [DP]                ; pushed here would leave the stack odd) - toggled
                STB     A, [DP]
                LB      A, r0
                MOVB    r0, #000h
                ANDB    A, [DP]                ; set now: the command is the answer
                JEQ     dls_gio_off
                LB      A, r1
                J       dl_rx_send
dls_gio_off:    CLRB    A
                J       dl_rx_send
dls_state:      CMPB    A, #05eh
                JNE     dls_c5f
                MOVB    [DP], #000h            ; 5Eh: everything back to normal
                MOV     DP, #DL_SVCX           ; (the cylinder test too)
                CAL     dls_cyl_none
                J       dls_ok
dls_c5f:        CMPB    A, #05fh
                JNE     dls_no
                LB      A, [DP]                ; 5Fh: the state
                J       dl_rx_send
dls_store:      STB     A, [DP]
dls_ok:         LB      A, r1
                J       dl_rx_send
dls_no:         LB      A, #07fh
                J       dl_rx_send

; ------------------------------------------------------------------ 63h-67h: the cylinder test (datalog.asm's receive interrupt)
; In: A (byte) = the command, bank 6Fh, DP pushed. 63h: none cut; 64h-67h: cylinder 1-4's injector kept shut, the one
; before back first (one at a time). Answer: the command.
dl_rx_cylcut:   STB     A, r1
                MOV     DP, #DL_SVCX
                CAL     dls_cyl_none           ; whichever was cut, back
                LB      A, r1
                CMPB    A, #064h
                JLT     dls_ok                 ; 63h: that is all
                JNE     dls_cyl_2
                SB      [DP].4                 ; 64h: cylinder 1 (P2.0)
                J       dls_ok
dls_cyl_2:      CMPB    A, #065h
                JNE     dls_cyl_3
                SB      [DP].7                 ; 65h: cylinder 2 (P2.3)
                J       dls_ok
dls_cyl_3:      CMPB    A, #066h
                JNE     dls_cyl_4
                SB      [DP].5                 ; 66h: cylinder 3 (P2.1)
                J       dls_ok
dls_cyl_4:      SB      [DP].6                 ; 67h: cylinder 4 (P2.2)
                J       dls_ok
; DP = DL_SVCX: no injector cut (a bit at a time: the tick and the main loop write this byte's other bits)
dls_cyl_none:   RB      [DP].4
                RB      [DP].5
                RB      [DP].6
                RB      [DP].7
                RT

; ------------------------------------------------------------------ the injector interrupt (NEED_INJCUT): the cut cylinder's injector shut
; In: A (byte) = the injectors about to open (a 0 bit opens one: P2.0-P2.3). The bank is page 1 here (the injector code's
; own), so off() reaches DL_SVCX. With none cut (the usual case) one compare and out. Only A and the flags; byte mode kept.
mod_injcut:     CMPB    off(DL_SVCX), #010h    ; bits 4-7 all clear: below 10h
                JLT     dls_injcut_ret
                JBR     off(DL_SVCX).4, dls_injcut_b1
                ORB     A, #001h
dls_injcut_b1:  JBR     off(DL_SVCX).5, dls_injcut_b2
                ORB     A, #002h
dls_injcut_b2:  JBR     off(DL_SVCX).6, dls_injcut_b3
                ORB     A, #004h
dls_injcut_b3:  JBR     off(DL_SVCX).7, dls_injcut_ret
                ORB     A, #008h
dls_injcut_ret: RT

; ------------------------------------------------------------------ every 16 ticks: the fuel cut and the lamp
; Tick context (the include site): only A is free; DP is kept here.
dls_tick:       L       A, DP
                PUSHS   A
                MOV     DP, #DL_SVC
                CLRB    A
                LB      A, [DP]
                ANDB    A, #003h
                JNE     dls_active
                MOV     DP, #DL_SVCX           ; a cylinder cut (the cylinder test): the lamp flashes, no fuel cut
                LB      A, [DP]
                ANDB    A, #0f0h
                JNE     dls_cylon
                MOV     DP, #SVC_FUELCUT            ; nothing on (the usual case, kept short): no service fuel cut...
                RB      [DP].1
                MOV     DP, #DL_SVCX           ; ...and the lamp handed back if it was taken
                MB      C, [DP].0
                JLT     dls_lamp_free
                SJ      dls_tick_ret
dls_active:     LB      A, [DP]
                ANDB    A, #001h               ; injectors off: the skeleton's fuel-cut request, bit 1 (lib.asm has bit 0)
                MOV     DP, #SVC_FUELCUT
                JEQ     dls_fuel_on
                SB      [DP].1
                SJ      dls_fuel_set
dls_fuel_on:    RB      [DP].1
                SJ      dls_fuel_set
dls_cylon:      MOV     DP, #SVC_FUELCUT
                RB      [DP].1
dls_fuel_set:
; the check-engine lamp (PC.3 on the P13) flashes while the injectors are off or the timing is locked: the output
; override masks (3DEh AND, 3DFh OR) take it from whatever else drives it
                MOV     DP, #DL_SVCX
                SB      [DP].0
                MOV     DP, #OUT_LAMP_MASK
                LB      A, [DP]
                ANDB    A, #(0ffh - OUT_LAMP)
                STB     A, [DP]
                INC     DP
                LB      A, SVC_TICK                ; lit while tick bit 6 is set: 131 ms on, 131 ms off
                ANDB    A, #040h
                JEQ     dls_lamp_dark
                LB      A, [DP]
                ORB     A, #OUT_LAMP
                SJ      dls_lamp_set
dls_lamp_dark:  LB      A, [DP]
                ANDB    A, #(0ffh - OUT_LAMP)
dls_lamp_set:   STB     A, [DP]
                SJ      dls_tick_ret
dls_lamp_free:  RB      [DP].0                 ; back to normal: the lamp handed back once (DP = DL_SVCX)
                MOV     DP, #OUT_LAMP_MASK
                LB      A, [DP]
                ORB     A, #OUT_LAMP
                STB     A, [DP]
                INC     DP
                LB      A, [DP]
                ANDB    A, #(0ffh - OUT_LAMP)
                STB     A, [DP]
                MOV     DP, #OUT_LAMP_COPY     ; its latch off: whatever drives it puts it back
                LB      A, [DP]
                ANDB    A, #(0ffh - OUT_LAMP)
                STB     A, [DP]
dls_tick_ret:   POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ the timing lock (main loop, after the final advance)
dls_ign:        L       A, DP
                PUSHS   A
                MOV     DP, #DL_SVC
                CLRB    A
                LB      A, [DP]
                ANDB    A, #002h
                JEQ     dls_ign_ret
                LCB     A, dls_timing
                STB     A, off(SVC_ADVF)         ; both advance bytes the spark timer is built from
                STB     A, off(SVC_ADVF + 1)
dls_ign_ret:    POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ clear the codes (main loop)
; The stock P13 keeps a code in three places, set together (110h-113h, 210h-213h, and 330h-333h with its sum and
; xor at 334h) and checks that every bit of the first is in the last - a bit it finds missing resets the ECU (BRK
; 4Fh). So all three are cleared, and the sum word with them (zero for all zeros); and the snapshot taken with the
; first code (338h-35Dh, its sum and xor at 362h), as the stock clear does.
dls_main:       L       A, DP
                PUSHS   A
                MOV     DP, #DL_SVCX
                CLRB    A
                LB      A, [DP]
                ANDB    A, #002h
                JEQ     dls_main_ret
                RB      [DP].1
if defined(FEAT_STOCK_DTC)
                CLR     A
                MOV     DP, #00110h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOV     DP, #00210h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOV     DP, #00330h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]                ; 334h: the sum and xor of four zero bytes
                MOV     DP, #00338h            ; the snapshot, 338h-35Dh
dls_main_snap:  ST      A, [DP]
                INC     DP
                INC     DP
                CMP     DP, #0035eh
                JLT     dls_main_snap
                MOV     DP, #00362h
                ST      A, [DP]                ; and its sum and xor
endif
dls_main_ret:   POPS    A
                MOV     DP, A
                RT
endif

endif
