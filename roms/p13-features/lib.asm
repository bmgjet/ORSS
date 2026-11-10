; ==================================================================================================
; lib.asm - routines the feature modules share. Built only when a module asks for them (NEED_MODLIB),
; so a skeleton with no such module carries none of it.
;
; The limiter modules (rev limits, launch, full-throttle shift, boost cut...) run from the 2.048 ms tick,
; each on its own slot of 16 (so every one runs about 30 times a second whatever the rpm - the main loop
; drops to a few passes a second at high rpm, far too slow for a limiter). The tick is an interrupt that
; does not let the crank interrupt in, so a module does little per call: read, compare, set a bit.
;
; Tick context: a module's tick routine starts with MOD_ENTER and leaves through "J mod_tick_exit". In
; between it runs in bank 3Fh (r0-r7 = 1F8h-1FFh are scratch, never kept between calls), off() reaches
; 100h-1FFh, and DP, X1 and X2 are free.
;
; Byte and word mode: the chip decodes the byte and word forms of most accumulator instructions (SLLB/SLL,
; CMPB/CMP A,#, ANDB/AND, STB/ST A,rN...) from the same opcode and tells them apart by its DD flag, which only
; the plain loads set (LB/CLRB: byte, L/CLR: word) - LC and LCB leave it alone. So every stretch of byte work
; starts with CLRB A (or an LB) and every stretch of word work with an L or CLR, even where the flag would
; happen to be right: an interrupt can arrive in any mode.
;
; Cut requests: every limiter has its own bit in two words, fuel (1F2h) and spark (1F4h). They are folded
; into the skeleton's own requests (1F0h bit 0 = fuel cut, 0FCh bit 0 = spark cut) each time one changes,
; so two limiters never undo each other.
;
; Trims (NEED_FUELTRIM, NEED_IGNTRIM): every module that corrects fuel or timing keeps its own trim word in
; module RAM and hands changes to mod_fueltrim / mod_igntrim, which keep the running total. Fuel is applied in
; the fuel hook as a multiplier on the final pulse width; timing through the skeleton's advance (2FCh) and
; retard (2FDh) requests. So any number of trims add up, and a module that stops trimming takes only its own
; share back out.
;
; Module RAM: MOD_RAM_BASE to MOD_RAM_END (features.inc: 31Ah-351h, clear of the stack, unless the stock
; trouble-code function is built in). P13: 408h-43Fh, and lib.asm has its first 8 bytes (the P30's has 10, the last
; two kept empty for its stock self-test) - each module takes what it needs from MODRAM_NEXT in its XP_DEFS part
; (see README.md).
; Bank 7Eh (3F0h-3F7h) is scratch for the fuel hook.
;> library
; ==================================================================================================
ifdef NEED_MODLIB

if XP == XP_DEFS
ifndef NEED_SPARKCUT
define NEED_SPARKCUT
endif
MOD_OUTSTATE    EQU     SVC_MODLIB          ; bits: 0 IAB, 1 rpm switch, 2 warning lamp, 3 tach, 4-6 GIO 1-3, 7 spare
MOD_FUELWANT    EQU     SVC_MODLIB + 1          ; word: a bit per limiter that wants fuel cut
MOD_SPARKWANT   EQU     SVC_MODLIB + 3          ; word: a bit per limiter that wants spark cut
MOD_FLAGS       EQU     SVC_MODLIB + 5          ; bits: 0 anti-start locked, 1 anti-start checked, 3 smart alternator taken, 4 A/C cut taken, 5 anti-stall taken, 6 tach holds its pin; 2, 7 spare
MOD_PAGE0       EQU     000fdh          ; bits: 0 secondary maps on, 1 decel pops on, 2 anti-stall on, 3 rolling idle on
MOD_SPARE       EQU     SVC_MODLIB + 6          ; (the datalog service commands' flags, dlservice.asm)
MOD_FUELSUM     EQU     MOD_RAM_BASE    ; word: the fuel trims added up, 1/256ths
MOD_FUELMUL     EQU     MOD_RAM_BASE + 2 ; word: the multiplier the fuel hook applies, 8000h = 1.0
MOD_IGNSUM      EQU     MOD_RAM_BASE + 4 ; word: the timing trims added up, 0.25 degree steps, + = advance
MOD_PWMSTEP     EQU     MOD_RAM_BASE + 6 ; P4.3 PWM: the step of the 25-step cycle...
MOD_PWMDUTY     EQU     MOD_RAM_BASE + 7 ; ...and how many of them are on (0-25)
; MOD_GEAR (the gear, 0 when not known; FEAT_GEAR; page 2, so main-loop code reads it with off()) is in features.inc
if defined(NEED_REVCAP)
MOD_REVCAP      EQU     MODRAM_NEXT     ; the lowest rev limit a module holds now, as its crank period / 4 (0 none):
MOD_REVNEXT     EQU     MODRAM_NEXT + 1 ; the crank interrupt cuts the fuel at once past it (mod_revcap); and the next
undef MODRAM_NEXT
define MODRAM_NEXT (MOD_REVCAP + 2)
endif
if defined(NEED_SWPWM)
MOD_SWSTEP      EQU     MODRAM_NEXT     ; software PWM: the step of the 25-step cycle...
MOD_SWDUTY      EQU     MODRAM_NEXT + 1 ; ...how many of them are on (0-25)...
MOD_SWOUT       EQU     MODRAM_NEXT + 2 ; ...and the output (as mod_output)
undef MODRAM_NEXT
define MODRAM_NEXT (MOD_SWSTEP + 3)
endif
if MODRAM_NEXT > MOD_RAM_END
                error   "module RAM is full: leave a module out"
endif
if defined(FEAT_STOCK_DTC)
                warning "with the stock trouble codes (FEAT_STOCK_DTC) built in, module RAM is 3F8h-42Fh, in the space the stack uses: deep interrupt nesting at high rpm can reach it. Leave FEAT_STOCK_DTC out to have module RAM where the stack never is."
endif
if defined(NEED_FUELTRIM) || defined(NEED_IGNTRIM) || defined(NEED_PWM43)
endif
; a bit in the want words for each limiter
MB_REVLIMIT     EQU     00001h
MB_LAUNCH       EQU     00002h
MB_FTS          EQU     00004h
MB_BURNOUT      EQU     00008h
MB_BOOSTCUT     EQU     00010h
MB_ECTPRO       EQU     00020h
MB_ANTISTART    EQU     00040h
MB_SPEEDLIMIT   EQU     00080h
MB_CEILING      EQU     00100h
MB_LEANPRO      EQU     00200h
MB_TRACTION     EQU     00400h
MB_GEARLIMIT    EQU     00800h
MB_WATERMARK    EQU     01000h
MB_REMOTE       EQU     02000h          ; remote.asm: its rev / speed limit, and the anti-start lock
MB_POPCORN      EQU     04000h          ; remote.asm: popcorn mode's spark cut
MB_SENSORPRO    EQU     08000h          ; sensorpro.asm: a sender's reading past its level
; the tick slot each module runs on (tick mod 16): features.inc hands them out when the ROM is built, the heaviest
; modules a slot of their own
endif

if XP == XP_TICK
                LB      A, SVC_TICK                ; each tick cycle (slot 0) the rev cap becomes what the modules
                ANDB    A, #00fh               ; asked for in the cycle before
                JNE     mod_revcap_roll_skip
if defined(NEED_REVCAP)
                CAL     mod_revcap_roll
endif
mod_revcap_roll_skip:
if defined(NEED_PWM43)
                CAL     mod_pwm_tick           ; every tick: the P4.3 PWM
endif
if defined(NEED_SWPWM)
                CAL     mod_swpwm_tick         ; every tick: the software PWM on a free output
endif
endif

if XP == XP_FUEL
if defined(NEED_FUELTRIM)
                CAL     mod_fuel_apply         ; the fuel trims, on the final pulse width
endif
endif

if XP == XP_CODE
; ------------------------------------------------------------------ power-up (the skeleton calls it before XP_BOOT)
mod_boot_init:  L       A, DP                  ; nothing wanted, nothing trimmed
                PUSHS   A
                MOV     DP, #MOD_OUTSTATE
mod_boot_clear: MOVB    [DP], #000h            ; 1F1h-1F7h
                INC     DP
                CMP     DP, #SVC_MODLIB + 7
                JNE     mod_boot_clear
                MOV     DP, #MOD_FUELSUM
mod_boot_clear2:
                MOVB    [DP], #000h            ; module RAM
                INC     DP
                CMP     DP, #MOD_RAM_END
                JNE     mod_boot_clear2
                MOV     DP, #MOD_FUELMUL
                MOV     [DP], #08000h          ; x 1.0
                MOV     DP, #SVC_IGNADV
                MOVB    [DP], #000h            ; no advance
                POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ tick routine exit
; A tick routine begins:  PUSHS LRB / MOV LRB, #0003fh / L A, DP / PUSHS A / L A, X1 / PUSHS A / L A, X2 / PUSHS A
; and ends with J mod_tick_exit, which puts all of that back and returns to the tick.
mod_tick_exit:  POPS    A
                MOV     X2, A
                POPS    A
                MOV     X1, A
                POPS    A
                MOV     DP, A
                POPS    LRB
                RT

; ------------------------------------------------------------------ switch inputs
; In: X1 = two calibration bytes: the one-hot input select, then invert (0 or 1).
;   Select: 01h power steering (B8), 02h service check connector (D4), 04h start (B9), 08h VTEC pressure
;   (D6), 10h A/C request (B5), 20h brake (D2), 40h park/neutral (B7), 80h always on, 00h never; with the
;   serial inputs (FEAT_DLSERIALIN) C0h-C7h serial input 1-8, on when its value is not 0.
; Out: A = 1 (Z clear) when the input is on after the invert, 0 (Z set) when it is off. Uses DP, r7.
mod_switch:     CLRB    A                      ; byte mode
                LCB     A, 00000h[X1]
if defined(FEAT_DLSERIALIN)
                STB     A, r7
                ANDB    A, #0f8h
                CMPB    A, #0c0h
                JNE     mod_switch_pins
                LB      A, r7                  ; C0h-C7h: a serial input
                ANDB    A, #007h
                ADDB    A, #004h               ; (serin_read's 4-11)
                CAL     serin_read
                RC
                CMPB    A, #000h
                JEQ     mod_switch_got         ; 0: off
                SC
                SJ      mod_switch_got
mod_switch_pins:
                LB      A, r7
endif
; P13: the A/C switch is the 82C55's port A bit 0 (8000h; the stock copy at 224h), the start signal P4.5 and the
; power steering switch P4.6, low = pressure (the stock copies 214h.0, 22Ch.2). Read at the pins, not the copies: the
; main loop refreshes those once a pass, and a module would see a new throttle with an old switch meanwhile. The service
; check connector is port A bit 2 (high: jumped - stock blinks the codes then), park/neutral port A bit 5 (low: in P or
; N; A/T cars only - a manual's reads off), the VTEC pressure switch bit 4 of the input port at 1000h (low: pressure).
; The brake switch is not traced on the P13 yet: it reads off.
                SLLB    A
                JLT     mod_switch_got         ; 80h: always on
                SLLB    A
                JGE     mod_switch_5
                MOV     DP, #08000h
                MB      C, [DP].5              ; park/neutral: low in P or N
                XORB    PSWH, #080h            ; (C is PSWH.7)
                SJ      mod_switch_got
mod_switch_5:   SLLB    A
                JGE     mod_switch_4
                RC                             ; brake (not traced on the P13)
                SJ      mod_switch_got
mod_switch_4:   SLLB    A
                JGE     mod_switch_3
                MOV     DP, #08000h
                MB      C, [DP].0              ; A/C request (port A; reading it changes nothing)
                SJ      mod_switch_got
mod_switch_3:   SLLB    A
                JGE     mod_switch_2
                MOV     DP, #01000h
                MB      C, [DP].4              ; VTEC pressure switch: low with pressure
                XORB    PSWH, #080h
                SJ      mod_switch_got
mod_switch_2:   SLLB    A
                JGE     mod_switch_1
                MB      C, P4.5                ; start signal
                SJ      mod_switch_got
mod_switch_1:   SLLB    A
                JGE     mod_switch_0
                MOV     DP, #08000h
                MB      C, [DP].2              ; service check connector: high when jumped
                SJ      mod_switch_got
mod_switch_0:   SLLB    A
                JGE     mod_switch_got         ; 00h: never (C is clear)
                MB      C, P4.6                ; power steering pressure switch: low = pressure
                XORB    PSWH, #080h            ; (C is PSWH.7)
mod_switch_got: CLRB    A                      ; byte mode (still, after the shifts: say so again)
                MB      ACC.0, C
                STB     A, r7
                LCB     A, 00001h[X1]          ; invert
                ANDB    A, #001h
                XORB    A, r7
                CMPB    A, #000h               ; Z: off
                RT

; ------------------------------------------------------------------ the map-switch input
; mod_switch for the modules that switch maps (mapswitch.asm, dualmaps.asm): the datalog service commands
; (dlservice.asm) can pick the maps instead of the switch. The same in and out as mod_switch.
mod_mapinput:
if defined(FEAT_DLSERVICE)
                MOV     DP, #DL_SVC
                CLRB    A
                LB      A, [DP]
                ANDB    A, #004h               ; chosen over the datalog?
                JEQ     mod_switch             ; no: the switch
                LB      A, [DP]
                ANDB    A, #008h               ; the secondary maps (1) or the first (0)
                JEQ     mod_mapin_got
                LB      A, #001h
mod_mapin_got:  CMPB    A, #000h               ; Z: off
                RT
else
                J       mod_switch
endif

; ------------------------------------------------------------------ limiter with hysteresis
; In: A (word) = the module's bit (MB_...); C = the module's own condition holds (input on, speed low...).
;     X1 = its calibration block:  +0 enable (byte)   +1 cut: 0 fuel, 1 ignition, 2 both
;                                  +2 cut at (crank period word: at or below it = at or above the rpm)
;                                  +4 back in at (crank period word, above the cut rpm's: below that rpm)
; Cuts once the rpm reaches the cut point, and lets it back in below the resume point; off at once when
; the condition goes away or the module is disabled. Uses r0-r7, DP. The cut point is checked against the period one
; reading ahead while the rpm rises (mod_period_ahead), so a fast-rising engine is cut at the limit, not past it.
mod_limit:      ST      A, er0                 ; the module's bit
                CLRB    A
                MB      ACC.0, C
                STB     A, r2                  ; its condition
                LCB     A, 00000h[X1]          ; enabled?
                ANDB    A, r2
                JNE     mod_limit_held
                J       mod_limit_off
mod_limit_held:
if defined(NEED_REVCAP)
                LC      A, 00002h[X1]          ; held: its cut point is a hard limit for the crank interrupt too
if defined(FEAT_REMOTE)
                CAL     rc_limit_set           ; (launch control's moved over the cable: remote.asm)
endif
                CAL     mod_revcap
endif
                L       A, off(MOD_FUELWANT)   ; cutting already?
                OR      A, off(MOD_SPARKWANT)
                AND     A, er0
                JNE     mod_limit_cutting
                LC      A, 00002h[X1]          ; not yet: cut once the period (looking ahead) is down to the cut point
if defined(FEAT_REMOTE)
                CAL     rc_limit_set
endif
                ST      A, er1
                CAL     mod_period_ahead
                CMP     A, er1
                JGT     mod_limit_ret
                SJ      mod_limit_cut
mod_limit_cutting:
                LC      A, 00004h[X1]          ; cutting: back in once the period is past the resume point
if defined(FEAT_REMOTE)
                CAL     rc_limit_reset
endif
                CMP     ENG_RPMP, A
                JGT     mod_limit_release
mod_limit_cut:  L       A, er0                 ; word mode
                ST      A, er1                 ; fuel
                ST      A, er2                 ; spark
                CLRB    A                      ; byte mode for the cut type
                LCB     A, 00001h[X1]
if defined(FEAT_REMOTE)
                CAL     rc_cut_type            ; (fuel or ignition chosen over the cable: remote.asm)
endif
                CMPB    A, #000h
                JNE     mod_limit_nofuelonly
                CLR     A                      ; word mode
                ST      A, er2                 ; 0: fuel only
                SJ      mod_limit_set
mod_limit_nofuelonly:
                CMPB    A, #001h
                JNE     mod_limit_set
                CLR     A                      ; word mode
                ST      A, er1                 ; 1: ignition only
mod_limit_set:  L       A, er0                 ; this limiter's requests replaced, not added to: its cut type can
                XOR     A, #0ffffh             ; change while it cuts (over the cable), and the old one must go
                ST      A, er3
                L       A, off(MOD_FUELWANT)
                AND     A, er3
                OR      A, er1
                ST      A, off(MOD_FUELWANT)
                L       A, off(MOD_SPARKWANT)
                AND     A, er3
                OR      A, er2
                ST      A, off(MOD_SPARKWANT)
                J       mod_fold
mod_limit_release:
                L       A, off(MOD_FUELWANT)   ; not cutting: nothing to let go (the usual case, kept short)
                OR      A, off(MOD_SPARKWANT)
                AND     A, er0
                JEQ     mod_limit_ret
                L       A, er0
                XOR     A, #0ffffh
                ST      A, er0
                L       A, off(MOD_FUELWANT)
                AND     A, er0
                ST      A, off(MOD_FUELWANT)
                L       A, off(MOD_SPARKWANT)
                AND     A, er0
                ST      A, off(MOD_SPARKWANT)
; fold the want words into the skeleton's requests: 1F0h bit 0 (fuel cut), 0FCh bit 0 (spark cut)
mod_fold:       L       A, off(MOD_FUELWANT)
                JEQ     mod_fold_fuel_off
                SB      off(SVC_FUELCUT).0
                SJ      mod_fold_spark
mod_fold_fuel_off:
                RB      off(SVC_FUELCUT).0
mod_fold_spark:
if defined(FEAT_IGNCUTMOD)
                RT                             ; igncutmod.asm drives 0FCh bit 0 itself, every tick
endif
                L       A, off(MOD_SPARKWANT)
                JEQ     mod_fold_spark_off
                LB      A, 0fch
                ORB     A, #001h
                STB     A, 0fch
                RT
mod_fold_spark_off:
                LB      A, 0fch
                ANDB    A, #0feh
                STB     A, 0fch
mod_limit_ret:  RT

; not held (off, or its condition gone): its cap goes at once, rather than at the end of the tick cycle
mod_limit_off:
if defined(NEED_REVCAP)
                LC      A, 00002h[X1]
if defined(FEAT_REMOTE)
                CAL     rc_limit_set
endif
                CAL     mod_revcap_drop
endif
                J       mod_limit_release

if defined(NEED_REVCAP)
; ------------------------------------------------------------------ the rev cap
; A rev limit a module holds now (In: A, word, its cut point as a crank period). The skeleton's crank interrupt looks
; at the cap on every reading, a step ahead (as mod_period_ahead), and cuts the fuel at once if the engine is past it
; by about 1.6 % - so however fast it climbs, it is never far over: the module's own cut, fuel or spark, every 33 ms,
; normally gets there first. The cap is the lowest rpm held in this tick cycle or the last. Uses DP, er2 (r4-r5).
mod_revcap:     CAL     mod_revcap_byte
                MOV     DP, #MOD_REVNEXT
                CMPB    A, [DP]
                JLE     mod_revcap_now         ; (a lower rpm is already held: its period is bigger)
                STB     A, [DP]
mod_revcap_now: DEC     DP                     ; MOD_REVCAP
                LB      A, r4
                CMPB    A, [DP]
                JLE     mod_revcap_ret
                STB     A, [DP]
mod_revcap_ret: RT
; Its limit let go: the cap falls back to the others' (this cycle's so far), if it was this one. Same In, Uses.
mod_revcap_drop:
                CAL     mod_revcap_byte
                MOV     DP, #MOD_REVCAP
                CMPB    A, [DP]
                JNE     mod_revcap_ret
                INC     DP
                LB      A, [DP]
                DEC     DP
                STB     A, [DP]
                RT
; A (word, a crank period) as the cap's byte: / 4, held to 1-FFh. Out: A (byte) and r4.
mod_revcap_byte:
                L       A, ACC                 ; word mode (an LC after byte work leaves it in byte mode)
                SRL     A
                SRL     A
                CMP     A, #000ffh
                JLE     mod_revcap_b1
                L       A, #000ffh
mod_revcap_b1:  CMP     A, #00000h
                JNE     mod_revcap_b2
                L       A, #00001h
mod_revcap_b2:  ST      A, er2
                LB      A, r4                  ; byte mode
                RT
; Slot 0: the cap becomes the cycle's, and the next cycle starts empty.
mod_revcap_roll:
                L       A, DP
                PUSHS   A
                MOV     DP, #MOD_REVNEXT
                LB      A, [DP]
                MOVB    [DP], #000h
                DEC     DP
                STB     A, [DP]
                POPS    A
                MOV     DP, A
                RT

endif

; ------------------------------------------------------------------ the crank period one reading ahead
; 0ACh only changes every few revolutions, and a module's tick looks at it every 33 ms: a limit checked against it
; alone is reached a reading or two after the engine got there. While the rpm rises this gives the newest period less
; the last change (36Ch, the reading before, - 0ACh), the period the next reading will about have - the change taken as
; 1/4 of the period at most (starting, the rpm doubles from one reading to the next); otherwise 0ACh itself.
; Out: A (word). Uses DP, er2 (r4-r5). Tick context.
mod_period_ahead:
                MOV     DP, #ENG_RPMPREV       ; the reading before 0ACh's
                L       A, [DP]
                SUB     A, ENG_RPMP                ; before - newest: the change while the rpm rises
                JLT     mod_ahead_now
                ST      A, er2
                L       A, ENG_RPMP
                SRL     A
                SRL     A
                CMP     A, er2
                JGE     mod_ahead_step
                ST      A, er2                 ; (held to 1/4)
mod_ahead_step: L       A, er2                 ; one and a half readings ahead (0ACh is an average of several)
                SRL     A
                ADD     A, er2
                ST      A, er2
                L       A, ENG_RPMP
                SUB     A, er2
                JGE     mod_ahead_ret
                CLR     A
mod_ahead_ret:  RT
mod_ahead_now:  L       A, ENG_RPMP
                RT

; ------------------------------------------------------------------ cut or not, as the module decides
; In: A (word) = the module's bit; C = cut now; X1 = its block (+1 = cut: 0 fuel, 1 ignition, 2 both).
mod_cut:        ST      A, er0                 ; (a store leaves C alone)
                JGE     mod_cut_release
                J       mod_limit_cut
mod_cut_release:
                J       mod_limit_release

; ------------------------------------------------------------------ set or clear a want bit directly
; In: A (word) = the module's bit; C = cut (both fuel and spark) or not. Uses r0-r1.
mod_cutboth:    ST      A, er0                 ; (a store leaves C alone)
                JLT     mod_cutboth_on
                L       A, er0                 ; word mode
                XOR     A, #0ffffh
                ST      A, er0
                L       A, off(MOD_FUELWANT)
                AND     A, er0
                ST      A, off(MOD_FUELWANT)
                L       A, off(MOD_SPARKWANT)
                AND     A, er0
                ST      A, off(MOD_SPARKWANT)
                J       mod_fold
mod_cutboth_on: L       A, off(MOD_FUELWANT)
                OR      A, er0
                ST      A, off(MOD_FUELWANT)
                L       A, off(MOD_SPARKWANT)
                OR      A, er0
                ST      A, off(MOD_SPARKWANT)
                J       mod_fold

; ------------------------------------------------------------------ fuel trims
; In: A (word) = the module's new trim, 1/256ths of the fuel (signed); DP = its trim word in module RAM.
; The total, held to -255..+255, becomes the multiplier the fuel hook applies (8000h + total x 128).
; Tick context (uses r0-r3).
mod_fueltrim:   ST      A, er0                 ; new
                L       A, [DP]                ; old
                ST      A, er1
                L       A, er0
                ST      A, [DP]
                SUB     A, er1                 ; the change...
                MOV     DP, #MOD_FUELSUM
                ADD     A, [DP]                ; ...into the total
                ST      A, [DP]
                CAL     mod_clamp255
                SLL     A
                SLL     A
                SLL     A
                SLL     A
                SLL     A
                SLL     A
                SLL     A
                ADD     A, #08000h
                MOV     DP, #MOD_FUELMUL
                ST      A, [DP]
                RT

; A (word, signed) held to -255..+255.
mod_clamp255:   MB      C, ACCH.7
                JLT     mod_clamp_neg
                CMP     A, #000ffh
                JLE     mod_clamp_ret
                L       A, #000ffh
                RT
mod_clamp_neg:  CMP     A, #0ff01h
                JGE     mod_clamp_ret
                L       A, #0ff01h
mod_clamp_ret:  RT

; ------------------------------------------------------------------ timing trims
; In: A (word) = the module's new trim, 0.25 degree steps, + = advance (signed); DP = its trim word.
; The total, held to -255..+255, goes to the skeleton's advance (2FCh) or retard (2FDh) request.
; Tick context (uses r0-r3).
mod_igntrim:    ST      A, er0
                L       A, [DP]
                ST      A, er1
                L       A, er0
                ST      A, [DP]
                SUB     A, er1
                MOV     DP, #MOD_IGNSUM
                ADD     A, [DP]
                ST      A, [DP]
                CAL     mod_clamp255
                MB      C, ACCH.7
                JLT     mod_igntrim_retard
                ST      A, er0                 ; advance
                MOV     DP, #SVC_IGNRET
                MOVB    [DP], #000h
                DEC     DP
                LB      A, r0
                STB     A, [DP]
                RT
mod_igntrim_retard:
                XOR     A, #0ffffh             ; retard = -total
                ADD     A, #00001h
                ST      A, er0
                MOV     DP, #SVC_IGNADV
                MOVB    [DP], #000h
                INC     DP
                LB      A, r0
                STB     A, [DP]
                RT

; ------------------------------------------------------------------ the fuel hook: trims on the pulse width
; Crank interrupt, right after the final pulse width is stored in 146h (before dead time).
mod_fuel_apply: PUSHS   LRB
                MOV     LRB, #SVC_BANKF           ; bank 3F0h: scratch, nothing of the caller's
                L       A, DP
                PUSHS   A
                MOV     DP, #MOD_FUELMUL
                L       A, [DP]
                CMP     A, #08000h
                JEQ     mod_fuel_done          ; x 1.0: nothing to do
                ST      A, er0
                MOV     DP, #SVC_FUELPW
                L       A, [DP]
                MUL                            ; er1:A = pulse x multiplier
                SLL     A                      ; / 8000h: one bit left, keep the high word
                ROL     er1
                JLT     mod_fuel_max           ; past 16 bits
                L       A, er1
                SJ      mod_fuel_store
mod_fuel_max:   L       A, #0ffffh
mod_fuel_store: ST      A, [DP]
mod_fuel_done:  POPS    A
                MOV     DP, A
                POPS    LRB
                RT

; ------------------------------------------------------------------ P4.3 PWM (boost solenoid)
; Every tick: a 25-step cycle (51 ms, 19.5 Hz), on for MOD_PWMDUTY steps. P4.3 is a plain output on the
; skeleton (the stock A/T lock-up output), low when off.
mod_pwm_tick:   L       A, DP
                PUSHS   A
                MOV     DP, #MOD_PWMSTEP
                LB      A, [DP]
                ADDB    A, #001h
                CMPB    A, #019h
                JLT     mod_pwm_step
                CLRB    A
mod_pwm_step:   STB     A, [DP]
                INC     DP                     ; the duty, right after the step
                CMPB    A, [DP]                ; step - duty borrows (C) while the step is below it: on
                MOV     DP, #SVC_OVR           ; P13: port B's spare output (PB.6), taken...
                RB      [DP].6
                INC     DP
                MB      [DP].6, C              ; ...at the PWM's level, and out to the port now
                CAL     skel_ports_now
                POPS    A
                MOV     DP, A
                RT

; ------------------------------------------------------------------ analog inputs
; In: A (byte) = the input: 0 O2, 1 ELD, 2 EGR lift (P5.3), 3 the TCS pin (P5.5), 4-11 serial inputs 1-8 (FEAT_DLSERIALIN).
; Out: A (byte) = its level, 0-255 for 0-5 V (a serial input: its value). Uses DP (a serial input: and r7).
mod_analog:
if defined(FEAT_DLSERIALIN)
                CMPB    A, #004h
                JLT     mod_analog_pin
                J       serin_read             ; dlserialin.asm
mod_analog_pin:
endif
; P13: the O2 sensor and the ELD from the analog multiplexer's scan (3D0h, 3D8h), EGR lift and the TCS pin straight
; from the A/D (ADCR3H, ADCR5H).
                CMPB    A, #001h
                JLT     mod_analog_o2
                JEQ     mod_analog_eld
                MOV     DP, #0006fh            ; ADCR3H: EGR lift (P5.3)
                CMPB    A, #002h
                JEQ     mod_analog_read
                MOV     DP, #00073h            ; ADCR5H: TCS (P5.5)
                SJ      mod_analog_read
mod_analog_eld: MOV     DP, #003d8h
                SJ      mod_analog_read
mod_analog_o2:  MOV     DP, #003d0h
mod_analog_read:
                LB      A, [DP]
                RT

; In: X1 = three calibration bytes: the input (as mod_analog), then the AFR (x 10) the sensor gives at 0 V
; and at 5 V. Out: A (byte) = the AFR x 10. Uses DP, r0-r3.
mod_afr:        CLRB    A
                LCB     A, 00000h[X1]
                CAL     mod_analog
                STB     A, r2                  ; the level
                LCB     A, 00001h[X1]
                STB     A, r3                  ; AFR at 0 V
                LCB     A, 00002h[X1]
                SUBB    A, r3                  ; the span (a sensor that falls with AFR has a negative one: taken as zero)
                JGE     mod_afr_span
                CLRB    A
mod_afr_span:   STB     A, r0
                LB      A, r2
                MULB                           ; span x level
                L       A, ACC
                ST      A, er0
                LB      A, r1                  ; / 256: the high byte
                ADDB    A, r3
                RT

; ------------------------------------------------------------------ rpm as a byte
; Out: A (byte) = rpm / 32 (255 at 8160 rpm and above). Uses er0-er2.
mod_rpmbyte:    L       A, ENG_RPMP                ; crank period, rpm = 1875000 / period
                CMP     A, #000e6h
                JLT     mod_rpmbyte_max
                ST      A, er2
                CLR     A
                ST      A, er0
                L       A, #0e4e2h             ; 1875000 / 32
                DIV
                ST      A, er0
                LB      A, r0
                RT
mod_rpmbyte_max:
                LB      A, #0ffh
                RT

; ------------------------------------------------------------------ table lookup
; In: A (byte) = the input 0-255; X1 = nine table bytes, the values at inputs 0, 32, 64 ... 256.
; Out: A (byte) = the straight line between the two points around the input. Uses r0-r7, X1.
mod_lookup9:    CMPB    A, #0ffh               ; the top of the input is the last point
                JNE     mod_lookup9_in
                LCB     A, 00008h[X1]
                RT
mod_lookup9_in: STB     A, r4
                ANDB    A, #01fh
                STB     A, r5                  ; how far into the segment (0-31)
                LB      A, r4
                SRLB    A
                SRLB    A
                SRLB    A
                SRLB    A
                SRLB    A
                STB     A, r6                  ; the segment (0-7)
                CLR     A
                LB      A, r6
                L       A, ACC
                ST      A, er3
                L       A, X1
                ADD     A, er3
                MOV     X1, A
                CLRB    A
                LCB     A, 00001h[X1]
                STB     A, r3                  ; the point after
                LCB     A, 00000h[X1]
                STB     A, r2                  ; and before
                CMPB    A, r3
                JGE     mod_lookup9_down
                LB      A, r3                  ; rising: before + rise x fraction / 32
                SUBB    A, r2
                MOVB    r0, r5
                MULB
                L       A, ACC
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er3
                LB      A, r2
                ADDB    A, r6
                RT
mod_lookup9_down:
                LB      A, r2                  ; falling: before - fall x fraction / 32
                SUBB    A, r3
                MOVB    r0, r5
                MULB
                L       A, ACC
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er3
                LB      A, r2
                SUBB    A, r6
                RT

if defined(NEED_GIO)
; ------------------------------------------------------------------ a GIO channel (gio1.asm - gio4.asm)
; In: X1 = the channel's block, X2 = its timer byte, A (byte) = its bit in MOD_OUTSTATE. Tick context (the
; caller has done the tick prologue). Block:
;   +0 enable   +1 output (as mod_output)   +2 invert   +3 input select   +4 input invert
;   +5 rpm on (period word)   +7 rpm off (period word, the hysteresis)
;   +9 throttle min   +10 throttle max   +11 MAP min   +12 MAP max (raw MAP byte)
;   +13 coolant at least (raw: smaller is warmer)   +14 coolant at most   +15 intake air at least
;   +16 speed min   +17 speed max   +18 gear min   +19 gear max   +20 battery min
;   +21 on delay   +22 off delay (32 ms steps)   +23 mode: 0 steady, 1 flash while on
mod_gio:        STB     A, r3                  ; the channel's bit
                CLRB    A
                LCB     A, 00000h[X1]
                CMPB    A, #000h
                JNE     gio_live
                LB      A, r3                  ; off: if it was on, hand the pin back
                ANDB    A, off(MOD_OUTSTATE)
                JEQ     gio_ret
                J       gio_set_off
gio_ret:        RT
gio_live:
if defined(FEAT_DLSERVICE)
                MOV     DP, #DL_SVC            ; forced on over the datalog (dlservice.asm): its conditions count as met
                CLRB    A
                LB      A, [DP]
                ANDB    A, r3
                JEQ     gio_own
                MOVB    r2, #001h
                J       gio_decide
gio_own:
endif
                L       A, X1                  ; the switch input
                ADD     A, #00003h
                MOV     X1, A
                CAL     mod_switch             ; A = 1 on (uses DP, r7)
                STB     A, r2
                L       A, X1
                SUB     A, #00003h
                MOV     X1, A
                CLRB    A
                LB      A, r2
                CMPB    A, #000h
                JEQ     gio_f1
                LCB     A, 00009h[X1]          ; throttle window
                CMPB    ENG_TPS, A
                JLT     gio_f1
                LCB     A, 0000ah[X1]
                CMPB    ENG_TPS, A
                JGT     gio_f1
                LCB     A, 0000bh[X1]          ; MAP window
                CMPB    ENG_MAP, A
                JLT     gio_f1
                LCB     A, 0000ch[X1]
                CMPB    ENG_MAP, A
                JGT     gio_f1
                LCB     A, 0000dh[X1]          ; coolant at least (a larger byte is colder)
                CMPB    ENG_ECT, A
                JGT     gio_f1
                LCB     A, 0000eh[X1]          ; coolant at most
                CMPB    ENG_ECT, A
                JLT     gio_f1
                SJ      gio_c2
gio_f1:         J       gio_false
gio_c2:         LCB     A, 0000fh[X1]          ; intake air at least
                CMPB    ENG_IAT, A
                JGT     gio_f2
                LCB     A, 00010h[X1]          ; road speed window
                CMPB    ENG_VSS, A
                JLT     gio_f2
                LCB     A, 00011h[X1]
                CMPB    ENG_VSS, A
                JGT     gio_f2
if defined(FEAT_GEAR)
                MOV     DP, #MOD_GEAR          ; gear window
                LB      A, [DP]
                STB     A, r2
                LCB     A, 00012h[X1]
                CMPB    A, r2
                JGT     gio_f2
                LCB     A, 00013h[X1]
                CMPB    A, r2
                JLT     gio_f2
endif
                CLRB    A
                LCB     A, 00014h[X1]          ; battery at least
                CMPB    ENG_BATT, A
                JLT     gio_f2
                LB      A, r3                  ; the rpm window, with hysteresis on the state
                ANDB    A, off(MOD_OUTSTATE)
                JNE     gio_rpm_on
                CLR     A                      ; (word mode for the period)
                LC      A, 00005h[X1]
                SJ      gio_rpm_cmp
gio_rpm_on:     CLR     A
                LC      A, 00007h[X1]
gio_rpm_cmp:    CMP     ENG_RPMP, A                ; period past the point's: below the rpm
                JGT     gio_f2
                MOVB    r2, #001h              ; every condition holds
                SJ      gio_decide
gio_f2:         J       gio_false
gio_false:      MOVB    r2, #000h
; r2: the conditions; r1: the state now; the timer (X2) counts 32 ms steps towards a change
gio_decide:     CLRB    A
                MOVB    r1, #000h
                LB      A, r3
                ANDB    A, off(MOD_OUTSTATE)
                JEQ     gio_st0
                MOVB    r1, #001h
gio_st0:        CLRB    A
                LCB     A, 00017h[X1]          ; flash mode: toggles while the conditions hold
                CMPB    A, #000h
                JEQ     gio_steady
                LB      A, r2
                CMPB    A, #000h
                JEQ     gio_steady             ; not held: off after the off delay, as steady
                LCB     A, 00015h[X1]
                SJ      gio_count_toggle
gio_steady:     LB      A, r2
                XORB    A, r1
                JEQ     gio_same               ; as it should be: the timer rests
                LB      A, r2
                CMPB    A, #000h
                JEQ     gio_offdelay
                LCB     A, 00015h[X1]
                SJ      gio_count_toggle
gio_offdelay:   LCB     A, 00016h[X1]
gio_count_toggle:
                STB     A, r0                  ; the delay
                L       A, X2
                MOV     DP, A
                CLRB    A
                LB      A, [DP]
                CMPB    A, r0
                JGE     gio_change             ; waited long enough
                ADDB    A, #001h
                STB     A, [DP]
                SJ      gio_keep
gio_same:       L       A, X2
                MOV     DP, A
                MOVB    [DP], #000h
                SJ      gio_keep
gio_change:     MOVB    [DP], #000h
                LB      A, r1
                CMPB    A, #000h
                JNE     gio_set_off
                LB      A, r3                  ; on
                ORB     off(MOD_OUTSTATE), A
                SJ      gio_drive
gio_set_off:    CLRB    A
                LB      A, r3
                XORB    A, #0ffh
                ANDB    off(MOD_OUTSTATE), A
                CLRB    A
                LCB     A, 00000h[X1]
                CMPB    A, #000h
                JNE     gio_drive
                RC                             ; disabled: the pin handed back
                LCB     A, 00001h[X1]
                J       mod_output
; no change: the pin is taken again while it should be driven, and left alone otherwise - handing it back
; every call would put its latch at the idle level over whatever else drives it
gio_keep:       SB      PSWL.4
                SJ      gio_pin
; a change: the pin is taken or handed back
gio_drive:      RB      PSWL.4
gio_pin:        CLRB    A                      ; the pin: the state through the invert
                LB      A, r3
                ANDB    A, off(MOD_OUTSTATE)
                JEQ     gio_drive0
                LB      A, #001h
gio_drive0:     STB     A, r1
                LCB     A, 00002h[X1]
                ANDB    A, #001h
                XORB    A, r1
                CMPB    A, #000h
                JNE     gio_drive1
                MB      C, PSWL.4              ; off: only on a change
                JLT     gio_done
                RC
                SJ      gio_drive2
gio_drive1:     SC
gio_drive2:     CLRB    A
                LCB     A, 00001h[X1]
                J       mod_output
gio_done:       RT
endif

if defined(NEED_SWPWM)
; ------------------------------------------------------------------ software PWM on a free output
; Every tick: a 25-step cycle (51 ms, 19.5 Hz) on the output in MOD_SWOUT (as mod_output), on for MOD_SWDUTY
; steps. The output is only touched when it changes.
mod_swpwm_tick: L       A, DP
                PUSHS   A
                MOV     DP, #MOD_SWSTEP
                CLRB    A
                LB      A, [DP]
                ADDB    A, #001h
                CMPB    A, #019h
                JLT     swpwm_step
                CLRB    A
swpwm_step:     STB     A, [DP]
                INC     DP                     ; the duty, right after the step
                CMPB    A, #000h
                JNE     swpwm_mid
                LB      A, [DP]                ; the start of a cycle: on, unless the duty is 0
                CMPB    A, #000h
                JEQ     swpwm_done
                SC
                SJ      swpwm_set
swpwm_mid:      CMPB    A, [DP]
                JNE     swpwm_done             ; the step the duty ends on: off
                RC
swpwm_set:      CAL     mod_swpwm_drive
swpwm_done:     POPS    A
                MOV     DP, A
                RT
; C = on. The tick prologue, then mod_output.
mod_swpwm_drive:
                PUSHS   LRB
                MOV     LRB, #SVC_BANKT
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                MOV     DP, #MOD_SWOUT
                CLRB    A
                LB      A, [DP]
                CAL     mod_output
; out to the pin now: the main loop copies the latches to the 8255 only a few times a second at high rpm,
; far too slow for a PWM (an interrupt, so nothing else writes the 8255 meanwhile)
                CAL     skel_ports_now
                J       mod_tick_exit
endif

if defined(NEED_OUTPORT)
; ------------------------------------------------------------------ outputs
; In: A (byte) = the output: 0 none, 1 P0.0 (A/C clutch, A15), 2 P0.1 (EVAP purge), 3 P0.4 (A/T lock-up),
;     4 P1.2 (O2 heater), 5 P1.4 (check-engine lamp, A13), 6 P1.5 (ECU LED), 7 P0.2 (alternator control, A16)
;     high, 8 P0.2 low, 9 P0.0 held high (the A/C clutch kept off), 10 P0.3 (radiator fan: low = on, as the other
;     relays, and the stock code holds it high while warm), 11 P4.3 (pin A17,
;     the CPU's own pin: high = on); C = drive it on. (Flashed one at a time on a car: P0.0 A/C clutch, P0.2
;     alternator control, P0.3 fan, P0.7 fuel pump, P1.0 VTEC, P1.2 O2 heater, P1.4 the lamp, P4.3 pin A17. The
;     others did nothing on that board - parts not fitted - and keep the stock code's names.)
;     "On" is the output's active level: low for the P0 ones and the O2 heater (they switch a relay or a
;     solenoid to ground), high for the lamp and the LED. Off hands the pin back and puts its latch at the
;     idle level: the skeleton copies an overridden level into the latch, and for the pins it no longer
;     drives itself nothing else would put it back.
; Uses DP, X2, r4-r6. Tick context (or anywhere interrupts are off).
; P13: the same numbers, on the 82C55's ports B and C, in the sense of the stock code's copies (225h, 226h: 1 = on):
;     1 PB.0 A/C clutch, 2 PB.7 EVAP purge, 3 PC.2 A/T, 4 the O2 heater (the CPU's P2A.2, low = on), 5 PC.3 the lamp,
;     6 none, 7 PB.3 alternator control high, 8 PB.3 low, 9 PB.0 A/C clutch held off, 10 PB.2 fan, 11 PB.6 (spare).
;     Off hands it back and puts the copy's bit at the idle level. (From the board's wiring; not tried on a car.)
mod_output:     STB     A, r5                  ; (called in byte mode)
                CLRB    A
                MB      ACC.0, C
                STB     A, r6
                CLR     A                      ; the index as a word, high byte 0
                LB      A, r5
                CMPB    A, #00ch
                JGE     mod_output_ret
                CMPB    A, #004h               ; P13: 4, the O2 heater, is the CPU's own pin (P2A.2, low = on)
                JEQ     mod_output_p2a
                L       A, ACC
                MOV     X2, A
                CLRB    A                      ; byte mode
                LCB     A, mod_out_mask[X2]
                CMPB    A, #000h
                JEQ     mod_output_ret         ; 0: none
                STB     A, r4
                MOV     DP, #SVC_OVR           ; port B's masks...
                LCB     A, mod_out_port[X2]
                CMPB    A, #000h
                JEQ     mod_output_port
                MOV     DP, #SVC_OVR + 2       ; ...or port C's
mod_output_port:
                LB      A, r6
                CMPB    A, #000h
                JEQ     mod_output_release
                LB      A, r4                  ; take the pin: clear it in the AND mask...
                XORB    A, #0ffh
                ANDB    A, [DP]
                STB     A, [DP]
                INC     DP
                LB      A, r4                  ; ...and put its on level in the OR mask
                XORB    A, #0ffh
                ANDB    A, [DP]
                STB     A, r6
                CLRB    A
                LCB     A, mod_out_on[X2]
                ORB     A, r6
                STB     A, [DP]
                RT
mod_output_p2a: LB      A, r6
                CMPB    A, #000h
                JEQ     mod_output_p2a_off
                RB      SKEL_OVR_P2A.1         ; held on (low): the skeleton puts it back after each stock write
                SB      SKEL_OVR_P2A.0
                RB      P2A.2
                RT
mod_output_p2a_off:
                RB      SKEL_OVR_P2A.0         ; given back, at the idle level (off: high) until the stock code writes it
                SB      SKEL_OVR_P2A.1
                SB      P2A.2
                RT
mod_output_release:
                LB      A, r4                  ; give it back: set it in the AND mask, clear it in the OR mask
                ORB     A, [DP]
                STB     A, [DP]
                INC     DP
                LB      A, r4
                XORB    A, #0ffh
                ANDB    A, [DP]
                STB     A, [DP]
                MOV     DP, #00225h            ; and the copy's bit to the idle level: port B's...
                CLRB    A
                LCB     A, mod_out_port[X2]
                CMPB    A, #000h
                JEQ     mod_output_latch
                MOV     DP, #00226h            ; ...or port C's
mod_output_latch:
                LB      A, r4
                XORB    A, #0ffh
                ANDB    A, [DP]
                STB     A, r6
                CLRB    A
                LCB     A, mod_out_idle[X2]
                ORB     A, r6
                STB     A, [DP]
mod_output_ret: RT
;@ ModOutputMask type=u8 count=12 formula=raw category="Internal" desc="lib.asm: the pin of each free output (not a tuning value)."
mod_out_mask:   DB      000h, 001h, 080h, 004h, 000h, 008h, 000h, 008h, 008h, 001h, 004h, 040h
;@ ModOutputPort type=u8 count=12 formula=raw category="Internal" desc="lib.asm: the port of each free output, 0 B, 1 C (not a tuning value)."
mod_out_port:   DB      000h, 000h, 000h, 001h, 000h, 001h, 000h, 000h, 000h, 000h, 000h, 000h
;@ ModOutputOn type=u8 count=12 formula=raw category="Internal" desc="lib.asm: the on level of each output (not a tuning value)."
mod_out_on:     DB      000h, 001h, 080h, 004h, 000h, 008h, 000h, 000h, 008h, 000h, 004h, 040h    ; the copy's bit when on
;@ ModOutputIdle type=u8 count=12 formula=raw category="Internal" desc="lib.asm: the off level of each output (not a tuning value)."
mod_out_idle:   DB      000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h    ; the copy's bit when off
endif
endif

endif
