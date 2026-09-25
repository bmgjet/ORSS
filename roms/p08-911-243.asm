;==================================================================================================
; p08-911-243.asm -- annotation pass (labels/comments only; firmware bytes unchanged)
; Verified: assembles with asm662 to exactly the bytes recorded in the original
; "; ADDR DD LRB USP HEX" trailers (see ANNOTATION_REPORT.md).
; Label sources: HTS115-Full-Comments.asm (matched code), CromeGold.asm, Neptune.asm, HD2_7_2_0_1.asm, p30.asm (secondary, where noted in the
; rename log), otherwise structural names built from what the labelled code does:
;   <context>_<action>   context = nearest named routine that reaches this block,
;                        action  = first instruction (load_/store_/cmp_/if_<ram>_b<n>_set/goto_/call_...)
;   ramXXX = RAM address XXXh, stk = user-stack frame slot.
; Comment lines tagged [H] were carried over from HTS115 (comments credited to bmgjet) onto code that
; is instruction-for-instruction identical to the HTS115 code they describe. Lines tagged [CG], [N],
; [HD2], [P30] were carried the same way from CromeGold.asm, Neptune.asm, HD2_7_2_0_1.asm, p30.asm.
; Items that could not be determined are listed in p08-911-243_unresolved.txt.
;==================================================================================================
                org 0000h
int_start_vec:            DW  int_start        ; 0000 ED24
int_break_vec:            DW  int_break        ; 0002 F424
int_WDT_vec:              DW  int_WDT          ; 0004 DC24
int_NMI_vec:              DW  int_NMI          ; 0006 3C00
int_INT0_vec:             DW  int_INT0         ; 0008 E901
int_serial_rx_vec:        DW  int_serial_rx    ; 000A 1302
int_serial_tx_vec:        DW  int_spurious_irq_trap    ; 000C D624
int_serial_rx_BRG_vec:    DW  int_serial_rx_BRG; 000E ED03
int_timer_0_overflow_vec: DW  int_spurious_irq_trap    ; 0010 D624
int_timer_0_vec:          DW  int_timer_0      ; 0012 9400
int_timer_1_overflow_vec: DW  int_spurious_irq_trap    ; 0014 D624
int_timer_1_vec:          DW  int_timer_1      ; 0016 2201
int_timer_2_overflow_vec: DW  int_timer_2_overflow; 0018 F302
int_timer_2_vec:          DW  int_timer_2      ; 001A 5B01
int_timer_3_overflow_vec: DW  int_spurious_irq_trap    ; 001C D624
int_timer_3_vec:          DW  int_timer_3      ; 001E 1103
int_a2d_finished_vec:     DW  int_spurious_irq_trap    ; 0020 D624
int_PWM_timer_vec:        DW  int_PWM_timer    ; 0022 3403
int_serial_tx_BRG_vec:    DW  int_spurious_irq_trap    ; 0024 D624
int_INT1_vec:             DW  int_INT1         ; 0026 7903
vcal_0_vec:               DW  vcal_0           ; 0028 9458
vcal_1_vec:               DW  vcal_1           ; 002A 6E58
vcal_2_vec:               DW  vcal_2           ; 002C 8158
vcal_3_vec:               DW  vcal_3           ; 002E AE28
vcal_4_vec:               DW  vcal_4           ; 0030 5859
vcal_5_vec:               DW  vcal_5           ; 0032 6359
vcal_6_vec:               DW  vcal_6           ; 0034 AD59
vcal_7_vec:               DW  vcal_7           ; 0036 A659
code_start:     DB  000h,01Ch,04Ah,001h ; 0038
; [H] NMI Interrupt Service Routine
; [H] NMI handler: on entry, tests+clears edge-detect bit 00230h.7; if it had just
; [H] gone 1->0, latches DP into 00084h[X1] (some kind of "last DP at NMI" snapshot).
; [H] Then runs two short busy-wait/poll loops (DP as a down-counter; P4.1 pin poll),
; [H] and unconditionally reprograms a block of peripheral control registers
; [H] (P2, TCON0, ADSCAN/ADSEL, IE, TCON1, IRQ, P4SF, TM1, SBYCON, STPACP, sysFlags_b7.1)
; [H] before a final check on trapReasonCode that either forces trapReasonCode=047h or falls into BRK.
; [H] NOTE: confirmed against the OKI MSM66207 datasheet -- SBYCON is the Standby Control Register
; [H] and STPACP is the Stop Code Acceptor, so this reprogramming pass is indeed preparing to enter
; [H] a STOP/HALT low-power mode (register list above also checks out: P2/TCON0/TCON1/P4SF/TM1 are
; [H] the port and timer control/data registers, ADSCAN/ADSEL the A/D scan and channel-select
; [H] registers, IE/IRQ the interrupt enable/request registers -- all named per the datasheet's SFR
; [H] table). Mechanism is confirmed; the specific reason this NMI path enters standby (vs. e.g.
; [H] int_break's) is not derived here.
int_NMI:        CLR     PSW                    ; 003C 0 ??? ??? B50415
                MOV     LRB, #00041h           ; 003F 0 208 ??? 574100 ; [H] local register base = #00041h (base address 0x0208)
                RB      off(00230h).7          ; 0042 0 208 ??? C4300F ; [H] test-and-reset edge-detect bit 00230h.7
                JEQ     int_NMI_goto_7a85             ; 0045 0 208 ??? C904 ; [H] skip snapshot if bit was already 0
                L       A, DP                  ; 0047 1 208 ??? 42 ; [H] bit just transitioned 1->0: snapshot DP
                ST      A, 00084h[X1]          ; 0048 1 208 ??? D08400 ; [H] ...into 00084h[X1]
int_NMI_goto_7a85:     J       int_NMI_load_dp             ; 004B 1 208 ??? 03857A
nmi_poll_p4_1:     MB      C, P4.1                ; 004E 1 208 ??? C52C29 ; [H] sample pin P4.1 into carry
                JGE     nmi_check_0f5             ; 0051 1 208 ??? CD38 ; [H] JGE branches on Carry=0 (arch.ml) -> as soon as P4.1 reads 0, jump ahead immediately
                JRNZ    DP, nmi_poll_p4_1         ; 0053 1 208 ??? 30F9 ; [H] else (P4.1 still 1) keep polling until DP counts out, then fall through anyway
                MOVB    P2, #0ffh              ; 0055 1 208 ??? C52498FF ; [H] drive P2 all-high
                RB      TCON0.2                ; 0059 1 208 ??? C5400A ; [H] clear TCON0.2
                SB      TCON0.2                ; 005C 1 208 ??? C5401A ; [H] ...then set TCON0.2 (pulse it)
                CLRB    A                      ; 005F 0 208 ??? FA
                STB     A, ADSCAN              ; 0060 0 208 ??? D558 ; [H] stop A/D scan
                STB     A, ADSEL               ; 0062 0 208 ??? D559 ; [H] clear A/D channel select
                MOV     IE, #00040h            ; 0064 0 208 ??? B51A984000 ; [H] mask interrupt-enable to one source
                MOVB    TCON1, #0e0h           ; 0069 0 208 ??? C54198E0
                CLR     IRQ                    ; 006D 0 208 ??? B51815 ; [H] clear pending IRQ flags
                SB      P4SF.1                 ; 0070 0 208 ??? C52E19
                MOV     TM1, #0ffffh           ; 0073 0 208 ??? B53498FFFF ; [H] reload timer1 to max (effectively stop it counting down soon)
                SB      TCON1.4                ; 0078 0 208 ??? C5411C
                SB      SBYCON.2               ; 007B 0 208 ??? C5101A ; [H] standby-control bit set (see routine note above)
                LB      A, #005h               ; 007E 0 208 ??? 7705
; [N] STPACP = "Stop Code Acceptor" per the MSM66207 datasheet -- not a clock prescaler. Writing
; [N] N then N<<1 (5, then 10) is the write-unlock sequence this register requires before STOP/HALT
; [N] mode will actually be entered; it's a safety interlock against accidental entry, not a divider.
                STB     A, STPACP              ; 0080 0 208 ??? D513 ; [H] stop-code-acceptor unlock write, step 1: N=5
                SLLB    A                      ; 0082 0 208 ??? 53 ; [H] ...step 2: N<<1=10
                STB     A, STPACP              ; 0083 0 208 ??? D513 ; [H] unlock write, step 2
                SB      SBYCON.0               ; 0085 0 208 ??? C51018 ; [H] standby-control bit 0 set (likely the actual STOP-mode trigger)
                RB      0b7h.1                 ; 0088 0 208 ??? C5B709
nmi_check_0f5:     LB      A, 0f5h                ; 008B 0 208 ??? F5F5 ; [H] read watchdog/status-like byte trapReasonCode
                JNE     nmi_brk             ; 008D 0 208 ??? CE04 ; [H] if nonzero, fall straight to BRK
                MOVB    0f5h, #047h            ; 008F 0 208 ??? C5F59847 ; [H] else stamp trapReasonCode with sentinel 047h first
nmi_brk:     BRK                            ; 0093 0 208 ??? FF ; [H] forces a BRK -> re-enters int_break (full reinit),
; [H] Timer 0 Interrupt Service Routine
; [H] involves a lot of bit-twiddling of r6(aka 00116h), r7 (00117h) and 00197h
; [H] also affects er0-er2 (00110h-00115h)
; [H] ultimately changes the state of Port2 pins 3,2,1 and 0
; [H] however, the exact behavior is still unclear
int_timer_0:    MOV     LRB, #00022h           ; 0094 0 110 ??? 572200
; [H] --- Timer0 ISR: bit-shifts a value (r6, 16 bits across er0/er1/er2 chain) out one bit per
; [H] timer period, reloading TMR0 for the next bit's timing, tracking bit count in r7 (0-15,
; [H] matching a 16-bit shift register), accumulating into off(00197h) and driving P2 with the
; [H] result. Reads as a software bit-banged serial or pulse-train output; no calibration anchors
; [H] to identify the specific protocol/signal.
                ANDB    TCON0, #0fbh           ; 0097 0 110 ??? C540D0FB
                CMPB    r7, #00fh              ; 009B 0 110 ??? 27C00F
                JEQ     timer0_return             ; 009E 0 110 ??? C93F
                L       A, er0                 ; 00A0 1 110 ??? 34
                JNE     timer0_bit_accumulate             ; 00A1 1 110 ??? CE3D
                L       A, er1                 ; 00A3 1 110 ??? 35
                JEQ     timer0_final_bit_check             ; 00A4 1 110 ??? C953
                ADD     TMR0, A                ; 00A6 1 110 ??? B53281
                LB      A, r6                  ; 00A9 0 110 ??? 7E
                MB      C, ACC.7               ; 00AA 0 110 ??? C5062F
                ROLB    r6                     ; 00AD 0 110 ??? 26B7
                ORB     A, r6                  ; 00AF 0 110 ??? 6E
                ANDB    A, #00fh               ; 00B0 0 110 ??? D60F
                ORB     r7, A                  ; 00B2 0 110 ??? 27E1
                ORB     off(0018fh), A         ; 00B4 0 110 ??? C48FE1
                LB      A, r6                  ; 00B7 0 110 ??? 7E
                SLLB    A                      ; 00B8 0 110 ??? 53
                ROLB    r6                     ; 00B9 0 110 ??? 26B7
                MOV     er0, er2               ; 00BB 0 110 ??? 4648
                L       A, #00001h             ; 00BD 1 110 ??? 670100
                ST      A, er1                 ; 00C0 1 110 ??? 89
timer0_bitshift_loop:     ST      A, er2                 ; 00C1 1 110 ??? 8A
                L       A, er0                 ; 00C2 1 110 ??? 34
                JNE     timer0_bit_shift_right             ; 00C3 1 110 ??? CE10
                L       A, er1                 ; 00C5 1 110 ??? 35
                JEQ     timer0_bit_invert             ; 00C6 1 110 ??? C910
                LB      A, r6                  ; 00C8 0 110 ??? 7E
                SRLB    A                      ; 00C9 0 110 ??? 63
                SRLB    A                      ; 00CA 0 110 ??? 63
                SRLB    A                      ; 00CB 0 110 ??? 63
                ORB     A, r6                  ; 00CC 0 110 ??? 6E
timer0_bit_output:     ORB     A, off(0018fh)         ; 00CD 0 110 ??? E78F
                ANDB    A, #00fh               ; 00CF 0 110 ??? D60F
                ORB     P2, A                  ; 00D1 0 110 ??? C524E1
                RTI                            ; 00D4 0 110 ??? 02
timer0_bit_shift_right:     LB      A, r6                  ; 00D5 0 110 ??? 7E
                SJ      timer0_bit_output             ; 00D6 0 110 ??? CBF5
timer0_bit_invert:     LB      A, r6                  ; 00D8 0 110 ??? 7E
                RORB    A                      ; 00D9 0 110 ??? 43
                XORB    A, #0ffh               ; 00DA 0 110 ??? F6FF
                J       timer0_bit_output             ; 00DC 0 110 ??? 03CD00
timer0_return:     RTI                            ; 00DF 0 110 ??? 02
timer0_bit_accumulate:     ADD     TMR0, A                ; 00E0 1 110 ??? B53281
                LB      A, r6                  ; 00E3 0 110 ??? 7E
                ANDB    A, #00fh               ; 00E4 0 110 ??? D60F
                ORB     r7, A                  ; 00E6 0 110 ??? 27E1
                ORB     off(0018fh), A         ; 00E8 0 110 ??? C48FE1
                LB      A, r6                  ; 00EB 0 110 ??? 7E
                SLLB    A                      ; 00EC 0 110 ??? 53
                ROLB    r6                     ; 00ED 0 110 ??? 26B7
                MOV     er0, er1               ; 00EF 0 110 ??? 4548
                MOV     er1, er2               ; 00F1 0 110 ??? 4649
                L       A, #00001h             ; 00F3 1 110 ??? 670100
                J       timer0_bitshift_loop             ; 00F6 1 110 ??? 03C100
timer0_final_bit_check:     L       A, er2                 ; 00F9 1 110 ??? 36
                JEQ     timer0_sequence_done             ; 00FA 1 110 ??? C91F
                ADD     TMR0, A                ; 00FC 1 110 ??? B53281
                LB      A, r6                  ; 00FF 0 110 ??? 7E
                MB      C, ACC.0               ; 0100 0 110 ??? C50628
                RORB    A                      ; 0103 0 110 ??? 43
                STB     A, r6                  ; 0104 0 110 ??? 8E
                XORB    A, #0ffh               ; 0105 0 110 ??? F6FF
                ANDB    A, #00fh               ; 0107 0 110 ??? D60F
                ORB     r7, A                  ; 0109 0 110 ??? 27E1
                ORB     off(0018fh), A         ; 010B 0 110 ??? C48FE1
                LB      A, r6                  ; 010E 0 110 ??? 7E
                ANDB    A, #00fh               ; 010F 0 110 ??? D60F
timer0_sequence_reset:     ORB     P2, A                  ; 0111 0 110 ??? C524E1
                L       A, #00001h             ; 0114 1 110 ??? 670100
                ST      A, er0                 ; 0117 1 110 ??? 88
                ST      A, er1                 ; 0118 1 110 ??? 89
                ST      A, er2                 ; 0119 1 110 ??? 8A
                RTI                            ; 011A 1 110 ??? 02
timer0_sequence_done:     LB      A, #00fh               ; 011B 0 110 ??? 770F
                STB     A, r7                  ; 011D 0 110 ??? 8F
                STB     A, off(0018fh)         ; 011E 0 110 ??? D48F
                SJ      timer0_sequence_reset             ; 0120 0 110 ??? CBEF
; [H] Timer 1 Interrupt Service Routine
; [H] toggles (TCON1).3, (000b6h).5
; [H] modifies er1, er2, r6, TMR1
; [H] also influenced by er0
; [H] This routine seems to systematically modify TMR1 based on er0, er1 and ADCR4
; [H] (what is connected to ADC channel 4??)
int_timer_1:    MOV     LRB, #00013h           ; 0122 0 098 ??? 571300
                JBR     off(TCON1).3, timer1_tmr1_reload ; 0125 0 098 ??? DB4124
                RB      off(000b6h).5          ; 0128 0 098 ??? C4B60D
                JNE     timer1_check_start             ; 012B 0 098 ??? CE13
                CMP     er1, #0064ah           ; 012D 0 098 ??? 45C04A06
                JLT     timer1_check_start             ; 0131 0 098 ??? CA0D
                ORB     off(000b6h), #020h     ; 0133 0 098 ??? C4B6E020
                L       A, #003b6h             ; 0137 1 098 ??? 67B603
                SUB     er1, A                 ; 013A 1 098 ??? 45A1
                ADD     off(TMR1), A           ; 013C 1 098 ??? B43681
                RTI                            ; 013F 1 098 ??? 02
timer1_check_start:     ANDB    off(TCON1), #0f7h      ; 0140 0 098 ??? C441D0F7
                L       A, off(ADCR4)          ; 0144 1 098 ??? E468
                ST      A, er2                 ; 0146 1 098 ??? 8A
                ADD     off(TMR1), off(0009ah) ; 0147 1 098 ??? B436839A
                RTI                            ; 014B 1 098 ??? 02
timer1_tmr1_reload:     ORB     off(TCON1), #008h      ; 014C 0 098 ??? C441E008
                INCB    r6                     ; 0150 0 098 ??? AE
                L       A, #00a00h             ; 0151 1 098 ??? 67000A
                SUB     A, er0                 ; 0154 1 098 ??? 28
                ST      A, er1                 ; 0155 1 098 ??? 89
                ADD     off(TMR1), off(00098h) ; 0156 1 098 ??? B4368398
                RTI                            ; 015A 1 098 ??? 02
; [H] Timer 2 Interrupt Service Routine
int_timer_2:    MOV     LRB, #00014h           ; 015B 0 0A0 ??? 571400
; [H] --- Timer2 ISR (0x160-0x1E9+): reschedules TMR2/TMR3 relative to each other and TM3,
; [H] tracking a small state counter (r0/r2, states 0-4/5) and TCON3 bits. Likely supporting
; [H] crank/cam signal period measurement alongside int_INT1's tooth-decode logic (references
; [H] TRNSIT and sysFlags_b7.2, both touched there too). No calibration anchors; named at the
; [H] mechanism level.
                LB      A, r2                  ; 015E 0 0A0 ??? 7A
                CMPB    A, #003h               ; 015F 0 0A0 ??? C603
                JGE     timer2_state1_check             ; 0161 0 0A0 ??? CD2A
                ADDB    A, #001h               ; 0163 0 0A0 ??? 8601
                JBS     off(ACC).0, timer2_state_dispatch ; 0165 0 0A0 ??? E80604
                MOV     off(000bah), off(ADCR6) ; 0168 0 0A0 ??? B46C7CBA
timer2_state_dispatch:     CMPB    A, r0                  ; 016C 0 0A0 ??? 48
                JEQ     timer3_reload_add             ; 016D 0 0A0 ??? C94E
                JLT     timer3_reload_dec             ; 016F 0 0A0 ??? CA04
timer2_tcon3_clear:     ANDB    off(TCON3), #0fbh      ; 0171 0 0A0 ??? C443D0FB
timer3_reload_dec:     L       A, off(TM3)            ; 0175 1 0A0 ??? E43C
                SUB     A, #00001h             ; 0177 1 0A0 ??? A60100
                ST      A, off(TMR3)           ; 017A 1 0A0 ??? D43E
timer2_irq_clear:     ANDB    off(IRQH), #0f7h       ; 017C 1 0A0 ??? C419D0F7
                ORB     off(IRQ), #008h        ; 0180 1 0A0 ??? C418E008
                RB      off(TRNSIT).0          ; 0184 1 0A0 ??? C44608
                JEQ     timer2_return             ; 0187 1 0A0 ??? C903
                SB      off(000b7h).2          ; 0189 1 0A0 ??? C4B71A
timer2_return:     RTI                            ; 018C 1 0A0 ??? 02
timer2_state1_check:     JEQ     timer2_state2_check             ; 018D 0 0A0 ??? C90E
                JBR     off(ACC).0, timer2_tcon3_check2 ; 018F 0 0A0 ??? D80637
                JBS     off(000a0h).3, timer2_tcon3_clear ; 0192 0 0A0 ??? EBA0DC
                CLRB    A                      ; 0195 0 0A0 ??? FA
                ORB     off(TCON3), #004h      ; 0196 0 0A0 ??? C443E004
                J       timer2_state_dispatch             ; 019A 0 0A0 ??? 036C01
timer2_state2_check:     LB      A, r0                  ; 019D 0 0A0 ??? 78
                ADDB    A, #001h               ; 019E 0 0A0 ??? 8601
                CMPB    A, #005h               ; 01A0 0 0A0 ??? C605
                JGE     timer2_er3_calc             ; 01A2 0 0A0 ??? CD15
                ANDB    off(TCON3), #0fbh      ; 01A4 0 0A0 ??? C443D0FB
                L       A, er2                 ; 01A8 1 0A0 ??? 36
                CMP     A, #0001fh             ; 01A9 1 0A0 ??? C61F00
                JGE     timer2_tmr2_add             ; 01AC 1 0A0 ??? CD03
                L       A, #0001fh             ; 01AE 1 0A0 ??? 671F00
timer2_tmr2_add:     ADD     A, off(TMR2)           ; 01B1 1 0A0 ??? 873A
                J       timer3_reload_store             ; 01B3 1 0A0 ??? 03E001
timer2_tcon3_check:     JBS     off(TCON3).3, timer3_reload_dec ; 01B6 0 0A0 ??? EB43BC
timer2_er3_calc:     L       A, off(TMR2)           ; 01B9 1 0A0 ??? E43A
                ADD     A, er2                 ; 01BB 1 0A0 ??? 0A
                ST      A, er3                 ; 01BC 1 0A0 ??? 8B
timer3_reload_add:     L       A, off(TMR2)           ; 01BD 1 0A0 ??? E43A
                ADD     A, off(000e8h)         ; 01BF 1 0A0 ??? 87E8
                ST      A, off(TMR3)           ; 01C1 1 0A0 ??? D43E
                ANDB    off(TCON3), #0f7h      ; 01C3 1 0A0 ??? C443D0F7
                SJ      timer2_irq_clear             ; 01C7 1 0A0 ??? CBB3
timer2_tcon3_check2:     JBS     off(TCON3).2, timer2_tcon3_check ; 01C9 0 0A0 ??? EA43EA
                L       A, off(TM3)            ; 01CC 1 0A0 ??? E43C
                SUB     A, off(TMR2)           ; 01CE 1 0A0 ??? A73A
                ADD     A, #00006h             ; 01D0 1 0A0 ??? 860600
                CMP     A, er2                 ; 01D3 1 0A0 ??? 4A
                JGE     timer3_reload_alt             ; 01D4 1 0A0 ??? CD05
                L       A, off(TMR2)           ; 01D6 1 0A0 ??? E43A
                ADD     A, er2                 ; 01D8 1 0A0 ??? 0A
                SJ      timer3_reload_store             ; 01D9 1 0A0 ??? CB05
timer3_reload_alt:     L       A, off(TM3)            ; 01DB 1 0A0 ??? E43C
                ADD     A, #00004h             ; 01DD 1 0A0 ??? 860400
timer3_reload_store:     ST      A, off(TMR3)           ; 01E0 1 0A0 ??? D43E
                ORB     off(TCON3), #008h      ; 01E2 1 0A0 ??? C443E008
                J       timer2_irq_clear             ; 01E6 1 0A0 ??? 037C01
; [H] Ext. Interrupt 0 Service Routine
int_INT0:       L       A, 0fah                ; 01E9 1 ??? ??? E5FA
                ST      A, IE                  ; 01EB 1 ??? ??? D51A
                L       A, TM2                 ; 01ED 1 ??? ??? E538
                ORB     PSWH, #001h            ; 01EF 1 ??? ??? A2E001
                MOV     LRB, #00015h           ; 01F2 1 0A8 ??? 571500
                JBS     off(ACCH).7, int_int0_edge_check ; 01F5 1 0A8 ??? EF0708
                JBR     off(IRQH).0, int_int0_edge_check ; 01F8 1 0A8 ??? D81905
                INCB    r3                     ; 01FB 1 0A8 ??? AB
                ORB     off(000b6h), #002h     ; 01FC 1 0A8 ??? C4B6E002
int_int0_edge_check:     XCHG    A, er0                 ; 0200 1 0A8 ??? 4410
                ST      A, er2                 ; 0202 1 0A8 ??? 8A
                CLRB    A                      ; 0203 0 0A8 ??? FA
                XCHGB   A, r3                  ; 0204 0 0A8 ??? 2310
                STB     A, r2                  ; 0206 0 0A8 ??? 8A
                ORB     off(000b6h), #004h     ; 0207 0 0A8 ??? C4B6E004
                L       A, off(000f8h)         ; 020B 1 0A8 ??? E4F8
                ANDB    PSWH, #0feh            ; 020D 1 0A8 ??? A2D0FE
                ST      A, off(IE)             ; 0210 1 0A8 ??? D41A
                RTI                            ; 0212 1 0A8 ??? 02
int_serial_rx:  L       A, 0fah                ; 0213 1 ??? ??? E5FA
                ST      A, IE                  ; 0215 1 ??? ??? D51A
                MOV     PSW, #00102h           ; 0217 1 ??? ??? B504980201
                MOV     LRB, #0007eh           ; 021C 1 3F0 ??? 577E00
                JBR     off(00356h).1, int_serial_rx_clear_acc ; 021F 1 3F0 ??? D9567B
                RB      off(00356h).6          ; 0222 1 3F0 ??? C4560E
                JEQ     int_serial_rx_load_r7             ; 0225 1 3F0 ??? C92E
                CLR     A                      ; 0227 1 3F0 ??? F9
                LB      A, r5                  ; 0228 0 3F0 ??? 7D
                CMPB    A, #002h               ; 0229 0 3F0 ??? C602
                JEQ     int_serial_rx_load_r2             ; 022B 0 3F0 ??? C91F
                CMPB    A, r2                  ; 022D 0 3F0 ??? 4A
                JGE     int_serial_rx_if_ne_goto_0244             ; 022E 0 3F0 ??? CD1F
                ADDB    A, r3                  ; 0230 0 3F0 ??? 0B
                L       A, ACC                 ; 0231 1 3F0 ??? E506
                SLL     A                      ; 0233 1 3F0 ??? 53
                ADD     A, #int_serial_rx_tbl           ; 0234 1 3F0 ??? 86126E
                MOV     DP, A                  ; 0237 1 3F0 ??? 52
                LC      A, [DP]                ; 0238 1 3F0 ??? 92A8
                MOV     DP, A                  ; 023A 1 3F0 ??? 52
                LB      A, [DP]                ; 023B 0 3F0 ??? F2
int_serial_rx_addb_r6:     ADDB    r6, A                  ; 023C 0 3F0 ??? 2681
int_serial_rx_store_stbuf:     STB     A, STBUF               ; 023E 0 3F0 ??? D551
                INCB    r5                     ; 0240 0 3F0 ??? AD
                SB      off(00356h).6          ; 0241 0 3F0 ??? C4561E
int_serial_rx_load_ram0f8:     L       A, 0f8h                ; 0244 1 3F0 ??? E5F8
                ANDB    PSWH, #0feh            ; 0246 1 3F0 ??? A2D0FE
                ST      A, IE                  ; 0249 1 3F0 ??? D51A
                RTI                            ; 024B 1 3F0 ??? 02
int_serial_rx_load_r2:     LB      A, r2                  ; 024C 0 3F0 ??? 7A
                SJ      int_serial_rx_addb_r6             ; 024D 0 3F0 ??? CBED
int_serial_rx_if_ne_goto_0244:     JNE     int_serial_rx_load_ram0f8             ; 024F 0 3F0 ??? CEF3
                CLRB    A                      ; 0251 0 3F0 ??? FA
                SUBB    A, r6                  ; 0252 0 3F0 ??? 2E
                SJ      int_serial_rx_store_stbuf             ; 0253 0 3F0 ??? CBE9
int_serial_rx_load_r7:     LB      A, r7                  ; 0255 0 3F0 ??? 7F
                JEQ     int_serial_rx_load_r0             ; 0256 0 3F0 ??? C91D
                LB      A, r5                  ; 0258 0 3F0 ??? 7D
                CMPB    A, #001h               ; 0259 0 3F0 ??? C601
                JEQ     int_serial_rx_load_srbuf             ; 025B 0 3F0 ??? C922
                ADDB    A, #001h               ; 025D 0 3F0 ??? 8601
                CMPB    A, r2                  ; 025F 0 3F0 ??? 4A
                JEQ     int_serial_rx_load_srbuf_2             ; 0260 0 3F0 ??? C922
                LB      A, SRBUF               ; 0262 0 3F0 ??? F555
                CMPB    r5, #002h              ; 0264 0 3F0 ??? 25C002
                JNE     int_serial_rx_store_r4             ; 0267 0 3F0 ??? CE03
                STB     A, r3                  ; 0269 0 3F0 ??? 8B
                SJ      int_serial_rx_addb_r6_2             ; 026A 0 3F0 ??? CB01
int_serial_rx_store_r4:     STB     A, r4                  ; 026C 0 3F0 ??? 8C
int_serial_rx_addb_r6_2:     ADDB    r6, A                  ; 026D 0 3F0 ??? 2681
                INCB    r5                     ; 026F 0 3F0 ??? AD
int_serial_rx_load_r7_2:     MOVB    r7, #002h              ; 0270 0 3F0 ??? 9F02
                J       int_serial_rx_load_ram0f8_2             ; 0272 0 3F0 ??? 039502
int_serial_rx_load_r0:     MOVB    r0, r1                 ; 0275 0 3F0 ??? 2148
                LB      A, SRBUF               ; 0277 0 3F0 ??? F555
                STB     A, r1                  ; 0279 0 3F0 ??? 89
                STB     A, r6                  ; 027A 0 3F0 ??? 8E
                MOVB    r5, #001h              ; 027B 0 3F0 ??? 9D01
                SJ      int_serial_rx_load_r7_2             ; 027D 0 3F0 ??? CBF1
int_serial_rx_load_srbuf:     LB      A, SRBUF               ; 027F 0 3F0 ??? F555
                STB     A, r2                  ; 0281 0 3F0 ??? 8A
                SJ      int_serial_rx_addb_r6_2             ; 0282 0 3F0 ??? CBE9
int_serial_rx_load_srbuf_2:     LB      A, SRBUF               ; 0284 0 3F0 ??? F555
                ADDB    A, r6                  ; 0286 0 3F0 ??? 0E
                JNE     int_serial_rx_clear_r7             ; 0287 0 3F0 ??? CE0A
                LB      A, r1                  ; 0289 0 3F0 ??? 79
                ANDB    A, #0e0h               ; 028A 0 3F0 ??? D6E0
                CMPB    A, #020h               ; 028C 0 3F0 ??? C620
                JNE     int_serial_rx_clear_r7             ; 028E 0 3F0 ??? CE03
                SB      off(00356h).7          ; 0290 0 3F0 ??? C4561F
int_serial_rx_clear_r7:     CLRB    r7                     ; 0293 0 3F0 ??? 2715
int_serial_rx_load_ram0f8_2:     L       A, 0f8h                ; 0295 1 3F0 ??? E5F8
                ANDB    PSWH, #0feh            ; 0297 1 3F0 ??? A2D0FE
                ST      A, IE                  ; 029A 1 3F0 ??? D51A
                RTI                            ; 029C 1 3F0 ??? 02
int_serial_rx_clear_acc:     CLRB    A                      ; 029D 0 3F0 ??? FA
                RB      SRSTAT.3               ; 029E 0 3F0 ??? C5560B
                JEQ     int_serial_rx_clear_srstat_bit2             ; 02A1 0 3F0 ??? C902
                ADDB    A, #001h               ; 02A3 0 3F0 ??? 8601
int_serial_rx_clear_srstat_bit2:     RB      SRSTAT.2               ; 02A5 0 3F0 ??? C5560A
                JEQ     int_serial_rx_store_acch             ; 02A8 0 3F0 ??? C902
                ADDB    A, #002h               ; 02AA 0 3F0 ??? 8602
int_serial_rx_store_acch:     STB     A, ACCH                ; 02AC 0 3F0 ??? D507
                LB      A, SRBUF               ; 02AE 0 3F0 ??? F555
                MOV     DP, A                  ; 02B0 0 3F0 ??? 52
                L       A, DP                  ; 02B1 1 3F0 ??? 42
                JEQ     int_serial_rx_load_dp             ; 02B2 1 3F0 ??? C90E
                SRL     A                      ; 02B4 1 3F0 ??? 63
                JLT     int_serial_rx_load_dp_ind             ; 02B5 1 3F0 ??? CA0E
                L       A, [DP]                ; 02B7 1 3F0 ??? E2
                LB      A, ACC                 ; 02B8 0 3F0 ??? F506
                MOVB    off(0035ch), ACCH      ; 02BA 0 3F0 ??? C5077C5C
int_serial_rx_store_stbuf_2:     STB     A, STBUF               ; 02BE 0 3F0 ??? D551
                SJ      int_serial_rx_load_ram0f8             ; 02C0 0 3F0 ??? CB82
int_serial_rx_load_dp:     MOV     DP, #0035ch            ; 02C2 1 3F0 ??? 625C03
int_serial_rx_load_dp_ind:     LB      A, [DP]                ; 02C5 0 3F0 ??? F2
                SJ      int_serial_rx_store_stbuf_2             ; 02C6 0 3F0 ??? CBF6
                DB  0E5h,0FAh,0D5h,01Ah,0B5h,004h,098h,002h ; 02C8
                DB  001h,067h,000h,001h,0F5h,055h,0C5h,056h ; 02D0
                DB  00Bh,0CEh,00Ch,0C5h,006h,02Fh,0C5h,007h ; 02D8
                DB  015h,0CAh,004h,0C5h,007h,098h,002h,052h ; 02E0
                DB  0F2h,0D5h,051h,0E5h,0F8h,0A2h,008h,0B5h ; 02E8
                DB  01Ah,08Ah,002h ; 02F0
int_timer_2_overflow: L       A, 0fah                ; 02F3 1 ??? ??? E5FA
                ST      A, IE                  ; 02F5 1 ??? ??? D51A
                ORB     PSWH, #001h            ; 02F7 1 ??? ??? A2E001
                MOV     LRB, #00015h           ; 02FA 1 0A8 ??? 571500
                RB      off(000b6h).0          ; 02FD 1 0A8 ??? C4B608
                JNE     timer2ovf_edge_check2             ; 0300 1 0A8 ??? CE01
                INCB    r6                     ; 0302 1 0A8 ??? AE
timer2ovf_edge_check2:     RB      off(000b6h).1          ; 0303 1 0A8 ??? C4B609
                JNE     timer2ovf_return             ; 0306 1 0A8 ??? CE01
                INCB    r3                     ; 0308 1 0A8 ??? AB
timer2ovf_return:     L       A, 0f8h                ; 0309 1 0A8 ??? E5F8
                ANDB    PSWH, #0feh            ; 030B 1 0A8 ??? A2D0FE
                ST      A, IE                  ; 030E 1 0A8 ??? D51A
                RTI                            ; 0310 1 0A8 ??? 02
int_timer_3:    L       A, 0fah                ; 0311 1 ??? ??? E5FA
                ST      A, IE                  ; 0313 1 ??? ??? D51A
                ORB     PSWH, #001h            ; 0315 1 ??? ??? A2E001
                MOV     LRB, #00014h           ; 0318 1 0A0 ??? 571400
                LB      A, r0                  ; 031B 0 0A0 ??? 78
                ADDB    A, #001h               ; 031C 0 0A0 ??? 8601
                CMPB    A, #005h               ; 031E 0 0A0 ??? C605
                JLT     timer3isr_return             ; 0320 0 0A0 ??? CA0A
                JBS     off(TCON3).2, timer3isr_return ; 0322 0 0A0 ??? EA4307
                MOV     off(TMR3), er3         ; 0325 0 0A0 ??? 477C3E
                ORB     off(TCON3), #008h      ; 0328 0 0A0 ??? C443E008
timer3isr_return:     L       A, off(000f8h)         ; 032C 1 0A0 ??? E4F8
                ANDB    PSWH, #0feh            ; 032E 1 0A0 ??? A2D0FE
                ST      A, IE                  ; 0331 1 0A0 ??? D51A
                RTI                            ; 0333 1 0A0 ??? 02
int_PWM_timer:  L       A, 0fah                ; 0334 1 ??? ??? E5FA
                ST      A, IE                  ; 0336 1 ??? ??? D51A
                ORB     PSWH, #001h            ; 0338 1 ??? ??? A2E001
                MOV     LRB, #0007dh           ; 033B 1 3E8 ??? 577D00
                LB      A, r0                  ; 033E 0 3E8 ??? 78
                ADDB    A, #001h               ; 033F 0 3E8 ??? 8601
                CMPB    A, #064h               ; 0341 0 3E8 ??? C664
                JLT     int_PWM_timer_store_r0             ; 0343 0 3E8 ??? CA04
                MOVB    r1, 0e4h               ; 0345 0 3E8 ??? C5E449
                CLRB    A                      ; 0348 0 3E8 ??? FA
int_PWM_timer_store_r0:     STB     A, r0                  ; 0349 0 3E8 ??? 88
                CMPB    A, r1                  ; 034A 0 3E8 ??? 49
                MB      P4.3, C                ; 034B 0 3E8 ??? C52C3B
                JBR     off(00356h).0, pwm_isr_return ; 034E 0 3E8 ??? D85619
                LB      A, r2                  ; 0351 0 3E8 ??? 7A
                JNE     int_PWM_timer_subb_acc             ; 0352 0 3E8 ??? CE1E
                MOVB    r3, 0e5h               ; 0354 0 3E8 ??? C5E54B
                MOV     er2, 0e6h              ; 0357 0 3E8 ??? B5E64A
                LB      A, #031h               ; 035A 0 3E8 ??? 7731
int_PWM_timer_store_r2:     STB     A, r2                  ; 035C 0 3E8 ??? 8A
                CMPB    A, r3                  ; 035D 0 3E8 ??? 4B
                JEQ     int_PWM_timer_load_er2             ; 035E 0 3E8 ??? C916
                L       A, #00001h             ; 0360 1 3E8 ??? 670100
                JGE     pwm_output_store             ; 0363 1 3E8 ??? CD03
                L       A, #0ffffh             ; 0365 1 3E8 ??? 67FFFF
pwm_output_store:     ST      A, PWMR0               ; 0368 1 3E8 ??? D572
pwm_isr_return:     L       A, 0f8h                ; 036A 1 3E8 ??? E5F8
                ANDB    PSWH, #0feh            ; 036C 1 3E8 ??? A2D0FE
                ST      A, IE                  ; 036F 1 3E8 ??? D51A
                RTI                            ; 0371 1 3E8 ??? 02
int_PWM_timer_subb_acc:     SUBB    A, #001h               ; 0372 0 3E8 ??? A601
                SJ      int_PWM_timer_store_r2             ; 0374 0 3E8 ??? CBE6
int_PWM_timer_load_er2:     L       A, er2                 ; 0376 1 3E8 ??? 36
                SJ      pwm_output_store             ; 0377 1 3E8 ??? CBEF
int_INT1:       L       A, #000a0h             ; 0379 1 ??? ??? 67A000
                ST      A, IE                  ; 037C 1 ??? ??? D51A
                MOV     PSW, #00102h           ; 037E 1 ??? ??? B504980201
                MOV     LRB, #00021h           ; 0383 1 108 ??? 572100
                MOV     USP, #00280h           ; 0386 1 108 280 A1988002
                CAL     refresh_engine_flags_snapshot             ; 038A 1 108 280 322B5C
                SB      off(00128h).4          ; 038D 1 108 280 C4281C
                JBS     off(0011ah).7, int1_dispatch_main_cycle ; 0390 1 108 280 EF1A0F
                JBS     off(0011ah).3, int1_dispatch_alt1 ; 0393 1 108 280 EB1A12
                RB      IRQH.1                 ; 0396 1 108 280 C51909
                JEQ     dtc04_ckp_latch             ; 0399 1 108 280 C90A
                RB      0b4h.0                 ; 039B 1 108 280 C5B408
                MOVB    off(001adh), #02dh     ; 039E 1 108 280 C4AD982D
int1_dispatch_main_cycle:     J       crank_cycle_entry             ; 03A2 1 108 280 039A06
dtc04_ckp_latch:     SB      0b4h.0                 ; 03A5 1 108 280 C5B418
int1_dispatch_alt1:     L       A, ADCR6               ; 03A8 1 108 280 E56C
                ST      A, 0bah                ; 03AA 1 108 280 D5BA
                L       A, TM2                 ; 03AC 1 108 280 E538
                ST      A, 0f0h                ; 03AE 1 108 280 D5F0
                MOVB    0a2h, #000h            ; 03B0 1 108 280 C5A29800
                LB      A, #003h               ; 03B4 0 108 280 7703
                RB      TRNSIT.0               ; 03B6 0 108 280 C54608
                JNE     crank_tooth_count_store             ; 03B9 0 108 280 CE0A
                LB      A, off(00134h)         ; 03BB 0 108 280 F434
                ADDB    A, #006h               ; 03BD 0 108 280 8606
                CMPB    A, #018h               ; 03BF 0 108 280 C618
                JLT     crank_tooth_count_store             ; 03C1 0 108 280 CA02
                LB      A, #003h               ; 03C3 0 108 280 7703
crank_tooth_count_store:     STB     A, off(00134h)         ; 03C5 0 108 280 D434
                SB      P4.0                   ; 03C7 0 108 280 C52C18
                MB      C, off(0011bh).6       ; 03CA 0 108 280 C41B2E
                MB      off(0012ah).1, C       ; 03CD 0 108 280 C42A39
                JBS     off(00128h).2, int1_exit_jump ; 03D0 0 108 280 EA2817
                LB      A, off(0013dh)         ; 03D3 0 108 280 F43D
                JNE     int1_exit_jump             ; 03D5 0 108 280 CE13
                STB     A, off(0013ch)         ; 03D7 0 108 280 D43C
                SB      off(00128h).2          ; 03D9 0 108 280 C4281A
                ANDB    PSWH, #0feh            ; 03DC 0 108 280 A2D0FE
                MOVB    off(0018eh), #077h     ; 03DF 0 108 280 C48E9877
                MOVB    off(00116h), #011h     ; 03E3 0 108 280 C4169811
                ORB     PSWH, #001h            ; 03E7 0 108 280 A2E001
int1_exit_jump:     J       crank_cycle_dispatch2             ; 03EA 0 108 280 038405
int_serial_rx_BRG: L       A, #000a0h             ; 03ED 1 ??? ??? 67A000
; [H] NOTE: despite the vector-table name (inherited from the OKI 66207's default peripheral
; [H] vector list), this handler's actual content -- storing to off(0011ah)/(0011ch)/(0011eh)
; [H] (the exact addresses refresh_engine_flags_snapshot reads from), managing a tooth/sync
; [H] counter (0xA2/0xA3), and touching sysFlags_b7 bits 0/2 -- looks like crank/cam sync-pattern
; [H] handling, not serial-receive-baud-rate-generator work. Likely this vector/trigger source is
; [H] repurposed by this firmware for a different signal than its datasheet name implies. Flagging
; [H] rather than asserting a replacement name without more certainty.
                ST      A, IE                  ; 03F0 1 ??? ??? D51A
                MOV     PSW, #00102h           ; 03F2 1 ??? ??? B504980201
                MOV     LRB, #00021h           ; 03F7 1 108 ??? 572100
                MOV     USP, #00280h           ; 03FA 1 108 280 A1988002
                L       A, (00212h-00280h)[USP] ; 03FE 1 108 280 E392
                ST      A, off(0011ah)         ; 0400 1 108 280 D41A
                L       A, (00214h-00280h)[USP] ; 0402 1 108 280 E394
                ST      A, off(0011ch)         ; 0404 1 108 280 D41C
                L       A, (00216h-00280h)[USP] ; 0406 1 108 280 E396
                ST      A, off(0011eh)         ; 0408 1 108 280 D41E
                MOVB    off(001adh), #02dh     ; 040A 1 108 280 C4AD982D
                JBR     off(00128h).3, crank_sync_flags_clear_path ; 040E 1 108 280 DB282F
                JBS     off(0011ah).7, crank_sync_flag_set ; 0411 1 108 280 EF1A16
                RB      IRQH.7                 ; 0414 1 108 280 C5190F
                JNE     crank_sync_lost_path             ; 0417 1 108 280 CE3B
                RB      0b6h.7                 ; 0419 1 108 280 C5B60F
                JNE     crank_sync_lost_path             ; 041C 1 108 280 CE36
crank_sync_retry_check:     CMPB    0a2h, #005h            ; 041E 1 108 280 C5A2C005
                JGE     crank_sync_confirm_check             ; 0422 1 108 280 CD0B
                INCB    0a2h                   ; 0424 1 108 280 C5A216
                J       crank_sync_window_check             ; 0427 1 108 280 037F04
crank_sync_flag_set:     SB      off(00128h).4          ; 042A 1 108 280 C4281C
                SJ      crank_sync_retry_check             ; 042D 1 108 280 CBEF
crank_sync_confirm_check:     JBS     off(0011ah).7, crank_sync_confirmed ; 042F 1 108 280 EF1A06
dtc08_tdc_latch_2: SB      0b4h.1                 ; 0432 1 108 280 C5B419
                SB      off(00128h).6          ; 0435 1 108 280 C4281E
crank_sync_confirmed:     INCB    0a3h                   ; 0438 1 108 280 C5A316
                CLRB    0a2h                   ; 043B 1 108 280 C5A215
                SJ      crank_sync_window_check             ; 043E 1 108 280 CB3F
crank_sync_flags_clear_path:     RB      IRQH.7                 ; 0440 1 108 280 C5190F
                RB      0b6h.7                 ; 0443 1 108 280 C5B60F
                RB      0b7h.2                 ; 0446 1 108 280 C5B70A
                MB      C, 0b7h.0              ; 0449 1 108 280 C5B728
                JGE     crank_sync_exit_jump             ; 044C 1 108 280 CD03
                SB      off(00128h).4          ; 044E 1 108 280 C4281C
crank_sync_exit_jump:     J       crank_decode_exit             ; 0451 1 108 280 035F06
crank_sync_lost_path:     SB      off(00128h).4          ; 0454 1 108 280 C4281C
                RB      off(00128h).6          ; 0457 1 108 280 C4280E
                MOVB    off(001aeh), #02dh     ; 045A 1 108 280 C4AE982D
                L       A, 0a2h                ; 045E 1 108 280 E5A2
                CMP     A, #00005h             ; 0460 1 108 280 C60500
                JEQ     crank_tooth_counter_reset             ; 0463 1 108 280 C917
                SB      off(00125h).7          ; 0465 1 108 280 C4251F
                JLT     crank_sync_flag_mid             ; 0468 1 108 280 CA0A
                CMP     A, #00105h             ; 046A 1 108 280 C60501
                JGE     crank_sync_flag_high             ; 046D 1 108 280 CD0A
                SB      0b5h.0                 ; 046F 1 108 280 C5B518
                SJ      crank_tooth_counter_reset             ; 0472 1 108 280 CB08
crank_sync_flag_mid:     SB      off(00128h).5          ; 0474 1 108 280 C4281D
                SJ      crank_tooth_counter_reset             ; 0477 1 108 280 CB03
crank_sync_flag_high:     SB      0b5h.1                 ; 0479 1 108 280 C5B519
crank_tooth_counter_reset:     CLR     0a2h                   ; 047C 1 108 280 B5A215
crank_sync_window_check:     JBS     off(0011bh).0, crank_window_flag_clear ; 047F 1 108 280 E81B26
                RB      0b7h.2                 ; 0482 1 108 280 C5B70A
                JEQ     crank_tooth_seq_check             ; 0485 1 108 280 C924
                RB      off(00128h).7          ; 0487 1 108 280 C4280F
                MOVB    off(001afh), #007h     ; 048A 1 108 280 C4AF9807
                L       A, off(00134h)         ; 048E 1 108 280 E434
                CMP     A, #00017h             ; 0490 1 108 280 C61700
                JNE     crank_window_flag_check2             ; 0493 1 108 280 CE33
                RB      off(00128h).5          ; 0495 1 108 280 C4280D
                JNE     crank_sync_flag_low             ; 0498 1 108 280 CE3A
                RB      off(00125h).7          ; 049A 1 108 280 C4250F
                CMPB    0a2h, #003h            ; 049D 1 108 280 C5A2C003
                JEQ     crank_tooth_reset             ; 04A1 1 108 280 C934
crank_sync_flag_common:     SB      0b5h.2                 ; 04A3 1 108 280 C5B51A
                SJ      crank_tooth_reset             ; 04A6 1 108 280 CB2F
crank_window_flag_clear:     RB      off(00125h).7          ; 04A8 1 108 280 C4250F
crank_tooth_seq_check:     CMPB    off(00134h), #017h     ; 04AB 1 108 280 C434C017
                JGE     crank_tooth_seq_gate             ; 04AF 1 108 280 CD06
                INCB    off(00134h)            ; 04B1 1 108 280 C43416
                J       crank_tooth_mod_check             ; 04B4 1 108 280 03DA04
crank_tooth_seq_gate:     JBS     off(0011bh).0, crank_tooth_seq_advance ; 04B7 1 108 280 E81B06
dtc09_cyp_latch: SB      0b4h.2                 ; 04BA 1 108 280 C5B41A
                SB      off(00128h).7          ; 04BD 1 108 280 C4281F
crank_tooth_seq_advance:     INCB    off(00135h)            ; 04C0 1 108 280 C43516
                CLRB    off(00134h)            ; 04C3 1 108 280 C43415
                SJ      crank_tooth_mod_check             ; 04C6 1 108 280 CB12
crank_window_flag_check2:     RB      off(00128h).5          ; 04C8 1 108 280 C4280D
                JGE     crank_tooth_reset             ; 04CB 1 108 280 CD0A
                JEQ     crank_sync_flag_common             ; 04CD 1 108 280 C9D4
                SB      0b5h.0                 ; 04CF 1 108 280 C5B518
                SJ      crank_tooth_reset             ; 04D2 1 108 280 CB03
crank_sync_flag_low:     SB      0b5h.1                 ; 04D4 1 108 280 C5B519
crank_tooth_reset:     CLR     off(00134h)            ; 04D7 1 108 280 B43415
crank_tooth_mod_check:     JBS     off(0011ah).7, crank_tooth_mod6_calc ; 04DA 1 108 280 EF1A0F
                JBS     off(00128h).6, crank_tooth_mod6_calc ; 04DD 1 108 280 EE280C
crank_tooth_range_check:     JBS     off(0011bh).0, crank_tooth_wrap_calc ; 04E0 1 108 280 E81B17
                JBS     off(00128h).7, crank_tooth_wrap_calc ; 04E3 1 108 280 EF2814
crank_tooth_carry_clear:     RC                             ; 04E6 1 108 280 95
                JBR     off(0011bh).6, crank_sync_store_flag ; 04E7 1 108 280 DE1B2F
                SJ      crank_sync_confirmed_flag             ; 04EA 1 108 280 CB29
crank_tooth_mod6_calc:     CLR     A                      ; 04EC 1 108 280 F9
                MOVB    r0, #006h              ; 04ED 1 108 280 9806
                LB      A, off(00134h)         ; 04EF 0 108 280 F434
                ADDB    A, #003h               ; 04F1 0 108 280 8603
                DIVB                           ; 04F3 0 108 280 A236
                LB      A, r1                  ; 04F5 0 108 280 79
                STB     A, 0a2h                ; 04F6 0 108 280 D5A2
                SJ      crank_tooth_range_check             ; 04F8 0 108 280 CBE6
crank_tooth_wrap_calc:     MOVB    r0, #006h              ; 04FA 1 108 280 9806
                LB      A, 0a2h                ; 04FC 0 108 280 F5A2
                ADDB    A, #003h               ; 04FE 0 108 280 8603
                SUBB    A, r0                  ; 0500 0 108 280 28
                JGE     crank_tooth_wrap_store             ; 0501 0 108 280 CD01
                ADDB    A, r0                  ; 0503 0 108 280 08
crank_tooth_wrap_store:     STB     A, r2                  ; 0504 0 108 280 8A
                CLR     A                      ; 0505 1 108 280 F9
                LB      A, off(00134h)         ; 0506 0 108 280 F434
                DIVB                           ; 0508 0 108 280 A236
                MULB                           ; 050A 0 108 280 A234
                ADDB    A, r2                  ; 050C 0 108 280 0A
                STB     A, off(00134h)         ; 050D 0 108 280 D434
                JBS     off(0011ah).7, crank_sync_confirmed_flag ; 050F 0 108 280 EF1A03
                JBR     off(00128h).6, crank_tooth_carry_clear ; 0512 0 108 280 DE28D1
crank_sync_confirmed_flag:     SC                             ; 0515 0 108 280 85
                SB      off(00124h).2          ; 0516 0 108 280 C4241A
crank_sync_store_flag:     MB      off(0012ah).1, C       ; 0519 0 108 280 C42A39
                LB      A, off(00134h)         ; 051C 0 108 280 F434
                EXTND                          ; 051E 1 108 280 F8
                MOV     X1, A                  ; 051F 1 108 280 50
                LCB     A, tbl_crank_sync_pattern[X1]        ; 0520 1 108 280 90AB9A6F
                ANDB    off(00128h), A         ; 0524 1 108 280 C428D1
                LB      A, off(00134h)         ; 0527 0 108 280 F434
                JNE     crank_sync_flag2_check             ; 0529 0 108 280 CE28
                JBR     off(00128h).2, crank_sync_store_flag_goto_7ab4 ; 052B 0 108 280 DA280B
                JBS     off(0011fh).7, crank_sync_flag2_check ; 052E 0 108 280 EF1F22
                JBS     off(00128h).0, crank_tooth_alt_flag ; 0531 0 108 280 E82816
                RB      off(00128h).1          ; 0534 0 108 280 C42809
                SJ      crank_tooth_alt_store             ; 0537 0 108 280 CB18
crank_sync_store_flag_goto_7ab4:     J       crank_sync_store_flag_andb_pswh             ; 0539 0 108 280 03B47A
                DB  000h ; 053C
crank_sync_store_flag_load_ram116:     MOVB    off(00116h), #011h     ; 053D 0 108 280 C4169811
                ANDB    off(00128h), #0fch     ; 0541 0 108 280 C428D0FC
                ORB     PSWH, #001h            ; 0545 0 108 280 A2E001
                SJ      crank_tooth_alt_store             ; 0548 0 108 280 CB07
crank_tooth_alt_flag:     LB      A, #001h               ; 054A 0 108 280 7701
                JBR     off(00128h).1, crank_tooth_alt_store ; 054C 0 108 280 D92802
                LB      A, #002h               ; 054F 0 108 280 7702
crank_tooth_alt_store:     STB     A, off(0013ch)         ; 0551 0 108 280 D43C
crank_sync_flag2_check:     JBS     off(00128h).2, crank_sync_flag2_check_if_ram11f_bit7_set ; 0553 0 108 280 EA280E
                CMPB    off(0013dh), #004h     ; 0556 0 108 280 C43DC004
                JEQ     crank_cycle_exit_early             ; 055A 0 108 280 C925
                LB      A, off(0013dh)         ; 055C 0 108 280 F43D
                J       crank_sync_flag2_check_if_ne_goto_7ac7             ; 055E 0 108 280 03BE7A
crank_sync_flag2_check_goto_7aca:     J       crank_sync_flag2_check_load_ram0a2             ; 0561 0 108 280 03CA7A
crank_sync_flag2_check_if_ram11f_bit7_set:     JBS     off(0011fh).7, crank_sync_flag2_check_goto_7aca ; 0564 0 108 280 EF1FFA
                LB      A, off(0013ch)         ; 0567 0 108 280 F43C
                ANDB    A, #001h               ; 0569 0 108 280 D601
                TRB     off(00128h)            ; 056B 0 108 280 C42813 ; [H] mnemonic was "TBR" (letter transposition)
                JNE     crank_cycle_exit_early             ; 056E 0 108 280 CE11
                CLR     A                      ; 0570 1 108 280 F9
                LB      A, off(00134h)         ; 0571 0 108 280 F434
                JBR     off(0013ch).0, crank_tooth_pattern_lookup ; 0573 0 108 280 D83C02
                ADDB    A, #006h               ; 0576 0 108 280 8606
crank_tooth_pattern_lookup:     MOV     X1, A                  ; 0578 0 108 280 50
                LCB     A, tbl_crank_tooth_pattern[X1]        ; 0579 0 108 280 90ABB26F
                CMPB    A, off(0013bh)         ; 057D 0 108 280 C73B
                JGE     crank_cycle_dispatch2             ; 057F 0 108 280 CD03
crank_cycle_exit_early:     J       crank_decode_exit             ; 0581 0 108 280 035F06
crank_cycle_dispatch2:     LB      A, off(0013ch)         ; 0584 0 108 280 F43C
                SLLB    A                      ; 0586 0 108 280 53
                EXTND                          ; 0587 1 108 280 F8
                MOV     X1, A                  ; 0588 1 108 280 50
                JBS     off(00125h).4, injtimer_countdown_check ; 0589 1 108 280 EC2523
                CLR     A                      ; 058C 1 108 280 F9
                MOV     X2, A                  ; 058D 1 108 280 51
                ST      A, 003beh[X2]          ; 058E 1 108 280 D1BE03
                ST      A, 003c0h[X2]          ; 0591 1 108 280 D1C003
                ST      A, 003c2h[X2]          ; 0594 1 108 280 D1C203
                ST      A, 003c4h[X2]          ; 0597 1 108 280 D1C403
                CLRB    A                      ; 059A 0 108 280 FA
                STB     A, off(0019dh)         ; 059B 0 108 280 D49D
                J       injtimer_bit_clear             ; 059D 0 108 280 03D505
injtimer_clear_path1:     SBR     off(0019fh)            ; 05A0 0 108 280 C49F11
                SB      off(0012ah).7          ; 05A3 0 108 280 C42A1F
                SB      off(0019bh).0          ; 05A6 0 108 280 C49B18
                SJ      injbase_calc_start             ; 05A9 0 108 280 CB2D
injtimer_countdown_store_load_ram14e:     L       A, off(0014eh)         ; 05AB 1 108 280 E44E
                SJ      injtimer_clamp_store             ; 05AD 1 108 280 CB23
injtimer_countdown_check:     LB      A, off(0019eh)         ; 05AF 0 108 280 F49E
                SUBB    A, #001h               ; 05B1 0 108 280 A601
                JGE     injtimer_countdown_store             ; 05B3 0 108 280 CD02
                LB      A, #007h               ; 05B5 0 108 280 7707
injtimer_countdown_store:     STB     A, off(0019eh)         ; 05B7 0 108 280 D49E
                CMPB    A, #007h               ; 05B9 0 108 280 C607
                JGT     injtimer_bit_clear             ; 05BB 0 108 280 C818
                MBR     C, off(0019dh)         ; 05BD 0 108 280 C49D21
                JLT     injtimer_clear_path1             ; 05C0 0 108 280 CADE
                ADDB    A, #004h               ; 05C2 0 108 280 8604
                RBR     off(0019fh)            ; 05C4 0 108 280 C49F12
                JNE     injtimer_countdown_store_load_ram14e             ; 05C7 0 108 280 CEE2
                L       A, 003beh[X1]          ; 05C9 1 108 280 E0BE03
                SUB     A, #0ffffh             ; 05CC 1 108 280 A6FFFF
                JGE     injtimer_clamp_store             ; 05CF 1 108 280 CD01
                CLR     A                      ; 05D1 1 108 280 F9
injtimer_clamp_store:     ST      A, 003beh[X1]          ; 05D2 1 108 280 D0BE03
injtimer_bit_clear:     RB      off(0019bh).0          ; 05D5 1 108 280 C49B08
injbase_calc_start:     CLR     A                      ; 05D8 1 108 280 F9
                JBS     off(00124h).4, injbase_store ; 05D9 1 108 280 EC240F
                JBS     off(0012ah).1, injbase_store ; 05DC 1 108 280 E92A0C
                L       A, 003b6h[X1]          ; 05DF 1 108 280 E0B603
                ADD     A, 003beh[X1]          ; 05E2 1 108 280 B0BE0382
                JGE     injbase_store             ; 05E6 1 108 280 CD03
                L       A, #0ffffh             ; 05E8 1 108 280 67FFFF
injbase_store:     ST      A, off(00196h)         ; 05EB 1 108 280 D496
                LB      A, off(0013ch)         ; 05ED 0 108 280 F43C
                ANDB    PSWH, #0feh            ; 05EF 0 108 280 A2D0FE
                TRB     off(00117h)            ; 05F2 0 108 280 C41713 ; [H] mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C41713
                JNE     tm0_sync_alt             ; 05F5 0 108 280 CE23
                JBR     off(00128h).2, tm0_sync_common ; 05F7 0 108 280 DA2814
                L       A, TM0                 ; 05FA 1 108 280 E530
                SUB     A, TMR0                ; 05FC 1 108 280 B532A2
                JEQ     tm0_sync_common             ; 05FF 1 108 280 C90D
                MB      C, IRQ.5               ; 0601 1 108 280 C5182D
                JLT     tm0_sync_common             ; 0604 1 108 280 CA08
                ADD     A, #00005h             ; 0606 1 108 280 860500
                JLT     tm0_sync_common             ; 0609 1 108 280 CA03
                ADD     TMR0, A                ; 060B 1 108 280 B53281
tm0_sync_common:     ORB     PSWH, #001h            ; 060E 1 108 280 A2E001
                CAL     tm0_resync_helper             ; 0611 1 108 280 32BE56
                SB      off(0012ah).3          ; 0614 1 108 280 C42A1B
                J       crank_tooth_flag_update             ; 0617 1 108 280 033B06
tm0_sync_alt:     L       A, TMR0                ; 061A 1 108 280 E532
                SUB     A, TM0                 ; 061C 1 108 280 B530A2
                CMP     A, #00005h             ; 061F 1 108 280 C60500
                JLT     tm0_sync_flag_clear             ; 0622 1 108 280 CA05
                CMP     A, #00020h             ; 0624 1 108 280 C62000
                JLT     tm0_sync_flag_set             ; 0627 1 108 280 CA09
tm0_sync_flag_clear:     ORB     PSWH, #001h            ; 0629 1 108 280 A2E001
                RB      off(0012ah).3          ; 062C 1 108 280 C42A0B
                J       crank_tooth_flag_update             ; 062F 1 108 280 033B06
tm0_sync_flag_set:     ORB     PSWH, #001h            ; 0632 1 108 280 A2E001
                CAL     tm0_resync_helper             ; 0635 1 108 280 32BE56
                SB      off(0012ah).3          ; 0638 1 108 280 C42A1B
crank_tooth_flag_update:     CAL     crank_helper2             ; 063B 1 108 280 32F554
                LB      A, off(0013ch)         ; 063E 0 108 280 F43C
                STB     A, r0                  ; 0640 0 108 280 88
                ANDB    A, #001h               ; 0641 0 108 280 D601
                SBR     off(00128h)            ; 0643 0 108 280 C42811
                INCB    r0                     ; 0646 0 108 280 A8
                LB      A, r0                  ; 0647 0 108 280 78
                ANDB    A, #003h               ; 0648 0 108 280 D603
                STB     A, off(0013ch)         ; 064A 0 108 280 D43C
                JBS     off(0011fh).3, crank_decode_exit ; 064C 0 108 280 EB1F10
                JBS     off(0011bh).7, crank_decode_exit ; 064F 0 108 280 EF1B0D
                RB      off(0012ah).0          ; 0652 0 108 280 C42A08
                JEQ     crank_decode_exit             ; 0655 0 108 280 C908
                RB      TRNSIT.2               ; 0657 0 108 280 C5460A
                JNE     crank_decode_exit             ; 065A 0 108 280 CE03
dtc16_injector_latch: SB      0b4h.6                 ; 065C 0 108 280 C5B41E
crank_decode_exit:     RB      off(0012ah).3          ; 065F 1 108 280 C42A0B
                JNE     crank_decode_final_check             ; 0662 1 108 280 CE03
                CAL     tm0_resync_helper             ; 0664 1 108 280 32BE56
crank_decode_final_check:     LB      A, 0a2h                ; 0667 0 108 280 F5A2
                CMPB    A, #003h               ; 0669 0 108 280 C603
                JNE     crank_cycle_dispatch             ; 066B 0 108 280 CE39
crank_cycle_dispatch_body:     JBS     off(00126h).0, crank_cycle_period_saturate ; 066D 0 108 280 E82625
                JBS     off(0011fh).1, crank_cycle_period_saturate ; 0670 0 108 280 E91F22
                CMPB    A, #003h               ; 0673 0 108 280 C603
                CLR     er2                    ; 0675 0 108 280 4615
                JBS     off(0012ah).5, crank_cycle_alt_dp ; 0677 0 108 280 ED2A08
                MOV     DP, #00366h            ; 067A 0 108 280 626603
                JEQ     crank_cycle_dp_common             ; 067D 0 108 280 C90A
                CLR     A                      ; 067F 1 108 280 F9
                SJ      crank_cycle_er2_store             ; 0680 1 108 280 CB16
crank_cycle_alt_dp:     MOV     DP, #00362h            ; 0682 0 108 280 626203
                JNE     crank_cycle_dp_common             ; 0685 0 108 280 CE02
                MOV     er2, [DP]              ; 0687 0 108 280 B24A
crank_cycle_dp_common:     L       A, [DP]                ; 0689 1 108 280 E2
                CLR     er0                    ; 068A 1 108 280 4415
                MOVB    r1, 09fh               ; 068C 1 108 280 C59F49
                MUL                            ; 068F 1 108 280 9035
                L       A, er2                 ; 0691 1 108 280 36
                ADD     A, er1                 ; 0692 1 108 280 09
                JGE     crank_cycle_er2_store             ; 0693 1 108 280 CD03
crank_cycle_period_saturate:     L       A, #0ffffh             ; 0695 1 108 280 67FFFF
crank_cycle_er2_store:     ST      A, 0a4h                ; 0698 1 108 280 D5A4
crank_cycle_entry:     L       A, off(00124h)         ; 069A 1 108 280 E424
                ST      A, (0021ch-00280h)[USP] ; 069C 1 108 280 D39C
                ANDB    PSWH, #0feh            ; 069E 1 108 280 A2D0FE
int1_rti_epilogue:     L       A, 0f8h                ; 06A1 1 108 280 E5F8
                ST      A, IE                  ; 06A3 1 108 280 D51A
                RTI                            ; 06A5 1 108 280 02
crank_cycle_dispatch:     JGE     crank_cycle_dispatch_alt             ; 06A6 0 108 280 CD64
                CMPB    A, #001h               ; 06A8 0 108 280 C601
                JGE     crank_cycle_dispatch_alt2             ; 06AA 0 108 280 CD69
                JBS     off(0011bh).6, crank_cycle_p4_gate ; 06AC 0 108 280 EE1B14
                JBS     off(00125h).7, crank_cycle_p4_gate ; 06AF 0 108 280 EF2511
                CMP     0c4h, #000e2h          ; 06B2 0 108 280 B5C4C0E200
                JLT     crank_cycle_p4_gate             ; 06B7 0 108 280 CA0A
                RB      TRNSIT.1               ; 06B9 0 108 280 C54609
                JNE     crank_cycle_p4_gate             ; 06BC 0 108 280 CE05
dtc15_ign_output_latch: SB      0b4h.3                 ; 06BE 0 108 280 C5B41B
                SJ      crank_cycle_p4_gate_if_ram11f_bit2_set             ; 06C1 0 108 280 CB07
crank_cycle_p4_gate:     RB      0b4h.3                 ; 06C3 0 108 280 C5B40B
                MOVB    off(001b0h), #006h     ; 06C6 0 108 280 C4B09806
crank_cycle_p4_gate_if_ram11f_bit2_set:     JBS     off(0011fh).2, crank_cycle_gate2 ; 06CA 0 108 280 EA1F4A
                JBS     off(0011fh).7, crank_cycle_p4_gate_set_p4_bit0 ; 06CD 0 108 280 EF1F0E
                JBR     off(00129h).1, crank_cycle_p4_gate_goto_7ad4 ; 06D0 0 108 280 D92910
                JBS     off(0011ah).2, crank_cycle_p4_gate_if_ram120_bit0_set ; 06D3 0 108 280 EA1A03
                JBR     off(0011ah).4, crank_cycle_result_common ; 06D6 0 108 280 DC1A29
crank_cycle_p4_gate_if_ram120_bit0_set:     JBS     off(00120h).0, crank_cycle_result_a ; 06D9 0 108 280 E8201F
                SJ      crank_cycle_result_common             ; 06DC 0 108 280 CB24
crank_cycle_p4_gate_set_p4_bit0:     SB      P4.0                   ; 06DE 0 108 280 C52C18
                SJ      crank_cycle_entry_gate             ; 06E1 0 108 280 CB3A
crank_cycle_p4_gate_goto_7ad4:     J       crank_cycle_p4_gate_load_imm             ; 06E3 0 108 280 03D47A
crank_cycle_counter_check:     CMPB    off(001aeh), #028h     ; 06E6 0 108 280 C4AEC028
                JLE     crank_cycle_result_b             ; 06EA 0 108 280 CF13
                JBS     off(0011fh).4, crank_cycle_result_a ; 06EC 0 108 280 EC1F0C
                JBS     off(0012ah).4, crank_cycle_result_common ; 06EF 0 108 280 EC2A10
                JBS     off(0011ah).5, crank_cycle_result_a ; 06F2 0 108 280 ED1A06
                CMPB    0d9h, #020h            ; 06F5 0 108 280 C5D9C020
                JLT     crank_cycle_result_common             ; 06F9 0 108 280 CA07
crank_cycle_result_a:     LB      A, #003h               ; 06FB 0 108 280 7703
                SJ      crank_cycle_result_common             ; 06FD 0 108 280 CB03
crank_cycle_result_b:     SB      off(00128h).4          ; 06FF 0 108 280 C4281C
crank_cycle_result_common:     SRLB    A                      ; 0702 0 108 280 63
                MB      off(00126h).0, C       ; 0703 0 108 280 C42638
                SRLB    A                      ; 0706 0 108 280 63
                MB      P4.0, C                ; 0707 0 108 280 C52C38
                SJ      crank_cycle_entry             ; 070A 0 108 280 CB8E
crank_cycle_dispatch_alt:     CMPB    A, #004h               ; 070C 0 108 280 C604
                JNE     crank_cycle_entry             ; 070E 0 108 280 CE8A
                J       crank_cycle_dispatch_body             ; 0710 0 108 280 036D06
crank_cycle_bailout:     SJ      crank_cycle_entry             ; 0713 0 108 280 CB85
crank_cycle_dispatch_alt2:     JEQ     crank_cycle_entry             ; 0715 0 108 280 C983
crank_cycle_gate2:     JBS     off(0011fh).7, crank_cycle_bailout ; 0717 0 108 280 EF1FF9
                JBR     off(00128h).4, crank_cycle_bailout ; 071A 0 108 280 DC28F6
crank_cycle_entry_gate:     INCB    off(0013eh)            ; 071D 0 108 280 C43E16
                JBS     off(0012ah).2, crank_cycle_bailout ; 0720 0 108 280 EA2AF0
                LB      A, off(00124h)         ; 0723 0 108 280 F424
                ANDB    A, #003h               ; 0725 0 108 280 D603
                ANDB    off(0013eh), A         ; 0727 0 108 280 C43ED1
                JNE     crank_cycle_bailout             ; 072A 0 108 280 CEE7
                J       crank_cycle_entry_gate_set_ram12a_bit2             ; 072C 0 108 280 03E27A
                DB  000h ; 072F
crank_cycle_entry_gate_call_crank_edge_helper:     CAL     crank_edge_helper             ; 0730 1 108 280 32225C
                MOV     PSW, #01101h           ; 0733 1 108 280 B504980111
                MOV     LRB, #00040h           ; 0738 1 200 280 574000
                MOV     USP, #00180h           ; 073B 1 200 180 A1988001
                MOV     DP, #00379h            ; 073F 1 200 180 627903
                MOVB    r0, [DP]               ; 0742 1 200 180 C248
                LB      A, 0e1h                ; 0744 0 200 180 F5E1
                STB     A, [DP]                ; 0746 0 200 180 D2
                LB      A, ADCR2H              ; 0747 0 200 180 F565
                STB     A, 0e1h                ; 0749 0 200 180 D5E1
                SUBB    A, r0                  ; 074B 0 200 180 28
                MB      off(0022bh).5, C       ; 074C 0 200 180 C42B3D
                JGE     crank_cycle_adc_prep             ; 074F 0 200 180 CD01
                VCAL    6                      ; 0751 0 200 180 16
crank_cycle_adc_prep:     STB     A, 0e2h                ; 0752 0 200 180 D5E2
                LB      A, P2                  ; 0754 0 200 180 F524
                ANDB    A, #0e0h               ; 0756 0 200 180 D6E0
                STB     A, off(00259h)         ; 0758 0 200 180 D459
                L       A, 0fah                ; 075A 1 200 180 E5FA
                ST      A, IE                  ; 075C 1 200 180 D51A
                ANDB    PSWH, #0feh            ; 075E 1 200 180 A2D0FE
                RB      ADSCAN.4               ; 0761 1 200 180 C5580C
                ANDB    P2, #01fh              ; 0764 1 200 180 C524D01F
                SB      ADSCAN.4               ; 0768 1 200 180 C5581C
                ORB     PSWH, #001h            ; 076B 1 200 180 A2E001
                L       A, 0f8h                ; 076E 1 200 180 E5F8
                ST      A, IE                  ; 0770 1 200 180 D51A
                MOV     DP, #00006h            ; 0772 1 200 180 620600
                CLR     A                      ; 0775 1 200 180 F9
                MOV     X1, A                  ; 0776 1 200 180 50
                ST      A, er0                 ; 0777 1 200 180 88
                ST      A, er1                 ; 0778 1 200 180 89
rpm_period_accum_goto_7aec:     J       rpm_period_accum_load_tbl_x1             ; 0779 1 200 180 03EC7A
rpm_period_overflow_check:     JEQ     rpm_period_invalid             ; 077C 1 200 180 C91B
rpm_period_accum:     ADD     er1, A                 ; 077E 1 200 180 4581
                ADCB    r0, #000h              ; 0780 1 200 180 209000
                INC     X1                     ; 0783 1 200 180 70
                INC     X1                     ; 0784 1 200 180 70
                JRNZ    DP, rpm_period_accum_goto_7aec         ; 0785 1 200 180 30F2
                RB      off(00217h).4          ; 0787 1 200 180 C4170C
                RB      off(00231h).5          ; 078A 1 200 180 C4310D
                L       A, er1                 ; 078D 1 200 180 35
                MOV     er2, #00005h           ; 078E 1 200 180 46980500
                DIV                            ; 0792 1 200 180 9037
                CMPB    r0, #000h              ; 0794 1 200 180 20C000
                JEQ     rpm_period_avg_store             ; 0797 1 200 180 C906
rpm_period_invalid:     SB      off(00231h).5          ; 0799 1 200 180 C4311D
                L       A, #0ffffh             ; 079C 1 200 180 67FFFF
rpm_period_avg_store:     ST      A, er0                 ; 079F 1 200 180 88
                CLR     X1                     ; 07A0 1 200 180 9015
                XCHG    A, 0c4h                ; 07A2 1 200 180 B5C410
                ST      A, er1                 ; 07A5 1 200 180 89
                XCHG    A, 0036ch[X1]          ; 07A6 1 200 180 B06C0310
                XCHG    A, 0036eh[X1]          ; 07AA 1 200 180 B06E0310
                XCHG    A, 00370h[X1]          ; 07AE 1 200 180 B0700310
                ST      A, er2                 ; 07B2 1 200 180 8A
                L       A, er0                 ; 07B3 1 200 180 34
                SUB     A, er2                 ; 07B4 1 200 180 2A
                MB      off(0021bh).7, C       ; 07B5 1 200 180 C41B3F
                JGE     rpm_accel_limit_check             ; 07B8 1 200 180 CD01
                VCAL    7                      ; 07BA 1 200 180 17
rpm_accel_limit_check:     ST      A, 0c8h                ; 07BB 1 200 180 D5C8
                L       A, er0                 ; 07BD 1 200 180 34
                SUB     A, er1                 ; 07BE 1 200 180 29
                MB      off(0021bh).6, C       ; 07BF 1 200 180 C41B3E
                JGE     rpm_decel_limit_check             ; 07C2 1 200 180 CD01
                VCAL    7                      ; 07C4 1 200 180 17
rpm_decel_limit_check:     ST      A, 0c6h                ; 07C5 1 200 180 D5C6
                L       A, 0c4h                ; 07C7 1 200 180 E5C4
                CMP     A, #000eah             ; 07C9 1 200 180 C6EA00
                JLT     rpm_period_normalize_lowrange             ; 07CC 1 200 180 CA38
                CMP     A, #00ea6h             ; 07CE 1 200 180 C6A60E
                JGE     rpm_period_normalize_highrange             ; 07D1 1 200 180 CD40
                MOV     er3, #0ffc0h           ; 07D3 1 200 180 4798C0FF
                MOV     er0, #00007h           ; 07D7 1 200 180 44980700
                MOV     er2, #00753h           ; 07DB 1 200 180 46985307
                MOV     X1, #05300h            ; 07DF 1 200 180 600053
rpm_divide_normalize_loop:     CMP     A, er2                 ; 07E2 1 200 180 4A
                JGE     rpm_divide_execute             ; 07E3 1 200 180 CD0C
                SRL     er0                    ; 07E5 1 200 180 44E7
                ROR     X1                     ; 07E7 1 200 180 90C7
                ADD     er3, #00040h           ; 07E9 1 200 180 47804000
                SRL     er2                    ; 07ED 1 200 180 46E7
                SJ      rpm_divide_normalize_loop             ; 07EF 1 200 180 CBF1
rpm_divide_execute:     ST      A, er2                 ; 07F1 1 200 180 8A
                L       A, X1                  ; 07F2 1 200 180 40
                DIV                            ; 07F3 1 200 180 9037
                SRL     A                      ; 07F5 1 200 180 63
                MB      PSWL.4, C              ; 07F6 1 200 180 A33C
                ADD     er3, A                 ; 07F8 1 200 180 4781
                LB      A, r7                  ; 07FA 0 200 180 7F
                JNE     rpm_clamp_0xfe             ; 07FB 0 200 180 CE10
                LB      A, r6                  ; 07FD 0 200 180 7E
                JEQ     rpm_normalize_flag_set             ; 07FE 0 200 180 C917
                CMPB    A, #0ffh               ; 0800 0 200 180 C6FF
                JGE     rpm_clamp_0xfe             ; 0802 0 200 180 CD09
                SJ      rpm_calc_finalize             ; 0804 0 200 180 CB15
rpm_period_normalize_lowrange:     CMP     A, #000bbh             ; 0806 1 200 180 C6BB00
                LB      A, #0ffh               ; 0809 0 200 180 77FF
                JLT     rpm_period_normalize_done             ; 080B 0 200 180 CA02
rpm_clamp_0xfe:     LB      A, #0feh               ; 080D 0 200 180 77FE
rpm_period_normalize_done:     SB      PSWL.4                 ; 080F 0 200 180 A31C
                SJ      rpm_calc_finalize             ; 0811 0 200 180 CB08
rpm_period_normalize_highrange:     CLRB    A                      ; 0813 0 200 180 FA
                JBS     off(00217h).4, rpm_normalize_flag_clear ; 0814 0 200 180 EC1702
rpm_normalize_flag_set:     LB      A, #001h               ; 0817 0 200 180 7701
rpm_normalize_flag_clear:     RB      PSWL.4                 ; 0819 0 200 180 A30C
rpm_calc_finalize:     MB      C, PSWL.4              ; 081B 0 200 180 A32C
                MB      0b8h.4, C              ; 081D 0 200 180 C5B83C
                STB     A, (00133h-00180h)[USP] ; 0820 0 200 180 D3B3
                XCHGB   A, off(00238h)         ; 0822 0 200 180 C43810
                STB     A, 0c3h                ; 0825 0 200 180 D5C3
                CLRB    r7                     ; 0827 0 200 180 2715
                JBS     off(00217h).4, loadindex_flag_default ; 0829 0 200 180 EC1717
                DECB    r7                     ; 082C 0 200 180 BF
                MOV     er2, 0c4h              ; 082D 0 200 180 B5C44A
                MOV     er0, #0d000h           ; 0830 0 200 180 449800D0
                CLR     A                      ; 0834 1 200 180 F9
                DIV                            ; 0835 1 200 180 9037
                SLL     A                      ; 0837 1 200 180 53
                LB      A, r1                  ; 0838 0 200 180 79
                RORB    A                      ; 0839 0 200 180 43
                SC                             ; 083A 0 200 180 85
                JNE     loadindex_flag_load             ; 083B 0 200 180 CE07
                SLLB    A                      ; 083D 0 200 180 53
                LB      A, r0                  ; 083E 0 200 180 78
                JNE     loadindex_store             ; 083F 0 200 180 CE04
                MOVB    r7, #001h              ; 0841 0 200 180 9F01
loadindex_flag_default:     RC                             ; 0843 0 200 180 95
loadindex_flag_load:     LB      A, r7                  ; 0844 0 200 180 7F
loadindex_store:     STB     A, 0c2h                ; 0845 0 200 180 D5C2
                MB      0b8h.3, C              ; 0847 0 200 180 C5B83B
                JBS     off(00212h).2, map_sign_flag_clear ; 084A 0 200 180 EA1217
                L       A, 0bah                ; 084D 1 200 180 E5BA
                SWAP                           ; 084F 1 200 180 83
                LB      A, ACC                 ; 0850 0 200 180 F506
                CMPB    A, #0a1h               ; 0852 0 200 180 C6A1
                JGT     dtc03_map_latch             ; 0854 0 200 180 C804
                CMPB    A, #00bh               ; 0856 0 200 180 C60B
                JGE     map_neg_helper_call             ; 0858 0 200 180 CD07
dtc03_map_latch:     SB      0b0h.0                 ; 085A 0 200 180 C5B018
                LB      A, off(00237h)         ; 085D 0 200 180 F437
                SJ      map_sign_gate2             ; 085F 0 200 180 CB09
map_neg_helper_call:     CAL     sub_clamp_helper             ; 0861 0 200 180 32F858
map_sign_flag_clear:     RB      0b0h.0                 ; 0864 0 200 180 C5B008
                JBS     off(00212h).2, map_sign_gate3 ; 0867 0 200 180 EA1203
map_sign_gate2:     JBR     off(00212h).4, map_sign_gate4 ; 086A 0 200 180 DC1206
map_sign_gate3:     LB      A, 0d1h                ; 086D 0 200 180 F5D1
                MOV     X1, #tbl_map_sign          ; 086F 0 200 180 60D76D
                VCAL    1                      ; 0872 0 200 180 11
map_sign_gate4:     STB     A, r0                  ; 0873 0 200 180 88
                LB      A, off(00237h)         ; 0874 0 200 180 F437
                SUBB    A, r0                  ; 0876 0 200 180 28
                MB      off(0021bh).4, C       ; 0877 0 200 180 C41B3C
                JGE     map_delta_store             ; 087A 0 200 180 CD01
                VCAL    6                      ; 087C 0 200 180 16
map_delta_store:     STB     A, 0c0h                ; 087D 0 200 180 D5C0
                MOV     DP, #00373h            ; 087F 0 200 180 627303
                LB      A, [DP]                ; 0882 0 200 180 F2
                SUBB    A, r0                  ; 0883 0 200 180 28
                MB      off(0021bh).5, C       ; 0884 0 200 180 C41B3D
                JGE     map_delta2_store             ; 0887 0 200 180 CD01
                VCAL    6                      ; 0889 0 200 180 16
map_delta2_store:     STB     A, 0c1h                ; 088A 0 200 180 D5C1
                LB      A, r0                  ; 088C 0 200 180 78
                STB     A, (00132h-00180h)[USP] ; 088D 0 200 180 D3B2
                XCHGB   A, off(00237h)         ; 088F 0 200 180 C43710
                XCHGB   A, 0bdh                ; 0892 0 200 180 C5BD10
                DEC     DP                     ; 0895 0 200 180 82
                XCHGB   A, [DP]                ; 0896 0 200 180 C210
                INC     DP                     ; 0898 0 200 180 72
                STB     A, [DP]                ; 0899 0 200 180 D2
                LB      A, #059h               ; 089A 0 200 180 7759
                JBS     off(00212h).2, tps_custom_clamp_store ; 089C 0 200 180 EA120A
                JBS     off(00212h).4, tps_custom_clamp_store ; 089F 0 200 180 EC1207
                LB      A, 0bch                ; 08A2 0 200 180 F5BC
                SUBB    A, off(00237h)         ; 08A4 0 200 180 A737
                JGE     tps_custom_clamp_store             ; 08A6 0 200 180 CD01
                CLRB    A                      ; 08A8 0 200 180 FA
tps_custom_clamp_store:     STB     A, 0beh                ; 08A9 0 200 180 D5BE
                MOV     er0, #04d00h           ; 08AB 0 200 180 4498004D
                RC                             ; 08AF 0 200 180 95
                JBS     off(00212h).6, dtc07_tps_latch ; 08B0 0 200 180 EE120B
                MOV     er0, ADCR7             ; 08B3 0 200 180 B56E48
                LB      A, #0fch               ; 08B6 0 200 180 77FC
                CMPB    A, r1                  ; 08B8 0 200 180 49
                JLT     dtc07_tps_latch             ; 08B9 0 200 180 CA03
                CMPB    r1, #005h              ; 08BB 0 200 180 21C005
dtc07_tps_latch:     MB      0b0h.2, C              ; 08BE 0 200 180 C5B03A
                JLT     tps_delta_alt_path             ; 08C1 0 200 180 CA19
                L       A, er0                 ; 08C3 1 200 180 34
                SLL     A                      ; 08C4 1 200 180 53
                JLT     tps_delta_clamp1             ; 08C5 1 200 180 CA05
                SLL     A                      ; 08C7 1 200 180 53
                LB      A, ACCH                ; 08C8 0 200 180 F507
                JGE     tps_delta_store1             ; 08CA 0 200 180 CD02
tps_delta_clamp1:     LB      A, #0ffh               ; 08CC 0 200 180 77FF
; [H] --- Repeated rate-of-change/plausibility check pattern applied to several TPS-related raw
; [H] values (0xD0/0xD2/0xD4/0xD6) across 0x852-0x8C9: compute delta, clamp to 0xFF, trigger
; [H] VCAL 7 (erratic-sensor diagnostic, same call used for RPM plausibility earlier) if out of
; [H] range. No calibration anchors; likely dual/redundant TPS channel handling.
tps_delta_store1:     STB     A, 0d4h                ; 08CE 0 200 180 D5D4
                L       A, er0                 ; 08D0 1 200 180 34
                XCHG    A, 0d0h                ; 08D1 1 200 180 B5D010
                MOV     er1, 0d2h              ; 08D4 1 200 180 B5D249
                ST      A, 0d2h                ; 08D7 1 200 180 D5D2
                JBR     off(00212h).6, tps_delta_check1 ; 08D9 1 200 180 DE1204
tps_delta_alt_path:     L       A, er0                 ; 08DC 1 200 180 34
                MOV     er1, 0d0h              ; 08DD 1 200 180 B5D049
tps_delta_check1:     SUB     A, er0                 ; 08E0 1 200 180 28
                MB      PSWL.4, C              ; 08E1 1 200 180 A33C
                JGE     tps_delta_clamp2             ; 08E3 1 200 180 CD01
                VCAL    7                      ; 08E5 1 200 180 17
tps_delta_clamp2:     SLL     A                      ; 08E6 1 200 180 53
                JLT     tps_delta_clamp2_max             ; 08E7 1 200 180 CA05
                SLL     A                      ; 08E9 1 200 180 53
                LB      A, ACCH                ; 08EA 0 200 180 F507
                JGE     tps_delta_store2             ; 08EC 0 200 180 CD02
tps_delta_clamp2_max:     LB      A, #0ffh               ; 08EE 0 200 180 77FF
tps_delta_store2:     STB     A, r0                  ; 08F0 0 200 180 88
                MB      C, PSWL.4              ; 08F1 0 200 180 A32C
                RB      off(0021bh).1          ; 08F3 0 200 180 C41B09
                MB      off(0021bh).1, C       ; 08F6 0 200 180 C41B39
                XCHGB   A, 0d5h                ; 08F9 0 200 180 C5D510
                JEQ     tps_delta_sign_check             ; 08FC 0 200 180 C903
                XORB    PSWH, #080h            ; 08FE 0 200 180 A2F080
tps_delta_sign_check:     JLT     tps_delta_flag_store             ; 0901 0 200 180 CA01
                CMPB    A, r0                  ; 0903 0 200 180 48
tps_delta_flag_store:     MB      off(0021bh).3, C       ; 0904 0 200 180 C41B3B
                L       A, er1                 ; 0907 1 200 180 35
                SUB     A, 0d0h                ; 0908 1 200 180 B5D0A2
                MB      off(0021bh).2, C       ; 090B 1 200 180 C41B3A
                JGE     tps_delta_clamp3             ; 090E 1 200 180 CD01
                VCAL    7                      ; 0910 1 200 180 17
tps_delta_clamp3:     SLL     A                      ; 0911 1 200 180 53
                JLT     tps_delta_clamp3_max             ; 0912 1 200 180 CA05
                SLL     A                      ; 0914 1 200 180 53
                LB      A, ACCH                ; 0915 0 200 180 F507
                JGE     tps_delta_store3             ; 0917 0 200 180 CD02
tps_delta_clamp3_max:     LB      A, #0ffh               ; 0919 0 200 180 77FF
tps_delta_store3:     STB     A, 0d6h                ; 091B 0 200 180 D5D6
                L       A, off(00296h)         ; 091D 1 200 180 E496
                ST      A, er0                 ; 091F 1 200 180 88
                LB      A, r1                  ; 0920 0 200 180 79
                JBR     off(0021ah).1, tps_delta_compare_final ; 0921 0 200 180 D91A01
                LB      A, r0                  ; 0924 0 200 180 78
tps_delta_compare_final:     CMPB    A, off(00238h)         ; 0925 0 200 180 C738
                MB      off(0021ah).1, C       ; 0927 0 200 180 C41A39
                LB      A, r1                  ; 092A 0 200 180 79
                JBR     off(0022bh).0, tps_window_calc1 ; 092B 0 200 180 D82B01
                LB      A, r0                  ; 092E 0 200 180 78
tps_window_calc1:     ADDB    A, #00dh               ; 092F 0 200 180 860D
                JGE     tps_window_store1             ; 0931 0 200 180 CD02
                LB      A, #0ffh               ; 0933 0 200 180 77FF
tps_window_store1:     CMPB    A, off(00238h)         ; 0935 0 200 180 C738
                MB      off(0022bh).0, C       ; 0937 0 200 180 C42B38
                MOV     DP, #00311h            ; 093A 0 200 180 621103
                MOVB    r4, [DP]               ; 093D 0 200 180 C24C
                LB      A, #003h               ; 093F 0 200 180 7703
                STB     A, r2                  ; 0941 0 200 180 8A
                MOVB    r3, #006h              ; 0942 0 200 180 9B06
                MB      C, off(00218h).2       ; 0944 0 200 180 C4182A
                MB      off(00218h).3, C       ; 0947 0 200 180 C4183B
                JLT     tps_window_calc2             ; 094A 0 200 180 CA01
                LB      A, r3                  ; 094C 0 200 180 7B
tps_window_calc2:     ADDB    A, r4                  ; 094D 0 200 180 0C
                CMPB    A, 0d4h                ; 094E 0 200 180 C5D4C2
                MB      off(00218h).2, C       ; 0951 0 200 180 C4183A
                LB      A, #004h               ; 0954 0 200 180 7704
                JBS     off(00218h).4, tps_window_calc3 ; 0956 0 200 180 EC1802
                LB      A, #007h               ; 0959 0 200 180 7707
tps_window_calc3:     ADDB    A, r4                  ; 095B 0 200 180 0C
                CMPB    A, 0d4h                ; 095C 0 200 180 C5D4C2
                MB      off(00218h).4, C       ; 095F 0 200 180 C4183C
                LB      A, r2                  ; 0962 0 200 180 7A
                MB      C, off(00218h).0       ; 0963 0 200 180 C41828
                MB      off(00218h).1, C       ; 0966 0 200 180 C41839
                JGE     tps_window_calc4             ; 0969 0 200 180 CD03
                MOVB    r0, r1                 ; 096B 0 200 180 2148
                LB      A, r3                  ; 096D 0 200 180 7B
tps_window_calc4:     ADDB    A, r4                  ; 096E 0 200 180 0C
                CMPB    0d4h, A                ; 096F 0 200 180 C5D4C1
                JGE     tps_window_store2             ; 0972 0 200 180 CD03
                LB      A, off(00238h)         ; 0974 0 200 180 F438
                CMPB    A, r0                  ; 0976 0 200 180 48
tps_window_store2:     MB      off(00218h).0, C       ; 0977 0 200 180 C41838
                MOVB    r0, 0c0h               ; 097A 0 200 180 C5C048
                MOVB    r1, off(00237h)        ; 097D 0 200 180 C43749
                JBS     off(0021ch).0, tps_interp_exact_match ; 0980 0 200 180 E81C2A
                JBR     off(0021ah).1, tps_interp_exact_match ; 0983 0 200 180 D91A27
                JBS     off(00212h).2, tps_interp_exact_match ; 0986 0 200 180 EA1224
                JBS     off(00212h).4, tps_interp_exact_match ; 0989 0 200 180 EC1221
                MOVB    r4, #0ffh              ; 098C 0 200 180 9CFF
                LB      A, 0bdh                ; 098E 0 200 180 F5BD
                MOV     DP, #tbl_tps_custom_curve2          ; 0990 0 200 180 621061
                MOV     X1, #tbl_tps_custom_curve          ; 0993 0 200 180 600C61
                CMPB    A, #0b0h               ; 0996 0 200 180 C6B0
                JGE     tps_table_offset_check             ; 0998 0 200 180 CD08
                INC     DP                     ; 099A 0 200 180 72
                INC     DP                     ; 099B 0 200 180 72
                CMPB    A, #040h               ; 099C 0 200 180 C640
                JGE     tps_table_offset_check             ; 099E 0 200 180 CD02
                INC     DP                     ; 09A0 0 200 180 72
                INC     DP                     ; 09A1 0 200 180 72
tps_table_offset_check:     JBS     off(0021bh).4, tps_table_lookup ; 09A2 0 200 180 EC1B03
                INC     X1                     ; 09A5 0 200 180 70
                INC     X1                     ; 09A6 0 200 180 70
                INC     DP                     ; 09A7 0 200 180 72
tps_table_lookup:     LC      A, [X1]                ; 09A8 0 200 180 90A8
                CMPB    A, r0                  ; 09AA 0 200 180 48
                JLT     tps_interp_clamp_check             ; 09AB 0 200 180 CA03
tps_interp_exact_match:     LB      A, r1                  ; 09AD 0 200 180 79
                SJ      tps_interp_store             ; 09AE 0 200 180 CB2A
tps_interp_clamp_check:     LB      A, ACCH                ; 09B0 0 200 180 F507
                CMPB    A, r0                  ; 09B2 0 200 180 48
                JGE     tps_interp_weight_calc             ; 09B3 0 200 180 CD01
                STB     A, r0                  ; 09B5 0 200 180 88
tps_interp_weight_calc:     LCB     A, [DP]                ; 09B6 0 200 180 92AA
                MULB                           ; 09B8 0 200 180 A234
                L       A, ACC                 ; 09BA 1 200 180 E506
                SRL     A                      ; 09BC 1 200 180 63
                SRL     A                      ; 09BD 1 200 180 63
                SRL     A                      ; 09BE 1 200 180 63
                SRL     A                      ; 09BF 1 200 180 63
                ST      A, er1                 ; 09C0 1 200 180 89
                LB      A, r3                  ; 09C1 0 200 180 7B
                JNE     tps_interp_zero_check             ; 09C2 0 200 180 CE12
                LB      A, r1                  ; 09C4 0 200 180 79
                JBR     off(0021bh).4, tps_interp_sub_check ; 09C5 0 200 180 DC1B05
                ADDB    A, r2                  ; 09C8 0 200 180 0A
                JLT     tps_interp_clamp_result             ; 09C9 0 200 180 CA08
                SJ      tps_interp_range_check             ; 09CB 0 200 180 CB03
tps_interp_sub_check:     SUBB    A, r2                  ; 09CD 0 200 180 2A
                JLT     tps_interp_zero_check             ; 09CE 0 200 180 CA06
tps_interp_range_check:     CMPB    A, r4                  ; 09D0 0 200 180 4C
                JLE     tps_interp_store             ; 09D1 0 200 180 CF07
tps_interp_clamp_result:     LB      A, r4                  ; 09D3 0 200 180 7C
                SJ      tps_interp_store             ; 09D4 0 200 180 CB04
tps_interp_zero_check:     CLRB    A                      ; 09D6 0 200 180 FA
                JBS     off(0021bh).4, tps_interp_clamp_result ; 09D7 0 200 180 EC1BF9
tps_interp_store:     STB     A, 0bfh                ; 09DA 0 200 180 D5BF
                L       A, 0c4h                ; 09DC 1 200 180 E5C4
                SUB     A, off(0025ch)         ; 09DE 1 200 180 A75C
                MB      off(0021ah).4, C       ; 09E0 1 200 180 C41A3C
                MOV     er0, #00300h           ; 09E3 1 200 180 44980003
                JGE     rpm_avg_range_check             ; 09E7 1 200 180 CD05
                VCAL    7                      ; 09E9 1 200 180 17
                MOV     er0, #00300h           ; 09EA 1 200 180 44980003
rpm_avg_range_check:     CMP     A, er0                 ; 09EE 1 200 180 48
                JLT     rpm_avg_store             ; 09EF 1 200 180 CA01
                L       A, er0                 ; 09F1 1 200 180 34
rpm_avg_store:     ST      A, 0cah                ; 09F2 1 200 180 D5CA
                LB      A, #0cdh               ; 09F4 0 200 180 77CD
                JBS     off(00218h).5, rpm_avg_store_cmp_acc ; 09F6 0 200 180 ED1802
                LB      A, #0d0h               ; 09F9 0 200 180 77D0
rpm_avg_store_cmp_acc:     CMPB    A, off(00238h)         ; 09FB 0 200 180 C738
                MB      off(00218h).5, C       ; 09FD 0 200 180 C4183D
                LB      A, #03ah               ; 0A00 0 200 180 773A
                JBS     off(00217h).0, rpm_avg_store_cmp_acc_2 ; 0A02 0 200 180 E81702
                LB      A, #040h               ; 0A05 0 200 180 7740
rpm_avg_store_cmp_acc_2:     CMPB    A, off(00238h)         ; 0A07 0 200 180 C738
                MB      off(00217h).0, C       ; 0A09 0 200 180 C41738
                MOV     X1, #Scaler_RpmAxis_Lo          ; 0A0C 0 200 180 601470
                MOVB    r3, (001c6h-00180h)[USP] ; 0A0F 0 200 180 C3464B
                MOVB    r2, off(00238h)        ; 0A12 0 200 180 C4384A
                MOVB    r6, #012h              ; 0A15 0 200 180 9E12
                MB      C, 0b8h.4              ; 0A17 0 200 180 C5B82C
                MB      PSWL.4, C              ; 0A1A 0 200 180 A33C
                CAL     newval_table3_call_sub_clear_acc             ; 0A1C 0 200 180 32B259
                STB     A, (001c2h-00180h)[USP] ; 0A1F 0 200 180 D342
                LB      A, r6                  ; 0A21 0 200 180 7E
                STB     A, (001c6h-00180h)[USP] ; 0A22 0 200 180 D346
                MOV     X1, #rpm_avg_store_tbl          ; 0A24 0 200 180 602870
                MOVB    r3, (001c7h-00180h)[USP] ; 0A27 0 200 180 C3474B
                MOVB    r2, 0c2h               ; 0A2A 0 200 180 C5C24A
                MOVB    r6, #012h              ; 0A2D 0 200 180 9E12
                MB      C, 0b8h.3              ; 0A2F 0 200 180 C5B82B
                JBR     off(00227h).5, rpm_avg_store_store_carry_pswl_bit4 ; 0A32 0 200 180 DD2706
                MOVB    r2, off(00238h)        ; 0A35 0 200 180 C4384A
                MB      C, 0b8h.4              ; 0A38 0 200 180 C5B82C
rpm_avg_store_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 0A3B 0 200 180 A33C
                CAL     newval_table3_call_sub_clear_acc             ; 0A3D 0 200 180 32B259
                STB     A, (001c4h-00180h)[USP] ; 0A40 0 200 180 D344
                LB      A, r6                  ; 0A42 0 200 180 7E
                STB     A, (001c7h-00180h)[USP] ; 0A43 0 200 180 D347
                LB      A, 0bch                ; 0A45 0 200 180 F5BC
                JBS     off(00212h).2, newval_table3_call ; 0A47 0 200 180 EA1205
                JBS     off(00212h).4, newval_table3_call ; 0A4A 0 200 180 EC1202
                LB      A, 0bfh                ; 0A4D 0 200 180 F5BF
newval_table3_call:     STB     A, r2                  ; 0A4F 0 200 180 8A
                MOV     X1, #newval_table3_call_tbl_3          ; 0A50 0 200 180 600070
                MOVB    r3, (001bbh-00180h)[USP] ; 0A53 0 200 180 C33B4B
                MOVB    r6, #008h              ; 0A56 0 200 180 9E08
                RB      PSWL.4                 ; 0A58 0 200 180 A30C
                CAL     newval_table3_call_sub_clear_acc             ; 0A5A 0 200 180 32B259
                STB     A, (001beh-00180h)[USP] ; 0A5D 0 200 180 D33E
                LB      A, r6                  ; 0A5F 0 200 180 7E
                STB     A, (001bbh-00180h)[USP] ; 0A60 0 200 180 D33B
                LB      A, 0bfh                ; 0A62 0 200 180 F5BF
                STB     A, r2                  ; 0A64 0 200 180 8A
                MOV     X1, #newval_table3_call_tbl_3          ; 0A65 0 200 180 600070
                MOVB    r3, (001bch-00180h)[USP] ; 0A68 0 200 180 C33C4B
                MOVB    r6, #008h              ; 0A6B 0 200 180 9E08
                RB      PSWL.4                 ; 0A6D 0 200 180 A30C
                CAL     newval_table3_call_sub_clear_acc             ; 0A6F 0 200 180 32B259
                STB     A, (001c0h-00180h)[USP] ; 0A72 0 200 180 D340
                LB      A, r6                  ; 0A74 0 200 180 7E
                STB     A, (001bch-00180h)[USP] ; 0A75 0 200 180 D33C
                JBR     off(00216h).7, newval_table3_call_clear_carry ; 0A77 0 200 180 DF161F
                MB      C, off(00223h).5       ; 0A7A 0 200 180 C4232D
                MB      PSWL.4, C              ; 0A7D 0 200 180 A33C
                LB      A, #0ffh               ; 0A7F 0 200 180 77FF
                CMPB    A, off(0029eh)         ; 0A81 0 200 180 C79E
                MB      off(00223h).5, C       ; 0A83 0 200 180 C4233D
                JGE     newval_table3_call_load_dp             ; 0A86 0 200 180 CD03
                XORB    PSWL, #010h            ; 0A88 0 200 180 A3F010
newval_table3_call_load_dp:     MOV     DP, #003eeh            ; 0A8B 0 200 180 62EE03
                LB      A, #0ffh               ; 0A8E 0 200 180 77FF
                JBS     off(0021dh).6, newval_table3_call_store_ram29c ; 0A90 0 200 180 EE1D0B
                LB      A, off(0029ch)         ; 0A93 0 200 180 F49C
                JNE     newval_table3_call_subb_acc             ; 0A95 0 200 180 CE05
                CLR     A                      ; 0A97 1 200 180 F9
                ST      A, [DP]                ; 0A98 1 200 180 D2
newval_table3_call_clear_carry:     RC                             ; 0A99 1 200 180 95
                SJ      newval_table3_call_store_carry_ram219_bit6             ; 0A9A 1 200 180 CB21
newval_table3_call_subb_acc:     SUBB    A, #001h               ; 0A9C 0 200 180 A601
newval_table3_call_store_ram29c:     STB     A, off(0029ch)         ; 0A9E 0 200 180 D49C
                MOV     X1, #newval_table3_call_tbl          ; 0AA0 0 200 180 603A65
                JBS     off(00223h).5, newval_table3_call_load_carry_pswl_bit4 ; 0AA3 0 200 180 ED2304
                INC     DP                     ; 0AA6 0 200 180 72
                MOV     X1, #newval_table3_call_tbl_2          ; 0AA7 0 200 180 603E65
newval_table3_call_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 0AAA 0 200 180 A32C
                JGE     newval_table3_call_load_carry_ram223_bit5             ; 0AAC 0 200 180 CD04
                LB      A, off(00237h)         ; 0AAE 0 200 180 F437
                VCAL    1                      ; 0AB0 0 200 180 11
                STB     A, [DP]                ; 0AB1 0 200 180 D2
newval_table3_call_load_carry_ram223_bit5:     MB      C, off(00223h).5       ; 0AB2 0 200 180 C4232D
                LB      A, [DP]                ; 0AB5 0 200 180 F2
                JEQ     newval_table3_call_store_carry_ram219_bit6             ; 0AB6 0 200 180 C905
                DECB    [DP]                   ; 0AB8 0 200 180 C217
                XORB    PSWH, #080h            ; 0ABA 0 200 180 A2F080
newval_table3_call_store_carry_ram219_bit6:     MB      off(00219h).6, C       ; 0ABD 0 200 180 C4193E
                CLR     er2                    ; 0AC0 0 200 180 4615
                SC                             ; 0AC2 0 200 180 85
                JBR     off(00227h).6, mode_flags_pack4 ; 0AC3 0 200 180 DE276B
                LB      A, (001bbh-00180h)[USP] ; 0AC6 0 200 180 F33B
                ADDB    A, #001h               ; 0AC8 0 200 180 8601
                CMPB    0bfh, #000h            ; 0ACA 0 200 180 C5BFC000
                JNE     mode_flags_pack_start             ; 0ACE 0 200 180 CE01
                CLRB    A                      ; 0AD0 0 200 180 FA
mode_flags_pack_start:     MOV     er0, off(00212h)       ; 0AD1 0 200 180 B41248
                AND     er0, #0c3bch           ; 0AD4 0 200 180 44D0BCC3
                JNE     mode_flags_pack_alt             ; 0AD8 0 200 180 CE03
                JBR     off(00214h).5, mode_flags_pack_store ; 0ADA 0 200 180 DD1402
mode_flags_pack_alt:     LB      A, #00fh               ; 0ADD 0 200 180 770F
mode_flags_pack_store:     STB     A, r1                  ; 0ADF 0 200 180 89
                RC                             ; 0AE0 0 200 180 95
                JBS     off(00214h).5, mode_flags_pack2 ; 0AE1 0 200 180 ED1403
                MB      C, off(00211h).1       ; 0AE4 0 200 180 C41129
mode_flags_pack2:     MB      off(00233h).3, C       ; 0AE7 0 200 180 C4333B
                MB      C, off(0021ch).2       ; 0AEA 0 200 180 C41C2A
                MB      off(00233h).4, C       ; 0AED 0 200 180 C4333C
                SC                             ; 0AF0 0 200 180 85
                LB      A, (0019ch-00180h)[USP] ; 0AF1 0 200 180 F31C
                JNE     mode_flags_pack3             ; 0AF3 0 200 180 CE07
                LB      A, off(0023eh)         ; 0AF5 0 200 180 F43E
                JNE     mode_flags_pack3             ; 0AF7 0 200 180 CE03
                MB      C, off(00220h).1       ; 0AF9 0 200 180 C42029
mode_flags_pack3:     MB      off(00233h).5, C       ; 0AFC 0 200 180 C4333D
                LB      A, off(00233h)         ; 0AFF 0 200 180 F433
                MOVB    r0, #010h              ; 0B01 0 200 180 9810
                MULB                           ; 0B03 0 200 180 A234
                ORB     A, r1                  ; 0B05 0 200 180 69
                L       A, ACC                 ; 0B06 1 200 180 E506
                ST      A, er2                 ; 0B08 1 200 180 8A
                MOV     er0, #00101h           ; 0B09 1 200 180 44980101
                MOVB    r2, #005h              ; 0B0D 1 200 180 9A05
scale_div32_loop:     SRL     A                      ; 0B0F 1 200 180 63
                ADCB    r0, #000h              ; 0B10 1 200 180 209000
                SRL     A                      ; 0B13 1 200 180 63
                ADCB    r1, #000h              ; 0B14 1 200 180 219000
                DECB    r2                     ; 0B17 1 200 180 BA
                JNE     scale_div32_loop             ; 0B18 1 200 180 CEF5
                SRLB    r0                     ; 0B1A 1 200 180 20E7
                MB      r5.2, C                ; 0B1C 1 200 180 253A
                SRLB    r1                     ; 0B1E 1 200 180 21E7
                MB      r5.3, C                ; 0B20 1 200 180 253B
                LB      A, (001afh-00180h)[USP] ; 0B22 0 200 180 F32F
                CMPB    A, #007h               ; 0B24 0 200 180 C607
                JLT     mode_flags_pack4             ; 0B26 0 200 180 CA09
                LB      A, (001b7h-00180h)[USP] ; 0B28 0 200 180 F337
                CMPB    A, #019h               ; 0B2A 0 200 180 C619
                JLT     mode_flags_pack4             ; 0B2C 0 200 180 CA03
                MB      C, off(0021dh).7       ; 0B2E 0 200 180 C41D2F
mode_flags_pack4:     MB      off(00233h).6, C       ; 0B31 0 200 180 C4333E
                L       A, er2                 ; 0B34 1 200 180 36
                ST      A, 0eah                ; 0B35 1 200 180 D5EA
                MOV     DP, #003c6h            ; 0B37 1 200 180 62C603
                LB      A, ADCR0H              ; 0B3A 0 200 180 F561
                STB     A, [DP]                ; 0B3C 0 200 180 D2
                STB     A, 0dah                ; 0B3D 0 200 180 D5DA
                MOV     DP, #003ceh            ; 0B3F 0 200 180 62CE03
                LB      A, ADCR1H              ; 0B42 0 200 180 F563
                STB     A, [DP]                ; 0B44 0 200 180 D2
                L       A, 0fah                ; 0B45 1 200 180 E5FA
                ST      A, IE                  ; 0B47 1 200 180 D51A
                ANDB    PSWH, #0feh            ; 0B49 1 200 180 A2D0FE
                RB      ADSCAN.4               ; 0B4C 1 200 180 C5580C
                ORB     P2, off(00259h)        ; 0B4F 1 200 180 C524E359
                RB      IRQH.4                 ; 0B53 1 200 180 C5190C
                SB      ADSCAN.4               ; 0B56 1 200 180 C5581C
                MOV     off(0025ah), TM2       ; 0B59 1 200 180 B5387C5A
                ORB     PSWH, #001h            ; 0B5D 1 200 180 A2E001
                L       A, 0f8h                ; 0B60 1 200 180 E5F8
                ST      A, IE                  ; 0B62 1 200 180 D51A
                JBS     off(0021dh).4, ignmap_alt_path ; 0B64 1 200 180 EC1D5B
                MOVB    r0, #00ah              ; 0B67 1 200 180 980A
                MOVB    r1, #014h              ; 0B69 1 200 180 9914
                MOVB    r2, (001bbh-00180h)[USP] ; 0B6B 1 200 180 C33B4A
                MOV     X2, (001beh-00180h)[USP] ; 0B6E 1 200 180 B33E79
                JBS     off(00227h).5, mode_flags_pack4_load_r3 ; 0B71 1 200 180 ED2717
                MOVB    r3, (001c6h-00180h)[USP] ; 0B74 1 200 180 C3464B
                MOV     er3, (001c2h-00180h)[USP] ; 0B77 1 200 180 B3424B
                MOV     X1, #mode_flags_pack4_tbl          ; 0B7A 1 200 180 60E472
                JBR     off(00214h).5, mode_flags_pack4_load_dp ; 0B7D 1 200 180 DD1403
                JBS     off(00218h).5, ignmap_2d_lookup ; 0B80 1 200 180 ED182C
mode_flags_pack4_load_dp:     MOV     DP, #mode_flags_pack4_tbl_3          ; 0B83 1 200 180 627474
                MOVB    r4, #000h              ; 0B86 1 200 180 9C00
                JBR     off(0021fh).1, mode_flags_pack4_nop_acc ; 0B88 1 200 180 D91F0E
mode_flags_pack4_load_r3:     MOVB    r3, (001c7h-00180h)[USP] ; 0B8B 1 200 180 C3474B
                MOV     er3, (001c4h-00180h)[USP] ; 0B8E 1 200 180 B3444B
                MOV     X1, #mode_flags_pack4_tbl_2          ; 0B91 1 200 180 60AC73
                MOV     DP, #mode_flags_pack4_tbl_4          ; 0B94 1 200 180 62E274
                MOVB    r4, #000h              ; 0B97 1 200 180 9C00
mode_flags_pack4_nop_acc:     NOP                            ; 0B99 1 200 180 00
                NOP                            ; 0B9A 1 200 180 00
                NOP                            ; 0B9B 1 200 180 00
                JBR     off(00219h).6, ignmap_2d_lookup ; 0B9C 1 200 180 DE1910
                LB      A, r4                  ; 0B9F 0 200 180 7C
                CMPB    A, r3                  ; 0BA0 0 200 180 4B
                JGT     ignmap_2d_lookup             ; 0BA1 0 200 180 C80C
                ADDB    A, #00ah               ; 0BA3 0 200 180 860A
                CMPB    A, r3                  ; 0BA5 0 200 180 4B
                JLE     ignmap_2d_lookup             ; 0BA6 0 200 180 CF07
                LB      A, r4                  ; 0BA8 0 200 180 7C
                SUBB    r3, A                  ; 0BA9 0 200 180 23A1
                MOVB    r1, #00bh              ; 0BAB 0 200 180 990B
                MOV     X1, DP                 ; 0BAD 0 200 180 9278
ignmap_2d_lookup:     RB      PSWL.5                 ; 0BAF 0 200 180 A30D
                CAL     table2d_lookup_interp             ; 0BB1 0 200 180 32E459
                MOVB    r0, A                  ; 0BB4 0 200 180 208A
                LB      A, off(00247h)         ; 0BB6 0 200 180 F447
                JEQ     ignmap_scale_skip             ; 0BB8 0 200 180 C905
                MULB                           ; 0BBA 0 200 180 A234
                MOVB    r0, ACCH               ; 0BBC 0 200 180 C50748
ignmap_scale_skip:     LB      A, r0                  ; 0BBF 0 200 180 78
                SJ      ignmap_result_common             ; 0BC0 0 200 180 CB10
ignmap_alt_path:     LB      A, 0c2h                ; 0BC2 0 200 180 F5C2
                MOV     X1, #ignmap_alt_path_tbl          ; 0BC4 0 200 180 60D167
                JBS     off(0021fh).1, ignmap_alt_path_call_table_interp_lookup ; 0BC7 0 200 180 E91F05
                LB      A, off(00238h)         ; 0BCA 0 200 180 F438
                MOV     X1, #ignmap_alt_path_tbl_2          ; 0BCC 0 200 180 60FD67
ignmap_alt_path_call_table_interp_lookup:     CAL     table_interp_lookup             ; 0BCF 0 200 180 323958
ignmap_result_common:     STB     A, off(00248h)         ; 0BD2 0 200 180 D448
                CLRB    A                      ; 0BD4 0 200 180 FA
                CMPB    0d9h, #02eh            ; 0BD5 0 200 180 C5D9C02E
                JGE     idleign_result_store             ; 0BD9 0 200 180 CD1F
                JBR     off(00218h).0, idleign_result_store ; 0BDB 0 200 180 D8181C
                JBS     off(00210h).7, idleign_result_store ; 0BDE 0 200 180 EF1019
                L       A, 0cah                ; 0BE1 1 200 180 E5CA
                MOV     X1, #IgnControl          ; 0BE3 1 200 180 600C6D
                JBS     off(0021ah).4, idleign_table_lookup ; 0BE6 1 200 180 EC1A03
                MOV     X1, #HiIdleIgnControl          ; 0BE9 1 200 180 60FC6C
idleign_table_lookup:     CAL     table_interp_lookup_4byte             ; 0BEC 1 200 180 32D358
                MOVB    r0, #011h              ; 0BEF 1 200 180 9811
                LB      A, r6                  ; 0BF1 0 200 180 7E
                CMPB    A, r0                  ; 0BF2 0 200 180 48
                JLT     idleign_vcal6_check             ; 0BF3 0 200 180 CA01
                LB      A, r0                  ; 0BF5 0 200 180 78
idleign_vcal6_check:     JBR     off(0021ah).4, idleign_result_store ; 0BF6 0 200 180 DC1A01
                VCAL    6                      ; 0BF9 0 200 180 16
idleign_result_store:     STB     A, off(00243h)         ; 0BFA 0 200 180 D443
                LB      A, #01eh               ; 0BFC 0 200 180 771E
                JBS     off(00221h).3, rpm_threshold_221_3 ; 0BFE 0 200 180 EB2102
                LB      A, #010h               ; 0C01 0 200 180 7710
rpm_threshold_221_3:     CMPB    0c5h, A                ; 0C03 0 200 180 C5C5C1
                MB      off(00221h).3, C       ; 0C06 0 200 180 C4213B
                LB      A, #000h               ; 0C09 0 200 180 7700
                JBS     off(00221h).4, rpm_threshold_221_3_cmp_acc ; 0C0B 0 200 180 EC2102
                LB      A, #001h               ; 0C0E 0 200 180 7701
rpm_threshold_221_3_cmp_acc:     CMPB    A, off(00238h)         ; 0C10 0 200 180 C738
                MB      off(00221h).4, C       ; 0C12 0 200 180 C4213C
                CLRB    A                      ; 0C15 0 200 180 FA
                MOV     X1, #tbl_ignmap_idle2          ; 0C16 0 200 180 60D66C
                JBS     off(00221h).2, knockretard_table_gate ; 0C19 0 200 180 EA2105
                INC     X1                     ; 0C1C 0 200 180 70
                INC     X1                     ; 0C1D 0 200 180 70
                MB      C, off(00221h).3       ; 0C1E 0 200 180 C4212B
knockretard_table_gate:     JGE     knockretard_store             ; 0C21 0 200 180 CD0C
                L       A, off(00254h)         ; 0C23 1 200 180 E454
                ST      A, er3                 ; 0C25 1 200 180 8B
                LB      A, off(00237h)         ; 0C26 0 200 180 F437
                CAL     knockretard_helper             ; 0C28 0 200 180 322158
                JBR     off(00221h).2, knockretard_store ; 0C2B 0 200 180 DA2101
                VCAL    6                      ; 0C2E 0 200 180 16
knockretard_store:     STB     A, off(00242h)         ; 0C2F 0 200 180 D442
                LB      A, #046h               ; 0C31 0 200 180 7746
                JBS     off(00222h).5, knockretard_store_cmp_acc ; 0C33 0 200 180 ED2202
                LB      A, #053h               ; 0C36 0 200 180 7753
knockretard_store_cmp_acc:     CMPB    A, off(00238h)         ; 0C38 0 200 180 C738
                MB      off(00222h).5, C       ; 0C3A 0 200 180 C4223D
                CLRB    A                      ; 0C3D 0 200 180 FA
                JBR     off(00227h).7, knockretard2_clamp_store_ram23a ; 0C3E 0 200 180 DF272B
                JBS     off(00213h).1, knockretard2_clamp_store_ram23a ; 0C41 0 200 180 E91328
                JGE     knockretard2_clamp_store_ram23a             ; 0C44 0 200 180 CD26
                CMPB    0d8h, #0b5h            ; 0C46 0 200 180 C5D8C0B5
                JGE     knockretard2_clamp_store_ram23a             ; 0C4A 0 200 180 CD20
                JBS     off(0021dh).5, knockretard2_clamp_store_ram23a ; 0C4C 0 200 180 ED1D1D
                JBS     off(0021ah).3, knockretard2_clamp_store_ram23a ; 0C4F 0 200 180 EB1A1A
                JBR     off(0021ah).2, knockretard2_clamp_store_ram23a ; 0C52 0 200 180 DA1A17
                CLR     A                      ; 0C55 1 200 180 F9
                LB      A, off(00256h)         ; 0C56 0 200 180 F456
                MOV     er3, A                 ; 0C58 0 200 180 478A
                LB      A, off(00237h)         ; 0C5A 0 200 180 F437
                MOV     X1, #tbl_ignmap_idle1          ; 0C5C 0 200 180 60B86C
                CAL     knockretard_helper             ; 0C5F 0 200 180 322158
                LB      A, off(0023ah)         ; 0C62 0 200 180 F43A
                ADDB    A, #001h               ; 0C64 0 200 180 8601
                JLT     knockretard2_clamp             ; 0C66 0 200 180 CA03
                CMPB    A, r6                  ; 0C68 0 200 180 4E
                JLT     knockretard2_clamp_store_ram23a             ; 0C69 0 200 180 CA01
knockretard2_clamp:     LB      A, r6                  ; 0C6B 0 200 180 7E
knockretard2_clamp_store_ram23a:     STB     A, off(0023ah)         ; 0C6C 0 200 180 D43A
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram2b8 ; 0C6E 0 200 180 DA1624
                LB      A, #06dh               ; 0C71 0 200 180 776D
                JBS     off(00216h).3, overrev_hardcap_compare ; 0C73 0 200 180 EB1602
                LB      A, #06dh               ; 0C76 0 200 180 776D
overrev_hardcap_compare:     CMPB    A, off(00238h)         ; 0C78 0 200 180 C738
                JLT     overrev_hardcap_compare_load_ram2b8             ; 0C7A 0 200 180 CA19
                LB      A, 0cch                ; 0C7C 0 200 180 F5CC
                CMPB    A, #02dh               ; 0C7E 0 200 180 C62D
                JGE     overrev_hardcap_compare_load_ram2b8             ; 0C80 0 200 180 CD13
                CMPB    A, #023h               ; 0C82 0 200 180 C623
                JLT     overrev_hardcap_compare_load_ram2b8             ; 0C84 0 200 180 CA0F
                CMPB    0d9h, #028h            ; 0C86 0 200 180 C5D9C028
                JGE     overrev_hardcap_compare_load_ram2b8             ; 0C8A 0 200 180 CD09
                CMPB    off(00237h), #064h     ; 0C8C 0 200 180 C437C064
                JGE     overrev_hardcap_compare_load_ram2b8             ; 0C90 0 200 180 CD03
                JBR     off(0021ah).3, overrev_hardcap_compare_cmp_ram2b8 ; 0C92 0 200 180 DB1A0B
overrev_hardcap_compare_load_ram2b8:     MOVB    off(002b8h), #060h     ; 0C95 0 200 180 C4B89860
                CLRB    A                      ; 0C99 0 200 180 FA
                STB     A, r0                  ; 0C9A 0 200 180 88
                RB      off(00222h).6          ; 0C9B 0 200 180 C4220E
                SJ      overrev_hardcap_compare_store_ram253             ; 0C9E 0 200 180 CB25
overrev_hardcap_compare_cmp_ram2b8:     CMPB    off(002b8h), #00ch     ; 0CA0 0 200 180 C4B8C00C
                JGE     knockretard2_store_clear_acc             ; 0CA4 0 200 180 CD29
                LB      A, off(002b8h)         ; 0CA6 0 200 180 F4B8
                JEQ     overrev_hardcap_compare_cmp_acc             ; 0CA8 0 200 180 C906
                MOVB    off(002b7h), #060h     ; 0CAA 0 200 180 C4B79860
                SJ      overrev_hardcap_compare_load_r0             ; 0CAE 0 200 180 CB05
overrev_hardcap_compare_cmp_acc:     CMPB    A, off(002b7h)         ; 0CB0 0 200 180 C7B7
                MB      off(00222h).6, C       ; 0CB2 0 200 180 C4223E
overrev_hardcap_compare_load_r0:     MOVB    r0, off(0023bh)        ; 0CB5 0 200 180 C43B48
                LB      A, off(00253h)         ; 0CB8 0 200 180 F453
                JEQ     overrev_hardcap_compare_addb_r0             ; 0CBA 0 200 180 C904
                SUBB    A, #001h               ; 0CBC 0 200 180 A601
                SJ      overrev_hardcap_compare_store_ram253             ; 0CBE 0 200 180 CB05
overrev_hardcap_compare_addb_r0:     ADDB    r0, #002h              ; 0CC0 0 200 180 208002
                LB      A, #004h               ; 0CC3 0 200 180 7704
overrev_hardcap_compare_store_ram253:     STB     A, off(00253h)         ; 0CC5 0 200 180 D453
                LB      A, #015h               ; 0CC7 0 200 180 7715
                CMPB    A, r0                  ; 0CC9 0 200 180 48
                JLE     knockretard2_store             ; 0CCA 0 200 180 CF01
                LB      A, r0                  ; 0CCC 0 200 180 78
knockretard2_store:     STB     A, off(0023bh)         ; 0CCD 0 200 180 D43B
knockretard2_store_clear_acc:     CLRB    A                      ; 0CCF 0 200 180 FA
                RC                             ; 0CD0 0 200 180 95
                JBS     off(00233h).6, flags_pack_233_7 ; 0CD1 0 200 180 EE3328
                JBS     off(00212h).3, flags_pack_233_7 ; 0CD4 0 200 180 EB1225
                JBS     off(00213h).0, flags_pack_233_7 ; 0CD7 0 200 180 E81322
                L       A, 0ech                ; 0CDA 1 200 180 E5EC
                ST      A, er2                 ; 0CDC 1 200 180 8A
                CLR     er0                    ; 0CDD 1 200 180 4415
                MOVB    r2, #005h              ; 0CDF 1 200 180 9A05
scale_shift_loop:     SLL     A                      ; 0CE1 1 200 180 53
                ADCB    r1, #000h              ; 0CE2 1 200 180 219000
                SLL     A                      ; 0CE5 1 200 180 53
                ADCB    r0, #000h              ; 0CE6 1 200 180 209000
                DECB    r2                     ; 0CE9 1 200 180 BA
                JNE     scale_shift_loop             ; 0CEA 1 200 180 CEF5
                SLL     A                      ; 0CEC 1 200 180 53
                JGE     scale_direction_toggle             ; 0CED 1 200 180 CD09
                SLL     A                      ; 0CEF 1 200 180 53
                JGE     scale_direction_toggle             ; 0CF0 1 200 180 CD06
                L       A, er0                 ; 0CF2 1 200 180 34
                AND     A, #00101h             ; 0CF3 1 200 180 D60101
                JNE     scale_result_common             ; 0CF6 1 200 180 CE03
scale_direction_toggle:     XORB    PSWH, #080h            ; 0CF8 1 200 180 A2F080
scale_result_common:     LB      A, r5                  ; 0CFB 0 200 180 7D
flags_pack_233_7:     MB      off(00233h).7, C       ; 0CFC 0 200 180 C4333F
                SRLB    A                      ; 0CFF 0 200 180 63
                MB      off(00232h).7, C       ; 0D00 0 200 180 C4323F
                STB     A, r5                  ; 0D03 0 200 180 8D
                CLRB    A                      ; 0D04 0 200 180 FA
                JBR     off(00227h).6, knock_244_store ; 0D05 0 200 180 DE2730
                CMPB    0c5h, #000h            ; 0D08 0 200 180 C5C5C000
                JGT     knock_244_store             ; 0D0C 0 200 180 C82A
                LB      A, 0eah                ; 0D0E 0 200 180 F5EA
                ANDB    A, #00fh               ; 0D10 0 200 180 D60F
                CMPB    A, #00fh               ; 0D12 0 200 180 C60F
                JEQ     knock_244_table_select             ; 0D14 0 200 180 C90C
                JBS     off(00214h).7, knock_244_table_select ; 0D16 0 200 180 EF1409
                JBS     off(00233h).6, knockretard_clear_state ; 0D19 0 200 180 EE331E
                JBS     off(00233h).7, knockretard_clear_state ; 0D1C 0 200 180 EF331B
                LB      A, r5                  ; 0D1F 0 200 180 7D
                SJ      knock_244_store             ; 0D20 0 200 180 CB16
knock_244_table_select:     LB      A, (001c7h-00180h)[USP] ; 0D22 0 200 180 F347
                MOV     er0, (001c4h-00180h)[USP] ; 0D24 0 200 180 B34448
                MOV     DP, #tbl_knock244_a          ; 0D27 0 200 180 62F06D
                JBS     off(0021fh).1, knock_244_table_select_call_knock_244_helper ; 0D2A 0 200 180 E91F08
                LB      A, (001c6h-00180h)[USP] ; 0D2D 0 200 180 F346
                MOV     er0, (001c2h-00180h)[USP] ; 0D2F 0 200 180 B34248
                MOV     DP, #tbl_knock244_b          ; 0D32 0 200 180 62046E
knock_244_table_select_call_knock_244_helper:     CAL     knock_244_helper             ; 0D35 0 200 180 32465A
knock_244_store:     STB     A, off(00246h)         ; 0D38 0 200 180 D446
knockretard_clear_state:     LB      A, #07fh               ; 0D3A 0 200 180 777F
                JBS     off(00221h).6, knockretard_clear_state_cmp_acc ; 0D3C 0 200 180 EE2102
                LB      A, #07fh               ; 0D3F 0 200 180 777F
knockretard_clear_state_cmp_acc:     CMPB    A, off(00246h)         ; 0D41 0 200 180 C746
                MB      off(00221h).6, C       ; 0D43 0 200 180 C4213E
                CLRB    A                      ; 0D46 0 200 180 FA
                CMPB    (0019ch-00180h)[USP], #001h ; 0D47 0 200 180 C31CC001
                JNE     knockretard_clear_state_cmp_stk             ; 0D4B 0 200 180 CE19
                MOV     X1, #knockretard_clear_state_tbl          ; 0D4D 0 200 180 600667
                MB      C, 0b8h.6              ; 0D50 0 200 180 C5B82E
                JGE     knockretard_clear_state_if_ram221_bit6_clr             ; 0D53 0 200 180 CD03
                MOV     X1, #knockretard_clear_state_tbl_2          ; 0D55 0 200 180 605E67
knockretard_clear_state_if_ram221_bit6_clr:     JBR     off(00221h).6, knockretard_clear_state_load_ram238 ; 0D58 0 200 180 DE2104
                ADD     X1, #0002ch            ; 0D5B 0 200 180 90802C00
knockretard_clear_state_load_ram238:     LB      A, off(00238h)         ; 0D5F 0 200 180 F438
                CAL     table_interp_lookup             ; 0D61 0 200 180 323958
                SJ      knockretard_clear_state_store_ram23d             ; 0D64 0 200 180 CB10
knockretard_clear_state_cmp_stk:     CMPB    (0019ch-00180h)[USP], #003h ; 0D66 0 200 180 C31CC003
                JNE     knockretard_clear_state_store_ram23d             ; 0D6A 0 200 180 CE0A
                LB      A, #000h               ; 0D6C 0 200 180 7700
                CMPB    0d9h, #0ffh            ; 0D6E 0 200 180 C5D9C0FF
                JGE     knockretard_clear_state_store_ram23d             ; 0D72 0 200 180 CD02
                LB      A, #0ffh               ; 0D74 0 200 180 77FF
knockretard_clear_state_store_ram23d:     STB     A, off(0023dh)         ; 0D76 0 200 180 D43D
                LB      A, #03ah               ; 0D78 0 200 180 773A
                MOVB    r0, #040h              ; 0D7A 0 200 180 9840
                CMPB    0bch, #0dbh            ; 0D7C 0 200 180 C5BCC0DB
                JGE     knockretard_clear_state_if_ram222_bit0_set             ; 0D80 0 200 180 CD04
                LB      A, #093h               ; 0D82 0 200 180 7793
                MOVB    r0, #097h              ; 0D84 0 200 180 9897
knockretard_clear_state_if_ram222_bit0_set:     JBS     off(00222h).0, knockretard_clear_state_cmp_acc_2 ; 0D86 0 200 180 E82201
                LB      A, r0                  ; 0D89 0 200 180 78
knockretard_clear_state_cmp_acc_2:     CMPB    A, off(00238h)         ; 0D8A 0 200 180 C738
                MB      off(00222h).0, C       ; 0D8C 0 200 180 C42238
                CLRB    A                      ; 0D8F 0 200 180 FA
                JBR     off(0021dh).5, knockretard_clear_state_store_ram241 ; 0D90 0 200 180 DD1D10
                JGE     knockretard_clear_state_store_ram241             ; 0D93 0 200 180 CD0E
                MOV     X1, #knockretard_clear_state_tbl_3          ; 0D95 0 200 180 606C6D
                JBR     off(0021eh).3, knockretard_clear_state_load_ram238_2 ; 0D98 0 200 180 DB1E03
                MOV     X1, #knockretard_clear_state_tbl_4          ; 0D9B 0 200 180 60786D
knockretard_clear_state_load_ram238_2:     LB      A, off(00238h)         ; 0D9E 0 200 180 F438
                CAL     table_interp_lookup             ; 0DA0 0 200 180 323958
knockretard_clear_state_store_ram241:     STB     A, off(00241h)         ; 0DA3 0 200 180 D441
                LB      A, #05ah               ; 0DA5 0 200 180 775A
                JBS     off(00222h).1, knockretard_clear_state_cmp_acc_3 ; 0DA7 0 200 180 E92202
                LB      A, #060h               ; 0DAA 0 200 180 7760
knockretard_clear_state_cmp_acc_3:     CMPB    A, off(00238h)         ; 0DAC 0 200 180 C738
                MB      off(00222h).1, C       ; 0DAE 0 200 180 C42239
                LB      A, 0d1h                ; 0DB1 0 200 180 F5D1
                MOVB    r0, #09ah              ; 0DB3 0 200 180 989A
                MOVB    r1, #024h              ; 0DB5 0 200 180 9924
                JBS     off(00222h).2, knockretard_clear_state_cmp_acc_4 ; 0DB7 0 200 180 EA2204
                MOVB    r0, #097h              ; 0DBA 0 200 180 9897
                MOVB    r1, #026h              ; 0DBC 0 200 180 9926
knockretard_clear_state_cmp_acc_4:     CMPB    A, r0                  ; 0DBE 0 200 180 48
                JGE     knockretard_clear_state_store_carry_ram222_bit2             ; 0DBF 0 200 180 CD02
                CMPB    r1, A                  ; 0DC1 0 200 180 21C1
knockretard_clear_state_store_carry_ram222_bit2:     MB      off(00222h).2, C       ; 0DC3 0 200 180 C4223A
                CLRB    A                      ; 0DC6 0 200 180 FA
                JBR     off(00216h).3, knockretard_clear_state_store_ram23e ; 0DC7 0 200 180 DB1623
                JBS     off(00211h).5, knockretard_clear_state_store_ram23e ; 0DCA 0 200 180 ED1120
                J       knockretard_clear_state_if_ram235_bit3_set             ; 0DCD 0 200 180 035379
knockretard_clear_state_if_ram21d_bit4_set:     JBS     off(0021dh).4, knockretard_clear_state_store_ram23e ; 0DD0 0 200 180 EC1D1A
                JBR     off(00211h).4, knockretard_clear_state_store_ram23e ; 0DD3 0 200 180 DC1117
                CMPB    0d9h, #02eh            ; 0DD6 0 200 180 C5D9C02E
                JGE     knockretard_clear_state_store_ram23e             ; 0DDA 0 200 180 CD11
                JBS     off(0021ah).2, knockretard_clear_state_store_ram23e ; 0DDC 0 200 180 EA1A0E
                JBR     off(00222h).1, knockretard_clear_state_store_ram23e ; 0DDF 0 200 180 D9220B
                JBR     off(00222h).2, knockretard_clear_state_store_ram23e ; 0DE2 0 200 180 DA2208
                LB      A, 0d1h                ; 0DE5 0 200 180 F5D1
                MOV     X1, #knockretard_clear_state_tbl_5          ; 0DE7 0 200 180 60C36D
                CAL     table_interp_lookup             ; 0DEA 0 200 180 323958
knockretard_clear_state_store_ram23e:     STB     A, off(0023eh)         ; 0DED 0 200 180 D43E
                LB      A, #029h               ; 0DEF 0 200 180 7729
                JBS     off(00222h).3, callhelper_table_interp_lookup ; 0DF1 0 200 180 EB2202
                LB      A, #022h               ; 0DF4 0 200 180 7722
callhelper_table_interp_lookup:     CMPB    0beh, A                ; 0DF6 0 200 180 C5BEC1
                MB      off(00222h).3, C       ; 0DF9 0 200 180 C4223B
                CLRB    A                      ; 0DFC 0 200 180 FA
                JLT     callhelper_table_interp_lookup_store_ram23f             ; 0DFD 0 200 180 CA11
                CMPB    0d9h, #034h            ; 0DFF 0 200 180 C5D9C034
                JGE     callhelper_table_interp_lookup_store_ram23f             ; 0E03 0 200 180 CD0B
                JBS     off(0021dh).5, callhelper_table_interp_lookup_store_ram23f ; 0E05 0 200 180 ED1D08
                LB      A, off(00238h)         ; 0E08 0 200 180 F438
                MOV     X1, #callhelper_table_interp_lookup_tbl          ; 0E0A 0 200 180 60B16D
                CAL     table_interp_lookup             ; 0E0D 0 200 180 323958
callhelper_table_interp_lookup_store_ram23f:     STB     A, off(0023fh)         ; 0E10 0 200 180 D43F
                MOV     X1, #TipinTPS          ; 0E12 0 200 180 60846D
                LB      A, off(00238h)         ; 0E15 0 200 180 F438
                CAL     table_interp_lookup             ; 0E17 0 200 180 323958
                CMPB    A, 0d3h                ; 0E1A 0 200 180 C5D3C2
                MB      off(00231h).6, C       ; 0E1D 0 200 180 C4313E
                L       A, off(00212h)         ; 0E20 1 200 180 E412
                AND     A, #08074h             ; 0E22 1 200 180 D67480
                JNE     tipin_gate_fail             ; 0E25 1 200 180 CE2D
                JBS     off(00214h).0, tipin_gate_fail ; 0E27 1 200 180 E8142A
                JBS     off(0021dh).4, tipin_gate_fail ; 0E2A 1 200 180 EC1D27
                JBS     off(00216h).3, tipin_gate_fail ; 0E2D 1 200 180 EB1624
                CMPB    0d9h, #03ch            ; 0E30 1 200 180 C5D9C03C
                JGE     tipin_gate_fail             ; 0E34 1 200 180 CD1E
                LB      A, 0cch                ; 0E36 0 200 180 F5CC
                CMPB    A, #005h               ; 0E38 0 200 180 C605
                JLT     tipin_gate_fail             ; 0E3A 0 200 180 CA18
                CMPB    A, #078h               ; 0E3C 0 200 180 C678
                JGE     tipin_gate_fail             ; 0E3E 0 200 180 CD14
                LB      A, off(00238h)         ; 0E40 0 200 180 F438
                CMPB    A, #033h               ; 0E42 0 200 180 C633
                JLT     tipin_gate_fail             ; 0E44 0 200 180 CA0E
                CMPB    A, #0c0h               ; 0E46 0 200 180 C6C0
                JGE     tipin_gate_fail             ; 0E48 0 200 180 CD0A
                JBS     off(00220h).0, tipin_gate_pass ; 0E4A 0 200 180 E82018
                JBR     off(00231h).6, tipin_gate2 ; 0E4D 0 200 180 DE310C
                LB      A, off(00239h)         ; 0E50 0 200 180 F439
                JNE     tipin_decay_check             ; 0E52 0 200 180 CE43
tipin_gate_fail:     RB      off(00220h).0          ; 0E54 0 200 180 C42008
                RB      off(00220h).2          ; 0E57 0 200 180 C4200A
                SJ      tipin_decay_zero             ; 0E5A 0 200 180 CB75
tipin_gate2:     JBR     off(0021bh).1, tipin_decay_zero ; 0E5C 0 200 180 D91B72
                CMPB    0d5h, #010h            ; 0E5F 0 200 180 C5D5C010
                JLT     tipin_decay_zero             ; 0E63 0 200 180 CA6C
tipin_gate_pass:     SB      off(00220h).0          ; 0E65 0 200 180 C42018
                JBS     off(0021bh).6, tipin_enrich_lookup ; 0E68 0 200 180 EE1B07
                CMP     0c6h, #0ffffh          ; 0E6B 0 200 180 B5C6C0FFFF
                JGE     tipin_decay_zero             ; 0E70 0 200 180 CD5F
tipin_enrich_lookup:     LB      A, off(00251h)         ; 0E72 0 200 180 F451
                EXTND                          ; 0E74 1 200 180 F8
                LCB     A, tipin_enrich_lookup_tbl[ACC]       ; 0E75 1 200 180 B506AB9F6D
                MOVB    off(00250h), A         ; 0E7A 1 200 180 C4508A
                MOV     X1, #TipinRPM          ; 0E7D 1 200 180 60926D
                LB      A, off(00238h)         ; 0E80 0 200 180 F438
                CAL     table_interp_lookup             ; 0E82 0 200 180 323958
                MOVB    r0, off(00252h)        ; 0E85 0 200 180 C45248
                MULB                           ; 0E88 0 200 180 A234
                L       A, ACC                 ; 0E8A 1 200 180 E506
                SLL     A                      ; 0E8C 1 200 180 53
                JGE     tipin_enrich_clamp             ; 0E8D 1 200 180 CD03
                L       A, #0ffffh             ; 0E8F 1 200 180 67FFFF
tipin_enrich_clamp:     LB      A, ACCH                ; 0E92 0 200 180 F507
                RB      off(00220h).0          ; 0E94 0 200 180 C42008
tipin_decay_check:     CMPB    off(00250h), #000h     ; 0E97 0 200 180 C450C000
                JEQ     tipin_decay_gate1             ; 0E9B 0 200 180 C907
                DECB    off(00250h)            ; 0E9D 0 200 180 C45017
                MOVB    r0, #001h              ; 0EA0 0 200 180 9801
                SJ      tipin_decay_sub             ; 0EA2 0 200 180 CB27
tipin_decay_gate1:     JBS     off(0021bh).6, tipin_decay_gate2 ; 0EA4 0 200 180 EE1B0D
                CMP     0c6h, #00010h          ; 0EA7 0 200 180 B5C6C01000
                JLT     tipin_decay_gate3             ; 0EAC 0 200 180 CA0D
                RB      off(00220h).2          ; 0EAE 0 200 180 C4200A
tipin_decay_common:     RC                             ; 0EB1 0 200 180 95
                SJ      tipin_decay_flag3             ; 0EB2 0 200 180 CB10
tipin_decay_gate2:     CMP     0c6h, #00003h          ; 0EB4 0 200 180 B5C6C00300
                JGE     tipin_decay_gate4             ; 0EB9 0 200 180 CD05
tipin_decay_gate3:     JBS     off(00220h).2, tipin_decay_common ; 0EBB 0 200 180 EA20F3
                SJ      tipin_decay_sc             ; 0EBE 0 200 180 CB03
tipin_decay_gate4:     SB      off(00220h).2          ; 0EC0 0 200 180 C4201A
tipin_decay_sc:     SC                             ; 0EC3 0 200 180 85
tipin_decay_flag3:     MB      off(00220h).3, C       ; 0EC4 0 200 180 C4203B
                JGE     tipin_decay_rc             ; 0EC7 0 200 180 CD09
                MOVB    r0, #004h              ; 0EC9 0 200 180 9804
tipin_decay_sub:     SUBB    A, r0                  ; 0ECB 0 200 180 28
                JLT     tipin_decay_zero             ; 0ECC 0 200 180 CA03
                SC                             ; 0ECE 0 200 180 85
                SJ      tipin_decay_store             ; 0ECF 0 200 180 CB02
tipin_decay_zero:     CLRB    A                      ; 0ED1 0 200 180 FA
tipin_decay_rc:     RC                             ; 0ED2 0 200 180 95
tipin_decay_store:     STB     A, off(00239h)         ; 0ED3 0 200 180 D439
                MB      off(00220h).1, C       ; 0ED5 0 200 180 C42039
                LB      A, #0feh               ; 0ED8 0 200 180 77FE
                JBS     off(00222h).4, knock244_threshold_check ; 0EDA 0 200 180 EC2202
                LB      A, #0ffh               ; 0EDD 0 200 180 77FF
knock244_threshold_check:     CMPB    A, off(00246h)         ; 0EDF 0 200 180 C746
                MB      off(00222h).4, C       ; 0EE1 0 200 180 C4223C
                MOVB    r0, #040h              ; 0EE4 0 200 180 9840
                MOVB    r1, #003h              ; 0EE6 0 200 180 9903
                MOVB    r2, #024h              ; 0EE8 0 200 180 9A24
                MOVB    r3, #010h              ; 0EEA 0 200 180 9B10
                JGE     dwellbase_gate1             ; 0EEC 0 200 180 CD08
                MOVB    r0, #040h              ; 0EEE 0 200 180 9840
                MOVB    r1, #003h              ; 0EF0 0 200 180 9903
                MOVB    r2, #024h              ; 0EF2 0 200 180 9A24
                MOVB    r3, #010h              ; 0EF4 0 200 180 9B10
dwellbase_gate1:     JBS     off(00212h).6, gate_255_common ; 0EF6 0 200 180 EE1220
                JBS     off(0021dh).4, gate_255_common ; 0EF9 0 200 180 EC1D1D
                CMPB    0d9h, #028h            ; 0EFC 0 200 180 C5D9C028
                JGE     gate_255_common             ; 0F00 0 200 180 CD17
                LB      A, r0                  ; 0F02 0 200 180 78
                CMPB    A, off(00238h)         ; 0F03 0 200 180 C738
                JLT     gate_255_common             ; 0F05 0 200 180 CA12
                JBS     off(00231h).6, gate_255_common ; 0F07 0 200 180 EE310F
                CLRB    A                      ; 0F0A 0 200 180 FA
                JBR     off(0021bh).1, store_255_result ; 0F0B 0 200 180 D91B09
                CMPB    0d5h, #018h            ; 0F0E 0 200 180 C5D5C018
                JLT     store_255_result             ; 0F12 0 200 180 CA03
                LB      A, r1                  ; 0F14 0 200 180 79
                ADDB    A, #001h               ; 0F15 0 200 180 8601
store_255_result:     STB     A, off(00257h)         ; 0F17 0 200 180 D457
gate_255_common:     LB      A, r2                  ; 0F19 0 200 180 7A
                CMPB    off(00257h), #000h     ; 0F1A 0 200 180 C457C000
                JEQ     track239e_check             ; 0F1E 0 200 180 C905
                DECB    off(00257h)            ; 0F20 0 200 180 C45717
                SJ      dwell_base_lookup             ; 0F23 0 200 180 CB06
track239e_check:     LB      A, off(00240h)         ; 0F25 0 200 180 F440
                SUBB    A, r3                  ; 0F27 0 200 180 2B
                JGE     dwell_base_lookup             ; 0F28 0 200 180 CD01
                CLRB    A                      ; 0F2A 0 200 180 FA
dwell_base_lookup:     STB     A, off(00240h)         ; 0F2B 0 200 180 D440
                J       dwell_base_lookup_rom_load_tbl_7cb8             ; 0F2D 0 200 180 03147C
                DW  0ffffh           ; 0F30
dwell_base_lookup_call_table_interp_lookup:     CAL     table_interp_lookup             ; 0F32 0 200 180 323958
                STB     A, off(00249h)         ; 0F35 0 200 180 D449
                LB      A, 0c2h                ; 0F37 0 200 180 F5C2
                MOV     X1, #DwellBaseValues          ; 0F39 0 200 180 607A6C
                CAL     table_interp_lookup             ; 0F3C 0 200 180 323958
                MOV     DP, #0035ah            ; 0F3F 0 200 180 625A03
                STB     A, [DP]                ; 0F42 0 200 180 D2
                STB     A, r0                  ; 0F43 0 200 180 88
                LB      A, off(0024dh)         ; 0F44 0 200 180 F44D
                MULB                           ; 0F46 0 200 180 A234
                L       A, ACC                 ; 0F48 1 200 180 E506
                ST      A, er1                 ; 0F4A 1 200 180 89
                CAL     dwell_scale_helper             ; 0F4B 1 200 180 32FA5C
                ST      A, off(0024eh)         ; 0F4E 1 200 180 D44E
                LB      A, #0ffh               ; 0F50 0 200 180 77FF
                JBS     off(00221h).5, dwell_base_lookup_cmp_acc ; 0F52 0 200 180 ED2102
                LB      A, #0ffh               ; 0F55 0 200 180 77FF
dwell_base_lookup_cmp_acc:     CMPB    A, off(00238h)         ; 0F57 0 200 180 C738
                MB      off(00221h).5, C       ; 0F59 0 200 180 C4213D
                L       A, er1                 ; 0F5C 1 200 180 35
                JLT     dwell_scale_shift             ; 0F5D 1 200 180 CA01
                SRL     A                      ; 0F5F 1 200 180 63
dwell_scale_shift:     SRL     A                      ; 0F60 1 200 180 63
                CAL     dwell_scale_helper             ; 0F61 1 200 180 32FA5C
                ST      A, off(0024fh)         ; 0F64 1 200 180 D44F
                MOV     DP, #dwell_scale_shift_tbl          ; 0F66 1 200 180 621C6D
                MOV     er0, (001c4h-00180h)[USP] ; 0F69 1 200 180 B34448
                LB      A, (001c7h-00180h)[USP] ; 0F6C 0 200 180 F347
                JBS     off(0021fh).1, dwell_scale_shift_if_ram21d_bit4_clr ; 0F6E 0 200 180 E91F08
                MOV     DP, #dwell_scale_shift_tbl_2          ; 0F71 0 200 180 62446D
                MOV     er0, (001c2h-00180h)[USP] ; 0F74 0 200 180 B34248
                LB      A, (001c6h-00180h)[USP] ; 0F77 0 200 180 F346
dwell_scale_shift_if_ram21d_bit4_clr:     JBR     off(0021dh).4, dwell_scale_shift_call_knock_244_helper ; 0F79 0 200 180 DC1D04
                ADD     DP, #00014h            ; 0F7C 0 200 180 92801400
dwell_scale_shift_call_knock_244_helper:     CAL     knock_244_helper             ; 0F80 0 200 180 32465A
                STB     A, off(0024ch)         ; 0F83 0 200 180 D44C
                CLR     A                      ; 0F85 1 200 180 F9
                ST      A, er3                 ; 0F86 1 200 180 8B
                JBS     off(00212h).5, ign_sum_stage4 ; 0F87 1 200 180 ED125F
                JBR     off(00220h).1, ignsum_er3_start ; 0F8A 1 200 180 D92016
                LB      A, 0d1h                ; 0F8D 0 200 180 F5D1
                MOV     X1, #TipinRetard          ; 0F8F 0 200 180 60A56D
                CAL     table_interp_lookup             ; 0F92 0 200 180 323958
                MOVB    r0, off(00239h)        ; 0F95 0 200 180 C43948
                MULB                           ; 0F98 0 200 180 A234
                L       A, ACC                 ; 0F9A 1 200 180 E506
                SLL     A                      ; 0F9C 1 200 180 53
                MOVB    r6, ACCH               ; 0F9D 1 200 180 C5074E
                CLRB    r7                     ; 0FA0 1 200 180 2715
                CLR     A                      ; 0FA2 1 200 180 F9
ignsum_er3_start:     LB      A, off(0023ah)         ; 0FA3 0 200 180 F43A
                ADD     er3, A                 ; 0FA5 0 200 180 4781
                LB      A, off(0023bh)         ; 0FA7 0 200 180 F43B
                ADD     er3, A                 ; 0FA9 0 200 180 4781
                LB      A, off(0023ch)         ; 0FAB 0 200 180 F43C
                ADD     er3, A                 ; 0FAD 0 200 180 4781
                LB      A, off(0023dh)         ; 0FAF 0 200 180 F43D
                ADD     er3, A                 ; 0FB1 0 200 180 4781
                LB      A, off(0023eh)         ; 0FB3 0 200 180 F43E
                ADD     er3, A                 ; 0FB5 0 200 180 4781
                LB      A, off(0023fh)         ; 0FB7 0 200 180 F43F
                ADD     er3, A                 ; 0FB9 0 200 180 4781
                LB      A, off(00240h)         ; 0FBB 0 200 180 F440
                ADD     er3, A                 ; 0FBD 0 200 180 4781
                JBR     off(00234h).4, ignsum_er3_start_cmp_ram0d9 ; 0FBF 0 200 180 DC3404
                LB      A, #040h               ; 0FC2 0 200 180 7740
                ADD     er3, A                 ; 0FC4 0 200 180 4781
ignsum_er3_start_cmp_ram0d9:     CMPB    0d9h, #034h            ; 0FC6 0 200 180 C5D9C034
                JGE     ignsum_er3_start_goto_7c94             ; 0FCA 0 200 180 CD07
                JBR     off(00218h).0, ignsum_er3_start_goto_7c94 ; 0FCC 0 200 180 D81804
                LB      A, #00ch               ; 0FCF 0 200 180 770C
                ADD     er3, A                 ; 0FD1 0 200 180 4781
ignsum_er3_start_goto_7c94:     J       ignsum_er3_start_load_ram2ff             ; 0FD3 0 200 180 03947C
ignsum_er3_start_load_acc:     L       A, ACC                 ; 0FD6 1 200 180 E506
                SUB     A, er3                 ; 0FD8 1 200 180 2B
                ST      A, er3                 ; 0FD9 1 200 180 8B
                LB      A, off(00242h)         ; 0FDA 0 200 180 F442
                EXTND                          ; 0FDC 1 200 180 F8
                ADD     er3, A                 ; 0FDD 1 200 180 4781
                LB      A, off(00243h)         ; 0FDF 0 200 180 F443
                EXTND                          ; 0FE1 1 200 180 F8
                ADD     er3, A                 ; 0FE2 1 200 180 4781
                LB      A, off(00244h)         ; 0FE4 0 200 180 F444
                EXTND                          ; 0FE6 1 200 180 F8
                ADD     er3, A                 ; 0FE7 1 200 180 4781
ign_sum_stage4:     LB      A, off(00245h)         ; 0FE9 0 200 180 F445
                EXTND                          ; 0FEB 1 200 180 F8
                ADD     er3, A                 ; 0FEC 1 200 180 4781
                CLR     A                      ; 0FEE 1 200 180 F9
                LB      A, off(00246h)         ; 0FEF 0 200 180 F446
                SUB     er3, A                 ; 0FF1 0 200 180 47A1
                CLR     A                      ; 0FF3 1 200 180 F9
                LB      A, off(00248h)         ; 0FF4 0 200 180 F448
                STB     A, r0                  ; 0FF6 0 200 180 88
                L       A, ACC                 ; 0FF7 1 200 180 E506
                ADD     A, er3                 ; 0FF9 1 200 180 0B
                JBR     off(00207h).7, ign_sum_clamp_check ; 0FFA 1 200 180 DF0705
                JLT     ign_sum_result             ; 0FFD 1 200 180 CA0A
                CLRB    A                      ; 0FFF 0 200 180 FA
                SJ      ign_sum_result             ; 1000 0 200 180 CB07
ign_sum_clamp_check:     CMP     A, #000ffh             ; 1002 1 200 180 C6FF00
                JLT     ign_sum_result             ; 1005 1 200 180 CA02
                LB      A, #0ffh               ; 1007 0 200 180 77FF
ign_sum_result:     LB      A, ACC                 ; 1009 0 200 180 F506
                STB     A, r4                  ; 100B 0 200 180 8C
                LB      A, #040h               ; 100C 0 200 180 7740
                JBS     off(00234h).5, ign_sum_common ; 100E 0 200 180 ED3402
                LB      A, #04dh               ; 1011 0 200 180 774D
ign_sum_common:     CMPB    A, off(00238h)         ; 1013 0 200 180 C738
                MB      off(00234h).5, C       ; 1015 0 200 180 C4343D
                LB      A, #040h               ; 1018 0 200 180 7740
                SC                             ; 101A 0 200 180 85
                JBS     off(00212h).5, ign_p40_flag_store ; 101B 0 200 180 ED1229
                CMPB    0d9h, #0d0h            ; 101E 0 200 180 C5D9C0D0
                JLT     ign_p40_flag_store             ; 1022 0 200 180 CA23
                MB      C, P4.0                ; 1024 0 200 180 C52C28
                JLT     ign_p40_store             ; 1027 0 200 180 CA19
                JBS     off(00221h).7, ign_result_clamp249 ; 1029 0 200 180 EF211E
                LB      A, #000h               ; 102C 0 200 180 7700
                MB      C, off(0021eh).0       ; 102E 0 200 180 C41E28
                JLT     ign_p40_store             ; 1031 0 200 180 CA0F
                JBS     off(00234h).5, ign_p40_toggle ; 1033 0 200 180 ED340E
                LB      A, off(0024bh)         ; 1036 0 200 180 F44B
                ADDB    A, #002h               ; 1038 0 200 180 8602
                JGE     ign_p40_clamp             ; 103A 0 200 180 CD02
                LB      A, #0ffh               ; 103C 0 200 180 77FF
ign_p40_clamp:     CMPB    A, r4                  ; 103E 0 200 180 4C
                JGE     ign_p40_toggle             ; 103F 0 200 180 CD03
                STB     A, r4                  ; 1041 0 200 180 8C
ign_p40_store:     STB     A, off(0024bh)         ; 1042 0 200 180 D44B
ign_p40_toggle:     XORB    PSWH, #080h            ; 1044 0 200 180 A2F080
ign_p40_flag_store:     MB      off(00221h).7, C       ; 1047 0 200 180 C4213F
ign_result_clamp249:     MOVB    r3, off(0024ch)        ; 104A 0 200 180 C44C4B
                LB      A, r4                  ; 104D 0 200 180 7C
                CMPB    A, r3                  ; 104E 0 200 180 4B
                JGE     ign_result_clamp_common             ; 104F 0 200 180 CD01
                LB      A, r3                  ; 1051 0 200 180 7B
ign_result_clamp_common:     RC                             ; 1052 0 200 180 95
                JBS     off(00217h).0, ign_flag_217_1 ; 1053 0 200 180 E81705
                LB      A, ACC                 ; 1056 0 200 180 F506
                JNE     ign_flag_217_1             ; 1058 0 200 180 CE01
                SC                             ; 105A 0 200 180 85
ign_flag_217_1:     MB      off(00217h).1, C       ; 105B 0 200 180 C41739
                MOV     DP, #0035bh            ; 105E 0 200 180 625B03
                JBS     off(0021eh).0, ign_result_zero ; 1061 0 200 180 E81E03
                JBR     off(00217h).1, ign_flag_217_1_store_dp_ind ; 1064 0 200 180 D91706
ign_result_zero:     CLRB    A                      ; 1067 0 200 180 FA
                STB     A, [DP]                ; 1068 0 200 180 D2
                STB     A, off(0024ah)         ; 1069 0 200 180 D44A
                SJ      igntiming_cylinder_trim_add             ; 106B 0 200 180 CB09
ign_flag_217_1_store_dp_ind:     STB     A, [DP]                ; 106D 0 200 180 D2
                ADDB    A, off(00249h)         ; 106E 0 200 180 8749
                JGE     ignmap_disable_check             ; 1070 0 200 180 CD02
                LB      A, #0ffh               ; 1072 0 200 180 77FF
ignmap_disable_check:     STB     A, off(0024ah)         ; 1074 0 200 180 D44A
igntiming_cylinder_trim_add:     MOVB    r2, off(0024ah)        ; 1076 0 200 180 C44A4A
                MOVB    r4, off(0024eh)        ; 1079 0 200 180 C44E4C
                CAL     ign_angle_to_timer_convert             ; 107C 0 200 180 320258
                MOV     DP, #00357h            ; 107F 0 200 180 625703
                AND     IE, #002a0h            ; 1082 0 200 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 1087 0 200 180 A2D0FE
                MB      0b8h.0, C              ; 108A 0 200 180 C5B838
                STB     A, [DP]                ; 108D 0 200 180 D2
                INC     DP                     ; 108E 0 200 180 72
                L       A, er0                 ; 108F 1 200 180 34
                ST      A, [DP]                ; 1090 1 200 180 D2
                ORB     PSWH, #001h            ; 1091 1 200 180 A2E001
                L       A, 0f8h                ; 1094 1 200 180 E5F8
                ST      A, IE                  ; 1096 1 200 180 D51A
                MOVB    r4, off(0024fh)        ; 1098 1 200 180 C44F4C
                CAL     ign_angle_to_timer_convert             ; 109B 1 200 180 320258
                MOV     DP, #0035dh            ; 109E 1 200 180 625D03
                AND     IE, #002a0h            ; 10A1 1 200 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 10A6 1 200 180 A2D0FE
                MB      0b8h.1, C              ; 10A9 1 200 180 C5B839
                ST      A, [DP]                ; 10AC 1 200 180 D2
                INC     DP                     ; 10AD 1 200 180 72
                L       A, er0                 ; 10AE 1 200 180 34
                ST      A, [DP]                ; 10AF 1 200 180 D2
                ORB     PSWH, #001h            ; 10B0 1 200 180 A2E001
                L       A, 0f8h                ; 10B3 1 200 180 E5F8
                ST      A, IE                  ; 10B5 1 200 180 D51A
                MOV     LRB, #00020h           ; 10B7 1 100 180 572000
                MOV     USP, #00280h           ; 10BA 1 100 280 A1988002
                CAL     refresh_engine_flags_snapshot             ; 10BE 1 100 280 322B5C
                SC                             ; 10C1 1 100 280 85
                JBR     off(0011eh).6, igntiming_enable_pin_drive ; 10C2 1 100 280 DE1E09
                JBR     off(00121h).2, igntiming_enable_pin_drive ; 10C5 1 100 280 DA2106
                MB      C, 0b8h.2              ; 10C8 1 100 280 C5B82A
                XORB    PSWH, #080h            ; 10CB 1 100 280 A2F080
igntiming_enable_pin_drive:     MB      P1.2, C                ; 10CE 1 100 280 C5223A
                L       A, 0fah                ; 10D1 1 100 280 E5FA
                ST      A, IE                  ; 10D3 1 100 280 D51A
                ANDB    PSWH, #0feh            ; 10D5 1 100 280 A2D0FE
                LB      A, P1                  ; 10D8 0 100 280 F522
                MOV     DP, #02f00h            ; 10DA 0 100 280 62002F
                STB     A, [DP]                ; 10DD 0 100 280 D2
                ORB     PSWH, #001h            ; 10DE 0 100 280 A2E001
                L       A, 0f8h                ; 10E1 1 100 280 E5F8
                ST      A, IE                  ; 10E3 1 100 280 D51A
                L       A, #01d4ch             ; 10E5 1 100 280 674C1D
                JBS     off(00129h).1, vtec_rawperiod_threshold_check ; 10E8 1 100 280 E92903
                L       A, #00ea6h             ; 10EB 1 100 280 67A60E
vtec_rawperiod_threshold_check:     CMP     0c4h, A                ; 10EE 1 100 280 B5C4C1
                MB      off(00129h).1, C       ; 10F1 1 100 280 C42939
                JBR     off(0011eh).5, vtec_state_reset_low_rpm ; 10F4 1 100 280 DD1E39
                LB      A, ADCR5H              ; 10F7 0 100 280 F56B
                STB     A, 0d7h                ; 10F9 0 100 280 D5D7
                LB      A, #0ffh               ; 10FB 0 100 280 77FF
                JBS     off(00126h).2, vtec_rawperiod_threshold_check_cmp_acc ; 10FD 0 100 280 EA2602
                LB      A, #0ffh               ; 1100 0 100 280 77FF
vtec_rawperiod_threshold_check_cmp_acc:     CMPB    A, off(00132h)         ; 1102 0 100 280 C732
                MB      off(00126h).2, C       ; 1104 0 100 280 C4263A
                LB      A, #0ffh               ; 1107 0 100 280 77FF
                JBS     off(00131h).6, vtec_rawperiod_threshold_check_cmp_acc_2 ; 1109 0 100 280 EE3102
                LB      A, #0ffh               ; 110C 0 100 280 77FF
vtec_rawperiod_threshold_check_cmp_acc_2:     CMPB    A, off(00133h)         ; 110E 0 100 280 C733
                MB      off(00131h).6, C       ; 1110 0 100 280 C4313E
                LB      A, #0ffh               ; 1113 0 100 280 77FF
                JBS     off(00131h).7, vtec_rawperiod_threshold_check_cmp_acc_3 ; 1115 0 100 280 EF3102
                LB      A, #0ffh               ; 1118 0 100 280 77FF
vtec_rawperiod_threshold_check_cmp_acc_3:     CMPB    A, off(00132h)         ; 111A 0 100 280 C732
                MB      off(00131h).7, C       ; 111C 0 100 280 C4313F
                LB      A, #0ffh               ; 111F 0 100 280 77FF
                JBS     off(0011fh).5, vtec_state_reset_low_rpm ; 1121 0 100 280 ED1F0C
                JBR     off(00122h).6, vtec_state_reset_low_rpm ; 1124 0 100 280 DE2209
                JBS     off(00122h).7, vtec_state_reset_low_rpm ; 1127 0 100 280 EF2206
                JBR     off(00126h).2, vtec_state_reset_low_rpm ; 112A 0 100 280 DA2603
                JBS     off(00120h).2, vtec_oilpressure_gate_check ; 112D 0 100 280 EA2007
vtec_state_reset_low_rpm:     MOVB    off(001e2h), #0ffh     ; 1130 0 100 280 C4E298FF
                J       vtec_state_clear             ; 1134 0 100 280 031C12
vtec_oilpressure_gate_check:     JBR     off(0011dh).1, vtec_debounce_counter_check ; 1137 0 100 280 D91D03
                J       vtec_oilpressure_pin_check             ; 113A 0 100 280 03BD11
vtec_debounce_counter_check:     CMPB    0d7h, #0ffh            ; 113D 0 100 280 C5D7C0FF
                JGT     vtec_oilpressure_pin_check             ; 1141 0 100 280 C87A
                CMPB    0d7h, #000h            ; 1143 0 100 280 C5D7C000
                JLT     vtec_oilpressure_pin_check             ; 1147 0 100 280 CA74
                STB     A, off(001e2h)         ; 1149 0 100 280 D4E2
                MOVB    r1, off(0019ch)        ; 114B 0 100 280 C49C49
                LB      A, off(0019ah)         ; 114E 0 100 280 F49A
                JNE     vtec_debounce_step_calc             ; 1150 0 100 280 CE56
                CLRB    r0                     ; 1152 0 100 280 2015
                JBR     off(00131h).6, vtec_debounce_counter_check_if_ram131_bit7_clr ; 1154 0 100 280 DE3102
                INCB    r0                     ; 1157 0 100 280 A8
                INCB    r0                     ; 1158 0 100 280 A8
vtec_debounce_counter_check_if_ram131_bit7_clr:     JBR     off(00131h).7, to_vtec_debounce_store ; 1159 0 100 280 DF3101
                INCB    r0                     ; 115C 0 100 280 A8
to_vtec_debounce_store:     CLRB    r1                     ; 115D 0 100 280 2115
                CMPB    0d7h, #0ffh            ; 115F 0 100 280 C5D7C0FF
                JLE     to_vtec_debounce_store_load_imm             ; 1163 0 100 280 CF3F
                LB      A, r0                  ; 1165 0 100 280 78
                EXTND                          ; 1166 1 100 280 F8
                ADD     A, #to_vtec_debounce_store_tbl           ; 1167 1 100 280 86EA66
                MOV     DP, A                  ; 116A 1 100 280 52
                INCB    r1                     ; 116B 1 100 280 A9
                LB      A, 0d7h                ; 116C 0 100 280 F5D7
                RB      0b8h.6                 ; 116E 0 100 280 C5B80E
                CMPCB   A, [DP]                ; 1171 0 100 280 92AE
                JLE     to_vtec_debounce_store_load_imm             ; 1173 0 100 280 CF2F
                SB      0b8h.6                 ; 1175 0 100 280 C5B81E
                ADD     DP, #00004h            ; 1178 0 100 280 92800400
                CMPCB   A, [DP]                ; 117C 0 100 280 92AE
                JLE     to_vtec_debounce_store_load_imm             ; 117E 0 100 280 CF24
                ADD     DP, #00004h            ; 1180 0 100 280 92800400
                INCB    r1                     ; 1184 0 100 280 A9
                JBS     off(0011ah).3, to_vtec_debounce_store_load_imm ; 1185 0 100 280 EB1A1C
                JBS     off(0011ah).7, to_vtec_debounce_store_load_imm ; 1188 0 100 280 EF1A19
to_vtec_debounce_store_cmp_acc:     CMPCB   A, [DP]                ; 118B 0 100 280 92AE
                JLE     to_vtec_debounce_store_load_imm             ; 118D 0 100 280 CF15
to_vtec_debounce_store_add_dp:     ADD     DP, #00004h            ; 118F 0 100 280 92800400
                INCB    r1                     ; 1193 0 100 280 A9
                CMPB    r1, #004h              ; 1194 0 100 280 21C004
                JNE     to_vtec_debounce_store_cmp_r1             ; 1197 0 100 280 CE06
                CMPB    0d9h, #0ffh            ; 1199 0 100 280 C5D9C0FF
                JGE     to_vtec_debounce_store_add_dp             ; 119D 0 100 280 CDF0
to_vtec_debounce_store_cmp_r1:     CMPB    r1, #007h              ; 119F 0 100 280 21C007
                JLT     to_vtec_debounce_store_cmp_acc             ; 11A2 0 100 280 CAE7
to_vtec_debounce_store_load_imm:     LB      A, #0ffh               ; 11A4 0 100 280 77FF
                SJ      vtec_debounce_store             ; 11A6 0 100 280 CB11
vtec_debounce_step_calc:     SUBB    A, #001h               ; 11A8 0 100 280 A601
                JBR     off(00124h).0, vtec_debounce_store ; 11AA 0 100 280 D8240C
                SUBB    A, #001h               ; 11AD 0 100 280 A601
                JLT     vtec_debounce_zero             ; 11AF 0 100 280 CA07
                JBR     off(00124h).1, vtec_debounce_store ; 11B1 0 100 280 D92405
                SUBB    A, #002h               ; 11B4 0 100 280 A602
                JGE     vtec_debounce_store             ; 11B6 0 100 280 CD01
vtec_debounce_zero:     CLRB    A                      ; 11B8 0 100 280 FA
vtec_debounce_store:     STB     A, off(0019ah)         ; 11B9 0 100 280 D49A
                SJ      vtec_rpm_valid_check             ; 11BB 0 100 280 CB19
vtec_oilpressure_pin_check:     MB      C, P4.6                ; 11BD 0 100 280 C52C2E
                JGE     vtec_state_dispatch             ; 11C0 0 100 280 CD0A
                STB     A, off(001e2h)         ; 11C2 0 100 280 D4E2
vtec_state_reset_no_pressure:     MOVB    off(001e3h), #0ffh     ; 11C4 0 100 280 C4E398FF
                MOVB    r1, #004h              ; 11C8 0 100 280 9904
                SJ      vtec_rpm_valid_check             ; 11CA 0 100 280 CB0A
vtec_state_dispatch:     LB      A, off(001e2h)         ; 11CC 0 100 280 F4E2
                JNE     vtec_state_reset_no_pressure             ; 11CE 0 100 280 CEF4
                LB      A, off(001e3h)         ; 11D0 0 100 280 F4E3
                JEQ     vtec_state_clear             ; 11D2 0 100 280 C948
                MOVB    r1, #002h              ; 11D4 0 100 280 9902
vtec_rpm_valid_check:     CMPB    off(00133h), #0ffh     ; 11D6 0 100 280 C433C0FF
                JLT     vtec_state_hold_check             ; 11DA 0 100 280 CA0B
                LB      A, r1                  ; 11DC 0 100 280 79
                CMPB    A, #001h               ; 11DD 0 100 280 C601
                JLE     vtec_state_active_check             ; 11DF 0 100 280 CF0B
                MOVB    off(001dah), #0ffh     ; 11E1 0 100 280 C4DA98FF
                SJ      vtec_state_store             ; 11E5 0 100 280 CB11
vtec_state_hold_check:     JBS     off(00125h).4, vtec_state_confirm ; 11E7 0 100 280 EC2505
                SJ      vtec_state_clear             ; 11EA 0 100 280 CB30
vtec_state_active_check:     JBR     off(00125h).4, vtec_state_finalize ; 11EC 0 100 280 DC252F
vtec_state_confirm:     LB      A, off(001dah)         ; 11EF 0 100 280 F4DA
                JEQ     vtec_state_finalize             ; 11F1 0 100 280 C92B
                MOVB    r1, #002h              ; 11F3 0 100 280 9902
                CLRB    off(0019ah)            ; 11F5 0 100 280 C49A15
vtec_state_store:     LB      A, r1                  ; 11F8 0 100 280 79
                STB     A, off(0019ch)         ; 11F9 0 100 280 D49C
                SB      off(00125h).4          ; 11FB 0 100 280 C4251C
                JNE     vtec_retard_timer_check             ; 11FE 0 100 280 CE07
                MOVB    off(0019eh), #00ch     ; 1200 0 100 280 C49E980C
                CLRB    off(0019dh)            ; 1204 0 100 280 C49D15
vtec_retard_timer_check:     CMPB    off(0019eh), #008h     ; 1207 0 100 280 C49EC008
                JGT     vtec_retard_lookup_done             ; 120B 0 100 280 C80D
                CLR     A                      ; 120D 1 100 280 F9
                LB      A, r1                  ; 120E 0 100 280 79
                SUBB    A, #002h               ; 120F 0 100 280 A602
                MOV     DP, #tbl_vtec_transition_retard          ; 1211 0 100 280 62B667
                ADD     DP, A                  ; 1214 0 100 280 9281
                LCB     A, [DP]                ; 1216 0 100 280 92AA
                STB     A, off(0019dh)         ; 1218 0 100 280 D49D
vtec_retard_lookup_done:     SJ      vtec_engage_gate_start             ; 121A 0 100 280 CB10
vtec_state_clear:     CLRB    r1                     ; 121C 0 100 280 2115
vtec_state_finalize:     RB      off(00125h).4          ; 121E 0 100 280 C4250C
                CLRB    A                      ; 1221 0 100 280 FA
                STB     A, off(0019ah)         ; 1222 0 100 280 D49A
                CMPB    r1, #001h              ; 1224 0 100 280 21C001
                JNE     vtec_state_store2             ; 1227 0 100 280 CE01
                LB      A, r1                  ; 1229 0 100 280 79
vtec_state_store2:     STB     A, off(0019ch)         ; 122A 0 100 280 D49C
vtec_engage_gate_start:     JBR     off(0011eh).4, vtec_disengage_output ; 122C 0 100 280 DC1E52
                LB      A, #005h               ; 122F 0 100 280 7705
                MOVB    r0, #014h              ; 1231 0 100 280 9814
                JBS     off(00131h).0, vtec_engage_gate_start_if_ram11e_bit3_set ; 1233 0 100 280 E83104
                LB      A, #00ah               ; 1236 0 100 280 770A
                MOVB    r0, #019h              ; 1238 0 100 280 9819
vtec_engage_gate_start_if_ram11e_bit3_set:     JBS     off(0011eh).3, vtec_engage_gate_start_cmp_acc ; 123A 0 100 280 EB1E01
                LB      A, r0                  ; 123D 0 100 280 78
vtec_engage_gate_start_cmp_acc:     CMPB    A, 0cch                ; 123E 0 100 280 C5CCC2
                MB      off(00131h).0, C       ; 1241 0 100 280 C43138
                MOV     DP, #vtec_engage_gate_start_tbl          ; 1244 0 100 280 624265
                MOV     X1, #vtec_engage_gate_start_tbl_3          ; 1247 0 100 280 604A65
                JBS     off(0011eh).3, vtec_engage_gate_start_rom_load_dp_ind ; 124A 0 100 280 EB1E06
                MOV     DP, #vtec_engage_gate_start_tbl_2          ; 124D 0 100 280 624665
                MOV     X1, #vtec_engage_gate_start_tbl_4          ; 1250 0 100 280 605865
vtec_engage_gate_start_rom_load_dp_ind:     LC      A, [DP]                ; 1253 0 100 280 92A8
                INC     DP                     ; 1255 0 100 280 72
                INC     DP                     ; 1256 0 100 280 72
                JBS     off(00131h).1, vtec_rpm_vs_settings_check ; 1257 0 100 280 E93102
                LB      A, ACCH                ; 125A 0 100 280 F507
vtec_rpm_vs_settings_check:     CMPB    A, off(00133h)         ; 125C 0 100 280 C733
                MB      off(00131h).1, C       ; 125E 0 100 280 C43139
                LC      A, [DP]                ; 1261 0 100 280 92A8
                JBS     off(00131h).2, vtec_rpm_vs_settings_check_cmp_acc ; 1263 0 100 280 EA3102
                LB      A, ACCH                ; 1266 0 100 280 F507
vtec_rpm_vs_settings_check_cmp_acc:     CMPB    A, off(00133h)         ; 1268 0 100 280 C733
                MB      off(00131h).2, C       ; 126A 0 100 280 C4313A
                LB      A, off(00133h)         ; 126D 0 100 280 F433
                CAL     table_interp_lookup             ; 126F 0 100 280 323958
                STB     A, off(00198h)         ; 1272 0 100 280 D498
                L       A, off(0011ah)         ; 1274 1 100 280 E41A
                AND     A, #0c0bch             ; 1276 1 100 280 D6BCC0
                JNE     vtec_disengage_output             ; 1279 1 100 280 CE06
                LB      A, off(0011ch)         ; 127B 0 100 280 F41C
                ANDB    A, #031h               ; 127D 0 100 280 D631
                JEQ     vtec_engage_conditions_start             ; 127F 0 100 280 C905
vtec_disengage_output:     RB      P1.1                   ; 1281 0 100 280 C52209
                SJ      vtec_highcam_output             ; 1284 0 100 280 CB24
vtec_engage_conditions_start:     SB      P1.1                   ; 1286 0 100 280 C52219
                CMPB    0f3h, #032h            ; 1289 0 100 280 C5F3C032
                JLT     vtec_highcam_output             ; 128D 0 100 280 CA1B
                CMPB    0d9h, #044h            ; 128F 0 100 280 C5D9C044
                JGE     vtec_highcam_output             ; 1293 0 100 280 CD15
                LCB     A, vtec_engage_conditions_start_tbl            ; 1295 0 100 280 909DFA60
                JNE     vtec_engage_conditions_start_if_ram11e_bit3_clr             ; 1299 0 100 280 CE03
                JBR     off(00131h).0, vtec_highcam_output ; 129B 0 100 280 D8310C
vtec_engage_conditions_start_if_ram11e_bit3_clr:     JBR     off(0011eh).3, vtec_engage_conditions_start_if_ram131_bit1_set ; 129E 0 100 280 DB1E03
                JBS     off(00119h).5, vtec_engage_conditions_start_if_ram127_bit1_set ; 12A1 0 100 280 ED1903
vtec_engage_conditions_start_if_ram131_bit1_set:     JBS     off(00131h).1, vtec_engage_conditions_start_load_ram198 ; 12A4 0 100 280 E9310B
vtec_engage_conditions_start_if_ram127_bit1_set:     JBS     off(00127h).1, vtec_engage_conditions_start_clear_ram1df ; 12A7 0 100 280 E92721
vtec_highcam_output:     RB      P1.0                   ; 12AA 0 100 280 C52208
                RB      off(00127h).2          ; 12AD 0 100 280 C4270A
                SJ      vtec_highcam_output_load_ram1d8             ; 12B0 0 100 280 CB29
vtec_engage_conditions_start_load_ram198:     LB      A, off(00198h)         ; 12B2 0 100 280 F498
                SUBB    A, off(00199h)         ; 12B4 0 100 280 A799
                JLT     vtec_engage_conditions_start_clear_acc             ; 12B6 0 100 280 CA07
                JBR     off(00127h).2, vtec_engage_conditions_start_cmp_acc ; 12B8 0 100 280 DA2705
                SUBB    A, #008h               ; 12BB 0 100 280 A608
                JGE     vtec_engage_conditions_start_cmp_acc             ; 12BD 0 100 280 CD01
vtec_engage_conditions_start_clear_acc:     CLRB    A                      ; 12BF 0 100 280 FA
vtec_engage_conditions_start_cmp_acc:     CMPB    A, off(00132h)         ; 12C0 0 100 280 C732
                JLT     vtec_engage_conditions_start_load_ram1df             ; 12C2 0 100 280 CA20
                JBS     off(00131h).2, vtec_engage_conditions_start_load_ram1df ; 12C4 0 100 280 EA311D
                LB      A, off(001dfh)         ; 12C7 0 100 280 F4DF
                JNE     vtec_engage_conditions_start_set_p1_bit0             ; 12C9 0 100 280 CE1D
vtec_engage_conditions_start_clear_ram1df:     CLRB    off(001dfh)            ; 12CB 0 100 280 C4DF15
                RB      P1.0                   ; 12CE 0 100 280 C52208
                RB      off(00127h).2          ; 12D1 0 100 280 C4270A
                JBS     off(00119h).1, vtec_engage_conditions_start_load_ram1d8 ; 12D4 0 100 280 E9191A
vtec_engage_conditions_start_load_ram1d9:     LB      A, off(001d9h)         ; 12D7 0 100 280 F4D9
                JNE     vtec_engage_conditions_start_set_ram127_bit1             ; 12D9 0 100 280 CE1E
vtec_highcam_output_load_ram1d8:     MOVB    off(001d8h), #00ah     ; 12DB 0 100 280 C4D8980A
vtec_highcam_output_clear_ram127_bit1:     RB      off(00127h).1          ; 12DF 0 100 280 C42709
                SJ      fuelmap_base_lookup             ; 12E2 0 100 280 CB18
vtec_engage_conditions_start_load_ram1df:     MOVB    off(001dfh), #014h     ; 12E4 0 100 280 C4DF9814
vtec_engage_conditions_start_set_p1_bit0:     SB      P1.0                   ; 12E8 0 100 280 C52218
                SB      off(00127h).2          ; 12EB 0 100 280 C4271A
                JBR     off(00119h).1, vtec_engage_conditions_start_load_ram1d9 ; 12EE 0 100 280 D919E6
vtec_engage_conditions_start_load_ram1d8:     LB      A, off(001d8h)         ; 12F1 0 100 280 F4D8
                JNE     vtec_highcam_output_clear_ram127_bit1             ; 12F3 0 100 280 CEEA
                MOVB    off(001d9h), #00ah     ; 12F5 0 100 280 C4D9980A
vtec_engage_conditions_start_set_ram127_bit1:     SB      off(00127h).1          ; 12F9 0 100 280 C42719
fuelmap_base_lookup:     MOVB    r0, #00ah              ; 12FC 0 100 280 980A
                MOVB    r1, #014h              ; 12FE 0 100 280 9914
                MOVB    r2, off(001bch)        ; 1300 0 100 280 C4BC4A
                MOV     X2, off(001c0h)        ; 1303 0 100 280 B4C079
                MOVB    r3, off(001c7h)        ; 1306 0 100 280 C4C74B
                MOV     er3, off(001c4h)       ; 1309 0 100 280 B4C44B
                MOV     X1, #fuelmap_base_lookup_tbl_3          ; 130C 0 100 280 602271
                JBR     off(0011ch).5, fuelmap_base_lookup_load_dp ; 130F 0 100 280 DD1C03
                JBS     off(00120h).5, fuelmap_base_lookup_set_pswl_bit5 ; 1312 0 100 280 ED2029
fuelmap_base_lookup_load_dp:     MOV     DP, #fuelmap_base_lookup_tbl_5          ; 1315 0 100 280 626C72
                MOVB    r4, #000h              ; 1318 0 100 280 9C00
                JBS     off(00127h).1, fuelmap_base_lookup_if_ram121_bit6_clr ; 131A 0 100 280 E9270E
                MOVB    r3, off(001c6h)        ; 131D 0 100 280 C4C64B
                MOV     er3, off(001c2h)       ; 1320 0 100 280 B4C24B
                MOV     X1, #fuelmap_base_lookup_tbl_2          ; 1323 0 100 280 605070
                MOV     DP, #fuelmap_base_lookup_tbl_4          ; 1326 0 100 280 62F471
                MOVB    r4, #000h              ; 1329 0 100 280 9C00
fuelmap_base_lookup_if_ram121_bit6_clr:     JBR     off(00121h).6, fuelmap_base_lookup_set_pswl_bit5 ; 132B 0 100 280 DE2110
                LB      A, r4                  ; 132E 0 100 280 7C
                CMPB    A, r3                  ; 132F 0 100 280 4B
                JGT     fuelmap_base_lookup_set_pswl_bit5             ; 1330 0 100 280 C80C
                ADDB    A, #00ah               ; 1332 0 100 280 860A
                CMPB    A, r3                  ; 1334 0 100 280 4B
                JLE     fuelmap_base_lookup_set_pswl_bit5             ; 1335 0 100 280 CF07
                LB      A, r4                  ; 1337 0 100 280 7C
                SUBB    r3, A                  ; 1338 0 100 280 23A1
                MOVB    r1, #00bh              ; 133A 0 100 280 990B
                MOV     X1, DP                 ; 133C 0 100 280 9278
fuelmap_base_lookup_set_pswl_bit5:     SB      PSWL.5                 ; 133E 0 100 280 A31D
                CAL     table2d_lookup_interp             ; 1340 0 100 280 32E459
                LCB     A, fuelmap_base_lookup_tbl            ; 1343 0 100 280 909DE560
                MOV     A, er2                 ; 1347 1 100 280 4699
                JEQ     fuelmap_base_lookup_store_ram140             ; 1349 1 100 280 C903
                CAL     map_result_postscale             ; 134B 1 100 280 32555A
fuelmap_base_lookup_store_ram140:     ST      A, off(00140h)         ; 134E 1 100 280 D440
                LB      A, off(00182h)         ; 1350 0 100 280 F482
                JBS     off(0011fh).5, accel_iac_calc ; 1352 0 100 280 ED1F05
                JBS     off(0012ch).4, fuel_timer_scale ; 1355 0 100 280 EC2C1A
                SJ      accel_iac_clamp_min             ; 1358 0 100 280 CB14
accel_iac_calc:     LB      A, off(0016bh)         ; 135A 0 100 280 F46B
                STB     A, r0                  ; 135C 0 100 280 88
                LB      A, #09ah               ; 135D 0 100 280 779A
                MULB                           ; 135F 0 100 280 A234
                L       A, ACC                 ; 1361 1 100 280 E506
                SLL     A                      ; 1363 1 100 280 53
                LB      A, ACCH                ; 1364 0 100 280 F507
                JGE     accel_iac_calc_cmp_acc             ; 1366 0 100 280 CD02
                LB      A, #0ffh               ; 1368 0 100 280 77FF
accel_iac_calc_cmp_acc:     CMPB    A, #040h               ; 136A 0 100 280 C640
                JGE     accel_iac_store             ; 136C 0 100 280 CD02
accel_iac_clamp_min:     LB      A, #040h               ; 136E 0 100 280 7740
accel_iac_store:     STB     A, off(00182h)         ; 1370 0 100 280 D482
fuel_timer_scale:     MOVB    r0, off(00183h)        ; 1372 0 100 280 C48348
                MULB                           ; 1375 0 100 280 A234
                MOVB    r1, off(00181h)        ; 1377 0 100 280 C48149
                CLRB    r0                     ; 137A 0 100 280 2015
                MUL                            ; 137C 0 100 280 9035
                MOV     er0, er1               ; 137E 0 100 280 4548
                L       A, off(0015eh)         ; 1380 1 100 280 E45E
                MUL                            ; 1382 1 100 280 9035
                MOV     off(00184h), er1       ; 1384 1 100 280 457C84
                CMPB    off(00133h), #0c0h     ; 1387 1 100 280 C433C0C0
                RB      PSWH.7                 ; 138B 1 100 280 A20F
                MOVB    r0, 0d6h               ; 138D 1 100 280 C5D648
                MB      C, off(00123h).2       ; 1390 1 100 280 C4232A
                JEQ     accelenrich_rpm_mode_check             ; 1393 1 100 280 C906
                MOVB    r0, 0d5h               ; 1395 1 100 280 C5D548
                MB      C, off(00123h).1       ; 1398 1 100 280 C42329
accelenrich_rpm_mode_check:     JLT     accelenrich_flags_clear             ; 139B 1 100 280 CA0F
                LB      A, #00ah               ; 139D 0 100 280 770A
                CMPB    A, r0                  ; 139F 0 100 280 48
                MB      off(0012ch).1, C       ; 13A0 0 100 280 C42C39
                LB      A, #00ah               ; 13A3 0 100 280 770A
                CMPB    A, r0                  ; 13A5 0 100 280 48
                MB      off(0012ch).2, C       ; 13A6 0 100 280 C42C3A
                RC                             ; 13A9 0 100 280 95
                SJ      accelenrich_mode_flag_store             ; 13AA 0 100 280 CB09
accelenrich_flags_clear:     RB      off(0012ch).1          ; 13AC 1 100 280 C42C09
                RB      off(0012ch).2          ; 13AF 1 100 280 C42C0A
                LB      A, #004h               ; 13B2 0 100 280 7704
                CMPB    A, r0                  ; 13B4 0 100 280 48
accelenrich_mode_flag_store:     MB      off(0012ch).0, C       ; 13B5 0 100 280 C42C38
                JBS     off(00125h).4, accelenrich_jump_cranking_path ; 13B8 0 100 280 EC251A
                JBS     off(00119h).0, accelenrich_jump_cranking_path ; 13BB 0 100 280 E81917
                JBR     off(0012ch).0, accelenrich_clear_pulse_check ; 13BE 0 100 280 D82C69
                JBR     off(00123h).3, accelenrich_jump_tipin_check ; 13C1 0 100 280 DB2314
                LB      A, off(0018ah)         ; 13C4 0 100 280 F48A
                JBS     off(0012ch).3, accelenrich_table_lookup ; 13C6 0 100 280 EB2C3D
                CMPB    0bdh, #0dah            ; 13C9 0 100 280 C5BDC0DA
                JGE     accelenrich_jump_cranking_path             ; 13CD 0 100 280 CD06
                CMPB    0d3h, #0b3h            ; 13CF 0 100 280 C5D3C0B3
                JLT     accelenrich_base_calc             ; 13D3 0 100 280 CA06
accelenrich_jump_cranking_path:     J       accelenrich_clear_and_cranking_prep             ; 13D5 0 100 280 03B914
accelenrich_jump_tipin_check:     J       accelenrich_jump_tipin_check_load_ram142             ; 13D8 0 100 280 036114
accelenrich_base_calc:     CLRB    A                      ; 13DB 0 100 280 FA
                JBR     off(00120h).1, accelenrich_base_adjust ; 13DC 0 100 280 D92006
                CMPB    0cch, #005h            ; 13DF 0 100 280 C5CCC005
                JLT     accelenrich_result_store             ; 13E3 0 100 280 CA1F
accelenrich_base_adjust:     ADDB    A, #02ah               ; 13E5 0 100 280 862A
                JBR     off(0012eh).4, accelenrich_rpm_tier1 ; 13E7 0 100 280 DC2E02
                ADDB    A, #006h               ; 13EA 0 100 280 8606
accelenrich_rpm_tier1:     CMPB    off(00133h), #0c0h     ; 13EC 0 100 280 C433C0C0
                JGE     accelenrich_result_store             ; 13F0 0 100 280 CD12
                SUBB    A, #00ch               ; 13F2 0 100 280 A60C
                CMPB    off(00133h), #08dh     ; 13F4 0 100 280 C433C08D
                JGE     accelenrich_result_store             ; 13F8 0 100 280 CD0A
                SUBB    A, #00ch               ; 13FA 0 100 280 A60C
                CMPB    off(00133h), #074h     ; 13FC 0 100 280 C433C074
                JGE     accelenrich_result_store             ; 1400 0 100 280 CD02
                SUBB    A, #00ch               ; 1402 0 100 280 A60C
accelenrich_result_store:     STB     A, off(0018ah)         ; 1404 0 100 280 D48A
accelenrich_table_lookup:     CLRB    ACCH                   ; 1406 0 100 280 C50715
                MOV     X1, A                  ; 1409 0 100 280 50
                ADD     X1, #tbl_tipin_enrich_rpm          ; 140A 0 100 280 9080F862
                LB      A, r0                  ; 140E 0 100 280 78
                VCAL    2                      ; 140F 0 100 280 12
                MOV     er0, off(00184h)       ; 1410 0 100 280 B48448
                MUL                            ; 1413 0 100 280 9035
                SRL     er1                    ; 1415 0 100 280 45E7
                RORB    A                      ; 1417 0 100 280 43
                SRL     er1                    ; 1418 0 100 280 45E7
                RORB    A                      ; 141A 0 100 280 43
                LB      A, r2                  ; 141B 0 100 280 7A
                L       A, ACC                 ; 141C 1 100 280 E506
                SWAP                           ; 141E 1 100 280 83
                CMPB    r3, #000h              ; 141F 1 100 280 23C000
                JEQ     accelenrich_table_lookup_goto_cranking_flag_check             ; 1422 1 100 280 C903
                L       A, #0ffffh             ; 1424 1 100 280 67FFFF
accelenrich_table_lookup_goto_cranking_flag_check:     J       cranking_flag_check             ; 1427 1 100 280 03C214
accelenrich_clear_pulse_check:     JBR     off(0012ch).2, accelenrich_clear_pulse_check_cmp_ram133 ; 142A 0 100 280 DA2C03
                CLR     off(00142h)            ; 142D 0 100 280 B44215
accelenrich_clear_pulse_check_cmp_ram133:     CMPB    off(00133h), #053h     ; 1430 0 100 280 C433C053
                JLT     accelenrich_jump_tipin_check_load_ram142             ; 1434 0 100 280 CA2B
                JBR     off(0012ch).1, tipin_gate_common ; 1436 0 100 280 D92C20
                JBR     off(00123h).3, tipin_gate_common ; 1439 0 100 280 DB231D
                MOV     X1, #tbl_tipin_low          ; 143C 0 100 280 609463
                CMPB    (00251h-00280h)[USP], #003h ; 143F 0 100 280 C3D1C003
                JGE     tipin_table_gear_adjust             ; 1443 0 100 280 CD04
                ADD     X1, #00006h            ; 1445 0 100 280 90800600
tipin_table_gear_adjust:     CMPB    off(00133h), #08dh     ; 1449 0 100 280 C433C08D
                JGE     tipin_table_lookup             ; 144D 0 100 280 CD04
                SUB     X1, #0000ch            ; 144F 0 100 280 90A00C00
tipin_table_lookup:     LB      A, r0                  ; 1453 0 100 280 78
                VCAL    2                      ; 1454 0 100 280 12
                LB      A, ACC                 ; 1455 0 100 280 F506
                SJ      accelenrich_clear_and_cranking_prep_store_ram167             ; 1457 0 100 280 CB61
tipin_gate_common:     LB      A, off(00167h)         ; 1459 0 100 280 F467
                JEQ     accelenrich_jump_tipin_check_load_ram142             ; 145B 0 100 280 C904
                ADDB    A, #003h               ; 145D 0 100 280 8603
                JGE     accelenrich_clear_and_cranking_prep_store_ram167             ; 145F 0 100 280 CD59
accelenrich_jump_tipin_check_load_ram142:     L       A, off(00142h)         ; 1461 1 100 280 E442
                JEQ     accelenrich_clear_and_cranking_prep             ; 1463 1 100 280 C954
                ST      A, er3                 ; 1465 1 100 280 8B
                LB      A, off(0018ah)         ; 1466 0 100 280 F48A
                EXTND                          ; 1468 1 100 280 F8
                MOV     DP, #tbl_tipin_normal_enrich          ; 1469 1 100 280 622E63
                ADD     DP, A                  ; 146C 1 100 280 9281
                LC      A, [DP]                ; 146E 1 100 280 92A8
                ST      A, er2                 ; 1470 1 100 280 8A
                CMP     A, er3                 ; 1471 1 100 280 4B
                L       A, #0007dh             ; 1472 1 100 280 677D00
                JLT     tipin_table_result_alt             ; 1475 1 100 280 CA36
                LC      A, 00002h[DP]          ; 1477 1 100 280 92A90200
                ST      A, er2                 ; 147B 1 100 280 8A
                CMP     A, er3                 ; 147C 1 100 280 4B
                JLT     tipin_table_row2             ; 147D 1 100 280 CA1A
                MOV     er0, off(00188h)       ; 147F 1 100 280 B48848
                LC      A, 00004h[DP]          ; 1482 1 100 280 92A90400
                MUL                            ; 1486 1 100 280 9035
                LB      A, r2                  ; 1488 0 100 280 7A
                L       A, ACC                 ; 1489 1 100 280 E506
                SWAP                           ; 148B 1 100 280 83
                CMPB    r3, #000h              ; 148C 1 100 280 23C000
                JEQ     accelenrich_jump_tipin_check_xchg_acc             ; 148F 1 100 280 C903
                L       A, #0ffffh             ; 1491 1 100 280 67FFFF
accelenrich_jump_tipin_check_xchg_acc:     XCHG    A, er3                 ; 1494 1 100 280 4710
                SUB     A, er3                 ; 1496 1 100 280 2B
                SJ      tipin_table_final             ; 1497 1 100 280 CB1E
tipin_table_row2:     MOV     er0, off(00186h)       ; 1499 1 100 280 B48648
                L       A, #00032h             ; 149C 1 100 280 673200
                MUL                            ; 149F 1 100 280 9035
                LB      A, r2                  ; 14A1 0 100 280 7A
                L       A, ACC                 ; 14A2 1 100 280 E506
                SWAP                           ; 14A4 1 100 280 83
                CMPB    r3, #000h              ; 14A5 1 100 280 23C000
                JEQ     tipin_table_result_alt             ; 14A8 1 100 280 C903
                L       A, #0ffffh             ; 14AA 1 100 280 67FFFF
tipin_table_result_alt:     XCHG    A, er3                 ; 14AD 1 100 280 4710
                SUB     A, er3                 ; 14AF 1 100 280 2B
                JLT     tipin_table_result_common             ; 14B0 1 100 280 CA03
                CMP     A, er2                 ; 14B2 1 100 280 4A
                JGE     tipin_table_final             ; 14B3 1 100 280 CD02
tipin_table_result_common:     L       A, er2                 ; 14B5 1 100 280 36
                RC                             ; 14B6 1 100 280 95
tipin_table_final:     JGE     cranking_flag_check             ; 14B7 1 100 280 CD09
accelenrich_clear_and_cranking_prep:     CLRB    A                      ; 14B9 0 100 280 FA
accelenrich_clear_and_cranking_prep_store_ram167:     STB     A, off(00167h)         ; 14BA 0 100 280 D467
                RB      off(0012ch).3          ; 14BC 0 100 280 C42C0B
                CLR     A                      ; 14BF 1 100 280 F9
                SJ      SetCranking             ; 14C0 1 100 280 CB06
cranking_flag_check:     CLRB    off(00167h)            ; 14C2 1 100 280 C46715
                SB      off(0012ch).3          ; 14C5 1 100 280 C42C1B
SetCranking:     ST      A, off(00142h)         ; 14C8 1 100 280 D442
                JBS     off(0011fh).5, Cranking ; 14CA 1 100 280 ED1F03
                J       notcranking_entry             ; 14CD 1 100 280 031D16
Cranking:     MOV     X1, #Cranking_tbl          ; 14D0 1 100 280 601C64
                LB      A, 0d9h                ; 14D3 0 100 280 F5D9
                VCAL    0                      ; 14D5 0 100 280 10
                STB     A, off(00140h)         ; 14D6 0 100 280 D440
                J       Cranking_load_x1             ; 14D8 0 100 280 030479
                DB  000h,000h,000h ; 14DB
Cranking_store_ram164:     STB     A, off(00164h)         ; 14DE 0 100 280 D464
                MOV     X1, #CrankFuelMap          ; 14E0 0 100 280 603B64
                LB      A, 0bch                ; 14E3 0 100 280 F5BC
                VCAL    1                      ; 14E5 0 100 280 11
                STB     A, off(00165h)         ; 14E6 0 100 280 D465
                MOVB    r0, off(00164h)        ; 14E8 0 100 280 C46448
                MULB                           ; 14EB 0 100 280 A234
                MOV     er0, off(00140h)       ; 14ED 0 100 280 B44048
                MUL                            ; 14F0 0 100 280 9035
                L       A, ACC                 ; 14F2 1 100 280 E506
                SLL     A                      ; 14F4 1 100 280 53
                ROL     er1                    ; 14F5 1 100 280 45B7
                JLT     crankfuel_clamp_max             ; 14F7 1 100 280 CA09
                SLL     A                      ; 14F9 1 100 280 53
                L       A, er1                 ; 14FA 1 100 280 35
                ROL     A                      ; 14FB 1 100 280 33
                JLT     crankfuel_clamp_max             ; 14FC 1 100 280 CA04
                ADD     A, off(00142h)         ; 14FE 1 100 280 8742
                JGE     crankfuel_halve_check             ; 1500 1 100 280 CD03
crankfuel_clamp_max:     L       A, #0ffffh             ; 1502 1 100 280 67FFFF
crankfuel_halve_check:     MB      C, 0b7h.0              ; 1505 1 100 280 C5B728
                JGE     crankfuel_add_adjust             ; 1508 1 100 280 CD02
                SRL     A                      ; 150A 1 100 280 63
                SRL     A                      ; 150B 1 100 280 63
crankfuel_add_adjust:     ADD     A, off(00144h)         ; 150C 1 100 280 8744
                JGE     crankfuel_zero_gate             ; 150E 1 100 280 CD03
                L       A, #0ffffh             ; 1510 1 100 280 67FFFF
crankfuel_zero_gate:     JBR     off(0012ah).1, crankfuel_store_injectors_ab ; 1513 1 100 280 D92A01
                CLR     A                      ; 1516 1 100 280 F9
crankfuel_store_injectors_ab:     MOV     DP, #003a2h            ; 1517 1 100 280 62A203
                ST      A, [DP]                ; 151A 1 100 280 D2
                MOV     DP, #003b4h            ; 151B 1 100 280 62B403
                ST      A, [DP]                ; 151E 1 100 280 D2
                CLR     X1                     ; 151F 1 100 280 9015
                CAL     scale_mul5_div4             ; 1521 1 100 280 329159
                AND     IE, #002a0h            ; 1524 1 100 280 B51AD0A002
                ANDB    PSWH, #0feh            ; 1529 1 100 280 A2D0FE
                ST      A, 003b6h[X1]          ; 152C 1 100 280 D0B603
                ST      A, 003b8h[X1]          ; 152F 1 100 280 D0B803
                ST      A, 003bah[X1]          ; 1532 1 100 280 D0BA03
                ST      A, 003bch[X1]          ; 1535 1 100 280 D0BC03
                ORB     PSWH, #001h            ; 1538 1 100 280 A2E001
                L       A, 0f8h                ; 153B 1 100 280 E5F8
                ST      A, IE                  ; 153D 1 100 280 D51A
                MB      C, 0b7h.0              ; 153F 1 100 280 C5B728
                JLT     crankfuel_output_apply_start             ; 1542 1 100 280 CA0C
                CMPB    off(0013dh), #004h     ; 1544 1 100 280 C43DC004
                JNE     postfuel_calc_start             ; 1548 1 100 280 CE58
                CMPB    0d9h, #0e8h            ; 154A 1 100 280 C5D9C0E8
                JGE     postfuel_calc_start             ; 154E 1 100 280 CD52
crankfuel_output_apply_start:     L       A, 003b6h[X1]          ; 1550 1 100 280 E0B603
                ST      A, off(00196h)         ; 1553 1 100 280 D496
                ST      A, off(00194h)         ; 1555 1 100 280 D494
                ST      A, off(00192h)         ; 1557 1 100 280 D492
                ST      A, off(00190h)         ; 1559 1 100 280 D490
                L       A, 0fah                ; 155B 1 100 280 E5FA
                ST      A, IE                  ; 155D 1 100 280 D51A
                ANDB    PSWH, #0feh            ; 155F 1 100 280 A2D0FE
                L       A, TM0                 ; 1562 1 100 280 E530
                SUB     A, TMR0                ; 1564 1 100 280 B532A2
                MB      C, IRQ.5               ; 1567 1 100 280 C5182D
                JLT     crankfuel_timer_sync_done             ; 156A 1 100 280 CA08
                ADD     A, #00005h             ; 156C 1 100 280 860500
                JLT     crankfuel_timer_sync_done             ; 156F 1 100 280 CA03
                ADD     TMR0, A                ; 1571 1 100 280 B53281
crankfuel_timer_sync_done:     ORB     PSWH, #001h            ; 1574 1 100 280 A2E001
                L       A, 0f8h                ; 1577 1 100 280 E5F8
                ST      A, IE                  ; 1579 1 100 280 D51A
                MOV     DP, #00010h            ; 157B 1 100 280 621000
crankfuel_timer_wait_loop:     L       A, off(00196h)         ; 157E 1 100 280 E496
                JRNZ    DP, crankfuel_timer_wait_loop         ; 1580 1 100 280 30FC
                CAL     injector_timer_schedule             ; 1582 1 100 280 32F854
                JBS     off(0011fh).3, cylinder_index_advance ; 1585 1 100 280 EB1F12
                JBS     off(0011bh).7, cylinder_index_advance ; 1588 1 100 280 EF1B0F
                MULB                           ; 158B 1 100 280 A234
                RB      off(0012ah).0          ; 158D 1 100 280 C42A08
                JEQ     cylinder_index_advance             ; 1590 1 100 280 C908
                RB      TRNSIT.2               ; 1592 1 100 280 C5460A
                JNE     cylinder_index_advance             ; 1595 1 100 280 CE03
dtc16_injector_latch_2: SB      0b4h.6                 ; 1597 1 100 280 C5B41E
cylinder_index_advance:     LB      A, off(0013ch)         ; 159A 0 100 280 F43C
                ADDB    A, #001h               ; 159C 0 100 280 8601
                ANDB    A, #003h               ; 159E 0 100 280 D603
                STB     A, off(0013ch)         ; 15A0 0 100 280 D43C
postfuel_calc_start:     SB      off(0012ch).4          ; 15A2 0 100 280 C42C1C
                LB      A, 0d9h                ; 15A5 0 100 280 F5D9
                CMPB    A, #0cfh               ; 15A7 0 100 280 C6CF
                MB      PSWL.5, C              ; 15A9 0 100 280 A33D
                MOV     X1, #postfuel_calc_start_tbl          ; 15AB 0 100 280 609F61
                VCAL    0                      ; 15AE 0 100 280 10
                STB     A, r0                  ; 15AF 0 100 280 88
                STB     A, r1                  ; 15B0 0 100 280 89
                JBS     off(0011ah).5, postfuel_scale_apply ; 15B1 0 100 280 ED1A2B
                JBS     off(0011bh).1, postfuel_scale_apply ; 15B4 0 100 280 E91B28
                CMPB    0d9h, #0a2h            ; 15B7 0 100 280 C5D9C0A2
                JLT     postfuel_scale_apply             ; 15BB 0 100 280 CA22
                MOV     DP, #0031ah            ; 15BD 0 100 280 621A03
                LB      A, [DP]                ; 15C0 0 100 280 F2
                SUBB    A, 0d9h                ; 15C1 0 100 280 C5D9A2
                JGE     postfuel_ect_rate_check             ; 15C4 0 100 280 CD01
                VCAL    6                      ; 15C6 0 100 280 16
postfuel_ect_rate_check:     CMPB    A, #010h               ; 15C7 0 100 280 C610
                JGE     postfuel_scale_apply             ; 15C9 0 100 280 CD14
                LB      A, 0d8h                ; 15CB 0 100 280 F5D8
                CMPB    A, #0bah               ; 15CD 0 100 280 C6BA
                JLT     postfuel_scale_apply             ; 15CF 0 100 280 CA0E
                SUBB    A, 0d9h                ; 15D1 0 100 280 C5D9A2
                JLT     postfuel_scale_apply             ; 15D4 0 100 280 CA09
                CMPB    A, #006h               ; 15D6 0 100 280 C606
                JLT     postfuel_scale_apply             ; 15D8 0 100 280 CA05
                L       A, #0d99ah             ; 15DA 1 100 280 679AD9
                MUL                            ; 15DD 1 100 280 9035
postfuel_scale_apply:     L       A, er1                 ; 15DF 1 100 280 35
                ST      A, off(00172h)         ; 15E0 1 100 280 D472
                CLRB    off(00171h)            ; 15E2 1 100 280 C47115
                MOV     er2, #02000h           ; 15E5 1 100 280 46980020
                SUB     A, er2                 ; 15E9 1 100 280 2A
                ST      A, er3                 ; 15EA 1 100 280 8B
                CLRB    r0                     ; 15EB 1 100 280 2015
                MOVB    r1, #066h              ; 15ED 1 100 280 9966
                MB      C, PSWL.5              ; 15EF 1 100 280 A32D
                JLT     postfuel_hyst_upper_calc             ; 15F1 1 100 280 CA02
                MOVB    r1, #05ah              ; 15F3 1 100 280 995A
postfuel_hyst_upper_calc:     MUL                            ; 15F5 1 100 280 9035
                L       A, er1                 ; 15F7 1 100 280 35
                ADD     A, er2                 ; 15F8 1 100 280 0A
                ST      A, off(00174h)         ; 15F9 1 100 280 D474
                L       A, er3                 ; 15FB 1 100 280 37
                MOVB    r1, #040h              ; 15FC 1 100 280 9940
                MB      C, PSWL.5              ; 15FE 1 100 280 A32D
                JLT     postfuel_hyst_lower_calc             ; 1600 1 100 280 CA02
                MOVB    r1, #033h              ; 1602 1 100 280 9933
postfuel_hyst_lower_calc:     MUL                            ; 1604 1 100 280 9035
                L       A, er1                 ; 1606 1 100 280 35
                ADD     A, er2                 ; 1607 1 100 280 0A
                ST      A, off(00176h)         ; 1608 1 100 280 D476
                CMPB    0d8h, #030h            ; 160A 1 100 280 C5D8C030
                MB      off(0012bh).3, C       ; 160E 1 100 280 C42B3B
                LB      A, off(0016bh)         ; 1611 0 100 280 F46B
                SUBB    A, off(0016fh)         ; 1613 0 100 280 A76F
                JGE     postfuel_tps_delta_finalize             ; 1615 0 100 280 CD01
                CLRB    A                      ; 1617 0 100 280 FA
postfuel_tps_delta_finalize:     STB     A, off(00170h)         ; 1618 0 100 280 D470
                J       postinj_rpm_check             ; 161A 0 100 280 03B122
notcranking_entry:     RB      0b7h.0                 ; 161D 1 100 280 C5B708
; [H] --- Post-start enrichment decay: selects a decay-rate table (PostFuelDecay/2/3, chosen by
; [H] TPS/RPM conditions), then subtracts the selected decay amount from the enrichment value
; [H] (0x170) each cycle, floored at a minimum of 0x2000, with an ECT-gated (0x2E threshold) exit
; [H] once fully decayed. This is what makes post-start enrichment taper off over time rather than
; [H] cutting off abruptly.
                JEQ     postfuel_decay_table_select             ; 1620 1 100 280 C903
                CLRB    off(0013dh)            ; 1622 1 100 280 C43D15
postfuel_decay_table_select:     JBR     off(0012ch).4, postfuel_final_store_load_imm ; 1625 1 100 280 DC2C64
                MOV     DP, #PostFuelDecay          ; 1628 1 100 280 628761
                JBR     off(0011eh).3, postfuel_decay_table_index_adjust ; 162B 1 100 280 DB1E09
                MOV     DP, #PostFuelDecay2          ; 162E 1 100 280 628F61
                JBS     off(00119h).5, postfuel_decay_table_index_adjust ; 1631 1 100 280 ED1903
                MOV     DP, #PostFuelDecay3          ; 1634 1 100 280 629761
postfuel_decay_table_index_adjust:     CMPB    off(00173h), #026h     ; 1637 1 100 280 C473C026
                JLE     postfuel_decay_table_index_adjust2             ; 163B 1 100 280 CF06
                CMP     off(00172h), off(00174h) ; 163D 1 100 280 B472C374
                JGT     postfuel_decay_apply             ; 1641 1 100 280 C812
postfuel_decay_table_index_adjust2:     INC     DP                     ; 1643 1 100 280 72
                INC     DP                     ; 1644 1 100 280 72
                CMP     off(00172h), off(00176h) ; 1645 1 100 280 B472C376
                JGT     postfuel_decay_apply             ; 1649 1 100 280 C80A
                INC     DP                     ; 164B 1 100 280 72
                INC     DP                     ; 164C 1 100 280 72
                CMPB    0d8h, #044h            ; 164D 1 100 280 C5D8C044
                JGE     postfuel_decay_apply             ; 1651 1 100 280 CD02
                INC     DP                     ; 1653 1 100 280 72
                INC     DP                     ; 1654 1 100 280 72
postfuel_decay_apply:     LC      A, [DP]                ; 1655 1 100 280 92A8
                SUBB    off(00171h), A         ; 1657 1 100 280 C471A1
                CLRB    A                      ; 165A 0 100 280 FA
                L       A, ACC                 ; 165B 1 100 280 E506
                SWAP                           ; 165D 1 100 280 83
                ST      A, er0                 ; 165E 1 100 280 88
                L       A, off(00172h)         ; 165F 1 100 280 E472
                SBC     A, er0                 ; 1661 1 100 280 38
                CMP     A, #02000h             ; 1662 1 100 280 C60020
                JLE     postfuel_decay_zero_reset             ; 1665 1 100 280 CF1B
                ST      A, off(00172h)         ; 1667 1 100 280 D472
                CMPB    0d9h, #02eh            ; 1669 1 100 280 C5D9C02E
                JLT     postfuel_final_store             ; 166D 1 100 280 CA1B
                JBR     off(00119h).2, postfuel_final_store ; 166F 1 100 280 DA1918
                CLRB    r0                     ; 1672 1 100 280 2015
                MOVB    r1, #08dh              ; 1674 1 100 280 998D
                MUL                            ; 1676 1 100 280 9035
                SLL     A                      ; 1678 1 100 280 53
                L       A, er1                 ; 1679 1 100 280 35
                ROL     A                      ; 167A 1 100 280 33
                JGE     postfuel_final_store             ; 167B 1 100 280 CD0D
                L       A, #0ffffh             ; 167D 1 100 280 67FFFF
                SJ      postfuel_final_store             ; 1680 1 100 280 CB08
postfuel_decay_zero_reset:     RB      off(0012ch).4          ; 1682 1 100 280 C42C0C
                L       A, #02000h             ; 1685 1 100 280 670020
                ST      A, off(00172h)         ; 1688 1 100 280 D472
postfuel_final_store:     ST      A, off(0015ch)         ; 168A 1 100 280 D45C
postfuel_final_store_load_imm:     LB      A, #0bah               ; 168C 0 100 280 77BA
                JBS     off(0012fh).0, postfuel_final_store_cmp_acc ; 168E 0 100 280 E82F02
                LB      A, #0c0h               ; 1691 0 100 280 77C0
postfuel_final_store_cmp_acc:     CMPB    A, off(00133h)         ; 1693 0 100 280 C733
                MB      off(0012fh).0, C       ; 1695 0 100 280 C42F38
                LB      A, #0deh               ; 1698 0 100 280 77DE
                JBS     off(0012fh).5, postfuel_final_store_cmp_acc_2 ; 169A 0 100 280 ED2F02
                LB      A, #0e0h               ; 169D 0 100 280 77E0
postfuel_final_store_cmp_acc_2:     CMPB    A, off(00133h)         ; 169F 0 100 280 C733
                MB      off(0012fh).5, C       ; 16A1 0 100 280 C42F3D
                LB      A, #017h               ; 16A4 0 100 280 7717
                JBS     off(0012fh).2, postfuel_final_store_cmp_ram0d9 ; 16A6 0 100 280 EA2F02
                LB      A, #014h               ; 16A9 0 100 280 7714
postfuel_final_store_cmp_ram0d9:     CMPB    0d9h, A                ; 16AB 0 100 280 C5D9C1
                MB      off(0012fh).2, C       ; 16AE 0 100 280 C42F3A
                LB      A, #014h               ; 16B1 0 100 280 7714
                JBS     off(0012fh).1, postfuel_final_store_cmp_ram0d9_2 ; 16B3 0 100 280 E92F02
                LB      A, #011h               ; 16B6 0 100 280 7711
postfuel_final_store_cmp_ram0d9_2:     CMPB    0d9h, A                ; 16B8 0 100 280 C5D9C1
                MB      off(0012fh).1, C       ; 16BB 0 100 280 C42F39
                LB      A, off(00133h)         ; 16BE 0 100 280 F433
                MOV     X1, #CloseLoopTPS          ; 16C0 0 100 280 605F62
                JBS     off(0012fh).6, closeloop_tps_lookup ; 16C3 0 100 280 EE2F03
                MOV     X1, #OpenLoopTPS          ; 16C6 0 100 280 606B62
closeloop_tps_lookup:     CAL     table_interp_lookup             ; 16C9 0 100 280 323958
                CMPB    A, 0d1h                ; 16CC 0 100 280 C5D1C2
                MB      off(0012fh).6, C       ; 16CF 0 100 280 C42F3E
                LB      A, off(00133h)         ; 16D2 0 100 280 F433
                MOV     X1, #tbl_closeloop_tps          ; 16D4 0 100 280 602F62
                CMPCB   A, 0000ch[X1]          ; 16D7 0 100 280 90AF0C00
                MB      off(0012fh).3, C       ; 16DB 0 100 280 C42F3B
                CAL     table_interp_lookup             ; 16DE 0 100 280 323958
                CLRB    r0                     ; 16E1 0 100 280 2015
                RB      PSWL.4                 ; 16E3 0 100 280 A30C
                JBS     off(0012fh).3, ve_adjust_sub ; 16E5 0 100 280 EB2F1C
                MOVB    r0, #020h              ; 16E8 0 100 280 9820
                JBS     off(0012fh).1, ve_adjust_sub ; 16EA 0 100 280 E92F17
                JBR     off(0011eh).1, closeloop_tps_lookup_clear_r0 ; 16ED 0 100 280 D91E0D
                JBR     off(0012fh).0, closeloop_tps_lookup_clear_r0 ; 16F0 0 100 280 D82F0A
                MOVB    r0, #040h              ; 16F3 0 100 280 9840
                JBS     off(00120h).7, ve_adjust_add ; 16F5 0 100 280 EF2007
                JBS     off(0012fh).2, ve_adjust_add ; 16F8 0 100 280 EA2F04
                SB      PSWL.4                 ; 16FB 0 100 280 A31C
closeloop_tps_lookup_clear_r0:     CLRB    r0                     ; 16FD 0 100 280 2015
ve_adjust_add:     ADDB    r0, off(00180h)        ; 16FF 0 100 280 208380
                JLT     ve_adjust_clamp_zero             ; 1702 0 100 280 CA03
ve_adjust_sub:     SUBB    A, r0                  ; 1704 0 100 280 28
                JGE     ve_adjust2_gate             ; 1705 0 100 280 CD01
ve_adjust_clamp_zero:     CLRB    A                      ; 1707 0 100 280 FA
ve_adjust2_gate:     STB     A, r4                  ; 1708 0 100 280 8C
                RB      PSWL.4                 ; 1709 0 100 280 A30C
                JEQ     ve_adjust2_gate_store_r0             ; 170B 0 100 280 C90D
                LB      A, off(00133h)         ; 170D 0 100 280 F433
                MOV     X1, #ve_adjust2_gate_tbl          ; 170F 0 100 280 604362
                CAL     table_interp_lookup             ; 1712 0 100 280 323958
                SUBB    A, off(00180h)         ; 1715 0 100 280 A780
                JGE     ve_adjust2_gate_store_r0             ; 1717 0 100 280 CD01
                CLRB    A                      ; 1719 0 100 280 FA
ve_adjust2_gate_store_r0:     STB     A, r0                  ; 171A 0 100 280 88
                SUBB    A, #010h               ; 171B 0 100 280 A610
                JGE     ve_adjust2_gate_cmp_acc             ; 171D 0 100 280 CD01
                CLRB    A                      ; 171F 0 100 280 FA
ve_adjust2_gate_cmp_acc:     CMPB    A, off(00132h)         ; 1720 0 100 280 C732
                MB      off(00130h).2, C       ; 1722 0 100 280 C4303A
                LB      A, r0                  ; 1725 0 100 280 78
                MOVB    r0, #008h              ; 1726 0 100 280 9808
                JBR     off(00130h).1, ve_result_flag_store ; 1728 0 100 280 D93004
                SUBB    A, r0                  ; 172B 0 100 280 28
                JGE     ve_result_flag_store             ; 172C 0 100 280 CD01
                CLRB    A                      ; 172E 0 100 280 FA
ve_result_flag_store:     CMPB    A, off(00132h)         ; 172F 0 100 280 C732
                MB      off(00130h).1, C       ; 1731 0 100 280 C43039
                LB      A, r4                  ; 1734 0 100 280 7C
                JBR     off(00130h).0, ve_result_flag_store_cmp_acc ; 1735 0 100 280 D83004
                SUBB    A, r0                  ; 1738 0 100 280 28
                JGE     ve_result_flag_store_cmp_acc             ; 1739 0 100 280 CD01
                CLRB    A                      ; 173B 0 100 280 FA
ve_result_flag_store_cmp_acc:     CMPB    A, off(00132h)         ; 173C 0 100 280 C732
                MB      off(00130h).0, C       ; 173E 0 100 280 C43038
                SC                             ; 1741 0 100 280 85
                JBR     off(0011eh).1, ve_result_flag_store_store_carry_ram126_bit3 ; 1742 0 100 280 D91E4B
                JBS     off(00120h).7, ve_result_flag_store_store_carry_ram126_bit3 ; 1745 0 100 280 EF2048
                JBS     off(00130h).2, ve_result_flag_store_load_ram1cc ; 1748 0 100 280 EA300F
                RB      off(00129h).2          ; 174B 0 100 280 C4290A
                JEQ     ve_result_flag_store_clear_ram1ca             ; 174E 0 100 280 C904
                MOVB    off(001cbh), off(001cah) ; 1750 0 100 280 C4CA7CCB
ve_result_flag_store_clear_ram1ca:     CLRB    off(001cah)            ; 1754 0 100 280 C4CA15
                RC                             ; 1757 0 100 280 95
                SJ      ve_result_flag_store_store_carry_ram126_bit3             ; 1758 0 100 280 CB36
ve_result_flag_store_load_ram1cc:     LB      A, off(001cch)         ; 175A 0 100 280 F4CC
                SB      off(00129h).2          ; 175C 0 100 280 C4291A
                JNE     ve_result_flag_store_clear_ram1c9             ; 175F 0 100 280 CE26
                CLR     A                      ; 1761 1 100 280 F9
                LB      A, off(001c9h)         ; 1762 0 100 280 F4C9
                MOV     er0, A                 ; 1764 0 100 280 448A
                LB      A, off(001cbh)         ; 1766 0 100 280 F4CB
                MOV     er1, A                 ; 1768 0 100 280 458A
                LB      A, off(001cch)         ; 176A 0 100 280 F4CC
                L       A, ACC                 ; 176C 1 100 280 E506
                ADD     A, er0                 ; 176E 1 100 280 08
                SUB     A, er1                 ; 176F 1 100 280 29
                LB      A, ACC                 ; 1770 0 100 280 F506
                JGE     ve_result_flag_store_cmp_acch             ; 1772 0 100 280 CD03
                CLRB    A                      ; 1774 0 100 280 FA
                SJ      ve_result_flag_store_load_r4             ; 1775 0 100 280 CB08
ve_result_flag_store_cmp_acch:     CMPB    ACCH, #000h            ; 1777 0 100 280 C507C000
                JEQ     ve_result_flag_store_load_r4             ; 177B 0 100 280 C902
                LB      A, #0ffh               ; 177D 0 100 280 77FF
ve_result_flag_store_load_r4:     MOVB    r4, #006h              ; 177F 0 100 280 9C06
                CMPB    A, r4                  ; 1781 0 100 280 4C
                JLT     ve_result_flag_store_store_ram1cc             ; 1782 0 100 280 CA01
                LB      A, r4                  ; 1784 0 100 280 7C
ve_result_flag_store_store_ram1cc:     STB     A, off(001cch)         ; 1785 0 100 280 D4CC
ve_result_flag_store_clear_ram1c9:     CLRB    off(001c9h)            ; 1787 0 100 280 C4C915
                CMPB    off(001cah), A         ; 178A 0 100 280 C4CAC1
                XORB    PSWH, #080h            ; 178D 0 100 280 A2F080
ve_result_flag_store_store_carry_ram126_bit3:     MB      off(00126h).3, C       ; 1790 0 100 280 C4263B
                MOVB    r0, #00ah              ; 1793 0 100 280 980A
                MOVB    r1, #014h              ; 1795 0 100 280 9914
                MOVB    r2, off(001bch)        ; 1797 0 100 280 C4BC4A
                MOV     X2, off(001c0h)        ; 179A 0 100 280 B4C079
                MOVB    r3, off(001c7h)        ; 179D 0 100 280 C4C74B
                MOV     er3, off(001c4h)       ; 17A0 0 100 280 B4C44B
                MOV     X1, #ve_result_flag_store_tbl_2          ; 17A3 0 100 280 601876
                RB      PSWL.5                 ; 17A6 0 100 280 A30D
                JBR     off(0011ch).5, ve_result_flag_store_if_ram127_bit1_set ; 17A8 0 100 280 DD1C03
                JBS     off(00120h).5, ve_result_flag_store_call_table2d_lookup_interp ; 17AB 0 100 280 ED200C
ve_result_flag_store_if_ram127_bit1_set:     JBS     off(00127h).1, ve_result_flag_store_call_table2d_lookup_interp ; 17AE 0 100 280 E92709
                MOVB    r3, off(001c6h)        ; 17B1 0 100 280 C4C64B
                MOV     er3, off(001c2h)       ; 17B4 0 100 280 B4C24B
                MOV     X1, #ve_result_flag_store_tbl          ; 17B7 0 100 280 605075
ve_result_flag_store_call_table2d_lookup_interp:     CAL     table2d_lookup_interp             ; 17BA 0 100 280 32E459
                LB      A, r4                  ; 17BD 0 100 280 7C
                SRLB    A                      ; 17BE 0 100 280 63
                STB     A, r0                  ; 17BF 0 100 280 88
                JBS     off(00125h).4, ve_accel_state_store_clear_ram125_bit5 ; 17C0 0 100 280 EC2553
                JBS     off(0011ah).6, ve_accel_gate1 ; 17C3 0 100 280 EE1A03
                JBS     off(0012fh).6, ve_accel_tps_threshold_check ; 17C6 0 100 280 EE2F1D
ve_accel_gate1:     JBS     off(0012fh).3, ve_accel_gate1_load_ram1ca ; 17C9 0 100 280 EB2F2C
                JBS     off(0012fh).1, ve_accel_gate1_load_ram1ca ; 17CC 0 100 280 E92F29
                JBR     off(0012fh).0, ve_accel_gate1_load_imm ; 17CF 0 100 280 D82F33
                JBR     off(0011eh).1, ve_accel_gate1_load_ram1ca ; 17D2 0 100 280 D91E23
                JBS     off(00120h).7, ve_accel_gate1_load_ram1ca ; 17D5 0 100 280 EF2020
                JBS     off(0012fh).2, ve_accel_gate1_load_ram1ca ; 17D8 0 100 280 EA2F1D
                JBR     off(00130h).1, ve_accel_state_store_clear_ram125_bit5 ; 17DB 0 100 280 D93038
                JBS     off(00130h).0, ve_accel_tps_threshold_check ; 17DE 0 100 280 E83005
                JBR     off(00126h).3, ve_accel_state_store_clear_ram125_bit5 ; 17E1 0 100 280 DB2632
                SJ      ve_accel_tps_threshold_check_goto_7bf1             ; 17E4 0 100 280 CB40
ve_accel_tps_threshold_check:     LB      A, r0                  ; 17E6 0 100 280 78
                JBS     off(00126h).3, ve_accel_tps_threshold_check_goto_7bf1 ; 17E7 0 100 280 EB263C
                LB      A, #080h               ; 17EA 0 100 280 7780
; [H] --- TPS-acceleration-enrichment tail (0x1734-0x17B7+): further scaling/clamping of the
; [H] enrichment value against working RAM (0x17D/0x244/0x1C5/0x1B0/0x18F) and two more small
; [H] lookup tables (tbl_ve_accel_1/tbl_ve_accel_2, RPM-indexed, selected by off(00127h).1). Low confidence on
; [H] exact per-flag semantics (no calibration-field anchors in this stretch); named at the
; [H] mechanism level. Ends by copying the ignition-cut output flag (off(00124h).4, set by the
; [H] fuel-cut/rev-limiter block) into off(0012eh).4 -- linking this enrichment stage back into
; [H] the ignition-cut state.
                MULB                           ; 17EC 0 100 280 A234
                SLLB    A                      ; 17EE 0 100 280 53
                LB      A, ACCH                ; 17EF 0 100 280 F507
                ROLB    A                      ; 17F1 0 100 280 33
                JGE     ve_accel_tps_threshold_check_goto_1826             ; 17F2 0 100 280 CD02
                LB      A, #0ffh               ; 17F4 0 100 280 77FF
ve_accel_tps_threshold_check_goto_1826:     SJ      ve_accel_tps_threshold_check_goto_7bf1             ; 17F6 0 100 280 CB2E
ve_accel_gate1_load_ram1ca:     MOVB    off(001cah), #006h     ; 17F8 0 100 280 C4CA9806
                JBR     off(00130h).0, ve_accel_gate1_clear_acc ; 17FC 0 100 280 D83003
                JBS     off(00129h).3, ve_accel_gate1_if_ram121_bit5_set ; 17FF 0 100 280 EB2921
ve_accel_gate1_clear_acc:     CLRB    A                      ; 1802 0 100 280 FA
                SJ      ve_accel_state_store             ; 1803 0 100 280 CB0F
ve_accel_gate1_load_imm:     LB      A, #001h               ; 1805 0 100 280 7701
                JBR     off(00130h).0, ve_accel_state_store ; 1807 0 100 280 D8300A
                CMPB    0cch, #005h            ; 180A 0 100 280 C5CCC005
                JLT     ve_accel_tps_threshold_check             ; 180E 0 100 280 CAD6
                LB      A, off(001dch)         ; 1810 0 100 280 F4DC
                JEQ     ve_accel_tps_threshold_check             ; 1812 0 100 280 C9D2
ve_accel_state_store:     STB     A, off(001dch)         ; 1814 0 100 280 D4DC
ve_accel_state_store_clear_ram125_bit5:     RB      off(00125h).5          ; 1816 0 100 280 C4250D
                RB      off(0012fh).4          ; 1819 0 100 280 C42F0C
ve_accel_state_store_clear_ram12f_bit7:     RB      off(0012fh).7          ; 181C 0 100 280 C42F0F
                LB      A, #040h               ; 181F 0 100 280 7740
                SJ      tpsaccel_result_common_store_ram164             ; 1821 0 100 280 CB6F
ve_accel_gate1_if_ram121_bit5_set:     JBS     off(00121h).5, ve_accel_next_stage ; 1823 0 100 280 ED210C
ve_accel_tps_threshold_check_goto_7bf1:     J       ve_accel_tps_threshold_check_cmp_r0             ; 1826 0 100 280 03F17B
                DB  0FFh ; 1829
to_ve_accel_common:     SB      off(00125h).5          ; 182A 0 100 280 C4251D
                CLRB    off(001dch)            ; 182D 0 100 280 C4DC15
                SJ      ve_accel_state_store_clear_ram12f_bit7             ; 1830 0 100 280 CBEA
ve_accel_next_stage:     MOVB    r0, off(0017fh)        ; 1832 0 100 280 C47F48
; [H] --- TPS-acceleration-enrichment tail (0x1734-0x17B7+): further scaling/clamping of the
; [H] enrichment value against working RAM (0x17D/0x244/0x1C5/0x1B0/0x18F) and two more small
; [H] lookup tables (tbl_ve_accel_1/tbl_ve_accel_2, RPM-indexed, selected by off(00127h).1). Low confidence on
; [H] exact per-flag semantics (no calibration-field anchors in this stretch); named at the
; [H] mechanism level. Ends by copying the ignition-cut output flag (off(00124h).4, set by the
; [H] fuel-cut/rev-limiter block) into off(0012eh).4 -- linking this enrichment stage back into
; [H] the ignition-cut state.
                MULB                           ; 1835 0 100 280 A234
                SLLB    A                      ; 1837 0 100 280 53
                LB      A, ACCH                ; 1838 0 100 280 F507
                ROLB    A                      ; 183A 0 100 280 33
                JGE     tpsaccel_scale_clamp1             ; 183B 0 100 280 CD02
                LB      A, #0ffh               ; 183D 0 100 280 77FF
tpsaccel_scale_clamp1:     STB     A, r2                  ; 183F 0 100 280 8A
                LB      A, (00246h-00280h)[USP] ; 1840 0 100 280 F3C6
                CMPB    A, #015h               ; 1842 0 100 280 C615
                JBS     off(0012fh).4, tpsaccel_hyst_check ; 1844 0 100 280 EC2F07
                JLT     tpsaccel_hyst_check             ; 1847 0 100 280 CA05
                SB      off(0012fh).4          ; 1849 0 100 280 C42F1C
                SJ      tpsaccel_table_select             ; 184C 0 100 280 CB0A
tpsaccel_hyst_check:     CMPB    A, #00ch               ; 184E 0 100 280 C60C
                JGE     tpsaccel_table_select             ; 1850 0 100 280 CD06
                LB      A, r2                  ; 1852 0 100 280 7A
                RB      off(0012fh).4          ; 1853 0 100 280 C42F0C
                SJ      tpsaccel_clamp_0xa0             ; 1856 0 100 280 CB1C
tpsaccel_table_select:     LB      A, off(00133h)         ; 1858 0 100 280 F433
                MOV     X1, #tbl_ve_accel_1          ; 185A 0 100 280 607762
                JBR     off(00127h).1, tpsaccel_table_lookup ; 185D 0 100 280 D92705
                LB      A, 0c2h                ; 1860 0 100 280 F5C2
                MOV     X1, #tbl_ve_accel_2          ; 1862 0 100 280 608362
tpsaccel_table_lookup:     CAL     table_interp_lookup             ; 1865 0 100 280 323958
                MOVB    r0, r2                 ; 1868 0 100 280 2248
                MULB                           ; 186A 0 100 280 A234
                SLLB    A                      ; 186C 0 100 280 53
                LB      A, ACCH                ; 186D 0 100 280 F507
                ROLB    A                      ; 186F 0 100 280 33
                JGE     tpsaccel_clamp_0xa0             ; 1870 0 100 280 CD02
                LB      A, #0ffh               ; 1872 0 100 280 77FF
tpsaccel_clamp_0xa0:     MOVB    r0, #056h              ; 1874 0 100 280 9856
                CMPB    A, r0                  ; 1876 0 100 280 48
                JLT     tpsaccel_clamp_0xa0_cmp_ram1cd             ; 1877 0 100 280 CA01
                LB      A, r0                  ; 1879 0 100 280 78
tpsaccel_clamp_0xa0_cmp_ram1cd:     CMPB    off(001cdh), #000h     ; 187A 0 100 280 C4CDC000
                JNE     tpsaccel_result_common             ; 187E 0 100 280 CE09
                JBR     off(0012fh).5, tpsaccel_result_common ; 1880 0 100 280 DD2F06
                MOVB    r0, #056h              ; 1883 0 100 280 9856
                CMPB    A, r0                  ; 1885 0 100 280 48
                JGE     tpsaccel_result_common             ; 1886 0 100 280 CD01
                LB      A, r0                  ; 1888 0 100 280 78
tpsaccel_result_common:     SB      off(00125h).5          ; 1889 0 100 280 C4251D
                SB      off(0012fh).7          ; 188C 0 100 280 C42F1F
                CLRB    off(001dch)            ; 188F 0 100 280 C4DC15
tpsaccel_result_common_store_ram164:     STB     A, off(00164h)         ; 1892 0 100 280 D464
                JBS     off(0012fh).5, tpsaccel_ignitioncut_flag_copy ; 1894 0 100 280 ED2F0B
                CLRB    A                      ; 1897 0 100 280 FA
                CMPB    0d9h, #02eh            ; 1898 0 100 280 C5D9C02E
                JGE     tpsaccel_ect_default_store             ; 189C 0 100 280 CD02
                LB      A, #034h               ; 189E 0 100 280 7734
tpsaccel_ect_default_store:     STB     A, off(001cdh)         ; 18A0 0 100 280 D4CD
tpsaccel_ignitioncut_flag_copy:     MB      C, off(00124h).4       ; 18A2 0 100 280 C4242C
                MB      off(0012eh).4, C       ; 18A5 0 100 280 C42E3C
                MOV     X1, #tbl_ignmap2_hi          ; 18A8 0 100 280 608364
                JBR     off(00124h).2, tpsaccel_ignitioncut_flag_copy_load_ram133 ; 18AB 0 100 280 DA2403
                MOV     X1, #tbl_ignmap2_lo          ; 18AE 0 100 280 607764
tpsaccel_ignitioncut_flag_copy_load_ram133:     LB      A, off(00133h)         ; 18B1 0 100 280 F433
                CAL     table_interp_lookup             ; 18B3 0 100 280 323958
                SUBB    A, off(001ach)         ; 18B6 0 100 280 A7AC
                JGE     tpsaccel_ignitioncut_flag_copy_cmp_acc             ; 18B8 0 100 280 CD01
                CLRB    A                      ; 18BA 0 100 280 FA
tpsaccel_ignitioncut_flag_copy_cmp_acc:     CMPB    A, off(00132h)         ; 18BB 0 100 280 C732
                MB      off(0012eh).0, C       ; 18BD 0 100 280 C42E38
                LB      A, off(001abh)         ; 18C0 0 100 280 F4AB
                MOVB    r0, #05ah              ; 18C2 0 100 280 985A
                MOVB    r1, #073h              ; 18C4 0 100 280 9973
                JBR     off(00124h).2, tpsaccel_threshold_pick ; 18C6 0 100 280 DA2406
                LB      A, off(001aah)         ; 18C9 0 100 280 F4AA
                MOVB    r0, #047h              ; 18CB 0 100 280 9847
                MOVB    r1, #060h              ; 18CD 0 100 280 9960
tpsaccel_threshold_pick:     JBR     off(00123h).0, tps_hysteresis_check ; 18CF 0 100 280 D8230C
                CMPB    0d8h, #044h            ; 18D2 0 100 280 C5D8C044
                JGE     tpsaccel_threshold_apply             ; 18D6 0 100 280 CD02
                MOVB    r0, r1                 ; 18D8 0 100 280 2148
tpsaccel_threshold_apply:     CMPB    A, r0                  ; 18DA 0 100 280 48
                JGE     tps_hysteresis_check             ; 18DB 0 100 280 CD01
                LB      A, r0                  ; 18DD 0 100 280 78
tps_hysteresis_check:     JBR     off(0011fh).6, rpm_threshold_adjust ; 18DE 0 100 280 DE1F25
                CMPB    0dch, #082h            ; 18E1 0 100 280 C5DCC082
                JBS     off(0012eh).7, tps_hysteresis_store ; 18E5 0 100 280 EF2E04
                CMPB    0dch, #07ah            ; 18E8 0 100 280 C5DCC07A
tps_hysteresis_store:     MB      off(0012eh).7, C       ; 18EC 0 100 280 C42E3F
                STB     A, r0                  ; 18EF 0 100 280 88
                LB      A, #040h               ; 18F0 0 100 280 7740
                JBS     off(0012bh).6, tps_hysteresis_flag2 ; 18F2 0 100 280 EE2B02
                LB      A, #05ah               ; 18F5 0 100 280 775A
tps_hysteresis_flag2:     CMPB    A, r0                  ; 18F7 0 100 280 48
                MB      off(0012bh).6, C       ; 18F8 0 100 280 C42B3E
                LB      A, r0                  ; 18FB 0 100 280 78
                JLT     rpm_threshold_adjust             ; 18FC 0 100 280 CA08
                JBS     off(0012eh).7, rpm_threshold_adjust ; 18FE 0 100 280 EF2E05
                SUBB    A, #00ah               ; 1901 0 100 280 A60A
                JGE     rpm_threshold_adjust             ; 1903 0 100 280 CD01
                CLRB    A                      ; 1905 0 100 280 FA
rpm_threshold_adjust:     CMPB    0cch, #000h            ; 1906 0 100 280 C5CCC000
                JBR     off(0011eh).3, rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold ; 190A 0 100 280 DB1E04
                CMPB    0cch, #008h            ; 190D 0 100 280 C5CCC008
rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold:     JLT     rpm_secondary_threshold_check             ; 1911 0 100 280 CA0C
                JBR     off(0012eh).1, rpm_secondary_threshold_check ; 1913 0 100 280 D92E09
                JBS     off(00124h).2, rpm_secondary_threshold_check ; 1916 0 100 280 EA2406
                ADDB    A, #020h               ; 1919 0 100 280 8620
                JGE     rpm_secondary_threshold_check             ; 191B 0 100 280 CD02
                LB      A, #0ffh               ; 191D 0 100 280 77FF
rpm_secondary_threshold_check:     CMPB    A, off(00133h)         ; 191F 0 100 280 C733
                MB      off(0012eh).3, C       ; 1921 0 100 280 C42E3B
                LB      A, #073h               ; 1924 0 100 280 7773
                JBS     off(0012eh).2, revlimiter_engage_resume_check ; 1926 0 100 280 EA2E02
                LB      A, #080h               ; 1929 0 100 280 7780
revlimiter_engage_resume_check:     CMPB    A, off(00133h)         ; 192B 0 100 280 C733
                MB      off(0012eh).2, C       ; 192D 0 100 280 C42E3A
                RB      PSWL.4                 ; 1930 0 100 280 A30C
                RB      PSWL.5                 ; 1932 0 100 280 A30D
                RB      off(0012bh).7          ; 1934 0 100 280 C42B0F
                JBS     off(0012dh).4, revlimiter_fuelcut_set ; 1937 0 100 280 EC2D72
                JBS     off(0011bh).5, revlimiter_engage_resume_check_if_ram11a_bit6_set ; 193A 0 100 280 ED1B0B
                MB      C, 0b1h.3              ; 193D 0 100 280 C5B12B
                JLT     revlimiter_engage_resume_check_if_ram11a_bit6_set             ; 1940 0 100 280 CA06
                LB      A, 09dh                ; 1942 0 100 280 F59D
                CMPB    A, #010h               ; 1944 0 100 280 C610
                JGE     doubleup_limiter_gate             ; 1946 0 100 280 CD1E
revlimiter_engage_resume_check_if_ram11a_bit6_set:     JBS     off(0011ah).6, vaccut_rpm_check ; 1948 0 100 280 EE1A13
                MB      C, 0b0h.2              ; 194B 0 100 280 C5B02A
                JLT     vaccut_rpm_check             ; 194E 0 100 280 CA0E
                CMPB    0d1h, #02bh            ; 1950 0 100 280 C5D1C02B
                JGE     doubleup_limiter_gate             ; 1954 0 100 280 CD10
                MOV     X1, #revlimiter_engage_resume_check_tbl          ; 1956 0 100 280 60EC6D
                LB      A, 0d1h                ; 1959 0 100 280 F5D1
                VCAL    1                      ; 195B 0 100 280 11
                SJ      vaccut_rpm_check_cmp_acc             ; 195C 0 100 280 CB02
vaccut_rpm_check:     LB      A, #080h               ; 195E 0 100 280 7780
vaccut_rpm_check_cmp_acc:     CMPB    A, off(00133h)         ; 1960 0 100 280 C733
                JGE     ofc_enable_check_if_ram12e_bit0_set             ; 1962 0 100 280 CD58
                SJ      revlimiter_fuelcut_set             ; 1964 0 100 280 CB46
doubleup_limiter_gate:     MOV     DP, #00228h            ; 1966 0 100 280 622802
                L       A, #00218h             ; 1969 1 100 280 671802
                MB      C, P4.0                ; 196C 1 100 280 C52C28
                JLT     doubleup_limiter_cont             ; 196F 1 100 280 CA08
                JBS     off(0011bh).7, doubleup_limiter_cont ; 1971 1 100 280 EF1B05
                MOV     DP, off(001a6h)        ; 1974 1 100 280 B4A67A
                L       A, off(001a4h)         ; 1977 1 100 280 E4A4
doubleup_limiter_cont:     JBR     off(00124h).5, ignition_cut_mode_check ; 1979 1 100 280 DD2401
                L       A, DP                  ; 197C 1 100 280 42
ignition_cut_mode_check:     CMP     0c4h, A                ; 197D 1 100 280 B5C4C1
                JLT     revlimiter_fuelcut_set             ; 1980 1 100 280 CA2A
                JBS     off(00121h).7, fuelcuttrack_store ; 1982 1 100 280 EF213D
                JBS     off(0011eh).2, ignition_cut_mode_check_load_imm ; 1985 1 100 280 EA1E06
                LCB     A, ignition_cut_mode_check_tbl            ; 1988 1 100 280 909DEF60
                JEQ     fuelcut_extra_gate             ; 198C 1 100 280 C922
ignition_cut_mode_check_load_imm:     LB      A, #0c8h               ; 198E 0 100 280 77C8
                CMPB    A, off(00133h)         ; 1990 0 100 280 C733
                JGE     ignition_cut_mode_check_load_imm_2             ; 1992 0 100 280 CD0A
                CMPB    0cch, #0b9h            ; 1994 0 100 280 C5CCC0B9
                JGE     ignition_cut_mode_check_load_ram1dd             ; 1998 0 100 280 CD0A
                LB      A, off(001deh)         ; 199A 0 100 280 F4DE
                JNE     revlimiter_fuelcut_set             ; 199C 0 100 280 CE0E
ignition_cut_mode_check_load_imm_2:     LB      A, #028h               ; 199E 0 100 280 7728
                STB     A, off(001ddh)         ; 19A0 0 100 280 D4DD
                SJ      fuelcut_extra_gate             ; 19A2 0 100 280 CB0C
ignition_cut_mode_check_load_ram1dd:     LB      A, off(001ddh)         ; 19A4 0 100 280 F4DD
                JNE     fuelcut_extra_gate             ; 19A6 0 100 280 CE08
                LB      A, #002h               ; 19A8 0 100 280 7702
                STB     A, off(001deh)         ; 19AA 0 100 280 D4DE
revlimiter_fuelcut_set:     SB      PSWL.5                 ; 19AC 0 100 280 A31D
                SJ      fuelcut_result_common             ; 19AE 0 100 280 CB6E
fuelcut_extra_gate:     JBS     off(00124h).2, ofc_enable_check ; 19B0 1 100 280 EA2403
                JBR     off(00122h).0, ofc_enable_check_if_ram12e_bit0_set ; 19B3 1 100 280 D82206
ofc_enable_check:     JBR     off(00120h).2, ofc_enable_check_if_ram12e_bit3_set ; 19B6 1 100 280 DA2012
                RB      off(0012eh).1          ; 19B9 1 100 280 C42E09
ofc_enable_check_if_ram12e_bit0_set:     JBS     off(0012eh).0, fuelcuttrack_store ; 19BC 1 100 280 E82E03
                JBS     off(0012eh).2, fuelcut_tps_recheck ; 19BF 1 100 280 EA2E11
fuelcuttrack_store:     LB      A, #014h               ; 19C2 0 100 280 7714
                STB     A, off(001d7h)         ; 19C4 0 100 280 D4D7
fuelcut_clear_active_flag:     RB      off(00124h).2          ; 19C6 0 100 280 C4240A
                SJ      fuelcut_output_flags             ; 19C9 0 100 280 CB56
ofc_enable_check_if_ram12e_bit3_set:     JBS     off(0012eh).3, fuelcut_tps_recheck ; 19CB 1 100 280 EB2E05
                SB      off(0012eh).1          ; 19CE 1 100 280 C42E19
                SJ      fuelcuttrack_store             ; 19D1 1 100 280 CBEF
fuelcut_tps_recheck:     JBS     off(00124h).2, fuelcut_finalize_ign_flag ; 19D3 1 100 280 EA2414
                LB      A, 0c1h                ; 19D6 0 100 280 F5C1
                CMPB    A, #060h               ; 19D8 0 100 280 C660
                JBS     off(0011eh).3, to_fuelcut_clear_active_flag ; 19DA 0 100 280 EB1E02
                CMPB    A, #010h               ; 19DD 0 100 280 C610
to_fuelcut_clear_active_flag:     JGE     fuelcuttrack_store             ; 19DF 0 100 280 CDE1
                LB      A, off(001d7h)         ; 19E1 0 100 280 F4D7
                JEQ     fuelcut_finalize_ign_flag             ; 19E3 0 100 280 C905
                SB      off(0012bh).7          ; 19E5 0 100 280 C42B1F
                SJ      fuelcut_clear_active_flag             ; 19E8 0 100 280 CBDC
fuelcut_finalize_ign_flag:     JBR     off(0011eh).3, fuelcut_finalize_ign_flag_if_ram12e_bit5_set ; 19EA 1 100 280 DB1E26
                LB      A, 0cch                ; 19ED 0 100 280 F5CC
                CMPB    A, #064h               ; 19EF 0 100 280 C664
                JGE     fuelcut_finalize_ign_flag_if_ram12e_bit5_set             ; 19F1 0 100 280 CD20
                LB      A, 0cdh                ; 19F3 0 100 280 F5CD
                SUBB    A, 0cch                ; 19F5 0 100 280 C5CCA2
                JLT     fuelcut_finalize_ign_flag_if_ram119_bit5_set             ; 19F8 0 100 280 CA04
                CMPB    A, #004h               ; 19FA 0 100 280 C604
                JGE     fuelcut_finalize_ign_flag_set_ram12e_bit5             ; 19FC 0 100 280 CD12
fuelcut_finalize_ign_flag_if_ram119_bit5_set:     JBS     off(00119h).5, fuelcut_finalize_ign_flag_if_ram12e_bit5_set ; 19FE 0 100 280 ED1912
                JBS     off(00123h).7, fuelcut_finalize_ign_flag_if_ram12e_bit5_set ; 1A01 0 100 280 EF230F
                L       A, 0c8h                ; 1A04 1 100 280 E5C8
                CMP     A, #00100h             ; 1A06 1 100 280 C60001
                JLT     fuelcut_finalize_ign_flag_if_ram12e_bit5_set             ; 1A09 1 100 280 CA08
                SB      off(0012eh).6          ; 1A0B 1 100 280 C42E1E
                SJ      fuelcut_finalize_ign_flag_if_ram12e_bit5_set             ; 1A0E 1 100 280 CB03
fuelcut_finalize_ign_flag_set_ram12e_bit5:     SB      off(0012eh).5          ; 1A10 0 100 280 C42E1D
fuelcut_finalize_ign_flag_if_ram12e_bit5_set:     JBS     off(0012eh).5, fuelcut_clear_active_flag ; 1A13 1 100 280 ED2EB0
                JBS     off(0012eh).6, fuelcut_clear_active_flag ; 1A16 1 100 280 EE2EAD
                JBS     off(0012ch).3, fuelcut_clear_active_flag ; 1A19 1 100 280 EB2CAA
                SB      PSWL.4                 ; 1A1C 1 100 280 A31C
fuelcut_result_common:     SB      off(00124h).2          ; 1A1E 0 100 280 C4241A
fuelcut_output_flags:     MB      C, PSWL.5              ; 1A21 0 100 280 A32D
                MB      off(00124h).5, C       ; 1A23 0 100 280 C4243D
                MB      C, PSWL.4              ; 1A26 0 100 280 A32C
                MB      off(00124h).4, C       ; 1A28 0 100 280 C4243C
                RC                             ; 1A2B 0 100 280 95
                RB      off(0012bh).7          ; 1A2C 0 100 280 C42B0F
                JBS     off(00124h).2, fuelcut_output_flags_set_carry ; 1A2F 0 100 280 EA2402
                JEQ     fuelcut_output_flags_store_carry_ram124_bit3             ; 1A32 0 100 280 C901
fuelcut_output_flags_set_carry:     SC                             ; 1A34 0 100 280 85
fuelcut_output_flags_store_carry_ram124_bit3:     MB      off(00124h).3, C       ; 1A35 0 100 280 C4243B
                LB      A, 0dch                ; 1A38 0 100 280 F5DC
                CMPB    A, #082h               ; 1A3A 0 100 280 C682
                JBS     off(0012bh).4, tps_hysteresis_reentry ; 1A3C 0 100 280 EC2B02
                CMPB    A, #07ah               ; 1A3F 0 100 280 C67A
tps_hysteresis_reentry:     MB      off(0012bh).4, C       ; 1A41 0 100 280 C42B3C
                ANDB    PSWL, #0cfh            ; 1A44 0 100 280 A3D0CF
                MOVB    r2, #00ah              ; 1A47 0 100 280 9A0A
                JBS     off(00121h).7, postig_result_zero_common ; 1A49 0 100 280 EF2166
                JBS     off(00125h).4, tps_hysteresis_reentry_load_ram132 ; 1A4C 0 100 280 EC2559
                JBS     off(0012ch).3, postig_result_zero_common ; 1A4F 0 100 280 EB2C60
                JBS     off(00125h).5, postig_result_zero_common ; 1A52 0 100 280 ED255D
                JBR     off(00122h).2, postig_result_default ; 1A55 0 100 280 DA225D
                JBR     off(00122h).0, postig_result_default ; 1A58 0 100 280 D8225A
                JBR     off(0011eh).3, postig_gate_chain2 ; 1A5B 0 100 280 DB1E03
                JBS     off(00119h).5, postig_result_default ; 1A5E 0 100 280 ED1954
postig_gate_chain2:     JBS     off(00120h).4, postig_result_default ; 1A61 0 100 280 EC2051
                LB      A, off(001a8h)         ; 1A64 0 100 280 F4A8
                MOVB    r0, #040h              ; 1A66 0 100 280 9840
                JBS     off(0012bh).5, postig_threshold_check1 ; 1A68 0 100 280 ED2B04
                LB      A, off(001a9h)         ; 1A6B 0 100 280 F4A9
                MOVB    r0, #05ah              ; 1A6D 0 100 280 985A
postig_threshold_check1:     JBR     off(00123h).0, postig_threshold_check2 ; 1A6F 0 100 280 D82304
                CMPB    A, r0                  ; 1A72 0 100 280 48
                JGE     postig_threshold_check2             ; 1A73 0 100 280 CD01
                LB      A, r0                  ; 1A75 0 100 280 78
postig_threshold_check2:     JBR     off(0011fh).6, postig_rpm_compare ; 1A76 0 100 280 DE1F12
                MOVB    r0, #032h              ; 1A79 0 100 280 9832
                JBS     off(0012bh).5, postig_threshold_check3 ; 1A7B 0 100 280 ED2B02
                MOVB    r0, #050h              ; 1A7E 0 100 280 9850
postig_threshold_check3:     CMPB    A, r0                  ; 1A80 0 100 280 48
                JGE     postig_rpm_compare             ; 1A81 0 100 280 CD08
                JBS     off(0012bh).4, postig_rpm_compare ; 1A83 0 100 280 EC2B05
                SUBB    A, #00ah               ; 1A86 0 100 280 A60A
                JGE     postig_rpm_compare             ; 1A88 0 100 280 CD01
                CLRB    A                      ; 1A8A 0 100 280 FA
postig_rpm_compare:     CMPB    A, off(00133h)         ; 1A8B 0 100 280 C733
                JGT     postig_result_zero_common             ; 1A8D 0 100 280 C823
                CMPB    0d9h, #034h            ; 1A8F 0 100 280 C5D9C034
                JGE     postig_result_high             ; 1A93 0 100 280 CD08
                JBR     off(0011eh).3, postig_result_high ; 1A95 0 100 280 DB1E05
                LB      A, off(001d6h)         ; 1A98 0 100 280 F4D6
                STB     A, r2                  ; 1A9A 0 100 280 8A
                JNE     postig_result_zero_common             ; 1A9B 0 100 280 CE15
postig_result_high:     LB      A, #0dah               ; 1A9D 0 100 280 77DA
                JBS     off(0011eh).3, to_set_pswl4_flag_b ; 1A9F 0 100 280 EB1E02
                LB      A, #0f3h               ; 1AA2 0 100 280 77F3
to_set_pswl4_flag_b:     SB      PSWL.5                 ; 1AA4 0 100 280 A31D
                SJ      set_pswl4_flag_b             ; 1AA6 0 100 280 CB33
tps_hysteresis_reentry_load_ram132:     LB      A, off(00132h)         ; 1AA8 0 100 280 F432
                MOV     X1, #tps_hysteresis_reentry_tbl          ; 1AAA 0 100 280 60DC66
                CAL     table_interp_lookup             ; 1AAD 0 100 280 323958
                SJ      set_pswl4_flag_b             ; 1AB0 0 100 280 CB29
postig_result_zero_common:     CLRB    A                      ; 1AB2 0 100 280 FA
                SJ      ignmap2_flags_store             ; 1AB3 0 100 280 CB28
postig_result_default:     LB      A, #080h               ; 1AB5 0 100 280 7780
                MOV     X1, #tbl_ignmap2_hi          ; 1AB7 0 100 280 608364
                JBR     off(0012bh).5, ignmap2_rpm_gate ; 1ABA 0 100 280 DD2B05
                LB      A, #073h               ; 1ABD 0 100 280 7773
                MOV     X1, #tbl_ignmap2_lo          ; 1ABF 0 100 280 607764
ignmap2_rpm_gate:     CMPB    A, off(00133h)         ; 1AC2 0 100 280 C733
                JGE     postig_result_zero_common             ; 1AC4 0 100 280 CDEC
                LB      A, off(00133h)         ; 1AC6 0 100 280 F433
                CAL     table_interp_lookup             ; 1AC8 0 100 280 323958
                ADDB    A, #002h               ; 1ACB 0 100 280 8602
                JGE     ignmap2_result_check             ; 1ACD 0 100 280 CD02
                LB      A, #0ffh               ; 1ACF 0 100 280 77FF
ignmap2_result_check:     SUBB    A, off(001ach)         ; 1AD1 0 100 280 A7AC
                JLT     postig_result_zero_common             ; 1AD3 0 100 280 CADD
                CMPB    A, off(00132h)         ; 1AD5 0 100 280 C732
                JLE     postig_result_zero_common             ; 1AD7 0 100 280 CFD9
                LB      A, #0f3h               ; 1AD9 0 100 280 77F3
set_pswl4_flag_b:     SB      PSWL.4                 ; 1ADB 0 100 280 A31C
ignmap2_flags_store:     STB     A, off(00166h)         ; 1ADD 0 100 280 D466
                MB      C, PSWL.4              ; 1ADF 0 100 280 A32C
                MB      off(0012bh).5, C       ; 1AE1 0 100 280 C42B3D
                MB      C, PSWL.5              ; 1AE4 0 100 280 A32D
                MB      off(00126h).1, C       ; 1AE6 0 100 280 C42639
                MOVB    off(001d6h), r2        ; 1AE9 0 100 280 227CD6
                LB      A, #0cdh               ; 1AEC 0 100 280 77CD
                JBS     off(0012dh).0, ignmap2_flags_store_cmp_acc ; 1AEE 0 100 280 E82D02
                LB      A, #0d0h               ; 1AF1 0 100 280 77D0
ignmap2_flags_store_cmp_acc:     CMPB    A, off(00133h)         ; 1AF3 0 100 280 C733
                MB      off(0012dh).0, C       ; 1AF5 0 100 280 C42D38
                LB      A, #012h               ; 1AF8 0 100 280 7712
                JBS     off(00124h).6, knock_window_check ; 1AFA 0 100 280 EE2402
                LB      A, #010h               ; 1AFD 0 100 280 7710
knock_window_check:     CMPB    0c5h, A                ; 1AFF 0 100 280 C5C5C1
                MB      off(00124h).6, C       ; 1B02 0 100 280 C4243E
                JGE     knock_window_gate_common             ; 1B05 0 100 280 CD0E
                RC                             ; 1B07 0 100 280 95
                JBS     off(00125h).5, knock_window_gate_common ; 1B08 0 100 280 ED250A
                JBS     off(0012dh).0, knock_window_gate_common ; 1B0B 0 100 280 E82D07
                JBS     off(0012bh).5, knock_window_gate_common ; 1B0E 0 100 280 ED2B04
                JBS     off(00124h).2, knock_window_gate_common ; 1B11 0 100 280 EA2401
                SC                             ; 1B14 0 100 280 85
knock_window_gate_common:     MB      off(00125h).2, C       ; 1B15 0 100 280 C4253A
                LB      A, #0bah               ; 1B18 0 100 280 77BA
                JBS     off(00125h).3, rpm_gate_final_check ; 1B1A 0 100 280 EB2502
                LB      A, #0c0h               ; 1B1D 0 100 280 77C0
rpm_gate_final_check:     CMPB    A, off(00133h)         ; 1B1F 0 100 280 C733
                MB      off(00125h).3, C       ; 1B21 0 100 280 C4253B
                JBR     off(00120h).0, o2_closedloop_read_and_select ; 1B24 0 100 280 D82004
                MOVB    off(001dbh), #019h     ; 1B27 0 100 280 C4DB9819
o2_closedloop_read_and_select:     LB      A, #01fh               ; 1B2B 0 100 280 771F
                MOVB    r0, #01fh              ; 1B2D 0 100 280 981F
                CMPB    0bch, #0dbh            ; 1B2F 0 100 280 C5BCC0DB
                JLT     o2_closedloop_read_and_select_if_ram11e_bit0_set             ; 1B33 0 100 280 CA04
                LB      A, #01fh               ; 1B35 0 100 280 771F
                MOVB    r0, #01fh              ; 1B37 0 100 280 981F
o2_closedloop_read_and_select_if_ram11e_bit0_set:     JBS     off(0011eh).0, o2_closedloop_read_and_select_cmp_acc ; 1B39 0 100 280 E81E01
                LB      A, r0                  ; 1B3C 0 100 280 78
o2_closedloop_read_and_select_cmp_acc:     CMPB    A, 0dah                ; 1B3D 0 100 280 C5DAC2
                RB      off(0012dh).2          ; 1B40 0 100 280 C42D0A
                MB      off(0012dh).2, C       ; 1B43 0 100 280 C42D3A
                JEQ     o2_closedloop_delay_dec             ; 1B46 0 100 280 C903
                XORB    PSWH, #080h            ; 1B48 0 100 280 A2F080
o2_closedloop_delay_dec:     MB      off(0012dh).1, C       ; 1B4B 0 100 280 C42D39
                L       A, off(001b8h)         ; 1B4E 1 100 280 E4B8
                JEQ     o2_closedloop_gate1             ; 1B50 1 100 280 C903
                DEC     off(001b8h)            ; 1B52 1 100 280 B4B817
o2_closedloop_gate1:     JBR     off(00121h).3, o2_trim_gate_common ; 1B55 1 100 280 DB216C
                JBS     off(00121h).4, o2_trim_gate_common ; 1B58 1 100 280 EC2169
                JBS     off(00125h).4, o2_trim_gate_common ; 1B5B 1 100 280 EC2566
                MOV     DP, #003abh            ; 1B5E 1 100 280 62AB03
                LB      A, [DP]                ; 1B61 0 100 280 F2
                CMPB    A, #031h               ; 1B62 0 100 280 C631
                JEQ     o2_trim_gate_common             ; 1B64 0 100 280 C95E
                CMPB    0f2h, #00ch            ; 1B66 0 100 280 C5F2C00C
                JLT     o2_trim_gate_common             ; 1B6A 0 100 280 CA58
                J       o2_closedloop_gate1_load_carry_stk             ; 1B6C 0 100 280 035F79
                DW  00000h           ; 1B6F
o2_closedloop_gate1_if_ne_goto_o2_trim_gate_common:     JNE     o2_trim_gate_common             ; 1B71 1 100 280 CE51
                L       A, off(0011ch)         ; 1B73 1 100 280 E41C
                AND     A, #01420h             ; 1B75 1 100 280 D62014
                JNE     o2_trim_gate_common             ; 1B78 1 100 280 CE4A
                CMPB    0d9h, #028h            ; 1B7A 1 100 280 C5D9C028
                JGE     o2_trim_gate_common             ; 1B7E 1 100 280 CD44
                LB      A, 0dah                ; 1B80 0 100 280 F5DA
                STB     A, r0                  ; 1B82 0 100 280 88
                JBS     off(00124h).4, o2_store_prev_reading ; 1B83 0 100 280 EC2423
                CMPB    off(00133h), #062h     ; 1B86 0 100 280 C433C062
                JGE     o2_gate_tps_check             ; 1B8A 0 100 280 CD04
                MOVB    off(001e0h), #032h     ; 1B8C 0 100 280 C4E09832
o2_gate_tps_check:     LB      A, off(001e0h)         ; 1B90 0 100 280 F4E0
                JNE     o2_gate_dp_set             ; 1B92 0 100 280 CE03
                SB      off(0012dh).3          ; 1B94 0 100 280 C42D1B
o2_gate_dp_set:     RC                             ; 1B97 0 100 280 95
                JBS     off(00124h).5, dtc01_o2_latch ; 1B98 0 100 280 ED2431
                JBR     off(00125h).5, dtc01_o2_latch ; 1B9B 0 100 280 DD252E
                LB      A, #047h               ; 1B9E 0 100 280 7747
                CMPB    A, off(00164h)         ; 1BA0 0 100 280 C764
                JGE     dtc01_o2_latch             ; 1BA2 0 100 280 CD28
                CMPB    r0, #003h              ; 1BA4 0 100 280 20C003
                SJ      dtc01_o2_latch             ; 1BA7 0 100 280 CB23
o2_store_prev_reading:     JBS     off(0012eh).4, o2_narrowband_check ; 1BA9 0 100 280 EC2E03
                LB      A, r0                  ; 1BAC 0 100 280 78
                STB     A, off(001bah)         ; 1BAD 0 100 280 D4BA
o2_narrowband_check:     JBR     off(0012dh).3, o2_trim_gate_reset_dp ; 1BAF 0 100 280 DB2D15
                LB      A, #09ah               ; 1BB2 0 100 280 779A
                CMPB    A, r0                  ; 1BB4 0 100 280 48
                JGE     o2_trim_gate_common             ; 1BB5 0 100 280 CD0D
                JBS     off(00120h).2, o2_trim_gate_common ; 1BB7 0 100 280 EA200A
                LB      A, off(001bah)         ; 1BBA 0 100 280 F4BA
                SUBB    A, r0                  ; 1BBC 0 100 280 28
                JGE     o2_delta_magnitude_check             ; 1BBD 0 100 280 CD01
                VCAL    6                      ; 1BBF 0 100 280 16
o2_delta_magnitude_check:     CMPB    A, #002h               ; 1BC0 0 100 280 C602
                JLT     dtc01_o2_latch             ; 1BC2 0 100 280 CA08
o2_trim_gate_common:     RB      off(0012dh).3          ; 1BC4 1 100 280 C42D0B
o2_trim_gate_reset_dp:     MOVB    off(001e0h), #032h     ; 1BC7 1 100 280 C4E09832
                RC                             ; 1BCB 1 100 280 95
dtc01_o2_latch:     MB      0b0h.4, C              ; 1BCC 1 100 280 C5B03C
                MOVB    r0, #032h              ; 1BCF 1 100 280 9832
                JBR     off(00121h).3, o2_trim_tps_mode_check_clear_ram17e ; 1BD1 1 100 280 DB216A
                JBS     off(00125h).4, o2_trim_tps_mode_check_clear_ram17e ; 1BD4 1 100 280 EC2567
                MOV     er1, #0828fh           ; 1BD7 1 100 280 45988F82
                JBR     off(0011eh).2, o2_trim_table_ptr_load ; 1BDB 1 100 280 DA1E0B
                MB      C, 0b8h.5              ; 1BDE 1 100 280 C5B82D
                JGE     o2_trim_table_ptr_load             ; 1BE1 1 100 280 CD06
                JBR     off(0012dh).1, o2_trim_table_ptr_alt ; 1BE3 1 100 280 D92D19
                RB      0b8h.5                 ; 1BE6 1 100 280 C5B80D
o2_trim_table_ptr_load:     L       A, #0828fh             ; 1BE9 1 100 280 678F82
                JBS     off(0011ah).2, o2_trim_clear_gate1 ; 1BEC 1 100 280 EA1A58
                JBS     off(0011ah).4, o2_trim_clear_gate1 ; 1BEF 1 100 280 EC1A55
                J       o2_trim_table_ptr_load_load_carry_stk             ; 1BF2 1 100 280 036F79
                DW  00000h           ; 1BF5
o2_trim_table_ptr_load_if_ne_goto_o2_trim_table_ptr_alt:     JNE     o2_trim_table_ptr_alt             ; 1BF7 1 100 280 CE06
                JBS     off(0011dh).2, o2_trim_table_ptr_alt ; 1BF9 1 100 280 EA1D03
                JBR     off(0011dh).4, o2_trim_gate3 ; 1BFC 1 100 280 DC1D03
o2_trim_table_ptr_alt:     L       A, er1                 ; 1BFF 1 100 280 35
                SJ      o2_trim_clear_gate1             ; 1C00 1 100 280 CB45
o2_trim_gate3:     JBR     off(00121h).1, o2_trim_tps_mode_check_clear_ram17e ; 1C02 1 100 280 D92139
                JBS     off(00125h).5, o2_trim_tps_mode_check_clear_ram17e ; 1C05 1 100 280 ED2536
                JBS     off(00121h).0, o2_trim_tps_mode_check ; 1C08 1 100 280 E82112
                CLRB    off(0017eh)            ; 1C0B 1 100 280 C47E15
                MOVB    off(001d3h), r0        ; 1C0E 1 100 280 207CD3
                MOV     DP, #00304h            ; 1C11 1 100 280 620403
                JBR     off(00120h).0, o2_trim_dp_table_read ; 1C14 1 100 280 D82003
                MOV     DP, #00300h            ; 1C17 1 100 280 620003
o2_trim_dp_table_read:     L       A, [DP]                ; 1C1A 1 100 280 E2
                SJ      o2_trim_clear_gate1             ; 1C1B 1 100 280 CB2A
o2_trim_tps_mode_check:     JBS     off(0012dh).0, o2_trim_tps_mode_check_clear_ram17e ; 1C1D 1 100 280 E82D1E
                JBR     off(00124h).6, o2_trim_alt_path_check_load_ram17e ; 1C20 1 100 280 DE240C
                JBR     off(00124h).2, o2_trim_alt_path_check ; 1C23 1 100 280 DA2406
                MOVB    off(001e4h), #00ah     ; 1C26 1 100 280 C4E4980A
                SJ      o2_trim_alt_path_check_load_ram17e             ; 1C2A 1 100 280 CB03
o2_trim_alt_path_check:     JBR     off(0012bh).5, o2_trim_alt_path_check_goto_7988 ; 1C2C 1 100 280 DD2B21
o2_trim_alt_path_check_load_ram17e:     MOVB    off(0017eh), #004h     ; 1C2F 1 100 280 C47E9804
                LB      A, off(001d3h)         ; 1C33 0 100 280 F4D3
                JEQ     o2_trim_default_target             ; 1C35 0 100 280 C90D
                L       A, off(0015ah)         ; 1C37 1 100 280 E45A
                J       o2_trim_alt_path_check_set_stk             ; 1C39 1 100 280 037F79
o2_trim_alt_path_check_goto_o2_trim_clear_gate0_and_retu:     SJ      o2_trim_clear_gate0_and_return             ; 1C3C 1 100 280 CB0C
o2_trim_tps_mode_check_clear_ram17e:     CLRB    off(0017eh)            ; 1C3E 1 100 280 C47E15
                MOVB    off(001d3h), r0        ; 1C41 1 100 280 207CD3
o2_trim_default_target:     L       A, #08000h             ; 1C44 1 100 280 670080
o2_trim_clear_gate1:     RB      off(00125h).1          ; 1C47 1 100 280 C42509
o2_trim_clear_gate0_and_return:     RB      off(00125h).0          ; 1C4A 1 100 280 C42508
                J       injtimer_finalize_start             ; 1C4D 1 100 280 03521E
o2_trim_alt_path_check_goto_7988:     J       o2_trim_alt_path_check_set_stk_2             ; 1C50 1 100 280 038879
o2_trim_alt_path_check_load_ram1d3:     MOVB    off(001d3h), r0        ; 1C53 1 100 280 207CD3
                MB      C, off(0012dh).5       ; 1C56 1 100 280 C42D2D
                MB      PSWL.4, C              ; 1C59 1 100 280 A33C
                LB      A, #052h               ; 1C5B 0 100 280 7752
                JLT     o2_trim_step_threshold             ; 1C5D 0 100 280 CA02
                LB      A, #064h               ; 1C5F 0 100 280 7764
o2_trim_step_threshold:     CMPB    A, off(00132h)         ; 1C61 0 100 280 C732
                MB      off(0012dh).5, C       ; 1C63 0 100 280 C42D3D
                MOVB    r6, #004h              ; 1C66 0 100 280 9E04
                MOVB    r7, #004h              ; 1C68 0 100 280 9F04
                CMPB    0d9h, #04fh            ; 1C6A 0 100 280 C5D9C04F
                JLT     o2_trim_step_threshold_load_er3             ; 1C6E 0 100 280 CA0A
                CMPB    0d9h, #0a2h            ; 1C70 0 100 280 C5D9C0A2
                JGE     o2_trim_step_threshold_load_er3             ; 1C74 0 100 280 CD04
                MOVB    r6, #004h              ; 1C76 0 100 280 9E04
                MOVB    r7, #004h              ; 1C78 0 100 280 9F04
o2_trim_step_threshold_load_er3:     L       A, er3                 ; 1C7A 1 100 280 37
                NOP                            ; 1C7B 1 100 280 00
                NOP                            ; 1C7C 1 100 280 00
                SB      off(00125h).0          ; 1C7D 1 100 280 C42518
                JEQ     o2_trim_dp300_read             ; 1C80 1 100 280 C912
                JBS     off(00120h).3, o2_trim_alt_gate ; 1C82 1 100 280 EB2045
                JBR     off(00120h).2, o2_trim_dp304_common ; 1C85 1 100 280 DA2051
                ST      A, off(0017ch)         ; 1C88 1 100 280 D47C
                JBR     off(00120h).1, o2_trim_dp304_calc ; 1C8A 1 100 280 D92011
                MOV     DP, #00308h            ; 1C8D 1 100 280 620803
                MOV     er1, [DP]              ; 1C90 1 100 280 B249
                SJ      o2_trim_step_finalize2             ; 1C92 1 100 280 CB32
o2_trim_dp300_read:     ST      A, off(0017ch)         ; 1C94 1 100 280 D47C
                MOV     DP, #00300h            ; 1C96 1 100 280 620003
                MOV     er1, [DP]              ; 1C99 1 100 280 B249
                JBS     off(00120h).0, o2_trim_step_finalize2 ; 1C9B 1 100 280 E82028
o2_trim_dp304_calc:     MOV     DP, #00304h            ; 1C9E 1 100 280 620403
                MOV     er0, [DP]              ; 1CA1 1 100 280 B248
                L       A, #08000h             ; 1CA3 1 100 280 670080
                MOV     er1, #08000h           ; 1CA6 1 100 280 45980080
                JBS     off(0011eh).3, cmp_0d9_028_load_er1 ; 1CAA 1 100 280 EB1E07
                L       A, #08000h             ; 1CAD 1 100 280 670080
                MOV     er1, #08000h           ; 1CB0 1 100 280 45980080
cmp_0d9_028_load_er1:     CMPB    0d9h, #057h            ; 1CB4 1 100 280 C5D9C057
                JLT     o2_trim_mul_apply             ; 1CB8 1 100 280 CA01
                L       A, er1                 ; 1CBA 1 100 280 35
o2_trim_mul_apply:     MUL                            ; 1CBB 1 100 280 9035
                SLL     A                      ; 1CBD 1 100 280 53
                ROL     er1                    ; 1CBE 1 100 280 45B7
                JGE     o2_trim_step_finalize2             ; 1CC0 1 100 280 CD04
                MOV     er1, #0ffffh           ; 1CC2 1 100 280 4598FFFF
o2_trim_step_finalize2:     SB      PSWL.5                 ; 1CC6 1 100 280 A31D
                SJ      o2_trim_result_check             ; 1CC8 1 100 280 CB19
o2_trim_alt_gate:     MB      C, PSWL.4              ; 1CCA 1 100 280 A32C
                JLT     o2_trim_dp304_common             ; 1CCC 1 100 280 CA0B
                JBR     off(0012dh).5, o2_trim_dp304_common ; 1CCE 1 100 280 DD2D08
                MOV     DP, #00304h            ; 1CD1 1 100 280 620403
                CMP     [DP], off(0015ah)      ; 1CD4 1 100 280 B2C35A
                JGT     o2_trim_dp304_calc             ; 1CD7 1 100 280 C8C5
o2_trim_dp304_common:     MOV     er1, off(0015ah)       ; 1CD9 1 100 280 B45A49
                RB      PSWL.5                 ; 1CDC 1 100 280 A30D
                JBR     off(0012dh).1, o2_trim_result_check ; 1CDE 1 100 280 D92D02
                ST      A, off(0017ch)         ; 1CE1 1 100 280 D47C
o2_trim_result_check:     MB      C, PSWL.5              ; 1CE3 1 100 280 A32D
                JLT     o2_trim_er3_decrement             ; 1CE5 1 100 280 CA03
                JBS     off(0012dh).1, o2_trim_result_check_nop_acc ; 1CE7 1 100 280 E92D19
o2_trim_er3_decrement:     L       A, er3                 ; 1CEA 1 100 280 37
                LB      A, ACC                 ; 1CEB 0 100 280 F506
                MOV     DP, #0017ch            ; 1CED 0 100 280 627C01
                JBR     off(0012dh).2, o2_trim_er3_decrement_decb_dp_ind ; 1CF0 0 100 280 DA2D08
                LB      A, ACCH                ; 1CF3 0 100 280 F507
                NOP                            ; 1CF5 0 100 280 00
                NOP                            ; 1CF6 0 100 280 00
                NOP                            ; 1CF7 0 100 280 00
                NOP                            ; 1CF8 0 100 280 00
                NOP                            ; 1CF9 0 100 280 00
                INC     DP                     ; 1CFA 0 100 280 72
o2_trim_er3_decrement_decb_dp_ind:     DECB    [DP]                   ; 1CFB 0 100 280 C217
                JEQ     o2_trim_er3_decrement_store_dp_ind             ; 1CFD 0 100 280 C903
                J       o2trim_gate_common2             ; 1CFF 0 100 280 03511E
o2_trim_er3_decrement_store_dp_ind:     STB     A, [DP]                ; 1D02 0 100 280 D2
o2_trim_result_check_nop_acc:     NOP                            ; 1D03 1 100 280 00
                NOP                            ; 1D04 1 100 280 00
                NOP                            ; 1D05 1 100 280 00
                NOP                            ; 1D06 1 100 280 00
                NOP                            ; 1D07 1 100 280 00
                NOP                            ; 1D08 1 100 280 00
                JBS     off(00120h).0, o2_trim_bank_index_alt ; 1D09 1 100 280 E8201F
                LB      A, (00296h-00280h)[USP] ; 1D0C 0 100 280 F316
                CMPB    A, off(00133h)         ; 1D0E 0 100 280 C733
                LB      A, #004h               ; 1D10 0 100 280 7704
                JLT     o2_trim_flag_store2             ; 1D12 0 100 280 CA01
                CLRB    A                      ; 1D14 0 100 280 FA
o2_trim_flag_store2:     STB     A, off(0017eh)         ; 1D15 0 100 280 D47E
o2_trim_bank_index_calc:     CLR     X1                     ; 1D17 0 100 280 9015
                JBS     off(0012fh).0, o2_trim_rate_table_select ; 1D19 0 100 280 E82F1E
                INC     X1                     ; 1D1C 0 100 280 70
                LB      A, off(00133h)         ; 1D1D 0 100 280 F433
                CMPB    A, #073h               ; 1D1F 0 100 280 C673
                JGE     o2_trim_rate_table_select             ; 1D21 0 100 280 CD17
                INC     X1                     ; 1D23 0 100 280 70
                CMPB    A, #040h               ; 1D24 0 100 280 C640
                JGE     o2_trim_rate_table_select             ; 1D26 0 100 280 CD12
                INC     X1                     ; 1D28 0 100 280 70
                SJ      o2_trim_rate_table_select             ; 1D29 0 100 280 CB0F
o2_trim_bank_index_alt:     MOV     X1, #00004h            ; 1D2B 1 100 280 600400
                LB      A, off(0017eh)         ; 1D2E 0 100 280 F47E
                JEQ     o2_trim_rate_table_select             ; 1D30 0 100 280 C908
                JBR     off(0012dh).1, o2_trim_bank_index_calc ; 1D32 0 100 280 D92DE2
                DECB    off(0017eh)            ; 1D35 0 100 280 C47E17
                JNE     o2_trim_bank_index_calc             ; 1D38 0 100 280 CEDD
o2_trim_rate_table_select:     SLL     X1                     ; 1D3A 0 100 280 90D7
                MOV     DP, #CloseLoopRate          ; 1D3C 0 100 280 62CF61
                MB      C, PSWL.5              ; 1D3F 0 100 280 A32D
                JLT     o2_trim_table_offset_calc             ; 1D41 0 100 280 CA0D
                JBR     off(0012dh).1, o2_trim_table_offset_calc ; 1D43 0 100 280 D92D0A
                MOV     DP, #CloseLoopGoose          ; 1D46 0 100 280 62E761
                JBS     off(0012dh).2, o2_trim_table_offset_calc ; 1D49 0 100 280 EA2D04
                LB      A, off(001d4h)         ; 1D4C 0 100 280 F4D4
                JEQ     o2trim_apply_start             ; 1D4E 0 100 280 C916
o2_trim_table_offset_calc:     L       A, X1                  ; 1D50 1 100 280 40
                JBR     off(0011eh).3, o2_trim_table_offset_calc2 ; 1D51 1 100 280 DB1E03
                ADD     A, #0000ch             ; 1D54 1 100 280 860C00
o2_trim_table_offset_calc2:     JBS     off(0011eh).0, o2_trim_rate_table_read ; 1D57 1 100 280 E81E03
                ADD     A, #00030h             ; 1D5A 1 100 280 863000
o2_trim_rate_table_read:     ADD     DP, A                  ; 1D5D 1 100 280 9281
                LC      A, [DP]                ; 1D5F 1 100 280 92A8
                JBS     off(0012dh).2, o2trim_sub_clamp ; 1D61 1 100 280 EA2D5F
                SJ      o2trim_add_clamp             ; 1D64 1 100 280 CB53
o2trim_apply_start:     MOVB    off(001d4h), #014h     ; 1D66 0 100 280 C4D49814
                L       A, #00b00h             ; 1D6A 1 100 280 67000B
                JBS     off(0012fh).0, o2trim_add_clamp ; 1D6D 1 100 280 E82F49
                L       A, #00000h             ; 1D70 1 100 280 670000
                JBS     off(0011eh).3, cmp_x1_bound8_dispatch ; 1D73 1 100 280 EB1E03
                L       A, #00000h             ; 1D76 1 100 280 670000
cmp_x1_bound8_dispatch:     CMP     X1, #00008h            ; 1D79 1 100 280 90C00800
                JEQ     o2trim_add_clamp             ; 1D7D 1 100 280 C93A
                MOVB    r0, #080h              ; 1D7F 1 100 280 9880
                MOV     er2, #006f7h           ; 1D81 1 100 280 4698F706
                MOV     er3, #006f7h           ; 1D85 1 100 280 4798F706
                LB      A, #064h               ; 1D89 0 100 280 7764
                JBS     off(0011eh).3, to_o2trim_add_clamp ; 1D8B 0 100 280 EB1E0C
                MOVB    r0, #080h              ; 1D8E 0 100 280 9880
                MOV     er2, #00618h           ; 1D90 0 100 280 46981806
                MOV     er3, #00618h           ; 1D94 0 100 280 47981806
                LB      A, #051h               ; 1D98 0 100 280 7751
to_o2trim_add_clamp:     CMPB    A, off(00132h)         ; 1D9A 0 100 280 C732
                JGT     to_o2trim_add_clamp_load_ram17a             ; 1D9C 0 100 280 C80A
                L       A, er2                 ; 1D9E 1 100 280 36
                JBS     off(0011eh).0, to_o2trim_add_clamp_cmp_r0 ; 1D9F 1 100 280 E81E01
                L       A, er3                 ; 1DA2 1 100 280 37
to_o2trim_add_clamp_cmp_r0:     CMPB    r0, off(00133h)        ; 1DA3 1 100 280 20C333
                JLE     o2trim_add_clamp             ; 1DA6 1 100 280 CF11
to_o2trim_add_clamp_load_ram17a:     L       A, off(0017ah)         ; 1DA8 1 100 280 E47A
                CMPB    off(00132h), #052h     ; 1DAA 1 100 280 C432C052
                JBS     off(0011eh).3, to_o2trim_add_clamp_if_ge_goto_o2trim_add_clamp ; 1DAE 1 100 280 EB1E04
                CMPB    off(00132h), #052h     ; 1DB1 1 100 280 C432C052
to_o2trim_add_clamp_if_ge_goto_o2trim_add_clamp:     JGE     o2trim_add_clamp             ; 1DB5 1 100 280 CD02
                L       A, off(00178h)         ; 1DB7 1 100 280 E478
o2trim_add_clamp:     ADD     er1, A                 ; 1DB9 1 100 280 4581
                JGE     o2trim_closeloop_speed_check             ; 1DBB 1 100 280 CD0C
                MOV     er1, #0ffffh           ; 1DBD 1 100 280 4598FFFF
                SJ      o2trim_closeloop_speed_check             ; 1DC1 1 100 280 CB06
o2trim_sub_clamp:     SUB     er1, A                 ; 1DC3 1 100 280 45A1
                JGE     o2trim_closeloop_speed_check             ; 1DC5 1 100 280 CD02
                CLR     er1                    ; 1DC7 1 100 280 4515
o2trim_closeloop_speed_check:     RB      PSWL.4                 ; 1DC9 1 100 280 A30C
                L       A, #0bc15h             ; 1DCB 1 100 280 6715BC
                CMP     A, er1                 ; 1DCE 1 100 280 49
                JLE     o2trim_closeloop_speed_check_store_er1             ; 1DCF 1 100 280 CF23
                L       A, #tbl_5e20           ; 1DD1 1 100 280 67205E
                CMP     A, er1                 ; 1DD4 1 100 280 49
                JLT     o2trim_speed_flags_store             ; 1DD5 1 100 280 CA1E
                JBS     off(0011fh).3, o2trim_closeloop_speed_check_store_er1 ; 1DD7 1 100 280 EB1F1A
                CMPB    0d9h, #001h            ; 1DDA 1 100 280 C5D9C001
                JGE     o2trim_closeloop_speed_check_store_er1             ; 1DDE 1 100 280 CD14
                CMPB    0d8h, #001h            ; 1DE0 1 100 280 C5D8C001
                JGE     o2trim_closeloop_speed_check_store_er1             ; 1DE4 1 100 280 CD0E
                CMPB    0dah, #04dh            ; 1DE6 1 100 280 C5DAC04D
                JGT     o2trim_closeloop_speed_check_store_er1             ; 1DEA 1 100 280 C808
                SB      PSWL.4                 ; 1DEC 1 100 280 A31C
                L       A, #tbl_5e20           ; 1DEE 1 100 280 67205E
                CMP     A, er1                 ; 1DF1 1 100 280 49
                JLT     o2trim_speed_flags_store             ; 1DF2 1 100 280 CA01
o2trim_closeloop_speed_check_store_er1:     ST      A, er1                 ; 1DF4 1 100 280 89
o2trim_speed_flags_store:     MB      C, PSWL.4              ; 1DF5 1 100 280 A32C
                MB      off(00126h).4, C       ; 1DF7 1 100 280 C4263C
                MOV     DP, #003abh            ; 1DFA 1 100 280 62AB03
                LB      A, [DP]                ; 1DFD 0 100 280 F2
                CMPB    A, #031h               ; 1DFE 0 100 280 C631
                JEQ     o2trim_gate_common2             ; 1E00 0 100 280 C94F
                LB      A, off(001e4h)         ; 1E02 0 100 280 F4E4
                JNE     o2trim_gate_common2             ; 1E04 0 100 280 CE4B
                JBR     off(00121h).1, o2trim_gate_common2 ; 1E06 0 100 280 D92148
                JBS     off(0012ch).4, o2trim_gate_common2 ; 1E09 0 100 280 EC2C45
                CMPB    0d8h, #030h            ; 1E0C 0 100 280 C5D8C030
                JLT     o2trim_gate_common2             ; 1E10 0 100 280 CA3F
                CLR     A                      ; 1E12 1 100 280 F9
                CLRB    A                      ; 1E13 0 100 280 FA
                MB      C, PSWL.5              ; 1E14 0 100 280 A32D
                JLT     o2trim_bank_select_check             ; 1E16 0 100 280 CA13
                JBR     off(0012dh).1, o2trim_bank_select_check ; 1E18 0 100 280 D92D10
                JBS     off(00125h).3, o2trim_gate_common2 ; 1E1B 0 100 280 EB2533
                MOV     X1, #00300h            ; 1E1E 0 100 280 600003
                JBS     off(00120h).0, o2trim_ect_offset_lookup ; 1E21 0 100 280 E82013
                MOV     X1, #00304h            ; 1E24 0 100 280 600403
                LB      A, #004h               ; 1E27 0 100 280 7704
                SJ      o2trim_ect_offset_lookup             ; 1E29 0 100 280 CB0C
o2trim_bank_select_check:     JBS     off(00120h).0, o2trim_gate_common2 ; 1E2B 0 100 280 E82023
                LB      A, off(001dbh)         ; 1E2E 0 100 280 F4DB
                JEQ     o2trim_gate_common2             ; 1E30 0 100 280 C91F
                MOV     X1, #00308h            ; 1E32 0 100 280 600803
                LB      A, #008h               ; 1E35 0 100 280 7708
o2trim_ect_offset_lookup:     CMPB    0d9h, #02eh            ; 1E37 0 100 280 C5D9C02E
                JGE     o2trim_ect_offset_lookup_rom_load_tbl_61b7_acc             ; 1E3B 0 100 280 CD02
                ADDB    A, #002h               ; 1E3D 0 100 280 8602
o2trim_ect_offset_lookup_rom_load_tbl_61b7_acc:     LC      A, o2trim_ect_offset_lookup_tbl[ACC]       ; 1E3F 0 100 280 B506A9B761
                L       A, ACC                 ; 1E44 1 100 280 E506
                ST      A, er0                 ; 1E46 1 100 280 88
                L       A, er1                 ; 1E47 1 100 280 35
                ST      A, er3                 ; 1E48 1 100 280 8B
                CAL     injtimer_bank_calc1             ; 1E49 1 100 280 322859
                CAL     injtimer_bank_calc2             ; 1E4C 1 100 280 327A5A
                MOV     er1, er3               ; 1E4F 1 100 280 4749
o2trim_gate_common2:     L       A, er1                 ; 1E51 1 100 280 35
injtimer_finalize_start:     ST      A, off(0015ah)         ; 1E52 1 100 280 D45A
                LB      A, #002h               ; 1E54 0 100 280 7702
                JBS     off(00130h).3, injtimer_finalize_start_cmp_acc ; 1E56 0 100 280 EB3002
                LB      A, #004h               ; 1E59 0 100 280 7704
injtimer_finalize_start_cmp_acc:     CMPB    A, off(00133h)         ; 1E5B 0 100 280 C733
                MB      off(00130h).3, C       ; 1E5D 0 100 280 C4303B
                LB      A, #0f2h               ; 1E60 0 100 280 77F2
                JBS     off(00130h).4, injtimer_finalize_start_cmp_acc_2 ; 1E62 0 100 280 EC3002
                LB      A, #0f9h               ; 1E65 0 100 280 77F9
injtimer_finalize_start_cmp_acc_2:     CMPB    A, off(00132h)         ; 1E67 0 100 280 C732
                MB      off(00130h).4, C       ; 1E69 0 100 280 C4303C
                LB      A, off(0016eh)         ; 1E6C 0 100 280 F46E
                JBS     off(00125h).4, injtimer_finalize_start_store_ram165 ; 1E6E 0 100 280 EC2565
                LB      A, #040h               ; 1E71 0 100 280 7740
                JBS     off(0012fh).7, injtimer_finalize_start_store_ram165 ; 1E73 0 100 280 EF2F60
                JBS     off(0012bh).5, injtimer_finalize_start_store_ram165 ; 1E76 0 100 280 ED2B5D
                MOV     X1, #injtimer_finalize_start_tbl          ; 1E79 0 100 280 60B178
                JBS     off(0011eh).3, injtimer_finalize_start_if_ram125_bit1_clr ; 1E7C 0 100 280 EB1E04
                ADD     X1, #00003h            ; 1E7F 0 100 280 90800300
injtimer_finalize_start_if_ram125_bit1_clr:     JBR     off(00125h).1, injtimer_finalize_start_cmp_ram15c ; 1E83 0 100 280 D9250E
                JBS     off(00122h).2, injtimer_finalize_start_goto_7843 ; 1E86 0 100 280 EA2205
                JBR     off(00120h).0, injtimer_finalize_start_goto_7843 ; 1E89 0 100 280 D82002
                SJ      injtimer_finalize_start_store_ram165             ; 1E8C 0 100 280 CB48
injtimer_finalize_start_goto_7843:     J       injtimer_finalize_start_add_x1             ; 1E8E 0 100 280 034378
                DB  000h,000h,000h ; 1E91
injtimer_finalize_start_cmp_ram15c:     CMP     off(0015ch), #03000h   ; 1E94 0 100 280 B45CC00030
                JGE     injtimer_finalize_start_load_ram16b             ; 1E99 0 100 280 CD1E
                JBR     off(00130h).3, injtimer_finalize_start_load_ram16b ; 1E9B 0 100 280 DB301B
                JBS     off(00130h).4, injtimer_finalize_start_load_ram16b ; 1E9E 0 100 280 EC3018
                LB      A, 0c0h                ; 1EA1 0 100 280 F5C0
                JBR     off(00123h).4, injtimer_finalize_start_if_ram123_bit1_clr ; 1EA3 0 100 280 DC2304
                CMPB    A, #003h               ; 1EA6 0 100 280 C603
                JGE     injtimer_finalize_start_load_ram16b             ; 1EA8 0 100 280 CD0F
injtimer_finalize_start_if_ram123_bit1_clr:     JBR     off(00123h).1, injtimer_finalize_start_load_ram170 ; 1EAA 0 100 280 D92317
                LB      A, #004h               ; 1EAD 0 100 280 7704
                JBS     off(0011eh).3, injtimer_finalize_start_cmp_acc_3 ; 1EAF 0 100 280 EB1E02
                LB      A, #004h               ; 1EB2 0 100 280 7704
injtimer_finalize_start_cmp_acc_3:     CMPB    A, 0d5h                ; 1EB4 0 100 280 C5D5C2
                JGE     injtimer_finalize_start_load_ram170             ; 1EB7 0 100 280 CD0B
injtimer_finalize_start_load_ram16b:     LB      A, off(0016bh)         ; 1EB9 0 100 280 F46B
                SUBB    A, off(0016fh)         ; 1EBB 0 100 280 A76F
                JGE     injtimer_finalize_start_store_ram170             ; 1EBD 0 100 280 CD01
                CLRB    A                      ; 1EBF 0 100 280 FA
injtimer_finalize_start_store_ram170:     STB     A, off(00170h)         ; 1EC0 0 100 280 D470
                SJ      injtimer_finalize_start_goto_7879             ; 1EC2 0 100 280 CB0D
injtimer_finalize_start_load_ram170:     LB      A, off(00170h)         ; 1EC4 0 100 280 F470
                MOVB    r0, #0fah              ; 1EC6 0 100 280 98FA
                MULB                           ; 1EC8 0 100 280 A234
                LB      A, ACCH                ; 1ECA 0 100 280 F507
                STB     A, off(00170h)         ; 1ECC 0 100 280 D470
                J       injtimer_finalize_start_addb_acc             ; 1ECE 0 100 280 036378
injtimer_finalize_start_goto_7879:     J       injtimer_finalize_start_load_r7             ; 1ED1 0 100 280 037978
                DW  00000h           ; 1ED4
injtimer_finalize_start_store_ram165:     STB     A, off(00165h)         ; 1ED6 0 100 280 D465
                LB      A, off(00132h)         ; 1ED8 0 100 280 F432
                MOV     X1, #tbl_injtimer_finalize          ; 1EDA 0 100 280 60D762
                CAL     table_interp_lookup             ; 1EDD 0 100 280 323958
                CLRB    ACCH                   ; 1EE0 0 100 280 C50715
                L       A, ACC                 ; 1EE3 1 100 280 E506
                ADD     A, #00080h             ; 1EE5 1 100 280 868000
                CLRB    r0                     ; 1EE8 1 100 280 2015
                MOVB    r1, off(00169h)        ; 1EEA 1 100 280 C46949
                MUL                            ; 1EED 1 100 280 9035
                SLL     A                      ; 1EEF 1 100 280 53
                L       A, er1                 ; 1EF0 1 100 280 35
                ROL     A                      ; 1EF1 1 100 280 33
                NOP                            ; 1EF2 1 100 280 00
                NOP                            ; 1EF3 1 100 280 00
                ADD     A, #00200h             ; 1EF4 1 100 280 860002
                ST      A, off(00160h)         ; 1EF7 1 100 280 D460
                LB      A, #03ah               ; 1EF9 0 100 280 773A
                JBS     off(0012dh).6, injtimer_finalize_start_cmp_acc_4 ; 1EFB 0 100 280 EE2D02
                LB      A, #040h               ; 1EFE 0 100 280 7740
injtimer_finalize_start_cmp_acc_4:     CMPB    A, off(00133h)         ; 1F00 0 100 280 C733
                MB      off(0012dh).6, C       ; 1F02 0 100 280 C42D3E
                LB      A, #01ch               ; 1F05 0 100 280 771C
                JBS     off(0012dh).7, injtimer_finalize_start_cmp_acc_5 ; 1F07 0 100 280 EF2D02
                LB      A, #01dh               ; 1F0A 0 100 280 771D
injtimer_finalize_start_cmp_acc_5:     CMPB    A, 0d1h                ; 1F0C 0 100 280 C5D1C2
                MB      off(0012dh).7, C       ; 1F0F 0 100 280 C42D3F
                JBR     off(00121h).3, injtimer_gate_common ; 1F12 0 100 280 DB2125
                J       injtimer_finalize_start_load_carry_stk             ; 1F15 0 100 280 039179
injtimer_finalize_start_cmp_ram0d9:     CMPB    0d9h, #0e0h            ; 1F18 0 100 280 C5D9C0E0
                JGE     injtimer_gate_common             ; 1F1C 0 100 280 CD1C
                CMPB    0d9h, #044h            ; 1F1E 0 100 280 C5D9C044
                JLT     injtimer_gate_common             ; 1F22 0 100 280 CA16
                JBR     off(0012dh).6, injtimer_gate_common ; 1F24 0 100 280 DE2D13
                JBR     off(0012dh).7, injtimer_gate_common ; 1F27 0 100 280 DF2D10
                JBR     off(00121h).0, injtimer_gate_common ; 1F2A 0 100 280 D8210D
                JBS     off(0012bh).5, injtimer_gate_common ; 1F2D 0 100 280 ED2B0A
                JBS     off(00125h).1, injtimer_gate_common ; 1F30 0 100 280 E92507
                JBS     off(0012dh).2, injtimer_gate_common ; 1F33 0 100 280 EA2D04
                LB      A, #014h               ; 1F36 0 100 280 7714
                SJ      injtimer_gate_common_store_ram168             ; 1F38 0 100 280 CB07
injtimer_gate_common:     LB      A, off(00168h)         ; 1F3A 0 100 280 F468
                SUBB    A, #001h               ; 1F3C 0 100 280 A601
                JGE     injtimer_gate_common_store_ram168             ; 1F3E 0 100 280 CD01
                CLRB    A                      ; 1F40 0 100 280 FA
injtimer_gate_common_store_ram168:     STB     A, off(00168h)         ; 1F41 0 100 280 D468
                LB      A, off(00164h)         ; 1F43 0 100 280 F464
                JBS     off(0012fh).7, injtimer_gate_common_store_r1 ; 1F45 0 100 280 EF2F02
                LB      A, off(00165h)         ; 1F48 0 100 280 F465
injtimer_gate_common_store_r1:     STB     A, r1                  ; 1F4A 0 100 280 89
                CLRB    r0                     ; 1F4B 0 100 280 2015
                SRL     er0                    ; 1F4D 0 100 280 44E7
                LB      A, off(00166h)         ; 1F4F 0 100 280 F466
                JEQ     injtimer_gate_common_load_ram167             ; 1F51 0 100 280 C907
                STB     A, ACCH                ; 1F53 0 100 280 D507
                CLRB    A                      ; 1F55 0 100 280 FA
                MUL                            ; 1F56 0 100 280 9035
                MOV     er0, er1               ; 1F58 0 100 280 4548
injtimer_gate_common_load_ram167:     LB      A, off(00167h)         ; 1F5A 0 100 280 F467
                JEQ     injtimer_mul_chain1             ; 1F5C 0 100 280 C907
                STB     A, ACCH                ; 1F5E 0 100 280 D507
                CLRB    A                      ; 1F60 0 100 280 FA
                MUL                            ; 1F61 0 100 280 9035
                MOV     er0, er1               ; 1F63 0 100 280 4548
injtimer_mul_chain1:     MOVB    ACCH, #001h            ; 1F65 0 100 280 C5079801
                LB      A, off(00168h)         ; 1F69 0 100 280 F468
                MUL                            ; 1F6B 0 100 280 9035
                MOVB    r1, r2                 ; 1F6D 0 100 280 2249
                MOVB    r0, ACCH               ; 1F6F 0 100 280 C50748
                L       A, off(00162h)         ; 1F72 1 100 280 E462
                MUL                            ; 1F74 1 100 280 9035
                MOV     er0, er1               ; 1F76 1 100 280 4548
                L       A, off(00160h)         ; 1F78 1 100 280 E460
                MUL                            ; 1F7A 1 100 280 9035
                SRL     er1                    ; 1F7C 1 100 280 45E7
                ROR     A                      ; 1F7E 1 100 280 43
                SRL     er1                    ; 1F7F 1 100 280 45E7
                ROR     A                      ; 1F81 1 100 280 43
                MOVB    r1, r2                 ; 1F82 1 100 280 2249
                MOVB    r0, ACCH               ; 1F84 1 100 280 C50748
                LB      A, r3                  ; 1F87 0 100 280 7B
                JEQ     injtimer_mul_chain2             ; 1F88 0 100 280 C904
                MOV     er0, #0ffffh           ; 1F8A 0 100 280 4498FFFF
injtimer_mul_chain2:     L       A, off(0015eh)         ; 1F8E 1 100 280 E45E
                MUL                            ; 1F90 1 100 280 9035
                MOV     er0, er1               ; 1F92 1 100 280 4548
                JBR     off(0012ch).4, injtimer_mul_final ; 1F94 1 100 280 DC2C19
                SLL     A                      ; 1F97 1 100 280 53
                ROL     er0                    ; 1F98 1 100 280 44B7
                JLT     injtimer_mul_clamp             ; 1F9A 1 100 280 CA0A
                SLL     A                      ; 1F9C 1 100 280 53
                ROL     er0                    ; 1F9D 1 100 280 44B7
                JLT     injtimer_mul_clamp             ; 1F9F 1 100 280 CA05
                SLL     A                      ; 1FA1 1 100 280 53
                ROL     er0                    ; 1FA2 1 100 280 44B7
                JGE     injtimer_mul_chain3             ; 1FA4 1 100 280 CD04
injtimer_mul_clamp:     MOV     er0, #0ffffh           ; 1FA6 1 100 280 4498FFFF
injtimer_mul_chain3:     L       A, off(0015ch)         ; 1FAA 1 100 280 E45C
                MUL                            ; 1FAC 1 100 280 9035
                MOV     er0, er1               ; 1FAE 1 100 280 4548
injtimer_mul_final:     L       A, off(0015ah)         ; 1FB0 1 100 280 E45A
                MUL                            ; 1FB2 1 100 280 9035
                J       injtimer_mul_final_load_ram158             ; 1FB4 1 100 280 03997A
dwell_rpm_hyst_check_if_ram125_bit4_set:     JBS     off(00125h).4, dwell_zero_result ; 1FB7 0 100 280 EC254F
                LB      A, off(00133h)         ; 1FBA 0 100 280 F433
                CMPB    A, #0c0h               ; 1FBC 0 100 280 C6C0
                JGE     dwell_zero_result             ; 1FBE 0 100 280 CD49
                JBR     off(00129h).0, dwell_zero_result ; 1FC0 0 100 280 D82946
                LB      A, #004h               ; 1FC3 0 100 280 7704
                JBS     off(00123h).5, dwell_rpm_gate2 ; 1FC5 0 100 280 ED2308
                LB      A, #004h               ; 1FC8 0 100 280 7704
                CMPB    0f3h, #096h            ; 1FCA 0 100 280 C5F3C096
                JLT     dwell_zero_result             ; 1FCE 0 100 280 CA39
dwell_rpm_gate2:     CMPB    off(00133h), #002h     ; 1FD0 0 100 280 C433C002
                JBS     off(00123h).5, dwell_rpm_gate3 ; 1FD4 0 100 280 ED2304
                J       dwell_rpm_gate2_load_carry_ram130_bit6             ; 1FD7 0 100 280 03AB7A
                DB  000h ; 1FDA
dwell_rpm_gate3:     JLT     dwell_zero_result             ; 1FDB 0 100 280 CA2C
                CMPB    A, 0c1h                ; 1FDD 0 100 280 C5C1C2
                JGE     dwell_zero_result             ; 1FE0 0 100 280 CD27
                MOVB    r0, off(0018dh)        ; 1FE2 0 100 280 C48D48
                CMPB    off(00133h), #05ah     ; 1FE5 0 100 280 C433C05A
                JGE     dwell_value_select             ; 1FE9 0 100 280 CD03
                MOVB    r0, off(0018bh)        ; 1FEB 0 100 280 C48B48
dwell_value_select:     MOVB    r1, #018h              ; 1FEE 0 100 280 9918
                JBS     off(00123h).5, dwell_clamp_check ; 1FF0 0 100 280 ED2305
                MOVB    r0, off(0018ch)        ; 1FF3 0 100 280 C48C48
                MOVB    r1, #010h              ; 1FF6 0 100 280 9910
dwell_clamp_check:     LB      A, 0c1h                ; 1FF8 0 100 280 F5C1
                CMPB    A, r1                  ; 1FFA 0 100 280 49
                JLE     dwell_mul_apply             ; 1FFB 0 100 280 CF01
                LB      A, r1                  ; 1FFD 0 100 280 79
dwell_mul_apply:     MULB                           ; 1FFE 0 100 280 A234
                L       A, ACC                 ; 2000 1 100 280 E506
                SRL     A                      ; 2002 1 100 280 63
                JBS     off(00123h).5, dwell_store_result ; 2003 1 100 280 ED2304
                VCAL    7                      ; 2006 1 100 280 17
                SJ      dwell_store_result             ; 2007 1 100 280 CB01
dwell_zero_result:     CLR     A                      ; 2009 1 100 280 F9
dwell_store_result:     ST      A, off(00146h)         ; 200A 1 100 280 D446
                CLRB    r4                     ; 200C 1 100 280 2415
                RC                             ; 200E 1 100 280 95
                JBS     off(00125h).4, rpm_accel_skip ; 200F 1 100 280 EC256E
                JBR     off(00122h).3, rpm_accel_skip ; 2012 1 100 280 DB226B
                JBS     off(0012ch).7, rpm_accel_track_calc ; 2015 1 100 280 EF2C09
                JBS     off(00122h).4, rpm_accel_alt_path ; 2018 1 100 280 EC2268
                L       A, (0025ch-00280h)[USP] ; 201B 1 100 280 E3DC
                CLRB    r5                     ; 201D 1 100 280 2515
                SJ      rpm_accel_track_store             ; 201F 1 100 280 CB0F
rpm_accel_track_calc:     MOV     er3, off(00138h)       ; 2021 1 100 280 B4384B
                MOVB    r5, off(0013ah)        ; 2024 1 100 280 C43A4D
                CLRB    r0                     ; 2027 1 100 280 2015
                MOVB    r1, #080h              ; 2029 1 100 280 9980
                L       A, 0c4h                ; 202B 1 100 280 E5C4
                CAL     rpm_accel_track_helper             ; 202D 1 100 280 321559
rpm_accel_track_store:     ST      A, off(00138h)         ; 2030 1 100 280 D438
                MOVB    off(0013ah), r5        ; 2032 1 100 280 257C3A
                CLRB    r4                     ; 2035 1 100 280 2415
                SUB     A, 0c4h                ; 2037 1 100 280 B5C4A2
                MB      off(0012ch).6, C       ; 203A 1 100 280 C42C3E
                JLT     rpm_accel_fault_path             ; 203D 1 100 280 CA0A
                JBS     off(00123h).6, rpm_accel_secondary_calc ; 203F 1 100 280 EE2312
                CMP     0c6h, #00000h          ; 2042 1 100 280 B5C6C00000
                SJ      rpm_accel_gate_result             ; 2047 1 100 280 CB09
rpm_accel_fault_path:     VCAL    7                      ; 2049 1 100 280 17
                JBR     off(00123h).6, rpm_accel_secondary_calc ; 204A 1 100 280 DE2307
                CMP     0c6h, #00000h          ; 204D 1 100 280 B5C6C00000
rpm_accel_gate_result:     JGE     rpm_accel_clamp             ; 2052 1 100 280 CD2B
rpm_accel_secondary_calc:     CLRB    r0                     ; 2054 1 100 280 2015
                MOVB    r1, #020h              ; 2056 1 100 280 9920
                CMPB    0d9h, #034h            ; 2058 1 100 280 C5D9C034
                JGE     rpm_accel_mul_apply             ; 205C 1 100 280 CD0B
                JBS     off(0011eh).3, rpm_accel_mul_apply ; 205E 1 100 280 EB1E08
                CMPB    0cch, #005h            ; 2061 1 100 280 C5CCC005
                JLT     rpm_accel_mul_apply             ; 2065 1 100 280 CA02
                MOVB    r1, #020h              ; 2067 1 100 280 9920
rpm_accel_mul_apply:     MUL                            ; 2069 1 100 280 9035
                MOVB    r4, #02dh              ; 206B 1 100 280 9C2D
                SLL     A                      ; 206D 1 100 280 53
                ROL     er1                    ; 206E 1 100 280 45B7
                JLT     rpm_accel_clamp             ; 2070 1 100 280 CA0D
                SLL     A                      ; 2072 1 100 280 53
                ROL     er1                    ; 2073 1 100 280 45B7
                JLT     rpm_accel_clamp             ; 2075 1 100 280 CA08
                LB      A, r3                  ; 2077 0 100 280 7B
                JNE     rpm_accel_clamp             ; 2078 0 100 280 CE05
                LB      A, r2                  ; 207A 0 100 280 7A
                CMPB    A, r4                  ; 207B 0 100 280 4C
                JGE     rpm_accel_clamp             ; 207C 0 100 280 CD01
                STB     A, r4                  ; 207E 0 100 280 8C
rpm_accel_clamp:     SC                             ; 207F 0 100 280 85
rpm_accel_skip:     MB      off(0012ch).7, C       ; 2080 1 100 280 C42C3F
rpm_accel_alt_path:     LB      A, r4                  ; 2083 0 100 280 7C
                JEQ     rpm_accel_store_0x148             ; 2084 0 100 280 C904
                JBS     off(0012ch).6, rpm_accel_store_0x148 ; 2086 0 100 280 EE2C01
                VCAL    6                      ; 2089 0 100 280 16
rpm_accel_store_0x148:     STB     A, off(00148h)         ; 208A 0 100 280 D448
                JBR     off(0011eh).3, rpm_decel_zero ; 208C 0 100 280 DB1E4A
                JBR     off(00119h).5, rpm_decel_ect_gate ; 208F 0 100 280 DD1905
                RB      off(00130h).7          ; 2092 0 100 280 C4300F
                SJ      rpm_decel_zero             ; 2095 0 100 280 CB42
rpm_decel_ect_gate:     CMPB    0d9h, #0ffh            ; 2097 0 100 280 C5D9C0FF
                JLT     rpm_decel_zero             ; 209B 0 100 280 CA3C
                MOVB    r0, #001h              ; 209D 0 100 280 9801
                MOV     er1, #00001h           ; 209F 0 100 280 45980100
                CMPB    0d9h, #0ffh            ; 20A3 0 100 280 C5D9C0FF
                JLT     rpm_decel_calc             ; 20A7 0 100 280 CA06
                MOVB    r0, #001h              ; 20A9 0 100 280 9801
                MOV     er1, #00001h           ; 20AB 0 100 280 45980100
rpm_decel_calc:     MOV     DP, #00311h            ; 20AF 0 100 280 621103
                LB      A, [DP]                ; 20B2 0 100 280 F2
                ADDB    A, #001h               ; 20B3 0 100 280 8601
                CMPB    A, 0d4h                ; 20B5 0 100 280 C5D4C2
                JLT     rpm_decel_diff_check             ; 20B8 0 100 280 CA1A
                JBS     off(00123h).6, rpm_decel_diff_check ; 20BA 0 100 280 EE2317
                CMP     0c6h, #00040h          ; 20BD 0 100 280 B5C6C04000
                JLT     rpm_decel_diff_check             ; 20C2 0 100 280 CA10
                JBS     off(00130h).7, rpm_decel_flag_result ; 20C4 0 100 280 EF3007
                MOVB    off(001e5h), #001h     ; 20C7 0 100 280 C4E59801
                SB      off(00130h).7          ; 20CB 0 100 280 C4301F
rpm_decel_flag_result:     CMPB    off(001e5h), #000h     ; 20CE 0 100 280 C4E5C000
                JNE     rpm_decel_mul_calc             ; 20D2 0 100 280 CE08
rpm_decel_diff_check:     L       A, off(0014ah)         ; 20D4 1 100 280 E44A
                SUB     A, er1                 ; 20D6 1 100 280 29
                JGE     rpm_decel_store             ; 20D7 1 100 280 CD17
rpm_decel_zero:     CLR     A                      ; 20D9 1 100 280 F9
                SJ      rpm_decel_store             ; 20DA 1 100 280 CB14
rpm_decel_mul_calc:     CLRB    r1                     ; 20DC 0 100 280 2115
                L       A, 0c6h                ; 20DE 1 100 280 E5C6
                MUL                            ; 20E0 1 100 280 9035
                MOV     er0, #00000h           ; 20E2 1 100 280 44980000
                CMP     er1, #00000h           ; 20E6 1 100 280 45C00000
                JNE     rpm_decel_result_select             ; 20EA 1 100 280 CE03
                CMP     A, er0                 ; 20EC 1 100 280 48
                JLT     rpm_decel_store             ; 20ED 1 100 280 CA01
rpm_decel_result_select:     L       A, er0                 ; 20EF 1 100 280 34
rpm_decel_store:     ST      A, off(0014ah)         ; 20F0 1 100 280 D44A
                CLR     A                      ; 20F2 1 100 280 F9
                CLRB    r0                     ; 20F3 1 100 280 2015
                JBS     off(00125h).4, rpm_decel_flags_clear ; 20F5 1 100 280 EC2570
                JBS     off(00124h).0, rpm_decel_flags_clear ; 20F8 1 100 280 E8246D
                MOVB    r0, #004h              ; 20FB 1 100 280 9804
                JBS     off(00124h).2, rpm_decel_flags_clear ; 20FD 1 100 280 EA2468
                MOVB    r0, off(00156h)        ; 2100 1 100 280 C45648
                CMPB    r0, #000h              ; 2103 1 100 280 20C000
                JNE     rpm_decel_table_lookup             ; 2106 1 100 280 CE1F
                JBR     off(00123h).1, rpm_decel_counter_check ; 2108 1 100 280 D92306
                CMPB    0d5h, #008h            ; 210B 1 100 280 C5D5C008
                JGE     rpm_decel_flags_clear             ; 210F 1 100 280 CD57
rpm_decel_counter_check:     MOVB    r1, off(00157h)        ; 2111 1 100 280 C45749
                CMPB    r1, #000h              ; 2114 1 100 280 21C000
                JEQ     rpm_decel_diff_check2             ; 2117 1 100 280 C903
                DECB    r1                     ; 2119 1 100 280 B9
                JNE     rpm_decel_store_0x150_store_ram14c             ; 211A 1 100 280 CE56
rpm_decel_diff_check2:     L       A, off(00152h)         ; 211C 1 100 280 E452
                JEQ     rpm_decel_flags_clear             ; 211E 1 100 280 C948
                SUB     A, off(00154h)         ; 2120 1 100 280 A754
                JGE     rpm_decel_flags_clear             ; 2122 1 100 280 CD44
                CLR     A                      ; 2124 1 100 280 F9
                SJ      rpm_decel_flags_clear             ; 2125 1 100 280 CB41
rpm_decel_table_lookup:     LB      A, off(00133h)         ; 2127 0 100 280 F433
                MOV     X1, #tbl_rpm_decel          ; 2129 0 100 280 60A463
                VCAL    0                      ; 212C 0 100 280 10
                ; warning: had to flip DD
                CMP     A, 0c8h                ; 212D 1 100 280 B5C8C2
                CLR     A                      ; 2130 1 100 280 F9
                MOVB    r0, off(00156h)        ; 2131 1 100 280 C45648
                DECB    r0                     ; 2134 1 100 280 B8
                JBS     off(00123h).7, rpm_decel_store_0x150 ; 2135 1 100 280 EF2336
                JGE     rpm_decel_store_0x150             ; 2138 1 100 280 CD34
                L       A, #00145h             ; 213A 1 100 280 674501
                JBS     off(0012eh).5, rpm_decel_mul_final ; 213D 1 100 280 ED2E0F
                L       A, #000fah             ; 2140 1 100 280 67FA00
                JBS     off(0012eh).6, rpm_decel_mul_final ; 2143 1 100 280 EE2E09
                L       A, #0004bh             ; 2146 1 100 280 674B00
                JBR     off(0011eh).3, rpm_decel_mul_final ; 2149 1 100 280 DB1E03
                L       A, #0007dh             ; 214C 1 100 280 677D00
rpm_decel_mul_final:     MOV     er0, off(00184h)       ; 214F 1 100 280 B48448
                MUL                            ; 2152 1 100 280 9035
                SRL     er1                    ; 2154 1 100 280 45E7
                ROR     A                      ; 2156 1 100 280 43
                SRL     er1                    ; 2157 1 100 280 45E7
                ROR     A                      ; 2159 1 100 280 43
                LB      A, r2                  ; 215A 0 100 280 7A
                L       A, ACC                 ; 215B 1 100 280 E506
                SWAP                           ; 215D 1 100 280 83
                CMPB    r3, #000h              ; 215E 1 100 280 23C000
                JEQ     rpm_decel_result_clear             ; 2161 1 100 280 C903
                L       A, #0ffffh             ; 2163 1 100 280 67FFFF
rpm_decel_result_clear:     CLRB    r0                     ; 2166 1 100 280 2015
rpm_decel_flags_clear:     RB      off(0012eh).5          ; 2168 1 100 280 C42E0D
                RB      off(0012eh).6          ; 216B 1 100 280 C42E0E
rpm_decel_store_0x150:     ST      A, off(00152h)         ; 216E 1 100 280 D452
                MOVB    r1, #004h              ; 2170 1 100 280 9904
rpm_decel_store_0x150_store_ram14c:     ST      A, off(0014ch)         ; 2172 1 100 280 D44C
                MOVB    off(00156h), r0        ; 2174 1 100 280 207C56
                MOVB    off(00157h), r1        ; 2177 1 100 280 217C57
                JBR     off(00124h).4, tipin_time_calc ; 217A 1 100 280 DC2417
                CLR     A                      ; 217D 1 100 280 F9
                MOV     X1, A                  ; 217E 1 100 280 50
                ST      A, 003b4h[X1]          ; 217F 1 100 280 D0B403
                ST      A, 003b6h[X1]          ; 2182 1 100 280 D0B603
                ST      A, 003b8h[X1]          ; 2185 1 100 280 D0B803
                ST      A, 003bah[X1]          ; 2188 1 100 280 D0BA03
                ST      A, 003bch[X1]          ; 218B 1 100 280 D0BC03
                ST      A, 003a2h[X1]          ; 218E 1 100 280 D0A203
                J       postinj_rpm_check             ; 2191 1 100 280 03B122
tipin_time_calc:     L       A, off(00142h)         ; 2194 1 100 280 E442
                JBR     off(0012bh).3, tipin_time_sum ; 2196 1 100 280 DB2B0C
                CMPB    0f2h, #004h            ; 2199 1 100 280 C5F2C004
                MB      off(0012bh).3, C       ; 219D 1 100 280 C42B3B
                ADD     A, #0007dh             ; 21A0 1 100 280 867D00
                JLT     tipin_time_clamp             ; 21A3 1 100 280 CA0C
tipin_time_sum:     ADD     A, off(00144h)         ; 21A5 1 100 280 8744
                JLT     tipin_time_clamp             ; 21A7 1 100 280 CA08
                ADD     A, off(0014ah)         ; 21A9 1 100 280 874A
                JLT     tipin_time_clamp             ; 21AB 1 100 280 CA04
                ADD     A, off(0014ch)         ; 21AD 1 100 280 874C
                JGE     tipin_time_finalize             ; 21AF 1 100 280 CD03
tipin_time_clamp:     L       A, #0ffffh             ; 21B1 1 100 280 67FFFF
tipin_time_finalize:     ST      A, er0                 ; 21B4 1 100 280 88
                LB      A, off(00148h)         ; 21B5 0 100 280 F448
                EXTND                          ; 21B7 1 100 280 F8
                MOV     er3, off(00146h)       ; 21B8 1 100 280 B4464B
                CAL     signextend_helper             ; 21BB 1 100 280 326C59
                LB      A, off(00149h)         ; 21BE 0 100 280 F449
                EXTND                          ; 21C0 1 100 280 F8
                CAL     signextend_helper             ; 21C1 1 100 280 326C59
                CMP     A, #08000h             ; 21C4 1 100 280 C60080
                JGE     tipin_overflow_check1             ; 21C7 1 100 280 CD05
                ADD     A, er0                 ; 21C9 1 100 280 08
                JGE     tipin_overflow_check2             ; 21CA 1 100 280 CD05
                SJ      tipin_overflow_clamp             ; 21CC 1 100 280 CB08
tipin_overflow_check1:     ADD     A, er0                 ; 21CE 1 100 280 08
                JGE     tipin_result_store             ; 21CF 1 100 280 CD08
tipin_overflow_check2:     CMP     A, #08000h             ; 21D1 1 100 280 C60080
                JLT     tipin_result_store             ; 21D4 1 100 280 CA03
tipin_overflow_clamp:     L       A, #07fffh             ; 21D6 1 100 280 67FF7F
tipin_result_store:     ST      A, er3                 ; 21D9 1 100 280 8B
                MOV     X2, A                  ; 21DA 1 100 280 51
                L       A, off(00140h)         ; 21DB 1 100 280 E440
                MOV     er0, off(00158h)       ; 21DD 1 100 280 B45848
                MUL                            ; 21E0 1 100 280 9035
                SRL     er1                    ; 21E2 1 100 280 45E7
                ROR     A                      ; 21E4 1 100 280 43
                LB      A, r2                  ; 21E5 0 100 280 7A
                L       A, ACC                 ; 21E6 1 100 280 E506
                SWAP                           ; 21E8 1 100 280 83
                CMPB    r3, #000h              ; 21E9 1 100 280 23C000
                JEQ     injtimer_bank_a_calc             ; 21EC 1 100 280 C903
                L       A, #0ffffh             ; 21EE 1 100 280 67FFFF
injtimer_bank_a_calc:     ST      A, er2                 ; 21F1 1 100 280 8A
                XCHG    A, er3                 ; 21F2 1 100 280 4710
                VCAL    4                      ; 21F4 1 100 280 14
                JBR     off(00124h).5, injtimer_bank_a_store ; 21F5 1 100 280 DD2401
                CLR     A                      ; 21F8 1 100 280 F9
injtimer_bank_a_store:     MOV     DP, #003a2h            ; 21F9 1 100 280 62A203
                ST      A, [DP]                ; 21FC 1 100 280 D2
                L       A, er3                 ; 21FD 1 100 280 37
                MOV     DP, #003b4h            ; 21FE 1 100 280 62B403
                MOV     er0, [DP]              ; 2201 1 100 280 B248
                ST      A, [DP]                ; 2203 1 100 280 D2
                JBS     off(00125h).4, injtimer_bank_b_zero ; 2204 1 100 280 EC2518
                JBS     off(0012eh).4, injtimer_bank_b_zero ; 2207 1 100 280 EC2E15
                CMPB    off(00133h), #0a0h     ; 220A 1 100 280 C433C0A0
                JGE     injtimer_bank_b_zero             ; 220E 1 100 280 CD0F
                CMP     off(0014ch), #00000h   ; 2210 1 100 280 B44CC00000
                JNE     injtimer_bank_b_zero             ; 2215 1 100 280 CE08
                SUB     A, er0                 ; 2217 1 100 280 28
                JLT     injtimer_bank_b_zero             ; 2218 1 100 280 CA05
                CMP     A, #000fah             ; 221A 1 100 280 C6FA00
                JGE     injtimer_bank_b_clamp             ; 221D 1 100 280 CD03
injtimer_bank_b_zero:     CLR     A                      ; 221F 1 100 280 F9
                SJ      injtimer_bank_b_store             ; 2220 1 100 280 CB17
injtimer_bank_b_clamp:     MOV     er0, #003e8h           ; 2222 1 100 280 4498E803
                CMP     A, er0                 ; 2226 1 100 280 48
                JGE     injtimer_bank_b_default             ; 2227 1 100 280 CD01
                ST      A, er0                 ; 2229 1 100 280 88
injtimer_bank_b_default:     CLR     A                      ; 222A 1 100 280 F9
                MOVB    ACCH, #066h            ; 222B 1 100 280 C5079866
                MUL                            ; 222F 1 100 280 9035
                SLL     A                      ; 2231 1 100 280 53
                L       A, er1                 ; 2232 1 100 280 35
                ROL     A                      ; 2233 1 100 280 33
                JGE     injtimer_bank_b_store             ; 2234 1 100 280 CD03
                L       A, #0ffffh             ; 2236 1 100 280 67FFFF
injtimer_bank_b_store:     ST      A, off(00150h)         ; 2239 1 100 280 D450
                L       A, off(0014ch)         ; 223B 1 100 280 E44C
                CMP     A, off(00150h)         ; 223D 1 100 280 C750
                MB      off(0012ch).5, C       ; 223F 1 100 280 C42C3D
                JGE     injtimer_bank_c_check             ; 2242 1 100 280 CD02
                L       A, off(00150h)         ; 2244 1 100 280 E450
injtimer_bank_c_check:     L       A, ACC                 ; 2246 1 100 280 E506
                JEQ     injtimer_bank_c_store             ; 2248 1 100 280 C90A
                ADD     A, off(00144h)         ; 224A 1 100 280 8744
                JGE     injtimer_bank_c_scale             ; 224C 1 100 280 CD03
                L       A, #0ffffh             ; 224E 1 100 280 67FFFF
injtimer_bank_c_scale:     CAL     scale_mul5_div4             ; 2251 1 100 280 329159
injtimer_bank_c_store:     MOV     X1, A                  ; 2254 1 100 280 50
                JBR     off(0012ch).5, injtimer_critsection_start ; 2255 1 100 280 DD2C01
                CLR     A                      ; 2258 1 100 280 F9
injtimer_critsection_start:     AND     IE, #002a0h            ; 2259 1 100 280 B51AD0A002
                ANDB    PSWH, #0feh            ; 225E 1 100 280 A2D0FE
                MOV     off(00194h), X1        ; 2261 1 100 280 907C94
                ST      A, off(00190h)         ; 2264 1 100 280 D490
                ST      A, off(00192h)         ; 2266 1 100 280 D492
                ORB     PSWH, #001h            ; 2268 1 100 280 A2E001
                L       A, 0f8h                ; 226B 1 100 280 E5F8
                ST      A, IE                  ; 226D 1 100 280 D51A
                LCB     A, injtimer_critsection_start_tbl            ; 226F 1 100 280 909DF860
                JEQ     injtimer_critsection_start_load_dp_ind             ; 2273 1 100 280 C92A
                MOV     X1, #CylinderIGNCorrect          ; 2275 1 100 280 60C762
cylinder_ign_correct_loop:     INC     DP                     ; 2278 1 100 280 72
                INC     DP                     ; 2279 1 100 280 72
                L       A, er2                 ; 227A 1 100 280 36
                JBR     off(00125h).1, cylinder_ign_correct_apply ; 227B 1 100 280 D9250F
                ST      A, er0                 ; 227E 1 100 280 88
                CLR     A                      ; 227F 1 100 280 F9
                LCB     A, [X1]                ; 2280 1 100 280 90AA
                SWAP                           ; 2282 1 100 280 83
                MUL                            ; 2283 1 100 280 9035
                SLL     A                      ; 2285 1 100 280 53
                L       A, er1                 ; 2286 1 100 280 35
                ROL     A                      ; 2287 1 100 280 33
                JGE     cylinder_ign_correct_apply             ; 2288 1 100 280 CD03
                L       A, #0ffffh             ; 228A 1 100 280 67FFFF
cylinder_ign_correct_apply:     MOV     er3, X2                ; 228D 1 100 280 914B
                XCHG    A, er3                 ; 228F 1 100 280 4710
                VCAL    4                      ; 2291 1 100 280 14
                CAL     scale_mul5_div4             ; 2292 1 100 280 329159
                ST      A, [DP]                ; 2295 1 100 280 D2
                INC     X1                     ; 2296 1 100 280 70
                CMP     DP, #003bch            ; 2297 1 100 280 92C0BC03
                JLT     cylinder_ign_correct_loop             ; 229B 1 100 280 CADB
                SJ      postinj_rpm_check             ; 229D 1 100 280 CB12
injtimer_critsection_start_load_dp_ind:     L       A, [DP]                ; 229F 1 100 280 E2
                CAL     scale_mul5_div4             ; 22A0 1 100 280 329159
                CLR     X1                     ; 22A3 1 100 280 9015
                ST      A, 003b6h[X1]          ; 22A5 1 100 280 D0B603
                ST      A, 003b8h[X1]          ; 22A8 1 100 280 D0B803
                ST      A, 003bah[X1]          ; 22AB 1 100 280 D0BA03
                ST      A, 003bch[X1]          ; 22AE 1 100 280 D0BC03
postinj_rpm_check:     LB      A, #0c5h               ; 22B1 0 100 280 77C5
                JBS     off(0012bh).2, postinj_rpm_flag_store ; 22B3 0 100 280 EA2B02
                LB      A, #0c8h               ; 22B6 0 100 280 77C8
postinj_rpm_flag_store:     CMPB    A, off(00133h)         ; 22B8 0 100 280 C733
                MB      off(0012bh).2, C       ; 22BA 0 100 280 C42B3A
                LB      A, off(0013dh)         ; 22BD 0 100 280 F43D
                JNE     deadtime_retry_check             ; 22BF 0 100 280 CE57
                LB      A, #005h               ; 22C1 0 100 280 7705
                JBS     off(00125h).4, deadtime_retry_store_goto_injector_effective_pw_store ; 22C3 0 100 280 EC255F
                MOVB    r6, #007h              ; 22C6 0 100 280 9E07
                L       A, off(0011ah)         ; 22C8 1 100 280 E41A
                AND     A, #01034h             ; 22CA 1 100 280 D63410
                JNE     to_gio_mode_dispatch             ; 22CD 1 100 280 CE58
                MOVB    r6, #006h              ; 22CF 1 100 280 9E06
                JBS     off(0011fh).5, to_gio_mode_dispatch ; 22D1 1 100 280 ED1F53
                MOVB    r6, #006h              ; 22D4 1 100 280 9E06
                JBS     off(0012ch).5, to_gio_mode_dispatch ; 22D6 1 100 280 ED2C4E
                CMPB    0d9h, #02eh            ; 22D9 1 100 280 C5D9C02E
                JGE     deadtime_ect_offset             ; 22DD 1 100 280 CD05
                MOVB    r6, #007h              ; 22DF 1 100 280 9E07
                JBS     off(00120h).0, to_gio_mode_dispatch ; 22E1 1 100 280 E82043
deadtime_ect_offset:     CLR     DP                     ; 22E4 1 100 280 9215
                LB      A, 0d9h                ; 22E6 0 100 280 F5D9
                CMPB    A, #0aeh               ; 22E8 0 100 280 C6AE
                JLT     deadtime_ect_offset_load_imm             ; 22EA 0 100 280 CA04
                ADD     DP, #00003h            ; 22EC 0 100 280 92800300
deadtime_ect_offset_load_imm:     LB      A, #038h               ; 22F0 0 100 280 7738
                JBS     off(0012bh).1, deadtime_ect_offset_cmp_ram0be ; 22F2 0 100 280 E92B02
                LB      A, #030h               ; 22F5 0 100 280 7730
deadtime_ect_offset_cmp_ram0be:     CMPB    0beh, A                ; 22F7 0 100 280 C5BEC1
                MB      off(0012bh).1, C       ; 22FA 0 100 280 C42B39
                LB      A, #077h               ; 22FD 0 100 280 7777
                JBS     off(0012bh).0, deadtime_voltage_flag_store ; 22FF 0 100 280 E82B02
                LB      A, #070h               ; 2302 0 100 280 7770
deadtime_voltage_flag_store:     CMPB    0beh, A                ; 2304 0 100 280 C5BEC1
                MB      off(0012bh).0, C       ; 2307 0 100 280 C42B38
                JGE     deadtime_voltage_flag_store_rom_load_tbl_6106_dp             ; 230A 0 100 280 CD05
                INC     DP                     ; 230C 0 100 280 72
                JBR     off(0012bh).1, deadtime_voltage_flag_store_rom_load_tbl_6106_dp ; 230D 0 100 280 D92B01
                INC     DP                     ; 2310 0 100 280 72
deadtime_voltage_flag_store_rom_load_tbl_6106_dp:     LCB     A, deadtime_voltage_flag_store_tbl[DP]        ; 2311 0 100 280 92AB0661
                STB     A, r6                  ; 2315 0 100 280 8E
                SJ      to_gio_mode_dispatch             ; 2316 0 100 280 CB0F
deadtime_retry_check:     MB      C, 0b7h.0              ; 2318 0 100 280 C5B728
; [H] --- Injector deadtime/battery-voltage compensation (0x21A5-0x2225ish): selects an ECT/
; [H] battery-voltage-indexed offset into InjectorTable (real calibration field -- injector-size
; [H] dependent deadtime compensation), applies it, then computes effective injector pulse width
; [H] after subtracting deadtime.
                JGE     deadtime_retry_store             ; 231B 0 100 280 CD02
                LB      A, #005h               ; 231D 0 100 280 7705
deadtime_retry_store:     SUBB    A, #001h               ; 231F 0 100 280 A601
                STB     A, off(0013dh)         ; 2321 0 100 280 D43D
                LB      A, #00bh               ; 2323 0 100 280 770B
deadtime_retry_store_goto_injector_effective_pw_store:     SJ      injector_effective_pw_store             ; 2325 0 100 280 CB43
to_gio_mode_dispatch:     MOV     DP, #003b4h            ; 2327 1 100 280 62B403
                L       A, [DP]                ; 232A 1 100 280 E2
                CAL     scale_mul5_div4             ; 232B 1 100 280 329159
                CLR     er0                    ; 232E 1 100 280 4415
                MOV     er2, off(00136h)       ; 2330 1 100 280 B4364A
                DIV                            ; 2333 1 100 280 9037
                JLT     injector_effective_pw_skip             ; 2335 1 100 280 CA32
                CMP     A, #0000bh             ; 2337 1 100 280 C60B00
                JGT     injector_effective_pw_skip             ; 233A 1 100 280 C82D
                LB      A, ACC                 ; 233C 0 100 280 F506
                XCHGB   A, r6                  ; 233E 0 100 280 2610
                SUBB    A, r6                  ; 2340 0 100 280 2E
                JLT     injector_effective_pw_skip             ; 2341 0 100 280 CA26
                JBS     off(0012bh).2, injector_effective_pw_calc ; 2343 0 100 280 EA2B21
                MOVB    r6, off(0013bh)        ; 2346 0 100 280 C43B4E
                SUBB    r6, #001h              ; 2349 0 100 280 26A001
                JLT     injector_effective_pw_calc             ; 234C 0 100 280 CA19
                CMPB    A, r6                  ; 234E 0 100 280 4E
                JNE     injector_effective_pw_calc             ; 234F 0 100 280 CE16
                MOV     X1, er1                ; 2351 0 100 280 4578
                STB     A, r6                  ; 2353 0 100 280 8E
                L       A, #08000h             ; 2354 1 100 280 670080
                MOV     er0, er2               ; 2357 1 100 280 4648
                MUL                            ; 2359 1 100 280 9035
                L       A, er1                 ; 235B 1 100 280 35
                CMP     A, X1                  ; 235C 1 100 280 90C2
                LB      A, r6                  ; 235E 0 100 280 7E
                JLT     injector_effective_pw_calc             ; 235F 0 100 280 CA06
                CMPB    A, #00bh               ; 2361 0 100 280 C60B
                JGE     injector_effective_pw_calc             ; 2363 0 100 280 CD02
                ADDB    A, #001h               ; 2365 0 100 280 8601
injector_effective_pw_calc:     SJ      injector_effective_pw_store             ; 2367 0 100 280 CB01
injector_effective_pw_skip:     CLRB    A                      ; 2369 0 100 280 FA
injector_effective_pw_store:     STB     A, off(0013bh)         ; 236A 0 100 280 D43B
                LB      A, #0c2h               ; 236C 0 100 280 77C2
                JBS     off(00124h).0, rpm_hyst_flag_124_0 ; 236E 0 100 280 E82402
                LB      A, #0c5h               ; 2371 0 100 280 77C5
rpm_hyst_flag_124_0:     CMPB    A, off(00133h)         ; 2373 0 100 280 C733
                MB      off(00124h).0, C       ; 2375 0 100 280 C42438
                LB      A, #0edh               ; 2378 0 100 280 77ED
                JBS     off(00124h).1, rpm_hyst_flag_124_1 ; 237A 0 100 280 E92402
                LB      A, #0f0h               ; 237D 0 100 280 77F0
rpm_hyst_flag_124_1:     CMPB    A, off(00133h)         ; 237F 0 100 280 C733
                MB      off(00124h).1, C       ; 2381 0 100 280 C42439
                JBR     off(00121h).3, crank_edge_carry_clear ; 2384 0 100 280 DB213E
                JBR     off(0011eh).6, crank_edge_carry_clear ; 2387 0 100 280 DE1E3B
                LB      A, off(001e1h)         ; 238A 0 100 280 F4E1
                JNE     crank_edge_carry_clear             ; 238C 0 100 280 CE37
                JBR     off(00121h).2, crank_edge_carry_clear ; 238E 0 100 280 DA2134
                MOV     DP, #00f00h            ; 2391 0 100 280 62000F
                LB      A, [DP]                ; 2394 0 100 280 F2
                ANDB    A, #040h               ; 2395 0 100 280 D640
                MB      C, 0b8h.2              ; 2397 0 100 280 C5B82A
                JLT     crank_edge_sync_check             ; 239A 0 100 280 CA1B
                JNE     crank_edge_carry_set             ; 239C 0 100 280 CE2A
                RB      P1.2                   ; 239E 0 100 280 C5220A
                L       A, 0fah                ; 23A1 1 100 280 E5FA
                ST      A, IE                  ; 23A3 1 100 280 D51A
                ANDB    PSWH, #0feh            ; 23A5 1 100 280 A2D0FE
                LB      A, P1                  ; 23A8 0 100 280 F522
                MOV     DP, #02f00h            ; 23AA 0 100 280 62002F
                STB     A, [DP]                ; 23AD 0 100 280 D2
                ORB     PSWH, #001h            ; 23AE 0 100 280 A2E001
                L       A, 0f8h                ; 23B1 1 100 280 E5F8
                ST      A, IE                  ; 23B3 1 100 280 D51A
                SJ      crank_edge_direction_toggle             ; 23B5 1 100 280 CB02
crank_edge_sync_check:     JEQ     crank_edge_carry_set             ; 23B7 0 100 280 C90F
crank_edge_direction_toggle:     XORB    PSWH, #080h            ; 23B9 0 100 280 A2F080
                MB      0b8h.2, C              ; 23BC 0 100 280 C5B83A
                JGE     crank_edge_carry_clear             ; 23BF 0 100 280 CD04
                MOVB    off(001e1h), #019h     ; 23C1 0 100 280 C4E19819
crank_edge_carry_clear:     RC                             ; 23C5 0 100 280 95
                SJ      dtc27_code27_latch             ; 23C6 0 100 280 CB01
crank_edge_carry_set:     SC                             ; 23C8 0 100 280 85
dtc27_code27_latch:     MB      0b3h.2, C              ; 23C9 0 100 280 C5B33A
                JBR     off(0011eh).7, crank_edge_flag_store_clear_acc ; 23CC 0 100 280 DF1E79
                JBS     off(00125h).4, crank_edge_flag_store_clear_acc ; 23CF 0 100 280 EC2576
                LB      A, #001h               ; 23D2 0 100 280 7701
                JBS     off(00131h).3, crank_edge_flag_store_cmp_ram0d9 ; 23D4 0 100 280 EB3102
                LB      A, #000h               ; 23D7 0 100 280 7700
crank_edge_flag_store_cmp_ram0d9:     CMPB    0d9h, A                ; 23D9 0 100 280 C5D9C1
                MB      off(00131h).3, C       ; 23DC 0 100 280 C4313B
                LB      A, #0ffh               ; 23DF 0 100 280 77FF
                JBS     off(00131h).4, crank_edge_flag_store_cmp_acc ; 23E1 0 100 280 EC3102
                LB      A, #0ffh               ; 23E4 0 100 280 77FF
crank_edge_flag_store_cmp_acc:     CMPB    A, off(00132h)         ; 23E6 0 100 280 C732
                MB      off(00131h).4, C       ; 23E8 0 100 280 C4313C
                LB      A, #0ffh               ; 23EB 0 100 280 77FF
                JBS     off(00131h).5, crank_edge_flag_store_cmp_ram0be ; 23ED 0 100 280 ED3102
                LB      A, #0ffh               ; 23F0 0 100 280 77FF
crank_edge_flag_store_cmp_ram0be:     CMPB    0beh, A                ; 23F2 0 100 280 C5BEC1
                MB      off(00131h).5, C       ; 23F5 0 100 280 C4313D
                LB      A, #000h               ; 23F8 0 100 280 7700
                JBS     off(00124h).7, crank_edge_flag_store_cmp_acc_2 ; 23FA 0 100 280 EF2402
                LB      A, #001h               ; 23FD 0 100 280 7701
crank_edge_flag_store_cmp_acc_2:     CMPB    A, off(00133h)         ; 23FF 0 100 280 C733
                MB      off(00124h).7, C       ; 2401 0 100 280 C4243F
                MOV     DP, #003abh            ; 2404 0 100 280 62AB03
                LB      A, [DP]                ; 2407 0 100 280 F2
                CMPB    A, #032h               ; 2408 0 100 280 C632
                JNE     crank_edge_flag_store_if_ram124_bit7_set             ; 240A 0 100 280 CE0A
                MOV     X1, #crank_edge_flag_store_tbl          ; 240C 0 100 280 60896F
                LB      A, off(00133h)         ; 240F 0 100 280 F433
                CAL     table_interp_lookup             ; 2411 0 100 280 323958
                SJ      crank_edge_flag_store_clear_carry             ; 2414 0 100 280 CB33
crank_edge_flag_store_if_ram124_bit7_set:     JBS     off(00124h).7, crank_edge_flag_store_clear_acc ; 2416 0 100 280 EF242F
                JBS     off(0011fh).5, crank_edge_flag_store_clear_acc ; 2419 0 100 280 ED1F2C
                L       A, off(0011ah)         ; 241C 1 100 280 E41A
                AND     A, #0907ch             ; 241E 1 100 280 D67C90
                JNE     crank_edge_flag_store_clear_acc             ; 2421 1 100 280 CE25
                JBR     off(0011bh).3, crank_edge_flag_store_if_ram124_bit2_set ; 2423 1 100 280 DB1B0D
                JBR     off(00122h).5, crank_edge_flag_store_clear_acc ; 2426 1 100 280 DD221F
                LB      A, (0029eh-00280h)[USP] ; 2429 0 100 280 F31E
                CMPB    A, #0ffh               ; 242B 0 100 280 C6FF
                JLT     crank_edge_flag_store_clear_acc             ; 242D 0 100 280 CA19
                CMPB    A, #0ffh               ; 242F 0 100 280 C6FF
                JGT     crank_edge_flag_store_clear_acc             ; 2431 0 100 280 C815
crank_edge_flag_store_if_ram124_bit2_set:     JBS     off(00124h).2, crank_edge_flag_store_clear_acc ; 2433 0 100 280 EA2412
                JBS     off(00125h).5, crank_edge_flag_store_clear_acc ; 2436 0 100 280 ED250F
                JBR     off(00120h).2, crank_edge_flag_store_clear_acc ; 2439 0 100 280 DA200C
                J       crank_edge_flag_store_load_carry_stk             ; 243C 0 100 280 039F79
crank_edge_flag_store_if_ram11d_bit2_set:     JBS     off(0011dh).2, crank_edge_flag_store_if_ram125_bit2_clr ; 243F 0 100 280 EA1D0A
                JBS     off(0011dh).4, crank_edge_flag_store_if_ram125_bit2_clr ; 2442 0 100 280 EC1D07
                JBS     off(00125h).1, crank_edge_flag_store_if_ram131_bit3_clr ; 2445 0 100 280 E92507
crank_edge_flag_store_clear_acc:     CLRB    A                      ; 2448 0 100 280 FA
crank_edge_flag_store_clear_carry:     RC                             ; 2449 0 100 280 95
                SJ      crank_edge_flag_store_store_carry_ram125_bit6             ; 244A 0 100 280 CB75
crank_edge_flag_store_if_ram125_bit2_clr:     JBR     off(00125h).2, crank_edge_flag_store_clear_acc ; 244C 0 100 280 DA25F9
crank_edge_flag_store_if_ram131_bit3_clr:     JBR     off(00131h).3, crank_edge_flag_store_clear_acc ; 244F 0 100 280 DB31F6
                JBR     off(00131h).4, crank_edge_flag_store_clear_acc ; 2452 0 100 280 DC31F3
                JBS     off(00131h).5, crank_edge_flag_store_clear_acc ; 2455 0 100 280 ED31F0
                MOVB    r3, off(001c8h)        ; 2458 0 100 280 C4C84B
                MOVB    r2, off(00133h)        ; 245B 0 100 280 C4334A
                MOVB    r6, #012h              ; 245E 0 100 280 9E12
                MB      C, 0b8h.4              ; 2460 0 100 280 C5B82C
                MB      PSWL.4, C              ; 2463 0 100 280 A33C
                MOV     X1, #crank_edge_flag_store_tbl_3          ; 2465 0 100 280 603C70
                CAL     newval_table3_call_sub_clear_acc             ; 2468 0 100 280 32B259
                MOV     X2, A                  ; 246B 0 100 280 51
                LB      A, r6                  ; 246C 0 100 280 7E
                STB     A, off(001c8h)         ; 246D 0 100 280 D4C8
                MOVB    r2, 0bfh               ; 246F 0 100 280 C5BF4A
                MOV     X1, #crank_edge_flag_store_tbl_2          ; 2472 0 100 280 600A70
                MOVB    r3, off(001bdh)        ; 2475 0 100 280 C4BD4B
                MOVB    r6, #008h              ; 2478 0 100 280 9E08
                RB      PSWL.4                 ; 247A 0 100 280 A30C
                CAL     newval_table3_call_sub_clear_acc             ; 247C 0 100 280 32B259
                MOVB    off(001bdh), r6        ; 247F 0 100 280 267CBD
                MOVB    r0, #00ah              ; 2482 0 100 280 980A
                MOVB    r1, #014h              ; 2484 0 100 280 9914
                MOVB    r3, off(001c8h)        ; 2486 0 100 280 C4C84B
                MOVB    r2, r6                 ; 2489 0 100 280 264A
                MOV     er3, X2                ; 248B 0 100 280 914B
                MOV     X2, A                  ; 248D 0 100 280 51
                MOV     X1, #crank_edge_flag_store_tbl_4          ; 248E 0 100 280 60E076
                RB      PSWL.5                 ; 2491 0 100 280 A30D
                CAL     table2d_lookup_interp             ; 2493 0 100 280 32E459
                LCB     A, fuelmap_base_lookup_tbl            ; 2496 0 100 280 909DE560
                MOVB    A, r4                  ; 249A 0 100 280 2499
                JEQ     crank_edge_flag_store_store_r0             ; 249C 0 100 280 C912
                LB      A, (0029dh-00280h)[USP] ; 249E 0 100 280 F31D
                MB      C, ACC.7               ; 24A0 0 100 280 C5062F
                JGE     crank_edge_flag_store_addb_acc             ; 24A3 0 100 280 CD06
                ADDB    A, r4                  ; 24A5 0 100 280 0C
                JLT     crank_edge_flag_store_store_r0             ; 24A6 0 100 280 CA08
                CLRB    A                      ; 24A8 0 100 280 FA
                SJ      crank_edge_flag_store_store_r0             ; 24A9 0 100 280 CB05
crank_edge_flag_store_addb_acc:     ADDB    A, r4                  ; 24AB 0 100 280 0C
                JGE     crank_edge_flag_store_store_r0             ; 24AC 0 100 280 CD02
                LB      A, #0ffh               ; 24AE 0 100 280 77FF
crank_edge_flag_store_store_r0:     STB     A, r0                  ; 24B0 0 100 280 88
                MOV     DP, #00392h            ; 24B1 0 100 280 629203
                LB      A, [DP]                ; 24B4 0 100 280 F2
                L       A, ACC                 ; 24B5 1 100 280 E506
                MULB                           ; 24B7 1 100 280 A234
                SLL     A                      ; 24B9 1 100 280 53
                LB      A, ACCH                ; 24BA 0 100 280 F507
                JGE     crank_edge_flag_store_set_carry             ; 24BC 0 100 280 CD02
                LB      A, #0ffh               ; 24BE 0 100 280 77FF
crank_edge_flag_store_set_carry:     SC                             ; 24C0 0 100 280 85
crank_edge_flag_store_store_carry_ram125_bit6:     MB      off(00125h).6, C       ; 24C1 0 100 280 C4253E
                STB     A, (0029fh-00280h)[USP] ; 24C4 0 100 280 D31F
                CAL     crank_edge_helper             ; 24C6 0 100 280 32225C
                SB      0b6h.4                 ; 24C9 0 100 280 C5B61C
                L       A, 0fah                ; 24CC 1 100 280 E5FA
                ST      A, IE                  ; 24CE 1 100 280 D51A
                ANDB    PSWH, #0feh            ; 24D0 1 100 280 A2D0FE
                J       int1_rti_epilogue             ; 24D3 1 100 280 03A106
; [flow] int_spurious_irq_trap: every interrupt vector this ROM never enables points here. It stamps trap
;    reason 045h and goes through fault_retry_check (retry budget, then BRK -> int_break re-init).
int_spurious_irq_trap:  MOVB    0f5h, #045h            ; 24D6 0 ??? ??? C5F59845
                SJ      fault_retry_check             ; 24DA 0 ??? ??? CB04
int_WDT:        MOVB    0f5h, #044h            ; 24DC 0 ??? ??? C5F59844
fault_retry_check:     LB      A, 0f6h                ; 24E0 0 ??? ??? F5F6
                JEQ     fault_giveup_latch             ; 24E2 0 ??? ??? C905
                DECB    0f6h                   ; 24E4 0 ??? ??? C5F617
                JNE     fault_trigger_brk             ; 24E7 0 ??? ??? CE03
fault_giveup_latch:     SB      0b7h.1                 ; 24E9 0 ??? ??? C5B719
fault_trigger_brk:     BRK                            ; 24EC 0 ??? ??? FF
int_start:      MOVB    0f5h, #046h            ; 24ED 0 ??? ??? C5F59846
                RB      0b7h.1                 ; 24F1 0 ??? ??? C5B709
int_break:      MOVB    WDT, #03ch             ; 24F4 0 ??? ??? C511983C
                MOV     SSP, #0047eh           ; 24F8 0 ??? ??? A0987E04
                MOV     LRB, #00010h           ; 24FC 0 080 ??? 571000
                CLR     off(PSW)               ; 24FF 0 080 ??? B40415
                LB      A, off(000f5h)         ; 2502 0 080 ??? F4F5
                STB     A, off(000afh)         ; 2504 0 080 ??? D4AF
                JNE     breset_check_reason_46_47             ; 2506 0 080 ??? CE06
                MOVB    off(000f5h), #04eh     ; 2508 0 080 ??? C4F5984E
                SJ      fault_retry_check             ; 250C 0 080 ??? CBD2
breset_check_reason_46_47:     CMPB    A, #046h               ; 250E 0 080 ??? C646
                JEQ     breset_reason_46_or_47_common             ; 2510 0 080 ??? C904
                CMPB    A, #047h               ; 2512 0 080 ??? C647
                JNE     breset_check_p4_1             ; 2514 0 080 ??? CE12
breset_reason_46_or_47_common:     CLRB    off(000afh)            ; 2516 0 080 ??? C4AF15
                MOV     DP, #04700h            ; 2519 0 080 ??? 620047
                LB      A, [DP]                ; 251C 0 080 ??? F2
                SRLB    A                      ; 251D 0 080 ??? 63
                MB      off(000b7h).0, C       ; 251E 0 080 ??? C4B738
                JBS     off(000b7h).1, breset_check_p4_1 ; 2521 0 080 ??? E9B704
                MOVB    off(000f6h), #020h     ; 2524 0 080 ??? C4F69820
breset_check_p4_1:     JBR     off(P4).1, selftest_reg_stuckbit_check  ; 2528 0 080 ??? D92C03
                J       int_NMI                ; 252B 0 080 ??? 033C00
selftest_reg_stuckbit_check:     L       A, #05555h             ; 252E 1 080 ??? 675555
                XCHG    A, SSP                 ; 2531 1 080 ??? A010
                XCHG    A, SSP                 ; 2533 1 080 ??? A010
                CMP     A, #05555h             ; 2535 1 080 ??? C65555
                JNE     selftest_fail_041             ; 2538 1 080 ??? CE5E
                ST      A, IE                  ; 253A 1 080 ??? D51A
                CMP     A, IE                  ; 253C 1 080 ??? B51AC2
                JNE     selftest_fail_041             ; 253F 1 080 ??? CE57
                L       A, #01555h             ; 2541 1 080 ??? 675515
                MOV     LRB, A                 ; 2544 1 080 ??? A48A
                CMP     A, LRB                 ; 2546 1 080 ??? A4C2
                JNE     selftest_fail_041             ; 2548 1 080 ??? CE4E
                L       A, #0aaaah             ; 254A 1 080 ??? 67AAAA
                XCHG    A, SSP                 ; 254D 1 080 ??? A010
                XCHG    A, SSP                 ; 254F 1 080 ??? A010
                CMP     A, #0aaaah             ; 2551 1 080 ??? C6AAAA
                JNE     selftest_fail_041             ; 2554 1 080 ??? CE42
                ST      A, IE                  ; 2556 1 080 ??? D51A
                CMP     A, IE                  ; 2558 1 080 ??? B51AC2
                JNE     selftest_fail_041             ; 255B 1 080 ??? CE3B
                L       A, #00aaah             ; 255D 1 080 ??? 67AA0A
                MOV     LRB, A                 ; 2560 1 080 ??? A48A
                CMP     A, LRB                 ; 2562 1 080 ??? A4C2
                JNE     selftest_fail_041             ; 2564 1 080 ??? CE32
                CLR     A                      ; 2566 1 080 ??? F9
                ST      A, IE                  ; 2567 1 080 ??? D51A
                ST      A, 0f8h                ; 2569 1 080 ??? D5F8
                ST      A, 0fah                ; 256B 1 080 ??? D5FA
                MOV     LRB, #00010h           ; 256D 1 080 ??? 571000
                LB      A, #055h               ; 2570 0 080 ??? 7755
                XCHGB   A, PSWL                ; 2572 0 080 ??? A310
                XCHGB   A, PSWL                ; 2574 0 080 ??? A310
                CMPB    A, #0ddh               ; 2576 0 080 ??? C6DD
                JNE     selftest_fail_041             ; 2578 0 080 ??? CE1E
                LB      A, #0aah               ; 257A 0 080 ??? 77AA
                XCHGB   A, PSWL                ; 257C 0 080 ??? A310
                XCHGB   A, PSWL                ; 257E 0 080 ??? A310
                CMPB    A, #0eah               ; 2580 0 080 ??? C6EA
                JNE     selftest_fail_041             ; 2582 0 080 ??? CE14
                SB      PSWH.0                 ; 2584 0 080 ??? A218
                MB      C, PSWH.0              ; 2586 0 080 ??? A228
                MB      PSWH.6, C              ; 2588 0 080 ??? A23E
                JGE     selftest_fail_041             ; 258A 0 080 ??? CD0C
                JNE     selftest_fail_041             ; 258C 0 080 ??? CE0A
                RB      PSWH.0                 ; 258E 0 080 ??? A208
                MB      C, PSWH.0              ; 2590 0 080 ??? A228
                MB      PSWH.6, C              ; 2592 0 080 ??? A23E
                JLT     selftest_fail_041             ; 2594 0 080 ??? CA02
                JNE     periph_init_start             ; 2596 0 080 ??? CE05
selftest_fail_041:     MOVB    0f5h, #041h            ; 2598 0 080 ??? C5F59841
                BRK                            ; 259C 0 080 ??? FF
periph_init_start:     CLRB    off(PRPHF)             ; 259D 0 080 ??? C41215
                LB      A, #0ffh               ; 25A0 0 080 ??? 77FF
                MOVB    off(P0), #0ebh         ; 25A2 0 080 ??? C42098EB
                STB     A, off(P0IO)           ; 25A6 0 080 ??? D421
                MOVB    off(P1), #044h         ; 25A8 0 080 ??? C4229844
                STB     A, off(P1IO)           ; 25AC 0 080 ??? D423
                MOVB    off(P2), #01fh         ; 25AE 0 080 ??? C424981F
                STB     A, off(P2IO)           ; 25B2 0 080 ??? D425
                CLRB    off(P2SF)              ; 25B4 0 080 ??? C42615
                MOVB    off(P3), #0efh         ; 25B7 0 080 ??? C42898EF
                MOVB    off(TCON0), #08bh      ; 25BB 0 080 ??? C440988B
                CLR     A                      ; 25BF 1 080 ??? F9
                ST      A, off(TM0)            ; 25C0 1 080 ??? D430
                ST      A, off(TMR0)           ; 25C2 1 080 ??? D432
                MOVB    off(TCON1), #04fh      ; 25C4 1 080 ??? C441984F
                ST      A, off(TM1)            ; 25C8 1 080 ??? D434
                ST      A, off(TMR1)           ; 25CA 1 080 ??? D436
                MOVB    off(TCON2), #082h      ; 25CC 1 080 ??? C4429882
                ST      A, off(TM2)            ; 25D0 1 080 ??? D438
                ST      A, off(TMR2)           ; 25D2 1 080 ??? D43A
                MOVB    off(TCON3), #08fh      ; 25D4 1 080 ??? C443988F
                MOV     off(TM3), #00001h      ; 25D8 1 080 ??? B43C980100
                ST      A, off(TMR3)           ; 25DD 1 080 ??? D43E
                MOVB    off(P3IO), #0b1h       ; 25DF 1 080 ??? C42998B1
                MOVB    off(P3SF), #0ffh       ; 25E3 1 080 ??? C42A98FF
                CLRB    off(EXION)             ; 25E7 1 080 ??? C41C15
                SB      off(TCON0).2           ; 25EA 1 080 ??? C4401A
                RB      off(TCON0).2           ; 25ED 1 080 ??? C4400A
                MOVB    off(P4), #0f7h         ; 25F0 1 080 ??? C42C98F7
                L       A, #0ff00h             ; 25F4 1 080 ??? 6700FF
                MOVB    off(PWCON0), #03eh     ; 25F7 1 080 ??? C478983E
                ST      A, off(PWMC0)          ; 25FB 1 080 ??? D470
                ST      A, off(PWMR0)          ; 25FD 1 080 ??? D472
                MOVB    off(PWCON1), #07eh     ; 25FF 1 080 ??? C47A987E
                ST      A, off(PWMC1)          ; 2603 1 080 ??? D474
                ST      A, off(PWMR1)          ; 2605 1 080 ??? D476
                MOVB    off(P4IO), #00dh       ; 2607 1 080 ??? C42D980D
                MOVB    off(P4SF), #0fch       ; 260B 1 080 ??? C42E98FC
                SB      off(TCON0).4           ; 260F 1 080 ??? C4401C
                SB      off(TCON1).4           ; 2612 1 080 ??? C4411C
                SB      off(TCON2).4           ; 2615 1 080 ??? C4421C
                XCHG    A, ACC                 ; 2618 1 080 ??? B50610
                SB      off(TCON3).4           ; 261B 1 080 ??? C4431C
                CLR     off(IRQ)               ; 261E 1 080 ??? B41815
                LB      A, #002h               ; 2621 0 080 ??? 7702
periph_init_delay_loop_load_dp:     MOV     DP, #00177h            ; 2623 0 080 ??? 627701
periph_init_delay_loop:     DEC     DP                     ; 2626 0 080 ??? 82
                JEQ     periph_init_delay_loop_load_ram0f5             ; 2627 0 080 ??? C927
                MBR     C, off(P4)             ; 2629 0 080 ??? C42C21
                JLT     periph_init_delay_loop             ; 262C 0 080 ??? CAF8
                MOV     DP, #00177h            ; 262E 0 080 ??? 627701
periph_init_delay_loop_dec_dp:     DEC     DP                     ; 2631 0 080 ??? 82
                JEQ     periph_init_delay_loop_load_ram0f5             ; 2632 0 080 ??? C91C
                MBR     C, off(P4)             ; 2634 0 080 ??? C42C21
                JGE     periph_init_delay_loop_dec_dp             ; 2637 0 080 ??? CDF8
                MOV     DP, #000b2h            ; 2639 0 080 ??? 62B200
periph_init_delay_loop_dec_dp_2:     DEC     DP                     ; 263C 0 080 ??? 82
                JEQ     periph_init_delay_loop_load_ram0f5             ; 263D 0 080 ??? C911
                MBR     C, off(P4)             ; 263F 0 080 ??? C42C21
                JLT     periph_init_delay_loop_dec_dp_2             ; 2642 0 080 ??? CAF8
                INCB    ACC                    ; 2644 0 080 ??? C50616
                CMPB    A, #004h               ; 2647 0 080 ??? C604
                JNE     periph_init_delay_loop_load_dp             ; 2649 0 080 ??? CED8
                RB      off(IRQH).5            ; 264B 0 080 ??? C4190D
                JNE     periph_init_delay_loop_load_imm             ; 264E 0 080 ??? CE05
periph_init_delay_loop_load_ram0f5:     MOVB    off(000f5h), #04ch     ; 2650 0 080 ??? C4F5984C
                BRK                            ; 2654 0 080 ??? FF
periph_init_delay_loop_load_imm:     L       A, #0ffffh             ; 2655 1 080 ??? 67FFFF
                ST      A, off(PWMR0)          ; 2658 1 080 ??? D472
                ST      A, off(PWMR1)          ; 265A 1 080 ??? D476
                RB      off(P4SF).3            ; 265C 1 080 ??? C42E0B
                L       A, #05555h             ; 265F 1 080 ??? 675555
                MOV     X1, A                  ; 2662 1 080 ??? 50
                CMP     A, X1                  ; 2663 1 080 ??? 90C2
                JNE     selftest_fail_042             ; 2665 1 080 ??? CE10
                MOV     X2, A                  ; 2667 1 080 ??? 51
                CMP     A, X2                  ; 2668 1 080 ??? 91C2
                JNE     selftest_fail_042             ; 266A 1 080 ??? CE0B
                SLL     A                      ; 266C 1 080 ??? 53
                MOV     X1, A                  ; 266D 1 080 ??? 50
                CMP     A, X1                  ; 266E 1 080 ??? 90C2
                JNE     selftest_fail_042             ; 2670 1 080 ??? CE05
                MOV     X2, A                  ; 2672 1 080 ??? 51
                CMP     A, X2                  ; 2673 1 080 ??? 91C2
                JEQ     ram_clear_loop1             ; 2675 1 080 ??? C905
selftest_fail_042:     MOVB    off(000f5h), #042h     ; 2677 1 080 ??? C4F59842
                BRK                            ; 267B 1 080 ??? FF
ram_clear_loop1:     MOV     LRB, #00040h           ; 267C 1 200 ??? 574000
                MOV     X1, #003fah            ; 267F 1 200 ??? 60FA03
ram_clear_loop1_body:     MOV     DP, 00084h[X1]         ; 2682 1 200 ??? B084007A
                L       A, #05555h             ; 2686 1 200 ??? 675555
                CAL     selftest_regbank_verify             ; 2689 1 200 ??? 325C5C
                SLL     A                      ; 268C 1 200 ??? 53
                CAL     selftest_regbank_verify             ; 268D 1 200 ??? 325C5C
                SUB     X1, #00002h            ; 2690 1 200 ??? 90A00200
                JGE     ram_clear_loop1_body             ; 2694 1 200 ??? CDEC
                MOV     LRB, #00041h           ; 2696 1 208 ??? 574100
                CMPB    0f5h, #047h            ; 2699 1 208 ??? C5F5C047
                JNE     restore_trapstate_after_ramclear             ; 269D 1 208 ??? CE51
                J       ram_clear_loop1_body_load_dp             ; 269F 1 208 ??? 03AD79
cfgvariant_set_bit0_from_2edh_3_if_ram232_bit5_clr:     JBR     off(00232h).5, cfgvariant_check_320h_bit7 ; 26A2 1 208 ??? DD3229
                CLR     A                      ; 26A5 1 208 ??? F9
                LB      A, r6                  ; 26A6 0 208 ??? 7E
                CAL     cfgvariant_set_flags             ; 26A7 0 208 ??? 327E5B
                CMPB    r6, #018h              ; 26AA 0 208 ??? 26C018
                JEQ     cfgvariant_index_lookup             ; 26AD 0 208 ??? C90C
                CAL     cfgvariant_eval_condition             ; 26AF 0 208 ??? 321D5D
                CAL     cfgvariant_snapshot_capture             ; 26B2 0 208 ??? 32895E
                CAL     cfgvariant_checksum2_calc             ; 26B5 0 208 ??? 322D5F
                INC     DP                     ; 26B8 0 208 ??? 72
                L       A, er0                 ; 26B9 1 208 ??? 34
                ST      A, [DP]                ; 26BA 1 208 ??? D2
cfgvariant_index_lookup:     CLR     A                      ; 26BB 1 208 ??? F9
                LB      A, r7                  ; 26BC 0 208 ??? 7F
                LCB     A, cfgvariant_index_lookup_tbl[ACC]       ; 26BD 0 208 ??? B506AB556F
                CMPB    A, r6                  ; 26C2 0 208 ??? 4E
                JEQ     cfgvariant_clear_232h_bits45             ; 26C3 0 208 ??? C905
                MOVB    0f5h, #043h            ; 26C5 0 208 ??? C5F59843
                BRK                            ; 26C9 0 208 ??? FF
cfgvariant_clear_232h_bits45:     ANDB    off(00232h), #0cfh     ; 26CA 0 208 ??? C432D0CF
cfgvariant_check_320h_bit7:     MOV     DP, #00320h            ; 26CE 1 208 ??? 622003
                RB      [DP].7                 ; 26D1 1 208 ??? C20F
                CAL     cfgvariant_checksum_calc             ; 26D3 1 208 ??? 32925B
                JBR     off(00232h).2, cfgvariant_check_232h_bits01 ; 26D6 1 208 ??? DA320A
                JBR     off(00232h).3, cfgvariant_check_232h_bits01 ; 26D9 1 208 ??? DB3207
                CAL     cfgvariant_check_320h_bit7_sub_clear_acc             ; 26DC 1 208 ??? 32E35E
                ANDB    off(00232h), #0f3h     ; 26DF 1 208 ??? C432D0F3
cfgvariant_check_232h_bits01:     JBR     off(00232h).0, restore_trapstate_after_ramclear ; 26E3 1 208 ??? D8320A
                JBR     off(00232h).1, restore_trapstate_after_ramclear ; 26E6 1 208 ??? D93207
                CAL     cfgvariant_ram_init             ; 26E9 1 208 ??? 32F15E
                ANDB    off(00232h), #0fch     ; 26EC 1 208 ??? C432D0FC
restore_trapstate_after_ramclear:     MOV     LRB, #00010h           ; 26F0 1 080 ??? 571000
                MB      C, off(000b7h).0       ; 26F3 1 080 ??? C4B728
                MB      r0.0, C                ; 26F6 1 080 ??? 2038
                MB      C, off(000b7h).1       ; 26F8 1 080 ??? C4B729
                MB      r0.1, C                ; 26FB 1 080 ??? 2039
                MOVB    r1, off(000afh)        ; 26FD 1 080 ??? C4AF49
                MOVB    r2, off(000f6h)        ; 2700 1 080 ??? C4F64A
                MOVB    r3, off(000f5h)        ; 2703 1 080 ??? C4F54B
                CLR     A                      ; 2706 1 080 ??? F9
                MOV     USP, #00356h           ; 2707 1 080 356 A1985603
                MOV     DP, #00480h            ; 270B 1 080 356 628004
ram_clear_loop2:     DEC     DP                     ; 270E 1 080 356 82
                DEC     DP                     ; 270F 1 080 356 82
                ST      A, [DP]                ; 2710 1 080 356 D2
                CMP     DP, off(00086h)        ; 2711 1 080 356 92C386
                JGT     ram_clear_loop2             ; 2714 1 080 356 C8F8
                CMP     DP, #00098h            ; 2716 1 080 356 92C09800
                JLE     clear_0x324_high_nibble             ; 271A 1 080 356 CF0E
                MOV     USP, #00098h           ; 271C 1 080 098 A1989800
                CMPB    r3, #047h              ; 2720 1 080 098 23C047
                JNE     ram_clear_loop2             ; 2723 1 080 098 CEE9
                MOV     DP, #00300h            ; 2725 1 080 098 620003
                SJ      ram_clear_loop2             ; 2728 1 080 098 CBE4
clear_0x324_high_nibble:     MOV     DP, #00324h            ; 272A 1 080 356 622403
                LB      A, [DP]                ; 272D 0 080 356 F2
                ANDB    A, #0f0h               ; 272E 0 080 356 D6F0
                STB     A, [DP]                ; 2730 0 080 356 D2
                MB      C, r0.0                ; 2731 0 080 356 2028
                MB      off(000b7h).0, C       ; 2733 0 080 356 C4B738
                MB      C, r0.1                ; 2736 0 080 356 2029
                MB      off(000b7h).1, C       ; 2738 0 080 356 C4B739
                MOVB    off(000afh), r1        ; 273B 0 080 356 217CAF
                MOVB    off(000f6h), r2        ; 273E 0 080 356 227CF6
                MOVB    off(000f5h), r3        ; 2741 0 080 356 237CF5
                MOV     LRB, #00041h           ; 2744 0 208 356 574100
                SC                             ; 2747 0 208 356 85
                LB      A, 0afh                ; 2748 0 208 356 F5AF
                JNE     fuelpump_prime_check             ; 274A 0 208 356 CE05
                MOVB    off(002d1h), #014h     ; 274C 0 208 356 C4D19814
                RC                             ; 2750 0 208 356 95
fuelpump_prime_check:     MB      off(00230h).5, C       ; 2751 0 208 356 C4303D
; [H] --- Runtime state init: A/D channel setup, initial sensor snapshot, working-RAM seeding,
; [H] and diagnostic-serial baud/config setup, run once during boot after the self-test/RAM-clear
; [H] passes above. Ends by jumping to stack_sanity_check (0x3359) before falling into the main loop.
; [H] Individual working-RAM addresses here (0xD8-0xE1, 0xDC-0xDF, etc.) are not yet traced to
; [H] specific named parameters -- confidently identified: ADCR2H/ADCR4/ADCR6 (A/D conversion
; [H] results), tbl_boot_copy_block (a calibration table copied verbatim into 0x1D1-0x1DD), and
; [H] STTM/STTMR/STTMC/STCON/SRCON (serial timer + control regs -- diagnostic/K-line baud setup).
                MOV     USP, #00180h           ; 2754 0 208 180 A1988001
                CLR     A                      ; 2758 1 208 180 F9
                ST      A, IE                  ; 2759 1 208 180 D51A
                MOV     DP, A                  ; 275B 1 208 180 52
                CLRB    ADSEL                  ; 275C 1 208 180 C55915
                MOVB    ADSCAN, #010h          ; 275F 1 208 180 C5589810
                RB      IRQH.4                 ; 2763 1 208 180 C5190C
adc_wait_loop:     MB      r0.0, C                ; 2766 1 208 180 2038
                JRNZ    DP, adc_wait_loop         ; 2768 1 208 180 30FC
                CAL     idle_helper1             ; 276A 1 208 180 32865C
                LB      A, P2                  ; 276D 0 208 180 F524
                ANDB    A, #0e0h               ; 276F 0 208 180 D6E0
                JNE     adc_wait_loop             ; 2771 0 208 180 CEF3
                MOVB    0f7h, #001h            ; 2773 0 208 180 C5F79801
                CAL     selftest_reason_range_check_entry             ; 2777 0 208 180 32D95C
                L       A, ADCR4               ; 277A 1 208 180 E568
                ST      A, 09ch                ; 277C 1 208 180 D59C
                LB      A, ADCR2H              ; 277E 0 208 180 F565
                STB     A, 0e1h                ; 2780 0 208 180 D5E1
                MOV     DP, #00379h            ; 2782 0 208 180 627903
                STB     A, [DP]                ; 2785 0 208 180 D2
                MOV     DP, #003c6h            ; 2786 0 208 180 62C603
                LB      A, [DP]                ; 2789 0 208 180 F2
                STB     A, 0dah                ; 278A 0 208 180 D5DA
                MOV     DP, #003cdh            ; 278C 0 208 180 62CD03
                LB      A, [DP]                ; 278F 0 208 180 F2
                STB     A, 0dbh                ; 2790 0 208 180 D5DB
                MOVB    0d8h, #057h            ; 2792 0 208 180 C5D89857
                MOVB    0d9h, #03bh            ; 2796 0 208 180 C5D9983B
                MOVB    0bch, #0f9h            ; 279A 0 208 180 C5BC98F9
                J       adc_wait_loop_load_imm             ; 279E 0 208 180 030B7C
                DB  0FFh ; 27A1
adc_wait_loop_store_ram0df:     STB     A, 0dfh                ; 27A2 0 208 180 D5DF
                L       A, ADCR6               ; 27A4 1 208 180 E56C
                ST      A, 0bah                ; 27A6 1 208 180 D5BA
                LB      A, ACCH                ; 27A8 0 208 180 F507
                MOV     DP, #00374h            ; 27AA 0 208 180 627403
                STB     A, [DP]                ; 27AD 0 208 180 D2
                LB      A, #0a0h               ; 27AE 0 208 180 77A0
                STB     A, off(00237h)         ; 27B0 0 208 180 D437
                STB     A, (00132h-00180h)[USP] ; 27B2 0 208 180 D3B2
                STB     A, 0bdh                ; 27B4 0 208 180 D5BD
                MOV     DP, #00372h            ; 27B6 0 208 180 627203
                STB     A, [DP]                ; 27B9 0 208 180 D2
                INC     DP                     ; 27BA 0 208 180 72
                STB     A, [DP]                ; 27BB 0 208 180 D2
                L       A, #04d00h             ; 27BC 1 208 180 67004D
                ST      A, 0d0h                ; 27BF 1 208 180 D5D0
                ST      A, 0d2h                ; 27C1 1 208 180 D5D2
                ST      A, er0                 ; 27C3 1 208 180 88
                SLL     A                      ; 27C4 1 208 180 53
                JLT     clamp_to_0xff             ; 27C5 1 208 180 CA05
                SLL     A                      ; 27C7 1 208 180 53
                LB      A, ACCH                ; 27C8 0 208 180 F507
                JGE     clamp_result_store             ; 27CA 0 208 180 CD02
clamp_to_0xff:     LB      A, #0ffh               ; 27CC 0 208 180 77FF
clamp_result_store:     STB     A, 0d4h                ; 27CE 0 208 180 D5D4
                CAL     boot_completion_helper             ; 27D0 0 208 180 32455F
                CLR     X1                     ; 27D3 0 208 180 9015
                SB      off(00231h).5          ; 27D5 0 208 180 C4311D
                MOV     0ceh, #0ffffh          ; 27D8 0 208 180 B5CE98FFFF
                SB      off(00231h).3          ; 27DD 0 208 180 C4311B
                MOV     098h, #000e1h          ; 27E0 0 208 180 B59898E100
                MOV     09ah, #0091fh          ; 27E5 0 208 180 B59A981F09
                L       A, #00001h             ; 27EA 1 208 180 670100
                ST      A, (00114h-00180h)[USP] ; 27ED 1 208 180 D394
                ST      A, (00112h-00180h)[USP] ; 27EF 1 208 180 D392
                ST      A, (00110h-00180h)[USP] ; 27F1 1 208 180 D390
                LB      A, #00fh               ; 27F3 0 208 180 770F
                STB     A, (00117h-00180h)[USP] ; 27F5 0 208 180 D397
                STB     A, (0018fh-00180h)[USP] ; 27F7 0 208 180 D30F
                MOVB    0e5h, #031h            ; 27F9 0 208 180 C5E59831
                MOV     0e6h, #0ffffh          ; 27FD 0 208 180 B5E698FFFF
                MOVB    off(002a0h), #0ffh     ; 2802 0 208 180 C4A098FF
                MOVB    off(002b1h), #001h     ; 2806 0 208 180 C4B19801
                LB      A, 003d0h[X1]          ; 280A 0 208 180 F0D003
                STB     A, 00375h[X1]          ; 280D 0 208 180 D07503
                CAL     ect_step_helper             ; 2810 0 208 180 32F55B
                CLRB    A                      ; 2813 0 208 180 FA
                MOV     DP, #001adh            ; 2814 0 208 180 62AD01
clamp_result_store_rom_load_tbl_6d6b_dp:     LCB     A, clamp_result_store_tbl[DP]        ; 2817 0 208 180 92AB6B6D
                STB     A, [DP]                ; 281B 0 208 180 D2
                INC     DP                     ; 281C 0 208 180 72
                CMP     DP, #001bah            ; 281D 0 208 180 92C0BA01
                JNE     clamp_result_store_rom_load_tbl_6d6b_dp             ; 2821 0 208 180 CEF4
                MOVB    00393h[X1], #0ffh      ; 2823 0 208 180 C0930398FF
                MOVB    off(002c6h), #0f9h     ; 2828 0 208 180 C4C698F9
                MOVB    off(002bbh), #002h     ; 282C 0 208 180 C4BB9802
                MOVB    off(002bch), #002h     ; 2830 0 208 180 C4BC9802
                MOVB    00377h[X1], #053h      ; 2834 0 208 180 C077039853
                LB      A, 00310h[X1]          ; 2839 0 208 180 F01003
                MOVB    ACC, #07bh             ; 283C 0 208 180 C506987B
                JNE     serial_baud_store_common             ; 2840 0 208 180 CE03
                STB     A, 00311h[X1]          ; 2842 0 208 180 D01103
serial_baud_store_common:     STB     A, 00378h[X1]          ; 2845 0 208 180 D07803
                SB      off(00225h).1          ; 2848 0 208 180 C42519
                CMPB    0f5h, #047h            ; 284B 0 208 180 C5F5C047
                JEQ     serial_baud_select_done             ; 284F 0 208 180 C918
                MOV     DP, #00312h            ; 2851 0 208 180 621203
                L       A, #00266h             ; 2854 1 208 180 676602
                ST      A, [DP]                ; 2857 1 208 180 D2
                INC     DP                     ; 2858 1 208 180 72
                INC     DP                     ; 2859 1 208 180 72
                ST      A, [DP]                ; 285A 1 208 180 D2
                INC     DP                     ; 285B 1 208 180 72
                INC     DP                     ; 285C 1 208 180 72
                L       A, #00100h             ; 285D 1 208 180 670001
                ST      A, [DP]                ; 2860 1 208 180 D2
                INC     DP                     ; 2861 1 208 180 72
                INC     DP                     ; 2862 1 208 180 72
                ST      A, [DP]                ; 2863 1 208 180 D2
                MOVB    0031ah[X1], #03bh      ; 2864 1 208 180 C01A03983B
serial_baud_select_done:     MOVB    off(002cdh), #032h     ; 2869 1 208 180 C4CD9832
                MOVB    r0, #01ch              ; 286D 1 208 180 981C
                MOVB    r1, #08ch              ; 286F 1 208 180 998C
                LB      A, #0dfh               ; 2871 0 208 180 77DF
                MOV     DP, #00356h            ; 2873 0 208 180 625603
                MB      C, [DP].1              ; 2876 0 208 180 C229
                JLT     serial_baud_apply             ; 2878 0 208 180 CA06
                MOVB    r0, #031h              ; 287A 0 208 180 9831
                MOVB    r1, #0a1h              ; 287C 0 208 180 99A1
                LB      A, #0fbh               ; 287E 0 208 180 77FB
serial_baud_apply:     STB     A, STTM                ; 2880 0 208 180 D548
                STB     A, STTMR               ; 2882 0 208 180 D549
                MOVB    STTMC, #012h           ; 2884 0 208 180 C54A9812
                LB      A, r0                  ; 2888 0 208 180 78
                STB     A, STCON               ; 2889 0 208 180 D550
                LB      A, r1                  ; 288B 0 208 180 79
                STB     A, SRCON               ; 288C 0 208 180 D554
                MOV     DP, #04700h            ; 288E 0 208 180 620047
                LB      A, [DP]                ; 2891 0 208 180 F2
                XORB    A, #01ah               ; 2892 0 208 180 F61A
                STB     A, off(00211h)         ; 2894 0 208 180 D411
                STB     A, (00119h-00180h)[USP] ; 2896 0 208 180 D399
                CLR     A                      ; 2898 1 208 180 F9
                MOV     DP, #003fch            ; 2899 1 208 180 62FC03
                LC      A, 00038h              ; 289C 1 208 180 909C3800
                ST      A, [DP]                ; 28A0 1 208 180 D2
                INC     DP                     ; 28A1 1 208 180 72
                INC     DP                     ; 28A2 1 208 180 72
                LC      A, 0003ah              ; 28A3 1 208 180 909C3A00
                ST      A, [DP]                ; 28A7 1 208 180 D2
                CLRB    0f5h                   ; 28A8 1 208 180 C5F515
                J       stack_sanity_check             ; 28AB 1 208 180 03473F
vcal_3:         MOV     DP, #00356h            ; 28AE 1 208 180 625603
                MB      C, [DP].1              ; 28B1 1 208 180 C229
                JLT     vcal_3_load_dp             ; 28B3 1 208 180 CA03
                J       vcal_3_load_ram0fa             ; 28B5 1 208 180 039729
vcal_3_load_dp:     MOV     DP, #00356h            ; 28B8 1 208 180 625603
                RB      [DP].7                 ; 28BB 1 208 180 C20F
                JNE     vcal_3_load_dp_2             ; 28BD 1 208 180 CE03
vcal_3_goto_2997:     J       vcal_3_load_ram0fa             ; 28BF 1 208 180 039729
vcal_3_load_dp_2:     MOV     DP, #003f1h            ; 28C2 1 208 180 62F103
                LB      A, [DP]                ; 28C5 0 208 180 F2
                CMPB    A, #020h               ; 28C6 0 208 180 C620
                JNE     vcal_3_cmp_acc             ; 28C8 0 208 180 CE17
                L       A, 0c4h                ; 28CA 1 208 180 E5C4
                MOV     DP, #0039ch            ; 28CC 1 208 180 629C03
                ST      A, [DP]                ; 28CF 1 208 180 D2
                MOV     DP, #003a2h            ; 28D0 1 208 180 62A203
                L       A, [DP]                ; 28D3 1 208 180 E2
                MOV     DP, #0039eh            ; 28D4 1 208 180 629E03
                ST      A, [DP]                ; 28D7 1 208 180 D2
                MOV     DP, #003f4h            ; 28D8 1 208 180 62F403
                LB      A, [DP]                ; 28DB 0 208 180 F2
                ADDB    A, #003h               ; 28DC 0 208 180 8603
                J       vcal_3_load_dp_6             ; 28DE 0 208 180 037C29
vcal_3_cmp_acc:     CMPB    A, #030h               ; 28E1 0 208 180 C630
                JLT     vcal_3_cmp_acc_2             ; 28E3 0 208 180 CA2B
                CMPB    A, #036h               ; 28E5 0 208 180 C636
                JGT     vcal_3_cmp_acc_2             ; 28E7 0 208 180 C827
                CMPB    A, #030h               ; 28E9 0 208 180 C630
                JEQ     vcal_3_clear_acc             ; 28EB 0 208 180 C918
                JBR     off(00210h).7, vcal_3_clear_acc ; 28ED 0 208 180 DF1015
                MOV     DP, #003f0h            ; 28F0 0 208 180 62F003
                CMPB    A, [DP]                ; 28F3 0 208 180 C2C2
                JNE     vcal_3_load_dp_3             ; 28F5 0 208 180 CE08
                MOV     DP, #003abh            ; 28F7 0 208 180 62AB03
                STB     A, [DP]                ; 28FA 0 208 180 D2
vcal_3_load_imm:     LB      A, #028h               ; 28FB 0 208 180 7728
                SJ      vcal_3_load_dp_4             ; 28FD 0 208 180 CB0B
vcal_3_load_dp_3:     MOV     DP, #003fah            ; 28FF 0 208 180 62FA03
                LB      A, [DP]                ; 2902 0 208 180 F2
                JNE     vcal_3_load_imm             ; 2903 0 208 180 CEF6
vcal_3_clear_acc:     CLRB    A                      ; 2905 0 208 180 FA
                MOV     DP, #003abh            ; 2906 0 208 180 62AB03
                STB     A, [DP]                ; 2909 0 208 180 D2
vcal_3_load_dp_4:     MOV     DP, #003fah            ; 290A 0 208 180 62FA03
                STB     A, [DP]                ; 290D 0 208 180 D2
                SJ      vcal_3_load_imm_2             ; 290E 0 208 180 CB6A
vcal_3_cmp_acc_2:     CMPB    A, #021h               ; 2910 0 208 180 C621
                JNE     vcal_3_goto_2997             ; 2912 0 208 180 CEAB
                MOV     DP, #003f3h            ; 2914 0 208 180 62F303
                LB      A, [DP]                ; 2917 0 208 180 F2
                SRLB    A                      ; 2918 0 208 180 63
                JGE     vcal_3_load_dp_5             ; 2919 0 208 180 CD48
                CLR     A                      ; 291B 1 208 180 F9
                ST      A, (0011ah-00180h)[USP] ; 291C 1 208 180 D39A
                ST      A, (0011ch-00180h)[USP] ; 291E 1 208 180 D39C
                ST      A, off(00212h)         ; 2920 1 208 180 D412
                ST      A, off(00214h)         ; 2922 1 208 180 D414
                RB      off(0021ah).5          ; 2924 1 208 180 C41A0D
                ST      A, 0b0h                ; 2927 1 208 180 D5B0
                ST      A, 0b2h                ; 2929 1 208 180 D5B2
                ST      A, 0b4h                ; 292B 1 208 180 D5B4
                CLRB    A                      ; 292D 0 208 180 FA
                STB     A, 0f4h                ; 292E 0 208 180 D5F4
                STB     A, off(002b3h)         ; 2930 0 208 180 D4B3
                MOV     DP, #00399h            ; 2932 0 208 180 629903
                STB     A, [DP]                ; 2935 0 208 180 D2
                MOV     DP, #001adh            ; 2936 0 208 180 62AD01
vcal_3_rom_load_tbl_6d6b_dp:     LCB     A, clamp_result_store_tbl[DP]        ; 2939 0 208 180 92AB6B6D
                STB     A, [DP]                ; 293D 0 208 180 D2
                INC     DP                     ; 293E 0 208 180 72
                CMP     DP, #001bah            ; 293F 0 208 180 92C0BA01
                JNE     vcal_3_rom_load_tbl_6d6b_dp             ; 2943 0 208 180 CEF4
                RB      off(00218h).6          ; 2945 0 208 180 C4180E
                RB      off(00218h).7          ; 2948 0 208 180 C4180F
                RB      off(0022bh).4          ; 294B 0 208 180 C42B0C
                RB      off(00225h).7          ; 294E 0 208 180 C4250F
                RB      off(00234h).7          ; 2951 0 208 180 C4340F
                SB      off(00232h).2          ; 2954 0 208 180 C4321A
                SB      off(00232h).3          ; 2957 0 208 180 C4321B
                J       vcal_3_clear_ram235_bit2             ; 295A 0 208 180 03CC79
vcal_3_clear_ram232_bit2:     RB      off(00232h).2          ; 295D 0 208 180 C4320A
                RB      off(00232h).3          ; 2960 0 208 180 C4320B
vcal_3_load_dp_5:     MOV     DP, #003f3h            ; 2963 0 208 180 62F303
                LB      A, [DP]                ; 2966 0 208 180 F2
                SRLB    A                      ; 2967 0 208 180 63
                SRLB    A                      ; 2968 0 208 180 63
                JGE     vcal_3_load_imm_2             ; 2969 0 208 180 CD0F
                SB      off(00232h).0          ; 296B 0 208 180 C43218
                SB      off(00232h).1          ; 296E 0 208 180 C43219
                CAL     cfgvariant_ram_init             ; 2971 0 208 180 32F15E
                RB      off(00232h).0          ; 2974 0 208 180 C43208
                RB      off(00232h).1          ; 2977 0 208 180 C43209
vcal_3_load_imm_2:     LB      A, #003h               ; 297A 0 208 180 7703
vcal_3_load_dp_6:     MOV     DP, #003f2h            ; 297C 0 208 180 62F203
                STB     A, [DP]                ; 297F 0 208 180 D2
                MOV     DP, #00356h            ; 2980 0 208 180 625603
                SB      [DP].6                 ; 2983 0 208 180 C21E
                MOV     DP, #003f5h            ; 2985 0 208 180 62F503
                LB      A, #002h               ; 2988 0 208 180 7702
                STB     A, [DP]                ; 298A 0 208 180 D2
                MOV     DP, #003f1h            ; 298B 0 208 180 62F103
                LB      A, [DP]                ; 298E 0 208 180 F2
                ANDB    A, #01fh               ; 298F 0 208 180 D61F
                MOV     DP, #003f6h            ; 2991 0 208 180 62F603
                STB     A, [DP]                ; 2994 0 208 180 D2
                STB     A, STBUF               ; 2995 0 208 180 D551
vcal_3_load_ram0fa:     L       A, 0fah                ; 2997 1 208 180 E5FA
                ST      A, IE                  ; 2999 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 299B 1 208 180 A2D0FE
                LB      A, 09eh                ; 299E 0 208 180 F59E
                SUBB    A, #005h               ; 29A0 0 208 180 A605
                JLT     vcal3_leanprotect_ratelimit             ; 29A2 0 208 180 CA02
                STB     A, 09eh                ; 29A4 0 208 180 D59E
vcal3_leanprotect_ratelimit:     ORB     PSWH, #001h            ; 29A6 0 208 180 A2E001
                L       A, 0f8h                ; 29A9 1 208 180 E5F8
                ST      A, IE                  ; 29AB 1 208 180 D51A
                JGE     vcal3_main_task             ; 29AD 1 208 180 CD41
                RB      (0012ah-00180h)[USP].2 ; 29AF 1 208 180 C3AA0A
                JBR     off(00216h).7, vcal3_leanprotect_ratelimit_load_carry_ram0b6_bit4 ; 29B2 1 208 180 DF1608
                RB      0b6h.6                 ; 29B5 1 208 180 C5B60E
                JEQ     vcal3_leanprotect_ratelimit_load_carry_ram0b6_bit4             ; 29B8 1 208 180 C903
                J       vcal3_leanprotect_ratelimit_load_adcr3h             ; 29BA 1 208 180 03212E
vcal3_leanprotect_ratelimit_load_carry_ram0b6_bit4:     MB      C, 0b6h.4              ; 29BD 1 208 180 C5B62C
                JGE     vcal3_leanprotect_ratelimit_if_ram227_bit2_set             ; 29C0 1 208 180 CD0F
                JBR     off(0022bh).0, vcal3_task_a ; 29C2 1 208 180 D82B09
                RB      off(00231h).0          ; 29C5 1 208 180 C43108
                JNE     vcal3_task_a             ; 29C8 1 208 180 CE04
                RB      0b6h.4                 ; 29CA 1 208 180 C5B60C
                RT                             ; 29CD 1 208 180 01
vcal3_task_a:     J       battery_voltage_check             ; 29CE 1 208 180 03092F
vcal3_leanprotect_ratelimit_if_ram227_bit2_set:     JBS     off(00227h).2, vcal3_dispatch_check1 ; 29D1 1 208 180 EA270B
                JBR     off(00216h).3, vcal3_dispatch_check1 ; 29D4 1 208 180 DB1608
                RB      0b6h.3                 ; 29D7 1 208 180 C5B60B
                JEQ     vcal3_dispatch_check1             ; 29DA 1 208 180 C903
                J       vcal3_leanprotect_ratelimit_load_r5             ; 29DC 1 208 180 038E37
vcal3_dispatch_check1:     RB      off(00231h).1          ; 29DF 1 208 180 C43109
                JEQ     vcal3_dispatch_check2             ; 29E2 1 208 180 C903
                J       vcal3_task_c_timers             ; 29E4 1 208 180 03D93C
vcal3_dispatch_check2:     RB      off(00231h).2          ; 29E7 1 208 180 C4310A
                JNE     vcal3_task_b             ; 29EA 1 208 180 CE01
                RT                             ; 29EC 1 208 180 01
vcal3_task_b:     J       vcal3_task_b_body             ; 29ED 1 208 180 03FA3D
vcal3_main_task:     CAL     ResetWatchDog             ; 29F0 1 208 180 32E45B
                JBS     off(002b4h).0, vcal3_main_task_load_dp ; 29F3 1 208 180 E8B40C
                JBS     off(002b4h).1, vcal3_main_task_load_dp ; 29F6 1 208 180 E9B409
                SB      0b6h.6                 ; 29F9 1 208 180 C5B61E
                JBS     off(002b4h).2, vcal3_main_task_load_dp ; 29FC 1 208 180 EAB403
                SB      0b6h.3                 ; 29FF 1 208 180 C5B61B
vcal3_main_task_load_dp:     MOV     DP, #00008h            ; 2A02 1 208 180 620800
                MOV     X1, #001d3h            ; 2A05 1 208 180 60D301
                CAL     decrement_timer_array             ; 2A08 1 208 180 32C95B
                MOV     DP, #0000ch            ; 2A0B 1 208 180 620C00
                MOV     X1, #002bfh            ; 2A0E 1 208 180 60BF02
                CAL     decrement_timer_array             ; 2A11 1 208 180 32C95B
                MOV     DP, #00004h            ; 2A14 1 208 180 620400
                MOV     X1, #003f7h            ; 2A17 1 208 180 60F703
                CAL     decrement_timer_array             ; 2A1A 1 208 180 32C95B
                DECB    off(002b4h)            ; 2A1D 1 208 180 C4B417
                MOV     DP, #003fah            ; 2A20 1 208 180 62FA03
                LB      A, [DP]                ; 2A23 0 208 180 F2
                JNE     scheduler_slowflag_check             ; 2A24 0 208 180 CE04
                MOV     DP, #003abh            ; 2A26 0 208 180 62AB03
                STB     A, [DP]                ; 2A29 0 208 180 D2
scheduler_slowflag_check:     CLR     A                      ; 2A2A 1 208 180 F9
                LB      A, off(002c6h)         ; 2A2B 0 208 180 F4C6
                JNE     scheduler_divider_check             ; 2A2D 0 208 180 CE12
                LB      A, #0fah               ; 2A2F 0 208 180 77FA
                STB     A, off(002c6h)         ; 2A31 0 208 180 D4C6
                MB      C, off(00231h).7       ; 2A33 0 208 180 C4312F
                XORB    PSWH, #080h            ; 2A36 0 208 180 A2F080
                MB      off(00231h).7, C       ; 2A39 0 208 180 C4313F
                JLT     scheduler_divider_check             ; 2A3C 0 208 180 CA03
                SB      off(00231h).2          ; 2A3E 0 208 180 C4311A
scheduler_divider_check:     MOVB    r0, #00ah              ; 2A41 0 208 180 980A
                DIVB                           ; 2A43 0 208 180 A236
                LB      A, r1                  ; 2A45 0 208 180 79
                JNE     scheduler_task_done             ; 2A46 0 208 180 CE3B
                SB      off(00231h).1          ; 2A48 0 208 180 C43119
                JBR     off(00216h).5, scheduler_gate_common ; 2A4B 0 208 180 DD1627
                L       A, off(00214h)         ; 2A4E 1 208 180 E414
                AND     A, #00320h             ; 2A50 1 208 180 D62003
                JNE     scheduler_gate_common             ; 2A53 1 208 180 CE20
                L       A, off(00212h)         ; 2A55 1 208 180 E412
                AND     A, #001bch             ; 2A57 1 208 180 D6BC01
                JNE     scheduler_gate_common             ; 2A5A 1 208 180 CE19
                JBR     off(0021ah).6, scheduler_gate_common ; 2A5C 1 208 180 DE1A16
                JBS     off(0021ah).7, scheduler_gate_common ; 2A5F 1 208 180 EF1A13
                LB      A, 0d9h                ; 2A62 0 208 180 F5D9
                CMPB    A, #0ffh               ; 2A64 0 208 180 C6FF
                JLE     scheduler_ect_sign_check             ; 2A66 0 208 180 CF15
                CMPB    A, #0ffh               ; 2A68 0 208 180 C6FF
                JGE     scheduler_ect_sign_check             ; 2A6A 0 208 180 CD11
                XORB    P0, #040h              ; 2A6C 0 208 180 C520F040
                RB      off(00224h).7          ; 2A70 0 208 180 C4240F
                SJ      scheduler_task_done             ; 2A73 0 208 180 CB0E
scheduler_gate_common:     SB      P0.6                   ; 2A75 0 208 180 C5201E
                SB      off(00224h).7          ; 2A78 0 208 180 C4241F
                SJ      scheduler_task_done             ; 2A7B 0 208 180 CB06
scheduler_ect_sign_check:     RB      P0.6                   ; 2A7D 0 208 180 C5200E
                RB      off(00224h).7          ; 2A80 0 208 180 C4240F
scheduler_task_done:     MOV     DP, #000ceh            ; 2A83 0 208 180 62CE00
; [H] --- VSS (vehicle speed) calculation (0x274A-0x27E4ish): measures a speed-sensor pulse
; [H] period (0xA8/0xAC), divides vssSpeedNumerator by the pulse period and a plausibility-range check
; [H] (0x373-0x397D), applying sub_clamp_helper/mul_scale_helper2-style scaling, then clamps and stores
; [H] the final VSS byte to 0xCC -- the same VSS value read throughout the session (fuel-cut,
; [H] boost, wastegate, etc).
                JBS     off(00214h).0, vss_calc_skip ; 2A86 0 208 180 E81476
                RB      0b6h.2                 ; 2A89 0 208 180 C5B60A
                JEQ     vss_calc_gate2             ; 2A8C 0 208 180 C979
                JBS     off(00217h).5, vss_calc_gate3 ; 2A8E 0 208 180 ED177F
                CMPB    0dbh, #044h            ; 2A91 0 208 180 C5DBC044
                JLE     vss_calc_skip             ; 2A95 0 208 180 CF68
                L       A, 0fah                ; 2A97 1 208 180 E5FA
                ST      A, IE                  ; 2A99 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 2A9B 1 208 180 A2D0FE
                MOVB    r0, 0aah               ; 2A9E 1 208 180 C5AA48
                L       A, 0a8h                ; 2AA1 1 208 180 E5A8
                SUB     A, 0ach                ; 2AA3 1 208 180 B5ACA2
                ST      A, er1                 ; 2AA6 1 208 180 89
                ORB     PSWH, #001h            ; 2AA7 1 208 180 A2E001
                L       A, 0f8h                ; 2AAA 1 208 180 E5F8
                ST      A, IE                  ; 2AAC 1 208 180 D51A
                SBCB    r0, #000h              ; 2AAE 1 208 180 20B000
                SRLB    r0                     ; 2AB1 1 208 180 20E7
                L       A, er1                 ; 2AB3 1 208 180 35
                ROR     A                      ; 2AB4 1 208 180 43
                CMPB    r0, #000h              ; 2AB5 1 208 180 20C000
                JNE     vss_calc_gate3             ; 2AB8 1 208 180 CE56
                RB      off(00231h).3          ; 2ABA 1 208 180 C4310B
                JNE     vss_calc_done             ; 2ABD 1 208 180 CE5E
                RB      off(00231h).4          ; 2ABF 1 208 180 C4310C
                JNE     vss_calc_done             ; 2AC2 1 208 180 CE59
                CMP     A, #00373h             ; 2AC4 1 208 180 C67303
                MB      off(00231h).4, C       ; 2AC7 1 208 180 C4313C
                JLT     vss_calc_done             ; 2ACA 1 208 180 CA51
                CMP     A, #0397dh             ; 2ACC 1 208 180 C67D39
                JGE     vss_result_store             ; 2ACF 1 208 180 CD10
                MOV     er0, #01000h           ; 2AD1 1 208 180 44980010
                CMP     A, #005c0h             ; 2AD5 1 208 180 C6C005
                JLT     vss_scale_apply             ; 2AD8 1 208 180 CA04
                MOV     er0, #04000h           ; 2ADA 1 208 180 44980040
vss_scale_apply:     CAL     mul_scale_helper2             ; 2ADE 1 208 180 320759
vss_result_store:     ST      A, [DP]                ; 2AE1 1 208 180 D2
                ST      A, er2                 ; 2AE2 1 208 180 8A
vssSpeedNumerator    equ 05e59h ; VSS: speed = (3 * 10000h + vssSpeedNumerator) / pulse period (MOV er0,#3 / L A,# / DIV).
                                ; A number, not a table: it used to be bound to whatever label sat at this address.
                MOV     er0, #00003h           ; 2AE3 1 208 180 44980300
                L       A, #vssSpeedNumerator                      ; 2AE7 1 208 180 67595E
                DIV                            ; 2AEA 1 208 180 9037
                ST      A, er1                 ; 2AEC 1 208 180 89
                L       A, er0                 ; 2AED 1 208 180 34
                JNE     vss_clamp_max             ; 2AEE 1 208 180 CE03
                LB      A, r3                  ; 2AF0 0 208 180 7B
                JEQ     vss_clamp_common             ; 2AF1 0 208 180 C902
vss_clamp_max:     MOVB    r2, #0ffh              ; 2AF3 0 208 180 9AFF
vss_clamp_common:     LB      A, r2                  ; 2AF5 0 208 180 7A
vss_final_store:     STB     A, r2                  ; 2AF6 0 208 180 8A
                MOVB    r3, 0cch               ; 2AF7 0 208 180 C5CC4B
                L       A, er1                 ; 2AFA 1 208 180 35
                ST      A, 0cch                ; 2AFB 1 208 180 D5CC
                SJ      vss_calc_done             ; 2AFD 1 208 180 CB1E
vss_calc_skip:     L       A, #vss_calc_skip_tbl           ; 2AFF 1 208 180 67FA72
                RB      off(00231h).3          ; 2B02 1 208 180 C4310B
                SJ      vss_result_store             ; 2B05 1 208 180 CBDA
vss_calc_gate2:     LB      A, #003h               ; 2B07 0 208 180 7703
                CMPB    0abh, A                ; 2B09 0 208 180 C5ABC1
                JLT     vss_calc_done             ; 2B0C 0 208 180 CA0F
                STB     A, 0abh                ; 2B0E 0 208 180 D5AB
vss_calc_gate3:     RB      off(00231h).4          ; 2B10 0 208 180 C4310C
                SB      off(00231h).3          ; 2B13 0 208 180 C4311B
                MOV     [DP], #0ffffh          ; 2B16 0 208 180 B298FFFF
                CLRB    A                      ; 2B1A 0 208 180 FA
                SJ      vss_final_store             ; 2B1B 0 208 180 CBD9
vss_calc_done:     LB      A, #005h               ; 2B1D 0 208 180 7705
                JBS     off(0021ah).2, vss_hysteresis_check ; 2B1F 0 208 180 EA1A02
                LB      A, #006h               ; 2B22 0 208 180 7706
vss_hysteresis_check:     CMPB    A, 0cch                ; 2B24 0 208 180 C5CCC2
                MB      off(0021ah).2, C       ; 2B27 0 208 180 C41A3A
                JBS     off(00231h).3, vss_hysteresis_check_if_ram227_bit6_clr ; 2B2A 0 208 180 EB3104
                MOVB    off(002c7h), #008h     ; 2B2D 0 208 180 C4C79808
vss_hysteresis_check_if_ram227_bit6_clr:     JBR     off(00227h).6, idle_gate1_clear ; 2B31 0 208 180 DE2722
                JBS     off(00214h).7, idle_gate1_clear ; 2B34 0 208 180 EF141F
                MOV     DP, #00f00h            ; 2B37 0 208 180 62000F
                MB      C, [DP].2              ; 2B3A 0 208 180 C22A
                RB      off(00232h).6          ; 2B3C 0 208 180 C4320E
                MB      off(00232h).6, C       ; 2B3F 0 208 180 C4323E
                JEQ     idle_gate1             ; 2B42 0 208 180 C903
                XORB    PSWH, #080h            ; 2B44 0 208 180 A2F080
idle_gate1:     JGE     idle_gate1_timer_check             ; 2B47 0 208 180 CD10
                CMPB    0c5h, #000h            ; 2B49 0 208 180 C5C5C000
                JGT     idle_gate1_trigger             ; 2B4D 0 208 180 C803
                JBS     off(00233h).7, idle_gate1_timer_check ; 2B4F 0 208 180 EF3307
idle_gate1_trigger:     MOVB    off(002c9h), #0ffh     ; 2B52 0 208 180 C4C998FF
idle_gate1_clear:     RC                             ; 2B56 0 208 180 95
                SJ      dtc24_code24_latch             ; 2B57 0 208 180 CB05
idle_gate1_timer_check:     LB      A, off(002c9h)         ; 2B59 0 208 180 F4C9
                JNE     idle_gate1_clear             ; 2B5B 0 208 180 CEF9
                SC                             ; 2B5D 0 208 180 85
dtc24_code24_latch:     MB      0b2h.3, C              ; 2B5E 0 208 180 C5B23B
                RB      (0012ah-00180h)[USP].2 ; 2B61 0 208 180 C3AA0A
                CAL     idle_helper1             ; 2B64 0 208 180 32865C
                JBR     off(00227h).0, idle_init_start_clear_x2 ; 2B67 0 208 180 D82706
                CAL     idle_init_start_sub_load_dp             ; 2B6A 0 208 180 320E5D
                CAL     idle_init_start_sub_load_dp_ind             ; 2B6D 0 208 180 32115D
idle_init_start_clear_x2:     CLR     X2                     ; 2B70 0 208 180 9115
                MOV     er0, 00396h[X2]        ; 2B72 0 208 180 B1960348
                CLR     A                      ; 2B76 1 208 180 F9
                LB      A, #040h               ; 2B77 0 208 180 7740
                MUL                            ; 2B79 0 208 180 9035
                MOV     X1, A                  ; 2B7B 0 208 180 50
                MOV     DP, #00020h            ; 2B7C 0 208 180 622000
                MOVB    r0, 00398h[X2]         ; 2B7F 0 208 180 C1980348
idle_init_start_rom_load_tbl_x1:     LC      A, [X1]                ; 2B83 0 208 180 90A8
                ADDB    A, ACCH                ; 2B85 0 208 180 C50782
                ADDB    r0, A                  ; 2B88 0 208 180 2081
                INC     X1                     ; 2B8A 0 208 180 70
                INC     X1                     ; 2B8B 0 208 180 70
                JRNZ    DP, idle_init_start_rom_load_tbl_x1         ; 2B8C 0 208 180 30F5
                LB      A, r0                  ; 2B8E 0 208 180 78
                STB     A, 00398h[X2]          ; 2B8F 0 208 180 D19803
                INC     00396h[X2]             ; 2B92 0 208 180 B1960316
                CMP     00396h[X2], #00200h    ; 2B96 0 208 180 B19603C00002
                JNE     idle_init_start_if_ram227_bit0_clr             ; 2B9C 0 208 180 CE18
                CLR     00396h[X2]             ; 2B9E 0 208 180 B1960315
                LB      A, r0                  ; 2BA2 0 208 180 78
                JEQ     idle_init_start_if_ram227_bit0_clr             ; 2BA3 0 208 180 C911
                CLRB    00398h[X2]             ; 2BA5 0 208 180 C1980315
                LCB     A, idle_init_start_tbl            ; 2BA9 0 208 180 909DFB60
                JNE     idle_init_start_if_ram227_bit0_clr             ; 2BAD 0 208 180 CE07
                MOVB    0f5h, #048h            ; 2BAF 0 208 180 C5F59848
                J       fault_giveup_latch             ; 2BB3 0 208 180 03E924
idle_init_start_if_ram227_bit0_clr:     JBR     off(00227h).0, idle_init_start_clear_r2 ; 2BB6 0 208 180 D82706
                CAL     idle_init_start_sub_load_dp             ; 2BB9 0 208 180 320E5D
                CAL     idle_init_start_sub_load_dp_ind             ; 2BBC 0 208 180 32115D
idle_init_start_clear_r2:     CLRB    r2                     ; 2BBF 0 208 180 2215
                JBR     off(00227h).0, idle_init_start_goto_2c91 ; 2BC1 0 208 180 D82777
                J       idle_init_start_load_ram258             ; 2BC4 0 208 180 03CA2B
                DB  0FFh,0FFh,0FFh ; 2BC7
idle_init_start_load_ram258:     LB      A, off(00258h)         ; 2BCA 0 208 180 F458
                JEQ     idle_init_start_load_carry_ram22c_bit0             ; 2BCC 0 208 180 C90C
                CMPB    A, #0ffh               ; 2BCE 0 208 180 C6FF
                JEQ     idle_init_start_load_carry_ram22c_bit0             ; 2BD0 0 208 180 C908
                CMPB    A, #0aah               ; 2BD2 0 208 180 C6AA
                JEQ     idle_init_start_load_carry_ram22c_bit0             ; 2BD4 0 208 180 C904
                CMPB    A, #055h               ; 2BD6 0 208 180 C655
                JNE     idle_init_start_load_imm             ; 2BD8 0 208 180 CE14
idle_init_start_load_carry_ram22c_bit0:     MB      C, off(0022ch).0       ; 2BDA 0 208 180 C42C28
                MB      off(0022ch).1, C       ; 2BDD 0 208 180 C42C39
                MB      C, off(0022ch).2       ; 2BE0 0 208 180 C42C2A
                MB      off(0022ch).3, C       ; 2BE3 0 208 180 C42C3B
                RORB    A                      ; 2BE6 0 208 180 43
                MB      off(0022ch).0, C       ; 2BE7 0 208 180 C42C38
                RORB    A                      ; 2BEA 0 208 180 43
                MB      off(0022ch).2, C       ; 2BEB 0 208 180 C42C3A
idle_init_start_load_imm:     LB      A, #0ffh               ; 2BEE 0 208 180 77FF
                JBS     off(0022ch).5, idle_init_start_cmp_acc ; 2BF0 0 208 180 ED2C02
                LB      A, #0ffh               ; 2BF3 0 208 180 77FF
idle_init_start_cmp_acc:     CMPB    A, off(00238h)         ; 2BF5 0 208 180 C738
                MB      off(0022ch).5, C       ; 2BF7 0 208 180 C42C3D
                RB      PSWL.4                 ; 2BFA 0 208 180 A30C
                JBS     off(0022ch).4, idle_init_start_if_ram22c_bit2_set ; 2BFC 0 208 180 EC2C2D
                JBR     off(00234h).7, idle_init_start_cmp_ram0d9 ; 2BFF 0 208 180 DF3421
                SB      PSWL.4                 ; 2C02 0 208 180 A31C
                JBS     off(00215h).5, idle_init_start_load_ram2ca ; 2C04 0 208 180 ED1541
                JBS     off(00215h).6, idle_init_start_load_ram2ca ; 2C07 0 208 180 EE153E
                MOV     DP, #003f8h            ; 2C0A 0 208 180 62F803
                LB      A, off(002d8h)         ; 2C0D 0 208 180 F4D8
                JEQ     idle_init_start_load_dp_ind             ; 2C0F 0 208 180 C905
                MOVB    [DP], #0ffh            ; 2C11 0 208 180 C298FF
                SJ      idle_init_start_load_ram2ca             ; 2C14 0 208 180 CB32
idle_init_start_load_dp_ind:     LB      A, [DP]                ; 2C16 0 208 180 F2
                JNE     idle_init_start_clear_pswl_bit4             ; 2C17 0 208 180 CE06
                MOVB    off(002d8h), #0ffh     ; 2C19 0 208 180 C4D898FF
                SJ      idle_init_start_load_ram2ca             ; 2C1D 0 208 180 CB29
idle_init_start_clear_pswl_bit4:     RB      PSWL.4                 ; 2C1F 0 208 180 A30C
                SJ      idle_init_start_load_ram2ca             ; 2C21 0 208 180 CB25
idle_init_start_cmp_ram0d9:     CMPB    0d9h, #001h            ; 2C23 0 208 180 C5D9C001
                JGE     idle_init_start_load_ram2ca             ; 2C27 0 208 180 CD1F
                JBR     off(0022ch).5, idle_init_start_load_ram2ca ; 2C29 0 208 180 DD2C1C
idle_init_start_if_ram22c_bit2_set:     JBS     off(0022ch).2, idle_init_start_if_ram22c_bit0_set ; 2C2C 0 208 180 EA2C22
                JBR     off(0022ch).4, idle_init_start_load_ram2ca ; 2C2F 0 208 180 DC2C16
                JBR     off(0022ch).0, idle_init_start_load_ram2ac ; 2C32 0 208 180 D82C0A
                MOVB    r2, #0ffh              ; 2C35 0 208 180 9AFF
                LB      A, #0ffh               ; 2C37 0 208 180 77FF
                SJ      idle_init_start_store_ram2ac             ; 2C39 0 208 180 CB3E
idle_init_start_goto_2c91:     SJ      idle_init_start_load_ram247_2             ; 2C3B 0 208 180 CB54
idle_init_start_set_pswl_bit4:     SB      PSWL.4                 ; 2C3D 0 208 180 A31C
idle_init_start_load_ram2ac:     LB      A, off(002ach)         ; 2C3F 0 208 180 F4AC
                ADDB    A, off(00247h)         ; 2C41 0 208 180 8747
                JLT     idle_init_start_clear_ram22c_bit4             ; 2C43 0 208 180 CA07
                STB     A, r2                  ; 2C45 0 208 180 8A
                SJ      idle_init_start_load_carry_pswl_bit4             ; 2C46 0 208 180 CB35
idle_init_start_load_ram2ca:     MOVB    off(002cah), #0ffh     ; 2C48 0 208 180 C4CA98FF
idle_init_start_clear_ram22c_bit4:     RB      off(0022ch).4          ; 2C4C 0 208 180 C42C0C
                SJ      idle_init_start_load_carry_pswl_bit4             ; 2C4F 0 208 180 CB2C
idle_init_start_if_ram22c_bit0_set:     JBS     off(0022ch).0, idle_init_start_load_ram247 ; 2C51 0 208 180 E82C16
                JBR     off(0022ch).4, idle_init_start_load_ram2ca ; 2C54 0 208 180 DC2CF1
                LB      A, 0cch                ; 2C57 0 208 180 F5CC
                MOV     X1, #idle_init_start_tbl_2          ; 2C59 0 208 180 60BE66
                CAL     table_interp_lookup             ; 2C5C 0 208 180 323958
                STB     A, r2                  ; 2C5F 0 208 180 8A
                LB      A, 0cch                ; 2C60 0 208 180 F5CC
                MOV     X1, #idle_init_start_tbl_3          ; 2C62 0 208 180 60C666
                CAL     table_interp_lookup             ; 2C65 0 208 180 323958
                SJ      idle_init_start_store_ram2ac             ; 2C68 0 208 180 CB0F
idle_init_start_load_ram247:     LB      A, off(00247h)         ; 2C6A 0 208 180 F447
                JEQ     idle_init_start_load_r2             ; 2C6C 0 208 180 C904
                CMPB    A, #0ffh               ; 2C6E 0 208 180 C6FF
                JLT     idle_init_start_set_pswl_bit4             ; 2C70 0 208 180 CACB
idle_init_start_load_r2:     MOVB    r2, #0ffh              ; 2C72 0 208 180 9AFF
                LB      A, #0ffh               ; 2C74 0 208 180 77FF
                SB      off(0022ch).4          ; 2C76 0 208 180 C42C1C
idle_init_start_store_ram2ac:     STB     A, off(002ach)         ; 2C79 0 208 180 D4AC
                SB      PSWL.4                 ; 2C7B 0 208 180 A31C
idle_init_start_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 2C7D 0 208 180 A32C
                MB      P0.4, C                ; 2C7F 0 208 180 C5203C
                LB      A, off(002cah)         ; 2C82 0 208 180 F4CA
                JEQ     idle_init_start_clear_ram22c_bit4_2             ; 2C84 0 208 180 C906
                LB      A, (0019ch-00180h)[USP] ; 2C86 0 208 180 F31C
                JNE     idle_init_start_clear_r2_2             ; 2C88 0 208 180 CE05
                SJ      idle_init_start_load_ram247_2             ; 2C8A 0 208 180 CB05
idle_init_start_clear_ram22c_bit4_2:     RB      off(0022ch).4          ; 2C8C 0 208 180 C42C0C
idle_init_start_clear_r2_2:     CLRB    r2                     ; 2C8F 0 208 180 2215
idle_init_start_load_ram247_2:     MOVB    off(00247h), r2        ; 2C91 0 208 180 227C47
                JBR     off(00227h).0, idle_init_start_load_stk ; 2C94 0 208 180 D8272C
                J       idle_init_start_if_ram215_bit5_set             ; 2C97 0 208 180 039D2C
                DB  0FFh,0FFh,0FFh ; 2C9A
idle_init_start_if_ram215_bit5_set:     JBS     off(00215h).5, idle_init_start_load_stk ; 2C9D 0 208 180 ED1523
                JBS     off(00215h).6, idle_init_start_load_stk ; 2CA0 0 208 180 EE1520
                JBS     off(00217h).5, idle_init_start_load_stk ; 2CA3 0 208 180 ED171D
                CMPB    0dbh, #0ffh            ; 2CA6 0 208 180 C5DBC0FF
                JLT     idle_init_start_load_stk             ; 2CAA 0 208 180 CA17
                JBS     off(0022ch).0, idle_init_start_if_ram22c_bit2_clr ; 2CAC 0 208 180 E82C11
                RB      0b2h.4                 ; 2CAF 0 208 180 C5B20C
                JBR     off(0022ch).2, idle_init_start_clear_ram0b2_bit5 ; 2CB2 0 208 180 DA2C19
dtc31_at_signal_b_latch: SB      0b2h.5                 ; 2CB5 0 208 180 C5B21D
                JBS     off(0022ch).3, idle_mode_gate2 ; 2CB8 0 208 180 EB2C24
dtc30_at_signal_a_latch_2: SB      0b4h.4                 ; 2CBB 0 208 180 C5B41C
                SJ      idle_mode_gate2             ; 2CBE 0 208 180 CB1F
idle_init_start_if_ram22c_bit2_clr:     JBR     off(0022ch).2, dtc30_at_signal_a_latch ; 2CC0 0 208 180 DA2C10
idle_init_start_load_stk:     MOVB    (001b1h-00180h)[USP], #0ffh ; 2CC3 0 208 180 C33198FF
                MOVB    (001b2h-00180h)[USP], #0ffh ; 2CC7 0 208 180 C33298FF
                RB      0b2h.4                 ; 2CCB 0 208 180 C5B20C
idle_init_start_clear_ram0b2_bit5:     RB      0b2h.5                 ; 2CCE 0 208 180 C5B20D
                SJ      idle_mode_gate2             ; 2CD1 0 208 180 CB0C
dtc30_at_signal_a_latch:     SB      0b2h.4                 ; 2CD3 0 208 180 C5B21C
                RB      0b2h.5                 ; 2CD6 0 208 180 C5B20D
                JBS     off(0022ch).1, idle_mode_gate2 ; 2CD9 0 208 180 E92C03
dtc31_at_signal_b_latch_2: SB      0b4h.5                 ; 2CDC 0 208 180 C5B41D
idle_mode_gate2:     JBR     off(002b4h).0, idle_mode_gate2_load_ram098 ; 2CDF 0 208 180 D8B403
                J       transit_flag_check             ; 2CE2 0 208 180 03E32D
idle_mode_gate2_load_ram098:     L       A, 098h                ; 2CE5 1 208 180 E598
                MOV     X1, #tbl_idle_dc          ; 2CE7 1 208 180 601C6C
                CAL     table_interp_lookup_4byte             ; 2CEA 1 208 180 32D358
                MOV     er0, 09ch              ; 2CED 1 208 180 B59C48
                MUL                            ; 2CF0 1 208 180 9035
                SLL     A                      ; 2CF2 1 208 180 53
                L       A, er1                 ; 2CF3 1 208 180 35
                ROL     A                      ; 2CF4 1 208 180 33
                JGE     idle_dc_result_store             ; 2CF5 1 208 180 CD03
                L       A, #0ffffh             ; 2CF7 1 208 180 67FFFF
idle_dc_result_store:     MOV     DP, #00380h            ; 2CFA 1 208 180 628003
                ST      A, [DP]                ; 2CFD 1 208 180 D2
                MOV     er3, off(00292h)       ; 2CFE 1 208 180 B4924B
                SUB     A, off(0025eh)         ; 2D01 1 208 180 A75E
                MB      r4.0, C                ; 2D03 1 208 180 2438
                JEQ     idle_delta_flag_set             ; 2D05 1 208 180 C90D
                RB      off(00225h).6          ; 2D07 1 208 180 C4250E
                MB      off(00225h).6, C       ; 2D0A 1 208 180 C4253E
                JEQ     idle_delta_flag_check             ; 2D0D 1 208 180 C903
                XORB    PSWH, #080h            ; 2D0F 1 208 180 A2F080
idle_delta_flag_check:     JGE     idle_delta_flag_store             ; 2D12 1 208 180 CD01
idle_delta_flag_set:     SC                             ; 2D14 1 208 180 85
idle_delta_flag_store:     MB      r4.1, C                ; 2D15 1 208 180 2439
                MOV     X1, #000e1h            ; 2D17 1 208 180 60E100
                MOV     X2, #0091fh            ; 2D1A 1 208 180 611F09
                JBR     off(0020ch).0, idle_helper2_call1 ; 2D1D 1 208 180 D80C01
                VCAL    7                      ; 2D20 1 208 180 17
idle_helper2_call1:     ST      A, er0                 ; 2D21 1 208 180 88
                L       A, #00580h             ; 2D22 1 208 180 678005
                CAL     idle_helper2             ; 2D25 1 208 180 32F25A
                MOV     DP, A                  ; 2D28 1 208 180 52
                L       A, #000f0h             ; 2D29 1 208 180 67F000
                J       idle_helper2_call1_cmp_stk             ; 2D2C 1 208 180 03F578
idle_helper2_call1_xchg_acc:     XCHG    A, 098h                ; 2D2F 1 208 180 B59810
                ST      A, er0                 ; 2D32 1 208 180 88
                J       idle_helper2_call1_clear_acc             ; 2D33 1 208 180 036C7A
idle_target_store:     L       A, DP                  ; 2D36 1 208 180 42
                ST      A, off(00292h)         ; 2D37 1 208 180 D492
                L       A, er0                 ; 2D39 1 208 180 34
                CMP     A, 098h                ; 2D3A 1 208 180 B598C2
                JEQ     idle_step_default             ; 2D3D 1 208 180 C903
                JBR     off(0020ch).1, idle_debounce_gate ; 2D3F 1 208 180 D90C04
idle_step_default:     LB      A, #00ah               ; 2D42 0 208 180 770A
idle_step_store:     STB     A, (001eah-00180h)[USP] ; 2D44 0 208 180 D36A
idle_debounce_gate:     MB      C, 0b7h.1              ; 2D46 0 208 180 C5B729
                JLT     idle_debounce_disabled             ; 2D49 0 208 180 CA72
                JBR     off(00230h).2, idle_debounce_skip ; 2D4B 0 208 180 DA3047
                MOV     DP, #01f00h            ; 2D4E 0 208 180 62001F
                L       A, 0fah                ; 2D51 1 208 180 E5FA
                ST      A, IE                  ; 2D53 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 2D55 1 208 180 A2D0FE
                LB      A, P0                  ; 2D58 0 208 180 F520
                STB     A, [DP]                ; 2D5A 0 208 180 D2
                STB     A, r0                  ; 2D5B 0 208 180 88
                MOVB    r1, [DP]               ; 2D5C 0 208 180 C249
                ORB     PSWH, #001h            ; 2D5E 0 208 180 A2E001
                L       A, 0f8h                ; 2D61 1 208 180 E5F8
                ST      A, IE                  ; 2D63 1 208 180 D51A
                LB      A, r1                  ; 2D65 0 208 180 79
                CMPB    A, r0                  ; 2D66 0 208 180 48
                JNE     idle_port_p1_check             ; 2D67 0 208 180 CE1B
                MOV     DP, #02f00h            ; 2D69 0 208 180 62002F
                L       A, 0fah                ; 2D6C 1 208 180 E5FA
                ST      A, IE                  ; 2D6E 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 2D70 1 208 180 A2D0FE
                LB      A, P1                  ; 2D73 0 208 180 F522
                STB     A, [DP]                ; 2D75 0 208 180 D2
                STB     A, r0                  ; 2D76 0 208 180 88
                MOVB    r1, [DP]               ; 2D77 0 208 180 C249
                ORB     PSWH, #001h            ; 2D79 0 208 180 A2E001
                L       A, 0f8h                ; 2D7C 1 208 180 E5F8
                ST      A, IE                  ; 2D7E 1 208 180 D51A
                LB      A, r1                  ; 2D80 0 208 180 79
                CMPB    A, r0                  ; 2D81 0 208 180 48
                JEQ     idle_debounce_done             ; 2D82 0 208 180 C920
idle_port_p1_check:     LB      A, #04dh               ; 2D84 0 208 180 774D
                STB     A, 0afh                ; 2D86 0 208 180 D5AF
                DECB    0f7h                   ; 2D88 0 208 180 C5F717
                JNE     idle_debounce_skip             ; 2D8B 0 208 180 CE08
                STB     A, 0f5h                ; 2D8D 0 208 180 D5F5
                CLRB    0f6h                   ; 2D8F 0 208 180 C5F615
                J       fault_retry_check             ; 2D92 0 208 180 03E024
idle_debounce_skip:     L       A, 0fah                ; 2D95 1 208 180 E5FA
                ST      A, IE                  ; 2D97 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 2D99 1 208 180 A2D0FE
                CAL     port_debounce_helper             ; 2D9C 1 208 180 32A95B
                ORB     PSWH, #001h            ; 2D9F 1 208 180 A2E001
                SJ      idle_debounce_ie_restore             ; 2DA2 1 208 180 CB15
idle_debounce_done:     MOV     DP, #00f00h            ; 2DA4 0 208 180 62000F
                LB      A, [DP]                ; 2DA7 0 208 180 F2
                XORB    A, #038h               ; 2DA8 0 208 180 F638
                AND     IE, #002a0h            ; 2DAA 0 208 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 2DAF 0 208 180 A2D0FE
                STB     A, off(00210h)         ; 2DB2 0 208 180 D410
                STB     A, (00118h-00180h)[USP] ; 2DB4 0 208 180 D398
                ORB     PSWH, #001h            ; 2DB6 0 208 180 A2E001
idle_debounce_ie_restore:     L       A, 0f8h                ; 2DB9 1 208 180 E5F8
                ST      A, IE                  ; 2DBB 1 208 180 D51A
idle_debounce_disabled:     MOV     DP, #04700h            ; 2DBD 0 208 180 620047
                LB      A, [DP]                ; 2DC0 0 208 180 F2
                XORB    A, #01ah               ; 2DC1 0 208 180 F61A
                MB      C, off(00211h).4       ; 2DC3 0 208 180 C4112C
                AND     IE, #002a0h            ; 2DC6 0 208 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 2DCB 0 208 180 A2D0FE
                STB     A, off(00211h)         ; 2DCE 0 208 180 D411
                STB     A, (00119h-00180h)[USP] ; 2DD0 0 208 180 D399
                ORB     PSWH, #001h            ; 2DD2 0 208 180 A2E001
                L       A, 0f8h                ; 2DD5 1 208 180 E5F8
                ST      A, IE                  ; 2DD7 1 208 180 D51A
                JGE     idle_debounce_return             ; 2DD9 1 208 180 CD07
                JBS     off(00211h).4, idle_debounce_return ; 2DDB 1 208 180 EC1104
                MOVB    off(002e6h), #008h     ; 2DDE 1 208 180 C4E69808
idle_debounce_return:     RT                             ; 2DE2 1 208 180 01
transit_flag_check:     LB      A, #0ffh               ; 2DE3 0 208 180 77FF
                MOV     DP, #00393h            ; 2DE5 0 208 180 629303
                RB      TRNSIT.3               ; 2DE8 0 208 180 C5460B
                JNE     transit_flag_common             ; 2DEB 0 208 180 CE06
                SC                             ; 2DED 0 208 180 85
                LB      A, [DP]                ; 2DEE 0 208 180 F2
                JEQ     transit_flag_store             ; 2DEF 0 208 180 C903
                SUBB    A, #001h               ; 2DF1 0 208 180 A601
transit_flag_common:     RC                             ; 2DF3 0 208 180 95
transit_flag_store:     MB      off(00230h).6, C       ; 2DF4 0 208 180 C4303E
                STB     A, [DP]                ; 2DF7 0 208 180 D2
                JBR     off(002b4h).1, transit_gate_check ; 2DF8 0 208 180 D9B401
                RT                             ; 2DFB 0 208 180 01
transit_gate_check:     MOV     DP, #000deh            ; 2DFC 0 208 180 62DE00
                LB      A, 0dch                ; 2DFF 0 208 180 F5DC
                STB     A, ACCH                ; 2E01 0 208 180 D507
                CLRB    A                      ; 2E03 0 208 180 FA
                JBS     off(00214h).3, idle_scratch_store ; 2E04 0 208 180 EB140B
                MB      C, 0b1h.7              ; 2E07 0 208 180 C5B12F
                JLT     idle_task_done             ; 2E0A 0 208 180 CA11
                CMPB    0f3h, #032h            ; 2E0C 0 208 180 C5F3C032
                JGE     idle_scratch_scale             ; 2E10 0 208 180 CD04
idle_scratch_store:     MOV     [DP], A                ; 2E12 0 208 180 B28A
                SJ      idle_task_done             ; 2E14 0 208 180 CB07
idle_scratch_scale:     MOV     er0, #tbl_6000         ; 2E16 0 208 180 44980060
                CAL     mul_scale_helper2             ; 2E1A 0 208 180 320759
idle_task_done:     SB      off(00231h).0          ; 2E1D 0 208 180 C43118
                RT                             ; 2E20 0 208 180 01
vcal3_leanprotect_ratelimit_load_adcr3h:     LB      A, ADCR3H              ; 2E21 0 208 180 F567
                STB     A, off(002a1h)         ; 2E23 0 208 180 D4A1
                STB     A, r0                  ; 2E25 0 208 180 88
                RC                             ; 2E26 0 208 180 95
                JBS     off(00213h).3, dtc12_egr_latch ; 2E27 0 208 180 EB130C
                CMPB    off(00238h), #000h     ; 2E2A 0 208 180 C438C000
                MB      off(00223h).7, C       ; 2E2E 0 208 180 C4233F
                JGE     dtc12_egr_latch             ; 2E31 0 208 180 CD03
                LB      A, #0ffh               ; 2E33 0 208 180 77FF
                CMPB    A, r0                  ; 2E35 0 208 180 48
dtc12_egr_latch:     MB      0b1h.0, C              ; 2E36 0 208 180 C5B138
                JBS     off(00213h).3, vcal3_leanprotect_ratelimit_load_r0 ; 2E39 0 208 180 EB1324
                LB      A, #0ffh               ; 2E3C 0 208 180 77FF
                JGE     vcal3_leanprotect_ratelimit_if_ram21c_bit7_set             ; 2E3E 0 208 180 CD04
                STB     A, off(002edh)         ; 2E40 0 208 180 D4ED
                SJ      vcal3_leanprotect_ratelimit_load_ram2ee             ; 2E42 0 208 180 CB56
vcal3_leanprotect_ratelimit_if_ram21c_bit7_set:     JBS     off(0021ch).7, vcal3_leanprotect_ratelimit_store_ram2ed ; 2E44 0 208 180 EF1C06
                CMPB    off(0029fh), #000h     ; 2E47 0 208 180 C49FC000
                JEQ     vcal3_leanprotect_ratelimit_load_ram2ed             ; 2E4B 0 208 180 C902
vcal3_leanprotect_ratelimit_store_ram2ed:     STB     A, off(002edh)         ; 2E4D 0 208 180 D4ED
vcal3_leanprotect_ratelimit_load_ram2ed:     LB      A, off(002edh)         ; 2E4F 0 208 180 F4ED
                JNE     vcal3_leanprotect_ratelimit_load_r0             ; 2E51 0 208 180 CE0D
                LB      A, #0ffh               ; 2E53 0 208 180 77FF
                CMPB    A, r0                  ; 2E55 0 208 180 48
                JLT     vcal3_leanprotect_ratelimit_store_ram2a0             ; 2E56 0 208 180 CA06
                LB      A, #0ffh               ; 2E58 0 208 180 77FF
                CMPB    A, r0                  ; 2E5A 0 208 180 48
                JGE     vcal3_leanprotect_ratelimit_store_ram2a0             ; 2E5B 0 208 180 CD01
                LB      A, r0                  ; 2E5D 0 208 180 78
vcal3_leanprotect_ratelimit_store_ram2a0:     STB     A, off(002a0h)         ; 2E5E 0 208 180 D4A0
vcal3_leanprotect_ratelimit_load_r0:     LB      A, r0                  ; 2E60 0 208 180 78
                SUBB    A, off(002a0h)         ; 2E61 0 208 180 A7A0
                JGE     vcal3_leanprotect_ratelimit_store_ram29e             ; 2E63 0 208 180 CD01
                CLRB    A                      ; 2E65 0 208 180 FA
vcal3_leanprotect_ratelimit_store_ram29e:     STB     A, off(0029eh)         ; 2E66 0 208 180 D49E
                JBS     off(00213h).3, vcal3_leanprotect_ratelimit_load_ram2ee ; 2E68 0 208 180 EB132F
                JBS     off(00217h).5, vcal3_leanprotect_ratelimit_load_ram2ee ; 2E6B 0 208 180 ED172C
                SUBB    A, off(0029fh)         ; 2E6E 0 208 180 A79F
                JGE     vcal3_leanprotect_ratelimit_clear_ram223_bit6             ; 2E70 0 208 180 CD02
                VCAL    6                      ; 2E72 0 208 180 16
                SC                             ; 2E73 0 208 180 85
vcal3_leanprotect_ratelimit_clear_ram223_bit6:     RB      off(00223h).6          ; 2E74 0 208 180 C4230E
                MB      off(00223h).6, C       ; 2E77 0 208 180 C4233E
                JEQ     vcal3_leanprotect_ratelimit_if_lt_goto_2e9a             ; 2E7A 0 208 180 C903
                XORB    PSWH, #080h            ; 2E7C 0 208 180 A2F080
vcal3_leanprotect_ratelimit_if_lt_goto_2e9a:     JLT     vcal3_leanprotect_ratelimit_load_ram2ee             ; 2E7F 0 208 180 CA19
                CMPB    A, #006h               ; 2E81 0 208 180 C606
                JLE     vcal3_leanprotect_ratelimit_load_ram2ee             ; 2E83 0 208 180 CF15
                JBR     off(00223h).7, vcal3_leanprotect_ratelimit_load_ram2ee ; 2E85 0 208 180 DF2312
                CMPB    0dbh, #0ffh            ; 2E88 0 208 180 C5DBC0FF
                JLT     vcal3_leanprotect_ratelimit_load_ram2ee             ; 2E8C 0 208 180 CA0C
                CMPB    0beh, #030h            ; 2E8E 0 208 180 C5BEC030
                JLT     vcal3_leanprotect_ratelimit_load_ram2ee             ; 2E92 0 208 180 CA06
                CMPB    off(0029fh), #018h     ; 2E94 0 208 180 C49FC018
                JGE     vcal3_leanprotect_ratelimit_load_ram2ee_2             ; 2E98 0 208 180 CD07
vcal3_leanprotect_ratelimit_load_ram2ee:     MOVB    off(002eeh), #032h     ; 2E9A 0 208 180 C4EE9832
vcal3_leanprotect_ratelimit_clear_carry:     RC                             ; 2E9E 0 208 180 95
                SJ      dtc12_egr_latch_2             ; 2E9F 0 208 180 CB05
vcal3_leanprotect_ratelimit_load_ram2ee_2:     LB      A, off(002eeh)         ; 2EA1 0 208 180 F4EE
                JNE     vcal3_leanprotect_ratelimit_clear_carry             ; 2EA3 0 208 180 CEF9
                SC                             ; 2EA5 0 208 180 85
dtc12_egr_latch_2:     MB      0b1h.1, C              ; 2EA6 0 208 180 C5B139
                CLR     A                      ; 2EA9 1 208 180 F9
                MOV     DP, A                  ; 2EAA 1 208 180 52
                ST      A, er0                 ; 2EAB 1 208 180 88
                RC                             ; 2EAC 1 208 180 95
                LB      A, off(0029fh)         ; 2EAD 0 208 180 F49F
                JEQ     vcal3_leanprotect_ratelimit_load_ram2a4             ; 2EAF 0 208 180 C925
                L       A, off(002a2h)         ; 2EB1 1 208 180 E4A2
                JNE     vcal3_leanprotect_ratelimit_store_er3             ; 2EB3 1 208 180 CE03
                L       A, #09fffh             ; 2EB5 1 208 180 67FF9F
vcal3_leanprotect_ratelimit_store_er3:     ST      A, er3                 ; 2EB8 1 208 180 8B
                LB      A, off(0029eh)         ; 2EB9 0 208 180 F49E
                SUBB    A, off(0029fh)         ; 2EBB 0 208 180 A79F
                MB      r4.0, C                ; 2EBD 0 208 180 2438
                JGE     vcal3_leanprotect_ratelimit_store_r0             ; 2EBF 0 208 180 CD01
                VCAL    6                      ; 2EC1 0 208 180 16
vcal3_leanprotect_ratelimit_store_r0:     STB     A, r0                  ; 2EC2 0 208 180 88
                L       A, #09fffh             ; 2EC3 1 208 180 67FF9F
                MOV     X1, #09fffh            ; 2EC6 1 208 180 60FF9F
                MOV     X2, #09fffh            ; 2EC9 1 208 180 61FF9F
                CAL     vcal3_leanprotect_ratelimit_sub_mul_acc_2             ; 2ECC 1 208 180 32E65A
                MOV     DP, A                  ; 2ECF 1 208 180 52
                L       A, #09fffh             ; 2ED0 1 208 180 67FF9F
                CAL     vcal3_leanprotect_ratelimit_sub_mul_acc_2             ; 2ED3 1 208 180 32E65A
vcal3_leanprotect_ratelimit_load_ram2a4:     MOV     off(002a4h), A         ; 2ED6 1 208 180 B4A48A
                JLT     vcal3_leanprotect_ratelimit_load_ram2a4_2             ; 2ED9 1 208 180 CA03
                MOV     off(002a2h), DP        ; 2EDB 1 208 180 927CA2
vcal3_leanprotect_ratelimit_load_ram2a4_2:     L       A, off(002a4h)         ; 2EDE 1 208 180 E4A4
                MOV     er0, #00050h           ; 2EE0 1 208 180 44985000
                MUL                            ; 2EE4 1 208 180 9035
                SRL     A                      ; 2EE6 1 208 180 63
                SRL     A                      ; 2EE7 1 208 180 63
                SRL     A                      ; 2EE8 1 208 180 63
                SRL     A                      ; 2EE9 1 208 180 63
                L       A, ACC                 ; 2EEA 1 208 180 E506
                JNE     vcal3_leanprotect_ratelimit_vcal_7             ; 2EEC 1 208 180 CE03
                L       A, #00001h             ; 2EEE 1 208 180 670100
vcal3_leanprotect_ratelimit_vcal_7:     VCAL    7                      ; 2EF1 1 208 180 17
                AND     IE, #002a0h            ; 2EF2 1 208 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 2EF7 1 208 180 A2D0FE
                ST      A, 0e6h                ; 2EFA 1 208 180 D5E6
                LB      A, #031h               ; 2EFC 0 208 180 7731
                SUBB    A, r2                  ; 2EFE 0 208 180 2A
                STB     A, 0e5h                ; 2EFF 0 208 180 D5E5
                ORB     PSWH, #001h            ; 2F01 0 208 180 A2E001
                L       A, 0f8h                ; 2F04 1 208 180 E5F8
                ST      A, IE                  ; 2F06 1 208 180 D51A
                RT                             ; 2F08 1 208 180 01
battery_voltage_check:     MB      C, off(0022bh).2       ; 2F09 1 208 180 C42B2A
                MB      off(0022bh).3, C       ; 2F0C 1 208 180 C42B3B
                CLRB    A                      ; 2F0F 0 208 180 FA
                MB      C, off(0021ah).4       ; 2F10 0 208 180 C41A2C
                ROLB    A                      ; 2F13 0 208 180 33
                MB      C, off(00210h).3       ; 2F14 0 208 180 C4102B
                ROLB    A                      ; 2F17 0 208 180 33
                MB      C, off(00211h).2       ; 2F18 0 208 180 C4112A
                ROLB    A                      ; 2F1B 0 208 180 33
                MB      C, off(00211h).5       ; 2F1C 0 208 180 C4112D
                ROLB    A                      ; 2F1F 0 208 180 33
                STB     A, r0                  ; 2F20 0 208 180 88
                XORB    A, off(00229h)         ; 2F21 0 208 180 F729
                ANDB    A, #00fh               ; 2F23 0 208 180 D60F
                SWAPB                          ; 2F25 0 208 180 83
                ORB     A, r0                  ; 2F26 0 208 180 68
                STB     A, off(00229h)         ; 2F27 0 208 180 D429
                LB      A, 0dch                ; 2F29 0 208 180 F5DC
                STB     A, r0                  ; 2F2B 0 208 180 88
                XCHGB   A, 0ddh                ; 2F2C 0 208 180 C5DD10
                SUBB    A, r0                  ; 2F2F 0 208 180 28
                MB      off(00225h).2, C       ; 2F30 0 208 180 C4253A
                J       battery_voltage_check_if_ge_goto_782e             ; 2F33 0 208 180 032B78
                DW  00000h           ; 2F36
battery_voltage_check_load_imm:     LB      A, #050h               ; 2F38 0 208 180 7750
                JBS     off(0022ah).4, threshold_bank_check1 ; 2F3A 0 208 180 EC2A02
                LB      A, #030h               ; 2F3D 0 208 180 7730
threshold_bank_check1:     CMPB    r0, A                  ; 2F3F 0 208 180 20C1
                MB      off(0022ah).4, C       ; 2F41 0 208 180 C42A3C
                LB      A, #078h               ; 2F44 0 208 180 7778
                JBS     off(0022ah).5, threshold_bank_check2 ; 2F46 0 208 180 ED2A02
                LB      A, #070h               ; 2F49 0 208 180 7770
threshold_bank_check2:     CMPB    r0, A                  ; 2F4B 0 208 180 20C1
                MB      off(0022ah).5, C       ; 2F4D 0 208 180 C42A3D
                LB      A, #050h               ; 2F50 0 208 180 7750
                JBS     off(0022ah).6, threshold_bank_check3 ; 2F52 0 208 180 EE2A02
                LB      A, #030h               ; 2F55 0 208 180 7730
threshold_bank_check3:     CMPB    r0, A                  ; 2F57 0 208 180 20C1
                MB      off(0022ah).6, C       ; 2F59 0 208 180 C42A3E
                LB      A, #0feh               ; 2F5C 0 208 180 77FE
                JBS     off(0022ah).0, cmp_0e1_select_b0_c0 ; 2F5E 0 208 180 E82A02
                LB      A, #0ffh               ; 2F61 0 208 180 77FF
cmp_0e1_select_b0_c0:     CMPB    A, 0e1h                ; 2F63 0 208 180 C5E1C2
                MB      off(0022ah).0, C       ; 2F66 0 208 180 C42A38
                LB      A, #0b0h               ; 2F69 0 208 180 77B0
                JBS     off(0022ah).1, idle_temp_hyst1 ; 2F6B 0 208 180 E92A02
                LB      A, #0c0h               ; 2F6E 0 208 180 77C0
idle_temp_hyst1:     CMPB    A, 0e1h                ; 2F70 0 208 180 C5E1C2
                MB      off(0022ah).1, C       ; 2F73 0 208 180 C42A39
                LB      A, #066h               ; 2F76 0 208 180 7766
                JBS     off(0022ah).2, idle_temp_hyst2 ; 2F78 0 208 180 EA2A02
                LB      A, #073h               ; 2F7B 0 208 180 7773
idle_temp_hyst2:     CMPB    A, off(00238h)         ; 2F7D 0 208 180 C738
                MB      off(0022ah).2, C       ; 2F7F 0 208 180 C42A3A
                LB      A, #0ddh               ; 2F82 0 208 180 77DD
                JBS     off(0022ah).3, idle_temp_hyst3 ; 2F84 0 208 180 EB2A02
                LB      A, #0e0h               ; 2F87 0 208 180 77E0
idle_temp_hyst3:     CMPB    A, off(00238h)         ; 2F89 0 208 180 C738
                MB      off(0022ah).3, C       ; 2F8B 0 208 180 C42A3B
                MB      C, off(0021ah).0       ; 2F8E 0 208 180 C41A28
                MB      off(00225h).4, C       ; 2F91 0 208 180 C4253C
                JBS     off(0022bh).4, idle_temp_hyst3_set_carry ; 2F94 0 208 180 EC2B36
                MB      C, 0b0h.1              ; 2F97 0 208 180 C5B029
                JLT     idle_temp_hyst3_set_carry             ; 2F9A 0 208 180 CA31
                JBS     off(00212h).5, idle_temp_hyst3_set_carry ; 2F9C 0 208 180 ED122E
                JBR     off(00217h).5, idle_temp_hyst3_if_ram216_bit3_clr ; 2F9F 0 208 180 DD170A
                CMPB    0d8h, #030h            ; 2FA2 0 208 180 C5D8C030
                MB      off(0022ah).7, C       ; 2FA6 0 208 180 C42A3F
                RC                             ; 2FA9 0 208 180 95
                SJ      idle_temp_hyst3_store_carry_ram21a_bit0             ; 2FAA 0 208 180 CB22
idle_temp_hyst3_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_temp_hyst3_if_ram21a_bit2_set ; 2FAC 0 208 180 DB1603
                JBR     off(00211h).5, idle_temp_hyst3_set_carry ; 2FAF 0 208 180 DD111B
idle_temp_hyst3_if_ram21a_bit2_set:     JBS     off(0021ah).2, idle_temp_hyst3_set_carry ; 2FB2 0 208 180 EA1A18
                CMPB    off(00238h), #080h     ; 2FB5 0 208 180 C438C080
                JGE     idle_temp_hyst3_set_carry             ; 2FB9 0 208 180 CD12
                LB      A, #0feh               ; 2FBB 0 208 180 77FE
                JBR     off(0022ah).7, idle_temp_hyst3_cmp_acc ; 2FBD 0 208 180 DF2A02
                LB      A, #0feh               ; 2FC0 0 208 180 77FE
idle_temp_hyst3_cmp_acc:     CMPB    A, 0f3h                ; 2FC2 0 208 180 C5F3C2
                JGE     idle_temp_hyst3_load_ram0d9             ; 2FC5 0 208 180 CD0A
                CMPB    0d9h, #03bh            ; 2FC7 0 208 180 C5D9C03B
                JGE     idle_temp_hyst3_load_ram0d9             ; 2FCB 0 208 180 CD04
idle_temp_hyst3_set_carry:     SC                             ; 2FCD 0 208 180 85
idle_temp_hyst3_store_carry_ram21a_bit0:     MB      off(0021ah).0, C       ; 2FCE 0 208 180 C41A38
idle_temp_hyst3_load_ram0d9:     LB      A, 0d9h                ; 2FD1 0 208 180 F5D9
                STB     A, r0                  ; 2FD3 0 208 180 88
                MOV     X1, #IdleVsECT          ; 2FD4 0 208 180 60CB68
                MOV     X2, #idle_temp_hyst3_tbl          ; 2FD7 0 208 180 61F568
                MOVB    r2, #034h              ; 2FDA 0 208 180 9A34
                CMPB    A, #016h               ; 2FDC 0 208 180 C616
                JGE     idle_temp_hyst3_cmp_acc_2             ; 2FDE 0 208 180 CD0C
idle_temp_hyst3_load_r1:     MOVB    r1, r2                 ; 2FE0 0 208 180 2249
                L       A, #0090bh             ; 2FE2 1 208 180 670B09
                MOV     er3, #00600h           ; 2FE5 1 208 180 47980006
                J       idle_target_correction_start             ; 2FE9 1 208 180 037230
idle_temp_hyst3_cmp_acc_2:     CMPB    A, r2                  ; 2FEC 0 208 180 4A
                JGE     idle_ectvs_result3             ; 2FED 0 208 180 CD7F
                MOVB    r1, #031h              ; 2FEF 0 208 180 9931
                JBS     off(00217h).6, idle_temp_hyst3_if_ram22a_bit4_clr ; 2FF1 0 208 180 EE1722
                CMP     off(00274h), #08000h   ; 2FF4 0 208 180 B474C00080
                JGE     idle_temp_hyst3_cmp_acc_3             ; 2FF9 0 208 180 CD0F
                CMP     off(00274h), #00780h   ; 2FFB 0 208 180 B474C08007
                JBS     off(00216h).3, idle_temp_hyst3_if_ge_goto_2fe0 ; 3000 0 208 180 EB1605
                CMP     off(00274h), #00780h   ; 3003 0 208 180 B474C08007
idle_temp_hyst3_if_ge_goto_2fe0:     JGE     idle_temp_hyst3_load_r1             ; 3008 0 208 180 CDD6
idle_temp_hyst3_cmp_acc_3:     CMPB    A, r1                  ; 300A 0 208 180 49
                JGE     idle_ectvs_result3             ; 300B 0 208 180 CD61
idle_ectvs_flag_check_load_imm:     L       A, #009c4h             ; 300D 1 208 180 67C409
                MOV     er3, #00380h           ; 3010 1 208 180 47988003
                SJ      idle_target_correction_start             ; 3014 1 208 180 CB5C
idle_temp_hyst3_if_ram22a_bit4_clr:     JBR     off(0022ah).4, idle_temp_hyst3_if_ram225_bit1_clr ; 3016 0 208 180 DC2A0A
                MOVB    off(002e8h), #000h     ; 3019 0 208 180 C4E89800
                MOVB    off(002e9h), #05ah     ; 301D 0 208 180 C4E9985A
                SJ      idle_temp_hyst3_load_r1             ; 3021 0 208 180 CBBD
idle_temp_hyst3_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_temp_hyst3_cmp_acc_4 ; 3023 0 208 180 D92506
                CMPB    off(002e8h), #000h     ; 3026 0 208 180 C4E8C000
                JNE     idle_temp_hyst3_load_r1             ; 302A 0 208 180 CEB4
idle_temp_hyst3_cmp_acc_4:     CMPB    A, r1                  ; 302C 0 208 180 49
                JGE     idle_ectvs_result3             ; 302D 0 208 180 CD3F
                L       A, off(0027ch)         ; 302F 1 208 180 E47C
                JEQ     idle_ectvs_flag_check             ; 3031 1 208 180 C904
                MOVB    off(002e5h), #01eh     ; 3033 1 208 180 C4E5981E
idle_ectvs_flag_check:     LB      A, off(002e5h)         ; 3037 0 208 180 F4E5
                JNE     idle_ectvs_flag_check_load_imm             ; 3039 0 208 180 CED2
                JBR     off(0022ah).5, idle_ectvs_flag_check_if_ram225_bit1_clr ; 303B 0 208 180 DD2A06
                MOVB    off(002e9h), #05ah     ; 303E 0 208 180 C4E9985A
                SJ      idle_ectvs_flag_check_load_imm             ; 3042 0 208 180 CBC9
idle_ectvs_flag_check_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_flag_check_if_ram216_bit3_clr ; 3044 0 208 180 D92504
                LB      A, off(002e9h)         ; 3047 0 208 180 F4E9
                JNE     idle_ectvs_flag_check_load_imm             ; 3049 0 208 180 CEC2
idle_ectvs_flag_check_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_ectvs_flag_check_load_r1 ; 304B 0 208 180 DB1610
                MOVB    r1, #02fh              ; 304E 0 208 180 992F
                LB      A, r0                  ; 3050 0 208 180 78
                CMPB    A, r1                  ; 3051 0 208 180 49
                JGE     idle_ectvs_result3             ; 3052 0 208 180 CD1A
                L       A, #00a77h             ; 3054 1 208 180 67770A
                MOV     er3, #00100h           ; 3057 1 208 180 47980001
                JBS     off(00211h).5, idle_target_correction_start ; 305B 1 208 180 ED1114
idle_ectvs_flag_check_load_r1:     MOVB    r1, #02ch              ; 305E 1 208 180 992C
                LB      A, r0                  ; 3060 0 208 180 78
                CMPB    A, r1                  ; 3061 0 208 180 49
                JGE     idle_ectvs_result3             ; 3062 0 208 180 CD0A
                L       A, #00b44h             ; 3064 1 208 180 67440B
                MOV     er3, #00080h           ; 3067 1 208 180 47988000
                JBS     off(00225h).1, idle_target_correction_start ; 306B 1 208 180 E92504
idle_ectvs_result3:     LB      A, r0                  ; 306E 0 208 180 78
                VCAL    0                      ; 306F 0 208 180 10
                CLR     er3                    ; 3070 0 208 180 4715
idle_target_correction_start:     MOV     DP, A                  ; 3072 1 208 180 52
                L       A, er3                 ; 3073 1 208 180 37
                JEQ     idle_target_correction_done             ; 3074 1 208 180 C924
                MOV     X1, #IdleVsECT          ; 3076 1 208 180 60CB68
                LCB     A, 0000fh[X1]          ; 3079 1 208 180 90AB0F00
                MOVB    r4, A                  ; 307D 1 208 180 248A
                SUBB    r0, A                  ; 307F 1 208 180 20A1
                L       A, er3                 ; 3081 1 208 180 37
                JLE     idle_target_correction_done             ; 3082 1 208 180 CF16
                CLRB    A                      ; 3084 0 208 180 FA
                STB     A, r5                  ; 3085 0 208 180 8D
                XCHGB   A, r1                  ; 3086 0 208 180 2110
                CMPB    A, 0d9h                ; 3088 0 208 180 C5D9C2
                JLE     idle_target_correction_zero             ; 308B 0 208 180 CF0C
                XCHGB   A, r4                  ; 308D 0 208 180 2410
                SUBB    r4, A                  ; 308F 0 208 180 24A1
                JLE     idle_target_correction_zero             ; 3091 0 208 180 CF06
                CLR     A                      ; 3093 1 208 180 F9
                CAL     injtimer_bank_calc3             ; 3094 1 208 180 32BA58
                SJ      idle_target_correction_done             ; 3097 1 208 180 CB01
idle_target_correction_zero:     CLR     A                      ; 3099 1 208 180 F9
idle_target_correction_done:     ST      A, off(0027ah)         ; 309A 1 208 180 D47A
                L       A, DP                  ; 309C 1 208 180 42
                JBS     off(0021ah).0, idle_target_correction_done_store_ram25c ; 309D 1 208 180 E81A09
                LB      A, 0d9h                ; 30A0 0 208 180 F5D9
                MOV     X1, #idle_target_correction_done_tbl          ; 30A2 0 208 180 60E068
                VCAL    0                      ; 30A5 0 208 180 10
                MOV     X2, #idle_target_correction_done_tbl_2          ; 30A6 0 208 180 611169
idle_target_correction_done_store_ram25c:     STB     A, off(0025ch)         ; 30A9 0 208 180 D45C
                MOV     X1, X2                 ; 30AB 0 208 180 9178
                LB      A, 0d9h                ; 30AD 0 208 180 F5D9
                CAL     table_interp_lookup             ; 30AF 0 208 180 323958
                STB     A, r2                  ; 30B2 0 208 180 8A
                MOV     X1, X2                 ; 30B3 0 208 180 9178
                ADD     X1, #0000eh            ; 30B5 0 208 180 90800E00
                LB      A, 0d9h                ; 30B9 0 208 180 F5D9
                CAL     table_interp_lookup             ; 30BB 0 208 180 323958
                STB     A, ACCH                ; 30BE 0 208 180 D507
                LB      A, r2                  ; 30C0 0 208 180 7A
                MOV     off(00296h), A         ; 30C1 0 208 180 B4968A
                L       A, off(0025ch)         ; 30C4 1 208 180 E45C
                MOV     X1, #tbl_idle_pid_lo3          ; 30C6 1 208 180 60326A
                MOV     X2, #tbl_idle_pid_hi3          ; 30C9 1 208 180 617A6A
                CMP     A, #00964h             ; 30CC 1 208 180 C66409
                JLT     idle_pid_table_select2             ; 30CF 1 208 180 CA11
                MOV     X1, #tbl_idle_pid_lo2          ; 30D1 1 208 180 60266A
                MOV     X2, #tbl_idle_pid_hi2          ; 30D4 1 208 180 61686A
                CMP     A, #00a08h             ; 30D7 1 208 180 C6080A
                JLT     idle_pid_table_select2             ; 30DA 1 208 180 CA06
                MOV     X1, #tbl_idle_pid_lo1          ; 30DC 1 208 180 601A6A
                MOV     X2, #tbl_idle_pid_hi1          ; 30DF 1 208 180 61566A
idle_pid_table_select2:     JBS     off(00217h).6, idle_pid_table_lookup ; 30E2 1 208 180 EE1711
                MOV     X1, #tbl_idle_pid_b          ; 30E5 1 208 180 604A6A
                MOV     X2, #tbl_idle_pid_d          ; 30E8 1 208 180 619E6A
                CMP     A, #00964h             ; 30EB 1 208 180 C66409
                JLT     idle_pid_table_lookup             ; 30EE 1 208 180 CA06
                MOV     X1, #tbl_idle_pid_a          ; 30F0 1 208 180 603E6A
                MOV     X2, #tbl_idle_pid_c          ; 30F3 1 208 180 618C6A
idle_pid_table_lookup:     LB      A, off(00238h)         ; 30F6 0 208 180 F438
                CAL     table_interp_lookup             ; 30F8 0 208 180 323958
                MOVB    r0, 0e1h               ; 30FB 0 208 180 C5E148
                MULB                           ; 30FE 0 208 180 A234
                L       A, ACC                 ; 3100 1 208 180 E506
                ROL     A                      ; 3102 1 208 180 33
                LB      A, ACCH                ; 3103 0 208 180 F507
                JGE     idle_pid_mul_apply             ; 3105 0 208 180 CD02
                LB      A, #0ffh               ; 3107 0 208 180 77FF
idle_pid_mul_apply:     MOV     X1, X2                 ; 3109 0 208 180 9178
                VCAL    0                      ; 310B 0 208 180 10
                MOV     DP, #0037ah            ; 310C 0 208 180 627A03
                MOVB    r1, [DP]               ; 310F 0 208 180 C249
                CLRB    r0                     ; 3111 0 208 180 2015
                MUL                            ; 3113 0 208 180 9035
                ROLB    A                      ; 3115 0 208 180 33
                L       A, er1                 ; 3116 1 208 180 35
                ROL     A                      ; 3117 1 208 180 33
                JGE     idle_p0_pin_check             ; 3118 1 208 180 CD03
                L       A, #0ffffh             ; 311A 1 208 180 67FFFF
idle_p0_pin_check:     MB      C, P0.2                ; 311D 1 208 180 C5202A
                JGE     idle_pid_er3_store             ; 3120 1 208 180 CD07
                MOVB    r1, #040h              ; 3122 1 208 180 9940
                CLRB    r0                     ; 3124 1 208 180 2015
                MUL                            ; 3126 1 208 180 9035
                L       A, er1                 ; 3128 1 208 180 35
idle_pid_er3_store:     ST      A, er3                 ; 3129 1 208 180 8B
                JBS     off(0022bh).4, idle_pid_common ; 312A 1 208 180 EC2B4E
                MOVB    r1, #003h              ; 312D 1 208 180 9903
                JBS     off(00235h).0, idle_pid_gate2 ; 312F 1 208 180 E83503
                JBS     off(00225h).1, idle_pid_gate3 ; 3132 1 208 180 E92534
idle_pid_gate2:     JBS     off(00211h).2, idle_pid_common ; 3135 1 208 180 EA1143
                JBS     off(0022ah).0, idle_pid_common ; 3138 1 208 180 E82A40
                LB      A, #028h               ; 313B 0 208 180 7728
                CLRB    r1                     ; 313D 0 208 180 2115
                JBS     off(0022bh).5, idle_pid_recheck2 ; 313F 0 208 180 ED2B04
                LB      A, #028h               ; 3142 0 208 180 7728
                MOVB    r1, #003h              ; 3144 0 208 180 9903
idle_pid_recheck2:     MOVB    r2, 0e2h               ; 3146 0 208 180 C5E24A
                MB      C, off(0022bh).5       ; 3149 0 208 180 C42B2D
                JBR     off(00217h).6, idle_pid_hyst_check ; 314C 0 208 180 DE1711
                LB      A, #028h               ; 314F 0 208 180 7728
                CLRB    r1                     ; 3151 0 208 180 2115
                JBS     off(00225h).2, idle_pid_hyst_calc ; 3153 0 208 180 EA2504
                LB      A, #028h               ; 3156 0 208 180 7728
                MOVB    r1, #003h              ; 3158 0 208 180 9903
idle_pid_hyst_calc:     MOVB    r2, 0e0h               ; 315A 0 208 180 C5E04A
                MB      C, off(00225h).2       ; 315D 0 208 180 C4252A
idle_pid_hyst_check:     MB      PSWL.4, C              ; 3160 0 208 180 A33C
                CMPB    A, r2                  ; 3162 0 208 180 4A
                JGE     idle_pid_common             ; 3163 0 208 180 CD16
                MB      C, PSWL.4              ; 3165 0 208 180 A32C
                JLT     idle_pid_p0_check             ; 3167 0 208 180 CA06
idle_pid_gate3:     LB      A, off(0029bh)         ; 3169 0 208 180 F49B
                JEQ     idle_pid_flag_store             ; 316B 0 208 180 C907
                SJ      idle_pid_flag_clear             ; 316D 0 208 180 CB08
idle_pid_p0_check:     MB      C, P0.2                ; 316F 0 208 180 C5202A
                JLT     idle_pid_flag_clear             ; 3172 0 208 180 CA03
idle_pid_flag_store:     MOVB    off(0029bh), r1        ; 3174 0 208 180 217C9B
idle_pid_flag_clear:     CLRB    r5                     ; 3177 0 208 180 2515
                SJ      idle_pid_diff_calc             ; 3179 0 208 180 CB16
idle_pid_common:     L       A, off(00268h)         ; 317B 1 208 180 E468
                XCHG    A, er3                 ; 317D 1 208 180 4710
                MOVB    r5, off(00295h)        ; 317F 1 208 180 C4954D
                CLRB    r4                     ; 3182 1 208 180 2415
                MOVB    r1, #010h              ; 3184 1 208 180 9910
                JBS     off(00217h).6, idle_pid_track_call ; 3186 1 208 180 EE1702
                MOVB    r1, #010h              ; 3189 1 208 180 9910
idle_pid_track_call:     CLRB    r0                     ; 318B 1 208 180 2015
                CAL     rpm_accel_track_helper             ; 318D 1 208 180 321559
                ST      A, er3                 ; 3190 1 208 180 8B
idle_pid_diff_calc:     L       A, er3                 ; 3191 1 208 180 37
                SUB     A, off(00268h)         ; 3192 1 208 180 A768
                ST      A, er0                 ; 3194 1 208 180 88
                JGE     idle_pid_diff_clamp             ; 3195 1 208 180 CD01
                VCAL    7                      ; 3197 1 208 180 17
idle_pid_diff_clamp:     CMP     A, #00020h             ; 3198 1 208 180 C62000
                JBS     off(00217h).6, idle_pid_diff_zero ; 319B 1 208 180 EE1703
                CMP     A, #00020h             ; 319E 1 208 180 C62000
idle_pid_diff_zero:     CLR     A                      ; 31A1 1 208 180 F9
                JLT     idle_pid_diff_store             ; 31A2 1 208 180 CA01
                L       A, er0                 ; 31A4 1 208 180 34
idle_pid_diff_store:     ST      A, off(0026ah)         ; 31A5 1 208 180 D46A
                L       A, off(00278h)         ; 31A7 1 208 180 E478
                SUB     A, #000c0h             ; 31A9 1 208 180 A6C000
                JGE     idle_pid_flag_recheck             ; 31AC 1 208 180 CD01
                CLR     A                      ; 31AE 1 208 180 F9
idle_pid_flag_recheck:     CMPB    off(0029bh), #000h     ; 31AF 1 208 180 C49BC000
                JEQ     idle_pid_store_final             ; 31B3 1 208 180 C90C
                L       A, #00780h             ; 31B5 1 208 180 678007
                JBS     off(00217h).6, idle_pid_decrement ; 31B8 1 208 180 EE1703
                L       A, #00780h             ; 31BB 1 208 180 678007
idle_pid_decrement:     DECB    off(0029bh)            ; 31BE 1 208 180 C49B17
idle_pid_store_final:     MOV     off(00268h), er3       ; 31C1 1 208 180 477C68
                ST      A, off(00278h)         ; 31C4 1 208 180 D478
                MOVB    off(00295h), r5        ; 31C6 1 208 180 257C95
                MB      C, off(00225h).1       ; 31C9 1 208 180 C42529
                MB      off(00235h).0, C       ; 31CC 1 208 180 C43538
                JBR     off(00226h).4, idle_integrator_check2 ; 31CF 1 208 180 DC263F
                MOV     X1, #tbl_idle_pid_final1          ; 31D2 1 208 180 60BA6A
                JBS     off(00216h).3, to_idle_integrator_store ; 31D5 1 208 180 EB1603
                MOV     X1, #idle_pid_store_final_tbl          ; 31D8 1 208 180 60C96A
to_idle_integrator_store:     LB      A, 0d8h                ; 31DB 0 208 180 F5D8
                VCAL    0                      ; 31DD 0 208 180 10
                SLLB    A                      ; 31DE 0 208 180 53
                MOV     X2, A                  ; 31DF 0 208 180 51
                MOV     X1, #tbl_idle_pid_final2          ; 31E0 0 208 180 60D86A
                LB      A, off(00238h)         ; 31E3 0 208 180 F438
                CAL     table_interp_lookup             ; 31E5 0 208 180 323958
                L       A, er3                 ; 31E8 1 208 180 37
                SWAP                           ; 31E9 1 208 180 83
                CLRB    A                      ; 31EA 0 208 180 FA
                MOV     er0, X2                ; 31EB 0 208 180 9148
                MUL                            ; 31ED 0 208 180 9035
                MOV     DP, #0037eh            ; 31EF 0 208 180 627E03
                L       A, off(00282h)         ; 31F2 1 208 180 E482
                JEQ     idle_integrator_reset             ; 31F4 1 208 180 C90C
                JBS     off(00283h).7, idle_integrator_reset ; 31F6 1 208 180 EF8309
                L       A, [DP]                ; 31F9 1 208 180 E2
                SUB     A, #00100h             ; 31FA 1 208 180 A60001
                JGE     idle_integrator_store             ; 31FD 1 208 180 CD06
                CLR     A                      ; 31FF 1 208 180 F9
                SJ      idle_integrator_store             ; 3200 1 208 180 CB03
idle_integrator_reset:     L       A, #00580h             ; 3202 1 208 180 678005
idle_integrator_store:     ST      A, [DP]                ; 3205 1 208 180 D2
                ADD     A, er1                 ; 3206 1 208 180 09
                CMP     A, #08000h             ; 3207 1 208 180 C60080
                JLT     idle_integrator_final_store             ; 320A 1 208 180 CA18
                L       A, #07fffh             ; 320C 1 208 180 67FF7F
                SJ      idle_integrator_final_store             ; 320F 1 208 180 CB13
idle_integrator_check2:     L       A, off(00282h)         ; 3211 1 208 180 E482
                JEQ     idle_integrator_final_store             ; 3213 1 208 180 C90F
                JBR     off(00283h).7, idle_integrator_fault ; 3215 1 208 180 DF8308
                ADD     A, #00010h             ; 3218 1 208 180 861000
                JGE     idle_integrator_final_store             ; 321B 1 208 180 CD07
                CLR     A                      ; 321D 1 208 180 F9
                SJ      idle_integrator_final_store             ; 321E 1 208 180 CB04
idle_integrator_fault:     L       A, #00500h             ; 3220 1 208 180 670005
                VCAL    7                      ; 3223 1 208 180 17
idle_integrator_final_store:     ST      A, off(00282h)         ; 3224 1 208 180 D482
                CLR     A                      ; 3226 1 208 180 F9
                MOV     DP, A                  ; 3227 1 208 180 52
                JBR     off(00216h).3, to_idle_output_finalize ; 3228 1 208 180 DB1611
                JBR     off(00211h).5, idle_integrator_final_store_cmp_ram0d9 ; 322B 1 208 180 DD1114
                CMPB    0d9h, #03ah            ; 322E 1 208 180 C5D9C03A
                JLT     clear_a_default             ; 3232 1 208 180 CA07
                L       A, off(00276h)         ; 3234 1 208 180 E476
                SUB     A, #00040h             ; 3236 1 208 180 A64000
                JGE     idle_output_finalize             ; 3239 1 208 180 CD3A
clear_a_default:     CLR     A                      ; 323B 1 208 180 F9
to_idle_output_finalize:     MOVB    off(002e4h), #014h     ; 323C 1 208 180 C4E49814
                SJ      idle_output_finalize             ; 3240 1 208 180 CB33
idle_integrator_final_store_cmp_ram0d9:     CMPB    0d9h, #03ah            ; 3242 1 208 180 C5D9C03A
                JLT     inc_dp_step_load_ram0d9             ; 3246 1 208 180 CA13
                LB      A, off(002e4h)         ; 3248 0 208 180 F4E4
                JEQ     inc_dp_step             ; 324A 0 208 180 C90E
                JBS     off(0021bh).6, idle_integrator_final_store_load_ram276 ; 324C 0 208 180 EE1B07
                CMP     0c6h, #00004h          ; 324F 0 208 180 B5C6C00400
                JGE     inc_dp_step             ; 3254 0 208 180 CD04
idle_integrator_final_store_load_ram276:     L       A, off(00276h)         ; 3256 1 208 180 E476
                JEQ     idle_output_finalize_srl_dp             ; 3258 1 208 180 C91D
inc_dp_step:     INC     DP                     ; 325A 1 208 180 72
inc_dp_step_load_ram0d9:     LB      A, 0d9h                ; 325B 0 208 180 F5D9
                MOV     X1, #inc_dp_step_tbl          ; 325D 0 208 180 60E26A
                VCAL    0                      ; 3260 0 208 180 10
                MOV     X2, A                  ; 3261 0 208 180 51
                CMPB    0d9h, #034h            ; 3262 0 208 180 C5D9C034
                JGE     load_x2_result             ; 3266 0 208 180 CD0C
                MOV     X1, #inc_dp_step_tbl_2          ; 3268 0 208 180 60FD6A
                L       A, off(0025ch)         ; 326B 1 208 180 E45C
                CAL     table_interp_lookup_4byte             ; 326D 1 208 180 32D358
                CMP     A, X2                  ; 3270 1 208 180 91C2
                JGE     idle_output_finalize             ; 3272 1 208 180 CD01
load_x2_result:     L       A, X2                  ; 3274 1 208 180 41
idle_output_finalize:     ST      A, off(00276h)         ; 3275 1 208 180 D476
idle_output_finalize_srl_dp:     SRL     DP                     ; 3277 1 208 180 92E7
                MB      off(00225h).3, C       ; 3279 1 208 180 C4253B
                CLRB    A                      ; 327C 0 208 180 FA
                RC                             ; 327D 0 208 180 95
                JBS     off(00217h).5, idle_pid_result_store ; 327E 0 208 180 ED171C
                JBR     off(0022bh).2, idle_pid_gate4 ; 3281 0 208 180 DA2B13
                JBR     off(00210h).3, idle_pid_gate5 ; 3284 0 208 180 DB1013
                MOV     X1, #00400h            ; 3287 0 208 180 600004
                LB      A, off(00299h)         ; 328A 0 208 180 F499
                JEQ     idle_pid_x1_select             ; 328C 0 208 180 C906
                DECB    off(00299h)            ; 328E 0 208 180 C49917
                MOV     X1, #00800h            ; 3291 0 208 180 600008
idle_pid_x1_select:     L       A, X1                  ; 3294 1 208 180 40
                SJ      idle_pid_output_store             ; 3295 1 208 180 CB0C
idle_pid_gate4:     JBS     off(00210h).3, idle_pid_zero_flag ; 3297 0 208 180 EB1008
idle_pid_gate5:     SC                             ; 329A 0 208 180 85
                LB      A, #008h               ; 329B 0 208 180 7708
idle_pid_result_store:     MB      off(0022bh).2, C       ; 329D 0 208 180 C42B3A
                STB     A, off(00299h)         ; 32A0 0 208 180 D499
idle_pid_zero_flag:     CLR     A                      ; 32A2 1 208 180 F9
idle_pid_output_store:     ST      A, off(0027ch)         ; 32A3 1 208 180 D47C
                MOV     X1, #tbl_idle_pid_out2          ; 32A5 1 208 180 601D6B
                LB      A, off(00238h)         ; 32A8 0 208 180 F438
                VCAL    0                      ; 32AA 0 208 180 10
                MOV     DP, A                  ; 32AB 0 208 180 52
                MOV     X1, #ModePageTable_SetA          ; 32AC 0 208 180 60116B
                JBS     off(00216h).3, idle_pid_output_store_goto_7946 ; 32AF 0 208 180 EB1603
                MOV     X1, #ModePageTable_SetB          ; 32B2 0 208 180 60176B
idle_pid_output_store_goto_7946:     J       idle_pid_output_store_load_ram0d5             ; 32B5 0 208 180 034679
idle_sub_result_store_load_ram2c3:     LB      A, off(002c3h)         ; 32B8 0 208 180 F4C3
                MOV     A, off(0026ch)         ; 32BA 1 208 180 B46C99
                JNE     idle_sub_gate2             ; 32BD 1 208 180 CE2A
                MOVB    off(002c3h), #003h     ; 32BF 1 208 180 C4C39803
                JBR     off(0021ah).2, idle_sub_common ; 32C3 1 208 180 DA1A22
                JBS     off(0021bh).1, idle_sub_diff_calc ; 32C6 1 208 180 E91B05
                ADD     A, er3                 ; 32C9 1 208 180 0B
                JLT     idle_sub_alt_path             ; 32CA 1 208 180 CA3C
                SJ      idle_sub_range_check1             ; 32CC 1 208 180 CB03
idle_sub_diff_calc:     SUB     A, er3                 ; 32CE 1 208 180 2B
                JLT     idle_sub_common             ; 32CF 1 208 180 CA17
idle_sub_range_check1:     MOV     X2, #00600h            ; 32D1 1 208 180 610006
                CMP     A, #02000h             ; 32D4 1 208 180 C60020
                JGE     idle_sub_range_result             ; 32D7 1 208 180 CD0B
                MOV     X2, #00300h            ; 32D9 1 208 180 610003
                CMP     A, #01000h             ; 32DC 1 208 180 C60010
                JGE     idle_sub_range_result             ; 32DF 1 208 180 CD03
                MOV     X2, #00200h            ; 32E1 1 208 180 610002
idle_sub_range_result:     SUB     A, X2                  ; 32E4 1 208 180 91A2
                JGE     idle_sub_gate2             ; 32E6 1 208 180 CD01
idle_sub_common:     CLR     A                      ; 32E8 1 208 180 F9
idle_sub_gate2:     JBS     off(00216h).3, idle_sub_clamp ; 32E9 1 208 180 EB1618
                JBR     off(0021ah).2, idle_sub_clamp ; 32EC 1 208 180 DA1A15
                JBR     off(00218h).2, idle_sub_clamp ; 32EF 1 208 180 DA1812
                MOV     X2, A                  ; 32F2 1 208 180 51
                MOV     X1, #tbl_idle_sub_gate1          ; 32F3 1 208 180 602C6B
                JBR     off(00211h).2, idle_sub_table_lookup ; 32F6 1 208 180 DA1103
                MOV     X1, #tbl_idle_sub_gate2          ; 32F9 1 208 180 603B6B
idle_sub_table_lookup:     LB      A, off(00238h)         ; 32FC 0 208 180 F438
                VCAL    0                      ; 32FE 0 208 180 10
                L       A, X2                  ; 32FF 1 208 180 41
                CMP     A, er3                 ; 3300 1 208 180 4B
                JGE     idle_sub_clamp             ; 3301 1 208 180 CD01
                L       A, er3                 ; 3303 1 208 180 37
idle_sub_clamp:     CMP     A, DP                  ; 3304 1 208 180 92C2
                JLT     idle_sub_final_store             ; 3306 1 208 180 CA01
idle_sub_alt_path:     L       A, DP                  ; 3308 1 208 180 42
idle_sub_final_store:     ST      A, off(0026ch)         ; 3309 1 208 180 D46C
                MB      C, off(0022bh).6       ; 330B 1 208 180 C42B2E
                MB      off(0022bh).7, C       ; 330E 1 208 180 C42B3F
                MOV     DP, #0037bh            ; 3311 1 208 180 627B03
                LB      A, [DP]                ; 3314 0 208 180 F2
                MOV     X2, #tbl_idle_sub1          ; 3315 0 208 180 61FE69
                JBR     off(0021bh).0, idle_gate6 ; 3318 0 208 180 D81B09
                MOV     X2, #tbl_idle_sub2          ; 331B 0 208 180 610C6A
                CMPB    A, #053h               ; 331E 0 208 180 C653
                JGE     idle_gate6             ; 3320 0 208 180 CD02
                LB      A, #053h               ; 3322 0 208 180 7753
idle_gate6:     CMPB    A, off(00238h)         ; 3324 0 208 180 C738
                MB      off(0022bh).6, C       ; 3326 0 208 180 C42B3E
                JBR     off(0021ah).0, idle_gate6_result ; 3329 0 208 180 D81A13
                JLT     idle_gate6_result             ; 332C 0 208 180 CA11
                JBR     off(0022bh).7, idle_gate7 ; 332E 0 208 180 DF2B14
                JBS     off(0021bh).7, idle_gate6_result ; 3331 0 208 180 EF1B0B
                MOV     X1, #tbl_idle_gate6          ; 3334 0 208 180 60DB69
                LB      A, 0d9h                ; 3337 0 208 180 F5D9
                VCAL    0                      ; 3339 0 208 180 10
                ; warning: had to flip DD
                CMP     A, 0c8h                ; 333A 1 208 180 B5C8C2
                JLT     idle_table_lookup2             ; 333D 1 208 180 CA0F
idle_gate6_result:     MOVB    off(002c2h), off(00298h) ; 333F 1 208 180 C4987CC2
                SJ      idle_flag_zero             ; 3343 1 208 180 CB2B
idle_gate7:     L       A, off(0026eh)         ; 3345 1 208 180 E46E
                SUB     A, #00060h             ; 3347 1 208 180 A66000
                JLT     idle_flag_zero             ; 334A 1 208 180 CA24
                SJ      idle_flag_check3             ; 334C 1 208 180 CB1C
idle_table_lookup2:     MOV     X1, X2                 ; 334E 1 208 180 9178
                LB      A, 0d9h                ; 3350 0 208 180 F5D9
                CAL     table_interp_lookup             ; 3352 0 208 180 323958
                STB     A, r0                  ; 3355 0 208 180 88
                CLRB    r1                     ; 3356 0 208 180 2115
                L       A, 0c8h                ; 3358 1 208 180 E5C8
                MUL                            ; 335A 1 208 180 9035
                MOV     er0, #02000h           ; 335C 1 208 180 44980020
                CMP     er1, #00000h           ; 3360 1 208 180 45C00000
                JNE     idle_clamp_min             ; 3364 1 208 180 CE03
                CMP     A, er0                 ; 3366 1 208 180 48
                JLT     idle_flag_check3             ; 3367 1 208 180 CA01
idle_clamp_min:     L       A, er0                 ; 3369 1 208 180 34
idle_flag_check3:     CMPB    off(002c2h), #000h     ; 336A 1 208 180 C4C2C000
                JNE     idle_flag_store             ; 336E 1 208 180 CE01
idle_flag_zero:     CLR     A                      ; 3370 1 208 180 F9
idle_flag_store:     ST      A, off(0026eh)         ; 3371 1 208 180 D46E
                JBR     off(00219h).7, idle_mode_dispatch ; 3373 1 208 180 DF1925
                MOV     DP, #003abh            ; 3376 1 208 180 62AB03
                MOVB    r0, [DP]               ; 3379 1 208 180 C248
                L       A, #01a00h             ; 337B 1 208 180 67001A
                CMPB    r0, #033h              ; 337E 1 208 180 20C033
                JEQ     idle_gear_select_done             ; 3381 1 208 180 C913
                L       A, #02600h             ; 3383 1 208 180 670026
                CMPB    r0, #034h              ; 3386 1 208 180 20C034
                JEQ     idle_gear_select_done             ; 3389 1 208 180 C90B
                L       A, #03000h             ; 338B 1 208 180 670030
                CMPB    r0, #035h              ; 338E 1 208 180 20C035
                JEQ     idle_gear_select_done             ; 3391 1 208 180 C903
                L       A, #03fffh             ; 3393 1 208 180 67FF3F
idle_gear_select_done:     L       A, ACC                 ; 3396 1 208 180 E506
                J       idle_gear_target_check             ; 3398 1 208 180 034F37
idle_mode_dispatch:     JBR     off(00217h).5, idle_mode_dispatch2 ; 339B 1 208 180 DD1713
                SB      off(00228h).4          ; 339E 1 208 180 C4281C
                MOV     X1, #ZoneIndexTable3_SetA          ; 33A1 1 208 180 607A68
                JBS     off(00216h).3, to_idle_vcal5_call ; 33A4 1 208 180 EB1603
                MOV     X1, #idle_mode_dispatch_tbl          ; 33A7 1 208 180 605F68
to_idle_vcal5_call:     LB      A, 0d9h                ; 33AA 0 208 180 F5D9
                VCAL    0                      ; 33AC 0 208 180 10
                STB     A, off(00270h)         ; 33AD 0 208 180 D470
                SJ      to_idle_vcal5_call_load_dp             ; 33AF 0 208 180 CB59
idle_mode_dispatch2:     JBR     off(00218h).2, idle_mode_dispatch3 ; 33B1 1 208 180 DA1809
                JBR     off(0022ah).3, idle_gear_calc_start ; 33B4 1 208 180 DB2A69
                L       A, #011ebh             ; 33B7 1 208 180 67EB11
                J       idle_gear_target_final             ; 33BA 1 208 180 037837
idle_mode_dispatch3:     JBR     off(0021ah).1, idle_mode_reset ; 33BD 1 208 180 D91A35
                L       A, off(0026eh)         ; 33C0 1 208 180 E46E
                JNE     idle_mode_reset             ; 33C2 1 208 180 CE31
                JBR     off(0021ch).4, idle_gear_calc_start ; 33C4 1 208 180 DC1C59
                CMPB    0d9h, #02eh            ; 33C7 1 208 180 C5D9C02E
                JGE     idle_gear_calc_start             ; 33CB 1 208 180 CD53
                CMPB    0cch, #005h            ; 33CD 1 208 180 C5CCC005
                JLT     idle_gear_calc_start             ; 33D1 1 208 180 CA4D
                JBR     off(0022ah).2, idle_gear_calc_start ; 33D3 1 208 180 DA2A4A
                MOV     X1, #tbl_ve_map_scalar_alt          ; 33D6 1 208 180 604A6B
                LB      A, 0c2h                ; 33D9 0 208 180 F5C2
                JBS     off(0021fh).1, idle_mode_dispatch3_vcal_0 ; 33DB 0 208 180 E91F05
                MOV     X1, #tbl_ve_map_scalar          ; 33DE 0 208 180 60626B
                LB      A, off(00238h)         ; 33E1 0 208 180 F438
idle_mode_dispatch3_vcal_0:     VCAL    0                      ; 33E3 0 208 180 10
                STB     A, off(00272h)         ; 33E4 0 208 180 D472
                JEQ     idle_gear_calc_start             ; 33E6 0 208 180 C938
                SB      off(00228h).6          ; 33E8 0 208 180 C4281E
                MOV     DP, #0030ch            ; 33EB 0 208 180 620C03
                L       A, [DP]                ; 33EE 1 208 180 E2
vcal5_call:     VCAL    5                      ; 33EF 1 208 180 15
                ST      A, off(00262h)         ; 33F0 1 208 180 D462
                J       idle_stall_trigger_if_ram217_bit5_clr             ; 33F2 1 208 180 037736
idle_mode_reset:     CLR     off(0026ch)            ; 33F5 1 208 180 B46C15
                JBR     off(00216h).3, carry_set_flag_gate_0b0 ; 33F8 1 208 180 DB1615
                JBS     off(00211h).5, carry_set_flag_gate_0b0 ; 33FB 1 208 180 ED1112
                JBR     off(00225h).3, carry_set_flag_gate_0b0 ; 33FE 1 208 180 DB250F
                SB      off(00228h).7          ; 3401 1 208 180 C4281F
                MOV     er3, off(0026eh)       ; 3404 1 208 180 B46E4B
                L       A, off(00264h)         ; 3407 1 208 180 E464
                VCAL    5                      ; 3409 1 208 180 15
to_idle_vcal5_call_load_dp:     MOV     DP, #00382h            ; 340A 0 208 180 628203
                L       A, [DP]                ; 340D 1 208 180 E2
                SJ      vcal5_call             ; 340E 1 208 180 CBDF
carry_set_flag_gate_0b0:     SC                             ; 3410 1 208 180 85
                JBS     off(0022bh).4, idle_direction_toggle ; 3411 1 208 180 EC2B06
                JBS     off(00212h).5, idle_direction_toggle ; 3414 1 208 180 ED1203
                MB      C, 0b0h.1              ; 3417 1 208 180 C5B029
idle_direction_toggle:     XORB    PSWH, #080h            ; 341A 1 208 180 A2F080
                MB      off(00228h).5, C       ; 341D 1 208 180 C4283D
idle_gear_calc_start:     CLR     A                      ; 3420 1 208 180 F9
                ST      A, er2                 ; 3421 1 208 180 8A
                MOV     DP, #0030ch            ; 3422 1 208 180 620C03
                MOV     er0, off(00266h)       ; 3425 1 208 180 B46648
                MOVB    ACCH, #025h            ; 3428 1 208 180 C5079825
                MOVB    r5, #099h              ; 342C 1 208 180 9D99
                JBR     off(0021ah).0, idle_gear_mul_apply ; 342E 1 208 180 D81A1F
                MOV     er0, off(00264h)       ; 3431 1 208 180 B46448
                MOVB    ACCH, #052h            ; 3434 1 208 180 C5079852
                MOVB    r5, #090h              ; 3438 1 208 180 9D90
                JBR     off(00228h).5, idle_gear_mul_apply ; 343A 1 208 180 DD2813
                JBR     off(0021ah).2, idle_gear_mul_apply ; 343D 1 208 180 DA1A10
                CMPB    0d9h, #034h            ; 3440 1 208 180 C5D9C034
                JGE     idle_gear_mul_apply             ; 3444 1 208 180 CD0A
                L       A, [DP]                ; 3446 1 208 180 E2
                ADD     A, off(00268h)         ; 3447 1 208 180 8768
                JGE     idle_gear_result_store             ; 3449 1 208 180 CD1D
                L       A, #0ffffh             ; 344B 1 208 180 67FFFF
                SJ      idle_gear_result_store             ; 344E 1 208 180 CB18
idle_gear_mul_apply:     MUL                            ; 3450 1 208 180 9035
                SLL     A                      ; 3452 1 208 180 53
                L       A, er1                 ; 3453 1 208 180 35
                ROL     A                      ; 3454 1 208 180 33
                JLT     idle_gear_clamp             ; 3455 1 208 180 CA08
                ADD     A, off(00268h)         ; 3457 1 208 180 8768
                JLT     idle_gear_clamp             ; 3459 1 208 180 CA04
                ADD     A, [DP]                ; 345B 1 208 180 B282
                JGE     idle_gear_clamp_max             ; 345D 1 208 180 CD03
idle_gear_clamp:     L       A, #0ffffh             ; 345F 1 208 180 67FFFF
idle_gear_clamp_max:     SUB     A, #00800h             ; 3462 1 208 180 A60008
                JGE     idle_gear_result_store             ; 3465 1 208 180 CD01
                CLR     A                      ; 3467 1 208 180 F9
idle_gear_result_store:     ST      A, off(00290h)         ; 3468 1 208 180 D490
                L       A, er2                 ; 346A 1 208 180 36
                MUL                            ; 346B 1 208 180 9035
                SLL     A                      ; 346D 1 208 180 53
                L       A, er1                 ; 346E 1 208 180 35
                ROL     A                      ; 346F 1 208 180 33
                JLT     idle_gear2_clamp             ; 3470 1 208 180 CA09
                ADD     A, off(00268h)         ; 3472 1 208 180 8768
                JLT     idle_gear2_clamp             ; 3474 1 208 180 CA05
                ADD     A, #01000h             ; 3476 1 208 180 860010
                JGE     idle_gear2_store             ; 3479 1 208 180 CD03
idle_gear2_clamp:     L       A, #0ffffh             ; 347B 1 208 180 67FFFF
idle_gear2_store:     ST      A, off(0028eh)         ; 347E 1 208 180 D48E
                MOVB    r0, #010h              ; 3480 1 208 180 9810
                MOV     DP, #tbl_idle_gear2          ; 3482 1 208 180 629969
                JBR     off(00228h).5, idle_timer_gate1 ; 3485 1 208 180 DD2809
                JBS     off(0021ah).3, idle_timer_gate_common ; 3488 1 208 180 EB1A13
                MOVB    off(0029ah), #030h     ; 348B 1 208 180 C49A9830
                SJ      idle_timer_gate_common             ; 348F 1 208 180 CB0D
idle_timer_gate1:     JBR     off(00218h).2, idle_timer_gate_common ; 3491 1 208 180 DA180A
                CLRB    off(002e6h)            ; 3494 1 208 180 C4E615
                MOVB    r0, #030h              ; 3497 1 208 180 9830
                JBS     off(0021ah).4, idle_table_select2 ; 3499 1 208 180 EC1A4F
                SJ      idle_timer_store             ; 349C 1 208 180 CB50
idle_timer_gate_common:     JBS     off(0021ah).2, idle_table_select2 ; 349E 1 208 180 EA1A4A
                JBS     off(0021ah).0, idle_table_select1 ; 34A1 1 208 180 E81A0E
                CMPB    0f3h, #032h            ; 34A4 1 208 180 C5F3C032
                JGE     idle_table_select1             ; 34A8 1 208 180 CD08
                JBR     off(0021ah).4, idle_timer_store ; 34AA 1 208 180 DC1A41
                MOV     DP, #tbl_idle_timer          ; 34AD 1 208 180 628D69
                SJ      idle_timer_store             ; 34B0 1 208 180 CB3C
idle_table_select1:     LB      A, off(002e6h)         ; 34B2 0 208 180 F4E6
                JEQ     idle_table_select_default             ; 34B4 0 208 180 C905
                MOV     DP, #tbl_idle_select1          ; 34B6 0 208 180 629F69
                SJ      idle_flag_gate             ; 34B9 0 208 180 CB36
idle_table_select_default:     MOV     DP, #tbl_idle_select_default          ; 34BB 0 208 180 628769
                MOV     X1, #tbl_idle_default1          ; 34BE 0 208 180 602D69
                JBR     off(0021ah).4, idle_table_lookup3 ; 34C1 0 208 180 DC1A03
                MOV     X1, #tbl_idle_default2          ; 34C4 0 208 180 604969
idle_table_lookup3:     L       A, off(0025ch)         ; 34C7 1 208 180 E45C
                CAL     table_interp_lookup_4byte             ; 34C9 1 208 180 32D358
                CMP     A, 0cah                ; 34CC 1 208 180 B5CAC2
                JLT     idle_table_lookup4             ; 34CF 1 208 180 CA03
                MOV     DP, #tbl_idle_lookup3          ; 34D1 1 208 180 628169
idle_table_lookup4:     MOV     X1, #tbl_idle_lookup4          ; 34D4 1 208 180 606569
                L       A, off(0025ch)         ; 34D7 1 208 180 E45C
                CAL     table_interp_lookup_4byte             ; 34D9 1 208 180 32D358
                JBR     off(0021ah).4, idle_flag_gate ; 34DC 1 208 180 DC1A12
                CMP     A, 0cah                ; 34DF 1 208 180 B5CAC2
                JGE     idle_flag_gate             ; 34E2 1 208 180 CD0D
                LB      A, off(0029ah)         ; 34E4 0 208 180 F49A
                JEQ     idle_flag_gate             ; 34E6 0 208 180 C909
                SUBB    A, #001h               ; 34E8 0 208 180 A601
                STB     A, r0                  ; 34EA 0 208 180 88
idle_table_select2:     MOV     DP, #idle_table_select2_tbl          ; 34EB 1 208 180 629369
idle_timer_store:     MOVB    off(0029ah), r0        ; 34EE 1 208 180 207C9A
idle_flag_gate:     LB      A, off(002e7h)         ; 34F1 0 208 180 F4E7
                JNE     idle_copy_prev             ; 34F3 0 208 180 CE03
                RB      off(00225h).5          ; 34F5 0 208 180 C4250D
idle_copy_prev:     MOV     off(0028ah), off(00288h) ; 34F8 0 208 180 B4887C8A
                MOVB    off(0028dh), off(0028ch) ; 34FC 0 208 180 C48C7C8D
                SB      off(0022bh).1          ; 3500 0 208 180 C42B19
                RB      PSWL.4                 ; 3503 0 208 180 A30C
                JBS     off(00228h).5, idle_copy_prev_if_ram21a_bit3_set ; 3505 0 208 180 ED280E
                JBS     off(0021ah).3, idle_mode_gate5 ; 3508 0 208 180 EB1A32
                L       A, off(00264h)         ; 350B 1 208 180 E464
                JBS     off(00225h).4, idle_copy_prev_goto_idle_pi_mul1 ; 350D 1 208 180 EC2503
                JBS     off(0021ah).0, idle_target_store3 ; 3510 1 208 180 E81A65
idle_copy_prev_goto_idle_pi_mul1:     J       idle_pi_mul1             ; 3513 1 208 180 039235
idle_copy_prev_if_ram21a_bit3_set:     JBS     off(0021ah).3, idle_copy_prev_if_ram216_bit3_clr ; 3516 0 208 180 EB1A09
                SB      PSWL.4                 ; 3519 0 208 180 A31C
                JBR     off(00228h).0, idle_mode_gate5 ; 351B 0 208 180 D8281F
                L       A, off(00270h)         ; 351E 1 208 180 E470
                SJ      idle_target_store3             ; 3520 1 208 180 CB56
idle_copy_prev_if_ram216_bit3_clr:     JBR     off(00216h).3, multi_cond_dispatch_0d9_0f3 ; 3522 0 208 180 DB1603
                JBS     off(00229h).4, idle_mode_gate5 ; 3525 0 208 180 EC2915
multi_cond_dispatch_0d9_0f3:     JBS     off(00229h).5, idle_mode_gate5 ; 3528 0 208 180 ED2912
                JBR     off(0022bh).3, idle_pi_mul1 ; 352B 0 208 180 DB2B64
                CMPB    0d9h, #0d0h            ; 352E 0 208 180 C5D9C0D0
                JLT     idle_mode_gate4             ; 3532 0 208 180 CA06
                CMPB    0f3h, #0fah            ; 3534 0 208 180 C5F3C0FA
                JLT     idle_pi_mul1             ; 3538 0 208 180 CA58
idle_mode_gate4:     JBR     off(00229h).6, idle_pi_mul1 ; 353A 0 208 180 DE2955
idle_mode_gate5:     L       A, off(00266h)         ; 353D 1 208 180 E466
                JBR     off(0021ah).0, idle_target_store3 ; 353F 1 208 180 D81A36
                L       A, off(00264h)         ; 3542 1 208 180 E464
                JBR     off(00216h).3, idle_mode_gate5_load_carry_pswl_bit4 ; 3544 1 208 180 DB160D
                JBS     off(00211h).5, idle_mode_gate5_load_carry_pswl_bit4 ; 3547 1 208 180 ED110A
                JBR     off(00228h).3, idle_mode_gate5_load_carry_pswl_bit4 ; 354A 1 208 180 DB2807
                ST      A, er3                 ; 354D 1 208 180 8B
                MOV     DP, #00382h            ; 354E 1 208 180 628203
                L       A, [DP]                ; 3551 1 208 180 E2
                SJ      idle_vcal5_call2             ; 3552 1 208 180 CB29
idle_mode_gate5_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 3554 1 208 180 A32C
                JGE     idle_target_store3             ; 3556 1 208 180 CD20
                CMPB    off(002e7h), #000h     ; 3558 1 208 180 C4E7C000
                JEQ     idle_table_select3             ; 355C 1 208 180 C905
                SB      off(00225h).5          ; 355E 1 208 180 C4251D
                JNE     idle_target_store3             ; 3561 1 208 180 CE15
idle_table_select3:     MOV     X2, A                  ; 3563 1 208 180 51
                LB      A, #014h               ; 3564 0 208 180 7714
                MOV     X1, #tbl_idle_select3a          ; 3566 0 208 180 60A569
                JBR     off(0021bh).0, idle_table_apply3 ; 3569 0 208 180 D81B05
                LB      A, #032h               ; 356C 0 208 180 7732
                MOV     X1, #idle_table_select3_tbl          ; 356E 0 208 180 60B769
idle_table_apply3:     STB     A, off(002e7h)         ; 3571 0 208 180 D4E7
                LB      A, 0d8h                ; 3573 0 208 180 F5D8
                VCAL    0                      ; 3575 0 208 180 10
                L       A, X2                  ; 3576 1 208 180 41
                VCAL    5                      ; 3577 1 208 180 15
idle_target_store3:     ST      A, er3                 ; 3578 1 208 180 8B
                MOV     DP, #0030ch            ; 3579 1 208 180 620C03
                L       A, [DP]                ; 357C 1 208 180 E2
idle_vcal5_call2:     VCAL    5                      ; 357D 1 208 180 15
                MOV     er3, off(00268h)       ; 357E 1 208 180 B4684B
                VCAL    5                      ; 3581 1 208 180 15
                ST      A, off(00288h)         ; 3582 1 208 180 D488
                ST      A, off(0028ah)         ; 3584 1 208 180 D48A
                CLRB    A                      ; 3586 0 208 180 FA
                STB     A, off(0028ch)         ; 3587 0 208 180 D48C
                STB     A, off(0028dh)         ; 3589 0 208 180 D48D
                CLR     A                      ; 358B 1 208 180 F9
                ST      A, er1                 ; 358C 1 208 180 89
                ST      A, er2                 ; 358D 1 208 180 8A
                MOV     X1, A                  ; 358E 1 208 180 50
                MOV     X2, A                  ; 358F 1 208 180 51
                SJ      idle_vcal4_call             ; 3590 1 208 180 CB25
idle_pi_mul1:     MOV     er0, 0c8h              ; 3592 1 208 180 B5C848
                LC      A, [DP]                ; 3595 1 208 180 92A8
                MUL                            ; 3597 1 208 180 9035
                L       A, er1                 ; 3599 1 208 180 35
                JBR     off(0021bh).7, idle_pi_mul2 ; 359A 1 208 180 DF1B01
                VCAL    7                      ; 359D 1 208 180 17
idle_pi_mul2:     MOV     X1, A                  ; 359E 1 208 180 50
                MOV     er0, 0cah              ; 359F 1 208 180 B5CA48
                INC     DP                     ; 35A2 1 208 180 72
                INC     DP                     ; 35A3 1 208 180 72
                LC      A, [DP]                ; 35A4 1 208 180 92A8
                MUL                            ; 35A6 1 208 180 9035
                L       A, er1                 ; 35A8 1 208 180 35
                JBR     off(0021ah).4, idle_pi_mul3 ; 35A9 1 208 180 DC1A01
                VCAL    7                      ; 35AC 1 208 180 17
idle_pi_mul3:     MOV     X2, A                  ; 35AD 1 208 180 51
                INC     DP                     ; 35AE 1 208 180 72
                INC     DP                     ; 35AF 1 208 180 72
                LC      A, [DP]                ; 35B0 1 208 180 92A8
                MUL                            ; 35B2 1 208 180 9035
                ST      A, er2                 ; 35B4 1 208 180 8A
                L       A, off(0026ah)         ; 35B5 1 208 180 E46A
idle_vcal4_call:     MOV     er3, off(00288h)       ; 35B7 1 208 180 B4884B
                VCAL    4                      ; 35BA 1 208 180 14
                LB      A, off(0028ch)         ; 35BB 0 208 180 F48C
                JBS     off(0021ah).4, idle_integrator_sub ; 35BD 0 208 180 EC1A0B
                ADDB    A, r5                  ; 35C0 0 208 180 0D
                STB     A, r5                  ; 35C1 0 208 180 8D
                L       A, er3                 ; 35C2 1 208 180 37
                ADC     A, er1                 ; 35C3 1 208 180 19
                JGE     idle_integrator_result             ; 35C4 1 208 180 CD0C
                L       A, #0ffffh             ; 35C6 1 208 180 67FFFF
                SJ      idle_integrator_result             ; 35C9 1 208 180 CB07
idle_integrator_sub:     SUBB    A, r5                  ; 35CB 0 208 180 2D
                STB     A, r5                  ; 35CC 0 208 180 8D
                L       A, er3                 ; 35CD 1 208 180 37
                SBC     A, er1                 ; 35CE 1 208 180 39
                JGE     idle_integrator_result             ; 35CF 1 208 180 CD01
                CLR     A                      ; 35D1 1 208 180 F9
idle_integrator_result:     CAL     idle_pi_clamp_helper             ; 35D2 1 208 180 321A5B
                ST      A, er1                 ; 35D5 1 208 180 89
                ST      A, er3                 ; 35D6 1 208 180 8B
                JLT     idle_pi_store_p             ; 35D7 1 208 180 CA0C
                L       A, X1                  ; 35D9 1 208 180 40
                VCAL    4                      ; 35DA 1 208 180 14
                L       A, X2                  ; 35DB 1 208 180 41
                VCAL    4                      ; 35DC 1 208 180 14
                CAL     idle_pi_clamp_helper             ; 35DD 1 208 180 321A5B
                JLT     idle_pi_result_common             ; 35E0 1 208 180 CA06
                MOVB    off(0028ch), r5        ; 35E2 1 208 180 257C8C
idle_pi_store_p:     MOV     off(00288h), er1       ; 35E5 1 208 180 457C88
idle_pi_result_common:     ST      A, er3                 ; 35E8 1 208 180 8B
                L       A, off(0026eh)         ; 35E9 1 208 180 E46E
                JBS     off(00228h).5, idle_vcal5_call3 ; 35EB 1 208 180 ED2802
                L       A, off(0026ch)         ; 35EE 1 208 180 E46C
idle_vcal5_call3:     VCAL    5                      ; 35F0 1 208 180 15
                ST      A, off(00262h)         ; 35F1 1 208 180 D462
                MB      C, off(0022ah).1       ; 35F3 1 208 180 C42A29
                JBR     off(00217h).6, idle_vcal5_call3_if_lt_goto_3677 ; 35F6 1 208 180 DE1703
                MB      C, off(0022ah).6       ; 35F9 1 208 180 C42A2E
idle_vcal5_call3_if_lt_goto_3677:     JLT     idle_stall_trigger_if_ram217_bit5_clr             ; 35FC 1 208 180 CA79
                JBS     off(00225h).7, idle_stall_trigger_if_ram217_bit5_clr ; 35FE 1 208 180 EF2576
                JBR     off(00228h).5, idle_stall_trigger_if_ram217_bit5_clr ; 3601 1 208 180 DD2873
                JBS     off(0021ah).2, idle_stall_trigger_if_ram217_bit5_clr ; 3604 1 208 180 EA1A70
                JBR     off(0021ah).0, idle_stall_trigger_if_ram217_bit5_clr ; 3607 1 208 180 D81A6D
                L       A, off(00280h)         ; 360A 1 208 180 E480
                JNE     idle_stall_trigger_if_ram217_bit5_clr             ; 360C 1 208 180 CE69
                L       A, off(0027ch)         ; 360E 1 208 180 E47C
                JNE     idle_stall_trigger_if_ram217_bit5_clr             ; 3610 1 208 180 CE65
                L       A, off(00282h)         ; 3612 1 208 180 E482
                JNE     idle_stall_trigger_if_ram217_bit5_clr             ; 3614 1 208 180 CE61
                CMPB    0beh, #070h            ; 3616 1 208 180 C5BEC070
                JLT     idle_stall_trigger_if_ram217_bit5_clr             ; 361A 1 208 180 CA5B
                CMP     0c8h, #00018h          ; 361C 1 208 180 B5C8C01800
                JGE     idle_stall_trigger_if_ram217_bit5_clr             ; 3621 1 208 180 CD54
                L       A, #00040h             ; 3623 1 208 180 674000
                JBR     off(0021ah).4, idle_stall_check2 ; 3626 1 208 180 DC1A03
                L       A, #00040h             ; 3629 1 208 180 674000
idle_stall_check2:     CMP     A, 0cah                ; 362C 1 208 180 B5CAC2
                JLT     idle_stall_trigger_if_ram217_bit5_clr             ; 362F 1 208 180 CA46
                CMPB    0d9h, #067h            ; 3631 1 208 180 C5D9C067
                JGE     idle_stall_trigger_if_ram217_bit5_clr             ; 3635 1 208 180 CD40
                LB      A, off(002e7h)         ; 3637 0 208 180 F4E7
                JNE     idle_stall_trigger_if_ram217_bit5_clr             ; 3639 0 208 180 CE3C
                LB      A, 0bch                ; 363B 0 208 180 F5BC
                MOV     X1, #tbl_idle_stall          ; 363D 0 208 180 60C969
                VCAL    1                      ; 3640 0 208 180 11
                LB      A, #0a8h               ; 3641 0 208 180 77A8
                JBS     off(00216h).3, sub_r6_clamp_zero ; 3643 0 208 180 EB1602
                LB      A, #0b8h               ; 3646 0 208 180 77B8
sub_r6_clamp_zero:     SUBB    A, r6                  ; 3648 0 208 180 2E
                JGE     idle_stall_er0_select1             ; 3649 0 208 180 CD01
                CLRB    A                      ; 364B 0 208 180 FA
idle_stall_er0_select1:     MOV     er0, #00040h           ; 364C 0 208 180 44984000
                CMPB    A, 0beh                ; 3650 0 208 180 C5BEC2
                JLT     idle_stall_er0_select2             ; 3653 0 208 180 CA04
                MOV     er0, #00010h           ; 3655 0 208 180 44981000
idle_stall_er0_select2:     CMPB    0d9h, #028h            ; 3659 0 208 180 C5D9C028
                JLT     idle_stall_diff_calc             ; 365D 0 208 180 CA04
                MOV     er0, #00001h           ; 365F 0 208 180 44980100
idle_stall_diff_calc:     MOV     X1, #0030ch            ; 3663 0 208 180 600C03
                L       A, off(00288h)         ; 3666 1 208 180 E488
                SUB     A, off(00264h)         ; 3668 1 208 180 A764
                JLT     idle_stall_diff_check             ; 366A 1 208 180 CA04
                SUB     A, off(00268h)         ; 366C 1 208 180 A768
                JGE     idle_stall_trigger             ; 366E 1 208 180 CD01
idle_stall_diff_check:     CLR     A                      ; 3670 1 208 180 F9
idle_stall_trigger:     CAL     injtimer_bank_calc1             ; 3671 1 208 180 322859
                CAL     idle_stall_helper             ; 3674 1 208 180 32725A
idle_stall_trigger_if_ram217_bit5_clr:     JBR     off(00217h).5, idle_stall_trigger_cmp_ram0f2 ; 3677 1 208 180 DD1708
                LB      A, 0d9h                ; 367A 0 208 180 F5D9
                MOV     X1, #idle_stall_trigger_tbl          ; 367C 0 208 180 607A6B
                VCAL    0                      ; 367F 0 208 180 10
                SJ      idle_stall_trigger_store_ram280             ; 3680 0 208 180 CB1E
idle_stall_trigger_cmp_ram0f2:     CMPB    0f2h, #00ch            ; 3682 1 208 180 C5F2C00C
                JGE     idle_stall_trigger_clear_acc             ; 3686 1 208 180 CD17
                MOV     X1, #idle_stall_trigger_tbl_2          ; 3688 1 208 180 608C6B
                JBR     off(00228h).5, idle_stall_trigger_load_x1 ; 368B 1 208 180 DD2806
                LB      A, off(00238h)         ; 368E 0 208 180 F438
                CMPB    A, off(00296h)         ; 3690 0 208 180 C796
                JGE     idle_stall_trigger_load_ram0d9             ; 3692 0 208 180 CD03
idle_stall_trigger_load_x1:     MOV     X1, #idle_stall_trigger_tbl_3          ; 3694 0 208 180 609E6B
idle_stall_trigger_load_ram0d9:     LB      A, 0d9h                ; 3697 0 208 180 F5D9
                VCAL    0                      ; 3699 0 208 180 10
                L       A, off(00280h)         ; 369A 1 208 180 E480
                SUB     A, er3                 ; 369C 1 208 180 2B
                JGE     idle_stall_trigger_store_ram280             ; 369D 1 208 180 CD01
idle_stall_trigger_clear_acc:     CLR     A                      ; 369F 1 208 180 F9
idle_stall_trigger_store_ram280:     ST      A, off(00280h)         ; 36A0 1 208 180 D480
                L       A, off(00276h)         ; 36A2 1 208 180 E476
                MOV     er3, off(00278h)       ; 36A4 1 208 180 B4784B
                VCAL    5                      ; 36A7 1 208 180 15
                L       A, off(0027ah)         ; 36A8 1 208 180 E47A
                VCAL    5                      ; 36AA 1 208 180 15
                L       A, off(0027ch)         ; 36AB 1 208 180 E47C
                VCAL    5                      ; 36AD 1 208 180 15
                L       A, off(0027eh)         ; 36AE 1 208 180 E47E
                VCAL    5                      ; 36B0 1 208 180 15
                L       A, off(00280h)         ; 36B1 1 208 180 E480
                VCAL    5                      ; 36B3 1 208 180 15
                L       A, off(00282h)         ; 36B4 1 208 180 E482
                CMP     A, #08000h             ; 36B6 1 208 180 C60080
                JGE     idle_target_clamp1             ; 36B9 1 208 180 CD05
                ADD     A, er3                 ; 36BB 1 208 180 0B
                JGE     idle_target_clamp2             ; 36BC 1 208 180 CD05
                SJ      idle_target_clamp_max             ; 36BE 1 208 180 CB08
idle_target_clamp1:     ADD     A, er3                 ; 36C0 1 208 180 0B
                JGE     idle_target_final_store             ; 36C1 1 208 180 CD08
idle_target_clamp2:     CMP     A, #08000h             ; 36C3 1 208 180 C60080
                JLT     idle_target_final_store             ; 36C6 1 208 180 CA03
idle_target_clamp_max:     L       A, #07fffh             ; 36C8 1 208 180 67FF7F
idle_target_final_store:     ST      A, off(00274h)         ; 36CB 1 208 180 D474
                CLR     X1                     ; 36CD 1 208 180 9015
                JBS     off(00217h).5, idle_output_gate2 ; 36CF 1 208 180 ED172F
                JBR     off(00225h).7, idle_output_gate1 ; 36D2 1 208 180 DF2507
                MOV     DP, #0030ch            ; 36D5 1 208 180 620C03
                L       A, 00382h[X1]          ; 36D8 1 208 180 E08203
                ST      A, [DP]                ; 36DB 1 208 180 D2
idle_output_gate1:     MOV     er3, #00600h           ; 36DC 1 208 180 47980006
                L       A, 00382h[X1]          ; 36E0 1 208 180 E08203
                VCAL    5                      ; 36E3 1 208 180 15
                MB      C, 0b0h.1              ; 36E4 1 208 180 C5B029
                JLT     idle_output_common             ; 36E7 1 208 180 CA23
                JBS     off(00212h).5, idle_output_common ; 36E9 1 208 180 ED1220
                MOV     er3, off(00264h)       ; 36EC 1 208 180 B4644B
                L       A, 00382h[X1]          ; 36EF 1 208 180 E08203
                VCAL    5                      ; 36F2 1 208 180 15
                CLR     A                      ; 36F3 1 208 180 F9
                JBS     off(00212h).2, idle_output_alt_value ; 36F4 1 208 180 EA1203
                JBR     off(00212h).4, idle_output_vcal5 ; 36F7 1 208 180 DC1203
idle_output_alt_value:     L       A, #02000h             ; 36FA 1 208 180 670020
idle_output_vcal5:     VCAL    5                      ; 36FD 1 208 180 15
                JBS     off(0022bh).4, idle_output_common ; 36FE 1 208 180 EC2B0B
idle_output_gate2:     L       A, off(00262h)         ; 3701 1 208 180 E462
                JBS     off(00228h).6, idle_pi_final_calc ; 3703 1 208 180 EE2810
                CLR     off(00272h)            ; 3706 1 208 180 B47215
                JBS     off(0022bh).1, idle_output_gate3 ; 3709 1 208 180 E92B04
idle_output_common:     MOV     er3, off(00268h)       ; 370C 1 208 180 B4684B
                VCAL    5                      ; 370F 1 208 180 15
idle_output_gate3:     MOV     er3, off(00274h)       ; 3710 1 208 180 B4744B
                XCHG    A, er3                 ; 3713 1 208 180 4710
                VCAL    4                      ; 3715 1 208 180 14
idle_pi_final_calc:     MOV     X2, A                  ; 3716 1 208 180 51
                CLR     X1                     ; 3717 1 208 180 9015
                L       A, 0037ch[X1]          ; 3719 1 208 180 E07C03
                SUB     A, 0030ch[X1]          ; 371C 1 208 180 B00C03A2
                SLL     A                      ; 3720 1 208 180 53
                ST      A, er0                 ; 3721 1 208 180 88
                CLR     A                      ; 3722 1 208 180 F9
                JLT     idle_pi_scale_store             ; 3723 1 208 180 CA0A
                LB      A, off(00294h)         ; 3725 0 208 180 F494
                ANDB    A, #07fh               ; 3727 0 208 180 D67F
                STB     A, ACCH                ; 3729 0 208 180 D507
                CLRB    A                      ; 372B 0 208 180 FA
                MUL                            ; 372C 0 208 180 9035
                L       A, er1                 ; 372E 1 208 180 35
idle_pi_scale_store:     ST      A, off(00284h)         ; 372F 1 208 180 D484
                L       A, X2                  ; 3731 1 208 180 41
                CLRB    r0                     ; 3732 1 208 180 2015
                MOVB    r1, off(00294h)        ; 3734 1 208 180 C49449
                MUL                            ; 3737 1 208 180 9035
                SLL     A                      ; 3739 1 208 180 53
                L       A, er1                 ; 373A 1 208 180 35
                ROL     A                      ; 373B 1 208 180 33
                JGE     idle_pi_result_clamp             ; 373C 1 208 180 CD03
                L       A, #0ffffh             ; 373E 1 208 180 67FFFF
idle_pi_result_clamp:     ST      A, er3                 ; 3741 1 208 180 8B
                L       A, off(00284h)         ; 3742 1 208 180 E484
                VCAL    5                      ; 3744 1 208 180 15
                LCB     A, fuelmap_base_lookup_tbl            ; 3745 1 208 180 909DE560
                JEQ     idle_pi_final_common             ; 3749 1 208 180 C903
                L       A, off(00286h)         ; 374B 1 208 180 E486
                VCAL    4                      ; 374D 1 208 180 14
idle_pi_final_common:     L       A, er3                 ; 374E 1 208 180 37
idle_gear_target_check:     JNE     idle_gear_target_clamp             ; 374F 1 208 180 CE05
                JBS     off(0021ah).4, idle_gear_target_reset ; 3751 1 208 180 EC1A14
                SJ      idle_gear_target_store             ; 3754 1 208 180 CB1A
idle_gear_target_clamp:     MOV     er3, #03fffh           ; 3756 1 208 180 4798FF3F
                JBS     off(00216h).3, idle_gear_target_clamp_cmp_acc ; 375A 1 208 180 EB1604
                MOV     er3, #03fffh           ; 375D 1 208 180 4798FF3F
idle_gear_target_clamp_cmp_acc:     CMP     A, er3                 ; 3761 1 208 180 4B
                JLT     idle_gear_target_store             ; 3762 1 208 180 CA0C
                L       A, er3                 ; 3764 1 208 180 37
                JBS     off(0021ah).4, idle_gear_target_store ; 3765 1 208 180 EC1A08
idle_gear_target_reset:     MOV     off(00288h), off(0028ah) ; 3768 1 208 180 B48A7C88
                MOVB    off(0028ch), off(0028dh) ; 376C 1 208 180 C48D7C8C
idle_gear_target_store:     ST      A, off(00260h)         ; 3770 1 208 180 D460
                MOV     X1, #tbl_idle_gear_target          ; 3772 1 208 180 60FC6B
                CAL     table_interp_lookup_4byte             ; 3775 1 208 180 32D358
idle_gear_target_final:     ST      A, off(0025eh)         ; 3778 1 208 180 D45E
                RB      off(0022bh).1          ; 377A 1 208 180 C42B09
                MB      C, off(00228h).5       ; 377D 1 208 180 C4282D
                MB      off(0021ah).3, C       ; 3780 1 208 180 C41A3B
                LB      A, off(00228h)         ; 3783 0 208 180 F428
                ANDB    A, #0f0h               ; 3785 0 208 180 D6F0
                SWAPB                          ; 3787 0 208 180 83
                STB     A, off(00228h)         ; 3788 0 208 180 D428
                RB      0b6h.4                 ; 378A 0 208 180 C5B60C
                RT                             ; 378D 0 208 180 01
vcal3_leanprotect_ratelimit_load_r5:     MOVB    r5, 0d1h               ; 378E 1 208 180 C5D14D
                LB      A, 0cch                ; 3791 0 208 180 F5CC
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl          ; 3793 0 208 180 606A65
                CAL     table_interp_lookup             ; 3796 0 208 180 323958
                STB     A, r4                  ; 3799 0 208 180 8C
                LB      A, 0cch                ; 379A 0 208 180 F5CC
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_9          ; 379C 0 208 180 60F465
                CAL     table_interp_lookup             ; 379F 0 208 180 323958
                STB     A, r3                  ; 37A2 0 208 180 8B
                LB      A, 0cch                ; 37A3 0 208 180 F5CC
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_10          ; 37A5 0 208 180 600C66
                CAL     table_interp_lookup             ; 37A8 0 208 180 323958
                STB     A, r2                  ; 37AB 0 208 180 8A
                JBS     off(0022eh).5, vcal3_leanprotect_ratelimit_cmp_acc ; 37AC 0 208 180 ED2E01
                LB      A, r3                  ; 37AF 0 208 180 7B
vcal3_leanprotect_ratelimit_cmp_acc:     CMPB    A, r5                  ; 37B0 0 208 180 4D
                MB      off(0022eh).5, C       ; 37B1 0 208 180 C42E3D
                LB      A, r2                  ; 37B4 0 208 180 7A
                JBS     off(0022eh).4, vcal3_leanprotect_ratelimit_subb_acc ; 37B5 0 208 180 EC2E01
                LB      A, r3                  ; 37B8 0 208 180 7B
vcal3_leanprotect_ratelimit_subb_acc:     SUBB    A, r4                  ; 37B9 0 208 180 2C
                JGE     vcal3_leanprotect_ratelimit_cmp_acc_2             ; 37BA 0 208 180 CD01
                CLRB    A                      ; 37BC 0 208 180 FA
vcal3_leanprotect_ratelimit_cmp_acc_2:     CMPB    A, r5                  ; 37BD 0 208 180 4D
                MB      off(0022eh).4, C       ; 37BE 0 208 180 C42E3C
                LB      A, 0cch                ; 37C1 0 208 180 F5CC
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_11          ; 37C3 0 208 180 602466
                CAL     table_interp_lookup             ; 37C6 0 208 180 323958
                STB     A, r3                  ; 37C9 0 208 180 8B
                LB      A, 0cch                ; 37CA 0 208 180 F5CC
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_12          ; 37CC 0 208 180 603C66
                CAL     table_interp_lookup             ; 37CF 0 208 180 323958
                STB     A, r2                  ; 37D2 0 208 180 8A
                JBS     off(0022eh).7, vcal3_leanprotect_ratelimit_cmp_acc_3 ; 37D3 0 208 180 EF2E01
                LB      A, r3                  ; 37D6 0 208 180 7B
vcal3_leanprotect_ratelimit_cmp_acc_3:     CMPB    A, r5                  ; 37D7 0 208 180 4D
                MB      off(0022eh).7, C       ; 37D8 0 208 180 C42E3F
                LB      A, r2                  ; 37DB 0 208 180 7A
                JBS     off(0022eh).6, vcal3_leanprotect_ratelimit_subb_acc_2 ; 37DC 0 208 180 EE2E01
                LB      A, r3                  ; 37DF 0 208 180 7B
vcal3_leanprotect_ratelimit_subb_acc_2:     SUBB    A, r4                  ; 37E0 0 208 180 2C
                JGE     vcal3_leanprotect_ratelimit_cmp_acc_4             ; 37E1 0 208 180 CD01
                CLRB    A                      ; 37E3 0 208 180 FA
vcal3_leanprotect_ratelimit_cmp_acc_4:     CMPB    A, r5                  ; 37E4 0 208 180 4D
                MB      off(0022eh).6, C       ; 37E5 0 208 180 C42E3E
                LB      A, 0cch                ; 37E8 0 208 180 F5CC
                STB     A, r4                  ; 37EA 0 208 180 8C
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_17          ; 37EB 0 208 180 608666
                CAL     table_interp_lookup             ; 37EE 0 208 180 323958
                STB     A, off(002ach)         ; 37F1 0 208 180 D4AC
                LB      A, r4                  ; 37F3 0 208 180 7C
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_18          ; 37F4 0 208 180 609466
                CAL     table_interp_lookup             ; 37F7 0 208 180 323958
                STB     A, off(002adh)         ; 37FA 0 208 180 D4AD
                CMPB    r5, A                  ; 37FC 0 208 180 25C1
                JGT     vcal3_leanprotect_ratelimit_store_carry_ram22f_bit4             ; 37FE 0 208 180 C803
                LB      A, off(002ach)         ; 3800 0 208 180 F4AC
                CMPB    A, r5                  ; 3802 0 208 180 4D
vcal3_leanprotect_ratelimit_store_carry_ram22f_bit4:     MB      off(0022fh).4, C       ; 3803 0 208 180 C42F3C
                LB      A, r4                  ; 3806 0 208 180 7C
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_19          ; 3807 0 208 180 60A266
                CAL     table_interp_lookup             ; 380A 0 208 180 323958
                STB     A, off(002aeh)         ; 380D 0 208 180 D4AE
                LB      A, r4                  ; 380F 0 208 180 7C
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_20          ; 3810 0 208 180 60B066
                CAL     table_interp_lookup             ; 3813 0 208 180 323958
                STB     A, off(002afh)         ; 3816 0 208 180 D4AF
                CMPB    r5, A                  ; 3818 0 208 180 25C1
                JGT     vcal3_leanprotect_ratelimit_store_carry_ram22f_bit5             ; 381A 0 208 180 C803
                LB      A, off(002aeh)         ; 381C 0 208 180 F4AE
                CMPB    A, r5                  ; 381E 0 208 180 4D
vcal3_leanprotect_ratelimit_store_carry_ram22f_bit5:     MB      off(0022fh).5, C       ; 381F 0 208 180 C42F3D
                LB      A, 0cch                ; 3822 0 208 180 F5CC
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_13          ; 3824 0 208 180 605466
                JBS     off(0022eh).3, vcal3_leanprotect_ratelimit_call_table_interp_lookup ; 3827 0 208 180 EB2E03
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_14          ; 382A 0 208 180 605E66
vcal3_leanprotect_ratelimit_call_table_interp_lookup:     CAL     table_interp_lookup             ; 382D 0 208 180 323958
                MOV     DP, #00311h            ; 3830 0 208 180 621103
                ADDB    A, [DP]                ; 3833 0 208 180 C282
                CMPB    A, 0d4h                ; 3835 0 208 180 C5D4C2
                MB      off(0022eh).3, C       ; 3838 0 208 180 C42E3B
                MOVB    r0, 0cch               ; 383B 0 208 180 C5CC48
                LB      A, #025h               ; 383E 0 208 180 7725
                JBS     off(0022eh).2, vcal3_leanprotect_ratelimit_cmp_acc_5 ; 3840 0 208 180 EA2E02
                LB      A, #02bh               ; 3843 0 208 180 772B
vcal3_leanprotect_ratelimit_cmp_acc_5:     CMPB    A, r0                  ; 3845 0 208 180 48
                MB      off(0022eh).2, C       ; 3846 0 208 180 C42E3A
                LB      A, #082h               ; 3849 0 208 180 7782
                JBS     off(0022ch).2, vcal3_leanprotect_ratelimit_cmp_acc_6 ; 384B 0 208 180 EA2C02
                LB      A, #087h               ; 384E 0 208 180 7787
vcal3_leanprotect_ratelimit_cmp_acc_6:     CMPB    A, r0                  ; 3850 0 208 180 48
                MB      off(0022ch).2, C       ; 3851 0 208 180 C42C3A
                LB      A, #05fh               ; 3854 0 208 180 775F
                JBS     off(0022ch).3, vcal3_leanprotect_ratelimit_cmp_acc_7 ; 3856 0 208 180 EB2C02
                LB      A, #064h               ; 3859 0 208 180 7764
vcal3_leanprotect_ratelimit_cmp_acc_7:     CMPB    A, r0                  ; 385B 0 208 180 48
                MB      off(0022ch).3, C       ; 385C 0 208 180 C42C3B
                LB      A, #09ch               ; 385F 0 208 180 779C
                JBS     off(0022ch).4, vcal3_leanprotect_ratelimit_cmp_acc_8 ; 3861 0 208 180 EC2C02
                LB      A, #0a1h               ; 3864 0 208 180 77A1
vcal3_leanprotect_ratelimit_cmp_acc_8:     CMPB    A, r0                  ; 3866 0 208 180 48
                MB      off(0022ch).4, C       ; 3867 0 208 180 C42C3C
                LB      A, #00fh               ; 386A 0 208 180 770F
                JBS     off(0022ch).5, vcal3_leanprotect_ratelimit_cmp_acc_9 ; 386C 0 208 180 ED2C02
                LB      A, #011h               ; 386F 0 208 180 7711
vcal3_leanprotect_ratelimit_cmp_acc_9:     CMPB    A, r0                  ; 3871 0 208 180 48
                MB      off(0022ch).5, C       ; 3872 0 208 180 C42C3D
                LB      A, #010h               ; 3875 0 208 180 7710
                JBS     off(0022ch).6, vcal3_leanprotect_ratelimit_cmp_acc_10 ; 3877 0 208 180 EE2C02
                LB      A, #012h               ; 387A 0 208 180 7712
vcal3_leanprotect_ratelimit_cmp_acc_10:     CMPB    A, r0                  ; 387C 0 208 180 48
                MB      off(0022ch).6, C       ; 387D 0 208 180 C42C3E
                LB      A, #044h               ; 3880 0 208 180 7744
                JBS     off(0022ch).7, vcal3_leanprotect_ratelimit_cmp_acc_11 ; 3882 0 208 180 EF2C02
                LB      A, #049h               ; 3885 0 208 180 7749
vcal3_leanprotect_ratelimit_cmp_acc_11:     CMPB    A, r0                  ; 3887 0 208 180 48
                MB      off(0022ch).7, C       ; 3888 0 208 180 C42C3F
                LB      A, #022h               ; 388B 0 208 180 7722
                JBS     off(0022dh).0, vcal3_leanprotect_ratelimit_cmp_acc_12 ; 388D 0 208 180 E82D02
                LB      A, #025h               ; 3890 0 208 180 7725
vcal3_leanprotect_ratelimit_cmp_acc_12:     CMPB    A, r0                  ; 3892 0 208 180 48
                MB      off(0022dh).0, C       ; 3893 0 208 180 C42D38
                LB      A, #039h               ; 3896 0 208 180 7739
                JBS     off(0022dh).1, vcal3_leanprotect_ratelimit_cmp_acc_13 ; 3898 0 208 180 E92D02
                LB      A, #041h               ; 389B 0 208 180 7741
vcal3_leanprotect_ratelimit_cmp_acc_13:     CMPB    A, r0                  ; 389D 0 208 180 48
                MB      off(0022dh).1, C       ; 389E 0 208 180 C42D39
                LB      A, #014h               ; 38A1 0 208 180 7714
                JBS     off(0022dh).2, vcal3_leanprotect_ratelimit_cmp_acc_14 ; 38A3 0 208 180 EA2D02
                LB      A, #016h               ; 38A6 0 208 180 7716
vcal3_leanprotect_ratelimit_cmp_acc_14:     CMPB    A, r0                  ; 38A8 0 208 180 48
                MB      off(0022dh).2, C       ; 38A9 0 208 180 C42D3A
                LB      A, #025h               ; 38AC 0 208 180 7725
                JBS     off(0022dh).3, vcal3_leanprotect_ratelimit_cmp_acc_15 ; 38AE 0 208 180 EB2D02
                LB      A, #02bh               ; 38B1 0 208 180 772B
vcal3_leanprotect_ratelimit_cmp_acc_15:     CMPB    A, r0                  ; 38B3 0 208 180 48
                MB      off(0022dh).3, C       ; 38B4 0 208 180 C42D3B
                LB      A, #05fh               ; 38B7 0 208 180 775F
                JBS     off(0022dh).4, vcal3_leanprotect_ratelimit_cmp_acc_16 ; 38B9 0 208 180 EC2D02
                LB      A, #064h               ; 38BC 0 208 180 7764
vcal3_leanprotect_ratelimit_cmp_acc_16:     CMPB    A, r0                  ; 38BE 0 208 180 48
                MB      off(0022dh).4, C       ; 38BF 0 208 180 C42D3C
                LB      A, #07dh               ; 38C2 0 208 180 777D
                JBS     off(0022dh).5, vcal3_leanprotect_ratelimit_cmp_acc_17 ; 38C4 0 208 180 ED2D02
                LB      A, #082h               ; 38C7 0 208 180 7782
vcal3_leanprotect_ratelimit_cmp_acc_17:     CMPB    A, r0                  ; 38C9 0 208 180 48
                MB      off(0022dh).5, C       ; 38CA 0 208 180 C42D3D
                LB      A, #014h               ; 38CD 0 208 180 7714
                JBS     off(0022dh).6, vcal3_leanprotect_ratelimit_cmp_acc_18 ; 38CF 0 208 180 EE2D02
                LB      A, #019h               ; 38D2 0 208 180 7719
vcal3_leanprotect_ratelimit_cmp_acc_18:     CMPB    A, r0                  ; 38D4 0 208 180 48
                MB      off(0022dh).6, C       ; 38D5 0 208 180 C42D3E
                LB      A, #021h               ; 38D8 0 208 180 7721
                JBS     off(0022dh).7, vcal3_leanprotect_ratelimit_cmp_acc_19 ; 38DA 0 208 180 EF2D02
                LB      A, #026h               ; 38DD 0 208 180 7726
vcal3_leanprotect_ratelimit_cmp_acc_19:     CMPB    A, r0                  ; 38DF 0 208 180 48
                J       vcal3_leanprotect_ratelimit_store_carry_ram22d_bit7             ; 38E0 0 208 180 031178
vcal3_leanprotect_ratelimit_load_imm:     LB      A, #036h               ; 38E3 0 208 180 7736
                JBS     off(0022eh).1, vcal3_leanprotect_ratelimit_cmp_acc_20 ; 38E5 0 208 180 E92E02
                LB      A, #050h               ; 38E8 0 208 180 7750
vcal3_leanprotect_ratelimit_cmp_acc_20:     CMPB    A, off(00238h)         ; 38EA 0 208 180 C738
                MB      off(0022eh).1, C       ; 38EC 0 208 180 C42E39
                MOVB    r6, #001h              ; 38EF 0 208 180 9E01
                MOVB    r7, #001h              ; 38F1 0 208 180 9F01
                MOV     DP, #vcal3_leanprotect_ratelimit_tbl_8          ; 38F3 0 208 180 62E465
                JBS     off(00211h).5, vcal3_leanprotect_ratelimit_goto_39b2 ; 38F6 0 208 180 ED1106
                JBS     off(00211h).6, vcal3_leanprotect_ratelimit_load_x1_2 ; 38F9 0 208 180 EE111E
                JBS     off(00211h).7, vcal3_leanprotect_ratelimit_load_x1 ; 38FC 0 208 180 EF1103
vcal3_leanprotect_ratelimit_goto_39b2:     J       vcal3_leanprotect_ratelimit_load_ram2b1             ; 38FF 0 208 180 03B239
vcal3_leanprotect_ratelimit_load_x1:     MOV     X1, #vcal3_leanprotect_ratelimit_tbl_3          ; 3902 0 208 180 608A65
                CMPB    off(002b1h), #004h     ; 3905 0 208 180 C4B1C004
                JLT     vcal3_leanprotect_ratelimit_load_ram0d1             ; 3909 0 208 180 CA03
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_2          ; 390B 0 208 180 607865
vcal3_leanprotect_ratelimit_load_ram0d1:     LB      A, 0d1h                ; 390E 0 208 180 F5D1
                CAL     table_interp_lookup             ; 3910 0 208 180 323958
                MOVB    r6, #004h              ; 3913 0 208 180 9E04
                CMPB    A, 0cch                ; 3915 0 208 180 C5CCC2
                JLT     vcal3_leanprotect_ratelimit_load_r7             ; 3918 0 208 180 CA38
vcal3_leanprotect_ratelimit_load_x1_2:     MOV     X1, #vcal3_leanprotect_ratelimit_tbl_5          ; 391A 0 208 180 60AE65
                CMPB    off(002b1h), #003h     ; 391D 0 208 180 C4B1C003
                JLT     vcal3_leanprotect_ratelimit_load_ram0d1_2             ; 3921 0 208 180 CA03
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_4          ; 3923 0 208 180 609C65
vcal3_leanprotect_ratelimit_load_ram0d1_2:     LB      A, 0d1h                ; 3926 0 208 180 F5D1
                CAL     table_interp_lookup             ; 3928 0 208 180 323958
                MOVB    r6, #003h              ; 392B 0 208 180 9E03
                INC     DP                     ; 392D 0 208 180 72
                INC     DP                     ; 392E 0 208 180 72
                CMPB    A, 0cch                ; 392F 0 208 180 C5CCC2
                JLT     vcal3_leanprotect_ratelimit_load_r7             ; 3932 0 208 180 CA1E
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_7          ; 3934 0 208 180 60D265
                CMPB    off(002b1h), #002h     ; 3937 0 208 180 C4B1C002
                JLT     vcal3_leanprotect_ratelimit_load_ram0d1_3             ; 393B 0 208 180 CA03
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_6          ; 393D 0 208 180 60C065
vcal3_leanprotect_ratelimit_load_ram0d1_3:     LB      A, 0d1h                ; 3940 0 208 180 F5D1
                CAL     table_interp_lookup             ; 3942 0 208 180 323958
                MOVB    r6, #002h              ; 3945 0 208 180 9E02
                INC     DP                     ; 3947 0 208 180 72
                INC     DP                     ; 3948 0 208 180 72
                CMPB    A, 0cch                ; 3949 0 208 180 C5CCC2
                JLT     vcal3_leanprotect_ratelimit_load_r7             ; 394C 0 208 180 CA04
                MOVB    r6, #001h              ; 394E 0 208 180 9E01
                INC     DP                     ; 3950 0 208 180 72
                INC     DP                     ; 3951 0 208 180 72
vcal3_leanprotect_ratelimit_load_r7:     MOVB    r7, r6                 ; 3952 0 208 180 264F
                NOP                            ; 3954 0 208 180 00
                NOP                            ; 3955 0 208 180 00
                NOP                            ; 3956 0 208 180 00
                NOP                            ; 3957 0 208 180 00
                JBS     off(00218h).2, vcal3_leanprotect_ratelimit_load_ram2e2 ; 3958 0 208 180 EA1806
                MOVB    off(002e2h), #028h     ; 395B 0 208 180 C4E29828
                SJ      vcal3_leanprotect_ratelimit_load_ram2b1             ; 395F 0 208 180 CB51
vcal3_leanprotect_ratelimit_load_ram2e2:     LB      A, off(002e2h)         ; 3961 0 208 180 F4E2
                JNE     vcal3_leanprotect_ratelimit_load_ram2b1             ; 3963 0 208 180 CE4D
                JBR     off(0022eh).2, vcal3_leanprotect_ratelimit_load_ram2b1 ; 3965 0 208 180 DA2E4A
                LC      A, 00008h[DP]          ; 3968 0 208 180 92A90800
                MOV     er2, A                 ; 396C 0 208 180 468A
                MOV     er0, 0ceh              ; 396E 0 208 180 B5CE48
                CLR     A                      ; 3971 1 208 180 F9
                DIV                            ; 3972 1 208 180 9037
                LB      A, r0                  ; 3974 0 208 180 78
                L       A, ACC                 ; 3975 1 208 180 E506
                SWAP                           ; 3977 1 208 180 83
                CMPB    r1, #000h              ; 3978 1 208 180 21C000
                JEQ     vcal3_leanprotect_ratelimit_cmp_ram0c4             ; 397B 1 208 180 C903
                L       A, #0ffffh             ; 397D 1 208 180 67FFFF
vcal3_leanprotect_ratelimit_cmp_ram0c4:     CMP     0c4h, A                ; 3980 1 208 180 B5C4C1
                JGE     vcal3_leanprotect_ratelimit_load_imm_2             ; 3983 1 208 180 CD22
                LC      A, [DP]                ; 3985 1 208 180 92A8
                ST      A, er2                 ; 3987 1 208 180 8A
                MOV     er0, 0ceh              ; 3988 1 208 180 B5CE48
                CLR     A                      ; 398B 1 208 180 F9
                DIV                            ; 398C 1 208 180 9037
                LB      A, r0                  ; 398E 0 208 180 78
                L       A, ACC                 ; 398F 1 208 180 E506
                SWAP                           ; 3991 1 208 180 83
                CMPB    r1, #000h              ; 3992 1 208 180 21C000
                JEQ     vcal3_leanprotect_ratelimit_cmp_ram0c4_2             ; 3995 1 208 180 C903
                L       A, #0ffffh             ; 3997 1 208 180 67FFFF
vcal3_leanprotect_ratelimit_cmp_ram0c4_2:     CMP     0c4h, A                ; 399A 1 208 180 B5C4C1
                JGE     vcal3_leanprotect_ratelimit_load_ram2b1             ; 399D 1 208 180 CD13
                CMPB    r7, #001h              ; 399F 1 208 180 27C001
                JEQ     vcal3_leanprotect_ratelimit_load_ram2b1             ; 39A2 1 208 180 C90E
                DECB    r7                     ; 39A4 1 208 180 BF
                SJ      vcal3_leanprotect_ratelimit_load_ram2b1             ; 39A5 1 208 180 CB0B
vcal3_leanprotect_ratelimit_load_imm_2:     LB      A, #004h               ; 39A7 0 208 180 7704
                JBR     off(00211h).6, vcal3_leanprotect_ratelimit_cmp_acc_21 ; 39A9 0 208 180 DE1102
                LB      A, #003h               ; 39AC 0 208 180 7703
vcal3_leanprotect_ratelimit_cmp_acc_21:     CMPB    A, r7                  ; 39AE 0 208 180 4F
                JEQ     vcal3_leanprotect_ratelimit_load_ram2b1             ; 39AF 0 208 180 C901
                INCB    r7                     ; 39B1 0 208 180 AF
vcal3_leanprotect_ratelimit_load_ram2b1:     MOVB    off(002b1h), r6        ; 39B2 0 208 180 267CB1
                MOVB    off(002b2h), r7        ; 39B5 0 208 180 277CB2
                LB      A, off(00214h)         ; 39B8 0 208 180 F414
                STB     A, ACCH                ; 39BA 0 208 180 D507
                LB      A, off(00212h)         ; 39BC 0 208 180 F412
                AND     ACC, #00560h           ; 39BE 0 208 180 B506D06005
                JNE     vcal3_leanprotect_ratelimit_load_ram2d9             ; 39C3 0 208 180 CE1C
                CMPB    0d9h, #03ch            ; 39C5 0 208 180 C5D9C03C
                JGE     vcal3_leanprotect_ratelimit_load_ram2d9             ; 39C9 0 208 180 CD16
                JBR     off(0022eh).1, vcal3_leanprotect_ratelimit_load_ram2d9 ; 39CB 0 208 180 D92E13
                JBS     off(00211h).7, vcal3_leanprotect_ratelimit_load_ram2db_2 ; 39CE 0 208 180 EF111A
                JBR     off(00211h).6, vcal3_leanprotect_ratelimit_load_ram2d9 ; 39D1 0 208 180 DE110D
                JBR     off(0022fh).0, vcal3_leanprotect_ratelimit_load_ram2db ; 39D4 0 208 180 D82F04
                MOVB    off(002d8h), #014h     ; 39D7 0 208 180 C4D89814
vcal3_leanprotect_ratelimit_load_ram2db:     LB      A, off(002dbh)         ; 39DB 0 208 180 F4DB
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2             ; 39DD 0 208 180 CE40
                SJ      vcal3_leanprotect_ratelimit_load_ram2d9_2             ; 39DF 0 208 180 CB04
vcal3_leanprotect_ratelimit_load_ram2d9:     MOVB    off(002d9h), #002h     ; 39E1 0 208 180 C4D99802
vcal3_leanprotect_ratelimit_load_ram2d9_2:     LB      A, off(002d9h)         ; 39E5 0 208 180 F4D9
                JEQ     vcal3_leanprotect_ratelimit_if_ram21b_bit6_set             ; 39E7 0 208 180 C90A
                SJ      vcal3_leanprotect_ratelimit_clear_carry_2             ; 39E9 0 208 180 CB34
vcal3_leanprotect_ratelimit_load_ram2db_2:     MOVB    off(002dbh), #00ch     ; 39EB 0 208 180 C4DB980C
                LB      A, off(002d8h)         ; 39EF 0 208 180 F4D8
                JEQ     vcal3_leanprotect_ratelimit_load_ram2d9_2             ; 39F1 0 208 180 C9F2
vcal3_leanprotect_ratelimit_if_ram21b_bit6_set:     JBS     off(0021bh).6, vcal3_leanprotect_ratelimit_load_ram2da ; 39F3 0 208 180 EE1B0B
                CMP     0c6h, #00120h          ; 39F6 0 208 180 B5C6C02001
                JLT     vcal3_leanprotect_ratelimit_load_ram2da             ; 39FB 0 208 180 CA04
                MOVB    off(002dah), #014h     ; 39FD 0 208 180 C4DA9814
vcal3_leanprotect_ratelimit_load_ram2da:     LB      A, off(002dah)         ; 3A01 0 208 180 F4DA
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2             ; 3A03 0 208 180 CE1A
                JBS     off(0022eh).3, vcal3_leanprotect_ratelimit_if_ram211_bit6_set ; 3A05 0 208 180 EB2E1A
                CMPB    off(002b2h), #003h     ; 3A08 0 208 180 C4B2C003
                JLT     vcal3_leanprotect_ratelimit_clear_carry_2             ; 3A0C 0 208 180 CA11
                MB      C, off(0022dh).6       ; 3A0E 0 208 180 C42D2E
                JEQ     vcal3_leanprotect_ratelimit_if_ge_goto_3a1f             ; 3A11 0 208 180 C903
                MB      C, off(0022dh).7       ; 3A13 0 208 180 C42D2F
vcal3_leanprotect_ratelimit_if_ge_goto_3a1f:     JGE     vcal3_leanprotect_ratelimit_clear_carry_2             ; 3A16 0 208 180 CD07
                LB      A, off(002c7h)         ; 3A18 0 208 180 F4C7
                JEQ     vcal3_leanprotect_ratelimit_clear_carry_2             ; 3A1A 0 208 180 C903
                JBS     off(0021ch).3, vcal3_leanprotect_ratelimit_if_ram22f_bit0_set ; 3A1C 0 208 180 EB1C22
vcal3_leanprotect_ratelimit_clear_carry_2:     RC                             ; 3A1F 0 208 180 95
                SJ      vcal3_leanprotect_ratelimit_store_carry_ram22f_bit0             ; 3A20 0 208 180 CB38
vcal3_leanprotect_ratelimit_if_ram211_bit6_set:     JBS     off(00211h).6, vcal3_leanprotect_ratelimit_if_ram22c_bit2_set ; 3A22 0 208 180 EE110F
                JBS     off(0022ch).4, vcal3_leanprotect_ratelimit_if_ram22f_bit0_set ; 3A25 0 208 180 EC2C19
                JBR     off(0022ch).5, vcal3_leanprotect_ratelimit_load_ram2dc ; 3A28 0 208 180 DD2C03
                JBR     off(0022eh).7, vcal3_leanprotect_ratelimit_load_ram2dc_2 ; 3A2B 0 208 180 DF2E0F
vcal3_leanprotect_ratelimit_load_ram2dc:     MOVB    off(002dch), #00fh     ; 3A2E 0 208 180 C4DC980F
                SJ      vcal3_leanprotect_ratelimit_load_ram2dc_2             ; 3A32 0 208 180 CB09
vcal3_leanprotect_ratelimit_if_ram22c_bit2_set:     JBS     off(0022ch).2, vcal3_leanprotect_ratelimit_if_ram22f_bit0_set ; 3A34 0 208 180 EA2C0A
                JBR     off(0022ch).3, vcal3_leanprotect_ratelimit_load_ram2dc ; 3A37 0 208 180 DB2CF4
                JBS     off(0022eh).5, vcal3_leanprotect_ratelimit_load_ram2dc ; 3A3A 0 208 180 ED2EF1
vcal3_leanprotect_ratelimit_load_ram2dc_2:     LB      A, off(002dch)         ; 3A3D 0 208 180 F4DC
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2             ; 3A3F 0 208 180 CEDE
vcal3_leanprotect_ratelimit_if_ram22f_bit0_set:     JBS     off(0022fh).0, vcal3_leanprotect_ratelimit_set_carry ; 3A41 0 208 180 E82F15
                LB      A, 0d5h                ; 3A44 0 208 180 F5D5
                JBS     off(0021bh).1, vcal3_leanprotect_ratelimit_cmp_acc_22 ; 3A46 0 208 180 E91B04
                CMPB    A, #010h               ; 3A49 0 208 180 C610
                JGT     vcal3_leanprotect_ratelimit_load_ram2e1             ; 3A4B 0 208 180 C804
vcal3_leanprotect_ratelimit_cmp_acc_22:     CMPB    A, #020h               ; 3A4D 0 208 180 C620
                JLE     vcal3_leanprotect_ratelimit_load_ram2e1_2             ; 3A4F 0 208 180 CF04
vcal3_leanprotect_ratelimit_load_ram2e1:     MOVB    off(002e1h), #002h     ; 3A51 0 208 180 C4E19802
vcal3_leanprotect_ratelimit_load_ram2e1_2:     LB      A, off(002e1h)         ; 3A55 0 208 180 F4E1
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2             ; 3A57 0 208 180 CEC6
vcal3_leanprotect_ratelimit_set_carry:     SC                             ; 3A59 0 208 180 85
vcal3_leanprotect_ratelimit_store_carry_ram22f_bit0:     MB      off(0022fh).0, C       ; 3A5A 0 208 180 C42F38
                MB      P0.4, C                ; 3A5D 0 208 180 C5203C
                CMPB    0d8h, #0e1h            ; 3A60 0 208 180 C5D8C0E1
                JGE     vcal3_leanprotect_ratelimit_load_imm_3             ; 3A64 0 208 180 CD06
                CMPB    0d9h, #02eh            ; 3A66 0 208 180 C5D9C02E
                JLT     vcal3_leanprotect_ratelimit_if_ram22d_bit0_set             ; 3A6A 0 208 180 CA08
vcal3_leanprotect_ratelimit_load_imm_3:     LB      A, #00ch               ; 3A6C 0 208 180 770C
                STB     A, off(002bah)         ; 3A6E 0 208 180 D4BA
                STB     A, off(002b0h)         ; 3A70 0 208 180 D4B0
                SJ      vcal3_leanprotect_ratelimit_goto_3cb2             ; 3A72 0 208 180 CB71
vcal3_leanprotect_ratelimit_if_ram22d_bit0_set:     JBS     off(0022dh).0, vcal3_leanprotect_ratelimit_load_ram2ba ; 3A74 0 208 180 E82D06
                LB      A, off(002b0h)         ; 3A77 0 208 180 F4B0
                STB     A, off(002bah)         ; 3A79 0 208 180 D4BA
                SJ      vcal3_leanprotect_ratelimit_if_ne_goto_3ae5             ; 3A7B 0 208 180 CB04
vcal3_leanprotect_ratelimit_load_ram2ba:     LB      A, off(002bah)         ; 3A7D 0 208 180 F4BA
                STB     A, off(002b0h)         ; 3A7F 0 208 180 D4B0
vcal3_leanprotect_ratelimit_if_ne_goto_3ae5:     JNE     vcal3_leanprotect_ratelimit_goto_3cb2             ; 3A81 0 208 180 CE62
                JBR     off(0022fh).0, vcal3_leanprotect_ratelimit_goto_3cb2 ; 3A83 0 208 180 D82F5F
                JBS     off(0022eh).3, vcal3_leanprotect_ratelimit_load_carry_ram22e_bit4 ; 3A86 0 208 180 EB2E09
                CMPB    off(002b2h), #002h     ; 3A89 0 208 180 C4B2C002
                JLE     vcal3_leanprotect_ratelimit_goto_3cb2             ; 3A8D 0 208 180 CF56
                J       vcal3_leanprotect_ratelimit_if_ram22f_bit7_set             ; 3A8F 0 208 180 032278
vcal3_leanprotect_ratelimit_load_carry_ram22e_bit4:     MB      C, off(0022eh).4       ; 3A92 0 208 180 C42E2C
                JBS     off(00211h).6, vcal3_leanprotect_ratelimit_if_ge_goto_3aa1 ; 3A95 0 208 180 EE1103
                MB      C, off(0022eh).6       ; 3A98 0 208 180 C42E2E
vcal3_leanprotect_ratelimit_if_ge_goto_3aa1:     JGE     vcal3_leanprotect_ratelimit_load_ram2dd             ; 3A9B 0 208 180 CD04
                MOVB    off(002ddh), #00ah     ; 3A9D 0 208 180 C4DD980A
vcal3_leanprotect_ratelimit_load_ram2dd:     LB      A, off(002ddh)         ; 3AA1 0 208 180 F4DD
                JNE     vcal3_leanprotect_ratelimit_goto_3cb2             ; 3AA3 0 208 180 CE40
                MOV     er1, #00028h           ; 3AA5 0 208 180 45982800
                JBR     off(00211h).6, vcal3_leanprotect_ratelimit_if_ram22d_bit5_clr ; 3AA9 0 208 180 DE1105
                JBR     off(0022dh).4, vcal3_leanprotect_ratelimit_goto_3cb2 ; 3AAC 0 208 180 DC2D36
                SJ      vcal3_leanprotect_ratelimit_goto_3c9c             ; 3AAF 0 208 180 CB31
vcal3_leanprotect_ratelimit_if_ram22d_bit5_clr:     JBR     off(0022dh).5, vcal3_leanprotect_ratelimit_if_ram22d_bit1_set ; 3AB1 0 208 180 DD2D06
                MOV     er1, #00033h           ; 3AB4 0 208 180 45983300
                SJ      vcal3_leanprotect_ratelimit_goto_3c9c             ; 3AB8 0 208 180 CB28
vcal3_leanprotect_ratelimit_if_ram22d_bit1_set:     JBS     off(0022dh).1, vcal3_leanprotect_ratelimit_goto_3c9c ; 3ABA 0 208 180 E92D25
                CMPB    off(002b2h), #003h     ; 3ABD 0 208 180 C4B2C003
                JLT     vcal3_leanprotect_ratelimit_goto_3cb2             ; 3AC1 0 208 180 CA22
                JEQ     vcal3_leanprotect_ratelimit_if_ram22d_bit2_clr             ; 3AC3 0 208 180 C905
                JBR     off(0022dh).3, vcal3_leanprotect_ratelimit_goto_3cb2 ; 3AC5 0 208 180 DB2D1D
                SJ      vcal3_leanprotect_ratelimit_load_carry_ram22f_bit4             ; 3AC8 0 208 180 CB03
vcal3_leanprotect_ratelimit_if_ram22d_bit2_clr:     JBR     off(0022dh).2, vcal3_leanprotect_ratelimit_goto_3cb2 ; 3ACA 0 208 180 DA2D18
vcal3_leanprotect_ratelimit_load_carry_ram22f_bit4:     MB      C, off(0022fh).4       ; 3ACD 0 208 180 C42F2C
                JEQ     vcal3_leanprotect_ratelimit_if_lt_goto_3adb             ; 3AD0 0 208 180 C903
                MB      C, off(0022fh).5       ; 3AD2 0 208 180 C42F2D
vcal3_leanprotect_ratelimit_if_lt_goto_3adb:     JLT     vcal3_leanprotect_ratelimit_load_ram2de             ; 3AD5 0 208 180 CA04
                MOVB    off(002deh), #00ah     ; 3AD7 0 208 180 C4DE980A
vcal3_leanprotect_ratelimit_load_ram2de:     LB      A, off(002deh)         ; 3ADB 0 208 180 F4DE
                JEQ     vcal3_leanprotect_ratelimit_set_ram22f_bit3             ; 3ADD 0 208 180 C909
                J       vcal3_leanprotect_ratelimit_load_ram2ac_2             ; 3ADF 0 208 180 03423C
vcal3_leanprotect_ratelimit_goto_3c9c:     J       vcal3_leanprotect_ratelimit_load_ram2a6             ; 3AE2 0 208 180 039C3C
vcal3_leanprotect_ratelimit_goto_3cb2:     J       vcal3_leanprotect_ratelimit_clear_acc             ; 3AE5 0 208 180 03B23C
vcal3_leanprotect_ratelimit_set_ram22f_bit3:     SB      off(0022fh).3          ; 3AE8 0 208 180 C42F1B
                JNE     vcal3_leanprotect_ratelimit_load_ram2ac             ; 3AEB 0 208 180 CE11
                MOV     DP, #00316h            ; 3AED 0 208 180 621603
                CMPB    off(002b2h), #003h     ; 3AF0 0 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_load_dp_ind             ; 3AF4 0 208 180 CF03
                MOV     DP, #00318h            ; 3AF6 0 208 180 621803
vcal3_leanprotect_ratelimit_load_dp_ind:     L       A, [DP]                ; 3AF9 1 208 180 E2
                ST      A, off(002a8h)         ; 3AFA 1 208 180 D4A8
                SJ      vcal3_leanprotect_ratelimit_if_eq_goto_3b5d             ; 3AFC 1 208 180 CB55
vcal3_leanprotect_ratelimit_load_ram2ac:     LB      A, off(002ach)         ; 3AFE 0 208 180 F4AC
                MOVB    r0, #050h              ; 3B00 0 208 180 9850
                MOV     er1, #039eeh           ; 3B02 0 208 180 4598EE39
                MOVB    r6, #028h              ; 3B06 0 208 180 9E28
                MOVB    r7, #028h              ; 3B08 0 208 180 9F28
                CMPB    off(002b2h), #003h     ; 3B0A 0 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_subb_acc_3             ; 3B0E 0 208 180 CF0C
                LB      A, off(002aeh)         ; 3B10 0 208 180 F4AE
                MOVB    r0, #050h              ; 3B12 0 208 180 9850
                MOV     er1, #04cefh           ; 3B14 0 208 180 4598EF4C
                MOVB    r6, #028h              ; 3B18 0 208 180 9E28
                MOVB    r7, #028h              ; 3B1A 0 208 180 9F28
vcal3_leanprotect_ratelimit_subb_acc_3:     SUBB    A, 0d1h                ; 3B1C 0 208 180 C5D1A2
                MB      PSWL.4, C              ; 3B1F 0 208 180 A33C
                JGE     vcal3_leanprotect_ratelimit_mulb_acc             ; 3B21 0 208 180 CD01
                VCAL    6                      ; 3B23 0 208 180 16
vcal3_leanprotect_ratelimit_mulb_acc:     MULB                           ; 3B24 0 208 180 A234
                L       A, ACC                 ; 3B26 1 208 180 E506
                MB      C, PSWL.4              ; 3B28 1 208 180 A32C
                JGE     vcal3_leanprotect_ratelimit_add_acc             ; 3B2A 1 208 180 CD08
                XCHG    A, er1                 ; 3B2C 1 208 180 4510
                SUB     A, er1                 ; 3B2E 1 208 180 29
                JGE     vcal3_leanprotect_ratelimit_store_er0             ; 3B2F 1 208 180 CD09
                CLR     A                      ; 3B31 1 208 180 F9
                SJ      vcal3_leanprotect_ratelimit_store_er0             ; 3B32 1 208 180 CB06
vcal3_leanprotect_ratelimit_add_acc:     ADD     A, er1                 ; 3B34 1 208 180 09
                JGE     vcal3_leanprotect_ratelimit_store_er0             ; 3B35 1 208 180 CD03
                L       A, #0ffffh             ; 3B37 1 208 180 67FFFF
vcal3_leanprotect_ratelimit_store_er0:     ST      A, er0                 ; 3B3A 1 208 180 88
                L       A, 0ceh                ; 3B3B 1 208 180 E5CE
                MUL                            ; 3B3D 1 208 180 9035
                L       A, er1                 ; 3B3F 1 208 180 35
                MOV     DP, #00386h            ; 3B40 1 208 180 628603
                ST      A, [DP]                ; 3B43 1 208 180 D2
                SUB     A, 0c4h                ; 3B44 1 208 180 B5C4A2
                MB      PSWL.4, C              ; 3B47 1 208 180 A33C
                JGE     vcal3_leanprotect_ratelimit_load_dp             ; 3B49 1 208 180 CD01
                VCAL    7                      ; 3B4B 1 208 180 17
vcal3_leanprotect_ratelimit_load_dp:     MOV     DP, #00388h            ; 3B4C 1 208 180 628803
                ST      A, [DP]                ; 3B4F 1 208 180 D2
                CAL     weighted_sum_2term_trim             ; 3B50 1 208 180 32295B
vcal3_leanprotect_ratelimit_if_eq_goto_3b5d:     JEQ     vcal3_leanprotect_ratelimit_load_x2             ; 3B53 1 208 180 C908
                CMP     A, #00333h             ; 3B55 1 208 180 C63303
                JLT     vcal3_leanprotect_ratelimit_load_x2             ; 3B58 1 208 180 CA03
                L       A, #00333h             ; 3B5A 1 208 180 673303
vcal3_leanprotect_ratelimit_load_x2:     MOV     X2, A                  ; 3B5D 1 208 180 51
                MOV     X1, #00316h            ; 3B5E 1 208 180 601603
                CMPB    off(002b2h), #003h     ; 3B61 1 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_load_er0             ; 3B65 1 208 180 CF02
                INC     X1                     ; 3B67 1 208 180 70
                INC     X1                     ; 3B68 1 208 180 70
vcal3_leanprotect_ratelimit_load_er0:     MOV     er0, #000ffh           ; 3B69 1 208 180 4498FF00
                CAL     vcal3_leanprotect_ratelimit_sub_load_er2             ; 3B6D 1 208 180 323A59
                CAL     clamp_to_35_512             ; 3B70 1 208 180 329F5A
                L       A, X2                  ; 3B73 1 208 180 41
                RB      off(0022fh).2          ; 3B74 1 208 180 C42F0A
                RB      off(0022fh).1          ; 3B77 1 208 180 C42F09
                J       vcal3_leanprotect_ratelimit_store_ram2a6             ; 3B7A 1 208 180 03BE3C
vcal3_leanprotect_ratelimit_clear_r0:     CLRB    r0                     ; 3B7D 0 208 180 2015
                MOV     DP, #00312h            ; 3B7F 0 208 180 621203
                MOVB    r1, #080h              ; 3B82 0 208 180 9980
                MOVB    r2, #040h              ; 3B84 0 208 180 9A40
                CMPB    off(002b2h), #003h     ; 3B86 0 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_load_dp_ind_2             ; 3B8A 0 208 180 CF06
                INC     DP                     ; 3B8C 0 208 180 72
                INC     DP                     ; 3B8D 0 208 180 72
                MOVB    r1, #080h              ; 3B8E 0 208 180 9980
                MOVB    r2, #040h              ; 3B90 0 208 180 9A40
vcal3_leanprotect_ratelimit_load_dp_ind_2:     L       A, [DP]                ; 3B92 1 208 180 E2
                SUB     A, off(002a8h)         ; 3B93 1 208 180 A7A8
                MB      PSWL.4, C              ; 3B95 1 208 180 A33C
                JGE     vcal3_leanprotect_ratelimit_cmp_acc_23             ; 3B97 1 208 180 CD03
                VCAL    7                      ; 3B99 1 208 180 17
                MOVB    r1, r2                 ; 3B9A 1 208 180 2249
vcal3_leanprotect_ratelimit_cmp_acc_23:     CMP     A, #00155h             ; 3B9C 1 208 180 C65501
                SB      off(0022fh).1          ; 3B9F 1 208 180 C42F19
                JNE     vcal3_leanprotect_ratelimit_if_ram222_bit7_set             ; 3BA2 1 208 180 CE29
                JGE     vcal3_leanprotect_ratelimit_mul_acc             ; 3BA4 1 208 180 CD03
                L       A, [DP]                ; 3BA6 1 208 180 E2
                SJ      vcal3_leanprotect_ratelimit_cmp_acc_24             ; 3BA7 1 208 180 CB14
vcal3_leanprotect_ratelimit_mul_acc:     MUL                            ; 3BA9 1 208 180 9035
                SLL     A                      ; 3BAB 1 208 180 53
                ROL     er1                    ; 3BAC 1 208 180 45B7
                JGE     vcal3_leanprotect_ratelimit_load_ram2a8             ; 3BAE 1 208 180 CD04
                MOV     er1, #0ffffh           ; 3BB0 1 208 180 4598FFFF
vcal3_leanprotect_ratelimit_load_ram2a8:     L       A, off(002a8h)         ; 3BB4 1 208 180 E4A8
                MB      C, PSWL.4              ; 3BB6 1 208 180 A32C
                JLT     vcal3_leanprotect_ratelimit_sub_acc             ; 3BB8 1 208 180 CA0D
                ADD     A, er1                 ; 3BBA 1 208 180 09
                JLT     vcal3_leanprotect_ratelimit_load_imm_4             ; 3BBB 1 208 180 CA05
vcal3_leanprotect_ratelimit_cmp_acc_24:     CMP     A, #003ffh             ; 3BBD 1 208 180 C6FF03
                JLT     vcal3_leanprotect_ratelimit_store_ram2a8             ; 3BC0 1 208 180 CA09
vcal3_leanprotect_ratelimit_load_imm_4:     L       A, #003ffh             ; 3BC2 1 208 180 67FF03
                SJ      vcal3_leanprotect_ratelimit_store_ram2a8             ; 3BC5 1 208 180 CB04
vcal3_leanprotect_ratelimit_sub_acc:     SUB     A, er1                 ; 3BC7 1 208 180 29
                JGE     vcal3_leanprotect_ratelimit_store_ram2a8             ; 3BC8 1 208 180 CD01
                CLR     A                      ; 3BCA 1 208 180 F9
vcal3_leanprotect_ratelimit_store_ram2a8:     ST      A, off(002a8h)         ; 3BCB 1 208 180 D4A8
vcal3_leanprotect_ratelimit_if_ram222_bit7_set:     JBS     off(00222h).7, vcal3_leanprotect_ratelimit_load_ram2df ; 3BCD 1 208 180 EF2211
                CMP     off(002aah), #00180h   ; 3BD0 1 208 180 B4AAC08001
                JLT     vcal3_leanprotect_ratelimit_load_ram2df             ; 3BD5 1 208 180 CA0A
                LB      A, off(002dfh)         ; 3BD7 0 208 180 F4DF
                JNE     vcal3_leanprotect_ratelimit_load_ram0ce             ; 3BD9 0 208 180 CE0A
                MOVB    off(002b2h), #004h     ; 3BDB 0 208 180 C4B29804
                SJ      vcal3_leanprotect_ratelimit_load_ram0ce             ; 3BDF 0 208 180 CB04
vcal3_leanprotect_ratelimit_load_ram2df:     MOVB    off(002dfh), #028h     ; 3BE1 1 208 180 C4DF9828
vcal3_leanprotect_ratelimit_load_ram0ce:     L       A, 0ceh                ; 3BE5 1 208 180 E5CE
                MOV     er0, #03c18h           ; 3BE7 1 208 180 4498183C
                CMPB    off(002b2h), #003h     ; 3BEB 1 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_mul_acc_2             ; 3BEF 1 208 180 CF04
                MOV     er0, #05352h           ; 3BF1 1 208 180 44985253
vcal3_leanprotect_ratelimit_mul_acc_2:     MUL                            ; 3BF5 1 208 180 9035
                L       A, er1                 ; 3BF7 1 208 180 35
                MOV     DP, #00386h            ; 3BF8 1 208 180 628603
                ST      A, [DP]                ; 3BFB 1 208 180 D2
                L       A, 0c4h                ; 3BFC 1 208 180 E5C4
                SUB     A, er1                 ; 3BFE 1 208 180 29
                MB      off(00222h).7, C       ; 3BFF 1 208 180 C4223F
                MB      PSWL.4, C              ; 3C02 1 208 180 A33C
                JGE     vcal3_leanprotect_ratelimit_store_ram2aa             ; 3C04 1 208 180 CD01
                VCAL    7                      ; 3C06 1 208 180 17
vcal3_leanprotect_ratelimit_store_ram2aa:     ST      A, off(002aah)         ; 3C07 1 208 180 D4AA
                MOVB    r6, #020h              ; 3C09 1 208 180 9E20
                MOVB    r7, #020h              ; 3C0B 1 208 180 9F20
                CAL     weighted_sum_2term_trim             ; 3C0D 1 208 180 32295B
                MOV     X2, A                  ; 3C10 1 208 180 51
                JEQ     vcal3_leanprotect_ratelimit_cmp_ram2e0             ; 3C11 1 208 180 C904
                MOVB    off(002e0h), #014h     ; 3C13 1 208 180 C4E09814
vcal3_leanprotect_ratelimit_cmp_ram2e0:     CMPB    off(002e0h), #000h     ; 3C17 1 208 180 C4E0C000
                JNE     vcal3_leanprotect_ratelimit_if_ram22c_bit6_clr             ; 3C1B 1 208 180 CE04
                CLR     X2                     ; 3C1D 1 208 180 9115
                SJ      vcal3_leanprotect_ratelimit_load_x2_2             ; 3C1F 1 208 180 CB1B
vcal3_leanprotect_ratelimit_if_ram22c_bit6_clr:     JBR     off(0022ch).6, vcal3_leanprotect_ratelimit_load_x2_2 ; 3C21 1 208 180 DE2C18
                JBS     off(0022ch).7, vcal3_leanprotect_ratelimit_load_x2_2 ; 3C24 1 208 180 EF2C15
                MOV     X1, #00312h            ; 3C27 1 208 180 601203
                CMPB    off(002b2h), #003h     ; 3C2A 1 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_load_er0_2             ; 3C2E 1 208 180 CF02
                INC     X1                     ; 3C30 1 208 180 70
                INC     X1                     ; 3C31 1 208 180 70
vcal3_leanprotect_ratelimit_load_er0_2:     MOV     er0, #000ffh           ; 3C32 1 208 180 4498FF00
                CAL     vcal3_leanprotect_ratelimit_sub_load_er2             ; 3C36 1 208 180 323A59
                CAL     vcal3_leanprotect_ratelimit_sub_load_er2_2             ; 3C39 1 208 180 32955A
vcal3_leanprotect_ratelimit_load_x2_2:     L       A, X2                  ; 3C3C 1 208 180 41
                RB      off(0022fh).2          ; 3C3D 1 208 180 C42F0A
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit3             ; 3C40 1 208 180 CB79
vcal3_leanprotect_ratelimit_load_ram2ac_2:     LB      A, off(002ach)         ; 3C42 0 208 180 F4AC
                MOVB    r0, off(002adh)        ; 3C44 0 208 180 C4AD48
                MOV     er1, #00080h           ; 3C47 0 208 180 45988000
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_15          ; 3C4B 0 208 180 606866
                MOV     DP, #00316h            ; 3C4E 0 208 180 621603
                CMPB    off(002b2h), #003h     ; 3C51 0 208 180 C4B2C003
                JLE     vcal3_leanprotect_ratelimit_cmp_acc_25             ; 3C55 0 208 180 CF0E
                LB      A, off(002aeh)         ; 3C57 0 208 180 F4AE
                MOVB    r0, off(002afh)        ; 3C59 0 208 180 C4AF48
                MOV     er1, #00080h           ; 3C5C 0 208 180 45988000
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_16          ; 3C60 0 208 180 607766
                INC     DP                     ; 3C63 0 208 180 72
                INC     DP                     ; 3C64 0 208 180 72
vcal3_leanprotect_ratelimit_cmp_acc_25:     CMPB    A, 0d1h                ; 3C65 0 208 180 C5D1C2
                JGE     vcal3_leanprotect_ratelimit_load_er1             ; 3C68 0 208 180 CD0E
                MOV     er1, [DP]              ; 3C6A 0 208 180 B249
                LB      A, 0d1h                ; 3C6C 0 208 180 F5D1
                SUBB    A, r0                  ; 3C6E 0 208 180 28
                JLT     vcal3_leanprotect_ratelimit_load_er1             ; 3C6F 0 208 180 CA07
                VCAL    0                      ; 3C71 0 208 180 10
                ; warning: had to flip DD
                ADD     A, [DP]                ; 3C72 1 208 180 B282
                JLT     vcal3_leanprotect_ratelimit_load_imm_5             ; 3C74 1 208 180 CA08
                SJ      vcal3_leanprotect_ratelimit_cmp_acc_26             ; 3C76 1 208 180 CB01
vcal3_leanprotect_ratelimit_load_er1:     L       A, er1                 ; 3C78 1 208 180 35
vcal3_leanprotect_ratelimit_cmp_acc_26:     CMP     A, #00300h             ; 3C79 1 208 180 C60003
                JLT     vcal3_leanprotect_ratelimit_call_5b75             ; 3C7C 1 208 180 CA03
vcal3_leanprotect_ratelimit_load_imm_5:     L       A, #00300h             ; 3C7E 1 208 180 670003
vcal3_leanprotect_ratelimit_call_5b75:     CAL     vcal3_leanprotect_ratelimit_sub_cmp_acc             ; 3C81 1 208 180 32755B
                JBS     off(0022fh).2, vcal3_leanprotect_ratelimit_store_ram2a8_2 ; 3C84 1 208 180 EA2F11
                CMP     A, off(002a6h)         ; 3C87 1 208 180 C7A6
                MB      off(0022fh).2, C       ; 3C89 1 208 180 C42F3A
                JLT     vcal3_leanprotect_ratelimit_store_ram2a8_2             ; 3C8C 1 208 180 CA0A
                L       A, off(002a6h)         ; 3C8E 1 208 180 E4A6
                ADD     A, #00020h             ; 3C90 1 208 180 862000
                CAL     vcal3_leanprotect_ratelimit_sub_if_lt_goto_5b7a             ; 3C93 1 208 180 32735B
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit1             ; 3C96 1 208 180 CB20
vcal3_leanprotect_ratelimit_store_ram2a8_2:     ST      A, off(002a8h)         ; 3C98 1 208 180 D4A8
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit1             ; 3C9A 1 208 180 CB1C
vcal3_leanprotect_ratelimit_load_ram2a6:     L       A, off(002a6h)         ; 3C9C 1 208 180 E4A6
                ADD     A, er1                 ; 3C9E 1 208 180 09
                JLT     vcal3_leanprotect_ratelimit_load_imm_6             ; 3C9F 1 208 180 CA0A
                CMP     A, #003ffh             ; 3CA1 1 208 180 C6FF03
                JGE     vcal3_leanprotect_ratelimit_load_imm_6             ; 3CA4 1 208 180 CD05
                CMP     A, #003ffh             ; 3CA6 1 208 180 C6FF03
                JLT     vcal3_leanprotect_ratelimit_clear_ram22f_bit2             ; 3CA9 1 208 180 CA0A
vcal3_leanprotect_ratelimit_load_imm_6:     L       A, #003ffh             ; 3CAB 1 208 180 67FF03
                ST      A, off(002a8h)         ; 3CAE 1 208 180 D4A8
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit2             ; 3CB0 1 208 180 CB03
vcal3_leanprotect_ratelimit_clear_acc:     CLR     A                      ; 3CB2 1 208 180 F9
                ST      A, off(002a8h)         ; 3CB3 1 208 180 D4A8
vcal3_leanprotect_ratelimit_clear_ram22f_bit2:     RB      off(0022fh).2          ; 3CB5 1 208 180 C42F0A
vcal3_leanprotect_ratelimit_clear_ram22f_bit1:     RB      off(0022fh).1          ; 3CB8 1 208 180 C42F09
vcal3_leanprotect_ratelimit_clear_ram22f_bit3:     RB      off(0022fh).3          ; 3CBB 1 208 180 C42F0B
vcal3_leanprotect_ratelimit_store_ram2a6:     ST      A, off(002a6h)         ; 3CBE 1 208 180 D4A6
                CMP     A, #00023h             ; 3CC0 1 208 180 C62300
                JGE     vcal3_leanprotect_ratelimit_load_er0_3             ; 3CC3 1 208 180 CD01
                CLR     A                      ; 3CC5 1 208 180 F9
vcal3_leanprotect_ratelimit_load_er0_3:     MOV     er0, #00064h           ; 3CC6 1 208 180 44986400
                MUL                            ; 3CCA 1 208 180 9035
                MOV     er0, er1               ; 3CCC 1 208 180 4548
                MOV     er2, #003ffh           ; 3CCE 1 208 180 4698FF03
                DIV                            ; 3CD2 1 208 180 9037
                LB      A, ACC                 ; 3CD4 0 208 180 F506
                STB     A, 0e4h                ; 3CD6 0 208 180 D5E4
                RT                             ; 3CD8 0 208 180 01
vcal3_task_c_timers:     MOV     DP, #00012h            ; 3CD9 1 208 180 621200
                MOV     X1, #001dbh            ; 3CDC 1 208 180 60DB01
                CAL     decrement_timer_array             ; 3CDF 1 208 180 32C95B
                MOV     DP, #00026h            ; 3CE2 1 208 180 622600
                MOV     X1, #002cbh            ; 3CE5 1 208 180 60CB02
                CAL     decrement_timer_array             ; 3CE8 1 208 180 32C95B
                LB      A, 0f3h                ; 3CEB 0 208 180 F5F3
                ADDB    A, #001h               ; 3CED 0 208 180 8601
                JEQ     vcal3_task_c_msec_tick             ; 3CEF 0 208 180 C902
                STB     A, 0f3h                ; 3CF1 0 208 180 D5F3
vcal3_task_c_msec_tick:     CAL     selftest_reason_range_check             ; 3CF3 0 208 180 32D35C
                CLR     X1                     ; 3CF6 0 208 180 9015
                LB      A, 00399h[X1]          ; 3CF8 0 208 180 F09903
                JEQ     percyl_counter_gate             ; 3CFB 0 208 180 C914
                CMPB    off(002d0h), #000h     ; 3CFD 0 208 180 C4D0C000
                JNE     percyl_alt_check             ; 3D01 0 208 180 CE7D
                MOVB    r2, #010h              ; 3D03 0 208 180 9A10
                CMPB    A, r2                  ; 3D05 0 208 180 4A
                JGE     percyl_counter_check2             ; 3D06 0 208 180 CD02
                MOVB    r2, #001h              ; 3D08 0 208 180 9A01
percyl_counter_check2:     SUBB    A, r2                  ; 3D0A 0 208 180 2A
                MOV     er1, #01107h           ; 3D0B 0 208 180 45980711
                JNE     percyl_store_result             ; 3D0F 0 208 180 CE63
percyl_counter_gate:     SC                             ; 3D11 0 208 180 85
                JBS     off(00214h).7, tach_output_drive ; 3D12 0 208 180 EF147D
                CLR     A                      ; 3D15 1 208 180 F9
percyl_counter_loop:     LB      A, 0039ah[X1]          ; 3D16 0 208 180 F09A03
                STB     A, r0                  ; 3D19 0 208 180 88
                CMPB    A, #020h               ; 3D1A 0 208 180 C620
                JLT     percyl_counter_dp_select             ; 3D1C 0 208 180 CA10
                CLRB    0039ah[X1]             ; 3D1E 0 208 180 C09A0315
                LCB     A, idle_init_start_tbl            ; 3D22 0 208 180 909DFB60
                JEQ     tach_output_drive             ; 3D26 0 208 180 C96A
                LB      A, 0afh                ; 3D28 0 208 180 F5AF
                JEQ     tach_output_drive             ; 3D2A 0 208 180 C966
                SJ      percyl_bcd_convert             ; 3D2C 0 208 180 CB3C
percyl_counter_dp_select:     MOV     DP, #00321h            ; 3D2E 0 208 180 622103
                CMPB    A, #018h               ; 3D31 0 208 180 C618
                JGE     percyl_counter_increment             ; 3D33 0 208 180 CD09
                DEC     DP                     ; 3D35 0 208 180 82
                JBS     off(00208h).4, percyl_counter_increment ; 3D36 0 208 180 EC0805
                DEC     DP                     ; 3D39 0 208 180 82
                JBS     off(00208h).3, percyl_counter_increment ; 3D3A 0 208 180 EB0801
                DEC     DP                     ; 3D3D 0 208 180 82
percyl_counter_increment:     INCB    0039ah[X1]             ; 3D3E 0 208 180 C09A0316
                TRB     [DP]                   ; 3D42 0 208 180 C213 ; [H] mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C213
                JNE     percyl_wrap_check1             ; 3D44 0 208 180 CE0A
                LB      A, 0039ah[X1]          ; 3D46 0 208 180 F09A03
                ANDB    A, #007h               ; 3D49 0 208 180 D607
                RC                             ; 3D4B 0 208 180 95
                JNE     percyl_counter_loop             ; 3D4C 0 208 180 CEC8
                SJ      tach_output_drive             ; 3D4E 0 208 180 CB42
percyl_wrap_check1:     ADDB    A, #001h               ; 3D50 0 208 180 8601
                CMPB    A, #01dh               ; 3D52 0 208 180 C61D
                JNE     percyl_wrap_check2             ; 3D54 0 208 180 CE02
                LB      A, #02bh               ; 3D56 0 208 180 772B
percyl_wrap_check2:     CMPB    A, #01bh               ; 3D58 0 208 180 C61B
                JNE     percyl_wrap_check3             ; 3D5A 0 208 180 CE02
                LB      A, #029h               ; 3D5C 0 208 180 7729
percyl_wrap_check3:     CMPB    A, #01ah               ; 3D5E 0 208 180 C61A
                JNE     percyl_wrap_check4             ; 3D60 0 208 180 CE02
                LB      A, #024h               ; 3D62 0 208 180 7724
percyl_wrap_check4:     CMPB    A, #019h               ; 3D64 0 208 180 C619
                JNE     percyl_bcd_convert             ; 3D66 0 208 180 CE02
                LB      A, #023h               ; 3D68 0 208 180 7723
percyl_bcd_convert:     MOVB    r0, #00ah              ; 3D6A 0 208 180 980A
                DIVB                           ; 3D6C 0 208 180 A236
                SWAPB                          ; 3D6E 0 208 180 83
                ORB     A, r1                  ; 3D6F 0 208 180 69
                MOV     er1, #02b20h           ; 3D70 0 208 180 4598202B
percyl_store_result:     STB     A, 00399h[X1]          ; 3D74 0 208 180 D09903
                CMPB    A, #010h               ; 3D77 0 208 180 C610
                JLT     percyl_result_final             ; 3D79 0 208 180 CA02
                MOVB    r2, r3                 ; 3D7B 0 208 180 234A
percyl_result_final:     MOVB    off(002d0h), r2        ; 3D7D 0 208 180 227CD0
percyl_alt_check:     CMPB    A, #010h               ; 3D80 0 208 180 C610
                L       A, #00206h             ; 3D82 1 208 180 670602
                JLT     percyl_alt_store             ; 3D85 1 208 180 CA03
                L       A, #00311h             ; 3D87 1 208 180 671103
percyl_alt_store:     ST      A, er1                 ; 3D8A 1 208 180 89
                LB      A, off(002d0h)         ; 3D8B 0 208 180 F4D0
                CMPB    A, r2                  ; 3D8D 0 208 180 4A
                JGE     tach_output_drive             ; 3D8E 0 208 180 CD02
                CMPB    r3, A                  ; 3D90 0 208 180 23C1
tach_output_drive:     MB      P1.5, C                ; 3D92 0 208 180 C5223D
                JBR     off(00210h).7, tach_output_drive_if_ram227_bit3_clr ; 3D95 0 208 180 DF1019
                MOV     DP, #0031eh            ; 3D98 0 208 180 621E03
                L       A, [DP]                ; 3D9B 1 208 180 E2
                JNE     tach_output_drive_store_carry_p1_bit4             ; 3D9C 1 208 180 CE10
                INC     DP                     ; 3D9E 1 208 180 72
                INC     DP                     ; 3D9F 1 208 180 72
                L       A, [DP]                ; 3DA0 1 208 180 E2
                JNE     tach_output_drive_store_carry_p1_bit4             ; 3DA1 1 208 180 CE0B
                LCB     A, idle_init_start_tbl            ; 3DA3 1 208 180 909DFB60
                JEQ     tach_output_drive_set_carry             ; 3DA7 1 208 180 C904
                LB      A, 0afh                ; 3DA9 0 208 180 F5AF
                JNE     tach_output_drive_store_carry_p1_bit4             ; 3DAB 0 208 180 CE01
tach_output_drive_set_carry:     SC                             ; 3DAD 0 208 180 85
tach_output_drive_store_carry_p1_bit4:     MB      P1.4, C                ; 3DAE 0 208 180 C5223C
tach_output_drive_if_ram227_bit3_clr:     JBR     off(00227h).3, tach_output_return ; 3DB1 0 208 180 DB2745
                MOV     er2, 0ceh              ; 3DB4 0 208 180 B5CE4A
                MOV     er0, #00021h           ; 3DB7 0 208 180 44982100
                L       A, #0af7ah             ; 3DBB 1 208 180 677AAF
                DIV                            ; 3DBE 1 208 180 9037
                CMP     er0, #00000h           ; 3DC0 1 208 180 44C00000
                JEQ     tach_output_drive_load_dp             ; 3DC4 1 208 180 C903
                L       A, #0ffffh             ; 3DC6 1 208 180 67FFFF
tach_output_drive_load_dp:     MOV     DP, #00390h            ; 3DC9 1 208 180 629003
                XCHG    A, [DP]                ; 3DCC 1 208 180 B210
                SUB     A, [DP]                ; 3DCE 1 208 180 B2A2
                JGE     tach_output_drive_cmp_acch             ; 3DD0 1 208 180 CD01
                VCAL    7                      ; 3DD2 1 208 180 17
tach_output_drive_cmp_acch:     CMPB    ACCH, #000h            ; 3DD3 1 208 180 C507C000
                JEQ     tach_output_drive_load_dp_2             ; 3DD7 1 208 180 C902
                LB      A, #0ffh               ; 3DD9 0 208 180 77FF
tach_output_drive_load_dp_2:     MOV     DP, #0038dh            ; 3DDB 0 208 180 628D03
                MOVB    [DP], A                ; 3DDE 0 208 180 C28A
                MOV     DP, #0038ch            ; 3DE0 0 208 180 628C03
                LB      A, 0cch                ; 3DE3 0 208 180 F5CC
                JNE     tach_output_drive_cmp_acc             ; 3DE5 0 208 180 CE0D
                LB      A, [DP]                ; 3DE7 0 208 180 F2
                JEQ     tach_output_return             ; 3DE8 0 208 180 C90F
                MOVB    r6, #0ffh              ; 3DEA 0 208 180 9EFF
                CMPB    r6, A                  ; 3DEC 0 208 180 26C1
                MB      off(00226h).6, C       ; 3DEE 0 208 180 C4263E
                CLRB    A                      ; 3DF1 0 208 180 FA
                SJ      tach_output_drive_store_dp_ind             ; 3DF2 0 208 180 CB04
tach_output_drive_cmp_acc:     CMPB    A, [DP]                ; 3DF4 0 208 180 C2C2
                JLT     tach_output_return             ; 3DF6 0 208 180 CA01
tach_output_drive_store_dp_ind:     STB     A, [DP]                ; 3DF8 0 208 180 D2
tach_output_return:     RT                             ; 3DF9 0 208 180 01
vcal3_task_b_body:     MOV     DP, #00002h            ; 3DFA 1 208 180 620200
                MOV     X1, #001cdh            ; 3DFD 1 208 180 60CD01
                CAL     decrement_timer_array             ; 3E00 1 208 180 32C95B
                MOV     DP, #00009h            ; 3E03 1 208 180 620900
                MOV     X1, #002b5h            ; 3E06 1 208 180 60B502
                CAL     decrement_timer_array             ; 3E09 1 208 180 32C95B
                LB      A, 0f2h                ; 3E0C 0 208 180 F5F2
                ADDB    A, #001h               ; 3E0E 0 208 180 8601
                JEQ     vcal3_task_b_body_if_ram216_bit1_clr             ; 3E10 0 208 180 C902
                STB     A, 0f2h                ; 3E12 0 208 180 D5F2
vcal3_task_b_body_if_ram216_bit1_clr:     JBR     off(00216h).1, learn_table1_check ; 3E14 0 208 180 D91612
                LB      A, #006h               ; 3E17 0 208 180 7706
                CMPB    A, (001cah-00180h)[USP] ; 3E19 0 208 180 C34AC2
                JLE     vcal3_task_b_body_cmp_acc             ; 3E1C 0 208 180 CF03
                INCB    (001cah-00180h)[USP]   ; 3E1E 0 208 180 C34A16
vcal3_task_b_body_cmp_acc:     CMPB    A, (001c9h-00180h)[USP] ; 3E21 0 208 180 C349C2
                JLE     learn_table1_check             ; 3E24 0 208 180 CF03
                INCB    (001c9h-00180h)[USP]   ; 3E26 0 208 180 C34916
learn_table1_check:     LB      A, off(002bbh)         ; 3E29 0 208 180 F4BB
                JNE     learn_table2_check             ; 3E2B 0 208 180 CE29
                MOVB    off(002bbh), #002h     ; 3E2D 0 208 180 C4BB9802
                MOV     X1, #tbl_diag_snapshot_data2          ; 3E31 0 208 180 60956F
                MOV     DP, #001b3h            ; 3E34 0 208 180 62B301
                MOVB    r6, #027h              ; 3E37 0 208 180 9E27
learn_table1_loop:     LB      A, [DP]                ; 3E39 0 208 180 F2
                ADDB    A, #001h               ; 3E3A 0 208 180 8601
                JLT     learn_table1_reset_entry             ; 3E3C 0 208 180 CA04
                CMPCB   A, [X1]                ; 3E3E 0 208 180 90AE
                JLT     learn_table1_store             ; 3E40 0 208 180 CA02
learn_table1_reset_entry:     LCB     A, [X1]                ; 3E42 0 208 180 90AA
learn_table1_store:     STB     A, [DP]                ; 3E44 0 208 180 D2
                LB      A, r6                  ; 3E45 0 208 180 7E
                SUBB    A, 0f4h                ; 3E46 0 208 180 C5F4A2
                JNE     learn_table1_advance             ; 3E49 0 208 180 CE02
                STB     A, 0f4h                ; 3E4B 0 208 180 D5F4
learn_table1_advance:     INC     X1                     ; 3E4D 0 208 180 70
                INC     DP                     ; 3E4E 0 208 180 72
                INCB    r6                     ; 3E4F 0 208 180 AE
                CMP     DP, #001b7h            ; 3E50 0 208 180 92C0B701
                JLE     learn_table1_loop             ; 3E54 0 208 180 CFE3
learn_table2_check:     LB      A, off(002bch)         ; 3E56 0 208 180 F4BC
                JNE     vcal3_task_a_return             ; 3E58 0 208 180 CE26
                MOVB    off(002bch), #002h     ; 3E5A 0 208 180 C4BC9802
                LB      A, #001h               ; 3E5E 0 208 180 7701
                MB      C, 0b7h.1              ; 3E60 0 208 180 C5B729
                JLT     learn_counter_store             ; 3E63 0 208 180 CA0A
                LB      A, 0f7h                ; 3E65 0 208 180 F5F7
                ADDB    A, #001h               ; 3E67 0 208 180 8601
                CMPB    A, #020h               ; 3E69 0 208 180 C620
                JLT     learn_counter_store             ; 3E6B 0 208 180 CA02
                LB      A, #020h               ; 3E6D 0 208 180 7720
learn_counter_store:     STB     A, 0f7h                ; 3E6F 0 208 180 D5F7
                LB      A, 0f6h                ; 3E71 0 208 180 F5F6
                ADDB    A, #001h               ; 3E73 0 208 180 8601
                CMPB    A, #020h               ; 3E75 0 208 180 C620
                JLT     learn_retry_store             ; 3E77 0 208 180 CA05
                RB      0b7h.1                 ; 3E79 0 208 180 C5B709
                LB      A, #020h               ; 3E7C 0 208 180 7720
learn_retry_store:     STB     A, 0f6h                ; 3E7E 0 208 180 D5F6
vcal3_task_a_return:     RT                             ; 3E80 0 208 180 01
regbank_selftest2_start:     L       A, #02babh             ; 3E81 1 208 180 67AB2B
                MOV     X1, #002a0h            ; 3E84 1 208 180 60A002
                JBR     off(00217h).2, regbank_selftest2_ie_check ; 3E87 1 208 180 DA1706
                L       A, #0a9a3h             ; 3E8A 1 208 180 67A3A9
                MOV     X1, #000a0h            ; 3E8D 1 208 180 60A000
regbank_selftest2_ie_check:     CMP     A, 0f8h                ; 3E90 1 208 180 B5F8C2
                JNE     selftest_fail_04f             ; 3E93 1 208 180 CE0B
                CMP     A, IE                  ; 3E95 1 208 180 B51AC2
                JNE     selftest_fail_04f             ; 3E98 1 208 180 CE06
                L       A, X1                  ; 3E9A 1 208 180 40
                CMP     A, 0fah                ; 3E9B 1 208 180 B5FAC2
                JEQ     regbank_selftest2_range_check             ; 3E9E 1 208 180 C907
selftest_fail_04f:     MOVB    0f5h, #04fh            ; 3EA0 1 208 180 C5F5984F
                J       fault_retry_check             ; 3EA4 1 208 180 03E024
regbank_selftest2_range_check:     MOV     DP, #00394h            ; 3EA7 1 208 180 629403
                L       A, [DP]                ; 3EAA 1 208 180 E2
                CMP     A, #003fah             ; 3EAB 1 208 180 C6FA03
                JGT     regbank_selftest2_default             ; 3EAE 1 208 180 C832
                MOV     X1, A                  ; 3EB0 1 208 180 50
                MOV     DP, 00084h[X1]         ; 3EB1 1 208 180 B084007A
                L       A, #05555h             ; 3EB5 1 208 180 675555
                CAL     selftest_regbank_verify             ; 3EB8 1 208 180 325C5C
                SLL     A                      ; 3EBB 1 208 180 53
                CAL     selftest_regbank_verify             ; 3EBC 1 208 180 325C5C
                L       A, X1                  ; 3EBF 1 208 180 40
                SUB     A, #00002h             ; 3EC0 1 208 180 A60200
                JGE     irqmode_dispatch             ; 3EC3 1 208 180 CD20
                L       A, #05555h             ; 3EC5 1 208 180 675555
                MOV     X1, A                  ; 3EC8 1 208 180 50
                CMP     A, X1                  ; 3EC9 1 208 180 90C2
                JNE     selftest_fail_042_alt             ; 3ECB 1 208 180 CE0B
                MOV     X2, A                  ; 3ECD 1 208 180 51
                CMP     A, X2                  ; 3ECE 1 208 180 91C2
                JNE     selftest_fail_042_alt             ; 3ED0 1 208 180 CE06
                SLL     A                      ; 3ED2 1 208 180 53
                MOV     X1, A                  ; 3ED3 1 208 180 50
                CMP     A, X1                  ; 3ED4 1 208 180 90C2
                JEQ     regbank_selftest2_check3             ; 3ED6 1 208 180 C905
selftest_fail_042_alt:     MOVB    0f5h, #042h            ; 3ED8 1 208 180 C5F59842
                BRK                            ; 3EDC 1 208 180 FF
regbank_selftest2_check3:     MOV     X2, A                  ; 3EDD 1 208 180 51
                CMP     A, X2                  ; 3EDE 1 208 180 91C2
                JNE     selftest_fail_042_alt             ; 3EE0 1 208 180 CEF6
regbank_selftest2_default:     L       A, #003fah             ; 3EE2 1 208 180 67FA03
irqmode_dispatch:     MOV     DP, #00394h            ; 3EE5 1 208 180 629403
; [H] --- Interrupt-priority/mode switch: calls VCAL 3 (the scheduler), then based on off(00212h).3
; [H] and off(00217h).2 flags, reprograms IE and its shadow bytes (0xFA/0xF8) to one of two
; [H] distinct bitmasks (0x2BAF/0xA9A7 -- likely "engine running" vs "cranking/idle" interrupt
; [H] priority sets), plus TCON3 bits. Distinct from the register self-test above despite similar
; [H] surrounding code shape.
                ST      A, [DP]                ; 3EE8 1 208 180 D2
                VCAL    3                      ; 3EE9 1 208 180 13
                L       A, 0fah                ; 3EEA 1 208 180 E5FA
                ST      A, IE                  ; 3EEC 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 3EEE 1 208 180 A2D0FE
                JBS     off(00212h).3, irqmode_select_b ; 3EF1 1 208 180 EB122E
                JBS     off(00217h).2, irqmode_check1 ; 3EF4 1 208 180 EA170B
                RB      IRQH.7                 ; 3EF7 1 208 180 C5190F
                JEQ     irqmode_check1             ; 3EFA 1 208 180 C906
                SB      0b6h.7                 ; 3EFC 1 208 180 C5B61F
dtc04_ckp_latch_2: SB      0b4h.0                 ; 3EFF 1 208 180 C5B418
irqmode_check1:     ORB     PSWH, #001h            ; 3F02 1 208 180 A2E001
                CMPB    (001adh-00180h)[USP], #029h ; 3F05 1 208 180 C32DC029
                ANDB    PSWH, #0feh            ; 3F09 1 208 180 A2D0FE
                JLT     irqmode_select_b             ; 3F0C 1 208 180 CA14
                JBR     off(00217h).2, irqmode_done ; 3F0E 1 208 180 DA172F
                L       A, #02babh             ; 3F11 1 208 180 67AB2B
                ST      A, IE                  ; 3F14 1 208 180 D51A
                ST      A, 0f8h                ; 3F16 1 208 180 D5F8
                MOV     0fah, #002a0h          ; 3F18 1 208 180 B5FA98A002
                RB      off(00217h).2          ; 3F1D 1 208 180 C4170A
                SJ      irqmode_done             ; 3F20 1 208 180 CB1E
irqmode_select_b:     JBS     off(00217h).2, irqmode_done ; 3F22 1 208 180 EA171B
                L       A, #0a9a3h             ; 3F25 1 208 180 67A3A9
                ST      A, IE                  ; 3F28 1 208 180 D51A
                ST      A, 0f8h                ; 3F2A 1 208 180 D5F8
                MOV     0fah, #000a0h          ; 3F2C 1 208 180 B5FA98A000
                SB      off(00217h).2          ; 3F31 1 208 180 C4171A
                RB      (00125h-00180h)[USP].7 ; 3F34 1 208 180 C3A50F
                RB      off(0021dh).7          ; 3F37 1 208 180 C41D0F
                SB      TCON3.3                ; 3F3A 1 208 180 C5431B
                SB      TCON3.2                ; 3F3D 1 208 180 C5431A
irqmode_done:     ORB     PSWH, #001h            ; 3F40 1 208 180 A2E001
                L       A, 0f8h                ; 3F43 1 208 180 E5F8
                ST      A, IE                  ; 3F45 1 208 180 D51A
stack_sanity_check:     CMP     SSP, #0047eh           ; 3F47 1 208 180 A0C07E04
; [H] --- Post-init peripheral verification: re-reads SSP, LRB, every port direction/special-
; [H] function register, all four timer control regs, PWM control regs, A/D select/scan, and the
; [H] diagnostic-serial baud/control regs, comparing each against the exact values int_break's
; [H] init sequence (0x235F periph_init_start onward) programmed them to. Any mismatch -> stamps
; [H] trapReasonCode=0x50 (selftest_fail_050) and BRKs, forcing a full re-init retry. This is a
; [H] "did my own initialization actually stick" check, not a fresh self-test of new hardware.
                JNE     selftest_fail_050             ; 3F4B 1 208 180 CE64
                MOV     DP, #00400h            ; 3F4D 1 208 180 620004
                L       A, [DP]                ; 3F50 1 208 180 E2
                JNE     selftest_fail_050             ; 3F51 1 208 180 CE5E
                L       A, PSW                 ; 3F53 1 208 180 E504
                AND     A, #01107h             ; 3F55 1 208 180 D60711
                CMP     A, #01100h             ; 3F58 1 208 180 C60011
                JNE     selftest_fail_050             ; 3F5B 1 208 180 CE54
                CMP     LRB, #00041h           ; 3F5D 1 208 180 A4C04100
                JNE     selftest_fail_050             ; 3F61 1 208 180 CE4E
                CMPB    P0IO, #0ffh            ; 3F63 1 208 180 C521C0FF
                JNE     selftest_fail_050             ; 3F67 1 208 180 CE48
                CMPB    P1IO, #0ffh            ; 3F69 1 208 180 C523C0FF
                JNE     selftest_fail_050             ; 3F6D 1 208 180 CE42
                CMPB    P2IO, #0ffh            ; 3F6F 1 208 180 C525C0FF
                JNE     selftest_fail_050             ; 3F73 1 208 180 CE3C
                CMPB    P2SF, #007h            ; 3F75 1 208 180 C526C007
                JNE     selftest_fail_050             ; 3F79 1 208 180 CE36
                CMPB    P3IO, #0b1h            ; 3F7B 1 208 180 C529C0B1
                JNE     selftest_fail_050             ; 3F7F 1 208 180 CE30
                CMPB    P3SF, #0ffh            ; 3F81 1 208 180 C52AC0FF
                JNE     selftest_fail_050             ; 3F85 1 208 180 CE2A
                CMPB    P4IO, #00dh            ; 3F87 1 208 180 C52DC00D
                JNE     selftest_fail_050             ; 3F8B 1 208 180 CE24
                CMPB    P4SF, #0f4h            ; 3F8D 1 208 180 C52EC0F4
                JNE     selftest_fail_050             ; 3F91 1 208 180 CE1E
                LB      A, TCON0               ; 3F93 0 208 180 F540
                MOVB    r0, #0f3h              ; 3F95 0 208 180 98F3
                ANDB    A, r0                  ; 3F97 0 208 180 58
                CMPB    A, #093h               ; 3F98 0 208 180 C693
                JNE     selftest_fail_050             ; 3F9A 0 208 180 CE15
                LB      A, TCON1               ; 3F9C 0 208 180 F541
                ANDB    A, r0                  ; 3F9E 0 208 180 58
                CMPB    A, #053h               ; 3F9F 0 208 180 C653
                JNE     selftest_fail_050             ; 3FA1 0 208 180 CE0E
                LB      A, TCON2               ; 3FA3 0 208 180 F542
                ANDB    A, r0                  ; 3FA5 0 208 180 58
                CMPB    A, #092h               ; 3FA6 0 208 180 C692
                JNE     selftest_fail_050             ; 3FA8 0 208 180 CE07
                LB      A, TCON3               ; 3FAA 0 208 180 F543
                ANDB    A, r0                  ; 3FAC 0 208 180 58
                CMPB    A, #093h               ; 3FAD 0 208 180 C693
                JEQ     periph_init_verify_pwm_adc             ; 3FAF 0 208 180 C905
selftest_fail_050:     MOVB    0f5h, #050h            ; 3FB1 0 208 180 C5F59850
                BRK                            ; 3FB5 0 208 180 FF
periph_init_verify_pwm_adc:     LB      A, PWCON0              ; 3FB6 0 208 180 F578
                ANDB    A, #07bh               ; 3FB8 0 208 180 D67B
                CMPB    A, #03ah               ; 3FBA 0 208 180 C63A
                JNE     selftest_fail_050             ; 3FBC 0 208 180 CEF3
                LB      A, PWCON1              ; 3FBE 0 208 180 F57A
                ANDB    A, #07bh               ; 3FC0 0 208 180 D67B
                CMPB    A, #07ah               ; 3FC2 0 208 180 C67A
                JNE     selftest_fail_050             ; 3FC4 0 208 180 CEEB
                LB      A, ADSEL               ; 3FC6 0 208 180 F559
                ANDB    A, #05fh               ; 3FC8 0 208 180 D65F
                JNE     selftest_fail_050             ; 3FCA 0 208 180 CEE5
                LB      A, ADSCAN              ; 3FCC 0 208 180 F558
                ANDB    A, #05fh               ; 3FCE 0 208 180 D65F
                CMPB    A, #010h               ; 3FD0 0 208 180 C610
                JNE     selftest_fail_050             ; 3FD2 0 208 180 CEDD
                MOV     DP, #00356h            ; 3FD4 0 208 180 625603
                MB      C, [DP].1              ; 3FD7 0 208 180 C229
                JGE     periph_init_verify_done             ; 3FD9 0 208 180 CD1C
                LB      A, STTMC               ; 3FDB 0 208 180 F54A
                ANDB    A, #0f3h               ; 3FDD 0 208 180 D6F3
                CMPB    A, #012h               ; 3FDF 0 208 180 C612
                JNE     selftest_fail_050             ; 3FE1 0 208 180 CECE
                LB      A, STCON               ; 3FE3 0 208 180 F550
                ANDB    A, #07fh               ; 3FE5 0 208 180 D67F
                CMPB    A, #01ch               ; 3FE7 0 208 180 C61C
                JNE     selftest_fail_050             ; 3FE9 0 208 180 CEC6
                CMPB    SRCON, #08ch           ; 3FEB 0 208 180 C554C08C
                JNE     selftest_fail_050             ; 3FEF 0 208 180 CEC0
                CMPB    STTMR, #0dfh           ; 3FF1 0 208 180 C549C0DF
                JNE     selftest_fail_050             ; 3FF5 0 208 180 CEBA
periph_init_verify_done:     L       A, 0fah                ; 3FF7 1 208 180 E5FA
                ST      A, IE                  ; 3FF9 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 3FFB 1 208 180 A2D0FE
                MOV     er0, TM0               ; 3FFE 1 208 180 B53048
                MOV     er1, TM1               ; 4001 1 208 180 B53449
                MOV     er2, TM2               ; 4004 1 208 180 B5384A
                MOV     er3, TM3               ; 4007 1 208 180 B53C4B
                ORB     PSWH, #001h            ; 400A 1 208 180 A2E001
                NOP                            ; 400D 1 208 180 00
                ANDB    PSWH, #0feh            ; 400E 1 208 180 A2D0FE
                MOV     X1, TM0                ; 4011 1 208 180 B53078
                MOV     X2, TM1                ; 4014 1 208 180 B53479
                MOV     DP, TM2                ; 4017 1 208 180 B5387A
                ORB     PSWH, #001h            ; 401A 1 208 180 A2E001
                L       A, 0f8h                ; 401D 1 208 180 E5F8
                ST      A, IE                  ; 401F 1 208 180 D51A
                L       A, X1                  ; 4021 1 208 180 40
; [H] --- Oscillator/timer cross-check: snapshots TM0/TM1/TM2 into X1/X2/DP, re-enables
; [H] interrupts briefly (IE/PSWH toggling), re-snapshots into er0/er1/er2, then verifies the
; [H] deltas fall within expected ranges (0x22, 0x80, 0x22, a ratio check against er1>>2) --
; [H] confirms the timers are actually counting at the rate the code expects (i.e. the clock
; [H] source/oscillator is running correctly) before trusting any timing-dependent logic
; [H] (ignition/injection scheduling) downstream. Out-of-range -> selftest_fail_04b.
                SUB     A, er0                 ; 4022 1 208 180 28
                ST      A, er0                 ; 4023 1 208 180 88
                JEQ     selftest_fail_04b             ; 4024 1 208 180 C93D
                CMP     A, #00022h             ; 4026 1 208 180 C62200
                JGE     selftest_fail_04b             ; 4029 1 208 180 CD38
                L       A, X2                  ; 402B 1 208 180 41
                SUB     A, er1                 ; 402C 1 208 180 29
                ST      A, er1                 ; 402D 1 208 180 89
                JEQ     selftest_fail_04b             ; 402E 1 208 180 C933
                CMP     A, #00080h             ; 4030 1 208 180 C68000
                JGE     selftest_fail_04b             ; 4033 1 208 180 CD2E
                L       A, DP                  ; 4035 1 208 180 42
                SUB     A, er2                 ; 4036 1 208 180 2A
                MOV     X2, A                  ; 4037 1 208 180 51
                JEQ     selftest_fail_04b             ; 4038 1 208 180 C929
                CMP     A, #00022h             ; 403A 1 208 180 C62200
                JGE     selftest_fail_04b             ; 403D 1 208 180 CD24
                L       A, er3                 ; 403F 1 208 180 37
                SUB     A, er2                 ; 4040 1 208 180 2A
                MB      C, ACCH.7              ; 4041 1 208 180 C5072F
                JGE     clock_selftest_check2             ; 4044 1 208 180 CD01
                VCAL    7                      ; 4046 1 208 180 17
clock_selftest_check2:     CMP     A, #00002h             ; 4047 1 208 180 C60200
                JGE     selftest_fail_04b             ; 404A 1 208 180 CD17
                L       A, er1                 ; 404C 1 208 180 35
                SRL     A                      ; 404D 1 208 180 63
                SRL     A                      ; 404E 1 208 180 63
                SUB     A, X2                  ; 404F 1 208 180 91A2
                JGE     clock_selftest_check3             ; 4051 1 208 180 CD01
                VCAL    7                      ; 4053 1 208 180 17
clock_selftest_check3:     CMP     A, #00002h             ; 4054 1 208 180 C60200
                JGE     selftest_fail_04b             ; 4057 1 208 180 CD0A
                L       A, X2                  ; 4059 1 208 180 41
                SUB     A, er0                 ; 405A 1 208 180 28
                JGE     clock_selftest_check4             ; 405B 1 208 180 CD01
                VCAL    7                      ; 405D 1 208 180 17
clock_selftest_check4:     CMP     A, #00002h             ; 405E 1 208 180 C60200
                JLT     clock_selftest_passed             ; 4061 1 208 180 CA05
selftest_fail_04b:     MOVB    0f5h, #04bh            ; 4063 1 208 180 C5F5984B
                BRK                            ; 4067 1 208 180 FF
clock_selftest_passed:     VCAL    3                      ; 4068 1 208 180 13
                CAL     boot_completion_helper             ; 4069 1 208 180 32455F
                MOVB    r0, #001h              ; 406C 1 208 180 9801
                JBR     off(00217h).2, warmcold_ie_setup ; 406E 1 208 180 DA1702
                MOVB    r0, #006h              ; 4071 1 208 180 9806
warmcold_ie_setup:     L       A, 0fah                ; 4073 1 208 180 E5FA
; [H] COLD vs WARM RESTART FORK (0x3480-0x353C+): this is the transition point flagged much
; [H] earlier in this file as needing dedicated tracing -- now traced. warmcold_tm2_check compares
; [H] the current TM2 reading against a saved value (0xAE/0xEE) to detect whether the engine
; [H] appears to still be running/turning (a brief ECU reset while cranking) vs a genuine cold
; [H] power-up:
; [H] - coldstart_full_reset (warm check failed -> true cold start): zeroes currentRPMByte, the
; [H] ignition/injector hardware timer-prep registers (0x360-0x372, 0x3A6, 0x357/0x358/0x35D/
; [H] 0x35E), VTEC/mode flags (0x124/0x126/0x127/0x128/0x21C/0x21E/0x21F/0x221/0x232), and
; [H] drives P4.0/P1 low -- a full reset of all per-cycle working state built up over this
; [H] session's traced routines.
; [H] - warmrestart_path/warmrestart_tm3_resync (warm check passed -> engine still turning):
; [H] skips the reset entirely, just resyncs TM3 -- preserves ignition/fuel/VTEC state across
; [H] the brief reset instead of losing sync with a spinning engine.
                ST      A, IE                  ; 4075 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 4077 1 208 180 A2D0FE
                RB      off(00231h).5          ; 407A 1 208 180 C4310D
                JBR     off(00217h).4, warmcold_tm2_check ; 407D 1 208 180 DC1703
                J       warmrestart_tm3_resync             ; 4080 1 208 180 032C41
warmcold_tm2_check:     JNE     coldstart_full_reset             ; 4083 1 208 180 CE12
                LB      A, r0                  ; 4085 0 208 180 78
                CMPB    A, 0aeh                ; 4086 0 208 180 C5AEC2
                JLT     coldstart_full_reset             ; 4089 0 208 180 CA0C
                JNE     warmrestart_path             ; 408B 0 208 180 CE07
                L       A, TM2                 ; 408D 1 208 180 E538
                CMP     A, 0eeh                ; 408F 1 208 180 B5EEC2
                JGE     coldstart_full_reset             ; 4092 1 208 180 CD03
warmrestart_path:     J       warmcold_reconverge             ; 4094 1 208 180 033341
coldstart_full_reset:     SB      off(00217h).4          ; 4097 1 208 180 C4171C
                CLRB    A                      ; 409A 0 208 180 FA
                MOVB    0a2h, #002h            ; 409B 0 208 180 C5A29802
                STB     A, 0a3h                ; 409F 0 208 180 D5A3
                MOVB    (00134h-00180h)[USP], #005h ; 40A1 0 208 180 C3B49805
                STB     A, (00135h-00180h)[USP] ; 40A5 0 208 180 D3B5
                MOVB    (0013dh-00180h)[USP], #004h ; 40A7 0 208 180 C3BD9804
                CLR     A                      ; 40AB 1 208 180 F9
                MOV     X1, A                  ; 40AC 1 208 180 50
                ST      A, 00360h[X1]          ; 40AD 1 208 180 D06003
                ST      A, 00362h[X1]          ; 40B0 1 208 180 D06203
                ST      A, 00364h[X1]          ; 40B3 1 208 180 D06403
                ST      A, 00366h[X1]          ; 40B6 1 208 180 D06603
                ST      A, 00368h[X1]          ; 40B9 1 208 180 D06803
                ST      A, 0036ah[X1]          ; 40BC 1 208 180 D06A03
                ST      A, off(00268h)         ; 40BF 1 208 180 D468
                J       coldstart_full_reset_store_tbl_x1_2             ; 40C1 1 208 180 03AF7C
coldstart_full_reset_store_tbl_x1:     ST      A, 0036ch[X1]          ; 40C4 1 208 180 D06C03
                ST      A, 0036eh[X1]          ; 40C7 1 208 180 D06E03
                ST      A, 00370h[X1]          ; 40CA 1 208 180 D07003
                ST      A, 0c4h                ; 40CD 1 208 180 D5C4
                CLRB    A                      ; 40CF 0 208 180 FA
                STB     A, off(00238h)         ; 40D0 0 208 180 D438
                STB     A, (00133h-00180h)[USP] ; 40D2 0 208 180 D3B3
                STB     A, 0c3h                ; 40D4 0 208 180 D5C3
                STB     A, off(0029fh)         ; 40D6 0 208 180 D49F
                J       coldstart_full_reset_store_stk             ; 40D8 0 208 180 03FC7B
coldstart_full_reset_orb_tcon3:     ORB     TCON3, #00ch           ; 40DB 0 208 180 C543E00C
                SB      (00126h-00180h)[USP].0 ; 40DF 0 208 180 C3A618
                MOVB    0a0h, #004h            ; 40E2 0 208 180 C5A09804
                SB      (0012ah-00180h)[USP].5 ; 40E6 0 208 180 C3AA1D
                L       A, #0ffffh             ; 40E9 1 208 180 67FFFF
                ST      A, 0a4h                ; 40EC 1 208 180 D5A4
                ST      A, 0e8h                ; 40EE 1 208 180 D5E8
                L       A, #0ff04h             ; 40F0 1 208 180 6704FF
                ST      A, 00358h[X1]          ; 40F3 1 208 180 D05803
                ST      A, 0035eh[X1]          ; 40F6 1 208 180 D05E03
                LB      A, #0ffh               ; 40F9 0 208 180 77FF
                STB     A, 00357h[X1]          ; 40FB 0 208 180 D05703
                STB     A, 0035dh[X1]          ; 40FE 0 208 180 D05D03
                ORB     0b8h, #003h            ; 4101 0 208 180 C5B8E003
                RB      off(00221h).7          ; 4105 0 208 180 C4210F
                ANDB    P1, #0fch              ; 4108 0 208 180 C522D0FC
                ANDB    (00127h-00180h)[USP], #0f9h ; 410C 0 208 180 C3A7D0F9
                ANDB    off(0021fh), #0f9h     ; 4110 0 208 180 C41FD0F9
                J       coldstart_full_reset_clear_ram232_bit7             ; 4114 0 208 180 039E7C
coldstart_full_reset_clear_stk:     RB      (00126h-00180h)[USP].4 ; 4117 0 208 180 C3A60C
                RB      off(0021eh).4          ; 411A 0 208 180 C41E0C
                CLR     A                      ; 411D 1 208 180 F9
                ST      A, (00128h-00180h)[USP] ; 411E 1 208 180 D3A8
                ST      A, (00124h-00180h)[USP] ; 4120 1 208 180 D3A4
                ST      A, off(0021ch)         ; 4122 1 208 180 D41C
                ST      A, (001a2h-00180h)[USP] ; 4124 1 208 180 D322
                ST      A, (001a0h-00180h)[USP] ; 4126 1 208 180 D320
                ST      A, 0ech                ; 4128 1 208 180 D5EC
                ST      A, 0eah                ; 412A 1 208 180 D5EA
warmrestart_tm3_resync:     L       A, TM3                 ; 412C 1 208 180 E53C
                SUB     A, #00001h             ; 412E 1 208 180 A60100
                ST      A, TMR3                ; 4131 1 208 180 D53E
warmcold_reconverge:     ORB     PSWH, #001h            ; 4133 1 208 180 A2E001
                L       A, 0f8h                ; 4136 1 208 180 E5F8
                ST      A, IE                  ; 4138 1 208 180 D51A
                SC                             ; 413A 1 208 180 85
                JBS     off(00217h).4, warmcold_deg_flag ; 413B 1 208 180 EC1710
                JBS     off(00211h).0, warmcold_deg_select ; 413E 1 208 180 E81103
                JBR     off(00217h).5, warmcold_deg_flag_load_stk ; 4141 1 208 180 DD171D
warmcold_deg_select:     LB      A, #012h               ; 4144 0 208 180 7712
                JBS     off(00217h).5, warmcold_deg_check ; 4146 0 208 180 ED1702
                LB      A, #01dh               ; 4149 0 208 180 771D
warmcold_deg_check:     CMPB    A, 0c5h                ; 414B 0 208 180 C5C5C2
warmcold_deg_flag:     MB      off(00217h).5, C       ; 414E 0 208 180 C4173D
                JGE     warmcold_deg_flag_load_stk             ; 4151 0 208 180 CD0E
                JBR     off(00211h).0, warmcold_msec_reset ; 4153 0 208 180 D81103
                SB      off(00230h).4          ; 4156 0 208 180 C4301C
warmcold_msec_reset:     CLRB    A                      ; 4159 0 208 180 FA
                STB     A, 0f3h                ; 415A 0 208 180 D5F3
                STB     A, 0f2h                ; 415C 0 208 180 D5F2
                JBR     off(00217h).4, warmcold_deg_flag_vcal_3 ; 415E 0 208 180 DC1704
warmcold_deg_flag_load_stk:     MOVB    (001e7h-00180h)[USP], #063h ; 4161 0 208 180 C3679863
warmcold_deg_flag_vcal_3:     VCAL    3                      ; 4165 0 208 180 13
                CLR     X1                     ; 4166 0 208 180 9015
                LB      A, 003f9h[X1]          ; 4168 0 208 180 F0F903
                JNE     tps_learn_alt_path             ; 416B 0 208 180 CE56
                MOVB    003f9h[X1], #006h      ; 416D 0 208 180 C0F9039806
                LB      A, #0fah               ; 4172 0 208 180 77FA
                JBS     off(00217h).4, warmcold_deg_flag_store_tbl_x1 ; 4174 0 208 180 EC1749
                STB     A, r0                  ; 4177 0 208 180 88
                LB      A, #07bh               ; 4178 0 208 180 777B
                STB     A, r1                  ; 417A 0 208 180 89
                STB     A, r2                  ; 417B 0 208 180 8A
                JBS     off(0021ah).1, warmcold_deg_flag_load_r0 ; 417C 0 208 180 E91A2D
                JBS     off(0021ah).2, warmcold_deg_flag_load_r0 ; 417F 0 208 180 EA1A2A
                LB      A, 0d4h                ; 4182 0 208 180 F5D4
                CMPB    A, r1                  ; 4184 0 208 180 49
                JGE     warmcold_deg_flag_load_r0             ; 4185 0 208 180 CD25
                STB     A, r1                  ; 4187 0 208 180 89
                MOVB    r3, 00378h[X1]         ; 4188 0 208 180 C078034B
                SUBB    A, r3                  ; 418C 0 208 180 2B
                JLT     warmcold_deg_flag_load_tbl_x1             ; 418D 0 208 180 CA16
                CMPB    A, #004h               ; 418F 0 208 180 C604
                JGE     warmcold_deg_flag_load_r0             ; 4191 0 208 180 CD19
                SUBB    00377h[X1], #001h      ; 4193 0 208 180 C07703A001
                JNE     warmcold_deg_flag_load_tbl_x1_2             ; 4198 0 208 180 CE1A
                LB      A, r3                  ; 419A 0 208 180 7B
                STB     A, 00311h[X1]          ; 419B 0 208 180 D01103
                MOVB    00310h[X1], #0ffh      ; 419E 0 208 180 C0100398FF
                SJ      warmcold_deg_flag_load_tbl_x1_2             ; 41A3 0 208 180 CB0F
warmcold_deg_flag_load_tbl_x1:     LB      A, 00310h[X1]          ; 41A5 0 208 180 F01003
                JNE     warmcold_deg_flag_load_r0             ; 41A8 0 208 180 CE02
                MOVB    r0, #053h              ; 41AA 0 208 180 9853
warmcold_deg_flag_load_r0:     LB      A, r0                  ; 41AC 0 208 180 78
                STB     A, 00377h[X1]          ; 41AD 0 208 180 D07703
                LB      A, r1                  ; 41B0 0 208 180 79
                STB     A, 00378h[X1]          ; 41B1 0 208 180 D07803
warmcold_deg_flag_load_tbl_x1_2:     LB      A, 00311h[X1]          ; 41B4 0 208 180 F01103
                CMPB    A, r2                  ; 41B7 0 208 180 4A
                JLT     tps_learn_alt_path             ; 41B8 0 208 180 CA09
                LB      A, r2                  ; 41BA 0 208 180 7A
                STB     A, 00311h[X1]          ; 41BB 0 208 180 D01103
                SJ      tps_learn_alt_path             ; 41BE 0 208 180 CB03
warmcold_deg_flag_store_tbl_x1:     STB     A, 00377h[X1]          ; 41C0 0 208 180 D07703
tps_learn_alt_path:     CLR     X1                     ; 41C3 0 208 180 9015
                L       A, 0030ch[X1]          ; 41C5 1 208 180 E00C03
                CMP     A, #00010h             ; 41C8 1 208 180 C61000
                JLT     fueltbl_default_load             ; 41CB 1 208 180 CA05
                CMP     A, #01000h             ; 41CD 1 208 180 C60010
                JLE     fueltbl_sanitize_loop             ; 41D0 1 208 180 CF06
fueltbl_default_load:     L       A, 00382h[X1]          ; 41D2 1 208 180 E08203
; [H] --- Fuel table shadow-copy sanitization (0x35AE-0x35E8): walks the FUEL1_Hi_Extended
; [H] region in RAM (0x300-0x30C), and for any entry outside a plausible range (0x9862 max,
; [H] FUEL1_Hi_Extended min) resets it to a default 0x8000 -- guards against corrupted/garbage
; [H] fuel-table data. Followed by a knock-related check (knock_helper1 onward, comparing against
; [H] tbl_knock_sanity) gated by a critical-section register snapshot -- likely a knock-retard sanity
; [H] check, not fully confirmed.
                ST      A, 0030ch[X1]          ; 41D5 1 208 180 D00C03
fueltbl_sanitize_loop:     MOV     DP, #00300h            ; 41D8 1 208 180 620003
fueltbl_sanitize_check:     JBR     off(00216h).2, fueltbl_range_check ; 41DB 1 208 180 DA1605
                MB      C, 0b8h.5              ; 41DE 1 208 180 C5B82D
                JLT     fueltbl_default_value             ; 41E1 1 208 180 CA0C
fueltbl_range_check:     CMP     [DP], #09862h          ; 41E3 1 208 180 B2C06298
                JGT     fueltbl_default_value             ; 41E7 1 208 180 C806
                CMP     [DP], #07133h                         ; 41E9 1 208 180 B2C03371
                JGE     fueltbl_sanitize_advance             ; 41ED 1 208 180 CD04
fueltbl_default_value:     MOV     [DP], #08000h          ; 41EF 1 208 180 B2980080
fueltbl_sanitize_advance:     ADD     DP, #00004h            ; 41F3 1 208 180 92800400
                CMP     DP, #0030ch            ; 41F7 1 208 180 92C00C03
                JLT     fueltbl_sanitize_check             ; 41FB 1 208 180 CADE
                MB      C, (00128h-00180h)[USP].2 ; 41FD 1 208 180 C3A82A
                JGE     sensor_check_vcal3             ; 4200 1 208 180 CD63
                L       A, 0fah                ; 4202 1 208 180 E5FA
                ST      A, IE                  ; 4204 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 4206 1 208 180 A2D0FE
                MOVB    r0, (0018eh-00180h)[USP] ; 4209 1 208 180 C30E48
                MOVB    r1, (00116h-00180h)[USP] ; 420C 1 208 180 C39649
                MOVB    r2, (00117h-00180h)[USP] ; 420F 1 208 180 C3974A
                MOVB    r3, (0013ch-00180h)[USP] ; 4212 1 208 180 C3BC4B
                ORB     PSWH, #001h            ; 4215 1 208 180 A2E001
                L       A, 0f8h                ; 4218 1 208 180 E5F8
                ST      A, IE                  ; 421A 1 208 180 D51A
                LB      A, r3                  ; 421C 0 208 180 7B
                CAL     knock_helper1             ; 421D 0 208 180 32B056
                CMPB    A, r0                  ; 4220 0 208 180 48
                JNE     knock_check_alt_path             ; 4221 0 208 180 CE0D
                LB      A, r2                  ; 4223 0 208 180 7A
                EXTND                          ; 4224 1 208 180 F8
                SLL     A                      ; 4225 1 208 180 53
                LC      A, fueltbl_sanitize_advance_tbl[ACC]       ; 4226 1 208 180 B506A9D06F
                JEQ     sensor_check_vcal3             ; 422B 1 208 180 C938
                CMP     A, er0                 ; 422D 1 208 180 48
                JEQ     sensor_check_vcal3             ; 422E 1 208 180 C935
knock_check_alt_path:     L       A, 0fah                ; 4230 1 208 180 E5FA
                ST      A, IE                  ; 4232 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 4234 1 208 180 A2D0FE
                RB      TCON0.4                ; 4237 1 208 180 C5400C
                RB      TCON0.2                ; 423A 1 208 180 C5400A
                LB      A, #00fh               ; 423D 0 208 180 770F
                STB     A, (00117h-00180h)[USP] ; 423F 0 208 180 D397
                STB     A, (0018fh-00180h)[USP] ; 4241 0 208 180 D30F
                ORB     P2, A                  ; 4243 0 208 180 C524E1
                SB      TCON0.2                ; 4246 0 208 180 C5401A
                LB      A, (0013ch-00180h)[USP] ; 4249 0 208 180 F3BC
                CAL     knock_helper1             ; 424B 0 208 180 32B056
                STB     A, (0018eh-00180h)[USP] ; 424E 0 208 180 D30E
                XORB    A, #0ffh               ; 4250 0 208 180 F6FF
                MB      C, ACC.7               ; 4252 0 208 180 C5062F
                ROLB    A                      ; 4255 0 208 180 33
                STB     A, (00116h-00180h)[USP] ; 4256 0 208 180 D396
                RB      TCON0.2                ; 4258 0 208 180 C5400A
                SB      TCON0.4                ; 425B 0 208 180 C5401C
                ORB     PSWH, #001h            ; 425E 0 208 180 A2E001
                L       A, 0f8h                ; 4261 1 208 180 E5F8
                ST      A, IE                  ; 4263 1 208 180 D51A
sensor_check_vcal3:     VCAL    3                      ; 4265 1 208 180 13
                MOV     DP, #003cdh            ; 4266 1 208 180 62CD03
                J       sensor_check_vcal3_load_dp_ind             ; 4269 1 208 180 03FE7A
sensor_check_gate1_if_ram212_bit2_set:     JBS     off(00212h).2, sensor_check_clear ; 426C 0 208 180 EA122E
                JBS     off(00212h).4, sensor_check_clear ; 426F 0 208 180 EC122B
                JBR     off(00217h).5, sensor_check_gate2 ; 4272 0 208 180 DD1706
                MOVB    (001e8h-00180h)[USP], #064h ; 4275 0 208 180 C3689864
                SJ      sensor_check_clear             ; 4279 0 208 180 CB22
sensor_check_gate2:     JBS     off(00230h).5, sensor_check_clear ; 427B 0 208 180 ED301F
                CMPB    off(00238h), #002h     ; 427E 0 208 180 C438C002
                JGE     sensor_check_gate3             ; 4282 0 208 180 CD04
                MOVB    (001e8h-00180h)[USP], #064h ; 4284 0 208 180 C3689864
sensor_check_gate3:     JBR     off(00230h).4, sensor_check_clear ; 4288 0 208 180 DC3012
                MOV     DP, #00374h            ; 428B 0 208 180 627403
                LB      A, [DP]                ; 428E 0 208 180 F2
                SUBB    A, ADCR6H              ; 428F 0 208 180 C56DA2
                JGE     sensor_check_result             ; 4292 0 208 180 CD01
                VCAL    6                      ; 4294 0 208 180 16
sensor_check_result:     CMPB    A, #002h               ; 4295 0 208 180 C602
                JGE     sensor_check_set             ; 4297 0 208 180 CD07
                LB      A, (001e8h-00180h)[USP] ; 4299 0 208 180 F368
                JEQ     dtc05_map_range_latch             ; 429B 0 208 180 C906
sensor_check_clear:     RC                             ; 429D 0 208 180 95
                SJ      dtc05_map_range_latch             ; 429E 0 208 180 CB03
sensor_check_set:     SB      off(00230h).5          ; 42A0 0 208 180 C4301D
dtc05_map_range_latch:     MB      0b0h.3, C              ; 42A3 0 208 180 C5B03B
                RB      PSWL.4                 ; 42A6 0 208 180 A30C
                CLR     X1                     ; 42A8 0 208 180 9015
                LB      A, 003d0h[X1]          ; 42AA 0 208 180 F0D003
                STB     A, r1                  ; 42AD 0 208 180 89
                RC                             ; 42AE 0 208 180 95
                JBS     off(00212h).5, dtc06_ect_latch ; 42AF 0 208 180 ED1208
                LB      A, #0fch               ; 42B2 0 208 180 77FC
                CMPB    A, r1                  ; 42B4 0 208 180 49
                JLT     dtc06_ect_latch             ; 42B5 0 208 180 CA03
                LB      A, r1                  ; 42B7 0 208 180 79
                CMPB    A, #004h               ; 42B8 0 208 180 C604
dtc06_ect_latch:     MB      0b0h.1, C              ; 42BA 0 208 180 C5B039
                JBS     off(00212h).5, ect_simulate_ramp ; 42BD 0 208 180 ED1220
                JLT     ect_fault_stamp             ; 42C0 0 208 180 CA35
                JBS     off(00210h).7, ect_smooth_apply ; 42C2 0 208 180 EF103A
                SUBB    A, 00375h[X1]          ; 42C5 0 208 180 C07503A2
                JGE     ect_fault_delta_check             ; 42C9 0 208 180 CD01
                VCAL    6                      ; 42CB 0 208 180 16
ect_fault_delta_check:     CMPB    A, #002h               ; 42CC 0 208 180 C602
                JGT     ect_fault_normal_store             ; 42CE 0 208 180 C846
                LB      A, (001e9h-00180h)[USP] ; 42D0 0 208 180 F369
                JNE     sensor_bank_ect_check_goto_79db             ; 42D2 0 208 180 CE4A
                LB      A, r1                  ; 42D4 0 208 180 79
                JBS     off(00217h).4, ect_smooth_apply ; 42D5 0 208 180 EC1727
                CMPB    A, 00376h[X1]          ; 42D8 0 208 180 C07603C2
                JGT     sensor_bank_ect_check             ; 42DC 0 208 180 C83C
                SJ      ect_smooth_apply             ; 42DE 0 208 180 CB1F
ect_simulate_ramp:     JBR     off(00217h).5, ect_fault_stamp ; 42E0 0 208 180 DD1714
                CLR     A                      ; 42E3 1 208 180 F9
                LB      A, (001e7h-00180h)[USP] ; 42E4 0 208 180 F367
                MOVB    r0, #014h              ; 42E6 0 208 180 9814
                DIVB                           ; 42E8 0 208 180 A236
                MOV     DP, #tbl_ect_simulate_ramp          ; 42EA 0 208 180 62DB6D
                ADD     DP, A                  ; 42ED 0 208 180 9281
                LCB     A, [DP]                ; 42EF 0 208 180 92AA
                STB     A, 0d9h                ; 42F1 0 208 180 D5D9
                SB      PSWL.4                 ; 42F3 0 208 180 A31C
                SJ      sensor_bank_ect_check             ; 42F5 0 208 180 CB23
ect_fault_stamp:     MOVB    0d9h, #03bh            ; 42F7 0 208 180 C5D9983B
                SB      PSWL.4                 ; 42FB 0 208 180 A31C
                SJ      sensor_bank_ect_check             ; 42FD 0 208 180 CB1B
ect_smooth_apply:     MOVB    r0, 0d9h               ; 42FF 0 208 180 C5D948
                MOV     DP, #000d9h            ; 4302 0 208 180 62D900
                CAL     ect_smooth_helper             ; 4305 0 208 180 32115C
                CMPB    A, r0                  ; 4308 0 208 180 48
                JEQ     ect_store_history_check             ; 4309 0 208 180 C902
                SB      PSWL.4                 ; 430B 0 208 180 A31C
ect_store_history_check:     JBS     off(00217h).5, ect_step_call ; 430D 0 208 180 ED1703
                STB     A, 0031ah[X1]          ; 4310 0 208 180 D01A03
ect_step_call:     CAL     ect_step_helper             ; 4313 0 208 180 32F55B
ect_fault_normal_store:     LB      A, r1                  ; 4316 0 208 180 79
                STB     A, 00375h[X1]          ; 4317 0 208 180 D07503
sensor_bank_ect_check:     MOVB    (001e9h-00180h)[USP], #005h ; 431A 0 208 180 C3699805
sensor_bank_ect_check_goto_79db:     J       sensor_bank_ect_check_if_ram230_bit3_clr             ; 431E 0 208 180 03DB79
                DB  000h ; 4321
sensor_bank_ect_check_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 4322 0 208 180 A32C
sensor_bank_ect_check_store_carry_ram234_bit6:     MB      off(00234h).6, C       ; 4324 0 208 180 C4343E
                RC                             ; 4327 0 208 180 95
                JBS     off(00212h).7, dtc08_tdc_latch ; 4328 0 208 180 EF120E
                JBR     off(00217h).4, dtc08_tdc_latch ; 432B 0 208 180 DC170B
                MB      C, off(00211h).0       ; 432E 0 208 180 C41128
                JBR     off(00216h).3, dtc08_tdc_latch ; 4331 0 208 180 DB1605
                JGE     dtc08_tdc_latch             ; 4334 0 208 180 CD03
                MB      C, off(00211h).5       ; 4336 0 208 180 C4112D
dtc08_tdc_latch:     MB      0b0h.5, C              ; 4339 0 208 180 C5B03D
                JBR     off(00213h).1, iat_range_check ; 433C 0 208 180 D91306
                MOVB    0d8h, #057h            ; 433F 0 208 180 C5D89857
                SJ      iat_check_return             ; 4343 0 208 180 CB14
iat_range_check:     LB      A, #0fch               ; 4345 0 208 180 77FC
                MOV     DP, #003c8h            ; 4347 0 208 180 62C803
                CMPB    A, [DP]                ; 434A 0 208 180 C2C2
                JLT     dtc10_iat_latch             ; 434C 0 208 180 CA0C
                LB      A, [DP]                ; 434E 0 208 180 F2
                CMPB    A, #004h               ; 434F 0 208 180 C604
                JLT     dtc10_iat_latch             ; 4351 0 208 180 CA07
                MOV     DP, #000d8h            ; 4353 0 208 180 62D800
                CAL     ect_smooth_helper             ; 4356 0 208 180 32115C
iat_check_return:     RC                             ; 4359 0 208 180 95
dtc10_iat_latch:     MB      0b0h.6, C              ; 435A 0 208 180 C5B03E
                LB      A, #080h               ; 435D 0 208 180 7780
                RC                             ; 435F 0 208 180 95
                JBS     off(00217h).6, sensor_bank_store_e3 ; 4360 0 208 180 EE1714
                JBS     off(00219h).3, sensor_bank_store_e3 ; 4363 0 208 180 EB1911
                JBS     off(00213h).2, sensor_bank_store_e3 ; 4366 0 208 180 EA130E
                MOV     DP, #003ceh            ; 4369 0 208 180 62CE03
                LB      A, #0ffh               ; 436C 0 208 180 77FF
                CMPB    A, [DP]                ; 436E 0 208 180 C2C2
                JLT     dtc_bit08_latch             ; 4370 0 208 180 CA07
                LB      A, [DP]                ; 4372 0 208 180 F2
                CMPB    A, #000h               ; 4373 0 208 180 C600
                JLT     dtc_bit08_latch             ; 4375 0 208 180 CA02
sensor_bank_store_e3:     STB     A, 0e3h                ; 4377 0 208 180 D5E3
dtc_bit08_latch:     MB      0b0h.7, C              ; 4379 0 208 180 C5B03F
                JBR     off(00227h).4, sensor_bank_stamp_bc ; 437C 0 208 180 DC2703
                JBR     off(00213h).4, sensor_bank_bc_alt ; 437F 0 208 180 DC1306
sensor_bank_stamp_bc:     MOVB    0bch, #0f9h            ; 4382 0 208 180 C5BC98F9
                SJ      dcode14_return             ; 4386 0 208 180 CB18
sensor_bank_bc_alt:     CLR     A                      ; 4388 1 208 180 F9
                LB      A, #0ffh               ; 4389 0 208 180 77FF
                MOV     DP, #003c9h            ; 438B 0 208 180 62C903
                CMPB    A, [DP]                ; 438E 0 208 180 C2C2
                JLT     dtc13_baro_latch             ; 4390 0 208 180 CA0F
                LB      A, [DP]                ; 4392 0 208 180 F2
                CMPB    A, #000h               ; 4393 0 208 180 C600
                JLT     dtc13_baro_latch             ; 4395 0 208 180 CA0A
                CAL     sub_clamp_helper             ; 4397 0 208 180 32F858
                MOV     DP, #000bch            ; 439A 0 208 180 62BC00
                CAL     ect_smooth_helper             ; 439D 0 208 180 32115C
dcode14_return:     RC                             ; 43A0 0 208 180 95
dtc13_baro_latch:     MB      0b1h.2, C              ; 43A1 0 208 180 C5B13A
                VCAL    3                      ; 43A4 0 208 180 13
                JBS     off(00217h).5, dcode14_clear ; 43A5 0 208 180 ED171B
                JBS     off(00213h).5, dcode14_clear ; 43A8 0 208 180 ED1318
                LB      A, 0dbh                ; 43AB 0 208 180 F5DB
                MOV     X1, #tbl_dcode14_lo          ; 43AD 0 208 180 60E06D
                VCAL    2                      ; 43B0 0 208 180 12
                CMPB    A, off(0025eh)         ; 43B1 0 208 180 C75E
                JLT     dcode14_clear             ; 43B3 0 208 180 CA0E
                LB      A, 0dbh                ; 43B5 0 208 180 F5DB
                MOV     X1, #tbl_dcode14_hi          ; 43B7 0 208 180 60E66D
                VCAL    2                      ; 43BA 0 208 180 12
                CMPB    A, off(0025eh)         ; 43BB 0 208 180 C75E
                JGE     dcode14_clear             ; 43BD 0 208 180 CD04
                LB      A, (001eah-00180h)[USP] ; 43BF 0 208 180 F36A
                JEQ     dtc14_iacv_latch             ; 43C1 0 208 180 C901
dcode14_clear:     RC                             ; 43C3 0 208 180 95
dtc14_iacv_latch:     MB      0b1h.3, C              ; 43C4 0 208 180 C5B13B
                LB      A, #044h               ; 43C7 0 208 180 7744
                CMPB    A, 0dbh                ; 43C9 0 208 180 C5DBC2
                JGE     dtc17_vss_latch             ; 43CC 0 208 180 CD13
                CMPB    off(00238h), #0b0h     ; 43CE 0 208 180 C438C0B0
                JGE     dtc17_vss_latch             ; 43D2 0 208 180 CD0D
                RC                             ; 43D4 0 208 180 95
                JBS     off(00217h).5, dtc17_vss_latch ; 43D5 0 208 180 ED1709
                JBS     off(00214h).0, dtc17_vss_latch ; 43D8 0 208 180 E81406
                JBR     off(00231h).3, dtc17_vss_latch ; 43DB 0 208 180 DB3103
                MB      C, off(0021ch).4       ; 43DE 0 208 180 C41C2C
dtc17_vss_latch:     MB      0b1h.4, C              ; 43E1 0 208 180 C5B13C
                RC                             ; 43E4 0 208 180 95
                JBS     off(00227h).2, dtc_bit0F_latch ; 43E5 0 208 180 EA270F
                JBR     off(00216h).3, dtc_bit0F_latch ; 43E8 0 208 180 DB160C
                JBS     off(00214h).2, dtc_bit0F_latch ; 43EB 0 208 180 EA1409
                MB      C, off(00210h).4       ; 43EE 0 208 180 C4102C
                JBR     off(0022fh).0, dtc_bit0F_latch ; 43F1 0 208 180 D82F03
                XORB    PSWH, #080h            ; 43F4 0 208 180 A2F080
dtc_bit0F_latch:     MB      0b1h.6, C              ; 43F7 0 208 180 C5B13E
                VCAL    3                      ; 43FA 0 208 180 13
                JBS     off(00227h).2, dcode_gate_common2 ; 43FB 0 208 180 EA2738
                JBR     off(00216h).3, dcode_gate_common2 ; 43FE 0 208 180 DB1635
                JBS     off(00214h).2, dcode_gate_common2 ; 4401 0 208 180 EA1432
                MOV     DP, #003e8h            ; 4404 0 208 180 62E803
                L       A, 0fah                ; 4407 1 208 180 E5FA
                ST      A, IE                  ; 4409 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 440B 1 208 180 A2D0FE
                L       A, [DP]                ; 440E 1 208 180 E2
                ST      A, er0                 ; 440F 1 208 180 88
                MOV     DP, #04700h            ; 4410 1 208 180 620047
                LB      A, [DP]                ; 4413 0 208 180 F2
                STB     A, r7                  ; 4414 0 208 180 8F
                ORB     PSWH, #001h            ; 4415 0 208 180 A2E001
                L       A, 0f8h                ; 4418 1 208 180 E5F8
                ST      A, IE                  ; 441A 1 208 180 D51A
                ANDB    r7, #008h              ; 441C 1 208 180 27D008
                LB      A, r0                  ; 441F 0 208 180 78
                CMPB    A, #00ah               ; 4420 0 208 180 C60A
                JLT     dcode_gate_common2             ; 4422 0 208 180 CA12
                SUBB    A, r1                  ; 4424 0 208 180 29
                JGE     dcode_gate_common_cmp_acc             ; 4425 0 208 180 CD05
                LB      A, r7                  ; 4427 0 208 180 7F
                JNE     dtc19_at_lockup_latch             ; 4428 0 208 180 CE09
                SJ      dcode_gate_common2             ; 442A 0 208 180 CB0A
dcode_gate_common_cmp_acc:     CMPB    A, #00ah               ; 442C 0 208 180 C60A
                JLT     dcode_gate_common2             ; 442E 0 208 180 CA06
                LB      A, r7                  ; 4430 0 208 180 7F
                JNE     dcode_gate_common2             ; 4431 0 208 180 CE03
dtc19_at_lockup_latch:     SB      0b4h.7                 ; 4433 0 208 180 C5B41F
dcode_gate_common2:     LB      A, #025h               ; 4436 0 208 180 7725
                JBR     off(00219h).3, dcode_stamp_store ; 4438 0 208 180 DB191A
                JBR     off(00217h).6, dcode_stamp_store ; 443B 0 208 180 DE1717
                JBS     off(00214h).3, dcode_stamp_store ; 443E 0 208 180 EB1414
                CMPB    0dbh, #069h            ; 4441 0 208 180 C5DBC069
                JLT     dcode_stamp_store             ; 4445 0 208 180 CA0E
                MOV     DP, #003ceh            ; 4447 0 208 180 62CE03
                LB      A, #0dch               ; 444A 0 208 180 77DC
                CMPB    A, [DP]                ; 444C 0 208 180 C2C2
                JLT     dtc20_eld_latch             ; 444E 0 208 180 CA08
                LB      A, [DP]                ; 4450 0 208 180 F2
                CMPB    A, #00eh               ; 4451 0 208 180 C60E
                JLT     dtc20_eld_latch             ; 4453 0 208 180 CA03
dcode_stamp_store:     STB     A, 0dch                ; 4455 0 208 180 D5DC
                RC                             ; 4457 0 208 180 95
dtc20_eld_latch:     MB      0b1h.7, C              ; 4458 0 208 180 C5B13F
                RC                             ; 445B 0 208 180 95
                JBR     off(00216h).4, dtc21_vtec_solenoid_latch ; 445C 0 208 180 DC161B
                JBS     off(00214h).4, dtc21_vtec_solenoid_latch ; 445F 0 208 180 EC1418
                JBR     off(0021fh).2, altvtec_ramp_alt ; 4462 0 208 180 DA1F0C
                MOVB    (001ech-00180h)[USP], #032h ; 4465 0 208 180 C36C9832
                LB      A, (001ebh-00180h)[USP] ; 4469 0 208 180 F36B
                JBS     off(00210h).5, dtc21_vtec_solenoid_latch ; 446B 0 208 180 ED100C
altvtec_ramp_common:     SC                             ; 446E 0 208 180 85
                SJ      dtc21_vtec_solenoid_latch             ; 446F 0 208 180 CB09
altvtec_ramp_alt:     MOVB    (001ebh-00180h)[USP], #032h ; 4471 0 208 180 C36B9832
                LB      A, (001ech-00180h)[USP] ; 4475 0 208 180 F36C
                JBS     off(00210h).5, altvtec_ramp_common ; 4477 0 208 180 ED10F4
dtc21_vtec_solenoid_latch:     MB      0b2h.0, C              ; 447A 0 208 180 C5B238
                JBR     off(00216h).4, altvtec_vtps_result ; 447D 0 208 180 DC1615
                JNE     altvtec_vtps_result             ; 4480 0 208 180 CE13
                JBS     off(00214h).4, altvtec_vtps_result ; 4482 0 208 180 EC1410
                JLT     altvtec_vtps_result             ; 4485 0 208 180 CA0E
                JBS     off(00214h).5, altvtec_vtps_result ; 4487 0 208 180 ED140B
                MB      C, off(00211h).1       ; 448A 0 208 180 C41129
                JBR     off(0021fh).2, dtc22_vtec_pressure_latch ; 448D 0 208 180 DA1F06
                JLT     altvtec_vtps_result             ; 4490 0 208 180 CA03
                SC                             ; 4492 0 208 180 85
                SJ      dtc22_vtec_pressure_latch             ; 4493 0 208 180 CB01
altvtec_vtps_result:     RC                             ; 4495 0 208 180 95
dtc22_vtec_pressure_latch:     MB      0b2h.1, C              ; 4496 0 208 180 C5B239
                RC                             ; 4499 0 208 180 95
                JBR     off(00227h).6, dtc23_knock_latch ; 449A 0 208 180 DE271D
                JBS     off(00217h).5, dtc23_knock_latch ; 449D 0 208 180 ED171A
                JBS     off(00214h).6, dtc23_knock_latch ; 44A0 0 208 180 EE1417
                JBS     off(00233h).6, dtc23_knock_latch ; 44A3 0 208 180 EE3314
                L       A, off(00212h)         ; 44A6 1 208 180 E412
                AND     A, #0c3bch             ; 44A8 1 208 180 D6BCC3
                JNE     dtc23_knock_latch             ; 44AB 1 208 180 CE0D
                JBS     off(00214h).5, dtc23_knock_latch ; 44AD 1 208 180 ED140A
                LB      A, off(002c9h)         ; 44B0 0 208 180 F4C9
                JEQ     dtc23_knock_latch             ; 44B2 0 208 180 C906
                JBS     off(00233h).7, dtc23_knock_latch ; 44B4 0 208 180 EF3303
                MB      C, off(00232h).7       ; 44B7 0 208 180 C4322F
dtc23_knock_latch:     MB      0b2h.2, C              ; 44BA 0 208 180 C5B23A
                JBR     off(00216h).5, autotcc_return ; 44BD 0 208 180 DD161D
                LB      A, ADCR5H              ; 44C0 0 208 180 F56B
                STB     A, 0d7h                ; 44C2 0 208 180 D5D7
                JBS     off(00217h).5, autotcc_return ; 44C4 0 208 180 ED1716
                JBS     off(00215h).1, autotcc_return ; 44C7 0 208 180 E91513
                CMPB    0dbh, #0ffh            ; 44CA 0 208 180 C5DBC0FF
                JLT     autotcc_return             ; 44CE 0 208 180 CA0D
                LB      A, #0ffh               ; 44D0 0 208 180 77FF
                CMPB    A, 0d7h                ; 44D2 0 208 180 C5D7C2
                JLT     dtc26_code26_latch             ; 44D5 0 208 180 CA07
                CMPB    0d7h, #000h            ; 44D7 0 208 180 C5D7C000
                SJ      dtc26_code26_latch             ; 44DB 0 208 180 CB01
autotcc_return:     RC                             ; 44DD 0 208 180 95
dtc26_code26_latch:     MB      0b3h.1, C              ; 44DE 0 208 180 C5B339
                JBR     off(00216h).5, automatic_return ; 44E1 0 208 180 DD1614
                JBS     off(00217h).5, automatic_return ; 44E4 0 208 180 ED1711
                JBS     off(00215h).0, automatic_return ; 44E7 0 208 180 E8150E
                JBS     off(00215h).1, automatic_return ; 44EA 0 208 180 E9150B
                MB      C, 0b3h.1              ; 44ED 0 208 180 C5B329
                JLT     automatic_return             ; 44F0 0 208 180 CA06
                CMPB    0dbh, #0ffh            ; 44F2 0 208 180 C5DBC0FF
                JGE     automatic_p4_check             ; 44F6 0 208 180 CD03
automatic_return:     RC                             ; 44F8 0 208 180 95
                SJ      dtc25_code25_latch             ; 44F9 0 208 180 CB11
automatic_p4_check:     CMPB    0d7h, #0ffh            ; 44FB 0 208 180 C5D7C0FF
                JLE     automatic_result             ; 44FF 0 208 180 CF08
                MB      C, P4.6                ; 4501 0 208 180 C52C2E
                XORB    PSWH, #080h            ; 4504 0 208 180 A2F080
                SJ      dtc25_code25_latch             ; 4507 0 208 180 CB03
automatic_result:     MB      C, P4.6                ; 4509 0 208 180 C52C2E
dtc25_code25_latch:     MB      0b3h.0, C              ; 450C 0 208 180 C5B338
                JBR     off(00219h).3, knockwindow_clear ; 450F 0 208 180 DB1948
                JBS     off(00217h).5, knockwindow_clear ; 4512 0 208 180 ED1745
                MOV     DP, #003abh            ; 4515 0 208 180 62AB03
                LB      A, [DP]                ; 4518 0 208 180 F2
                CMPB    A, #031h               ; 4519 0 208 180 C631
                JEQ     knockwindow_clear             ; 451B 0 208 180 C93D
                L       A, off(00212h)         ; 451D 1 208 180 E412
                AND     A, #01808h             ; 451F 1 208 180 D60818
                JNE     knockwindow_clear             ; 4522 1 208 180 CE36
                JBS     off(00214h).5, knockwindow_clear ; 4524 1 208 180 ED1433
                JBS     off(0021ch).5, knockwindow_clear ; 4527 1 208 180 ED1C30
                JBS     off(0021dh).3, knockwindow_clear ; 452A 1 208 180 EB1D2D
                JBS     off(00218h).0, knockwindow_clear ; 452D 1 208 180 E8182A
                CMPB    0cch, #005h            ; 4530 1 208 180 C5CCC005
                JLT     knockwindow_check2             ; 4534 1 208 180 CA12
                MOV     X1, #tbl_ignmap2_hi          ; 4536 1 208 180 608364
                LB      A, off(00238h)         ; 4539 0 208 180 F438
                CAL     table_interp_lookup             ; 453B 0 208 180 323958
                ADDB    A, #010h               ; 453E 0 208 180 8610
                JGE     knockwindow_check1             ; 4540 0 208 180 CD02
                LB      A, #0ffh               ; 4542 0 208 180 77FF
knockwindow_check1:     CMPB    A, off(00237h)         ; 4544 0 208 180 C737
                JGE     knockwindow_clear             ; 4546 0 208 180 CD12
knockwindow_check2:     L       A, (0015ah-00180h)[USP] ; 4548 1 208 180 E3DA
                CMP     A, #0b333h             ; 454A 1 208 180 C633B3
                JGE     knockwindow_set             ; 454D 1 208 180 CD0E
                JBS     off(00217h).3, knockwindow_check3 ; 454F 1 208 180 EB1703
                JBS     off(0021eh).4, knockwindow_clear ; 4552 1 208 180 EC1E05
knockwindow_check3:     CMP     A, #06000h             ; 4555 1 208 180 C60060
                JLE     knockwindow_set             ; 4558 1 208 180 CF03
knockwindow_clear:     RC                             ; 455A 1 208 180 95
                SJ      knockwindow_result             ; 455B 1 208 180 CB01
knockwindow_set:     SC                             ; 455D 1 208 180 85
knockwindow_result:     MB      0b5h.7, C              ; 455E 1 208 180 C5B53F
                VCAL    3                      ; 4561 1 208 180 13
                JBS     off(00234h).6, knockwindow_next_table ; 4562 1 208 180 EE3403
                J       iat_map_correction_chain             ; 4565 1 208 180 03D946
knockwindow_next_table:     MOV     X1, #knockwindow_next_table_tbl_16          ; 4568 1 208 180 604468
                MOV     X2, #ZoneIndexTable2_SetA          ; 456B 1 208 180 61B068
                JBS     off(00216h).3, knockwindow_next_table_load_ram0d9 ; 456E 1 208 180 EB1606
                MOV     X1, #ZoneIndexTable1_SetB          ; 4571 1 208 180 602968
                MOV     X2, #ZoneIndexTable2_SetB          ; 4574 1 208 180 619568
knockwindow_next_table_load_ram0d9:     LB      A, 0d9h                ; 4577 0 208 180 F5D9
                VCAL    0                      ; 4579 0 208 180 10
                STB     A, off(00264h)         ; 457A 0 208 180 D464
                MOV     X1, X2                 ; 457C 0 208 180 9178
                LB      A, 0d9h                ; 457E 0 208 180 F5D9
                VCAL    0                      ; 4580 0 208 180 10
                STB     A, off(00266h)         ; 4581 0 208 180 D466
                VCAL    3                      ; 4583 0 208 180 13
                MOV     X1, #tbl_ect_overrun_nor          ; 4584 0 208 180 60F069
                LB      A, 0d9h                ; 4587 0 208 180 F5D9
                CAL     table_interp_lookup             ; 4589 0 208 180 323958
                STB     A, off(00298h)         ; 458C 0 208 180 D498
                MOV     X1, #tbl_ect_vecorrect          ; 458E 0 208 180 60CD69
                LB      A, 0d9h                ; 4591 0 208 180 F5D9
                CAL     table_interp_lookup             ; 4593 0 208 180 323958
                MOV     DP, #0037bh            ; 4596 0 208 180 627B03
                STB     A, [DP]                ; 4599 0 208 180 D2
                VCAL    3                      ; 459A 0 208 180 13
                CLR     X2                     ; 459B 0 208 180 9115
                MOV     X1, #tbl_ect_overrun_int          ; 459D 0 208 180 60B06A
                LB      A, 0d9h                ; 45A0 0 208 180 F5D9
                CAL     table_interp_lookup             ; 45A2 0 208 180 323958
                STB     A, 0037ah[X2]          ; 45A5 0 208 180 D17A03
                MOV     X1, #tbl_knockwindow_9          ; 45A8 0 208 180 60E16B
                JBS     off(00216h).3, knockwindow_next_table_load_ram0d9_2 ; 45AB 0 208 180 EB1603
                MOV     X1, #knockwindow_next_table_tbl_17          ; 45AE 0 208 180 60C66B
knockwindow_next_table_load_ram0d9_2:     LB      A, 0d9h                ; 45B1 0 208 180 F5D9
                VCAL    0                      ; 45B3 0 208 180 10
                STB     A, 0037ch[X2]          ; 45B4 0 208 180 D17C03
                VCAL    3                      ; 45B7 0 208 180 13
                LB      A, 0d9h                ; 45B8 0 208 180 F5D9
                MOV     X1, #tbl_ect_fuelcorrect          ; 45BA 0 208 180 60E66C
                MOV     X2, #knockwindow_next_table_tbl_20          ; 45BD 0 208 180 61DA6C
                CMPB    A, #023h               ; 45C0 0 208 180 C623
                JLT     knockwindow_next_table_store_carry_ram221_bit2             ; 45C2 0 208 180 CA06
                MOV     X1, #knockwindow_next_table_tbl_19          ; 45C4 0 208 180 60C86C
                MOV     X2, #knockwindow_next_table_tbl_18          ; 45C7 0 208 180 61BA6C
knockwindow_next_table_store_carry_ram221_bit2:     MB      off(00221h).2, C       ; 45CA 0 208 180 C4213A
                CAL     table_interp_lookup             ; 45CD 0 208 180 323958
                STB     A, r3                  ; 45D0 0 208 180 8B
                MOV     X1, X2                 ; 45D1 0 208 180 9178
                LB      A, 0d9h                ; 45D3 0 208 180 F5D9
                CAL     table_interp_lookup             ; 45D5 0 208 180 323958
                STB     A, r2                  ; 45D8 0 208 180 8A
                MOV     off(00254h), er1       ; 45D9 0 208 180 457C54
                LB      A, 0d9h                ; 45DC 0 208 180 F5D9
                MOV     X1, #tbl_knockwindow_10          ; 45DE 0 208 180 60AC6C
                CAL     table_interp_lookup             ; 45E1 0 208 180 323958
                STB     A, off(00256h)         ; 45E4 0 208 180 D456
                VCAL    3                      ; 45E6 0 208 180 13
                MOV     X1, #Overrun_Resume_nor          ; 45E7 0 208 180 604D64
                MOV     X2, #Overrun_Resume_int          ; 45EA 0 208 180 613F64
                JBR     off(00216h).3, knockwindow_next_table_load_ram0d9_3 ; 45ED 0 208 180 DB1606
                MOV     X1, #knockwindow_next_table_tbl_13          ; 45F0 0 208 180 606964
                MOV     X2, #knockwindow_next_table_tbl_12          ; 45F3 0 208 180 615B64
knockwindow_next_table_load_ram0d9_3:     LB      A, 0d9h                ; 45F6 0 208 180 F5D9
                CAL     table_interp_lookup             ; 45F8 0 208 180 323958
                STB     A, r2                  ; 45FB 0 208 180 8A
                MOV     X1, X2                 ; 45FC 0 208 180 9178
                LB      A, 0d9h                ; 45FE 0 208 180 F5D9
                CAL     table_interp_lookup             ; 4600 0 208 180 323958
                STB     A, ACCH                ; 4603 0 208 180 D507
                LB      A, r2                  ; 4605 0 208 180 7A
                MOV     (001aah-00180h)[USP], A ; 4606 0 208 180 B32A8A
                VCAL    3                      ; 4609 0 208 180 13
                MOV     X1, #tbl_knockwindow_4          ; 460A 0 208 180 609D62
                MOV     X2, #tbl_knockwindow_3          ; 460D 0 208 180 618F62
                JBR     off(00216h).3, knockwindow_next_table_load_ram0d9_4 ; 4610 0 208 180 DB1606
                MOV     X1, #knockwindow_next_table_tbl_8          ; 4613 0 208 180 60B962
                MOV     X2, #knockwindow_next_table_tbl_7          ; 4616 0 208 180 61AB62
knockwindow_next_table_load_ram0d9_4:     LB      A, 0d9h                ; 4619 0 208 180 F5D9
                CAL     table_interp_lookup             ; 461B 0 208 180 323958
                STB     A, r2                  ; 461E 0 208 180 8A
                MOV     X1, X2                 ; 461F 0 208 180 9178
                LB      A, 0d9h                ; 4621 0 208 180 F5D9
                CAL     table_interp_lookup             ; 4623 0 208 180 323958
                STB     A, ACCH                ; 4626 0 208 180 D507
                LB      A, r2                  ; 4628 0 208 180 7A
                MOV     (001a8h-00180h)[USP], A ; 4629 0 208 180 B3288A
                VCAL    3                      ; 462C 0 208 180 13
                LB      A, 0d9h                ; 462D 0 208 180 F5D9
                MOV     X1, #VEFuelCorrect          ; 462F 0 208 180 605362
                CMPCB   A, 00002h[X1]          ; 4632 0 208 180 90AF0200
                MB      off(00219h).5, C       ; 4636 0 208 180 C4193D
                CAL     table_interp_lookup             ; 4639 0 208 180 323958
                STB     A, (0017fh-00180h)[USP] ; 463C 0 208 180 D3FF
                LB      A, 0d9h                ; 463E 0 208 180 F5D9
                MOV     X1, #tbl_knockwindow_5          ; 4640 0 208 180 60B963
                VCAL    0                      ; 4643 0 208 180 10
                STB     A, (00154h-00180h)[USP] ; 4644 0 208 180 D3D4
                VCAL    3                      ; 4646 0 208 180 13
                LB      A, 0d9h                ; 4647 0 208 180 F5D9
                STB     A, r2                  ; 4649 0 208 180 8A
                MOV     X1, #knockwindow_next_table_tbl          ; 464A 0 208 180 601E61
                CAL     table_interp_lookup             ; 464D 0 208 180 323958
                STB     A, (0016ah-00180h)[USP] ; 4650 0 208 180 D3EA
                LB      A, r2                  ; 4652 0 208 180 7A
                MOV     X1, #knockwindow_next_table_tbl_2          ; 4653 0 208 180 602C61
                CAL     table_interp_lookup             ; 4656 0 208 180 323958
                STB     A, (0016bh-00180h)[USP] ; 4659 0 208 180 D3EB
                LB      A, r2                  ; 465B 0 208 180 7A
                MOV     X1, #knockwindow_next_table_tbl_3          ; 465C 0 208 180 603A61
                CAL     table_interp_lookup             ; 465F 0 208 180 323958
                STB     A, (0016ch-00180h)[USP] ; 4662 0 208 180 D3EC
                VCAL    3                      ; 4664 0 208 180 13
                LB      A, 0d9h                ; 4665 0 208 180 F5D9
                STB     A, r2                  ; 4667 0 208 180 8A
                MOV     X1, #knockwindow_next_table_tbl_4          ; 4668 0 208 180 604861
                CAL     table_interp_lookup             ; 466B 0 208 180 323958
                STB     A, (0016dh-00180h)[USP] ; 466E 0 208 180 D3ED
                LB      A, r2                  ; 4670 0 208 180 7A
                MOV     X1, #knockwindow_next_table_tbl_14          ; 4671 0 208 180 60CE66
                CAL     table_interp_lookup             ; 4674 0 208 180 323958
                STB     A, (0016eh-00180h)[USP] ; 4677 0 208 180 D3EE
                LB      A, r2                  ; 4679 0 208 180 7A
                MOV     X1, #knockwindow_next_table_tbl_5          ; 467A 0 208 180 605661
                CAL     table_interp_lookup             ; 467D 0 208 180 323958
                STB     A, (00181h-00180h)[USP] ; 4680 0 208 180 D301
                VCAL    3                      ; 4682 0 208 180 13
                J       knockwindow_next_table_load_ram0d9_5             ; 4683 0 208 180 038478
knockwindow_next_table_load_x1:     MOV     X1, #knockwindow_next_table_tbl_9          ; 4686 0 208 180 60D663
                JBS     off(00216h).3, knockwindow_next_table_call_table_interp_lookup ; 4689 0 208 180 EB1603
                MOV     X1, #tbl_knockwindow_6          ; 468C 0 208 180 60C863
knockwindow_next_table_call_table_interp_lookup:     CAL     table_interp_lookup             ; 468F 0 208 180 323958
                STB     A, (0018bh-00180h)[USP] ; 4692 0 208 180 D30B
                LB      A, r2                  ; 4694 0 208 180 7A
                MOV     X1, #knockwindow_next_table_tbl_10          ; 4695 0 208 180 60F263
                JBS     off(00216h).3, knockwindow_next_table_call_table_interp_lookup_2 ; 4698 0 208 180 EB1603
                MOV     X1, #tbl_knockwindow_7          ; 469B 0 208 180 60E463
knockwindow_next_table_call_table_interp_lookup_2:     CAL     table_interp_lookup             ; 469E 0 208 180 323958
                STB     A, (0018ch-00180h)[USP] ; 46A1 0 208 180 D30C
                VCAL    3                      ; 46A3 0 208 180 13
                LB      A, 0d9h                ; 46A4 0 208 180 F5D9
                STB     A, r2                  ; 46A6 0 208 180 8A
                MOV     X1, #knockwindow_next_table_tbl_11          ; 46A7 0 208 180 600064
                JBS     off(00216h).3, knockwindow_next_table_call_table_interp_lookup_3 ; 46AA 0 208 180 EB1603
                MOV     X1, #tbl_knockwindow_8          ; 46AD 0 208 180 600E64
knockwindow_next_table_call_table_interp_lookup_3:     CAL     table_interp_lookup             ; 46B0 0 208 180 323958
                STB     A, (0018dh-00180h)[USP] ; 46B3 0 208 180 D30D
                LB      A, r2                  ; 46B5 0 208 180 7A
                MOV     X1, #Tipintempoffsetnormal          ; 46B6 0 208 180 606463
                VCAL    0                      ; 46B9 0 208 180 10
                STB     A, (00186h-00180h)[USP] ; 46BA 0 208 180 D306
                VCAL    3                      ; 46BC 0 208 180 13
                LB      A, 0d9h                ; 46BD 0 208 180 F5D9
                MOV     X1, #Tipintempoffsetinitial          ; 46BF 0 208 180 607663
                VCAL    0                      ; 46C2 0 208 180 10
                STB     A, (00188h-00180h)[USP] ; 46C3 0 208 180 D308
                LB      A, 0d9h                ; 46C5 0 208 180 F5D9
                MOV     X1, #knockwindow_next_table_tbl_6          ; 46C7 0 208 180 606461
                CAL     table_interp_lookup             ; 46CA 0 208 180 323958
                STB     A, (0016fh-00180h)[USP] ; 46CD 0 208 180 D3EF
                VCAL    3                      ; 46CF 0 208 180 13
                LB      A, 0d9h                ; 46D0 0 208 180 F5D9
                MOV     X1, #knockwindow_next_table_tbl_15          ; 46D2 0 208 180 60BC67
                VCAL    0                      ; 46D5 0 208 180 10
                STB     A, (0014eh-00180h)[USP] ; 46D6 0 208 180 D3CE
                VCAL    3                      ; 46D8 0 208 180 13
iat_map_correction_chain:     LB      A, 0d8h                ; 46D9 0 208 180 F5D8
                MOV     X1, #tbl_iat_correct1          ; 46DB 0 208 180 60B06B
                VCAL    0                      ; 46DE 0 208 180 10
                STB     A, off(0027eh)         ; 46DF 0 208 180 D47E
                LB      A, 0bch                ; 46E1 0 208 180 F5BC
                MOV     X1, #tbl_iat_correct2          ; 46E3 0 208 180 60C26B
                VCAL    1                      ; 46E6 0 208 180 11
                STB     A, off(00294h)         ; 46E7 0 208 180 D494
                VCAL    3                      ; 46E9 0 208 180 13
                LB      A, #070h               ; 46EA 0 208 180 7770
                JBS     off(00221h).0, iat_map_correction_chain_cmp_acc ; 46EC 0 208 180 E82102
                LB      A, #074h               ; 46EF 0 208 180 7774
iat_map_correction_chain_cmp_acc:     CMPB    A, off(00238h)         ; 46F1 0 208 180 C738
                MB      off(00221h).0, C       ; 46F3 0 208 180 C42138
                LB      A, #091h               ; 46F6 0 208 180 7791
                JBS     off(00221h).1, iat_map_correction_chain_cmp_acc_2 ; 46F8 0 208 180 E92102
                LB      A, #09ch               ; 46FB 0 208 180 779C
iat_map_correction_chain_cmp_acc_2:     CMPB    A, off(00237h)         ; 46FD 0 208 180 C737
                MB      off(00221h).1, C       ; 46FF 0 208 180 C42139
                CLRB    A                      ; 4702 0 208 180 FA
                JGE     iat_map_correction_chain_store_ram23c             ; 4703 0 208 180 CD0E
                JBR     off(00221h).0, iat_map_correction_chain_store_ram23c ; 4705 0 208 180 D8210B
                JBS     off(00213h).1, iat_map_correction_chain_store_ram23c ; 4708 0 208 180 E91308
                LB      A, 0d8h                ; 470B 0 208 180 F5D8
                MOV     X1, #iat_map_correction_chain_tbl          ; 470D 0 208 180 60F26C
                CAL     table_interp_lookup             ; 4710 0 208 180 323958
iat_map_correction_chain_store_ram23c:     STB     A, off(0023ch)         ; 4713 0 208 180 D43C
                MOV     DP, #003d5h            ; 4715 0 208 180 62D503
                LB      A, [DP]                ; 4718 0 208 180 F2
                SLLB    A                      ; 4719 0 208 180 53
                MB      off(00220h).4, C       ; 471A 0 208 180 C4203C
                LB      A, #066h               ; 471D 0 208 180 7766
                JBS     off(00220h).5, iat_map_correction_chain_cmp_acc_3 ; 471F 0 208 180 ED2002
                LB      A, #073h               ; 4722 0 208 180 7773
iat_map_correction_chain_cmp_acc_3:     CMPB    A, off(00238h)         ; 4724 0 208 180 C738
                MB      off(00220h).5, C       ; 4726 0 208 180 C4203D
                LB      A, #09ah               ; 4729 0 208 180 779A
                JBS     off(00220h).6, iat_map_correction_chain_cmp_acc_4 ; 472B 0 208 180 EE2002
                LB      A, #0a0h               ; 472E 0 208 180 77A0
iat_map_correction_chain_cmp_acc_4:     CMPB    A, off(00238h)         ; 4730 0 208 180 C738
                MB      off(00220h).6, C       ; 4732 0 208 180 C4203E
                LB      A, #089h               ; 4735 0 208 180 7789
                JBS     off(00220h).7, iat_map_correction_chain_cmp_acc_5 ; 4737 0 208 180 EF2002
                LB      A, #09ch               ; 473A 0 208 180 779C
iat_map_correction_chain_cmp_acc_5:     CMPB    A, off(00237h)         ; 473C 0 208 180 C737
                CLRB    A                      ; 473E 0 208 180 FA
                MB      off(00220h).7, C       ; 473F 0 208 180 C4203F
                JGE     div_scale_store             ; 4742 0 208 180 CD30
                CLR     A                      ; 4744 1 208 180 F9
                MOV     DP, #003d2h            ; 4745 1 208 180 62D203
                LB      A, [DP]                ; 4748 0 208 180 F2
                CMPB    A, #0fah               ; 4749 0 208 180 C6FA
                JGE     div_scale_default             ; 474B 0 208 180 CD1D
                SUBB    A, #007h               ; 474D 0 208 180 A607
                JGE     div_scale_calc1             ; 474F 0 208 180 CD01
                CLRB    A                      ; 4751 0 208 180 FA
div_scale_calc1:     MOVB    r0, #051h              ; 4752 0 208 180 9851
                DIVB                           ; 4754 0 208 180 A236
                JBR     off(00220h).5, div_scale_gate_common ; 4756 0 208 180 DD200D
                MOVB    r0, #01bh              ; 4759 0 208 180 981B
                LB      A, r1                  ; 475B 0 208 180 79
                DIVB                           ; 475C 0 208 180 A236
                JBR     off(00220h).6, div_scale_gate_common ; 475E 0 208 180 DE2005
                MOVB    r0, #009h              ; 4761 0 208 180 9809
                LB      A, r1                  ; 4763 0 208 180 79
                DIVB                           ; 4764 0 208 180 A236
div_scale_gate_common:     CMPB    A, #003h               ; 4766 0 208 180 C603
                JLT     div_scale_mul_final             ; 4768 0 208 180 CA02
div_scale_default:     LB      A, #002h               ; 476A 0 208 180 7702
div_scale_mul_final:     MOVB    r0, #008h              ; 476C 0 208 180 9808
                MULB                           ; 476E 0 208 180 A234
                JBR     off(00220h).4, div_scale_store ; 4770 0 208 180 DC2001
                VCAL    6                      ; 4773 0 208 180 16
div_scale_store:     STB     A, off(00245h)         ; 4774 0 208 180 D445
                LB      A, #005h               ; 4776 0 208 180 7705
                MOV     X1, #00004h            ; 4778 0 208 180 600400
                JBS     off(00216h).3, gear_detect_store ; 477B 0 208 180 EB1636
                LB      A, #001h               ; 477E 0 208 180 7701
                CLR     X1                     ; 4780 0 208 180 9015
                JBS     off(00217h).5, gear_detect_store ; 4782 0 208 180 ED172F
                JBS     off(00214h).0, gear_detect_store ; 4785 0 208 180 E8142C
                JBR     off(00227h).3, div_scale_store_load_r1 ; 4788 0 208 180 DB270B
                JBR     off(0022fh).3, div_scale_store_load_ram2e1 ; 478B 0 208 180 DB2F04
                MOVB    off(002e1h), #005h     ; 478E 0 208 180 C4E19805
div_scale_store_load_ram2e1:     LB      A, off(002e1h)         ; 4792 0 208 180 F4E1
                JNE     gear_detect_store_load_ram0db             ; 4794 0 208 180 CE26
div_scale_store_load_r1:     MOVB    r1, 0cch               ; 4796 0 208 180 C5CC49
                CLRB    r0                     ; 4799 0 208 180 2015
                L       A, 0c4h                ; 479B 1 208 180 E5C4
                MUL                            ; 479D 1 208 180 9035
                L       A, er1                 ; 479F 1 208 180 35
                MOV     DP, #00004h            ; 47A0 1 208 180 620400
gear_detect_loop:     CMPC    A, GearCustom[X1]        ; 47A3 1 208 180 90AD2D65
                JLT     gear_detect_index_calc             ; 47A7 1 208 180 CA04
                INC     X1                     ; 47A9 1 208 180 70
                INC     X1                     ; 47AA 1 208 180 70
                JRNZ    DP, gear_detect_loop         ; 47AB 1 208 180 30F6
gear_detect_index_calc:     SRL     X1                     ; 47AD 1 208 180 90E7
                L       A, X1                  ; 47AF 1 208 180 40
                LB      A, ACC                 ; 47B0 0 208 180 F506
                ADDB    A, #001h               ; 47B2 0 208 180 8601
gear_detect_store:     STB     A, off(00251h)         ; 47B4 0 208 180 D451
                LCB     A, TipinGear[X1]        ; 47B6 0 208 180 90ABCF6D
                STB     A, off(00252h)         ; 47BA 0 208 180 D452
gear_detect_store_load_ram0db:     LB      A, 0dbh                ; 47BC 0 208 180 F5DB
                MOV     X1, #DwellBattery          ; 47BE 0 208 180 608A6C
                CAL     table_interp_lookup             ; 47C1 0 208 180 323958
                STB     A, off(0024dh)         ; 47C4 0 208 180 D44D
                VCAL    3                      ; 47C6 0 208 180 13
                JBS     off(00217h).4, dwell_battery_check2_clear_r0 ; 47C7 0 208 180 EC1710
                LB      A, 0beh                ; 47CA 0 208 180 F5BE
                CMPB    A, #04bh               ; 47CC 0 208 180 C64B
                JLT     dwell_battery_check2             ; 47CE 0 208 180 CA03
                SB      (00129h-00180h)[USP].3 ; 47D0 0 208 180 C3A91B
dwell_battery_check2:     CMPB    A, #04bh               ; 47D3 0 208 180 C64B
                JLT     dwell_battery_check2_clear_r0             ; 47D5 0 208 180 CA03
                SB      (00129h-00180h)[USP].0 ; 47D7 0 208 180 C3A918
dwell_battery_check2_clear_r0:     CLRB    r0                     ; 47DA 0 208 180 2015
                LCB     A, dwell_battery_check2_tbl            ; 47DC 0 208 180 909DF260
                JNE     dwell_battery_check2_goto_4865             ; 47E0 0 208 180 CE56
                L       A, #011f7h             ; 47E2 1 208 180 67F711
                JBS     off(00234h).0, dwell_battery_check2_cmp_ram0ce ; 47E5 1 208 180 E83403
                L       A, #0113fh             ; 47E8 1 208 180 673F11
dwell_battery_check2_cmp_ram0ce:     CMP     0ceh, A                ; 47EB 1 208 180 B5CEC1
                MB      off(00234h).0, C       ; 47EE 1 208 180 C43438
                L       A, #tbl_7b31           ; 47F1 1 208 180 67317B
                JBS     off(00234h).1, dwell_battery_check2_cmp_ram0ce_2 ; 47F4 1 208 180 E93403
                L       A, #0563ch                              ; 47F7 1 208 180 673C56
dwell_battery_check2_cmp_ram0ce_2:     CMP     0ceh, A                ; 47FA 1 208 180 B5CEC1
                MB      off(00234h).1, C       ; 47FD 1 208 180 C43439
                CLR     X1                     ; 4800 1 208 180 9015
                LB      A, #005h               ; 4802 0 208 180 7705
                JBS     off(00234h).2, dwell_battery_check2_addb_acc ; 4804 0 208 180 EA3402
                LB      A, #00ah               ; 4807 0 208 180 770A
dwell_battery_check2_addb_acc:     ADDB    A, 00311h[X1]          ; 4809 0 208 180 C0110382
                CMPB    A, 0d4h                ; 480D 0 208 180 C5D4C2
                MB      off(00234h).2, C       ; 4810 0 208 180 C4343A
                LB      A, off(00251h)         ; 4813 0 208 180 F451
                SLLB    A                      ; 4815 0 208 180 53
                EXTND                          ; 4816 1 208 180 F8
                LC      A, dwell_battery_check2_tbl_3[ACC]       ; 4817 1 208 180 B506A9A964
                CMPB    ACC, off(00238h)       ; 481C 1 208 180 C506C338
                JBS     off(00234h).3, dwell_battery_check2_store_carry_ram234_bit3 ; 4820 1 208 180 EB3404
                CMPB    ACCH, off(00238h)      ; 4823 1 208 180 C507C338
dwell_battery_check2_store_carry_ram234_bit3:     MB      off(00234h).3, C       ; 4827 1 208 180 C4343B
                LB      A, 003c9h[X1]          ; 482A 0 208 180 F0C903
                SLLB    A                      ; 482D 0 208 180 53
                JLT     dwell_battery_check2_load_tbl_x1             ; 482E 0 208 180 CA0A
                MOVB    (001e6h-00180h)[USP], #00ah ; 4830 0 208 180 C366980A
                CLRB    A                      ; 4834 0 208 180 FA
dwell_battery_check2_store_tbl_x1:     STB     A, 0031bh[X1]          ; 4835 0 208 180 D01B03
dwell_battery_check2_goto_4865:     SJ      dwell_battery_check2_srlb_r0             ; 4838 0 208 180 CB2B
dwell_battery_check2_load_tbl_x1:     LB      A, 0031bh[X1]          ; 483A 0 208 180 F01B03
                JNE     dwell_battery_check2_srlb_r0             ; 483D 0 208 180 CE26
                LB      A, (001e6h-00180h)[USP] ; 483F 0 208 180 F366
                JNE     dwell_battery_check2_srlb_r0             ; 4841 0 208 180 CE22
                MB      C, 0b0h.2              ; 4843 0 208 180 C5B02A
                JLT     dwell_battery_check2_srlb_r0             ; 4846 0 208 180 CA1D
                JBS     off(00212h).6, dwell_battery_check2_srlb_r0 ; 4848 0 208 180 EE121A
                MB      C, 0b1h.4              ; 484B 0 208 180 C5B12C
                JLT     dwell_battery_check2_srlb_r0             ; 484E 0 208 180 CA15
                JBS     off(00214h).0, dwell_battery_check2_srlb_r0 ; 4850 0 208 180 E81412
                LB      A, #0ffh               ; 4853 0 208 180 77FF
                JBS     off(00234h).0, dwell_battery_check2_store_tbl_x1 ; 4855 0 208 180 E834DD
                JBR     off(00234h).1, dwell_battery_check2_srlb_r0 ; 4858 0 208 180 D9340A
                JBR     off(00234h).2, dwell_battery_check2_srlb_r0 ; 485B 0 208 180 DA3407
                MOVB    r0, #001h              ; 485E 0 208 180 9801
                JBR     off(00234h).3, dwell_battery_check2_srlb_r0 ; 4860 0 208 180 DB3402
                MOVB    r0, #002h              ; 4863 0 208 180 9802
dwell_battery_check2_srlb_r0:     SRLB    r0                     ; 4865 0 208 180 20E7
                MB      off(00234h).4, C       ; 4867 0 208 180 C4343C
                SRLB    r0                     ; 486A 0 208 180 20E7
                MB      (0012dh-00180h)[USP].4, C ; 486C 0 208 180 C3AD3C
                LB      A, #0a0h               ; 486F 0 208 180 77A0
                JBS     off(00223h).2, dwell_battery_check2_cmp_acc ; 4871 0 208 180 EA2302
                LB      A, #0d8h               ; 4874 0 208 180 77D8
dwell_battery_check2_cmp_acc:     CMPB    A, off(00238h)         ; 4876 0 208 180 C738
                MB      off(00223h).2, C       ; 4878 0 208 180 C4233A
                CLR     A                      ; 487B 1 208 180 F9
                MOV     X1, #tbl_threshold_223_1          ; 487C 1 208 180 609364
                MOV     X2, #Revlimiters          ; 487F 1 208 180 619964
                JBR     off(0021fh).1, revlimit_table_select ; 4882 1 208 180 D91F06
                MOV     X1, #tbl_threshold_223_2          ; 4885 1 208 180 609F64
                MOV     X2, #dwell_battery_check2_tbl_2          ; 4888 1 208 180 61A564
revlimit_table_select:     LC      A, 00002h[X1]          ; 488B 1 208 180 90A90200
                MOV     DP, A                  ; 488F 1 208 180 52
                LC      A, 00002h[X2]          ; 4890 1 208 180 91A90200
                JBR     off(00217h).5, revlimit_table_select_if_ram214_bit0_set ; 4894 1 208 180 DD1706
                MOVB    (001ceh-00180h)[USP], #00ch ; 4897 1 208 180 C34E980C
                SJ      revlimit_table_select_and_ie             ; 489B 1 208 180 CB44
revlimit_table_select_if_ram214_bit0_set:     JBS     off(00214h).0, revlimit_table_select_and_ie ; 489D 1 208 180 E81441
                LB      A, (001d5h-00180h)[USP] ; 48A0 0 208 180 F355
                JNE     revlimit_table_select_load_ram0bc             ; 48A2 0 208 180 CE51
                MOVB    (001d5h-00180h)[USP], #014h ; 48A4 0 208 180 C3559814
                JBS     off(00212h).5, revlimit_table_select_if_ram223_bit2_clr ; 48A8 0 208 180 ED1206
                CMPB    0d9h, #044h            ; 48AB 0 208 180 C5D9C044
                JGE     revlimit_table_select_load_stk             ; 48AF 0 208 180 CD16
revlimit_table_select_if_ram223_bit2_clr:     JBR     off(00223h).2, revlimit_table_select_load_stk ; 48B1 0 208 180 DA2313
                LB      A, (001ceh-00180h)[USP] ; 48B4 0 208 180 F34E
                JNE     callhelper_sub37_clamp_to_er0             ; 48B6 0 208 180 CE13
                L       A, (001a6h-00180h)[USP] ; 48B8 1 208 180 E326
                CAL     add24_clamp_neg1             ; 48BA 1 208 180 32C25A
                MOV     DP, A                  ; 48BD 1 208 180 52
                L       A, (001a4h-00180h)[USP] ; 48BE 1 208 180 E324
                MOV     X1, X2                 ; 48C0 1 208 180 9178
                CAL     add24_clamp_neg1             ; 48C2 1 208 180 32C25A
                SJ      revlimit_table_select_and_ie             ; 48C5 1 208 180 CB1A
revlimit_table_select_load_stk:     MOVB    (001ceh-00180h)[USP], #00ch ; 48C7 0 208 180 C34E980C
callhelper_sub37_clamp_to_er0:     LC      A, 00002h[X1]          ; 48CB 0 208 180 90A90200
                MOV     er0, A                 ; 48CF 0 208 180 448A
                L       A, (001a6h-00180h)[USP] ; 48D1 1 208 180 E326
                CAL     sub37_clamp_to_er0             ; 48D3 1 208 180 32B85A
                MOV     DP, A                  ; 48D6 1 208 180 52
                LC      A, 00002h[X2]          ; 48D7 1 208 180 91A90200
                ST      A, er0                 ; 48DB 1 208 180 88
                L       A, (001a4h-00180h)[USP] ; 48DC 1 208 180 E324
                CAL     sub37_clamp_to_er0             ; 48DE 1 208 180 32B85A
revlimit_table_select_and_ie:     AND     IE, #002a0h            ; 48E1 1 208 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 48E6 1 208 180 A2D0FE
                ST      A, (001a4h-00180h)[USP] ; 48E9 1 208 180 D324
                L       A, DP                  ; 48EB 1 208 180 42
                ST      A, (001a6h-00180h)[USP] ; 48EC 1 208 180 D326
                ORB     PSWH, #001h            ; 48EE 1 208 180 A2E001
                L       A, 0f8h                ; 48F1 1 208 180 E5F8
                ST      A, IE                  ; 48F3 1 208 180 D51A
revlimit_table_select_load_ram0bc:     LB      A, 0bch                ; 48F5 0 208 180 F5BC
                MOV     X1, #tbl_revlimit_warm3          ; 48F7 0 208 180 608F64
                VCAL    1                      ; 48FA 0 208 180 11
                STB     A, (001ach-00180h)[USP] ; 48FB 0 208 180 D32C
                VCAL    3                      ; 48FD 0 208 180 13
                LB      A, 0bch                ; 48FE 0 208 180 F5BC
                MOV     X1, #tbl_revlimit_warm2          ; 4900 0 208 180 60CB62
                CAL     table_interp_lookup             ; 4903 0 208 180 323958
                STB     A, (00169h-00180h)[USP] ; 4906 0 208 180 D3E9
                LB      A, 0bch                ; 4908 0 208 180 F5BC
                MOV     X1, #tbl_revlimit_cold4          ; 490A 0 208 180 60A063
                VCAL    1                      ; 490D 0 208 180 11
                STB     A, (00183h-00180h)[USP] ; 490E 0 208 180 D303
                LB      A, 0bch                ; 4910 0 208 180 F5BC
                MOV     X1, #tbl_revlimit_warm1          ; 4912 0 208 180 603F62
                VCAL    1                      ; 4915 0 208 180 11
                STB     A, (00180h-00180h)[USP] ; 4916 0 208 180 D300
                LB      A, 0bch                ; 4918 0 208 180 F5BC
                MOV     X1, #revlimit_table_select_tbl          ; 491A 0 208 180 606665
                VCAL    1                      ; 491D 0 208 180 11
                STB     A, (00199h-00180h)[USP] ; 491E 0 208 180 D319
                VCAL    3                      ; 4920 0 208 180 13
                MOV     X1, #tbl_revlimit_cold1          ; 4921 0 208 180 60C361
                CMPB    0cch, #00fh            ; 4924 0 208 180 C5CCC00F
                JLT     iat_table_select             ; 4928 0 208 180 CA0C
                MOV     X1, #tbl_revlimit_cold2          ; 492A 0 208 180 60C761
                CMPB    0cch, #00fh            ; 492D 0 208 180 C5CCC00F
                JLT     iat_table_select             ; 4931 0 208 180 CA03
                MOV     X1, #tbl_revlimit_cold3          ; 4933 0 208 180 60CB61
iat_table_select:     LB      A, 0d8h                ; 4936 0 208 180 F5D8
; [H] --- Continues the correction chain: IAT (0xD8) indexed lookups into IATFuelCorrect,
; [H] IATScaler2, IATScaler (real calibration fields, IAT-based fuel correction factors),
; [H] results stored to a small working-RAM cluster at 0x3EA onward. Same VCAL 0/1/3 pattern as
; [H] the ECT correction chain earlier.
                VCAL    1                      ; 4938 0 208 180 11
                CMPB    0d9h, A                ; 4939 0 208 180 C5D9C1
                MB      off(00219h).1, C       ; 493C 0 208 180 C41939
                LB      A, 0d8h                ; 493F 0 208 180 F5D8
                MOV     X1, #IATFuelCorrect          ; 4941 0 208 180 607261
                VCAL    0                      ; 4944 0 208 180 10
                STB     A, (0015eh-00180h)[USP] ; 4945 0 208 180 D3DE
                VCAL    3                      ; 4947 0 208 180 13
                CLR     A                      ; 4948 1 208 180 F9
                LB      A, #0aah               ; 4949 0 208 180 77AA
                JBS     off(00223h).4, iat_table_select_cmp_acc ; 494B 0 208 180 EC2302
                LB      A, #0b0h               ; 494E 0 208 180 77B0
iat_table_select_cmp_acc:     CMPB    A, off(00238h)         ; 4950 0 208 180 C738
                MB      off(00223h).4, C       ; 4952 0 208 180 C4233C
                LCB     A, fuelmap_base_lookup_tbl            ; 4955 0 208 180 909DE560
                SRLB    A                      ; 4959 0 208 180 63
                SRLB    A                      ; 495A 0 208 180 63
                CLRB    r2                     ; 495B 0 208 180 2215
                MOV     DP, #003cah            ; 495D 0 208 180 62CA03
                LB      A, [DP]                ; 4960 0 208 180 F2
                JLT     knock_retard_check             ; 4961 0 208 180 CA23
                CMPB    A, #0f0h               ; 4963 0 208 180 C6F0
                JLT     knock_div_calc1             ; 4965 0 208 180 CA02
                LB      A, #076h               ; 4967 0 208 180 7776
knock_div_calc1:     MOVB    r0, #030h              ; 4969 0 208 180 9830
                DIVB                           ; 496B 0 208 180 A236
                JBS     off(00223h).4, knock_table_index ; 496D 0 208 180 EC230D
                SRLB    A                      ; 4970 0 208 180 63
                LB      A, r1                  ; 4971 0 208 180 79
                JGE     knock_div_calc2             ; 4972 0 208 180 CD03
                LB      A, #02fh               ; 4974 0 208 180 772F
                SUBB    A, r1                  ; 4976 0 208 180 29
knock_div_calc2:     MOVB    r0, #009h              ; 4977 0 208 180 9809
                DIVB                           ; 4979 0 208 180 A236
                ADDB    A, #006h               ; 497B 0 208 180 8606
knock_table_index:     SLLB    A                      ; 497D 0 208 180 53
                EXTND                          ; 497E 1 208 180 F8
                LC      A, knock_table_index_tbl[ACC]       ; 497F 1 208 180 B506A9B564
                SJ      knock_result_store             ; 4984 1 208 180 CB06
knock_retard_check:     ADDB    A, #080h               ; 4986 0 208 180 8680
                STB     A, r2                  ; 4988 0 208 180 8A
                L       A, #08000h             ; 4989 1 208 180 670080
knock_result_store:     ST      A, (00162h-00180h)[USP] ; 498C 1 208 180 D3E2
                MOVB    off(00244h), r2        ; 498E 1 208 180 227C44
                MOV     DP, #003d4h            ; 4991 1 208 180 62D403
                LB      A, [DP]                ; 4994 0 208 180 F2
                JBS     off(00219h).3, knock_result_store_addb_acc ; 4995 0 208 180 EB1902
                LB      A, 0e3h                ; 4998 0 208 180 F5E3
knock_result_store_addb_acc:     ADDB    A, #080h               ; 499A 0 208 180 8680
                STB     A, r0                  ; 499C 0 208 180 88
                LCB     A, idle_init_start_tbl            ; 499D 0 208 180 909DFB60
                JEQ     to_knock_div_calc3             ; 49A1 0 208 180 C90B
                LCB     A, fuelmap_base_lookup_tbl            ; 49A3 0 208 180 909DE560
                SRLB    A                      ; 49A7 0 208 180 63
                CLRB    A                      ; 49A8 0 208 180 FA
                XCHGB   A, r0                  ; 49A9 0 208 180 2010
                JLT     to_knock_div_calc3             ; 49AB 0 208 180 CA01
                CLRB    A                      ; 49AD 0 208 180 FA
to_knock_div_calc3:     STB     A, (0013fh-00180h)[USP] ; 49AE 0 208 180 D3BF
                LB      A, r0                  ; 49B0 0 208 180 78
                STB     A, (00149h-00180h)[USP] ; 49B1 0 208 180 D3C9
                CLRB    A                      ; 49B3 0 208 180 FA
                MOV     DP, #003d3h            ; 49B4 0 208 180 62D303
                LCB     A, fuelmap_base_lookup_tbl            ; 49B7 0 208 180 909DE560
                SRLB    A                      ; 49BB 0 208 180 63
                SRLB    A                      ; 49BC 0 208 180 63
                SRLB    A                      ; 49BD 0 208 180 63
                JGE     to_knock_div_calc3_srlb_acc             ; 49BE 0 208 180 CD07
                LB      A, [DP]                ; 49C0 0 208 180 F2
                ADDB    A, #080h               ; 49C1 0 208 180 8680
                CLR     er0                    ; 49C3 0 208 180 4415
                SJ      to_knock_div_calc3_store_ram29d             ; 49C5 0 208 180 CB0F
to_knock_div_calc3_srlb_acc:     SRLB    A                      ; 49C7 0 208 180 63
                JGE     to_knock_div_calc3_clear_acc             ; 49C8 0 208 180 CD16
                LB      A, [DP]                ; 49CA 0 208 180 F2
                MOVB    r0, #080h              ; 49CB 0 208 180 9880
                MULB                           ; 49CD 0 208 180 A234
                L       A, ACC                 ; 49CF 1 208 180 E506
                ADD     A, #0c000h             ; 49D1 1 208 180 8600C0
                ST      A, er0                 ; 49D4 1 208 180 88
                CLRB    A                      ; 49D5 0 208 180 FA
to_knock_div_calc3_store_ram29d:     STB     A, off(0029dh)         ; 49D6 0 208 180 D49D
                MOV     off(00286h), er0       ; 49D8 0 208 180 447C86
                CLR     A                      ; 49DB 1 208 180 F9
                LB      A, #076h               ; 49DC 0 208 180 7776
                SJ      knock_div_calc3             ; 49DE 0 208 180 CB0D
to_knock_div_calc3_clear_acc:     CLRB    A                      ; 49E0 0 208 180 FA
                STB     A, off(0029dh)         ; 49E1 0 208 180 D49D
                EXTND                          ; 49E3 1 208 180 F8
                ST      A, off(00286h)         ; 49E4 1 208 180 D486
                LB      A, [DP]                ; 49E6 0 208 180 F2
                CMPB    A, #0f0h               ; 49E7 0 208 180 C6F0
                JLT     knock_div_calc3             ; 49E9 0 208 180 CA02
                LB      A, #076h               ; 49EB 0 208 180 7776
knock_div_calc3:     MOVB    r0, #030h              ; 49ED 0 208 180 9830
                DIVB                           ; 49EF 0 208 180 A236
                STB     A, r2                  ; 49F1 0 208 180 8A
                SRLB    A                      ; 49F2 0 208 180 63
                LB      A, r1                  ; 49F3 0 208 180 79
                JGE     knock_div_calc4             ; 49F4 0 208 180 CD03
                LB      A, #02fh               ; 49F6 0 208 180 772F
                SUBB    A, r1                  ; 49F8 0 208 180 29
knock_div_calc4:     MOVB    r0, #009h              ; 49F9 0 208 180 9809
                DIVB                           ; 49FB 0 208 180 A236
                ADDB    A, #006h               ; 49FD 0 208 180 8606
                SLLB    A                      ; 49FF 0 208 180 53
                EXTND                          ; 4A00 1 208 180 F8
                MOV     X1, #tbl_knock_div          ; 4A01 1 208 180 60CD64
                JBR     off(00216h).3, knock_div_calc4_if_ram216_bit0_set ; 4A04 1 208 180 DB1603
                MOV     X1, #knock_div_calc4_tbl          ; 4A07 1 208 180 60FD64
knock_div_calc4_if_ram216_bit0_set:     JBS     off(00216h).0, knock_table2d_lookup ; 4A0A 1 208 180 E81604
                ADD     X1, #00018h            ; 4A0D 1 208 180 90801800
knock_table2d_lookup:     MOV     X2, X1                 ; 4A11 1 208 180 9079
                ADD     X1, A                  ; 4A13 1 208 180 9081
                LC      A, [X1]                ; 4A15 1 208 180 90A8
                ST      A, er0                 ; 4A17 1 208 180 88
                LB      A, r2                  ; 4A18 0 208 180 7A
                SLLB    A                      ; 4A19 0 208 180 53
                EXTND                          ; 4A1A 1 208 180 F8
                ADD     X2, A                  ; 4A1B 1 208 180 9181
                LC      A, [X2]                ; 4A1D 1 208 180 91A8
                AND     IE, #002a0h            ; 4A1F 1 208 180 B51AD0A002
                ANDB    PSWH, #0feh            ; 4A24 1 208 180 A2D0FE
                ST      A, (00178h-00180h)[USP] ; 4A27 1 208 180 D3F8
                L       A, er0                 ; 4A29 1 208 180 34
                ST      A, (0017ah-00180h)[USP] ; 4A2A 1 208 180 D3FA
                ORB     PSWH, #001h            ; 4A2C 1 208 180 A2E001
                L       A, 0f8h                ; 4A2F 1 208 180 E5F8
                ST      A, IE                  ; 4A31 1 208 180 D51A
                CLR     A                      ; 4A33 1 208 180 F9
                MOV     DP, #003cch            ; 4A34 1 208 180 62CC03
                LB      A, [DP]                ; 4A37 0 208 180 F2
                L       A, ACC                 ; 4A38 1 208 180 E506
                ADD     A, #0001fh             ; 4A3A 1 208 180 861F00
                SLL     A                      ; 4A3D 1 208 180 53
                SLL     A                      ; 4A3E 1 208 180 53
                LB      A, ACCH                ; 4A3F 0 208 180 F507
                EXTND                          ; 4A41 1 208 180 F8
                LCB     A, knock_table2d_lookup_tbl_2[ACC]       ; 4A42 1 208 180 B506AB3565
                MOV     DP, #00392h            ; 4A47 1 208 180 629203
                LB      A, ACC                 ; 4A4A 0 208 180 F506
                STB     A, [DP]                ; 4A4C 0 208 180 D2
                LB      A, 0dbh                ; 4A4D 0 208 180 F5DB
                MOV     X1, #knock_table2d_lookup_tbl          ; 4A4F 0 208 180 60E362
                VCAL    0                      ; 4A52 0 208 180 10
                STB     A, (00144h-00180h)[USP] ; 4A53 0 208 180 D3C4
                VCAL    3                      ; 4A55 0 208 180 13
                MOV     DP, #003c6h            ; 4A56 0 208 180 62C603
                LB      A, [DP]                ; 4A59 0 208 180 F2
                STB     A, 0dah                ; 4A5A 0 208 180 D5DA
                JBR     off(00219h).3, injidx_gate2 ; 4A5C 0 208 180 DB1916
                MOV     DP, #003abh            ; 4A5F 0 208 180 62AB03
                LB      A, [DP]                ; 4A62 0 208 180 F2
                CMPB    A, #031h               ; 4A63 0 208 180 C631
                JNE     injidx_gate1             ; 4A65 0 208 180 CE0B
                SB      off(00223h).3          ; 4A67 0 208 180 C4231B
                SB      off(00219h).0          ; 4A6A 0 208 180 C41918
                RB      off(00223h).1          ; 4A6D 0 208 180 C42309
                SJ      injidx_flag_set             ; 4A70 0 208 180 CB0C
injidx_gate1:     JBR     off(00223h).3, injidx_gate3 ; 4A72 0 208 180 DB230F
injidx_gate2:     RB      off(00223h).3          ; 4A75 0 208 180 C4230B
injidx_flag_clear:     RB      off(00219h).0          ; 4A78 0 208 180 C41908
                SB      off(00223h).1          ; 4A7B 0 208 180 C42319
injidx_flag_set:     SB      off(00223h).0          ; 4A7E 0 208 180 C42318
                J       vss_ect_stamp             ; 4A81 0 208 180 030B4B
injidx_gate3:     JBS     off(00219h).4, injidx_flag_clear ; 4A84 0 208 180 EC19F1
                JBS     off(0021dh).4, injidx_flag_clear ; 4A87 0 208 180 EC1DEE
                LB      A, off(002cdh)         ; 4A8A 0 208 180 F4CD
                JEQ     injidx_gate4             ; 4A8C 0 208 180 C90F
                RB      off(00219h).0          ; 4A8E 0 208 180 C41908
                RB      off(00223h).1          ; 4A91 0 208 180 C42309
injidx_flag_set2:     RB      off(00223h).0          ; 4A94 0 208 180 C42308
                MOVB    off(002ceh), #064h     ; 4A97 0 208 180 C4CE9864
                SJ      vss_ect_stamp             ; 4A9B 0 208 180 CB6E
injidx_gate4:     JBS     off(00217h).5, injidx_flag_set2 ; 4A9D 0 208 180 ED17F4
                JBS     off(00219h).0, vss_ect_gate ; 4AA0 0 208 180 E81947
                JBR     off(00223h).1, injidx_gate6 ; 4AA3 0 208 180 D92312
                JBS     off(00216h).6, injidx_gate5 ; 4AA6 0 208 180 EE1603
                JBS     off(00218h).0, vss_ect_gate ; 4AA9 0 208 180 E8183E
injidx_gate5:     JBR     off(0021dh).2, vss_ect_gate ; 4AAC 0 208 180 DA1D3B
                RB      off(00219h).0          ; 4AAF 0 208 180 C41908
                RB      off(00223h).1          ; 4AB2 0 208 180 C42309
                SB      off(00223h).0          ; 4AB5 0 208 180 C42318
injidx_gate6:     JBR     off(00216h).6, closeloopnarrow_check ; 4AB8 0 208 180 DE1620
                JBS     off(00219h).0, closeloopnarrow_check ; 4ABB 0 208 180 E8191D
                JBS     off(00223h).1, closeloopnarrow_check ; 4ABE 0 208 180 E9231A
                JBS     off(00223h).0, closeloopnarrow_check ; 4AC1 0 208 180 E82317
                JBR     off(00219h).2, injidx_stamp_c2 ; 4AC4 0 208 180 DA1906
                JBR     off(00219h).1, injidx_stamp_c2 ; 4AC7 0 208 180 D91903
                JBS     off(0021dh).2, injidx_c2_check ; 4ACA 0 208 180 EA1D06
injidx_stamp_c2:     MOVB    off(002ceh), #064h     ; 4ACD 0 208 180 C4CE9864
                SJ      closeloopnarrow_check             ; 4AD1 0 208 180 CB08
injidx_c2_check:     LB      A, off(002ceh)         ; 4AD3 0 208 180 F4CE
                JNE     closeloopnarrow_check             ; 4AD5 0 208 180 CE04
                LB      A, #02eh               ; 4AD7 0 208 180 772E
                SJ      closeloopnarrow_result             ; 4AD9 0 208 180 CB07
closeloopnarrow_check:     LB      A, #01ah               ; 4ADB 0 208 180 771A
                JBS     off(00216h).0, closeloopnarrow_result ; 4ADD 0 208 180 E81602
                LB      A, #01ah               ; 4AE0 0 208 180 771A
closeloopnarrow_result:     CMPB    A, 0dah                ; 4AE2 0 208 180 C5DAC2
                JLT     vss_ect_gate             ; 4AE5 0 208 180 CA03
                SB      off(00219h).0          ; 4AE7 0 208 180 C41918
vss_ect_gate:     CMPB    0d9h, #028h            ; 4AEA 0 208 180 C5D9C028
                JGE     vss_ect_stamp             ; 4AEE 0 208 180 CD1B
                CMPB    0cch, #005h            ; 4AF0 0 208 180 C5CCC005
                JGE     vss_ect_stamp             ; 4AF4 0 208 180 CD15
                CMPB    off(00238h), #080h     ; 4AF6 0 208 180 C438C080
                JLT     vss_ect_stamp             ; 4AFA 0 208 180 CA0F
                JBR     off(0021dh).2, vss_ect_stamp ; 4AFC 0 208 180 DA1D0C
                LB      A, off(002b5h)         ; 4AFF 0 208 180 F4B5
                JNE     idle_state_defaults             ; 4B01 0 208 180 CE0C
                SB      off(00219h).0          ; 4B03 0 208 180 C41918
                RB      off(00223h).1          ; 4B06 0 208 180 C42309
                SJ      idle_state_defaults             ; 4B09 0 208 180 CB04
vss_ect_stamp:     MOVB    off(002b5h), #004h     ; 4B0B 0 208 180 C4B59804
idle_state_defaults:     MOVB    r0, #005h              ; 4B0F 0 208 180 9805
                MOVB    r1, #032h              ; 4B11 0 208 180 9932
                MOVB    r2, #032h              ; 4B13 0 208 180 9A32
                MOVB    r3, #01bh              ; 4B15 0 208 180 9B1B
                JBS     off(00216h).0, idle_state_defaults_if_ram21d_bit1_clr ; 4B17 0 208 180 E81602
                MOVB    r3, #01bh              ; 4B1A 0 208 180 9B1B
idle_state_defaults_if_ram21d_bit1_clr:     JBR     off(0021dh).1, idle_stage_alt_start ; 4B1C 0 208 180 D91D28
                JBR     off(00218h).0, idle_stage_alt_start ; 4B1F 0 208 180 D81825
                MOVB    off(002cbh), r1        ; 4B22 0 208 180 217CCB
                MOVB    off(002cch), r2        ; 4B25 0 208 180 227CCC
                JBR     off(00219h).0, idle_stage_b7_store ; 4B28 0 208 180 D81915
                JBS     off(0021eh).4, idle_state_defaults_goto_78d9 ; 4B2B 0 208 180 EC1E43
                L       A, (0015ah-00180h)[USP] ; 4B2E 1 208 180 E3DA
                CMP     A, #0bc15h             ; 4B30 1 208 180 C615BC
                JGE     idle_state_defaults_goto_78d9             ; 4B33 1 208 180 CD3C
                CMP     A, #05e20h             ; 4B35 1 208 180 C6205E
                JLE     idle_state_defaults_goto_78d9             ; 4B38 1 208 180 CF37
                LB      A, r3                  ; 4B3A 0 208 180 7B
                CMPB    A, 0dah                ; 4B3B 0 208 180 C5DAC2
                JLT     idle_stage_b7_load             ; 4B3E 0 208 180 CA03
idle_stage_b7_store:     MOVB    off(002b6h), r0        ; 4B40 0 208 180 207CB6
idle_stage_b7_load:     LB      A, off(002b6h)         ; 4B43 0 208 180 F4B6
                SJ      idle_stage_c0_load_goto_78e6             ; 4B45 0 208 180 CB27
idle_stage_alt_start:     MOVB    off(002b6h), r0        ; 4B47 0 208 180 207CB6
                JBR     off(0021ch).2, idle_stage_c0_start ; 4B4A 0 208 180 DA1C13
                MOVB    off(002cch), r2        ; 4B4D 0 208 180 227CCC
                JBR     off(00219h).0, idle_stage_bf_store ; 4B50 0 208 180 D81906
                LB      A, r3                  ; 4B53 0 208 180 7B
                CMPB    A, 0dah                ; 4B54 0 208 180 C5DAC2
                JLT     idle_stage_bf_load             ; 4B57 0 208 180 CA03
idle_stage_bf_store:     MOVB    off(002cbh), r1        ; 4B59 0 208 180 217CCB
idle_stage_bf_load:     LB      A, off(002cbh)         ; 4B5C 0 208 180 F4CB
                SJ      idle_stage_c0_load_goto_78e6             ; 4B5E 0 208 180 CB0E
idle_stage_c0_start:     MOVB    off(002cbh), r1        ; 4B60 0 208 180 217CCB
                JBR     off(00219h).0, idle_stage_c0_store ; 4B63 0 208 180 D81903
                JBR     off(0021ch).6, idle_stage_c0_load ; 4B66 0 208 180 DE1C03
idle_stage_c0_store:     MOVB    off(002cch), r2        ; 4B69 0 208 180 227CCC
idle_stage_c0_load:     LB      A, off(002cch)         ; 4B6C 0 208 180 F4CC
idle_stage_c0_load_goto_78e6:     J       idle_stage_c0_load_load_ram2ef             ; 4B6E 0 208 180 03E678
idle_state_defaults_goto_78d9:     J       idle_state_defaults_cmp_ram0da             ; 4B71 0 208 180 03D978
                DW  00000h           ; 4B74
gio_fuelpump_dispatch:     VCAL    3                      ; 4B76 0 208 180 13
                RC                             ; 4B77 0 208 180 95
                LB      A, off(002d1h)         ; 4B78 0 208 180 F4D1
                JNE     fuelpump_relay_drive             ; 4B7A 0 208 180 CE06
                JBS     off(00211h).0, fuelpump_relay_drive ; 4B7C 0 208 180 E81103
                MB      C, off(00217h).4       ; 4B7F 0 208 180 C4172C
fuelpump_relay_drive:     MB      P0.7, C                ; 4B82 0 208 180 C5203F
                JBS     off(00210h).7, fuelpump_done ; 4B85 0 208 180 EF102D
                JBS     off(00218h).6, fuelpump_state_active ; 4B88 0 208 180 EE1826
                MOV     DP, #003d1h            ; 4B8B 0 208 180 62D103
                LB      A, [DP]                ; 4B8E 0 208 180 F2
                CMPB    A, #0ffh               ; 4B8F 0 208 180 C6FF
                JGT     fuelpump_gate4             ; 4B91 0 208 180 C804
                CMPB    A, #0fch               ; 4B93 0 208 180 C6FC
                JGE     fuelpump_gate4_rom_load_tbl_60fb             ; 4B95 0 208 180 CD03
fuelpump_gate4:     JBS     off(00230h).6, fuelpump_state_active ; 4B97 0 208 180 EE3017
fuelpump_gate4_rom_load_tbl_60fb:     LCB     A, idle_init_start_tbl            ; 4B9A 0 208 180 909DFB60
                JEQ     fuelpump_gate4_if_ram211_bit0_set             ; 4B9E 0 208 180 C904
                LB      A, 0afh                ; 4BA0 0 208 180 F5AF
                JNE     fuelpump_state_active             ; 4BA2 0 208 180 CE0D
fuelpump_gate4_if_ram211_bit0_set:     JBS     off(00211h).0, fuelpump_state_store ; 4BA4 0 208 180 E81103
                JBS     off(00217h).4, fuelpump_state_check ; 4BA7 0 208 180 EC1702
fuelpump_state_store:     STB     A, off(002d1h)         ; 4BAA 0 208 180 D4D1
fuelpump_state_check:     RC                             ; 4BAC 0 208 180 95
                LB      A, off(002d1h)         ; 4BAD 0 208 180 F4D1
                JEQ     fuelpump_state_active_store_carry_p1_bit4             ; 4BAF 0 208 180 C901
fuelpump_state_active:     SC                             ; 4BB1 0 208 180 85
fuelpump_state_active_store_carry_p1_bit4:     MB      P1.4, C                ; 4BB2 0 208 180 C5223C
fuelpump_done:     LB      A, #07eh               ; 4BB5 0 208 180 777E
                JBS     off(00226h).0, rpm_threshold_226_0 ; 4BB7 0 208 180 E82602
                LB      A, #082h               ; 4BBA 0 208 180 7782
rpm_threshold_226_0:     CMPB    A, 0cch                ; 4BBC 0 208 180 C5CCC2
                MB      off(00226h).0, C       ; 4BBF 0 208 180 C42638
                LB      A, #010h               ; 4BC2 0 208 180 7710
                JBS     off(00226h).1, rpm_threshold_226_1 ; 4BC4 0 208 180 E92602
                LB      A, #020h               ; 4BC7 0 208 180 7720
rpm_threshold_226_1:     CMPB    A, 0cch                ; 4BC9 0 208 180 C5CCC2
                MB      off(00226h).1, C       ; 4BCC 0 208 180 C42639
                LB      A, #033h               ; 4BCF 0 208 180 7733
                JBS     off(00226h).2, tps_threshold_226_2 ; 4BD1 0 208 180 EA2602
                LB      A, #080h               ; 4BD4 0 208 180 7780
tps_threshold_226_2:     CMPB    A, 0d1h                ; 4BD6 0 208 180 C5D1C2
                MB      off(00226h).2, C       ; 4BD9 0 208 180 C4263A
                LB      A, #0c8h               ; 4BDC 0 208 180 77C8
                JBS     off(00226h).3, tps_threshold_226_2_cmp_acc ; 4BDE 0 208 180 EB2602
                LB      A, #0d0h               ; 4BE1 0 208 180 77D0
tps_threshold_226_2_cmp_acc:     CMPB    A, off(00238h)         ; 4BE3 0 208 180 C738
                MB      off(00226h).3, C       ; 4BE5 0 208 180 C4263B
                L       A, #00ea6h             ; 4BE8 1 208 180 67A60E
                JBS     off(00226h).5, accut_rpm_gate ; 4BEB 1 208 180 ED2603
                L       A, #00c35h             ; 4BEE 1 208 180 67350C
accut_rpm_gate:     CMP     0c4h, A                ; 4BF1 1 208 180 B5C4C1
                MB      off(00226h).5, C       ; 4BF4 1 208 180 C4263D
                CMPB    0f3h, #014h            ; 4BF7 1 208 180 C5F3C014
                JLT     accut_reset_c3             ; 4BFB 1 208 180 CA3C
                JBS     off(00218h).7, accut_alt_gate ; 4BFD 1 208 180 EF181D
                CMPB    0d9h, #015h            ; 4C00 1 208 180 C5D9C015
                JGE     accut_gate2             ; 4C04 1 208 180 CD06
                JBR     off(00226h).0, accut_gate2 ; 4C06 1 208 180 D82603
                JBS     off(00226h).3, accut_reset_f7 ; 4C09 1 208 180 EB2630
accut_gate2:     JBS     off(00226h).2, accut_check_c3 ; 4C0C 1 208 180 EA260A
                CLRB    A                      ; 4C0F 0 208 180 FA
                JBS     off(00226h).1, accut_store_c3 ; 4C10 0 208 180 E92602
                LB      A, #032h               ; 4C13 0 208 180 7732
accut_store_c3:     STB     A, off(002cfh)         ; 4C15 0 208 180 D4CF
                SJ      accut_alt_gate             ; 4C17 0 208 180 CB04
accut_check_c3:     LB      A, off(002cfh)         ; 4C19 0 208 180 F4CF
                JNE     accut_reset_f7             ; 4C1B 0 208 180 CE1F
accut_alt_gate:     JBS     off(00226h).5, accut_gio_check ; 4C1D 1 208 180 ED2605
                RB      off(00226h).4          ; 4C20 1 208 180 C4260C
                SJ      accut_result_common             ; 4C23 1 208 180 CB25
accut_gio_check:     JBR     off(00211h).2, accut_common ; 4C25 1 208 180 DA1117
                SB      off(00226h).4          ; 4C28 1 208 180 C4261C
                LB      A, off(002c4h)         ; 4C2B 0 208 180 F4C4
                JNE     accut_result_common             ; 4C2D 0 208 180 CE1B
                MOVB    off(002c5h), #01eh     ; 4C2F 0 208 180 C4C5981E
accut_delay_check:     SB      off(0021bh).0          ; 4C33 0 208 180 C41B18
                RC                             ; 4C36 0 208 180 95
                SJ      accut_output_drive             ; 4C37 0 208 180 CB15
accut_reset_c3:     CLRB    off(002cfh)            ; 4C39 1 208 180 C4CF15
accut_reset_f7:     CLRB    off(002c5h)            ; 4C3C 1 208 180 C4C515
accut_common:     RB      off(00226h).4          ; 4C3F 1 208 180 C4260C
                LB      A, off(002c5h)         ; 4C42 0 208 180 F4C5
                JNE     accut_delay_check             ; 4C44 0 208 180 CEED
                MOVB    off(002c4h), #023h     ; 4C46 0 208 180 C4C49823
accut_result_common:     RB      off(0021bh).0          ; 4C4A 0 208 180 C41B08
                SC                             ; 4C4D 0 208 180 85
accut_output_drive:     MB      P0.0, C                ; 4C4E 0 208 180 C52038
                J       accut_output_drive_load_imm             ; 4C51 0 208 180 03A77B
accut_output_drive_if_ram212_bit5_set:     JBS     off(00212h).5, accut_output_drive_goto_purge_gate2 ; 4C54 0 208 180 ED1206
                CMPB    0d9h, #035h            ; 4C57 0 208 180 C5D9C035
                JGE     purge_result_clear             ; 4C5B 0 208 180 CD1C
accut_output_drive_goto_purge_gate2:     J       purge_gate2             ; 4C5D 0 208 180 03C77B
                DB  0FFh,0FFh,0FFh ; 4C60
purge_counter_check:     CMP     (001b8h-00180h)[USP], #005dch ; 4C63 0 208 180 B338C0DC05
                JLT     purge_result_clear             ; 4C68 0 208 180 CA0F
                CMPB    off(002b3h), #005h     ; 4C6A 0 208 180 C4B3C005
                JNE     purge_result_set             ; 4C6E 0 208 180 CE06
                CMPB    off(002d2h), #019h     ; 4C70 0 208 180 C4D2C019
                JLT     purge_result_clear             ; 4C74 0 208 180 CA03
purge_result_set:     SC                             ; 4C76 0 208 180 85
                SJ      purge_invert_result             ; 4C77 0 208 180 CB01
purge_result_clear:     RC                             ; 4C79 0 208 180 95
purge_invert_result:     MB      P0.1, C                ; 4C7A 0 208 180 C52039
                VCAL    3                      ; 4C7D 0 208 180 13
                LB      A, #046h               ; 4C7E 0 208 180 7746
                MOVB    r1, #046h              ; 4C80 0 208 180 9946
                JBS     off(00224h).0, purge_invert_result_if_ram216_bit3_set ; 4C82 0 208 180 E82404
                LB      A, #053h               ; 4C85 0 208 180 7753
                MOVB    r1, #053h              ; 4C87 0 208 180 9953
purge_invert_result_if_ram216_bit3_set:     JBS     off(00216h).3, purge_invert_result_cmp_acc ; 4C89 0 208 180 EB1601
                LB      A, r1                  ; 4C8C 0 208 180 79
purge_invert_result_cmp_acc:     CMPB    A, off(00238h)         ; 4C8D 0 208 180 C738
                MB      off(00224h).0, C       ; 4C8F 0 208 180 C42438
                LB      A, #090h               ; 4C92 0 208 180 7790
                JBS     off(00224h).1, purge_invert_result_cmp_acc_2 ; 4C94 0 208 180 E92402
                LB      A, #0a0h               ; 4C97 0 208 180 77A0
purge_invert_result_cmp_acc_2:     CMPB    A, off(00238h)         ; 4C99 0 208 180 C738
                MB      off(00224h).1, C       ; 4C9B 0 208 180 C42439
                MOVB    r0, 0cch               ; 4C9E 0 208 180 C5CC48
                LB      A, #00ch               ; 4CA1 0 208 180 770C
                JBS     off(00224h).2, vss_band_224_2_check ; 4CA3 0 208 180 EA2402
                LB      A, #00fh               ; 4CA6 0 208 180 770F
vss_band_224_2_check:     CMPB    A, r0                  ; 4CA8 0 208 180 48
                MB      off(00224h).2, C       ; 4CA9 0 208 180 C4243A
                LB      A, #049h               ; 4CAC 0 208 180 7749
                JBS     off(00224h).3, vss_band_224_3_check ; 4CAE 0 208 180 EB2402
                LB      A, #04bh               ; 4CB1 0 208 180 774B
vss_band_224_3_check:     CMPB    A, r0                  ; 4CB3 0 208 180 48
                MB      off(00224h).3, C       ; 4CB4 0 208 180 C4243B
                LB      A, #02dh               ; 4CB7 0 208 180 772D
                JBS     off(00224h).4, vss_band_224_4_check ; 4CB9 0 208 180 EC2402
                LB      A, #02fh               ; 4CBC 0 208 180 772F
vss_band_224_4_check:     CMPB    A, r0                  ; 4CBE 0 208 180 48
                MB      off(00224h).4, C       ; 4CBF 0 208 180 C4243C
                LB      A, #088h               ; 4CC2 0 208 180 7788
                JBS     off(00224h).5, vss_band_224_5_check ; 4CC4 0 208 180 ED2402
                LB      A, #080h               ; 4CC7 0 208 180 7780
vss_band_224_5_check:     CMPB    0dfh, A                ; 4CC9 0 208 180 C5DFC1
                MB      off(00224h).5, C       ; 4CCC 0 208 180 C4243D
                LB      A, #029h               ; 4CCF 0 208 180 7729
                JBS     off(00224h).6, ect_threshold_224_6 ; 4CD1 0 208 180 EE2402
                LB      A, #026h               ; 4CD4 0 208 180 7726
ect_threshold_224_6:     CMPB    0d9h, A                ; 4CD6 0 208 180 C5D9C1
                MB      off(00224h).6, C       ; 4CD9 0 208 180 C4243E
                SB      PSWL.4                 ; 4CDC 0 208 180 A31C
                JBR     off(00217h).6, state225_1_set ; 4CDE 0 208 180 DE172B
                JBS     off(00217h).4, state225_1_set ; 4CE1 0 208 180 EC1728
                LCB     A, ect_threshold_224_6_tbl            ; 4CE4 0 208 180 909DF960
                JNE     ect_threshold_224_6_if_ram218_bit7_clr             ; 4CE8 0 208 180 CE1F
                JBS     off(00212h).5, ect_threshold_224_6_clear_pswl_bit4 ; 4CEA 0 208 180 ED121A
                MOV     DP, #003d0h            ; 4CED 0 208 180 62D003
                CMPB    [DP], #0ffh            ; 4CF0 0 208 180 C2C0FF
                JLT     ect_threshold_224_6_cmp_dp_ind             ; 4CF3 0 208 180 CA05
                CLRB    off(002bdh)            ; 4CF5 0 208 180 C4BD15
                SJ      ect_threshold_224_6_if_ram218_bit7_clr             ; 4CF8 0 208 180 CB0F
ect_threshold_224_6_cmp_dp_ind:     CMPB    [DP], #0ffh            ; 4CFA 0 208 180 C2C0FF
                JGE     ect_threshold_224_6_load_ram2bd             ; 4CFD 0 208 180 CD04
                MOVB    off(002bdh), #0ffh     ; 4CFF 0 208 180 C4BD98FF
ect_threshold_224_6_load_ram2bd:     LB      A, off(002bdh)         ; 4D03 0 208 180 F4BD
                JEQ     ect_threshold_224_6_if_ram218_bit7_clr             ; 4D05 0 208 180 C902
ect_threshold_224_6_clear_pswl_bit4:     RB      PSWL.4                 ; 4D07 0 208 180 A30C
ect_threshold_224_6_if_ram218_bit7_clr:     JBR     off(00218h).7, state_dispatch2 ; 4D09 0 208 180 DF1806
state225_1_set:     SB      off(00225h).1          ; 4D0C 0 208 180 C42519
                J       state_result_clear5             ; 4D0F 0 208 180 03AE4D
state_dispatch2:     JBR     off(00224h).2, state_cce_set2b ; 4D12 0 208 180 DA242B
                JBS     off(0021ch).2, state_dispatch3 ; 4D15 0 208 180 EA1C06
                JBR     off(00216h).3, state_cce_set2b ; 4D18 0 208 180 DB1625
                JBR     off(0021eh).1, state_cce_set2b ; 4D1B 0 208 180 D91E22
state_dispatch3:     JBR     off(00224h).0, state_cce_set2b ; 4D1E 0 208 180 D8241F
                JBS     off(00224h).4, state_dispatch3_load_ram2d5 ; 4D21 0 208 180 EC2412
                JBR     off(00224h).6, state_dispatch3_load_ram2d5 ; 4D24 0 208 180 DE240F
                JBS     off(00225h).0, state_dispatch3_load_ram2d5 ; 4D27 0 208 180 E8250C
                LB      A, off(002d5h)         ; 4D2A 0 208 180 F4D5
                JNE     state_cce_set2b_load_ram2d6             ; 4D2C 0 208 180 CE16
                MOVB    off(002d6h), #003h     ; 4D2E 0 208 180 C4D69803
state_cce_set2b_clear_pswl_bit4:     RB      PSWL.4                 ; 4D32 0 208 180 A30C
                SJ      state_ccc_set9             ; 4D34 0 208 180 CB04
state_dispatch3_load_ram2d5:     MOVB    off(002d5h), #002h     ; 4D36 0 208 180 C4D59802
state_ccc_set9:     MOVB    off(002d3h), #005h     ; 4D3A 0 208 180 C4D39805
                SJ      state_2ba_reset             ; 4D3E 0 208 180 CB56
state_cce_set2b:     MOVB    off(002d5h), #002h     ; 4D40 0 208 180 C4D59802
state_cce_set2b_load_ram2d6:     LB      A, off(002d6h)         ; 4D44 0 208 180 F4D6
                JNE     state_cce_set2b_clear_pswl_bit4             ; 4D46 0 208 180 CEEA
                JBR     off(00222h).6, state_cce_set2b_load_ram2d3 ; 4D48 0 208 180 DE2202
                RB      PSWL.4                 ; 4D4B 0 208 180 A30C
state_cce_set2b_load_ram2d3:     LB      A, off(002d3h)         ; 4D4D 0 208 180 F4D3
                JEQ     state_ccc_check             ; 4D4F 0 208 180 C905
                JBR     off(00225h).0, state_dispatch4 ; 4D51 0 208 180 D82521
                SJ      state_2ba_reset             ; 4D54 0 208 180 CB40
state_ccc_check:     JBR     off(00224h).5, state_ccc_check_if_ram216_bit3_clr ; 4D56 0 208 180 DD2409
                MOVB    off(002d4h), #014h     ; 4D59 0 208 180 C4D49814
to_state_2ba_reset:     SB      off(00225h).0          ; 4D5D 0 208 180 C42518
                SJ      state_2ba_reset             ; 4D60 0 208 180 CB34
state_ccc_check_if_ram216_bit3_clr:     JBR     off(00216h).3, state_ccc_check_load_ram2d4 ; 4D62 0 208 180 DB1603
                JBS     off(00211h).5, to_state_2ba_reset ; 4D65 0 208 180 ED11F5
state_ccc_check_load_ram2d4:     LB      A, off(002d4h)         ; 4D68 0 208 180 F4D4
                JNE     state_2ba_reset             ; 4D6A 0 208 180 CE2A
                JBS     off(00224h).2, state_225_0_clear ; 4D6C 0 208 180 EA2403
                JBS     off(00225h).0, state_2ba_reset ; 4D6F 0 208 180 E82524
state_225_0_clear:     RB      off(00225h).0          ; 4D72 0 208 180 C42508
state_dispatch4:     JBS     off(00224h).3, state_225_1_check ; 4D75 0 208 180 EB2422
                JBS     off(00224h).1, state_225_1_check ; 4D78 0 208 180 E9241F
                CMPB    0d9h, #029h            ; 4D7B 0 208 180 C5D9C029
                JGE     state_225_1_check             ; 4D7F 0 208 180 CD19
                CMPB    0d8h, #0a9h            ; 4D81 0 208 180 C5D8C0A9
                JGE     state_225_1_check             ; 4D85 0 208 180 CD13
                JBS     off(00211h).2, state_225_1_check ; 4D87 0 208 180 EA1110
                LB      A, off(002b9h)         ; 4D8A 0 208 180 F4B9
                JEQ     state_225_1_check             ; 4D8C 0 208 180 C90C
                RB      off(00225h).1          ; 4D8E 0 208 180 C42509
state_result_set5:     SB      P0.2                   ; 4D91 0 208 180 C5201A
                SJ      altc2_normal_drive             ; 4D94 0 208 180 CB1B
state_2ba_reset:     MOVB    off(002b9h), #016h     ; 4D96 0 208 180 C4B99816
state_225_1_check:     JBS     off(00225h).1, state_225_1_check_load_ram2d7 ; 4D9A 0 208 180 E92507
                SB      off(00225h).1          ; 4D9D 0 208 180 C42519
                MOVB    off(002d7h), #003h     ; 4DA0 0 208 180 C4D79803
state_225_1_check_load_ram2d7:     LB      A, off(002d7h)         ; 4DA4 0 208 180 F4D7
                JNE     state_result_set5             ; 4DA6 0 208 180 CEE9
                CMPB    off(0029bh), #000h     ; 4DA8 0 208 180 C49BC000
                JGT     state_result_set5             ; 4DAC 0 208 180 C8E3
state_result_clear5:     RB      P0.2                   ; 4DAE 0 208 180 C5200A
altc2_normal_drive:     MB      C, PSWL.4              ; 4DB1 0 208 180 A32C
                MB      P0.3, C                ; 4DB3 0 208 180 C5203B
                VCAL    3                      ; 4DB6 0 208 180 13
                JBS     off(00227h).3, altc_normal_drive_if_ram219_bit3_clr ; 4DB7 0 208 180 EB272C
                JBS     off(00217h).3, altc_normal_drive_if_ram219_bit3_clr ; 4DBA 0 208 180 EB1729
                JBR     off(00216h).3, altc_normal_drive_if_ram219_bit3_clr ; 4DBD 0 208 180 DB1626
                MOVB    r0, #0feh              ; 4DC0 0 208 180 98FE
                JBS     off(00226h).7, altc2_normal_drive_load_adcr7h ; 4DC2 0 208 180 EF2602
                MOVB    r0, #0ffh              ; 4DC5 0 208 180 98FF
altc2_normal_drive_load_adcr7h:     LB      A, ADCR7H              ; 4DC7 0 208 180 F56F
                CMPB    r0, A                  ; 4DC9 0 208 180 20C1
                MB      off(00226h).7, C       ; 4DCB 0 208 180 C4263F
                JBR     off(00211h).4, altc2_normal_drive_set_carry ; 4DCE 0 208 180 DC110E
                JBS     off(00212h).6, altc_normal_drive ; 4DD1 0 208 180 EE120E
                CMPB    A, #0fch               ; 4DD4 0 208 180 C6FC
                JGE     altc_normal_drive             ; 4DD6 0 208 180 CD0A
                CMPB    A, #005h               ; 4DD8 0 208 180 C605
                JLT     altc_normal_drive             ; 4DDA 0 208 180 CA06
                JBR     off(00226h).7, altc_normal_drive ; 4DDC 0 208 180 DF2603
altc2_normal_drive_set_carry:     SC                             ; 4DDF 0 208 180 85
                SJ      altc_normal_drive_store_carry_p0_bit5             ; 4DE0 0 208 180 CB01
altc_normal_drive:     RC                             ; 4DE2 0 208 180 95
altc_normal_drive_store_carry_p0_bit5:     MB      P0.5, C                ; 4DE3 0 208 180 C5203D
altc_normal_drive_if_ram219_bit3_clr:     JBR     off(00219h).3, flags_b8_2_set ; 4DE6 0 208 180 DB1906
                JBR     off(00216h).6, flags_b8_2_set ; 4DE9 0 208 180 DE1603
                JBR     off(00217h).4, altc_condition_check ; 4DEC 0 208 180 DC1708
flags_b8_2_set:     SB      0b8h.2                 ; 4DEF 0 208 180 C5B81A
                RB      0b3h.2                 ; 4DF2 0 208 180 C5B30A
                SJ      gio_p1_2_check             ; 4DF5 0 208 180 CB17
altc_condition_check:     JBS     off(00215h).2, gio_p1_2_check ; 4DF7 0 208 180 EA1514
                JBS     off(00212h).5, gio_p1_2_check ; 4DFA 0 208 180 ED1211
                MB      C, 0b0h.1              ; 4DFD 0 208 180 C5B029
                JLT     gio_p1_2_check             ; 4E00 0 208 180 CA0C
                CMPB    0d9h, #0ffh            ; 4E02 0 208 180 C5D9C0FF
                JGE     gio_p1_2_check             ; 4E06 0 208 180 CD06
                CMPB    0dbh, #0ffh            ; 4E08 0 208 180 C5DBC0FF
                JLT     flags_219_2_store             ; 4E0C 0 208 180 CA04
gio_p1_2_check:     RC                             ; 4E0E 0 208 180 95
                SB      P1.2                   ; 4E0F 0 208 180 C5221A
flags_219_2_store:     MB      off(00219h).2, C       ; 4E12 0 208 180 C4193A
                VCAL    3                      ; 4E15 0 208 180 13
                JBS     off(0021ah).6, state_21a_7_dispatch ; 4E16 0 208 180 EE1A22
                CMPB    0c5h, #012h            ; 4E19 0 208 180 C5C5C012
                JGE     state_2fb_reset             ; 4E1D 0 208 180 CD0F
                LB      A, 0d7h                ; 4E1F 0 208 180 F5D7
                CMPB    A, #0ffh               ; 4E21 0 208 180 C6FF
                JGT     state_2fb_reset             ; 4E23 0 208 180 C809
                CMPB    A, #000h               ; 4E25 0 208 180 C600
                JLT     state_2fb_reset             ; 4E27 0 208 180 CA05
                MB      C, P4.6                ; 4E29 0 208 180 C52C2E
                JGE     flags_219_2_store_load_ram2c8             ; 4E2C 0 208 180 CD06
state_2fb_reset:     MOVB    off(002c8h), #0ffh     ; 4E2E 0 208 180 C4C898FF
                SJ      state_21a_7_dispatch             ; 4E32 0 208 180 CB07
flags_219_2_store_load_ram2c8:     LB      A, off(002c8h)         ; 4E34 0 208 180 F4C8
                JNE     state_21a_7_dispatch             ; 4E36 0 208 180 CE03
                SB      off(0021ah).6          ; 4E38 0 208 180 C41A1E
state_21a_7_dispatch:     JBS     off(0021ah).7, state_21a_7_dispatch3 ; 4E3B 0 208 180 EF1A1C
                JBS     off(00217h).5, state_21a_7_dispatch_if_ram213_bit0_set ; 4E3E 0 208 180 ED1703
                JBS     off(0021ah).6, state_21a_7_dispatch_if_ram224_bit7_clr ; 4E41 0 208 180 EE1A09
state_21a_7_dispatch_if_ram213_bit0_set:     JBS     off(00213h).0, state_21a_7_set ; 4E44 0 208 180 E81310
state_21a_7_dispatch_load_ram2ea:     MOVB    off(002eah), #0ffh     ; 4E47 0 208 180 C4EA98FF
                SJ      state_21a_7_dispatch3             ; 4E4B 0 208 180 CB0D
state_21a_7_dispatch_if_ram224_bit7_clr:     JBR     off(00224h).7, state_21a_7_dispatch_load_ram2ea ; 4E4D 0 208 180 DF24F7
                JBS     off(0021dh).4, state_21a_7_dispatch_load_ram2ea ; 4E50 0 208 180 EC1DF4
                LB      A, off(002eah)         ; 4E53 0 208 180 F4EA
                JNE     state_21a_7_dispatch3             ; 4E55 0 208 180 CE03
state_21a_7_set:     SB      off(0021ah).7          ; 4E57 0 208 180 C41A1F
state_21a_7_dispatch3:     JBS     off(0021ah).7, state_21a_7_dispatch2 ; 4E5A 0 208 180 EF1A26
                JBR     off(0021ah).6, state_2de_reset ; 4E5D 0 208 180 DE1A1F
                JBS     off(00217h).5, state_2de_reset ; 4E60 0 208 180 ED171C
                JBS     off(00215h).1, altc_p46_check ; 4E63 0 208 180 E91505
                MB      C, 0b3h.1              ; 4E66 0 208 180 C5B329
                JGE     state_2de_reset             ; 4E69 0 208 180 CD14
altc_p46_check:     MB      C, P4.6                ; 4E6B 0 208 180 C52C2E
                JGE     state_2de_reset             ; 4E6E 0 208 180 CD0F
                JBS     off(00218h).0, altc_p46_check_load_ram2eb ; 4E70 0 208 180 E81803
                JBS     off(0021eh).2, state_2de_reset ; 4E73 0 208 180 EA1E09
altc_p46_check_load_ram2eb:     LB      A, off(002ebh)         ; 4E76 0 208 180 F4EB
                JNE     state_21a_7_dispatch2             ; 4E78 0 208 180 CE09
                SB      off(0021ah).7          ; 4E7A 0 208 180 C41A1F
                SJ      state_21a_7_dispatch2             ; 4E7D 0 208 180 CB04
state_2de_reset:     MOVB    off(002ebh), #0ffh     ; 4E7F 0 208 180 C4EB98FF
state_21a_7_dispatch2:     JBS     off(0021ah).7, state_21a_7_dispatch2_load_r0 ; 4E83 0 208 180 EF1A2A
                JBR     off(0021ah).6, state_2df_reset ; 4E86 0 208 180 DE1A1A
                JBS     off(00217h).5, state_2df_reset ; 4E89 0 208 180 ED1717
                LB      A, 0d7h                ; 4E8C 0 208 180 F5D7
                CMPB    A, #0ffh               ; 4E8E 0 208 180 C6FF
                JGT     state_2df_reset             ; 4E90 0 208 180 C811
                CMPB    A, #000h               ; 4E92 0 208 180 C600
                JLT     state_2df_reset             ; 4E94 0 208 180 CA0D
                JBR     off(00215h).0, state_2df_reset ; 4E96 0 208 180 D8150A
                JBS     off(00218h).0, state_dc_check2 ; 4E99 0 208 180 E81803
                JBS     off(0021eh).2, state_2df_reset ; 4E9C 0 208 180 EA1E04
state_dc_check2:     CMPB    A, #0ffh               ; 4E9F 0 208 180 C6FF
                JGT     state_dc_check2_load_ram2ec             ; 4EA1 0 208 180 C806
state_2df_reset:     MOVB    off(002ech), #0ffh     ; 4EA3 0 208 180 C4EC98FF
                SJ      state_21a_7_dispatch2_load_r0             ; 4EA7 0 208 180 CB07
state_dc_check2_load_ram2ec:     LB      A, off(002ech)         ; 4EA9 0 208 180 F4EC
                JNE     state_21a_7_dispatch2_load_r0             ; 4EAB 0 208 180 CE03
                SB      off(0021ah).7          ; 4EAD 0 208 180 C41A1F
state_21a_7_dispatch2_load_r0:     MOVB    r0, #004h              ; 4EB0 0 208 180 9804
                MOV     DP, #tbl_map_sign          ; 4EB2 0 208 180 62D76D
                LB      A, 0d9h                ; 4EB5 0 208 180 F5D9
state_21a_7_dispatch2_dec_dp:     DEC     DP                     ; 4EB7 0 208 180 82
                DECB    r0                     ; 4EB8 0 208 180 B8
                JEQ     state_21a_7_dispatch2_load_ram0fa             ; 4EB9 0 208 180 C904
                CMPCB   A, [DP]                ; 4EBB 0 208 180 92AE
                JGE     state_21a_7_dispatch2_dec_dp             ; 4EBD 0 208 180 CDF8
state_21a_7_dispatch2_load_ram0fa:     L       A, 0fah                ; 4EBF 1 208 180 E5FA
                ST      A, IE                  ; 4EC1 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 4EC3 1 208 180 A2D0FE
                LB      A, off(00233h)         ; 4EC6 0 208 180 F433
                ANDB    A, #0fch               ; 4EC8 0 208 180 D6FC
                ORB     A, r0                  ; 4ECA 0 208 180 68
                STB     A, off(00233h)         ; 4ECB 0 208 180 D433
                ORB     PSWH, #001h            ; 4ECD 0 208 180 A2E001
                L       A, 0f8h                ; 4ED0 1 208 180 E5F8
                ST      A, IE                  ; 4ED2 1 208 180 D51A
                CMPB    0d8h, #0ffh            ; 4ED4 1 208 180 C5D8C0FF
                MB      off(00233h).2, C       ; 4ED8 1 208 180 C4333A
                VCAL    3                      ; 4EDB 1 208 180 13
                JBR     off(00227h).3, state_21a_7_dispatch2_goto_5102 ; 4EDC 1 208 180 DB2721
                JBS     off(00216h).3, state_21a_7_dispatch2_goto_50fe ; 4EDF 1 208 180 EB1618
                RB      off(0022eh).4          ; 4EE2 1 208 180 C42E0C
                MB      C, off(00211h).5       ; 4EE5 1 208 180 C4112D
                MB      off(0022eh).4, C       ; 4EE8 1 208 180 C42E3C
                JEQ     state_21a_7_dispatch2_store_carry_ram22f_bit3             ; 4EEB 1 208 180 C903
                XORB    PSWH, #080h            ; 4EED 1 208 180 A2F080
state_21a_7_dispatch2_store_carry_ram22f_bit3:     MB      off(0022fh).3, C       ; 4EF0 1 208 180 C42F3B
                LB      A, off(002d1h)         ; 4EF3 0 208 180 F4D1
                JNE     state_21a_7_dispatch2_goto_50f8             ; 4EF5 0 208 180 CE06
                J       state_21a_7_dispatch2_if_ram235_bit3_set             ; 4EF7 0 208 180 03ED79
state_21a_7_dispatch2_goto_50fe:     J       state_21a_7_dispatch2_set_carry             ; 4EFA 1 208 180 03FE50
state_21a_7_dispatch2_goto_50f8:     J       state_21a_7_dispatch2_clear_carry             ; 4EFD 0 208 180 03F850
state_21a_7_dispatch2_goto_5102:     J       state_21a_7_dispatch2_vcal_3             ; 4F00 1 208 180 030251
state_21a_7_dispatch2_load_x1:     MOV     X1, #state_21a_7_dispatch2_tbl          ; 4F03 0 208 180 603C6C
                MOV     DP, #0022dh            ; 4F06 0 208 180 622D02
                SB      PSWL.4                 ; 4F09 0 208 180 A31C
                MOV     er0, #00400h           ; 4F0B 0 208 180 44980004
                MOVB    r2, 0beh               ; 4F0F 0 208 180 C5BE4A
                CAL     timer_or_counter_helper             ; 4F12 0 208 180 32405C
                RB      PSWL.4                 ; 4F15 0 208 180 A30C
                MOVB    r1, #001h              ; 4F17 0 208 180 9901
                MOVB    r2, off(00237h)        ; 4F19 0 208 180 C4374A
                CAL     timer_or_counter_helper             ; 4F1C 0 208 180 32405C
                MOVB    r1, #001h              ; 4F1F 0 208 180 9901
                MOVB    r2, 0d1h               ; 4F21 0 208 180 C5D14A
                CAL     timer_or_counter_helper             ; 4F24 0 208 180 32405C
                MOVB    r1, #002h              ; 4F27 0 208 180 9902
                MOVB    r2, off(00238h)        ; 4F29 0 208 180 C4384A
                CAL     timer_or_counter_helper             ; 4F2C 0 208 180 32405C
                MOV     DP, #0022eh            ; 4F2F 0 208 180 622E02
                MOV     er0, #00300h           ; 4F32 0 208 180 44980003
                MOVB    r2, 0cch               ; 4F36 0 208 180 C5CC4A
                CAL     timer_or_counter_helper             ; 4F39 0 208 180 32405C
                CMPB    0cch, #0ffh            ; 4F3C 0 208 180 C5CCC0FF
                JLT     state_21a_7_dispatch2_load_dp             ; 4F40 0 208 180 CA23
                CMPB    off(00238h), #0ffh     ; 4F42 0 208 180 C438C0FF
                JLT     state_21a_7_dispatch2_load_dp             ; 4F46 0 208 180 CA1D
                MOV     DP, #0038ah            ; 4F48 0 208 180 628A03
                CLRB    A                      ; 4F4B 0 208 180 FA
                JBS     off(0022fh).3, state_21a_7_dispatch2_store_dp_ind ; 4F4C 0 208 180 EB2F12
                LB      A, off(00251h)         ; 4F4F 0 208 180 F451
                INC     DP                     ; 4F51 0 208 180 72
                XCHGB   A, [DP]                ; 4F52 0 208 180 C210
                CMPB    A, [DP]                ; 4F54 0 208 180 C2C2
                JEQ     state_21a_7_dispatch2_load_dp             ; 4F56 0 208 180 C90D
                DEC     DP                     ; 4F58 0 208 180 82
                LB      A, #0ffh               ; 4F59 0 208 180 77FF
                INCB    [DP]                   ; 4F5B 0 208 180 C216
                CMPB    A, [DP]                ; 4F5D 0 208 180 C2C2
                JGE     state_21a_7_dispatch2_load_dp             ; 4F5F 0 208 180 CD04
state_21a_7_dispatch2_store_dp_ind:     STB     A, [DP]                ; 4F61 0 208 180 D2
                MB      off(0022eh).3, C       ; 4F62 0 208 180 C42E3B
state_21a_7_dispatch2_load_dp:     MOV     DP, #0038dh            ; 4F65 0 208 180 628D03
                LB      A, [DP]                ; 4F68 0 208 180 F2
                CMPB    A, #0ffh               ; 4F69 0 208 180 C6FF
                MB      off(0022eh).5, C       ; 4F6B 0 208 180 C42E3D
                JGE     state_21a_7_dispatch2_load_imm             ; 4F6E 0 208 180 CD03
                JBS     off(0022eh).6, state_21a_7_dispatch2_store_carry_ram22e_bit7 ; 4F70 0 208 180 EE2E0A
state_21a_7_dispatch2_load_imm:     LB      A, #0ffh               ; 4F73 0 208 180 77FF
                CMPB    A, 0beh                ; 4F75 0 208 180 C5BEC2
                MB      off(0022eh).6, C       ; 4F78 0 208 180 C42E3E
                JLT     state_21a_7_dispatch2_load_ram251             ; 4F7B 0 208 180 CA03
state_21a_7_dispatch2_store_carry_ram22e_bit7:     MB      off(0022eh).7, C       ; 4F7D 0 208 180 C42E3F
state_21a_7_dispatch2_load_ram251:     LB      A, off(00251h)         ; 4F80 0 208 180 F451
                STB     A, r0                  ; 4F82 0 208 180 88
                JBS     off(0022dh).1, state_21a_7_dispatch2_load_ram2d8 ; 4F83 0 208 180 E92D04
                MOVB    off(002d8h), #0ffh     ; 4F86 0 208 180 C4D898FF
state_21a_7_dispatch2_load_ram2d8:     LB      A, off(002d8h)         ; 4F8A 0 208 180 F4D8
                JNE     state_21a_7_dispatch2_if_ram22f_bit1_set_2             ; 4F8C 0 208 180 CE18
                JBS     off(0022fh).2, state_21a_7_dispatch2_if_ram22f_bit1_set ; 4F8E 0 208 180 EA2F08
                CMPB    r0, #003h              ; 4F91 0 208 180 20C003
                JNE     state_21a_7_dispatch2_if_ram22f_bit1_set             ; 4F94 0 208 180 CE03
                SB      off(0022fh).2          ; 4F96 0 208 180 C42F1A
state_21a_7_dispatch2_if_ram22f_bit1_set:     JBS     off(0022fh).1, state_21a_7_dispatch2_if_ram22f_bit0_set ; 4F99 0 208 180 E92F10
                CMPB    r0, #002h              ; 4F9C 0 208 180 20C002
                JNE     state_21a_7_dispatch2_if_ram22f_bit2_clr             ; 4F9F 0 208 180 CE08
                SB      off(0022fh).1          ; 4FA1 0 208 180 C42F19
                SJ      state_21a_7_dispatch2_if_ram22f_bit0_set             ; 4FA4 0 208 180 CB06
state_21a_7_dispatch2_if_ram22f_bit1_set_2:     JBS     off(0022fh).1, state_21a_7_dispatch2_if_ram22f_bit0_set ; 4FA6 0 208 180 E92F03
state_21a_7_dispatch2_if_ram22f_bit2_clr:     JBR     off(0022fh).2, state_21a_7_dispatch2_andb_ram22f ; 4FA9 0 208 180 DA2F23
state_21a_7_dispatch2_if_ram22f_bit0_set:     JBS     off(0022fh).0, state_21a_7_dispatch2_cmp_r0 ; 4FAC 0 208 180 E82F10
                CMPB    r0, #003h              ; 4FAF 0 208 180 20C003
                JGE     state_21a_7_dispatch2_load_ram2d9             ; 4FB2 0 208 180 CD04
                MOVB    off(002d9h), #0ffh     ; 4FB4 0 208 180 C4D998FF
state_21a_7_dispatch2_load_ram2d9:     LB      A, off(002d9h)         ; 4FB8 0 208 180 F4D9
                JNE     state_21a_7_dispatch2_load_ram2da             ; 4FBA 0 208 180 CE08
                SB      off(0022fh).0          ; 4FBC 0 208 180 C42F18
state_21a_7_dispatch2_cmp_r0:     CMPB    r0, #002h              ; 4FBF 0 208 180 20C002
                JEQ     state_21a_7_dispatch2_load_ram2da_2             ; 4FC2 0 208 180 C904
state_21a_7_dispatch2_load_ram2da:     MOVB    off(002dah), #0ffh     ; 4FC4 0 208 180 C4DA98FF
state_21a_7_dispatch2_load_ram2da_2:     LB      A, off(002dah)         ; 4FC8 0 208 180 F4DA
                JEQ     state_21a_7_dispatch2_andb_ram22f             ; 4FCA 0 208 180 C903
                JBS     off(0022eh).0, state_21a_7_dispatch2_clear_x1 ; 4FCC 0 208 180 E82E04
state_21a_7_dispatch2_andb_ram22f:     ANDB    off(0022fh), #0f8h     ; 4FCF 0 208 180 C42FD0F8
state_21a_7_dispatch2_clear_x1:     CLR     X1                     ; 4FD3 0 208 180 9015
                CMPB    0d9h, #0ffh            ; 4FD5 0 208 180 C5D9C0FF
                JLT     state_21a_7_dispatch2_load_x1_2             ; 4FD9 0 208 180 CA21
                CMPB    0d8h, #0ffh            ; 4FDB 0 208 180 C5D8C0FF
                JGE     state_21a_7_dispatch2_load_r0_2             ; 4FDF 0 208 180 CD74
                JBR     off(0022dh).0, state_21a_7_dispatch2_load_ram2db ; 4FE1 0 208 180 D82D04
                MOVB    off(002dbh), #0ffh     ; 4FE4 0 208 180 C4DB98FF
state_21a_7_dispatch2_load_ram2db:     LB      A, off(002dbh)         ; 4FE8 0 208 180 F4DB
                MOV     X1, #00004h            ; 4FEA 0 208 180 600400
                JNE     state_21a_7_dispatch2_load_r0_2             ; 4FED 0 208 180 CE66
                SLL     X1                     ; 4FEF 0 208 180 90D7
                JBR     off(00216h).0, state_21a_7_dispatch2_load_r0_2 ; 4FF1 0 208 180 D81661
                JBS     off(00226h).6, state_21a_7_dispatch2_load_r0_2 ; 4FF4 0 208 180 EE265E
                MOV     X1, #0000ch            ; 4FF7 0 208 180 600C00
                SJ      state_21a_7_dispatch2_load_r0_2             ; 4FFA 0 208 180 CB59
state_21a_7_dispatch2_load_x1_2:     MOV     X1, #00004h            ; 4FFC 0 208 180 600400
                LB      A, #0ffh               ; 4FFF 0 208 180 77FF
                JBR     off(00226h).6, state_21a_7_dispatch2_if_ram22e_bit7_set ; 5001 0 208 180 DE2623
                JBS     off(0022fh).4, state_21a_7_dispatch2_if_ram22e_bit7_set ; 5004 0 208 180 EC2F20
                JBR     off(0022eh).2, state_21a_7_dispatch2_if_ram22e_bit7_clr ; 5007 0 208 180 DA2E0C
                JBS     off(0022fh).5, state_21a_7_dispatch2_if_ram22e_bit7_clr ; 500A 0 208 180 ED2F09
                SB      off(0022fh).5          ; 500D 0 208 180 C42F1D
                JBS     off(0022dh).0, state_21a_7_dispatch2_if_ram22e_bit7_clr ; 5010 0 208 180 E82D03
                SB      off(0022fh).4          ; 5013 0 208 180 C42F1C
state_21a_7_dispatch2_if_ram22e_bit7_clr:     JBR     off(0022eh).7, state_21a_7_dispatch2_load_r0_2 ; 5016 0 208 180 DF2E3C
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2db_2 ; 5019 0 208 180 DA2D02
                STB     A, off(002dbh)         ; 501C 0 208 180 D4DB
state_21a_7_dispatch2_load_ram2db_2:     LB      A, off(002dbh)         ; 501E 0 208 180 F4DB
                JNE     state_21a_7_dispatch2_load_r0_2             ; 5020 0 208 180 CE33
                MOV     X1, #00010h            ; 5022 0 208 180 601000
                SJ      state_21a_7_dispatch2_load_r0_2             ; 5025 0 208 180 CB2E
state_21a_7_dispatch2_if_ram22e_bit7_set:     JBS     off(0022eh).7, state_21a_7_dispatch2_if_ram22d_bit2_clr ; 5027 0 208 180 EF2E14
                JBR     off(00216h).0, state_21a_7_dispatch2_load_r0_2 ; 502A 0 208 180 D81628
                MOV     X1, #00018h            ; 502D 0 208 180 601800
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2db_3 ; 5030 0 208 180 DA2D02
                STB     A, off(002dbh)         ; 5033 0 208 180 D4DB
state_21a_7_dispatch2_load_ram2db_3:     LB      A, off(002dbh)         ; 5035 0 208 180 F4DB
                JEQ     state_21a_7_dispatch2_load_r0_2             ; 5037 0 208 180 C91C
state_21a_7_dispatch2_load_x1_3:     MOV     X1, #00014h            ; 5039 0 208 180 601400
                SJ      state_21a_7_dispatch2_load_r0_2             ; 503C 0 208 180 CB17
state_21a_7_dispatch2_if_ram22d_bit2_clr:     JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2db_4 ; 503E 0 208 180 DA2D02
                STB     A, off(002dbh)         ; 5041 0 208 180 D4DB
state_21a_7_dispatch2_load_ram2db_4:     LB      A, off(002dbh)         ; 5043 0 208 180 F4DB
                JEQ     state_21a_7_dispatch2_load_x1_4             ; 5045 0 208 180 C905
                JBS     off(00216h).0, state_21a_7_dispatch2_load_x1_3 ; 5047 0 208 180 E816EF
                SJ      state_21a_7_dispatch2_load_r0_2             ; 504A 0 208 180 CB09
state_21a_7_dispatch2_load_x1_4:     MOV     X1, #0001ch            ; 504C 0 208 180 601C00
                JBS     off(00216h).0, state_21a_7_dispatch2_load_r0_2 ; 504F 0 208 180 E81603
                MOV     X1, #00022h            ; 5052 0 208 180 602200
state_21a_7_dispatch2_load_r0_2:     LB      A, r0                  ; 5055 0 208 180 78
                JEQ     state_21a_7_dispatch2_extnd_acc             ; 5056 0 208 180 C906
                CMPB    A, #005h               ; 5058 0 208 180 C605
                JEQ     state_21a_7_dispatch2_load_ram2dc             ; 505A 0 208 180 C92F
                SUBB    A, #001h               ; 505C 0 208 180 A601
state_21a_7_dispatch2_extnd_acc:     EXTND                          ; 505E 1 208 180 F8
                ADD     A, X1                  ; 505F 1 208 180 9082
                CMP     X1, #0001ch            ; 5061 1 208 180 90C01C00
                JLT     state_21a_7_dispatch2_load_dp_2             ; 5065 1 208 180 CA12
                CMPB    r0, #003h              ; 5067 1 208 180 20C003
                JLT     state_21a_7_dispatch2_load_dp_2             ; 506A 1 208 180 CA0D
                JNE     state_21a_7_dispatch2_if_ram22f_bit2_clr_2             ; 506C 1 208 180 CE05
                JBR     off(0022fh).1, state_21a_7_dispatch2_load_dp_2 ; 506E 1 208 180 D92F08
                SJ      state_21a_7_dispatch2_add_acc             ; 5071 1 208 180 CB03
state_21a_7_dispatch2_if_ram22f_bit2_clr_2:     JBR     off(0022fh).2, state_21a_7_dispatch2_load_dp_2 ; 5073 1 208 180 DA2F03
state_21a_7_dispatch2_add_acc:     ADD     A, #00002h             ; 5076 1 208 180 860200
state_21a_7_dispatch2_load_dp_2:     MOV     DP, #0038eh            ; 5079 1 208 180 628E03
                MOVB    [DP], A                ; 507C 1 208 180 C28A
                ADD     A, #state_21a_7_dispatch2_tbl_2           ; 507E 1 208 180 86526C
                MOV     DP, A                  ; 5081 1 208 180 52
                CLRB    A                      ; 5082 0 208 180 FA
                LCB     A, [DP]                ; 5083 0 208 180 92AA
                MOV     DP, #0038fh            ; 5085 0 208 180 628F03
                STB     A, [DP]                ; 5088 0 208 180 D2
                SJ      state_21a_7_dispatch2_load_r1             ; 5089 0 208 180 CB04
state_21a_7_dispatch2_load_ram2dc:     MOVB    off(002dch), #0ffh     ; 508B 0 208 180 C4DC98FF
state_21a_7_dispatch2_load_r1:     MOVB    r1, #0ffh              ; 508F 0 208 180 99FF
                JBR     off(0022eh).1, state_21a_7_dispatch2_andb_ram22f_2 ; 5091 0 208 180 D92E06
                LB      A, off(002dch)         ; 5094 0 208 180 F4DC
                JNE     state_21a_7_dispatch2_set_carry             ; 5096 0 208 180 CE66
                SJ      state_21a_7_dispatch2_load_dp_3             ; 5098 0 208 180 CB06
state_21a_7_dispatch2_andb_ram22f_2:     ANDB    off(0022fh), #0cfh     ; 509A 0 208 180 C42FD0CF
                SJ      state_21a_7_dispatch2_set_carry             ; 509E 0 208 180 CB5E
state_21a_7_dispatch2_load_dp_3:     MOV     DP, #0038fh            ; 50A0 0 208 180 628F03
                LB      A, [DP]                ; 50A3 0 208 180 F2
                JBR     off(0022fh).6, state_21a_7_dispatch2_cmp_acc ; 50A4 0 208 180 DE2F05
                SUBB    A, #0ffh               ; 50A7 0 208 180 A6FF
                JGE     state_21a_7_dispatch2_cmp_acc             ; 50A9 0 208 180 CD01
                CLRB    A                      ; 50AB 0 208 180 FA
state_21a_7_dispatch2_cmp_acc:     CMPB    A, 0cch                ; 50AC 0 208 180 C5CCC2
                MB      off(0022fh).6, C       ; 50AF 0 208 180 C42F3E
                JGE     state_21a_7_dispatch2_if_ram22d_bit7_set             ; 50B2 0 208 180 CD47
                JBS     off(0022dh).4, state_21a_7_dispatch2_load_ram2dd ; 50B4 0 208 180 EC2D04
                MOVB    off(002ddh), #0ffh     ; 50B7 0 208 180 C4DD98FF
state_21a_7_dispatch2_load_ram2dd:     LB      A, off(002ddh)         ; 50BB 0 208 180 F4DD
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set             ; 50BD 0 208 180 CE3C
                JBS     off(0022eh).3, state_21a_7_dispatch2_if_ram22d_bit3_set ; 50BF 0 208 180 EB2E0B
                JBR     off(00211h).5, state_21a_7_dispatch2_load_ram2de ; 50C2 0 208 180 DD1104
                MOVB    off(002deh), #0ffh     ; 50C5 0 208 180 C4DE98FF
state_21a_7_dispatch2_load_ram2de:     LB      A, off(002deh)         ; 50C9 0 208 180 F4DE
                JNE     state_21a_7_dispatch2_set_carry             ; 50CB 0 208 180 CE31
state_21a_7_dispatch2_if_ram22d_bit3_set:     JBS     off(0022dh).3, state_21a_7_dispatch2_load_ram2df ; 50CD 0 208 180 EB2D09
                MOVB    off(002dfh), #0ffh     ; 50D0 0 208 180 C4DF98FF
                MOVB    off(002e0h), r1        ; 50D4 0 208 180 217CE0
                SJ      state_21a_7_dispatch2_if_ram22d_bit5_clr             ; 50D7 0 208 180 CB11
state_21a_7_dispatch2_load_ram2df:     LB      A, off(002dfh)         ; 50D9 0 208 180 F4DF
                JEQ     state_21a_7_dispatch2_if_ram22d_bit5_clr             ; 50DB 0 208 180 C90D
                JBR     off(0022eh).5, state_21a_7_dispatch2_load_ram2e0 ; 50DD 0 208 180 DD2E03
                MOVB    off(002e0h), r1        ; 50E0 0 208 180 217CE0
state_21a_7_dispatch2_load_ram2e0:     LB      A, off(002e0h)         ; 50E3 0 208 180 F4E0
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set             ; 50E5 0 208 180 CE14
                JBR     off(0022dh).6, state_21a_7_dispatch2_set_carry ; 50E7 0 208 180 DE2D14
state_21a_7_dispatch2_if_ram22d_bit5_clr:     JBR     off(0022dh).5, state_21a_7_dispatch2_load_ram2e3 ; 50EA 0 208 180 DD2D04
                MOVB    off(002e3h), #0ffh     ; 50ED 0 208 180 C4E398FF
state_21a_7_dispatch2_load_ram2e3:     LB      A, off(002e3h)         ; 50F1 0 208 180 F4E3
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set             ; 50F3 0 208 180 CE06
                JBS     off(00211h).4, state_21a_7_dispatch2_set_carry ; 50F5 0 208 180 EC1106
state_21a_7_dispatch2_clear_carry:     RC                             ; 50F8 0 208 180 95
                SJ      state_21a_7_dispatch2_store_carry_p0_bit5             ; 50F9 0 208 180 CB04
state_21a_7_dispatch2_if_ram22d_bit7_set:     JBS     off(0022dh).7, state_21a_7_dispatch2_clear_carry ; 50FB 0 208 180 EF2DFA
state_21a_7_dispatch2_set_carry:     SC                             ; 50FE 1 208 180 85
state_21a_7_dispatch2_store_carry_p0_bit5:     MB      P0.5, C                ; 50FF 1 208 180 C5203D
state_21a_7_dispatch2_vcal_3:     VCAL    3                      ; 5102 1 208 180 13
                MOV     DP, #003d1h            ; 5103 1 208 180 62D103
                LB      A, [DP]                ; 5106 0 208 180 F2
                CMPB    A, #0ffh               ; 5107 0 208 180 C6FF
                JGT     knock_244_recheck             ; 5109 0 208 180 C804
                CMPB    A, #0fch               ; 510B 0 208 180 C6FC
                JGE     knock_324_bit_check             ; 510D 0 208 180 CD04
knock_244_recheck:     SC                             ; 510F 0 208 180 85
                JBS     off(00230h).6, knock_324_bit_store ; 5110 0 208 180 EE3003
knock_324_bit_check:     MB      C, off(00214h).7       ; 5113 0 208 180 C4142F
knock_324_bit_store:     MOV     DP, #00324h            ; 5116 0 208 180 622403
                MB      [DP].0, C              ; 5119 0 208 180 C238
                LB      A, [DP]                ; 511B 0 208 180 F2
                ANDB    A, #0f1h               ; 511C 0 208 180 D6F1
                STB     A, [DP]                ; 511E 0 208 180 D2
                L       A, ADCR6               ; 511F 1 208 180 E56C
                ST      A, 0bah                ; 5121 1 208 180 D5BA
                LB      A, ADCR7H              ; 5123 0 208 180 F56F
                MOV     DP, #003a0h            ; 5125 0 208 180 62A003
                STB     A, [DP]                ; 5128 0 208 180 D2
                LB      A, ADCR2H              ; 5129 0 208 180 F565
                MOV     DP, #003a1h            ; 512B 0 208 180 62A103
                STB     A, [DP]                ; 512E 0 208 180 D2
                RC                             ; 512F 0 208 180 95
                CLRB    A                      ; 5130 0 208 180 FA
                MB      C, off(00211h).1       ; 5131 0 208 180 C41129
                XORB    PSWH, #080h            ; 5134 0 208 180 A2F080
                ROLB    A                      ; 5137 0 208 180 33
                MB      C, off(00211h).7       ; 5138 0 208 180 C4112F
                ROLB    A                      ; 513B 0 208 180 33
                MB      C, off(00211h).6       ; 513C 0 208 180 C4112E
                ROLB    A                      ; 513F 0 208 180 33
                MB      C, off(00211h).5       ; 5140 0 208 180 C4112D
                ROLB    A                      ; 5143 0 208 180 33
                MB      C, off(00211h).4       ; 5144 0 208 180 C4112C
                ROLB    A                      ; 5147 0 208 180 33
                MB      C, off(00210h).3       ; 5148 0 208 180 C4102B
                XORB    PSWH, #080h            ; 514B 0 208 180 A2F080
                ROLB    A                      ; 514E 0 208 180 33
                MB      C, off(00211h).2       ; 514F 0 208 180 C4112A
                ROLB    A                      ; 5152 0 208 180 33
                MB      C, off(00211h).0       ; 5153 0 208 180 C41128
                ROLB    A                      ; 5156 0 208 180 33
                JBS     off(00216h).3, knock_324_bit_store_load_dp ; 5157 0 208 180 EB1602
                ANDB    A, #08fh               ; 515A 0 208 180 D68F
knock_324_bit_store_load_dp:     MOV     DP, #003ach            ; 515C 0 208 180 62AC03
                STB     A, [DP]                ; 515F 0 208 180 D2
                RC                             ; 5160 0 208 180 95
                LCB     A, dwell_battery_check2_tbl            ; 5161 0 208 180 909DF260
                JNE     knock_324_bit_store_clear_acc             ; 5165 0 208 180 CE05
                MOV     DP, #003c9h            ; 5167 0 208 180 62C903
                LB      A, [DP]                ; 516A 0 208 180 F2
                SLLB    A                      ; 516B 0 208 180 53
knock_324_bit_store_clear_acc:     CLRB    A                      ; 516C 0 208 180 FA
                ROLB    A                      ; 516D 0 208 180 33
                MB      C, P4.6                ; 516E 0 208 180 C52C2E
                XORB    PSWH, #080h            ; 5171 0 208 180 A2F080
                ROLB    A                      ; 5174 0 208 180 33
                MB      C, off(0022ch).2       ; 5175 0 208 180 C42C2A
                ROLB    A                      ; 5178 0 208 180 33
                MB      C, off(0022ch).0       ; 5179 0 208 180 C42C28
                ROLB    A                      ; 517C 0 208 180 33
                MB      C, off(00210h).7       ; 517D 0 208 180 C4102F
                ROLB    A                      ; 5180 0 208 180 33
                ROLB    A                      ; 5181 0 208 180 33
                JBR     off(00227h).3, knock_324_bit_store_rolb_acc ; 5182 0 208 180 DB2703
                MB      C, off(00211h).5       ; 5185 0 208 180 C4112D
knock_324_bit_store_rolb_acc:     ROLB    A                      ; 5188 0 208 180 33
                ROLB    A                      ; 5189 0 208 180 33
                MOV     DP, #003adh            ; 518A 0 208 180 62AD03
                STB     A, [DP]                ; 518D 0 208 180 D2
                RC                             ; 518E 0 208 180 95
                CLRB    A                      ; 518F 0 208 180 FA
                MOV     DP, #003aeh            ; 5190 0 208 180 62AE03
                STB     A, [DP]                ; 5193 0 208 180 D2
                RC                             ; 5194 0 208 180 95
                CLRB    A                      ; 5195 0 208 180 FA
                MB      C, P1.2                ; 5196 0 208 180 C5222A
                XORB    PSWH, #080h            ; 5199 0 208 180 A2F080
                ROLB    A                      ; 519C 0 208 180 33
                MB      C, P1.4                ; 519D 0 208 180 C5222C
                ROLB    A                      ; 51A0 0 208 180 33
                ROLB    A                      ; 51A1 0 208 180 33
                ROLB    A                      ; 51A2 0 208 180 33
                MB      C, P0.1                ; 51A3 0 208 180 C52029
                XORB    PSWH, #080h            ; 51A6 0 208 180 A2F080
                ROLB    A                      ; 51A9 0 208 180 33
                MB      C, P0.0                ; 51AA 0 208 180 C52028
                XORB    PSWH, #080h            ; 51AD 0 208 180 A2F080
                ROLB    A                      ; 51B0 0 208 180 33
                MB      C, P0.7                ; 51B1 0 208 180 C5202F
                XORB    PSWH, #080h            ; 51B4 0 208 180 A2F080
                ROLB    A                      ; 51B7 0 208 180 33
                MOV     DP, #003afh            ; 51B8 0 208 180 62AF03
                STB     A, [DP]                ; 51BB 0 208 180 D2
                RC                             ; 51BC 0 208 180 95
                CLRB    A                      ; 51BD 0 208 180 FA
                MB      C, P0.5                ; 51BE 0 208 180 C5202D
                XORB    PSWH, #080h            ; 51C1 0 208 180 A2F080
                ROLB    A                      ; 51C4 0 208 180 33
                MB      C, P0.6                ; 51C5 0 208 180 C5202E
                J       knock_324_bit_store_xorb_pswh             ; 51C8 0 208 180 033678
                DB  000h ; 51CB
knock_324_bit_store_rolb_acc_2:     ROLB    A                      ; 51CC 0 208 180 33
                MB      C, P0.4                ; 51CD 0 208 180 C5202C
                ROLB    A                      ; 51D0 0 208 180 33
                MB      C, P1.0                ; 51D1 0 208 180 C52228
                ROLB    A                      ; 51D4 0 208 180 33
                ROLB    A                      ; 51D5 0 208 180 33
                MB      C, P0.3                ; 51D6 0 208 180 C5202B
                XORB    PSWH, #080h            ; 51D9 0 208 180 A2F080
                ROLB    A                      ; 51DC 0 208 180 33
                MB      C, P0.2                ; 51DD 0 208 180 C5202A
                XORB    PSWH, #080h            ; 51E0 0 208 180 A2F080
                ROLB    A                      ; 51E3 0 208 180 33
                MOV     DP, #003b0h            ; 51E4 0 208 180 62B003
                STB     A, [DP]                ; 51E7 0 208 180 D2
                RC                             ; 51E8 0 208 180 95
                CLRB    A                      ; 51E9 0 208 180 FA
                MB      C, P0.5                ; 51EA 0 208 180 C5202D
                ROLB    A                      ; 51ED 0 208 180 33
                ROLB    A                      ; 51EE 0 208 180 33
                MOV     DP, #003b1h            ; 51EF 0 208 180 62B103
                STB     A, [DP]                ; 51F2 0 208 180 D2
                RC                             ; 51F3 0 208 180 95
                CLRB    A                      ; 51F4 0 208 180 FA
                MOV     DP, #003b2h            ; 51F5 0 208 180 62B203
                STB     A, [DP]                ; 51F8 0 208 180 D2
                RC                             ; 51F9 0 208 180 95
                CLRB    A                      ; 51FA 0 208 180 FA
                MB      C, off(0021dh).0       ; 51FB 0 208 180 C41D28
                ROLB    A                      ; 51FE 0 208 180 33
                MOV     DP, #003b3h            ; 51FF 0 208 180 62B303
                STB     A, [DP]                ; 5202 0 208 180 D2
                J       knock_324_bit_store_clear_carry             ; 5203 0 208 180 03297B
knock_324_bit_store_store_dp_ind:     STB     A, [DP]                ; 5206 0 208 180 D2
                INC     X1                     ; 5207 0 208 180 70
                INC     DP                     ; 5208 0 208 180 72
diag_snapshot_copy_loop:     LCB     A, [X1]                ; 5209 0 208 180 90AA
                MOVB    [DP], A                ; 520B 0 208 180 C28A
                INC     X1                     ; 520D 0 208 180 70
                INC     DP                     ; 520E 0 208 180 72
                CMP     X1, #crank_edge_flag_store_tbl          ; 520F 0 208 180 90C0896F
                JNE     diag_snapshot_copy_loop             ; 5213 0 208 180 CEF4
                MOVB    r0, #040h              ; 5215 0 208 180 9840
                JBR     off(00219h).3, diag_mode_code_store ; 5217 0 208 180 DB1939
                MOVB    r0, #020h              ; 521A 0 208 180 9820
                LCB     A, diag_snapshot_copy_loop_tbl            ; 521C 0 208 180 909DF460
                JNE     diag_mode_code_store             ; 5220 0 208 180 CE31
                LCB     A, dwell_battery_check2_tbl            ; 5222 0 208 180 909DF260
                JEQ     diag_snapshot_copy_loop_load_r0             ; 5226 0 208 180 C909
                LCB     A, diag_snapshot_copy_loop_tbl_2            ; 5228 0 208 180 909DF560
                JEQ     diag_snapshot_copy_loop_load_r0             ; 522C 0 208 180 C903
                JBS     off(00216h).0, diag_mode_code_store ; 522E 0 208 180 E81622
diag_snapshot_copy_loop_load_r0:     MOVB    r0, #001h              ; 5231 0 208 180 9801
                JBS     off(00216h).2, diag_mode_code_store ; 5233 0 208 180 EA161D
                MOVB    r0, #002h              ; 5236 0 208 180 9802
                LCB     A, dwell_battery_check2_tbl            ; 5238 0 208 180 909DF260
                JEQ     diag_mode_code_store             ; 523C 0 208 180 C915
                LCB     A, diag_snapshot_copy_loop_tbl_2            ; 523E 0 208 180 909DF560
                JEQ     diag_snapshot_copy_loop_load_r0_2             ; 5242 0 208 180 C903
                JBR     off(00216h).0, diag_mode_code_store ; 5244 0 208 180 D8160C
diag_snapshot_copy_loop_load_r0_2:     MOVB    r0, #008h              ; 5247 0 208 180 9808
                JBR     off(00216h).0, diag_mode_code_store ; 5249 0 208 180 D81607
                MOVB    r0, #010h              ; 524C 0 208 180 9810
                JBR     off(00217h).6, diag_mode_code_store ; 524E 0 208 180 DE1702
                MOVB    r0, #004h              ; 5251 0 208 180 9804
diag_mode_code_store:     MOV     DP, #003a7h            ; 5253 0 208 180 62A703
                LB      A, r0                  ; 5256 0 208 180 78
                STB     A, [DP]                ; 5257 0 208 180 D2
                CLRB    r0                     ; 5258 0 208 180 2015
                JBR     off(00216h).3, diag_mode_code_store_rom_load_tbl_60f6 ; 525A 0 208 180 DB1607
                LCB     A, diag_mode_code_store_tbl_4            ; 525D 0 208 180 909DF760
                SLLB    A                      ; 5261 0 208 180 53
                ROLB    r0                     ; 5262 0 208 180 20B7
diag_mode_code_store_rom_load_tbl_60f6:     LCB     A, diag_mode_code_store_tbl_3            ; 5264 0 208 180 909DF660
                SLLB    A                      ; 5268 0 208 180 53
                ROLB    r0                     ; 5269 0 208 180 20B7
                MB      C, off(00227h).5       ; 526B 0 208 180 C4272D
                ROLB    r0                     ; 526E 0 208 180 20B7
                MB      C, off(00216h).5       ; 5270 0 208 180 C4162D
                ROLB    r0                     ; 5273 0 208 180 20B7
                MB      C, off(00227h).4       ; 5275 0 208 180 C4272C
                ROLB    r0                     ; 5278 0 208 180 20B7
                MB      C, off(00217h).6       ; 527A 0 208 180 C4172E
                ROLB    r0                     ; 527D 0 208 180 20B7
                RC                             ; 527F 0 208 180 95
                LCB     A, diag_mode_code_store_tbl            ; 5280 0 208 180 909DEA60
                JNE     diag_mode_code_store_rolb_r0             ; 5284 0 208 180 CE06
                MOV     DP, #003c7h            ; 5286 0 208 180 62C703
                LB      A, [DP]                ; 5289 0 208 180 F2
                SLLB    A                      ; 528A 0 208 180 53
                SLLB    A                      ; 528B 0 208 180 53
diag_mode_code_store_rolb_r0:     ROLB    r0                     ; 528C 0 208 180 20B7
                MB      C, off(00216h).3       ; 528E 0 208 180 C4162B
                ROLB    r0                     ; 5291 0 208 180 20B7
                MOV     DP, #003a8h            ; 5293 0 208 180 62A803
                LB      A, r0                  ; 5296 0 208 180 78
                STB     A, [DP]                ; 5297 0 208 180 D2
                LCB     A, diag_mode_code_store_tbl_2            ; 5298 0 208 180 909DF360
                MOVB    r0, A                  ; 529C 0 208 180 208A
                L       A, off(00260h)         ; 529E 1 208 180 E460
                SLL     A                      ; 52A0 1 208 180 53
                JLT     diag_clamp_ff             ; 52A1 1 208 180 CA08
                CMPB    r0, #000h              ; 52A3 1 208 180 20C000
                JNE     diag_clamp_acch             ; 52A6 1 208 180 CE07
                SLL     A                      ; 52A8 1 208 180 53
                JGE     diag_clamp_acch             ; 52A9 1 208 180 CD04
diag_clamp_ff:     LB      A, #0ffh               ; 52AB 0 208 180 77FF
                SJ      diag_store_3ad             ; 52AD 0 208 180 CB02
diag_clamp_acch:     LB      A, ACCH                ; 52AF 0 208 180 F507
diag_store_3ad:     MOV     DP, #003a9h            ; 52B1 0 208 180 62A903
                STB     A, [DP]                ; 52B4 0 208 180 D2
                MOV     DP, #0030ch            ; 52B5 0 208 180 620C03
                L       A, [DP]                ; 52B8 1 208 180 E2
                SLL     A                      ; 52B9 1 208 180 53
                JLT     diag_clamp_ff2             ; 52BA 1 208 180 CA08
                CMPB    r0, #000h              ; 52BC 1 208 180 20C000
                JNE     diag_clamp_acch2             ; 52BF 1 208 180 CE07
                SLL     A                      ; 52C1 1 208 180 53
                JGE     diag_clamp_acch2             ; 52C2 1 208 180 CD04
diag_clamp_ff2:     LB      A, #0ffh               ; 52C4 0 208 180 77FF
                SJ      diag_store_3ae             ; 52C6 0 208 180 CB02
diag_clamp_acch2:     LB      A, ACCH                ; 52C8 0 208 180 F507
diag_store_3ae:     MOV     DP, #003aah            ; 52CA 0 208 180 62AA03
                STB     A, [DP]                ; 52CD 0 208 180 D2
                LB      A, 0cch                ; 52CE 0 208 180 F5CC
                JBR     off(00214h).0, diag_store_39f ; 52D0 0 208 180 D81401
                CLRB    A                      ; 52D3 0 208 180 FA
diag_store_39f:     MOV     DP, #0039bh            ; 52D4 0 208 180 629B03
                STB     A, [DP]                ; 52D7 0 208 180 D2
                MOV     DP, #003abh            ; 52D8 0 208 180 62AB03
                LB      A, [DP]                ; 52DB 0 208 180 F2
                CMPB    A, #033h               ; 52DC 0 208 180 C633
                JEQ     diag_3af_range_check             ; 52DE 0 208 180 C90C
                CMPB    A, #034h               ; 52E0 0 208 180 C634
                JEQ     diag_3af_range_check             ; 52E2 0 208 180 C908
                CMPB    A, #035h               ; 52E4 0 208 180 C635
                JEQ     diag_3af_range_check             ; 52E6 0 208 180 C904
                CMPB    A, #036h               ; 52E8 0 208 180 C636
                JNE     diag_3af_no_match             ; 52EA 0 208 180 CE03
diag_3af_range_check:     SC                             ; 52EC 0 208 180 85
                SJ      diag_3af_flag_store             ; 52ED 0 208 180 CB01
diag_3af_no_match:     RC                             ; 52EF 0 208 180 95
diag_3af_flag_store:     MB      off(00219h).7, C       ; 52F0 0 208 180 C4193F
                VCAL    3                      ; 52F3 0 208 180 13
                MOV     er1, 0b0h              ; 52F4 0 208 180 B5B049
                MOV     er2, 0b2h              ; 52F7 0 208 180 B5B24A
                JBR     off(00217h).5, diag_mask_gate ; 52FA 0 208 180 DD1712
                AND     er1, #0c5e2h           ; 52FD 0 208 180 45D0E2C5
                AND     0b0h, #0c5e2h          ; 5301 0 208 180 B5B0D0E2C5
                AND     er2, #0040bh           ; 5306 0 208 180 46D00B04
                AND     0b2h, #0040bh          ; 530A 0 208 180 B5B2D00B04
diag_mask_gate:     MB      C, 0b7h.1              ; 530F 0 208 180 C5B729
                JGE     dtc_scan_init             ; 5312 0 208 180 CD07
                CLR     A                      ; 5314 1 208 180 F9
                ST      A, 0b0h                ; 5315 1 208 180 D5B0
                ST      A, 0b2h                ; 5317 1 208 180 D5B2
                ST      A, er1                 ; 5319 1 208 180 89
                ST      A, er2                 ; 531A 1 208 180 8A
dtc_scan_init:     MOVB    r7, #001h              ; 531B 1 208 180 9F01
                MOV     DP, #002d2h            ; 531D 1 208 180 62D202
dtc_scan_loop:     SRL     er2                    ; 5320 1 208 180 46E7
                ROR     er1                    ; 5322 1 208 180 45C7
                JLT     dtc_scan_found_check             ; 5324 1 208 180 CA18
                LB      A, r7                  ; 5326 0 208 180 7F
                SUBB    A, off(002b3h)         ; 5327 0 208 180 A7B3
                JNE     dtc_scan_f4_check             ; 5329 0 208 180 CE03
                STB     A, off(002b3h)         ; 532B 0 208 180 D4B3
                STB     A, [DP]                ; 532D 0 208 180 D2
dtc_scan_f4_check:     LB      A, r7                  ; 532E 0 208 180 7F
                SUBB    A, 0f4h                ; 532F 0 208 180 C5F4A2
                JNE     dtc_scan_advance             ; 5332 0 208 180 CE02
                STB     A, 0f4h                ; 5334 0 208 180 D5F4
dtc_scan_advance:     INCB    r7                     ; 5336 0 208 180 AF
                CMPB    r7, #01ch              ; 5337 0 208 180 27C01C
                JNE     dtc_scan_loop             ; 533A 0 208 180 CEE4
                SJ      dtc_debounce_init             ; 533C 0 208 180 CB16
dtc_scan_found_check:     LB      A, off(002b3h)         ; 533E 0 208 180 F4B3
                JEQ     dtc_scan_new_code             ; 5340 0 208 180 C908
                CMPB    A, r7                  ; 5342 0 208 180 4F
                JNE     dtc_scan_advance             ; 5343 0 208 180 CEF1
                LB      A, [DP]                ; 5345 0 208 180 F2
                JNE     dtc_debounce_init             ; 5346 0 208 180 CE0C
                SJ      dtc_debounce2_init             ; 5348 0 208 180 CB67
dtc_scan_new_code:     CLR     A                      ; 534A 1 208 180 F9
                LB      A, r7                  ; 534B 0 208 180 7F
                STB     A, off(002b3h)         ; 534C 0 208 180 D4B3
                LCB     A, dtc_scan_new_code_tbl[ACC]       ; 534E 0 208 180 B506AB246F
                STB     A, [DP]                ; 5353 0 208 180 D2
dtc_debounce_init:     VCAL    3                      ; 5354 0 208 180 13
; [H] --- DTC debounce/persistence tracking (0x43C8-0x4432ish): maintains a per-fault debounce
; [H] countdown array at 0x1D1 (44 entries, dtc_debounce_loop) and a second array at 0x1DC (16
; [H] more entries with a fixed 0xBB3 sentinel when active) -- each potential fault condition gets
; [H] its own countdown before being confirmed/latched, rather than triggering on a single sample.
; [H] Feeds the same 0xF4 "active DTC index" tracked by the bit-scanner above.
                MOVB    r7, #021h              ; 5355 0 208 180 9F21
                CLR     A                      ; 5357 1 208 180 F9
                XCHG    A, 0b4h                ; 5358 1 208 180 B5B410
                JBS     off(0021ch).6, dtc_debounce_mask_apply ; 535B 1 208 180 EE1C03
                AND     A, #081ffh             ; 535E 1 208 180 D6FF81
dtc_debounce_mask_apply:     ST      A, er0                 ; 5361 1 208 180 88
                MB      C, 0b7h.1              ; 5362 1 208 180 C5B729
                JGE     dtc_debounce_loop_start             ; 5365 1 208 180 CD02
                CLR     er0                    ; 5367 1 208 180 4415
dtc_debounce_loop_start:     MOV     DP, #001adh            ; 5369 1 208 180 62AD01
dtc_debounce_loop:     SRL     er0                    ; 536C 1 208 180 44E7
                JGE     dtc_debounce_check_active             ; 536E 1 208 180 CD07
                LB      A, [DP]                ; 5370 0 208 180 F2
                JEQ     dtc_debounce2_init             ; 5371 0 208 180 C93E
                DECB    [DP]                   ; 5373 0 208 180 C217
                SJ      dtc_debounce_advance             ; 5375 0 208 180 CB12
dtc_debounce_check_active:     CLR     A                      ; 5377 1 208 180 F9
                LB      A, r7                  ; 5378 0 208 180 7F
                CMPB    A, 0f4h                ; 5379 0 208 180 C5F4C2
                JNE     dtc_debounce_advance             ; 537C 0 208 180 CE0B
                LCB     A, dtc_scan_new_code_tbl[ACC]       ; 537E 0 208 180 B506AB246F
                SUBB    A, [DP]                ; 5383 0 208 180 C2A2
                JNE     dtc_debounce_advance             ; 5385 0 208 180 CE02
                STB     A, 0f4h                ; 5387 0 208 180 D5F4
dtc_debounce_advance:     INC     DP                     ; 5389 0 208 180 72
                INCB    r7                     ; 538A 0 208 180 AF
                CMPB    r7, #02ch              ; 538B 0 208 180 27C02C
                JNE     dtc_debounce_loop             ; 538E 0 208 180 CEDC
                MOVB    r7, #030h              ; 5390 0 208 180 9F30
                MOV     DP, #001b8h            ; 5392 0 208 180 62B801
                SRL     er0                    ; 5395 0 208 180 44E7
                SRL     er0                    ; 5397 0 208 180 44E7
                SRL     er0                    ; 5399 0 208 180 44E7
                SRL     er0                    ; 539B 0 208 180 44E7
                SRL     er0                    ; 539D 0 208 180 44E7
                JLT     dtc_debounce2_check             ; 539F 0 208 180 CA0D
                MOV     [DP], #00bb3h          ; 53A1 0 208 180 B298B30B
                LB      A, 0f4h                ; 53A5 0 208 180 F5F4
                SUBB    A, r7                  ; 53A7 0 208 180 2F
                JNE     dtc_debounce2_check_goto_7a1b             ; 53A8 0 208 180 CE66
                STB     A, 0f4h                ; 53AA 0 208 180 D5F4
                SJ      dtc_debounce2_check_goto_7a1b             ; 53AC 0 208 180 CB62
dtc_debounce2_check:     L       A, [DP]                ; 53AE 1 208 180 E2
                JNE     dtc_debounce2_check_goto_7a1b             ; 53AF 1 208 180 CE5F
dtc_debounce2_init:     LB      A, #005h               ; 53B1 0 208 180 7705
                STB     A, [DP]                ; 53B3 0 208 180 D2
                LB      A, 0f4h                ; 53B4 0 208 180 F5F4
                JNE     dtc_active_confirm             ; 53B6 0 208 180 CE05
                LB      A, r7                  ; 53B8 0 208 180 7F
                STB     A, 0f4h                ; 53B9 0 208 180 D5F4
                SJ      dtc_debounce2_check_goto_7a1b             ; 53BB 0 208 180 CB53
dtc_active_confirm:     SUBB    A, r7                  ; 53BD 0 208 180 2F
                J       dtc_active_confirm_if_ne_goto_7a82             ; 53BE 0 208 180 037B7A
                DB  000h ; 53C1
cfgvariant_apply_gate:     AND     IE, #00080h            ; 53C2 0 208 180 B51AD08000
                CLR     A                      ; 53C7 1 208 180 F9
                LB      A, r7                  ; 53C8 0 208 180 7F
                CMPB    A, #030h               ; 53C9 0 208 180 C630
                JNE     cfgvariant_apply_gate_rom_load_tbl_6f55_acc             ; 53CB 0 208 180 CE0D
                MOV     (001b8h-00180h)[USP], #00bb3h ; 53CD 0 208 180 B33898B30B
                JBR     off(00216h).2, cfgvariant_apply_gate_rom_load_tbl_6f55_acc ; 53D2 0 208 180 DA1605
                SB      0b8h.5                 ; 53D5 0 208 180 C5B81D
                SJ      cfgvariant_apply_done_load_ram0f8             ; 53D8 0 208 180 CB32
cfgvariant_apply_gate_rom_load_tbl_6f55_acc:     LCB     A, cfgvariant_index_lookup_tbl[ACC]       ; 53DA 0 208 180 B506AB556F
                JEQ     cfgvariant_apply_done_load_ram0f8             ; 53DF 0 208 180 C92B
                STB     A, r6                  ; 53E1 0 208 180 8E
                SB      off(00232h).4          ; 53E2 0 208 180 C4321C
                SB      off(00232h).5          ; 53E5 0 208 180 C4321D
                CAL     cfgvariant_set_flags             ; 53E8 0 208 180 327E5B
                CMPB    r6, #018h              ; 53EB 0 208 180 26C018
                JEQ     cfgvariant_apply_done             ; 53EE 0 208 180 C90C
                CAL     cfgvariant_eval_condition             ; 53F0 0 208 180 321D5D
                CAL     cfgvariant_snapshot_capture             ; 53F3 0 208 180 32895E
                CAL     cfgvariant_checksum2_calc             ; 53F6 0 208 180 322D5F
                INC     DP                     ; 53F9 0 208 180 72
                L       A, er0                 ; 53FA 1 208 180 34
                ST      A, [DP]                ; 53FB 1 208 180 D2
cfgvariant_apply_done:     RB      off(00232h).4          ; 53FC 1 208 180 C4320C
                RB      off(00232h).5          ; 53FF 1 208 180 C4320D
                CLR     A                      ; 5402 1 208 180 F9
                LB      A, r7                  ; 5403 0 208 180 7F
                LCB     A, cfgvariant_index_lookup_tbl[ACC]       ; 5404 0 208 180 B506AB556F
                CMPB    A, r6                  ; 5409 0 208 180 4E
                JNE     selftest_fail_043_checksum             ; 540A 0 208 180 CE4B
cfgvariant_apply_done_load_ram0f8:     L       A, 0f8h                ; 540C 1 208 180 E5F8
                ST      A, IE                  ; 540E 1 208 180 D51A
dtc_debounce2_check_goto_7a1b:     J       dtc_debounce2_check_load_dp             ; 5410 0 208 180 031B7A
dtc_debounce2_check_load_x1:     MOV     X1, #0011eh            ; 5413 0 208 180 601E01
                NOP                            ; 5416 0 208 180 00
                NOP                            ; 5417 0 208 180 00
calchecksum_loop:     DEC     DP                     ; 5418 0 208 180 82
                DEC     X1                     ; 5419 0 208 180 80
                LB      A, r0                  ; 541A 0 208 180 78
                ADDB    A, [DP]                ; 541B 0 208 180 C282
                STB     A, r0                  ; 541D 0 208 180 88
                LB      A, r1                  ; 541E 0 208 180 79
                XORB    A, [DP]                ; 541F 0 208 180 C2F2
                STB     A, r1                  ; 5421 0 208 180 89
                LB      A, 00000h[X1]          ; 5422 0 208 180 F00000
                STB     A, r2                  ; 5425 0 208 180 8A
                LB      A, [DP]                ; 5426 0 208 180 F2
                XORB    A, r2                  ; 5427 0 208 180 22F2
                ANDB    A, r2                  ; 5429 0 208 180 5A
                JNE     selftest_fail_043_checksum             ; 542A 0 208 180 CE2B
                CMP     DP, #0031eh            ; 542C 0 208 180 92C01E03
                JNE     calchecksum_loop             ; 5430 0 208 180 CEE6
                J       calchecksum_loop_dec_dp             ; 5432 0 208 180 03307A
calchecksum_loop_if_ne_goto_selftest_fail_043_checksum:     JNE     selftest_fail_043_checksum             ; 5435 0 208 180 CE20
                INC     DP                     ; 5437 0 208 180 72
                LB      A, [DP]                ; 5438 0 208 180 F2
                ANDB    A, #000h               ; 5439 0 208 180 D600
                JNE     selftest_fail_043_checksum             ; 543B 0 208 180 CE1A
                INC     DP                     ; 543D 0 208 180 72
                LB      A, [DP]                ; 543E 0 208 180 F2
                ANDB    A, #002h               ; 543F 0 208 180 D602
                JNE     selftest_fail_043_checksum             ; 5441 0 208 180 CE14
                INC     DP                     ; 5443 0 208 180 72
                LB      A, [DP]                ; 5444 0 208 180 F2
                ANDB    A, #088h               ; 5445 0 208 180 D688
                JNE     selftest_fail_043_checksum             ; 5447 0 208 180 CE0E
                INC     DP                     ; 5449 0 208 180 72
                L       A, [DP]                ; 544A 1 208 180 E2
                CMP     A, er0                 ; 544B 1 208 180 48
                JNE     selftest_fail_043_checksum             ; 544C 1 208 180 CE09
                VCAL    3                      ; 544E 1 208 180 13
                CAL     cfgvariant_checksum2_calc             ; 544F 1 208 180 322D5F
                INC     DP                     ; 5452 1 208 180 72
                L       A, [DP]                ; 5453 1 208 180 E2
                CMP     A, er0                 ; 5454 1 208 180 48
                JEQ     freezeframe_decode_start             ; 5455 1 208 180 C905
selftest_fail_043_checksum:     MOVB    0f5h, #043h            ; 5457 0 208 180 C5F59843
                BRK                            ; 545B 0 208 180 FF
freezeframe_decode_start:     VCAL    3                      ; 545C 1 208 180 13
                L       A, off(00212h)         ; 545D 1 208 180 E412
                ORB     A, off(00214h)         ; 545F 1 208 180 E714
                J       freezeframe_decode_start_load_carry_ram235_bit3             ; 5461 1 208 180 03407A
freezeframe_flag_218_7:     MB      off(00218h).7, C       ; 5464 1 208 180 C4183F
                JLT     freezeframe_flag_218_6             ; 5467 1 208 180 CA12
                ANDB    off(00218h), #0bfh     ; 5469 1 208 180 C418D0BF
                ANDB    off(0022bh), #0efh     ; 546D 1 208 180 C42BD0EF
                ANDB    off(00225h), #07fh     ; 5471 1 208 180 C425D07F
                ANDB    off(00234h), #07fh     ; 5475 1 208 180 C434D07F
                SJ      prep_lowpower_seq             ; 5479 1 208 180 CB41
freezeframe_flag_218_6:     L       A, off(00212h)         ; 547B 1 208 180 E412
                AND     A, #0fffdh             ; 547D 1 208 180 D6FDFF
                JNE     freezeframe_flag_22b_4             ; 5480 1 208 180 CE08
                L       A, off(00214h)         ; 5482 1 208 180 E414
                AND     A, #014f5h             ; 5484 1 208 180 D6F514
                JNE     freezeframe_flag_22b_4             ; 5487 1 208 180 CE01
                RC                             ; 5489 1 208 180 95
freezeframe_flag_22b_4:     MB      off(00218h).6, C       ; 548A 1 208 180 C4183E
                SC                             ; 548D 1 208 180 85
                L       A, off(00212h)         ; 548E 1 208 180 E412
                AND     A, #02054h             ; 5490 1 208 180 D65420
                JNE     freezeframe_flag_22b_4_store_carry_ram22b_bit4             ; 5493 1 208 180 CE04
                JBS     off(00214h).0, freezeframe_flag_22b_4_store_carry_ram22b_bit4 ; 5495 1 208 180 E81401
                RC                             ; 5498 1 208 180 95
freezeframe_flag_22b_4_store_carry_ram22b_bit4:     MB      off(0022bh).4, C       ; 5499 1 208 180 C42B3C
                J       freezeframe_flag_22b_4_set_carry             ; 549C 1 208 180 03497A
freezeframe_flag_22b_4_if_ne_goto_freezeframe_flag_next:     JNE     freezeframe_flag_next             ; 549F 1 208 180 CE08
                L       A, off(00214h)         ; 54A1 1 208 180 E414
                AND     A, #014fdh             ; 54A3 1 208 180 D6FD14
                JNE     freezeframe_flag_next             ; 54A6 1 208 180 CE01
                RC                             ; 54A8 1 208 180 95
freezeframe_flag_next:     MB      off(00225h).7, C       ; 54A9 1 208 180 C4253F
                J       freezeframe_flag_next_set_carry             ; 54AC 1 208 180 03557A
freezeframe_flag_next_if_ne_goto_54b9:     JNE     freezeframe_flag_next_store_carry_ram234_bit7             ; 54AF 1 208 180 CE08
                L       A, off(00214h)         ; 54B1 1 208 180 E414
                AND     A, #074f5h                              ; 54B3 1 208 180 D6F574
                JNE     freezeframe_flag_next_store_carry_ram234_bit7             ; 54B6 1 208 180 CE01
                RC                             ; 54B8 1 208 180 95
freezeframe_flag_next_store_carry_ram234_bit7:     MB      off(00234h).7, C       ; 54B9 1 208 180 C4343F
prep_lowpower_seq:     SB      off(00230h).3          ; 54BC 1 208 180 C4301B
                JNE     lowpower_trap_call             ; 54BF 1 208 180 CE31
                CAL     ResetWatchDog             ; 54C1 1 208 180 32E45B
                L       A, TM1                 ; 54C4 1 208 180 E534
                ADD     A, #00a00h             ; 54C6 1 208 180 86000A
                ST      A, TMR1                ; 54C9 1 208 180 D536
                MULB                           ; 54CB 1 208 180 A234
                DIV                            ; 54CD 1 208 180 9037
                DIV                            ; 54CF 1 208 180 9037
                MB      C, 0b7h.1              ; 54D1 1 208 180 C5B729
                JLT     prep_lowpower_ie_config             ; 54D4 1 208 180 CA07
                CAL     port_debounce_helper             ; 54D6 1 208 180 32A95B
                MOVB    0f7h, #020h            ; 54D9 1 208 180 C5F79820
prep_lowpower_ie_config:     MOV     0fah, #002a0h          ; 54DD 1 208 180 B5FA98A002
                L       A, #02babh             ; 54E2 1 208 180 67AB2B
                ST      A, 0f8h                ; 54E5 1 208 180 D5F8
                CLRB    TRNSIT                 ; 54E7 1 208 180 C54615
                CLR     IRQ                    ; 54EA 1 208 180 B51815
                RB      TCON0.2                ; 54ED 1 208 180 C5400A
                ST      A, IE                  ; 54F0 1 208 180 D51A
lowpower_trap_call:     J       regbank_selftest2_start             ; 54F2 1 208 180 03813E
crank_helper2:     JBR     off(00128h).2, injtimer_shift_path ; 54F5 1 108 280 DA283B
injector_timer_schedule:     MOVB    r0, #0ffh              ; 54F8 1 108 280 98FF
                L       A, off(00196h)         ; 54FA 1 108 280 E496
                ST      A, er1                 ; 54FC 1 108 280 89
                CMPB    off(00117h), #00fh     ; 54FD 1 108 280 C417C00F
                JNE     injtimer_schedule_done             ; 5501 1 108 280 CE6C
                L       A, TM0                 ; 5503 1 108 280 E530
                SUB     A, #00001h             ; 5505 1 108 280 A60100
                ST      A, TMR0                ; 5508 1 108 280 D532
                MOV     X1, #00110h            ; 550A 1 108 280 601001
                MOV     DP, #00190h            ; 550D 1 108 280 629001
                L       A, [DP]                ; 5510 1 108 280 E2
                CMP     A, #000c0h             ; 5511 1 108 280 C6C000
                JGE     injtimer_bank1_check2             ; 5514 1 108 280 CD3B
                CLR     A                      ; 5516 1 108 280 F9
                ST      A, [DP]                ; 5517 1 108 280 D2
                INC     DP                     ; 5518 1 108 280 72
                INC     DP                     ; 5519 1 108 280 72
                L       A, [DP]                ; 551A 1 108 280 E2
                CMP     A, #000c0h             ; 551B 1 108 280 C6C000
                JGE     injtimer_bank2_zero             ; 551E 1 108 280 CD20
                CLR     A                      ; 5520 1 108 280 F9
                ST      A, [DP]                ; 5521 1 108 280 D2
                INC     DP                     ; 5522 1 108 280 72
                INC     DP                     ; 5523 1 108 280 72
                L       A, [DP]                ; 5524 1 108 280 E2
                CMP     A, #000c0h             ; 5525 1 108 280 C6C000
                JLT     injtimer_bank3_check             ; 5528 1 108 280 CA23
                ST      A, er1                 ; 552A 1 108 280 89
                LB      A, off(00116h)         ; 552B 0 108 280 F416
                SRLB    A                      ; 552D 0 108 280 63
                RORB    off(00116h)            ; 552E 0 108 280 C416C7
                SJ      injtimer_schedule_common             ; 5531 0 108 280 CB36
injtimer_shift_path:     LB      A, off(0018eh)         ; 5533 0 108 280 F48E
                SLLB    A                      ; 5535 0 108 280 53
                ROLB    off(0018eh)            ; 5536 0 108 280 C48EB7
                LB      A, off(00116h)         ; 5539 0 108 280 F416
                SLLB    A                      ; 553B 0 108 280 53
                ROLB    off(00116h)            ; 553C 0 108 280 C416B7
                RT                             ; 553F 0 108 280 01
injtimer_bank2_zero:     ST      A, er1                 ; 5540 1 108 280 89
                LB      A, off(00116h)         ; 5541 0 108 280 F416
                SRLB    A                      ; 5543 0 108 280 63
                RORB    off(00116h)            ; 5544 0 108 280 C416C7
                SRLB    A                      ; 5547 0 108 280 63
                RORB    off(00116h)            ; 5548 0 108 280 C416C7
                SJ      injtimer_bank_mask_calc             ; 554B 0 108 280 CB14
injtimer_bank3_check:     CLR     A                      ; 554D 1 108 280 F9
                ST      A, [DP]                ; 554E 1 108 280 D2
                SJ      injtimer_schedule_done             ; 554F 1 108 280 CB1E
injtimer_bank1_check2:     ST      A, er1                 ; 5551 1 108 280 89
                LB      A, off(00116h)         ; 5552 0 108 280 F416
                SLLB    A                      ; 5554 0 108 280 53
                ROLB    off(00116h)            ; 5555 0 108 280 C416B7
                CAL     inj_wrap_clamp_calc             ; 5558 0 108 280 329956
                LB      A, off(0018eh)         ; 555B 0 108 280 F48E
                SRLB    A                      ; 555D 0 108 280 63
                SRLB    A                      ; 555E 0 108 280 63
                ANDB    r0, A                  ; 555F 0 108 280 20D1
injtimer_bank_mask_calc:     CAL     inj_wrap_clamp_calc             ; 5561 0 108 280 329956
                LB      A, off(0018eh)         ; 5564 0 108 280 F48E
                SRLB    A                      ; 5566 0 108 280 63
                ANDB    r0, A                  ; 5567 0 108 280 20D1
injtimer_schedule_common:     CAL     inj_wrap_clamp_calc             ; 5569 0 108 280 329956
                ANDB    r0, off(0018eh)        ; 556C 0 108 280 20D38E
injtimer_schedule_done:     LB      A, off(0018eh)         ; 556F 0 108 280 F48E
                SLLB    A                      ; 5571 0 108 280 53
                ROLB    off(0018eh)            ; 5572 0 108 280 C48EB7
                LB      A, r0                  ; 5575 0 108 280 78
                ANDB    A, off(0018eh)         ; 5576 0 108 280 D78E
                CMP     off(00196h), #000c0h   ; 5578 0 108 280 B496C0C000
                JLT     injenable_reset_all             ; 557D 0 108 280 CA40
                MOVB    r1, off(00117h)        ; 557F 0 108 280 C41749
                ANDB    off(00117h), A         ; 5582 0 108 280 C417D1
                JBS     off(0012ah).7, injenable_p2_update ; 5585 0 108 280 EF2A0A
                JBS     off(00124h).5, injenable_p2_update ; 5588 0 108 280 ED2407
                ANDB    off(0018fh), A         ; 558B 0 108 280 C48FD1
                ORB     off(0012ah), #001h     ; 558E 0 108 280 C42AE001
injenable_p2_update:     LB      A, off(0018fh)         ; 5592 0 108 280 F48F
                ORB     A, #0f0h               ; 5594 0 108 280 E6F0
                ANDB    P2, A                  ; 5596 0 108 280 C524D1
                ANDB    TRNSIT, #0fbh          ; 5599 0 108 280 C546D0FB
                ANDB    PSWH, #0feh            ; 559D 0 108 280 A2D0FE
                ORB     TCON0, #004h           ; 55A0 0 108 280 C540E004
                L       A, TM0                 ; 55A4 1 108 280 E530
                ORB     PSWH, #001h            ; 55A6 1 108 280 A2E001
                ANDB    TCON0, #0fbh           ; 55A9 1 108 280 C540D0FB
                CMPB    r1, #00fh              ; 55AD 1 108 280 21C00F
                JEQ     inj_accum2_direct             ; 55B0 1 108 280 C92B
                SUB     A, TMR0                ; 55B2 1 108 280 B532A2
                ADD     A, er1                 ; 55B5 1 108 280 09
                JBR     off(00109h).0, inj_accum_check1 ; 55B6 1 108 280 D80929
                JBR     off(00109h).2, inj_accum_check2 ; 55B9 1 108 280 DA0929
                J       inj_accum_check4             ; 55BC 1 108 280 032456
injenable_reset_all:     LB      A, #00fh               ; 55BF 0 108 280 770F
                STB     A, off(00117h)         ; 55C1 0 108 280 D417
                STB     A, off(0018fh)         ; 55C3 0 108 280 D48F
                ORB     P2, A                  ; 55C5 0 108 280 C524E1
                SB      TCON0.2                ; 55C8 0 108 280 C5401A
                LB      A, off(0018eh)         ; 55CB 0 108 280 F48E
                XORB    A, #0ffh               ; 55CD 0 108 280 F6FF
                MB      C, ACC.7               ; 55CF 0 108 280 C5062F
                ROLB    A                      ; 55D2 0 108 280 33
                STB     A, off(00116h)         ; 55D3 0 108 280 D416
                RB      TCON0.2                ; 55D5 0 108 280 C5400A
                L       A, #00001h             ; 55D8 1 108 280 670100
                SJ      inj_accum1_store_new             ; 55DB 1 108 280 CB4F
inj_accum2_direct:     ADD     A, er1                 ; 55DD 1 108 280 09
; [H] --- Dual-accumulator injector timing calc (0x46A3-0x4723ish): manages two 16-bit
; [H] accumulators (0x110/0x112, capped/wrapped at 0x100) feeding TMR0 reschedule -- likely
; [H] timing for two injector groups/banks. No calibration anchors; named at the mechanism level.
                ST      A, TMR0                ; 55DE 1 108 280 D532
                SJ      inj_p2_calc_start             ; 55E0 1 108 280 CB7D
inj_accum_check1:     JBR     off(00109h).2, inj_accum_dispatch ; 55E2 1 108 280 DA0906
inj_accum_check2:     JBS     off(00109h).3, inj_accum_check5 ; 55E5 1 108 280 EB095C
                JBS     off(00109h).1, inj_accum_dispatch2 ; 55E8 1 108 280 E9095C
inj_accum_dispatch:     JGE     inj_accum_direct_add             ; 55EB 1 108 280 CD2C
                SUB     A, off(00110h)         ; 55ED 1 108 280 A710
                JLT     inj_accum1_add             ; 55EF 1 108 280 CA11
                SUB     A, off(00112h)         ; 55F1 1 108 280 A712
                JGE     inj_accum_check3             ; 55F3 1 108 280 CD1C
                ADD     A, off(00112h)         ; 55F5 1 108 280 8712
                CMP     A, #00100h             ; 55F7 1 108 280 C60001
                JLT     inj_accum2_zero             ; 55FA 1 108 280 CA0F
                ST      A, off(00112h)         ; 55FC 1 108 280 D412
                CLR     A                      ; 55FE 1 108 280 F9
                J       inj_accum_store_114             ; 55FF 1 108 280 035D56
inj_accum1_add:     ADD     A, off(00110h)         ; 5602 1 108 280 8710
                CMP     A, #00100h             ; 5604 1 108 280 C60001
                JLT     inj_accum_both_zero             ; 5607 1 108 280 CA13
                ST      A, off(00110h)         ; 5609 1 108 280 D410
inj_accum2_zero:     CLR     A                      ; 560B 1 108 280 F9
                ST      A, off(00112h)         ; 560C 1 108 280 D412
                J       inj_accum_store_114             ; 560E 1 108 280 035D56
inj_accum_check3:     CMP     A, #00100h             ; 5611 1 108 280 C60001
                JGE     inj_accum_store_114             ; 5614 1 108 280 CD47
                CLR     A                      ; 5616 1 108 280 F9
                SJ      inj_accum_store_114             ; 5617 1 108 280 CB44
inj_accum_direct_add:     ADD     TMR0, A                ; 5619 1 108 280 B53281
inj_accum_both_zero:     CLR     A                      ; 561C 1 108 280 F9
                ST      A, off(00110h)         ; 561D 1 108 280 D410
                ST      A, off(00112h)         ; 561F 1 108 280 D412
                J       inj_accum_store_114             ; 5621 1 108 280 035D56
inj_accum_check4:     JGE     inj_accum_check4_add_tmr0             ; 5624 1 108 280 CD10
                CMP     A, #00100h             ; 5626 1 108 280 C60001
                JGE     inj_accum1_store_new             ; 5629 1 108 280 CD01
                CLR     A                      ; 562B 1 108 280 F9
inj_accum1_store_new:     ST      A, off(00110h)         ; 562C 1 108 280 D410
                L       A, #00001h             ; 562E 1 108 280 670100
                ST      A, off(00112h)         ; 5631 1 108 280 D412
                J       inj_accum_store_114             ; 5633 1 108 280 035D56
inj_accum_check4_add_tmr0:     ADD     TMR0, A                ; 5636 1 108 280 B53281
                CLR     A                      ; 5639 1 108 280 F9
                ST      A, off(00110h)         ; 563A 1 108 280 D410
inj_accum_check4_load_imm:       L       A, #00001h             ; 563C 1 108 280 670100
                ST      A, off(00112h)         ; 563F 1 108 280 D412
                J       inj_accum_store_114             ; 5641 1 108 280 035D56
inj_accum_check5:     JBS     off(00109h).1, inj_accum_check4 ; 5644 1 108 280 E909DD
inj_accum_dispatch2:     JGE     inj_accum_dispatch2_add_tmr0             ; 5647 1 108 280 CD4B
                SUB     A, off(00110h)         ; 5649 1 108 280 A710
                JGE     inj_accum1_wrap_check             ; 564B 1 108 280 CD40
                ADD     A, off(00110h)         ; 564D 1 108 280 8710
                CMP     A, #00100h             ; 564F 1 108 280 C60001
                JGE     inj_accum1_store2             ; 5652 1 108 280 CD01
inj_accum1_zero2:     CLR     A                      ; 5654 1 108 280 F9
inj_accum1_store2:     ST      A, off(00110h)         ; 5655 1 108 280 D410
inj_accum2_zero2:     CLR     A                      ; 5657 1 108 280 F9
inj_accum2_store2:     ST      A, off(00112h)         ; 5658 1 108 280 D412
                L       A, #00001h             ; 565A 1 108 280 670100
inj_accum_store_114:     ST      A, off(00114h)         ; 565D 1 108 280 D414
inj_p2_calc_start:     L       A, off(00110h)         ; 565F 1 108 280 E410
                JNE     inj_p2_calc_alt             ; 5661 1 108 280 CE0E
                L       A, off(00112h)         ; 5663 1 108 280 E412
                JEQ     inj_p2_calc_check114             ; 5665 1 108 280 C90E
                LB      A, off(00116h)         ; 5667 0 108 280 F416
                SRLB    A                      ; 5669 0 108 280 63
                SRLB    A                      ; 566A 0 108 280 63
                SRLB    A                      ; 566B 0 108 280 63
                ORB     A, off(00116h)         ; 566C 0 108 280 E716
                J       inj_p2_calc_or197             ; 566E 0 108 280 037E56
inj_p2_calc_alt:     LB      A, off(00116h)         ; 5671 0 108 280 F416
                SJ      inj_p2_calc_or197             ; 5673 0 108 280 CB09
inj_p2_calc_check114:     L       A, off(00114h)         ; 5675 1 108 280 E414
                JEQ     inj_p2_default_f             ; 5677 1 108 280 C910
                LB      A, off(00116h)         ; 5679 0 108 280 F416
                RORB    A                      ; 567B 0 108 280 43
                XORB    A, #0ffh               ; 567C 0 108 280 F6FF
inj_p2_calc_or197:     ORB     A, off(0018fh)         ; 567E 0 108 280 E78F
                ANDB    A, #00fh               ; 5680 0 108 280 D60F
inj_p2_drive_return:     ORB     P2, A                  ; 5682 0 108 280 C524E1
                RB      off(0012ah).7          ; 5685 0 108 280 C42A0F
                RT                             ; 5688 0 108 280 01
inj_p2_default_f:     LB      A, #00fh               ; 5689 0 108 280 770F
                SJ      inj_p2_drive_return             ; 568B 0 108 280 CBF5
inj_accum1_wrap_check:     CMP     A, #00100h             ; 568D 1 108 280 C60001
                JLT     inj_accum2_zero2             ; 5690 1 108 280 CAC5
                SJ      inj_accum2_store2             ; 5692 1 108 280 CBC4
inj_accum_dispatch2_add_tmr0:     ADD     TMR0, A                ; 5694 1 108 280 B53281
                SJ      inj_accum1_zero2             ; 5697 1 108 280 CBBB
inj_wrap_clamp_calc:     CLR     A                      ; 5699 1 108 280 F9
                XCHG    A, [DP]                ; 569A 1 108 280 B210
                MOV     X2, A                  ; 569C 1 108 280 51
                INC     DP                     ; 569D 1 108 280 72
                INC     DP                     ; 569E 1 108 280 72
                L       A, [DP]                ; 569F 1 108 280 E2
                SUB     A, X2                  ; 56A0 1 108 280 91A2
                JLT     inj_wrap_clamp_zero             ; 56A2 1 108 280 CA05
                CMP     A, #00100h             ; 56A4 1 108 280 C60001
                JGE     inj_wrap_clamp_store             ; 56A7 1 108 280 CD01
inj_wrap_clamp_zero:     CLR     A                      ; 56A9 1 108 280 F9
inj_wrap_clamp_store:     ST      A, 00000h[X1]          ; 56AA 1 108 280 D00000
                INC     X1                     ; 56AD 1 108 280 70
                INC     X1                     ; 56AE 1 108 280 70
                RT                             ; 56AF 1 108 280 01
knock_helper1:     MOVB    r6, #077h              ; 56B0 0 208 180 9E77
                JEQ     bitreverse_return             ; 56B2 0 208 180 C908
bitreverse_loop:     MB      C, r6.7                ; 56B4 0 208 180 262F
                ROLB    r6                     ; 56B6 0 208 180 26B7
                SUBB    A, #001h               ; 56B8 0 208 180 A601
                JNE     bitreverse_loop             ; 56BA 0 208 180 CEF8
bitreverse_return:     LB      A, r6                  ; 56BC 0 208 180 7E
                RT                             ; 56BD 0 208 180 01
tm0_resync_helper:     L       A, TMR2                ; 56BE 1 108 280 E53A
                JBR     off(0011fh).2, tm0_resync_store_er3 ; 56C0 1 108 280 DA1F02
                L       A, 0f0h                ; 56C3 1 108 280 E5F0
tm0_resync_store_er3:     ST      A, er3                 ; 56C5 1 108 280 8B
                JBS     off(0010fh).7, rpm_resync_gate ; 56C6 1 108 280 EF0F0B
                MB      C, IRQH.0              ; 56C9 1 108 280 C51928
                JGE     rpm_resync_gate             ; 56CC 1 108 280 CD06
                INCB    0aeh                   ; 56CE 1 108 280 C5AE16
                SB      0b6h.0                 ; 56D1 1 108 280 C5B618
rpm_resync_gate:     SB      off(00128h).3          ; 56D4 1 108 280 C4281B
                JEQ     rpm_resync_common             ; 56D7 1 108 280 C93A
                SUB     A, 0eeh                ; 56D9 1 108 280 B5EEA2
                JBR     off(0011fh).2, rpm_resync_tcon2_check ; 56DC 1 108 280 DA1F22
                CLRB    r1                     ; 56DF 1 108 280 2115
                MOVB    r0, 0aeh               ; 56E1 1 108 280 C5AE48
                SBCB    r0, #000h              ; 56E4 1 108 280 20B000
                MOV     er2, #00006h           ; 56E7 1 108 280 46980600
                DIV                            ; 56EB 1 108 280 9037
                CMPB    r0, #000h              ; 56ED 1 108 280 20C000
                JEQ     rpm_period_reset_calc             ; 56F0 1 108 280 C901
                CLR     A                      ; 56F2 1 108 280 F9
rpm_period_reset_calc:     ST      A, off(00136h)         ; 56F3 1 108 280 D436
                MOV     X1, #0000ch            ; 56F5 1 108 280 600C00
rpm_period_reset_loop:     DEC     X1                     ; 56F8 1 108 280 80
                DEC     X1                     ; 56F9 1 108 280 80
                ST      A, 00360h[X1]          ; 56FA 1 108 280 D06003
                JNE     rpm_period_reset_loop             ; 56FD 1 108 280 CEF9
                SJ      rpm_resync_common             ; 56FF 1 108 280 CB12
rpm_resync_tcon2_check:     MB      C, TCON2.2             ; 5701 1 108 280 C5422A
                JGE     rpm_resync_store136             ; 5704 1 108 280 CD01
                CLR     A                      ; 5706 1 108 280 F9
rpm_resync_store136:     ST      A, off(00136h)         ; 5707 1 108 280 D436
                LB      A, 0a2h                ; 5709 0 108 280 F5A2
                SLLB    A                      ; 570B 0 108 280 53
                EXTND                          ; 570C 1 108 280 F8
                MOV     X1, A                  ; 570D 1 108 280 50
                L       A, off(00136h)         ; 570E 1 108 280 E436
                ST      A, 00360h[X1]          ; 5710 1 108 280 D06003
rpm_resync_common:     L       A, er3                 ; 5713 1 108 280 37
                ST      A, 0eeh                ; 5714 1 108 280 D5EE
                CLRB    0aeh                   ; 5716 1 108 280 C5AE15
                CMPB    0a2h, #005h            ; 5719 1 108 280 C5A2C005
                JNE     crank_a3_gate             ; 571D 1 108 280 CE03
                SLLB    off(0019bh)            ; 571F 1 108 280 C49BD7
crank_a3_gate:     JBS     off(0019bh).2, crank_dp_35e ; 5722 1 108 280 EA9B0E
                MOV     DP, #00358h            ; 5725 1 108 280 625803
                MB      C, 0b8h.0              ; 5728 1 108 280 C5B828
                SJ      crank_pswl4_store             ; 572B 1 108 280 CB0C
crank_mul_alt:     MULB                           ; 572D 0 108 280 A234
crank_mul_common:     MULB                           ; 572F 0 108 280 A234
                SJ      crank_a2_advance             ; 5731 0 108 280 CB2E
crank_dp_35e:     MOV     DP, #0035eh            ; 5733 1 108 280 625E03
                MB      C, 0b8h.1              ; 5736 1 108 280 C5B829
crank_pswl4_store:     MB      PSWL.4, C              ; 5739 1 108 280 A33C
                LB      A, 0a2h                ; 573B 0 108 280 F5A2
                CMPB    A, #004h               ; 573D 0 108 280 C604
                JEQ     crank_mul_alt             ; 573F 0 108 280 C9EC
                JGE     crank_a0_update             ; 5741 0 108 280 CD12
                STB     A, r0                  ; 5743 0 108 280 88
                INCB    r0                     ; 5744 0 108 280 A8
                LB      A, 0a0h                ; 5745 0 108 280 F5A0
                ADDB    A, #001h               ; 5747 0 108 280 8601
                CMPB    A, r0                  ; 5749 0 108 280 48
                JLE     crank_mul_common             ; 574A 0 108 280 CFE3
                LB      A, [DP]                ; 574C 0 108 280 F2
                ADDB    A, #001h               ; 574D 0 108 280 8601
                CMPB    A, r0                  ; 574F 0 108 280 48
                JLE     crank_mul_common             ; 5750 0 108 280 CFDD
                JBR     off(0011fh).0, crank_mul_common ; 5752 0 108 280 D81FDA
crank_a0_update:     L       A, [DP]                ; 5755 1 108 280 E2
                ST      A, 0a0h                ; 5756 1 108 280 D5A0
                DEC     DP                     ; 5758 1 108 280 82
                LB      A, [DP]                ; 5759 0 108 280 F2
                STB     A, 09fh                ; 575A 0 108 280 D59F
                MB      C, PSWL.4              ; 575C 0 108 280 A32C
                MB      off(0012ah).5, C       ; 575E 0 108 280 C42A3D
crank_a2_advance:     CLR     A                      ; 5761 1 108 280 F9
                MOV     er0, 0a0h              ; 5762 1 108 280 B5A048
                ST      A, er3                 ; 5765 1 108 280 8B
                LB      A, 0a2h                ; 5766 0 108 280 F5A2
                ADDB    A, #001h               ; 5768 0 108 280 8601
                CMPB    A, r0                  ; 576A 0 108 280 48
                JEQ     crank_mul_common2             ; 576B 0 108 280 C918
                CMPB    A, #006h               ; 576D 0 108 280 C606
                JNE     crank_a2_check3             ; 576F 0 108 280 CE06
                LB      A, r0                  ; 5771 0 108 280 78
                JEQ     crank_mul_common2             ; 5772 0 108 280 C911
                SLLB    A                      ; 5774 0 108 280 53
                JLT     crank_mul_common2             ; 5775 0 108 280 CA0E
crank_a2_check3:     CMPB    0a2h, #003h            ; 5777 0 108 280 C5A2C003
                JNE     crank_mul_alt2             ; 577B 0 108 280 CE26
                CMPB    r0, #005h              ; 577D 0 108 280 20C005
                JNE     crank_mul_alt2             ; 5780 0 108 280 CE21
                MOV     er3, off(00136h)       ; 5782 0 108 280 B4364B
crank_mul_common2:     CLRB    r0                     ; 5785 0 108 280 2015
                L       A, off(00136h)         ; 5787 1 108 280 E436
                MUL                            ; 5789 1 108 280 9035
                LB      A, 0a0h                ; 578B 0 108 280 F5A0
                SLLB    A                      ; 578D 0 108 280 53
                JGE     crank_mul_common2_load_er3             ; 578E 0 108 280 CD2E
                ANDB    PSWH, #0feh            ; 5790 0 108 280 A2D0FE
                L       A, TM3                 ; 5793 1 108 280 E53C
                SUB     A, TMR2                ; 5795 1 108 280 B53AA2
                ADD     A, #00010h             ; 5798 1 108 280 861000
                CMP     A, er1                 ; 579B 1 108 280 49
                JGE     crank_mul_common2_clear_tcon3_bit2             ; 579C 1 108 280 CD0D
                L       A, TMR2                ; 579E 1 108 280 E53A
                ADD     A, er1                 ; 57A0 1 108 280 09
                SJ      tmr3_reload_store2             ; 57A1 1 108 280 CB10
crank_mul_alt2:     MUL                            ; 57A3 0 108 280 9035
                RB      r0.0                   ; 57A5 0 108 280 2008
                L       A, ACC                 ; 57A7 1 108 280 E506
                SJ      tmr3_reload_clamp_min             ; 57A9 1 108 280 CB1F
crank_mul_common2_clear_tcon3_bit2:     RB      TCON3.2                ; 57AB 1 108 280 C5430A
                L       A, TM3                 ; 57AE 1 108 280 E53C
                SUB     A, #00001h             ; 57B0 1 108 280 A60100
tmr3_reload_store2:     ST      A, TMR3                ; 57B3 1 108 280 D53E
                RB      TCON3.3                ; 57B5 1 108 280 C5430B
                ORB     PSWH, #001h            ; 57B8 1 108 280 A2E001
                J       tmr3_reload_clamp_min             ; 57BB 1 108 280 03CA57
crank_mul_common2_load_er3:     L       A, er3                 ; 57BE 1 108 280 37
                ADD     A, er1                 ; 57BF 1 108 280 09
                JGE     tmr3_reload_clamp_check             ; 57C0 1 108 280 CD03
                L       A, #0ffffh             ; 57C2 1 108 280 67FFFF
tmr3_reload_clamp_check:     CMP     A, #0001fh             ; 57C5 1 108 280 C61F00
                JGE     tmr3_store_e8             ; 57C8 1 108 280 CD03
tmr3_reload_clamp_min:     L       A, #0001fh             ; 57CA 1 108 280 671F00
tmr3_store_e8:     ST      A, 0e8h                ; 57CD 1 108 280 D5E8
                MOV     DP, #00f00h            ; 57CF 1 108 280 62000F
                LB      A, [DP]                ; 57D2 0 108 280 F2
                SRLB    A                      ; 57D3 0 108 280 63
                ROR     off(001a2h)            ; 57D4 0 108 280 B4A2C7
                SRLB    A                      ; 57D7 0 108 280 63
                ROR     off(001a2h)            ; 57D8 0 108 280 B4A2C7
                LB      A, 0a2h                ; 57DB 0 108 280 F5A2
                JNE     crank_a2_check4             ; 57DD 0 108 280 CE06
                CLR     A                      ; 57DF 1 108 280 F9
                XCHG    A, off(001a2h)         ; 57E0 1 108 280 B4A210
                ST      A, 0ech                ; 57E3 1 108 280 D5EC
crank_a2_check4:     LB      A, 0a2h                ; 57E5 0 108 280 F5A2
                CMPB    A, #001h               ; 57E7 0 108 280 C601
                JNE     crank_a8_p1_output             ; 57E9 0 108 280 CE04
                L       A, 0eah                ; 57EB 1 108 280 E5EA
                ST      A, off(001a0h)         ; 57ED 1 108 280 D4A0
crank_a8_p1_output:     L       A, off(001a0h)         ; 57EF 1 108 280 E4A0
                SRL     A                      ; 57F1 1 108 280 63
                MB      P1.7, C                ; 57F2 1 108 280 C5223F
                SRL     A                      ; 57F5 1 108 280 63
                MB      P1.3, C                ; 57F6 1 108 280 C5223B
                ST      A, off(001a0h)         ; 57F9 1 108 280 D4A0
                MOV     DP, #02f00h            ; 57FB 1 108 280 62002F
                LB      A, P1                  ; 57FE 0 108 280 F522
                STB     A, [DP]                ; 5800 0 108 280 D2
                RT                             ; 5801 0 108 280 01
ign_angle_to_timer_convert:     CLRB    A                      ; 5802 0 200 180 FA
; [H] --- Converts a computed ignition angle/trim (r4) into a hardware timer-compare value
; [H] (scaling via MULB by 3 and combining with er1), used when programming the two ignition
; [H] coil-channel hardware timers (igntiming_output_coil1 and the DP=0x35D channel that follows).
; [H] Clamps the result if it would exceed 0xFE00 range (CMPB ACC,#0feh check).
                STB     A, r3                  ; 5803 0 200 180 8B
                SUBB    A, r4                  ; 5804 0 200 180 2C
                MOVB    r0, #003h              ; 5805 0 200 180 9803
                MULB                           ; 5807 0 200 180 A234
                L       A, ACC                 ; 5809 1 200 180 E506
                SUB     A, er1                 ; 580B 1 200 180 29
                SLL     A                      ; 580C 1 200 180 53
                SWAP                           ; 580D 1 200 180 83
                CMPB    ACC, #0feh             ; 580E 1 200 180 C506C0FE
                JNE     ign_timer_clamp_store             ; 5812 1 200 180 CE03
                L       A, #000ffh             ; 5814 1 200 180 67FF00
ign_timer_clamp_store:     ST      A, er0                 ; 5817 1 200 180 88
                CLRB    A                      ; 5818 0 200 180 FA
                SUBB    A, r2                  ; 5819 0 200 180 2A
                SLLB    A                      ; 581A 0 200 180 53
                JNE     ign_timer_convert_return             ; 581B 0 200 180 CE03
                LB      A, #0ffh               ; 581D 0 200 180 77FF
                SC                             ; 581F 0 200 180 85
ign_timer_convert_return:     RT                             ; 5820 0 200 180 01
knockretard_helper:     STB     A, r0                  ; 5821 0 200 180 88
                LC      A, [X1]                ; 5822 0 200 180 90A8
                CMPB    r0, A                  ; 5824 0 200 180 20C1
                JLT     knockretard_r1_store             ; 5826 0 200 180 CA01
                STB     A, r0                  ; 5828 0 200 180 88
knockretard_r1_store:     STB     A, r1                  ; 5829 0 200 180 89
                LB      A, ACCH                ; 582A 0 200 180 F507
                CMPB    r0, A                  ; 582C 0 200 180 20C1
                JGE     knockretard_sub_result             ; 582E 0 200 180 CD01
                STB     A, r0                  ; 5830 0 200 180 88
knockretard_sub_result:     SUBB    r0, A                  ; 5831 0 200 180 20A1
                SUBB    r1, A                  ; 5833 0 200 180 21A1
                LB      A, r7                  ; 5835 0 200 180 7F
                J       table_interp_delta_calc             ; 5836 0 200 180 035558
table_interp_lookup:     CMPCB   A, 00002h[X1]          ; 5839 0 200 180 90AF0200
; [H] --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; [H] fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; [H] pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; [H] find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; [H] same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found             ; 583D 0 200 180 CD05
                INC     X1                     ; 583F 0 200 180 70
                INC     X1                     ; 5840 0 200 180 70
                J       table_interp_lookup             ; 5841 0 200 180 033958
table_interp_bracket_found:     STB     A, r0                  ; 5844 0 200 180 88
                LC      A, 00002h[X1]          ; 5845 0 200 180 90A90200
                MOVB    r6, ACCH               ; 5849 0 200 180 C5074E
                STB     A, r1                  ; 584C 0 200 180 89
                SUBB    r0, A                  ; 584D 0 200 180 20A1
                LC      A, [X1]                ; 584F 0 200 180 90A8
                SUBB    A, r1                  ; 5851 0 200 180 29
                STB     A, r1                  ; 5852 0 200 180 89
                LB      A, ACCH                ; 5853 0 200 180 F507
table_interp_delta_calc:     SUBB    A, r6                  ; 5855 0 200 180 2E
                JGE     table_interp_scale_add             ; 5856 0 200 180 CD0D
                STB     A, r7                  ; 5858 0 200 180 8F
                CLRB    A                      ; 5859 0 200 180 FA
                SUBB    A, r7                  ; 585A 0 200 180 2F
                MULB                           ; 585B 0 200 180 A234
                MOVB    r0, r1                 ; 585D 0 200 180 2148
                DIVB                           ; 585F 0 200 180 A236
                SUBB    r6, A                  ; 5861 0 200 180 26A1
                LB      A, r6                  ; 5863 0 200 180 7E
                RT                             ; 5864 0 200 180 01
table_interp_scale_add:     MULB                           ; 5865 0 200 180 A234
                MOVB    r0, r1                 ; 5867 0 200 180 2148
                DIVB                           ; 5869 0 200 180 A236
                ADDB    A, r6                  ; 586B 0 200 180 0E
                STB     A, r6                  ; 586C 0 200 180 8E
                RT                             ; 586D 0 200 180 01
vcal_1:         CMPCB   A, [X1]                ; 586E 0 200 180 90AE
                JLE     vcal1_bracket_check             ; 5870 0 200 180 CF02
                LCB     A, [X1]                ; 5872 0 200 180 90AA
vcal1_bracket_check:     CMPCB   A, 00002h[X1]          ; 5874 0 200 180 90AF0200
                JGE     table_interp_bracket_found             ; 5878 0 200 180 CDCA
                LCB     A, 00002h[X1]          ; 587A 0 200 180 90AB0200
                J       table_interp_bracket_found             ; 587E 0 200 180 034458
vcal_2:         CMPCB   A, [X1]                ; 5881 0 208 180 90AE
                JLE     vcal2_bracket_check             ; 5883 0 208 180 CF02
                LCB     A, [X1]                ; 5885 0 208 180 90AA
vcal2_bracket_check:     CMPCB   A, 00003h[X1]          ; 5887 0 208 180 90AF0300
                JGE     vcal_common_interp             ; 588B 0 208 180 CD14
                LCB     A, 00003h[X1]          ; 588D 0 208 180 90AB0300
                J       vcal_common_interp             ; 5891 0 208 180 03A158
vcal_0:         CMPCB   A, 00003h[X1]          ; 5894 0 208 180 90AF0300
                JGE     vcal_common_interp             ; 5898 0 208 180 CD07
                ADD     X1, #00003h            ; 589A 0 208 180 90800300
                J       vcal_0                 ; 589E 0 208 180 039458
vcal_common_interp:     STB     A, r0                  ; 58A1 0 208 180 88
                CLR     A                      ; 58A2 1 208 180 F9
                LC      A, [X1]                ; 58A3 1 208 180 90A8
                ST      A, er2                 ; 58A5 1 208 180 8A
                LC      A, 00004h[X1]          ; 58A6 1 208 180 90A90400
                ST      A, er3                 ; 58AA 1 208 180 8B
                LC      A, 00002h[X1]          ; 58AB 1 208 180 90A90200
                SWAP                           ; 58AF 1 208 180 83
                SUBB    r0, A                  ; 58B0 1 208 180 20A1
                SUBB    r4, A                  ; 58B2 1 208 180 24A1
                CLRB    A                      ; 58B4 0 208 180 FA
                STB     A, r1                  ; 58B5 0 208 180 89
                XCHGB   A, r5                  ; 58B6 0 208 180 2510
                L       A, ACC                 ; 58B8 1 208 180 E506
injtimer_bank_calc3:     SUB     A, er3                 ; 58BA 1 200 180 2B
                JGE     injtimer_bank_calc3_alt             ; 58BB 1 200 180 CD0D
                ST      A, er1                 ; 58BD 1 200 180 89
                CLR     A                      ; 58BE 1 200 180 F9
                SUB     A, er1                 ; 58BF 1 200 180 29
                MUL                            ; 58C0 1 200 180 9035
                MOV     er0, er1               ; 58C2 1 200 180 4548
                DIV                            ; 58C4 1 200 180 9037
                SUB     er3, A                 ; 58C6 1 200 180 47A1
                L       A, er3                 ; 58C8 1 200 180 37
                RT                             ; 58C9 1 200 180 01
injtimer_bank_calc3_alt:     MUL                            ; 58CA 1 200 180 9035
                MOV     er0, er1               ; 58CC 1 200 180 4548
                DIV                            ; 58CE 1 200 180 9037
                ADD     A, er3                 ; 58D0 1 200 180 0B
                ST      A, er3                 ; 58D1 1 200 180 8B
                RT                             ; 58D2 1 200 180 01
table_interp_lookup_4byte:     CMPC    A, 00004h[X1]          ; 58D3 1 200 180 90AD0400
                JGE     table_interp_4byte_bracket             ; 58D7 1 200 180 CD07
                ADD     X1, #00004h            ; 58D9 1 200 180 90800400
                J       table_interp_lookup_4byte             ; 58DD 1 200 180 03D358
table_interp_4byte_bracket:     ST      A, er0                 ; 58E0 1 200 180 88
                LC      A, 00004h[X1]          ; 58E1 1 200 180 90A90400
                ST      A, er2                 ; 58E5 1 200 180 8A
                SUB     er0, A                 ; 58E6 1 200 180 44A1
                LC      A, [X1]                ; 58E8 1 200 180 90A8
                SUB     A, er2                 ; 58EA 1 200 180 2A
                ST      A, er2                 ; 58EB 1 200 180 8A
                LC      A, 00006h[X1]          ; 58EC 1 200 180 90A90600
                ST      A, er3                 ; 58F0 1 200 180 8B
                LC      A, 00002h[X1]          ; 58F1 1 200 180 90A90200
                J       injtimer_bank_calc3             ; 58F5 1 200 180 03BA58
sub_clamp_helper:     SUBB    A, #018h               ; 58F8 0 200 180 A618
                JLT     sub_clamp_zero             ; 58FA 0 200 180 CA09
                MB      C, ACCH.7              ; 58FC 0 200 180 C5072F
                ROLB    A                      ; 58FF 0 200 180 33
                JGE     sub_clamp_return             ; 5900 0 200 180 CD02
                LB      A, #0ffh               ; 5902 0 200 180 77FF
sub_clamp_return:     RT                             ; 5904 0 200 180 01
sub_clamp_zero:     CLRB    A                      ; 5905 0 200 180 FA
                RT                             ; 5906 0 200 180 01
mul_scale_helper2:     MUL                            ; 5907 1 208 180 9035
                MOV     er2, er1               ; 5909 1 208 180 454A
                CLR     A                      ; 590B 1 208 180 F9
                SUB     A, er0                 ; 590C 1 208 180 28
                MOV     er0, [DP]              ; 590D 1 208 180 B248
                MUL                            ; 590F 1 208 180 9035
                L       A, er1                 ; 5911 1 208 180 35
                ADD     A, er2                 ; 5912 1 208 180 0A
                ST      A, [DP]                ; 5913 1 208 180 D2
                RT                             ; 5914 1 208 180 01
rpm_accel_track_helper:     MUL                            ; 5915 1 208 180 9035
                MOV     DP, er1                ; 5917 1 208 180 457A
                MOV     X2, A                  ; 5919 1 208 180 51
                L       A, er3                 ; 591A 1 208 180 37
                MUL                            ; 591B 1 208 180 9035
                SUB     er2, A                 ; 591D 1 208 180 46A1
                L       A, er1                 ; 591F 1 208 180 35
                SBC     er3, A                 ; 5920 1 208 180 47B1
                L       A, X2                  ; 5922 1 208 180 41
                ADD     er2, A                 ; 5923 1 208 180 4681
                L       A, DP                  ; 5925 1 208 180 42
                ADC     A, er3                 ; 5926 1 208 180 1B
                RT                             ; 5927 1 208 180 01
injtimer_bank_calc1:     MOV     er2, 00000h[X1]        ; 5928 1 208 180 B000004A
                SUB     A, er2                 ; 592C 1 208 180 2A
                JGE     injtimer_bank_calc1_mul             ; 592D 1 208 180 CD03
                ST      A, er1                 ; 592F 1 208 180 89
                CLR     A                      ; 5930 1 208 180 F9
                SUB     A, er1                 ; 5931 1 208 180 29
injtimer_bank_calc1_mul:     MUL                            ; 5932 1 208 180 9035
                ST      A, er0                 ; 5934 1 208 180 88
                L       A, 00002h[X1]          ; 5935 1 208 180 E00200
                SJ      injtimer_bank_calc1_sign             ; 5938 1 208 180 CB11
vcal3_leanprotect_ratelimit_sub_load_er2:     MOV     er2, 00000h[X1]        ; 593A 1 208 180 B000004A
                SUB     A, er2                 ; 593E 1 208 180 2A
                JGE     vcal3_leanprotect_ratelimit_sub_mul_acc             ; 593F 1 208 180 CD03
                ST      A, er1                 ; 5941 1 208 180 89
                CLR     A                      ; 5942 1 208 180 F9
                SUB     A, er1                 ; 5943 1 208 180 29
vcal3_leanprotect_ratelimit_sub_mul_acc:     MUL                            ; 5944 1 208 180 9035
                ST      A, er0                 ; 5946 1 208 180 88
                MOV     DP, #00384h            ; 5947 1 208 180 628403
                L       A, [DP]                ; 594A 1 208 180 E2
injtimer_bank_calc1_sign:     JGE     injtimer_bank_calc1_add             ; 594B 1 208 180 CD05
                SUB     A, er0                 ; 594D 1 208 180 28
                ST      A, er0                 ; 594E 1 208 180 88
                L       A, er2                 ; 594F 1 208 180 36
                SBC     A, er1                 ; 5950 1 208 180 39
                RT                             ; 5951 1 208 180 01
injtimer_bank_calc1_add:     ADD     A, er0                 ; 5952 1 208 180 08
                ST      A, er0                 ; 5953 1 208 180 88
                L       A, er2                 ; 5954 1 208 180 36
                ADC     A, er1                 ; 5955 1 208 180 19
                RT                             ; 5956 1 208 180 01
                DB  0E2h ; 5957
vcal_4:         ROL     A                      ; 5958 1 208 180 33
; [H] --- RESOLVED: VCAL 4 is a saturating signed 16-bit add-to-er3 helper (clamps to 0 if the
; [H] result would go negative). VCAL 5 (below) is similar but clamps to 0xFFFF on overflow
; [H] instead. Both are widely used throughout the session (idle PID, injector timer calcs, etc)
; [H] -- this resolves the "not yet identified" hedge attached to several VCAL 4/5 call sites.
                JGE     vcal4_negative_path             ; 5959 1 208 180 CD07
                ROR     A                      ; 595B 1 208 180 43
                ADD     A, er3                 ; 595C 1 208 180 0B
                JLT     vcal4_store             ; 595D 1 208 180 CA01
                CLR     A                      ; 595F 1 208 180 F9
vcal4_store:     ST      A, er3                 ; 5960 1 208 180 8B
                RT                             ; 5961 1 208 180 01
vcal4_negative_path:     ROR     A                      ; 5962 1 208 180 43
vcal_5:         ADD     A, er3                 ; 5963 1 208 180 0B
                JGE     vcal5_store             ; 5964 1 208 180 CD03
                L       A, #0ffffh             ; 5966 1 208 180 67FFFF
vcal5_store:     ST      A, er3                 ; 5969 1 208 180 8B
                RT                             ; 596A 1 208 180 01
                DB  0E2h ; 596B
signextend_helper:     ROL     A                      ; 596C 1 100 280 33
; [H] --- 16-bit signed saturating add helper (sign-extends r7's high bit, adds to er3, clamps to
; [H] 0x7FFF/0x8000 on overflow rather than wrapping). Used in RPM/period calculations.
                JLT     signext_negative_path             ; 596D 1 100 280 CA11
                ROR     A                      ; 596F 1 100 280 43
                MB      C, r7.7                ; 5970 1 100 280 272F
                JLT     signext_common_add             ; 5972 1 100 280 CA09
                ADD     A, er3                 ; 5974 1 100 280 0B
                ROL     A                      ; 5975 1 100 280 33
                JGE     signext_final_store             ; 5976 1 100 280 CD16
                L       A, #07fffh             ; 5978 1 100 280 67FF7F
                ST      A, er3                 ; 597B 1 100 280 8B
                RT                             ; 597C 1 100 280 01
signext_common_add:     ADD     A, er3                 ; 597D 1 100 280 0B
                ST      A, er3                 ; 597E 1 100 280 8B
                RT                             ; 597F 1 100 280 01
signext_negative_path:     ROR     A                      ; 5980 1 100 280 43
                MB      C, r7.7                ; 5981 1 100 280 272F
                JGE     signext_common_add             ; 5983 1 100 280 CDF8
                ADD     A, er3                 ; 5985 1 100 280 0B
                ROL     A                      ; 5986 1 100 280 33
                JLT     signext_final_store             ; 5987 1 100 280 CA05
                L       A, #08000h             ; 5989 1 100 280 670080
                ST      A, er3                 ; 598C 1 100 280 8B
                RT                             ; 598D 1 100 280 01
signext_final_store:     ROR     A                      ; 598E 1 100 280 43
                ST      A, er3                 ; 598F 1 100 280 8B
                RT                             ; 5990 1 100 280 01
scale_mul5_div4:     MOV     er0, #00005h           ; 5991 1 100 280 44980500
                MUL                            ; 5995 1 100 280 9035
                SRL     er1                    ; 5997 1 100 280 45E7
                ROR     A                      ; 5999 1 100 280 43
                SRL     er1                    ; 599A 1 100 280 45E7
                ROR     A                      ; 599C 1 100 280 43
                CMPB    r2, #000h              ; 599D 1 100 280 22C000
                JEQ     scale_mul5_div4_return             ; 59A0 1 100 280 C903
                L       A, #0ffffh             ; 59A2 1 100 280 67FFFF
scale_mul5_div4_return:     RT                             ; 59A5 1 100 280 01
vcal_7:         XOR     A, #0ffffh             ; 59A6 1 200 180 F6FFFF
                ADD     A, #00001h             ; 59A9 1 200 180 860100
                RT                             ; 59AC 1 200 180 01
vcal_6:         XORB    A, #0ffh               ; 59AD 0 200 180 F6FF
                ADDB    A, #001h               ; 59AF 0 200 180 8601
                RT                             ; 59B1 0 200 180 01
newval_table3_call_sub_clear_acc:     CLR     A                      ; 59B2 1 200 180 F9
                ST      A, er0                 ; 59B3 1 200 180 88
                ST      A, er2                 ; 59B4 1 200 180 8A
                LB      A, r3                  ; 59B5 0 200 180 7B
                CMPB    A, r6                  ; 59B6 0 200 180 4E
                JLT     scaler_table_search_start             ; 59B7 0 200 180 CA01
                LB      A, r6                  ; 59B9 0 200 180 7E
scaler_table_search_start:     STB     A, r6                  ; 59BA 0 200 180 8E
                ADD     X1, A                  ; 59BB 0 200 180 9081
scaler_table_search_loop:     INCB    r6                     ; 59BD 0 200 180 AE
                INC     X1                     ; 59BE 0 200 180 70
                LCB     A, [X1]                ; 59BF 0 200 180 90AA
                JEQ     scaler_table_interp             ; 59C1 0 200 180 C903
                CMPB    A, r2                  ; 59C3 0 200 180 4A
                JLE     scaler_table_search_loop             ; 59C4 0 200 180 CFF7
scaler_table_interp:     LB      A, r2                  ; 59C6 0 200 180 7A
scaler_table_search_back:     DECB    r6                     ; 59C7 0 200 180 BE
                DEC     X1                     ; 59C8 0 200 180 80
                CMPCB   A, [X1]                ; 59C9 0 200 180 90AE
                JLT     scaler_table_search_back             ; 59CB 0 200 180 CAFA
                LCB     A, [X1]                ; 59CD 0 200 180 90AA
                STB     A, r4                  ; 59CF 0 200 180 8C
                LB      A, r2                  ; 59D0 0 200 180 7A
                SUBB    A, r4                  ; 59D1 0 200 180 2C
                STB     A, r0                  ; 59D2 0 200 180 88
                INC     X1                     ; 59D3 0 200 180 70
                LCB     A, [X1]                ; 59D4 0 200 180 90AA
                SUBB    A, r4                  ; 59D6 0 200 180 2C
                STB     A, r4                  ; 59D7 0 200 180 8C
                CLR     A                      ; 59D8 1 200 180 F9
                MB      C, PSWL.4              ; 59D9 1 200 180 A32C
                JGE     scaler_div_final             ; 59DB 1 200 180 CD04
                ROL     er0                    ; 59DD 1 200 180 44B7
                SLL     er2                    ; 59DF 1 200 180 46D7
scaler_div_final:     DIV                            ; 59E1 1 200 180 9037
                RT                             ; 59E3 1 200 180 01
table2d_lookup_interp:     CLR     A                      ; 59E4 1 200 180 F9
; [H] --- Generic 2D table lookup/interpolation helper (row x column, e.g. RPM x Load). Given a
; [H] table base in X1, row width in r0, row index in r1, column offset in r2, column count in r3.
; [H] Companion to the 1D table_interp_lookup used elsewhere.
                LB      A, r2                  ; 59E5 0 200 180 7A
                ADD     X1, A                  ; 59E6 0 200 180 9081
                MOV     DP, X1                 ; 59E8 0 200 180 907A
                L       A, #00101h             ; 59EA 1 200 180 670101
                MB      C, PSWL.5              ; 59ED 1 200 180 A32D
                JGE     table2d_row_calc             ; 59EF 1 200 180 CD08
                LB      A, r1                  ; 59F1 0 200 180 79
                MULB                           ; 59F2 0 200 180 A234
                ADD     DP, A                  ; 59F4 0 200 180 9281
                CLR     A                      ; 59F6 1 200 180 F9
                LC      A, [DP]                ; 59F7 1 200 180 92A8
table2d_row_calc:     ST      A, er2                 ; 59F9 1 200 180 8A
                LB      A, r3                  ; 59FA 0 200 180 7B
                MULB                           ; 59FB 0 200 180 A234
                ADD     X1, A                  ; 59FD 0 200 180 9081
                LC      A, [X1]                ; 59FF 0 200 180 90A8
                MOV     DP, A                  ; 5A01 0 200 180 52
                CLR     A                      ; 5A02 1 200 180 F9
                LB      A, r0                  ; 5A03 0 200 180 78
                ADD     X1, A                  ; 5A04 0 200 180 9081
                LC      A, [X1]                ; 5A06 0 200 180 90A8
                MOV     X1, A                  ; 5A08 0 200 180 50
                MOVB    r0, r4                 ; 5A09 0 200 180 2448
                L       A, DP                  ; 5A0B 1 200 180 42
                MULB                           ; 5A0C 1 200 180 A234
                ST      A, er1                 ; 5A0E 1 200 180 89
                MOVB    r0, r5                 ; 5A0F 1 200 180 2548
                L       A, DP                  ; 5A11 1 200 180 42
                SWAP                           ; 5A12 1 200 180 83
                MULB                           ; 5A13 1 200 180 A234
                MOV     DP, A                  ; 5A15 1 200 180 52
                L       A, X1                  ; 5A16 1 200 180 40
                SWAP                           ; 5A17 1 200 180 83
                MULB                           ; 5A18 1 200 180 A234
                MOVB    r0, r4                 ; 5A1A 1 200 180 2448
                ST      A, er2                 ; 5A1C 1 200 180 8A
                L       A, X1                  ; 5A1D 1 200 180 40
                MULB                           ; 5A1E 1 200 180 A234
                MOV     X1, er1                ; 5A20 1 200 180 4578
                XCHG    A, er2                 ; 5A22 1 200 180 4610
                MOV     er0, X2                ; 5A24 1 200 180 9148
                CAL     table2d_mul_combine             ; 5A26 1 200 180 32335A
                MOV     er2, X1                ; 5A29 1 200 180 904A
                MOV     X1, A                  ; 5A2B 1 200 180 50
                L       A, DP                  ; 5A2C 1 200 180 42
                CAL     table2d_mul_combine             ; 5A2D 1 200 180 32335A
                L       A, X1                  ; 5A30 1 200 180 40
                MOV     er0, er3               ; 5A31 1 200 180 4748
table2d_mul_combine:     SUB     A, er2                 ; 5A33 1 200 180 2A
                JGE     table2d_mul_positive             ; 5A34 1 200 180 CD0A
                ST      A, er1                 ; 5A36 1 200 180 89
                CLR     A                      ; 5A37 1 200 180 F9
                SUB     A, er1                 ; 5A38 1 200 180 29
                MUL                            ; 5A39 1 200 180 9035
                L       A, er1                 ; 5A3B 1 200 180 35
                SUB     er2, A                 ; 5A3C 1 200 180 46A1
                L       A, er2                 ; 5A3E 1 200 180 36
                RT                             ; 5A3F 1 200 180 01
table2d_mul_positive:     MUL                            ; 5A40 1 200 180 9035
                L       A, er1                 ; 5A42 1 200 180 35
                ADD     A, er2                 ; 5A43 1 200 180 0A
                ST      A, er2                 ; 5A44 1 200 180 8A
                RT                             ; 5A45 1 200 180 01
knock_244_helper:     EXTND                          ; 5A46 1 200 180 F8
                ADD     DP, A                  ; 5A47 1 200 180 9281
                CLR     A                      ; 5A49 1 200 180 F9
                LCB     A, [DP]                ; 5A4A 1 200 180 92AA
                ST      A, er2                 ; 5A4C 1 200 180 8A
                INC     DP                     ; 5A4D 1 200 180 72
                LCB     A, [DP]                ; 5A4E 1 200 180 92AA
                CAL     table2d_mul_combine             ; 5A50 1 200 180 32335A
                LB      A, r4                  ; 5A53 0 200 180 7C
                RT                             ; 5A54 0 200 180 01
map_result_postscale:     MOVB    r0, off(0013fh)        ; 5A55 1 100 280 C43F48
                MOVB    r1, #001h              ; 5A58 1 100 280 9901
                CMPB    r0, #080h              ; 5A5A 1 100 280 20C080
                JGE     mul_scale_rotate             ; 5A5D 1 100 280 CD01
                INCB    r1                     ; 5A5F 1 100 280 A9
mul_scale_rotate:     MUL                            ; 5A60 1 100 280 9035
                LB      A, r2                  ; 5A62 0 100 280 7A
                L       A, ACC                 ; 5A63 1 100 280 E506
                SWAP                           ; 5A65 1 100 280 83
                SRLB    r3                     ; 5A66 1 100 280 23E7
                ROR     A                      ; 5A68 1 100 280 43
                CMPB    r3, #000h              ; 5A69 1 100 280 23C000
                JEQ     tipin_table_diff_calc             ; 5A6C 1 100 280 C903
                L       A, #0ffffh             ; 5A6E 1 100 280 67FFFF
tipin_table_diff_calc:     RT                             ; 5A71 1 100 280 01
idle_stall_helper:     MOV     X2, #00010h            ; 5A72 1 208 180 611000
                MOV     DP, #01000h            ; 5A75 1 208 180 620010
                SJ      clamp_range_check             ; 5A78 1 208 180 CB06
injtimer_bank_calc2:     MOV     X2, #fueltbl_range_check_tbl          ; 5A7A 1 100 280 613371
                MOV     DP, #09862h            ; 5A7D 1 100 280 626298
clamp_range_check:     CMP     A, X2                  ; 5A80 1 208 180 91C2
                JLE     clamp_range_lowside             ; 5A82 1 208 180 CF06
                CMP     A, DP                  ; 5A84 1 208 180 92C2
                JLT     clamp_range_store             ; 5A86 1 208 180 CA05
                MOV     X2, DP                 ; 5A88 1 208 180 9279
clamp_range_lowside:     L       A, X2                  ; 5A8A 1 208 180 41
                CLR     er0                    ; 5A8B 1 208 180 4415
clamp_range_store:     ST      A, 00000h[X1]          ; 5A8D 1 208 180 D00000
                L       A, er0                 ; 5A90 1 208 180 34
                ST      A, 00002h[X1]          ; 5A91 1 208 180 D00200
                RT                             ; 5A94 1 208 180 01
vcal3_leanprotect_ratelimit_sub_load_er2_2:     MOV     er2, #00023h           ; 5A95 1 208 180 46982300
                MOV     er3, #003ffh           ; 5A99 1 208 180 4798FF03
                SJ      clamp_to_35_512_cmp_acc             ; 5A9D 1 208 180 CB08
clamp_to_35_512:     MOV     er2, #00023h           ; 5A9F 1 208 180 46982300
                MOV     er3, #00199h           ; 5AA3 1 208 180 47989901
clamp_to_35_512_cmp_acc:     CMP     A, er2                 ; 5AA7 1 208 180 4A
                JLT     load_er0_result             ; 5AA8 1 208 180 CA05
                CMP     A, er3                 ; 5AAA 1 208 180 4B
                JLE     load_er0_result_store_tbl_x1             ; 5AAB 1 208 180 CF05
                MOV     er2, er3               ; 5AAD 1 208 180 474A
load_er0_result:     L       A, er2                 ; 5AAF 1 208 180 36
                CLR     er0                    ; 5AB0 1 208 180 4415
load_er0_result_store_tbl_x1:     ST      A, 00000h[X1]          ; 5AB2 1 208 180 D00000
                L       A, er0                 ; 5AB5 1 208 180 34
                ST      A, [DP]                ; 5AB6 1 208 180 D2
                RT                             ; 5AB7 1 208 180 01
sub37_clamp_to_er0:     SUB     A, #00025h             ; 5AB8 1 208 180 A62500
                JLT     sub37_clamp_to_er0_load_er0             ; 5ABB 1 208 180 CA03
                CMP     A, er0                 ; 5ABD 1 208 180 48
                JGE     sub37_clamp_to_er0_return             ; 5ABE 1 208 180 CD01
sub37_clamp_to_er0_load_er0:     L       A, er0                 ; 5AC0 1 208 180 34
sub37_clamp_to_er0_return:     RT                             ; 5AC1 1 208 180 01
add24_clamp_neg1:     ADD     A, #00018h             ; 5AC2 1 208 180 861800
                JGE     table_index_add_sub_0ce             ; 5AC5 1 208 180 CD03
                L       A, #0ffffh             ; 5AC7 1 208 180 67FFFF
table_index_add_sub_0ce:     ST      A, er3                 ; 5ACA 1 208 180 8B
                CLR     er1                    ; 5ACB 1 208 180 4515
                LC      A, [X1]                ; 5ACD 1 208 180 90A8
                ST      A, er0                 ; 5ACF 1 208 180 88
                L       A, 0ceh                ; 5AD0 1 208 180 E5CE
                SUB     A, er0                 ; 5AD2 1 208 180 28
                JLT     table_index_add_clamp_er3             ; 5AD3 1 208 180 CA07
                ST      A, er0                 ; 5AD5 1 208 180 88
                LC      A, 00004h[X1]          ; 5AD6 1 208 180 90A90400
                MUL                            ; 5ADA 1 208 180 9035
table_index_add_clamp_er3:     LC      A, 00002h[X1]          ; 5ADC 1 208 180 90A90200
                ADD     A, er1                 ; 5AE0 1 208 180 09
                CMP     A, er3                 ; 5AE1 1 208 180 4B
                JLT     table_index_add_clamp_er3_return             ; 5AE2 1 208 180 CA01
                L       A, er3                 ; 5AE4 1 208 180 37
table_index_add_clamp_er3_return:     RT                             ; 5AE5 1 208 180 01
vcal3_leanprotect_ratelimit_sub_mul_acc_2:     MUL                            ; 5AE6 1 208 180 9035
                CMPB    r2, #000h              ; 5AE8 1 208 180 22C000
                JEQ     idle_helper2_if_ram20c_bit0_set             ; 5AEB 1 208 180 C908
                L       A, #0ffffh             ; 5AED 1 208 180 67FFFF
                SJ      idle_helper2_if_ram20c_bit0_set             ; 5AF0 1 208 180 CB03
idle_helper2:     MUL                            ; 5AF2 1 208 180 9035
                L       A, er1                 ; 5AF4 1 208 180 35
idle_helper2_if_ram20c_bit0_set:     JBS     off(0020ch).0, idle_helper2_alt_path ; 5AF5 1 208 180 E80C09
                XCHG    A, er3                 ; 5AF8 1 208 180 4710
                SUB     A, er3                 ; 5AFA 1 208 180 2B
                JGE     idle_pi_clamp_compare             ; 5AFB 1 208 180 CD07
idle_pi_clamp_setcarry:     SC                             ; 5AFD 1 208 180 85
                L       A, X1                  ; 5AFE 1 208 180 40
                ST      A, er3                 ; 5AFF 1 208 180 8B
                RT                             ; 5B00 1 208 180 01
idle_helper2_alt_path:     ADD     A, er3                 ; 5B01 1 208 180 0B
                JLT     idle_helper2_sc_path             ; 5B02 1 208 180 CA08
idle_pi_clamp_compare:     CMP     A, X1                  ; 5B04 1 208 180 90C2
                JLE     idle_pi_clamp_setcarry             ; 5B06 1 208 180 CFF5
                CMP     X2, A                  ; 5B08 1 208 180 91C1
                JGT     idle_helper2_store             ; 5B0A 1 208 180 C802
idle_helper2_sc_path:     SC                             ; 5B0C 1 208 180 85
                L       A, X2                  ; 5B0D 1 208 180 41
idle_helper2_store:     ST      A, er3                 ; 5B0E 1 208 180 8B
                RT                             ; 5B0F 1 208 180 01
                DB  067h,000h,007h,0EBh,016h,003h,067h,000h ; 5B10
                DB  005h,001h ; 5B18
idle_pi_clamp_helper:     CMP     off(0028eh), A         ; 5B1A 1 208 180 B48EC1
                JLT     idle_pi_clamp_low             ; 5B1D 1 208 180 CA07
                CMP     A, off(00290h)         ; 5B1F 1 208 180 C790
                JGE     idle_pi_clamp_return             ; 5B21 1 208 180 CD02
                L       A, off(00290h)         ; 5B23 1 208 180 E490
idle_pi_clamp_return:     RT                             ; 5B25 1 208 180 01
idle_pi_clamp_low:     L       A, off(0028eh)         ; 5B26 1 208 180 E48E
                RT                             ; 5B28 1 208 180 01
weighted_sum_2term_trim:     MOV     X1, A                  ; 5B29 1 208 180 50
                CLRB    r0                     ; 5B2A 1 208 180 2015
                MOVB    r1, r6                 ; 5B2C 1 208 180 2649
                MUL                            ; 5B2E 1 208 180 9035
                MOV     er2, er1               ; 5B30 1 208 180 454A
                L       A, X1                  ; 5B32 1 208 180 40
                MOVB    r1, r7                 ; 5B33 1 208 180 2749
                MUL                            ; 5B35 1 208 180 9035
                L       A, off(002a8h)         ; 5B37 1 208 180 E4A8
                MB      C, PSWL.4              ; 5B39 1 208 180 A32C
                JLT     weighted_sum_2term_trim_sub_acc             ; 5B3B 1 208 180 CA19
                ADD     A, er1                 ; 5B3D 1 208 180 09
                JLT     weighted_sum_2term_trim_load_imm             ; 5B3E 1 208 180 CA05
                CMP     A, #003ffh             ; 5B40 1 208 180 C6FF03
                JLE     weighted_sum_2term_trim_store_ram2a8             ; 5B43 1 208 180 CF03
weighted_sum_2term_trim_load_imm:     L       A, #003ffh             ; 5B45 1 208 180 67FF03
weighted_sum_2term_trim_store_ram2a8:     ST      A, off(002a8h)         ; 5B48 1 208 180 D4A8
                ADD     A, er2                 ; 5B4A 1 208 180 0A
                JLT     weighted_sum_2term_trim_load_imm_2             ; 5B4B 1 208 180 CA05
                CMP     A, #003ffh             ; 5B4D 1 208 180 C6FF03
                JLT     weighted_sum_2term_trim_return             ; 5B50 1 208 180 CA03
weighted_sum_2term_trim_load_imm_2:     L       A, #003ffh             ; 5B52 1 208 180 67FF03
weighted_sum_2term_trim_return:     RT                             ; 5B55 1 208 180 01
weighted_sum_2term_trim_sub_acc:     SUB     A, er1                 ; 5B56 1 208 180 29
                CLR     er0                    ; 5B57 1 208 180 4415
                JLE     weighted_sum_2term_trim_load_er0             ; 5B59 1 208 180 CF07
                MOV     er0, #003ffh           ; 5B5B 1 208 180 4498FF03
                CMP     A, er0                 ; 5B5F 1 208 180 48
                JLT     weighted_sum_2term_trim_store_ram2a8_2             ; 5B60 1 208 180 CA01
weighted_sum_2term_trim_load_er0:     L       A, er0                 ; 5B62 1 208 180 34
weighted_sum_2term_trim_store_ram2a8_2:     ST      A, off(002a8h)         ; 5B63 1 208 180 D4A8
                SUB     A, er2                 ; 5B65 1 208 180 2A
                JLE     weighted_sum_2term_trim_clear_acc             ; 5B66 1 208 180 CF09
                CMP     A, #003ffh             ; 5B68 1 208 180 C6FF03
                JLT     weighted_sum_2term_trim_return_2             ; 5B6B 1 208 180 CA03
                L       A, #003ffh             ; 5B6D 1 208 180 67FF03
weighted_sum_2term_trim_return_2:     RT                             ; 5B70 1 208 180 01
weighted_sum_2term_trim_clear_acc:     CLR     A                      ; 5B71 1 208 180 F9
                RT                             ; 5B72 1 208 180 01
vcal3_leanprotect_ratelimit_sub_if_lt_goto_5b7a:     JLT     vcal3_leanprotect_ratelimit_sub_load_imm             ; 5B73 1 208 180 CA05
vcal3_leanprotect_ratelimit_sub_cmp_acc:     CMP     A, #003ffh             ; 5B75 1 208 180 C6FF03
                JLT     vcal3_leanprotect_ratelimit_sub_return             ; 5B78 1 208 180 CA03
vcal3_leanprotect_ratelimit_sub_load_imm:     L       A, #003ffh             ; 5B7A 1 208 180 67FF03
vcal3_leanprotect_ratelimit_sub_return:     RT                             ; 5B7D 1 208 180 01
cfgvariant_set_flags:     SUBB    A, #001h               ; 5B7E 0 208 ??? A601
                MOVB    r0, #008h              ; 5B80 0 208 ??? 9808
                DIVB                           ; 5B82 0 208 ??? A236
                MOV     X1, A                  ; 5B84 0 208 ??? 50
                LB      A, r1                  ; 5B85 0 208 ??? 79
                SBR     0011ah[X1]             ; 5B86 0 208 ??? C01A0111
                SBR     00212h[X1]             ; 5B8A 0 208 ??? C0120211
                SBR     0031eh[X1]             ; 5B8E 0 208 ??? C01E0311
cfgvariant_checksum_calc:     MOV     DP, #0031dh            ; 5B92 0 208 ??? 621D03
                CLR     er0                    ; 5B95 0 208 ??? 4415
cfgvariant_checksum_loop:     LB      A, r0                  ; 5B97 0 208 ??? 78
                ADDB    A, [DP]                ; 5B98 0 208 ??? C282
                STB     A, r0                  ; 5B9A 0 208 ??? 88
                LB      A, r1                  ; 5B9B 0 208 ??? 79
                XORB    A, [DP]                ; 5B9C 0 208 ??? C2F2
                STB     A, r1                  ; 5B9E 0 208 ??? 89
                INC     DP                     ; 5B9F 0 208 ??? 72
                CMP     DP, #00322h            ; 5BA0 0 208 ??? 92C02203
                JNE     cfgvariant_checksum_loop             ; 5BA4 0 208 ??? CEF1
                L       A, er0                 ; 5BA6 1 208 ??? 34
                ST      A, [DP]                ; 5BA7 1 208 ??? D2
                RT                             ; 5BA8 1 208 ??? 01
port_debounce_helper:     MOV     DP, #03f00h            ; 5BA9 1 208 180 62003F
                LB      A, #090h               ; 5BAC 0 208 180 7790
                STB     A, [DP]                ; 5BAE 0 208 180 D2
                MOV     DP, #01f00h            ; 5BAF 0 208 180 62001F
                LB      A, P0                  ; 5BB2 0 208 180 F520
                STB     A, [DP]                ; 5BB4 0 208 180 D2
                MOV     DP, #02f00h            ; 5BB5 0 208 180 62002F
                LB      A, P1                  ; 5BB8 0 208 180 F522
                STB     A, [DP]                ; 5BBA 0 208 180 D2
                MOV     DP, #00f00h            ; 5BBB 0 208 180 62000F
                LB      A, [DP]                ; 5BBE 0 208 180 F2
                XORB    A, #038h               ; 5BBF 0 208 180 F638
                STB     A, off(00210h)         ; 5BC1 0 208 180 D410
                STB     A, (00118h-00180h)[USP] ; 5BC3 0 208 180 D398
                SB      off(00230h).2          ; 5BC5 0 208 180 C4301A
                RT                             ; 5BC8 0 208 180 01
decrement_timer_array:     L       A, 0fah                ; 5BC9 1 208 180 E5FA
                ST      A, IE                  ; 5BCB 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 5BCD 1 208 180 A2D0FE
                LB      A, 00000h[X1]          ; 5BD0 0 208 180 F00000
                JEQ     decrement_timer_array_next             ; 5BD3 0 208 180 C904
                DECB    00000h[X1]             ; 5BD5 0 208 180 C0000017
decrement_timer_array_next:     ORB     PSWH, #001h            ; 5BD9 0 208 180 A2E001
                L       A, 0f8h                ; 5BDC 1 208 180 E5F8
                ST      A, IE                  ; 5BDE 1 208 180 D51A
                INC     X1                     ; 5BE0 1 208 180 70
                JRNZ    DP, decrement_timer_array         ; 5BE1 1 208 180 30E6
                RT                             ; 5BE3 1 208 180 01
ResetWatchDog:     LB      A, #03ch               ; 5BE4 0 208 180 773C
                STB     A, WDT                 ; 5BE6 0 208 180 D511
                SWAPB                          ; 5BE8 0 208 180 83
                STB     A, WDT                 ; 5BE9 0 208 180 D511
                MB      C, 0b7h.1              ; 5BEB 0 208 180 C5B729
                JLT     resetwatchdog_return             ; 5BEE 0 208 180 CA04
                XORB    P2, #010h              ; 5BF0 0 208 180 C524F010
resetwatchdog_return:     RT                             ; 5BF4 0 208 180 01
ect_step_helper:     ADDB    A, #005h               ; 5BF5 0 208 180 8605
                JGE     ect_step_range_check             ; 5BF7 0 208 180 CD02
                LB      A, #0ffh               ; 5BF9 0 208 180 77FF
ect_step_range_check:     JBS     off(00217h).4, ect_step_clamp_default ; 5BFB 0 208 180 EC1709
                JBR     off(00230h).3, ect_step_clamp_default ; 5BFE 0 208 180 DB3006
                CMPB    A, 00376h[X1]          ; 5C01 0 208 180 C07603C2
                JGE     ect_step_return             ; 5C05 0 208 180 CD09
ect_step_clamp_default:     MOVB    r0, #042h              ; 5C07 0 208 180 9842
                CMPB    A, r0                  ; 5C09 0 208 180 48
                JGE     ect_step_store             ; 5C0A 0 208 180 CD01
                LB      A, r0                  ; 5C0C 0 208 180 78
ect_step_store:     STB     A, 00376h[X1]          ; 5C0D 0 208 180 D07603
ect_step_return:     RT                             ; 5C10 0 208 180 01
ect_smooth_helper:     SUBB    A, [DP]                ; 5C11 0 208 180 C2A2
                JGE     ect_smooth_sub             ; 5C13 0 208 180 CD04
                ADDB    A, #002h               ; 5C15 0 208 180 8602
                SJ      ect_smooth_store             ; 5C17 0 208 180 CB02
ect_smooth_sub:     SUBB    A, #002h               ; 5C19 0 208 180 A602
ect_smooth_store:     JGE     ect_smooth_add_store             ; 5C1B 0 208 180 CD01
                CLRB    A                      ; 5C1D 0 208 180 FA
ect_smooth_add_store:     ADDB    A, [DP]                ; 5C1E 0 208 180 C282
                STB     A, [DP]                ; 5C20 0 208 180 D2
                RT                             ; 5C21 0 208 180 01
crank_edge_helper:     L       A, off(00124h)         ; 5C22 1 108 280 E424
                ST      A, (0021ch-00280h)[USP] ; 5C24 1 108 280 D39C
                L       A, off(00126h)         ; 5C26 1 108 280 E426
                ST      A, (0021eh-00280h)[USP] ; 5C28 1 108 280 D39E
                RT                             ; 5C2A 1 108 280 01
refresh_engine_flags_snapshot:     L       A, (00212h-00280h)[USP] ; 5C2B 1 108 280 E392
; [H] --- Copies a 5-word input/condition snapshot (captured elsewhere, likely synchronized with
; [H] the crank-angle interrupt) into the working flag bytes off(0011Ah)/(0011Ch)/(0011Eh)/
; [H] (00120h)/(00122h). These are the same flag bytes tested throughout GIO1/2/3, ignition
; [H] timing, and elsewhere in this file (e.g. "JBR off(0011eh).5, ..."), refreshed once per call
; [H] here rather than being live hardware registers -- worth knowing when tracing any of those
; [H] bit tests: they reflect the state as of the last refresh_engine_flags_snapshot call, not the
; [H] instantaneous pin state.
                ST      A, off(0011ah)         ; 5C2D 1 108 280 D41A
                L       A, (00214h-00280h)[USP] ; 5C2F 1 108 280 E394
                ST      A, off(0011ch)         ; 5C31 1 108 280 D41C
                L       A, (00216h-00280h)[USP] ; 5C33 1 108 280 E396
                ST      A, off(0011eh)         ; 5C35 1 108 280 D41E
                L       A, (00218h-00280h)[USP] ; 5C37 1 108 280 E398
                ST      A, off(00120h)         ; 5C39 1 108 280 D420
                L       A, (0021ah-00280h)[USP] ; 5C3B 1 108 280 E39A
                ST      A, off(00122h)         ; 5C3D 1 108 280 D422
                RT                             ; 5C3F 1 108 280 01
timer_or_counter_helper:     LB      A, r0                  ; 5C40 0 208 180 78
                MBR     C, [DP]                ; 5C41 0 208 180 C221
                LC      A, [X1]                ; 5C43 0 208 180 90A8
                JLT     timer_or_counter_helper_load_carry_pswl_bit4             ; 5C45 0 208 180 CA02
                LB      A, ACCH                ; 5C47 0 208 180 F507
timer_or_counter_helper_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 5C49 0 208 180 A32C
                JLT     timer_or_counter_helper_cmp_r2             ; 5C4B 0 208 180 CA03
                CMPB    A, r2                  ; 5C4D 0 208 180 4A
                SJ      timer_or_counter_helper_load_r0             ; 5C4E 0 208 180 CB02
timer_or_counter_helper_cmp_r2:     CMPB    r2, A                  ; 5C50 0 208 180 22C1
timer_or_counter_helper_load_r0:     LB      A, r0                  ; 5C52 0 208 180 78
                MBR     [DP], C                ; 5C53 0 208 180 C220
                INC     X1                     ; 5C55 0 208 180 70
                INC     X1                     ; 5C56 0 208 180 70
                INCB    r0                     ; 5C57 0 208 180 A8
                DECB    r1                     ; 5C58 0 208 180 B9
                JNE     timer_or_counter_helper             ; 5C59 0 208 180 CEE5
                RT                             ; 5C5B 0 208 180 01
selftest_regbank_verify:     MOV     X2, A                  ; 5C5C 1 200 ??? 51
                SB      off(00230h).7          ; 5C5D 1 200 ??? C4301F
                AND     IE, #002a0h            ; 5C60 1 200 ??? B51AD0A002
                ANDB    PSWH, #0feh            ; 5C65 1 200 ??? A2D0FE
                XCHG    A, 00084h[X1]          ; 5C68 1 200 ??? B0840010
                XCHG    A, 00084h[X1]          ; 5C6C 1 200 ??? B0840010
                ST      A, er3                 ; 5C70 1 200 ??? 8B
                ORB     PSWH, #001h            ; 5C71 1 200 ??? A2E001
                L       A, 0f8h                ; 5C74 1 200 ??? E5F8
                ST      A, IE                  ; 5C76 1 200 ??? D51A
                RB      off(00230h).7          ; 5C78 1 200 ??? C4300F
                L       A, er3                 ; 5C7B 1 200 ??? 37
                CMP     A, X2                  ; 5C7C 1 200 ??? 91C2
                JNE     regbank_verify_fail             ; 5C7E 1 200 ??? CE01
                RT                             ; 5C80 1 200 ??? 01
regbank_verify_fail:     MOVB    0f5h, #042h            ; 5C81 1 200 ??? C5F59842
                BRK                            ; 5C85 1 200 ??? FF
idle_helper1:     JBR     off(00230h).3, idle_helper1_alt ; 5C86 1 208 180 DB3017
                L       A, 0fah                ; 5C89 1 208 180 E5FA
                ST      A, IE                  ; 5C8B 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 5C8D 1 208 180 A2D0FE
                L       A, TM2                 ; 5C90 1 208 180 E538
                SUB     A, off(0025ah)         ; 5C92 1 208 180 A75A
                CMP     A, #000c8h             ; 5C94 1 208 180 C6C800
                ORB     PSWH, #001h            ; 5C97 1 208 180 A2E001
                L       A, 0f8h                ; 5C9A 1 208 180 E5F8
                ST      A, IE                  ; 5C9C 1 208 180 D51A
                JLT     idle_helper1_return             ; 5C9E 1 208 180 CA2D
idle_helper1_alt:     RB      IRQH.4                 ; 5CA0 1 208 180 C5190C
                JEQ     idle_helper1_alt_load_ram0f5             ; 5CA3 1 208 180 C929
                LB      A, P2                  ; 5CA5 0 208 180 F524
                SWAPB                          ; 5CA7 0 208 180 83
                SRLB    A                      ; 5CA8 0 208 180 63
                ANDB    A, #007h               ; 5CA9 0 208 180 D607
                EXTND                          ; 5CAB 1 208 180 F8
                MOV     X1, A                  ; 5CAC 1 208 180 50
                LB      A, ADCR1H              ; 5CAD 0 208 180 F563
                STB     A, 003ceh[X1]          ; 5CAF 0 208 180 D0CE03
                LB      A, ADCR0H              ; 5CB2 0 208 180 F561
                STB     A, 003c6h[X1]          ; 5CB4 0 208 180 D0C603
                L       A, 0fah                ; 5CB7 1 208 180 E5FA
                ST      A, IE                  ; 5CB9 1 208 180 D51A
                ANDB    PSWH, #0feh            ; 5CBB 1 208 180 A2D0FE
                ADDB    P2, #020h              ; 5CBE 1 208 180 C5248020
                MOV     off(0025ah), TM2       ; 5CC2 1 208 180 B5387C5A
                ORB     PSWH, #001h            ; 5CC6 1 208 180 A2E001
                L       A, 0f8h                ; 5CC9 1 208 180 E5F8
                ST      A, IE                  ; 5CCB 1 208 180 D51A
idle_helper1_return:     RT                             ; 5CCD 1 208 180 01
idle_helper1_alt_load_ram0f5:     MOVB    0f5h, #04ah            ; 5CCE 1 208 180 C5F5984A
                BRK                            ; 5CD2 1 208 180 FF
selftest_reason_range_check:     CMPB    off(00238h), #00ah     ; 5CD3 0 208 180 C438C00A
                JLT     empty_stub_return             ; 5CD7 0 208 180 CA20
selftest_reason_range_check_entry:     MOV     DP, #003d1h            ; 5CD9 0 208 180 62D103
                LB      A, [DP]                ; 5CDC 0 208 180 F2
                CMPB    A, #0ffh               ; 5CDD 0 208 180 C6FF
                JGT     selftest_reason_range_check_entry_load_imm             ; 5CDF 0 208 180 C80C
                CMPB    A, #0fch               ; 5CE1 0 208 180 C6FC
                JGE     empty_stub_return             ; 5CE3 0 208 180 CD14
                CMPB    A, #088h               ; 5CE5 0 208 180 C688
                JGT     selftest_reason_range_check_entry_load_imm             ; 5CE7 0 208 180 C804
                CMPB    A, #078h               ; 5CE9 0 208 180 C678
                JGE     empty_stub_return             ; 5CEB 0 208 180 CD0C
selftest_reason_range_check_entry_load_imm:     LB      A, #049h               ; 5CED 0 208 180 7749
                STB     A, 0afh                ; 5CEF 0 208 180 D5AF
                DECB    0f7h                   ; 5CF1 0 208 180 C5F717
                JNE     empty_stub_return             ; 5CF4 0 208 180 CE03
                STB     A, 0f5h                ; 5CF6 0 208 180 D5F5
                BRK                            ; 5CF8 0 208 180 FF
empty_stub_return:     RT                             ; 5CF9 0 208 180 01
dwell_scale_helper:     MOVB    r0, #0bdh              ; 5CFA 1 200 180 98BD
                SLL     A                      ; 5CFC 1 200 180 53
                JLT     dwell_scale_default             ; 5CFD 1 200 180 CA0D
                SLL     A                      ; 5CFF 1 200 180 53
                JLT     dwell_scale_default             ; 5D00 1 200 180 CA0A
                LB      A, ACCH                ; 5D02 0 200 180 F507
                CMPB    A, r0                  ; 5D04 0 200 180 48
                JGE     dwell_scale_default             ; 5D05 0 200 180 CD05
                MOVB    r0, #00fh              ; 5D07 0 200 180 980F
                CMPB    A, r0                  ; 5D09 0 200 180 48
                JGE     dwell_scale_return             ; 5D0A 0 200 180 CD01
dwell_scale_default:     LB      A, r0                  ; 5D0C 0 200 180 78
dwell_scale_return:     RT                             ; 5D0D 0 200 180 01
idle_init_start_sub_load_dp:     MOV     DP, #04700h            ; 5D0E 0 208 180 620047
idle_init_start_sub_load_dp_ind:     LB      A, [DP]                ; 5D11 0 208 180 F2
                XORB    A, #0ffh               ; 5D12 0 208 180 F6FF
                ROLB    A                      ; 5D14 0 208 180 33
                ROLB    off(00258h)            ; 5D15 0 208 180 C458B7
                ROLB    A                      ; 5D18 0 208 180 33
                ROLB    off(00258h)            ; 5D19 0 208 180 C458B7
                RT                             ; 5D1C 0 208 180 01
cfgvariant_eval_condition:     CLRB    r0                     ; 5D1D 0 208 ??? 2015
                CMPB    r6, #001h              ; 5D1F 0 208 ??? 26C001
                JNE     cfgvariant_check_v3             ; 5D22 0 208 ??? CE09
                CMPB    0dah, #01ah            ; 5D24 0 208 ??? C5DAC01A
                JLT     cfgvariant_result_common             ; 5D28 0 208 ??? CA01
                INCB    r0                     ; 5D2A 0 208 ??? A8
cfgvariant_result_common:     SJ      cfgvariant_eval_result             ; 5D2B 0 208 ??? CB7F
cfgvariant_check_v3:     CMPB    r6, #003h              ; 5D2D 0 208 ??? 26C003
; [H] --- cfgvariant_eval_condition's dispatch body: for each specific variant index (3, 6, 7, 10,
; [H] 11, 13, 20, 26), checks the sign of that variant's associated sensor/config byte (0xBB,
; [H] 0x3D4, 0x3A4, 0x3CC, 0x3D2, 0x3CD, 0x3D2 again, 0xD7) and increments r0 if negative --
; [H] reads as a per-variant "is this variant's associated input plausible/connected" check,
; [H] feeding cfgvariant_eval_result.
                JNE     cfgvariant_check_v6             ; 5D30 0 208 ??? CE08
                LB      A, 0bbh                ; 5D32 0 208 ??? F5BB
                SLLB    A                      ; 5D34 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D35 0 208 ??? CD75
                INCB    r0                     ; 5D37 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D38 0 208 ??? CB72
cfgvariant_check_v6:     CMPB    r6, #006h              ; 5D3A 0 208 ??? 26C006
                JNE     cfgvariant_check_v7             ; 5D3D 0 208 ??? CE0A
                MOV     DP, #003d0h            ; 5D3F 0 208 ??? 62D003
                LB      A, [DP]                ; 5D42 0 208 ??? F2
                SLLB    A                      ; 5D43 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D44 0 208 ??? CD66
                INCB    r0                     ; 5D46 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D47 0 208 ??? CB63
cfgvariant_check_v7:     CMPB    r6, #007h              ; 5D49 0 208 ??? 26C007
                JNE     cfgvariant_check_v10             ; 5D4C 0 208 ??? CE0A
                MOV     DP, #003a0h            ; 5D4E 0 208 ??? 62A003
                LB      A, [DP]                ; 5D51 0 208 ??? F2
                SLLB    A                      ; 5D52 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D53 0 208 ??? CD57
                INCB    r0                     ; 5D55 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D56 0 208 ??? CB54
cfgvariant_check_v10:     CMPB    r6, #00ah              ; 5D58 0 208 ??? 26C00A
                JNE     cfgvariant_check_v11             ; 5D5B 0 208 ??? CE0A
                MOV     DP, #003c8h            ; 5D5D 0 208 ??? 62C803
                LB      A, [DP]                ; 5D60 0 208 ??? F2
                SLLB    A                      ; 5D61 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D62 0 208 ??? CD48
                INCB    r0                     ; 5D64 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D65 0 208 ??? CB45
cfgvariant_check_v11:     CMPB    r6, #00bh              ; 5D67 0 208 ??? 26C00B
                JNE     cfgvariant_check_v11_cmp_r6             ; 5D6A 0 208 ??? CE0A
                MOV     DP, #003ceh            ; 5D6C 0 208 ??? 62CE03
                LB      A, [DP]                ; 5D6F 0 208 ??? F2
                SLLB    A                      ; 5D70 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D71 0 208 ??? CD39
                INCB    r0                     ; 5D73 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D74 0 208 ??? CB36
cfgvariant_check_v11_cmp_r6:     CMPB    r6, #00ch              ; 5D76 0 208 ??? 26C00C
                JNE     cfgvariant_check_v13             ; 5D79 0 208 ??? CE08
                CMPB    r7, #009h              ; 5D7B 0 208 ??? 27C009
                JNE     cfgvariant_check_v13             ; 5D7E 0 208 ??? CE03
                INCB    r0                     ; 5D80 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D81 0 208 ??? CB29
cfgvariant_check_v13:     CMPB    r6, #00dh              ; 5D83 0 208 ??? 26C00D
                JNE     cfgvariant_check_v20             ; 5D86 0 208 ??? CE0A
                MOV     DP, #003c9h            ; 5D88 0 208 ??? 62C903
                LB      A, [DP]                ; 5D8B 0 208 ??? F2
                SLLB    A                      ; 5D8C 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D8D 0 208 ??? CD1D
                INCB    r0                     ; 5D8F 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D90 0 208 ??? CB1A
cfgvariant_check_v20:     CMPB    r6, #014h              ; 5D92 0 208 ??? 26C014
                JNE     cfgvariant_check_v26             ; 5D95 0 208 ??? CE0A
                MOV     DP, #003ceh            ; 5D97 0 208 ??? 62CE03
                LB      A, [DP]                ; 5D9A 0 208 ??? F2
                SLLB    A                      ; 5D9B 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5D9C 0 208 ??? CD0E
                INCB    r0                     ; 5D9E 0 208 ??? A8
                SJ      cfgvariant_eval_result             ; 5D9F 0 208 ??? CB0B
cfgvariant_check_v26:     CMPB    r6, #01ah              ; 5DA1 0 208 ??? 26C01A
                JNE     cfgvariant_check_v4             ; 5DA4 0 208 ??? CE09
                LB      A, 0d7h                ; 5DA6 0 208 ??? F5D7
                SLLB    A                      ; 5DA8 0 208 ??? 53
                JGE     cfgvariant_eval_result             ; 5DA9 0 208 ??? CD01
                INCB    r0                     ; 5DAB 0 208 ??? A8
cfgvariant_eval_result:     J       cfgvariant_remap_start             ; 5DAC 0 208 ??? 035C5E
cfgvariant_check_v4:     CMPB    r6, #004h              ; 5DAF 0 208 ??? 26C004
                JNE     cfgvariant_check_v8             ; 5DB2 0 208 ??? CE08
                CMPB    r7, #021h              ; 5DB4 0 208 ??? 27C021
                JEQ     cfgvariant_eval_result2             ; 5DB7 0 208 ??? C928
                INCB    r0                     ; 5DB9 0 208 ??? A8
                SJ      cfgvariant_eval_result2             ; 5DBA 0 208 ??? CB25
cfgvariant_check_v8:     CMPB    r6, #008h              ; 5DBC 0 208 ??? 26C008
                JNE     cfgvariant_check_v9             ; 5DBF 0 208 ??? CE0E
                CMPB    r7, #022h              ; 5DC1 0 208 ??? 27C022
                JEQ     cfgvariant_eval_result2             ; 5DC4 0 208 ??? C91B
                INCB    r0                     ; 5DC6 0 208 ??? A8
                CMPB    r7, #02ah              ; 5DC7 0 208 ??? 27C02A
                JEQ     cfgvariant_eval_result2             ; 5DCA 0 208 ??? C915
                INCB    r0                     ; 5DCC 0 208 ??? A8
                SJ      cfgvariant_eval_result2             ; 5DCD 0 208 ??? CB12
cfgvariant_check_v9:     CMPB    r6, #009h              ; 5DCF 0 208 ??? 26C009
                JNE     cfgvariant_check_v17             ; 5DD2 0 208 ??? CE08
                CMPB    r7, #023h              ; 5DD4 0 208 ??? 27C023
                JEQ     cfgvariant_eval_result2             ; 5DD7 0 208 ??? C908
                INCB    r0                     ; 5DD9 0 208 ??? A8
                SJ      cfgvariant_eval_result2             ; 5DDA 0 208 ??? CB05
cfgvariant_check_v17:     CMPB    r6, #011h              ; 5DDC 0 208 ??? 26C011
                JNE     cfgvariant_check_v14_29             ; 5DDF 0 208 ??? CE02
cfgvariant_eval_result2:     SJ      cfgvariant_remap_start             ; 5DE1 0 208 ??? CB79
cfgvariant_check_v14_29:     CMPB    r6, #00ch              ; 5DE3 0 208 ??? 26C00C
                JNE     cfgvariant_check_v14_29_cmp_r6             ; 5DE6 0 208 ??? CE0C
                CMPB    r7, #00ah              ; 5DE8 0 208 ??? 27C00A
                JNE     cfgvariant_check_v14_29_cmp_r6             ; 5DEB 0 208 ??? CE07
                INCB    r0                     ; 5DED 0 208 ??? A8
                INCB    r0                     ; 5DEE 0 208 ??? A8
                SB      off(0021ah).5          ; 5DEF 0 208 ??? C41A1D
                SJ      cfgvariant_eval_result3             ; 5DF2 0 208 ??? CB12
cfgvariant_check_v14_29_cmp_r6:     CMPB    r6, #00eh              ; 5DF4 0 208 ??? 26C00E
                JEQ     cfgvariant_eval_result3             ; 5DF7 0 208 ??? C90D
                CMPB    r6, #01dh              ; 5DF9 0 208 ??? 26C01D
                JNE     cfgvariant_check_v15_16_21             ; 5DFC 0 208 ??? CE0A
                L       A, (0ffd9h-0ffffh)[USP] ; 5DFE 1 208 ??? E3DA
                CMP     A, #08000h             ; 5E00 1 208 ??? C60080
                JLT     cfgvariant_eval_result3             ; 5E03 1 208 ??? CA01
                INCB    r0                     ; 5E05 1 208 ??? A8
cfgvariant_eval_result3:     SJ      cfgvariant_remap_start             ; 5E06 1 208 ??? CB54
cfgvariant_check_v15_16_21:     CMPB    r6, #00fh              ; 5E08 0 208 ??? 26C00F
                JEQ     cfgvariant_eval_result4             ; 5E0B 0 208 ??? C91C
                CMPB    r6, #010h              ; 5E0D 0 208 ??? 26C010
                JEQ     cfgvariant_eval_result4             ; 5E10 0 208 ??? C917
                CMPB    r6, #013h              ; 5E12 0 208 ??? 26C013
                JNE     cfgvariant_check_v15_16_21_cmp_r6             ; 5E15 0 208 ??? CE08
                CMPB    r7, #00fh              ; 5E17 0 208 ??? 27C00F
                JEQ     cfgvariant_eval_result4             ; 5E1A 0 208 ??? C90D
                INCB    r0                     ; 5E1C 0 208 ??? A8
                SJ      cfgvariant_eval_result4             ; 5E1D 0 208 ??? CB0A
cfgvariant_check_v15_16_21_cmp_r6:     CMPB    r6, #015h              ; 5E1F 0 208 ??? 26C015
tbl_5e20        EQU     $-2 ; 5E20
                JEQ     cfgvariant_eval_result4             ; 5E22 0 208 ??? C905
                CMPB    r6, #01bh              ; 5E24 0 208 ??? 26C01B
                JNE     cfgvariant_check_v5_16_17             ; 5E27 0 208 ??? CE02
cfgvariant_eval_result4:     SJ      cfgvariant_remap_start             ; 5E29 0 208 ??? CB31
cfgvariant_check_v5_16_17:     CMPB    r6, #005h              ; 5E2B 0 208 ??? 26C005
                JEQ     cfgvariant_remap_start             ; 5E2E 0 208 ??? C92C
                CMPB    r6, #016h              ; 5E30 0 208 ??? 26C016
                JEQ     cfgvariant_remap_start             ; 5E33 0 208 ??? C927
                CMPB    r6, #017h              ; 5E35 0 208 ??? 26C017
                JEQ     cfgvariant_remap_start             ; 5E38 0 208 ??? C922
                CMPB    r6, #01eh              ; 5E3A 0 208 ??? 26C01E
                JNE     cfgvariant_check_v1e             ; 5E3D 0 208 ??? CE08
                CMPB    r7, #015h              ; 5E3F 0 208 ??? 27C015
                JNE     cfgvariant_remap_start             ; 5E42 0 208 ??? CE18
                INCB    r0                     ; 5E44 0 208 ??? A8
                SJ      cfgvariant_remap_start             ; 5E45 0 208 ??? CB15
cfgvariant_check_v1e:     CMPB    r6, #01fh              ; 5E47 0 208 ??? 26C01F
                JNE     cfgvariant_check_v1f             ; 5E4A 0 208 ??? CE08
                CMPB    r7, #016h              ; 5E4C 0 208 ??? 27C016
                JNE     cfgvariant_remap_start             ; 5E4F 0 208 ??? CE0B
                INCB    r0                     ; 5E51 0 208 ??? A8
                SJ      cfgvariant_remap_start             ; 5E52 0 208 ??? CB08
cfgvariant_check_v1f:     CMPB    r6, #019h              ; 5E54 0 208 ??? 26C019
                JEQ     cfgvariant_remap_start             ; 5E57 0 208 ??? C903
cfgvariant_check_v1f_load_r1:       MOVB    r1, r6                 ; 5E59 0 208 ??? 2649
                RT                             ; 5E5B 0 208 ??? 01
cfgvariant_remap_start:     CLR     A                      ; 5E5C 1 208 ??? F9
                LB      A, r6                  ; 5E5D 0 208 ??? 7E
                CMPB    A, #019h               ; 5E5E 0 208 ??? C619
                JNE     cfgvariant_remap_1a             ; 5E60 0 208 ??? CE04
                LB      A, #023h               ; 5E62 0 208 ??? 7723
                SJ      cfgvariant_remap_store             ; 5E64 0 208 ??? CB16
cfgvariant_remap_1a:     CMPB    A, #01ah               ; 5E66 0 208 ??? C61A
                JNE     cfgvariant_remap_1b             ; 5E68 0 208 ??? CE04
                LB      A, #024h               ; 5E6A 0 208 ??? 7724
                SJ      cfgvariant_remap_store             ; 5E6C 0 208 ??? CB0E
cfgvariant_remap_1b:     CMPB    A, #01bh               ; 5E6E 0 208 ??? C61B
                JNE     cfgvariant_remap_1d             ; 5E70 0 208 ??? CE04
                LB      A, #029h               ; 5E72 0 208 ??? 7729
                SJ      cfgvariant_remap_store             ; 5E74 0 208 ??? CB06
cfgvariant_remap_1d:     CMPB    A, #01dh               ; 5E76 0 208 ??? C61D
                JNE     cfgvariant_remap_store             ; 5E78 0 208 ??? CE02
                LB      A, #02bh               ; 5E7A 0 208 ??? 772B
cfgvariant_remap_store:     STB     A, r1                  ; 5E7C 0 208 ??? 89
                SRLB    A                      ; 5E7D 0 208 ??? 63
                MOV     X1, A                  ; 5E7E 0 208 ??? 50
                LB      A, r0                  ; 5E7F 0 208 ??? 78
                JGE     cfgvariant_bit_calc             ; 5E80 0 208 ??? CD02
                ADDB    A, #004h               ; 5E82 0 208 ??? 8604
cfgvariant_bit_calc:     SBR     00324h[X1]             ; 5E84 0 208 ??? C0240311
                RT                             ; 5E88 0 208 ??? 01
cfgvariant_snapshot_capture:     MOV     DP, #00344h            ; 5E89 0 208 ??? 624403
                LB      A, [DP]                ; 5E8C 0 208 ??? F2
                JNE     cfgvariant_snapshot_capture_return             ; 5E8D 0 208 ??? CE53
                J       cfgvariant_snapshot_capture_inc_dp             ; 5E8F 0 208 ??? 03965E
                DB  0FFh,0FFh,0FFh,0FFh ; 5E92
cfgvariant_snapshot_capture_inc_dp:     INC     DP                     ; 5E96 0 208 ??? 72
                LB      A, 0cch                ; 5E97 0 208 ??? F5CC
                STB     A, [DP]                ; 5E99 0 208 ??? D2
                INC     DP                     ; 5E9A 0 208 ??? 72
                L       A, 0c4h                ; 5E9B 1 208 ??? E5C4
                SWAP                           ; 5E9D 1 208 ??? 83
                ST      A, [DP]                ; 5E9E 1 208 ??? D2
                INC     DP                     ; 5E9F 1 208 ??? 72
                INC     DP                     ; 5EA0 1 208 ??? 72
                MOV     X1, #003d0h            ; 5EA1 1 208 ??? 60D003
                LB      A, 00000h[X1]          ; 5EA4 0 208 ??? F00000
                STB     A, [DP]                ; 5EA7 0 208 ??? D2
                INC     DP                     ; 5EA8 0 208 ??? 72
                MOV     X1, #003c8h            ; 5EA9 0 208 ??? 60C803
                LB      A, 00000h[X1]          ; 5EAC 0 208 ??? F00000
                STB     A, [DP]                ; 5EAF 0 208 ??? D2
                INC     DP                     ; 5EB0 0 208 ??? 72
                LB      A, 0bbh                ; 5EB1 0 208 ??? F5BB
                STB     A, [DP]                ; 5EB3 0 208 ??? D2
                INC     DP                     ; 5EB4 0 208 ??? 72
                MOV     X1, #003c9h            ; 5EB5 0 208 ??? 60C903
                LB      A, 00000h[X1]          ; 5EB8 0 208 ??? F00000
                STB     A, [DP]                ; 5EBB 0 208 ??? D2
                INC     DP                     ; 5EBC 0 208 ??? 72
                MOV     X1, #003a0h            ; 5EBD 0 208 ??? 60A003
                LB      A, 00000h[X1]          ; 5EC0 0 208 ??? F00000
                STB     A, [DP]                ; 5EC3 0 208 ??? D2
                INC     DP                     ; 5EC4 0 208 ??? 72
                LB      A, 0dbh                ; 5EC5 0 208 ??? F5DB
                STB     A, [DP]                ; 5EC7 0 208 ??? D2
                INC     DP                     ; 5EC8 0 208 ??? 72
                MOV     X1, #003a2h            ; 5EC9 0 208 ??? 60A203
                L       A, 00000h[X1]          ; 5ECC 1 208 ??? E00000
                SWAP                           ; 5ECF 1 208 ??? 83
                ST      A, [DP]                ; 5ED0 1 208 ??? D2
                INC     DP                     ; 5ED1 1 208 ??? 72
                INC     DP                     ; 5ED2 1 208 ??? 72
                LB      A, 0dah                ; 5ED3 0 208 ??? F5DA
                STB     A, [DP]                ; 5ED5 0 208 ??? D2
                INC     DP                     ; 5ED6 0 208 ??? 72
                LB      A, (0ffdah-0ffffh)[USP] ; 5ED7 0 208 ??? F3DB
                STB     A, [DP]                ; 5ED9 0 208 ??? D2
                INC     DP                     ; 5EDA 0 208 ??? 72
                LB      A, 09dh                ; 5EDB 0 208 ??? F59D
                STB     A, [DP]                ; 5EDD 0 208 ??? D2
                INC     DP                     ; 5EDE 0 208 ??? 72
                J       cfgvariant_snapshot_capture_load_ram2a1             ; 5EDF 0 208 ??? 03197B
cfgvariant_snapshot_capture_return:     RT                             ; 5EE2 0 208 ??? 01
cfgvariant_check_320h_bit7_sub_clear_acc:     CLR     A                      ; 5EE3 1 208 ??? F9
                J       cfgvariant_check_320h_bit7_sub_load_dp             ; 5EE4 1 208 ??? 03617A
cfgvariant_state_clear_loop:     DEC     DP                     ; 5EE7 1 208 ??? 82
                DEC     DP                     ; 5EE8 1 208 ??? 82
                ST      A, [DP]                ; 5EE9 1 208 ??? D2
                CMP     DP, #0031eh            ; 5EEA 1 208 ??? 92C01E03
                JGT     cfgvariant_state_clear_loop             ; 5EEE 1 208 ??? C8F7
                RT                             ; 5EF0 1 208 ??? 01
cfgvariant_ram_init:     CLR     X1                     ; 5EF1 1 208 ??? 9015
                L       A, #08000h             ; 5EF3 1 208 ??? 670080
                ST      A, 00300h[X1]          ; 5EF6 1 208 ??? D00003
                ST      A, 00304h[X1]          ; 5EF9 1 208 ??? D00403
                ST      A, 00308h[X1]          ; 5EFC 1 208 ??? D00803
                L       A, 00382h[X1]          ; 5EFF 1 208 ??? E08203
                ST      A, 0030ch[X1]          ; 5F02 1 208 ??? D00C03
                CLRB    A                      ; 5F05 0 208 ??? FA
                STB     A, 00310h[X1]          ; 5F06 0 208 ??? D01003
                STB     A, 0031bh[X1]          ; 5F09 0 208 ??? D01B03
                LB      A, #07bh               ; 5F0C 0 208 ??? 777B
                STB     A, 00311h[X1]          ; 5F0E 0 208 ??? D01103
                LB      A, #03bh               ; 5F11 0 208 ??? 773B
                STB     A, 0031ah[X1]          ; 5F13 0 208 ??? D01A03
                L       A, #00266h             ; 5F16 1 208 ??? 676602
                ST      A, 00312h[X1]          ; 5F19 1 208 ??? D01203
                ST      A, 00314h[X1]          ; 5F1C 1 208 ??? D01403
                L       A, #00100h             ; 5F1F 1 208 ??? 670001
                ST      A, 00316h[X1]          ; 5F22 1 208 ??? D01603
                ST      A, 00318h[X1]          ; 5F25 1 208 ??? D01803
                MOVB    off(002a0h), #0ffh     ; 5F28 1 208 ??? C4A098FF
                RT                             ; 5F2C 1 208 ??? 01
cfgvariant_checksum2_calc:     MOV     DP, #00324h            ; 5F2D 0 208 ??? 622403
                LB      A, [DP]                ; 5F30 0 208 ??? F2
                ANDB    A, #0f0h               ; 5F31 0 208 ??? D6F0
                STB     A, r0                  ; 5F33 0 208 ??? 88
                STB     A, r1                  ; 5F34 0 208 ??? 89
cfgvariant_checksum2_loop:     INC     DP                     ; 5F35 0 208 ??? 72
                LB      A, r0                  ; 5F36 0 208 ??? 78
                ADDB    A, [DP]                ; 5F37 0 208 ??? C282
                STB     A, r0                  ; 5F39 0 208 ??? 88
                LB      A, r1                  ; 5F3A 0 208 ??? 79
                XORB    A, [DP]                ; 5F3B 0 208 ??? C2F2
                STB     A, r1                  ; 5F3D 0 208 ??? 89
                CMP     DP, #00353h            ; 5F3E 0 208 ??? 92C05303
                JNE     cfgvariant_checksum2_loop             ; 5F42 0 208 ??? CEF1
                RT                             ; 5F44 0 208 ??? 01
boot_completion_helper:     CLRB    A                      ; 5F45 0 208 180 FA
                LCB     A, boot_completion_helper_tbl            ; 5F46 0 208 180 909DE660
                SLLB    A                      ; 5F4A 0 208 180 53
                MB      off(00216h).4, C       ; 5F4B 0 208 180 C4163C
                LCB     A, boot_completion_helper_tbl_2            ; 5F4E 0 208 180 909DE760
                SLLB    A                      ; 5F52 0 208 180 53
                MB      off(00227h).6, C       ; 5F53 0 208 180 C4273E
                J       boot_completion_helper_rom_load_tbl_60eb             ; 5F56 0 208 180 035E5F
                DB  0FFh,0FFh,0FFh,0FFh,0FFh ; 5F59
boot_completion_helper_rom_load_tbl_60eb:     LCB     A, boot_completion_helper_tbl_3            ; 5F5E 0 208 180 909DEB60
                SLLB    A                      ; 5F62 0 208 180 53
                MB      off(00219h).3, C       ; 5F63 0 208 180 C4193B
                LCB     A, boot_completion_helper_tbl_4            ; 5F66 0 208 180 909DEC60
                SLLB    A                      ; 5F6A 0 208 180 53
                MB      off(00217h).3, C       ; 5F6B 0 208 180 C4173B
                LCB     A, boot_completion_helper_tbl_5            ; 5F6E 0 208 180 909DED60
                SLLB    A                      ; 5F72 0 208 180 53
                MB      off(00227h).7, C       ; 5F73 0 208 180 C4273F
                LCB     A, boot_completion_helper_tbl_6            ; 5F76 0 208 180 909DEE60
                SLLB    A                      ; 5F7A 0 208 180 53
                MB      off(00216h).1, C       ; 5F7B 0 208 180 C41639
                LCB     A, boot_completion_helper_tbl_7            ; 5F7E 0 208 180 909DF060
                SLLB    A                      ; 5F82 0 208 180 53
                MB      off(00216h).7, C       ; 5F83 0 208 180 C4163F
                MOV     DP, #00356h            ; 5F86 0 208 180 625603
                MB      [DP].0, C              ; 5F89 0 208 180 C238
                LCB     A, boot_completion_helper_tbl_8            ; 5F8B 0 208 180 909DF160
                SLLB    A                      ; 5F8F 0 208 180 53
                MB      off(00227h).1, C       ; 5F90 0 208 180 C42739
                MOV     DP, #003c7h            ; 5F93 0 208 180 62C703
                LB      A, [DP]                ; 5F96 0 208 180 F2
                STB     A, r1                  ; 5F97 0 208 180 89
                RC                             ; 5F98 0 208 180 95
                LCB     A, idle_init_start_tbl            ; 5F99 0 208 180 909DFB60
                STB     A, r0                  ; 5F9D 0 208 180 88
                JNE     boot_completion_helper_store_carry_ram227_bit5             ; 5F9E 0 208 180 CE0C
                LCB     A, diag_mode_code_store_tbl            ; 5FA0 0 208 180 909DEA60
                JEQ     boot_completion_helper_store_carry_ram227_bit5             ; 5FA4 0 208 180 C906
                LB      A, r1                  ; 5FA6 0 208 180 79
                SLLB    A                      ; 5FA7 0 208 180 53
                SLLB    A                      ; 5FA8 0 208 180 53
                ANDB    r1, #080h              ; 5FA9 0 208 180 21D080
boot_completion_helper_store_carry_ram227_bit5:     MB      off(00227h).5, C       ; 5FAC 0 208 180 C4273D
                MOV     DP, #003cfh            ; 5FAF 0 208 180 62CF03
                LB      A, [DP]                ; 5FB2 0 208 180 F2
                STB     A, r2                  ; 5FB3 0 208 180 8A
                LCB     A, diag_mode_code_store_tbl            ; 5FB4 0 208 180 909DEA60
                JEQ     boot_completion_helper_load_r2             ; 5FB8 0 208 180 C906
                SLLB    r2                     ; 5FBA 0 208 180 22D7
                MOVB    r2, #080h              ; 5FBC 0 208 180 9A80
                RORB    r2                     ; 5FBE 0 208 180 22C7
boot_completion_helper_load_r2:     LB      A, r2                  ; 5FC0 0 208 180 7A
                CMPB    r0, #000h              ; 5FC1 0 208 180 20C000
                JEQ     boot_completion_helper_sllb_acc             ; 5FC4 0 208 180 C904
                LCB     A, boot_completion_helper_tbl_9            ; 5FC6 0 208 180 909DFC60
boot_completion_helper_sllb_acc:     SLLB    A                      ; 5FCA 0 208 180 53
                J       boot_completion_helper_store_carry_ram216_bit3             ; 5FCB 0 208 180 03457B
boot_completion_helper_cmp_r0:     CMPB    r0, #000h              ; 5FCE 0 208 180 20C000
                JEQ     boot_completion_helper_goto_7b55             ; 5FD1 0 208 180 C907
                LCB     A, boot_completion_helper_tbl_10            ; 5FD3 0 208 180 909DFD60
                SLLB    A                      ; 5FD7 0 208 180 53
                SJ      boot_flag_iabv_common             ; 5FD8 0 208 180 CB0D
boot_completion_helper_goto_7b55:     J       boot_completion_helper_set_carry             ; 5FDA 0 208 180 03557B
                DB  0FFh,0FFh,0FFh,0FFh ; 5FDD
boot_completion_helper_load_r2_2:     LB      A, r2                  ; 5FE1 0 208 180 7A
                SLLB    A                      ; 5FE2 0 208 180 53
                SLLB    A                      ; 5FE3 0 208 180 53
                XORB    PSWH, #080h            ; 5FE4 0 208 180 A2F080
boot_flag_iabv_common:     MB      off(00216h).2, C       ; 5FE7 0 208 180 C4163A
                CMPB    r0, #000h              ; 5FEA 0 208 180 20C000
                JEQ     boot_flag_iabv_common_goto_7b70             ; 5FED 0 208 180 C907
                LCB     A, boot_flag_iabv_common_tbl_3            ; 5FEF 0 208 180 909DFE60
                SLLB    A                      ; 5FF3 0 208 180 53
                SJ      boot_flag_iabv_common_goto_7b80             ; 5FF4 0 208 180 CB06
boot_flag_iabv_common_goto_7b70:     J       boot_flag_iabv_common_set_carry             ; 5FF6 0 208 180 03707B
boot_flag_iabv_common_xorb_pswh:     XORB    PSWH, #080h            ; 5FF9 0 208 180 A2F080
boot_flag_iabv_common_goto_7b80:     J       boot_flag_iabv_common_store_carry_ram216_bit0             ; 5FFC 0 208 180 03807B
boot_flag_iabv_common_cmp_r0:     CMPB    r0, #000h              ; 5FFF 0 208 180 20C000
tbl_6000        EQU     $-2 ; 6000
                JEQ     boot_flag_iabv_common_load_carry_ram216_bit2             ; 6002 0 208 180 C907
                LCB     A, boot_flag_iabv_common_tbl_4            ; 6004 0 208 180 909DFF60
                SLLB    A                      ; 6008 0 208 180 53
                SJ      boot_flag_iabv_common_store_carry_pswl_bit4             ; 6009 0 208 180 CB0E
boot_flag_iabv_common_load_carry_ram216_bit2:     MB      C, off(00216h).2       ; 600B 0 208 180 C4162A
                LCB     A, dwell_battery_check2_tbl            ; 600E 0 208 180 909DF260
                JEQ     boot_flag_iabv_common_store_carry_pswl_bit4             ; 6012 0 208 180 C905
                LB      A, r1                  ; 6014 0 208 180 79
                SLLB    A                      ; 6015 0 208 180 53
                XORB    PSWH, #080h            ; 6016 0 208 180 A2F080
boot_flag_iabv_common_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 6019 0 208 180 A33C
                CMPB    r0, #000h              ; 601B 0 208 180 20C000
                JNE     boot_flag_iabv_common_rom_load_tbl_60e9             ; 601E 0 208 180 CE06
                LCB     A, diag_mode_code_store_tbl            ; 6020 0 208 180 909DEA60
                JNE     boot_flag_iabv_common_clear_pswl_bit4             ; 6024 0 208 180 CE07
boot_flag_iabv_common_rom_load_tbl_60e9:     LCB     A, boot_flag_iabv_common_tbl_2            ; 6026 0 208 180 909DE960
                SLLB    A                      ; 602A 0 208 180 53
                SJ      boot_flag_iabv_common_store_carry_ram227_bit4             ; 602B 0 208 180 CB07
boot_flag_iabv_common_clear_pswl_bit4:     RB      PSWL.4                 ; 602D 0 208 180 A30C
                LB      A, r1                  ; 602F 0 208 180 79
                SLLB    A                      ; 6030 0 208 180 53
                XORB    PSWH, #080h            ; 6031 0 208 180 A2F080
boot_flag_iabv_common_store_carry_ram227_bit4:     MB      off(00227h).4, C       ; 6034 0 208 180 C4273C
                MB      C, PSWL.4              ; 6037 0 208 180 A32C
                MB      off(00217h).6, C       ; 6039 0 208 180 C4173E
                CMPB    r0, #000h              ; 603C 0 208 180 20C000
                JEQ     boot_flag_iabv_common_clear_carry             ; 603F 0 208 180 C907
                LCB     A, boot_flag_iabv_common_tbl_5            ; 6041 0 208 180 909D0061
                SLLB    A                      ; 6045 0 208 180 53
                SJ      boot_flag_iabv_common_store_carry_ram216_bit5             ; 6046 0 208 180 CB09
boot_flag_iabv_common_clear_carry:     RC                             ; 6048 0 208 180 95
                LCB     A, dwell_battery_check2_tbl            ; 6049 0 208 180 909DF260
                JNE     boot_flag_iabv_common_store_carry_ram216_bit5             ; 604D 0 208 180 CE02
                LB      A, r1                  ; 604F 0 208 180 79
                SLLB    A                      ; 6050 0 208 180 53
boot_flag_iabv_common_store_carry_ram216_bit5:     MB      off(00216h).5, C       ; 6051 0 208 180 C4163D
                CMPB    r0, #000h              ; 6054 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt             ; 6057 0 208 180 C907
                LCB     A, boot_flag_iabv_common_tbl_6            ; 6059 0 208 180 909D0161
                SLLB    A                      ; 605D 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_pswl_bit4             ; 605E 0 208 180 CB03
boot_flag_gearpreset_alt:     LB      A, r1                  ; 6060 0 208 180 79
                SLLB    A                      ; 6061 0 208 180 53
                SLLB    A                      ; 6062 0 208 180 53
boot_flag_gearpreset_alt_store_carry_pswl_bit4:     MB      PSWL.4, C              ; 6063 0 208 180 A33C
                CMPB    r0, #000h              ; 6065 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt_clear_carry             ; 6068 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl            ; 606A 0 208 180 909D0261
                SLLB    A                      ; 606E 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_ram227_bit3             ; 606F 0 208 180 CB0A
boot_flag_gearpreset_alt_clear_carry:     RC                             ; 6071 0 208 180 95
                LCB     A, diag_mode_code_store_tbl_2            ; 6072 0 208 180 909DF360
                JEQ     boot_flag_gearpreset_alt_store_carry_ram227_bit3             ; 6076 0 208 180 C903
                SC                             ; 6078 0 208 180 85
                NOP                            ; 6079 0 208 180 00
                NOP                            ; 607A 0 208 180 00
boot_flag_gearpreset_alt_store_carry_ram227_bit3:     MB      off(00227h).3, C       ; 607B 0 208 180 C4273B
                CMPB    r0, #000h              ; 607E 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt_load_carry_pswl_bit4             ; 6081 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_2            ; 6083 0 208 180 909D0361
                SLLB    A                      ; 6087 0 208 180 53
                SJ      boot_flag_gearpreset_alt_goto_7b9a             ; 6088 0 208 180 CB02
boot_flag_gearpreset_alt_load_carry_pswl_bit4:     MB      C, PSWL.4              ; 608A 0 208 180 A32C
boot_flag_gearpreset_alt_goto_7b9a:     J       boot_flag_gearpreset_alt_if_ram227_bit0_clr             ; 608C 0 208 180 039A7B
boot_flag_gearpreset_alt_cmp_r0:     CMPB    r0, #000h              ; 608F 0 208 180 20C000
                JEQ     boot_flag_gearpreset_alt_clear_carry_2             ; 6092 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_3            ; 6094 0 208 180 909D0461
                SLLB    A                      ; 6098 0 208 180 53
                SJ      boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 6099 0 208 180 CB1F
boot_flag_gearpreset_alt_clear_carry_2:     RC                             ; 609B 0 208 180 95
                JBS     off(00217h).6, boot_flag_gearpreset_alt_store_carry_ram219_bit4 ; 609C 0 208 180 EE171B
                LCB     A, boot_flag_gearpreset_alt_tbl_3            ; 609F 0 208 180 909D0461
                JNE     boot_flag_gearpreset_alt_load_dp             ; 60A3 0 208 180 CE0F
                LCB     A, dwell_battery_check2_tbl            ; 60A5 0 208 180 909DF260
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 60A9 0 208 180 C90F
                LCB     A, diag_snapshot_copy_loop_tbl_2            ; 60AB 0 208 180 909DF560
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4             ; 60AF 0 208 180 C909
                JBR     off(00216h).0, boot_flag_gearpreset_alt_store_carry_ram219_bit4 ; 60B1 0 208 180 D81606
boot_flag_gearpreset_alt_load_dp:     MOV     DP, #003ceh            ; 60B4 0 208 180 62CE03
                CMPB    [DP], #09ah            ; 60B7 0 208 180 C2C09A
boot_flag_gearpreset_alt_store_carry_ram219_bit4:     MB      off(00219h).4, C       ; 60BA 0 208 180 C4193C
                CMPB    r0, #000h              ; 60BD 0 208 180 20C000
                JEQ     boot_flag_3cf_check             ; 60C0 0 208 180 C907
                LCB     A, boot_flag_gearpreset_alt_tbl_4            ; 60C2 0 208 180 909D0561
                SLLB    A                      ; 60C6 0 208 180 53
                SJ      boot_flag_final             ; 60C7 0 208 180 CB09
boot_flag_3cf_check:     MOV     DP, #003cbh            ; 60C9 0 208 180 62CB03
                CMPB    [DP], #080h            ; 60CC 0 208 180 C2C080
                XORB    PSWH, #080h            ; 60CF 0 208 180 A2F080
boot_flag_final:     MOV     DP, #00356h            ; 60D2 0 208 180 625603
                MB      [DP].1, C              ; 60D5 0 208 180 C239
                L       A, #00700h             ; 60D7 1 208 180 670007
                JBS     off(00216h).3, boot_flag_final_load_dp ; 60DA 1 208 180 EB1603
                L       A, #00500h             ; 60DD 1 208 180 670005
boot_flag_final_load_dp:     MOV     DP, #00382h            ; 60E0 1 208 180 628203
                ST      A, [DP]                ; 60E3 1 208 180 D2
                RT                             ; 60E4 1 208 180 01
fuelmap_base_lookup_tbl:       DB  000h ; 60E5
boot_completion_helper_tbl:       DB  0FFh ; 60E6
boot_completion_helper_tbl_2:       DB  000h ; 60E7
boot_flag_iabv_common_tbl:       DB  000h ; 60E8
boot_flag_iabv_common_tbl_2:       DB  000h ; 60E9
diag_mode_code_store_tbl:       DB  000h ; 60EA
boot_completion_helper_tbl_3:       DB  0FFh ; 60EB
boot_completion_helper_tbl_4:       DB  0FFh ; 60EC
boot_completion_helper_tbl_5:       DB  000h ; 60ED
boot_completion_helper_tbl_6:       DB  0FFh ; 60EE
ignition_cut_mode_check_tbl:       DB  0FFh ; 60EF
boot_completion_helper_tbl_7:       DB  000h ; 60F0
boot_completion_helper_tbl_8:       DB  000h ; 60F1
dwell_battery_check2_tbl:       DB  000h ; 60F2
diag_mode_code_store_tbl_2:       DB  000h ; 60F3
diag_snapshot_copy_loop_tbl:       DB  000h ; 60F4
diag_snapshot_copy_loop_tbl_2:       DB  000h ; 60F5
diag_mode_code_store_tbl_3:       DB  000h ; 60F6
diag_mode_code_store_tbl_4:       DB  000h ; 60F7
injtimer_critsection_start_tbl:       DB  000h ; 60F8
ect_threshold_224_6_tbl:       DB  0FFh ; 60F9
vtec_engage_conditions_start_tbl:       DB  000h ; 60FA
idle_init_start_tbl:       DB  000h ; 60FB
boot_completion_helper_tbl_9:       DB  000h ; 60FC
boot_completion_helper_tbl_10:       DB  0FFh ; 60FD
boot_flag_iabv_common_tbl_3:       DB  0FFh ; 60FE
boot_flag_iabv_common_tbl_4:       DB  0FFh ; 60FF
boot_flag_iabv_common_tbl_5:       DB  000h ; 6100
boot_flag_iabv_common_tbl_6:       DB  000h ; 6101
boot_flag_gearpreset_alt_tbl:       DB  000h ; 6102
boot_flag_gearpreset_alt_tbl_2:       DB  000h ; 6103
boot_flag_gearpreset_alt_tbl_3:       DB  000h ; 6104
boot_flag_gearpreset_alt_tbl_4:       DB  0FFh ; 6105
deadtime_voltage_flag_store_tbl:       DB  006h,006h,006h,00Ah,00Bh,00Bh ; 6106
tbl_tps_custom_curve:       DB  004h,018h,004h,018h ; 610C
tbl_tps_custom_curve2:       DB  030h,040h,030h,040h,030h,040h,000h,000h ; 6110
                DB  000h,000h,000h,000h,000h,000h ; 6118
knockwindow_next_table_tbl:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h ; 611E
                DB  044h,042h,028h,041h,000h,040h ; 6126
knockwindow_next_table_tbl_2:       DB  0FFh,066h,0E6h,058h,0CFh,053h,0A1h,050h ; 612C
                DB  044h,04Ch,028h,041h,000h,040h ; 6134
knockwindow_next_table_tbl_3:       DB  0FFh,040h,000h,040h,000h,040h,000h,040h ; 613A
                DB  000h,040h,000h,040h,000h,040h ; 6142
knockwindow_next_table_tbl_4:       DB  0FFh,066h,0E6h,058h,0CFh,053h,0A1h,046h ; 6148
                DB  044h,043h,02Eh,040h,000h,040h ; 6150
knockwindow_next_table_tbl_5:       DB  0FFh,093h,0E6h,080h,0CFh,073h,0A1h,056h ; 6156
                DB  044h,046h,02Eh,040h,000h,040h ; 615E
knockwindow_next_table_tbl_6:       DB  0FFh,064h,0E6h,056h,0CFh,053h,0A1h,050h ; 6164
                DB  044h,04Ch,028h,041h,000h,040h ; 616C
IATFuelCorrect:       DB  0FFh,0E1h,09Ah,0F5h,0E1h,09Ah,0E1h,0A3h ; 6172
                DB  090h,0BAh,0AEh,087h,087h,000h,080h,034h ; 617A
                DB  052h,078h,000h,052h,078h ; 6182
PostFuelDecay:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h ; 6187
PostFuelDecay2:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h ; 618F
PostFuelDecay3:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h ; 6197
postfuel_calc_start_tbl:       DB  0FFh,0CDh,084h,0F1h,033h,083h,0E6h,09Ah ; 619F
                DB  079h,0CFh,0CDh,05Ch,0A1h,000h,040h,07Ah ; 61A7
                DB  0D7h,033h,040h,0C2h,025h,000h,0C2h,025h ; 61AF
o2trim_ect_offset_lookup_tbl:       DB  001h,000h,000h,001h,001h,000h,000h,002h ; 61B7
                DB  001h,000h,000h,004h ; 61BF
tbl_revlimit_cold1:       DB  0AEh,028h,0A1h,034h ; 61C3
tbl_revlimit_cold2:       DB  0B5h,02Eh,0A9h,062h ; 61C7
tbl_revlimit_cold3:       DB  0B5h,02Eh,0A9h,062h ; 61CB
CloseLoopRate:       DB  06Fh,000h,06Fh,000h,06Fh,000h,06Fh,000h ; 61CF
                DB  030h,000h,000h,000h,06Fh,000h,06Fh,000h ; 61D7
                DB  06Fh,000h,06Fh,000h,030h,000h,000h,000h ; 61DF
CloseLoopGoose:       DB  07Ch,003h,05Ah,004h,05Ah,004h,05Ah,004h ; 61E7
                DB  080h,000h,000h,000h,07Ch,003h,0CAh,004h ; 61EF
                DB  0CAh,004h,0CAh,004h,080h,000h,000h,000h ; 61F7
                DB  06Fh,000h,06Fh,000h,06Fh,000h,06Fh,000h ; 61FF
                DB  030h,000h,000h,000h,06Fh,000h,06Fh,000h ; 6207
                DB  06Fh,000h,06Fh,000h,030h,000h,000h,000h ; 620F
                DB  07Ch,003h,05Ah,004h,05Ah,004h,05Ah,004h ; 6217
                DB  080h,000h,000h,000h,07Ch,003h,0CAh,004h ; 621F
                DB  0CAh,004h,0CAh,004h,080h,000h,000h,000h ; 6227
tbl_closeloop_tps:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C5h,0D0h ; 622F
                DB  0C0h,0EAh,04Dh,0EAh,040h,0AEh,000h,0AEh ; 6237
tbl_revlimit_warm1:       DB  0EEh,000h,0A0h,030h ; 623F
ve_adjust2_gate_tbl:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C5h,0D0h ; 6243
                DB  0C0h,0EAh,04Dh,0EAh,040h,0AEh,000h,0AEh ; 624B
VEFuelCorrect:       DB  0FFh,080h,01Fh,080h,018h,080h,013h,08Bh ; 6253
                DB  000h,08Bh,000h,08Bh ; 625B
CloseLoopTPS:       DB  0FFh,094h,0D0h,094h,0A0h,088h,080h,069h ; 625F
                DB  040h,05Eh,000h,052h ; 6267
OpenLoopTPS:       DB  0FFh,09Ah,0D0h,09Ah,0A0h,08Dh,080h,073h ; 626B
                DB  040h,066h,000h,05Ah ; 6273
tbl_ve_accel_1:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h ; 6277
                DB  000h,080h,000h,080h ; 627F
tbl_ve_accel_2:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h ; 6283
                DB  000h,080h,000h,080h ; 628B
tbl_knockwindow_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah ; 628F
                DB  034h,060h,028h,059h,000h,059h ; 6297
tbl_knockwindow_4:       DB  0FFh,08Eh,0A1h,08Eh,087h,071h,06Eh,05Eh ; 629D
                DB  034h,04Bh,028h,03Dh,000h,03Dh ; 62A5
knockwindow_next_table_tbl_7:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,06Dh ; 62AB
                DB  034h,060h,028h,04Dh,000h,04Dh ; 62B3
knockwindow_next_table_tbl_8:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,050h ; 62B9
                DB  034h,043h,028h,030h,000h,030h ; 62C1
CylinderIGNCorrect:       DB  080h,080h,080h,080h ; 62C7
tbl_revlimit_warm2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 62CB
                DB  000h,000h,000h,000h ; 62D3
tbl_injtimer_finalize:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 62D7
                DB  000h,000h,000h,000h ; 62DF
knock_table2d_lookup_tbl:       DB  0FFh,064h,000h,0A7h,067h,000h,093h,094h ; 62E3
                DB  000h,07Eh,0C3h,000h,069h,054h,001h,054h ; 62EB
                DB  080h,002h,000h,080h,002h ; 62F3
tbl_tipin_enrich_rpm:       DB  050h,020h,003h,000h,000h,000h,030h,0EEh ; 62F8
                DB  002h,000h,019h,000h,020h,020h,003h,000h ; 6300
                DB  032h,000h,030h,0EEh,002h,000h,019h,000h ; 6308
                DB  030h,0E8h,003h,000h,04Bh,000h,020h,0B6h ; 6310
                DB  003h,000h,019h,000h,030h,065h,004h,000h ; 6318
                DB  050h,000h,030h,0E8h,003h,000h,032h,000h ; 6320
                DB  040h,065h,004h,000h,050h,000h ; 6328
tbl_tipin_normal_enrich:       DB  090h,001h,000h,001h,010h,000h,0FAh,000h ; 632E
                DB  0FAh,000h,018h,000h,05Eh,001h,0FAh,000h ; 6336
                DB  010h,000h,0C2h,001h,02Ch,001h,018h,000h ; 633E
                DB  0C2h,001h,02Ch,001h,018h,000h,0F4h,001h ; 6346
                DB  02Ch,001h,010h,000h,0F4h,001h,02Ch,001h ; 634E
                DB  010h,000h,058h,002h,02Ch,001h,010h,000h ; 6356
                DB  058h,002h,02Ch,001h,010h,000h ; 635E
Tipintempoffsetnormal:       DB  0FFh,04Dh,000h,0A2h,04Dh,000h,040h,080h ; 6364
                DB  000h,028h,000h,001h,000h,000h,001h,000h ; 636C
                DB  000h,001h ; 6374
Tipintempoffsetinitial:       DB  0FFh,04Dh,000h,0A2h,04Dh,000h,040h,080h,000h,028h ; 6376
                DB  000h,001h,000h,000h,001h,000h,000h,001h,010h,0E6h ; 6380
                DB  000h,002h,000h,001h,050h,0F3h,000h,008h,000h,001h ; 638A
tbl_tipin_low:       DB  050h,0E6h,000h,010h,000h,001h,050h,0E6h ; 6394
                DB  000h,010h,000h,001h ; 639C
tbl_revlimit_cold4:       DB  0FFh,080h,000h,080h ; 63A0
tbl_rpm_decel:       DB  0FFh,008h,000h,08Bh,008h,000h,080h,018h ; 63A4
                DB  000h,060h,050h,000h,040h,070h,000h,020h ; 63AC
                DB  0A0h,000h,000h,0C0h,000h ; 63B4
tbl_knockwindow_5:       DB  0FFh,07Dh,000h,000h,07Dh,000h,000h,07Dh ; 63B9
                DB  000h,000h,07Dh,000h,000h,07Dh,000h ; 63C1
tbl_knockwindow_6:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 63C8
                DB  06Eh,020h,028h,010h,000h,010h ; 63D0
knockwindow_next_table_tbl_9:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 63D6
                DB  06Eh,020h,028h,010h,000h,010h ; 63DE
tbl_knockwindow_7:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h ; 63E4
                DB  06Eh,020h,028h,008h,000h,008h ; 63EC
knockwindow_next_table_tbl_10:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h ; 63F2
                DB  06Eh,020h,028h,008h,000h,008h ; 63FA
knockwindow_next_table_tbl_11:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 6400
                DB  06Eh,020h,028h,010h,000h,010h ; 6408
tbl_knockwindow_8:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h ; 640E
                DB  06Eh,020h,028h,010h,000h,010h ; 6416
Cranking_tbl:       DB  0FFh,0D2h,05Ah,0F1h,0D2h,05Ah,0E6h,0CDh ; 641C
                DB  046h,0CFh,010h,027h,0A1h,06Ah,018h,087h ; 6424
                DB  09Ah,010h,040h,02Eh,009h,028h,098h,008h ; 642C
                DB  000h,098h,008h,0FFh,0FFh,0FFh,0FFh ; 6434
CrankFuelMap:       DB  0FFh,080h,000h,080h ; 643B
Overrun_Resume_int:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah ; 643F
                DB  034h,060h,028h,059h,000h,059h ; 6447
Overrun_Resume_nor:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h ; 644D
                DB  034h,04Dh,028h,03Fh,000h,03Fh ; 6455
knockwindow_next_table_tbl_12:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah ; 645B
                DB  034h,060h,028h,059h,000h,059h ; 6463
knockwindow_next_table_tbl_13:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h ; 6469
                DB  034h,04Dh,028h,03Fh,000h,03Fh ; 6471
tbl_ignmap2_lo:       DB  0FFh,020h,0E0h,020h,0D0h,01Bh,0C0h,015h ; 6477
                DB  0A0h,00Fh,000h,00Fh ; 647F
tbl_ignmap2_hi:       DB  0FFh,018h,0E0h,018h,0D0h,013h,0C0h,00Dh ; 6483
                DB  0A0h,007h,000h,007h ; 648B
tbl_revlimit_warm3:       DB  0FFh,000h,000h,000h ; 648F
tbl_threshold_223_1:       DB  01Eh,02Bh,001h,001h,04Eh,001h ; 6493
Revlimiters:       DB  01Eh,02Bh,0FDh,000h,002h,001h ; 6499
tbl_threshold_223_2:       DB  01Eh,02Bh,001h,001h,04Eh,001h ; 649F
dwell_battery_check2_tbl_2:       DB  01Eh,02Bh,0FDh,000h ; 64A5
dwell_battery_check2_tbl_3:       DB  002h,001h,028h,05Ah,028h,04Dh,028h,040h ; 64A9
                DB  028h,040h,028h,040h ; 64B1
knock_table_index_tbl:       DB  033h,073h,09Ah,079h,000h,080h,066h,086h ; 64B5
                DB  0CDh,08Ch,0CDh,08Ch,033h,073h,09Ah,079h ; 64BD
                DB  000h,080h,066h,086h,0CDh,08Ch,0CDh,08Ch ; 64C5
tbl_knock_div:       DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h ; 64CD
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h ; 64D5
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h ; 64DD
                DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h ; 64E5
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h ; 64ED
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h ; 64F5
knock_div_calc4_tbl:       DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h ; 64FD
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h ; 6505
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h ; 650D
                DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h ; 6515
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h ; 651D
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h ; 6525
GearCustom:       DB  04Ah,000h,07Eh,000h,0B7h,000h,0ECh,000h ; 652D
knock_table2d_lookup_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,080h ; 6535
newval_table3_call_tbl:       DB  0FFh,0FFh,000h,0FFh ; 653A
newval_table3_call_tbl_2:       DB  0FFh,0FFh,000h,0FFh ; 653E
vtec_engage_gate_start_tbl:       DB  0CAh,0CDh,0D5h,0D8h ; 6542
vtec_engage_gate_start_tbl_2:       DB  0CAh,0CDh,0D5h,0D8h ; 6546
vtec_engage_gate_start_tbl_3:       DB  0FFh,03Fh,0D5h,03Fh,0CAh,0AEh,000h,0AEh ; 654A
                DB  000h,0AEh,000h,0AEh,000h,0AEh ; 6552
vtec_engage_gate_start_tbl_4:       DB  0FFh,03Fh,0D5h,03Fh,0CAh,0AEh,000h,0AEh ; 6558
                DB  000h,0AEh,000h,0AEh,000h,0AEh ; 6560
revlimit_table_select_tbl:       DB  0FFh,000h,000h,000h ; 6566
vcal3_leanprotect_ratelimit_tbl:       DB  0FFh,001h,09Fh,001h,09Bh,013h,06Eh,013h ; 656A
                DB  05Ah,013h,041h,005h,000h,005h ; 6572
vcal3_leanprotect_ratelimit_tbl_2:       DB  0FFh,096h,0CFh,096h,0CEh,07Fh,088h,051h ; 6578
                DB  04Eh,02Ch,041h,020h,038h,014h,02Ch,00Fh ; 6580
                DB  000h,00Fh ; 6588
vcal3_leanprotect_ratelimit_tbl_3:       DB  0FFh,0A5h,0CFh,0A5h,0CEh,08Fh,07Eh,064h ; 658A
                DB  065h,051h,04Eh,044h,034h,033h,02Ch,02Dh ; 6592
                DB  000h,02Dh ; 659A
vcal3_leanprotect_ratelimit_tbl_4:       DB  0FFh,065h,0CFh,065h,0CEh,041h,08Fh,033h ; 659C
                DB  068h,026h,04Eh,019h,044h,014h,02Ch,00Fh ; 65A4
                DB  000h,00Fh ; 65AC
vcal3_leanprotect_ratelimit_tbl_5:       DB  0FFh,071h,0CFh,071h,0CEh,05Fh,0ADh,052h ; 65AE
                DB  073h,040h,04Eh,032h,041h,02Bh,02Ch,021h ; 65B6
                DB  000h,021h ; 65BE
vcal3_leanprotect_ratelimit_tbl_6:       DB  0FFh,02Eh,0CFh,02Eh,0CEh,027h,07Ch,016h ; 65C0
                DB  04Eh,011h,041h,00Fh,034h,00Dh,02Ch,00Ch ; 65C8
                DB  000h,00Ch ; 65D0
vcal3_leanprotect_ratelimit_tbl_7:       DB  0FFh,03Bh,0CFh,03Bh,0CEh,033h,08Fh,028h ; 65D2
                DB  068h,01Eh,04Ch,016h,034h,013h,02Ch,011h ; 65DA
                DB  000h,011h ; 65E2
vcal3_leanprotect_ratelimit_tbl_8:       DB  075h,004h,0B0h,006h,0A0h,00Bh,0DEh,03Ah ; 65E4
                DB  02Eh,003h,053h,004h,022h,006h,051h,00Bh ; 65EC
vcal3_leanprotect_ratelimit_tbl_9:       DB  0FFh,0FAh,0B0h,0FAh,09Bh,0FAh,082h,0FAh ; 65F4
                DB  080h,09Ch,078h,092h,064h,076h,05Ah,069h ; 65FC
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h ; 6604
vcal3_leanprotect_ratelimit_tbl_10:       DB  0FFh,0FAh,0B0h,0FAh,08Eh,0FAh,087h,0FAh ; 660C
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh ; 6614
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h ; 661C
vcal3_leanprotect_ratelimit_tbl_11:       DB  0FFh,0FAh,09Ch,0FAh,09Ah,0B6h,096h,0B6h ; 6624
                DB  085h,0A2h,078h,092h,064h,076h,05Ah,069h ; 662C
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h ; 6634
vcal3_leanprotect_ratelimit_tbl_12:       DB  0FFh,0FAh,0A1h,0FAh,09Fh,0A3h,09Bh,0A3h ; 663C
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh ; 6644
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h ; 664C
vcal3_leanprotect_ratelimit_tbl_13:       DB  0FFh,014h,0B4h,014h,04Eh,014h,04Ch,003h,000h,003h ; 6654
vcal3_leanprotect_ratelimit_tbl_14:       DB  0FFh,01Bh,0B4h,01Bh,04Eh,01Bh,04Ch,006h,000h,006h ; 665E
vcal3_leanprotect_ratelimit_tbl_15:       DB  0FFh,080h,000h,010h,080h,000h,008h,060h ; 6668
                DB  000h,004h,000h,001h,000h,000h,000h ; 6670
vcal3_leanprotect_ratelimit_tbl_16:       DB  0FFh,080h,000h,012h,010h,000h,008h,040h ; 6677
                DB  000h,004h,080h,000h,000h,000h,000h ; 667F
vcal3_leanprotect_ratelimit_tbl_17:       DB  0FFh,02Ch,050h,02Ch,03Ch,01Eh,028h,01Eh ; 6686
                DB  019h,01Ch,014h,01Ch,000h,01Ch ; 668E
vcal3_leanprotect_ratelimit_tbl_18:       DB  0FFh,038h,050h,038h,03Ch,032h,028h,032h ; 6694
                DB  019h,02Eh,014h,02Ah,000h,020h ; 669C
vcal3_leanprotect_ratelimit_tbl_19:       DB  0FFh,033h,078h,033h,050h,02Eh,03Ch,01Eh ; 66A2
                DB  028h,01Eh,014h,01Ch,000h,01Ch ; 66AA
vcal3_leanprotect_ratelimit_tbl_20:       DB  0FFh,03Fh,078h,03Fh,050h,03Ah,03Ch,035h ; 66B0
                DB  028h,033h,014h,02Ah,000h,020h ; 66B8
idle_init_start_tbl_2:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh ; 66BE
idle_init_start_tbl_3:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh ; 66C6
knockwindow_next_table_tbl_14:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 66CE
                DB  0FFh,0FFh,0FFh,0FFh,000h,0FFh ; 66D6
tps_hysteresis_reentry_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 66DC
                DB  0FFh,0FFh,0FFh,0FFh,000h,0FFh ; 66E4
to_vtec_debounce_store_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 66EA
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 66F2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 66FA
                DB  0FFh,0FFh,0FFh,0FFh ; 6702
knockretard_clear_state_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6706
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 670E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6716
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 671E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6726
                DB  0FFh,0FFh,000h,0FFh,0FFh,0FFh,0FFh,0FFh ; 672E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6736
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 673E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6746
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 674E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,000h,0FFh ; 6756
knockretard_clear_state_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 675E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6766
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 676E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6776
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 677E
                DB  0FFh,0FFh,000h,0FFh,0FFh,0FFh,0FFh,0FFh ; 6786
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 678E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6796
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 679E
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67A6
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,000h,0FFh ; 67AE
tbl_vtec_transition_retard:       DB  000h,000h,011h,055h,077h,0FFh ; 67B6
knockwindow_next_table_tbl_15:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67BC
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67C4
                DB  0FFh,0FFh,000h,0FFh,0FFh ; 67CC
ignmap_alt_path_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67D1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67D9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67E1
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67E9
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67F1
                DB  0FFh,0FFh,000h,0FFh ; 67F9
ignmap_alt_path_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 67FD
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6805
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 680D
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6815
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 681D
                DB  0FFh,0FFh,000h,0FFh ; 6825
ZoneIndexTable1_SetB:       DB  0FFh,000h,014h,0F0h,000h,014h,0E0h,000h ; 6829
                DB  00Ah,0CAh,000h,00Ch,080h,000h,010h,060h ; 6831
                DB  000h,00Eh,035h,000h,007h,028h,000h,000h ; 6839
                DB  000h,000h,000h ; 6841
knockwindow_next_table_tbl_16:       DB  0FFh,000h,017h,0F0h,000h,017h,0E0h,000h ; 6844
                DB  010h,0CAh,000h,011h,090h,000h,01Dh,070h ; 684C
                DB  000h,01Bh,035h,000h,008h,028h,000h,000h ; 6854
                DB  000h,000h,000h ; 685C
idle_mode_dispatch_tbl:       DB  0FFh,000h,026h,0F0h,000h,026h,0E0h,000h ; 685F
                DB  013h,0CAh,000h,013h,080h,000h,015h,060h ; 6867
                DB  000h,012h,035h,000h,00Bh,028h,000h,009h ; 686F
                DB  000h,000h,009h ; 6877
ZoneIndexTable3_SetA:       DB  0FFh,000h,02Ah,0F0h,000h,02Ah,0E0h,000h ; 687A
                DB  01Bh,0CAh,000h,019h,090h,000h,025h,070h ; 6882
                DB  000h,021h,035h,000h,00Eh,028h,000h,00Ah ; 688A
                DB  000h,000h,00Ah ; 6892
ZoneIndexTable2_SetB:       DB  0FFh,000h,019h,0F0h,000h,019h,0E0h,000h ; 6895
                DB  00Eh,0CAh,000h,010h,080h,000h,014h,060h ; 689D
                DB  000h,011h,035h,000h,00Ah,028h,000h,008h ; 68A5
                DB  000h,000h,008h ; 68AD
ZoneIndexTable2_SetA:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h ; 68B0
                DB  015h,0CAh,000h,016h,090h,000h,024h,070h ; 68B8
                DB  000h,020h,035h,000h,00Dh,028h,000h,009h ; 68C0
                DB  000h,000h,009h ; 68C8
IdleVsECT:       DB  0FFh,0E2h,004h,0A1h,03Bh,005h,087h,0A2h ; 68CB
                DB  005h,06Eh,01Bh,006h,034h,00Bh,009h,028h ; 68D3
                DB  035h,00Ch,000h,035h,00Ch ; 68DB
idle_target_correction_done_tbl:       DB  0FFh,0E2h,004h,0A1h,0E2h,004h,087h,03Bh ; 68E0
                DB  005h,06Eh,0A2h,005h,034h,023h,008h,028h ; 68E8
                DB  00Bh,009h,000h,00Bh,009h ; 68F0
idle_temp_hyst3_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h ; 68F5
                DB  034h,050h,028h,042h,000h,042h,0FFh,09Ah ; 68FD
                DB  0A1h,09Ah,087h,083h,06Eh,073h,034h,066h ; 6905
                DB  028h,04Dh,000h,04Dh ; 690D
idle_target_correction_done_tbl_2:       DB  0FFh,092h,0A1h,092h,087h,07Ah,06Eh,073h ; 6911
                DB  034h,05Dh,028h,04Dh,000h,04Dh,0FFh,09Ah ; 6919
                DB  0A1h,09Ah,087h,086h,06Eh,083h,034h,070h ; 6921
                DB  028h,05Ah,000h,05Ah ; 6929
tbl_idle_default1:       DB  0FFh,0FFh,06Bh,000h,035h,00Ch,06Bh,000h ; 692D
                DB  0C4h,009h,044h,000h,00Bh,009h,03Ah,000h ; 6935
                DB  053h,007h,026h,000h,04Eh,004h,00Eh,000h ; 693D
                DB  000h,000h,00Eh,000h ; 6945
tbl_idle_default2:       DB  0FFh,0FFh,095h,000h,035h,00Ch,095h,000h ; 6949
                DB  0C4h,009h,061h,000h,00Bh,009h,053h,000h ; 6951
                DB  053h,007h,037h,000h,04Eh,004h,013h,000h ; 6959
                DB  000h,000h,013h,000h ; 6961
tbl_idle_lookup4:       DB  0FFh,0FFh,0BFh,001h,035h,00Ch,0BFh,001h ; 6965
                DB  0C4h,009h,027h,001h,00Bh,009h,0FFh,000h ; 696D
                DB  053h,007h,0ABh,000h,04Eh,004h,03Dh,000h ; 6975
                DB  000h,000h,03Dh,000h ; 697D
tbl_idle_lookup3:       DB  000h,080h,000h,004h,000h,008h ; 6981
tbl_idle_select_default:       DB  000h,0F0h,000h,008h,000h,00Eh ; 6987
tbl_idle_timer:       DB  000h,040h,000h,006h,000h,006h ; 698D
idle_table_select2_tbl:       DB  000h,0F0h,0C0h,000h,050h,000h ; 6993
tbl_idle_gear2:       DB  000h,000h,000h,080h,001h,000h ; 6999
tbl_idle_select1:       DB  000h,0F0h,000h,040h,000h,000h ; 699F
tbl_idle_select3a:       DB  0FFh,080h,001h,050h,080h,001h,030h,080h ; 69A5
                DB  002h,000h,000h,003h,000h,000h,003h,000h ; 69AD
                DB  000h,003h ; 69B5
idle_table_select3_tbl:       DB  0FFh,080h,001h,057h,080h,001h,03Ch,080h ; 69B7
                DB  002h,02Eh,000h,004h,028h,000h,00Ah,000h ; 69BF
                DB  000h,00Ch ; 69C7
tbl_idle_stall:       DB  0FFh,000h,000h,000h ; 69C9
tbl_ect_vecorrect:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h ; 69CD
                DB  034h,050h,028h,042h,000h,042h ; 69D5
tbl_idle_gate6:       DB  0FFh,014h,000h,034h,014h,000h,028h,030h ; 69DB
                DB  000h,000h,030h,000h,000h,030h,000h,000h ; 69E3
                DB  030h,000h,000h,030h,000h ; 69EB
tbl_ect_overrun_nor:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh ; 69F0
                DB  000h,0FFh,000h,0FFh,000h,0FFh ; 69F8
tbl_idle_sub1:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah ; 69FE
                DB  034h,009h,028h,007h,000h,007h ; 6A06
tbl_idle_sub2:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah ; 6A0C
                DB  034h,009h,028h,007h,000h,007h ; 6A14
tbl_idle_pid_lo1:       DB  0FFh,0C0h,040h,0C0h,028h,0A5h,01Ah,080h ; 6A1A
                DB  013h,080h,000h,06Bh ; 6A22
tbl_idle_pid_lo2:       DB  0FFh,0A8h,040h,0A8h,028h,08Dh,020h,080h ; 6A26
                DB  013h,060h,000h,040h ; 6A2E
tbl_idle_pid_lo3:       DB  0FFh,09Ch,040h,09Ch,028h,080h,020h,074h ; 6A32
                DB  013h,062h,000h,05Ah ; 6A3A
tbl_idle_pid_a:       DB  0FFh,0A8h,040h,0A8h,028h,08Dh,020h,080h ; 6A3E
                DB  013h,060h,000h,040h ; 6A46
tbl_idle_pid_b:       DB  0FFh,09Ch,040h,09Ch,028h,080h,020h,074h ; 6A4A
                DB  013h,062h,000h,05Ah ; 6A52
tbl_idle_pid_hi1:       DB  0FFh,000h,006h,0B0h,010h,004h,098h,0F0h ; 6A56
                DB  002h,080h,090h,001h,070h,000h,000h,000h ; 6A5E
                DB  000h,000h ; 6A66
tbl_idle_pid_hi2:       DB  0FFh,0B0h,007h,0A0h,020h,005h,088h,0E0h ; 6A68
                DB  003h,070h,000h,002h,060h,000h,000h,000h ; 6A70
                DB  000h,000h ; 6A78
tbl_idle_pid_hi3:       DB  0FFh,000h,007h,0A0h,080h,004h,088h,080h ; 6A7A
                DB  003h,068h,040h,001h,054h,000h,000h,000h ; 6A82
                DB  000h,000h ; 6A8A
tbl_idle_pid_c:       DB  0FFh,0B0h,007h,0A0h,020h,005h,088h,0E0h ; 6A8C
                DB  003h,070h,000h,002h,060h,000h,000h,000h ; 6A94
                DB  000h,000h ; 6A9C
tbl_idle_pid_d:       DB  0FFh,000h,007h,0A0h,080h,004h,088h,080h ; 6A9E
                DB  003h,068h,040h,001h,054h,000h,000h,000h ; 6AA6
                DB  000h,000h ; 6AAE
tbl_ect_overrun_int:       DB  0FFh,0C0h,0A1h,0C0h,044h,0ADh,028h,080h,000h,080h ; 6AB0
tbl_idle_pid_final1:       DB  0FFh,000h,00Bh,0C0h,000h,00Ch,060h,000h ; 6ABA
                DB  00Eh,030h,000h,013h,000h,000h,016h ; 6AC2
idle_pid_store_final_tbl:       DB  0FFh,000h,00Bh,0C0h,000h,00Ch,060h,000h ; 6AC9
                DB  00Eh,030h,000h,013h,000h,000h,016h ; 6AD1
tbl_idle_pid_final2:       DB  0FFh,0C0h,0B0h,0C0h,080h,098h,053h,080h,000h,080h ; 6AD8
inc_dp_step_tbl:       DB  0FFh,000h,00Eh,0D0h,000h,00Eh,0BAh,000h ; 6AE2
                DB  00Eh,094h,000h,00Dh,055h,000h,008h,042h ; 6AEA
                DB  000h,006h,028h,080h,000h,000h,080h,000h ; 6AF2
                DB  000h,080h,000h ; 6AFA
inc_dp_step_tbl_2:       DB  0FFh,0FFh,080h,000h,035h,00Ch,080h,000h,0C4h,009h ; 6AFD
                DB  000h,005h,00Bh,009h,000h,007h,000h,000h,080h,007h ; 6B07
ModePageTable_SetA:       DB  040h,000h,010h,008h,000h,000h ; 6B11
ModePageTable_SetB:       DB  040h,0FFh,03Fh,008h,000h,000h ; 6B17
tbl_idle_pid_out2:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,066h,000h ; 6B1D
                DB  020h,040h,000h,010h,000h,000h,006h ; 6B25
tbl_idle_sub_gate1:       DB  0FFh,000h,00Ah,0C0h,000h,00Ah,080h,000h ; 6B2C
                DB  00Ah,060h,000h,008h,000h,000h,005h ; 6B34
tbl_idle_sub_gate2:       DB  0FFh,000h,00Bh,0C0h,000h,00Bh,080h,000h ; 6B3B
                DB  00Bh,060h,000h,009h,000h,000h,006h ; 6B43
tbl_ve_map_scalar_alt:       DB  0FFh,0FFh,03Fh,055h,0FFh,03Fh,039h,000h ; 6B4A
                DB  00Ah,02Ch,000h,000h,000h,000h,000h,000h ; 6B52
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6B5A
tbl_ve_map_scalar:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,0A0h,000h ; 6B62
                DB  020h,080h,000h,00Ah,064h,000h,000h,000h ; 6B6A
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6B72
idle_stall_trigger_tbl:       DB  0FFh,000h,010h,0D0h,000h,00Ah,0A0h,000h ; 6B7A
                DB  007h,060h,000h,005h,028h,000h,003h,000h ; 6B82
                DB  000h,003h ; 6B8A
idle_stall_trigger_tbl_2:       DB  0FFh,060h,000h,0D0h,040h,000h,0A0h,020h ; 6B8C
                DB  000h,060h,010h,000h,028h,00Ch,000h,000h ; 6B94
                DB  00Ch,000h ; 6B9C
idle_stall_trigger_tbl_3:       DB  0FFh,004h,000h,0D0h,003h,000h,0A0h,002h ; 6B9E
                DB  000h,060h,002h,000h,028h,002h,000h,000h ; 6BA6
                DB  001h,000h ; 6BAE
tbl_iat_correct1:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 6BB0
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6BB8
                DB  000h,000h ; 6BC0
tbl_iat_correct2:       DB  0FFh,080h,000h,080h ; 6BC2
knockwindow_next_table_tbl_17:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 6BC6
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6BCE
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6BD6
                DB  000h,000h,000h ; 6BDE
tbl_knockwindow_9:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 6BE1
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6BE9
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6BF1
                DB  000h,000h,000h ; 6BF9
tbl_idle_gear_target:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,0CDh,0ACh ; 6BFC
                DB  048h,031h,09Ah,099h,0B0h,017h,09Ah,079h ; 6C04
                DB  070h,00Ah,000h,060h,0E2h,004h,033h,053h ; 6C0C
                DB  080h,001h,066h,046h,000h,000h,066h,026h ; 6C14
tbl_idle_dc:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h ; 6C1C
                DB  000h,006h,08Fh,082h,080h,003h,014h,07Eh ; 6C24
                DB  080h,002h,00Ah,077h,080h,001h,0AEh,067h ; 6C2C
                DB  000h,001h,0C2h,055h,000h,000h,0C2h,055h ; 6C34
state_21a_7_dispatch2_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C3C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C44
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C4C
state_21a_7_dispatch2_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C52
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C5C
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C66
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6C70
DwellBaseValues:       DB  0FFh,0B8h,0ABh,09Ah,055h,05Ch,047h,055h ; 6C7A
                DB  039h,04Dh,02Bh,03Ch,00Bh,010h,000h,010h ; 6C82
DwellBattery:       DB  0FFh,01Ch,0BCh,02Eh,0A7h,034h,092h,040h,07Dh,050h ; 6C8A
                DB  068h,068h,054h,0A0h,03Fh,0D9h,000h,0D9h,000h,0D9h ; 6C94
dwell_base_lookup_tbl:       DB  0FFh,03Bh,0AAh,025h,071h,017h,038h,009h ; 6C9E
                DB  01Ch,002h,013h,000h,000h,000h ; 6CA6
tbl_knockwindow_10:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 6CAC
                DB  000h,000h,000h,000h ; 6CB4
tbl_ignmap_idle1:                 DW  064d4h           ; 6CB8
knockwindow_next_table_tbl_18:       DB  0FFh,06Fh,0E6h,067h,0BFh,049h,094h,02Ah ; 6CBA
                DB  057h,011h,028h,000h,000h,000h ; 6CC2
knockwindow_next_table_tbl_19:       DB  0FFh,05Ah,0E6h,051h,0BFh,033h,094h,022h ; 6CC8
                DB  057h,011h,028h,000h,000h,000h ; 6CD0
tbl_ignmap_idle2:       DB  077h,064h,0C1h,064h ; 6CD6
knockwindow_next_table_tbl_20:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 6CDA
                DB  000h,000h,000h,000h ; 6CE2
tbl_ect_fuelcorrect:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,00Dh ; 6CE6
                DB  00Fh,015h,000h,015h ; 6CEE
iat_map_correction_chain_tbl:       DB  0FFh,000h,06Ch,000h,044h,00Ch,02Eh,015h,000h,015h ; 6CF2
HiIdleIgnControl:       DB  0FFh,0FFh,011h,000h,000h,001h,00Ch,000h ; 6CFC
                DB  040h,000h,008h,000h,000h,000h,000h,000h ; 6D04
IgnControl:       DB  0FFh,0FFh,00Ch,000h,0D9h,000h,00Ch,000h ; 6D0C
                DB  03Dh,000h,008h,000h,000h,000h,000h,000h ; 6D14
dwell_scale_shift_tbl:       DB  000h,000h,000h,000h,000h,000h,000h,000h,015h,037h ; 6D1C
                DB  03Eh,044h,048h,04Bh,060h,072h,070h,062h,062h,062h ; 6D26
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6D30
                DB  000h,000h,000h,000h,015h,037h,044h,060h,077h,062h ; 6D3A
dwell_scale_shift_tbl_2:       DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6D44
                DB  004h,01Dh,022h,033h,037h,02Ah,03Bh,03Bh ; 6D4C
                DB  03Bh,04Dh,04Dh,04Dh,000h,000h,000h,000h ; 6D54
                DB  000h,000h,000h,000h,004h,01Dh,022h,033h ; 6D5C
                DB  037h,02Ah,03Bh,03Bh,03Bh,04Dh,04Dh ; 6D64
clamp_result_store_tbl:       DB  04Dh ; 6D6B
knockretard_clear_state_tbl_3:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h ; 6D6C
                DB  000h,000h,000h,000h ; 6D74
knockretard_clear_state_tbl_4:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h ; 6D78
                DB  000h,000h,000h,000h ; 6D80
TipinTPS:       DB  0FFh,05Ah,0D0h,05Ah,0C0h,05Ah,0A0h,04Dh ; 6D84
                DB  080h,040h,040h,033h,000h,033h ; 6D8C
TipinRPM:       DB  0FFh,02Ah,0A0h,040h,090h,04Ch,080h,04Ch ; 6D92
                DB  066h,044h,040h,040h,000h ; 6D9A
tipin_enrich_lookup_tbl:       DB  02Ah,001h,002h,003h,002h,001h ; 6D9F
TipinRetard:       DB  0FFh,080h,080h,080h,067h,080h,04Dh,066h ; 6DA5
                DB  040h,040h,000h,000h ; 6DAD
callhelper_table_interp_lookup_tbl:       DB  0FFh,000h,0D4h,000h,0D0h,00Eh,0C8h,00Ch ; 6DB1
                DB  0B0h,00Eh,0A0h,00Eh,098h,000h,000h,000h ; 6DB9
                DB  000h,000h ; 6DC1
knockretard_clear_state_tbl_5:       DB  0FFh,000h,09Ah,00Ch,052h,040h,033h,040h ; 6DC3
                DB  026h,015h,000h,000h ; 6DCB
TipinGear:       DB  000h,080h,046h,046h,046h,0FFh,0FFh,0FFh ; 6DCF
tbl_map_sign:       DB  060h,0F0h,020h,060h ; 6DD7
tbl_ect_simulate_ramp:       DB  0DFh,0CFh,0A1h,057h,028h ; 6DDB
tbl_dcode14_lo:       DB  0C2h,000h,0FAh,03Eh,000h,047h ; 6DE0
tbl_dcode14_hi:       DB  0E5h,000h,051h,03Eh,000h,019h ; 6DE6
revlimiter_engage_resume_check_tbl:       DB  06Bh,0A9h,02Bh,062h ; 6DEC
tbl_knock244_a:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6DF0
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h ; 6DFA
tbl_knock244_b:       DB  000h,000h,000h,000h,000h,000h,000h,000h ; 6E04
                DB  000h,000h,000h,000h,000h,000h ; 6E0C
int_serial_rx_tbl:       DB  000h,000h,000h,000h,000h,000h,09Dh,003h ; 6E12
                DB  09Ch,003h,09Bh,003h,000h,004h,000h,004h ; 6E1A
                DB  000h,004h,000h,004h,000h,004h,0ACh,003h ; 6E22
                DB  0ADh,003h,0AEh,003h,0AFh,003h,0B0h,003h ; 6E2A
                DB  0B1h,003h,0B2h,003h,0B3h,003h,0D0h,003h ; 6E32
                DB  0C8h,003h,0BBh,000h,0C9h,003h,0A0h,003h ; 6E3A
                DB  0DAh,000h,000h,004h,0DBh,000h,0A1h,003h ; 6E42
                DB  0CEh,003h,0D7h,000h,0A1h,002h,0CEh,003h ; 6E4A
                DB  000h,004h,000h,004h,000h,004h,05Bh,001h ; 6E52
                DB  000h,004h,005h,003h,000h,004h,09Fh,003h ; 6E5A
                DB  09Eh,003h,05Bh,003h,046h,002h,0A9h,003h ; 6E62
                DB  09Dh,000h,0AAh,003h,09Fh,002h,09Eh,002h ; 6E6A
                DB  000h,004h,000h,004h,000h,004h,000h,004h ; 6E72
                DB  000h,004h,000h,004h,000h,004h,000h,004h ; 6E7A
                DB  0AEh,001h,0AFh,001h,0ADh,001h,0B6h,001h ; 6E82
                DB  0B7h,001h,0B5h,001h,0ABh,003h,000h,004h ; 6E8A
                DB  000h,004h,000h,004h,000h,004h,024h,003h ; 6E92
                DB  025h,003h,026h,003h,027h,003h,028h,003h ; 6E9A
                DB  029h,003h,02Ah,003h,02Bh,003h,02Ch,003h ; 6EA2
                DB  02Dh,003h,02Eh,003h,02Fh,003h,030h,003h ; 6EAA
                DB  031h,003h,032h,003h,033h,003h,034h,003h ; 6EB2
                DB  035h,003h,036h,003h,037h,003h,038h,003h ; 6EBA
                DB  039h,003h,03Ah,003h,03Bh,003h,03Ch,003h ; 6EC2
                DB  03Dh,003h,03Eh,003h,03Fh,003h,040h,003h ; 6ECA
                DB  041h,003h,042h,003h,043h,003h,044h,003h ; 6ED2
                DB  045h,003h,046h,003h,047h,003h,048h,003h ; 6EDA
                DB  049h,003h,04Ah,003h,04Bh,003h,04Ch,003h ; 6EE2
                DB  04Dh,003h,04Eh,003h,04Fh,003h,050h,003h ; 6EEA
                DB  051h,003h,052h,003h,053h,003h,000h,004h ; 6EF2
                DB  000h,004h,000h,004h,000h,004h,000h,004h ; 6EFA
                DB  000h,004h,000h,004h,000h,004h,0A4h,003h ; 6F02
                DB  0A5h,003h,0A6h,003h,0A7h,003h,0A8h,003h ; 6F0A
                DB  000h,004h,000h,004h,000h,004h,02Dh,02Dh ; 6F12
                DB  007h,006h,0FFh,0FFh,0FFh,078h,019h,019h ; 6F1A
                DB  019h,0B3h ; 6F22
dtc_scan_new_code_tbl:       DB  00Bh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh ; 6F24
                DB  0FFh,0FFh,0FFh,0FFh,02Dh,02Dh,0FFh,02Dh ; 6F2C
                DB  02Dh,006h,02Dh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F34
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6F3C
                DB  0FFh,02Dh,02Dh,007h,006h,0FFh,0FFh,0FFh ; 6F44
                DB  078h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh ; 6F4C
                DB  0B3h ; 6F54
cfgvariant_index_lookup_tbl:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah ; 6F55
                DB  00Bh,00Ch,00Ch,00Dh,00Eh,011h,000h,013h ; 6F5D
                DB  014h,015h,016h,017h,018h,01Eh,01Fh,000h ; 6F65
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h ; 6F6D
                DB  000h,004h,008h,009h,00Fh,01Eh,01Fh,010h ; 6F75
                DB  013h,004h,008h,009h,000h,000h,000h,000h ; 6F7D
                DB  01Dh ; 6F85
knock_324_bit_store_tbl:       DB  010h,093h,003h ; 6F86
crank_edge_flag_store_tbl:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh ; 6F89
                DB  000h,0FFh,000h,0FFh ; 6F91
tbl_diag_snapshot_data2:       DB  0FFh,078h,019h,019h,019h ; 6F95
tbl_crank_sync_pattern:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FEh,0FFh,0FFh ; 6F9A
                DB  0FFh,0FFh,0FFh,0FDh,0FFh,0FFh,0FFh,0FFh ; 6FA2
                DB  0FFh,0FEh,0FFh,0FFh,0FFh,0FFh,0FFh,0FDh ; 6FAA
tbl_crank_tooth_pattern:       DB  007h,008h,009h,00Ah,00Bh,000h,001h,002h,003h,004h ; 6FB2
                DB  005h,006h,007h,008h,009h,00Ah,00Bh,000h,001h,002h ; 6FBC
                DB  003h,004h,005h,006h,007h,008h,009h,00Ah,00Bh,000h ; 6FC6
fueltbl_sanitize_advance_tbl:       DB  000h,000h,077h,022h,0EEh,044h,077h,044h ; 6FD0
                DB  0DDh,088h,0FFh,0FFh,0EEh,088h,077h,088h ; 6FD8
                DB  0BBh,011h,0BBh,022h,0FFh,0FFh,0BBh,044h ; 6FE0
                DB  0DDh,011h,0DDh,022h,0EEh,011h,000h,000h ; 6FE8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FF0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 6FF8
newval_table3_call_tbl_3:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,000h ; 7000
crank_edge_flag_store_tbl_2:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,000h ; 700A
Scaler_RpmAxis_Lo:       DB  000h,00Dh,01Ah,02Dh,040h,050h,05Ah,063h,076h,080h ; 7014
                DB  083h,08Ah,093h,0ADh,0C0h,0C8h,0D0h,0E0h,0F0h,000h ; 701E
rpm_avg_store_tbl:       DB  000h,011h,01Ch,02Bh,039h,047h,055h,064h,072h,080h ; 7028
                DB  087h,08Eh,095h,09Ch,0ABh,0B9h,0C7h,0D5h,0E4h,000h ; 7032
crank_edge_flag_store_tbl_3:       DB  000h,00Dh,01Ah,02Dh,040h,050h,05Ah,063h,076h,080h ; 703C
                DB  083h,08Ah,093h,0ADh,0C0h,0C8h,0D0h,0E0h,0F0h,000h ; 7046
fuelmap_base_lookup_tbl_2:       DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0AAh ; 7050
                DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0ACh ; 705A
                DB  044h,0B9h,0C2h,09Dh,0A3h,0A9h,0AFh,0BDh,0CDh,0B0h ; 7064
                DB  047h,0BBh,0C5h,0A2h,0A5h,0ABh,0B0h,0BEh,0CEh,0B2h ; 706E
                DB  048h,0C1h,0CAh,0A4h,0A9h,0AFh,0B4h,0C2h,0D2h,0B6h ; 7078
                DB  048h,0CAh,0D2h,0AAh,0AFh,0B5h,0BCh,0C4h,0D2h,0B6h ; 7082
                DB  048h,0CDh,0D2h,0A9h,0AEh,0B5h,0BBh,0C8h,0D9h,0BBh ; 708C
                DB  048h,0CAh,0CFh,0A6h,0ADh,0B2h,0B8h,0C5h,0D4h,0B6h ; 7096
                DB  04Ah,0D8h,0DCh,0B0h,0B8h,0BEh,0C2h,0CFh,0EAh,0C8h ; 70A0
                DB  049h,0D0h,0D4h,0A9h,0B0h,0B6h,0BBh,0C9h,0D9h,0BBh ; 70AA
                DB  049h,0CFh,0D4h,0A8h,0B0h,0B5h,0BBh,0C9h,0D9h,0BBh ; 70B4
                DB  049h,0D2h,0D5h,0A9h,0AFh,0B5h,0BBh,0C8h,0D7h,0B9h ; 70BE
                DB  04Dh,0DDh,0DFh,0B1h,0B7h,0BCh,0C1h,0CCh,0DCh,0BEh ; 70C8
                DB  04Ah,0C4h,0D1h,0ACh,0B6h,0BBh,0C1h,0CCh,0DCh,0BEh ; 70D2
                DB  050h,0E3h,0EBh,0BFh,0C8h,0CFh,0D5h,0E6h,0F6h,0E8h ; 70DC
                DB  070h,0F9h,0FDh,0CEh,0D6h,0DBh,0E1h,0ECh,0FCh,0EFh ; 70E6
                DB  078h,0FEh,0FFh,0CFh,0D8h,0DCh,0E0h,0EFh,0FFh,0F1h ; 70F0
                DB  050h,0DEh,0E5h,0BCh,0C6h,0C6h,0CFh,0DDh,0ECh,0E0h ; 70FA
                DB  050h,0DEh,0E5h,0BCh,0C6h,0C6h,0CFh,0DDh,0ECh,0E0h ; 7104
                DB  050h,0DEh,0E3h,0BCh,0C6h,0C6h,0CFh,0DDh,0ECh,0E0h ; 710E
                DB  001h,002h,003h,005h,006h,007h,008h,008h,008h,00Ah ; 7118
fuelmap_base_lookup_tbl_3:       DB  028h,075h,08Ah,099h,0A2h,0ABh,09Ch,0A8h ; 7122
                DB  0BCh,0C8h,028h,075h,08Ah,099h,0A2h,0ABh ; 712A
                DB  09Ch ; 7132
fueltbl_range_check_tbl:       DB  0A8h,0BCh,0C8h,028h,075h,08Ah,099h,0A2h ; 7133
                DB  0ABh,09Ch,0A8h,0BCh,0C8h,028h,075h,08Ah ; 713B
                DB  099h,0A2h,0ABh,09Ch,0A8h,0BCh,0C8h,028h ; 7143
                DB  075h,08Ah,099h,0A2h,0ABh,09Ch,0A8h,0BCh ; 714B
                DB  0C8h,028h,075h,08Ah,099h,0A2h,0ABh,09Ch ; 7153
                DB  0A8h,0BCh,0C8h,04Dh,08Dh,0A4h,0B0h,0B5h ; 715B
                DB  0BFh,0ADh,0BBh,0CEh,0E2h,017h,078h,097h ; 7163
                DB  0A8h,0B0h,0BDh,0B0h,0BEh,0D5h,0E3h,016h ; 716B
                DB  077h,094h,0A6h,0B2h,0BCh,0ADh,0BDh,0CEh ; 7173
                DB  0DAh,014h,08Eh,0A7h,0B7h,0C2h,0CCh,0BDh ; 717B
                DB  0C9h,0D6h,0E0h,03Dh,08Eh,0A8h,0BBh,0C8h ; 7183
                DB  0D2h,0BFh,0CAh,0D7h,0E1h,001h,09Bh,0B3h ; 718B
                DB  0C4h,0D0h,0D5h,0C4h,0D2h,0E2h,0E5h,039h ; 7193
                DB  0A7h,0C1h,0D5h,0E0h,0E8h,0D5h,0E1h,0EAh ; 719B
                DB  0EDh,060h,0B2h,0CCh,0DEh,0E8h,0EBh,0D4h ; 71A3
                DB  0E2h,0EBh,0F5h,07Bh,0B8h,0D8h,0E5h,0EBh ; 71AB
                DB  0EEh,0D7h,0E3h,0F1h,0F7h,049h,0BBh,0D5h ; 71B3
                DB  0ECh,0F3h,0F3h,0DEh,0ECh,0F7h,0F8h,05Ch ; 71BB
                DB  0A1h,0C7h,0EAh,0F3h,0F4h,0DAh,0F1h,0F5h ; 71C3
                DB  0F8h,041h,08Fh,0B6h,0CFh,0DBh,0E8h,0CAh ; 71CB
                DB  0D8h,0DFh,0E9h,041h,08Fh,0B6h,0CFh,0DBh ; 71D3
                DB  0E8h,0CAh,0D8h,0DFh,0E9h,041h,08Fh,0B6h ; 71DB
                DB  0CFh,0DBh,0E8h,0CAh,0D8h,0DFh,0E9h,001h ; 71E3
                DB  003h,004h,005h,006h,007h,009h,009h,009h ; 71EB
                DB  009h ; 71F3
fuelmap_base_lookup_tbl_4:       DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0AAh ; 71F4
                DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0ACh ; 71FE
                DB  044h,0B9h,0C2h,09Dh,0A3h,0A9h,0AFh,0BDh,0CDh,0B0h ; 7208
                DB  047h,0BBh,0C5h,0A2h,0A5h,0ABh,0B0h,0BEh,0CEh,0B2h ; 7212
                DB  048h,0C1h,0CAh,0A4h,0A9h,0AFh,0B4h,0C2h,0D2h,0B6h ; 721C
                DB  048h,0CAh,0D2h,0AAh,0AFh,0B5h,0BCh,0C4h,0D2h,0B6h ; 7226
                DB  048h,0CDh,0D2h,0A9h,0AEh,0B5h,0BBh,0C8h,0D9h,0BBh ; 7230
                DB  048h,0CAh,0CFh,0A6h,0ADh,0B2h,0B8h,0C5h,0D4h,0B6h ; 723A
                DB  04Ah,0D8h,0DCh,0B0h,0B8h,0BEh,0C2h,0CFh,0EAh,0C8h ; 7244
                DB  049h,0D0h,0D4h,0A9h,0B0h,0B6h,0BBh,0C9h,0D9h,0BBh ; 724E
                DB  049h,0CFh,0D4h,0A8h,0B0h,0B5h,0BBh,0C9h,0D9h,0BBh ; 7258
                DB  001h,002h,003h,005h,006h,007h,008h,008h,008h,00Ah ; 7262
fuelmap_base_lookup_tbl_5:       DB  02Dh,07Ah,097h,0A2h,0ABh,0B1h,0BBh,0B5h,0C7h,0BCh ; 726C
                DB  02Dh,07Ah,097h,0A2h,0ABh,0B1h,0BBh,0B5h,0C7h,0BCh ; 7276
                DB  02Dh,07Ah,097h,0A2h,0ABh,0B1h,0BBh,0B5h,0C7h,0BCh ; 7280
                DB  030h,080h,098h,0A2h,0ACh,0B4h,0BEh,0B6h,0C6h,0BBh ; 728A
                DB  030h,08Bh,0A0h,0ABh,0B1h,0B9h,0C0h,0B9h,0C8h,0BDh ; 7294
                DB  030h,091h,0A8h,0B4h,0B8h,0C1h,0C8h,0BFh,0CEh,0C3h ; 729E
                DB  030h,095h,0ABh,0B7h,0C0h,0C6h,0CDh,0C4h,0D3h,0C8h ; 72A8
                DB  030h,091h,0A9h,0B8h,0C0h,0C7h,0D0h,0C7h,0D7h,0CDh ; 72B2
                DB  03Ah,09Ah,0B1h,0BDh,0C5h,0CBh,0D3h,0C9h,0D9h,0CEh ; 72BC
                DB  03Ah,094h,0ADh,0BAh,0C4h,0C7h,0D0h,0C7h,0D6h,0CBh ; 72C6
                DB  03Ah,093h,0ABh,0B8h,0C4h,0C7h,0D0h,0C7h,0D7h,0CCh ; 72D0
                DB  001h,003h,004h,005h,006h,007h,008h,009h,009h,00Ah ; 72DA
mode_flags_pack4_tbl:       DB  066h,066h,066h,05Eh,044h,030h,020h,00Fh ; 72E4
                DB  000h,000h,066h,066h,066h,05Eh,044h,030h ; 72EC
                DB  020h,00Fh,000h,000h,066h,066h ; 72F4
vss_calc_skip_tbl:       DB  066h,05Eh,044h,030h,020h,00Fh,000h,000h ; 72FA
                DB  066h,066h,066h,05Eh,044h,030h,020h,00Fh ; 7302
                DB  000h,000h,06Fh,06Fh,06Fh,069h,061h,049h ; 730A
                DB  031h,022h,015h,011h,087h,087h,087h,07Dh ; 7312
                DB  073h,059h,040h,033h,024h,020h,08Fh,08Fh ; 731A
                DB  08Fh,085h,079h,060h,047h,03Bh,02Dh,029h ; 7322
                DB  097h,097h,097h,08Bh,07Dh,066h,04Bh,043h ; 732A
                DB  035h,031h,09Eh,09Eh,09Eh,091h,085h,071h ; 7332
                DB  056h,04Eh,042h,03Eh,0A2h,0A2h,0A2h,095h ; 733A
                DB  089h,075h,05Dh,053h,046h,041h,0A6h,0A6h ; 7342
                DB  0A6h,098h,08Ch,078h,060h,055h,048h,044h ; 734A
                DB  0AFh,0AFh,0AFh,0A1h,093h,07Eh,067h,05Bh ; 7352
                DB  04Eh,04Ah,0B7h,0B7h,0B7h,0AAh,09Ah,086h ; 735A
                DB  070h,063h,054h,050h,0C7h,0C7h,0C7h,0BEh ; 7362
                DB  0B3h,0A7h,097h,088h,070h,070h,0C7h,0C7h ; 736A
                DB  0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,07Ch,07Ch ; 7372
                DB  0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh ; 737A
                DB  07Ch,07Ch,0C7h,0C7h,0C7h,0BEh,0B3h,0ABh ; 7382
                DB  09Ah,08Dh,084h,084h,0C7h,0C7h,0C7h,0BEh ; 738A
                DB  0B3h,0ABh,09Ah,08Dh,084h,084h,0C7h,0C7h ; 7392
                DB  0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 739A
                DB  0C8h,0C8h,0C8h,0BDh,0B3h,0ABh,09Ah,08Dh ; 73A2
                DB  084h,084h ; 73AA
mode_flags_pack4_tbl_2:       DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,010h,000h,000h ; 73AC
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,010h,000h,000h ; 73B6
                DB  078h,078h,078h,071h,065h,04Ch,031h,022h,015h,011h ; 73C0
                DB  095h,095h,095h,089h,07Ch,067h,04Ch,041h,033h,02Fh ; 73CA
                DB  0A2h,0A2h,0A2h,095h,089h,077h,061h,055h,049h,045h ; 73D4
                DB  0B7h,0B7h,0B7h,0A9h,09Ah,08Bh,078h,064h,051h,04Dh ; 73DE
                DB  0C5h,0C5h,0C5h,0B8h,0ADh,0A5h,099h,07Ah,062h,05Eh ; 73E8
                DB  0C7h,0C7h,0C7h,0BAh,0B3h,0ABh,0A1h,08Dh,073h,073h ; 73F2
                DB  0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,07Ch,07Ch ; 73FC
                DB  0C7h,0C7h,0C7h,0BEh,0AFh,0ABh,09Ah,08Dh,07Ch,07Ch ; 7406
                DB  0C8h,0C8h,0C8h,0C1h,0B2h,0AEh,09Ah,08Dh,080h,080h ; 7410
                DB  0C8h,0C8h,0C8h,0C4h,0B5h,0B1h,09Ah,08Dh,084h,084h ; 741A
                DB  0C8h,0C8h,0C8h,0C3h,0B4h,0AFh,09Ah,08Dh,084h,084h ; 7424
                DB  0C8h,0C8h,0C8h,0C0h,0B4h,0ADh,09Ah,08Dh,084h,084h ; 742E
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 7438
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 7442
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 744C
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 7456
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 7460
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h ; 746A
mode_flags_pack4_tbl_3:       DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h ; 7474
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h ; 747E
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h ; 7488
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h ; 7492
                DB  06Fh,06Fh,06Fh,06Fh,065h,04Ch,031h,022h,015h,011h ; 749C
                DB  087h,087h,087h,07Dh,073h,05Ch,040h,033h,024h,020h ; 74A6
                DB  08Fh,08Fh,08Fh,085h,079h,063h,047h,03Bh,02Dh,029h ; 74B0
                DB  097h,097h,097h,08Bh,07Dh,069h,04Eh,043h,035h,031h ; 74BA
                DB  09Eh,09Eh,09Eh,091h,085h,072h,05Ah,04Fh,042h,03Eh ; 74C4
                DB  0A2h,0A2h,0A2h,095h,089h,077h,061h,055h,049h,045h ; 74CE
                DB  0A6h,0A6h,0A6h,098h,08Ch,07Bh,065h,058h,04Ah,047h ; 74D8
mode_flags_pack4_tbl_4:       DB  05Ah,05Ah,05Ah,05Ah,047h,03Bh,02Ch,01Dh ; 74E2
                DB  015h,011h,05Ah,05Ah,05Ah,05Ah,049h,03Fh ; 74EA
                DB  034h,024h,01Ch ; 74F2
freezeframe_flag_next_tbl:       DB  018h,05Ah,05Ah,05Ah,05Ah,04Bh,043h,03Bh ; 74F5
                DB  02Ch,023h,01Fh,05Ah,05Ah,05Ah,05Ah,04Fh ; 74FD
                DB  047h,041h,033h,02Ah,026h,06Fh,06Fh,06Fh ; 7505
                DB  06Fh,061h,056h,04Dh,041h,039h,035h,08Ch ; 750D
                DB  08Ch,08Ch,07Bh,069h,060h,059h,04Dh,046h ; 7515
                DB  042h,097h,097h,097h,081h,06Fh,068h,062h ; 751D
                DB  057h,050h,04Ch,0A1h,0A1h,0A1h,087h,073h ; 7525
                DB  06Eh,067h,05Eh,055h,051h,0A9h,0A9h,0A9h ; 752D
                DB  08Ch,077h,071h,06Bh,064h,05Ah,056h,0ABh ; 7535
                DB  0ABh,0ABh,08Eh,07Ah,074h,06Eh,068h,05Eh ; 753D
                DB  05Ah,0ACh,0ACh,0ACh,091h,07Eh,078h,072h ; 7545
                DB  06Ch,062h,05Eh ; 754D
ve_result_flag_store_tbl:       DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h ; 7550
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h ; 755A
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h ; 7564
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 756E
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7578
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7582
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 758C
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7596
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75A0
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75AA
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75B4
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75BE
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75C8
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75D2
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 75DC
                DB  086h,086h,086h,086h,097h,097h,097h,097h,097h,097h ; 75E6
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 75F0
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 75FA
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 7604
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 760E
ve_result_flag_store_tbl_2:       DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h ; 7618
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h ; 7622
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h ; 762C
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7636
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7640
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 764A
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7654
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 765E
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h ; 7668
                DB  086h,086h,086h,086h,097h,097h,097h,097h,097h,097h ; 7672
                DB  086h,086h,086h,086h,097h,097h,097h,097h,097h,097h ; 767C
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 7686
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 7690
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 769A
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 76A4
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 76AE
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 76B8
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 76C2
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 76CC
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h ; 76D6
crank_edge_flag_store_tbl_4:       DB  000h,000h,000h,000h,000h,000h,000h,000h ; 76E0
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 76E8
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 76F0
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 76F8
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7700
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7708
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7710
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7718
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7720
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7728
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7730
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7738
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7740
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7748
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7750
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7758
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7760
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7768
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7770
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7778
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7780
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7788
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7790
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 7798
                DB  000h,000h,000h,000h,000h,000h,000h,000h ; 77A0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77A8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77B0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77B8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77C0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77C8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77D0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77D8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77E0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77E8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77F0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 77F8
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7800
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh ; 7808
                DB  0FFh ; 7810
vcal3_leanprotect_ratelimit_store_carry_ram22d_bit7:     MB      off(0022dh).7, C       ; 7811 0 208 180 C42D3F
                LB      A, #046h               ; 7814 0 208 180 7746
                JBS     off(0022fh).7, vcal3_leanprotect_ratelimit_cmp_acc_27 ; 7816 0 208 180 EF2F02
                LB      A, #04bh               ; 7819 0 208 180 774B
vcal3_leanprotect_ratelimit_cmp_acc_27:     CMPB    A, r0                  ; 781B 0 208 180 48
                MB      off(0022fh).7, C       ; 781C 0 208 180 C42F3F
                J       vcal3_leanprotect_ratelimit_load_imm             ; 781F 0 208 180 03E338
vcal3_leanprotect_ratelimit_if_ram22f_bit7_set:     JBS     off(0022fh).7, vcal3_leanprotect_ratelimit_goto_3ae5 ; 7822 0 208 180 EF2F03
                J       vcal3_leanprotect_ratelimit_clear_r0             ; 7825 0 208 180 037D3B
vcal3_leanprotect_ratelimit_goto_3ae5:     J       vcal3_leanprotect_ratelimit_goto_3cb2             ; 7828 0 208 180 03E53A
battery_voltage_check_if_ge_goto_782e:     JGE     battery_voltage_check_store_ram0e0             ; 782B 0 208 180 CD01
                VCAL    6                      ; 782D 0 208 180 16
battery_voltage_check_store_ram0e0:     STB     A, 0e0h                ; 782E 0 208 180 D5E0
                MOVB    r0, 0dfh               ; 7830 0 208 180 C5DF48
                J       battery_voltage_check_load_imm             ; 7833 0 208 180 03382F
knock_324_bit_store_xorb_pswh:     XORB    PSWH, #080h            ; 7836 0 208 180 A2F080
                ROLB    A                      ; 7839 0 208 180 33
                MB      C, P0.4                ; 783A 0 208 180 C5202C
                XORB    PSWH, #080h            ; 783D 0 208 180 A2F080
                J       knock_324_bit_store_rolb_acc_2             ; 7840 0 208 180 03CC51
injtimer_finalize_start_add_x1:     ADD     X1, #00006h            ; 7843 0 100 280 90800600
                MOVB    r7, off(0016dh)        ; 7847 0 100 280 C46D4F
                MOVB    r6, off(001ffh)        ; 784A 0 100 280 C4FF4E
                MOVB    r1, off(0016ch)        ; 784D 0 100 280 C46C49
injtimer_finalize_start_load_ram132:     LB      A, off(00132h)         ; 7850 0 100 280 F432
                CMPCB   A, 00001h[X1]          ; 7852 0 100 280 90AF0100
                JGE     injtimer_finalize_start_call_knockretard_helper             ; 7856 0 100 280 CD05
                MOVB    r7, r6                 ; 7858 0 100 280 264F
                MOVB    r6, r1                 ; 785A 0 100 280 214E
                INC     X1                     ; 785C 0 100 280 70
injtimer_finalize_start_call_knockretard_helper:     CAL     knockretard_helper             ; 785D 0 100 280 322158
                J       injtimer_finalize_start_store_ram165             ; 7860 0 100 280 03D61E
injtimer_finalize_start_addb_acc:     ADDB    A, off(0016fh)         ; 7863 0 100 280 876F
                STB     A, r7                  ; 7865 0 100 280 8F
                MOVB    r6, off(0016ah)        ; 7866 0 100 280 C46A4E
                LCB     A, [X1]                ; 7869 0 100 280 90AA
                STB     A, r1                  ; 786B 0 100 280 89
                LCB     A, 00002h[X1]          ; 786C 0 100 280 90AB0200
                STB     A, r0                  ; 7870 0 100 280 88
                LB      A, off(00132h)         ; 7871 0 100 280 F432
                CAL     Cranking_sub_cmp_acc             ; 7873 0 100 280 329F78
                J       injtimer_finalize_start_store_ram165             ; 7876 0 100 280 03D61E
injtimer_finalize_start_load_r7:     MOVB    r7, off(0016bh)        ; 7879 0 100 280 C46B4F
                MOVB    r6, off(001feh)        ; 787C 0 100 280 C4FE4E
                MOVB    r1, off(0016ah)        ; 787F 0 100 280 C46A49
                SJ      injtimer_finalize_start_load_ram132             ; 7882 0 100 280 CBCC
knockwindow_next_table_load_ram0d9_5:     LB      A, 0d9h                ; 7884 0 208 180 F5D9
                STB     A, r2                  ; 7886 0 208 180 8A
                MOV     X1, #knockwindow_next_table_tbl_21          ; 7887 0 208 180 60BD78
                CAL     table_interp_lookup             ; 788A 0 208 180 323958
                STB     A, (001feh-00180h)[USP] ; 788D 0 208 180 D37E
                LB      A, r2                  ; 788F 0 208 180 7A
                MOV     X1, #knockwindow_next_table_tbl_22          ; 7890 0 208 180 60CB78
                CAL     table_interp_lookup             ; 7893 0 208 180 323958
                STB     A, (001ffh-00180h)[USP] ; 7896 0 208 180 D37F
                VCAL    3                      ; 7898 0 208 180 13
                LB      A, 0d9h                ; 7899 0 208 180 F5D9
                STB     A, r2                  ; 789B 0 208 180 8A
                J       knockwindow_next_table_load_x1             ; 789C 0 208 180 038646
Cranking_sub_cmp_acc:     CMPB    A, r1                  ; 789F 0 100 280 49
                JLE     Cranking_sub_cmp_acc_2             ; 78A0 0 100 280 CF01
                LB      A, r1                  ; 78A2 0 100 280 79
Cranking_sub_cmp_acc_2:     CMPB    A, r0                  ; 78A3 0 100 280 48
                JGE     Cranking_sub_xchgb_acc             ; 78A4 0 100 280 CD01
                LB      A, r0                  ; 78A6 0 100 280 78
Cranking_sub_xchgb_acc:     XCHGB   A, r0                  ; 78A7 0 100 280 2010
                SUBB    r0, A                  ; 78A9 0 100 280 20A1
                SUBB    r1, A                  ; 78AB 0 100 280 21A1
                LB      A, r7                  ; 78AD 0 100 280 7F
                J       table_interp_delta_calc             ; 78AE 0 100 280 035558
injtimer_finalize_start_tbl:       DB  0D0h,064h,063h,0D0h,051h,050h,0D0h,064h ; 78B1
                DB  063h,0D0h,051h,050h ; 78B9
knockwindow_next_table_tbl_21:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h ; 78BD
                DB  044h,042h,028h,041h,000h,040h ; 78C5
knockwindow_next_table_tbl_22:       DB  0FFh,040h,000h,040h,000h,040h,000h,040h ; 78CB
                DB  000h,040h,000h,040h,000h,040h ; 78D3
idle_state_defaults_cmp_ram0da:     CMPB    0dah, #04dh            ; 78D9 0 208 180 C5DAC04D
                JGT     idle_state_defaults_orb_pswh             ; 78DD 0 208 180 C804
                LB      A, off(002efh)         ; 78DF 0 208 180 F4EF
                SJ      idle_stage_c0_load_if_ne_goto_78f2             ; 78E1 0 208 180 CB07
idle_state_defaults_orb_pswh:     ORB     PSWH, #040h            ; 78E3 0 208 180 A2E040
idle_stage_c0_load_load_ram2ef:     MOVB    off(002efh), #050h     ; 78E6 0 208 180 C4EF9850
idle_stage_c0_load_if_ne_goto_78f2:     JNE     idle_stage_c0_load_goto_gio_fuelpump_dispatch             ; 78EA 0 208 180 CE06
                RB      off(00219h).0          ; 78EC 0 208 180 C41908
                SB      off(00223h).1          ; 78EF 0 208 180 C42319
idle_stage_c0_load_goto_gio_fuelpump_dispatch:     J       gio_fuelpump_dispatch             ; 78F2 0 208 180 03764B
idle_helper2_call1_cmp_stk:     CMPB    (001eah-00180h)[USP], #004h ; 78F5 1 208 180 C36AC004
                JGE     idle_helper2_call1_call_idle_helper2             ; 78F9 1 208 180 CD03
                L       A, #012c0h             ; 78FB 1 208 180 67C012
idle_helper2_call1_call_idle_helper2:     CAL     idle_helper2             ; 78FE 1 208 180 32F25A
                J       idle_helper2_call1_xchg_acc             ; 7901 1 208 180 032F2D
Cranking_load_x1:     MOV     X1, #Cranking_tbl_3          ; 7904 0 100 280 602379
                LB      A, 0d9h                ; 7907 0 100 280 F5D9
                VCAL    1                      ; 7909 0 100 280 11
                STB     A, r2                  ; 790A 0 100 280 8A
                MOV     X1, #Cranking_tbl_2          ; 790B 0 100 280 601F79
                LB      A, 0d9h                ; 790E 0 100 280 F5D9
                VCAL    1                      ; 7910 0 100 280 11
                MOVB    r7, #080h              ; 7911 0 100 280 9F80
                MOVB    r0, r2                 ; 7913 0 100 280 2248
                MOVB    r1, #030h              ; 7915 0 100 280 9930
                LB      A, 0c5h                ; 7917 0 100 280 F5C5
                CAL     Cranking_sub_cmp_acc             ; 7919 0 100 280 329F78
                J       Cranking_store_ram164             ; 791C 0 100 280 03DE14
Cranking_tbl_2:       DB  0FFh,05Ah,000h,05Ah ; 791F
Cranking_tbl_3:       DB  0FFh,012h,000h,012h ; 7923
idle_pid_output_store_store_r0:     STB     A, r0                  ; 7927 0 208 180 88
                CLR     A                      ; 7928 1 208 180 F9
                LB      A, #080h               ; 7929 0 208 180 7780
                JBS     off(00216h).3, idle_pid_output_store_load_acc ; 792B 0 208 180 EB1607
                LB      A, off(00251h)         ; 792E 0 208 180 F451
                LCB     A, idle_pid_output_store_tbl[ACC]       ; 7930 0 208 180 B506AB4D79
idle_pid_output_store_load_acc:     L       A, ACC                 ; 7935 1 208 180 E506
                SWAP                           ; 7937 1 208 180 83
                MUL                            ; 7938 1 208 180 9035
                SLL     A                      ; 793A 1 208 180 53
                L       A, er1                 ; 793B 1 208 180 35
                ROL     A                      ; 793C 1 208 180 33
                JGE     idle_sub_result_store             ; 793D 1 208 180 CD03
                L       A, #0ffffh             ; 793F 1 208 180 67FFFF
idle_sub_result_store:     ST      A, er3                 ; 7942 1 208 180 8B
                J       idle_sub_result_store_load_ram2c3             ; 7943 1 208 180 03B832
idle_pid_output_store_load_ram0d5:     LB      A, 0d5h                ; 7946 0 208 180 F5D5
                VCAL    2                      ; 7948 0 208 180 12
                J       idle_pid_output_store_store_r0             ; 7949 0 208 180 032779
                DB  0FFh ; 794C
idle_pid_output_store_tbl:       DB  0FFh,0A0h,0A0h,093h,080h,080h ; 794D
knockretard_clear_state_if_ram235_bit3_set:     JBS     off(00235h).3, knockretard_clear_state_goto_0ded ; 7953 0 200 180 EB3506
                JBS     off(00218h).6, knockretard_clear_state_goto_0ded ; 7956 0 200 180 EE1803
                J       knockretard_clear_state_if_ram21d_bit4_set             ; 7959 0 200 180 03D00D
knockretard_clear_state_goto_0ded:     J       knockretard_clear_state_store_ram23e             ; 795C 0 200 180 03ED0D
o2_closedloop_gate1_load_carry_stk:     MB      C, (00235h-00280h)[USP].3 ; 795F 0 100 280 C3B52B
                JGE     o2_closedloop_gate1_load_ram11a             ; 7962 0 100 280 CD03
                J       o2_trim_gate_common             ; 7964 0 100 280 03C41B
o2_closedloop_gate1_load_ram11a:     L       A, off(0011ah)         ; 7967 1 100 280 E41A
                AND     A, #08075h             ; 7969 1 100 280 D67580
                J       o2_closedloop_gate1_if_ne_goto_o2_trim_gate_common             ; 796C 1 100 280 03711B
o2_trim_table_ptr_load_load_carry_stk:     MB      C, (00235h-00280h)[USP].3 ; 796F 1 100 280 C3B52B
                JGE     o2_trim_table_ptr_load_load_ram11a             ; 7972 1 100 280 CD03
                J       o2_trim_table_ptr_alt             ; 7974 1 100 280 03FF1B
o2_trim_table_ptr_load_load_ram11a:     L       A, off(0011ah)         ; 7977 1 100 280 E41A
                AND     A, #08061h             ; 7979 1 100 280 D66180
                J       o2_trim_table_ptr_load_if_ne_goto_o2_trim_table_ptr_alt             ; 797C 1 100 280 03F71B
o2_trim_alt_path_check_set_stk:     SB      (00235h-00280h)[USP].2 ; 797F 1 100 280 C3B51A
                SB      off(00125h).1          ; 7982 1 100 280 C42519
                J       o2_trim_alt_path_check_goto_o2_trim_clear_gate0_and_retu             ; 7985 1 100 280 033C1C
o2_trim_alt_path_check_set_stk_2:     SB      (00235h-00280h)[USP].2 ; 7988 1 100 280 C3B51A
                SB      off(00125h).1          ; 798B 1 100 280 C42519
                J       o2_trim_alt_path_check_load_ram1d3             ; 798E 1 100 280 03531C
injtimer_finalize_start_load_carry_stk:     MB      C, (00235h-00280h)[USP].3 ; 7991 0 100 280 C3B52B
                JLT     injtimer_finalize_start_goto_injtimer_gate_common             ; 7994 0 100 280 CA06
                JBS     off(00120h).6, injtimer_finalize_start_goto_injtimer_gate_common ; 7996 0 100 280 EE2003
                J       injtimer_finalize_start_cmp_ram0d9             ; 7999 0 100 280 03181F
injtimer_finalize_start_goto_injtimer_gate_common:     J       injtimer_gate_common             ; 799C 0 100 280 033A1F
crank_edge_flag_store_load_carry_stk:     MB      C, (00235h-00280h)[USP].3 ; 799F 0 100 280 C3B52B
                JLT     crank_edge_flag_store_goto_244c             ; 79A2 0 100 280 CA06
                JBS     off(0011ah).0, crank_edge_flag_store_goto_244c ; 79A4 0 100 280 E81A03
                J       crank_edge_flag_store_if_ram11d_bit2_set             ; 79A7 0 100 280 033F24
crank_edge_flag_store_goto_244c:     J       crank_edge_flag_store_if_ram125_bit2_clr             ; 79AA 0 100 280 034C24
ram_clear_loop1_body_load_dp:     MOV     DP, #0031dh            ; 79AD 1 208 ??? 621D03
                LCB     A, boot_completion_helper_tbl_8            ; 79B0 1 208 ??? 909DF160
                JNE     cfgvariant_check_bit0             ; 79B4 1 208 ??? CE04
                CLRB    [DP]                   ; 79B6 1 208 ??? C215
                SJ      cfgvariant_set_bit0_from_2edh_3_goto_7a90             ; 79B8 1 208 ??? CB0F
cfgvariant_check_bit0:     MB      C, [DP].0              ; 79BA 1 208 ??? C228
                JGE     cfgvariant_set_bit0_from_2edh_3             ; 79BC 1 208 ??? CD06
                JBR     off(00235h).1, cfgvariant_set_bit0_from_2edh_3_goto_7a90 ; 79BE 1 208 ??? D93508
                JBR     off(00235h).2, cfgvariant_set_bit0_from_2edh_3_goto_7a90 ; 79C1 1 208 ??? DA3505
cfgvariant_set_bit0_from_2edh_3:     MB      C, off(00235h).3       ; 79C4 1 208 ??? C4352B
                MB      [DP].0, C              ; 79C7 1 208 ??? C238
cfgvariant_set_bit0_from_2edh_3_goto_7a90:     J       cfgvariant_set_bit0_from_2edh_3_if_ram232_bit4_clr             ; 79C9 1 208 ??? 03907A
vcal_3_clear_ram235_bit2:     RB      off(00235h).2          ; 79CC 0 208 180 C4350A
                RB      off(00235h).1          ; 79CF 0 208 180 C43509
                RB      off(00235h).3          ; 79D2 0 208 180 C4350B
                CAL     cfgvariant_check_320h_bit7_sub_clear_acc             ; 79D5 0 208 180 32E35E
                J       vcal_3_clear_ram232_bit2             ; 79D8 0 208 180 035D29
sensor_bank_ect_check_if_ram230_bit3_clr:     JBR     off(00230h).3, sensor_bank_ect_check_load_imm ; 79DB 0 208 180 DB3003
                J       sensor_bank_ect_check_load_carry_pswl_bit4             ; 79DE 0 208 180 032243
sensor_bank_ect_check_load_imm:     LB      A, #057h               ; 79E1 0 208 180 7757
                CMPB    A, 0d9h                ; 79E3 0 208 180 C5D9C2
                MB      off(00235h).1, C       ; 79E6 0 208 180 C43539
                SC                             ; 79E9 0 208 180 85
                J       sensor_bank_ect_check_store_carry_ram234_bit6             ; 79EA 0 208 180 032443
state_21a_7_dispatch2_if_ram235_bit3_set:     JBS     off(00235h).3, state_21a_7_dispatch2_goto_4efa ; 79ED 0 208 180 EB3506
                JBS     off(00218h).6, state_21a_7_dispatch2_goto_4efa ; 79F0 0 208 180 EE1803
                J       state_21a_7_dispatch2_load_x1             ; 79F3 0 208 180 03034F
state_21a_7_dispatch2_goto_4efa:     J       state_21a_7_dispatch2_goto_50fe             ; 79F6 0 208 180 03FA4E
dtc_active_confirm_if_ram227_bit1_clr:     JBR     off(00227h).1, dtc_active_confirm_goto_cfgvariant_apply_gate ; 79F9 0 208 180 D92718
                JBS     off(00210h).7, dtc_active_confirm_goto_cfgvariant_apply_gate ; 79FC 0 208 180 EF1015
                CMPB    r7, #005h              ; 79FF 0 208 180 27C005
                JNE     dtc_active_confirm_goto_cfgvariant_apply_gate             ; 7A02 0 208 180 CE10
                SB      off(00235h).3          ; 7A04 0 208 180 C4351B
                MOV     DP, #0031dh            ; 7A07 0 208 180 621D03
                MB      C, [DP].0              ; 7A0A 0 208 180 C228
                JGE     dtc_active_confirm_goto_5410             ; 7A0C 0 208 180 CD03
                JBS     off(00235h).1, dtc_active_confirm_goto_cfgvariant_apply_gate ; 7A0E 0 208 180 E93503
dtc_active_confirm_goto_5410:     J       dtc_debounce2_check_goto_7a1b             ; 7A11 0 208 180 031054
dtc_active_confirm_goto_cfgvariant_apply_gate:     J       cfgvariant_apply_gate             ; 7A14 0 208 180 03C253
                DB  000h,000h,000h,000h ; 7A17
dtc_debounce2_check_load_dp:     MOV     DP, #0031dh            ; 7A1B 0 208 180 621D03
                JBS     off(00227h).1, dtc_debounce2_check_load_r0 ; 7A1E 0 208 180 E92705
                RB      off(00235h).3          ; 7A21 0 208 180 C4350B
                CLRB    [DP]                   ; 7A24 0 208 180 C215
dtc_debounce2_check_load_r0:     MOVB    r0, [DP]               ; 7A26 0 208 180 C248
                MOVB    r1, r0                 ; 7A28 0 208 180 2049
                MOV     DP, #00322h            ; 7A2A 0 208 180 622203
                J       dtc_debounce2_check_load_x1             ; 7A2D 0 208 180 031354
calchecksum_loop_dec_dp:     DEC     DP                     ; 7A30 0 208 180 82
                LB      A, [DP]                ; 7A31 0 208 180 F2
                ANDB    A, #0feh               ; 7A32 0 208 180 D6FE
                JNE     calchecksum_loop_goto_selftest_fail_043_checksum             ; 7A34 0 208 180 CE07
                INC     DP                     ; 7A36 0 208 180 72
                LB      A, [DP]                ; 7A37 0 208 180 F2
                ANDB    A, #002h               ; 7A38 0 208 180 D602
                J       calchecksum_loop_if_ne_goto_selftest_fail_043_checksum             ; 7A3A 0 208 180 033554
calchecksum_loop_goto_selftest_fail_043_checksum:     J       selftest_fail_043_checksum             ; 7A3D 0 208 180 035754
freezeframe_decode_start_load_carry_ram235_bit3:     MB      C, off(00235h).3       ; 7A40 1 208 180 C4352B
                ADC     A, #0ffffh             ; 7A43 1 208 180 96FFFF
                J       freezeframe_flag_218_7             ; 7A46 1 208 180 036454
freezeframe_flag_22b_4_set_carry:     SC                             ; 7A49 1 208 180 85
                JBS     off(00235h).3, freezeframe_flag_22b_4_goto_freezeframe_flag_next ; 7A4A 1 208 180 EB3505
                L       A, off(00212h)         ; 7A4D 1 208 180 E412
                J       freezeframe_flag_22b_4_if_ne_goto_freezeframe_flag_next             ; 7A4F 1 208 180 039F54
freezeframe_flag_22b_4_goto_freezeframe_flag_next:     J       freezeframe_flag_next             ; 7A52 1 208 180 03A954
freezeframe_flag_next_set_carry:     SC                             ; 7A55 1 208 180 85
                JBS     off(00235h).3, freezeframe_flag_next_goto_54b9 ; 7A56 1 208 180 EB3505
                L       A, off(00212h)         ; 7A59 1 208 180 E412
                J       freezeframe_flag_next_if_ne_goto_54b9             ; 7A5B 1 208 180 03AF54
freezeframe_flag_next_goto_54b9:     J       freezeframe_flag_next_store_carry_ram234_bit7             ; 7A5E 1 208 180 03B954
cfgvariant_check_320h_bit7_sub_load_dp:     MOV     DP, #0031dh            ; 7A61 1 208 ??? 621D03
                CLRB    [DP]                   ; 7A64 1 208 ??? C215
                MOV     DP, #00356h            ; 7A66 1 208 ??? 625603
                J       cfgvariant_state_clear_loop             ; 7A69 1 208 ??? 03E75E
idle_helper2_call1_clear_acc:     CLRB    A                      ; 7A6C 0 208 180 FA
                JLT     idle_helper2_call1_if_ram20c_bit1_clr             ; 7A6D 0 208 180 CA03
                J       idle_target_store             ; 7A6F 0 208 180 03362D
idle_helper2_call1_if_ram20c_bit1_clr:     JBR     off(0020ch).1, idle_helper2_call1_goto_idle_step_store ; 7A72 0 208 180 D90C03
                J       idle_step_default             ; 7A75 0 208 180 03422D
idle_helper2_call1_goto_idle_step_store:     J       idle_step_store             ; 7A78 0 208 180 03442D
dtc_active_confirm_if_ne_goto_7a82:     JNE     dtc_active_confirm_goto_5410_2             ; 7A7B 0 208 180 CE05
                STB     A, 0f4h                ; 7A7D 0 208 180 D5F4
                J       dtc_active_confirm_if_ram227_bit1_clr             ; 7A7F 0 208 180 03F979
dtc_active_confirm_goto_5410_2:     J       dtc_debounce2_check_goto_7a1b             ; 7A82 0 208 180 031054
int_NMI_load_dp:     MOV     DP, #00007h            ; 7A85 1 208 ??? 620700
int_NMI_loop_dp:     JRNZ    DP, int_NMI_loop_dp         ; 7A88 1 208 ??? 30FE
                MOV     DP, #00005h            ; 7A8A 1 208 ??? 620500
                J       nmi_poll_p4_1             ; 7A8D 1 208 ??? 034E00
cfgvariant_set_bit0_from_2edh_3_if_ram232_bit4_clr:     JBR     off(00232h).4, cfgvariant_set_bit0_from_2edh_3_goto_cfgvariant_check_32 ; 7A90 1 208 ??? DC3203
                J       cfgvariant_set_bit0_from_2edh_3_if_ram232_bit5_clr             ; 7A93 1 208 ??? 03A226
cfgvariant_set_bit0_from_2edh_3_goto_cfgvariant_check_32:     J       cfgvariant_check_320h_bit7             ; 7A96 1 208 ??? 03CE26
injtimer_mul_final_load_ram158:     MOV     off(00158h), er1       ; 7A99 1 100 280 457C58
                LB      A, #05ah               ; 7A9C 0 100 280 775A
                JBS     off(00130h).6, dwell_rpm_hyst_check ; 7A9E 0 100 280 EE3002
                LB      A, #05dh               ; 7AA1 0 100 280 775D
dwell_rpm_hyst_check:     CMPB    A, off(00133h)         ; 7AA3 0 100 280 C733
                MB      off(00130h).6, C       ; 7AA5 0 100 280 C4303E
                J       dwell_rpm_hyst_check_if_ram125_bit4_set             ; 7AA8 0 100 280 03B71F
dwell_rpm_gate2_load_carry_ram130_bit6:     MB      C, off(00130h).6       ; 7AAB 0 100 280 C4302E
                XORB    PSWH, #080h            ; 7AAE 0 100 280 A2F080
                J       dwell_rpm_gate3             ; 7AB1 0 100 280 03DB1F
crank_sync_store_flag_andb_pswh:     ANDB    PSWH, #0feh            ; 7AB4 0 108 280 A2D0FE
                MOVB    off(0018eh), #077h     ; 7AB7 0 108 280 C48E9877
                J       crank_sync_store_flag_load_ram116             ; 7ABB 0 108 280 033D05
crank_sync_flag2_check_if_ne_goto_7ac7:     JNE     crank_sync_flag2_check_goto_0564             ; 7ABE 0 108 280 CE07
                LB      A, 0a2h                ; 7AC0 0 108 280 F5A2
                JNE     crank_sync_flag2_check_goto_0564             ; 7AC2 0 108 280 CE03
                SB      off(00128h).2          ; 7AC4 0 108 280 C4281A
crank_sync_flag2_check_goto_0564:     J       crank_sync_flag2_check_if_ram11f_bit7_set             ; 7AC7 0 108 280 036405
crank_sync_flag2_check_load_ram0a2:     LB      A, 0a2h                ; 7ACA 0 108 280 F5A2
                JEQ     crank_sync_flag2_check_goto_crank_cycle_dispatch2             ; 7ACC 0 108 280 C903
                J       crank_decode_exit             ; 7ACE 0 108 280 035F06
crank_sync_flag2_check_goto_crank_cycle_dispatch2:     J       crank_cycle_dispatch2             ; 7AD1 0 108 280 038405
crank_cycle_p4_gate_load_imm:     LB      A, #001h               ; 7AD4 0 108 280 7701
                CMPB    0f4h, #024h            ; 7AD6 0 108 280 C5F4C024
                JNE     crank_cycle_p4_gate_goto_crank_cycle_counter_check             ; 7ADA 0 108 280 CE03
                SB      off(0012ah).4          ; 7ADC 0 108 280 C42A1C
crank_cycle_p4_gate_goto_crank_cycle_counter_check:     J       crank_cycle_counter_check             ; 7ADF 0 108 280 03E606
crank_cycle_entry_gate_set_ram12a_bit2:     SB      off(0012ah).2          ; 7AE2 0 108 280 C42A1A
                L       A, 0f8h                ; 7AE5 1 108 280 E5F8
                ST      A, IE                  ; 7AE7 1 108 280 D51A
                J       crank_cycle_entry_gate_call_crank_edge_helper             ; 7AE9 1 108 280 033007
rpm_period_accum_load_tbl_x1:     L       A, 00360h[X1]          ; 7AEC 1 200 180 E06003
                JBS     off(00217h).7, rpm_period_accum_load_tbl_x1_2 ; 7AEF 1 200 180 EF1703
                J       rpm_period_overflow_check             ; 7AF2 1 200 180 037C07
rpm_period_accum_load_tbl_x1_2:     MOV     00360h[X1], #00001h    ; 7AF5 1 200 180 B06003980100
                J       rpm_period_accum             ; 7AFB 1 200 180 037E07
sensor_check_vcal3_load_dp_ind:     LB      A, [DP]                ; 7AFE 0 208 180 F2
                STB     A, 0dbh                ; 7AFF 0 208 180 D5DB
                RC                             ; 7B01 0 208 180 95
                JBS     off(00212h).3, sensor_check_gate1 ; 7B02 0 208 180 EB120E
                CMPB    (001b5h-00180h)[USP], #015h ; 7B05 0 208 180 C335C015
                JGT     sensor_check_gate1             ; 7B09 0 208 180 C808
                SC                             ; 7B0B 0 208 180 85
                JBS     off(0021ch).6, sensor_check_gate1 ; 7B0C 0 208 180 EE1C04
                MOVB    (001b5h-00180h)[USP], #014h ; 7B0F 0 208 180 C3359814
sensor_check_gate1:     MB      off(00217h).7, C       ; 7B13 0 208 180 C4173F
                J       sensor_check_gate1_if_ram212_bit2_set             ; 7B16 0 208 180 036C42
cfgvariant_snapshot_capture_load_ram2a1:     LB      A, off(002a1h)         ; 7B19 0 208 ??? F4A1
                STB     A, [DP]                ; 7B1B 0 208 ??? D2
                MOV     DP, #00344h            ; 7B1C 0 208 ??? 624403
                LB      A, r1                  ; 7B1F 0 208 ??? 79
                ROLB    A                      ; 7B20 0 208 ??? 33
                MB      C, off(0021dh).0       ; 7B21 0 208 ??? C41D28
                RORB    A                      ; 7B24 0 208 ??? 43
                STB     A, [DP]                ; 7B25 0 208 ??? D2
                J       cfgvariant_snapshot_capture_return             ; 7B26 0 208 ??? 03E25E
knock_324_bit_store_clear_carry:     RC                             ; 7B29 0 208 180 95
                J       knock_324_bit_store_clear_acc_2             ; 7B2A 0 208 180 03A77C
                DB  0FFh ; 7B2D
knock_324_bit_store_if_eq_goto_7b36:     JEQ     knock_324_bit_store_load_x1             ; 7B2E 0 208 180 C906
                MOV     DP, #003cfh            ; 7B30 0 208 180 62CF03
tbl_7b31        EQU     $-2 ; 7B31
                LB      A, [DP]                ; 7B33 0 208 180 F2
                SLLB    A                      ; 7B34 0 208 180 53
                SLLB    A                      ; 7B35 0 208 180 53
knock_324_bit_store_load_x1:     MOV     X1, #knock_324_bit_store_tbl          ; 7B36 0 208 180 60866F
                LCB     A, [X1]                ; 7B39 0 208 180 90AA
                JGE     knock_324_bit_store_load_dp_2             ; 7B3B 0 208 180 CD02
                ADDB    A, #006h               ; 7B3D 0 208 180 8606
knock_324_bit_store_load_dp_2:     MOV     DP, #003a4h            ; 7B3F 0 208 180 62A403
                J       knock_324_bit_store_store_dp_ind             ; 7B42 0 208 180 030652
boot_completion_helper_store_carry_ram216_bit3:     MB      off(00216h).3, C       ; 7B45 0 208 180 C4163B
                JGE     boot_completion_helper_store_carry_ram227_bit0             ; 7B48 0 208 180 CD05
                LCB     A, boot_completion_helper_tbl_13            ; 7B4A 0 208 180 909DA67B
                SLLB    A                      ; 7B4E 0 208 180 53
boot_completion_helper_store_carry_ram227_bit0:     MB      off(00227h).0, C       ; 7B4F 0 208 180 C42738
                J       boot_completion_helper_cmp_r0             ; 7B52 0 208 180 03CE5F
boot_completion_helper_set_carry:     SC                             ; 7B55 0 208 180 85
                LCB     A, boot_completion_helper_tbl_11            ; 7B56 0 208 180 909DA47B
                JNE     boot_completion_helper_goto_boot_flag_iabv_common             ; 7B5A 0 208 180 CE11
                RC                             ; 7B5C 0 208 180 95
                LCB     A, dwell_battery_check2_tbl            ; 7B5D 0 208 180 909DF260
                JNE     boot_completion_helper_goto_boot_flag_iabv_common             ; 7B61 0 208 180 CE0A
                SC                             ; 7B63 0 208 180 85
                LCB     A, boot_completion_helper_tbl_12            ; 7B64 0 208 180 909DA57B
                JNE     boot_completion_helper_goto_boot_flag_iabv_common             ; 7B68 0 208 180 CE03
                J       boot_completion_helper_load_r2_2             ; 7B6A 0 208 180 03E15F
boot_completion_helper_goto_boot_flag_iabv_common:     J       boot_flag_iabv_common             ; 7B6D 0 208 180 03E75F
boot_flag_iabv_common_set_carry:     SC                             ; 7B70 0 208 180 85
                LCB     A, boot_completion_helper_tbl_12            ; 7B71 0 208 180 909DA57B
                JNE     boot_flag_iabv_common_goto_5ffc             ; 7B75 0 208 180 CE06
                LB      A, r2                  ; 7B77 0 208 180 7A
                SLLB    A                      ; 7B78 0 208 180 53
                SLLB    A                      ; 7B79 0 208 180 53
                J       boot_flag_iabv_common_xorb_pswh             ; 7B7A 0 208 180 03F95F
boot_flag_iabv_common_goto_5ffc:     J       boot_flag_iabv_common_goto_7b80             ; 7B7D 0 208 180 03FC5F
boot_flag_iabv_common_store_carry_ram216_bit0:     MB      off(00216h).0, C       ; 7B80 0 208 180 C41638
                LCB     A, boot_flag_iabv_common_tbl            ; 7B83 0 208 180 909DE860
                SLLB    A                      ; 7B87 0 208 180 53
                LCB     A, diag_mode_code_store_tbl_2            ; 7B88 0 208 180 909DF360
                JEQ     boot_flag_iabv_common_store_carry_ram216_bit6             ; 7B8C 0 208 180 C906
                MB      C, off(00216h).0       ; 7B8E 0 208 180 C41628
                XORB    PSWH, #080h            ; 7B91 0 208 180 A2F080
boot_flag_iabv_common_store_carry_ram216_bit6:     MB      off(00216h).6, C       ; 7B94 0 208 180 C4163E
                J       boot_flag_iabv_common_cmp_r0             ; 7B97 0 208 180 03FF5F
boot_flag_gearpreset_alt_if_ram227_bit0_clr:     JBR     off(00227h).0, boot_flag_gearpreset_alt_store_carry_ram227_bit2 ; 7B9A 0 208 180 D82701
                SC                             ; 7B9D 0 208 180 85
boot_flag_gearpreset_alt_store_carry_ram227_bit2:     MB      off(00227h).2, C       ; 7B9E 0 208 180 C4273A
                J       boot_flag_gearpreset_alt_cmp_r0             ; 7BA1 0 208 180 038F60
boot_completion_helper_tbl_11:       DB  000h ; 7BA4
boot_completion_helper_tbl_12:       DB  0FFh ; 7BA5
boot_completion_helper_tbl_13:       DB  000h ; 7BA6
accut_output_drive_load_imm:     LB      A, #0feh               ; 7BA7 0 208 180 77FE
                JBS     off(00235h).4, accut_output_drive_cmp_acc ; 7BA9 0 208 180 EC3502
                LB      A, #0ffh               ; 7BAC 0 208 180 77FF
accut_output_drive_cmp_acc:     CMPB    A, 0d1h                ; 7BAE 0 208 180 C5D1C2
                MB      off(00235h).4, C       ; 7BB1 0 208 180 C4353C
                LB      A, #000h               ; 7BB4 0 208 180 7700
                JBS     off(00235h).5, accut_output_drive_cmp_acc_2 ; 7BB6 0 208 180 ED3502
                LB      A, #001h               ; 7BB9 0 208 180 7701
accut_output_drive_cmp_acc_2:     CMPB    A, 0cch                ; 7BBB 0 208 180 C5CCC2
                MB      off(00235h).5, C       ; 7BBE 0 208 180 C4353D
                JBS     off(00217h).5, purge_gate2_goto_purge_result_clear ; 7BC1 0 208 180 ED172A
                J       accut_output_drive_if_ram212_bit5_set             ; 7BC4 0 208 180 03544C
purge_gate2:     JBR     off(00218h).0, purge_ect_check ; 7BC7 0 208 180 D81806
                JBR     off(0021eh).4, purge_ect_check ; 7BCA 0 208 180 DC1E03
                JBR     off(00219h).0, purge_gate2_goto_purge_result_clear ; 7BCD 0 208 180 D8191E
purge_ect_check:     CMPB    0d9h, #000h            ; 7BD0 0 208 180 C5D9C000
                JGE     purge_ect_check_load_ram2f0             ; 7BD4 0 208 180 CD14
                CMPB    0d8h, #000h            ; 7BD6 0 208 180 C5D8C000
                JGE     purge_ect_check_load_ram2f0             ; 7BDA 0 208 180 CD0E
                JBS     off(00235h).4, purge_ect_check_load_ram2f0 ; 7BDC 0 208 180 EC350B
                CLRB    A                      ; 7BDF 0 208 180 FA
                JBS     off(00235h).5, purge_delay_store ; 7BE0 0 208 180 ED3502
                LB      A, #000h               ; 7BE3 0 208 180 7700
purge_delay_store:     STB     A, off(002f0h)         ; 7BE5 0 208 180 D4F0
purge_delay_store_goto_purge_counter_check:     J       purge_counter_check             ; 7BE7 0 208 180 03634C
purge_ect_check_load_ram2f0:     LB      A, off(002f0h)         ; 7BEA 0 208 180 F4F0
                JEQ     purge_delay_store_goto_purge_counter_check             ; 7BEC 0 208 180 C9F9
purge_gate2_goto_purge_result_clear:     J       purge_result_clear             ; 7BEE 0 208 180 03794C
ve_accel_tps_threshold_check_cmp_r0:     CMPB    r0, off(0016bh)        ; 7BF1 0 100 280 20C36B
                JGE     ve_accel_tps_threshold_check_goto_ve_accel_next_stage             ; 7BF4 0 100 280 CD03
                J       to_ve_accel_common             ; 7BF6 0 100 280 032A18
ve_accel_tps_threshold_check_goto_ve_accel_next_stage:     J       ve_accel_next_stage             ; 7BF9 0 100 280 033218
coldstart_full_reset_store_stk:     STB     A, (00168h-00180h)[USP] ; 7BFC 0 208 180 D3E8
                MOVB    (001cch-00180h)[USP], #006h ; 7BFE 0 208 180 C34C9806
                SB      (00126h-00180h)[USP].3 ; 7C02 0 208 180 C3A61B
                SB      P4.0                   ; 7C05 0 208 180 C52C18
                J       coldstart_full_reset_orb_tcon3             ; 7C08 0 208 180 03DB40
adc_wait_loop_load_imm:     LB      A, #025h               ; 7C0B 0 208 180 7725
                STB     A, 0dch                ; 7C0D 0 208 180 D5DC
                STB     A, 0ddh                ; 7C0F 0 208 180 D5DD
                J       adc_wait_loop_store_ram0df             ; 7C11 0 208 180 03A227
dwell_base_lookup_rom_load_tbl_7cb8:     LCB     A, dwell_base_lookup_tbl_2            ; 7C14 0 200 180 909DB87C
                JEQ     dwell_base_lookup_clear_carry             ; 7C18 0 200 180 C928
                JBR     off(00216h).3, dwell_base_lookup_clear_carry ; 7C1A 0 200 180 DB1625
                LB      A, #0feh               ; 7C1D 0 200 180 77FE
                JBS     off(00236h).1, dwell_base_lookup_cmp_acc_2 ; 7C1F 0 200 180 E93602
                LB      A, #0ffh               ; 7C22 0 200 180 77FF
dwell_base_lookup_cmp_acc_2:     CMPB    A, off(00238h)         ; 7C24 0 200 180 C738
                MB      off(00236h).1, C       ; 7C26 0 200 180 C43639
                MOVB    r0, 0d1h               ; 7C29 0 200 180 C5D148
                LB      A, #0feh               ; 7C2C 0 200 180 77FE
                JBS     off(00236h).2, dwell_base_lookup_cmp_acc_3 ; 7C2E 0 200 180 EA3602
                LB      A, #0ffh               ; 7C31 0 200 180 77FF
dwell_base_lookup_cmp_acc_3:     CMPB    A, r0                  ; 7C33 0 200 180 48
                MB      off(00236h).2, C       ; 7C34 0 200 180 C4363A
                JBR     off(00211h).5, dwell_base_lookup_load_ram23e ; 7C37 0 200 180 DD1111
                MOVB    off(002bfh), #000h     ; 7C3A 0 200 180 C4BF9800
dwell_base_lookup_load_ram2c1:     MOVB    off(002c1h), #000h     ; 7C3E 0 200 180 C4C19800
dwell_base_lookup_clear_carry:     RC                             ; 7C42 0 200 180 95
                CLRB    off(002c0h)            ; 7C43 0 200 180 C4C015
dwell_base_lookup_store_carry_ram236_bit0:     MB      off(00236h).0, C       ; 7C46 0 200 180 C43638
                SJ      dwell_base_lookup_clear_acc             ; 7C49 0 200 180 CB30
dwell_base_lookup_load_ram23e:     LB      A, off(0023eh)         ; 7C4B 0 200 180 F43E
                JNE     dwell_base_lookup_clear_carry             ; 7C4D 0 200 180 CEF3
                JBS     off(00236h).0, dwell_base_lookup_if_ram235_bit3_set ; 7C4F 0 200 180 E83604
                LB      A, off(002bfh)         ; 7C52 0 200 180 F4BF
                JEQ     dwell_base_lookup_clear_carry             ; 7C54 0 200 180 C9EC
dwell_base_lookup_if_ram235_bit3_set:     JBS     off(00235h).3, dwell_base_lookup_clear_carry ; 7C56 0 200 180 EB35E9
                JBS     off(00218h).6, dwell_base_lookup_clear_carry ; 7C59 0 200 180 EE18E6
                LB      A, (0019ch-00180h)[USP] ; 7C5C 0 200 180 F31C
                JNE     dwell_base_lookup_clear_carry             ; 7C5E 0 200 180 CEE2
                CMPB    0d9h, #001h            ; 7C60 0 200 180 C5D9C001
                JGE     dwell_base_lookup_clear_carry             ; 7C64 0 200 180 CDDC
                JBS     off(0021ah).2, dwell_base_lookup_clear_carry ; 7C66 0 200 180 EA1AD9
                JBR     off(00236h).2, dwell_base_lookup_load_ram2c1 ; 7C69 0 200 180 DA36D2
                JBR     off(00236h).1, dwell_base_lookup_clear_carry ; 7C6C 0 200 180 D936D3
                SC                             ; 7C6F 0 200 180 85
                JBR     off(00236h).0, dwell_base_lookup_store_carry_ram236_bit0 ; 7C70 0 200 180 D836D3
                LB      A, off(002c1h)         ; 7C73 0 200 180 F4C1
                JEQ     dwell_base_lookup_load_ram2c0             ; 7C75 0 200 180 C907
                MOVB    off(002c0h), #000h     ; 7C77 0 200 180 C4C09800
dwell_base_lookup_clear_acc:     CLRB    A                      ; 7C7B 0 200 180 FA
                SJ      dwell_base_lookup_store_ram2ff             ; 7C7C 0 200 180 CB0C
dwell_base_lookup_load_ram2c0:     LB      A, off(002c0h)         ; 7C7E 0 200 180 F4C0
                RC                             ; 7C80 0 200 180 95
                JEQ     dwell_base_lookup_store_carry_ram236_bit0             ; 7C81 0 200 180 C9C3
                LB      A, r0                  ; 7C83 0 200 180 78
                MOV     X1, #dwell_base_lookup_tbl_3          ; 7C84 0 200 180 60B97C
                CAL     table_interp_lookup             ; 7C87 0 200 180 323958
dwell_base_lookup_store_ram2ff:     STB     A, off(002ffh)         ; 7C8A 0 200 180 D4FF
                LB      A, 0c2h                ; 7C8C 0 200 180 F5C2
                MOV     X1, #dwell_base_lookup_tbl          ; 7C8E 0 200 180 609E6C
                J       dwell_base_lookup_call_table_interp_lookup             ; 7C91 0 200 180 03320F
ignsum_er3_start_load_ram2ff:     LB      A, off(002ffh)         ; 7C94 0 200 180 F4FF
                ADD     er3, A                 ; 7C96 0 200 180 4781
                CLR     A                      ; 7C98 1 200 180 F9
                LB      A, off(00241h)         ; 7C99 0 200 180 F441
                J       ignsum_er3_start_load_acc             ; 7C9B 0 200 180 03D60F
coldstart_full_reset_clear_ram232_bit7:     RB      off(00232h).7          ; 7C9E 0 208 180 C4320F
                RB      off(00236h).0          ; 7CA1 0 208 180 C43608
                J       coldstart_full_reset_clear_stk             ; 7CA4 0 208 180 031741
knock_324_bit_store_clear_acc_2:     CLRB    A                      ; 7CA7 0 208 180 FA
                LCB     A, boot_completion_helper_tbl_12            ; 7CA8 0 208 180 909DA57B
                J       knock_324_bit_store_if_eq_goto_7b36             ; 7CAC 0 208 180 032E7B
coldstart_full_reset_store_tbl_x1_2:     ST      A, 003a2h[X1]          ; 7CAF 1 208 180 D0A203
                L       A, #0ffffh             ; 7CB2 1 208 180 67FFFF
                J       coldstart_full_reset_store_tbl_x1             ; 7CB5 1 208 180 03C440
dwell_base_lookup_tbl_2:       DB  000h ; 7CB8
dwell_base_lookup_tbl_3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h ; 7CB9
                DB  000h,000h,000h,000h ; 7CC1
