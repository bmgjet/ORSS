;==================================================================================================
; p30-skeleton.asm - a minimal P30 (Honda OBD1, OKI MSM66207, P28-style board) that still runs the
; engine, as the base for building a ROM out of feature modules. See roms/p30-skeleton.md.
;
; Built from roms/p30.asm one subsystem at a time; after every step the simulator compared it with
; stock P30 at 14 operating points (cranking, cold/warm idle, cruise, part load, WOT low and VTEC,
; rev limit, decel, hot WOT, key-on prime, stall, tip-in).
;
; Kept: boot and self-tests, ROM checksum, crank/TDC/CYP sync, sensors, fuel (maps, cranking,
;   warm-up, IAT/baro/battery corrections, tip-in, decel cut), ignition, rev limiter, VTEC (with its
;   oil-pressure check), idle air control (IACV), fuel pump, and the stock calibration at 6000h-7649h.
; Removed: serial datalog/diagnostic link, trouble-code detection, storage and flashing, check-engine
;   lamp, closed-loop O2 (fuel is always open loop), EGR, automatic transmission control and lock-up.
; Added: module hooks at 5F00h, module requests (fuel cut, ignition retard), a 2.048 ms tick, and a
;   checksum byte at 7FFFh. Free for modules: skel_free_start-5EFFh and 764Ah-7FFEh.
;
; Not bench-tested on a car. Treat it like any new ROM: emulator and wideband first.
;==================================================================================================
                org 0000h
int_start_vec:            DW  int_start        ; 0000 E221
int_break_vec:            DW  int_break        ; 0002 E921
int_WDT_vec:              DW  int_WDT          ; 0004 D121
int_NMI_vec:              DW  int_NMI          ; 0006 3C00
int_INT0_vec:             DW  int_INT0         ; 0008 D301
int_serial_rx_vec:        DW  int_spurious_irq_trap    ; 000A (skeleton: no serial)
int_serial_tx_vec:        DW  int_spurious_irq_trap    ; 000C CB21
int_crank_sync_vec:       DW  int_crank_sync   ; 000E (IRQ bit 3: crank/cylinder sync - named int_serial_rx_BRG in the p30.asm annotations, it has nothing to do with serial)
int_timer_0_overflow_vec: DW  int_spurious_irq_trap    ; 0010 CB21
int_timer_0_vec:          DW  int_timer_0      ; 0012 8600
int_timer_1_overflow_vec: DW  int_spurious_irq_trap    ; 0014 CB21
int_timer_1_vec:          DW  int_timer_1      ; 0016 1401
int_timer_2_overflow_vec: DW  int_timer_2_overflow; 0018 DD02
int_timer_2_vec:          DW  int_timer_2      ; 001A 4D01
int_timer_3_overflow_vec: DW  int_spurious_irq_trap    ; 001C CB21
int_timer_3_vec:          DW  int_timer_3      ; 001E FB02
int_a2d_finished_vec:     DW  int_spurious_irq_trap    ; 0020 CB21
int_PWM_timer_vec:        DW  int_PWM_timer    ; 0022 1E03
int_serial_tx_BRG_vec:    DW  int_spurious_irq_trap    ; 0024 CB21
int_INT1_vec:             DW  int_INT1         ; 0026 7B03
vcal_0_vec:               DW  vcal_0           ; 0028 624E
vcal_1_vec:               DW  vcal_1           ; 002A C04E
vcal_2_vec:               DW  vcal_2           ; 002C 9C4E
vcal_3_vec:               DW  vcal_3           ; 002E AE4E
vcal_4_vec:               DW  background_task_scheduler ; 0030 (skeleton: straight to the scheduler, the serial command handler is gone)
vcal_5_vec:               DW  vcal_5           ; 0032 7F4F
vcal_6_vec:               DW  vcal_6           ; 0034 844F
vcal_7_vec:               DW  vcal_7           ; 0036 CE4F
code_start:     DB  000h,07Fh,031h,000h ; 0038
int_NMI:        CLR     PSW                    ; 003C 0 ??? ??? B50415
                MOV     LRB, #00041h           ; 003F 0 208 ??? 574100 ; [H] local register base = #00041h (base address 0x0208)
                RB      off(00230h).7          ; 0042 0 208 ??? C4300F ; [H] test-and-reset edge-detect bit 00230h.7
                JEQ     nmi_snapshot_dp_skip             ; 0045 0 208 ??? C904 ; [H] skip snapshot if bit was already 0
                L       A, DP                  ; 0047 1 208 ??? 42 ; [H] bit just transitioned 1->0: snapshot DP
                ST      A, 00084h[X1]          ; 0048 1 208 ??? D08400 ; [H] ...into 00084h[X1]
nmi_snapshot_dp_skip:     MOV     DP, #00009h            ; 004B 1 208 ??? 620900
nmi_poll_p4_1:     MB      C, P4.1                ; 004E 1 208 ??? C52C29 ; [H] sample pin P4.1 into carry
                JGE     nmi_enter_lowpower_seq             ; 0051 1 208 ??? CD2E ; [H] JGE branches on Carry=0 (arch.ml) -> as soon as P4.1 reads 0, jump ahead immediately
                JRNZ    DP, nmi_poll_p4_1         ; 0053 1 208 ??? 30F9 ; [H] else (P4.1 still 1) keep polling until DP counts out, then fall through anyway
                J       nmi_poll_p4_1_load_p2             ; 0055 1 208 ??? 036B57
nmi_poll_p4_1_store_adsel:     STB     A, ADSEL               ; 0058 0 208 ??? D559 ; [H] clear A/D channel select
                MOV     IE, #00040h            ; 005A 0 208 ??? B51A984000 ; [H] mask interrupt-enable to one source
                MOVB    TCON1, #0e0h           ; 005F 0 208 ??? C54198E0
                CLR     IRQ                    ; 0063 0 208 ??? B51815 ; [H] clear pending IRQ flags
                SB      P4SF.1                 ; 0066 0 208 ??? C52E19
                MOV     TM1, #0ffffh           ; 0069 0 208 ??? B53498FFFF ; [H] reload timer1 to max (effectively stop it counting down soon)
                SB      TCON1.4                ; 006E 0 208 ??? C5411C
                SB      SBYCON.2               ; 0071 0 208 ??? C5101A ; [H] standby-control bit set (see routine note above)
                LB      A, #005h               ; 0074 0 208 ??? 7705
; [H] STPACP = "Stop Code Acceptor" per the MSM66207 datasheet -- not a clock prescaler. Writing
; [H] N then N<<1 (5, then 10) is the write-unlock sequence this register requires before STOP/HALT
; [H] mode will actually be entered; it's a safety interlock against accidental entry, not a divider.
                STB     A, STPACP              ; 0076 0 208 ??? D513 ; [H] stop-code-acceptor unlock write, step 1: N=5
                SLLB    A                      ; 0078 0 208 ??? 53 ; [H] ...step 2: N<<1=10
                STB     A, STPACP              ; 0079 0 208 ??? D513 ; [H] unlock write, step 2
                SB      SBYCON.0               ; 007B 0 208 ??? C51018 ; [H] standby-control bit 0 set (likely the actual STOP-mode trigger)
                RB      09fh.1                 ; 007E 0 208 ??? C59F09
nmi_enter_lowpower_seq:     J       nmi_enter_lowpower_seq_load_ram0eb             ; 0081 1 208 ??? 03825A
int_timer_0:    MOV     LRB, #00037h           ; 0086 0 1B8 ??? 573700
; [H] --- Timer0 ISR: bit-shifts a value (r6, 16 bits across er0/er1/er2 chain) out one bit per
; [H] timer period, reloading TMR0 for the next bit's timing, tracking bit count in r7 (0-15,
; [H] matching a 16-bit shift register), accumulating into off(00197h) and driving P2 with the
; [H] result. Reads as a software bit-banged serial or pulse-train output; no calibration anchors
; [H] to identify the specific protocol/signal.
                ANDB    TCON0, #0fbh           ; 0089 0 1B8 ??? C540D0FB
                CMPB    r7, #00fh              ; 008D 0 1B8 ??? 27C00F
                JEQ     timer0_return             ; 0090 0 1B8 ??? C93F
                L       A, er0                 ; 0092 1 1B8 ??? 34
                JNE     timer0_bit_accumulate             ; 0093 1 1B8 ??? CE3D
                L       A, er1                 ; 0095 1 1B8 ??? 35
                JEQ     timer0_final_bit_check             ; 0096 1 1B8 ??? C953
                ADD     TMR0, A                ; 0098 1 1B8 ??? B53281
                LB      A, r6                  ; 009B 0 1B8 ??? 7E
                MB      C, ACC.7               ; 009C 0 1B8 ??? C5062F
                ROLB    r6                     ; 009F 0 1B8 ??? 26B7
                ORB     A, r6                  ; 00A1 0 1B8 ??? 6E
                ANDB    A, #00fh               ; 00A2 0 1B8 ??? D60F
                ORB     r7, A                  ; 00A4 0 1B8 ??? 27E1
                ORB     off(001b7h), A         ; 00A6 0 1B8 ??? C4B7E1
                LB      A, r6                  ; 00A9 0 1B8 ??? 7E
                SLLB    A                      ; 00AA 0 1B8 ??? 53
                ROLB    r6                     ; 00AB 0 1B8 ??? 26B7
                MOV     er0, er2               ; 00AD 0 1B8 ??? 4648
                L       A, #00001h             ; 00AF 1 1B8 ??? 670100
                ST      A, er1                 ; 00B2 1 1B8 ??? 89
timer0_bitshift_loop:     ST      A, er2                 ; 00B3 1 1B8 ??? 8A
                L       A, er0                 ; 00B4 1 1B8 ??? 34
                JNE     timer0_bit_shift_right             ; 00B5 1 1B8 ??? CE10
                L       A, er1                 ; 00B7 1 1B8 ??? 35
                JEQ     timer0_bit_invert             ; 00B8 1 1B8 ??? C910
                LB      A, r6                  ; 00BA 0 1B8 ??? 7E
                SRLB    A                      ; 00BB 0 1B8 ??? 63
                SRLB    A                      ; 00BC 0 1B8 ??? 63
                SRLB    A                      ; 00BD 0 1B8 ??? 63
                ORB     A, r6                  ; 00BE 0 1B8 ??? 6E
timer0_bit_output:     ORB     A, off(001b7h)         ; 00BF 0 1B8 ??? E7B7
                ANDB    A, #00fh               ; 00C1 0 1B8 ??? D60F
                ORB     P2, A                  ; 00C3 0 1B8 ??? C524E1
                RTI                            ; 00C6 0 1B8 ??? 02
timer0_bit_shift_right:     LB      A, r6                  ; 00C7 0 1B8 ??? 7E
                SJ      timer0_bit_output             ; 00C8 0 1B8 ??? CBF5
timer0_bit_invert:     LB      A, r6                  ; 00CA 0 1B8 ??? 7E
                RORB    A                      ; 00CB 0 1B8 ??? 43
                XORB    A, #0ffh               ; 00CC 0 1B8 ??? F6FF
                J       timer0_bit_output             ; 00CE 0 1B8 ??? 03BF00
timer0_return:     RTI                            ; 00D1 0 1B8 ??? 02
timer0_bit_accumulate:     ADD     TMR0, A                ; 00D2 1 1B8 ??? B53281
                LB      A, r6                  ; 00D5 0 1B8 ??? 7E
                ANDB    A, #00fh               ; 00D6 0 1B8 ??? D60F
                ORB     r7, A                  ; 00D8 0 1B8 ??? 27E1
                ORB     off(001b7h), A         ; 00DA 0 1B8 ??? C4B7E1
                LB      A, r6                  ; 00DD 0 1B8 ??? 7E
                SLLB    A                      ; 00DE 0 1B8 ??? 53
                ROLB    r6                     ; 00DF 0 1B8 ??? 26B7
                MOV     er0, er1               ; 00E1 0 1B8 ??? 4548
                MOV     er1, er2               ; 00E3 0 1B8 ??? 4649
                L       A, #00001h             ; 00E5 1 1B8 ??? 670100
                J       timer0_bitshift_loop             ; 00E8 1 1B8 ??? 03B300
timer0_final_bit_check:     L       A, er2                 ; 00EB 1 1B8 ??? 36
                JEQ     timer0_sequence_done             ; 00EC 1 1B8 ??? C91F
                ADD     TMR0, A                ; 00EE 1 1B8 ??? B53281
                LB      A, r6                  ; 00F1 0 1B8 ??? 7E
                MB      C, ACC.0               ; 00F2 0 1B8 ??? C50628
                RORB    A                      ; 00F5 0 1B8 ??? 43
                STB     A, r6                  ; 00F6 0 1B8 ??? 8E
                XORB    A, #0ffh               ; 00F7 0 1B8 ??? F6FF
                ANDB    A, #00fh               ; 00F9 0 1B8 ??? D60F
                ORB     r7, A                  ; 00FB 0 1B8 ??? 27E1
                ORB     off(001b7h), A         ; 00FD 0 1B8 ??? C4B7E1
                LB      A, r6                  ; 0100 0 1B8 ??? 7E
                ANDB    A, #00fh               ; 0101 0 1B8 ??? D60F
timer0_sequence_reset:     ORB     P2, A                  ; 0103 0 1B8 ??? C524E1
                L       A, #00001h             ; 0106 1 1B8 ??? 670100
                ST      A, er0                 ; 0109 1 1B8 ??? 88
                ST      A, er1                 ; 010A 1 1B8 ??? 89
                ST      A, er2                 ; 010B 1 1B8 ??? 8A
                RTI                            ; 010C 1 1B8 ??? 02
timer0_sequence_done:     LB      A, #00fh               ; 010D 0 1B8 ??? 770F
                STB     A, r7                  ; 010F 0 1B8 ??? 8F
                STB     A, off(001b7h)         ; 0110 0 1B8 ??? D4B7
                SJ      timer0_sequence_reset             ; 0112 0 1B8 ??? CBEF
int_timer_1:    MOV     LRB, #00019h           ; 0114 0 0C8 ??? 571900
                JBR     off(TCON1).3, timer1_tmr1_reload ; 0117 0 0C8 ??? DB4124
                RB      off(0009eh).5          ; 011A 0 0C8 ??? C49E0D
                JNE     timer1_check_start             ; 011D 0 0C8 ??? CE13
                CMP     er1, #0064ah           ; 011F 0 0C8 ??? 45C04A06
                JLT     timer1_check_start             ; 0123 0 0C8 ??? CA0D
                ORB     off(0009eh), #020h     ; 0125 0 0C8 ??? C49EE020
                L       A, #003b6h             ; 0129 1 0C8 ??? 67B603
                SUB     er1, A                 ; 012C 1 0C8 ??? 45A1
                ADD     off(TMR1), A           ; 012E 1 0C8 ??? B43681
                RTI                            ; 0131 1 0C8 ??? 02
timer1_check_start:     ANDB    off(TCON1), #0f7h      ; 0132 0 0C8 ??? C441D0F7
                L       A, off(ADCR4)          ; 0136 1 0C8 ??? E468
                ST      A, er2                 ; 0138 1 0C8 ??? 8A
                ADD     off(TMR1), off(000cah) ; 0139 1 0C8 ??? B43683CA
                RTI                            ; 013D 1 0C8 ??? 02
timer1_tmr1_reload:     ORB     off(TCON1), #008h      ; 013E 0 0C8 ??? C441E008
                INCB    0feh                   ; (skeleton) module tick: word at 0FEh counts IACV PWM periods, 2.048 ms each
                JNE     timer1_tick_done
                INCB    0ffh
timer1_tick_done:
                INCB    r6                     ; 0142 0 0C8 ??? AE
                L       A, #00a00h             ; 0143 1 0C8 ??? 67000A
                SUB     A, er0                 ; 0146 1 0C8 ??? 28
                ST      A, er1                 ; 0147 1 0C8 ??? 89
                ADD     off(TMR1), off(000c8h) ; 0148 1 0C8 ??? B43683C8
                RTI                            ; 014C 1 0C8 ??? 02
int_timer_2:    MOV     LRB, #0001ah           ; 014D 0 0D0 ??? 571A00
                LB      A, r2                  ; 0150 0 0D0 ??? 7A
                CMPB    A, #003h               ; 0151 0 0D0 ??? C603
                JGE     timer2_state1_check             ; 0153 0 0D0 ??? CD22
                ADDB    A, #001h               ; 0155 0 0D0 ??? 8601
                JBS     off(ACC).0, timer2_state_dispatch ; 0157 0 0D0 ??? E80604
                MOV     off(000a2h), off(ADCR6) ; 015A 0 0D0 ??? B46C7CA2
timer2_state_dispatch:     CMPB    A, r0                  ; 015E 0 0D0 ??? 48
                JEQ     timer3_reload_add             ; 015F 0 0D0 ??? C946
                JLT     timer3_reload_dec             ; 0161 0 0D0 ??? CA04
timer2_tcon3_clear:     ANDB    off(TCON3), #0fbh      ; 0163 0 0D0 ??? C443D0FB
timer3_reload_dec:     L       A, off(TM3)            ; 0167 1 0D0 ??? E43C
                SUB     A, #00001h             ; 0169 1 0D0 ??? A60100
                ST      A, off(TMR3)           ; 016C 1 0D0 ??? D43E
timer2_irq_clear:     ANDB    off(IRQH), #0f7h       ; 016E 1 0D0 ??? C419D0F7
                J       timer2_irq_clear_orb_off_irq             ; 0172 1 0D0 ??? 037476
timer2_state1_check:     JEQ     timer2_state2_check             ; 0177 0 0D0 ??? C90E
                JBR     off(ACC).0, timer2_tcon3_check2 ; 0179 0 0D0 ??? D80637
                JBS     off(000d0h).3, timer2_tcon3_clear ; 017C 0 0D0 ??? EBD0E4
                CLRB    A                      ; 017F 0 0D0 ??? FA
                ORB     off(TCON3), #004h      ; 0180 0 0D0 ??? C443E004
                J       timer2_state_dispatch             ; 0184 0 0D0 ??? 035E01
timer2_state2_check:     LB      A, r0                  ; 0187 0 0D0 ??? 78
                ADDB    A, #001h               ; 0188 0 0D0 ??? 8601
                CMPB    A, #005h               ; 018A 0 0D0 ??? C605
                JGE     timer2_er3_calc             ; 018C 0 0D0 ??? CD15
                ANDB    off(TCON3), #0fbh      ; 018E 0 0D0 ??? C443D0FB
                L       A, er2                 ; 0192 1 0D0 ??? 36
                CMP     A, #0001fh             ; 0193 1 0D0 ??? C61F00
                JGE     timer2_tmr2_add             ; 0196 1 0D0 ??? CD03
                L       A, #0001fh             ; 0198 1 0D0 ??? 671F00
timer2_tmr2_add:     ADD     A, off(TMR2)           ; 019B 1 0D0 ??? 873A
                J       timer3_reload_store             ; 019D 1 0D0 ??? 03CA01
timer2_tcon3_check:     JBS     off(TCON3).3, timer3_reload_dec ; 01A0 0 0D0 ??? EB43C4
timer2_er3_calc:     L       A, off(TMR2)           ; 01A3 1 0D0 ??? E43A
                ADD     A, er2                 ; 01A5 1 0D0 ??? 0A
                ST      A, er3                 ; 01A6 1 0D0 ??? 8B
timer3_reload_add:     L       A, off(TMR2)           ; 01A7 1 0D0 ??? E43A
                ADD     A, off(000e0h)         ; 01A9 1 0D0 ??? 87E0
                ST      A, off(TMR3)           ; 01AB 1 0D0 ??? D43E
                ANDB    off(TCON3), #0f7h      ; 01AD 1 0D0 ??? C443D0F7
                SJ      timer2_irq_clear             ; 01B1 1 0D0 ??? CBBB
timer2_tcon3_check2:     JBS     off(TCON3).2, timer2_tcon3_check ; 01B3 0 0D0 ??? EA43EA
                L       A, off(TM3)            ; 01B6 1 0D0 ??? E43C
                SUB     A, off(TMR2)           ; 01B8 1 0D0 ??? A73A
                ADD     A, #00006h             ; 01BA 1 0D0 ??? 860600
                CMP     A, er2                 ; 01BD 1 0D0 ??? 4A
                JGE     timer3_reload_alt             ; 01BE 1 0D0 ??? CD05
                L       A, off(TMR2)           ; 01C0 1 0D0 ??? E43A
                ADD     A, er2                 ; 01C2 1 0D0 ??? 0A
                SJ      timer3_reload_store             ; 01C3 1 0D0 ??? CB05
timer3_reload_alt:     L       A, off(TM3)            ; 01C5 1 0D0 ??? E43C
                ADD     A, #00004h             ; 01C7 1 0D0 ??? 860400
timer3_reload_store:     ST      A, off(TMR3)           ; 01CA 1 0D0 ??? D43E
                ORB     off(TCON3), #008h      ; 01CC 1 0D0 ??? C443E008
                J       timer2_irq_clear             ; 01D0 1 0D0 ??? 036E01
int_INT0:       L       A, 0f4h                ; 01D3 1 ??? ??? E5F4
                ST      A, IE                  ; 01D5 1 ??? ??? D51A
                L       A, TM2                 ; 01D7 1 ??? ??? E538
                ORB     PSWH, #001h            ; 01D9 1 ??? ??? A2E001
                MOV     LRB, #0001bh           ; 01DC 1 0D8 ??? 571B00
                JBS     off(ACCH).7, int_int0_edge_check ; 01DF 1 0D8 ??? EF0708
                JBR     off(IRQH).0, int_int0_edge_check ; 01E2 1 0D8 ??? D81905
                INCB    r3                     ; 01E5 1 0D8 ??? AB
                ORB     off(0009eh), #002h     ; 01E6 1 0D8 ??? C49EE002
int_int0_edge_check:     XCHG    A, er0                 ; 01EA 1 0D8 ??? 4410
                ST      A, er2                 ; 01EC 1 0D8 ??? 8A
                CLRB    A                      ; 01ED 0 0D8 ??? FA
                XCHGB   A, r3                  ; 01EE 0 0D8 ??? 2310
                STB     A, r2                  ; 01F0 0 0D8 ??? 8A
                ORB     off(0009eh), #004h     ; 01F1 0 0D8 ??? C49EE004
                L       A, off(000f2h)         ; 01F5 1 0D8 ??? E4F2
                ANDB    PSWH, #0feh            ; 01F7 1 0D8 ??? A2D0FE
                ST      A, off(IE)             ; 01FA 1 0D8 ??? D41A
                RTI                            ; 01FC 1 0D8 ??? 02
                DB  0E5h,0F4h,0D5h,01Ah,0B5h,004h,098h,002h ; 02B2
                DB  001h,067h,000h,001h,0F5h,055h,0C5h,056h ; 02BA
                DB  00Bh,0CEh,00Ch,0C5h,006h,02Fh,0C5h,007h ; 02C2
                DB  015h,0CAh,004h,0C5h,007h,098h,002h,052h ; 02CA
                DB  0F2h,0D5h,051h,0E5h,0F2h,0A2h,008h,0B5h ; 02D2
                DB  01Ah,08Ah,002h ; 02DA
int_timer_2_overflow: L       A, 0f4h                ; 02DD 1 ??? ??? E5F4
                ST      A, IE                  ; 02DF 1 ??? ??? D51A
                ORB     PSWH, #001h            ; 02E1 1 ??? ??? A2E001
                MOV     LRB, #0001bh           ; 02E4 1 0D8 ??? 571B00
                RB      off(0009eh).0          ; 02E7 1 0D8 ??? C49E08
                JNE     timer2ovf_edge_check2             ; 02EA 1 0D8 ??? CE01
                INCB    r6                     ; 02EC 1 0D8 ??? AE
timer2ovf_edge_check2:     RB      off(0009eh).1          ; 02ED 1 0D8 ??? C49E09
                JNE     timer2ovf_return             ; 02F0 1 0D8 ??? CE01
                INCB    r3                     ; 02F2 1 0D8 ??? AB
timer2ovf_return:     L       A, 0f2h                ; 02F3 1 0D8 ??? E5F2
                ANDB    PSWH, #0feh            ; 02F5 1 0D8 ??? A2D0FE
                ST      A, IE                  ; 02F8 1 0D8 ??? D51A
                RTI                            ; 02FA 1 0D8 ??? 02
int_timer_3:    L       A, 0f4h                ; 02FB 1 ??? ??? E5F4
                ST      A, IE                  ; 02FD 1 ??? ??? D51A
                ORB     PSWH, #001h            ; 02FF 1 ??? ??? A2E001
                MOV     LRB, #0001ah           ; 0302 1 0D0 ??? 571A00
                LB      A, r0                  ; 0305 0 0D0 ??? 78
                ADDB    A, #001h               ; 0306 0 0D0 ??? 8601
                CMPB    A, #005h               ; 0308 0 0D0 ??? C605
                JLT     timer3isr_return             ; 030A 0 0D0 ??? CA0A
                JBS     off(TCON3).2, timer3isr_return ; 030C 0 0D0 ??? EA4307
                MOV     off(TMR3), er3         ; 030F 0 0D0 ??? 477C3E
                ORB     off(TCON3), #008h      ; 0312 0 0D0 ??? C443E008
timer3isr_return:     L       A, off(000f2h)         ; 0316 1 0D0 ??? E4F2
                ANDB    PSWH, #0feh            ; 0318 1 0D0 ??? A2D0FE
                ST      A, IE                  ; 031B 1 0D0 ??? D51A
                RTI                            ; 031D 1 0D0 ??? 02
int_PWM_timer:  L       A, 0f4h                ; 031E 1 ??? ??? E5F4
                ST      A, IE                  ; 0320 1 ??? ??? D51A
                ORB     PSWH, #001h            ; 0322 1 ??? ??? A2E001
                MOV     LRB, #00070h           ; 0325 1 380 ??? 577000
                                                ; 0328 (skeleton: the PWM tick only paces the scheduler now - no EGR duty output, no A/T lock-up output on P4.3)
                LB      A, r0                  ; 032B 0 380 ??? 78
                ADDB    A, #001h               ; 032C 0 380 ??? 8601
                CMPB    A, #064h               ; 032E 0 380 ??? C664
                JLT     int_PWM_timer_store_r0             ; 0330 0 380 ??? CA04
                CLRB    A                      ; 0335 0 380 ??? FA
int_PWM_timer_store_r0:     STB     A, r0                  ; 0336 0 380 ??? 88
                CMPB    A, #000h               ; 033B 0 380 ??? C600
                JNE     int_PWM_timer_load_ram0f2             ; 033D 0 380 ??? CE04
                ORB     09eh, #008h            ; 033F 0 380 ??? C59EE008
int_PWM_timer_load_ram0f2:     L       A, 0f2h                ; 0343 1 380 ??? E5F2
                ANDB    PSWH, #0feh            ; 0345 1 380 ??? A2D0FE
                ST      A, IE                  ; 0348 1 380 ??? D51A
                RTI                            ; 034A 1 380 ??? 02
int_INT1:       L       A, #000a0h             ; 037B 1 ??? ??? 67A000
                ST      A, IE                  ; 037E 1 ??? ??? D51A
                MOV     PSW, #00102h           ; 0380 1 ??? ??? B504980201
                MOV     LRB, #00021h           ; 0385 1 108 ??? 572100
                MOV     USP, #00280h           ; 0388 1 108 280 A1988002
                CAL     refresh_engine_flags_snapshot             ; 038C 1 108 280 326252
                SB      off(00120h).4          ; 038F 1 108 280 C4201C
                RB      IRQH.1                 ; 0398 1 108 280 C51909
                JEQ     dtc04_ckp_latch             ; 039B 1 108 280 C90A
                RB      09ch.0                 ; 039D 1 108 280 C59C08
                MOVB    off(001a9h), #02dh     ; 03A0 1 108 280 C4A9982D
int1_dispatch_main_cycle:     J       crank_cycle_entry             ; 03A4 1 108 280 037A06
dtc04_ckp_latch:     RB      09ch.0                 ; 03A7 1 108 280 C59C18
int1_dispatch_alt1:     L       A, ADCR6               ; 03AA 1 108 280 E56C
                ST      A, 0a2h                ; 03AC 1 108 280 D5A2
                L       A, TM2                 ; 03AE 1 108 280 E538
                ST      A, TMR2                ; 03B0 1 108 280 D53A
                MOVB    0d2h, #000h            ; 03B2 1 108 280 C5D29800
                LB      A, #003h               ; 03B6 0 108 280 7703
                RB      TRNSIT.0               ; 03B8 0 108 280 C54608
                JNE     crank_tooth_count_store             ; 03BB 0 108 280 CE0A
                LB      A, off(0012ah)         ; 03BD 0 108 280 F42A
                ADDB    A, #006h               ; 03BF 0 108 280 8606
                CMPB    A, #018h               ; 03C1 0 108 280 C618
                JLT     crank_tooth_count_store             ; 03C3 0 108 280 CA02
                LB      A, #003h               ; 03C5 0 108 280 7703
crank_tooth_count_store:     STB     A, off(0012ah)         ; 03C7 0 108 280 D42A
                SB      P4.0                   ; 03C9 0 108 280 C52C18
                J       crank_tooth_count_store_load_carry_ram113_bit6             ; 03CC 0 108 280 03745F
crank_tooth_count_store_if_ram120_bit2_set:     JBS     off(00120h).2, int1_exit_jump ; 03CF 0 108 280 EA2007
                LB      A, off(00135h)         ; 03D2 0 108 280 F435
                JNE     int1_exit_jump             ; 03D4 0 108 280 CE03
                J       crank_tooth_count_store_set_ram120_bit2             ; 03D6 0 108 280 038F76
int1_exit_jump:     J       crank_cycle_dispatch2             ; 03D9 0 108 280 036905
int_crank_sync: L       A, #000a0h             ; 03DC 1 ??? ??? 67A000
                ST      A, IE                  ; 03DF 1 ??? ??? D51A
                MOV     PSW, #00102h           ; 03E1 1 ??? ??? B504980201
                MOV     LRB, #00021h           ; 03E6 1 108 ??? 572100
                MOV     USP, #00280h           ; 03E9 1 108 280 A1988002
; (skeleton: no fault-flag snapshot to copy)
; (skeleton: no fault-flag snapshot to copy)
; (skeleton: no fault-flag snapshot to copy)
; (skeleton: no fault-flag snapshot to copy)
                L       A, (00216h-00280h)[USP] ; 03F5 1 108 280 E396
                ST      A, off(00116h)         ; 03F7 1 108 280 D416
                MOVB    off(001a9h), #02dh     ; 03F9 1 108 280 C4A9982D
                JBR     off(00120h).3, crank_sync_flags_clear_path ; 03FD 1 108 280 DB204A
                J       int_crank_sync_if_ram112_bit7_set             ; 0400 1 108 280 031877
int_crank_sync_clear_irqh_bit7:     RB      IRQH.7                 ; 0403 1 108 280 C5190F
                JNE     crank_sync_lost_path             ; 0406 1 108 280 CE05
                RB      09eh.7                 ; 0408 1 108 280 C59E0F
                JEQ     crank_sync_retry_check             ; 040B 1 108 280 C920
crank_sync_lost_path:     SB      off(00120h).4          ; 040D 1 108 280 C4201C
                RB      off(00120h).6          ; 0410 1 108 280 C4200E
                MOVB    off(001aah), #02dh     ; 0413 1 108 280 C4AA982D
                L       A, 0d2h                ; 0417 1 108 280 E5D2
                CMP     A, #00005h             ; 0419 1 108 280 C60500
                JEQ     crank_tooth_counter_reset             ; 041C 1 108 280 C948
                SB      off(0011dh).6          ; 041E 1 108 280 C41D1E
                JLT     crank_sync_lost_path_set_ram120_bit5             ; 0421 1 108 280 CA3B
                CMP     A, #00105h             ; 0423 1 108 280 C60501
                JGE     crank_sync_flag_high             ; 0426 1 108 280 CD3B
                SB      09dh.0                 ; 0428 1 108 280 C59D18
                SJ      crank_tooth_counter_reset             ; 042B 1 108 280 CB39
crank_sync_retry_check:     CMPB    0d2h, #005h            ; 042D 1 108 280 C5D2C005
                JGE     crank_sync_confirm_check             ; 0431 1 108 280 CD06
                INCB    0d2h                   ; 0433 1 108 280 C5D216
                J       crank_tooth_counter_reset_goto_786c             ; 0436 1 108 280 036904
crank_sync_confirm_check:
dtc08_tdc_latch_2: RB      09ch.1                 ; 043C 1 108 280 C59C19
                SB      off(00120h).6          ; 043F 1 108 280 C4201E
crank_sync_confirmed:     INCB    0d3h                   ; 0442 1 108 280 C5D316
                CLRB    0d2h                   ; 0445 1 108 280 C5D215
                SJ      crank_tooth_counter_reset_goto_786c             ; 0448 1 108 280 CB1F
crank_sync_flags_clear_path:     RB      IRQH.7                 ; 044A 1 108 280 C5190F
                RB      09eh.7                 ; 044D 1 108 280 C59E0F
                RB      09fh.2                 ; 0450 1 108 280 C59F0A
                MB      C, 09fh.0              ; 0453 1 108 280 C59F28
                JGE     crank_sync_exit_jump             ; 0456 1 108 280 CD03
                SB      off(00120h).4          ; 0458 1 108 280 C4201C
crank_sync_exit_jump:     J       crank_decode_exit             ; 045B 1 108 280 033F06
crank_sync_lost_path_set_ram120_bit5:     SB      off(00120h).5          ; 045E 1 108 280 C4201D
                SJ      crank_tooth_counter_reset             ; 0461 1 108 280 CB03
crank_sync_flag_high:     SB      09dh.1                 ; 0463 1 108 280 C59D19
crank_tooth_counter_reset:     CLR     0d2h                   ; 0466 1 108 280 B5D215
crank_tooth_counter_reset_goto_786c:     J       crank_tooth_counter_reset_if_ram113_bit0_set             ; 0469 1 108 280 036C78
crank_tooth_counter_reset_clear_ram09f_bit2:     RB      09fh.2                 ; 046C 1 108 280 C59F0A
                JNE     crank_tooth_counter_reset_clear_ram120_bit7             ; 046F 1 108 280 CE2E
crank_tooth_seq_check:     CMPB    off(0012ah), #017h     ; 0471 1 108 280 C42AC017
                JGE     crank_tooth_seq_gate             ; 0475 1 108 280 CD06
                INCB    off(0012ah)            ; 0477 1 108 280 C42A16
                J       crank_tooth_mod_check             ; 047A 1 108 280 03C104
crank_tooth_seq_gate:
dtc09_cyp_latch: RB      09ch.2                 ; 0480 1 108 280 C59C1A
                SB      off(00120h).7          ; 0483 1 108 280 C4201F
crank_tooth_seq_advance:     INCB    off(0012bh)            ; 0486 1 108 280 C42B16
                CLRB    off(0012ah)            ; 0489 1 108 280 C42A15
                SJ      crank_tooth_mod_check             ; 048C 1 108 280 CB33
crank_window_flag_check2:     RB      off(00120h).5          ; 048E 1 108 280 C4200D
                JGE     crank_tooth_reset             ; 0491 1 108 280 CD2B
                JEQ     crank_window_flag_check2_set_ram09d_bit2             ; 0493 1 108 280 C926
                SB      09dh.0                 ; 0495 1 108 280 C59D18
                SJ      crank_tooth_reset             ; 0498 1 108 280 CB24
crank_sync_flag_low:     SB      09dh.1                 ; 049A 1 108 280 C59D19
                SJ      crank_tooth_reset             ; 049D 1 108 280 CB1F
crank_tooth_counter_reset_clear_ram120_bit7:     RB      off(00120h).7          ; 049F 1 108 280 C4200F
                MOVB    off(001abh), #007h     ; 04A2 1 108 280 C4AB9807
                L       A, off(0012ah)         ; 04A6 1 108 280 E42A
                CMP     A, #00017h             ; 04A8 1 108 280 C61700
                JNE     crank_window_flag_check2             ; 04AB 1 108 280 CEE1
                RB      off(00120h).5          ; 04AD 1 108 280 C4200D
                JNE     crank_sync_flag_low             ; 04B0 1 108 280 CEE8
                RB      off(0011dh).6          ; 04B2 1 108 280 C41D0E
                CMPB    0d2h, #003h            ; 04B5 1 108 280 C5D2C003
                JEQ     crank_tooth_reset             ; 04B9 1 108 280 C903
crank_window_flag_check2_set_ram09d_bit2:     SB      09dh.2                 ; 04BB 1 108 280 C59D1A
crank_tooth_reset:     CLR     off(0012ah)            ; 04BE 1 108 280 B42A15
crank_tooth_mod_check:
                JBS     off(00120h).6, crank_tooth_mod6_calc ; 04C4 1 108 280 EE200C
crank_tooth_range_check:
                JBS     off(00120h).7, crank_tooth_wrap_calc ; 04CA 1 108 280 EF2014
crank_tooth_carry_clear:     RC                             ; 04CD 1 108 280 95
                J       crank_sync_store_flag ; (skeleton: fault flags are always clear)
crank_tooth_mod6_calc:     CLR     A                      ; 04D3 1 108 280 F9
                MOVB    r0, #006h              ; 04D4 1 108 280 9806
                LB      A, off(0012ah)         ; 04D6 0 108 280 F42A
                ADDB    A, #003h               ; 04D8 0 108 280 8603
                DIVB                           ; 04DA 0 108 280 A236
                LB      A, r1                  ; 04DC 0 108 280 79
                STB     A, 0d2h                ; 04DD 0 108 280 D5D2
                SJ      crank_tooth_range_check             ; 04DF 0 108 280 CBE6
crank_tooth_wrap_calc:     MOVB    r0, #006h              ; 04E1 1 108 280 9806
                LB      A, 0d2h                ; 04E3 0 108 280 F5D2
                ADDB    A, #003h               ; 04E5 0 108 280 8603
                SUBB    A, r0                  ; 04E7 0 108 280 28
                JGE     crank_tooth_wrap_store             ; 04E8 0 108 280 CD01
                ADDB    A, r0                  ; 04EA 0 108 280 08
crank_tooth_wrap_store:     STB     A, r2                  ; 04EB 0 108 280 8A
                CLR     A                      ; 04EC 1 108 280 F9
                LB      A, off(0012ah)         ; 04ED 0 108 280 F42A
                DIVB                           ; 04EF 0 108 280 A236
                MULB                           ; 04F1 0 108 280 A234
                ADDB    A, r2                  ; 04F3 0 108 280 0A
                STB     A, off(0012ah)         ; 04F4 0 108 280 D42A
                JBR     off(00120h).6, crank_tooth_carry_clear ; 04F9 0 108 280 DE20D1
crank_sync_confirmed_flag:     SC                             ; 04FC 0 108 280 85
                SB      off(0011ch).2          ; 04FD 0 108 280 C41C1A
crank_sync_store_flag:     MB      off(00122h).1, C       ; 0500 0 108 280 C42239
                LB      A, off(0012ah)         ; 0503 0 108 280 F42A
                EXTND                          ; 0505 1 108 280 F8
                MOV     X1, A                  ; 0506 1 108 280 50
                LCB     A, tbl_crank_sync_pattern[X1]        ; 0507 1 108 280 90ABD26C
                ANDB    off(00120h), A         ; 050B 1 108 280 C420D1
                LB      A, off(0012ah)         ; 050E 0 108 280 F42A
                JNE     crank_sync_flag2_check             ; 0510 0 108 280 CE26
                JBR     off(00120h).2, crank_resync_reset ; 0512 0 108 280 DA2008
                JBS     off(00120h).0, crank_tooth_alt_flag ; 0515 0 108 280 E82017
                RB      off(00120h).1          ; 0518 0 108 280 C42009
                SJ      crank_tooth_alt_store             ; 051B 0 108 280 CB19
crank_resync_reset:     RB      PSWH.0                 ; 051D 0 108 280 A208
                MOVB    off(001b6h), #077h     ; 051F 0 108 280 C4B69877
                MOVB    off(001beh), #011h     ; 0523 0 108 280 C4BE9811
                ANDB    off(00120h), #0fch     ; 0527 0 108 280 C420D0FC
                SB      PSWH.0                 ; 052B 0 108 280 A218
                SJ      crank_tooth_alt_store             ; 052D 0 108 280 CB07
crank_tooth_alt_flag:     LB      A, #001h               ; 052F 0 108 280 7701
                JBR     off(00120h).1, crank_tooth_alt_store ; 0531 0 108 280 D92002
                LB      A, #002h               ; 0534 0 108 280 7702
crank_tooth_alt_store:     STB     A, off(00134h)         ; 0536 0 108 280 D434
crank_sync_flag2_check:     JBS     off(00120h).2, crank_sync_bit_check ; 0538 0 108 280 EA2011
                CMPB    off(00135h), #004h     ; 053B 0 108 280 C435C004
                JEQ     crank_cycle_exit_early             ; 053F 0 108 280 C925
                LB      A, off(00135h)         ; 0541 0 108 280 F435
                JNE     crank_sync_bit_check             ; 0543 0 108 280 CE07
                LB      A, 0d2h                ; 0545 0 108 280 F5D2
                JNE     crank_sync_bit_check             ; 0547 0 108 280 CE03
                SB      off(00120h).2          ; 0549 0 108 280 C4201A
crank_sync_bit_check:     LB      A, off(00134h)         ; 054C 0 108 280 F434
                ANDB    A, #001h               ; 054E 0 108 280 D601
                TRB     off(00120h)            ; 0550 0 108 280 C42013
                JNE     crank_cycle_exit_early             ; 0553 0 108 280 CE11
                CLR     A                      ; 0555 1 108 280 F9
                LB      A, off(0012ah)         ; 0556 0 108 280 F42A
                JBR     off(00134h).0, crank_tooth_pattern_lookup ; 0558 0 108 280 D83402
                ADDB    A, #006h               ; 055B 0 108 280 8606
crank_tooth_pattern_lookup:     MOV     X1, A                  ; 055D 0 108 280 50
                LCB     A, tbl_crank_tooth_pattern[X1]        ; 055E 0 108 280 90ABEA6C
                CMPB    A, off(00133h)         ; 0562 0 108 280 C733
                JGE     crank_cycle_dispatch2             ; 0564 0 108 280 CD03
crank_cycle_exit_early:     J       crank_decode_exit             ; 0566 0 108 280 033F06
crank_cycle_dispatch2:     LB      A, off(00134h)         ; 0569 0 108 280 F434
                SLLB    A                      ; 056B 0 108 280 53
                EXTND                          ; 056C 1 108 280 F8
                MOV     X1, A                  ; 056D 1 108 280 50
                CLR     A                      ; 0571 1 108 280 F9
                MOV     X2, A                  ; 0572 1 108 280 51
                ST      A, 003b6h[X2]          ; 0573 1 108 280 D1B603
                ST      A, 003b8h[X2]          ; 0576 1 108 280 D1B803
                ST      A, 003bah[X2]          ; 0579 1 108 280 D1BA03
                ST      A, 003bch[X2]          ; 057C 1 108 280 D1BC03
                CLRB    A                      ; 057F 0 108 280 FA
                STB     A, off(001cbh)         ; 0580 0 108 280 D4CB
                J       injtimer_bit_clear             ; 0582 0 108 280 03BA05
injtimer_bit_clear:     RB      off(001c9h).0          ; 05BA 1 108 280 C4C908
injbase_calc_start:     CLR     A                      ; 05BD 1 108 280 F9
                JBS     off(0011ch).4, injbase_store ; 05BE 1 108 280 EC1C0F
                JBS     off(00122h).1, injbase_store ; 05C1 1 108 280 E9220C
                L       A, 003aeh[X1]          ; 05C4 1 108 280 E0AE03
                ADD     A, 003b6h[X1]          ; 05C7 1 108 280 B0B60382
                JGE     injbase_store             ; 05CB 1 108 280 CD03
                L       A, #0ffffh             ; 05CD 1 108 280 67FFFF
injbase_store:     ST      A, off(001c6h)         ; 05D0 1 108 280 D4C6
                LB      A, off(00134h)         ; 05D2 0 108 280 F434
                RB      PSWH.0                 ; 05D4 0 108 280 A208
                TRB     off(001bfh)            ; 05D6 0 108 280 C4BF13
                JEQ     injbase_store_if_ram120_bit2_clr             ; 05D9 0 108 280 C917
                L       A, TMR0                ; 05DB 1 108 280 E532
                SUB     A, TM0                 ; 05DD 1 108 280 B530A2
                CMP     A, #00005h             ; 05E0 1 108 280 C60500
                JLT     injbase_store_set_pswh_bit0             ; 05E3 1 108 280 CA05
                CMP     A, #00021h             ; 05E5 1 108 280 C62100
                JLT     injbase_store_set_pswh_bit0_2             ; 05E8 1 108 280 CA29
injbase_store_set_pswh_bit0:     SB      PSWH.0                 ; 05EA 1 108 280 A218
                RB      off(00122h).3          ; 05EC 1 108 280 C4220B
                J       crank_tooth_flag_update             ; 05EF 1 108 280 031B06
injbase_store_if_ram120_bit2_clr:     JBR     off(00120h).2, tm0_sync_common ; 05F2 0 108 280 DA2014
                L       A, TM0                 ; 05F5 1 108 280 E530
                SUB     A, TMR0                ; 05F7 1 108 280 B532A2
                JEQ     tm0_sync_common             ; 05FA 1 108 280 C90D
                MB      C, IRQ.5               ; 05FC 1 108 280 C5182D
                JLT     tm0_sync_common             ; 05FF 1 108 280 CA08
                ADD     A, #00005h             ; 0601 1 108 280 860500
                JLT     tm0_sync_common             ; 0604 1 108 280 CA03
                ADD     TMR0, A                ; 0606 1 108 280 B53281
tm0_sync_common:     SB      PSWH.0                 ; 0609 1 108 280 A218
                CAL     tm0_resync_helper             ; 060B 1 108 280 32E54C
                SB      off(00122h).3          ; 060E 1 108 280 C4221B
                SJ      crank_tooth_flag_update             ; 0611 1 108 280 CB08
injbase_store_set_pswh_bit0_2:     SB      PSWH.0                 ; 0613 1 108 280 A218
                CAL     tm0_resync_helper             ; 0615 1 108 280 32E54C
                SB      off(00122h).3          ; 0618 1 108 280 C4221B
crank_tooth_flag_update:     CAL     crank_helper2             ; 061B 1 108 280 32324B
                LB      A, off(00134h)         ; 061E 0 108 280 F434
                STB     A, r0                  ; 0620 0 108 280 88
                ANDB    A, #001h               ; 0621 0 108 280 D601
                SBR     off(00120h)            ; 0623 0 108 280 C42011
                INCB    r0                     ; 0626 0 108 280 A8
                LB      A, r0                  ; 0627 0 108 280 78
                ANDB    A, #003h               ; 0628 0 108 280 D603
                STB     A, off(00134h)         ; 062A 0 108 280 D434
                JBS     off(00117h).3, crank_decode_exit ; 062C 0 108 280 EB1710
                RB      off(00122h).0          ; 0632 0 108 280 C42208
                JEQ     crank_decode_exit             ; 0635 0 108 280 C908
                RB      TRNSIT.2               ; 0637 0 108 280 C5460A
                JNE     crank_decode_exit             ; 063A 0 108 280 CE03
dtc16_injector_latch: RB      09ch.6                 ; 063C 0 108 280 C59C1E
crank_decode_exit:     RB      off(00122h).3          ; 063F 1 108 280 C4220B
                JNE     crank_decode_final_check             ; 0642 1 108 280 CE03
                CAL     tm0_resync_helper             ; 0644 1 108 280 32E54C
crank_decode_final_check:     LB      A, 0d2h                ; 0647 0 108 280 F5D2
                CMPB    A, #003h               ; 0649 0 108 280 C603
                JNE     crank_cycle_dispatch             ; 064B 0 108 280 CE38
crank_cycle_dispatch_body:     JBS     off(0011eh).0, crank_cycle_period_saturate ; 064D 0 108 280 E81E25
                JBS     off(00117h).1, crank_cycle_period_saturate ; 0650 0 108 280 E91722
                CMPB    A, #003h               ; 0653 0 108 280 C603
                CLR     er2                    ; 0655 0 108 280 4615
                JBS     off(00122h).5, crank_cycle_alt_dp ; 0657 0 108 280 ED2208
                MOV     DP, #00366h            ; 065A 0 108 280 626603
                JEQ     crank_cycle_dp_common             ; 065D 0 108 280 C90A
                CLR     A                      ; 065F 1 108 280 F9
                SJ      crank_cycle_er2_store             ; 0660 1 108 280 CB16
crank_cycle_alt_dp:     MOV     DP, #00362h            ; 0662 0 108 280 626203
                JNE     crank_cycle_dp_common             ; 0665 0 108 280 CE02
                MOV     er2, [DP]              ; 0667 0 108 280 B24A
crank_cycle_dp_common:     L       A, [DP]                ; 0669 1 108 280 E2
                CLR     er0                    ; 066A 1 108 280 4415
                MOVB    r1, 0cfh               ; 066C 1 108 280 C5CF49
                MUL                            ; 066F 1 108 280 9035
                L       A, er2                 ; 0671 1 108 280 36
                ADD     A, er1                 ; 0672 1 108 280 09
                JGE     crank_cycle_er2_store             ; 0673 1 108 280 CD03
crank_cycle_period_saturate:     L       A, #0ffffh             ; 0675 1 108 280 67FFFF
crank_cycle_er2_store:     ST      A, 0d4h                ; 0678 1 108 280 D5D4
crank_cycle_entry:     L       A, off(0011ch)         ; 067A 1 108 280 E41C
                ST      A, (0021ch-00280h)[USP] ; 067C 1 108 280 D39C
                RB      PSWH.0                 ; 067E 1 108 280 A208
int1_rti_epilogue:     L       A, 0f2h                ; 0680 1 108 280 E5F2
                ST      A, IE                  ; 0682 1 108 280 D51A
                RTI                            ; 0684 1 108 280 02
crank_cycle_dispatch:     JGE     crank_cycle_dispatch_alt             ; 0685 0 108 280 CD59
                CMPB    A, #001h               ; 0687 0 108 280 C601
                JGE     crank_cycle_dispatch_alt2             ; 0689 0 108 280 CD5E
                JBS     off(0011dh).6, crank_cycle_p4_gate ; 068E 0 108 280 EE1D11
                CMP     0ach, #000e2h          ; 0691 0 108 280 B5ACC0E200
                JLT     crank_cycle_p4_gate             ; 0696 0 108 280 CA0A
                RB      TRNSIT.1               ; 0698 0 108 280 C54609
                JNE     crank_cycle_p4_gate             ; 069B 0 108 280 CE05
dtc15_ign_output_latch: RB      09ch.3                 ; 069D 0 108 280 C59C1B
                SJ      crank_cycle_p4_gate_if_ram117_bit2_set             ; 06A0 0 108 280 CB07
crank_cycle_p4_gate:     RB      09ch.3                 ; 06A2 0 108 280 C59C0B
                MOVB    off(001ach), #006h     ; 06A5 0 108 280 C4AC9806
crank_cycle_p4_gate_if_ram117_bit2_set:     JBS     off(00117h).2, crank_cycle_dispatch_alt2_if_ram120_bit4_clr ; 06A9 0 108 280 EA173F
                J       crank_cycle_p4_gate_if_ram121_bit1_clr             ; 06AC 0 108 280 033077
crank_cycle_f4_check:     LB      A, #001h               ; 06AF 0 108 280 7701
                CMPB    0eah, #024h            ; 06B1 0 108 280 C5EAC024
                JNE     crank_cycle_counter_check             ; 06B5 0 108 280 CE03
                SB      off(00122h).4          ; 06B7 0 108 280 C4221C
crank_cycle_counter_check:     CMPB    off(001aah), #028h     ; 06BA 0 108 280 C4AAC028
                JLE     crank_cycle_result_b             ; 06BE 0 108 280 CF13
                JBS     off(00117h).4, crank_cycle_result_a ; 06C0 0 108 280 EC170C
                JBS     off(00122h).4, crank_cycle_result_common ; 06C3 0 108 280 EC2210
                CMPB    0c1h, #020h            ; 06C9 0 108 280 C5C1C020
                JLT     crank_cycle_result_common             ; 06CD 0 108 280 CA07
crank_cycle_result_a:     LB      A, #003h               ; 06CF 0 108 280 7703
                SJ      crank_cycle_result_common             ; 06D1 0 108 280 CB03
crank_cycle_result_b:     SB      off(00120h).4          ; 06D3 0 108 280 C4201C
crank_cycle_result_common:     SRLB    A                      ; 06D6 0 108 280 63
                MB      off(0011eh).0, C       ; 06D7 0 108 280 C41E38
                SRLB    A                      ; 06DA 0 108 280 63
                MB      P4.0, C                ; 06DB 0 108 280 C52C38
                SJ      crank_cycle_entry             ; 06DE 0 108 280 CB9A
crank_cycle_dispatch_alt:     CMPB    A, #004h               ; 06E0 0 108 280 C604
                JNE     crank_cycle_entry             ; 06E2 0 108 280 CE96
                J       crank_cycle_dispatch_body             ; 06E4 0 108 280 034D06
crank_cycle_bailout:     SJ      crank_cycle_entry             ; 06E7 0 108 280 CB91
crank_cycle_dispatch_alt2:     JEQ     crank_cycle_entry             ; 06E9 0 108 280 C98F
crank_cycle_dispatch_alt2_if_ram120_bit4_clr:     JBR     off(00120h).4, crank_cycle_bailout ; 06EB 0 108 280 DC20F9
                INCB    off(00136h)            ; 06EE 0 108 280 C43616
                JBS     off(00122h).2, crank_cycle_bailout ; 06F1 0 108 280 EA22F3
                LB      A, off(0011ch)         ; 06F4 0 108 280 F41C
                ANDB    A, #003h               ; 06F6 0 108 280 D603
                ANDB    off(00136h), A         ; 06F8 0 108 280 C436D1
                JNE     crank_cycle_bailout             ; 06FB 0 108 280 CEEA
                L       A, 0f2h                ; 06FD 1 108 280 E5F2
                RB      PSWH.0                 ; 06FF 1 108 280 A208
                SB      off(00122h).2          ; 0701 1 108 280 C4221A
                SB      PSWH.0                 ; 0704 1 108 280 A218
                ST      A, IE                  ; 0706 1 108 280 D51A
                CAL     crank_edge_helper             ; 0708 1 108 280 325952
                MOV     PSW, #01101h           ; 070B 1 108 280 B504980111
                MOV     LRB, #00040h           ; 0710 1 200 280 574000
                MOV     USP, #00180h           ; 0713 1 200 180 A1988001
                MOV     DP, #003d2h            ; 0717 1 200 180 62D203
                MOVB    r0, [DP]               ; 071A 1 200 180 C248
                LB      A, 0c5h                ; 071C 0 200 180 F5C5
                STB     A, [DP]                ; 071E 0 200 180 D2
                LB      A, ADCR2H              ; 071F 0 200 180 F565
                STB     A, 0c5h                ; 0721 0 200 180 D5C5
                SUBB    A, r0                  ; 0723 0 200 180 28
                MB      off(0022bh).5, C       ; 0724 0 200 180 C42B3D
                JGE     crank_cycle_adc_prep             ; 0727 0 200 180 CD01
                VCAL    7                      ; 0729 0 200 180 17
crank_cycle_adc_prep:     STB     A, 0c6h                ; 072A 0 200 180 D5C6
                LB      A, P2                  ; 072C 0 200 180 F524
                ANDB    A, #0e0h               ; 072E 0 200 180 D6E0
                STB     A, off(00255h)         ; 0730 0 200 180 D455
                L       A, 0f4h                ; 0732 1 200 180 E5F4
                ST      A, IE                  ; 0734 1 200 180 D51A
                RB      PSWH.0                 ; 0736 1 200 180 A208
                RB      ADSCAN.4               ; 0738 1 200 180 C5580C
                ANDB    P2, #01fh              ; 073B 1 200 180 C524D01F
                SB      ADSCAN.4               ; 073F 1 200 180 C5581C
                SB      PSWH.0                 ; 0742 1 200 180 A218
                L       A, 0f2h                ; 0744 1 200 180 E5F2
                ST      A, IE                  ; 0746 1 200 180 D51A
                MOV     DP, #00360h            ; 0748 1 200 180 626003
                CLR     A                      ; 074B 1 200 180 F9
                ST      A, er0                 ; 074C 1 200 180 88
                ST      A, er1                 ; 074D 1 200 180 89
crank_cycle_adc_prep_load_dp_ind:     L       A, [DP]                ; 074E 1 200 180 E2
                JEQ     rpm_period_invalid             ; 074F 1 200 180 C91F
                ADD     er1, A                 ; 0751 1 200 180 4581
                ADCB    r0, #000h              ; 0753 1 200 180 209000
                INC     DP                     ; 0756 1 200 180 72
                INC     DP                     ; 0757 1 200 180 72
                CMP     DP, #0036ch            ; 0758 1 200 180 92C06C03
                JLT     crank_cycle_adc_prep_load_dp_ind             ; 075C 1 200 180 CAF0
                RB      off(00217h).4          ; 075E 1 200 180 C4170C
                RB      off(00231h).5          ; 0761 1 200 180 C4310D
                L       A, er1                 ; 0764 1 200 180 35
                MOV     er2, #00005h           ; 0765 1 200 180 46980500
                DIV                            ; 0769 1 200 180 9037
                CMPB    r0, #000h              ; 076B 1 200 180 20C000
                JEQ     rpm_period_avg_store             ; 076E 1 200 180 C906
rpm_period_invalid:     SB      off(00231h).5          ; 0770 1 200 180 C4311D
                L       A, #0ffffh             ; 0773 1 200 180 67FFFF
rpm_period_avg_store:     ST      A, er0                 ; 0776 1 200 180 88
                MOV     DP, #0036ch            ; 0777 1 200 180 626C03
                XCHG    A, 0ach                ; 077A 1 200 180 B5AC10
                ST      A, er1                 ; 077D 1 200 180 89
                XCHG    A, [DP]                ; 077E 1 200 180 B210
                INC     DP                     ; 0780 1 200 180 72
                INC     DP                     ; 0781 1 200 180 72
                XCHG    A, [DP]                ; 0782 1 200 180 B210
                INC     DP                     ; 0784 1 200 180 72
                INC     DP                     ; 0785 1 200 180 72
                XCHG    A, [DP]                ; 0786 1 200 180 B210
                ST      A, er2                 ; 0788 1 200 180 8A
                L       A, er0                 ; 0789 1 200 180 34
                SUB     A, er2                 ; 078A 1 200 180 2A
                MB      off(0021bh).7, C       ; 078B 1 200 180 C41B3F
                JGE     rpm_accel_limit_check             ; 078E 1 200 180 CD01
                VCAL    7                      ; 0790 1 200 180 17
rpm_accel_limit_check:     ST      A, 0b0h                ; 0791 1 200 180 D5B0
                L       A, er0                 ; 0793 1 200 180 34
                SUB     A, er1                 ; 0794 1 200 180 29
                MB      off(0021bh).6, C       ; 0795 1 200 180 C41B3E
                JGE     rpm_decel_limit_check             ; 0798 1 200 180 CD01
                VCAL    7                      ; 079A 1 200 180 17
rpm_decel_limit_check:     ST      A, 0aeh                ; 079B 1 200 180 D5AE
                L       A, 0ach                ; 079D 1 200 180 E5AC
                CMP     A, #000eah             ; 079F 1 200 180 C6EA00
                JLT     rpm_period_normalize_lowrange             ; 07A2 1 200 180 CA3A
                CMP     A, #00ea6h             ; 07A4 1 200 180 C6A60E
                JGE     rpm_period_normalize_highrange             ; 07A7 1 200 180 CD42
                ST      A, er2                 ; 07A9 1 200 180 8A
                MOV     er3, #0ffc0h           ; 07AA 1 200 180 4798C0FF
                MOV     er0, #00007h           ; 07AE 1 200 180 44980700
                MOV     X1, #05300h            ; 07B2 1 200 180 600053
                MOV     DP, #rpm_decel_limit_check_tbl          ; 07B5 1 200 180 62086D
rpm_divide_normalize_loop:     LC      A, [DP]                ; 07B8 1 200 180 92A8
                CMP     er2, A                 ; 07BA 1 200 180 46C1
                JGE     rpm_divide_normalize_loop_load_x1             ; 07BC 1 200 180 CD0C
                SRL     er0                    ; 07BE 1 200 180 44E7
                ROR     X1                     ; 07C0 1 200 180 90C7
                ADD     er3, #00040h           ; 07C2 1 200 180 47804000
                INC     DP                     ; 07C6 1 200 180 72
                INC     DP                     ; 07C7 1 200 180 72
                SJ      rpm_divide_normalize_loop             ; 07C8 1 200 180 CBEE
rpm_divide_normalize_loop_load_x1:     L       A, X1                  ; 07CA 1 200 180 40
                DIV                            ; 07CB 1 200 180 9037
                SRL     A                      ; 07CD 1 200 180 63
                MB      PSWL.4, C              ; 07CE 1 200 180 A33C
                ADD     er3, A                 ; 07D0 1 200 180 4781
                LB      A, r7                  ; 07D2 0 200 180 7F
                JNE     rpm_clamp_0xfe             ; 07D3 0 200 180 CE10
                LB      A, r6                  ; 07D5 0 200 180 7E
                JEQ     rpm_normalize_flag_set             ; 07D6 0 200 180 C917
                CMPB    A, #0ffh               ; 07D8 0 200 180 C6FF
                JGE     rpm_clamp_0xfe             ; 07DA 0 200 180 CD09
                SJ      rpm_calc_finalize             ; 07DC 0 200 180 CB15
rpm_period_normalize_lowrange:     CMP     A, #000bbh             ; 07DE 1 200 180 C6BB00
                LB      A, #0ffh               ; 07E1 0 200 180 77FF
                JLT     rpm_period_normalize_done             ; 07E3 0 200 180 CA02
rpm_clamp_0xfe:     LB      A, #0feh               ; 07E5 0 200 180 77FE
rpm_period_normalize_done:     SB      PSWL.4                 ; 07E7 0 200 180 A31C
                SJ      rpm_calc_finalize             ; 07E9 0 200 180 CB08
rpm_period_normalize_highrange:     CLRB    A                      ; 07EB 0 200 180 FA
                JBS     off(00217h).4, rpm_normalize_flag_clear ; 07EC 0 200 180 EC1702
rpm_normalize_flag_set:     LB      A, #001h               ; 07EF 0 200 180 7701
rpm_normalize_flag_clear:     RB      PSWL.4                 ; 07F1 0 200 180 A30C
rpm_calc_finalize:     MB      C, PSWL.4              ; 07F3 0 200 180 A32C
                MB      0a0h.7, C              ; 07F5 0 200 180 C5A03F
                STB     A, (0012dh-00180h)[USP] ; 07F8 0 200 180 D3AD
                XCHGB   A, off(00236h)         ; 07FA 0 200 180 C43610
                STB     A, 0abh                ; 07FD 0 200 180 D5AB
                CLRB    r7                     ; 07FF 0 200 180 2715
                JBS     off(00217h).4, loadindex_flag_default ; 0801 0 200 180 EC1718
                DECB    r7                     ; 0804 0 200 180 BF
                MOV     er2, 0ach              ; 0805 0 200 180 B5AC4A
                MOV     er0, #0d000h           ; 0808 0 200 180 449800D0
                CLR     A                      ; 080C 1 200 180 F9
                DIV                            ; 080D 1 200 180 9037
                SLL     A                      ; 080F 1 200 180 53
                SB      PSWL.4                 ; 0810 1 200 180 A31C
                LB      A, r1                  ; 0812 0 200 180 79
                JNE     loadindex_flag_load             ; 0813 0 200 180 CE09
                MB      PSWL.4, C              ; 0815 0 200 180 A33C
                LB      A, r0                  ; 0817 0 200 180 78
                JNE     loadindex_store             ; 0818 0 200 180 CE05
                MOVB    r7, #001h              ; 081A 0 200 180 9F01
loadindex_flag_default:     RB      PSWL.4                 ; 081C 0 200 180 A30C
loadindex_flag_load:     LB      A, r7                  ; 081E 0 200 180 7F
loadindex_store:     STB     A, 0aah                ; 081F 0 200 180 D5AA
                MB      C, PSWL.4              ; 0821 0 200 180 A32C
                MB      0a0h.6, C              ; 0823 0 200 180 C5A03E
                L       A, 0a2h                ; 0829 1 200 180 E5A2
                SWAP                           ; 082B 1 200 180 83
                LB      A, ACC                 ; 082C 0 200 180 F506
                CMPB    A, #0a1h               ; 082E 0 200 180 C6A1
                JGT     dtc03_map_latch             ; 0830 0 200 180 C804
                CMPB    A, #00bh               ; 0832 0 200 180 C60B
                JGE     map_neg_helper_call             ; 0834 0 200 180 CD07
dtc03_map_latch:     RB      098h.0                 ; 0836 0 200 180 C59818
                LB      A, off(00235h)         ; 0839 0 200 180 F435
                SJ      map_sign_gate2             ; 083B 0 200 180 CB09
map_neg_helper_call:     CAL     subtract24_clamp_byte             ; 083D 0 200 180 32214F
map_sign_flag_clear:     RB      098h.0                 ; 0840 0 200 180 C59808
map_sign_gate2:     J       map_sign_gate4 ; (skeleton: fault flags are always clear)
map_sign_gate4:     STB     A, r0                  ; 084F 0 200 180 88
                LB      A, off(00235h)         ; 0850 0 200 180 F435
                SUBB    A, r0                  ; 0852 0 200 180 28
                MB      off(0021bh).4, C       ; 0853 0 200 180 C41B3C
                JGE     map_delta_store             ; 0856 0 200 180 CD01
                VCAL    7                      ; 0858 0 200 180 17
map_delta_store:     STB     A, 0a8h                ; 0859 0 200 180 D5A8
                MOV     DP, #00373h            ; 085B 0 200 180 627303
                LB      A, [DP]                ; 085E 0 200 180 F2
                SUBB    A, r0                  ; 085F 0 200 180 28
                MB      off(0021bh).5, C       ; 0860 0 200 180 C41B3D
                JGE     map_delta2_store             ; 0863 0 200 180 CD01
                VCAL    7                      ; 0865 0 200 180 17
map_delta2_store:     STB     A, 0a9h                ; 0866 0 200 180 D5A9
                LB      A, r0                  ; 0868 0 200 180 78
                STB     A, (0012ch-00180h)[USP] ; 0869 0 200 180 D3AC
                XCHGB   A, off(00235h)         ; 086B 0 200 180 C43510
                XCHGB   A, 0a5h                ; 086E 0 200 180 C5A510
                DEC     DP                     ; 0871 0 200 180 82
                XCHGB   A, [DP]                ; 0872 0 200 180 C210
                INC     DP                     ; 0874 0 200 180 72
                STB     A, [DP]                ; 0875 0 200 180 D2
                LB      A, #059h               ; 0876 0 200 180 7759
                LB      A, 0a4h                ; 087E 0 200 180 F5A4
                SUBB    A, off(00235h)         ; 0880 0 200 180 A735
                JGE     tps_custom_clamp_store             ; 0882 0 200 180 CD01
                CLRB    A                      ; 0884 0 200 180 FA
tps_custom_clamp_store:     STB     A, 0a6h                ; 0885 0 200 180 D5A6
                MOV     er0, #04d00h           ; 0887 0 200 180 4498004D
                RC                             ; 088B 0 200 180 95
                MOV     er0, ADCR7             ; 088F 0 200 180 B56E48
                LB      A, #0fch               ; 0892 0 200 180 77FC
                CMPB    A, r1                  ; 0894 0 200 180 49
                JLT     dtc07_tps_latch             ; 0895 0 200 180 CA03
                CMPB    r1, #005h              ; 0897 0 200 180 21C005
dtc07_tps_latch:     RB      098h.2                 ; 089A 0 200 180 C5983A
                JLT     tps_delta_alt_path             ; 089D 0 200 180 CA19
                L       A, er0                 ; 089F 1 200 180 34
                SLL     A                      ; 08A0 1 200 180 53
                JLT     tps_delta_clamp1             ; 08A1 1 200 180 CA05
                SLL     A                      ; 08A3 1 200 180 53
                LB      A, ACCH                ; 08A4 0 200 180 F507
                JGE     tps_delta_store1             ; 08A6 0 200 180 CD02
tps_delta_clamp1:     LB      A, #0ffh               ; 08A8 0 200 180 77FF
tps_delta_store1:     STB     A, 0bch                ; 08AA 0 200 180 D5BC
                L       A, er0                 ; 08AC 1 200 180 34
                XCHG    A, 0b8h                ; 08AD 1 200 180 B5B810
                MOV     er1, 0bah              ; 08B0 1 200 180 B5BA49
                ST      A, 0bah                ; 08B3 1 200 180 D5BA
                J       tps_delta_check1 ; (skeleton: fault flags are always clear)
tps_delta_alt_path:     L       A, er0                 ; 08B8 1 200 180 34
                MOV     er1, 0b8h              ; 08B9 1 200 180 B5B849
tps_delta_check1:     SUB     A, er0                 ; 08BC 1 200 180 28
                MB      PSWL.4, C              ; 08BD 1 200 180 A33C
                JGE     tps_delta_clamp2             ; 08BF 1 200 180 CD01
                VCAL    7                      ; 08C1 1 200 180 17
tps_delta_clamp2:     SLL     A                      ; 08C2 1 200 180 53
                JLT     tps_delta_clamp2_max             ; 08C3 1 200 180 CA05
                SLL     A                      ; 08C5 1 200 180 53
                LB      A, ACCH                ; 08C6 0 200 180 F507
                JGE     tps_delta_store2             ; 08C8 0 200 180 CD02
tps_delta_clamp2_max:     LB      A, #0ffh               ; 08CA 0 200 180 77FF
tps_delta_store2:     STB     A, r0                  ; 08CC 0 200 180 88
                MB      C, PSWL.4              ; 08CD 0 200 180 A32C
                RB      off(0021bh).1          ; 08CF 0 200 180 C41B09
                MB      off(0021bh).1, C       ; 08D2 0 200 180 C41B39
                XCHGB   A, 0bdh                ; 08D5 0 200 180 C5BD10
                JEQ     tps_delta_sign_check             ; 08D8 0 200 180 C903
                XORB    PSWH, #080h            ; 08DA 0 200 180 A2F080
tps_delta_sign_check:     JLT     tps_delta_flag_store             ; 08DD 0 200 180 CA01
                CMPB    A, r0                  ; 08DF 0 200 180 48
tps_delta_flag_store:     MB      off(0021bh).3, C       ; 08E0 0 200 180 C41B3B
                L       A, er1                 ; 08E3 1 200 180 35
                SUB     A, 0b8h                ; 08E4 1 200 180 B5B8A2
                MB      off(0021bh).2, C       ; 08E7 1 200 180 C41B3A
                JGE     tps_delta_clamp3             ; 08EA 1 200 180 CD01
                VCAL    7                      ; 08EC 1 200 180 17
tps_delta_clamp3:     SLL     A                      ; 08ED 1 200 180 53
                JLT     tps_delta_clamp3_max             ; 08EE 1 200 180 CA05
                SLL     A                      ; 08F0 1 200 180 53
                LB      A, ACCH                ; 08F1 0 200 180 F507
                JGE     tps_delta_store3             ; 08F3 0 200 180 CD02
tps_delta_clamp3_max:     LB      A, #0ffh               ; 08F5 0 200 180 77FF
tps_delta_store3:     STB     A, 0beh                ; 08F7 0 200 180 D5BE
                L       A, off(00292h)         ; 08F9 1 200 180 E492
                ST      A, er0                 ; 08FB 1 200 180 88
                LB      A, r1                  ; 08FC 0 200 180 79
                JBR     off(0021ah).2, tps_delta_compare_final ; 08FD 0 200 180 DA1A01
                LB      A, r0                  ; 0900 0 200 180 78
tps_delta_compare_final:     CMPB    A, off(00236h)         ; 0901 0 200 180 C736
                MB      off(0021ah).2, C       ; 0903 0 200 180 C41A3A
                MOV     DP, #00311h            ; 0906 0 200 180 621103
                MOVB    r4, [DP]               ; 0909 0 200 180 C24C
                LB      A, #003h               ; 090B 0 200 180 7703
                STB     A, r2                  ; 090D 0 200 180 8A
                MOVB    r3, #006h              ; 090E 0 200 180 9B06
                MB      C, off(00218h).2       ; 0910 0 200 180 C4182A
                MB      off(00218h).3, C       ; 0913 0 200 180 C4183B
                JLT     tps_window_calc2             ; 0916 0 200 180 CA01
                LB      A, r3                  ; 0918 0 200 180 7B
tps_window_calc2:     ADDB    A, r4                  ; 0919 0 200 180 0C
                CMPB    A, 0bch                ; 091A 0 200 180 C5BCC2
                MB      off(00218h).2, C       ; 091D 0 200 180 C4183A
                LB      A, #004h               ; 0920 0 200 180 7704
                JBS     off(00218h).4, tps_window_calc3 ; 0922 0 200 180 EC1802
                LB      A, #007h               ; 0925 0 200 180 7707
tps_window_calc3:     ADDB    A, r4                  ; 0927 0 200 180 0C
                CMPB    A, 0bch                ; 0928 0 200 180 C5BCC2
                MB      off(00218h).4, C       ; 092B 0 200 180 C4183C
                LB      A, r2                  ; 092E 0 200 180 7A
                MB      C, off(00218h).0       ; 092F 0 200 180 C41828
                MB      off(00218h).1, C       ; 0932 0 200 180 C41839
                JGE     tps_window_calc4             ; 0935 0 200 180 CD03
                MOVB    r0, r1                 ; 0937 0 200 180 2148
                LB      A, r3                  ; 0939 0 200 180 7B
tps_window_calc4:     ADDB    A, r4                  ; 093A 0 200 180 0C
                CMPB    0bch, A                ; 093B 0 200 180 C5BCC1
                JGE     tps_window_store2             ; 093E 0 200 180 CD03
                LB      A, off(00236h)         ; 0940 0 200 180 F436
                CMPB    A, r0                  ; 0942 0 200 180 48
tps_window_store2:     MB      off(00218h).0, C       ; 0943 0 200 180 C41838
                MOVB    r0, 0a8h               ; 0946 0 200 180 C5A848
                MOVB    r1, off(00235h)        ; 0949 0 200 180 C43549
                JBS     off(0021ch).0, tps_interp_exact_match ; 094C 0 200 180 E81C2D
                JBR     off(0021ah).2, tps_interp_exact_match ; 094F 0 200 180 DA1A2A
                JBS     off(00210h).7, tps_interp_exact_match ; 0952 0 200 180 EF1027
                MOVB    r4, #0ffh              ; 095B 0 200 180 9CFF
                LB      A, 0a5h                ; 095D 0 200 180 F5A5
                MOV     DP, #tbl_tps_custom_curve2          ; 095F 0 200 180 622660
                MOV     X1, #tbl_tps_custom_curve          ; 0962 0 200 180 602260
                CMPB    A, #0b0h               ; 0965 0 200 180 C6B0
                JGE     tps_table_offset_check             ; 0967 0 200 180 CD08
                INC     DP                     ; 0969 0 200 180 72
                INC     DP                     ; 096A 0 200 180 72
                CMPB    A, #040h               ; 096B 0 200 180 C640
                JGE     tps_table_offset_check             ; 096D 0 200 180 CD02
                INC     DP                     ; 096F 0 200 180 72
                INC     DP                     ; 0970 0 200 180 72
tps_table_offset_check:     JBS     off(0021bh).4, tps_table_lookup ; 0971 0 200 180 EC1B03
                INC     X1                     ; 0974 0 200 180 70
                INC     X1                     ; 0975 0 200 180 70
                INC     DP                     ; 0976 0 200 180 72
tps_table_lookup:     LC      A, [X1]                ; 0977 0 200 180 90A8
                CMPB    A, r0                  ; 0979 0 200 180 48
                JLT     tps_interp_clamp_check             ; 097A 0 200 180 CA03
tps_interp_exact_match:     LB      A, r1                  ; 097C 0 200 180 79
                SJ      tps_interp_store             ; 097D 0 200 180 CB2A
tps_interp_clamp_check:     LB      A, ACCH                ; 097F 0 200 180 F507
                CMPB    A, r0                  ; 0981 0 200 180 48
                JGE     tps_interp_weight_calc             ; 0982 0 200 180 CD01
                STB     A, r0                  ; 0984 0 200 180 88
tps_interp_weight_calc:     LCB     A, [DP]                ; 0985 0 200 180 92AA
                MULB                           ; 0987 0 200 180 A234
                L       A, ACC                 ; 0989 1 200 180 E506
                SRL     A                      ; 098B 1 200 180 63
                SRL     A                      ; 098C 1 200 180 63
                SRL     A                      ; 098D 1 200 180 63
                SRL     A                      ; 098E 1 200 180 63
                ST      A, er1                 ; 098F 1 200 180 89
                LB      A, r3                  ; 0990 0 200 180 7B
                JNE     tps_interp_zero_check             ; 0991 0 200 180 CE12
                LB      A, r1                  ; 0993 0 200 180 79
                JBR     off(0021bh).4, tps_interp_sub_check ; 0994 0 200 180 DC1B05
                ADDB    A, r2                  ; 0997 0 200 180 0A
                JLT     tps_interp_clamp_result             ; 0998 0 200 180 CA08
                SJ      tps_interp_range_check             ; 099A 0 200 180 CB03
tps_interp_sub_check:     SUBB    A, r2                  ; 099C 0 200 180 2A
                JLT     tps_interp_zero_check             ; 099D 0 200 180 CA06
tps_interp_range_check:     CMPB    A, r4                  ; 099F 0 200 180 4C
                JLE     tps_interp_store             ; 09A0 0 200 180 CF07
tps_interp_clamp_result:     LB      A, r4                  ; 09A2 0 200 180 7C
                SJ      tps_interp_store             ; 09A3 0 200 180 CB04
tps_interp_zero_check:     CLRB    A                      ; 09A5 0 200 180 FA
                JBS     off(0021bh).4, tps_interp_clamp_result ; 09A6 0 200 180 EC1BF9
tps_interp_store:     STB     A, 0a7h                ; 09A9 0 200 180 D5A7
                L       A, 0ach                ; 09AB 1 200 180 E5AC
                SUB     A, off(00258h)         ; 09AD 1 200 180 A758
                MB      off(0021ah).5, C       ; 09AF 1 200 180 C41A3D
                J       tps_interp_store_load_er0             ; 09B2 1 200 180 03AB5D
rpm_avg_range_check_store_ram0b2:     ST      A, 0b2h                ; 09B5 1 200 180 D5B2
                LB      A, #098h               ; 09B7 0 200 180 7798
                JBS     off(0022bh).0, threshold_bank_218_5 ; 09B9 0 200 180 E82B02
                LB      A, #0a0h               ; 09BC 0 200 180 77A0
threshold_bank_218_5:     CMPB    A, off(00236h)         ; 09BE 0 200 180 C736
                MB      off(0022bh).0, C       ; 09C0 0 200 180 C42B38
                LB      A, #0cdh               ; 09C3 0 200 180 77CD
                JBS     off(00218h).7, threshold_bank_218_5_cmp_acc ; 09C5 0 200 180 EF1802
                LB      A, #0d0h               ; 09C8 0 200 180 77D0
threshold_bank_218_5_cmp_acc:     CMPB    A, off(00236h)         ; 09CA 0 200 180 C736
                MB      off(00218h).7, C       ; 09CC 0 200 180 C4183F
                LB      A, #03ah               ; 09CF 0 200 180 773A
                JBS     off(00217h).0, threshold_bank_217_0 ; 09D1 0 200 180 E81702
                LB      A, #040h               ; 09D4 0 200 180 7740
threshold_bank_217_0:     CMPB    A, off(00236h)         ; 09D6 0 200 180 C736
                MB      off(00217h).0, C       ; 09D8 0 200 180 C41738
                MOV     X1, #Scaler_RpmAxis_Lo          ; 09DB 0 200 180 600A70
                MOVB    r3, (001d8h-00180h)[USP] ; 09DE 0 200 180 C3584B
                MOVB    r2, off(00236h)        ; 09E1 0 200 180 C4364A
                MOVB    r6, #012h              ; 09E4 0 200 180 9E12
                MB      C, 0a0h.7              ; 09E6 0 200 180 C5A02F
                MB      PSWL.4, C              ; 09E9 0 200 180 A33C
                CAL     newval_table3_call_sub_clear_acc             ; 09EB 0 200 180 32DE4F
                STB     A, (001dah-00180h)[USP] ; 09EE 0 200 180 D35A
                LB      A, r6                  ; 09F0 0 200 180 7E
                STB     A, (001d8h-00180h)[USP] ; 09F1 0 200 180 D358
                MOV     X1, #Scaler_RpmAxis_Hi          ; 09F3 0 200 180 601E70
                MOVB    r3, (001d9h-00180h)[USP] ; 09F6 0 200 180 C3594B
                MOVB    r2, 0aah               ; 09F9 0 200 180 C5AA4A
                MOVB    r6, #012h              ; 09FC 0 200 180 9E12
                J       threshold_bank_217_0_load_carry_ram0a0_bit6             ; 09FE 0 200 180 03A176
threshold_bank_217_0_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 0A01 0 200 180 A33C
                CAL     newval_table3_call_sub_clear_acc             ; 0A03 0 200 180 32DE4F
                STB     A, (001dch-00180h)[USP] ; 0A06 0 200 180 D35C
                LB      A, r6                  ; 0A08 0 200 180 7E
                STB     A, (001d9h-00180h)[USP] ; 0A09 0 200 180 D359
                LB      A, 0a4h                ; 0A0B 0 200 180 F5A4
                LB      A, 0a7h                ; 0A13 0 200 180 F5A7
newval_table3_call:     STB     A, r2                  ; 0A15 0 200 180 8A
                MOV     X1, #newval_table3_call_tbl_3          ; 0A16 0 200 180 600070
                MOVB    r3, (001d2h-00180h)[USP] ; 0A19 0 200 180 C3524B
                MOVB    r6, #008h              ; 0A1C 0 200 180 9E08
                RB      PSWL.4                 ; 0A1E 0 200 180 A30C
                CAL     newval_table3_call_sub_clear_acc             ; 0A20 0 200 180 32DE4F
                STB     A, (001d4h-00180h)[USP] ; 0A23 0 200 180 D354
                LB      A, r6                  ; 0A25 0 200 180 7E
                STB     A, (001d2h-00180h)[USP] ; 0A26 0 200 180 D352
                LB      A, 0a7h                ; 0A28 0 200 180 F5A7
                STB     A, r2                  ; 0A2A 0 200 180 8A
                MOV     X1, #newval_table3_call_tbl_3          ; 0A2B 0 200 180 600070
                MOVB    r3, (001d3h-00180h)[USP] ; 0A2E 0 200 180 C3534B
                MOVB    r6, #008h              ; 0A31 0 200 180 9E08
                RB      PSWL.4                 ; 0A33 0 200 180 A30C
                CAL     newval_table3_call_sub_clear_acc             ; 0A35 0 200 180 32DE4F
                STB     A, (001d6h-00180h)[USP] ; 0A38 0 200 180 D356
                LB      A, r6                  ; 0A3A 0 200 180 7E
                STB     A, (001d3h-00180h)[USP] ; 0A3B 0 200 180 D353
; (skeleton: no EGR, so never the EGR fuel/ignition maps - 219h.6 stays 0)
                CLR     er2                    ; 0A92 0 200 180 4615
                SC                             ; 0A94 0 200 180 85
                JBR     off(00227h).6, mode_flags_pack4 ; 0A95 0 200 180 DE276D
                LB      A, (001d2h-00180h)[USP] ; 0A98 0 200 180 F352
                ADDB    A, #001h               ; 0A9A 0 200 180 8601
                CMPB    0a7h, #000h            ; 0A9C 0 200 180 C5A7C000
                JNE     mode_flags_pack_start             ; 0AA0 0 200 180 CE01
                CLRB    A                      ; 0AA2 0 200 180 FA
; (skeleton: knock control unit removed: no condition word for it)
mode_flags_pack_start:
mode_flags_pack_alt:
mode_flags_pack_store:
mode_flags_pack2:
mode_flags_pack3:
scale_div32_loop:
mode_flags_pack4:
                MOV     DP, #003beh            ; 0B0B 1 200 180 62BE03
                LB      A, ADCR0H              ; 0B0E 0 200 180 F561
                STB     A, [DP]                ; 0B10 0 200 180 D2
                STB     A, 0c2h                ; 0B11 0 200 180 D5C2
                MOV     DP, #003c6h            ; 0B13 0 200 180 62C603
                LB      A, ADCR1H              ; 0B16 0 200 180 F563
                STB     A, [DP]                ; 0B18 0 200 180 D2
                L       A, 0f4h                ; 0B19 1 200 180 E5F4
                ST      A, IE                  ; 0B1B 1 200 180 D51A
                RB      PSWH.0                 ; 0B1D 1 200 180 A208
                RB      ADSCAN.4               ; 0B1F 1 200 180 C5580C
                ORB     P2, off(00255h)        ; 0B22 1 200 180 C524E355
                RB      IRQH.4                 ; 0B26 1 200 180 C5190C
                SB      ADSCAN.4               ; 0B29 1 200 180 C5581C
                MOV     off(00256h), TM2       ; 0B2C 1 200 180 B5387C56
                SB      PSWH.0                 ; 0B30 1 200 180 A218
                L       A, 0f2h                ; 0B32 1 200 180 E5F2
                ST      A, IE                  ; 0B34 1 200 180 D51A
                JBS     off(0021dh).4, ignmap_alt_path ; 0B36 1 200 180 EC1D45
                MOVB    r0, #00ah              ; 0B39 1 200 180 980A
                MOVB    r1, #014h              ; 0B3B 1 200 180 9914
                MOVB    r2, (001d2h-00180h)[USP] ; 0B3D 1 200 180 C3524A
                MOV     X2, (001d4h-00180h)[USP] ; 0B40 1 200 180 B35479
                MOVB    r3, (001d9h-00180h)[USP] ; 0B43 1 200 180 C3594B
                MOV     er3, (001dch-00180h)[USP] ; 0B46 1 200 180 B35C4B
                MOV     X1, #mode_flags_pack4_tbl          ; 0B49 1 200 180 601673
                J       flag_dispatch_21d_212             ; 0B4C 1 200 180 03B076
flag_dispatch_21d_212_load_r3:     MOVB    r3, (001d8h-00180h)[USP] ; 0B4F 1 200 180 C3584B
                MOV     er3, (001dah-00180h)[USP] ; 0B52 1 200 180 B35A4B
                MOV     X1, #flag_dispatch_21d_212_tbl          ; 0B55 1 200 180 604E72
                J       flag_dispatch_21d_212_if_ram213_bit3_set ; (skeleton: fault flags are always clear)
flag_dispatch_21d_212_if_ram213_bit3_set:
                J       ignmap_2d_lookup ; 0B61 (skeleton: no EGR maps)
ignmap_2d_lookup:     RB      PSWL.5                 ; 0B76 0 200 180 A30D
                CAL     table2d_lookup_interp             ; 0B78 0 200 180 321050
                LB      A, r4                  ; 0B7B 0 200 180 7C
                SJ      ignmap_result_common             ; 0B7C 0 200 180 CB0E
ignmap_alt_path:     LB      A, 0aah                ; 0B7E 0 200 180 F5AA
                MOV     X1, #ignmap_alt_path_tbl          ; 0B80 0 200 180 60E165
                JBS     off(0021fh).1, ignmap_alt_path_vcal_0 ; 0B83 0 200 180 E91F05
                LB      A, off(00236h)         ; 0B86 0 200 180 F436
                MOV     X1, #ignmap_alt_path_tbl_2          ; 0B88 0 200 180 600D66
ignmap_alt_path_vcal_0:     VCAL    0                      ; 0B8B 0 200 180 10
ignmap_result_common:     STB     A, off(00244h)         ; 0B8C 0 200 180 D444
                CLRB    A                      ; 0B8E 0 200 180 FA
                CMPB    0c1h, #02eh            ; 0B8F 0 200 180 C5C1C02E
                JGE     idleign_result_store             ; 0B93 0 200 180 CD1F
                JBR     off(00218h).0, idleign_result_store ; 0B95 0 200 180 D8181C
                JBS     off(00210h).7, idleign_result_store ; 0B98 0 200 180 EF1019
                L       A, 0b2h                ; 0B9B 1 200 180 E5B2
                MOV     X1, #IgnControl          ; 0B9D 1 200 180 60896A
                JBS     off(0021ah).5, idleign_table_lookup ; 0BA0 1 200 180 ED1A03
                MOV     X1, #HiIdleIgnControl          ; 0BA3 1 200 180 60796A
idleign_table_lookup:     CAL     table_interp_lookup_4byte             ; 0BA6 1 200 180 32FE4E
                MOVB    r0, #008h              ; 0BA9 1 200 180 9808
                LB      A, r6                  ; 0BAB 0 200 180 7E
                CMPB    A, r0                  ; 0BAC 0 200 180 48
                JLT     idleign_vcal6_check             ; 0BAD 0 200 180 CA01
                LB      A, r0                  ; 0BAF 0 200 180 78
idleign_vcal6_check:     JBR     off(0021ah).5, idleign_result_store ; 0BB0 0 200 180 DD1A01
                VCAL    7                      ; 0BB3 0 200 180 17
idleign_result_store:     STB     A, off(00240h)         ; 0BB4 0 200 180 D440
                LB      A, #012h               ; 0BB6 0 200 180 7712
                JBS     off(00221h).3, rpm_threshold_221_3 ; 0BB8 0 200 180 EB2102
                LB      A, #010h               ; 0BBB 0 200 180 7710
rpm_threshold_221_3:     CMPB    0adh, A                ; 0BBD 0 200 180 C5ADC1
                MB      off(00221h).3, C       ; 0BC0 0 200 180 C4213B
                LB      A, #000h               ; 0BC3 0 200 180 7700
                JBS     off(00221h).4, rpm_threshold_221_4 ; 0BC5 0 200 180 EC2102
                LB      A, #001h               ; 0BC8 0 200 180 7701
rpm_threshold_221_4:     CMPB    A, off(00236h)         ; 0BCA 0 200 180 C736
                MB      off(00221h).4, C       ; 0BCC 0 200 180 C4213C
                CLRB    A                      ; 0BCF 0 200 180 FA
                MOV     X1, #tbl_ignmap_idle2          ; 0BD0 0 200 180 60536A
                JBS     off(00221h).2, knockretard_table_gate ; 0BD3 0 200 180 EA2104
                INC     X1                     ; 0BD6 0 200 180 70
                MB      C, off(00221h).3       ; 0BD7 0 200 180 C4212B
knockretard_table_gate:     JGE     knockretard_store             ; 0BDA 0 200 180 CD0C
                L       A, off(00252h)         ; 0BDC 1 200 180 E452
                ST      A, er3                 ; 0BDE 1 200 180 8B
                LB      A, off(00235h)         ; 0BDF 0 200 180 F435
                CAL     table_interp_lookup_prescan             ; 0BE1 0 200 180 324E4E
                JBR     off(00221h).2, knockretard_store ; 0BE4 0 200 180 DA2101
                VCAL    7                      ; 0BE7 0 200 180 17
knockretard_store:     STB     A, off(0023fh)         ; 0BE8 0 200 180 D43F
                LB      A, #05ah               ; 0BEA 0 200 180 775A
                JBS     off(00220h).2, rpm_threshold_222_5 ; 0BEC 0 200 180 EA2002
                LB      A, #060h               ; 0BEF 0 200 180 7760
rpm_threshold_222_5:     CMPB    A, off(00236h)         ; 0BF1 0 200 180 C736
                MB      off(00220h).2, C       ; 0BF3 0 200 180 C4203A
                CLRB    A                      ; 0BF6 0 200 180 FA
                JBR     off(00227h).7, knockretard2_clamp_store_ram238 ; 0BF7 0 200 180 DF272B
                JGE     knockretard2_clamp_store_ram238             ; 0BFD 0 200 180 CD26
                CMPB    0c0h, #0b5h            ; 0BFF 0 200 180 C5C0C0B5
                JGE     knockretard2_clamp_store_ram238             ; 0C03 0 200 180 CD20
                JBS     off(0021dh).5, knockretard2_clamp_store_ram238 ; 0C05 0 200 180 ED1D1D
                JBS     off(0021ah).4, knockretard2_clamp_store_ram238 ; 0C08 0 200 180 EC1A1A
                JBR     off(0021ah).3, knockretard2_clamp_store_ram238 ; 0C0B 0 200 180 DB1A17
                CLR     A                      ; 0C0E 1 200 180 F9
                LB      A, off(00254h)         ; 0C0F 0 200 180 F454
                MOV     er3, A                 ; 0C11 0 200 180 478A
                LB      A, off(00235h)         ; 0C13 0 200 180 F435
                MOV     X1, #tbl_ignmap_idle1          ; 0C15 0 200 180 60346A
                CAL     table_interp_lookup_prescan             ; 0C18 0 200 180 324E4E
                LB      A, off(00238h)         ; 0C1B 0 200 180 F438
                ADDB    A, #001h               ; 0C1D 0 200 180 8601
                JLT     knockretard2_clamp             ; 0C1F 0 200 180 CA03
                CMPB    A, r6                  ; 0C21 0 200 180 4E
                JLT     knockretard2_clamp_store_ram238             ; 0C22 0 200 180 CA01
knockretard2_clamp:     LB      A, r6                  ; 0C24 0 200 180 7E
knockretard2_clamp_store_ram238:     STB     A, off(00238h)         ; 0C25 0 200 180 D438
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram2ad ; 0C27 0 200 180 DA1624
                LB      A, #07ah               ; 0C2A 0 200 180 777A
                JBS     off(00216h).3, overrev_hardcap_compare ; 0C2C 0 200 180 EB1602
                LB      A, #07ah               ; 0C2F 0 200 180 777A
overrev_hardcap_compare:     CMPB    A, off(00236h)         ; 0C31 0 200 180 C736
                JLT     overrev_hardcap_compare_load_ram2ad             ; 0C33 0 200 180 CA19
                LB      A, 0b4h                ; 0C35 0 200 180 F5B4
                CMPB    A, #02dh               ; 0C37 0 200 180 C62D
                JGE     overrev_hardcap_compare_load_ram2ad             ; 0C39 0 200 180 CD13
                CMPB    A, #023h               ; 0C3B 0 200 180 C623
                JLT     overrev_hardcap_compare_load_ram2ad             ; 0C3D 0 200 180 CA0F
                CMPB    0c1h, #028h            ; 0C3F 0 200 180 C5C1C028
                JGE     overrev_hardcap_compare_load_ram2ad             ; 0C43 0 200 180 CD09
                CMPB    off(00235h), #064h     ; 0C45 0 200 180 C435C064
                JGE     overrev_hardcap_compare_load_ram2ad             ; 0C49 0 200 180 CD03
                JBR     off(0021ah).4, overrev_hardcap_compare_cmp_ram2ad ; 0C4B 0 200 180 DC1A0B
overrev_hardcap_compare_load_ram2ad:     MOVB    off(002adh), #060h     ; 0C4E 0 200 180 C4AD9860
                CLRB    A                      ; 0C52 0 200 180 FA
                STB     A, r0                  ; 0C53 0 200 180 88
                RB      off(00220h).3          ; 0C54 0 200 180 C4200B
                SJ      overrev_hardcap_compare_store_ram251             ; 0C57 0 200 180 CB25
overrev_hardcap_compare_cmp_ram2ad:     CMPB    off(002adh), #00ch     ; 0C59 0 200 180 C4ADC00C
                JGE     overrev_hardcap_compare_goto_596d             ; 0C5D 0 200 180 CD29
                LB      A, off(002adh)         ; 0C5F 0 200 180 F4AD
                JEQ     overrev_hardcap_compare_cmp_acc             ; 0C61 0 200 180 C906
                MOVB    off(002ach), #060h     ; 0C63 0 200 180 C4AC9860
                SJ      overrev_hardcap_compare_load_r0             ; 0C67 0 200 180 CB05
overrev_hardcap_compare_cmp_acc:     CMPB    A, off(002ach)         ; 0C69 0 200 180 C7AC
                MB      off(00220h).3, C       ; 0C6B 0 200 180 C4203B
overrev_hardcap_compare_load_r0:     MOVB    r0, off(00239h)        ; 0C6E 0 200 180 C43948
                LB      A, off(00251h)         ; 0C71 0 200 180 F451
                JEQ     overrev_hardcap_compare_addb_r0             ; 0C73 0 200 180 C904
                SUBB    A, #001h               ; 0C75 0 200 180 A601
                SJ      overrev_hardcap_compare_store_ram251             ; 0C77 0 200 180 CB05
overrev_hardcap_compare_addb_r0:     ADDB    r0, #002h              ; 0C79 0 200 180 208002
                LB      A, #004h               ; 0C7C 0 200 180 7704
overrev_hardcap_compare_store_ram251:     STB     A, off(00251h)         ; 0C7E 0 200 180 D451
                LB      A, #015h               ; 0C80 0 200 180 7715
                CMPB    A, r0                  ; 0C82 0 200 180 48
                JLE     overrev_hardcap_compare_store_ram239             ; 0C83 0 200 180 CF01
                LB      A, r0                  ; 0C85 0 200 180 78
overrev_hardcap_compare_store_ram239:     STB     A, off(00239h)         ; 0C86 0 200 180 D439
overrev_hardcap_compare_goto_596d:     J       overrev_hardcap_compare_load_imm_2             ; 0C88 0 200 180 036D59
overrev_hardcap_compare_if_ne_goto_0c95:     JNE     overrev_hardcap_compare_goto_789a             ; 0C8D 0 200 180 CE06
                MOV     X1, #overrev_hardcap_compare_tbl_2          ; 0C8F 0 200 180 606E65
                J       overrev_hardcap_compare_load_carry_ram0a0_bit1             ; 0C92 0 200 180 031058
overrev_hardcap_compare_goto_789a:     J       overrev_hardcap_compare_cmp_stk             ; 0C95 0 200 180 039A78
overrev_hardcap_compare_load_imm:     LB      A, #01dh               ; 0C9B 0 200 180 771D
knockretard2_store:     STB     A, off(0023bh)         ; 0C9D 0 200 180 D43B
; (skeleton: knock control unit removed: no knock flags, no knock retard)
scale_shift_loop:
scale_direction_toggle:
scale_result_common:
flags_pack_233_7:
knock_244_table_select:
knock_244_lookup:
knock_244_store:
flags_pack_sj:     LB      A, #03ah               ; 0D08 0 200 180 773A
                MOVB    r0, #040h              ; 0D0A 0 200 180 9840
                CMPB    0a4h, #0dbh            ; 0D0C 0 200 180 C5A4C0DB
                JGE     flags_pack_sj_if_ram222_bit0_set             ; 0D10 0 200 180 CD04
                LB      A, #093h               ; 0D12 0 200 180 7793
                MOVB    r0, #097h              ; 0D14 0 200 180 9897
flags_pack_sj_if_ram222_bit0_set:     JBS     off(00222h).0, flags_pack_sj_cmp_acc ; 0D16 0 200 180 E82201
                LB      A, r0                  ; 0D19 0 200 180 78
flags_pack_sj_cmp_acc:     CMPB    A, off(00236h)         ; 0D1A 0 200 180 C736
                MB      off(00222h).0, C       ; 0D1C 0 200 180 C42238
                CLRB    A                      ; 0D1F 0 200 180 FA
                JBR     off(0021dh).5, flags_pack_sj_store_ram23e ; 0D20 0 200 180 DD1D0E
                JGE     flags_pack_sj_store_ram23e             ; 0D23 0 200 180 CD0C
                MOV     X1, #flags_pack_sj_tbl          ; 0D25 0 200 180 60C16A
                JBR     off(0021eh).3, flags_pack_sj_load_ram236 ; 0D28 0 200 180 DB1E03
                MOV     X1, #TipinTPS          ; 0D2B 0 200 180 60CD6A
flags_pack_sj_load_ram236:     LB      A, off(00236h)         ; 0D2E 0 200 180 F436
                VCAL    0                      ; 0D30 0 200 180 10
flags_pack_sj_store_ram23e:     STB     A, off(0023eh)         ; 0D31 0 200 180 D43E
                LB      A, #05ah               ; 0D33 0 200 180 775A
                JBS     off(00222h).1, flags_pack_sj_cmp_acc_2 ; 0D35 0 200 180 E92202
                LB      A, #060h               ; 0D38 0 200 180 7760
flags_pack_sj_cmp_acc_2:     CMPB    A, off(00236h)         ; 0D3A 0 200 180 C736
                MB      off(00222h).1, C       ; 0D3C 0 200 180 C42239
                LB      A, 0b9h                ; 0D3F 0 200 180 F5B9
                MOVB    r0, #09ah              ; 0D41 0 200 180 989A
                MOVB    r1, #024h              ; 0D43 0 200 180 9924
                JBS     off(00222h).2, flags_pack_sj_cmp_acc_3 ; 0D45 0 200 180 EA2204
                MOVB    r0, #097h              ; 0D48 0 200 180 9897
                MOVB    r1, #026h              ; 0D4A 0 200 180 9926
flags_pack_sj_cmp_acc_3:     CMPB    A, r0                  ; 0D4C 0 200 180 48
                JGE     flags_pack_sj_store_carry_ram222_bit2             ; 0D4D 0 200 180 CD02
                CMPB    r1, A                  ; 0D4F 0 200 180 21C1
flags_pack_sj_store_carry_ram222_bit2:     MB      off(00222h).2, C       ; 0D51 0 200 180 C4223A
                CLRB    A                      ; 0D54 0 200 180 FA
                JBR     off(00216h).3, flags_pack_sj_store_ram23c ; 0D55 0 200 180 DB1621
                JBS     off(00211h).5, flags_pack_sj_store_ram23c ; 0D58 0 200 180 ED111E
                JBS     off(00218h).5, flags_pack_sj_store_ram23c ; 0D5B 0 200 180 ED181B
                JBS     off(0021dh).4, flags_pack_sj_store_ram23c ; 0D5E 0 200 180 EC1D18
                JBR     off(00211h).4, flags_pack_sj_store_ram23c ; 0D61 0 200 180 DC1115
                CMPB    0c1h, #02eh            ; 0D64 0 200 180 C5C1C02E
                JGE     flags_pack_sj_store_ram23c             ; 0D68 0 200 180 CD0F
                JBS     off(0021ah).3, flags_pack_sj_store_ram23c ; 0D6A 0 200 180 EB1A0C
                JBR     off(00222h).1, flags_pack_sj_store_ram23c ; 0D6D 0 200 180 D92209
                JBR     off(00222h).2, flags_pack_sj_store_ram23c ; 0D70 0 200 180 DA2206
                LB      A, 0b9h                ; 0D73 0 200 180 F5B9
                MOV     X1, #flags_pack_sj_tbl_2          ; 0D75 0 200 180 60076B
                VCAL    0                      ; 0D78 0 200 180 10
flags_pack_sj_store_ram23c:     STB     A, off(0023ch)         ; 0D79 0 200 180 D43C
                LB      A, #0ffh               ; 0D7B 0 200 180 77FF
                JBS     off(00222h).3, callhelper_table_interp_lookup ; 0D7D 0 200 180 EB2202
                LB      A, #0feh               ; 0D80 0 200 180 77FE
callhelper_table_interp_lookup:     CMPB    0a6h, A                ; 0D82 0 200 180 C5A6C1
                MB      off(00222h).3, C       ; 0D85 0 200 180 C4223B
                CLRB    A                      ; 0D88 0 200 180 FA
                JLT     callhelper_table_interp_lookup_store_ram23d             ; 0D89 0 200 180 CA0F
                CMPB    0c1h, #001h            ; 0D8B 0 200 180 C5C1C001
                JGE     callhelper_table_interp_lookup_store_ram23d             ; 0D8F 0 200 180 CD09
                JBS     off(0021dh).5, callhelper_table_interp_lookup_store_ram23d ; 0D91 0 200 180 ED1D06
                LB      A, off(00236h)         ; 0D94 0 200 180 F436
                MOV     X1, #callhelper_table_interp_lookup_tbl_2          ; 0D96 0 200 180 60F56A
                VCAL    0                      ; 0D99 0 200 180 10
callhelper_table_interp_lookup_store_ram23d:     STB     A, off(0023dh)         ; 0D9A 0 200 180 D43D
                J       callhelper_table_interp_lookup_load_x1             ; 0D9C 0 200 180 03C55A
skel_tipin_after_fault_test:                JBS     off(0021dh).4, tipin_gate_fail ; 0DA6 1 200 180 EC1D1D
                JBS     off(00216h).3, tipin_gate_fail ; 0DA9 1 200 180 EB161A
                CMPB    0c1h, #034h            ; 0DAC 1 200 180 C5C1C034
                JGE     tipin_gate_fail             ; 0DB0 1 200 180 CD14
                LB      A, 0b4h                ; 0DB2 0 200 180 F5B4
                CMPB    A, #005h               ; 0DB4 0 200 180 C605
                JLT     tipin_gate_fail             ; 0DB6 0 200 180 CA0E
                CMPB    A, #078h               ; 0DB8 0 200 180 C678
                JGE     tipin_gate_fail             ; 0DBA 0 200 180 CD0A
                LB      A, off(00236h)         ; 0DBC 0 200 180 F436
                CMPB    A, #040h               ; 0DBE 0 200 180 C640
                JLT     tipin_gate_fail             ; 0DC0 0 200 180 CA04
                CMPB    A, #0a0h               ; 0DC2 0 200 180 C6A0
                JLT     callhelper_table_interp_lookup_if_ram220_bit0_set             ; 0DC4 0 200 180 CA02
tipin_gate_fail:     SJ      tipin_gate_fail_goto_5b0f             ; 0DC6 0 200 180 CB63
callhelper_table_interp_lookup_if_ram220_bit0_set:     JBS     off(00220h).0, tipin_gate_pass ; 0DC8 0 200 180 E82018
                NOP                            ; 0DCB 0 200 180 00
                NOP                            ; 0DCC 0 200 180 00
                NOP                            ; 0DCD 0 200 180 00
                NOP                            ; 0DCE 0 200 180 00
                NOP                            ; 0DCF 0 200 180 00
                JBR     off(00231h).6, tipin_gate2 ; 0DD0 0 200 180 DE3107
                LB      A, off(00237h)         ; 0DD3 0 200 180 F437
                JNE     tipin_decay_check             ; 0DD5 0 200 180 CE35
                SJ      tipin_gate_fail_goto_5b0f             ; 0DD7 0 200 180 CB52
tipin_gate2:     JBR     off(0021bh).1, tipin_decay_zero ; 0DDA 0 200 180 D91B51
                CMPB    0bdh, #010h            ; 0DDD 0 200 180 C5BDC010
                JLT     tipin_decay_zero             ; 0DE1 0 200 180 CA4B
tipin_gate_pass:     SB      off(00220h).0          ; 0DE3 0 200 180 C42018
                JBS     off(0021bh).6, tipin_gate_pass_goto_5ad9 ; 0DE6 0 200 180 EE1B07
                CMP     0aeh, #0ffffh          ; 0DE9 0 200 180 B5AEC0FFFF
                JGE     tipin_decay_zero             ; 0DEE 0 200 180 CD3E
tipin_gate_pass_goto_5ad9:     J       tipin_gate_pass_load_ram24f             ; 0DF0 0 200 180 03D95A
tipin_gate_pass_load_ram236:     LB      A, off(00236h)         ; 0DF3 0 200 180 F436
                VCAL    0                      ; 0DF5 0 200 180 10
                MOVB    r0, off(00250h)        ; 0DF6 0 200 180 C45048
                MULB                           ; 0DF9 0 200 180 A234
                L       A, ACC                 ; 0DFB 1 200 180 E506
                SLL     A                      ; 0DFD 1 200 180 53
                JGE     tipin_enrich_clamp             ; 0DFE 1 200 180 CD03
                L       A, #0ffffh             ; 0E00 1 200 180 67FFFF
tipin_enrich_clamp:     LB      A, ACCH                ; 0E03 0 200 180 F507
                RB      off(00220h).0          ; 0E05 0 200 180 C42008
                NOP                            ; 0E08 0 200 180 00
                NOP                            ; 0E09 0 200 180 00
                NOP                            ; 0E0A 0 200 180 00
                NOP                            ; 0E0B 0 200 180 00
tipin_decay_check:     CMPB    off(0024eh), #000h     ; 0E0C 0 200 180 C44EC000
                JEQ     tipin_decay_check_goto_5aea             ; 0E10 0 200 180 C907
                DECB    off(0024eh)            ; 0E12 0 200 180 C44E17
                MOVB    r0, #001h              ; 0E15 0 200 180 9801
                SJ      tipin_decay_sub             ; 0E17 0 200 180 CB0C
tipin_decay_check_goto_5aea:     J       tipin_decay_check_if_ram21b_bit6_set             ; 0E19 0 200 180 03EA5A
tipin_decay_common_store_carry_ram232_bit5:     MB      off(00232h).5, C       ; 0E1E 0 200 180 C4323D
                JGE     tipin_decay_rc             ; 0E21 0 200 180 CD0C
                MOVB    r0, #003h              ; 0E23 0 200 180 9803
tipin_decay_sub:     SUBB    A, r0                  ; 0E25 0 200 180 28
                JLT     tipin_decay_zero             ; 0E26 0 200 180 CA06
                SC                             ; 0E28 0 200 180 85
                SJ      tipin_decay_store             ; 0E29 0 200 180 CB05
tipin_gate_fail_goto_5b0f:     J       tipin_gate_fail_clear_ram220_bit0             ; 0E2B 0 200 180 030F5B
tipin_decay_zero:     CLRB    A                      ; 0E2E 0 200 180 FA
tipin_decay_rc:     RC                             ; 0E2F 0 200 180 95
tipin_decay_store:     STB     A, off(00237h)         ; 0E30 0 200 180 D437
                J       tipin_decay_store_store_carry_ram220_bit1             ; 0E32 0 200 180 03935C
gate_255_common_if_ram216_bit3_set:     JBS     off(00216h).3, vss_threshold_2ee_0 ; 0E35 0 200 180 EB1643
                CLR     A                      ; 0E38 (skeleton: fault flags are always clear)
                JBS     off(0021dh).4, vss_threshold_2ee_0 ; 0E42 1 200 180 EC1D36
                MOVB    r0, #0c0h              ; 0E45 1 200 180 98C0
                MOVB    r1, #08ah              ; 0E47 1 200 180 998A
                MOVB    r2, #09ch              ; 0E49 1 200 180 9A9C
                MOVB    r3, #048h              ; 0E4B 1 200 180 9B48
                JBS     off(00221h).6, gate_255_common_load_ram236 ; 0E4D 1 200 180 EE2108
                MOVB    r0, #0bah              ; 0E50 1 200 180 98BA
                MOVB    r1, #090h              ; 0E52 1 200 180 9990
                MOVB    r2, #092h              ; 0E54 1 200 180 9A92
                MOVB    r3, #051h              ; 0E56 1 200 180 9B51
gate_255_common_load_ram236:     LB      A, off(00236h)         ; 0E58 0 200 180 F436
                CMPB    A, r0                  ; 0E5A 0 200 180 48
                JGE     vss_threshold_2ee_0_store_carry_ram221_bit6             ; 0E5B 0 200 180 CD1F
                CMPB    A, r1                  ; 0E5D 0 200 180 49
                JLT     vss_threshold_2ee_0             ; 0E5E 0 200 180 CA1B
                LB      A, off(00235h)         ; 0E60 0 200 180 F435
                CMPB    A, r2                  ; 0E62 0 200 180 4A
                JGE     vss_threshold_2ee_0_store_carry_ram221_bit6             ; 0E63 0 200 180 CD17
                CMPB    A, r3                  ; 0E65 0 200 180 4B
                JLT     vss_threshold_2ee_0             ; 0E66 0 200 180 CA13
                LB      A, off(00237h)         ; 0E68 0 200 180 F437
                JNE     vss_threshold_2ee_0             ; 0E6A 0 200 180 CE0F
                CMPB    0c1h, #001h            ; 0E6C 0 200 180 C5C1C001
                JGE     vss_threshold_2ee_0_store_carry_ram221_bit6             ; 0E70 0 200 180 CD0A
                LCB     A, gate_255_common_tbl            ; 0E72 0 200 180 909D1060
                JNE     vss_threshold_2ee_0_store_carry_ram221_bit6             ; 0E76 0 200 180 CE04
                JBS     off(0021ah).3, vss_threshold_2ee_0_store_carry_ram221_bit6 ; 0E78 0 200 180 EB1A01
vss_threshold_2ee_0:     RC                             ; 0E7B 0 200 180 95
vss_threshold_2ee_0_store_carry_ram221_bit6:     MB      off(00221h).6, C       ; 0E7C 0 200 180 C4213E
                LB      A, 0aah                ; 0E7F 0 200 180 F5AA
                MOV     X1, #tbl_iat_correct1          ; 0E81 0 200 180 601A6A
                VCAL    0                      ; 0E84 0 200 180 10
                STB     A, off(00245h)         ; 0E85 0 200 180 D445
                LB      A, 0aah                ; 0E87 0 200 180 F5AA
                MOV     X1, #tbl_iat_correct2          ; 0E89 0 200 180 60E669
                VCAL    0                      ; 0E8C 0 200 180 10
                STB     A, off(0024ah)         ; 0E8D 0 200 180 D44A
                STB     A, r0                  ; 0E8F 0 200 180 88
                LB      A, off(0024bh)         ; 0E90 0 200 180 F44B
                MULB                           ; 0E92 0 200 180 A234
                L       A, ACC                 ; 0E94 1 200 180 E506
                ST      A, er1                 ; 0E96 1 200 180 89
                CAL     dwell_scale_helper             ; 0E97 1 200 180 322D53
                ST      A, off(0024ch)         ; 0E9A 1 200 180 D44C
                LB      A, #050h               ; 0E9C 0 200 180 7750
                JBS     off(00221h).5, vss_threshold_2ee_0_cmp_acc ; 0E9E 0 200 180 ED2102
                LB      A, #051h               ; 0EA1 0 200 180 7751
vss_threshold_2ee_0_cmp_acc:     CMPB    A, off(00236h)         ; 0EA3 0 200 180 C736
                MB      off(00221h).5, C       ; 0EA5 0 200 180 C4213D
                L       A, er1                 ; 0EA8 1 200 180 35
                JLT     dwell_scale_shift             ; 0EA9 1 200 180 CA01
                SRL     A                      ; 0EAB 1 200 180 63
dwell_scale_shift:     SRL     A                      ; 0EAC 1 200 180 63
                CAL     dwell_scale_helper             ; 0EAD 1 200 180 322D53
                ST      A, off(0024dh)         ; 0EB0 1 200 180 D44D
                MOV     DP, #dwell_scale_shift_tbl_3          ; 0EB2 1 200 180 62996A
                MOV     er0, (001dch-00180h)[USP] ; 0EB5 1 200 180 B35C48
                LB      A, (001d9h-00180h)[USP] ; 0EB8 0 200 180 F359
                JBS     off(0021fh).1, dwell_scale_shift_goto_58c1 ; 0EBA 0 200 180 E91F08
                MOV     DP, #dwell_scale_shift_tbl          ; 0EBD 0 200 180 62E658
                MOV     er0, (001dah-00180h)[USP] ; 0EC0 0 200 180 B35A48
                LB      A, (001d8h-00180h)[USP] ; 0EC3 0 200 180 F358
dwell_scale_shift_goto_58c1:     J       dwell_scale_shift_if_ram21d_bit4_clr             ; 0EC5 0 200 180 03C158
dwell_scale_shift_store_ram249:     STB     A, off(00249h)         ; 0EC8 0 200 180 D449
                CLR     A                      ; 0ECA 1 200 180 F9
                ST      A, er3                 ; 0ECB 1 200 180 8B
                JBR     off(00220h).1, ign_sum_stage1 ; 0ECF 1 200 180 D92003
                J       dwell_scale_shift_load_ram0b9             ; 0ED2 1 200 180 03185B
ign_sum_stage1:     LB      A, off(00238h)         ; 0ED5 0 200 180 F438
                ADD     er3, A                 ; 0ED7 0 200 180 4781
                LB      A, off(00239h)         ; 0ED9 0 200 180 F439
                ADD     er3, A                 ; 0EDB 0 200 180 4781
                LB      A, off(0023ah)         ; 0EDD 0 200 180 F43A
                ADD     er3, A                 ; 0EDF 0 200 180 4781
                LB      A, off(0023bh)         ; 0EE1 0 200 180 F43B
                ADD     er3, A                 ; 0EE3 0 200 180 4781
                LB      A, off(0023ch)         ; 0EE5 0 200 180 F43C
                ADD     er3, A                 ; 0EE7 0 200 180 4781
                LB      A, off(0023dh)         ; 0EE9 0 200 180 F43D
                ADD     er3, A                 ; 0EEB 0 200 180 4781
                J       ign_sum_stage1_load_ram2fa             ; 0EED 0 200 180 03EE5C
ign_sum_negate:     CLR     A                      ; 0EF0 1 200 180 F9
                LB      A, off(0023eh)         ; 0EF1 0 200 180 F43E
                ADD     er3, A                 ; 0EF3 0 200 180 4781
                LB      A, off(0023fh)         ; 0EF5 0 200 180 F43F
                EXTND                          ; 0EF7 1 200 180 F8
                ADD     er3, A                 ; 0EF8 1 200 180 4781
                LB      A, off(00240h)         ; 0EFA 0 200 180 F440
                EXTND                          ; 0EFC 1 200 180 F8
                ADD     er3, A                 ; 0EFD 1 200 180 4781
                LB      A, off(00241h)         ; 0EFF 0 200 180 F441
                EXTND                          ; 0F01 1 200 180 F8
                ADD     er3, A                 ; 0F02 1 200 180 4781
ign_sum_stage4:     LB      A, off(00242h)         ; 0F04 0 200 180 F442
                EXTND                          ; 0F06 1 200 180 F8
                ADD     er3, A                 ; 0F07 1 200 180 4781
; (skeleton: no knock retard to subtract)
                CLR     A                      ; 0F0E 1 200 180 F9
                LB      A, off(00244h)         ; 0F0F 0 200 180 F444
                STB     A, r0                  ; 0F11 0 200 180 88
                L       A, ACC                 ; 0F12 1 200 180 E506
                ADD     A, er3                 ; 0F14 1 200 180 0B
                JBR     off(00207h).7, ign_sum_clamp_check ; 0F15 1 200 180 DF0705
                JLT     ign_sum_result             ; 0F18 1 200 180 CA0A
                CLRB    A                      ; 0F1A 0 200 180 FA
                SJ      ign_sum_result             ; 0F1B 0 200 180 CB07
ign_sum_clamp_check:     CMP     A, #000ffh             ; 0F1D 1 200 180 C6FF00
                JLT     ign_sum_result             ; 0F20 1 200 180 CA02
                LB      A, #0ffh               ; 0F22 0 200 180 77FF
ign_sum_result:     LB      A, ACC                 ; 0F24 0 200 180 F506
                STB     A, r4                  ; 0F26 0 200 180 8C
                JBR     off(00221h).6, ign_sum_result_store_r5 ; 0F27 0 200 180 DE211A
                LB      A, #0ffh               ; 0F2A 0 200 180 77FF
                MULB                           ; 0F2C 0 200 180 A234
                CLRB    A                      ; 0F2E 0 200 180 FA
                L       A, ACC                 ; 0F2F 1 200 180 E506
                SWAP                           ; 0F31 1 200 180 83
                ADD     A, er3                 ; 0F32 1 200 180 0B
                JBR     off(00207h).7, ign_sum_result_cmp_acc ; 0F33 1 200 180 DF0705
                JLT     ign_sum_result_load_acc             ; 0F36 1 200 180 CA0A
                CLRB    A                      ; 0F38 0 200 180 FA
                SJ      ign_sum_result_load_acc             ; 0F39 0 200 180 CB07
ign_sum_result_cmp_acc:     CMP     A, #000ffh             ; 0F3B 1 200 180 C6FF00
                JLT     ign_sum_result_load_acc             ; 0F3E 1 200 180 CA02
                LB      A, #0ffh               ; 0F40 0 200 180 77FF
ign_sum_result_load_acc:     LB      A, ACC                 ; 0F42 0 200 180 F506
ign_sum_result_store_r5:     STB     A, r5                  ; 0F44 0 200 180 8D
                LB      A, #040h               ; 0F45 0 200 180 7740
                SC                             ; 0F47 0 200 180 85
                CMPB    0c1h, #0d0h            ; 0F4B 0 200 180 C5C1C0D0
                JLT     ign_p40_flag_store             ; 0F4F 0 200 180 CA24
                JBS     off(00221h).7, ign_result_clamp249 ; 0F51 0 200 180 EF2124
                MB      C, P4.0                ; 0F54 0 200 180 C52C28
                JLT     ign_p40_store             ; 0F57 0 200 180 CA17
                LB      A, #000h               ; 0F59 0 200 180 7700
                MB      C, off(0021eh).0       ; 0F5B 0 200 180 C41E28
                JLT     ign_p40_store             ; 0F5E 0 200 180 CA10
                JBR     off(00218h).0, ign_p40_toggle ; 0F60 0 200 180 D8180F
                LB      A, off(00248h)         ; 0F63 0 200 180 F448
                ADDB    A, #004h               ; 0F65 0 200 180 8604
                JGE     ign_p40_clamp             ; 0F67 0 200 180 CD02
                LB      A, #0ffh               ; 0F69 0 200 180 77FF
ign_p40_clamp:     CMPB    A, r4                  ; 0F6B 0 200 180 4C
                JGE     ign_p40_toggle             ; 0F6C 0 200 180 CD04
                STB     A, r4                  ; 0F6E 0 200 180 8C
                STB     A, r5                  ; 0F6F 0 200 180 8D
ign_p40_store:     STB     A, off(00248h)         ; 0F70 0 200 180 D448
ign_p40_toggle:     XORB    PSWH, #080h            ; 0F72 0 200 180 A2F080
ign_p40_flag_store:     MB      off(00221h).7, C       ; 0F75 0 200 180 C4213F
ign_result_clamp249:     MOVB    r3, off(00249h)        ; 0F78 0 200 180 C4494B
                LB      A, r4                  ; 0F7B 0 200 180 7C
                CMPB    A, r3                  ; 0F7C 0 200 180 4B
                JGE     ign_result_clamp_common             ; 0F7D 0 200 180 CD01
                LB      A, r3                  ; 0F7F 0 200 180 7B
ign_result_clamp_common:     RC                             ; 0F80 0 200 180 95
                JBS     off(00217h).0, ign_flag_217_1 ; 0F81 0 200 180 E81705
                LB      A, ACC                 ; 0F84 0 200 180 F506
                JNE     ign_flag_217_1             ; 0F86 0 200 180 CE01
                SC                             ; 0F88 0 200 180 85
ign_flag_217_1:     MB      off(00217h).1, C       ; 0F89 0 200 180 C41739
                MOV     DP, #0035ch            ; 0F8C 0 200 180 625C03
                JBS     off(0021eh).0, ign_result_zero ; 0F8F 0 200 180 E81E03
                JBR     off(00217h).1, ign_result_add_247 ; 0F92 0 200 180 D91708
ign_result_zero:     CLRB    A                      ; 0F95 0 200 180 FA
                STB     A, [DP]                ; 0F96 0 200 180 D2
                STB     A, off(00246h)         ; 0F97 0 200 180 D446
                STB     A, off(00247h)         ; 0F99 0 200 180 D447
                SJ      gearcorrect_store_result_load_r2             ; 0F9B 0 200 180 CB16
ign_result_add_247:     STB     A, [DP]                ; 0F9D 0 200 180 D2
                ADDB    A, off(00245h)         ; 0F9E 0 200 180 8745
                JGE     ignmap_disable_check             ; 0FA0 0 200 180 CD02
                LB      A, #0ffh               ; 0FA2 0 200 180 77FF
ignmap_disable_check:     STB     A, off(00246h)         ; 0FA4 0 200 180 D446
                LB      A, r5                  ; 0FA6 0 200 180 7D
                CMPB    A, r3                  ; 0FA7 0 200 180 4B
                JGE     gearcorrect_store_result             ; 0FA8 0 200 180 CD01
                LB      A, r3                  ; 0FAA 0 200 180 7B
gearcorrect_store_result:     ADDB    A, off(00245h)         ; 0FAB 0 200 180 8745
                JGE     gearcorrect_store_result_store_ram247             ; 0FAD 0 200 180 CD02
                LB      A, #0ffh               ; 0FAF 0 200 180 77FF
gearcorrect_store_result_store_ram247:     STB     A, off(00247h)         ; 0FB1 0 200 180 D447
gearcorrect_store_result_load_r2:     CAL     skel_ign_service ; (skeleton) module retard request, then hook_ign
                MOVB    r2, off(00246h)        ; 0FB3 0 200 180 C4464A
                MOVB    r4, off(0024ch)        ; 0FB6 0 200 180 C44C4C
                CAL     ign_angle_to_timer_convert             ; 0FB9 0 200 180 322F4E
                MOV     DP, #00355h            ; 0FBC 0 200 180 625503
                AND     IE, #002a0h            ; 0FBF 0 200 180 B51AD0A002
                RB      PSWH.0                 ; 0FC4 0 200 180 A208
                MB      0a0h.2, C              ; 0FC6 0 200 180 C5A03A
                STB     A, [DP]                ; 0FC9 0 200 180 D2
                INC     DP                     ; 0FCA 0 200 180 72
                L       A, er0                 ; 0FCB 1 200 180 34
                ST      A, [DP]                ; 0FCC 1 200 180 D2
                SB      PSWH.0                 ; 0FCD 1 200 180 A218
                L       A, 0f2h                ; 0FCF 1 200 180 E5F2
                ST      A, IE                  ; 0FD1 1 200 180 D51A
                MOVB    r2, off(00247h)        ; 0FD3 1 200 180 C4474A
                MOVB    r4, off(0024ch)        ; 0FD6 1 200 180 C44C4C
                CAL     ign_angle_to_timer_convert             ; 0FD9 1 200 180 322F4E
                MOV     DP, #00359h            ; 0FDC 1 200 180 625903
                AND     IE, #002a0h            ; 0FDF 1 200 180 B51AD0A002
                RB      PSWH.0                 ; 0FE4 1 200 180 A208
                MB      0a0h.3, C              ; 0FE6 1 200 180 C5A03B
                ST      A, [DP]                ; 0FE9 1 200 180 D2
                INC     DP                     ; 0FEA 1 200 180 72
                L       A, er0                 ; 0FEB 1 200 180 34
                ST      A, [DP]                ; 0FEC 1 200 180 D2
                SB      PSWH.0                 ; 0FED 1 200 180 A218
                L       A, 0f2h                ; 0FEF 1 200 180 E5F2
                ST      A, IE                  ; 0FF1 1 200 180 D51A
                MOVB    r2, off(00246h)        ; 0FF3 1 200 180 C4464A
                MOVB    r4, off(0024dh)        ; 0FF6 1 200 180 C44D4C
                CAL     ign_angle_to_timer_convert             ; 0FF9 1 200 180 322F4E
                MOV     DP, #0035dh            ; 0FFC 1 200 180 625D03
                AND     IE, #002a0h            ; 0FFF 1 200 180 B51AD0A002
                RB      PSWH.0                 ; 1004 1 200 180 A208
                MB      0a0h.4, C              ; 1006 1 200 180 C5A03C
                ST      A, [DP]                ; 1009 1 200 180 D2
                INC     DP                     ; 100A 1 200 180 72
                L       A, er0                 ; 100B 1 200 180 34
                ST      A, [DP]                ; 100C 1 200 180 D2
                SB      PSWH.0                 ; 100D 1 200 180 A218
                L       A, 0f2h                ; 100F 1 200 180 E5F2
                ST      A, IE                  ; 1011 1 200 180 D51A
                MOV     LRB, #00020h           ; 1013 1 100 180 572000
                MOV     USP, #00280h           ; 1016 1 100 280 A1988002
                CAL     refresh_engine_flags_snapshot             ; 101A 1 100 280 326252
                SC                             ; 101D 1 100 280 85
                JBR     off(00116h).6, igntiming_enable_pin_drive ; 101E 1 100 280 DE1609
                JBR     off(00119h).3, igntiming_enable_pin_drive ; 1021 1 100 280 DB1906
                MB      C, 0a0h.5              ; 1024 1 100 280 C5A02D
                XORB    PSWH, #080h            ; 1027 1 100 280 A2F080
igntiming_enable_pin_drive:     MB      P1.2, C                ; 102A 1 100 280 C5223A
                AND     IE, #002a0h            ; 102D 1 100 280 B51AD0A002
                RB      PSWH.0                 ; 1032 1 100 280 A208
                LB      A, P1                  ; 1034 0 100 280 F522
                MOV     DP, #02f00h            ; 1036 0 100 280 62002F
                STB     A, [DP]                ; 1039 0 100 280 D2
                SB      PSWH.0                 ; 103A 0 100 280 A218
                L       A, 0f2h                ; 103C 1 100 280 E5F2
                ST      A, IE                  ; 103E 1 100 280 D51A
                L       A, #01d4ch             ; 1040 1 100 280 674C1D
                JBS     off(00121h).1, vtec_rawperiod_threshold_check ; 1043 1 100 280 E92103
                L       A, #00ea6h             ; 1046 1 100 280 67A60E
vtec_rawperiod_threshold_check:     CMP     0ach, A                ; 1049 1 100 280 B5ACC1
                MB      off(00121h).1, C       ; 104C 1 100 280 C42139
; (skeleton: no VTEC oil-pressure monitoring - the pressure switch (P4.6) and pressure input (ADC 5) are not read;
;  the state is always "normal", so there is no pressure fault, no transition retard and no limp mode)
vtec_state_clear:     CLRB    r1                     ; 1077 0 100 280 2115
                J       vtec_state_finalize             ; 1079 0 100 280 035811
vtec_state_finalize:
                CLRB    A                      ; 115B 0 100 280 FA
                STB     A, off(001c8h)         ; 115C 0 100 280 D4C8
                CMPB    r1, #001h              ; 115E 0 100 280 21C001
                JNE     vtec_state_store2             ; 1161 0 100 280 CE01
                LB      A, r1                  ; 1163 0 100 280 79
vtec_state_store2:     STB     A, off(001cah)         ; 1164 0 100 280 D4CA
vtec_state_store2_load_imm:     LB      A, #005h               ; 1166 0 100 280 7705
                MOVB    r0, #014h              ; 1168 0 100 280 9814
                JBS     off(00128h).0, vtec_state_store2_if_ram116_bit3_set ; 116A 0 100 280 E82804
                LB      A, #00ah               ; 116D 0 100 280 770A
                MOVB    r0, #019h              ; 116F 0 100 280 9819
vtec_state_store2_if_ram116_bit3_set:     JBS     off(00116h).3, vtec_state_store2_cmp_acc ; 1171 0 100 280 EB1601
                LB      A, r0                  ; 1174 0 100 280 78
vtec_state_store2_cmp_acc:     CMPB    A, 0b4h                ; 1175 0 100 280 C5B4C2
                MB      off(00128h).0, C       ; 1178 0 100 280 C42838
                MOV     DP, #vtec_state_store2_tbl          ; 117B 0 100 280 623264
                MOV     X1, #vtec_state_store2_tbl_3          ; 117E 0 100 280 603A64
                JBS     off(00116h).3, vtec_state_store2_rom_load_dp_ind ; 1181 0 100 280 EB1606
                MOV     DP, #vtec_state_store2_tbl_2          ; 1184 0 100 280 623664
                MOV     X1, #vtec_state_store2_tbl_4          ; 1187 0 100 280 604864
vtec_state_store2_rom_load_dp_ind:     LC      A, [DP]                ; 118A 0 100 280 92A8
                INC     DP                     ; 118C 0 100 280 72
                INC     DP                     ; 118D 0 100 280 72
                JBS     off(00128h).1, vtec_rpm_vs_settings_check ; 118E 0 100 280 E92802
                LB      A, ACCH                ; 1191 0 100 280 F507
vtec_rpm_vs_settings_check:     CMPB    A, off(0012dh)         ; 1193 0 100 280 C72D
                MB      off(00128h).1, C       ; 1195 0 100 280 C42839
                LC      A, [DP]                ; 1198 0 100 280 92A8
                JBS     off(00128h).2, vtec_rpm_vs_settings_check_cmp_acc ; 119A 0 100 280 EA2802
                LB      A, ACCH                ; 119D 0 100 280 F507
vtec_rpm_vs_settings_check_cmp_acc:     CMPB    A, off(0012dh)         ; 119F 0 100 280 C72D
                MB      off(00128h).2, C       ; 11A1 0 100 280 C4283A
                LB      A, off(0012dh)         ; 11A4 0 100 280 F42D
                VCAL    0                      ; 11A6 0 100 280 10
                STB     A, off(00158h)         ; 11A7 0 100 280 D458
                JBR     off(00116h).4, vtec_disengage_output ; 11A9 0 100 280 DC160D
                J       vtec_engage_conditions_start ; 11AC (skeleton: fault flags are always clear)
vtec_disengage_output:     RB      P1.1                   ; 11B9 0 100 280 C52209
                SJ      vtec_highcam_output             ; 11BC 0 100 280 CB24
vtec_engage_conditions_start:     SB      P1.1                   ; 11BE 0 100 280 C52219
                CMPB    0e9h, #032h            ; 11C1 0 100 280 C5E9C032
                JLT     vtec_highcam_output             ; 11C5 0 100 280 CA1B
                CMPB    0c1h, #044h            ; 11C7 0 100 280 C5C1C044
                JGE     vtec_highcam_output             ; 11CB 0 100 280 CD15
                LCB     A, gate_255_common_tbl            ; 11CD 0 100 280 909D1060
                JNE     vtec_engage_conditions_start_if_ram116_bit3_clr             ; 11D1 0 100 280 CE03
                JBR     off(00128h).0, vtec_highcam_output ; 11D3 0 100 280 D8280C
vtec_engage_conditions_start_if_ram116_bit3_clr:     JBR     off(00116h).3, vtec_engage_conditions_start_if_ram128_bit1_set ; 11D6 0 100 280 DB1603
                JBS     off(00111h).5, vtec_engage_conditions_start_if_ram11f_bit1_set ; 11D9 0 100 280 ED1103
vtec_engage_conditions_start_if_ram128_bit1_set:     JBS     off(00128h).1, vtec_engage_conditions_start_load_ram158 ; 11DC 0 100 280 E9280B
vtec_engage_conditions_start_if_ram11f_bit1_set:     JBS     off(0011fh).1, vtec_engage_conditions_start_clear_ram192 ; 11DF 0 100 280 E91F21
vtec_highcam_output:     RB      P1.0                   ; 11E2 0 100 280 C52208
                RB      off(0011fh).2          ; 11E5 0 100 280 C41F0A
                SJ      vtec_highcam_output_load_ram1a4             ; 11E8 0 100 280 CB29
vtec_engage_conditions_start_load_ram158:     LB      A, off(00158h)         ; 11EA 0 100 280 F458
                SUBB    A, off(00159h)         ; 11EC 0 100 280 A759
                JLT     vtec_engage_conditions_start_clear_acc             ; 11EE 0 100 280 CA07
                JBR     off(0011fh).2, vtec_engage_conditions_start_cmp_acc ; 11F0 0 100 280 DA1F05
                SUBB    A, #008h               ; 11F3 0 100 280 A608
                JGE     vtec_engage_conditions_start_cmp_acc             ; 11F5 0 100 280 CD01
vtec_engage_conditions_start_clear_acc:     CLRB    A                      ; 11F7 0 100 280 FA
vtec_engage_conditions_start_cmp_acc:     CMPB    A, off(0012ch)         ; 11F8 0 100 280 C72C
                JLT     vtec_engage_conditions_start_load_ram192             ; 11FA 0 100 280 CA20
                JBS     off(00128h).2, vtec_engage_conditions_start_load_ram192 ; 11FC 0 100 280 EA281D
                LB      A, off(00192h)         ; 11FF 0 100 280 F492
                JNE     vtec_engage_conditions_start_set_p1_bit0             ; 1201 0 100 280 CE1D
vtec_engage_conditions_start_clear_ram192:     CLRB    off(00192h)            ; 1203 0 100 280 C49215
                RB      P1.0                   ; 1206 0 100 280 C52208
                RB      off(0011fh).2          ; 1209 0 100 280 C41F0A
                JBS     off(00111h).1, vtec_engage_conditions_start_load_ram1a4 ; 120C 0 100 280 E9111A
vtec_engage_conditions_start_load_ram1a5:     LB      A, off(001a5h)         ; 120F 0 100 280 F4A5
                JNE     vtec_engage_conditions_start_set_ram11f_bit1             ; 1211 0 100 280 CE1E
vtec_highcam_output_load_ram1a4:     MOVB    off(001a4h), #00ah     ; 1213 0 100 280 C4A4980A
vtec_highcam_output_clear_ram11f_bit1:     RB      off(0011fh).1          ; 1217 0 100 280 C41F09
                SJ      fuelmap_base_lookup             ; 121A 0 100 280 CB18
vtec_engage_conditions_start_load_ram192:     MOVB    off(00192h), #014h     ; 121C 0 100 280 C4929814
vtec_engage_conditions_start_set_p1_bit0:     SB      P1.0                   ; 1220 0 100 280 C52218
                SB      off(0011fh).2          ; 1223 0 100 280 C41F1A
                JBR     off(00111h).1, vtec_engage_conditions_start_load_ram1a5 ; 1226 0 100 280 D911E6
vtec_engage_conditions_start_load_ram1a4:     LB      A, off(001a4h)         ; 1229 0 100 280 F4A4
                JNE     vtec_highcam_output_clear_ram11f_bit1             ; 122B 0 100 280 CEEA
                MOVB    off(001a5h), #00ah     ; 122D 0 100 280 C4A5980A
vtec_engage_conditions_start_set_ram11f_bit1:     SB      off(0011fh).1          ; 1231 0 100 280 C41F19
fuelmap_base_lookup:     MOVB    r0, #00ah              ; 1234 0 100 280 980A
                MOVB    r1, #014h              ; 1236 0 100 280 9914
                MOVB    r2, off(001d3h)        ; 1238 0 100 280 C4D34A
                MOV     X2, off(001d6h)        ; 123B 0 100 280 B4D679
                MOVB    r3, off(001d9h)        ; 123E 0 100 280 C4D94B
                MOV     er3, off(001dch)       ; 1241 0 100 280 B4DC4B
                MOV     X1, #fuelmap_base_lookup_tbl_2          ; 1244 0 100 280 600471
                JBS     off(0011fh).1, fuel_base_lookup_done ; 1247 0 100 280 E91F24
                J       fuelmap_base_lookup_load_r3 ; (skeleton: fault flags are always clear)
fuelmap_base_lookup_load_r3:     MOVB    r3, off(001d8h)        ; 1250 0 100 280 C4D84B
                MOV     er3, off(001dah)       ; 1253 0 100 280 B4DA4B
                MOV     X1, #fuelmap_base_lookup_tbl          ; 1256 0 100 280 603270
                J       fuel_base_lookup_done ; 1259 (skeleton: no EGR maps)
fuel_base_lookup_done:     SB      PSWL.5                 ; 126E 0 100 280 A31D
                CAL     table2d_lookup_interp             ; 1270 0 100 280 321050
                CAL     map_result_postscale             ; 1273 0 100 280 328850
                STB     A, off(00138h)         ; 1276 0 100 280 D438
                LB      A, off(00170h)         ; 1278 0 100 280 F470
                JBS     off(00117h).5, accel_iac_calc ; 127A 0 100 280 ED1705
                JBS     off(0011fh).0, fuel_timer_scale ; 127D 0 100 280 E81F1A
                SJ      accel_iac_clamp_min             ; 1280 0 100 280 CB14
accel_iac_calc:     LB      A, off(0015bh)         ; 1282 0 100 280 F45B
                STB     A, r0                  ; 1284 0 100 280 88
                LB      A, #09ah               ; 1285 0 100 280 779A
                MULB                           ; 1287 0 100 280 A234
                L       A, ACC                 ; 1289 1 100 280 E506
                SLL     A                      ; 128B 1 100 280 53
                LB      A, ACCH                ; 128C 0 100 280 F507
                JGE     accel_iac_calc_cmp_acc             ; 128E 0 100 280 CD02
                LB      A, #0ffh               ; 1290 0 100 280 77FF
accel_iac_calc_cmp_acc:     CMPB    A, #040h               ; 1292 0 100 280 C640
                JGE     accel_iac_store             ; 1294 0 100 280 CD02
accel_iac_clamp_min:     LB      A, #040h               ; 1296 0 100 280 7740
accel_iac_store:     STB     A, off(00170h)         ; 1298 0 100 280 D470
fuel_timer_scale:     MOVB    r0, off(00171h)        ; 129A 0 100 280 C47148
                MULB                           ; 129D 0 100 280 A234
                MOVB    r1, off(0016fh)        ; 129F 0 100 280 C46F49
                CLRB    r0                     ; 12A2 0 100 280 2015
                MUL                            ; 12A4 0 100 280 9035
                MOV     er0, er1               ; 12A6 0 100 280 4548
                L       A, off(0014ch)         ; 12A8 1 100 280 E44C
                MUL                            ; 12AA 1 100 280 9035
                MOV     off(001e4h), er1       ; 12AC 1 100 280 457CE4
                CMPB    off(0012dh), #0b4h     ; 12AF 1 100 280 C42DC0B4
                RB      PSWH.7                 ; 12B3 1 100 280 A20F
                MOVB    r0, 0beh               ; 12B5 1 100 280 C5BE48
                MB      C, off(0011bh).2       ; 12B8 1 100 280 C41B2A
                JEQ     accelenrich_rpm_mode_check             ; 12BB 1 100 280 C906
                MOVB    r0, 0bdh               ; 12BD 1 100 280 C5BD48
                MB      C, off(0011bh).1       ; 12C0 1 100 280 C41B29
accelenrich_rpm_mode_check:     JLT     accelenrich_flags_clear             ; 12C3 1 100 280 CA0F
                LB      A, #00ah               ; 12C5 0 100 280 770A
                CMPB    A, r0                  ; 12C7 0 100 280 48
                MB      off(00124h).1, C       ; 12C8 0 100 280 C42439
                LB      A, #00ah               ; 12CB 0 100 280 770A
                CMPB    A, r0                  ; 12CD 0 100 280 48
                MB      off(00124h).2, C       ; 12CE 0 100 280 C4243A
                RC                             ; 12D1 0 100 280 95
                SJ      accelenrich_mode_flag_store             ; 12D2 0 100 280 CB09
accelenrich_flags_clear:     RB      off(00124h).1          ; 12D4 1 100 280 C42409
                RB      off(00124h).2          ; 12D7 1 100 280 C4240A
                LB      A, #004h               ; 12DA 0 100 280 7704
                CMPB    A, r0                  ; 12DC 0 100 280 48
accelenrich_mode_flag_store:     MB      off(00124h).0, C       ; 12DD 0 100 280 C42438
                JBS     off(00111h).0, accelenrich_jump_cranking_path ; 12E3 0 100 280 E81117
                JBR     off(00124h).0, accelenrich_clear_pulse_check ; 12E6 0 100 280 D82457
                JBR     off(0011bh).3, accelenrich_jump_tipin_check ; 12E9 0 100 280 DB1B14
                LB      A, off(00172h)         ; 12EC 0 100 280 F472
                JBS     off(00124h).3, accelenrich_table_lookup ; 12EE 0 100 280 EB243D
                CMPB    0a5h, #0dah            ; 12F1 0 100 280 C5A5C0DA
                JGE     accelenrich_jump_cranking_path             ; 12F5 0 100 280 CD06
                CMPB    0bbh, #0b3h            ; 12F7 0 100 280 C5BBC0B3
                JLT     accelenrich_base_calc             ; 12FB 0 100 280 CA06
accelenrich_jump_cranking_path:     J       accelenrich_clear_and_cranking_prep             ; 12FD 0 100 280 03B913
accelenrich_jump_tipin_check:     J       accelenrich_jump_tipin_check_load_ram13a             ; 1300 0 100 280 037713
accelenrich_base_calc:     CLRB    A                      ; 1303 0 100 280 FA
                JBR     off(00118h).1, accelenrich_base_adjust ; 1304 0 100 280 D91806
                CMPB    0b4h, #005h            ; 1307 0 100 280 C5B4C005
                JLT     accelenrich_result_store             ; 130B 0 100 280 CA1F
accelenrich_base_adjust:     ADDB    A, #02ah               ; 130D 0 100 280 862A
                JBR     off(00126h).4, accelenrich_rpm_tier1 ; 130F 0 100 280 DC2602
                ADDB    A, #006h               ; 1312 0 100 280 8606
accelenrich_rpm_tier1:     CMPB    off(0012dh), #0b4h     ; 1314 0 100 280 C42DC0B4
                JGE     accelenrich_result_store             ; 1318 0 100 280 CD12
                SUBB    A, #00ch               ; 131A 0 100 280 A60C
                CMPB    off(0012dh), #08dh     ; 131C 0 100 280 C42DC08D
                JGE     accelenrich_result_store             ; 1320 0 100 280 CD0A
                SUBB    A, #00ch               ; 1322 0 100 280 A60C
                CMPB    off(0012dh), #066h     ; 1324 0 100 280 C42DC066
                JGE     accelenrich_result_store             ; 1328 0 100 280 CD02
                SUBB    A, #00ch               ; 132A 0 100 280 A60C
accelenrich_result_store:     STB     A, off(00172h)         ; 132C 0 100 280 D472
accelenrich_table_lookup:     CLRB    ACCH                   ; 132E 0 100 280 C50715
                MOV     X1, A                  ; 1331 0 100 280 50
                ADD     X1, #tbl_tipin_enrich_rpm          ; 1332 0 100 280 9080EB61
                LB      A, r0                  ; 1336 0 100 280 78
                VCAL    3                      ; 1337 0 100 280 13
                STB     A, off(001e2h)         ; 1338 0 100 280 D4E2
                CAL     scale_ram1e4_mul_shr2             ; 133A 0 100 280 32B150
                J       cranking_flag_check             ; 133D 0 100 280 03C413
accelenrich_clear_pulse_check:     JBR     off(00124h).2, tipin_rpm_gate ; 1340 0 100 280 DA2403
                CLR     off(0013ah)            ; 1343 0 100 280 B43A15
tipin_rpm_gate:     CMPB    off(0012dh), #060h     ; 1346 0 100 280 C42DC060
                JLT     accelenrich_jump_tipin_check_load_ram13a             ; 134A 0 100 280 CA2B
                JBR     off(00124h).1, tipin_gate_common ; 134C 0 100 280 D92420
                JBR     off(0011bh).3, tipin_gate_common ; 134F 0 100 280 DB1B1D
                MOV     X1, #tbl_tipin_low          ; 1352 0 100 280 607B62
                CMPB    (0024fh-00280h)[USP], #003h ; 1355 0 100 280 C3CFC003
                JGE     tipin_table_gear_adjust             ; 1359 0 100 280 CD04
                ADD     X1, #00006h            ; 135B 0 100 280 90800600
tipin_table_gear_adjust:     CMPB    off(0012dh), #08dh     ; 135F 0 100 280 C42DC08D
                JLT     tipin_table_lookup             ; 1363 0 100 280 CA04
                ADD     X1, #0000ch            ; 1365 0 100 280 90800C00
tipin_table_lookup:     LB      A, r0                  ; 1369 0 100 280 78
                VCAL    3                      ; 136A 0 100 280 13
                LB      A, ACC                 ; 136B 0 100 280 F506
                SJ      accelenrich_clear_0x165             ; 136D 0 100 280 CB4B
tipin_gate_common:     LB      A, off(00155h)         ; 136F 0 100 280 F455
                JEQ     accelenrich_jump_tipin_check_load_ram13a             ; 1371 0 100 280 C904
                ADDB    A, #003h               ; 1373 0 100 280 8603
                JGE     accelenrich_clear_0x165             ; 1375 0 100 280 CD43
accelenrich_jump_tipin_check_load_ram13a:     L       A, off(0013ah)         ; 1377 1 100 280 E43A
                JEQ     accelenrich_clear_and_cranking_prep             ; 1379 1 100 280 C93E
                ST      A, er3                 ; 137B 1 100 280 8B
                LB      A, off(00172h)         ; 137C 0 100 280 F472
                EXTND                          ; 137E 1 100 280 F8
                MOV     DP, #tbl_tipin_normal_enrich          ; 137F 1 100 280 622162
                ADD     DP, A                  ; 1382 1 100 280 9281
                LC      A, [DP]                ; 1384 1 100 280 92A8
                ST      A, er2                 ; 1386 1 100 280 8A
                CMP     A, er3                 ; 1387 1 100 280 4B
                L       A, #00096h             ; 1388 1 100 280 679600
                JLT     tipin_table_result_alt             ; 138B 1 100 280 CA20
                LC      A, 00002h[DP]          ; 138D 1 100 280 92A90200
                ST      A, er2                 ; 1391 1 100 280 8A
                CMP     A, er3                 ; 1392 1 100 280 4B
                JLT     tipin_table_row2             ; 1393 1 100 280 CA0F
                MOV     er0, off(001e8h)       ; 1395 1 100 280 B4E848
                LC      A, 00004h[DP]          ; 1398 1 100 280 92A90400
                CAL     mul_zero_if_r3_zero             ; 139C 1 100 280 32BE50
                XCHG    A, er3                 ; 139F 1 100 280 4710
                SUB     A, er3                 ; 13A1 1 100 280 2B
                SJ      tipin_table_final             ; 13A2 1 100 280 CB13
tipin_table_row2:     MOV     er0, off(001e6h)       ; 13A4 1 100 280 B4E648
                L       A, #00040h             ; 13A7 1 100 280 674000
                CAL     mul_zero_if_r3_zero             ; 13AA 1 100 280 32BE50
tipin_table_result_alt:     XCHG    A, er3                 ; 13AD 1 100 280 4710
                SUB     A, er3                 ; 13AF 1 100 280 2B
                JLT     tipin_table_result_common             ; 13B0 1 100 280 CA03
                CMP     A, er2                 ; 13B2 1 100 280 4A
                JGE     tipin_table_final             ; 13B3 1 100 280 CD02
tipin_table_result_common:     L       A, er2                 ; 13B5 1 100 280 36
                RC                             ; 13B6 1 100 280 95
tipin_table_final:     JGE     cranking_flag_check             ; 13B7 1 100 280 CD0B
accelenrich_clear_and_cranking_prep:     CLRB    A                      ; 13B9 0 100 280 FA
accelenrich_clear_0x165:     STB     A, off(00155h)         ; 13BA 0 100 280 D455
                RB      off(00124h).3          ; 13BC 0 100 280 C4240B
                CLR     A                      ; 13BF 1 100 280 F9
                ST      A, off(001e2h)         ; 13C0 1 100 280 D4E2
                SJ      SetCranking             ; 13C2 1 100 280 CB06
cranking_flag_check:     CLRB    off(00155h)            ; 13C4 0 100 280 C45515
                SB      off(00124h).3          ; 13C7 0 100 280 C4241B
SetCranking:     STB     A, off(0013ah)         ; 13CA 0 100 280 D43A
                JBS     off(00117h).5, Cranking ; 13CC 0 100 280 ED1703
                J       notcranking_entry             ; 13CF 0 100 280 030815
Cranking:     MOV     X1, #CrankFuel          ; 13D2 0 100 280 60FF62
                LB      A, 0c1h                ; 13D5 0 100 280 F5C1
                VCAL    1                      ; 13D7 0 100 280 11
                STB     A, off(00138h)         ; 13D8 0 100 280 D438
                MOV     X1, #CrankFuelComp          ; 13DA 0 100 280 601763
                LB      A, 0adh                ; 13DD 0 100 280 F5AD
                VCAL    2                      ; 13DF 0 100 280 12
                STB     A, off(00153h)         ; 13E0 0 100 280 D453
                MOV     X1, #CrankFuelMap          ; 13E2 0 100 280 601B63
                LB      A, 0a4h                ; 13E5 0 100 280 F5A4
                VCAL    2                      ; 13E7 0 100 280 12
                STB     A, off(00152h)         ; 13E8 0 100 280 D452
                MOVB    r0, off(00153h)        ; 13EA 0 100 280 C45348
                MULB                           ; 13ED 0 100 280 A234
                MOV     er0, off(00138h)       ; 13EF 0 100 280 B43848
                MUL                            ; 13F2 0 100 280 9035
                L       A, ACC                 ; 13F4 1 100 280 E506
                SLL     A                      ; 13F6 1 100 280 53
                ROL     er1                    ; 13F7 1 100 280 45B7
                JLT     crankfuel_clamp_max             ; 13F9 1 100 280 CA09
                SLL     A                      ; 13FB 1 100 280 53
                L       A, er1                 ; 13FC 1 100 280 35
                ROL     A                      ; 13FD 1 100 280 33
                JLT     crankfuel_clamp_max             ; 13FE 1 100 280 CA04
                ADD     A, off(0013ah)         ; 1400 1 100 280 873A
                JGE     crankfuel_halve_check             ; 1402 1 100 280 CD03
crankfuel_clamp_max:     L       A, #0ffffh             ; 1404 1 100 280 67FFFF
crankfuel_halve_check:     MB      C, 09fh.0              ; 1407 1 100 280 C59F28
                JGE     crankfuel_halve_check_add_acc             ; 140A 1 100 280 CD02
                SRL     A                      ; 140C 1 100 280 63
                SRL     A                      ; 140D 1 100 280 63
crankfuel_halve_check_add_acc:     ADD     A, off(0013ch)         ; 140E 1 100 280 873C
                JGE     crankfuel_halve_check_goto_diag_report_finalize             ; 1410 1 100 280 CD03
                L       A, #0ffffh             ; 1412 1 100 280 67FFFF
crankfuel_halve_check_goto_diag_report_finalize:     J       diag_report_finalize             ; 1415 1 100 280 038176
diag_report_finalize_store_dp_ind:     ST      A, [DP]                ; 1418 1 100 280 D2
                CLR     X1                     ; 1419 1 100 280 9015
                CAL     scale_mul5_div4             ; 141B 1 100 280 32B94F
                AND     IE, #002a0h            ; 141E 1 100 280 B51AD0A002
                RB      PSWH.0                 ; 1423 1 100 280 A208
                ST      A, 003aeh[X1]          ; 1425 1 100 280 D0AE03
                ST      A, 003b0h[X1]          ; 1428 1 100 280 D0B003
                ST      A, 003b2h[X1]          ; 142B 1 100 280 D0B203
                ST      A, 003b4h[X1]          ; 142E 1 100 280 D0B403
                SB      PSWH.0                 ; 1431 1 100 280 A218
                L       A, 0f2h                ; 1433 1 100 280 E5F2
                ST      A, IE                  ; 1435 1 100 280 D51A
                MB      C, 09fh.0              ; 1437 1 100 280 C59F28
                JLT     crankfuel_output_apply_start             ; 143A 1 100 280 CA0C
                CMPB    off(00135h), #004h     ; 143C 1 100 280 C435C004
                JNE     postfuel_calc_start             ; 1440 1 100 280 CE54
                CMPB    0c1h, #0e8h            ; 1442 1 100 280 C5C1C0E8
                JGE     postfuel_calc_start             ; 1446 1 100 280 CD4E
crankfuel_output_apply_start:     L       A, 003aeh[X1]          ; 1448 1 100 280 E0AE03
                ST      A, off(001c6h)         ; 144B 1 100 280 D4C6
                ST      A, off(001c4h)         ; 144D 1 100 280 D4C4
                ST      A, off(001c2h)         ; 144F 1 100 280 D4C2
                ST      A, off(001c0h)         ; 1451 1 100 280 D4C0
                L       A, 0f4h                ; 1453 1 100 280 E5F4
                ST      A, IE                  ; 1455 1 100 280 D51A
                RB      PSWH.0                 ; 1457 1 100 280 A208
                L       A, TM0                 ; 1459 1 100 280 E530
                SUB     A, TMR0                ; 145B 1 100 280 B532A2
                MB      C, IRQ.5               ; 145E 1 100 280 C5182D
                JLT     crankfuel_timer_sync_done             ; 1461 1 100 280 CA08
                ADD     A, #00005h             ; 1463 1 100 280 860500
                JLT     crankfuel_timer_sync_done             ; 1466 1 100 280 CA03
                ADD     TMR0, A                ; 1468 1 100 280 B53281
crankfuel_timer_sync_done:     SB      PSWH.0                 ; 146B 1 100 280 A218
                L       A, 0f2h                ; 146D 1 100 280 E5F2
                ST      A, IE                  ; 146F 1 100 280 D51A
                MOV     DP, #00010h            ; 1471 1 100 280 621000
crankfuel_timer_wait_loop:     L       A, off(001c6h)         ; 1474 1 100 280 E4C6
                JRNZ    DP, crankfuel_timer_wait_loop         ; 1476 1 100 280 30FC
                CAL     injector_timer_schedule             ; 1478 1 100 280 32354B
                JBS     off(00117h).3, cylinder_index_advance ; 147B 1 100 280 EB1710
                J       crankfuel_timer_wait_loop_sll_er0             ; 1481 1 100 280 03F576
crankfuel_timer_wait_loop_if_eq_goto_cylinder_index_adva:     JEQ     cylinder_index_advance             ; 1484 1 100 280 C908
                RB      TRNSIT.2               ; 1486 1 100 280 C5460A
                JNE     cylinder_index_advance             ; 1489 1 100 280 CE03
dtc16_injector_latch_2: RB      09ch.6                 ; 148B 1 100 280 C59C1E
cylinder_index_advance:     LB      A, off(00134h)         ; 148E 0 100 280 F434
                ADDB    A, #001h               ; 1490 0 100 280 8601
                ANDB    A, #003h               ; 1492 0 100 280 D603
                STB     A, off(00134h)         ; 1494 0 100 280 D434
postfuel_calc_start:     SB      off(0011fh).0          ; 1496 1 100 280 C41F18
                LB      A, 0c1h                ; 1499 0 100 280 F5C1
                CMPB    A, #0cfh               ; 149B 0 100 280 C6CF
                MB      PSWL.5, C              ; 149D 0 100 280 A33D
                MOV     X1, #PostFuel          ; 149F 0 100 280 60A760
                VCAL    1                      ; 14A2 0 100 280 11
                STB     A, r0                  ; 14A3 0 100 280 88
                STB     A, r1                  ; 14A4 0 100 280 89
                CMPB    0c1h, #0a2h            ; 14AB 0 100 280 C5C1C0A2
                JLT     postfuel_scale_apply             ; 14AF 0 100 280 CA22
                MOV     DP, #00352h            ; 14B1 0 100 280 625203
                LB      A, [DP]                ; 14B4 0 100 280 F2
                SUBB    A, 0c1h                ; 14B5 0 100 280 C5C1A2
                JGE     postfuel_ect_rate_check             ; 14B8 0 100 280 CD01
                VCAL    7                      ; 14BA 0 100 280 17
postfuel_ect_rate_check:     CMPB    A, #010h               ; 14BB 0 100 280 C610
                JGE     postfuel_scale_apply             ; 14BD 0 100 280 CD14
                LB      A, 0c0h                ; 14BF 0 100 280 F5C0
                CMPB    A, #0bah               ; 14C1 0 100 280 C6BA
                JLT     postfuel_scale_apply             ; 14C3 0 100 280 CA0E
                SUBB    A, 0c1h                ; 14C5 0 100 280 C5C1A2
                JLT     postfuel_scale_apply             ; 14C8 0 100 280 CA09
                CMPB    A, #006h               ; 14CA 0 100 280 C606
                JLT     postfuel_scale_apply             ; 14CC 0 100 280 CA05
                L       A, #0e666h             ; 14CE 1 100 280 6766E6
                MUL                            ; 14D1 1 100 280 9035
postfuel_scale_apply:     L       A, er1                 ; 14D3 1 100 280 35
                ST      A, off(00160h)         ; 14D4 1 100 280 D460
                CLRB    off(0015fh)            ; 14D6 1 100 280 C45F15
                MOV     er2, #02000h           ; 14D9 1 100 280 46980020
                SUB     A, er2                 ; 14DD 1 100 280 2A
                ST      A, er3                 ; 14DE 1 100 280 8B
                CLRB    r0                     ; 14DF 1 100 280 2015
                MOVB    r1, #073h              ; 14E1 1 100 280 9973
                MB      C, PSWL.5              ; 14E3 1 100 280 A32D
                JLT     postfuel_hyst_upper_calc             ; 14E5 1 100 280 CA02
                MOVB    r1, #05ah              ; 14E7 1 100 280 995A
postfuel_hyst_upper_calc:     MUL                            ; 14E9 1 100 280 9035
                L       A, er1                 ; 14EB 1 100 280 35
                ADD     A, er2                 ; 14EC 1 100 280 0A
                ST      A, off(00162h)         ; 14ED 1 100 280 D462
                L       A, er3                 ; 14EF 1 100 280 37
                MOVB    r1, #04dh              ; 14F0 1 100 280 994D
                MB      C, PSWL.5              ; 14F2 1 100 280 A32D
                JLT     postfuel_hyst_lower_calc             ; 14F4 1 100 280 CA02
                MOVB    r1, #033h              ; 14F6 1 100 280 9933
postfuel_hyst_lower_calc:     MUL                            ; 14F8 1 100 280 9035
                L       A, er1                 ; 14FA 1 100 280 35
                ADD     A, er2                 ; 14FB 1 100 280 0A
                ST      A, off(00164h)         ; 14FC 1 100 280 D464
                CMPB    0c0h, #030h            ; 14FE 1 100 280 C5C0C030
                MB      off(00123h).3, C       ; 1502 1 100 280 C4233B
                J       postfuel_hyst_lower_calc_call_clamp_diff_15b_1ec             ; 1505 1 100 280 039C5B
notcranking_entry:     RB      09fh.0                 ; 1508 0 100 280 C59F08
                JEQ     postfuel_decay_table_select             ; 150B 0 100 280 C903
                CLRB    off(00135h)            ; 150D 0 100 280 C43515
postfuel_decay_table_select:     JBR     off(0011fh).0, postfuel_decay_zero_reset_load_imm ; 1510 0 100 280 D81F5D
                MOV     DP, #PostFuelDecay          ; 1513 0 100 280 628F60
                JBR     off(00116h).3, postfuel_decay_table_index_adjust ; 1516 0 100 280 DB1609
                MOV     DP, #PostFuelDecay2          ; 1519 0 100 280 629760
                JBS     off(00111h).5, postfuel_decay_table_index_adjust ; 151C 0 100 280 ED1103
                MOV     DP, #PostFuelDecay3          ; 151F 0 100 280 629F60
postfuel_decay_table_index_adjust:     CMPB    off(00161h), #026h     ; 1522 0 100 280 C461C026
                JLE     postfuel_decay_table_index_adjust2             ; 1526 0 100 280 CF06
                CMP     off(00160h), off(00162h) ; 1528 0 100 280 B460C362
                JGT     postfuel_decay_apply             ; 152C 0 100 280 C812
postfuel_decay_table_index_adjust2:     INC     DP                     ; 152E 0 100 280 72
                INC     DP                     ; 152F 0 100 280 72
                CMP     off(00160h), off(00164h) ; 1530 0 100 280 B460C364
                JGT     postfuel_decay_apply             ; 1534 0 100 280 C80A
                INC     DP                     ; 1536 0 100 280 72
                INC     DP                     ; 1537 0 100 280 72
                CMPB    0c0h, #044h            ; 1538 0 100 280 C5C0C044
                JGE     postfuel_decay_apply             ; 153C 0 100 280 CD02
                INC     DP                     ; 153E 0 100 280 72
                INC     DP                     ; 153F 0 100 280 72
postfuel_decay_apply:     LC      A, [DP]                ; 1540 0 100 280 92A8
                SUBB    off(0015fh), A         ; 1542 0 100 280 C45FA1
                CLRB    A                      ; 1545 0 100 280 FA
                L       A, ACC                 ; 1546 1 100 280 E506
                SWAP                           ; 1548 1 100 280 83
                ST      A, er0                 ; 1549 1 100 280 88
                L       A, off(00160h)         ; 154A 1 100 280 E460
                SBC     A, er0                 ; 154C 1 100 280 38
                CMP     A, #02000h             ; 154D 1 100 280 C60020
                JLE     postfuel_decay_zero_reset             ; 1550 1 100 280 CF1B
                ST      A, off(00160h)         ; 1552 1 100 280 D460
                CMPB    0c1h, #02eh            ; 1554 1 100 280 C5C1C02E
                JLT     postfuel_final_store             ; 1558 1 100 280 CA1B
                JBR     off(00111h).2, postfuel_final_store ; 155A 1 100 280 DA1118
                CLRB    r0                     ; 155D 1 100 280 2015
                MOVB    r1, #08dh              ; 155F 1 100 280 998D
                MUL                            ; 1561 1 100 280 9035
                SLL     A                      ; 1563 1 100 280 53
                L       A, er1                 ; 1564 1 100 280 35
                ROL     A                      ; 1565 1 100 280 33
                JGE     postfuel_final_store             ; 1566 1 100 280 CD0D
                L       A, #0ffffh             ; 1568 1 100 280 67FFFF
                SJ      postfuel_final_store             ; 156B 1 100 280 CB08
postfuel_decay_zero_reset:     RB      off(0011fh).0          ; 156D 1 100 280 C41F08
postfuel_decay_zero_reset_load_imm:     L       A, #02000h             ; 1570 1 100 280 670020
                ST      A, off(00160h)         ; 1573 1 100 280 D460
postfuel_final_store:     ST      A, off(0014ah)         ; 1575 1 100 280 D44A
                LB      A, #0bah               ; 1577 0 100 280 77BA
                JBS     off(00127h).0, postfuel_final_store_cmp_acc ; 1579 0 100 280 E82702
                LB      A, #0c0h               ; 157C 0 100 280 77C0
postfuel_final_store_cmp_acc:     CMPB    A, off(0012dh)         ; 157E 0 100 280 C72D
                MB      off(00127h).0, C       ; 1580 0 100 280 C42738
                LB      A, #0deh               ; 1583 0 100 280 77DE
                JBS     off(00127h).5, to_flag_12f_5_select_ff ; 1585 0 100 280 ED2702
                LB      A, #0e0h               ; 1588 0 100 280 77E0
to_flag_12f_5_select_ff:     CMPB    A, off(0012dh)         ; 158A 0 100 280 C72D
                MB      off(00127h).5, C       ; 158C 0 100 280 C4273D
                LB      A, #017h               ; 158F 0 100 280 7717
                JBS     off(00127h).2, to_flag_12f_5_select_ff_cmp_ram0c1 ; 1591 0 100 280 EA2702
                LB      A, #014h               ; 1594 0 100 280 7714
to_flag_12f_5_select_ff_cmp_ram0c1:     CMPB    0c1h, A                ; 1596 0 100 280 C5C1C1
                MB      off(00127h).2, C       ; 1599 0 100 280 C4273A
                LB      A, #014h               ; 159C 0 100 280 7714
                JBS     off(00127h).1, to_flag_12f_5_select_ff_cmp_ram0c1_2 ; 159E 0 100 280 E92702
                LB      A, #011h               ; 15A1 0 100 280 7711
to_flag_12f_5_select_ff_cmp_ram0c1_2:     CMPB    0c1h, A                ; 15A3 0 100 280 C5C1C1
                MB      off(00127h).1, C       ; 15A6 0 100 280 C42739
                LB      A, off(0012dh)         ; 15A9 0 100 280 F42D
                MOV     X1, #to_flag_12f_5_select_ff_tbl          ; 15AB 0 100 280 605261
                JBS     off(00127h).6, to_flag_12f_5_select_ff_vcal_0 ; 15AE 0 100 280 EE2703
                MOV     X1, #to_flag_12f_5_select_ff_tbl_2          ; 15B1 0 100 280 605E61
to_flag_12f_5_select_ff_vcal_0:     VCAL    0                      ; 15B4 0 100 280 10
                CMPB    A, 0b9h                ; 15B5 0 100 280 C5B9C2
                MB      off(00127h).6, C       ; 15B8 0 100 280 C4273E
                LB      A, off(0012dh)         ; 15BB 0 100 280 F42D
                MOV     X1, #tbl_closeloop_tps          ; 15BD 0 100 280 602261
                CMPCB   A, 0000ch[X1]          ; 15C0 0 100 280 90AF0C00
                MB      off(00127h).3, C       ; 15C4 0 100 280 C4273B
                VCAL    0                      ; 15C7 0 100 280 10
                CLRB    r0                     ; 15C8 0 100 280 2015
                RB      PSWL.4                 ; 15CA 0 100 280 A30C
                JBS     off(00127h).3, ve_adjust_sub ; 15CC 0 100 280 EB271C
                MOVB    r0, #020h              ; 15CF 0 100 280 9820
                JBS     off(00127h).1, ve_adjust_sub ; 15D1 0 100 280 E92717
                JBR     off(00116h).1, to_flag_12f_5_select_ff_clear_r0 ; 15D4 0 100 280 D9160D
                JBR     off(00127h).0, to_flag_12f_5_select_ff_clear_r0 ; 15D7 0 100 280 D8270A
                MOVB    r0, #040h              ; 15DA 0 100 280 9840
                JBS     off(00118h).6, ve_adjust_add ; 15DC 0 100 280 EE1807
                JBS     off(00127h).2, ve_adjust_add ; 15DF 0 100 280 EA2704
                SB      PSWL.4                 ; 15E2 0 100 280 A31C
to_flag_12f_5_select_ff_clear_r0:     CLRB    r0                     ; 15E4 0 100 280 2015
ve_adjust_add:     ADDB    r0, off(0016eh)        ; 15E6 0 100 280 20836E
                JLT     ve_adjust_clamp_zero             ; 15E9 0 100 280 CA03
ve_adjust_sub:     SUBB    A, r0                  ; 15EB 0 100 280 28
                JGE     ve_adjust2_gate             ; 15EC 0 100 280 CD01
ve_adjust_clamp_zero:     CLRB    A                      ; 15EE 0 100 280 FA
ve_adjust2_gate:     STB     A, r4                  ; 15EF 0 100 280 8C
                RB      PSWL.4                 ; 15F0 0 100 280 A30C
                JEQ     ve_adjust2_gate_store_r0             ; 15F2 0 100 280 C90B
                LB      A, off(0012dh)         ; 15F4 0 100 280 F42D
                MOV     X1, #ve_adjust2_gate_tbl          ; 15F6 0 100 280 603661
                VCAL    0                      ; 15F9 0 100 280 10
                SUBB    A, off(0016eh)         ; 15FA 0 100 280 A76E
                JGE     ve_adjust2_gate_store_r0             ; 15FC 0 100 280 CD01
                CLRB    A                      ; 15FE 0 100 280 FA
ve_adjust2_gate_store_r0:     STB     A, r0                  ; 15FF 0 100 280 88
                SUBB    A, #010h               ; 1600 0 100 280 A610
                JGE     ve_adjust2_gate_cmp_acc             ; 1602 0 100 280 CD01
                CLRB    A                      ; 1604 0 100 280 FA
ve_adjust2_gate_cmp_acc:     CMPB    A, off(0012ch)         ; 1605 0 100 280 C72C
                MB      off(00128h).5, C       ; 1607 0 100 280 C4283D
                LB      A, r0                  ; 160A 0 100 280 78
                MOVB    r0, #008h              ; 160B 0 100 280 9808
                JBR     off(00128h).4, ve_result_flag_store ; 160D 0 100 280 DC2804
                SUBB    A, r0                  ; 1610 0 100 280 28
                JGE     ve_result_flag_store             ; 1611 0 100 280 CD01
                CLRB    A                      ; 1613 0 100 280 FA
ve_result_flag_store:     CMPB    A, off(0012ch)         ; 1614 0 100 280 C72C
                MB      off(00128h).4, C       ; 1616 0 100 280 C4283C
                LB      A, r4                  ; 1619 0 100 280 7C
                JBR     off(00128h).3, ve_result_flag_store_cmp_acc ; 161A 0 100 280 DB2804
                SUBB    A, r0                  ; 161D 0 100 280 28
                JGE     ve_result_flag_store_cmp_acc             ; 161E 0 100 280 CD01
                CLRB    A                      ; 1620 0 100 280 FA
ve_result_flag_store_cmp_acc:     CMPB    A, off(0012ch)         ; 1621 0 100 280 C72C
                MB      off(00128h).3, C       ; 1623 0 100 280 C4283B
                SC                             ; 1626 0 100 280 85
                JBR     off(00116h).1, ve_result_flag_store_store_carry_ram11e_bit3 ; 1627 0 100 280 D91649
                JBS     off(00118h).6, ve_result_flag_store_store_carry_ram11e_bit3 ; 162A 0 100 280 EE1846
                JBS     off(00128h).5, ve_result_flag_store_load_ram187 ; 162D 0 100 280 ED280F
                RB      off(00121h).2          ; 1630 0 100 280 C4210A
                JEQ     ve_result_flag_store_clear_ram185             ; 1633 0 100 280 C904
                MOVB    off(00186h), off(00185h) ; 1635 0 100 280 C4857C86
ve_result_flag_store_clear_ram185:     CLRB    off(00185h)            ; 1639 0 100 280 C48515
                RC                             ; 163C 0 100 280 95
                SJ      ve_result_flag_store_store_carry_ram11e_bit3             ; 163D 0 100 280 CB34
ve_result_flag_store_load_ram187:     LB      A, off(00187h)         ; 163F 0 100 280 F487
                SB      off(00121h).2          ; 1641 0 100 280 C4211A
                JNE     ve_result_flag_store_clear_ram184             ; 1644 0 100 280 CE24
                CLR     A                      ; 1646 1 100 280 F9
                LB      A, off(00184h)         ; 1647 0 100 280 F484
                MOV     er0, A                 ; 1649 0 100 280 448A
                LB      A, off(00186h)         ; 164B 0 100 280 F486
                MOV     er1, A                 ; 164D 0 100 280 458A
                LB      A, off(00187h)         ; 164F 0 100 280 F487
                L       A, ACC                 ; 1651 1 100 280 E506
                ADD     A, er0                 ; 1653 1 100 280 08
                SUB     A, er1                 ; 1654 1 100 280 29
                LB      A, ACC                 ; 1655 0 100 280 F506
                J       ve_result_flag_store_if_ge_goto_5914             ; 1657 0 100 280 030E59
ve_result_flag_store_cmp_acch:     CMPB    ACCH, #000h            ; 165A 0 100 280 C507C000
                JEQ     ve_result_flag_store_load_r4             ; 165E 0 100 280 C902
                LB      A, #0ffh               ; 1660 0 100 280 77FF
ve_result_flag_store_load_r4:     MOVB    r4, #006h              ; 1662 0 100 280 9C06
                CMPB    A, r4                  ; 1664 0 100 280 4C
                JLT     ve_result_flag_store_store_ram187             ; 1665 0 100 280 CA01
                LB      A, r4                  ; 1667 0 100 280 7C
ve_result_flag_store_store_ram187:     STB     A, off(00187h)         ; 1668 0 100 280 D487
ve_result_flag_store_clear_ram184:     CLRB    off(00184h)            ; 166A 0 100 280 C48415
                CMPB    off(00185h), A         ; 166D 0 100 280 C485C1
                XORB    PSWH, #080h            ; 1670 0 100 280 A2F080
ve_result_flag_store_store_carry_ram11e_bit3:     MB      off(0011eh).3, C       ; 1673 0 100 280 C41E3B
                MOVB    r0, #00ah              ; 1676 0 100 280 980A
                MOVB    r1, #014h              ; 1678 0 100 280 9914
                MOVB    r2, off(001d3h)        ; 167A 0 100 280 C4D34A
                MOV     X2, off(001d6h)        ; 167D 0 100 280 B4D679
; (skeleton: one VE table for both cams, as HTS - the low-cam table and axis)
                RB      PSWL.5                 ; 1689
ve_table_result_store:     MOVB    r3, off(001d8h)        ; 1694 0 100 280 C4D84B
                MOV     er3, off(001dah)       ; 1697 0 100 280 B4DA4B
                MOV     X1, #ve_table_result_store_tbl          ; 169A 0 100 280 604C74
ve_table_result_store_call_table2d_lookup_interp:     CAL     table2d_lookup_interp             ; 169D 0 100 280 321050
                LB      A, r4                  ; 16A0 0 100 280 7C
                SRLB    A                      ; 16A1 0 100 280 63
                STB     A, r0                  ; 16A2 0 100 280 88
                JBS     off(00127h).6, ve_accel_tps_threshold_check ; 16A9 0 100 280 EE271D
ve_accel_gate1:     JBS     off(00127h).3, ve_accel_gate1_load_ram185 ; 16AC 0 100 280 EB2725
                JBS     off(00127h).1, ve_accel_gate1_load_ram185 ; 16AF 0 100 280 E92722
                JBR     off(00127h).0, ve_accel_gate1_load_imm ; 16B2 0 100 280 D82729
                JBR     off(00116h).1, ve_accel_gate1_load_ram185 ; 16B5 0 100 280 D9161C
                JBS     off(00118h).6, ve_accel_gate1_load_ram185 ; 16B8 0 100 280 EE1819
                JBS     off(00127h).2, ve_accel_gate1_load_ram185 ; 16BB 0 100 280 EA2716
                JBR     off(00128h).4, ve_accel_state_store_clear_ram11d_bit5 ; 16BE 0 100 280 DC282E
                JBS     off(00128h).3, ve_accel_tps_threshold_check ; 16C1 0 100 280 EB2805
                JBR     off(0011eh).3, ve_accel_state_store_clear_ram11d_bit5 ; 16C4 0 100 280 DB1E28
                SJ      ve_accel_reset_flags             ; 16C7 0 100 280 CB36
ve_accel_tps_threshold_check:     LB      A, r0                  ; 16C9 0 100 280 78
                JBS     off(0011eh).3, ve_accel_reset_flags ; 16CA 0 100 280 EB1E32
                LB      A, #080h               ; 16CD 0 100 280 7780
                CAL     sub_clamp_helper             ; 16CF 0 100 280 32A550
                SJ      ve_accel_reset_flags             ; 16D2 0 100 280 CB2B
ve_accel_gate1_load_ram185:     MOVB    off(00185h), #006h     ; 16D4 0 100 280 C4859806
                JBS     off(00128h).3, ve_accel_check_tps_rate ; 16D8 0 100 280 EB2821
                CLRB    A                      ; 16DB 0 100 280 FA
                SJ      ve_accel_state_store             ; 16DC 0 100 280 CB0F
ve_accel_gate1_load_imm:     LB      A, #001h               ; 16DE 0 100 280 7701
                JBR     off(00128h).3, ve_accel_state_store ; 16E0 0 100 280 DB280A
                CMPB    0b4h, #005h            ; 16E3 0 100 280 C5B4C005
                JLT     ve_accel_tps_threshold_check             ; 16E7 0 100 280 CAE0
                LB      A, off(0018fh)         ; 16E9 0 100 280 F48F
                JEQ     ve_accel_tps_threshold_check             ; 16EB 0 100 280 C9DC
ve_accel_state_store:     STB     A, off(0018fh)         ; 16ED 0 100 280 D48F
ve_accel_state_store_clear_ram11d_bit5:     RB      off(0011dh).5          ; 16EF 0 100 280 C41D0D
                RB      off(00123h).6          ; 16F2 0 100 280 C4230E
ve_accel_common:     RB      off(00123h).4          ; 16F5 0 100 280 C4230C
                LB      A, #040h               ; 16F8 0 100 280 7740
                SJ      tpsaccel_result_common_store_ram152             ; 16FA 0 100 280 CB5C
ve_accel_check_tps_rate:     JBS     off(00119h).5, ve_accel_next_stage ; 16FC 0 100 280 ED190C
ve_accel_reset_flags:     CMPB    A, off(0015bh)         ; 16FF 0 100 280 C75B
                JGE     ve_accel_next_stage             ; 1701 0 100 280 CD08
                SB      off(0011dh).5          ; 1703 0 100 280 C41D1D
                CLRB    off(0018fh)            ; 1706 0 100 280 C48F15
                SJ      ve_accel_common             ; 1709 0 100 280 CBEA
ve_accel_next_stage:     MOVB    r0, off(0016dh)        ; 170B 0 100 280 C46D48
                CAL     sub_clamp_helper             ; 170E 0 100 280 32A550
                STB     A, r2                  ; 1711 0 100 280 8A
                LB      A, (00243h-00280h)[USP] ; 1712 0 100 280 F3C3
                CMPB    A, #015h               ; 1714 0 100 280 C615
                JBS     off(00123h).6, tpsaccel_hyst_check ; 1716 0 100 280 EE2307
                JLT     tpsaccel_hyst_check             ; 1719 0 100 280 CA05
                SB      off(00123h).6          ; 171B 0 100 280 C4231E
                SJ      tpsaccel_table_select             ; 171E 0 100 280 CB0A
tpsaccel_hyst_check:     CMPB    A, #00ch               ; 1720 0 100 280 C60C
                JGE     tpsaccel_table_select             ; 1722 0 100 280 CD06
                LB      A, r2                  ; 1724 0 100 280 7A
                RB      off(00123h).6          ; 1725 0 100 280 C4230E
                SJ      tpsaccel_clamp_0xa0             ; 1728 0 100 280 CB13
tpsaccel_table_select:     LB      A, off(0012dh)         ; 172A 0 100 280 F42D
                MOV     X1, #tbl_ve_accel_1          ; 172C 0 100 280 606A61
                JBR     off(0011fh).1, tpsaccel_table_lookup ; 172F 0 100 280 D91F05
                LB      A, 0aah                ; 1732 0 100 280 F5AA
                MOV     X1, #tbl_ve_accel_2          ; 1734 0 100 280 607661
tpsaccel_table_lookup:     VCAL    0                      ; 1737 0 100 280 10
                MOVB    r0, r2                 ; 1738 0 100 280 2248
                CAL     sub_clamp_helper             ; 173A 0 100 280 32A550
tpsaccel_clamp_0xa0:     MOVB    r0, #056h              ; 173D 0 100 280 9856
                CMPB    A, r0                  ; 173F 0 100 280 48
                JLT     to_flag_dispatch_130_1_130_2             ; 1740 0 100 280 CA01
                LB      A, r0                  ; 1742 0 100 280 78
to_flag_dispatch_130_1_130_2:     CMPB    off(00188h), #000h     ; 1743 0 100 280 C488C000
                JNE     tpsaccel_result_common             ; 1747 0 100 280 CE06
                MOVB    r0, #056h              ; 1749 0 100 280 9856
                CMPB    A, r0                  ; 174B 0 100 280 48
                JGE     tpsaccel_result_common             ; 174C 0 100 280 CD01
                LB      A, r0                  ; 174E 0 100 280 78
tpsaccel_result_common:     SB      off(0011dh).5          ; 174F 0 100 280 C41D1D
                SB      off(00123h).4          ; 1752 0 100 280 C4231C
                CLRB    off(0018fh)            ; 1755 0 100 280 C48F15
tpsaccel_result_common_store_ram152:     STB     A, off(00152h)         ; 1758 0 100 280 D452
                JBS     off(00127h).5, tpsaccel_ignitioncut_flag_copy ; 175A 0 100 280 ED2704
                J       tpsaccel_result_common_clear_acc             ; 175D 0 100 280 03CB56
tpsaccel_ignitioncut_flag_copy:     MB      C, off(0011ch).4       ; 1761 0 100 280 C41C2C
                MB      off(00126h).4, C       ; 1764 0 100 280 C4263C
                MOV     X1, #tbl_ignmap2_hi          ; 1767 0 100 280 606363
                JBR     off(0011ch).2, tpsaccel_ignitioncut_flag_copy_load_ram12d ; 176A 0 100 280 DA1C03
                MOV     X1, #tbl_ignmap2_lo          ; 176D 0 100 280 605763
tpsaccel_ignitioncut_flag_copy_load_ram12d:     LB      A, off(0012dh)         ; 1770 0 100 280 F42D
                VCAL    0                      ; 1772 0 100 280 10
                SUBB    A, off(0017ch)         ; 1773 0 100 280 A77C
                J       tpsaccel_ignitioncut_flag_copy_if_ge_goto_5984             ; 1775 0 100 280 038159
tpsaccel_ignitioncut_flag_copy_store_carry_ram126_bit0:     MB      off(00126h).0, C       ; 1779 0 100 280 C42638
                LB      A, off(0017bh)         ; 177C 0 100 280 F47B
                MOVB    r0, #05ah              ; 177E 0 100 280 985A
                JBR     off(0011ch).2, tpsaccel_threshold_pick ; 1780 0 100 280 DA1C04
                LB      A, off(0017ah)         ; 1783 0 100 280 F47A
                MOVB    r0, #047h              ; 1785 0 100 280 9847
tpsaccel_threshold_pick:     JBR     off(0011bh).0, tps_hysteresis_check ; 1787 0 100 280 D81B04
                CMPB    A, r0                  ; 178A 0 100 280 48
                JGE     tps_hysteresis_check             ; 178B 0 100 280 CD01
                LB      A, r0                  ; 178D 0 100 280 78
tps_hysteresis_check:     JBR     off(00117h).6, rpm_threshold_adjust ; 178E 0 100 280 DE1715
                CMPB    0c4h, #082h            ; 1791 0 100 280 C5C4C082
                JBS     off(00126h).7, tps_hysteresis_check_goto_tps_hysteresis_store ; 1795 0 100 280 EF2604
                CMPB    0c4h, #07ah            ; 1798 0 100 280 C5C4C07A
tps_hysteresis_check_goto_tps_hysteresis_store:     J       tps_hysteresis_store             ; 179C 0 100 280 038959
tps_hysteresis_flag2_subb_acc:     SUBB    A, #00ah               ; 17A1 0 100 280 A60A
                JGE     rpm_threshold_adjust             ; 17A3 0 100 280 CD01
                CLRB    A                      ; 17A5 0 100 280 FA
rpm_threshold_adjust:     CMPB    0b4h, #000h            ; 17A6 0 100 280 C5B4C000
                JBR     off(00116h).3, rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold ; 17AA 0 100 280 DB1604
                CMPB    0b4h, #008h            ; 17AD 0 100 280 C5B4C008
rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold:     JLT     rpm_secondary_threshold_check             ; 17B1 0 100 280 CA0C
                JBR     off(00126h).1, rpm_secondary_threshold_check ; 17B3 0 100 280 D92609
                JBS     off(0011ch).2, rpm_secondary_threshold_check ; 17B6 0 100 280 EA1C06
                ADDB    A, #030h               ; 17B9 0 100 280 8630
                JGE     rpm_secondary_threshold_check             ; 17BB 0 100 280 CD02
                LB      A, #0ffh               ; 17BD 0 100 280 77FF
rpm_secondary_threshold_check:     CMPB    A, off(0012dh)         ; 17BF 0 100 280 C72D
                MB      off(00126h).3, C       ; 17C1 0 100 280 C4263B
                LB      A, #073h               ; 17C4 0 100 280 7773
                JBS     off(00126h).2, vss_threshold_226_3 ; 17C6 0 100 280 EA2602
                LB      A, #080h               ; 17C9 0 100 280 7780
vss_threshold_226_3:     CMPB    A, off(0012dh)         ; 17CB 0 100 280 C72D
                MB      off(00126h).2, C       ; 17CD 0 100 280 C4263A
                RB      PSWL.4                 ; 17D0 0 100 280 A30C
                RB      PSWL.5                 ; 17D2 0 100 280 A30D
                RB      off(00123h).7          ; 17D4 0 100 280 C4230F
                MB      C, 099h.3              ; 17DA 0 100 280 C5992B
                JLT     vss_threshold_226_3_if_ram112_bit6_set             ; 17DD 0 100 280 CA06
                LB      A, 0cdh                ; 17DF 0 100 280 F5CD
                CMPB    A, #010h               ; 17E1 0 100 280 C610
                JGE     doubleup_limiter_gate             ; 17E3 0 100 280 CD1E
vss_threshold_226_3_if_ram112_bit6_set:
                MB      C, 098h.2              ; 17E8 0 100 280 C5982A
                JLT     vaccut_rpm_check             ; 17EB 0 100 280 CA0E
                CMPB    0b9h, #02bh            ; 17ED 0 100 280 C5B9C02B
                JGE     doubleup_limiter_gate             ; 17F1 0 100 280 CD10
                MOV     X1, #vss_threshold_226_3_tbl          ; 17F3 0 100 280 60306B
                LB      A, 0b9h                ; 17F6 0 100 280 F5B9
                VCAL    2                      ; 17F8 0 100 280 12
                SJ      vaccut_rpm_check_cmp_acc             ; 17F9 0 100 280 CB02
vaccut_rpm_check:     LB      A, #080h               ; 17FB 0 100 280 7780
vaccut_rpm_check_cmp_acc:     CMPB    A, off(0012dh)         ; 17FD 0 100 280 C72D
                JGE     ofc_enable_check_if_ram126_bit0_set             ; 17FF 0 100 280 CD55
                SJ      revlimiter_fuelcut_set             ; 1801 0 100 280 CB43
doubleup_limiter_gate:     MOV     DP, #00228h            ; 1803 0 100 280 622802
                L       A, #00218h             ; 1806 1 100 280 671802
                MB      C, P4.0                ; 1809 1 100 280 C52C28
                JLT     doubleup_limiter_cont             ; 180C 1 100 280 CA08
                MOV     DP, off(00182h)        ; 1811 1 100 280 B4827A
                L       A, off(00180h)         ; 1814 1 100 280 E480
doubleup_limiter_cont:     JBR     off(0011ch).5, ignition_cut_mode_check ; 1816 1 100 280 DD1C01
                L       A, DP                  ; 1819 1 100 280 42
ignition_cut_mode_check:     CMP     0ach, A                ; 181A 1 100 280 B5ACC1
                MB      off(0011ch).5, C       ; 181D 1 100 280 C41C3D
                JLT     revlimiter_fuelcut_set             ; 1820 1 100 280 CA24
                CMPB    off(001f0h), #000h     ; (skeleton) module fuel-cut request: any bit set cuts fuel like the rev limiter
                JNE     revlimiter_fuelcut_set
                JBS     off(00119h).7, fuelcuttrack_store ; 1822 1 100 280 EF1937
                SJ      fuelcut_extra_gate     ; 1825 (skeleton: no speed limiter)
revlimiter_fuelcut_set:     SB      PSWL.5                 ; 1846 1 100 280 A31D
                SJ      fuelcut_result_common             ; 1848 1 100 280 CB69
fuelcut_extra_gate:     JBS     off(0011ch).2, ofc_enable_check ; 184A 1 100 280 EA1C03
                JBR     off(0011ah).0, ofc_enable_check_if_ram126_bit0_set ; 184D 1 100 280 D81A06
ofc_enable_check:     JBR     off(00118h).2, fuelcut_tps_recheck ; 1850 1 100 280 DA1812
                RB      off(00126h).1          ; 1853 1 100 280 C42609
ofc_enable_check_if_ram126_bit0_set:     JBS     off(00126h).0, fuelcuttrack_store ; 1856 1 100 280 E82603
                JBS     off(00126h).2, fuelcut_tps_recheck_if_ram11c_bit2_set ; 1859 1 100 280 EA2611
fuelcuttrack_store:     LB      A, #014h               ; 185C 0 100 280 7714
                STB     A, off(001a3h)         ; 185E 0 100 280 D4A3
fuelcut_clear_active_flag:     RB      off(0011ch).2          ; 1860 0 100 280 C41C0A
                SJ      fuelcut_output_flags             ; 1863 0 100 280 CB51
fuelcut_tps_recheck:     JBS     off(00126h).3, fuelcut_tps_recheck_if_ram11c_bit2_set ; 1865 1 100 280 EB2605
                SB      off(00126h).1          ; 1868 1 100 280 C42619
                SJ      fuelcuttrack_store             ; 186B 1 100 280 CBEF
fuelcut_tps_recheck_if_ram11c_bit2_set:     JBS     off(0011ch).2, fuelcut_finalize_ign_flag ; 186D 1 100 280 EA1C0F
                J       fuelcut_tps_recheck_load_ram0a9             ; 1870 1 100 280 03A459
to_fuelcut_clear_active_flag:     JGE     fuelcuttrack_store             ; 1874 0 100 280 CDE6
                LB      A, off(001a3h)         ; 1876 0 100 280 F4A3
                JEQ     fuelcut_finalize_ign_flag             ; 1878 0 100 280 C905
                SB      off(00123h).7          ; 187A 0 100 280 C4231F
                SJ      fuelcut_clear_active_flag             ; 187D 0 100 280 CBE1
fuelcut_finalize_ign_flag:     JBR     off(00116h).3, fuelcut_finalize_ign_flag_if_ram126_bit5_set ; 187F 1 100 280 DB1626
                LB      A, 0b4h                ; 1882 0 100 280 F5B4
                CMPB    A, #064h               ; 1884 0 100 280 C664
                JGE     fuelcut_finalize_ign_flag_if_ram126_bit5_set             ; 1886 0 100 280 CD20
                LB      A, 0b5h                ; 1888 0 100 280 F5B5
                SUBB    A, 0b4h                ; 188A 0 100 280 C5B4A2
                JLT     fuelcut_finalize_ign_flag_if_ram111_bit5_set             ; 188D 0 100 280 CA04
                CMPB    A, #004h               ; 188F 0 100 280 C604
                JGE     fuelcut_finalize_ign_flag_set_ram126_bit5             ; 1891 0 100 280 CD12
fuelcut_finalize_ign_flag_if_ram111_bit5_set:     JBS     off(00111h).5, fuelcut_finalize_ign_flag_if_ram126_bit5_set ; 1893 0 100 280 ED1112
                JBS     off(0011bh).7, fuelcut_finalize_ign_flag_if_ram126_bit5_set ; 1896 0 100 280 EF1B0F
                L       A, 0b0h                ; 1899 1 100 280 E5B0
                CMP     A, #00100h             ; 189B 1 100 280 C60001
                JLT     fuelcut_finalize_ign_flag_if_ram126_bit5_set             ; 189E 1 100 280 CA08
                SB      off(00126h).6          ; 18A0 1 100 280 C4261E
                SJ      fuelcut_finalize_ign_flag_if_ram126_bit5_set             ; 18A3 1 100 280 CB03
fuelcut_finalize_ign_flag_set_ram126_bit5:     SB      off(00126h).5          ; 18A5 0 100 280 C4261D
fuelcut_finalize_ign_flag_if_ram126_bit5_set:     JBS     off(00126h).5, fuelcut_clear_active_flag ; 18A8 1 100 280 ED26B5
                JBS     off(00126h).6, fuelcut_clear_active_flag ; 18AB 1 100 280 EE26B2
                JBS     off(00124h).3, fuelcut_clear_active_flag ; 18AE 1 100 280 EB24AF
                SB      PSWL.4                 ; 18B1 1 100 280 A31C
fuelcut_result_common:     SB      off(0011ch).2          ; 18B3 1 100 280 C41C1A
fuelcut_output_flags:     MB      C, PSWL.5              ; 18B6 1 100 280 A32D
                MB      off(0011ch).5, C       ; 18B8 1 100 280 C41C3D
                MB      C, PSWL.4              ; 18BB 1 100 280 A32C
                MB      off(0011ch).4, C       ; 18BD 1 100 280 C41C3C
                RC                             ; 18C0 1 100 280 95
                RB      off(00123h).7          ; 18C1 1 100 280 C4230F
                JBS     off(0011ch).2, fuelcut_output_flags_set_carry ; 18C4 1 100 280 EA1C02
                JEQ     fuelcut_output_flags_store_carry_ram11c_bit3             ; 18C7 1 100 280 C901
fuelcut_output_flags_set_carry:     SC                             ; 18C9 1 100 280 85
fuelcut_output_flags_store_carry_ram11c_bit3:     MB      off(0011ch).3, C       ; 18CA 1 100 280 C41C3B
                J       fuelcut_output_flags_load_ram0c4             ; 18CD 1 100 280 03375A
tps_hysteresis_reentry_load_r2:     MOVB    r2, #00ah              ; 18D0 0 100 280 9A0A
                JBR     off(00119h).7, tps_hysteresis_reentry_if_ram11d_bit4_clr ; 18D2 0 100 280 DF1903
                J       ignmap2_result_check_clear_acc             ; 18D5 0 100 280 034C19
tps_hysteresis_reentry_if_ram11d_bit4_clr:     J       tps_hysteresis_reentry_if_ram124_bit3_set ; (skeleton: 11Dh.4, the VTEC pressure limp flag, is always 0)
tps_hysteresis_reentry_if_ram124_bit3_set:     JBS     off(00124h).3, ignmap2_result_check_clear_acc ; 18E3 0 100 280 EB2466
                JBS     off(0011dh).5, ignmap2_result_check_clear_acc ; 18E6 0 100 280 ED1D63
                JBR     off(0011ah).3, postig_result_default ; 18E9 0 100 280 DB1A3A
                JBR     off(0011ah).0, postig_result_default ; 18EC 0 100 280 D81A37
                J       tps_hysteresis_reentry_if_ram116_bit3_clr             ; 18EF 0 100 280 037878
postig_gate_chain2:     JBS     off(00118h).4, postig_result_default ; 18F2 0 100 280 EC1831
                LB      A, off(001eah)         ; 18F5 0 100 280 F4EA
                MOVB    r0, #045h              ; 18F7 0 100 280 9845
                JBS     off(00123h).5, postig_threshold_check1 ; 18F9 0 100 280 ED2304
                LB      A, off(001ebh)         ; 18FC 0 100 280 F4EB
                MOVB    r0, #05ah              ; 18FE 0 100 280 985A
postig_threshold_check1:     JBR     off(0011bh).0, postig_threshold_check2 ; 1900 0 100 280 D81B04
                CMPB    A, r0                  ; 1903 0 100 280 48
                JGE     postig_threshold_check2             ; 1904 0 100 280 CD01
                LB      A, r0                  ; 1906 0 100 280 78
postig_threshold_check2:     J       postig_threshold_check2_if_ram117_bit6_clr             ; 1907 0 100 280 03495A
postig_rpm_compare_cmp_ram0c1:     CMPB    0c1h, #034h            ; 190B 0 100 280 C5C1C034
                JGE     postig_result_high             ; 190F 0 100 280 CD08
                JBR     off(00116h).3, postig_result_high ; 1911 0 100 280 DB1605
                LB      A, off(001a2h)         ; 1914 0 100 280 F4A2
                STB     A, r2                  ; 1916 0 100 280 8A
                JNE     ignmap2_result_check_clear_acc             ; 1917 0 100 280 CE33
postig_result_high:     LB      A, #0dah               ; 1919 0 100 280 77DA
                JBS     off(00116h).3, to_set_pswl4_flag_b ; 191B 0 100 280 EB1602
                LB      A, #0f3h               ; 191E 0 100 280 77F3
to_set_pswl4_flag_b:     SB      PSWL.5                 ; 1920 0 100 280 A31D
to_set_pswl4_flag_b_set_pswl_bit4:     SB      PSWL.4                 ; 1922 0 100 280 A31C
                SJ      ignmap2_flags_store             ; 1924 0 100 280 CB27
postig_result_default:     LB      A, #080h               ; 1926 0 100 280 7780
                MOV     X1, #tbl_ignmap2_hi          ; 1928 0 100 280 606363
                JBR     off(00123h).5, ignmap2_rpm_gate ; 192B 0 100 280 DD2305
                LB      A, #073h               ; 192E 0 100 280 7773
                MOV     X1, #tbl_ignmap2_lo          ; 1930 0 100 280 605763
ignmap2_rpm_gate:     CMPB    A, off(0012dh)         ; 1933 0 100 280 C72D
                JGE     ignmap2_result_check_clear_acc             ; 1935 0 100 280 CD15
                LB      A, off(0012dh)         ; 1937 0 100 280 F42D
                VCAL    0                      ; 1939 0 100 280 10
                ADDB    A, #002h               ; 193A 0 100 280 8602
                JGE     ignmap2_result_check             ; 193C 0 100 280 CD02
                LB      A, #0ffh               ; 193E 0 100 280 77FF
ignmap2_result_check:     SUBB    A, off(0017ch)         ; 1940 0 100 280 A77C
                JLT     ignmap2_result_check_clear_acc             ; 1942 0 100 280 CA08
                CMPB    A, off(0012ch)         ; 1944 0 100 280 C72C
                JLE     ignmap2_result_check_clear_acc             ; 1946 0 100 280 CF04
                LB      A, #0f3h               ; 1948 0 100 280 77F3
                SJ      to_set_pswl4_flag_b_set_pswl_bit4             ; 194A 0 100 280 CBD6
ignmap2_result_check_clear_acc:     CLRB    A                      ; 194C 0 100 280 FA
ignmap2_flags_store:     STB     A, off(00154h)         ; 194D 0 100 280 D454
                MB      C, PSWL.4              ; 194F 0 100 280 A32C
                MB      off(00123h).5, C       ; 1951 0 100 280 C4233D
                MB      C, PSWL.5              ; 1954 0 100 280 A32D
                MB      off(0011eh).1, C       ; 1956 0 100 280 C41E39
                MOVB    off(001a2h), r2        ; 1959 0 100 280 227CA2
                LB      A, #0d5h               ; 195C 0 100 280 77D5
                JBS     off(00125h).0, ignmap2_flags_store_cmp_acc ; 195E 0 100 280 E82502
                LB      A, #0d8h               ; 1961 0 100 280 77D8
ignmap2_flags_store_cmp_acc:     CMPB    A, off(0012dh)         ; 1963 0 100 280 C72D
                MB      off(00125h).0, C       ; 1965 0 100 280 C42538
                LB      A, #012h               ; 1968 0 100 280 7712
                JBS     off(0011ch).6, knock_window_check ; 196A 0 100 280 EE1C02
                LB      A, #010h               ; 196D 0 100 280 7710
knock_window_check:     CMPB    0adh, A                ; 196F 0 100 280 C5ADC1
                MB      off(0011ch).6, C       ; 1972 0 100 280 C41C3E
                JGE     knock_window_gate_common             ; 1975 0 100 280 CD0E
                RC                             ; 1977 0 100 280 95
                JBS     off(0011dh).5, knock_window_gate_common ; 1978 0 100 280 ED1D0A
                JBS     off(00125h).0, knock_window_gate_common ; 197B 0 100 280 E82507
                JBS     off(00123h).5, knock_window_gate_common ; 197E 0 100 280 ED2304
                JBS     off(0011ch).2, knock_window_gate_common ; 1981 0 100 280 EA1C01
                SC                             ; 1984 0 100 280 85
knock_window_gate_common:     MB      off(0011dh).2, C       ; 1985 0 100 280 C41D3A
                LB      A, #0bah               ; 1988 0 100 280 77BA
                JBS     off(0011dh).3, rpm_gate_final_check ; 198A 0 100 280 EB1D02
                LB      A, #0c0h               ; 198D 0 100 280 77C0
rpm_gate_final_check:     CMPB    A, off(0012dh)         ; 198F 0 100 280 C72D
                MB      off(0011dh).3, C       ; 1991 0 100 280 C41D3B
                JBR     off(00118h).0, o2_closedloop_read_and_select ; 1994 0 100 280 D81804
                MOVB    off(0018eh), #019h     ; 1997 0 100 280 C48E9819
o2_closedloop_read_and_select:     MOVB    r0, #032h      ; 199B (skeleton: no closed-loop O2 - always the open-loop path, O2 correction 1.0)
                J       o2_trim_tps_mode_check_clear_ram16c
o2_trim_tps_mode_check_clear_ram16c:     CLRB    off(0016ch)            ; 1AA9 1 100 280 C46C15
                MOVB    off(0019fh), r0        ; 1AAC 1 100 280 207C9F
o2_trim_default_target:     L       A, #08000h             ; 1AAF 1 100 280 670080
o2_trim_clear_gate1:     RB      off(0011dh).1          ; 1AB2 1 100 280 C41D09
o2_trim_clear_gate0_and_return:     RB      off(0011dh).0          ; 1AB5 1 100 280 C41D08
                J       injtimer_finalize_start             ; 1AB8 1 100 280 03681C
injtimer_finalize_start:     ST      A, off(00148h)         ; 1C68 1 100 280 D448
                J       to_injtimer_sub_common             ; 1C6A 1 100 280 03A25B
to_injtimer_sub_common_load_imm:     LB      A, #040h               ; 1C6F 0 100 280 7740
                JBS     off(00123h).4, to_injtimer_sub_common_store_ram153 ; 1C71 0 100 280 EC2323
                JBS     off(00123h).5, to_injtimer_sub_common_store_ram153 ; 1C74 0 100 280 ED2320
                MOV     X1, #to_injtimer_sub_common_tbl          ; 1C77 0 100 280 602C60
                MOV     X2, #0015ah            ; 1C7A 0 100 280 615A01
                JBR     off(0011dh).0, to_injtimer_sub_common_if_ram116_bit3_set ; 1C7D 0 100 280 D81D06
                ADD     X1, #00004h            ; 1C80 0 100 280 90800400
                INC     X2                     ; 1C84 0 100 280 71
                INC     X2                     ; 1C85 0 100 280 71
to_injtimer_sub_common_if_ram116_bit3_set:     JBS     off(00116h).3, to_injtimer_sub_common_load_tbl_x2 ; 1C86 0 100 280 EB1601
                INC     X1                     ; 1C89 0 100 280 70
to_injtimer_sub_common_load_tbl_x2:     LB      A, 00000h[X2]          ; 1C8A 0 100 280 F10000
                STB     A, r6                  ; 1C8D 0 100 280 8E
                LB      A, 00001h[X2]          ; 1C8E 0 100 280 F10100
                J       to_injtimer_sub_common_store_r7             ; 1C91 0 100 280 03C55B
to_injtimer_sub_common_call_table_interp_lookup_prescan:     CAL     table_interp_lookup_prescan             ; 1C94 0 100 280 324E4E
to_injtimer_sub_common_store_ram153:     STB     A, off(00153h)         ; 1C97 0 100 280 D453
                LB      A, off(0012ch)         ; 1C99 0 100 280 F42C
                MOV     X1, #tbl_injtimer_finalize          ; 1C9B 0 100 280 60CA61
                VCAL    0                      ; 1C9E 0 100 280 10
                MOVB    ACCH, #002h            ; 1C9F 0 100 280 C5079802
                MOVB    r0, off(00156h)        ; 1CA3 0 100 280 C45648
                CLRB    r1                     ; 1CA6 0 100 280 2115
                MUL                            ; 1CA8 0 100 280 9035
                SRL     er1                    ; 1CAA 0 100 280 45E7
                RORB    ACCH                   ; 1CAC 0 100 280 C507C7
                LB      A, r2                  ; 1CAF 0 100 280 7A
                L       A, ACC                 ; 1CB0 1 100 280 E506
                SWAP                           ; 1CB2 1 100 280 83
                ADD     A, #00200h             ; 1CB3 1 100 280 860002
                ST      A, off(0014eh)         ; 1CB6 1 100 280 D44E
                LB      A, #03ah               ; 1CB8 0 100 280 773A
                JBS     off(00125h).6, to_injtimer_sub_common_cmp_acc ; 1CBA 0 100 280 EE2502
                LB      A, #040h               ; 1CBD 0 100 280 7740
to_injtimer_sub_common_cmp_acc:     CMPB    A, off(0012dh)         ; 1CBF 0 100 280 C72D
                MB      off(00125h).6, C       ; 1CC1 0 100 280 C4253E
                LB      A, #01ch               ; 1CC4 0 100 280 771C
                JBS     off(00125h).7, to_injtimer_store_0x166 ; 1CC6 0 100 280 EF2502
                LB      A, #01dh               ; 1CC9 0 100 280 771D
to_injtimer_store_0x166:     CMPB    A, 0b9h                ; 1CCB 0 100 280 C5B9C2
                MB      off(00125h).7, C       ; 1CCE 0 100 280 C4253F
                JBR     off(00119h).1, injtimer_gate_common ; 1CD1 0 100 280 D9191F
                JBS     off(00118h).5, injtimer_gate_common ; 1CD4 0 100 280 ED181C
                CMPB    0c1h, #0e0h            ; 1CD7 0 100 280 C5C1C0E0
                JGE     injtimer_gate_common             ; 1CDB 0 100 280 CD16
                J       to_injtimer_store_0x166_cmp_ram0c1             ; 1CDD 0 100 280 03405B
to_injtimer_store_0x166_if_ram125_bit7_clr:     JBR     off(00125h).7, injtimer_gate_common ; 1CE0 0 100 280 DF2510
                JBR     off(00119h).0, injtimer_gate_common ; 1CE3 0 100 280 D8190D
                JBS     off(00123h).5, injtimer_gate_common ; 1CE6 0 100 280 ED230A
                JBS     off(0011dh).1, injtimer_gate_common ; 1CE9 0 100 280 E91D07
                JBS     off(00125h).2, injtimer_gate_common ; 1CEC 0 100 280 EA2504
                LB      A, #014h               ; 1CEF 0 100 280 7714
                SJ      injtimer_store_0x166             ; 1CF1 0 100 280 CB07
injtimer_gate_common:     LB      A, off(00157h)         ; 1CF3 0 100 280 F457
                SUBB    A, #001h               ; 1CF5 0 100 280 A601
                JGE     injtimer_store_0x166             ; 1CF7 0 100 280 CD01
                CLRB    A                      ; 1CF9 0 100 280 FA
injtimer_store_0x166:     STB     A, off(00157h)         ; 1CFA 0 100 280 D457
                LB      A, off(00152h)         ; 1CFC 0 100 280 F452
                JBS     off(00123h).4, injtimer_store_0x166_store_r1 ; 1CFE 0 100 280 EC2302
                LB      A, off(00153h)         ; 1D01 0 100 280 F453
injtimer_store_0x166_store_r1:     STB     A, r1                  ; 1D03 0 100 280 89
                CLRB    r0                     ; 1D04 0 100 280 2015
                SRL     er0                    ; 1D06 0 100 280 44E7
                LB      A, off(00154h)         ; 1D08 0 100 280 F454
                JEQ     injtimer_store_0x166_load_ram155             ; 1D0A 0 100 280 C907
                STB     A, ACCH                ; 1D0C 0 100 280 D507
                CLRB    A                      ; 1D0E 0 100 280 FA
                MUL                            ; 1D0F 0 100 280 9035
                MOV     er0, er1               ; 1D11 0 100 280 4548
injtimer_store_0x166_load_ram155:     LB      A, off(00155h)         ; 1D13 0 100 280 F455
                JEQ     injtimer_mul_chain1             ; 1D15 0 100 280 C907
                STB     A, ACCH                ; 1D17 0 100 280 D507
                CLRB    A                      ; 1D19 0 100 280 FA
                MUL                            ; 1D1A 0 100 280 9035
                MOV     er0, er1               ; 1D1C 0 100 280 4548
injtimer_mul_chain1:     MOVB    ACCH, #001h            ; 1D1E 0 100 280 C5079801
                LB      A, off(00157h)         ; 1D22 0 100 280 F457
                MUL                            ; 1D24 0 100 280 9035
                MOVB    r1, r2                 ; 1D26 0 100 280 2249
                MOVB    r0, ACCH               ; 1D28 0 100 280 C50748
                L       A, off(00150h)         ; 1D2B 1 100 280 E450
                MUL                            ; 1D2D 1 100 280 9035
                MOV     er0, er1               ; 1D2F 1 100 280 4548
                L       A, off(0014eh)         ; 1D31 1 100 280 E44E
                MUL                            ; 1D33 1 100 280 9035
                SRL     er1                    ; 1D35 1 100 280 45E7
                ROR     A                      ; 1D37 1 100 280 43
                SRL     er1                    ; 1D38 1 100 280 45E7
                ROR     A                      ; 1D3A 1 100 280 43
                MOVB    r1, r2                 ; 1D3B 1 100 280 2249
                MOVB    r0, ACCH               ; 1D3D 1 100 280 C50748
                LB      A, r3                  ; 1D40 0 100 280 7B
                JEQ     injtimer_mul_chain2             ; 1D41 0 100 280 C904
                MOV     er0, #0ffffh           ; 1D43 0 100 280 4498FFFF
injtimer_mul_chain2:     L       A, off(0014ch)         ; 1D47 1 100 280 E44C
                MUL                            ; 1D49 1 100 280 9035
                MOV     er0, er1               ; 1D4B 1 100 280 4548
                NOP                            ; 1D4D 1 100 280 00
                NOP                            ; 1D4E 1 100 280 00
                NOP                            ; 1D4F 1 100 280 00
                JBR     off(0011fh).0, injtimer_mul_final ; 1D50 1 100 280 D81F19
                SLL     A                      ; 1D53 1 100 280 53
                ROL     er0                    ; 1D54 1 100 280 44B7
                JLT     injtimer_mul_clamp             ; 1D56 1 100 280 CA0A
                SLL     A                      ; 1D58 1 100 280 53
                ROL     er0                    ; 1D59 1 100 280 44B7
                JLT     injtimer_mul_clamp             ; 1D5B 1 100 280 CA05
                SLL     A                      ; 1D5D 1 100 280 53
                ROL     er0                    ; 1D5E 1 100 280 44B7
                JGE     injtimer_mul_chain3             ; 1D60 1 100 280 CD04
injtimer_mul_clamp:     MOV     er0, #0ffffh           ; 1D62 1 100 280 4498FFFF
injtimer_mul_chain3:     L       A, off(0014ah)         ; 1D66 1 100 280 E44A
                MUL                            ; 1D68 1 100 280 9035
                MOV     er0, er1               ; 1D6A 1 100 280 4548
injtimer_mul_final:     L       A, off(00148h)         ; 1D6C 1 100 280 E448
                MUL                            ; 1D6E 1 100 280 9035
                MOV     off(00146h), er1       ; 1D70 1 100 280 457C46
                CAL     hook_fuel              ; (skeleton) module slot: final pulse width is the word at 146h
                LB      A, off(0012dh)         ; 1D76 0 100 280 F42D
                CMPB    A, #0c0h               ; 1D78 0 100 280 C6C0
                JGE     dwell_zero_result             ; 1D7A 0 100 280 CD49
                JBS     off(00121h).0, injtimer_mul_final_load_imm ; 1D7C 0 100 280 E82109
                CMPB    0a6h, #04bh            ; 1D7F 0 100 280 C5A6C04B
                JLT     dwell_zero_result             ; 1D83 0 100 280 CA40
                SB      off(00121h).0          ; 1D85 0 100 280 C42118
injtimer_mul_final_load_imm:     LB      A, #004h               ; 1D88 0 100 280 7704
                JBS     off(0011bh).5, dwell_rpm_gate2 ; 1D8A 0 100 280 ED1B08
                LB      A, #004h               ; 1D8D 0 100 280 7704
                CMPB    0e9h, #096h            ; 1D8F 0 100 280 C5E9C096
                JLT     dwell_zero_result             ; 1D93 0 100 280 CA30
dwell_rpm_gate2:     CMPB    off(0012dh), #002h     ; 1D95 0 100 280 C42DC002
                JBS     off(0011bh).5, dwell_rpm_gate3 ; 1D99 0 100 280 ED1B04
                CMPB    off(0012dh), #05ah     ; 1D9C 0 100 280 C42DC05A
dwell_rpm_gate3:     JLT     dwell_zero_result             ; 1DA0 0 100 280 CA23
                CMPB    A, 0a9h                ; 1DA2 0 100 280 C5A9C2
                JGE     dwell_zero_result             ; 1DA5 0 100 280 CD1E
                J       dwell_rpm_gate3_load_r0             ; 1DA7 0 100 280 035D5B
dwell_value_select:     MOVB    r1, #018h              ; 1DAA 0 100 280 9918
                JBS     off(0011bh).5, dwell_clamp_check ; 1DAC 0 100 280 ED1B05
                MOVB    r0, off(00174h)        ; 1DAF 0 100 280 C47448
                MOVB    r1, #010h              ; 1DB2 0 100 280 9910
dwell_clamp_check:     LB      A, 0a9h                ; 1DB4 0 100 280 F5A9
                CMPB    A, r1                  ; 1DB6 0 100 280 49
                JLE     dwell_mul_apply             ; 1DB7 0 100 280 CF01
                LB      A, r1                  ; 1DB9 0 100 280 79
dwell_mul_apply:     MULB                           ; 1DBA 0 100 280 A234
                L       A, ACC                 ; 1DBC 1 100 280 E506
                SRL     A                      ; 1DBE 1 100 280 63
                JBS     off(0011bh).5, dwell_store_result ; 1DBF 1 100 280 ED1B04
                VCAL    7                      ; 1DC2 1 100 280 17
                SJ      dwell_store_result             ; 1DC3 1 100 280 CB01
dwell_zero_result:     CLR     A                      ; 1DC5 1 100 280 F9
dwell_store_result:     ST      A, off(0013eh)         ; 1DC6 1 100 280 D43E
                CLRB    r4                     ; 1DC8 1 100 280 2415
                RC                             ; 1DCA 1 100 280 95
                JBR     off(0011ah).4, rpm_accel_skip ; 1DCE 1 100 280 DC1A6B
                JBS     off(00124h).7, rpm_accel_track_calc ; 1DD1 1 100 280 EF2409
                JBS     off(0011ah).5, rpm_accel_alt_path ; 1DD4 1 100 280 ED1A68
                L       A, (00258h-00280h)[USP] ; 1DD7 1 100 280 E3D8
                CLRB    r5                     ; 1DD9 1 100 280 2515
                SJ      rpm_accel_track_store             ; 1DDB 1 100 280 CB0F
rpm_accel_track_calc:     MOV     er3, off(00130h)       ; 1DDD 1 100 280 B4304B
                MOVB    r5, off(00132h)        ; 1DE0 1 100 280 C4324D
                CLRB    r0                     ; 1DE3 1 100 280 2015
                MOVB    r1, #033h              ; 1DE5 1 100 280 9933
                L       A, 0ach                ; 1DE7 1 100 280 E5AC
                CAL     rpm_accel_track_helper             ; 1DE9 1 100 280 323E4F
rpm_accel_track_store:     ST      A, off(00130h)         ; 1DEC 1 100 280 D430
                MOVB    off(00132h), r5        ; 1DEE 1 100 280 257C32
                CLRB    r4                     ; 1DF1 1 100 280 2415
                SUB     A, 0ach                ; 1DF3 1 100 280 B5ACA2
                MB      off(00124h).6, C       ; 1DF6 1 100 280 C4243E
                JLT     rpm_accel_fault_path             ; 1DF9 1 100 280 CA0A
                JBS     off(0011bh).6, rpm_accel_secondary_calc ; 1DFB 1 100 280 EE1B12
                CMP     0aeh, #0001ah          ; 1DFE 1 100 280 B5AEC01A00
                SJ      rpm_accel_gate_result             ; 1E03 1 100 280 CB09
rpm_accel_fault_path:     VCAL    7                      ; 1E05 1 100 280 17
                JBR     off(0011bh).6, rpm_accel_secondary_calc ; 1E06 1 100 280 DE1B07
                CMP     0aeh, #0001ah          ; 1E09 1 100 280 B5AEC01A00
rpm_accel_gate_result:     JGE     rpm_accel_clamp             ; 1E0E 1 100 280 CD2B
rpm_accel_secondary_calc:     CLRB    r0                     ; 1E10 1 100 280 2015
                MOVB    r1, #020h              ; 1E12 1 100 280 9920
                CMPB    0c1h, #034h            ; 1E14 1 100 280 C5C1C034
                JGE     rpm_accel_mul_apply             ; 1E18 1 100 280 CD0B
                JBS     off(00116h).3, rpm_accel_mul_apply ; 1E1A 1 100 280 EB1608
                CMPB    0b4h, #005h            ; 1E1D 1 100 280 C5B4C005
                JLT     rpm_accel_mul_apply             ; 1E21 1 100 280 CA02
                MOVB    r1, #020h              ; 1E23 1 100 280 9920
rpm_accel_mul_apply:     MUL                            ; 1E25 1 100 280 9035
                MOVB    r4, #032h              ; 1E27 1 100 280 9C32
                SLL     A                      ; 1E29 1 100 280 53
                ROL     er1                    ; 1E2A 1 100 280 45B7
                JLT     rpm_accel_clamp             ; 1E2C 1 100 280 CA0D
                SLL     A                      ; 1E2E 1 100 280 53
                ROL     er1                    ; 1E2F 1 100 280 45B7
                JLT     rpm_accel_clamp             ; 1E31 1 100 280 CA08
                LB      A, r3                  ; 1E33 0 100 280 7B
                JNE     rpm_accel_clamp             ; 1E34 0 100 280 CE05
                LB      A, r2                  ; 1E36 0 100 280 7A
                CMPB    A, r4                  ; 1E37 0 100 280 4C
                JGE     rpm_accel_clamp             ; 1E38 0 100 280 CD01
                STB     A, r4                  ; 1E3A 0 100 280 8C
rpm_accel_clamp:     SC                             ; 1E3B 0 100 280 85
rpm_accel_skip:     MB      off(00124h).7, C       ; 1E3C 1 100 280 C4243F
rpm_accel_alt_path:     LB      A, r4                  ; 1E3F 0 100 280 7C
                JEQ     rpm_accel_store_0x148             ; 1E40 0 100 280 C904
                JBS     off(00124h).6, rpm_accel_store_0x148 ; 1E42 0 100 280 EE2401
                VCAL    7                      ; 1E45 0 100 280 17
rpm_accel_store_0x148:     STB     A, off(00140h)         ; 1E46 0 100 280 D440
                CLR     A                      ; 1E48 1 100 280 F9
                CLRB    r0                     ; 1E49 1 100 280 2015
                JBS     off(0011ch).0, rpm_decel_flags_clear ; 1E4E 1 100 280 E81C56
                MOVB    r0, #004h              ; 1E51 1 100 280 9804
                JBS     off(0011ch).2, rpm_decel_flags_clear ; 1E53 1 100 280 EA1C51
                MOVB    r0, off(0017dh)        ; 1E56 1 100 280 C47D48
                CMPB    r0, #000h              ; 1E59 1 100 280 20C000
                JNE     rpm_decel_table_lookup             ; 1E5C 1 100 280 CE1C
                JBR     off(0011bh).1, rpm_decel_counter_check ; 1E5E 1 100 280 D91B06
                CMPB    0bdh, #008h            ; 1E61 1 100 280 C5BDC008
                JGE     rpm_decel_flags_clear             ; 1E65 1 100 280 CD40
rpm_decel_counter_check:     J       rpm_decel_counter_check_load_r1             ; 1E67 1 100 280 03B059
rpm_decel_counter_check_if_eq_goto_rpm_decel_diff_check2:     JEQ     rpm_decel_diff_check2             ; 1E6A 1 100 280 C903
                DECB    r1                     ; 1E6C 1 100 280 B9
                JNE     rpm_decel_store_0x14a             ; 1E6D 1 100 280 CE42
rpm_decel_diff_check2:     L       A, off(001deh)         ; 1E6F 1 100 280 E4DE
                JEQ     rpm_decel_flags_clear             ; 1E71 1 100 280 C934
                SUB     A, off(001e0h)         ; 1E73 1 100 280 A7E0
                JGE     rpm_decel_flags_clear             ; 1E75 1 100 280 CD30
                CLR     A                      ; 1E77 1 100 280 F9
                SJ      rpm_decel_flags_clear             ; 1E78 1 100 280 CB2D
rpm_decel_table_lookup:     LB      A, off(0012dh)         ; 1E7A 0 100 280 F42D
                MOV     X1, #tbl_rpm_decel          ; 1E7C 0 100 280 60A362
                VCAL    1                      ; 1E7F 0 100 280 11
                ; warning: had to flip DD
                CMP     A, 0b0h                ; 1E80 1 100 280 B5B0C2
                CLR     A                      ; 1E83 1 100 280 F9
                MOVB    r0, off(0017dh)        ; 1E84 1 100 280 C47D48
                DECB    r0                     ; 1E87 1 100 280 B8
                JBS     off(0011bh).7, rpm_decel_store_0x150 ; 1E88 1 100 280 EF1B22
                JGE     rpm_decel_store_0x150             ; 1E8B 1 100 280 CD20
                L       A, #00145h             ; 1E8D 1 100 280 674501
                JBS     off(00126h).5, rpm_decel_mul_final ; 1E90 1 100 280 ED260F
                L       A, #000fah             ; 1E93 1 100 280 67FA00
                JBS     off(00126h).6, rpm_decel_mul_final ; 1E96 1 100 280 EE2609
                L       A, #0004bh             ; 1E99 1 100 280 674B00
                JBR     off(00116h).3, rpm_decel_mul_final ; 1E9C 1 100 280 DB1603
                L       A, #0007dh             ; 1E9F 1 100 280 677D00
rpm_decel_mul_final:     CAL     scale_ram1e4_mul_shr2             ; 1EA2 1 100 280 32B150
                CLRB    r0                     ; 1EA5 1 100 280 2015
rpm_decel_flags_clear:     RB      off(00126h).5          ; 1EA7 1 100 280 C4260D
                RB      off(00126h).6          ; 1EAA 1 100 280 C4260E
rpm_decel_store_0x150:     ST      A, off(001deh)         ; 1EAD 1 100 280 D4DE
                MOVB    r1, #004h              ; 1EAF 1 100 280 9904
rpm_decel_store_0x14a:     ST      A, off(00142h)         ; 1EB1 1 100 280 D442
                MOVB    off(0017dh), r0        ; 1EB3 1 100 280 207C7D
                MOVB    off(0017eh), r1        ; 1EB6 1 100 280 217C7E
                CLR     A                      ; 1EB9 1 100 280 F9
                J       rpm_decel_store_0x14a_cmp_ram12d             ; 1EBA 1 100 280 03D956
rpm_decel_store_0x14a_if_lt_goto_idle_sub_result_store:     JLT     idle_sub_result_store             ; 1EBE 1 100 280 CA13
                L       A, off(001e2h)         ; 1EC0 1 100 280 E4E2
                JEQ     idle_sub_result_store             ; 1EC2 1 100 280 C90F
                CLRB    r0                     ; 1EC4 1 100 280 2015
                MOVB    r1, off(00175h)        ; 1EC6 1 100 280 C47549
                MUL                            ; 1EC9 1 100 280 9035
                SLL     A                      ; 1ECB 1 100 280 53
                L       A, er1                 ; 1ECC 1 100 280 35
                ROL     A                      ; 1ECD 1 100 280 33
                JGE     idle_sub_result_store             ; 1ECE 1 100 280 CD03
                L       A, #0ffffh             ; 1ED0 1 100 280 67FFFF
idle_sub_result_store:     ST      A, off(00176h)         ; 1ED3 1 100 280 D476
                JBR     off(0011ch).4, tipin_time_calc ; 1ED5 1 100 280 DC1C14
                CLR     A                      ; 1ED8 1 100 280 F9
                MOV     X1, A                  ; 1ED9 1 100 280 50
                ST      A, 003ach[X1]          ; 1EDA 1 100 280 D0AC03
                ST      A, 003aeh[X1]          ; 1EDD 1 100 280 D0AE03
                ST      A, 003b0h[X1]          ; 1EE0 1 100 280 D0B003
                ST      A, 003b2h[X1]          ; 1EE3 1 100 280 D0B203
                J       idle_sub_result_store_store_tbl_x1             ; 1EE6 1 100 280 031759
idle_sub_result_store_goto_1fe6:     J       cylinder_ign_correct_apply_goto_5c43             ; 1EE9 1 100 280 03E61F
tipin_time_calc:     L       A, off(0013ah)         ; 1EEC 1 100 280 E43A
                JBR     off(00123h).3, tipin_time_calc_add_acc ; 1EEE 1 100 280 DB230C
                CMPB    0e8h, #004h            ; 1EF1 1 100 280 C5E8C004
                MB      off(00123h).3, C       ; 1EF5 1 100 280 C4233B
                ADD     A, #0007dh             ; 1EF8 1 100 280 867D00
                JLT     tipin_time_clamp             ; 1EFB 1 100 280 CA08
tipin_time_calc_add_acc:     ADD     A, off(0013ch)         ; 1EFD 1 100 280 873C
                JLT     tipin_time_clamp             ; 1EFF 1 100 280 CA04
                ADD     A, off(00142h)         ; 1F01 1 100 280 8742
                JGE     tipin_time_finalize             ; 1F03 1 100 280 CD03
tipin_time_clamp:     L       A, #0ffffh             ; 1F05 1 100 280 67FFFF
tipin_time_finalize:     ST      A, er0                 ; 1F08 1 100 280 88
                LB      A, off(00140h)         ; 1F09 0 100 280 F440
                EXTND                          ; 1F0B 1 100 280 F8
                MOV     er3, off(0013eh)       ; 1F0C 1 100 280 B43E4B
                CAL     add_saturate_s16             ; 1F0F 1 100 280 32934F
                LB      A, off(00141h)         ; 1F12 0 100 280 F441
                EXTND                          ; 1F14 1 100 280 F8
                CAL     add_saturate_s16             ; 1F15 1 100 280 32934F
                CMP     A, #08000h             ; 1F18 1 100 280 C60080
                JGE     tipin_overflow_check1             ; 1F1B 1 100 280 CD05
                ADD     A, er0                 ; 1F1D 1 100 280 08
                JGE     tipin_overflow_check2             ; 1F1E 1 100 280 CD05
                SJ      tipin_overflow_clamp             ; 1F20 1 100 280 CB08
tipin_overflow_check1:     ADD     A, er0                 ; 1F22 1 100 280 08
                JGE     tipin_result_store             ; 1F23 1 100 280 CD08
tipin_overflow_check2:     CMP     A, #08000h             ; 1F25 1 100 280 C60080
                JLT     tipin_result_store             ; 1F28 1 100 280 CA03
tipin_overflow_clamp:     L       A, #07fffh             ; 1F2A 1 100 280 67FF7F
tipin_result_store:     ST      A, er3                 ; 1F2D 1 100 280 8B
                MOV     X2, A                  ; 1F2E 1 100 280 51
                L       A, off(00138h)         ; 1F2F 1 100 280 E438
                MOV     er0, off(00146h)       ; 1F31 1 100 280 B44648
                MUL                            ; 1F34 1 100 280 9035
                SRL     er1                    ; 1F36 1 100 280 45E7
                ROR     A                      ; 1F38 1 100 280 43
                LB      A, r2                  ; 1F39 0 100 280 7A
                L       A, ACC                 ; 1F3A 1 100 280 E506
                SWAP                           ; 1F3C 1 100 280 83
                CMPB    r3, #000h              ; 1F3D 1 100 280 23C000
                JEQ     injtimer_bank_a_calc             ; 1F40 1 100 280 C903
                L       A, #0ffffh             ; 1F42 1 100 280 67FFFF
injtimer_bank_a_calc:     ST      A, er2                 ; 1F45 1 100 280 8A
                XCHG    A, er3                 ; 1F46 1 100 280 4710
                VCAL    5                      ; 1F48 1 100 280 15
                J       injtimer_bank_a_calc_if_ram11c_bit5_clr             ; 1F49 1 100 280 032059
injtimer_bank_a_store_load_er0:     MOV     er0, [DP]              ; 1F4C 1 100 280 B248
                ST      A, [DP]                ; 1F4E 1 100 280 D2
                JBS     off(00126h).4, injtimer_bank_b_zero ; 1F52 1 100 280 EC2615
                CMPB    off(0012dh), #0a0h     ; 1F55 1 100 280 C42DC0A0
                JGE     injtimer_bank_b_zero             ; 1F59 1 100 280 CD0F
                CMP     off(00142h), #00000h   ; 1F5B 1 100 280 B442C00000
                JNE     injtimer_bank_b_zero             ; 1F60 1 100 280 CE08
                SUB     A, er0                 ; 1F62 1 100 280 28
                JLT     injtimer_bank_b_zero             ; 1F63 1 100 280 CA05
                CMP     A, #000fah             ; 1F65 1 100 280 C6FA00
                JGE     injtimer_bank_b_clamp             ; 1F68 1 100 280 CD03
injtimer_bank_b_zero:     CLR     A                      ; 1F6A 1 100 280 F9
                SJ      injtimer_bank_b_store             ; 1F6B 1 100 280 CB17
injtimer_bank_b_clamp:     MOV     er0, #007d0h           ; 1F6D 1 100 280 4498D007
                CMP     A, er0                 ; 1F71 1 100 280 48
                JGE     injtimer_bank_b_default             ; 1F72 1 100 280 CD01
                ST      A, er0                 ; 1F74 1 100 280 88
injtimer_bank_b_default:     CLR     A                      ; 1F75 1 100 280 F9
                MOVB    ACCH, #080h            ; 1F76 1 100 280 C5079880
                MUL                            ; 1F7A 1 100 280 9035
                SLL     A                      ; 1F7C 1 100 280 53
                L       A, er1                 ; 1F7D 1 100 280 35
                ROL     A                      ; 1F7E 1 100 280 33
                JGE     injtimer_bank_b_store             ; 1F7F 1 100 280 CD03
                L       A, #0ffffh             ; 1F81 1 100 280 67FFFF
injtimer_bank_b_store:     ST      A, off(00178h)         ; 1F84 1 100 280 D478
                L       A, off(00142h)         ; 1F86 1 100 280 E442
                CMP     A, off(00176h)         ; 1F88 1 100 280 C776
                JGE     injtimer_bank_b_store_cmp_acc             ; 1F8A 1 100 280 CD02
                L       A, off(00176h)         ; 1F8C 1 100 280 E476
injtimer_bank_b_store_cmp_acc:     CMP     A, off(00178h)         ; 1F8E 1 100 280 C778
                MB      off(00123h).2, C       ; 1F90 1 100 280 C4233A
                JGE     injtimer_bank_c_check             ; 1F93 1 100 280 CD02
                L       A, off(00178h)         ; 1F95 1 100 280 E478
injtimer_bank_c_check:     L       A, ACC                 ; 1F97 1 100 280 E506
                JEQ     injtimer_bank_c_store             ; 1F99 1 100 280 C90A
                ADD     A, off(0013ch)         ; 1F9B 1 100 280 873C
                JGE     injtimer_bank_c_scale             ; 1F9D 1 100 280 CD03
                L       A, #0ffffh             ; 1F9F 1 100 280 67FFFF
injtimer_bank_c_scale:     CAL     scale_mul5_div4             ; 1FA2 1 100 280 32B94F
injtimer_bank_c_store:     MOV     X1, A                  ; 1FA5 1 100 280 50
                JBR     off(00123h).2, injtimer_critsection_start ; 1FA6 1 100 280 DA2301
                CLR     A                      ; 1FA9 1 100 280 F9
injtimer_critsection_start:     AND     IE, #002a0h            ; 1FAA 1 100 280 B51AD0A002
; [H] --- Per-cylinder injector timer write (critical section, interrupts masked via IE/PSWH):
; [H] cylinder_ign_correct_loop applies CylinderIGNCorrect (real per-cylinder ignition-correction
; [H] calibration table) and a mul5/div4 scale to each cylinder's computed value, writing results
; [H] to the injector timer-compare registers up through 0x3C0 -- this is the routine referenced
; [H] back in ign_angle_to_timer_convert's comment as "programming the two ignition coil-channel
; [H] hardware timers" (the same critical-section pattern, here for injector-side output).
                RB      PSWH.0                 ; 1FAF 1 100 280 A208
                MOV     off(001c4h), X1        ; 1FB1 1 100 280 907CC4
                ST      A, off(001c0h)         ; 1FB4 1 100 280 D4C0
                ST      A, off(001c2h)         ; 1FB6 1 100 280 D4C2
                SB      PSWH.0                 ; 1FB8 1 100 280 A218
                L       A, 0f2h                ; 1FBA 1 100 280 E5F2
                ST      A, IE                  ; 1FBC 1 100 280 D51A
                MOV     X1, #CylinderIGNCorrect          ; 1FBE 1 100 280 60BA61
cylinder_ign_correct_loop:     INC     DP                     ; 1FC1 1 100 280 72
                INC     DP                     ; 1FC2 1 100 280 72
                L       A, er2                 ; 1FC3 1 100 280 36
                JBR     off(0011dh).1, cylinder_ign_correct_apply ; 1FC4 1 100 280 D91D0F
                ST      A, er0                 ; 1FC7 1 100 280 88
                CLR     A                      ; 1FC8 1 100 280 F9
                LCB     A, [X1]                ; 1FC9 1 100 280 90AA
                SWAP                           ; 1FCB 1 100 280 83
                MUL                            ; 1FCC 1 100 280 9035
                SLL     A                      ; 1FCE 1 100 280 53
                L       A, er1                 ; 1FCF 1 100 280 35
                ROL     A                      ; 1FD0 1 100 280 33
                JGE     cylinder_ign_correct_apply             ; 1FD1 1 100 280 CD03
                L       A, #0ffffh             ; 1FD3 1 100 280 67FFFF
cylinder_ign_correct_apply:     MOV     er3, X2                ; 1FD6 1 100 280 914B
                XCHG    A, er3                 ; 1FD8 1 100 280 4710
                VCAL    5                      ; 1FDA 1 100 280 15
                CAL     scale_mul5_div4             ; 1FDB 1 100 280 32B94F
                ST      A, [DP]                ; 1FDE 1 100 280 D2
                INC     X1                     ; 1FDF 1 100 280 70
                CMP     DP, #003b4h            ; 1FE0 1 100 280 92C0B403
                JLT     cylinder_ign_correct_loop             ; 1FE4 1 100 280 CADB
cylinder_ign_correct_apply_goto_5c43:     J       cylinder_ign_correct_apply_load_imm_2             ; 1FE6 1 100 280 03435C
cylinder_ign_correct_apply_load_imm:     LB      A, #005h               ; 1FEA 0 100 280 7705
                MOVB    r6, #007h              ; 1FEF 0 100 280 9E07
                CLR     A                      ; 1FF1 (skeleton: fault flags are always clear)
                MOVB    r6, #006h              ; 1FF8 1 100 280 9E06
                JBS     off(00117h).5, to_gio_mode_dispatch ; 1FFA 1 100 280 ED1753
                MOVB    r6, #006h              ; 1FFD 1 100 280 9E06
                JBS     off(00123h).2, to_gio_mode_dispatch ; 1FFF 1 100 280 EA234E
                CMPB    0c1h, #02eh            ; 2002 1 100 280 C5C1C02E
                JGE     deadtime_ect_offset             ; 2006 1 100 280 CD05
                MOVB    r6, #007h              ; 2008 1 100 280 9E07
                JBS     off(00118h).0, to_gio_mode_dispatch ; 200A 1 100 280 E81843
deadtime_ect_offset:     CLR     DP                     ; 200D 1 100 280 9215
                LB      A, 0c1h                ; 200F 0 100 280 F5C1
                CMPB    A, #0aeh               ; 2011 0 100 280 C6AE
                JGE     deadtime_ect_offset_load_imm             ; 2013 0 100 280 CD04
                ADD     DP, #00003h            ; 2015 0 100 280 92800300
deadtime_ect_offset_load_imm:     LB      A, #038h               ; 2019 0 100 280 7738
                JBS     off(00123h).1, deadtime_ect_offset_cmp_ram0a6 ; 201B 0 100 280 E92302
                LB      A, #030h               ; 201E 0 100 280 7730
deadtime_ect_offset_cmp_ram0a6:     CMPB    0a6h, A                ; 2020 0 100 280 C5A6C1
                MB      off(00123h).1, C       ; 2023 0 100 280 C42339
                LB      A, #077h               ; 2026 0 100 280 7777
                JBS     off(00123h).0, deadtime_voltage_flag_store ; 2028 0 100 280 E82302
                LB      A, #070h               ; 202B 0 100 280 7770
deadtime_voltage_flag_store:     CMPB    0a6h, A                ; 202D 0 100 280 C5A6C1
                MB      off(00123h).0, C       ; 2030 0 100 280 C42338
                JGE     deadtime_voltage_flag_store_rom_load_tbl_601c_dp             ; 2033 0 100 280 CD05
                INC     DP                     ; 2035 0 100 280 72
                JBR     off(00123h).1, deadtime_voltage_flag_store_rom_load_tbl_601c_dp ; 2036 0 100 280 D92301
                INC     DP                     ; 2039 0 100 280 72
deadtime_voltage_flag_store_rom_load_tbl_601c_dp:     LCB     A, deadtime_voltage_flag_store_tbl[DP]        ; 203A 0 100 280 92AB1C60
                STB     A, r6                  ; 203E 0 100 280 8E
                SJ      to_gio_mode_dispatch             ; 203F 0 100 280 CB0F
deadtime_retry_check:     MB      C, 09fh.0              ; 2041 0 100 280 C59F28
                JGE     deadtime_retry_store             ; 2044 0 100 280 CD02
                LB      A, #005h               ; 2046 0 100 280 7705
deadtime_retry_store:     SUBB    A, #001h               ; 2048 0 100 280 A601
                STB     A, off(00135h)         ; 204A 0 100 280 D435
                LB      A, #00bh               ; 204C 0 100 280 770B
deadtime_retry_store_goto_injector_effective_pw_store:     SJ      injector_effective_pw_store             ; 204E 0 100 280 CB1D
to_gio_mode_dispatch:     MOV     DP, #003ach            ; 2050 1 100 280 62AC03
                L       A, [DP]                ; 2053 1 100 280 E2
                CAL     scale_mul5_div4             ; 2054 1 100 280 32B94F
                CLR     er0                    ; 2057 1 100 280 4415
                MOV     er2, off(0012eh)       ; 2059 1 100 280 B42E4A
                DIV                            ; 205C 1 100 280 9037
                JLT     injector_effective_pw_skip             ; 205E 1 100 280 CA0C
                CMP     A, #0000bh             ; 2060 1 100 280 C60B00
                JGT     injector_effective_pw_skip             ; 2063 1 100 280 C807
                LB      A, ACC                 ; 2065 0 100 280 F506
                XCHGB   A, r6                  ; 2067 0 100 280 2610
                J       to_gio_mode_dispatch_subb_acc             ; 2069 0 100 280 03595C
injector_effective_pw_skip:     CLRB    A                      ; 206C 0 100 280 FA
injector_effective_pw_store:     STB     A, off(00133h)         ; 206D 0 100 280 D433
                LB      A, #0c2h               ; 206F 0 100 280 77C2
                JBS     off(0011ch).0, rpm_hyst_flag_124_0 ; 2071 0 100 280 E81C02
                LB      A, #0c5h               ; 2074 0 100 280 77C5
rpm_hyst_flag_124_0:     CMPB    A, off(0012dh)         ; 2076 0 100 280 C72D
                MB      off(0011ch).0, C       ; 2078 0 100 280 C41C38
                LB      A, #0edh               ; 207B 0 100 280 77ED
                JBS     off(0011ch).1, rpm_hyst_flag_124_1 ; 207D 0 100 280 E91C02
                LB      A, #0f0h               ; 2080 0 100 280 77F0
rpm_hyst_flag_124_1:     CMPB    A, off(0012dh)         ; 2082 0 100 280 C72D
                MB      off(0011ch).1, C       ; 2084 0 100 280 C41C39
                JBR     off(00119h).1, crank_edge_carry_clear ; 2087 0 100 280 D9193D
                JBR     off(00116h).6, crank_edge_carry_clear ; 208A 0 100 280 DE163A
                LB      A, off(00194h)         ; 208D 0 100 280 F494
                JNE     crank_edge_carry_clear             ; 208F 0 100 280 CE36
                JBR     off(00119h).3, crank_edge_carry_clear ; 2091 0 100 280 DB1933
                MOV     DP, #00f00h            ; 2094 0 100 280 62000F
                LB      A, [DP]                ; 2097 0 100 280 F2
                ANDB    A, #040h               ; 2098 0 100 280 D640
                MB      C, 0a0h.5              ; 209A 0 100 280 C5A02D
                JLT     crank_edge_sync_check             ; 209D 0 100 280 CA1A
                JNE     crank_edge_carry_set             ; 209F 0 100 280 CE29
                RB      P1.2                   ; 20A1 0 100 280 C5220A
                AND     IE, #002a0h            ; 20A4 0 100 280 B51AD0A002
                RB      PSWH.0                 ; 20A9 0 100 280 A208
                LB      A, P1                  ; 20AB 0 100 280 F522
                MOV     DP, #02f00h            ; 20AD 0 100 280 62002F
                STB     A, [DP]                ; 20B0 0 100 280 D2
                SB      PSWH.0                 ; 20B1 0 100 280 A218
                L       A, 0f2h                ; 20B3 1 100 280 E5F2
                ST      A, IE                  ; 20B5 1 100 280 D51A
                SJ      crank_edge_direction_toggle             ; 20B7 1 100 280 CB02
crank_edge_sync_check:     JEQ     crank_edge_carry_set             ; 20B9 0 100 280 C90F
crank_edge_direction_toggle:     XORB    PSWH, #080h            ; 20BB 0 100 280 A2F080
                MB      0a0h.5, C              ; 20BE 0 100 280 C5A03D
                JGE     crank_edge_carry_clear             ; 20C1 0 100 280 CD04
                MOVB    off(00194h), #019h     ; 20C3 0 100 280 C4949819
crank_edge_carry_clear:     RC                             ; 20C7 0 100 280 95
                SJ      dtc27_code27_latch             ; 20C8 0 100 280 CB01
crank_edge_carry_set:     SC                             ; 20CA 0 100 280 85
dtc27_code27_latch:     RB      09bh.2                 ; 20CB 0 100 280 C59B3A
                JBR     off(00116h).7, crank_edge_flag_store_clear_acc ; 20CE 0 100 280 DF1677
                JBR     off(00116h).3, crank_edge_flag_store_clear_acc ; 20D1 0 100 280 DB1674
                LB      A, #001h               ; 20D4 0 100 280 7701
                JBS     off(00129h).0, crank_edge_flag_store_cmp_ram0c1 ; 20D6 0 100 280 E82902
                LB      A, #000h               ; 20D9 0 100 280 7700
crank_edge_flag_store_cmp_ram0c1:     CMPB    0c1h, A                ; 20DB 0 100 280 C5C1C1
                MB      off(00129h).0, C       ; 20DE 0 100 280 C42938
                LB      A, #0ffh               ; 20E1 0 100 280 77FF
                JBS     off(00129h).1, crank_edge_flag_store_cmp_acc ; 20E3 0 100 280 E92902
                LB      A, #0ffh               ; 20E6 0 100 280 77FF
crank_edge_flag_store_cmp_acc:     CMPB    A, off(0012ch)         ; 20E8 0 100 280 C72C
                MB      off(00129h).1, C       ; 20EA 0 100 280 C42939
                LB      A, #0ffh               ; 20ED 0 100 280 77FF
                JBS     off(00129h).2, crank_edge_flag_store_cmp_ram0a6 ; 20EF 0 100 280 EA2902
                LB      A, #0ffh               ; 20F2 0 100 280 77FF
crank_edge_flag_store_cmp_ram0a6:     CMPB    0a6h, A                ; 20F4 0 100 280 C5A6C1
                MB      off(00129h).2, C       ; 20F7 0 100 280 C4293A
                LB      A, #000h               ; 20FA 0 100 280 7700
                JBS     off(0011ch).7, crank_edge_flag_store_cmp_acc_2 ; 20FC 0 100 280 EF1C02
                LB      A, #001h               ; 20FF 0 100 280 7701
crank_edge_flag_store_cmp_acc_2:     CMPB    A, off(0012dh)         ; 2101 0 100 280 C72D
                MB      off(0011ch).7, C       ; 2103 0 100 280 C41C3F
                MOV     DP, #0039bh            ; 2106 0 100 280 629B03
                LB      A, [DP]                ; 2109 0 100 280 F2
                CMPB    A, #032h               ; 210A 0 100 280 C632
                JNE     crank_edge_flag_store_if_ram11c_bit7_set             ; 210C 0 100 280 CE08
                MOV     X1, #crank_edge_flag_store_tbl          ; 210E 0 100 280 600B64
                LB      A, off(0012dh)         ; 2111 0 100 280 F42D
                VCAL    0                      ; 2113 0 100 280 10
                SJ      crank_edge_flag_store_clear_carry             ; 2114 0 100 280 CB33
crank_edge_flag_store_if_ram11c_bit7_set:     JBS     off(0011ch).7, crank_edge_flag_store_clear_acc ; 2116 0 100 280 EF1C2F
                JBS     off(00117h).5, crank_edge_flag_store_clear_acc ; 2119 0 100 280 ED172C
                CLR     A                      ; 211C (skeleton: fault flags are always clear)
                J       crank_edge_flag_store_if_ram11c_bit2_set ; (skeleton: fault flags are always clear)
crank_edge_flag_store_if_ram11c_bit2_set:     JBS     off(0011ch).2, crank_edge_flag_store_clear_acc ; 2133 0 100 280 EA1C12
                JBS     off(0011dh).5, crank_edge_flag_store_clear_acc ; 2136 0 100 280 ED1D0F
                JBR     off(00118h).2, crank_edge_flag_store_clear_acc ; 2139 0 100 280 DA180C
                JBS     off(0011dh).1, crank_edge_flag_store_if_ram129_bit0_clr ; 2145 0 100 280 E91D07
crank_edge_flag_store_clear_acc:     CLRB    A                      ; 2148 0 100 280 FA
crank_edge_flag_store_clear_carry:     RC                             ; 2149 0 100 280 95
                SJ      crank_edge_flag_store_store_carry_ram11d_bit7             ; 214A 0 100 280 CB68
crank_edge_flag_store_if_ram129_bit0_clr:     JBR     off(00129h).0, crank_edge_flag_store_clear_acc ; 214F 0 100 280 D829F6
                JBR     off(00129h).1, crank_edge_flag_store_clear_acc ; 2152 0 100 280 D929F3
                JBS     off(00129h).2, crank_edge_flag_store_clear_acc ; 2155 0 100 280 EA29F0
                MOVB    r3, off(001d8h)        ; 2158 0 100 280 C4D84B
                MOV     er3, off(001dah)       ; 215B 0 100 280 B4DA4B
                MOV     X1, #crank_edge_flag_store_tbl_3          ; 215E 0 100 280 60DC75
                LB      A, #000h               ; 2161 0 100 280 7700
                CMPB    A, r3                  ; 2163 0 100 280 4B
                JGT     crank_edge_flag_store_clear_acc             ; 2164 0 100 280 C8E2
                ADDB    A, #00ah               ; 2166 0 100 280 860A
                CMPB    A, r3                  ; 2168 0 100 280 4B
                JLE     crank_edge_flag_store_clear_acc             ; 2169 0 100 280 CFDD
                SUBB    r3, #000h              ; 216B 0 100 280 23A000
                MOVB    r0, #00ah              ; 216E 0 100 280 980A
                MOVB    r1, #00bh              ; 2170 0 100 280 990B
                MOVB    r2, off(001d3h)        ; 2172 0 100 280 C4D34A
                MOV     X2, off(001d6h)        ; 2175 0 100 280 B4D679
                RB      PSWL.5                 ; 2178 0 100 280 A30D
                CAL     table2d_lookup_interp             ; 217A 0 100 280 321050
                LB      A, (002f1h-00280h)[USP] ; 217D 0 100 280 F371
                MB      C, ACC.7               ; 217F 0 100 280 C5062F
                JGE     crank_edge_flag_store_addb_acc             ; 2182 0 100 280 CD06
                ADDB    A, r4                  ; 2184 0 100 280 0C
                JLT     crank_edge_flag_store_store_r1             ; 2185 0 100 280 CA08
                CLRB    A                      ; 2187 0 100 280 FA
                SJ      crank_edge_flag_store_store_r1             ; 2188 0 100 280 CB05
crank_edge_flag_store_addb_acc:     ADDB    A, r4                  ; 218A 0 100 280 0C
                JGE     crank_edge_flag_store_store_r1             ; 218B 0 100 280 CD02
                LB      A, #0ffh               ; 218D 0 100 280 77FF
crank_edge_flag_store_store_r1:     STB     A, r1                  ; 218F 0 100 280 89
                MOVB    r0, #004h              ; 2190 0 100 280 9804
                MOVB    ACCH, #004h            ; 2192 0 100 280 C5079804
                MOV     DP, #003c4h            ; 2196 0 100 280 62C403
                LB      A, [DP]                ; 2199 0 100 280 F2
                ADDB    A, #01fh               ; 219A 0 100 280 861F
                JLT     crank_edge_flag_store_load_acch             ; 219C 0 100 280 CA02
                MULB                           ; 219E 0 100 280 A234
crank_edge_flag_store_load_acch:     LB      A, ACCH                ; 21A0 0 100 280 F507
                EXTND                          ; 21A2 1 100 280 F8
                LCB     A, crank_edge_flag_store_tbl_2[ACC]       ; 21A3 1 100 280 B506AB1764
                MOVB    r0, r1                 ; 21A8 1 100 280 2148
                MULB                           ; 21AA 1 100 280 A234
                SLL     A                      ; 21AC 1 100 280 53
                LB      A, ACCH                ; 21AD 0 100 280 F507
                JGE     crank_edge_flag_store_set_carry             ; 21AF 0 100 280 CD02
                LB      A, #0ffh               ; 21B1 0 100 280 77FF
crank_edge_flag_store_set_carry:     SC                             ; 21B3 0 100 280 85
crank_edge_flag_store_store_carry_ram11d_bit7:     MB      off(0011dh).7, C       ; 21B4 0 100 280 C41D3F
                STB     A, (002f3h-00280h)[USP] ; 21B7 0 100 280 D373
                CAL     crank_edge_helper             ; 21B9 0 100 280 325952
                SB      09eh.4                 ; 21BC 0 100 280 C59E1C
                L       A, 0f4h                ; 21BF 1 100 280 E5F4
                ST      A, IE                  ; 21C1 1 100 280 D51A
                RB      PSWH.0                 ; 21C3 1 100 280 A208
                NOP                            ; 21C5 1 100 280 00
                NOP                            ; 21C6 1 100 280 00
                NOP                            ; 21C7 1 100 280 00
                J       int1_rti_epilogue             ; 21C8 1 100 280 038006
; [flow] int_spurious_irq_trap: every interrupt vector this ROM never enables points here. It stamps trap
;    reason 045h and goes through fault_retry_check (retry budget, then BRK -> int_break re-init).
int_spurious_irq_trap:  MOVB    0ebh, #045h            ; 21CB 0 ??? ??? C5EB9845
                SJ      fault_retry_check             ; 21CF 0 ??? ??? CB04
int_WDT:        MOVB    0ebh, #044h            ; 21D1 0 ??? ??? C5EB9844
fault_retry_check:     LB      A, 0ech                ; 21D5 0 ??? ??? F5EC
                JEQ     fault_giveup_latch             ; 21D7 0 ??? ??? C905
                DECB    0ech                   ; 21D9 0 ??? ??? C5EC17
                JNE     fault_trigger_brk             ; 21DC 0 ??? ??? CE03
fault_giveup_latch:     SB      09fh.1                 ; 21DE 0 ??? ??? C59F19
fault_trigger_brk:     BRK                            ; 21E1 0 ??? ??? FF
int_start:      MOVB    0ebh, #046h            ; 21E2 0 ??? ??? C5EB9846
                RB      09fh.1                 ; 21E6 0 ??? ??? C59F09
int_break:      MOVB    WDT, #03ch             ; 21E9 0 ??? ??? C511983C
                MOV     SSP, #0047eh           ; 21ED 0 ??? ??? A0987E04
                MOV     LRB, #00010h           ; 21F1 0 080 ??? 571000
                CLR     off(PSW)               ; 21F4 0 080 ??? B40415
                LB      A, off(000ebh)         ; 21F7 0 080 ??? F4EB
                STB     A, off(000e7h)         ; 21F9 0 080 ??? D4E7
                JNE     breset_check_reason_46_47             ; 21FB 0 080 ??? CE06
                MOVB    off(000ebh), #04eh     ; 21FD 0 080 ??? C4EB984E
                SJ      fault_retry_check             ; 2201 0 080 ??? CBD2
breset_check_reason_46_47:     CMPB    A, #046h               ; 2203 0 080 ??? C646
                JEQ     breset_reason_46_or_47_common             ; 2205 0 080 ??? C904
                CMPB    A, #047h               ; 2207 0 080 ??? C647
                JNE     breset_check_p4_1             ; 2209 0 080 ??? CE12
breset_reason_46_or_47_common:     CLRB    off(000e7h)            ; 220B 0 080 ??? C4E715
                MOV     DP, #04700h            ; 220E 0 080 ??? 620047
                LB      A, [DP]                ; 2211 0 080 ??? F2
                SRLB    A                      ; 2212 0 080 ??? 63
                MB      off(0009fh).0, C       ; 2213 0 080 ??? C49F38
                JBS     off(0009fh).1, breset_check_p4_1 ; 2216 0 080 ??? E99F04
                MOVB    off(000ech), #020h     ; 2219 0 080 ??? C4EC9820
breset_check_p4_1:     JBR     off(P4).1, selftest_reg_stuckbit_check  ; 221D 0 080 ??? D92C03
                J       int_NMI                ; 2220 0 080 ??? 033C00
selftest_reg_stuckbit_check:     L       A, #05555h             ; 2223 1 080 ??? 675555
                XCHG    A, SSP                 ; 2226 1 080 ??? A010
                XCHG    A, SSP                 ; 2228 1 080 ??? A010
                CMP     A, #05555h             ; 222A 1 080 ??? C65555
                JNE     selftest_fail_041             ; 222D 1 080 ??? CE5E
                ST      A, IE                  ; 222F 1 080 ??? D51A
                CMP     A, IE                  ; 2231 1 080 ??? B51AC2
                JNE     selftest_fail_041             ; 2234 1 080 ??? CE57
                L       A, #01555h             ; 2236 1 080 ??? 675515
                MOV     LRB, A                 ; 2239 1 080 ??? A48A
                CMP     A, LRB                 ; 223B 1 080 ??? A4C2
                JNE     selftest_fail_041             ; 223D 1 080 ??? CE4E
                L       A, #0aaaah             ; 223F 1 080 ??? 67AAAA
                XCHG    A, SSP                 ; 2242 1 080 ??? A010
                XCHG    A, SSP                 ; 2244 1 080 ??? A010
                CMP     A, #0aaaah             ; 2246 1 080 ??? C6AAAA
                JNE     selftest_fail_041             ; 2249 1 080 ??? CE42
                ST      A, IE                  ; 224B 1 080 ??? D51A
                CMP     A, IE                  ; 224D 1 080 ??? B51AC2
                JNE     selftest_fail_041             ; 2250 1 080 ??? CE3B
                L       A, #00aaah             ; 2252 1 080 ??? 67AA0A
                MOV     LRB, A                 ; 2255 1 080 ??? A48A
                CMP     A, LRB                 ; 2257 1 080 ??? A4C2
                JNE     selftest_fail_041             ; 2259 1 080 ??? CE32
                CLR     A                      ; 225B 1 080 ??? F9
                ST      A, IE                  ; 225C 1 080 ??? D51A
                ST      A, 0f2h                ; 225E 1 080 ??? D5F2
                ST      A, 0f4h                ; 2260 1 080 ??? D5F4
                MOV     LRB, #00010h           ; 2262 1 080 ??? 571000
                LB      A, #055h               ; 2265 0 080 ??? 7755
                XCHGB   A, PSWL                ; 2267 0 080 ??? A310
                XCHGB   A, PSWL                ; 2269 0 080 ??? A310
                CMPB    A, #0ddh               ; 226B 0 080 ??? C6DD
                JNE     selftest_fail_041             ; 226D 0 080 ??? CE1E
                LB      A, #0aah               ; 226F 0 080 ??? 77AA
                XCHGB   A, PSWL                ; 2271 0 080 ??? A310
                XCHGB   A, PSWL                ; 2273 0 080 ??? A310
                CMPB    A, #0eah               ; 2275 0 080 ??? C6EA
                JNE     selftest_fail_041             ; 2277 0 080 ??? CE14
                SB      PSWH.0                 ; 2279 0 080 ??? A218
                MB      C, PSWH.0              ; 227B 0 080 ??? A228
                MB      PSWH.6, C              ; 227D 0 080 ??? A23E
                JGE     selftest_fail_041             ; 227F 0 080 ??? CD0C
                JNE     selftest_fail_041             ; 2281 0 080 ??? CE0A
                RB      PSWH.0                 ; 2283 0 080 ??? A208
                MB      C, PSWH.0              ; 2285 0 080 ??? A228
                MB      PSWH.6, C              ; 2287 0 080 ??? A23E
                JLT     selftest_fail_041             ; 2289 0 080 ??? CA02
                JNE     periph_init_start             ; 228B 0 080 ??? CE05
selftest_fail_041:     MOVB    0ebh, #041h            ; 228D 0 080 ??? C5EB9841
                BRK                            ; 2291 0 080 ??? FF
periph_init_start:     CLRB    off(PRPHF)             ; 2292 0 080 ??? C41215
                LB      A, #0ffh               ; 2295 0 080 ??? 77FF
                MOVB    off(P0), #0ebh         ; 2297 0 080 ??? C42098EB
                STB     A, off(P0IO)           ; 229B 0 080 ??? D421
                MOVB    off(P1), #044h         ; 229D 0 080 ??? C4229844
                STB     A, off(P1IO)           ; 22A1 0 080 ??? D423
                MOVB    off(P2), #01fh         ; 22A3 0 080 ??? C424981F
                STB     A, off(P2IO)           ; 22A7 0 080 ??? D425
                CLRB    off(P2SF)              ; 22A9 0 080 ??? C42615
                MOVB    off(P3), #0efh         ; 22AC 0 080 ??? C42898EF
                MOVB    off(TCON0), #08bh      ; 22B0 0 080 ??? C440988B
                CLR     A                      ; 22B4 1 080 ??? F9
                ST      A, off(TM0)            ; 22B5 1 080 ??? D430
                ST      A, off(TMR0)           ; 22B7 1 080 ??? D432
                MOVB    off(TCON1), #04fh      ; 22B9 1 080 ??? C441984F
                ST      A, off(TM1)            ; 22BD 1 080 ??? D434
                ST      A, off(TMR1)           ; 22BF 1 080 ??? D436
                MOVB    off(TCON2), #082h      ; 22C1 1 080 ??? C4429882
                ST      A, off(TM2)            ; 22C5 1 080 ??? D438
                ST      A, off(TMR2)           ; 22C7 1 080 ??? D43A
                MOVB    off(TCON3), #08fh      ; 22C9 1 080 ??? C443988F
                MOV     off(TM3), #00001h      ; 22CD 1 080 ??? B43C980100
                ST      A, off(TMR3)           ; 22D2 1 080 ??? D43E
                MOVB    off(P3IO), #0b1h       ; 22D4 1 080 ??? C42998B1
                MOVB    off(P3SF), #0ffh       ; 22D8 1 080 ??? C42A98FF
                CLRB    off(EXION)             ; 22DC 1 080 ??? C41C15
                SB      off(TCON0).2           ; 22DF 1 080 ??? C4401A
                RB      off(TCON0).2           ; 22E2 1 080 ??? C4400A
                MOVB    off(P4), #0f7h         ; 22E5 1 080 ??? C42C98F7
                L       A, #0ff00h             ; 22E9 1 080 ??? 6700FF
                MOVB    off(PWCON0), #03eh     ; 22EC 1 080 ??? C478983E
                ST      A, off(PWMC0)          ; 22F0 1 080 ??? D470
                ST      A, off(PWMR0)          ; 22F2 1 080 ??? D472
                MOVB    off(PWCON1), #07eh     ; 22F4 1 080 ??? C47A987E
                ST      A, off(PWMC1)          ; 22F8 1 080 ??? D474
                ST      A, off(PWMR1)          ; 22FA 1 080 ??? D476
                MOVB    off(P4IO), #00dh       ; 22FC 1 080 ??? C42D980D
                MOVB    off(P4SF), #0fch       ; 2300 1 080 ??? C42E98FC
                SB      off(TCON0).4           ; 2304 1 080 ??? C4401C
                SB      off(TCON1).4           ; 2307 1 080 ??? C4411C
                SB      off(TCON2).4           ; 230A 1 080 ??? C4421C
                XCHG    A, ACC                 ; 230D 1 080 ??? B50610
                SB      off(TCON3).4           ; 2310 1 080 ??? C4431C
                CLR     off(IRQ)               ; 2313 1 080 ??? B41815
                LB      A, #002h               ; 2316 0 080 ??? 7702
periph_init_delay_loop_load_dp:     MOV     DP, #00177h            ; 2318 0 080 ??? 627701
periph_init_delay_loop:     DEC     DP                     ; 231B 0 080 ??? 82
                JEQ     periph_init_delay_loop_load_ram0eb             ; 231C 0 080 ??? C927
                MBR     C, off(P4)             ; 231E 0 080 ??? C42C21
                JLT     periph_init_delay_loop             ; 2321 0 080 ??? CAF8
                MOV     DP, #00177h            ; 2323 0 080 ??? 627701
periph_init_delay_loop_dec_dp:     DEC     DP                     ; 2326 0 080 ??? 82
                JEQ     periph_init_delay_loop_load_ram0eb             ; 2327 0 080 ??? C91C
                MBR     C, off(P4)             ; 2329 0 080 ??? C42C21
                JGE     periph_init_delay_loop_dec_dp             ; 232C 0 080 ??? CDF8
                MOV     DP, #000b2h            ; 232E 0 080 ??? 62B200
periph_init_delay_loop_dec_dp_2:     DEC     DP                     ; 2331 0 080 ??? 82
                JEQ     periph_init_delay_loop_load_ram0eb             ; 2332 0 080 ??? C911
                MBR     C, off(P4)             ; 2334 0 080 ??? C42C21
                JLT     periph_init_delay_loop_dec_dp_2             ; 2337 0 080 ??? CAF8
                INCB    ACC                    ; 2339 0 080 ??? C50616
                CMPB    A, #004h               ; 233C 0 080 ??? C604
                JNE     periph_init_delay_loop_load_dp             ; 233E 0 080 ??? CED8
                RB      off(IRQH).5            ; 2340 0 080 ??? C4190D
                JNE     periph_init_delay_loop_load_imm             ; 2343 0 080 ??? CE05
periph_init_delay_loop_load_ram0eb:     MOVB    off(000ebh), #04ch     ; 2345 0 080 ??? C4EB984C
                BRK                            ; 2349 0 080 ??? FF
periph_init_delay_loop_load_imm:     L       A, #0ffffh             ; 234A 1 080 ??? 67FFFF
                ST      A, off(PWMR0)          ; 234D 1 080 ??? D472
                ST      A, off(PWMR1)          ; 234F 1 080 ??? D476
                RB      off(P4SF).3            ; 2351 1 080 ??? C42E0B
                L       A, #05555h             ; 2354 1 080 ??? 675555
                MOV     X1, A                  ; 2357 1 080 ??? 50
                CMP     A, X1                  ; 2358 1 080 ??? 90C2
                JNE     selftest_fail_042             ; 235A 1 080 ??? CE10
                MOV     X2, A                  ; 235C 1 080 ??? 51
                CMP     A, X2                  ; 235D 1 080 ??? 91C2
                JNE     selftest_fail_042             ; 235F 1 080 ??? CE0B
                SLL     A                      ; 2361 1 080 ??? 53
                MOV     X1, A                  ; 2362 1 080 ??? 50
                CMP     A, X1                  ; 2363 1 080 ??? 90C2
                JNE     selftest_fail_042             ; 2365 1 080 ??? CE05
                MOV     X2, A                  ; 2367 1 080 ??? 51
                CMP     A, X2                  ; 2368 1 080 ??? 91C2
                JEQ     ram_clear_loop1             ; 236A 1 080 ??? C905
selftest_fail_042:     MOVB    off(000ebh), #042h     ; 236C 1 080 ??? C4EB9842
                BRK                            ; 2370 1 080 ??? FF
ram_clear_loop1:     MOV     LRB, #00040h           ; 2371 1 200 ??? 574000
                MOV     X1, #003fah            ; 2374 1 200 ??? 60FA03
ram_clear_loop1_body:     MOV     DP, 00084h[X1]         ; 2377 1 200 ??? B084007A
                L       A, #05555h             ; 237B 1 200 ??? 675555
                CAL     selftest_regbank_verify             ; 237E 1 200 ??? 329352
                SLL     A                      ; 2381 1 200 ??? 53
                CAL     selftest_regbank_verify             ; 2382 1 200 ??? 329352
                SUB     X1, #00002h            ; 2385 1 200 ??? 90A00200
                JGE     ram_clear_loop1_body             ; 2389 1 200 ??? CDEC
                MOV     LRB, #00041h           ; 238B 1 208 ??? 574100
; (skeleton: no stored trouble codes to restore at power-up, no stored-code checksum)
cfgvariant_check_232h_bits01:     JBR     off(00232h).0, restore_trapstate_after_ramclear ; 23D8 1 208 ??? D83208
                JBR     off(00232h).1, restore_trapstate_after_ramclear ; 23DB 1 208 ??? D93205
                J       cfgvariant_check_232h_bits01_call_cfgvariant_ram_init_0x             ; 23DE 1 208 ??? 038B5A
restore_trapstate_after_ramclear:     MOV     LRB, #00010h           ; 23E3 1 080 ??? 571000
                MB      C, off(0009fh).0       ; 23E6 1 080 ??? C49F28
                MB      r0.0, C                ; 23E9 1 080 ??? 2038
                MB      C, off(0009fh).1       ; 23EB 1 080 ??? C49F29
                MB      r0.1, C                ; 23EE 1 080 ??? 2039
                MOVB    r1, off(000e7h)        ; 23F0 1 080 ??? C4E749
                MOVB    r2, off(000ech)        ; 23F3 1 080 ??? C4EC4A
                MOVB    r3, off(000ebh)        ; 23F6 1 080 ??? C4EB4B
                CLR     A                      ; 23F9 1 080 ??? F9
                MOV     USP, #00354h           ; 23FA 1 080 354 A1985403
                MOV     DP, #00480h            ; 23FE 1 080 354 628004
ram_clear_loop2:     DEC     DP                     ; 2401 1 080 354 82
                DEC     DP                     ; 2402 1 080 354 82
                ST      A, [DP]                ; 2403 1 080 354 D2
                CMP     DP, off(00086h)        ; 2404 1 080 354 92C386
                JGT     ram_clear_loop2             ; 2407 1 080 354 C8F8
                CMP     DP, #00098h            ; 2409 1 080 354 92C09800
                JLE     clear_0x324_high_nibble             ; 240D 1 080 354 CF0E
                MOV     USP, #00098h           ; 240F 1 080 098 A1989800
                CMPB    r3, #047h              ; 2413 1 080 098 23C047
                JNE     ram_clear_loop2             ; 2416 1 080 098 CEE9
                MOV     DP, #00300h            ; 2418 1 080 098 620003
                SJ      ram_clear_loop2             ; 241B 1 080 098 CBE4
clear_0x324_high_nibble:     MOV     DP, #00320h            ; 241D 1 080 354 622003
                LB      A, [DP]                ; 2420 0 080 354 F2
                ANDB    A, #0f0h               ; 2421 0 080 354 D6F0
                STB     A, [DP]                ; 2423 0 080 354 D2
                MB      C, r0.0                ; 2424 0 080 354 2028
                MB      off(0009fh).0, C       ; 2426 0 080 354 C49F38
                MB      C, r0.1                ; 2429 0 080 354 2029
                MB      off(0009fh).1, C       ; 242B 0 080 354 C49F39
                MOVB    off(000e7h), r1        ; 242E 0 080 354 217CE7
                MOVB    off(000ech), r2        ; 2431 0 080 354 227CEC
                MOVB    off(000ebh), r3        ; 2434 0 080 354 237CEB
                MOV     LRB, #00041h           ; 2437 0 208 354 574100
                SC                             ; 243A 0 208 354 85
                LB      A, 0e7h                ; 243B 0 208 354 F5E7
                JNE     fuelpump_prime_check             ; 243D 0 208 354 CE05
                MOVB    off(002bch), #014h     ; 243F 0 208 354 C4BC9814
                RC                             ; 2443 0 208 354 95
fuelpump_prime_check:     MB      off(00230h).5, C       ; 2444 0 208 354 C4303D
; [H] --- Runtime state init: A/D channel setup, initial sensor snapshot, working-RAM seeding,
; [H] and diagnostic-serial baud/config setup, run once during boot after the self-test/RAM-clear
; [H] passes above. Ends by jumping to stack_sanity_check (0x3359) before falling into the main loop.
; [H] Individual working-RAM addresses here (0xD8-0xE1, 0xDC-0xDF, etc.) are not yet traced to
; [H] specific named parameters -- confidently identified: ADCR2H/ADCR4/ADCR6 (A/D conversion
; [H] results), tbl_boot_copy_block (a calibration table copied verbatim into 0x1D1-0x1DD), and
; [H] STTM/STTMR/STTMC/STCON/SRCON (serial timer + control regs -- diagnostic/K-line baud setup).
                MOV     USP, #00180h           ; 2447 0 208 180 A1988001
                CLR     A                      ; 244B 1 208 180 F9
                ST      A, IE                  ; 244C 1 208 180 D51A
                MOV     DP, A                  ; 244E 1 208 180 52
                CLRB    ADSEL                  ; 244F 1 208 180 C55915
                MOVB    ADSCAN, #010h          ; 2452 1 208 180 C5589810
                RB      IRQH.4                 ; 2456 1 208 180 C5190C
adc_wait_loop:     MB      r0.0, C                ; 2459 1 208 180 2038
                JRNZ    DP, adc_wait_loop         ; 245B 1 208 180 30FC
                CAL     idle_helper1             ; 245D 1 208 180 32BB52
                LB      A, P2                  ; 2460 0 208 180 F524
                ANDB    A, #0e0h               ; 2462 0 208 180 D6E0
                JNE     adc_wait_loop             ; 2464 0 208 180 CEF3
                MOVB    0edh, #001h            ; 2466 0 208 180 C5ED9801
                CAL     selftest_reason_range_check_entry             ; 246A 0 208 180 320C53
                L       A, ADCR4               ; 246D 1 208 180 E568
                ST      A, 0cch                ; 246F 1 208 180 D5CC
                LB      A, ADCR2H              ; 2471 0 208 180 F565
                STB     A, 0c5h                ; 2473 0 208 180 D5C5
                MOV     DP, #003d2h            ; 2475 0 208 180 62D203
                STB     A, [DP]                ; 2478 0 208 180 D2
                MOV     DP, #003beh            ; 2479 0 208 180 62BE03
                LB      A, [DP]                ; 247C 0 208 180 F2
                STB     A, 0c2h                ; 247D 0 208 180 D5C2
                MOV     DP, #003c5h            ; 247F 0 208 180 62C503
                LB      A, [DP]                ; 2482 0 208 180 F2
                STB     A, 0c3h                ; 2483 0 208 180 D5C3
                MOVB    0c0h, #057h            ; 2485 0 208 180 C5C09857
                MOVB    0c1h, #03bh            ; 2489 0 208 180 C5C1983B
                MOVB    0a4h, #0f9h            ; 248D 0 208 180 C5A498F9
                LB      A, #025h               ; 2491 0 208 180 7725
                STB     A, 0c4h                ; 2493 0 208 180 D5C4
                STB     A, 0f7h                ; 2495 0 208 180 D5F7
                L       A, ADCR6               ; 2497 1 208 180 E56C
                ST      A, 0a2h                ; 2499 1 208 180 D5A2
                LB      A, ACCH                ; 249B 0 208 180 F507
                STB     A, off(00234h)         ; 249D 0 208 180 D434
                LB      A, #0a0h               ; 249F 0 208 180 77A0
                STB     A, off(00235h)         ; 24A1 0 208 180 D435
                STB     A, (0012ch-00180h)[USP] ; 24A3 0 208 180 D3AC
                STB     A, 0a5h                ; 24A5 0 208 180 D5A5
                MOV     DP, #00372h            ; 24A7 0 208 180 627203
                STB     A, [DP]                ; 24AA 0 208 180 D2
                INC     DP                     ; 24AB 0 208 180 72
                STB     A, [DP]                ; 24AC 0 208 180 D2
                L       A, #04d00h             ; 24AD 1 208 180 67004D
                ST      A, 0b8h                ; 24B0 1 208 180 D5B8
                ST      A, 0bah                ; 24B2 1 208 180 D5BA
                ST      A, er0                 ; 24B4 1 208 180 88
                SLL     A                      ; 24B5 1 208 180 53
                JLT     clamp_to_0xff             ; 24B6 1 208 180 CA05
                SLL     A                      ; 24B8 1 208 180 53
                LB      A, ACCH                ; 24B9 0 208 180 F507
                JGE     clamp_result_store             ; 24BB 0 208 180 CD02
clamp_to_0xff:     LB      A, #0ffh               ; 24BD 0 208 180 77FF
clamp_result_store:     STB     A, 0bch                ; 24BF 0 208 180 D5BC
                LB      A, r1                  ; 24C1 0 208 180 79
                STB     A, 0bbh                ; 24C2 0 208 180 D5BB
                CAL     boot_completion_helper             ; 24C4 0 208 180 326055
                SB      off(00231h).5          ; 24C7 0 208 180 C4311D
                MOV     0b6h, #0ffffh          ; 24CA 0 208 180 B5B698FFFF
                SB      off(00231h).3          ; 24CF 0 208 180 C4311B
                MOV     0c8h, #000e1h          ; 24D2 0 208 180 B5C898E100
                MOV     0cah, #0091fh          ; 24D7 0 208 180 B5CA981F09
                L       A, #00001h             ; 24DC 1 208 180 670100
                ST      A, (001bch-00180h)[USP] ; 24DF 1 208 180 D33C
                ST      A, (001bah-00180h)[USP] ; 24E1 1 208 180 D33A
                ST      A, (001b8h-00180h)[USP] ; 24E3 1 208 180 D338
                NOP                            ; 24E5 1 208 180 00
                NOP                            ; 24E6 1 208 180 00
                NOP                            ; 24E7 1 208 180 00
                NOP                            ; 24E8 1 208 180 00
                NOP                            ; 24E9 1 208 180 00
                NOP                            ; 24EA 1 208 180 00
                NOP                            ; 24EB 1 208 180 00
                NOP                            ; 24EC 1 208 180 00
                NOP                            ; 24ED 1 208 180 00
                NOP                            ; 24EE 1 208 180 00
                NOP                            ; 24EF 1 208 180 00
                NOP                            ; 24F0 1 208 180 00
                LB      A, #00fh               ; 24F1 0 208 180 770F
                STB     A, (001bfh-00180h)[USP] ; 24F3 0 208 180 D33F
                STB     A, (001b7h-00180h)[USP] ; 24F5 0 208 180 D337
                MOVB    0e6h, #031h            ; 24F7 0 208 180 C5E69831
                MOV     0e4h, #0ffffh          ; 24FB 0 208 180 B5E498FFFF
                MOVB    off(002f4h), #0ffh     ; 2500 0 208 180 C4F498FF
                MOV     DP, #003c8h            ; 2504 0 208 180 62C803
                LB      A, [DP]                ; 2507 0 208 180 F2
                STB     A, off(002a5h)         ; 2508 0 208 180 D4A5
                CAL     ect_step_helper             ; 250A 0 208 180 322F52
                CLRB    A                      ; 250D 0 208 180 FA
                MOV     DP, #001a9h            ; 250E 0 208 180 62A901
clamp_result_store_rom_load_tbl_6ab3_dp:     LCB     A, clamp_result_store_tbl[DP]        ; 2511 0 208 180 92ABB36A
                STB     A, [DP]                ; 2515 0 208 180 D2
                INC     DP                     ; 2516 0 208 180 72
                CMP     DP, #001b6h            ; 2517 0 208 180 92C0B601
                JNE     clamp_result_store_rom_load_tbl_6ab3_dp             ; 251B 0 208 180 CEF4
                MOVB    off(002ebh), #0ffh     ; 251D 0 208 180 C4EB98FF
                MOVB    off(002e4h), #0f9h     ; 2521 0 208 180 C4E498F9
                MOVB    off(002aeh), #002h     ; 2525 0 208 180 C4AE9802
                MOVB    off(002b2h), #002h     ; 2529 0 208 180 C4B29802
                MOVB    off(002a3h), #053h     ; 252D 0 208 180 C4A39853
                MOV     DP, #00310h            ; 2531 0 208 180 621003
                LB      A, [DP]                ; 2534 0 208 180 F2
                MOVB    ACC, #07bh             ; 2535 0 208 180 C506987B
                JNE     serial_baud_store_common             ; 2539 0 208 180 CE02
                INC     DP                     ; 253B 0 208 180 72
                STB     A, [DP]                ; 253C 0 208 180 D2
serial_baud_store_common:     STB     A, off(002a4h)         ; 253D 0 208 180 D4A4
                SB      off(00225h).1          ; 253F 0 208 180 C42519
                CMPB    0ebh, #047h            ; 2542 0 208 180 C5EBC047
                JEQ     serial_baud_select_done             ; 2546 0 208 180 C910
                MOV     DP, #00312h            ; 2548 0 208 180 621203
                L       A, #00332h             ; 254B 1 208 180 673203
                ST      A, [DP]                ; 254E 1 208 180 D2
                INC     DP                     ; 254F 1 208 180 72
                INC     DP                     ; 2550 1 208 180 72
                ST      A, [DP]                ; 2551 1 208 180 D2
                MOV     DP, #00352h            ; 2552 1 208 180 625203
                MOVB    [DP], #03bh            ; 2555 1 208 180 C2983B
serial_baud_select_done:     MOVB    off(002b6h), #032h     ; 2558 1 208 180 C4B69832
                NOP                            ; 255C 1 208 180 00
                NOP                            ; 255D 1 208 180 00
                NOP                            ; 255E 1 208 180 00
                NOP                            ; 255F 1 208 180 00
                MOV     DP, #04700h            ; 2581 0 208 180 620047
                LB      A, [DP]                ; 2584 0 208 180 F2
                XORB    A, #01ah               ; 2585 0 208 180 F61A
                STB     A, off(00211h)         ; 2587 0 208 180 D411
                STB     A, (00111h-00180h)[USP] ; 2589 0 208 180 D391
                CLR     A                      ; 258B 1 208 180 F9
                MOV     DP, #003fch            ; 258C 1 208 180 62FC03
                LC      A, 00038h              ; 258F 1 208 180 909C3800
                ST      A, [DP]                ; 2593 1 208 180 D2
                INC     DP                     ; 2594 1 208 180 72
                INC     DP                     ; 2595 1 208 180 72
                LC      A, 0003ah              ; 2596 1 208 180 909C3A00
                ST      A, [DP]                ; 259A 1 208 180 D2
                CLRB    0ebh                   ; 259B 1 208 180 C5EB15
                CAL     skel_boot_modules      ; (skeleton) clear the module requests, then hook_init
                J       stack_sanity_check             ; 259E 1 208 180 032838
; [CG] background_task_scheduler  @0x2686
; [CG] TRACED: manages an IE interrupt-mask cycle counter (RAM 0xCE), runs housekeeping
; [CG] (ResetWatchDog + decrement_timer_array x3), runs a divide-by-10 slow-tick generator
; [CG] that raises off(231h).1/.2 for the two periodic decay tasks, then dispatches - by
; [CG] unconditional JUMP, not CALL - to exactly one of five subsystem tasks per invocation
; [CG] based on a priority-ordered chain of flag tests (off 09Eh.6/.4, off(227h).2,
; [CG] off(216h).3, off(231h).0/.1/.2). Reached via VCAL 4, 199 call sites' worth of VCAL
; [CG] usage total across the ROM makes this the busiest entry point in the firmware.
background_task_scheduler:     L       A, 0f4h                ; 2686 1 208 180 E5F4
                ST      A, IE                  ; 2688 1 208 180 D51A
                RB      PSWH.0                 ; 268A 1 208 180 A208
                LB      A, 0ceh                ; 268C 0 208 180 F5CE
                SUBB    A, #005h               ; 268E 0 208 180 A605
                JLT     vcal3_leanprotect_ratelimit             ; 2690 0 208 180 CA02
                STB     A, 0ceh                ; 2692 0 208 180 D5CE
vcal3_leanprotect_ratelimit:     SB      PSWH.0                 ; 2694 0 208 180 A218
                L       A, 0f2h                ; 2696 1 208 180 E5F2
                ST      A, IE                  ; 2698 1 208 180 D51A
                JGE     vcal3_main_task             ; 269A 1 208 180 CD3B
                J       vcal3_leanprotect_ratelimit_clear_stk             ; 269C 1 208 180 037D5F
vcal3_leanprotect_ratelimit_clear_ram09e_bit6:     RB      09eh.6                 ; 269F 1 208 180 C59E0E
                JEQ     vcal3_leanprotect_ratelimit_clear_ram09e_bit4             ; 26A2 1 208 180 C903
                RT                             ; 26A4 (skeleton: no EGR - the valve duty stays at its power-up value FFFFh, closed)
vcal3_leanprotect_ratelimit_clear_ram09e_bit4:     RB      09eh.4                 ; 26A7 1 208 180 C59E0C
                JEQ     vcal3_leanprotect_ratelimit_if_ram227_bit2_set             ; 26AA 1 208 180 C90C
                JBR     off(0022bh).0, vcal3_task_a ; 26AC 1 208 180 D82B06
                RB      off(00231h).0          ; 26AF 1 208 180 C43108
                JNE     vcal3_task_a             ; 26B2 1 208 180 CE01
                RT                             ; 26B4 1 208 180 01
vcal3_task_a:     J       battery_voltage_check             ; 26B5 1 208 180 03842A
vcal3_leanprotect_ratelimit_if_ram227_bit2_set:     JBS     off(00227h).2, vcal3_dispatch_check1 ; 26B8 1 208 180 EA270B
                JBR     off(00216h).3, vcal3_dispatch_check1 ; 26BB 1 208 180 DB1608
                RB      09eh.3                 ; 26BE 1 208 180 C59E0B
                JEQ     vcal3_dispatch_check1             ; 26C1 1 208 180 C903
                J       ignition_timing_calc_task             ; 26C3 1 208 180 03DB31
vcal3_dispatch_check1:     RB      off(00231h).1          ; 26C6 1 208 180 C43109
                JEQ     vcal3_dispatch_check2             ; 26C9 1 208 180 C903
                J       periodic_decay_task_1             ; 26CB 1 208 180 03B935
vcal3_dispatch_check2:     RB      off(00231h).2          ; 26CE 1 208 180 C4310A
                JNE     vcal3_task_b             ; 26D1 1 208 180 CE01
                RT                             ; 26D3 1 208 180 01
vcal3_task_b:     J       vcal3_task_b_body             ; 26D4 1 208 180 03CE36
vcal3_main_task:     CAL     ResetWatchDog             ; 26D7 1 208 180 321E52
                MOV     DP, #0000ah            ; 26DA 1 208 180 620A00
                MOV     X1, #0019fh            ; 26DD 1 208 180 609F01
                CAL     decrement_timer_array             ; 26E0 1 208 180 320452
                MOV     DP, #0000bh            ; 26E3 1 208 180 620B00
                MOV     X1, #002dfh            ; 26E6 1 208 180 60DF02
                CAL     decrement_timer_array             ; 26E9 1 208 180 320452
                MOV     DP, #00001h            ; 26EC 1 208 180 620100
                MOV     X1, #0037fh            ; 26EF 1 208 180 607F03
                CAL     decrement_timer_array             ; 26F2 1 208 180 320452
                LB      A, off(002e6h)         ; 26F5 0 208 180 F4E6
                JNE     scheduler_slowflag_check             ; 26F7 0 208 180 CE04
                MOV     DP, #0039bh            ; 26F9 0 208 180 629B03
                STB     A, [DP]                ; 26FC 0 208 180 D2
scheduler_slowflag_check:     CLR     A                      ; 26FD 1 208 180 F9
                LB      A, off(002e4h)         ; 26FE 0 208 180 F4E4
                JNE     scheduler_divider_check             ; 2700 0 208 180 CE12
                LB      A, #0fah               ; 2702 0 208 180 77FA
                STB     A, off(002e4h)         ; 2704 0 208 180 D4E4
                MB      C, off(00231h).7       ; 2706 0 208 180 C4312F
                XORB    PSWH, #080h            ; 2709 0 208 180 A2F080
                MB      off(00231h).7, C       ; 270C 0 208 180 C4313F
                JLT     scheduler_divider_check             ; 270F 0 208 180 CA03
                SB      off(00231h).2          ; 2711 0 208 180 C4311A
scheduler_divider_check:     MOVB    r0, #00ah              ; 2714 0 208 180 980A
                DIVB                           ; 2716 0 208 180 A236
                LB      A, r1                  ; 2718 0 208 180 79
                JNE     scheduler_task_done             ; 2719 0 208 180 CE3D
                SB      off(00231h).1          ; 271B 0 208 180 C43119
                JBR     off(00216h).5, scheduler_gate_common ; 271E 0 208 180 DD1629
                NOP                            ; 2721 0 208 180 00
                NOP                            ; 2722 0 208 180 00
                CLR     A                      ; 2723 (skeleton: fault flags are always clear)
                                                ; 2731 (skeleton: no VTEC pressure-switch state to test - treated as healthy)
                                                ; 2734 (skeleton: no VTEC pressure-switch state to test - treated as healthy)
                LB      A, 0c1h                ; 2737 0 208 180 F5C1
                CMPB    A, #00ch               ; 2739 0 208 180 C60C
                JLE     scheduler_ect_sign_check             ; 273B 0 208 180 CF15
                CMPB    A, #0d0h               ; 273D 0 208 180 C6D0
                JGE     scheduler_ect_sign_check             ; 273F 0 208 180 CD11
                RB      off(00223h).6          ; 2741 0 208 180 C4230E
                XORB    P0, #040h              ; 2744 0 208 180 C520F040
                SJ      scheduler_task_done             ; 2748 0 208 180 CB0E
scheduler_gate_common:     SB      P0.6                   ; 274A 0 208 180 C5201E
                SB      off(00223h).6          ; 274D 0 208 180 C4231E
                SJ      scheduler_task_done             ; 2750 0 208 180 CB06
scheduler_ect_sign_check:     RB      P0.6                   ; 2752 0 208 180 C5200E
                RB      off(00223h).6          ; 2755 0 208 180 C4230E
scheduler_task_done:     MOV     DP, #000b6h            ; 2758 0 208 180 62B600
                RB      09eh.2                 ; 275E 0 208 180 C59E0A
                JEQ     vss_calc_gate2             ; 2761 0 208 180 C977
                JBS     off(00217h).5, vss_calc_gate3 ; 2763 0 208 180 ED177D
                CMPB    0c3h, #044h            ; 2766 0 208 180 C5C3C044
                JLT     vss_calc_skip             ; 276A 0 208 180 CA66
                L       A, 0f4h                ; 276C 1 208 180 E5F4
                ST      A, IE                  ; 276E 1 208 180 D51A
                RB      PSWH.0                 ; 2770 1 208 180 A208
                MOVB    r0, 0dah               ; 2772 1 208 180 C5DA48
                L       A, 0d8h                ; 2775 1 208 180 E5D8
                SUB     A, 0dch                ; 2777 1 208 180 B5DCA2
                ST      A, er1                 ; 277A 1 208 180 89
                SB      PSWH.0                 ; 277B 1 208 180 A218
                L       A, 0f2h                ; 277D 1 208 180 E5F2
                ST      A, IE                  ; 277F 1 208 180 D51A
                SBCB    r0, #000h              ; 2781 1 208 180 20B000
                SRLB    r0                     ; 2784 1 208 180 20E7
                L       A, er1                 ; 2786 1 208 180 35
                ROR     A                      ; 2787 1 208 180 43
                CMPB    r0, #000h              ; 2788 1 208 180 20C000
                JNE     vss_calc_gate3             ; 278B 1 208 180 CE56
                RB      off(00231h).3          ; 278D 1 208 180 C4310B
                JNE     vss_calc_gate2_if_ram231_bit3_set             ; 2790 1 208 180 CE5E
                RB      off(00231h).4          ; 2792 1 208 180 C4310C
                JNE     vss_calc_gate2_if_ram231_bit3_set             ; 2795 1 208 180 CE59
                CMP     A, #00373h             ; 2797 1 208 180 C67303
                MB      off(00231h).4, C       ; 279A 1 208 180 C4313C
                JLT     vss_calc_gate2_if_ram231_bit3_set             ; 279D 1 208 180 CA51
                CMP     A, #0397dh             ; 279F 1 208 180 C67D39
                JGE     vss_result_store             ; 27A2 1 208 180 CD10
                MOV     er0, #01000h           ; 27A4 1 208 180 44980010
                CMP     A, #005c0h             ; 27A8 1 208 180 C6C005
                JLT     vss_scale_apply             ; 27AB 1 208 180 CA04
                MOV     er0, #04000h           ; 27AD 1 208 180 44980040
vss_scale_apply:     CAL     mul_scale_helper2             ; 27B1 1 208 180 32304F
vss_result_store:     ST      A, [DP]                ; 27B4 1 208 180 D2
                ST      A, er2                 ; 27B5 1 208 180 8A
vssSpeedNumerator    equ 05e59h ; VSS: speed = (3 * 10000h + vssSpeedNumerator) / pulse period (MOV er0,#3 / L A,# / DIV).
                                ; A number, not a table: it used to be bound to whatever label sat at this address.
                MOV     er0, #00003h           ; 27B6 1 208 180 44980300
                L       A, #vssSpeedNumerator       ; 27BA 1 208 180 67595E
                DIV                            ; 27BD 1 208 180 9037
                ST      A, er1                 ; 27BF 1 208 180 89
                L       A, er0                 ; 27C0 1 208 180 34
                JNE     vss_clamp_max             ; 27C1 1 208 180 CE03
                LB      A, r3                  ; 27C3 0 208 180 7B
                JEQ     vss_clamp_common             ; 27C4 0 208 180 C902
vss_clamp_max:     MOVB    r2, #0ffh              ; 27C6 0 208 180 9AFF
vss_clamp_common:     LB      A, r2                  ; 27C8 0 208 180 7A
vss_final_store:     STB     A, r2                  ; 27C9 0 208 180 8A
                MOVB    r3, 0b4h               ; 27CA 0 208 180 C5B44B
                L       A, er1                 ; 27CD 1 208 180 35
                ST      A, 0b4h                ; 27CE 1 208 180 D5B4
                SJ      vss_calc_gate2_if_ram231_bit3_set             ; 27D0 1 208 180 CB1E
vss_calc_skip:     L       A, #vss_calc_skip_tbl           ; 27D2 1 208 180 67FA72
                RB      off(00231h).3          ; 27D5 1 208 180 C4310B
                SJ      vss_result_store             ; 27D8 1 208 180 CBDA
vss_calc_gate2:     LB      A, #003h               ; 27DA 0 208 180 7703
                CMPB    0dbh, A                ; 27DC 0 208 180 C5DBC1
                JLT     vss_calc_gate2_if_ram231_bit3_set             ; 27DF 0 208 180 CA0F
                STB     A, 0dbh                ; 27E1 0 208 180 D5DB
vss_calc_gate3:     RB      off(00231h).4          ; 27E3 0 208 180 C4310C
                SB      off(00231h).3          ; 27E6 0 208 180 C4311B
                MOV     [DP], #0ffffh          ; 27E9 0 208 180 B298FFFF
                CLRB    A                      ; 27ED 0 208 180 FA
                SJ      vss_final_store             ; 27EE 0 208 180 CBD9
vss_calc_gate2_if_ram231_bit3_set:     JBS     off(00231h).3, vss_calc_gate2_if_ram227_bit6_clr ; 27F0 1 208 180 EB3104
                MOVB    off(002e5h), #008h     ; 27F3 1 208 180 C4E59808
vss_calc_gate2_if_ram227_bit6_clr:     JBR     off(00227h).6, idle_gate1_clear ; 27F7 1 208 180 DE2722
                MOV     DP, #00f00h            ; 27FD 1 208 180 62000F
                MB      C, [DP].2              ; 2800 1 208 180 C22A
                RB      off(00232h).6          ; 2802 1 208 180 C4320E
                MB      off(00232h).6, C       ; 2805 1 208 180 C4323E
                JEQ     idle_gate1             ; 2808 1 208 180 C903
                XORB    PSWH, #080h            ; 280A 1 208 180 A2F080
idle_gate1:     JGE     idle_gate1_timer_check             ; 280D 1 208 180 CD10
                CMPB    0adh, #00dh            ; 280F 1 208 180 C5ADC00D
                JGT     idle_gate1_trigger             ; 2813 1 208 180 C803
                                                ; 2815 (skeleton: no knock flag to test)
idle_gate1_trigger:     MOVB    off(002e8h), #00ah     ; 2818 1 208 180 C4E8980A
idle_gate1_clear:     RC                             ; 281C 1 208 180 95
                SJ      dtc24_code24_latch             ; 281D 1 208 180 CB05
idle_gate1_timer_check:     LB      A, off(002e8h)         ; 281F 0 208 180 F4E8
                JNE     idle_gate1_clear             ; 2821 0 208 180 CEF9
                SC                             ; 2823 0 208 180 85
dtc24_code24_latch:     RB      09ah.3                 ; 2824 0 208 180 C59A3B
                J       idle_init_start_clear_stk             ; 2827 0 208 180 03895F
idle_init_start_load_er0:     MOV     er0, off(002ech)       ; 282A 0 208 180 B4EC48
                CLR     A                      ; 282D 1 208 180 F9
                LB      A, #040h               ; 282E 0 208 180 7740
                MUL                            ; 2830 0 208 180 9035
                MOV     X1, A                  ; 2832 0 208 180 50
                MOV     DP, #00020h            ; 2833 0 208 180 622000
                MOVB    r0, off(002eah)        ; 2836 0 208 180 C4EA48
idle_init_start_rom_load_tbl_x1:     LC      A, [X1]                ; 2839 0 208 180 90A8
                ADDB    A, ACCH                ; 283B 0 208 180 C50782
                ADDB    r0, A                  ; 283E 0 208 180 2081
                INC     X1                     ; 2840 0 208 180 70
                INC     X1                     ; 2841 0 208 180 70
                JRNZ    DP, idle_init_start_rom_load_tbl_x1         ; 2842 0 208 180 30F5
                LB      A, r0                  ; 2844 0 208 180 78
                STB     A, off(002eah)         ; 2845 0 208 180 D4EA
                INC     off(002ech)            ; 2847 0 208 180 B4EC16
                CMP     off(002ech), #00200h   ; 284A 0 208 180 B4ECC00002
                JNE     idle_mode_gate2             ; 284F 0 208 180 CE16
                CLR     off(002ech)            ; 2851 0 208 180 B4EC15
                LB      A, r0                  ; 2854 0 208 180 78
                JEQ     idle_mode_gate2             ; 2855 0 208 180 C910
                CLRB    off(002eah)            ; 2857 0 208 180 C4EA15
                LCB     A, idle_init_start_tbl            ; 285A 0 208 180 909D1160
                JNE     idle_mode_gate2             ; 285E 0 208 180 CE07
                MOVB    0ebh, #048h            ; 2860 0 208 180 C5EB9848
                J       fault_giveup_latch             ; 2864 0 208 180 03DE21
idle_mode_gate2:     JBR     off(002e4h).0, idle_mode_gate2_load_ram0c8 ; 2867 0 208 180 D8E403
                J       transit_flag_check             ; 286A 0 208 180 036429
idle_mode_gate2_load_ram0c8:     L       A, 0c8h                ; 286D 1 208 180 E5C8
                MOV     X1, #tbl_idle_dc          ; 286F 1 208 180 608869
                CAL     table_interp_lookup_4byte             ; 2872 1 208 180 32FE4E
                MOV     er0, 0cch              ; 2875 1 208 180 B5CC48
                MUL                            ; 2878 1 208 180 9035
                SLL     A                      ; 287A 1 208 180 53
                L       A, er1                 ; 287B 1 208 180 35
                ROL     A                      ; 287C 1 208 180 33
                JGE     idle_dc_result_store             ; 287D 1 208 180 CD03
                L       A, #0ffffh             ; 287F 1 208 180 67FFFF
idle_dc_result_store:     MOV     DP, #003ceh            ; 2882 1 208 180 62CE03
                ST      A, [DP]                ; 2885 1 208 180 D2
                MOV     er3, off(0028ah)       ; 2886 1 208 180 B48A4B
                SUB     A, off(0025ah)         ; 2889 1 208 180 A75A
                MB      r4.0, C                ; 288B 1 208 180 2438
                JEQ     idle_delta_flag_set             ; 288D 1 208 180 C90D
                RB      off(0022ah).5          ; 288F 1 208 180 C42A0D
                MB      off(0022ah).5, C       ; 2892 1 208 180 C42A3D
                JEQ     idle_delta_flag_check             ; 2895 1 208 180 C903
                XORB    PSWH, #080h            ; 2897 1 208 180 A2F080
idle_delta_flag_check:     JGE     idle_delta_flag_store             ; 289A 1 208 180 CD01
idle_delta_flag_set:     SC                             ; 289C 1 208 180 85
idle_delta_flag_store:     MB      r4.1, C                ; 289D 1 208 180 2439
                MOV     X1, #000e1h            ; 289F 1 208 180 60E100
                MOV     X2, #0091fh            ; 28A2 1 208 180 611F09
                JBR     off(0020ch).0, idle_helper2_call1 ; 28A5 1 208 180 D80C01
                VCAL    7                      ; 28A8 1 208 180 17
idle_helper2_call1:     ST      A, er0                 ; 28A9 1 208 180 88
                L       A, #00580h             ; 28AA 1 208 180 678005
                CAL     idle_helper2             ; 28AD 1 208 180 324151
                MOV     DP, A                  ; 28B0 1 208 180 52
                L       A, #000f0h             ; 28B1 1 208 180 67F000
                CAL     idle_helper2             ; 28B4 1 208 180 324151
                XCHG    A, 0c8h                ; 28B7 1 208 180 B5C810
                ST      A, er0                 ; 28BA 1 208 180 88
                CLRB    A                      ; 28BB 0 208 180 FA
                JLT     idle_step_default_store_ram2bd             ; 28BC 0 208 180 CA0E
                L       A, DP                  ; 28BE 1 208 180 42
                ST      A, off(0028ah)         ; 28BF 1 208 180 D48A
                L       A, er0                 ; 28C1 1 208 180 34
                CMP     A, 0c8h                ; 28C2 1 208 180 B5C8C2
                JEQ     idle_step_default             ; 28C5 1 208 180 C903
                JBR     off(0020ch).1, idle_debounce_gate ; 28C7 1 208 180 D90C04
idle_step_default:     LB      A, #00ah               ; 28CA 0 208 180 770A
idle_step_default_store_ram2bd:     STB     A, off(002bdh)         ; 28CC 0 208 180 D4BD
idle_debounce_gate:     MB      C, 09fh.1              ; 28CE 0 208 180 C59F29
                JLT     idle_debounce_disabled             ; 28D1 0 208 180 CA6D
                JBR     off(00230h).2, idle_debounce_skip ; 28D3 0 208 180 DA305A
                MOV     DP, #01f00h            ; 28D6 0 208 180 62001F
                AND     IE, #002a0h            ; 28D9 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 28DE 0 208 180 A208
                LB      A, P0                  ; 28E0 0 208 180 F520
                STB     A, [DP]                ; 28E2 0 208 180 D2
                STB     A, r0                  ; 28E3 0 208 180 88
                MOVB    r1, [DP]               ; 28E4 0 208 180 C249
                SB      PSWH.0                 ; 28E6 0 208 180 A218
                L       A, 0f2h                ; 28E8 1 208 180 E5F2
                ST      A, IE                  ; 28EA 1 208 180 D51A
                LB      A, r1                  ; 28EC 0 208 180 79
                CMPB    A, r0                  ; 28ED 0 208 180 48
                JNE     idle_port_p1_check             ; 28EE 0 208 180 CE2F
                MOV     DP, #02f00h            ; 28F0 0 208 180 62002F
                AND     IE, #002a0h            ; 28F3 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 28F8 0 208 180 A208
                LB      A, P1                  ; 28FA 0 208 180 F522
                STB     A, [DP]                ; 28FC 0 208 180 D2
                STB     A, r0                  ; 28FD 0 208 180 88
                MOVB    r1, [DP]               ; 28FE 0 208 180 C249
                SB      PSWH.0                 ; 2900 0 208 180 A218
                L       A, 0f2h                ; 2902 1 208 180 E5F2
                ST      A, IE                  ; 2904 1 208 180 D51A
                LB      A, r1                  ; 2906 0 208 180 79
                CMPB    A, r0                  ; 2907 0 208 180 48
                JNE     idle_port_p1_check             ; 2908 0 208 180 CE15
                MOV     DP, #00f00h            ; 290A 0 208 180 62000F
                LB      A, [DP]                ; 290D 0 208 180 F2
                XORB    A, #038h               ; 290E 0 208 180 F638
                AND     IE, #002a0h            ; 2910 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 2915 0 208 180 A208
                STB     A, off(00210h)         ; 2917 0 208 180 D410
                STB     A, (00110h-00180h)[USP] ; 2919 0 208 180 D390
                SB      PSWH.0                 ; 291B 0 208 180 A218
                SJ      idle_debounce_ie_restore             ; 291D 0 208 180 CB1D
idle_port_p1_check:     LB      A, #04dh               ; 291F 0 208 180 774D
                STB     A, 0e7h                ; 2921 0 208 180 D5E7
                DECB    0edh                   ; 2923 0 208 180 C5ED17
                JNE     idle_debounce_skip             ; 2926 0 208 180 CE08
                STB     A, 0ebh                ; 2928 0 208 180 D5EB
                CLRB    0ech                   ; 292A 0 208 180 C5EC15
                J       fault_retry_check             ; 292D 0 208 180 03D521
idle_debounce_skip:     AND     IE, #002a0h            ; 2930 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 2935 0 208 180 A208
                CAL     port_debounce_helper             ; 2937 0 208 180 32E451
                SB      PSWH.0                 ; 293A 0 208 180 A218
idle_debounce_ie_restore:     L       A, 0f2h                ; 293C 1 208 180 E5F2
                ST      A, IE                  ; 293E 1 208 180 D51A
idle_debounce_disabled:     MOV     DP, #04700h            ; 2940 0 208 180 620047
                LB      A, [DP]                ; 2943 0 208 180 F2
                XORB    A, #01ah               ; 2944 0 208 180 F61A
                MB      C, off(00211h).4       ; 2946 0 208 180 C4112C
                AND     IE, #002a0h            ; 2949 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 294E 0 208 180 A208
                STB     A, off(00211h)         ; 2950 0 208 180 D411
                STB     A, (00111h-00180h)[USP] ; 2952 0 208 180 D391
                SB      PSWH.0                 ; 2954 0 208 180 A218
                L       A, 0f2h                ; 2956 1 208 180 E5F2
                ST      A, IE                  ; 2958 1 208 180 D51A
                JGE     idle_debounce_return             ; 295A 1 208 180 CD07
                JBS     off(00211h).4, idle_debounce_return ; 295C 1 208 180 EC1104
                MOVB    off(002d6h), #00fh     ; 295F 1 208 180 C4D6980F
idle_debounce_return:     RT                             ; 2963 1 208 180 01
; [CG] transit_flag_check  @0x2964
; [CG] TRACED: dispatch-adjacent task in the same background_task_scheduler region. Tests
; [CG] TRNSIT (edge-detect SFR) bit 3, conditionally decrements a counter at RAM 0x2EB.
transit_flag_check:     LB      A, #0ffh               ; 2964 0 208 180 77FF
                RB      TRNSIT.3               ; 2966 0 208 180 C5460B
                JNE     transit_flag_common             ; 2969 0 208 180 CE07
                SC                             ; 296B 0 208 180 85
                LB      A, off(002ebh)         ; 296C 0 208 180 F4EB
                JEQ     transit_flag_store             ; 296E 0 208 180 C903
                SUBB    A, #001h               ; 2970 0 208 180 A601
transit_flag_common:     RC                             ; 2972 0 208 180 95
transit_flag_store:     MB      off(00230h).6, C       ; 2973 0 208 180 C4303E
                STB     A, off(002ebh)         ; 2976 0 208 180 D4EB
                JBR     off(002e4h).1, transit_gate_check ; 2978 0 208 180 D9E401
                RT                             ; 297B 0 208 180 01
; [CG] transit_gate_check  @0x297C
; [CG] TRACED: reads RAM 0xC4 (unnamed byte), tests off(214h).3 and SFR bit 099h.7, compares
; [CG] the periodic counter at RAM 0xE9 (the same counter periodic_decay_task_1 increments)
; [CG] against 50, and on threshold calls mul_scale_helper2 with the tiny table at 0x6000
; [CG] before setting the slow-tick flag off(231h).0. Dispatch target from
; [CG] background_task_scheduler, sandwiched between other tasks.
transit_gate_check:     MOV     DP, #000f6h            ; 297C 0 208 180 62F600
                LB      A, 0c4h                ; 297F 0 208 180 F5C4
                STB     A, ACCH                ; 2981 0 208 180 D507
                CLRB    A                      ; 2983 0 208 180 FA
                MB      C, 099h.7              ; 2987 0 208 180 C5992F
                JLT     idle_task_done             ; 298A 0 208 180 CA11
                CMPB    0e9h, #032h            ; 298C 0 208 180 C5E9C032
                JGE     idle_scratch_scale             ; 2990 0 208 180 CD04
idle_scratch_store:     MOV     [DP], A                ; 2992 0 208 180 B28A
                SJ      idle_task_done             ; 2994 0 208 180 CB07
idle_scratch_scale:     MOV     er0, #tbl_idle_pi_clamp         ; 2996 0 208 180 44980060
                CAL     mul_scale_helper2             ; 299A 0 208 180 32304F
idle_task_done:     SB      off(00231h).0          ; 299D 0 208 180 C43118
                RT                             ; 29A0 0 208 180 01
battery_voltage_check:     MB      C, off(0022bh).2       ; 2A84 1 208 180 C42B2A
                MB      off(0022bh).3, C       ; 2A87 1 208 180 C42B3B
                CLRB    A                      ; 2A8A 0 208 180 FA
                MB      C, off(0021ah).5       ; 2A8B 0 208 180 C41A2D
                ROLB    A                      ; 2A8E 0 208 180 33
                MB      C, off(00210h).3       ; 2A8F 0 208 180 C4102B
                ROLB    A                      ; 2A92 0 208 180 33
                MB      C, off(00211h).2       ; 2A93 0 208 180 C4112A
                ROLB    A                      ; 2A96 0 208 180 33
                MB      C, off(00211h).5       ; 2A97 0 208 180 C4112D
                ROLB    A                      ; 2A9A 0 208 180 33
                STB     A, r0                  ; 2A9B 0 208 180 88
                XORB    A, off(00229h)         ; 2A9C 0 208 180 F729
                ANDB    A, #00fh               ; 2A9E 0 208 180 D60F
                SWAPB                          ; 2AA0 0 208 180 83
                ORB     A, r0                  ; 2AA1 0 208 180 68
                STB     A, off(00229h)         ; 2AA2 0 208 180 D429
                LB      A, #005h               ; 2AA4 0 208 180 7705
                JBS     off(0021ah).3, battery_voltage_check_cmp_acc ; 2AA6 0 208 180 EB1A02
                LB      A, #006h               ; 2AA9 0 208 180 7706
battery_voltage_check_cmp_acc:     CMPB    A, 0b4h                ; 2AAB 0 208 180 C5B4C2
                J       battery_voltage_check_store_carry_ram21a_bit3             ; 2AAE 0 208 180 030E5E
battery_voltage_store_load_x1:     MOV     X1, #battery_voltage_store_tbl          ; 2AB1 0 208 180 603966
                MOV     DP, #0022ah            ; 2AB4 0 208 180 622A02
                MOVB    r2, 0c5h               ; 2AB7 0 208 180 C5C54A
                MOV     er0, #00100h           ; 2ABA 0 208 180 44980001
                RB      PSWL.4                 ; 2ABE 0 208 180 A30C
                CAL     timer_or_counter_helper             ; 2AC0 0 208 180 327752
                MOVB    r1, #002h              ; 2AC3 0 208 180 9902
                MOVB    r2, off(00236h)        ; 2AC5 0 208 180 C4364A
                CAL     timer_or_counter_helper             ; 2AC8 0 208 180 327752
                MOVB    r1, #002h              ; 2ACB 0 208 180 9902
                MOVB    r2, 0f7h               ; 2ACD 0 208 180 C5F74A
                SB      PSWL.4                 ; 2AD0 0 208 180 A31C
                J       battery_voltage_store_call_timer_or_counter_helper             ; 2AD2 0 208 180 03E956
battery_voltage_store_set_carry:     SC                             ; 2AD5 0 208 180 85
                CLR     A                      ; 2AD6 (skeleton: fault flags are always clear)
                RC                             ; 2AE0 1 208 180 95
freezeframe_flag_225_7:     MB      off(0022bh).4, C       ; 2AE1 1 208 180 C42B3C
                MB      C, off(0021ah).0       ; 2AE4 1 208 180 C41A28
                MB      off(00223h).5, C       ; 2AE7 1 208 180 C4233D
                JBS     off(0022bh).4, freezeframe_flag_225_7_set_carry ; 2AEA 1 208 180 EC2B36
                MB      C, 098h.1              ; 2AED 1 208 180 C59829
                JLT     freezeframe_flag_225_7_set_carry             ; 2AF0 1 208 180 CA31
                JBR     off(00217h).5, freezeframe_flag_225_7_if_ram216_bit3_clr ; 2AF5 1 208 180 DD170A
                CMPB    0c0h, #030h            ; 2AF8 1 208 180 C5C0C030
                MB      off(0022ah).6, C       ; 2AFC 1 208 180 C42A3E
                RC                             ; 2AFF 1 208 180 95
                SJ      freezeframe_flag_225_7_store_carry_ram21a_bit0             ; 2B00 1 208 180 CB22
freezeframe_flag_225_7_if_ram216_bit3_clr:     JBR     off(00216h).3, freezeframe_flag_225_7_if_ram21a_bit3_set ; 2B02 1 208 180 DB1603
                JBR     off(00211h).5, freezeframe_flag_225_7_set_carry ; 2B05 1 208 180 DD111B
freezeframe_flag_225_7_if_ram21a_bit3_set:     JBS     off(0021ah).3, freezeframe_flag_225_7_set_carry ; 2B08 1 208 180 EB1A18
                CMPB    off(00236h), #080h     ; 2B0B 1 208 180 C436C080
                JGE     freezeframe_flag_225_7_set_carry             ; 2B0F 1 208 180 CD12
                LB      A, #0feh               ; 2B11 0 208 180 77FE
                JBR     off(0022ah).6, freezeframe_flag_225_7_cmp_acc ; 2B13 0 208 180 DE2A02
                LB      A, #0feh               ; 2B16 0 208 180 77FE
freezeframe_flag_225_7_cmp_acc:     CMPB    A, 0e9h                ; 2B18 0 208 180 C5E9C2
                JGE     freezeframe_flag_225_7_load_x1             ; 2B1B 0 208 180 CD0A
                CMPB    0c1h, #03bh            ; 2B1D 0 208 180 C5C1C03B
                JGE     freezeframe_flag_225_7_load_x1             ; 2B21 0 208 180 CD04
freezeframe_flag_225_7_set_carry:     SC                             ; 2B23 1 208 180 85
freezeframe_flag_225_7_store_carry_ram21a_bit0:     MB      off(0021ah).0, C       ; 2B24 1 208 180 C41A38
freezeframe_flag_225_7_load_x1:     MOV     X1, #ZoneIndexTable1_SetA          ; 2B27 1 208 180 605E66
                MOV     X2, #ZoneIndexTable2_SetA          ; 2B2A 1 208 180 61CA66
                JBS     off(00216h).3, freezeframe_flag_225_7_load_ram0c1 ; 2B2D 1 208 180 EB1606
                MOV     X1, #ZoneIndexTable1_SetB          ; 2B30 1 208 180 604366
                MOV     X2, #ZoneIndexTable2_SetB          ; 2B33 1 208 180 61AF66
freezeframe_flag_225_7_load_ram0c1:     LB      A, 0c1h                ; 2B36 0 208 180 F5C1
                VCAL    1                      ; 2B38 0 208 180 11
                STB     A, off(00276h)         ; 2B39 0 208 180 D476
                MOV     X1, X2                 ; 2B3B 0 208 180 9178
                LB      A, 0c1h                ; 2B3D 0 208 180 F5C1
                VCAL    1                      ; 2B3F 0 208 180 11
                STB     A, off(00278h)         ; 2B40 0 208 180 D478
                LB      A, 0c1h                ; 2B42 0 208 180 F5C1
                STB     A, r0                  ; 2B44 0 208 180 88
                NOP                            ; 2B45 0 208 180 00
                NOP                            ; 2B46 0 208 180 00
                NOP                            ; 2B47 0 208 180 00
                NOP                            ; 2B48 0 208 180 00
                NOP                            ; 2B49 0 208 180 00
                NOP                            ; 2B4A 0 208 180 00
                NOP                            ; 2B4B 0 208 180 00
                NOP                            ; 2B4C 0 208 180 00
                NOP                            ; 2B4D 0 208 180 00
                MOV     X1, #IdleVsECT          ; 2B4E 0 208 180 60E566
                MOV     X2, #freezeframe_flag_225_7_tbl          ; 2B51 0 208 180 610F67
                MOVB    r2, #034h              ; 2B54 0 208 180 9A34
                CMPB    A, #016h               ; 2B56 0 208 180 C616
                JGE     idle_ectvs_check2             ; 2B58 0 208 180 CD0B
idle_ectvs_result1_load_r1:     MOVB    r1, r2                 ; 2B5A 0 208 180 2249
                L       A, #0090bh             ; 2B5C 1 208 180 670B09
                MOV     er3, #00480h           ; 2B5F 1 208 180 47988004
                SJ      idle_target_correction_start             ; 2B63 1 208 180 CB54
idle_ectvs_check2:     CMPB    A, r2                  ; 2B65 0 208 180 4A
                JGE     idle_ectvs_result3             ; 2B66 0 208 180 CD4D
                MOVB    r1, #030h              ; 2B68 0 208 180 9930
                J       cfg_selector3_dispatch             ; 2B6A 0 208 180 03D277
cfg_selector3_dispatch_goto_5802:     J       cfg_selector3_dispatch_cmp_ram280             ; 2B6D 0 208 180 030258
cfg_selector3_dispatch_if_ge_goto_idle_ectvs_result3:     JGE     idle_ectvs_result3             ; 2B72 0 208 180 CD41
idle_ectvs_result2:     L       A, #009c4h             ; 2B74 1 208 180 67C409
                MOV     er3, #00280h           ; 2B77 1 208 180 47988002
                SJ      idle_target_correction_start             ; 2B7B 1 208 180 CB3C
cfg_selector3_dispatch_goto_idle_ectvs_result1:     J       idle_ectvs_result1             ; 2B7D 0 208 180 03775E
idle_ectvs_result1_cmp_acc:     CMPB    A, r1                  ; 2B80 0 208 180 49
                JGE     idle_ectvs_result3             ; 2B81 0 208 180 CD32
                L       A, off(00270h)         ; 2B83 1 208 180 E470
                JEQ     idle_ectvs_flag_check             ; 2B85 1 208 180 C904
                MOVB    off(002d5h), #01eh     ; 2B87 1 208 180 C4D5981E
idle_ectvs_flag_check:     LB      A, off(002d5h)         ; 2B8B 0 208 180 F4D5
                JNE     idle_ectvs_result2             ; 2B8D 0 208 180 CEE5
                J       idle_ectvs_flag_check_if_ram22a_bit4_clr             ; 2B8F 0 208 180 03975E
idle_ectvs_flag_check_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_ectvs_flag_check_load_r1 ; 2B92 0 208 180 DB1610
                MOVB    r1, #02dh              ; 2B95 0 208 180 992D
                LB      A, r0                  ; 2B97 0 208 180 78
                CMPB    A, r1                  ; 2B98 0 208 180 49
                JGE     idle_ectvs_result3             ; 2B99 0 208 180 CD1A
                L       A, #00a77h             ; 2B9B 1 208 180 67770A
                MOV     er3, #00100h           ; 2B9E 1 208 180 47980001
                JBS     off(00211h).5, idle_target_correction_start ; 2BA2 1 208 180 ED1114
idle_ectvs_flag_check_load_r1:     MOVB    r1, #02dh              ; 2BA5 1 208 180 992D
                LB      A, r0                  ; 2BA7 0 208 180 78
                CMPB    A, r1                  ; 2BA8 0 208 180 49
                JGE     idle_ectvs_result3             ; 2BA9 0 208 180 CD0A
                L       A, #00a77h             ; 2BAB 1 208 180 67770A
                MOV     er3, #00100h           ; 2BAE 1 208 180 47980001
                JBS     off(00225h).1, idle_target_correction_start ; 2BB2 1 208 180 E92504
idle_ectvs_result3:     LB      A, r0                  ; 2BB5 0 208 180 78
                VCAL    1                      ; 2BB6 0 208 180 11
                CLR     er3                    ; 2BB7 0 208 180 4715
idle_target_correction_start:     MOV     DP, A                  ; 2BB9 1 208 180 52
                NOP                            ; 2BBA 1 208 180 00
                L       A, er3                 ; 2BBB 1 208 180 37
                JEQ     to_idle_step_condition_dispatch             ; 2BBC 1 208 180 C91C
                MOV     X1, #IdleVsECT          ; 2BBE 1 208 180 60E566
                LCB     A, 0000fh[X1]          ; 2BC1 1 208 180 90AB0F00
                MOVB    r4, A                  ; 2BC5 1 208 180 248A
                SUBB    r0, A                  ; 2BC7 1 208 180 20A1
                L       A, er3                 ; 2BC9 1 208 180 37
                JLE     to_idle_step_condition_dispatch             ; 2BCA 1 208 180 CF0E
                CLRB    A                      ; 2BCC 0 208 180 FA
                STB     A, r5                  ; 2BCD 0 208 180 8D
                XCHGB   A, r1                  ; 2BCE 0 208 180 2110
                CMPB    A, 0c1h                ; 2BD0 0 208 180 C5C1C2
                JLE     idle_target_correction_done_clear_acc             ; 2BD3 0 208 180 CF03
                J       idle_target_correction_done             ; 2BD5 0 208 180 038F57
idle_target_correction_done_clear_acc:     CLR     A                      ; 2BD8 1 208 180 F9
                NOP                            ; 2BD9 1 208 180 00
to_idle_step_condition_dispatch:     J       idle_step_flag_store             ; 2BDA 1 208 180 03B959
idle_step_flag_store_load_ram0c1:     LB      A, 0c1h                ; 2BDE 0 208 180 F5C1
                VCAL    0                      ; 2BE0 0 208 180 10
                STB     A, r2                  ; 2BE1 0 208 180 8A
                MOV     X1, X2                 ; 2BE2 0 208 180 9178
                ADD     X1, #0000eh            ; 2BE4 0 208 180 90800E00
                LB      A, 0c1h                ; 2BE8 0 208 180 F5C1
                VCAL    0                      ; 2BEA 0 208 180 10
                STB     A, ACCH                ; 2BEB 0 208 180 D507
                LB      A, r2                  ; 2BED 0 208 180 7A
                MOV     off(00292h), A         ; 2BEE 0 208 180 B4928A
                L       A, off(00258h)         ; 2BF1 1 208 180 E458
                MOV     X1, #tbl_idle_pid_lo3          ; 2BF3 1 208 180 60C667
                MOV     X2, #tbl_idle_pid_hi3          ; 2BF6 1 208 180 610E68
                CMP     A, #00964h             ; 2BF9 1 208 180 C66409
                JLT     idle_pid_table_select2             ; 2BFC 1 208 180 CA11
                MOV     X1, #tbl_idle_pid_lo2          ; 2BFE 1 208 180 60BA67
                MOV     X2, #tbl_idle_pid_hi2          ; 2C01 1 208 180 61FC67
                CMP     A, #00a08h             ; 2C04 1 208 180 C6080A
                JLT     idle_pid_table_select2             ; 2C07 1 208 180 CA06
                MOV     X1, #tbl_idle_pid_lo1          ; 2C09 1 208 180 60AE67
                MOV     X2, #tbl_idle_pid_hi1          ; 2C0C 1 208 180 61EA67
idle_pid_table_select2:     JBS     off(00217h).6, idle_pid_table_lookup ; 2C0F 1 208 180 EE1711
                MOV     X1, #tbl_idle_pid_b          ; 2C12 1 208 180 60DE67
                MOV     X2, #tbl_idle_pid_d          ; 2C15 1 208 180 613268
                CMP     A, #00964h             ; 2C18 1 208 180 C66409
                JLT     idle_pid_table_lookup             ; 2C1B 1 208 180 CA06
                MOV     X1, #tbl_idle_pid_a          ; 2C1D 1 208 180 60D267
                MOV     X2, #tbl_idle_pid_c          ; 2C20 1 208 180 612068
idle_pid_table_lookup:     LB      A, off(00236h)         ; 2C23 0 208 180 F436
                VCAL    0                      ; 2C25 0 208 180 10
                MOVB    r0, 0c5h               ; 2C26 0 208 180 C5C548
                MULB                           ; 2C29 0 208 180 A234
                L       A, ACC                 ; 2C2B 1 208 180 E506
                ROL     A                      ; 2C2D 1 208 180 33
                LB      A, ACCH                ; 2C2E 0 208 180 F507
                JGE     idle_pid_mul_apply             ; 2C30 0 208 180 CD02
                LB      A, #0ffh               ; 2C32 0 208 180 77FF
idle_pid_mul_apply:     MOV     X1, X2                 ; 2C34 0 208 180 9178
                VCAL    1                      ; 2C36 0 208 180 11
                J       idle_pid_mul_apply_store_r1             ; 2C37 0 208 180 03235E
idle_pid_mul_apply_resume:     JGE     idle_pid_er3_store             ; 2C3A 1 208 180 CD07
                MOVB    r1, #040h              ; 2C3C 1 208 180 9940
                CLRB    r0                     ; 2C3E 1 208 180 2015
                MUL                            ; 2C40 1 208 180 9035
                L       A, er1                 ; 2C42 1 208 180 35
idle_pid_er3_store:     ST      A, er3                 ; 2C43 1 208 180 8B
                JBS     off(0022bh).4, idle_pid_common ; 2C44 1 208 180 EC2B25
                JBS     off(00211h).2, idle_pid_common ; 2C47 1 208 180 EA1122
                JBS     off(0022ah).0, idle_pid_common ; 2C4A 1 208 180 E82A1F
                LB      A, #028h               ; 2C4D 0 208 180 7728
                CLRB    r1                     ; 2C4F 0 208 180 2115
                JBS     off(0022bh).5, idle_pid_recheck2 ; 2C51 0 208 180 ED2B04
                LB      A, #028h               ; 2C54 0 208 180 7728
                MOVB    r1, #000h              ; 2C56 0 208 180 9900
idle_pid_recheck2:     MOVB    r2, 0c6h               ; 2C58 0 208 180 C5C64A
                MB      C, off(0022bh).5       ; 2C5B 0 208 180 C42B2D
                J       idle_pid_recheck2_if_ram217_bit6_clr             ; 2C5E 0 208 180 03485E
idle_pid_hyst_check_if_ge_goto_idle_pid_common:     JGE     idle_pid_common             ; 2C63 0 208 180 CD07
                J       idle_pid_hyst_check_load_carry_pswl_bit4             ; 2C65 0 208 180 03625E
idle_pid_flag_clear:     CLRB    r5                     ; 2C68 0 208 180 2515
                SJ      idle_pid_diff_calc             ; 2C6A 0 208 180 CB16
idle_pid_common:     L       A, off(00268h)         ; 2C6C 1 208 180 E468
                XCHG    A, er3                 ; 2C6E 1 208 180 4710
                MOVB    r5, off(00291h)        ; 2C70 1 208 180 C4914D
                CLRB    r4                     ; 2C73 1 208 180 2415
                MOVB    r1, #030h              ; 2C75 1 208 180 9930
                JBS     off(00217h).6, idle_pid_track_call ; 2C77 1 208 180 EE1702
                MOVB    r1, #030h              ; 2C7A 1 208 180 9930
idle_pid_track_call:     CLRB    r0                     ; 2C7C 1 208 180 2015
                CAL     rpm_accel_track_helper             ; 2C7E 1 208 180 323E4F
                ST      A, er3                 ; 2C81 1 208 180 8B
idle_pid_diff_calc:     L       A, er3                 ; 2C82 1 208 180 37
                SUB     A, off(00268h)         ; 2C83 1 208 180 A768
                ST      A, er0                 ; 2C85 1 208 180 88
                JGE     idle_pid_diff_clamp             ; 2C86 1 208 180 CD01
                VCAL    7                      ; 2C88 1 208 180 17
idle_pid_diff_clamp:     CMP     A, #00030h             ; 2C89 1 208 180 C63000
                JBS     off(00217h).6, idle_pid_diff_zero ; 2C8C 1 208 180 EE1703
                CMP     A, #00030h             ; 2C8F 1 208 180 C63000
idle_pid_diff_zero:     CLR     A                      ; 2C92 1 208 180 F9
                JLT     idle_pid_diff_store             ; 2C93 1 208 180 CA01
                L       A, er0                 ; 2C95 1 208 180 34
idle_pid_diff_store:     ST      A, off(0026ch)         ; 2C96 1 208 180 D46C
                L       A, off(0026ah)         ; 2C98 1 208 180 E46A
                SUB     A, #00000h             ; 2C9A 1 208 180 A60000
                JGE     idle_pid_flag_recheck             ; 2C9D 1 208 180 CD01
                CLR     A                      ; 2C9F 1 208 180 F9
idle_pid_flag_recheck:     CMPB    off(00297h), #000h     ; 2CA0 1 208 180 C497C000
                JEQ     idle_pid_store_final             ; 2CA4 1 208 180 C90C
                L       A, #00000h             ; 2CA6 1 208 180 670000
                JBS     off(00217h).6, idle_pid_decrement ; 2CA9 1 208 180 EE1703
                L       A, #00000h             ; 2CAC 1 208 180 670000
idle_pid_decrement:     DECB    off(00297h)            ; 2CAF 1 208 180 C49717
idle_pid_store_final:     MOV     off(00268h), er3       ; 2CB2 1 208 180 477C68
                ST      A, off(0026ah)         ; 2CB5 1 208 180 D46A
                MOVB    off(00291h), r5        ; 2CB7 1 208 180 257C91
                JBR     off(00226h).4, idle_integrator_check2 ; 2CBA 1 208 180 DC263E
                MOV     X1, #ZoneCorrectionRowSelect_SetA          ; 2CBD 1 208 180 604468
                JBS     off(00216h).3, to_idle_integrator_store ; 2CC0 1 208 180 EB1603
                MOV     X1, #ZoneCorrectionRowSelect_SetB          ; 2CC3 1 208 180 605368
to_idle_integrator_store:     LB      A, 0c0h                ; 2CC6 0 208 180 F5C0
                VCAL    1                      ; 2CC8 0 208 180 11
                SLLB    A                      ; 2CC9 0 208 180 53
                MOV     X2, A                  ; 2CCA 0 208 180 51
                MOV     X1, #ZoneCorrection2DTable          ; 2CCB 0 208 180 606268
                LB      A, off(00236h)         ; 2CCE 0 208 180 F436
                VCAL    0                      ; 2CD0 0 208 180 10
                L       A, ACC                 ; 2CD1 1 208 180 E506
                SWAP                           ; 2CD3 1 208 180 83
                CLRB    A                      ; 2CD4 0 208 180 FA
                MOV     er0, X2                ; 2CD5 0 208 180 9148
                MUL                            ; 2CD7 0 208 180 9035
                L       A, off(00266h)         ; 2CD9 1 208 180 E466
                MOV     DP, #003d0h            ; 2CDB 1 208 180 62D003
                JEQ     idle_integrator_reset             ; 2CDE 1 208 180 C90C
                JBS     off(00267h).7, idle_integrator_reset ; 2CE0 1 208 180 EF6709
                L       A, [DP]                ; 2CE3 1 208 180 E2
                SUB     A, #00004h             ; 2CE4 1 208 180 A60400
                JGE     idle_integrator_store             ; 2CE7 1 208 180 CD06
                CLR     A                      ; 2CE9 1 208 180 F9
                SJ      idle_integrator_store             ; 2CEA 1 208 180 CB03
idle_integrator_reset:     L       A, #00200h             ; 2CEC 1 208 180 670002
idle_integrator_store:     ST      A, [DP]                ; 2CEF 1 208 180 D2
                ADD     A, er1                 ; 2CF0 1 208 180 09
                CMP     A, #08000h             ; 2CF1 1 208 180 C60080
                JLT     idle_integrator_final_store             ; 2CF4 1 208 180 CA18
                L       A, #07fffh             ; 2CF6 1 208 180 67FF7F
                SJ      idle_integrator_final_store             ; 2CF9 1 208 180 CB13
idle_integrator_check2:     L       A, off(00266h)         ; 2CFB 1 208 180 E466
                JEQ     idle_integrator_final_store             ; 2CFD 1 208 180 C90F
                JBR     off(00267h).7, idle_integrator_fault ; 2CFF 1 208 180 DF6708
                ADD     A, #00008h             ; 2D02 1 208 180 860800
                JGE     idle_integrator_final_store             ; 2D05 1 208 180 CD07
                CLR     A                      ; 2D07 1 208 180 F9
                SJ      idle_integrator_final_store             ; 2D08 1 208 180 CB04
idle_integrator_fault:     L       A, #00180h             ; 2D0A 1 208 180 678001
                VCAL    7                      ; 2D0D 1 208 180 17
idle_integrator_final_store:     ST      A, off(00266h)         ; 2D0E 1 208 180 D466
                CLR     A                      ; 2D10 1 208 180 F9
                MOV     DP, A                  ; 2D11 1 208 180 52
                JBR     off(00216h).3, to_idle_output_finalize ; 2D12 1 208 180 DB1603
                J       idle_integrator_final_store_if_ram211_bit5_clr             ; 2D15 1 208 180 03F85C
to_idle_output_finalize:     MOVB    off(002d4h), #014h     ; 2D18 1 208 180 C4D49814
                SJ      idle_output_finalize             ; 2D1C 1 208 180 CB33
idle_integrator_final_store_cmp_ram0c1:     CMPB    0c1h, #03ah            ; 2D1E 1 208 180 C5C1C03A
                JLT     inc_dp_step_load_ram0c1             ; 2D22 1 208 180 CA13
                LB      A, off(002d4h)         ; 2D24 0 208 180 F4D4
                JEQ     inc_dp_step             ; 2D26 0 208 180 C90E
                JBS     off(0021bh).6, idle_integrator_final_store_load_ram264 ; 2D28 0 208 180 EE1B07
                CMP     0aeh, #00004h          ; 2D2B 0 208 180 B5AEC00400
                JGE     inc_dp_step             ; 2D30 0 208 180 CD04
idle_integrator_final_store_load_ram264:     L       A, off(00264h)         ; 2D32 1 208 180 E464
                JEQ     idle_output_finalize_srl_dp             ; 2D34 1 208 180 C91D
inc_dp_step:     INC     DP                     ; 2D36 1 208 180 72
inc_dp_step_load_ram0c1:     LB      A, 0c1h                ; 2D37 0 208 180 F5C1
                MOV     X1, #inc_dp_step_tbl          ; 2D39 0 208 180 606C68
                VCAL    1                      ; 2D3C 0 208 180 11
                MOV     X2, A                  ; 2D3D 0 208 180 51
                CMPB    0c1h, #034h            ; 2D3E 0 208 180 C5C1C034
                JGE     load_x2_result             ; 2D42 0 208 180 CD0C
                MOV     X1, #inc_dp_step_tbl_2          ; 2D44 0 208 180 608768
                L       A, off(00258h)         ; 2D47 1 208 180 E458
                CAL     table_interp_lookup_4byte             ; 2D49 1 208 180 32FE4E
                CMP     A, X2                  ; 2D4C 1 208 180 91C2
                JGE     idle_output_finalize             ; 2D4E 1 208 180 CD01
load_x2_result:     L       A, X2                  ; 2D50 1 208 180 41
idle_output_finalize:     ST      A, off(00264h)         ; 2D51 1 208 180 D464
idle_output_finalize_srl_dp:     SRL     DP                     ; 2D53 1 208 180 92E7
                MB      off(0022ah).7, C       ; 2D55 1 208 180 C42A3F
                CLRB    A                      ; 2D58 0 208 180 FA
                RC                             ; 2D59 0 208 180 95
                JBS     off(00217h).5, idle_pid_result_store ; 2D5A 0 208 180 ED171C
                JBR     off(0022bh).2, idle_pid_gate4 ; 2D5D 0 208 180 DA2B13
                JBR     off(00210h).3, idle_pid_gate5 ; 2D60 0 208 180 DB1013
                MOV     X1, #00100h            ; 2D63 0 208 180 600001
                LB      A, off(00295h)         ; 2D66 0 208 180 F495
                JEQ     idle_pid_x1_select             ; 2D68 0 208 180 C906
                DECB    off(00295h)            ; 2D6A 0 208 180 C49517
                MOV     X1, #00800h            ; 2D6D 0 208 180 600008
idle_pid_x1_select:     L       A, X1                  ; 2D70 1 208 180 40
                SJ      idle_pid_output_store             ; 2D71 1 208 180 CB0C
idle_pid_gate4:     JBS     off(00210h).3, idle_pid_zero_flag ; 2D73 0 208 180 EB1008
idle_pid_gate5:     SC                             ; 2D76 0 208 180 85
                LB      A, #005h               ; 2D77 0 208 180 7705
idle_pid_result_store:     MB      off(0022bh).2, C       ; 2D79 0 208 180 C42B3A
                STB     A, off(00295h)         ; 2D7C 0 208 180 D495
idle_pid_zero_flag:     CLR     A                      ; 2D7E 1 208 180 F9
idle_pid_output_store:     ST      A, off(00270h)         ; 2D7F 1 208 180 D470
                MOV     X1, #ModeToPageTable          ; 2D81 1 208 180 60A768
                LB      A, off(00236h)         ; 2D84 0 208 180 F436
                VCAL    1                      ; 2D86 0 208 180 11
                MOV     DP, A                  ; 2D87 0 208 180 52
                MOV     X1, #ModePageTable_SetA          ; 2D88 0 208 180 609B68
                JBS     off(00216h).3, vcal2_scale_multiply ; 2D8B 0 208 180 EB1603
                MOV     X1, #ModePageTable_SetB          ; 2D8E 0 208 180 60A168
vcal2_scale_multiply:     LB      A, 0bdh                ; 2D91 0 208 180 F5BD
                VCAL    3                      ; 2D93 0 208 180 13
                LB      A, off(002e1h)         ; 2D94 0 208 180 F4E1
                MOV     A, off(00262h)         ; 2D96 1 208 180 B46299
                JNE     idle_sub_gate2             ; 2D99 1 208 180 CE2A
                MOVB    off(002e1h), #003h     ; 2D9B 1 208 180 C4E19803
                JBR     off(0021ah).3, idle_sub_common ; 2D9F 1 208 180 DB1A22
                JBS     off(0021bh).1, idle_sub_diff_calc ; 2DA2 1 208 180 E91B05
                ADD     A, er3                 ; 2DA5 1 208 180 0B
                JLT     idle_sub_alt_path             ; 2DA6 1 208 180 CA21
                SJ      idle_sub_range_check1             ; 2DA8 1 208 180 CB03
idle_sub_diff_calc:     SUB     A, er3                 ; 2DAA 1 208 180 2B
                JLT     idle_sub_common             ; 2DAB 1 208 180 CA17
idle_sub_range_check1:     MOV     X2, #00400h            ; 2DAD 1 208 180 610004
                CMP     A, #00a00h             ; 2DB0 1 208 180 C6000A
                JGE     idle_sub_range_result             ; 2DB3 1 208 180 CD0B
                MOV     X2, #00300h            ; 2DB5 1 208 180 610003
                CMP     A, #00400h             ; 2DB8 1 208 180 C60004
                JGE     idle_sub_range_result             ; 2DBB 1 208 180 CD03
                MOV     X2, #00200h            ; 2DBD 1 208 180 610002
idle_sub_range_result:     SUB     A, X2                  ; 2DC0 1 208 180 91A2
                JGE     idle_sub_gate2             ; 2DC2 1 208 180 CD01
idle_sub_common:     CLR     A                      ; 2DC4 1 208 180 F9
idle_sub_gate2:     J       idle_sub_gate2_if_ram216_bit3_set             ; 2DC5 1 208 180 03125D
idle_sub_alt_path:     L       A, DP                  ; 2DC9 1 208 180 42
idle_sub_alt_path_store_ram262:     ST      A, off(00262h)         ; 2DCA 1 208 180 D462
                MOV     X1, #idle_sub_alt_path_tbl_2          ; 2DCC 1 208 180 609267
                LB      A, 0c1h                ; 2DCF 0 208 180 F5C1
                VCAL    0                      ; 2DD1 0 208 180 10
                STB     A, off(00294h)         ; 2DD2 0 208 180 D494
                MB      C, off(0022bh).6       ; 2DD4 0 208 180 C42B2E
                MB      off(0022bh).7, C       ; 2DD7 0 208 180 C42B3F
                MOV     X1, #idle_sub_alt_path_tbl          ; 2DDA 0 208 180 606F67
                LB      A, 0c1h                ; 2DDD 0 208 180 F5C1
                VCAL    0                      ; 2DDF 0 208 180 10
                CMPB    A, off(00236h)         ; 2DE0 0 208 180 C736
                MB      off(0022bh).6, C       ; 2DE2 0 208 180 C42B3E
                JBR     off(0021ah).0, idle_gate6_result ; 2DE5 0 208 180 D81A13
                JLT     idle_gate6_result             ; 2DE8 0 208 180 CA11
                JBR     off(0022bh).7, idle_gate7 ; 2DEA 0 208 180 DF2B14
                JBS     off(0021bh).7, idle_gate6_result ; 2DED 0 208 180 EF1B0B
                MOV     X1, #tbl_idle_gate6          ; 2DF0 0 208 180 607D67
                LB      A, 0c1h                ; 2DF3 0 208 180 F5C1
                VCAL    1                      ; 2DF5 0 208 180 11
                ; warning: had to flip DD
                CMP     A, 0b0h                ; 2DF6 1 208 180 B5B0C2
                JLT     idle_table_lookup2             ; 2DF9 1 208 180 CA0F
idle_gate6_result:     MOVB    off(002e0h), off(00294h) ; 2DFB 1 208 180 C4947CE0
                SJ      idle_flag_zero             ; 2DFF 1 208 180 CB2A
idle_gate7:     L       A, off(00260h)         ; 2E01 1 208 180 E460
                SUB     A, #00040h             ; 2E03 1 208 180 A64000
                JLT     idle_flag_zero             ; 2E06 1 208 180 CA23
                SJ      idle_flag_check3             ; 2E08 1 208 180 CB1B
idle_table_lookup2:     MOV     X1, #idle_table_lookup2_tbl          ; 2E0A 1 208 180 60A067
                LB      A, 0c1h                ; 2E0D 0 208 180 F5C1
                VCAL    0                      ; 2E0F 0 208 180 10
                STB     A, r0                  ; 2E10 0 208 180 88
                CLRB    r1                     ; 2E11 0 208 180 2115
                L       A, 0b0h                ; 2E13 1 208 180 E5B0
                MUL                            ; 2E15 1 208 180 9035
                MOV     er0, #02000h           ; 2E17 1 208 180 44980020
                CMP     er1, #00000h           ; 2E1B 1 208 180 45C00000
                JNE     idle_clamp_min             ; 2E1F 1 208 180 CE03
                CMP     A, er0                 ; 2E21 1 208 180 48
                JLT     idle_flag_check3             ; 2E22 1 208 180 CA01
idle_clamp_min:     L       A, er0                 ; 2E24 1 208 180 34
idle_flag_check3:     CMPB    off(002e0h), #000h     ; 2E25 1 208 180 C4E0C000
                JNE     idle_flag_store             ; 2E29 1 208 180 CE01
idle_flag_zero:     CLR     A                      ; 2E2B 1 208 180 F9
idle_flag_store:     ST      A, off(00260h)         ; 2E2C 1 208 180 D460
                JBR     off(00219h).7, idle_mode_dispatch ; 2E2E 1 208 180 DF1925
                MOV     DP, #0039bh            ; 2E31 1 208 180 629B03
                MOVB    r0, [DP]               ; 2E34 1 208 180 C248
                L       A, #01400h             ; 2E36 1 208 180 670014
                CMPB    r0, #033h              ; 2E39 1 208 180 20C033
                JEQ     idle_gear_select_done             ; 2E3C 1 208 180 C913
                L       A, #02000h             ; 2E3E 1 208 180 670020
                CMPB    r0, #034h              ; 2E41 1 208 180 20C034
                JEQ     idle_gear_select_done             ; 2E44 1 208 180 C90B
                L       A, #02c00h             ; 2E46 1 208 180 67002C
                CMPB    r0, #035h              ; 2E49 1 208 180 20C035
                JEQ     idle_gear_select_done             ; 2E4C 1 208 180 C903
                L       A, #03fffh             ; 2E4E 1 208 180 67FF3F
idle_gear_select_done:     L       A, ACC                 ; 2E51 1 208 180 E506
                J       idle_gear_target_check             ; 2E53 1 208 180 03A631
idle_mode_dispatch:     JBR     off(00217h).5, idle_mode_dispatch2 ; 2E56 1 208 180 DD1713
                SB      off(00228h).4          ; 2E59 1 208 180 C4281C
                MOV     X1, #ZoneIndexTable3_SetA          ; 2E5C 1 208 180 609466
                JBS     off(00216h).3, to_idle_vcal5_call ; 2E5F 1 208 180 EB1603
                MOV     X1, #idle_mode_dispatch_tbl          ; 2E62 1 208 180 607966
to_idle_vcal5_call:     LB      A, 0c1h                ; 2E65 0 208 180 F5C1
                VCAL    1                      ; 2E67 0 208 180 11
                STB     A, off(0027ah)         ; 2E68 0 208 180 D47A
                SJ      idle_vcal5_call             ; 2E6A 0 208 180 CB24
idle_mode_dispatch2:     JBR     off(00218h).2, idle_mode_dispatch3 ; 2E6C 1 208 180 DA1809
                JBR     off(0022ah).2, idle_gear_calc_start ; 2E6F 1 208 180 DA2A64
                L       A, #011ebh             ; 2E72 1 208 180 67EB11
                J       idle_gear_target_final             ; 2E75 1 208 180 03C831
idle_mode_dispatch3:     JBS     off(0021ah).2, idle_mode_dispatch3_if_ram21c_bit4_clr ; 2E78 1 208 180 EA1A1A
                CLR     off(00262h)            ; 2E7B 1 208 180 B46215
                JBR     off(00216h).3, carry_set_flag_gate_0b0 ; 2E7E 1 208 180 DB1645
                JBS     off(00211h).5, carry_set_flag_gate_0b0 ; 2E81 1 208 180 ED1142
                JBR     off(0022ah).7, carry_set_flag_gate_0b0 ; 2E84 1 208 180 DF2A3F
                SB      off(00228h).7          ; 2E87 1 208 180 C4281F
                MOV     er3, off(00260h)       ; 2E8A 1 208 180 B4604B
                L       A, off(00276h)         ; 2E8D 1 208 180 E476
                VCAL    6                      ; 2E8F 1 208 180 16
idle_vcal5_call:     CAL     stub_or_short_helper             ; 2E90 0 208 180 326B51
                SJ      vcal5_call             ; 2E93 0 208 180 CB2B
idle_mode_dispatch3_if_ram21c_bit4_clr:     JBR     off(0021ch).4, idle_gear_calc_start ; 2E95 1 208 180 DC1C3E
                CMPB    0c1h, #02eh            ; 2E98 1 208 180 C5C1C02E
                JGE     idle_gear_calc_start             ; 2E9C 1 208 180 CD38
                CMPB    0b4h, #005h            ; 2E9E 1 208 180 C5B4C005
                JLT     idle_gear_calc_start             ; 2EA2 1 208 180 CA32
                JBR     off(0022ah).1, idle_gear_calc_start ; 2EA4 1 208 180 D92A2F
                MOV     X1, #tbl_ve_map_scalar_alt          ; 2EA7 1 208 180 60B668
                LB      A, 0aah                ; 2EAA 0 208 180 F5AA
                JBS     off(0021fh).1, idle_mode_dispatch3_vcal_1 ; 2EAC 0 208 180 E91F05
                MOV     X1, #tbl_ve_map_scalar          ; 2EAF 0 208 180 60CE68
                LB      A, off(00236h)         ; 2EB2 0 208 180 F436
idle_mode_dispatch3_vcal_1:     VCAL    1                      ; 2EB4 0 208 180 11
                STB     A, off(00274h)         ; 2EB5 0 208 180 D474
                JEQ     idle_gear_calc_start             ; 2EB7 0 208 180 C91D
                SB      off(00228h).6          ; 2EB9 0 208 180 C4281E
                MOV     DP, #0030ch            ; 2EBC 0 208 180 620C03
                L       A, [DP]                ; 2EBF 1 208 180 E2
vcal5_call:     VCAL    6                      ; 2EC0 0 208 180 16
                STB     A, off(0025eh)         ; 2EC1 0 208 180 D45E
                J       idle_stall_check2_if_ram217_bit5_clr             ; 2EC3 0 208 180 03C230
carry_set_flag_gate_0b0:     SC                             ; 2EC6 1 208 180 85
                JBS     off(0022bh).4, idle_direction_toggle ; 2EC7 1 208 180 EC2B06
                MB      C, 098h.1              ; 2ECD 1 208 180 C59829
idle_direction_toggle:     XORB    PSWH, #080h            ; 2ED0 1 208 180 A2F080
                MB      off(00228h).5, C       ; 2ED3 1 208 180 C4283D
idle_gear_calc_start:     CLR     A                      ; 2ED6 1 208 180 F9
                ST      A, er2                 ; 2ED7 1 208 180 8A
                MOV     DP, #0030ch            ; 2ED8 1 208 180 620C03
                MOV     er0, off(00278h)       ; 2EDB 1 208 180 B47848
                MOVB    ACCH, #025h            ; 2EDE 1 208 180 C5079825
                MOVB    r5, #099h              ; 2EE2 1 208 180 9D99
                JBR     off(0021ah).0, idle_gear_mul_apply ; 2EE4 1 208 180 D81A18
                MOV     er0, off(00276h)       ; 2EE7 1 208 180 B47648
                MOVB    ACCH, #052h            ; 2EEA 1 208 180 C5079852
                MOVB    r5, #090h              ; 2EEE 1 208 180 9D90
                JBR     off(00228h).5, idle_gear_mul_apply ; 2EF0 1 208 180 DD280C
                JBR     off(0021ah).3, idle_gear_mul_apply ; 2EF3 1 208 180 DB1A09
                CMPB    0c1h, #034h            ; 2EF6 1 208 180 C5C1C034
                JGE     idle_gear_mul_apply             ; 2EFA 1 208 180 CD03
                J       idle_gear_calc_start_load_dp_ind             ; 2EFC 1 208 180 030857
idle_gear_mul_apply:     MUL                            ; 2EFF 1 208 180 9035
                SLL     A                      ; 2F01 1 208 180 53
                L       A, er1                 ; 2F02 1 208 180 35
                J       idle_gear_mul_apply_rol_acc             ; 2F03 1 208 180 031357
idle_gear_mul_apply_add_acc:     ADD     A, [DP]                ; 2F06 1 208 180 B282
                JGE     idle_gear_clamp_max             ; 2F08 1 208 180 CD03
idle_gear_clamp:     L       A, #0ffffh             ; 2F0A 1 208 180 67FFFF
idle_gear_clamp_max:     SUB     A, #00a00h             ; 2F0D 1 208 180 A6000A
                JGE     idle_gear_result_store             ; 2F10 1 208 180 CD01
                CLR     A                      ; 2F12 1 208 180 F9
idle_gear_result_store:     ST      A, off(0028eh)         ; 2F13 1 208 180 D48E
                L       A, er2                 ; 2F15 1 208 180 36
                MUL                            ; 2F16 1 208 180 9035
                SLL     A                      ; 2F18 1 208 180 53
                L       A, er1                 ; 2F19 1 208 180 35
                J       idle_gear_result_store_rol_acc             ; 2F1A 1 208 180 032057
idle_gear_result_store_add_acc:     ADD     A, #01000h             ; 2F1D 1 208 180 860010
                JGE     idle_gear2_store             ; 2F20 1 208 180 CD03
idle_gear2_clamp:     L       A, #0ffffh             ; 2F22 1 208 180 67FFFF
idle_gear2_store:     ST      A, off(0028ch)         ; 2F25 1 208 180 D48C
                MOVB    r0, #030h              ; 2F27 1 208 180 9830
                MOV     DP, #tbl_idle_gear2          ; 2F29 1 208 180 625F67
                JBR     off(00228h).5, idle_timer_gate1 ; 2F2C 1 208 180 DD2809
                JBS     off(0021ah).4, idle_timer_gate_common ; 2F2F 1 208 180 EC1A0E
                MOVB    off(00296h), #028h     ; 2F32 1 208 180 C4969828
                SJ      idle_timer_gate_common             ; 2F36 1 208 180 CB08
idle_timer_gate1:     J       idle_timer_gate1_if_ram218_bit2_clr             ; 2F38 1 208 180 03335D
idle_timer_gate1_if_ram21a_bit5_set:     JBS     off(0021ah).5, idle_table_select2 ; 2F3B 1 208 180 ED1A45
                SJ      idle_timer_store             ; 2F3E 1 208 180 CB46
idle_timer_gate_common:     JBS     off(0021ah).3, idle_table_select2 ; 2F40 1 208 180 EB1A40
                JBS     off(0021ah).0, idle_table_select1 ; 2F43 1 208 180 E81A0E
                CMPB    0e9h, #032h            ; 2F46 1 208 180 C5E9C032
                JGE     idle_table_select1             ; 2F4A 1 208 180 CD08
                JBR     off(0021ah).5, idle_timer_store ; 2F4C 1 208 180 DD1A37
                MOV     DP, #tbl_idle_timer          ; 2F4F 1 208 180 625367
                SJ      idle_timer_store             ; 2F52 1 208 180 CB32
idle_table_select1:     LB      A, off(002d6h)         ; 2F54 0 208 180 F4D6
                JEQ     idle_table_select_default             ; 2F56 0 208 180 C905
                MOV     DP, #idle_table_select1_tbl          ; 2F58 0 208 180 626567
                SJ      idle_flag_gate             ; 2F5B 0 208 180 CB2C
idle_table_select_default:     MOV     DP, #tbl_idle_select_default          ; 2F5D 0 208 180 624D67
                MOV     X1, #tbl_idle_default1          ; 2F60 0 208 180 604C5D
                JBR     off(0021ah).5, idle_table_lookup3 ; 2F63 0 208 180 DD1A03
                MOV     X1, #tbl_idle_default2          ; 2F66 0 208 180 60685D
idle_table_lookup3:     J       idle_table_lookup3_load_ram258             ; 2F69 0 208 180 03415D
idle_table_lookup3_if_lt_goto_idle_table_lookup4:     JLT     idle_table_lookup4             ; 2F6C 1 208 180 CA03
                MOV     DP, #tbl_idle_lookup3          ; 2F6E 1 208 180 624767
idle_table_lookup4:     J       idle_table_lookup4_load_x1             ; 2F71 1 208 180 03845D
idle_table_lookup4_if_ram21a_bit5_clr:     JBR     off(0021ah).5, idle_flag_gate ; 2F74 1 208 180 DD1A12
                CMP     A, 0b2h                ; 2F77 1 208 180 B5B2C2
                JGE     idle_flag_gate             ; 2F7A 1 208 180 CD0D
                LB      A, off(00296h)         ; 2F7C 0 208 180 F496
                JEQ     idle_flag_gate             ; 2F7E 0 208 180 C909
                SUBB    A, #001h               ; 2F80 0 208 180 A601
                STB     A, r0                  ; 2F82 0 208 180 88
idle_table_select2:     MOV     DP, #tbl_idle_select1          ; 2F83 1 208 180 625967
idle_timer_store:     MOVB    off(00296h), r0        ; 2F86 1 208 180 207C96
idle_flag_gate:     J       idle_flag_gate_load_ram2dc             ; 2F89 1 208 180 03BD5D
idle_flag_gate_load_ram289:     MOVB    off(00289h), off(00288h) ; 2F8D 0 208 180 C4887C89
                J       idle_flag_gate_set_ram22b_bit1             ; 2F91 0 208 180 03CF59
idle_flag_gate_if_ram228_bit5_set:     JBS     off(00228h).5, idle_flag_gate_if_ram21a_bit4_set ; 2F94 0 208 180 ED280D
                JBS     off(0021ah).4, idle_mode_gate6_load_ram278 ; 2F97 0 208 180 EC1A23
                L       A, off(00276h)         ; 2F9A 1 208 180 E476
                JBS     off(00223h).5, idle_pi_mul1 ; 2F9C 1 208 180 ED234E
                JBR     off(0021ah).0, idle_pi_mul1 ; 2F9F 1 208 180 D81A4B
                SJ      idle_mode_gate5_goto_5a03             ; 2FA2 1 208 180 CB30
idle_flag_gate_if_ram21a_bit4_set:     JBS     off(0021ah).4, idle_mode_gate6 ; 2FA4 0 208 180 EC1A07
                J       idle_flag_gate_set_pswl_bit4             ; 2FA7 0 208 180 03D759
idle_mode_gate5:     L       A, off(0027ah)         ; 2FAA 1 208 180 E47A
                SJ      idle_mode_gate5_goto_5a03             ; 2FAC 1 208 180 CB26
idle_mode_gate6:     JBR     off(00216h).3, idle_mode_gate6_if_ram229_bit5_set ; 2FAE 0 208 180 DB1603
                JBS     off(00229h).4, idle_mode_gate6_load_ram278 ; 2FB1 0 208 180 EC2909
idle_mode_gate6_if_ram229_bit5_set:     JBS     off(00229h).5, idle_mode_gate6_load_ram278 ; 2FB4 0 208 180 ED2906
                J       idle_mode_gate6_if_ram22b_bit3_clr             ; 2FB7 0 208 180 03CB5D
idle_mode_gate6_if_ram229_bit6_clr:     JBR     off(00229h).6, idle_pi_mul1 ; 2FBA 0 208 180 DE2930
idle_mode_gate6_load_ram278:     L       A, off(00278h)         ; 2FBD 1 208 180 E478
                JBR     off(0021ah).0, idle_mode_gate5_goto_5a03 ; 2FBF 1 208 180 D81A12
                L       A, off(00276h)         ; 2FC2 1 208 180 E476
                J       idle_mode_gate6_if_ram216_bit3_clr             ; 2FC4 1 208 180 03E259
idle_mode_gate6_store_er3:     ST      A, er3                 ; 2FCD 1 208 180 8B
                CAL     stub_or_short_helper             ; 2FCE 1 208 180 326B51
idle_mode_gate5_vcal_6:     VCAL    6                      ; 2FD1 1 208 180 16
                SJ      idle_mode_gate5_load_er3             ; 2FD2 1 208 180 CB05
idle_mode_gate5_goto_5a03:     J       idle_mode_gate5_store_er3             ; 2FD4 1 208 180 03035A
idle_mode_gate5_load_er3:     MOV     er3, off(00268h)       ; 2FD9 1 208 180 B4684B
                VCAL    6                      ; 2FDC 1 208 180 16
                ST      A, off(00284h)         ; 2FDD 1 208 180 D484
                ST      A, off(00286h)         ; 2FDF 1 208 180 D486
                CLRB    A                      ; 2FE1 0 208 180 FA
                STB     A, off(00288h)         ; 2FE2 0 208 180 D488
                STB     A, off(00289h)         ; 2FE4 0 208 180 D489
                CLR     A                      ; 2FE6 1 208 180 F9
                ST      A, er1                 ; 2FE7 1 208 180 89
                ST      A, er2                 ; 2FE8 1 208 180 8A
                MOV     X1, A                  ; 2FE9 1 208 180 50
                MOV     X2, A                  ; 2FEA 1 208 180 51
                SJ      idle_vcal4_call             ; 2FEB 1 208 180 CB25
idle_pi_mul1:     MOV     er0, 0b0h              ; 2FED 1 208 180 B5B048
                LC      A, [DP]                ; 2FF0 1 208 180 92A8
                MUL                            ; 2FF2 1 208 180 9035
                L       A, er1                 ; 2FF4 1 208 180 35
                JBR     off(0021bh).7, idle_pi_mul2 ; 2FF5 1 208 180 DF1B01
                VCAL    7                      ; 2FF8 1 208 180 17
idle_pi_mul2:     MOV     X1, A                  ; 2FF9 1 208 180 50
                MOV     er0, 0b2h              ; 2FFA 1 208 180 B5B248
                INC     DP                     ; 2FFD 1 208 180 72
                INC     DP                     ; 2FFE 1 208 180 72
                LC      A, [DP]                ; 2FFF 1 208 180 92A8
                MUL                            ; 3001 1 208 180 9035
                L       A, er1                 ; 3003 1 208 180 35
                JBR     off(0021ah).5, idle_pi_mul3 ; 3004 1 208 180 DD1A01
                VCAL    7                      ; 3007 1 208 180 17
idle_pi_mul3:     MOV     X2, A                  ; 3008 1 208 180 51
                INC     DP                     ; 3009 1 208 180 72
                INC     DP                     ; 300A 1 208 180 72
                LC      A, [DP]                ; 300B 1 208 180 92A8
                MUL                            ; 300D 1 208 180 9035
                ST      A, er2                 ; 300F 1 208 180 8A
                L       A, off(0026ch)         ; 3010 1 208 180 E46C
idle_vcal4_call:     MOV     er3, off(00284h)       ; 3012 1 208 180 B4844B
                VCAL    5                      ; 3015 1 208 180 15
                LB      A, off(00288h)         ; 3016 0 208 180 F488
                JBS     off(0021ah).5, idle_integrator_sub ; 3018 0 208 180 ED1A0B
                ADDB    A, r5                  ; 301B 0 208 180 0D
                STB     A, r5                  ; 301C 0 208 180 8D
                L       A, er3                 ; 301D 1 208 180 37
                ADC     A, er1                 ; 301E 1 208 180 19
                JGE     idle_integrator_result             ; 301F 1 208 180 CD0C
                L       A, #0ffffh             ; 3021 1 208 180 67FFFF
                SJ      idle_integrator_result             ; 3024 1 208 180 CB07
idle_integrator_sub:     SUBB    A, r5                  ; 3026 0 208 180 2D
                STB     A, r5                  ; 3027 0 208 180 8D
                L       A, er3                 ; 3028 1 208 180 37
                SBC     A, er1                 ; 3029 1 208 180 39
                JGE     idle_integrator_result             ; 302A 1 208 180 CD01
                CLR     A                      ; 302C 1 208 180 F9
idle_integrator_result:     CAL     idle_pi_clamp_helper             ; 302D 1 208 180 327551
                ST      A, er1                 ; 3030 1 208 180 89
                ST      A, er3                 ; 3031 1 208 180 8B
                JLT     idle_pi_store_p             ; 3032 1 208 180 CA0C
                L       A, X1                  ; 3034 1 208 180 40
                VCAL    5                      ; 3035 1 208 180 15
                L       A, X2                  ; 3036 1 208 180 41
                VCAL    5                      ; 3037 1 208 180 15
                CAL     idle_pi_clamp_helper             ; 3038 1 208 180 327551
                JLT     idle_pi_result_common             ; 303B 1 208 180 CA06
                MOVB    off(00288h), r5        ; 303D 1 208 180 257C88
idle_pi_store_p:     MOV     off(00284h), er1       ; 3040 1 208 180 457C84
idle_pi_result_common:     ST      A, er3                 ; 3043 1 208 180 8B
                L       A, off(00260h)         ; 3044 1 208 180 E460
                JBS     off(00228h).5, idle_vcal5_call3 ; 3046 1 208 180 ED2802
                L       A, off(00262h)         ; 3049 1 208 180 E462
idle_vcal5_call3:     VCAL    6                      ; 304B 1 208 180 16
                ST      A, off(0025eh)         ; 304C 1 208 180 D45E
                CLR     A                      ; 304E (skeleton: fault flags are always clear)
                JBR     off(00228h).5, idle_stall_check2_if_ram217_bit5_clr ; 3059 1 208 180 DD2866
                JBS     off(0021ah).3, idle_stall_check2_if_ram217_bit5_clr ; 305C 1 208 180 EB1A63
                J       idle_vcal5_call3_if_ram21a_bit0_clr             ; 305F 1 208 180 032D57
idle_vcal5_call3_goto_5b4f:     J       idle_vcal5_call3_load_ram27c             ; 3062 1 208 180 034F5B
idle_vcal5_call3_goto_5f09:     J       idle_vcal5_call3_load_ram266             ; 3066 1 208 180 03095F
idle_vcal5_call3_cmp_ram0a6:     CMPB    0a6h, #070h            ; 3069 1 208 180 C5A6C070
                JLT     idle_stall_check2_if_ram217_bit5_clr             ; 306D 1 208 180 CA53
                CMP     0b0h, #00018h          ; 306F 1 208 180 B5B0C01800
                JGE     idle_stall_check2_if_ram217_bit5_clr             ; 3074 1 208 180 CD4C
                L       A, #00040h             ; 3076 1 208 180 674000
                JBR     off(0021ah).5, idle_stall_check2 ; 3079 1 208 180 DD1A03
                L       A, #00040h             ; 307C 1 208 180 674000
idle_stall_check2:     CMP     A, 0b2h                ; 307F 1 208 180 B5B2C2
                JLT     idle_stall_check2_if_ram217_bit5_clr             ; 3082 1 208 180 CA3E
                CMPB    0c1h, #067h            ; 3084 1 208 180 C5C1C067
                J       idle_stall_check2_if_ge_goto_5a16             ; 3088 1 208 180 030B5A
idle_stall_check2_load_x1:     MOV     X1, #tbl_idle_stall          ; 308C 0 208 180 606B67
                VCAL    2                      ; 308F 0 208 180 12
                LB      A, #0a8h               ; 3090 0 208 180 77A8
                JBS     off(00216h).3, sub_r6_clamp_zero ; 3092 0 208 180 EB1602
                LB      A, #0b8h               ; 3095 0 208 180 77B8
sub_r6_clamp_zero:     SUBB    A, r6                  ; 3097 0 208 180 2E
                JGE     idle_stall_er0_select1             ; 3098 0 208 180 CD01
                CLRB    A                      ; 309A 0 208 180 FA
idle_stall_er0_select1:     MOV     er0, #00040h           ; 309B 0 208 180 44984000
                CMPB    A, 0a6h                ; 309F 0 208 180 C5A6C2
                JLT     idle_stall_er0_select2             ; 30A2 0 208 180 CA04
                MOV     er0, #00010h           ; 30A4 0 208 180 44981000
idle_stall_er0_select2:     CMPB    0c1h, #028h            ; 30A8 0 208 180 C5C1C028
                JLT     idle_stall_diff_calc             ; 30AC 0 208 180 CA04
                MOV     er0, #00001h           ; 30AE 0 208 180 44980100
idle_stall_diff_calc:     MOV     X1, #0030ch            ; 30B2 0 208 180 600C03
                J       idle_stall_diff_calc_load_ram284             ; 30B5 0 208 180 034157
idle_stall_diff_calc_if_ge_goto_30bc:     JGE     idle_stall_diff_calc_call_injtimer_bank_calc1             ; 30B9 1 208 180 CD01
idle_stall_diff_calc_clear_acc:     CLR     A                      ; 30BB 1 208 180 F9
idle_stall_diff_calc_call_injtimer_bank_calc1:     CAL     injtimer_bank_calc1             ; 30BC 1 208 180 32514F
                CAL     idle_stall_helper             ; 30BF 1 208 180 32CD50
idle_stall_check2_if_ram217_bit5_clr:     JBR     off(00217h).5, idle_stall_check2_cmp_ram0e8 ; 30C2 0 208 180 DD1708
                LB      A, 0c1h                ; 30C5 0 208 180 F5C1
                MOV     X1, #idle_stall_check2_tbl          ; 30C7 0 208 180 60E668
                VCAL    1                      ; 30CA 0 208 180 11
                SJ      idle_stall_check2_store_ram27c             ; 30CB 0 208 180 CB1E
idle_stall_check2_cmp_ram0e8:     CMPB    0e8h, #00ch            ; 30CD 0 208 180 C5E8C00C
                JGE     idle_stall_check2_clear_acc             ; 30D1 0 208 180 CD17
                MOV     X1, #idle_stall_check2_tbl_2          ; 30D3 0 208 180 60F868
                JBR     off(00228h).5, idle_stall_check2_load_x1_2 ; 30D6 0 208 180 DD2806
                LB      A, off(00236h)         ; 30D9 0 208 180 F436
                CMPB    A, off(00292h)         ; 30DB 0 208 180 C792
                JGE     idle_stall_check2_load_ram0c1             ; 30DD 0 208 180 CD03
idle_stall_check2_load_x1_2:     MOV     X1, #idle_stall_check2_tbl_3          ; 30DF 0 208 180 600A69
idle_stall_check2_load_ram0c1:     LB      A, 0c1h                ; 30E2 0 208 180 F5C1
                VCAL    1                      ; 30E4 0 208 180 11
                L       A, off(0027ch)         ; 30E5 1 208 180 E47C
                SUB     A, er3                 ; 30E7 1 208 180 2B
                JGE     idle_stall_check2_store_ram27c             ; 30E8 1 208 180 CD01
idle_stall_check2_clear_acc:     CLR     A                      ; 30EA 1 208 180 F9
idle_stall_check2_store_ram27c:     ST      A, off(0027ch)         ; 30EB 1 208 180 D47C
                LB      A, 0c0h                ; 30ED 0 208 180 F5C0
                MOV     X1, #idle_stall_check2_tbl_4          ; 30EF 0 208 180 601C69
                VCAL    1                      ; 30F2 0 208 180 11
                STB     A, off(0027eh)         ; 30F3 0 208 180 D47E
                L       A, off(00264h)         ; 30F5 1 208 180 E464
                MOV     er3, off(0026ah)       ; 30F7 1 208 180 B46A4B
                VCAL    6                      ; 30FA 1 208 180 16
                L       A, off(0026eh)         ; 30FB 1 208 180 E46E
                VCAL    6                      ; 30FD 1 208 180 16
                L       A, off(00270h)         ; 30FE 1 208 180 E470
                VCAL    6                      ; 3100 1 208 180 16
                L       A, off(0027eh)         ; 3101 1 208 180 E47E
                VCAL    6                      ; 3103 1 208 180 16
                L       A, off(0027ch)         ; 3104 1 208 180 E47C
                VCAL    6                      ; 3106 1 208 180 16
                L       A, off(00266h)         ; 3107 1 208 180 E466
                CMP     A, #08000h             ; 3109 1 208 180 C60080
                JGE     idle_target_clamp1             ; 310C 1 208 180 CD05
                ADD     A, er3                 ; 310E 1 208 180 0B
                JGE     idle_target_clamp2             ; 310F 1 208 180 CD05
                SJ      idle_target_clamp_max             ; 3111 1 208 180 CB08
idle_target_clamp1:     ADD     A, er3                 ; 3113 1 208 180 0B
                JGE     idle_target_final_store             ; 3114 1 208 180 CD08
idle_target_clamp2:     CMP     A, #08000h             ; 3116 1 208 180 C60080
                JLT     idle_target_final_store             ; 3119 1 208 180 CA03
idle_target_clamp_max:     L       A, #07fffh             ; 311B 1 208 180 67FF7F
idle_target_final_store:     ST      A, off(00280h)         ; 311E 1 208 180 D480
                JBS     off(00217h).5, idle_output_gate2 ; 3120 1 208 180 ED172C
                J       idle_target_final_store_load_er3 ; 3123 (skeleton: fault flags are always clear)
idle_target_final_store_load_er3:     MOV     er3, #00600h           ; 3135 1 208 180 47980006
                CAL     stub_or_short_helper             ; 3139 1 208 180 326B51
                VCAL    6                      ; 313C 1 208 180 16
                MB      C, 098h.1              ; 313D 1 208 180 C59829
                JLT     idle_output_common             ; 3140 1 208 180 CA18
                MOV     er3, off(00276h)       ; 3145 1 208 180 B4764B
                J       idle_target_final_store_call_stub_or_short_helper             ; 3148 1 208 180 034577
idle_output_vcal5:     VCAL    6                      ; 314B 1 208 180 16
                JBS     off(0022bh).4, idle_output_common ; 314C 1 208 180 EC2B0B
idle_output_gate2:     L       A, off(0025eh)         ; 314F 1 208 180 E45E
                JBS     off(00228h).6, idle_pi_final_calc ; 3151 1 208 180 EE2810
                CLR     off(00274h)            ; 3154 1 208 180 B47415
                JBS     off(0022bh).1, idle_output_gate3 ; 3157 1 208 180 E92B04
idle_output_common:     MOV     er3, off(00268h)       ; 315A 1 208 180 B4684B
                VCAL    6                      ; 315D 1 208 180 16
idle_output_gate3:     MOV     er3, off(00280h)       ; 315E 1 208 180 B4804B
                XCHG    A, er3                 ; 3161 1 208 180 4710
                VCAL    5                      ; 3163 1 208 180 15
idle_pi_final_calc:     MOV     X2, A                  ; 3164 1 208 180 51
                MOV     X1, #idle_pi_final_calc_tbl          ; 3165 1 208 180 602E69
                LB      A, 0a4h                ; 3168 0 208 180 F5A4
                VCAL    2                      ; 316A 0 208 180 12
                STB     A, off(00290h)         ; 316B 0 208 180 D490
                MOV     X1, #idle_pi_final_calc_tbl_3          ; 316D 0 208 180 604D69
                JBS     off(00216h).3, idle_pi_final_calc_load_ram0c1 ; 3170 0 208 180 EB1603
                MOV     X1, #idle_pi_final_calc_tbl_2          ; 3173 0 208 180 603269
idle_pi_final_calc_load_ram0c1:     LB      A, 0c1h                ; 3176 0 208 180 F5C1
                VCAL    1                      ; 3178 0 208 180 11
                MOV     DP, #0030ch            ; 3179 0 208 180 620C03
                ; warning: had to flip DD
                SUB     A, [DP]                ; 317C 1 208 180 B2A2
                SLL     A                      ; 317E 1 208 180 53
                ST      A, er0                 ; 317F 1 208 180 88
                CLR     A                      ; 3180 1 208 180 F9
                JLT     idle_pi_scale_store             ; 3181 1 208 180 CA0A
                LB      A, off(00290h)         ; 3183 0 208 180 F490
                ANDB    A, #07fh               ; 3185 0 208 180 D67F
                STB     A, ACCH                ; 3187 0 208 180 D507
                CLRB    A                      ; 3189 0 208 180 FA
                MUL                            ; 318A 0 208 180 9035
                L       A, er1                 ; 318C 1 208 180 35
idle_pi_scale_store:     ST      A, off(00272h)         ; 318D 1 208 180 D472
                L       A, X2                  ; 318F 1 208 180 41
                CLRB    r0                     ; 3190 1 208 180 2015
                MOVB    r1, off(00290h)        ; 3192 1 208 180 C49049
                MUL                            ; 3195 1 208 180 9035
                SLL     A                      ; 3197 1 208 180 53
                L       A, er1                 ; 3198 1 208 180 35
                ROL     A                      ; 3199 1 208 180 33
                JGE     idle_pi_result_clamp             ; 319A 1 208 180 CD03
                L       A, #0ffffh             ; 319C 1 208 180 67FFFF
idle_pi_result_clamp:     ST      A, er3                 ; 319F 1 208 180 8B
                L       A, off(00272h)         ; 31A0 1 208 180 E472
                VCAL    6                      ; 31A2 1 208 180 16
                L       A, off(00282h)         ; 31A3 1 208 180 E482
                VCAL    5                      ; 31A5 1 208 180 15
idle_gear_target_check:     JNE     idle_gear_target_clamp             ; 31A6 1 208 180 CE05
                JBS     off(0021ah).5, idle_gear_target_reset ; 31A8 1 208 180 ED1A0D
                SJ      idle_gear_target_store             ; 31AB 1 208 180 CB13
idle_gear_target_clamp:     MOV     er3, #03fffh           ; 31AD 1 208 180 4798FF3F
                CMP     A, er3                 ; 31B1 1 208 180 4B
                JLT     idle_gear_target_store             ; 31B2 1 208 180 CA0C
                L       A, er3                 ; 31B4 1 208 180 37
                JBS     off(0021ah).5, idle_gear_target_store ; 31B5 1 208 180 ED1A08
idle_gear_target_reset:     MOV     off(00284h), off(00286h) ; 31B8 1 208 180 B4867C84
                MOVB    off(00288h), off(00289h) ; 31BC 1 208 180 C4897C88
idle_gear_target_store:     ST      A, off(0025ch)         ; 31C0 1 208 180 D45C
                MOV     X1, #tbl_idle_gear_target          ; 31C2 1 208 180 606869
                CAL     table_interp_lookup_4byte             ; 31C5 1 208 180 32FE4E
idle_gear_target_final:     ST      A, off(0025ah)         ; 31C8 1 208 180 D45A
                RB      off(0022bh).1          ; 31CA 1 208 180 C42B09
                MB      C, off(00228h).5       ; 31CD 1 208 180 C4282D
                MB      off(0021ah).4, C       ; 31D0 1 208 180 C41A3C
                LB      A, off(00228h)         ; 31D3 0 208 180 F428
                ANDB    A, #0f0h               ; 31D5 0 208 180 D6F0
                SWAPB                          ; 31D7 0 208 180 83
                STB     A, off(00228h)         ; 31D8 0 208 180 D428
                RT                             ; 31DA 0 208 180 01
ignition_timing_calc_task:     MOVB    r5, 0b9h               ; 31DB 1 208 180 C5B94D
                LB      A, 0b4h                ; 31DE 0 208 180 F5B4
                MOV     X1, #ignition_timing_calc_task_tbl_2          ; 31E0 0 208 180 608064
                VCAL    0                      ; 31E3 0 208 180 10
                STB     A, r4                  ; 31E4 0 208 180 8C
                LB      A, 0b4h                ; 31E5 0 208 180 F5B4
                MOV     X1, #ignition_timing_calc_task_tbl_3          ; 31E7 0 208 180 608E64
                VCAL    0                      ; 31EA 0 208 180 10
                STB     A, r3                  ; 31EB 0 208 180 8B
                LB      A, 0b4h                ; 31EC 0 208 180 F5B4
                MOV     X1, #ignition_timing_calc_task_tbl_4          ; 31EE 0 208 180 60A664
                VCAL    0                      ; 31F1 0 208 180 10
                STB     A, r2                  ; 31F2 0 208 180 8A
                JBS     off(0022eh).5, ignition_timing_calc_task_cmp_acc ; 31F3 0 208 180 ED2E01
                LB      A, r3                  ; 31F6 0 208 180 7B
ignition_timing_calc_task_cmp_acc:     CMPB    A, r5                  ; 31F7 0 208 180 4D
                MB      off(0022eh).5, C       ; 31F8 0 208 180 C42E3D
                LB      A, r2                  ; 31FB 0 208 180 7A
                JBS     off(0022eh).4, ignition_timing_calc_task_subb_acc ; 31FC 0 208 180 EC2E01
                LB      A, r3                  ; 31FF 0 208 180 7B
ignition_timing_calc_task_subb_acc:     SUBB    A, r4                  ; 3200 0 208 180 2C
                J       ignition_timing_calc_task_if_ge_goto_57a2             ; 3201 0 208 180 039F57
ignition_timing_calc_task_load_ram0b4:     LB      A, 0b4h                ; 3205 0 208 180 F5B4
                MOV     X1, #ignition_timing_calc_task_tbl_5          ; 3207 0 208 180 60BE64
                VCAL    0                      ; 320A 0 208 180 10
                STB     A, r3                  ; 320B 0 208 180 8B
                LB      A, 0b4h                ; 320C 0 208 180 F5B4
                MOV     X1, #ignition_timing_calc_task_tbl_6          ; 320E 0 208 180 60D664
                VCAL    0                      ; 3211 0 208 180 10
                STB     A, r2                  ; 3212 0 208 180 8A
                JBS     off(0022eh).7, ignition_timing_calc_task_cmp_acc_2 ; 3213 0 208 180 EF2E01
                LB      A, r3                  ; 3216 0 208 180 7B
ignition_timing_calc_task_cmp_acc_2:     CMPB    A, r5                  ; 3217 0 208 180 4D
                MB      off(0022eh).7, C       ; 3218 0 208 180 C42E3F
                LB      A, r2                  ; 321B 0 208 180 7A
                JBS     off(0022eh).6, ignition_timing_calc_task_subb_acc_2 ; 321C 0 208 180 EE2E01
                LB      A, r3                  ; 321F 0 208 180 7B
ignition_timing_calc_task_subb_acc_2:     SUBB    A, r4                  ; 3220 0 208 180 2C
                J       ignition_timing_calc_task_if_ge_goto_57ac             ; 3221 0 208 180 03A957
ignition_timing_calc_task_load_ram0b4_2:     LB      A, 0b4h                ; 3225 0 208 180 F5B4
                STB     A, r4                  ; 3227 0 208 180 8C
                MOV     X1, #ignition_timing_calc_task_tbl_9          ; 3228 0 208 180 600265
                VCAL    0                      ; 322B 0 208 180 10
                STB     A, off(0029fh)         ; 322C 0 208 180 D49F
                LB      A, r4                  ; 322E 0 208 180 7C
                MOV     X1, #ignition_timing_calc_task_tbl_10          ; 322F 0 208 180 601065
                VCAL    0                      ; 3232 0 208 180 10
                STB     A, off(002a0h)         ; 3233 0 208 180 D4A0
                CMPB    A, r5                  ; 3235 0 208 180 4D
                XORB    PSWH, #080h            ; 3236 0 208 180 A2F080
                JGE     ignition_timing_calc_task_store_carry_ram22f_bit3             ; 3239 0 208 180 CD03
                LB      A, off(0029fh)         ; 323B 0 208 180 F49F
                CMPB    A, r5                  ; 323D 0 208 180 4D
ignition_timing_calc_task_store_carry_ram22f_bit3:     MB      off(0022fh).3, C       ; 323E 0 208 180 C42F3B
                LB      A, r4                  ; 3241 0 208 180 7C
                MOV     X1, #ignition_timing_calc_task_tbl_11          ; 3242 0 208 180 601E65
                VCAL    0                      ; 3245 0 208 180 10
                STB     A, off(002a1h)         ; 3246 0 208 180 D4A1
                LB      A, r4                  ; 3248 0 208 180 7C
                MOV     X1, #ignition_timing_calc_task_tbl_12          ; 3249 0 208 180 602C65
                VCAL    0                      ; 324C 0 208 180 10
                STB     A, off(002a2h)         ; 324D 0 208 180 D4A2
                CMPB    A, r5                  ; 324F 0 208 180 4D
                XORB    PSWH, #080h            ; 3250 0 208 180 A2F080
                JGE     ignition_timing_calc_task_store_carry_ram22f_bit4             ; 3253 0 208 180 CD03
                LB      A, off(002a1h)         ; 3255 0 208 180 F4A1
                CMPB    A, r5                  ; 3257 0 208 180 4D
ignition_timing_calc_task_store_carry_ram22f_bit4:     MB      off(0022fh).4, C       ; 3258 0 208 180 C42F3C
                LB      A, 0b4h                ; 325B 0 208 180 F5B4
                MOV     X1, #ignition_timing_calc_task_tbl_7          ; 325D 0 208 180 60EE64
                JBS     off(0022eh).3, ignition_timing_calc_task_vcal_0 ; 3260 0 208 180 EB2E03
                MOV     X1, #ignition_timing_calc_task_tbl_8          ; 3263 0 208 180 60F864
ignition_timing_calc_task_vcal_0:     VCAL    0                      ; 3266 0 208 180 10
                MOV     DP, #00311h            ; 3267 0 208 180 621103
                ADDB    A, [DP]                ; 326A 0 208 180 C282
                CMPB    A, 0bch                ; 326C 0 208 180 C5BCC2
                MB      off(0022eh).3, C       ; 326F 0 208 180 C42E3B
                MOV     DP, #0022ch            ; 3272 0 208 180 622C02
                MOV     er0, #00800h           ; 3275 0 208 180 44980008
                MOV     X1, #ignition_timing_calc_task_tbl          ; 3279 0 208 180 605A64
                MOVB    r2, 0b4h               ; 327C 0 208 180 C5B44A
                RB      PSWL.4                 ; 327F 0 208 180 A30C
                CAL     timer_or_counter_helper             ; 3281 0 208 180 327752
                INC     DP                     ; 3284 0 208 180 72
                MOV     er0, #00800h           ; 3285 0 208 180 44980008
                CAL     timer_or_counter_helper             ; 3289 0 208 180 327752
                INC     DP                     ; 328C 0 208 180 72
                MOV     er0, #00100h           ; 328D 0 208 180 44980001
                CAL     timer_or_counter_helper             ; 3291 0 208 180 327752
                MOVB    r1, #001h              ; 3294 0 208 180 9901
                MOVB    r2, off(00236h)        ; 3296 0 208 180 C4364A
                CAL     timer_or_counter_helper             ; 3299 0 208 180 327752
                MOVB    r1, #001h              ; 329C 0 208 180 9901
                MOVB    r2, 0b9h               ; 329E 0 208 180 C5B94A
                CAL     timer_or_counter_helper             ; 32A1 0 208 180 327752
                LB      A, 0b4h                ; 32A4 0 208 180 F5B4
                MOVB    r7, #080h              ; 32A6 0 208 180 9F80
                JBS     off(00211h).5, ignition_timing_calc_task_load_r7 ; 32A8 0 208 180 ED1134
                JBS     off(00211h).6, ignition_timing_calc_task_if_ram22e_bit2_set ; 32AB 0 208 180 EE1106
                JBR     off(00211h).7, ignition_timing_calc_task_load_r7 ; 32AE 0 208 180 DF112E
                JBS     off(0022ch).0, ignition_timing_calc_task_clear_r7 ; 32B1 0 208 180 E82C29
ignition_timing_calc_task_if_ram22e_bit2_set:     JBS     off(0022eh).2, ignition_timing_calc_task_load_r7 ; 32B4 0 208 180 EA2E28
                JBR     off(0022fh).6, ignition_timing_calc_task_cmp_acc_3 ; 32B7 0 208 180 DE2F08
                CMPB    A, #027h               ; 32BA 0 208 180 C627
                JLT     ignition_timing_calc_task_load_r7             ; 32BC 0 208 180 CA21
                MOVB    r7, #040h              ; 32BE 0 208 180 9F40
                SJ      ignition_timing_calc_task_if_ram22c_bit1_clr             ; 32C0 0 208 180 CB12
ignition_timing_calc_task_cmp_acc_3:     CMPB    A, #010h               ; 32C2 0 208 180 C610
                JLT     ignition_timing_calc_task_load_r7             ; 32C4 0 208 180 CA19
                MOVB    r7, #040h              ; 32C6 0 208 180 9F40
                JBS     off(0022fh).7, ignition_timing_calc_task_if_ram22c_bit1_clr ; 32C8 0 208 180 EF2F09
                JBS     off(0022eh).3, ignition_timing_calc_task_if_ram22c_bit1_clr ; 32CB 0 208 180 EB2E06
                CMPB    A, #010h               ; 32CE 0 208 180 C610
                JGE     ignition_timing_calc_task_clear_r7             ; 32D0 0 208 180 CD0B
                SJ      ignition_timing_calc_task_load_r7             ; 32D2 0 208 180 CB0B
ignition_timing_calc_task_if_ram22c_bit1_clr:     JBR     off(0022ch).1, ignition_timing_calc_task_load_r7 ; 32D4 0 208 180 D92C08
                JBS     off(00211h).6, ignition_timing_calc_task_load_r7 ; 32D7 0 208 180 EE1105
                JBS     off(0022eh).6, ignition_timing_calc_task_load_r7 ; 32DA 0 208 180 EE2E02
ignition_timing_calc_task_clear_r7:     CLRB    r7                     ; 32DD 0 208 180 2715
ignition_timing_calc_task_load_r7:     LB      A, r7                  ; 32DF 0 208 180 7F
                SLLB    A                      ; 32E0 0 208 180 53
                MB      off(0022fh).6, C       ; 32E1 0 208 180 C42F3E
                SLLB    A                      ; 32E4 0 208 180 53
                MB      off(0022fh).7, C       ; 32E5 0 208 180 C42F3F
                CLR     A                      ; 32E8 (skeleton: fault flags are always clear)
                CMPB    0c1h, #03ch            ; 32F5 0 208 180 C5C1C03C
                JGE     ignition_timing_calc_task_load_ram2ca             ; 32F9 0 208 180 CD16
                JBR     off(0022eh).1, ignition_timing_calc_task_load_ram2ca ; 32FB 0 208 180 D92E13
                JBS     off(00211h).7, ignition_timing_calc_task_load_ram2cc_2 ; 32FE 0 208 180 EF111A
                JBR     off(00211h).6, ignition_timing_calc_task_load_ram2ca ; 3301 0 208 180 DE110D
                JBR     off(0022fh).0, ignition_timing_calc_task_load_ram2cc ; 3304 0 208 180 D82F04
                MOVB    off(002c9h), #014h     ; 3307 0 208 180 C4C99814
ignition_timing_calc_task_load_ram2cc:     LB      A, off(002cch)         ; 330B 0 208 180 F4CC
                JNE     ignition_timing_calc_task_clear_carry             ; 330D 0 208 180 CE41
                SJ      ignition_timing_calc_task_load_ram2ca_2             ; 330F 0 208 180 CB04
ignition_timing_calc_task_load_ram2ca:     MOVB    off(002cah), #002h     ; 3311 0 208 180 C4CA9802
ignition_timing_calc_task_load_ram2ca_2:     LB      A, off(002cah)         ; 3315 0 208 180 F4CA
                JEQ     ignition_timing_calc_task_if_ram21b_bit6_set             ; 3317 0 208 180 C90A
                SJ      ignition_timing_calc_task_clear_carry             ; 3319 0 208 180 CB35
ignition_timing_calc_task_load_ram2cc_2:     MOVB    off(002cch), #00ch     ; 331B 0 208 180 C4CC980C
                LB      A, off(002c9h)         ; 331F 0 208 180 F4C9
                JEQ     ignition_timing_calc_task_load_ram2ca_2             ; 3321 0 208 180 C9F2
ignition_timing_calc_task_if_ram21b_bit6_set:     JBS     off(0021bh).6, ignition_timing_calc_task_load_ram2cb ; 3323 0 208 180 EE1B0B
                CMP     0aeh, #00120h          ; 3326 0 208 180 B5AEC02001
                JLT     ignition_timing_calc_task_load_ram2cb             ; 332B 0 208 180 CA04
                MOVB    off(002cbh), #014h     ; 332D 0 208 180 C4CB9814
ignition_timing_calc_task_load_ram2cb:     LB      A, off(002cbh)         ; 3331 0 208 180 F4CB
                JNE     ignition_timing_calc_task_clear_carry             ; 3333 0 208 180 CE1B
                JBS     off(0022eh).3, ignition_timing_calc_task_if_ram211_bit6_set ; 3335 0 208 180 EB2E1B
                JBS     off(0022fh).6, ignition_timing_calc_task_clear_carry ; 3338 0 208 180 EE2F15
                MB      C, off(0022dh).6       ; 333B 0 208 180 C42D2E
                JBS     off(0022fh).7, ignition_timing_calc_task_if_ge_goto_3350 ; 333E 0 208 180 EF2F03
                MB      C, off(0022dh).7       ; 3341 0 208 180 C42D2F
ignition_timing_calc_task_if_ge_goto_3350:     JGE     ignition_timing_calc_task_clear_carry             ; 3344 0 208 180 CD0A
                JBS     off(0022eh).0, ignition_timing_calc_task_clear_carry ; 3346 0 208 180 E82E07
                LB      A, off(002e5h)         ; 3349 0 208 180 F4E5
                JEQ     ignition_timing_calc_task_clear_carry             ; 334B 0 208 180 C903
                JBS     off(0021ch).3, ignition_timing_calc_task_if_ram22f_bit0_set ; 334D 0 208 180 EB1C22
ignition_timing_calc_task_clear_carry:     RC                             ; 3350 0 208 180 95
                SJ      ignition_timing_calc_task_store_carry_ram22f_bit0             ; 3351 0 208 180 CB31
ignition_timing_calc_task_if_ram211_bit6_set:     JBS     off(00211h).6, ignition_timing_calc_task_if_ram22c_bit2_set ; 3353 0 208 180 EE110F
                JBS     off(0022ch).4, ignition_timing_calc_task_if_ram22f_bit0_set ; 3356 0 208 180 EC2C19
                JBR     off(0022ch).5, ignition_timing_calc_task_load_ram2cd ; 3359 0 208 180 DD2C03
                JBR     off(0022eh).7, ignition_timing_calc_task_load_ram2cd_2 ; 335C 0 208 180 DF2E0F
ignition_timing_calc_task_load_ram2cd:     MOVB    off(002cdh), #014h     ; 335F 0 208 180 C4CD9814
                SJ      ignition_timing_calc_task_load_ram2cd_2             ; 3363 0 208 180 CB09
ignition_timing_calc_task_if_ram22c_bit2_set:     JBS     off(0022ch).2, ignition_timing_calc_task_if_ram22f_bit0_set ; 3365 0 208 180 EA2C0A
                JBR     off(0022ch).3, ignition_timing_calc_task_load_ram2cd ; 3368 0 208 180 DB2CF4
                JBS     off(0022eh).5, ignition_timing_calc_task_load_ram2cd ; 336B 0 208 180 ED2EF1
ignition_timing_calc_task_load_ram2cd_2:     LB      A, off(002cdh)         ; 336E 0 208 180 F4CD
                JNE     ignition_timing_calc_task_clear_carry             ; 3370 0 208 180 CEDE
ignition_timing_calc_task_if_ram22f_bit0_set:     JBS     off(0022fh).0, ignition_timing_calc_task_set_carry ; 3372 0 208 180 E82F0E
                J       ignition_timing_calc_task_load_ram0bd             ; 3375 0 208 180 03135F
ignition_timing_calc_task_if_le_goto_337f:     JLE     ignition_timing_calc_task_load_ram2d2_2             ; 3379 0 208 180 CF04
ignition_timing_calc_task_load_ram2d2:     MOVB    off(002d2h), #002h     ; 337B 0 208 180 C4D29802
ignition_timing_calc_task_load_ram2d2_2:     LB      A, off(002d2h)         ; 337F 0 208 180 F4D2
                JNE     ignition_timing_calc_task_clear_carry             ; 3381 0 208 180 CECD
ignition_timing_calc_task_set_carry:     SC                             ; 3383 0 208 180 85
ignition_timing_calc_task_store_carry_ram22f_bit0:     MB      off(0022fh).0, C       ; 3384 0 208 180 C42F38
                MB      P0.4, C                ; 3387 0 208 180 C5203C
                CMPB    0c0h, #0e1h            ; 338A 0 208 180 C5C0C0E1
                JGE     ignition_timing_calc_task_load_imm             ; 338E 0 208 180 CD06
                CMPB    0c1h, #02eh            ; 3390 0 208 180 C5C1C02E
                JLT     ignition_timing_calc_task_if_ram22d_bit0_set             ; 3394 0 208 180 CA08
ignition_timing_calc_task_load_imm:     LB      A, #00ch               ; 3396 0 208 180 770C
                STB     A, off(002b0h)         ; 3398 0 208 180 D4B0
                STB     A, off(0029eh)         ; 339A 0 208 180 D49E
                SJ      ignition_timing_calc_task_goto_3595             ; 339C 0 208 180 CB72
ignition_timing_calc_task_if_ram22d_bit0_set:     JBS     off(0022dh).0, ignition_timing_calc_task_load_ram2b0 ; 339E 0 208 180 E82D06
                LB      A, off(0029eh)         ; 33A1 0 208 180 F49E
                STB     A, off(002b0h)         ; 33A3 0 208 180 D4B0
                SJ      ignition_timing_calc_task_if_ne_goto_3410             ; 33A5 0 208 180 CB04
ignition_timing_calc_task_load_ram2b0:     LB      A, off(002b0h)         ; 33A7 0 208 180 F4B0
                STB     A, off(0029eh)         ; 33A9 0 208 180 D49E
ignition_timing_calc_task_if_ne_goto_3410:     JNE     ignition_timing_calc_task_goto_3595             ; 33AB 0 208 180 CE63
                JBR     off(0022fh).0, ignition_timing_calc_task_goto_3595 ; 33AD 0 208 180 D82F60
                JBS     off(0022eh).3, ignition_timing_calc_task_load_carry_ram22e_bit4 ; 33B0 0 208 180 EB2E08
                JBS     off(0022fh).7, ignition_timing_calc_task_goto_340a ; 33B3 0 208 180 EF2F03
                JBS     off(0022fh).6, ignition_timing_calc_task_goto_3595 ; 33B6 0 208 180 EE2F57
ignition_timing_calc_task_goto_340a:     SJ      ignition_timing_calc_task_goto_348c             ; 33B9 0 208 180 CB4F
ignition_timing_calc_task_load_carry_ram22e_bit4:     MB      C, off(0022eh).4       ; 33BB 0 208 180 C42E2C
                JBS     off(00211h).6, ignition_timing_calc_task_if_ge_goto_33ca ; 33BE 0 208 180 EE1103
                MB      C, off(0022eh).6       ; 33C1 0 208 180 C42E2E
ignition_timing_calc_task_if_ge_goto_33ca:     JGE     ignition_timing_calc_task_load_ram2ce             ; 33C4 0 208 180 CD04
                MOVB    off(002ceh), #00ah     ; 33C6 0 208 180 C4CE980A
ignition_timing_calc_task_load_ram2ce:     LB      A, off(002ceh)         ; 33CA 0 208 180 F4CE
                JNE     ignition_timing_calc_task_goto_3595             ; 33CC 0 208 180 CE42
                MOV     er1, #00028h           ; 33CE 0 208 180 45982800
                JBR     off(00211h).6, ignition_timing_calc_task_if_ram22d_bit5_clr ; 33D2 0 208 180 DE1105
                JBR     off(0022dh).4, ignition_timing_calc_task_goto_3595 ; 33D5 0 208 180 DC2D38
                SJ      ignition_timing_calc_task_goto_3583             ; 33D8 0 208 180 CB33
ignition_timing_calc_task_if_ram22d_bit5_clr:     JBR     off(0022dh).5, ignition_timing_calc_task_if_ram22d_bit1_set ; 33DA 0 208 180 DD2D06
                MOV     er1, #00033h           ; 33DD 0 208 180 45983300
                SJ      ignition_timing_calc_task_goto_3583             ; 33E1 0 208 180 CB2A
ignition_timing_calc_task_if_ram22d_bit1_set:     JBS     off(0022dh).1, ignition_timing_calc_task_goto_3583 ; 33E3 0 208 180 E92D27
                JBS     off(0022fh).7, ignition_timing_calc_task_if_ram22d_bit2_clr ; 33E6 0 208 180 EF2F08
                JBS     off(0022fh).6, ignition_timing_calc_task_goto_3595 ; 33E9 0 208 180 EE2F24
                JBR     off(0022dh).3, ignition_timing_calc_task_goto_3595 ; 33EC 0 208 180 DB2D21
                SJ      ignition_timing_calc_task_load_carry_ram22f_bit3             ; 33EF 0 208 180 CB03
ignition_timing_calc_task_if_ram22d_bit2_clr:     JBR     off(0022dh).2, ignition_timing_calc_task_goto_3595 ; 33F1 0 208 180 DA2D1C
ignition_timing_calc_task_load_carry_ram22f_bit3:     MB      C, off(0022fh).3       ; 33F4 0 208 180 C42F2B
                JBS     off(0022fh).7, ignition_timing_calc_task_if_lt_goto_3403 ; 33F7 0 208 180 EF2F03
                MB      C, off(0022fh).4       ; 33FA 0 208 180 C42F2C
ignition_timing_calc_task_if_lt_goto_3403:     JLT     ignition_timing_calc_task_goto_7756             ; 33FD 0 208 180 CA04
                MOVB    off(002cfh), #00ah     ; 33FF 0 208 180 C4CF980A
ignition_timing_calc_task_goto_7756:     J       ignition_timing_calc_task_load_ram2cf             ; 3403 0 208 180 035677
                DB  000h,003h,039h,035h ; 3406
ignition_timing_calc_task_goto_348c:     J       ignition_timing_calc_task_clear_r0             ; 340A 0 208 180 038C34
ignition_timing_calc_task_goto_3583:     J       ignition_timing_calc_task_load_ram298             ; 340D 0 208 180 038335
ignition_timing_calc_task_goto_3595:     J       ignition_timing_calc_task_clear_acc             ; 3410 0 208 180 039535
ignition_timing_calc_task_load_ram29f:     LB      A, off(0029fh)         ; 3413 0 208 180 F49F
                MOVB    r0, #060h              ; 3415 0 208 180 9860
                MOV     er1, #0332eh           ; 3417 0 208 180 45982E33
                MOVB    r6, #020h              ; 341B 0 208 180 9E20
                MOVB    r7, #020h              ; 341D 0 208 180 9F20
                JBS     off(0022fh).7, ignition_timing_calc_task_subb_acc_3 ; 341F 0 208 180 EF2F0C
                LB      A, off(002a1h)         ; 3422 0 208 180 F4A1
                MOVB    r0, #060h              ; 3424 0 208 180 9860
                MOV     er1, #044a1h           ; 3426 0 208 180 4598A144
                MOVB    r6, #020h              ; 342A 0 208 180 9E20
                MOVB    r7, #020h              ; 342C 0 208 180 9F20
ignition_timing_calc_task_subb_acc_3:     SUBB    A, 0b9h                ; 342E 0 208 180 C5B9A2
                MB      PSWL.4, C              ; 3431 0 208 180 A33C
                JGE     ignition_timing_calc_task_mulb_acc             ; 3433 0 208 180 CD01
                VCAL    7                      ; 3435 0 208 180 17
ignition_timing_calc_task_mulb_acc:     MULB                           ; 3436 0 208 180 A234
                L       A, ACC                 ; 3438 1 208 180 E506
                MOVB    r0, #020h              ; 343A 1 208 180 9820
                NOP                            ; 343C 1 208 180 00
                NOP                            ; 343D 1 208 180 00
                NOP                            ; 343E 1 208 180 00
                NOP                            ; 343F 1 208 180 00
                MB      C, PSWL.4              ; 3440 1 208 180 A32C
                JGE     ignition_timing_calc_task_add_acc             ; 3442 1 208 180 CD08
                XCHG    A, er1                 ; 3444 1 208 180 4510
                SUB     A, er1                 ; 3446 1 208 180 29
                JGE     ignition_timing_calc_task_store_er0             ; 3447 1 208 180 CD09
                CLR     A                      ; 3449 1 208 180 F9
                SJ      ignition_timing_calc_task_store_er0             ; 344A 1 208 180 CB06
ignition_timing_calc_task_add_acc:     ADD     A, er1                 ; 344C 1 208 180 09
                JGE     ignition_timing_calc_task_store_er0             ; 344D 1 208 180 CD03
                L       A, #0ffffh             ; 344F 1 208 180 67FFFF
ignition_timing_calc_task_store_er0:     ST      A, er0                 ; 3452 1 208 180 88
                L       A, 0b6h                ; 3453 1 208 180 E5B6
                MUL                            ; 3455 1 208 180 9035
                L       A, er1                 ; 3457 1 208 180 35
                MOV     DP, #0038ah            ; 3458 1 208 180 628A03
                ST      A, [DP]                ; 345B 1 208 180 D2
                SUB     A, 0ach                ; 345C 1 208 180 B5ACA2
                MB      PSWL.4, C              ; 345F 1 208 180 A33C
                JGE     ignition_timing_calc_task_load_dp             ; 3461 1 208 180 CD01
                VCAL    7                      ; 3463 1 208 180 17
ignition_timing_calc_task_load_dp:     MOV     DP, #0038ch            ; 3464 1 208 180 628C03
                ST      A, [DP]                ; 3467 1 208 180 D2
                CAL     weighted_sum_2term_trim             ; 3468 1 208 180 328451
ignition_timing_calc_task_if_eq_goto_3475:     JEQ     ignition_timing_calc_task_load_x2             ; 346B 1 208 180 C908
                CMP     A, #00333h             ; 346D 1 208 180 C63303
                JLT     ignition_timing_calc_task_load_x2             ; 3470 1 208 180 CA03
                L       A, #00333h             ; 3472 1 208 180 673303
ignition_timing_calc_task_load_x2:     MOV     X2, A                  ; 3475 1 208 180 51
                MOV     X1, #00316h            ; 3476 1 208 180 601603
                JBS     off(0022fh).7, ignition_timing_calc_task_load_er0 ; 3479 1 208 180 EF2F02
                INC     X1                     ; 347C 1 208 180 70
                INC     X1                     ; 347D 1 208 180 70
ignition_timing_calc_task_load_er0:     MOV     er0, #000ffh           ; 347E 1 208 180 4498FF00
                CAL     interp_bracket_delta_scale_2             ; 3482 1 208 180 32624F
                CAL     clamp_to_35_512             ; 3485 1 208 180 32FA50
                L       A, X2                  ; 3488 1 208 180 41
                J       ignition_timing_calc_task_clear_ram22f_bit2_2             ; 3489 1 208 180 037477
ignition_timing_calc_task_clear_r0:     CLRB    r0                     ; 348C 0 208 180 2015
                MOV     DP, #00312h            ; 348E 0 208 180 621203
                MOVB    r1, #090h              ; 3491 0 208 180 9990
                MOVB    r2, #040h              ; 3493 0 208 180 9A40
                JBS     off(0022fh).7, ignition_timing_calc_task_load_dp_ind ; 3495 0 208 180 EF2F06
                INC     DP                     ; 3498 0 208 180 72
                INC     DP                     ; 3499 0 208 180 72
                MOVB    r1, #080h              ; 349A 0 208 180 9980
                MOVB    r2, #040h              ; 349C 0 208 180 9A40
ignition_timing_calc_task_load_dp_ind:     L       A, [DP]                ; 349E 1 208 180 E2
                SUB     A, off(0029ah)         ; 349F 1 208 180 A79A
                MB      PSWL.4, C              ; 34A1 1 208 180 A33C
                JGE     ignition_timing_calc_task_cmp_acc_4             ; 34A3 1 208 180 CD03
                VCAL    7                      ; 34A5 1 208 180 17
                MOVB    r1, r2                 ; 34A6 1 208 180 2249
ignition_timing_calc_task_cmp_acc_4:     CMP     A, #00155h             ; 34A8 1 208 180 C65501
                SB      off(0022fh).1          ; 34AB 1 208 180 C42F19
                JGE     ignition_timing_calc_task_goto_5a68             ; 34AE 1 208 180 CD05
                JNE     ignition_timing_calc_task_if_ram22f_bit5_set             ; 34B0 1 208 180 CE19
                J       ignition_timing_calc_task_load_dp_ind_3             ; 34B2 1 208 180 037D77
ignition_timing_calc_task_goto_5a68:     J       ignition_timing_calc_task_mul_acc_3             ; 34B5 1 208 180 03685A
ignition_timing_calc_task_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 34B9 1 208 180 A32C
                JLT     ignition_timing_calc_task_sub_acc             ; 34BB 1 208 180 CA08
                ADD     A, er1                 ; 34BD 1 208 180 09
                J       ignition_timing_calc_task_if_lt_goto_7787             ; 34BE 1 208 180 038077
ignition_timing_calc_task_goto_34c9:     SJ      ignition_timing_calc_task_store_ram29a             ; 34C3 1 208 180 CB04
ignition_timing_calc_task_sub_acc:     SUB     A, er1                 ; 34C5 1 208 180 29
                JGE     ignition_timing_calc_task_store_ram29a             ; 34C6 1 208 180 CD01
                CLR     A                      ; 34C8 1 208 180 F9
ignition_timing_calc_task_store_ram29a:     ST      A, off(0029ah)         ; 34C9 1 208 180 D49A
ignition_timing_calc_task_if_ram22f_bit5_set:     JBS     off(0022fh).5, ignition_timing_calc_task_load_ram2d0 ; 34CB 1 208 180 ED2F10
                CMP     off(0029ch), #00180h   ; 34CE 1 208 180 B49CC08001
                JLT     ignition_timing_calc_task_load_ram2d0             ; 34D3 1 208 180 CA09
                LB      A, off(002d0h)         ; 34D5 0 208 180 F4D0
                JNE     ignition_timing_calc_task_load_ram0b6             ; 34D7 0 208 180 CE09
                RB      off(0022fh).7          ; 34D9 0 208 180 C42F0F
                SJ      ignition_timing_calc_task_load_ram0b6             ; 34DC 0 208 180 CB04
ignition_timing_calc_task_load_ram2d0:     MOVB    off(002d0h), #028h     ; 34DE 1 208 180 C4D09828
ignition_timing_calc_task_load_ram0b6:     L       A, 0b6h                ; 34E2 1 208 180 E5B6
                MOV     er0, #034c2h           ; 34E4 1 208 180 4498C234
                JBS     off(0022fh).7, ignition_timing_calc_task_mul_acc ; 34E8 1 208 180 EF2F04
                MOV     er0, #04a55h           ; 34EB 1 208 180 4498554A
ignition_timing_calc_task_mul_acc:     MUL                            ; 34EF 1 208 180 9035
                L       A, er1                 ; 34F1 1 208 180 35
                MOV     DP, #0038ah            ; 34F2 1 208 180 628A03
                ST      A, [DP]                ; 34F5 1 208 180 D2
                L       A, 0ach                ; 34F6 1 208 180 E5AC
                SUB     A, er1                 ; 34F8 1 208 180 29
                MB      off(0022fh).5, C       ; 34F9 1 208 180 C42F3D
                MB      PSWL.4, C              ; 34FC 1 208 180 A33C
                JGE     ignition_timing_calc_task_store_ram29c             ; 34FE 1 208 180 CD01
                VCAL    7                      ; 3500 1 208 180 17
ignition_timing_calc_task_store_ram29c:     ST      A, off(0029ch)         ; 3501 1 208 180 D49C
                MOVB    r6, #040h              ; 3503 1 208 180 9E40
                MOVB    r7, #040h              ; 3505 1 208 180 9F40
                CAL     weighted_sum_2term_trim             ; 3507 1 208 180 328451
                MOV     X2, A                  ; 350A 1 208 180 51
                JEQ     ignition_timing_calc_task_cmp_ram2d1             ; 350B 1 208 180 C904
                MOVB    off(002d1h), #014h     ; 350D 1 208 180 C4D19814
ignition_timing_calc_task_cmp_ram2d1:     CMPB    off(002d1h), #000h     ; 3511 1 208 180 C4D1C000
                JNE     ignition_timing_calc_task_if_ram22c_bit6_clr             ; 3515 1 208 180 CE04
                CLR     X2                     ; 3517 1 208 180 9115
                SJ      ignition_timing_calc_task_load_x2_2             ; 3519 1 208 180 CB18
ignition_timing_calc_task_if_ram22c_bit6_clr:     JBR     off(0022ch).6, ignition_timing_calc_task_load_x2_2 ; 351B 1 208 180 DE2C15
                JBS     off(0022ch).7, ignition_timing_calc_task_load_x2_2 ; 351E 1 208 180 EF2C12
                MOV     X1, #00312h            ; 3521 1 208 180 601203
                JBS     off(0022fh).7, ignition_timing_calc_task_load_er0_2 ; 3524 1 208 180 EF2F02
                INC     X1                     ; 3527 1 208 180 70
                INC     X1                     ; 3528 1 208 180 70
ignition_timing_calc_task_load_er0_2:     MOV     er0, #000ffh           ; 3529 1 208 180 4498FF00
                CAL     interp_bracket_delta_scale_2             ; 352D 1 208 180 32624F
                CAL     ignition_timing_calc_task_sub_load_er2             ; 3530 1 208 180 32F050
ignition_timing_calc_task_load_x2_2:     L       A, X2                  ; 3533 1 208 180 41
                J       ignition_timing_calc_task_clear_ram22f_bit2_3             ; 3534 1 208 180 03C277
ignition_timing_calc_task_load_ram29f_2:     LB      A, off(0029fh)         ; 3539 0 208 180 F49F
                MOVB    r0, #0ffh              ; 353B 0 208 180 98FF
                MOV     DP, #00316h            ; 353D 0 208 180 621603
                JBS     off(0022fh).7, ignition_timing_calc_task_subb_acc_4 ; 3540 0 208 180 EF2F06
                LB      A, off(002a1h)         ; 3543 0 208 180 F4A1
                MOVB    r0, #0ffh              ; 3545 0 208 180 98FF
                INC     DP                     ; 3547 0 208 180 72
                INC     DP                     ; 3548 0 208 180 72
ignition_timing_calc_task_subb_acc_4:     SUBB    A, 0b9h                ; 3549 0 208 180 C5B9A2
                JLT     ignition_timing_calc_task_vcal_7             ; 354C 0 208 180 CA02
                CLRB    r0                     ; 354E 0 208 180 2015
ignition_timing_calc_task_vcal_7:     VCAL    7                      ; 3550 0 208 180 17
                MULB                           ; 3551 0 208 180 A234
                L       A, ACC                 ; 3553 1 208 180 E506
                J       ignition_timing_calc_task_sll_acc             ; 3555 1 208 180 038D77
ignition_timing_calc_task_load_imm_2:     L       A, #0ffffh             ; 3558 1 208 180 67FFFF
ignition_timing_calc_task_load_r1:     MOVB    r1, ACCH               ; 355B 1 208 180 C50749
                ADDB    r1, #040h              ; 355E 1 208 180 218040
                J       ignition_timing_calc_task_if_ge_goto_779d             ; 3561 1 208 180 039977
ignition_timing_calc_task_mul_acc_2:     MUL                            ; 3564 1 208 180 9035
                J       ignition_timing_calc_task_sll_acc_2             ; 3566 1 208 180 03A377
ignition_timing_calc_task_if_ram22f_bit2_set:     JBS     off(0022fh).2, ignition_timing_calc_task_store_ram29a_2 ; 3569 1 208 180 EA2F13
                CMP     A, off(00298h)         ; 356C 1 208 180 C798
                MB      off(0022fh).2, C       ; 356E 1 208 180 C42F3A
                JLT     ignition_timing_calc_task_store_ram29a_2             ; 3571 1 208 180 CA0C
                L       A, off(00298h)         ; 3573 1 208 180 E498
                ADD     A, #00020h             ; 3575 1 208 180 862000
                CAL     clamp_0_3ff_simple             ; 3578 1 208 180 32C777
                SJ      ignition_timing_calc_task_goto_77b7             ; 357B 1 208 180 CB1E
                DW  to_injtimer_store_0x166       ; 357D CB1C
ignition_timing_calc_task_store_ram29a_2:     ST      A, off(0029ah)         ; 357F 1 208 180 D49A
                SJ      ignition_timing_calc_task_goto_77b7             ; 3581 1 208 180 CB18
ignition_timing_calc_task_load_ram298:     L       A, off(00298h)         ; 3583 1 208 180 E498
                ADD     A, er1                 ; 3585 1 208 180 09
                JLT     ignition_timing_calc_task_load_imm_3             ; 3586 1 208 180 CA08
                J       ignition_timing_calc_task_cmp_acc_11             ; 3588 1 208 180 03AC77
ignition_timing_calc_task_cmp_acc_5:     CMP     A, #003ffh             ; 358B 1 208 180 C6FF03
                JLT     ignition_timing_calc_task_clear_ram22f_bit2             ; 358E 1 208 180 CA08
ignition_timing_calc_task_load_imm_3:     L       A, #003ffh             ; 3590 1 208 180 67FF03
                SJ      ignition_timing_calc_task_clear_ram22f_bit2             ; 3593 1 208 180 CB03
ignition_timing_calc_task_clear_acc:     CLR     A                      ; 3595 1 208 180 F9
                ST      A, off(0029ah)         ; 3596 1 208 180 D49A
ignition_timing_calc_task_clear_ram22f_bit2:     RB      off(0022fh).2          ; 3598 1 208 180 C42F0A
ignition_timing_calc_task_goto_77b7:     J       ignition_timing_calc_task_clear_ram22f_bit1             ; 359B 1 208 180 03B777
ignition_timing_calc_task_cmp_acc_6:     CMP     A, #00023h             ; 35A0 1 208 180 C62300
                JGE     ignition_timing_calc_task_load_er0_3             ; 35A3 1 208 180 CD01
                CLR     A                      ; 35A5 1 208 180 F9
ignition_timing_calc_task_load_er0_3:     MOV     er0, #00064h           ; 35A6 1 208 180 44986400
                MUL                            ; 35AA 1 208 180 9035
                MOV     er0, er1               ; 35AC 1 208 180 4548
                MOV     er2, #003ffh           ; 35AE 1 208 180 4698FF03
                DIV                            ; 35B2 1 208 180 9037
                LB      A, ACC                 ; 35B4 0 208 180 F506
                STB     A, 0dfh                ; 35B6 0 208 180 D5DF
                RT                             ; 35B8 0 208 180 01
; [CG] periodic_decay_task_1  @0x35B9
; [CG] TRACED: dispatch target from background_task_scheduler, runs only when the
; [CG] divide-by-10 slow tick sets off(231h).1. Calls decrement_timer_array (0x5204) over two
; [CG] RAM ranges, then increments a counter at RAM 0xE9.
periodic_decay_task_1:     MOV     DP, #00011h            ; 35B9 1 208 180 621100
                MOV     X1, #0018eh            ; 35BC 1 208 180 608E01
                CAL     decrement_timer_array             ; 35BF 1 208 180 320452
                MOV     DP, #0002bh            ; 35C2 1 208 180 622B00
                MOV     X1, #002b4h            ; 35C5 1 208 180 60B402
                CAL     decrement_timer_array             ; 35C8 1 208 180 320452
                LB      A, 0e9h                ; 35CB 0 208 180 F5E9
                ADDB    A, #001h               ; 35CD 0 208 180 8601
                JEQ     vcal3_task_c_msec_tick             ; 35CF 0 208 180 C902
                STB     A, 0e9h                ; 35D1 0 208 180 D5E9
vcal3_task_c_msec_tick:     CAL     selftest_reason_range_check             ; 35D3 0 208 180 320653
                MOV     er2, 0b6h              ; 35D6 0 208 180 B5B64A
                MOV     er0, #00021h           ; 35D9 0 208 180 44982100
                L       A, #0af7ah             ; 35DD 1 208 180 677AAF
                DIV                            ; 35E0 1 208 180 9037
                CMP     er0, #00000h           ; 35E2 1 208 180 44C00000
                JEQ     vcal3_task_c_msec_tick_store_er0             ; 35E6 1 208 180 C903
                L       A, #0ffffh             ; 35E8 1 208 180 67FFFF
vcal3_task_c_msec_tick_store_er0:     ST      A, er0                 ; 35EB 1 208 180 88
                MOV     DP, #003aah            ; 35EC 1 208 180 62AA03
                XCHG    A, [DP]                ; 35EF 1 208 180 B210
                SUB     er0, A                 ; 35F1 1 208 180 44A1
                JGE     vcal3_task_c_msec_tick_load_r1             ; 35F3 1 208 180 CD03
                CLR     A                      ; 35F5 1 208 180 F9
                SUB     A, er0                 ; 35F6 1 208 180 28
                ST      A, er0                 ; 35F7 1 208 180 88
vcal3_task_c_msec_tick_load_r1:     LB      A, r1                  ; 35F8 0 208 180 79
                JEQ     vcal3_task_c_msec_tick_load_r0             ; 35F9 0 208 180 C902
                MOVB    r0, #0ffh              ; 35FB 0 208 180 98FF
vcal3_task_c_msec_tick_load_r0:     LB      A, r0                  ; 35FD 0 208 180 78
                MOV     DP, #003a7h            ; 35FE 0 208 180 62A703
                STB     A, [DP]                ; 3601 0 208 180 D2
                MOV     DP, #003a6h            ; 3602 0 208 180 62A603
                LB      A, 0b4h                ; 3605 0 208 180 F5B4
                JNE     vcal3_task_c_msec_tick_cmp_acc             ; 3607 0 208 180 CE0D
                LB      A, [DP]                ; 3609 0 208 180 F2
                JEQ     vcal3_task_c_msec_tick_load_ram2a8             ; 360A 0 208 180 C90F
                MOVB    r6, #0ffh              ; 360C 0 208 180 9EFF
                CMPB    r6, A                  ; 360E 0 208 180 26C1
                MB      off(00225h).6, C       ; 3610 0 208 180 C4253E
                CLRB    A                      ; 3613 0 208 180 FA
                SJ      vcal3_task_c_msec_tick_store_dp_ind             ; 3614 0 208 180 CB04
vcal3_task_c_msec_tick_cmp_acc:     CMPB    A, [DP]                ; 3616 0 208 180 C2C2
                JLT     vcal3_task_c_msec_tick_load_ram2a8             ; 3618 0 208 180 CA01
vcal3_task_c_msec_tick_store_dp_ind:     STB     A, [DP]                ; 361A 0 208 180 D2
vcal3_task_c_msec_tick_load_ram2a8:     RT                     ; 361B (skeleton: check-engine lamp and code flashing removed; the lamp (P1.4) and ECU LED (P1.5) stay off)
; [CG] vcal3_task_b_body  @0x36CE
; [CG] TRACED: dispatch target from background_task_scheduler, runs only when the
; [CG] divide-by-10 slow tick sets off(231h).2. Structurally identical to
; [CG] periodic_decay_task_1 but over different RAM ranges and counter (RAM 0xE8).
vcal3_task_b_body:     MOV     DP, #00006h            ; 36CE 1 208 180 620600
                MOV     X1, #00188h            ; 36D1 1 208 180 608801
                CAL     decrement_timer_array             ; 36D4 1 208 180 320452
                MOV     DP, #0000ah            ; 36D7 1 208 180 620A00
                MOV     X1, #002aah            ; 36DA 1 208 180 60AA02
                CAL     decrement_timer_array             ; 36DD 1 208 180 320452
                LB      A, 0e8h                ; 36E0 0 208 180 F5E8
                ADDB    A, #001h               ; 36E2 0 208 180 8601
                JEQ     learn_table1_check             ; 36E4 0 208 180 C902
                STB     A, 0e8h                ; 36E6 0 208 180 D5E8
learn_table1_check:     LB      A, off(002aeh)         ; 36E8 0 208 180 F4AE
                JNE     learn_table2_check             ; 36EA 0 208 180 CE27
                MOVB    off(002aeh), #002h     ; 36EC 0 208 180 C4AE9802
                MOV     X1, #tbl_diag_snapshot_data2          ; 36F0 0 208 180 60CD6C
                MOV     DP, #001afh            ; 36F3 0 208 180 62AF01
                MOVB    r6, #027h              ; 36F6 0 208 180 9E27
learn_table1_loop:     LB      A, [DP]                ; 36F8 0 208 180 F2
                ADDB    A, #001h               ; 36F9 0 208 180 8601
                CMPCB   A, [X1]                ; 36FB 0 208 180 90AE
                JLT     learn_table1_store             ; 36FD 0 208 180 CA02
                LCB     A, [X1]                ; 36FF 0 208 180 90AA
learn_table1_store:     STB     A, [DP]                ; 3701 0 208 180 D2
                LB      A, r6                  ; 3702 0 208 180 7E
                SUBB    A, 0eah                ; 3703 0 208 180 C5EAA2
                JNE     learn_table1_advance             ; 3706 0 208 180 CE02
                STB     A, 0eah                ; 3708 0 208 180 D5EA
learn_table1_advance:     INC     X1                     ; 370A 0 208 180 70
                INC     DP                     ; 370B 0 208 180 72
                INCB    r6                     ; 370C 0 208 180 AE
                CMP     DP, #001b3h            ; 370D 0 208 180 92C0B301
                JLE     learn_table1_loop             ; 3711 0 208 180 CFE5
learn_table2_check:     LB      A, off(002b2h)         ; 3713 0 208 180 F4B2
                JNE     learn_retry_store_load_imm             ; 3715 0 208 180 CE26
                MOVB    off(002b2h), #002h     ; 3717 0 208 180 C4B29802
                LB      A, #001h               ; 371B 0 208 180 7701
                MB      C, 09fh.1              ; 371D 0 208 180 C59F29
                JLT     learn_counter_store             ; 3720 0 208 180 CA0A
                LB      A, 0edh                ; 3722 0 208 180 F5ED
                ADDB    A, #001h               ; 3724 0 208 180 8601
                CMPB    A, #020h               ; 3726 0 208 180 C620
                JLT     learn_counter_store             ; 3728 0 208 180 CA02
                LB      A, #020h               ; 372A 0 208 180 7720
learn_counter_store:     STB     A, 0edh                ; 372C 0 208 180 D5ED
                LB      A, 0ech                ; 372E 0 208 180 F5EC
                ADDB    A, #001h               ; 3730 0 208 180 8601
                CMPB    A, #020h               ; 3732 0 208 180 C620
                JLT     learn_retry_store             ; 3734 0 208 180 CA05
                RB      09fh.1                 ; 3736 0 208 180 C59F09
                LB      A, #020h               ; 3739 0 208 180 7720
learn_retry_store:     STB     A, 0ech                ; 373B 0 208 180 D5EC
learn_retry_store_load_imm:     LB      A, #006h               ; 373D 0 208 180 7706
                CMPB    A, (00185h-00180h)[USP] ; 373F 0 208 180 C305C2
                JLE     learn_retry_store_cmp_acc             ; 3742 0 208 180 CF03
                INCB    (00185h-00180h)[USP]   ; 3744 0 208 180 C30516
learn_retry_store_cmp_acc:     CMPB    A, (00184h-00180h)[USP] ; 3747 0 208 180 C304C2
                JLE     vcal3_task_a_return             ; 374A 0 208 180 CF03
                INCB    (00184h-00180h)[USP]   ; 374C 0 208 180 C30416
vcal3_task_a_return:     RT                             ; 374F 0 208 180 01
regbank_selftest2_start:     L       A, #02ba9h             ; 3750 (skeleton: serial receive interrupt off; stock 2BABh)
                MOV     X1, #002a0h            ; 3753 1 208 180 60A002
                JBR     off(00217h).2, regbank_selftest2_ie_check ; 3756 1 208 180 DA1706
                L       A, #0a9a1h             ; 3759 (skeleton: serial interrupts off; stock A9A3h)
                MOV     X1, #000a0h            ; 375C 1 208 180 60A000
regbank_selftest2_ie_check:     CMP     A, 0f2h                ; 375F 1 208 180 B5F2C2
                JNE     selftest_fail_04f             ; 3762 1 208 180 CE0B
                CMP     A, IE                  ; 3764 1 208 180 B51AC2
                JNE     selftest_fail_04f             ; 3767 1 208 180 CE06
                L       A, X1                  ; 3769 1 208 180 40
                CMP     A, 0f4h                ; 376A 1 208 180 B5F4C2
                JEQ     regbank_selftest2_range_check             ; 376D 1 208 180 C907
selftest_fail_04f:     MOVB    0ebh, #04fh            ; 376F 1 208 180 C5EB984F
                J       fault_retry_check             ; 3773 1 208 180 03D521
regbank_selftest2_range_check:     L       A, off(002eeh)         ; 3776 1 208 180 E4EE
                CMP     A, #003fah             ; 3778 1 208 180 C6FA03
                JGT     regbank_selftest2_default             ; 377B 1 208 180 C832
                MOV     X1, A                  ; 377D 1 208 180 50
                MOV     DP, 00084h[X1]         ; 377E 1 208 180 B084007A
                L       A, #05555h             ; 3782 1 208 180 675555
                CAL     selftest_regbank_verify             ; 3785 1 208 180 329352
                SLL     A                      ; 3788 1 208 180 53
                CAL     selftest_regbank_verify             ; 3789 1 208 180 329352
                L       A, X1                  ; 378C 1 208 180 40
                SUB     A, #00002h             ; 378D 1 208 180 A60200
                JGE     irqmode_dispatch             ; 3790 1 208 180 CD20
                L       A, #05555h             ; 3792 1 208 180 675555
                MOV     X1, A                  ; 3795 1 208 180 50
                CMP     A, X1                  ; 3796 1 208 180 90C2
                JNE     selftest_fail_042_alt             ; 3798 1 208 180 CE0B
                MOV     X2, A                  ; 379A 1 208 180 51
                CMP     A, X2                  ; 379B 1 208 180 91C2
                JNE     selftest_fail_042_alt             ; 379D 1 208 180 CE06
                SLL     A                      ; 379F 1 208 180 53
                MOV     X1, A                  ; 37A0 1 208 180 50
                CMP     A, X1                  ; 37A1 1 208 180 90C2
                JEQ     regbank_selftest2_check3             ; 37A3 1 208 180 C905
selftest_fail_042_alt:     MOVB    0ebh, #042h            ; 37A5 1 208 180 C5EB9842
                BRK                            ; 37A9 1 208 180 FF
regbank_selftest2_check3:     MOV     X2, A                  ; 37AA 1 208 180 51
                CMP     A, X2                  ; 37AB 1 208 180 91C2
                JNE     selftest_fail_042_alt             ; 37AD 1 208 180 CEF6
regbank_selftest2_default:     L       A, #003fah             ; 37AF 1 208 180 67FA03
irqmode_dispatch:     ST      A, off(002eeh)         ; 37B2 1 208 180 D4EE
                VCAL    4                      ; 37B4 1 208 180 14
                AND     IE, #002a0h            ; 37B5 1 208 180 B51AD0A002
                RB      PSWH.0                 ; 37BA 1 208 180 A208
                JBS     off(00217h).2, irqmode_check1 ; 37BF 1 208 180 EA170B
                RB      IRQH.7                 ; 37C2 1 208 180 C5190F
                JEQ     irqmode_check1             ; 37C5 1 208 180 C906
                SB      09eh.7                 ; 37C7 1 208 180 C59E1F
dtc04_ckp_latch_2: RB      09ch.0                 ; 37CA 1 208 180 C59C18
irqmode_check1:     SB      PSWH.0                 ; 37CD 1 208 180 A218
                CMPB    (001a9h-00180h)[USP], #029h ; 37CF 1 208 180 C329C029
                RB      PSWH.0                 ; 37D3 1 208 180 A208
                JLT     irqmode_select_b             ; 37D5 1 208 180 CA2F
                JBR     off(00217h).2, irqmode_done ; 37D7 1 208 180 DA1747
                L       A, #02ba9h             ; 37DA (skeleton: serial receive interrupt off; stock 2BABh)
                ST      A, IE                  ; 37DD 1 208 180 D51A
                ST      A, 0f2h                ; 37DF 1 208 180 D5F2
                MOV     0f4h, #002a0h          ; 37E1 1 208 180 B5F498A002
                RB      off(00217h).2          ; 37E6 1 208 180 C4170A
                MOVB    TCON2, #082h           ; 37E9 1 208 180 C5429882
                MOV     TM2, #00001h           ; 37ED 1 208 180 B538980100
                MOVB    TCON3, #08fh           ; 37F2 1 208 180 C543988F
                MOV     TM3, #00002h           ; 37F6 1 208 180 B53C980200
                SC                             ; 37FB 1 208 180 85
                MB      TCON2.4, C             ; 37FC 1 208 180 C5423C
                L       A, ACC                 ; 37FF 1 208 180 E506
                MB      TCON3.4, C             ; 3801 1 208 180 C5433C
                SJ      irqmode_done             ; 3804 1 208 180 CB1B
irqmode_select_b:     JBS     off(00217h).2, irqmode_done ; 3806 1 208 180 EA1718
                L       A, #0a9a1h             ; 3809 (skeleton: serial interrupts off; stock A9A3h)
                ST      A, IE                  ; 380C 1 208 180 D51A
                ST      A, 0f2h                ; 380E 1 208 180 D5F2
                MOV     0f4h, #000a0h          ; 3810 1 208 180 B5F498A000
                SB      off(00217h).2          ; 3815 1 208 180 C4171A
                RB      (0011dh-00180h)[USP].6 ; 3818 1 208 180 C39D0E
                RB      off(0021dh).6          ; 381B 1 208 180 C41D0E
                SB      TCON3.2                ; 381E 1 208 180 C5431A
irqmode_done:     SB      PSWH.0                 ; 3821 1 208 180 A218
                L       A, 0f2h                ; 3823 1 208 180 E5F2
                ST      A, IE                  ; 3825 1 208 180 D51A
                NOP                            ; 3827 1 208 180 00
stack_sanity_check:     CMP     SSP, #0047eh           ; 3828 1 208 180 A0C07E04
; [H] --- Post-init peripheral verification: re-reads SSP, LRB, every port direction/special-
; [H] function register, all four timer control regs, PWM control regs, A/D select/scan, and the
; [H] diagnostic-serial baud/control regs, comparing each against the exact values int_break's
; [H] init sequence (0x235F periph_init_start onward) programmed them to. Any mismatch -> stamps
; [H] trapReasonCode=0x50 (selftest_fail_050) and BRKs, forcing a full re-init retry. This is a
; [H] "did my own initialization actually stick" check, not a fresh self-test of new hardware.
                JNE     selftest_fail_050             ; 382C 1 208 180 CE64
                MOV     DP, #00400h            ; 382E 1 208 180 620004
                L       A, [DP]                ; 3831 1 208 180 E2
                JNE     selftest_fail_050             ; 3832 1 208 180 CE5E
                L       A, PSW                 ; 3834 1 208 180 E504
                AND     A, #01107h             ; 3836 1 208 180 D60711
                CMP     A, #01100h             ; 3839 1 208 180 C60011
                JNE     selftest_fail_050             ; 383C 1 208 180 CE54
                CMP     LRB, #00041h           ; 383E 1 208 180 A4C04100
                JNE     selftest_fail_050             ; 3842 1 208 180 CE4E
                CMPB    P0IO, #0ffh            ; 3844 1 208 180 C521C0FF
                JNE     selftest_fail_050             ; 3848 1 208 180 CE48
                CMPB    P1IO, #0ffh            ; 384A 1 208 180 C523C0FF
                JNE     selftest_fail_050             ; 384E 1 208 180 CE42
                CMPB    P2IO, #0ffh            ; 3850 1 208 180 C525C0FF
                JNE     selftest_fail_050             ; 3854 1 208 180 CE3C
                CMPB    P2SF, #007h            ; 3856 1 208 180 C526C007
                JNE     selftest_fail_050             ; 385A 1 208 180 CE36
                CMPB    P3IO, #0b1h            ; 385C 1 208 180 C529C0B1
                JNE     selftest_fail_050             ; 3860 1 208 180 CE30
                CMPB    P3SF, #0ffh            ; 3862 1 208 180 C52AC0FF
                JNE     selftest_fail_050             ; 3866 1 208 180 CE2A
                CMPB    P4IO, #00dh            ; 3868 1 208 180 C52DC00D
                JNE     selftest_fail_050             ; 386C 1 208 180 CE24
                CMPB    P4SF, #0f4h            ; 386E 1 208 180 C52EC0F4
                JNE     selftest_fail_050             ; 3872 1 208 180 CE1E
                LB      A, TCON0               ; 3874 0 208 180 F540
                MOVB    r0, #0f3h              ; 3876 0 208 180 98F3
                ANDB    A, r0                  ; 3878 0 208 180 58
                CMPB    A, #093h               ; 3879 0 208 180 C693
                JNE     selftest_fail_050             ; 387B 0 208 180 CE15
                LB      A, TCON1               ; 387D 0 208 180 F541
                ANDB    A, r0                  ; 387F 0 208 180 58
                CMPB    A, #053h               ; 3880 0 208 180 C653
                JNE     selftest_fail_050             ; 3882 0 208 180 CE0E
                LB      A, TCON2               ; 3884 0 208 180 F542
                ANDB    A, r0                  ; 3886 0 208 180 58
                CMPB    A, #092h               ; 3887 0 208 180 C692
                JNE     selftest_fail_050             ; 3889 0 208 180 CE07
                LB      A, TCON3               ; 388B 0 208 180 F543
                ANDB    A, r0                  ; 388D 0 208 180 58
                CMPB    A, #093h               ; 388E 0 208 180 C693
                JEQ     periph_init_verify_pwm_adc             ; 3890 0 208 180 C905
selftest_fail_050:     MOVB    0ebh, #050h            ; 3892 0 208 180 C5EB9850
                BRK                            ; 3896 0 208 180 FF
periph_init_verify_pwm_adc:     LB      A, PWCON0              ; 3897 0 208 180 F578
                ANDB    A, #07bh               ; 3899 0 208 180 D67B
                CMPB    A, #03ah               ; 389B 0 208 180 C63A
                JNE     selftest_fail_050             ; 389D 0 208 180 CEF3
                LB      A, PWCON1              ; 389F 0 208 180 F57A
                ANDB    A, #07bh               ; 38A1 0 208 180 D67B
                CMPB    A, #07ah               ; 38A3 0 208 180 C67A
                JNE     selftest_fail_050             ; 38A5 0 208 180 CEEB
                LB      A, ADSEL               ; 38A7 0 208 180 F559
                ANDB    A, #05fh               ; 38A9 0 208 180 D65F
                JNE     selftest_fail_050             ; 38AB 0 208 180 CEE5
                LB      A, ADSCAN              ; 38AD 0 208 180 F558
                ANDB    A, #05fh               ; 38AF 0 208 180 D65F
                CMPB    A, #010h               ; 38B1 0 208 180 C610
                JNE     selftest_fail_050             ; 38B3 0 208 180 CEDD
                J       periph_init_verify_pwm_adc_and_ie ; 38B5 (skeleton: no serial registers to verify)
periph_init_verify_pwm_adc_and_ie:     AND     IE, #002a0h            ; 38D8 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 38DD 0 208 180 A208
                MOV     er0, TM0               ; 38DF 0 208 180 B53048
                MOV     er1, TM1               ; 38E2 0 208 180 B53449
                MOV     er2, TM2               ; 38E5 0 208 180 B5384A
                MOV     er3, TM3               ; 38E8 0 208 180 B53C4B
                SB      PSWH.0                 ; 38EB 0 208 180 A218
                NOP                            ; 38ED 0 208 180 00
                RB      PSWH.0                 ; 38EE 0 208 180 A208
                MOV     X1, TM0                ; 38F0 0 208 180 B53078
                MOV     X2, TM1                ; 38F3 0 208 180 B53479
                MOV     DP, TM2                ; 38F6 0 208 180 B5387A
                SB      PSWH.0                 ; 38F9 0 208 180 A218
                L       A, 0f2h                ; 38FB 1 208 180 E5F2
                ST      A, IE                  ; 38FD 1 208 180 D51A
                L       A, X1                  ; 38FF 1 208 180 40
; [H] --- Oscillator/timer cross-check: snapshots TM0/TM1/TM2 into X1/X2/DP, re-enables
; [H] interrupts briefly (IE/PSWH toggling), re-snapshots into er0/er1/er2, then verifies the
; [H] deltas fall within expected ranges (0x22, 0x80, 0x22, a ratio check against er1>>2) --
; [H] confirms the timers are actually counting at the rate the code expects (i.e. the clock
; [H] source/oscillator is running correctly) before trusting any timing-dependent logic
; [H] (ignition/injection scheduling) downstream. Out-of-range -> selftest_fail_04b.
                SUB     A, er0                 ; 3900 1 208 180 28
                ST      A, er0                 ; 3901 1 208 180 88
                JEQ     selftest_fail_04b             ; 3902 1 208 180 C93D
                CMP     A, #00021h             ; 3904 1 208 180 C62100
                JGE     selftest_fail_04b             ; 3907 1 208 180 CD38
                L       A, X2                  ; 3909 1 208 180 41
                SUB     A, er1                 ; 390A 1 208 180 29
                ST      A, er1                 ; 390B 1 208 180 89
                JEQ     selftest_fail_04b             ; 390C 1 208 180 C933
                CMP     A, #0007fh             ; 390E 1 208 180 C67F00
                JGE     selftest_fail_04b             ; 3911 1 208 180 CD2E
                L       A, DP                  ; 3913 1 208 180 42
                SUB     A, er2                 ; 3914 1 208 180 2A
                MOV     X2, A                  ; 3915 1 208 180 51
                JEQ     selftest_fail_04b             ; 3916 1 208 180 C929
                CMP     A, #00021h             ; 3918 1 208 180 C62100
                JGE     selftest_fail_04b             ; 391B 1 208 180 CD24
                L       A, er3                 ; 391D 1 208 180 37
                SUB     A, er2                 ; 391E 1 208 180 2A
                MB      C, ACCH.7              ; 391F 1 208 180 C5072F
                JGE     clock_selftest_check2             ; 3922 1 208 180 CD01
                VCAL    7                      ; 3924 1 208 180 17
clock_selftest_check2:     CMP     A, #00002h             ; 3925 1 208 180 C60200
                JGE     selftest_fail_04b             ; 3928 1 208 180 CD17
                L       A, er1                 ; 392A 1 208 180 35
                SRL     A                      ; 392B 1 208 180 63
                SRL     A                      ; 392C 1 208 180 63
                SUB     A, X2                  ; 392D 1 208 180 91A2
                JGE     clock_selftest_check3             ; 392F 1 208 180 CD01
                VCAL    7                      ; 3931 1 208 180 17
clock_selftest_check3:     CMP     A, #00002h             ; 3932 1 208 180 C60200
                JGE     selftest_fail_04b             ; 3935 1 208 180 CD0A
                L       A, X2                  ; 3937 1 208 180 41
                SUB     A, er0                 ; 3938 1 208 180 28
                JGE     clock_selftest_check4             ; 3939 1 208 180 CD01
                VCAL    7                      ; 393B 1 208 180 17
clock_selftest_check4:     CMP     A, #00002h             ; 393C 1 208 180 C60200
                JLT     clock_selftest_passed             ; 393F 1 208 180 CA05
selftest_fail_04b:     MOVB    0ebh, #04bh            ; 3941 1 208 180 C5EB984B
                BRK                            ; 3945 1 208 180 FF
clock_selftest_passed:     VCAL    4                      ; 3946 1 208 180 14
                CAL     boot_completion_helper             ; 3947 1 208 180 326055
                MOVB    r0, #001h              ; 394A 1 208 180 9801
                JBR     off(00217h).2, warmcold_ie_setup ; 394C 1 208 180 DA1702
                MOVB    r0, #006h              ; 394F 1 208 180 9806
warmcold_ie_setup:     L       A, 0f4h                ; 3951 1 208 180 E5F4
                ST      A, IE                  ; 3953 1 208 180 D51A
                RB      PSWH.0                 ; 3955 1 208 180 A208
                RB      off(00231h).5          ; 3957 1 208 180 C4310D
                JBR     off(00217h).4, warmcold_tm2_check ; 395A 1 208 180 DC1703
                J       warmrestart_tm3_resync             ; 395D 1 208 180 03FB39
warmcold_tm2_check:     JNE     coldstart_full_reset             ; 3960 1 208 180 CE12
                LB      A, r0                  ; 3962 0 208 180 78
                CMPB    A, 0deh                ; 3963 0 208 180 C5DEC2
                JLT     coldstart_full_reset             ; 3966 0 208 180 CA0C
                JNE     warmrestart_path             ; 3968 0 208 180 CE07
                L       A, TM2                 ; 396A 1 208 180 E538
                CMP     A, 0e2h                ; 396C 1 208 180 B5E2C2
                JGE     coldstart_full_reset             ; 396F 1 208 180 CD03
warmrestart_path:     J       warmcold_reconverge             ; 3971 1 208 180 03023A
coldstart_full_reset:     SB      off(00217h).4          ; 3974 1 208 180 C4171C
                CLRB    A                      ; 3977 0 208 180 FA
                MOVB    0d2h, #002h            ; 3978 0 208 180 C5D29802
                STB     A, 0d3h                ; 397C 0 208 180 D5D3
                MOVB    (0012ah-00180h)[USP], #005h ; 397E 0 208 180 C3AA9805
                STB     A, (0012bh-00180h)[USP] ; 3982 0 208 180 D3AB
                MOVB    (00135h-00180h)[USP], #004h ; 3984 0 208 180 C3B59804
                MOV     USP, #00380h           ; 3988 0 208 380 A1988003
                L       A, #0ffffh             ; 398C 1 208 380 67FFFF
                ST      A, (0036ch-00380h)[USP] ; 398F 1 208 380 D3EC
                ST      A, (0036eh-00380h)[USP] ; 3991 1 208 380 D3EE
                ST      A, (00370h-00380h)[USP] ; 3993 1 208 380 D3F0
                ST      A, 0ach                ; 3995 1 208 380 D5AC
                CLR     A                      ; 3997 1 208 380 F9
                ST      A, (00360h-00380h)[USP] ; 3998 1 208 380 D3E0
                ST      A, (00362h-00380h)[USP] ; 399A 1 208 380 D3E2
                ST      A, (00364h-00380h)[USP] ; 399C 1 208 380 D3E4
                ST      A, (00366h-00380h)[USP] ; 399E 1 208 380 D3E6
                ST      A, (00368h-00380h)[USP] ; 39A0 1 208 380 D3E8
                ST      A, (0036ah-00380h)[USP] ; 39A2 1 208 380 D3EA
                MOV     USP, #00180h           ; 39A4 1 208 180 A1988001
                CLRB    A                      ; 39A8 0 208 180 FA
                STB     A, off(00236h)         ; 39A9 0 208 180 D436
                STB     A, (0012dh-00180h)[USP] ; 39AB 0 208 180 D3AD
                STB     A, 0abh                ; 39AD 0 208 180 D5AB
                SB      P4.0                   ; 39AF 0 208 180 C52C18
                SB      (0011eh-00180h)[USP].0 ; 39B2 0 208 180 C39E18
                MOVB    0d0h, #004h            ; 39B5 0 208 180 C5D09804
                SB      (00122h-00180h)[USP].5 ; 39B9 0 208 180 C3A21D
                L       A, #0ffffh             ; 39BC 1 208 180 67FFFF
                ST      A, 0d4h                ; 39BF 1 208 180 D5D4
                ST      A, 0e0h                ; 39C1 1 208 180 D5E0
                CLR     X1                     ; 39C3 1 208 180 9015
                L       A, #0ff04h             ; 39C5 1 208 180 6704FF
                ST      A, 00356h[X1]          ; 39C8 1 208 180 D05603
                ST      A, 0035ah[X1]          ; 39CB 1 208 180 D05A03
                ST      A, 0035eh[X1]          ; 39CE 1 208 180 D05E03
                LB      A, #0ffh               ; 39D1 0 208 180 77FF
                STB     A, 00355h[X1]          ; 39D3 0 208 180 D05503
                STB     A, 00359h[X1]          ; 39D6 0 208 180 D05903
                STB     A, 0035dh[X1]          ; 39D9 0 208 180 D05D03
                ORB     0a0h, #01ch            ; 39DC 0 208 180 C5A0E01C
                J       coldstart_full_reset_andb_p1             ; 39E0 0 208 180 03925F
coldstart_full_reset_goto_7831:     J       coldstart_full_reset_clear_ram221_bit7             ; 39E5 0 208 180 033178
coldstart_full_reset_orb_tcon3:     ORB     TCON3, #00ch           ; 39E8 0 208 180 C543E00C
                CLR     A                      ; 39EC 1 208 180 F9
                ST      A, (00120h-00180h)[USP] ; 39ED 1 208 180 D3A0
                ST      A, (0011ch-00180h)[USP] ; 39EF 1 208 180 D39C
                ST      A, off(0021ch)         ; 39F1 1 208 180 D41C
                ST      A, (001d0h-00180h)[USP] ; 39F3 1 208 180 D350
                ST      A, (001ceh-00180h)[USP] ; 39F5 1 208 180 D34E
                J       coldstart_full_reset_store_ram0f0             ; 39F7 1 208 180 039C5F
warmrestart_tm3_resync:     L       A, TM3                 ; 39FB 1 208 180 E53C
                SUB     A, #00001h             ; 39FD 1 208 180 A60100
                ST      A, TMR3                ; 3A00 1 208 180 D53E
warmcold_reconverge:     SB      PSWH.0                 ; 3A02 1 208 180 A218
                L       A, 0f2h                ; 3A04 1 208 180 E5F2
                ST      A, IE                  ; 3A06 1 208 180 D51A
                SC                             ; 3A08 1 208 180 85
                JBS     off(00217h).4, warmcold_deg_flag ; 3A09 1 208 180 EC1710
                JBS     off(00211h).0, warmcold_deg_select ; 3A0C 1 208 180 E81103
                JBR     off(00217h).5, warmcold_state_stamp ; 3A0F 1 208 180 DD1730
warmcold_deg_select:     LB      A, #012h               ; 3A12 0 208 180 7712
                JBS     off(00217h).5, warmcold_deg_check ; 3A14 0 208 180 ED1702
                LB      A, #01dh               ; 3A17 0 208 180 771D
warmcold_deg_check:     CMPB    A, 0adh                ; 3A19 0 208 180 C5ADC2
warmcold_deg_flag:     MB      off(00217h).5, C       ; 3A1C 0 208 180 C4173D
                JGE     warmcold_state_stamp             ; 3A1F 0 208 180 CD21
                JBR     off(00211h).0, warmcold_msec_reset ; 3A21 0 208 180 D81103
                SB      off(00230h).4          ; 3A24 0 208 180 C4301C
warmcold_msec_reset:     ANDB    098h, #0e2h            ; 3A27 0 208 180 C598D0E2
                ANDB    099h, #0cdh            ; 3A2B 0 208 180 C599D0CD
                ANDB    09ah, #008h            ; 3A2F 0 208 180 C59AD008
                ANDB    09bh, #007h            ; 3A33 0 208 180 C59BD007
                CLRB    A                      ; 3A37 0 208 180 FA
                STB     A, 0e9h                ; 3A38 0 208 180 D5E9
                STB     A, 0e8h                ; 3A3A 0 208 180 D5E8
                NOP                            ; 3A3C 0 208 180 00
                NOP                            ; 3A3D 0 208 180 00
                NOP                            ; 3A3E 0 208 180 00
                JBR     off(00217h).4, tps_learn_vcal3_call ; 3A3F 0 208 180 DC1704
warmcold_state_stamp:     MOVB    off(002bah), #063h     ; 3A42 0 208 180 C4BA9863
tps_learn_vcal3_call:     VCAL    4                      ; 3A46 0 208 180 14
                LB      A, off(002dfh)         ; 3A47 0 208 180 F4DF
                JNE     tps_learn_vcal3_call_load_dp             ; 3A49 0 208 180 CE52
                MOVB    off(002dfh), #006h     ; 3A4B 0 208 180 C4DF9806
                LB      A, #0fah               ; 3A4F 0 208 180 77FA
                JBS     off(00217h).4, tps_learn_vcal3_call_store_ram2a3 ; 3A51 0 208 180 EC1747
                STB     A, r0                  ; 3A54 0 208 180 88
                LB      A, #07bh               ; 3A55 0 208 180 777B
                STB     A, r1                  ; 3A57 0 208 180 89
                STB     A, r2                  ; 3A58 0 208 180 8A
                JBS     off(0021ah).2, tps_learn_table_store_load_r0 ; 3A59 0 208 180 EA1A2E
                JBS     off(0021ah).3, tps_learn_table_store_load_r0 ; 3A5C 0 208 180 EB1A2B
                LB      A, 0bch                ; 3A5F 0 208 180 F5BC
                CMPB    A, r1                  ; 3A61 0 208 180 49
                JGE     tps_learn_table_store_load_r0             ; 3A62 0 208 180 CD26
                STB     A, r1                  ; 3A64 0 208 180 89
                MOVB    r3, off(002a4h)        ; 3A65 0 208 180 C4A44B
                SUBB    A, r3                  ; 3A68 0 208 180 2B
                JLT     tps_learn_table_store             ; 3A69 0 208 180 CA17
                CMPB    A, #004h               ; 3A6B 0 208 180 C604
                JGE     tps_learn_table_store_load_r0             ; 3A6D 0 208 180 CD1B
                SUBB    off(002a3h), #001h     ; 3A6F 0 208 180 C4A3A001
                JNE     tps_learn_table_store_load_dp             ; 3A73 0 208 180 CE1B
                MOV     DP, #00311h            ; 3A75 0 208 180 621103
                LB      A, r3                  ; 3A78 0 208 180 7B
                STB     A, [DP]                ; 3A79 0 208 180 D2
                MOV     DP, #00310h            ; 3A7A 0 208 180 621003
                LB      A, #0ffh               ; 3A7D 0 208 180 77FF
                STB     A, [DP]                ; 3A7F 0 208 180 D2
                SJ      tps_learn_table_store_load_dp             ; 3A80 0 208 180 CB0E
tps_learn_table_store:     MOV     DP, #00310h            ; 3A82 0 208 180 621003
                LB      A, [DP]                ; 3A85 0 208 180 F2
                JNE     tps_learn_table_store_load_r0             ; 3A86 0 208 180 CE02
                MOVB    r0, #053h              ; 3A88 0 208 180 9853
tps_learn_table_store_load_r0:     LB      A, r0                  ; 3A8A 0 208 180 78
                STB     A, off(002a3h)         ; 3A8B 0 208 180 D4A3
                LB      A, r1                  ; 3A8D 0 208 180 79
                STB     A, off(002a4h)         ; 3A8E 0 208 180 D4A4
tps_learn_table_store_load_dp:     MOV     DP, #00311h            ; 3A90 0 208 180 621103
                LB      A, [DP]                ; 3A93 0 208 180 F2
                CMPB    A, r2                  ; 3A94 0 208 180 4A
                JLT     tps_learn_vcal3_call_load_dp             ; 3A95 0 208 180 CA06
                LB      A, r2                  ; 3A97 0 208 180 7A
                STB     A, [DP]                ; 3A98 0 208 180 D2
                SJ      tps_learn_vcal3_call_load_dp             ; 3A99 0 208 180 CB02
tps_learn_vcal3_call_store_ram2a3:     STB     A, off(002a3h)         ; 3A9B 0 208 180 D4A3
tps_learn_vcal3_call_load_dp:     MOV     DP, #0030ch            ; 3A9D 0 208 180 620C03
                L       A, [DP]                ; 3AA0 1 208 180 E2
                CMP     A, #00010h             ; 3AA1 1 208 180 C61000
                JLT     fueltbl_default_load             ; 3AA4 1 208 180 CA05
                CMP     A, #01000h             ; 3AA6 1 208 180 C60010
                JLE     fueltbl_sanitize_loop             ; 3AA9 1 208 180 CF04
fueltbl_default_load:     CAL     stub_or_short_helper             ; 3AAB 1 208 180 326B51
                ST      A, [DP]                ; 3AAE 1 208 180 D2
fueltbl_sanitize_loop:     MOV     DP, #00300h            ; 3AAF 1 208 180 620003
fueltbl_sanitize_check:     JBR     off(00216h).2, fueltbl_range_check ; 3AB2 1 208 180 DA1605
                MB      C, 0a0h.0              ; 3AB5 1 208 180 C5A028
                JLT     fueltbl_default_value             ; 3AB8 1 208 180 CA0C
fueltbl_range_check:     CMP     [DP], #09862h          ; 3ABA 1 208 180 B2C06298
                JGT     fueltbl_default_value             ; 3ABE 1 208 180 C806
                CMP     [DP], #07133h                         ; 3AC0 1 208 180 B2C03371
                JGE     fueltbl_sanitize_advance             ; 3AC4 1 208 180 CD04
fueltbl_default_value:     MOV     [DP], #08000h          ; 3AC6 1 208 180 B2980080
fueltbl_sanitize_advance:     ADD     DP, #00004h            ; 3ACA 1 208 180 92800400
                CMP     DP, #0030ch            ; 3ACE 1 208 180 92C00C03
                JLT     fueltbl_sanitize_check             ; 3AD2 1 208 180 CADE
                LB      A, (00120h-00180h)[USP] ; 3AD4 0 208 180 F3A0
                MB      C, ACC.2               ; 3AD6 0 208 180 C5062A
                JGE     sensor_check_vcal3             ; 3AD9 0 208 180 CD5F
                L       A, 0f4h                ; 3ADB 1 208 180 E5F4
                ST      A, IE                  ; 3ADD 1 208 180 D51A
                RB      PSWH.0                 ; 3ADF 1 208 180 A208
                MOVB    r0, (001b6h-00180h)[USP] ; 3AE1 1 208 180 C33648
                MOVB    r1, (001beh-00180h)[USP] ; 3AE4 1 208 180 C33E49
                MOVB    r2, (001bfh-00180h)[USP] ; 3AE7 1 208 180 C33F4A
                MOVB    r3, (00134h-00180h)[USP] ; 3AEA 1 208 180 C3B44B
                SB      PSWH.0                 ; 3AED 1 208 180 A218
                L       A, 0f2h                ; 3AEF 1 208 180 E5F2
                ST      A, IE                  ; 3AF1 1 208 180 D51A
                LB      A, r3                  ; 3AF3 0 208 180 7B
                CAL     knock_helper1             ; 3AF4 0 208 180 32D74C
                CMPB    A, r0                  ; 3AF7 0 208 180 48
                JNE     knock_check_alt_path             ; 3AF8 0 208 180 CE0D
                LB      A, r2                  ; 3AFA 0 208 180 7A
                EXTND                          ; 3AFB 1 208 180 F8
                SLL     A                      ; 3AFC 1 208 180 53
                LC      A, fueltbl_sanitize_advance_tbl[ACC]       ; 3AFD 1 208 180 B506A9126D
                JEQ     sensor_check_vcal3             ; 3B02 1 208 180 C936
                CMP     A, er0                 ; 3B04 1 208 180 48
                JEQ     sensor_check_vcal3             ; 3B05 1 208 180 C933
knock_check_alt_path:     L       A, 0f4h                ; 3B07 1 208 180 E5F4
                ST      A, IE                  ; 3B09 1 208 180 D51A
                RB      PSWH.0                 ; 3B0B 1 208 180 A208
                RB      TCON0.4                ; 3B0D 1 208 180 C5400C
                RB      TCON0.2                ; 3B10 1 208 180 C5400A
                LB      A, #00fh               ; 3B13 0 208 180 770F
                STB     A, (001bfh-00180h)[USP] ; 3B15 0 208 180 D33F
                STB     A, (001b7h-00180h)[USP] ; 3B17 0 208 180 D337
                ORB     P2, A                  ; 3B19 0 208 180 C524E1
                SB      TCON0.2                ; 3B1C 0 208 180 C5401A
                LB      A, (00134h-00180h)[USP] ; 3B1F 0 208 180 F3B4
                CAL     knock_helper1             ; 3B21 0 208 180 32D74C
                STB     A, (001b6h-00180h)[USP] ; 3B24 0 208 180 D336
                XORB    A, #0ffh               ; 3B26 0 208 180 F6FF
                MB      C, ACC.7               ; 3B28 0 208 180 C5062F
                ROLB    A                      ; 3B2B 0 208 180 33
                STB     A, (001beh-00180h)[USP] ; 3B2C 0 208 180 D33E
                RB      TCON0.2                ; 3B2E 0 208 180 C5400A
                SB      TCON0.4                ; 3B31 0 208 180 C5401C
                SB      PSWH.0                 ; 3B34 0 208 180 A218
                L       A, 0f2h                ; 3B36 1 208 180 E5F2
                ST      A, IE                  ; 3B38 1 208 180 D51A
sensor_check_vcal3:     VCAL    4                      ; 3B3A 1 208 180 14
                MOV     DP, #003c5h            ; 3B3B 1 208 180 62C503
                LB      A, [DP]                ; 3B3E 0 208 180 F2
                STB     A, 0c3h                ; 3B3F 0 208 180 D5C3
                J       sensor_check_vcal3_if_ram217_bit5_set             ; 3B47 0 208 180 03FD76
sensor_check_vcal3_cmp_ram236:     CMPB    off(00236h), #002h     ; 3B4A 0 208 180 C436C002
                JGE     sensor_check_vcal3_if_ram230_bit4_clr             ; 3B4E 0 208 180 CD04
                MOVB    off(002beh), #064h     ; 3B50 0 208 180 C4BE9864
sensor_check_vcal3_if_ram230_bit4_clr:     JBR     off(00230h).4, sensor_check_clear ; 3B54 0 208 180 DC3010
                LB      A, off(00234h)         ; 3B57 0 208 180 F434
                SUBB    A, ADCR6H              ; 3B59 0 208 180 C56DA2
                JGE     sensor_check_result             ; 3B5C 0 208 180 CD01
                VCAL    7                      ; 3B5E 0 208 180 17
sensor_check_result:     CMPB    A, #002h               ; 3B5F 0 208 180 C602
                JGE     sensor_check_set             ; 3B61 0 208 180 CD07
                LB      A, off(002beh)         ; 3B63 0 208 180 F4BE
                JEQ     dtc05_map_range_latch             ; 3B65 0 208 180 C906
sensor_check_clear:     RC                             ; 3B67 0 208 180 95
                SJ      dtc05_map_range_latch             ; 3B68 0 208 180 CB03
sensor_check_set:     SB      off(00230h).5          ; 3B6A 0 208 180 C4301D
dtc05_map_range_latch:     RB      098h.3                 ; 3B6D 0 208 180 C5983B
                MOV     DP, #003c8h            ; 3B70 0 208 180 62C803
                LB      A, [DP]                ; 3B73 0 208 180 F2
                STB     A, r1                  ; 3B74 0 208 180 89
                RC                             ; 3B75 0 208 180 95
                LB      A, #0fch               ; 3B79 0 208 180 77FC
                CMPB    A, r1                  ; 3B7B 0 208 180 49
                JLT     dtc06_ect_latch             ; 3B7C 0 208 180 CA03
                LB      A, r1                  ; 3B7E 0 208 180 79
                CMPB    A, #004h               ; 3B7F 0 208 180 C604
dtc06_ect_latch:     RB      098h.1                 ; 3B81 0 208 180 C59839
                JLT     ect_simulate_ramp_load_ram0c1             ; 3B87 0 208 180 CA2F
                JBS     off(00210h).7, ect_fault_range_check_load_dp ; 3B89 0 208 180 EF1032
                SUBB    A, off(002a5h)         ; 3B8C 0 208 180 A7A5
                JGE     ect_fault_delta_check             ; 3B8E 0 208 180 CD01
                VCAL    7                      ; 3B90 0 208 180 17
ect_fault_delta_check:     CMPB    A, #002h               ; 3B91 0 208 180 C602
                JGT     ect_fault_normal_store             ; 3B93 0 208 180 C839
                LB      A, off(002b9h)         ; 3B95 0 208 180 F4B9
                JNE     sensor_bank_ect_check_clear_carry             ; 3B97 0 208 180 CE3C
                LB      A, r1                  ; 3B99 0 208 180 79
                JBS     off(00217h).4, ect_fault_range_check_load_dp ; 3B9A 0 208 180 EC1721
                CMPB    A, off(002a6h)         ; 3B9D 0 208 180 C7A6
                JGT     sensor_bank_ect_check             ; 3B9F 0 208 180 C830
                SJ      ect_fault_range_check_load_dp             ; 3BA1 0 208 180 CB1B
ect_simulate_ramp_load_ram0c1:     MOVB    0c1h, #03bh            ; 3BB8 0 208 180 C5C1983B
                SJ      sensor_bank_ect_check             ; 3BBC 0 208 180 CB13
ect_fault_range_check_load_dp:     MOV     DP, #000c1h            ; 3BBE 0 208 180 62C100
                CAL     ect_smooth_helper             ; 3BC1 0 208 180 324852
                JBS     off(00217h).5, ect_step_call ; 3BC4 0 208 180 ED1704
                MOV     DP, #00352h            ; 3BC7 0 208 180 625203
                STB     A, [DP]                ; 3BCA 0 208 180 D2
ect_step_call:     CAL     ect_step_helper             ; 3BCB 0 208 180 322F52
ect_fault_normal_store:     MOVB    off(002a5h), r1        ; 3BCE 0 208 180 217CA5
sensor_bank_ect_check:     MOVB    off(002b9h), #005h     ; 3BD1 0 208 180 C4B99805
sensor_bank_ect_check_clear_carry:     RC                             ; 3BD5 0 208 180 95
                JBR     off(00217h).4, dtc08_tdc_latch ; 3BD9 0 208 180 DC170B
                MB      C, off(00211h).0       ; 3BDC 0 208 180 C41128
                JBR     off(00216h).3, dtc08_tdc_latch ; 3BDF 0 208 180 DB1605
                JGE     dtc08_tdc_latch             ; 3BE2 0 208 180 CD03
                MB      C, off(00211h).5       ; 3BE4 0 208 180 C4112D
dtc08_tdc_latch:     RB      098h.5                 ; 3BE7 0 208 180 C5983D
                J       iat_range_check ; (skeleton: fault flags are always clear)
iat_range_check:     LB      A, #0fch               ; 3BF3 0 208 180 77FC
                MOV     DP, #003c0h            ; 3BF5 0 208 180 62C003
                CMPB    A, [DP]                ; 3BF8 0 208 180 C2C2
                JLT     dtc10_iat_latch             ; 3BFA 0 208 180 CA0C
                LB      A, [DP]                ; 3BFC 0 208 180 F2
                CMPB    A, #004h               ; 3BFD 0 208 180 C604
                JLT     dtc10_iat_latch             ; 3BFF 0 208 180 CA07
                MOV     DP, #000c0h            ; 3C01 0 208 180 62C000
                CAL     ect_smooth_helper             ; 3C04 0 208 180 324852
iat_check_return:     RC                             ; 3C07 0 208 180 95
dtc10_iat_latch:     RB      098h.6                 ; 3C08 0 208 180 C5983E
                LB      A, #080h               ; 3C0B 0 208 180 7780
                RC                             ; 3C0D 0 208 180 95
                JBS     off(00217h).6, sensor_bank_store_e3 ; 3C0E 0 208 180 EE1714
                JBS     off(00219h).1, sensor_bank_store_e3 ; 3C11 0 208 180 E91911
                MOV     DP, #003c6h            ; 3C17 0 208 180 62C603
                LB      A, #0ffh               ; 3C1A 0 208 180 77FF
                CMPB    A, [DP]                ; 3C1C 0 208 180 C2C2
                JLT     dtc_bit08_latch             ; 3C1E 0 208 180 CA07
                LB      A, [DP]                ; 3C20 0 208 180 F2
                CMPB    A, #000h               ; 3C21 0 208 180 C600
                JLT     dtc_bit08_latch             ; 3C23 0 208 180 CA02
sensor_bank_store_e3:     STB     A, 0c7h                ; 3C25 0 208 180 D5C7
dtc_bit08_latch:     RB      098h.7                 ; 3C27 0 208 180 C5983F
                JBR     off(00227h).4, sensor_bank_stamp_bc ; 3C2A 0 208 180 DC2703
                J       sensor_bank_bc_alt ; (skeleton: fault flags are always clear)
sensor_bank_stamp_bc:     MOVB    0a4h, #0f9h            ; 3C30 0 208 180 C5A498F9
                SJ      dcode14_return             ; 3C34 0 208 180 CB18
sensor_bank_bc_alt:     CLR     A                      ; 3C36 1 208 180 F9
                LB      A, #0ffh               ; 3C37 0 208 180 77FF
                MOV     DP, #003c1h            ; 3C39 0 208 180 62C103
                CMPB    A, [DP]                ; 3C3C 0 208 180 C2C2
                JLT     dcode14_check             ; 3C3E 0 208 180 CA0F
                LB      A, [DP]                ; 3C40 0 208 180 F2
                CMPB    A, #000h               ; 3C41 0 208 180 C600
                JLT     dcode14_check             ; 3C43 0 208 180 CA0A
                CAL     subtract24_clamp_byte             ; 3C45 0 208 180 32214F
                MOV     DP, #000a4h            ; 3C48 0 208 180 62A400
                CAL     ect_smooth_helper             ; 3C4B 0 208 180 324852
dcode14_return:     RC                             ; 3C4E 0 208 180 95
dcode14_check:     J       dtc13_baro_latch             ; 3C4F 0 208 180 03AE5F
dcode14_check_if_ram217_bit5_set:     JBS     off(00217h).5, dcode14_clear ; 3C52 0 208 180 ED171B
                LB      A, 0c3h                ; 3C58 0 208 180 F5C3
                MOV     X1, #tbl_dcode14_lo          ; 3C5A 0 208 180 60246B
                VCAL    3                      ; 3C5D 0 208 180 13
                CMPB    A, off(0025ah)         ; 3C5E 0 208 180 C75A
                JLT     dcode14_clear             ; 3C60 0 208 180 CA0E
                LB      A, 0c3h                ; 3C62 0 208 180 F5C3
                MOV     X1, #tbl_dcode14_hi          ; 3C64 0 208 180 602A6B
                VCAL    3                      ; 3C67 0 208 180 13
                CMPB    A, off(0025ah)         ; 3C68 0 208 180 C75A
                JGE     dcode14_clear             ; 3C6A 0 208 180 CD04
                LB      A, off(002bdh)         ; 3C6C 0 208 180 F4BD
                JEQ     dtc14_iacv_latch             ; 3C6E 0 208 180 C901
dcode14_clear:     RC                             ; 3C70 0 208 180 95
dtc14_iacv_latch:     RB      099h.3                 ; 3C71 0 208 180 C5993B
                LB      A, #044h               ; 3C74 0 208 180 7744
                CMPB    A, 0c3h                ; 3C76 0 208 180 C5C3C2
                JGE     dtc17_vss_latch             ; 3C79 0 208 180 CD10
                CMPB    off(00236h), #0b0h     ; 3C7B 0 208 180 C436C0B0
                JGE     dtc17_vss_latch             ; 3C7F 0 208 180 CD0A
                RC                             ; 3C81 0 208 180 95
                JBR     off(00231h).3, dtc17_vss_latch ; 3C85 0 208 180 DB3103
                MB      C, off(0021ch).4       ; 3C88 0 208 180 C41C2C
dtc17_vss_latch:     RB      099h.4                 ; 3C8B 0 208 180 C5993C
                RC                             ; 3C8E 0 208 180 95
                JBS     off(00227h).2, dtc_bit0F_latch ; 3C8F 0 208 180 EA2713
                JBR     off(00216h).3, dtc_bit0F_latch ; 3C92 0 208 180 DB1610
                MOV     DP, #00f00h            ; 3C98 0 208 180 62000F
                LB      A, [DP]                ; 3C9B 0 208 180 F2
                MB      C, ACC.4               ; 3C9C 0 208 180 C5062C
                JBS     off(0022fh).0, dtc_bit0F_latch ; 3C9F 0 208 180 E82F03
                XORB    PSWH, #080h            ; 3CA2 0 208 180 A2F080
dtc_bit0F_latch:     RB      099h.6                 ; 3CA5 0 208 180 C5993E
                VCAL    4                      ; 3CA8 0 208 180 14
                J       skel_block5_end ; (skeleton: diagnostics block removed)
skel_block5_end: VCAL    4                      ; 3DEB 0 208 180 14
                LB      A, 0c1h                ; 3DEC 0 208 180 F5C1
                MOV     X1, #tbl_ect_fuelcorrect          ; 3DEE 0 208 180 60636A
                MOV     X2, #knockwindow_result_tbl_4          ; 3DF1 0 208 180 61576A
                CMPB    A, #023h               ; 3DF4 0 208 180 C623
                JLT     knockwindow_result_store_carry_ram221_bit2             ; 3DF6 0 208 180 CA06
                MOV     X1, #knockwindow_result_tbl_3          ; 3DF8 0 208 180 60456A
                MOV     X2, #knockwindow_result_tbl_2          ; 3DFB 0 208 180 61376A
knockwindow_result_store_carry_ram221_bit2:     MB      off(00221h).2, C       ; 3DFE 0 208 180 C4213A
                VCAL    0                      ; 3E01 0 208 180 10
                STB     A, r3                  ; 3E02 0 208 180 8B
                MOV     X1, X2                 ; 3E03 0 208 180 9178
                LB      A, 0c1h                ; 3E05 0 208 180 F5C1
                VCAL    0                      ; 3E07 0 208 180 10
                STB     A, r2                  ; 3E08 0 208 180 8A
                MOV     off(00252h), er1       ; 3E09 0 208 180 457C52
                LB      A, 0c1h                ; 3E0C 0 208 180 F5C1
                MOV     X1, #knockwindow_result_tbl          ; 3E0E 0 208 180 60286A
                VCAL    0                      ; 3E11 0 208 180 10
                STB     A, off(00254h)         ; 3E12 0 208 180 D454
                VCAL    4                      ; 3E14 0 208 180 14
                LB      A, #03ah               ; 3E15 0 208 180 773A
                JBS     off(00221h).0, threshold_bank_220_5 ; 3E17 0 208 180 E82102
                LB      A, #040h               ; 3E1A 0 208 180 7740
threshold_bank_220_5:     CMPB    A, off(00236h)         ; 3E1C 0 208 180 C736
                MB      off(00221h).0, C       ; 3E1E 0 208 180 C42138
                LB      A, #088h               ; 3E21 0 208 180 7788
                JBS     off(00221h).1, threshold_bank_220_6 ; 3E23 0 208 180 E92102
                LB      A, #090h               ; 3E26 0 208 180 7790
threshold_bank_220_6:     CMPB    A, off(00235h)         ; 3E28 0 208 180 C735
                MB      off(00221h).1, C       ; 3E2A 0 208 180 C42139
                CLRB    A                      ; 3E2D 0 208 180 FA
                JGE     threshold_bank_222_6             ; 3E2E 0 208 180 CD0C
                JBR     off(00221h).0, threshold_bank_222_6 ; 3E30 0 208 180 D82109
                LB      A, 0c0h                ; 3E36 0 208 180 F5C0
                MOV     X1, #threshold_bank_220_6_tbl          ; 3E38 0 208 180 606F6A
                VCAL    0                      ; 3E3B 0 208 180 10
threshold_bank_222_6:     STB     A, off(0023ah)         ; 3E3C 0 208 180 D43A
                MOV     DP, #003cdh            ; 3E3E 0 208 180 62CD03
                LB      A, [DP]                ; 3E41 0 208 180 F2
                SLLB    A                      ; 3E42 0 208 180 53
                MB      off(00220h).4, C       ; 3E43 0 208 180 C4203C
                LB      A, #066h               ; 3E46 0 208 180 7766
                JBS     off(00220h).5, threshold_bank_222_6_cmp_acc ; 3E48 0 208 180 ED2002
                LB      A, #073h               ; 3E4B 0 208 180 7773
threshold_bank_222_6_cmp_acc:     CMPB    A, off(00236h)         ; 3E4D 0 208 180 C736
                MB      off(00220h).5, C       ; 3E4F 0 208 180 C4203D
                LB      A, #09ah               ; 3E52 0 208 180 779A
                JBS     off(00220h).6, threshold_bank_222_6_cmp_acc_2 ; 3E54 0 208 180 EE2002
                LB      A, #0a0h               ; 3E57 0 208 180 77A0
threshold_bank_222_6_cmp_acc_2:     CMPB    A, off(00236h)         ; 3E59 0 208 180 C736
                MB      off(00220h).6, C       ; 3E5B 0 208 180 C4203E
                LB      A, #089h               ; 3E5E 0 208 180 7789
                JBS     off(00220h).7, threshold_bank_222_6_cmp_acc_3 ; 3E60 0 208 180 EF2002
                LB      A, #09ch               ; 3E63 0 208 180 779C
threshold_bank_222_6_cmp_acc_3:     CMPB    A, off(00235h)         ; 3E65 0 208 180 C735
                CLRB    A                      ; 3E67 0 208 180 FA
                MB      off(00220h).7, C       ; 3E68 0 208 180 C4203F
                JGE     div_scale_store             ; 3E6B 0 208 180 CD2C
                CLR     A                      ; 3E6D 1 208 180 F9
                MOV     DP, #003cah            ; 3E6E 1 208 180 62CA03
                J       select_dp_3d9_3d6_flag_222_6             ; 3E71 1 208 180 03195A
select_dp_3d9_3d6_flag_222_6_if_ge_goto_div_scale_calc1:     JGE     div_scale_calc1             ; 3E74 0 208 180 CD01
                CLRB    A                      ; 3E76 0 208 180 FA
div_scale_calc1:     MOVB    r0, #051h              ; 3E77 0 208 180 9851
                DIVB                           ; 3E79 0 208 180 A236
                JBR     off(00220h).5, div_scale_gate_common ; 3E7B 0 208 180 DD200D
                MOVB    r0, #01bh              ; 3E7E 0 208 180 981B
                LB      A, r1                  ; 3E80 0 208 180 79
                DIVB                           ; 3E81 0 208 180 A236
                JBR     off(00220h).6, div_scale_gate_common ; 3E83 0 208 180 DE2005
                MOVB    r0, #009h              ; 3E86 0 208 180 9809
                LB      A, r1                  ; 3E88 0 208 180 79
                DIVB                           ; 3E89 0 208 180 A236
div_scale_gate_common:     CMPB    A, #003h               ; 3E8B 0 208 180 C603
                JLT     div_scale_mul_final             ; 3E8D 0 208 180 CA02
div_scale_default:     LB      A, #002h               ; 3E8F 0 208 180 7702
div_scale_mul_final:     MOVB    r0, #008h              ; 3E91 0 208 180 9808
                MULB                           ; 3E93 0 208 180 A234
                JBR     off(00220h).4, div_scale_store ; 3E95 0 208 180 DC2001
                VCAL    7                      ; 3E98 0 208 180 17
div_scale_store:     STB     A, off(00242h)         ; 3E99 0 208 180 D442
                LB      A, #005h               ; 3E9B 0 208 180 7705
                J       div_scale_store_load_x1             ; 3E9D 0 208 180 03245F
div_scale_store_clear_x1:     CLR     X1                     ; 3EA0 0 208 180 9015
                JBS     off(00217h).5, gear_detect_store ; 3EA2 0 208 180 ED172F
                JBR     off(00227h).3, div_scale_store_load_r1 ; 3EA8 0 208 180 DB270B
                JBR     off(0022fh).3, div_scale_store_load_ram2d2 ; 3EAB 0 208 180 DB2F04
                MOVB    off(002d2h), #005h     ; 3EAE 0 208 180 C4D29805
div_scale_store_load_ram2d2:     LB      A, off(002d2h)         ; 3EB2 0 208 180 F4D2
                JNE     gear_detect_store_load_ram0c3             ; 3EB4 0 208 180 CE26
div_scale_store_load_r1:     MOVB    r1, 0b4h               ; 3EB6 0 208 180 C5B449
                CLRB    r0                     ; 3EB9 0 208 180 2015
                L       A, 0ach                ; 3EBB 1 208 180 E5AC
                MUL                            ; 3EBD 1 208 180 9035
                L       A, er1                 ; 3EBF 1 208 180 35
                MOV     DP, #00004h            ; 3EC0 1 208 180 620400
gear_detect_loop:     CMPC    A, GearCustom[X1]        ; 3EC3 1 208 180 90AD0364
                JLT     gear_detect_index_calc             ; 3EC7 1 208 180 CA04
                INC     X1                     ; 3EC9 1 208 180 70
                INC     X1                     ; 3ECA 1 208 180 70
                JRNZ    DP, gear_detect_loop         ; 3ECB 1 208 180 30F6
gear_detect_index_calc:     SRL     X1                     ; 3ECD 1 208 180 90E7
                L       A, X1                  ; 3ECF 1 208 180 40
                LB      A, ACC                 ; 3ED0 0 208 180 F506
                ADDB    A, #001h               ; 3ED2 0 208 180 8601
gear_detect_store:     STB     A, off(0024fh)         ; 3ED4 0 208 180 D44F
                LCB     A, TipinGear[X1]        ; 3ED6 0 208 180 90AB136B
                STB     A, off(00250h)         ; 3EDA 0 208 180 D450
gear_detect_store_load_ram0c3:     LB      A, 0c3h                ; 3EDC 0 208 180 F5C3
                MOV     X1, #DwellBattery          ; 3EDE 0 208 180 60F669
                VCAL    0                      ; 3EE1 0 208 180 10
                STB     A, off(0024bh)         ; 3EE2 0 208 180 D44B
                VCAL    4                      ; 3EE4 0 208 180 14
                MOV     X1, #gear_detect_store_tbl_5          ; 3EE5 0 208 180 606F63
                LB      A, 0a4h                ; 3EE8 0 208 180 F5A4
                VCAL    2                      ; 3EEA 0 208 180 12
                STB     A, (0017ch-00180h)[USP] ; 3EEB 0 208 180 D3FC
                MOV     X1, #Overrun_Resume_nor          ; 3EED 0 208 180 602D63
                MOV     X2, #Overrun_Resume_int          ; 3EF0 0 208 180 611F63
                JBR     off(00216h).3, gear_detect_store_load_ram0c1 ; 3EF3 0 208 180 DB1606
                MOV     X1, #gear_detect_store_tbl_4          ; 3EF6 0 208 180 604963
                MOV     X2, #gear_detect_store_tbl_3          ; 3EF9 0 208 180 613B63
gear_detect_store_load_ram0c1:     LB      A, 0c1h                ; 3EFC 0 208 180 F5C1
                VCAL    0                      ; 3EFE 0 208 180 10
                STB     A, r2                  ; 3EFF 0 208 180 8A
                MOV     X1, X2                 ; 3F00 0 208 180 9178
                LB      A, 0c1h                ; 3F02 0 208 180 F5C1
                VCAL    0                      ; 3F04 0 208 180 10
                STB     A, ACCH                ; 3F05 0 208 180 D507
                LB      A, r2                  ; 3F07 0 208 180 7A
                J       gear_detect_store_load_stk             ; 3F08 0 208 180 03B55F
gear_detect_store_load_x1:     MOV     X1, #tbl_knockwindow_4          ; 3F0B 0 208 180 609061
                MOV     X2, #tbl_knockwindow_3          ; 3F0E 0 208 180 618261
                JBR     off(00216h).3, gear_detect_store_load_ram0c1_2 ; 3F11 0 208 180 DB1606
                MOV     X1, #gear_detect_store_tbl_2          ; 3F14 0 208 180 60AC61
                MOV     X2, #gear_detect_store_tbl          ; 3F17 0 208 180 619E61
gear_detect_store_load_ram0c1_2:     LB      A, 0c1h                ; 3F1A 0 208 180 F5C1
                VCAL    0                      ; 3F1C 0 208 180 10
                STB     A, r2                  ; 3F1D 0 208 180 8A
                MOV     X1, X2                 ; 3F1E 0 208 180 9178
                LB      A, 0c1h                ; 3F20 0 208 180 F5C1
                VCAL    0                      ; 3F22 0 208 180 10
                STB     A, ACCH                ; 3F23 0 208 180 D507
                LB      A, r2                  ; 3F25 0 208 180 7A
                J       gear_detect_store_load_stk_2             ; 3F26 0 208 180 03BC5F
threshold_bank_223_2:     LB      A, #0a0h               ; 3F29 0 208 180 77A0
                JBS     off(00223h).2, threshold_bank_223_2_store ; 3F2B 0 208 180 EA2302
                LB      A, #0d8h               ; 3F2E 0 208 180 77D8
threshold_bank_223_2_store:     CMPB    A, off(00236h)         ; 3F30 0 208 180 C736
                MB      off(00223h).2, C       ; 3F32 0 208 180 C4233A
                CLR     A                      ; 3F35 1 208 180 F9
                MOV     X1, #tbl_threshold_223_1          ; 3F36 1 208 180 607363
                MOV     X2, #Revlimiters          ; 3F39 1 208 180 617963
                JBR     off(0021fh).1, revlimit_table_select ; 3F3C 1 208 180 D91F06
                MOV     X1, #tbl_threshold_223_2          ; 3F3F 1 208 180 607F63
                MOV     X2, #tbl_threshold_223_3          ; 3F42 1 208 180 618563
revlimit_table_select:     LC      A, 00002h[X1]          ; 3F45 1 208 180 90A90200
                MOV     DP, A                  ; 3F49 1 208 180 52
                LC      A, 00002h[X2]          ; 3F4A 1 208 180 91A90200
                J       revlimit_table_select_if_ram217_bit5_set             ; 3F4E 1 208 180 03BB56
revlimit_table_select_load_stk:     LB      A, (001a1h-00180h)[USP] ; 3F51 0 208 180 F321
                JNE     revlimit_table_select_load_ram0c1             ; 3F53 0 208 180 CE55
                MOVB    (001a1h-00180h)[USP], #014h ; 3F55 0 208 180 C3219814
                CMPB    0c1h, #044h            ; 3F5C 0 208 180 C5C1C044
                JGE     revlimit_table_select_load_stk_2             ; 3F60 0 208 180 CD1C
revlimit_table_select_if_ram223_bit2_clr:     JBR     off(00223h).2, revlimit_table_select_load_stk_2 ; 3F62 0 208 180 DA2319
                NOP                            ; 3F65 0 208 180 00
                NOP                            ; 3F66 0 208 180 00
                NOP                            ; 3F67 0 208 180 00
                NOP                            ; 3F68 0 208 180 00
                NOP                            ; 3F69 0 208 180 00
                NOP                            ; 3F6A 0 208 180 00
                LB      A, (00189h-00180h)[USP] ; 3F6B 0 208 180 F309
                JNE     callhelper_sub37_clamp_to_er0             ; 3F6D 0 208 180 CE13
                L       A, (00182h-00180h)[USP] ; 3F6F 1 208 180 E302
                CAL     add24_clamp_neg1             ; 3F71 1 208 180 321D51
                MOV     DP, A                  ; 3F74 1 208 180 52
                L       A, (00180h-00180h)[USP] ; 3F75 1 208 180 E300
                MOV     X1, X2                 ; 3F77 1 208 180 9178
                CAL     add24_clamp_neg1             ; 3F79 1 208 180 321D51
                SJ      revlimit_table_select_and_ie             ; 3F7C 1 208 180 CB1A
revlimit_table_select_load_stk_2:     MOVB    (00189h-00180h)[USP], #00ch ; 3F7E 0 208 180 C309980C
callhelper_sub37_clamp_to_er0:     LC      A, 00002h[X1]          ; 3F82 0 208 180 90A90200
                MOV     er0, A                 ; 3F86 0 208 180 448A
                L       A, (00182h-00180h)[USP] ; 3F88 1 208 180 E302
                CAL     sub37_clamp_to_er0             ; 3F8A 1 208 180 321351
                MOV     DP, A                  ; 3F8D 1 208 180 52
                LC      A, 00002h[X2]          ; 3F8E 1 208 180 91A90200
                ST      A, er0                 ; 3F92 1 208 180 88
                L       A, (00180h-00180h)[USP] ; 3F93 1 208 180 E300
                CAL     sub37_clamp_to_er0             ; 3F95 1 208 180 321351
revlimit_table_select_and_ie:     AND     IE, #002a0h            ; 3F98 1 208 180 B51AD0A002
                RB      PSWH.0                 ; 3F9D 1 208 180 A208
                ST      A, (00180h-00180h)[USP] ; 3F9F 1 208 180 D300
                L       A, DP                  ; 3FA1 1 208 180 42
                ST      A, (00182h-00180h)[USP] ; 3FA2 1 208 180 D302
                SB      PSWH.0                 ; 3FA4 1 208 180 A218
                L       A, 0f2h                ; 3FA6 1 208 180 E5F2
                ST      A, IE                  ; 3FA8 1 208 180 D51A
revlimit_table_select_load_ram0c1:     LB      A, 0c1h                ; 3FAA 0 208 180 F5C1
                MOV     X1, #revlimit_table_select_tbl_9          ; 3FAC 0 208 180 604661
                CMPCB   A, 00002h[X1]          ; 3FAF 0 208 180 90AF0200
                MB      off(00219h).5, C       ; 3FB3 0 208 180 C4193D
                VCAL    0                      ; 3FB6 0 208 180 10
                STB     A, (0016dh-00180h)[USP] ; 3FB7 0 208 180 D3ED
                LB      A, 0c1h                ; 3FB9 0 208 180 F5C1
                MOV     X1, #tbl_revlimit_warm3          ; 3FBB 0 208 180 60B862
                VCAL    1                      ; 3FBE 0 208 180 11
                STB     A, (001e0h-00180h)[USP] ; 3FBF 0 208 180 D360
                VCAL    4                      ; 3FC1 0 208 180 14
                LB      A, 0a4h                ; 3FC2 0 208 180 F5A4
                MOV     X1, #tbl_revlimit_warm2          ; 3FC4 0 208 180 60BE61
                VCAL    0                      ; 3FC7 0 208 180 10
                STB     A, (00156h-00180h)[USP] ; 3FC8 0 208 180 D3D6
                LB      A, 0a4h                ; 3FCA 0 208 180 F5A4
                MOV     X1, #tbl_revlimit_cold4          ; 3FCC 0 208 180 609362
                VCAL    2                      ; 3FCF 0 208 180 12
                STB     A, (00171h-00180h)[USP] ; 3FD0 0 208 180 D3F1
                LB      A, 0a4h                ; 3FD2 0 208 180 F5A4
                MOV     X1, #tbl_revlimit_warm1          ; 3FD4 0 208 180 603261
                VCAL    2                      ; 3FD7 0 208 180 12
                STB     A, (0016eh-00180h)[USP] ; 3FD8 0 208 180 D3EE
                MOV     X1, #revlimit_table_select_tbl_17          ; 3FDA 0 208 180 605664
                LB      A, 0a4h                ; 3FDD 0 208 180 F5A4
                VCAL    2                      ; 3FDF 0 208 180 12
                STB     A, (00159h-00180h)[USP] ; 3FE0 0 208 180 D3D9
                VCAL    4                      ; 3FE2 0 208 180 14
                LB      A, 0c1h                ; 3FE3 0 208 180 F5C1
                STB     A, r2                  ; 3FE5 0 208 180 8A
                MOV     X1, #revlimit_table_select_tbl_4          ; 3FE6 0 208 180 603460
                VCAL    0                      ; 3FE9 0 208 180 10
                STB     A, (0015ah-00180h)[USP] ; 3FEA 0 208 180 D3DA
                LB      A, r2                  ; 3FEC 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_5          ; 3FED 0 208 180 604260
                VCAL    0                      ; 3FF0 0 208 180 10
                STB     A, (0015bh-00180h)[USP] ; 3FF1 0 208 180 D3DB
                LB      A, r2                  ; 3FF3 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_6          ; 3FF4 0 208 180 605060
                VCAL    0                      ; 3FF7 0 208 180 10
                STB     A, (0015ch-00180h)[USP] ; 3FF8 0 208 180 D3DC
                VCAL    4                      ; 3FFA 0 208 180 14
                LB      A, 0c1h                ; 3FFB 0 208 180 F5C1
                J       revlimit_table_select_store_r2             ; 3FFD 0 208 180 035D57
revlimit_table_select_vcal_0:     VCAL    0                      ; 4000 0 208 180 10
                STB     A, (0015dh-00180h)[USP] ; 4001 0 208 180 D3DD
                LB      A, r2                  ; 4003 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_18          ; 4004 0 208 180 603A65
                VCAL    0                      ; 4007 0 208 180 10
                STB     A, (0015eh-00180h)[USP] ; 4008 0 208 180 D3DE
                LB      A, r2                  ; 400A 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_8          ; 400B 0 208 180 606C60
                VCAL    0                      ; 400E 0 208 180 10
                STB     A, (0016fh-00180h)[USP] ; 400F 0 208 180 D3EF
                VCAL    4                      ; 4011 0 208 180 14
                LB      A, 0c1h                ; 4012 0 208 180 F5C1
                J       revlimit_table_select_store_r2_2             ; 4014 0 208 180 036457
revlimit_table_select_vcal_0_2:     VCAL    0                      ; 4017 0 208 180 10
                STB     A, (00175h-00180h)[USP] ; 4018 0 208 180 D3F5
                LB      A, r2                  ; 401A 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_14          ; 401B 0 208 180 60D562
                JBS     off(00216h).3, revlimit_table_select_vcal_0_3 ; 401E 0 208 180 EB1603
                MOV     X1, #revlimit_table_select_tbl_13          ; 4021 0 208 180 60C762
revlimit_table_select_vcal_0_3:     VCAL    0                      ; 4024 0 208 180 10
                STB     A, (00173h-00180h)[USP] ; 4025 0 208 180 D3F3
                LB      A, r2                  ; 4027 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_16          ; 4028 0 208 180 60F162
                JBS     off(00216h).3, revlimit_table_select_vcal_0_4 ; 402B 0 208 180 EB1603
                MOV     X1, #revlimit_table_select_tbl_15          ; 402E 0 208 180 60E362
revlimit_table_select_vcal_0_4:     VCAL    0                      ; 4031 0 208 180 10
                STB     A, (00174h-00180h)[USP] ; 4032 0 208 180 D3F4
                VCAL    4                      ; 4034 0 208 180 14
                LB      A, 0c1h                ; 4035 0 208 180 F5C1
                J       revlimit_table_select_store_r2_3             ; 4037 0 208 180 036C5B
revlimit_table_select_vcal_1:     VCAL    1                      ; 403A 0 208 180 11
                STB     A, (001e6h-00180h)[USP] ; 403B 0 208 180 D366
                LB      A, 0c1h                ; 403D 0 208 180 F5C1
                MOV     X1, #revlimit_table_select_tbl_11          ; 403F 0 208 180 606962
                J       revlimit_table_select_vcal_1_2             ; 4042 0 208 180 03055C
revlimit_table_select_vcal_4:     VCAL    4                      ; 4045 0 208 180 14
                MOV     X1, #tbl_revlimit_cold1          ; 4046 0 208 180 60C860
                CMPB    0b4h, #00fh            ; 4049 0 208 180 C5B4C00F
                JLT     iat_table_select             ; 404D 0 208 180 CA03
                MOV     X1, #tbl_revlimit_cold3          ; 404F 0 208 180 60CC60
iat_table_select:     LB      A, 0c0h                ; 4052 0 208 180 F5C0
                VCAL    2                      ; 4054 0 208 180 12
                CMPB    0c1h, A                ; 4055 0 208 180 C5C1C1
                MB      off(00219h).2, C       ; 4058 0 208 180 C4193A
                LB      A, 0c0h                ; 405B 0 208 180 F5C0
                MOV     X1, #IATFuelCorrect          ; 405D 0 208 180 607A60
                VCAL    1                      ; 4060 0 208 180 11
                STB     A, (0014ch-00180h)[USP] ; 4061 0 208 180 D3CC
                VCAL    4                      ; 4063 0 208 180 14
                CLR     A                      ; 4064 1 208 180 F9
                LB      A, #0aah               ; 4065 0 208 180 77AA
                JBS     off(00223h).1, iat_table_select_cmp_acc ; 4067 0 208 180 E92302
                LB      A, #0b0h               ; 406A 0 208 180 77B0
iat_table_select_cmp_acc:     CMPB    A, off(00236h)         ; 406C 0 208 180 C736
                MB      off(00223h).1, C       ; 406E 0 208 180 C42339
                LCB     A, tbl_idle_pi_clamp            ; 4071 0 208 180 909D0060
                SRLB    A                      ; 4075 0 208 180 63
                SRLB    A                      ; 4076 0 208 180 63
                CLRB    r2                     ; 4077 0 208 180 2215
                MOV     DP, #003c2h            ; 4079 0 208 180 62C203
                LB      A, [DP]                ; 407C 0 208 180 F2
                JLT     knock_retard_check             ; 407D 0 208 180 CA23
                CMPB    A, #0f0h               ; 407F 0 208 180 C6F0
                JLT     knock_div_calc1             ; 4081 0 208 180 CA02
                LB      A, #076h               ; 4083 0 208 180 7776
knock_div_calc1:     MOVB    r0, #030h              ; 4085 0 208 180 9830
                DIVB                           ; 4087 0 208 180 A236
                JBS     off(00223h).1, knock_table_index ; 4089 0 208 180 E9230D
                SRLB    A                      ; 408C 0 208 180 63
                LB      A, r1                  ; 408D 0 208 180 79
                JGE     knock_div_calc2             ; 408E 0 208 180 CD03
                LB      A, #02fh               ; 4090 0 208 180 772F
                SUBB    A, r1                  ; 4092 0 208 180 29
knock_div_calc2:     MOVB    r0, #009h              ; 4093 0 208 180 9809
                DIVB                           ; 4095 0 208 180 A236
                ADDB    A, #006h               ; 4097 0 208 180 8606
knock_table_index:     SLLB    A                      ; 4099 0 208 180 53
                EXTND                          ; 409A 1 208 180 F8
                LC      A, knock_table_index_tbl[ACC]       ; 409B 1 208 180 B506A98B63
                SJ      knock_result_store             ; 40A0 1 208 180 CB06
knock_retard_check:     ADDB    A, #080h               ; 40A2 0 208 180 8680
                STB     A, r2                  ; 40A4 0 208 180 8A
                L       A, #08000h             ; 40A5 1 208 180 670080
knock_result_store:     ST      A, (00150h-00180h)[USP] ; 40A8 1 208 180 D3D0
                MOVB    off(00241h), r2        ; 40AA 1 208 180 227C41
                MOV     DP, #003cch            ; 40AD 1 208 180 62CC03
                LB      A, [DP]                ; 40B0 0 208 180 F2
                JBS     off(00219h).1, knock_result_store_addb_acc ; 40B1 0 208 180 E91902
                LB      A, 0c7h                ; 40B4 0 208 180 F5C7
knock_result_store_addb_acc:     ADDB    A, #080h               ; 40B6 0 208 180 8680
                STB     A, r0                  ; 40B8 0 208 180 88
                LCB     A, idle_init_start_tbl            ; 40B9 0 208 180 909D1160
                JEQ     knock_result_store_store_stk             ; 40BD 0 208 180 C90A
                LCB     A, tbl_idle_pi_clamp            ; 40BF 0 208 180 909D0060
                SRLB    A                      ; 40C3 0 208 180 63
                CLRB    A                      ; 40C4 0 208 180 FA
                J       knock_result_store_xchgb_acc             ; 40C5 0 208 180 032F59
knock_result_store_store_stk:     STB     A, (00137h-00180h)[USP] ; 40C9 0 208 180 D3B7
                LB      A, r0                  ; 40CB 0 208 180 78
                STB     A, (00141h-00180h)[USP] ; 40CC 0 208 180 D3C1
                CLRB    A                      ; 40CE 0 208 180 FA
                MOV     DP, #003cbh            ; 40CF 0 208 180 62CB03
                LCB     A, tbl_idle_pi_clamp            ; 40D2 0 208 180 909D0060
                SRLB    A                      ; 40D6 0 208 180 63
                SRLB    A                      ; 40D7 0 208 180 63
                SRLB    A                      ; 40D8 0 208 180 63
                JGE     knock_result_store_srlb_acc             ; 40D9 0 208 180 CD07
                LB      A, [DP]                ; 40DB 0 208 180 F2
                ADDB    A, #080h               ; 40DC 0 208 180 8680
                CLR     er0                    ; 40DE 0 208 180 4415
                SJ      knock_result_store_store_ram2f1             ; 40E0 0 208 180 CB0F
knock_result_store_srlb_acc:     SRLB    A                      ; 40E2 0 208 180 63
                JGE     knock_clear_284             ; 40E3 0 208 180 CD16
                LB      A, [DP]                ; 40E5 0 208 180 F2
                MOVB    r0, #080h              ; 40E6 0 208 180 9880
                MULB                           ; 40E8 0 208 180 A234
                L       A, ACC                 ; 40EA 1 208 180 E506
                ADD     A, #0c000h             ; 40EC 1 208 180 8600C0
                ST      A, er0                 ; 40EF 1 208 180 88
                CLRB    A                      ; 40F0 0 208 180 FA
knock_result_store_store_ram2f1:     STB     A, off(002f1h)         ; 40F1 0 208 180 D4F1
                MOV     off(00282h), er0       ; 40F3 0 208 180 447C82
                CLR     A                      ; 40F6 1 208 180 F9
                LB      A, #076h               ; 40F7 0 208 180 7776
                SJ      knock_div_calc3             ; 40F9 0 208 180 CB0D
knock_clear_284:     CLRB    A                      ; 40FB 0 208 180 FA
                STB     A, off(002f1h)         ; 40FC 0 208 180 D4F1
                EXTND                          ; 40FE 1 208 180 F8
                ST      A, off(00282h)         ; 40FF 1 208 180 D482
                LB      A, [DP]                ; 4101 0 208 180 F2
                CMPB    A, #0f0h               ; 4102 0 208 180 C6F0
                JLT     knock_div_calc3             ; 4104 0 208 180 CA02
                LB      A, #076h               ; 4106 0 208 180 7776
knock_div_calc3:     MOVB    r0, #030h              ; 4108 0 208 180 9830
                DIVB                           ; 410A 0 208 180 A236
                STB     A, r2                  ; 410C 0 208 180 8A
                SRLB    A                      ; 410D 0 208 180 63
                LB      A, r1                  ; 410E 0 208 180 79
                JGE     knock_div_calc4             ; 410F 0 208 180 CD03
                LB      A, #02fh               ; 4111 0 208 180 772F
                SUBB    A, r1                  ; 4113 0 208 180 29
knock_div_calc4:     MOVB    r0, #009h              ; 4114 0 208 180 9809
                DIVB                           ; 4116 0 208 180 A236
                ADDB    A, #006h               ; 4118 0 208 180 8606
                SLLB    A                      ; 411A 0 208 180 53
                EXTND                          ; 411B 1 208 180 F8
                MOV     X1, #tbl_knock_div          ; 411C 1 208 180 60A363
                JBR     off(00216h).3, knock_div_calc4_if_ram216_bit0_set ; 411F 1 208 180 DB1603
                MOV     X1, #knock_div_calc4_tbl          ; 4122 1 208 180 60D363
knock_div_calc4_if_ram216_bit0_set:     JBS     off(00216h).0, knock_table2d_lookup ; 4125 1 208 180 E81604
                ADD     X1, #00018h            ; 4128 1 208 180 90801800
knock_table2d_lookup:     MOV     X2, X1                 ; 412C 1 208 180 9079
                ADD     X1, A                  ; 412E 1 208 180 9081
                LC      A, [X1]                ; 4130 1 208 180 90A8
                ST      A, er0                 ; 4132 1 208 180 88
                LB      A, r2                  ; 4133 0 208 180 7A
                SLLB    A                      ; 4134 0 208 180 53
                EXTND                          ; 4135 1 208 180 F8
                ADD     X2, A                  ; 4136 1 208 180 9181
                LC      A, [X2]                ; 4138 1 208 180 91A8
                AND     IE, #002a0h            ; 413A 1 208 180 B51AD0A002
                RB      PSWH.0                 ; 413F 1 208 180 A208
                ST      A, (00166h-00180h)[USP] ; 4141 1 208 180 D3E6
                L       A, er0                 ; 4143 1 208 180 34
                ST      A, (00168h-00180h)[USP] ; 4144 1 208 180 D3E8
                SB      PSWH.0                 ; 4146 1 208 180 A218
                L       A, 0f2h                ; 4148 1 208 180 E5F2
                ST      A, IE                  ; 414A 1 208 180 D51A
                LB      A, 0c3h                ; 414C 0 208 180 F5C3
                MOV     X1, #knock_table2d_lookup_tbl          ; 414E 0 208 180 60D661
                VCAL    1                      ; 4151 0 208 180 11
                STB     A, (0013ch-00180h)[USP] ; 4152 0 208 180 D3BC
                VCAL    4                      ; 4154 0 208 180 14
                MOV     DP, #003beh            ; 4155 0 208 180 62BE03
                LB      A, [DP]                ; 4158 0 208 180 F2
                STB     A, 0c2h                ; 4159 0 208 180 D5C2
                JBR     off(00219h).1, injidx_gate2 ; 415B 0 208 180 D91916
                MOV     DP, #0039bh            ; 415E 0 208 180 629B03
                LB      A, [DP]                ; 4161 0 208 180 F2
                CMPB    A, #031h               ; 4162 0 208 180 C631
                JNE     injidx_gate1             ; 4164 0 208 180 CE0B
                SB      off(00223h).7          ; 4166 0 208 180 C4231F
                SB      off(00219h).0          ; 4169 0 208 180 C41918
                RB      off(00223h).3          ; 416C 0 208 180 C4230B
                SJ      injidx_flag_set             ; 416F 0 208 180 CB0C
injidx_gate1:     JBR     off(00223h).7, injidx_gate3 ; 4171 0 208 180 DF230F
injidx_gate2:     RB      off(00223h).7          ; 4174 0 208 180 C4230F
injidx_flag_clear:     RB      off(00219h).0          ; 4177 0 208 180 C41908
                SB      off(00223h).3          ; 417A 0 208 180 C4231B
injidx_flag_set:     SB      off(00223h).0          ; 417D 0 208 180 C42318
                J       vss_ect_stamp             ; 4180 0 208 180 030A42
injidx_gate3:     JBS     off(00219h).4, injidx_flag_clear ; 4183 0 208 180 EC19F1
                JBS     off(0021dh).4, injidx_flag_clear ; 4186 0 208 180 EC1DEE
                LB      A, off(002b6h)         ; 4189 0 208 180 F4B6
                JEQ     injidx_gate4             ; 418B 0 208 180 C90F
                RB      off(00219h).0          ; 418D 0 208 180 C41908
                RB      off(00223h).3          ; 4190 0 208 180 C4230B
injidx_flag_set2:     RB      off(00223h).0          ; 4193 0 208 180 C42308
                MOVB    off(002b7h), #064h     ; 4196 0 208 180 C4B79864
                SJ      vss_ect_stamp             ; 419A 0 208 180 CB6E
injidx_gate4:     JBS     off(00217h).5, injidx_flag_set2 ; 419C 0 208 180 ED17F4
                JBS     off(00219h).0, vss_ect_gate ; 419F 0 208 180 E81947
                JBR     off(00223h).3, injidx_gate6 ; 41A2 0 208 180 DB2312
                JBS     off(00216h).6, injidx_gate5 ; 41A5 0 208 180 EE1603
                JBS     off(00218h).0, vss_ect_gate ; 41A8 0 208 180 E8183E
injidx_gate5:     JBR     off(0021dh).2, vss_ect_gate ; 41AB 0 208 180 DA1D3B
                RB      off(00219h).0          ; 41AE 0 208 180 C41908
                RB      off(00223h).3          ; 41B1 0 208 180 C4230B
                SB      off(00223h).0          ; 41B4 0 208 180 C42318
injidx_gate6:     JBR     off(00216h).6, closeloopnarrow_check ; 41B7 0 208 180 DE1620
                JBS     off(00219h).0, closeloopnarrow_check ; 41BA 0 208 180 E8191D
                JBS     off(00223h).3, closeloopnarrow_check ; 41BD 0 208 180 EB231A
                JBS     off(00223h).0, closeloopnarrow_check ; 41C0 0 208 180 E82317
                JBR     off(00219h).3, injidx_stamp_c2 ; 41C3 0 208 180 DB1906
                JBR     off(00219h).2, injidx_stamp_c2 ; 41C6 0 208 180 DA1903
                JBS     off(0021dh).2, injidx_c2_check ; 41C9 0 208 180 EA1D06
injidx_stamp_c2:     MOVB    off(002b7h), #064h     ; 41CC 0 208 180 C4B79864
                SJ      closeloopnarrow_check             ; 41D0 0 208 180 CB08
injidx_c2_check:     LB      A, off(002b7h)         ; 41D2 0 208 180 F4B7
                JNE     closeloopnarrow_check             ; 41D4 0 208 180 CE04
                LB      A, #02eh               ; 41D6 0 208 180 772E
                SJ      closeloopnarrow_result             ; 41D8 0 208 180 CB07
closeloopnarrow_check:     LB      A, #01ah               ; 41DA 0 208 180 771A
                JBS     off(00216h).0, closeloopnarrow_result ; 41DC 0 208 180 E81602
                LB      A, #01ah               ; 41DF 0 208 180 771A
closeloopnarrow_result:     CMPB    A, 0c2h                ; 41E1 0 208 180 C5C2C2
                JLT     vss_ect_gate             ; 41E4 0 208 180 CA03
                SB      off(00219h).0          ; 41E6 0 208 180 C41918
vss_ect_gate:     CMPB    0c1h, #028h            ; 41E9 0 208 180 C5C1C028
                JGE     vss_ect_stamp             ; 41ED 0 208 180 CD1B
                CMPB    0b4h, #005h            ; 41EF 0 208 180 C5B4C005
                JGE     vss_ect_stamp             ; 41F3 0 208 180 CD15
                CMPB    off(00236h), #080h     ; 41F5 0 208 180 C436C080
                JLT     vss_ect_stamp             ; 41F9 0 208 180 CA0F
                JBR     off(0021dh).2, vss_ect_stamp ; 41FB 0 208 180 DA1D0C
                LB      A, off(002aah)         ; 41FE 0 208 180 F4AA
                JNE     idle_state_defaults             ; 4200 0 208 180 CE0C
                SB      off(00219h).0          ; 4202 0 208 180 C41918
                RB      off(00223h).3          ; 4205 0 208 180 C4230B
                SJ      idle_state_defaults             ; 4208 0 208 180 CB04
vss_ect_stamp:     MOVB    off(002aah), #004h     ; 420A 0 208 180 C4AA9804
idle_state_defaults:     MOVB    r0, #005h              ; 420E 0 208 180 9805
                MOVB    r1, #032h              ; 4210 0 208 180 9932
                MOVB    r2, #032h              ; 4212 0 208 180 9A32
                MOVB    r3, #01bh              ; 4214 0 208 180 9B1B
                JBS     off(00216h).0, idle_state_defaults_if_ram21d_bit1_clr ; 4216 0 208 180 E81602
                MOVB    r3, #01bh              ; 4219 0 208 180 9B1B
idle_state_defaults_if_ram21d_bit1_clr:     JBR     off(0021dh).1, idle_stage_alt_start ; 421B 0 208 180 D91D25
                JBR     off(00218h).0, idle_stage_alt_start ; 421E 0 208 180 D81822
                MOVB    off(002b4h), r1        ; 4221 0 208 180 217CB4
                MOVB    off(002b5h), r2        ; 4224 0 208 180 227CB5
                J       idle_state_defaults_if_ram219_bit0_clr             ; 4227 0 208 180 033D78
idle_state_defaults_load_stk:     L       A, (00148h-00180h)[USP] ; 422A 1 208 180 E3C8
                CMP     A, #0bc15h             ; 422C 1 208 180 C615BC
                JGE     idle_stage_c0_load_clear_ram219_bit0             ; 422F 1 208 180 CD3B
                CMP     A, #05e20h                                    ; 4231 1 208 180 C6205E
                JLE     idle_stage_c0_load_clear_ram219_bit0             ; 4234 1 208 180 CF36
                LB      A, r3                  ; 4236 0 208 180 7B
                CMPB    A, 0c2h                ; 4237 0 208 180 C5C2C2
                JLT     idle_stage_b7_load             ; 423A 0 208 180 CA03
idle_stage_b7_store:     MOVB    off(002abh), r0        ; 423C 0 208 180 207CAB
idle_stage_b7_load:     LB      A, off(002abh)         ; 423F 0 208 180 F4AB
                SJ      idle_stage_c0_load_if_ne_goto_gio_fuelpump_dispatch             ; 4241 0 208 180 CB27
idle_stage_alt_start:     MOVB    off(002abh), r0        ; 4243 0 208 180 207CAB
                JBR     off(0021ch).2, idle_stage_c0_start ; 4246 0 208 180 DA1C13
                MOVB    off(002b5h), r2        ; 4249 0 208 180 227CB5
                JBR     off(00219h).0, idle_stage_bf_store ; 424C 0 208 180 D81906
                LB      A, r3                  ; 424F 0 208 180 7B
                CMPB    A, 0c2h                ; 4250 0 208 180 C5C2C2
                JLT     idle_stage_bf_load             ; 4253 0 208 180 CA03
idle_stage_bf_store:     MOVB    off(002b4h), r1        ; 4255 0 208 180 217CB4
idle_stage_bf_load:     LB      A, off(002b4h)         ; 4258 0 208 180 F4B4
                SJ      idle_stage_c0_load_if_ne_goto_gio_fuelpump_dispatch             ; 425A 0 208 180 CB0E
idle_stage_c0_start:     MOVB    off(002b4h), r1        ; 425C 0 208 180 217CB4
                JBR     off(00219h).0, idle_stage_c0_store ; 425F 0 208 180 D81903
                JBR     off(0021ch).6, idle_stage_c0_load ; 4262 0 208 180 DE1C03
idle_stage_c0_store:     MOVB    off(002b5h), r2        ; 4265 0 208 180 227CB5
idle_stage_c0_load:     LB      A, off(002b5h)         ; 4268 0 208 180 F4B5
idle_stage_c0_load_if_ne_goto_gio_fuelpump_dispatch:     JNE     gio_fuelpump_dispatch             ; 426A 0 208 180 CE06
idle_stage_c0_load_clear_ram219_bit0:     RB      off(00219h).0          ; 426C 0 208 180 C41908
                SB      off(00223h).3          ; 426F 0 208 180 C4231B
gio_fuelpump_dispatch:     VCAL    4                      ; 4272 0 208 180 14
                RC                             ; 4273 0 208 180 95
                LB      A, off(002bch)         ; 4274 0 208 180 F4BC
                JNE     fuelpump_relay_drive             ; 4276 0 208 180 CE06
                JBS     off(00211h).0, fuelpump_relay_drive ; 4278 0 208 180 E81103
                MB      C, off(00217h).4       ; 427B 0 208 180 C4172C
fuelpump_relay_drive:     MB      P0.7, C                ; 427E 0 208 180 C5203F
                JBS     off(00210h).7, fuelpump_state_active_cmp_ram0e9 ; 4281 0 208 180 EF102D
                JBS     off(00218h).5, fuelpump_state_active ; 4284 0 208 180 ED1826
                MOV     DP, #003c9h            ; 4287 0 208 180 62C903
                LB      A, [DP]                ; 428A 0 208 180 F2
                CMPB    A, #0ffh               ; 428B 0 208 180 C6FF
                JGT     fuelpump_gate4             ; 428D 0 208 180 C804
                CMPB    A, #0fch               ; 428F 0 208 180 C6FC
                JGE     fuelpump_gate4_rom_load_tbl_6011             ; 4291 0 208 180 CD03
fuelpump_gate4:     JBS     off(00230h).6, fuelpump_state_active ; 4293 0 208 180 EE3017
fuelpump_gate4_rom_load_tbl_6011:     LCB     A, idle_init_start_tbl            ; 4296 0 208 180 909D1160
                JEQ     flag_dispatch_221_6_217_4             ; 429A 0 208 180 C904
                LB      A, 0e7h                ; 429C 0 208 180 F5E7
                JNE     fuelpump_state_active             ; 429E 0 208 180 CE0D
flag_dispatch_221_6_217_4:     JBS     off(00211h).0, fuelpump_state_store ; 42A0 0 208 180 E81103
                JBS     off(00217h).4, fuelpump_state_check ; 42A3 0 208 180 EC1702
fuelpump_state_store:     STB     A, off(002bch)         ; 42A6 0 208 180 D4BC
fuelpump_state_check:     RC                             ; 42A8 0 208 180 95
                LB      A, off(002bch)         ; 42A9 0 208 180 F4BC
                JEQ     fuelpump_state_active_store_carry_p1_bit4             ; 42AB 0 208 180 C901
fuelpump_state_active:     SC                             ; 42AD 0 208 180 85
; (skeleton: the stock key-on bulb check wrote P1.4 here; the lamp output is left to feature modules)
fuelpump_state_active_store_carry_p1_bit4:
fuelpump_state_active_cmp_ram0e9:     CMPB    0e9h, #014h            ; 42B1 0 208 180 C5E9C014
                JLT     accut_reset_c3             ; 42B5 0 208 180 CA63
                CMPB    0c1h, #015h            ; 42B7 0 208 180 C5C1C015
                JGE     rpm_threshold_226_0_if_ram218_bit6_set             ; 42BB 0 208 180 CD1D
                LB      A, #07eh               ; 42BD 0 208 180 777E
                JBS     off(00226h).1, rpm_threshold_226_0 ; 42BF 0 208 180 E92602
                LB      A, #082h               ; 42C2 0 208 180 7782
rpm_threshold_226_0:     CMPB    A, 0b4h                ; 42C4 0 208 180 C5B4C2
                MB      off(00226h).1, C       ; 42C7 0 208 180 C42639
                JGE     rpm_threshold_226_0_if_ram218_bit6_set             ; 42CA 0 208 180 CD0E
                LB      A, #0c8h               ; 42CC 0 208 180 77C8
                JBS     off(00226h).0, rpm_threshold_226_0_cmp_acc ; 42CE 0 208 180 E82602
                LB      A, #0d0h               ; 42D1 0 208 180 77D0
rpm_threshold_226_0_cmp_acc:     CMPB    A, off(00236h)         ; 42D3 0 208 180 C736
                MB      off(00226h).0, C       ; 42D5 0 208 180 C42638
                JLT     accut_reset_f7             ; 42D8 0 208 180 CA43
rpm_threshold_226_0_if_ram218_bit6_set:     JBS     off(00218h).6, accut_check_c3_if_ram211_bit2_clr ; 42DA 0 208 180 EE1829
                LB      A, #033h               ; 42DD 0 208 180 7733
                JBS     off(00226h).3, rpm_threshold_226_0_cmp_acc_2 ; 42DF 0 208 180 EB2602
                LB      A, #080h               ; 42E2 0 208 180 7780
rpm_threshold_226_0_cmp_acc_2:     CMPB    A, 0b9h                ; 42E4 0 208 180 C5B9C2
                MB      off(00226h).3, C       ; 42E7 0 208 180 C4263B
                JLT     accut_check_c3             ; 42EA 0 208 180 CA16
                LB      A, #010h               ; 42EC 0 208 180 7710
                JBS     off(00226h).2, rpm_threshold_226_1 ; 42EE 0 208 180 EA2602
                LB      A, #020h               ; 42F1 0 208 180 7720
rpm_threshold_226_1:     CMPB    A, 0b4h                ; 42F3 0 208 180 C5B4C2
                MB      off(00226h).2, C       ; 42F6 0 208 180 C4263A
                CLRB    A                      ; 42F9 0 208 180 FA
                JLT     accut_store_c3             ; 42FA 0 208 180 CA02
                LB      A, #032h               ; 42FC 0 208 180 7732
accut_store_c3:     STB     A, off(002b8h)         ; 42FE 0 208 180 D4B8
                SJ      accut_check_c3_if_ram211_bit2_clr             ; 4300 0 208 180 CB04
accut_check_c3:     LB      A, off(002b8h)         ; 4302 0 208 180 F4B8
                JNE     accut_reset_f7             ; 4304 0 208 180 CE17
accut_check_c3_if_ram211_bit2_clr:     JBR     off(00211h).2, accut_common ; 4306 0 208 180 DA1117
                SB      off(00226h).4          ; 4309 0 208 180 C4261C
                LB      A, off(002e2h)         ; 430C 0 208 180 F4E2
                JNE     accut_result_common             ; 430E 0 208 180 CE1B
                MOVB    off(002e3h), #032h     ; 4310 0 208 180 C4E39832
accut_delay_check:     SB      off(0021bh).0          ; 4314 0 208 180 C41B18
                RC                             ; 4317 0 208 180 95
                SJ      accut_output_drive             ; 4318 0 208 180 CB15
accut_reset_c3:     CLRB    off(002b8h)            ; 431A 0 208 180 C4B815
accut_reset_f7:     CLRB    off(002e3h)            ; 431D 0 208 180 C4E315
accut_common:     RB      off(00226h).4          ; 4320 0 208 180 C4260C
                LB      A, off(002e3h)         ; 4323 0 208 180 F4E3
                JNE     accut_delay_check             ; 4325 0 208 180 CEED
                MOVB    off(002e2h), #032h     ; 4327 0 208 180 C4E29832
accut_result_common:     RB      off(0021bh).0          ; 432B 0 208 180 C41B08
                SC                             ; 432E 0 208 180 85
accut_output_drive:     MB      P0.0, C                ; 432F 0 208 180 C52038
                JBS     off(00217h).5, purge_result_clear ; 4332 0 208 180 ED171F
                CMPB    0c1h, #035h            ; 4338 0 208 180 C5C1C035
                JGE     purge_result_clear             ; 433C 0 208 180 CD16
accut_output_drive_goto_purge_counter_check:     J       purge_counter_check             ; 433E 0 208 180 034C78
purge_counter_check_if_lt_goto_purge_result_clear:     JLT     purge_result_clear             ; 4343 0 208 180 CA0F
                CMPB    off(002a7h), #005h     ; 4345 0 208 180 C4A7C005
                JNE     purge_result_set             ; 4349 0 208 180 CE06
                CMPB    off(002c1h), #019h     ; 434B 0 208 180 C4C1C019
                JLT     purge_result_clear             ; 434F 0 208 180 CA03
purge_result_set:     SC                             ; 4351 0 208 180 85
                SJ      purge_result_clear_goto_vss_band_dispatch             ; 4352 0 208 180 CB01
purge_result_clear:     RC                             ; 4354 0 208 180 95
purge_result_clear_goto_vss_band_dispatch:     J       vss_band_dispatch             ; 4355 0 208 180 03C35F
vss_band_dispatch_load_r2:     MOVB    r2, off(00236h)        ; 4358 0 208 180 C4364A
                LB      A, #046h               ; 435B 0 208 180 7746
                MOVB    r1, #046h              ; 435D 0 208 180 9946
                JBS     off(00224h).0, vss_band_224_0 ; 435F 0 208 180 E82404
                LB      A, #053h               ; 4362 0 208 180 7753
                MOVB    r1, #053h              ; 4364 0 208 180 9953
vss_band_224_0:     JBS     off(00216h).3, vss_band_224_0_check ; 4366 0 208 180 EB1601
                LB      A, r1                  ; 4369 0 208 180 79
vss_band_224_0_check:     CMPB    A, r2                  ; 436A 0 208 180 4A
                MB      off(00224h).0, C       ; 436B 0 208 180 C42438
                MOV     X1, #vss_band_224_0_check_tbl          ; 436E 0 208 180 602464
                MOV     DP, #00224h            ; 4371 0 208 180 622402
                MOV     er0, #00101h           ; 4374 0 208 180 44980101
                RB      PSWL.4                 ; 4378 0 208 180 A30C
                CAL     timer_or_counter_helper             ; 437A 0 208 180 327752
                MOVB    r1, #003h              ; 437D 0 208 180 9903
                MOVB    r2, 0b4h               ; 437F 0 208 180 C5B44A
                CAL     timer_or_counter_helper             ; 4382 0 208 180 327752
                MOVB    r1, #002h              ; 4385 0 208 180 9902
                MOVB    r2, 0f7h               ; 4387 0 208 180 C5F74A
                SB      PSWL.4                 ; 438A 0 208 180 A31C
                CAL     timer_or_counter_helper             ; 438C 0 208 180 327752
                MOVB    r1, #001h              ; 438F 0 208 180 9901
                MOVB    r2, 0c1h               ; 4391 0 208 180 C5C14A
                CAL     timer_or_counter_helper             ; 4394 0 208 180 327752
                JBS     off(00218h).6, vss_band_224_0_check_set_p0_bit3 ; 4397 0 208 180 EE1806
                JBR     off(00217h).6, vss_band_224_0_check_set_p0_bit3 ; 439A 0 208 180 DE1703
                JBR     off(00217h).4, state_dispatch2 ; 439D 0 208 180 DC1709
vss_band_224_0_check_set_p0_bit3:     SB      P0.3                   ; 43A0 0 208 180 C5201B
                SB      off(00225h).1          ; 43A3 0 208 180 C42519
                J       state_result_clear5             ; 43A6 0 208 180 036244
state_dispatch2:     JBR     off(00224h).2, state_cce_set2b ; 43A9 0 208 180 DA242E
                JBS     off(0021ch).2, state_dispatch3 ; 43AC 0 208 180 EA1C06
                JBR     off(00216h).3, state_cce_set2b ; 43AF 0 208 180 DB1628
                JBR     off(0021eh).1, state_cce_set2b ; 43B2 0 208 180 D91E25
state_dispatch3:     JBR     off(00224h).0, state_cce_set2b ; 43B5 0 208 180 D82422
                JBS     off(00224h).4, state_cce_set2 ; 43B8 0 208 180 EC2411
                JBR     off(00224h).7, state_cce_set2 ; 43BB 0 208 180 DF240E
                JBS     off(00225h).0, state_cce_set2 ; 43BE 0 208 180 E8250B
                LB      A, off(002c4h)         ; 43C1 0 208 180 F4C4
                JNE     state_ccf_gate             ; 43C3 0 208 180 CE19
                MOVB    off(002c5h), #003h     ; 43C5 0 208 180 C4C59803
state_ccf_check:     RC                             ; 43C9 0 208 180 95
                SJ      state_ccc_set9             ; 43CA 0 208 180 CB05
state_cce_set2:     MOVB    off(002c4h), #002h     ; 43CC 0 208 180 C4C49802
                SC                             ; 43D0 0 208 180 85
state_ccc_set9:     MB      P0.3, C                ; 43D1 0 208 180 C5203B
                MOVB    off(002c2h), #005h     ; 43D4 0 208 180 C4C29805
                SJ      state_2ba_reset             ; 43D8 0 208 180 CB70
state_cce_set2b:     MOVB    off(002c4h), #002h     ; 43DA 0 208 180 C4C49802
state_ccf_gate:     LB      A, off(002c5h)         ; 43DE 0 208 180 F4C5
                JNE     state_ccf_check             ; 43E0 0 208 180 CEE7
                RC                             ; 43E2 0 208 180 95
                JBS     off(00220h).3, state_ccf_gate_store_carry_p0_bit3 ; 43E3 0 208 180 EB2001
                SC                             ; 43E6 0 208 180 85
state_ccf_gate_store_carry_p0_bit3:     MB      P0.3, C                ; 43E7 0 208 180 C5203B
                LB      A, off(002c2h)         ; 43EA 0 208 180 F4C2
                JEQ     state_ccc_check             ; 43EC 0 208 180 C905
                JBR     off(00225h).0, state_dispatch4 ; 43EE 0 208 180 D8252E
                SJ      state_2ba_reset             ; 43F1 0 208 180 CB57
state_ccc_check:     JBR     off(00227h).1, flag_dispatch_216_211 ; 43F3 0 208 180 D9274A
                JBR     off(00211h).4, state_ccc_check_load_ram2c7 ; 43F6 0 208 180 DC1104
                MOVB    off(002c7h), #003h     ; 43F9 0 208 180 C4C79803
state_ccc_check_load_ram2c7:     LB      A, off(002c7h)         ; 43FD 0 208 180 F4C7
                JEQ     flag_dispatch_216_211             ; 43FF 0 208 180 C93F
                JBS     off(00224h).6, flag_dispatch_216_211_load_ram2c8_2 ; 4401 0 208 180 EE2404
flag_dispatch_216_211_load_ram2c8:     MOVB    off(002c8h), #003h     ; 4404 0 208 180 C4C89803
flag_dispatch_216_211_load_ram2c8_2:     LB      A, off(002c8h)         ; 4408 0 208 180 F4C8
                JEQ     to_state_2ba_reset             ; 440A 0 208 180 C93B
                JBR     off(00216h).3, state_ccd_check ; 440C 0 208 180 DB1603
                JBS     off(00211h).5, to_state_2ba_reset ; 440F 0 208 180 ED1135
state_ccd_check:     LB      A, off(002c3h)         ; 4412 0 208 180 F4C3
                JNE     state_2ba_reset             ; 4414 0 208 180 CE34
                JBS     off(00224h).2, state_ccd_check_clear_ram225_bit0 ; 4416 0 208 180 EA2403
                JBS     off(00225h).0, state_2ba_reset ; 4419 0 208 180 E8252E
state_ccd_check_clear_ram225_bit0:     RB      off(00225h).0          ; 441C 0 208 180 C42508
state_dispatch4:     JBS     off(00224h).3, state_225_1_check ; 441F 0 208 180 EB242C
                JBS     off(00224h).1, state_225_1_check ; 4422 0 208 180 E92429
                CMPB    0c1h, #029h            ; 4425 0 208 180 C5C1C029
                JGE     state_225_1_check             ; 4429 0 208 180 CD23
                CMPB    0c0h, #0a9h            ; 442B 0 208 180 C5C0C0A9
                JGE     state_225_1_check             ; 442F 0 208 180 CD1D
                JBS     off(00211h).2, state_225_1_check ; 4431 0 208 180 EA111A
                LB      A, off(002afh)         ; 4434 0 208 180 F4AF
                JEQ     state_225_1_check             ; 4436 0 208 180 C916
                RB      off(00225h).1          ; 4438 0 208 180 C42509
state_result_set5:     SB      P0.2                   ; 443B 0 208 180 C5201A
                SJ      altc_gio_override_check             ; 443E 0 208 180 CB25
flag_dispatch_216_211:     JBR     off(00224h).5, flag_dispatch_216_211_load_ram2c8 ; 4440 0 208 180 DD24C1
                MOVB    off(002c3h), #014h     ; 4443 0 208 180 C4C39814
to_state_2ba_reset:     SB      off(00225h).0          ; 4447 0 208 180 C42518
state_2ba_reset:     MOVB    off(002afh), #016h     ; 444A 0 208 180 C4AF9816
state_225_1_check:     JBS     off(00225h).1, state_2d0_check ; 444E 0 208 180 E92507
                SB      off(00225h).1          ; 4451 0 208 180 C42519
                MOVB    off(002c6h), #003h     ; 4454 0 208 180 C4C69803
state_2d0_check:     LB      A, off(002c6h)         ; 4458 0 208 180 F4C6
                JNE     state_result_set5             ; 445A 0 208 180 CEDF
                CMPB    off(00297h), #0ffh     ; 445C 0 208 180 C497C0FF
                JGT     state_result_set5             ; 4460 0 208 180 C8D9
state_result_clear5:     RB      P0.2                   ; 4462 0 208 180 C5200A
altc_gio_override_check:     J       altc_gio_override_check_vcal_4             ; 4465 0 208 180 03CA5F
altc_gio_override_check_if_ram216_bit3_clr:     JBR     off(00216h).3, altc_normal_drive ; 4468 0 208 180 DB1622
                MOVB    r0, #0feh              ; 446B 0 208 180 98FE
                JBS     off(00225h).7, altc_gio_override_check_load_adcr7h ; 446D 0 208 180 EF2502
                MOVB    r0, #0ffh              ; 4470 0 208 180 98FF
altc_gio_override_check_load_adcr7h:     LB      A, ADCR7H              ; 4472 0 208 180 F56F
                CMPB    r0, A                  ; 4474 0 208 180 20C1
                MB      off(00225h).7, C       ; 4476 0 208 180 C4253F
                JBR     off(00211h).4, altc_gio_override_check_set_carry ; 4479 0 208 180 DC110E
                CMPB    A, #0fch               ; 447F 0 208 180 C6FC
                JGE     altc_normal_drive             ; 4481 0 208 180 CD0A
                CMPB    A, #005h               ; 4483 0 208 180 C605
                JLT     altc_normal_drive             ; 4485 0 208 180 CA06
                JBR     off(00225h).7, altc_normal_drive ; 4487 0 208 180 DF2503
altc_gio_override_check_set_carry:     SC                             ; 448A 0 208 180 85
                SJ      altc_normal_drive_store_carry_p0_bit5             ; 448B 0 208 180 CB01
altc_normal_drive:     RC                             ; 448D 0 208 180 95
altc_normal_drive_store_carry_p0_bit5:     MB      P0.5, C                ; 448E 0 208 180 C5203D
altc_normal_drive_nop_acc:     NOP                            ; 4491 0 208 180 00
                NOP                            ; 4492 0 208 180 00
                NOP                            ; 4493 0 208 180 00
                NOP                            ; 4494 0 208 180 00
                NOP                            ; 4495 0 208 180 00
                NOP                            ; 4496 0 208 180 00
                NOP                            ; 4497 0 208 180 00
                NOP                            ; 4498 0 208 180 00
                NOP                            ; 4499 0 208 180 00
                NOP                            ; 449A 0 208 180 00
                NOP                            ; 449B 0 208 180 00
                NOP                            ; 449C 0 208 180 00
                NOP                            ; 449D 0 208 180 00
                NOP                            ; 449E 0 208 180 00
                NOP                            ; 449F 0 208 180 00
                NOP                            ; 44A0 0 208 180 00
                JBR     off(00219h).1, flags_b8_2_set ; 44A1 0 208 180 D91906
                JBR     off(00216h).6, flags_b8_2_set ; 44A4 0 208 180 DE1603
                JBR     off(00217h).4, altc_condition_check ; 44A7 0 208 180 DC1708
flags_b8_2_set:     SB      0a0h.5                 ; 44AA 0 208 180 C5A01D
                RB      09bh.2                 ; 44AD 0 208 180 C59B0A
                SJ      gio_p1_2_check             ; 44B0 0 208 180 CB17
altc_condition_check:
                MB      C, 098h.1              ; 44B8 0 208 180 C59829
                JLT     gio_p1_2_check             ; 44BB 0 208 180 CA0C
                CMPB    0c1h, #0c5h            ; 44BD 0 208 180 C5C1C0C5
                JGE     gio_p1_2_check             ; 44C1 0 208 180 CD06
                CMPB    0c3h, #0a7h            ; 44C3 0 208 180 C5C3C0A7
                JLT     flags_219_2_store             ; 44C7 0 208 180 CA04
gio_p1_2_check:     RC                             ; 44C9 0 208 180 95
                SB      P1.2                   ; 44CA 0 208 180 C5221A
flags_219_2_store:     MB      off(00219h).3, C       ; 44CD 0 208 180 C4193B
                JBR     off(00227h).1, flags_219_2_store_clear_acc ; 44D0 0 208 180 D9270D
                JBS     off(00216h).2, flags_219_2_store_clear_acc ; 44D3 0 208 180 EA160A
                JBS     off(00218h).6, flags_219_2_store_clear_acc ; 44D6 0 208 180 EE1807
                JBS     off(0021fh).0, flags_219_2_store_cmp_ram0c0 ; 44D9 0 208 180 E81F08
                LB      A, off(002b1h)         ; 44DC 0 208 180 F4B1
                JNE     flags_219_2_store_clear_carry             ; 44DE 0 208 180 CE12
flags_219_2_store_clear_acc:     CLRB    A                      ; 44E0 0 208 180 FA
                SC                             ; 44E1 0 208 180 85
                SJ      flags_219_2_store_store_carry_p1_bit6             ; 44E2 0 208 180 CB0F
flags_219_2_store_cmp_ram0c0:     CMPB    0c0h, #001h            ; 44E4 0 208 180 C5C0C001
                JGE     flags_219_2_store_clear_acc             ; 44E8 0 208 180 CDF6
                CMPB    0c1h, #001h            ; 44EA 0 208 180 C5C1C001
                JGE     flags_219_2_store_clear_acc             ; 44EE 0 208 180 CDF0
                LB      A, #000h               ; 44F0 0 208 180 7700
flags_219_2_store_clear_carry:     RC                             ; 44F2 0 208 180 95
flags_219_2_store_store_carry_p1_bit6:     MB      P1.6, C                ; 44F3 0 208 180 C5223E
                STB     A, off(002b1h)         ; 44F6 0 208 180 D4B1
                VCAL    4                      ; 44F8 0 208 180 14
; (skeleton: no VTEC oil-pressure switch check at idle / pressure fault latch)
state_21a_7_dispatch2_load_x1:     MOV     X1, #state_21a_7_dispatch2_tbl          ; 4592 0 208 180 60CC65
                LB      A, 0c1h                ; 4595 0 208 180 F5C1
                VCAL    1                      ; 4597 0 208 180 11
                STB     A, (00144h-00180h)[USP] ; 4598 0 208 180 D3C4
                MOVB    r0, #004h              ; 459A 0 208 180 9804
                MOV     DP, #tbl_map_sign          ; 459C 0 208 180 621B6B
                LB      A, 0c1h                ; 459F 0 208 180 F5C1
state_21a_7_dispatch2_dec_dp:     DEC     DP                     ; 45A1 0 208 180 82
                DECB    r0                     ; 45A2 0 208 180 B8
                JEQ     state_21a_7_dispatch2_and_ie             ; 45A3 0 208 180 C904
                CMPCB   A, [DP]                ; 45A5 0 208 180 92AE
                JGE     state_21a_7_dispatch2_dec_dp             ; 45A7 0 208 180 CDF8
state_21a_7_dispatch2_and_ie:     AND     IE, #002a0h            ; 45A9 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 45AE 0 208 180 A208
                LB      A, off(00233h)         ; 45B0 0 208 180 F433
                ANDB    A, #0fch               ; 45B2 0 208 180 D6FC
                ORB     A, r0                  ; 45B4 0 208 180 68
                STB     A, off(00233h)         ; 45B5 0 208 180 D433
                SB      PSWH.0                 ; 45B7 0 208 180 A218
                L       A, 0f2h                ; 45B9 1 208 180 E5F2
                ST      A, IE                  ; 45BB 1 208 180 D51A
                CMPB    0c0h, #028h            ; 45BD 1 208 180 C5C0C028
                MB      off(00233h).2, C       ; 45C1 1 208 180 C4333A
                VCAL    4                      ; 45C4 1 208 180 14
                J       state_21a_7_dispatch2_vcal_4 ; (skeleton: automatic transmission control removed - manual only)
state_21a_7_dispatch2_vcal_4:     VCAL    4                      ; 47EB 0 208 180 14
                J       skel_block20_end ; (skeleton: diagnostics block removed)
skel_block20_end: VCAL    4                      ; 498D 0 208 180 14
                J       dtc_debounce_init ; (skeleton: diagnostics block removed)
dtc_debounce_init:     VCAL    4                      ; 49D9 0 208 180 14
                J       freezeframe_decode_start ; (skeleton: DTC debounce and stored-code storage removed)
freezeframe_decode_start:     VCAL    4                      ; 4AE2 1 208 180 14
                J       freezeframe_decode_start_load_ram212             ; 4AE3 1 208 180 03DB5F
freezeframe_decode_start_add_acc:     ADD     A, #0ffffh             ; 4AE6 1 208 180 86FFFF
                MB      off(00218h).6, C       ; 4AE9 1 208 180 C4183E
                J       prep_lowpower_seq ; 4AEC (skeleton: fault flags are always clear)
prep_lowpower_seq:     SB      off(00230h).3          ; 4AFD 1 208 180 C4301B
                JNE     lowpower_trap_call             ; 4B00 1 208 180 CE2D
                CAL     ResetWatchDog             ; 4B02 1 208 180 321E52
                L       A, TM1                 ; 4B05 1 208 180 E534
                ADD     A, #00a00h             ; 4B07 1 208 180 86000A
                J       prep_lowpower_seq_store_tmr1             ; 4B0A 1 208 180 030D77
prep_lowpower_seq_load_carry_ram09f_bit1:     MB      C, 09fh.1              ; 4B0E 1 208 180 C59F29
                JLT     prep_lowpower_ie_config             ; 4B11 1 208 180 CA07
                CAL     port_debounce_helper             ; 4B13 1 208 180 32E451
                MOVB    0edh, #020h            ; 4B16 1 208 180 C5ED9820
prep_lowpower_ie_config:     MOV     0f4h, #002a0h          ; 4B1A 1 208 180 B5F498A002
                L       A, #02ba9h             ; 4B1F (skeleton: serial receive interrupt off; stock 2BABh)
                ST      A, 0f2h                ; 4B22 1 208 180 D5F2
                CLRB    TRNSIT                 ; 4B24 1 208 180 C54615
                CLR     IRQ                    ; 4B27 1 208 180 B51815
                RB      TCON0.2                ; 4B2A 1 208 180 C5400A
                ST      A, IE                  ; 4B2D 1 208 180 D51A
lowpower_trap_call:     CAL     hook_main              ; (skeleton) module slot: once per main-loop pass
                J       regbank_selftest2_start             ; 4B2F 1 208 180 035037
; [CG] crank_helper2  @0x4B32
; [CG] VERIFIED: entry point that first checks off(120h).2; if set, skips straight to the
; [CG] shared clamp body (injector_timer_schedule). If clear, also bails immediately when
; [CG] off(1BFh)==0x0Fh (an apparent "not yet valid" sentinel).
crank_helper2:     JBR     off(00120h).2, injtimer_shift_path ; 4B32 1 108 280 DA2034
; [CG] injector_timer_schedule  @0x4B35
; [CG] VERIFIED: clamps a 3-word array based at RAM 0x1C0 to a ceiling of 0xC0 (192), one
; [CG] word at a time. Direct-entry form of crank_helper2.
injector_timer_schedule:     MOVB    r0, #0ffh              ; 4B35 1 108 280 98FF
                L       A, off(001c6h)         ; 4B37 1 108 280 E4C6
                ST      A, er1                 ; 4B39 1 108 280 89
                CMPB    off(001bfh), #00fh     ; 4B3A 1 108 280 C4BFC00F
                JNE     injtimer_schedule_done             ; 4B3E 1 108 280 CE65
                J       injector_timer_schedule_load_tm0             ; 4B40 1 108 280 03E25F
injector_timer_schedule_load_dp:     MOV     DP, #001c0h            ; 4B43 1 108 280 62C001
                L       A, [DP]                ; 4B46 1 108 280 E2
                CMP     A, #000c0h             ; 4B47 1 108 280 C6C000
                JGE     injtimer_bank1_check2             ; 4B4A 1 108 280 CD3B
                CLR     A                      ; 4B4C 1 108 280 F9
                ST      A, [DP]                ; 4B4D 1 108 280 D2
                INC     DP                     ; 4B4E 1 108 280 72
                INC     DP                     ; 4B4F 1 108 280 72
                L       A, [DP]                ; 4B50 1 108 280 E2
                CMP     A, #000c0h             ; 4B51 1 108 280 C6C000
                JGE     injtimer_bank2_zero             ; 4B54 1 108 280 CD20
                CLR     A                      ; 4B56 1 108 280 F9
                ST      A, [DP]                ; 4B57 1 108 280 D2
                INC     DP                     ; 4B58 1 108 280 72
                INC     DP                     ; 4B59 1 108 280 72
                L       A, [DP]                ; 4B5A 1 108 280 E2
                CMP     A, #000c0h             ; 4B5B 1 108 280 C6C000
                JLT     injtimer_bank3_check             ; 4B5E 1 108 280 CA23
                ST      A, er1                 ; 4B60 1 108 280 89
                LB      A, off(001beh)         ; 4B61 0 108 280 F4BE
                SRLB    A                      ; 4B63 0 108 280 63
                RORB    off(001beh)            ; 4B64 0 108 280 C4BEC7
                SJ      injtimer_schedule_common             ; 4B67 0 108 280 CB36
injtimer_shift_path:     LB      A, off(001b6h)         ; 4B69 0 108 280 F4B6
                SLLB    A                      ; 4B6B 0 108 280 53
                ROLB    off(001b6h)            ; 4B6C 0 108 280 C4B6B7
                LB      A, off(001beh)         ; 4B6F 0 108 280 F4BE
                SLLB    A                      ; 4B71 0 108 280 53
                ROLB    off(001beh)            ; 4B72 0 108 280 C4BEB7
                RT                             ; 4B75 0 108 280 01
; [CG] injtimer_bank2_zero  @0x4B76
; [CG] TRACED: substantial routine (~0x150 bytes, 30+ internal branches) directly
; [CG] manipulating TMR0 (ADD TMR0,A - the hardware injector/ignition timer register) using
; [CG] values staged in RAM 0x1B6-0x1BC, decoded through four digital input bits at
; [CG] off(109h).0-3. Calls inj_wrap_clamp_calc twice internally. RAM 0x1B6-0x1BC sits
; [CG] immediately before the 0x1C0 array that injector_timer_schedule/_gated operate on,
; [CG] confirming this is the parent context for that pair - together they form the core
; [CG] injector pulse-width timer-bank assembly.
injtimer_bank2_zero:     ST      A, er1                 ; 4B76 1 108 280 89
                LB      A, off(001beh)         ; 4B77 0 108 280 F4BE
                SRLB    A                      ; 4B79 0 108 280 63
                RORB    off(001beh)            ; 4B7A 0 108 280 C4BEC7
                SRLB    A                      ; 4B7D 0 108 280 63
                RORB    off(001beh)            ; 4B7E 0 108 280 C4BEC7
                SJ      injtimer_bank_mask_calc             ; 4B81 0 108 280 CB14
injtimer_bank3_check:     CLR     A                      ; 4B83 1 108 280 F9
                ST      A, [DP]                ; 4B84 1 108 280 D2
                SJ      injtimer_schedule_done             ; 4B85 1 108 280 CB1E
injtimer_bank1_check2:     ST      A, er1                 ; 4B87 1 108 280 89
                LB      A, off(001beh)         ; 4B88 0 108 280 F4BE
                SLLB    A                      ; 4B8A 0 108 280 53
                ROLB    off(001beh)            ; 4B8B 0 108 280 C4BEB7
                CAL     inj_wrap_clamp_calc             ; 4B8E 0 108 280 32C04C
                LB      A, off(001b6h)         ; 4B91 0 108 280 F4B6
                SRLB    A                      ; 4B93 0 108 280 63
                SRLB    A                      ; 4B94 0 108 280 63
                ANDB    r0, A                  ; 4B95 0 108 280 20D1
injtimer_bank_mask_calc:     CAL     inj_wrap_clamp_calc             ; 4B97 0 108 280 32C04C
                LB      A, off(001b6h)         ; 4B9A 0 108 280 F4B6
                SRLB    A                      ; 4B9C 0 108 280 63
                ANDB    r0, A                  ; 4B9D 0 108 280 20D1
injtimer_schedule_common:     CAL     inj_wrap_clamp_calc             ; 4B9F 0 108 280 32C04C
                ANDB    r0, off(001b6h)        ; 4BA2 0 108 280 20D3B6
injtimer_schedule_done:     LB      A, off(001b6h)         ; 4BA5 0 108 280 F4B6
                SLLB    A                      ; 4BA7 0 108 280 53
                ROLB    off(001b6h)            ; 4BA8 0 108 280 C4B6B7
                LB      A, r0                  ; 4BAB 0 108 280 78
                ANDB    A, off(001b6h)         ; 4BAC 0 108 280 D7B6
                CMP     off(001c6h), #000c0h   ; 4BAE 0 108 280 B4C6C0C000
                JLT     injenable_reset_all             ; 4BB3 0 108 280 CA45
                MOVB    r1, off(001bfh)        ; 4BB5 0 108 280 C4BF49
                ANDB    off(001bfh), A         ; 4BB8 0 108 280 C4BFD1
                JBS     off(00122h).7, injenable_p2_update ; 4BBB 0 108 280 EF220A
                JBS     off(0011ch).5, injenable_p2_update ; 4BBE 0 108 280 ED1C07
                ANDB    off(001b7h), A         ; 4BC1 0 108 280 C4B7D1
                ORB     off(00122h), #001h     ; 4BC4 0 108 280 C422E001
injenable_p2_update:     LB      A, off(001b7h)         ; 4BC8 0 108 280 F4B7
                ORB     A, #0f0h               ; 4BCA 0 108 280 E6F0
                ANDB    P2, A                  ; 4BCC 0 108 280 C524D1
                ANDB    TRNSIT, #0fbh          ; 4BCF 0 108 280 C546D0FB
                ANDB    PSWH, #0feh            ; 4BD3 0 108 280 A2D0FE
                ORB     TCON0, #004h           ; 4BD6 0 108 280 C540E004
                L       A, TM0                 ; 4BDA 1 108 280 E530
                ORB     PSWH, #001h            ; 4BDC 1 108 280 A2E001
                ANDB    TCON0, #0fbh           ; 4BDF 1 108 280 C540D0FB
                CMPB    r1, #00fh              ; 4BE3 1 108 280 21C00F
                JEQ     inj_accum2_direct             ; 4BE6 1 108 280 C930
                SUB     A, TMR0                ; 4BE8 1 108 280 B532A2
                ADD     A, er1                 ; 4BEB 1 108 280 09
                JBR     off(00109h).0, inj_accum_check1 ; 4BEC 1 108 280 D8092E
                JBR     off(00109h).1, inj_accum_check2 ; 4BEF 1 108 280 D9097A
                JBS     off(00109h).2, inj_accum_check2_if_lt_goto_4c2d ; 4BF2 1 108 280 EA0931
                JBS     off(00109h).3, inj_accum_check2_if_lt_goto_4c2d ; 4BF5 1 108 280 EB092E
                SJ      inj_accum_check4             ; 4BF8 1 108 280 CB78
injenable_reset_all:     LB      A, #00fh               ; 4BFA 0 108 280 770F
                STB     A, off(001bfh)         ; 4BFC 0 108 280 D4BF
                STB     A, off(001b7h)         ; 4BFE 0 108 280 D4B7
                ORB     P2, A                  ; 4C00 0 108 280 C524E1
                SB      TCON0.2                ; 4C03 0 108 280 C5401A
                LB      A, off(001b6h)         ; 4C06 0 108 280 F4B6
                XORB    A, #0ffh               ; 4C08 0 108 280 F6FF
                MB      C, ACC.7               ; 4C0A 0 108 280 C5062F
                ROLB    A                      ; 4C0D 0 108 280 33
                STB     A, off(001beh)         ; 4C0E 0 108 280 D4BE
                RB      TCON0.2                ; 4C10 0 108 280 C5400A
                L       A, #00001h             ; 4C13 1 108 280 670100
                SJ      inj_accum1_store_new             ; 4C16 1 108 280 CB1B
inj_accum2_direct:     ADD     A, er1                 ; 4C18 1 108 280 09
                ST      A, TMR0                ; 4C19 1 108 280 D532
                SJ      inj_p2_calc_start             ; 4C1B 1 108 280 CB75
inj_accum_check1:     JBR     off(00109h).1, inj_accum_check1_if_ram109_bit2_clr ; 4C1D 1 108 280 D9091C
                JBR     off(00109h).2, inj_accum_check1_if_ge_goto_inj_accum_direct_add ; 4C20 1 108 280 DA091F
                JBR     off(00109h).3, inj_accum_check4 ; 4C23 1 108 280 DB094C
inj_accum_check2_if_lt_goto_4c2d:     JLT     inj_accum_check2_cmp_acc             ; 4C26 1 108 280 CA05
                ADD     TMR0, A                ; 4C28 1 108 280 B53281
                SJ      inj_accum_check2_clear_acc             ; 4C2B 1 108 280 CB05
inj_accum_check2_cmp_acc:     CMP     A, #00100h             ; 4C2D 1 108 280 C60001
                JGE     inj_accum1_store_new             ; 4C30 1 108 280 CD01
inj_accum_check2_clear_acc:     CLR     A                      ; 4C32 1 108 280 F9
inj_accum1_store_new:     ST      A, off(001b8h)         ; 4C33 1 108 280 D4B8
                L       A, #00001h             ; 4C35 1 108 280 670100
                ST      A, off(001bah)         ; 4C38 1 108 280 D4BA
                SJ      inj_accum_store_114             ; 4C3A 1 108 280 CB54
inj_accum_check1_if_ram109_bit2_clr:     JBR     off(00109h).2, inj_accum_check1_if_ge_goto_inj_accum_direct_add ; 4C3C 1 108 280 DA0903
                JBS     off(00109h).3, inj_accum_check4 ; 4C3F 1 108 280 EB0930
inj_accum_check1_if_ge_goto_inj_accum_direct_add:     JGE     inj_accum_direct_add             ; 4C42 1 108 280 CD10
                SUB     A, off(001b8h)         ; 4C44 1 108 280 A7B8
                JLT     inj_accum1_add             ; 4C46 1 108 280 CA16
                SUB     A, off(001bah)         ; 4C48 1 108 280 A7BA
                JLT     inj_accum_check2_goto_764a             ; 4C4A 1 108 280 CA1A
                CMP     A, #00100h             ; 4C4C 1 108 280 C60001
                JGE     inj_accum_store_114             ; 4C4F 1 108 280 CD3F
                CLR     A                      ; 4C51 1 108 280 F9
                SJ      inj_accum_store_114             ; 4C52 1 108 280 CB3C
inj_accum_direct_add:     ADD     TMR0, A                ; 4C54 1 108 280 B53281
                CLR     A                      ; 4C57 1 108 280 F9
                ST      A, off(001b8h)         ; 4C58 1 108 280 D4B8
                ST      A, off(001bah)         ; 4C5A 1 108 280 D4BA
                SJ      inj_accum_store_114             ; 4C5C 1 108 280 CB32
inj_accum1_add:     J       inj_accum1_add_add_acc             ; 4C5E 1 108 280 03EF5F
inj_accum_check2_goto_764a:     J       inj_accum_check2_add_acc             ; 4C66 1 108 280 034A76
inj_accum_check2:     JBS     off(00109h).2, inj_accum_check2_if_lt_goto_4c2d ; 4C6C 1 108 280 EA09B7
                JBR     off(00109h).3, inj_accum_check1_if_ge_goto_inj_accum_direct_add ; 4C6F 1 108 280 DB09D0
inj_accum_check4:     JGE     inj_accum_check4_add_tmr0             ; 4C72 1 108 280 CD09
                SUB     A, off(001b8h)         ; 4C74 1 108 280 A7B8
                JGE     inj_accum_check4_cmp_acc             ; 4C76 1 108 280 CD0D
                J       inj_accum_check4_add_acc             ; 4C78 1 108 280 035876
inj_accum_check4_add_tmr0:     ADD     TMR0, A                ; 4C7D 1 108 280 B53281
                CLR     A                      ; 4C80 1 108 280 F9
                ST      A, off(001b8h)         ; 4C81 1 108 280 D4B8
                SJ      inj_accum2_store2             ; 4C83 1 108 280 CB06
inj_accum_check4_cmp_acc:     CMP     A, #00100h             ; 4C85 1 108 280 C60001
                JGE     inj_accum2_store2             ; 4C88 1 108 280 CD01
inj_accum2_zero2:     CLR     A                      ; 4C8A 1 108 280 F9
inj_accum2_store2:     ST      A, off(001bah)         ; 4C8B 1 108 280 D4BA
                L       A, #00001h             ; 4C8D 1 108 280 670100
inj_accum_store_114:     ST      A, off(001bch)         ; 4C90 1 108 280 D4BC
inj_p2_calc_start:     L       A, off(001b8h)         ; 4C92 1 108 280 E4B8
                JNE     inj_p2_calc_alt             ; 4C94 1 108 280 CE0E
                L       A, off(001bah)         ; 4C96 1 108 280 E4BA
                JEQ     inj_p2_calc_check114             ; 4C98 1 108 280 C90E
                LB      A, off(001beh)         ; 4C9A 0 108 280 F4BE
                SRLB    A                      ; 4C9C 0 108 280 63
                SRLB    A                      ; 4C9D 0 108 280 63
                SRLB    A                      ; 4C9E 0 108 280 63
                ORB     A, off(001beh)         ; 4C9F 0 108 280 E7BE
                J       inj_p2_calc_or197             ; 4CA1 0 108 280 03B14C
inj_p2_calc_alt:     LB      A, off(001beh)         ; 4CA4 0 108 280 F4BE
                SJ      inj_p2_calc_or197             ; 4CA6 0 108 280 CB09
inj_p2_calc_check114:     L       A, off(001bch)         ; 4CA8 1 108 280 E4BC
                JEQ     inj_p2_default_f             ; 4CAA 1 108 280 C910
                LB      A, off(001beh)         ; 4CAC 0 108 280 F4BE
                RORB    A                      ; 4CAE 0 108 280 43
                XORB    A, #0ffh               ; 4CAF 0 108 280 F6FF
inj_p2_calc_or197:     ORB     A, off(001b7h)         ; 4CB1 0 108 280 E7B7
                ANDB    A, #00fh               ; 4CB3 0 108 280 D60F
inj_p2_drive_return:     ORB     P2, A                  ; 4CB5 0 108 280 C524E1
                RB      off(00122h).7          ; 4CB8 0 108 280 C4220F
                RT                             ; 4CBB 0 108 280 01
; [CG] inj_p2_default_f  @0x4CBC
; [CG] TRACED: alternate entry that presets A=0x0F then jumps back into inj_wrap_clamp_calc's
; [CG] body (0x4CC0, immediately following) with a different starting value.
inj_p2_default_f:     LB      A, #00fh               ; 4CBC 0 108 280 770F
                SJ      inj_p2_drive_return             ; 4CBE 0 108 280 CBF5
inj_wrap_clamp_calc:     CLR     A                      ; 4CC0 1 108 280 F9
                XCHG    A, [DP]                ; 4CC1 1 108 280 B210
                MOV     X2, A                  ; 4CC3 1 108 280 51
                INC     DP                     ; 4CC4 1 108 280 72
                INC     DP                     ; 4CC5 1 108 280 72
                L       A, [DP]                ; 4CC6 1 108 280 E2
                SUB     A, X2                  ; 4CC7 1 108 280 91A2
                JLT     inj_wrap_clamp_zero             ; 4CC9 1 108 280 CA05
                CMP     A, #00100h             ; 4CCB 1 108 280 C60001
                JGE     inj_wrap_clamp_store             ; 4CCE 1 108 280 CD01
inj_wrap_clamp_zero:     CLR     A                      ; 4CD0 1 108 280 F9
inj_wrap_clamp_store:     ST      A, 00000h[X1]          ; 4CD1 1 108 280 D00000
                INC     X1                     ; 4CD4 1 108 280 70
                INC     X1                     ; 4CD5 1 108 280 70
                RT                             ; 4CD6 1 108 280 01
knock_helper1:     MOVB    r6, #077h              ; 4CD7 0 208 180 9E77
                JEQ     bitreverse_return             ; 4CD9 0 208 180 C908
bitreverse_loop:     MB      C, r6.7                ; 4CDB 0 208 180 262F
                ROLB    r6                     ; 4CDD 0 208 180 26B7
                SUBB    A, #001h               ; 4CDF 0 208 180 A601
                JNE     bitreverse_loop             ; 4CE1 0 208 180 CEF8
bitreverse_return:     LB      A, r6                  ; 4CE3 0 208 180 7E
                RT                             ; 4CE4 0 208 180 01
; [CG] tm0_resync_helper  @0x4CE5
; [CG] VERIFIED: snapshots TMR2 into er3, tests off(10Fh).7/IRQH.0, conditionally increments
; [CG] an event counter at RAM 0xDE, then divides the captured pair by a fixed divisor of 6.
; [CG] Called 3x around the TMR0 crank-edge adjustment code at 0x0601-0x061B.
tm0_resync_helper:     L       A, TMR2                ; 4CE5 1 108 280 E53A
                ST      A, er3                 ; 4CE7 1 108 280 8B
                JBS     off(0010fh).7, rpm_resync_gate ; 4CE8 1 108 280 EF0F0B
                MB      C, IRQH.0              ; 4CEB 1 108 280 C51928
                JGE     rpm_resync_gate             ; 4CEE 1 108 280 CD06
                INCB    0deh                   ; 4CF0 1 108 280 C5DE16
                SB      09eh.0                 ; 4CF3 1 108 280 C59E18
rpm_resync_gate:     SB      off(00120h).3          ; 4CF6 1 108 280 C4201B
                JEQ     rpm_resync_common             ; 4CF9 1 108 280 C93A
                SUB     A, 0e2h                ; 4CFB 1 108 280 B5E2A2
                JBR     off(00117h).2, rpm_resync_tcon2_check ; 4CFE 1 108 280 DA1722
                CLRB    r1                     ; 4D01 1 108 280 2115
                MOVB    r0, 0deh               ; 4D03 1 108 280 C5DE48
                SBCB    r0, #000h              ; 4D06 1 108 280 20B000
                MOV     er2, #00006h           ; 4D09 1 108 280 46980600
                DIV                            ; 4D0D 1 108 280 9037
                CMPB    r0, #000h              ; 4D0F 1 108 280 20C000
                JEQ     rpm_period_reset_calc             ; 4D12 1 108 280 C901
                CLR     A                      ; 4D14 1 108 280 F9
rpm_period_reset_calc:     ST      A, off(0012eh)         ; 4D15 1 108 280 D42E
                MOV     X1, #0000ch            ; 4D17 1 108 280 600C00
rpm_period_reset_loop:     DEC     X1                     ; 4D1A 1 108 280 80
                DEC     X1                     ; 4D1B 1 108 280 80
                ST      A, 00360h[X1]          ; 4D1C 1 108 280 D06003
                JNE     rpm_period_reset_loop             ; 4D1F 1 108 280 CEF9
                SJ      rpm_resync_common             ; 4D21 1 108 280 CB12
rpm_resync_tcon2_check:     MB      C, TCON2.2             ; 4D23 1 108 280 C5422A
                JGE     rpm_resync_store136             ; 4D26 1 108 280 CD01
                CLR     A                      ; 4D28 1 108 280 F9
rpm_resync_store136:     ST      A, off(0012eh)         ; 4D29 1 108 280 D42E
                LB      A, 0d2h                ; 4D2B 0 108 280 F5D2
                SLLB    A                      ; 4D2D 0 108 280 53
                EXTND                          ; 4D2E 1 108 280 F8
                MOV     X1, A                  ; 4D2F 1 108 280 50
                L       A, off(0012eh)         ; 4D30 1 108 280 E42E
                ST      A, 00360h[X1]          ; 4D32 1 108 280 D06003
rpm_resync_common:     L       A, er3                 ; 4D35 1 108 280 37
                ST      A, 0e2h                ; 4D36 1 108 280 D5E2
                CLRB    0deh                   ; 4D38 1 108 280 C5DE15
                CMPB    0d2h, #005h            ; 4D3B 1 108 280 C5D2C005
                JNE     crank_a3_gate             ; 4D3F 1 108 280 CE03
                SLLB    off(001c9h)            ; 4D41 1 108 280 C4C9D7
crank_a3_gate:     LB      A, off(0012ah)         ; 4D44 0 108 280 F42A
                CMPB    A, #002h               ; 4D46 0 108 280 C602
                JBS     off(001c9h).2, crank_dp_35e ; 4D48 0 108 280 EAC915
                JLT     crank_a3_gate_load_dp             ; 4D4B 0 108 280 CA04
                CMPB    A, #013h               ; 4D4D 0 108 280 C613
                JLE     crank_a3_gate_load_dp_2             ; 4D4F 0 108 280 CF17
crank_a3_gate_load_dp:     MOV     DP, #0035ah            ; 4D51 0 108 280 625A03
                MB      C, 0a0h.3              ; 4D54 0 108 280 C5A02B
                J       crank_pswl4_store             ; 4D57 0 108 280 036E4D
crank_mul_alt:     MULB                           ; 4D5A 0 108 280 A234
crank_mul_alt_mulb_acc:     MULB                           ; 4D5C 0 108 280 A234
                SJ      crank_a2_advance             ; 4D5E 0 108 280 CB30
crank_dp_35e:     MOV     DP, #0035eh            ; 4D60 0 108 280 625E03
                MB      C, 0a0h.4              ; 4D63 0 108 280 C5A02C
                SJ      crank_pswl4_store             ; 4D66 0 108 280 CB06
crank_a3_gate_load_dp_2:     MOV     DP, #00356h            ; 4D68 0 108 280 625603
                MB      C, 0a0h.2              ; 4D6B 0 108 280 C5A02A
crank_pswl4_store:     MB      PSWL.4, C              ; 4D6E 0 108 280 A33C
                LB      A, 0d2h                ; 4D70 0 108 280 F5D2
                CMPB    A, #004h               ; 4D72 0 108 280 C604
                JEQ     crank_mul_alt             ; 4D74 0 108 280 C9E4
                JGE     crank_a0_update             ; 4D76 0 108 280 CD0C
                STB     A, r0                  ; 4D78 0 108 280 88
                INCB    r0                     ; 4D79 0 108 280 A8
                LB      A, 0d0h                ; 4D7A 0 108 280 F5D0
                ADDB    A, #001h               ; 4D7C 0 108 280 8601
                J       crank_pswl4_store_cmp_acc             ; 4D7E 0 108 280 036576
crank_pswl4_store_if_ram117_bit0_clr:     JBR     off(00117h).0, crank_mul_alt_mulb_acc ; 4D81 0 108 280 D817D8
crank_a0_update:     L       A, [DP]                ; 4D84 1 108 280 E2
                ST      A, 0d0h                ; 4D85 1 108 280 D5D0
                DEC     DP                     ; 4D87 1 108 280 82
                LB      A, [DP]                ; 4D88 0 108 280 F2
                STB     A, 0cfh                ; 4D89 0 108 280 D5CF
                MB      C, PSWL.4              ; 4D8B 0 108 280 A32C
                MB      off(00122h).5, C       ; 4D8D 0 108 280 C4223D
crank_a2_advance:     CLR     A                      ; 4D90 1 108 280 F9
                MOV     er0, 0d0h              ; 4D91 1 108 280 B5D048
                ST      A, er3                 ; 4D94 1 108 280 8B
                LB      A, 0d2h                ; 4D95 0 108 280 F5D2
                ADDB    A, #001h               ; 4D97 0 108 280 8601
                CMPB    A, r0                  ; 4D99 0 108 280 48
                JEQ     crank_mul_common2             ; 4D9A 0 108 280 C918
                CMPB    A, #006h               ; 4D9C 0 108 280 C606
                JNE     crank_a2_check3             ; 4D9E 0 108 280 CE06
                LB      A, r0                  ; 4DA0 0 108 280 78
                JEQ     crank_mul_common2             ; 4DA1 0 108 280 C911
                SLLB    A                      ; 4DA3 0 108 280 53
                JLT     crank_mul_common2             ; 4DA4 0 108 280 CA0E
crank_a2_check3:     CMPB    0d2h, #003h            ; 4DA6 0 108 280 C5D2C003
                JNE     crank_mul_alt2             ; 4DAA 0 108 280 CE25
                CMPB    r0, #005h              ; 4DAC 0 108 280 20C005
                JNE     crank_mul_alt2             ; 4DAF 0 108 280 CE20
                MOV     er3, off(0012eh)       ; 4DB1 0 108 280 B42E4B
crank_mul_common2:     CLRB    r0                     ; 4DB4 0 108 280 2015
                L       A, off(0012eh)         ; 4DB6 1 108 280 E42E
                MUL                            ; 4DB8 1 108 280 9035
                LB      A, 0d0h                ; 4DBA 0 108 280 F5D0
                SLLB    A                      ; 4DBC 0 108 280 53
                JGE     crank_mul_common2_load_er3             ; 4DBD 0 108 280 CD2C
                RB      PSWH.0                 ; 4DBF 0 108 280 A208
                L       A, TM3                 ; 4DC1 1 108 280 E53C
                SUB     A, TMR2                ; 4DC3 1 108 280 B53AA2
                ADD     A, #00010h             ; 4DC6 1 108 280 861000
                CMP     A, er1                 ; 4DC9 1 108 280 49
                JGE     crank_mul_common2_clear_tcon3_bit2             ; 4DCA 1 108 280 CD0D
                L       A, TMR2                ; 4DCC 1 108 280 E53A
                ADD     A, er1                 ; 4DCE 1 108 280 09
                SJ      tmr3_reload_store2             ; 4DCF 1 108 280 CB10
crank_mul_alt2:     MUL                            ; 4DD1 0 108 280 9035
                RB      r0.0                   ; 4DD3 0 108 280 2008
                L       A, ACC                 ; 4DD5 1 108 280 E506
                SJ      tmr3_reload_clamp_min             ; 4DD7 1 108 280 CB1E
crank_mul_common2_clear_tcon3_bit2:     RB      TCON3.2                ; 4DD9 1 108 280 C5430A
                L       A, TM3                 ; 4DDC 1 108 280 E53C
                SUB     A, #00001h             ; 4DDE 1 108 280 A60100
tmr3_reload_store2:     ST      A, TMR3                ; 4DE1 1 108 280 D53E
                RB      TCON3.3                ; 4DE3 1 108 280 C5430B
                SB      PSWH.0                 ; 4DE6 1 108 280 A218
                J       tmr3_reload_clamp_min             ; 4DE8 1 108 280 03F74D
crank_mul_common2_load_er3:     L       A, er3                 ; 4DEB 1 108 280 37
                ADD     A, er1                 ; 4DEC 1 108 280 09
                JGE     tmr3_reload_clamp_check             ; 4DED 1 108 280 CD03
                L       A, #0ffffh             ; 4DEF 1 108 280 67FFFF
tmr3_reload_clamp_check:     CMP     A, #0001fh             ; 4DF2 1 108 280 C61F00
                JGE     tmr3_store_e8             ; 4DF5 1 108 280 CD03
tmr3_reload_clamp_min:     L       A, #0001fh             ; 4DF7 1 108 280 671F00
tmr3_store_e8:     ST      A, 0e0h                ; 4DFA 1 108 280 D5E0
; (skeleton: knock control unit removed: no knock sample from port A, nothing shifted out on P1.7/P1.3)
crank_a2_check4:
crank_a8_p1_output:
                MOV     DP, #02f00h            ; 4E28 1 108 280 62002F
                LB      A, P1                  ; 4E2B 0 108 280 F522
                STB     A, [DP]                ; 4E2D 0 108 280 D2
                RT                             ; 4E2E 0 108 280 01
ign_angle_to_timer_convert:     CLRB    A                      ; 4E2F 0 200 180 FA
; [H] --- Converts a computed ignition angle/trim (r4) into a hardware timer-compare value
; [H] (scaling via MULB by 3 and combining with er1), used when programming the two ignition
; [H] coil-channel hardware timers (igntiming_output_coil1 and the DP=0x35D channel that follows).
; [H] Clamps the result if it would exceed 0xFE00 range (CMPB ACC,#0feh check).
                STB     A, r3                  ; 4E30 0 200 180 8B
                SUBB    A, r4                  ; 4E31 0 200 180 2C
                MOVB    r0, #003h              ; 4E32 0 200 180 9803
                MULB                           ; 4E34 0 200 180 A234
                L       A, ACC                 ; 4E36 1 200 180 E506
                SUB     A, er1                 ; 4E38 1 200 180 29
                SLL     A                      ; 4E39 1 200 180 53
                SWAP                           ; 4E3A 1 200 180 83
                CMPB    ACC, #0feh             ; 4E3B 1 200 180 C506C0FE
                JNE     ign_timer_clamp_store             ; 4E3F 1 200 180 CE03
                L       A, #000ffh             ; 4E41 1 200 180 67FF00
ign_timer_clamp_store:     ST      A, er0                 ; 4E44 1 200 180 88
                CLRB    A                      ; 4E45 0 200 180 FA
                SUBB    A, r2                  ; 4E46 0 200 180 2A
                SLLB    A                      ; 4E47 0 200 180 53
                JNE     ign_timer_convert_return             ; 4E48 0 200 180 CE03
                LB      A, #0ffh               ; 4E4A 0 200 180 77FF
                SC                             ; 4E4C 0 200 180 85
ign_timer_convert_return:     RT                             ; 4E4D 0 200 180 01
table_interp_lookup_prescan:     CMPCB   A, [X1]                ; 4E4E 0 200 180 90AE
                JLT     knockretard_r1_store             ; 4E50 0 200 180 CA02
                LCB     A, [X1]                ; 4E52 0 200 180 90AA
knockretard_r1_store:     CMPCB   A, 00002h[X1]          ; 4E54 0 200 180 90AF0200
                JGE     knockretard_sub_result             ; 4E58 0 200 180 CD04
                LCB     A, 00002h[X1]          ; 4E5A 0 200 180 90AB0200
knockretard_sub_result:     MOVB    r0, A                  ; 4E5E 0 200 180 208A
                SJ      table_interp_delta_calc             ; 4E60 0 200 180 CB15
vcal_0:         CMPCB   A, 00002h[X1]          ; 4E62 0 200 180 90AF0200
; [H] --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; [H] fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; [H] pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; [H] find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; [H] same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found             ; 4E66 0 200 180 CD04
                INC     X1                     ; 4E68 0 200 180 70
                INC     X1                     ; 4E69 0 200 180 70
                SJ      vcal_0                 ; 4E6A 0 200 180 CBF6
table_interp_bracket_found:     STB     A, r0                  ; 4E6C 0 200 180 88
                LCB     A, 00003h[X1]          ; 4E6D 0 200 180 90AB0300
                STB     A, r6                  ; 4E71 0 200 180 8E
                LCB     A, 00001h[X1]          ; 4E72 0 200 180 90AB0100
                STB     A, r7                  ; 4E76 0 200 180 8F
table_interp_delta_calc:     LCB     A, 00002h[X1]          ; 4E77 0 200 180 90AB0200
                STB     A, r1                  ; 4E7B 0 200 180 89
                SUBB    r0, A                  ; 4E7C 0 200 180 20A1
                LCB     A, [X1]                ; 4E7E 0 200 180 90AA
                SUBB    A, r1                  ; 4E80 0 200 180 29
                STB     A, r1                  ; 4E81 0 200 180 89
                LB      A, r7                  ; 4E82 0 200 180 7F
                SUBB    A, r6                  ; 4E83 0 200 180 2E
                MB      PSWL.4, C              ; 4E84 0 200 180 A33C
                JGE     table_interp_delta_calc_mulb_acc             ; 4E86 0 200 180 CD03
                STB     A, r7                  ; 4E88 0 200 180 8F
                CLRB    A                      ; 4E89 0 200 180 FA
                SUBB    A, r7                  ; 4E8A 0 200 180 2F
table_interp_delta_calc_mulb_acc:     MULB                           ; 4E8B 0 200 180 A234
                MOVB    r0, r1                 ; 4E8D 0 200 180 2148
                DIVB                           ; 4E8F 0 200 180 A236
                RB      PSWL.4                 ; 4E91 0 200 180 A30C
                JEQ     table_interp_delta_calc_addb_acc             ; 4E93 0 200 180 C904
                SUBB    r6, A                  ; 4E95 0 200 180 26A1
                LB      A, r6                  ; 4E97 0 200 180 7E
                RT                             ; 4E98 0 200 180 01
table_interp_delta_calc_addb_acc:     ADDB    A, r6                  ; 4E99 0 200 180 0E
                STB     A, r6                  ; 4E9A 0 200 180 8E
                RT                             ; 4E9B 0 200 180 01
vcal_2:         CMPCB   A, [X1]                ; 4E9C 0 200 180 90AE
                JLT     vcal1_bracket_check             ; 4E9E 0 200 180 CA02
                LCB     A, [X1]                ; 4EA0 0 200 180 90AA
vcal1_bracket_check:     CMPCB   A, 00002h[X1]          ; 4EA2 0 200 180 90AF0200
                JGE     vcal1_bracket_check_goto_table_interp_bracket_found             ; 4EA6 0 200 180 CD04
                LCB     A, 00002h[X1]          ; 4EA8 0 200 180 90AB0200
vcal1_bracket_check_goto_table_interp_bracket_found:     SJ      table_interp_bracket_found             ; 4EAC 0 200 180 CBBE
vcal_3:         CMPCB   A, [X1]                ; 4EAE 0 208 180 90AE
                JLT     vcal2_bracket_check             ; 4EB0 0 208 180 CA02
                LCB     A, [X1]                ; 4EB2 0 208 180 90AA
vcal2_bracket_check:     CMPCB   A, 00003h[X1]          ; 4EB4 0 208 180 90AF0300
                JGE     vcal2_bracket_check_goto_vcal_common_interp             ; 4EB8 0 208 180 CD04
                LCB     A, 00003h[X1]          ; 4EBA 0 208 180 90AB0300
vcal2_bracket_check_goto_vcal_common_interp:     SJ      vcal_common_interp             ; 4EBE 0 208 180 CB0B
vcal_1:         CMPCB   A, 00003h[X1]          ; 4EC0 0 208 180 90AF0300
                JGE     vcal_common_interp             ; 4EC4 0 208 180 CD05
                INC     X1                     ; 4EC6 0 208 180 70
                INC     X1                     ; 4EC7 0 208 180 70
                INC     X1                     ; 4EC8 0 208 180 70
                SJ      vcal_1                 ; 4EC9 0 208 180 CBF5
vcal_common_interp:     STB     A, r0                  ; 4ECB 0 208 180 88
                LCB     A, 00003h[X1]          ; 4ECC 0 208 180 90AB0300
                STB     A, r4                  ; 4ED0 0 208 180 8C
                SUBB    r0, A                  ; 4ED1 0 208 180 20A1
                CLRB    r1                     ; 4ED3 0 208 180 2115
                LCB     A, [X1]                ; 4ED5 0 208 180 90AA
                SUBB    A, r4                  ; 4ED7 0 208 180 2C
                STB     A, r4                  ; 4ED8 0 208 180 8C
                CLRB    r5                     ; 4ED9 0 208 180 2515
                CLR     A                      ; 4EDB 1 208 180 F9
                LC      A, 00004h[X1]          ; 4EDC 1 208 180 90A90400
                ST      A, er3                 ; 4EE0 1 208 180 8B
                LC      A, 00001h[X1]          ; 4EE1 1 208 180 90A90100
injtimer_bank_calc3:     SUB     A, er3                 ; 4EE5 1 200 180 2B
                MB      PSWL.4, C              ; 4EE6 1 200 180 A33C
                JGE     injtimer_bank_calc3_mul_acc             ; 4EE8 1 200 180 CD03
                ST      A, er1                 ; 4EEA 1 200 180 89
                CLR     A                      ; 4EEB 1 200 180 F9
                SUB     A, er1                 ; 4EEC 1 200 180 29
injtimer_bank_calc3_mul_acc:     MUL                            ; 4EED 1 200 180 9035
                MOV     er0, er1               ; 4EEF 1 200 180 4548
                DIV                            ; 4EF1 1 200 180 9037
                RB      PSWL.4                 ; 4EF3 1 200 180 A30C
                JEQ     injtimer_bank_calc3_add_acc             ; 4EF5 1 200 180 C904
                SUB     er3, A                 ; 4EF7 1 200 180 47A1
                L       A, er3                 ; 4EF9 1 200 180 37
                RT                             ; 4EFA 1 200 180 01
injtimer_bank_calc3_add_acc:     ADD     A, er3                 ; 4EFB 1 200 180 0B
                ST      A, er3                 ; 4EFC 1 200 180 8B
                RT                             ; 4EFD 1 200 180 01
; [CG] table_interp_lookup_4byte  @0x4EFE
; [CG] Called 6x; used at 0x0BA6 after a 0x6A79/0x6A89 table select.
table_interp_lookup_4byte:     CMPC    A, 00004h[X1]          ; 4EFE 1 200 180 90AD0400
                JGE     table_interp_4byte_bracket             ; 4F02 1 200 180 CD06
                ADD     X1, #00004h            ; 4F04 1 200 180 90800400
                SJ      table_interp_lookup_4byte             ; 4F08 1 200 180 CBF4
table_interp_4byte_bracket:     ST      A, er0                 ; 4F0A 1 200 180 88
                LC      A, 00004h[X1]          ; 4F0B 1 200 180 90A90400
                ST      A, er2                 ; 4F0F 1 200 180 8A
                SUB     er0, A                 ; 4F10 1 200 180 44A1
                LC      A, [X1]                ; 4F12 1 200 180 90A8
                SUB     A, er2                 ; 4F14 1 200 180 2A
                ST      A, er2                 ; 4F15 1 200 180 8A
                LC      A, 00006h[X1]          ; 4F16 1 200 180 90A90600
                ST      A, er3                 ; 4F1A 1 200 180 8B
                LC      A, 00002h[X1]          ; 4F1B 1 200 180 90A90200
                SJ      injtimer_bank_calc3             ; 4F1F 1 200 180 CBC4
; [CG] subtract24_clamp_byte  @0x4F21
; [CG] VERIFIED: computes A-24, clamps the result to the unsigned byte range - 0 if the
; [CG] subtraction went negative, 0xFF if it overflowed 255.
subtract24_clamp_byte:     SUBB    A, #018h               ; 4F21 0 200 180 A618
                JGE     subtract24_clamp_byte_load_carry_ramacc_bit7             ; 4F23 0 200 180 CD02
                CLRB    A                      ; 4F25 0 200 180 FA
                RT                             ; 4F26 0 200 180 01
subtract24_clamp_byte_load_carry_ramacc_bit7:     MB      C, ACCH.7              ; 4F27 0 200 180 C5072F
                ROLB    A                      ; 4F2A 0 200 180 33
                JGE     subtract24_clamp_byte_return             ; 4F2B 0 200 180 CD02
                LB      A, #0ffh               ; 4F2D 0 200 180 77FF
subtract24_clamp_byte_return:     RT                             ; 4F2F 0 200 180 01
mul_scale_helper2:     MUL                            ; 4F30 1 208 180 9035
                MOV     er2, er1               ; 4F32 1 208 180 454A
                CLR     A                      ; 4F34 1 208 180 F9
                SUB     A, er0                 ; 4F35 1 208 180 28
                MOV     er0, [DP]              ; 4F36 1 208 180 B248
                MUL                            ; 4F38 1 208 180 9035
                L       A, er1                 ; 4F3A 1 208 180 35
                ADD     A, er2                 ; 4F3B 1 208 180 0A
                ST      A, [DP]                ; 4F3C 1 208 180 D2
                RT                             ; 4F3D 1 208 180 01
rpm_accel_track_helper:     MUL                            ; 4F3E 1 208 180 9035
                MOV     DP, er1                ; 4F40 1 208 180 457A
                MOV     X2, A                  ; 4F42 1 208 180 51
                L       A, er3                 ; 4F43 1 208 180 37
                MUL                            ; 4F44 1 208 180 9035
                SUB     er2, A                 ; 4F46 1 208 180 46A1
                L       A, er1                 ; 4F48 1 208 180 35
                SBC     er3, A                 ; 4F49 1 208 180 47B1
                L       A, X2                  ; 4F4B 1 208 180 41
                ADD     er2, A                 ; 4F4C 1 208 180 4681
                L       A, DP                  ; 4F4E 1 208 180 42
                ADC     A, er3                 ; 4F4F 1 208 180 1B
                RT                             ; 4F50 1 208 180 01
injtimer_bank_calc1:     MOV     er2, 00000h[X1]        ; 4F51 1 208 180 B000004A
                SUB     A, er2                 ; 4F55 1 208 180 2A
                JGE     injtimer_bank_calc1_mul             ; 4F56 1 208 180 CD02
                VCAL    7                      ; 4F58 1 208 180 17
                SC                             ; 4F59 1 208 180 85
injtimer_bank_calc1_mul:     MUL                            ; 4F5A 1 208 180 9035
                ST      A, er0                 ; 4F5C 1 208 180 88
                L       A, 00002h[X1]          ; 4F5D 1 208 180 E00200
                SJ      injtimer_bank_calc1_sign             ; 4F60 1 208 180 CB10
; [CG] interp_bracket_delta_scale_2  @0x4F62
; [CG] VERIFIED: structurally identical to injtimer_bank_calc1, operating on the
; [CG] upper breakpoint instead of the lower.
interp_bracket_delta_scale_2:     MOV     er2, 00000h[X1]        ; 4F62 1 208 180 B000004A
                SUB     A, er2                 ; 4F66 1 208 180 2A
                JGE     interp_bracket_delta_scale_2_mul_acc             ; 4F67 1 208 180 CD02
                VCAL    7                      ; 4F69 1 208 180 17
                SC                             ; 4F6A 1 208 180 85
interp_bracket_delta_scale_2_mul_acc:     MUL                            ; 4F6B 1 208 180 9035
                ST      A, er0                 ; 4F6D 1 208 180 88
                MOV     DP, #00388h            ; 4F6E 1 208 180 628803
                L       A, [DP]                ; 4F71 1 208 180 E2
injtimer_bank_calc1_sign:     JGE     injtimer_bank_calc1_add             ; 4F72 1 208 180 CD05
                SUB     A, er0                 ; 4F74 1 208 180 28
                ST      A, er0                 ; 4F75 1 208 180 88
                L       A, er2                 ; 4F76 1 208 180 36
                SBC     A, er1                 ; 4F77 1 208 180 39
                RT                             ; 4F78 1 208 180 01
injtimer_bank_calc1_add:     ADD     A, er0                 ; 4F79 1 208 180 08
                ST      A, er0                 ; 4F7A 1 208 180 88
                L       A, er2                 ; 4F7B 1 208 180 36
                ADC     A, er1                 ; 4F7C 1 208 180 19
                RT                             ; 4F7D 1 208 180 01
                DB  0E2h ; 4F7E
vcal_5:         MB      C, ACCH.7              ; 4F7F 1 208 180 C5072F
                JLT     vcal_5_add_acc             ; 4F82 1 208 180 CA08
vcal_6:         ADD     A, er3                 ; 4F84 1 208 180 0B
                JGE     vcal4_store             ; 4F85 1 208 180 CD09
                L       A, #0ffffh             ; 4F87 1 208 180 67FFFF
                SJ      vcal4_store             ; 4F8A 1 208 180 CB04
vcal_5_add_acc:     ADD     A, er3                 ; 4F8C 1 208 180 0B
                JLT     vcal4_store             ; 4F8D 1 208 180 CA01
                CLR     A                      ; 4F8F 1 208 180 F9
vcal4_store:     ST      A, er3                 ; 4F90 1 208 180 8B
                RT                             ; 4F91 1 208 180 01
                DB  0E2h ; 4F92
; [CG] add_saturate_s16  @0x4F93
; [CG] VERIFIED: adds er3 to A with explicit signed 16-bit saturation - clamps to 0x7FFF on
; [CG] positive overflow, 0x8000 on negative overflow, checking ACCH.7 and r7.7 sign bits
; [CG] before and after the add.
add_saturate_s16:     MB      C, ACCH.7              ; 4F93 1 100 280 C5072F
                JLT     add_saturate_s16_load_carry_r7_bit7             ; 4F96 1 100 280 CA0F
                MB      C, r7.7                ; 4F98 1 100 280 272F
                JLT     signext_common_add             ; 4F9A 1 100 280 CA1A
                ADD     A, er3                 ; 4F9C 1 100 280 0B
                MB      C, ACCH.7              ; 4F9D 1 100 280 C5072F
                JGE     signext_common_add_store_er3             ; 4FA0 1 100 280 CD15
                L       A, #07fffh             ; 4FA2 1 100 280 67FF7F
                SJ      signext_common_add_store_er3             ; 4FA5 1 100 280 CB10
add_saturate_s16_load_carry_r7_bit7:     MB      C, r7.7                ; 4FA7 1 100 280 272F
                JGE     signext_common_add             ; 4FA9 1 100 280 CD0B
                ADD     A, er3                 ; 4FAB 1 100 280 0B
                MB      C, ACCH.7              ; 4FAC 1 100 280 C5072F
                JLT     signext_common_add_store_er3             ; 4FAF 1 100 280 CA06
                L       A, #08000h             ; 4FB1 1 100 280 670080
                SJ      signext_common_add_store_er3             ; 4FB4 1 100 280 CB01
signext_common_add:     ADD     A, er3                 ; 4FB6 1 100 280 0B
signext_common_add_store_er3:     ST      A, er3                 ; 4FB7 1 100 280 8B
                RT                             ; 4FB8 1 100 280 01
scale_mul5_div4:     MOV     er0, #00005h           ; 4FB9 1 100 280 44980500
                MUL                            ; 4FBD 1 100 280 9035
                SRL     er1                    ; 4FBF 1 100 280 45E7
                ROR     A                      ; 4FC1 1 100 280 43
                SRL     er1                    ; 4FC2 1 100 280 45E7
                ROR     A                      ; 4FC4 1 100 280 43
                CMPB    r2, #000h              ; 4FC5 1 100 280 22C000
                JEQ     scale_mul5_div4_return             ; 4FC8 1 100 280 C903
                L       A, #0ffffh             ; 4FCA 1 100 280 67FFFF
scale_mul5_div4_return:     RT                             ; 4FCD 1 100 280 01
vcal_7:         MB      C, PSWH.4              ; 4FCE 0 200 180 A22C
                JGE     vcal_7_xorb_acc             ; 4FD0 0 200 180 CD07
                XORB    A, #0ffh               ; 4FD2 0 200 180 F6FF
                BRK                            ; 4FD4 0 200 180 FF
                DB  086h,001h,000h,001h ; 4FD5
vcal_7_xorb_acc:     XORB    A, #0ffh               ; 4FD9 0 200 180 F6FF
                ADDB    A, #001h               ; 4FDB 0 200 180 8601
                RT                             ; 4FDD 0 200 180 01
newval_table3_call_sub_clear_acc:     CLR     A                      ; 4FDE 1 200 180 F9
                ST      A, er0                 ; 4FDF 1 200 180 88
                ST      A, er2                 ; 4FE0 1 200 180 8A
                LB      A, r3                  ; 4FE1 0 200 180 7B
                CMPB    A, r6                  ; 4FE2 0 200 180 4E
                JLT     scaler_table_search_start             ; 4FE3 0 200 180 CA01
                LB      A, r6                  ; 4FE5 0 200 180 7E
scaler_table_search_start:     STB     A, r6                  ; 4FE6 0 200 180 8E
                ADD     X1, A                  ; 4FE7 0 200 180 9081
scaler_table_search_loop:     INCB    r6                     ; 4FE9 0 200 180 AE
                INC     X1                     ; 4FEA 0 200 180 70
                LCB     A, [X1]                ; 4FEB 0 200 180 90AA
                JEQ     scaler_table_interp             ; 4FED 0 200 180 C903
                CMPB    A, r2                  ; 4FEF 0 200 180 4A
                JLE     scaler_table_search_loop             ; 4FF0 0 200 180 CFF7
scaler_table_interp:     LB      A, r2                  ; 4FF2 0 200 180 7A
scaler_table_search_back:     DECB    r6                     ; 4FF3 0 200 180 BE
                DEC     X1                     ; 4FF4 0 200 180 80
                CMPCB   A, [X1]                ; 4FF5 0 200 180 90AE
                JLT     scaler_table_search_back             ; 4FF7 0 200 180 CAFA
                LCB     A, [X1]                ; 4FF9 0 200 180 90AA
                STB     A, r4                  ; 4FFB 0 200 180 8C
                LB      A, r2                  ; 4FFC 0 200 180 7A
                SUBB    A, r4                  ; 4FFD 0 200 180 2C
                STB     A, r0                  ; 4FFE 0 200 180 88
                INC     X1                     ; 4FFF 0 200 180 70
                LCB     A, [X1]                ; 5000 0 200 180 90AA
                SUBB    A, r4                  ; 5002 0 200 180 2C
                STB     A, r4                  ; 5003 0 200 180 8C
                CLR     A                      ; 5004 1 200 180 F9
                MB      C, PSWL.4              ; 5005 1 200 180 A32C
                JGE     scaler_div_final             ; 5007 1 200 180 CD04
                ROL     er0                    ; 5009 1 200 180 44B7
                SLL     er2                    ; 500B 1 200 180 46D7
scaler_div_final:     DIV                            ; 500D 1 200 180 9037
                RT                             ; 500F 1 200 180 01
table2d_lookup_interp:     CLR     A                      ; 5010 1 200 180 F9
; [H] --- Generic 2D table lookup/interpolation helper (row x column, e.g. RPM x Load). Given a
; [H] table base in X1, row width in r0, row index in r1, column offset in r2, column count in r3.
; [H] Companion to the 1D table_interp_lookup used elsewhere.
                LB      A, r2                  ; 5011 0 200 180 7A
                ADD     X1, A                  ; 5012 0 200 180 9081
                MOV     DP, X1                 ; 5014 0 200 180 907A
                L       A, #00101h             ; 5016 1 200 180 670101
                MB      C, PSWL.5              ; 5019 1 200 180 A32D
                JGE     table2d_row_calc             ; 501B 1 200 180 CD08
                LB      A, r1                  ; 501D 0 200 180 79
                MULB                           ; 501E 0 200 180 A234
                ADD     DP, A                  ; 5020 0 200 180 9281
                CLR     A                      ; 5022 1 200 180 F9
                LC      A, [DP]                ; 5023 1 200 180 92A8
table2d_row_calc:     ST      A, er2                 ; 5025 1 200 180 8A
                LB      A, r3                  ; 5026 0 200 180 7B
                MULB                           ; 5027 0 200 180 A234
                ADD     X1, A                  ; 5029 0 200 180 9081
                LC      A, [X1]                ; 502B 0 200 180 90A8
                MOV     DP, A                  ; 502D 0 200 180 52
                CLR     A                      ; 502E 1 200 180 F9
                LB      A, r0                  ; 502F 0 200 180 78
                ADD     X1, A                  ; 5030 0 200 180 9081
                LC      A, [X1]                ; 5032 0 200 180 90A8
                MOV     X1, A                  ; 5034 0 200 180 50
                MOVB    r0, r4                 ; 5035 0 200 180 2448
                L       A, DP                  ; 5037 1 200 180 42
                MULB                           ; 5038 1 200 180 A234
                ST      A, er1                 ; 503A 1 200 180 89
                MOVB    r0, r5                 ; 503B 1 200 180 2548
                L       A, DP                  ; 503D 1 200 180 42
                SWAP                           ; 503E 1 200 180 83
                MULB                           ; 503F 1 200 180 A234
                MOV     DP, A                  ; 5041 1 200 180 52
                L       A, X1                  ; 5042 1 200 180 40
                SWAP                           ; 5043 1 200 180 83
                MULB                           ; 5044 1 200 180 A234
                MOVB    r0, r4                 ; 5046 1 200 180 2448
                ST      A, er2                 ; 5048 1 200 180 8A
                L       A, X1                  ; 5049 1 200 180 40
                MULB                           ; 504A 1 200 180 A234
                MOV     X1, er1                ; 504C 1 200 180 4578
                XCHG    A, er2                 ; 504E 1 200 180 4610
                MOV     er0, X2                ; 5050 1 200 180 9148
                CAL     table2d_mul_combine             ; 5052 1 200 180 326350
                MOV     er2, X1                ; 5055 1 200 180 904A
                MOV     X1, A                  ; 5057 1 200 180 50
                L       A, DP                  ; 5058 1 200 180 42
                CAL     table2d_mul_combine             ; 5059 1 200 180 326350
                L       A, X1                  ; 505C 1 200 180 40
                MOV     er0, er3               ; 505D 1 200 180 4748
                CAL     table2d_mul_combine             ; 505F 1 200 180 326350
                RT                             ; 5062 1 200 180 01
table2d_mul_combine:     SUB     A, er2                 ; 5063 1 200 180 2A
                MB      PSWL.4, C              ; 5064 1 200 180 A33C
                JGE     table2d_mul_combine_mul_acc             ; 5066 1 200 180 CD03
                ST      A, er1                 ; 5068 1 200 180 89
                CLR     A                      ; 5069 1 200 180 F9
                SUB     A, er1                 ; 506A 1 200 180 29
table2d_mul_combine_mul_acc:     MUL                            ; 506B 1 200 180 9035
                L       A, er1                 ; 506D 1 200 180 35
                MB      C, PSWL.4              ; 506E 1 200 180 A32C
                JGE     table2d_mul_combine_add_acc             ; 5070 1 200 180 CD04
                SUB     er2, A                 ; 5072 1 200 180 46A1
                L       A, er2                 ; 5074 1 200 180 36
                RT                             ; 5075 1 200 180 01
table2d_mul_combine_add_acc:     ADD     A, er2                 ; 5076 1 200 180 0A
                ST      A, er2                 ; 5077 1 200 180 8A
                RT                             ; 5078 1 200 180 01
knock_244_helper:     EXTND                          ; 5079 1 200 180 F8
                ADD     DP, A                  ; 507A 1 200 180 9281
                CLR     A                      ; 507C 1 200 180 F9
                LCB     A, [DP]                ; 507D 1 200 180 92AA
                ST      A, er2                 ; 507F 1 200 180 8A
                INC     DP                     ; 5080 1 200 180 72
                LCB     A, [DP]                ; 5081 1 200 180 92AA
                CAL     table2d_mul_combine             ; 5083 1 200 180 326350
                LB      A, r4                  ; 5086 0 200 180 7C
                RT                             ; 5087 0 200 180 01
; [CG] map_result_postscale  @0x5088
; [CG] Called right after table2d_lookup_interp at 0x1273.
map_result_postscale:     MOVB    r0, off(00137h)        ; 5088 0 100 280 C43748
                MOVB    r1, #001h              ; 508B 0 100 280 9901
                CMPB    r0, #080h              ; 508D 0 100 280 20C080
                JGE     mul_scale_rotate             ; 5090 0 100 280 CD01
                INCB    r1                     ; 5092 0 100 280 A9
mul_scale_rotate:     MUL                            ; 5093 0 100 280 9035
                LB      A, r2                  ; 5095 0 100 280 7A
                L       A, ACC                 ; 5096 1 100 280 E506
                SWAP                           ; 5098 1 100 280 83
                SRLB    r3                     ; 5099 1 100 280 23E7
                ROR     A                      ; 509B 1 100 280 43
                CMPB    r3, #000h              ; 509C 1 100 280 23C000
                JEQ     stub_return_short             ; 509F 1 100 280 C903
                L       A, #0ffffh             ; 50A1 1 100 280 67FFFF
stub_return_short:     RT                             ; 50A4 1 100 280 01
; [CG] sub_clamp_helper  @0x50A5
; [CG] Called 3x; used at 0x16CF.
sub_clamp_helper:     MULB                           ; 50A5 0 100 280 A234
                L       A, ACC                 ; 50A7 1 100 280 E506
                SLL     A                      ; 50A9 1 100 280 53
                LB      A, ACCH                ; 50AA 0 100 280 F507
                JGE     sub_clamp_helper_return             ; 50AC 0 100 280 CD02
                LB      A, #0ffh               ; 50AE 0 100 280 77FF
sub_clamp_helper_return:     RT                             ; 50B0 0 100 280 01
; [CG] scale_ram1e4_mul_shr2  @0x50B1
; [CG] VERIFIED: multiplies A by RAM word 0x1E4, then shifts the 32-bit product right by 2
; [CG] bits (two SRL/RORB pairs) before falling into mul_zero_if_r3_zero.
scale_ram1e4_mul_shr2:     MOV     er0, off(001e4h)       ; 50B1 0 100 280 B4E448
                MUL                            ; 50B4 0 100 280 9035
                SRL     er1                    ; 50B6 0 100 280 45E7
                RORB    A                      ; 50B8 0 100 280 43
                SRL     er1                    ; 50B9 0 100 280 45E7
                RORB    A                      ; 50BB 0 100 280 43
                SJ      mul_zero_if_r3_zero_load_r2             ; 50BC 0 100 280 CB02
; [CG] mul_zero_if_r3_zero  @0x50BE
; [CG] VERIFIED: performs MUL, then forces the result to 0xFFFF if r3==0 (a "no data"
; [CG] sentinel), otherwise returns the swapped product. Direct-entry form used both
; [CG] standalone and as the tail of scale_ram1e4_mul_shr2.
mul_zero_if_r3_zero:     MUL                            ; 50BE 1 100 280 9035
mul_zero_if_r3_zero_load_r2:     LB      A, r2                  ; 50C0 0 100 280 7A
                L       A, ACC                 ; 50C1 1 100 280 E506
                SWAP                           ; 50C3 1 100 280 83
                CMPB    r3, #000h              ; 50C4 1 100 280 23C000
                JEQ     tipin_table_diff_calc             ; 50C7 1 100 280 C903
                L       A, #0ffffh             ; 50C9 1 100 280 67FFFF
tipin_table_diff_calc:     RT                             ; 50CC 1 100 280 01
idle_stall_helper:     MOV     X2, #00010h            ; 50CD 1 208 180 611000
                MOV     DP, #01000h            ; 50D0 1 208 180 620010
                SJ      clamp_range_check             ; 50D3 1 208 180 CB06
clamp_range_check:     CMP     A, X2                  ; 50DB 1 208 180 91C2
                JLE     clamp_range_lowside             ; 50DD 1 208 180 CF06
                CMP     A, DP                  ; 50DF 1 208 180 92C2
                JLT     clamp_range_store             ; 50E1 1 208 180 CA05
                MOV     X2, DP                 ; 50E3 1 208 180 9279
clamp_range_lowside:     L       A, X2                  ; 50E5 1 208 180 41
                CLR     er0                    ; 50E6 1 208 180 4415
clamp_range_store:     ST      A, 00000h[X1]          ; 50E8 1 208 180 D00000
                L       A, er0                 ; 50EB 1 208 180 34
                ST      A, 00002h[X1]          ; 50EC 1 208 180 D00200
                RT                             ; 50EF 1 208 180 01
ignition_timing_calc_task_sub_load_er2:     MOV     er2, #00023h           ; 50F0 1 208 180 46982300
                MOV     er3, #003ffh           ; 50F4 1 208 180 4798FF03
                SJ      clamp_to_35_512_cmp_acc             ; 50F8 1 208 180 CB08
clamp_to_35_512:     MOV     er2, #00023h           ; 50FA 1 208 180 46982300
                MOV     er3, #00200h           ; 50FE 1 208 180 47980002
clamp_to_35_512_cmp_acc:     CMP     A, er2                 ; 5102 1 208 180 4A
                JLT     load_er0_result             ; 5103 1 208 180 CA05
                CMP     A, er3                 ; 5105 1 208 180 4B
                JLE     load_er0_result_store_tbl_x1             ; 5106 1 208 180 CF05
                MOV     er2, er3               ; 5108 1 208 180 474A
load_er0_result:     L       A, er2                 ; 510A 1 208 180 36
                CLR     er0                    ; 510B 1 208 180 4415
load_er0_result_store_tbl_x1:     ST      A, 00000h[X1]          ; 510D 1 208 180 D00000
                L       A, er0                 ; 5110 1 208 180 34
                ST      A, [DP]                ; 5111 1 208 180 D2
                RT                             ; 5112 1 208 180 01
sub37_clamp_to_er0:     SUB     A, #00025h             ; 5113 1 208 180 A62500
                JLT     sub37_clamp_to_er0_load_er0             ; 5116 1 208 180 CA03
                CMP     A, er0                 ; 5118 1 208 180 48
                JGE     sub37_clamp_to_er0_return             ; 5119 1 208 180 CD01
sub37_clamp_to_er0_load_er0:     L       A, er0                 ; 511B 1 208 180 34
sub37_clamp_to_er0_return:     RT                             ; 511C 1 208 180 01
add24_clamp_neg1:     ADD     A, #00018h             ; 511D 1 208 180 861800
                JGE     table_index_add_sub_0ce             ; 5120 1 208 180 CD03
                L       A, #0ffffh             ; 5122 1 208 180 67FFFF
table_index_add_sub_0ce:     ST      A, er3                 ; 5125 1 208 180 8B
                CLR     er1                    ; 5126 1 208 180 4515
                LC      A, [X1]                ; 5128 1 208 180 90A8
                ST      A, er0                 ; 512A 1 208 180 88
                L       A, 0b6h                ; 512B 1 208 180 E5B6
                SUB     A, er0                 ; 512D 1 208 180 28
                JLT     table_index_add_clamp_er3             ; 512E 1 208 180 CA07
                ST      A, er0                 ; 5130 1 208 180 88
                LC      A, 00004h[X1]          ; 5131 1 208 180 90A90400
                MUL                            ; 5135 1 208 180 9035
table_index_add_clamp_er3:     LC      A, 00002h[X1]          ; 5137 1 208 180 90A90200
                ADD     A, er1                 ; 513B 1 208 180 09
                CMP     A, er3                 ; 513C 1 208 180 4B
                JLT     table_index_add_clamp_er3_return             ; 513D 1 208 180 CA01
                L       A, er3                 ; 513F 1 208 180 37
table_index_add_clamp_er3_return:     RT                             ; 5140 1 208 180 01
; [CG] idle_helper2  @0x5141
; [CG] VERIFIED: MUL, then feeds into a shared bounds-check against X1/X2 register-supplied
; [CG] limits (gated by off(20Ch).0) rather than fixed presets.
idle_helper2:     MUL                            ; 5141 1 208 180 9035
                L       A, er1                 ; 5143 1 208 180 35
                SJ      mul_then_clamp_x1x2_2_if_ram20c_bit0_clr             ; 5144 1 208 180 CB0A
mul_then_clamp_x1x2_2_if_ram20c_bit0_clr:     JBR     off(0020ch).0, mul_then_clamp_x1x2_2_xchg_acc ; 5150 1 208 180 D80C0F
                ADD     A, er3                 ; 5153 1 208 180 0B
                JLT     idle_helper2_sc_path             ; 5154 1 208 180 CA08
idle_pi_clamp_compare:     CMP     A, X1                  ; 5156 1 208 180 90C2
                JLE     idle_pi_clamp_setcarry             ; 5158 1 208 180 CF0D
                CMP     X2, A                  ; 515A 1 208 180 91C1
                JGT     idle_helper2_store             ; 515C 1 208 180 C80B
idle_helper2_sc_path:     SC                             ; 515E 1 208 180 85
                L       A, X2                  ; 515F 1 208 180 41
                SJ      idle_helper2_store             ; 5160 1 208 180 CB07
mul_then_clamp_x1x2_2_xchg_acc:     XCHG    A, er3                 ; 5162 1 208 180 4710
                SUB     A, er3                 ; 5164 1 208 180 2B
                JGE     idle_pi_clamp_compare             ; 5165 1 208 180 CDEF
idle_pi_clamp_setcarry:     L       A, X1                  ; 5167 1 208 180 40
                SC                             ; 5168 1 208 180 85
idle_helper2_store:     ST      A, er3                 ; 5169 1 208 180 8B
                RT                             ; 516A 1 208 180 01
; [CG] stub_or_short_helper  @0x516B
; [CG] Called 7x; 4 instructions.
stub_or_short_helper:     L       A, #00700h             ; 516B 1 208 ??? 670007
                JBS     off(00216h).3, stub_or_short_helper_return ; 516E 1 208 ??? EB1603
                L       A, #00500h             ; 5171 1 208 ??? 670005
stub_or_short_helper_return:     RT                             ; 5174 1 208 ??? 01
idle_pi_clamp_helper:     CMP     off(0028ch), A         ; 5175 1 208 180 B48CC1
                JLT     idle_pi_clamp_low             ; 5178 1 208 180 CA07
                CMP     A, off(0028eh)         ; 517A 1 208 180 C78E
                JGE     idle_pi_clamp_return             ; 517C 1 208 180 CD02
                L       A, off(0028eh)         ; 517E 1 208 180 E48E
idle_pi_clamp_return:     RT                             ; 5180 1 208 180 01
idle_pi_clamp_low:     L       A, off(0028ch)         ; 5181 1 208 180 E48C
                RT                             ; 5183 1 208 180 01
; [CG] weighted_sum_2term_trim  @0x5184
; [CG] VERIFIED: computes two products (r6*A and r7*X1), conditionally accumulates them into
; [CG] a running total at off(29Ah) gated by PSWL.4, calling clamp_0_to_3ff to bound the
; [CG] running total. A two-term weighted-blend accumulator.
weighted_sum_2term_trim:     MOV     X1, A                  ; 5184 1 208 180 50
                CLRB    r0                     ; 5185 1 208 180 2015
                MOVB    r1, r6                 ; 5187 1 208 180 2649
                MUL                            ; 5189 1 208 180 9035
                MOV     er2, er1               ; 518B 1 208 180 454A
                L       A, X1                  ; 518D 1 208 180 40
                MOVB    r1, r7                 ; 518E 1 208 180 2749
                MUL                            ; 5190 1 208 180 9035
                L       A, off(0029ah)         ; 5192 1 208 180 E49A
                MB      C, PSWL.4              ; 5194 1 208 180 A32C
                JLT     weighted_sum_2term_trim_sub_acc             ; 5196 1 208 180 CA09
                ADD     A, er1                 ; 5198 1 208 180 09
                CAL     clamp_0_to_3ff             ; 5199 1 208 180 32AC51
                ST      A, off(0029ah)         ; 519C 1 208 180 D49A
                ADD     A, er2                 ; 519E 1 208 180 0A
                SJ      weighted_sum_2term_trim_call_clamp_0_to_3ff             ; 519F 1 208 180 CB07
weighted_sum_2term_trim_sub_acc:     SUB     A, er1                 ; 51A1 1 208 180 29
                CAL     clamp_0_to_3ff             ; 51A2 1 208 180 32AC51
                ST      A, off(0029ah)         ; 51A5 1 208 180 D49A
                SUB     A, er2                 ; 51A7 1 208 180 2A
weighted_sum_2term_trim_call_clamp_0_to_3ff:     CAL     clamp_0_to_3ff             ; 51A8 1 208 180 32AC51
                RT                             ; 51AB 1 208 180 01
; [CG] clamp_0_to_3ff  @0x51AC
; [CG] VERIFIED: clamps A to the range [0, 0x3FF] (1023). Called from
; [CG] weighted_sum_2term_trim.
clamp_0_to_3ff:     CLR     er0                    ; 51AC 1 208 180 4415
                JLE     clamp_0_to_3ff_load_er0             ; 51AE 1 208 180 CF07
                MOV     er0, #003ffh           ; 51B0 1 208 180 4498FF03
                CMP     A, er0                 ; 51B4 1 208 180 48
                JLT     clamp_0_to_3ff_return             ; 51B5 1 208 180 CA01
clamp_0_to_3ff_load_er0:     L       A, er0                 ; 51B7 1 208 180 34
clamp_0_to_3ff_return:     RT                             ; 51B8 1 208 180 01
port_debounce_helper:     MOV     DP, #03f00h            ; 51E4 0 208 180 62003F
                LB      A, #090h               ; 51E7 0 208 180 7790
                STB     A, [DP]                ; 51E9 0 208 180 D2
                MOV     DP, #01f00h            ; 51EA 0 208 180 62001F
                LB      A, P0                  ; 51ED 0 208 180 F520
                STB     A, [DP]                ; 51EF 0 208 180 D2
                MOV     DP, #02f00h            ; 51F0 0 208 180 62002F
                LB      A, P1                  ; 51F3 0 208 180 F522
                STB     A, [DP]                ; 51F5 0 208 180 D2
                MOV     DP, #00f00h            ; 51F6 0 208 180 62000F
                LB      A, [DP]                ; 51F9 0 208 180 F2
                XORB    A, #038h               ; 51FA 0 208 180 F638
                STB     A, off(00210h)         ; 51FC 0 208 180 D410
                STB     A, (00110h-00180h)[USP] ; 51FE 0 208 180 D390
                SB      off(00230h).2          ; 5200 0 208 180 C4301A
                RT                             ; 5203 0 208 180 01
decrement_timer_array:     AND     IE, #002a0h            ; 5204 1 208 180 B51AD0A002
                RB      PSWH.0                 ; 5209 1 208 180 A208
                LB      A, 00000h[X1]          ; 520B 0 208 180 F00000
                JEQ     decrement_timer_array_next             ; 520E 0 208 180 C904
                DECB    00000h[X1]             ; 5210 0 208 180 C0000017
decrement_timer_array_next:     SB      PSWH.0                 ; 5214 0 208 180 A218
                L       A, 0f2h                ; 5216 1 208 180 E5F2
                ST      A, IE                  ; 5218 1 208 180 D51A
                INC     X1                     ; 521A 1 208 180 70
                JRNZ    DP, decrement_timer_array         ; 521B 1 208 180 30E7
                RT                             ; 521D 1 208 180 01
ResetWatchDog:     LB      A, #03ch               ; 521E 0 208 180 773C
                STB     A, WDT                 ; 5220 0 208 180 D511
                SWAPB                          ; 5222 0 208 180 83
                STB     A, WDT                 ; 5223 0 208 180 D511
                MB      C, 09fh.1              ; 5225 0 208 180 C59F29
                JLT     resetwatchdog_return             ; 5228 0 208 180 CA04
                XORB    P2, #010h              ; 522A 0 208 180 C524F010
resetwatchdog_return:     RT                             ; 522E 0 208 180 01
ect_step_helper:     ADDB    A, #005h               ; 522F 0 208 180 8605
                JGE     ect_step_range_check             ; 5231 0 208 180 CD02
                LB      A, #0ffh               ; 5233 0 208 180 77FF
ect_step_range_check:     JBS     off(00217h).4, ect_step_clamp_default ; 5235 0 208 180 EC1707
                JBR     off(00230h).3, ect_step_clamp_default ; 5238 0 208 180 DB3004
                CMPB    A, off(002a6h)         ; 523B 0 208 180 C7A6
                JGE     ect_step_return             ; 523D 0 208 180 CD08
ect_step_clamp_default:     MOVB    r0, #042h              ; 523F 0 208 180 9842
                CMPB    A, r0                  ; 5241 0 208 180 48
                JGE     ect_step_store             ; 5242 0 208 180 CD01
                LB      A, r0                  ; 5244 0 208 180 78
ect_step_store:     STB     A, off(002a6h)         ; 5245 0 208 180 D4A6
ect_step_return:     RT                             ; 5247 0 208 180 01
ect_smooth_helper:     MOVB    r0, #002h              ; 5248 0 208 180 9802
                SUBB    A, [DP]                ; 524A 0 208 180 C2A2
                JGE     ect_smooth_sub             ; 524C 0 208 180 CD03
                ADDB    A, r0                  ; 524E 0 208 180 08
                SJ      ect_smooth_store             ; 524F 0 208 180 CB01
ect_smooth_sub:     SUBB    A, r0                  ; 5251 0 208 180 28
ect_smooth_store:     JGE     ect_smooth_add_store             ; 5252 0 208 180 CD01
                CLRB    A                      ; 5254 0 208 180 FA
ect_smooth_add_store:     ADDB    A, [DP]                ; 5255 0 208 180 C282
                STB     A, [DP]                ; 5257 0 208 180 D2
                RT                             ; 5258 0 208 180 01
crank_edge_helper:     L       A, off(0011ch)         ; 5259 1 108 280 E41C
                ST      A, (0021ch-00280h)[USP] ; 525B 1 108 280 D39C
                L       A, off(0011eh)         ; 525D 1 108 280 E41E
                ST      A, (0021eh-00280h)[USP] ; 525F 1 108 280 D39E
                RT                             ; 5261 1 108 280 01
; [CG] refresh_engine_flags_snapshot  @0x5262
; [CG] VERIFIED: copies 5 consecutive words from a USP-relative stack frame (0x212-0x21A)
; [CG] into fixed RAM locations 0x112-0x11A. A pure register/stack snapshot copier, no
; [CG] computation.
refresh_engine_flags_snapshot:
; (skeleton: no fault-flag snapshot to copy)
; (skeleton: no fault-flag snapshot to copy)
; (skeleton: no fault-flag snapshot to copy)
                L       A, (00216h-00280h)[USP] ; 526A 1 108 280 E396
                ST      A, off(00116h)         ; 526C 1 108 280 D416
                L       A, (00218h-00280h)[USP] ; 526E 1 108 280 E398
                ST      A, off(00118h)         ; 5270 1 108 280 D418
                L       A, (0021ah-00280h)[USP] ; 5272 1 108 280 E39A
                ST      A, off(0011ah)         ; 5274 1 108 280 D41A
                RT                             ; 5276 1 108 280 01
; [CG] timer_or_counter_helper  @0x5277
; [CG] Most-called CAL in the ROM (17 sites).
timer_or_counter_helper:     LB      A, r0                  ; 5277 0 208 180 78
                MBR     C, [DP]                ; 5278 0 208 180 C221
                LC      A, [X1]                ; 527A 0 208 180 90A8
                JLT     timer_or_counter_helper_load_carry_pswl_bit4             ; 527C 0 208 180 CA02
                LB      A, ACCH                ; 527E 0 208 180 F507
timer_or_counter_helper_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 5280 0 208 180 A32C
                JLT     timer_or_counter_helper_cmp_r2             ; 5282 0 208 180 CA03
                CMPB    A, r2                  ; 5284 0 208 180 4A
                SJ      timer_or_counter_helper_load_r0             ; 5285 0 208 180 CB02
timer_or_counter_helper_cmp_r2:     CMPB    r2, A                  ; 5287 0 208 180 22C1
timer_or_counter_helper_load_r0:     LB      A, r0                  ; 5289 0 208 180 78
                MBR     [DP], C                ; 528A 0 208 180 C220
                INC     X1                     ; 528C 0 208 180 70
                INC     X1                     ; 528D 0 208 180 70
                INCB    r0                     ; 528E 0 208 180 A8
                DECB    r1                     ; 528F 0 208 180 B9
                JNE     timer_or_counter_helper             ; 5290 0 208 180 CEE5
                RT                             ; 5292 0 208 180 01
selftest_regbank_verify:     MOV     X2, A                  ; 5293 1 200 ??? 51
                SB      off(00230h).7          ; 5294 1 200 ??? C4301F
                AND     IE, #002a0h            ; 5297 1 200 ??? B51AD0A002
                RB      PSWH.0                 ; 529C 1 200 ??? A208
                XCHG    A, 00084h[X1]          ; 529E 1 200 ??? B0840010
                XCHG    A, 00084h[X1]          ; 52A2 1 200 ??? B0840010
                ST      A, er3                 ; 52A6 1 200 ??? 8B
                SB      PSWH.0                 ; 52A7 1 200 ??? A218
                L       A, 0f2h                ; 52A9 1 200 ??? E5F2
                ST      A, IE                  ; 52AB 1 200 ??? D51A
                RB      off(00230h).7          ; 52AD 1 200 ??? C4300F
                L       A, er3                 ; 52B0 1 200 ??? 37
                CMP     A, X2                  ; 52B1 1 200 ??? 91C2
                JEQ     selftest_regbank_verify_return             ; 52B3 1 200 ??? C905
                MOVB    0ebh, #042h            ; 52B5 1 200 ??? C5EB9842
                BRK                            ; 52B9 1 200 ??? FF
selftest_regbank_verify_return:     RT                             ; 52BA 1 200 ??? 01
idle_helper1:     JBR     off(00230h).3, idle_helper1_alt ; 52BB 1 208 180 DB3016
                AND     IE, #002a0h            ; 52BE 1 208 180 B51AD0A002
                RB      PSWH.0                 ; 52C3 1 208 180 A208
                L       A, TM2                 ; 52C5 1 208 180 E538
                SUB     A, off(00256h)         ; 52C7 1 208 180 A756
                CMP     A, #000c8h             ; 52C9 1 208 180 C6C800
                SB      PSWH.0                 ; 52CC 1 208 180 A218
                L       A, 0f2h                ; 52CE 1 208 180 E5F2
                ST      A, IE                  ; 52D0 1 208 180 D51A
                JLT     idle_helper1_return             ; 52D2 1 208 180 CA31
idle_helper1_alt:     RB      IRQH.4                 ; 52D4 1 208 180 C5190C
                JNE     idle_helper1_alt_load_p2             ; 52D7 1 208 180 CE05
                MOVB    0ebh, #04ah            ; 52D9 1 208 180 C5EB984A
                BRK                            ; 52DD 1 208 180 FF
idle_helper1_alt_load_p2:     LB      A, P2                  ; 52DE 0 208 180 F524
                SWAPB                          ; 52E0 0 208 180 83
                SRLB    A                      ; 52E1 0 208 180 63
                ANDB    A, #007h               ; 52E2 0 208 180 D607
                EXTND                          ; 52E4 1 208 180 F8
                MOV     X1, A                  ; 52E5 1 208 180 50
                LB      A, ADCR1H              ; 52E6 0 208 180 F563
                STB     A, 003c6h[X1]          ; 52E8 0 208 180 D0C603
                LB      A, ADCR0H              ; 52EB 0 208 180 F561
                STB     A, 003beh[X1]          ; 52ED 0 208 180 D0BE03
                AND     IE, #002a0h            ; 52F0 0 208 180 B51AD0A002
                RB      PSWH.0                 ; 52F5 0 208 180 A208
                ADDB    P2, #020h              ; 52F7 0 208 180 C5248020
                MOV     off(00256h), TM2       ; 52FB 0 208 180 B5387C56
                SB      PSWH.0                 ; 52FF 0 208 180 A218
                L       A, 0f2h                ; 5301 1 208 180 E5F2
                ST      A, IE                  ; 5303 1 208 180 D51A
idle_helper1_return:     RT                             ; 5305 1 208 180 01
selftest_reason_range_check:     CMPB    off(00236h), #00ah     ; 5306 0 208 180 C436C00A
                JLT     empty_stub_return             ; 530A 0 208 180 CA20
; [CG] selftest_reason_range_check_entry  @0x530C
; [CG] VERIFIED: identical body to selftest_reason_range_check; this is the direct-entry
; [CG] address used when the caller has already passed the off(236)>=0x0A precondition.
selftest_reason_range_check_entry:     MOV     DP, #003c9h            ; 530C 0 208 180 62C903
                LB      A, [DP]                ; 530F 0 208 180 F2
                CMPB    A, #0ffh               ; 5310 0 208 180 C6FF
                JGT     selftest_reason_range_check_entry_load_imm             ; 5312 0 208 180 C80C
                CMPB    A, #0fch               ; 5314 0 208 180 C6FC
                JGE     empty_stub_return             ; 5316 0 208 180 CD14
                CMPB    A, #088h               ; 5318 0 208 180 C688
                JGT     selftest_reason_range_check_entry_load_imm             ; 531A 0 208 180 C804
                CMPB    A, #078h               ; 531C 0 208 180 C678
                JGE     empty_stub_return             ; 531E 0 208 180 CD0C
selftest_reason_range_check_entry_load_imm:     LB      A, #049h               ; 5320 0 208 180 7749
                STB     A, 0e7h                ; 5322 0 208 180 D5E7
                DECB    0edh                   ; 5324 0 208 180 C5ED17
                JNE     empty_stub_return             ; 5327 0 208 180 CE03
                STB     A, 0ebh                ; 5329 0 208 180 D5EB
                BRK                            ; 532B 0 208 180 FF
empty_stub_return:     RT                             ; 532C 0 208 180 01
dwell_scale_helper:     MOVB    r0, #0bdh              ; 532D 1 200 180 98BD
                SLL     A                      ; 532F 1 200 180 53
                JLT     dwell_scale_default             ; 5330 1 200 180 CA0D
                SLL     A                      ; 5332 1 200 180 53
                JLT     dwell_scale_default             ; 5333 1 200 180 CA0A
                LB      A, ACCH                ; 5335 0 200 180 F507
                CMPB    A, r0                  ; 5337 0 200 180 48
                JGE     dwell_scale_default             ; 5338 0 200 180 CD05
                MOVB    r0, #00fh              ; 533A 0 200 180 980F
                CMPB    A, r0                  ; 533C 0 200 180 48
                JGE     dwell_scale_return             ; 533D 0 200 180 CD01
dwell_scale_default:     LB      A, r0                  ; 533F 0 200 180 78
dwell_scale_return:     RT                             ; 5340 0 200 180 01
; [CG] cfgvariant_ram_init_0x300  @0x5513
; [CG] VERIFIED: initializes RAM 0x300-0x31xx with default sentinel values (0x8000 words, a
; [CG] 0x7B byte, a 0x332 word). This is exactly the RAM range cfgvariant_checksum2_calc (0x5548)
; [CG] later checksums (0x320-0x34F), so this is that subsystem's initializer.
cfgvariant_ram_init_0x300:     L       A, #08000h             ; 5513 1 208 ??? 670080
                MOV     DP, #00300h            ; 5516 1 208 ??? 620003
                ST      A, [DP]                ; 5519 1 208 ??? D2
                MOV     DP, #00304h            ; 551A 1 208 ??? 620403
                ST      A, [DP]                ; 551D 1 208 ??? D2
                MOV     DP, #00308h            ; 551E 1 208 ??? 620803
                ST      A, [DP]                ; 5521 1 208 ??? D2
                CAL     stub_or_short_helper             ; 5522 1 208 ??? 326B51
                MOV     DP, #0030ch            ; 5525 1 208 ??? 620C03
                ST      A, [DP]                ; 5528 1 208 ??? D2
                CLRB    A                      ; 5529 0 208 ??? FA
                MOV     DP, #00310h            ; 552A 0 208 ??? 621003
                STB     A, [DP]                ; 552D 0 208 ??? D2
                LB      A, #07bh               ; 552E 0 208 ??? 777B
                INC     DP                     ; 5530 0 208 ??? 72
                STB     A, [DP]                ; 5531 0 208 ??? D2
                MOV     DP, #00312h            ; 5532 0 208 ??? 621203
                L       A, #00332h             ; 5535 1 208 ??? 673203
                ST      A, [DP]                ; 5538 1 208 ??? D2
                INC     DP                     ; 5539 1 208 ??? 72
                INC     DP                     ; 553A 1 208 ??? 72
                ST      A, [DP]                ; 553B 1 208 ??? D2
                CLR     A                      ; 553C 1 208 ??? F9
                INC     DP                     ; 553D 1 208 ??? 72
                INC     DP                     ; 553E 1 208 ??? 72
                ST      A, [DP]                ; 553F 1 208 ??? D2
                INC     DP                     ; 5540 1 208 ??? 72
                INC     DP                     ; 5541 1 208 ??? 72
                ST      A, [DP]                ; 5542 1 208 ??? D2
                MOVB    off(002f4h), #0ffh     ; 5543 1 208 ??? C4F498FF
                RT                             ; 5547 1 208 ??? 01
boot_completion_helper:     CLRB    A                      ; 5560 0 208 180 FA
                LCB     A, boot_completion_helper_tbl            ; 5561 0 208 180 909D0160
                SLLB    A                      ; 5565 0 208 180 53
                MB      off(00216h).4, C       ; 5566 0 208 180 C4163C
                LCB     A, boot_completion_helper_tbl_2            ; 5569 0 208 180 909D0260
                SLLB    A                      ; 556D 0 208 180 53
                MB      off(00227h).6, C       ; 556E 0 208 180 C4273E
                LCB     A, boot_completion_helper_tbl_3            ; 5571 0 208 180 909D0360
                SLLB    A                      ; 5575 0 208 180 53
                MB      off(00216h).6, C       ; 5576 0 208 180 C4163E
                LCB     A, boot_completion_helper_tbl_4            ; 5579 0 208 180 909D0460
                SLLB    A                      ; 557D 0 208 180 53
                MB      off(00227h).4, C       ; 557E 0 208 180 C4273C
                LCB     A, boot_completion_helper_tbl_5            ; 5581 0 208 180 909D0560
                SLLB    A                      ; 5585 0 208 180 53
                MB      off(00219h).1, C       ; 5586 0 208 180 C41939
                LCB     A, boot_completion_helper_tbl_6            ; 5589 0 208 180 909D0660
                SLLB    A                      ; 558D 0 208 180 53
                MB      off(00217h).3, C       ; 558E 0 208 180 C4173B
                LCB     A, boot_completion_helper_tbl_7            ; 5591 0 208 180 909D0760
                SLLB    A                      ; 5595 0 208 180 53
                MB      off(00227h).7, C       ; 5596 0 208 180 C4273F
                LCB     A, boot_completion_helper_tbl_8            ; 5599 0 208 180 909D0860
                SLLB    A                      ; 559D 0 208 180 53
                MB      off(00216h).1, C       ; 559E 0 208 180 C41639
                LCB     A, boot_completion_helper_tbl_9            ; 55A1 0 208 180 909D0960
                SLLB    A                      ; 55A5 0 208 180 53
                MB      off(00216h).7, C       ; 55A6 0 208 180 C4163F
                MOV     DP, #00354h            ; 55A9 0 208 180 625403
                MB      [DP].0, C              ; 55AC 0 208 180 C238
                LCB     A, boot_completion_helper_tbl_10            ; 55AE 0 208 180 909D0A60
                SLLB    A                      ; 55B2 0 208 180 53
                MB      off(00227h).1, C       ; 55B3 0 208 180 C42739
                MOV     DP, #003bfh            ; 55B6 0 208 180 62BF03
                LB      A, [DP]                ; 55B9 0 208 180 F2
                STB     A, r1                  ; 55BA 0 208 180 89
                J       boot_completion_helper_clear_carry_2             ; 55BB 0 208 180 03C976
boot_completion_helper_load_dp_ind:     LB      A, [DP]                ; 55BE 0 208 180 F2
                STB     A, r2                  ; 55BF 0 208 180 8A
                J       boot_completion_helper_rom_load_tbl_600f             ; 55C0 0 208 180 03E676
boot_completion_helper_load_r2:     LB      A, r2                  ; 55C5 0 208 180 7A
                CMPB    r0, #000h              ; 55C6 0 208 180 20C000
                JEQ     boot_completion_helper_sllb_acc             ; 55C9 0 208 180 C904
                LCB     A, boot_completion_helper_tbl_11            ; 55CB 0 208 180 909D1260
boot_completion_helper_sllb_acc:     SLLB    A                      ; 55CF 0 208 180 53
                MB      off(00216h).3, C       ; 55D0 0 208 180 C4163B
                CMPB    r0, #000h              ; 55D3 0 208 180 20C000
                JEQ     boot_completion_helper_clear_carry             ; 55D6 0 208 180 C907
                LCB     A, boot_completion_helper_tbl_12            ; 55D8 0 208 180 909D1360
                SLLB    A                      ; 55DC 0 208 180 53
                SJ      boot_flag_iabv_common             ; 55DD 0 208 180 CB0D
boot_completion_helper_clear_carry:     RC                             ; 55DF 0 208 180 95
                LCB     A, diag_snapshot_copy_loop_tbl            ; 55E0 0 208 180 909D0B60
                JNE     boot_flag_iabv_common             ; 55E4 0 208 180 CE06
                LB      A, r2                  ; 55E6 0 208 180 7A
                SLLB    A                      ; 55E7 0 208 180 53
                SLLB    A                      ; 55E8 0 208 180 53
                XORB    PSWH, #080h            ; 55E9 0 208 180 A2F080
boot_flag_iabv_common:     MB      off(00216h).2, C       ; 55EC 0 208 180 C4163A
                CMPB    r0, #000h              ; 55EF 0 208 180 20C000
                JEQ     boot_flag_baro_check             ; 55F2 0 208 180 C907
                LCB     A, boot_flag_iabv_common_tbl            ; 55F4 0 208 180 909D1460
                SLLB    A                      ; 55F8 0 208 180 53
                SJ      boot_flag_baro_common             ; 55F9 0 208 180 CB06
boot_flag_baro_check:     LB      A, r2                  ; 55FB 0 208 180 7A
                SLLB    A                      ; 55FC 0 208 180 53
                SLLB    A                      ; 55FD 0 208 180 53
                XORB    PSWH, #080h            ; 55FE 0 208 180 A2F080
boot_flag_baro_common:     MB      off(00216h).0, C       ; 5601 0 208 180 C41638
                CMPB    r0, #000h              ; 5604 0 208 180 20C000
                JEQ     boot_flag_baro_common_goto_5ee4             ; 5607 0 208 180 C907
                LCB     A, boot_flag_baro_common_tbl            ; 5609 0 208 180 909D1560
                SLLB    A                      ; 560D 0 208 180 53
                SJ      boot_flag_baro_common_store_carry_ram217_bit6             ; 560E 0 208 180 CB0C
boot_flag_baro_common_goto_5ee4:     J       boot_flag_baro_common_load_carry_ram216_bit2             ; 5610 0 208 180 03E45E
boot_flag_baro_common_if_eq_goto_561c:     JEQ     boot_flag_baro_common_store_carry_ram217_bit6             ; 5615 0 208 180 C905
                LB      A, r1                  ; 5617 0 208 180 79
                SLLB    A                      ; 5618 0 208 180 53
                XORB    PSWH, #080h            ; 5619 0 208 180 A2F080
boot_flag_baro_common_store_carry_ram217_bit6:     MB      off(00217h).6, C       ; 561C 0 208 180 C4173E
                CMPB    r0, #000h              ; 561F 0 208 180 20C000
                JEQ     boot_flag_baro_common_clear_carry             ; 5622 0 208 180 C907
                LCB     A, boot_flag_baro_common_tbl_2            ; 5624 0 208 180 909D1660
                SLLB    A                      ; 5628 0 208 180 53
                SJ      boot_flag_baro_common_store_carry_ram216_bit5             ; 5629 0 208 180 CB09
boot_flag_baro_common_clear_carry:     RC                             ; 562B 0 208 180 95
                LCB     A, diag_snapshot_copy_loop_tbl            ; 562C 0 208 180 909D0B60
                JNE     boot_flag_baro_common_store_carry_ram216_bit5             ; 5630 0 208 180 CE02
                LB      A, r1                  ; 5632 0 208 180 79
                SLLB    A                      ; 5633 0 208 180 53
boot_flag_baro_common_store_carry_ram216_bit5:     MB      off(00216h).5, C       ; 5634 0 208 180 C4163D
                CMPB    r0, #000h              ; 5637 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt             ; 563A 0 208 180 C907
                LCB     A, boot_flag_baro_common_tbl_3            ; 563C 0 208 180 909D1760
                SLLB    A                      ; 5640 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_pswl_bit4             ; 5641 0 208 180 CB03
boot_flag_gearpreset_alt:     LB      A, r1                  ; 5643 0 208 180 79
                SLLB    A                      ; 5644 0 208 180 53
                SLLB    A                      ; 5645 0 208 180 53
boot_flag_gearpreset_alt_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 5646 0 208 180 A33C
                CMPB    r0, #000h              ; 5648 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt_clear_carry             ; 564B 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_2            ; 564D 0 208 180 909D1860
                SLLB    A                      ; 5651 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_ram227_bit3             ; 5652 0 208 180 CB0A
boot_flag_gearpreset_alt_clear_carry:     RC                             ; 5654 0 208 180 95
                LCB     A, boot_flag_gearpreset_alt_tbl            ; 5655 0 208 180 909D0C60
                JEQ     boot_flag_gearpreset_alt_store_carry_ram227_bit3             ; 5659 0 208 180 C903
                MB      C, off(00216h).0       ; 565B 0 208 180 C41628
boot_flag_gearpreset_alt_store_carry_ram227_bit3:     MB      off(00227h).3, C       ; 565E 0 208 180 C4273B
                CMPB    r0, #000h              ; 5661 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt_load_carry_pswl_bit4             ; 5664 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_3            ; 5666 0 208 180 909D1960
                SLLB    A                      ; 566A 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_ram227_bit2             ; 566B 0 208 180 CB02
boot_flag_gearpreset_alt_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 566D 0 208 180 A32C
boot_flag_gearpreset_alt_store_carry_ram227_bit2:     MB      off(00227h).2, C       ; 566F 0 208 180 C4273A
                CMPB    r0, #000h              ; 5672 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt_goto_5953             ; 5675 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_4            ; 5677 0 208 180 909D1A60
                SLLB    A                      ; 567B 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 567C 0 208 180 CB1C
boot_flag_gearpreset_alt_goto_5953:     J       boot_flag_gearpreset_alt_clear_carry_2             ; 567E 0 208 180 035359
boot_flag_gearpreset_alt_if_ne_goto_5694:     JNE     boot_flag_gearpreset_alt_load_dp             ; 5682 0 208 180 CE10
                NOP                            ; 5684 0 208 180 00
                LCB     A, diag_snapshot_copy_loop_tbl            ; 5685 0 208 180 909D0B60
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 5689 0 208 180 C90F
                LCB     A, diag_snapshot_copy_loop_tbl_3            ; 568B 0 208 180 909D0E60
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 568F 0 208 180 C909
                JBR     off(00216h).0, boot_flag_gearpreset_alt_store_carry_ram219_bit4 ; 5691 0 208 180 D81606
boot_flag_gearpreset_alt_load_dp:     MOV     DP, #003c6h            ; 5694 0 208 180 62C603
                CMPB    [DP], #09ah            ; 5697 0 208 180 C2C09A
boot_flag_gearpreset_alt_store_carry_ram219_bit4:     MB      off(00219h).4, C       ; 569A 0 208 180 C4193C
                CMPB    r0, #000h              ; 569D 0 208 180 20C000
                JEQ     boot_flag_3cf_check             ; 56A0 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_5            ; 56A2 0 208 180 909D1B60
                SLLB    A                      ; 56A6 0 208 180 53
                SJ      boot_flag_final             ; 56A7 0 208 180 CB09
boot_flag_3cf_check:     MOV     DP, #003c3h            ; 56A9 0 208 180 62C303
                CMPB    [DP], #080h            ; 56AC 0 208 180 C2C080
                XORB    PSWH, #080h            ; 56AF 0 208 180 A2F080
boot_flag_final:     MOV     DP, #00354h            ; 56B2 0 208 180 625403
                RB      [DP].1                 ; 56B5 (skeleton: serial always off - stock copied the serial/diag mode into 354h.1 here)
                NOP                            ; 56B7 0 208 180 00
                NOP                            ; 56B8 0 208 180 00
                NOP                            ; 56B9 0 208 180 00
                RT                             ; 56BA 0 208 180 01
revlimit_table_select_if_ram217_bit5_set:     JBS     off(00217h).5, revlimit_table_select_load_stk_3 ; 56BB 1 208 180 ED1706
                J       revlimit_table_select_load_stk             ; 56C1 1 208 180 03513F
revlimit_table_select_load_stk_3:     MOVB    (00189h-00180h)[USP], #00ch ; 56C4 1 208 180 C309980C
revlimit_table_select_goto_3f98:     J       revlimit_table_select_and_ie             ; 56C8 1 208 180 03983F
tpsaccel_result_common_clear_acc:     CLRB    A                      ; 56CB 0 100 280 FA
                CMPB    0c1h, #02eh            ; 56CC 0 100 280 C5C1C02E
                JGE     tpsaccel_result_common_store_ram188             ; 56D0 0 100 280 CD02
                LB      A, #034h               ; 56D2 0 100 280 7734
tpsaccel_result_common_store_ram188:     STB     A, off(00188h)         ; 56D4 0 100 280 D488
                J       tpsaccel_ignitioncut_flag_copy             ; 56D6 0 100 280 036117
rpm_decel_store_0x14a_cmp_ram12d:     CMPB    off(0012dh), #0ffh     ; 56D9 1 100 280 C42DC0FF
                JGE     rpm_decel_store_0x14a_goto_idle_sub_result_store             ; 56DD 1 100 280 CD07
                CMPB    0c1h, #0ffh            ; 56DF 1 100 280 C5C1C0FF
                J       rpm_decel_store_0x14a_if_lt_goto_idle_sub_result_store             ; 56E3 1 100 280 03BE1E
rpm_decel_store_0x14a_goto_idle_sub_result_store:     J       idle_sub_result_store             ; 56E6 1 100 280 03D31E
battery_voltage_store_call_timer_or_counter_helper:     CAL     timer_or_counter_helper             ; 56E9 0 208 180 327752
                LB      A, #044h               ; 56EC 0 208 180 7744
                JBS     off(00225h).4, battery_voltage_store_cmp_r2 ; 56EE 0 208 180 EC2502
                LB      A, #030h               ; 56F1 0 208 180 7730
battery_voltage_store_cmp_r2:     CMPB    r2, A                  ; 56F3 0 208 180 22C1
                MB      off(00225h).4, C       ; 56F5 0 208 180 C4253C
                LB      A, #0b0h               ; 56F8 0 208 180 77B0
                JBS     off(00225h).5, battery_voltage_store_cmp_acc ; 56FA 0 208 180 ED2502
                LB      A, #0c0h               ; 56FD 0 208 180 77C0
battery_voltage_store_cmp_acc:     CMPB    A, 0c5h                ; 56FF 0 208 180 C5C5C2
                MB      off(00225h).5, C       ; 5702 0 208 180 C4253D
                J       battery_voltage_store_set_carry             ; 5705 0 208 180 03D52A
idle_gear_calc_start_load_dp_ind:     L       A, [DP]                ; 5708 1 208 180 E2
                ADD     A, off(00268h)         ; 5709 1 208 180 8768
                JGE     idle_gear_calc_start_goto_idle_gear_result_store             ; 570B 1 208 180 CD03
                L       A, #0ffffh             ; 570D 1 208 180 67FFFF
idle_gear_calc_start_goto_idle_gear_result_store:     J       idle_gear_result_store             ; 5710 1 208 180 03132F
idle_gear_mul_apply_rol_acc:     ROL     A                      ; 5713 1 208 180 33
                JLT     idle_gear_mul_apply_goto_idle_gear_clamp             ; 5714 1 208 180 CA07
                ADD     A, off(00268h)         ; 5716 1 208 180 8768
                JLT     idle_gear_mul_apply_goto_idle_gear_clamp             ; 5718 1 208 180 CA03
                J       idle_gear_mul_apply_add_acc             ; 571A 1 208 180 03062F
idle_gear_mul_apply_goto_idle_gear_clamp:     J       idle_gear_clamp             ; 571D 1 208 180 030A2F
idle_gear_result_store_rol_acc:     ROL     A                      ; 5720 1 208 180 33
                JLT     idle_gear_result_store_goto_idle_gear2_clamp             ; 5721 1 208 180 CA07
                ADD     A, off(00268h)         ; 5723 1 208 180 8768
                JLT     idle_gear_result_store_goto_idle_gear2_clamp             ; 5725 1 208 180 CA03
                J       idle_gear_result_store_add_acc             ; 5727 1 208 180 031D2F
idle_gear_result_store_goto_idle_gear2_clamp:     J       idle_gear2_clamp             ; 572A 1 208 180 03222F
idle_vcal5_call3_if_ram21a_bit0_clr:     JBR     off(0021ah).0, idle_vcal5_call3_goto_30c2 ; 572D 1 208 180 D81A0E
                MB      C, off(00225h).5       ; 5730 1 208 180 C4252D
                JBR     off(00217h).6, idle_vcal5_call3_if_lt_goto_573e ; 5733 1 208 180 DE1703
                MB      C, off(00225h).4       ; 5736 1 208 180 C4252C
idle_vcal5_call3_if_lt_goto_573e:     JLT     idle_vcal5_call3_goto_30c2             ; 5739 1 208 180 CA03
                J       idle_vcal5_call3_goto_5b4f             ; 573B 1 208 180 036230
idle_vcal5_call3_goto_30c2:     J       idle_stall_check2_if_ram217_bit5_clr             ; 573E 1 208 180 03C230
idle_stall_diff_calc_load_ram284:     L       A, off(00284h)         ; 5741 1 208 180 E484
                SUB     A, off(00276h)         ; 5743 1 208 180 A776
                JGE     idle_stall_diff_calc_sub_acc             ; 5745 1 208 180 CD03
                J       idle_stall_diff_calc_clear_acc             ; 5747 1 208 180 03BB30
idle_stall_diff_calc_sub_acc:     SUB     A, off(00268h)         ; 574A 1 208 180 A768
                J       idle_stall_diff_calc_if_ge_goto_30bc             ; 574C 1 208 180 03B930
revlimit_table_select_store_r2:     STB     A, r2                  ; 575D 0 208 180 8A
                MOV     X1, #revlimit_table_select_tbl_7          ; 575E 0 208 180 605E60
                J       revlimit_table_select_vcal_0             ; 5761 0 208 180 030040
revlimit_table_select_store_r2_2:     STB     A, r2                  ; 5764 0 208 180 8A
                MOV     X1, #revlimit_table_select_tbl_12          ; 5765 0 208 180 609762
                J       revlimit_table_select_vcal_0_2             ; 5768 0 208 180 031740
nmi_poll_p4_1_load_p2:     MOVB    P2, #0ffh              ; 576B 1 208 ??? C52498FF
                RB      TCON0.2                ; 576F 1 208 ??? C5400A
                SB      TCON0.2                ; 5772 1 208 ??? C5401A
                CLRB    A                      ; 5775 0 208 ??? FA
                STB     A, ADSCAN              ; 5776 0 208 ??? D558
                J       nmi_poll_p4_1_store_adsel             ; 5778 0 208 ??? 035800
                DB  0F9h,07Eh,032h,0B9h,051h,003h,099h,023h ; 577B
idle_target_correction_done:     XCHGB   A, r4                  ; 578F 0 208 180 2410
                SUBB    r4, A                  ; 5791 0 208 180 24A1
                JGT     idle_target_correction_done_clear_acc_2             ; 5793 0 208 180 C803
                J       idle_target_correction_done_clear_acc             ; 5795 0 208 180 03D82B
idle_target_correction_done_clear_acc_2:     CLR     A                      ; 5798 1 208 180 F9
                CAL     injtimer_bank_calc3             ; 5799 1 208 180 32E54E
                J       to_idle_step_condition_dispatch             ; 579C 1 208 180 03DA2B
ignition_timing_calc_task_if_ge_goto_57a2:     JGE     ignition_timing_calc_task_cmp_acc_7             ; 579F 0 208 180 CD01
                CLRB    A                      ; 57A1 0 208 180 FA
ignition_timing_calc_task_cmp_acc_7:     CMPB    A, r5                  ; 57A2 0 208 180 4D
                MB      off(0022eh).4, C       ; 57A3 0 208 180 C42E3C
                J       ignition_timing_calc_task_load_ram0b4             ; 57A6 0 208 180 030532
ignition_timing_calc_task_if_ge_goto_57ac:     JGE     ignition_timing_calc_task_cmp_acc_8             ; 57A9 0 208 180 CD01
                CLRB    A                      ; 57AB 0 208 180 FA
ignition_timing_calc_task_cmp_acc_8:     CMPB    A, r5                  ; 57AC 0 208 180 4D
                MB      off(0022eh).6, C       ; 57AD 0 208 180 C42E3E
                J       ignition_timing_calc_task_load_ram0b4_2             ; 57B0 0 208 180 032532
cfg_selector3_dispatch_cmp_ram280:     CMP     off(00280h), #00700h   ; 5802 0 208 180 B480C00007
                JGE     cfg_selector3_dispatch_goto_2b5a             ; 5807 0 208 180 CD04
cfg_selector3_dispatch_cmp_acc:     CMPB    A, r1                  ; 5809 0 208 180 49
                J       cfg_selector3_dispatch_if_ge_goto_idle_ectvs_result3             ; 580A 0 208 180 03722B
cfg_selector3_dispatch_goto_2b5a:     J       idle_ectvs_result1_load_r1             ; 580D 0 208 180 035A2B
overrev_hardcap_compare_load_carry_ram0a0_bit1:     MB      C, 0a0h.1              ; 5810 0 200 180 C5A029
                JGE     overrev_hardcap_compare_nop_acc             ; 5813 0 200 180 CD03
                MOV     X1, #overrev_hardcap_compare_tbl          ; 5815 0 200 180 606958
overrev_hardcap_compare_nop_acc:     NOP                            ; 5818 0 200 180 00
                NOP                            ; 5819 0 200 180 00
                NOP                            ; 581A 0 200 180 00
                JBR     off(00223h).4, overrev_hardcap_compare_load_ram236 ; 581B 0 200 180 DC2304
                ADD     X1, #0002ch            ; 581E 0 200 180 90802C00
overrev_hardcap_compare_load_ram236:     LB      A, off(00236h)         ; 5822 0 200 180 F436
                VCAL    0                      ; 5824 0 200 180 10
                J       knockretard2_store             ; 5825 0 200 180 039D0C
to_vtec_debounce_store_tbl:       DB  04Eh,04Eh,04Eh,04Eh,063h,063h,063h,063h ; 584D
                DB  077h,077h,077h,077h,08Bh,08Bh,08Bh,08Bh ; 5855
                DB  0A0h,0A0h,0A0h,0A0h,0B4h,0B4h,0B4h,0B4h ; 585D
                DB  0C9h,0C9h,0C9h,0C9h ; 5865
overrev_hardcap_compare_tbl:       DB  0FFh,017h,0F8h,017h,0F0h,031h,0E8h,037h ; 5869
                DB  0E0h,035h,0D8h,03Ah,0D0h,042h,0C8h,042h ; 5871
                DB  0C0h,042h,0B0h,042h,0A0h,03Eh,098h,03Ch ; 5879
                DB  090h,03Ch,088h,037h,080h,038h,070h,033h ; 5881
                DB  060h,031h,050h,028h,040h,000h,000h,000h ; 5889
                DB  000h,000h,000h,000h,0FFh,017h,0F8h,017h ; 5891
                DB  0F0h,024h,0E8h,02Ah,0E0h,029h,0D8h,02Fh ; 5899
                DB  0D0h,03Ah,0C8h,03Ah,0C0h,03Ah,0B0h,024h ; 58A1
                DB  0A0h,015h,098h,013h,090h,011h,088h,008h ; 58A9
                DB  080h,000h,070h,000h,060h,000h,050h,000h ; 58B1
                DB  040h,000h,000h,000h,000h,000h,000h,000h ; 58B9
dwell_scale_shift_if_ram21d_bit4_clr:     JBR     off(0021dh).4, dwell_scale_shift_call_knock_244_helper ; 58C1 0 200 180 DC1D04
                ADD     DP, #00014h            ; 58C4 0 200 180 92801400
dwell_scale_shift_call_knock_244_helper:     CAL     knock_244_helper             ; 58C8 0 200 180 327950
                J       dwell_scale_shift_store_ram249             ; 58CB 0 200 180 03C80E
dwell_scale_shift_tbl:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 58E6
                DB  000h,000h,000h,000h,000h,000h,020h,03Ah,063h,07Ah ; 58F0
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 58FA
                DB  01Dh,024h,01Dh,000h,020h,039h,04Ah,066h,084h,088h ; 5904
ve_result_flag_store_if_ge_goto_5914:     JGE     ve_result_flag_store_goto_165a             ; 590E 0 100 280 CD04
                CLRB    A                      ; 5910 0 100 280 FA
                J       ve_result_flag_store_load_r4             ; 5911 0 100 280 036216
ve_result_flag_store_goto_165a:     J       ve_result_flag_store_cmp_acch             ; 5914 0 100 280 035A16
idle_sub_result_store_store_tbl_x1:     ST      A, 003b4h[X1]          ; 5917 1 100 280 D0B403
                ST      A, 003d4h[X1]          ; 591A 1 100 280 D0D403
                J       idle_sub_result_store_goto_1fe6             ; 591D 1 100 280 03E91E
injtimer_bank_a_calc_if_ram11c_bit5_clr:     JBR     off(0011ch).5, injtimer_bank_a_store ; 5920 1 100 280 DD1C01
                CLR     A                      ; 5923 1 100 280 F9
injtimer_bank_a_store:     MOV     DP, #003d4h            ; 5924 1 100 280 62D403
                ST      A, [DP]                ; 5927 1 100 280 D2
                L       A, er3                 ; 5928 1 100 280 37
                MOV     DP, #003ach            ; 5929 1 100 280 62AC03
                J       injtimer_bank_a_store_load_er0             ; 592C 1 100 280 034C1F
knock_result_store_xchgb_acc:     XCHGB   A, r0                  ; 592F 0 208 180 2010
                JLT     knock_result_store_goto_40c9             ; 5931 0 208 180 CA01
                CLRB    A                      ; 5933 0 208 180 FA
knock_result_store_goto_40c9:     J       knock_result_store_store_stk             ; 5934 0 208 180 03C940
boot_flag_gearpreset_alt_clear_carry_2:     RC                             ; 5953 0 208 180 95
                JBS     off(00217h).6, boot_flag_gearpreset_alt_goto_569a ; 5954 0 208 180 EE1707
                LCB     A, diag_snapshot_copy_loop_tbl_2            ; 5957 0 208 180 909D0D60
                J       boot_flag_gearpreset_alt_if_ne_goto_5694             ; 595B 0 208 180 038256
boot_flag_gearpreset_alt_goto_569a:     J       boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 595E 0 208 180 039A56
overrev_hardcap_compare_load_imm_2:     LB      A, #008h               ; 596D 0 200 180 7708
                JBS     off(00223h).4, overrev_hardcap_compare_cmp_acc_2 ; 596F 0 200 180 EC2302
                LB      A, #015h               ; 5972 0 200 180 7715
overrev_hardcap_compare_cmp_acc_2:     CMPB    A, off(00243h)         ; 5974 0 200 180 C743
                MB      off(00223h).4, C       ; 5976 0 200 180 C4233C
                CLRB    A                      ; 5979 0 200 180 FA
                CMPB    (001cah-00180h)[USP], #001h ; 597A 0 200 180 C34AC001
                J       overrev_hardcap_compare_if_ne_goto_0c95             ; 597E 0 200 180 038D0C
tpsaccel_ignitioncut_flag_copy_if_ge_goto_5984:     JGE     tpsaccel_ignitioncut_flag_copy_cmp_acc             ; 5981 0 100 280 CD01
                CLRB    A                      ; 5983 0 100 280 FA
tpsaccel_ignitioncut_flag_copy_cmp_acc:     CMPB    A, off(0012ch)         ; 5984 0 100 280 C72C
                J       tpsaccel_ignitioncut_flag_copy_store_carry_ram126_bit0             ; 5986 0 100 280 037917
tps_hysteresis_store:     MB      off(00126h).7, C       ; 5989 0 100 280 C4263F
                STB     A, r0                  ; 598C 0 100 280 88
                LB      A, #047h               ; 598D 0 100 280 7747
                JBS     off(00127h).7, tps_hysteresis_flag2 ; 598F 0 100 280 EF2702
                LB      A, #05ah               ; 5992 0 100 280 775A
tps_hysteresis_flag2:     CMPB    A, r0                  ; 5994 0 100 280 48
                MB      off(00127h).7, C       ; 5995 0 100 280 C4273F
                LB      A, r0                  ; 5998 0 100 280 78
                JLT     tps_hysteresis_flag2_goto_rpm_threshold_adjust             ; 5999 0 100 280 CA06
                JBS     off(00126h).7, tps_hysteresis_flag2_goto_rpm_threshold_adjust ; 599B 0 100 280 EF2603
                J       tps_hysteresis_flag2_subb_acc             ; 599E 0 100 280 03A117
tps_hysteresis_flag2_goto_rpm_threshold_adjust:     J       rpm_threshold_adjust             ; 59A1 0 100 280 03A617
fuelcut_tps_recheck_load_ram0a9:     LB      A, 0a9h                ; 59A4 0 100 280 F5A9
                CMPB    A, #060h               ; 59A6 0 100 280 C660
                JBS     off(00116h).3, fuelcut_tps_recheck_goto_to_fuelcut_clear_active_flag ; 59A8 0 100 280 EB1602
                CMPB    A, #010h               ; 59AB 0 100 280 C610
fuelcut_tps_recheck_goto_to_fuelcut_clear_active_flag:     J       to_fuelcut_clear_active_flag             ; 59AD 0 100 280 037418
rpm_decel_counter_check_load_r1:     MOVB    r1, off(0017eh)        ; 59B0 1 100 280 C47E49
                CMPB    r1, #000h              ; 59B3 1 100 280 21C000
                J       rpm_decel_counter_check_if_eq_goto_rpm_decel_diff_check2             ; 59B6 1 100 280 036A1E
idle_step_flag_store:     ST      A, off(0026eh)         ; 59B9 1 208 180 D46E
                L       A, DP                  ; 59BB 1 208 180 42
                JBS     off(0021ah).0, idle_step_flag_store_store_ram258 ; 59BC 1 208 180 E81A09
                LB      A, 0c1h                ; 59BF 0 208 180 F5C1
                MOV     X1, #idle_step_flag_store_tbl          ; 59C1 0 208 180 60FA66
                VCAL    1                      ; 59C4 0 208 180 11
                MOV     X2, #idle_step_flag_store_tbl_2          ; 59C5 0 208 180 612B67
idle_step_flag_store_store_ram258:     STB     A, off(00258h)         ; 59C8 0 208 180 D458
                MOV     X1, X2                 ; 59CA 0 208 180 9178
                J       idle_step_flag_store_load_ram0c1             ; 59CC 0 208 180 03DE2B
idle_flag_gate_set_ram22b_bit1:     SB      off(0022bh).1          ; 59CF 0 208 180 C42B19
                RB      PSWL.4                 ; 59D2 0 208 180 A30C
                J       idle_flag_gate_if_ram228_bit5_set             ; 59D4 0 208 180 03942F
idle_flag_gate_set_pswl_bit4:     SB      PSWL.4                 ; 59D7 0 208 180 A31C
                JBR     off(00228h).0, idle_flag_gate_goto_2fbd ; 59D9 0 208 180 D82803
                J       idle_mode_gate5             ; 59DC 0 208 180 03AA2F
idle_flag_gate_goto_2fbd:     J       idle_mode_gate6_load_ram278             ; 59DF 0 208 180 03BD2F
idle_mode_gate6_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_mode_gate6_clear_er3 ; 59E2 1 208 180 DB1609
                JBS     off(00211h).5, idle_mode_gate6_clear_er3 ; 59E5 1 208 180 ED1106
                JBR     off(00228h).3, idle_mode_gate6_clear_er3 ; 59E8 1 208 180 DB2803
                J       idle_mode_gate6_store_er3             ; 59EB 1 208 180 03CD2F
idle_mode_gate6_clear_er3:     CLR     er3                    ; 59EE 1 208 180 4715
                MB      C, PSWL.4              ; 59F0 1 208 180 A32C
                JGE     idle_mode_gate6_vcal_6             ; 59F2 1 208 180 CD0E
                J       idle_mode_gate6_cmp_ram2dc             ; 59F4 1 208 180 03E05D
idle_mode_gate6_if_ne_goto_5a02:     JNE     idle_mode_gate6_vcal_6             ; 59F8 1 208 180 CE08
idle_mode_gate6_goto_5def:     J       idle_mode_gate6_load_x2             ; 59FA 1 208 180 03EF5D
idle_mode_gate6_load_ram2dc:     MOVB    off(002dch), #014h     ; 59FE 1 208 180 C4DC9814
idle_mode_gate6_vcal_6:     VCAL    6                      ; 5A02 1 208 180 16
idle_mode_gate5_store_er3:     ST      A, er3                 ; 5A03 1 208 180 8B
                MOV     DP, #0030ch            ; 5A04 1 208 180 620C03
                L       A, [DP]                ; 5A07 1 208 180 E2
                J       idle_mode_gate5_vcal_6             ; 5A08 1 208 180 03D12F
idle_stall_check2_if_ge_goto_5a16:     JGE     idle_stall_check2_goto_30c2             ; 5A0B 1 208 180 CD09
                LB      A, off(002dch)         ; 5A0D 0 208 180 F4DC
                JNE     idle_stall_check2_goto_30c2             ; 5A0F 0 208 180 CE05
                LB      A, 0a4h                ; 5A11 0 208 180 F5A4
                J       idle_stall_check2_load_x1             ; 5A13 0 208 180 038C30
idle_stall_check2_goto_30c2:     J       idle_stall_check2_if_ram217_bit5_clr             ; 5A16 1 208 180 03C230
select_dp_3d9_3d6_flag_222_6:     LB      A, [DP]                ; 5A19 0 208 180 F2
                CMPB    A, #0fah               ; 5A1A 0 208 180 C6FA
                JGE     select_dp_3d9_3d6_flag_222_6_goto_div_scale_default             ; 5A1C 0 208 180 CD05
                SUBB    A, #007h               ; 5A1E 0 208 180 A607
                J       select_dp_3d9_3d6_flag_222_6_if_ge_goto_div_scale_calc1             ; 5A20 0 208 180 03743E
select_dp_3d9_3d6_flag_222_6_goto_div_scale_default:     J       div_scale_default             ; 5A23 0 208 180 038F3E
                DB  0C4h,02Ah,02Bh,0D9h,027h,003h,0C4h,026h ; 5A26
                DB  02Ch,0CAh,003h,003h,080h,02Bh,003h,05Ah ; 5A2E
                DB  02Bh ; 5A36
fuelcut_output_flags_load_ram0c4:     LB      A, 0c4h                ; 5A37 0 100 280 F5C4
                CMPB    A, #082h               ; 5A39 0 100 280 C682
                JBS     off(00129h).5, tps_hysteresis_reentry ; 5A3B 0 100 280 ED2902
                CMPB    A, #07ah               ; 5A3E 0 100 280 C67A
tps_hysteresis_reentry:     MB      off(00129h).5, C       ; 5A40 0 100 280 C4293D
                ANDB    PSWL, #0cfh            ; 5A43 0 100 280 A3D0CF
                J       tps_hysteresis_reentry_load_r2             ; 5A46 0 100 280 03D018
postig_threshold_check2_if_ram117_bit6_clr:     JBR     off(00117h).6, postig_rpm_compare ; 5A49 0 100 280 DE1712
                MOVB    r0, #032h              ; 5A4C 0 100 280 9832
                JBS     off(00123h).5, postig_threshold_check3 ; 5A4E 0 100 280 ED2302
                MOVB    r0, #050h              ; 5A51 0 100 280 9850
postig_threshold_check3:     CMPB    A, r0                  ; 5A53 0 100 280 48
                JGE     postig_rpm_compare             ; 5A54 0 100 280 CD08
                JBS     off(00129h).5, postig_rpm_compare ; 5A56 0 100 280 ED2905
                SUBB    A, #00ah               ; 5A59 0 100 280 A60A
                JGE     postig_rpm_compare             ; 5A5B 0 100 280 CD01
                CLRB    A                      ; 5A5D 0 100 280 FA
postig_rpm_compare:     CMPB    A, off(0012dh)         ; 5A5E 0 100 280 C72D
                JGT     postig_rpm_compare_goto_194c             ; 5A60 0 100 280 C803
                J       postig_rpm_compare_cmp_ram0c1             ; 5A62 0 100 280 030B19
postig_rpm_compare_goto_194c:     J       ignmap2_result_check_clear_acc             ; 5A65 0 100 280 034C19
ignition_timing_calc_task_mul_acc_3:     MUL                            ; 5A68 1 208 180 9035
                SLL     A                      ; 5A6A 1 208 180 53
                ROL     er1                    ; 5A6B 1 208 180 45B7
                JGE     ignition_timing_calc_task_load_ram29a             ; 5A6D 1 208 180 CD04
                MOV     er1, #0ffffh           ; 5A6F 1 208 180 4598FFFF
ignition_timing_calc_task_load_ram29a:     L       A, off(0029ah)         ; 5A73 1 208 180 E49A
                J       ignition_timing_calc_task_load_carry_pswl_bit4             ; 5A75 1 208 180 03B934
                DB  0D5h,0F0h,0D5h,0EEh,0C4h,032h,00Fh,003h ; 5A78
                DB  0FBh,039h ; 5A80
nmi_enter_lowpower_seq_load_ram0eb:     LB      A, 0ebh                ; 5A82 0 208 ??? F5EB
                JNE     nmi_enter_lowpower_seq_brk             ; 5A84 0 208 ??? CE04
                MOVB    0ebh, #047h            ; 5A86 0 208 ??? C5EB9847
nmi_enter_lowpower_seq_brk:     BRK                            ; 5A8A 0 208 ??? FF
cfgvariant_check_232h_bits01_call_cfgvariant_ram_init_0x:     CAL     cfgvariant_ram_init_0x300             ; 5A8B 1 208 ??? 321355
                ANDB    off(00232h), #0fch     ; 5A8E 1 208 ??? C432D0FC
                J       restore_trapstate_after_ramclear             ; 5A92 1 208 ??? 03E323
callhelper_table_interp_lookup_load_x1:     MOV     X1, #callhelper_table_interp_lookup_tbl          ; 5AC5 0 200 180 60D96A
                LB      A, off(00236h)         ; 5AC8 0 200 180 F436
                VCAL    0                      ; 5ACA 0 200 180 10
                CMPB    A, 0bbh                ; 5ACB 0 200 180 C5BBC2
                MB      off(00231h).6, C       ; 5ACE 0 200 180 C4313E
                CLR     A                      ; 5AD1 (skeleton: fault flags are always clear)
                J       skel_tipin_after_fault_test
tipin_gate_pass_load_ram24f:     LB      A, off(0024fh)         ; 5AD9 0 200 180 F44F
                EXTND                          ; 5ADB 1 200 180 F8
                LCB     A, tbl_5b2e[ACC]       ; 5ADC 1 200 180 B506AB2E5B
                MOVB    off(0024eh), A         ; 5AE1 1 200 180 C44E8A
                MOV     X1, #tipin_gate_pass_tbl          ; 5AE4 1 200 180 60E76A
                J       tipin_gate_pass_load_ram236             ; 5AE7 1 200 180 03F30D
tipin_decay_check_if_ram21b_bit6_set:     JBS     off(0021bh).6, tipin_decay_gate2 ; 5AEA 0 200 180 EE1B0D
                CMP     0aeh, #00010h          ; 5AED 0 200 180 B5AEC01000
                JLT     tipin_decay_gate3             ; 5AF2 0 200 180 CA0D
                RB      off(00232h).4          ; 5AF4 0 200 180 C4320C
tipin_decay_common:     RC                             ; 5AF7 0 200 180 95
                SJ      tipin_decay_common_goto_0e1e             ; 5AF8 0 200 180 CB12
tipin_decay_gate2:     CMP     0aeh, #00003h          ; 5AFA 0 200 180 B5AEC00300
                JGE     tipin_decay_gate4             ; 5AFF 0 200 180 CD06
tipin_decay_gate3:     JBS     off(00232h).4, tipin_decay_common ; 5B01 0 200 180 EC32F3
tipin_decay_gate3_set_carry:     SC                             ; 5B04 0 200 180 85
                SJ      tipin_decay_common_goto_0e1e             ; 5B05 0 200 180 CB05
tipin_decay_gate4:     SB      off(00232h).4          ; 5B07 0 200 180 C4321C
                SJ      tipin_decay_gate3_set_carry             ; 5B0A 0 200 180 CBF8
tipin_decay_common_goto_0e1e:     J       tipin_decay_common_store_carry_ram232_bit5             ; 5B0C 0 200 180 031E0E
tipin_gate_fail_clear_ram220_bit0:     RB      off(00220h).0          ; 5B0F 0 200 180 C42008
                RB      off(00232h).4          ; 5B12 0 200 180 C4320C
                J       tipin_decay_zero             ; 5B15 0 200 180 032E0E
dwell_scale_shift_load_ram0b9:     LB      A, 0b9h                ; 5B18 0 200 180 F5B9
                MOV     X1, #dwell_scale_shift_tbl_2          ; 5B1A 0 200 180 60345B
                VCAL    0                      ; 5B1D 0 200 180 10
                MOVB    r0, off(00237h)        ; 5B1E 0 200 180 C43748
                MULB                           ; 5B21 0 200 180 A234
                L       A, ACC                 ; 5B23 1 200 180 E506
                SLL     A                      ; 5B25 1 200 180 53
                MOVB    r6, ACCH               ; 5B26 1 200 180 C5074E
                CLRB    r7                     ; 5B29 1 200 180 2715
                CLR     A                      ; 5B2B 1 200 180 F9
                J       ign_sum_stage1             ; 5B2C 1 200 180 03D50E
tbl_5b2e        EQU     $-1 ; 5B2E
                DB  001h,004h,004h,002h,001h ; 5B2F
dwell_scale_shift_tbl_2:       DB  0FFh,080h,04Dh,080h,040h,05Ah,030h,026h ; 5B34
                DB  028h,000h,000h,000h ; 5B3C
to_injtimer_store_0x166_cmp_ram0c1:     CMPB    0c1h, #044h            ; 5B40 0 100 280 C5C1C044
                JLT     to_injtimer_store_0x166_goto_injtimer_gate_common             ; 5B44 0 100 280 CA06
                JBR     off(00125h).6, to_injtimer_store_0x166_goto_injtimer_gate_common ; 5B46 0 100 280 DE2503
                J       to_injtimer_store_0x166_if_ram125_bit7_clr             ; 5B49 0 100 280 03E01C
to_injtimer_store_0x166_goto_injtimer_gate_common:     J       injtimer_gate_common             ; 5B4C 0 100 280 03F31C
idle_vcal5_call3_load_ram27c:     L       A, off(0027ch)         ; 5B4F 1 208 180 E47C
                JNE     idle_vcal5_call3_goto_30c2_2             ; 5B51 1 208 180 CE07
                L       A, off(00270h)         ; 5B53 1 208 180 E470
                JNE     idle_vcal5_call3_goto_30c2_2             ; 5B55 1 208 180 CE03
                J       idle_vcal5_call3_goto_5f09             ; 5B57 1 208 180 036630
idle_vcal5_call3_goto_30c2_2:     J       idle_stall_check2_if_ram217_bit5_clr             ; 5B5A 1 208 180 03C230
dwell_rpm_gate3_load_r0:     MOVB    r0, off(00173h)        ; 5B5D 0 100 280 C47348
                CMPB    off(0012dh), #080h     ; 5B60 0 100 280 C42DC080
                JLT     dwell_rpm_gate3_goto_dwell_value_select             ; 5B64 0 100 280 CA03
                MOVB    r0, off(001eeh)        ; 5B66 0 100 280 C4EE48
dwell_rpm_gate3_goto_dwell_value_select:     J       dwell_value_select             ; 5B69 0 100 280 03AA1D
revlimit_table_select_store_r2_3:     STB     A, r2                  ; 5B6C 0 208 180 8A
                MOV     X1, #revlimit_table_select_tbl          ; 5B6D 0 208 180 60805B
                JBS     off(00216h).3, revlimit_table_select_vcal_0_5 ; 5B70 0 208 180 EB1603
                MOV     X1, #revlimit_table_select_tbl_2          ; 5B73 0 208 180 608E5B
revlimit_table_select_vcal_0_5:     VCAL    0                      ; 5B76 0 208 180 10
                STB     A, (001eeh-00180h)[USP] ; 5B77 0 208 180 D36E
                LB      A, r2                  ; 5B79 0 208 180 7A
                MOV     X1, #revlimit_table_select_tbl_10          ; 5B7A 0 208 180 605762
                J       revlimit_table_select_vcal_1             ; 5B7D 0 208 180 033A40
revlimit_table_select_tbl:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 5B80
                DB  06Eh,020h,028h,018h,000h,018h ; 5B88
revlimit_table_select_tbl_2:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 5B8E
                DB  06Eh,020h,028h,014h,000h,014h ; 5B96
postfuel_hyst_lower_calc_call_clamp_diff_15b_1ec:     CAL     clamp_diff_15b_1ec             ; 5B9C 1 100 280 32135C
                J       cylinder_ign_correct_apply_goto_5c43             ; 5B9F 1 100 280 03E61F
to_injtimer_sub_common:     LB      A, #040h               ; 5BA2 0 100 280 7740
                JBS     off(00129h).3, to_injtimer_sub_common_cmp_acc_2 ; 5BA4 0 100 280 EB2902
                LB      A, #04dh               ; 5BA7 0 100 280 774D
to_injtimer_sub_common_cmp_acc_2:     CMPB    A, off(0012dh)         ; 5BA9 0 100 280 C72D
                MB      off(00129h).3, C       ; 5BAB 0 100 280 C4293B
                LB      A, #0f2h               ; 5BAE 0 100 280 77F2
                JBS     off(00129h).4, to_injtimer_sub_common_cmp_acc_3 ; 5BB0 0 100 280 EC2902
                LB      A, #0f9h               ; 5BB3 0 100 280 77F9
to_injtimer_sub_common_cmp_acc_3:     CMPB    A, off(0012ch)         ; 5BB5 0 100 280 C72C
                MB      off(00129h).4, C       ; 5BB7 0 100 280 C4293C
                LB      A, off(0015eh)         ; 5BBA 0 100 280 F45E
                J       to_injtimer_sub_common_load_imm             ; 5BBF 0 100 280 036F1C
to_injtimer_sub_common_store_r7:     STB     A, r7                  ; 5BC5 0 100 280 8F
                JBS     off(0011dh).0, to_injtimer_sub_common_load_ram12c ; 5BC6 0 100 280 E81D37
                CMP     off(0014ah), #03000h   ; 5BC9 0 100 280 B44AC00030
                JGE     to_injtimer_sub_common_call_clamp_diff_15b_1ec             ; 5BCE 0 100 280 CD1E
                JBR     off(00129h).3, to_injtimer_sub_common_call_clamp_diff_15b_1ec ; 5BD0 0 100 280 DB291B
                JBS     off(00129h).4, to_injtimer_sub_common_call_clamp_diff_15b_1ec ; 5BD3 0 100 280 EC2918
                LB      A, 0a8h                ; 5BD6 0 100 280 F5A8
                JBR     off(0011bh).4, to_injtimer_sub_common_if_ram11b_bit1_clr ; 5BD8 0 100 280 DC1B04
                CMPB    A, #003h               ; 5BDB 0 100 280 C603
                JGE     to_injtimer_sub_common_call_clamp_diff_15b_1ec             ; 5BDD 0 100 280 CD0F
to_injtimer_sub_common_if_ram11b_bit1_clr:     JBR     off(0011bh).1, to_injtimer_sub_common_load_ram1ed ; 5BDF 0 100 280 D91B11
                LB      A, #004h               ; 5BE2 0 100 280 7704
                JBS     off(00116h).3, to_injtimer_sub_common_cmp_acc_4 ; 5BE4 0 100 280 EB1602
                LB      A, #004h               ; 5BE7 0 100 280 7704
to_injtimer_sub_common_cmp_acc_4:     CMPB    A, 0bdh                ; 5BE9 0 100 280 C5BDC2
                JGE     to_injtimer_sub_common_load_ram1ed             ; 5BEC 0 100 280 CD05
to_injtimer_sub_common_call_clamp_diff_15b_1ec:     CAL     clamp_diff_15b_1ec             ; 5BEE 0 100 280 32135C
                SJ      to_injtimer_sub_common_load_ram12c             ; 5BF1 0 100 280 CB0D
to_injtimer_sub_common_load_ram1ed:     LB      A, off(001edh)         ; 5BF3 0 100 280 F4ED
                MOVB    r0, #0fah              ; 5BF5 0 100 280 98FA
                MULB                           ; 5BF7 0 100 280 A234
                LB      A, ACCH                ; 5BF9 0 100 280 F507
                STB     A, off(001edh)         ; 5BFB 0 100 280 D4ED
                ADDB    A, off(001ech)         ; 5BFD 0 100 280 87EC
                STB     A, r7                  ; 5BFF 0 100 280 8F
to_injtimer_sub_common_load_ram12c:     LB      A, off(0012ch)         ; 5C00 0 100 280 F42C
                J       to_injtimer_sub_common_call_table_interp_lookup_prescan             ; 5C02 0 100 280 03941C
revlimit_table_select_vcal_1_2:     VCAL    1                      ; 5C05 0 208 180 11
                STB     A, (001e8h-00180h)[USP] ; 5C06 0 208 180 D368
                LB      A, 0c1h                ; 5C08 0 208 180 F5C1
                MOV     X1, #revlimit_table_select_tbl_3          ; 5C0A 0 208 180 601D5C
                VCAL    0                      ; 5C0D 0 208 180 10
                STB     A, (001ech-00180h)[USP] ; 5C0E 0 208 180 D36C
                J       revlimit_table_select_vcal_4             ; 5C10 0 208 180 034540
clamp_diff_15b_1ec:     LB      A, off(0015bh)         ; 5C13 0 100 280 F45B
                SUBB    A, off(001ech)         ; 5C15 0 100 280 A7EC
                JGE     clamp_diff_15b_1ec_store_ram1ed             ; 5C17 0 100 280 CD01
                CLRB    A                      ; 5C19 0 100 280 FA
clamp_diff_15b_1ec_store_ram1ed:     STB     A, off(001edh)         ; 5C1A 0 100 280 D4ED
                RT                             ; 5C1C 0 100 280 01
revlimit_table_select_tbl_3:       DB  0FFh,060h,0E6h,052h,0CFh,051h,0A1h,050h ; 5C1D
                DB  044h,041h,028h,040h,000h,040h ; 5C25
cylinder_ign_correct_apply_load_imm_2:     LB      A, #0c5h               ; 5C43 0 100 280 77C5
                JBS     off(00124h).5, cylinder_ign_correct_apply_cmp_acc ; 5C45 0 100 280 ED2402
                LB      A, #0c8h               ; 5C48 0 100 280 77C8
cylinder_ign_correct_apply_cmp_acc:     CMPB    A, off(0012dh)         ; 5C4A 0 100 280 C72D
                MB      off(00124h).5, C       ; 5C4C 0 100 280 C4243D
                LB      A, off(00135h)         ; 5C4F 0 100 280 F435
                JNE     cylinder_ign_correct_apply_goto_deadtime_retry_check             ; 5C51 0 100 280 CE03
                J       cylinder_ign_correct_apply_load_imm             ; 5C53 0 100 280 03EA1F
cylinder_ign_correct_apply_goto_deadtime_retry_check:     J       deadtime_retry_check             ; 5C56 0 100 280 034120
to_gio_mode_dispatch_subb_acc:     SUBB    A, r6                  ; 5C59 0 100 280 2E
                JGE     to_gio_mode_dispatch_if_ram124_bit5_set             ; 5C5A 0 100 280 CD03
                J       injector_effective_pw_skip             ; 5C5C 0 100 280 036C20
to_gio_mode_dispatch_if_ram124_bit5_set:     JBS     off(00124h).5, injector_effective_pw_calc ; 5C5F 0 100 280 ED2421
                MOVB    r6, off(00133h)        ; 5C62 0 100 280 C4334E
                SUBB    r6, #001h              ; 5C65 0 100 280 26A001
                JLT     injector_effective_pw_calc             ; 5C68 0 100 280 CA19
                CMPB    A, r6                  ; 5C6A 0 100 280 4E
                JNE     injector_effective_pw_calc             ; 5C6B 0 100 280 CE16
                MOV     X1, er1                ; 5C6D 0 100 280 4578
                STB     A, r6                  ; 5C6F 0 100 280 8E
                L       A, #08000h             ; 5C70 1 100 280 670080
                MOV     er0, er2               ; 5C73 1 100 280 4648
                MUL                            ; 5C75 1 100 280 9035
                L       A, er1                 ; 5C77 1 100 280 35
                CMP     A, X1                  ; 5C78 1 100 280 90C2
                LB      A, r6                  ; 5C7A 0 100 280 7E
                JLT     injector_effective_pw_calc             ; 5C7B 0 100 280 CA06
                CMPB    A, #00bh               ; 5C7D 0 100 280 C60B
                JGE     injector_effective_pw_calc             ; 5C7F 0 100 280 CD02
                ADDB    A, #001h               ; 5C81 0 100 280 8601
injector_effective_pw_calc:     J       injector_effective_pw_store             ; 5C83 0 100 280 036D20
                DB  0D9h,01Bh,007h,0C5h,0BDh,0C0h,020h,003h ; 5C86
                DB  079h,033h,003h,07Bh,033h ; 5C8E
tipin_decay_store_store_carry_ram220_bit1:     MB      off(00220h).1, C       ; 5C93 0 200 180 C42039
                LB      A, #000h               ; 5C96 0 200 180 7700
                JBS     off(00225h).3, knock244_threshold_check ; 5C98 0 200 180 EB2502
                LB      A, #00bh               ; 5C9B 0 200 180 770B
knock244_threshold_check:     CMPB    A, off(00243h)         ; 5C9D 0 200 180 C743
                MB      off(00225h).3, C       ; 5C9F 0 200 180 C4253B
                MOVB    r0, #040h              ; 5CA2 0 200 180 9840
                MOVB    r1, #003h              ; 5CA4 0 200 180 9903
                MOVB    r2, #02ah              ; 5CA6 0 200 180 9A2A
                MOVB    r3, #00ch              ; 5CA8 0 200 180 9B0C
                JGE     dwellbase_gate1             ; 5CAA 0 200 180 CD08
                MOVB    r0, #040h              ; 5CAC 0 200 180 9840
                MOVB    r1, #006h              ; 5CAE 0 200 180 9906
                MOVB    r2, #033h              ; 5CB0 0 200 180 9A33
                MOVB    r3, #00ch              ; 5CB2 0 200 180 9B0C
dwellbase_gate1:
                JBS     off(0021dh).4, gate_255_common ; 5CB7 0 200 180 EC1D1D
                CMPB    0c1h, #034h            ; 5CBA 0 200 180 C5C1C034
                JGE     gate_255_common             ; 5CBE 0 200 180 CD17
                LB      A, r0                  ; 5CC0 0 200 180 78
                CMPB    A, off(00236h)         ; 5CC1 0 200 180 C736
                JLT     gate_255_common             ; 5CC3 0 200 180 CA12
                JBS     off(00231h).6, gate_255_common ; 5CC5 0 200 180 EE310F
                CLRB    A                      ; 5CC8 0 200 180 FA
                JBR     off(0021bh).1, store_255_result ; 5CC9 0 200 180 D91B09
                CMPB    0bdh, #020h            ; 5CCC 0 200 180 C5BDC020
                JLT     store_255_result             ; 5CD0 0 200 180 CA03
                LB      A, r1                  ; 5CD2 0 200 180 79
                ADDB    A, #001h               ; 5CD3 0 200 180 8601
store_255_result:     STB     A, off(002fbh)         ; 5CD5 0 200 180 D4FB
gate_255_common:     LB      A, r2                  ; 5CD7 0 200 180 7A
                CMPB    off(002fbh), #000h     ; 5CD8 0 200 180 C4FBC000
                JNE     gate_255_common_decb_ram2fb             ; 5CDC 0 200 180 CE08
                LB      A, off(002fah)         ; 5CDE 0 200 180 F4FA
                SUBB    A, r3                  ; 5CE0 0 200 180 2B
                JGE     gate_255_common_store_ram2fa             ; 5CE1 0 200 180 CD06
                CLRB    A                      ; 5CE3 0 200 180 FA
                SJ      gate_255_common_store_ram2fa             ; 5CE4 0 200 180 CB03
gate_255_common_decb_ram2fb:     DECB    off(002fbh)            ; 5CE6 0 200 180 C4FB17
gate_255_common_store_ram2fa:     STB     A, off(002fah)         ; 5CE9 0 200 180 D4FA
                J       gate_255_common_if_ram216_bit3_set             ; 5CEB 0 200 180 03350E
ign_sum_stage1_load_ram2fa:     LB      A, off(002fah)         ; 5CEE 0 200 180 F4FA
                ADD     er3, A                 ; 5CF0 0 200 180 4781
                L       A, er3                 ; 5CF2 1 200 180 37
                VCAL    7                      ; 5CF3 1 200 180 17
                ST      A, er3                 ; 5CF4 1 200 180 8B
                J       ign_sum_negate             ; 5CF5 1 200 180 03F00E
idle_integrator_final_store_if_ram211_bit5_clr:     JBR     off(00211h).5, idle_integrator_final_store_goto_2d1e ; 5CF8 1 208 180 DD1114
                CMPB    0c1h, #03ah            ; 5CFB 1 208 180 C5C1C03A
                JLT     idle_integrator_final_store_clear_acc             ; 5CFF 1 208 180 CA07
                L       A, off(00264h)         ; 5D01 1 208 180 E464
                SUB     A, #00040h             ; 5D03 1 208 180 A64000
                JGE     idle_integrator_final_store_goto_idle_output_finalize             ; 5D06 1 208 180 CD04
idle_integrator_final_store_clear_acc:     CLR     A                      ; 5D08 1 208 180 F9
                J       to_idle_output_finalize             ; 5D09 1 208 180 03182D
idle_integrator_final_store_goto_idle_output_finalize:     J       idle_output_finalize             ; 5D0C 1 208 180 03512D
idle_integrator_final_store_goto_2d1e:     J       idle_integrator_final_store_cmp_ram0c1             ; 5D0F 1 208 180 031E2D
idle_sub_gate2_if_ram216_bit3_set:     JBS     off(00216h).3, idle_sub_gate2_cmp_acc_2 ; 5D12 1 208 180 EB1614
                JBR     off(0021ah).3, idle_sub_gate2_cmp_acc_2 ; 5D15 1 208 180 DB1A11
                JBR     off(00218h).2, idle_sub_gate2_cmp_acc_2 ; 5D18 1 208 180 DA180E
                MOV     X1, #00a00h            ; 5D1B 1 208 180 60000A
                JBR     off(00211h).2, idle_sub_gate2_cmp_acc ; 5D1E 1 208 180 DA1103
                MOV     X1, #00b00h            ; 5D21 1 208 180 60000B
idle_sub_gate2_cmp_acc:     CMP     A, X1                  ; 5D24 1 208 180 90C2
                JGE     idle_sub_gate2_cmp_acc_2             ; 5D26 1 208 180 CD01
                L       A, X1                  ; 5D28 1 208 180 40
idle_sub_gate2_cmp_acc_2:     CMP     A, DP                  ; 5D29 1 208 180 92C2
                JLT     idle_sub_gate2_goto_2dca             ; 5D2B 1 208 180 CA03
                J       idle_sub_alt_path             ; 5D2D 1 208 180 03C92D
idle_sub_gate2_goto_2dca:     J       idle_sub_alt_path_store_ram262             ; 5D30 1 208 180 03CA2D
idle_timer_gate1_if_ram218_bit2_clr:     JBR     off(00218h).2, idle_timer_gate1_goto_idle_timer_gate_common ; 5D33 1 208 180 DA1808
                CLRB    off(002d6h)            ; 5D36 1 208 180 C4D615
                MOVB    r0, #028h              ; 5D39 1 208 180 9828
                J       idle_timer_gate1_if_ram21a_bit5_set             ; 5D3B 1 208 180 033B2F
idle_timer_gate1_goto_idle_timer_gate_common:     J       idle_timer_gate_common             ; 5D3E 1 208 180 03402F
idle_table_lookup3_load_ram258:     L       A, off(00258h)         ; 5D41 1 208 180 E458
                CAL     table_interp_lookup_4byte             ; 5D43 1 208 180 32FE4E
                CMP     A, 0b2h                ; 5D46 1 208 180 B5B2C2
                J       idle_table_lookup3_if_lt_goto_idle_table_lookup4             ; 5D49 1 208 180 036C2F
tbl_idle_default1:       DB  0FFh,0FFh,06Bh,000h,035h,00Ch,06Bh,000h ; 5D4C
                DB  0C4h,009h,044h,000h,00Bh,009h,03Ah,000h ; 5D54
                DB  053h,007h,026h,000h,04Eh,004h,00Eh,000h ; 5D5C
                DB  000h,000h,00Eh,000h ; 5D64
tbl_idle_default2:       DB  0FFh,0FFh,095h,000h,035h,00Ch,095h,000h ; 5D68
                DB  0C4h,009h,061h,000h,00Bh,009h,053h,000h ; 5D70
                DB  053h,007h,037h,000h,04Eh,004h,013h,000h ; 5D78
                DB  000h,000h,013h,000h ; 5D80
idle_table_lookup4_load_x1:     MOV     X1, #idle_table_lookup4_tbl          ; 5D84 1 208 180 608F5D
                L       A, off(00258h)         ; 5D87 1 208 180 E458
                CAL     table_interp_lookup_4byte             ; 5D89 1 208 180 32FE4E
                J       idle_table_lookup4_if_ram21a_bit5_clr             ; 5D8C 1 208 180 03742F
idle_table_lookup4_tbl:       DB  0FFh,0FFh,0F1h,000h,035h,00Ch,0F1h,000h ; 5D8F
                DB  0C4h,009h,09Dh,000h,00Bh,009h,087h,000h ; 5D97
                DB  053h,007h,05Ah,000h,04Eh,004h,01Fh,000h ; 5D9F
                DB  000h,000h,01Fh,000h ; 5DA7
tps_interp_store_load_er0:     MOV     er0, #00300h           ; 5DAB 1 200 180 44980003
                JGE     rpm_avg_range_check             ; 5DAF 1 200 180 CD05
                VCAL    7                      ; 5DB1 1 200 180 17
                MOV     er0, #00300h           ; 5DB2 1 200 180 44980003
rpm_avg_range_check:     CMP     A, er0                 ; 5DB6 1 200 180 48
                JLT     rpm_avg_range_check_goto_09b5             ; 5DB7 1 200 180 CA01
                L       A, er0                 ; 5DB9 1 200 180 34
rpm_avg_range_check_goto_09b5:     J       rpm_avg_range_check_store_ram0b2             ; 5DBA 1 200 180 03B509
idle_flag_gate_load_ram2dc:     LB      A, off(002dch)         ; 5DBD 0 208 180 F4DC
                JNE     idle_flag_gate_load_ram286             ; 5DBF 0 208 180 CE03
                RB      off(00222h).7          ; 5DC1 0 208 180 C4220F
idle_flag_gate_load_ram286:     MOV     off(00286h), off(00284h) ; 5DC4 0 208 180 B4847C86
                J       idle_flag_gate_load_ram289             ; 5DC8 0 208 180 038D2F
idle_mode_gate6_if_ram22b_bit3_clr:     JBR     off(0022bh).3, idle_mode_gate6_goto_idle_pi_mul1 ; 5DCB 0 208 180 DB2B0F
                CMPB    0c1h, #0d0h            ; 5DCE 0 208 180 C5C1C0D0
                JLT     idle_mode_gate6_goto_2fba             ; 5DD2 0 208 180 CA06
                CMPB    0e9h, #0fah            ; 5DD4 0 208 180 C5E9C0FA
                JLT     idle_mode_gate6_goto_idle_pi_mul1             ; 5DD8 0 208 180 CA03
idle_mode_gate6_goto_2fba:     J       idle_mode_gate6_if_ram229_bit6_clr             ; 5DDA 0 208 180 03BA2F
idle_mode_gate6_goto_idle_pi_mul1:     J       idle_pi_mul1             ; 5DDD 0 208 180 03ED2F
idle_mode_gate6_cmp_ram2dc:     CMPB    off(002dch), #000h     ; 5DE0 1 208 180 C4DCC000
                JEQ     idle_mode_gate6_goto_59fa             ; 5DE4 1 208 180 C906
                SB      off(00222h).7          ; 5DE6 1 208 180 C4221F
                J       idle_mode_gate6_if_ne_goto_5a02             ; 5DE9 1 208 180 03F859
idle_mode_gate6_goto_59fa:     J       idle_mode_gate6_goto_5def             ; 5DEC 1 208 180 03FA59
idle_mode_gate6_load_x2:     MOV     X2, A                  ; 5DEF 1 208 180 51
                LB      A, 0c0h                ; 5DF0 0 208 180 F5C0
                MOV     X1, #idle_mode_gate6_tbl          ; 5DF2 0 208 180 60FC5D
                CAL     vcal_1                 ; 5DF5 0 208 180 32C04E
                L       A, X2                  ; 5DF8 1 208 180 41
                J       idle_mode_gate6_load_ram2dc             ; 5DF9 1 208 180 03FE59
idle_mode_gate6_tbl:       DB  0FFh,000h,000h,0C0h,000h,000h,0A0h,040h ; 5DFC
                DB  001h,080h,080h,001h,030h,000h,002h,000h ; 5E04
                DB  000h,003h ; 5E0C
battery_voltage_check_store_carry_ram21a_bit3:     MB      off(0021ah).3, C       ; 5E0E 0 208 180 C41A3B
                LB      A, 0c4h                ; 5E11 0 208 180 F5C4
                STB     A, r0                  ; 5E13 0 208 180 88
                XCHGB   A, 0f8h                ; 5E14 0 208 180 C5F810
                SUBB    A, r0                  ; 5E17 0 208 180 28
                MB      off(00225h).2, C       ; 5E18 0 208 180 C4253A
                JGE     battery_voltage_store             ; 5E1B 0 208 180 CD01
                VCAL    7                      ; 5E1D 0 208 180 17
battery_voltage_store:     STB     A, 0f9h                ; 5E1E 0 208 180 D5F9
battery_voltage_store_goto_2ab1:       J       battery_voltage_store_load_x1             ; 5E20 0 208 180 03B12A
idle_pid_mul_apply_store_r1:     STB     A, r1                  ; 5E23 0 208 180 89
                MOV     X1, #idle_pid_mul_apply_tbl          ; 5E24 0 208 180 603E5E
                LB      A, 0c1h                ; 5E27 0 208 180 F5C1
                VCAL    0                      ; 5E29 0 208 180 10
                STB     A, r1                  ; 5E2A 0 208 180 89
                CLRB    r0                     ; 5E2B 0 208 180 2015
                L       A, er1                 ; 5E2D 1 208 180 35
                MUL                            ; 5E2E 1 208 180 9035
                ROL     A                      ; 5E30 1 208 180 33
                L       A, er1                 ; 5E31 1 208 180 35
                ROL     A                      ; 5E32 1 208 180 33
                JGE     idle_pid_mul_apply_p02_check             ; 5E33 1 208 180 CD03
                L       A, #0ffffh             ; 5E35 1 208 180 67FFFF
idle_pid_mul_apply_p02_check:     MB      C, P0.2                ; 5E38 1 208 180 C5202A
                J       idle_pid_mul_apply_resume             ; 5E3B 1 208 180 033A2C
idle_pid_mul_apply_tbl:       DB  0FFh,0C0h,0A1h,0C0h,044h,0A0h,028h,080h,000h,080h ; 5E3E
idle_pid_recheck2_if_ram217_bit6_clr:     JBR     off(00217h).6, idle_pid_hyst_check ; 5E48 0 208 180 DE1711
                LB      A, #028h               ; 5E4B 0 208 180 7728
                CLRB    r1                     ; 5E4D 0 208 180 2115
                JBS     off(00225h).2, idle_pid_hyst_calc ; 5E4F 0 208 180 EA2504
                LB      A, #028h               ; 5E52 0 208 180 7728
                MOVB    r1, #000h              ; 5E54 0 208 180 9900
idle_pid_hyst_calc:     MOVB    r2, 0f9h               ; 5E56 0 208 180 C5F94A
                     MB      C, off(00225h).2       ; 5E59 0 208 180 C4252A
idle_pid_hyst_check:     MB      PSWL.4, C              ; 5E5C 0 208 180 A33C
                CMPB    A, r2                  ; 5E5E 0 208 180 4A
                J       idle_pid_hyst_check_if_ge_goto_idle_pid_common             ; 5E5F 0 208 180 03632C
idle_pid_hyst_check_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 5E62 0 208 180 A32C
                JLT     idle_pid_p0_check             ; 5E64 0 208 180 CA06
                LB      A, off(00297h)         ; 5E66 0 208 180 F497
                JEQ     idle_pid_flag_store             ; 5E68 0 208 180 C907
                SJ      idle_pid_flag_store_goto_idle_pid_flag_clear             ; 5E6A 0 208 180 CB08
idle_pid_p0_check:     MB      C, P0.2                ; 5E6C 0 208 180 C5202A
                JLT     idle_pid_flag_store_goto_idle_pid_flag_clear             ; 5E6F 0 208 180 CA03
idle_pid_flag_store:     MOVB    off(00297h), r1        ; 5E71 0 208 180 217C97
idle_pid_flag_store_goto_idle_pid_flag_clear:     J       idle_pid_flag_clear             ; 5E74 0 208 180 03682C
idle_ectvs_result1:     JBR     off(00227h).1, idle_ectvs_result1_if_ram22a_bit3_clr ; 5E77 0 208 180 D92705
                JBR     off(00226h).4, idle_ectvs_result1_goto_2b80 ; 5E7A 0 208 180 DC2617
                SJ      idle_ectvs_result1_goto_2b5a             ; 5E7D 0 208 180 CB0B
idle_ectvs_result1_if_ram22a_bit3_clr:     JBR     off(0022ah).3, idle_ectvs_result1_if_ram225_bit1_clr ; 5E7F 0 208 180 DB2A0B
                MOVB    off(002ddh), #014h     ; 5E82 0 208 180 C4DD9814
                MOVB    off(002deh), #05ah     ; 5E86 0 208 180 C4DE985A
idle_ectvs_result1_goto_2b5a:     J       idle_ectvs_result1_load_r1             ; 5E8A 0 208 180 035A2B
idle_ectvs_result1_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_result1_goto_2b80 ; 5E8D 0 208 180 D92504
                LB      A, off(002ddh)         ; 5E90 0 208 180 F4DD
                JNE     idle_ectvs_result1_goto_2b5a             ; 5E92 0 208 180 CEF6
idle_ectvs_result1_goto_2b80:     J       idle_ectvs_result1_cmp_acc             ; 5E94 0 208 180 03802B
idle_ectvs_flag_check_if_ram22a_bit4_clr:     JBR     off(0022ah).4, idle_ectvs_flag_check_if_ram225_bit1_clr ; 5E97 0 208 180 DC2A07
                MOVB    off(002deh), #05ah     ; 5E9A 0 208 180 C4DE985A
idle_ectvs_flag_check_goto_idle_ectvs_result2:     J       idle_ectvs_result2             ; 5E9E 0 208 180 03742B
idle_ectvs_flag_check_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_flag_check_goto_2b92 ; 5EA1 0 208 180 D92504
                LB      A, off(002deh)         ; 5EA4 0 208 180 F4DE
                JNE     idle_ectvs_flag_check_goto_idle_ectvs_result2             ; 5EA6 0 208 180 CEF6
idle_ectvs_flag_check_goto_2b92:     J       idle_ectvs_flag_check_if_ram216_bit3_clr             ; 5EA8 0 208 180 03922B
boot_flag_baro_common_load_carry_ram216_bit2:     MB      C, off(00216h).2       ; 5EE4 0 208 180 C4162A
                LCB     A, diag_snapshot_copy_loop_tbl            ; 5EE7 0 208 180 909D0B60
                J       boot_flag_baro_common_if_eq_goto_561c             ; 5EEB 0 208 180 031556
idle_vcal5_call3_load_ram266:     L       A, off(00266h)         ; 5F09 1 208 180 E466
                JNE     idle_vcal5_call3_goto_30c2_3             ; 5F0B 1 208 180 CE03
                J       idle_vcal5_call3_cmp_ram0a6             ; 5F0D 1 208 180 036930
idle_vcal5_call3_goto_30c2_3:     J       idle_stall_check2_if_ram217_bit5_clr             ; 5F10 1 208 180 03C230
ignition_timing_calc_task_load_ram0bd:     LB      A, 0bdh                ; 5F13 0 208 180 F5BD
                JBS     off(0021bh).1, ignition_timing_calc_task_cmp_acc_9 ; 5F15 0 208 180 E91B04
                CMPB    A, #010h               ; 5F18 0 208 180 C610
                JGT     ignition_timing_calc_task_goto_337b             ; 5F1A 0 208 180 C805
ignition_timing_calc_task_cmp_acc_9:     CMPB    A, #020h               ; 5F1C 0 208 180 C620
                J       ignition_timing_calc_task_if_le_goto_337f             ; 5F1E 0 208 180 037933
ignition_timing_calc_task_goto_337b:     J       ignition_timing_calc_task_load_ram2d2             ; 5F21 0 208 180 037B33
div_scale_store_load_x1:     MOV     X1, #00004h            ; 5F24 0 208 180 600400
                JBS     off(00216h).3, div_scale_store_goto_gear_detect_store ; 5F27 0 208 180 EB1605
                LB      A, #001h               ; 5F2A 0 208 180 7701
                J       div_scale_store_clear_x1             ; 5F2C 0 208 180 03A03E
div_scale_store_goto_gear_detect_store:     J       gear_detect_store             ; 5F2F 0 208 180 03D43E
                DB  0EBh,01Dh,006h,0ECh,01Eh,003h,003h,0D5h ; 5F68
                DB  03Dh,003h,0E4h,03Dh ; 5F70
crank_tooth_count_store_load_carry_ram113_bit6:     RC                             ; (skeleton: fault flag always clear)
                MB      off(00122h).1, C       ; 5F77 0 108 280 C42239
                J       crank_tooth_count_store_if_ram120_bit2_set             ; 5F7A 0 108 280 03CF03
vcal3_leanprotect_ratelimit_clear_stk:     RB      (00122h-00180h)[USP].2 ; 5F7D 1 208 180 C3A20A
                JBR     off(00216h).7, vcal3_leanprotect_ratelimit_goto_26a7 ; 5F80 1 208 180 DF1603
                J       vcal3_leanprotect_ratelimit_clear_ram09e_bit6             ; 5F83 1 208 180 039F26
vcal3_leanprotect_ratelimit_goto_26a7:     J       vcal3_leanprotect_ratelimit_clear_ram09e_bit4             ; 5F86 1 208 180 03A726
idle_init_start_clear_stk:     RB      (00122h-00180h)[USP].2 ; 5F89 0 208 180 C3A20A
                CAL     idle_helper1             ; 5F8C 0 208 180 32BB52
                J       idle_init_start_load_er0             ; 5F8F 0 208 180 032A28
coldstart_full_reset_andb_p1:     ANDB    P1, #0fch              ; 5F92 0 208 180 C522D0FC
                CLR     off(00268h)            ; 5F96 0 208 180 B46815
                J       coldstart_full_reset_goto_7831             ; 5F99 0 208 180 03E539
coldstart_full_reset_store_ram0f0:     ST      A, 0f0h                ; 5F9C 1 208 180 D5F0
                ST      A, 0eeh                ; 5F9E 1 208 180 D5EE
                ANDB    (0011fh-00180h)[USP], #0f9h ; 5FA0 1 208 180 C39FD0F9
                ANDB    off(0021fh), #0f9h     ; 5FA4 1 208 180 C41FD0F9
                RB      off(00232h).7          ; 5FA8 1 208 180 C4320F
                J       warmrestart_tm3_resync             ; 5FAB 1 208 180 03FB39
dtc13_baro_latch:     RB      099h.2                 ; 5FAE 0 208 180 C5993A
                VCAL    4                      ; 5FB1 0 208 180 14
                J       dcode14_check_if_ram217_bit5_set             ; 5FB2 0 208 180 03523C
gear_detect_store_load_stk:     MOV     (0017ah-00180h)[USP], A ; 5FB5 0 208 180 B3FA8A
                VCAL    4                      ; 5FB8 0 208 180 14
                J       gear_detect_store_load_x1             ; 5FB9 0 208 180 030B3F
gear_detect_store_load_stk_2:     MOV     (001eah-00180h)[USP], A ; 5FBC 0 208 180 B36A8A
                VCAL    4                      ; 5FBF 0 208 180 14
                J       threshold_bank_223_2             ; 5FC0 0 208 180 03293F
vss_band_dispatch:     MB      P0.1, C                ; 5FC3 0 208 180 C52039
                VCAL    4                      ; 5FC6 0 208 180 14
                J       vss_band_dispatch_load_r2             ; 5FC7 0 208 180 035843
altc_gio_override_check_vcal_4:     VCAL    4                      ; 5FCA 0 208 180 14
                JBS     off(00227h).3, altc_gio_override_check_goto_4491 ; 5FCB 0 208 180 EB2703
                J       altc_gio_override_check_if_ram216_bit3_clr             ; 5FCE 0 208 180 036844
altc_gio_override_check_goto_4491:     J       altc_normal_drive_nop_acc             ; 5FD1 0 208 180 039144
freezeframe_decode_start_load_ram212:                CLR     A                      ; 5FDB (skeleton: fault flags are always clear)
                J       freezeframe_decode_start_add_acc             ; 5FDF 1 208 180 03E64A
injector_timer_schedule_load_tm0:     L       A, TM0                 ; 5FE2 1 108 280 E530
                SUB     A, #00001h             ; 5FE4 1 108 280 A60100
                ST      A, TMR0                ; 5FE7 1 108 280 D532
                MOV     X1, #001b8h            ; 5FE9 1 108 280 60B801
                J       injector_timer_schedule_load_dp             ; 5FEC 1 108 280 03434B
inj_accum1_add_add_acc:     ADD     A, off(001b8h)         ; 5FEF 1 108 280 87B8
                CMP     A, #00100h             ; 5FF1 1 108 280 C60001
                JGE     inj_accum1_store2             ; 5FF4 1 108 280 CD01
                CLR     A                      ; 5FF6 1 108 280 F9
inj_accum1_store2:     ST      A, off(001b8h)         ; 5FF7 1 108 280 D4B8
                CLR     A                      ; 5FF9 1 108 280 F9
                ST      A, off(001bah)         ; 5FFA 1 108 280 D4BA
                J       inj_accum_store_114             ; 5FFC 1 108 280 03904C
; ------------------------------------------------------------------------------------------------
; Code that stock P30 kept after the calibration (764Ah-78ADh), moved down here so the space above the
; calibration is one free block.
; ------------------------------------------------------------------------------------------------
inj_accum_check2_add_acc:     ADD     A, off(001bah)         ; 764A 1 108 280 87BA
                CMP     A, #00100h             ; 764C 1 108 280 C60001
                JGE     inj_accum_check2_store_ram1ba             ; 764F 1 108 280 CD01
                CLR     A                      ; 7651 1 108 280 F9
inj_accum_check2_store_ram1ba:     ST      A, off(001bah)         ; 7652 1 108 280 D4BA
                CLR     A                      ; 7654 1 108 280 F9
                J       inj_accum_store_114             ; 7655 1 108 280 03904C
inj_accum_check4_add_acc:     ADD     A, off(001b8h)         ; 7658 1 108 280 87B8
                CMP     A, #00100h             ; 765A 1 108 280 C60001
                JGE     inj_accum_check4_store_ram1b8             ; 765D 1 108 280 CD01
                CLR     A                      ; 765F 1 108 280 F9
inj_accum_check4_store_ram1b8:     ST      A, off(001b8h)         ; 7660 1 108 280 D4B8
                J       inj_accum2_zero2             ; 7662 1 108 280 038A4C
crank_pswl4_store_cmp_acc:     CMPB    A, r0                  ; 7665 0 108 280 48
                JLE     crank_pswl4_store_goto_4d5c             ; 7666 0 108 280 CF09
                LB      A, [DP]                ; 7668 0 108 280 F2
                ADDB    A, #001h               ; 7669 0 108 280 8601
                CMPB    A, r0                  ; 766B 0 108 280 48
                JLE     crank_pswl4_store_goto_4d5c             ; 766C 0 108 280 CF03
                J       crank_pswl4_store_if_ram117_bit0_clr             ; 766E 0 108 280 03814D
crank_pswl4_store_goto_4d5c:     J       crank_mul_alt_mulb_acc             ; 7671 0 108 280 035C4D
timer2_irq_clear_orb_off_irq:     ORB     off(IRQ), #008h        ; 7674 1 0D0 ??? C418E008
                RB      TRNSIT.0               ; 7678 1 0D0 ??? C54608
                JEQ     timer2_irq_clear_return             ; 767B 1 0D0 ??? C903
                SB      09fh.2                 ; 767D 1 0D0 ??? C59F1A
timer2_irq_clear_return:     RTI                            ; 7680 1 0D0 ??? 02
; [CG] diag_report_finalize  @0x7681
; [CG] TRACED: writes into the diagnostic-snapshot RAM area (0x3AC/0x3D4, adjacent to
; [CG] cfgvariant_snapshot_capture's own 0x340 block), gated by off(120h).2 and off(122h).1, and
; [CG] hands off to fuelmap_do_lookup_b35. A second stage of the diagnostic/serial report
; [CG] construction.
diag_report_finalize:     JBR     off(00122h).1, diag_report_finalize_load_dp ; 7681 1 100 280 D92201
                CLR     A                      ; 7684 1 100 280 F9
diag_report_finalize_load_dp:     MOV     DP, #003d4h            ; 7685 1 100 280 62D403
                ST      A, [DP]                ; 7688 1 100 280 D2
                MOV     DP, #003ach            ; 7689 1 100 280 62AC03
                J       diag_report_finalize_store_dp_ind             ; 768C 1 100 280 031814
crank_tooth_count_store_set_ram120_bit2:     SB      off(00120h).2          ; 768F 0 108 280 C4201A
                RB      PSWH.0                 ; 7692 0 108 280 A208
                MOVB    off(001b6h), #077h     ; 7694 0 108 280 C4B69877
                MOVB    off(001beh), #011h     ; 7698 0 108 280 C4BE9811
                SB      PSWH.0                 ; 769C 0 108 280 A218
                J       crank_cycle_dispatch2             ; 769E 0 108 280 036905
threshold_bank_217_0_load_carry_ram0a0_bit6:     MB      C, 0a0h.6              ; 76A1 0 200 180 C5A02E
                JBR     off(00227h).5, threshold_bank_217_0_goto_0a01 ; 76A4 0 200 180 DD2706
                MOVB    r2, off(00236h)        ; 76A7 0 200 180 C4364A
                MB      C, 0a0h.7              ; 76AA 0 200 180 C5A02F
threshold_bank_217_0_goto_0a01:     J       threshold_bank_217_0_store_carry_pswl_bit4             ; 76AD 0 200 180 03010A
flag_dispatch_21d_212:     JBS     off(00227h).5, flag_dispatch_21d_212_goto_ignmap_2d_lookup ; 76B0 1 200 180 ED2706
                JBS     off(0021fh).1, flag_dispatch_21d_212_goto_ignmap_2d_lookup ; 76B3 1 200 180 E91F03
                J       flag_dispatch_21d_212_load_r3             ; 76B6 1 200 180 034F0B
flag_dispatch_21d_212_goto_ignmap_2d_lookup:     J       ignmap_2d_lookup             ; 76B9 1 200 180 03760B
boot_completion_helper_clear_carry_2:     RC                             ; 76C9 0 208 180 95
                LCB     A, idle_init_start_tbl            ; 76CA 0 208 180 909D1160
                STB     A, r0                  ; 76CE 0 208 180 88
                JNE     boot_completion_helper_store_carry_ram227_bit5             ; 76CF 0 208 180 CE0C
                LCB     A, diag_mode_code_store_tbl_2            ; 76D1 0 208 180 909D0F60
                JEQ     boot_completion_helper_store_carry_ram227_bit5             ; 76D5 0 208 180 C906
                SLLB    r1                     ; 76D7 0 208 180 21D7
                SLLB    r1                     ; 76D9 0 208 180 21D7
                MOVB    r1, #080h              ; 76DB 0 208 180 9980
boot_completion_helper_store_carry_ram227_bit5:     MB      off(00227h).5, C       ; 76DD 0 208 180 C4273D
                MOV     DP, #003c7h            ; 76E0 0 208 180 62C703
                J       boot_completion_helper_load_dp_ind             ; 76E3 0 208 180 03BE55
boot_completion_helper_rom_load_tbl_600f:     LCB     A, diag_mode_code_store_tbl_2            ; 76E6 0 208 180 909D0F60
                JEQ     boot_completion_helper_goto_55c5             ; 76EA 0 208 180 C906
                SLLB    r2                     ; 76EC 0 208 180 22D7
                MOVB    r2, #080h              ; 76EE 0 208 180 9A80
                RORB    r2                     ; 76F0 0 208 180 22C7
boot_completion_helper_goto_55c5:     J       boot_completion_helper_load_r2             ; 76F2 0 208 180 03C555
crankfuel_timer_wait_loop_sll_er0:     SLL     er0                    ; 76F5 1 100 280 44D7
                RB      off(00122h).0          ; 76F7 1 100 280 C42208
                J       crankfuel_timer_wait_loop_if_eq_goto_cylinder_index_adva             ; 76FA 1 100 280 038414
sensor_check_vcal3_if_ram217_bit5_set:     JBS     off(00217h).5, sensor_check_vcal3_load_ram2be ; 76FD 0 208 180 ED1706
                JBS     off(00230h).5, sensor_check_vcal3_goto_sensor_check_clear ; 7700 0 208 180 ED3007
                J       sensor_check_vcal3_cmp_ram236             ; 7703 0 208 180 034A3B
sensor_check_vcal3_load_ram2be:     MOVB    off(002beh), #064h     ; 7706 0 208 180 C4BE9864
sensor_check_vcal3_goto_sensor_check_clear:     J       sensor_check_clear             ; 770A 0 208 180 03673B
prep_lowpower_seq_store_tmr1:     ST      A, TMR1                ; 770D 1 208 180 D536
                SLL     er0                    ; 770F 1 208 180 44D7
                DIV                            ; 7711 1 208 180 9037
                DIV                            ; 7713 1 208 180 9037
                J       prep_lowpower_seq_load_carry_ram09f_bit1             ; 7715 1 208 180 030E4B
int_crank_sync_if_ram112_bit7_set:
                J       int_crank_sync_clear_irqh_bit7             ; 771B 1 108 280 030304
crank_cycle_p4_gate_if_ram121_bit1_clr:     JBR     off(00121h).1, crank_cycle_p4_gate_goto_crank_cycle_f4_check ; 7730 0 108 280 D9210F
                J       crank_cycle_p4_gate_goto_crank_cycle_result_common ; (skeleton: fault flags are always clear)
crank_cycle_p4_gate_goto_crank_cycle_result_common:     J       crank_cycle_result_common             ; 773C 0 108 280 03D606
crank_cycle_p4_gate_goto_crank_cycle_f4_check:     J       crank_cycle_f4_check             ; 7742 0 108 280 03AF06
idle_target_final_store_call_stub_or_short_helper:     CAL     stub_or_short_helper             ; 7745 1 208 180 326B51
                VCAL    6                      ; 7748 1 208 180 16
                CLR     A                      ; 7749 1 208 180 F9
                J       idle_target_final_store_goto_idle_output_vcal5 ; (skeleton: fault flags are always clear)
idle_target_final_store_goto_idle_output_vcal5:     J       idle_output_vcal5             ; 7753 1 208 180 034B31
ignition_timing_calc_task_load_ram2cf:     LB      A, off(002cfh)         ; 7756 0 208 180 F4CF
                JEQ     ignition_timing_calc_task_set_ram222_bit6             ; 7758 0 208 180 C903
                J       ignition_timing_calc_task_load_ram29f_2             ; 775A 0 208 180 033935
ignition_timing_calc_task_set_ram222_bit6:     SB      off(00222h).6          ; 775D 0 208 180 C4221E
                JEQ     ignition_timing_calc_task_load_dp_2             ; 7760 0 208 180 C903
                J       ignition_timing_calc_task_load_ram29f             ; 7762 0 208 180 031334
ignition_timing_calc_task_load_dp_2:     MOV     DP, #00316h            ; 7765 0 208 180 621603
                JBS     off(0022fh).7, ignition_timing_calc_task_load_dp_ind_2 ; 7768 0 208 180 EF2F03
                MOV     DP, #00318h            ; 776B 0 208 180 621803
ignition_timing_calc_task_load_dp_ind_2:     L       A, [DP]                ; 776E 1 208 180 E2
                ST      A, off(0029ah)         ; 776F 1 208 180 D49A
                J       ignition_timing_calc_task_if_eq_goto_3475             ; 7771 1 208 180 036B34
ignition_timing_calc_task_clear_ram22f_bit2_2:     RB      off(0022fh).2          ; 7774 1 208 180 C42F0A
                RB      off(0022fh).1          ; 7777 1 208 180 C42F09
                J       ignition_timing_calc_task_store_ram298             ; 777A 1 208 180 03BD77
ignition_timing_calc_task_load_dp_ind_3:     L       A, [DP]                ; 777D 1 208 180 E2
                SJ      ignition_timing_calc_task_cmp_acc_10             ; 777E 1 208 180 CB02
ignition_timing_calc_task_if_lt_goto_7787:     JLT     ignition_timing_calc_task_load_imm_4             ; 7780 1 208 180 CA05
ignition_timing_calc_task_cmp_acc_10:     CMP     A, #003ffh             ; 7782 1 208 180 C6FF03
                JLT     ignition_timing_calc_task_goto_34c3             ; 7785 1 208 180 CA03
ignition_timing_calc_task_load_imm_4:     L       A, #003ffh             ; 7787 1 208 180 67FF03
ignition_timing_calc_task_goto_34c3:     J       ignition_timing_calc_task_goto_34c9             ; 778A 1 208 180 03C334
ignition_timing_calc_task_sll_acc:     SLL     A                      ; 778D 1 208 180 53
                JLT     ignition_timing_calc_task_goto_3558             ; 778E 1 208 180 CA03
                SLL     A                      ; 7790 1 208 180 53
                JGE     ignition_timing_calc_task_goto_355b             ; 7791 1 208 180 CD03
ignition_timing_calc_task_goto_3558:     J       ignition_timing_calc_task_load_imm_2             ; 7793 1 208 180 035835
ignition_timing_calc_task_goto_355b:     J       ignition_timing_calc_task_load_r1             ; 7796 1 208 180 035B35
ignition_timing_calc_task_if_ge_goto_779d:     JGE     ignition_timing_calc_task_clear_r0_2             ; 7799 1 208 180 CD02
                MOVB    r1, #0ffh              ; 779B 1 208 180 99FF
ignition_timing_calc_task_clear_r0_2:     CLRB    r0                     ; 779D 1 208 180 2015
                L       A, [DP]                ; 779F 1 208 180 E2
                J       ignition_timing_calc_task_mul_acc_2             ; 77A0 1 208 180 036435
ignition_timing_calc_task_sll_acc_2:     SLL     A                      ; 77A3 1 208 180 53
                L       A, er1                 ; 77A4 1 208 180 35
                ROL     A                      ; 77A5 1 208 180 33
                CAL     clamp_0_3ff_simple             ; 77A6 1 208 180 32C777
                J       ignition_timing_calc_task_if_ram22f_bit2_set             ; 77A9 1 208 180 036935
ignition_timing_calc_task_cmp_acc_11:     CMP     A, #003ffh             ; 77AC 1 208 180 C6FF03
                JGE     ignition_timing_calc_task_goto_3590             ; 77AF 1 208 180 CD03
                J       ignition_timing_calc_task_cmp_acc_5             ; 77B1 1 208 180 038B35
ignition_timing_calc_task_goto_3590:     J       ignition_timing_calc_task_load_imm_3             ; 77B4 1 208 180 039035
ignition_timing_calc_task_clear_ram22f_bit1:     RB      off(0022fh).1          ; 77B7 1 208 180 C42F09
ignition_timing_calc_task_clear_ram222_bit6:     RB      off(00222h).6          ; 77BA 1 208 180 C4220E
ignition_timing_calc_task_store_ram298:     ST      A, off(00298h)         ; 77BD 1 208 180 D498
                J       ignition_timing_calc_task_cmp_acc_6             ; 77BF 1 208 180 03A035
ignition_timing_calc_task_clear_ram22f_bit2_3:     RB      off(0022fh).2          ; 77C2 1 208 180 C42F0A
                SJ      ignition_timing_calc_task_clear_ram222_bit6             ; 77C5 1 208 180 CBF3
; [CG] clamp_0_3ff_simple  @0x77C7
; [CG] VERIFIED: clamps A to [0, 0x3FF] using a simpler direct-compare form than
; [CG] clamp_0_to_3ff (no register-pair bound source, just two fixed compares).
clamp_0_3ff_simple:     JLT     clamp_0_3ff_simple_load_imm             ; 77C7 1 208 180 CA05
                CMP     A, #003ffh             ; 77C9 1 208 180 C6FF03
                JLT     clamp_0_3ff_simple_return             ; 77CC 1 208 180 CA03
clamp_0_3ff_simple_load_imm:     L       A, #003ffh             ; 77CE 1 208 180 67FF03
clamp_0_3ff_simple_return:     RT                             ; 77D1 1 208 180 01
cfg_selector3_dispatch:     JBS     off(00217h).6, cfg_selector3_dispatch_goto_2b7d ; 77D2 0 208 180 EE170D
                CMP     off(00280h), #08000h   ; 77D5 0 208 180 B480C00080
                JGE     cfg_selector3_dispatch_goto_5809             ; 77DA 0 208 180 CD03
                J       cfg_selector3_dispatch_goto_5802             ; 77DC 0 208 180 036D2B
cfg_selector3_dispatch_goto_5809:     J       cfg_selector3_dispatch_cmp_acc             ; 77DF 0 208 180 030958
cfg_selector3_dispatch_goto_2b7d:     J       cfg_selector3_dispatch_goto_idle_ectvs_result1             ; 77E2 0 208 180 037D2B
                DB  043h,000h,043h,000h,043h,000h,043h,000h ; 77E5
                DB  030h,000h,043h,000h,043h,000h,043h,000h ; 77ED
                DB  043h,000h,043h,000h,030h,000h,043h,000h ; 77F5
                DB  07Ch,003h,035h,004h,0EAh,003h,09Ch,002h ; 77FD
                DB  080h,000h,09Ch,002h,07Ch,003h,05Ah,004h ; 7805
                DB  05Ah,004h,05Ah,004h,080h,000h,05Ah,004h ; 780D
coldstart_full_reset_clear_ram221_bit7:     RB      off(00221h).7          ; 7831 0 208 180 C4210F
                SB      (0011eh-00180h)[USP].4 ; 7834 0 208 180 C39E1C
                SB      off(0021eh).4          ; 7837 0 208 180 C41E1C
                J       coldstart_full_reset_orb_tcon3             ; 783A 0 208 180 03E839
idle_state_defaults_if_ram219_bit0_clr:     JBR     off(00219h).0, idle_state_defaults_goto_idle_stage_b7_store ; 783D 0 208 180 D81906
                JBR     off(0021eh).4, idle_state_defaults_goto_426c ; 7840 0 208 180 DC1E06
                J       idle_state_defaults_load_stk             ; 7843 0 208 180 032A42
idle_state_defaults_goto_idle_stage_b7_store:     J       idle_stage_b7_store             ; 7846 0 208 180 033C42
idle_state_defaults_goto_426c:     J       idle_stage_c0_load_clear_ram219_bit0             ; 7849 0 208 180 036C42
purge_counter_check:     JBR     off(00218h).0, purge_counter_check_cmp_stk ; 784C 0 208 180 D81803
                JBR     off(0021eh).4, purge_counter_check_goto_purge_result_clear ; 784F 0 208 180 DC1E08
purge_counter_check_cmp_stk:     CMP     (001b4h-00180h)[USP], #005dch ; 7852 0 208 180 B334C0DC05
                J       purge_counter_check_if_lt_goto_purge_result_clear             ; 7857 0 208 180 034343
purge_counter_check_goto_purge_result_clear:     J       purge_result_clear             ; 785A 0 208 180 035443
crank_tooth_counter_reset_if_ram113_bit0_set:
                J       crank_tooth_counter_reset_clear_ram09f_bit2             ; 786F 1 108 280 036C04
tps_hysteresis_reentry_if_ram116_bit3_clr:     JBR     off(00116h).3, tps_hysteresis_reentry_goto_postig_gate_chain2 ; 7878 0 100 280 DB1603
                JBS     off(00111h).5, tps_hysteresis_reentry_goto_postig_result_default ; 787B 0 100 280 ED1103
tps_hysteresis_reentry_goto_postig_gate_chain2:     J       postig_gate_chain2             ; 787E 0 100 280 03F218
tps_hysteresis_reentry_goto_postig_result_default:     J       postig_result_default             ; 7881 0 100 280 032619
overrev_hardcap_compare_cmp_stk:     CMPB    (001cah-00180h)[USP], #003h ; 789A 0 200 180 C34AC003
                JNE     overrev_hardcap_compare_goto_knockretard2_store             ; 789E 0 200 180 CE0B
                LB      A, #000h               ; 78A0 0 200 180 7700
                CMPB    0c1h, #028h            ; 78A2 0 200 180 C5C1C028
                JGE     overrev_hardcap_compare_goto_knockretard2_store             ; 78A6 0 200 180 CD03
                J       overrev_hardcap_compare_load_imm             ; 78A8 0 200 180 039B0C
overrev_hardcap_compare_goto_knockretard2_store:     J       knockretard2_store             ; 78AB 0 200 180 039D0C
; ================================================================================================
; Skeleton services for feature modules (called from the hook sites above; not part of stock P30)
; ================================================================================================
skel_boot_modules:
                L       A, X1                  ; keep X1
                PUSHS   A
                CLR     X1
                CLRB    A                      ; nothing is requested until a module asks
                STB     A, 001f0h[X1]          ; fuel-cut request
                STB     A, off(002fdh)         ; ignition retard request
                POPS    A
                MOV     X1, A
                J       hook_init              ; module slot: once at power-up (tail call)
skel_ign_service:
                LB      A, off(002fdh)         ; ignition retard requested by the modules, in advance-byte units
                JEQ     skel_ign_service_hook
                LB      A, off(00246h)         ; final advance (the two bytes the spark timer is built from)
                SUBB    A, off(002fdh)
                JGE     skel_ign_service_store1
                CLRB    A                      ; no further than the bottom of the scale
skel_ign_service_store1:
                STB     A, off(00246h)
                LB      A, off(00247h)
                SUBB    A, off(002fdh)
                JGE     skel_ign_service_store2
                CLRB    A
skel_ign_service_store2:
                STB     A, off(00247h)
skel_ign_service_hook:
                J       hook_ign               ; module slot (tail call)

; ================================================================================================
; Module interface: fixed addresses the feature editor relies on. See roms/p30-skeleton.md.
;
; Hook slots: 3 bytes each, RT until a module is installed; installing one writes J <module> over
; the slot. The module ends with RT (to the hook site) or with J to the next module on the same hook.
;   hook_init  5F00  once at power-up, before the main loop starts             (main-loop context)
;   hook_main  5F03  once per main-loop pass                                     (main-loop context)
;   hook_fuel  5F06  every fuel calculation, the final pulse width is word 146h  (crank interrupt)
;   hook_ign   5F09  every spark calculation, the final advance is 246h/247h     (main-loop context)
;   5F0C-5F17  four spare slots
; Rules for module code: return with RT; leave LRB, USP, SSP and the caller's register bank as found;
; A and the flags are free; save DP, X1, X2 if you use them. Use your own register bank:
;   PUSHS LRB / MOV LRB, #nnh ... POPS LRB   (banks in module RAM: 7Bh=3D8h 7Ch=3E0h 7Dh=3E8h 7Eh=3F0h 3Fh=1F8h)
;
; RAM for modules (unused by the skeleton):
;   0FEh-0FFh  tick: word, +1 every 2.048 ms (timer 1), read it, do not write it
;   1F0h       fuel-cut request: while any bit is set, fuel is cut like the rev limiter (one bit per module)
;   2FDh       ignition retard request: subtracted from the final advance (floor 0)
;   0FBh-0FDh, 1F1h-1FFh, 2F7h-2F9h, 2FEh-2FFh, 3D6h-3F9h  free for modules
; Outputs freed by the skeleton: P1.4 (dash check-engine lamp, 1 = on) and P1.5 (ECU LED).
; ================================================================================================
skel_free_start:                               ; everything from here to 5EFFh is free for modules
; @keep-begin (the hook slots are patched by modules: keep every byte)
                org 05F00h
hook_init:      RT
                NOP
                NOP
hook_main:      RT
                NOP
                NOP
hook_fuel:      RT
                NOP
                NOP
hook_ign:       RT
                NOP
                NOP
hook_spare1:    RT
                NOP
                NOP
hook_spare2:    RT
                NOP
                NOP
hook_spare3:    RT
                NOP
                NOP
hook_spare4:    RT
                NOP
                NOP
                org 05FE0h
skel_info:      DB  050h,033h,030h,02Dh,053h,04Bh,045h,04Ch,045h,054h,04Fh,04Eh ; 5FE0 'P30-SKELETON' identifies the base for the feature editor
skel_version:   DB  001h, 000h             ; 5FEC layout version 1.0
skel_free_lo:   DW  skel_free_start        ; 5FEE first free byte below the calibration
skel_free_hi:   DW  05EFFh                 ; 5FF0 last free byte below the calibration
skel_free2_lo:  DW  0764Ah                 ; 5FF2 free block above the calibration
skel_free2_hi:  DW  07FFEh                 ; 5FF4 (7FFFh is the checksum byte)
skel_hooks:     DW  hook_init              ; 5FF6 hook table
skel_hookcount: DB  8                      ; 5FF8 slots
skel_reserved:  DB  0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh ; 5FF9
; @keep-end
; ------------------------------------------------------------------------------------------------
; Calibration: kept at its stock P30 addresses (6000h-7640h), so P30 definitions and XDFs still line up.
; The gap between the end of the code above and here is free space.
; ------------------------------------------------------------------------------------------------
                org 06000h
tbl_idle_pi_clamp:       DB  000h ; 6000
boot_completion_helper_tbl:       DB  0FFh ; 6001
boot_completion_helper_tbl_2:       DB  0FFh ; 6002
boot_completion_helper_tbl_3:       DB  0FFh ; 6003
boot_completion_helper_tbl_4:       DB  000h ; 6004
boot_completion_helper_tbl_5:       DB  0FFh ; 6005
boot_completion_helper_tbl_6:       DB  0FFh ; 6006
boot_completion_helper_tbl_7:       DB  0FFh ; 6007
boot_completion_helper_tbl_8:       DB  0FFh ; 6008
boot_completion_helper_tbl_9:       DB  000h ; 6009
boot_completion_helper_tbl_10:       DB  000h ; 600A
diag_snapshot_copy_loop_tbl:       DB  000h ; 600B
boot_flag_gearpreset_alt_tbl:       DB  000h ; 600C
diag_snapshot_copy_loop_tbl_2:       DB  000h ; 600D
diag_snapshot_copy_loop_tbl_3:       DB  0FFh ; 600E
diag_mode_code_store_tbl_2:       DB  000h ; 600F
gate_255_common_tbl:       DB  000h ; 6010
idle_init_start_tbl:       DB  000h ; 6011
boot_completion_helper_tbl_11:       DB  000h ; 6012
boot_completion_helper_tbl_12:       DB  0FFh ; 6013
boot_flag_iabv_common_tbl:       DB  0FFh ; 6014
boot_flag_baro_common_tbl:       DB  0FFh ; 6015
boot_flag_baro_common_tbl_2:       DB  000h ; 6016
boot_flag_baro_common_tbl_3:       DB  000h ; 6017
boot_flag_gearpreset_alt_tbl_2:       DB  000h ; 6018
boot_flag_gearpreset_alt_tbl_3:       DB  000h ; 6019
boot_flag_gearpreset_alt_tbl_4:       DB  000h ; 601A
boot_flag_gearpreset_alt_tbl_5:       DB  0FFh ; 601B
deadtime_voltage_flag_store_tbl:       DB  00Bh,00Bh,00Bh,006h,006h,008h ; 601C
tbl_tps_custom_curve:       DB  004h,018h,004h,018h ; 6022
tbl_tps_custom_curve2:       DB  028h,040h,030h,040h,030h,040h ; 6026
to_injtimer_sub_common_tbl:       DB  0D0h,0D0h,064h,051h,0D0h,0D0h,064h,051h ; 602C
revlimit_table_select_tbl_4:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h ; 6034
                DB  044h,042h,028h,041h,000h,040h ; 603C
revlimit_table_select_tbl_5:       DB  0FFh,066h,0E6h,05Eh,0CFh,05Dh,0A1h,05Ch ; 6042
                DB  044h,04Ch,028h,041h,000h,040h ; 604A
revlimit_table_select_tbl_6:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h ; 6050
                DB  044h,040h,02Eh,040h,000h,040h ; 6058
revlimit_table_select_tbl_7:       DB  0FFh,066h,0E6h,05Eh,0CFh,05Dh,0A1h,046h ; 605E
                DB  044h,043h,02Eh,040h,000h,040h ; 6066
revlimit_table_select_tbl_8:       DB  0FFh,080h,0E6h,073h,0CFh,06Ch,0A1h,060h ; 606C
                DB  044h,04Dh,02Eh,040h,000h,040h ; 6074
IATFuelCorrect:       DB  0FFh,0E1h,09Ah,0F5h,0E1h,09Ah,0E1h,0A3h ; 607A
                DB  090h,0BAh,0AEh,087h,087h,000h,080h,034h ; 6082
                DB  052h,078h,000h,052h,078h ; 608A
PostFuelDecay:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h ; 608F
PostFuelDecay2:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h ; 6097
PostFuelDecay3:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h ; 609F
PostFuel:       DB  0FFh,000h,090h,0E6h,000h,070h,0CFh,000h ; 60A7
                DB  058h,0A1h,099h,049h,07Ah,09Ah,039h,040h ; 60AF
                DB  000h,028h,000h,000h,028h ; 60B7
o2trim_ect_offset_lookup_tbl:       DB  001h,000h,000h,001h,001h,000h,000h,002h ; 60BC
                DB  001h,000h,000h,004h ; 60C4
tbl_revlimit_cold1:       DB  0AEh,028h,0A1h,034h ; 60C8
tbl_revlimit_cold3:       DB  0B5h,02Eh,0A9h,062h ; 60CC
o2_trim_step_threshold_tbl:                 DW  00404h           ; 60D0
CloseLoopRate:       DB  043h,000h,043h,000h,043h,000h,043h,000h ; 60D2
                DB  030h,000h,043h,000h,043h,000h,043h,000h ; 60DA
                DB  043h,000h,043h,000h,030h,000h,043h,000h ; 60E2
CloseLoopGoose:       DB  07Ch,003h,035h,004h,0EAh,003h,09Ch,002h ; 60EA
                DB  080h,000h,09Ch,002h,07Ch,003h,05Ah,004h ; 60F2
                DB  05Ah,004h,05Ah,004h,080h,000h,05Ah,004h ; 60FA
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6102
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 610A
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6112
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 611A
tbl_closeloop_tps:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C8h,0D0h ; 6122
                DB  0C0h,0D8h,04Dh,0EAh,040h,0AEh,000h,0AEh ; 612A
tbl_revlimit_warm1:       DB  0EEh,000h,0A0h,030h ; 6132
ve_adjust2_gate_tbl:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C8h,0D0h ; 6136
                DB  0C0h,0D8h,04Dh,0EAh,040h,0AEh,000h,0AEh ; 613E
revlimit_table_select_tbl_9:       DB  0FFh,080h,01Fh,080h,018h,080h,013h,08Bh ; 6146
                DB  00Fh,08Bh,000h,08Bh ; 614E
to_flag_12f_5_select_ff_tbl:       DB  0FFh,094h,0D0h,094h,0A0h,088h,080h,069h ; 6152
                DB  040h,05Eh,000h,052h ; 615A
to_flag_12f_5_select_ff_tbl_2:       DB  0FFh,09Ah,0D0h,09Ah,0A0h,08Dh,080h,073h ; 615E
                DB  040h,066h,000h,05Ah ; 6166
tbl_ve_accel_1:       DB  0FFh,088h,0D0h,088h,0C0h,085h,0A0h,080h ; 616A
                DB  040h,080h,000h,080h ; 6172
tbl_ve_accel_2:       DB  0FFh,08Ah,08Eh,08Ah,072h,088h,055h,080h ; 6176
                DB  01Ch,080h,000h,080h ; 617E
tbl_knockwindow_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah ; 6182
                DB  034h,060h,028h,059h,000h,059h ; 618A
tbl_knockwindow_4:       DB  0FFh,08Eh,0A1h,08Eh,087h,071h,06Eh,05Eh ; 6190
                DB  034h,04Bh,028h,03Dh,000h,03Dh ; 6198
gear_detect_store_tbl:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,06Dh ; 619E
                DB  034h,060h,028h,04Dh,000h,04Dh ; 61A6
gear_detect_store_tbl_2:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,050h ; 61AC
                DB  034h,043h,028h,030h,000h,030h ; 61B4
CylinderIGNCorrect:       DB  080h,080h,080h,080h ; 61BA
tbl_revlimit_warm2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 61BE
                DB  000h,000h,000h,000h ; 61C6
tbl_injtimer_finalize:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 61CA
                DB  000h,000h,000h,000h ; 61D2
knock_table2d_lookup_tbl:       DB  0FFh,064h,000h,0A7h,067h,000h,093h,094h ; 61D6
                DB  000h,07Eh,0C3h,000h,069h,054h,001h,054h ; 61DE
                DB  080h,002h,000h,080h,002h ; 61E6
tbl_tipin_enrich_rpm:       DB  060h,065h,004h,000h,026h,000h,060h,020h ; 61EB
                DB  003h,000h,000h,000h,060h,020h,003h,000h ; 61F3
                DB  02Dh,000h,058h,039h,003h,000h,000h,000h ; 61FB
                DB  058h,0E8h,003h,000h,032h,000h,040h,06Bh ; 6203
                DB  003h,000h,000h,000h,040h,065h,004h,000h ; 620B
                DB  03Eh,000h,040h,084h,003h,000h,000h,000h ; 6213
                DB  040h,065h,004h,000h,04Bh,000h ; 621B
tbl_tipin_normal_enrich:       DB  0E1h,000h,0AFh,000h,004h,000h,0FAh,000h ; 6221
                DB  0AFh,000h,006h,000h,0C2h,001h,02Ch,001h ; 6229
                DB  008h,000h,013h,001h,0C8h,000h,006h,000h ; 6231
                DB  0C2h,001h,02Ch,001h,008h,000h,02Ch,001h ; 6239
                DB  0E1h,000h,008h,000h,0C2h,001h,02Ch,001h ; 6241
                DB  008h,000h,02Ch,001h,0E1h,000h,008h,000h ; 6249
                DB  0C2h,001h,02Ch,001h,008h,000h ; 6251
revlimit_table_select_tbl_10:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,0A2h,073h ; 6257
                DB  000h,040h,0D0h,000h,028h,000h,001h,000h ; 625F
                DB  000h,001h ; 6267
revlimit_table_select_tbl_11:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,0A2h,04Dh ; 6269
                DB  000h,040h,080h,000h,028h,000h,001h,000h ; 6271
                DB  000h,001h ; 6279
tbl_tipin_low:       DB  010h,0E6h,000h,002h,000h,001h,050h,0E6h ; 627B
                DB  000h,008h,000h,001h,050h,0F3h,000h,010h ; 6283
                DB  000h,001h,050h,0F3h,000h,010h,000h,001h ; 628B
tbl_revlimit_cold4:       DB  0FFh,080h,000h,080h ; 6293
revlimit_table_select_tbl_12:       DB  0FFh,08Ah,0C0h,08Ah,060h,040h,040h,026h ; 6297
                DB  020h,020h,000h,020h ; 629F
tbl_rpm_decel:       DB  0FFh,008h,000h,08Bh,008h,000h,080h,018h ; 62A3
                DB  000h,060h,050h,000h,040h,070h,000h,020h ; 62AB
                DB  0A0h,000h,000h,0C0h,000h ; 62B3
tbl_revlimit_warm3:       DB  0FFh,07Dh,000h,0CFh,07Dh,000h,0A2h,07Dh ; 62B8
                DB  000h,06Eh,07Dh,000h,000h,07Dh,000h ; 62C0
revlimit_table_select_tbl_13:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 62C7
                DB  06Eh,030h,028h,012h,000h,012h ; 62CF
revlimit_table_select_tbl_14:       DB  0FFh,090h,0E6h,080h,0CFh,070h,0A1h,040h ; 62D5
                DB  06Eh,030h,028h,012h,000h,012h ; 62DD
revlimit_table_select_tbl_15:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h ; 62E3
                DB  06Eh,020h,028h,008h,000h,008h ; 62EB
revlimit_table_select_tbl_16:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h ; 62F1
                DB  06Eh,020h,028h,008h,000h,008h ; 62F9
CrankFuel:       DB  0FFh,0A8h,061h,0F1h,0A8h,061h,0E6h,020h ; 62FF
                DB  04Eh,0CFh,010h,027h,0A1h,0DBh,01Ah,087h ; 6307
                DB  011h,012h,028h,04Dh,008h,000h,04Dh,008h ; 630F
CrankFuelComp:       DB  030h,080h,012h,05Ah ; 6317
CrankFuelMap:       DB  0FFh,080h,000h,080h ; 631B
Overrun_Resume_int:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah ; 631F
                DB  034h,060h,028h,059h,000h,059h ; 6327
Overrun_Resume_nor:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h ; 632D
                DB  034h,04Dh,028h,03Fh,000h,03Fh ; 6335
gear_detect_store_tbl_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah ; 633B
                DB  034h,060h,028h,059h,000h,059h ; 6343
gear_detect_store_tbl_4:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h ; 6349
                DB  034h,04Dh,028h,03Fh,000h,03Fh ; 6351
tbl_ignmap2_lo:       DB  0FFh,020h,0E0h,020h,0D0h,01Bh,0C0h,015h ; 6357
                DB  0A0h,00Fh,000h,00Fh ; 635F
tbl_ignmap2_hi:       DB  0FFh,018h,0E0h,018h,0D0h,013h,0C0h,00Dh ; 6363
                DB  0A0h,007h,000h,007h ; 636B
gear_detect_store_tbl_5:       DB  0FFh,000h,000h,000h ; 636F
tbl_threshold_223_1:       DB  01Eh,02Bh,0E4h,000h,06Fh,001h ; 6373
Revlimiters:       DB  01Eh,02Bh,0E2h,000h,023h,001h ; 6379
tbl_threshold_223_2:       DB  01Eh,02Bh,0E4h,000h,06Fh,001h ; 637F
tbl_threshold_223_3:       DB  01Eh,02Bh,0E2h,000h,023h,001h ; 6385
knock_table_index_tbl:       DB  033h,073h,09Ah,079h,000h,080h,066h,086h ; 638B
                DB  0CDh,08Ch,0CDh,08Ch,033h,073h,09Ah,079h ; 6393
                DB  000h,080h,066h,086h,0CDh,08Ch,0CDh,08Ch ; 639B
tbl_knock_div:       DB  07Ch,003h,0EBh,003h,05Ah,004h,0CAh,004h ; 63A3
                DB  039h,005h,039h,005h,0D5h,003h,044h,004h ; 63AB
                DB  0B3h,004h,023h,005h,093h,005h,093h,005h ; 63B3
                DB  07Ch,003h,0EBh,003h,05Ah,004h,0CAh,004h ; 63BB
                DB  039h,005h,039h,005h,0D5h,003h,044h,004h ; 63C3
                DB  0B3h,004h,023h,005h,093h,005h,093h,005h ; 63CB
knock_div_calc4_tbl:       DB  0EBh,003h,05Ah,004h,0CAh,004h,039h,005h ; 63D3
                DB  0A9h,005h,0A9h,005h,039h,005h,0A9h,005h ; 63DB
                DB  018h,006h,088h,006h,0F7h,006h,0F7h,006h ; 63E3
                DB  0EBh,003h,05Ah,004h,0CAh,004h,039h,005h ; 63EB
                DB  0A9h,005h,0A9h,005h,039h,005h,0A9h,005h ; 63F3
                DB  018h,006h,088h,006h,0F7h,006h,0F7h,006h ; 63FB
GearCustom:       DB  046h,000h,067h,000h,08Eh,000h,0B8h,000h ; 6403
crank_edge_flag_store_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 640B
                DB  0FFh,0FFh,000h,0FFh ; 6413
crank_edge_flag_store_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,080h ; 6417
newval_table3_call_tbl:       DB  0FFh,0FFh,000h,0FFh ; 641C
newval_table3_call_tbl_2:       DB  0FFh,0FFh,000h,0FFh ; 6420
vss_band_224_0_check_tbl:       DB  090h,0A0h,00Ch,00Fh,02Dh,02Fh,02Dh,02Fh ; 6424
                DB  088h,080h,088h,080h,029h,026h ; 642C
vtec_state_store2_tbl:       DB  0CAh,0CDh,0D5h,0D8h ; 6432
vtec_state_store2_tbl_2:       DB  0D6h,0DAh,0DBh,0DEh ; 6436
vtec_state_store2_tbl_3:       DB  0FFh,03Fh,0F8h,03Fh,0F0h,03Fh,0E8h,03Fh ; 643A
                DB  0D5h,03Fh,0CAh,0AEh,000h,0AEh ; 6442
vtec_state_store2_tbl_4:       DB  0FFh,03Fh,0F8h,03Fh,0F0h,03Fh,0E8h,03Fh ; 6448
                DB  0DBh,03Fh,0D6h,0AEh,000h,0AEh ; 6450
revlimit_table_select_tbl_17:       DB  0FFh,000h,000h,000h ; 6456
ignition_timing_calc_task_tbl:       DB  046h,04Bh,02Bh,036h,082h,087h,05Fh,064h ; 645A
                DB  09Ch,0A1h,00Fh,011h,010h,012h,044h,049h ; 6462
                DB  022h,025h,039h,041h,014h,016h,028h,02Dh ; 646A
                DB  05Fh,064h,07Dh,082h,014h,019h,021h,026h ; 6472
                DB  04Ah,04Ch,036h,050h,0B3h,0C0h ; 647A
ignition_timing_calc_task_tbl_2:       DB  0FFh,001h,09Fh,001h,09Bh,013h,06Eh,013h ; 6480
                DB  05Ah,013h,041h,005h,000h,005h ; 6488
ignition_timing_calc_task_tbl_3:       DB  0FFh,0FAh,0B0h,0FAh,09Bh,0FAh,082h,0FAh ; 648E
                DB  080h,09Ch,078h,092h,064h,076h,05Ah,069h ; 6496
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h ; 649E
ignition_timing_calc_task_tbl_4:       DB  0FFh,0FAh,0B0h,0FAh,08Eh,0FAh,087h,0FAh ; 64A6
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh ; 64AE
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h ; 64B6
ignition_timing_calc_task_tbl_5:       DB  0FFh,0FAh,09Ch,0FAh,09Ah,0B6h,096h,0B6h ; 64BE
                DB  085h,0A2h,078h,092h,064h,076h,05Ah,069h ; 64C6
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h ; 64CE
ignition_timing_calc_task_tbl_6:       DB  0FFh,0FAh,0A1h,0FAh,09Fh,0A3h,09Bh,0A3h ; 64D6
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh ; 64DE
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h ; 64E6
ignition_timing_calc_task_tbl_7:       DB  0FFh,014h,0B4h,014h,04Eh,014h,04Ch,003h,000h,003h ; 64EE
ignition_timing_calc_task_tbl_8:       DB  0FFh,01Bh,0B4h,01Bh,04Eh,01Bh,04Ch,006h,000h,006h ; 64F8
ignition_timing_calc_task_tbl_9:       DB  0FFh,02Ch,050h,02Ch,03Ch,01Eh,028h,01Eh ; 6502
                DB  019h,01Eh,014h,01Bh,000h,01Bh ; 650A
ignition_timing_calc_task_tbl_10:       DB  0FFh,038h,050h,038h,03Ch,030h,028h,030h ; 6510
                DB  019h,02Bh,014h,02Ah,000h,020h ; 6518
ignition_timing_calc_task_tbl_11:       DB  0FFh,033h,078h,033h,050h,02Eh,03Ch,01Dh ; 651E
                DB  028h,01Dh,014h,01Bh,000h,01Bh ; 6526
ignition_timing_calc_task_tbl_12:       DB  0FFh,03Fh,078h,03Fh,050h,03Ah,03Ch,027h ; 652C
                DB  028h,025h,014h,01Fh,000h,01Bh ; 6534
revlimit_table_select_tbl_18:       DB  0FFh,057h,0CFh,057h,0A1h,051h,06Eh,04Ch ; 653A
                DB  044h,046h,028h,040h,000h,040h ; 6542
tps_hysteresis_reentry_tbl:       DB  0FFh,0D2h,0E0h,0D2h,0C0h,0D2h,080h,0D2h ; 6548
                DB  060h,0DAh,05Ch,0FFh,000h,0FFh,000h,000h ; 6550
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6558
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6560
                DB  000h,000h,000h,000h,000h,000h ; 6568
overrev_hardcap_compare_tbl_2:       DB  0FFh,017h,0F8h,017h,0F0h,028h,0E8h,026h ; 656E
                DB  0E0h,024h,0D8h,024h,0D0h,02Dh,0C8h,031h ; 6576
                DB  0C0h,02Dh,0B0h,02Dh,0A0h,029h,098h,02Ah ; 657E
                DB  090h,02Ah,088h,026h,080h,026h,070h,020h ; 6586
                DB  060h,018h,050h,00Eh,040h,000h,000h,000h ; 658E
                DB  000h,000h,000h,000h,0FFh,017h,0F8h,017h ; 6596
                DB  0F0h,01Ch,0E8h,019h,0E0h,017h,0D8h,01Ah ; 659E
                DB  0D0h,024h,0C8h,029h,0C0h,024h,0B0h,00Fh ; 65A6
                DB  0A0h,000h,098h,000h,090h,000h,088h,000h ; 65AE
                DB  080h,000h,070h,000h,060h,000h,050h,000h ; 65B6
                DB  040h,000h,000h,000h,000h,000h,000h,000h ; 65BE
tbl_vtec_transition_retard:       DB  000h,000h,011h,055h,077h,0FFh ; 65C6
state_21a_7_dispatch2_tbl:       DB  0FFh,04Dh,008h,0CFh,04Dh,008h,0BAh,0B7h ; 65CC
                DB  007h,087h,059h,006h,02Eh,0EEh,002h,028h ; 65D4
                DB  0EEh,002h,000h,0EEh,002h ; 65DC
ignmap_alt_path_tbl:       DB  0FFh,0ABh,0E4h,0ABh,0D5h,0A2h,0C7h,0A2h ; 65E1
                DB  0B9h,0A2h,0ABh,09Eh,09Dh,091h,08Eh,08Dh ; 65E9
                DB  080h,089h,072h,089h,064h,07Ch,056h,073h ; 65F1
                DB  047h,06Fh,039h,055h,02Bh,049h,01Dh,033h ; 65F9
                DB  000h,033h,000h,033h,000h,033h,000h,033h ; 6601
                DB  000h,033h,000h,033h ; 6609
ignmap_alt_path_tbl_2:       DB  0FFh,0ABh,0F8h,0ABh,0F0h,0A2h,0E8h,0A2h ; 660D
                DB  0E0h,09Eh,0D8h,091h,0D0h,08Dh,0C8h,089h ; 6615
                DB  0C0h,089h,0B0h,07Ch,0A0h,073h,098h,071h ; 661D
                DB  090h,06Fh,088h,062h,080h,055h,070h,04Dh ; 6625
                DB  060h,049h,050h,040h,040h,033h,000h,033h ; 662D
                DB  000h,033h,000h,033h ; 6635
battery_voltage_store_tbl:       DB  0FEh,0FFh,066h,073h,0DDh,0E0h,044h,030h,078h,070h ; 6639
ZoneIndexTable1_SetB:       DB  0FFh,000h,016h,0F0h,000h,016h,0E0h,000h ; 6643
                DB  010h,0CAh,000h,012h,090h,000h,015h,070h ; 664B
                DB  000h,014h,035h,000h,00Ah,028h,000h,000h ; 6653
                DB  000h,000h,000h ; 665B
ZoneIndexTable1_SetA:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h ; 665E
                DB  013h,0CAh,000h,016h,090h,000h,01Dh,070h ; 6666
                DB  000h,018h,035h,000h,00Ah,028h,000h,000h ; 666E
                DB  000h,000h,000h ; 6676
idle_mode_dispatch_tbl:       DB  0FFh,000h,028h,0F0h,000h,028h,0E0h,000h ; 6679
                DB  01Fh,0CAh,000h,020h,090h,000h,023h,070h ; 6681
                DB  000h,020h,035h,000h,013h,028h,000h,010h ; 6689
                DB  000h,000h,010h ; 6691
ZoneIndexTable3_SetA:       DB  0FFh,000h,030h,0F0h,000h,030h,0E0h,000h ; 6694
                DB  024h,0CAh,000h,025h,090h,000h,028h,070h ; 669C
                DB  000h,023h,035h,000h,014h,028h,000h,010h ; 66A4
                DB  000h,000h,010h ; 66AC
ZoneIndexTable2_SetB:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h ; 66AF
                DB  015h,0CAh,000h,016h,090h,000h,019h,070h ; 66B7
                DB  000h,017h,035h,000h,00Dh,028h,000h,008h ; 66BF
                DB  000h,000h,008h ; 66C7
ZoneIndexTable2_SetA:       DB  0FFh,000h,026h,0F0h,000h,026h,0E0h,000h ; 66CA
                DB  01Ch,0CAh,000h,01Dh,090h,000h,022h,070h ; 66D2
                DB  000h,01Dh,035h,000h,00Eh,028h,000h,00Ah ; 66DA
                DB  000h,000h,00Ah ; 66E2
IdleVsECT:       DB  0FFh,0E2h,004h,0A1h,03Bh,005h,087h,0A2h ; 66E5
                DB  005h,06Eh,01Bh,006h,034h,00Bh,009h,028h ; 66ED
                DB  044h,00Bh,000h,044h,00Bh ; 66F5
idle_step_flag_store_tbl:       DB  0FFh,0E2h,004h,0A1h,0E2h,004h,087h,03Bh ; 66FA
                DB  005h,06Eh,0A2h,005h,034h,023h,008h,028h ; 6702
                DB  00Bh,009h,000h,00Bh,009h ; 670A
freezeframe_flag_225_7_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h ; 670F
                DB  034h,050h,028h,042h,000h,042h,0FFh,09Ah ; 6717
                DB  0A1h,09Ah,087h,083h,06Eh,073h,034h,066h ; 671F
                DB  028h,04Dh,000h,04Dh ; 6727
idle_step_flag_store_tbl_2:       DB  0FFh,092h,0A1h,092h,087h,07Ah,06Eh,073h ; 672B
                DB  034h,05Dh,028h,04Dh,000h,04Dh,0FFh,09Ah ; 6733
                DB  0A1h,09Ah,087h,086h,06Eh,083h,034h,070h ; 673B
                DB  028h,05Ah,000h,05Ah ; 6743
tbl_idle_lookup3:       DB  000h,0F0h,000h,002h,000h,004h ; 6747
tbl_idle_select_default:       DB  000h,0F0h,000h,010h,000h,00Dh ; 674D
tbl_idle_timer:       DB  000h,040h,000h,006h,000h,006h ; 6753
tbl_idle_select1:       DB  000h,0F0h,080h,000h,080h,001h ; 6759
tbl_idle_gear2:       DB  000h,000h,000h,080h,001h,000h ; 675F
idle_table_select1_tbl:       DB  0FFh,0FFh,0FFh,0FFh,000h,000h ; 6765
tbl_idle_stall:       DB  0F5h,000h,098h,000h ; 676B
idle_sub_alt_path_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h ; 676F
                DB  034h,050h,028h,042h,000h,042h ; 6777
tbl_idle_gate6:       DB  0FFh,014h,000h,0A1h,014h,000h,087h,014h ; 677D
                DB  000h,06Eh,014h,000h,034h,014h,000h,028h ; 6785
                DB  030h,000h,000h,030h,000h ; 678D
idle_sub_alt_path_tbl_2:       DB  0FFh,0FFh,0A1h,0FFh,087h,0FFh,06Eh,0FFh ; 6792
                DB  034h,0FFh,028h,0FFh,000h,0FFh ; 679A
idle_table_lookup2_tbl:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah ; 67A0
                DB  034h,006h,028h,002h,000h,002h ; 67A8
tbl_idle_pid_lo1:       DB  0FFh,0CCh,040h,0CCh,028h,0A7h,020h,097h ; 67AE
                DB  013h,080h,000h,060h ; 67B6
tbl_idle_pid_lo2:       DB  0FFh,0A9h,040h,0A9h,028h,090h,020h,080h ; 67BA
                DB  013h,068h,000h,060h ; 67C2
tbl_idle_pid_lo3:       DB  0FFh,097h,040h,097h,028h,080h,020h,071h ; 67C6
                DB  013h,04Fh,000h,04Fh ; 67CE
tbl_idle_pid_a:       DB  0FFh,0A9h,040h,0A9h,028h,090h,020h,080h ; 67D2
                DB  013h,068h,000h,060h ; 67DA
tbl_idle_pid_b:       DB  0FFh,097h,040h,097h,028h,080h,020h,071h ; 67DE
                DB  013h,04Fh,000h,04Fh ; 67E6
tbl_idle_pid_hi1:       DB  0FFh,040h,005h,0A0h,040h,002h,098h,0E0h ; 67EA
                DB  001h,080h,0D0h,000h,078h,000h,000h,000h ; 67F2
                DB  000h,000h ; 67FA
tbl_idle_pid_hi2:       DB  0FFh,090h,006h,0B0h,0E0h,003h,0A0h,020h ; 67FC
                DB  003h,080h,090h,001h,070h,000h,000h,000h ; 6804
                DB  000h,000h ; 680C
tbl_idle_pid_hi3:       DB  0FFh,000h,007h,0B0h,000h,004h,0A0h,090h ; 680E
                DB  003h,080h,0C0h,001h,060h,000h,000h,000h ; 6816
                DB  000h,000h ; 681E
tbl_idle_pid_c:       DB  0FFh,090h,006h,0B0h,0E0h,003h,0A0h,020h ; 6820
                DB  003h,080h,090h,001h,070h,000h,000h,000h ; 6828
                DB  000h,000h ; 6830
tbl_idle_pid_d:       DB  0FFh,000h,007h,0B0h,000h,004h,0A0h,090h ; 6832
                DB  003h,080h,0C0h,001h,060h,000h,000h,000h ; 683A
                DB  000h,000h ; 6842
ZoneCorrectionRowSelect_SetA:       DB  0FFh,080h,006h,0C0h,080h,006h,060h,000h ; 6844
                DB  008h,030h,000h,00Ah,000h,000h,00Dh ; 684C
ZoneCorrectionRowSelect_SetB:       DB  0FFh,080h,006h,0C0h,080h,006h,060h,000h ; 6853
                DB  008h,030h,000h,00Ah,000h,000h,00Dh ; 685B
ZoneCorrection2DTable:       DB  0FFh,0C0h,0B0h,0C0h,080h,098h,053h,080h,000h,080h ; 6862
inc_dp_step_tbl:       DB  0FFh,000h,00Eh,0D0h,000h,00Eh,0BAh,000h ; 686C
                DB  00Eh,094h,000h,00Dh,055h,080h,00Ah,042h ; 6874
                DB  000h,008h,034h,080h,007h,028h,000h,004h ; 687C
                DB  000h,000h,004h ; 6884
inc_dp_step_tbl_2:       DB  0FFh,0FFh,000h,004h,044h,00Bh,000h,004h,0C4h,009h ; 6887
                DB  080h,007h,00Bh,009h,000h,00Ah,000h,000h,000h,00Ah ; 6891
ModePageTable_SetA:       DB  030h,000h,020h,004h,000h,000h ; 689B
ModePageTable_SetB:       DB  030h,0FFh,03Fh,004h,000h,000h ; 68A1
ModeToPageTable:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,060h,000h ; 68A7
                DB  01Ch,040h,000h,006h,000h,000h,006h ; 68AF
tbl_ve_map_scalar_alt:       DB  0FFh,0FFh,03Fh,08Eh,0FFh,03Fh,080h,0FFh ; 68B6
                DB  03Fh,072h,0FFh,03Fh,055h,0FFh,03Fh,039h ; 68BE
                DB  000h,00Ah,02Ch,000h,000h,000h,000h,000h ; 68C6
tbl_ve_map_scalar:       DB  0FFh,0FFh,03Fh,0D0h,0FFh,03Fh,0C8h,000h ; 68CE
                DB  030h,0C0h,000h,026h,0A0h,000h,020h,080h ; 68D6
                DB  000h,00Ah,064h,000h,000h,000h,000h,000h ; 68DE
idle_stall_check2_tbl:       DB  0FFh,000h,010h,0D0h,000h,00Ah,0A0h,000h ; 68E6
                DB  007h,060h,000h,005h,028h,000h,003h,000h ; 68EE
                DB  000h,003h ; 68F6
idle_stall_check2_tbl_2:       DB  0FFh,060h,000h,0D0h,040h,000h,0A0h,020h ; 68F8
                DB  000h,060h,010h,000h,028h,00Ch,000h,000h ; 6900
                DB  00Ch,000h ; 6908
idle_stall_check2_tbl_3:       DB  0FFh,004h,000h,0D0h,003h,000h,0A0h,002h ; 690A
                DB  000h,060h,002h,000h,028h,002h,000h,000h ; 6912
                DB  001h,000h ; 691A
idle_stall_check2_tbl_4:       DB  0FFh,000h,000h,0CFh,000h,000h,0A0h,000h ; 691C
                DB  000h,044h,000h,000h,028h,000h,000h,000h ; 6924
                DB  000h,000h ; 692C
idle_pi_final_calc_tbl:       DB  0FFh,080h,000h,080h ; 692E
idle_pi_final_calc_tbl_2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 6932
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 693A
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6942
                DB  000h,000h,000h ; 694A
idle_pi_final_calc_tbl_3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 694D
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6955
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 695D
                DB  000h,000h,000h ; 6965
tbl_idle_gear_target:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,000h,0C0h ; 6968
                DB  080h,036h,066h,0A6h,0F0h,018h,000h,080h ; 6970
                DB  010h,00Ah,066h,066h,000h,003h,033h,053h ; 6978
                DB  0A0h,000h,066h,046h,000h,000h,0CCh,02Ch ; 6980
tbl_idle_dc:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h ; 6988
                DB  000h,008h,01Eh,085h,080h,006h,01Eh,085h ; 6990
                DB  000h,003h,085h,07Bh,000h,002h,033h,073h ; 6998
                DB  000h,001h,028h,05Ch,000h,000h,028h,05Ch ; 69A0
state_21a_7_dispatch2_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69A8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69B0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69B8
state_21a_7_dispatch2_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69BE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69C8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69D2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 69DC
tbl_iat_correct2:       DB  0FFh,0B8h,0ABh,09Ah,055h,05Ch,047h,055h ; 69E6
                DB  039h,04Dh,02Bh,03Ch,00Bh,010h,000h,010h ; 69EE
DwellBattery:       DB  0FFh,01Ch,0BCh,02Eh,0A7h,034h,092h,040h ; 69F6
                DB  07Dh,050h,068h,068h,054h,0A0h,03Fh,0D9h ; 69FE
                DB  000h,0D9h,000h,0D9h,000h,0D9h,000h,0D9h ; 6A06
                DB  000h,0D9h,000h,0D9h,000h,0D9h,000h,0D9h ; 6A0E
                DB  000h,0D9h,000h,0D9h ; 6A16
tbl_iat_correct1:       DB  0FFh,03Bh,0AAh,025h,071h,017h,038h,009h ; 6A1A
                DB  01Ch,002h,013h,000h,000h,000h ; 6A22
knockwindow_result_tbl:       DB  0FFh,000h,0AEh,000h,0A1h,02Bh,057h,015h ; 6A28
                DB  034h,000h,000h,000h ; 6A30
tbl_ignmap_idle1:       DB  0D4h,000h,0C1h ; 6A34
knockwindow_result_tbl_2:       DB  0FFh,06Fh,0E6h,067h,0BFh,049h,094h,02Ah ; 6A37
                DB  057h,011h,028h,000h,000h,000h ; 6A3F
knockwindow_result_tbl_3:       DB  0FFh,05Ah,0E6h,051h,0BFh,033h,094h,022h ; 6A45
                DB  057h,011h,028h,000h,000h,000h ; 6A4D
tbl_ignmap_idle2:       DB  077h,0C1h,064h,064h ; 6A53
knockwindow_result_tbl_4:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,000h ; 6A57
                DB  00Fh,000h,000h,000h ; 6A5F
tbl_ect_fuelcorrect:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,00Dh ; 6A63
                DB  00Fh,015h,000h,015h ; 6A6B
threshold_bank_220_6_tbl:       DB  0FFh,000h,06Ch,000h,044h,00Ch,02Eh,015h,000h,015h ; 6A6F
HiIdleIgnControl:       DB  0FFh,0FFh,000h,000h,000h,002h,000h,000h ; 6A79
                DB  0F0h,000h,015h,000h,000h,000h,000h,000h ; 6A81
IgnControl:       DB  0FFh,0FFh,000h,000h,000h,003h,015h,000h ; 6A89
                DB  0CEh,000h,015h,000h,000h,000h,000h,000h ; 6A91
dwell_scale_shift_tbl_3:       DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6A99
                DB  000h,000h,020h,02Fh,040h,03Dh,03Ah,055h ; 6AA1
                DB  063h,072h,07Ah,07Ah,000h,000h,000h,000h ; 6AA9
                DB  000h,000h ; 6AB1
clamp_result_store_tbl:       DB  024h,000h,020h,039h,04Ah,050h,055h,05Eh ; 6AB3
                DB  066h,080h,084h,088h,088h,088h ; 6ABB
flags_pack_sj_tbl:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h ; 6AC1
                DB  040h,000h,000h,000h ; 6AC9
TipinTPS:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h ; 6ACD
                DB  040h,000h,000h,000h ; 6AD5
callhelper_table_interp_lookup_tbl:       DB  0FFh,040h,0D0h,040h,0C0h,038h,0A0h,030h ; 6AD9
                DB  080h,02Ch,040h,028h,000h,028h ; 6AE1
tipin_gate_pass_tbl:       DB  0FFh,02Ah,0C0h,02Ah,0A0h,02Ah,080h,055h ; 6AE7
                DB  066h,055h,040h,02Ah,000h,015h ; 6AEF
callhelper_table_interp_lookup_tbl_2:       DB  0FFh,000h,0D8h,000h,0D0h,000h,0C0h,000h ; 6AF5
                DB  0B0h,000h,0A0h,000h,090h,000h,080h,000h ; 6AFD
                DB  000h,000h ; 6B05
flags_pack_sj_tbl_2:       DB  0FFh,000h,09Ah,00Ch,04Dh,040h,033h,02Ah ; 6B07
                DB  026h,015h,000h,000h ; 6B0F
TipinGear:       DB  040h,080h,066h,047h,047h,0BAh,07Ah,028h ; 6B13
tbl_map_sign:       DB  060h,0F0h,020h,070h ; 6B1B
ect_simulate_ramp_tbl:       DB  0DFh,0CFh,0A1h,057h,028h ; 6B1F
tbl_dcode14_lo:       DB  0C2h,000h,0FAh,03Eh,000h,047h ; 6B24
tbl_dcode14_hi:       DB  0E5h,000h,051h,03Eh,000h,019h ; 6B2A
vss_threshold_226_3_tbl:       DB  06Bh,0A9h,02Bh,062h ; 6B30
tbl_knock244_a:       DB  030h,030h,030h,025h,01Bh,01Bh,01Bh,015h,00Ch,00Ch ; 6B34
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,008h,008h,008h,008h,008h ; 6B3E
tbl_knock244_b:       DB  030h,030h,030h,030h,030h,02Ch,025h,01Bh ; 6B48
                DB  01Bh,01Bh,01Bh,01Bh,01Bh,015h ; 6B50
int_serial_rx_tbl:       DB  00Ch,00Ch,00Ch,00Ch,008h,008h,08Fh,003h ; 6B56
                DB  08Eh,003h,0D6h,003h,000h,004h,000h,004h ; 6B5E
                DB  000h,004h,000h,004h,000h,004h,09Ch,003h ; 6B66
                DB  09Dh,003h,09Eh,003h,09Fh,003h,0A0h,003h ; 6B6E
                DB  0A1h,003h,0A2h,003h,0A3h,003h,0C8h,003h ; 6B76
                DB  0C0h,003h,0A3h,000h,0C1h,003h,092h,003h ; 6B7E
                DB  0C2h,000h,000h,004h,0C3h,000h,093h,003h ; 6B86
                DB  0C6h,003h,0BFh,000h,0F5h,002h,0C6h,003h ; 6B8E
                DB  000h,004h,000h,004h,000h,004h,049h,001h ; 6B96
                DB  000h,004h,005h,003h,000h,004h,091h,003h ; 6B9E
                DB  090h,003h,05Ch,003h,043h,002h,099h,003h ; 6BA6
                DB  0CDh,000h,09Ah,003h,0F3h,002h,0F2h,002h ; 6BAE
                DB  000h,004h,000h,004h,000h,004h,000h,004h ; 6BB6
                DB  000h,004h,000h,004h,000h,004h,000h,004h ; 6BBE
                DB  0AAh,001h,0ABh,001h,0A9h,001h,0B2h,001h ; 6BC6
                DB  0B3h,001h,0B1h,001h,09Bh,003h,000h,004h ; 6BCE
                DB  000h,004h,000h,004h,000h,004h,020h,003h ; 6BD6
                DB  021h,003h,022h,003h,023h,003h,024h,003h ; 6BDE
                DB  025h,003h,026h,003h,027h,003h,028h,003h ; 6BE6
                DB  029h,003h,02Ah,003h,02Bh,003h,02Ch,003h ; 6BEE
                DB  02Dh,003h,02Eh,003h,02Fh,003h,030h,003h ; 6BF6
                DB  031h,003h,032h,003h,033h,003h,034h,003h ; 6BFE
                DB  035h,003h,036h,003h,037h,003h,038h,003h ; 6C06
                DB  039h,003h,03Ah,003h,03Bh,003h,03Ch,003h ; 6C0E
                DB  03Dh,003h,03Eh,003h,03Fh,003h,040h,003h ; 6C16
                DB  041h,003h,042h,003h,043h,003h,044h,003h ; 6C1E
                DB  045h,003h,046h,003h,047h,003h,048h,003h ; 6C26
                DB  049h,003h,04Ah,003h,04Bh,003h,04Ch,003h ; 6C2E
                DB  04Dh,003h,04Eh,003h,04Fh,003h,000h,004h ; 6C36
                DB  000h,004h,000h,004h,000h,004h,000h,004h ; 6C3E
                DB  000h,004h,000h,004h,000h,004h,094h,003h ; 6C46
                DB  095h,003h,096h,003h,097h,003h,098h,003h ; 6C4E
                DB  000h,004h,000h,004h,000h,004h,02Dh,02Dh ; 6C56
                DB  007h,006h,0FFh,0FFh,0FFh,078h,019h,019h ; 6C5E
                DB  019h,0B3h ; 6C66
dtc_scan_new_code_tbl:       DB  00Bh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh ; 6C68
                DB  0FFh,0FFh,0FFh,0FFh,02Dh,02Dh,0FFh,02Dh ; 6C70
                DB  02Dh,006h,02Dh,00Fh,00Fh,0FFh,0FFh,0FFh ; 6C78
                DB  0FFh,007h,007h,014h,0FFh,0FFh,0FFh,0FFh ; 6C80
                DB  0FFh,02Dh,02Dh,007h,006h,0FFh,0FFh,0FFh ; 6C88
                DB  078h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh ; 6C90
                DB  0B3h ; 6C98
cfgvariant_index_lookup_tbl:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah ; 6C99
                DB  00Bh,00Ch,00Ch,00Dh,00Eh,011h,000h,013h ; 6CA1
                DB  014h,015h,016h,017h,018h,000h,000h,000h ; 6CA9
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h ; 6CB1
                DB  000h,004h,008h,009h,00Fh,000h,000h,010h ; 6CB9
                DB  013h,004h,008h,009h,000h,000h,000h,000h ; 6CC1
                DB  01Dh ; 6CC9
tbl_diag_snapshot_data1:       DB  000h,092h,007h ; 6CCA
tbl_diag_snapshot_data2:       DB  0FFh,078h,019h,019h,019h ; 6CCD
tbl_crank_sync_pattern:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FEh,0FFh,0FFh ; 6CD2
                DB  0FFh,0FFh,0FFh,0FDh,0FFh,0FFh,0FFh,0FFh ; 6CDA
                DB  0FFh,0FEh,0FFh,0FFh,0FFh,0FFh,0FFh,0FDh ; 6CE2
tbl_crank_tooth_pattern:       DB  007h,008h,009h,00Ah,00Bh,000h,001h,002h,003h,004h ; 6CEA
                DB  005h,006h,007h,008h,009h,00Ah,00Bh,000h,001h,002h ; 6CF4
                DB  003h,004h,005h,006h,007h,008h,009h,00Ah,00Bh,000h ; 6CFE
rpm_decel_limit_check_tbl:       DB  053h,007h,0A9h,003h,0D4h,001h,0EAh,000h,000h,000h ; 6D08
fueltbl_sanitize_advance_tbl:       DB  000h,000h,077h,022h,0EEh,044h,077h,044h,0DDh,088h ; 6D12
                DB  0FFh,0FFh,0EEh,088h,077h,088h,0BBh,011h,0BBh,022h ; 6D1C
                DB  0FFh,0FFh,0BBh,044h,0DDh,011h,0DDh,022h,0EEh,011h ; 6D26
                DB  000h,000h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D30
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D3A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D44
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D4E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D58
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D62
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D6C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D76
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D80
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D8A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D94
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6D9E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DA8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DB2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DBC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DC6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DD0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DDA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DE4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DEE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6DF8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E02
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E0C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E16
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E20
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E2A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E34
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E3E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E48
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E52
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E5C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E66
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E70
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E7A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E84
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E8E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6E98
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EA2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EAC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EB6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EC0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6ECA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6ED4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EDE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EE8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EF2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6EFC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F06
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F10
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F1A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F24
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F2E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F38
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F42
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F4C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F56
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F60
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F6A
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F74
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F7E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F88
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F92
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F9C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FA6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FB0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FBA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FC4
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FCE
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FD8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FE2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FEC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FF6
newval_table3_call_tbl_3:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,000h ; 7000
Scaler_RpmAxis_Lo:       DB  000h,00Dh,01Ah,026h,040h,050h,060h,070h,080h,088h ; 700A
                DB  090h,0A0h,0A6h,0B0h,0C0h,0C8h,0D0h,0E0h,0F0h,000h ; 7014
Scaler_RpmAxis_Hi:       DB  000h,011h,01Ch,02Bh,039h,047h,055h,064h,072h,080h ; 701E
                DB  08Eh,095h,09Ch,0A3h,0ABh,0B9h,0C7h,0D5h,0E4h,000h ; 7028
fuelmap_base_lookup_tbl:       DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D2h ; 7032
                DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D3h ; 703C
                DB  030h,07Fh,099h,0A6h,0ACh,0B2h,0B9h,0C7h,0C6h,0D4h ; 7046
                DB  030h,080h,099h,0A7h,0ACh,0B3h,0B9h,0CAh,0C7h,0D6h ; 7050
                DB  030h,089h,0A1h,0ABh,0B1h,0B7h,0BDh,0CEh,0C5h,0D2h ; 705A
                DB  042h,090h,0A9h,0B4h,0BBh,0BEh,0C3h,0D2h,0CCh,0D7h ; 7064
                DB  045h,096h,0A9h,0B6h,0BCh,0C0h,0C5h,0D4h,0CFh,0DDh ; 706E
                DB  042h,093h,0A8h,0B5h,0BCh,0C3h,0C8h,0D8h,0CEh,0DDh ; 7078
                DB  042h,096h,0ABh,0B8h,0BFh,0C6h,0CCh,0DBh,0D4h,0DFh ; 7082
                DB  042h,096h,0ABh,0B9h,0C0h,0C4h,0CAh,0DAh,0D0h,0DFh ; 708C
                DB  03Dh,092h,0A7h,0B5h,0BEh,0C3h,0C9h,0DAh,0D2h,0E1h ; 7096
                DB  04Fh,0A1h,0BAh,0C6h,0CEh,0D3h,0D7h,0E9h,0E0h,0EEh ; 70A0
                DB  04Fh,0A0h,0B8h,0C7h,0CFh,0D4h,0DAh,0EAh,0E0h,0EDh ; 70AA
                DB  053h,09Ah,0B4h,0C0h,0C9h,0CFh,0D4h,0E4h,0E0h,0EDh ; 70B4
                DB  046h,097h,0B3h,0C0h,0CAh,0D2h,0DDh,0EDh,0E2h,0EBh ; 70BE
                DB  053h,09Dh,0B5h,0C4h,0CEh,0D4h,0DAh,0EEh,0E1h,0EEh ; 70C8
                DB  064h,0ACh,0C6h,0D3h,0DAh,0E2h,0E6h,0F9h,0EBh,0F6h ; 70D2
                DB  06Ch,0BBh,0D0h,0DBh,0EAh,0EEh,0F1h,0FFh,0F4h,0FEh ; 70DC
                DB  06Ch,0BBh,0D0h,0DBh,0EAh,0EEh,0F1h,0FFh,0F4h,0FEh ; 70E6
                DB  06Ch,0BBh,0D0h,0DBh,0EAh,0EEh,0F1h,0FFh,0F4h,0FEh ; 70F0
                DB  001h,003h,004h,005h,006h,007h,008h,008h,009h,009h ; 70FA
fuelmap_base_lookup_tbl_2:       DB  018h,046h,05Dh,05Ch,069h,075h,074h,081h ; 7104
                DB  08Dh,09Ch,018h,046h,05Dh,05Ch,069h,075h ; 710C
                DB  074h,081h,08Dh,09Ch,018h,046h,05Dh,05Ch ; 7114
                DB  069h,075h,074h,081h,08Dh,09Ch,018h,046h ; 711C
                DB  05Dh,05Ch,069h,075h,074h,081h,08Dh,09Ch ; 7124
                DB  018h,046h,05Dh,05Ch,069h,075h,074h ; 712C
fueltbl_range_check_tbl:       DB  081h,08Dh,09Ch,01Bh,04Fh,071h,06Eh,07Ch ; 7133
                DB  087h,083h,091h,08Fh,09Ch,01Bh,05Eh,081h ; 713B
                DB  07Fh,095h,0A8h,0A6h,0B6h,0B4h,0C5h,03Dh ; 7143
                DB  07Dh,09Ch,097h,0A7h,0B6h,0AFh,0BEh,0C1h ; 714B
                DB  0CFh,01Bh,05Eh,084h,083h,098h,0A7h,0A2h ; 7153
                DB  0B8h,0BBh,0C9h,020h,05Dh,086h,087h,09Ch ; 715B
                DB  0AFh,0ACh,0BEh,0BBh,0C6h,025h,06Ch,08Eh ; 7163
                DB  08Ch,09Eh,0AFh,0A8h,0B7h,0B2h,0B9h,02Ch ; 716B
                DB  073h,093h,08Eh,0A1h,0AFh,0A9h,0B9h,0B4h ; 7173
                DB  0BDh,03Bh,07Fh,0A2h,096h,0A8h,0B6h,0AFh ; 717B
                DB  0C0h,0BDh,0C7h,063h,093h,0B0h,0A3h,0B4h ; 7183
                DB  0C1h,0B7h,0C6h,0C1h,0CBh,06Eh,09Bh,0B8h ; 718B
                DB  0A7h,0B6h,0C2h,0B7h,0C5h,0C1h,0CDh,063h ; 7193
                DB  0A2h,0C3h,0B2h,0C5h,0D5h,0CBh,0DAh,0D4h ; 719B
                DB  0E2h,07Ch,0C6h,0E6h,0D2h,0E2h,0EDh,0DCh ; 71A3
                DB  0EEh,0E7h,0F4h,078h,0C3h,0E5h,0D2h,0E7h ; 71AB
                DB  0F6h,0E8h,0F8h,0EDh,0F6h,07Ah,0C4h,0EBh ; 71B3
                DB  0D9h,0ECh,0F6h,0E5h,0F4h,0EAh,0F2h,07Ah ; 71BB
                DB  0C4h,0EBh,0D9h,0ECh,0F6h,0E5h,0F4h,0EAh ; 71C3
                DB  0F2h,001h,003h,004h,006h,007h,008h,00Ah ; 71CB
                DB  00Ah,00Bh,00Bh ; 71D3
fuelmap_base_lookup_tbl_3:       DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D2h ; 71D6
                DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D3h ; 71E0
                DB  030h,07Fh,099h,0A6h,0ACh,0B2h,0B9h,0C7h,0C6h,0D4h ; 71EA
                DB  030h,080h,099h,0A7h,0ACh,0B3h,0B9h,0CAh,0C7h,0D6h ; 71F4
                DB  030h,089h,0A1h,0ABh,0B1h,0B7h,0BDh,0CEh,0C5h,0D2h ; 71FE
                DB  042h,090h,0A9h,0B4h,0BBh,0BEh,0C3h,0D2h,0CCh,0D7h ; 7208
                DB  045h,096h,0A9h,0B6h,0BCh,0C0h,0C5h,0D4h,0CFh,0DDh ; 7212
                DB  042h,093h,0A8h,0B5h,0BCh,0C3h,0C8h,0D8h,0CEh,0DDh ; 721C
                DB  042h,096h,0ABh,0B8h,0BFh,0C6h,0CCh,0DBh,0D4h,0DFh ; 7226
                DB  042h,096h,0ABh,0B9h,0C0h,0C4h,0CAh,0DAh,0D0h,0DFh ; 7230
                DB  03Dh,092h,0A7h,0B5h,0BEh,0C3h,0C9h,0DAh,0D2h,0E1h ; 723A
                DB  001h,003h,004h,005h,006h,007h,008h,008h,009h,009h ; 7244
flag_dispatch_21d_212_tbl:       DB  05Ah,05Ah,05Ah,05Ah,047h,03Bh,02Ch,01Dh ; 724E
                DB  015h,011h,05Ah,05Ah,05Ah,05Ah,049h,03Fh ; 7256
                DB  034h,024h,01Ch,018h,05Ah,05Ah,05Ah,05Ah ; 725E
                DB  04Bh,043h,03Bh,02Ch,023h,01Fh,05Ah,05Ah ; 7266
                DB  05Ah,05Ah,04Fh,047h,041h,033h,02Ah,026h ; 726E
                DB  06Fh,06Fh,06Fh,06Fh,061h,056h,04Dh,041h ; 7276
                DB  039h,035h,08Ch,08Ch,08Ch,07Bh,069h,060h ; 727E
                DB  059h,04Dh,046h,042h,097h,097h,097h,081h ; 7286
                DB  06Fh,068h,062h,057h,050h,04Ch,0A1h,0A1h ; 728E
                DB  0A1h,087h,073h,06Eh,067h,05Eh,055h,051h ; 7296
                DB  0A9h,0A9h,0A9h,08Ch,077h,071h,06Bh,064h ; 729E
                DB  05Ah,056h,0ABh,0ABh,0ABh,08Eh,07Ah,074h ; 72A6
                DB  06Eh,068h,05Eh,05Ah,0ACh,0ACh,0ACh,091h ; 72AE
                DB  07Eh,078h,072h,06Ch,062h,05Eh,0B3h,0B3h ; 72B6
                DB  0B3h,09Bh,08Ah,083h,07Ch,074h,068h,064h ; 72BE
                DB  0B5h,0B5h,0B5h,0A2h,093h,08Ah,081h,078h ; 72C6
                DB  06Dh,069h,0B8h,0B8h,0B8h,0ABh,09Dh,092h ; 72CE
                DB  089h,07Fh,075h,071h,0C0h,0C0h,0C0h,0B5h ; 72D6
                DB  0A6h,099h,08Eh,085h,07Dh,079h,0C2h,0C2h ; 72DE
                DB  0C2h,0B7h,0A8h,09Bh,090h,087h,07Dh,079h ; 72E6
                DB  0C2h,0C2h,0C2h,0B8h,0A9h,09Ch,090h,087h ; 72EE
                DB  07Dh,079h,0C4h,0C4h ; 72F6
vss_calc_skip_tbl:       DB  0C4h,0BAh,0ABh,09Ch,090h,087h,07Dh,079h ; 72FA
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,09Ch,090h,087h ; 7302
                DB  07Dh,079h,0C4h,0C4h,0C4h,0BAh,0ABh,09Ch ; 730A
                DB  090h,087h,07Dh,079h ; 7312
mode_flags_pack4_tbl:       DB  05Ah,05Ah,05Ah,05Ah,031h,01Ah,00Ch,000h,000h,000h ; 7316
                DB  05Ah,05Ah,05Ah,05Ah,039h,023h,015h,006h,000h,000h ; 7320
                DB  06Fh,06Fh,06Fh,06Fh,05Ah,040h,02Fh,023h,01Bh,017h ; 732A
                DB  097h,097h,097h,081h,06Fh,060h,04Ch,03Eh,036h,032h ; 7334
                DB  0A9h,0A9h,0A9h,08Ch,077h,06Eh,062h,055h,04Bh,046h ; 733E
                DB  0ACh,0ACh,0ACh,091h,07Eh,076h,06Ch,062h,056h,052h ; 7348
                DB  0B3h,0B3h,0B3h,09Bh,08Ah,082h,076h,069h,05Ch,058h ; 7352
                DB  0B8h,0B8h,0B8h,0ABh,09Dh,091h,082h,074h,069h,065h ; 735C
                DB  0C0h,0C0h,0C0h,0B5h,0A6h,099h,08Ah,07Ch,071h,06Dh ; 7366
                DB  0C2h,0C2h,0C2h,0B7h,0A8h,09Bh,090h,085h,07Bh,077h ; 7370
                DB  0C2h,0C2h,0C2h,0B8h,0A9h,09Ch,090h,087h,07Dh,079h ; 737A
                DB  0C2h,0C2h,0C2h,0B8h,0A9h,09Ch,090h,087h,07Dh,079h ; 7384
                DB  0C3h,0C3h,0C3h,0B9h,0AAh,09Ch,090h,087h,07Dh,079h ; 738E
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,09Ch,090h,087h,07Dh,079h ; 7398
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,09Ch,090h,087h,07Dh,079h ; 73A2
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A2h,098h,08Eh,084h,081h ; 73AC
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A3h,099h,091h,087h,083h ; 73B6
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A0h,095h,089h,07Eh,07Ah ; 73C0
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A0h,094h,088h,07Dh,079h ; 73CA
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A1h,098h,08Ch,081h,07Dh ; 73D4
flag_dispatch_21d_212_tbl_2:       DB  05Ah,05Ah,05Ah,05Ah,047h,03Bh,02Ch,01Dh,015h,011h ; 73DE
                DB  05Ah,05Ah,05Ah,05Ah,049h,03Fh,034h,024h,01Ch,018h ; 73E8
                DB  05Ah,05Ah,05Ah,05Ah,04Bh,043h,03Bh,02Ch,023h,01Fh ; 73F2
                DB  05Ah,05Ah,05Ah,05Ah,04Fh,047h,041h,033h,02Ah,026h ; 73FC
                DB  06Fh,06Fh,06Fh,06Fh,061h,056h,04Dh,041h,039h,035h ; 7406
                DB  08Ch,08Ch,08Ch,07Bh,069h,060h,059h,04Dh,046h,042h ; 7410
                DB  097h,097h,097h,081h,06Fh,068h,062h,057h,050h,04Ch ; 741A
                DB  0A1h,0A1h,0A1h,087h,073h,06Eh,067h,05Eh,055h,051h ; 7424
                DB  0A9h,0A9h,0A9h,08Ch,077h,071h,06Bh,064h,05Ah,056h ; 742E
                DB  0ABh,0ABh,0ABh,08Eh,07Ah,074h,06Eh,068h,05Eh,05Ah ; 7438
                DB  0ACh,0ACh,0ACh,091h,07Eh,078h,072h,06Ch,062h,05Eh ; 7442
ve_table_result_store_tbl:       DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 744C
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7456
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7460
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 746A
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7474
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 747E
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 7488
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 7492
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 749C
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74A6
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74B0
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74BA
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74C4
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74CE
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74D8
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 74E2
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 74EC
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 74F6
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,09Bh,09Bh,09Bh ; 7500
                DB  08Eh,08Eh,08Eh,08Eh,097h,097h,097h,09Bh,09Bh,09Bh ; 750A
ve_result_flag_store_tbl:       DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7514
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 751E
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7528
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 7532
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 753C
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 7546
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 7550
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 755A
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 7564
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h ; 756E
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7578
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7582
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 758C
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 7596
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 75A0
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h ; 75AA
                DB  08Eh,08Eh,08Eh,097h,097h,097h,097h,09Bh,09Bh,09Bh ; 75B4
                DB  08Eh,08Eh,08Eh,097h,097h,09Bh,09Bh,09Bh,09Bh,09Eh ; 75BE
                DB  08Eh,08Eh,08Eh,097h,09Bh,09Bh,09Bh,09Bh,09Eh,09Eh ; 75C8
                DB  08Eh,08Eh,097h,09Bh,09Bh,09Bh,09Bh,09Bh,09Eh,09Eh ; 75D2
crank_edge_flag_store_tbl_3:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 75DC
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 75E6
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 75F0
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 75FA
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 7604
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 760E
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 7618
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 7622
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 762C
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 7636
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 7640
; ------------------------------------------------------------------------------------------------
; Checksum: the 8-bit sum of the whole image must be 0 (the ROM checks it while running, BRK 48h).
; This byte, at a fixed address, is what the build (and the feature editor) adjusts.
; ------------------------------------------------------------------------------------------------
                org 07FFFh
checksum_fix:   DB  00Fh ; CHECKSUM correction
