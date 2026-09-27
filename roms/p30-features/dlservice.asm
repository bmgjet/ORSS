; ==================================================================================================
; dlservice.asm - datalogging: service commands
;> feature: FEAT_DLSERVICE
;> name: Datalogging: service commands
;> category: Diagnostics
;> conflicts: FEAT_STOCK_SERIAL
;> ram: 1F7h, 2FFh
;> pages: datalog
;> about: Over the datalog cable (Datalogging > Codes and service…): clear the trouble codes, injectors
;>        off, the timing locked for a timing light, the maps picked and the GIO outputs forced on. The
;>        check-engine lamp flashes quickly while the injectors are off or the timing is locked.
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
;   5Eh  all of the above back to normal         5Fh  the state: the DL_SVC byte below
; While the injectors are off or the timing is locked the check-engine lamp flashes quickly (about four
; times a second), whatever else drives it, so a service mode is never left on unnoticed.
; ==================================================================================================
ifdef FEAT_DLSERVICE

if XP == XP_DEFS
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
; two bytes the skeleton and stock P30 never touch (not module RAM: that is full with every module built in)
DL_SVC              EQU     002ffh              ; bits: 0 injectors off, 1 timing locked, 2 map chosen here, 3 that map is
                                                ;   the secondary one, 4-7 GIO 1-4 forced on. Written by the receive interrupt only.
DL_SVCX             EQU     001f7h              ; bits: 0 the lamp is taken for the flashing (tick), 1 clear the codes (set by the
                                                ;   receive interrupt, cleared by the main loop). Single-instruction bit set and
                                                ;   clear only, so the three never undo each other.
DLSVC_SLOT          EQU     3                   ; the tick slot it runs on (tick mod 16: about 30 times a second)
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

if XP == XP_TICK
                LB      A, 0feh
                ANDB    A, #00fh
                CMPB    A, #DLSVC_SLOT
                JNE     dls_tick_skip
                CAL     dls_tick
dls_tick_skip:
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
                MOVB    [DP], #000h
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

; ------------------------------------------------------------------ every 16 ticks: the fuel cut and the lamp
; Tick context (the include site): only A is free; DP is kept here.
dls_tick:       L       A, DP
                PUSHS   A
                MOV     DP, #DL_SVC
                CLRB    A
                LB      A, [DP]
                ANDB    A, #003h
                JNE     dls_active
                MOV     DP, #001f0h            ; nothing on (the usual case, kept short): no service fuel cut...
                RB      [DP].1
                MOV     DP, #DL_SVCX           ; ...and the lamp handed back if it was taken
                MB      C, [DP].0
                JLT     dls_lamp_free
                SJ      dls_tick_ret
dls_active:     LB      A, [DP]
                ANDB    A, #001h               ; injectors off: the skeleton's fuel-cut request, bit 1 (lib.asm has bit 0)
                MOV     DP, #001f0h
                JEQ     dls_fuel_on
                SB      [DP].1
                SJ      dls_fuel_set
dls_fuel_on:    RB      [DP].1
dls_fuel_set:
; the check-engine lamp (P1.4) flashes while the injectors are off or the timing is locked: the output
; override masks (3DEh AND, 3DFh OR) take it from whatever else drives it
                MOV     DP, #DL_SVCX
                SB      [DP].0
                MOV     DP, #003deh
                LB      A, [DP]
                ANDB    A, #0efh
                STB     A, [DP]
                INC     DP
                LB      A, 0feh                ; lit while tick bit 6 is set: 131 ms on, 131 ms off
                ANDB    A, #040h
                JEQ     dls_lamp_dark
                LB      A, [DP]
                ORB     A, #010h
                SJ      dls_lamp_set
dls_lamp_dark:  LB      A, [DP]
                ANDB    A, #0efh
dls_lamp_set:   STB     A, [DP]
                SJ      dls_tick_ret
dls_lamp_free:  RB      [DP].0                 ; back to normal: the lamp handed back once (DP = DL_SVCX)
                MOV     DP, #003deh
                LB      A, [DP]
                ORB     A, #010h
                STB     A, [DP]
                INC     DP
                LB      A, [DP]
                ANDB    A, #0efh
                STB     A, [DP]
                MOV     DP, #00022h            ; its latch off: whatever drives it puts it back
                LB      A, [DP]
                ANDB    A, #0efh
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
                STB     A, off(00246h)         ; both advance bytes the spark timer is built from
                STB     A, off(00247h)
dls_ign_ret:    POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ clear the codes (main loop)
; The stock code keeps a code in three places, set together (112h-115h, 212h-215h, and 31Ah-31Dh with its
; sum and xor at 31Eh) and checks that every bit of the first is in the last - a bit it finds missing
; resets the ECU (BRK 43h). So all three are cleared, and the sum word with them (zero for all zeros).
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
                MOV     DP, #00112h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOV     DP, #00212h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOV     DP, #0031ah
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]                ; 31Eh: the sum and xor of four zero bytes
endif
dls_main_ret:   POPS    A
                MOV     DP, A
                RT
endif

endif
