; ==================================================================================================
; remote.asm - remote control over the datalog cable
;> feature: FEAT_REMOTE
;> name: Remote control commands
;> category: Diagnostics
;> requires: FEAT_DATALOG
;> conflicts: FEAT_STOCK_SERIAL
;> ram: 0FDh bit 1, module RAM (21 bytes), and the rev cap: 2 more shared by every rev limit (lib.asm)
;> pages: datalog
;> about: Commands over the datalog cable for a remote control panel (a phone, a dash button box): the fan
;>        on or off, the rev limit, the speed limit, the boost cut and the VTEC point set, popcorn mode (decel
;>        pops), and an anti-start lock: no password, no start. The main password runs the engine as tuned,
;>        the guest password in valet mode - a lower rev limit, a speed limit, softer timing (or, set so, no
;>        password at all means valet mode instead of no start). Also the shift light point, fuel or ignition
;>        cut for the rev limiter and launch control, the launch rpm and rolling idle. Everything set over the
;>        cable is forgotten at power-up. Off until enabled.
;
; Each command is one byte, some followed by one or two value bytes; the answer is one byte: the command (or the
; value) when it is taken, 7Fh when this ROM cannot (the module is not enabled). See docs/remote.html.
;   30h fan as the ECU decides   31h fan on   32h fan off
;   33h n  rev limit n x 50 rpm (0 = the ROM's own; never above it)        34h  read it (n)
;   35h n  speed limit n km/h (0 = none)                                  36h  read it (n)
;   37h n  boost cut at MAP sensor count n (0 = the tune's own; never above the tune's own + RemoteBoostMaxUp)
;                                                                         38h  read it (n)
;   39h n  VTEC engage point at rpm byte n (0 = the tune's own)            3Ah  read it (n)
;   3Dh popcorn mode on       3Eh off
;   3Fh the state: bit 0 fan forced, 1 forced on, 2 popcorn, 3 unlocked, 4 valet (the guest password), 6 locked
;       now, 7 enabled
;   2Dh everything set here back to normal (not the lock or the valet mode)
;   2Eh lock again (with the anti-start lock on: the engine stops)
;   2Fh hi lo  a password (0-65535, high byte first): 80h the main one (as tuned), 81h the guest one (valet), 7Fh
;       neither
;   2Ch k n  set value k to n (answer n; 7Fh: no such k)     2Bh k  read value k
;       k: 0 rev limit (n x 50 rpm), 1 speed limit (km/h), 2 boost cut (MAP counts), 3 VTEC point (rpm byte) - as above;
;          4 shift light point (n x 50 rpm), 5 the rev limiter's and launch control's cut (1 fuel, 2 ignition, 3 both),
;          6 launch control rpm (n x 50 rpm), 7 rolling idle (1 off, 2 on), 8 what rolling idle leaves out (1 an
;          injector opening, 2 a spark), 9 rolling idle's one event in n (3-19). 0: the tune's own, for every one.
; ==================================================================================================
ifdef FEAT_REMOTE

if XP == XP_DEFS
ifndef NEED_REVCAP
define NEED_REVCAP                             ; (its rev limit is a hard limit for the crank interrupt too: lib.asm)
endif
ifndef NEED_MODLIB
define NEED_MODLIB
endif
ifndef NEED_FUELTRIM
define NEED_FUELTRIM
endif
ifndef NEED_IGNTRIM
define NEED_IGNTRIM
endif
ifndef NEED_OUTPORT
define NEED_OUTPORT
endif
ifndef NEED_DECELPOP
define NEED_DECELPOP
endif
rc_flags            EQU     MODRAM_NEXT         ; bits as the 3Fh answer, but 5 = popping now, 6 = hand the fan back (pending)
; the values set over the cable (2Ch k n): value k at rc_rev + k, 0 = the tune's own
rc_rev              EQU     MODRAM_NEXT + 1     ; 0: the rev limit set, x 50 rpm (0 none)
rc_speed            EQU     MODRAM_NEXT + 2     ; 1: the speed limit set, km/h (0 none)
rc_boost            EQU     MODRAM_NEXT + 3     ; 2: the boost cut set, in the MAP sensor's counts
rc_vtec             EQU     MODRAM_NEXT + 4     ; 3: the VTEC engage point set, as the rpm byte
rc_shift            EQU     MODRAM_NEXT + 5     ; 4: the shift light point, x 50 rpm
rc_cut              EQU     MODRAM_NEXT + 6     ; 5: the rev limiter's and launch's cut + 1 (1 fuel, 2 ignition, 3 both)
rc_launch           EQU     MODRAM_NEXT + 7     ; 6: the launch control rpm, x 50 rpm
rc_ri_en            EQU     MODRAM_NEXT + 8     ; 7: rolling idle + 1 (1 off, 2 on)
rc_ri_mode          EQU     MODRAM_NEXT + 9     ; 8: what rolling idle leaves out + 1 (1 an injector opening, 2 a spark)
rc_ri_every         EQU     MODRAM_NEXT + 10    ; 9: rolling idle's one event in n
RC_KEYS             EQU     10
rc_tmp              EQU     MODRAM_NEXT + 11    ; the password as it comes in (word: low byte first); 2Ch's key
rc_fuel             EQU     MODRAM_NEXT + 13    ; its fuel trim word (popcorn)
rc_ign              EQU     MODRAM_NEXT + 15    ; its timing trim word (valet mode, popcorn)
rc_shift_per        EQU     MODRAM_NEXT + 17    ; the shift light point as a crank period (0: the tune's), each tick
rc_launch_per       EQU     MODRAM_NEXT + 19    ; the launch rpm as a crank period (0: the tune's), each tick
undef MODRAM_NEXT
define MODRAM_NEXT (rc_flags + 21)
; its tick slot (SLOT_REMOTE) comes from features.inc
endif

if XP == XP_BOOT
                CAL     rc_boot
endif

if XP == XP_TICKSLOT
if SLOT_REMOTE == TICK_SLOT
                CAL     rc_tick                ; the lock and the limits
endif
if SLOT_REMOTE2 == TICK_SLOT
                CAL     rc_tick2               ; popcorn, the timing and the fan
endif
endif

if XP == XP_CAL
;@ RemoteEnable type=u8 flag=1 on=1 off=0 category="Remote control" slot=remote.enable desc="Take the remote control commands over the datalog cable (30h-3Fh, 2Dh-2Fh). Off: they are answered 7Fh and nothing changes."
rc_enable:              DB  000h
                        DB  000h                 ; (the cut type of its limits for mod_cut: 0 fuel)
;@ RemoteLock type=u8 flag=1 on=1 off=0 category="Remote control" slot=remote.lock desc="Anti-start: at every key-on the engine will not run (no fuel, no spark) until a password is sent (2Fh). No password, no start."
rc_lock:                DB  000h
                        DB  001h                 ; (popcorn's spark cut for mod_cut: 1 ignition)
;@ RemoteLockValet type=u8 flag=1 on=1 off=0 category="Remote control" slot=remote.lockvalet desc="With the anti-start lock on: no password (or a wrong one) starts the engine in valet mode instead of not at all - its rev limit, speed limit and softer timing - until the main password is sent."
rc_lock_valet:          DB  000h
;@ RemoteMainPassword type=u16 formula=x min=0 max=65535 decimals=0 category="Remote control" slot=remote.password.main desc="The main password, a number 0-65535: the engine runs as tuned."
rc_pw_main:             DW  00000h
;@ RemoteGuestPassword type=u16 formula=x min=0 max=65535 decimals=0 category="Remote control" slot=remote.password.guest desc="The guest password, a number 0-65535: the engine runs in valet mode (the limits below). Keep it different from the main one."
rc_pw_guest:            DW  00001h
;@ PopcornRpm type=u16 formula=rpm_period_word category="Remote control" slot=remote.pop.rpm desc="Popcorn mode works above this rpm, with the throttle shut."
rc_pop_rpm:             DW  002eeh               ; 2500 rpm
;@ RemoteGuestEnable type=u8 flag=1 on=1 off=0 category="Remote control" slot=remote.guest desc="Take the guest password (valet mode). Off: only the main password is taken."
rc_guest:               DB  000h
;@ RemoteValetRev type=u8 formula="x*50" inverse="x/50" unit=rpm decimals=0 min=0 max=12750 category="Remote control" slot=remote.valet.rev desc="Valet mode's rev limit (0 = the ROM's own). A rev limit set over the cable (33h) wins over it."
rc_valet_rev:           DB  050h                 ; 4000 rpm
;@ RemoteValetSpeed type=u8 formula=speed_kmh_byte category="Remote control" slot=remote.valet.speed desc="Valet mode's speed limit (0 = none). A speed limit set over the cable (35h) wins over it."
rc_valet_speed:         DB  03ch                 ; 60 km/h
;@ RemoteValetIgn type=u8 formula="(x-128)/4" inverse="x*4+128" unit=deg decimals=2 min=-32 max=0 category="Remote control" slot=remote.valet.ign desc="Valet mode's timing offset (negative = softer)."
rc_valet_ign:           DB  070h                 ; -4 degrees
;@ RemoteBoostMaxUp type=u8 formula=x min=0 max=112 category="Remote control" slot=remote.boostmax desc="How far the boost cut may be set over the cable past the tune's own cut point, in the MAP sensor's counts. 0 (the default): it can only be set lower - never above what the tune allows."
rc_boost_max:           DB  000h
;@ PopcornMaxTps type=u8 formula=tps_pct category="Remote control" slot=remote.pop.tps desc="Popcorn mode works while the throttle is at or under this."
rc_pop_tps:             DB  022h
;@ PopcornFuel type=u8 formula="x*100/256" inverse="x*256/100" unit=% decimals=1 min=0 max=99 category="Remote control" slot=remote.pop.fuel desc="Popcorn mode: fuel added while it pops (the overrun fuel cut is held off)."
rc_pop_fuel:            DB  040h                 ; +25 %
;@ PopcornRetard type=u8 formula="x/4" inverse="x*4" unit=deg decimals=2 min=0 max=63 category="Remote control" slot=remote.pop.retard desc="Popcorn mode: timing taken out while it pops (the fuel burns in the exhaust)."
rc_pop_retard:          DB  03ch                 ; 15 degrees
endif

if XP == XP_CODE
; ------------------------------------------------------------------ power-up: nothing set, locked when the lock is on
rc_boot:        L       A, DP
                PUSHS   A
                CAL     rc_clear_values
                MOV     DP, #rc_flags
                CLRB    A
                LCB     A, rc_lock
                CMPB    A, #000h
                JNE     rc_boot_locked
                MOVB    [DP], #008h            ; no lock: unlocked, as tuned
                SJ      rc_boot_ret
rc_boot_locked: MOVB    [DP], #000h            ; locked: no start...
                LCB     A, rc_lock_valet
                CMPB    A, #000h
                JEQ     rc_boot_ret
                MOVB    [DP], #018h            ; ...or, set so, valet mode until the main password
rc_boot_ret:    POPS    A
                MOV     DP, A
                RT

; Every value set over the cable back to the tune's own (and their periods). Uses DP, A.
rc_clear_values:
                MOV     DP, #rc_rev
rc_clear_next:  MOVB    [DP], #000h
                INC     DP
                CMP     DP, #rc_rev + RC_KEYS
                JNE     rc_clear_next
                MOV     DP, #rc_shift_per
                MOV     [DP], #00000h
                MOV     DP, #rc_launch_per
                MOV     [DP], #00000h
                RT

if defined(FEAT_DATALOG)              ; (without the datalog nothing can reach them)
; ------------------------------------------------------------------ a command (datalog.asm's receive interrupt)
; In: A (byte) = the command (2Dh-3Fh), bank 6Fh (r1 free in the command state), DP pushed.
; Leaves through dl_rx_send (an answer) or dl_rx_ret (a value byte comes next: receive state 9-14).
dl_rx_remote:   STB     A, r1
                CLRB    A
                LCB     A, rc_enable
                CMPB    A, #000h
                JNE     rc_rx_on
                J       rc_no
rc_rx_on:       LB      A, r1
                CMPB    A, #033h
                JNE     rc_c35
                MOVB    r0, #009h              ; the rev limit follows
                J       dl_rx_ret
rc_c35:         CMPB    A, #035h
                JNE     rc_c37
                MOVB    r0, #00ah              ; the speed limit follows
                J       dl_rx_ret
rc_c37:         CMPB    A, #037h
                JNE     rc_c39
                MOVB    r0, #00dh              ; the boost cut follows
                J       dl_rx_ret
rc_c39:         CMPB    A, #039h
                JNE     rc_c2c
                MOVB    r0, #00eh              ; the VTEC point follows
                J       dl_rx_ret
rc_c2c:         CMPB    A, #02ch
                JNE     rc_c2b
                MOVB    r0, #00fh              ; a key and a value follow
                J       dl_rx_ret
rc_c2b:         CMPB    A, #02bh
                JNE     rc_c2f
                MOVB    r0, #011h              ; the key to read follows
                J       dl_rx_ret
rc_c2f:         CMPB    A, #02fh
                JNE     rc_c30
                MOVB    r0, #00bh              ; the password follows, high byte first
                J       dl_rx_ret
rc_c30:         MOV     DP, #rc_flags
                CMPB    A, #030h               ; fan as the ECU decides: handed back on the next tick
                JNE     rc_c31
                LB      A, [DP]
                ANDB    A, #0fch
                ORB     A, #040h
                J       rc_store
rc_c31:         CMPB    A, #031h               ; fan on
                JNE     rc_c32
                LB      A, [DP]
                ANDB    A, #0bfh
                ORB     A, #003h
                J       rc_store
rc_c32:         CMPB    A, #032h               ; fan off
                JNE     rc_c34
                LB      A, [DP]
                ANDB    A, #0bdh
                ORB     A, #001h
                J       rc_store
rc_c34:         MOV     DP, #rc_rev            ; the reads
                CMPB    A, #034h
                JEQ     rc_read
                MOV     DP, #rc_speed
                CMPB    A, #036h
                JEQ     rc_read
                MOV     DP, #rc_boost
                CMPB    A, #038h
                JEQ     rc_read
                MOV     DP, #rc_vtec
                CMPB    A, #03ah
                JEQ     rc_read
                MOV     DP, #rc_flags
                CMPB    A, #03dh               ; popcorn on
                JNE     rc_c3e
                LB      A, [DP]
                ORB     A, #004h
                J       rc_store
rc_c3e:         CMPB    A, #03eh               ; popcorn off
                JNE     rc_c3f
                LB      A, [DP]
                ANDB    A, #0fbh
                J       rc_store
rc_c3f:         CMPB    A, #03fh               ; the state
                JNE     rc_c2d
                LB      A, [DP]
                ANDB    A, #01fh               ; (bit 5 is the tick's own)
                ORB     A, #080h               ; enabled
                STB     A, r1
                CLRB    A
                LCB     A, rc_lock
                CMPB    A, #000h
                JEQ     rc_state_out
                MB      C, [DP].3              ; locked now: the lock on and not unlocked
                JLT     rc_state_out
                LB      A, r1
                ORB     A, #040h
                STB     A, r1
rc_state_out:   LB      A, r1
                J       dl_rx_send
rc_read:        LB      A, [DP]
                J       dl_rx_send
rc_c2d:         CMPB    A, #02dh               ; everything back to normal (the lock and valet mode stay)
                JNE     rc_c2e
                LB      A, [DP]
                ANDB    A, #018h               ; keep unlocked and valet
                MB      C, [DP].0
                JGE     rc_c2d_fan
                ORB     A, #040h               ; the fan was forced: hand it back
rc_c2d_fan:     STB     A, [DP]
                CAL     rc_clear_values
                J       rc_ok
rc_c2e:         CMPB    A, #02eh               ; lock again (with the lock on)
                JNE     rc_no
                CLRB    A
                LCB     A, rc_lock
                CMPB    A, #000h
                JEQ     rc_ok
                LB      A, [DP]
                ANDB    A, #0e7h               ; locked: not unlocked, not valet...
                STB     A, [DP]
                CLRB    A
                LCB     A, rc_lock_valet
                CMPB    A, #000h
                JEQ     rc_ok
                LB      A, [DP]
                ORB     A, #018h               ; ...or valet mode, when set so
                STB     A, [DP]
                J       rc_ok
rc_store:       STB     A, [DP]
rc_ok:          LB      A, r1
                J       dl_rx_send
rc_no:          LB      A, #07fh
                J       dl_rx_send

; ------------------------------------------------------------------ a value byte (receive states 9-14)
; In: A (byte) = the byte, r0 = the state. Bank 6Fh, DP pushed.
dl_rx_rcarg:    STB     A, r1
                MOV     DP, #rc_rev            ; 9: the rev limit
                CMPB    r0, #009h
                JEQ     rc_arg_store
                MOV     DP, #rc_speed          ; 10: the speed limit
                CMPB    r0, #00ah
                JEQ     rc_arg_store
                MOV     DP, #rc_boost          ; 13: the boost cut
                CMPB    r0, #00dh
                JEQ     rc_arg_store
                MOV     DP, #rc_vtec           ; 14: the VTEC point
                CMPB    r0, #00eh
                JEQ     rc_arg_store
                CMPB    r0, #00fh
                JEQ     rc_arg15
                CMPB    r0, #010h
                JEQ     rc_arg16
                CMPB    r0, #011h
                JEQ     rc_arg17
                CMPB    r0, #00bh
                JNE     rc_arg12
                MOV     DP, #rc_tmp + 1        ; 11: the password's high byte
                LB      A, r1
                STB     A, [DP]
                MOVB    r0, #00ch
                J       dl_rx_ret
rc_arg_store:   LB      A, r1
                STB     A, [DP]
                MOVB    r0, #000h
                J       dl_rx_send
; 15: 2Ch's key (kept in rc_tmp), 16: its value; 17: 2Bh's key
rc_arg15:       MOV     DP, #rc_tmp
                LB      A, r1
                STB     A, [DP]
                MOVB    r0, #010h
                J       dl_rx_ret
rc_arg_key:     MOVB    r0, #000h              ; In: A (byte) = a key. Out: DP = its value, or to rc_no
                CMPB    A, #RC_KEYS
                JGE     rc_arg_nokey
                L       A, ACC                 ; (the high byte is 0: CLRB at the start of the byte)
                ADD     A, #rc_rev
                MOV     DP, A
                RT
rc_arg_nokey:   MOV     DP, #00000h
                RT
rc_arg16:       MOV     DP, #rc_tmp
                CLR     A
                LB      A, [DP]
                CAL     rc_arg_key
                CMP     DP, #00000h
                JEQ     rc_arg_no
                SJ      rc_arg_store
rc_arg17:       CLR     A
                LB      A, r1
                CAL     rc_arg_key
                CMP     DP, #00000h
                JEQ     rc_arg_no
                LB      A, [DP]
                J       dl_rx_send
rc_arg_no:      LB      A, #07fh
                J       dl_rx_send
rc_arg12:       MOVB    r0, #000h              ; 12: its low byte, then which password it is
                MOV     DP, #rc_tmp
                LB      A, r1
                STB     A, [DP]
                CLR     A                      ; word mode for the compare (LC keeps the mode it finds)
                LC      A, rc_pw_main
                CMP     A, [DP]
                JNE     rc_pw_guest_try
                MOV     DP, #rc_flags          ; the main one: unlocked, as tuned
                LB      A, [DP]
                ANDB    A, #0efh
                ORB     A, #008h
                STB     A, [DP]
                LB      A, #080h
                J       dl_rx_send
rc_pw_guest_try:
                CLRB    A
                LCB     A, rc_guest
                CMPB    A, #000h
                JEQ     rc_pw_wrong
                CLR     A
                LC      A, rc_pw_guest
                CMP     A, [DP]
                JNE     rc_pw_wrong
                MOV     DP, #rc_flags          ; the guest one: unlocked, valet mode
                LB      A, [DP]
                ORB     A, #018h
                STB     A, [DP]
                LB      A, #081h
                J       dl_rx_send
rc_pw_wrong:    LB      A, #07fh
                J       dl_rx_send

endif

; ------------------------------------------------------------------ the points set over the cable
; The boost cut: In: A (byte) = the tune's cut point. Out: A (byte) = the one set over the cable if any, but never
; above the tune's own + RemoteBoostMaxUp. Uses DP, er3 (r6, r7): free where it is called (boostcut.asm).
rc_boost_point: STB     A, r6                  ; the tune's
                MOV     DP, #rc_boost
                LB      A, [DP]
                JEQ     rc_bp_tune
                STB     A, r7                  ; the one set
                CLRB    A
                LCB     A, rc_boost_max
                ADDB    A, r6                  ; the highest allowed
                JGE     rc_bp_cmp
                LB      A, #0ffh               ; (past FFh)
rc_bp_cmp:      CMPB    A, r7
                JLT     rc_bp_ret              ; set above it: held there
                LB      A, r7
rc_bp_ret:      RT
rc_bp_tune:     LB      A, r6
                RT
; The VTEC engage point: In: A (byte) = the tune's (the rpm byte). Out: A (byte) = the one set over the cable, or
; that. Uses DP, r6 (vtecctl.asm).
rc_vtec_point:  STB     A, r6
                MOV     DP, #rc_vtec
                LB      A, [DP]
                JNE     rc_vp_ret
                LB      A, r6
rc_vp_ret:      RT

; ------------------------------------------------------------------ the tick: the lock, the limits, popcorn, the fan
; Tick context, bank 3Fh. r3 the speed limit, r4 the rev limit, r5 valet mode (1), r6 the margin, r7 a flag.
rc_tick:        PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, rc_enable
                CMPB    A, #000h
                JNE     rc_tick_on
                J       rc_tick_off
rc_tick_on:
; ---- locked: nothing runs (fuel and spark cut)
                CLRB    A
                LCB     A, rc_lock
                CMPB    A, #000h
                JEQ     rc_unlocked
                MOV     DP, #rc_flags
                MB      C, [DP].3
                JLT     rc_unlocked
                L       A, #MB_REMOTE
                SC
                CAL     mod_cutboth
                J       mod_tick_exit
rc_unlocked:
; ---- valet mode?
                CAL     rc_profile
; ---- the limits: the rev limit set, else valet mode's (r4, x 50 rpm); the speed limit likewise (r3)
                MOV     DP, #rc_rev
                CLRB    A
                LB      A, [DP]
                JNE     rc_have_rev
                LB      A, r5
                JEQ     rc_have_rev
                CLRB    A
                LCB     A, rc_valet_rev
rc_have_rev:    STB     A, r4
                MOV     DP, #rc_speed
                CLRB    A
                LB      A, [DP]
                JNE     rc_have_speed
                LB      A, r5
                JEQ     rc_have_speed
                CLRB    A
                LCB     A, rc_valet_speed
rc_have_speed:  STB     A, r3
                MOVB    r7, #000h              ; over a limit
                MOVB    r6, #000h              ; the margin: 0, or while cutting 2 (100 rpm, 2 km/h)
                L       A, off(MOD_FUELWANT)
                AND     A, #MB_REMOTE
                JEQ     rc_margin_set
                MOVB    r6, #002h
rc_margin_set:  CLRB    A
                LB      A, r4
                JEQ     rc_no_rev
                SUBB    A, r6
                JLT     rc_no_rev
                JEQ     rc_no_rev
                STB     A, r4
                CAL     rc_period              ; A (word) = the crank period of that rpm
                ST      A, er0
                CAL     mod_revcap             ; a hard limit for the crank interrupt too (uses er2, DP)
                L       A, er0
                CAL     mod_period_ahead       ; the period looking ahead: at or under it, at or over the rpm
                CMP     A, er0
                JGT     rc_no_rev
                MOVB    r7, #001h
rc_no_rev:      CLRB    A
                LB      A, r3
                JEQ     rc_no_speed
                SUBB    A, r6
                JLT     rc_no_speed
                JEQ     rc_no_speed
                CMPB    0b4h, A                ; speed - limit: no borrow at or over it
                JLT     rc_no_speed
                MOVB    r7, #001h
rc_no_speed:    CLRB    A
                LB      A, r7
                JEQ     rc_lim_off
                L       A, #MB_REMOTE
                MOV     X1, #rc_enable         ; its block: +1 = fuel cut
                SC
                CAL     mod_cut
                SJ      rc_lim_done
rc_lim_off:     L       A, #MB_REMOTE
                MOV     X1, #rc_enable
                RC
                CAL     mod_cut
rc_lim_done:    J       mod_tick_exit

; The second half, on a slot of its own (each half alone is a tick's worth): popcorn, the timing and the fan.
rc_tick2:       PUSHS   LRB
                MOV     LRB, #0003fh
                L       A, DP
                PUSHS   A
                L       A, X1
                PUSHS   A
                L       A, X2
                PUSHS   A
                CLRB    A
                LCB     A, rc_enable
                CMPB    A, #000h
                JNE     rc_tick2_en
                J       mod_tick_exit          ; off: the first half lets everything go
rc_tick2_en:
; ---- the shift light and launch points as crank periods, for their modules (0: the tune's)
                MOV     X1, #rc_shift
                MOV     X2, #rc_shift_per
                CAL     rc_point_period
                MOV     X1, #rc_launch
                MOV     X2, #rc_launch_per
                CAL     rc_point_period
                CLRB    A
                LCB     A, rc_lock
                CMPB    A, #000h
                JEQ     rc_tick2_on
                MOV     DP, #rc_flags
                MB      C, [DP].3
                JLT     rc_tick2_on
                J       rc_fan                 ; locked: no popcorn, no timing - only the fan
rc_tick2_on:
; ---- popcorn: with the throttle shut over its rpm, fuel stays on, more of it, timing out, and the sparks cut in turn
                MOVB    r7, #000h              ; popping now
                MOV     DP, #rc_flags
                MB      C, [DP].2
                JGE     rc_pop_set
                CLRB    A
                LCB     A, rc_pop_tps
                CMPB    A, 0b9h                ; limit - throttle: borrows while the throttle is over it
                JLT     rc_pop_set
                LC      A, rc_pop_rpm
                CMP     0ach, A                ; the period at or under it: at or over the rpm
                JGT     rc_pop_set
                MOVB    r7, #001h
rc_pop_set:     MOV     DP, #rc_flags          ; (bit 5: popping now - r7 does not last past mod_cut)
                RB      [DP].5
                CLRB    A
                LB      A, r7
                JEQ     rc_pop_idle
                SB      [DP].5
                SB      0fdh.1                 ; the skeleton holds the overrun fuel cut off while this is set
                CLR     A
                LCB     A, rc_pop_fuel
                L       A, ACC
                SJ      rc_pop_fuel_set
rc_pop_idle:    RB      0fdh.1
                CLR     A
rc_pop_fuel_set:
                MOV     DP, #rc_fuel
                CAL     mod_fueltrim
                CLRB    A
                LB      A, r7
                JEQ     rc_pop_nocut
                LB      A, 0feh                ; every other slot: the sparks cut, then back
                ANDB    A, #010h
                JEQ     rc_pop_nocut
                L       A, #MB_POPCORN
                MOV     X1, #rc_lock           ; its block: +1 = ignition cut
                SC
                CAL     mod_cut
                SJ      rc_pop_done
rc_pop_nocut:   L       A, #MB_POPCORN
                MOV     X1, #rc_lock
                RC
                CAL     mod_cut
rc_pop_done:    MOVB    r7, #000h
                MOV     DP, #rc_flags
                MB      C, [DP].5
                JGE     rc_pop_flag
                MOVB    r7, #001h
rc_pop_flag:
; ---- the timing: valet mode's offset, less popcorn's retard while it pops
                CAL     rc_profile
                CLR     A
                ST      A, er2
                CLRB    A
                LB      A, r5
                JEQ     rc_ign_pop
                CLR     A
                LCB     A, rc_valet_ign
                L       A, ACC
                SUB     A, #00080h             ; signed quarter degrees
                ST      A, er2
rc_ign_pop:     CLRB    A
                LB      A, r7
                JEQ     rc_ign_set
                CLR     A
                LCB     A, rc_pop_retard
                L       A, ACC
                ST      A, er3
                L       A, er2
                SUB     A, er3
                ST      A, er2
rc_ign_set:     L       A, er2
                MOV     DP, #rc_ign
                CAL     mod_igntrim
; ---- the fan
rc_fan:         MOV     DP, #rc_flags
                MB      C, [DP].6              ; hand it back (once)
                JGE     rc_fan_forced
                RB      [DP].6
                LB      A, #00ah
                RC
                CAL     mod_output
                SJ      rc_tick_ret
rc_fan_forced:  MB      C, [DP].0
                JGE     rc_tick_ret
                MB      C, [DP].1
                JGE     rc_fan_off
                LB      A, #00ah               ; on: the relay pulled in (P0.3 low)
                SC
                CAL     mod_output
                SJ      rc_tick_ret
rc_fan_off:     MOV     DP, #003dch            ; off: P0.3 taken and held high, whatever the stock code says
                LB      A, [DP]
                ANDB    A, #0f7h
                STB     A, [DP]
                INC     DP
                LB      A, [DP]
                ORB     A, #008h
                STB     A, [DP]
rc_tick_ret:    J       mod_tick_exit
; ---- not enabled: nothing held, nothing set
rc_tick_off:    CAL     rc_clear_values
                RB      0fdh.1
                L       A, #MB_REMOTE
                RC
                CAL     mod_cutboth
                L       A, #MB_POPCORN
                RC
                CAL     mod_cutboth
                J       mod_tick_exit

; Valet mode (bit 4 of the flags) in r5: 1 or 0. Uses DP.
rc_profile:     MOV     DP, #rc_flags
                CLRB    A
                LB      A, [DP]
                SRLB    A
                SRLB    A
                SRLB    A
                SRLB    A
                ANDB    A, #001h
                STB     A, r5
                RT

; A point set in 50 rpm steps as a crank period: In: X1 = the byte (0: the tune's), X2 = the word for its period.
; Uses er0-er2 (rc_period), DP.
rc_point_period:
                L       A, X1
                MOV     DP, A
                CLRB    A
                LB      A, [DP]
                JEQ     rc_pp_none
                STB     A, r4
                CAL     rc_period
                SJ      rc_pp_store
rc_pp_none:     CLR     A
rc_pp_store:    ST      A, er1
                L       A, X2
                MOV     DP, A
                L       A, er1
                ST      A, [DP]
                RT

; ------------------------------------------------------------------ for the other modules (no registers of theirs)
; The rev limiter's and launch control's cut type: In: A (byte) = the tune's (0 fuel, 1 ignition, 2 both), X1 = the
; limiter's block. Out: A. Uses DP, r6, r7 (bank 3Fh: lib.asm's mod_limit).
rc_cut_type:    STB     A, r6
                MOV     DP, #rc_cut
                LB      A, [DP]
                JEQ     rc_ct_tune
                STB     A, r7
                L       A, X1
if defined(FEAT_REVLIMIT)
                CMP     A, #revlimit_low
                JEQ     rc_ct_set
                CMP     A, #revlimit_high
                JEQ     rc_ct_set
endif
if defined(FEAT_LAUNCH)
                CMP     A, #launch_block
                JEQ     rc_ct_set
endif
rc_ct_tune:     LB      A, r6
                RT
rc_ct_set:      LB      A, r7
                SUBB    A, #001h
                CMPB    A, #003h
                JLT     rc_ct_ret
                LB      A, r6
rc_ct_ret:      RT
; A limiter's cut point (rc_limit_set) or resume point (rc_limit_reset), as crank periods: In: A (word) = the tune's,
; X1 = the limiter's block. Out: A: launch control's moved to the launch rpm set over the cable (the resume point
; kept as far below it as the tune has it). Uses DP, er2, er3 (bank 3Fh: lib.asm's mod_limit).
rc_limit_set:   L       A, ACC                 ; word mode (an LC after byte work leaves it in byte mode)
                ST      A, er3
if defined(FEAT_LAUNCH)
                L       A, X1
                CMP     A, #launch_block
                JNE     rc_ls_tune
                MOV     DP, #rc_launch_per
                L       A, [DP]
                JNE     rc_ls_ret
endif
rc_ls_tune:     L       A, er3
rc_ls_ret:      RT
rc_limit_reset: L       A, ACC
                ST      A, er3
if defined(FEAT_LAUNCH)
                L       A, X1
                CMP     A, #launch_block
                JNE     rc_ls_tune
                MOV     DP, #rc_launch_per
                L       A, [DP]
                JEQ     rc_ls_tune
                ST      A, er2
                LC      A, 00002h[X1]          ; resume - cut, the tune's...
                SUB     er3, A
                L       A, er2                 ; ...past the launch point set
                ADD     A, er3
endif
                RT
; Rolling idle's switch and what it leaves out: In: A (byte) = the tune's, DP = rc_ri_en or rc_ri_mode.
; Out: A (byte). Uses nothing else.
rc_byte_less1:  CMPB    [DP], #000h
                JEQ     rc_bl_ret
                LB      A, [DP]
                SUBB    A, #001h
rc_bl_ret:      RT

; The crank period of an rpm: In: r4 = the rpm / 50 (not 0). Out: A (word) = 37500 / it (the period of that rpm).
rc_period:      CLR     A
                ST      A, er0
                LB      A, r4
                L       A, ACC
                ST      A, er2
                L       A, #0927ch             ; 37500
                DIV                            ; (er0, A) / er2
                RT
endif

endif
