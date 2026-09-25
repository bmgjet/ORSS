; ================================================================================================
; HTS120 - generated from HTS115.asm by tools/hts120/Hts120Build (edit that, not this file).
;
; Calibration keeps its HTS 1.15 addresses (5F14h-7FFFh); code does not, so HTS 1.15/1.20 tuning
; software, which loads its own base code over a ROM, must not be used on it.
; Adds traction control from engine speed, rpm ceilings by gear and road speed, anti-start, a speed
; limiter by switch and a 40h datalog packet, all off by default. <end>
;
; Fixes
;   - Rev limiter "catch code" (HTS Rom.cs): while the ignition cut runs, the resume limit counts.
;   - Post-ignition limit (ignmap2) read its high-cam tables from 4F6Ch/4F60h - the middle of
;     boot_flag code. Both cams now use tbl_ignmap2_hi/lo, as P30/P08 do.
;   - Not applied: HTS's "VE map scaler" write at 6DFFh. The table there is live (vcal_0, 3-byte
;     entries, FFh sentinel) and HTS's check for "unset" matches it; the write would wreck it.
;   (GIO1 trigger 5586h and LeanProtect2 5B17h were already fixed in HTS115.asm.)
; Cleanup
;   - 125 bytes of unreachable code/data and 35 of filler out; the serial/datalog state machine
;     disassembled from DB bytes; cfgvariant sign checks as a table; long branches shortened.
;     All of it lands as one free block in front of the calibration (hts120_code).
; Features (all off / neutral by default; calibration at 5F14h-5F40h)
;   - SpeedCorrection: road speed x value / 8000h.
;   - Traction control from engine speed alone (TcEnable...): hts_tick / hts_tc_apply.
;   - Rpm ceilings by road speed and by gear (LimitBySpeed / LimitByGear): hts_limiter.
;   - Anti-start: locked at power-up (fuel and spark cut) until the A/C
;     switch is on with the throttle past AntiStartTps.
;   - Speed limiter by switch: fuel and spark cut at SwLimitSpeed while a chosen switch is on.
;   - Datalog command 40h: TC retard, HTS120 status, gear, raw TPS + checksum (hts120_log_table);
;     the 51-byte 20h/90h frames are untouched, so existing loggers still work.
; RAM used: 0FCh-0FFh, 388h-38Fh (LRB 71h) - untouched by HTS 1.15.
; ================================================================================================

;*************************************************************************************************
; This file is for educational USE ONLY. The comments are provided by bmgjet. Do
; not alter or post this file in any way without the consent of bmgjet. This is not to be
; used in any private financial venture.					 
;
;*************************************************************************************************
; Known, intentional, NOT bugs (left as-is, confirmed present in the original public release):
;   - leanprotect_backref_m2 EQU $-2 (0x5AAC): a label pointing 2 bytes backward on purpose, not a code gap.
;
;*************************************************************************************************
; Global zero-page state bytes used by the boot/self-test/trap framework (verified: these are
; addressed both bare (always RAM[n], page-independent) and via off(n) from LRB banks whose
trapReasonCode      equ 0f5h ; last BRK/trap "reason" sentinel (0x41-0x50-ish range seen so far);
                             ; written right before many BRKs across the whole ROM, read back by
                             ; int_break to choose the re-init path.
trapRetryCounter    equ 0f6h ; countdown used by the fault_retry_check trampoline (below) to decide
                             ; whether to keep silently retrying or to latch retriesExhaustedFlag.
lastTrapReasonCode  equ 0afh ; persisted copy of trapReasonCode taken early in int_break, before
                             ; trapReasonCode itself may be reused/cleared later in the boot path.
sysFlags_b7         equ 0b7h ; multi-purpose flags byte. bit1 confirmed = retries-exhausted latch
                             ; (set once trapRetryCounter reaches 0). bits 0/2 reused at several
                             ; sites not yet traced in this pass -- left as numeric bit indices
                             ; rather than guessed names.
currentRPMByte      equ 00133h ; working RAM byte read/compared 40x throughout the file, almost
                             ; always against RPM-domain calibration fields (FuelCutRPM,
                             ; FuelCutRPMResume, VacCutRPM, IGNCUT...) or plausible RPM-shaped
                             ; immediate thresholds (0xA0, 0xF0, 0xC5, 0x70...). High confidence
                             ; this is a scaled "current engine RPM" snapshot; exact scale/units
                             ; not derived in this pass.
; knockwindow_check3 (0x393C) compares the knock-signal period word (RAM 0x158) against the raw
; constant #05BB7h, an upper period bound; an earlier pass mis-bound that immediate to the
; coincidentally-equal code address 0x5BB7 and it has been cleaned up. leanprotect_backref_m2
; (0x5AAC, the deliberate "EQU $-2" backward
org 0000h
int_start_vec:            DW  int_start        ; 0000 AF22 Starts here with normal power up reset
int_break_vec:            DW  int_break        ; 0002 B622 Goes here if BREAK
int_WDT_vec:              DW  int_WDT          ; 0004 9E22 Goes here if WDT timed out
int_NMI_vec:              DW  int_NMI
int_INT0_vec:             DW  int_int0_vss     ; 0008 IRQ bit0 INT0 = vehicle-speed pulse input (P3.2): latches TM2 (CKP edge counter) into
                                              ; 0A8h/0ACh on every VSS pulse -- the words the VSS calc consumes to produce the 0CCh speed byte
int_serial_rx_vec:        DW  int_serial_rx    ; 000A IRQ bit1 serial RX (P3.1): tuning-link / datalog byte received
int_serial_tx_vec:        DW  int_serial_tx    ; 000C IRQ bit2 serial TX (P3.0): datalog/report byte sent
int_serial_rx_BRG_vec:    DW  int_serial_rx_BRG ; 000E IRQ bit3 serial RX baud-rate generator: handler completes crank-sync pattern confirmation
int_timer_0_overflow_vec: DW  int_spurious_irq_trap ; 0010 TM0 overflow: never enabled in this ROM -> shared spurious-IRQ trap (code 045h)
int_timer_0_vec:          DW  int_timer_0_match ; 0012 TM0 match: injector pulse end -- advances the next injector-bank pattern onto P2 and rearms TMR0
int_timer_1_overflow_vec: DW  int_spurious_irq_trap ; 0014 TM1 overflow: trap (045h)
int_timer_1_vec:          DW  int_timer_1_match ; 0016 TM1 match: reschedules TMR1 from the 098h/09Ah phase words, TCON1.3 phase toggle
int_timer_2_overflow_vec: DW  int_timer_2_overflow ; 0018 TM2 overflow: edge bookkeeping shared with int_int0_vss (0B6h bits)
int_timer_2_vec:          DW  int_timer_2_capture ; 001A TM2 capture = CKP tooth edge: reschedules TMR3 (ignition) around the measured tooth period
int_timer_3_overflow_vec: DW  int_spurious_irq_trap ; 001C TM3 overflow: trap (045h)
int_timer_3_vec:          DW  int_timer_3_match ; 001E TM3 match = ignition-output timer event: rearms TMR3 from er3 for the next event
int_a2d_finished_vec:     DW  int_spurious_irq_trap ; 0020 A/D conversion-done: not enabled (result polling used) -> trap (045h)
int_PWM_timer_vec:        DW  int_PWM_timer    ; 0022 PWM timer: boost-solenoid duty end / cycle start, drives P4.3
int_serial_tx_BRG_vec:    DW  int_spurious_irq_trap ; 0024 serial TX baud-rate generator: never enabled -> trap (045h)
int_INT1_vec:             DW  int_INT1         ; 0026 IRQ bit15 INT1 = TDC input (P3.3): the main per-cycle engine control handler
vcal_0_vec:               DW  vcal_0
vcal_1_vec:               DW  vcal_1
vcal_2_vec:               DW  vcal_2
vcal_3_vec:               DW  vcal_3
vcal_4_vec:               DW  vcal_4
vcal_5_vec:               DW  vcal_5
vcal_6_vec:               DW  vcal_6
vcal_7_vec:               DW  vcal_7
;--------------------------------------------------------------------------------------------------
;Boot constants (not code): 4-byte island, two words, copied via LC into RAM 03FCh/03FEh during
;boot (see the boot_rom_const_copy block near 25F8). Actual code starts at int_NMI, 003Ch.
;@ boot_rom_const_38 type=u8 count=4 formula=raw category=Detected desc="4 bytes"
boot_rom_const_38: DB  000h,06Eh,065h,000h
;--------------------------------------------------------------------------------------------------
;			NMI Interrupt Service Routine
;--------------------------------------------------------------------------------------------------
; NMI handler: on entry, tests+clears edge-detect bit 00230h.7; if it had just
; gone 1->0, latches DP into 00084h[X1] (some kind of "last DP at NMI" snapshot).
; Then runs two short busy-wait/poll loops (DP as a down-counter; P4.1 pin poll),
; and unconditionally reprograms a block of peripheral control registers
; (P2, TCON0, ADSCAN/ADSEL, IE, TCON1, IRQ, P4SF, TM1, SBYCON, STPACP, sysFlags_b7.1)
; before a final check on trapReasonCode that either forces trapReasonCode=047h or falls into BRK.
; NOTE: confirmed against the OKI MSM66207 datasheet -- SBYCON is the Standby Control Register
; and STPACP is the Stop Code Acceptor, so this reprogramming pass is indeed preparing to enter
; a STOP/HALT low-power mode (register list above also checks out: P2/TCON0/TCON1/P4SF/TM1 are
; the port and timer control/data registers, ADSCAN/ADSEL the A/D scan and channel-select
; registers, IE/IRQ the interrupt enable/request registers -- all named per the datasheet's SFR
; table). Mechanism is confirmed; the specific reason this NMI path enters standby (vs. e.g.
; int_break's) is not derived here.
int_NMI:        CLR     PSW
                MOV     LRB, #00041h ; local register base = #00041h (base address 0x0208)
                RB      off(00230h).7 ; test-and-reset edge-detect bit 00230h.7
                JEQ     nmi_snapshot_dp_skip ; skip snapshot if bit was already 0
                L       A, DP ; bit just transitioned 1->0: snapshot DP
                ST      A, 00084h[X1] ; ...into 00084h[X1]

nmi_snapshot_dp_skip: MOV DP, #00007h ; start short delay-loop counter (7)

nmi_delay_loop1:JRNZ    DP, nmi_delay_loop1 ; busy-wait: decrement DP to 0
                MOV     DP, #00005h ; start second delay-loop counter (5)

nmi_poll_p4_1:  MB      C, P4.1 ; sample pin P4.1 into carry
                JGE     nmi_enter_lowpower_seq ; JGE branches on Carry=0 (arch.ml) -> as soon as P4.1 reads 0, jump ahead immediately
                JRNZ    DP, nmi_poll_p4_1 ; else (P4.1 still 1) keep polling until DP counts out, then fall through anyway
nmi_enter_lowpower_seq: MOVB P2, #0ffh ; drive P2 all-high
                RB      TCON0.2 ; clear TCON0.2
                SB      TCON0.2 ; ...then set TCON0.2 (pulse it)
                CLRB    A
                STB     A, ADSCAN ; stop A/D scan
                STB     A, ADSEL ; clear A/D channel select
                MOV     IE, #00040h ; mask interrupt-enable to one source
                MOVB    TCON1, #0e0h
                CLR     IRQ ; clear pending IRQ flags
                SB      P4SF.1
                MOV     TM1, #0ffffh ; reload timer1 to max (effectively stop it counting down soon)
                SB      TCON1.4
                SB      SBYCON.2 ; standby-control bit set (see routine note above)
                LB      A, #005h
; STPACP = "Stop Code Acceptor" per the MSM66207 datasheet -- not a clock prescaler. Writing
; N then N<<1 (5, then 10) is the write-unlock sequence this register requires before STOP/HALT
; mode will actually be entered; it's a safety interlock against accidental entry, not a divider.
                STB     A, STPACP ; stop-code-acceptor unlock write, step 1: N=5
                SLLB    A ; ...step 2: N<<1=10
                STB     A, STPACP ; unlock write, step 2
                SB      SBYCON.0 ; standby-control bit 0 set (likely the actual STOP-mode trigger)
                RB      sysFlags_b7.1

nmi_check_0f5:  LB      A, trapReasonCode ; read watchdog/status-like byte trapReasonCode
                JNE     nmi_brk ; if nonzero, fall straight to BRK
                MOVB    trapReasonCode, #047h ; else stamp trapReasonCode with sentinel 047h first

nmi_brk:        BRK ; forces a BRK -> re-enters int_break (full reinit),
;--------------------------------------------------------------------------------------------------
;			Timer 0 match ISR (vector 0012h, IRQ bit5)
;
;	involves bit-twiddling of r6(aka 00116h), r7 (00117h) and the P2 shadow 00197h
;	also affects er0-er2 (00110h-00115h)
;	ultimately drives the injector bank bits on Port2 pins 3,2,1 and 0
;--------------------------------------------------------------------------------------------------

int_timer_0_match: MOV    LRB, #00022h           ; 0099 0 110 ??? 572200
; --- Timer0-match ISR = injector pulse end / next-bank stagger (P2.0-3 are the four injector
; drives on the P28). On each TMR0 match: clears the TCON0.3 timer-output bit (ANDB #0FBh) to end
; the pulse that just ran, then walks the er0->er1->er2 interval chain written by
; injector_timer_schedule: ADD TMR0,A rearms TMR0 for the next bank's pulse end, and the r6
; rotating bit pattern (&00Fh, mirrored into the P2 shadow 0197h) is ORed onto P2 to open the next
; injector bank. r7==00Fh marks "no pulse pending" (timer0_return); timer0_sequence_done resets the
; chain. This is NOT a bit-banged serial port -- it is the staged injector-bank firing engine.
                ANDB    TCON0, #0fbh           ; 009C 0 110 ??? C540D0FB
                CMPB    r7, #00fh              ; 00A0 0 110 ??? 27C00F
                JEQ     timer0_return             ; 00A3 0 110 ??? C93F
                L       A, er0                 ; 00A5 1 110 ??? 34
                JNE     timer0_bit_accumulate             ; 00A6 1 110 ??? CE3D
                L       A, er1                 ; 00A8 1 110 ??? 35
                JEQ     timer0_final_bit_check             ; 00A9 1 110 ??? C953
                ADD     TMR0, A                ; 00AB 1 110 ??? B53281
                LB      A, r6                  ; 00AE 0 110 ??? 7E
                MB      C, ACC.7               ; 00AF 0 110 ??? C5062F
                ROLB    r6                     ; 00B2 0 110 ??? 26B7
                ORB     A, r6                  ; 00B4 0 110 ??? 6E
                ANDB    A, #00fh               ; 00B5 0 110 ??? D60F
                ORB     r7, A                  ; 00B7 0 110 ??? 27E1
                ORB     off(00197h), A         ; 00B9 0 110 ??? C497E1
                LB      A, r6                  ; 00BC 0 110 ??? 7E
                SLLB    A                      ; 00BD 0 110 ??? 53
                ROLB    r6                     ; 00BE 0 110 ??? 26B7
                MOV     er0, er2               ; 00C0 0 110 ??? 4648
                L       A, #00001h             ; 00C2 1 110 ??? 670100
                ST      A, er1                 ; 00C5 1 110 ??? 89

timer0_bitshift_loop:     ST      A, er2                 ; 00C6 1 110 ??? 8A
                L       A, er0                 ; 00C7 1 110 ??? 34
                JNE     timer0_bit_shift_right             ; 00C8 1 110 ??? CE10
                L       A, er1                 ; 00CA 1 110 ??? 35
                JEQ     timer0_bit_invert             ; 00CB 1 110 ??? C910
                LB      A, r6                  ; 00CD 0 110 ??? 7E
                SRLB    A                      ; 00CE 0 110 ??? 63
                SRLB    A                      ; 00CF 0 110 ??? 63
                SRLB    A                      ; 00D0 0 110 ??? 63
                ORB     A, r6                  ; 00D1 0 110 ??? 6E

timer0_bit_output:     ORB     A, off(00197h)         ; 00D2 0 110 ??? E797
                ANDB    A, #00fh               ; 00D4 0 110 ??? D60F
                ORB     P2, A                  ; 00D6 0 110 ??? C524E1
                RTI                            ; 00D9 0 110 ??? 02

timer0_bit_shift_right:     LB      A, r6                  ; 00DA 0 110 ??? 7E
                SJ      timer0_bit_output             ; 00DB 0 110 ??? CBF5

timer0_bit_invert:     LB      A, r6                  ; 00DD 0 110 ??? 7E
                RORB    A                      ; 00DE 0 110 ??? 43
                XORB    A, #0ffh               ; 00DF 0 110 ??? F6FF
                SJ       timer0_bit_output             ; 00E1 0 110 ??? 03D200

timer0_return:     RTI                            ; 00E4 0 110 ??? 02

timer0_bit_accumulate:     ADD     TMR0, A                ; 00E5 1 110 ??? B53281
                LB      A, r6                  ; 00E8 0 110 ??? 7E
                ANDB    A, #00fh               ; 00E9 0 110 ??? D60F
                ORB     r7, A                  ; 00EB 0 110 ??? 27E1
                ORB     off(00197h), A         ; 00ED 0 110 ??? C497E1
                LB      A, r6                  ; 00F0 0 110 ??? 7E
                SLLB    A                      ; 00F1 0 110 ??? 53
                ROLB    r6                     ; 00F2 0 110 ??? 26B7
                MOV     er0, er1               ; 00F4 0 110 ??? 4548
                MOV     er1, er2               ; 00F6 0 110 ??? 4649
                L       A, #00001h             ; 00F8 1 110 ??? 670100
                SJ       timer0_bitshift_loop             ; 00FB 1 110 ??? 03C600

timer0_final_bit_check:     L       A, er2                 ; 00FE 1 110 ??? 36
                JEQ     timer0_sequence_done             ; 00FF 1 110 ??? C91F
                ADD     TMR0, A                ; 0101 1 110 ??? B53281
                LB      A, r6                  ; 0104 0 110 ??? 7E
                MB      C, ACC.0               ; 0105 0 110 ??? C50628
                RORB    A                      ; 0108 0 110 ??? 43
                STB     A, r6                  ; 0109 0 110 ??? 8E
                XORB    A, #0ffh               ; 010A 0 110 ??? F6FF
                ANDB    A, #00fh               ; 010C 0 110 ??? D60F
                ORB     r7, A                  ; 010E 0 110 ??? 27E1
                ORB     off(00197h), A         ; 0110 0 110 ??? C497E1
                LB      A, r6                  ; 0113 0 110 ??? 7E
                ANDB    A, #00fh               ; 0114 0 110 ??? D60F

timer0_sequence_reset:     ORB     P2, A                  ; 0116 0 110 ??? C524E1
                L       A, #00001h             ; 0119 1 110 ??? 670100
                ST      A, er0                 ; 011C 1 110 ??? 88
                ST      A, er1                 ; 011D 1 110 ??? 89
                ST      A, er2                 ; 011E 1 110 ??? 8A
                RTI                            ; 011F 1 110 ??? 02

timer0_sequence_done:     LB      A, #00fh               ; 0120 0 110 ??? 770F
                STB     A, r7                  ; 0122 0 110 ??? 8F
                STB     A, off(00197h)         ; 0123 0 110 ??? D497
                SJ      timer0_sequence_reset             ; 0125 0 110 ??? CBEF
;--------------------------------------------------------------------------------------------------
;			Timer 1 match ISR (vector 0016h, IRQ bit7)
;
;	toggles (TCON1).3, sets/clears (000b6h).5
;	modifies er1 (09Ah), er2 (09Ch), r6, TMR1; phase pair word 098h/09Ah
;
;	Autonomous two-phase rescheduler: on one phase it rearms TMR1 with 0A00h-er0, on the other
;	with the raw words, sampling the ADCR4 result pair into er2 every pass; sets 0B6h.5 when the
;	second phase word exceeds 64Ah. Consumer unconfirmed -- mechanism-level naming kept.
;--------------------------------------------------------------------------------------------------

int_timer_1_match: MOV    LRB, #00013h           ; 0127 0 098 ??? 571300
                JBR     off(TCON1).3, timer1_tmr1_reload ; 012A 0 098 ??? DB4124
                RB      off(000b6h).5          ; 012D 0 098 ??? C4B60D
                JNE     timer1_check_start             ; 0130 0 098 ??? CE13
                CMP     er1, #0064ah           ; 0132 0 098 ??? 45C04A06
                JLT     timer1_check_start             ; 0136 0 098 ??? CA0D
                ORB     off(000b6h), #020h     ; 0138 0 098 ??? C4B6E020
                L       A, #003b6h             ; 013C 1 098 ??? 67B603
                SUB     er1, A                 ; 013F 1 098 ??? 45A1
                ADD     off(TMR1), A           ; 0141 1 098 ??? B43681
                RTI                            ; 0144 1 098 ??? 02

timer1_check_start:     ANDB    off(TCON1), #0f7h      ; 0145 0 098 ??? C441D0F7
                L       A, off(ADCR4)          ; 0149 1 098 ??? E468
                ST      A, er2                 ; 014B 1 098 ??? 8A
                ADD     off(TMR1), off(0009ah) ; 014C 1 098 ??? B436839A
                RTI                            ; 0150 1 098 ??? 02

timer1_tmr1_reload:     ORB     off(TCON1), #008h      ; 0151 0 098 ??? C441E008
                INCB    r6                     ; 0155 0 098 ??? AE
                L       A, #00a00h             ; 0156 1 098 ??? 67000A
                SUB     A, er0                 ; 0159 1 098 ??? 28
                ST      A, er1                 ; 015A 1 098 ??? 89
                ADD     off(TMR1), off(00098h) ; 015B 1 098 ??? B4368398
                RTI                            ; 015F 1 098 ??? 02
;--------------------------------------------------------------------------------------------------
;			Timer 2 capture ISR (vector 001Ah, IRQ bit9: crank CKP tooth edge on P3.6)
;--------------------------------------------------------------------------------------------------

int_timer_2_capture: MOV  LRB, #00014h           ; 0160 0 0A0 ??? 571400
; --- Timer2-capture ISR (0x160-0x1E9+): fires on every CKP edge. It snapshots the MAP converter
; (ADCR6 -> 000BAh), tracks a small state counter (r0/r2, states 0-4/5) and TCON3 bits, and
; reschedules TMR3 (the ignition-output timer) from the measured tooth period, alongside
; int_INT1's tooth-decode logic (references TRNSIT and sysFlags_b7.2, both touched there too).
                LB      A, r2                  ; 0163 0 0A0 ??? 7A
                CMPB    A, #003h               ; 0164 0 0A0 ??? C603
                JGE     timer2_state1_check             ; 0166 0 0A0 ??? CD2A
                ADDB    A, #001h               ; 0168 0 0A0 ??? 8601
                JBS     off(ACC).0, timer2_state_dispatch ; 016A 0 0A0 ??? E80604
                MOV     off(000bah), off(ADCR6) ; 016D 0 0A0 ??? B46C7CBA

timer2_state_dispatch:     CMPB    A, r0                  ; 0171 0 0A0 ??? 48
                JEQ     timer3_reload_add             ; 0172 0 0A0 ??? C950
                JLT     timer3_reload_dec             ; 0174 0 0A0 ??? CA04

timer2_tcon3_clear:     ANDB    off(TCON3), #0fbh      ; 0176 0 0A0 ??? C443D0FB

timer3_reload_dec:     L       A, off(TM3)            ; 017A 1 0A0 ??? E43C
                SUB     A, #00001h             ; 017C 1 0A0 ??? A60100
                ST      A, off(TMR3)           ; 017F 1 0A0 ??? D43E

timer2_irq_clear:     ANDB    off(IRQH), #0f7h       ; 0181 1 0A0 ??? C419D0F7
                ORB     off(IRQ), #008h        ; 0185 1 0A0 ??? C418E008
                RB      off(TRNSIT).0          ; 0189 1 0A0 ??? C44608
                JEQ     timer2_return             ; 018C 1 0A0 ??? C903
                SB      off(sysFlags_b7).2          ; 018E 1 0A0 ??? C4B71A

timer2_return:     RTI                            ; 0191 1 0A0 ??? 02

timer2_state1_check:     JEQ     timer2_state2_check             ; 0192 0 0A0 ??? C910
                JBR     off(ACC).0, timer2_tcon3_check2 ; 0194 0 0A0 ??? D80639
                JBS     off(000a0h).3, timer2_tcon3_clear ; 0197 0 0A0 ??? EBA0DC
                CLRB    A                      ; 019A 0 0A0 ??? FA
                JBS     off(000e6h).0, timer2_state_dispatch ; 019B 0 0A0 ??? E8E6D3
                ORB     off(TCON3), #004h      ; 019E 0 0A0 ??? C443E004
                SJ      timer2_state_dispatch             ; 01A2 0 0A0 ??? CBCD

timer2_state2_check:     LB      A, r0                  ; 01A4 0 0A0 ??? 78
                ADDB    A, #001h               ; 01A5 0 0A0 ??? 8601
                CMPB    A, #005h               ; 01A7 0 0A0 ??? C605
                JGE     timer2_er3_calc             ; 01A9 0 0A0 ??? CD15
                ANDB    off(TCON3), #0fbh      ; 01AB 0 0A0 ??? C443D0FB
                L       A, er2                 ; 01AF 1 0A0 ??? 36
                CMP     A, #0001fh             ; 01B0 1 0A0 ??? C61F00
                JGE     timer2_tmr2_add             ; 01B3 1 0A0 ??? CD03
                L       A, #0001fh             ; 01B5 1 0A0 ??? 671F00

timer2_tmr2_add:     ADD     A, off(TMR2)           ; 01B8 1 0A0 ??? 873A
                SJ       timer3_reload_store             ; 01BA 1 0A0 ??? 03E701

timer2_tcon3_check:     JBS     off(TCON3).3, timer3_reload_dec ; 01BD 0 0A0 ??? EB43BA

timer2_er3_calc:     L       A, off(TMR2)           ; 01C0 1 0A0 ??? E43A
                ADD     A, er2                 ; 01C2 1 0A0 ??? 0A
                ST      A, er3                 ; 01C3 1 0A0 ??? 8B

timer3_reload_add:     L       A, off(TMR2)           ; 01C4 1 0A0 ??? E43A
                ADD     A, off(000e8h)         ; 01C6 1 0A0 ??? 87E8
                ST      A, off(TMR3)           ; 01C8 1 0A0 ??? D43E
                ANDB    off(TCON3), #0f7h      ; 01CA 1 0A0 ??? C443D0F7
                SJ      timer2_irq_clear             ; 01CE 1 0A0 ??? CBB1

timer2_tcon3_check2:     JBS     off(TCON3).2, timer2_tcon3_check ; 01D0 0 0A0 ??? EA43EA
                L       A, off(TM3)            ; 01D3 1 0A0 ??? E43C
                SUB     A, off(TMR2)           ; 01D5 1 0A0 ??? A73A
                ADD     A, #00006h             ; 01D7 1 0A0 ??? 860600
                CMP     A, er2                 ; 01DA 1 0A0 ??? 4A
                JGE     timer3_reload_alt             ; 01DB 1 0A0 ??? CD05
                L       A, off(TMR2)           ; 01DD 1 0A0 ??? E43A
                ADD     A, er2                 ; 01DF 1 0A0 ??? 0A
                SJ      timer3_reload_store             ; 01E0 1 0A0 ??? CB05

timer3_reload_alt:     L       A, off(TM3)            ; 01E2 1 0A0 ??? E43C
                ADD     A, #00004h             ; 01E4 1 0A0 ??? 860400

timer3_reload_store:     ST      A, off(TMR3)           ; 01E7 1 0A0 ??? D43E
                JBS     off(000e6h).0, timer2_irq_clear ; 01E9 1 0A0 ??? E8E695
                ORB     off(TCON3), #008h      ; 01EC 1 0A0 ??? C443E008
                SJ      timer2_irq_clear             ; 01F0 1 0A0 ??? CB8F
;--------------------------------------------------------------------------------------------------
;			Ext. Interrupt 0 Service Routine
;--------------------------------------------------------------------------------------------------				

int_int0_vss:   L       A, 0fah
; --- INT0 = vehicle-speed input edge (P3.2 on the P28). Reads the TM2 counter (which counts
; crank CKP edges), stores the running TM2 value into off(000a8h)/er2 (000aCh) with interrupt-safe
; swap, and counts edges into r3 via the shared off(000b6h) bits 0/1 with int_timer_2_overflow
; below. The 0A8h/0ACh pair is exactly what the VSS calculation (0x274A region) consumes to
; produce the 0CCh vehicle-speed byte used by the fuel-cut, boost, VTEC and shift-light logic.
                ST      A, IE
                L       A, TM2
                ORB     PSWH, #001h
                MOV     LRB, #00015h           ; 01FB 1 0A8 ??? 571500
                JBS     off(ACCH).7, int_int0_edge_check ; 01FE 1 0A8 ??? EF0708
                JBR     off(IRQH).0, int_int0_edge_check ; 0201 1 0A8 ??? D81905
                INCB    r3                     ; 0204 1 0A8 ??? AB
                ORB     off(000b6h), #002h     ; 0205 1 0A8 ??? C4B6E002

int_int0_edge_check:     XCHG    A, er0                 ; 0209 1 0A8 ??? 4410
                ST      A, er2                 ; 020B 1 0A8 ??? 8A
                CLRB    A                      ; 020C 0 0A8 ??? FA
                XCHGB   A, r3                  ; 020D 0 0A8 ??? 2310
                STB     A, r2                  ; 020F 0 0A8 ??? 8A
                ORB     off(000b6h), #004h     ; 0210 0 0A8 ??? C4B6E004
                L       A, off(000f8h)         ; 0214 1 0A8 ??? E4F8
                ANDB    PSWH, #0feh            ; 0216 1 0A8 ??? A2D0FE
                ST      A, off(IE)             ; 0219 1 0A8 ??? D41A
                RTI                            ; 021B 1 0A8 ??? 02

int_timer_2_overflow: L       A, 0fah
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #00015h           ; 0223 1 0A8 ??? 571500
                RB      off(000b6h).0          ; 0226 1 0A8 ??? C4B608
                JNE     timer2ovf_edge_check2             ; 0229 1 0A8 ??? CE01
                INCB    r6                     ; 022B 1 0A8 ??? AE

timer2ovf_edge_check2:     RB      off(000b6h).1          ; 022C 1 0A8 ??? C4B609
                JNE     timer2ovf_return             ; 022F 1 0A8 ??? CE01
                INCB    r3                     ; 0231 1 0A8 ??? AB

timer2ovf_return:     L       A, 0f8h                ; 0232 1 0A8 ??? E5F8
                ANDB    PSWH, #0feh            ; 0234 1 0A8 ??? A2D0FE
                ST      A, IE                  ; 0237 1 0A8 ??? D51A
                RTI                            ; 0239 1 0A8 ??? 02

int_timer_3_match: L     A, 0fah
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #00014h           ; 0241 1 0A0 ??? 571400
                LB      A, r0                  ; 0244 0 0A0 ??? 78
                ADDB    A, #001h               ; 0245 0 0A0 ??? 8601
                CMPB    A, #005h               ; 0247 0 0A0 ??? C605
                JLT     timer3isr_return             ; 0249 0 0A0 ??? CA0D
                JBS     off(TCON3).2, timer3isr_return ; 024B 0 0A0 ??? EA430A
                MOV     off(TMR3), er3         ; 024E 0 0A0 ??? 477C3E
                JBS     off(000e6h).0, timer3isr_return ; 0251 0 0A0 ??? E8E604
                ORB     off(TCON3), #008h      ; 0254 0 0A0 ??? C443E008

timer3isr_return:     L       A, off(000f8h)         ; 0258 1 0A0 ??? E4F8
                ANDB    PSWH, #0feh            ; 025A 1 0A0 ??? A2D0FE
                ST      A, IE                  ; 025D 1 0A0 ??? D51A
                RTI                            ; 025F 1 0A0 ??? 02

int_PWM_timer:  L       A, 0fah
; --- PWM timer ISR: the actual hardware PWM generator for the boost/wastegate duty cycle
; calculated in the main engine cycle (bstPWMHZ/bstPWMMode/bstPWMOutput -- real calibration
; fields, same subsystem as the boost-control block traced earlier). Drives P4.3 directly and
; writes PWMR0 as the timer reload value.
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #00081h           ; 0267 1 408 ??? 578100
                L       A, er2                 ; 026A 1 408 ??? 36
                JNE     pwm_period_countdown             ; 026B 1 408 ??? CE04
                LC      A, bstPWMHZ            ; 026D 1 408 ??? 909CF95F

pwm_period_countdown:     SUB     A, #00001h             ; 0271 1 408 ??? A60100
                ST      A, er2                 ; 0274 1 408 ??? 8A
                CMP     A, er1                 ; 0275 1 408 ??? 49
                LCB     A, bstPWMMode            ; 0276 1 408 ??? 909D9761
                JEQ     pwm_mode_check             ; 027A 1 408 ??? C903
                XORB    PSWH, #080h            ; 027C 1 408 ??? A2F080

pwm_mode_check:     LCB     A, bstPWMOutput            ; 027F 1 408 ??? 909D9861
                JEQ     pwm_output_clamp_check             ; 0283 1 408 ??? C905
                MB      P4.3, C                ; 0285 1 408 ??? C52C3B
                SJ      pwm_isr_return             ; 0288 1 408 ??? CB0C

pwm_output_clamp_check:     L       A, ACC                 ; 028A 1 408 ??? E506
                L       A, #0ffffh             ; 028C 1 408 ??? 67FFFF
                JGE     pwm_output_store             ; 028F 1 408 ??? CD03
                L       A, #00001h             ; 0291 1 408 ??? 670100

pwm_output_store:     ST      A, PWMR0               ; 0294 1 408 ??? D572

pwm_isr_return:     L       A, 0f8h                ; 0296 1 408 ??? E5F8
                ANDB    PSWH, #0feh            ; 0298 1 408 ??? A2D0FE
                ST      A, IE                  ; 029B 1 408 ??? D51A
                RTI                            ; 029D 1 408 ??? 02

int_INT1:       L       A, #000a0h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #00021h           ; 02A8 1 108 ??? 572100
                MOV     USP, #00280h           ; 02AB 1 108 280 A1988002
                CAL     refresh_engine_flags_snapshot             ; 02AF 1 108 280 325A4C
                SB      off(00128h).4          ; 02B2 1 108 280 C4281C
                JBS     off(0011ah).7, int1_dispatch_main_cycle ; 02B5 1 108 280 EF1A0F
                JBS     off(0011ah).3, int1_dispatch_alt1 ; 02B8 1 108 280 EB1A12
                RB      IRQH.1                 ; 02BB 1 108 280 C51909
                JEQ     dtc04_ckp_latch             ; 02BE 1 108 280 C90A
                RB      0b4h.0                 ; 02C0 1 108 280 C5B408
                MOVB    off(001d1h), #02dh     ; 02C3 1 108 280 C4D1982D

int1_dispatch_main_cycle:     J       crank_cycle_entry             ; 02C7 1 108 280 03E305

dtc04_ckp_latch:     SB      0b4h.0                 ; 02CA 1 108 280 C5B418

int1_dispatch_alt1:     L       A, ADCR6               ; 02CD 1 108 280 E56C
                ST      A, 0bah                ; 02CF 1 108 280 D5BA
                L       A, TM2                 ; 02D1 1 108 280 E538
                ST      A, 0f0h                ; 02D3 1 108 280 D5F0
                MOVB    0a2h, #000h            ; 02D5 1 108 280 C5A29800
                LB      A, #003h               ; 02D9 0 108 280 7703
                RB      TRNSIT.0               ; 02DB 0 108 280 C54608
                JNE     crank_tooth_count_store             ; 02DE 0 108 280 CE0A
                LB      A, off(00134h)         ; 02E0 0 108 280 F434
                ADDB    A, #006h               ; 02E2 0 108 280 8606
                CMPB    A, #018h               ; 02E4 0 108 280 C618
                JLT     crank_tooth_count_store             ; 02E6 0 108 280 CA02
                LB      A, #003h               ; 02E8 0 108 280 7703

crank_tooth_count_store:     STB     A, off(00134h)         ; 02EA 0 108 280 D434
                SB      P4.0                   ; 02EC 0 108 280 C52C18
                MB      C, off(0011bh).6       ; 02EF 0 108 280 C41B2E
                MB      off(0012ah).1, C       ; 02F2 0 108 280 C42A39
                JBS     off(00128h).2, int1_exit_jump ; 02F5 0 108 280 EA2817
                LB      A, off(0013dh)         ; 02F8 0 108 280 F43D
                JNE     int1_exit_jump             ; 02FA 0 108 280 CE13
                STB     A, off(0013ch)         ; 02FC 0 108 280 D43C
                SB      off(00128h).2          ; 02FE 0 108 280 C4281A
                ANDB    PSWH, #0feh            ; 0301 0 108 280 A2D0FE
                MOVB    off(00196h), #077h     ; 0304 0 108 280 C4969877
                MOVB    off(00116h), #011h     ; 0308 0 108 280 C4169811
                ORB     PSWH, #001h            ; 030C 0 108 280 A2E001

int1_exit_jump:     J       crank_cycle_dispatch2             ; 030F 0 108 280 03B504

int_serial_rx_BRG: L       A, #000a0h
; NOTE: despite the vector-table name (inherited from the OKI 66207's default peripheral
; vector list), this handler's actual content -- storing to off(0011ah)/(0011ch)/(0011eh)
; (the exact addresses refresh_engine_flags_snapshot reads from), managing a tooth/sync
; counter (0xA2/0xA3), and touching sysFlags_b7 bits 0/2 -- looks like crank/cam sync-pattern
; handling, not serial-receive-baud-rate-generator work. Likely this vector/trigger source is
; repurposed by this firmware for a different signal than its datasheet name implies. Flagging
; rather than asserting a replacement name without more certainty.
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #00021h           ; 031C 1 108 ??? 572100
                MOV     USP, #00280h           ; 031F 1 108 280 A1988002
                L       A, (00212h-00280h)[USP] ; 0323 1 108 280 E392
                ST      A, off(0011ah)         ; 0325 1 108 280 D41A
                L       A, (00214h-00280h)[USP] ; 0327 1 108 280 E394
                ST      A, off(0011ch)         ; 0329 1 108 280 D41C
                L       A, (00216h-00280h)[USP] ; 032B 1 108 280 E396
                ST      A, off(0011eh)         ; 032D 1 108 280 D41E
                MOVB    off(001d1h), #02dh     ; 032F 1 108 280 C4D1982D
                JBR     off(00128h).3, crank_sync_flags_clear_path ; 0333 1 108 280 DB282F
                JBS     off(0011ah).7, crank_sync_flag_set ; 0336 1 108 280 EF1A16
                RB      IRQH.7                 ; 0339 1 108 280 C5190F
                JNE     crank_sync_lost_path             ; 033C 1 108 280 CE3B
                RB      0b6h.7                 ; 033E 1 108 280 C5B60F
                JNE     crank_sync_lost_path             ; 0341 1 108 280 CE36

crank_sync_retry_check:     CMPB    0a2h, #005h            ; 0343 1 108 280 C5A2C005
                JGE     crank_sync_confirm_check             ; 0347 1 108 280 CD0B
                INCB    0a2h                   ; 0349 1 108 280 C5A216
                SJ       crank_sync_window_check             ; 034C 1 108 280 03A403

crank_sync_flag_set:     SB      off(00128h).4          ; 034F 1 108 280 C4281C
                SJ      crank_sync_retry_check             ; 0352 1 108 280 CBEF

crank_sync_confirm_check:     JBS     off(0011ah).7, crank_sync_confirmed ; 0354 1 108 280 EF1A06
dtc08_tdc_latch_2: SB      0b4h.1                 ; 0357 1 108 280 C5B419
                SB      off(00128h).6          ; 035A 1 108 280 C4281E

crank_sync_confirmed:     INCB    0a3h                   ; 035D 1 108 280 C5A316
                CLRB    0a2h                   ; 0360 1 108 280 C5A215
                SJ      crank_sync_window_check             ; 0363 1 108 280 CB3F

crank_sync_flags_clear_path:     RB      IRQH.7                 ; 0365 1 108 280 C5190F
                RB      0b6h.7                 ; 0368 1 108 280 C5B60F
                RB      sysFlags_b7.2                 ; 036B 1 108 280 C5B70A
                MB      C, sysFlags_b7.0              ; 036E 1 108 280 C5B728
                JGE     crank_sync_exit_jump             ; 0371 1 108 280 CD03
                SB      off(00128h).4          ; 0373 1 108 280 C4281C

crank_sync_exit_jump:     J       crank_decode_exit             ; 0376 1 108 280 03A805

crank_sync_lost_path:     SB      off(00128h).4          ; 0379 1 108 280 C4281C
                RB      off(00128h).6          ; 037C 1 108 280 C4280E
                MOVB    off(001d2h), #02dh     ; 037F 1 108 280 C4D2982D
                L       A, 0a2h                ; 0383 1 108 280 E5A2
                CMP     A, #00005h             ; 0385 1 108 280 C60500
                JEQ     crank_tooth_counter_reset             ; 0388 1 108 280 C917
                SB      off(00125h).7          ; 038A 1 108 280 C4251F
                JLT     crank_sync_flag_mid             ; 038D 1 108 280 CA0A
                CMP     A, #00105h             ; 038F 1 108 280 C60501
                JGE     crank_sync_flag_high             ; 0392 1 108 280 CD0A
                SB      0b5h.0                 ; 0394 1 108 280 C5B518
                SJ      crank_tooth_counter_reset             ; 0397 1 108 280 CB08

crank_sync_flag_mid:     SB      off(00128h).5          ; 0399 1 108 280 C4281D
                SJ      crank_tooth_counter_reset             ; 039C 1 108 280 CB03

crank_sync_flag_high:     SB      0b5h.1                 ; 039E 1 108 280 C5B519

crank_tooth_counter_reset:     CLR     0a2h                   ; 03A1 1 108 280 B5A215

crank_sync_window_check:     JBS     off(0011bh).0, crank_window_flag_clear ; 03A4 1 108 280 E81B26
; --- Crank/cam trigger-wheel tooth-counting and sync-window state machine (0x379-0x3FF+):
; tracks tooth position counters (0x134/0x135, compared against 0x17=23) and sync-confidence
; flags (0xB5.0/.1/.2, 0x128.4-7) to detect a valid missing-tooth/sync pattern. Low anchor
; density (no calibration fields); named at the mechanism level.
                RB      sysFlags_b7.2                 ; 03A7 1 108 280 C5B70A
                JEQ     crank_tooth_seq_check             ; 03AA 1 108 280 C924
                RB      off(00128h).7          ; 03AC 1 108 280 C4280F
                MOVB    off(001d3h), #007h     ; 03AF 1 108 280 C4D39807
                L       A, off(00134h)         ; 03B3 1 108 280 E434
                CMP     A, #00017h             ; 03B5 1 108 280 C61700
                JNE     crank_window_flag_check2             ; 03B8 1 108 280 CE33
                RB      off(00128h).5          ; 03BA 1 108 280 C4280D
                JNE     crank_sync_flag_low             ; 03BD 1 108 280 CE3A
                RB      off(00125h).7          ; 03BF 1 108 280 C4250F
                CMPB    0a2h, #003h            ; 03C2 1 108 280 C5A2C003
                JEQ     crank_tooth_reset             ; 03C6 1 108 280 C934

crank_sync_flag_common:     SB      0b5h.2                 ; 03C8 1 108 280 C5B51A
                SJ      crank_tooth_reset             ; 03CB 1 108 280 CB2F

crank_window_flag_clear:     RB      off(00125h).7          ; 03CD 1 108 280 C4250F

crank_tooth_seq_check:     CMPB    off(00134h), #017h     ; 03D0 1 108 280 C434C017
                JGE     crank_tooth_seq_gate             ; 03D4 1 108 280 CD06
                INCB    off(00134h)            ; 03D6 1 108 280 C43416
                SJ       crank_tooth_mod_check             ; 03D9 1 108 280 03FF03

crank_tooth_seq_gate:     JBS     off(0011bh).0, crank_tooth_seq_advance ; 03DC 1 108 280 E81B06
dtc09_cyp_latch: SB      0b4h.2                 ; 03DF 1 108 280 C5B41A
                SB      off(00128h).7          ; 03E2 1 108 280 C4281F

crank_tooth_seq_advance:     INCB    off(00135h)            ; 03E5 1 108 280 C43516
                CLRB    off(00134h)            ; 03E8 1 108 280 C43415
                SJ      crank_tooth_mod_check             ; 03EB 1 108 280 CB12

crank_window_flag_check2:     RB      off(00128h).5          ; 03ED 1 108 280 C4280D
                JGE     crank_tooth_reset             ; 03F0 1 108 280 CD0A
                JEQ     crank_sync_flag_common             ; 03F2 1 108 280 C9D4
                SB      0b5h.0                 ; 03F4 1 108 280 C5B518
                SJ      crank_tooth_reset             ; 03F7 1 108 280 CB03

crank_sync_flag_low:     SB      0b5h.1                 ; 03F9 1 108 280 C5B519

crank_tooth_reset:     CLR     off(00134h)            ; 03FC 1 108 280 B43415

crank_tooth_mod_check:     JBS     off(0011ah).7, crank_tooth_mod6_calc ; 03FF 1 108 280 EF1A0F
                JBS     off(00128h).6, crank_tooth_mod6_calc ; 0402 1 108 280 EE280C

crank_tooth_range_check:     JBS     off(0011bh).0, crank_tooth_wrap_calc ; 0405 1 108 280 E81B17
                JBS     off(00128h).7, crank_tooth_wrap_calc ; 0408 1 108 280 EF2814

crank_tooth_carry_clear:     RC                             ; 040B 1 108 280 95
                JBR     off(0011bh).6, crank_sync_store_flag ; 040C 1 108 280 DE1B2F
                SJ      crank_sync_confirmed_flag             ; 040F 1 108 280 CB29

crank_tooth_mod6_calc:     CLR     A                      ; 0411 1 108 280 F9
                MOVB    r0, #006h              ; 0412 1 108 280 9806
                LB      A, off(00134h)         ; 0414 0 108 280 F434
                ADDB    A, #003h               ; 0416 0 108 280 8603
                DIVB                           ; 0418 0 108 280 A236
                LB      A, r1                  ; 041A 0 108 280 79
                STB     A, 0a2h                ; 041B 0 108 280 D5A2
                SJ      crank_tooth_range_check             ; 041D 0 108 280 CBE6

crank_tooth_wrap_calc:     MOVB    r0, #006h              ; 041F 1 108 280 9806
                LB      A, 0a2h                ; 0421 0 108 280 F5A2
                ADDB    A, #003h               ; 0423 0 108 280 8603
                SUBB    A, r0                  ; 0425 0 108 280 28
                JGE     crank_tooth_wrap_store             ; 0426 0 108 280 CD01
                ADDB    A, r0                  ; 0428 0 108 280 08

crank_tooth_wrap_store:     STB     A, r2                  ; 0429 0 108 280 8A
                CLR     A                      ; 042A 1 108 280 F9
                LB      A, off(00134h)         ; 042B 0 108 280 F434
                DIVB                           ; 042D 0 108 280 A236
                MULB                           ; 042F 0 108 280 A234
                ADDB    A, r2                  ; 0431 0 108 280 0A
                STB     A, off(00134h)         ; 0432 0 108 280 D434
                JBS     off(0011ah).7, crank_sync_confirmed_flag ; 0434 0 108 280 EF1A03
                JBR     off(00128h).6, crank_tooth_carry_clear ; 0437 0 108 280 DE28D1

crank_sync_confirmed_flag:     SC                             ; 043A 0 108 280 85
                SB      off(00124h).2          ; 043B 0 108 280 C4241A

crank_sync_store_flag:     MB      off(0012ah).1, C       ; 043E 0 108 280 C42A39
                LB      A, off(00134h)         ; 0441 0 108 280 F434
                EXTND                          ; 0443 1 108 280 F8
                MOV     X1, A                  ; 0444 1 108 280 50
                LCB     A, tbl_crank_sync_pattern[X1]        ; 0445 1 108 280 90AB546C
                ANDB    off(00128h), A         ; 0449 1 108 280 C428D1
                LB      A, off(00134h)         ; 044C 0 108 280 F434
                JNE     crank_sync_flag2_check             ; 044E 0 108 280 CE2B
                JBR     off(00128h).2, crank_resync_reset ; 0450 0 108 280 DA280B
                JBS     off(0011fh).7, crank_sync_flag2_check ; 0453 0 108 280 EF1F25
                JBS     off(00128h).0, crank_tooth_alt_flag ; 0456 0 108 280 E82819
                RB      off(00128h).1          ; 0459 0 108 280 C42809
                SJ      crank_tooth_alt_store             ; 045C 0 108 280 CB1B

crank_resync_reset:     ANDB    PSWH, #0feh            ; 045E 0 108 280 A2D0FE
                MOVB    off(00196h), #077h     ; 0461 0 108 280 C4969877
                MOVB    off(00116h), #011h     ; 0465 0 108 280 C4169811
                ANDB    off(00128h), #0fch     ; 0469 0 108 280 C428D0FC
                ORB     PSWH, #001h            ; 046D 0 108 280 A2E001
                SJ      crank_tooth_alt_store             ; 0470 0 108 280 CB07

crank_tooth_alt_flag:     LB      A, #001h               ; 0472 0 108 280 7701
                JBR     off(00128h).1, crank_tooth_alt_store ; 0474 0 108 280 D92802
                LB      A, #002h               ; 0477 0 108 280 7702

crank_tooth_alt_store:     STB     A, off(0013ch)         ; 0479 0 108 280 D43C


crank_sync_flag2_check:     JBS     off(00128h).2, crank_sync_flag2_check2 ; 047B 0 108 280 EA2811
                CMPB    off(0013dh), #004h     ; 047E 0 108 280 C43DC004
                JEQ     crank_cycle_exit_early             ; 0482 0 108 280 C92E
                LB      A, off(0013dh)         ; 0484 0 108 280 F43D
                JNE     crank_sync_flag2_check2             ; 0486 0 108 280 CE07
                LB      A, 0a2h                ; 0488 0 108 280 F5A2
                JNE     crank_sync_flag2_check2             ; 048A 0 108 280 CE03
                SB      off(00128h).2          ; 048C 0 108 280 C4281A

crank_sync_flag2_check2:     JBR     off(0011fh).7, crank_sync_bit_check ; 048F 0 108 280 DF1F06
                LB      A, 0a2h                ; 0492 0 108 280 F5A2
                JNE     crank_cycle_exit_early             ; 0494 0 108 280 CE1C
                SJ      crank_cycle_dispatch2             ; 0496 0 108 280 CB1D

crank_sync_bit_check:     LB      A, off(0013ch)         ; 0498 0 108 280 F43C
                ANDB    A, #001h               ; 049A 0 108 280 D601
                TRB     off(00128h)            ; 049C 0 108 280 C42813 ; mnemonic was "TBR" (letter transposition)
                JNE     crank_cycle_exit_early             ; 049F 0 108 280 CE11
                CLR     A                      ; 04A1 1 108 280 F9
                LB      A, off(00134h)         ; 04A2 0 108 280 F434
                JBR     off(0013ch).0, crank_tooth_pattern_lookup ; 04A4 0 108 280 D83C02
                ADDB    A, #006h               ; 04A7 0 108 280 8606

crank_tooth_pattern_lookup:     MOV     X1, A                  ; 04A9 0 108 280 50
                LCB     A, tbl_crank_tooth_pattern[X1]        ; 04AA 0 108 280 90AB6C6C
                CMPB    A, off(0013bh)         ; 04AE 0 108 280 C73B
                JGE     crank_cycle_dispatch2             ; 04B0 0 108 280 CD03

crank_cycle_exit_early:     J       crank_decode_exit             ; 04B2 0 108 280 03A805

crank_cycle_dispatch2:     LB      A, off(0013ch)         ; 04B5 0 108 280 F43C
                SLLB    A                      ; 04B7 0 108 280 53
                EXTND                          ; 04B8 1 108 280 F8
                MOV     X1, A                  ; 04B9 1 108 280 50
                JBS     off(00125h).4, injtimer_countdown_check ; 04BA 1 108 280 EC2522
                CLR     A                      ; 04BD 1 108 280 F9
                MOV     X2, A                  ; 04BE 1 108 280 51
                ST      A, 003c2h[X2]          ; 04BF 1 108 280 D1C203
                ST      A, 003c4h[X2]          ; 04C2 1 108 280 D1C403
                ST      A, 003c6h[X2]          ; 04C5 1 108 280 D1C603
                ST      A, 003c8h[X2]          ; 04C8 1 108 280 D1C803
                CLRB    A                      ; 04CB 0 108 280 FA
                STB     A, off(001a5h)         ; 04CC 0 108 280 D4A5
                SJ       injtimer_bit_clear             ; 04CE 0 108 280 030505

injtimer_clear_path1:     SBR     off(001a7h)            ; 04D1 0 108 280 C4A711
                SB      off(0012ah).7          ; 04D4 0 108 280 C42A1F
                SB      off(001a3h).0          ; 04D7 0 108 280 C4A318
                SJ      injbase_calc_start             ; 04DA 0 108 280 CB2C

injtimer_clear_path2:     CLR     A                      ; 04DC 1 108 280 F9
                SJ      injtimer_clamp_store             ; 04DD 1 108 280 CB23

injtimer_countdown_check:     LB      A, off(001a6h)         ; 04DF 0 108 280 F4A6
                SUBB    A, #001h               ; 04E1 0 108 280 A601
                JGE     injtimer_countdown_store             ; 04E3 0 108 280 CD02
                LB      A, #007h               ; 04E5 0 108 280 7707

injtimer_countdown_store:     STB     A, off(001a6h)         ; 04E7 0 108 280 D4A6
                CMPB    A, #007h               ; 04E9 0 108 280 C607
                JGT     injtimer_bit_clear             ; 04EB 0 108 280 C818
                MBR     C, off(001a5h)         ; 04ED 0 108 280 C4A521
                JLT     injtimer_clear_path1             ; 04F0 0 108 280 CADF
                ADDB    A, #004h               ; 04F2 0 108 280 8604
                RBR     off(001a7h)            ; 04F4 0 108 280 C4A712
                JNE     injtimer_clear_path2             ; 04F7 0 108 280 CEE3
                L       A, 003c2h[X1]          ; 04F9 1 108 280 E0C203
                SUB     A, #00000h             ; 04FC 1 108 280 A60000
                JGE     injtimer_clamp_store             ; 04FF 1 108 280 CD01
                CLR     A                      ; 0501 1 108 280 F9

injtimer_clamp_store:     ST      A, 003c2h[X1]          ; 0502 1 108 280 D0C203

injtimer_bit_clear:     RB      off(001a3h).0          ; 0505 1 108 280 C4A308

injbase_calc_start:     CLR     A                      ; 0508 1 108 280 F9
; --- Base injector pulse-width calc: combines a running accumulator with INJ_MULT
; (injector-size multiplier calibration field) via mul_scale_clamp, then adds Deadtime
; (injector deadtime compensation), storing the result at off(0019eh) as the base injector
; timing value used by the critical-section hardware-timer writes traced earlier.
                JBS     off(00124h).5, injbase_store ; 0509 1 108 280 ED2428
                JBS     off(00124h).4, injbase_store ; 050C 1 108 280 EC2425
                JBS     off(0012ah).1, injbase_store ; 050F 1 108 280 E92A22
                L       A, 003bah[X1]          ; 0512 1 108 280 E0BA03
                ADD     A, 003c2h[X1]          ; 0515 1 108 280 B0C20382
                JGE     injbase_mult_deadtime             ; 0519 1 108 280 CD05
                L       A, #0ffffh             ; 051B 1 108 280 67FFFF
                SJ      injbase_store             ; 051E 1 108 280 CB14

injbase_mult_deadtime:     L       A, ACC                 ; 0520 1 108 280 E506
                MOV     er0, A                 ; 0522 1 108 280 448A
                LC      A, INJ_MULT            ; 0524 1 108 280 909C0161
                CAL     mul_scale_clamp             ; 0528 1 108 280 328B52
                MOV     X2, A                  ; 052B 1 108 280 51
                LC      A, Deadtime            ; 052C 1 108 280 909C0D61
                ADD     X2, A                  ; 0530 1 108 280 9181
                MOV     A, X2                  ; 0532 1 108 280 9199

injbase_store:     ST      A, off(0019eh)         ; 0534 1 108 280 D49E
                LB      A, off(0013ch)         ; 0536 0 108 280 F43C
                ANDB    PSWH, #0feh            ; 0538 0 108 280 A2D0FE
                TRB     off(00117h)            ; 053B 0 108 280 C41713 ;mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C41713
                JNE     tm0_sync_alt             ; 053E 0 108 280 CE23
                JBR     off(00128h).2, tm0_sync_common ; 0540 0 108 280 DA2814
                L       A, TM0                 ; 0543 1 108 280 E530
                SUB     A, TMR0                ; 0545 1 108 280 B532A2
                JEQ     tm0_sync_common             ; 0548 1 108 280 C90D
                MB      C, IRQ.5               ; 054A 1 108 280 C5182D
                JLT     tm0_sync_common             ; 054D 1 108 280 CA08
                ADD     A, #00005h             ; 054F 1 108 280 860500
                JLT     tm0_sync_common             ; 0552 1 108 280 CA03
                ADD     TMR0, A                ; 0554 1 108 280 B53281

tm0_sync_common:     ORB     PSWH, #001h            ; 0557 1 108 280 A2E001
                CAL     tm0_resync_helper             ; 055A 1 108 280 328447
                SB      off(0012ah).3          ; 055D 1 108 280 C42A1B
                SJ       crank_tooth_flag_update             ; 0560 1 108 280 038405

tm0_sync_alt:     L       A, TMR0                ; 0563 1 108 280 E532
                SUB     A, TM0                 ; 0565 1 108 280 B530A2
                CMP     A, #00005h             ; 0568 1 108 280 C60500
                JLT     tm0_sync_flag_clear             ; 056B 1 108 280 CA05
                CMP     A, #00020h             ; 056D 1 108 280 C62000
                JLT     tm0_sync_flag_set             ; 0570 1 108 280 CA09

tm0_sync_flag_clear:     ORB     PSWH, #001h            ; 0572 1 108 280 A2E001
                RB      off(0012ah).3          ; 0575 1 108 280 C42A0B
                SJ       crank_tooth_flag_update             ; 0578 1 108 280 038405

tm0_sync_flag_set:     ORB     PSWH, #001h            ; 057B 1 108 280 A2E001
                CAL     tm0_resync_helper             ; 057E 1 108 280 328447
                SB      off(0012ah).3          ; 0581 1 108 280 C42A1B

crank_tooth_flag_update:     CAL     crank_helper2             ; 0584 1 108 280 32BB45
                LB      A, off(0013ch)         ; 0587 0 108 280 F43C
                STB     A, r0                  ; 0589 0 108 280 88
                ANDB    A, #001h               ; 058A 0 108 280 D601
                SBR     off(00128h)            ; 058C 0 108 280 C42811
                INCB    r0                     ; 058F 0 108 280 A8
                LB      A, r0                  ; 0590 0 108 280 78
                ANDB    A, #003h               ; 0591 0 108 280 D603
                STB     A, off(0013ch)         ; 0593 0 108 280 D43C
                JBS     off(0011fh).3, crank_decode_exit ; 0595 0 108 280 EB1F10
                JBS     off(0011bh).7, crank_decode_exit ; 0598 0 108 280 EF1B0D
                RB      off(0012ah).0          ; 059B 0 108 280 C42A08
                JEQ     crank_decode_exit             ; 059E 0 108 280 C908
                RB      TRNSIT.2               ; 05A0 0 108 280 C5460A
                JNE     crank_decode_exit             ; 05A3 0 108 280 CE03
dtc16_injector_latch: SB      0b4h.6                 ; 05A5 0 108 280 C5B41E

crank_decode_exit:     RB      off(0012ah).3          ; 05A8 1 108 280 C42A0B
                JNE     crank_decode_final_check             ; 05AB 1 108 280 CE03
                CAL     tm0_resync_helper             ; 05AD 1 108 280 328447

crank_decode_final_check:     LB      A, 0a2h                ; 05B0 0 108 280 F5A2
                CMPB    A, #003h               ; 05B2 0 108 280 C603
                JNE     crank_cycle_dispatch             ; 05B4 0 108 280 CE39

crank_cycle_dispatch_body:     JBS     off(00126h).0, crank_cycle_period_saturate ; 05B6 0 108 280 E82625
                JBS     off(0011fh).1, crank_cycle_period_saturate ; 05B9 0 108 280 E91F22
                CMPB    A, #003h               ; 05BC 0 108 280 C603
                CLR     er2                    ; 05BE 0 108 280 4615
                JBS     off(0012ah).5, crank_cycle_alt_dp ; 05C0 0 108 280 ED2A08
                MOV     DP, #00366h            ; 05C3 0 108 280 626603
                JEQ     crank_cycle_dp_common             ; 05C6 0 108 280 C90A
                CLR     A                      ; 05C8 1 108 280 F9
                SJ      crank_cycle_er2_store             ; 05C9 1 108 280 CB16

crank_cycle_alt_dp:     MOV     DP, #00362h            ; 05CB 0 108 280 626203
                JNE     crank_cycle_dp_common             ; 05CE 0 108 280 CE02
                MOV     er2, [DP]              ; 05D0 0 108 280 B24A

crank_cycle_dp_common:     L       A, [DP]                ; 05D2 1 108 280 E2
                CLR     er0                    ; 05D3 1 108 280 4415
                MOVB    r1, 09fh               ; 05D5 1 108 280 C59F49
                MUL                            ; 05D8 1 108 280 9035
                L       A, er2                 ; 05DA 1 108 280 36
                ADD     A, er1                 ; 05DB 1 108 280 09
                JGE     crank_cycle_er2_store             ; 05DC 1 108 280 CD03

crank_cycle_period_saturate:     L       A, #0ffffh             ; 05DE 1 108 280 67FFFF

crank_cycle_er2_store:     ST      A, 0a4h                ; 05E1 1 108 280 D5A4

crank_cycle_entry:     L       A, off(00124h)         ; 05E3 1 108 280 E424
                ST      A, (0021ch-00280h)[USP] ; 05E5 1 108 280 D39C
                ANDB    PSWH, #0feh            ; 05E7 1 108 280 A2D0FE

int1_rti_epilogue:     L       A, 0f8h                ; 05EA 1 108 280 E5F8
                ST      A, IE                  ; 05EC 1 108 280 D51A
                RTI                            ; 05EE 1 108 280 02

crank_cycle_dispatch:     JGE     crank_cycle_dispatch_alt             ; 05EF 0 108 280 CD5D
                CMPB    A, #001h               ; 05F1 0 108 280 C601
                JGE     crank_cycle_dispatch_alt2             ; 05F3 0 108 280 CD60
                JBS     off(0011bh).6, crank_cycle_p4_gate ; 05F5 0 108 280 EE1B0C
                JBS     off(00125h).7, crank_cycle_p4_gate ; 05F8 0 108 280 EF2509
                CMP     0c4h, #000e7h          ; 05FB 0 108 280 B5C4C0E700
                JLT     crank_cycle_p4_gate             ; 0600 0 108 280 CA02
                SJ      crank_cycle_p4_gate             ; 0602 0 108 280 CB00

crank_cycle_p4_gate:     RB      0b4h.3                 ; 0604 0 108 280 C5B40B
                MOVB    off(001d4h), #006h     ; 0607 0 108 280 C4D49806
                JBS     off(0011fh).2, crank_cycle_gate2 ; 060B 0 108 280 EA1F49
                JBR     off(0011fh).7, crank_cycle_p4_flag_check ; 060E 0 108 280 DF1F06
                SB      P4.0                   ; 0611 0 108 280 C52C18
                SJ       crank_cycle_entry_gate             ; 0614 0 108 280 035D06

crank_cycle_p4_flag_check:     JBR     off(00129h).1, crank_cycle_f4_check ; 0617 0 108 280 D92902
                SJ      crank_cycle_result_common             ; 061A 0 108 280 CB27

crank_cycle_f4_check:     LB      A, #001h               ; 061C 0 108 280 7701
                CMPB    0f4h, #024h            ; 061E 0 108 280 C5F4C024
                JNE     crank_cycle_counter_check             ; 0622 0 108 280 CE03
                SB      off(0012ah).4          ; 0624 0 108 280 C42A1C

crank_cycle_counter_check:     CMPB    off(001d2h), #028h     ; 0627 0 108 280 C4D2C028
                JLE     crank_cycle_result_b             ; 062B 0 108 280 CF13
                JBS     off(0011fh).4, crank_cycle_result_a ; 062D 0 108 280 EC1F0C
                JBS     off(0012ah).4, crank_cycle_result_common ; 0630 0 108 280 EC2A10
                JBS     off(0011ah).5, crank_cycle_result_a ; 0633 0 108 280 ED1A06
                CMPB    0d9h, #034h            ; 0636 0 108 280 C5D9C034
                JLT     crank_cycle_result_common             ; 063A 0 108 280 CA07

crank_cycle_result_a:     LB      A, #003h               ; 063C 0 108 280 7703
                SJ      crank_cycle_result_common             ; 063E 0 108 280 CB03

crank_cycle_result_b:     SB      off(00128h).4          ; 0640 0 108 280 C4281C

crank_cycle_result_common:     SRLB    A                      ; 0643 0 108 280 63
                MB      off(00126h).0, C       ; 0644 0 108 280 C42638
                SRLB    A                      ; 0647 0 108 280 63
                MB      P4.0, C                ; 0648 0 108 280 C52C38

crank_cycle_bailout:     SJ       crank_cycle_entry             ; 064B 0 108 280 03E305

crank_cycle_dispatch_alt:     CMPB    A, #004h               ; 064E 0 108 280 C604
                JNE     crank_cycle_bailout             ; 0650 0 108 280 CEF9
                J       crank_cycle_dispatch_body             ; 0652 0 108 280 03B605

crank_cycle_dispatch_alt2:     JEQ     crank_cycle_bailout             ; 0655 0 108 280 C9F4

crank_cycle_gate2:     JBS     off(0011fh).7, crank_cycle_bailout ; 0657 0 108 280 EF1FF1
                JBR     off(00128h).4, crank_cycle_bailout ; 065A 0 108 280 DC28EE

crank_cycle_entry_gate:     INCB    off(0013eh)            ; 065D 0 108 280 C43E16
                JBS     off(0012ah).2, crank_cycle_bailout ; 0660 0 108 280 EA2AE8
                LB      A, off(00124h)         ; 0663 0 108 280 F424
                ANDB    A, #003h               ; 0665 0 108 280 D603
                ANDB    off(0013eh), A         ; 0667 0 108 280 C43ED1
                JNE     crank_cycle_bailout             ; 066A 0 108 280 CEDF
                SB      off(0012ah).2          ; 066C 0 108 280 C42A1A
                L       A, 0f8h                ; 066F 1 108 280 E5F8
                ST      A, IE                  ; 0671 1 108 280 D51A
                CAL     crank_edge_helper             ; 0673 1 108 280 32514C
                MOV     PSW, #01101h           ; 0676 1 108 280 B504980111
                MOV     LRB, #00040h
                MOV     USP, #00180h
                CAL     crank_cycle_helper1
                CAL     ectboostcut_check_start
                CAL     burnout_input_check
                CAL     shiftlight_check_start
                MOV     DP, #0037bh
                MOVB    r0, [DP]
                LB      A, 0e1h
                STB     A, [DP]
                LB      A, ADCR2H
                STB     A, 0e1h
                SUBB    A, r0
                MB      off(0022bh).5, C
                JGE     crank_cycle_adc_prep
                VCAL    6

crank_cycle_adc_prep:     STB     A, 0e2h
                LB      A, P2
                ANDB    A, #0e0h
                STB     A, off(00257h)
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      ADSCAN.4
                ANDB    P2, #01fh
                SB      ADSCAN.4
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MOV     DP, #00006h
                CLR     A
                MOV     X1, A
                ST      A, er0
                ST      A, er1

rpm_period_sum_loop:     L       A, 00360h[X1]
; --- Core RPM calculation (0x06C8-0x07C0): sums 5 stored crank/cam pulse-period samples
; (0x360[X1]), averages by dividing by 5 (rpm_period_avg_store), sanity-checks the result
; against acceleration/deceleration limits (rpm_accel_limit_check/rpm_decel_limit_check,
; triggering VCAL 7 -- likely a "erratic RPM signal" fault path -- if exceeded), then performs
; a shift-normalize-before-divide (rpm_divide_normalize_loop/rpm_divide_execute) to convert
; the raw period into the actual scaled RPM value, finally stored as currentRPMByte
; (rpm_calc_finalize, matches the currentRPMByte EQU defined near the top of this file).
; Immediately followed by the load-index calculation: blends MAP (0xBB) and TPS (0xD1) via
; the AlphaNMapCross/AlphaNTpsCross crossover thresholds to pick alpha-N (TPS-based) vs
; speed-density (MAP-based) load estimation, looked up through the AlphaN table, feeding the
; LoadIndex working value used by the main fuel/ignition tables downstream.
                JBR     off(00217h).7, rpm_period_overflow_check
                MOV     00360h[X1], #00360h
                SJ      rpm_period_accum

rpm_period_overflow_check:     JEQ     rpm_period_invalid

rpm_period_accum:     ADD     er1, A
                ADCB    r0, #000h
                INC     X1
                INC     X1
                JRNZ    DP, rpm_period_sum_loop
                RB      off(00217h).4
                RB      off(00231h).5
                L       A, er1
                MOV     er2, #00005h
                DIV
                CMPB    r0, #000h
                JEQ     rpm_period_avg_store

rpm_period_invalid:     SB      off(00231h).5
                L       A, #0ffffh

rpm_period_avg_store:     ST      A, er0
                CLR     X1
                XCHG    A, 0c4h
                ST      A, er1
                XCHG    A, 0036eh[X1]
                XCHG    A, 00370h[X1]
                XCHG    A, 00372h[X1]
                ST      A, er2
                L       A, er0
                SUB     A, er2
                MB      off(0021bh).7, C
                JGE     rpm_accel_limit_check
                VCAL    7

rpm_accel_limit_check:     ST      A, 0c8h
                L       A, er0
                SUB     A, er1
                MB      off(0021bh).6, C
                JGE     rpm_decel_limit_check
                VCAL    7

rpm_decel_limit_check:     ST      A, 0c6h
                L       A, 0c4h
                CMP     A, #000eah
                JLT     rpm_period_normalize_lowrange
                CMP     A, #00ea6h
                JGE     rpm_period_normalize_highrange
                MOV     er3, #0ffc0h
                MOV     er0, #00007h
                MOV     er2, #00753h
                MOV     X1, #05300h

rpm_divide_normalize_loop:     CMP     A, er2
                JGE     rpm_divide_execute
                SRL     er0
                ROR     X1
                ADD     er3, #00040h
                SRL     er2
                SJ      rpm_divide_normalize_loop

rpm_divide_execute:     ST      A, er2
                L       A, X1
                DIV
                SRL     A
                MB      PSWL.4, C
                ADD     er3, A
                LB      A, r7
                JNE     rpm_clamp_0xfe
                LB      A, r6
                JEQ     rpm_normalize_flag_set
                CMPB    A, #0ffh
                JGE     rpm_clamp_0xfe
                SJ      rpm_calc_finalize

rpm_period_normalize_lowrange:     CMP     A, #000bbh
                LB      A, #0ffh
                JLT     rpm_period_normalize_done

rpm_clamp_0xfe:     LB      A, #0feh

rpm_period_normalize_done:     SB      PSWL.4
                SJ      rpm_calc_finalize

rpm_period_normalize_highrange:     CLRB    A
                JBS     off(00217h).4, rpm_normalize_flag_clear

rpm_normalize_flag_set:     LB      A, #001h

rpm_normalize_flag_clear:     RB      PSWL.4

rpm_calc_finalize:     MB      C, PSWL.4
                MB      0b8h.4, C
                STB     A, (currentRPMByte-00180h)[USP]
                XCHGB   A, off(00236h)
                STB     A, 0c3h
                CLRB    r7
                JBS     off(00217h).4, loadindex_flag_default
                DECB    r7
                MOV     er2, 0c4h
                MOV     er0, #0aa00h
                CLR     A
                DIV
                SLL     A
                LB      A, r1
                RORB    A
                SC
                JNE     loadindex_flag_load
                SLLB    A
                LB      A, r0
                JNE     loadindex_store
                MOVB    r7, #001h

loadindex_flag_default:     RC

loadindex_flag_load:     LB      A, r7

loadindex_store:     STB     A, 0c2h
                MB      0b8h.3, C
                LCB     A, AlphaNMapCross
                CMPB    0bbh, A
                JGE     loadindex_use_tps
                LCB     A, AlphaNTpsCross
                CMPB    0d1h, A
                JGE     loadindex_use_tps
                LB      A, 0bbh
                SJ      loadindex_lookup_done

loadindex_use_tps:     LB      A, 0d1h
                MOV     X1, #AlphaN
                VCAL    1

loadindex_lookup_done:     MOV     DP, #00426h
                STB     A, [DP]
                JBS     off(00212h).2, map_sign_flag_clear
                LB      A, ACC
                LB      A, 0bbh
                CMPB    A, #000h
                JGE     map_neg_helper_call
dtc03_map_latch: SB      0b0h.0
                LB      A, off(00235h)
                SJ      map_sign_gate2

map_neg_helper_call:     CAL     sub_clamp_helper

map_sign_flag_clear:     RB      0b0h.0
                JBS     off(00212h).2, map_sign_gate3

map_sign_gate2:     JBR     off(00212h).4, map_sign_gate4

map_sign_gate3:     LB      A, 0d1h
                MOV     X1, #tbl_map_sign
                VCAL    1

map_sign_gate4:     STB     A, r0
                LB      A, off(00235h)
                SUBB    A, r0
                RB      off(0021bh).4
                MB      off(0021bh).4, C
                JEQ     map_delta_direction_flag
                XORB    PSWH, #080h

map_delta_direction_flag:     MB      off(002edh).6, C
                JBR     off(0021bh).4, map_delta_store
                VCAL    6

map_delta_store:     STB     A, 0c0h
                MOV     DP, #00375h
                LB      A, [DP]
                SUBB    A, r0
                MB      off(0021bh).5, C
                JGE     map_delta2_store
                VCAL    6

map_delta2_store:     STB     A, 0c1h
                LB      A, r0
                STB     A, (00132h-00180h)[USP]
                XCHGB   A, off(00235h)
                XCHGB   A, 0bdh
                DEC     DP
                XCHGB   A, [DP]
                INC     DP
                STB     A, [DP]
                LB      A, #059h
                JBS     off(00212h).2, tps_custom_clamp_store
                JBS     off(00212h).4, tps_custom_clamp_store
                LB      A, 0bch
                SUBB    A, off(00235h)
                JGE     tps_custom_clamp_store
                CLRB    A


tps_custom_clamp_store:     STB     A, 0beh
; --- TPS voltage-to-percentage linearization (0x82C-0x870ish): CustomTPS calibration flag
; gates using a custom TPSSettings interpolation table (via VCAL 1) against raw ADC readings
; (ADCR7/ADCR7H) instead of a fixed linear conversion -- lets a non-linear/aftermarket TPS
; sensor be calibrated in software.
                MOV     er0, #04d00h
                RC
                JBS     off(00212h).6, dtc07_tps_latch
                LCB     A, CustomTPS
                MOV     er0, ADCR7
                JEQ     tps_custom_result_check
                LB      A, ADCR7H
                MOV     X1, #TPSSettings
                VCAL    1
                CLR     er0
                STB     A, r1

tps_custom_result_check:     LB      A, #000h
                JNE     dtc07_tps_latch
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc07_tps_latch
                CMPB    r1, #005h

dtc07_tps_latch:     MB      0b0h.2, C
                JLT     tps_delta_alt_path
                L       A, er0
                SLL     A
                JLT     tps_delta_clamp1
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store1

tps_delta_clamp1:     LB      A, #0ffh
; --- Repeated rate-of-change/plausibility check pattern applied to several TPS-related raw
; values (0xD0/0xD2/0xD4/0xD6) across 0x852-0x8C9: compute delta, clamp to 0xFF, trigger
; VCAL 7 (erratic-sensor diagnostic, same call used for RPM plausibility earlier) if out of
; range. No calibration anchors; likely dual/redundant TPS channel handling.

tps_delta_store1:     STB     A, 0d4h
                L       A, er0
                XCHG    A, 0d0h
                MOV     er1, 0d2h
                ST      A, 0d2h
                JBR     off(00212h).6, tps_delta_check1

tps_delta_alt_path:     L       A, er0
                MOV     er1, 0d0h

tps_delta_check1:     SUB     A, er0
                MB      PSWL.4, C
                JGE     tps_delta_clamp2
                VCAL    7

tps_delta_clamp2:     SLL     A
                JLT     tps_delta_clamp2_max
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store2

tps_delta_clamp2_max:     LB      A, #0ffh

tps_delta_store2:     STB     A, r0
                MB      C, PSWL.4
                RB      off(0021bh).1
                MB      off(0021bh).1, C
                XCHGB   A, 0d5h
                JEQ     tps_delta_sign_check
                XORB    PSWH, #080h

tps_delta_sign_check:     JLT     tps_delta_flag_store
                CMPB    A, r0

tps_delta_flag_store:     MB      off(0021bh).3, C
                L       A, er1
                SUB     A, 0d0h
                MB      off(0021bh).2, C
                JGE     tps_delta_clamp3
                VCAL    7

tps_delta_clamp3:     SLL     A
                JLT     tps_delta_clamp3_max
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store3

tps_delta_clamp3_max:     LB      A, #0ffh

tps_delta_store3:     STB     A, 0d6h
                L       A, off(00294h)
                ST      A, er0
                LB      A, r1
                JBR     off(0021ah).1, tps_delta_compare_final
                LB      A, r0

tps_delta_compare_final:     CMPB    A, off(00236h)
                MB      off(0021ah).1, C
                LB      A, r1
                JBR     off(0022bh).0, tps_window_calc1
                LB      A, r0

tps_window_calc1:     ADDB    A, #00dh
                JGE     tps_window_store1
                LB      A, #0ffh

tps_window_store1:     CMPB    A, off(00236h)
                MB      off(0022bh).0, C
                MOV     DP, #00311h
                MOVB    r4, [DP]
                LB      A, #003h
                STB     A, r2
                MOVB    r3, #006h
                MB      C, off(00218h).2
                MB      off(00218h).3, C
                JLT     tps_window_calc2
                LB      A, r3

tps_window_calc2:     ADDB    A, r4
                CMPB    A, 0d4h
                MB      off(00218h).2, C
                LB      A, #004h
                JBS     off(00218h).4, tps_window_calc3
                LB      A, #007h

tps_window_calc3:     ADDB    A, r4
                CMPB    A, 0d4h
                MB      off(00218h).4, C
                LB      A, r2
                MB      C, off(00218h).0
                MB      off(00218h).1, C
                JGE     tps_window_calc4
                MOVB    r0, r1
                LB      A, r3

tps_window_calc4:     ADDB    A, r4
                CMPB    0d4h, A
                JGE     tps_window_store2
                LB      A, off(00236h)
                CMPB    A, r0

tps_window_store2:     MB      off(00218h).0, C
                MOVB    r1, off(00235h)
                JBS     off(00212h).2, tps_window_result_store
                JBS     off(00212h).4, tps_window_result_store
                CMPB    0f3h, #032h
                JGE     tps_window_gate2

tps_window_result_store:     MOVB    off(0029bh), r1
                SJ       tps_interp_exact_match

tps_window_gate2:     CMPB    0bdh, off(00235h)
                JEQ     tps_window_reset
                JBR     off(002edh).6, tps_rate_check1

tps_window_reset:     CLRB    r0
                LB      A, 0bdh
                STB     A, off(0029bh)
                SJ      tps_table_gate

tps_rate_check1:     LB      A, off(00235h)
                SUBB    A, off(0029bh)
                MB      PSWL.4, C
                JGE     tps_rate_mode_select
                VCAL    6

tps_rate_mode_select:     MOVB    r0, #090h
                JBS     off(0021bh).4, tps_rate_mul_apply
                MOVB    r0, #060h

tps_rate_mul_apply:     MULB
                MB      C, PSWL.4
                JLT     tps_rate_sub_apply
                ADD     off(0029ah), A
                SJ      tps_rate_check2

tps_rate_sub_apply:     SUB     off(0029ah), A

tps_rate_check2:     LB      A, off(0029bh)
                SUBB    A, off(00235h)
                MB      off(002edh).7, C
                JGE     tps_rate_store
                VCAL    6

tps_rate_store:     STB     A, r0

tps_table_gate:     JBS     off(0021ch).0, tps_interp_exact_match
                JBR     off(0021ah).1, tps_interp_exact_match
                MOVB    r4, #0ffh
                LB      A, 0bdh
                MOV     DP, #tbl_tps_custom_curve2
                MOV     X1, #tbl_tps_custom_curve
                CMPB    A, #090h
                JGE     tps_table_offset_check
                INC     DP
                INC     DP
                CMPB    A, #040h
                JGE     tps_table_offset_check
                INC     DP
                INC     DP

tps_table_offset_check:     JBS     off(002edh).7, tps_table_lookup
                INC     X1
                INC     X1
                INC     DP

tps_table_lookup:     LC      A, [X1]
                CMPB    A, r0
                JLT     tps_interp_clamp_check

tps_interp_exact_match:     LB      A, r1
                SJ      tps_interp_store

tps_interp_clamp_check:     LB      A, ACCH
                CMPB    A, r0
                JGE     tps_interp_weight_calc
                STB     A, r0

tps_interp_weight_calc:     LCB     A, [DP]
                MULB
                L       A, ACC
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                ST      A, er1
                LB      A, r3
                JNE     tps_interp_zero_check
                LB      A, r1
                JBR     off(002edh).7, tps_interp_sub_check
                ADDB    A, r2
                JLT     tps_interp_clamp_result
                SJ      tps_interp_range_check

tps_interp_sub_check:     SUBB    A, r2
                JLT     tps_interp_zero_check

tps_interp_range_check:     CMPB    A, r4
                JLE     tps_interp_store

tps_interp_clamp_result:     LB      A, r4
                SJ      tps_interp_store

tps_interp_zero_check:     CLRB    A
                JBS     off(002edh).7, tps_interp_clamp_result

tps_interp_store:     STB     A, 0bfh
                L       A, 0c4h
                SUB     A, off(0025ah)
                MB      off(0021ah).4, C
                MOV     er0, #00300h
                JGE     rpm_avg_range_check
                VCAL    7
                MOV     er0, #00300h

rpm_avg_range_check:     CMP     A, er0
                JLT     rpm_avg_store
                L       A, er0

rpm_avg_store:     ST      A, 0cah
                LB      A, #0c2h
                JBS     off(00218h).5, threshold_bank_218_5
                LB      A, #0c6h

threshold_bank_218_5:     CMPB    A, off(00236h)
                MB      off(00218h).5, C
                LB      A, #03ah
                JBS     off(00217h).0, threshold_bank_217_0
                LB      A, #040h

threshold_bank_217_0:     CMPB    A, off(00236h)
                MB      off(00217h).0, C
                CAL     mode_flag_409_5_check
                MOV     X1, #P_LO_Scaler
                JGE     lo_scaler_lookup
                MOV     X1, #S_LO_Scaler

lo_scaler_lookup:     MOVB    r3, (001e7h-00180h)[USP]
; ============================================================================================
; VE MAP SCALER calculation (0x9EE-0xA5B+):
; (tbl_ve_map_scalar/VEMapScalar, the 24-byte table
; data). Uses P_LO_Scaler/S_LO_Scaler, P_HI_Scaler/S_HI_Scaler, VE_SCALER,
; P_MAP_Scaler/S_MAP_Scaler (all real calibration fields -- S_MAP_Scaler is the exact field
; ============================================================================================
                MOVB    r2, off(00236h)
                MOVB    r6, #012h
                MB      C, 0b8h.3
                MB      PSWL.4, C
                CAL     scaler_table_lookup
                STB     A, (001eah-00180h)[USP]
                LB      A, r6
                STB     A, (001e7h-00180h)[USP]
                MB      C, [DP].5
                MOV     X1, #P_HI_Scaler
                JGE     hi_scaler_lookup
                MOV     X1, #S_HI_Scaler

hi_scaler_lookup:     MOVB    r3, (001e8h-00180h)[USP]
                MOVB    r2, 0c2h
                MOVB    r6, #012h
                MB      C, 0b8h.3
                MB      PSWL.4, C
                CAL     scaler_table_lookup
                STB     A, (001ech-00180h)[USP]
                LB      A, r6
                STB     A, (001e8h-00180h)[USP]
                MOV     X1, #VE_SCALER
                MOVB    r3, (001e9h-00180h)[USP]
                MOVB    r2, 0c2h
                MOVB    r6, #00dh
                MB      C, 0b8h.3
                MB      PSWL.4, C
                CAL     scaler_table_lookup
                STB     A, (001eeh-00180h)[USP]
                LB      A, r6
                STB     A, (001e9h-00180h)[USP]
                CAL     loadindex_bit_dispatch
                STB     A, r2
                CAL     mode_flag_409_5_check
                MOV     X1, #P_MAP_Scaler
                JGE     map_scaler_lookup
                MOV     X1, #S_MAP_Scaler

map_scaler_lookup:     MOVB    r3, (001dfh-00180h)[USP]
                MOVB    r6, #016h
                RB      PSWL.4
                CAL     scaler_table_lookup
                STB     A, (001e2h-00180h)[USP]
                LB      A, r6
                STB     A, (001dfh-00180h)[USP]
                LB      A, 0bbh
                STB     A, r2
                MOV     X1, #P_MAP_Scaler
                MOVB    r3, (001e6h-00180h)[USP]
                MOVB    r6, #016h
                RB      PSWL.4
                CAL     scaler_table_lookup
                STB     A, (001e4h-00180h)[USP]
                LB      A, r6
                STB     A, (001e6h-00180h)[USP]
                CLR     er2
                SC
                JBR     off(00227h).6, mode_flags_pack4
                LB      A, (001dfh-00180h)[USP]
                ADDB    A, #001h
                CMPB    0bfh, #000h
                JNE     mode_flags_pack_start
                CLRB    A

mode_flags_pack_start:     MOV     er0, off(00212h)
                AND     er0, #0c3bch
                JNE     mode_flags_pack_alt
                JBR     off(00214h).5, mode_flags_pack_store

mode_flags_pack_alt:     LB      A, #00fh

mode_flags_pack_store:     STB     A, r1
                RC
                JBS     off(00214h).5, mode_flags_pack2
                MB      C, off(00211h).1

mode_flags_pack2:     MB      off(00233h).3, C
                MB      C, off(0021ch).2
                MB      off(00233h).4, C
                SC
                LB      A, (001a4h-00180h)[USP]
                JNE     mode_flags_pack3
                MB      C, off(00220h).1

mode_flags_pack3:     MB      off(00233h).5, C
                LB      A, off(00233h)
                MOVB    r0, #010h
                MULB
                ORB     A, r1
                L       A, ACC
                ST      A, er2
                MOV     er0, #00101h
                MOVB    r2, #005h

scale_div32_loop:     SRL     A
                ADCB    r0, #000h
                SRL     A
                ADCB    r1, #000h
                DECB    r2
                JNE     scale_div32_loop
                SRLB    r0
                MB      r5.2, C
                SRLB    r1
                MB      r5.3, C
                LB      A, (001d3h-00180h)[USP]
                CMPB    A, #007h
                JLT     mode_flags_pack4
                LB      A, (001dbh-00180h)[USP]
                CMPB    A, #019h
                JLT     mode_flags_pack4
                MB      C, off(0021dh).7

mode_flags_pack4:     MB      off(00233h).6, C
                L       A, er2
                ST      A, 0eah
                MOV     DP, #003cah
                LB      A, ADCR0H
                CAL     ect_smooth_helper
                STB     A, [DP]
                STB     A, 0dah
                MOV     DP, #003d2h
                LB      A, ADCR1H
                STB     A, [DP]
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      ADSCAN.4
                ORB     P2, off(00257h)
                RB      IRQH.4
                SB      ADSCAN.4
                MOV     off(00258h), TM2
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JBS     off(0021dh).4, ignmap_alt_path
                JBS     off(00212h).2, ignmap_dp_gate
                JBR     off(00212h).4, ignmap_table_select

ignmap_dp_gate:     JBS     off(00218h).0, ignmap_alt_value

ignmap_alt_value:     LB      A, #05ah
                SJ      ignmap_result_common

ignmap_table_select:     CAL     mode_flag_409_5_check
; --- Base ignition timing map lookup (0x0B20-0x0B6A): this is the actual IGN1_Lo/IGN2_Lo/
; IGN1_Hi/IGN2_HI (real calibration fields) table lookup referenced back at ignmap_lookup_done
; in the ignition-timing pipeline documented earlier this session. Selects Lo vs Hi and
; primary(1) vs secondary(2) tables via mode_flag_409_5_check and other gates, interpolates
; via table2d_lookup_interp (RPM x Load), producing the base ignition timing value.
                MOVB    r0, #018h
                MOVB    r1, #014h
                MOVB    r2, (001dfh-00180h)[USP]
                MOV     X2, (001e2h-00180h)[USP]
                MOVB    r3, (001e7h-00180h)[USP]
                MOV     er3, (001eah-00180h)[USP]
                MOV     X1, #IGN1_Lo
                JGE     ignmap_hi_gate1
                MOV     X1, #IGN2_Lo

ignmap_hi_gate1:     JBR     off(00214h).5, ignmap_hi_gate2
                JBS     off(00218h).5, ignmap_2d_lookup

ignmap_hi_gate2:     JBR     off(0021fh).1, ignmap_2d_lookup
                MOVB    r1, #014h
                MOVB    r3, (001e8h-00180h)[USP]
                MOV     er3, (001ech-00180h)[USP]
                MB      C, [DP].5
                MOV     X1, #IGN1_Hi
                JGE     ignmap_2d_lookup
                MOV     X1, #IGN2_HI

ignmap_2d_lookup:     RB      PSWL.5
                CAL     table2d_lookup_interp
                MOVB    r0, A
                LB      A, off(00245h)
                JEQ     ignmap_scale_skip
                MULB
                MOVB    r0, ACCH

ignmap_scale_skip:     LB      A, r0
                SJ      ignmap_result_common

ignmap_alt_path:     CLRB    A

ignmap_result_common:     STB     A, off(00246h)
                LCB     A, idleigncheck
                JEQ     idleign_result_store
                LCB     A, IDLEignECT
                CMPB    0d9h, A
                CLRB    A
                JGE     idleign_result_store
                JBR     off(00218h).0, idleign_result_store
                JBS     off(00221h).6, idleign_result_store
                L       A, 0cah
                MOV     X1, #IgnControl
                JBS     off(0021ah).4, idleign_table_lookup
                MOV     X1, #HiIdleIgnControl

idleign_table_lookup:     CAL     table_interp_lookup_4byte
                MOVB    r0, #00eh
                LB      A, r6
                CMPB    A, r0
                JLT     idleign_vcal6_check
                LB      A, r0

idleign_vcal6_check:     JBR     off(0021ah).4, idleign_result_store
                VCAL    6

idleign_result_store:     STB     A, off(00241h)
                LB      A, #01eh
                JBS     off(00221h).3, rpm_threshold_221_3
                LB      A, #00ch

rpm_threshold_221_3:     CMPB    0c5h, A
                MB      off(00221h).3, C
                LB      A, #001h
                JBS     off(00221h).4, rpm_threshold_221_4
                LB      A, #002h

rpm_threshold_221_4:     CMPB    A, off(00236h)
                MB      off(00221h).4, C
                CLRB    A
                MOV     X1, #tbl_ignmap_idle2
                JBS     off(00221h).2, knockretard_table_gate
                INC     X1
                INC     X1
                MB      C, off(00221h).3

knockretard_table_gate:     JGE     knockretard_store
                CLR     A
                ST      A, er3
                LB      A, off(00235h)
                CAL     knockretard_helper
                JBR     off(00221h).2, knockretard_store
                STB     A, r5
                LB      A, off(00236h)
                MOV     X1, #tbl_knockretard
                CAL     table_interp_lookup
                MOVB    r0, r5
                MULB
                SLLB    A
                LB      A, ACCH
                ROLB    A
                MB      C, ACC.7
                JGE     knockretard_vcal6_check
                LB      A, #07fh

knockretard_vcal6_check:     VCAL    6

knockretard_store:     STB     A, off(00240h)
                LB      A, #01ah
                JBS     off(00222h).5, rpm_threshold_222_5
                LB      A, #027h

rpm_threshold_222_5:     CMPB    A, off(00236h)
                MB      off(00222h).5, C
                CLRB    A
                JBR     off(00227h).7, knockretard2_store
                JBS     off(00213h).1, knockretard2_store
                JGE     knockretard2_store
                CMPB    0d8h, #0a1h
                JGE     knockretard2_store
                JBS     off(0021dh).5, knockretard2_store
                JBS     off(0021ah).3, knockretard2_store
                JBR     off(0021ah).2, knockretard2_store
                CLR     A
                LB      A, off(00254h)
                MOV     er3, A
                LB      A, off(00235h)
                MOV     X1, #tbl_ignmap_idle1
                CAL     knockretard_helper
                LB      A, off(00238h)
                ADDB    A, #001h
                JLT     knockretard2_clamp
                CMPB    A, r6
                JLT     knockretard2_store

knockretard2_clamp:     LB      A, r6

knockretard2_store:     STB     A, off(00238h)
                CLRB    A
                RC
                JBS     off(00233h).6, flags_pack_233_7
                JBS     off(00212h).3, flags_pack_233_7
                JBS     off(00213h).0, flags_pack_233_7
                L       A, 0ech
                ST      A, er2
                CLR     er0
                MOVB    r2, #005h

scale_shift_loop:     SLL     A
                ADCB    r1, #000h
                SLL     A
                ADCB    r0, #000h
                DECB    r2
                JNE     scale_shift_loop
                SLL     A
                JGE     scale_direction_toggle
                SLL     A
                JGE     scale_direction_toggle
                L       A, er0
                AND     A, #00101h
                JNE     scale_result_common

scale_direction_toggle:     XORB    PSWH, #080h

scale_result_common:     LB      A, r5

flags_pack_233_7:     MB      off(00233h).7, C
                SRLB    A
                MB      off(00232h).7, C
                STB     A, r5
                CLRB    A
                JBR     off(00227h).6, knock_244_store
                CMPB    0c5h, #00dh
                JGT     knock_244_store
                LB      A, 0eah
                ANDB    A, #00fh
                CMPB    A, #00fh
                JEQ     knock_244_table_select
                JBS     off(00214h).7, knock_244_table_select
                JBS     off(00233h).6, flags_pack_sj
                JBS     off(00233h).7, flags_pack_sj
                LB      A, r5
                SJ      knock_244_store

knock_244_table_select:     LB      A, (001e8h-00180h)[USP]
                MOV     er0, (001ech-00180h)[USP]
                MOV     DP, #tbl_knock244_a
                JBS     off(0021fh).1, knock_244_lookup
                LB      A, (001e7h-00180h)[USP]
                MOV     er0, (001eah-00180h)[USP]
                MOV     DP, #tbl_knock244_b

knock_244_lookup:     CAL     knock_244_helper

knock_244_store:     STB     A, off(00244h)

flags_pack_sj:     SJ      tipin_tps_check

tipin_tps_check:     LB      A, #0ffh
                CMPB    0beh, A
                MOV     X1, #TipinTPS
                LB      A, off(00236h)
                CAL     table_interp_lookup
                CMPB    A, 0d3h
                MB      off(00231h).6, C
                L       A, off(00212h)
                AND     A, #08074h
                JNE     tipin_gate_fail
                JBS     off(00214h).0, tipin_gate_fail
                JBS     off(0021dh).4, tipin_gate_fail
                CMPB    0d9h, #034h
                JGE     tipin_gate_fail
                LB      A, 0cch
                CMPB    A, #00ah
                JLT     tipin_gate_fail
                CMPB    A, #08ch
                JGE     tipin_gate_fail
                LB      A, off(00236h)
                CMPB    A, #040h
                JLT     tipin_gate_fail
                CMPB    A, #0c8h
                JGE     tipin_gate_fail
                JBS     off(00220h).0, tipin_gate_pass
                JBR     off(00231h).6, tipin_gate2
                LB      A, off(00237h)
                JNE     tipin_decay_check

tipin_gate_fail:     RB      off(00220h).0
                RB      off(00220h).2
                SJ      tipin_decay_zero

tipin_gate2:     JBR     off(0021bh).1, tipin_decay_zero
                CMPB    0d5h, #008h
                JLT     tipin_decay_zero

tipin_gate_pass:     SB      off(00220h).0
                JBS     off(0021bh).6, tipin_enrich_lookup
                CMP     0c6h, #0ffffh
                JGE     tipin_decay_zero

tipin_enrich_lookup:     LB      A, off(0024fh)
; --- Tip-in enrichment (0x0CF5-0x0D4E): TipinEnrich[gear] (real field, gear-indexed) sets a
; decay counter (0x24E), and TipinRPM (real field) via table_interp_lookup scales the
; enrichment amount, clamped to 0xFFFF. tipin_decay_* then counts the enrichment back down
; over time. This is the concrete implementation tying together TipinTPS/TipinGear referenced
; elsewhere in the tip-in acceleration enrichment chain named earlier this session.
                EXTND
                LCB     A, TipinEnrich[ACC]
                MOVB    off(0024eh), A
                MOV     X1, #TipinRPM
                LB      A, off(00236h)
                CAL     table_interp_lookup
                MOVB    r0, off(00250h)
                MULB
                L       A, ACC
                SLL     A
                JGE     tipin_enrich_clamp
                L       A, #0ffffh

tipin_enrich_clamp:     LB      A, ACCH
                RB      off(00220h).0

tipin_decay_check:     CMPB    off(0024eh), #000h
                JEQ     tipin_decay_gate1
                DECB    off(0024eh)
                MOVB    r0, #001h
                SJ      tipin_decay_sub

tipin_decay_gate1:     JBS     off(0021bh).6, tipin_decay_gate2
                CMP     0c6h, #00010h
                JLT     tipin_decay_gate3
                RB      off(00220h).2

tipin_decay_common:     RC
                SJ      tipin_decay_flag3

tipin_decay_gate2:     CMP     0c6h, #00003h
                JGE     tipin_decay_gate4

tipin_decay_gate3:     JBS     off(00220h).2, tipin_decay_common
                SJ      tipin_decay_sc

tipin_decay_gate4:     SB      off(00220h).2

tipin_decay_sc:     SC

tipin_decay_flag3:     MB      off(00220h).3, C
                JGE     tipin_decay_rc
                MOVB    r0, #003h

tipin_decay_sub:     SUBB    A, r0
                JLT     tipin_decay_zero
                SC
                SJ      tipin_decay_store

tipin_decay_zero:     CLRB    A

tipin_decay_rc:     RC

tipin_decay_store:     STB     A, off(00237h)
                MB      off(00220h).1, C
                LB      A, #041h
                JBS     off(002eeh).0, vss_threshold_2ee_0
                LB      A, #046h

vss_threshold_2ee_0:     CMPB    A, 0cch
                MB      off(002eeh).0, C
                LB      A, #000h
                JBS     off(00222h).4, knock244_threshold_check
                LB      A, #00bh

knock244_threshold_check:     CMPB    A, off(00244h)
                MB      off(00222h).4, C
                MOVB    r0, #03fh
                MOVB    r1, #003h
                MOVB    r2, #02ah
                MOVB    r3, #00ch
                JGE     rpm_gate_2d99
                MOVB    r1, #006h
                MOVB    r2, #033h

rpm_gate_2d99:     JBS     off(00212h).6, gate_255_common
                JBS     off(0021dh).4, gate_255_common
                CMPB    0d9h, #034h
                JGE     gate_255_common
                JBS     off(002eeh).0, gate_255_common
                LB      A, r0
                CMPB    A, off(00236h)
                JLT     gate_255_common
                JBS     off(00231h).6, gate_255_common
                CLRB    A
                JBR     off(0021bh).1, store_255_result
                CMPB    0d5h, #010h
                JLT     store_255_result
                LB      A, r1
                ADDB    A, #001h


store_255_result:     STB     A, off(00255h)

gate_255_common:     LB      A, r2
                CMPB    off(00255h), #000h
                JEQ     track239e_check
                DECB    off(00255h)
                SJ      dwell_base_lookup

track239e_check:     LB      A, off(0023eh)
                SUBB    A, r3
                JGE     dwell_base_lookup
                CLRB    A

dwell_base_lookup:     STB     A, off(0023eh)
; --- Ignition dwell time calculation (0x0DBA-0x0DE8): DwellBaseRPM/DwellBaseValues (real
; calibration fields) compute the base coil dwell time by RPM, combined with dwell_scale_helper
; scaling. Followed by TipinRetard (real field) -- ignition retard applied during throttle
; tip-in, scaled by the tip-in enrichment amount (off(00237h)) computed earlier.
                LB      A, 0c2h
                MOV     X1, #DwellBaseRPM
                CAL     table_interp_lookup
                STB     A, off(00247h)
                LB      A, 0c2h
                MOV     X1, #DwellBaseValues
                CAL     table_interp_lookup
                MOV     DP, #0035ah
                STB     A, [DP]
                STB     A, r0
                LB      A, off(0024bh)
                MULB
                L       A, ACC
                ST      A, er1
                CAL     dwell_scale_helper
                ST      A, off(0024ch)
                RC
                L       A, er1
                JLT     dwell_scale_shift
                SRL     A

dwell_scale_shift:     SRL     A
                CAL     dwell_scale_helper
                ST      A, off(0024dh)
                CLRB    A
                STB     A, off(0024ah)
                RB      PSWL.4
                CLR     A
                ST      A, er3
                JBS     off(00212h).5, ign_sum_stage4
                JBR     off(00220h).1, tipin_retard_common
                LB      A, 0d1h
                MOV     X1, #TipinRetard
                CAL     table_interp_lookup
                MOVB    r0, off(00237h)
                MULB
                L       A, ACC
                SLL     A
                MOVB    r6, ACCH
                CLRB    r7
                CLR     A

tipin_retard_common:     CLRB    A
                ADD     er3, A
                CLR     A
                ST      A, er2
                LB      A, #000h
                ADD     er2, A
                LB      A, off(0023eh)
                ADD     er2, A
                MOV     er1, er2
                JBR     off(00240h).7, tipin_retard_er2_calc
                CLRB    A
                SUBB    A, off(00240h)
                ADD     er2, A

tipin_retard_er2_calc:     LB      A, off(00244h)
; --- Final ignition timing summation (0x0E24-0x0E88): combines all the individually
; computed ignition corrections named throughout this session -- knock retard (0x244),
; anti-lag/lock/FTS-mode result (0x240/241/242/243), and the base ignmap result (0x246) --
; into one final clamped (0x00-0xFF) ignition timing value. This is where the whole ignition
; timing pipeline traced earlier actually converges into the value fed to
; ign_angle_to_timer_convert for hardware output.
                ADD     er2, A
                L       A, er2
                CMP     A, er3
                MB      PSWL.4, C
                JLT     ign_sum_stage1
                MOV     er3, er1

ign_sum_stage1:     LB      A, off(00238h)
                ADD     er3, A
                CMPB    0d9h, #000h
                JGE     ign_sum_negate
                JBR     off(00218h).0, ign_sum_negate
                LB      A, #000h
                ADD     er3, A

ign_sum_negate:     CLR     A
                SUB     A, er3
                ST      A, er3
                JBR     off(00240h).7, ign_sum_stage2
                MB      C, PSWL.4
                JLT     ign_sum_stage3

ign_sum_stage2:     LB      A, off(00240h)
                EXTND
                ADD     er3, A

ign_sum_stage3:     LB      A, off(00241h)
                EXTND
                ADD     er3, A
                LB      A, off(00242h)
                EXTND
                ADD     er3, A

ign_sum_stage4:     LB      A, off(00243h)
                EXTND
                ADD     er3, A
                MB      C, PSWL.4
                JLT     ign_sum_final_add
                CLR     A
                LB      A, off(00244h)
                SUB     er3, A

ign_sum_final_add:     CLR     A
                LB      A, off(00246h)
                STB     A, r0
                L       A, ACC
                ADD     A, er3
                JBR     off(00207h).7, ign_sum_clamp_check
                JLT     ign_sum_result
                CLRB    A
                SJ      ign_sum_result

ign_sum_clamp_check:     CMP     A, #000ffh
                JLT     ign_sum_result
                LB      A, #0ffh

ign_sum_result:     LB      A, ACC
                STB     A, r4
                LB      A, #040h
                JBS     off(002ech).0, ign_sum_common
                LB      A, #045h

ign_sum_common:     CMPB    A, off(00236h)
                MB      off(002ech).0, C
                LB      A, #040h
                SC
                JBS     off(00212h).5, ign_p40_flag_store
                CMPB    0d9h, #0cfh
                JLT     ign_p40_flag_store
                MB      C, P4.0
                JLT     ign_p40_store
                JBS     off(00221h).7, ign_result_clamp249
                LB      A, #000h
                MB      C, off(0021eh).0
                JLT     ign_p40_store
                JBS     off(002ech).0, ign_p40_toggle
                LB      A, off(00249h)
                ADDB    A, #002h
                JGE     ign_p40_clamp
                LB      A, #0ffh

ign_p40_clamp:     CMPB    A, r4
                JGE     ign_p40_toggle
                STB     A, r4

ign_p40_store:     STB     A, off(00249h)

ign_p40_toggle:     XORB    PSWH, #080h

ign_p40_flag_store:     MB      off(00221h).7, C

ign_result_clamp249:     MOVB    r3, off(0024ah)
                LB      A, r4
                CMPB    A, r3
                JGE     ign_result_clamp_common
                LB      A, r3

ign_result_clamp_common:     RC
                JBS     off(00217h).0, ign_flag_217_1
                LB      A, ACC
                JNE     ign_flag_217_1
                SC

ign_flag_217_1:     MB      off(00217h).1, C
                JBS     off(0021eh).0, ign_result_zero
                JBR     off(00217h).1, ign_result_add_247

ign_result_zero:     CLRB    A
                STB     A, off(00248h)
                SJ      ignmap_lookup_done

ign_result_add_247:     ADDB    A, off(00247h)
                JGE     ignmap_disable_check
                LB      A, #0ffh

ignmap_disable_check:     STB     A, r0
                LCB     A, DisableIGNMAP
                JEQ     ignmap_lookup_done
                CLR     A
                LCB     A, IGNMAP
                CMPB    0bbh, A
                JLE     ignmap_lookup_done
                CLR     A
                LB      A, off(00246h)
                ADDB    A, off(00247h)
                JGE     ignmap_result_r0
                LB      A, #0ffh

ignmap_result_r0:     STB     A, r0

ignmap_lookup_done:CAL     hts_tc_apply             ; HTS120 hook
                MOV     DP, #00409h
                MB      C, [DP].1
                JGE     igntiming_lockcheck
                MB      C, [DP].0
                JLT     antilag_active_check
                MB      C, [DP].2
                JLT     ftsstaticign_check
                SJ      igntiming_lockcheck

antilag_active_check:     LCB     A, AntiLagStatic
                MB      C, ACC.0
                JGE     antilag_retard_normal
                LCB     A, AntiLagRetardDegree
                MOVB    r0, A
                SJ      igntiming_target_store

antilag_retard_normal:     LCB     A, AntiLagRetard
                SJ      igntiming_target_calc

ftsstaticign_check:     LCB     A, FTSchkStatic
                MB      C, ACC.0
                JGE     ftsstaticign_normal
                LCB     A, tbl_fts_static_ign
                MOVB    r0, A
                SJ      igntiming_target_store

ftsstaticign_normal:     LCB     A, FTSStaticIgn
                SJ      igntiming_target_calc

igntiming_target_calc:     SUBB    r0, A
                JGE     igntiming_target_final
                CLRB    r0
                SJ      igntiming_target_final

igntiming_lockcheck:     LCB     A, Lockigndeg
; --- Ignition timing target selection + lock/anti-lag override (0x0EFF-0x0F8Fish). Dispatch
; via 3 flag bits at off(00409h).0/.1/.2 (mode flags maintained elsewhere): bit1 set -> skip
; straight to lock-check; bit0 set -> antilag_active_check (turbo anti-lag retard, using
; AntiLagStatic/AntiLagRetardDegree/AntiLagRetard); bit2 set -> ftsstaticign_check (flex-fuel
; static ignition override, FTSchkStatic/FTSStaticIgn/tbl_fts_static_ign); neither -> normal path.
; igntiming_target_calc computes the final target retard/advance in r0.
; igntiming_lockcheck/ignsynclock_check: Lockigndeg + IgnSyncLock gate a fixed Lockdeg value
; overriding the computed target entirely (diagnostic/dyno-tuning ignition lock feature).
; igntiming_ramp_step then steps the actual applied timing toward the target gradually
; rather than jumping instantly (0x246/0x247/0x248 working values), avoiding abrupt
; ignition-timing changes.
                JEQ     ignsynclock_check
                MB      C, off(00221h).6
                JLT     igntiming_locked_value

ignsynclock_check:     LCB     A, IgnSyncLock
                JEQ     igntiming_target_final

igntiming_locked_value:     LCB     A, Lockdeg

igntiming_target_store:     STB     A, r0
                CLRB    A
                STB     A, off(00246h)
                STB     A, off(00247h)

igntiming_ramp_step:     MOVB    A, r0
                STB     A, off(00248h)
                SUBB    A, off(00247h)
                JGE     igntiming_cylinder_trim_add
                CLRB    A
                SJ      igntiming_cylinder_trim_add

igntiming_target_final:     MOV     DP, #000e6h
                L       A, [DP]
                JNE     igntiming_icfuelmod_check
                SJ      igntiming_ramp_step

igntiming_icfuelmod_check:     LCB     A, ICFuelMod
                JEQ     igntiming_ramp_step
                LCB     A, IGNCDEG
                MOVB    r0, A
                SJ      igntiming_target_store

igntiming_cylinder_trim_add:     MOVB    r0, A
                CLR     A
                CLR     X1
                LB      A, 0043ch[X1]
                ADDB    A, r0
                JGE     igntiming_output_coil1
                LB      A, #0ffh
                STB     A, off(00248h)
                SJ      igntiming_output_coil1

igntiming_output_coil1:     MOV     DP, #0035bh
                STB     A, [DP]
                MOVB    r2, off(00248h)
                MOVB    r4, off(0024ch)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #00357h
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                MB      0b8h.0, C
                STB     A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MOVB    r4, off(0024dh)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #0035dh
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                MB      0b8h.1, C
                ST      A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MOV     LRB, #00020h
                MOV     USP, #00280h
                CAL     refresh_engine_flags_snapshot
                MOV     DP, #0040eh
                MB      C, [DP].2
                JGE     igntiming_enable_pin_check
                INC     DP
                MB      C, [DP].2
                XORB    PSWH, #080h
                SJ      igntiming_enable_pin_drive

igntiming_enable_pin_check:     SC
                JBR     off(0011eh).6, igntiming_enable_pin_drive
                JBR     off(00121h).2, igntiming_enable_pin_drive
                MB      C, 0b8h.2
                XORB    PSWH, #080h

igntiming_enable_pin_drive:     MB      P1.2, C
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, P1
                MOV     DP, #02f00h
                STB     A, [DP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                L       A, #01d4ch
                JBS     off(00129h).1, vtec_rawperiod_threshold_check
                L       A, #00b03h

vtec_rawperiod_threshold_check:     CMP     0c4h, A
; --- VTEC engagement debounce + engagement-transition ignition retard (0x1021-0x10EB),
; feeding directly into the confirmed VTEC engagement-gate logic below (vtec_engage_gate_start
; onward, which does reference real VtecVSSMin/VtecDelay/VtecSettings/etc. calibration fields
; -- confirming this identification). A debounce counter (0xD7) gates a state value in r1
; (0/1/2/4-ish) stored to off(001A4h) -- consistent with an OFF/engaging/ON progression. Once
; state-confirmed, a countdown timer (off(001A6h), initialized to 12) gates a lookup into
; tbl_vtec_transition_retard indexed by state, storing to off(001A5h) -- likely a temporary ignition retard
; applied during the cam-profile-switch transition (exact use of off(001A5h) downstream not
; separately re-verified here).
                MB      off(00129h).1, C
                JBR     off(0011eh).5, vtec_state_reset_low_rpm
                CLRB    A
                STB     A, 0d7h
                RB      off(00126h).2
                LB      A, #000h
                JBS     off(0011fh).5, vtec_state_reset_low_rpm
                JBR     off(00122h).6, vtec_state_reset_low_rpm
                JBS     off(00122h).7, vtec_state_reset_low_rpm
                JBR     off(00126h).2, vtec_state_reset_low_rpm
                JBS     off(00120h).2, vtec_oilpressure_gate_check

vtec_state_reset_low_rpm:     MOVB    off(001bdh), #000h
                J       vtec_state_clear

vtec_oilpressure_gate_check:     JBR     off(0011dh).1, vtec_debounce_counter_check
                SJ       vtec_oilpressure_pin_check

vtec_debounce_counter_check:     CMPB    0d7h, #0ffh
                JGT     vtec_oilpressure_pin_check
                CMPB    0d7h, #000h
                JLT     vtec_oilpressure_pin_check
                STB     A, off(001bdh)
                MOVB    r1, off(001a4h)
                LB      A, off(001a2h)
                JNE     vtec_debounce_step_calc
                LB      A, #000h
                SJ      vtec_debounce_store

vtec_debounce_step_calc:     SUBB    A, #001h
                JBR     off(00124h).0, vtec_debounce_store
                SUBB    A, #001h
                JLT     vtec_debounce_zero
                JBR     off(00124h).1, vtec_debounce_store
                SUBB    A, #002h
                JGE     vtec_debounce_store

vtec_debounce_zero:     CLRB    A

vtec_debounce_store:     STB     A, off(001a2h)
                SJ      vtec_rpm_valid_check

vtec_oilpressure_pin_check:     MB      C, P4.6
                JGE     vtec_state_dispatch
                STB     A, off(001bdh)

vtec_state_reset_no_pressure:     MOVB    off(001beh), #000h
                MOVB    r1, #004h
                SJ      vtec_rpm_valid_check

vtec_state_dispatch:     LB      A, off(001bdh)
                JNE     vtec_state_reset_no_pressure
                LB      A, off(001beh)
                JEQ     vtec_state_clear
                MOVB    r1, #002h

vtec_rpm_valid_check:     CMPB    off(currentRPMByte), #0ffh
                JLT     vtec_state_hold_check
                LB      A, r1
                CMPB    A, #001h
                JLE     vtec_state_active_check
                MOVB    off(001cfh), #000h
                SJ      vtec_state_store

vtec_state_hold_check:     JBS     off(00125h).4, vtec_state_confirm
                SJ      vtec_state_clear

vtec_state_active_check:     JBR     off(00125h).4, vtec_state_finalize

vtec_state_confirm:     LB      A, off(001cfh)
                JEQ     vtec_state_finalize
                MOVB    r1, #002h
                CLRB    off(001a2h)

vtec_state_store:     LB      A, r1
                STB     A, off(001a4h)
                SB      off(00125h).4
                JNE     vtec_retard_timer_check
                MOVB    off(001a6h), #00ch
                CLRB    off(001a5h)

vtec_retard_timer_check:     CMPB    off(001a6h), #008h
                JGT     vtec_retard_lookup_done
                CLR     A
                LB      A, r1
                SUBB    A, #002h
                MOV     DP, #tbl_vtec_transition_retard
                ADD     DP, A
                LCB     A, [DP]
                STB     A, off(001a5h)

vtec_retard_lookup_done:     SJ      vtec_engage_gate_start

vtec_state_clear:     CLRB    r1


vtec_state_finalize:     RB      off(00125h).4
                CLRB    A
                STB     A, off(001a2h)
                CMPB    r1, #001h
                JNE     vtec_state_store2
                LB      A, r1

vtec_state_store2:     STB     A, off(001a4h)

vtec_engage_gate_start:     JBR     off(0011eh).4, vtec_disengage_output
; --- VTEC engagement gate checks VSS
; (VtecVSSMin, with hysteresis), RPM against a VtecSettings table (VCAL 1) minus VtecDelay,
; and a DCode21 diagnostic-code gate, to decide engage (P1.1 set, vtec_engage_conditions_start)
; vs disengage (P1.1 clear, vtec_disengage_output). Once engage-conditions are entered, further
; gates on coolant temp (VtecTempCheck/VtecECTMin), VSS (VtecVSSCheck), and load (VtecLoadMin)
; drive P1.0 and set/clear off(00127h).1/.2 mode flags (chkHighCamOnly forces high-cam-only
; mode). Feeds directly into vtec_fuel_table_select, which picks between FUEL1_Hi/FUEL2_Hi
; base fuel tables based on the resulting cam state -- i.e. VTEC engagement here also selects
; a different base fuel map, not just cam profile/ignition.
                LCB     A, VtecVSSMin
                JBS     off(00131h).0, vtec_vss_hysteresis_store
                ADDB    A, #005h
                JGE     vtec_vss_hysteresis_store
                LB      A, #0ffh

vtec_vss_hysteresis_store:     CMPB    A, 0cch
                MB      off(00131h).0, C
                LCB     A, VtecDelay
                STB     A, r4
                LB      A, 0d1h
                MOV     X1, #VtecSettings
                VCAL    1
                JBR     off(00131h).2, vtec_rpm_vs_settings_check
                SUBB    A, r4

vtec_rpm_vs_settings_check:     CMPB    A, off(currentRPMByte)
                MB      off(00131h).2, C
                LCB     A, DCode21
                JNE     vtec_engage_conditions_start
                L       A, off(0011ah)
                AND     A, #0c0bch
                JNE     vtec_disengage_output
                LB      A, off(0011ch)
                ANDB    A, #031h
                JEQ     vtec_engage_conditions_start

vtec_disengage_output:     RB      P1.1
                SJ      vtec_highcam_output

vtec_engage_conditions_start:     SB      P1.1
                CMPB    0f3h, #032h
                JLT     vtec_highcam_output
                LCB     A, VtecTempCheck
                JNE     vtec_vsscheck
                LCB     A, VtecECTMin
                CMPB    0d9h, A
                JGE     vtec_highcam_output

vtec_vsscheck:     LCB     A, VtecVSSCheck
                JNE     vtec_loadmin_check
                JBR     off(00131h).0, vtec_highcam_output

vtec_loadmin_check:     LCB     A, VtecLoadMin
                CMPB    0bbh, A
                JLT     vtec_highcam_output
                JBS     off(00131h).2, vtec_highcam_force_on
                JBS     off(00127h).1, vtec_highcam_output

vtec_highcam_output:     RB      P1.0
                RB      off(00127h).2
                RB      off(00127h).1
                LCB     A, chkHighCamOnly
                JEQ     vtec_fuel_table_select
                SB      off(00127h).1
                SJ      vtec_fuel_table_select

vtec_highcam_force_on:     SB      P1.0
                SB      off(00127h).2
                SB      off(00127h).1

vtec_fuel_table_select:     CAL     mode_flag_409_5_check
; --- Main fuel injector pulse-width calculation (0x117A-0x122E+). Selects the base fuel
; table (FUEL1_Hi/FUEL2_Hi/FUEL1_Lo/FUEL2_Lo, chosen by VTEC cam state + a load/RPM crossover
; check) and interpolates it via table2d_lookup_interp (RPM x Load 2D table). Applies overall
; fuel trim (OverallFT) via mul_scale_clamp, then adds a mode-specific enrichment selected by
; the same off(00409h).0/.1/.2 dispatcher used for ignition timing: antilag enrichment
; (AntiLagFV), flex-fuel static enrichment (tbl_fts_fuel_enrich), or neither (normal). Adds a per-cylinder
; base trim (0x43A), conditionally adds ignition-cut fuel modifier (ICFuelMod/IGNCFV) when
; active, then applies the same gear-based correction pattern as the ignition path
; (GearCorrectVSS/GearCorrectMap gate GearCorrectFuel[gear]).
                MOVB    r0, #018h
                MOVB    r1, #014h
                MOVB    r2, off(001dfh)
                MOV     X2, off(001e2h)
                MOVB    r3, off(001e8h)
                MOV     er3, off(001ech)
                MOV     X1, #FUEL1_Hi
                JGE     fuel_hi_table_gate
                MOV     X1, #FUEL2_Hi

fuel_hi_table_gate:     JBR     off(0011ch).5, fuel_lo_table_check
                JBS     off(00120h).5, fuel_base_lookup_done

fuel_lo_table_check:     JBS     off(00127h).1, fuel_base_lookup_done
                MOVB    r1, #014h
                MOVB    r3, off(001e7h)
                MOV     er3, off(001eah)
                MB      C, [DP].5
                MOV     X1, #FUEL1_Lo
                JGE     fuel_base_lookup_done
                MOV     X1, #FUEL2_Lo

fuel_base_lookup_done:     SB      PSWL.5
                CAL     table2d_lookup_interp
                MOV     er0, A
                LC      A, OverallFT
                CAL     mul_scale_clamp
                MOV     X2, A
                CLR     A
                MOV     DP, #00409h
                MB      C, [DP].1
                JGE     fuel_mode_adjust_add
                MB      C, [DP].0
                JLT     fuel_antilag_enrich
                MB      C, [DP].2
                JLT     fuel_fts_enrich
                SJ      fuel_mode_adjust_add

fuel_antilag_enrich:     LC      A, AntiLagFV
                SJ      fuel_mode_adjust_add

fuel_fts_enrich:     LC      A, tbl_fts_fuel_enrich

fuel_mode_adjust_add:     ADD     X2, A
                CLR     X1
                L       A, 0043ah[X1]
                ADD     X2, A
                MOV     DP, #000e6h
                L       A, [DP]
                JNE     fuel_icfuelmod_check
                SJ      fuel_gearcorrect_check

fuel_icfuelmod_check:     LCB     A, ICFuelMod
                JEQ     fuel_gearcorrect_check
                LC      A, IGNCFV
                ADD     X2, A
                SJ      fuel_gearcorrect_check

fuel_gearcorrect_check:     LCB     A, GearCorrectVSS
                CMPB    0cch, A
                JLT     fuel_gearcorrect_disabled
                LCB     A, GearCorrectMap
                CMPB    0bbh, A
                JLT     fuel_gearcorrect_disabled
                CLR     A
                LB      A, (0024fh-00280h)[USP]
                LCB     A, GearCorrectFuel[ACC]
                STB     A, (0023bh-00280h)[USP]
                MB      C, PSWL.4
                JLT     gio1_fuel_adjust_check
                CLRB    ACCH
                L       A, ACC
                SWAP
                MOV     er0, A
                MOV     A, X2
                CAL     mul_scale_clamp
                MOV     X2, A
                SJ      gio1_fuel_adjust_check


fuel_gearcorrect_disabled:     LB      A, #080h
                STB     A, (0023bh-00280h)[USP]

gio1_fuel_adjust_check:     MOV     DP, #00410h
; --- GIO output-driven fuel adjustments: if GIO1/2/3's computed output is active
; (off(00410h).0/.1/.2, set by the aux_output_pin_drive-based GIO logic earlier), adds a
; VSS-indexed GIOAdjustment2 table lookup to the running fuel total (X2). Clamped non-negative
; (fuel_clamp_nonneg), then stored as the final base fuel/pulse-width value at off(00140h)
; (fuel_final_store). This lets a GIOx channel be configured as a fuel-adjustment trigger
; (e.g. nitrous/meth injection enrichment) in addition to its generic output-pin role.
                MB      C, [DP].0
                JGE     gio2_fuel_adjust_check
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment2
                VCAL    0
                SUBB    A, #000h
                DEC     X1
                ADD     X2, A

gio2_fuel_adjust_check:     MOV     DP, #00410h
                MB      C, [DP].1
                JGE     gio3_fuel_adjust_check
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment2
                VCAL    0
                SUBB    A, #000h
                DEC     X1
                ADD     X2, A

gio3_fuel_adjust_check:     MOV     DP, #00410h
                MB      C, [DP].2
                JGE     fuel_clamp_nonneg
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment2
                VCAL    0
                SUBB    A, #000h
                DEC     X1
                ADD     X2, A

fuel_clamp_nonneg:     CMP     X2, #08000h
                JLT     fuel_final_store
                CLR     X2

fuel_final_store:     L       A, X2
                ST      A, off(00140h)
                LB      A, off(00180h)
                JBS     off(0011fh).5, accel_iac_calc
                JBS     off(0012ch).4, fuel_timer_scale
                SJ      accel_iac_clamp_min

accel_iac_calc:     LB      A, off(00169h)
; --- Transient/acceleration enrichment tied to idle-air-control area (0x1279-0x1288): scales
; a working value (0x169) by 0x1F4 and clamps the result to a minimum of 0x40, stored back to
; off(00180h). Gated by off(0011fh).5/(0012ch).4 flags (mechanism confirmed, exact trigger
; condition not traced). fuel_timer_scale below then converts the resulting fuel value into
; the actual injector timer/pulse-width value via a chained multiply.
                STB     A, r0
                LB      A, off(001f4h)
                MULB
                LB      A, ACCH
                CMPB    A, #040h
                JGE     accel_iac_store

accel_iac_clamp_min:     LB      A, #040h

accel_iac_store:     STB     A, off(00180h)

fuel_timer_scale:     MOVB    r0, off(00181h)
                MULB
                MOVB    r1, off(0017fh)
                CLRB    r0
                MUL
                MOV     er0, er1
                L       A, off(0015ch)
                MUL
                MOV     off(00182h), er1
                LCB     A, FuelCutMAP
                CMPB    0bbh, A
                XORB    PSWH, #080h
                MB      off(00130h).5, C
                JBR     off(00124h).2, fuelcutmap_direction_common
                LCB     A, FuelCutMAP
                CMPB    0bbh, A
                XORB    PSWH, #080h

fuelcutmap_direction_common:     MB      off(0012eh).0, C
                LB      A, #003h
                JBS     off(001f8h).0, accel_decel_mode_select
                LB      A, #005h

accel_decel_mode_select:     CMPB    A, 0cch
; --- TPS tip-in acceleration enrichment (0x12C3-0x1448ish). Moderate-to-low confidence on
; individual flag bits (10+ untraced condition bytes: 0x11F/0x120/0x123/0x125/0x12C/0x1F8),
; but the overall identification is reasonably solid: tipin_rpm_gate directly uses the
; tpstipinrpm calibration field, and this block flows directly into the already-named
; StartCranking/SetCranking cranking-state labels just below it. Reads as: gate on VSS/RPM
; mode (accel_decel_mode_select/accelenrich_rpm_hysteresis), build a base enrichment value
; tiered by RPM (accelenrich_base_calc/rpm_tier1, subtracting 0x18 per RPM band crossed --
; 0xF0/0xC5/0xA0/0x70), look it up through tbl_tipin_enrich_rpm (accelenrich_table_lookup), then gate
; further on TPS tip-in RPM (tipin_rpm_gate) and a second table (tbl_tipin_secondary) before either
; continuing into normal running enrichment (accelenrich_cranking_gate -> tbl_tipin_normal_enrich) or falling
; into cranking prep. Treat the exact per-bit conditions as unconfirmed; the overall shape
; (transient TPS-tip enrichment feeding into cranking) is the higher-confidence part.
                MB      off(001f8h).0, C
                CMPB    off(currentRPMByte), #0a0h
                RB      PSWH.7
                MOVB    r0, 0d6h
                MB      C, off(00123h).2
                JEQ     accelenrich_rpm_mode_check
                MOVB    r0, 0d5h
                MB      C, off(00123h).1

accelenrich_rpm_mode_check:     JLT     accelenrich_flags_clear
                MOVB    r2, #008h
                MOVB    r3, #00ah
                JBR     off(001f8h).0, accelenrich_gate2_common
                LB      A, off(001c1h)
                JEQ     accelenrich_gate2_common
                MOVB    r2, #020h
                MOVB    r3, #020h

accelenrich_gate2_common:     LB      A, r2
                CMPB    A, r0
                MB      off(0012ch).1, C
                LB      A, r3
                CMPB    A, r0
                MB      off(0012ch).2, C
                RC
                SJ      accelenrich_mode_flag_store

accelenrich_flags_clear:     RB      off(0012ch).1
                RB      off(0012ch).2
                LB      A, #004h
                CMPB    A, r0

accelenrich_mode_flag_store:     MB      off(0012ch).0, C
                LB      A, #0c2h
                JBS     off(001f8h).3, accelenrich_rpm_hysteresis
                LB      A, #0c6h

accelenrich_rpm_hysteresis:     CMPB    A, off(currentRPMByte)
                MB      off(001f8h).3, C
                SJ      accelenrich_gate_chain

accelenrich_skip_to_gate2:     SJ       accelenrich_clear_pulse_check

accelenrich_gate_chain:     JBS     off(00125h).4, accelenrich_jump_cranking_path
                JBS     off(00119h).0, accelenrich_jump_cranking_path
                JBR     off(0012ch).0, accelenrich_skip_to_gate2
                JBR     off(00123h).3, accelenrich_jump_tipin_check
                LB      A, off(00188h)
                JBS     off(0012ch).3, accelenrich_table_lookup
                CMPB    0d3h, #0b0h
                JLT     accelenrich_base_calc

accelenrich_jump_cranking_path:     J       accelenrich_clear_and_cranking_prep

accelenrich_jump_tipin_check:     J       accelenrich_cranking_gate

accelenrich_base_calc:     CLRB    A
                JBR     off(00120h).1, accelenrich_base_adjust
                CMPB    0cch, #005h
                JLT     accelenrich_result_store

accelenrich_base_adjust:     ADDB    A, #06ch
                JBR     off(0012eh).4, accelenrich_rpm_tier1
                ADDB    A, #00ch

accelenrich_rpm_tier1:     CMPB    off(currentRPMByte), #0f0h
                JGE     accelenrich_result_store
                SUBB    A, #018h
                CMPB    off(currentRPMByte), #0c5h
                JGE     accelenrich_result_store
                SUBB    A, #018h
                CMPB    off(currentRPMByte), #0a0h
                JGE     accelenrich_result_store
                SUBB    A, #018h
                CMPB    off(currentRPMByte), #070h
                JGE     accelenrich_result_store
                SUBB    A, #018h

accelenrich_result_store:     STB     A, off(00188h)

accelenrich_table_lookup:     CLRB    ACCH
                MOV     X1, A
                ADD     X1, #tbl_tipin_enrich_rpm
                LB      A, r0
                VCAL    0
                MOV     er0, off(00182h)
                MUL
                SRL     er1
                RORB    A
                SRL     er1
                RORB    A
                LB      A, r2
                L       A, ACC
                SWAP
                CMP     A, off(00142h)
                JGE     accelenrich_clamp_check
                L       A, off(00142h)

accelenrich_clamp_check:     CMPB    r3, #000h
                JEQ     accelenrich_cranking_flag_set
                L       A, #0ffffh

accelenrich_cranking_flag_set:     MOVB    off(001c1h), #00ah
                J       cranking_flag_check

accelenrich_clear_pulse_check:     JBR     off(0012ch).2, tipin_rpm_gate
                CLR     off(00142h)

tipin_rpm_gate:     LCB     A, tpstipinrpm
                CMPB    off(currentRPMByte), A
                JLT     accelenrich_cranking_gate
                JBR     off(0012ch).1, tipin_gate_common
                JBR     off(00123h).3, tipin_gate_common
                CMPB    off(001c1h), #000h
                JEQ     tipin_table_select_low
                MOV     X1, #tbl_tipin_secondary
                SJ      tipin_table_lookup

tipin_table_select_low:     MOV     X1, #tbl_tipin_low
                CMPB    (0024fh-00280h)[USP], #003h
                JGE     tipin_table_gear_adjust
                ADD     X1, #00006h

tipin_table_gear_adjust:     CMPB    off(currentRPMByte), #08dh
                JGE     tipin_table_lookup
                SUB     X1, #0000ch

tipin_table_lookup:     LB      A, r0
                VCAL    2
                LB      A, ACC
                LCB     A, TPSTipOutTrim
                CAL     mulb_scale_clamp
                SJ      accelenrich_clear_0x165

tipin_gate_common:     LB      A, off(00165h)
                JEQ     accelenrich_cranking_gate
                ADDB    A, #002h
                JGE     accelenrich_clear_0x165

accelenrich_cranking_gate:     JBR     off(00120h).2, accelenrich_clear_and_cranking_prep
                L       A, off(00142h)
                JEQ     accelenrich_clear_and_cranking_prep
                ST      A, er3
                LB      A, off(00188h)
                EXTND
                MOV     DP, #tbl_tipin_normal_enrich
                ADD     DP, A
                LC      A, [DP]
                ST      A, er2
                CMP     A, er3
                LC      A, 00004h[DP]
                JLT     tipin_table_result_alt
                LC      A, 00002h[DP]
                ST      A, er2
                CMP     A, er3
                JLT     tipin_table_row2
                MOV     er0, off(00186h)
                LC      A, 00008h[DP]
                MUL
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     tipin_table_diff_calc
                L       A, #0ffffh

tipin_table_diff_calc:     XCHG    A, er3
                SUB     A, er3
                SJ      tipin_table_final

tipin_table_row2:     MOV     er0, off(00184h)
                LC      A, 00006h[DP]
                MUL
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     tipin_table_result_alt
                L       A, #0ffffh

tipin_table_result_alt:     XCHG    A, er3
                SUB     A, er3
                JLT     tipin_table_result_common
                CMP     A, er2
                JGE     tipin_table_final

tipin_table_result_common:     L       A, er2
                RC

tipin_table_final:     JGE     cranking_flag_check

accelenrich_clear_and_cranking_prep:     CLRB    A

accelenrich_clear_0x165:     STB     A, off(00165h)

StartCranking:     RB      off(0012ch).3
                CLR     A
                SJ      SetCranking

cranking_flag_check:     CLRB    off(00165h)
                JBS     off(00130h).5, cranking_flag_set
                JBS     off(001f8h).3, StartCranking

cranking_flag_set:     SB      off(0012ch).3

SetCranking:     ST      A, off(00142h)
                JBS     off(0011fh).5, Cranking
                J       notcranking_entry

Cranking:     MOV     X1, #CrankFuel
; --- Engine-cranking fuel pulse-width calculation (0x145C-0x14DC+): looks up CrankFuel (by
; ECT, 0xD9), CrankFuelComp (by IAT/MAT, 0xC5), and CrankFuelMap (by MAP, 0xBC), multiplies
; them together with a fixed-point scale/clamp sequence, applies the accel-enrichment pulse
; (off(00142h)) and a further off(00144h) adjustment, clamps to 0/0xFFFF, then writes the
; final value into the per-cylinder injector timer-compare registers (0x3A6/0x3B8, then
; 0x3BA/0x3BC/0x3BE/0x3C0) inside an interrupt-disabled critical section -- same
; disable-IE/write/re-enable pattern used for the ignition-timer writes earlier.
                LB      A, 0d9h
                VCAL    0
                STB     A, off(00140h)
                MOV     X1, #CrankFuelComp
                LB      A, 0c5h
                VCAL    1
                STB     A, off(00162h)
                MOV     X1, #CrankFuelMap
                LB      A, 0bch
                VCAL    1
                STB     A, off(00163h)
                MOVB    r0, off(00162h)
                MULB
                MOV     er0, off(00140h)
                MUL
                L       A, ACC
                SLL     A
                ROL     er1
                JLT     crankfuel_clamp_max
                SLL     A
                L       A, er1
                ROL     A
                JLT     crankfuel_clamp_max
                ADD     A, off(00142h)
                JGE     crankfuel_halve_check

crankfuel_clamp_max:     L       A, #0ffffh

crankfuel_halve_check:     MB      C, sysFlags_b7.0
                JGE     crankfuel_add_adjust
                SRL     A
                SRL     A

crankfuel_add_adjust:     ADD     A, off(00144h)
                JGE     crankfuel_zero_gate
                L       A, #0ffffh

crankfuel_zero_gate:     JBR     off(0012ah).1, crankfuel_store_injectors_ab
                CLR     A

crankfuel_store_injectors_ab:     MOV     DP, #003a6h
                ST      A, [DP]
                MOV     DP, #003b8h
                ST      A, [DP]
                CLR     X1
                CAL     scale_mul5_div4
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, 003bah[X1]
                ST      A, 003bch[X1]
                ST      A, 003beh[X1]
                ST      A, 003c0h[X1]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MB      C, sysFlags_b7.0
                JLT     crankfuel_output_apply_start
                CMPB    off(0013dh), #004h
                JNE     postfuel_calc_start
                CMPB    0d9h, #0ech
                JGE     postfuel_calc_start

crankfuel_output_apply_start:     L       A, 003bah[X1]
                L       A, ACC
                MOV     er0, A
                LC      A, CrankT
                CAL     mul_scale_clamp
                ST      A, off(0019eh)
                ST      A, off(0019ch)
                ST      A, off(0019ah)
                ST      A, off(00198h)
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                L       A, TM0
                SUB     A, TMR0
                MB      C, IRQ.5
                JLT     crankfuel_timer_sync_done
                ADD     A, #00005h
                JLT     crankfuel_timer_sync_done
                ADD     TMR0, A

crankfuel_timer_sync_done:     ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MOV     DP, #00010h

crankfuel_timer_wait_loop:     L       A, off(0019eh)
                JRNZ    DP, crankfuel_timer_wait_loop
                CAL     injector_timer_schedule
                JBS     off(0011fh).3, cylinder_index_advance
                JBS     off(0011bh).7, cylinder_index_advance
                MULB
                RB      off(0012ah).0
                JEQ     cylinder_index_advance
                RB      TRNSIT.2
                JNE     cylinder_index_advance
dtc16_injector_latch_2: SB      0b4h.6

cylinder_index_advance:     LB      A, off(0013ch)
                ADDB    A, #001h
                ANDB    A, #003h
                STB     A, off(0013ch)

postfuel_calc_start:     SB      off(0012ch).4
; --- Post-start enrichment (0x1539-0x15BF): after cranking ends, looks up PostFuel (by ECT,
; gated to only apply below 0xCF) and PostfuelT, with several ECT-rate-of-change sanity checks
; (comparing current 0xD9 against a stored previous value at 0x31A, and IAT 0xD8) that trigger
; VCAL 6 (the same diagnostic call used elsewhere for out-of-range sensor deltas) if the
; coolant temp changed implausibly fast between calls. Produces a decaying post-start
; enrichment value applied via mul_scale_clamp, stored at off(00170h). Runs alongside
; cylinder_index_advance, a simple round-robin counter (0x13C, mod 4) selecting which
; cylinder's injector event is being scheduled next.
                LB      A, 0d9h
                CMPB    A, #0cfh
                MB      PSWL.5, C
                MOV     X1, #PostFuel
                VCAL    0
                STB     A, r0
                STB     A, r1
                JBS     off(0011ah).5, postfuel_scale_apply
                JBS     off(0011bh).1, postfuel_scale_apply
                CMPB    0d9h, #0c5h
                JLT     postfuel_scale_apply
                MOV     DP, #0031ah
                LB      A, [DP]
                SUBB    A, 0d9h
                JGE     postfuel_ect_rate_check
                VCAL    6

postfuel_ect_rate_check:     CMPB    A, #00ah
                JGE     postfuel_scale_apply
                LB      A, 0d8h
                CMPB    A, #0c5h
                JLT     postfuel_scale_apply
                SUBB    A, 0d9h
                JLT     postfuel_scale_apply
                CMPB    A, #005h
                JLT     postfuel_scale_apply
                L       A, #0e666h
                MUL

postfuel_scale_apply:     L       A, er1
                L       A, ACC
                MOV     er0, A
                LC      A, PostfuelT
                CAL     mul_scale_clamp
                ST      A, off(00170h)
                CLRB    off(0016fh)
                MOV     er2, #02000h
                SUB     A, er2
                ST      A, er3
                CLRB    r0
                MOVB    r1, #080h
                MB      C, PSWL.5
                JLT     postfuel_hyst_upper_calc
                MOVB    r1, #04dh

postfuel_hyst_upper_calc:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(00172h)
                L       A, er3
                MOVB    r1, #040h
                MB      C, PSWL.5
                JLT     postfuel_hyst_lower_calc
                MOVB    r1, #033h

postfuel_hyst_lower_calc:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(00174h)
                CMPB    0d8h, #030h
                MB      off(0012bh).3, C
                LB      A, off(00169h)
                SUBB    A, off(0016dh)
                JGE     postfuel_tps_delta_finalize
                CLRB    A

postfuel_tps_delta_finalize:     STB     A, off(0016eh)
                J       postinj_rpm_check

notcranking_entry:     RB      sysFlags_b7.0
; --- Post-start enrichment decay: selects a decay-rate table (PostFuelDecay/2/3, chosen by
; TPS/RPM conditions), then subtracts the selected decay amount from the enrichment value
; (0x170) each cycle, floored at a minimum of 0x2000, with an ECT-gated (0x2E threshold) exit
; once fully decayed. This is what makes post-start enrichment taper off over time rather than
; cutting off abruptly.
                JEQ     postfuel_decay_table_select
                CLRB    off(0013dh)

postfuel_decay_table_select:     JBR     off(0012ch).4, rpm_hyst_flag_12f0
                MOV     DP, #PostFuelDecay
                JBR     off(0011eh).3, postfuel_decay_table_index_adjust
                MOV     DP, #PostFuelDecay2
                JBS     off(00119h).5, postfuel_decay_table_index_adjust
                MOV     DP, #PostFuelDecay3


postfuel_decay_table_index_adjust:     CMPB    off(00171h), #02eh
                JLE     postfuel_decay_table_index_adjust2
                CMP     off(00170h), off(00172h)
                JGT     postfuel_decay_apply

postfuel_decay_table_index_adjust2:     INC     DP
                INC     DP
                CMP     off(00170h), off(00174h)
                JGT     postfuel_decay_apply
                INC     DP
                INC     DP
                CMPB    0d8h, #030h
                JGE     postfuel_decay_apply
                INC     DP
                INC     DP

postfuel_decay_apply:     LC      A, [DP]
                SUBB    off(0016fh), A
                CLRB    A
                L       A, ACC
                SWAP
                ST      A, er0
                L       A, off(00170h)
                SBC     A, er0
                CMP     A, #02000h
                JLE     postfuel_decay_zero_reset
                ST      A, off(00170h)
                CMPB    0d9h, #02eh
                JLT     postfuel_final_store
                JBR     off(00119h).2, postfuel_final_store
                CLRB    r0
                MOVB    r1, #08dh
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     postfuel_final_store
                L       A, #0ffffh
                SJ      postfuel_final_store

postfuel_decay_zero_reset:     RB      off(0012ch).4
                L       A, #02000h
                ST      A, off(00170h)

postfuel_final_store:     ST      A, off(0015ah)

rpm_hyst_flag_12f0:     LB      A, #0bah
; --- VE table / closed-loop O2 entry-condition gating (0x162E-0x16B2+): sets several
; condition flags at off(0012fh)/(00130h) from RPM hysteresis checks, DisableVE/VE_ECT
; (volumetric-efficiency table enable + ECT threshold), CloseloopO2/OpenloopMbar (closed-loop
; O2 enable + MAP crossover into open-loop), and CloseLoopTPS/OpenLoopTPS (TPS-based
; open/closed-loop table interpolated via table_interp_lookup). These flags are almost
; certainly what the earlier o2_closedloop_gate1/o2_gate_tps_check checks read -- this is the
; condition-setting side of that gating, not yet cross-verified bit-for-bit against those
; consumers.
                JBS     off(0012fh).0, rpm_hyst_flag_12f0_store
                LB      A, #0c0h

rpm_hyst_flag_12f0_store:     CMPB    A, off(currentRPMByte)
                MB      off(0012fh).0, C
                LB      A, #0dah
                JBS     off(0012fh).5, rpm_hyst_flag_12f5
                LB      A, #0ddh

rpm_hyst_flag_12f5:     CMPB    A, off(currentRPMByte)
                MB      off(0012fh).5, C
                LB      A, #0ffh
                CMPB    A, off(currentRPMByte)
                MB      off(00130h).1, C
                LB      A, #0ffh
                CMPB    A, off(00132h)
                MB      off(00130h).2, C
                LCB     A, DisableVE
                JEQ     ve_ect_check
                SC
                SJ      ve_ect_flag_store

ve_ect_check:     LCB     A, VE_ECT
                CMPB    A, 0d9h

ve_ect_flag_store:     MB      off(0012fh).1, C
                LCB     A, CloseloopO2
                JEQ     O2Conditions
                SC
                SJ      closeloop_tps_flag_store

O2Conditions:     LCB     A, OpenloopMbar
                CMPB    A, 0bbh
                JLT     closeloop_tps_flag_store
                LB      A, off(currentRPMByte)
                MOV     X1, #CloseLoopTPS
                JBS     off(0012fh).6, closeloop_tps_lookup
                MOV     X1, #OpenLoopTPS

closeloop_tps_lookup:     CAL     table_interp_lookup
                CMPB    A, 0d1h

closeloop_tps_flag_store:     MB      off(0012fh).6, C
                LB      A, off(currentRPMByte)
                MOV     X1, #tbl_closeloop_tps
                CMPCB   A, 0000ch[X1]
                MB      off(0012fh).3, C
                CAL     table_interp_lookup
                CLRB    r0
                JBS     off(0012fh).3, ve_adjust_sub
                MOVB    r0, #025h
                JBS     off(0012fh).1, ve_adjust_sub
                MOVB    r0, #025h
                JBS     off(00120h).7, ve_adjust_add
                CLRB    r0

ve_adjust_add:     ADDB    r0, off(0017eh)
; --- VE (volumetric efficiency) table lookup and TPS-acceleration-enrichment blend
; (0x16AD-0x1734+). Applies a couple of small trim adjustments (ve_adjust_add/sub, gated by
; the flags set in the previous block), looks up the actual VEhi table via
; table2d_lookup_interp (RPM x Load, same 2D helper used for the fuel table earlier), then a
; dense chain of flag checks (0x11A/0x120/0x121/0x125/0x129/0x12F/0x130) decide whether/how to
; blend in acceleration enrichment on top of the VE result. Confidence is high on the VEhi
; lookup itself, lower on the exact meaning of each individual accel-blend gate -- named at
; the mechanism level (state/gate/threshold) rather than asserting precise trigger semantics.
                JLT     ve_adjust_clamp_zero

ve_adjust_sub:     SUBB    A, r0
                JGE     ve_adjust2_gate

ve_adjust_clamp_zero:     CLRB    A

ve_adjust2_gate:     MOVB    r0, #008h
                JBR     off(00130h).0, ve_result_flag_store
                SUBB    A, r0
                JGE     ve_result_flag_store
                CLRB    A

ve_result_flag_store:     CMPB    A, off(00132h)
                MB      off(00130h).0, C
                MOVB    r0, #018h
                MOVB    r1, #014h
                MOVB    r2, off(001e6h)
                MOV     X2, off(001e4h)
                MOVB    r3, off(001e9h)
                MOV     er3, off(001eeh)
                MOV     X1, #VEhi
                RB      PSWL.5
                CAL     table2d_lookup_interp
                LB      A, r4
                JBR     off(0012fh).1, ve_table_result_store
                LB      A, #080h

ve_table_result_store:     STB     A, r0
                JBS     off(00125h).4, ve_accel_state_9
                JBS     off(0011ah).6, ve_accel_gate1
                JBS     off(0012fh).6, ve_accel_tps_threshold_check

ve_accel_gate1:     JBS     off(0012fh).3, ve_accel_gate2
                JBS     off(00120h).7, ve_accel_gate2
                JBS     off(00130h).0, ve_accel_state_check_vss

ve_accel_state_9:     MOVB    off(001b7h), #009h
                SJ      ve_accel_reset_flags


ve_accel_gate2:     JBR     off(00130h).0, ve_accel_state_zero
                JBS     off(00129h).3, ve_accel_check_tps_rate

ve_accel_state_zero:     CLRB    A
                SJ      ve_accel_state_store

ve_accel_state_check_vss:     CMPB    0cch, #005h
                JLT     ve_accel_tps_threshold_check
                LB      A, off(001b7h)
                JEQ     ve_accel_tps_threshold_check
                SJ      ve_accel_reset_flags

ve_accel_state_store:     STB     A, off(001b7h)


ve_accel_reset_flags:     MOVB    off(001c5h), #0ffh
                RB      off(00125h).5
                RB      off(0012fh).4

ve_accel_common:     RB      off(0012fh).7
                LB      A, #080h
                J       tpsaccel_store_0x162

ve_accel_check_tps_rate:     JBS     off(00121h).5, ve_accel_next_stage



ve_accel_tps_threshold_check:     LB      A, r0
                CMPB    A, off(00169h)
                JGE     ve_accel_next_stage
                SB      off(00125h).5
                CLRB    off(001b7h)
                SJ      ve_accel_common

ve_accel_next_stage:     MOVB    r0, off(0017dh)
; --- TPS-acceleration-enrichment tail (0x1734-0x17B7+): further scaling/clamping of the
; enrichment value against working RAM (0x17D/0x244/0x1C5/0x1B0/0x18F) and two more small
; lookup tables (tbl_ve_accel_1/tbl_ve_accel_2, RPM-indexed, selected by off(00127h).1). Low confidence on
; exact per-flag semantics (no calibration-field anchors in this stretch); named at the
; mechanism level. Ends by copying the ignition-cut output flag (off(00124h).4, set by the
; fuel-cut/rev-limiter block) into off(0012eh).4 -- linking this enrichment stage back into
; the ignition-cut state.
                MULB
                SLLB    A
                LB      A, ACCH
                ROLB    A
                JGE     tpsaccel_scale_clamp1
                LB      A, #0ffh

tpsaccel_scale_clamp1:     STB     A, r2
                LB      A, (00244h-00280h)[USP]
                CMPB    A, #0ffh
                JBS     off(0012fh).4, tpsaccel_hyst_check
                JLT     tpsaccel_hyst_check
                SB      off(0012fh).4
                SJ      tpsaccel_table_select

tpsaccel_hyst_check:     CMPB    A, #0ffh
                JGE     tpsaccel_table_select
                LB      A, r2
                RB      off(0012fh).4
                SJ      tpsaccel_clamp_0xa0


tpsaccel_table_select:     LB      A, off(currentRPMByte)
                MOV     X1, #tbl_ve_accel_1
                JBR     off(00127h).1, tpsaccel_table_lookup
                LB      A, 0c2h
                MOV     X1, #tbl_ve_accel_2

tpsaccel_table_lookup:     CAL     table_interp_lookup
                MOVB    r0, r2
                MULB
                SLLB    A
                LB      A, ACCH
                ROLB    A
                JGE     tpsaccel_clamp_0xa0
                LB      A, #0ffh

tpsaccel_clamp_0xa0:     MOVB    r0, #0a0h
                CMPB    A, r0
                JLT     tpsaccel_mode_gate
                LB      A, r0

tpsaccel_mode_gate:     JBR     off(00130h).1, tpsaccel_set_0x1c5
                JBS     off(00130h).2, tpsaccel_check_0x1c5

tpsaccel_set_0x1c5:     MOVB    off(001c5h), #0ffh

tpsaccel_check_0x1c5:     CMPB    off(001c5h), #000h
                JEQ     tpsaccel_check_0x12c4
                CMPB    off(001b0h), #000h
                JNE     tpsaccel_result_common
                JBR     off(0012fh).5, tpsaccel_result_common

tpsaccel_check_0x12c4:     JBS     off(0012ch).4, tpsaccel_result_common
                MOVB    r0, #0a7h
                CMPB    A, r0
                JGE     tpsaccel_result_common
                LB      A, r0

tpsaccel_result_common:     SB      off(00125h).5
                SB      off(0012fh).7
                CLRB    off(001b7h)

tpsaccel_store_0x162:     STB     A, off(00162h)
                JBS     off(0012fh).5, tpsaccel_ignitioncut_flag_copy
                CLRB    A
                CMPB    0d9h, #03bh
                JGE     tpsaccel_ect_default_store
                LB      A, #036h

tpsaccel_ect_default_store:     STB     A, off(001b0h)

tpsaccel_ignitioncut_flag_copy:     MB      C, off(00124h).4
                MB      off(0012eh).4, C
                LB      A, off(0018fh)
                MOVB    r0, #05ah
                MOVB    r1, #073h
                JBR     off(00124h).2, tpsaccel_threshold_pick
                LB      A, off(0018eh)
                MOVB    r0, #04dh

tpsaccel_ect_gate:     MOVB    r1, #060h

tpsaccel_threshold_pick:     JBR     off(00123h).0, tps_hysteresis_check
                CMPB    0d8h, #030h
                JGE     tpsaccel_threshold_apply
                MOVB    r0, r1

tpsaccel_threshold_apply:     CMPB    A, r0
                JGE     tps_hysteresis_check
                LB      A, r0

tps_hysteresis_check:     JBR     off(0011fh).6, rpm_threshold_adjust
; --- Master fuel-cut / rev-limiter decision block (0x17DB-0x18FB). Builds the two final
; output flags off(00124h).4 (ignition cut) and off(00124h).5 (injector/fuel cut) consumed by
; the actual spark/injection scheduler elsewhere, from several independent checks:
;  1. tps_hysteresis_check/store: a TPS- or scratch-value-based two-state hysteresis latch
;     (off(0012eh).7), mechanism confirmed, exact signal not traced.
;  2. rpm_threshold_adjust/rpm_secondary_threshold_check: builds an adjusted RPM threshold from
;     scratch byte 0cch and sets a secondary flag (off(0012eh).3) -- not the main rev limiter.
;  3. revlimiter_engage_resume_check: THE rev limiter -- classic engage-high/resume-low
;     hysteresis using calibration fields FuelCutRPM (engage) / FuelCutRPMResume (resume)
;     against currentRPMByte, latched into off(0012eh).2.
;  4. overrev_hardcap_check/compare: a hardcoded (non-calibration, immediate 0xE5/0xE8) RPM
;     ceiling -- looks like a fixed hardware-protection failsafe independent of user calibration.
;  5. doubleup_limiter_gate/cont: gates the CAL to doubleup_limiter_target -- this is the exact "double-up
;     limiter" A describes (0x1879); left untouched per that item.
;  6. ignition_cut_mode_check/timing_mod/result_check: IGNCUT / ICTimeMod calibration-driven
;     ignition-cut-vs-timing-retard mode selection.
;  7. ofc_enable_check onward: Overrun Fuel Cut (OFCEnable calibration flag) gated by TPS and
;     the VacCut/VacCutTPS/VacCutRPM manifold-vacuum-based overrun cut checked earlier
;     (0x184A-0x1869, see VacCut* labels below), plus FuelCutTrack bookkeeping.
;  8. killinjectors_override: KillInjectors calibration flag forces both output flags directly,
;     bypassing every computed decision above.
; Flag polarity (0=cut-active vs 0=feature-disabled etc.) not independently re-derived here --
; treat as consistent with lookup_table.md's field naming, not re-verified bit-for-bit.

                CMPB    0dch, #082h
                JBS     off(0012eh).7, tps_hysteresis_store
                CMPB    0dch, #07ah

tps_hysteresis_store:     MB      off(0012eh).7, C
                STB     A, r0
                LB      A, #046h
                JBS     off(0012bh).6, tps_hysteresis_flag2
                LB      A, #047h

tps_hysteresis_flag2:     CMPB    A, r0
                MB      off(0012bh).6, C
                LB      A, r0
                JLT     rpm_threshold_adjust
                JBS     off(0012eh).7, rpm_threshold_adjust
                SUBB    A, #00ah
                JGE     rpm_threshold_adjust
                CLRB    A

rpm_threshold_adjust:     CMPB    0cch, #000h
                JLT     rpm_secondary_threshold_check
                JBS     off(00124h).2, rpm_secondary_threshold_check
                ADDB    A, #020h
                JGE     rpm_secondary_threshold_check
                LB      A, #0ffh

rpm_secondary_threshold_check:     CMPB    A, off(currentRPMByte)
                MB      off(0012eh).3, C
                LCB     A, FuelCutRPMResume
                JBS     off(0012eh).2, revlimiter_engage_resume_check
                LCB     A, FuelCutRPM

revlimiter_engage_resume_check:     CMPB    A, off(currentRPMByte)
                MB      off(0012eh).2, C
                RB      PSWL.4
                RB      PSWL.5
                RB      off(0012bh).7
                JBR     off(0011ch).5, overrev_hardcap_check
                LB      A, #0e5h
                JBS     off(00124h).5, overrev_hardcap_compare
                LB      A, #0e8h

overrev_hardcap_compare:     CMPB    A, off(currentRPMByte)
                JLT     tpsaccel_ect_gate

overrev_hardcap_check:     JBS     off(0011bh).5, vaccut_check_start
                MB      C, 0b1h.3
                JLT     vaccut_check_start
                LB      A, 09dh
                CMPB    A, #010h
                JGE     doubleup_limiter_gate

vaccut_check_start:     LCB     A, VacCut
                JNE     doubleup_limiter_gate
                JBS     off(0011ah).6, vaccut_rpm_check
                MB      C, 0b0h.2
                JLT     vaccut_rpm_check
                LCB     A, VacCutTPS
                CMPB    0d1h, A
                JGE     doubleup_limiter_gate

vaccut_rpm_check:     LCB     A, VacCutRPM
                CMPB    A, off(currentRPMByte)
                JGE     ofc_enable_check
                SJ      revlimiter_fuelcut_set

doubleup_limiter_gate:     MOV     DP, #00228h
                L       A, #00218h
                MB      C, P4.0
                JLT     doubleup_limiter_cont
                JBS     off(0011bh).7, doubleup_limiter_cont
                CAL     hts_limiter                 ; HTS120 hook

doubleup_limiter_cont:     JBR     off(00124h).5, ignition_cut_mode_check
                L       A, DP

ignition_cut_mode_check:     CMP     0c4h, A
                LCB     A, IGNCUT
                JEQ     ignition_cut_result_check
                MOV     DP, #000e6h
                LCB     A, ICTimeMod
                JEQ     ignition_cut_timing_mod
                MB      [DP].0, C
                SJ      ignition_cut_result_check

ignition_cut_timing_mod:     JGE     ignition_cut_result_check
                SB      [DP].0

ignition_cut_result_check:     JGE     fuelcut_extra_gate
                LCB     A, FuelCut
                JNE     fuelcut_result_common

revlimiter_fuelcut_set:     SB      PSWL.5
                SJ      fuelcut_result_common

fuelcut_extra_gate:     JBS     off(00124h).2, ofc_enable_check
                LB      A, off(001b3h)
                JNE     ofc_enable_check



ofc_enable_check:     LCB     A, OFCEnable
                JNE     fuelcuttrack_store
                LCB     A, FuelCutTPS
                CMPB    0d1h, A
                JGE     fuelcuttrack_store
                JBS     off(0012eh).0, fuelcuttrack_store
                JBS     off(0012eh).2, fuelcut_tps_recheck

fuelcuttrack_store:     LCB     A, FuelCutTrack
                STB     A, off(001cch)

fuelcut_clear_active_flag:     RB      off(00124h).2
                SJ      killinjectors_override

fuelcut_tps_recheck:     JBS     off(00124h).2, fuelcut_finalize_ign_flag
                LB      A, 0c1h
                CMPB    A, #008h
                JGE     fuelcuttrack_store
                LB      A, off(001cch)
                JEQ     fuelcut_finalize_ign_flag
                SB      off(0012bh).7
                SJ      fuelcut_clear_active_flag

fuelcut_finalize_ign_flag:     JBS     off(0012ch).3, fuelcut_clear_active_flag
                SB      PSWL.4

fuelcut_result_common:     SB      off(00124h).2

killinjectors_override:CAL     hts_kill_check       ; HTS120 hook
                JEQ     fuelcut_output_flags
                MB      C, ACC.0
                MB      PSWL.5, C
                MB      PSWL.4, C

fuelcut_output_flags:     MB      C, PSWL.5
                MB      off(00124h).5, C
                MB      C, PSWL.4
                MB      off(00124h).4, C
                LB      A, 0dch
                CMPB    A, #082h
                JBS     off(0012bh).4, tps_hysteresis_reentry
                CMPB    A, #07ah

tps_hysteresis_reentry:     MB      off(0012bh).4, C
; --- Dense flag-gated result selector (0x1907-0x19A1ish): chooses an output value (stored via
; postig_result_high/zero/default) based on a long chain of engine-state flag checks
; (0x119/0x11E/0x120/0x121/0x122/0x125/0x12B/0x12C) and RPM/ECT comparisons. No calibration
; anchors in this stretch; named at the mechanism level only.
                ANDB    PSWL, #0cfh
                MOVB    r2, #000h
                JBS     off(00121h).7, postig_result_zero_common
                JBS     off(00125h).4, postig_result_zero
                JBS     off(0012ch).3, postig_result_zero_common
                JBS     off(00125h).5, postig_result_zero_common
                JBR     off(00122h).2, postig_result_default
                JBS     off(00122h).0, postig_result_default
                JBR     off(0011eh).3, postig_gate_chain2
                JBS     off(00119h).5, postig_result_default

postig_gate_chain2:     JBS     off(00120h).4, postig_result_default
                LB      A, off(0018ch)
                MOVB    r0, #04bh
                JBS     off(0012bh).5, postig_threshold_check1
                LB      A, off(0018dh)
                MOVB    r0, #05ah

postig_threshold_check1:     JBR     off(00123h).0, postig_threshold_check2
                CMPB    A, r0
                JGE     postig_threshold_check2
                LB      A, r0

postig_threshold_check2:     JBR     off(0011fh).6, postig_rpm_compare
                MOVB    r0, #045h
                JBS     off(0012bh).5, postig_threshold_check3
                MOVB    r0, #046h

postig_threshold_check3:     CMPB    A, r0
                JGE     postig_rpm_compare
                JBS     off(0012bh).4, postig_rpm_compare
                SUBB    A, #00ah
                JGE     postig_rpm_compare
                CLRB    A

postig_rpm_compare:     CMPB    A, off(currentRPMByte)
                JGT     postig_result_zero_common
                CMPB    0d9h, #034h
                JGE     postig_result_high
                JBR     off(0011eh).3, postig_result_high
                LB      A, off(001cbh)
                STB     A, r2
                JNE     postig_result_zero_common

postig_result_high:     LB      A, #0e6h
                SB      PSWL.5
                SJ      ignmap2_flags_store

postig_result_zero:     CLRB    A
                SJ      ignmap2_flags_store

postig_result_zero_common:     CLRB    A
                SJ      ignmap2_flags_store

postig_result_default:     LB      A, #080h
                MOV     X1, #tbl_ignmap2_hi

ignmap2_table_select:     JBR     off(0012bh).5, ignmap2_rpm_gate
                LB      A, #073h
                MOV     X1, #tbl_ignmap2_lo

ignmap2_rpm_gate:     CMPB    A, off(currentRPMByte)
                JGE     postig_result_zero_common
                LB      A, off(currentRPMByte)
                CAL     table_interp_lookup
                ADDB    A, #002h
                JGE     ignmap2_result_check
                LB      A, #0ffh

ignmap2_result_check:     SUBB    A, off(00190h)
                JLT     postig_result_zero_common
                CMPB    A, off(00132h)
                JLE     postig_result_zero_common
                LB      A, #0e6h

ignmap2_flags_store:     CLRB    off(00164h)
                MB      C, PSWL.4
                MB      off(0012bh).5, C
                MB      C, PSWL.5
                MB      off(00126h).1, C
                MOVB    off(001cbh), r2
                LB      A, #0cdh
                JBS     off(0012dh).0, rpm_threshold_flag_12d0
                LB      A, #0d0h

rpm_threshold_flag_12d0:     CMPB    A, off(currentRPMByte)
                MB      off(0012dh).0, C
                LB      A, #011h
                JBS     off(00124h).6, knock_window_check
                LB      A, #00eh

knock_window_check:     CMPB    0c5h, A
                MB      off(00124h).6, C
                JGE     knock_window_gate_common
                RC
                JBS     off(00125h).5, knock_window_gate_common
                JBS     off(0012dh).0, knock_window_gate_common
                JBS     off(0012bh).5, knock_window_gate_common
                JBS     off(00124h).2, knock_window_gate_common
                SC

knock_window_gate_common:     MB      off(00125h).2, C
                LB      A, #03dh
                JBS     off(0012ah).6, vss_threshold_flag_check
                LB      A, #040h

vss_threshold_flag_check:     CMPB    A, 0cch
                MB      off(0012ah).6, C
                LB      A, #0bah
                JBS     off(00125h).3, rpm_gate_final_check
                LB      A, #0c0h

rpm_gate_final_check:     CMPB    A, off(currentRPMByte)
                MB      off(00125h).3, C
                JBR     off(00120h).0, o2_closedloop_read_and_select
                MOVB    off(001b6h), #019h

o2_closedloop_read_and_select:     LCB     A, O2Input
; --- Closed-loop O2/lambda correction entry. Reads O2Input (which physical sensor/type is
; fitted) and dispatches through indexed_ram_selector_0to3 (below) to fetch that sensor's raw
; value from one of 4 possible RAM slots. Compares against CloseLoopNarrow (narrowband vs
; wideband selection) and CloseLoopTargetVolt (target AFR/lambda voltage) to derive a
; rich/lean direction, latched via XORB PSWH,#080h into a direction bit consumed downstream
; by the actual trim integrator. Followed by several gate checks (RPM/TPS/gear/mode flags)
; that can abort closed-loop trim entirely under the wrong conditions.
                CAL     indexed_ram_selector_0to3
                STB     A, r0
                LCB     A, CloseLoopNarrow
                JNE     o2_direction_wideband
                LCB     A, CloseLoopTargetVolt
                CMPB    A, r0
                SJ      o2_richlean_direction_latch

o2_direction_wideband:     LCB     A, CloseLoopTargetVolt
                CMPB    r0, A

o2_richlean_direction_latch:     RB      off(0012dh).2
                MB      off(0012dh).2, C
                JEQ     o2_closedloop_delay_dec
                XORB    PSWH, #080h

o2_closedloop_delay_dec:     MB      off(0012dh).1, C
                L       A, off(001dch)
                JEQ     o2_closedloop_gate1
                DEC     off(001dch)

o2_closedloop_gate1:     JBR     off(00121h).3, o2_trim_gate_common
                JBS     off(00125h).4, o2_trim_gate_common
                MOV     DP, #003afh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2_trim_gate_common
                CMPB    0f2h, #00ch
                JLT     o2_trim_gate_common
                MB      C, (002edh-00280h)[USP].3
                JLT     o2_trim_gate_common
                MB      C, (002eeh-00280h)[USP].4
                JLT     o2_trim_gate_common
                L       A, off(0011ah)
                AND     A, #08075h
                JNE     o2_trim_gate_common
                L       A, off(0011ch)
                AND     A, #01420h
                JNE     o2_trim_gate_common
                CMPB    0d9h, #025h
                JGE     o2_trim_gate_common
                LB      A, 0dah
                STB     A, r0
                JBS     off(00124h).4, o2_store_prev_reading
                CMPB    off(currentRPMByte), #062h
                JGE     o2_gate_tps_check
                MOVB    off(001bbh), #032h

o2_gate_tps_check:     LB      A, off(001bbh)
                JNE     o2_gate_dp_set
                SB      off(0012dh).3

o2_gate_dp_set:     RC
                JBS     off(00124h).5, dtc01_o2_latch
                JBR     off(00125h).5, dtc01_o2_latch
                LB      A, #092h
                CMPB    A, off(00162h)
                JGE     dtc01_o2_latch
                CMPB    r0, #003h
                SJ      dtc01_o2_latch

o2_store_prev_reading:     JBS     off(0012eh).4, o2_narrowband_check
                LB      A, r0
                STB     A, off(00191h)

o2_narrowband_check:     JBR     off(0012dh).3, o2_trim_gate_reset_dp
                LCB     A, CloseLoopNarrow
                JNE     o2_delta_check
                LB      A, #04dh
                CMPB    A, r0
                JGE     o2_trim_gate_common

o2_delta_check:     JBS     off(00120h).2, o2_trim_gate_common
                LB      A, off(00191h)
                SUBB    A, r0
                JGE     o2_delta_magnitude_check
                VCAL    6

o2_delta_magnitude_check:     CMPB    A, #002h
                JLT     dtc01_o2_latch

o2_trim_gate_common:     RB      off(0012dh).3

o2_trim_gate_reset_dp:     MOVB    off(001bbh), #032h
                RC

dtc01_o2_latch:     MB      0b0h.4, C
                MOVB    r0, #064h
                JBR     off(00121h).3, o2_trim_step_common
                JBS     off(00125h).4, o2_trim_step_common
                MOV     er1, #0828fh
                JBR     off(0011eh).2, o2_trim_table_ptr_load
                MB      C, 0b8h.5
                JGE     o2_trim_table_ptr_load
                JBR     off(0012dh).1, o2_trim_table_ptr_alt
                RB      0b8h.5

o2_trim_table_ptr_load:     L       A, #0828fh
; --- O2 trim step-size/target selection (0x1ACE-0x1BA8ish): chooses between a couple of
; RAM-table pointers (0x828F immediate, or DP=0x304/0x300 lookups) and gate flags to decide
; the actual trim step magnitude/target applied to the closed-loop fuel correction, based on
; combinations of engine-state bits (0x11A/0x11D/0x120/0x121/0x124/0x125/0x12B/0x12D) and the
; earlier-computed rich/lean direction. High confidence this is "how big a trim step, and
; using which target-table, does the closed-loop integrator take this cycle" -- the exact
; meaning of each individual gate flag is not separately confirmed.
                JBS     off(0011ah).2, o2_trim_clear_gate1
                JBS     off(0011ah).4, o2_trim_clear_gate1
                MB      C, (002edh-00280h)[USP].3
                JLT     o2_trim_table_ptr_alt
                MB      C, (002eeh-00280h)[USP].4
                JLT     o2_trim_table_ptr_alt
                L       A, off(0011ah)
                AND     A, #08061h
                JNE     o2_trim_table_ptr_alt
                JBS     off(0011dh).2, o2_trim_table_ptr_alt
                JBR     off(0011dh).4, o2_trim_gate3

o2_trim_table_ptr_alt:     L       A, er1
                SJ      o2_trim_clear_gate1

o2_trim_gate3:     JBR     off(00121h).1, o2_trim_step_common
                JBS     off(00125h).5, o2_trim_step_common
                JBS     off(00121h).0, o2_trim_tps_mode_check
                SB      off(001f8h).5
                CLRB    off(001c6h)
                MOVB    off(001c8h), r0
                MOV     DP, #00304h
                JBR     off(00120h).0, o2_trim_dp_table_read
                MOV     DP, #00300h

o2_trim_dp_table_read:     L       A, [DP]
                SJ      o2_trim_clear_gate1

o2_trim_tps_mode_check:     JBS     off(0012dh).0, o2_trim_step_common
                JBR     off(00124h).6, o2_trim_step_finalize
                JBR     off(00124h).2, o2_trim_alt_path_check
                MOVB    off(001bfh), #00ah
                SJ      o2_trim_step_finalize

o2_trim_alt_path_check:     JBR     off(0012bh).5, o2_trim_alt_step_path


o2_trim_step_finalize:     RB      off(001f8h).5
                LB      A, off(001c8h)
                JEQ     o2_trim_default_target
                L       A, off(00158h)
                SB      (002edh-00280h)[USP].2
                SB      off(00125h).1
                SJ      o2_trim_clear_gate0_and_return

o2_trim_step_common:     SB      off(001f8h).5
                CLRB    off(001c6h)
                MOVB    off(001c8h), r0

o2_trim_default_target:     L       A, #08000h

o2_trim_clear_gate1:     RB      off(00125h).1

o2_trim_clear_gate0_and_return:     RB      off(00125h).0
                J       injtimer_finalize_start

o2_trim_alt_step_path:     SB      (002edh-00280h)[USP].2
                SB      off(00125h).1
                MOVB    off(001c8h), r0
                MB      C, off(0012dh).5
                MB      PSWL.4, C
                LB      A, #037h
                JLT     o2_trim_step_threshold
                LB      A, #04ch

o2_trim_step_threshold:     CMPB    A, off(00132h)
                MB      off(0012dh).5, C
                MOVB    r6, #004h
                MOVB    r7, #004h
                L       A, er3
                SB      off(00125h).0
                JEQ     o2_trim_dp300_read
                JBS     off(00120h).3, o2_trim_alt_gate
                JBR     off(00120h).2, o2_trim_alt_gate
                ST      A, off(0017ah)
                JBR     off(00120h).1, o2_trim_dp304_calc
                MOV     DP, #00308h
                MOV     er1, [DP]
                SJ      o2_trim_step_finalize2

o2_trim_dp300_read:     ST      A, off(0017ah)
                MOV     DP, #00300h
                MOV     er1, [DP]
                JBS     off(00120h).0, o2_trim_step_finalize2


o2_trim_dp304_calc:     MOV     DP, #00304h
                MOV     er0, [DP]
                L       A, #08400h
                MOV     er1, #08000h
                CMPB    0d9h, #028h
                JLT     o2_trim_mul_apply
                L       A, er1

o2_trim_mul_apply:     MUL
                SLL     A
                ROL     er1
                JGE     o2_trim_step_finalize2
                MOV     er1, #0ffffh

o2_trim_step_finalize2:     SB      PSWL.5
                SJ      o2_trim_result_check

o2_trim_alt_gate:     MB      C, PSWL.4
                JLT     o2_trim_dp304_common
                JBR     off(0012dh).5, o2_trim_dp304_common
                MOV     DP, #00304h
                CMP     [DP], off(00158h)
                JGT     o2_trim_dp304_calc

o2_trim_dp304_common:     MOV     er1, off(00158h)
                RB      PSWL.5
                JBR     off(0012dh).1, o2_trim_result_check
                ST      A, off(0017ah)

o2_trim_result_check:     MB      C, PSWL.5
                JLT     o2_trim_er3_decrement
                JBS     off(0012dh).1, o2_trim_rpm_alt_check

o2_trim_er3_decrement:     L       A, er3
                LB      A, ACC
                MOV     DP, #0017ah
                JBR     off(0012dh).2, o2_trim_decrement_apply
                LB      A, ACCH
                INC     DP

o2_trim_decrement_apply:     DECB    [DP]
                JEQ     o2_trim_decrement_store
                J       o2trim_gate_common2

o2_trim_decrement_store:     STB     A, [DP]

o2_trim_rpm_alt_check:     JBS     off(00120h).0, o2_trim_bank_index_alt
                LB      A, (00294h-00280h)[USP]
                CMPB    A, off(currentRPMByte)
                JGE     o2_trim_flag_default_zero
                RB      off(001f8h).5
                SJ      o2_trim_bank_index_calc

o2_trim_flag_default_zero:     CLRB    A

o2_trim_flag_store2:     STB     A, off(001c6h)
                SB      off(001f8h).5

o2_trim_bank_index_calc:     CLR     X1
                JBS     off(0012fh).0, o2_trim_rate_table_select
                INC     X1
                LB      A, off(currentRPMByte)
                CMPB    A, #089h
                JGE     o2_trim_rate_table_select
                INC     X1
                CMPB    A, #040h
                JGE     o2_trim_rate_table_select
                INC     X1
                SJ      o2_trim_rate_table_select

o2_trim_bank_index_alt:     MOV     X1, #00004h
                JBS     off(001f8h).5, o2_trim_flag_recheck
                JBR     off(0012dh).1, o2_trim_bank_index_calc
                LB      A, #03ch
                SJ      o2_trim_flag_store2

o2_trim_flag_recheck:     LB      A, off(001c6h)
                JNE     o2_trim_bank_index_calc

o2_trim_rate_table_select:     SLL     X1
                MOV     DP, #CloseLoopRate
                MB      C, PSWL.5
                JLT     o2_trim_table_offset_calc
                JBR     off(0012dh).1, o2_trim_table_offset_calc
                MOV     DP, #CloseLoopGoose
                JBS     off(0012dh).2, o2_trim_table_offset_calc
                LB      A, off(001c9h)
                JEQ     o2trim_apply_start

o2_trim_table_offset_calc:     L       A, X1
                JBR     off(0011eh).3, o2_trim_table_offset_calc2
                ADD     A, #0000ch

o2_trim_table_offset_calc2:     JBS     off(0011eh).0, o2_trim_rate_table_read
                ADD     A, #00030h

o2_trim_rate_table_read:     ADD     DP, A
                LC      A, [DP]
                MOV     er0, A
                MOV     er3, er1
                LC      A, MultO2
                CAL     mul_scale_clamp
                MOV     er1, er3
                JBS     off(0012dh).2, o2trim_sub_clamp
                SJ      o2trim_add_clamp

o2trim_apply_start:     MOVB    off(001c9h), #014h
                L       A, #00d00h
                JBS     off(0012fh).0, o2trim_add_clamp
                L       A, #00000h
                CMP     X1, #00008h
                JEQ     o2trim_add_clamp
                MOVB    r0, #083h
                LB      A, #051h
                CMPB    A, off(00132h)
                JGT     o2trim_apply_alt1
                L       A, off(001f2h)
                CMPB    r0, off(currentRPMByte)
                JGT     o2trim_apply_alt1
                JBR     off(0012ah).6, o2trim_apply_alt2
                SJ      o2trim_add_clamp

o2trim_apply_alt1:     L       A, off(00176h)
                CMPB    off(00132h), #051h
                JLT     o2trim_add_clamp

o2trim_apply_alt2:     L       A, off(00178h)

o2trim_add_clamp:     ADD     er1, A
                JGE     o2trim_closeloop_speed_check
                MOV     er1, #0ffffh
                SJ      o2trim_closeloop_speed_check

o2trim_sub_clamp:     SUB     er1, A
                JGE     o2trim_closeloop_speed_check
                CLR     er1

o2trim_closeloop_speed_check:     RB      PSWL.4
; --- O2 sensor switching-speed diagnostic: compares elapsed rich/lean transition time
; against CLSTFV/CLSTFT (Closed-Loop Switch Time Fast/limits) and CLMaxVoltage
; (CloseLoopNarrow-gated), flagging a slow-switching or stuck sensor into off(00126h).4/.5.
; Feeds off the same closed-loop O2 trim path named earlier in the session.
                RB      PSWL.5
                LC      A, CLSTFV
                CMP     A, er1
                JLE     o2trim_speed_flag_common
                LC      A, CLSTFT
                CMP     A, er1
                JLT     o2trim_speed_flags_store
                JBS     off(0011fh).3, o2trim_speed_flag_common
                CMPB    0d9h, #028h
                JGE     o2trim_speed_flag_common
                CMPB    0d8h, #02eh
                JGE     o2trim_speed_flag_common
                LCB     A, CloseLoopNarrow
                JNE     o2trim_speed_flag_set
                LCB     A, CLMaxVoltage
                CMPB    0dah, A
                JGT     o2trim_speed_flag_common

o2trim_speed_flag_set:     SB      PSWL.4
                L       A, #03300h
                CMP     A, er1
                JLT     o2trim_speed_flags_store

o2trim_speed_flag_common:     SB      PSWL.5
                ST      A, er1

o2trim_speed_flags_store:     MB      C, PSWL.4
                MB      off(00126h).4, C
                MB      C, PSWL.5
                MB      off(001f8h).1, C
                MOV     DP, #003afh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2trim_gate_common2
                LB      A, off(001bfh)
                JNE     o2trim_gate_common2
                JBS     off(001f8h).1, o2trim_gate_common2
                JBR     off(00121h).1, o2trim_gate_common2
                JBS     off(0012ch).4, o2trim_gate_common2
                CMPB    0d8h, #030h
                JLT     o2trim_gate_common2
                CLR     A
                CLRB    A
                MB      C, PSWL.5
                JLT     o2trim_bank_select_check
                JBR     off(0012dh).1, o2trim_bank_select_check
                JBS     off(00125h).3, o2trim_gate_common2
                MOV     X1, #00300h
                JBS     off(00120h).0, o2trim_ect_offset_lookup
                MOV     X1, #00304h
                LB      A, #004h
                SJ      o2trim_ect_offset_lookup

o2trim_bank_select_check:     JBS     off(00120h).0, o2trim_gate_common2
                LB      A, off(001b6h)
                JEQ     o2trim_gate_common2
                MOV     X1, #00308h
                LB      A, #008h

o2trim_ect_offset_lookup:     LCB     A, CloseLoopECT
                CMPB    0d9h, A
                JGE     o2trim_table_apply
                ADDB    A, #002h

o2trim_table_apply:     LC      A, tbl_o2trim_ect_offset[ACC]
                L       A, ACC
                ST      A, er0
                L       A, er1
                ST      A, er3
                CAL     injtimer_bank_calc1
                CAL     injtimer_bank_calc2
                MOV     er1, er3

o2trim_gate_common2:     L       A, er1

injtimer_finalize_start:     ST      A, off(00158h)
                LB      A, off(00132h)
                MOV     X1, #tbl_injtimer_finalize
                CAL     table_interp_lookup
                CLRB    ACCH
                L       A, ACC
                ADD     A, #00040h
                CLRB    r0
                MOVB    r1, off(00167h)
                MUL
                SLL     A
                ROL     er1
                SLL     A
                L       A, er1
                ROL     A
                ADD     A, #00200h
                ST      A, off(0015eh)
                MOV     DP, #003eeh
                MOV     er3, [DP]
                LB      A, off(00132h)
                STB     A, r0
                MOVB    r4, #0e6h
                CMPB    A, r4
                JGE     injtimer_bank_gate
                MOV     DP, #003eah
                MOV     er3, [DP]
                MOVB    r2, #019h
                LB      A, r0
                CMPB    A, r2
                JLT     injtimer_bank_gate
                LB      A, #064h
                CMPB    A, r0
                JLT     injtimer_dp_adjust
                STB     A, r4
                LB      A, r2
                SJ      injtimer_sub_common

injtimer_dp_adjust:     INC     DP
                INC     DP

injtimer_sub_common:     SUBB    r0, A
                CLRB    r1
                SUBB    r4, A
                CLRB    r5
                L       A, [DP]
                ST      A, er3
                INC     DP
                INC     DP
                L       A, [DP]
                CAL     injtimer_bank_calc3

injtimer_bank_gate:     L       A, ACC
                MOV     er0, er3
                LC      A, tbl_injector_bank_factor
                CAL     mul_scale_clamp
                MOV     off(0015ch), A
                RB      off(0012dh).6
                RB      off(0012dh).7
                JBR     off(00121h).3, injtimer_gate_common
                MB      C, (002edh-00280h)[USP].3
                JLT     injtimer_gate_common
                MB      C, (002eeh-00280h)[USP].4
                JLT     injtimer_gate_common
                JBS     off(00120h).6, injtimer_gate_common
                CMPB    0d9h, #000h
                JGE     injtimer_gate_common
                CMPB    0d9h, #000h
                JLT     injtimer_gate_common
                JBR     off(0012dh).6, injtimer_gate_common
                JBR     off(0012dh).7, injtimer_gate_common
                JBR     off(00121h).0, injtimer_gate_common
                JBS     off(0012bh).5, injtimer_gate_common
                JBS     off(00125h).1, injtimer_gate_common
                JBS     off(0012dh).2, injtimer_gate_common
                LB      A, #000h
                SJ      injtimer_store_0x166

injtimer_gate_common:     LB      A, off(00166h)
                SUBB    A, #000h
                JGE     injtimer_store_0x166
                CLRB    A

injtimer_store_0x166:     STB     A, off(00166h)
; --- Injector-timer final multiply chain (0x1DD6-0x1E48): a cascade of MUL operations
; combining per-cylinder-bank factors (0x156-0x166) into final timer values. Low-anchor
; territory (working RAM only, no calibration fields); named at the mechanism level.
; Continues into dwell/RPM-hysteresis logic (dwell_rpm_hyst_check onward) selecting a dwell
; value based on RPM bands (0xC5/0x70 thresholds) -- likely ignition coil dwell-time
; compensation for RPM.
                MOVB    r0, off(00168h)
                LB      A, off(00162h)
                MULB
                L       A, ACC
                ROL     A
                LB      A, ACCH
                STB     A, r1
                CLRB    r0
                SRL     er0
                SRL     er0
                LB      A, off(00165h)
                JEQ     injtimer_mul_chain1
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1

injtimer_mul_chain1:     MOVB    ACCH, #001h
                LB      A, off(00166h)
                MUL
                MOVB    r1, r2
                MOVB    r0, ACCH
                L       A, off(00160h)
                MUL
                MOV     er0, er1
                L       A, off(0015eh)
                MUL
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                MOVB    r1, r2
                MOVB    r0, ACCH
                LB      A, r3
                JEQ     injtimer_mul_chain2
                MOV     er0, #0ffffh

injtimer_mul_chain2:     L       A, off(0015ch)
                MUL
                MOV     er0, er1
                JBR     off(0012ch).4, injtimer_mul_final
                SLL     A
                ROL     er0
                JLT     injtimer_mul_clamp
                SLL     A
                ROL     er0
                JLT     injtimer_mul_clamp
                SLL     A
                ROL     er0
                JGE     injtimer_mul_chain3

injtimer_mul_clamp:     MOV     er0, #0ffffh

injtimer_mul_chain3:     L       A, off(0015ah)
                MUL
                MOV     er0, er1

injtimer_mul_final:     L       A, off(00158h)
                MUL
                MOV     off(00156h), er1
                LB      A, #040h
                JBS     off(00130h).6, dwell_rpm_hyst_check
                LB      A, #04dh

dwell_rpm_hyst_check:     CMPB    A, off(currentRPMByte)
                MB      off(00130h).6, C
                JBS     off(00125h).4, dwell_zero_result
                LB      A, off(currentRPMByte)
                CMPB    A, #0c5h
                JGE     dwell_zero_result
                JBR     off(00129h).0, dwell_zero_result
                LB      A, #004h
                JBS     off(00123h).4, dwell_rpm_gate2
                LB      A, #004h
                CMPB    0f3h, #096h
                JLT     dwell_zero_result

dwell_rpm_gate2:     CMPB    off(currentRPMByte), #002h
                JBS     off(00123h).4, dwell_rpm_gate3
                MB      C, off(00130h).6
                XORB    PSWH, #080h

dwell_rpm_gate3:     JLT     dwell_zero_result
                CMPB    A, 0c0h
                JGE     dwell_zero_result
                MOVB    r0, off(0018bh)
                CMPB    off(currentRPMByte), #070h
                JGE     dwell_value_select
                MOVB    r0, off(00189h)

dwell_value_select:     MOVB    r1, #014h
                JBS     off(00123h).4, dwell_clamp_check
                MOVB    r0, off(0018ah)
                MOVB    r1, #010h

dwell_clamp_check:     LB      A, 0c0h
                CMPB    A, r1
                JLE     dwell_mul_apply
                LB      A, r1

dwell_mul_apply:     MULB
                L       A, ACC
                SRL     A
                JBS     off(00123h).4, dwell_store_result
                VCAL    7
                SJ      dwell_store_result

dwell_zero_result:     CLR     A

dwell_store_result:     ST      A, off(00146h)
                CLRB    r4
                RC
                JBS     off(00125h).4, rpm_accel_skip
                JBR     off(00122h).3, rpm_accel_skip
                JBS     off(0012ch).7, rpm_accel_track_calc
                JBS     off(00122h).4, rpm_accel_alt_path
                L       A, (0025ah-00280h)[USP]
                CLRB    r5
                SJ      rpm_accel_track_store

rpm_accel_track_calc:     MOV     er3, off(00138h)
                MOVB    r5, off(0013ah)
                CLRB    r0
                MOVB    r1, #080h
                L       A, 0c4h
                CAL     rpm_accel_track_helper

rpm_accel_track_store:     ST      A, off(00138h)
                MOVB    off(0013ah), r5
                CLRB    r4
                SUB     A, 0c4h
                MB      off(0012ch).6, C
                MOV     DP, #003e8h
                JLT     rpm_accel_fault_path
                ST      A, [DP]
                JBS     off(00123h).6, rpm_accel_secondary_calc
                CMP     0c6h, #0001ah
                SJ      rpm_accel_gate_result

rpm_accel_fault_path:     VCAL    7
                ST      A, [DP]
                JBR     off(00123h).6, rpm_accel_secondary_calc
                CMP     0c6h, #0001ah

rpm_accel_gate_result:     JGE     rpm_accel_clamp

rpm_accel_secondary_calc:     CLRB    r0
                MOVB    r1, #01eh
                CMPB    0d9h, #034h
                JGE     rpm_accel_mul_apply
                JBS     off(0011eh).3, rpm_accel_mul_apply
                CMPB    0cch, #005h
                JLT     rpm_accel_mul_apply
                MOVB    r1, #01eh

rpm_accel_mul_apply:     MUL
                MOVB    r4, #02ah
                SLL     A
                ROL     er1
                JLT     rpm_accel_clamp
                SLL     A
                ROL     er1
                JLT     rpm_accel_clamp
                LB      A, r3
                JNE     rpm_accel_clamp
                LB      A, r2
                CMPB    A, r4
                JGE     rpm_accel_clamp
                STB     A, r4

rpm_accel_clamp:     SC

rpm_accel_skip:     MB      off(0012ch).7, C

rpm_accel_alt_path:     LB      A, r4
                JEQ     rpm_accel_store_0x148
                JBS     off(0012ch).6, rpm_accel_store_0x148
                VCAL    6

rpm_accel_store_0x148:     STB     A, off(00148h)
                JBR     off(0011eh).3, rpm_decel_zero
                JBR     off(00119h).5, rpm_decel_ect_gate
                RB      off(00130h).7
                SJ      rpm_decel_zero

rpm_decel_ect_gate:     CMPB    0d9h, #0ffh
                JLT     rpm_decel_zero
                MOVB    r0, #000h
                MOV     er1, #0ffffh
                CMPB    0d9h, #0ffh
                JLT     rpm_decel_calc
                MOVB    r0, #000h
                MOV     er1, #0ffffh

rpm_decel_calc:     MOV     DP, #00311h
                LB      A, [DP]
                ADDB    A, #000h
                CMPB    A, 0d4h
                JLT     rpm_decel_diff_check
                JBS     off(00123h).6, rpm_decel_diff_check
                CMP     0c6h, #0ffffh
                LB      A, #000h
                JLT     rpm_decel_flag_check
                LB      A, #000h

rpm_decel_flag_check:     JBS     off(00130h).7, rpm_decel_flag_result
                MOVB    off(001c0h), #001h
                SB      off(00130h).7

rpm_decel_flag_result:     CMPB    off(001c0h), #000h
                JNE     rpm_decel_mul_calc

rpm_decel_diff_check:     L       A, off(001f0h)
                SUB     A, er1
                JGE     rpm_decel_store

rpm_decel_zero:     CLR     A
                SJ      rpm_decel_store

rpm_decel_mul_calc:     CLRB    r1
                MULB
                MOV     er0, 0c6h
                MUL
                MOV     er0, #00000h
                L       A, ACC
                SLL     A
                ROL     er1
                CMPB    r3, #000h
                JNE     rpm_decel_result_select
                LB      A, r2
                L       A, ACC
                SWAP
                CMP     A, er0
                JLT     rpm_decel_store

rpm_decel_result_select:     L       A, er0

rpm_decel_store:     ST      A, off(001f0h)
                CLR     A
                CLRB    r0
                JBS     off(00125h).4, rpm_decel_flags_clear
                JBS     off(00124h).0, rpm_decel_flags_clear
                MOVB    r0, #004h
                JBS     off(00124h).2, rpm_decel_flags_clear
                MOVB    r0, off(00154h)
                CMPB    r0, #000h
                JNE     rpm_decel_table_lookup
                JBR     off(00123h).1, rpm_decel_counter_check
                CMPB    0d5h, #003h
                JGE     rpm_decel_flags_clear

rpm_decel_counter_check:     MOVB    r1, off(00155h)
                CMPB    r1, #000h
                JEQ     rpm_decel_diff_check2
                DECB    r1
                JNE     rpm_decel_store_0x14a

rpm_decel_diff_check2:     L       A, off(00150h)
                JEQ     rpm_decel_flags_clear
                SUB     A, off(00152h)
                JGE     rpm_decel_flags_clear
                CLR     A
                SJ      rpm_decel_flags_clear

rpm_decel_table_lookup:     LB      A, off(currentRPMByte)
                MOV     X1, #tbl_rpm_decel
                VCAL    0
                ; warning: had to flip DD
                CMP     A, 0c8h
                CLR     A
                MOVB    r0, off(00154h)
                DECB    r0
                JBS     off(00123h).7, rpm_decel_store_0x150
                JGE     rpm_decel_store_0x150
                L       A, #0007dh
                JBS     off(0012eh).5, rpm_decel_mul_final
                L       A, #0007dh
                JBS     off(0012eh).6, rpm_decel_mul_final
                L       A, #0007dh
                JBR     off(0011eh).3, rpm_decel_mul_final
                L       A, #0007dh

rpm_decel_mul_final:     MOV     er0, off(00182h)
                MUL
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     rpm_decel_result_clear
                L       A, #0ffffh

rpm_decel_result_clear:     CLRB    r0

rpm_decel_flags_clear:     RB      off(0012eh).5
                RB      off(0012eh).6

rpm_decel_store_0x150:     ST      A, off(00150h)
                MOVB    r1, #004h

rpm_decel_store_0x14a:     ST      A, off(0014ah)
                MOVB    off(00154h), r0
                MOVB    off(00155h), r1
                JBR     off(00124h).4, tipin_time_calc
                CLR     A
                MOV     X1, A
; --- Fuel-cut injector kill: when the ignition-cut/injector-cut flag (off(00124h).4, set by
; the fuel-cut/rev-limiter master decision block) is active, zeroes all 6 per-cylinder
; injector timer-compare registers directly (the same registers programmed by the cranking
; fuel calc and injector_timer_schedule) and jumps straight to the output continuation,
; skipping tipin_time_calc entirely.
                ST      A, 003b8h[X1]
                ST      A, 003bah[X1]
                ST      A, 003bch[X1]
                ST      A, 003beh[X1]
                ST      A, 003c0h[X1]
                ST      A, 003a6h[X1]
                J       postinj_rpm_check

tipin_time_calc:     L       A, off(00142h)
                L       A, ACC
                MOV     er0, A
                LC      A, TipinT
                CAL     mul_scale_clamp
                JBR     off(0012bh).3, tipin_time_sum
                CMPB    0f2h, #004h
                MB      off(0012bh).3, C
                ADD     A, #00064h
                JLT     tipin_time_clamp

tipin_time_sum:     ADD     A, off(00144h)
                JLT     tipin_time_clamp
                ADD     A, off(001f0h)
                JLT     tipin_time_clamp
                ADD     A, off(0014ah)
                JGE     tipin_time_finalize

tipin_time_clamp:     L       A, #0ffffh

tipin_time_finalize:     ST      A, er0
                LB      A, off(00148h)
                EXTND
                MOV     er3, off(00146h)
                CAL     signextend_helper
                LB      A, off(00149h)
                EXTND
                CAL     signextend_helper
                CMP     A, #08000h
                JGE     tipin_overflow_check1
                ADD     A, er0
                JGE     tipin_overflow_check2
                SJ      tipin_overflow_clamp

tipin_overflow_check1:     ADD     A, er0
                JGE     tipin_result_store

tipin_overflow_check2:     CMP     A, #08000h
                JLT     tipin_result_store

tipin_overflow_clamp:     L       A, #07fffh

tipin_result_store:     ST      A, er3
                MOV     X2, A
                L       A, off(00140h)
                MOV     er0, off(00156h)
                MUL
                SRL     er1
                ROR     A
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     injtimer_bank_a_calc
                L       A, #0ffffh

injtimer_bank_a_calc:     ST      A, er2
                XCHG    A, er3
                VCAL    4
                JBR     off(00124h).5, injtimer_bank_a_store
                CLR     A

injtimer_bank_a_store:     MOV     DP, #003a6h
                ST      A, [DP]
                L       A, er3
                MOV     DP, #003b8h
                MOV     er0, [DP]
                ST      A, [DP]
                JBS     off(00125h).4, injtimer_bank_b_zero
                CMPB    off(currentRPMByte), #070h
                JGE     injtimer_bank_b_zero
                CMP     off(0014ah), #00000h
                JNE     injtimer_bank_b_zero
                JBR     off(0012eh).4, injtimer_bank_b_check
                JBR     off(0012ch).3, injtimer_bank_b_zero
                CLRB    r0
                MOVB    r1, #080h
                L       A, off(00142h)
                SJ      injtimer_bank_b_mul

injtimer_bank_b_check:     SUB     A, er0
                JLT     injtimer_bank_b_zero
                CMP     A, #000fah
                JGE     injtimer_bank_b_clamp

injtimer_bank_b_zero:     CLR     A
                SJ      injtimer_bank_b_store

injtimer_bank_b_clamp:     MOV     er0, #007d0h
                CMP     A, er0
                JGE     injtimer_bank_b_default
                ST      A, er0

injtimer_bank_b_default:     CLR     A
                MOVB    ACCH, #080h

injtimer_bank_b_mul:     MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     injtimer_bank_b_store
                L       A, #0ffffh

injtimer_bank_b_store:     ST      A, off(0014eh)
                L       A, off(0014ah)
                CMP     A, off(0014eh)
                MB      off(0012ch).5, C
                JGE     injtimer_bank_c_check
                L       A, off(0014eh)

injtimer_bank_c_check:     L       A, ACC
                JEQ     injtimer_bank_c_store
                ADD     A, off(00144h)
                JGE     injtimer_bank_c_scale
                L       A, #0ffffh

injtimer_bank_c_scale:     CAL     scale_mul5_div4

injtimer_bank_c_store:     MOV     X1, A
                JBR     off(0012ch).5, injtimer_critsection_start
                CLR     A

injtimer_critsection_start:     AND     IE, #002a0h
; --- Per-cylinder injector timer write (critical section, interrupts masked via IE/PSWH):
; cylinder_ign_correct_loop applies CylinderIGNCorrect (real per-cylinder ignition-correction
; calibration table) and a mul5/div4 scale to each cylinder's computed value, writing results
; to the injector timer-compare registers up through 0x3C0 -- this is the routine referenced
; back in ign_angle_to_timer_convert's comment as "programming the two ignition coil-channel
; hardware timers" (the same critical-section pattern, here for injector-side output).
                ANDB    PSWH, #0feh
                MOV     off(0019ch), X1
                ST      A, off(00198h)
                ST      A, off(0019ah)
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MOV     X1, #CylinderIGNCorrect

cylinder_ign_correct_loop:     INC     DP
                INC     DP
                L       A, er2
                ST      A, er0
                CLR     A
                LCB     A, [X1]
                SWAP
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     cylinder_ign_correct_apply
                L       A, #0ffffh

cylinder_ign_correct_apply:     MOV     er3, X2
                XCHG    A, er3
                VCAL    4
                CAL     scale_mul5_div4
                ST      A, [DP]
                INC     X1
                CMP     DP, #003c0h
                JLT     cylinder_ign_correct_loop


postinj_rpm_check:     LB      A, #0c5h
                JBS     off(0012bh).2, postinj_rpm_flag_store
                LB      A, #0c8h

postinj_rpm_flag_store:     CMPB    A, off(currentRPMByte)
                MB      off(0012bh).2, C
                L       A, #0186ah
                JBR     off(001f8h).2, postinj_period_flag_store
                L       A, #030d4h

postinj_period_flag_store:     CMP     0c4h, A
                MB      off(001f8h).2, C
                LB      A, off(0013dh)
                JNE     deadtime_retry_check
                LB      A, #005h
                JBS     off(00125h).4, deadtime_skip_to_2226
                MOVB    r6, #00ah
                RB      PSWL.4
                L       A, off(0011ah)
                AND     A, #01034h
                JNE     deadtime_apply_check
                SB      PSWL.4
                MOVB    r6, #005h
                JBR     off(001f8h).2, deadtime_apply_check
                MOVB    r6, #007h
                JBS     off(0012ch).5, deadtime_apply_check
                RB      PSWL.4
                CMPB    0d9h, #0ffh
                JGE     deadtime_ect_offset
                MOVB    r6, #009h
                JBS     off(00120h).0, deadtime_apply_check

deadtime_ect_offset:     CLR     DP
                LB      A, 0d9h
                CMPB    A, #0a1h
                JLT     deadtime_voltage_check
                ADD     DP, #00003h

deadtime_voltage_check:     RB      off(0012bh).1
                LB      A, #0a8h
                JBS     off(0012bh).0, deadtime_voltage_flag_store
                LB      A, #095h

deadtime_voltage_flag_store:     CMPB    0beh, A
                MB      off(0012bh).0, C
                JGE     deadtime_table_lookup
                INC     DP
                JBR     off(0012bh).1, deadtime_table_lookup
                INC     DP


deadtime_table_lookup:     LCB     A, InjectorTable[DP]
                STB     A, r6
                SJ      deadtime_apply_check

deadtime_retry_check:     MB      C, sysFlags_b7.0
; --- Injector deadtime/battery-voltage compensation (0x21A5-0x2225ish): selects an ECT/
; battery-voltage-indexed offset into InjectorTable (real calibration field -- injector-size
; dependent deadtime compensation), applies it, then computes effective injector pulse width
; after subtracting deadtime.
                JGE     deadtime_retry_store
                LB      A, #005h

deadtime_retry_store:     SUBB    A, #001h
                STB     A, off(0013dh)
                LB      A, #00bh

deadtime_skip_to_2226:     SJ      injector_effective_pw_store

deadtime_apply_check:     LB      A, r6
                MB      C, PSWL.4
                JLT     deadtime_skip_to_2226
                MOV     DP, #003b8h
                L       A, [DP]
                CAL     scale_mul5_div4
                CLR     er0
                MOV     er2, off(00136h)
                DIV
                JLT     injector_effective_pw_skip
                CMP     A, #0000bh
                JGT     injector_effective_pw_skip
                LB      A, ACC
                XCHGB   A, r6
                SUBB    A, r6
                JLT     injector_effective_pw_skip
                JBS     off(0012bh).2, injector_effective_pw_calc
                MOVB    r6, off(0013bh)
                SUBB    r6, #001h
                JLT     injector_effective_pw_calc
                CMPB    A, r6
                JNE     injector_effective_pw_calc
                MOV     X1, er1
                STB     A, r6
                L       A, #08000h
                MOV     er0, er2
                MUL
                L       A, er1
                CMP     A, X1
                LB      A, r6
                JLT     injector_effective_pw_calc
                CMPB    A, #00bh
                JGE     injector_effective_pw_calc
                ADDB    A, #001h

injector_effective_pw_calc:     SJ      injector_effective_pw_store

injector_effective_pw_skip:     CLRB    A

injector_effective_pw_store:     STB     A, off(0013bh)
                LB      A, #0c2h
                JBS     off(00124h).0, rpm_hyst_flag_124_0
                LB      A, #0c5h

rpm_hyst_flag_124_0:     CMPB    A, off(currentRPMByte)
                MB      off(00124h).0, C
                LB      A, #0edh
                JBS     off(00124h).1, rpm_hyst_flag_124_1
                LB      A, #0f0h

rpm_hyst_flag_124_1:     CMPB    A, off(currentRPMByte)
                MB      off(00124h).1, C
                JBR     off(00121h).3, crank_edge_carry_clear
                JBR     off(0011eh).6, crank_edge_carry_clear
                LB      A, off(001bch)
                JNE     crank_edge_carry_clear
                JBR     off(00121h).2, crank_edge_carry_clear
                MOV     DP, #00f00h
                LB      A, [DP]
                ANDB    A, #040h
                MB      C, 0b8h.2
                JLT     crank_edge_sync_check
                JNE     crank_edge_carry_set
                RB      P1.2
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, P1
                MOV     DP, #02f00h
                STB     A, [DP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                SJ      crank_edge_direction_toggle

crank_edge_sync_check:     JEQ     crank_edge_carry_set

crank_edge_direction_toggle:     XORB    PSWH, #080h
                MB      0b8h.2, C
                JGE     crank_edge_carry_clear
                MOVB    off(001bch), #019h

crank_edge_carry_clear:     RC
                SJ      dtc27_code27_latch

crank_edge_carry_set:     SC

dtc27_code27_latch:     MB      0b3h.2, C
                CAL     crank_edge_helper
                SB      0b6h.4
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                J       int1_rti_epilogue

int_spurious_irq_trap: MOVB trapReasonCode, #045h ; shared trap for never-enabled vectors (TM0/1/3 ovf, A/D done,
                                                  ; serial TX BRG): stamps code 045h, retry-then-BRK below
                SJ      fault_retry_check

int_WDT:        MOVB    trapReasonCode, #044h

fault_retry_check:     LB      A, trapRetryCounter
                JEQ     fault_giveup_latch
                DECB    trapRetryCounter
                JNE     fault_trigger_brk

fault_giveup_latch:     SB      sysFlags_b7.1

fault_trigger_brk:     BRK

int_start:      MOVB    trapReasonCode, #046h
                RB      sysFlags_b7.1

int_break:      MOVB    WDT, #03ch
                MOV     SSP, #0047eh
                MOV     LRB, #00010h           ; 22BE 0 080 ??? 571000
                CLR     off(PSW)               ; 22C1 0 080 ??? B40415
                LB      A, off(trapReasonCode)         ; 22C4 0 080 ??? F4F5
                STB     A, off(lastTrapReasonCode)         ; 22C6 0 080 ??? D4AF
                JNE     breset_check_reason_46_47             ; 22C8 0 080 ??? CE06
                MOVB    off(trapReasonCode), #04eh     ; 22CA 0 080 ??? C4F5984E
                SJ      fault_retry_check             ; 22CE 0 080 ??? CBD2

breset_check_reason_46_47:     CMPB    A, #046h               ; 22D0 0 080 ??? C646
                JEQ     breset_reason_46_or_47_common             ; 22D2 0 080 ??? C904
                CMPB    A, #047h               ; 22D4 0 080 ??? C647
                JNE     breset_check_p4_1             ; 22D6 0 080 ??? CE12

breset_reason_46_or_47_common:     CLRB    off(lastTrapReasonCode)            ; 22D8 0 080 ??? C4AF15
                MOV     DP, #04700h            ; 22DB 0 080 ??? 620047
                LB      A, [DP]                ; 22DE 0 080 ??? F2
                SRLB    A                      ; 22DF 0 080 ??? 63
                MB      off(sysFlags_b7).0, C       ; 22E0 0 080 ??? C4B738
                JBS     off(sysFlags_b7).1, breset_check_p4_1 ; 22E3 0 080 ??? E9B704
                MOVB    off(trapRetryCounter), #020h     ; 22E6 0 080 ??? C4F69820

breset_check_p4_1:     JBR     off(P4).1, selftest_reg_stuckbit_check  ; 22EA 0 080 ??? D92C03
                J       int_NMI                ; 22ED 0 080 ??? 033C00

selftest_reg_stuckbit_check:     L       A, #05555h             ; 22F0 1 080 ??? 675555
                XCHG    A, SSP                 ; 22F3 1 080 ??? A010
                XCHG    A, SSP                 ; 22F5 1 080 ??? A010
                CMP     A, #05555h             ; 22F7 1 080 ??? C65555
                JNE     selftest_fail_041             ; 22FA 1 080 ??? CE5E
                ST      A, IE                  ; 22FC 1 080 ??? D51A
                CMP     A, IE                  ; 22FE 1 080 ??? B51AC2
                JNE     selftest_fail_041             ; 2301 1 080 ??? CE57
                L       A, #01555h             ; 2303 1 080 ??? 675515
                MOV     LRB, A                 ; 2306 1 080 ??? A48A
                CMP     A, LRB                 ; 2308 1 080 ??? A4C2
                JNE     selftest_fail_041             ; 230A 1 080 ??? CE4E
                L       A, #0aaaah             ; 230C 1 080 ??? 67AAAA
                XCHG    A, SSP                 ; 230F 1 080 ??? A010
                XCHG    A, SSP                 ; 2311 1 080 ??? A010
                CMP     A, #0aaaah             ; 2313 1 080 ??? C6AAAA
                JNE     selftest_fail_041             ; 2316 1 080 ??? CE42
                ST      A, IE                  ; 2318 1 080 ??? D51A
                CMP     A, IE                  ; 231A 1 080 ??? B51AC2
                JNE     selftest_fail_041             ; 231D 1 080 ??? CE3B
                L       A, #00aaah             ; 231F 1 080 ??? 67AA0A
                MOV     LRB, A                 ; 2322 1 080 ??? A48A
                CMP     A, LRB                 ; 2324 1 080 ??? A4C2
                JNE     selftest_fail_041             ; 2326 1 080 ??? CE32
                CLR     A                      ; 2328 1 080 ??? F9
                ST      A, IE                  ; 2329 1 080 ??? D51A
                ST      A, 0f8h                ; 232B 1 080 ??? D5F8
                ST      A, 0fah                ; 232D 1 080 ??? D5FA
                MOV     LRB, #00010h           ; 232F 1 080 ??? 571000
                LB      A, #055h               ; 2332 0 080 ??? 7755
                XCHGB   A, PSWL                ; 2334 0 080 ??? A310
                XCHGB   A, PSWL                ; 2336 0 080 ??? A310
                CMPB    A, #0ddh               ; 2338 0 080 ??? C6DD
                JNE     selftest_fail_041             ; 233A 0 080 ??? CE1E
                LB      A, #0aah               ; 233C 0 080 ??? 77AA
                XCHGB   A, PSWL                ; 233E 0 080 ??? A310
                XCHGB   A, PSWL                ; 2340 0 080 ??? A310
                CMPB    A, #0eah               ; 2342 0 080 ??? C6EA
                JNE     selftest_fail_041             ; 2344 0 080 ??? CE14
                SB      PSWH.0                 ; 2346 0 080 ??? A218
                MB      C, PSWH.0              ; 2348 0 080 ??? A228
                MB      PSWH.6, C              ; 234A 0 080 ??? A23E
                JGE     selftest_fail_041             ; 234C 0 080 ??? CD0C
                JNE     selftest_fail_041             ; 234E 0 080 ??? CE0A
                RB      PSWH.0                 ; 2350 0 080 ??? A208
                MB      C, PSWH.0              ; 2352 0 080 ??? A228
                MB      PSWH.6, C              ; 2354 0 080 ??? A23E
                JLT     selftest_fail_041             ; 2356 0 080 ??? CA02
                JNE     periph_init_start             ; 2358 0 080 ??? CE05

selftest_fail_041:     MOVB    trapReasonCode, #041h            ; 235A 0 080 ??? C5F59841
                BRK                            ; 235E 0 080 ??? FF

periph_init_start:     CLRB    off(PRPHF)             ; 235F 0 080 ??? C41215
                LB      A, #0ffh               ; 2362 0 080 ??? 77FF
                MOVB    off(P0), #0ebh         ; 2364 0 080 ??? C42098EB
                STB     A, off(P0IO)           ; 2368 0 080 ??? D421
                MOVB    off(P1), #044h         ; 236A 0 080 ??? C4229844
                STB     A, off(P1IO)           ; 236E 0 080 ??? D423
                MOVB    off(P2), #01fh         ; 2370 0 080 ??? C424981F
                STB     A, off(P2IO)           ; 2374 0 080 ??? D425
                CLRB    off(P2SF)              ; 2376 0 080 ??? C42615
                MOVB    off(P3), #0efh         ; 2379 0 080 ??? C42898EF
                MOVB    off(TCON0), #08bh      ; 237D 0 080 ??? C440988B
                CLR     A                      ; 2381 1 080 ??? F9
                ST      A, off(TM0)            ; 2382 1 080 ??? D430
                ST      A, off(TMR0)           ; 2384 1 080 ??? D432
                MOVB    off(TCON1), #04fh      ; 2386 1 080 ??? C441984F
                ST      A, off(TM1)            ; 238A 1 080 ??? D434
                ST      A, off(TMR1)           ; 238C 1 080 ??? D436
                MOVB    off(TCON2), #082h      ; 238E 1 080 ??? C4429882
                ST      A, off(TM2)            ; 2392 1 080 ??? D438
                ST      A, off(TMR2)           ; 2394 1 080 ??? D43A
                MOVB    off(TCON3), #08fh      ; 2396 1 080 ??? C443988F
                MOV     off(TM3), #00001h      ; 239A 1 080 ??? B43C980100
                ST      A, off(TMR3)           ; 239F 1 080 ??? D43E
                MOVB    off(P3IO), #0b1h       ; 23A1 1 080 ??? C42998B1
                MOVB    off(P3SF), #0ffh       ; 23A5 1 080 ??? C42A98FF
                CLRB    off(EXION)             ; 23A9 1 080 ??? C41C15
                SB      off(TCON0).2           ; 23AC 1 080 ??? C4401A
                RB      off(TCON0).2           ; 23AF 1 080 ??? C4400A
                MOVB    off(P4), #0f7h         ; 23B2 1 080 ??? C42C98F7
                L       A, #0ff00h             ; 23B6 1 080 ??? 6700FF
                MOVB    off(PWCON0), #03dh     ; 23B9 1 080 ??? C478983D
                ST      A, off(PWMC0)          ; 23BD 1 080 ??? D470
                ST      A, off(PWMR0)          ; 23BF 1 080 ??? D472
                MOVB    off(PWCON1), #07dh     ; 23C1 1 080 ??? C47A987D
                ST      A, off(PWMC1)          ; 23C5 1 080 ??? D474
                ST      A, off(PWMR1)          ; 23C7 1 080 ??? D476
                MOVB    off(P4IO), #00dh       ; 23C9 1 080 ??? C42D980D
                MOVB    off(P4SF), #0f4h       ; 23CD 1 080 ??? C42E98F4
                SB      off(TCON0).4           ; 23D1 1 080 ??? C4401C
                SB      off(TCON1).4           ; 23D4 1 080 ??? C4411C
                SB      off(TCON2).4           ; 23D7 1 080 ??? C4421C
                XCHG    A, ACC                 ; 23DA 1 080 ??? B50610
                SB      off(TCON3).4           ; 23DD 1 080 ??? C4431C
                CLR     off(IRQ)               ; 23E0 1 080 ??? B41815
                MOV     DP, #002e8h            ; 23E3 1 080 ??? 62E802

periph_init_delay_loop:     DEC     DP                     ; 23E6 1 080 ??? 82
                JNE     periph_init_delay_loop             ; 23E7 1 080 ??? CEFD
                RB      off(IRQH).5            ; 23E9 1 080 ??? C4190D
                L       A, #0ffffh             ; 23EC 1 080 ??? 67FFFF
                ST      A, off(PWMR0)          ; 23EF 1 080 ??? D472
                ST      A, off(PWMR1)          ; 23F1 1 080 ??? D476
                L       A, #05555h             ; 23F3 1 080 ??? 675555
                MOV     X1, A                  ; 23F6 1 080 ??? 50
                CMP     A, X1                  ; 23F7 1 080 ??? 90C2
                JNE     selftest_fail_042             ; 23F9 1 080 ??? CE10
                MOV     X2, A                  ; 23FB 1 080 ??? 51
                CMP     A, X2                  ; 23FC 1 080 ??? 91C2
                JNE     selftest_fail_042             ; 23FE 1 080 ??? CE0B
                SLL     A                      ; 2400 1 080 ??? 53
                MOV     X1, A                  ; 2401 1 080 ??? 50
                CMP     A, X1                  ; 2402 1 080 ??? 90C2
                JNE     selftest_fail_042             ; 2404 1 080 ??? CE05
                MOV     X2, A                  ; 2406 1 080 ??? 51
                CMP     A, X2                  ; 2407 1 080 ??? 91C2
                JEQ     ram_clear_loop1             ; 2409 1 080 ??? C905

selftest_fail_042:     MOVB    off(trapReasonCode), #042h     ; 240B 1 080 ??? C4F59842
                BRK                            ; 240F 1 080 ??? FF

ram_clear_loop1:     MOV     LRB, #00040h
                MOV     X1, #003fah

ram_clear_loop1_body:     MOV     DP, 00084h[X1]
                L       A, #05555h
                CAL     selftest_regbank_verify
                SLL     A
                CAL     selftest_regbank_verify
                SUB     X1, #00002h
                JGE     ram_clear_loop1_body
                MOV     LRB, #00041h
                CMPB    trapReasonCode, #047h
                JNE     restore_trapstate_after_ramclear
                MOV     DP, #0031dh
                LCB     A, tbl_cfgvariant_max
                JNE     cfgvariant_check_bit0
                CLRB    [DP]
                SJ      cfgvariant_check_232h_bits45

cfgvariant_check_bit0:     MB      C, [DP].0
                JGE     cfgvariant_set_bit0_from_2edh_3
                JBR     off(002edh).1, cfgvariant_check_bit1
                JBR     off(002edh).2, cfgvariant_check_bit1

cfgvariant_set_bit0_from_2edh_3:     MB      C, off(002edh).3
                MB      [DP].0, C

cfgvariant_check_bit1:     MB      C, [DP].1
                JGE     cfgvariant_set_bit1_from_2eeh_4
                JBR     off(002edh).1, cfgvariant_check_232h_bits45
                JBR     off(002edh).2, cfgvariant_check_232h_bits45

cfgvariant_set_bit1_from_2eeh_4:     MB      C, off(002eeh).4
                MB      [DP].1, C

cfgvariant_check_232h_bits45:     JBR     off(00232h).4, cfgvariant_check_320h_bit7
                JBR     off(00232h).5, cfgvariant_check_320h_bit7
                CLR     A
                LB      A, r6
                CAL     cfgvariant_set_flags
                CMPB    r6, #018h
                JEQ     cfgvariant_index_lookup
                CAL     cfgvariant_eval_condition
                CAL     cfgvariant_snapshot_capture
                CAL     cfgvariant_checksum2_calc
                INC     DP
                L       A, er0
                ST      A, [DP]

cfgvariant_index_lookup:     CLR     A
                LB      A, r7
                LCB     A, tbl_cfgvariant_map[ACC]
                CMPB    A, r6
                JEQ     cfgvariant_clear_232h_bits45
                MOVB    trapReasonCode, #043h
                BRK

cfgvariant_clear_232h_bits45:     ANDB    off(00232h), #0cfh

cfgvariant_check_320h_bit7:     MOV     DP, #00320h
                RB      [DP].7
                CAL     cfgvariant_checksum_calc
                JBR     off(00232h).2, cfgvariant_check_232h_bits01
                JBR     off(00232h).3, cfgvariant_check_232h_bits01
                CAL     cfgvariant_state_reset
                ANDB    off(00232h), #0f3h

cfgvariant_check_232h_bits01:     JBR     off(00232h).0, restore_trapstate_after_ramclear
                JBR     off(00232h).1, restore_trapstate_after_ramclear
                CAL     cfgvariant_ram_init
                ANDB    off(00232h), #0fch

restore_trapstate_after_ramclear:     MOV     LRB, #00010h           ; 24AF 1 080 ??? 571000
                MB      C, off(sysFlags_b7).0       ; 24B2 1 080 ??? C4B728
                MB      r0.0, C                ; 24B5 1 080 ??? 2038
                MB      C, off(sysFlags_b7).1       ; 24B7 1 080 ??? C4B729
                MB      r0.1, C                ; 24BA 1 080 ??? 2039
                MOVB    r1, off(lastTrapReasonCode)        ; 24BC 1 080 ??? C4AF49
                MOVB    r2, off(trapRetryCounter)        ; 24BF 1 080 ??? C4F64A
                MOVB    r3, off(trapReasonCode)        ; 24C2 1 080 ??? C4F54B
                CLR     A                      ; 24C5 1 080 ??? F9
                MOV     USP, #00356h           ; 24C6 1 080 356 A1985603
                MOV     DP, #00480h            ; 24CA 1 080 356 628004

ram_clear_loop2:     DEC     DP                     ; 24CD 1 080 356 82
                DEC     DP                     ; 24CE 1 080 356 82
                ST      A, [DP]                ; 24CF 1 080 356 D2
                CMP     DP, off(00086h)        ; 24D0 1 080 356 92C386
                JGT     ram_clear_loop2             ; 24D3 1 080 356 C8F8
                CMP     DP, #00098h            ; 24D5 1 080 356 92C09800
                JLE     clear_0x324_high_nibble             ; 24D9 1 080 356 CF0E
                MOV     USP, #00098h           ; 24DB 1 080 098 A1989800
                CMPB    r3, #047h              ; 24DF 1 080 098 23C047
                JNE     ram_clear_loop2             ; 24E2 1 080 098 CEE9
                MOV     DP, #00300h            ; 24E4 1 080 098 620003
                SJ      ram_clear_loop2             ; 24E7 1 080 098 CBE4

clear_0x324_high_nibble:     MOV     DP, #00324h            ; 24E9 1 080 356 622403
                LB      A, [DP]                ; 24EC 0 080 356 F2
                ANDB    A, #0f0h               ; 24ED 0 080 356 D6F0
                STB     A, [DP]                ; 24EF 0 080 356 D2
                MB      C, r0.0                ; 24F0 0 080 356 2028
                MB      off(sysFlags_b7).0, C       ; 24F2 0 080 356 C4B738
                MB      C, r0.1                ; 24F5 0 080 356 2029
                MB      off(sysFlags_b7).1, C       ; 24F7 0 080 356 C4B739
                MOVB    off(lastTrapReasonCode), r1        ; 24FA 0 080 356 217CAF
                MOVB    off(trapRetryCounter), r2        ; 24FD 0 080 356 227CF6
                MOVB    off(trapReasonCode), r3        ; 2500 0 080 356 237CF5
                MOV     LRB, #00041h           ; 2503 0 208 356 574100
                SC                             ; 2506 0 208 356 85
                LB      A, lastTrapReasonCode                ; 2507 0 208 356 F5AF
                JNE     fuelpump_prime_check             ; 2509 0 208 356 CE08
                LCB     A, FPPrimeT            ; 250B 0 208 356 909D6A60
                MOVB    off(002c6h), A         ; 250F 0 208 356 C4C68A
                RC                             ; 2512 0 208 356 95

fuelpump_prime_check:     MB      off(00230h).5, C       ; 2513 0 208 356 C4303D
; --- Runtime state init: A/D channel setup, initial sensor snapshot, working-RAM seeding,
; and diagnostic-serial baud/config setup, run once during boot after the self-test/RAM-clear
; passes above. Ends by jumping to stack_sanity_check (0x3359) before falling into the main loop.
; Individual working-RAM addresses here (0xD8-0xE1, 0xDC-0xDF, etc.) are not yet traced to
; specific named parameters -- confidently identified: ADCR2H/ADCR4/ADCR6 (A/D conversion
; results), tbl_boot_copy_block (a calibration table copied verbatim into 0x1D1-0x1DD), and
; STTM/STTMR/STTMC/STCON/SRCON (serial timer + control regs -- diagnostic/K-line baud setup).
                MOV     USP, #00180h
                CLR     A
                ST      A, IE
                MOV     DP, A
                CLRB    ADSEL
                MOVB    ADSCAN, #010h
                RB      IRQH.4

adc_wait_loop:     MB      r0.0, C
                JRNZ    DP, adc_wait_loop
                CAL     idle_helper1
                LB      A, P2
                ANDB    A, #0e0h
                JNE     adc_wait_loop
                MOVB    0f7h, #001h
                CAL     empty_stub_return
                L       A, ADCR4
                ST      A, 09ch
                LB      A, ADCR2H
                STB     A, 0e1h
                MOV     DP, #0037bh
                STB     A, [DP]
                MOV     DP, #003cah
                LB      A, [DP]
                STB     A, 0dah
                MOV     DP, #003d1h
                LB      A, [DP]
                STB     A, 0dbh
                MOVB    0d8h, #056h
                MOVB    0d9h, #03bh
                MOVB    0bch, #0f9h
                LB      A, #01fh
                STB     A, 0dch
                STB     A, 0ddh
                STB     A, 0dfh
                L       A, ADCR6
                ST      A, 0bah
                LB      A, ACCH
                MOV     DP, #00376h
                STB     A, [DP]
                LB      A, #0a0h
                STB     A, off(00235h)
                STB     A, (00132h-00180h)[USP]
                STB     A, 0bdh
                MOV     DP, #00374h
                STB     A, [DP]
                INC     DP
                STB     A, [DP]
                L       A, #04d00h
                ST      A, 0d0h
                ST      A, 0d2h
                ST      A, er0
                SLL     A
                JLT     clamp_to_0xff
                SLL     A
                LB      A, ACCH
                JGE     clamp_result_store

clamp_to_0xff:     LB      A, #0ffh

clamp_result_store:     STB     A, 0d4h
                CAL     boot_completion_helper
                CLR     X1
                SB      off(00231h).5
                MOV     0ceh, #0ffffh
                SB      off(00231h).3
                MOV     098h, #000e1h
                MOV     09ah, #0091fh
                L       A, #00001h
                ST      A, (00114h-00180h)[USP]
                ST      A, (00112h-00180h)[USP]
                ST      A, (00110h-00180h)[USP]
                LB      A, #00fh
                STB     A, (00117h-00180h)[USP]
                STB     A, (00197h-00180h)[USP]
                LB      A, 003d4h[X1]
                STB     A, 00377h[X1]
                CAL     ect_step_helper
                CLRB    A
                MOV     DP, #001d1h

tbl6b1f_copy_loop:     LCB     A, tbl_boot_copy_block[DP]
                STB     A, [DP]
                INC     DP
                CMP     DP, #001deh
                JNE     tbl6b1f_copy_loop
                MOVB    00397h[X1], #0ffh
                MOVB    off(002fah), #0f9h
                MOVB    off(002bch), #002h
                MOVB    off(002bdh), #002h
                MOVB    00379h[X1], #053h
                LB      A, 00310h[X1]
                MOVB    ACC, #07bh
                JNE     serial_baud_store_common
                STB     A, 00311h[X1]

serial_baud_store_common:     STB     A, 0037ah[X1]
                SB      off(00225h).1
                CMPB    trapReasonCode, #047h
                JEQ     serial_baud_select_done
                MOVB    0031ah[X1], #03bh

serial_baud_select_done:     MOVB    off(002c1h), #032h
                MOVB    r0, #01ch
                MOVB    r1, #08ch
                LB      A, #0f8h
                MOV     DP, #00356h
                MB      C, [DP].1
                JLT     serial_baud_apply
                MOVB    r0, #031h
                MOVB    r1, #0a1h
                LB      A, #0fbh

serial_baud_apply:     STB     A, STTM
                STB     A, STTMR
                MOVB    STTMC, #012h
                LB      A, r0
                STB     A, STCON
                LB      A, r1
                STB     A, SRCON
                MOV     DP, #04700h
                LB      A, [DP]
                XORB    A, #01ah
                STB     A, off(00211h)
                STB     A, (00119h-00180h)[USP]
                CLR     A
                MOV     DP, #003fch
                LC      A, 00038h
                ST      A, [DP]
                INC     DP
                INC     DP
                LC      A, 0003ah
                ST      A, [DP]
                CLRB    trapReasonCode
                CLR     X1
                CLRB    0040eh[X1]
                CLRB    0040fh[X1]
                CLRB    00420h[X1]
                CLRB    00427h[X1]
                CLRB    00437h[X1]
                CLRB    00438h[X1]
                MOV     0043ah[X1], #0043ah
                CLRB    0043ch[X1]
                LB      A, #080h
                STB     A, 00412h[X1]
                STB     A, 0041dh[X1]
                STB     A, off(00252h)
                STB     A, off(00253h)
                J       stack_sanity_check

vcal_3:         L       A, 0fah
; ============================================================================================
; VCAL 3 target routine -- called from dozens of sites throughout the ROM (LeanProtect,
; fuel-cut, and many other subsystems) as a periodic "housekeeping tick": runs
; leanprotect_rpm_gate every call (rate-limited via a counter at 0x9E), then, roughly once
; every ~2 calls (vcal3_leanprotect_ratelimit's JGE), dispatches into a round-robin scheduler
; of periodic background tasks selected by off(00231h) bits 0/1/2 and a rotating flag
; (0xB6.4): vcal3_task_a (-> 0x29A5), vcal3_dispatch_check2/vcal3_task_b (-> 0x3221),
; vcal3_dispatch_check1 (-> 0x314C), or vcal3_main_task (the "everything else" path: resets
; the watchdog, runs ictimemod_check_start, then decrements several arrays of software
; countdown timers via decrement_timer_array with different base-pointer/count pairs).
; This is effectively the ROM's cooperative background-task scheduler, invoked opportunistically
; from many unrelated routines rather than from one central main loop.
; ============================================================================================
                ST      A, IE
                ANDB    PSWH, #0feh
                CAL     leanprotect_rpm_gate
                LB      A, 09eh
                SUBB    A, #005h
                JLT     vcal3_leanprotect_ratelimit
                STB     A, 09eh

vcal3_leanprotect_ratelimit:     ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JGE     vcal3_main_task
                RB      (0012ah-00180h)[USP].2
                MB      C, 0b6h.4
                JGE     vcal3_dispatch_check1
                JBR     off(0022bh).0, vcal3_task_a
                RB      off(00231h).0
                JNE     vcal3_task_a
                RB      0b6h.4
                RT

vcal3_task_a:     J       battery_voltage_check

vcal3_dispatch_check1:     RB      off(00231h).1
                JEQ     vcal3_dispatch_check2
                J       vcal3_task_c

vcal3_dispatch_check2:     RB      off(00231h).2
                JNE     vcal3_task_b
                RT

vcal3_task_b:     J       vcal3_task_b_body

vcal3_main_task:CAL     hts_tick                    ; HTS120 hook
                CAL     ictimemod_check_start
                CLR     X1
                MOV     DP, #00009h
                MOV     X1, #001c8h
                CAL     decrement_timer_array
                MOV     DP, #0000bh
                MOV     X1, #002f4h
                CAL     decrement_timer_array
                MOV     DP, #00004h
                MOV     X1, #003f7h
                CAL     decrement_timer_array
                DECB    off(002b4h)
                MOV     DP, #003fah
                LB      A, [DP]
                JNE     scheduler_slowflag_check
                MOV     DP, #003afh
                STB     A, [DP]

scheduler_slowflag_check:     CLR     A
                LB      A, off(002fah)
                JNE     scheduler_divider_check
                LB      A, #0fah
                STB     A, off(002fah)
                MB      C, off(00231h).7
                XORB    PSWH, #080h
                MB      off(00231h).7, C
                JLT     scheduler_divider_check
                SB      off(00231h).2

scheduler_divider_check:     MOVB    r0, #00ah
                DIVB
                LB      A, r1
                JNE     scheduler_task_done
                SB      off(00231h).1
                JBR     off(00216h).5, scheduler_gate_common
                L       A, off(00214h)
                AND     A, #00320h
                JNE     scheduler_gate_common
                L       A, off(00212h)
                AND     A, #001bch
                JNE     scheduler_gate_common
                JBR     off(0021ah).6, scheduler_gate_common
                JBS     off(0021ah).7, scheduler_gate_common
                LB      A, 0d9h
                CMPB    A, #000h
                JLE     scheduler_ect_sign_check
                CMPB    A, #000h
                JGE     scheduler_ect_sign_check
                XORB    P0, #040h
                RB      off(00224h).7
                SJ      scheduler_task_done

scheduler_gate_common:     SB      P0.6
                SB      off(00224h).7
                SJ      scheduler_task_done

scheduler_ect_sign_check:     RB      P0.6
                RB      off(00224h).7

scheduler_task_done:     MOV     DP, #000ceh
; --- VSS (vehicle speed) calculation (0x274A-0x27E4ish): measures a speed-sensor pulse
; period (0xA8/0xAC), divides vssSpeedNumerator by the pulse period and a plausibility-range check
; (0x373-0x397D), applying sub_clamp_helper/mul_scale_helper2-style scaling, then clamps and stores
; the final VSS byte to 0xCC -- the same VSS value read throughout the session (fuel-cut,
; boost, wastegate, etc).
                JBS     off(00214h).0, vss_calc_skip
                RB      0b6h.2
                JEQ     vss_calc_gate2
                JBS     off(00217h).5, vss_calc_gate3
                CMPB    0dbh, #044h
                JLE     vss_calc_skip
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                MOVB    r0, 0aah
                L       A, 0a8h
                SUB     A, 0ach
                ST      A, er1
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                SBCB    r0, #000h
                SRLB    r0
                L       A, er1
                ROR     A
                CMPB    r0, #000h
                JNE     vss_calc_gate3
                RB      off(00231h).3
                JNE     vss_calc_done
                RB      off(00231h).4
                JNE     vss_calc_done
                CMP     A, #00373h
                MB      off(00231h).4, C
                JLT     vss_calc_done
                CMP     A, #0397dh
                JGE     vss_result_store
                MOV     er0, #01000h
                CMP     A, #005c0h
                JLT     vss_scale_apply
                MOV     er0, #04000h

vss_scale_apply:     CAL     mul_scale_helper2


vss_result_store:     ST      A, [DP]
                ST      A, er2
vssSpeedNumerator    equ 05fb4h ; VSS: speed = (3 * 10000h + vssSpeedNumerator) / pulse period (MOV er0,#3 / L A,# / DIV).
                                ; A number, not a table: it used to be bound to whatever label sat at this address.
                CAL     hts_vss_speed          ; HTS120: speed = 25FB4h / period x SpeedCorrection / 8000h
                ST      A, er1
                L       A, er0
                JNE     vss_clamp_max
                LB      A, r3
                JEQ     vss_clamp_common

vss_clamp_max:     MOVB    r2, #0ffh

vss_clamp_common:     LB      A, r2

vss_final_store:     STB     A, r2
                MOVB    r3, 0cch
                L       A, er1
                ST      A, 0cch
                SJ      vss_calc_done


vss_calc_skip:     L       A, #072FAh
                RB      off(00231h).3
                SJ      vss_result_store

vss_calc_gate2:     LB      A, #003h
                CMPB    0abh, A
                JLT     vss_calc_done
                STB     A, 0abh


vss_calc_gate3:     RB      off(00231h).4
                SB      off(00231h).3
                MOV     [DP], #0ffffh
                CLRB    A
                SJ      vss_final_store

vss_calc_done:     LB      A, #005h
                JBS     off(0021ah).2, vss_hysteresis_check
                LB      A, #007h

vss_hysteresis_check:     CMPB    A, 0cch
                MB      off(0021ah).2, C
                JBR     off(00227h).6, idle_gate1_clear
                JBS     off(00214h).7, idle_gate1_clear
                MOV     DP, #00f00h
                MB      C, [DP].2
                RB      off(00232h).6
                MB      off(00232h).6, C
                JEQ     idle_gate1
                XORB    PSWH, #080h

idle_gate1:     JGE     idle_gate1_timer_check
                CMPB    0c5h, #00dh
                JGT     idle_gate1_trigger
                JBS     off(00233h).7, idle_gate1_timer_check

idle_gate1_trigger:     MOVB    off(002fch), #00ah

idle_gate1_clear:     RC
                SJ      dtc24_code24_latch

idle_gate1_timer_check:     LB      A, off(002fch)
                JNE     idle_gate1_clear
                SC

dtc24_code24_latch:     MB      0b2h.3, C
; --- Idle Air Control (IAC) valve duty-cycle calculation (0x281E onward): selects IdleDC or
; IdleAC (real calibration fields) via ECT/mode gating, looks up a target duty cycle through
; tbl_idle_dc (via table_interp_lookup_4byte, a 4-byte-stride variant of the earlier 2-byte
; table_interp_lookup), and computes a delta-based correction. This is the base idle-speed
; valve control routine.
                RB      (0012ah-00180h)[USP].2
                CAL     idle_helper1
                CLRB    r2
                MOVB    off(00245h), r2
                MOVB    (001d5h-00180h)[USP], #0ffh
                MOVB    (001d6h-00180h)[USP], #0ffh
                RB      0b2h.4
                RB      0b2h.5
                JBR     off(002b4h).0, idle_dc_select
                SJ       idle_mode_gate2

idle_mode_gate2:     JBR     off(002b4h).0, idle_dc_select
                J       transit_flag_check

idle_dc_select:     LC      A, IdleDC
                JBR     off(00226h).4, idle_dc_table_lookup
                LC      A, IdleAC

idle_dc_table_lookup:     MOV     DP, A
                L       A, 098h
                MOV     X1, #tbl_idle_dc
                CAL     table_interp_lookup_4byte
                SUB     A, DP
                MOV     er0, 09ch
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_dc_result_store
                L       A, #0ffffh

idle_dc_result_store:     MOV     DP, #00382h
                ST      A, [DP]
                MOV     er3, off(00290h)
                SUB     A, off(0025ch)
                MB      r4.0, C
                JEQ     idle_delta_flag_set
                RB      off(00225h).6
                MB      off(00225h).6, C
                JEQ     idle_delta_flag_check
                XORB    PSWH, #080h

idle_delta_flag_check:     JGE     idle_delta_flag_store

idle_delta_flag_set:     SC

idle_delta_flag_store:     MB      r4.1, C
                MOV     X1, #000e1h
                MOV     X2, #0091fh
                JBR     off(0020ch).0, idle_helper2_call1
                VCAL    7

idle_helper2_call1:     ST      A, er0
                L       A, #005a0h
                CAL     idle_helper2
                MOV     DP, A
                L       A, #00118h
                CMPB    (001c4h-00180h)[USP], #004h
                JGE     idle_helper2_call2
                L       A, #015e0h

idle_helper2_call2:     CAL     idle_helper2
                XCHG    A, 098h
                ST      A, er0
                CLRB    A
                JGE     idle_target_store
                JBR     off(0020ch).1, idle_step_store
                SJ      idle_step_default

idle_target_store:     L       A, DP
                ST      A, off(00290h)
                L       A, er0
                CMP     A, 098h
                JEQ     idle_step_default
                JBR     off(0020ch).1, idle_debounce_gate

idle_step_default:     LB      A, #00ah

idle_step_store:     STB     A, (001c4h-00180h)[USP]

idle_debounce_gate:     MB      C, sysFlags_b7.1
                JLT     idle_debounce_disabled
                JBR     off(00230h).2, idle_debounce_skip
                MOV     DP, #01f00h
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, P0
                STB     A, [DP]
                STB     A, r0
                MOVB    r1, [DP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                LB      A, r1
                CMPB    A, r0
                JNE     idle_port_p1_check
                MOV     DP, #02f00h
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, P1
                STB     A, [DP]
                STB     A, r0
                MOVB    r1, [DP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                LB      A, r1
                CMPB    A, r0
                JEQ     idle_debounce_done

idle_port_p1_check:     LB      A, #04dh
                STB     A, lastTrapReasonCode
                DECB    0f7h
                JNE     idle_debounce_skip
                STB     A, trapReasonCode
                CLRB    trapRetryCounter
                J       fault_retry_check

idle_debounce_skip:     L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                CAL     port_debounce_helper
                ORB     PSWH, #001h
                SJ      idle_debounce_ie_restore

idle_debounce_done:     MOV     DP, #00f00h
                LB      A, [DP]
                XORB    A, #038h
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                STB     A, off(00210h)
                STB     A, (00118h-00180h)[USP]
                ORB     PSWH, #001h

idle_debounce_ie_restore:     L       A, 0f8h
                ST      A, IE

idle_debounce_disabled:     MOV     DP, #04700h
                LB      A, [DP]
                XORB    A, #01ah
                MB      C, off(00211h).4
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                STB     A, off(00211h)
                STB     A, (00119h-00180h)[USP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JGE     idle_debounce_return
                MOV     DP, #00420h
                MB      C, [DP].5
                JLT     idle_debounce_timer_set
                JBS     off(00211h).4, idle_debounce_return

idle_debounce_timer_set:     MOVB    off(002d9h), #014h

idle_debounce_return:     RT

transit_flag_check:     LB      A, #0ffh
                MOV     DP, #00397h
                RB      TRNSIT.3
                JNE     transit_flag_common
                SC
                LB      A, [DP]
                JEQ     transit_flag_store
                SUBB    A, #001h

transit_flag_common:     RC

transit_flag_store:     MB      off(00230h).6, C
                STB     A, [DP]
                JBR     off(002b4h).1, transit_gate_check
                RT

transit_gate_check:     MOV     DP, #000deh
                LB      A, 0dch
                STB     A, ACCH
                CLRB    A
                JBS     off(00214h).3, idle_scratch_store
                MB      C, 0b1h.7
                JLT     idle_task_done
                CMPB    0f3h, #032h
                JGE     idle_scratch_scale

idle_scratch_store:     MOV     [DP], A
                SJ      idle_task_done

idle_scratch_scale:     MOV     er0, #02400h
                CAL     mul_scale_helper2

idle_task_done:     SB      off(00231h).0
                RT

battery_voltage_check:     MB      C, off(0022bh).2
; --- vcal3_task_a body: packs 4 status bits into a nibble at off(00229h) (change-detected via
; XOR against the stored previous value), then a battery-voltage plausibility check (0xDC vs
; previous 0xDD, VCAL 6 if delta too large), followed by a bank of hysteresis threshold
; comparisons (off(0022ah) bits 4/5/6, each choosing between two thresholds) -- likely more
; voltage- or temperature-based hysteresis flags. No calibration anchors in this stretch.
                MB      off(0022bh).3, C
                CLRB    A
                MB      C, off(0021ah).4
                ROLB    A
                MB      C, off(00210h).3
                ROLB    A
                MB      C, off(00211h).2
                ROLB    A
                MB      C, off(00211h).5
                ROLB    A
                STB     A, r0
                XORB    A, off(00229h)
                ANDB    A, #00fh
                SWAPB
                ORB     A, r0
                STB     A, off(00229h)
                LB      A, 0dch
                STB     A, r0
                XCHGB   A, 0ddh
                SUBB    A, r0
                MB      off(00225h).2, C
                JGE     battery_voltage_store
                VCAL    6

battery_voltage_store:     STB     A, 0e0h
                MOVB    r0, 0dfh
                LB      A, #03ah
                JBS     off(0022ah).4, threshold_bank_check1
                LB      A, #023h

threshold_bank_check1:     CMPB    r0, A
                MB      off(0022ah).4, C
                LB      A, #064h
                JBS     off(0022ah).5, threshold_bank_check2
                LB      A, #04ch

threshold_bank_check2:     CMPB    r0, A
                MB      off(0022ah).5, C
                LB      A, #044h
                JBS     off(0022ah).6, threshold_bank_check3
                LB      A, #030h

threshold_bank_check3:     CMPB    r0, A
                MB      off(0022ah).6, C
                LB      A, #0ffh
                CMPB    A, 0e1h
                MB      off(0022ah).0, C
                LB      A, #0b0h
                JBS     off(0022ah).1, idle_temp_hyst1
                LB      A, #0c0h

idle_temp_hyst1:     CMPB    A, 0e1h
                MB      off(0022ah).1, C
                LB      A, #060h
                JBS     off(0022ah).2, idle_temp_hyst2
                LB      A, #06dh

idle_temp_hyst2:     CMPB    A, off(00236h)
                MB      off(0022ah).2, C
                LB      A, #0cdh
                JBS     off(0022ah).3, idle_temp_hyst3
                LB      A, #0d0h

idle_temp_hyst3:     CMPB    A, off(00236h)
                MB      off(0022ah).3, C
                LB      A, 0d9h
                STB     A, r0
                MOVB    r1, #03ch
                CMPB    A, r1
                JGE     idle_ectvs_check1
                LB      A, #050h
                CMPB    0d8h, #030h
                JGE     idle_flag_recheck2
                LB      A, #096h

idle_flag_recheck2:     CMPB    A, 0f3h
                JLT     idle_ectvs_check1
                MOV     er3, #00600h
                SJ      idle_ectvs_store

idle_ectvs_check1:     LB      A, r0
; --- Idle-target-vs-ECT selection (0x2A45-0x2AA1ish): IdleVsECT (real calibration field)
; combined with battery voltage (0xD9) and RPM-band checks (off(00272h)) picks between several
; fixed idle-target constants (0x120/0x430/0x600) -- classic cold-start fast-idle logic.
                MOV     X1, #IdleVsECT
                MOVB    r1, #037h
                MOVB    r2, #02dh
                CMPB    A, #016h
                JGE     idle_ectvs_check2

idle_ectvs_result1:     MOV     er3, #00430h
                SJ      idle_ectvs_store

idle_ectvs_check2:     CMPB    A, r1
                JGE     idle_ectvs_result3
                JBS     off(00217h).6, idle_ectvs_alt_check
                CMP     off(00272h), #08000h
                JGE     idle_ectvs_check3
                CMP     off(00272h), #00c00h
                JGE     idle_ectvs_result1

idle_ectvs_check3:     MOVB    r1, r2
                CMPB    A, r1
                JGE     idle_ectvs_result3

idle_ectvs_result2:     MOV     er3, #00120h

idle_ectvs_store:     LC      A, TargetIdle
; --- Loads the base TargetIdle calibration value, then idle_target_correction_start applies
; an IdleVsECT-indexed offset and a battery-voltage-gated correction (0xD9), feeding the result
; toward injtimer_bank_calc3 -- ties idle target directly into the injector timing chain.
                SJ      idle_target_correction_start

idle_ectvs_alt_check:     JBR     off(0022ah).4, idle_ectvs_gate2
                MOVB    off(002dbh), #014h
                SJ      idle_ectvs_result1

idle_ectvs_gate2:     JBR     off(00225h).1, idle_ectvs_gate3
                CMPB    off(002dbh), #000h
                JNE     idle_ectvs_result1

idle_ectvs_gate3:     MOVB    r1, r2
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, off(0027ah)
                JEQ     idle_ectvs_flag_check
                MOVB    off(002d8h), #01eh

idle_ectvs_flag_check:     LB      A, off(002d8h)
                JNE     idle_ectvs_result2
                JBS     off(00225h).1, idle_ectvs_result2

idle_ectvs_result3:     LB      A, r0
                VCAL    0
                CLR     er3

idle_target_correction_start:     MOV     DP, A
                L       A, er3
                JEQ     idle_target_correction_done
                MOV     X1, #IdleVsECT
                LCB     A, 0000fh[X1]
                MOVB    r4, A
                SUBB    r0, A
                L       A, er3
                JLE     idle_target_correction_done
                CLRB    A
                STB     A, r5
                XCHGB   A, r1
                CMPB    A, 0d9h
                JLE     idle_target_correction_zero
                XCHGB   A, r4
                SUBB    r4, A
                JLE     idle_target_correction_zero
                CLR     A
                CAL     injtimer_bank_calc3
                SJ      idle_target_correction_done


idle_target_correction_zero:     CLR     A

idle_target_correction_done:     ST      A, off(00278h)
; --- Idle stepper valve position control (0x2ACD onward): two more table interpolations
; (tbl_idle_target_refine1/tbl_idle_target_refine2 via table_interp_lookup_4byte) refine the target, then idle_step_loop
; incrementally steps a stored value at [DP] (0x386) toward the target by +/-8 per call
; (classic rate-limited servo step, not jump-to-target), gated by several engine-state flags
; and battery voltage. No calibration anchors for the individual gates.
                L       A, DP
                ST      A, off(0025ah)
                MOV     X1, #tbl_idle_target_refine1
                CAL     table_interp_lookup_4byte
                MOV     X2, A
                MOV     X1, #tbl_idle_target_refine2
                L       A, off(0025ah)
                CAL     table_interp_lookup_4byte
                MOV     er2, X2
                MOVB    r5, r6
                MOV     off(00294h), er2
                MB      C, off(0021ah).0
                MB      off(002eeh).1, C
                MOV     DP, #00386h
                JBR     off(00217h).5, idle_step_gate1
                CLR     [DP]

idle_step_loop:     MOVB    off(002d6h), #014h
                MOVB    (001b3h-00180h)[USP], #032h
                MOVB    off(002c7h), #064h
                SC
                SJ      idle_step_flag_store

idle_step_gate1:     JBR     off(0021ah).0, idle_step_return
                JBS     off(0022bh).4, idle_step_return
                MB      C, 0b0h.1
                JLT     idle_step_return
                JBS     off(00212h).5, idle_step_return
                LB      A, 0d9h
                MOV     X1, #tbl_idle_step
                VCAL    0
                L       A, off(0025ah)
                SUB     A, er3
                JGE     idle_step_diff_check
                CLR     A

idle_step_diff_check:     CMP     A, 0c4h
                JGE     idle_step_return
                JBS     off(0021ah).2, idle_step_return
                L       A, [DP]
                ADD     A, #00008h
                JGE     idle_step_store2
                L       A, #0ffffh

idle_step_store2:     ST      A, [DP]
                SJ      idle_step_loop

idle_step_return:     RC

idle_step_flag_store:     MB      off(0021ah).0, C
; --- Temperature-scheduled idle PID coefficient selection: picks between several pairs of
; unnamed tables (tbl_idle_pid_lo3/tbl_idle_pid_lo2/tbl_idle_pid_lo1 and tbl_idle_pid_hi3/tbl_idle_pid_hi2/tbl_idle_pid_hi1, etc.) based on ECT
; temperature bands, interpolates via table_interp_lookup, and combines into a PID-style
; correction (idle_pid_mul_apply/idle_pid_result_store) feeding the idle step control.
                L       A, off(0025ah)
                MOV     X1, #tbl_idle_pid_lo3
                MOV     X2, #tbl_idle_pid_hi3
                CMP     A, #00000h
                JLT     idle_pid_table_select2
                MOV     X1, #tbl_idle_pid_lo2
                MOV     X2, #tbl_idle_pid_hi2
                CMP     A, #00928h
                JLT     idle_pid_table_select2
                MOV     X1, #tbl_idle_pid_lo1
                MOV     X2, #tbl_idle_pid_hi1

idle_pid_table_select2:     JBS     off(00217h).6, idle_pid_table_lookup
                MOV     X1, #tbl_idle_pid_b
                MOV     X2, #tbl_idle_pid_d
                CMP     A, #00928h
                JLT     idle_pid_table_lookup
                MOV     X1, #tbl_idle_pid_a
                MOV     X2, #tbl_idle_pid_c

idle_pid_table_lookup:     LB      A, off(00236h)
                CAL     table_interp_lookup
                MOVB    r0, 0e1h
                MULB
                L       A, ACC
                ROL     A
                LB      A, ACCH
                JGE     idle_pid_mul_apply
                LB      A, #0ffh

idle_pid_mul_apply:     MOV     X1, X2
                VCAL    0
                MOV     DP, #0037ch
                MOVB    r1, [DP]
                CLRB    r0
                MUL
                ROLB    A
                L       A, er1
                ROL     A
                JGE     idle_p0_pin_check
                L       A, #0ffffh

idle_p0_pin_check:     MB      C, P0.2
                JGE     idle_pid_er3_store
                MOVB    r1, #040h
                CLRB    r0
                MUL
                L       A, er1

idle_pid_er3_store:     ST      A, er3
                JBS     off(0022bh).4, idle_pid_common
                MOVB    r1, #021h
                JBS     off(002edh).0, idle_pid_gate2
                JBS     off(00225h).1, idle_pid_gate3

idle_pid_gate2:     JBS     off(00211h).2, idle_pid_common
                JBS     off(0022ah).0, idle_pid_common
                LB      A, #028h
                CLRB    r1
                JBS     off(0022bh).5, idle_pid_recheck2
                LB      A, #028h
                MOVB    r1, #021h

idle_pid_recheck2:     MOVB    r2, 0e2h
                MB      C, off(0022bh).5
                JBR     off(00217h).6, idle_pid_hyst_check
                LB      A, #020h
                CLRB    r1
                JBS     off(00225h).2, idle_pid_hyst_calc
                LB      A, #032h
                MOVB    r1, #021h

idle_pid_hyst_calc:     MOVB    r2, 0e0h
                MB      C, off(00225h).2

idle_pid_hyst_check:     MB      PSWL.4, C
                CMPB    A, r2
                JGE     idle_pid_common
                MB      C, PSWL.4
                JLT     idle_pid_p0_check

idle_pid_gate3:     LB      A, off(00299h)
                JEQ     idle_pid_flag_store
                SJ      idle_pid_flag_clear

idle_pid_p0_check:     MB      C, P0.2
                JLT     idle_pid_flag_clear

idle_pid_flag_store:     MOVB    off(00299h), r1


idle_pid_flag_clear:     CLRB    r5
                SJ      idle_pid_diff_calc

idle_pid_common:     L       A, off(00266h)
                XCHG    A, er3
                MOVB    r5, off(00293h)
                CLRB    r4
                MOVB    r1, #040h
                JBS     off(00217h).6, idle_pid_track_call
                MOVB    r1, #040h

idle_pid_track_call:     CLRB    r0
                CAL     rpm_accel_track_helper
                ST      A, er3

idle_pid_diff_calc:     L       A, er3
                SUB     A, off(00266h)
                ST      A, er0
                JGE     idle_pid_diff_clamp
                VCAL    7

idle_pid_diff_clamp:     CMP     A, #00030h
                JBS     off(00217h).6, idle_pid_diff_zero
                CMP     A, #00030h

idle_pid_diff_zero:     CLR     A
                JLT     idle_pid_diff_store
                L       A, er0

idle_pid_diff_store:     ST      A, off(00268h)
                L       A, off(00276h)
                SUB     A, #00030h
                JGE     idle_pid_flag_recheck
                CLR     A

idle_pid_flag_recheck:     CMPB    off(00299h), #000h
                JEQ     idle_pid_store_final
                L       A, #00200h
                JBS     off(00217h).6, idle_pid_decrement
                L       A, #00200h

idle_pid_decrement:     DECB    off(00299h)

idle_pid_store_final:     MOV     off(00266h), er3
                ST      A, off(00276h)
                MOVB    off(00293h), r5
                MB      C, off(00225h).1
                MB      off(002edh).0, C
                JBR     off(00226h).4, idle_integrator_check2
                MOV     X1, #tbl_idle_pid_final1
                LB      A, 0d8h
                VCAL    0
                SLLB    A
                MOV     X2, A
                MOV     X1, #tbl_idle_pid_final2
                LB      A, off(00236h)
                CAL     table_interp_lookup
                L       A, er3
                SWAP
                CLRB    A
                MOV     er0, X2
                MUL
                MOV     DP, #00380h
                L       A, off(00280h)
                JEQ     idle_integrator_reset
                JBS     off(00281h).7, idle_integrator_reset
                L       A, [DP]
                SUB     A, #00010h
                JGE     idle_integrator_store
                CLR     A
                SJ      idle_integrator_store

idle_integrator_reset:     L       A, #00200h

idle_integrator_store:     ST      A, [DP]
                ADD     A, er1
                CMP     A, #08000h
                JLT     idle_integrator_final_store
                L       A, #07fffh
                SJ      idle_integrator_final_store

idle_integrator_check2:     L       A, off(00280h)
                JEQ     idle_integrator_final_store
                JBR     off(00281h).7, idle_integrator_fault
                ADD     A, #00010h
                JGE     idle_integrator_final_store
                CLR     A
                SJ      idle_integrator_final_store

idle_integrator_fault:     L       A, #00280h
                VCAL    7

idle_integrator_final_store:     ST      A, off(00280h)
                CLR     A
                MOV     DP, A
                MOVB    off(002d7h), #0ffh
                SJ      idle_output_finalize

idle_output_finalize:     ST      A, off(00274h)
                SRL     DP
                MB      off(00225h).3, C
                CLRB    A
                RC
                MOV     DP, #00420h
                MB      C, [DP].0
                JLT     idle_pid_result_store
                JBS     off(00217h).5, idle_pid_result_store
                JBR     off(0022bh).2, idle_pid_gate4
                JBR     off(00210h).3, idle_pid_gate5
                MOV     X1, #00680h
                LB      A, off(00297h)
                JEQ     idle_pid_x1_select
                DECB    off(00297h)
                MOV     X1, #00a00h

idle_pid_x1_select:     L       A, X1
                SJ      idle_pid_output_store

idle_pid_gate4:     JBS     off(00210h).3, idle_pid_zero_flag

idle_pid_gate5:     SC
                LB      A, #008h

idle_pid_result_store:     MB      off(0022bh).2, C
                STB     A, off(00297h)

idle_pid_zero_flag:     CLR     A

idle_pid_output_store:     ST      A, off(0027ah)
                MOV     X1, #tbl_idle_pid_out2
                LB      A, off(00236h)
                VCAL    0
                MOV     DP, A
                MOV     X1, #tbl_idle_pid_out1
                LB      A, 0d5h
                VCAL    2
                STB     A, r0
                CLR     A
                LB      A, #080h
                L       A, ACC
                SWAP
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_sub_result_store
                L       A, #0ffffh

idle_sub_result_store:     ST      A, er3
                LB      A, off(002f5h)
                MOV     A, off(0026ah)
                JNE     idle_sub_gate2
                MOVB    off(002f5h), #003h
                JBR     off(0021ah).2, idle_sub_common
                JBS     off(0021bh).1, idle_sub_diff_calc
                ADD     A, er3
                JLT     idle_sub_alt_path
                SJ      idle_sub_range_check1

idle_sub_diff_calc:     SUB     A, er3
                JLT     idle_sub_common

idle_sub_range_check1:     MOV     X2, #00400h
                CMP     A, #00a00h
                JGE     idle_sub_range_result
                MOV     X2, #00300h
                CMP     A, #00400h
                JGE     idle_sub_range_result
                MOV     X2, #00200h

idle_sub_range_result:     SUB     A, X2
                JGE     idle_sub_gate2

idle_sub_common:     CLR     A

idle_sub_gate2:     JBR     off(00218h).2, idle_sub_clamp
                MOV     X2, A
                MOV     X1, #tbl_idle_sub_gate1
                JBR     off(00211h).2, idle_sub_table_lookup
                MOV     X1, #tbl_idle_sub_gate2

idle_sub_table_lookup:     LB      A, off(00236h)
                VCAL    0
                L       A, X2
                CMP     A, er3
                JGE     idle_sub_clamp
                L       A, er3

idle_sub_clamp:     CMP     A, DP
                JLT     idle_sub_final_store

idle_sub_alt_path:     L       A, DP

idle_sub_final_store:     ST      A, off(0026ah)
                MB      C, off(0022bh).6
                MB      off(0022bh).7, C
                MOV     DP, #0037dh
                LB      A, [DP]
                MOV     X2, #tbl_idle_sub1
                JBR     off(0021bh).0, idle_gate6
                MOV     X2, #tbl_idle_sub2
                CMPB    A, #056h
                JGE     idle_gate6
                LB      A, #056h

idle_gate6:     CMPB    A, off(00236h)
                MB      off(0022bh).6, C
                JBS     off(0021ah).0, idle_gate6_result
                JLT     idle_gate6_result
                JBR     off(0022bh).7, idle_gate7
                JBS     off(0021bh).7, idle_gate6_result
                MOV     X1, #tbl_idle_gate6
                LB      A, 0d9h
                VCAL    0
                ; warning: had to flip DD
                CMP     A, 0c8h
                JLT     idle_table_lookup2

idle_gate6_result:     MOVB    off(002f4h), off(00296h)
                SJ      idle_flag_zero

idle_gate7:     L       A, off(0026ch)
                SUB     A, #00080h
                JLT     idle_flag_zero
                SJ      idle_flag_check3

idle_table_lookup2:     MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r0
                CLRB    r1
                L       A, 0c8h
                MUL
                MOV     er0, #02000h
                CMP     er1, #00000h
                JNE     idle_clamp_min
                CMP     A, er0
                JLT     idle_flag_check3

idle_clamp_min:     L       A, er0


idle_flag_check3:     CMPB    off(002f4h), #000h
                JNE     idle_flag_store


idle_flag_zero:     CLR     A

idle_flag_store:     ST      A, off(0026ch)
                JBR     off(00219h).7, idle_mode_dispatch
                MOV     DP, #003afh
                MOVB    r0, [DP]
                L       A, #01480h
                CMPB    r0, #033h
                JEQ     idle_gear_select_done
                L       A, #02300h
                CMPB    r0, #034h
                JEQ     idle_gear_select_done
                L       A, #02d00h
                CMPB    r0, #035h
                JEQ     idle_gear_select_done
                L       A, #03fffh

idle_gear_select_done:     L       A, ACC
                J       idle_gear_target_check

idle_mode_dispatch:     JBR     off(0021ah).0, idle_mode_dispatch2
                SB      off(00228h).4
                MOV     X1, #tbl_idle_mode
                LB      A, 0d9h
                VCAL    0
                STB     A, off(0026eh)
                JBS     off(00217h).5, idle_vcal5_store
                MOV     DP, #00386h
                SJ      idle_vcal5_call

idle_mode_dispatch2:     JBR     off(00218h).2, idle_mode_dispatch3
                JBR     off(0022ah).3, idle_gear_calc_start
                L       A, #011ebh
                J       idle_gear_target_final

idle_mode_dispatch3:     JBR     off(0021ah).1, idle_mode_reset
                L       A, off(0026ch)
                JNE     idle_mode_reset
                JBR     off(0021ch).4, idle_gear_calc_start
                CMPB    0d9h, #02eh
                JGE     idle_gear_calc_start
                CMPB    0cch, #00fh
                JLT     idle_gear_calc_start
                JBR     off(0022ah).2, idle_gear_calc_start
                MOV     X1, #tbl_ve_map_scalar_alt
                JBR     off(00226h).4, vemapscalar_gate
                MOV     X1, #tbl_ve_map_scalar

vemapscalar_gate:     LB      A, 0c2h
                VCAL    0
                STB     A, off(00270h)
                JEQ     idle_gear_calc_start
                SB      off(00228h).6
                MOV     DP, #0030ch

idle_vcal5_call:     L       A, [DP]
                VCAL    5

idle_vcal5_store:     STB     A, off(00260h)
                J       idle_vcal5_report


idle_mode_reset:     CLR     off(0026ah)
                SC
                JBS     off(0022bh).4, idle_direction_toggle
                JBS     off(00212h).5, idle_direction_toggle
                MB      C, 0b0h.1


idle_direction_toggle:     XORB    PSWH, #080h
                MB      off(00228h).5, C

idle_gear_calc_start:     CLR     A
                ST      A, er2
                MOV     DP, #0030ch
                MOV     er0, off(00262h)
                MOVB    ACCH, #026h
                MOVB    r5, #0ffh
                CMPB    off(002c7h), #000h
                JNE     idle_gear_mul_apply
                MOVB    ACCH, #026h
                MOVB    r5, #0a6h
                JBR     off(00228h).5, idle_gear_mul_apply
                JBR     off(0021ah).2, idle_gear_mul_apply
                CMPB    0d9h, #04ah
                JGE     idle_gear_mul_apply
                L       A, [DP]
                ADD     A, off(00266h)
                JGE     idle_gear_result_store
                L       A, #0ffffh
                SJ      idle_gear_result_store

idle_gear_mul_apply:     MUL
                SLL     A
                L       A, er1
                ROL     A
                JLT     idle_gear_clamp
                ADD     A, off(00266h)
                JLT     idle_gear_clamp
                ADD     A, [DP]
                JGE     idle_gear_clamp_max

idle_gear_clamp:     L       A, #0ffffh

idle_gear_clamp_max:     SUB     A, #00500h
                JGE     idle_gear_result_store
                CLR     A

idle_gear_result_store:     ST      A, off(0028eh)
                L       A, er2
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JLT     idle_gear2_clamp
                ADD     A, off(00266h)
                JLT     idle_gear2_clamp
                ADD     A, #01000h
                JGE     idle_gear2_store

idle_gear2_clamp:     L       A, #0ffffh

idle_gear2_store:     ST      A, off(0028ch)
                MOVB    r0, #020h
                MOV     DP, #tbl_idle_gear2
                JBR     off(00228h).5, idle_timer_gate1
                JBS     off(0021ah).3, idle_timer_gate_common
                MOVB    off(00298h), #028h
                SJ      idle_timer_gate_common

idle_timer_gate1:     JBR     off(00218h).2, idle_timer_gate_common
                CLRB    off(002d9h)
                MOVB    r0, #028h
                JBS     off(0021ah).4, idle_table_select2
                SJ      idle_timer_store

idle_timer_gate_common:     JBS     off(0021ah).2, idle_table_select2
                LB      A, off(002d9h)
                JEQ     idle_table_select1
                MOV     DP, #tbl_idle_timer
                SJ      idle_flag_gate

idle_table_select1:     LB      A, off(002d6h)
                JEQ     idle_table_select_default
                JBR     off(0021ah).4, idle_table_select_default
                MOV     DP, #tbl_idle_select1
                SJ      idle_flag_gate

idle_table_select_default:     MOV     DP, #tbl_idle_select_default
                MOV     X1, #tbl_idle_default1
                JBR     off(0021ah).4, idle_table_lookup3
                MOV     X1, #tbl_idle_default2

idle_table_lookup3:     L       A, off(0025ah)
                CAL     table_interp_lookup_4byte
                CMP     A, 0cah
                JLT     idle_table_lookup4
                MOV     DP, #tbl_idle_lookup3

idle_table_lookup4:     MOV     X1, #tbl_idle_lookup4
                L       A, off(0025ah)
                CAL     table_interp_lookup_4byte
                JBR     off(0021ah).4, idle_flag_gate
                CMP     A, 0cah
                JGE     idle_flag_gate
                LB      A, off(00298h)
                JEQ     idle_flag_gate
                SUBB    A, #001h
                STB     A, r0

idle_table_select2:     MOV     DP, #tbl_idle_select1

idle_timer_store:     MOVB    off(00298h), r0

idle_flag_gate:     LB      A, off(002dah)
                JNE     idle_copy_prev
                RB      off(00225h).5

idle_copy_prev:     MOV     off(00288h), off(00286h)
                MOVB    off(0028bh), off(0028ah)
                SB      off(0022bh).1
                JBS     off(00228h).5, idle_mode_gate3
                JBS     off(0021ah).3, idle_mode_gate5
                L       A, off(00262h)
                JBS     off(002eeh).1, idle_target_store3
                SJ       idle_pi_mul1

idle_mode_gate3:     JBR     off(0021ah).3, idle_mode_gate5
                JBS     off(00229h).5, idle_mode_gate5
                JBR     off(0022bh).3, idle_pi_mul1
                CMPB    0d9h, #0d0h
                JLT     idle_mode_gate4
                CMPB    0f3h, #0fah
                JLT     idle_pi_mul1

idle_mode_gate4:     JBR     off(00229h).6, idle_pi_mul1

idle_mode_gate5:     L       A, off(00262h)
                JBR     off(002eeh).1, idle_mode_gate6
                MOV     er3, off(0026eh)
                MOV     DP, #00386h
                L       A, [DP]
                SJ      idle_vcal5_call2

idle_mode_gate6:     JBR     off(00228h).5, idle_target_store3
                JBS     off(0021ah).3, idle_target_store3
                JBS     off(002eeh).1, idle_target_store3
                JBS     off(00228h).3, idle_target_store3
                CMPB    off(002dah), #000h
                JEQ     idle_table_select3
                SB      off(00225h).5
                JNE     idle_target_store3

idle_table_select3:     MOV     X2, A
                LB      A, #014h
                MOV     X1, #tbl_idle_select3a
                JBR     off(0021bh).0, idle_table_apply3
                LB      A, #014h
                MOV     X1, #tbl_idle_select3b

idle_table_apply3:     STB     A, off(002dah)
                LB      A, 0d8h
                VCAL    0
                L       A, X2
                VCAL    5

idle_target_store3:     ST      A, er3
                MOV     DP, #0030ch
                L       A, [DP]

idle_vcal5_call2:     VCAL    5
                MOV     er3, off(00266h)
                VCAL    5
                ST      A, off(00286h)
                ST      A, off(00288h)
                CLRB    A
                STB     A, off(0028ah)
                STB     A, off(0028bh)
                CLR     A
                ST      A, er1
                ST      A, er2
                MOV     X1, A
                MOV     X2, A
                SJ      idle_vcal4_call

idle_pi_mul1:     MOV     er0, 0c8h
                LC      A, [DP]
                MUL
                L       A, er1
                JBR     off(0021bh).7, idle_pi_mul2
                VCAL    7

idle_pi_mul2:     MOV     X1, A
                MOV     er0, 0cah
                INC     DP
                INC     DP
                LC      A, [DP]
                MUL
                L       A, er1
                JBR     off(0021ah).4, idle_pi_mul3
                VCAL    7

idle_pi_mul3:     MOV     X2, A
                INC     DP
                INC     DP
                LC      A, [DP]
                MUL
                ST      A, er2
                L       A, off(00268h)

idle_vcal4_call:     MOV     er3, off(00286h)
                VCAL    4
                LB      A, off(0028ah)
                JBS     off(0021ah).4, idle_integrator_sub
                ADDB    A, r5
                STB     A, r5
                L       A, er3
                ADC     A, er1
                JGE     idle_integrator_result
                L       A, #0ffffh
                SJ      idle_integrator_result

idle_integrator_sub:     SUBB    A, r5
                STB     A, r5
                L       A, er3
                SBC     A, er1
                JGE     idle_integrator_result
                CLR     A

idle_integrator_result:     CAL     idle_pi_clamp_helper
                ST      A, er1
                ST      A, er3
                JLT     idle_pi_store_p
                L       A, X1
                VCAL    4
                L       A, X2
                VCAL    4
                CAL     idle_pi_clamp_helper
                JLT     idle_pi_result_common
                MOVB    off(0028ah), r5

idle_pi_store_p:     MOV     off(00286h), er1

idle_pi_result_common:     ST      A, er3
                L       A, off(0026ch)
                JBS     off(00228h).5, idle_vcal5_call3
                L       A, off(0026ah)

idle_vcal5_call3:     VCAL    5
                ST      A, off(00260h)
                JBS     off(00225h).7, idle_vcal5_report
                JBR     off(00228h).5, idle_vcal5_report
                JBS     off(0021ah).2, idle_vcal5_report
                MB      C, off(0022ah).1
                JBR     off(00217h).6, idle_stall_check1
                MB      C, off(0022ah).6

idle_stall_check1:     JLT     idle_vcal5_report
                L       A, off(0027ah)
                JNE     idle_vcal5_report
                L       A, off(00280h)
                JNE     idle_vcal5_report
                CMPB    0beh, #07bh
                JLT     idle_vcal5_report
                CMP     0c8h, #00018h
                JGE     idle_vcal5_report
                L       A, #00040h
                JBR     off(0021ah).4, idle_stall_check2
                L       A, #00040h

idle_stall_check2:     CMP     A, 0cah
                JLT     idle_vcal5_report
                CMPB    0d9h, #067h
                JGE     idle_vcal5_report
                LB      A, off(002dah)
                JNE     idle_vcal5_report
                LB      A, 0bch
                MOV     X1, #tbl_idle_stall
                VCAL    1
                LB      A, #0c2h
                SUBB    A, r6
                JGE     idle_stall_er0_select1
                CLRB    A

idle_stall_er0_select1:     MOV     er0, #00040h
                CMPB    A, 0beh
                JLT     idle_stall_er0_select2
                MOV     er0, #00010h

idle_stall_er0_select2:     CMPB    0d9h, #028h
                JLT     idle_stall_diff_calc
                MOV     er0, #00001h

idle_stall_diff_calc:     MOV     X1, #0030ch
                L       A, off(00286h)
                SUB     A, off(00262h)
                JLT     idle_stall_diff_check
                SUB     A, off(00266h)
                JGE     idle_stall_trigger

idle_stall_diff_check:     CLR     A

idle_stall_trigger:     CAL     injtimer_bank_calc1
                CAL     idle_stall_helper

idle_vcal5_report:     L       A, off(00274h)
                MOV     er3, off(00276h)
                VCAL    5
                L       A, off(00278h)
                VCAL    5
                L       A, off(0027ah)
                VCAL    5
                L       A, off(0027ch)
                VCAL    5
                L       A, off(00280h)
                CMP     A, #08000h
                JGE     idle_target_clamp1
                ADD     A, er3
                JGE     idle_target_clamp2
                SJ      idle_target_clamp_max

idle_target_clamp1:     ADD     A, er3
                JGE     idle_target_final_store

idle_target_clamp2:     CMP     A, #08000h
                JLT     idle_target_final_store

idle_target_clamp_max:     L       A, #07fffh

idle_target_final_store:     ST      A, off(00272h)
                CLR     X1
                JBS     off(00217h).5, idle_output_gate2
                JBR     off(00225h).7, idle_output_gate1
                MOV     DP, #0030ch
                L       A, 00384h[X1]
                ST      A, [DP]

idle_output_gate1:     MOV     er3, #01000h
                L       A, 00384h[X1]
                VCAL    5
                MB      C, 0b0h.1
                JLT     idle_output_common
                JBS     off(00212h).5, idle_output_common
                MOV     er3, off(00262h)
                L       A, 00384h[X1]
                VCAL    5
                CLR     A
                JBS     off(00212h).2, idle_output_alt_value
                JBR     off(00212h).4, idle_output_vcal5

idle_output_alt_value:     L       A, #01500h

idle_output_vcal5:     VCAL    5
                JBS     off(0022bh).4, idle_output_common

idle_output_gate2:     L       A, off(00260h)
                JBS     off(00228h).6, idle_pi_final_calc
                CLR     off(00270h)
                JBS     off(0022bh).1, idle_output_gate3

idle_output_common:     MOV     er3, off(00266h)
                VCAL    5

idle_output_gate3:     MOV     er3, off(00272h)
                XCHG    A, er3
                VCAL    4

idle_pi_final_calc:     MOV     X2, A
                CLR     X1
                L       A, 0037eh[X1]
                SUB     A, 0030ch[X1]
                SLL     A
                ST      A, er0
                CLR     A
                JLT     idle_pi_scale_store
                LB      A, off(00292h)
                ANDB    A, #07fh
                STB     A, ACCH
                CLRB    A
                MUL
                L       A, er1

idle_pi_scale_store:     ST      A, off(00282h)
                L       A, X2
                CLRB    r0
                MOVB    r1, off(00292h)
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_pi_result_clamp
                L       A, #0ffffh

idle_pi_result_clamp:     ST      A, er3
                L       A, off(00282h)
                VCAL    5
                LCB     A, tbl_idle_pi_clamp
                JEQ     idle_pi_final_common
                L       A, off(00284h)
                VCAL    4

idle_pi_final_common:     L       A, er3

idle_gear_target_check:     JNE     idle_gear_target_clamp
                JBS     off(0021ah).4, idle_gear_target_reset
                SJ      idle_gear_target_store

idle_gear_target_clamp:     MOV     er3, #03fffh
                CMP     A, er3
                JLT     idle_gear_target_store
                L       A, er3
                JBS     off(0021ah).4, idle_gear_target_store

idle_gear_target_reset:     MOV     off(00286h), off(00288h)
                MOVB    off(0028ah), off(0028bh)



idle_gear_target_store:     ST      A, off(0025eh)
                MOV     X1, #tbl_idle_gear_target
                CAL     table_interp_lookup_4byte

idle_gear_target_final:     ST      A, off(0025ch)
                RB      off(0022bh).1
                MB      C, off(00228h).5
                MB      off(0021ah).3, C
                LB      A, off(00228h)
                ANDB    A, #0f0h
                SWAPB
                STB     A, off(00228h)
                RB      0b6h.4
                RT

vcal3_task_c:     JBR     off(00217h).5, vcal3_task_c_timers
; --- Another vcal_3 round-robin task: decrements two more software-timer arrays via
; decrement_timer_array, ticks a millisecond-like counter (0xF3), then dispatches into a
; per-cylinder counter increment/reset state machine (0x39D/0x39E arrays, indexed by X1) --
; possibly knock-window or per-cylinder misfire-adjacent counting, not confirmed.
                CAL     crank_cycle_helper1

vcal3_task_c_timers:     MOV     DP, #00015h
                MOV     X1, #001b3h
                CAL     decrement_timer_array
                MOV     DP, #00021h
                MOV     X1, #002bfh
                CAL     decrement_timer_array
                LB      A, 0f3h
                ADDB    A, #001h
                JEQ     vcal3_task_c_msec_tick
                STB     A, 0f3h

vcal3_task_c_msec_tick:     CAL     empty_stub_return
                CLR     X1
                LB      A, 0039dh[X1]
                JEQ     percyl_counter_gate
                CMPB    off(002c5h), #000h
                JNE     percyl_alt_check
                MOVB    r2, #010h
                CMPB    A, r2
                JGE     percyl_counter_check2
                MOVB    r2, #001h

percyl_counter_check2:     SUBB    A, r2
                MOV     er1, #01107h
                JNE     percyl_store_result

percyl_counter_gate:     SC
                JBS     off(00214h).7, tach_output_drive
                CLR     A

percyl_counter_loop:     LB      A, 0039eh[X1]
                STB     A, r0
                CMPB    A, #020h
                JLT     percyl_counter_dp_select
                CLRB    0039eh[X1]
                SJ      tach_output_drive

percyl_counter_dp_select:     MOV     DP, #00321h
                CMPB    A, #018h
                JGE     percyl_counter_increment
                DEC     DP
                JBS     off(00208h).4, percyl_counter_increment
                DEC     DP
                JBS     off(00208h).3, percyl_counter_increment
                DEC     DP

percyl_counter_increment:     INCB    0039eh[X1]
                TRB     [DP] ; ;mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C213
                JNE     percyl_wrap_check1
                LB      A, 0039eh[X1]
                ANDB    A, #007h
                RC
                JNE     percyl_counter_loop
                SJ      tach_output_drive

percyl_wrap_check1:     ADDB    A, #001h
                CAL     code_remap                     ; 25->35, 26->36, 27->41, 29->43
percyl_bcd_convert:     MOVB    r0, #00ah
                DIVB
                SWAPB
                ORB     A, r1
                MOV     er1, #02b20h

percyl_store_result:     STB     A, 0039dh[X1]
                CMPB    A, #010h
                JLT     percyl_result_final
                MOVB    r2, r3

percyl_result_final:     MOVB    off(002c5h), r2

percyl_alt_check:     CMPB    A, #010h
                L       A, #00206h
                JLT     percyl_alt_store
                L       A, #00311h

percyl_alt_store:     ST      A, er1
                LB      A, off(002c5h)
                CMPB    A, r2
                JGE     tach_output_drive
                CMPB    r3, A

tach_output_drive:     MB      P1.5, C
                MOV     DP, #0040eh
                MB      C, [DP].4
                JLT     tach_output_alt_check
                MB      C, P1.5
                JBR     off(00221h).6, tach_output_return

tach_output_alt_check:     MOV     DP, #0031eh
                L       A, [DP]
                JNE     tach_output_drive2
                INC     DP
                INC     DP
                L       A, [DP]
                JNE     tach_output_drive2
                SC

tach_output_drive2:     MB      P1.4, C

tach_output_return:     RT

vcal3_task_b_body:     MOV     DP, #00002h
; --- vcal_3 round-robin task: decrements two more software-timer arrays, ticks a msec
; counter (0xF2), then runs learn_table1 (a rolling min/max-tracking loop over a 4-entry
; table at 0x1D7-0x1DB against tbl_diag_snapshot_data2) and learn_table2 -- looks like an adaptive
; learning/trim-tracking mechanism (possibly cylinder-trim or knock-threshold learning), not
; confirmed against a calibration field. Also reuses sysFlags_b7.1 and trapRetryCounter here
; in a different runtime context than their boot-sequence roles.
                MOV     X1, #001b0h
                CAL     decrement_timer_array
                MOV     DP, #00008h
                MOV     X1, #002b6h
                CAL     decrement_timer_array
                LB      A, 0f2h
                ADDB    A, #001h
                JEQ     learn_table1_check
                STB     A, 0f2h

learn_table1_check:     LB      A, off(002bch)
                JNE     learn_table2_check
                MOVB    off(002bch), #002h
                MOV     X1, #tbl_diag_snapshot_data2
                MOV     DP, #001d7h
                MOVB    r6, #027h

learn_table1_loop:     LB      A, [DP]
                ADDB    A, #001h
                JLT     learn_table1_reset_entry
                CMPCB   A, [X1]
                JLT     learn_table1_store

learn_table1_reset_entry:     LCB     A, [X1]

learn_table1_store:     STB     A, [DP]
                LB      A, r6
                SUBB    A, 0f4h
                JNE     learn_table1_advance
                STB     A, 0f4h

learn_table1_advance:     INC     X1
                INC     DP
                INCB    r6
                CMP     DP, #001dbh
                JLE     learn_table1_loop

learn_table2_check:     LB      A, off(002bdh)
                JNE     vcal3_task_a_return
                MOVB    off(002bdh), #002h
                LB      A, #001h
                MB      C, sysFlags_b7.1
                JLT     learn_counter_store
                LB      A, 0f7h
                ADDB    A, #001h
                CMPB    A, #020h
                JLT     learn_counter_store
                LB      A, #020h

learn_counter_store:     STB     A, 0f7h
                LB      A, trapRetryCounter
                ADDB    A, #001h
                CMPB    A, #020h
                JLT     learn_retry_store
                RB      sysFlags_b7.1
                LB      A, #020h

learn_retry_store:     STB     A, trapRetryCounter

vcal3_task_a_return:     RT

regbank_selftest2_start:     L       A, #02bafh
; NOTE: the only "from" reference to this label is 0x5EB7 (lowpower_cond_exit, the tail end of
; lowpower_abort_cond_scan, restored above). Previously this was assumed to be a disassembler
; artifact from scanning dead filler bytes, since that region used to be blanked 0xFFh. Now that
; lowpower_abort_cond_scan has been restored from bmtune1.15.asm, this IS a real, live call site:
; lowpower_abort_cond_scan always falls into this routine (whether or not any of its calibratable
; conditions triggered), so this register-bank self-test (same pattern as
; selftest_reg_stuckbit_check, but validating the STOP/HALT-entry TM1/IE/X1 reload values here) is
; confirmed reachable, from the low-power preparation path (prep_lowpower_seq -> lowpower_trap_call
; -> lowpower_abort_cond_scan -> here).
                MOV     X1, #002a0h
                JBR     off(00217h).2, regbank_selftest2_ie_check
                L       A, #0a9a7h
                MOV     X1, #000a0h

regbank_selftest2_ie_check:     CMP     A, 0f8h
                JNE     selftest_fail_04f
                CMP     A, IE
                JNE     selftest_fail_04f
                L       A, X1
                CMP     A, 0fah
                JEQ     regbank_selftest2_range_check

selftest_fail_04f:     MOVB    trapReasonCode, #04fh
                J       fault_retry_check

regbank_selftest2_range_check:     MOV     DP, #00398h
                L       A, [DP]
                CMP     A, #003fah
                JGT     regbank_selftest2_default
                MOV     X1, A
                MOV     DP, 00084h[X1]
                L       A, #05555h
                CAL     selftest_regbank_verify
                SLL     A
                CAL     selftest_regbank_verify
                L       A, X1
                SUB     A, #00002h
                JGE     irqmode_dispatch
                L       A, #05555h
                MOV     X1, A
                CMP     A, X1
                JNE     selftest_fail_042_alt
                MOV     X2, A
                CMP     A, X2
                JNE     selftest_fail_042_alt
                SLL     A
                MOV     X1, A
                CMP     A, X1
                JEQ     regbank_selftest2_check3

selftest_fail_042_alt:     MOVB    trapReasonCode, #042h
                BRK

regbank_selftest2_check3:     MOV     X2, A
                CMP     A, X2
                JNE     selftest_fail_042_alt

regbank_selftest2_default:     L       A, #003fah

irqmode_dispatch:     MOV     DP, #00398h
; --- Interrupt-priority/mode switch: calls VCAL 3 (the scheduler), then based on off(00212h).3
; and off(00217h).2 flags, reprograms IE and its shadow bytes (0xFA/0xF8) to one of two
; distinct bitmasks (0x2BAF/0xA9A7 -- likely "engine running" vs "cranking/idle" interrupt
; priority sets), plus TCON3 bits. Distinct from the register self-test above despite similar
; surrounding code shape.
                ST      A, [DP]
                VCAL    3
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                JBS     off(00212h).3, irqmode_select_b
                JBS     off(00217h).2, irqmode_check1
                RB      IRQH.7
                JEQ     irqmode_check1
                SB      0b6h.7
dtc04_ckp_latch_2: SB      0b4h.0

irqmode_check1:     ORB     PSWH, #001h
                CMPB    (001d1h-00180h)[USP], #029h
                ANDB    PSWH, #0feh
                JLT     irqmode_select_b
                JBR     off(00217h).2, irqmode_done
                L       A, #02bafh
                ST      A, IE
                ST      A, 0f8h
                MOV     0fah, #002a0h
                RB      off(00217h).2
                SJ      irqmode_done

irqmode_select_b:     JBS     off(00217h).2, irqmode_done
                L       A, #0a9a7h
                ST      A, IE
                ST      A, 0f8h
                MOV     0fah, #000a0h
                SB      off(00217h).2
                RB      (00125h-00180h)[USP].7
                RB      off(0021dh).7
                SB      TCON3.3
                SB      TCON3.2

irqmode_done:     ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE

stack_sanity_check:     CMP     SSP, #0047eh
; --- Post-init peripheral verification: re-reads SSP, LRB, every port direction/special-
; function register, all four timer control regs, PWM control regs, A/D select/scan, and the
; diagnostic-serial baud/control regs, comparing each against the exact values int_break's
; init sequence (0x235F periph_init_start onward) programmed them to. Any mismatch -> stamps
; trapReasonCode=0x50 (selftest_fail_050) and BRKs, forcing a full re-init retry. This is a
; "did my own initialization actually stick" check, not a fresh self-test of new hardware.
                JNE     selftest_fail_050
                MOV     DP, #00400h
                L       A, [DP]
                JNE     selftest_fail_050
                L       A, PSW
                AND     A, #01107h
                CMP     A, #01100h
                JNE     selftest_fail_050
                CMP     LRB, #00041h
                JNE     selftest_fail_050
                CMPB    P0IO, #0ffh
                JNE     selftest_fail_050
                CMPB    P1IO, #0ffh
                JNE     selftest_fail_050
                CMPB    P2IO, #0ffh
                JNE     selftest_fail_050
                CMPB    P2SF, #007h
                JNE     selftest_fail_050
                CMPB    P3IO, #0b1h
                JNE     selftest_fail_050
                CMPB    P3SF, #0ffh
                JNE     selftest_fail_050
                CMPB    P4IO, #00dh
                JNE     selftest_fail_050
                CMPB    P4SF, #0f4h
                JNE     selftest_fail_050
                LB      A, TCON0
                MOVB    r0, #0f3h
                ANDB    A, r0
                CMPB    A, #093h
                JNE     selftest_fail_050
                LB      A, TCON1
                ANDB    A, r0
                CMPB    A, #053h
                JNE     selftest_fail_050
                LB      A, TCON2
                ANDB    A, r0
                CMPB    A, #092h
                JNE     selftest_fail_050
                LB      A, TCON3
                ANDB    A, r0
                CMPB    A, #093h
                JEQ     periph_init_verify_pwm_adc

selftest_fail_050:     MOVB    trapReasonCode, #050h
                BRK

periph_init_verify_pwm_adc:     LB      A, PWCON0
                ANDB    A, #07bh
                CMPB    A, #039h
                LB      A, PWCON1
                ANDB    A, #07bh
                CMPB    A, #07ah
                LB      A, ADSEL
                ANDB    A, #05fh
                JNE     selftest_fail_050
                LB      A, ADSCAN
                ANDB    A, #05fh
                CMPB    A, #010h
                JNE     selftest_fail_050
                MOV     DP, #00356h
                MB      C, [DP].1
                JGE     periph_init_verify_done
                LB      A, STTMC
                ANDB    A, #0f3h
                CMPB    A, #012h
                JNE     selftest_fail_050
                LB      A, STCON
                ANDB    A, #07fh
                CMPB    A, #01ch
                JNE     selftest_fail_050
                CMPB    SRCON, #08ch
                JNE     selftest_fail_050
                CMPB    STTMR, #0f8h
                JNE     selftest_fail_050

periph_init_verify_done:     L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                MOV     er0, TM0
                MOV     er1, TM1
                MOV     er2, TM2
                MOV     er3, TM3
                ORB     PSWH, #001h
                ANDB    PSWH, #0feh
                MOV     X1, TM0
                MOV     X2, TM1
                MOV     DP, TM2
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                L       A, X1
; --- Oscillator/timer cross-check: snapshots TM0/TM1/TM2 into X1/X2/DP, re-enables
; interrupts briefly (IE/PSWH toggling), re-snapshots into er0/er1/er2, then verifies the
; deltas fall within expected ranges (0x22, 0x80, 0x22, a ratio check against er1>>2) --
; confirms the timers are actually counting at the rate the code expects (i.e. the clock
; source/oscillator is running correctly) before trusting any timing-dependent logic
; (ignition/injection scheduling) downstream. Out-of-range -> selftest_fail_04b.
                SUB     A, er0
                ST      A, er0
                JEQ     selftest_fail_04b
                CMP     A, #00022h
                JGE     selftest_fail_04b
                L       A, X2
                SUB     A, er1
                ST      A, er1
                JEQ     selftest_fail_04b
                CMP     A, #00080h
                JGE     selftest_fail_04b
                L       A, DP
                SUB     A, er2
                MOV     X2, A
                JEQ     selftest_fail_04b
                CMP     A, #00022h
                JGE     selftest_fail_04b
                L       A, er3
                SUB     A, er2
                MB      C, ACCH.7
                JGE     clock_selftest_check2
                VCAL    7

clock_selftest_check2:     CMP     A, #00002h
                JGE     selftest_fail_04b
                L       A, er1
                SRL     A
                SRL     A
                SUB     A, X2
                JGE     clock_selftest_check3
                VCAL    7

clock_selftest_check3:     CMP     A, #00002h
                JGE     selftest_fail_04b
                L       A, X2
                SUB     A, er0
                JGE     clock_selftest_check4
                VCAL    7

clock_selftest_check4:     CMP     A, #00002h
                JLT     clock_selftest_passed

selftest_fail_04b:     MOVB    trapReasonCode, #04bh
                BRK

clock_selftest_passed:     VCAL    3
                CAL     boot_completion_helper
                MOVB    r0, #001h
                JBR     off(00217h).2, warmcold_ie_setup
                MOVB    r0, #006h

warmcold_ie_setup:     L       A, 0fah
; ============================================================================================
; COLD vs WARM RESTART FORK (0x3480-0x353C+): this is the transition point flagged much
; earlier in this file as needing dedicated tracing -- now traced. warmcold_tm2_check compares
; the current TM2 reading against a saved value (0xAE/0xEE) to detect whether the engine
; appears to still be running/turning (a brief ECU reset while cranking) vs a genuine cold
; power-up:
;  - coldstart_full_reset (warm check failed -> true cold start): zeroes currentRPMByte, the
;    ignition/injector hardware timer-prep registers (0x360-0x372, 0x3A6, 0x357/0x358/0x35D/
;    0x35E), VTEC/mode flags (0x124/0x126/0x127/0x128/0x21C/0x21E/0x21F/0x221/0x232), and
;    drives P4.0/P1 low -- a full reset of all per-cycle working state built up over this
;    session's traced routines.
;  - warmrestart_path/warmrestart_tm3_resync (warm check passed -> engine still turning):
;    skips the reset entirely, just resyncs TM3 -- preserves ignition/fuel/VTEC state across
;    the brief reset instead of losing sync with a spinning engine.
; ============================================================================================
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      off(00231h).5
                JBR     off(00217h).4, warmcold_tm2_check
                J       warmrestart_tm3_resync

warmcold_tm2_check:     JNE     coldstart_full_reset
                LB      A, r0
                CMPB    A, 0aeh
                JLT     coldstart_full_reset
                JNE     warmrestart_path
                L       A, TM2
                CMP     A, 0eeh
                JGE     coldstart_full_reset

warmrestart_path:     J       warmcold_reconverge

coldstart_full_reset:     SB      off(00217h).4
                CLRB    A
                MOVB    0a2h, #002h
                STB     A, 0a3h
                MOVB    (00134h-00180h)[USP], #005h
                STB     A, (00135h-00180h)[USP]
                MOVB    (0013dh-00180h)[USP], #004h
                CLR     A
                MOV     X1, A
                ST      A, 00360h[X1]
                ST      A, 00362h[X1]
                ST      A, 00364h[X1]
                ST      A, 00366h[X1]
                ST      A, 00368h[X1]
                ST      A, 0036ah[X1]
                ST      A, off(00266h)
                ST      A, 003a6h[X1]
                L       A, #0ffffh
                ST      A, 0036eh[X1]
                ST      A, 00370h[X1]
                ST      A, 00372h[X1]
                ST      A, 0c4h
                CLRB    A
                STB     A, off(00236h)
                STB     A, (currentRPMByte-00180h)[USP]
                STB     A, 0c3h
                STB     A, (00166h-00180h)[USP]
                SB      P4.0
                ORB     TCON3, #00ch
                SB      (00126h-00180h)[USP].0
                MOVB    0a0h, #004h
                SB      (0012ah-00180h)[USP].5
                L       A, #0ffffh
                ST      A, 0a4h
                ST      A, 0e8h
                L       A, #0ff04h
                ST      A, 00358h[X1]
                ST      A, 0035eh[X1]
                LB      A, #0ffh
                STB     A, 00357h[X1]
                STB     A, 0035dh[X1]
                ORB     0b8h, #003h
                RB      off(00221h).7
                ANDB    P1, #0fch
                ANDB    (00127h-00180h)[USP], #0f9h
                ANDB    off(0021fh), #0f9h
                RB      off(00232h).7
                RB      (00126h-00180h)[USP].4
                RB      off(0021eh).4
                CLR     A
                ST      A, (00128h-00180h)[USP]
                ST      A, (00124h-00180h)[USP]
                ST      A, off(0021ch)
                ST      A, (001aah-00180h)[USP]
                ST      A, (001a8h-00180h)[USP]
                ST      A, 0ech
                ST      A, 0eah

warmrestart_tm3_resync:     L       A, TM3
                SUB     A, #00001h
                ST      A, TMR3

warmcold_reconverge:     ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                SC
                JBS     off(00217h).4, warmcold_deg_flag
                JBS     off(00219h).6, warmcold_deg_select
                JBR     off(00217h).5, warmcold_state_stamp

warmcold_deg_select:     LB      A, #012h
                JBS     off(00217h).5, warmcold_deg_check
                LB      A, #01dh

warmcold_deg_check:     CMPB    A, 0c5h

warmcold_deg_flag:     MB      off(00217h).5, C
                JGE     warmcold_state_stamp
                JBR     off(00219h).6, warmcold_msec_reset
                SB      off(00230h).4

warmcold_msec_reset:     CLRB    A
                STB     A, 0f3h
                STB     A, 0f2h
                JBR     off(00217h).4, tps_learn_vcal3_call

warmcold_state_stamp:     MOVB    off(002c4h), #031h

tps_learn_vcal3_call:     VCAL    3
                CLR     X1
                MOVB    r0, #07bh
                JBS     off(00217h).4, tps_learn_gate_result
                JBS     off(0021ah).1, tps_learn_gate_result
                JBS     off(0021ah).2, tps_learn_gate_result
                LB      A, 0d4h
                CMPB    A, r0
                JGE     tps_learn_gate_result
                STB     A, r1
                MOVB    r3, 0037ah[X1]
                SUBB    A, r3
                JLT     tps_learn_table_store
                CMPB    A, #004h
                JGE     tps_learn_table_store
                LB      A, off(002d2h)
                JNE     tps_learn_alt_path
                LB      A, r3
                STB     A, 00311h[X1]
                SJ      tps_learn_gate_result

tps_learn_table_store:     LB      A, r1
                STB     A, 0037ah[X1]

tps_learn_gate_result:     LB      A, 00311h[X1]
                CMPB    A, r0
                LB      A, #096h
                JLT     tps_learn_result_store
                LB      A, #032h

tps_learn_result_store:     STB     A, off(002d2h)

tps_learn_alt_path:     CLR     X1
                L       A, 0030ch[X1]
                CMP     A, #00010h
                JLT     fueltbl_default_load
                CMP     A, #01000h
                JLE     fueltbl_sanitize_loop

fueltbl_default_load:     L       A, 00384h[X1]
; --- Fuel table shadow-copy sanitization (0x35AE-0x35E8): walks the FUEL1_Hi_Extended
; region in RAM (0x300-0x30C), and for any entry outside a plausible range (0x9862 max,
; FUEL1_Hi_Extended min) resets it to a default 0x8000 -- guards against corrupted/garbage
; fuel-table data. Followed by a knock-related check (knock_helper1 onward, comparing against
; tbl_knock_sanity) gated by a critical-section register snapshot -- likely a knock-retard sanity
; check, not fully confirmed.
                ST      A, 0030ch[X1]

fueltbl_sanitize_loop:     MOV     DP, #00300h

fueltbl_sanitize_check:     JBR     off(00216h).2, fueltbl_range_check
                MB      C, 0b8h.5
                JLT     fueltbl_default_value

fueltbl_range_check:     CMP     [DP], #09862h
                JGT     fueltbl_default_value
                CMP     [DP], #07133h           
                JGE     fueltbl_sanitize_advance

fueltbl_default_value:     MOV     [DP], #08000h

fueltbl_sanitize_advance:     ADD     DP, #00004h
                CMP     DP, #0030ch
                JLT     fueltbl_sanitize_check
                MB      C, (00128h-00180h)[USP].2
                JGE     sensor_check_vcal3
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                MOVB    r0, (00196h-00180h)[USP]
                MOVB    r1, (00116h-00180h)[USP]
                MOVB    r2, (00117h-00180h)[USP]
                MOVB    r3, (0013ch-00180h)[USP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                LB      A, r3
                CAL     knock_helper1
                CMPB    A, r0
                JNE     knock_check_alt_path
                LB      A, r2
                EXTND
                SLL     A
                LC      A, tbl_knock_sanity[ACC]
                JEQ     sensor_check_vcal3
                CMP     A, er0
                JEQ     sensor_check_vcal3

knock_check_alt_path:     L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      TCON0.4
                RB      TCON0.2
                LB      A, #00fh
                STB     A, (00117h-00180h)[USP]
                STB     A, (00197h-00180h)[USP]
                ORB     P2, A
                SB      TCON0.2
                LB      A, (0013ch-00180h)[USP]
                CAL     knock_helper1
                STB     A, (00196h-00180h)[USP]
                XORB    A, #0ffh
                MB      C, ACC.7
                ROLB    A
                STB     A, (00116h-00180h)[USP]
                RB      TCON0.2
                SB      TCON0.4
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE

sensor_check_vcal3:     VCAL    3
                MOV     DP, #003d1h
                LB      A, [DP]
                STB     A, 0dbh
                RC
                JBS     off(00212h).3, sensor_check_gate1
                CMPB    (001d9h-00180h)[USP], #015h
                JGT     sensor_check_gate1
                SC
                JBS     off(0021ch).6, sensor_check_gate1
                MOVB    (001d9h-00180h)[USP], #014h

sensor_check_gate1:     MB      off(00217h).7, C
                JBS     off(00212h).2, sensor_check_clear
                JBS     off(00212h).4, sensor_check_clear
                JBR     off(00217h).5, sensor_check_gate2
                MOVB    (001c2h-00180h)[USP], #032h
                SJ      sensor_check_clear

sensor_check_gate2:     JBS     off(00230h).5, sensor_check_clear
                CMPB    off(00236h), #0ffh
                JGE     sensor_check_gate3
                MOVB    (001c2h-00180h)[USP], #032h

sensor_check_gate3:     JBR     off(00230h).4, sensor_check_clear
                MOV     DP, #00376h
                LB      A, [DP]
                SUBB    A, ADCR6H
                JGE     sensor_check_result
                VCAL    6

sensor_check_result:     CMPB    A, #000h
                JGE     sensor_check_set
                LB      A, (001c2h-00180h)[USP]
                JEQ     dtc05_map_range_latch

sensor_check_clear:     RC
                SJ      dtc05_map_range_latch

sensor_check_set:     SB      off(00230h).5

dtc05_map_range_latch:     MB      0b0h.3, C
; --- ECT (coolant temp) plausibility check and limp-mode fallback (0x36A3-0x371E): if the
; raw ECT reading looks implausible (rate-of-change or range checks vs 0x377/0x378 history),
; ect_simulate_ramp stamps 0xD9 with a value from tbl_ect_simulate_ramp indexed by elapsed time (0x2C4/10)
; -- simulating a warming-up coolant curve rather than trusting a possibly-failed sensor.
; Otherwise ect_smooth_apply/ect_step_helper rate-limit the accepted value toward the raw
; reading. Classic sensor-fault limp-mode handling.
                LB      A, #000h
                JNE     dtc06_ect_latch
                RB      PSWL.4
                CLR     X1
                LB      A, 003d4h[X1]
                STB     A, r1
                RC
                JBS     off(00212h).5, dtc06_ect_latch
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc06_ect_latch
                LB      A, r1
                CMPB    A, #004h

dtc06_ect_latch:     MB      0b0h.1, C
                JBS     off(00212h).5, ect_simulate_ramp
                JLT     ect_fault_stamp
                JBS     off(00221h).6, ect_smooth_apply
                SUBB    A, 00377h[X1]
                JGE     ect_fault_delta_check
                VCAL    6

ect_fault_delta_check:     CMPB    A, #002h
                JGT     ect_fault_normal_store
                LB      A, (001c3h-00180h)[USP]
                JNE     sensor_bank_gate1
                LB      A, r1
                JBS     off(00217h).4, ect_smooth_apply
                CMPB    A, 00378h[X1]
                JGT     sensor_bank_ect_check
                SJ      ect_smooth_apply

ect_simulate_ramp:     JBR     off(00217h).5, ect_fault_stamp
                CLR     A
                LB      A, off(002c4h)
                MOVB    r0, #00ah
                DIVB
                MOV     DP, #tbl_ect_simulate_ramp
                ADD     DP, A
                LCB     A, [DP]
                STB     A, 0d9h
                SB      PSWL.4
                SJ      sensor_bank_ect_check

ect_fault_stamp:     MOVB    0d9h, #03bh
                SB      PSWL.4
                SJ      sensor_bank_ect_check

ect_smooth_apply:     MOVB    r0, 0d9h
                MOV     DP, #000d9h
                CAL     ect_smooth_helper
                CMPB    A, r0
                JEQ     ect_store_history_check
                SB      PSWL.4

ect_store_history_check:     JBS     off(00217h).5, ect_step_call
                STB     A, 0031ah[X1]

ect_step_call:     CAL     ect_step_helper

ect_fault_normal_store:     LB      A, r1
                STB     A, 00377h[X1]

sensor_bank_ect_check:     MOVB    (001c3h-00180h)[USP], #005h
; --- Continuing multi-sensor plausibility bank (0x371E-0x378C+): similar pattern to the ECT
; check above, applied to IAT/MAT (0xD8, iat_fault_stamp/iat_range_check) and other analog
; readings, each setting a bit in the shared 0xB0 status byte (bits 3/5/6/7) plus occasional
; direct stamps (0xE3/0xBC). Consistent sensor-plausibility/limp-mode pattern throughout.

sensor_bank_gate1:     JBS     off(00230h).3, sensor_bank_gate1_alt
                LB      A, #057h
                CMPB    A, 0d9h
                MB      off(002edh).1, C
                SC
                SJ      sensor_bank_flag1

sensor_bank_gate1_alt:     MB      C, PSWL.4

sensor_bank_flag1:     MB      off(002ech).1, C
                RC
                JBS     off(00212h).7, dtc08_tdc_latch
                JBR     off(00217h).4, dtc08_tdc_latch
                MB      C, off(00219h).6

dtc08_tdc_latch:     MB      0b0h.5, C
                LB      A, #000h
                JNE     iat_fault_stamp
                JBR     off(00213h).1, iat_range_check

iat_fault_stamp:     MOVB    0d8h, #056h
                SJ      iat_check_return

iat_range_check:     LB      A, #0fch
                MOV     DP, #003cch
                CMPB    A, [DP]
                JLT     dtc10_iat_latch
                LB      A, [DP]
                CMPB    A, #004h
                JLT     dtc10_iat_latch
                MOV     DP, #000d8h
                CAL     ect_smooth_helper

iat_check_return:     RC

dtc10_iat_latch:     MB      0b0h.6, C
                LB      A, #080h
                RC
                JBS     off(00217h).6, sensor_bank_store_e3
                JBS     off(00219h).3, sensor_bank_store_e3
                JBS     off(00213h).2, sensor_bank_store_e3
                MOV     DP, #003d2h
                LB      A, #0ffh
                CMPB    A, [DP]
                JLT     dtc_bit08_latch
                LB      A, [DP]
                CMPB    A, #000h
                JLT     dtc_bit08_latch

sensor_bank_store_e3:     STB     A, 0e3h

dtc_bit08_latch:     MB      0b0h.7, C
                JBR     off(00227h).4, sensor_bank_stamp_bc
                JBR     off(00213h).4, sensor_bank_bc_alt

sensor_bank_stamp_bc:     MOVB    0bch, #0f9h
                SJ      dcode14_return

sensor_bank_bc_alt:     CLR     A
                LB      A, #0e6h
                MOV     DP, #003cdh
                CMPB    A, [DP]
                JLT     dtc13_baro_latch
                LB      A, [DP]
                CMPB    A, #051h
                JLT     dtc13_baro_latch
                CAL     sub_clamp_helper
                MOV     DP, #000bch
                CAL     ect_smooth_helper

dcode14_return:     RC

dtc13_baro_latch:     MB      0b1h.2, C
; --- Dcode14 (real diagnostic-code calibration field) gated check: reads 0xDB against two
; threshold tables (tbl_dcode14_lo/tbl_dcode14_hi) via VCAL 2 (a vectored call target not yet identified,
; used for table lookups here), comparing against off(0025ch). Sets status bits at 0xB1
; (3/4) similar to the 0xB0 sensor-plausibility bank pattern above.
                VCAL    3
                LCB     A, Dcode14
                JNE     dtc14_iacv_latch
                JBS     off(00217h).5, dcode14_clear
                JBS     off(00213h).5, dcode14_clear
                LB      A, 0dbh
                MOV     X1, #tbl_dcode14_lo
                VCAL    2
                CMPB    A, off(0025ch)
                JLT     dcode14_clear
                LB      A, 0dbh
                MOV     X1, #tbl_dcode14_hi
                VCAL    2
                CMPB    A, off(0025ch)
                JGE     dcode14_clear
                LB      A, (001c4h-00180h)[USP]
                JEQ     dtc14_iacv_latch

dcode14_clear:     RC

dtc14_iacv_latch:     MB      0b1h.3, C
                LB      A, #044h
                CMPB    A, 0dbh
                JGE     dtc17_vss_latch
                CMPB    off(00236h), #0a7h
                JGE     dtc17_vss_latch
                RC
                JBS     off(0022dh).1, dtc17_vss_latch
                JBS     off(00217h).5, dtc17_vss_latch
                JBS     off(00214h).0, dtc17_vss_latch
                JBR     off(00231h).3, dtc17_vss_latch
                MB      C, off(0021ch).4

dtc17_vss_latch:     MB      0b1h.4, C
                VCAL    3
                LB      A, #000h
                JNE     dcode_gate_common2
                LB      A, #01fh
                SJ      dcode_stamp_store

dcode_gate_common2:     LB      A, #01fh
                JBR     off(00219h).3, dcode_stamp_store
                JBR     off(00217h).6, dcode_stamp_store
                JBS     off(00214h).3, dcode_stamp_store
                CMPB    0dbh, #069h
                JLT     dcode_stamp_store
                MOV     DP, #003d2h
                LB      A, #0dch
                CMPB    A, [DP]
                JLT     dtc20_eld_latch
                LB      A, [DP]
                CMPB    A, #00eh
                JLT     dtc20_eld_latch

dcode_stamp_store:     STB     A, 0dch
                RC

dtc20_eld_latch:     MB      0b1h.7, C
                RC
                LCB     A, VTSF
                JNE     dtc21_vtec_solenoid_latch
                LCB     A, ALTVtecEnable
                JNE     dtc21_vtec_solenoid_latch
                JBR     off(00216h).4, dtc21_vtec_solenoid_latch
                JBS     off(00214h).4, dtc21_vtec_solenoid_latch
                JBR     off(0021fh).2, altvtec_ramp_alt
                MOVB    (001b5h-00180h)[USP], #032h
                LB      A, (001b4h-00180h)[USP]
                JBS     off(00210h).5, dtc21_vtec_solenoid_latch

altvtec_ramp_common:     SC
                SJ      dtc21_vtec_solenoid_latch

altvtec_ramp_alt:     MOVB    (001b4h-00180h)[USP], #032h
                LB      A, (001b5h-00180h)[USP]
                JBS     off(00210h).5, altvtec_ramp_common

dtc21_vtec_solenoid_latch:     MB      0b2h.0, C
                LCB     A, VTPS
                JNE     altvtec_vtps_result
                LCB     A, ALTVtecEnable
                JNE     altvtec_vtps_result
                JBR     off(00216h).4, altvtec_vtps_result
                JNE     altvtec_vtps_result
                JBS     off(00214h).4, altvtec_vtps_result
                JLT     altvtec_vtps_result
                JBS     off(00214h).5, altvtec_vtps_result
                MB      C, off(00211h).1
                JBR     off(0021fh).2, dtc22_vtec_pressure_latch
                JLT     altvtec_vtps_result
                SC
                SJ      dtc22_vtec_pressure_latch

altvtec_vtps_result:     RC

dtc22_vtec_pressure_latch:     MB      0b2h.1, C
; --- dtc26_code26_latch transmission support (0x3878+): dtc23_knock_latch (torque-converter-clutch lockup
; engagement conditions) and dtc26_code26_latch (auto-vs-manual transmission detection, using P4.6 --
; note this P4.6 usage here means the earlier tentative "VTEC oil pressure switch" guess for
; P4.6 should stay hedged, not be treated as confirmed, since it's evidently reused/shared).
; New subsystem not touched earlier this session.
                RC
                JBR     off(00227h).6, dtc23_knock_latch
                JBS     off(00217h).5, dtc23_knock_latch
                JBS     off(00214h).6, dtc23_knock_latch
                JBS     off(00233h).6, dtc23_knock_latch
                L       A, off(00212h)
                AND     A, #0c3bch
                JNE     dtc23_knock_latch
                JBS     off(00214h).5, dtc23_knock_latch
                LB      A, off(002fch)
                JEQ     dtc23_knock_latch
                JBS     off(00233h).7, dtc23_knock_latch
                MB      C, off(00232h).7

dtc23_knock_latch:     MB      0b2h.2, C
                JBR     off(00216h).5, autotcc_return
                CLRB    A
                STB     A, 0d7h
                JBS     off(00217h).5, autotcc_return
                JBS     off(00215h).1, autotcc_return
                CMPB    0dbh, #0ffh
                JLT     autotcc_return
                LB      A, #0ffh
                CMPB    A, 0d7h
                JLT     dtc26_code26_latch
                CMPB    0d7h, #000h
                SJ      dtc26_code26_latch

autotcc_return:     RC

dtc26_code26_latch:     MB      0b3h.1, C
                JBR     off(00216h).5, automatic_return
                JBS     off(00217h).5, automatic_return
                JBS     off(00215h).0, automatic_return
                JBS     off(00215h).1, automatic_return
                MB      C, 0b3h.1
                JLT     automatic_return
                CMPB    0dbh, #0ffh
                JGE     automatic_p4_check

automatic_return:     RC
                SJ      dtc25_code25_latch

automatic_p4_check:     CMPB    0d7h, #0ffh
                JLE     automatic_result
                MB      C, P4.6
                XORB    PSWH, #080h
                SJ      dtc25_code25_latch

automatic_result:     MB      C, P4.6

dtc25_code25_latch:     MB      0b3h.0, C
                JBR     off(00219h).3, knockwindow_clear
                JBS     off(00217h).5, knockwindow_clear
                MOV     DP, #003afh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     knockwindow_clear
                L       A, off(00212h)
                AND     A, #01808h
                JNE     knockwindow_clear
                JBS     off(00214h).5, knockwindow_clear
                JBS     off(0021ch).5, knockwindow_clear
                JBS     off(0021dh).3, knockwindow_clear
                JBS     off(00218h).0, knockwindow_clear
                CMPB    0cch, #005h
                JLT     knockwindow_check2
                MOV     X1, #tbl_knockwindow_alt
                JBS     off(0021fh).1, knockwindow_table_lookup
                MOV     X1, #tbl_ignmap2_hi

knockwindow_table_lookup:     LB      A, off(00236h)
                CAL     table_interp_lookup
                ADDB    A, #010h
                JGE     knockwindow_check1
                LB      A, #0ffh

knockwindow_check1:     CMPB    A, off(00235h)
                JGE     knockwindow_clear

knockwindow_check2:     L       A, (00158h-00180h)[USP]
                CMP     A, #0b333h
                JGE     knockwindow_set
                JBS     off(00217h).3, knockwindow_check3
                JBS     off(0021eh).4, knockwindow_clear

knockwindow_check3:     CMP     A, #05BB7h       ; knock period upper bound (raw constant; was mis-bound to code addr 05BB7h)
                JLE     knockwindow_set

knockwindow_clear:     RC
                SJ      knockwindow_result

knockwindow_set:     SC

knockwindow_result:     MB      0b5h.7, C
                VCAL    3
                JBS     off(002ech).1, knockwindow_next_table
                J       iat_map_correction_chain

knockwindow_next_table:     MOV     X1, #tbl_ect_fuelcorrect
; ============================================================================================
; ECT-INDEXED FUEL/VE CORRECTION CHAIN (0x394F-0x3A48): a long, mostly linear sequence of
; ECT (0xD9) indexed table_interp_lookup calls computing multiple correction factors, each
; separated by a VCAL 3 scheduler tick. High-confidence identification via real calibration
; fields encountered: ECTFuelCorrect, VEFuelCorrect, Overrun_Resume_nor/Overrun_Resume_int
; (overrun/deceleration fuel-cut resume thresholds, normal vs "interrupted"), plus several
; unnamed tables (tbl_ect_fuelcorrect/682f/680c/68ef/69e0/6a88/63fc/63ee/64b5). Results are stored to a
; cluster of working RAM locations (0x152/0x17D/0x18C/0x18E/0x243h-adjacent/0x254/0x262/0x296/
; 0x37c/0x37d/0x37e) consumed elsewhere in the fuel/VE calculation. VCAL 0 appears here paired
; with simple load-then-store sequences -- likely a lightweight "clamp or pass-through" helper,
; not yet independently confirmed.
; ============================================================================================
                LB      A, 0d9h
                VCAL    0
                STB     A, off(00262h)
                VCAL    3
                MOV     X1, #tbl_ect_overrun_nor
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, off(00296h)
                MOV     X1, #tbl_ect_vecorrect
                LB      A, 0d9h
                CAL     table_interp_lookup
                MOV     DP, #0037dh
                STB     A, [DP]
                VCAL    3
                CLR     X2
                MOV     X1, #tbl_ect_overrun_int
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, 0037ch[X2]
                MOV     X1, #tbl_knockwindow_9
                LB      A, 0d9h
                VCAL    0
                STB     A, 0037eh[X2]
                VCAL    3
                LB      A, 0d9h
                CMPB    A, #023h
                MB      off(00221h).2, C
                LB      A, 0d9h
                MOV     X1, #tbl_knockwindow_10
                CAL     table_interp_lookup
                STB     A, off(00254h)
                VCAL    3
                MOV     X1, #Overrun_Resume_nor
                MOV     X2, #Overrun_Resume_int
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r2
                MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, ACCH
                LB      A, r2
                MOV     (0018eh-00180h)[USP], A
                VCAL    3
                MOV     X1, #tbl_knockwindow_4
                MOV     X2, #tbl_knockwindow_3
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r2
                MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, ACCH
                LB      A, r2
                MOV     (0018ch-00180h)[USP], A
                VCAL    3
                LB      A, 0d9h
                MOV     X1, #VEFuelCorrect
                CMPCB   A, 00002h[X1]
                MB      off(00219h).5, C
                CAL     table_interp_lookup
                STB     A, (0017dh-00180h)[USP]
                LB      A, 0d9h
                MOV     X1, #tbl_knockwindow_5
                VCAL    0
                STB     A, (00152h-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #ECTFuelCorrect
                CAL     table_interp_lookup
                STB     A, (00168h-00180h)[USP]
                STB     A, (00169h-00180h)[USP]
                LB      A, r2
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                LB      A, r2
                MOV     X1, #FuelSettingsStuff
                CAL     table_interp_lookup
                STB     A, (0017fh-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #tbl_knockwindow_6
                CAL     table_interp_lookup
                STB     A, (00189h-00180h)[USP]
                LB      A, r2
                MOV     X1, #tbl_knockwindow_7
                CAL     table_interp_lookup
                STB     A, (0018ah-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #tbl_knockwindow_8
                CAL     table_interp_lookup
                STB     A, (0018bh-00180h)[USP]
                LB      A, r2
                MOV     X1, #Tipintempoffsetnormal
                VCAL    0
                STB     A, (00184h-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                MOV     X1, #Tipintempoffsetinitial
                VCAL    0
                STB     A, (00186h-00180h)[USP]
                LB      A, 0d9h
                MOV     X1, #tbl_ect_knock_scale
                CAL     table_interp_lookup
                STB     A, (0016dh-00180h)[USP]
                LB      A, 0d9h
                MOV     X1, #tbl_knockwindow_2
                CAL     table_interp_lookup
                STB     A, (001f4h-00180h)[USP]
                VCAL    3
                VCAL    3

iat_map_correction_chain:     LB      A, 0d8h
                MOV     X1, #tbl_iat_correct1
                VCAL    0
                STB     A, off(0027ch)
                LB      A, 0bch
                MOV     X1, #tbl_iat_correct2
                VCAL    1
                STB     A, off(00292h)
                VCAL    3
                LB      A, #074h
                JBS     off(00220h).5, threshold_bank_220_5
                LB      A, #080h

threshold_bank_220_5:     CMPB    A, off(00236h)
                MB      off(00220h).5, C
                LB      A, #0c2h
                JBS     off(00220h).6, threshold_bank_220_6
                LB      A, #0c6h

threshold_bank_220_6:     CMPB    A, off(00236h)
                MB      off(00220h).6, C
                LB      A, #0c8h
                JBS     off(00222h).6, threshold_bank_222_6
                LB      A, #0d0h

threshold_bank_222_6:     CMPB    A, off(00235h)
                MB      off(00222h).6, C
                LB      A, #082h
                JBS     off(00220h).7, threshold_bank_220_7
                LB      A, #08ah

threshold_bank_220_7:     CMPB    A, off(00235h)
                CLRB    A
                MB      off(00220h).7, C
                JBS     off(00218h).0, div_scale_store
                JGE     div_scale_store
                CLR     A
                MOV     DP, #003d9h
                JBS     off(00222h).6, div_scale_dp_select
                MOV     DP, #003d6h

div_scale_dp_select:     LB      A, [DP]
                CMPB    A, #0fah
                JGE     div_scale_default
                SUBB    A, #007h
                JGE     div_scale_calc1
                CLRB    A

div_scale_calc1:     MOVB    r0, #051h
                DIVB
                JBR     off(00220h).5, div_scale_gate_common
                MOVB    r0, #01bh
                LB      A, r1
                DIVB
                JBR     off(00220h).6, div_scale_gate_common
                MOVB    r0, #009h
                LB      A, r1
                DIVB

div_scale_gate_common:     CMPB    A, #003h
                JLT     div_scale_mul_final

div_scale_default:     LB      A, #002h

div_scale_mul_final:     MOVB    r0, #008h
                MULB
                VCAL    6

div_scale_store:     STB     A, off(00243h)
; --- Gear detection + tip-in/dwell/rev-limiter table selection (0x3AC2-0x3B37+):
; gear_detect_loop/index_calc walks the GearCustom table (real field: VSS/RPM-ratio-based
; gear lookup, a classic "detect current gear from wheel speed vs engine speed ratio" method
; for ECUs without a direct gear-position sensor) to find the current gear index, stored to
; off(0024fh). Then looks up TipinGear[gear] (per-gear tip-in enrichment) and DwellBattery
; (ignition coil dwell time vs battery voltage compensation). Finally revlimit_table_select
; picks between two rev-limiter table pairs based on RevlimitWarmC (a coolant-temp threshold)
; -- warm vs cold rev limiter targets, loaded into a critical section for later use.
                LB      A, #005h
                MOV     X1, #00004h
                CLR     X1
                JBS     off(00217h).5, gear_detect_store
                JBS     off(00214h).0, gear_detect_store
                MOVB    r1, 0cch
                CLRB    r0
                L       A, 0c4h
                MUL
                L       A, er1
                MOV     DP, #00004h

gear_detect_loop:     CMPC    A, GearCustom[X1]
                JLT     gear_detect_index_calc
                INC     X1
                INC     X1
                JRNZ    DP, gear_detect_loop

gear_detect_index_calc:     SRL     X1
                L       A, X1
                LB      A, ACC
                ADDB    A, #001h

gear_detect_store:     STB     A, off(0024fh)
                LCB     A, TipinGear[X1]
                STB     A, off(00250h)
                LB      A, 0dbh
                MOV     X1, #DwellBattery
                CAL     table_interp_lookup
                STB     A, off(0024bh)
                VCAL    3
                JBS     off(00217h).4, threshold_bank_223_2
                LB      A, 0beh
                CMPB    A, #04ah
                JLT     dwell_battery_check2
                SB      (00129h-00180h)[USP].3

dwell_battery_check2:     CMPB    A, #04bh
                JLT     threshold_bank_223_2
                SB      (00129h-00180h)[USP].0


threshold_bank_223_2:     LB      A, #0a0h
                JBS     off(00223h).2, threshold_bank_223_2_store
                LB      A, #0d8h

threshold_bank_223_2_store:     CMPB    A, off(00236h)
                MB      off(00223h).2, C
                CLR     A
                LCB     A, RevlimitWarmC
                CMPB    0d9h, A
                MOV     X1, #tbl_threshold_223_1
                MOV     X2, #Revlimiters
                JGT     revlimit_table_select
                MOV     X1, #tbl_threshold_223_2
                MOV     X2, #tbl_threshold_223_3

revlimit_table_select:     LC      A, 00002h[X1]
                MOV     DP, A
                LC      A, 00002h[X2]
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, (00192h-00180h)[USP]
                L       A, DP
                ST      A, (00194h-00180h)[USP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_warm3
                VCAL    1
                STB     A, (00190h-00180h)[USP]
                VCAL    3
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_warm2
                CAL     table_interp_lookup
                STB     A, (00167h-00180h)[USP]
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_cold4
                VCAL    1
                STB     A, (00181h-00180h)[USP]
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_warm1
                VCAL    1
                STB     A, (0017eh-00180h)[USP]
                VCAL    3
                MOV     X1, #tbl_revlimit_cold1
                CMPB    0cch, #014h
                JLT     iat_table_select
                MOV     X1, #tbl_revlimit_cold2
                CMPB    0cch, #038h
                JLT     iat_table_select
                MOV     X1, #tbl_revlimit_cold3

iat_table_select:     LB      A, 0d8h
; --- Continues the correction chain: IAT (0xD8) indexed lookups into IATFuelCorrect,
; IATScaler2, IATScaler (real calibration fields, IAT-based fuel correction factors),
; results stored to a small working-RAM cluster at 0x3EA onward. Same VCAL 0/1/3 pattern as
; the ECT correction chain earlier.
                VCAL    1
                CMPB    0d9h, A
                MB      off(00219h).1, C
                LB      A, 0d8h
                MOV     X1, #IATFuelCorrect
                VCAL    0
                MOV     DP, #003eah
                STB     A, [DP]
                LB      A, 0d8h
                MOV     X1, #IATScaler2
                VCAL    0
                INC     DP
                INC     DP
                STB     A, [DP]
                LB      A, 0d8h
                MOV     X1, #IATScaler
                VCAL    0
                INC     DP
                INC     DP
                STB     A, [DP]
                VCAL    3
                CLR     A
                LB      A, #0c2h
                JBS     off(00223h).4, threshold_bank_223_4
                LB      A, #0c6h

threshold_bank_223_4:     CMPB    A, off(00236h)
                MB      off(00223h).4, C
                LCB     A, tbl_idle_pi_clamp
                SRLB    A
                SRLB    A
                CLRB    r2
                MOV     DP, #003ceh
                LB      A, [DP]
                JLT     knock_retard_check
                CMPB    A, #0f0h
                JLT     knock_div_calc1
                LB      A, #076h

knock_div_calc1:     MOVB    r0, #030h
                DIVB
                JBS     off(00223h).4, knock_table_index
                SRLB    A
                LB      A, r1
                JGE     knock_div_calc2
                LB      A, #02fh
                SUBB    A, r1

knock_div_calc2:     MOVB    r0, #009h
                DIVB
                ADDB    A, #006h

knock_table_index:     SLLB    A
                EXTND
                LC      A, tbl_knock_index[ACC]
                SJ      knock_result_store

knock_retard_check:     ADDB    A, #080h
                STB     A, r2
                L       A, #08000h

knock_result_store:     ST      A, (00160h-00180h)[USP]
                MOVB    off(00242h), r2
                CLRB    A
                STB     A, (0013fh-00180h)[USP]
                STB     A, (00149h-00180h)[USP]
                CLRB    A
                MOV     DP, #003d7h
                LCB     A, tbl_idle_pi_clamp
                MB      C, ACC.3
                JGE     knock_clear_284
                LB      A, [DP]
                MOVB    r0, #080h
                MULB
                L       A, ACC
                ADD     A, #0c000h
                ST      A, er0
                MOV     off(00284h), er0
                CLR     A
                LB      A, #076h
                SJ      knock_div_calc3

knock_clear_284:     CLR     A
                ST      A, off(00284h)
                LB      A, [DP]
                CMPB    A, #0f0h
                JLT     knock_div_calc3
                LB      A, #076h


knock_div_calc3:     MOVB    r0, #030h
                DIVB
                STB     A, r2
                SRLB    A
                LB      A, r1
                JGE     knock_div_calc4
                LB      A, #02fh
                SUBB    A, r1

knock_div_calc4:     MOVB    r0, #009h
                DIVB
                ADDB    A, #006h
                SLLB    A
                EXTND
                MOV     X1, #tbl_knock_div
                JBS     off(00216h).0, knock_table2d_lookup
                ADD     X1, #00024h

knock_table2d_lookup:     MOV     X2, X1
                ADD     X1, A
                LC      A, [X1]
                ST      A, er0
                ADD     X1, #0000ch
                LC      A, [X1]
                ST      A, er2
                LB      A, r2
                SLLB    A
                EXTND
                ADD     X2, A
                LC      A, [X2]
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, (00176h-00180h)[USP]
                L       A, er0
                ST      A, (00178h-00180h)[USP]
                L       A, er2
                ST      A, (001f2h-00180h)[USP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                LB      A, 0dbh
                MOV     X1, #InjectorIndex
                VCAL    0
                STB     A, (00144h-00180h)[USP]
                VCAL    3
                MOV     DP, #003cah
                LB      A, [DP]
                STB     A, 0dah
                JBR     off(00219h).3, injidx_gate2
                MOV     DP, #003afh
                LB      A, [DP]
                CMPB    A, #031h
                JNE     injidx_gate1
                SB      off(00223h).3
                SB      off(00219h).0
                RB      off(00223h).1
                SJ      injidx_flag_set

injidx_gate1:     JBR     off(00223h).3, injidx_gate3

injidx_gate2:     RB      off(00223h).3

injidx_flag_clear:     RB      off(00219h).0
                SB      off(00223h).1

injidx_flag_set:     SB      off(00223h).0
                J       vss_ect_stamp

injidx_gate3:     JBS     off(0021dh).4, injidx_flag_clear
                LB      A, off(002c1h)
                JEQ     injidx_gate4
                RB      off(00219h).0
                RB      off(00223h).1

injidx_flag_set2:     RB      off(00223h).0
                MOVB    off(002c2h), #064h
                SJ      vss_ect_stamp

injidx_gate4:     JBS     off(00217h).5, injidx_flag_set2
                JBS     off(00219h).0, vss_ect_gate
                JBR     off(00223h).1, injidx_gate6
                JBS     off(00216h).6, injidx_gate5
                JBS     off(00218h).0, vss_ect_gate

injidx_gate5:     JBR     off(0021dh).2, vss_ect_gate
                RB      off(00219h).0
                RB      off(00223h).1
                SB      off(00223h).0

injidx_gate6:     JBR     off(00216h).6, closeloopnarrow_check
                JBS     off(00219h).0, closeloopnarrow_check
                JBS     off(00223h).1, closeloopnarrow_check
                JBS     off(00223h).0, closeloopnarrow_check
                JBR     off(00219h).2, injidx_stamp_c2
                JBR     off(00219h).1, injidx_stamp_c2
                JBS     off(0021dh).2, injidx_c2_check


injidx_stamp_c2:     MOVB    off(002c2h), #064h
                SJ      closeloopnarrow_check

injidx_c2_check:     LB      A, off(002c2h)
                JNE     closeloopnarrow_check
                LB      A, #033h
                SJ      closeloopnarrow_result

closeloopnarrow_check:     LCB     A, CloseLoopNarrow
                JNE     closeloopnarrow_set
                LB      A, #017h

closeloopnarrow_result:     CMPB    A, 0dah
                JLT     vss_ect_gate

closeloopnarrow_set:     SB      off(00219h).0

vss_ect_gate:     CMPB    0d9h, #028h
                JGE     vss_ect_stamp
                CMPB    0cch, #005h
                JGE     vss_ect_stamp
                CMPB    off(00236h), #080h
                JLT     vss_ect_stamp
                JBR     off(0021dh).2, vss_ect_stamp
                LB      A, off(002b6h)
                JNE     idle_state_defaults
                SB      off(00219h).0
                RB      off(00223h).1
                SJ      idle_state_defaults

vss_ect_stamp:     MOVB    off(002b6h), #004h

idle_state_defaults:     MOVB    r0, #005h
                MOVB    r1, #032h
                MOVB    r2, #032h
                MOVB    r3, #018h
                JBR     off(0021dh).1, idle_stage_alt_start
                JBR     off(00218h).0, idle_stage_alt_start
                MOVB    off(002bfh), r1
                MOVB    off(002c0h), r2
                JBR     off(00219h).0, idle_stage_b7_store
                JBS     off(0021eh).4, idle_stage_da_check
                L       A, (00158h-00180h)[USP]
                CMP     A, #0bc15h
                JGE     idle_stage_da_check
                CMP     A, #leanprotect_backref_m2
                JLE     idle_stage_da_check
                LB      A, r3
                CMPB    A, 0dah
                JLT     idle_stage_b7_load

idle_stage_b7_store:     MOVB    off(002b7h), r0

idle_stage_b7_load:     LB      A, off(002b7h)
                SJ      idle_stage_stamp_d4

idle_stage_alt_start:     MOVB    off(002b7h), r0
                JBR     off(0021ch).2, idle_stage_c0_start
                MOVB    off(002c0h), r2
                JBR     off(00219h).0, idle_stage_bf_store
                LB      A, r3
                CMPB    A, 0dah
                JLT     idle_stage_bf_load

idle_stage_bf_store:     MOVB    off(002bfh), r1

idle_stage_bf_load:     LB      A, off(002bfh)
                SJ      idle_stage_stamp_d4

idle_stage_c0_start:     MOVB    off(002bfh), r1
                JBR     off(00219h).0, idle_stage_c0_store
                JBR     off(0021ch).6, idle_stage_c0_load

idle_stage_c0_store:     MOVB    off(002c0h), r2

idle_stage_c0_load:     LB      A, off(002c0h)

idle_stage_stamp_d4:     MOVB    off(002d4h), #050h
                SJ      idle_stage_final_check

idle_stage_da_check:     CMPB    0dah, #04dh
                JLE     idle_stage_d4_load
                CLRB    A
                SJ      idle_stage_stamp_d4

idle_stage_d4_load:     LB      A, off(002d4h)

idle_stage_final_check:     JNE     gio_fuelpump_dispatch
                LCB     A, CloseLoopNarrow
                JNE     gio_fuelpump_dispatch
                RB      off(00219h).0
                SB      off(00223h).1

gio_fuelpump_dispatch:     VCAL    3
                MOV     DP, #0040eh
                MB      C, [DP].5
                JGE     fuelpump_mode_check
                INC     DP
                MB      C, [DP].5
                XORB    PSWH, #080h
                SJ      fuelpump_relay_drive

fuelpump_mode_check:     LCB     A, FPMode
; --- Fuel pump relay control: FPMode (calibration field) selects the drive logic, ultimately
; driving the fuel pump relay via P0.7 (fuelpump_relay_drive). Uses the shared scratch byte
; off(002c6h) here as a pump-state value -- see the note at mil_blink_check_gate: this byte's
; meaning is local to each routine that touches it, not a single global identity.
                JEQ     fuelpump_gate1
                RC
                MB      C, ACC.0
                XORB    PSWH, #080h
                SJ      fuelpump_relay_drive

fuelpump_gate1:     JBS     off(00221h).0, fuelpump_gate2
                RC
                LB      A, off(002c6h)
                JNE     fuelpump_relay_drive
                SB      off(00221h).0

fuelpump_gate2:     JBS     off(00219h).6, fuelpump_relay_drive
                MB      C, off(00217h).4

fuelpump_relay_drive:     MB      P0.7, C
                RC
                MOV     DP, #0040eh
                MB      C, [DP].4
                JLT     fuelpump_gate3
                JBS     off(00221h).6, fuelpump_done

fuelpump_gate3:     JBS     off(00218h).6, fuelpump_state_active
                LB      A, #07fh
                CMPB    A, #0ffh
                JGT     fuelpump_gate4
                CMPB    A, #0fch
                JGE     fuelpump_state_clear

fuelpump_gate4:     JBS     off(00230h).6, fuelpump_state_active

fuelpump_state_clear:     CLRB    A
                JBS     off(00219h).6, fuelpump_state_store
                JBS     off(00217h).4, fuelpump_state_check

fuelpump_state_store:     STB     A, off(002c6h)

fuelpump_state_check:     RC
                LB      A, off(002c6h)
                JEQ     fuelpump_state_inactive

fuelpump_state_active:     SC

fuelpump_state_inactive:     MB      off(00222h).3, C
                CAL     shiftlight_check_start

fuelpump_done:     LB      A, #014h
                JBS     off(00226h).0, rpm_threshold_226_0
                LB      A, #019h

rpm_threshold_226_0:     CMPB    A, 0cch
                MB      off(00226h).0, C
                LB      A, #010h
                JBS     off(00226h).1, rpm_threshold_226_1
                LB      A, #020h

rpm_threshold_226_1:     CMPB    A, 0cch
                MB      off(00226h).1, C
                LB      A, #026h
                JBS     off(00226h).2, tps_threshold_226_2
                LB      A, #07fh

tps_threshold_226_2:     CMPB    A, 0d1h
                MB      off(00226h).2, C
                LB      A, #073h
                JBS     off(00226h).3, vss_threshold_226_3
                LB      A, #080h

vss_threshold_226_3:     CMPB    A, off(00236h)
                MB      off(00226h).3, C
                LB      A, #0f0h
                JBS     off(00226h).6, vss_threshold_226_6
                LB      A, #0fah

vss_threshold_226_6:     CMPB    A, off(00236h)
                MB      off(00226h).6, C
                CAL     FlexFuelMod
                MOV     DP, #0040eh
                MB      C, [DP].0
                JGE     accut_idlecut_check
                INC     DP
                MB      C, [DP].0
                XORB    PSWH, #080h
                J       accut_output_drive

accut_idlecut_check:     LC      A, IdleCut
; --- AC compressor idle-cut logic (0x3E63 onward): IdleCut/IdleRes (real fields) gate on a
; raw period value (0xC4) with hysteresis, combined with ECT/TPS/RPM threshold checks and
; DisableAC (real field), to decide whether to cut the AC compressor clutch -- classic
; "cut AC briefly under heavy load / near idle" behavior. Preceded directly by the confirmed
; CAL FlexFuelMod call site (0x3E50)
                JBS     off(00226h).5, accut_rpm_gate
                LC      A, IdleRes

accut_rpm_gate:     CMP     0c4h, A
                MB      off(00226h).5, C
                CMPB    0f3h, #032h
                JLT     accut_reset_c3
                JBS     off(00226h).6, accut_reset_f7
                CMPB    0d9h, #013h
                JGE     accut_gate2
                JBR     off(00226h).0, accut_gate2
                JBS     off(00226h).3, accut_reset_f7


accut_gate2:     JBS     off(00218h).7, accut_disableac_check
                JBS     off(00226h).2, accut_check_c3
                CLRB    A
                JBS     off(00226h).1, accut_store_c3
                LB      A, #028h

accut_store_c3:     STB     A, off(002c3h)
                SJ      accut_disableac_check

accut_check_c3:     LB      A, off(002c3h)
                JNE     accut_reset_f7

accut_disableac_check:     LCB     A, DisableAC
; --- Full AC compressor cut condition set: chkAcCut/ACCutRPM/ACCutTPS/ACCVSSMax (real
; calibration fields) gate cutting the AC compressor clutch above certain RPM/TPS/VSS
; thresholds (protects engine power/cooling under load), plus a GIO-triggered override
; (0x420.4) with a timed delay (0x2F6/0x2F7 countdown). Result drives P0.0 -- the actual
; AC compressor clutch relay output.
                JNE     rpm_threshold_2ed_4
                LCB     A, chkAcCut
                JEQ     accut_alt_gate
                LC      A, ACCutRPM
                CMP     0c4h, A
                JLT     accut_disabled_path
                LCB     A, ACCutTPS
                CMPB    0d1h, A
                JGT     accut_disabled_path
                LCB     A, ACCVSSMax
                CMPB    0cch, A
                JGT     accut_disabled_path

accut_alt_gate:     JBS     off(00226h).5, accut_gio_check

accut_disabled_path:     RB      off(00226h).4
                SJ      accut_result_common

accut_gio_check:     MOV     DP, #00420h
                MB      C, [DP].4
                JLT     accut_common
                JBR     off(00211h).2, accut_common
                SB      off(00226h).4
                LB      A, off(002f6h)
                JNE     accut_result_common
                MOVB    off(002f7h), #028h

accut_delay_check:     SB      off(0021bh).0
                RC
                SJ      accut_output_drive

accut_reset_c3:     CLRB    off(002c3h)

accut_reset_f7:     CLRB    off(002f7h)

accut_common:     RB      off(00226h).4
                LB      A, off(002f7h)
                JNE     accut_delay_check
                MOVB    off(002f6h), #032h

accut_result_common:     RB      off(0021bh).0
                SC

accut_output_drive:     MB      P0.0, C

rpm_threshold_2ed_4:     LB      A, #074h
                JBS     off(002edh).4, vss_threshold_2ed_4
                LB      A, #080h

vss_threshold_2ed_4:     CMPB    A, off(00236h)
                MB      off(002edh).4, C
                LB      A, #022h
                JBS     off(002edh).5, vss_threshold_2ed_5
                LB      A, #032h

vss_threshold_2ed_5:     CMPB    A, 0cch
                MB      off(002edh).5, C
                MOV     DP, #0040eh
                MB      C, [DP].1
                JGE     purge_gate1
                INC     DP
                MB      C, [DP].1
                XORB    PSWH, #080h
                MB      P0.1, C
                SJ      gio_boost_override_check

purge_gate1:     JBS     off(00217h).5, purge_result_clear
; --- EVAP canister purge valve control (0x3F2A onward): gates purge on ECT/RPM/mode
; conditions, with a timed enable delay after startup (0x2D5/0x2CB counters), then
; DisablePurge/PurgeInvert (real fields) finalize the drive signal. Complements the
; AC-cut and idle logic named just above -- another accessory/emissions output on the
; same shared P0 port.
                JBS     off(00212h).5, purge_gate2
                CMPB    0d9h, #030h
                JGE     purge_result_clear

purge_gate2:     JBR     off(00218h).0, purge_ect_check
                JBR     off(0021eh).4, purge_ect_check
                JBR     off(00219h).0, purge_result_clear

purge_ect_check:     CMPB    0d9h, #028h
                JGE     purge_delay_check
                CMPB    0d8h, #034h
                JGE     purge_delay_check
                JBS     off(0021dh).5, purge_delay_check
                CLRB    A
                JBS     off(002edh).5, purge_delay_store
                LB      A, #032h

purge_delay_store:     STB     A, off(002d5h)
                SJ      purge_counter_check

purge_delay_check:     LB      A, off(002d5h)
                JNE     purge_delay_flag

purge_delay_common:     SJ      purge_counter_check

purge_delay_flag:     JBS     off(002edh).4, purge_delay_common
                SJ      purge_result_clear


purge_counter_check:     CMP     (001dch-00180h)[USP], #005dch
                JLT     purge_result_clear
                CMPB    off(002b3h), #005h
                JNE     purge_result_set
                CMPB    off(002cbh), #019h
                JLT     purge_result_clear

purge_result_set:     SC
                SJ      purge_disable_check

purge_result_clear:     RC
                LCB     A, DisablePurge
                JNE     purge_result_set

purge_disable_check:     MB      r0.0, C
                LCB     A, PurgeInvert
                MB      C, r0.0
                JEQ     purge_invert_result
                XORB    PSWH, #080h

purge_invert_result:     MB      P0.1, C

gio_boost_override_check:     MOV     DP, #0040eh
; --- Boost PWM output GIO override (0x3F90-0x3FB7): if a GIO channel's computed output is
; active (off(0040eh).6), bstPWMOutput (real field) selects between forcing P4.3 (the boost
; PWM pin) or P0.5 (an alternate output) directly -- lets a GIO channel manually override the
; boost PWM output. Followed by a long chain of VSS-indexed threshold hysteresis checks
; (0x224 bits 0-5) -- likely feeding a speed-band/shift-point detector, not yet confirmed.
                MB      C, [DP].6
                JGE     gio_boost_disabled
                INC     DP
                MB      C, [DP].6
                MB      off(002eeh).2, C
                JBS     off(002eeh).3, gio_boost_p0_5_toggle
                LCB     A, bstPWMOutput
                JNE     vss_band_dispatch
                MB      P4.3, C
                SJ      vss_band_dispatch

gio_boost_p0_5_toggle:     XORB    PSWH, #080h
                MB      P0.5, C
                SJ      vss_band_dispatch

gio_boost_disabled:     RC
                MB      off(002eeh).2, C

vss_band_dispatch:     VCAL    3
                LB      A, #046h
                MOVB    r1, #046h
                JBS     off(00224h).0, vss_band_224_0
                LB      A, #053h
                MOVB    r1, #053h

vss_band_224_0:     JBS     off(00216h).3, vss_band_224_0_check
                LB      A, r1

vss_band_224_0_check:     CMPB    A, off(00236h)
                MB      off(00224h).0, C
                LB      A, #0a0h
                JBS     off(00224h).1, vss_band_224_1_check
                LB      A, #0b0h

vss_band_224_1_check:     CMPB    A, off(00236h)
                MB      off(00224h).1, C
                MOVB    r0, 0cch
                LB      A, #00dh
                JBS     off(00224h).2, vss_band_224_2_check
                LB      A, #00fh

vss_band_224_2_check:     CMPB    A, r0
                MB      off(00224h).2, C
                LB      A, #03dh
                JBS     off(00224h).3, vss_band_224_3_check
                LB      A, #040h

vss_band_224_3_check:     CMPB    A, r0
                MB      off(00224h).3, C
                LB      A, #046h
                JBS     off(00224h).4, vss_band_224_4_check
                LB      A, #04ah

vss_band_224_4_check:     CMPB    A, r0
                MB      off(00224h).4, C
                LB      A, #082h
                JBS     off(00224h).5, vss_band_224_5_check
                LB      A, #07ah

vss_band_224_5_check:     CMPB    0dfh, A
                MB      off(00224h).5, C
                LB      A, #02ah
                JBS     off(00224h).6, ect_threshold_224_6
                LB      A, #028h

ect_threshold_224_6:     CMPB    0d9h, A
                MB      off(00224h).6, C
                SB      PSWL.4
                JBR     off(00217h).6, state225_1_set
                JBS     off(00217h).4, state225_1_set
                JBR     off(00218h).7, state_dispatch2

state225_1_set:     SB      off(00225h).1
                J       state_result_clear5

state_dispatch2:     JBR     off(00224h).2, state_cce_set2b
                JBS     off(0021ch).2, state_dispatch3
                JBR     off(00216h).3, state_cce_set2b
                JBR     off(0021eh).1, state_cce_set2b

state_dispatch3:     JBR     off(00224h).0, state_cce_set2b
                JBS     off(00224h).4, state_cce_set2
                JBR     off(00224h).6, state_cce_set2
                JBS     off(00225h).0, state_cce_set2
                LB      A, off(002ceh)
                JNE     state_ccf_gate
                MOVB    off(002cfh), #002h

state_ccf_check:     RB      PSWL.4
                SJ      state_ccc_set9

state_cce_set2:     MOVB    off(002ceh), #002h

state_ccc_set9:     MOVB    off(002cch), #009h
                SJ      state_2ba_reset

state_cce_set2b:     MOVB    off(002ceh), #002h

state_ccf_gate:     LB      A, off(002cfh)
                JNE     state_ccf_check
                LB      A, off(002cch)
                JEQ     state_ccc_check
                JBR     off(00225h).0, state_dispatch4
                SJ      state_2ba_reset

state_ccc_check:     JBR     off(00224h).5, state_ccd_check
                MOVB    off(002cdh), #014h
                SB      off(00225h).0
                SJ      state_2ba_reset

state_ccd_check:     LB      A, off(002cdh)
                JNE     state_2ba_reset
                JBS     off(00224h).2, state_225_0_clear
                JBS     off(00225h).0, state_2ba_reset

state_225_0_clear:     RB      off(00225h).0

state_dispatch4:     JBS     off(00224h).3, state_225_1_check
                JBS     off(00224h).1, state_225_1_check
                CMPB    0d9h, #02dh
                JGE     state_225_1_check
                CMPB    0d8h, #0a9h
                JGE     state_225_1_check
                JBS     off(00211h).2, state_225_1_check
                LB      A, off(002bah)
                JEQ     state_225_1_check
                RB      off(00225h).1

state_result_set5:     SB      PSWL.5
                SJ      altc_gio_override_check

state_2ba_reset:     MOVB    off(002bah), #016h

state_225_1_check:     JBS     off(00225h).1, state_2d0_check
                SB      off(00225h).1
                MOVB    off(002d0h), #003h

state_2d0_check:     LB      A, off(002d0h)
                JNE     state_result_set5
                CMPB    off(00299h), #01eh
                JGT     state_result_set5

state_result_clear5:     RB      PSWL.5

altc_gio_override_check:     MOV     DP, #0040eh
; --- Alternator control (0x40B9-0x40EF): two GIO-overridable outputs on P0.3/P0.2, gated by
; DisableAltC (real field) and internal flags (PSWL.4/.5, set by the state machine above --
; possibly a charge-system fault condition, not confirmed). Drives what's likely alternator
; field/charge-relay control.
                MB      C, [DP].3
                JGE     altc_normal_drive
                INC     DP
                MB      C, [DP].3
                XORB    PSWH, #080h
                MB      P0.3, C
                SJ      altc_disable_check

altc_normal_drive:     MB      C, PSWL.4
                MB      P0.3, C

altc_disable_check:     LCB     A, DisableAltC
                JEQ     altc2_gio_override_check
                RB      PSWL.5

altc2_gio_override_check:     MOV     DP, #0040eh
                MB      C, [DP].7
                JGE     altc2_normal_drive
                INC     DP
                MB      C, [DP].7
                XORB    PSWH, #080h
                MB      P0.2, C
                SJ      altc_vcal3_call

altc2_normal_drive:     MB      C, PSWL.5
                MB      P0.2, C

altc_vcal3_call:     VCAL    3
                JBR     off(00219h).3, flags_b8_2_set
                JBR     off(00216h).6, flags_b8_2_set
                JBR     off(00217h).4, altc_condition_check

flags_b8_2_set:     SB      0b8h.2
                RB      0b3h.2
                SJ      gio_p1_2_check

altc_condition_check:     JBS     off(00215h).2, gio_p1_2_check
                JBS     off(00212h).5, gio_p1_2_check
                MB      C, 0b0h.1
                JLT     gio_p1_2_check
                CMPB    0d9h, #0c5h
                JGE     gio_p1_2_check
                CMPB    0dbh, #0a7h
                JLT     flags_219_2_store

gio_p1_2_check:     MOV     DP, #0040eh
                MB      C, [DP].2
                JLT     flags_219_2_common
                SB      P1.2

flags_219_2_common:     RC

flags_219_2_store:     MB      off(00219h).2, C
                VCAL    3
                JBS     off(0021ah).6, state_21a_7_dispatch
                CMPB    0c5h, #012h
                JGE     state_2fb_reset
                LB      A, 0d7h
                CMPB    A, #0ffh
                JGT     state_2fb_reset
                CMPB    A, #000h
                JLT     state_2fb_reset
                MB      C, P4.6
                JGE     state_2fb_check

state_2fb_reset:     MOVB    off(002fbh), #000h
                SJ      state_21a_7_dispatch

state_2fb_check:     LB      A, off(002fbh)
                JNE     state_21a_7_dispatch
                SB      off(0021ah).6

state_21a_7_dispatch:     JBS     off(0021ah).7, state_21a_7_dispatch3
                JBS     off(00217h).5, state_213_0_check
                JBS     off(0021ah).6, state_224_7_check

state_213_0_check:     JBS     off(00213h).0, state_21a_7_set

state_2dd_reset:     MOVB    off(002ddh), #000h
                SJ      state_21a_7_dispatch3

state_224_7_check:     JBR     off(00224h).7, state_2dd_reset
                JBS     off(0021dh).4, state_2dd_reset
                LB      A, off(002ddh)
                JNE     state_21a_7_dispatch3

state_21a_7_set:     SB      off(0021ah).7

state_21a_7_dispatch3:     JBS     off(0021ah).7, state_21a_7_dispatch2
                JBR     off(0021ah).6, state_2de_reset
                JBS     off(00217h).5, state_2de_reset
                JBS     off(00215h).1, altc_p46_check
                MB      C, 0b3h.1
                JGE     state_2de_reset

altc_p46_check:     MB      C, P4.6
                JGE     state_2de_reset
                JBS     off(00218h).0, state_2de_check
                JBS     off(0021eh).2, state_2de_reset

state_2de_check:     LB      A, off(002deh)
                JNE     state_21a_7_dispatch2
                SB      off(0021ah).7
                SJ      state_21a_7_dispatch2

state_2de_reset:     MOVB    off(002deh), #000h

state_21a_7_dispatch2:     JBS     off(0021ah).7, tbl_6baf_search
                JBR     off(0021ah).6, state_2df_reset
                JBS     off(00217h).5, state_2df_reset
                LB      A, 0d7h
                CMPB    A, #0ffh
                JGT     state_2df_reset
                CMPB    A, #000h
                JLT     state_2df_reset
                JBR     off(00215h).0, state_2df_reset
                JBS     off(00218h).0, state_dc_check2
                JBS     off(0021eh).2, state_2df_reset

state_dc_check2:     CMPB    A, #0ffh
                JGT     state_2df_check

state_2df_reset:     MOVB    off(002dfh), #000h
                SJ      tbl_6baf_search

state_2df_check:     LB      A, off(002dfh)
                JNE     tbl_6baf_search
                SB      off(0021ah).7

tbl_6baf_search:     MOVB    r0, #004h
                MOV     DP, #tbl_map_sign
                LB      A, 0d9h

tbl_6baf_loop:     DEC     DP
                DECB    r0
                JEQ     tbl_6baf_done
                CMPCB   A, [DP]
                JGE     tbl_6baf_loop

tbl_6baf_done:     L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, off(00233h)
                ANDB    A, #0fch
                ORB     A, r0
                STB     A, off(00233h)
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                CMPB    0d8h, #023h
                MB      off(00233h).2, C
                VCAL    3
                LB      A, #07fh
                CMPB    A, #0ffh
                JGT     knock_244_recheck
                CMPB    A, #0fch
                JGE     knock_324_bit_check

knock_244_recheck:     SC
                JBS     off(00230h).6, knock_324_bit_store

knock_324_bit_check:     MB      C, off(00214h).7

knock_324_bit_store:     MOV     DP, #00324h
                MB      [DP].0, C
                LB      A, [DP]
                ANDB    A, #0f1h
                STB     A, [DP]
                L       A, ADCR6
                ST      A, 0bah
                LCB     A, CustomTPS
                MB      C, ACC.0
                LB      A, ADCR7H
                JGE     tps2_adc_store
                MOV     X1, #TPSSettings
                VCAL    1

tps2_adc_store:     MOV     DP, #003a4h
; --- Second TPS reading path (0x420B onward): CustomTPS/TPSSettings (same real fields as the
; main TPS linearization, VCAL 1) applied to a second ADC channel (ADCR7H/ADCR2H) -- likely a
; redundant/sub-TPS sensor input. Followed by a digital-input bit-packing routine (0x4225-
; 0x4270ish, ROLB chain gathering ~16 discrete flag bits from 0x210/0x211/0x21C/0x21F into
; two bytes at 0x3B0) -- likely a snapshot for diagnostic/serial reporting.
                STB     A, [DP]
                LB      A, ADCR2H
                MOV     DP, #003a5h
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, off(00210h).3
                XORB    PSWH, #080h
                ROLB    A
                MB      C, off(00210h).5
                ROLB    A
                MB      C, off(00210h).7
                ROLB    A
                MB      C, off(00211h).0
                ROLB    A
                MB      C, off(00211h).1
                ROLB    A
                MB      C, off(00211h).2
                ROLB    A
                MB      C, off(00211h).4
                ROLB    A
                MB      C, off(00211h).5
                ROLB    A
                MOV     DP, #003b0h
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, off(00211h).6
                ROLB    A
                MB      C, off(00211h).7
                ROLB    A
                MB      C, off(0021ch).5
                ROLB    A
                MB      C, off(0021ch).4
                ROLB    A
                MB      C, off(0021fh).1
                ROLB    A
                MOV     DP, #000e6h
                MB      C, [DP].0
                ROLB    A
                MB      C, off(00221h).6
                ROLB    A
                MOV     DP, #0012ch
                MB      C, [DP].4
                ROLB    A
                MOV     DP, #003b1h
                STB     A, [DP]
                RC
                CLRB    A
; --- Comprehensive I/O state snapshot for diagnostics (0x4278-0x42D2): bit-packs the state
; of every P0/P1/P4 discrete output and input pin into 3 bytes at 0x3B1-0x3B3, following the
; same pattern as the earlier discrete-input packing at 0x4225. Then diag_snapshot_copy_loop
; copies a calibration data block (tbl_diag_snapshot_data1-tbl_diag_snapshot_data2) into a RAM buffer at 0x3A8 -- overall
; this reads as building a full status/calibration snapshot, likely for K-line diagnostic
; serial reporting to a scan tool.
                MB      C, P0.0
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.1
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.2
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.3
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.4
                XORB    PSWH, #080h
                ROLB    A
                MB      C, off(002eeh).2
                ROLB    A
                MB      C, P0.6
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.7
                XORB    PSWH, #080h
                ROLB    A
                MOV     DP, #003b2h
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, P1.0
                ROLB    A
                MB      C, P1.2
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P1.4
                ROLB    A
                MB      C, P4.6
                XORB    PSWH, #080h
                ROLB    A
                RC
                ROLB    A
                ROLB    A
                ROLB    A
                ROLB    A
                MOV     DP, #003b3h
                STB     A, [DP]
                MOV     X1, #tbl_diag_snapshot_data1
                MOV     DP, #003a8h

diag_snapshot_copy_loop:     LCB     A, [X1]
                MOVB    [DP], A
                INC     X1
                INC     DP
                CMP     X1, #tbl_diag_snapshot_data2
                JNE     diag_snapshot_copy_loop
                MOVB    r0, #040h
                JBR     off(00219h).3, diag_mode_code_store
                MOVB    r0, #001h
                JBS     off(00216h).2, diag_mode_code_store
                MOVB    r0, #002h
                JBR     off(002eeh).3, diag_mode_code_store
                MOVB    r0, #004h

diag_mode_code_store:     MOV     DP, #003abh
                LB      A, r0
                STB     A, [DP]
                CLRB    r0
                RC
                ROLB    r0
                ROLB    r0
                ROLB    r0
                MB      C, off(00216h).5
                ROLB    r0
                ROLB    r0
                MB      C, off(00217h).6
                ROLB    r0
                ROLB    r0
                MB      C, off(00216h).3
                ROLB    r0
                MOV     DP, #003ach
                LB      A, r0
                STB     A, [DP]
                L       A, off(0025eh)
                SLL     A
                JLT     diag_clamp_ff
                SLL     A
                JGE     diag_clamp_acch

diag_clamp_ff:     LB      A, #0ffh
                SJ      diag_store_3ad

diag_clamp_acch:     LB      A, ACCH

diag_store_3ad:     MOV     DP, #003adh
                STB     A, [DP]
                MOV     DP, #0030ch
                L       A, [DP]
                SLL     A
                JLT     diag_clamp_ff2
                SLL     A
                JGE     diag_clamp_acch2

diag_clamp_ff2:     LB      A, #0ffh
                SJ      diag_store_3ae

diag_clamp_acch2:     LB      A, ACCH

diag_store_3ae:     MOV     DP, #003aeh
                STB     A, [DP]
                LB      A, 0cch
                JBR     off(00214h).0, diag_store_39f
                CLRB    A

diag_store_39f:     MOV     DP, #0039fh
                STB     A, [DP]
                MOV     DP, #003afh
                LB      A, [DP]
                CMPB    A, #033h
                JEQ     diag_3af_range_check
                CMPB    A, #034h
                JEQ     diag_3af_range_check
                CMPB    A, #035h
                JEQ     diag_3af_range_check
                CMPB    A, #036h
                JNE     diag_3af_no_match

diag_3af_range_check:     SC
                SJ      diag_3af_flag_store

diag_3af_no_match:     RC

diag_3af_flag_store:     MB      off(00219h).7, C
                VCAL    3
                MOV     er1, 0b0h
                MOV     er2, 0b2h
                JBR     off(00217h).5, diag_mask_gate
                AND     er1, #0c5e2h
                AND     0b0h, #0c5e2h
                AND     er2, #0040bh
                AND     0b2h, #0040bh

diag_mask_gate:     MB      C, sysFlags_b7.1
                JGE     dtc_scan_init
                CLR     A
                ST      A, 0b0h
                ST      A, 0b2h
                ST      A, er1
                ST      A, er2

dtc_scan_init:     MOVB    r7, #001h
; --- Diagnostic trouble code (DTC) bit scanner (0x438F-0x4426ish): scans a 28-bit status
; field (0xB0/0xB2/er1/er2, masked/zeroed by diag_mask_gate depending on off(00217h).5 and
; sysFlags_b7.1) bit-by-bit via dtc_scan_loop, tracking the position of the lowest set bit
; (r7) as the "active" DTC index into off(002b3h), with a separate counter at 0xF4. Found
; index feeds a lookup into tbl_dtc_code_map -- likely mapping bit position to an actual DTC number.
                MOV     DP, #002cbh

dtc_scan_loop:     SRL     er2
                ROR     er1
                JLT     dtc_scan_found_check
                LB      A, r7
                SUBB    A, off(002b3h)
                JNE     dtc_scan_f4_check
                STB     A, off(002b3h)
                STB     A, [DP]

dtc_scan_f4_check:     LB      A, r7
                SUBB    A, 0f4h
                JNE     dtc_scan_advance
                STB     A, 0f4h


dtc_scan_advance:     INCB    r7
                CMPB    r7, #01ch
                JNE     dtc_scan_loop
                SJ      dtc_debounce_init

dtc_scan_found_check:     LB      A, off(002b3h)
                JEQ     dtc_scan_new_code
                CMPB    A, r7
                JNE     dtc_scan_advance
                LB      A, [DP]
                JNE     dtc_debounce_init
                SJ      dtc_debounce2_init

dtc_scan_new_code:     CLR     A
                LB      A, r7
                STB     A, off(002b3h)
                LCB     A, tbl_dtc_code_map[ACC]
                STB     A, [DP]

dtc_debounce_init:     VCAL    3
; --- DTC debounce/persistence tracking (0x43C8-0x4432ish): maintains a per-fault debounce
; countdown array at 0x1D1 (44 entries, dtc_debounce_loop) and a second array at 0x1DC (16
; more entries with a fixed 0xBB3 sentinel when active) -- each potential fault condition gets
; its own countdown before being confirmed/latched, rather than triggering on a single sample.
; Feeds the same 0xF4 "active DTC index" tracked by the bit-scanner above.
                MOVB    r7, #021h
                CLR     A
                XCHG    A, 0b4h
                JBS     off(0021ch).6, dtc_debounce_mask_apply
                AND     A, #081ffh

dtc_debounce_mask_apply:     ST      A, er0
                MB      C, sysFlags_b7.1
                JGE     dtc_debounce_loop_start
                CLR     er0

dtc_debounce_loop_start:     MOV     DP, #001d1h

dtc_debounce_loop:     SRL     er0
                JGE     dtc_debounce_check_active
                LB      A, [DP]
                JEQ     dtc_debounce2_init
                DECB    [DP]
                SJ      dtc_debounce_advance

dtc_debounce_check_active:     CLR     A
                LB      A, r7
                CMPB    A, 0f4h
                JNE     dtc_debounce_advance
                LCB     A, tbl_dtc_code_map[ACC]
                SUBB    A, [DP]
                JNE     dtc_debounce_advance
                STB     A, 0f4h

dtc_debounce_advance:     INC     DP
                INCB    r7
                CMPB    r7, #02ch
                JNE     dtc_debounce_loop
                MOVB    r7, #030h
                MOV     DP, #001dch
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                JLT     dtc_debounce2_check
                MOV     [DP], #00bb3h
                LB      A, 0f4h
                SUBB    A, r7
                JNE     dtc_debounce2_next
                STB     A, 0f4h

dtc_debounce2_next:     J       calchecksum_gate

dtc_debounce2_check:     L       A, [DP]
                JNE     dtc_debounce2_next

dtc_debounce2_init:     LB      A, #005h
                STB     A, [DP]
                LB      A, 0f4h
                JNE     dtc_active_confirm
                LB      A, r7
                STB     A, 0f4h
                SJ      calchecksum_gate

dtc_active_confirm:     SUBB    A, r7
                JNE     calchecksum_gate
                STB     A, 0f4h
                JBR     off(0022dh).0, cfgvariant_apply_gate
                JBS     off(00221h).6, cfgvariant_apply_gate
                MOV     DP, #0031dh
                CMPB    r7, #005h
                JEQ     cfgvariant_apply_flag_a
                CMPB    r7, #030h
                JNE     cfgvariant_apply_gate
                SB      off(002eeh).4
                MB      C, [DP].1
                SJ      cfgvariant_apply_check

cfgvariant_apply_flag_a:     SB      off(002edh).3
                MB      C, [DP].0

cfgvariant_apply_check:     JGE     calchecksum_gate
                JBR     off(002edh).1, calchecksum_gate

cfgvariant_apply_gate:     AND     IE, #00080h
; --- CONFIG VARIANT APPLICATION (0x445B-0x4507): connects directly to the config/variant
; validation block identified at the very start of this session (boot-time cfgvariant_*
; labels, tbl_cfgvariant_max/tbl_cfgvariant_map). Here, when the fault-scan index (r7) matches a specific variant
; via tbl_cfgvariant_map, calls cfgvariant_set_flags/cfgvariant_eval_condition/cfgvariant_snapshot_capture/cfgvariant_checksum2_calc -- almost certainly the
; actual "apply this configuration variant's parameters" routines, invoked from within the
; DTC/fault-scan cycle rather than only at boot. This is the concrete implementation behind
; the config-variant mechanism only partially traced earlier.
                CLR     A
                LB      A, r7
                CMPB    A, #030h
                JNE     cfgvariant_index_lookup2
                MOV     (001dch-00180h)[USP], #00bb3h
                JBS     off(002eeh).3, cfgvariant_index_lookup2
                SB      0b8h.5
                SJ      dtc_scan_ie_restore

cfgvariant_index_lookup2:     LCB     A, tbl_cfgvariant_map[ACC]
                JEQ     dtc_scan_ie_restore
                STB     A, r6
                SB      off(00232h).4
                SB      off(00232h).5
                CAL     cfgvariant_set_flags
                CMPB    r6, #018h
                JEQ     cfgvariant_apply_done
                CAL     cfgvariant_eval_condition
                CAL     cfgvariant_snapshot_capture
                CAL     cfgvariant_checksum2_calc
                INC     DP
                L       A, er0
                ST      A, [DP]

cfgvariant_apply_done:     RB      off(00232h).4
                RB      off(00232h).5
                CLR     A
                LB      A, r7
                LCB     A, tbl_cfgvariant_map[ACC]
                CMPB    A, r6
                JNE     selftest_fail_043_checksum


dtc_scan_ie_restore:     L       A, 0f8h
                ST      A, IE

calchecksum_gate:     MOV     DP, #0031dh
                JBS     off(0022dh).0, calchecksum_init
                RB      off(002edh).3
                RB      off(002eeh).4
                CLRB    [DP]

calchecksum_init:     MOVB    r0, [DP]
                MOVB    r1, r0
                MOV     DP, #00322h
                MOV     X1, #0011eh

calchecksum_loop:     DEC     DP
                DEC     X1
                LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                LB      A, 00000h[X1]
                STB     A, r2
                LB      A, [DP]
                XORB    A, r2
                ANDB    A, r2
                JNE     selftest_fail_043_checksum
                CMP     DP, #0031eh
                JNE     calchecksum_loop
                DEC     DP
                LB      A, [DP]
                ANDB    A, #0fch
                JNE     selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #002h
                JNE     selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #008h
                JNE     selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #006h
                JNE     selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #088h
                JNE     selftest_fail_043_checksum
                INC     DP
                L       A, [DP]
                CMP     A, er0
                JNE     selftest_fail_043_checksum
                VCAL    3
                CAL     cfgvariant_checksum2_calc
                INC     DP
                L       A, [DP]
                CMP     A, er0
                JEQ     freezeframe_decode_start

selftest_fail_043_checksum:     MOVB    trapReasonCode, #043h
                BRK

freezeframe_decode_start:     VCAL    3
; --- Freeze-frame condition decoder (0x450C onward): decodes a captured status snapshot
; (0x212/0x214) against several bit-pattern masks to derive individual boolean conditions
; (stored to 0x218.6/.7, 0x22B.4, 0x225.7, etc) -- e.g. "was AC on", "was idle" at the time a
; fault occurred. Classic diagnostic freeze-frame behavior, consistent with the DTC scanning/
; debounce system traced just above.
                SC
                JBS     off(002edh).3, freezeframe_flag_218_7
                JBS     off(002eeh).4, freezeframe_flag_218_7
                L       A, off(00212h)
                ORB     A, off(00214h)
                ADD     A, #0ffffh


freezeframe_flag_218_7:     MB      off(00218h).7, C
                JLT     freezeframe_flag_218_6
                ANDB    off(00218h), #0bfh
                ANDB    off(0022bh), #0efh
                ANDB    off(00225h), #07fh
                ANDB    off(002ech), #0fbh
                SJ      prep_lowpower_seq

freezeframe_flag_218_6:     L       A, off(00212h)
                AND     A, #0fffdh
                JNE     freezeframe_flag_22b_4
                L       A, off(00214h)
                AND     A, #014f5h
                JNE     freezeframe_flag_22b_4
                RC

freezeframe_flag_22b_4:     MB      off(00218h).6, C
                SC
                L       A, off(00212h)
                AND     A, #02054h
                JNE     freezeframe_flag_225_7
                JBS     off(00214h).0, freezeframe_flag_225_7
                RC

freezeframe_flag_225_7:     MB      off(0022bh).4, C
                SC
                JBS     off(002edh).3, freezeframe_flag_next
                JBS     off(002eeh).4, freezeframe_flag_next
                L       A, off(00212h)
                JNE     freezeframe_flag_next
                L       A, off(00214h)
                AND     A, #014fdh
                JNE     freezeframe_flag_next
                RC

freezeframe_flag_next:     MB      off(00225h).7, C
                SC
                JBS     off(002edh).3, freezeframe_flag_common
                JBS     off(002eeh).4, freezeframe_flag_common
                L       A, off(00212h)
                JNE     freezeframe_flag_common
                L       A, off(00214h)
                AND     A, #074f5h          
                JNE     freezeframe_flag_common
                RC

freezeframe_flag_common:     MB      off(002ech).2, C

prep_lowpower_seq:     SB      off(00230h).3
; a standby/low-power preparation sequence (watchdog reset, TMR1 reload/divide, port_debounce_
; helper, then reconfigures IE/0xF8/0xFA -- structurally similar to int_NMI's low-power entry
; sequence from very early this session), then lowpower_trap_gate's JBR always falls through
; (target lowpower_trap_call is the very next instruction) into lowpower_trap_call
; (J lowpower_abort_cond_scan) -- the unconditional jump into the restored low-power-entry
; veto/validation gate (see its header comment for what it does).
                JNE     lowpower_trap_gate
                CAL     ResetWatchDog
                L       A, TM1
                ADD     A, #00a00h
                ST      A, TMR1
                MULB
                DIV
                DIV
                MB      C, sysFlags_b7.1
                JLT     prep_lowpower_ie_config
                CAL     port_debounce_helper
                MOVB    0f7h, #020h

prep_lowpower_ie_config:     MOV     0fah, #002a0h
                L       A, #02bafh
                ST      A, 0f8h
                CLRB    TRNSIT
                CLR     IRQ
                RB      TCON0.2
                ST      A, IE

lowpower_trap_gate:     JBR     off(00217h).4, lowpower_trap_call

lowpower_trap_call:     J       lowpower_abort_cond_scan

crank_helper2:     JBR     off(00128h).2, injtimer_shift_path ; 45BB 1 108 280 DA283B

injector_timer_schedule:     MOVB    r0, #0ffh              ; 45BE 1 108 280 98FF
                L       A, off(0019eh)         ; 45C0 1 108 280 E49E
                ST      A, er1                 ; 45C2 1 108 280 89
                CMPB    off(00117h), #00fh     ; 45C3 1 108 280 C417C00F
                JNE     injtimer_schedule_done             ; 45C7 1 108 280 CE6C
                L       A, TM0                 ; 45C9 1 108 280 E530
                SUB     A, #00001h             ; 45CB 1 108 280 A60100
                ST      A, TMR0                ; 45CE 1 108 280 D532
                MOV     X1, #00110h            ; 45D0 1 108 280 601001
                MOV     DP, #00198h            ; 45D3 1 108 280 629801
                L       A, [DP]                ; 45D6 1 108 280 E2
                CMP     A, #000c0h             ; 45D7 1 108 280 C6C000
                JGE     injtimer_bank1_check2             ; 45DA 1 108 280 CD3B
                CLR     A                      ; 45DC 1 108 280 F9
                ST      A, [DP]                ; 45DD 1 108 280 D2
                INC     DP                     ; 45DE 1 108 280 72
                INC     DP                     ; 45DF 1 108 280 72
                L       A, [DP]                ; 45E0 1 108 280 E2
                CMP     A, #000c0h             ; 45E1 1 108 280 C6C000
                JGE     injtimer_bank2_zero             ; 45E4 1 108 280 CD20
                CLR     A                      ; 45E6 1 108 280 F9
                ST      A, [DP]                ; 45E7 1 108 280 D2
                INC     DP                     ; 45E8 1 108 280 72
                INC     DP                     ; 45E9 1 108 280 72
                L       A, [DP]                ; 45EA 1 108 280 E2
                CMP     A, #000c0h             ; 45EB 1 108 280 C6C000
                JLT     injtimer_bank3_check             ; 45EE 1 108 280 CA23
                ST      A, er1                 ; 45F0 1 108 280 89
                LB      A, off(00116h)         ; 45F1 0 108 280 F416
                SRLB    A                      ; 45F3 0 108 280 63
                RORB    off(00116h)            ; 45F4 0 108 280 C416C7
                SJ      injtimer_schedule_common             ; 45F7 0 108 280 CB36

injtimer_shift_path:     LB      A, off(00196h)         ; 45F9 0 108 280 F496
                SLLB    A                      ; 45FB 0 108 280 53
                ROLB    off(00196h)            ; 45FC 0 108 280 C496B7
                LB      A, off(00116h)         ; 45FF 0 108 280 F416
                SLLB    A                      ; 4601 0 108 280 53
                ROLB    off(00116h)            ; 4602 0 108 280 C416B7
                RT                             ; 4605 0 108 280 01

injtimer_bank2_zero:     ST      A, er1                 ; 4606 1 108 280 89
                LB      A, off(00116h)         ; 4607 0 108 280 F416
                SRLB    A                      ; 4609 0 108 280 63
                RORB    off(00116h)            ; 460A 0 108 280 C416C7
                SRLB    A                      ; 460D 0 108 280 63
                RORB    off(00116h)            ; 460E 0 108 280 C416C7
                SJ      injtimer_bank_mask_calc             ; 4611 0 108 280 CB14

injtimer_bank3_check:     CLR     A                      ; 4613 1 108 280 F9
                ST      A, [DP]                ; 4614 1 108 280 D2
                SJ      injtimer_schedule_done             ; 4615 1 108 280 CB1E

injtimer_bank1_check2:     ST      A, er1                 ; 4617 1 108 280 89
                LB      A, off(00116h)         ; 4618 0 108 280 F416
                SLLB    A                      ; 461A 0 108 280 53
                ROLB    off(00116h)            ; 461B 0 108 280 C416B7
                CAL     inj_wrap_clamp_calc             ; 461E 0 108 280 325F47
                LB      A, off(00196h)         ; 4621 0 108 280 F496
                SRLB    A                      ; 4623 0 108 280 63
                SRLB    A                      ; 4624 0 108 280 63
                ANDB    r0, A                  ; 4625 0 108 280 20D1

injtimer_bank_mask_calc:     CAL     inj_wrap_clamp_calc             ; 4627 0 108 280 325F47
                LB      A, off(00196h)         ; 462A 0 108 280 F496
                SRLB    A                      ; 462C 0 108 280 63
                ANDB    r0, A                  ; 462D 0 108 280 20D1

injtimer_schedule_common:     CAL     inj_wrap_clamp_calc             ; 462F 0 108 280 325F47
                ANDB    r0, off(00196h)        ; 4632 0 108 280 20D396


injtimer_schedule_done:     LB      A, off(00196h)         ; 4635 0 108 280 F496
                SLLB    A                      ; 4637 0 108 280 53
                ROLB    off(00196h)            ; 4638 0 108 280 C496B7
                LB      A, r0                  ; 463B 0 108 280 78
                ANDB    A, off(00196h)         ; 463C 0 108 280 D796
                CMP     off(0019eh), #000c0h   ; 463E 0 108 280 B49EC0C000
                JLT     injenable_reset_all             ; 4643 0 108 280 CA40
                MOVB    r1, off(00117h)        ; 4645 0 108 280 C41749
                ANDB    off(00117h), A         ; 4648 0 108 280 C417D1
                JBS     off(0012ah).7, injenable_p2_update ; 464B 0 108 280 EF2A0A
                JBS     off(00124h).5, injenable_p2_update ; 464E 0 108 280 ED2407
                ANDB    off(00197h), A         ; 4651 0 108 280 C497D1
                ORB     off(0012ah), #001h     ; 4654 0 108 280 C42AE001


injenable_p2_update:     LB      A, off(00197h)         ; 4658 0 108 280 F497
; --- Sequential injector enable/scheduling: P2 output port bits act as per-injector enable
; signals (confirmed: same port/RAM shadow (0x197) driven by the int_timer_0_match injector
; bank-stagger ISR above), rotated via off(00196h)/(00117h) shift chains and scheduled
; against TM0/TMR0 hardware timer -- this is the sequential-injection firing-order scheduler.
                ORB     A, #0f0h               ; 465A 0 108 280 E6F0
                ANDB    P2, A                  ; 465C 0 108 280 C524D1
                ANDB    TRNSIT, #0fbh          ; 465F 0 108 280 C546D0FB
                ANDB    PSWH, #0feh            ; 4663 0 108 280 A2D0FE
                ORB     TCON0, #004h           ; 4666 0 108 280 C540E004
                L       A, TM0                 ; 466A 1 108 280 E530
                ORB     PSWH, #001h            ; 466C 1 108 280 A2E001
                ANDB    TCON0, #0fbh           ; 466F 1 108 280 C540D0FB
                CMPB    r1, #00fh              ; 4673 1 108 280 21C00F
                JEQ     inj_accum2_direct             ; 4676 1 108 280 C92B
                SUB     A, TMR0                ; 4678 1 108 280 B532A2
                ADD     A, er1                 ; 467B 1 108 280 09
                JBR     off(00109h).0, inj_accum_check1 ; 467C 1 108 280 D80929
                JBR     off(00109h).2, inj_accum_check2 ; 467F 1 108 280 DA0929
                SJ       inj_accum_check4             ; 4682 1 108 280 03EA46

injenable_reset_all:     LB      A, #00fh               ; 4685 0 108 280 770F
                STB     A, off(00117h)         ; 4687 0 108 280 D417
                STB     A, off(00197h)         ; 4689 0 108 280 D497
                ORB     P2, A                  ; 468B 0 108 280 C524E1
                SB      TCON0.2                ; 468E 0 108 280 C5401A
                LB      A, off(00196h)         ; 4691 0 108 280 F496
                XORB    A, #0ffh               ; 4693 0 108 280 F6FF
                MB      C, ACC.7               ; 4695 0 108 280 C5062F
                ROLB    A                      ; 4698 0 108 280 33
                STB     A, off(00116h)         ; 4699 0 108 280 D416
                RB      TCON0.2                ; 469B 0 108 280 C5400A
                L       A, #00001h             ; 469E 1 108 280 670100
                SJ      inj_accum1_store_new             ; 46A1 1 108 280 CB4F

inj_accum2_direct:     ADD     A, er1                 ; 46A3 1 108 280 09
; --- Dual-accumulator injector timing calc (0x46A3-0x4723ish): manages two 16-bit
; accumulators (0x110/0x112, capped/wrapped at 0x100) feeding TMR0 reschedule -- likely
; timing for two injector groups/banks. No calibration anchors; named at the mechanism level.
                ST      A, TMR0                ; 46A4 1 108 280 D532
                SJ      inj_p2_calc_start             ; 46A6 1 108 280 CB7D

inj_accum_check1:     JBR     off(00109h).2, inj_accum_dispatch ; 46A8 1 108 280 DA0906

inj_accum_check2:     JBS     off(00109h).3, inj_accum_check5 ; 46AB 1 108 280 EB095C
                JBS     off(00109h).1, inj_accum_dispatch2 ; 46AE 1 108 280 E9095C

inj_accum_dispatch:     JGE     inj_accum_direct_add             ; 46B1 1 108 280 CD2C
                SUB     A, off(00110h)         ; 46B3 1 108 280 A710
                JLT     inj_accum1_add             ; 46B5 1 108 280 CA11
                SUB     A, off(00112h)         ; 46B7 1 108 280 A712
                JGE     inj_accum_check3             ; 46B9 1 108 280 CD1C
                ADD     A, off(00112h)         ; 46BB 1 108 280 8712
                CMP     A, #00100h             ; 46BD 1 108 280 C60001
                JLT     inj_accum2_zero             ; 46C0 1 108 280 CA0F
                ST      A, off(00112h)         ; 46C2 1 108 280 D412
                CLR     A                      ; 46C4 1 108 280 F9
                SJ       inj_accum_store_114             ; 46C5 1 108 280 032347

inj_accum1_add:     ADD     A, off(00110h)         ; 46C8 1 108 280 8710
                CMP     A, #00100h             ; 46CA 1 108 280 C60001
                JLT     inj_accum_both_zero             ; 46CD 1 108 280 CA13
                ST      A, off(00110h)         ; 46CF 1 108 280 D410

inj_accum2_zero:     CLR     A                      ; 46D1 1 108 280 F9
                ST      A, off(00112h)         ; 46D2 1 108 280 D412
                SJ       inj_accum_store_114             ; 46D4 1 108 280 032347

inj_accum_check3:     CMP     A, #00100h             ; 46D7 1 108 280 C60001
                JGE     inj_accum_store_114             ; 46DA 1 108 280 CD47
                CLR     A                      ; 46DC 1 108 280 F9
                SJ      inj_accum_store_114             ; 46DD 1 108 280 CB44

inj_accum_direct_add:     ADD     TMR0, A                ; 46DF 1 108 280 B53281

inj_accum_both_zero:     CLR     A                      ; 46E2 1 108 280 F9
                ST      A, off(00110h)         ; 46E3 1 108 280 D410
                ST      A, off(00112h)         ; 46E5 1 108 280 D412
                SJ       inj_accum_store_114             ; 46E7 1 108 280 032347


inj_accum_check4:     JGE     inj_accum_direct_add2             ; 46EA 1 108 280 CD10
                CMP     A, #00100h             ; 46EC 1 108 280 C60001
                JGE     inj_accum1_store_new             ; 46EF 1 108 280 CD01
                CLR     A                      ; 46F1 1 108 280 F9


inj_accum1_store_new:     ST      A, off(00110h)         ; 46F2 1 108 280 D410
                L       A, #00001h             ; 46F4 1 108 280 670100
                ST      A, off(00112h)         ; 46F7 1 108 280 D412
                SJ       inj_accum_store_114             ; 46F9 1 108 280 032347

inj_accum_direct_add2:     ADD     TMR0, A                ; 46FC 1 108 280 B53281
                CLR     A                      ; 46FF 1 108 280 F9
                SJ      inj_accum1_store_new    ; same four instructions as there

inj_accum_check5:     JBS     off(00109h).1, inj_accum_check4 ; 470A 1 108 280 E909DD

inj_accum_dispatch2:     JGE     inj_accum_direct_add3             ; 470D 1 108 280 CD4B
                SUB     A, off(00110h)         ; 470F 1 108 280 A710
                JGE     inj_accum1_wrap_check             ; 4711 1 108 280 CD40
                ADD     A, off(00110h)         ; 4713 1 108 280 8710
                CMP     A, #00100h             ; 4715 1 108 280 C60001
                JGE     inj_accum1_store2             ; 4718 1 108 280 CD01

inj_accum1_zero2:     CLR     A                      ; 471A 1 108 280 F9

inj_accum1_store2:     ST      A, off(00110h)         ; 471B 1 108 280 D410

inj_accum2_zero2:     CLR     A                      ; 471D 1 108 280 F9

inj_accum2_store2:     ST      A, off(00112h)         ; 471E 1 108 280 D412
                L       A, #00001h             ; 4720 1 108 280 670100

inj_accum_store_114:     ST      A, off(00114h)         ; 4723 1 108 280 D414

inj_p2_calc_start:     L       A, off(00110h)         ; 4725 1 108 280 E410
                JNE     inj_p2_calc_alt             ; 4727 1 108 280 CE0E
                L       A, off(00112h)         ; 4729 1 108 280 E412
                JEQ     inj_p2_calc_check114             ; 472B 1 108 280 C90E
                LB      A, off(00116h)         ; 472D 0 108 280 F416
                SRLB    A                      ; 472F 0 108 280 63
                SRLB    A                      ; 4730 0 108 280 63
                SRLB    A                      ; 4731 0 108 280 63
                ORB     A, off(00116h)         ; 4732 0 108 280 E716
                SJ       inj_p2_calc_or197             ; 4734 0 108 280 034447

inj_p2_calc_alt:     LB      A, off(00116h)         ; 4737 0 108 280 F416
                SJ      inj_p2_calc_or197             ; 4739 0 108 280 CB09

inj_p2_calc_check114:     L       A, off(00114h)         ; 473B 1 108 280 E414
                JEQ     inj_p2_default_f             ; 473D 1 108 280 C910
                LB      A, off(00116h)         ; 473F 0 108 280 F416
                RORB    A                      ; 4741 0 108 280 43
                XORB    A, #0ffh               ; 4742 0 108 280 F6FF

inj_p2_calc_or197:     ORB     A, off(00197h)         ; 4744 0 108 280 E797
                ANDB    A, #00fh               ; 4746 0 108 280 D60F

inj_p2_drive_return:     ORB     P2, A                  ; 4748 0 108 280 C524E1
                RB      off(0012ah).7          ; 474B 0 108 280 C42A0F
                RT                             ; 474E 0 108 280 01

inj_p2_default_f:     LB      A, #00fh               ; 474F 0 108 280 770F
                SJ      inj_p2_drive_return             ; 4751 0 108 280 CBF5

inj_accum1_wrap_check:     CMP     A, #00100h             ; 4753 1 108 280 C60001
                JLT     inj_accum2_zero2             ; 4756 1 108 280 CAC5
                SJ      inj_accum2_store2             ; 4758 1 108 280 CBC4

inj_accum_direct_add3:     ADD     TMR0, A                ; 475A 1 108 280 B53281
                SJ      inj_accum1_zero2             ; 475D 1 108 280 CBBB

inj_wrap_clamp_calc:     CLR     A                      ; 475F 1 108 280 F9
                XCHG    A, [DP]                ; 4760 1 108 280 B210
                MOV     X2, A                  ; 4762 1 108 280 51
                INC     DP                     ; 4763 1 108 280 72
                INC     DP                     ; 4764 1 108 280 72
                L       A, [DP]                ; 4765 1 108 280 E2
                SUB     A, X2                  ; 4766 1 108 280 91A2
                JLT     inj_wrap_clamp_zero             ; 4768 1 108 280 CA05
                CMP     A, #00100h             ; 476A 1 108 280 C60001
                JGE     inj_wrap_clamp_store             ; 476D 1 108 280 CD01

inj_wrap_clamp_zero:     CLR     A                      ; 476F 1 108 280 F9

inj_wrap_clamp_store:     ST      A, 00000h[X1]          ; 4770 1 108 280 D00000
                INC     X1                     ; 4773 1 108 280 70
                INC     X1                     ; 4774 1 108 280 70
                RT                             ; 4775 1 108 280 01

knock_helper1:     MOVB    r6, #077h
                JEQ     bitreverse_return

bitreverse_loop:     MB      C, r6.7
                ROLB    r6
                SUBB    A, #001h
                JNE     bitreverse_loop

bitreverse_return:     LB      A, r6
                RT

tm0_resync_helper:     L       A, TMR2                ; 4784 1 108 280 E53A
                JBR     off(0011fh).2, tm0_resync_store_er3 ; 4786 1 108 280 DA1F02
                L       A, 0f0h                ; 4789 1 108 280 E5F0

tm0_resync_store_er3:     ST      A, er3                 ; 478B 1 108 280 8B
                JBS     off(0010fh).7, rpm_resync_gate ; 478C 1 108 280 EF0F0B
                MB      C, IRQH.0              ; 478F 1 108 280 C51928
                JGE     rpm_resync_gate             ; 4792 1 108 280 CD06
                INCB    0aeh                   ; 4794 1 108 280 C5AE16
                SB      0b6h.0                 ; 4797 1 108 280 C5B618

rpm_resync_gate:     SB      off(00128h).3          ; 479A 1 108 280 C4281B
                JEQ     rpm_resync_common             ; 479D 1 108 280 C93A
                SUB     A, 0eeh                ; 479F 1 108 280 B5EEA2
                JBR     off(0011fh).2, rpm_resync_tcon2_check ; 47A2 1 108 280 DA1F22
                CLRB    r1                     ; 47A5 1 108 280 2115
                MOVB    r0, 0aeh               ; 47A7 1 108 280 C5AE48
                SBCB    r0, #000h              ; 47AA 1 108 280 20B000
                MOV     er2, #00006h           ; 47AD 1 108 280 46980600
                DIV                            ; 47B1 1 108 280 9037
                CMPB    r0, #000h              ; 47B3 1 108 280 20C000
                JEQ     rpm_period_reset_calc             ; 47B6 1 108 280 C901
                CLR     A                      ; 47B8 1 108 280 F9

rpm_period_reset_calc:     ST      A, off(00136h)         ; 47B9 1 108 280 D436
                MOV     X1, #0000ch            ; 47BB 1 108 280 600C00

rpm_period_reset_loop:     DEC     X1                     ; 47BE 1 108 280 80
                DEC     X1                     ; 47BF 1 108 280 80
                ST      A, 00360h[X1]          ; 47C0 1 108 280 D06003
                JNE     rpm_period_reset_loop             ; 47C3 1 108 280 CEF9
                SJ      rpm_resync_common             ; 47C5 1 108 280 CB12

rpm_resync_tcon2_check:     MB      C, TCON2.2             ; 47C7 1 108 280 C5422A
                JGE     rpm_resync_store136             ; 47CA 1 108 280 CD01
                CLR     A                      ; 47CC 1 108 280 F9

rpm_resync_store136:     ST      A, off(00136h)         ; 47CD 1 108 280 D436
                LB      A, 0a2h                ; 47CF 0 108 280 F5A2
                SLLB    A                      ; 47D1 0 108 280 53
                EXTND                          ; 47D2 1 108 280 F8
                MOV     X1, A                  ; 47D3 1 108 280 50
                L       A, off(00136h)         ; 47D4 1 108 280 E436
                ST      A, 00360h[X1]          ; 47D6 1 108 280 D06003

rpm_resync_common:     L       A, er3                 ; 47D9 1 108 280 37
                ST      A, 0eeh                ; 47DA 1 108 280 D5EE
                CLRB    0aeh                   ; 47DC 1 108 280 C5AE15
                CMPB    0a2h, #005h            ; 47DF 1 108 280 C5A2C005
                JNE     crank_a3_gate             ; 47E3 1 108 280 CE03
                SLLB    off(001a3h)            ; 47E5 1 108 280 C4A3D7

crank_a3_gate:     JBS     off(001a3h).2, crank_dp_35e ; 47E8 1 108 280 EAA30E
                MOV     DP, #00358h            ; 47EB 1 108 280 625803
                MB      C, 0b8h.0              ; 47EE 1 108 280 C5B828
                SJ      crank_pswl4_store             ; 47F1 1 108 280 CB0C

crank_mul_alt:     MULB                           ; 47F3 0 108 280 A234

crank_mul_common:     MULB                           ; 47F5 0 108 280 A234
                SJ      crank_a2_advance             ; 47F7 0 108 280 CB2E

crank_dp_35e:     MOV     DP, #0035eh            ; 47F9 1 108 280 625E03
                MB      C, 0b8h.1              ; 47FC 1 108 280 C5B829

crank_pswl4_store:     MB      PSWL.4, C              ; 47FF 1 108 280 A33C
                LB      A, 0a2h                ; 4801 0 108 280 F5A2
                CMPB    A, #004h               ; 4803 0 108 280 C604
                JEQ     crank_mul_alt             ; 4805 0 108 280 C9EC
                JGE     crank_a0_update             ; 4807 0 108 280 CD12
                STB     A, r0                  ; 4809 0 108 280 88
                INCB    r0                     ; 480A 0 108 280 A8
                LB      A, 0a0h                ; 480B 0 108 280 F5A0
                ADDB    A, #001h               ; 480D 0 108 280 8601
                CMPB    A, r0                  ; 480F 0 108 280 48
                JLE     crank_mul_common             ; 4810 0 108 280 CFE3
                LB      A, [DP]                ; 4812 0 108 280 F2
                ADDB    A, #001h               ; 4813 0 108 280 8601
                CMPB    A, r0                  ; 4815 0 108 280 48
                JLE     crank_mul_common             ; 4816 0 108 280 CFDD
                JBR     off(0011fh).0, crank_mul_common ; 4818 0 108 280 D81FDA

crank_a0_update:     L       A, [DP]                ; 481B 1 108 280 E2
                ST      A, 0a0h                ; 481C 1 108 280 D5A0
                DEC     DP                     ; 481E 1 108 280 82
                LB      A, [DP]                ; 481F 0 108 280 F2
                STB     A, 09fh                ; 4820 0 108 280 D59F
                MB      C, PSWL.4              ; 4822 0 108 280 A32C
                MB      off(0012ah).5, C       ; 4824 0 108 280 C42A3D

crank_a2_advance:     CLR     A                      ; 4827 1 108 280 F9
                MOV     er0, 0a0h              ; 4828 1 108 280 B5A048
                ST      A, er3                 ; 482B 1 108 280 8B
                LB      A, 0a2h                ; 482C 0 108 280 F5A2
                ADDB    A, #001h               ; 482E 0 108 280 8601
                CMPB    A, r0                  ; 4830 0 108 280 48
                JEQ     crank_mul_common2             ; 4831 0 108 280 C918
                CMPB    A, #006h               ; 4833 0 108 280 C606
                JNE     crank_a2_check3             ; 4835 0 108 280 CE06
                LB      A, r0                  ; 4837 0 108 280 78
                JEQ     crank_mul_common2             ; 4838 0 108 280 C911
                SLLB    A                      ; 483A 0 108 280 53
                JLT     crank_mul_common2             ; 483B 0 108 280 CA0E

crank_a2_check3:     CMPB    0a2h, #003h            ; 483D 0 108 280 C5A2C003
                JNE     crank_mul_alt2             ; 4841 0 108 280 CE26
                CMPB    r0, #005h              ; 4843 0 108 280 20C005
                JNE     crank_mul_alt2             ; 4846 0 108 280 CE21
                MOV     er3, off(00136h)       ; 4848 0 108 280 B4364B

crank_mul_common2:     CLRB    r0                     ; 484B 0 108 280 2015
                L       A, off(00136h)         ; 484D 1 108 280 E436
                MUL                            ; 484F 1 108 280 9035
                LB      A, 0a0h                ; 4851 0 108 280 F5A0
                SLLB    A                      ; 4853 0 108 280 53
                JGE     tmr3_reload_add2             ; 4854 0 108 280 CD2E
                ANDB    PSWH, #0feh            ; 4856 0 108 280 A2D0FE
                L       A, TM3                 ; 4859 1 108 280 E53C
                SUB     A, TMR2                ; 485B 1 108 280 B53AA2
                ADD     A, #00010h             ; 485E 1 108 280 861000
                CMP     A, er1                 ; 4861 1 108 280 49
                JGE     tmr3_reload_dec2             ; 4862 1 108 280 CD0D
                L       A, TMR2                ; 4864 1 108 280 E53A
                ADD     A, er1                 ; 4866 1 108 280 09
                SJ      tmr3_reload_store2             ; 4867 1 108 280 CB10

crank_mul_alt2:     MUL                            ; 4869 0 108 280 9035
                RB      r0.0                   ; 486B 0 108 280 2008
                L       A, ACC                 ; 486D 1 108 280 E506
                SJ      tmr3_reload_clamp_min             ; 486F 1 108 280 CB1F

tmr3_reload_dec2:     RB      TCON3.2                ; 4871 1 108 280 C5430A
                L       A, TM3                 ; 4874 1 108 280 E53C
                SUB     A, #00001h             ; 4876 1 108 280 A60100

tmr3_reload_store2:     ST      A, TMR3                ; 4879 1 108 280 D53E
                RB      TCON3.3                ; 487B 1 108 280 C5430B
                ORB     PSWH, #001h            ; 487E 1 108 280 A2E001
                SJ       tmr3_reload_clamp_min             ; 4881 1 108 280 039048

tmr3_reload_add2:     L       A, er3                 ; 4884 1 108 280 37
                ADD     A, er1                 ; 4885 1 108 280 09
                JGE     tmr3_reload_clamp_check             ; 4886 1 108 280 CD03
                L       A, #0ffffh             ; 4888 1 108 280 67FFFF

tmr3_reload_clamp_check:     CMP     A, #0001fh             ; 488B 1 108 280 C61F00
                JGE     tmr3_store_e8             ; 488E 1 108 280 CD03

tmr3_reload_clamp_min:     L       A, #0001fh             ; 4890 1 108 280 671F00

tmr3_store_e8:     ST      A, 0e8h                ; 4893 1 108 280 D5E8
                MOV     DP, #00f00h            ; 4895 1 108 280 62000F
                LB      A, [DP]                ; 4898 0 108 280 F2
                SRLB    A                      ; 4899 0 108 280 63
                ROR     off(001aah)            ; 489A 0 108 280 B4AAC7
                SRLB    A                      ; 489D 0 108 280 63
                ROR     off(001aah)            ; 489E 0 108 280 B4AAC7
                LB      A, 0a2h                ; 48A1 0 108 280 F5A2
                JNE     crank_a2_check4             ; 48A3 0 108 280 CE06
                CLR     A                      ; 48A5 1 108 280 F9
                XCHG    A, off(001aah)         ; 48A6 1 108 280 B4AA10
                ST      A, 0ech                ; 48A9 1 108 280 D5EC

crank_a2_check4:     LB      A, 0a2h                ; 48AB 0 108 280 F5A2
                CMPB    A, #001h               ; 48AD 0 108 280 C601
                JNE     crank_a8_p1_output             ; 48AF 0 108 280 CE04
                L       A, 0eah                ; 48B1 1 108 280 E5EA
                ST      A, off(001a8h)         ; 48B3 1 108 280 D4A8

crank_a8_p1_output:     L       A, off(001a8h)         ; 48B5 1 108 280 E4A8
                SRL     A                      ; 48B7 1 108 280 63
                MB      P1.7, C                ; 48B8 1 108 280 C5223F
                SRL     A                      ; 48BB 1 108 280 63
                MB      P1.3, C                ; 48BC 1 108 280 C5223B
                ST      A, off(001a8h)         ; 48BF 1 108 280 D4A8
                MOV     DP, #02f00h            ; 48C1 1 108 280 62002F
                LB      A, P1                  ; 48C4 0 108 280 F522
                STB     A, [DP]                ; 48C6 0 108 280 D2
                RT                             ; 48C7 0 108 280 01

ign_angle_to_timer_convert:     CLRB    A
; --- Converts a computed ignition angle/trim (r4) into a hardware timer-compare value
; (scaling via MULB by 3 and combining with er1), used when programming the two ignition
; coil-channel hardware timers (igntiming_output_coil1 and the DP=0x35D channel that follows).
; Clamps the result if it would exceed 0xFE00 range (CMPB ACC,#0feh check).
                STB     A, r3
                SUBB    A, r4
                MOVB    r0, #003h
                MULB
                L       A, ACC
                SUB     A, er1
                SLL     A
                SWAP
                CMPB    ACC, #0feh
                JNE     ign_timer_clamp_store
                L       A, #000ffh

ign_timer_clamp_store:     ST      A, er0
                CLRB    A
                SUBB    A, r2
                SLLB    A
                JNE     ign_timer_convert_return
                LB      A, #0ffh
                SC

ign_timer_convert_return:     RT


knockretard_helper:     STB     A, r0
                LC      A, [X1]
                CMPB    r0, A
                JLT     knockretard_r1_store
                STB     A, r0

knockretard_r1_store:     STB     A, r1
                LB      A, ACCH
                CMPB    r0, A
                JGE     knockretard_sub_result
                STB     A, r0

knockretard_sub_result:     SUBB    r0, A
                SUBB    r1, A
                LB      A, r7
                SJ       table_interp_delta_calc

table_interp_lookup:     CMPCB   A, 00002h[X1]
; --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found
                INC     X1
                INC     X1
                SJ       table_interp_lookup

table_interp_bracket_found:     STB     A, r0
                LC      A, 00002h[X1]
                MOVB    r6, ACCH
                STB     A, r1
                SUBB    r0, A
                LC      A, [X1]
                SUBB    A, r1
                STB     A, r1
                LB      A, ACCH

table_interp_delta_calc:     SUBB    A, r6
                JGE     table_interp_scale_add
                STB     A, r7
                CLRB    A
                SUBB    A, r7
                MULB
                MOVB    r0, r1
                DIVB
                SUBB    r6, A
                LB      A, r6
                RT

table_interp_scale_add:     MULB
                MOVB    r0, r1
                DIVB
                ADDB    A, r6
                STB     A, r6
                RT

vcal_1:         CMPCB   A, [X1]
; ============================================================================================
; RESOLVED: VCAL 0/1/2 (hardware-vectored calls, used throughout this session for table
; lookups without a full CAL+address) are all clamp-then-interpolate table search variants,
; sharing vcal_common_interp for the final math -- essentially specialized entry points into
; the same family as table_interp_lookup, just reached via the cheaper 1-byte VCAL opcode:
;  - VCAL 1 (here): 2-byte-stride table, clamps to the table's first/last Y value if the
;    input is outside the table's X range, otherwise searches for the bracketing segment.
;  - VCAL 2 (below): same but 3-byte-stride table (extra byte per entry, seen in Dcode14 and
;    other diagnostic threshold tables).
;  - VCAL 0 (below): walks a 3-byte-stride table without a low-end clamp, just searching until
;    it finds a segment or hits the table end.
; This resolves the "not yet identified" hedges attached to VCAL 0/1/2 usages earlier in this
; session (idle PID selection, gear correction, Dcode14, dwell tables, etc).
; ============================================================================================
                JLE     vcal1_bracket_check
                LCB     A, [X1]

vcal1_bracket_check:     CMPCB   A, 00002h[X1]
                JGE     table_interp_bracket_found
                LCB     A, 00002h[X1]
                SJ       table_interp_bracket_found

vcal_2:         CMPCB   A, [X1]
                JLE     vcal2_bracket_check
                LCB     A, [X1]

vcal2_bracket_check:     CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                LCB     A, 00003h[X1]
                SJ       vcal_common_interp

vcal_0:         CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                ADD     X1, #00003h
                SJ       vcal_0

vcal_common_interp:     STB     A, r0
                CLR     A
                LC      A, [X1]
                ST      A, er2
                LC      A, 00004h[X1]
                ST      A, er3
                LC      A, 00002h[X1]
                SWAP
                SUBB    r0, A
                SUBB    r4, A
                CLRB    A
                STB     A, r1
                XCHGB   A, r5
                L       A, ACC

injtimer_bank_calc3:     SUB     A, er3
                JGE     injtimer_bank_calc3_alt
                ST      A, er1
                CLR     A
                SUB     A, er1
                MUL
                MOV     er0, er1
                DIV
                SUB     er3, A
                L       A, er3
                RT

injtimer_bank_calc3_alt:     MUL
                MOV     er0, er1
                DIV
                ADD     A, er3
                ST      A, er3
                RT

table_interp_lookup_4byte:     CMPC    A, 00004h[X1]
                JGE     table_interp_4byte_bracket
                ADD     X1, #00004h
                SJ       table_interp_lookup_4byte

table_interp_4byte_bracket:     ST      A, er0
                LC      A, 00004h[X1]
                ST      A, er2
                SUB     er0, A
                LC      A, [X1]
                SUB     A, er2
                ST      A, er2
                LC      A, 00006h[X1]
                ST      A, er3
                LC      A, 00002h[X1]
                SJ       injtimer_bank_calc3

sub_clamp_helper:     SUBB    A, #018h
                JLT     sub_clamp_zero
                MB      C, ACCH.7
                ROLB    A
                JGE     sub_clamp_return
                LB      A, #0ffh

sub_clamp_return:     RT

sub_clamp_zero:     CLRB    A
                RT

mul_scale_helper2:     MUL
                MOV     er2, er1
                CLR     A
                SUB     A, er0
                MOV     er0, [DP]
                MUL
                L       A, er1
                ADD     A, er2
                ST      A, [DP]
                RT

rpm_accel_track_helper:     MUL
                MOV     DP, er1
                MOV     X2, A
                L       A, er3
                MUL
                SUB     er2, A
                L       A, er1
                SBC     er3, A
                L       A, X2
                ADD     er2, A
                L       A, DP
                ADC     A, er3
                RT

injtimer_bank_calc1:     MOV     er2, 00000h[X1]
                SUB     A, er2
                JGE     injtimer_bank_calc1_mul
                ST      A, er1
                CLR     A
                SUB     A, er1

injtimer_bank_calc1_mul:     MUL
                ST      A, er0
                L       A, 00002h[X1]
                SJ      injtimer_bank_calc1_sign

injtimer_bank_calc1_sign:     JGE     injtimer_bank_calc1_add
                SUB     A, er0
                ST      A, er0
                L       A, er2
                SBC     A, er1
                RT

injtimer_bank_calc1_add:     ADD     A, er0
                ST      A, er0
                L       A, er2
                ADC     A, er1
                RT

vcal_4:         ROL     A
; --- RESOLVED: VCAL 4 is a saturating signed 16-bit add-to-er3 helper (clamps to 0 if the
; result would go negative). VCAL 5 (below) is similar but clamps to 0xFFFF on overflow
; instead. Both are widely used throughout the session (idle PID, injector timer calcs, etc)
; -- this resolves the "not yet identified" hedge attached to several VCAL 4/5 call sites.
                JGE     vcal4_negative_path
                ROR     A
                ADD     A, er3
                JLT     vcal4_store
                CLR     A

vcal4_store:     ST      A, er3
                RT

vcal4_negative_path:     ROR     A

vcal_5:         ADD     A, er3
                JGE     vcal5_store
                L       A, #0ffffh

vcal5_store:     ST      A, er3
                RT

signextend_helper:     ROL     A
; --- 16-bit signed saturating add helper (sign-extends r7's high bit, adds to er3, clamps to
; 0x7FFF/0x8000 on overflow rather than wrapping). Used in RPM/period calculations.
                JLT     signext_negative_path
                ROR     A
                MB      C, r7.7
                JLT     signext_common_add
                ADD     A, er3
                ROL     A
                JGE     signext_final_store
                L       A, #07fffh
                ST      A, er3
                RT

signext_common_add:     ADD     A, er3
                ST      A, er3
                RT

signext_negative_path:     ROR     A
                MB      C, r7.7
                JGE     signext_common_add
                ADD     A, er3
                ROL     A
                JLT     signext_final_store
                L       A, #08000h
                ST      A, er3
                RT

signext_final_store:     ROR     A
                ST      A, er3
                RT

scale_mul5_div4:     MOV     er0, #00005h
                MUL
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                CMPB    r2, #000h
                JEQ     scale_mul5_div4_return
                L       A, #0ffffh

scale_mul5_div4_return:     RT

vcal_7:         XOR     A, #0ffffh
; ============================================================================================
; two's-complement NEGATE helpers (XOR with 0xFFFF/0xFF then +1) -- a 16-bit and 8-bit variant
; respectively. They are typically called right after subtracting two sensor readings, to
; compute abs(delta) before comparing against a plausibility threshold. Earlier comments in
; this file describing "VCAL 6/7 (erratic-sensor diagnostic call)" mischaracterized these as
; themselves raising a diagnostic condition -- they don't; they're plain arithmetic. The
; diagnostic/fault behavior comes from the surrounding code's threshold comparison, not from
; VCAL 6/7. The general observation that these appear at sensor-plausibility check sites
; remains accurate; only the specific claim about what VCAL 6/7 themselves do was wrong.
; ============================================================================================
                ADD     A, #00001h
                RT

vcal_6:         XORB    A, #0ffh
                ADDB    A, #001h
                RT

scaler_table_lookup_entry:     CLRB    r6
                CLRB    A
                RT

scaler_table_lookup:     LCB     A, [X1]
                CMPB    r2, A
                JLE     scaler_table_lookup_entry
                CLR     A
                ST      A, er0
                ST      A, er2
                LB      A, r3
                CMPB    A, r6
                JLT     scaler_table_search_start
                LB      A, r6

scaler_table_search_start:     STB     A, r6
                ADD     X1, A

scaler_table_search_loop:     INCB    r6
                INC     X1
                LCB     A, [X1]
                JEQ     scaler_table_interp
                CMPB    A, r2
                JLE     scaler_table_search_loop

scaler_table_interp:     LB      A, r2

scaler_table_search_back:     DECB    r6
                DEC     X1
                CMPCB   A, [X1]
                JLT     scaler_table_search_back
                LCB     A, [X1]
                STB     A, r4
                LB      A, r2
                SUBB    A, r4
                STB     A, r0
                INC     X1
                LCB     A, [X1]
                SUBB    A, r4
                STB     A, r4
                CLR     A
                MB      C, PSWL.4
                JGE     scaler_div_final
                ROL     er0
                SLL     er2

scaler_div_final:     DIV
                RT

table2d_lookup_interp:     CLR     A
; --- Generic 2D table lookup/interpolation helper (row x column, e.g. RPM x Load). Given a
; table base in X1, row width in r0, row index in r1, column offset in r2, column count in r3.
; Companion to the 1D table_interp_lookup used elsewhere.
                LB      A, r2
                ADD     X1, A
                MOV     DP, X1
                L       A, #00101h
                MB      C, PSWL.5
                JGE     table2d_row_calc
                LB      A, r1
                MULB
                ADD     DP, A
                CLR     A
                LC      A, [DP]

table2d_row_calc:     ST      A, er2
                LB      A, r3
                MULB
                ADD     X1, A
                LC      A, [X1]
                MOV     DP, A
                CLR     A
                LB      A, r0
                ADD     X1, A
                LC      A, [X1]
                MOV     X1, A
                MOVB    r0, r4
                L       A, DP
                MULB
                ST      A, er1
                MOVB    r0, r5
                L       A, DP
                SWAP
                MULB
                MOV     DP, A
                L       A, X1
                SWAP
                MULB
                MOVB    r0, r4
                ST      A, er2
                L       A, X1
                MULB
                MOV     X1, er1
                XCHG    A, er2
                MOV     er0, X2
                SCAL     table2d_mul_combine
                MOV     er2, X1
                MOV     X1, A
                L       A, DP
                SCAL     table2d_mul_combine
                L       A, X1
                MOV     er0, er3

table2d_mul_combine:     SUB     A, er2
                JGE     table2d_mul_positive
                ST      A, er1
                CLR     A
                SUB     A, er1
                MUL
                L       A, er1
                SUB     er2, A
                L       A, er2
                RT

table2d_mul_positive:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, er2
                RT

knock_244_helper:     EXTND
                ADD     DP, A
                CLR     A
                LCB     A, [DP]
                ST      A, er2
                INC     DP
                LCB     A, [DP]
                SCAL     table2d_mul_combine
                LB      A, r4
                RT

idle_stall_helper:     MOV     X2, #00010h
                MOV     DP, #01000h
                SJ      clamp_range_check

injtimer_bank_calc2:     MOV     X2, #07133h
                MOV     DP, #09862h

clamp_range_check:     CMP     A, X2
                JLE     clamp_range_lowside
                CMP     A, DP
                JLT     clamp_range_store
                MOV     X2, DP

clamp_range_lowside:     L       A, X2
                CLR     er0

clamp_range_store:     ST      A, 00000h[X1]
                L       A, er0
                ST      A, 00002h[X1]
                RT

idle_helper2:     MUL
                L       A, er1
                JBS     off(0020ch).0, idle_helper2_alt_path
                XCHG    A, er3
                SUB     A, er3
                JGE     idle_pi_clamp_compare

idle_pi_clamp_setcarry:     SC
                L       A, X1
                ST      A, er3
                RT

idle_helper2_alt_path:     ADD     A, er3
                JLT     idle_helper2_sc_path

idle_pi_clamp_compare:     CMP     A, X1
                JLE     idle_pi_clamp_setcarry
                CMP     X2, A
                JGT     idle_helper2_store

idle_helper2_sc_path:     SC
                L       A, X2

idle_helper2_store:     ST      A, er3
                RT

idle_pi_clamp_helper:     CMP     off(0028ch), A
                JLT     idle_pi_clamp_low
                CMP     A, off(0028eh)
                JGE     idle_pi_clamp_return
                L       A, off(0028eh)

idle_pi_clamp_return:     RT

idle_pi_clamp_low:     L       A, off(0028ch)
                RT

cfgvariant_set_flags:     SUBB    A, #001h
; cfgvariant_checksum2_calc are its siblings -- referenced from both cfgvariant_apply_gate in the DTC-scan
; context and the original boot-time config-variant validation block from the very start of
; this session's work). Given a variant index in A, computes byte offset (A/8) and bit
; position (A%8) and sets that bit in 3 separate flag arrays (0x11A, 0x212, 0x31E) --
; enabling variant-specific feature flags across the ECU based on which configuration variant
; is active. cfgvariant_checksum_calc then sums+XORs a small calibration block (0x31D-0x322)
; -- likely a per-variant config validation checksum.
                MOVB    r0, #008h
                DIVB
                MOV     X1, A
                LB      A, r1
                SBR     0011ah[X1]
                SBR     00212h[X1]
                SBR     0031eh[X1]

cfgvariant_checksum_calc:     MOV     DP, #0031dh
                CLR     er0

cfgvariant_checksum_loop:     LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                INC     DP
                CMP     DP, #00322h
                JNE     cfgvariant_checksum_loop
                L       A, er0
                ST      A, [DP]
                RT


port_debounce_helper:     MOV     DP, #03f00h
                LB      A, #090h
                STB     A, [DP]
                MOV     DP, #01f00h
                LB      A, P0
                STB     A, [DP]
                MOV     DP, #02f00h
                LB      A, P1
                STB     A, [DP]
                MOV     DP, #00f00h
                LB      A, [DP]
                XORB    A, #038h
                STB     A, off(00210h)
                STB     A, (00118h-00180h)[USP]
                SB      off(00230h).2
                RT

decrement_timer_array:     L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, 00000h[X1]
                JEQ     decrement_timer_array_next
                DECB    00000h[X1]

decrement_timer_array_next:     ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                INC     X1
                JRNZ    DP, decrement_timer_array
                RT

ResetWatchDog:     LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                MB      C, sysFlags_b7.1
                JLT     resetwatchdog_return
                XORB    P2, #010h

resetwatchdog_return:     RT

ect_step_helper:     ADDB    A, #005h
                JGE     ect_step_range_check
                LB      A, #0ffh

ect_step_range_check:     JBS     off(00217h).4, ect_step_clamp_default
                JBR     off(00230h).3, ect_step_clamp_default
                CMPB    A, 00378h[X1]
                JGE     ect_step_return

ect_step_clamp_default:     MOVB    r0, #042h
                CMPB    A, r0
                JGE     ect_step_store
                LB      A, r0

ect_step_store:     STB     A, 00378h[X1]

ect_step_return:     RT

ect_smooth_helper:     SUBB    A, [DP]
                JGE     ect_smooth_sub
                ADDB    A, #002h
                SJ      ect_smooth_store

ect_smooth_sub:     SUBB    A, #002h

ect_smooth_store:     JGE     ect_smooth_add_store
                CLRB    A

ect_smooth_add_store:     ADDB    A, [DP]
                STB     A, [DP]
                RT

crank_edge_helper:     L       A, off(00124h)         ; 4C51 1 108 280 E424
                ST      A, (0021ch-00280h)[USP] ; 4C53 1 108 280 D39C
                L       A, off(00126h)         ; 4C55 1 108 280 E426
                ST      A, (0021eh-00280h)[USP] ; 4C57 1 108 280 D39E
                RT                             ; 4C59 1 108 280 01

refresh_engine_flags_snapshot:     L       A, (00212h-00280h)[USP] ; 4C5A 1 108 280 E392
; --- Copies a 5-word input/condition snapshot (captured elsewhere, likely synchronized with
; the crank-angle interrupt) into the working flag bytes off(0011Ah)/(0011Ch)/(0011Eh)/
; (00120h)/(00122h). These are the same flag bytes tested throughout GIO1/2/3, ignition
; timing, and elsewhere in this file (e.g. "JBR off(0011eh).5, ..."), refreshed once per call
; here rather than being live hardware registers -- worth knowing when tracing any of those
; bit tests: they reflect the state as of the last refresh_engine_flags_snapshot call, not the
; instantaneous pin state.
                ST      A, off(0011ah)         ; 4C5C 1 108 280 D41A
                L       A, (00214h-00280h)[USP] ; 4C5E 1 108 280 E394
                ST      A, off(0011ch)         ; 4C60 1 108 280 D41C
                L       A, (00216h-00280h)[USP] ; 4C62 1 108 280 E396
                ST      A, off(0011eh)         ; 4C64 1 108 280 D41E
                L       A, (00218h-00280h)[USP] ; 4C66 1 108 280 E398
                ST      A, off(00120h)         ; 4C68 1 108 280 D420
                L       A, (0021ah-00280h)[USP] ; 4C6A 1 108 280 E39A
                ST      A, off(00122h)         ; 4C6C 1 108 280 D422
                RT                             ; 4C6E 1 108 280 01

selftest_regbank_verify:     MOV     X2, A
                SB      off(00230h).7
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                XCHG    A, 00084h[X1]
                XCHG    A, 00084h[X1]
                ST      A, er3
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                RB      off(00230h).7
                L       A, er3
                CMP     A, X2
                JNE     regbank_verify_fail
                RT

regbank_verify_fail:     MOVB    trapReasonCode, #042h
                BRK

idle_helper1:     JBR     off(00230h).3, idle_helper1_alt
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                L       A, TM2
                SUB     A, off(00258h)
                CMP     A, #000c8h
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JLT     idle_helper1_return

idle_helper1_alt:     RB      IRQH.4
                JEQ     selftest_fail_04a
                LB      A, P2
                SWAPB
                SRLB    A
                ANDB    A, #007h
                EXTND
                MOV     X1, A
                LB      A, ADCR1H
                STB     A, 003d2h[X1]
                LB      A, ADCR0H
                STB     A, 003cah[X1]
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                ADDB    P2, #020h
                MOV     off(00258h), TM2
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE

idle_helper1_return:     RT

selftest_fail_04a:     MOVB    trapReasonCode, #04ah
                BRK

empty_stub_return:     RT

dwell_scale_helper:     MOVB    r0, #0bdh
                SLL     A
                JLT     dwell_scale_default
                SLL     A
                JLT     dwell_scale_default
                LB      A, ACCH
                CMPB    A, r0
                JGE     dwell_scale_default
                MOVB    r0, #00fh
                CMPB    A, r0
                JGE     dwell_scale_return

dwell_scale_default:     LB      A, r0

dwell_scale_return:     RT

cfgvariant_eval_condition:     CLRB    r0
                CMPB    r6, #001h
                JNE     cfgvariant_check_v3
                LCB     A, CloseloopO2
                JNE     cfgvariant_result_common
                LCB     A, CloseLoopNarrow
                JNE     cfgvariant_result_common
                CMPB    0dah, #01ah
                JLT     cfgvariant_result_common
                INCB    r0

cfgvariant_result_common:     SJ      cfgvariant_eval_result

cfgvariant_check_v3:     MOV     DP, #cfgvariant_sign_inputs
; --- Variants 3, 6, 7, 10, 11, 13, 20 and 26 each test the sign bit of one input byte (0xBB,
; 0x3D4, 0x3A4, 0x3CC, 0x3D2, 0x3CD, 0x3D2 again, 0xD7) and count a set one in r0 -- a
; per-variant "is this variant's input plausible/connected" check feeding cfgvariant_eval_result.
; HTS 1.15 spelled it out as one 15-byte compare-and-test block per variant; HTS120 walks
; cfgvariant_sign_inputs (variant, input address) instead. Same tests, same order; any other
; variant goes on to cfgvariant_check_v4 as before. (DP is dead here: the next routine reloads it.)
cfgvariant_sign_next:     LCB     A, [DP]
                JEQ     cfgvariant_check_v4
                INC     DP
                CMPB    r6, A           ; (not CMPB A,r6: LCB leaves DD as it was)
                JEQ     cfgvariant_sign_test
                INC     DP
                INC     DP
                SJ      cfgvariant_sign_next
cfgvariant_sign_test:     LC      A, [DP]
                MOV     DP, A
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
cfgvariant_eval_result:     J       cfgvariant_remap_start
;@ cfgvariant_sign_inputs type=u8 formula=ign_advance category=Ignition
cfgvariant_sign_inputs:  DB  003h
                DW  000bbh
                DB  006h
                DW  003d4h
                DB  007h
                DW  003a4h
                DB  00ah
                DW  003cch
                DB  00bh
                DW  003d2h
                DB  00dh
                DW  003cdh
                DB  014h
                DW  003d2h
                DB  01ah
                DW  000d7h
                DB  000h            ; end: not one of these variants

cfgvariant_check_v4:     CMPB    r6, #004h
                JNE     cfgvariant_check_v8
                CMPB    r7, #021h
                JEQ     cfgvariant_eval_result2
                INCB    r0
                SJ      cfgvariant_eval_result2

cfgvariant_check_v8:     CMPB    r6, #008h
                JNE     cfgvariant_check_v9
                CMPB    r7, #022h
                JEQ     cfgvariant_eval_result2
                INCB    r0
                CMPB    r7, #02ah
                JEQ     cfgvariant_eval_result2
                INCB    r0
                SJ      cfgvariant_eval_result2

cfgvariant_check_v9:     CMPB    r6, #009h
                JNE     cfgvariant_check_v17
                CMPB    r7, #023h
                JEQ     cfgvariant_eval_result2
                INCB    r0
                SJ      cfgvariant_eval_result2

cfgvariant_check_v17:     CMPB    r6, #011h
                JNE     cfgvariant_check_v14_29

cfgvariant_eval_result2:     SJ      cfgvariant_remap_start

cfgvariant_check_v14_29:     CMPB    r6, #00eh
                JEQ     cfgvariant_eval_result3
                CMPB    r6, #01dh
                JNE     cfgvariant_check_v15_16_21
                L       A, (0ffd7h-0ffffh)[USP]
                CMP     A, #08000h
                JLT     cfgvariant_eval_result3
                INCB    r0

cfgvariant_eval_result3:     SJ      cfgvariant_remap_start

cfgvariant_check_v15_16_21:     CMPB    r6, #00fh
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #010h
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #015h
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #01bh
                JNE     cfgvariant_check_v5_16_17

cfgvariant_eval_result4:     SJ      cfgvariant_remap_start

cfgvariant_check_v5_16_17:     CMPB    r6, #005h
                JEQ     cfgvariant_remap_start
                CMPB    r6, #016h
                JEQ     cfgvariant_remap_start
                CMPB    r6, #017h
                JEQ     cfgvariant_remap_start
                CMPB    r6, #01eh
                JNE     cfgvariant_check_v1e
                CMPB    r7, #015h
                JNE     cfgvariant_remap_start
                INCB    r0
                SJ      cfgvariant_remap_start

cfgvariant_check_v1e:     CMPB    r6, #01fh
                JNE     cfgvariant_check_v1f
                CMPB    r7, #016h
                JNE     cfgvariant_remap_start
                INCB    r0
                SJ      cfgvariant_remap_start

cfgvariant_check_v1f:     CMPB    r6, #019h
                JEQ     cfgvariant_remap_start
                MOVB    r1, r6
                RT

cfgvariant_remap_start:     CLR     A
                LB      A, r6
                CAL     code_remap                     ; 25->35, 26->36, 27->41, 29->43
cfgvariant_remap_store:     STB     A, r1
                SRLB    A
                MOV     X1, A
                LB      A, r0
                JGE     cfgvariant_bit_calc
                ADDB    A, #004h

cfgvariant_bit_calc:     SBR     00324h[X1]
                RT

cfgvariant_snapshot_capture:     MOV     DP, #00344h
; --- One of the config-variant sibling routines (cfgvariant_set_flags/cfgvariant_eval_
; condition are the others): captures a comprehensive one-time sensor snapshot (VSS, RPM,
; MAP, IAT, TPS-related bytes) sequentially into a buffer starting at 0x345, gated so it only
; captures once (checks 0x344 is still zero first). Reads as a freeze-frame-style data
; capture tied to a specific config-variant condition becoming active -- connects to the
; freeze-frame decoder found earlier in the DTC/diagnostic subsystem.
                LB      A, [DP]
                JNE     cfgvariant_snapshot_return
                INC     DP
                LB      A, 0cch
                STB     A, [DP]
                INC     DP
                L       A, 0c4h
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                MOV     X1, #003d4h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003cch
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0bbh
                STB     A, [DP]
                INC     DP
                MOV     X1, #003cdh
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003a4h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0dbh
                STB     A, [DP]
                INC     DP
                MOV     X1, #003a6h
                L       A, 00000h[X1]
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                LB      A, 0dah
                STB     A, [DP]
                INC     DP
                LB      A, (0ffd8h-0ffffh)[USP]
                STB     A, [DP]
                INC     DP
                LB      A, 09dh
                STB     A, [DP]
                NOP
                MOV     DP, #00344h
                LB      A, r1
                ROLB    A
                MB      C, off(0021dh).0
                RORB    A
                STB     A, [DP]

cfgvariant_snapshot_return:     RT

cfgvariant_state_reset:     CLR     A
                MOV     DP, #0031dh
                CLRB    [DP]
                MOV     DP, #00356h

cfgvariant_state_clear_loop:     DEC     DP
                DEC     DP
                ST      A, [DP]
                CMP     DP, #0031eh
                JGT     cfgvariant_state_clear_loop
                RT

cfgvariant_ram_init:     CLR     X1
; --- Config-variant RAM initialization: seeds default values (0x8000 sentinels, and copies
; from FUEL1_Hi_Extended) into the 0x300-0x31A working region -- pairs with
; cfgvariant_checksum2_calc below, a second checksum (sum+XOR) computed over 0x324-0x353,
; likely validating a different per-variant config block than cfgvariant_checksum_calc's.
                L       A, #08000h
                ST      A, 00300h[X1]
                ST      A, 00304h[X1]
                ST      A, 00308h[X1]
                L       A, 00384h[X1]
                ST      A, 0030ch[X1]
                CLRB    A
                STB     A, 00310h[X1]
                LB      A, #07bh
                STB     A, 00311h[X1]
                LB      A, #03bh
                STB     A, 0031ah[X1]
                RT

cfgvariant_checksum2_calc:     MOV     DP, #00324h
                LB      A, [DP]
                ANDB    A, #0f0h
                STB     A, r0
                STB     A, r1

cfgvariant_checksum2_loop:     INC     DP
                LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                CMP     DP, #00353h
                JNE     cfgvariant_checksum2_loop
                RT

boot_completion_helper:     CLRB    A
; --- Master feature-enable flag initialization: reads a whole set of calibration enable
; flags (VtecEnable, AutoA, O2Heater, CloseloopO2VE, DCode16, Tablepointers, and more --
; all real calibration fields) and packs each into its corresponding runtime status bit
; (0x216/0x217/0x219/0x227). This is the concrete "apply calibration enable switches to
; runtime state" step, likely run once during/after boot.
                LCB     A, VtecEnable
                SLLB    A
                MB      off(00216h).4, C
                LCB     A, AutoA
                SLLB    A
                MB      off(00227h).6, C
                LCB     A, O2Heater
                SLLB    A
                MB      off(00216h).6, C
                LCB     A, CloseloopO2VE
                SLLB    A
                MB      off(00219h).3, C
                LCB     A, DCode16
                SLLB    A
                MB      off(00217h).3, C
                LCB     A, Tablepointers
                SLLB    A
                MB      off(00227h).7, C
                LCB     A, tbl_boot_flag_misc1
                SLLB    A
                MB      off(00227h).1, C
                LCB     A, tbl_cfgvariant_max
                SLLB    A
                MB      off(0022dh).0, C
                LCB     A, VtecVSSCheck
                SLLB    A
                MB      off(0022dh).1, C
                LCB     A, DCode20
                SLLB    A
                MB      off(00217h).6, C
                MOV     DP, #003cbh
                LB      A, [DP]
                STB     A, r1
                RC
                LCB     A, Debug
                STB     A, r0
                MOV     DP, #003d3h
                LB      A, [DP]
                STB     A, r2
                CMPB    r0, #000h
                JEQ     boot_flag_disableauto
                LCB     A, DisableAuto

boot_flag_disableauto:     SLLB    A
                MB      off(00216h).3, C
                LCB     A, IABVEnable
                SLLB    A
                MB      off(002eeh).3, C
                CMPB    r0, #000h
                JEQ     boot_flag_iabv_check
                LCB     A, tbl_autotrans_flag
                SLLB    A
                SJ      boot_flag_iabv_common

boot_flag_iabv_check:     RC
                JBS     off(002eeh).3, boot_flag_iabv_common
                LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h


boot_flag_iabv_common:     MB      off(00216h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_baro_check
                LCB     A, tbl_iabv_flag
                SLLB    A
                SJ      boot_flag_baro_common

boot_flag_baro_check:     LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h

boot_flag_baro_common:     MB      off(00216h).0, C
                LCB     A, chkBaro
                SLLB    A
                MB      off(00227h).4, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_check
                LCB     A, InjectorSettings
                SLLB    A
                SJ      boot_flag_gearpreset_common

boot_flag_gearpreset_check:     RC
                JBS     off(002eeh).3, boot_flag_gearpreset_common
                LB      A, r1
                SLLB    A

boot_flag_gearpreset_common:     MB      off(00216h).5, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt
                LCB     A, GearPreset
                SLLB    A
                SJ      boot_flag_tbl6214_check

boot_flag_gearpreset_alt:     MB      C, off(00216h).3

boot_flag_tbl6214_check:     MB      off(00227h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_3cf_check
                LCB     A, tbl_boot_flag_misc2
                SLLB    A
                SJ      boot_flag_final

boot_flag_3cf_check:     MOV     DP, #003cfh
                CMPB    [DP], #080h
                XORB    PSWH, #080h

boot_flag_final:     MOV     DP, #00356h
                MB      [DP].1, C
                L       A, #00500h
                MOV     DP, #00384h
                ST      A, [DP]
                RT
                DB  0E6h,03Fh,0E6h,03Fh,0AEh,019h,0AEh,019h
                DB  0FFh,030h,0E0h,021h,0D0h,01Eh,0C0h,023h
                DB  0B0h,028h ; 4FF5
;@ tbl_knockwindow_alt type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_knockwindow_alt:DB  000h,028h,0FFh,027h,0E0h,018h ; 4FF7
                DB  0D0h,015h,0C0h,017h,0B0h,022h ; 4FFD
;@ tbl_ect_knock_scale type=u8 count=20 formula=raw category=Detected desc="20 bytes"
tbl_ect_knock_scale:DB  000h,022h ; 5003
                DB  0FFh,0CCh,0F5h,0CCh,0E6h,0AEh,0CFh,0AAh
                DB  0A1h,0A9h,06Eh,0A4h,02Eh,09Ah,028h,080h
                DB  000h,080h

int_serial_tx:  L       A, 0fah
; ============================================================================================
; Serial transmit interrupt: dispatches through an INDIRECT jump table (J [DP], address
; computed from er0 as a state index) into the diagnostic serial transmit state machine. This
; is exactly the kind of double-indirect call the compact doc's README warns dasm662 is not
; 100% reliable for -- the disassembler could not statically resolve individual jump targets,
; so much of the surrounding code (the DB byte runs at 0x4FE5-0x503A, 0x504F-0x50A4, etc.) is
; very likely jump-table data and/or code the disassembler mis-identified as data, not
; necessarily dead code. Treat labels in this immediate region (int_serial_tx onward) as lower
; confidence than elsewhere in this file for that reason -- verify against reassembled output
; rather than trusting the linear disassembly here.
; ============================================================================================
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #0007eh           ; 5041 1 3F0 ??? 577E00
                L       A, DP                  ; 5044 1 3F0 ??? 42
                PUSHS   A                      ; 5045 1 3F0 ??? 55
                L       A, er0                 ; 5046 1 3F0 ??? 34
                JEQ     serialtx_dispatch_zero             ; 5047 1 3F0 ??? C903
                MOV     DP, A                  ; 5049 1 3F0 ??? 52
                J       [DP]                   ; 504A 1 3F0 ??? 9222

serialtx_dispatch_zero:     J       serial_isr_return             ; 504C 1 3F0 ??? 030951
serial_504F:    LB A, r4                            ; 504F 1 7C
                JEQ serial_5081                     ; 5050 0 C92F
                MOV DP, er1                         ; 5052 0 457A
                DECB r4                             ; 5054 0 BC
                LB A, [DP]                          ; 5055 0 F2
                INC er1                             ; 5056 0 4516
                SJ serial_507A                      ; 5058 0 CB20
serial_505A:    LB A, r4                            ; 505A 1 7C
                JEQ serial_5081                     ; 505B 0 C924
                MOV DP, er1                         ; 505D 0 457A
                DECB r4                             ; 505F 0 BC
                CLRB A                              ; 5060 0 FA
                LCB A, [DP]                         ; 5061 0 92AA
                INC er1                             ; 5063 0 4516
                SJ serial_507A                      ; 5065 0 CB13
serial_5067:    MOV DP, er1                         ; 5067 1 457A
                ADD er1, #00002h                    ; 5069 1 45800200
                L A, 006h                           ; 506D 1 E506
                LC A, [DP]                          ; 506F 1 92A8
                JEQ serial_5081                     ; 5071 1 C90E
                CMP A, #08000h                      ; 5073 1 C60080
                JGE serial_5085                     ; 5076 1 CD0D
                MOV DP, A                           ; 5078 1 52
                LB A, [DP]                          ; 5079 1 F2
serial_507A:    STB A, r6                           ; 507A 0 8E
                ADDB A, r5                          ; 507B 0 0D
                STB A, r5                           ; 507C 0 8D
                LB A, r6                            ; 507D 0 7E
                J serialtx_send_byte                ; 507E 0 030751
serial_5081:    LB A, r5                            ; 5081 0 7D
                SJ serialrx_reset_state              ; 5082 0 030351
serial_5085:    MOV DP, #07FFFh                     ; 5085 1 62FF7F
                AND A, DP                           ; 5088 1 92D2
                MOV DP, A                           ; 508A 1 52
                MOV er0, [DP]                       ; 508B 1 B248
                LB A, r0                            ; 508D 1 78
                MOVB r4, r1                         ; 508E 0 214C
                MOV er0, #serial_5096               ; 5090 0 44989650
                SJ serial_507A                      ; 5094 0 CBE4
serial_5096:    MOV er0, #serial_5067               ; 5096 1 44986750
                LB A, r4                            ; 509A 1 7C
                SJ serial_507A                      ; 509B 0 CBDD

serialtx_jumptable_entry1:     J       serialtx_error_ee             ; 509D 0 3F0 ??? 039D51
serial_50A0:    LB A, r4                            ; 50A0 1 7C
                SJ serialrx_reset_state              ; 50A1 0 030351

int_serial_rx:  L       A, 0fah
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #0007eh           ; 50AB 1 3F0 ??? 577E00
                L       A, DP                  ; 50AE 1 3F0 ??? 42
                PUSHS   A                      ; 50AF 1 3F0 ??? 55
                CLR     A                      ; 50B0 1 3F0 ??? F9
                LB      A, SRBUF               ; 50B1 0 3F0 ??? F555
                CMPB    r0, #000h              ; 50B3 0 3F0 ??? 20C000
                JNE     serialrx_range_check             ; 50B6 0 3F0 ??? CE24
                STB     A, r0                  ; 50B8 0 3F0 ??? 88
                CMPB    r0, #0c0h              ; 50B9 0 3F0 ??? 20C0C0
                JGE     serialrx_cmd_dispatch             ; 50BC 0 3F0 ??? CD55
                ANDB    A, #00fh               ; 50BE 0 3F0 ??? D60F
                STB     A, r1                  ; 50C0 0 3F0 ??? 89
                CMPB    A, #005h               ; 50C1 0 3F0 ??? C605
                JGT     serialtx_jumptable_entry1             ; 50C3 0 3F0 ??? C8D8
                CMPB    A, #000h               ; 50C5 0 3F0 ??? C600
                JNE     serial_isr_return             ; 50C7 0 3F0 ??? CE40

serialrx_store_loop:     LB      A, r0                  ; 50C9 0 3F0 ??? 78
                L       A, ACC                 ; 50CA 1 3F0 ??? E506
                AND     A, #000f0h             ; 50CC 1 3F0 ??? D6F000
                SRL     A                      ; 50CF 1 3F0 ??? 63
                SRL     A                      ; 50D0 1 3F0 ??? 63
                SRL     A                      ; 50D1 1 3F0 ??? 63
                MOV     DP, #serial_cmd_table            ; 50D2 1 3F0 ??? 62C151
                ADD     DP, A                  ; 50D5 1 3F0 ??? 9281
                LC      A, [DP]                ; 50D7 1 3F0 ??? 92A8
                MOV     DP, A                  ; 50D9 1 3F0 ??? 52
                J       [DP]                   ; 50DA 1 3F0 ??? 9222

serialrx_range_check:     CMPB    r0, #0f1h              ; 50DC 0 3F0 ??? 20C0F1
                JLT     serialrx_store_alt             ; 50DF 0 3F0 ??? CA11
                STB     A, r7                  ; 50E1 0 3F0 ??? 8F
                MOV     DP, #00417h            ; 50E2 0 3F0 ??? 621704
                LB      A, r2                  ; 50E5 0 3F0 ??? 7A
                ADD     DP, A                  ; 50E6 0 3F0 ??? 9281
                LB      A, r7                  ; 50E8 0 3F0 ??? 7F
                STB     A, [DP]                ; 50E9 0 3F0 ??? D2
                INCB    r2                     ; 50EA 0 3F0 ??? AA
                LB      A, r1                  ; 50EB 0 3F0 ??? 79
                CMPB    A, r2                  ; 50EC 0 3F0 ??? 4A
                JEQ     serialrx_store_loop             ; 50ED 0 3F0 ??? C9DA
                SJ       serial_isr_return             ; 50EF 0 3F0 ??? 030951

serialrx_store_alt:     STB     A, r7                  ; 50F2 0 3F0 ??? 8F
                MOV     DP, #003f1h            ; 50F3 0 3F0 ??? 62F103
                LB      A, r1                  ; 50F6 0 3F0 ??? 79
                ADD     DP, A                  ; 50F7 0 3F0 ??? 9281
                LB      A, r7                  ; 50F9 0 3F0 ??? 7F
                STB     A, [DP]                ; 50FA 0 3F0 ??? D2
                MOV     DP, er1                ; 50FB 0 3F0 ??? 457A
                DECB    r1                     ; 50FD 0 3F0 ??? B9
                JEQ     serialrx_store_loop             ; 50FE 0 3F0 ??? C9C9
                SJ       serial_isr_return             ; 5100 0 3F0 ??? 030951

serialrx_reset_state:     CLRB    r0                     ; 5103 0 3F0 ??? 2015
                CLRB    r1                     ; 5105 0 3F0 ??? 2115

serialtx_send_byte:     STB     A, STBUF               ; 5107 0 3F0 ??? D551

serial_isr_return:     POPS    A                      ; 5109 1 3F0 ??? 65
                MOV     DP, A                  ; 510A 1 3F0 ??? 52
                L       A, 0f8h                ; 510B 1 3F0 ??? E5F8
                ANDB    PSWH, #0feh            ; 510D 1 3F0 ??? A2D0FE
                ST      A, IE                  ; 5110 1 3F0 ??? D51A
                RTI                            ; 5112 1 3F0 ??? 02

serialrx_cmd_dispatch:     LB      A, r0                  ; 5113 0 3F0 ??? 78
                SUBB    A, #0c0h               ; 5114 0 3F0 ??? A6C0
                MOV     DP, #serial_c0_table            ; 5116 0 3F0 ??? 622F52
                L       A, ACC                 ; 5119 1 3F0 ??? E506
                AND     A, #000ffh             ; 511B 1 3F0 ??? D6FF00
                ADD     DP, A                  ; 511E 1 3F0 ??? 9281
                ADD     DP, A                  ; 5120 1 3F0 ??? 9281
                LC      A, [DP]                ; 5122 1 3F0 ??? 92A8
                CMP     A, #08000h             ; 5124 1 3F0 ??? C60080
                JGE     serialrx_cmd_indirect             ; 5127 1 3F0 ??? CD05
                MOV     DP, A                  ; 5129 1 3F0 ??? 52
                LB      A, [DP]                ; 512A 0 3F0 ??? F2
                SJ       serialrx_reset_state             ; 512B 0 3F0 ??? 030351

serialrx_cmd_indirect:     MOV     DP, #07fffh            ; 512E 1 3F0 ??? 62FF7F
                AND     A, DP                  ; 5131 1 3F0 ??? 92D2
                MOV     DP, A                  ; 5133 1 3F0 ??? 52
                MOV     er0, [DP]              ; 5134 1 3F0 ??? B248
                LB      A, r0                  ; 5136 0 3F0 ??? 78
                MOVB    r4, r1                 ; 5137 0 3F0 ??? 214C
                MOV     er0, #serial_50A0           ; 5139 0 3F0 ??? 4498A050
                SJ       serialtx_send_byte             ; 513D 0 3F0 ??? 030751
serial_5140:    LB A, #0CDh                         ; 5140 1 77CD
                SJ serialrx_reset_state             ; 5142 0 CBBF
serial_5144:    MOV DP, #0031Eh                     ; 5144 1 621E03
                CLR A                               ; 5147 1 F9
                ST A, [DP]                          ; 5148 1 D2
                INC DP                              ; 5149 1 72
                INC DP                              ; 514A 1 72
                ST A, [DP]                          ; 514B 1 D2
                LB A, #050h                         ; 514C 1 7750
                SJ serialrx_reset_state             ; 514E 0 CBB3
serial_5150:    MOV er1, #serial_c0_table                    ; 5150 1 45982F52
serial_5154:    MOV er0, #serial_5067               ; 5154 1 44986750
                CLRB r5                             ; 5158 1 2515
                MOV DP, er0                         ; 515A 1 447A
                J [DP]                              ; 515C 1 9222
serial_515E:    MOV er1, #serial_frame_table                    ; 515E 1 45980552
                SJ serial_5154                      ; 5162 1 CBF0
serial_cmd_hts120: MOV er1, #hts120_log_table     ; HTS120: 40h -> TC/anti-start datalog packet + checksum
                SJ serial_5154
serial_5164:    MOV DP, er1                         ; 5164 1 457A
                LCB A, [DP]                         ; 5166 1 92AA
                SJ serialrx_reset_state             ; 5168 1 CB99
serial_516A:    MOV DP, er1                         ; 516A 1 457A
                LB A, [DP]                          ; 516C 1 F2
                SJ serialrx_reset_state             ; 516D 0 CB94
serial_516F:    MOV DP, er1                         ; 516F 1 457A
                CLRB A                              ; 5171 1 FA
                LCB A, [DP]                         ; 5172 0 92AA
                STB A, r5                           ; 5174 0 8D
                INC er1                             ; 5175 0 4516
                MOVB r4, #0FFh                      ; 5177 0 9CFF
                MOV er0, #serial_505A               ; 5179 0 44985A50
                SJ serialtx_send_byte                ; 517D 0 030751
serial_5180:    MOV DP, er1                         ; 5180 1 457A
                LB A, [DP]                          ; 5182 1 F2
                STB A, r5                           ; 5183 0 8D
                INC er1                             ; 5184 0 4516
                MOVB r4, #0FFh                      ; 5186 0 9CFF
                MOV er0, #serial_504F               ; 5188 0 44984F50
                J serialtx_send_byte                ; 518C 0 030751
serial_518F:    RB PSWL.4                           ; 518F 1 A30C
                SB PSWL.5                           ; 5191 1 A31D
                SCAL serial_51A2                    ; 5193 1 310D
                MOV DP, er1                         ; 5195 1 457A
                LB A, r4                            ; 5197 1 7C
                STB A, [DP]                         ; 5198 0 D2
                CLRB A                              ; 5199 0 FA
                J serialrx_reset_state              ; 519A 0 030351

serialtx_error_ee:     LB      A, #0eeh               ; 519D 0 3F0 ??? 77EE
                J       serialrx_reset_state             ; 519F 0 3F0 ??? 030351
serial_51A2:    LB A, r0                            ; 51A2 1 78
                ADDB A, r2                          ; 51A3 0 0A
                ADDB A, r3                          ; 51A4 0 0B
                MB C, PSWL.4                        ; 51A5 0 A32C
                JGE serial_51AC                     ; 51A7 0 CD03
                CMPB A, r4                          ; 51A9 0 4C
                SJ serial_51B6                      ; 51AA 0 CB0A
serial_51AC:    ADDB A, r4                          ; 51AC 0 0C
                MB C, PSWL.5                        ; 51AD 0 A32D
                JLT serial_51B5                     ; 51AF 0 CA04
                ADDB A, r5                          ; 51B1 0 0D
                CMPB A, r6                          ; 51B2 0 4E
                SJ serial_51B6                      ; 51B3 0 CB01
serial_51B5:    CMPB A, r5                          ; 51B5 0 4D
serial_51B6:    JNE serial_51B9                     ; 51B6 0 CE01
                RT                                  ; 51B8 0 01
serial_51B9:    POPS A                              ; 51B9 0 65
                SJ serialtx_error_ee                ; 51BA 1 CBE1
serial_51BC:    LB A, #0DDh                         ; 51BC 1 77DD
                J serialrx_reset_state              ; 51BE 0 030351
serial_cmd_table:DW  serialtx_error_ee             ; 51C1
                DW  serial_5140                   ; 51C3
                DW  serial_5150                   ; 51C5
                DW  serial_515E                   ; 51C7
                DW  serial_cmd_hts120             ; 51C9 (40h: was serialtx_error_ee)
                DW  serial_5144                   ; 51CB
                DW  serial_5164                   ; 51CD
                DW  serial_516A                   ; 51CF
                DW  serial_516F                   ; 51D1
                DW  serial_5180                   ; 51D3
                DW  serial_518F                   ; 51D5
                DW  serial_51BC                   ; 51D7
                DW  serial_51BC                   ; 51D9
                DW  serial_51BC                   ; 51DB
                DW  serial_51BC                   ; 51DD
                DW  serial_51BC                   ; 51DF
;@ serial_frame_table type=u8 count=42 formula=raw category=Detected desc="42 bytes"
serial_frame_table:DB  0D9h,000h,0CCh,003h,0CAh ; 5205
                DB  003h,0BBh,000h,0A4h,003h,0CCh,000h,0C4h
                DB  080h,0C6h,080h,0C8h,080h,0CDh,000h,0E7h
                DB  001h,0E8h,001h,0DFh,001h,09Eh,081h,05Bh
                DB  003h,0D2h,003h,01Ch,004h,067h,000h,0D5h
                DB  003h,000h,000h,000h,000h ; 522A
;@ serial_c0_table type=u8 count=92 formula=raw category=Detected desc="92 bytes"
serial_c0_table:DB  0D9h,000h,0CCh ; 522F
                DB  003h,0CAh,003h,0BCh,000h,0BBh,000h,0A4h
                DB  003h,0C4h,080h,0B1h,003h,0E7h,001h,0E8h
                DB  001h,0DFh,001h,01Ah,001h,01Bh,001h,01Ch
                DB  001h,01Dh,001h,0CCh,000h,09Eh,081h,05Bh
                DB  003h,046h,002h,0B0h,003h,0B2h,003h,0B3h
                DB  003h,0D2h,003h,0D1h,003h,068h,001h,058h
                DB  081h,004h,083h,05Ch,081h,062h,001h,012h
                DB  004h,052h,002h,053h,002h,03Bh,002h,008h
                DB  004h,009h,004h,01Bh,004h,01Ch,004h,01Ah
                DB  004h,010h,004h,067h,000h,0D5h,003h,0EAh
                DB  001h,0ECh,001h,0E2h,001h,082h,083h,000h
                DB  000h

mul_scale_clamp:     MUL                            ; 528B 1 108 280 9035
                ROL     A                      ; 528D 1 108 280 33
                L       A, er1                 ; 528E 1 108 280 35
                ROL     A                      ; 528F 1 108 280 33
                JGE     mul_scale_clamp_return             ; 5290 1 108 280 CD03
                L       A, #0ffffh             ; 5292 1 108 280 67FFFF

mul_scale_clamp_return:     RT                             ; 5295 1 108 280 01

mulb_scale_clamp:     MULB
                L       A, ACC
                ROL     A
                LB      A, ACCH
                JGE     mul_scale_clamp_return
                LB      A, #0ffh

gearcorrect_ign_check:     LCB     A, GearCorrectVSS
; --- Per-gear ignition timing correction: if VSS(0xCC) and MAP(0xBB) both exceed
; GearCorrectVSS/GearCorrectMap thresholds, looks up a per-gear correction from
; GearCorrectIgn[current gear index @ 0x24F] and clamps it centered on 0x80 (neutral/no
; correction); otherwise defaults to 0x80 (gearcorrect_ign_disabled = no correction applied).
                CMPB    0cch, A
                JLT     gearcorrect_ign_disabled
                LCB     A, GearCorrectMap
                CMPB    0bbh, A
                JLT     gearcorrect_ign_disabled
                CLR     A
                LB      A, off(0024fh)
                LCB     A, GearCorrectIgn[ACC]
                STB     A, off(00253h)
                CAL     clamp_centered_0x80
                SJ      igncorrect_iat_lookup

gearcorrect_ign_disabled:     LB      A, #080h
                STB     A, off(00253h)

igncorrect_iat_lookup:     MOVB    r3, r0
                LB      A, 0d8h
                MOV     X1, #IATCorrect
                CAL     table_interp_lookup
                CLR     X1
                STB     A, 00412h[X1]
                MOVB    r0, r3
                CAL     clamp_centered_0x80
                MOVB    r3, r0
                LB      A, 0d9h
                MOV     X1, #ECTIgnCorrect
                CAL     table_interp_lookup
                STB     A, off(00252h)
                MOVB    r0, r3
                SCAL     clamp_centered_0x80
                MOVB    r3, r0
                MOV     DP, #00410h
                MB      C, [DP].0
                JGE     igncorrect_gio1_check
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment1
                CAL     table_interp_lookup
                MOVB    r0, r3
                SCAL    clamp_centered_0x80

igncorrect_gio1_check:     MOVB    r3, r0
                MOV     DP, #00410h
                MB      C, [DP].1
                JGE     igncorrect_gio2_check
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment1
                CAL     table_interp_lookup
                MOVB    r0, r3
                SCAL    clamp_centered_0x80

igncorrect_gio2_check:     MOVB    r3, r0
                MOV     DP, #00410h
                MB      C, [DP].2
                JGE     igncorrect_cylinder_select
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment1
                CAL     table_interp_lookup
                MOVB    r0, r3
                SCAL    clamp_centered_0x80

igncorrect_cylinder_select:     MOVB    r4, (0013ch-00180h)[USP]
                CLRB    A
                CMPB    r4, #000h
                JNE     igncorrect_cyl2_check
                LCB     A, CylinderIgn
                SJ      igncorrect_cyl_clamp

igncorrect_cyl2_check:     CMPB    r4, #001h
                JNE     igncorrect_cyl3_check
                LCB     A, CylinderIgn2
                SJ      igncorrect_cyl_clamp

igncorrect_cyl3_check:     CMPB    r4, #002h
                JNE     igncorrect_cyl4_check
                LCB     A, CylinderIgn3
                SJ      igncorrect_cyl_clamp

igncorrect_cyl4_check:     CMPB    r4, #003h
                JNE     igncorrect_cyl_clamp
                LCB     A, CylinderIgn4


igncorrect_cyl_clamp:     SCAL    clamp_centered_0x80
                RT

clamp_centered_0x80:     MOVB    r4, #080h
                CMPB    A, r4
                JEQ     clamp_centered_return
                JGE     clamp_centered_high
                SUBB    r4, A
                LB      A, r4
                SUBB    r0, A
                JGE     clamp_centered_return
                MOVB    r0, #000h
                SJ      clamp_centered_return

clamp_centered_high:     SUBB    A, r4
                ADDB    r0, A
                JGE     clamp_centered_return
                MOVB    r0, #0ffh

clamp_centered_return:     RT

aux_input_bit_select:     MB      C, ACC.0
; --- Generic auxiliary-input helper: given a channel index 0-7 in A, extracts that specific
; bit from the ACC port snapshot into Carry (chained per-bit test/branch). Channel indices >=8
; fall through to a separate extended-input path (0x53A0+, not traced here) reading other
; status registers (e.g. off(00210h).3) -- likely maps additional logical "inputs" (internal
; flags/conditions) onto the same input-select mechanism used for physical pins.
                JLT     aux_input_ext_ch8
                MB      C, ACC.1
                JLT     aux_input_ext_ch9
                MB      C, ACC.2
                JLT     aux_input_ext_ch10
                MB      C, ACC.3
                JLT     aux_input_ext_ch11
                MB      C, ACC.4
                JLT     aux_input_ext_ch12
                MB      C, ACC.5
                JLT     aux_input_ext_ch13
                MB      C, ACC.6
                JLT     aux_input_ext_ch14
                MB      C, ACC.7
                JLT     aux_input_ext_invalid
                RC
                SJ      aux_input_bit_select_return

aux_input_ext_ch8:     MB      C, off(00210h).3
                MOVB    r1, #000h
                SJ      aux_input_ext_common

aux_input_ext_ch9:     MB      C, off(00210h).7
                MOVB    r1, #001h
                SJ      aux_input_ext_common

aux_input_ext_ch10:     MB      C, off(00211h).0
                MOVB    r1, #002h
                SJ      aux_input_ext_common

aux_input_ext_ch11:     MB      C, off(00211h).1
                MOVB    r1, #003h
                SJ      aux_input_ext_common

aux_input_ext_ch12:     MB      C, off(00211h).2
                MOVB    r1, #004h
                SJ      aux_input_ext_common

aux_input_ext_ch13:     MB      C, off(00211h).4
                MOVB    r1, #005h
                SJ      aux_input_ext_common

aux_input_ext_ch14:     MB      C, off(00211h).5
                MOVB    r1, #006h
                SJ      aux_input_ext_common

aux_input_ext_invalid:     SC
                SJ      aux_input_bit_select_return

aux_input_ext_common:     LB      A, r0
                JEQ     aux_input_result_store
                XORB    PSWH, #080h

aux_input_result_store:     L       A, X1
                PUSHS   A
                CLR     X1
                LB      A, r1
                SBR     00420h[X1]
                POPS    A
                MOV     X1, A
                CLRB    A
                RT

aux_input_bit_select_return:     RT

indexed_ram_selector_0to3:     CMPB    A, #001h
; --- Generic 4-way indexed RAM read: given A=0-3, returns the value at one of 4 fixed RAM
; addresses (case0=off(003d2h), case1=off(00067h), case2=off(003d5h), case3=off(000dah)).
; Confirmed used for at least two unrelated purposes: (1) O2Input-based sensor-type selection
; (see o2_closedloop_read_and_select above), and (2) bstDial-based boost-dial input selection
; (see indexed_ram_selector call from 0x5A05 using bstDial). Genuinely generic, not O2-specific
; -- do not assume every caller is O2-related.
; --- O2/lambda sensor MUX: selects which RAM slot holds the raw sensor reading based on
; O2Input (0-3), loads it into A. Case 0 (default, off(003d2h)) presumably a different sensor
; type/location than cases 1-3 (0x0067, 0x03D5, 0x00DA respectively) -- exact sensor identity
; per case not confirmed (would need Rom.cs's O2Input enum values).
                JEQ     o2_sel_case1
                CMPB    A, #002h
                JEQ     o2_sel_case2
                CMPB    A, #003h
                JEQ     o2_sel_case3
                MOV     DP, #003d2h
                SJ      o2_sel_common_read

o2_sel_case1:     MOV     DP, #00067h
                SJ      o2_sel_common_read

o2_sel_case2:     MOV     DP, #003d5h
                SJ      o2_sel_common_read

o2_sel_case3:     MOV     DP, #000dah

o2_sel_common_read:     LB      A, [DP]
                RT

aux_output_pin_clear:     CMPB    A, #008h
; --- Generic auxiliary-output helpers, shared across FANOUT, AltVtec, and the GIOx blocks
; below. Given a physical pin index in A (0-7 = discrete pin, >=8 = no-op/reserved):
;  aux_output_pin_clear: pre-clears that pin's pending-state bit (register array at 0x40E)
;    before the calling feature recomputes its condition this cycle.
;  aux_output_pin_drive (below): given the same pin index plus the feature's computed
;    on/off result in Carry, actually sets or resets that pin's output-drive bit
;    (register array at 0x40F) -- this is what physically turns the pin on/off.
                JGE     aux_output_pin_clear_return
                CLR     X1
                SBR     0040eh[X1]

aux_output_pin_clear_return:     RT

aux_output_pin_drive:     STB     A, r0
                CLR     X1
                MB      PSWL.4, C
                CMPB    A, #008h
                JGE     aux_output_pin_drive_return
                LB      A, r0
                MB      C, PSWL.4
                JGE     aux_output_pin_drive_off
                SBR     0040fh[X1]
                RT

aux_output_pin_drive_off:     RBR     0040fh[X1]

aux_output_pin_drive_return:     RT

crank_cycle_helper1:     MOV     X1, #00409h
; ============================================================================================
; DUAL MAP feature implementation (0x545F onward): connects directly to DuelMapEnable
; DuelMapchkRpm/DuelMapRPM (RPM threshold) or fall through to further TPS/Load checks (not
; shown here) via duelmap_check_input_gate. DuelMapinput/DuelMapinvert (via
; aux_input_bit_select) provide an alternative digital-input-triggered map switch. Result
; ultimately selects which base fuel/ignition table set (Hi vs Lo, primary vs secondary)
; the main calculation cycle uses -- this is the real implementation behind the feature that
; byte 0x619B configures.
; ============================================================================================
                MOV     X2, #00408h
                MOV     er2, #0040eh
                MOV     er3, #0040fh
                CLR     A
                LB      A, ACC
                MOV     DP, X1
                LB      A, [DP]
                ANDB    A, #01fh
                STB     A, [DP]
                CLR     A
                MOV     DP, X2
                LB      A, [DP]
                ANDB    A, #00fh
                STB     A, [DP]
                CLR     A
                MOV     DP, #00410h
                LB      A, [DP]
                ANDB    A, #0c0h
                STB     A, [DP]
                MOV     DP, er3
                STB     A, [DP]
                LCB     A, SecondaryMapsOnly
                JNE     duelmap_secondary_only
                LCB     A, DuelMap
                MB      C, ACC.0
                JLT     DuelMapCondition
                MB      C, ACC.1
                JLT     duelmap_check_input_gate
                SJ      duelmap_result_common

duelmap_secondary_only:     SC
                SJ      duelmap_apply_condition

DuelMapCondition:     LCB     A, DuelMapinvert
                STB     A, r0
                LCB     A, DuelMapinput
                CAL     aux_input_bit_select
                SJ      duelmap_apply_condition

duelmap_check_input_gate:     RC
                LCB     A, DuelMapchkRpm
                JEQ     duelmap_rpm_check
                LC      A, DuelMapRPM
                CMP     0c4h, A
                JGE     duelmap_rpm_result
                SC

duelmap_rpm_check:     LCB     A, DuelMapchkLoad
                JEQ     duelmap_tps_check
                LCB     A, DuelMapLoad
                CMPB    0bbh, A
                JLT     duelmap_rpm_result
                SC

duelmap_tps_check:     LCB     A, DuelMapchkTps
                JEQ     duelmap_apply_condition
                MOV     DP, #003a4h
                LCB     A, DuelMapTPS
                CMPB    [DP], A
                JLT     duelmap_rpm_result
                SC
                SJ      duelmap_apply_condition

duelmap_rpm_result:     RC

duelmap_apply_condition:     MOV     DP, #00409h
                MB      [DP].5, C

duelmap_result_common:     LCB     A, FANChk
; --- Cooling fan control: FANChk gates fan logic entirely; FANOUT selects the output pin
; (via aux_output_pin_clear/fan_output_drive, the same generic aux-output mechanism used
; throughout this file); FANECT/FANVSS (real fields) set ECT and VSS thresholds -- fan runs
; when coolant temp OR vehicle speed condition is met; FANINVERT flips the output polarity.
                JEQ     altvtec_enable_check
                LCB     A, FANOUT
                CAL     aux_output_pin_clear
                LCB     A, FANECT
                CMPB    0d9h, A
                MOV     DP, #00409h
                JGT     fan_condition_fail
                LCB     A, FANVSS
                CMPB    0cch, A
                JGT     fan_condition_fail
                SB      [DP].6
                SC
                LCB     A, FANINVERT
                JEQ     fan_output_drive
                XORB    PSWH, #080h
                SJ      fan_output_drive

fan_condition_fail:     RB      [DP].6
                RC

fan_output_drive:     LCB     A, FANOUT
                CAL     aux_output_pin_drive

altvtec_enable_check:     LCB     A, ALTVtecEnable
                JEQ     gio1_enable_check
                LCB     A, AltVtecOutput
                CAL     aux_output_pin_clear
                MB      C, P1.0
                LCB     A, AltVtecInvert
                JEQ     altvtec_apply_invert
                XORB    PSWH, #080h

altvtec_apply_invert:     LCB     A, AltVtecOutput
                CAL     aux_output_pin_drive

gio1_enable_check:     LCB     A, GIO1Enable
; --- GIO1 auxiliary output logic (GIO2/GIO3 below are identical in structure, different cal
; fields): if GIO1Enable set, selects the output pin (GIO1Output) and pre-clears it, reads the
; configured input pin (GIO1Input/GIO1Invert) via aux_input_bit_select, then -- unless
; GIO1DisableLimiters or (GIO1chkMil and MIL active) block it -- gates the output on RPM/ECT/
; IAT/MAP/VSS/TPS all falling within their Min/Max calibration ranges. If all conditions pass,
; sets the output true (with a chk-maps sub-flag toggling a second bit at 0x409.5, purpose not
; traced), applies GIO1OutInvert, then drives the physical pin via aux_output_pin_drive.
; This is a fully user-configurable auxiliary output channel (e.g. a relay/solenoid driven by
; arbitrary RPM/temp/load/speed/throttle conditions) -- exact real-world function depends on
; how the calibration is set, not fixed in code.
                JEQ     gio1_disabled_skip
                LCB     A, GIO1Output
                CAL     aux_output_pin_clear
                LCB     A, GIO1Invert
                STB     A, r0
                LCB     A, GIO1Input
                CAL     aux_input_bit_select
                MOV     DP, X2
                MB      [DP].4, C
                JGE     gio1_disabled_skip
                LCB     A, GIO1DisableLimiters
                JEQ     gio1_mil_check
                LB      A, ACC
                MOV     DP, X1
                LCB     A, [DP]
                ANDB    A, #005h
                JNE     gio1_conditions_fail

gio1_mil_check:     LCB     A, GIO1chkMil
                JEQ     gio1_rpm_min_check
                MB      C, off(00222h).3
                JLT     gio1_conditions_fail
                SJ      gio1_rpm_min_check

gio1_disabled_skip:     J       gio2_enable_check

gio1_conditions_fail:     SJ       gio1_conditions_fail_clear

gio1_rpm_min_check:     LC      A, GIO1RpmMin
                CMP     0c4h, A
                JGT     gio1_conditions_fail_clear
                LC      A, GIO1RpmMax
                CMP     0c4h, A
                JLT     gio1_conditions_fail_clear
                LCB     A, GIO1EctMin
                CMPB    0d9h, A
                JGT     gio1_conditions_fail_clear
                LCB     A, GIO1EctMax
                CMPB    0d9h, A
                JLT     gio1_conditions_fail_clear
                LCB     A, GIO1IATMin ; was mislabeled GIO1IATMax; operand 0x61BA decodes to GIO1IATMin (byte value was already correct, only the label was stale)
                CMPB    0d8h, A
                JGT     gio1_conditions_fail_clear
                LCB     A, GIO1IATMax
                CMPB    0d8h, A
                JLT     gio1_conditions_fail_clear
                LCB     A, GIO1MapMin
                CMPB    0bbh, A
                JLT     gio1_conditions_fail_clear
                LCB     A, GIO1MapMax
                CMPB    0bbh, A
                JGT     gio1_conditions_fail_clear
                LCB     A, GIO1VSSMin
                CMPB    0cch, A
                JLT     gio1_conditions_fail_clear
                LCB     A, GIO1VSSMax
                CMPB    0cch, A
                JGT     gio1_conditions_fail_clear
                LCB     A, GIO1TPS
                MOV     DP, #003a4h
                CMPB    [DP], A
                JLT     gio1_conditions_fail_clear
                MOV     DP, #00410h
                SB      [DP].0
                LCB     A, GIO1chkMaps
                JEQ     gio1_conditions_pass_maps_done
                MOV     DP, #00409h
                SB      [DP].5

gio1_conditions_pass_maps_done:     SC
                SJ      gio1_apply_invert

gio1_conditions_fail_clear:     RC

gio1_apply_invert:     LCB     A, GIO1OutInvert
                JEQ     gio1_drive_output
                XORB    PSWH, #080h

gio1_drive_output:     LCB     A, GIO1Output
                CAL     aux_output_pin_drive

gio2_enable_check:     LCB     A, GIO2Enable
                JEQ     gio2_disabled_skip
                LCB     A, GIO2Outselect
                CAL     aux_output_pin_clear
                LCB     A, GIO2Ininvert
                STB     A, r0
                LCB     A, GIO2Inselect
                CAL     aux_input_bit_select
                MOV     DP, X2
                MB      [DP].5, C
                JGE     gio2_disabled_skip
                LCB     A, GIO2DisableLimiters
                JEQ     gio2_mil_check
                LB      A, ACC
                MOV     DP, X1
                LCB     A, [DP]
                ANDB    A, #005h
                JNE     gio2_conditions_fail

gio2_mil_check:     LCB     A, GIO2chkMil
                JEQ     gio2_rpm_min_check
                MB      C, off(00222h).3
                JLT     gio2_conditions_fail
                SJ      gio2_rpm_min_check

gio2_disabled_skip:     J       gio3_enable_check

gio2_conditions_fail:     SJ       gio2_conditions_fail_clear

gio2_rpm_min_check:     LC      A, GIO2RpmMin
                CMP     0c4h, A
                JGT     gio2_conditions_fail_clear
                LC      A, GIO2RpmMax
                CMP     0c4h, A
                JLT     gio2_conditions_fail_clear
                LCB     A, GIO2EctMin
                CMPB    0d9h, A
                JGT     gio2_conditions_fail_clear
                LCB     A, GIO2EctMax
                CMPB    0d9h, A
                JLT     gio2_conditions_fail_clear
                LCB     A, GIO2IATMin
                CMPB    0d8h, A
                JGT     gio2_conditions_fail_clear
                LCB     A, GIO2IATMax
                CMPB    0d8h, A
                JLT     gio2_conditions_fail_clear
                LCB     A, GIO2MapMin
                CMPB    0bbh, A
                JLT     gio2_conditions_fail_clear
                LCB     A, GIO2MapMax
                CMPB    0bbh, A
                JGT     gio2_conditions_fail_clear
                LCB     A, GIO2VSSMin
                CMPB    0cch, A
                JLT     gio2_conditions_fail_clear
                LCB     A, GIO2VSSMax
                CMPB    0cch, A
                JGT     gio2_conditions_fail_clear
                LCB     A, GIO2TPS
                MOV     DP, #003a4h
                CMPB    [DP], A
                JLT     gio2_conditions_fail_clear
                MOV     DP, #00410h
                SB      [DP].1
                LCB     A, GIO2chkMaps
                JEQ     gio2_conditions_pass_maps_done
                MOV     DP, #00409h
                SB      [DP].5

gio2_conditions_pass_maps_done:     SC
                SJ      gio2_apply_invert

gio2_conditions_fail_clear:     RC

gio2_apply_invert:     LCB     A, GIO2Outinvert
                JEQ     gio2_drive_output
                XORB    PSWH, #080h

gio2_drive_output:     LCB     A, GIO2Outselect
                CAL     aux_output_pin_drive

gio3_enable_check:     LCB     A, GIO3Enable
                JEQ     gio3_disabled_skip
                LCB     A, GIO3Outselect
                CAL     aux_output_pin_clear
                LCB     A, GIO3Ininvert
                STB     A, r0
                LCB     A, GIO3Inselect
                CAL     aux_input_bit_select
                MOV     DP, X2
                MB      [DP].6, C
                JGE     gio3_disabled_skip
                LCB     A, GIO3DisableLimiters
                JEQ     gio3_mil_check
                LB      A, ACC
                MOV     DP, X1
                LCB     A, [DP]
                ANDB    A, #005h
                JNE     gio3_conditions_fail

gio3_mil_check:     LCB     A, GIO3chkMil
                JEQ     gio3_rpm_min_check
                MB      C, off(00222h).3
                JLT     gio3_conditions_fail
                SJ      gio3_rpm_min_check

gio3_disabled_skip:     J       manualboost_input_check

gio3_conditions_fail:     SJ       gio3_conditions_fail_clear

gio3_rpm_min_check:     LC      A, GIO3RpmMin
                CMP     0c4h, A
                JGT     gio3_conditions_fail_clear
                LC      A, GIO3RpmMax
                CMP     0c4h, A
                JLT     gio3_conditions_fail_clear
                LCB     A, GIO3EctMin
                CMPB    0d9h, A
                JGT     gio3_conditions_fail_clear
                LCB     A, GIO3EctMax
                CMPB    0d9h, A
                JLT     gio3_conditions_fail_clear
                LCB     A, GIO3IATMin
                CMPB    0d8h, A
                JGT     gio3_conditions_fail_clear
                LCB     A, GIO3IATMax
                CMPB    0d8h, A
                JLT     gio3_conditions_fail_clear
                LCB     A, GIO3MapMin
                CMPB    0bbh, A
                JLT     gio3_conditions_fail_clear
                LCB     A, GIO3MapMax
                CMPB    0bbh, A
                JGT     gio3_conditions_fail_clear
                LCB     A, GIO3VSSMin
                CMPB    0cch, A
                JLT     gio3_conditions_fail_clear
                LCB     A, GIO3VSSMax
                CMPB    0cch, A
                JGT     gio3_conditions_fail_clear
                LCB     A, GIO3TPS
                MOV     DP, #003a4h
                CMPB    [DP], A
                JLT     gio3_conditions_fail_clear
                MOV     DP, #00410h
                SB      [DP].2
                LCB     A, GIO3chkMaps
                JEQ     gio3_conditions_pass_maps_done
                MOV     DP, #00409h
                SB      [DP].5

gio3_conditions_pass_maps_done:     SC
                SJ      gio3_apply_invert

gio3_conditions_fail_clear:     RC

gio3_apply_invert:     LCB     A, GIO3Outinvert
                JEQ     gio3_drive_output
                XORB    PSWH, #080h

gio3_drive_output:     LCB     A, GIO3Outselect
                CAL     aux_output_pin_drive

manualboost_input_check:     LCB     A, ManualBstInput1invert
                STB     A, r0
                LCB     A, ManualBstInput1
                CAL     aux_input_bit_select
                MOV     DP, X2
                MB      [DP].7, C
                JGE     manualboost_result_jump
                LCB     A, Stage2on
                CAL     aux_output_pin_clear
                LCB     A, Stage3on
                CAL     aux_output_pin_clear
                LCB     A, Stage4on
                CAL     aux_output_pin_clear
                LCB     A, ManualBstchkFtl
                JEQ     manualboost_mil_check
                LB      A, ACC
                MOV     DP, X1
                LCB     A, [DP]
                ANDB    A, #005h
                JNE     manualboost_result_jump

manualboost_mil_check:     LCB     A, ManualBstchkMil
                JEQ     manualboost_table_lookup
                MB      C, off(00222h).3
                JLT     manualboost_result_jump

manualboost_result_jump:     SJ       iab_check_start

manualboost_table_lookup:     LC      A, ManualBst1
                CMP     0c4h, A
                JGT     iab_check_start
                LCB     A, ManualBst2
                MOV     DP, #003a4h
                CMPB    [DP], A
                JLT     iab_check_start
                LCB     A, ManualBst3
                CMPB    0d9h, A
                JGT     iab_check_start
                MOV     DP, #00409h
                SB      [DP].7
                LCB     A, Stage2Vss
                CMPB    0cch, A
                JLT     iab_check_start
                MOV     DP, #00410h
                SB      [DP].3
                SC
                LCB     A, Stage2on
                CAL     aux_output_pin_drive
                LCB     A, Stage3Vss
                JEQ     iab_check_start
                CMPB    0cch, A
                JLT     iab_check_start
                MOV     DP, #00410h
                SB      [DP].4
                SC
                LCB     A, Stage3on
                CAL     aux_output_pin_drive
                LCB     A, Stage4Vss
                JEQ     iab_check_start
                CMPB    0cch, A
                JLT     iab_check_start
                MOV     DP, #00410h
                SB      [DP].5
                SC
                LCB     A, Stage3on
                CAL     aux_output_pin_drive

iab_check_start:     LCB     A, IABCheck
                JEQ     ebc_pwm_invert_check
                LCB     A, IABSelection
                CAL     aux_output_pin_clear
                LCB     A, IABValues
                JBR     off(002eeh).2, iab_output_compare
                LCB     A, IABSetRPM

iab_output_compare:     CMPB    off(00236h), A
                LCB     A, IABInvert
                JEQ     iab_output_invert
                XORB    PSWH, #080h

iab_output_invert:     LCB     A, IABoutinvert
                JEQ     iab_selection_check
                XORB    PSWH, #080h

iab_selection_check:     LCB     A, IABSelection
                CAL     aux_output_pin_drive

ebc_pwm_invert_check:     LCB     A, EBCPWMInvert
                STB     A, r0
                LCB     A, EBCPWM
                JEQ     gio2_output_prep
                CAL     aux_input_bit_select
                MOV     DP, #00408h
                MB      [DP].2, C
                JGE     gio2_output_prep
                LCB     A, EBCPWMhiInvert
                STB     A, r0
                LCB     A, EBCPWMhi
                RC
                JEQ     gio1_output_prep
                CAL     aux_input_bit_select

gio1_output_prep:     MB      PSWL.5, C
                MB      [DP].3, C
                LCB     A, DuelMapEnable
                JNE     gio3_output_prep
                INC     DP
                MB      C, [DP].3
                JLT     gio2_output_prep
                MOV     DP, #00410h
                MB      C, [DP].7
                JGE     gio3_output_prep

gio2_output_prep:     MOV     DP, #00409h
                RB      [DP].4
                SB      PSWL.4
                CLRB    A
                MOV     DP, #0041ah
                STB     A, [DP]
                SJ      ebc_output_store

gio3_output_prep:     RB      PSWL.4
                LCB     A, EBCMapActive
                CMPB    A, 0bbh
                MOV     DP, #00409h
                MB      [DP].4, C
                JGE     ebc_fastspool_disable
                LCB     A, bstTargetMode
                JEQ     ebc_wastegate_source_check
                SB      PSWL.4
                SJ      ebc_output_store

ebc_wastegate_source_check:     LCB     A, EBCWasteGate
; --- Electronic boost control / wastegate PWM duty-cycle calculation (0x58C2-0x59FE):
; 1. ebc_wastegate_source_check/fastspool/output_store: selects wastegate-PWM source and
;    handles FastSpool override.
; 2. boost_rpm_mode_check/gear_table_select/rpmgear_table_select/target_interp: computes the
;    base target boost (WGGearLow/WGGearHi tables by gear, or wastegateRPM/wastegateGEAR by
;    RPM+gear via table_interp_lookup) depending on bstRPMMode.
; 3. boost_error_calc: compares target against actual (0xBB, presumably current MAP/boost
;    reading) to get an error term.
; 4. boost_openloop_pwm/closeloop_check/deadband_check/overshoot_trim/undershoot_check/
;    undershoot_trim: applies closed-loop PWM correction (bstCloseLoop/bstDeadBand/
;    bstOvershootSens/bstUndershootSen) via wgcloselooppw/WastegateCloseLoop tables, gated by
;    bstCloseLoopmin.
; 5. boost_iat_gio_trim: additional IAT (wastegateIAT) and GIOAdjustment1 trim correction.
; 6. boost_pwm_clamp: final clamp to bstPWMMin/bstPWMMax.
; 7. boost_dial_multi_trim (0x59FF, called separately): driver-adjustable bstDial knob applies
;    a further WastegateMulti2/WastegateMulti scaling on top of the above.
; Math/clamp helpers clamp_centered_0x80 and mul_scale_clamp are small generic arithmetic
; utilities, not boost-specific (verify other callers before assuming boost-only meaning).
                CMPB    0bbh, A
                JGT     boost_rpm_mode_check
                LCB     A, FastSpool
                SB      PSWL.4
                SJ      ebc_output_store

ebc_fastspool_disable:     SB      PSWL.4
                CLRB    A

ebc_output_store:     MOV     DP, #0041bh
                STB     A, [DP]
                MB      C, PSWL.4
                JGE     boost_rpm_mode_check
                J       boost_output_disabled_path

boost_rpm_mode_check:     LCB     A, bstRPMMode
                JNE     boost_rpmgear_table_select
                CLR     A
                MOV     X1, #WGGearHi
                MB      C, PSWL.5
                JLT     boost_gear_table_select
                MOV     X1, #WGGearLow

boost_gear_table_select:     LB      A, ACC
                LB      A, off(0024fh)
                ADD     X1, A
                LCB     A, [X1]
                SJ      boost_target_store

boost_rpmgear_table_select:     MOV     X1, #wastegateGEAR
                MB      C, PSWL.5
                JLT     boost_target_interp
                MOV     X1, #wastegateRPM

boost_target_interp:     LB      A, 0c2h
                CAL     table_interp_lookup

boost_target_store:     MOVB    r3, A
                CAL     boost_dial_multi_trim
                LB      A, r3
                MOV     DP, #0041ah
                STB     A, [DP]
                SUBB    A, 0bbh
                MB      PSWL.5, C
                JGE     boost_error_calc
                XORB    A, #0ffh
                ADDB    A, #001h

boost_error_calc:     STB     A, r4
                MOV     DP, #0041ah
                LB      A, [DP]
                MOV     X1, #WasteGateLookup
                CAL     table_interp_lookup
                MOV     DP, #0041bh
                STB     A, [DP]
                STB     A, r5
                SJ      boost_closeloop_check

boost_openloop_pwm:     LB      A, #080h
                SJ      boost_pwm_store

boost_closeloop_check:     LCB     A, bstCloseLoop
                JNE     boost_openloop_pwm
                MB      C, PSWL.5
                JLT     boost_deadband_check
                LCB     A, bstDeadBand
                CMPB    A, r4
                JLE     boost_openloop_pwm

boost_deadband_check:     MOV     DP, #0041dh
                MB      C, PSWL.5
                JLT     boost_undershoot_check
                LB      A, (001bah-00180h)[USP]
                JEQ     boost_overshoot_trim
                SJ      boost_pwm_finalize

boost_overshoot_trim:     LCB     A, bstOvershootSens
                STB     A, (001bah-00180h)[USP]
                LB      A, r4
                MOV     X1, #wgcloselooppw
                CAL     table_interp_lookup
                STB     A, r4
                LCB     A, bstCloseLoopmin
                STB     A, r0
                LB      A, [DP]
                ADDB    A, r4
                CMPB    A, r0
                JLE     boost_pwm_store
                LB      A, r0
                SJ      boost_pwm_store

boost_undershoot_check:     LB      A, (001cdh-00180h)[USP]
                JEQ     boost_undershoot_trim
                SJ      boost_pwm_finalize

boost_undershoot_trim:     LCB     A, bstUndershootSen
                STB     A, (001cdh-00180h)[USP]
                LB      A, r4
                MOV     X1, #WastegateCloseLoop
                CAL     table_interp_lookup
                STB     A, r4
                LCB     A, BoostLimitMode1
                STB     A, r0
                LB      A, [DP]
                SUBB    A, r4
                CMPB    A, r0
                JGE     boost_pwm_store
                LB      A, r0
                SJ      boost_pwm_store

boost_pwm_store:     MOV     DP, #0041dh
                STB     A, [DP]

boost_pwm_finalize:     SCAL    boost_iat_gio_trim
                SCAL    boost_pwm_clamp

boost_output_disabled_path:     MOV     DP, #0041ch
                STB     A, [DP]
                L       A, ACC
                MOV     X1, #tbl_boost_pwm_disabled
                VCAL    0
                MOV     er0, A
                LC      A, bstPWMHZ
                CAL     mul_scale_clamp
                MOV     DP, #0040ah
                ST      A, [DP]
                SJ       boostdial_multi_gate
;@ tbl_boost_pwm_disabled type=u8 count=9 formula=raw category=Boost desc="9 bytes"
tbl_boost_pwm_disabled:       DB  0FFh,000h,080h,0C8h,000h,080h,000h,000h
                DB  000h

boost_iat_gio_trim:     MOVB    r0, r5
                MOVB    r3, r0
                MOV     DP, #0041dh
                LB      A, [DP]
                MOVB    r3, r0
                CAL     clamp_centered_0x80
                MOVB    r3, r0
                LB      A, 0d8h
                MOV     X1, #wastegateIAT
                CAL     table_interp_lookup
                MOVB    r0, r3
                CAL     clamp_centered_0x80
                MOVB    r3, r0
                LB      A, 0c2h
                MOV     X1, #GIOAdjustment1
                CAL     table_interp_lookup
                MOVB    r0, r3
                CAL     clamp_centered_0x80
                RT

boost_pwm_clamp:     LCB     A, bstPWMMin
                STB     A, r1
                LCB     A, bstPWMMax
                STB     A, r2
                LB      A, r0
                JEQ     boostdial_return
                CMPB    A, r1
                JGE     boostdial_result_check
                LB      A, r1
                SJ      boostdial_return

boostdial_result_check:     CMPB    A, r2
                JLE     boostdial_return
                LB      A, r2

boostdial_return:     RT

boost_dial_multi_trim:     LB      A, ACC
                LCB     A, bstDial
                CAL     indexed_ram_selector_0to3
                MOV     X1, #WastegateMulti2
                CAL     table_interp_lookup
                MOVB    r0, A
                LB      A, r3
                CAL     mulb_scale_clamp
                MOVB    r3, A
                MOV     DP, #003a4h
                LB      A, [DP]
                MOV     X1, #WastegateMulti
                CAL     table_interp_lookup
                MOVB    r0, r3
                CAL     mulb_scale_clamp
                MOVB    r3, A
                RT

boostdial_multi_gate:     SC
                LCB     A, DisableStarterIN
                JNE     boostdial_flag_219_6
                MOV     DP, #00420h
                MB      C, [DP].2
                JLT     boostdial_flag_219_6
                MB      C, off(00211h).0

boostdial_flag_219_6:     MB      off(00219h).6, C
                LB      A, ACC
                CLRB    r0
                LCB     A, SCCInput
                CAL     aux_input_bit_select
                LCB     A, SCCInvert
                JEQ     boostdial_flag_221_6
                XORB    PSWH, #080h

boostdial_flag_221_6:     MB      off(00221h).6, C
                JLT     mil_blink_check_gate
                JBR     off(00217h).5, mil_blink_check_gate
                MOV     DP, #003a4h
                LB      A, [DP]
                CMPB    A, #07fh
                XORB    PSWH, #080h
                MB      off(00221h).6, C
                JGE     mil_blink_check_gate
                JBR     off(00211h).4, mil_blink_check_gate
                MOV     DP, #0031eh
                CLR     A
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]

mil_blink_check_gate:     LB      A, off(002c6h)
; --- MIL blink-count tracking: off(002c6h) here is a "protection event active" gate (skip if
; nonzero), and MILFlashCount (real calibration field) caps a per-code blink counter at
; 0x413[offset]. NOTE: off(002c6h) is a generic reused scratch byte, not dedicated to this
; routine -- it's also written by fuel-pump relay control (~0x3E03) and by the LeanProtect
; routine below (leanprotect_trigger_common) with different meanings each time. Read each use
; site's own logic; don't assume a single global identity for this byte.
                JNE     mil_blink_return
                MOV     X1, #00413h
                JBR     off(00217h).5, mil_blink_return
                LCB     A, MILFlashCount
                MOVB    r0, A
                MOV     DP, X1
                LB      A, [DP]
                CMPB    A, r0
                JGE     mil_blink_return
                MOVB    off(002c6h), #004h
                INCB    [DP]


mil_blink_return:     RT

leanprotect_rpm_gate:     L       A, ACC
; --- LeanProtect (0x5A8E-0x5B44): a two-stage lean-condition protection, confirmed via
; LeanProMinRpm/LeanProMinTps gating entry, then two near-identical independently-timed checks
; (Lean1: LeanProcheck1/LeanProlean1Map/LeanProLean1AfrVolt/LeanProLean1Tmr; Lean2: same
; pattern with check2/lean2Map/Lean2AfrVolt/Lean2Tmr) -- if MAP and AFR-voltage both indicate
; a lean condition, a countdown timer (0x41E for stage 1, 0x41F for stage 2) decrements each
; call; hitting zero triggers leanprotect_trigger_common (sets off(00410h).7 and calls
; leanprotect_trigger_common twice via SCAL).
; -- leanprotect_lean2_reset_timer is the target that fix corrected the branch to reach.
                CLR     X1
                MOV     DP, #00410h
                LC      A, LeanProMinRpm
                CMP     0c4h, A
                JGT     leanprotect_timer_defaults
                LB      A, ACC
                LCB     A, LeanProMinTps
                MOV     DP, #003a4h
                CMPB    [DP], A
                JLT     leanprotect_timer_defaults
                MOV     DP, #00410h
leanprotect_backref_m2        EQU     $-2
                MB      C, [DP].7
                JGE     leanprotect_check1_start
                CAL     leanprotect_trigger_common
                J       leanprotect_return

leanprotect_timer_defaults:     LB      A, ACC
                LCB     A, LeanProLean1Tmr
                STB     A, 0041eh[X1]
                LCB     A, LeanProLean2Tmr
                STB     A, 0041fh[X1]
                MOV     DP, #00410h
                RB      [DP].7
                SJ      leanprotect_return

leanprotect_check1_start:     LB      A, ACC
                LCB     A, LeanProcheck1
                JEQ     leanprotect_check2_start
                LCB     A, LeanProlean1Map
                CMPB    0bbh, A
                JLT     leanprotect_lean1_reset_timer
                LCB     A, LeanProLean1AfrVolt
                CMPB    0dah, A
                JLT     leanprotect_lean1_reset_timer
                LB      A, ACC
                MOV     DP, #0041eh
                LB      A, [DP]
                JEQ     leanprotect_lean1_trigger
                DECB    [DP]
                SJ      leanprotect_check2_start

leanprotect_lean1_trigger:     MOV     DP, #00410h
                SB      [DP].7
                SCAL    leanprotect_trigger_common
                SJ      leanprotect_check2_start

leanprotect_lean1_reset_timer:     LB      A, ACC
                LCB     A, LeanProLean1Tmr
                STB     A, 0041eh[X1]

leanprotect_check2_start:     LB      A, ACC
                LCB     A, LeanProcheck2
                JEQ     leanprotect_return
                LCB     A, LeanProlean2Map
                CMPB    0bbh, A
                JLT     leanprotect_lean2_reset_timer ; ;operand was E6 (-26), which actually branches backward into leanprotect_lean1_reset_timer instead of forward to leanprotect_lean2_reset_timer as labeled/intended (LeanProtect2 bug per Rom.cs); corrected to 1E (+30) to reach leanprotect_lean2_reset_timer, matching the analogous check at 5B1F
                LCB     A, LeanProLean2AfrVolt
                CMPB    0dah, A
                JLT     leanprotect_lean2_reset_timer
                LB      A, ACC
                MOV     DP, #0041fh
                LB      A, [DP]
                JEQ     leanprotect_lean2_trigger
                DECB    [DP]
                SJ      leanprotect_return

leanprotect_lean2_trigger:     MOV     DP, #00410h
                SB      [DP].7
                SCAL    leanprotect_trigger_common
                SJ      leanprotect_return

leanprotect_lean2_reset_timer:     LB      A, ACC
                LCB     A, LeanProLean2Tmr
                STB     A, 0041fh[X1]

leanprotect_return:     RT

leanprotect_trigger_common:     MOVB    off(002c6h), #001h
                RT

doubleup_limiter_target:     MOV     X1, #00409h
                MOV     X2, #00410h
                L       A, ACC
                L       A, off(00192h)
                MOV     er0, A
                LC      A, FTLDelay
                MOV     er2, A
                MOV     DP, #00415h
                L       A, [DP]
                ST      A, er1
                MOV     DP, X1
                MB      C, [DP].3
                L       A, #003a9h
                JLT     dult_clamp_min
                MB      C, [DP].0
                L       A, er1
                JLT     dult_clamp_min
                MB      C, [DP].2
                L       A, er1
                JLT     dult_clamp_min
                MOV     DP, X2
                MB      C, [DP].6
                LC      A, ECTProtectionTable
                JLT     dult_clamp_min
                MB      C, [DP].7
                LC      A, LeanProMinRpm
                JLT     dult_clamp_min
                MOV     DP, #00427h
                MB      C, [DP].1
                LC      A, CYPCount
                JLT     dult_clamp_min
                MOV     DP, off(00194h)
                L       A, off(00192h)
                RT

dult_clamp_min:     CMP     A, er0
                JGT     dult_add_delay_exit
                L       A, er0

dult_add_delay_exit:     L       A, ACC
                MOV     DP, A
                ADD     A, er2
                XCHG    A, DP
                RT

ectboostcut_check_start:     MOV     X1, #00409h
; --- ECT-based boost-cut safety (0x5B9D-0x5BFD): if coolant temp (0xD9) exceeds
; ECTProtectC (gated by ECTProtectChk), sets an ECT-overheat flag (off(00410h).6). Separately,
; if BoostchkEnable is set, gates a boost cut (off(00410h).3) on RPM > 0x3A9, TPS > 0x60,
; and coolant temp vs BoostCutECT (using ctrlBoostCutCold/ctrlBoostCutHot MAP thresholds
; depending which side of BoostCutECT the engine is on) -- unless BoostcutOnMil overrides via
; the MIL-active flag (off(00222h).3). Straightforward and high-confidence: an overheat-based
; boost cut with a MIL-active override.
                MOV     X2, #00408h
                MOV     DP, #00410h
                LCB     A, ECTProtectChk
                JEQ     ectboostcut_flag_clear
                LCB     A, ECTProtectC
                CMPB    0d9h, A
                JGE     ectboostcut_flag_clear
                SB      [DP].6
                 SJ      boostcut_enable_check

ectboostcut_flag_clear:     RB      [DP].6

boostcut_enable_check:     MOV     DP, X1
                LCB     A, BoostchkEnable
                JEQ     boostcut_flag_clear
                LCB     A, BoostcutOnMil
                JEQ     boostcut_rpm_check
                JBS     off(00222h).3, boostcut_trigger

boostcut_rpm_check:     L       A, #003a9h
                CMP     0c4h, A
                JGT     boostcut_flag_clear
                LB      A, #060h
                CMPB    0d1h, A
                JLT     boostcut_flag_clear
                MOV     DP, X1
                MB      C, [DP].3
                JLT     boostcut_return
                LCB     A, BoostCutECT
                CMPB    0d9h, A
                LCB     A, ctrlBoostCutCold
                JGT     boostcut_map_check
                LCB     A, ctrlBoostCutHot

boostcut_map_check:     CMPB    0bbh, A
                JLT     boostcut_flag_clear

boostcut_trigger:     SB      [DP].3
                SJ      boostcut_return

boostcut_flag_clear:     RB      [DP].3

boostcut_return:     RT

burnout_input_check:     LCB     A, BURNOUTINVERT
; --- Burnout mode + FTL (Flat/Fuel Torque Limiter) entry (0x5BFE-0x5C79+). BURNOUT input pin
; (via aux_input_bit_select, inverted by BURNOUTINVERT) gates a burnout-mode flag and loads
; BURNOUTRPM as the active limiter target; otherwise falls into FTLFunction, which reads its
; own enable input (FTLInput/FTLInvert), an RPM gate (FTLRPM), and mode select (FTLMode),
; eventually feeding the BoostLimitMode1/FTLRPM2/FTLRPMTable/FTLDelay fields seen earlier in
; the boost-control block -- this is the enable/mode-selection front-end for that limiter.
                ST      A, er0
                LCB     A, BURNOUT
                CAL     aux_input_bit_select
                MOV     DP, X2
                JGE     FTLFunction
                CMPB    0cch, #000h
                JGT     ftl_disabled_exit
                MOV     DP, X1
                L       A, ACC
                SB      [DP].0
                SB      [DP].2
                LC      A, BURNOUTRPM
                MOV     DP, #00415h
                ST      A, [DP]
                J       limiter_target_apply

ftl_disabled_exit:     J       ftl_antilag_common

FTLFunction:     LCB     A, FTLInvert
                ST      A, er0
                LCB     A, FTLInput
                CAL     aux_input_bit_select
                MOV     DP, X2
                MB      [DP].0, C
                JGE     ftl_disabled_exit
                LCB     A, FTLRPM
                CMPB    0cch, A
                JGE     ftl_disabled_exit
                LCB     A, FTLMode
                JNE     ftl_rpm_mode_check
                L       A, ACC
                MOV     DP, X1
                MB      C, [DP].0
                JLT     ftl_tps_low_range_check
                LC      A, FTLTPSMin
                ADD     A, #0000ah
                CMP     0c4h, A
                JGE     ftl_antilag_common
                SB      [DP].0
                LC      A, FTLTPSMin
                MOV     DP, #00415h
                ST      A, [DP]
                SJ      antilag_input_check

ftl_tps_low_range_check:     LC      A, FTLTPSMin
                ADD     A, #00060h
                CMP     0c4h, A
                JGE     ftl_antilag_common
                SJ      antilag_input_check

ftl_rpm_mode_check:     MOV     DP, X1
                MB      C, [DP].0
                JLT     ftl_tps_disp_check
                LC      A, FTLRPMMin
                CMP     0c4h, A
                JGE     ftl_antilag_common
                LCB     A, FTLTPSThresh
                CMPB    A, 0d1h
                MB      [DP].0, C
                JGE     ftl_antilag_common
                J       limiter_target_apply

ftl_tps_disp_check:     LCB     A, FTLTPSDisp
                CMPB    0d1h, A
                JLE     ftl_antilag_common

antilag_input_check:     LB      A, ACC
; --- Anti-lag input handling: EnableAntiLag gates reading the anti-lag activation input
; (AntiLageByte/AntiLag0Byte via aux_input_bit_select), with an AntiLagTPS threshold check
; when VSS (0xCC) is 0. Merges with the FTL (Flat/Fuel Torque Limiter) path above at
; ftl_antilag_common.
                LCB     A, EnableAntiLag
                JEQ     antilag_disabled_exit
                LCB     A, AntiLageByte
                STB     A, r0
                LCB     A, AntiLag0Byte
                CAL     aux_input_bit_select
                JGE     antilag_flag_clear
                CMPB    0cch, #000h
                JGT     antilag_flag_clear
                LCB     A, AntiLagTPS
                CMPB    A, 0d1h
                MOV     DP, X1
                MB      [DP].1, C
                SJ      limiter_target_apply

antilag_disabled_exit:     SJ       limiter_target_apply

antilag_flag_clear:     MOV     DP, X1
                RB      [DP].1
                SJ      limiter_target_apply

ftl_antilag_common:     MOV     DP, X1
                RB      [DP].0
                MB      C, [DP].2
                JLT     fts_ftl_input_check
                RB      [DP].1

fts_ftl_input_check:     LCB     A, FTSInvert
; --- FTL (Flat/Fuel Torque Limiter) RPM target calculation: FTL input enable gates an RPM
; threshold (FTLRPM2) and VSS threshold (FTSVSS) check, then GearBasedLimiter selects between
; a flat FTLRPMTable value or a per-gear FTLRPMTable[gear] lookup. FTSMode gates whether the
; result is actually applied. limiter_target_apply (0x5D3C) is the SHARED exit used by
; burnout/FTL/anti-lag alike: stores the winning target into off(00415h) -- the single
; "currently active RPM-based limiter target" register -- defaulting to current RPM if none of
; the above set it. limiter_flags_clear_all fully resets this state when no limiter applies.
                ST      A, er0
                LCB     A, FTL
                CAL     aux_input_bit_select
                MOV     DP, X2
                MB      [DP].1, C
                JGE     limiter_flags_clear_all
                LCB     A, FTLRPM2
                CMPB    0d1h, A
                JLE     limiter_flags_clear_all
                LCB     A, FTSVSS
                CMPB    0cch, A
                JLE     limiter_flags_clear_all
                LCB     A, GearBasedLimiter
                JNE     ftl_rpm_table_gear_lookup
                LC      A, FTLRPMTable
                SJ      ftl_rpm_check

ftl_rpm_table_gear_lookup:     CLR     A
                LB      A, off(0024fh)
                L       A, ACC
                SLL     A
                LC      A, FTLRPMTable[ACC]

ftl_rpm_check:     MOV     DP, X1
                MB      C, [DP].2
                JLT     ftl_flag_check2
                CMP     0c4h, A
                MB      [DP].2, C
                JGT     limiter_flags_clear_all

ftl_flag_check2:     L       A, ACC
                ST      A, er0
                LCB     A, tbl_ftl_rpm_alt
                JEQ     ftl_mode_check
                MOV     DP, X1
                SB      [DP].1

ftl_mode_check:     LCB     A, FTSMode
                JNE     limiter_target_apply
                L       A, er0
                MOV     DP, #00415h
                ST      A, [DP]
                RT

limiter_target_apply:     MOV     DP, #00415h
                L       A, [DP]
                JNE     limiter_target_return
                L       A, 0c4h
                ST      A, [DP]

limiter_target_return:     RT

limiter_flags_clear_all:     MOV     DP, X1
                RB      [DP].0
                RB      [DP].1
                RB      [DP].2
                MOV     DP, #00415h
                CLR     [DP]
                RT

mode_flag_409_5_check:     MOV     DP, #00409h
                MB      C, [DP].5
                RT

loadindex_bit_dispatch:     SCAL    mode_flag_409_5_check
                JLT     loadindex_bit_dispatch_alt
                LCB     A, LoadIndex
                MB      C, ACC.0
                JLT     loadindex_use_0x426
                MB      C, ACC.1
                JLT     loadindex_use_tps_alt
                SJ      loadindex_use_map

loadindex_bit_dispatch_alt:     LCB     A, LoadIndex
                MB      C, ACC.2
                JLT     loadindex_use_0x426
                MB      C, ACC.3
                JLT     loadindex_use_tps_alt
                SJ      loadindex_use_map

loadindex_use_map:     LB      A, 0bbh
                SJ      loadindex_store_0x425

loadindex_use_tps_alt:     MOV     DP, #003a4h
                LB      A, [DP]
                SJ      loadindex_store_0x425

loadindex_use_0x426:     MOV     DP, #00426h
                LB      A, [DP]

loadindex_store_0x425:     MOV     DP, #00425h
                STB     A, [DP]
                RT

shiftlight_check_start:     JBS     off(00221h).6, shiftlight_return
; --- MIL shift-light (0x5D91-0x5DCC): if enabled (MILShiftLight) and MIL-active-gated
; (off(00222h).3), compares RPM against a target (MILShiftLightRPM), either flat or
; per-gear (MILShiftLightGear selects MILShiftLightRPM[gear]) via shiftlight_rpm_gear_lookup,
; driving P1.4 as the shift-light/MIL-blink output.
                MOV     DP, #0040eh
                MB      C, [DP].4
                JGE     shiftlight_mil_gate
                INC     DP
                MB      C, [DP].4
                SJ      shiftlight_output_drive

shiftlight_mil_gate:     MB      C, off(00222h).3
                JLT     shiftlight_output_drive
                LCB     A, MILShiftLight
                JEQ     shiftlight_output_drive
                LCB     A, MILShiftLightGear
                JNE     shiftlight_rpm_gear_lookup
                CLR     A
                LC      A, MILShiftLightRPM
                CMP     0c4h, A
                SJ      shiftlight_output_drive

shiftlight_rpm_gear_lookup:     CLR     A
                LB      A, off(0024fh)
                L       A, ACC
                SLL     A
                LC      A, MILShiftLightRPM[ACC]
                CMP     0c4h, A

shiftlight_output_drive:     MB      P1.4, C

shiftlight_return:     RT

ictimemod_check_start:     LCB     A, ICTimeMod
; --- Ignition-Cut Timing Modifier (ICTimeMod, 0x5DCD onward): this is the routine behind the
; igntiming_icfuelmod_check/fuel_icfuelmod_check calls seen earlier -- when active, dispatches
; through a state machine (off(00437h), counter off(00438h)) with states handled at
; ictimemod_state0/ictimemod_state1/ictimemod_state_reset, apparently blending ignition-cut behavior with TPS
; (0xD1) and RPM-based conditions. ReturnMainThread (already-named real label) is a shared
; "bail out to the main loop" exit reused across several routines, not specific to this one.
                JEQ     ictimemod_counter_check
                RT

ictimemod_counter_check:     CLR     X1
                LB      A, 00438h[X1]
                JEQ     ictimemod_state_dispatch
                DECB    00438h[X1]

ictimemod_state_dispatch:     LB      A, 00437h[X1]
                CMPB    A, #000h
                JEQ     ictimemod_state0
                CMPB    A, #001h
                JEQ     ictimemod_state1
                SJ      ictimemod_state_reset

ictimemod_state0:     CMPB    0d1h, #01dh
                JLT     ictimemod_common_exit
                MOV     DP, #000e6h
                L       A, [DP]
                JNE     postcycle_dp_setup
                SJ      ReturnMainThread

postcycle_dp_setup:     MOV     DP, #00409h
                MB      C, [DP].1
                JGE     MainIGNDelay
                MB      C, [DP].0
                JLT     LaunchIGNDelay
                MB      C, [DP].2
                JLT     FTSIGNDelay
                SJ      MainIGNDelay

MainIGNDelay:     LCB     A, IGNCDelay
                SJ      IgnitionCutDelays

LaunchIGNDelay:     LCB     A, LCDelay
                SJ      IgnitionCutDelays

FTSIGNDelay:     LCB     A, FTSDelay
                SJ      IgnitionCutDelays

IgnitionCutDelays:     ST      A, 00438h[X1]
                MOVB    00437h[X1], #001h
                SJ      ReturnMainThread

ictimemod_state1:     LB      A, 00438h[X1]
                JNE     ReturnMainThread
                MOVB    00437h[X1], #002h
                LB      A, #001h
                STB     A, 00438h[X1]
                SJ      ictimemod_common_exit

ictimemod_state_reset:     LB      A, 00438h[X1]
                JNE     ictimemod_common_exit
                MOVB    00437h[X1], #000h



ictimemod_common_exit:     MOV     DP, #000e6h
                RB      [DP].0
                SJ      ReturnMainThread

ReturnMainThread:     RT

lowpower_abort_cond_scan:     CLR     A
                CLR     X1
                LCB     A, CKPCount            ; master enable byte (0x61E3); 0 = feature disabled
                JEQ     lowpower_cond_exit
                MOV     DP, #00427h
                MB      C, [DP].0              ; re-entry guard: already latched this pass?
                JLT     lowpower_cond_exit
                SB      [DP].0
                SJ      lowpower_cond1_check

lowpower_cond1_check:     LCB     A, SpareCalByte1
                JEQ     lowpower_cond2_check
                SRA     A
                JLT     lowpower_cond1_alt
                JBS     off(00211h).2, lowpower_cond_trigger
                SJ      lowpower_cond2_check

lowpower_cond1_alt:     JBR     off(00211h).2, lowpower_cond_trigger

lowpower_cond2_check:     LCB     A, SpareCalByte2
                JEQ     lowpower_cond3_check
                SRA     A
                JLT     lowpower_cond2_alt
                JBS     off(00210h).3, lowpower_cond_trigger
                SJ      lowpower_cond3_check

lowpower_cond2_alt:     JBR     off(00210h).3, lowpower_cond_trigger

lowpower_cond3_check:     LCB     A, SpareCalByte3
                JEQ     lowpower_cond4_check
                SRA     A
                JLT     lowpower_cond3_alt
                JBS     off(00210h).7, lowpower_cond_trigger
                SJ      lowpower_cond4_check

lowpower_cond3_alt:     JBR     off(00210h).7, lowpower_cond_trigger

lowpower_cond4_check:     LCB     A, SpareCalByte4
                JEQ     lowpower_cond5_check
                SRA     A
                JLT     lowpower_cond4_alt
                JBS     off(00211h).4, lowpower_cond_trigger
                SJ      lowpower_cond5_check

lowpower_cond4_alt:     JBR     off(00211h).4, lowpower_cond_trigger

lowpower_cond5_check:     LCB     A, TDCCount
                JEQ     lowpower_cond_exit
                SRA     A
                JLT     lowpower_cond5_alt
                JBS     off(00211h).1, lowpower_cond_trigger
                SJ      lowpower_cond_exit

lowpower_cond5_alt:     JBR     off(00211h).1, lowpower_cond_trigger
                SJ      lowpower_cond_exit

lowpower_cond_trigger:     SB      [DP].1

lowpower_cond_exit:     J       regbank_selftest2_start

FlexFuelMod:     CLR     X1
                LCB     A, Flexinput
                JNE     ISFlexEnabled
                CLR     X1
                L       A, #00000h
                ST      A, 0043ah[X1]
                CLRB    A
                STB     A, 0043ch[X1]
                RT

ISFlexEnabled:     CMPB    A, #001h
                JNE     FlexHeader
                SJ      FlexFunction

FlexHeader:     CMPB    A, #002h
                JNE     FlexValue
                LB      A, 003d2h[X1]
                SJ      FlexVolt2Per

FlexValue:     CMPB    A, #003h
                JNE     FlexLoadByte
                LB      A, ADCR3H
                SJ      FlexVolt2Per

FlexLoadByte:     LB      A, 003d5h[X1]

FlexVolt2Per:     MOV     X1, #Ethanolpercent
                CAL     table_interp_lookup
                CLR     X1
                STB     A, 00439h[X1]

FlexFunction:     MOV     DP, #00125h
                CLR     X1
                LB      A, 00439h[X1]
                MOV     X1, #EthanolComp
                VCAL    0
                CLR     X1
                STB     A, 0043ah[X1]
                LB      A, 00439h[X1]
                MOV     X1, #EthanolAdvance
                CAL     table_interp_lookup
                CLR     X1
                STB     A, 0043ch[X1]
                RT

; ============================================================================================
; HTS120 code. Everything the cleanup freed ends up here, in front of the calibration, which
; stays at its HTS 1.15 addresses.
; ============================================================================================
hts120_code:
; code_remap: the ROM numbers its codes by stored index + 1 but flashes four of them as other
; codes (25->35, 26->36, 27->41, 29->43). Shared by the code store and the code-flash routine.
code_remap:     CMPB    A, #019h
                JNE     code_remap_1a
                LB      A, #023h
                RT
code_remap_1a:  CMPB    A, #01ah
                JNE     code_remap_1b
                LB      A, #024h
                RT
code_remap_1b:  CMPB    A, #01bh
                JNE     code_remap_1d
                LB      A, #029h
                RT
code_remap_1d:  CMPB    A, #01dh
                JNE     code_remap_done
                LB      A, #02bh
code_remap_done: RT

; --------------------------------------------------------------------------------------------
; hts_tick: the 10 ms housekeeping tick (vcal3_main_task) now comes through here first.
;   Anti-start: with AntiStartEnable set the ECU powers up locked
;     (0FDh.7: fuel and spark cut) until the A/C switch is on with the throttle past
;     AntiStartTps. (TPS alone would clash with the code-flash request: full throttle, engine off.)
;   Traction control, from engine speed alone: every TcSampleTicks+1 ticks the rpm rise is
;     compared with the gear's TcRateByGear limit. Over it, TcAttack more retard (to
;     TcMaxRetard); under it, TcDecay less. hts_tc_apply takes the retard (0FCh) off the timing.
; Runs on its own register bank (388h-38Fh, LRB 71h) so the interrupted code's registers are
; untouched; er3 there carries the previous rpm from one sample to the next.
; --------------------------------------------------------------------------------------------
hts_tick:       PUSHS   LRB
                MOV     LRB, #00071h
                MB      C, 0fdh.6
                JLT     hts_antistart_hold
                SB      0fdh.6                 ; power-up: lock once, if enabled
                LCB     A, AntiStartEnable
                JEQ     hts_antistart_hold
                SB      0fdh.7
hts_antistart_hold:
                MB      C, 0fdh.7
                JGE     hts_tc_tick
                MOV     DP, #04700h            ; switch buffer: bit 2 = A/C switch (B5)
                MB      C, [DP].2
                JGE     hts_antistart_cut
                LCB     A, AntiStartTps
                CMPB    ADCR7H, A              ; the TPS converter itself: 0D1h is only copied
                JLT     hts_antistart_cut      ; from it once the engine turns
                RB      0fdh.7                 ; A/C on and throttle down: unlocked
                SJ      hts_tc_tick
hts_antistart_cut:                             ; locked: fuel and spark cut flags every tick, so
                MOV     DP, #00124h            ; cranking (which never reaches the limiter code)
                SB      [DP].5                 ; is cut too
                SB      [DP].4
hts_tc_tick:    LB      A, 0feh                ; sample when the countdown runs out
                SUBB    A, #001h
                STB     A, 0feh
                JGE     hts_tick_done
hts_tc_sample:  LCB     A, TcSampleTicks
                STB     A, 0feh
                MOV     er2, 0c4h              ; TDC period: rpm = 1875000 / period
                MOV     er0, #0001ch
                L       A, #09c38h
                DIV
                MOV     er1, A
                SUB     A, er3                 ; rise since the last sample
                MOV     er3, er1
                JLT     hts_tc_decay
                MOV     er0, A
                LCB     A, TcEnable
                JEQ     hts_tc_decay
                LCB     A, TcMinSpeed
                CMPB    0cch, A
                JLT     hts_tc_decay
                LCB     A, TcMinTps
                CMPB    0d1h, A
                JLT     hts_tc_decay
                MOV     DP, #0024fh            ; gear
                CLR     A
                LB      A, [DP]
                LCB     A, TcRateByGear[ACC]
                JEQ     hts_tc_decay
                L       A, ACC
                SLL     A
                SLL     A
                SLL     A
                CMP     A, er0
                JGE     hts_tc_decay           ; rise within the limit
                LB      A, 0fch                ; (LB first: LCB leaves DD as it was, and the byte ops need 0)
                STB     A, r0
                LCB     A, TcAttack
                ADDB    A, r0
                JGE     hts_tc_ceiling
                LB      A, #0ffh
hts_tc_ceiling: STB     A, r0
                LCB     A, TcMaxRetard
                CMPB    A, r0
                JLT     hts_tc_store
                LB      A, r0
                SJ      hts_tc_store
hts_tc_decay:   CLRB    A                      ; DD = 0 for the byte ops below
                LCB     A, TcDecay
                STB     A, r0
                LB      A, 0fch
                SUBB    A, r0
                JGE     hts_tc_store
                CLRB    A
hts_tc_store:   STB     A, 0fch
hts_tick_done:  POPS    LRB
                J       ResetWatchDog

; hts_tc_apply: the timing trims end with the per-gear/IAT/ECT/GIO corrections; traction
; control retard is the last of them, through the same clamp (r0 += A - 80h).
hts_tc_apply:   CAL     gearcorrect_ign_check
                LB      A, #080h
                SUBB    A, 0fch
                JGE     hts_tc_apply_trim
                CLRB    A
hts_tc_apply_trim:
                J       clamp_centered_0x80

; hts_limiter: the rev limiter's limit (A = cut period, DP = resume period; larger = lower rpm).
;   The LimitBySpeed / LimitByGear ceilings: the lower rpm of the two replaces the limiter's
;     own when it is lower still, with 10h of period as the resume margin.
;   HTS 1.15's "catch code" (Rom.cs applies it on load): while the ignition cut is on (0E6h)
;     the resume limit is the one that counts.
hts_limiter:    CAL     doubleup_limiter_target
                PUSHS   A                      ; VCAL 0 uses er0-er3: the cut limit waits on the stack,
                L       A, er3                 ; and er3, which the limiter's caller keeps, in X2
                MOV     X2, A                  ; (spare: doubleup_limiter_target overwrites it)
                LB      A, 0cch
                MOV     X1, #LimitBySpeed
                VCAL    0
                MOV     er1, A
                L       A, X2
                ST      A, er3
                POPS    A
                MOV     er2, A
                CLR     X1
                LB      A, 0024fh[X1]
                EXTND
                SLL     A
                LC      A, LimitByGear[ACC]
                CMP     A, er1
                JGE     hts_limiter_gear
                L       A, er1
hts_limiter_gear:
                CMP     A, er2
                JLT     hts_limiter_catch      ; ceiling above the limiter: nothing to do
                MOV     er2, A
                ADD     A, #00010h
                MOV     DP, A
hts_limiter_catch:
                L       A, 0e6h
                JEQ     hts_limiter_cut
                L       A, DP
                RT
hts_limiter_cut:
                L       A, er2
                RT

; hts_kill_check: where the ROM decides on its KillInjectors override (A bit 0 = fuel and spark cut).
;   Anti-start locked (0FDh.7): cut.
;   Speed limiter by switch: road speed at or over SwLimitSpeed with the SwLimitInput bit of the ROM's
;     switch byte (3B0h) on (off, with SwLimitInvert): cut, until the speed drops back under it.
;   Otherwise KillInjectors as before. (DP is free here: nothing reads it before loading it again.)
hts_kill_check: MB      C, 0fdh.7
                JLT     hts_kill_cut
                LB      A, 0cch                ; road speed (after SpeedCorrection)
                CMPCB   A, SwLimitSpeed
                JLT     hts_kill_normal
                LCB     A, SwLimitInput
                MOV     DP, #003b0h
                MBR     C, [DP]                ; the switch, as the ROM reads it
                LCB     A, SwLimitInvert
                JEQ     hts_kill_switch
                XORB    PSWH, #080h
hts_kill_switch:
                JGE     hts_kill_normal
hts_kill_cut:   LB      A, #001h
                RT
hts_kill_normal:
                LCB     A, KillInjectors
                RT

; hts_vss_speed: the VSS routine's division (er2 = pulse period), moved here, then the result
; scaled by SpeedCorrection/8000h. Returns er0:A like the division did.
hts_vss_speed:  MOV     er0, #00003h
                L       A, #vssSpeedNumerator  ; speed = 3xxxxh / period
                DIV
                MOV     er1, A
                L       A, er0
                JNE     hts_vss_done           ; already off the scale: er0 <> 0 makes the caller clamp to FFh
                LC      A, SpeedCorrection
                MOV     er0, A
                L       A, er1
                CAL     mul_scale_clamp        ; A = A x er0 / 8000h, saturating
                CLR     er0
hts_vss_done:   RT
hts120_code_end:
                org 05F14h        ; calibration: same addresses as HTS 1.15
; ---- HTS120 calibration (5F14h-5F40h, unused FF bytes in HTS 1.15) ------------------------
;@ SpeedCorrection type=u16 formula=x*100/32768 inverse=x*32768/100 unit=% category=Detected slot=vss.correction desc="Road speed scale: 100% reads as measured."
SpeedCorrection:    DW  08000h        ; road speed x SpeedCorrection / 8000h: 8000h = as measured, 8CCDh = +10%, 7459h = -9%
;@ TcEnable type=u8 flag=1 on=1 off=0 category=Switches slot=tc.rpmrate.enable desc="Traction control from engine speed alone."
TcEnable:           DB  000h          ; traction control: 00h off, anything else on
;@ TcSampleTicks type=u8 formula=(x+1)*10 inverse=x/10-1 unit=ms decimals=0 category=Detected slot=tc.rpmrate.sample desc="How long each rpm rise is measured over."
TcSampleTicks:      DB  004h          ; rpm rise measured over (n+1) x 10 ms
;@ TcMinSpeed type=u8 formula=speed_kmh_byte category=Detected slot=tc.rpmrate.speed desc="Traction control stays out below this road speed."
TcMinSpeed:         DB  003h          ; km/h: TC stays out below this
;@ TcMinTps type=u8 formula=volts_5v_byte category=Throttle slot=tc.rpmrate.tps desc="Traction control stays out below this throttle (TPS volts)."
TcMinTps:           DB  040h          ; TPS (0D1h units): TC stays out below this
;@ TcRateByGear type=u8 count=6 formula=x*8 inverse=x/8 unit=rpm decimals=0 category=Detected slot=tc.rpmrate.limit desc="Allowed rpm rise per sample, gear 0-5 (0 = TC off in that gear)."
TcRateByGear:       DB  000h,01Fh,013h,00Dh,009h,007h ; per gear 0-5: allowed rpm rise per sample / 8 (00h = TC off in that gear)
;@ TcAttack type=u8 formula=hts_quarter_deg category=Detected slot=tc.rpmrate.attack desc="Retard added each sample the rise is over the limit."
TcAttack:           DB  008h          ; retard added per sample while the rise is over the limit (0.25 deg units)
;@ TcMaxRetard type=u8 formula=hts_quarter_deg category=Detected slot=tc.rpmrate.max desc="Most traction control retard."
TcMaxRetard:        DB  028h          ; retard ceiling (0.25 deg units, at most 80h)
;@ TcDecay type=u8 formula=hts_quarter_deg category=Detected slot=tc.rpmrate.decay desc="Retard taken back each sample the rise is under the limit."
TcDecay:            DB  002h          ; retard taken back per sample once the rise is under the limit
;@ AntiStartEnable type=u8 flag=1 on=1 off=0 category=Switches slot=antistart.enable desc="Power up locked (fuel and spark cut) until A/C is on with the throttle past AntiStartTps."
AntiStartEnable:    DB  000h          ; anti-start: 00h off, else locked at power-up until the A/C switch is on
;@ AntiStartTps type=u8 formula=volts_5v_byte category=Throttle slot=antistart.tps desc="Throttle (TPS volts) that, with A/C on, unlocks anti-start."
AntiStartTps:       DB  0D0h          ;   and TPS (volts x 51, as 0D1h) is at least this - D0h is about 88%
;@ SwLimitSpeed type=u8 formula=speed_kmh_byte category=Limits slot=revlimit.swlimit.speed desc="Speed limiter by switch: cut at this speed while the input is on (255 = off)."
SwLimitSpeed:       DB  0FFh          ; speed limiter by switch: cut at this km/h while the input is on (FFh = off)
;@ SwLimitInput type=u8 category=Limits slot=revlimit.swlimit.input desc="Speed limiter input: bit of the switch byte 3B0h."
SwLimitInput:       DB  002h          ;   input, a bit of the ROM's switch byte 3B0h: 0 park/neutral, 1 brake, 2 A/C, 3 VTEC pressure,
                                      ;   4 start signal, 5 service check, 6 VTEC feedback, 7 power steering
;@ SwLimitInvert type=u8 flag=1 on=1 off=0 category=Limits slot=revlimit.swlimit.invert desc="Speed limiter works while the input reads off."
SwLimitInvert:      DB  000h          ;   00h = limit while the input reads on, else while it reads off
;@ LimitByGear type=u16 count=6 formula=rpm_period_word category=Limits slot=revlimit.ceiling.gear desc="Rpm ceiling per gear 0-5 (12500 = none)."
LimitByGear:        DW  00096h,00096h,00096h,00096h,00096h,00096h ; rpm ceiling per gear 0-5, as TDC period: rpm = 1875000 / x (96h = 12500, no limit)
;@ LimitBySpeed type=u8 count=44 formula=raw category=Limits desc="44 bytes"
LimitBySpeed:       DB  0FFh,096h,000h,0C8h,096h,000h,096h,096h,000h,064h,096h,000h,000h,096h,000h ; rpm ceiling by road speed: (km/h, period word) falling km/h
                DB  0FFh
                DB  0FFh,0FFh,000h,0FFh,0FFh,0FFh,0FFh,000h
                DB  000h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0E8h,03Ch,000h,000h,000h,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
; ---- HTS120 datalog packet (command 40h): RAM addresses, one byte each, 0 ends; checksum follows
;@ hts120_log_table type=u16 count=5 category=HTS120 desc="Datalog command 40h: the RAM addresses it sends, 0 ends."
hts120_log_table:   DW  000FCh,000FDh,0024Fh,0006Fh,00000h ; TC retard (0.25 deg), HTS120 status (bit 7 anti-start locked), gear, TPS converter (ADCR7H)
                DB  0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
;@ ICTimeMod type=u8 formula=raw category=Detected
ICTimeMod:       DB  000h
;@ ICFuelMod type=u8 flag=1 on=255 off=0 category=Fuel slot=revlimit.mod desc="Fuel enrichment and static timing while the ignition cut is on."
ICFuelMod:       DB  0FFh
;@ EthanolComp type=u8 count=18 formula=raw category=Detected desc="18 bytes"
EthanolComp:       DB  0FFh,08Ch,008h,0FFh,0FFh,000h,0FFh,08Ch
                DB  000h,0D9h,000h,000h,026h,000h,000h,000h
                DB  000h,000h
;@ Ethanolpercent type=u8 count=8 formula=raw category=Detected desc="8 bytes"
Ethanolpercent:       DB  0FFh,0FFh,0D9h,0D9h,026h,026h,000h,000h
;@ EthanolAdvance type=u8 count=15 formula=raw category=Detected desc="15 bytes"
EthanolAdvance:       DB  0FFh,018h,0FFh,018h,0FFh,018h,0D9h,000h
                DB  026h,000h,000h,000h,0FFh,0FFh,0FFh
;@ FTSVSS type=u8 formula=speed_kmh_byte category=Detected slot=fts.vss desc="18 bytes"
FTSVSS:       DB  009h
                     DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh
;@ VacCut type=u8 flag=1 on=255 off=0 category=Limits slot=fuelcut.vacuum.disable
VacCut:       DB  0FFh
;@ VacCutTPS type=u8 formula=hts_tps_pct category=Throttle slot=fuelcut.vacuum.tps
VacCutTPS:       DB  024h
;@ VacCutRPM type=u8 formula=rpm_axis_byte_log category=RPM slot=fuelcut.vacuum.rpm
VacCutRPM:       DB  090h
;@ GearCorrectMap type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Detected slot=gearcorr.load
GearCorrectMap:                 DW  0ff00h
;@ OFCEnable type=u8 flag=1 on=0 off=255 category=Switches slot=fuelcut.enable desc="Fuel cut on deceleration (FFh = off)."
OFCEnable:       DB  000h
;@ AntiLageByte type=u8 formula=raw category=Detected
AntiLageByte:       DB  000h
;@ AntiLag0Byte type=u8 formula=raw category=Detected
AntiLag0Byte:       DB  080h
;@ FuelCutRPMResume type=u8 formula=raw category=RPM
FuelCutRPMResume:       DB  073h
;@ tpstipinrpm type=u8 formula=rpm_axis_byte_log category=RPM slot=tipinout.disable
tpstipinrpm:       DB  079h
;@ IdleAC type=s16 category=Idle slot=idle.iacv.dutyac desc="IACV duty offset with the A/C on (the code reads it here; 1.15's page writes a byte later)."
IdleAC:                 DW  00000h
;@ FuelCutRPM type=u8 formula=rpm_axis_byte_log category=RPM slot=fuelcut.rpm
FuelCutRPM:       DB  080h
;@ TPSTipOutTrim type=u8 formula=hts_trim_128 category=Throttle slot=tipinout.shiftresponse
TPSTipOutTrim:       DB  079h
;@ KillInjectors type=u8 formula=raw category=Fuel
KillInjectors:       DB  000h
;@ Lockigndeg type=u8 flag=1 on=255 off=0 category=Ignition slot=scc.ignlock.enable
Lockigndeg:       DB  000h
;@ BURNOUTRPM type=u16 formula=rpm_period_word category=RPM slot=burnout.rpm
BURNOUTRPM:                 DW  00135h
;@ BURNOUT type=u8 category=Detected slot=burnout.input
BURNOUT:       DB  000h
;@ BURNOUTINVERT type=u8 flag=1 on=255 off=0 category=Switches slot=burnout.input.invert
BURNOUTINVERT:       DB  000h
;@ tbl_fts_static_ign type=u8 formula=ign_advance category=Ignition
tbl_fts_static_ign:       DB  0B4h
;@ tbl_fts_fuel_enrich type=u16 formula=raw category=Fuel
tbl_fts_fuel_enrich:                 DW  0003Ch   ; raw constant 60; an earlier pass bound the value to the int_NMI address
;@ tbl_ftl_rpm_alt type=u8 formula=raw category=RPM
tbl_ftl_rpm_alt:       DB  0FFh
;@ FTSMode type=u8 formula=raw flag=1 on=255 off=0 category=Switches
FTSMode:       DB  000h
;@ O2Input type=u8 category=Detected slot=closeloop.input desc="Where the O2 signal comes from: 0 ELD (D10), 1 EGR (D12), 2 B6, 3 O2 (D14)."
O2Input:       DB  003h
;@ LeanProMinRpm type=u16 formula=rpm_period_word category=RPM slot=leanpro.minrpm
LeanProMinRpm:                 DW  003a9h
;@ LeanProMinTps type=u8 formula=hts_tps_pct category=Throttle slot=leanpro.mintps
LeanProMinTps:       DB  020h
;@ LeanProLean1Tmr type=u8 formula=hts_x10_ms category=Detected slot=leanpro.1.duration
LeanProLean1Tmr:       DB  01Bh
;@ LeanProcheck1 type=u8 flag=1 on=255 off=0 category=Switches slot=leanpro.1.enable
LeanProcheck1:       DB  000h
;@ LeanProlean1Map type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=leanpro.1.load
LeanProlean1Map:       DB  090h
;@ LeanProLean1AfrVolt type=u8 formula=volts_5v_byte category=Detected slot=leanpro.1.volts
LeanProLean1AfrVolt:       DB  080h
;@ LeanProLean2Tmr type=u8 formula=hts_x10_ms category=Detected slot=leanpro.2.duration
LeanProLean2Tmr:       DB  010h
;@ WastegateMulti2 type=u8 count=8 formula=raw category=Detected desc="8 bytes"
WastegateMulti2:       DB  0FFh,080h,0FFh,080h,000h,080h,000h,080h
;@ WastegateMulti type=u8 count=8 formula=raw category=Detected desc="8 bytes"
WastegateMulti:       DB  0FFh,080h,0FFh,080h,000h,080h,000h,080h
;@ IABSelection type=u8 category=Detected slot=iab.alt.output
IABSelection:       DB  006h
;@ IABoutinvert type=u8 flag=1 on=255 off=0 category=Switches slot=iab.alt.invert
IABoutinvert:       DB  000h
;@ bstPWMHZ type=u16 category=Boost slot=ebc.frequency desc="PWM period word (HTS: 8, 15, 20, 25, 31 or 40 Hz)."
bstPWMHZ:                 DW  000c3h
;@ ECTProtectionTable type=u16 formula=rpm_period_word category=Detected slot=ectpro.rpm desc="4 bytes"
ECTProtectionTable:       DB  070h,002h,000h,000h
;@ ALTVtecEnable type=u8 flag=1 on=255 off=0 category=VTEC slot=vtec.alt.enable
ALTVtecEnable:       DB  000h
;@ AltVtecOutput type=u8 category=VTEC slot=vtec.alt.output
AltVtecOutput:       DB  008h
;@ AltVtecInvert type=u8 flag=1 on=255 off=0 category=VTEC slot=vtec.alt.invert
AltVtecInvert:       DB  000h
;@ FTLRPM2 type=u8 formula=hts_tps_pct category=RPM slot=fts.tps
FTLRPM2:       DB  0B2h
;@ GearBasedLimiter type=u8 flag=1 on=255 off=0 category=Limits slot=fts.gearlimit
GearBasedLimiter:       DB  000h
;@ FTLRPMTable type=u16 formula=rpm_period_word category=RPM slot=fts.cutrpm desc="FTS cut rpm (and the gear-0 entry of the per-gear table)."
FTLRPMTable:       DB  017h,002h,0EAh,000h,0EAh,000h,0EAh,000h
                DB  0EAh,000h,0EAh,000h
;@ AntiLagRetardDegree type=u8 formula=ign_advance category=Detected slot=launch.antilag.staticdeg
AntiLagRetardDegree:       DB  008h
;@ AntiLagStatic type=u8 flag=1 on=255 off=0 category=Detected slot=launch.antilag.static
AntiLagStatic:                 DW  000ffh
;@ RevlimitWarmC type=u8 formula=honda_temp_c category=Limits slot=revlimit.warmect desc="13 bytes"
RevlimitWarmC:       DB  043h,0EAh,000h,0EAh,000h,0EAh,000h,0EAh
                DB  000h,0EAh,000h,0EAh,000h
;@ MILFlashCount type=u8 category=Detected slot=scc.milflashes
MILFlashCount:       DB  000h
;@ idleigncheck type=u8 flag=1 on=255 off=0 category=Ignition slot=idleigncorr.enable
idleigncheck:       DB  0FFh
;@ IDLEignECT type=u8 formula=honda_temp_c category=Ignition slot=idleigncorr.ect desc="7 bytes"
IDLEignECT:       DB  054h,00Ah,08Ch,040h,0C8h,034h,008h
;@ FTLDelay type=u16 formula=raw category=Detected
FTLDelay:                 DW  00001h
;@ bstPWMMin type=u8 formula=hts_duty_half category=Boost slot=ebc.duty.min
bstPWMMin:       DB  000h
;@ AlphaN type=u8 formula=hts_tps_pct category=Detected slot=mapindex.alpha.tps100 desc="4 bytes"
AlphaN:       DB  0E7h,0FDh,02Ch,070h
;@ AlphaNTpsCross type=u8 formula=hts_tps_pct category=Throttle slot=mapindex.crosstps
AlphaNTpsCross:       DB  02Ch
;@ AlphaNMapCross type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=mapindex.crossmap
AlphaNMapCross:       DB  070h
;@ LoadIndex type=u8 category=Detected slot=mapindex.loadindex
LoadIndex:       DB  000h
;@ bstDial type=u8 category=Boost slot=ebc.dial
bstDial:       DB  000h
;@ LeanProcheck2 type=u8 flag=1 on=255 off=0 category=Switches slot=leanpro.2.enable
LeanProcheck2:       DB  000h
;@ LeanProlean2Map type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=leanpro.2.load
LeanProlean2Map:       DB  090h
;@ LeanProLean2AfrVolt type=u8 formula=volts_5v_byte category=Detected slot=leanpro.2.volts
LeanProLean2AfrVolt:       DB  080h
;@ IABInvert type=u8 flag=1 on=255 off=0 category=Detected slot=iab.invert desc="4 bytes"
IABInvert:       DB  000h,000h,000h,000h
;@ GIO2Enable type=u8 flag=1 on=255 off=0 category=Switches slot=gpo2.enable
GIO2Enable:       DB  000h
;@ GIO2Outselect type=u8 category=Detected slot=gpo2.output
GIO2Outselect:       DB  008h
;@ GIO2Outinvert type=u8 flag=1 on=255 off=0 category=Switches slot=gpo2.output.invert
GIO2Outinvert:       DB  000h
;@ GIO2Inselect type=u8 category=Detected slot=gpo2.input
GIO2Inselect:       DB  080h
;@ GIO2Ininvert type=u8 flag=1 on=255 off=0 category=Switches slot=gpo2.input.invert
GIO2Ininvert:       DB  000h
;@ GIO2DisableLimiters type=u8 flag=1 on=255 off=0 category=Limits slot=gpo2.nocut
GIO2DisableLimiters:       DB  000h
;@ GIO2chkMil type=u8 flag=1 on=255 off=0 category=Switches slot=gpo2.nomil
GIO2chkMil:       DB  000h
;@ GIO2chkMaps type=u8 flag=1 on=255 off=0 category=Load slot=gpo2.secondary
GIO2chkMaps:       DB  000h
;@ GIO2RpmMin type=u16 formula=rpm_period_word category=RPM slot=gpo2.rpm.min
GIO2RpmMin:                 DW  00753h
;@ GIO2RpmMax type=u16 formula=rpm_period_word category=RPM slot=gpo2.rpm.max
GIO2RpmMax:                 DW  000aah
;@ GIO2MapMin type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=gpo2.load.min
GIO2MapMin:       DB  000h
;@ GIO2MapMax type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=gpo2.load.max
GIO2MapMax:       DB  0FFh
;@ GIO2EctMin type=u8 formula=honda_temp_c category=Detected slot=gpo2.ect.min
GIO2EctMin:       DB  0FFh
;@ GIO2EctMax type=u8 formula=honda_temp_c category=Detected slot=gpo2.ect.max
GIO2EctMax:       DB  000h
;@ GIO2IATMin type=u8 formula=honda_temp_c category=Detected slot=gpo2.iat.min
GIO2IATMin:       DB  0FFh
;@ GIO2IATMax type=u8 formula=honda_temp_c category=Detected slot=gpo2.iat.max
GIO2IATMax:       DB  000h
;@ GIO2VSSMin type=u8 formula=speed_kmh_byte category=Detected slot=gpo2.speed.min
GIO2VSSMin:       DB  000h
;@ GIO2TPS type=u8 formula=hts_tps_pct category=Throttle slot=gpo2.tps
GIO2TPS:       DB  020h
;@ GIO2VSSMax type=u8 formula=speed_kmh_byte category=Detected slot=gpo2.speed.max
GIO2VSSMax:       DB  0FFh
;@ GIO3Enable type=u8 flag=1 on=255 off=0 category=Switches slot=gpo3.enable
GIO3Enable:       DB  000h
;@ GIO3Outselect type=u8 category=Detected slot=gpo3.output
GIO3Outselect:       DB  008h
;@ GIO3Outinvert type=u8 flag=1 on=255 off=0 category=Switches slot=gpo3.output.invert
GIO3Outinvert:       DB  000h
;@ GIO3Inselect type=u8 category=Detected slot=gpo3.input
GIO3Inselect:       DB  080h
;@ GIO3Ininvert type=u8 flag=1 on=255 off=0 category=Switches slot=gpo3.input.invert
GIO3Ininvert:       DB  000h
;@ GIO3DisableLimiters type=u8 flag=1 on=255 off=0 category=Limits slot=gpo3.nocut
GIO3DisableLimiters:       DB  000h
;@ GIO3chkMil type=u8 flag=1 on=255 off=0 category=Switches slot=gpo3.nomil
GIO3chkMil:       DB  000h
;@ GIO3chkMaps type=u8 flag=1 on=255 off=0 category=Load slot=gpo3.secondary
GIO3chkMaps:       DB  000h
;@ GIO3RpmMin type=u16 formula=rpm_period_word category=RPM slot=gpo3.rpm.min
GIO3RpmMin:                 DW  00753h
;@ GIO3RpmMax type=u16 formula=rpm_period_word category=RPM slot=gpo3.rpm.max
GIO3RpmMax:                 DW  000aah
;@ GIO3MapMin type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=gpo3.load.min
GIO3MapMin:       DB  000h
;@ GIO3MapMax type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=gpo3.load.max
GIO3MapMax:       DB  0FFh
;@ GIO3EctMin type=u8 formula=honda_temp_c category=Detected slot=gpo3.ect.min
GIO3EctMin:       DB  0FFh
;@ GIO3EctMax type=u8 formula=honda_temp_c category=Detected slot=gpo3.ect.max
GIO3EctMax:       DB  000h
;@ GIO3IATMin type=u8 formula=honda_temp_c category=Detected slot=gpo3.iat.min
GIO3IATMin:       DB  0FFh
;@ GIO3IATMax type=u8 formula=honda_temp_c category=Detected slot=gpo3.iat.max
GIO3IATMax:       DB  000h
;@ GIO3VSSMin type=u8 formula=speed_kmh_byte category=Detected slot=gpo3.speed.min
GIO3VSSMin:       DB  000h
;@ GIO3TPS type=u8 formula=hts_tps_pct category=Throttle slot=gpo3.tps
GIO3TPS:       DB  01Fh
;@ GIO3VSSMax type=u8 formula=speed_kmh_byte category=Detected slot=gpo3.speed.max
GIO3VSSMax:       DB  0FFh
;@ tbl_injector_bank_factor type=u8 count=3 formula=raw category=Fuel desc="3 bytes"
tbl_injector_bank_factor:       DB  05Dh,080h,046h
;@ ECTProtectChk type=u8 flag=1 on=255 off=0 category=Switches slot=ectpro.enable
ECTProtectChk:       DB  000h
;@ ECTProtectC type=u8 formula=honda_temp_c category=Detected slot=ectpro.ect
ECTProtectC:       DB  011h
;@ FPPrimeT type=u8 formula=hts_x01_s category=Detected slot=scc.prime
FPPrimeT:       DB  014h
;@ DisableStarterIN type=u8 flag=1 on=255 off=0 category=Switches slot=romoptions.starter
DisableStarterIN:       DB  000h
;@ FuelCutTrack type=u8 formula=raw category=Fuel
FuelCutTrack:       DB  080h
;@ WastegateCloseLoop type=u8 count=12 formula=raw category=Detected desc="12 bytes"
WastegateCloseLoop:       DB  0FFh,000h,080h,0E8h,000h,080h,0D1h,000h
                DB  080h,0BAh,000h,080h
;@ WasteGateLookup type=u8 count=22 formula=raw category=Detected desc="22 bytes"
WasteGateLookup:       DB  0FFh,000h,0EAh,000h,0E0h,000h,0D7h,000h
                DB  0CDh,000h,0C4h,000h,0BAh,000h,0B1h,000h
                DB  0FFh,000h,0E8h,000h,0D1h,000h
;@ wastegateGEAR type=u8 count=22 formula=raw category=Detected desc="22 bytes"
wastegateGEAR:       DB  0BAh,000h,0A3h,000h,08Bh,000h,074h,000h
                DB  05Dh,000h,08Bh,000h,074h,000h,05Dh,000h
                DB  046h,000h,02Fh,000h,000h,000h
;@ wastegateRPM type=u8 count=22 formula=raw category=RPM desc="22 bytes"
wastegateRPM:       DB  0FFh,080h,0E8h,080h,0D1h,080h,0BAh,080h
                DB  0A3h,080h,08Bh,080h,074h,080h,05Dh,080h
                DB  046h,080h,02Fh,080h,05Dh,080h
;@ wastegateIAT type=u8 count=10 formula=raw category=Detected desc="10 bytes"
wastegateIAT:       DB  0FFh,06Ch,0DEh,076h,0B5h,080h,06Dh,080h,000h,094h
;@ GIOAdjustment1 type=u8 count=22 formula=raw category=Detected desc="22 bytes"
GIOAdjustment1:       DB  0FFh,080h,0E8h,080h,0D1h,080h,0BAh,080h
                DB  0A3h,080h,08Bh,080h,074h,080h,05Dh,080h
                DB  046h,080h,02Fh,080h,000h,080h
;@ GIOAdjustment2 type=u8 count=38 formula=raw category=Detected desc="38 bytes"
GIOAdjustment2:       DB  0FFh,000h,080h,0E8h,000h,080h,0D1h,000h
                DB  080h,0BAh,000h,080h,0A3h,000h,080h,08Bh
                DB  000h,080h,074h,000h,080h,05Dh,000h,080h
                DB  046h,000h,080h,02Fh,000h,080h,000h,000h
                DB  080h,002h,0BAh,07Fh,0FEh,086h
;@ INJ_MULT type=u16 formula=x/32768 inverse=x*32768 unit=x decimals=3 category=Fuel slot=injector.multiplier desc="Injector size multiplier (old / new)."
INJ_MULT:                 DW  08000h
;@ CrankT type=u16 formula=hts_trim_word category=Detected slot=crankfuel.trim;injector.crank desc="Cranking fuel trim."
CrankT:                 DW  08000h
;@ PostfuelT type=u16 formula=hts_trim_word category=Fuel slot=injector.postfuel
PostfuelT:                 DW  08000h
;@ MultO2 type=u16 formula=raw category=Detected
MultO2:                 DW  08000h
;@ TipinT type=u16 formula=hts_trim_word category=Detected slot=tipinout.tipin;injector.tipin
TipinT:                 DW  07999h
;@ OverallFT type=u16 formula=hts_trim_word category=Detected slot=injector.overall desc="Overall fuel trim."
OverallFT:                 DW  08000h
;@ Deadtime type=u16 formula=x/8 inverse=x*8 category=Fuel slot=injector.deadtime
Deadtime:                 DW  00000h
;@ DisableVE type=u8 flag=1 on=255 off=0 category=Switches slot=closeloop.ve;romoptions.vecorr desc="VE correction off."
DisableVE:       DB  0FFh
;@ VE_ECT type=u8 formula=honda_temp_c category=Detected slot=closeloop.ve.ect desc="VE overheat correction above this coolant temperature."
VE_ECT:       DB  052h
;@ CloseloopO2 type=u8 flag=1 on=255 off=0 category=Detected slot=romoptions.closeloop
CloseloopO2:       DB  0FFh
;@ OpenloopMbar type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Detected slot=closeloop.maxload desc="Closed loop is off above this load."
OpenloopMbar:       DB  070h
;@ CloseLoopTargetVolt type=u8 formula=volts_5v_byte category=Detected slot=closeloop.targetv desc="Closed-loop target O2 voltage."
CloseLoopTargetVolt:       DB  018h
;@ IdleDC type=s16 category=Idle slot=idle.iacv.duty desc="IACV duty offset (HTS: -10240 to +10240)."
IdleDC:                 DW  00000h
;@ Dcode14 type=u8 flag=1 on=255 off=0 category=Detected slot=idle.iacverror.disable;romoptions.dtc14
Dcode14:       DB  000h
;@ TargetIdle type=u16 formula=rpm_period_word category=Idle slot=idle.rpm
TargetIdle:                 DW  0089dh
;@ IABValues type=u8 formula=rpm_axis_byte_log category=Detected slot=iab.disengage
IABValues:       DB  0D7h
;@ IABSetRPM type=u8 formula=rpm_axis_byte_log category=RPM slot=iab.engage
IABSetRPM:       DB  0DCh
;@ DisableIGNMAP type=u8 flag=1 on=255 off=0 category=Ignition slot=romoptions.igncorrload
DisableIGNMAP:       DB  000h
;@ IGNMAP type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Ignition slot=romoptions.igncorrload.value
IGNMAP:       DB  097h
;@ VtecDelay type=u8 formula=raw category=VTEC
VtecDelay:       DB  008h
;@ DCode21 type=u8 flag=1 on=255 off=0 category=Detected slot=vtec.noerror;romoptions.dtc21
DCode21:       DB  0FFh
;@ VtecTempCheck type=u8 flag=1 on=255 off=0 category=VTEC slot=vtec.notemp
VtecTempCheck:       DB  0FFh
;@ VtecECTMin type=u8 formula=honda_temp_c category=VTEC slot=vtec.minect
VtecECTMin:       DB  044h
;@ VtecLoadMin type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=VTEC slot=vtec.minload
VtecLoadMin:       DB  017h
;@ VtecVSSMin type=u8 formula=speed_kmh_byte category=VTEC slot=vtec.minspeed
VtecVSSMin:       DB  00Ah
;@ VTPS type=u8 flag=1 on=255 off=0 category=Throttle slot=vtec.nopressure;romoptions.dtc22
VTPS:       DB  0FFh
;@ VTSF type=u8 formula=raw category=Detected
VTSF:       DB  0FFh
;@ IGNCUT type=u8 flag=1 on=255 off=0 category=Ignition slot=revlimit.igncut
IGNCUT:       DB  000h
;@ FuelCut type=u8 flag=1 on=0 off=255 category=Fuel slot=revlimit.fuelcut
FuelCut:       DB  000h
;@ GearCorrectVSS type=u8 formula=speed_kmh_byte category=Detected slot=gearcorr.speed
GearCorrectVSS:       DB  010h
;@ GearCorrectFuel type=u8 count=6 formula=raw category=Fuel desc="6 bytes"
GearCorrectFuel:       DB  000h,080h,080h,080h,080h,080h
;@ GearCorrectIgn type=u8 count=6 formula=ign_advance category=Ignition desc="6 bytes"
GearCorrectIgn:       DB  000h,080h,080h,080h,080h,07Eh
;@ CylinderIgn type=u8 count=4 formula=ign_trim category=Ignition slot=cyltrim.ign desc="Timing trim per cylinder."
CylinderIgn:       DB  080h
;@ CylinderIgn2 type=u8 formula=ign_advance category=Ignition
CylinderIgn2:       DB  080h
;@ CylinderIgn3 type=u8 formula=ign_advance category=Ignition
CylinderIgn3:       DB  080h
;@ CylinderIgn4 type=u8 formula=ign_advance category=Ignition
CylinderIgn4:       DB  080h
;@ SCCInput type=u8 category=Detected slot=scc.input
SCCInput:       DB  002h
;@ SCCInvert type=u8 flag=1 on=255 off=0 category=Switches slot=scc.input.invert
SCCInvert:       DB  000h
;@ chkAcCut type=u8 flag=1 on=255 off=0 category=Limits slot=ac.cutoff.enable
chkAcCut:       DB  0FFh
;@ ACCutRPM type=u16 formula=rpm_period_word category=RPM slot=ac.cutoff.rpm
ACCutRPM:                 DW  00177h
;@ ACCutTPS type=u8 formula=hts_tps_pct category=Throttle slot=ac.cutoff.tps
ACCutTPS:       DB  09Fh
;@ IdleCut type=u16 formula=rpm_period_word category=Idle slot=ac.idlecut
IdleCut:                 DW  00b44h
;@ IdleRes type=u16 formula=rpm_period_word category=Idle slot=ac.idleresume
IdleRes:                 DW  009c4h
;@ MILShiftLight type=u8 flag=1 on=255 off=0 category=Detected slot=shiftlight.enable
MILShiftLight:       DB  000h
;@ MILShiftLightGear type=u8 flag=1 on=255 off=0 category=Detected slot=shiftlight.gearbased
MILShiftLightGear:       DB  000h
;@ MILShiftLightRPM type=u16 formula=rpm_period_word category=RPM slot=shiftlight.rpm desc="12 bytes"
MILShiftLightRPM:       DB  0EAh,000h,0EAh,000h,0EAh,000h,0EAh,000h
                DB  0EAh,000h,0EAh,000h
;@ BoostchkEnable type=u8 flag=1 on=255 off=0 category=Boost slot=boostcut.enable
BoostchkEnable:       DB  000h
;@ ctrlBoostCutCold type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Boost slot=boostcut.cold
ctrlBoostCutCold:       DB  0FFh
;@ FTLInput type=u8 category=Detected slot=launch.input
FTLInput:       DB  000h
;@ FTLInvert type=u8 flag=1 on=255 off=0 category=Switches slot=launch.input.invert
FTLInvert:       DB  000h
;@ FTLRPM type=u8 formula=speed_kmh_byte category=RPM slot=launch.speed desc="Launch control works below this speed."
FTLRPM:       DB  009h
;@ FTLMode type=u8 category=Switches slot=launch.mode
FTLMode:       DB  000h
;@ FTLTPSMin type=u16 formula=rpm_period_word category=Throttle slot=launch.rpm desc="Launch rpm (memory based)."
FTLTPSMin:                 DW  001d4h
;@ FTLTPSThresh type=u8 formula=hts_tps_pct category=Throttle slot=launch.tps.engage
FTLTPSThresh:       DB  05Fh
;@ FTL type=u8 category=Detected slot=fts.input
FTL:       DB  000h
;@ FTSInvert type=u8 flag=1 on=255 off=0 category=Switches slot=fts.input.invert
FTSInvert:       DB  000h
;@ BoostLimitMode1 type=u8 formula=hts_half_step category=Boost slot=ebc.cl.min desc="Closed loop: most duty taken away (undershoot)."
BoostLimitMode1:       DB  076h
;@ bstCloseLoopmin type=u8 formula=hts_half_step category=Boost slot=ebc.cl.max desc="Closed loop: most duty added (overshoot)."
bstCloseLoopmin:       DB  08Ah
;@ BoostcutOnMil type=u8 flag=1 on=255 off=0 category=Boost slot=boostcut.dtc
BoostcutOnMil:       DB  0FFh
;@ ctrlBoostCutHot type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Boost slot=boostcut.hot
ctrlBoostCutHot:       DB  0FFh
;@ BoostCutECT type=u8 formula=honda_temp_c category=Boost slot=boostcut.ect
BoostCutECT:       DB  043h
;@ AntiLagTPS type=u8 formula=hts_tps_pct category=Throttle slot=launch.antilag.tps
AntiLagTPS:       DB  09Fh
;@ AntiLagFV type=u16 formula=hts_quarter category=Detected slot=launch.antilag.enrich
AntiLagFV:                 DW  0003Ch            ; raw constant 60; an earlier pass bound the value to the int_NMI address
;@ AntiLagRetard type=u8 formula=hts_quarter_deg category=Detected slot=launch.antilag.retard
AntiLagRetard:       DB  0F0h
;@ EnableAntiLag type=u8 flag=1 on=255 off=0 category=Switches slot=launch.antilag.enable
EnableAntiLag:       DB  000h
;@ FTLRPMMin type=u16 formula=rpm_period_word category=RPM slot=launch.minrpm desc="Minimum launch rpm (TPS based)."
FTLRPMMin:                 DW  001d4h
;@ CLSTFT type=u16 formula=hts_trim_word category=Detected slot=closeloop.adjust.min desc="Most the closed-loop trim may take away."
CLSTFT:                 DW  05999h
;@ CLSTFV type=u16 formula=hts_trim_word category=Detected slot=closeloop.adjust.max desc="Most the closed-loop trim may add."
CLSTFV:                 DW  0bc28h
;@ DisablePurge type=u8 flag=1 on=255 off=0 category=Switches slot=romoptions.purge
DisablePurge:       DB  0FFh
;@ PurgeInvert type=u8 flag=1 on=255 off=0 category=Switches slot=romoptions.purgeinvert
PurgeInvert:       DB  000h
;@ FANChk type=u8 flag=1 on=255 off=0 category=Switches slot=fan.enable
FANChk:       DB  0FFh
;@ FANECT type=u8 formula=honda_temp_c category=Detected slot=fan.ect
FANECT:       DB  01Fh
;@ FANOUT type=u8 category=Detected slot=fan.output
FANOUT:       DB  003h
;@ EBCPWM type=u8 category=Detected slot=ebc.input
EBCPWM:       DB  000h
;@ EBCPWMInvert type=u8 flag=1 on=255 off=0 category=Switches slot=ebc.input.invert
EBCPWMInvert:       DB  000h
;@ EBCPWMhi type=u8 category=Detected slot=ebc.hilo.input
EBCPWMhi:       DB  000h
;@ EBCPWMhiInvert type=u8 flag=1 on=255 off=0 category=Detected slot=ebc.hilo.input.invert
EBCPWMhiInvert:                 DW  0ff00h
;@ EBCMapActive type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=ebc.active
EBCMapActive:       DB  000h
;@ EBCWasteGate type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Detected slot=ebc.wastegate
EBCWasteGate:       DB  000h
;@ FastSpool type=u8 formula=hts_duty_half category=Detected slot=ebc.fastspool
FastSpool:       DB  000h
;@ bstTargetMode type=u8 formula=hts_duty_half category=Boost slot=ebc.fixedduty desc="Fixed duty (0 = use the tables)."
bstTargetMode:                 DW  0000ah
;@ bstDeadBand type=u8 category=Fuel slot=ebc.cl.deadband
bstDeadBand:       DB  00Ah
;@ bstOvershootSens type=u8 formula=hts_x10_ms category=Boost slot=ebc.cl.overshoot
bstOvershootSens:       DB  005h
;@ bstUndershootSen type=u8 formula=hts_x10_ms category=Boost slot=ebc.cl.undershoot
bstUndershootSen:       DB  005h
;@ bstRPMMode type=u8 flag=1 on=255 off=0 category=RPM slot=ebc.rpmmode
bstRPMMode:       DB  000h
;@ bstCloseLoop type=u8 flag=1 on=0 off=255 category=Boost slot=ebc.closeloop
bstCloseLoop:       DB  0FFh
;@ WGGearLow type=u8 count=6 formula=raw category=Detected desc="6 bytes"
WGGearLow:       DB  000h,000h,000h,000h,000h,000h
;@ WGGearHi type=u8 count=6 formula=raw category=Detected desc="6 bytes"
WGGearHi:       DB  000h,000h,000h,000h,000h,000h
;@ wgcloselooppw type=u8 count=12 formula=raw category=Detected desc="12 bytes"
wgcloselooppw:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
;@ bstPWMMode type=u8 flag=1 on=255 off=0 category=Boost slot=ebc.pwmmode
bstPWMMode:       DB  000h
;@ bstPWMOutput type=u8 category=Boost slot=ebc.output
bstPWMOutput:       DB  0FFh
;@ bstPWMMax type=u8 formula=hts_duty_half category=Boost slot=ebc.duty.max
bstPWMMax:       DB  0C8h
;@ DisableAC type=u8 flag=1 on=255 off=0 category=Switches slot=ac.disable
DisableAC:       DB  000h
; BoostLimitMode1/FTLRPM byte at 0x615B, confirmed against lookup_table.md's valFTLRPM
; field). Duplicate label names are dangerous: any operand reference to "BoostLimitMode1"
; elsewhere in this file would ambiguously resolve to whichever definition asm662 picks,
; silently reading/writing the wrong calibration byte. Renamed here based on position only
; (immediately precedes the DuelMap* field group, right after DisableAC) -- NOT confirmed
; against Rom.cs, since this address isn't in lookup_table.md. Treat as tentative.
;@ DuelMapEnable type=u8 flag=1 on=0 off=255 category=Load slot=ebc.disabledtc desc="PWM off on a DTC or lean condition."
DuelMapEnable:       DB  000h
;@ DuelMap type=u8 category=Load slot=dualmap.mode
DuelMap:       DB  000h
;@ DuelMapinput type=u8 category=Load slot=dualmap.input
DuelMapinput:       DB  000h
;@ DuelMapinvert type=u8 flag=1 on=255 off=0 category=Load slot=dualmap.input.invert
DuelMapinvert:       DB  000h
;@ DuelMapchkRpm type=u8 flag=1 on=255 off=0 category=RPM slot=dualmap.chkrpm
DuelMapchkRpm:       DB  000h
;@ DuelMapRPM type=u16 formula=rpm_period_word category=RPM slot=dualmap.rpm
DuelMapRPM:                 DW  00753h
;@ DuelMapchkLoad type=u8 flag=1 on=255 off=0 category=Load slot=dualmap.chkload
DuelMapchkLoad:       DB  000h
;@ DuelMapLoad type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=dualmap.load
DuelMapLoad:       DB  000h
;@ DuelMapchkTps type=u8 flag=1 on=255 off=0 category=Load slot=dualmap.chktps
DuelMapchkTps:       DB  000h
;@ DuelMapTPS type=u8 formula=hts_tps_pct category=Load slot=dualmap.tps
DuelMapTPS:       DB  000h
;@ chkHighCamOnly type=u8 flag=1 on=255 off=0 category=Switches slot=mapindex.highcamonly
chkHighCamOnly:       DB  000h
;@ FPMode type=u8 category=Switches slot=scc.fuelpump
FPMode:       DB  000h
;@ SecondaryMapsOnly type=u8 flag=1 on=255 off=0 category=Detected slot=mapindex.secondaryonly
SecondaryMapsOnly:                 DW  0ff00h
;@ GIO1Enable type=u8 flag=1 on=255 off=0 category=Switches slot=gpo1.enable
GIO1Enable:       DB  000h
;@ GIO1Output type=u8 category=Detected slot=gpo1.output
GIO1Output:       DB  008h
;@ GIO1OutInvert type=u8 flag=1 on=255 off=0 category=Switches slot=gpo1.output.invert
GIO1OutInvert:       DB  000h
;@ GIO1Input type=u8 category=Detected slot=gpo1.input
GIO1Input:       DB  080h
;@ GIO1Invert type=u8 flag=1 on=255 off=0 category=Switches slot=gpo1.input.invert
GIO1Invert:       DB  000h
;@ GIO1DisableLimiters type=u8 flag=1 on=255 off=0 category=Limits slot=gpo1.nocut
GIO1DisableLimiters:       DB  000h
;@ GIO1chkMil type=u8 flag=1 on=255 off=0 category=Switches slot=gpo1.nomil
GIO1chkMil:       DB  000h
;@ GIO1chkMaps type=u8 flag=1 on=255 off=0 category=Load slot=gpo1.secondary
GIO1chkMaps:       DB  000h
;@ GIO1RpmMin type=u16 formula=rpm_period_word category=RPM slot=gpo1.rpm.min
GIO1RpmMin:                 DW  00753h
;@ GIO1RpmMax type=u16 formula=rpm_period_word category=RPM slot=gpo1.rpm.max
GIO1RpmMax:                 DW  000aah
;@ GIO1MapMin type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=gpo1.load.min
GIO1MapMin:       DB  000h
;@ GIO1MapMax type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Load slot=gpo1.load.max
GIO1MapMax:       DB  0FFh
;@ GIO1EctMin type=u8 formula=honda_temp_c category=Detected slot=gpo1.ect.min
GIO1EctMin:       DB  0FFh
;@ GIO1EctMax type=u8 formula=honda_temp_c category=Detected slot=gpo1.ect.max
GIO1EctMax:       DB  000h
;@ GIO1IATMin type=u8 formula=honda_temp_c category=Detected slot=gpo1.iat.min
GIO1IATMin:       DB  0FFh
;@ GIO1IATMax type=u8 formula=honda_temp_c category=Detected slot=gpo1.iat.max
GIO1IATMax:       DB  000h
;@ GIO1VSSMin type=u8 formula=speed_kmh_byte category=Detected slot=gpo1.speed.min
GIO1VSSMin:       DB  000h
;@ GIO1TPS type=u8 formula=hts_tps_pct category=Throttle slot=gpo1.tps
GIO1TPS:       DB  020h
;@ GIO1VSSMax type=u8 formula=speed_kmh_byte category=Detected slot=gpo1.speed.max
GIO1VSSMax:       DB  0FFh
;@ FANINVERT type=u8 flag=1 on=255 off=0 category=Switches slot=fan.invert
FANINVERT:       DB  000h
;@ ManualBstInput1 type=u8 category=Boost slot=boostmanual.input
ManualBstInput1:       DB  000h
;@ ManualBstInput1invert type=u8 flag=1 on=255 off=0 category=Boost slot=boostmanual.input.invert
ManualBstInput1invert:       DB  000h
;@ ManualBstchkMil type=u8 flag=1 on=255 off=0 category=Boost slot=boostmanual.nodtc
ManualBstchkMil:       DB  000h
;@ ManualBstchkFtl type=u8 flag=1 on=255 off=0 category=Boost slot=boostmanual.nocut
ManualBstchkFtl:       DB  000h
;@ ManualBst1 type=u16 formula=raw category=Boost
ManualBst1:                 DW  00753h
;@ ManualBst2 type=u8 formula=raw category=Boost
ManualBst2:       DB  01Fh ; 61C6
;@ ManualBst3 type=u8 formula=raw category=Boost
ManualBst3:       DB  0FFh
;@ Stage2on type=u8 formula=raw category=Detected
Stage2on:       DB  008h
;@ Stage3on type=u8 formula=raw category=Detected
Stage3on:       DB  008h
;@ Stage4on type=u8 formula=raw category=Detected
Stage4on:       DB  008h
;@ Stage2Vss type=u8 formula=speed_kmh_byte category=Detected slot=boostmanual.2.speed
Stage2Vss:       DB  028h
;@ Stage3Vss type=u8 formula=speed_kmh_byte category=Detected slot=boostmanual.3.speed
Stage3Vss:       DB  046h
;@ Stage4Vss type=u8 formula=speed_kmh_byte category=Detected slot=boostmanual.4.speed
Stage4Vss:       DB  064h
;@ DisableAltC type=u8 flag=1 on=255 off=0 category=Switches slot=romoptions.altc
DisableAltC:       DB  0FFh
;@ FTLTPSDisp type=u8 formula=hts_tps_pct category=Throttle slot=launch.tps.disengage desc="5 bytes"
FTLTPSDisp:       DB  03Fh,024h,000h,000h,000h
;@ CLMaxVoltage type=u8 formula=volts_5v_byte category=Detected slot=closeloop.maxo2v desc="O2 voltage over this sets the MIL."
CLMaxVoltage:       DB  04Dh
;@ CloseLoopECT type=u8 formula=honda_temp_c category=Detected slot=closeloop.minect desc="Closed loop is off below this coolant temperature."
CloseLoopECT:                 DW  02e2eh
;@ CloseLoopNarrow type=u8 formula=raw category=Detected
CloseLoopNarrow:       DB  000h
;@ IGNCDelay type=u8 formula=hts_x10_ms category=Ignition slot=revlimit.igndelay;fts.igndelay
IGNCDelay:       DB  007h
; SpareCalByte1-4 and TDCCount below, plus CKPCount further down, ARE read -- by
; in this ROM. CKPCount is that routine's master enable; SpareCalByte1-4/TDCCount each gate one of
; its five calibratable status-bit conditions. The "never read or written" note below predates
; that restoration.
;@ SpareCalByte1 type=u8 formula=raw category=Detected
SpareCalByte1:       DB  000h
;@ SpareCalByte2 type=u8 formula=raw category=Detected
SpareCalByte2:       DB  000h
;@ SpareCalByte3 type=u8 formula=raw category=Detected
SpareCalByte3:       DB  000h
;@ SpareCalByte4 type=u8 formula=raw category=Detected
SpareCalByte4:       DB  000h
;@ TDCCount type=u8 formula=raw category=Detected
TDCCount:       DB  000h
;@ Flexinput type=u8 category=Detected slot=flexfuel.input desc="Analog input the ethanol sensor is on."
Flexinput:       DB  000h,0FFh,0FFh
;@ CYPCount type=u16 formula=raw category=Detected
CYPCount:                 DW  002eeh
;@ CKPCount type=u8 formula=raw category=Detected
CKPCount:       DB  000h ; master enable byte for lowpower_abort_cond_scan (0x5E4A); 0 = disabled
;@ LCDelay type=u8 formula=hts_x10_ms category=Detected slot=revlimit.launchdelay
LCDelay:       DB  007h
;@ FTSDelay type=u8 formula=hts_x10_ms category=Detected slot=revlimit.ftsdelay
FTSDelay:       DB  007h
;@ IGNCFV type=u16 formula=hts_quarter category=Ignition slot=revlimit.enrich
IGNCFV:                 DW  00000h
;@ IGNCDEG type=u8 formula=ign_advance category=Ignition slot=revlimit.staticign
IGNCDEG:       DB  000h
;@ FTSStaticIgn type=u8 formula=ign_advance category=Ignition slot=fts.staticdeg
FTSStaticIgn:       DB  000h
;@ FTSchkStatic type=u8 flag=1 on=255 off=0 category=Switches slot=fts.static
FTSchkStatic:       DB  0FFh
;@ FANVSS type=u8 formula=speed_kmh_byte category=Detected slot=fan.speed
FANVSS:       DB  023h
;@ ACCVSSMax type=u8 formula=speed_kmh_byte category=Detected slot=ac.cutoff.speed desc="5 bytes"
ACCVSSMax:       DB  08Ch,0FFh,0FFh,0FFh,0FFh
;@ tbl_idle_pi_clamp type=u8 formula=raw category=Idle
tbl_idle_pi_clamp:       DB  000h
;@ VtecEnable type=u8 flag=1 on=255 off=0 category=VTEC slot=vtec.enable
VtecEnable:       DB  0FFh
;@ AutoA type=u8 flag=1 on=0 off=255 category=Detected slot=romoptions.dtc30
AutoA:       DB  000h
;@ O2Heater type=u8 flag=1 on=0 off=255 category=Detected slot=closeloop.o2heater.disable;romoptions.dtc41 desc="O2 heater off (and its code 41)."
O2Heater:       DB  000h
;@ chkBaro type=u8 flag=1 on=0 off=255 category=Switches slot=romoptions.dtc13
chkBaro:       DB  000h
;@ FuelCutMAP type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category=Fuel slot=fuelcut.load
FuelCutMAP:       DB  025h
;@ FuelCutTPS type=u8 formula=hts_tps_pct category=Fuel slot=fuelcut.tps
FuelCutTPS:       DB  024h
;@ CloseloopO2VE type=u8 flag=1 on=255 off=0 category=Detected slot=closeloop.ve.fueldisable;romoptions.closeloopOnly desc="VE overheat fuel correction off."
CloseloopO2VE:       DB  0FFh
;@ DCode16 type=u8 flag=1 on=255 off=0 category=Detected slot=romoptions.dtc16
DCode16:       DB  0FFh
;@ Tablepointers type=u8 count=3 formula=raw category=Detected desc="3 bytes"
Tablepointers:       DB  0FFh,00Ah,000h
;@ IgnSyncLock type=u8 formula=ign_advance category=Ignition
IgnSyncLock:       DB  000h
;@ tbl_boot_flag_misc1 type=u8 formula=raw flag=1 on=255 off=0 category=Switches
tbl_boot_flag_misc1:       DB  000h
;@ tbl_cfgvariant_max type=u8 formula=raw category=Detected
tbl_cfgvariant_max:       DB  0FFh
;@ CustomTPS type=u8 flag=1 on=255 off=0 category=Throttle slot=tpssensor.custom
CustomTPS:       DB  000h
;@ IABVEnable type=u8 flag=1 on=255 off=0 category=Switches slot=iab.usdm
IABVEnable:       DB  0FFh
;@ Lockdeg type=u8 formula=ign_advance category=Detected slot=scc.ignlock.deg
Lockdeg:       DB  05Ah
;@ TPSSettings type=u8 formula=volts_5v_byte category=Throttle slot=tpssensor.max desc="TPS volts at 100%."
TPSSettings:       DB  0E8h,0E8h,018h,018h,0FFh,058h
;@ VtecVSSCheck type=u8 flag=1 on=255 off=0 category=VTEC slot=vtec.nospeed
VtecVSSCheck:       DB  0FFh
;@ Debug type=u8 flag=1 on=255 off=0 category=Detected slot=romoptions.debug
Debug:       DB  000h
;@ DisableAuto type=u8 flag=1 on=0 off=255 category=Switches slot=romoptions.autotranny
DisableAuto:       DB  000h
;@ tbl_autotrans_flag type=u8 formula=raw flag=1 on=255 off=0 category=Switches
tbl_autotrans_flag:       DB  000h
;@ tbl_iabv_flag type=u8 formula=raw flag=1 on=255 off=0 category=Switches
tbl_iabv_flag:       DB  0FFh
;@ DCode20 type=u8 flag=1 on=0 off=255 category=Detected slot=romoptions.dtc20
DCode20:       DB  000h
;@ InjectorSettings type=u8 count=3 formula=raw category=Fuel desc="3 bytes"
InjectorSettings:       DB  000h,001h,000h
;@ GearPreset type=u16 formula=raw category=Detected
GearPreset:                 DW  000ffh
;@ tbl_boot_flag_misc2 type=u8 formula=raw flag=1 on=255 off=0 category=Switches
tbl_boot_flag_misc2:       DB  0FFh
;@ IABCheck type=u8 flag=1 on=255 off=0 category=Switches slot=iab.enable
IABCheck:       DB  000h
;@ InjectorTable type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0 category=Fuel slot=injector.hotlow desc="6 bytes"
InjectorTable:       DB  006h,008h,00Ah,00Bh,00Bh,00Bh
;@ tbl_tps_custom_curve type=u8 count=4 formula=percent255 category=Throttle desc="4 bytes"
tbl_tps_custom_curve:       DB  004h,00Bh,004h,00Bh
;@ tbl_tps_custom_curve2 type=u8 count=14 formula=percent255 category=Throttle desc="14 bytes"
tbl_tps_custom_curve2:       DB  040h,040h,040h,030h,030h,020h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
;@ ECTFuelCorrect type=u8 count=72 formula=raw category=Fuel desc="72 bytes"
ECTFuelCorrect:       DB  0FFh,0B3h,0F5h,0B3h,0E6h,0A6h,0CFh,0A0h
                DB  0A1h,09Ah,06Eh,094h,02Eh,08Ah,028h,080h
                DB  000h,080h,0FFh,0DAh,0F5h,0DAh,0E6h,0BDh
                DB  0CFh,0B6h,0A1h,0ADh,06Eh,0A4h,02Eh,09Ah
                DB  028h,080h,000h,080h,0FFh,080h,000h,080h
                DB  000h,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h,000h,080h,0FFh,099h
                DB  0A1h,099h,050h,089h,02Eh,080h,000h,080h
                DB  000h,080h,000h,080h,000h,080h,000h,080h
;@ FuelSettingsStuff type=u8 count=32 formula=raw category=Fuel desc="32 bytes"
FuelSettingsStuff:       DB  0FFh,090h,0D0h,090h,0B8h,08Ch,0A1h,079h
                DB  044h,059h,02Eh,040h,000h,040h,000h,040h
                DB  000h,040h,000h,000h,000h,000h,000h,000h
                DB  0F0h,000h,000h,000h,000h,000h,000h,000h
;@ tbl_knockwindow_2 type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_knockwindow_2:       DB  0FFh,040h,0D7h,040h,0D2h,05Ah,0CFh,073h
                DB  000h,073h,000h,073h
;@ IATFuelCorrect type=u8 count=27 formula=raw category=Fuel desc="27 bytes"
IATFuelCorrect:       DB  0FFh,0CCh,08Ch,0F5h,0CCh,08Ch,0E6h,0D4h
                DB  088h,0CFh,0DDh,084h,0A1h,068h,081h,057h
                DB  000h,080h,034h,05Ch,07Fh,018h,056h,07Eh
                DB  000h,056h,07Eh
;@ IATScaler2 type=u8 count=27 formula=raw category=Detected desc="27 bytes"
IATScaler2:       DB  0FFh,0A4h,090h,0F5h,0A4h,090h,0E6h,08Bh
                DB  08Ch,0CFh,052h,088h,0A1h,07Bh,084h,057h
                DB  000h,080h,034h,0CDh,07Ch,018h,0E1h,07Ah
                DB  000h,0E1h,07Ah
;@ IATScaler type=u8 count=27 formula=raw category=Detected desc="27 bytes"
IATScaler:       DB  0FFh,09Ch,094h,0F5h,09Ch,094h,0E6h,021h
                DB  090h,0CFh,0A6h,08Bh,0A1h,0C9h,086h,057h
                DB  000h,080h,034h,085h,07Bh,018h,099h,079h
                DB  000h,099h,079h
;@ PostFuelDecay type=u16 count=4 category=Fuel slot=injector.postdecay1 desc="8 bytes"
PostFuelDecay:       DB  000h,0B0h,000h,00Ah,000h,002h,020h,000h
;@ PostFuelDecay2 type=u16 count=4 category=Fuel slot=injector.postdecay2 desc="8 bytes"
PostFuelDecay2:       DB  000h,0B0h,000h,00Ah,000h,002h,020h,000h
;@ PostFuelDecay3 type=u16 count=4 category=Fuel slot=injector.postdecay3 desc="8 bytes"
PostFuelDecay3:       DB  000h,0B0h,000h,00Ah,000h,002h,020h,000h
;@ PostFuel type=u8 count=27 formula=raw category=Fuel desc="27 bytes"
PostFuel:       DB  0FFh,000h,0A0h,0F5h,000h,0A0h,0E6h,000h
                DB  070h,0CFh,000h,060h,0A1h,000h,040h,06Eh
                DB  000h,030h,02Eh,0C3h,025h,000h,0C3h,025h
                DB  000h,0C3h,025h
;@ tbl_o2trim_ect_offset type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_o2trim_ect_offset:       DB  001h,000h,000h,001h,001h,000h,000h,002h
                DB  001h,000h,000h,004h
;@ tbl_revlimit_cold1 type=u8 count=4 formula=raw category=Limits desc="4 bytes"
tbl_revlimit_cold1:       DB  0DBh,030h,0CFh,050h
;@ tbl_revlimit_cold2 type=u8 count=4 formula=raw category=Limits desc="4 bytes"
tbl_revlimit_cold2:       DB  0B5h,07Bh,0A7h,097h
;@ tbl_revlimit_cold3 type=u8 count=4 formula=raw category=Limits desc="4 bytes"
tbl_revlimit_cold3:       DB  0DBh,07Bh,0CFh,0A2h
;@ CloseLoopRate type=u16 count=4 formula=x/16 inverse=x*16 unit=%/s category=Detected slot=closeloop.rate desc="How fast the closed-loop trim moves."
CloseLoopRate:       DB  010h,001h,010h,001h,010h,001h,0C0h,000h
                DB  018h,000h,000h,000h,010h,001h,010h,001h
                DB  010h,001h,0C0h,000h,018h,000h,000h,000h
;@ CloseLoopGoose type=u8 count=72 formula=raw category=Detected desc="72 bytes"
CloseLoopGoose:       DB  000h,000h,040h,004h,000h,004h,000h,004h
                DB  000h,001h,000h,000h,000h,000h,040h,004h
                DB  000h,004h,000h,004h,000h,001h,000h,000h
                DB  010h,001h,010h,001h,010h,001h,0C0h,000h
                DB  018h,000h,000h,000h,010h,001h,010h,001h
                DB  010h,001h,0C0h,000h,018h,000h,000h,000h
                DB  000h,000h,040h,004h,000h,004h,000h,004h
                DB  000h,001h,000h,000h,000h,000h,040h,004h
                DB  000h,004h,000h,004h,000h,001h,000h,000h
;@ tbl_closeloop_tps type=u8 count=16 formula=percent255 category=Throttle desc="16 bytes"
tbl_closeloop_tps:       DB  0FFh,030h,0E8h,030h,0E0h,080h,0DCh,0D8h
                DB  0C0h,0D8h,04Dh,0D8h,040h,0D0h,000h,0D0h
;@ tbl_revlimit_warm1 type=u8 count=4 formula=raw category=Limits desc="4 bytes"
tbl_revlimit_warm1:       DB  0EEh,000h,086h,04Dh
;@ VEFuelCorrect type=u8 count=12 formula=raw category=Fuel desc="12 bytes"
VEFuelCorrect:       DB  0FFh,080h,01Fh,080h,018h,080h,013h,08Bh
                DB  00Fh,08Bh,000h,08Bh
;@ CloseLoopTPS type=u8 count=12 formula=percent255 category=Throttle desc="12 bytes"
CloseLoopTPS:       DB  0FFh,06Ch,0C0h,06Ch,0A0h,060h,080h,04Ch
                DB  060h,040h,000h,034h
;@ OpenLoopTPS type=u8 count=12 formula=percent255 category=Throttle desc="12 bytes"
OpenLoopTPS:       DB  0FFh,072h,0C0h,072h,0A0h,065h,080h,052h
                DB  060h,046h,000h,03Ah
;@ tbl_ve_accel_1 type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_ve_accel_1:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h
;@ tbl_ve_accel_2 type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_ve_accel_2:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h
;@ tbl_knockwindow_3 type=u8 count=14 formula=raw category=Detected desc="14 bytes"
tbl_knockwindow_3:       DB  0FFh,093h,0A1h,093h,087h,086h,06Eh,07Ah
                DB  044h,066h,028h,054h,000h,054h
;@ tbl_knockwindow_4 type=u8 count=42 formula=raw category=Detected desc="42 bytes"
tbl_knockwindow_4:       DB  0FFh,086h,0A1h,086h,087h,071h,06Eh,05Eh
                DB  044h,051h,028h,041h,000h,041h,0FFh,093h
                DB  0A1h,093h,087h,086h,06Eh,07Ah,044h,066h
                DB  028h,054h,000h,054h,0FFh,086h,0A1h,086h
                DB  087h,071h,06Eh,05Eh,044h,051h,028h,041h
                DB  000h,041h
;@ CylinderIGNCorrect type=u8 count=4 formula=hts_trim_128 category=Ignition slot=cyltrim.fuel desc="Fuel trim per cylinder (despite its name)."
CylinderIGNCorrect:       DB  080h,080h,080h,080h
;@ tbl_revlimit_warm2 type=u8 count=12 formula=raw category=Limits desc="12 bytes"
tbl_revlimit_warm2:       DB  0FFh,000h,0EEh,000h,0BDh,008h,0A7h,028h
                DB  08Fh,032h,000h,032h
;@ tbl_injtimer_finalize type=u8 count=12 formula=raw category=Fuel desc="12 bytes"
tbl_injtimer_finalize:       DB  0FFh,000h,0A0h,000h,050h,040h,038h,079h
                DB  020h,0F6h,000h,0F6h
;@ InjectorIndex type=u8 count=24 formula=raw category=Fuel desc="24 bytes"
InjectorIndex:       DB  0FFh,063h,000h,0A6h,067h,000h,093h,092h
                DB  000h,07Dh,0C1h,000h,067h,054h,001h,054h
                DB  080h,002h,000h,080h,002h,000h,000h,000h
;@ Tipintempoffsetnormal type=u8 count=18 formula=raw category=Detected desc="18 bytes"
Tipintempoffsetnormal:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,06Eh,066h
                DB  000h,040h,09Ah,000h,028h,000h,001h,000h
                DB  000h,001h
;@ Tipintempoffsetinitial type=u8 count=30 formula=raw category=Detected desc="30 bytes"
Tipintempoffsetinitial:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,06Eh,066h,000h,040h
                DB  080h,000h,028h,000h,001h,000h,000h,001h,030h,0DAh
                DB  000h,010h,000h,001h,030h,0E6h,000h,010h,000h,001h
;@ tbl_tipin_low type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_tipin_low:       DB  030h,0CAh,000h,008h,000h,001h,030h,0DCh
                DB  000h,008h,000h,001h
;@ tbl_tipin_secondary type=u8 count=6 formula=raw category=Detected desc="6 bytes"
tbl_tipin_secondary:       DB  030h,000h,001h,010h,000h,001h
;@ tbl_revlimit_cold4 type=u8 count=4 formula=raw category=Limits desc="4 bytes"
tbl_revlimit_cold4:       DB  0EEh,080h,0BDh,040h
;@ tbl_rpm_decel type=u8 count=21 formula=raw category=RPM desc="21 bytes"
tbl_rpm_decel:       DB  0FFh,014h,000h,095h,014h,000h,06Dh,03Ch
                DB  000h,04Dh,080h,000h,034h,0E0h,000h,027h
                DB  00Eh,001h,000h,00Eh,001h
;@ tbl_knockwindow_5 type=u8 count=15 formula=raw category=Detected desc="15 bytes"
tbl_knockwindow_5:       DB  0FFh,04Bh,000h,0CFh,04Bh,000h,0A2h,07Dh
                DB  000h,06Eh,07Dh,000h,000h,07Dh,000h
;@ tbl_knockwindow_6 type=u8 count=28 formula=raw category=Detected desc="28 bytes"
tbl_knockwindow_6:       DB  0FFh,0A0h,0EDh,0A0h,0D0h,094h,0A1h,090h
                DB  06Eh,058h,028h,010h,000h,010h,0FFh,0A0h
                DB  0EDh,0A0h,0D0h,094h,0A1h,090h,06Eh,058h
                DB  028h,010h,000h,010h
;@ tbl_knockwindow_7 type=u8 count=42 formula=raw category=Detected desc="42 bytes"
tbl_knockwindow_7:       DB  0FFh,060h,0EDh,060h,0D0h,050h,0A1h,040h
                DB  06Eh,038h,028h,008h,000h,008h,0FFh,060h
                DB  0EDh,060h,0D0h,050h,0A1h,040h,06Eh,038h
                DB  028h,008h,000h,008h,0FFh,010h,000h,010h
                DB  000h,010h,000h,010h,000h,010h,000h,010h
                DB  000h,010h
;@ tbl_knockwindow_8 type=u8 count=14 formula=raw category=Detected desc="14 bytes"
tbl_knockwindow_8:       DB  0FFh,010h,000h,010h,000h,010h,000h,010h
                DB  000h,010h,000h,010h,000h,010h
;@ CrankFuel type=u8 count=27 formula=raw category=Fuel desc="27 bytes"
CrankFuel:       DB  0FFh,030h,075h,0F5h,030h,075h,0E6h,05Ch
                DB  044h,0CFh,0D4h,030h,0A1h,06Ah,018h,06Eh
                DB  0A6h,00Eh,028h,0D0h,007h,000h,0D0h,007h
                DB  000h,0D0h,007h
;@ CrankFuelComp type=u8 count=4 formula=raw category=Fuel desc="4 bytes"
CrankFuelComp:       DB  030h,080h,012h,05Ah
;@ CrankFuelMap type=u8 count=4 formula=raw category=Fuel desc="4 bytes"
CrankFuelMap:       DB  0EEh,080h,073h,05Ah
;@ Overrun_Resume_int type=u8 count=14 formula=raw category=Detected desc="14 bytes"
Overrun_Resume_int:       DB  0FFh,093h,0A1h,093h,087h,086h,06Eh,07Ah
                DB  044h,066h,028h,054h,000h,054h
;@ Overrun_Resume_nor type=u8 count=42 formula=raw category=Detected desc="42 bytes"
Overrun_Resume_nor:       DB  0FFh,088h,0A1h,088h,087h,073h,06Eh,060h
                DB  044h,053h,028h,043h,000h,043h,0FFh,093h
                DB  0A1h,093h,087h,086h,06Eh,07Ah,044h,066h
                DB  028h,054h,000h,054h,0FFh,088h,0A1h,088h
                DB  087h,073h,06Eh,060h,044h,053h,028h,043h
                DB  000h,043h
;@ tbl_ignmap2_lo type=u8 count=12 formula=ign_advance category=Ignition desc="12 bytes"
tbl_ignmap2_lo:       DB  0FFh,033h,0E0h,024h,0C0h,017h,098h,019h
                DB  080h,019h,000h,019h
;@ tbl_ignmap2_hi type=u8 count=12 formula=ign_advance category=Ignition desc="12 bytes"
tbl_ignmap2_hi:       DB  0FFh,027h,0E0h,018h,0C0h,00Bh,098h,013h
                DB  080h,013h,000h,013h
;@ tbl_revlimit_warm3 type=u8 count=4 formula=raw category=Limits desc="4 bytes"
tbl_revlimit_warm3:       DB  0EEh,000h,073h,00Dh
;@ tbl_threshold_223_1 type=u8 count=6 formula=raw category=Detected desc="6 bytes"
tbl_threshold_223_1:       DB  01Eh,02Bh,0FFh,000h,067h,001h
;@ Revlimiters type=u8 count=6 formula=raw category=Limits desc="6 bytes"
Revlimiters:       DB  01Eh,02Bh,0FDh,000h,01Dh,001h
;@ tbl_threshold_223_2 type=u8 count=6 formula=raw category=Detected desc="6 bytes"
tbl_threshold_223_2:       DB  01Eh,02Bh,0FFh,000h,067h,001h
;@ tbl_threshold_223_3 type=u8 count=6 formula=raw category=Detected desc="6 bytes"
tbl_threshold_223_3:       DB  01Eh,02Bh,0FDh,000h,01Dh,001h
;@ tbl_knock_index type=u8 count=24 formula=raw category=Detected desc="24 bytes"
tbl_knock_index:       DB  052h,078h,029h,07Ch,000h,080h,0D7h,083h
                DB  0AEh,087h,0AEh,087h,052h,078h,029h,07Ch
                DB  000h,080h,0D7h,083h,0AEh,087h,0AEh,087h
;@ tbl_knock_div type=u8 count=144 formula=raw category=Detected desc="144 bytes"
tbl_knock_div:       DB  0C0h,003h,000h,004h,040h,004h,080h,004h
                DB  0C0h,004h,0C0h,004h,0C0h,005h,000h,006h
                DB  040h,006h,080h,006h,0C0h,006h,0C0h,006h
                DB  040h,005h,080h,005h,0C0h,005h,000h,006h
                DB  040h,006h,040h,006h,0C0h,003h,000h,004h
                DB  040h,004h,080h,004h,0C0h,004h,0C0h,004h
                DB  0C0h,005h,000h,006h,040h,006h,080h,006h
                DB  0C0h,006h,0C0h,006h,040h,005h,080h,005h
                DB  0C0h,005h,000h,006h,040h,006h,040h,006h
                DB  0C0h,003h,000h,004h,040h,004h,080h,004h
                DB  0C0h,004h,0C0h,004h,0C0h,005h,000h,006h
                DB  040h,006h,080h,006h,0C0h,006h,0C0h,006h
                DB  040h,005h,080h,005h,0C0h,005h,000h,006h
                DB  040h,006h,040h,006h,0C0h,003h,000h,004h
                DB  040h,004h,080h,004h,0C0h,004h,0C0h,004h
                DB  0C0h,005h,000h,006h,040h,006h,080h,006h
                DB  0C0h,006h,0C0h,006h,040h,005h,080h,005h
                DB  0C0h,005h,000h,006h,040h,006h,040h,006h
;@ GearCustom type=u16 count=4 category=Detected slot=transmission.ratio desc="Custom gear ratio words."
GearCustom:       DB  046h,000h,067h,000h,08Eh,000h,0B8h,000h
;@ VtecSettings type=u8 formula=hts_tps_pct category=VTEC slot=vtec.tps.high desc="VTEC high-load throttle."
VtecSettings:       DB  052h,0DBh,037h,0D8h,0FFh,0FFh,000h,0FFh
                DB  000h,0FFh,000h,0FFh,0FFh,0FFh,000h,0FFh
                DB  000h,0FFh,000h,0FFh,0FFh,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,0FFh,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
;@ tbl_vtec_transition_retard type=u8 count=25 formula=raw category=VTEC desc="25 bytes"
tbl_vtec_transition_retard:       DB  000h,000h,011h,055h,077h,0FFh,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h
;@ tbl_ect_fuelcorrect type=u8 count=54 formula=raw category=Fuel desc="54 bytes"
tbl_ect_fuelcorrect:       DB  0FFh,000h,013h,0E1h,000h,011h,0CFh,000h
                DB  011h,0A1h,000h,018h,068h,000h,018h,050h
                DB  000h,013h,044h,000h,00Fh,028h,000h,000h
                DB  000h,000h,000h,0FFh,000h,013h,0E1h,000h
                DB  011h,0CFh,000h,011h,0A1h,000h,018h,068h
                DB  000h,018h,050h,000h,013h,044h,000h,00Fh
                DB  028h,000h,000h,000h,000h,000h
;@ tbl_idle_mode type=u8 count=94 formula=raw category=Idle desc="94 bytes"
tbl_idle_mode:       DB  0FFh,0FFh,03Fh,0F5h,0FFh,03Fh,0E6h,000h
                DB  030h,0CFh,000h,026h,068h,000h,024h,050h
                DB  000h,01Eh,028h,000h,00Ch,020h,000h,014h
                DB  000h,000h,019h,0FFh,0FFh,03Fh,0F5h,0FFh
                DB  03Fh,0E6h,000h,030h,0CFh,000h,026h,068h
                DB  000h,024h,050h,000h,01Eh,028h,000h,00Ch
                DB  020h,000h,014h,000h,000h,019h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
;@ IdleVsECT type=u8 count=42 formula=raw category=Idle desc="42 bytes"
IdleVsECT:       DB  0CDh,0E2h,004h,0A1h,0E2h,004h,087h,03Bh
                DB  005h,06Eh,01Ah,006h,044h,053h,007h,028h
                DB  09Dh,008h,000h,027h,009h,0CDh,0B9h,004h
                DB  0A1h,0B9h,004h,087h,00Dh,005h,06Eh,0A2h
                DB  005h,044h,0A8h,006h,028h,053h,007h,000h
                DB  023h,008h
;@ tbl_idle_default1 type=u8 count=28 formula=raw category=Idle desc="28 bytes"
tbl_idle_default1:       DB  0FFh,0FFh,062h,000h,077h,00Ah,062h,000h
                DB  053h,007h,030h,000h,0A2h,005h,01Ch,000h
                DB  00Dh,005h,016h,000h,094h,004h,012h,000h
                DB  000h,000h,012h,000h
;@ tbl_idle_default2 type=u8 count=28 formula=raw category=Idle desc="28 bytes"
tbl_idle_default2:       DB  0FFh,0FFh,06Fh,000h,077h,00Ah,06Fh,000h
                DB  053h,007h,037h,000h,0A2h,005h,020h,000h
                DB  00Dh,005h,01Ah,000h,094h,004h,016h,000h
                DB  000h,000h,016h,000h
;@ tbl_idle_lookup4 type=u8 count=28 formula=raw category=Idle desc="28 bytes"
tbl_idle_lookup4:       DB  0FFh,0FFh,054h,002h,077h,00Ah,054h,002h
                DB  053h,007h,039h,001h,0A2h,005h,0C0h,000h
                DB  00Dh,005h,09Dh,000h,094h,004h,083h,000h
                DB  000h,000h,083h,000h
;@ tbl_idle_lookup3 type=u8 count=6 formula=raw category=Idle desc="6 bytes"
tbl_idle_lookup3:       DB  0FFh,0FFh,000h,001h,000h,004h
;@ tbl_idle_select_default type=u8 count=6 formula=raw category=Idle desc="6 bytes"
tbl_idle_select_default:       DB  0FFh,0FFh,000h,00Ch,000h,008h
;@ tbl_idle_select1 type=u8 count=6 formula=raw category=Idle desc="6 bytes"
tbl_idle_select1:       DB  000h,080h,000h,009h,040h,000h
;@ tbl_idle_gear2 type=u8 count=6 formula=raw category=Idle desc="6 bytes"
tbl_idle_gear2:       DB  000h,000h,000h,080h,001h,000h
;@ tbl_idle_timer type=u8 count=12 formula=raw category=Idle desc="12 bytes"
tbl_idle_timer:       DB  0FFh,0FFh,0FFh,0FFh,000h,000h,0FFh,0FFh
                DB  0FFh,0FFh,000h,000h
;@ tbl_idle_select3a type=u8 count=18 formula=raw category=Idle desc="18 bytes"
tbl_idle_select3a:       DB  0FFh,000h,000h,0C0h,000h,000h,0A0h,080h
                DB  001h,080h,000h,002h,030h,000h,003h,000h
                DB  000h,003h
;@ tbl_idle_select3b type=u8 count=28 formula=raw category=Idle desc="28 bytes"
tbl_idle_select3b:       DB  0FFh,000h,002h,0C0h,000h,002h,057h,000h
                DB  004h,036h,000h,006h,020h,000h,007h,000h
                DB  000h,007h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
;@ tbl_idle_stall type=u8 count=4 formula=raw category=Idle desc="4 bytes"
tbl_idle_stall:       DB  0EEh,000h,091h,04Ah
;@ tbl_ect_vecorrect type=u8 count=14 formula=raw category=Detected desc="14 bytes"
tbl_ect_vecorrect:       DB  0FFh,08Bh,0A1h,08Bh,087h,07Ch,06Eh,06Ah
                DB  044h,056h,028h,049h,000h,049h
;@ tbl_idle_gate6 type=u8 count=21 formula=raw category=Idle desc="21 bytes"
tbl_idle_gate6:       DB  0FFh,014h,000h,0A1h,014h,000h,087h,014h
                DB  000h,06Eh,014h,000h,044h,014h,000h,028h
                DB  014h,000h,000h,014h,000h
;@ tbl_ect_overrun_nor type=u8 count=14 formula=raw category=Detected desc="14 bytes"
tbl_ect_overrun_nor:       DB  0FFh,0C0h,0A1h,0C0h,087h,0A0h,06Eh,078h
                DB  044h,064h,028h,05Ah,000h,05Ah
;@ tbl_idle_sub1 type=u8 count=14 formula=raw category=Idle desc="14 bytes"
tbl_idle_sub1:       DB  0FFh,00Ah,0A1h,00Ah,087h,008h,06Eh,008h
                DB  044h,005h,028h,002h,000h,002h
;@ tbl_idle_sub2 type=u8 count=14 formula=raw category=Idle desc="14 bytes"
tbl_idle_sub2:       DB  0FFh,016h,0A1h,016h,087h,015h,06Eh,014h
                DB  044h,013h,028h,012h,000h,012h
;@ tbl_idle_pid_lo1 type=u8 count=12 formula=raw category=Idle desc="12 bytes"
tbl_idle_pid_lo1:       DB  0FFh,09Fh,040h,09Fh,02Ch,08Fh,020h,080h
                DB  01Ah,07Ch,000h,07Ch
;@ tbl_idle_pid_lo2 type=u8 count=12 formula=raw category=Idle desc="12 bytes"
tbl_idle_pid_lo2:       DB  0FFh,08Fh,040h,08Fh,02Ch,080h,020h,073h
                DB  01Ah,06Fh,000h,06Fh
;@ tbl_idle_pid_lo3 type=u8 count=12 formula=raw category=Idle desc="12 bytes"
tbl_idle_pid_lo3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
;@ tbl_idle_pid_a type=u8 count=12 formula=raw category=Idle desc="12 bytes"
tbl_idle_pid_a:       DB  0FFh,09Fh,040h,09Fh,02Ch,08Fh,020h,080h
                DB  01Ah,07Ch,000h,07Ch
;@ tbl_idle_pid_b type=u8 count=12 formula=raw category=Idle desc="12 bytes"
tbl_idle_pid_b:       DB  0FFh,08Fh,040h,08Fh,02Ch,080h,020h,073h
                DB  01Ah,06Fh,000h,06Fh
;@ tbl_idle_pid_hi1 type=u8 count=18 formula=raw category=Idle desc="18 bytes"
tbl_idle_pid_hi1:       DB  0FFh,020h,005h,0D0h,0C0h,003h,0B4h,0C0h
                DB  002h,08Ch,080h,000h,080h,000h,000h,000h
                DB  000h,000h
;@ tbl_idle_pid_hi2 type=u8 count=18 formula=raw category=Idle desc="18 bytes"
tbl_idle_pid_hi2:       DB  0FFh,0B0h,006h,0D0h,000h,005h,0B4h,070h
                DB  003h,08Ch,060h,001h,07Ch,000h,000h,000h
                DB  000h,000h
;@ tbl_idle_pid_hi3 type=u8 count=18 formula=raw category=Idle desc="18 bytes"
tbl_idle_pid_hi3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h
;@ tbl_idle_pid_c type=u8 count=18 formula=raw category=Idle desc="18 bytes"
tbl_idle_pid_c:       DB  0FFh,020h,005h,0D0h,0C0h,003h,0B4h,0C0h
                DB  002h,08Ch,080h,000h,080h,000h,000h,000h
                DB  000h,000h
;@ tbl_idle_pid_d type=u8 count=18 formula=raw category=Idle desc="18 bytes"
tbl_idle_pid_d:       DB  0FFh,0B0h,006h,0D0h,000h,005h,0B4h,070h
                DB  003h,08Ch,060h,001h,07Ch,000h,000h,000h
                DB  000h,000h
;@ tbl_ect_overrun_int type=u8 count=25 formula=raw category=Detected desc="25 bytes"
tbl_ect_overrun_int:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,0FFh,000h,00Bh,036h,000h,00Ch
                DB  020h,000h,012h,018h,000h,014h,000h,000h
                DB  015h
;@ tbl_idle_pid_final1 type=u8 count=15 formula=raw category=Idle desc="15 bytes"
tbl_idle_pid_final1:       DB  0FFh,000h,00Bh,036h,000h,00Ch,020h,000h
                DB  012h,018h,000h,014h,000h,000h,015h
;@ tbl_idle_pid_final2 type=u8 count=63 formula=raw category=Idle desc="63 bytes"
tbl_idle_pid_final2:       DB  0FFh,0C0h,0B0h,0C0h,080h,098h,053h,080h
                DB  000h,080h,0FFh,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,0FFh,0FFh,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,040h,0FFh,03Fh,004h,000h,000h
;@ tbl_idle_pid_out1 type=u8 count=11 formula=raw category=Idle desc="11 bytes"
tbl_idle_pid_out1:       DB  040h,0FFh,03Fh,004h,000h,000h,080h,080h
                DB  080h,080h,080h
;@ tbl_idle_pid_out2 type=u8 count=15 formula=raw category=Idle desc="15 bytes"
tbl_idle_pid_out2:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,080h,000h
                DB  01Ch,040h,000h,008h,000h,000h,006h
;@ tbl_idle_sub_gate1 type=u8 count=15 formula=raw category=Idle desc="15 bytes"
tbl_idle_sub_gate1:       DB  0FFh,000h,003h,000h,000h,003h,000h,000h
                DB  003h,000h,000h,003h,000h,000h,003h
;@ tbl_idle_sub_gate2 type=u8 count=15 formula=raw category=Idle desc="15 bytes"
tbl_idle_sub_gate2:       DB  0FFh,000h,006h,000h,000h,006h,000h,000h
                DB  006h,000h,000h,006h,000h,000h,006h
;@ tbl_ve_map_scalar_alt type=u8 count=60 formula=map_kpa category=Load desc="60 bytes"
tbl_ve_map_scalar_alt:       DB  0FFh,0FFh,03Fh,079h,0FFh,03Fh,055h,000h,020h,040h
                DB  000h,01Ah,039h,000h,00Ch,032h,000h,004h,02Bh,000h
                DB  000h,000h,000h,000h,0FFh,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
;@ tbl_iat_correct1 type=u8 count=18 formula=raw category=Detected desc="18 bytes"
tbl_iat_correct1:       DB  0FFh,000h,000h,02Ah,000h,000h,027h,080h
                DB  000h,023h,000h,001h,000h,000h,001h,000h
                DB  000h,001h
;@ tbl_iat_correct2 type=u8 count=4 formula=raw category=Detected desc="4 bytes"
tbl_iat_correct2:       DB  0EEh,080h,091h,0A1h
;@ tbl_knockwindow_9 type=u8 count=54 formula=raw category=Detected desc="54 bytes"
tbl_knockwindow_9:       DB  0FFh,0FFh,07Fh,0C0h,0FFh,07Fh,0B7h,000h
                DB  076h,0A1h,000h,05Eh,094h,000h,040h,087h
                DB  000h,02Eh,07Ah,000h,014h,072h,000h,005h
                DB  000h,000h,005h,0FFh,0FFh,07Fh,0C0h,0FFh
                DB  07Fh,0B7h,000h,076h,0A1h,000h,05Eh,094h
                DB  000h,040h,087h,000h,02Eh,07Ah,000h,014h
                DB  072h,000h,005h,000h,000h,005h
;@ tbl_idle_gear_target type=u8 count=32 formula=raw category=Idle desc="32 bytes"
tbl_idle_gear_target:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,000h,0C0h
                DB  080h,036h,066h,0A6h,0F0h,018h,000h,080h
                DB  010h,00Ah,066h,066h,000h,003h,033h,053h
                DB  0A0h,000h,066h,046h,000h,000h,0CCh,02Ch
;@ tbl_idle_dc type=u8 count=32 formula=raw category=Idle desc="32 bytes"
tbl_idle_dc:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h
                DB  000h,008h,01Eh,085h,080h,006h,01Eh,085h
                DB  000h,003h,085h,07Bh,000h,002h,033h,073h
                DB  000h,001h,028h,05Ch,000h,000h,028h,05Ch
;@ DwellBaseValues type=u8 count=16 formula=raw category=Detected desc="16 bytes"
DwellBaseValues:       DB  0D0h,0B8h,08Bh,09Ah,045h,05Ch,03Ah,055h
                DB  02Eh,04Dh,023h,03Ch,008h,010h,000h,010h
;@ DwellBattery type=u8 count=20 formula=raw category=Detected desc="20 bytes"
DwellBattery:       DB  0FFh,01Ch,0BCh,02Eh,0A7h,034h,092h,040h,07Dh,050h
                DB  068h,068h,054h,0A0h,03Fh,0D9h,000h,0D9h,000h,0D9h
;@ DwellBaseRPM type=u8 count=14 formula=raw category=RPM desc="14 bytes"
DwellBaseRPM:       DB  0FFh,050h,08Ah,022h,05Ch,017h,02Dh,009h
                DB  016h,002h,010h,000h,000h,000h
;@ tbl_knockwindow_10 type=u8 count=12 formula=raw category=Detected desc="12 bytes"
tbl_knockwindow_10:       DB  0FFh,000h,0AEh,000h,094h,01Eh,04Ch,01Eh
                DB  040h,000h,000h,000h
;@ tbl_ignmap_idle1 type=u16 formula=raw category=Ignition
tbl_ignmap_idle1:                 DW  088adh
;@ ECTIgnCorrect type=u8 count=28 formula=ign_advance category=Ignition desc="28 bytes"
ECTIgnCorrect:       DB  0FFh,0F3h,0F5h,0F3h,0CFh,0CCh,0A1h,0A2h
                DB  057h,08Ch,02Eh,080h,01Ch,080h,018h,074h
                DB  00Fh,06Ch,000h,06Ch,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
;@ tbl_ignmap_idle2 type=u8 count=4 formula=ign_advance category=Ignition desc="4 bytes"
tbl_ignmap_idle2:       DB  077h,064h,0D4h,064h
;@ IATCorrect type=u8 count=24 formula=raw category=Detected desc="24 bytes"
IATCorrect:       DB  0FFh,080h,0E6h,080h,0CFh,080h,0A1h,080h
                DB  057h,080h,049h,076h,030h,06Ah,028h,066h
                DB  000h,062h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ tbl_knockretard type=u8 count=30 formula=raw category=Detected desc="30 bytes"
tbl_knockretard:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h,000h,080h,000h,080h,000h,080h
                DB  0FFh,000h,06Ch,000h,044h,00Ch,02Eh,015h,000h,015h
;@ HiIdleIgnControl type=u16 count=4 colstride=4 category=Ignition slot=idle.ign.high desc="High idle ignition control (4-byte entries)."
HiIdleIgnControl:       DB  0FFh,0FFh,015h,000h,0CDh,000h,015h,000h
                DB  073h,000h,00Ch,000h,000h,000h,000h,000h
;@ IgnControl type=u16 count=4 colstride=4 category=Ignition slot=idle.ign.low desc="Low idle ignition control (4-byte entries)."
IgnControl:       DB  0FFh,0FFh,015h,000h,0B2h,000h,015h,000h
                DB  068h,000h,00Ch,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,015h,022h,02Fh,033h
                DB  037h,03Ch,051h,052h,052h,052h,052h,000h
                DB  000h,000h,000h
;@ tbl_boot_copy_block type=u8 count=61 formula=raw category=Detected desc="61 bytes"
tbl_boot_copy_block:       DB  000h,000h,000h,000h,000h,015h,022h,02Fh
                DB  033h,037h,03Ch,051h,052h,052h,052h,052h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,015h,02Fh,037h,051h
                DB  051h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  015h,02Fh,037h,051h,051h
;@ TipinTPS type=u8 count=14 formula=percent255 category=Throttle desc="14 bytes"
TipinTPS:       DB  0FFh,050h,0D0h,040h,0C0h,038h,0A0h,030h
                DB  080h,030h,040h,028h,000h,028h
;@ TipinRPM type=u8 count=13 formula=raw category=RPM desc="13 bytes"
TipinRPM:       DB  0FFh,055h,0C0h,055h,090h,055h,080h,055h
                DB  066h,055h,040h,02Ah,000h
;@ TipinEnrich type=u8 count=6 formula=raw category=Detected desc="6 bytes"
TipinEnrich:       DB  02Ah,001h,006h,003h,001h,001h
;@ TipinRetard type=u8 count=42 formula=raw category=Detected desc="42 bytes"
TipinRetard:       DB  0FFh,080h,04Dh,080h,040h,05Ah,030h,040h
                DB  028h,026h,000h,026h,0FFh,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h
;@ TipinGear type=u8 count=5 formula=hts_trim_128 category=Detected slot=tpsretard.gearmul desc="8 bytes"
TipinGear:       DB  080h,080h,080h,05Ah,047h,0ADh,070h,02Eh
;@ tbl_map_sign type=u8 count=4 formula=ign_advance category=Ignition desc="4 bytes"
tbl_map_sign:       DB  060h,0F0h,020h,070h
;@ tbl_ect_simulate_ramp type=u8 count=5 formula=raw category=Detected desc="5 bytes"
tbl_ect_simulate_ramp:       DB  0E1h,0D0h,0A1h,070h,028h
;@ tbl_dcode14_lo type=u8 count=6 formula=raw category=Detected desc="6 bytes"
tbl_dcode14_lo:       DB  0C2h,000h,0FAh,03Eh,000h,047h
;@ tbl_dcode14_hi type=u8 count=10 formula=raw category=Detected desc="10 bytes"
tbl_dcode14_hi:       DB  0E5h,000h,051h,03Eh,000h,019h,02Ch,0A0h,025h,05Ah
;@ tbl_knock244_a type=u8 count=20 formula=raw category=Detected desc="20 bytes"
tbl_knock244_a:       DB  000h,011h,011h,011h,011h,011h,011h,011h,011h,011h
                DB  011h,008h,001h,000h,000h,000h,000h,000h,000h,000h
;@ tbl_knock244_b type=u8 count=14 formula=raw category=Detected desc="14 bytes"
tbl_knock244_b:       DB  011h,011h,011h,011h,011h,011h,011h,011h
                DB  011h,011h,011h,011h,011h,011h
;@ tbl_dtc_code_map type=u8 count=49 formula=map_kpa category=Load desc="49 bytes"
tbl_dtc_code_map:       DB  00Bh,00Fh,00Fh,00Fh,0FFh,02Dh,04Bh,00Fh
                DB  0FFh,0FFh,0FFh,00Fh,02Dh,02Dh,0FFh,0FFh
                DB  02Dh,006h,02Dh,00Fh,00Fh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,014h,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,02Dh,02Dh,007h,006h,0FFh,0FFh,019h
                DB  0FFh,019h,019h,019h,0FFh,0FFh,0FFh,0FFh
                DB  0B3h
;@ tbl_cfgvariant_map type=u8 count=49 formula=map_kpa category=Load desc="49 bytes"
tbl_cfgvariant_map:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah
                DB  00Bh,00Ch,00Ch,00Dh,00Eh,011h,000h,013h
                DB  014h,015h,016h,017h,018h,01Eh,01Fh,000h
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h
                DB  000h,004h,008h,009h,00Fh,01Eh,01Fh,010h
                DB  013h,004h,008h,009h,000h,000h,000h,000h
                DB  01Dh
;@ tbl_diag_snapshot_data1 type=u8 count=3 formula=raw category=Detected desc="3 bytes"
tbl_diag_snapshot_data1:       DB  001h,094h,000h
;@ tbl_diag_snapshot_data2 type=u8 count=5 formula=raw category=Detected desc="5 bytes"
tbl_diag_snapshot_data2:       DB  019h,0FFh,019h,019h,019h
;@ tbl_crank_sync_pattern type=u8 count=24 formula=raw category=Detected desc="24 bytes"
tbl_crank_sync_pattern:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FEh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FDh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FEh,0FFh,0FFh,0FFh,0FFh,0FFh,0FDh
;@ tbl_crank_tooth_pattern type=u8 count=30 formula=raw category=Detected desc="30 bytes"
tbl_crank_tooth_pattern:       DB  007h,008h,009h,00Ah,00Bh,000h,001h,002h,003h,004h
                DB  005h,006h,007h,008h,009h,00Ah,00Bh,000h,001h,002h
                DB  003h,004h,005h,006h,007h,008h,009h,00Ah,00Bh,000h
;@ tbl_knock_sanity type=u8 count=32 formula=raw category=Detected desc="32 bytes"
tbl_knock_sanity:       DB  000h,000h,077h,022h,0EEh,044h,077h,044h
                DB  0DDh,088h,0FFh,0FFh,0EEh,088h,077h,088h
                DB  0BBh,011h,0BBh,022h,0FFh,0FFh,0BBh,044h
                DB  0DDh,011h,0DDh,022h,0EEh,011h,000h,000h
;@ tbl_idle_target_refine1 type=u8 count=28 formula=raw category=Idle desc="28 bytes"
tbl_idle_target_refine1:       DB  0FFh,0FFh,046h,000h,077h,00Ah,046h,000h
                DB  053h,007h,056h,000h,0A2h,005h,06Ah,000h
                DB  00Dh,005h,07Ch,000h,094h,004h,08Bh,000h
                DB  000h,000h,08Bh,000h
;@ tbl_idle_target_refine2 type=u8 count=28 formula=raw category=Idle desc="28 bytes"
tbl_idle_target_refine2:       DB  0FFh,0FFh,050h,000h,077h,00Ah,050h,000h
                DB  053h,007h,063h,000h,0A2h,005h,076h,000h
                DB  00Dh,005h,085h,000h,094h,004h,092h,000h
                DB  000h,000h,092h,000h
;@ tbl_idle_step type=u8 count=21 formula=raw category=Idle desc="21 bytes"
tbl_idle_step:       DB  0FFh,000h,000h,0A1h,000h,000h,087h,054h
                DB  000h,06Eh,067h,000h,044h,0ABh,000h,028h
                DB  050h,001h,000h,050h,001h
;@ tbl_tipin_enrich_rpm type=u8 count=132 formula=raw category=RPM desc="132 bytes"
tbl_tipin_enrich_rpm:       DB  0FFh,0E8h,003h,030h,0E8h,003h,000h,07Dh
                DB  000h,000h,07Dh,000h,0FFh,0EEh,002h,040h
                DB  0EEh,002h,010h,0FAh,000h,000h,032h,000h
                DB  0FFh,033h,004h,040h,033h,004h,000h,064h
                DB  000h,000h,064h,000h,0FFh,0E8h,003h,040h
                DB  0E8h,003h,010h,0C8h,000h,000h,032h,000h
                DB  0FFh,0B0h,004h,040h,0B0h,004h,000h,07Dh
                DB  000h,000h,07Dh,000h,0FFh,0E8h,003h,040h
                DB  0E8h,003h,010h,05Eh,001h,000h,032h,000h
                DB  0FFh,0B0h,004h,040h,0B0h,004h,000h,0C8h
                DB  000h,000h,0C8h,000h,0FFh,0E8h,003h,030h
                DB  0E8h,003h,000h,07Dh,000h,000h,07Dh,000h
                DB  0FFh,0E8h,003h,030h,0E8h,003h,000h,07Dh
                DB  000h,000h,07Dh,000h,0FFh,0E8h,003h,030h
                DB  0E8h,003h,000h,07Dh,000h,000h,07Dh,000h
                DB  0FFh,0E8h,003h,030h,0E8h,003h,000h,07Dh
                DB  000h,000h,07Dh,000h
;@ tbl_tipin_normal_enrich type=u8 count=132 formula=raw category=Detected desc="132 bytes"
tbl_tipin_normal_enrich:       DB  090h,001h,00Ah,001h,040h,000h,019h,000h
                DB  008h,000h,000h,000h,0C2h,001h,02Ch,001h
                DB  040h,000h,019h,000h,008h,000h,000h,000h
                DB  0C2h,001h,02Ch,001h,040h,000h,019h,000h
                DB  008h,000h,000h,000h,0C2h,001h,02Ch,001h
                DB  040h,000h,019h,000h,008h,000h,000h,000h
                DB  0C2h,001h,02Ch,001h,040h,000h,019h,000h
                DB  008h,000h,000h,000h,0C2h,001h,02Ch,001h
                DB  040h,000h,019h,000h,00Ch,000h,000h,000h
                DB  0C2h,001h,02Ch,001h,040h,000h,019h,000h
                DB  00Ch,000h,000h,000h,0C2h,001h,0FAh,000h
                DB  040h,000h,019h,000h,00Ch,000h,000h,000h
                DB  0C2h,001h,0FAh,000h,040h,000h,019h,000h
                DB  00Ch,000h,000h,000h,0C2h,001h,0FAh,000h
                DB  080h,000h,032h,000h,018h,000h,000h,000h
                DB  0C2h,001h,0FAh,000h,080h,000h,032h,000h
                DB  018h,000h,000h,000h
;@ tbl_ve_map_scalar type=u8 count=24 formula=map_kpa category=Load desc="24 bytes"
tbl_ve_map_scalar:       DB  0FFh,0FFh,03Fh,079h,0FFh,03Fh,055h,000h
                DB  034h,040h,000h,02Eh,039h,000h,020h,032h
                DB  000h,018h,02Bh,000h,014h,000h,000h,014h
;@ S_MAP_Scaler type=u8 count=10 formula=map_mbar category=Axes desc="load axis breakpoints of IGN2_Lo"
S_MAP_Scaler:       DB  004h,033h,043h,052h,062h,072h,082h,089h
                DB  090h,098h,0A7h,0B9h,0CAh,0DBh,0EDh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ S_LO_Scaler type=u8 count=20 formula=rpm_axis_byte_log category=Axes desc="rpm axis breakpoints of IGN2_Lo"
S_LO_Scaler:       DB  002h,00Dh,01Ah,029h,040h,053h,060h,070h,080h,088h
                DB  092h,0A2h,0A5h,0AEh,0C0h,0C7h,0D0h,0E0h,0F0h,000h
;@ S_HI_Scaler type=u8 count=20 formula=rpm_axis_byte category=Axes desc="rpm axis breakpoints of IGN2_HI"
S_HI_Scaler:       DB  000h,00Eh,017h,023h,02Fh,03Ah,046h,052h
                DB  05Dh,069h,06Fh,074h,07Bh,081h,08Bh,097h
                DB  0A3h,0AEh,0BBh,0D1h,0FFh,0FFh
;@ P_MAP_Scaler type=u8 count=10 formula=map_mbar category=Axes desc="load axis breakpoints of IGN1_Lo"
P_MAP_Scaler:       DB  01Bh,033h,043h,052h,062h,072h,082h,089h
                DB  090h,098h,0A7h,0B9h,0CAh,0DBh,0EDh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
;@ P_LO_Scaler type=u8 count=20 formula=rpm_axis_byte_log category=Axes desc="rpm axis breakpoints of IGN1_Lo"
P_LO_Scaler:       DB  002h,00Dh,01Ah,029h,040h,053h,060h,070h,080h,088h
                DB  092h,0A2h,0A5h,0AEh,0C0h,0C7h,0D0h,0E0h,0F0h,000h
;@ P_HI_Scaler type=u8 count=20 formula=rpm_axis_byte category=Axes desc="rpm axis breakpoints of IGN1_Hi"
P_HI_Scaler:       DB  000h,00Eh,017h,023h,02Fh,03Ah,046h,052h,05Dh,069h
                DB  06Fh,074h,07Bh,081h,08Bh,097h,0A3h,0AEh,0BBh,0D1h
;@ VE_SCALER type=u8 count=20 formula=rpm_axis_byte_log category=Axes desc="rpm axis breakpoints of VEhi"
VE_SCALER:       DB  000h,011h,01Ch,02Bh,039h,047h,055h,064h,072h,080h
                DB  08Eh,095h,09Ch,0A3h,0ABh,0B9h,0C7h,0D5h,0E4h,000h
;@ FUEL1_Lo type=u8 size=20x10 stride=24 colscale=0708Dh formula=honda_fuel rows.axis=P_LO_Scaler rows.formula=rpm_axis_byte_log rows.unit=rpm cols.axis=P_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Fuel desc="20 x 10 map (24 bytes per row), column multipliers after the last row; rows: low-cam rpm (P_LO_Scaler), columns: load (P_MAP_Scaler)"
FUEL1_Lo:       DB  044h,07Bh,091h,084h,08Bh,093h,08Ch,096h
                DB  094h,09Bh,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  044h,07Bh,091h,084h,08Bh,093h,08Ch,096h
                DB  094h,09Ch,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  044h,07Bh,092h,083h,08Ch,094h,08Ch,097h
                DB  095h,0A0h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  048h,07Dh,094h,087h,08Dh,096h,08Dh,098h
                DB  096h,0A2h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  048h,081h,098h,089h,091h,099h,090h,09Bh
                DB  099h,0A5h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  048h,087h,09Eh,08Eh,096h,09Eh,096h,09Dh
                DB  099h,0A5h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  048h,089h,09Eh,08Dh,095h,09Eh,096h,0A0h
                DB  09Eh,0AAh,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  048h,087h,09Bh,08Ah,094h,09Ch,093h,09Eh
                DB  09Ah,0A5h,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  04Ch,090h,0A5h,093h,09Eh,0A6h,09Bh,0A6h
                DB  0AAh,0B6h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  048h,08Bh,09Fh,08Dh,097h,09Fh,096h,0A1h
                DB  09Eh,0AAh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  048h,08Bh,09Fh,08Ch,097h,09Eh,096h,0A1h
                DB  09Eh,0AAh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  048h,08Ch,0A0h,08Dh,096h,09Eh,096h,0A0h
                DB  09Ch,0A8h,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  04Ch,093h,0A7h,094h,09Dh,0A4h,09Ah,0A3h
                DB  0A0h,0ADh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  04Ch,083h,09Dh,08Fh,09Ch,0A4h,09Ah,0A3h
                DB  0A0h,0ADh,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  050h,097h,0B0h,09Fh,0ABh,0B5h,0AAh,0B8h
                DB  0B3h,0D3h,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  070h,0A7h,0BEh,0ACh,0B7h,0C0h,0B4h,0BDh
                DB  0B7h,0D9h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  078h,0A9h,0BFh,0ACh,0B9h,0C0h,0B3h,0BFh
                DB  0B9h,0DBh,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  050h,094h,0ACh,09Dh,0AAh,0ADh,0A6h,0B1h
                DB  0ACh,0CCh,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  050h,094h,0ACh,09Dh,0AAh,0ADh,0A6h,0B1h
                DB  0ACh,0CCh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  050h,094h,0AAh,09Dh,0AAh,0ADh,0A6h,0B1h
                DB  0ACh,0CCh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  001h,003h,004h,006h,007h,008h,00Ah,00Ah
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
;@ FUEL1_Hi type=u8 size=20x10 stride=24 colscale=07285h formula=honda_fuel rows.axis=P_HI_Scaler rows.formula=rpm_axis_byte rows.unit=rpm cols.axis=P_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Fuel desc="20 x 10 map (24 bytes per row), column multipliers after the last row; rows: high-cam rpm (P_HI_Scaler), columns: load (P_MAP_Scaler)"
FUEL1_Hi:       DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
FUEL1_Hi_Extended:       DB  0AEh,0AEh,04Ch,08Fh,0A4h,093h,09Bh,0A7h
                DB  0ADh,0A8h,0A9h,0B9h,0B7h,0B7h,0B7h,0B7h
                DB  0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  0B7h,0B7h,018h,078h,096h,08Ch,097h,0A5h
                DB  0B0h,0ABh,0AEh,0BAh,0AFh,0AFh,0AFh,0AFh
                DB  0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  0AFh,0AFh,018h,077h,093h,08Bh,099h,0A4h
                DB  0ADh,0AAh,0A9h,0B2h,0B4h,0B4h,0B4h,0B4h
                DB  0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  0B4h,0B4h,014h,08Fh,0A7h,099h,0A6h,0B2h
                DB  0BDh,0B5h,0AFh,0B7h,0BFh,0BFh,0BFh,0BFh
                DB  0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  0BFh,0BFh,03Ch,08Fh,0A8h,09Dh,0ABh,0B8h
                DB  0BFh,0B6h,0B0h,0B8h,0CDh,0CDh,0CDh,0CDh
                DB  0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  0CDh,0CDh,000h,09Bh,0B3h,0A3h,0B2h,0BAh
                DB  0C4h,0BDh,0B9h,0BBh,0BCh,0BCh,0BCh,0BCh
                DB  0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  0BCh,0BCh,038h,0A7h,0C1h,0B1h,0C0h,0CBh
                DB  0D5h,0CAh,0BFh,0C2h,0BDh,0BDh,0BDh,0BDh
                DB  0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  0BDh,0BDh,060h,0B3h,0CCh,0B9h,0C7h,0CEh
                DB  0D4h,0CBh,0C0h,0C8h,0C0h,0C0h,0C0h,0C0h
                DB  0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  0C0h,0C0h,07Ch,0B8h,0D8h,0BFh,0CAh,0D0h
                DB  0D7h,0CCh,0C5h,0CAh,0CBh,0CBh,0CBh,0CBh
                DB  0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  0CBh,0CBh,048h,0BBh,0D5h,0C5h,0D1h,0D5h
                DB  0DEh,0D4h,0CAh,0CBh,0D2h,0D2h,0D2h,0D2h
                DB  0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  0D2h,0D2h,05Ch,0A1h,0C7h,0C3h,0D1h,0D6h
                DB  0DAh,0D9h,0C8h,0CBh,0D6h,0D6h,0D6h,0D6h
                DB  0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  0D6h,0D6h,040h,08Fh,0B6h,0ADh,0BCh,0CBh
                DB  0CAh,0C2h,0B6h,0BFh,0D5h,0D5h,0D5h,0D5h
                DB  0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  0D5h,0D5h,040h,08Fh,0B6h,0ADh,0BCh,0CBh
                DB  0CAh,0C2h,0B6h,0BFh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,040h,08Fh,0B6h,0ADh,0BCh,0CBh
                DB  0CAh,0C2h,0B6h,0BFh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,001h,003h,004h,006h,007h,008h
                DB  009h,00Ah,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
                DB  00Bh,00Bh
;@ IGN1_Lo type=u8 size=20x10 stride=24 formula=ign_advance rows.axis=P_LO_Scaler rows.formula=rpm_axis_byte_log rows.unit=rpm cols.axis=P_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Ignition desc="20 x 10 map (24 bytes per row); rows: low-cam rpm (P_LO_Scaler), columns: load (P_MAP_Scaler)"
IGN1_Lo:       DB  05Ah,05Ah,05Ah,052h,044h,030h,020h,00Fh
                DB  000h,000h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h
                DB  05Ah,05Ah,05Ah,052h,044h,030h,020h,00Fh
                DB  000h,000h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h
                DB  05Ah,05Ah,05Ah,052h,044h,030h,020h,00Fh
                DB  000h,000h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h
                DB  05Ah,05Ah,05Ah,052h,044h,030h,020h,00Fh
                DB  000h,000h,012h,012h,012h,012h,012h,012h
                DB  012h,012h,012h,012h,012h
IGN1_Lo_Extended:       DB  012h,012h,012h,06Fh,06Fh,06Fh,069h,061h
                DB  049h,031h,022h,015h,011h,02Ch,02Ch,02Ch
                DB  02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch
                DB  02Ch,02Ch,02Ch,087h,087h,087h,07Dh,073h
                DB  059h,040h,033h,024h,020h,036h,036h,036h
                DB  036h,036h,036h,036h,036h,036h,036h,036h
                DB  036h,036h,036h,08Fh,08Fh,08Fh,085h,079h
                DB  060h,047h,03Bh,02Dh,029h,03Ch,03Ch,03Ch
                DB  03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch
                DB  03Ch,03Ch,03Ch,097h,097h,097h,08Bh,07Dh
                DB  066h,04Eh,043h,035h,031h,046h,046h,046h
                DB  046h,046h,046h,046h,046h,046h,046h,046h
                DB  046h,046h,046h,09Eh,09Eh,09Eh,091h,085h
                DB  072h,05Ah,04Fh,042h,03Eh,04Eh,04Eh,04Eh
                DB  04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh
                DB  04Eh,04Eh,04Eh,0A2h,0A2h,0A2h,095h,089h
                DB  077h,061h,055h,046h,041h,055h,055h,055h
                DB  055h,055h,055h,055h,055h,055h,055h,055h
                DB  055h,055h,055h,0A6h,0A6h,0A6h,098h,08Ch
                DB  07Bh,065h,058h,048h,044h,059h,059h,059h
                DB  059h,059h,059h,059h,059h,059h,059h,059h
                DB  059h,059h,059h,0AFh,0AFh,0AFh,0A1h,093h
                DB  084h,06Fh,05Fh,04Eh,04Ah,06Bh,06Bh,06Bh
                DB  06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh
                DB  06Bh,06Bh,06Bh,0B7h,0B7h,0B7h,0AAh,09Ah
                DB  08Ch,078h,067h,054h,050h,06Ch,06Ch,06Ch
                DB  06Ch,06Ch,06Ch,06Ch,06Ch,06Ch,06Ch,06Ch
                DB  06Ch,06Ch,06Ch,0C7h,0C7h,0C7h,0BEh,0B3h
                DB  0ABh,09Ah,08Ah,070h,070h,070h,070h,070h
                DB  070h,070h,070h,070h,070h,070h,070h,070h
                DB  070h,070h,070h,0C7h,0C7h,0C7h,0BEh,0B3h
                DB  0ABh,09Ah,08Dh,07Ch,07Ch,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,0C7h,0C7h,0C7h,0BEh,0B3h
                DB  0ABh,09Ah,08Dh,07Ch,07Ch,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,0C7h,0C7h,0C7h,0BEh,0B3h
                DB  0ABh,09Ah,08Dh,084h,084h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,0C7h,0C7h,0C7h,0BEh,0B3h
                DB  0ABh,09Ah,08Dh,084h,084h,06Dh,06Dh,06Dh
                DB  06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh
                DB  06Dh,06Dh,06Dh,0C7h,0C7h,0C7h,0BEh,0B3h
                DB  0ABh,09Ah,08Dh,084h,084h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,081h,0C8h,0C8h,0C8h,0BDh,0B3h
                DB  0ABh,09Ah,08Dh,084h,084h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,081h
;@ IGN1_Hi type=u8 size=20x10 stride=24 formula=ign_advance rows.axis=P_HI_Scaler rows.formula=rpm_axis_byte rows.unit=rpm cols.axis=P_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Ignition desc="20 x 10 map (24 bytes per row); rows: high-cam rpm (P_HI_Scaler), columns: load (P_MAP_Scaler)"
IGN1_Hi:       DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,010h,000h,000h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,05Ah,05Ah,05Ah,05Ah,044h,030h
                DB  020h,010h,000h,000h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,078h,078h
                DB  078h,071h,065h,04Ch,031h,022h,015h,011h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,095h,095h,095h,089h,07Ch,067h,04Ch,041h
                DB  033h,02Fh,012h,012h,012h,012h,012h,012h,012h,012h
                DB  012h,012h,012h,012h,012h,012h,0A2h,0A2h,0A2h,095h
                DB  089h,077h,061h,055h,049h,045h,02Ch,02Ch,02Ch,02Ch
                DB  02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch
IGN1_Hi_Extended:       DB  0B7h,0B7h,0B7h,0A9h,09Ah,08Bh,078h,064h
                DB  051h,04Dh,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah
                DB  03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah
                DB  0C5h,0C5h,0C5h,0B8h,0ADh,0A5h,099h,07Ah
                DB  062h,05Eh,044h,044h,044h,044h,044h,044h
                DB  044h,044h,044h,044h,044h,044h,044h,044h
                DB  0C7h,0C7h,0C7h,0BAh,0B3h,0ABh,0A1h,08Dh
                DB  073h,073h,046h,046h,046h,046h,046h,046h
                DB  046h,046h,046h,046h,046h,046h,046h,046h
                DB  0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh
                DB  07Ch,07Ch,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh
                DB  04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh
                DB  0C7h,0C7h,0C7h,0BEh,0AFh,0ABh,09Ah,08Dh
                DB  07Ch,07Ch,055h,055h,055h,055h,055h,055h
                DB  055h,055h,055h,055h,055h,055h,055h,055h
                DB  0C8h,0C8h,0C8h,0C1h,0B2h,0AEh,09Ah,08Dh
                DB  080h,080h,059h,059h,059h,059h,059h,059h
                DB  059h,059h,059h,059h,059h,059h,059h,059h
                DB  0C8h,0C8h,0C8h,0C4h,0B5h,0B1h,09Ah,08Dh
                DB  084h,084h,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh
                DB  06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh
                DB  0C8h,0C8h,0C8h,0C3h,0B4h,0AFh,09Ah,08Dh
                DB  084h,084h,070h,070h,070h,070h,070h,070h
                DB  070h,070h,070h,070h,070h,070h,070h,070h
                DB  0C8h,0C8h,0C8h,0C0h,0B4h,0ADh,09Ah,08Dh
                DB  084h,084h,070h,070h,070h,070h,070h,070h
                DB  070h,070h,070h,070h,070h,070h,070h,070h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh
                DB  06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h
                DB  0FFh,0FFh
;@ FUEL2_Lo type=u8 size=20x10 stride=24 colscale=0783Fh formula=honda_fuel rows.axis=S_LO_Scaler rows.formula=rpm_axis_byte_log rows.unit=rpm cols.axis=S_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Fuel desc="20 x 10 map (24 bytes per row), column multipliers after the last row; rows: low-cam rpm (S_LO_Scaler), columns: load (S_MAP_Scaler)"
FUEL2_Lo:       DB  044h,07Bh,091h,084h,08Bh,093h,08Ch,096h
                DB  094h,09Bh,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  044h,07Bh,091h,084h,08Bh,093h,08Ch,096h
                DB  094h,09Ch,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  044h,07Bh,092h,083h,08Ch,094h,08Ch,097h
                DB  095h,0A0h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  048h,07Dh,094h,087h,08Dh,096h,08Dh,098h
                DB  096h,0A2h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  048h,081h,098h,089h,091h,099h,090h,09Bh
                DB  099h,0A5h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  048h,087h,09Eh,08Eh,096h,09Eh,096h,09Dh
                DB  099h,0A5h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  048h,089h,09Eh,08Dh,095h,09Eh,096h,0A0h
                DB  09Eh,0AAh,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  048h,087h,09Bh,08Ah,094h,09Ch,093h,09Eh
                DB  09Ah,0A5h,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  04Ch,090h,0A5h,093h,09Eh,0A6h,09Bh,0A6h
                DB  0AAh,0B6h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  048h,08Bh,09Fh,08Dh,097h,09Fh,096h,0A1h
                DB  09Eh,0AAh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  048h,08Bh,09Fh,08Ch,097h,09Eh,096h,0A1h
                DB  09Eh,0AAh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  048h,08Ch,0A0h,08Dh,096h,09Eh,096h,0A0h
                DB  09Ch,0A8h,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  04Ch,093h,0A7h,094h,09Dh,0A4h,09Ah,0A3h
                DB  0A0h,0ADh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  04Ch,083h,09Dh,08Fh,09Ch,0A4h,09Ah,0A3h
                DB  0A0h,0ADh,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  050h,097h,0B0h,09Fh,0ABh,0B5h,0AAh,0B8h
                DB  0B3h,0D3h,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  070h,0A7h,0BEh,0ACh,0B7h,0C0h,0B4h,0BDh
                DB  0B7h,0D9h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  078h,0A9h,0BFh,0ACh,0B9h,0C0h,0B3h,0BFh
                DB  0B9h,0DBh,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  050h,094h,0ACh,09Dh,0AAh,0ADh,0A6h,0B1h
                DB  0ACh,0CCh,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  050h,094h,0ACh,09Dh,0AAh,0ADh,0A6h,0B1h
                DB  0ACh,0CCh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  050h,094h,0AAh,09Dh,0AAh,0ADh,0A6h,0B1h
                DB  0ACh,0CCh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  001h,003h,004h,006h,007h,008h,00Ah,00Ah
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
;@ FUEL2_Hi type=u8 size=20x10 stride=24 colscale=07A37h formula=honda_fuel rows.axis=S_HI_Scaler rows.formula=rpm_axis_byte rows.unit=rpm cols.axis=S_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Fuel desc="20 x 10 map (24 bytes per row), column multipliers after the last row; rows: high-cam rpm (S_HI_Scaler), columns: load (S_MAP_Scaler)"
FUEL2_Hi:       DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h,0A8h
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h,0A9h
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  028h,077h,08Ah,07Fh,08Bh,096h,09Ch,097h
                DB  09Ah,0A4h,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh,0AEh
                DB  04Ch,08Fh,0A4h,093h,09Bh,0A7h,0ADh,0A8h
                DB  0A9h,0B9h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h,0B7h
                DB  018h,078h,096h,08Ch,097h,0A5h,0B0h,0ABh
                DB  0AEh,0BAh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh,0AFh
                DB  018h,077h,093h,08Bh,099h,0A4h,0ADh,0AAh
                DB  0A9h,0B2h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h,0B4h
                DB  014h,08Fh,0A7h,099h,0A6h,0B2h,0BDh,0B5h
                DB  0AFh,0B7h,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh,0BFh
                DB  03Ch,08Fh,0A8h,09Dh,0ABh,0B8h,0BFh,0B6h
                DB  0B0h,0B8h,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh,0CDh
                DB  000h,09Bh,0B3h,0A3h,0B2h,0BAh,0C4h,0BDh
                DB  0B9h,0BBh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh,0BCh
                DB  038h,0A7h,0C1h,0B1h,0C0h,0CBh,0D5h,0CAh
                DB  0BFh,0C2h,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh,0BDh
                DB  060h,0B3h,0CCh,0B9h,0C7h,0CEh,0D4h,0CBh
                DB  0C0h,0C8h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h,0C0h
                DB  07Ch,0B8h,0D8h,0BFh,0CAh,0D0h,0D7h,0CCh
                DB  0C5h,0CAh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh,0CBh
                DB  048h,0BBh,0D5h,0C5h,0D1h,0D5h,0DEh,0D4h
                DB  0CAh,0CBh,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h,0D2h
                DB  05Ch,0A1h,0C7h,0C3h,0D1h,0D6h,0DAh,0D9h
                DB  0C8h,0CBh,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h,0D6h
                DB  040h,08Fh,0B6h,0ADh,0BCh,0CBh,0CAh,0C2h
                DB  0B6h,0BFh,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h,0D5h
                DB  040h,08Fh,0B6h,0ADh,0BCh,0CBh,0CAh,0C2h
                DB  0B6h,0BFh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  040h,08Fh,0B6h,0ADh,0BCh,0CBh,0CAh,0C2h
                DB  0B6h,0BFh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh,0CEh
                DB  001h,003h,004h,006h,007h,008h,009h,00Ah
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
                DB  00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh,00Bh
;@ IGN2_Lo type=u8 size=20x10 stride=24 formula=ign_advance rows.axis=S_LO_Scaler rows.formula=rpm_axis_byte_log rows.unit=rpm cols.axis=S_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Ignition desc="20 x 10 map (24 bytes per row); rows: low-cam rpm (S_LO_Scaler), columns: load (S_MAP_Scaler)"
IGN2_Lo:       DB  05Ah,05Ah,05Ah,052h,044h,030h,020h,00Fh,000h,000h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,05Ah,05Ah,05Ah,052h,044h,030h
                DB  020h,00Fh,000h,000h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,05Ah,05Ah
                DB  05Ah,052h,044h,030h,020h,00Fh,000h,000h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,05Ah,05Ah,05Ah,052h,044h,030h,020h,00Fh
                DB  000h,000h,012h,012h,012h,012h,012h,012h,012h,012h
                DB  012h,012h,012h,012h,012h,012h,06Fh,06Fh,06Fh,069h
                DB  061h,049h,031h,022h,015h,011h,02Ch,02Ch,02Ch,02Ch
                DB  02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch
                DB  087h,087h,087h,07Dh,073h,059h,040h,033h,024h,020h
                DB  036h,036h,036h,036h,036h,036h,036h,036h,036h,036h
                DB  036h,036h,036h,036h,08Fh,08Fh,08Fh,085h,079h,060h
                DB  047h,03Bh,02Dh,029h,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch
                DB  03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,03Ch,097h,097h
                DB  097h,08Bh,07Dh,066h,04Eh,043h,035h,031h,046h,046h
                DB  046h,046h,046h,046h,046h,046h,046h,046h,046h,046h
                DB  046h,046h,09Eh,09Eh,09Eh,091h,085h,072h,05Ah,04Fh
                DB  042h,03Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh
                DB  04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,0A2h,0A2h,0A2h,095h
                DB  089h,077h,061h,055h,046h,041h,055h,055h,055h,055h
                DB  055h,055h,055h,055h,055h,055h,055h,055h,055h,055h
                DB  0A6h,0A6h,0A6h,098h,08Ch,07Bh,065h,058h,048h,044h
                DB  059h,059h,059h,059h,059h,059h,059h,059h,059h,059h
                DB  059h,059h,059h,059h,0AFh,0AFh,0AFh,0A1h,093h,084h
                DB  06Fh,05Fh,04Eh,04Ah,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh
                DB  06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,0B7h,0B7h
                DB  0B7h,0AAh,09Ah,08Ch,078h,067h,054h,050h,06Ch,06Ch
                DB  06Ch,06Ch,06Ch,06Ch,06Ch,06Ch,06Ch,06Ch,06Ch,06Ch
                DB  06Ch,06Ch,0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Ah
                DB  070h,070h,070h,070h,070h,070h,070h,070h,070h,070h
                DB  070h,070h,070h,070h,070h,070h,0C7h,0C7h,0C7h,0BEh
                DB  0B3h,0ABh,09Ah,08Dh,07Ch,07Ch,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h,068h,068h
                DB  0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,07Ch,07Ch
                DB  068h,068h,068h,068h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,0C7h,0C7h,0C7h,0BEh,0B3h,0ABh
                DB  09Ah,08Dh,084h,084h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h,0C7h,0C7h
                DB  0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,084h,084h,06Dh,06Dh
                DB  06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh
                DB  06Dh,06Dh,0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,081h,081h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,0C8h,0C8h,0C8h,0BDh
                DB  0B3h,0ABh,09Ah,08Dh,084h,084h,081h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h,081h,081h
;@ IGN2_HI type=u8 size=20x10 stride=24 formula=ign_advance rows.axis=S_HI_Scaler rows.formula=rpm_axis_byte rows.unit=rpm cols.axis=S_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=Ignition desc="20 x 10 map (24 bytes per row); rows: high-cam rpm (S_HI_Scaler), columns: load (S_MAP_Scaler)"
IGN2_HI:       DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,010h,000h,000h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,05Ah,05Ah,05Ah,05Ah,044h,030h
                DB  020h,010h,000h,000h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,078h,078h
                DB  078h,071h,065h,04Ch,031h,022h,015h,011h,004h,004h
                DB  004h,004h,004h,004h,004h,004h,004h,004h,004h,004h
                DB  004h,004h,095h,095h,095h,089h,07Ch,067h,04Ch,041h
                DB  033h,02Fh,012h,012h,012h,012h,012h,012h,012h,012h
                DB  012h,012h,012h,012h,012h,012h,0A2h,0A2h,0A2h,095h
                DB  089h,077h,061h,055h,049h,045h,02Ch,02Ch,02Ch,02Ch
                DB  02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch,02Ch
                DB  0B7h,0B7h,0B7h,0A9h,09Ah,08Bh,078h,064h,051h,04Dh
                DB  03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah
                DB  03Ah,03Ah,03Ah,03Ah,0C5h,0C5h,0C5h,0B8h,0ADh,0A5h
                DB  099h,07Ah,062h,05Eh,044h,044h,044h,044h,044h,044h
                DB  044h,044h,044h,044h,044h,044h,044h,044h,0C7h,0C7h
                DB  0C7h,0BAh,0B3h,0ABh,0A1h,08Dh,073h,073h,046h,046h
                DB  046h,046h,046h,046h,046h,046h,046h,046h,046h,046h
                DB  046h,046h,0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh
                DB  07Ch,07Ch,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,04Eh
                DB  04Eh,04Eh,04Eh,04Eh,04Eh,04Eh,0C7h,0C7h,0C7h,0BEh
                DB  0AFh,0ABh,09Ah,08Dh,07Ch,07Ch,055h,055h,055h,055h
                DB  055h,055h,055h,055h,055h,055h,055h,055h,055h,055h
                DB  0C8h,0C8h,0C8h,0C1h,0B2h,0AEh,09Ah,08Dh,080h,080h
                DB  059h,059h,059h,059h,059h,059h,059h,059h,059h,059h
                DB  059h,059h,059h,059h,0C8h,0C8h,0C8h,0C4h,0B5h,0B1h
                DB  09Ah,08Dh,084h,084h,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh
                DB  06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,06Bh,0C8h,0C8h
                DB  0C8h,0C3h,0B4h,0AFh,09Ah,08Dh,084h,084h,070h,070h
                DB  070h,070h,070h,070h,070h,070h,070h,070h,070h,070h
                DB  070h,070h,0C8h,0C8h,0C8h,0C0h,0B4h,0ADh,09Ah,08Dh
                DB  084h,084h,070h,070h,070h,070h,070h,070h,070h,070h
                DB  070h,070h,070h,070h,070h,070h,0C8h,0C8h,0C8h,0BBh
                DB  0B3h,0ABh,09Ah,08Dh,084h,084h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h,068h,068h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  068h,068h,068h,068h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,0C8h,0C8h,0C8h,0BBh,0B3h,0ABh
                DB  09Ah,08Dh,084h,084h,068h,068h,068h,068h,068h,068h
                DB  068h,068h,068h,068h,068h,068h,068h,068h,0C8h,0C8h
                DB  0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h,06Dh,06Dh
                DB  06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh
                DB  06Dh,06Dh,0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h,081h,081h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,0C8h,0C8h,0C8h,0BBh
                DB  0B3h,0ABh,09Ah,08Dh,084h,084h,081h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h,081h,081h
;@ VEhi type=u8 size=20x10 stride=24 formula=ve_percent rows.axis=VE_SCALER rows.formula=rpm_axis_byte_log rows.unit=rpm cols.axis=P_MAP_Scaler cols.formula=map_mbar cols.unit=mbar category=VE desc="20 x 10 map (24 bytes per row); rows: low-cam rpm (VE_SCALER), columns: load (P_MAP_Scaler)"
VEhi:       DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  093h,093h,093h,093h,093h,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  097h,097h,097h,097h,097h,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,09Ah
                DB  09Ah,09Ah,099h,099h,099h,099h,099h,099h
                DB  099h,099h,099h,099h,099h,099h,099h,099h
                DB  08Eh,08Eh,08Eh,08Eh,097h,097h,097h,09Ah
                DB  09Ah,09Ah,099h,099h,099h,099h,099h,099h
                DB  099h,099h,099h,099h,099h,099h,099h,099h
                DB  001h,001h,005h,048h,04Fh,04Eh,044h,041h
                DB  054h,055h,04Eh,045h,053h,055h,049h,054h
                DB  045h

; definitions for settings without a label of their own (at= gives the address)
;@ DisableCypCode type=u8 flag=1 on=216 off=232 category="ROM options" slot=romoptions.dtc9 desc="Code 9 (CYP) check off (an opcode in the code: D8h = off, E8h = on)." at=00400h
;@ DisableTpsCode type=u8 flag=1 on=255 off=0 category="ROM options" slot=romoptions.dtc7 desc="Code 7 (TPS) check off (a byte in the code)." at=0083Dh
;@ ErrorIATValue2 type=u8 formula=honda_temp_c category="ROM options" slot=romoptions.dtc10.value desc="Intake air temperature used while code 10 is off (second copy)." at=0253Dh
;@ ErrorECTValue2 type=u8 formula=honda_temp_c category="ROM options" slot=romoptions.dtc6.value desc="Coolant temperature used while code 6 is off (second copy)." at=02541h
;@ ErrorchkECT type=u8 flag=1 on=255 off=0 category="ROM options" slot=romoptions.dtc6 desc="Code 6 (ECT) check off; the ECU then uses the fixed ECT below." at=03670h
;@ ErrorECTValue type=u8 formula=honda_temp_c category="ROM options" slot=romoptions.dtc6.value desc="Coolant temperature used while code 6 is off." at=036C7h
;@ ErrorchkIAT type=u8 flag=1 on=255 off=0 category="ROM options" slot=romoptions.dtc10 desc="Code 10 (IAT) check off; the ECU then uses the fixed IAT below." at=0370Ch
;@ ErrorIATValue type=u8 formula=honda_temp_c category="ROM options" slot=romoptions.dtc10.value desc="Intake air temperature used while code 10 is off." at=03715h
;@ ErrorchkVSS type=u8 flag=1 on=255 off=0 category="ROM options" slot=romoptions.dtc17 desc="Code 17 (VSS) check off; the ECU then uses the fixed speed below." at=037C2h
;@ ErrorVSSValue type=u8 formula=speed_kmh_byte category="ROM options" slot=romoptions.dtc17.value desc="Road speed used while code 17 is off." at=037C6h
;@ DisableTcsCode type=u16 flag=1 on=52117 off=5853 category="ROM options" slot=romoptions.dtc36 desc="Code 36 (traction control) check off (a 3-byte patch: 95 CB 1D off, DD 16 1C on)." at=03868h
;@ DisableTcsCode_b3 type=u8 flag=1 on=29 off=28 category="ROM options" slot=romoptions.dtc36 desc="Third byte of the code 36 patch." at=0386Ah
;@ DisableAutoBCode type=u16 flag=1 on=52117 off=5853 category="ROM options" slot=romoptions.dtc31 desc="Code 31 (automatic transmission B) check off (95 CB 28 off, DD 16 14 on)." at=0388Bh
;@ DisableAutoBCode_b3 type=u8 flag=1 on=40 off=20 category="ROM options" slot=romoptions.dtc31 desc="Third byte of the code 31 patch." at=0388Dh
;@ LimitBySpeed_5F35 type=u16 count=5 colstride=3 formula=rpm_period_word cols.axis=LimitBySpeed cols.stride=3 cols.formula=speed_kmh_byte category="Rev limits" slot=revlimit.ceiling.speed desc="Rpm ceiling by road speed, falling km/h." at=05F35h
;@ FTSAntiLagRetard type=u8 formula=hts_quarter_deg category="Full throttle shift" slot=fts.retard at=05F55h
;@ FTSAntiLagFV type=u16 formula=hts_quarter category="Full throttle shift" slot=fts.enrich at=05F56h
;@ FTSAntiLag type=u8 flag=1 on=255 off=0 category="Full throttle shift" slot=fts.antilag at=05F58h
;@ EthanolComp_5F8B type=u16 count=6 colstride=3 formula=raw cols.axis=EthanolComp cols.stride=3 cols.formula=percent255 category="Flex fuel" slot=flexfuel.fuel desc="Fuel against ethanol content." at=05F8Bh
;@ EthanolAdvance_5FA5 type=u8 count=6 colstride=2 formula=hts_quarter_deg cols.axis=EthanolAdvance cols.stride=2 cols.formula=percent255 category="Flex fuel" slot=flexfuel.ign desc="Advance against ethanol content." at=05FA5h
;@ FTLRPMTable_gears type=u16 count=5 formula=rpm_period_word category="Full throttle shift" slot=fts.gear desc="FTS cut rpm, gears 1-5." at=06006h
;@ TipinRetardVssMin type=u8 formula=speed_kmh_byte category="TPS tip-in retard" slot=tpsretard.speed.min at=06023h
;@ TipinRetardVssMax type=u8 formula=speed_kmh_byte category="TPS tip-in retard" slot=tpsretard.speed.max at=06024h
;@ TipinRetardRpmMin type=u8 formula=rpm_axis_byte_log category="TPS tip-in retard" slot=tpsretard.rpm.min at=06025h
;@ TipinRetardRpmMax type=u8 formula=rpm_axis_byte_log category="TPS tip-in retard" slot=tpsretard.rpm.max at=06026h
;@ TipinRetardEct type=u8 formula=honda_temp_c category="TPS tip-in retard" slot=tpsretard.ect at=06027h
;@ AlphaN_map100 type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category="Maps indexing" slot=mapindex.alpha.map100 at=0602Dh
;@ AlphaN_tps0 type=u8 formula=hts_tps_pct category="Maps indexing" slot=mapindex.alpha.tps0 at=0602Eh
;@ AlphaN_map0 type=u8 formula="x * 1860 / 255 - 70" inverse="(x + 70) * 255 / 1860" unit=mBar decimals=0 category="Maps indexing" slot=mapindex.alpha.map0 at=0602Fh
;@ WasteGateLookup_607A type=u8 count=11 colstride=2 formula=hts_duty_half cols.axis=WasteGateLookup cols.stride=2 cols.formula="((x * 1860 / 255 - 70) - 1013) * 0.0145038" cols.inverse="((x / 0.0145038 + 1013) + 70) * 255 / 1860" cols.unit=psi cols.decimals=1 category="Electronic boost control" slot=ebc.lookup at=0607Ah
;@ wastegateGEAR_6090 type=u8 count=11 colstride=2 formula="((x * 1860 / 255 - 70) - 1013) * 0.0145038" inverse="((x / 0.0145038 + 1013) + 70) * 255 / 1860" unit=psi decimals=1 cols.axis=wastegateGEAR cols.stride=2 cols.formula=raw category="Electronic boost control" slot=ebc.gear at=06090h
;@ wastegateRPM_60A6 type=u8 count=11 colstride=2 formula=hts_half_step cols.axis=wastegateRPM cols.stride=2 cols.formula=rpm_axis_byte category="Electronic boost control" slot=ebc.rpm at=060A6h
;@ wastegateIAT_60BC type=u8 count=5 colstride=2 formula=hts_half_step cols.axis=wastegateIAT cols.stride=2 cols.formula=honda_temp_c category="Electronic boost control" slot=ebc.iat at=060BCh
;@ GIOAdjustment1_60C6 type=u8 count=11 colstride=2 formula=ign_trim cols.axis=GIOAdjustment1 cols.stride=2 cols.formula=rpm_axis_byte category="General purpose output 1" slot=gpo1.retard desc="Timing while GPO 1 is on, against rpm." at=060C6h
;@ GIOAdjustment2_60DC type=u16 count=11 colstride=3 formula=hts_trim_word cols.axis=GIOAdjustment2 cols.stride=3 cols.formula=rpm_axis_byte category="General purpose output 1" slot=gpo1.fuel desc="Fuel while GPO 1 is on, against rpm." at=060DCh
;@ GearCorrectFuel_cells type=u8 count=5 formula=hts_trim_128 category="Gear corrections" slot=gearcorr.fuel desc="Fuel trim, gears 1-5." at=06129h
;@ GearCorrectIgn_cells type=u8 count=5 formula=ign_trim category="Gear corrections" slot=gearcorr.ign desc="Timing trim, gears 1-5." at=0612Fh
;@ MILShiftLightIndex type=u16 count=5 formula=rpm_period_word category="MIL shift light" slot=shiftlight.gear desc="Shift rpm, gears 1-5." at=06146h
;@ WGGearLow_cells type=u8 count=5 formula="((x * 1860 / 255 - 70) - 1013) * 0.0145038" inverse="((x / 0.0145038 + 1013) + 70) * 255 / 1860" unit=psi decimals=1 category="Electronic boost control" slot=ebc.gearlow at=06180h
;@ WGGearHi_cells type=u8 count=5 formula="((x * 1860 / 255 - 70) - 1013) * 0.0145038" inverse="((x / 0.0145038 + 1013) + 70) * 255 / 1860" unit=psi decimals=1 category="Electronic boost control" slot=ebc.gearhigh at=06186h
;@ LCDelay_strain type=u8 flag=1 on=255 off=0 category="Full throttle shift" slot=fts.strain desc="Strain cut delay (shares its byte with the launch cut delay)." at=061E4h
;@ TPSSettings_min type=u8 formula=volts_5v_byte category="TPS sensor" slot=tpssensor.min desc="TPS volts at 0%." at=06205h
;@ GearPresetIndex type=u8 category=Transmission slot=transmission.preset at=06213h
;@ InjectorTable_hothigh type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0 category=Injectors slot=injector.hothigh at=06217h
;@ InjectorTable_coldlow type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0 category=Injectors slot=injector.coldlow at=06219h
;@ InjectorTable_coldhigh type=u8 formula=570-x*15 inverse=(570-x)/15 unit=cc decimals=0 category=Injectors slot=injector.coldhigh at=0621Ah
;@ ECTFuelCorrect_622F type=u8 count=9 colstride=2 formula=hts_trim_128 cols.axis=ECTFuelCorrect cols.stride=2 cols.formula=honda_temp_c category="ECT corrections" slot=ectcorr.fuel at=0622Fh
;@ IATFuelCorrect_62A3 type=u16 size=3x9 stride=27 colstride=3 formula=hts_trim_word rows.name=block rows.values=1,2,3 cols.axis=IATFuelCorrect cols.stride=3 cols.formula=honda_temp_c category="IAT corrections" slot=iatcorr.fuel desc="Fuel against intake air temperature, three blocks." at=062A3h
;@ PostFuel_630C type=u16 count=9 colstride=3 formula=x/1024 inverse=x*1024 cols.axis=PostFuel cols.stride=3 cols.formula=honda_temp_c category="ECT corrections" slot=ectcorr.poststart at=0630Ch
;@ VEFuelCorrect_63B3 type=u8 count=6 colstride=2 formula=hts_trim_128 cols.axis=VEFuelCorrect cols.stride=2 cols.formula=honda_temp_c category="Closed loop" slot=closeloop.ve.table desc="Fuel against coolant temperature once the VE overheat correction is in." at=063B3h
;@ CloseLoopTPS_63BF type=u8 count=6 colstride=2 formula=hts_tps_pct cols.axis=CloseLoopTPS cols.stride=2 cols.formula=rpm_axis_byte_log category="Closed loop" slot=closeloop.tps.close desc="Closed loop below this throttle, against rpm." at=063BFh
;@ OpenLoopTPS_63CB type=u8 count=6 colstride=2 formula=hts_tps_pct cols.axis=OpenLoopTPS cols.stride=2 cols.formula=rpm_axis_byte_log category="Closed loop" slot=closeloop.tps.open desc="Open loop above this throttle, against rpm." at=063CBh
;@ InjectorIndex_6443 type=u16 count=7 colstride=3 formula=x*3.2/1000 inverse=x*1000/3.2 unit=ms cols.axis=InjectorIndex cols.stride=3 cols.formula=hts_batt_v category=Injectors slot=injector.lag desc="Injector lag against battery voltage." at=06443h
;@ Tipintempoffsetnormal_645B type=u16 count=6 colstride=3 formula=raw cols.axis=Tipintempoffsetnormal cols.stride=3 cols.formula=honda_temp_c category="TPS tip in / out" slot=tipinout.normal desc="Tip-in fuel against coolant temperature." at=0645Bh
;@ Tipintempoffsetinitial_646D type=u16 count=6 colstride=3 formula=raw cols.axis=Tipintempoffsetinitial cols.stride=3 cols.formula=honda_temp_c category="TPS tip in / out" slot=tipinout.initial desc="Tip-in fuel against coolant temperature, first minutes after start." at=0646Dh
;@ CrankFuel_6519 type=u16 count=9 colstride=3 formula=hts_quarter cols.axis=CrankFuel cols.stride=3 cols.formula=honda_temp_c category="Cranking fuel" slot=crankfuel.ect desc="Cranking fuel against coolant temperature (the word / 4, as HTS shows it)." at=06519h
;@ CrankFuelComp_6534 type=u8 count=2 colstride=2 formula=hts_signed_trim cols.axis=CrankFuelComp cols.stride=2 cols.formula=rpm_axis_byte category="Cranking fuel" slot=crankfuel.rpm desc="Cranking fuel compensation against rpm." at=06534h
;@ CrankFuelMap_6538 type=u8 count=2 colstride=2 formula=hts_signed_trim cols.axis=CrankFuelMap cols.stride=2 cols.formula="x * 1860 / 255 - 70" cols.inverse="(x + 70) * 255 / 1860" cols.unit=mBar cols.decimals=0 category="Cranking fuel" slot=crankfuel.map desc="Cranking fuel compensation against manifold pressure." at=06538h
;@ Overrun_Resume_int_653C type=u8 count=7 colstride=2 formula=hts_x16 cols.axis=Overrun_Resume_int cols.stride=2 cols.formula=honda_temp_c category="Fuel cut" slot=fuelcut.resume.initial desc="Fuel-cut resume against coolant temperature, first cut after start." at=0653Ch
;@ Overrun_Resume_nor_654A type=u8 count=7 colstride=2 formula=hts_x16 cols.axis=Overrun_Resume_nor cols.stride=2 cols.formula=honda_temp_c category="Fuel cut" slot=fuelcut.resume.normal desc="Fuel-cut resume against coolant temperature." at=0654Ah
;@ RevLimitLowReset type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.low.reset at=06591h
;@ RevLimitLowSet type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.low.set at=06597h
;@ RevLimitHighReset type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.high.reset at=0659Dh
;@ RevLimitHighSet type=u16 formula=rpm_period_word category="Rev limits" slot=revlimit.high.set at=065A3h
;@ VtecSettings_rpmhigh type=u8 formula=rpm_axis_byte_log category=VTEC slot=vtec.rpm.high at=06658h
;@ VtecSettings_tpslow type=u8 formula=hts_tps_pct category=VTEC slot=vtec.tps.low at=06659h
;@ VtecSettings_rpmlow type=u8 formula=rpm_axis_byte_log category=VTEC slot=vtec.rpm.low at=0665Ah
;@ IdleVsECT_6739 type=u16 size=2x7 stride=21 colstride=3 formula=rpm_period_word rows.name=set rows.values=1,2 cols.axis=IdleVsECT cols.stride=3 cols.formula=honda_temp_c category=Idle slot=idle.target desc="Idle target against coolant temperature (two sets)." at=06739h
;@ DwellBaseValues_6A57 type=u8 count=8 colstride=2 formula=x/16-1 inverse=(x+1)*16 cols.axis=DwellBaseValues cols.stride=2 cols.formula=rpm_axis_byte category="Dwell control" slot=dwell.base at=06A57h
;@ DwellBattery_6A67 type=u8 count=10 colstride=2 formula=hts_trim_64 cols.axis=DwellBattery cols.stride=2 cols.formula=hts_dwell_batt_v category="Dwell control" slot=dwell.batt at=06A67h
;@ DwellBaseRPM_6A7B type=u8 count=7 colstride=2 formula=hts_quarter cols.axis=DwellBaseRPM cols.stride=2 cols.formula=rpm_axis_byte category="Dwell control" slot=dwell.rpm at=06A7Bh
;@ ECTIgnCorrect_6A97 type=u8 count=10 colstride=2 formula=ign_trim cols.axis=ECTIgnCorrect cols.stride=2 cols.formula=honda_temp_c category="ECT corrections" slot=ectcorr.ign at=06A97h
;@ IATCorrect_6AB7 type=u8 count=9 colstride=2 formula=ign_trim cols.axis=IATCorrect cols.stride=2 cols.formula=honda_temp_c category="IAT corrections" slot=iatcorr.ign at=06AB7h
;@ TipinTPS_6B5D type=u8 count=7 colstride=2 formula=hts_tps_pct cols.axis=TipinTPS cols.stride=2 cols.formula=rpm_axis_byte_log category="TPS tip-in retard" slot=tpsretard.mintps at=06B5Dh
;@ TipinRPM_6B6B type=u8 count=7 colstride=2 formula=-x/4 inverse=-x*4 unit=deg cols.axis=TipinRPM cols.stride=2 cols.formula=rpm_axis_byte_log category="TPS tip-in retard" slot=tpsretard.base at=06B6Bh
;@ TipinEnrich_duration type=u8 count=5 formula=hts_x10_ms category="TPS tip-in retard" slot=tpsretard.duration desc="Tip-in retard duration per gear." at=06B78h
;@ TipinRetard_6B7E type=u8 count=6 colstride=2 formula=x/128 inverse=x*128 unit=x cols.axis=TipinRetard cols.stride=2 cols.formula=hts_tps_pct category="TPS tip-in retard" slot=tpsretard.tpsmul at=06B7Eh