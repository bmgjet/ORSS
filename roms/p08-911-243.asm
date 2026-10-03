;==================================================================================================
; p08-911-243.asm -- annotation pass (labels/comments only; firmware bytes unchanged)
; Assembles to the original image byte for byte.
; otherwise structural names built from what the labelled code does:
;   <context>_<action>   context = nearest named routine that reaches this block,
;                        action  = first instruction (load_/store_/cmp_/if_<ram>_b<n>_set/goto_/call_...)
;   ramXXX = RAM address XXXh, stk = user-stack frame slot.
;==================================================================================================
                org 0000h
int_start_vec:            DW  int_start
int_break_vec:            DW  int_break
int_WDT_vec:              DW  int_WDT
int_NMI_vec:              DW  int_NMI
int_INT0_vec:             DW  int_INT0
int_serial_rx_vec:        DW  int_serial_rx
int_serial_tx_vec:        DW  int_spurious_irq_trap
int_serial_rx_BRG_vec:    DW  int_serial_rx_BRG
int_timer_0_overflow_vec: DW  int_spurious_irq_trap
int_timer_0_vec:          DW  int_timer_0
int_timer_1_overflow_vec: DW  int_spurious_irq_trap
int_timer_1_vec:          DW  int_timer_1
int_timer_2_overflow_vec: DW  int_timer_2_overflow
int_timer_2_vec:          DW  int_timer_2
int_timer_3_overflow_vec: DW  int_spurious_irq_trap
int_timer_3_vec:          DW  int_timer_3
int_a2d_finished_vec:     DW  int_spurious_irq_trap
int_PWM_timer_vec:        DW  int_PWM_timer
int_serial_tx_BRG_vec:    DW  int_spurious_irq_trap
int_INT1_vec:             DW  int_INT1
vcal_0_vec:               DW  vcal_0
vcal_1_vec:               DW  vcal_1
vcal_2_vec:               DW  vcal_2
vcal_3_vec:               DW  vcal_3
vcal_4_vec:               DW  vcal_4
vcal_5_vec:               DW  vcal_5
vcal_6_vec:               DW  vcal_6
vcal_7_vec:               DW  vcal_7
code_start:     DB  000h,01Ch,04Ah,001h
; NMI Interrupt Service Routine
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
                MOV     LRB, #00041h  ; local register base = #00041h (base address 0x0208)
                RB      off(00230h).7  ; test-and-reset edge-detect bit 00230h.7
                JEQ     int_NMI_goto_7a85  ; skip snapshot if bit was already 0
                L       A, DP  ; bit just transitioned 1->0: snapshot DP
                ST      A, 00084h[X1]  ; ...into 00084h[X1]
int_NMI_goto_7a85:
                J       int_NMI_load_dp
nmi_poll_p4_1:  MB      C, P4.1  ; sample pin P4.1 into carry
                JGE     nmi_check_0f5  ; JGE branches on Carry=0 (arch.ml) -> as soon as P4.1 reads 0, jump ahead immediately
                JRNZ    DP, nmi_poll_p4_1  ; else (P4.1 still 1) keep polling until DP counts out, then fall through anyway
                MOVB    P2, #0ffh  ; drive P2 all-high
                RB      TCON0.2  ; clear TCON0.2
                SB      TCON0.2  ; ...then set TCON0.2 (pulse it)
                CLRB    A
                STB     A, ADSCAN  ; stop A/D scan
                STB     A, ADSEL  ; clear A/D channel select
                MOV     IE, #00040h  ; mask interrupt-enable to one source
                MOVB    TCON1, #0e0h
                CLR     IRQ  ; clear pending IRQ flags
                SB      P4SF.1
                MOV     TM1, #0ffffh  ; reload timer1 to max (effectively stop it counting down soon)
                SB      TCON1.4
                SB      SBYCON.2  ; standby-control bit set (see routine note above)
                LB      A, #005h
; [C1] STPACP = "Stop Code Acceptor" per the MSM66207 datasheet -- not a clock prescaler. Writing
; [C1] N then N<<1 (5, then 10) is the write-unlock sequence this register requires before STOP/HALT
; [C1] mode will actually be entered; it's a safety interlock against accidental entry, not a divider.
                STB     A, STPACP  ; stop-code-acceptor unlock write, step 1: N=5
                SLLB    A  ; ...step 2: N<<1=10
                STB     A, STPACP  ; unlock write, step 2
                SB      SBYCON.0  ; standby-control bit 0 set (likely the actual STOP-mode trigger)
                RB      0b7h.1
nmi_check_0f5:  LB      A, 0f5h  ; read watchdog/status-like byte trapReasonCode
                JNE     nmi_brk  ; if nonzero, fall straight to BRK
                MOVB    0f5h, #047h  ; else stamp trapReasonCode with sentinel 047h first
nmi_brk:        BRK  ; forces a BRK -> re-enters int_break (full reinit),
; Timer 0 Interrupt Service Routine
; involves a lot of bit-twiddling of r6(aka 00116h), r7 (00117h) and 00197h
; also affects er0-er2 (00110h-00115h)
; ultimately changes the state of Port2 pins 3,2,1 and 0
; however, the exact behavior is still unclear
int_timer_0:    MOV     LRB, #00022h
; --- Timer0 ISR: bit-shifts a value (r6, 16 bits across er0/er1/er2 chain) out one bit per
; timer period, reloading TMR0 for the next bit's timing, tracking bit count in r7 (0-15,
; matching a 16-bit shift register), accumulating into off(00197h) and driving P2 with the
; result. Reads as a software bit-banged serial or pulse-train output; no calibration anchors
; to identify the specific protocol/signal.
                ANDB    TCON0, #0fbh
                CMPB    r7, #00fh
                JEQ     timer0_return
                L       A, er0
                JNE     timer0_bit_accumulate
                L       A, er1
                JEQ     timer0_final_bit_check
                ADD     TMR0, A
                LB      A, r6
                MB      C, ACC.7
                ROLB    r6
                ORB     A, r6
                ANDB    A, #00fh
                ORB     r7, A
                ORB     off(0018fh), A
                LB      A, r6
                SLLB    A
                ROLB    r6
                MOV     er0, er2
                L       A, #00001h
                ST      A, er1
timer0_bitshift_loop:
                ST      A, er2
                L       A, er0
                JNE     timer0_bit_shift_right
                L       A, er1
                JEQ     timer0_bit_invert
                LB      A, r6
                SRLB    A
                SRLB    A
                SRLB    A
                ORB     A, r6
timer0_bit_output:
                ORB     A, off(0018fh)
                ANDB    A, #00fh
                ORB     P2, A
                RTI
timer0_bit_shift_right:
                LB      A, r6
                SJ      timer0_bit_output
timer0_bit_invert:
                LB      A, r6
                RORB    A
                XORB    A, #0ffh
                J       timer0_bit_output
timer0_return:  RTI
timer0_bit_accumulate:
                ADD     TMR0, A
                LB      A, r6
                ANDB    A, #00fh
                ORB     r7, A
                ORB     off(0018fh), A
                LB      A, r6
                SLLB    A
                ROLB    r6
                MOV     er0, er1
                MOV     er1, er2
                L       A, #00001h
                J       timer0_bitshift_loop
timer0_final_bit_check:
                L       A, er2
                JEQ     timer0_sequence_done
                ADD     TMR0, A
                LB      A, r6
                MB      C, ACC.0
                RORB    A
                STB     A, r6
                XORB    A, #0ffh
                ANDB    A, #00fh
                ORB     r7, A
                ORB     off(0018fh), A
                LB      A, r6
                ANDB    A, #00fh
timer0_sequence_reset:
                ORB     P2, A
                L       A, #00001h
                ST      A, er0
                ST      A, er1
                ST      A, er2
                RTI
timer0_sequence_done:
                LB      A, #00fh
                STB     A, r7
                STB     A, off(0018fh)
                SJ      timer0_sequence_reset
; Timer 1 Interrupt Service Routine
; toggles (TCON1).3, (000b6h).5
; modifies er1, er2, r6, TMR1
; also influenced by er0
; This routine seems to systematically modify TMR1 based on er0, er1 and ADCR4
; (what is connected to ADC channel 4??)
int_timer_1:    MOV     LRB, #00013h
                JBR     off(TCON1).3, timer1_tmr1_reload
                RB      off(000b6h).5
                JNE     timer1_check_start
                CMP     er1, #0064ah
                JLT     timer1_check_start
                ORB     off(000b6h), #020h
                L       A, #003b6h
                SUB     er1, A
                ADD     off(TMR1), A
                RTI
timer1_check_start:
                ANDB    off(TCON1), #0f7h
                L       A, off(ADCR4)
                ST      A, er2
                ADD     off(TMR1), off(0009ah)
                RTI
timer1_tmr1_reload:
                ORB     off(TCON1), #008h
                INCB    r6
                L       A, #00a00h
                SUB     A, er0
                ST      A, er1
                ADD     off(TMR1), off(00098h)
                RTI
; Timer 2 Interrupt Service Routine
int_timer_2:    MOV     LRB, #00014h
; --- Timer2 ISR (0x160-0x1E9+): reschedules TMR2/TMR3 relative to each other and TM3,
; tracking a small state counter (r0/r2, states 0-4/5) and TCON3 bits. Likely supporting
; crank/cam signal period measurement alongside int_INT1's tooth-decode logic (references
; TRNSIT and sysFlags_b7.2, both touched there too). No calibration anchors; named at the
; mechanism level.
                LB      A, r2
                CMPB    A, #003h
                JGE     timer2_state1_check
                ADDB    A, #001h
                JBS     off(ACC).0, timer2_state_dispatch
                MOV     off(000bah), off(ADCR6)
timer2_state_dispatch:
                CMPB    A, r0
                JEQ     timer3_reload_add
                JLT     timer3_reload_dec
timer2_tcon3_clear:
                ANDB    off(TCON3), #0fbh
timer3_reload_dec:
                L       A, off(TM3)
                SUB     A, #00001h
                ST      A, off(TMR3)
timer2_irq_clear:
                ANDB    off(IRQH), #0f7h
                ORB     off(IRQ), #008h
                RB      off(TRNSIT).0
                JEQ     timer2_return
                SB      off(000b7h).2
timer2_return:  RTI
timer2_state1_check:
                JEQ     timer2_state2_check
                JBR     off(ACC).0, timer2_tcon3_check2
                JBS     off(000a0h).3, timer2_tcon3_clear
                CLRB    A
                ORB     off(TCON3), #004h
                J       timer2_state_dispatch
timer2_state2_check:
                LB      A, r0
                ADDB    A, #001h
                CMPB    A, #005h
                JGE     timer2_er3_calc
                ANDB    off(TCON3), #0fbh
                L       A, er2
                CMP     A, #0001fh
                JGE     timer2_tmr2_add
                L       A, #0001fh
timer2_tmr2_add:
                ADD     A, off(TMR2)
                J       timer3_reload_store
timer2_tcon3_check:
                JBS     off(TCON3).3, timer3_reload_dec
timer2_er3_calc:
                L       A, off(TMR2)
                ADD     A, er2
                ST      A, er3
timer3_reload_add:
                L       A, off(TMR2)
                ADD     A, off(000e8h)
                ST      A, off(TMR3)
                ANDB    off(TCON3), #0f7h
                SJ      timer2_irq_clear
timer2_tcon3_check2:
                JBS     off(TCON3).2, timer2_tcon3_check
                L       A, off(TM3)
                SUB     A, off(TMR2)
                ADD     A, #00006h
                CMP     A, er2
                JGE     timer3_reload_alt
                L       A, off(TMR2)
                ADD     A, er2
                SJ      timer3_reload_store
timer3_reload_alt:
                L       A, off(TM3)
                ADD     A, #00004h
timer3_reload_store:
                ST      A, off(TMR3)
                ORB     off(TCON3), #008h
                J       timer2_irq_clear
; Ext. Interrupt 0 Service Routine
int_INT0:       L       A, 0fah
                ST      A, IE
                L       A, TM2
                ORB     PSWH, #001h
                MOV     LRB, #00015h
                JBS     off(ACCH).7, int_int0_edge_check
                JBR     off(IRQH).0, int_int0_edge_check
                INCB    r3
                ORB     off(000b6h), #002h
int_int0_edge_check:
                XCHG    A, er0
                ST      A, er2
                CLRB    A
                XCHGB   A, r3
                STB     A, r2
                ORB     off(000b6h), #004h
                L       A, off(000f8h)
                ANDB    PSWH, #0feh
                ST      A, off(IE)
                RTI
int_serial_rx:  L       A, 0fah
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #0007eh
                JBR     off(00356h).1, int_serial_rx_clear_acc
                RB      off(00356h).6
                JEQ     int_serial_rx_load_r7
                CLR     A
                LB      A, r5
                CMPB    A, #002h
                JEQ     int_serial_rx_load_r2
                CMPB    A, r2
                JGE     int_serial_rx_if_ne_goto_0244
                ADDB    A, r3
                L       A, ACC
                SLL     A
                ADD     A, #int_serial_rx_tbl
                MOV     DP, A
                LC      A, [DP]
                MOV     DP, A
                LB      A, [DP]
int_serial_rx_addb_r6:
                ADDB    r6, A
int_serial_rx_store_stbuf:
                STB     A, STBUF
                INCB    r5
                SB      off(00356h).6
int_serial_rx_load_ram0f8:
                L       A, 0f8h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_serial_rx_load_r2:
                LB      A, r2
                SJ      int_serial_rx_addb_r6
int_serial_rx_if_ne_goto_0244:
                JNE     int_serial_rx_load_ram0f8
                CLRB    A
                SUBB    A, r6
                SJ      int_serial_rx_store_stbuf
int_serial_rx_load_r7:
                LB      A, r7
                JEQ     int_serial_rx_load_r0
                LB      A, r5
                CMPB    A, #001h
                JEQ     int_serial_rx_load_srbuf
                ADDB    A, #001h
                CMPB    A, r2
                JEQ     int_serial_rx_load_srbuf_2
                LB      A, SRBUF
                CMPB    r5, #002h
                JNE     int_serial_rx_store_r4
                STB     A, r3
                SJ      int_serial_rx_addb_r6_2
int_serial_rx_store_r4:
                STB     A, r4
int_serial_rx_addb_r6_2:
                ADDB    r6, A
                INCB    r5
int_serial_rx_load_r7_2:
                MOVB    r7, #002h
                J       int_serial_rx_load_ram0f8_2
int_serial_rx_load_r0:
                MOVB    r0, r1
                LB      A, SRBUF
                STB     A, r1
                STB     A, r6
                MOVB    r5, #001h
                SJ      int_serial_rx_load_r7_2
int_serial_rx_load_srbuf:
                LB      A, SRBUF
                STB     A, r2
                SJ      int_serial_rx_addb_r6_2
int_serial_rx_load_srbuf_2:
                LB      A, SRBUF
                ADDB    A, r6
                JNE     int_serial_rx_clear_r7
                LB      A, r1
                ANDB    A, #0e0h
                CMPB    A, #020h
                JNE     int_serial_rx_clear_r7
                SB      off(00356h).7
int_serial_rx_clear_r7:
                CLRB    r7
int_serial_rx_load_ram0f8_2:
                L       A, 0f8h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_serial_rx_clear_acc:
                CLRB    A
                RB      SRSTAT.3
                JEQ     int_serial_rx_clear_srstat_bit2
                ADDB    A, #001h
int_serial_rx_clear_srstat_bit2:
                RB      SRSTAT.2
                JEQ     int_serial_rx_store_acch
                ADDB    A, #002h
int_serial_rx_store_acch:
                STB     A, ACCH
                LB      A, SRBUF
                MOV     DP, A
                L       A, DP
                JEQ     int_serial_rx_load_dp
                SRL     A
                JLT     int_serial_rx_load_dp_ind
                L       A, [DP]
                LB      A, ACC
                MOVB    off(0035ch), ACCH
int_serial_rx_store_stbuf_2:
                STB     A, STBUF
                SJ      int_serial_rx_load_ram0f8
int_serial_rx_load_dp:
                MOV     DP, #0035ch
int_serial_rx_load_dp_ind:
                LB      A, [DP]
                SJ      int_serial_rx_store_stbuf_2
                DB  0E5h,0FAh,0D5h,01Ah,0B5h,004h,098h,002h
                DB  001h,067h,000h,001h,0F5h,055h,0C5h,056h
                DB  00Bh,0CEh,00Ch,0C5h,006h,02Fh,0C5h,007h
                DB  015h,0CAh,004h,0C5h,007h,098h,002h,052h
                DB  0F2h,0D5h,051h,0E5h,0F8h,0A2h,008h,0B5h
                DB  01Ah,08Ah,002h
int_timer_2_overflow:
                L       A, 0fah
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #00015h
                RB      off(000b6h).0
                JNE     timer2ovf_edge_check2
                INCB    r6
timer2ovf_edge_check2:
                RB      off(000b6h).1
                JNE     timer2ovf_return
                INCB    r3
timer2ovf_return:
                L       A, 0f8h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_timer_3:    L       A, 0fah
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #00014h
                LB      A, r0
                ADDB    A, #001h
                CMPB    A, #005h
                JLT     timer3isr_return
                JBS     off(TCON3).2, timer3isr_return
                MOV     off(TMR3), er3
                ORB     off(TCON3), #008h
timer3isr_return:
                L       A, off(000f8h)
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_PWM_timer:  L       A, 0fah
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #0007dh
                LB      A, r0
                ADDB    A, #001h
                CMPB    A, #064h
                JLT     int_PWM_timer_store_r0
                MOVB    r1, 0e4h
                CLRB    A
int_PWM_timer_store_r0:
                STB     A, r0
                CMPB    A, r1
                MB      P4.3, C
                JBR     off(00356h).0, pwm_isr_return
                LB      A, r2
                JNE     int_PWM_timer_subb_acc
                MOVB    r3, 0e5h
                MOV     er2, 0e6h
                LB      A, #031h
int_PWM_timer_store_r2:
                STB     A, r2
                CMPB    A, r3
                JEQ     int_PWM_timer_load_er2
                L       A, #00001h
                JGE     pwm_output_store
                L       A, #0ffffh
pwm_output_store:
                ST      A, PWMR0
pwm_isr_return: L       A, 0f8h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_PWM_timer_subb_acc:
                SUBB    A, #001h
                SJ      int_PWM_timer_store_r2
int_PWM_timer_load_er2:
                L       A, er2
                SJ      pwm_output_store
int_INT1:       L       A, #000a0h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #00021h
                MOV     USP, #00280h
                CAL     refresh_engine_flags_snapshot
                SB      off(00128h).4
                JBS     off(0011ah).7, int1_dispatch_main_cycle
                JBS     off(0011ah).3, int1_dispatch_alt1
                RB      IRQH.1
                JEQ     dtc04_ckp_latch
                RB      0b4h.0
                MOVB    off(001adh), #02dh
int1_dispatch_main_cycle:
                J       crank_cycle_entry
dtc04_ckp_latch:
                SB      0b4h.0
int1_dispatch_alt1:
                L       A, ADCR6
                ST      A, 0bah
                L       A, TM2
                ST      A, 0f0h
                MOVB    0a2h, #000h
                LB      A, #003h
                RB      TRNSIT.0
                JNE     crank_tooth_count_store
                LB      A, off(00134h)
                ADDB    A, #006h
                CMPB    A, #018h
                JLT     crank_tooth_count_store
                LB      A, #003h
crank_tooth_count_store:
                STB     A, off(00134h)
                SB      P4.0
                MB      C, off(0011bh).6
                MB      off(0012ah).1, C
                JBS     off(00128h).2, int1_exit_jump
                LB      A, off(0013dh)
                JNE     int1_exit_jump
                STB     A, off(0013ch)
                SB      off(00128h).2
                ANDB    PSWH, #0feh
                MOVB    off(0018eh), #077h
                MOVB    off(00116h), #011h
                ORB     PSWH, #001h
int1_exit_jump: J       crank_cycle_dispatch2
int_serial_rx_BRG:
                L       A, #000a0h
; NOTE: despite the vector-table name (inherited from the OKI 66207's default peripheral
; vector list), this handler's actual content -- storing to off(0011ah)/(0011ch)/(0011eh)
; (the exact addresses refresh_engine_flags_snapshot reads from), managing a tooth/sync
; counter (0xA2/0xA3), and touching sysFlags_b7 bits 0/2 -- looks like crank/cam sync-pattern
; handling, not serial-receive-baud-rate-generator work. Likely this vector/trigger source is
; repurposed by this firmware for a different signal than its datasheet name implies. Flagging
; rather than asserting a replacement name without more certainty.
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #00021h
                MOV     USP, #00280h
                L       A, (00212h-00280h)[USP]
                ST      A, off(0011ah)
                L       A, (00214h-00280h)[USP]
                ST      A, off(0011ch)
                L       A, (00216h-00280h)[USP]
                ST      A, off(0011eh)
                MOVB    off(001adh), #02dh
                JBR     off(00128h).3, crank_sync_flags_clear_path
                JBS     off(0011ah).7, crank_sync_flag_set
                RB      IRQH.7
                JNE     crank_sync_lost_path
                RB      0b6h.7
                JNE     crank_sync_lost_path
crank_sync_retry_check:
                CMPB    0a2h, #005h
                JGE     crank_sync_confirm_check
                INCB    0a2h
                J       crank_sync_window_check
crank_sync_flag_set:
                SB      off(00128h).4
                SJ      crank_sync_retry_check
crank_sync_confirm_check:
                JBS     off(0011ah).7, crank_sync_confirmed
dtc08_tdc_latch_2:
                SB      0b4h.1
                SB      off(00128h).6
crank_sync_confirmed:
                INCB    0a3h
                CLRB    0a2h
                SJ      crank_sync_window_check
crank_sync_flags_clear_path:
                RB      IRQH.7
                RB      0b6h.7
                RB      0b7h.2
                MB      C, 0b7h.0
                JGE     crank_sync_exit_jump
                SB      off(00128h).4
crank_sync_exit_jump:
                J       crank_decode_exit
crank_sync_lost_path:
                SB      off(00128h).4
                RB      off(00128h).6
                MOVB    off(001aeh), #02dh
                L       A, 0a2h
                CMP     A, #00005h
                JEQ     crank_tooth_counter_reset
                SB      off(00125h).7
                JLT     crank_sync_flag_mid
                CMP     A, #00105h
                JGE     crank_sync_flag_high
                SB      0b5h.0
                SJ      crank_tooth_counter_reset
crank_sync_flag_mid:
                SB      off(00128h).5
                SJ      crank_tooth_counter_reset
crank_sync_flag_high:
                SB      0b5h.1
crank_tooth_counter_reset:
                CLR     0a2h
crank_sync_window_check:
                JBS     off(0011bh).0, crank_window_flag_clear
                RB      0b7h.2
                JEQ     crank_tooth_seq_check
                RB      off(00128h).7
                MOVB    off(001afh), #007h
                L       A, off(00134h)
                CMP     A, #00017h
                JNE     crank_window_flag_check2
                RB      off(00128h).5
                JNE     crank_sync_flag_low
                RB      off(00125h).7
                CMPB    0a2h, #003h
                JEQ     crank_tooth_reset
crank_sync_flag_common:
                SB      0b5h.2
                SJ      crank_tooth_reset
crank_window_flag_clear:
                RB      off(00125h).7
crank_tooth_seq_check:
                CMPB    off(00134h), #017h
                JGE     crank_tooth_seq_gate
                INCB    off(00134h)
                J       crank_tooth_mod_check
crank_tooth_seq_gate:
                JBS     off(0011bh).0, crank_tooth_seq_advance
dtc09_cyp_latch:
                SB      0b4h.2
                SB      off(00128h).7
crank_tooth_seq_advance:
                INCB    off(00135h)
                CLRB    off(00134h)
                SJ      crank_tooth_mod_check
crank_window_flag_check2:
                RB      off(00128h).5
                JGE     crank_tooth_reset
                JEQ     crank_sync_flag_common
                SB      0b5h.0
                SJ      crank_tooth_reset
crank_sync_flag_low:
                SB      0b5h.1
crank_tooth_reset:
                CLR     off(00134h)
crank_tooth_mod_check:
                JBS     off(0011ah).7, crank_tooth_mod6_calc
                JBS     off(00128h).6, crank_tooth_mod6_calc
crank_tooth_range_check:
                JBS     off(0011bh).0, crank_tooth_wrap_calc
                JBS     off(00128h).7, crank_tooth_wrap_calc
crank_tooth_carry_clear:
                RC
                JBR     off(0011bh).6, crank_sync_store_flag
                SJ      crank_sync_confirmed_flag
crank_tooth_mod6_calc:
                CLR     A
                MOVB    r0, #006h
                LB      A, off(00134h)
                ADDB    A, #003h
                DIVB
                LB      A, r1
                STB     A, 0a2h
                SJ      crank_tooth_range_check
crank_tooth_wrap_calc:
                MOVB    r0, #006h
                LB      A, 0a2h
                ADDB    A, #003h
                SUBB    A, r0
                JGE     crank_tooth_wrap_store
                ADDB    A, r0
crank_tooth_wrap_store:
                STB     A, r2
                CLR     A
                LB      A, off(00134h)
                DIVB
                MULB
                ADDB    A, r2
                STB     A, off(00134h)
                JBS     off(0011ah).7, crank_sync_confirmed_flag
                JBR     off(00128h).6, crank_tooth_carry_clear
crank_sync_confirmed_flag:
                SC
                SB      off(00124h).2
crank_sync_store_flag:
                MB      off(0012ah).1, C
                LB      A, off(00134h)
                EXTND
                MOV     X1, A
                LCB     A, tbl_crank_sync_pattern[X1]
                ANDB    off(00128h), A
                LB      A, off(00134h)
                JNE     crank_sync_flag2_check
                JBR     off(00128h).2, crank_sync_store_flag_goto_7ab4
                JBS     off(0011fh).7, crank_sync_flag2_check
                JBS     off(00128h).0, crank_tooth_alt_flag
                RB      off(00128h).1
                SJ      crank_tooth_alt_store
crank_sync_store_flag_goto_7ab4:
                J       crank_sync_store_flag_andb_pswh
                DB  000h
crank_sync_store_flag_load_ram116:
                MOVB    off(00116h), #011h
                ANDB    off(00128h), #0fch
                ORB     PSWH, #001h
                SJ      crank_tooth_alt_store
crank_tooth_alt_flag:
                LB      A, #001h
                JBR     off(00128h).1, crank_tooth_alt_store
                LB      A, #002h
crank_tooth_alt_store:
                STB     A, off(0013ch)
crank_sync_flag2_check:
                JBS     off(00128h).2, crank_sync_flag2_check_if_ram11f_bit7_set
                CMPB    off(0013dh), #004h
                JEQ     crank_cycle_exit_early
                LB      A, off(0013dh)
                J       crank_sync_flag2_check_if_ne_goto_7ac7
crank_sync_flag2_check_goto_7aca:
                J       crank_sync_flag2_check_load_ram0a2
crank_sync_flag2_check_if_ram11f_bit7_set:
                JBS     off(0011fh).7, crank_sync_flag2_check_goto_7aca
                LB      A, off(0013ch)
                ANDB    A, #001h
                TRB     off(00128h)  ; mnemonic was "TBR" (letter transposition)
                JNE     crank_cycle_exit_early
                CLR     A
                LB      A, off(00134h)
                JBR     off(0013ch).0, crank_tooth_pattern_lookup
                ADDB    A, #006h
crank_tooth_pattern_lookup:
                MOV     X1, A
                LCB     A, tbl_crank_tooth_pattern[X1]
                CMPB    A, off(0013bh)
                JGE     crank_cycle_dispatch2
crank_cycle_exit_early:
                J       crank_decode_exit
crank_cycle_dispatch2:
                LB      A, off(0013ch)
                SLLB    A
                EXTND
                MOV     X1, A
                JBS     off(00125h).4, injtimer_countdown_check
                CLR     A
                MOV     X2, A
                ST      A, 003beh[X2]
                ST      A, 003c0h[X2]
                ST      A, 003c2h[X2]
                ST      A, 003c4h[X2]
                CLRB    A
                STB     A, off(0019dh)
                J       injtimer_bit_clear
injtimer_clear_path1:
                SBR     off(0019fh)
                SB      off(0012ah).7
                SB      off(0019bh).0
                SJ      injbase_calc_start
injtimer_countdown_store_load_ram14e:
                L       A, off(0014eh)
                SJ      injtimer_clamp_store
injtimer_countdown_check:
                LB      A, off(0019eh)
                SUBB    A, #001h
                JGE     injtimer_countdown_store
                LB      A, #007h
injtimer_countdown_store:
                STB     A, off(0019eh)
                CMPB    A, #007h
                JGT     injtimer_bit_clear
                MBR     C, off(0019dh)
                JLT     injtimer_clear_path1
                ADDB    A, #004h
                RBR     off(0019fh)
                JNE     injtimer_countdown_store_load_ram14e
                L       A, 003beh[X1]
                SUB     A, #0ffffh
                JGE     injtimer_clamp_store
                CLR     A
injtimer_clamp_store:
                ST      A, 003beh[X1]
injtimer_bit_clear:
                RB      off(0019bh).0
injbase_calc_start:
                CLR     A
                JBS     off(00124h).4, injbase_store
                JBS     off(0012ah).1, injbase_store
                L       A, 003b6h[X1]
                ADD     A, 003beh[X1]
                JGE     injbase_store
                L       A, #0ffffh
injbase_store:  ST      A, off(00196h)
                LB      A, off(0013ch)
                ANDB    PSWH, #0feh
                TRB     off(00117h)  ; mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C41713
                JNE     tm0_sync_alt
                JBR     off(00128h).2, tm0_sync_common
                L       A, TM0
                SUB     A, TMR0
                JEQ     tm0_sync_common
                MB      C, IRQ.5
                JLT     tm0_sync_common
                ADD     A, #00005h
                JLT     tm0_sync_common
                ADD     TMR0, A
tm0_sync_common:
                ORB     PSWH, #001h
                CAL     tm0_resync_helper
                SB      off(0012ah).3
                J       crank_tooth_flag_update
tm0_sync_alt:   L       A, TMR0
                SUB     A, TM0
                CMP     A, #00005h
                JLT     tm0_sync_flag_clear
                CMP     A, #00020h
                JLT     tm0_sync_flag_set
tm0_sync_flag_clear:
                ORB     PSWH, #001h
                RB      off(0012ah).3
                J       crank_tooth_flag_update
tm0_sync_flag_set:
                ORB     PSWH, #001h
                CAL     tm0_resync_helper
                SB      off(0012ah).3
crank_tooth_flag_update:
                CAL     crank_helper2
                LB      A, off(0013ch)
                STB     A, r0
                ANDB    A, #001h
                SBR     off(00128h)
                INCB    r0
                LB      A, r0
                ANDB    A, #003h
                STB     A, off(0013ch)
                JBS     off(0011fh).3, crank_decode_exit
                JBS     off(0011bh).7, crank_decode_exit
                RB      off(0012ah).0
                JEQ     crank_decode_exit
                RB      TRNSIT.2
                JNE     crank_decode_exit
dtc16_injector_latch:
                SB      0b4h.6
crank_decode_exit:
                RB      off(0012ah).3
                JNE     crank_decode_final_check
                CAL     tm0_resync_helper
crank_decode_final_check:
                LB      A, 0a2h
                CMPB    A, #003h
                JNE     crank_cycle_dispatch
crank_cycle_dispatch_body:
                JBS     off(00126h).0, crank_cycle_period_saturate
                JBS     off(0011fh).1, crank_cycle_period_saturate
                CMPB    A, #003h
                CLR     er2
                JBS     off(0012ah).5, crank_cycle_alt_dp
                MOV     DP, #00366h
                JEQ     crank_cycle_dp_common
                CLR     A
                SJ      crank_cycle_er2_store
crank_cycle_alt_dp:
                MOV     DP, #00362h
                JNE     crank_cycle_dp_common
                MOV     er2, [DP]
crank_cycle_dp_common:
                L       A, [DP]
                CLR     er0
                MOVB    r1, 09fh
                MUL
                L       A, er2
                ADD     A, er1
                JGE     crank_cycle_er2_store
crank_cycle_period_saturate:
                L       A, #0ffffh
crank_cycle_er2_store:
                ST      A, 0a4h
crank_cycle_entry:
                L       A, off(00124h)
                ST      A, (0021ch-00280h)[USP]
                ANDB    PSWH, #0feh
int1_rti_epilogue:
                L       A, 0f8h
                ST      A, IE
                RTI
crank_cycle_dispatch:
                JGE     crank_cycle_dispatch_alt
                CMPB    A, #001h
                JGE     crank_cycle_dispatch_alt2
                JBS     off(0011bh).6, crank_cycle_p4_gate
                JBS     off(00125h).7, crank_cycle_p4_gate
                CMP     0c4h, #000e2h
                JLT     crank_cycle_p4_gate
                RB      TRNSIT.1
                JNE     crank_cycle_p4_gate
dtc15_ign_output_latch:
                SB      0b4h.3
                SJ      crank_cycle_p4_gate_if_ram11f_bit2_set
crank_cycle_p4_gate:
                RB      0b4h.3
                MOVB    off(001b0h), #006h
crank_cycle_p4_gate_if_ram11f_bit2_set:
                JBS     off(0011fh).2, crank_cycle_gate2
                JBS     off(0011fh).7, crank_cycle_p4_gate_set_p4_bit0
                JBR     off(00129h).1, crank_cycle_p4_gate_goto_7ad4
                JBS     off(0011ah).2, crank_cycle_p4_gate_if_ram120_bit0_set
                JBR     off(0011ah).4, crank_cycle_result_common
crank_cycle_p4_gate_if_ram120_bit0_set:
                JBS     off(00120h).0, crank_cycle_result_a
                SJ      crank_cycle_result_common
crank_cycle_p4_gate_set_p4_bit0:
                SB      P4.0
                SJ      crank_cycle_entry_gate
crank_cycle_p4_gate_goto_7ad4:
                J       crank_cycle_p4_gate_load_imm
crank_cycle_counter_check:
                CMPB    off(001aeh), #028h
                JLE     crank_cycle_result_b
                JBS     off(0011fh).4, crank_cycle_result_a
                JBS     off(0012ah).4, crank_cycle_result_common
                JBS     off(0011ah).5, crank_cycle_result_a
                CMPB    0d9h, #020h
                JLT     crank_cycle_result_common
crank_cycle_result_a:
                LB      A, #003h
                SJ      crank_cycle_result_common
crank_cycle_result_b:
                SB      off(00128h).4
crank_cycle_result_common:
                SRLB    A
                MB      off(00126h).0, C
                SRLB    A
                MB      P4.0, C
                SJ      crank_cycle_entry
crank_cycle_dispatch_alt:
                CMPB    A, #004h
                JNE     crank_cycle_entry
                J       crank_cycle_dispatch_body
crank_cycle_bailout:
                SJ      crank_cycle_entry
crank_cycle_dispatch_alt2:
                JEQ     crank_cycle_entry
crank_cycle_gate2:
                JBS     off(0011fh).7, crank_cycle_bailout
                JBR     off(00128h).4, crank_cycle_bailout
crank_cycle_entry_gate:
                INCB    off(0013eh)
                JBS     off(0012ah).2, crank_cycle_bailout
                LB      A, off(00124h)
                ANDB    A, #003h
                ANDB    off(0013eh), A
                JNE     crank_cycle_bailout
                J       crank_cycle_entry_gate_set_ram12a_bit2
                DB  000h
crank_cycle_entry_gate_call_crank_edge_helper:
                CAL     crank_edge_helper
                MOV     PSW, #01101h
                MOV     LRB, #00040h
                MOV     USP, #00180h
                MOV     DP, #00379h
                MOVB    r0, [DP]
                LB      A, 0e1h
                STB     A, [DP]
                LB      A, ADCR2H
                STB     A, 0e1h
                SUBB    A, r0
                MB      off(0022bh).5, C
                JGE     crank_cycle_adc_prep
                VCAL    6
crank_cycle_adc_prep:
                STB     A, 0e2h
                LB      A, P2
                ANDB    A, #0e0h
                STB     A, off(00259h)
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
rpm_period_accum_goto_7aec:
                J       rpm_period_accum_load_tbl_x1
rpm_period_overflow_check:
                JEQ     rpm_period_invalid
rpm_period_accum:
                ADD     er1, A
                ADCB    r0, #000h
                INC     X1
                INC     X1
                JRNZ    DP, rpm_period_accum_goto_7aec
                RB      off(00217h).4
                RB      off(00231h).5
                L       A, er1
                MOV     er2, #00005h
                DIV
                CMPB    r0, #000h
                JEQ     rpm_period_avg_store
rpm_period_invalid:
                SB      off(00231h).5
                L       A, #0ffffh
rpm_period_avg_store:
                ST      A, er0
                CLR     X1
                XCHG    A, 0c4h
                ST      A, er1
                XCHG    A, 0036ch[X1]
                XCHG    A, 0036eh[X1]
                XCHG    A, 00370h[X1]
                ST      A, er2
                L       A, er0
                SUB     A, er2
                MB      off(0021bh).7, C
                JGE     rpm_accel_limit_check
                VCAL    7
rpm_accel_limit_check:
                ST      A, 0c8h
                L       A, er0
                SUB     A, er1
                MB      off(0021bh).6, C
                JGE     rpm_decel_limit_check
                VCAL    7
rpm_decel_limit_check:
                ST      A, 0c6h
                L       A, 0c4h
                CMP     A, #000eah
                JLT     rpm_period_normalize_lowrange
                CMP     A, #00ea6h
                JGE     rpm_period_normalize_highrange
                MOV     er3, #0ffc0h
                MOV     er0, #00007h
                MOV     er2, #00753h
                MOV     X1, #05300h
rpm_divide_normalize_loop:
                CMP     A, er2
                JGE     rpm_divide_execute
                SRL     er0
                ROR     X1
                ADD     er3, #00040h
                SRL     er2
                SJ      rpm_divide_normalize_loop
rpm_divide_execute:
                ST      A, er2
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
rpm_period_normalize_lowrange:
                CMP     A, #000bbh
                LB      A, #0ffh
                JLT     rpm_period_normalize_done
rpm_clamp_0xfe: LB      A, #0feh
rpm_period_normalize_done:
                SB      PSWL.4
                SJ      rpm_calc_finalize
rpm_period_normalize_highrange:
                CLRB    A
                JBS     off(00217h).4, rpm_normalize_flag_clear
rpm_normalize_flag_set:
                LB      A, #001h
rpm_normalize_flag_clear:
                RB      PSWL.4
rpm_calc_finalize:
                MB      C, PSWL.4
                MB      0b8h.4, C
                STB     A, (00133h-00180h)[USP]
                XCHGB   A, off(00238h)
                STB     A, 0c3h
                CLRB    r7
                JBS     off(00217h).4, loadindex_flag_default
                DECB    r7
                MOV     er2, 0c4h
                MOV     er0, #0d000h
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
loadindex_flag_default:
                RC
loadindex_flag_load:
                LB      A, r7
loadindex_store:
                STB     A, 0c2h
                MB      0b8h.3, C
                JBS     off(00212h).2, map_sign_flag_clear
                L       A, 0bah
                SWAP
                LB      A, ACC
                CMPB    A, #0a1h
                JGT     dtc03_map_latch
                CMPB    A, #00bh
                JGE     map_neg_helper_call
dtc03_map_latch:
                SB      0b0h.0
                LB      A, off(00237h)
                SJ      map_sign_gate2
map_neg_helper_call:
                CAL     sub_clamp_helper
map_sign_flag_clear:
                RB      0b0h.0
                JBS     off(00212h).2, map_sign_gate3
map_sign_gate2: JBR     off(00212h).4, map_sign_gate4
map_sign_gate3: LB      A, 0d1h
                MOV     X1, #tbl_map_sign
                VCAL    1
map_sign_gate4: STB     A, r0
                LB      A, off(00237h)
                SUBB    A, r0
                MB      off(0021bh).4, C
                JGE     map_delta_store
                VCAL    6
map_delta_store:
                STB     A, 0c0h
                MOV     DP, #00373h
                LB      A, [DP]
                SUBB    A, r0
                MB      off(0021bh).5, C
                JGE     map_delta2_store
                VCAL    6
map_delta2_store:
                STB     A, 0c1h
                LB      A, r0
                STB     A, (00132h-00180h)[USP]
                XCHGB   A, off(00237h)
                XCHGB   A, 0bdh
                DEC     DP
                XCHGB   A, [DP]
                INC     DP
                STB     A, [DP]
                LB      A, #059h
                JBS     off(00212h).2, tps_custom_clamp_store
                JBS     off(00212h).4, tps_custom_clamp_store
                LB      A, 0bch
                SUBB    A, off(00237h)
                JGE     tps_custom_clamp_store
                CLRB    A
tps_custom_clamp_store:
                STB     A, 0beh
                MOV     er0, #04d00h
                RC
                JBS     off(00212h).6, dtc07_tps_latch
                MOV     er0, ADCR7
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc07_tps_latch
                CMPB    r1, #005h
dtc07_tps_latch:
                MB      0b0h.2, C
                JLT     tps_delta_alt_path
                L       A, er0
                SLL     A
                JLT     tps_delta_clamp1
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store1
tps_delta_clamp1:
                LB      A, #0ffh
; --- Repeated rate-of-change/plausibility check pattern applied to several TPS-related raw
; values (0xD0/0xD2/0xD4/0xD6) across 0x852-0x8C9: compute delta, clamp to 0xFF, trigger
; VCAL 7 (erratic-sensor diagnostic, same call used for RPM plausibility earlier) if out of
; range. No calibration anchors; likely dual/redundant TPS channel handling.
tps_delta_store1:
                STB     A, 0d4h
                L       A, er0
                XCHG    A, 0d0h
                MOV     er1, 0d2h
                ST      A, 0d2h
                JBR     off(00212h).6, tps_delta_check1
tps_delta_alt_path:
                L       A, er0
                MOV     er1, 0d0h
tps_delta_check1:
                SUB     A, er0
                MB      PSWL.4, C
                JGE     tps_delta_clamp2
                VCAL    7
tps_delta_clamp2:
                SLL     A
                JLT     tps_delta_clamp2_max
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store2
tps_delta_clamp2_max:
                LB      A, #0ffh
tps_delta_store2:
                STB     A, r0
                MB      C, PSWL.4
                RB      off(0021bh).1
                MB      off(0021bh).1, C
                XCHGB   A, 0d5h
                JEQ     tps_delta_sign_check
                XORB    PSWH, #080h
tps_delta_sign_check:
                JLT     tps_delta_flag_store
                CMPB    A, r0
tps_delta_flag_store:
                MB      off(0021bh).3, C
                L       A, er1
                SUB     A, 0d0h
                MB      off(0021bh).2, C
                JGE     tps_delta_clamp3
                VCAL    7
tps_delta_clamp3:
                SLL     A
                JLT     tps_delta_clamp3_max
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store3
tps_delta_clamp3_max:
                LB      A, #0ffh
tps_delta_store3:
                STB     A, 0d6h
                L       A, off(00296h)
                ST      A, er0
                LB      A, r1
                JBR     off(0021ah).1, tps_delta_compare_final
                LB      A, r0
tps_delta_compare_final:
                CMPB    A, off(00238h)
                MB      off(0021ah).1, C
                LB      A, r1
                JBR     off(0022bh).0, tps_window_calc1
                LB      A, r0
tps_window_calc1:
                ADDB    A, #00dh
                JGE     tps_window_store1
                LB      A, #0ffh
tps_window_store1:
                CMPB    A, off(00238h)
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
tps_window_calc2:
                ADDB    A, r4
                CMPB    A, 0d4h
                MB      off(00218h).2, C
                LB      A, #004h
                JBS     off(00218h).4, tps_window_calc3
                LB      A, #007h
tps_window_calc3:
                ADDB    A, r4
                CMPB    A, 0d4h
                MB      off(00218h).4, C
                LB      A, r2
                MB      C, off(00218h).0
                MB      off(00218h).1, C
                JGE     tps_window_calc4
                MOVB    r0, r1
                LB      A, r3
tps_window_calc4:
                ADDB    A, r4
                CMPB    0d4h, A
                JGE     tps_window_store2
                LB      A, off(00238h)
                CMPB    A, r0
tps_window_store2:
                MB      off(00218h).0, C
                MOVB    r0, 0c0h
                MOVB    r1, off(00237h)
                JBS     off(0021ch).0, tps_interp_exact_match
                JBR     off(0021ah).1, tps_interp_exact_match
                JBS     off(00212h).2, tps_interp_exact_match
                JBS     off(00212h).4, tps_interp_exact_match
                MOVB    r4, #0ffh
                LB      A, 0bdh
                MOV     DP, #tbl_tps_custom_curve2
                MOV     X1, #tbl_tps_custom_curve
                CMPB    A, #0b0h
                JGE     tps_table_offset_check
                INC     DP
                INC     DP
                CMPB    A, #040h
                JGE     tps_table_offset_check
                INC     DP
                INC     DP
tps_table_offset_check:
                JBS     off(0021bh).4, tps_table_lookup
                INC     X1
                INC     X1
                INC     DP
tps_table_lookup:
                LC      A, [X1]
                CMPB    A, r0
                JLT     tps_interp_clamp_check
tps_interp_exact_match:
                LB      A, r1
                SJ      tps_interp_store
tps_interp_clamp_check:
                LB      A, ACCH
                CMPB    A, r0
                JGE     tps_interp_weight_calc
                STB     A, r0
tps_interp_weight_calc:
                LCB     A, [DP]
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
                JBR     off(0021bh).4, tps_interp_sub_check
                ADDB    A, r2
                JLT     tps_interp_clamp_result
                SJ      tps_interp_range_check
tps_interp_sub_check:
                SUBB    A, r2
                JLT     tps_interp_zero_check
tps_interp_range_check:
                CMPB    A, r4
                JLE     tps_interp_store
tps_interp_clamp_result:
                LB      A, r4
                SJ      tps_interp_store
tps_interp_zero_check:
                CLRB    A
                JBS     off(0021bh).4, tps_interp_clamp_result
tps_interp_store:
                STB     A, 0bfh
                L       A, 0c4h
                SUB     A, off(0025ch)
                MB      off(0021ah).4, C
                MOV     er0, #00300h
                JGE     rpm_avg_range_check
                VCAL    7
                MOV     er0, #00300h
rpm_avg_range_check:
                CMP     A, er0
                JLT     rpm_avg_store
                L       A, er0
rpm_avg_store:  ST      A, 0cah
                LB      A, #0cdh
                JBS     off(00218h).5, rpm_avg_store_cmp_acc
                LB      A, #0d0h
rpm_avg_store_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00218h).5, C
                LB      A, #03ah
                JBS     off(00217h).0, rpm_avg_store_cmp_acc_2
                LB      A, #040h
rpm_avg_store_cmp_acc_2:
                CMPB    A, off(00238h)
                MB      off(00217h).0, C
                MOV     X1, #Scaler_RpmAxis_Lo
                MOVB    r3, (001c6h-00180h)[USP]
                MOVB    r2, off(00238h)
                MOVB    r6, #012h
                MB      C, 0b8h.4
                MB      PSWL.4, C
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001c2h-00180h)[USP]
                LB      A, r6
                STB     A, (001c6h-00180h)[USP]
                MOV     X1, #rpm_avg_store_tbl
                MOVB    r3, (001c7h-00180h)[USP]
                MOVB    r2, 0c2h
                MOVB    r6, #012h
                MB      C, 0b8h.3
                JBR     off(00227h).5, rpm_avg_store_store_carry_pswl_bit4
                MOVB    r2, off(00238h)
                MB      C, 0b8h.4
rpm_avg_store_store_carry_pswl_bit4:
                MB      PSWL.4, C
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001c4h-00180h)[USP]
                LB      A, r6
                STB     A, (001c7h-00180h)[USP]
                LB      A, 0bch
                JBS     off(00212h).2, newval_table3_call
                JBS     off(00212h).4, newval_table3_call
                LB      A, 0bfh
newval_table3_call:
                STB     A, r2
                MOV     X1, #newval_table3_call_tbl_3
                MOVB    r3, (001bbh-00180h)[USP]
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001beh-00180h)[USP]
                LB      A, r6
                STB     A, (001bbh-00180h)[USP]
                LB      A, 0bfh
                STB     A, r2
                MOV     X1, #newval_table3_call_tbl_3
                MOVB    r3, (001bch-00180h)[USP]
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001c0h-00180h)[USP]
                LB      A, r6
                STB     A, (001bch-00180h)[USP]
                JBR     off(00216h).7, newval_table3_call_clear_carry
                MB      C, off(00223h).5
                MB      PSWL.4, C
                LB      A, #0ffh
                CMPB    A, off(0029eh)
                MB      off(00223h).5, C
                JGE     newval_table3_call_load_dp
                XORB    PSWL, #010h
newval_table3_call_load_dp:
                MOV     DP, #003eeh
                LB      A, #0ffh
                JBS     off(0021dh).6, newval_table3_call_store_ram29c
                LB      A, off(0029ch)
                JNE     newval_table3_call_subb_acc
                CLR     A
                ST      A, [DP]
newval_table3_call_clear_carry:
                RC
                SJ      newval_table3_call_store_carry_ram219_bit6
newval_table3_call_subb_acc:
                SUBB    A, #001h
newval_table3_call_store_ram29c:
                STB     A, off(0029ch)
                MOV     X1, #newval_table3_call_tbl
                JBS     off(00223h).5, newval_table3_call_load_carry_pswl_bit4
                INC     DP
                MOV     X1, #newval_table3_call_tbl_2
newval_table3_call_load_carry_pswl_bit4:
                MB      C, PSWL.4
                JGE     newval_table3_call_load_carry_ram223_bit5
                LB      A, off(00237h)
                VCAL    1
                STB     A, [DP]
newval_table3_call_load_carry_ram223_bit5:
                MB      C, off(00223h).5
                LB      A, [DP]
                JEQ     newval_table3_call_store_carry_ram219_bit6
                DECB    [DP]
                XORB    PSWH, #080h
newval_table3_call_store_carry_ram219_bit6:
                MB      off(00219h).6, C
                CLR     er2
                SC
                JBR     off(00227h).6, mode_flags_pack4
                LB      A, (001bbh-00180h)[USP]
                ADDB    A, #001h
                CMPB    0bfh, #000h
                JNE     mode_flags_pack_start
                CLRB    A
mode_flags_pack_start:
                MOV     er0, off(00212h)
                AND     er0, #0c3bch
                JNE     mode_flags_pack_alt
                JBR     off(00214h).5, mode_flags_pack_store
mode_flags_pack_alt:
                LB      A, #00fh
mode_flags_pack_store:
                STB     A, r1
                RC
                JBS     off(00214h).5, mode_flags_pack2
                MB      C, off(00211h).1
mode_flags_pack2:
                MB      off(00233h).3, C
                MB      C, off(0021ch).2
                MB      off(00233h).4, C
                SC
                LB      A, (0019ch-00180h)[USP]
                JNE     mode_flags_pack3
                LB      A, off(0023eh)
                JNE     mode_flags_pack3
                MB      C, off(00220h).1
mode_flags_pack3:
                MB      off(00233h).5, C
                LB      A, off(00233h)
                MOVB    r0, #010h
                MULB
                ORB     A, r1
                L       A, ACC
                ST      A, er2
                MOV     er0, #00101h
                MOVB    r2, #005h
scale_div32_loop:
                SRL     A
                ADCB    r0, #000h
                SRL     A
                ADCB    r1, #000h
                DECB    r2
                JNE     scale_div32_loop
                SRLB    r0
                MB      r5.2, C
                SRLB    r1
                MB      r5.3, C
                LB      A, (001afh-00180h)[USP]
                CMPB    A, #007h
                JLT     mode_flags_pack4
                LB      A, (001b7h-00180h)[USP]
                CMPB    A, #019h
                JLT     mode_flags_pack4
                MB      C, off(0021dh).7
mode_flags_pack4:
                MB      off(00233h).6, C
                L       A, er2
                ST      A, 0eah
                MOV     DP, #003c6h
                LB      A, ADCR0H
                STB     A, [DP]
                STB     A, 0dah
                MOV     DP, #003ceh
                LB      A, ADCR1H
                STB     A, [DP]
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      ADSCAN.4
                ORB     P2, off(00259h)
                RB      IRQH.4
                SB      ADSCAN.4
                MOV     off(0025ah), TM2
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JBS     off(0021dh).4, ignmap_alt_path
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, (001bbh-00180h)[USP]
                MOV     X2, (001beh-00180h)[USP]
                JBS     off(00227h).5, mode_flags_pack4_load_r3
                MOVB    r3, (001c6h-00180h)[USP]
                MOV     er3, (001c2h-00180h)[USP]
                MOV     X1, #mode_flags_pack4_tbl
                JBR     off(00214h).5, mode_flags_pack4_load_dp
                JBS     off(00218h).5, ignmap_2d_lookup
mode_flags_pack4_load_dp:
                MOV     DP, #mode_flags_pack4_tbl_3
                MOVB    r4, #000h
                JBR     off(0021fh).1, mode_flags_pack4_nop_acc
mode_flags_pack4_load_r3:
                MOVB    r3, (001c7h-00180h)[USP]
                MOV     er3, (001c4h-00180h)[USP]
                MOV     X1, #mode_flags_pack4_tbl_2
                MOV     DP, #mode_flags_pack4_tbl_4
                MOVB    r4, #000h
mode_flags_pack4_nop_acc:
                NOP
                NOP
                NOP
                JBR     off(00219h).6, ignmap_2d_lookup
                LB      A, r4
                CMPB    A, r3
                JGT     ignmap_2d_lookup
                ADDB    A, #00ah
                CMPB    A, r3
                JLE     ignmap_2d_lookup
                LB      A, r4
                SUBB    r3, A
                MOVB    r1, #00bh
                MOV     X1, DP
ignmap_2d_lookup:
                RB      PSWL.5
                CAL     table2d_lookup_interp
                MOVB    r0, A
                LB      A, off(00247h)
                JEQ     ignmap_scale_skip
                MULB
                MOVB    r0, ACCH
ignmap_scale_skip:
                LB      A, r0
                SJ      ignmap_result_common
ignmap_alt_path:
                LB      A, 0c2h
                MOV     X1, #ignmap_alt_path_tbl
                JBS     off(0021fh).1, ignmap_alt_path_call_table_interp_lookup
                LB      A, off(00238h)
                MOV     X1, #ignmap_alt_path_tbl_2
ignmap_alt_path_call_table_interp_lookup:
                CAL     table_interp_lookup
ignmap_result_common:
                STB     A, off(00248h)
                CLRB    A
                CMPB    0d9h, #02eh
                JGE     idleign_result_store
                JBR     off(00218h).0, idleign_result_store
                JBS     off(00210h).7, idleign_result_store
                L       A, 0cah
                MOV     X1, #IgnControl
                JBS     off(0021ah).4, idleign_table_lookup
                MOV     X1, #HiIdleIgnControl
idleign_table_lookup:
                CAL     table_interp_lookup_4byte
                MOVB    r0, #011h
                LB      A, r6
                CMPB    A, r0
                JLT     idleign_vcal6_check
                LB      A, r0
idleign_vcal6_check:
                JBR     off(0021ah).4, idleign_result_store
                VCAL    6
idleign_result_store:
                STB     A, off(00243h)
                LB      A, #01eh
                JBS     off(00221h).3, rpm_threshold_221_3
                LB      A, #010h
rpm_threshold_221_3:
                CMPB    0c5h, A
                MB      off(00221h).3, C
                LB      A, #000h
                JBS     off(00221h).4, rpm_threshold_221_3_cmp_acc
                LB      A, #001h
rpm_threshold_221_3_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00221h).4, C
                CLRB    A
                MOV     X1, #tbl_ignmap_idle2
                JBS     off(00221h).2, knockretard_table_gate
                INC     X1
                INC     X1
                MB      C, off(00221h).3
knockretard_table_gate:
                JGE     knockretard_store
                L       A, off(00254h)
                ST      A, er3
                LB      A, off(00237h)
                CAL     knockretard_helper
                JBR     off(00221h).2, knockretard_store
                VCAL    6
knockretard_store:
                STB     A, off(00242h)
                LB      A, #046h
                JBS     off(00222h).5, knockretard_store_cmp_acc
                LB      A, #053h
knockretard_store_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00222h).5, C
                CLRB    A
                JBR     off(00227h).7, knockretard2_clamp_store_ram23a
                JBS     off(00213h).1, knockretard2_clamp_store_ram23a
                JGE     knockretard2_clamp_store_ram23a
                CMPB    0d8h, #0b5h
                JGE     knockretard2_clamp_store_ram23a
                JBS     off(0021dh).5, knockretard2_clamp_store_ram23a
                JBS     off(0021ah).3, knockretard2_clamp_store_ram23a
                JBR     off(0021ah).2, knockretard2_clamp_store_ram23a
                CLR     A
                LB      A, off(00256h)
                MOV     er3, A
                LB      A, off(00237h)
                MOV     X1, #tbl_ignmap_idle1
                CAL     knockretard_helper
                LB      A, off(0023ah)
                ADDB    A, #001h
                JLT     knockretard2_clamp
                CMPB    A, r6
                JLT     knockretard2_clamp_store_ram23a
knockretard2_clamp:
                LB      A, r6
knockretard2_clamp_store_ram23a:
                STB     A, off(0023ah)
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram2b8
                LB      A, #06dh
                JBS     off(00216h).3, overrev_hardcap_compare
                LB      A, #06dh
overrev_hardcap_compare:
                CMPB    A, off(00238h)
                JLT     overrev_hardcap_compare_load_ram2b8
                LB      A, 0cch
                CMPB    A, #02dh
                JGE     overrev_hardcap_compare_load_ram2b8
                CMPB    A, #023h
                JLT     overrev_hardcap_compare_load_ram2b8
                CMPB    0d9h, #028h
                JGE     overrev_hardcap_compare_load_ram2b8
                CMPB    off(00237h), #064h
                JGE     overrev_hardcap_compare_load_ram2b8
                JBR     off(0021ah).3, overrev_hardcap_compare_cmp_ram2b8
overrev_hardcap_compare_load_ram2b8:
                MOVB    off(002b8h), #060h
                CLRB    A
                STB     A, r0
                RB      off(00222h).6
                SJ      overrev_hardcap_compare_store_ram253
overrev_hardcap_compare_cmp_ram2b8:
                CMPB    off(002b8h), #00ch
                JGE     knockretard2_store_clear_acc
                LB      A, off(002b8h)
                JEQ     overrev_hardcap_compare_cmp_acc
                MOVB    off(002b7h), #060h
                SJ      overrev_hardcap_compare_load_r0
overrev_hardcap_compare_cmp_acc:
                CMPB    A, off(002b7h)
                MB      off(00222h).6, C
overrev_hardcap_compare_load_r0:
                MOVB    r0, off(0023bh)
                LB      A, off(00253h)
                JEQ     overrev_hardcap_compare_addb_r0
                SUBB    A, #001h
                SJ      overrev_hardcap_compare_store_ram253
overrev_hardcap_compare_addb_r0:
                ADDB    r0, #002h
                LB      A, #004h
overrev_hardcap_compare_store_ram253:
                STB     A, off(00253h)
                LB      A, #015h
                CMPB    A, r0
                JLE     knockretard2_store
                LB      A, r0
knockretard2_store:
                STB     A, off(0023bh)
knockretard2_store_clear_acc:
                CLRB    A
                RC
                JBS     off(00233h).6, flags_pack_233_7
                JBS     off(00212h).3, flags_pack_233_7
                JBS     off(00213h).0, flags_pack_233_7
                L       A, 0ech
                ST      A, er2
                CLR     er0
                MOVB    r2, #005h
scale_shift_loop:
                SLL     A
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
scale_direction_toggle:
                XORB    PSWH, #080h
scale_result_common:
                LB      A, r5
flags_pack_233_7:
                MB      off(00233h).7, C
                SRLB    A
                MB      off(00232h).7, C
                STB     A, r5
                CLRB    A
                JBR     off(00227h).6, knock_244_store
                CMPB    0c5h, #000h
                JGT     knock_244_store
                LB      A, 0eah
                ANDB    A, #00fh
                CMPB    A, #00fh
                JEQ     knock_244_table_select
                JBS     off(00214h).7, knock_244_table_select
                JBS     off(00233h).6, knockretard_clear_state
                JBS     off(00233h).7, knockretard_clear_state
                LB      A, r5
                SJ      knock_244_store
knock_244_table_select:
                LB      A, (001c7h-00180h)[USP]
                MOV     er0, (001c4h-00180h)[USP]
                MOV     DP, #tbl_knock244_a
                JBS     off(0021fh).1, knock_244_table_select_call_knock_244_helper
                LB      A, (001c6h-00180h)[USP]
                MOV     er0, (001c2h-00180h)[USP]
                MOV     DP, #tbl_knock244_b
knock_244_table_select_call_knock_244_helper:
                CAL     knock_244_helper
knock_244_store:
                STB     A, off(00246h)
knockretard_clear_state:
                LB      A, #07fh
                JBS     off(00221h).6, knockretard_clear_state_cmp_acc
                LB      A, #07fh
knockretard_clear_state_cmp_acc:
                CMPB    A, off(00246h)
                MB      off(00221h).6, C
                CLRB    A
                CMPB    (0019ch-00180h)[USP], #001h
                JNE     knockretard_clear_state_cmp_stk
                MOV     X1, #knockretard_clear_state_tbl
                MB      C, 0b8h.6
                JGE     knockretard_clear_state_if_ram221_bit6_clr
                MOV     X1, #knockretard_clear_state_tbl_2
knockretard_clear_state_if_ram221_bit6_clr:
                JBR     off(00221h).6, knockretard_clear_state_load_ram238
                ADD     X1, #0002ch
knockretard_clear_state_load_ram238:
                LB      A, off(00238h)
                CAL     table_interp_lookup
                SJ      knockretard_clear_state_store_ram23d
knockretard_clear_state_cmp_stk:
                CMPB    (0019ch-00180h)[USP], #003h
                JNE     knockretard_clear_state_store_ram23d
                LB      A, #000h
                CMPB    0d9h, #0ffh
                JGE     knockretard_clear_state_store_ram23d
                LB      A, #0ffh
knockretard_clear_state_store_ram23d:
                STB     A, off(0023dh)
                LB      A, #03ah
                MOVB    r0, #040h
                CMPB    0bch, #0dbh
                JGE     knockretard_clear_state_if_ram222_bit0_set
                LB      A, #093h
                MOVB    r0, #097h
knockretard_clear_state_if_ram222_bit0_set:
                JBS     off(00222h).0, knockretard_clear_state_cmp_acc_2
                LB      A, r0
knockretard_clear_state_cmp_acc_2:
                CMPB    A, off(00238h)
                MB      off(00222h).0, C
                CLRB    A
                JBR     off(0021dh).5, knockretard_clear_state_store_ram241
                JGE     knockretard_clear_state_store_ram241
                MOV     X1, #knockretard_clear_state_tbl_3
                JBR     off(0021eh).3, knockretard_clear_state_load_ram238_2
                MOV     X1, #knockretard_clear_state_tbl_4
knockretard_clear_state_load_ram238_2:
                LB      A, off(00238h)
                CAL     table_interp_lookup
knockretard_clear_state_store_ram241:
                STB     A, off(00241h)
                LB      A, #05ah
                JBS     off(00222h).1, knockretard_clear_state_cmp_acc_3
                LB      A, #060h
knockretard_clear_state_cmp_acc_3:
                CMPB    A, off(00238h)
                MB      off(00222h).1, C
                LB      A, 0d1h
                MOVB    r0, #09ah
                MOVB    r1, #024h
                JBS     off(00222h).2, knockretard_clear_state_cmp_acc_4
                MOVB    r0, #097h
                MOVB    r1, #026h
knockretard_clear_state_cmp_acc_4:
                CMPB    A, r0
                JGE     knockretard_clear_state_store_carry_ram222_bit2
                CMPB    r1, A
knockretard_clear_state_store_carry_ram222_bit2:
                MB      off(00222h).2, C
                CLRB    A
                JBR     off(00216h).3, knockretard_clear_state_store_ram23e
                JBS     off(00211h).5, knockretard_clear_state_store_ram23e
                J       knockretard_clear_state_if_ram235_bit3_set
knockretard_clear_state_if_ram21d_bit4_set:
                JBS     off(0021dh).4, knockretard_clear_state_store_ram23e
                JBR     off(00211h).4, knockretard_clear_state_store_ram23e
                CMPB    0d9h, #02eh
                JGE     knockretard_clear_state_store_ram23e
                JBS     off(0021ah).2, knockretard_clear_state_store_ram23e
                JBR     off(00222h).1, knockretard_clear_state_store_ram23e
                JBR     off(00222h).2, knockretard_clear_state_store_ram23e
                LB      A, 0d1h
                MOV     X1, #knockretard_clear_state_tbl_5
                CAL     table_interp_lookup
knockretard_clear_state_store_ram23e:
                STB     A, off(0023eh)
                LB      A, #029h
                JBS     off(00222h).3, callhelper_table_interp_lookup
                LB      A, #022h
callhelper_table_interp_lookup:
                CMPB    0beh, A
                MB      off(00222h).3, C
                CLRB    A
                JLT     callhelper_table_interp_lookup_store_ram23f
                CMPB    0d9h, #034h
                JGE     callhelper_table_interp_lookup_store_ram23f
                JBS     off(0021dh).5, callhelper_table_interp_lookup_store_ram23f
                LB      A, off(00238h)
                MOV     X1, #callhelper_table_interp_lookup_tbl
                CAL     table_interp_lookup
callhelper_table_interp_lookup_store_ram23f:
                STB     A, off(0023fh)
                MOV     X1, #TipinTPS
                LB      A, off(00238h)
                CAL     table_interp_lookup
                CMPB    A, 0d3h
                MB      off(00231h).6, C
                L       A, off(00212h)
                AND     A, #08074h
                JNE     tipin_gate_fail
                JBS     off(00214h).0, tipin_gate_fail
                JBS     off(0021dh).4, tipin_gate_fail
                JBS     off(00216h).3, tipin_gate_fail
                CMPB    0d9h, #03ch
                JGE     tipin_gate_fail
                LB      A, 0cch
                CMPB    A, #005h
                JLT     tipin_gate_fail
                CMPB    A, #078h
                JGE     tipin_gate_fail
                LB      A, off(00238h)
                CMPB    A, #033h
                JLT     tipin_gate_fail
                CMPB    A, #0c0h
                JGE     tipin_gate_fail
                JBS     off(00220h).0, tipin_gate_pass
                JBR     off(00231h).6, tipin_gate2
                LB      A, off(00239h)
                JNE     tipin_decay_check
tipin_gate_fail:
                RB      off(00220h).0
                RB      off(00220h).2
                SJ      tipin_decay_zero
tipin_gate2:    JBR     off(0021bh).1, tipin_decay_zero
                CMPB    0d5h, #010h
                JLT     tipin_decay_zero
tipin_gate_pass:
                SB      off(00220h).0
                JBS     off(0021bh).6, tipin_enrich_lookup
                CMP     0c6h, #0ffffh
                JGE     tipin_decay_zero
tipin_enrich_lookup:
                LB      A, off(00251h)
                EXTND
                LCB     A, tipin_enrich_lookup_tbl[ACC]
                MOVB    off(00250h), A
                MOV     X1, #TipinRPM
                LB      A, off(00238h)
                CAL     table_interp_lookup
                MOVB    r0, off(00252h)
                MULB
                L       A, ACC
                SLL     A
                JGE     tipin_enrich_clamp
                L       A, #0ffffh
tipin_enrich_clamp:
                LB      A, ACCH
                RB      off(00220h).0
tipin_decay_check:
                CMPB    off(00250h), #000h
                JEQ     tipin_decay_gate1
                DECB    off(00250h)
                MOVB    r0, #001h
                SJ      tipin_decay_sub
tipin_decay_gate1:
                JBS     off(0021bh).6, tipin_decay_gate2
                CMP     0c6h, #00010h
                JLT     tipin_decay_gate3
                RB      off(00220h).2
tipin_decay_common:
                RC
                SJ      tipin_decay_flag3
tipin_decay_gate2:
                CMP     0c6h, #00003h
                JGE     tipin_decay_gate4
tipin_decay_gate3:
                JBS     off(00220h).2, tipin_decay_common
                SJ      tipin_decay_sc
tipin_decay_gate4:
                SB      off(00220h).2
tipin_decay_sc: SC
tipin_decay_flag3:
                MB      off(00220h).3, C
                JGE     tipin_decay_rc
                MOVB    r0, #004h
tipin_decay_sub:
                SUBB    A, r0
                JLT     tipin_decay_zero
                SC
                SJ      tipin_decay_store
tipin_decay_zero:
                CLRB    A
tipin_decay_rc: RC
tipin_decay_store:
                STB     A, off(00239h)
                MB      off(00220h).1, C
                LB      A, #0feh
                JBS     off(00222h).4, knock244_threshold_check
                LB      A, #0ffh
knock244_threshold_check:
                CMPB    A, off(00246h)
                MB      off(00222h).4, C
                MOVB    r0, #040h
                MOVB    r1, #003h
                MOVB    r2, #024h
                MOVB    r3, #010h
                JGE     dwellbase_gate1
                MOVB    r0, #040h
                MOVB    r1, #003h
                MOVB    r2, #024h
                MOVB    r3, #010h
dwellbase_gate1:
                JBS     off(00212h).6, gate_255_common
                JBS     off(0021dh).4, gate_255_common
                CMPB    0d9h, #028h
                JGE     gate_255_common
                LB      A, r0
                CMPB    A, off(00238h)
                JLT     gate_255_common
                JBS     off(00231h).6, gate_255_common
                CLRB    A
                JBR     off(0021bh).1, store_255_result
                CMPB    0d5h, #018h
                JLT     store_255_result
                LB      A, r1
                ADDB    A, #001h
store_255_result:
                STB     A, off(00257h)
gate_255_common:
                LB      A, r2
                CMPB    off(00257h), #000h
                JEQ     track239e_check
                DECB    off(00257h)
                SJ      dwell_base_lookup
track239e_check:
                LB      A, off(00240h)
                SUBB    A, r3
                JGE     dwell_base_lookup
                CLRB    A
dwell_base_lookup:
                STB     A, off(00240h)
                J       dwell_base_lookup_rom_load_tbl_7cb8
                DW  0ffffh
dwell_base_lookup_call_table_interp_lookup:
                CAL     table_interp_lookup
                STB     A, off(00249h)
                LB      A, 0c2h
                MOV     X1, #DwellBaseValues
                CAL     table_interp_lookup
                MOV     DP, #0035ah
                STB     A, [DP]
                STB     A, r0
                LB      A, off(0024dh)
                MULB
                L       A, ACC
                ST      A, er1
                CAL     dwell_scale_helper
                ST      A, off(0024eh)
                LB      A, #0ffh
                JBS     off(00221h).5, dwell_base_lookup_cmp_acc
                LB      A, #0ffh
dwell_base_lookup_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00221h).5, C
                L       A, er1
                JLT     dwell_scale_shift
                SRL     A
dwell_scale_shift:
                SRL     A
                CAL     dwell_scale_helper
                ST      A, off(0024fh)
                MOV     DP, #dwell_scale_shift_tbl
                MOV     er0, (001c4h-00180h)[USP]
                LB      A, (001c7h-00180h)[USP]
                JBS     off(0021fh).1, dwell_scale_shift_if_ram21d_bit4_clr
                MOV     DP, #dwell_scale_shift_tbl_2
                MOV     er0, (001c2h-00180h)[USP]
                LB      A, (001c6h-00180h)[USP]
dwell_scale_shift_if_ram21d_bit4_clr:
                JBR     off(0021dh).4, dwell_scale_shift_call_knock_244_helper
                ADD     DP, #00014h
dwell_scale_shift_call_knock_244_helper:
                CAL     knock_244_helper
                STB     A, off(0024ch)
                CLR     A
                ST      A, er3
                JBS     off(00212h).5, ign_sum_stage4
                JBR     off(00220h).1, ignsum_er3_start
                LB      A, 0d1h
                MOV     X1, #TipinRetard
                CAL     table_interp_lookup
                MOVB    r0, off(00239h)
                MULB
                L       A, ACC
                SLL     A
                MOVB    r6, ACCH
                CLRB    r7
                CLR     A
ignsum_er3_start:
                LB      A, off(0023ah)
                ADD     er3, A
                LB      A, off(0023bh)
                ADD     er3, A
                LB      A, off(0023ch)
                ADD     er3, A
                LB      A, off(0023dh)
                ADD     er3, A
                LB      A, off(0023eh)
                ADD     er3, A
                LB      A, off(0023fh)
                ADD     er3, A
                LB      A, off(00240h)
                ADD     er3, A
                JBR     off(00234h).4, ignsum_er3_start_cmp_ram0d9
                LB      A, #040h
                ADD     er3, A
ignsum_er3_start_cmp_ram0d9:
                CMPB    0d9h, #034h
                JGE     ignsum_er3_start_goto_7c94
                JBR     off(00218h).0, ignsum_er3_start_goto_7c94
                LB      A, #00ch
                ADD     er3, A
ignsum_er3_start_goto_7c94:
                J       ignsum_er3_start_load_ram2ff
ignsum_er3_start_load_acc:
                L       A, ACC
                SUB     A, er3
                ST      A, er3
                LB      A, off(00242h)
                EXTND
                ADD     er3, A
                LB      A, off(00243h)
                EXTND
                ADD     er3, A
                LB      A, off(00244h)
                EXTND
                ADD     er3, A
ign_sum_stage4: LB      A, off(00245h)
                EXTND
                ADD     er3, A
                CLR     A
                LB      A, off(00246h)
                SUB     er3, A
                CLR     A
                LB      A, off(00248h)
                STB     A, r0
                L       A, ACC
                ADD     A, er3
                JBR     off(00207h).7, ign_sum_clamp_check
                JLT     ign_sum_result
                CLRB    A
                SJ      ign_sum_result
ign_sum_clamp_check:
                CMP     A, #000ffh
                JLT     ign_sum_result
                LB      A, #0ffh
ign_sum_result: LB      A, ACC
                STB     A, r4
                LB      A, #040h
                JBS     off(00234h).5, ign_sum_common
                LB      A, #04dh
ign_sum_common: CMPB    A, off(00238h)
                MB      off(00234h).5, C
                LB      A, #040h
                SC
                JBS     off(00212h).5, ign_p40_flag_store
                CMPB    0d9h, #0d0h
                JLT     ign_p40_flag_store
                MB      C, P4.0
                JLT     ign_p40_store
                JBS     off(00221h).7, ign_result_clamp249
                LB      A, #000h
                MB      C, off(0021eh).0
                JLT     ign_p40_store
                JBS     off(00234h).5, ign_p40_toggle
                LB      A, off(0024bh)
                ADDB    A, #002h
                JGE     ign_p40_clamp
                LB      A, #0ffh
ign_p40_clamp:  CMPB    A, r4
                JGE     ign_p40_toggle
                STB     A, r4
ign_p40_store:  STB     A, off(0024bh)
ign_p40_toggle: XORB    PSWH, #080h
ign_p40_flag_store:
                MB      off(00221h).7, C
ign_result_clamp249:
                MOVB    r3, off(0024ch)
                LB      A, r4
                CMPB    A, r3
                JGE     ign_result_clamp_common
                LB      A, r3
ign_result_clamp_common:
                RC
                JBS     off(00217h).0, ign_flag_217_1
                LB      A, ACC
                JNE     ign_flag_217_1
                SC
ign_flag_217_1: MB      off(00217h).1, C
                MOV     DP, #0035bh
                JBS     off(0021eh).0, ign_result_zero
                JBR     off(00217h).1, ign_flag_217_1_store_dp_ind
ign_result_zero:
                CLRB    A
                STB     A, [DP]
                STB     A, off(0024ah)
                SJ      igntiming_cylinder_trim_add
ign_flag_217_1_store_dp_ind:
                STB     A, [DP]
                ADDB    A, off(00249h)
                JGE     ignmap_disable_check
                LB      A, #0ffh
ignmap_disable_check:
                STB     A, off(0024ah)
igntiming_cylinder_trim_add:
                MOVB    r2, off(0024ah)
                MOVB    r4, off(0024eh)
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
                MOVB    r4, off(0024fh)
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
                SC
                JBR     off(0011eh).6, igntiming_enable_pin_drive
                JBR     off(00121h).2, igntiming_enable_pin_drive
                MB      C, 0b8h.2
                XORB    PSWH, #080h
igntiming_enable_pin_drive:
                MB      P1.2, C
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
                L       A, #00ea6h
vtec_rawperiod_threshold_check:
                CMP     0c4h, A
                MB      off(00129h).1, C
                JBR     off(0011eh).5, vtec_state_reset_low_rpm
                LB      A, ADCR5H
                STB     A, 0d7h
                LB      A, #0ffh
                JBS     off(00126h).2, vtec_rawperiod_threshold_check_cmp_acc
                LB      A, #0ffh
vtec_rawperiod_threshold_check_cmp_acc:
                CMPB    A, off(00132h)
                MB      off(00126h).2, C
                LB      A, #0ffh
                JBS     off(00131h).6, vtec_rawperiod_threshold_check_cmp_acc_2
                LB      A, #0ffh
vtec_rawperiod_threshold_check_cmp_acc_2:
                CMPB    A, off(00133h)
                MB      off(00131h).6, C
                LB      A, #0ffh
                JBS     off(00131h).7, vtec_rawperiod_threshold_check_cmp_acc_3
                LB      A, #0ffh
vtec_rawperiod_threshold_check_cmp_acc_3:
                CMPB    A, off(00132h)
                MB      off(00131h).7, C
                LB      A, #0ffh
                JBS     off(0011fh).5, vtec_state_reset_low_rpm
                JBR     off(00122h).6, vtec_state_reset_low_rpm
                JBS     off(00122h).7, vtec_state_reset_low_rpm
                JBR     off(00126h).2, vtec_state_reset_low_rpm
                JBS     off(00120h).2, vtec_oilpressure_gate_check
vtec_state_reset_low_rpm:
                MOVB    off(001e2h), #0ffh
                J       vtec_state_clear
vtec_oilpressure_gate_check:
                JBR     off(0011dh).1, vtec_debounce_counter_check
                J       vtec_oilpressure_pin_check
vtec_debounce_counter_check:
                CMPB    0d7h, #0ffh
                JGT     vtec_oilpressure_pin_check
                CMPB    0d7h, #000h
                JLT     vtec_oilpressure_pin_check
                STB     A, off(001e2h)
                MOVB    r1, off(0019ch)
                LB      A, off(0019ah)
                JNE     vtec_debounce_step_calc
                CLRB    r0
                JBR     off(00131h).6, vtec_debounce_counter_check_if_ram131_bit7_clr
                INCB    r0
                INCB    r0
vtec_debounce_counter_check_if_ram131_bit7_clr:
                JBR     off(00131h).7, to_vtec_debounce_store
                INCB    r0
to_vtec_debounce_store:
                CLRB    r1
                CMPB    0d7h, #0ffh
                JLE     to_vtec_debounce_store_load_imm
                LB      A, r0
                EXTND
                ADD     A, #to_vtec_debounce_store_tbl
                MOV     DP, A
                INCB    r1
                LB      A, 0d7h
                RB      0b8h.6
                CMPCB   A, [DP]
                JLE     to_vtec_debounce_store_load_imm
                SB      0b8h.6
                ADD     DP, #00004h
                CMPCB   A, [DP]
                JLE     to_vtec_debounce_store_load_imm
                ADD     DP, #00004h
                INCB    r1
                JBS     off(0011ah).3, to_vtec_debounce_store_load_imm
                JBS     off(0011ah).7, to_vtec_debounce_store_load_imm
to_vtec_debounce_store_cmp_acc:
                CMPCB   A, [DP]
                JLE     to_vtec_debounce_store_load_imm
to_vtec_debounce_store_add_dp:
                ADD     DP, #00004h
                INCB    r1
                CMPB    r1, #004h
                JNE     to_vtec_debounce_store_cmp_r1
                CMPB    0d9h, #0ffh
                JGE     to_vtec_debounce_store_add_dp
to_vtec_debounce_store_cmp_r1:
                CMPB    r1, #007h
                JLT     to_vtec_debounce_store_cmp_acc
to_vtec_debounce_store_load_imm:
                LB      A, #0ffh
                SJ      vtec_debounce_store
vtec_debounce_step_calc:
                SUBB    A, #001h
                JBR     off(00124h).0, vtec_debounce_store
                SUBB    A, #001h
                JLT     vtec_debounce_zero
                JBR     off(00124h).1, vtec_debounce_store
                SUBB    A, #002h
                JGE     vtec_debounce_store
vtec_debounce_zero:
                CLRB    A
vtec_debounce_store:
                STB     A, off(0019ah)
                SJ      vtec_rpm_valid_check
vtec_oilpressure_pin_check:
                MB      C, P4.6
                JGE     vtec_state_dispatch
                STB     A, off(001e2h)
vtec_state_reset_no_pressure:
                MOVB    off(001e3h), #0ffh
                MOVB    r1, #004h
                SJ      vtec_rpm_valid_check
vtec_state_dispatch:
                LB      A, off(001e2h)
                JNE     vtec_state_reset_no_pressure
                LB      A, off(001e3h)
                JEQ     vtec_state_clear
                MOVB    r1, #002h
vtec_rpm_valid_check:
                CMPB    off(00133h), #0ffh
                JLT     vtec_state_hold_check
                LB      A, r1
                CMPB    A, #001h
                JLE     vtec_state_active_check
                MOVB    off(001dah), #0ffh
                SJ      vtec_state_store
vtec_state_hold_check:
                JBS     off(00125h).4, vtec_state_confirm
                SJ      vtec_state_clear
vtec_state_active_check:
                JBR     off(00125h).4, vtec_state_finalize
vtec_state_confirm:
                LB      A, off(001dah)
                JEQ     vtec_state_finalize
                MOVB    r1, #002h
                CLRB    off(0019ah)
vtec_state_store:
                LB      A, r1
                STB     A, off(0019ch)
                SB      off(00125h).4
                JNE     vtec_retard_timer_check
                MOVB    off(0019eh), #00ch
                CLRB    off(0019dh)
vtec_retard_timer_check:
                CMPB    off(0019eh), #008h
                JGT     vtec_retard_lookup_done
                CLR     A
                LB      A, r1
                SUBB    A, #002h
                MOV     DP, #tbl_vtec_transition_retard
                ADD     DP, A
                LCB     A, [DP]
                STB     A, off(0019dh)
vtec_retard_lookup_done:
                SJ      vtec_engage_gate_start
vtec_state_clear:
                CLRB    r1
vtec_state_finalize:
                RB      off(00125h).4
                CLRB    A
                STB     A, off(0019ah)
                CMPB    r1, #001h
                JNE     vtec_state_store2
                LB      A, r1
vtec_state_store2:
                STB     A, off(0019ch)
vtec_engage_gate_start:
                JBR     off(0011eh).4, vtec_disengage_output
                LB      A, #005h
                MOVB    r0, #014h
                JBS     off(00131h).0, vtec_engage_gate_start_if_ram11e_bit3_set
                LB      A, #00ah
                MOVB    r0, #019h
vtec_engage_gate_start_if_ram11e_bit3_set:
                JBS     off(0011eh).3, vtec_engage_gate_start_cmp_acc
                LB      A, r0
vtec_engage_gate_start_cmp_acc:
                CMPB    A, 0cch
                MB      off(00131h).0, C
                MOV     DP, #vtec_engage_gate_start_tbl
                MOV     X1, #vtec_engage_gate_start_tbl_3
                JBS     off(0011eh).3, vtec_engage_gate_start_rom_load_dp_ind
                MOV     DP, #vtec_engage_gate_start_tbl_2
                MOV     X1, #vtec_engage_gate_start_tbl_4
vtec_engage_gate_start_rom_load_dp_ind:
                LC      A, [DP]
                INC     DP
                INC     DP
                JBS     off(00131h).1, vtec_rpm_vs_settings_check
                LB      A, ACCH
vtec_rpm_vs_settings_check:
                CMPB    A, off(00133h)
                MB      off(00131h).1, C
                LC      A, [DP]
                JBS     off(00131h).2, vtec_rpm_vs_settings_check_cmp_acc
                LB      A, ACCH
vtec_rpm_vs_settings_check_cmp_acc:
                CMPB    A, off(00133h)
                MB      off(00131h).2, C
                LB      A, off(00133h)
                CAL     table_interp_lookup
                STB     A, off(00198h)
                L       A, off(0011ah)
                AND     A, #0c0bch
                JNE     vtec_disengage_output
                LB      A, off(0011ch)
                ANDB    A, #031h
                JEQ     vtec_engage_conditions_start
vtec_disengage_output:
                RB      P1.1
                SJ      vtec_highcam_output
vtec_engage_conditions_start:
                SB      P1.1
                CMPB    0f3h, #032h
                JLT     vtec_highcam_output
                CMPB    0d9h, #044h
                JGE     vtec_highcam_output
                LCB     A, vtec_engage_conditions_start_tbl
                JNE     vtec_engage_conditions_start_if_ram11e_bit3_clr
                JBR     off(00131h).0, vtec_highcam_output
vtec_engage_conditions_start_if_ram11e_bit3_clr:
                JBR     off(0011eh).3, vtec_engage_conditions_start_if_ram131_bit1_set
                JBS     off(00119h).5, vtec_engage_conditions_start_if_ram127_bit1_set
vtec_engage_conditions_start_if_ram131_bit1_set:
                JBS     off(00131h).1, vtec_engage_conditions_start_load_ram198
vtec_engage_conditions_start_if_ram127_bit1_set:
                JBS     off(00127h).1, vtec_engage_conditions_start_clear_ram1df
vtec_highcam_output:
                RB      P1.0
                RB      off(00127h).2
                SJ      vtec_highcam_output_load_ram1d8
vtec_engage_conditions_start_load_ram198:
                LB      A, off(00198h)
                SUBB    A, off(00199h)
                JLT     vtec_engage_conditions_start_clear_acc
                JBR     off(00127h).2, vtec_engage_conditions_start_cmp_acc
                SUBB    A, #008h
                JGE     vtec_engage_conditions_start_cmp_acc
vtec_engage_conditions_start_clear_acc:
                CLRB    A
vtec_engage_conditions_start_cmp_acc:
                CMPB    A, off(00132h)
                JLT     vtec_engage_conditions_start_load_ram1df
                JBS     off(00131h).2, vtec_engage_conditions_start_load_ram1df
                LB      A, off(001dfh)
                JNE     vtec_engage_conditions_start_set_p1_bit0
vtec_engage_conditions_start_clear_ram1df:
                CLRB    off(001dfh)
                RB      P1.0
                RB      off(00127h).2
                JBS     off(00119h).1, vtec_engage_conditions_start_load_ram1d8
vtec_engage_conditions_start_load_ram1d9:
                LB      A, off(001d9h)
                JNE     vtec_engage_conditions_start_set_ram127_bit1
vtec_highcam_output_load_ram1d8:
                MOVB    off(001d8h), #00ah
vtec_highcam_output_clear_ram127_bit1:
                RB      off(00127h).1
                SJ      fuelmap_base_lookup
vtec_engage_conditions_start_load_ram1df:
                MOVB    off(001dfh), #014h
vtec_engage_conditions_start_set_p1_bit0:
                SB      P1.0
                SB      off(00127h).2
                JBR     off(00119h).1, vtec_engage_conditions_start_load_ram1d9
vtec_engage_conditions_start_load_ram1d8:
                LB      A, off(001d8h)
                JNE     vtec_highcam_output_clear_ram127_bit1
                MOVB    off(001d9h), #00ah
vtec_engage_conditions_start_set_ram127_bit1:
                SB      off(00127h).1
fuelmap_base_lookup:
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, off(001bch)
                MOV     X2, off(001c0h)
                MOVB    r3, off(001c7h)
                MOV     er3, off(001c4h)
                MOV     X1, #fuelmap_base_lookup_tbl_3
                JBR     off(0011ch).5, fuelmap_base_lookup_load_dp
                JBS     off(00120h).5, fuelmap_base_lookup_set_pswl_bit5
fuelmap_base_lookup_load_dp:
                MOV     DP, #fuelmap_base_lookup_tbl_5
                MOVB    r4, #000h
                JBS     off(00127h).1, fuelmap_base_lookup_if_ram121_bit6_clr
                MOVB    r3, off(001c6h)
                MOV     er3, off(001c2h)
                MOV     X1, #fuelmap_base_lookup_tbl_2
                MOV     DP, #fuelmap_base_lookup_tbl_4
                MOVB    r4, #000h
fuelmap_base_lookup_if_ram121_bit6_clr:
                JBR     off(00121h).6, fuelmap_base_lookup_set_pswl_bit5
                LB      A, r4
                CMPB    A, r3
                JGT     fuelmap_base_lookup_set_pswl_bit5
                ADDB    A, #00ah
                CMPB    A, r3
                JLE     fuelmap_base_lookup_set_pswl_bit5
                LB      A, r4
                SUBB    r3, A
                MOVB    r1, #00bh
                MOV     X1, DP
fuelmap_base_lookup_set_pswl_bit5:
                SB      PSWL.5
                CAL     table2d_lookup_interp
                LCB     A, fuelmap_base_lookup_tbl
                MOV     A, er2
                JEQ     fuelmap_base_lookup_store_ram140
                CAL     map_result_postscale
fuelmap_base_lookup_store_ram140:
                ST      A, off(00140h)
                LB      A, off(00182h)
                JBS     off(0011fh).5, accel_iac_calc
                JBS     off(0012ch).4, fuel_timer_scale
                SJ      accel_iac_clamp_min
accel_iac_calc: LB      A, off(0016bh)
                STB     A, r0
                LB      A, #09ah
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     accel_iac_calc_cmp_acc
                LB      A, #0ffh
accel_iac_calc_cmp_acc:
                CMPB    A, #040h
                JGE     accel_iac_store
accel_iac_clamp_min:
                LB      A, #040h
accel_iac_store:
                STB     A, off(00182h)
fuel_timer_scale:
                MOVB    r0, off(00183h)
                MULB
                MOVB    r1, off(00181h)
                CLRB    r0
                MUL
                MOV     er0, er1
                L       A, off(0015eh)
                MUL
                MOV     off(00184h), er1
                CMPB    off(00133h), #0c0h
                RB      PSWH.7
                MOVB    r0, 0d6h
                MB      C, off(00123h).2
                JEQ     accelenrich_rpm_mode_check
                MOVB    r0, 0d5h
                MB      C, off(00123h).1
accelenrich_rpm_mode_check:
                JLT     accelenrich_flags_clear
                LB      A, #00ah
                CMPB    A, r0
                MB      off(0012ch).1, C
                LB      A, #00ah
                CMPB    A, r0
                MB      off(0012ch).2, C
                RC
                SJ      accelenrich_mode_flag_store
accelenrich_flags_clear:
                RB      off(0012ch).1
                RB      off(0012ch).2
                LB      A, #004h
                CMPB    A, r0
accelenrich_mode_flag_store:
                MB      off(0012ch).0, C
                JBS     off(00125h).4, accelenrich_jump_cranking_path
                JBS     off(00119h).0, accelenrich_jump_cranking_path
                JBR     off(0012ch).0, accelenrich_clear_pulse_check
                JBR     off(00123h).3, accelenrich_jump_tipin_check
                LB      A, off(0018ah)
                JBS     off(0012ch).3, accelenrich_table_lookup
                CMPB    0bdh, #0dah
                JGE     accelenrich_jump_cranking_path
                CMPB    0d3h, #0b3h
                JLT     accelenrich_base_calc
accelenrich_jump_cranking_path:
                J       accelenrich_clear_and_cranking_prep
accelenrich_jump_tipin_check:
                J       accelenrich_jump_tipin_check_load_ram142
accelenrich_base_calc:
                CLRB    A
                JBR     off(00120h).1, accelenrich_base_adjust
                CMPB    0cch, #005h
                JLT     accelenrich_result_store
accelenrich_base_adjust:
                ADDB    A, #02ah
                JBR     off(0012eh).4, accelenrich_rpm_tier1
                ADDB    A, #006h
accelenrich_rpm_tier1:
                CMPB    off(00133h), #0c0h
                JGE     accelenrich_result_store
                SUBB    A, #00ch
                CMPB    off(00133h), #08dh
                JGE     accelenrich_result_store
                SUBB    A, #00ch
                CMPB    off(00133h), #074h
                JGE     accelenrich_result_store
                SUBB    A, #00ch
accelenrich_result_store:
                STB     A, off(0018ah)
accelenrich_table_lookup:
                CLRB    ACCH
                MOV     X1, A
                ADD     X1, #tbl_tipin_enrich_rpm
                LB      A, r0
                VCAL    2
                MOV     er0, off(00184h)
                MUL
                SRL     er1
                RORB    A
                SRL     er1
                RORB    A
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     accelenrich_table_lookup_goto_cranking_flag_check
                L       A, #0ffffh
accelenrich_table_lookup_goto_cranking_flag_check:
                J       cranking_flag_check
accelenrich_clear_pulse_check:
                JBR     off(0012ch).2, accelenrich_clear_pulse_check_cmp_ram133
                CLR     off(00142h)
accelenrich_clear_pulse_check_cmp_ram133:
                CMPB    off(00133h), #053h
                JLT     accelenrich_jump_tipin_check_load_ram142
                JBR     off(0012ch).1, tipin_gate_common
                JBR     off(00123h).3, tipin_gate_common
                MOV     X1, #tbl_tipin_low
                CMPB    (00251h-00280h)[USP], #003h
                JGE     tipin_table_gear_adjust
                ADD     X1, #00006h
tipin_table_gear_adjust:
                CMPB    off(00133h), #08dh
                JGE     tipin_table_lookup
                SUB     X1, #0000ch
tipin_table_lookup:
                LB      A, r0
                VCAL    2
                LB      A, ACC
                SJ      accelenrich_clear_and_cranking_prep_store_ram167
tipin_gate_common:
                LB      A, off(00167h)
                JEQ     accelenrich_jump_tipin_check_load_ram142
                ADDB    A, #003h
                JGE     accelenrich_clear_and_cranking_prep_store_ram167
accelenrich_jump_tipin_check_load_ram142:
                L       A, off(00142h)
                JEQ     accelenrich_clear_and_cranking_prep
                ST      A, er3
                LB      A, off(0018ah)
                EXTND
                MOV     DP, #tbl_tipin_normal_enrich
                ADD     DP, A
                LC      A, [DP]
                ST      A, er2
                CMP     A, er3
                L       A, #0007dh
                JLT     tipin_table_result_alt
                LC      A, 00002h[DP]
                ST      A, er2
                CMP     A, er3
                JLT     tipin_table_row2
                MOV     er0, off(00188h)
                LC      A, 00004h[DP]
                MUL
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     accelenrich_jump_tipin_check_xchg_acc
                L       A, #0ffffh
accelenrich_jump_tipin_check_xchg_acc:
                XCHG    A, er3
                SUB     A, er3
                SJ      tipin_table_final
tipin_table_row2:
                MOV     er0, off(00186h)
                L       A, #00032h
                MUL
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     tipin_table_result_alt
                L       A, #0ffffh
tipin_table_result_alt:
                XCHG    A, er3
                SUB     A, er3
                JLT     tipin_table_result_common
                CMP     A, er2
                JGE     tipin_table_final
tipin_table_result_common:
                L       A, er2
                RC
tipin_table_final:
                JGE     cranking_flag_check
accelenrich_clear_and_cranking_prep:
                CLRB    A
accelenrich_clear_and_cranking_prep_store_ram167:
                STB     A, off(00167h)
                RB      off(0012ch).3
                CLR     A
                SJ      SetCranking
cranking_flag_check:
                CLRB    off(00167h)
                SB      off(0012ch).3
SetCranking:    ST      A, off(00142h)
                JBS     off(0011fh).5, Cranking
                J       notcranking_entry
Cranking:       MOV     X1, #Cranking_tbl
                LB      A, 0d9h
                VCAL    0
                STB     A, off(00140h)
                J       Cranking_load_x1
                DB  000h,000h,000h
Cranking_store_ram164:
                STB     A, off(00164h)
                MOV     X1, #CrankFuelMap
                LB      A, 0bch
                VCAL    1
                STB     A, off(00165h)
                MOVB    r0, off(00164h)
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
crankfuel_clamp_max:
                L       A, #0ffffh
crankfuel_halve_check:
                MB      C, 0b7h.0
                JGE     crankfuel_add_adjust
                SRL     A
                SRL     A
crankfuel_add_adjust:
                ADD     A, off(00144h)
                JGE     crankfuel_zero_gate
                L       A, #0ffffh
crankfuel_zero_gate:
                JBR     off(0012ah).1, crankfuel_store_injectors_ab
                CLR     A
crankfuel_store_injectors_ab:
                MOV     DP, #003a2h
                ST      A, [DP]
                MOV     DP, #003b4h
                ST      A, [DP]
                CLR     X1
                CAL     scale_mul5_div4
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, 003b6h[X1]
                ST      A, 003b8h[X1]
                ST      A, 003bah[X1]
                ST      A, 003bch[X1]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MB      C, 0b7h.0
                JLT     crankfuel_output_apply_start
                CMPB    off(0013dh), #004h
                JNE     postfuel_calc_start
                CMPB    0d9h, #0e8h
                JGE     postfuel_calc_start
crankfuel_output_apply_start:
                L       A, 003b6h[X1]
                ST      A, off(00196h)
                ST      A, off(00194h)
                ST      A, off(00192h)
                ST      A, off(00190h)
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
crankfuel_timer_sync_done:
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                MOV     DP, #00010h
crankfuel_timer_wait_loop:
                L       A, off(00196h)
                JRNZ    DP, crankfuel_timer_wait_loop
                CAL     injector_timer_schedule
                JBS     off(0011fh).3, cylinder_index_advance
                JBS     off(0011bh).7, cylinder_index_advance
                MULB
                RB      off(0012ah).0
                JEQ     cylinder_index_advance
                RB      TRNSIT.2
                JNE     cylinder_index_advance
dtc16_injector_latch_2:
                SB      0b4h.6
cylinder_index_advance:
                LB      A, off(0013ch)
                ADDB    A, #001h
                ANDB    A, #003h
                STB     A, off(0013ch)
postfuel_calc_start:
                SB      off(0012ch).4
                LB      A, 0d9h
                CMPB    A, #0cfh
                MB      PSWL.5, C
                MOV     X1, #postfuel_calc_start_tbl
                VCAL    0
                STB     A, r0
                STB     A, r1
                JBS     off(0011ah).5, postfuel_scale_apply
                JBS     off(0011bh).1, postfuel_scale_apply
                CMPB    0d9h, #0a2h
                JLT     postfuel_scale_apply
                MOV     DP, #0031ah
                LB      A, [DP]
                SUBB    A, 0d9h
                JGE     postfuel_ect_rate_check
                VCAL    6
postfuel_ect_rate_check:
                CMPB    A, #010h
                JGE     postfuel_scale_apply
                LB      A, 0d8h
                CMPB    A, #0bah
                JLT     postfuel_scale_apply
                SUBB    A, 0d9h
                JLT     postfuel_scale_apply
                CMPB    A, #006h
                JLT     postfuel_scale_apply
                L       A, #0d99ah
                MUL
postfuel_scale_apply:
                L       A, er1
                ST      A, off(00172h)
                CLRB    off(00171h)
                MOV     er2, #02000h
                SUB     A, er2
                ST      A, er3
                CLRB    r0
                MOVB    r1, #066h
                MB      C, PSWL.5
                JLT     postfuel_hyst_upper_calc
                MOVB    r1, #05ah
postfuel_hyst_upper_calc:
                MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(00174h)
                L       A, er3
                MOVB    r1, #040h
                MB      C, PSWL.5
                JLT     postfuel_hyst_lower_calc
                MOVB    r1, #033h
postfuel_hyst_lower_calc:
                MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(00176h)
                CMPB    0d8h, #030h
                MB      off(0012bh).3, C
                LB      A, off(0016bh)
                SUBB    A, off(0016fh)
                JGE     postfuel_tps_delta_finalize
                CLRB    A
postfuel_tps_delta_finalize:
                STB     A, off(00170h)
                J       postinj_rpm_check
notcranking_entry:
                RB      0b7h.0
; --- Post-start enrichment decay: selects a decay-rate table (PostFuelDecay/2/3, chosen by
; TPS/RPM conditions), then subtracts the selected decay amount from the enrichment value
; (0x170) each cycle, floored at a minimum of 0x2000, with an ECT-gated (0x2E threshold) exit
; once fully decayed. This is what makes post-start enrichment taper off over time rather than
; cutting off abruptly.
                JEQ     postfuel_decay_table_select
                CLRB    off(0013dh)
postfuel_decay_table_select:
                JBR     off(0012ch).4, postfuel_final_store_load_imm
                MOV     DP, #PostFuelDecay
                JBR     off(0011eh).3, postfuel_decay_table_index_adjust
                MOV     DP, #PostFuelDecay2
                JBS     off(00119h).5, postfuel_decay_table_index_adjust
                MOV     DP, #PostFuelDecay3
postfuel_decay_table_index_adjust:
                CMPB    off(00173h), #026h
                JLE     postfuel_decay_table_index_adjust2
                CMP     off(00172h), off(00174h)
                JGT     postfuel_decay_apply
postfuel_decay_table_index_adjust2:
                INC     DP
                INC     DP
                CMP     off(00172h), off(00176h)
                JGT     postfuel_decay_apply
                INC     DP
                INC     DP
                CMPB    0d8h, #044h
                JGE     postfuel_decay_apply
                INC     DP
                INC     DP
postfuel_decay_apply:
                LC      A, [DP]
                SUBB    off(00171h), A
                CLRB    A
                L       A, ACC
                SWAP
                ST      A, er0
                L       A, off(00172h)
                SBC     A, er0
                CMP     A, #02000h
                JLE     postfuel_decay_zero_reset
                ST      A, off(00172h)
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
postfuel_decay_zero_reset:
                RB      off(0012ch).4
                L       A, #02000h
                ST      A, off(00172h)
postfuel_final_store:
                ST      A, off(0015ch)
postfuel_final_store_load_imm:
                LB      A, #0bah
                JBS     off(0012fh).0, postfuel_final_store_cmp_acc
                LB      A, #0c0h
postfuel_final_store_cmp_acc:
                CMPB    A, off(00133h)
                MB      off(0012fh).0, C
                LB      A, #0deh
                JBS     off(0012fh).5, postfuel_final_store_cmp_acc_2
                LB      A, #0e0h
postfuel_final_store_cmp_acc_2:
                CMPB    A, off(00133h)
                MB      off(0012fh).5, C
                LB      A, #017h
                JBS     off(0012fh).2, postfuel_final_store_cmp_ram0d9
                LB      A, #014h
postfuel_final_store_cmp_ram0d9:
                CMPB    0d9h, A
                MB      off(0012fh).2, C
                LB      A, #014h
                JBS     off(0012fh).1, postfuel_final_store_cmp_ram0d9_2
                LB      A, #011h
postfuel_final_store_cmp_ram0d9_2:
                CMPB    0d9h, A
                MB      off(0012fh).1, C
                LB      A, off(00133h)
                MOV     X1, #CloseLoopTPS
                JBS     off(0012fh).6, closeloop_tps_lookup
                MOV     X1, #OpenLoopTPS
closeloop_tps_lookup:
                CAL     table_interp_lookup
                CMPB    A, 0d1h
                MB      off(0012fh).6, C
                LB      A, off(00133h)
                MOV     X1, #tbl_closeloop_tps
                CMPCB   A, 0000ch[X1]
                MB      off(0012fh).3, C
                CAL     table_interp_lookup
                CLRB    r0
                RB      PSWL.4
                JBS     off(0012fh).3, ve_adjust_sub
                MOVB    r0, #020h
                JBS     off(0012fh).1, ve_adjust_sub
                JBR     off(0011eh).1, closeloop_tps_lookup_clear_r0
                JBR     off(0012fh).0, closeloop_tps_lookup_clear_r0
                MOVB    r0, #040h
                JBS     off(00120h).7, ve_adjust_add
                JBS     off(0012fh).2, ve_adjust_add
                SB      PSWL.4
closeloop_tps_lookup_clear_r0:
                CLRB    r0
ve_adjust_add:  ADDB    r0, off(00180h)
                JLT     ve_adjust_clamp_zero
ve_adjust_sub:  SUBB    A, r0
                JGE     ve_adjust2_gate
ve_adjust_clamp_zero:
                CLRB    A
ve_adjust2_gate:
                STB     A, r4
                RB      PSWL.4
                JEQ     ve_adjust2_gate_store_r0
                LB      A, off(00133h)
                MOV     X1, #ve_adjust2_gate_tbl
                CAL     table_interp_lookup
                SUBB    A, off(00180h)
                JGE     ve_adjust2_gate_store_r0
                CLRB    A
ve_adjust2_gate_store_r0:
                STB     A, r0
                SUBB    A, #010h
                JGE     ve_adjust2_gate_cmp_acc
                CLRB    A
ve_adjust2_gate_cmp_acc:
                CMPB    A, off(00132h)
                MB      off(00130h).2, C
                LB      A, r0
                MOVB    r0, #008h
                JBR     off(00130h).1, ve_result_flag_store
                SUBB    A, r0
                JGE     ve_result_flag_store
                CLRB    A
ve_result_flag_store:
                CMPB    A, off(00132h)
                MB      off(00130h).1, C
                LB      A, r4
                JBR     off(00130h).0, ve_result_flag_store_cmp_acc
                SUBB    A, r0
                JGE     ve_result_flag_store_cmp_acc
                CLRB    A
ve_result_flag_store_cmp_acc:
                CMPB    A, off(00132h)
                MB      off(00130h).0, C
                SC
                JBR     off(0011eh).1, ve_result_flag_store_store_carry_ram126_bit3
                JBS     off(00120h).7, ve_result_flag_store_store_carry_ram126_bit3
                JBS     off(00130h).2, ve_result_flag_store_load_ram1cc
                RB      off(00129h).2
                JEQ     ve_result_flag_store_clear_ram1ca
                MOVB    off(001cbh), off(001cah)
ve_result_flag_store_clear_ram1ca:
                CLRB    off(001cah)
                RC
                SJ      ve_result_flag_store_store_carry_ram126_bit3
ve_result_flag_store_load_ram1cc:
                LB      A, off(001cch)
                SB      off(00129h).2
                JNE     ve_result_flag_store_clear_ram1c9
                CLR     A
                LB      A, off(001c9h)
                MOV     er0, A
                LB      A, off(001cbh)
                MOV     er1, A
                LB      A, off(001cch)
                L       A, ACC
                ADD     A, er0
                SUB     A, er1
                LB      A, ACC
                JGE     ve_result_flag_store_cmp_acch
                CLRB    A
                SJ      ve_result_flag_store_load_r4
ve_result_flag_store_cmp_acch:
                CMPB    ACCH, #000h
                JEQ     ve_result_flag_store_load_r4
                LB      A, #0ffh
ve_result_flag_store_load_r4:
                MOVB    r4, #006h
                CMPB    A, r4
                JLT     ve_result_flag_store_store_ram1cc
                LB      A, r4
ve_result_flag_store_store_ram1cc:
                STB     A, off(001cch)
ve_result_flag_store_clear_ram1c9:
                CLRB    off(001c9h)
                CMPB    off(001cah), A
                XORB    PSWH, #080h
ve_result_flag_store_store_carry_ram126_bit3:
                MB      off(00126h).3, C
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, off(001bch)
                MOV     X2, off(001c0h)
                MOVB    r3, off(001c7h)
                MOV     er3, off(001c4h)
                MOV     X1, #ve_result_flag_store_tbl_2
                RB      PSWL.5
                JBR     off(0011ch).5, ve_result_flag_store_if_ram127_bit1_set
                JBS     off(00120h).5, ve_result_flag_store_call_table2d_lookup_interp
ve_result_flag_store_if_ram127_bit1_set:
                JBS     off(00127h).1, ve_result_flag_store_call_table2d_lookup_interp
                MOVB    r3, off(001c6h)
                MOV     er3, off(001c2h)
                MOV     X1, #ve_result_flag_store_tbl
ve_result_flag_store_call_table2d_lookup_interp:
                CAL     table2d_lookup_interp
                LB      A, r4
                SRLB    A
                STB     A, r0
                JBS     off(00125h).4, ve_accel_state_store_clear_ram125_bit5
                JBS     off(0011ah).6, ve_accel_gate1
                JBS     off(0012fh).6, ve_accel_tps_threshold_check
ve_accel_gate1: JBS     off(0012fh).3, ve_accel_gate1_load_ram1ca
                JBS     off(0012fh).1, ve_accel_gate1_load_ram1ca
                JBR     off(0012fh).0, ve_accel_gate1_load_imm
                JBR     off(0011eh).1, ve_accel_gate1_load_ram1ca
                JBS     off(00120h).7, ve_accel_gate1_load_ram1ca
                JBS     off(0012fh).2, ve_accel_gate1_load_ram1ca
                JBR     off(00130h).1, ve_accel_state_store_clear_ram125_bit5
                JBS     off(00130h).0, ve_accel_tps_threshold_check
                JBR     off(00126h).3, ve_accel_state_store_clear_ram125_bit5
                SJ      ve_accel_tps_threshold_check_goto_7bf1
ve_accel_tps_threshold_check:
                LB      A, r0
                JBS     off(00126h).3, ve_accel_tps_threshold_check_goto_7bf1
                LB      A, #080h
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
                JGE     ve_accel_tps_threshold_check_goto_1826
                LB      A, #0ffh
ve_accel_tps_threshold_check_goto_1826:
                SJ      ve_accel_tps_threshold_check_goto_7bf1
ve_accel_gate1_load_ram1ca:
                MOVB    off(001cah), #006h
                JBR     off(00130h).0, ve_accel_gate1_clear_acc
                JBS     off(00129h).3, ve_accel_gate1_if_ram121_bit5_set
ve_accel_gate1_clear_acc:
                CLRB    A
                SJ      ve_accel_state_store
ve_accel_gate1_load_imm:
                LB      A, #001h
                JBR     off(00130h).0, ve_accel_state_store
                CMPB    0cch, #005h
                JLT     ve_accel_tps_threshold_check
                LB      A, off(001dch)
                JEQ     ve_accel_tps_threshold_check
ve_accel_state_store:
                STB     A, off(001dch)
ve_accel_state_store_clear_ram125_bit5:
                RB      off(00125h).5
                RB      off(0012fh).4
ve_accel_state_store_clear_ram12f_bit7:
                RB      off(0012fh).7
                LB      A, #040h
                SJ      tpsaccel_result_common_store_ram164
ve_accel_gate1_if_ram121_bit5_set:
                JBS     off(00121h).5, ve_accel_next_stage
ve_accel_tps_threshold_check_goto_7bf1:
                J       ve_accel_tps_threshold_check_cmp_r0
                DB  0FFh
to_ve_accel_common:
                SB      off(00125h).5
                CLRB    off(001dch)
                SJ      ve_accel_state_store_clear_ram12f_bit7
ve_accel_next_stage:
                MOVB    r0, off(0017fh)
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
tpsaccel_scale_clamp1:
                STB     A, r2
                LB      A, (00246h-00280h)[USP]
                CMPB    A, #015h
                JBS     off(0012fh).4, tpsaccel_hyst_check
                JLT     tpsaccel_hyst_check
                SB      off(0012fh).4
                SJ      tpsaccel_table_select
tpsaccel_hyst_check:
                CMPB    A, #00ch
                JGE     tpsaccel_table_select
                LB      A, r2
                RB      off(0012fh).4
                SJ      tpsaccel_clamp_0xa0
tpsaccel_table_select:
                LB      A, off(00133h)
                MOV     X1, #tbl_ve_accel_1
                JBR     off(00127h).1, tpsaccel_table_lookup
                LB      A, 0c2h
                MOV     X1, #tbl_ve_accel_2
tpsaccel_table_lookup:
                CAL     table_interp_lookup
                MOVB    r0, r2
                MULB
                SLLB    A
                LB      A, ACCH
                ROLB    A
                JGE     tpsaccel_clamp_0xa0
                LB      A, #0ffh
tpsaccel_clamp_0xa0:
                MOVB    r0, #056h
                CMPB    A, r0
                JLT     tpsaccel_clamp_0xa0_cmp_ram1cd
                LB      A, r0
tpsaccel_clamp_0xa0_cmp_ram1cd:
                CMPB    off(001cdh), #000h
                JNE     tpsaccel_result_common
                JBR     off(0012fh).5, tpsaccel_result_common
                MOVB    r0, #056h
                CMPB    A, r0
                JGE     tpsaccel_result_common
                LB      A, r0
tpsaccel_result_common:
                SB      off(00125h).5
                SB      off(0012fh).7
                CLRB    off(001dch)
tpsaccel_result_common_store_ram164:
                STB     A, off(00164h)
                JBS     off(0012fh).5, tpsaccel_ignitioncut_flag_copy
                CLRB    A
                CMPB    0d9h, #02eh
                JGE     tpsaccel_ect_default_store
                LB      A, #034h
tpsaccel_ect_default_store:
                STB     A, off(001cdh)
tpsaccel_ignitioncut_flag_copy:
                MB      C, off(00124h).4
                MB      off(0012eh).4, C
                MOV     X1, #tbl_ignmap2_hi
                JBR     off(00124h).2, tpsaccel_ignitioncut_flag_copy_load_ram133
                MOV     X1, #tbl_ignmap2_lo
tpsaccel_ignitioncut_flag_copy_load_ram133:
                LB      A, off(00133h)
                CAL     table_interp_lookup
                SUBB    A, off(001ach)
                JGE     tpsaccel_ignitioncut_flag_copy_cmp_acc
                CLRB    A
tpsaccel_ignitioncut_flag_copy_cmp_acc:
                CMPB    A, off(00132h)
                MB      off(0012eh).0, C
                LB      A, off(001abh)
                MOVB    r0, #05ah
                MOVB    r1, #073h
                JBR     off(00124h).2, tpsaccel_threshold_pick
                LB      A, off(001aah)
                MOVB    r0, #047h
                MOVB    r1, #060h
tpsaccel_threshold_pick:
                JBR     off(00123h).0, tps_hysteresis_check
                CMPB    0d8h, #044h
                JGE     tpsaccel_threshold_apply
                MOVB    r0, r1
tpsaccel_threshold_apply:
                CMPB    A, r0
                JGE     tps_hysteresis_check
                LB      A, r0
tps_hysteresis_check:
                JBR     off(0011fh).6, rpm_threshold_adjust
                CMPB    0dch, #082h
                JBS     off(0012eh).7, tps_hysteresis_store
                CMPB    0dch, #07ah
tps_hysteresis_store:
                MB      off(0012eh).7, C
                STB     A, r0
                LB      A, #040h
                JBS     off(0012bh).6, tps_hysteresis_flag2
                LB      A, #05ah
tps_hysteresis_flag2:
                CMPB    A, r0
                MB      off(0012bh).6, C
                LB      A, r0
                JLT     rpm_threshold_adjust
                JBS     off(0012eh).7, rpm_threshold_adjust
                SUBB    A, #00ah
                JGE     rpm_threshold_adjust
                CLRB    A
rpm_threshold_adjust:
                CMPB    0cch, #000h
                JBR     off(0011eh).3, rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold
                CMPB    0cch, #008h
rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold:
                JLT     rpm_secondary_threshold_check
                JBR     off(0012eh).1, rpm_secondary_threshold_check
                JBS     off(00124h).2, rpm_secondary_threshold_check
                ADDB    A, #020h
                JGE     rpm_secondary_threshold_check
                LB      A, #0ffh
rpm_secondary_threshold_check:
                CMPB    A, off(00133h)
                MB      off(0012eh).3, C
                LB      A, #073h
                JBS     off(0012eh).2, revlimiter_engage_resume_check
                LB      A, #080h
revlimiter_engage_resume_check:
                CMPB    A, off(00133h)
                MB      off(0012eh).2, C
                RB      PSWL.4
                RB      PSWL.5
                RB      off(0012bh).7
                JBS     off(0012dh).4, revlimiter_fuelcut_set
                JBS     off(0011bh).5, revlimiter_engage_resume_check_if_ram11a_bit6_set
                MB      C, 0b1h.3
                JLT     revlimiter_engage_resume_check_if_ram11a_bit6_set
                LB      A, 09dh
                CMPB    A, #010h
                JGE     doubleup_limiter_gate
revlimiter_engage_resume_check_if_ram11a_bit6_set:
                JBS     off(0011ah).6, vaccut_rpm_check
                MB      C, 0b0h.2
                JLT     vaccut_rpm_check
                CMPB    0d1h, #02bh
                JGE     doubleup_limiter_gate
                MOV     X1, #revlimiter_engage_resume_check_tbl
                LB      A, 0d1h
                VCAL    1
                SJ      vaccut_rpm_check_cmp_acc
vaccut_rpm_check:
                LB      A, #080h
vaccut_rpm_check_cmp_acc:
                CMPB    A, off(00133h)
                JGE     ofc_enable_check_if_ram12e_bit0_set
                SJ      revlimiter_fuelcut_set
doubleup_limiter_gate:
                MOV     DP, #00228h
                L       A, #00218h
                MB      C, P4.0
                JLT     doubleup_limiter_cont
                JBS     off(0011bh).7, doubleup_limiter_cont
                MOV     DP, off(001a6h)
                L       A, off(001a4h)
doubleup_limiter_cont:
                JBR     off(00124h).5, ignition_cut_mode_check
                L       A, DP
ignition_cut_mode_check:
                CMP     0c4h, A
                JLT     revlimiter_fuelcut_set
                JBS     off(00121h).7, fuelcuttrack_store
                JBS     off(0011eh).2, ignition_cut_mode_check_load_imm
                LCB     A, ignition_cut_mode_check_tbl
                JEQ     fuelcut_extra_gate
ignition_cut_mode_check_load_imm:
                LB      A, #0c8h
                CMPB    A, off(00133h)
                JGE     ignition_cut_mode_check_load_imm_2
                CMPB    0cch, #0b9h
                JGE     ignition_cut_mode_check_load_ram1dd
                LB      A, off(001deh)
                JNE     revlimiter_fuelcut_set
ignition_cut_mode_check_load_imm_2:
                LB      A, #028h
                STB     A, off(001ddh)
                SJ      fuelcut_extra_gate
ignition_cut_mode_check_load_ram1dd:
                LB      A, off(001ddh)
                JNE     fuelcut_extra_gate
                LB      A, #002h
                STB     A, off(001deh)
revlimiter_fuelcut_set:
                SB      PSWL.5
                SJ      fuelcut_result_common
fuelcut_extra_gate:
                JBS     off(00124h).2, ofc_enable_check
                JBR     off(00122h).0, ofc_enable_check_if_ram12e_bit0_set
ofc_enable_check:
                JBR     off(00120h).2, ofc_enable_check_if_ram12e_bit3_set
                RB      off(0012eh).1
ofc_enable_check_if_ram12e_bit0_set:
                JBS     off(0012eh).0, fuelcuttrack_store
                JBS     off(0012eh).2, fuelcut_tps_recheck
fuelcuttrack_store:
                LB      A, #014h
                STB     A, off(001d7h)
fuelcut_clear_active_flag:
                RB      off(00124h).2
                SJ      fuelcut_output_flags
ofc_enable_check_if_ram12e_bit3_set:
                JBS     off(0012eh).3, fuelcut_tps_recheck
                SB      off(0012eh).1
                SJ      fuelcuttrack_store
fuelcut_tps_recheck:
                JBS     off(00124h).2, fuelcut_finalize_ign_flag
                LB      A, 0c1h
                CMPB    A, #060h
                JBS     off(0011eh).3, to_fuelcut_clear_active_flag
                CMPB    A, #010h
to_fuelcut_clear_active_flag:
                JGE     fuelcuttrack_store
                LB      A, off(001d7h)
                JEQ     fuelcut_finalize_ign_flag
                SB      off(0012bh).7
                SJ      fuelcut_clear_active_flag
fuelcut_finalize_ign_flag:
                JBR     off(0011eh).3, fuelcut_finalize_ign_flag_if_ram12e_bit5_set
                LB      A, 0cch
                CMPB    A, #064h
                JGE     fuelcut_finalize_ign_flag_if_ram12e_bit5_set
                LB      A, 0cdh
                SUBB    A, 0cch
                JLT     fuelcut_finalize_ign_flag_if_ram119_bit5_set
                CMPB    A, #004h
                JGE     fuelcut_finalize_ign_flag_set_ram12e_bit5
fuelcut_finalize_ign_flag_if_ram119_bit5_set:
                JBS     off(00119h).5, fuelcut_finalize_ign_flag_if_ram12e_bit5_set
                JBS     off(00123h).7, fuelcut_finalize_ign_flag_if_ram12e_bit5_set
                L       A, 0c8h
                CMP     A, #00100h
                JLT     fuelcut_finalize_ign_flag_if_ram12e_bit5_set
                SB      off(0012eh).6
                SJ      fuelcut_finalize_ign_flag_if_ram12e_bit5_set
fuelcut_finalize_ign_flag_set_ram12e_bit5:
                SB      off(0012eh).5
fuelcut_finalize_ign_flag_if_ram12e_bit5_set:
                JBS     off(0012eh).5, fuelcut_clear_active_flag
                JBS     off(0012eh).6, fuelcut_clear_active_flag
                JBS     off(0012ch).3, fuelcut_clear_active_flag
                SB      PSWL.4
fuelcut_result_common:
                SB      off(00124h).2
fuelcut_output_flags:
                MB      C, PSWL.5
                MB      off(00124h).5, C
                MB      C, PSWL.4
                MB      off(00124h).4, C
                RC
                RB      off(0012bh).7
                JBS     off(00124h).2, fuelcut_output_flags_set_carry
                JEQ     fuelcut_output_flags_store_carry_ram124_bit3
fuelcut_output_flags_set_carry:
                SC
fuelcut_output_flags_store_carry_ram124_bit3:
                MB      off(00124h).3, C
                LB      A, 0dch
                CMPB    A, #082h
                JBS     off(0012bh).4, tps_hysteresis_reentry
                CMPB    A, #07ah
tps_hysteresis_reentry:
                MB      off(0012bh).4, C
                ANDB    PSWL, #0cfh
                MOVB    r2, #00ah
                JBS     off(00121h).7, postig_result_zero_common
                JBS     off(00125h).4, tps_hysteresis_reentry_load_ram132
                JBS     off(0012ch).3, postig_result_zero_common
                JBS     off(00125h).5, postig_result_zero_common
                JBR     off(00122h).2, postig_result_default
                JBR     off(00122h).0, postig_result_default
                JBR     off(0011eh).3, postig_gate_chain2
                JBS     off(00119h).5, postig_result_default
postig_gate_chain2:
                JBS     off(00120h).4, postig_result_default
                LB      A, off(001a8h)
                MOVB    r0, #040h
                JBS     off(0012bh).5, postig_threshold_check1
                LB      A, off(001a9h)
                MOVB    r0, #05ah
postig_threshold_check1:
                JBR     off(00123h).0, postig_threshold_check2
                CMPB    A, r0
                JGE     postig_threshold_check2
                LB      A, r0
postig_threshold_check2:
                JBR     off(0011fh).6, postig_rpm_compare
                MOVB    r0, #032h
                JBS     off(0012bh).5, postig_threshold_check3
                MOVB    r0, #050h
postig_threshold_check3:
                CMPB    A, r0
                JGE     postig_rpm_compare
                JBS     off(0012bh).4, postig_rpm_compare
                SUBB    A, #00ah
                JGE     postig_rpm_compare
                CLRB    A
postig_rpm_compare:
                CMPB    A, off(00133h)
                JGT     postig_result_zero_common
                CMPB    0d9h, #034h
                JGE     postig_result_high
                JBR     off(0011eh).3, postig_result_high
                LB      A, off(001d6h)
                STB     A, r2
                JNE     postig_result_zero_common
postig_result_high:
                LB      A, #0dah
                JBS     off(0011eh).3, to_set_pswl4_flag_b
                LB      A, #0f3h
to_set_pswl4_flag_b:
                SB      PSWL.5
                SJ      set_pswl4_flag_b
tps_hysteresis_reentry_load_ram132:
                LB      A, off(00132h)
                MOV     X1, #tps_hysteresis_reentry_tbl
                CAL     table_interp_lookup
                SJ      set_pswl4_flag_b
postig_result_zero_common:
                CLRB    A
                SJ      ignmap2_flags_store
postig_result_default:
                LB      A, #080h
                MOV     X1, #tbl_ignmap2_hi
                JBR     off(0012bh).5, ignmap2_rpm_gate
                LB      A, #073h
                MOV     X1, #tbl_ignmap2_lo
ignmap2_rpm_gate:
                CMPB    A, off(00133h)
                JGE     postig_result_zero_common
                LB      A, off(00133h)
                CAL     table_interp_lookup
                ADDB    A, #002h
                JGE     ignmap2_result_check
                LB      A, #0ffh
ignmap2_result_check:
                SUBB    A, off(001ach)
                JLT     postig_result_zero_common
                CMPB    A, off(00132h)
                JLE     postig_result_zero_common
                LB      A, #0f3h
set_pswl4_flag_b:
                SB      PSWL.4
ignmap2_flags_store:
                STB     A, off(00166h)
                MB      C, PSWL.4
                MB      off(0012bh).5, C
                MB      C, PSWL.5
                MB      off(00126h).1, C
                MOVB    off(001d6h), r2
                LB      A, #0cdh
                JBS     off(0012dh).0, ignmap2_flags_store_cmp_acc
                LB      A, #0d0h
ignmap2_flags_store_cmp_acc:
                CMPB    A, off(00133h)
                MB      off(0012dh).0, C
                LB      A, #012h
                JBS     off(00124h).6, knock_window_check
                LB      A, #010h
knock_window_check:
                CMPB    0c5h, A
                MB      off(00124h).6, C
                JGE     knock_window_gate_common
                RC
                JBS     off(00125h).5, knock_window_gate_common
                JBS     off(0012dh).0, knock_window_gate_common
                JBS     off(0012bh).5, knock_window_gate_common
                JBS     off(00124h).2, knock_window_gate_common
                SC
knock_window_gate_common:
                MB      off(00125h).2, C
                LB      A, #0bah
                JBS     off(00125h).3, rpm_gate_final_check
                LB      A, #0c0h
rpm_gate_final_check:
                CMPB    A, off(00133h)
                MB      off(00125h).3, C
                JBR     off(00120h).0, o2_closedloop_read_and_select
                MOVB    off(001dbh), #019h
o2_closedloop_read_and_select:
                LB      A, #01fh
                MOVB    r0, #01fh
                CMPB    0bch, #0dbh
                JLT     o2_closedloop_read_and_select_if_ram11e_bit0_set
                LB      A, #01fh
                MOVB    r0, #01fh
o2_closedloop_read_and_select_if_ram11e_bit0_set:
                JBS     off(0011eh).0, o2_closedloop_read_and_select_cmp_acc
                LB      A, r0
o2_closedloop_read_and_select_cmp_acc:
                CMPB    A, 0dah
                RB      off(0012dh).2
                MB      off(0012dh).2, C
                JEQ     o2_closedloop_delay_dec
                XORB    PSWH, #080h
o2_closedloop_delay_dec:
                MB      off(0012dh).1, C
                L       A, off(001b8h)
                JEQ     o2_closedloop_gate1
                DEC     off(001b8h)
o2_closedloop_gate1:
                JBR     off(00121h).3, o2_trim_gate_common
                JBS     off(00121h).4, o2_trim_gate_common
                JBS     off(00125h).4, o2_trim_gate_common
                MOV     DP, #003abh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2_trim_gate_common
                CMPB    0f2h, #00ch
                JLT     o2_trim_gate_common
                J       o2_closedloop_gate1_load_carry_stk
                DW  00000h
o2_closedloop_gate1_if_ne_goto_o2_trim_gate_common:
                JNE     o2_trim_gate_common
                L       A, off(0011ch)
                AND     A, #01420h
                JNE     o2_trim_gate_common
                CMPB    0d9h, #028h
                JGE     o2_trim_gate_common
                LB      A, 0dah
                STB     A, r0
                JBS     off(00124h).4, o2_store_prev_reading
                CMPB    off(00133h), #062h
                JGE     o2_gate_tps_check
                MOVB    off(001e0h), #032h
o2_gate_tps_check:
                LB      A, off(001e0h)
                JNE     o2_gate_dp_set
                SB      off(0012dh).3
o2_gate_dp_set: RC
                JBS     off(00124h).5, dtc01_o2_latch
                JBR     off(00125h).5, dtc01_o2_latch
                LB      A, #047h
                CMPB    A, off(00164h)
                JGE     dtc01_o2_latch
                CMPB    r0, #003h
                SJ      dtc01_o2_latch
o2_store_prev_reading:
                JBS     off(0012eh).4, o2_narrowband_check
                LB      A, r0
                STB     A, off(001bah)
o2_narrowband_check:
                JBR     off(0012dh).3, o2_trim_gate_reset_dp
                LB      A, #09ah
                CMPB    A, r0
                JGE     o2_trim_gate_common
                JBS     off(00120h).2, o2_trim_gate_common
                LB      A, off(001bah)
                SUBB    A, r0
                JGE     o2_delta_magnitude_check
                VCAL    6
o2_delta_magnitude_check:
                CMPB    A, #002h
                JLT     dtc01_o2_latch
o2_trim_gate_common:
                RB      off(0012dh).3
o2_trim_gate_reset_dp:
                MOVB    off(001e0h), #032h
                RC
dtc01_o2_latch: MB      0b0h.4, C
                MOVB    r0, #032h
                JBR     off(00121h).3, o2_trim_tps_mode_check_clear_ram17e
                JBS     off(00125h).4, o2_trim_tps_mode_check_clear_ram17e
                MOV     er1, #0828fh
                JBR     off(0011eh).2, o2_trim_table_ptr_load
                MB      C, 0b8h.5
                JGE     o2_trim_table_ptr_load
                JBR     off(0012dh).1, o2_trim_table_ptr_alt
                RB      0b8h.5
o2_trim_table_ptr_load:
                L       A, #0828fh
                JBS     off(0011ah).2, o2_trim_clear_gate1
                JBS     off(0011ah).4, o2_trim_clear_gate1
                J       o2_trim_table_ptr_load_load_carry_stk
                DW  00000h
o2_trim_table_ptr_load_if_ne_goto_o2_trim_table_ptr_alt:
                JNE     o2_trim_table_ptr_alt
                JBS     off(0011dh).2, o2_trim_table_ptr_alt
                JBR     off(0011dh).4, o2_trim_gate3
o2_trim_table_ptr_alt:
                L       A, er1
                SJ      o2_trim_clear_gate1
o2_trim_gate3:  JBR     off(00121h).1, o2_trim_tps_mode_check_clear_ram17e
                JBS     off(00125h).5, o2_trim_tps_mode_check_clear_ram17e
                JBS     off(00121h).0, o2_trim_tps_mode_check
                CLRB    off(0017eh)
                MOVB    off(001d3h), r0
                MOV     DP, #00304h
                JBR     off(00120h).0, o2_trim_dp_table_read
                MOV     DP, #00300h
o2_trim_dp_table_read:
                L       A, [DP]
                SJ      o2_trim_clear_gate1
o2_trim_tps_mode_check:
                JBS     off(0012dh).0, o2_trim_tps_mode_check_clear_ram17e
                JBR     off(00124h).6, o2_trim_alt_path_check_load_ram17e
                JBR     off(00124h).2, o2_trim_alt_path_check
                MOVB    off(001e4h), #00ah
                SJ      o2_trim_alt_path_check_load_ram17e
o2_trim_alt_path_check:
                JBR     off(0012bh).5, o2_trim_alt_path_check_goto_7988
o2_trim_alt_path_check_load_ram17e:
                MOVB    off(0017eh), #004h
                LB      A, off(001d3h)
                JEQ     o2_trim_default_target
                L       A, off(0015ah)
                J       o2_trim_alt_path_check_set_stk
o2_trim_alt_path_check_goto_o2_trim_clear_gate0_and_retu:
                SJ      o2_trim_clear_gate0_and_return
o2_trim_tps_mode_check_clear_ram17e:
                CLRB    off(0017eh)
                MOVB    off(001d3h), r0
o2_trim_default_target:
                L       A, #08000h
o2_trim_clear_gate1:
                RB      off(00125h).1
o2_trim_clear_gate0_and_return:
                RB      off(00125h).0
                J       injtimer_finalize_start
o2_trim_alt_path_check_goto_7988:
                J       o2_trim_alt_path_check_set_stk_2
o2_trim_alt_path_check_load_ram1d3:
                MOVB    off(001d3h), r0
                MB      C, off(0012dh).5
                MB      PSWL.4, C
                LB      A, #052h
                JLT     o2_trim_step_threshold
                LB      A, #064h
o2_trim_step_threshold:
                CMPB    A, off(00132h)
                MB      off(0012dh).5, C
                MOVB    r6, #004h
                MOVB    r7, #004h
                CMPB    0d9h, #04fh
                JLT     o2_trim_step_threshold_load_er3
                CMPB    0d9h, #0a2h
                JGE     o2_trim_step_threshold_load_er3
                MOVB    r6, #004h
                MOVB    r7, #004h
o2_trim_step_threshold_load_er3:
                L       A, er3
                NOP
                NOP
                SB      off(00125h).0
                JEQ     o2_trim_dp300_read
                JBS     off(00120h).3, o2_trim_alt_gate
                JBR     off(00120h).2, o2_trim_dp304_common
                ST      A, off(0017ch)
                JBR     off(00120h).1, o2_trim_dp304_calc
                MOV     DP, #00308h
                MOV     er1, [DP]
                SJ      o2_trim_step_finalize2
o2_trim_dp300_read:
                ST      A, off(0017ch)
                MOV     DP, #00300h
                MOV     er1, [DP]
                JBS     off(00120h).0, o2_trim_step_finalize2
o2_trim_dp304_calc:
                MOV     DP, #00304h
                MOV     er0, [DP]
                L       A, #08000h
                MOV     er1, #08000h
                JBS     off(0011eh).3, cmp_0d9_028_load_er1
                L       A, #08000h
                MOV     er1, #08000h
cmp_0d9_028_load_er1:
                CMPB    0d9h, #057h
                JLT     o2_trim_mul_apply
                L       A, er1
o2_trim_mul_apply:
                MUL
                SLL     A
                ROL     er1
                JGE     o2_trim_step_finalize2
                MOV     er1, #0ffffh
o2_trim_step_finalize2:
                SB      PSWL.5
                SJ      o2_trim_result_check
o2_trim_alt_gate:
                MB      C, PSWL.4
                JLT     o2_trim_dp304_common
                JBR     off(0012dh).5, o2_trim_dp304_common
                MOV     DP, #00304h
                CMP     [DP], off(0015ah)
                JGT     o2_trim_dp304_calc
o2_trim_dp304_common:
                MOV     er1, off(0015ah)
                RB      PSWL.5
                JBR     off(0012dh).1, o2_trim_result_check
                ST      A, off(0017ch)
o2_trim_result_check:
                MB      C, PSWL.5
                JLT     o2_trim_er3_decrement
                JBS     off(0012dh).1, o2_trim_result_check_nop_acc
o2_trim_er3_decrement:
                L       A, er3
                LB      A, ACC
                MOV     DP, #0017ch
                JBR     off(0012dh).2, o2_trim_er3_decrement_decb_dp_ind
                LB      A, ACCH
                NOP
                NOP
                NOP
                NOP
                NOP
                INC     DP
o2_trim_er3_decrement_decb_dp_ind:
                DECB    [DP]
                JEQ     o2_trim_er3_decrement_store_dp_ind
                J       o2trim_gate_common2
o2_trim_er3_decrement_store_dp_ind:
                STB     A, [DP]
o2_trim_result_check_nop_acc:
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                JBS     off(00120h).0, o2_trim_bank_index_alt
                LB      A, (00296h-00280h)[USP]
                CMPB    A, off(00133h)
                LB      A, #004h
                JLT     o2_trim_flag_store2
                CLRB    A
o2_trim_flag_store2:
                STB     A, off(0017eh)
o2_trim_bank_index_calc:
                CLR     X1
                JBS     off(0012fh).0, o2_trim_rate_table_select
                INC     X1
                LB      A, off(00133h)
                CMPB    A, #073h
                JGE     o2_trim_rate_table_select
                INC     X1
                CMPB    A, #040h
                JGE     o2_trim_rate_table_select
                INC     X1
                SJ      o2_trim_rate_table_select
o2_trim_bank_index_alt:
                MOV     X1, #00004h
                LB      A, off(0017eh)
                JEQ     o2_trim_rate_table_select
                JBR     off(0012dh).1, o2_trim_bank_index_calc
                DECB    off(0017eh)
                JNE     o2_trim_bank_index_calc
o2_trim_rate_table_select:
                SLL     X1
                MOV     DP, #CloseLoopRate
                MB      C, PSWL.5
                JLT     o2_trim_table_offset_calc
                JBR     off(0012dh).1, o2_trim_table_offset_calc
                MOV     DP, #CloseLoopGoose
                JBS     off(0012dh).2, o2_trim_table_offset_calc
                LB      A, off(001d4h)
                JEQ     o2trim_apply_start
o2_trim_table_offset_calc:
                L       A, X1
                JBR     off(0011eh).3, o2_trim_table_offset_calc2
                ADD     A, #0000ch
o2_trim_table_offset_calc2:
                JBS     off(0011eh).0, o2_trim_rate_table_read
                ADD     A, #00030h
o2_trim_rate_table_read:
                ADD     DP, A
                LC      A, [DP]
                JBS     off(0012dh).2, o2trim_sub_clamp
                SJ      o2trim_add_clamp
o2trim_apply_start:
                MOVB    off(001d4h), #014h
                L       A, #00b00h
                JBS     off(0012fh).0, o2trim_add_clamp
                L       A, #00000h
                JBS     off(0011eh).3, cmp_x1_bound8_dispatch
                L       A, #00000h
cmp_x1_bound8_dispatch:
                CMP     X1, #00008h
                JEQ     o2trim_add_clamp
                MOVB    r0, #080h
                MOV     er2, #006f7h
                MOV     er3, #006f7h
                LB      A, #064h
                JBS     off(0011eh).3, to_o2trim_add_clamp
                MOVB    r0, #080h
                MOV     er2, #00618h
                MOV     er3, #00618h
                LB      A, #051h
to_o2trim_add_clamp:
                CMPB    A, off(00132h)
                JGT     to_o2trim_add_clamp_load_ram17a
                L       A, er2
                JBS     off(0011eh).0, to_o2trim_add_clamp_cmp_r0
                L       A, er3
to_o2trim_add_clamp_cmp_r0:
                CMPB    r0, off(00133h)
                JLE     o2trim_add_clamp
to_o2trim_add_clamp_load_ram17a:
                L       A, off(0017ah)
                CMPB    off(00132h), #052h
                JBS     off(0011eh).3, to_o2trim_add_clamp_if_ge_goto_o2trim_add_clamp
                CMPB    off(00132h), #052h
to_o2trim_add_clamp_if_ge_goto_o2trim_add_clamp:
                JGE     o2trim_add_clamp
                L       A, off(00178h)
o2trim_add_clamp:
                ADD     er1, A
                JGE     o2trim_closeloop_speed_check
                MOV     er1, #0ffffh
                SJ      o2trim_closeloop_speed_check
o2trim_sub_clamp:
                SUB     er1, A
                JGE     o2trim_closeloop_speed_check
                CLR     er1
o2trim_closeloop_speed_check:
                RB      PSWL.4
                L       A, #0bc15h
                CMP     A, er1
                JLE     o2trim_closeloop_speed_check_store_er1
                L       A, #tbl_5e20
                CMP     A, er1
                JLT     o2trim_speed_flags_store
                JBS     off(0011fh).3, o2trim_closeloop_speed_check_store_er1
                CMPB    0d9h, #001h
                JGE     o2trim_closeloop_speed_check_store_er1
                CMPB    0d8h, #001h
                JGE     o2trim_closeloop_speed_check_store_er1
                CMPB    0dah, #04dh
                JGT     o2trim_closeloop_speed_check_store_er1
                SB      PSWL.4
                L       A, #tbl_5e20
                CMP     A, er1
                JLT     o2trim_speed_flags_store
o2trim_closeloop_speed_check_store_er1:
                ST      A, er1
o2trim_speed_flags_store:
                MB      C, PSWL.4
                MB      off(00126h).4, C
                MOV     DP, #003abh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2trim_gate_common2
                LB      A, off(001e4h)
                JNE     o2trim_gate_common2
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
o2trim_bank_select_check:
                JBS     off(00120h).0, o2trim_gate_common2
                LB      A, off(001dbh)
                JEQ     o2trim_gate_common2
                MOV     X1, #00308h
                LB      A, #008h
o2trim_ect_offset_lookup:
                CMPB    0d9h, #02eh
                JGE     o2trim_ect_offset_lookup_rom_load_tbl_61b7_acc
                ADDB    A, #002h
o2trim_ect_offset_lookup_rom_load_tbl_61b7_acc:
                LC      A, o2trim_ect_offset_lookup_tbl[ACC]
                L       A, ACC
                ST      A, er0
                L       A, er1
                ST      A, er3
                CAL     injtimer_bank_calc1
                CAL     injtimer_bank_calc2
                MOV     er1, er3
o2trim_gate_common2:
                L       A, er1
injtimer_finalize_start:
                ST      A, off(0015ah)
                LB      A, #002h
                JBS     off(00130h).3, injtimer_finalize_start_cmp_acc
                LB      A, #004h
injtimer_finalize_start_cmp_acc:
                CMPB    A, off(00133h)
                MB      off(00130h).3, C
                LB      A, #0f2h
                JBS     off(00130h).4, injtimer_finalize_start_cmp_acc_2
                LB      A, #0f9h
injtimer_finalize_start_cmp_acc_2:
                CMPB    A, off(00132h)
                MB      off(00130h).4, C
                LB      A, off(0016eh)
                JBS     off(00125h).4, injtimer_finalize_start_store_ram165
                LB      A, #040h
                JBS     off(0012fh).7, injtimer_finalize_start_store_ram165
                JBS     off(0012bh).5, injtimer_finalize_start_store_ram165
                MOV     X1, #injtimer_finalize_start_tbl
                JBS     off(0011eh).3, injtimer_finalize_start_if_ram125_bit1_clr
                ADD     X1, #00003h
injtimer_finalize_start_if_ram125_bit1_clr:
                JBR     off(00125h).1, injtimer_finalize_start_cmp_ram15c
                JBS     off(00122h).2, injtimer_finalize_start_goto_7843
                JBR     off(00120h).0, injtimer_finalize_start_goto_7843
                SJ      injtimer_finalize_start_store_ram165
injtimer_finalize_start_goto_7843:
                J       injtimer_finalize_start_add_x1
                DB  000h,000h,000h
injtimer_finalize_start_cmp_ram15c:
                CMP     off(0015ch), #03000h
                JGE     injtimer_finalize_start_load_ram16b
                JBR     off(00130h).3, injtimer_finalize_start_load_ram16b
                JBS     off(00130h).4, injtimer_finalize_start_load_ram16b
                LB      A, 0c0h
                JBR     off(00123h).4, injtimer_finalize_start_if_ram123_bit1_clr
                CMPB    A, #003h
                JGE     injtimer_finalize_start_load_ram16b
injtimer_finalize_start_if_ram123_bit1_clr:
                JBR     off(00123h).1, injtimer_finalize_start_load_ram170
                LB      A, #004h
                JBS     off(0011eh).3, injtimer_finalize_start_cmp_acc_3
                LB      A, #004h
injtimer_finalize_start_cmp_acc_3:
                CMPB    A, 0d5h
                JGE     injtimer_finalize_start_load_ram170
injtimer_finalize_start_load_ram16b:
                LB      A, off(0016bh)
                SUBB    A, off(0016fh)
                JGE     injtimer_finalize_start_store_ram170
                CLRB    A
injtimer_finalize_start_store_ram170:
                STB     A, off(00170h)
                SJ      injtimer_finalize_start_goto_7879
injtimer_finalize_start_load_ram170:
                LB      A, off(00170h)
                MOVB    r0, #0fah
                MULB
                LB      A, ACCH
                STB     A, off(00170h)
                J       injtimer_finalize_start_addb_acc
injtimer_finalize_start_goto_7879:
                J       injtimer_finalize_start_load_r7
                DW  00000h
injtimer_finalize_start_store_ram165:
                STB     A, off(00165h)
                LB      A, off(00132h)
                MOV     X1, #tbl_injtimer_finalize
                CAL     table_interp_lookup
                CLRB    ACCH
                L       A, ACC
                ADD     A, #00080h
                CLRB    r0
                MOVB    r1, off(00169h)
                MUL
                SLL     A
                L       A, er1
                ROL     A
                NOP
                NOP
                ADD     A, #00200h
                ST      A, off(00160h)
                LB      A, #03ah
                JBS     off(0012dh).6, injtimer_finalize_start_cmp_acc_4
                LB      A, #040h
injtimer_finalize_start_cmp_acc_4:
                CMPB    A, off(00133h)
                MB      off(0012dh).6, C
                LB      A, #01ch
                JBS     off(0012dh).7, injtimer_finalize_start_cmp_acc_5
                LB      A, #01dh
injtimer_finalize_start_cmp_acc_5:
                CMPB    A, 0d1h
                MB      off(0012dh).7, C
                JBR     off(00121h).3, injtimer_gate_common
                J       injtimer_finalize_start_load_carry_stk
injtimer_finalize_start_cmp_ram0d9:
                CMPB    0d9h, #0e0h
                JGE     injtimer_gate_common
                CMPB    0d9h, #044h
                JLT     injtimer_gate_common
                JBR     off(0012dh).6, injtimer_gate_common
                JBR     off(0012dh).7, injtimer_gate_common
                JBR     off(00121h).0, injtimer_gate_common
                JBS     off(0012bh).5, injtimer_gate_common
                JBS     off(00125h).1, injtimer_gate_common
                JBS     off(0012dh).2, injtimer_gate_common
                LB      A, #014h
                SJ      injtimer_gate_common_store_ram168
injtimer_gate_common:
                LB      A, off(00168h)
                SUBB    A, #001h
                JGE     injtimer_gate_common_store_ram168
                CLRB    A
injtimer_gate_common_store_ram168:
                STB     A, off(00168h)
                LB      A, off(00164h)
                JBS     off(0012fh).7, injtimer_gate_common_store_r1
                LB      A, off(00165h)
injtimer_gate_common_store_r1:
                STB     A, r1
                CLRB    r0
                SRL     er0
                LB      A, off(00166h)
                JEQ     injtimer_gate_common_load_ram167
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1
injtimer_gate_common_load_ram167:
                LB      A, off(00167h)
                JEQ     injtimer_mul_chain1
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1
injtimer_mul_chain1:
                MOVB    ACCH, #001h
                LB      A, off(00168h)
                MUL
                MOVB    r1, r2
                MOVB    r0, ACCH
                L       A, off(00162h)
                MUL
                MOV     er0, er1
                L       A, off(00160h)
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
injtimer_mul_chain2:
                L       A, off(0015eh)
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
injtimer_mul_clamp:
                MOV     er0, #0ffffh
injtimer_mul_chain3:
                L       A, off(0015ch)
                MUL
                MOV     er0, er1
injtimer_mul_final:
                L       A, off(0015ah)
                MUL
                J       injtimer_mul_final_load_ram158
dwell_rpm_hyst_check_if_ram125_bit4_set:
                JBS     off(00125h).4, dwell_zero_result
                LB      A, off(00133h)
                CMPB    A, #0c0h
                JGE     dwell_zero_result
                JBR     off(00129h).0, dwell_zero_result
                LB      A, #004h
                JBS     off(00123h).5, dwell_rpm_gate2
                LB      A, #004h
                CMPB    0f3h, #096h
                JLT     dwell_zero_result
dwell_rpm_gate2:
                CMPB    off(00133h), #002h
                JBS     off(00123h).5, dwell_rpm_gate3
                J       dwell_rpm_gate2_load_carry_ram130_bit6
                DB  000h
dwell_rpm_gate3:
                JLT     dwell_zero_result
                CMPB    A, 0c1h
                JGE     dwell_zero_result
                MOVB    r0, off(0018dh)
                CMPB    off(00133h), #05ah
                JGE     dwell_value_select
                MOVB    r0, off(0018bh)
dwell_value_select:
                MOVB    r1, #018h
                JBS     off(00123h).5, dwell_clamp_check
                MOVB    r0, off(0018ch)
                MOVB    r1, #010h
dwell_clamp_check:
                LB      A, 0c1h
                CMPB    A, r1
                JLE     dwell_mul_apply
                LB      A, r1
dwell_mul_apply:
                MULB
                L       A, ACC
                SRL     A
                JBS     off(00123h).5, dwell_store_result
                VCAL    7
                SJ      dwell_store_result
dwell_zero_result:
                CLR     A
dwell_store_result:
                ST      A, off(00146h)
                CLRB    r4
                RC
                JBS     off(00125h).4, rpm_accel_skip
                JBR     off(00122h).3, rpm_accel_skip
                JBS     off(0012ch).7, rpm_accel_track_calc
                JBS     off(00122h).4, rpm_accel_alt_path
                L       A, (0025ch-00280h)[USP]
                CLRB    r5
                SJ      rpm_accel_track_store
rpm_accel_track_calc:
                MOV     er3, off(00138h)
                MOVB    r5, off(0013ah)
                CLRB    r0
                MOVB    r1, #080h
                L       A, 0c4h
                CAL     rpm_accel_track_helper
rpm_accel_track_store:
                ST      A, off(00138h)
                MOVB    off(0013ah), r5
                CLRB    r4
                SUB     A, 0c4h
                MB      off(0012ch).6, C
                JLT     rpm_accel_fault_path
                JBS     off(00123h).6, rpm_accel_secondary_calc
                CMP     0c6h, #00000h
                SJ      rpm_accel_gate_result
rpm_accel_fault_path:
                VCAL    7
                JBR     off(00123h).6, rpm_accel_secondary_calc
                CMP     0c6h, #00000h
rpm_accel_gate_result:
                JGE     rpm_accel_clamp
rpm_accel_secondary_calc:
                CLRB    r0
                MOVB    r1, #020h
                CMPB    0d9h, #034h
                JGE     rpm_accel_mul_apply
                JBS     off(0011eh).3, rpm_accel_mul_apply
                CMPB    0cch, #005h
                JLT     rpm_accel_mul_apply
                MOVB    r1, #020h
rpm_accel_mul_apply:
                MUL
                MOVB    r4, #02dh
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
rpm_accel_clamp:
                SC
rpm_accel_skip: MB      off(0012ch).7, C
rpm_accel_alt_path:
                LB      A, r4
                JEQ     rpm_accel_store_0x148
                JBS     off(0012ch).6, rpm_accel_store_0x148
                VCAL    6
rpm_accel_store_0x148:
                STB     A, off(00148h)
                JBR     off(0011eh).3, rpm_decel_zero
                JBR     off(00119h).5, rpm_decel_ect_gate
                RB      off(00130h).7
                SJ      rpm_decel_zero
rpm_decel_ect_gate:
                CMPB    0d9h, #0ffh
                JLT     rpm_decel_zero
                MOVB    r0, #001h
                MOV     er1, #00001h
                CMPB    0d9h, #0ffh
                JLT     rpm_decel_calc
                MOVB    r0, #001h
                MOV     er1, #00001h
rpm_decel_calc: MOV     DP, #00311h
                LB      A, [DP]
                ADDB    A, #001h
                CMPB    A, 0d4h
                JLT     rpm_decel_diff_check
                JBS     off(00123h).6, rpm_decel_diff_check
                CMP     0c6h, #00040h
                JLT     rpm_decel_diff_check
                JBS     off(00130h).7, rpm_decel_flag_result
                MOVB    off(001e5h), #001h
                SB      off(00130h).7
rpm_decel_flag_result:
                CMPB    off(001e5h), #000h
                JNE     rpm_decel_mul_calc
rpm_decel_diff_check:
                L       A, off(0014ah)
                SUB     A, er1
                JGE     rpm_decel_store
rpm_decel_zero: CLR     A
                SJ      rpm_decel_store
rpm_decel_mul_calc:
                CLRB    r1
                L       A, 0c6h
                MUL
                MOV     er0, #00000h
                CMP     er1, #00000h
                JNE     rpm_decel_result_select
                CMP     A, er0
                JLT     rpm_decel_store
rpm_decel_result_select:
                L       A, er0
rpm_decel_store:
                ST      A, off(0014ah)
                CLR     A
                CLRB    r0
                JBS     off(00125h).4, rpm_decel_flags_clear
                JBS     off(00124h).0, rpm_decel_flags_clear
                MOVB    r0, #004h
                JBS     off(00124h).2, rpm_decel_flags_clear
                MOVB    r0, off(00156h)
                CMPB    r0, #000h
                JNE     rpm_decel_table_lookup
                JBR     off(00123h).1, rpm_decel_counter_check
                CMPB    0d5h, #008h
                JGE     rpm_decel_flags_clear
rpm_decel_counter_check:
                MOVB    r1, off(00157h)
                CMPB    r1, #000h
                JEQ     rpm_decel_diff_check2
                DECB    r1
                JNE     rpm_decel_store_0x150_store_ram14c
rpm_decel_diff_check2:
                L       A, off(00152h)
                JEQ     rpm_decel_flags_clear
                SUB     A, off(00154h)
                JGE     rpm_decel_flags_clear
                CLR     A
                SJ      rpm_decel_flags_clear
rpm_decel_table_lookup:
                LB      A, off(00133h)
                MOV     X1, #tbl_rpm_decel
                VCAL    0
                ; warning: had to flip DD
                CMP     A, 0c8h
                CLR     A
                MOVB    r0, off(00156h)
                DECB    r0
                JBS     off(00123h).7, rpm_decel_store_0x150
                JGE     rpm_decel_store_0x150
                L       A, #00145h
                JBS     off(0012eh).5, rpm_decel_mul_final
                L       A, #000fah
                JBS     off(0012eh).6, rpm_decel_mul_final
                L       A, #0004bh
                JBR     off(0011eh).3, rpm_decel_mul_final
                L       A, #0007dh
rpm_decel_mul_final:
                MOV     er0, off(00184h)
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
rpm_decel_result_clear:
                CLRB    r0
rpm_decel_flags_clear:
                RB      off(0012eh).5
                RB      off(0012eh).6
rpm_decel_store_0x150:
                ST      A, off(00152h)
                MOVB    r1, #004h
rpm_decel_store_0x150_store_ram14c:
                ST      A, off(0014ch)
                MOVB    off(00156h), r0
                MOVB    off(00157h), r1
                JBR     off(00124h).4, tipin_time_calc
                CLR     A
                MOV     X1, A
                ST      A, 003b4h[X1]
                ST      A, 003b6h[X1]
                ST      A, 003b8h[X1]
                ST      A, 003bah[X1]
                ST      A, 003bch[X1]
                ST      A, 003a2h[X1]
                J       postinj_rpm_check
tipin_time_calc:
                L       A, off(00142h)
                JBR     off(0012bh).3, tipin_time_sum
                CMPB    0f2h, #004h
                MB      off(0012bh).3, C
                ADD     A, #0007dh
                JLT     tipin_time_clamp
tipin_time_sum: ADD     A, off(00144h)
                JLT     tipin_time_clamp
                ADD     A, off(0014ah)
                JLT     tipin_time_clamp
                ADD     A, off(0014ch)
                JGE     tipin_time_finalize
tipin_time_clamp:
                L       A, #0ffffh
tipin_time_finalize:
                ST      A, er0
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
tipin_overflow_check1:
                ADD     A, er0
                JGE     tipin_result_store
tipin_overflow_check2:
                CMP     A, #08000h
                JLT     tipin_result_store
tipin_overflow_clamp:
                L       A, #07fffh
tipin_result_store:
                ST      A, er3
                MOV     X2, A
                L       A, off(00140h)
                MOV     er0, off(00158h)
                MUL
                SRL     er1
                ROR     A
                LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     injtimer_bank_a_calc
                L       A, #0ffffh
injtimer_bank_a_calc:
                ST      A, er2
                XCHG    A, er3
                VCAL    4
                JBR     off(00124h).5, injtimer_bank_a_store
                CLR     A
injtimer_bank_a_store:
                MOV     DP, #003a2h
                ST      A, [DP]
                L       A, er3
                MOV     DP, #003b4h
                MOV     er0, [DP]
                ST      A, [DP]
                JBS     off(00125h).4, injtimer_bank_b_zero
                JBS     off(0012eh).4, injtimer_bank_b_zero
                CMPB    off(00133h), #0a0h
                JGE     injtimer_bank_b_zero
                CMP     off(0014ch), #00000h
                JNE     injtimer_bank_b_zero
                SUB     A, er0
                JLT     injtimer_bank_b_zero
                CMP     A, #000fah
                JGE     injtimer_bank_b_clamp
injtimer_bank_b_zero:
                CLR     A
                SJ      injtimer_bank_b_store
injtimer_bank_b_clamp:
                MOV     er0, #003e8h
                CMP     A, er0
                JGE     injtimer_bank_b_default
                ST      A, er0
injtimer_bank_b_default:
                CLR     A
                MOVB    ACCH, #066h
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     injtimer_bank_b_store
                L       A, #0ffffh
injtimer_bank_b_store:
                ST      A, off(00150h)
                L       A, off(0014ch)
                CMP     A, off(00150h)
                MB      off(0012ch).5, C
                JGE     injtimer_bank_c_check
                L       A, off(00150h)
injtimer_bank_c_check:
                L       A, ACC
                JEQ     injtimer_bank_c_store
                ADD     A, off(00144h)
                JGE     injtimer_bank_c_scale
                L       A, #0ffffh
injtimer_bank_c_scale:
                CAL     scale_mul5_div4
injtimer_bank_c_store:
                MOV     X1, A
                JBR     off(0012ch).5, injtimer_critsection_start
                CLR     A
injtimer_critsection_start:
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                MOV     off(00194h), X1
                ST      A, off(00190h)
                ST      A, off(00192h)
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                LCB     A, injtimer_critsection_start_tbl
                JEQ     injtimer_critsection_start_load_dp_ind
                MOV     X1, #CylinderIGNCorrect
cylinder_ign_correct_loop:
                INC     DP
                INC     DP
                L       A, er2
                JBR     off(00125h).1, cylinder_ign_correct_apply
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
cylinder_ign_correct_apply:
                MOV     er3, X2
                XCHG    A, er3
                VCAL    4
                CAL     scale_mul5_div4
                ST      A, [DP]
                INC     X1
                CMP     DP, #003bch
                JLT     cylinder_ign_correct_loop
                SJ      postinj_rpm_check
injtimer_critsection_start_load_dp_ind:
                L       A, [DP]
                CAL     scale_mul5_div4
                CLR     X1
                ST      A, 003b6h[X1]
                ST      A, 003b8h[X1]
                ST      A, 003bah[X1]
                ST      A, 003bch[X1]
postinj_rpm_check:
                LB      A, #0c5h
                JBS     off(0012bh).2, postinj_rpm_flag_store
                LB      A, #0c8h
postinj_rpm_flag_store:
                CMPB    A, off(00133h)
                MB      off(0012bh).2, C
                LB      A, off(0013dh)
                JNE     deadtime_retry_check
                LB      A, #005h
                JBS     off(00125h).4, deadtime_retry_store_goto_injector_effective_pw_store
                MOVB    r6, #007h
                L       A, off(0011ah)
                AND     A, #01034h
                JNE     to_gio_mode_dispatch
                MOVB    r6, #006h
                JBS     off(0011fh).5, to_gio_mode_dispatch
                MOVB    r6, #006h
                JBS     off(0012ch).5, to_gio_mode_dispatch
                CMPB    0d9h, #02eh
                JGE     deadtime_ect_offset
                MOVB    r6, #007h
                JBS     off(00120h).0, to_gio_mode_dispatch
deadtime_ect_offset:
                CLR     DP
                LB      A, 0d9h
                CMPB    A, #0aeh
                JLT     deadtime_ect_offset_load_imm
                ADD     DP, #00003h
deadtime_ect_offset_load_imm:
                LB      A, #038h
                JBS     off(0012bh).1, deadtime_ect_offset_cmp_ram0be
                LB      A, #030h
deadtime_ect_offset_cmp_ram0be:
                CMPB    0beh, A
                MB      off(0012bh).1, C
                LB      A, #077h
                JBS     off(0012bh).0, deadtime_voltage_flag_store
                LB      A, #070h
deadtime_voltage_flag_store:
                CMPB    0beh, A
                MB      off(0012bh).0, C
                JGE     deadtime_voltage_flag_store_rom_load_tbl_6106_dp
                INC     DP
                JBR     off(0012bh).1, deadtime_voltage_flag_store_rom_load_tbl_6106_dp
                INC     DP
deadtime_voltage_flag_store_rom_load_tbl_6106_dp:
                LCB     A, deadtime_voltage_flag_store_tbl[DP]
                STB     A, r6
                SJ      to_gio_mode_dispatch
deadtime_retry_check:
                MB      C, 0b7h.0
; --- Injector deadtime/battery-voltage compensation (0x21A5-0x2225ish): selects an ECT/
; battery-voltage-indexed offset into InjectorTable (real calibration field -- injector-size
; dependent deadtime compensation), applies it, then computes effective injector pulse width
; after subtracting deadtime.
                JGE     deadtime_retry_store
                LB      A, #005h
deadtime_retry_store:
                SUBB    A, #001h
                STB     A, off(0013dh)
                LB      A, #00bh
deadtime_retry_store_goto_injector_effective_pw_store:
                SJ      injector_effective_pw_store
to_gio_mode_dispatch:
                MOV     DP, #003b4h
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
injector_effective_pw_calc:
                SJ      injector_effective_pw_store
injector_effective_pw_skip:
                CLRB    A
injector_effective_pw_store:
                STB     A, off(0013bh)
                LB      A, #0c2h
                JBS     off(00124h).0, rpm_hyst_flag_124_0
                LB      A, #0c5h
rpm_hyst_flag_124_0:
                CMPB    A, off(00133h)
                MB      off(00124h).0, C
                LB      A, #0edh
                JBS     off(00124h).1, rpm_hyst_flag_124_1
                LB      A, #0f0h
rpm_hyst_flag_124_1:
                CMPB    A, off(00133h)
                MB      off(00124h).1, C
                JBR     off(00121h).3, crank_edge_carry_clear
                JBR     off(0011eh).6, crank_edge_carry_clear
                LB      A, off(001e1h)
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
crank_edge_sync_check:
                JEQ     crank_edge_carry_set
crank_edge_direction_toggle:
                XORB    PSWH, #080h
                MB      0b8h.2, C
                JGE     crank_edge_carry_clear
                MOVB    off(001e1h), #019h
crank_edge_carry_clear:
                RC
                SJ      dtc27_code27_latch
crank_edge_carry_set:
                SC
dtc27_code27_latch:
                MB      0b3h.2, C
                JBR     off(0011eh).7, crank_edge_flag_store_clear_acc
                JBS     off(00125h).4, crank_edge_flag_store_clear_acc
                LB      A, #001h
                JBS     off(00131h).3, crank_edge_flag_store_cmp_ram0d9
                LB      A, #000h
crank_edge_flag_store_cmp_ram0d9:
                CMPB    0d9h, A
                MB      off(00131h).3, C
                LB      A, #0ffh
                JBS     off(00131h).4, crank_edge_flag_store_cmp_acc
                LB      A, #0ffh
crank_edge_flag_store_cmp_acc:
                CMPB    A, off(00132h)
                MB      off(00131h).4, C
                LB      A, #0ffh
                JBS     off(00131h).5, crank_edge_flag_store_cmp_ram0be
                LB      A, #0ffh
crank_edge_flag_store_cmp_ram0be:
                CMPB    0beh, A
                MB      off(00131h).5, C
                LB      A, #000h
                JBS     off(00124h).7, crank_edge_flag_store_cmp_acc_2
                LB      A, #001h
crank_edge_flag_store_cmp_acc_2:
                CMPB    A, off(00133h)
                MB      off(00124h).7, C
                MOV     DP, #003abh
                LB      A, [DP]
                CMPB    A, #032h
                JNE     crank_edge_flag_store_if_ram124_bit7_set
                MOV     X1, #crank_edge_flag_store_tbl
                LB      A, off(00133h)
                CAL     table_interp_lookup
                SJ      crank_edge_flag_store_clear_carry
crank_edge_flag_store_if_ram124_bit7_set:
                JBS     off(00124h).7, crank_edge_flag_store_clear_acc
                JBS     off(0011fh).5, crank_edge_flag_store_clear_acc
                L       A, off(0011ah)
                AND     A, #0907ch
                JNE     crank_edge_flag_store_clear_acc
                JBR     off(0011bh).3, crank_edge_flag_store_if_ram124_bit2_set
                JBR     off(00122h).5, crank_edge_flag_store_clear_acc
                LB      A, (0029eh-00280h)[USP]
                CMPB    A, #0ffh
                JLT     crank_edge_flag_store_clear_acc
                CMPB    A, #0ffh
                JGT     crank_edge_flag_store_clear_acc
crank_edge_flag_store_if_ram124_bit2_set:
                JBS     off(00124h).2, crank_edge_flag_store_clear_acc
                JBS     off(00125h).5, crank_edge_flag_store_clear_acc
                JBR     off(00120h).2, crank_edge_flag_store_clear_acc
                J       crank_edge_flag_store_load_carry_stk
crank_edge_flag_store_if_ram11d_bit2_set:
                JBS     off(0011dh).2, crank_edge_flag_store_if_ram125_bit2_clr
                JBS     off(0011dh).4, crank_edge_flag_store_if_ram125_bit2_clr
                JBS     off(00125h).1, crank_edge_flag_store_if_ram131_bit3_clr
crank_edge_flag_store_clear_acc:
                CLRB    A
crank_edge_flag_store_clear_carry:
                RC
                SJ      crank_edge_flag_store_store_carry_ram125_bit6
crank_edge_flag_store_if_ram125_bit2_clr:
                JBR     off(00125h).2, crank_edge_flag_store_clear_acc
crank_edge_flag_store_if_ram131_bit3_clr:
                JBR     off(00131h).3, crank_edge_flag_store_clear_acc
                JBR     off(00131h).4, crank_edge_flag_store_clear_acc
                JBS     off(00131h).5, crank_edge_flag_store_clear_acc
                MOVB    r3, off(001c8h)
                MOVB    r2, off(00133h)
                MOVB    r6, #012h
                MB      C, 0b8h.4
                MB      PSWL.4, C
                MOV     X1, #crank_edge_flag_store_tbl_3
                CAL     newval_table3_call_sub_clear_acc
                MOV     X2, A
                LB      A, r6
                STB     A, off(001c8h)
                MOVB    r2, 0bfh
                MOV     X1, #crank_edge_flag_store_tbl_2
                MOVB    r3, off(001bdh)
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     newval_table3_call_sub_clear_acc
                MOVB    off(001bdh), r6
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r3, off(001c8h)
                MOVB    r2, r6
                MOV     er3, X2
                MOV     X2, A
                MOV     X1, #crank_edge_flag_store_tbl_4
                RB      PSWL.5
                CAL     table2d_lookup_interp
                LCB     A, fuelmap_base_lookup_tbl
                MOVB    A, r4
                JEQ     crank_edge_flag_store_store_r0
                LB      A, (0029dh-00280h)[USP]
                MB      C, ACC.7
                JGE     crank_edge_flag_store_addb_acc
                ADDB    A, r4
                JLT     crank_edge_flag_store_store_r0
                CLRB    A
                SJ      crank_edge_flag_store_store_r0
crank_edge_flag_store_addb_acc:
                ADDB    A, r4
                JGE     crank_edge_flag_store_store_r0
                LB      A, #0ffh
crank_edge_flag_store_store_r0:
                STB     A, r0
                MOV     DP, #00392h
                LB      A, [DP]
                L       A, ACC
                MULB
                SLL     A
                LB      A, ACCH
                JGE     crank_edge_flag_store_set_carry
                LB      A, #0ffh
crank_edge_flag_store_set_carry:
                SC
crank_edge_flag_store_store_carry_ram125_bit6:
                MB      off(00125h).6, C
                STB     A, (0029fh-00280h)[USP]
                CAL     crank_edge_helper
                SB      0b6h.4
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                J       int1_rti_epilogue
; [flow] int_spurious_irq_trap: every interrupt vector this ROM never enables points here. It stamps trap
;    reason 045h and goes through fault_retry_check (retry budget, then BRK -> int_break re-init).
int_spurious_irq_trap:
                MOVB    0f5h, #045h
                SJ      fault_retry_check
int_WDT:        MOVB    0f5h, #044h
fault_retry_check:
                LB      A, 0f6h
                JEQ     fault_giveup_latch
                DECB    0f6h
                JNE     fault_trigger_brk
fault_giveup_latch:
                SB      0b7h.1
fault_trigger_brk:
                BRK
int_start:      MOVB    0f5h, #046h
                RB      0b7h.1
int_break:      MOVB    WDT, #03ch
                MOV     SSP, #0047eh
                MOV     LRB, #00010h
                CLR     off(PSW)
                LB      A, off(000f5h)
                STB     A, off(000afh)
                JNE     breset_check_reason_46_47
                MOVB    off(000f5h), #04eh
                SJ      fault_retry_check
breset_check_reason_46_47:
                CMPB    A, #046h
                JEQ     breset_reason_46_or_47_common
                CMPB    A, #047h
                JNE     breset_check_p4_1
breset_reason_46_or_47_common:
                CLRB    off(000afh)
                MOV     DP, #04700h
                LB      A, [DP]
                SRLB    A
                MB      off(000b7h).0, C
                JBS     off(000b7h).1, breset_check_p4_1
                MOVB    off(000f6h), #020h
breset_check_p4_1:
                JBR     off(P4).1, selftest_reg_stuckbit_check
                J       int_NMI
selftest_reg_stuckbit_check:
                L       A, #05555h
                XCHG    A, SSP
                XCHG    A, SSP
                CMP     A, #05555h
                JNE     selftest_fail_041
                ST      A, IE
                CMP     A, IE
                JNE     selftest_fail_041
                L       A, #01555h
                MOV     LRB, A
                CMP     A, LRB
                JNE     selftest_fail_041
                L       A, #0aaaah
                XCHG    A, SSP
                XCHG    A, SSP
                CMP     A, #0aaaah
                JNE     selftest_fail_041
                ST      A, IE
                CMP     A, IE
                JNE     selftest_fail_041
                L       A, #00aaah
                MOV     LRB, A
                CMP     A, LRB
                JNE     selftest_fail_041
                CLR     A
                ST      A, IE
                ST      A, 0f8h
                ST      A, 0fah
                MOV     LRB, #00010h
                LB      A, #055h
                XCHGB   A, PSWL
                XCHGB   A, PSWL
                CMPB    A, #0ddh
                JNE     selftest_fail_041
                LB      A, #0aah
                XCHGB   A, PSWL
                XCHGB   A, PSWL
                CMPB    A, #0eah
                JNE     selftest_fail_041
                SB      PSWH.0
                MB      C, PSWH.0
                MB      PSWH.6, C
                JGE     selftest_fail_041
                JNE     selftest_fail_041
                RB      PSWH.0
                MB      C, PSWH.0
                MB      PSWH.6, C
                JLT     selftest_fail_041
                JNE     periph_init_start
selftest_fail_041:
                MOVB    0f5h, #041h
                BRK
periph_init_start:
                CLRB    off(PRPHF)
                LB      A, #0ffh
                MOVB    off(P0), #0ebh
                STB     A, off(P0IO)
                MOVB    off(P1), #044h
                STB     A, off(P1IO)
                MOVB    off(P2), #01fh
                STB     A, off(P2IO)
                CLRB    off(P2SF)
                MOVB    off(P3), #0efh
                MOVB    off(TCON0), #08bh
                CLR     A
                ST      A, off(TM0)
                ST      A, off(TMR0)
                MOVB    off(TCON1), #04fh
                ST      A, off(TM1)
                ST      A, off(TMR1)
                MOVB    off(TCON2), #082h
                ST      A, off(TM2)
                ST      A, off(TMR2)
                MOVB    off(TCON3), #08fh
                MOV     off(TM3), #00001h
                ST      A, off(TMR3)
                MOVB    off(P3IO), #0b1h
                MOVB    off(P3SF), #0ffh
                CLRB    off(EXION)
                SB      off(TCON0).2
                RB      off(TCON0).2
                MOVB    off(P4), #0f7h
                L       A, #0ff00h
                MOVB    off(PWCON0), #03eh
                ST      A, off(PWMC0)
                ST      A, off(PWMR0)
                MOVB    off(PWCON1), #07eh
                ST      A, off(PWMC1)
                ST      A, off(PWMR1)
                MOVB    off(P4IO), #00dh
                MOVB    off(P4SF), #0fch
                SB      off(TCON0).4
                SB      off(TCON1).4
                SB      off(TCON2).4
                XCHG    A, ACC
                SB      off(TCON3).4
                CLR     off(IRQ)
                LB      A, #002h
periph_init_delay_loop_load_dp:
                MOV     DP, #00177h
periph_init_delay_loop:
                DEC     DP
                JEQ     periph_init_delay_loop_load_ram0f5
                MBR     C, off(P4)
                JLT     periph_init_delay_loop
                MOV     DP, #00177h
periph_init_delay_loop_dec_dp:
                DEC     DP
                JEQ     periph_init_delay_loop_load_ram0f5
                MBR     C, off(P4)
                JGE     periph_init_delay_loop_dec_dp
                MOV     DP, #000b2h
periph_init_delay_loop_dec_dp_2:
                DEC     DP
                JEQ     periph_init_delay_loop_load_ram0f5
                MBR     C, off(P4)
                JLT     periph_init_delay_loop_dec_dp_2
                INCB    ACC
                CMPB    A, #004h
                JNE     periph_init_delay_loop_load_dp
                RB      off(IRQH).5
                JNE     periph_init_delay_loop_load_imm
periph_init_delay_loop_load_ram0f5:
                MOVB    off(000f5h), #04ch
                BRK
periph_init_delay_loop_load_imm:
                L       A, #0ffffh
                ST      A, off(PWMR0)
                ST      A, off(PWMR1)
                RB      off(P4SF).3
                L       A, #05555h
                MOV     X1, A
                CMP     A, X1
                JNE     selftest_fail_042
                MOV     X2, A
                CMP     A, X2
                JNE     selftest_fail_042
                SLL     A
                MOV     X1, A
                CMP     A, X1
                JNE     selftest_fail_042
                MOV     X2, A
                CMP     A, X2
                JEQ     ram_clear_loop1
selftest_fail_042:
                MOVB    off(000f5h), #042h
                BRK
ram_clear_loop1:
                MOV     LRB, #00040h
                MOV     X1, #003fah
ram_clear_loop1_body:
                MOV     DP, 00084h[X1]
                L       A, #05555h
                CAL     selftest_regbank_verify
                SLL     A
                CAL     selftest_regbank_verify
                SUB     X1, #00002h
                JGE     ram_clear_loop1_body
                MOV     LRB, #00041h
                CMPB    0f5h, #047h
                JNE     restore_trapstate_after_ramclear
                J       ram_clear_loop1_body_load_dp
cfgvariant_set_bit0_from_2edh_3_if_ram232_bit5_clr:
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
cfgvariant_index_lookup:
                CLR     A
                LB      A, r7
                LCB     A, cfgvariant_index_lookup_tbl[ACC]
                CMPB    A, r6
                JEQ     cfgvariant_clear_232h_bits45
                MOVB    0f5h, #043h
                BRK
cfgvariant_clear_232h_bits45:
                ANDB    off(00232h), #0cfh
cfgvariant_check_320h_bit7:
                MOV     DP, #00320h
                RB      [DP].7
                CAL     cfgvariant_checksum_calc
                JBR     off(00232h).2, cfgvariant_check_232h_bits01
                JBR     off(00232h).3, cfgvariant_check_232h_bits01
                CAL     cfgvariant_check_320h_bit7_sub_clear_acc
                ANDB    off(00232h), #0f3h
cfgvariant_check_232h_bits01:
                JBR     off(00232h).0, restore_trapstate_after_ramclear
                JBR     off(00232h).1, restore_trapstate_after_ramclear
                CAL     cfgvariant_ram_init
                ANDB    off(00232h), #0fch
restore_trapstate_after_ramclear:
                MOV     LRB, #00010h
                MB      C, off(000b7h).0
                MB      r0.0, C
                MB      C, off(000b7h).1
                MB      r0.1, C
                MOVB    r1, off(000afh)
                MOVB    r2, off(000f6h)
                MOVB    r3, off(000f5h)
                CLR     A
                MOV     USP, #00356h
                MOV     DP, #00480h
ram_clear_loop2:
                DEC     DP
                DEC     DP
                ST      A, [DP]
                CMP     DP, off(00086h)
                JGT     ram_clear_loop2
                CMP     DP, #00098h
                JLE     clear_0x324_high_nibble
                MOV     USP, #00098h
                CMPB    r3, #047h
                JNE     ram_clear_loop2
                MOV     DP, #00300h
                SJ      ram_clear_loop2
clear_0x324_high_nibble:
                MOV     DP, #00324h
                LB      A, [DP]
                ANDB    A, #0f0h
                STB     A, [DP]
                MB      C, r0.0
                MB      off(000b7h).0, C
                MB      C, r0.1
                MB      off(000b7h).1, C
                MOVB    off(000afh), r1
                MOVB    off(000f6h), r2
                MOVB    off(000f5h), r3
                MOV     LRB, #00041h
                SC
                LB      A, 0afh
                JNE     fuelpump_prime_check
                MOVB    off(002d1h), #014h
                RC
fuelpump_prime_check:
                MB      off(00230h).5, C
; --- Runtime state init: A/D channel setup, initial sensor snapshot, working-RAM seeding,
; and diagnostic-serial baud/config setup, run once during boot after the self-test/RAM-clear
; passes above. Ends by jumping to stack_sanity_check (0x3359) before falling into the main loop.
; Individual working-RAM addresses here (0xD8-0xE1, 0xDC-0xDF, etc.) are not yet traced to
; specific named parameters -- confidently identified: ADCR2H/ADCR4/ADCR6 (A/D conversion
; results), tbl_boot_copy_block (a calibration table copied verbatim into 0x1D1-0x1DD), and
; STTM/STTMR/STTMC/STCON/SRCON (serial timer + control regs -- diagnostic link baud setup).
                MOV     USP, #00180h
                CLR     A
                ST      A, IE
                MOV     DP, A
                CLRB    ADSEL
                MOVB    ADSCAN, #010h
                RB      IRQH.4
adc_wait_loop:  MB      r0.0, C
                JRNZ    DP, adc_wait_loop
                CAL     idle_helper1
                LB      A, P2
                ANDB    A, #0e0h
                JNE     adc_wait_loop
                MOVB    0f7h, #001h
                CAL     selftest_reason_range_check_entry
                L       A, ADCR4
                ST      A, 09ch
                LB      A, ADCR2H
                STB     A, 0e1h
                MOV     DP, #00379h
                STB     A, [DP]
                MOV     DP, #003c6h
                LB      A, [DP]
                STB     A, 0dah
                MOV     DP, #003cdh
                LB      A, [DP]
                STB     A, 0dbh
                MOVB    0d8h, #057h
                MOVB    0d9h, #03bh
                MOVB    0bch, #0f9h
                J       adc_wait_loop_load_imm
                DB  0FFh
adc_wait_loop_store_ram0df:
                STB     A, 0dfh
                L       A, ADCR6
                ST      A, 0bah
                LB      A, ACCH
                MOV     DP, #00374h
                STB     A, [DP]
                LB      A, #0a0h
                STB     A, off(00237h)
                STB     A, (00132h-00180h)[USP]
                STB     A, 0bdh
                MOV     DP, #00372h
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
clamp_to_0xff:  LB      A, #0ffh
clamp_result_store:
                STB     A, 0d4h
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
                STB     A, (0018fh-00180h)[USP]
                MOVB    0e5h, #031h
                MOV     0e6h, #0ffffh
                MOVB    off(002a0h), #0ffh
                MOVB    off(002b1h), #001h
                LB      A, 003d0h[X1]
                STB     A, 00375h[X1]
                CAL     ect_step_helper
                CLRB    A
                MOV     DP, #001adh
clamp_result_store_rom_load_tbl_6d6b_dp:
                LCB     A, clamp_result_store_tbl[DP]
                STB     A, [DP]
                INC     DP
                CMP     DP, #001bah
                JNE     clamp_result_store_rom_load_tbl_6d6b_dp
                MOVB    00393h[X1], #0ffh
                MOVB    off(002c6h), #0f9h
                MOVB    off(002bbh), #002h
                MOVB    off(002bch), #002h
                MOVB    00377h[X1], #053h
                LB      A, 00310h[X1]
                MOVB    ACC, #07bh
                JNE     serial_baud_store_common
                STB     A, 00311h[X1]
serial_baud_store_common:
                STB     A, 00378h[X1]
                SB      off(00225h).1
                CMPB    0f5h, #047h
                JEQ     serial_baud_select_done
                MOV     DP, #00312h
                L       A, #00266h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                L       A, #00100h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOVB    0031ah[X1], #03bh
serial_baud_select_done:
                MOVB    off(002cdh), #032h
                MOVB    r0, #01ch
                MOVB    r1, #08ch
                LB      A, #0dfh
                MOV     DP, #00356h
                MB      C, [DP].1
                JLT     serial_baud_apply
                MOVB    r0, #031h
                MOVB    r1, #0a1h
                LB      A, #0fbh
serial_baud_apply:
                STB     A, STTM
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
                CLRB    0f5h
                J       stack_sanity_check
vcal_3:         MOV     DP, #00356h
                MB      C, [DP].1
                JLT     vcal_3_load_dp
                J       vcal_3_load_ram0fa
vcal_3_load_dp: MOV     DP, #00356h
                RB      [DP].7
                JNE     vcal_3_load_dp_2
vcal_3_goto_2997:
                J       vcal_3_load_ram0fa
vcal_3_load_dp_2:
                MOV     DP, #003f1h
                LB      A, [DP]
                CMPB    A, #020h
                JNE     vcal_3_cmp_acc
                L       A, 0c4h
                MOV     DP, #0039ch
                ST      A, [DP]
                MOV     DP, #003a2h
                L       A, [DP]
                MOV     DP, #0039eh
                ST      A, [DP]
                MOV     DP, #003f4h
                LB      A, [DP]
                ADDB    A, #003h
                J       vcal_3_load_dp_6
vcal_3_cmp_acc: CMPB    A, #030h
                JLT     vcal_3_cmp_acc_2
                CMPB    A, #036h
                JGT     vcal_3_cmp_acc_2
                CMPB    A, #030h
                JEQ     vcal_3_clear_acc
                JBR     off(00210h).7, vcal_3_clear_acc
                MOV     DP, #003f0h
                CMPB    A, [DP]
                JNE     vcal_3_load_dp_3
                MOV     DP, #003abh
                STB     A, [DP]
vcal_3_load_imm:
                LB      A, #028h
                SJ      vcal_3_load_dp_4
vcal_3_load_dp_3:
                MOV     DP, #003fah
                LB      A, [DP]
                JNE     vcal_3_load_imm
vcal_3_clear_acc:
                CLRB    A
                MOV     DP, #003abh
                STB     A, [DP]
vcal_3_load_dp_4:
                MOV     DP, #003fah
                STB     A, [DP]
                SJ      vcal_3_load_imm_2
vcal_3_cmp_acc_2:
                CMPB    A, #021h
                JNE     vcal_3_goto_2997
                MOV     DP, #003f3h
                LB      A, [DP]
                SRLB    A
                JGE     vcal_3_load_dp_5
                CLR     A
                ST      A, (0011ah-00180h)[USP]
                ST      A, (0011ch-00180h)[USP]
                ST      A, off(00212h)
                ST      A, off(00214h)
                RB      off(0021ah).5
                ST      A, 0b0h
                ST      A, 0b2h
                ST      A, 0b4h
                CLRB    A
                STB     A, 0f4h
                STB     A, off(002b3h)
                MOV     DP, #00399h
                STB     A, [DP]
                MOV     DP, #001adh
vcal_3_rom_load_tbl_6d6b_dp:
                LCB     A, clamp_result_store_tbl[DP]
                STB     A, [DP]
                INC     DP
                CMP     DP, #001bah
                JNE     vcal_3_rom_load_tbl_6d6b_dp
                RB      off(00218h).6
                RB      off(00218h).7
                RB      off(0022bh).4
                RB      off(00225h).7
                RB      off(00234h).7
                SB      off(00232h).2
                SB      off(00232h).3
                J       vcal_3_clear_ram235_bit2
vcal_3_clear_ram232_bit2:
                RB      off(00232h).2
                RB      off(00232h).3
vcal_3_load_dp_5:
                MOV     DP, #003f3h
                LB      A, [DP]
                SRLB    A
                SRLB    A
                JGE     vcal_3_load_imm_2
                SB      off(00232h).0
                SB      off(00232h).1
                CAL     cfgvariant_ram_init
                RB      off(00232h).0
                RB      off(00232h).1
vcal_3_load_imm_2:
                LB      A, #003h
vcal_3_load_dp_6:
                MOV     DP, #003f2h
                STB     A, [DP]
                MOV     DP, #00356h
                SB      [DP].6
                MOV     DP, #003f5h
                LB      A, #002h
                STB     A, [DP]
                MOV     DP, #003f1h
                LB      A, [DP]
                ANDB    A, #01fh
                MOV     DP, #003f6h
                STB     A, [DP]
                STB     A, STBUF
vcal_3_load_ram0fa:
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, 09eh
                SUBB    A, #005h
                JLT     vcal3_leanprotect_ratelimit
                STB     A, 09eh
vcal3_leanprotect_ratelimit:
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JGE     vcal3_main_task
                RB      (0012ah-00180h)[USP].2
                JBR     off(00216h).7, vcal3_leanprotect_ratelimit_load_carry_ram0b6_bit4
                RB      0b6h.6
                JEQ     vcal3_leanprotect_ratelimit_load_carry_ram0b6_bit4
                J       vcal3_leanprotect_ratelimit_load_adcr3h
vcal3_leanprotect_ratelimit_load_carry_ram0b6_bit4:
                MB      C, 0b6h.4
                JGE     vcal3_leanprotect_ratelimit_if_ram227_bit2_set
                JBR     off(0022bh).0, vcal3_task_a
                RB      off(00231h).0
                JNE     vcal3_task_a
                RB      0b6h.4
                RT
vcal3_task_a:   J       battery_voltage_check
vcal3_leanprotect_ratelimit_if_ram227_bit2_set:
                JBS     off(00227h).2, vcal3_dispatch_check1
                JBR     off(00216h).3, vcal3_dispatch_check1
                RB      0b6h.3
                JEQ     vcal3_dispatch_check1
                J       vcal3_leanprotect_ratelimit_load_r5
vcal3_dispatch_check1:
                RB      off(00231h).1
                JEQ     vcal3_dispatch_check2
                J       vcal3_task_c_timers
vcal3_dispatch_check2:
                RB      off(00231h).2
                JNE     vcal3_task_b
                RT
vcal3_task_b:   J       vcal3_task_b_body
vcal3_main_task:
                CAL     ResetWatchDog
                JBS     off(002b4h).0, vcal3_main_task_load_dp
                JBS     off(002b4h).1, vcal3_main_task_load_dp
                SB      0b6h.6
                JBS     off(002b4h).2, vcal3_main_task_load_dp
                SB      0b6h.3
vcal3_main_task_load_dp:
                MOV     DP, #00008h
                MOV     X1, #001d3h
                CAL     decrement_timer_array
                MOV     DP, #0000ch
                MOV     X1, #002bfh
                CAL     decrement_timer_array
                MOV     DP, #00004h
                MOV     X1, #003f7h
                CAL     decrement_timer_array
                DECB    off(002b4h)
                MOV     DP, #003fah
                LB      A, [DP]
                JNE     scheduler_slowflag_check
                MOV     DP, #003abh
                STB     A, [DP]
scheduler_slowflag_check:
                CLR     A
                LB      A, off(002c6h)
                JNE     scheduler_divider_check
                LB      A, #0fah
                STB     A, off(002c6h)
                MB      C, off(00231h).7
                XORB    PSWH, #080h
                MB      off(00231h).7, C
                JLT     scheduler_divider_check
                SB      off(00231h).2
scheduler_divider_check:
                MOVB    r0, #00ah
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
                CMPB    A, #0ffh
                JLE     scheduler_ect_sign_check
                CMPB    A, #0ffh
                JGE     scheduler_ect_sign_check
                XORB    P0, #040h
                RB      off(00224h).7
                SJ      scheduler_task_done
scheduler_gate_common:
                SB      P0.6
                SB      off(00224h).7
                SJ      scheduler_task_done
scheduler_ect_sign_check:
                RB      P0.6
                RB      off(00224h).7
scheduler_task_done:
                MOV     DP, #000ceh
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
vss_scale_apply:
                CAL     mul_scale_helper2
vss_result_store:
                ST      A, [DP]
                ST      A, er2
vssSpeedNumerator    equ 05e59h ; VSS: speed = (3 * 10000h + vssSpeedNumerator) / pulse period (MOV er0,#3 / L A,# / DIV).
                                ; A number, not a table: it used to be bound to whatever label sat at this address.
                MOV     er0, #00003h
                L       A, #vssSpeedNumerator
                DIV
                ST      A, er1
                L       A, er0
                JNE     vss_clamp_max
                LB      A, r3
                JEQ     vss_clamp_common
vss_clamp_max:  MOVB    r2, #0ffh
vss_clamp_common:
                LB      A, r2
vss_final_store:
                STB     A, r2
                MOVB    r3, 0cch
                L       A, er1
                ST      A, 0cch
                SJ      vss_calc_done
vss_calc_skip:  L       A, #vss_calc_skip_tbl
                RB      off(00231h).3
                SJ      vss_result_store
vss_calc_gate2: LB      A, #003h
                CMPB    0abh, A
                JLT     vss_calc_done
                STB     A, 0abh
vss_calc_gate3: RB      off(00231h).4
                SB      off(00231h).3
                MOV     [DP], #0ffffh
                CLRB    A
                SJ      vss_final_store
vss_calc_done:  LB      A, #005h
                JBS     off(0021ah).2, vss_hysteresis_check
                LB      A, #006h
vss_hysteresis_check:
                CMPB    A, 0cch
                MB      off(0021ah).2, C
                JBS     off(00231h).3, vss_hysteresis_check_if_ram227_bit6_clr
                MOVB    off(002c7h), #008h
vss_hysteresis_check_if_ram227_bit6_clr:
                JBR     off(00227h).6, idle_gate1_clear
                JBS     off(00214h).7, idle_gate1_clear
                MOV     DP, #00f00h
                MB      C, [DP].2
                RB      off(00232h).6
                MB      off(00232h).6, C
                JEQ     idle_gate1
                XORB    PSWH, #080h
idle_gate1:     JGE     idle_gate1_timer_check
                CMPB    0c5h, #000h
                JGT     idle_gate1_trigger
                JBS     off(00233h).7, idle_gate1_timer_check
idle_gate1_trigger:
                MOVB    off(002c9h), #0ffh
idle_gate1_clear:
                RC
                SJ      dtc24_code24_latch
idle_gate1_timer_check:
                LB      A, off(002c9h)
                JNE     idle_gate1_clear
                SC
dtc24_code24_latch:
                MB      0b2h.3, C
                RB      (0012ah-00180h)[USP].2
                CAL     idle_helper1
                JBR     off(00227h).0, idle_init_start_clear_x2
                CAL     idle_init_start_sub_load_dp
                CAL     idle_init_start_sub_load_dp_ind
idle_init_start_clear_x2:
                CLR     X2
                MOV     er0, 00396h[X2]
                CLR     A
                LB      A, #040h
                MUL
                MOV     X1, A
                MOV     DP, #00020h
                MOVB    r0, 00398h[X2]
idle_init_start_rom_load_tbl_x1:
                LC      A, [X1]
                ADDB    A, ACCH
                ADDB    r0, A
                INC     X1
                INC     X1
                JRNZ    DP, idle_init_start_rom_load_tbl_x1
                LB      A, r0
                STB     A, 00398h[X2]
                INC     00396h[X2]
                CMP     00396h[X2], #00200h
                JNE     idle_init_start_if_ram227_bit0_clr
                CLR     00396h[X2]
                LB      A, r0
                JEQ     idle_init_start_if_ram227_bit0_clr
                CLRB    00398h[X2]
                LCB     A, idle_init_start_tbl
                JNE     idle_init_start_if_ram227_bit0_clr
                MOVB    0f5h, #048h
                J       fault_giveup_latch
idle_init_start_if_ram227_bit0_clr:
                JBR     off(00227h).0, idle_init_start_clear_r2
                CAL     idle_init_start_sub_load_dp
                CAL     idle_init_start_sub_load_dp_ind
idle_init_start_clear_r2:
                CLRB    r2
                JBR     off(00227h).0, idle_init_start_goto_2c91
                J       idle_init_start_load_ram258
                DB  0FFh,0FFh,0FFh
idle_init_start_load_ram258:
                LB      A, off(00258h)
                JEQ     idle_init_start_load_carry_ram22c_bit0
                CMPB    A, #0ffh
                JEQ     idle_init_start_load_carry_ram22c_bit0
                CMPB    A, #0aah
                JEQ     idle_init_start_load_carry_ram22c_bit0
                CMPB    A, #055h
                JNE     idle_init_start_load_imm
idle_init_start_load_carry_ram22c_bit0:
                MB      C, off(0022ch).0
                MB      off(0022ch).1, C
                MB      C, off(0022ch).2
                MB      off(0022ch).3, C
                RORB    A
                MB      off(0022ch).0, C
                RORB    A
                MB      off(0022ch).2, C
idle_init_start_load_imm:
                LB      A, #0ffh
                JBS     off(0022ch).5, idle_init_start_cmp_acc
                LB      A, #0ffh
idle_init_start_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(0022ch).5, C
                RB      PSWL.4
                JBS     off(0022ch).4, idle_init_start_if_ram22c_bit2_set
                JBR     off(00234h).7, idle_init_start_cmp_ram0d9
                SB      PSWL.4
                JBS     off(00215h).5, idle_init_start_load_ram2ca
                JBS     off(00215h).6, idle_init_start_load_ram2ca
                MOV     DP, #003f8h
                LB      A, off(002d8h)
                JEQ     idle_init_start_load_dp_ind
                MOVB    [DP], #0ffh
                SJ      idle_init_start_load_ram2ca
idle_init_start_load_dp_ind:
                LB      A, [DP]
                JNE     idle_init_start_clear_pswl_bit4
                MOVB    off(002d8h), #0ffh
                SJ      idle_init_start_load_ram2ca
idle_init_start_clear_pswl_bit4:
                RB      PSWL.4
                SJ      idle_init_start_load_ram2ca
idle_init_start_cmp_ram0d9:
                CMPB    0d9h, #001h
                JGE     idle_init_start_load_ram2ca
                JBR     off(0022ch).5, idle_init_start_load_ram2ca
idle_init_start_if_ram22c_bit2_set:
                JBS     off(0022ch).2, idle_init_start_if_ram22c_bit0_set
                JBR     off(0022ch).4, idle_init_start_load_ram2ca
                JBR     off(0022ch).0, idle_init_start_load_ram2ac
                MOVB    r2, #0ffh
                LB      A, #0ffh
                SJ      idle_init_start_store_ram2ac
idle_init_start_goto_2c91:
                SJ      idle_init_start_load_ram247_2
idle_init_start_set_pswl_bit4:
                SB      PSWL.4
idle_init_start_load_ram2ac:
                LB      A, off(002ach)
                ADDB    A, off(00247h)
                JLT     idle_init_start_clear_ram22c_bit4
                STB     A, r2
                SJ      idle_init_start_load_carry_pswl_bit4
idle_init_start_load_ram2ca:
                MOVB    off(002cah), #0ffh
idle_init_start_clear_ram22c_bit4:
                RB      off(0022ch).4
                SJ      idle_init_start_load_carry_pswl_bit4
idle_init_start_if_ram22c_bit0_set:
                JBS     off(0022ch).0, idle_init_start_load_ram247
                JBR     off(0022ch).4, idle_init_start_load_ram2ca
                LB      A, 0cch
                MOV     X1, #idle_init_start_tbl_2
                CAL     table_interp_lookup
                STB     A, r2
                LB      A, 0cch
                MOV     X1, #idle_init_start_tbl_3
                CAL     table_interp_lookup
                SJ      idle_init_start_store_ram2ac
idle_init_start_load_ram247:
                LB      A, off(00247h)
                JEQ     idle_init_start_load_r2
                CMPB    A, #0ffh
                JLT     idle_init_start_set_pswl_bit4
idle_init_start_load_r2:
                MOVB    r2, #0ffh
                LB      A, #0ffh
                SB      off(0022ch).4
idle_init_start_store_ram2ac:
                STB     A, off(002ach)
                SB      PSWL.4
idle_init_start_load_carry_pswl_bit4:
                MB      C, PSWL.4
                MB      P0.4, C
                LB      A, off(002cah)
                JEQ     idle_init_start_clear_ram22c_bit4_2
                LB      A, (0019ch-00180h)[USP]
                JNE     idle_init_start_clear_r2_2
                SJ      idle_init_start_load_ram247_2
idle_init_start_clear_ram22c_bit4_2:
                RB      off(0022ch).4
idle_init_start_clear_r2_2:
                CLRB    r2
idle_init_start_load_ram247_2:
                MOVB    off(00247h), r2
                JBR     off(00227h).0, idle_init_start_load_stk
                J       idle_init_start_if_ram215_bit5_set
                DB  0FFh,0FFh,0FFh
idle_init_start_if_ram215_bit5_set:
                JBS     off(00215h).5, idle_init_start_load_stk
                JBS     off(00215h).6, idle_init_start_load_stk
                JBS     off(00217h).5, idle_init_start_load_stk
                CMPB    0dbh, #0ffh
                JLT     idle_init_start_load_stk
                JBS     off(0022ch).0, idle_init_start_if_ram22c_bit2_clr
                RB      0b2h.4
                JBR     off(0022ch).2, idle_init_start_clear_ram0b2_bit5
dtc31_at_signal_b_latch:
                SB      0b2h.5
                JBS     off(0022ch).3, idle_mode_gate2
dtc30_at_signal_a_latch_2:
                SB      0b4h.4
                SJ      idle_mode_gate2
idle_init_start_if_ram22c_bit2_clr:
                JBR     off(0022ch).2, dtc30_at_signal_a_latch
idle_init_start_load_stk:
                MOVB    (001b1h-00180h)[USP], #0ffh
                MOVB    (001b2h-00180h)[USP], #0ffh
                RB      0b2h.4
idle_init_start_clear_ram0b2_bit5:
                RB      0b2h.5
                SJ      idle_mode_gate2
dtc30_at_signal_a_latch:
                SB      0b2h.4
                RB      0b2h.5
                JBS     off(0022ch).1, idle_mode_gate2
dtc31_at_signal_b_latch_2:
                SB      0b4h.5
idle_mode_gate2:
                JBR     off(002b4h).0, idle_mode_gate2_load_ram098
                J       transit_flag_check
idle_mode_gate2_load_ram098:
                L       A, 098h
                MOV     X1, #tbl_idle_dc
                CAL     table_interp_lookup_4byte
                MOV     er0, 09ch
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_dc_result_store
                L       A, #0ffffh
idle_dc_result_store:
                MOV     DP, #00380h
                ST      A, [DP]
                MOV     er3, off(00292h)
                SUB     A, off(0025eh)
                MB      r4.0, C
                JEQ     idle_delta_flag_set
                RB      off(00225h).6
                MB      off(00225h).6, C
                JEQ     idle_delta_flag_check
                XORB    PSWH, #080h
idle_delta_flag_check:
                JGE     idle_delta_flag_store
idle_delta_flag_set:
                SC
idle_delta_flag_store:
                MB      r4.1, C
                MOV     X1, #000e1h
                MOV     X2, #0091fh
                JBR     off(0020ch).0, idle_helper2_call1
                VCAL    7
idle_helper2_call1:
                ST      A, er0
                L       A, #00580h
                CAL     idle_helper2
                MOV     DP, A
                L       A, #000f0h
                J       idle_helper2_call1_cmp_stk
idle_helper2_call1_xchg_acc:
                XCHG    A, 098h
                ST      A, er0
                J       idle_helper2_call1_clear_acc
idle_target_store:
                L       A, DP
                ST      A, off(00292h)
                L       A, er0
                CMP     A, 098h
                JEQ     idle_step_default
                JBR     off(0020ch).1, idle_debounce_gate
idle_step_default:
                LB      A, #00ah
idle_step_store:
                STB     A, (001eah-00180h)[USP]
idle_debounce_gate:
                MB      C, 0b7h.1
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
idle_port_p1_check:
                LB      A, #04dh
                STB     A, 0afh
                DECB    0f7h
                JNE     idle_debounce_skip
                STB     A, 0f5h
                CLRB    0f6h
                J       fault_retry_check
idle_debounce_skip:
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                CAL     port_debounce_helper
                ORB     PSWH, #001h
                SJ      idle_debounce_ie_restore
idle_debounce_done:
                MOV     DP, #00f00h
                LB      A, [DP]
                XORB    A, #038h
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                STB     A, off(00210h)
                STB     A, (00118h-00180h)[USP]
                ORB     PSWH, #001h
idle_debounce_ie_restore:
                L       A, 0f8h
                ST      A, IE
idle_debounce_disabled:
                MOV     DP, #04700h
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
                JBS     off(00211h).4, idle_debounce_return
                MOVB    off(002e6h), #008h
idle_debounce_return:
                RT
transit_flag_check:
                LB      A, #0ffh
                MOV     DP, #00393h
                RB      TRNSIT.3
                JNE     transit_flag_common
                SC
                LB      A, [DP]
                JEQ     transit_flag_store
                SUBB    A, #001h
transit_flag_common:
                RC
transit_flag_store:
                MB      off(00230h).6, C
                STB     A, [DP]
                JBR     off(002b4h).1, transit_gate_check
                RT
transit_gate_check:
                MOV     DP, #000deh
                LB      A, 0dch
                STB     A, ACCH
                CLRB    A
                JBS     off(00214h).3, idle_scratch_store
                MB      C, 0b1h.7
                JLT     idle_task_done
                CMPB    0f3h, #032h
                JGE     idle_scratch_scale
idle_scratch_store:
                MOV     [DP], A
                SJ      idle_task_done
idle_scratch_scale:
                MOV     er0, #tbl_6000
                CAL     mul_scale_helper2
idle_task_done: SB      off(00231h).0
                RT
vcal3_leanprotect_ratelimit_load_adcr3h:
                LB      A, ADCR3H
                STB     A, off(002a1h)
                STB     A, r0
                RC
                JBS     off(00213h).3, dtc12_egr_latch
                CMPB    off(00238h), #000h
                MB      off(00223h).7, C
                JGE     dtc12_egr_latch
                LB      A, #0ffh
                CMPB    A, r0
dtc12_egr_latch:
                MB      0b1h.0, C
                JBS     off(00213h).3, vcal3_leanprotect_ratelimit_load_r0
                LB      A, #0ffh
                JGE     vcal3_leanprotect_ratelimit_if_ram21c_bit7_set
                STB     A, off(002edh)
                SJ      vcal3_leanprotect_ratelimit_load_ram2ee
vcal3_leanprotect_ratelimit_if_ram21c_bit7_set:
                JBS     off(0021ch).7, vcal3_leanprotect_ratelimit_store_ram2ed
                CMPB    off(0029fh), #000h
                JEQ     vcal3_leanprotect_ratelimit_load_ram2ed
vcal3_leanprotect_ratelimit_store_ram2ed:
                STB     A, off(002edh)
vcal3_leanprotect_ratelimit_load_ram2ed:
                LB      A, off(002edh)
                JNE     vcal3_leanprotect_ratelimit_load_r0
                LB      A, #0ffh
                CMPB    A, r0
                JLT     vcal3_leanprotect_ratelimit_store_ram2a0
                LB      A, #0ffh
                CMPB    A, r0
                JGE     vcal3_leanprotect_ratelimit_store_ram2a0
                LB      A, r0
vcal3_leanprotect_ratelimit_store_ram2a0:
                STB     A, off(002a0h)
vcal3_leanprotect_ratelimit_load_r0:
                LB      A, r0
                SUBB    A, off(002a0h)
                JGE     vcal3_leanprotect_ratelimit_store_ram29e
                CLRB    A
vcal3_leanprotect_ratelimit_store_ram29e:
                STB     A, off(0029eh)
                JBS     off(00213h).3, vcal3_leanprotect_ratelimit_load_ram2ee
                JBS     off(00217h).5, vcal3_leanprotect_ratelimit_load_ram2ee
                SUBB    A, off(0029fh)
                JGE     vcal3_leanprotect_ratelimit_clear_ram223_bit6
                VCAL    6
                SC
vcal3_leanprotect_ratelimit_clear_ram223_bit6:
                RB      off(00223h).6
                MB      off(00223h).6, C
                JEQ     vcal3_leanprotect_ratelimit_if_lt_goto_2e9a
                XORB    PSWH, #080h
vcal3_leanprotect_ratelimit_if_lt_goto_2e9a:
                JLT     vcal3_leanprotect_ratelimit_load_ram2ee
                CMPB    A, #006h
                JLE     vcal3_leanprotect_ratelimit_load_ram2ee
                JBR     off(00223h).7, vcal3_leanprotect_ratelimit_load_ram2ee
                CMPB    0dbh, #0ffh
                JLT     vcal3_leanprotect_ratelimit_load_ram2ee
                CMPB    0beh, #030h
                JLT     vcal3_leanprotect_ratelimit_load_ram2ee
                CMPB    off(0029fh), #018h
                JGE     vcal3_leanprotect_ratelimit_load_ram2ee_2
vcal3_leanprotect_ratelimit_load_ram2ee:
                MOVB    off(002eeh), #032h
vcal3_leanprotect_ratelimit_clear_carry:
                RC
                SJ      dtc12_egr_latch_2
vcal3_leanprotect_ratelimit_load_ram2ee_2:
                LB      A, off(002eeh)
                JNE     vcal3_leanprotect_ratelimit_clear_carry
                SC
dtc12_egr_latch_2:
                MB      0b1h.1, C
                CLR     A
                MOV     DP, A
                ST      A, er0
                RC
                LB      A, off(0029fh)
                JEQ     vcal3_leanprotect_ratelimit_load_ram2a4
                L       A, off(002a2h)
                JNE     vcal3_leanprotect_ratelimit_store_er3
                L       A, #09fffh
vcal3_leanprotect_ratelimit_store_er3:
                ST      A, er3
                LB      A, off(0029eh)
                SUBB    A, off(0029fh)
                MB      r4.0, C
                JGE     vcal3_leanprotect_ratelimit_store_r0
                VCAL    6
vcal3_leanprotect_ratelimit_store_r0:
                STB     A, r0
                L       A, #09fffh
                MOV     X1, #09fffh
                MOV     X2, #09fffh
                CAL     vcal3_leanprotect_ratelimit_sub_mul_acc_2
                MOV     DP, A
                L       A, #09fffh
                CAL     vcal3_leanprotect_ratelimit_sub_mul_acc_2
vcal3_leanprotect_ratelimit_load_ram2a4:
                MOV     off(002a4h), A
                JLT     vcal3_leanprotect_ratelimit_load_ram2a4_2
                MOV     off(002a2h), DP
vcal3_leanprotect_ratelimit_load_ram2a4_2:
                L       A, off(002a4h)
                MOV     er0, #00050h
                MUL
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                L       A, ACC
                JNE     vcal3_leanprotect_ratelimit_vcal_7
                L       A, #00001h
vcal3_leanprotect_ratelimit_vcal_7:
                VCAL    7
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, 0e6h
                LB      A, #031h
                SUBB    A, r2
                STB     A, 0e5h
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                RT
battery_voltage_check:
                MB      C, off(0022bh).2
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
                J       battery_voltage_check_if_ge_goto_782e
                DW  00000h
battery_voltage_check_load_imm:
                LB      A, #050h
                JBS     off(0022ah).4, threshold_bank_check1
                LB      A, #030h
threshold_bank_check1:
                CMPB    r0, A
                MB      off(0022ah).4, C
                LB      A, #078h
                JBS     off(0022ah).5, threshold_bank_check2
                LB      A, #070h
threshold_bank_check2:
                CMPB    r0, A
                MB      off(0022ah).5, C
                LB      A, #050h
                JBS     off(0022ah).6, threshold_bank_check3
                LB      A, #030h
threshold_bank_check3:
                CMPB    r0, A
                MB      off(0022ah).6, C
                LB      A, #0feh
                JBS     off(0022ah).0, cmp_0e1_select_b0_c0
                LB      A, #0ffh
cmp_0e1_select_b0_c0:
                CMPB    A, 0e1h
                MB      off(0022ah).0, C
                LB      A, #0b0h
                JBS     off(0022ah).1, idle_temp_hyst1
                LB      A, #0c0h
idle_temp_hyst1:
                CMPB    A, 0e1h
                MB      off(0022ah).1, C
                LB      A, #066h
                JBS     off(0022ah).2, idle_temp_hyst2
                LB      A, #073h
idle_temp_hyst2:
                CMPB    A, off(00238h)
                MB      off(0022ah).2, C
                LB      A, #0ddh
                JBS     off(0022ah).3, idle_temp_hyst3
                LB      A, #0e0h
idle_temp_hyst3:
                CMPB    A, off(00238h)
                MB      off(0022ah).3, C
                MB      C, off(0021ah).0
                MB      off(00225h).4, C
                JBS     off(0022bh).4, idle_temp_hyst3_set_carry
                MB      C, 0b0h.1
                JLT     idle_temp_hyst3_set_carry
                JBS     off(00212h).5, idle_temp_hyst3_set_carry
                JBR     off(00217h).5, idle_temp_hyst3_if_ram216_bit3_clr
                CMPB    0d8h, #030h
                MB      off(0022ah).7, C
                RC
                SJ      idle_temp_hyst3_store_carry_ram21a_bit0
idle_temp_hyst3_if_ram216_bit3_clr:
                JBR     off(00216h).3, idle_temp_hyst3_if_ram21a_bit2_set
                JBR     off(00211h).5, idle_temp_hyst3_set_carry
idle_temp_hyst3_if_ram21a_bit2_set:
                JBS     off(0021ah).2, idle_temp_hyst3_set_carry
                CMPB    off(00238h), #080h
                JGE     idle_temp_hyst3_set_carry
                LB      A, #0feh
                JBR     off(0022ah).7, idle_temp_hyst3_cmp_acc
                LB      A, #0feh
idle_temp_hyst3_cmp_acc:
                CMPB    A, 0f3h
                JGE     idle_temp_hyst3_load_ram0d9
                CMPB    0d9h, #03bh
                JGE     idle_temp_hyst3_load_ram0d9
idle_temp_hyst3_set_carry:
                SC
idle_temp_hyst3_store_carry_ram21a_bit0:
                MB      off(0021ah).0, C
idle_temp_hyst3_load_ram0d9:
                LB      A, 0d9h
                STB     A, r0
                MOV     X1, #IdleVsECT
                MOV     X2, #idle_temp_hyst3_tbl
                MOVB    r2, #034h
                CMPB    A, #016h
                JGE     idle_temp_hyst3_cmp_acc_2
idle_temp_hyst3_load_r1:
                MOVB    r1, r2
                L       A, #0090bh
                MOV     er3, #00600h
                J       idle_target_correction_start
idle_temp_hyst3_cmp_acc_2:
                CMPB    A, r2
                JGE     idle_ectvs_result3
                MOVB    r1, #031h
                JBS     off(00217h).6, idle_temp_hyst3_if_ram22a_bit4_clr
                CMP     off(00274h), #08000h
                JGE     idle_temp_hyst3_cmp_acc_3
                CMP     off(00274h), #00780h
                JBS     off(00216h).3, idle_temp_hyst3_if_ge_goto_2fe0
                CMP     off(00274h), #00780h
idle_temp_hyst3_if_ge_goto_2fe0:
                JGE     idle_temp_hyst3_load_r1
idle_temp_hyst3_cmp_acc_3:
                CMPB    A, r1
                JGE     idle_ectvs_result3
idle_ectvs_flag_check_load_imm:
                L       A, #009c4h
                MOV     er3, #00380h
                SJ      idle_target_correction_start
idle_temp_hyst3_if_ram22a_bit4_clr:
                JBR     off(0022ah).4, idle_temp_hyst3_if_ram225_bit1_clr
                MOVB    off(002e8h), #000h
                MOVB    off(002e9h), #05ah
                SJ      idle_temp_hyst3_load_r1
idle_temp_hyst3_if_ram225_bit1_clr:
                JBR     off(00225h).1, idle_temp_hyst3_cmp_acc_4
                CMPB    off(002e8h), #000h
                JNE     idle_temp_hyst3_load_r1
idle_temp_hyst3_cmp_acc_4:
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, off(0027ch)
                JEQ     idle_ectvs_flag_check
                MOVB    off(002e5h), #01eh
idle_ectvs_flag_check:
                LB      A, off(002e5h)
                JNE     idle_ectvs_flag_check_load_imm
                JBR     off(0022ah).5, idle_ectvs_flag_check_if_ram225_bit1_clr
                MOVB    off(002e9h), #05ah
                SJ      idle_ectvs_flag_check_load_imm
idle_ectvs_flag_check_if_ram225_bit1_clr:
                JBR     off(00225h).1, idle_ectvs_flag_check_if_ram216_bit3_clr
                LB      A, off(002e9h)
                JNE     idle_ectvs_flag_check_load_imm
idle_ectvs_flag_check_if_ram216_bit3_clr:
                JBR     off(00216h).3, idle_ectvs_flag_check_load_r1
                MOVB    r1, #02fh
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, #00a77h
                MOV     er3, #00100h
                JBS     off(00211h).5, idle_target_correction_start
idle_ectvs_flag_check_load_r1:
                MOVB    r1, #02ch
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, #00b44h
                MOV     er3, #00080h
                JBS     off(00225h).1, idle_target_correction_start
idle_ectvs_result3:
                LB      A, r0
                VCAL    0
                CLR     er3
idle_target_correction_start:
                MOV     DP, A
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
idle_target_correction_zero:
                CLR     A
idle_target_correction_done:
                ST      A, off(0027ah)
                L       A, DP
                JBS     off(0021ah).0, idle_target_correction_done_store_ram25c
                LB      A, 0d9h
                MOV     X1, #idle_target_correction_done_tbl
                VCAL    0
                MOV     X2, #idle_target_correction_done_tbl_2
idle_target_correction_done_store_ram25c:
                STB     A, off(0025ch)
                MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r2
                MOV     X1, X2
                ADD     X1, #0000eh
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, ACCH
                LB      A, r2
                MOV     off(00296h), A
                L       A, off(0025ch)
                MOV     X1, #tbl_idle_pid_lo3
                MOV     X2, #tbl_idle_pid_hi3
                CMP     A, #00964h
                JLT     idle_pid_table_select2
                MOV     X1, #tbl_idle_pid_lo2
                MOV     X2, #tbl_idle_pid_hi2
                CMP     A, #00a08h
                JLT     idle_pid_table_select2
                MOV     X1, #tbl_idle_pid_lo1
                MOV     X2, #tbl_idle_pid_hi1
idle_pid_table_select2:
                JBS     off(00217h).6, idle_pid_table_lookup
                MOV     X1, #tbl_idle_pid_b
                MOV     X2, #tbl_idle_pid_d
                CMP     A, #00964h
                JLT     idle_pid_table_lookup
                MOV     X1, #tbl_idle_pid_a
                MOV     X2, #tbl_idle_pid_c
idle_pid_table_lookup:
                LB      A, off(00238h)
                CAL     table_interp_lookup
                MOVB    r0, 0e1h
                MULB
                L       A, ACC
                ROL     A
                LB      A, ACCH
                JGE     idle_pid_mul_apply
                LB      A, #0ffh
idle_pid_mul_apply:
                MOV     X1, X2
                VCAL    0
                MOV     DP, #0037ah
                MOVB    r1, [DP]
                CLRB    r0
                MUL
                ROLB    A
                L       A, er1
                ROL     A
                JGE     idle_p0_pin_check
                L       A, #0ffffh
idle_p0_pin_check:
                MB      C, P0.2
                JGE     idle_pid_er3_store
                MOVB    r1, #040h
                CLRB    r0
                MUL
                L       A, er1
idle_pid_er3_store:
                ST      A, er3
                JBS     off(0022bh).4, idle_pid_common
                MOVB    r1, #003h
                JBS     off(00235h).0, idle_pid_gate2
                JBS     off(00225h).1, idle_pid_gate3
idle_pid_gate2: JBS     off(00211h).2, idle_pid_common
                JBS     off(0022ah).0, idle_pid_common
                LB      A, #028h
                CLRB    r1
                JBS     off(0022bh).5, idle_pid_recheck2
                LB      A, #028h
                MOVB    r1, #003h
idle_pid_recheck2:
                MOVB    r2, 0e2h
                MB      C, off(0022bh).5
                JBR     off(00217h).6, idle_pid_hyst_check
                LB      A, #028h
                CLRB    r1
                JBS     off(00225h).2, idle_pid_hyst_calc
                LB      A, #028h
                MOVB    r1, #003h
idle_pid_hyst_calc:
                MOVB    r2, 0e0h
                MB      C, off(00225h).2
idle_pid_hyst_check:
                MB      PSWL.4, C
                CMPB    A, r2
                JGE     idle_pid_common
                MB      C, PSWL.4
                JLT     idle_pid_p0_check
idle_pid_gate3: LB      A, off(0029bh)
                JEQ     idle_pid_flag_store
                SJ      idle_pid_flag_clear
idle_pid_p0_check:
                MB      C, P0.2
                JLT     idle_pid_flag_clear
idle_pid_flag_store:
                MOVB    off(0029bh), r1
idle_pid_flag_clear:
                CLRB    r5
                SJ      idle_pid_diff_calc
idle_pid_common:
                L       A, off(00268h)
                XCHG    A, er3
                MOVB    r5, off(00295h)
                CLRB    r4
                MOVB    r1, #010h
                JBS     off(00217h).6, idle_pid_track_call
                MOVB    r1, #010h
idle_pid_track_call:
                CLRB    r0
                CAL     rpm_accel_track_helper
                ST      A, er3
idle_pid_diff_calc:
                L       A, er3
                SUB     A, off(00268h)
                ST      A, er0
                JGE     idle_pid_diff_clamp
                VCAL    7
idle_pid_diff_clamp:
                CMP     A, #00020h
                JBS     off(00217h).6, idle_pid_diff_zero
                CMP     A, #00020h
idle_pid_diff_zero:
                CLR     A
                JLT     idle_pid_diff_store
                L       A, er0
idle_pid_diff_store:
                ST      A, off(0026ah)
                L       A, off(00278h)
                SUB     A, #000c0h
                JGE     idle_pid_flag_recheck
                CLR     A
idle_pid_flag_recheck:
                CMPB    off(0029bh), #000h
                JEQ     idle_pid_store_final
                L       A, #00780h
                JBS     off(00217h).6, idle_pid_decrement
                L       A, #00780h
idle_pid_decrement:
                DECB    off(0029bh)
idle_pid_store_final:
                MOV     off(00268h), er3
                ST      A, off(00278h)
                MOVB    off(00295h), r5
                MB      C, off(00225h).1
                MB      off(00235h).0, C
                JBR     off(00226h).4, idle_integrator_check2
                MOV     X1, #tbl_idle_pid_final1
                JBS     off(00216h).3, to_idle_integrator_store
                MOV     X1, #idle_pid_store_final_tbl
to_idle_integrator_store:
                LB      A, 0d8h
                VCAL    0
                SLLB    A
                MOV     X2, A
                MOV     X1, #tbl_idle_pid_final2
                LB      A, off(00238h)
                CAL     table_interp_lookup
                L       A, er3
                SWAP
                CLRB    A
                MOV     er0, X2
                MUL
                MOV     DP, #0037eh
                L       A, off(00282h)
                JEQ     idle_integrator_reset
                JBS     off(00283h).7, idle_integrator_reset
                L       A, [DP]
                SUB     A, #00100h
                JGE     idle_integrator_store
                CLR     A
                SJ      idle_integrator_store
idle_integrator_reset:
                L       A, #00580h
idle_integrator_store:
                ST      A, [DP]
                ADD     A, er1
                CMP     A, #08000h
                JLT     idle_integrator_final_store
                L       A, #07fffh
                SJ      idle_integrator_final_store
idle_integrator_check2:
                L       A, off(00282h)
                JEQ     idle_integrator_final_store
                JBR     off(00283h).7, idle_integrator_fault
                ADD     A, #00010h
                JGE     idle_integrator_final_store
                CLR     A
                SJ      idle_integrator_final_store
idle_integrator_fault:
                L       A, #00500h
                VCAL    7
idle_integrator_final_store:
                ST      A, off(00282h)
                CLR     A
                MOV     DP, A
                JBR     off(00216h).3, to_idle_output_finalize
                JBR     off(00211h).5, idle_integrator_final_store_cmp_ram0d9
                CMPB    0d9h, #03ah
                JLT     clear_a_default
                L       A, off(00276h)
                SUB     A, #00040h
                JGE     idle_output_finalize
clear_a_default:
                CLR     A
to_idle_output_finalize:
                MOVB    off(002e4h), #014h
                SJ      idle_output_finalize
idle_integrator_final_store_cmp_ram0d9:
                CMPB    0d9h, #03ah
                JLT     inc_dp_step_load_ram0d9
                LB      A, off(002e4h)
                JEQ     inc_dp_step
                JBS     off(0021bh).6, idle_integrator_final_store_load_ram276
                CMP     0c6h, #00004h
                JGE     inc_dp_step
idle_integrator_final_store_load_ram276:
                L       A, off(00276h)
                JEQ     idle_output_finalize_srl_dp
inc_dp_step:    INC     DP
inc_dp_step_load_ram0d9:
                LB      A, 0d9h
                MOV     X1, #inc_dp_step_tbl
                VCAL    0
                MOV     X2, A
                CMPB    0d9h, #034h
                JGE     load_x2_result
                MOV     X1, #inc_dp_step_tbl_2
                L       A, off(0025ch)
                CAL     table_interp_lookup_4byte
                CMP     A, X2
                JGE     idle_output_finalize
load_x2_result: L       A, X2
idle_output_finalize:
                ST      A, off(00276h)
idle_output_finalize_srl_dp:
                SRL     DP
                MB      off(00225h).3, C
                CLRB    A
                RC
                JBS     off(00217h).5, idle_pid_result_store
                JBR     off(0022bh).2, idle_pid_gate4
                JBR     off(00210h).3, idle_pid_gate5
                MOV     X1, #00400h
                LB      A, off(00299h)
                JEQ     idle_pid_x1_select
                DECB    off(00299h)
                MOV     X1, #00800h
idle_pid_x1_select:
                L       A, X1
                SJ      idle_pid_output_store
idle_pid_gate4: JBS     off(00210h).3, idle_pid_zero_flag
idle_pid_gate5: SC
                LB      A, #008h
idle_pid_result_store:
                MB      off(0022bh).2, C
                STB     A, off(00299h)
idle_pid_zero_flag:
                CLR     A
idle_pid_output_store:
                ST      A, off(0027ch)
                MOV     X1, #tbl_idle_pid_out2
                LB      A, off(00238h)
                VCAL    0
                MOV     DP, A
                MOV     X1, #ModePageTable_SetA
                JBS     off(00216h).3, idle_pid_output_store_goto_7946
                MOV     X1, #ModePageTable_SetB
idle_pid_output_store_goto_7946:
                J       idle_pid_output_store_load_ram0d5
idle_sub_result_store_load_ram2c3:
                LB      A, off(002c3h)
                MOV     A, off(0026ch)
                JNE     idle_sub_gate2
                MOVB    off(002c3h), #003h
                JBR     off(0021ah).2, idle_sub_common
                JBS     off(0021bh).1, idle_sub_diff_calc
                ADD     A, er3
                JLT     idle_sub_alt_path
                SJ      idle_sub_range_check1
idle_sub_diff_calc:
                SUB     A, er3
                JLT     idle_sub_common
idle_sub_range_check1:
                MOV     X2, #00600h
                CMP     A, #02000h
                JGE     idle_sub_range_result
                MOV     X2, #00300h
                CMP     A, #01000h
                JGE     idle_sub_range_result
                MOV     X2, #00200h
idle_sub_range_result:
                SUB     A, X2
                JGE     idle_sub_gate2
idle_sub_common:
                CLR     A
idle_sub_gate2: JBS     off(00216h).3, idle_sub_clamp
                JBR     off(0021ah).2, idle_sub_clamp
                JBR     off(00218h).2, idle_sub_clamp
                MOV     X2, A
                MOV     X1, #tbl_idle_sub_gate1
                JBR     off(00211h).2, idle_sub_table_lookup
                MOV     X1, #tbl_idle_sub_gate2
idle_sub_table_lookup:
                LB      A, off(00238h)
                VCAL    0
                L       A, X2
                CMP     A, er3
                JGE     idle_sub_clamp
                L       A, er3
idle_sub_clamp: CMP     A, DP
                JLT     idle_sub_final_store
idle_sub_alt_path:
                L       A, DP
idle_sub_final_store:
                ST      A, off(0026ch)
                MB      C, off(0022bh).6
                MB      off(0022bh).7, C
                MOV     DP, #0037bh
                LB      A, [DP]
                MOV     X2, #tbl_idle_sub1
                JBR     off(0021bh).0, idle_gate6
                MOV     X2, #tbl_idle_sub2
                CMPB    A, #053h
                JGE     idle_gate6
                LB      A, #053h
idle_gate6:     CMPB    A, off(00238h)
                MB      off(0022bh).6, C
                JBR     off(0021ah).0, idle_gate6_result
                JLT     idle_gate6_result
                JBR     off(0022bh).7, idle_gate7
                JBS     off(0021bh).7, idle_gate6_result
                MOV     X1, #tbl_idle_gate6
                LB      A, 0d9h
                VCAL    0
                ; warning: had to flip DD
                CMP     A, 0c8h
                JLT     idle_table_lookup2
idle_gate6_result:
                MOVB    off(002c2h), off(00298h)
                SJ      idle_flag_zero
idle_gate7:     L       A, off(0026eh)
                SUB     A, #00060h
                JLT     idle_flag_zero
                SJ      idle_flag_check3
idle_table_lookup2:
                MOV     X1, X2
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
idle_clamp_min: L       A, er0
idle_flag_check3:
                CMPB    off(002c2h), #000h
                JNE     idle_flag_store
idle_flag_zero: CLR     A
idle_flag_store:
                ST      A, off(0026eh)
                JBR     off(00219h).7, idle_mode_dispatch
                MOV     DP, #003abh
                MOVB    r0, [DP]
                L       A, #01a00h
                CMPB    r0, #033h
                JEQ     idle_gear_select_done
                L       A, #02600h
                CMPB    r0, #034h
                JEQ     idle_gear_select_done
                L       A, #03000h
                CMPB    r0, #035h
                JEQ     idle_gear_select_done
                L       A, #03fffh
idle_gear_select_done:
                L       A, ACC
                J       idle_gear_target_check
idle_mode_dispatch:
                JBR     off(00217h).5, idle_mode_dispatch2
                SB      off(00228h).4
                MOV     X1, #ZoneIndexTable3_SetA
                JBS     off(00216h).3, to_idle_vcal5_call
                MOV     X1, #idle_mode_dispatch_tbl
to_idle_vcal5_call:
                LB      A, 0d9h
                VCAL    0
                STB     A, off(00270h)
                SJ      to_idle_vcal5_call_load_dp
idle_mode_dispatch2:
                JBR     off(00218h).2, idle_mode_dispatch3
                JBR     off(0022ah).3, idle_gear_calc_start
                L       A, #011ebh
                J       idle_gear_target_final
idle_mode_dispatch3:
                JBR     off(0021ah).1, idle_mode_reset
                L       A, off(0026eh)
                JNE     idle_mode_reset
                JBR     off(0021ch).4, idle_gear_calc_start
                CMPB    0d9h, #02eh
                JGE     idle_gear_calc_start
                CMPB    0cch, #005h
                JLT     idle_gear_calc_start
                JBR     off(0022ah).2, idle_gear_calc_start
                MOV     X1, #tbl_ve_map_scalar_alt
                LB      A, 0c2h
                JBS     off(0021fh).1, idle_mode_dispatch3_vcal_0
                MOV     X1, #tbl_ve_map_scalar
                LB      A, off(00238h)
idle_mode_dispatch3_vcal_0:
                VCAL    0
                STB     A, off(00272h)
                JEQ     idle_gear_calc_start
                SB      off(00228h).6
                MOV     DP, #0030ch
                L       A, [DP]
vcal5_call:     VCAL    5
                ST      A, off(00262h)
                J       idle_stall_trigger_if_ram217_bit5_clr
idle_mode_reset:
                CLR     off(0026ch)
                JBR     off(00216h).3, carry_set_flag_gate_0b0
                JBS     off(00211h).5, carry_set_flag_gate_0b0
                JBR     off(00225h).3, carry_set_flag_gate_0b0
                SB      off(00228h).7
                MOV     er3, off(0026eh)
                L       A, off(00264h)
                VCAL    5
to_idle_vcal5_call_load_dp:
                MOV     DP, #00382h
                L       A, [DP]
                SJ      vcal5_call
carry_set_flag_gate_0b0:
                SC
                JBS     off(0022bh).4, idle_direction_toggle
                JBS     off(00212h).5, idle_direction_toggle
                MB      C, 0b0h.1
idle_direction_toggle:
                XORB    PSWH, #080h
                MB      off(00228h).5, C
idle_gear_calc_start:
                CLR     A
                ST      A, er2
                MOV     DP, #0030ch
                MOV     er0, off(00266h)
                MOVB    ACCH, #025h
                MOVB    r5, #099h
                JBR     off(0021ah).0, idle_gear_mul_apply
                MOV     er0, off(00264h)
                MOVB    ACCH, #052h
                MOVB    r5, #090h
                JBR     off(00228h).5, idle_gear_mul_apply
                JBR     off(0021ah).2, idle_gear_mul_apply
                CMPB    0d9h, #034h
                JGE     idle_gear_mul_apply
                L       A, [DP]
                ADD     A, off(00268h)
                JGE     idle_gear_result_store
                L       A, #0ffffh
                SJ      idle_gear_result_store
idle_gear_mul_apply:
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JLT     idle_gear_clamp
                ADD     A, off(00268h)
                JLT     idle_gear_clamp
                ADD     A, [DP]
                JGE     idle_gear_clamp_max
idle_gear_clamp:
                L       A, #0ffffh
idle_gear_clamp_max:
                SUB     A, #00800h
                JGE     idle_gear_result_store
                CLR     A
idle_gear_result_store:
                ST      A, off(00290h)
                L       A, er2
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JLT     idle_gear2_clamp
                ADD     A, off(00268h)
                JLT     idle_gear2_clamp
                ADD     A, #01000h
                JGE     idle_gear2_store
idle_gear2_clamp:
                L       A, #0ffffh
idle_gear2_store:
                ST      A, off(0028eh)
                MOVB    r0, #010h
                MOV     DP, #tbl_idle_gear2
                JBR     off(00228h).5, idle_timer_gate1
                JBS     off(0021ah).3, idle_timer_gate_common
                MOVB    off(0029ah), #030h
                SJ      idle_timer_gate_common
idle_timer_gate1:
                JBR     off(00218h).2, idle_timer_gate_common
                CLRB    off(002e6h)
                MOVB    r0, #030h
                JBS     off(0021ah).4, idle_table_select2
                SJ      idle_timer_store
idle_timer_gate_common:
                JBS     off(0021ah).2, idle_table_select2
                JBS     off(0021ah).0, idle_table_select1
                CMPB    0f3h, #032h
                JGE     idle_table_select1
                JBR     off(0021ah).4, idle_timer_store
                MOV     DP, #tbl_idle_timer
                SJ      idle_timer_store
idle_table_select1:
                LB      A, off(002e6h)
                JEQ     idle_table_select_default
                MOV     DP, #tbl_idle_select1
                SJ      idle_flag_gate
idle_table_select_default:
                MOV     DP, #tbl_idle_select_default
                MOV     X1, #tbl_idle_default1
                JBR     off(0021ah).4, idle_table_lookup3
                MOV     X1, #tbl_idle_default2
idle_table_lookup3:
                L       A, off(0025ch)
                CAL     table_interp_lookup_4byte
                CMP     A, 0cah
                JLT     idle_table_lookup4
                MOV     DP, #tbl_idle_lookup3
idle_table_lookup4:
                MOV     X1, #tbl_idle_lookup4
                L       A, off(0025ch)
                CAL     table_interp_lookup_4byte
                JBR     off(0021ah).4, idle_flag_gate
                CMP     A, 0cah
                JGE     idle_flag_gate
                LB      A, off(0029ah)
                JEQ     idle_flag_gate
                SUBB    A, #001h
                STB     A, r0
idle_table_select2:
                MOV     DP, #idle_table_select2_tbl
idle_timer_store:
                MOVB    off(0029ah), r0
idle_flag_gate: LB      A, off(002e7h)
                JNE     idle_copy_prev
                RB      off(00225h).5
idle_copy_prev: MOV     off(0028ah), off(00288h)
                MOVB    off(0028dh), off(0028ch)
                SB      off(0022bh).1
                RB      PSWL.4
                JBS     off(00228h).5, idle_copy_prev_if_ram21a_bit3_set
                JBS     off(0021ah).3, idle_mode_gate5
                L       A, off(00264h)
                JBS     off(00225h).4, idle_copy_prev_goto_idle_pi_mul1
                JBS     off(0021ah).0, idle_target_store3
idle_copy_prev_goto_idle_pi_mul1:
                J       idle_pi_mul1
idle_copy_prev_if_ram21a_bit3_set:
                JBS     off(0021ah).3, idle_copy_prev_if_ram216_bit3_clr
                SB      PSWL.4
                JBR     off(00228h).0, idle_mode_gate5
                L       A, off(00270h)
                SJ      idle_target_store3
idle_copy_prev_if_ram216_bit3_clr:
                JBR     off(00216h).3, multi_cond_dispatch_0d9_0f3
                JBS     off(00229h).4, idle_mode_gate5
multi_cond_dispatch_0d9_0f3:
                JBS     off(00229h).5, idle_mode_gate5
                JBR     off(0022bh).3, idle_pi_mul1
                CMPB    0d9h, #0d0h
                JLT     idle_mode_gate4
                CMPB    0f3h, #0fah
                JLT     idle_pi_mul1
idle_mode_gate4:
                JBR     off(00229h).6, idle_pi_mul1
idle_mode_gate5:
                L       A, off(00266h)
                JBR     off(0021ah).0, idle_target_store3
                L       A, off(00264h)
                JBR     off(00216h).3, idle_mode_gate5_load_carry_pswl_bit4
                JBS     off(00211h).5, idle_mode_gate5_load_carry_pswl_bit4
                JBR     off(00228h).3, idle_mode_gate5_load_carry_pswl_bit4
                ST      A, er3
                MOV     DP, #00382h
                L       A, [DP]
                SJ      idle_vcal5_call2
idle_mode_gate5_load_carry_pswl_bit4:
                MB      C, PSWL.4
                JGE     idle_target_store3
                CMPB    off(002e7h), #000h
                JEQ     idle_table_select3
                SB      off(00225h).5
                JNE     idle_target_store3
idle_table_select3:
                MOV     X2, A
                LB      A, #014h
                MOV     X1, #tbl_idle_select3a
                JBR     off(0021bh).0, idle_table_apply3
                LB      A, #032h
                MOV     X1, #idle_table_select3_tbl
idle_table_apply3:
                STB     A, off(002e7h)
                LB      A, 0d8h
                VCAL    0
                L       A, X2
                VCAL    5
idle_target_store3:
                ST      A, er3
                MOV     DP, #0030ch
                L       A, [DP]
idle_vcal5_call2:
                VCAL    5
                MOV     er3, off(00268h)
                VCAL    5
                ST      A, off(00288h)
                ST      A, off(0028ah)
                CLRB    A
                STB     A, off(0028ch)
                STB     A, off(0028dh)
                CLR     A
                ST      A, er1
                ST      A, er2
                MOV     X1, A
                MOV     X2, A
                SJ      idle_vcal4_call
idle_pi_mul1:   MOV     er0, 0c8h
                LC      A, [DP]
                MUL
                L       A, er1
                JBR     off(0021bh).7, idle_pi_mul2
                VCAL    7
idle_pi_mul2:   MOV     X1, A
                MOV     er0, 0cah
                INC     DP
                INC     DP
                LC      A, [DP]
                MUL
                L       A, er1
                JBR     off(0021ah).4, idle_pi_mul3
                VCAL    7
idle_pi_mul3:   MOV     X2, A
                INC     DP
                INC     DP
                LC      A, [DP]
                MUL
                ST      A, er2
                L       A, off(0026ah)
idle_vcal4_call:
                MOV     er3, off(00288h)
                VCAL    4
                LB      A, off(0028ch)
                JBS     off(0021ah).4, idle_integrator_sub
                ADDB    A, r5
                STB     A, r5
                L       A, er3
                ADC     A, er1
                JGE     idle_integrator_result
                L       A, #0ffffh
                SJ      idle_integrator_result
idle_integrator_sub:
                SUBB    A, r5
                STB     A, r5
                L       A, er3
                SBC     A, er1
                JGE     idle_integrator_result
                CLR     A
idle_integrator_result:
                CAL     idle_pi_clamp_helper
                ST      A, er1
                ST      A, er3
                JLT     idle_pi_store_p
                L       A, X1
                VCAL    4
                L       A, X2
                VCAL    4
                CAL     idle_pi_clamp_helper
                JLT     idle_pi_result_common
                MOVB    off(0028ch), r5
idle_pi_store_p:
                MOV     off(00288h), er1
idle_pi_result_common:
                ST      A, er3
                L       A, off(0026eh)
                JBS     off(00228h).5, idle_vcal5_call3
                L       A, off(0026ch)
idle_vcal5_call3:
                VCAL    5
                ST      A, off(00262h)
                MB      C, off(0022ah).1
                JBR     off(00217h).6, idle_vcal5_call3_if_lt_goto_3677
                MB      C, off(0022ah).6
idle_vcal5_call3_if_lt_goto_3677:
                JLT     idle_stall_trigger_if_ram217_bit5_clr
                JBS     off(00225h).7, idle_stall_trigger_if_ram217_bit5_clr
                JBR     off(00228h).5, idle_stall_trigger_if_ram217_bit5_clr
                JBS     off(0021ah).2, idle_stall_trigger_if_ram217_bit5_clr
                JBR     off(0021ah).0, idle_stall_trigger_if_ram217_bit5_clr
                L       A, off(00280h)
                JNE     idle_stall_trigger_if_ram217_bit5_clr
                L       A, off(0027ch)
                JNE     idle_stall_trigger_if_ram217_bit5_clr
                L       A, off(00282h)
                JNE     idle_stall_trigger_if_ram217_bit5_clr
                CMPB    0beh, #070h
                JLT     idle_stall_trigger_if_ram217_bit5_clr
                CMP     0c8h, #00018h
                JGE     idle_stall_trigger_if_ram217_bit5_clr
                L       A, #00040h
                JBR     off(0021ah).4, idle_stall_check2
                L       A, #00040h
idle_stall_check2:
                CMP     A, 0cah
                JLT     idle_stall_trigger_if_ram217_bit5_clr
                CMPB    0d9h, #067h
                JGE     idle_stall_trigger_if_ram217_bit5_clr
                LB      A, off(002e7h)
                JNE     idle_stall_trigger_if_ram217_bit5_clr
                LB      A, 0bch
                MOV     X1, #tbl_idle_stall
                VCAL    1
                LB      A, #0a8h
                JBS     off(00216h).3, sub_r6_clamp_zero
                LB      A, #0b8h
sub_r6_clamp_zero:
                SUBB    A, r6
                JGE     idle_stall_er0_select1
                CLRB    A
idle_stall_er0_select1:
                MOV     er0, #00040h
                CMPB    A, 0beh
                JLT     idle_stall_er0_select2
                MOV     er0, #00010h
idle_stall_er0_select2:
                CMPB    0d9h, #028h
                JLT     idle_stall_diff_calc
                MOV     er0, #00001h
idle_stall_diff_calc:
                MOV     X1, #0030ch
                L       A, off(00288h)
                SUB     A, off(00264h)
                JLT     idle_stall_diff_check
                SUB     A, off(00268h)
                JGE     idle_stall_trigger
idle_stall_diff_check:
                CLR     A
idle_stall_trigger:
                CAL     injtimer_bank_calc1
                CAL     idle_stall_helper
idle_stall_trigger_if_ram217_bit5_clr:
                JBR     off(00217h).5, idle_stall_trigger_cmp_ram0f2
                LB      A, 0d9h
                MOV     X1, #idle_stall_trigger_tbl
                VCAL    0
                SJ      idle_stall_trigger_store_ram280
idle_stall_trigger_cmp_ram0f2:
                CMPB    0f2h, #00ch
                JGE     idle_stall_trigger_clear_acc
                MOV     X1, #idle_stall_trigger_tbl_2
                JBR     off(00228h).5, idle_stall_trigger_load_x1
                LB      A, off(00238h)
                CMPB    A, off(00296h)
                JGE     idle_stall_trigger_load_ram0d9
idle_stall_trigger_load_x1:
                MOV     X1, #idle_stall_trigger_tbl_3
idle_stall_trigger_load_ram0d9:
                LB      A, 0d9h
                VCAL    0
                L       A, off(00280h)
                SUB     A, er3
                JGE     idle_stall_trigger_store_ram280
idle_stall_trigger_clear_acc:
                CLR     A
idle_stall_trigger_store_ram280:
                ST      A, off(00280h)
                L       A, off(00276h)
                MOV     er3, off(00278h)
                VCAL    5
                L       A, off(0027ah)
                VCAL    5
                L       A, off(0027ch)
                VCAL    5
                L       A, off(0027eh)
                VCAL    5
                L       A, off(00280h)
                VCAL    5
                L       A, off(00282h)
                CMP     A, #08000h
                JGE     idle_target_clamp1
                ADD     A, er3
                JGE     idle_target_clamp2
                SJ      idle_target_clamp_max
idle_target_clamp1:
                ADD     A, er3
                JGE     idle_target_final_store
idle_target_clamp2:
                CMP     A, #08000h
                JLT     idle_target_final_store
idle_target_clamp_max:
                L       A, #07fffh
idle_target_final_store:
                ST      A, off(00274h)
                CLR     X1
                JBS     off(00217h).5, idle_output_gate2
                JBR     off(00225h).7, idle_output_gate1
                MOV     DP, #0030ch
                L       A, 00382h[X1]
                ST      A, [DP]
idle_output_gate1:
                MOV     er3, #00600h
                L       A, 00382h[X1]
                VCAL    5
                MB      C, 0b0h.1
                JLT     idle_output_common
                JBS     off(00212h).5, idle_output_common
                MOV     er3, off(00264h)
                L       A, 00382h[X1]
                VCAL    5
                CLR     A
                JBS     off(00212h).2, idle_output_alt_value
                JBR     off(00212h).4, idle_output_vcal5
idle_output_alt_value:
                L       A, #02000h
idle_output_vcal5:
                VCAL    5
                JBS     off(0022bh).4, idle_output_common
idle_output_gate2:
                L       A, off(00262h)
                JBS     off(00228h).6, idle_pi_final_calc
                CLR     off(00272h)
                JBS     off(0022bh).1, idle_output_gate3
idle_output_common:
                MOV     er3, off(00268h)
                VCAL    5
idle_output_gate3:
                MOV     er3, off(00274h)
                XCHG    A, er3
                VCAL    4
idle_pi_final_calc:
                MOV     X2, A
                CLR     X1
                L       A, 0037ch[X1]
                SUB     A, 0030ch[X1]
                SLL     A
                ST      A, er0
                CLR     A
                JLT     idle_pi_scale_store
                LB      A, off(00294h)
                ANDB    A, #07fh
                STB     A, ACCH
                CLRB    A
                MUL
                L       A, er1
idle_pi_scale_store:
                ST      A, off(00284h)
                L       A, X2
                CLRB    r0
                MOVB    r1, off(00294h)
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_pi_result_clamp
                L       A, #0ffffh
idle_pi_result_clamp:
                ST      A, er3
                L       A, off(00284h)
                VCAL    5
                LCB     A, fuelmap_base_lookup_tbl
                JEQ     idle_pi_final_common
                L       A, off(00286h)
                VCAL    4
idle_pi_final_common:
                L       A, er3
idle_gear_target_check:
                JNE     idle_gear_target_clamp
                JBS     off(0021ah).4, idle_gear_target_reset
                SJ      idle_gear_target_store
idle_gear_target_clamp:
                MOV     er3, #03fffh
                JBS     off(00216h).3, idle_gear_target_clamp_cmp_acc
                MOV     er3, #03fffh
idle_gear_target_clamp_cmp_acc:
                CMP     A, er3
                JLT     idle_gear_target_store
                L       A, er3
                JBS     off(0021ah).4, idle_gear_target_store
idle_gear_target_reset:
                MOV     off(00288h), off(0028ah)
                MOVB    off(0028ch), off(0028dh)
idle_gear_target_store:
                ST      A, off(00260h)
                MOV     X1, #tbl_idle_gear_target
                CAL     table_interp_lookup_4byte
idle_gear_target_final:
                ST      A, off(0025eh)
                RB      off(0022bh).1
                MB      C, off(00228h).5
                MB      off(0021ah).3, C
                LB      A, off(00228h)
                ANDB    A, #0f0h
                SWAPB
                STB     A, off(00228h)
                RB      0b6h.4
                RT
vcal3_leanprotect_ratelimit_load_r5:
                MOVB    r5, 0d1h
                LB      A, 0cch
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl
                CAL     table_interp_lookup
                STB     A, r4
                LB      A, 0cch
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_9
                CAL     table_interp_lookup
                STB     A, r3
                LB      A, 0cch
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_10
                CAL     table_interp_lookup
                STB     A, r2
                JBS     off(0022eh).5, vcal3_leanprotect_ratelimit_cmp_acc
                LB      A, r3
vcal3_leanprotect_ratelimit_cmp_acc:
                CMPB    A, r5
                MB      off(0022eh).5, C
                LB      A, r2
                JBS     off(0022eh).4, vcal3_leanprotect_ratelimit_subb_acc
                LB      A, r3
vcal3_leanprotect_ratelimit_subb_acc:
                SUBB    A, r4
                JGE     vcal3_leanprotect_ratelimit_cmp_acc_2
                CLRB    A
vcal3_leanprotect_ratelimit_cmp_acc_2:
                CMPB    A, r5
                MB      off(0022eh).4, C
                LB      A, 0cch
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_11
                CAL     table_interp_lookup
                STB     A, r3
                LB      A, 0cch
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_12
                CAL     table_interp_lookup
                STB     A, r2
                JBS     off(0022eh).7, vcal3_leanprotect_ratelimit_cmp_acc_3
                LB      A, r3
vcal3_leanprotect_ratelimit_cmp_acc_3:
                CMPB    A, r5
                MB      off(0022eh).7, C
                LB      A, r2
                JBS     off(0022eh).6, vcal3_leanprotect_ratelimit_subb_acc_2
                LB      A, r3
vcal3_leanprotect_ratelimit_subb_acc_2:
                SUBB    A, r4
                JGE     vcal3_leanprotect_ratelimit_cmp_acc_4
                CLRB    A
vcal3_leanprotect_ratelimit_cmp_acc_4:
                CMPB    A, r5
                MB      off(0022eh).6, C
                LB      A, 0cch
                STB     A, r4
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_17
                CAL     table_interp_lookup
                STB     A, off(002ach)
                LB      A, r4
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_18
                CAL     table_interp_lookup
                STB     A, off(002adh)
                CMPB    r5, A
                JGT     vcal3_leanprotect_ratelimit_store_carry_ram22f_bit4
                LB      A, off(002ach)
                CMPB    A, r5
vcal3_leanprotect_ratelimit_store_carry_ram22f_bit4:
                MB      off(0022fh).4, C
                LB      A, r4
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_19
                CAL     table_interp_lookup
                STB     A, off(002aeh)
                LB      A, r4
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_20
                CAL     table_interp_lookup
                STB     A, off(002afh)
                CMPB    r5, A
                JGT     vcal3_leanprotect_ratelimit_store_carry_ram22f_bit5
                LB      A, off(002aeh)
                CMPB    A, r5
vcal3_leanprotect_ratelimit_store_carry_ram22f_bit5:
                MB      off(0022fh).5, C
                LB      A, 0cch
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_13
                JBS     off(0022eh).3, vcal3_leanprotect_ratelimit_call_table_interp_lookup
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_14
vcal3_leanprotect_ratelimit_call_table_interp_lookup:
                CAL     table_interp_lookup
                MOV     DP, #00311h
                ADDB    A, [DP]
                CMPB    A, 0d4h
                MB      off(0022eh).3, C
                MOVB    r0, 0cch
                LB      A, #025h
                JBS     off(0022eh).2, vcal3_leanprotect_ratelimit_cmp_acc_5
                LB      A, #02bh
vcal3_leanprotect_ratelimit_cmp_acc_5:
                CMPB    A, r0
                MB      off(0022eh).2, C
                LB      A, #082h
                JBS     off(0022ch).2, vcal3_leanprotect_ratelimit_cmp_acc_6
                LB      A, #087h
vcal3_leanprotect_ratelimit_cmp_acc_6:
                CMPB    A, r0
                MB      off(0022ch).2, C
                LB      A, #05fh
                JBS     off(0022ch).3, vcal3_leanprotect_ratelimit_cmp_acc_7
                LB      A, #064h
vcal3_leanprotect_ratelimit_cmp_acc_7:
                CMPB    A, r0
                MB      off(0022ch).3, C
                LB      A, #09ch
                JBS     off(0022ch).4, vcal3_leanprotect_ratelimit_cmp_acc_8
                LB      A, #0a1h
vcal3_leanprotect_ratelimit_cmp_acc_8:
                CMPB    A, r0
                MB      off(0022ch).4, C
                LB      A, #00fh
                JBS     off(0022ch).5, vcal3_leanprotect_ratelimit_cmp_acc_9
                LB      A, #011h
vcal3_leanprotect_ratelimit_cmp_acc_9:
                CMPB    A, r0
                MB      off(0022ch).5, C
                LB      A, #010h
                JBS     off(0022ch).6, vcal3_leanprotect_ratelimit_cmp_acc_10
                LB      A, #012h
vcal3_leanprotect_ratelimit_cmp_acc_10:
                CMPB    A, r0
                MB      off(0022ch).6, C
                LB      A, #044h
                JBS     off(0022ch).7, vcal3_leanprotect_ratelimit_cmp_acc_11
                LB      A, #049h
vcal3_leanprotect_ratelimit_cmp_acc_11:
                CMPB    A, r0
                MB      off(0022ch).7, C
                LB      A, #022h
                JBS     off(0022dh).0, vcal3_leanprotect_ratelimit_cmp_acc_12
                LB      A, #025h
vcal3_leanprotect_ratelimit_cmp_acc_12:
                CMPB    A, r0
                MB      off(0022dh).0, C
                LB      A, #039h
                JBS     off(0022dh).1, vcal3_leanprotect_ratelimit_cmp_acc_13
                LB      A, #041h
vcal3_leanprotect_ratelimit_cmp_acc_13:
                CMPB    A, r0
                MB      off(0022dh).1, C
                LB      A, #014h
                JBS     off(0022dh).2, vcal3_leanprotect_ratelimit_cmp_acc_14
                LB      A, #016h
vcal3_leanprotect_ratelimit_cmp_acc_14:
                CMPB    A, r0
                MB      off(0022dh).2, C
                LB      A, #025h
                JBS     off(0022dh).3, vcal3_leanprotect_ratelimit_cmp_acc_15
                LB      A, #02bh
vcal3_leanprotect_ratelimit_cmp_acc_15:
                CMPB    A, r0
                MB      off(0022dh).3, C
                LB      A, #05fh
                JBS     off(0022dh).4, vcal3_leanprotect_ratelimit_cmp_acc_16
                LB      A, #064h
vcal3_leanprotect_ratelimit_cmp_acc_16:
                CMPB    A, r0
                MB      off(0022dh).4, C
                LB      A, #07dh
                JBS     off(0022dh).5, vcal3_leanprotect_ratelimit_cmp_acc_17
                LB      A, #082h
vcal3_leanprotect_ratelimit_cmp_acc_17:
                CMPB    A, r0
                MB      off(0022dh).5, C
                LB      A, #014h
                JBS     off(0022dh).6, vcal3_leanprotect_ratelimit_cmp_acc_18
                LB      A, #019h
vcal3_leanprotect_ratelimit_cmp_acc_18:
                CMPB    A, r0
                MB      off(0022dh).6, C
                LB      A, #021h
                JBS     off(0022dh).7, vcal3_leanprotect_ratelimit_cmp_acc_19
                LB      A, #026h
vcal3_leanprotect_ratelimit_cmp_acc_19:
                CMPB    A, r0
                J       vcal3_leanprotect_ratelimit_store_carry_ram22d_bit7
vcal3_leanprotect_ratelimit_load_imm:
                LB      A, #036h
                JBS     off(0022eh).1, vcal3_leanprotect_ratelimit_cmp_acc_20
                LB      A, #050h
vcal3_leanprotect_ratelimit_cmp_acc_20:
                CMPB    A, off(00238h)
                MB      off(0022eh).1, C
                MOVB    r6, #001h
                MOVB    r7, #001h
                MOV     DP, #vcal3_leanprotect_ratelimit_tbl_8
                JBS     off(00211h).5, vcal3_leanprotect_ratelimit_goto_39b2
                JBS     off(00211h).6, vcal3_leanprotect_ratelimit_load_x1_2
                JBS     off(00211h).7, vcal3_leanprotect_ratelimit_load_x1
vcal3_leanprotect_ratelimit_goto_39b2:
                J       vcal3_leanprotect_ratelimit_load_ram2b1
vcal3_leanprotect_ratelimit_load_x1:
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_3
                CMPB    off(002b1h), #004h
                JLT     vcal3_leanprotect_ratelimit_load_ram0d1
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_2
vcal3_leanprotect_ratelimit_load_ram0d1:
                LB      A, 0d1h
                CAL     table_interp_lookup
                MOVB    r6, #004h
                CMPB    A, 0cch
                JLT     vcal3_leanprotect_ratelimit_load_r7
vcal3_leanprotect_ratelimit_load_x1_2:
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_5
                CMPB    off(002b1h), #003h
                JLT     vcal3_leanprotect_ratelimit_load_ram0d1_2
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_4
vcal3_leanprotect_ratelimit_load_ram0d1_2:
                LB      A, 0d1h
                CAL     table_interp_lookup
                MOVB    r6, #003h
                INC     DP
                INC     DP
                CMPB    A, 0cch
                JLT     vcal3_leanprotect_ratelimit_load_r7
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_7
                CMPB    off(002b1h), #002h
                JLT     vcal3_leanprotect_ratelimit_load_ram0d1_3
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_6
vcal3_leanprotect_ratelimit_load_ram0d1_3:
                LB      A, 0d1h
                CAL     table_interp_lookup
                MOVB    r6, #002h
                INC     DP
                INC     DP
                CMPB    A, 0cch
                JLT     vcal3_leanprotect_ratelimit_load_r7
                MOVB    r6, #001h
                INC     DP
                INC     DP
vcal3_leanprotect_ratelimit_load_r7:
                MOVB    r7, r6
                NOP
                NOP
                NOP
                NOP
                JBS     off(00218h).2, vcal3_leanprotect_ratelimit_load_ram2e2
                MOVB    off(002e2h), #028h
                SJ      vcal3_leanprotect_ratelimit_load_ram2b1
vcal3_leanprotect_ratelimit_load_ram2e2:
                LB      A, off(002e2h)
                JNE     vcal3_leanprotect_ratelimit_load_ram2b1
                JBR     off(0022eh).2, vcal3_leanprotect_ratelimit_load_ram2b1
                LC      A, 00008h[DP]
                MOV     er2, A
                MOV     er0, 0ceh
                CLR     A
                DIV
                LB      A, r0
                L       A, ACC
                SWAP
                CMPB    r1, #000h
                JEQ     vcal3_leanprotect_ratelimit_cmp_ram0c4
                L       A, #0ffffh
vcal3_leanprotect_ratelimit_cmp_ram0c4:
                CMP     0c4h, A
                JGE     vcal3_leanprotect_ratelimit_load_imm_2
                LC      A, [DP]
                ST      A, er2
                MOV     er0, 0ceh
                CLR     A
                DIV
                LB      A, r0
                L       A, ACC
                SWAP
                CMPB    r1, #000h
                JEQ     vcal3_leanprotect_ratelimit_cmp_ram0c4_2
                L       A, #0ffffh
vcal3_leanprotect_ratelimit_cmp_ram0c4_2:
                CMP     0c4h, A
                JGE     vcal3_leanprotect_ratelimit_load_ram2b1
                CMPB    r7, #001h
                JEQ     vcal3_leanprotect_ratelimit_load_ram2b1
                DECB    r7
                SJ      vcal3_leanprotect_ratelimit_load_ram2b1
vcal3_leanprotect_ratelimit_load_imm_2:
                LB      A, #004h
                JBR     off(00211h).6, vcal3_leanprotect_ratelimit_cmp_acc_21
                LB      A, #003h
vcal3_leanprotect_ratelimit_cmp_acc_21:
                CMPB    A, r7
                JEQ     vcal3_leanprotect_ratelimit_load_ram2b1
                INCB    r7
vcal3_leanprotect_ratelimit_load_ram2b1:
                MOVB    off(002b1h), r6
                MOVB    off(002b2h), r7
                LB      A, off(00214h)
                STB     A, ACCH
                LB      A, off(00212h)
                AND     ACC, #00560h
                JNE     vcal3_leanprotect_ratelimit_load_ram2d9
                CMPB    0d9h, #03ch
                JGE     vcal3_leanprotect_ratelimit_load_ram2d9
                JBR     off(0022eh).1, vcal3_leanprotect_ratelimit_load_ram2d9
                JBS     off(00211h).7, vcal3_leanprotect_ratelimit_load_ram2db_2
                JBR     off(00211h).6, vcal3_leanprotect_ratelimit_load_ram2d9
                JBR     off(0022fh).0, vcal3_leanprotect_ratelimit_load_ram2db
                MOVB    off(002d8h), #014h
vcal3_leanprotect_ratelimit_load_ram2db:
                LB      A, off(002dbh)
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2
                SJ      vcal3_leanprotect_ratelimit_load_ram2d9_2
vcal3_leanprotect_ratelimit_load_ram2d9:
                MOVB    off(002d9h), #002h
vcal3_leanprotect_ratelimit_load_ram2d9_2:
                LB      A, off(002d9h)
                JEQ     vcal3_leanprotect_ratelimit_if_ram21b_bit6_set
                SJ      vcal3_leanprotect_ratelimit_clear_carry_2
vcal3_leanprotect_ratelimit_load_ram2db_2:
                MOVB    off(002dbh), #00ch
                LB      A, off(002d8h)
                JEQ     vcal3_leanprotect_ratelimit_load_ram2d9_2
vcal3_leanprotect_ratelimit_if_ram21b_bit6_set:
                JBS     off(0021bh).6, vcal3_leanprotect_ratelimit_load_ram2da
                CMP     0c6h, #00120h
                JLT     vcal3_leanprotect_ratelimit_load_ram2da
                MOVB    off(002dah), #014h
vcal3_leanprotect_ratelimit_load_ram2da:
                LB      A, off(002dah)
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2
                JBS     off(0022eh).3, vcal3_leanprotect_ratelimit_if_ram211_bit6_set
                CMPB    off(002b2h), #003h
                JLT     vcal3_leanprotect_ratelimit_clear_carry_2
                MB      C, off(0022dh).6
                JEQ     vcal3_leanprotect_ratelimit_if_ge_goto_3a1f
                MB      C, off(0022dh).7
vcal3_leanprotect_ratelimit_if_ge_goto_3a1f:
                JGE     vcal3_leanprotect_ratelimit_clear_carry_2
                LB      A, off(002c7h)
                JEQ     vcal3_leanprotect_ratelimit_clear_carry_2
                JBS     off(0021ch).3, vcal3_leanprotect_ratelimit_if_ram22f_bit0_set
vcal3_leanprotect_ratelimit_clear_carry_2:
                RC
                SJ      vcal3_leanprotect_ratelimit_store_carry_ram22f_bit0
vcal3_leanprotect_ratelimit_if_ram211_bit6_set:
                JBS     off(00211h).6, vcal3_leanprotect_ratelimit_if_ram22c_bit2_set
                JBS     off(0022ch).4, vcal3_leanprotect_ratelimit_if_ram22f_bit0_set
                JBR     off(0022ch).5, vcal3_leanprotect_ratelimit_load_ram2dc
                JBR     off(0022eh).7, vcal3_leanprotect_ratelimit_load_ram2dc_2
vcal3_leanprotect_ratelimit_load_ram2dc:
                MOVB    off(002dch), #00fh
                SJ      vcal3_leanprotect_ratelimit_load_ram2dc_2
vcal3_leanprotect_ratelimit_if_ram22c_bit2_set:
                JBS     off(0022ch).2, vcal3_leanprotect_ratelimit_if_ram22f_bit0_set
                JBR     off(0022ch).3, vcal3_leanprotect_ratelimit_load_ram2dc
                JBS     off(0022eh).5, vcal3_leanprotect_ratelimit_load_ram2dc
vcal3_leanprotect_ratelimit_load_ram2dc_2:
                LB      A, off(002dch)
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2
vcal3_leanprotect_ratelimit_if_ram22f_bit0_set:
                JBS     off(0022fh).0, vcal3_leanprotect_ratelimit_set_carry
                LB      A, 0d5h
                JBS     off(0021bh).1, vcal3_leanprotect_ratelimit_cmp_acc_22
                CMPB    A, #010h
                JGT     vcal3_leanprotect_ratelimit_load_ram2e1
vcal3_leanprotect_ratelimit_cmp_acc_22:
                CMPB    A, #020h
                JLE     vcal3_leanprotect_ratelimit_load_ram2e1_2
vcal3_leanprotect_ratelimit_load_ram2e1:
                MOVB    off(002e1h), #002h
vcal3_leanprotect_ratelimit_load_ram2e1_2:
                LB      A, off(002e1h)
                JNE     vcal3_leanprotect_ratelimit_clear_carry_2
vcal3_leanprotect_ratelimit_set_carry:
                SC
vcal3_leanprotect_ratelimit_store_carry_ram22f_bit0:
                MB      off(0022fh).0, C
                MB      P0.4, C
                CMPB    0d8h, #0e1h
                JGE     vcal3_leanprotect_ratelimit_load_imm_3
                CMPB    0d9h, #02eh
                JLT     vcal3_leanprotect_ratelimit_if_ram22d_bit0_set
vcal3_leanprotect_ratelimit_load_imm_3:
                LB      A, #00ch
                STB     A, off(002bah)
                STB     A, off(002b0h)
                SJ      vcal3_leanprotect_ratelimit_goto_3cb2
vcal3_leanprotect_ratelimit_if_ram22d_bit0_set:
                JBS     off(0022dh).0, vcal3_leanprotect_ratelimit_load_ram2ba
                LB      A, off(002b0h)
                STB     A, off(002bah)
                SJ      vcal3_leanprotect_ratelimit_if_ne_goto_3ae5
vcal3_leanprotect_ratelimit_load_ram2ba:
                LB      A, off(002bah)
                STB     A, off(002b0h)
vcal3_leanprotect_ratelimit_if_ne_goto_3ae5:
                JNE     vcal3_leanprotect_ratelimit_goto_3cb2
                JBR     off(0022fh).0, vcal3_leanprotect_ratelimit_goto_3cb2
                JBS     off(0022eh).3, vcal3_leanprotect_ratelimit_load_carry_ram22e_bit4
                CMPB    off(002b2h), #002h
                JLE     vcal3_leanprotect_ratelimit_goto_3cb2
                J       vcal3_leanprotect_ratelimit_if_ram22f_bit7_set
vcal3_leanprotect_ratelimit_load_carry_ram22e_bit4:
                MB      C, off(0022eh).4
                JBS     off(00211h).6, vcal3_leanprotect_ratelimit_if_ge_goto_3aa1
                MB      C, off(0022eh).6
vcal3_leanprotect_ratelimit_if_ge_goto_3aa1:
                JGE     vcal3_leanprotect_ratelimit_load_ram2dd
                MOVB    off(002ddh), #00ah
vcal3_leanprotect_ratelimit_load_ram2dd:
                LB      A, off(002ddh)
                JNE     vcal3_leanprotect_ratelimit_goto_3cb2
                MOV     er1, #00028h
                JBR     off(00211h).6, vcal3_leanprotect_ratelimit_if_ram22d_bit5_clr
                JBR     off(0022dh).4, vcal3_leanprotect_ratelimit_goto_3cb2
                SJ      vcal3_leanprotect_ratelimit_goto_3c9c
vcal3_leanprotect_ratelimit_if_ram22d_bit5_clr:
                JBR     off(0022dh).5, vcal3_leanprotect_ratelimit_if_ram22d_bit1_set
                MOV     er1, #00033h
                SJ      vcal3_leanprotect_ratelimit_goto_3c9c
vcal3_leanprotect_ratelimit_if_ram22d_bit1_set:
                JBS     off(0022dh).1, vcal3_leanprotect_ratelimit_goto_3c9c
                CMPB    off(002b2h), #003h
                JLT     vcal3_leanprotect_ratelimit_goto_3cb2
                JEQ     vcal3_leanprotect_ratelimit_if_ram22d_bit2_clr
                JBR     off(0022dh).3, vcal3_leanprotect_ratelimit_goto_3cb2
                SJ      vcal3_leanprotect_ratelimit_load_carry_ram22f_bit4
vcal3_leanprotect_ratelimit_if_ram22d_bit2_clr:
                JBR     off(0022dh).2, vcal3_leanprotect_ratelimit_goto_3cb2
vcal3_leanprotect_ratelimit_load_carry_ram22f_bit4:
                MB      C, off(0022fh).4
                JEQ     vcal3_leanprotect_ratelimit_if_lt_goto_3adb
                MB      C, off(0022fh).5
vcal3_leanprotect_ratelimit_if_lt_goto_3adb:
                JLT     vcal3_leanprotect_ratelimit_load_ram2de
                MOVB    off(002deh), #00ah
vcal3_leanprotect_ratelimit_load_ram2de:
                LB      A, off(002deh)
                JEQ     vcal3_leanprotect_ratelimit_set_ram22f_bit3
                J       vcal3_leanprotect_ratelimit_load_ram2ac_2
vcal3_leanprotect_ratelimit_goto_3c9c:
                J       vcal3_leanprotect_ratelimit_load_ram2a6
vcal3_leanprotect_ratelimit_goto_3cb2:
                J       vcal3_leanprotect_ratelimit_clear_acc
vcal3_leanprotect_ratelimit_set_ram22f_bit3:
                SB      off(0022fh).3
                JNE     vcal3_leanprotect_ratelimit_load_ram2ac
                MOV     DP, #00316h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_load_dp_ind
                MOV     DP, #00318h
vcal3_leanprotect_ratelimit_load_dp_ind:
                L       A, [DP]
                ST      A, off(002a8h)
                SJ      vcal3_leanprotect_ratelimit_if_eq_goto_3b5d
vcal3_leanprotect_ratelimit_load_ram2ac:
                LB      A, off(002ach)
                MOVB    r0, #050h
                MOV     er1, #039eeh
                MOVB    r6, #028h
                MOVB    r7, #028h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_subb_acc_3
                LB      A, off(002aeh)
                MOVB    r0, #050h
                MOV     er1, #04cefh
                MOVB    r6, #028h
                MOVB    r7, #028h
vcal3_leanprotect_ratelimit_subb_acc_3:
                SUBB    A, 0d1h
                MB      PSWL.4, C
                JGE     vcal3_leanprotect_ratelimit_mulb_acc
                VCAL    6
vcal3_leanprotect_ratelimit_mulb_acc:
                MULB
                L       A, ACC
                MB      C, PSWL.4
                JGE     vcal3_leanprotect_ratelimit_add_acc
                XCHG    A, er1
                SUB     A, er1
                JGE     vcal3_leanprotect_ratelimit_store_er0
                CLR     A
                SJ      vcal3_leanprotect_ratelimit_store_er0
vcal3_leanprotect_ratelimit_add_acc:
                ADD     A, er1
                JGE     vcal3_leanprotect_ratelimit_store_er0
                L       A, #0ffffh
vcal3_leanprotect_ratelimit_store_er0:
                ST      A, er0
                L       A, 0ceh
                MUL
                L       A, er1
                MOV     DP, #00386h
                ST      A, [DP]
                SUB     A, 0c4h
                MB      PSWL.4, C
                JGE     vcal3_leanprotect_ratelimit_load_dp
                VCAL    7
vcal3_leanprotect_ratelimit_load_dp:
                MOV     DP, #00388h
                ST      A, [DP]
                CAL     weighted_sum_2term_trim
vcal3_leanprotect_ratelimit_if_eq_goto_3b5d:
                JEQ     vcal3_leanprotect_ratelimit_load_x2
                CMP     A, #00333h
                JLT     vcal3_leanprotect_ratelimit_load_x2
                L       A, #00333h
vcal3_leanprotect_ratelimit_load_x2:
                MOV     X2, A
                MOV     X1, #00316h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_load_er0
                INC     X1
                INC     X1
vcal3_leanprotect_ratelimit_load_er0:
                MOV     er0, #000ffh
                CAL     vcal3_leanprotect_ratelimit_sub_load_er2
                CAL     clamp_to_35_512
                L       A, X2
                RB      off(0022fh).2
                RB      off(0022fh).1
                J       vcal3_leanprotect_ratelimit_store_ram2a6
vcal3_leanprotect_ratelimit_clear_r0:
                CLRB    r0
                MOV     DP, #00312h
                MOVB    r1, #080h
                MOVB    r2, #040h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_load_dp_ind_2
                INC     DP
                INC     DP
                MOVB    r1, #080h
                MOVB    r2, #040h
vcal3_leanprotect_ratelimit_load_dp_ind_2:
                L       A, [DP]
                SUB     A, off(002a8h)
                MB      PSWL.4, C
                JGE     vcal3_leanprotect_ratelimit_cmp_acc_23
                VCAL    7
                MOVB    r1, r2
vcal3_leanprotect_ratelimit_cmp_acc_23:
                CMP     A, #00155h
                SB      off(0022fh).1
                JNE     vcal3_leanprotect_ratelimit_if_ram222_bit7_set
                JGE     vcal3_leanprotect_ratelimit_mul_acc
                L       A, [DP]
                SJ      vcal3_leanprotect_ratelimit_cmp_acc_24
vcal3_leanprotect_ratelimit_mul_acc:
                MUL
                SLL     A
                ROL     er1
                JGE     vcal3_leanprotect_ratelimit_load_ram2a8
                MOV     er1, #0ffffh
vcal3_leanprotect_ratelimit_load_ram2a8:
                L       A, off(002a8h)
                MB      C, PSWL.4
                JLT     vcal3_leanprotect_ratelimit_sub_acc
                ADD     A, er1
                JLT     vcal3_leanprotect_ratelimit_load_imm_4
vcal3_leanprotect_ratelimit_cmp_acc_24:
                CMP     A, #003ffh
                JLT     vcal3_leanprotect_ratelimit_store_ram2a8
vcal3_leanprotect_ratelimit_load_imm_4:
                L       A, #003ffh
                SJ      vcal3_leanprotect_ratelimit_store_ram2a8
vcal3_leanprotect_ratelimit_sub_acc:
                SUB     A, er1
                JGE     vcal3_leanprotect_ratelimit_store_ram2a8
                CLR     A
vcal3_leanprotect_ratelimit_store_ram2a8:
                ST      A, off(002a8h)
vcal3_leanprotect_ratelimit_if_ram222_bit7_set:
                JBS     off(00222h).7, vcal3_leanprotect_ratelimit_load_ram2df
                CMP     off(002aah), #00180h
                JLT     vcal3_leanprotect_ratelimit_load_ram2df
                LB      A, off(002dfh)
                JNE     vcal3_leanprotect_ratelimit_load_ram0ce
                MOVB    off(002b2h), #004h
                SJ      vcal3_leanprotect_ratelimit_load_ram0ce
vcal3_leanprotect_ratelimit_load_ram2df:
                MOVB    off(002dfh), #028h
vcal3_leanprotect_ratelimit_load_ram0ce:
                L       A, 0ceh
                MOV     er0, #03c18h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_mul_acc_2
                MOV     er0, #05352h
vcal3_leanprotect_ratelimit_mul_acc_2:
                MUL
                L       A, er1
                MOV     DP, #00386h
                ST      A, [DP]
                L       A, 0c4h
                SUB     A, er1
                MB      off(00222h).7, C
                MB      PSWL.4, C
                JGE     vcal3_leanprotect_ratelimit_store_ram2aa
                VCAL    7
vcal3_leanprotect_ratelimit_store_ram2aa:
                ST      A, off(002aah)
                MOVB    r6, #020h
                MOVB    r7, #020h
                CAL     weighted_sum_2term_trim
                MOV     X2, A
                JEQ     vcal3_leanprotect_ratelimit_cmp_ram2e0
                MOVB    off(002e0h), #014h
vcal3_leanprotect_ratelimit_cmp_ram2e0:
                CMPB    off(002e0h), #000h
                JNE     vcal3_leanprotect_ratelimit_if_ram22c_bit6_clr
                CLR     X2
                SJ      vcal3_leanprotect_ratelimit_load_x2_2
vcal3_leanprotect_ratelimit_if_ram22c_bit6_clr:
                JBR     off(0022ch).6, vcal3_leanprotect_ratelimit_load_x2_2
                JBS     off(0022ch).7, vcal3_leanprotect_ratelimit_load_x2_2
                MOV     X1, #00312h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_load_er0_2
                INC     X1
                INC     X1
vcal3_leanprotect_ratelimit_load_er0_2:
                MOV     er0, #000ffh
                CAL     vcal3_leanprotect_ratelimit_sub_load_er2
                CAL     vcal3_leanprotect_ratelimit_sub_load_er2_2
vcal3_leanprotect_ratelimit_load_x2_2:
                L       A, X2
                RB      off(0022fh).2
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit3
vcal3_leanprotect_ratelimit_load_ram2ac_2:
                LB      A, off(002ach)
                MOVB    r0, off(002adh)
                MOV     er1, #00080h
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_15
                MOV     DP, #00316h
                CMPB    off(002b2h), #003h
                JLE     vcal3_leanprotect_ratelimit_cmp_acc_25
                LB      A, off(002aeh)
                MOVB    r0, off(002afh)
                MOV     er1, #00080h
                MOV     X1, #vcal3_leanprotect_ratelimit_tbl_16
                INC     DP
                INC     DP
vcal3_leanprotect_ratelimit_cmp_acc_25:
                CMPB    A, 0d1h
                JGE     vcal3_leanprotect_ratelimit_load_er1
                MOV     er1, [DP]
                LB      A, 0d1h
                SUBB    A, r0
                JLT     vcal3_leanprotect_ratelimit_load_er1
                VCAL    0
                ; warning: had to flip DD
                ADD     A, [DP]
                JLT     vcal3_leanprotect_ratelimit_load_imm_5
                SJ      vcal3_leanprotect_ratelimit_cmp_acc_26
vcal3_leanprotect_ratelimit_load_er1:
                L       A, er1
vcal3_leanprotect_ratelimit_cmp_acc_26:
                CMP     A, #00300h
                JLT     vcal3_leanprotect_ratelimit_call_5b75
vcal3_leanprotect_ratelimit_load_imm_5:
                L       A, #00300h
vcal3_leanprotect_ratelimit_call_5b75:
                CAL     vcal3_leanprotect_ratelimit_sub_cmp_acc
                JBS     off(0022fh).2, vcal3_leanprotect_ratelimit_store_ram2a8_2
                CMP     A, off(002a6h)
                MB      off(0022fh).2, C
                JLT     vcal3_leanprotect_ratelimit_store_ram2a8_2
                L       A, off(002a6h)
                ADD     A, #00020h
                CAL     vcal3_leanprotect_ratelimit_sub_if_lt_goto_5b7a
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit1
vcal3_leanprotect_ratelimit_store_ram2a8_2:
                ST      A, off(002a8h)
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit1
vcal3_leanprotect_ratelimit_load_ram2a6:
                L       A, off(002a6h)
                ADD     A, er1
                JLT     vcal3_leanprotect_ratelimit_load_imm_6
                CMP     A, #003ffh
                JGE     vcal3_leanprotect_ratelimit_load_imm_6
                CMP     A, #003ffh
                JLT     vcal3_leanprotect_ratelimit_clear_ram22f_bit2
vcal3_leanprotect_ratelimit_load_imm_6:
                L       A, #003ffh
                ST      A, off(002a8h)
                SJ      vcal3_leanprotect_ratelimit_clear_ram22f_bit2
vcal3_leanprotect_ratelimit_clear_acc:
                CLR     A
                ST      A, off(002a8h)
vcal3_leanprotect_ratelimit_clear_ram22f_bit2:
                RB      off(0022fh).2
vcal3_leanprotect_ratelimit_clear_ram22f_bit1:
                RB      off(0022fh).1
vcal3_leanprotect_ratelimit_clear_ram22f_bit3:
                RB      off(0022fh).3
vcal3_leanprotect_ratelimit_store_ram2a6:
                ST      A, off(002a6h)
                CMP     A, #00023h
                JGE     vcal3_leanprotect_ratelimit_load_er0_3
                CLR     A
vcal3_leanprotect_ratelimit_load_er0_3:
                MOV     er0, #00064h
                MUL
                MOV     er0, er1
                MOV     er2, #003ffh
                DIV
                LB      A, ACC
                STB     A, 0e4h
                RT
vcal3_task_c_timers:
                MOV     DP, #00012h
                MOV     X1, #001dbh
                CAL     decrement_timer_array
                MOV     DP, #00026h
                MOV     X1, #002cbh
                CAL     decrement_timer_array
                LB      A, 0f3h
                ADDB    A, #001h
                JEQ     vcal3_task_c_msec_tick
                STB     A, 0f3h
vcal3_task_c_msec_tick:
                CAL     selftest_reason_range_check
                CLR     X1
                LB      A, 00399h[X1]
                JEQ     percyl_counter_gate
                CMPB    off(002d0h), #000h
                JNE     percyl_alt_check
                MOVB    r2, #010h
                CMPB    A, r2
                JGE     percyl_counter_check2
                MOVB    r2, #001h
percyl_counter_check2:
                SUBB    A, r2
                MOV     er1, #01107h
                JNE     percyl_store_result
percyl_counter_gate:
                SC
                JBS     off(00214h).7, tach_output_drive
                CLR     A
percyl_counter_loop:
                LB      A, 0039ah[X1]
                STB     A, r0
                CMPB    A, #020h
                JLT     percyl_counter_dp_select
                CLRB    0039ah[X1]
                LCB     A, idle_init_start_tbl
                JEQ     tach_output_drive
                LB      A, 0afh
                JEQ     tach_output_drive
                SJ      percyl_bcd_convert
percyl_counter_dp_select:
                MOV     DP, #00321h
                CMPB    A, #018h
                JGE     percyl_counter_increment
                DEC     DP
                JBS     off(00208h).4, percyl_counter_increment
                DEC     DP
                JBS     off(00208h).3, percyl_counter_increment
                DEC     DP
percyl_counter_increment:
                INCB    0039ah[X1]
                TRB     [DP]  ; mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C213
                JNE     percyl_wrap_check1
                LB      A, 0039ah[X1]
                ANDB    A, #007h
                RC
                JNE     percyl_counter_loop
                SJ      tach_output_drive
percyl_wrap_check1:
                ADDB    A, #001h
                CMPB    A, #01dh
                JNE     percyl_wrap_check2
                LB      A, #02bh
percyl_wrap_check2:
                CMPB    A, #01bh
                JNE     percyl_wrap_check3
                LB      A, #029h
percyl_wrap_check3:
                CMPB    A, #01ah
                JNE     percyl_wrap_check4
                LB      A, #024h
percyl_wrap_check4:
                CMPB    A, #019h
                JNE     percyl_bcd_convert
                LB      A, #023h
percyl_bcd_convert:
                MOVB    r0, #00ah
                DIVB
                SWAPB
                ORB     A, r1
                MOV     er1, #02b20h
percyl_store_result:
                STB     A, 00399h[X1]
                CMPB    A, #010h
                JLT     percyl_result_final
                MOVB    r2, r3
percyl_result_final:
                MOVB    off(002d0h), r2
percyl_alt_check:
                CMPB    A, #010h
                L       A, #00206h
                JLT     percyl_alt_store
                L       A, #00311h
percyl_alt_store:
                ST      A, er1
                LB      A, off(002d0h)
                CMPB    A, r2
                JGE     tach_output_drive
                CMPB    r3, A
tach_output_drive:
                MB      P1.5, C
                JBR     off(00210h).7, tach_output_drive_if_ram227_bit3_clr
                MOV     DP, #0031eh
                L       A, [DP]
                JNE     tach_output_drive_store_carry_p1_bit4
                INC     DP
                INC     DP
                L       A, [DP]
                JNE     tach_output_drive_store_carry_p1_bit4
                LCB     A, idle_init_start_tbl
                JEQ     tach_output_drive_set_carry
                LB      A, 0afh
                JNE     tach_output_drive_store_carry_p1_bit4
tach_output_drive_set_carry:
                SC
tach_output_drive_store_carry_p1_bit4:
                MB      P1.4, C
tach_output_drive_if_ram227_bit3_clr:
                JBR     off(00227h).3, tach_output_return
                MOV     er2, 0ceh
                MOV     er0, #00021h
                L       A, #0af7ah
                DIV
                CMP     er0, #00000h
                JEQ     tach_output_drive_load_dp
                L       A, #0ffffh
tach_output_drive_load_dp:
                MOV     DP, #00390h
                XCHG    A, [DP]
                SUB     A, [DP]
                JGE     tach_output_drive_cmp_acch
                VCAL    7
tach_output_drive_cmp_acch:
                CMPB    ACCH, #000h
                JEQ     tach_output_drive_load_dp_2
                LB      A, #0ffh
tach_output_drive_load_dp_2:
                MOV     DP, #0038dh
                MOVB    [DP], A
                MOV     DP, #0038ch
                LB      A, 0cch
                JNE     tach_output_drive_cmp_acc
                LB      A, [DP]
                JEQ     tach_output_return
                MOVB    r6, #0ffh
                CMPB    r6, A
                MB      off(00226h).6, C
                CLRB    A
                SJ      tach_output_drive_store_dp_ind
tach_output_drive_cmp_acc:
                CMPB    A, [DP]
                JLT     tach_output_return
tach_output_drive_store_dp_ind:
                STB     A, [DP]
tach_output_return:
                RT
vcal3_task_b_body:
                MOV     DP, #00002h
                MOV     X1, #001cdh
                CAL     decrement_timer_array
                MOV     DP, #00009h
                MOV     X1, #002b5h
                CAL     decrement_timer_array
                LB      A, 0f2h
                ADDB    A, #001h
                JEQ     vcal3_task_b_body_if_ram216_bit1_clr
                STB     A, 0f2h
vcal3_task_b_body_if_ram216_bit1_clr:
                JBR     off(00216h).1, learn_table1_check
                LB      A, #006h
                CMPB    A, (001cah-00180h)[USP]
                JLE     vcal3_task_b_body_cmp_acc
                INCB    (001cah-00180h)[USP]
vcal3_task_b_body_cmp_acc:
                CMPB    A, (001c9h-00180h)[USP]
                JLE     learn_table1_check
                INCB    (001c9h-00180h)[USP]
learn_table1_check:
                LB      A, off(002bbh)
                JNE     learn_table2_check
                MOVB    off(002bbh), #002h
                MOV     X1, #tbl_diag_snapshot_data2
                MOV     DP, #001b3h
                MOVB    r6, #027h
learn_table1_loop:
                LB      A, [DP]
                ADDB    A, #001h
                JLT     learn_table1_reset_entry
                CMPCB   A, [X1]
                JLT     learn_table1_store
learn_table1_reset_entry:
                LCB     A, [X1]
learn_table1_store:
                STB     A, [DP]
                LB      A, r6
                SUBB    A, 0f4h
                JNE     learn_table1_advance
                STB     A, 0f4h
learn_table1_advance:
                INC     X1
                INC     DP
                INCB    r6
                CMP     DP, #001b7h
                JLE     learn_table1_loop
learn_table2_check:
                LB      A, off(002bch)
                JNE     vcal3_task_a_return
                MOVB    off(002bch), #002h
                LB      A, #001h
                MB      C, 0b7h.1
                JLT     learn_counter_store
                LB      A, 0f7h
                ADDB    A, #001h
                CMPB    A, #020h
                JLT     learn_counter_store
                LB      A, #020h
learn_counter_store:
                STB     A, 0f7h
                LB      A, 0f6h
                ADDB    A, #001h
                CMPB    A, #020h
                JLT     learn_retry_store
                RB      0b7h.1
                LB      A, #020h
learn_retry_store:
                STB     A, 0f6h
vcal3_task_a_return:
                RT
regbank_selftest2_start:
                L       A, #02babh
                MOV     X1, #002a0h
                JBR     off(00217h).2, regbank_selftest2_ie_check
                L       A, #0a9a3h
                MOV     X1, #000a0h
regbank_selftest2_ie_check:
                CMP     A, 0f8h
                JNE     selftest_fail_04f
                CMP     A, IE
                JNE     selftest_fail_04f
                L       A, X1
                CMP     A, 0fah
                JEQ     regbank_selftest2_range_check
selftest_fail_04f:
                MOVB    0f5h, #04fh
                J       fault_retry_check
regbank_selftest2_range_check:
                MOV     DP, #00394h
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
selftest_fail_042_alt:
                MOVB    0f5h, #042h
                BRK
regbank_selftest2_check3:
                MOV     X2, A
                CMP     A, X2
                JNE     selftest_fail_042_alt
regbank_selftest2_default:
                L       A, #003fah
irqmode_dispatch:
                MOV     DP, #00394h
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
dtc04_ckp_latch_2:
                SB      0b4h.0
irqmode_check1: ORB     PSWH, #001h
                CMPB    (001adh-00180h)[USP], #029h
                ANDB    PSWH, #0feh
                JLT     irqmode_select_b
                JBR     off(00217h).2, irqmode_done
                L       A, #02babh
                ST      A, IE
                ST      A, 0f8h
                MOV     0fah, #002a0h
                RB      off(00217h).2
                SJ      irqmode_done
irqmode_select_b:
                JBS     off(00217h).2, irqmode_done
                L       A, #0a9a3h
                ST      A, IE
                ST      A, 0f8h
                MOV     0fah, #000a0h
                SB      off(00217h).2
                RB      (00125h-00180h)[USP].7
                RB      off(0021dh).7
                SB      TCON3.3
                SB      TCON3.2
irqmode_done:   ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
stack_sanity_check:
                CMP     SSP, #0047eh
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
selftest_fail_050:
                MOVB    0f5h, #050h
                BRK
periph_init_verify_pwm_adc:
                LB      A, PWCON0
                ANDB    A, #07bh
                CMPB    A, #03ah
                JNE     selftest_fail_050
                LB      A, PWCON1
                ANDB    A, #07bh
                CMPB    A, #07ah
                JNE     selftest_fail_050
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
                CMPB    STTMR, #0dfh
                JNE     selftest_fail_050
periph_init_verify_done:
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                MOV     er0, TM0
                MOV     er1, TM1
                MOV     er2, TM2
                MOV     er3, TM3
                ORB     PSWH, #001h
                NOP
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
clock_selftest_check2:
                CMP     A, #00002h
                JGE     selftest_fail_04b
                L       A, er1
                SRL     A
                SRL     A
                SUB     A, X2
                JGE     clock_selftest_check3
                VCAL    7
clock_selftest_check3:
                CMP     A, #00002h
                JGE     selftest_fail_04b
                L       A, X2
                SUB     A, er0
                JGE     clock_selftest_check4
                VCAL    7
clock_selftest_check4:
                CMP     A, #00002h
                JLT     clock_selftest_passed
selftest_fail_04b:
                MOVB    0f5h, #04bh
                BRK
clock_selftest_passed:
                VCAL    3
                CAL     boot_completion_helper
                MOVB    r0, #001h
                JBR     off(00217h).2, warmcold_ie_setup
                MOVB    r0, #006h
warmcold_ie_setup:
                L       A, 0fah
; COLD vs WARM RESTART FORK (0x3480-0x353C+): this is the transition point flagged much
; earlier in this file as needing dedicated tracing -- now traced. warmcold_tm2_check compares
; the current TM2 reading against a saved value (0xAE/0xEE) to detect whether the engine
; appears to still be running/turning (a brief ECU reset while cranking) vs a genuine cold
; power-up:
; - coldstart_full_reset (warm check failed -> true cold start): zeroes currentRPMByte, the
; ignition/injector hardware timer-prep registers (0x360-0x372, 0x3A6, 0x357/0x358/0x35D/
; 0x35E), VTEC/mode flags (0x124/0x126/0x127/0x128/0x21C/0x21E/0x21F/0x221/0x232), and
; drives P4.0/P1 low -- a full reset of all per-cycle working state built up over this
; session's traced routines.
; - warmrestart_path/warmrestart_tm3_resync (warm check passed -> engine still turning):
; skips the reset entirely, just resyncs TM3 -- preserves ignition/fuel/VTEC state across
; the brief reset instead of losing sync with a spinning engine.
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      off(00231h).5
                JBR     off(00217h).4, warmcold_tm2_check
                J       warmrestart_tm3_resync
warmcold_tm2_check:
                JNE     coldstart_full_reset
                LB      A, r0
                CMPB    A, 0aeh
                JLT     coldstart_full_reset
                JNE     warmrestart_path
                L       A, TM2
                CMP     A, 0eeh
                JGE     coldstart_full_reset
warmrestart_path:
                J       warmcold_reconverge
coldstart_full_reset:
                SB      off(00217h).4
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
                ST      A, off(00268h)
                J       coldstart_full_reset_store_tbl_x1_2
coldstart_full_reset_store_tbl_x1:
                ST      A, 0036ch[X1]
                ST      A, 0036eh[X1]
                ST      A, 00370h[X1]
                ST      A, 0c4h
                CLRB    A
                STB     A, off(00238h)
                STB     A, (00133h-00180h)[USP]
                STB     A, 0c3h
                STB     A, off(0029fh)
                J       coldstart_full_reset_store_stk
coldstart_full_reset_orb_tcon3:
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
                J       coldstart_full_reset_clear_ram232_bit7
coldstart_full_reset_clear_stk:
                RB      (00126h-00180h)[USP].4
                RB      off(0021eh).4
                CLR     A
                ST      A, (00128h-00180h)[USP]
                ST      A, (00124h-00180h)[USP]
                ST      A, off(0021ch)
                ST      A, (001a2h-00180h)[USP]
                ST      A, (001a0h-00180h)[USP]
                ST      A, 0ech
                ST      A, 0eah
warmrestart_tm3_resync:
                L       A, TM3
                SUB     A, #00001h
                ST      A, TMR3
warmcold_reconverge:
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                SC
                JBS     off(00217h).4, warmcold_deg_flag
                JBS     off(00211h).0, warmcold_deg_select
                JBR     off(00217h).5, warmcold_deg_flag_load_stk
warmcold_deg_select:
                LB      A, #012h
                JBS     off(00217h).5, warmcold_deg_check
                LB      A, #01dh
warmcold_deg_check:
                CMPB    A, 0c5h
warmcold_deg_flag:
                MB      off(00217h).5, C
                JGE     warmcold_deg_flag_load_stk
                JBR     off(00211h).0, warmcold_msec_reset
                SB      off(00230h).4
warmcold_msec_reset:
                CLRB    A
                STB     A, 0f3h
                STB     A, 0f2h
                JBR     off(00217h).4, warmcold_deg_flag_vcal_3
warmcold_deg_flag_load_stk:
                MOVB    (001e7h-00180h)[USP], #063h
warmcold_deg_flag_vcal_3:
                VCAL    3
                CLR     X1
                LB      A, 003f9h[X1]
                JNE     tps_learn_alt_path
                MOVB    003f9h[X1], #006h
                LB      A, #0fah
                JBS     off(00217h).4, warmcold_deg_flag_store_tbl_x1
                STB     A, r0
                LB      A, #07bh
                STB     A, r1
                STB     A, r2
                JBS     off(0021ah).1, warmcold_deg_flag_load_r0
                JBS     off(0021ah).2, warmcold_deg_flag_load_r0
                LB      A, 0d4h
                CMPB    A, r1
                JGE     warmcold_deg_flag_load_r0
                STB     A, r1
                MOVB    r3, 00378h[X1]
                SUBB    A, r3
                JLT     warmcold_deg_flag_load_tbl_x1
                CMPB    A, #004h
                JGE     warmcold_deg_flag_load_r0
                SUBB    00377h[X1], #001h
                JNE     warmcold_deg_flag_load_tbl_x1_2
                LB      A, r3
                STB     A, 00311h[X1]
                MOVB    00310h[X1], #0ffh
                SJ      warmcold_deg_flag_load_tbl_x1_2
warmcold_deg_flag_load_tbl_x1:
                LB      A, 00310h[X1]
                JNE     warmcold_deg_flag_load_r0
                MOVB    r0, #053h
warmcold_deg_flag_load_r0:
                LB      A, r0
                STB     A, 00377h[X1]
                LB      A, r1
                STB     A, 00378h[X1]
warmcold_deg_flag_load_tbl_x1_2:
                LB      A, 00311h[X1]
                CMPB    A, r2
                JLT     tps_learn_alt_path
                LB      A, r2
                STB     A, 00311h[X1]
                SJ      tps_learn_alt_path
warmcold_deg_flag_store_tbl_x1:
                STB     A, 00377h[X1]
tps_learn_alt_path:
                CLR     X1
                L       A, 0030ch[X1]
                CMP     A, #00010h
                JLT     fueltbl_default_load
                CMP     A, #01000h
                JLE     fueltbl_sanitize_loop
fueltbl_default_load:
                L       A, 00382h[X1]
; --- Fuel table shadow-copy sanitization (0x35AE-0x35E8): walks the FUEL1_Hi_Extended
; region in RAM (0x300-0x30C), and for any entry outside a plausible range (0x9862 max,
; FUEL1_Hi_Extended min) resets it to a default 0x8000 -- guards against corrupted/garbage
; fuel-table data. Followed by a knock-related check (knock_helper1 onward, comparing against
; tbl_knock_sanity) gated by a critical-section register snapshot -- likely a knock-retard sanity
; check, not fully confirmed.
                ST      A, 0030ch[X1]
fueltbl_sanitize_loop:
                MOV     DP, #00300h
fueltbl_sanitize_check:
                JBR     off(00216h).2, fueltbl_range_check
                MB      C, 0b8h.5
                JLT     fueltbl_default_value
fueltbl_range_check:
                CMP     [DP], #09862h
                JGT     fueltbl_default_value
                CMP     [DP], #07133h
                JGE     fueltbl_sanitize_advance
fueltbl_default_value:
                MOV     [DP], #08000h
fueltbl_sanitize_advance:
                ADD     DP, #00004h
                CMP     DP, #0030ch
                JLT     fueltbl_sanitize_check
                MB      C, (00128h-00180h)[USP].2
                JGE     sensor_check_vcal3
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                MOVB    r0, (0018eh-00180h)[USP]
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
                LC      A, fueltbl_sanitize_advance_tbl[ACC]
                JEQ     sensor_check_vcal3
                CMP     A, er0
                JEQ     sensor_check_vcal3
knock_check_alt_path:
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                RB      TCON0.4
                RB      TCON0.2
                LB      A, #00fh
                STB     A, (00117h-00180h)[USP]
                STB     A, (0018fh-00180h)[USP]
                ORB     P2, A
                SB      TCON0.2
                LB      A, (0013ch-00180h)[USP]
                CAL     knock_helper1
                STB     A, (0018eh-00180h)[USP]
                XORB    A, #0ffh
                MB      C, ACC.7
                ROLB    A
                STB     A, (00116h-00180h)[USP]
                RB      TCON0.2
                SB      TCON0.4
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
sensor_check_vcal3:
                VCAL    3
                MOV     DP, #003cdh
                J       sensor_check_vcal3_load_dp_ind
sensor_check_gate1_if_ram212_bit2_set:
                JBS     off(00212h).2, sensor_check_clear
                JBS     off(00212h).4, sensor_check_clear
                JBR     off(00217h).5, sensor_check_gate2
                MOVB    (001e8h-00180h)[USP], #064h
                SJ      sensor_check_clear
sensor_check_gate2:
                JBS     off(00230h).5, sensor_check_clear
                CMPB    off(00238h), #002h
                JGE     sensor_check_gate3
                MOVB    (001e8h-00180h)[USP], #064h
sensor_check_gate3:
                JBR     off(00230h).4, sensor_check_clear
                MOV     DP, #00374h
                LB      A, [DP]
                SUBB    A, ADCR6H
                JGE     sensor_check_result
                VCAL    6
sensor_check_result:
                CMPB    A, #002h
                JGE     sensor_check_set
                LB      A, (001e8h-00180h)[USP]
                JEQ     dtc05_map_range_latch
sensor_check_clear:
                RC
                SJ      dtc05_map_range_latch
sensor_check_set:
                SB      off(00230h).5
dtc05_map_range_latch:
                MB      0b0h.3, C
                RB      PSWL.4
                CLR     X1
                LB      A, 003d0h[X1]
                STB     A, r1
                RC
                JBS     off(00212h).5, dtc06_ect_latch
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc06_ect_latch
                LB      A, r1
                CMPB    A, #004h
dtc06_ect_latch:
                MB      0b0h.1, C
                JBS     off(00212h).5, ect_simulate_ramp
                JLT     ect_fault_stamp
                JBS     off(00210h).7, ect_smooth_apply
                SUBB    A, 00375h[X1]
                JGE     ect_fault_delta_check
                VCAL    6
ect_fault_delta_check:
                CMPB    A, #002h
                JGT     ect_fault_normal_store
                LB      A, (001e9h-00180h)[USP]
                JNE     sensor_bank_ect_check_goto_79db
                LB      A, r1
                JBS     off(00217h).4, ect_smooth_apply
                CMPB    A, 00376h[X1]
                JGT     sensor_bank_ect_check
                SJ      ect_smooth_apply
ect_simulate_ramp:
                JBR     off(00217h).5, ect_fault_stamp
                CLR     A
                LB      A, (001e7h-00180h)[USP]
                MOVB    r0, #014h
                DIVB
                MOV     DP, #tbl_ect_simulate_ramp
                ADD     DP, A
                LCB     A, [DP]
                STB     A, 0d9h
                SB      PSWL.4
                SJ      sensor_bank_ect_check
ect_fault_stamp:
                MOVB    0d9h, #03bh
                SB      PSWL.4
                SJ      sensor_bank_ect_check
ect_smooth_apply:
                MOVB    r0, 0d9h
                MOV     DP, #000d9h
                CAL     ect_smooth_helper
                CMPB    A, r0
                JEQ     ect_store_history_check
                SB      PSWL.4
ect_store_history_check:
                JBS     off(00217h).5, ect_step_call
                STB     A, 0031ah[X1]
ect_step_call:  CAL     ect_step_helper
ect_fault_normal_store:
                LB      A, r1
                STB     A, 00375h[X1]
sensor_bank_ect_check:
                MOVB    (001e9h-00180h)[USP], #005h
sensor_bank_ect_check_goto_79db:
                J       sensor_bank_ect_check_if_ram230_bit3_clr
                DB  000h
sensor_bank_ect_check_load_carry_pswl_bit4:
                MB      C, PSWL.4
sensor_bank_ect_check_store_carry_ram234_bit6:
                MB      off(00234h).6, C
                RC
                JBS     off(00212h).7, dtc08_tdc_latch
                JBR     off(00217h).4, dtc08_tdc_latch
                MB      C, off(00211h).0
                JBR     off(00216h).3, dtc08_tdc_latch
                JGE     dtc08_tdc_latch
                MB      C, off(00211h).5
dtc08_tdc_latch:
                MB      0b0h.5, C
                JBR     off(00213h).1, iat_range_check
                MOVB    0d8h, #057h
                SJ      iat_check_return
iat_range_check:
                LB      A, #0fch
                MOV     DP, #003c8h
                CMPB    A, [DP]
                JLT     dtc10_iat_latch
                LB      A, [DP]
                CMPB    A, #004h
                JLT     dtc10_iat_latch
                MOV     DP, #000d8h
                CAL     ect_smooth_helper
iat_check_return:
                RC
dtc10_iat_latch:
                MB      0b0h.6, C
                LB      A, #080h
                RC
                JBS     off(00217h).6, sensor_bank_store_e3
                JBS     off(00219h).3, sensor_bank_store_e3
                JBS     off(00213h).2, sensor_bank_store_e3
                MOV     DP, #003ceh
                LB      A, #0ffh
                CMPB    A, [DP]
                JLT     dtc_bit08_latch
                LB      A, [DP]
                CMPB    A, #000h
                JLT     dtc_bit08_latch
sensor_bank_store_e3:
                STB     A, 0e3h
dtc_bit08_latch:
                MB      0b0h.7, C
                JBR     off(00227h).4, sensor_bank_stamp_bc
                JBR     off(00213h).4, sensor_bank_bc_alt
sensor_bank_stamp_bc:
                MOVB    0bch, #0f9h
                SJ      dcode14_return
sensor_bank_bc_alt:
                CLR     A
                LB      A, #0ffh
                MOV     DP, #003c9h
                CMPB    A, [DP]
                JLT     dtc13_baro_latch
                LB      A, [DP]
                CMPB    A, #000h
                JLT     dtc13_baro_latch
                CAL     sub_clamp_helper
                MOV     DP, #000bch
                CAL     ect_smooth_helper
dcode14_return: RC
dtc13_baro_latch:
                MB      0b1h.2, C
                VCAL    3
                JBS     off(00217h).5, dcode14_clear
                JBS     off(00213h).5, dcode14_clear
                LB      A, 0dbh
                MOV     X1, #tbl_dcode14_lo
                VCAL    2
                CMPB    A, off(0025eh)
                JLT     dcode14_clear
                LB      A, 0dbh
                MOV     X1, #tbl_dcode14_hi
                VCAL    2
                CMPB    A, off(0025eh)
                JGE     dcode14_clear
                LB      A, (001eah-00180h)[USP]
                JEQ     dtc14_iacv_latch
dcode14_clear:  RC
dtc14_iacv_latch:
                MB      0b1h.3, C
                LB      A, #044h
                CMPB    A, 0dbh
                JGE     dtc17_vss_latch
                CMPB    off(00238h), #0b0h
                JGE     dtc17_vss_latch
                RC
                JBS     off(00217h).5, dtc17_vss_latch
                JBS     off(00214h).0, dtc17_vss_latch
                JBR     off(00231h).3, dtc17_vss_latch
                MB      C, off(0021ch).4
dtc17_vss_latch:
                MB      0b1h.4, C
                RC
                JBS     off(00227h).2, dtc_bit0F_latch
                JBR     off(00216h).3, dtc_bit0F_latch
                JBS     off(00214h).2, dtc_bit0F_latch
                MB      C, off(00210h).4
                JBR     off(0022fh).0, dtc_bit0F_latch
                XORB    PSWH, #080h
dtc_bit0F_latch:
                MB      0b1h.6, C
                VCAL    3
                JBS     off(00227h).2, dcode_gate_common2
                JBR     off(00216h).3, dcode_gate_common2
                JBS     off(00214h).2, dcode_gate_common2
                MOV     DP, #003e8h
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                L       A, [DP]
                ST      A, er0
                MOV     DP, #04700h
                LB      A, [DP]
                STB     A, r7
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                ANDB    r7, #008h
                LB      A, r0
                CMPB    A, #00ah
                JLT     dcode_gate_common2
                SUBB    A, r1
                JGE     dcode_gate_common_cmp_acc
                LB      A, r7
                JNE     dtc19_at_lockup_latch
                SJ      dcode_gate_common2
dcode_gate_common_cmp_acc:
                CMPB    A, #00ah
                JLT     dcode_gate_common2
                LB      A, r7
                JNE     dcode_gate_common2
dtc19_at_lockup_latch:
                SB      0b4h.7
dcode_gate_common2:
                LB      A, #025h
                JBR     off(00219h).3, dcode_stamp_store
                JBR     off(00217h).6, dcode_stamp_store
                JBS     off(00214h).3, dcode_stamp_store
                CMPB    0dbh, #069h
                JLT     dcode_stamp_store
                MOV     DP, #003ceh
                LB      A, #0dch
                CMPB    A, [DP]
                JLT     dtc20_eld_latch
                LB      A, [DP]
                CMPB    A, #00eh
                JLT     dtc20_eld_latch
dcode_stamp_store:
                STB     A, 0dch
                RC
dtc20_eld_latch:
                MB      0b1h.7, C
                RC
                JBR     off(00216h).4, dtc21_vtec_solenoid_latch
                JBS     off(00214h).4, dtc21_vtec_solenoid_latch
                JBR     off(0021fh).2, altvtec_ramp_alt
                MOVB    (001ech-00180h)[USP], #032h
                LB      A, (001ebh-00180h)[USP]
                JBS     off(00210h).5, dtc21_vtec_solenoid_latch
altvtec_ramp_common:
                SC
                SJ      dtc21_vtec_solenoid_latch
altvtec_ramp_alt:
                MOVB    (001ebh-00180h)[USP], #032h
                LB      A, (001ech-00180h)[USP]
                JBS     off(00210h).5, altvtec_ramp_common
dtc21_vtec_solenoid_latch:
                MB      0b2h.0, C
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
altvtec_vtps_result:
                RC
dtc22_vtec_pressure_latch:
                MB      0b2h.1, C
                RC
                JBR     off(00227h).6, dtc23_knock_latch
                JBS     off(00217h).5, dtc23_knock_latch
                JBS     off(00214h).6, dtc23_knock_latch
                JBS     off(00233h).6, dtc23_knock_latch
                L       A, off(00212h)
                AND     A, #0c3bch
                JNE     dtc23_knock_latch
                JBS     off(00214h).5, dtc23_knock_latch
                LB      A, off(002c9h)
                JEQ     dtc23_knock_latch
                JBS     off(00233h).7, dtc23_knock_latch
                MB      C, off(00232h).7
dtc23_knock_latch:
                MB      0b2h.2, C
                JBR     off(00216h).5, autotcc_return
                LB      A, ADCR5H
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
autotcc_return: RC
dtc26_code26_latch:
                MB      0b3h.1, C
                JBR     off(00216h).5, automatic_return
                JBS     off(00217h).5, automatic_return
                JBS     off(00215h).0, automatic_return
                JBS     off(00215h).1, automatic_return
                MB      C, 0b3h.1
                JLT     automatic_return
                CMPB    0dbh, #0ffh
                JGE     automatic_p4_check
automatic_return:
                RC
                SJ      dtc25_code25_latch
automatic_p4_check:
                CMPB    0d7h, #0ffh
                JLE     automatic_result
                MB      C, P4.6
                XORB    PSWH, #080h
                SJ      dtc25_code25_latch
automatic_result:
                MB      C, P4.6
dtc25_code25_latch:
                MB      0b3h.0, C
                JBR     off(00219h).3, knockwindow_clear
                JBS     off(00217h).5, knockwindow_clear
                MOV     DP, #003abh
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
                MOV     X1, #tbl_ignmap2_hi
                LB      A, off(00238h)
                CAL     table_interp_lookup
                ADDB    A, #010h
                JGE     knockwindow_check1
                LB      A, #0ffh
knockwindow_check1:
                CMPB    A, off(00237h)
                JGE     knockwindow_clear
knockwindow_check2:
                L       A, (0015ah-00180h)[USP]
                CMP     A, #0b333h
                JGE     knockwindow_set
                JBS     off(00217h).3, knockwindow_check3
                JBS     off(0021eh).4, knockwindow_clear
knockwindow_check3:
                CMP     A, #06000h
                JLE     knockwindow_set
knockwindow_clear:
                RC
                SJ      knockwindow_result
knockwindow_set:
                SC
knockwindow_result:
                MB      0b5h.7, C
                VCAL    3
                JBS     off(00234h).6, knockwindow_next_table
                J       iat_map_correction_chain
knockwindow_next_table:
                MOV     X1, #knockwindow_next_table_tbl_16
                MOV     X2, #ZoneIndexTable2_SetA
                JBS     off(00216h).3, knockwindow_next_table_load_ram0d9
                MOV     X1, #ZoneIndexTable1_SetB
                MOV     X2, #ZoneIndexTable2_SetB
knockwindow_next_table_load_ram0d9:
                LB      A, 0d9h
                VCAL    0
                STB     A, off(00264h)
                MOV     X1, X2
                LB      A, 0d9h
                VCAL    0
                STB     A, off(00266h)
                VCAL    3
                MOV     X1, #tbl_ect_overrun_nor
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, off(00298h)
                MOV     X1, #tbl_ect_vecorrect
                LB      A, 0d9h
                CAL     table_interp_lookup
                MOV     DP, #0037bh
                STB     A, [DP]
                VCAL    3
                CLR     X2
                MOV     X1, #tbl_ect_overrun_int
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, 0037ah[X2]
                MOV     X1, #tbl_knockwindow_9
                JBS     off(00216h).3, knockwindow_next_table_load_ram0d9_2
                MOV     X1, #knockwindow_next_table_tbl_17
knockwindow_next_table_load_ram0d9_2:
                LB      A, 0d9h
                VCAL    0
                STB     A, 0037ch[X2]
                VCAL    3
                LB      A, 0d9h
                MOV     X1, #tbl_ect_fuelcorrect
                MOV     X2, #knockwindow_next_table_tbl_20
                CMPB    A, #023h
                JLT     knockwindow_next_table_store_carry_ram221_bit2
                MOV     X1, #knockwindow_next_table_tbl_19
                MOV     X2, #knockwindow_next_table_tbl_18
knockwindow_next_table_store_carry_ram221_bit2:
                MB      off(00221h).2, C
                CAL     table_interp_lookup
                STB     A, r3
                MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r2
                MOV     off(00254h), er1
                LB      A, 0d9h
                MOV     X1, #tbl_knockwindow_10
                CAL     table_interp_lookup
                STB     A, off(00256h)
                VCAL    3
                MOV     X1, #Overrun_Resume_nor
                MOV     X2, #Overrun_Resume_int
                JBR     off(00216h).3, knockwindow_next_table_load_ram0d9_3
                MOV     X1, #knockwindow_next_table_tbl_13
                MOV     X2, #knockwindow_next_table_tbl_12
knockwindow_next_table_load_ram0d9_3:
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r2
                MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, ACCH
                LB      A, r2
                MOV     (001aah-00180h)[USP], A
                VCAL    3
                MOV     X1, #tbl_knockwindow_4
                MOV     X2, #tbl_knockwindow_3
                JBR     off(00216h).3, knockwindow_next_table_load_ram0d9_4
                MOV     X1, #knockwindow_next_table_tbl_8
                MOV     X2, #knockwindow_next_table_tbl_7
knockwindow_next_table_load_ram0d9_4:
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, r2
                MOV     X1, X2
                LB      A, 0d9h
                CAL     table_interp_lookup
                STB     A, ACCH
                LB      A, r2
                MOV     (001a8h-00180h)[USP], A
                VCAL    3
                LB      A, 0d9h
                MOV     X1, #VEFuelCorrect
                CMPCB   A, 00002h[X1]
                MB      off(00219h).5, C
                CAL     table_interp_lookup
                STB     A, (0017fh-00180h)[USP]
                LB      A, 0d9h
                MOV     X1, #tbl_knockwindow_5
                VCAL    0
                STB     A, (00154h-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #knockwindow_next_table_tbl
                CAL     table_interp_lookup
                STB     A, (0016ah-00180h)[USP]
                LB      A, r2
                MOV     X1, #knockwindow_next_table_tbl_2
                CAL     table_interp_lookup
                STB     A, (0016bh-00180h)[USP]
                LB      A, r2
                MOV     X1, #knockwindow_next_table_tbl_3
                CAL     table_interp_lookup
                STB     A, (0016ch-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #knockwindow_next_table_tbl_4
                CAL     table_interp_lookup
                STB     A, (0016dh-00180h)[USP]
                LB      A, r2
                MOV     X1, #knockwindow_next_table_tbl_14
                CAL     table_interp_lookup
                STB     A, (0016eh-00180h)[USP]
                LB      A, r2
                MOV     X1, #knockwindow_next_table_tbl_5
                CAL     table_interp_lookup
                STB     A, (00181h-00180h)[USP]
                VCAL    3
                J       knockwindow_next_table_load_ram0d9_5
knockwindow_next_table_load_x1:
                MOV     X1, #knockwindow_next_table_tbl_9
                JBS     off(00216h).3, knockwindow_next_table_call_table_interp_lookup
                MOV     X1, #tbl_knockwindow_6
knockwindow_next_table_call_table_interp_lookup:
                CAL     table_interp_lookup
                STB     A, (0018bh-00180h)[USP]
                LB      A, r2
                MOV     X1, #knockwindow_next_table_tbl_10
                JBS     off(00216h).3, knockwindow_next_table_call_table_interp_lookup_2
                MOV     X1, #tbl_knockwindow_7
knockwindow_next_table_call_table_interp_lookup_2:
                CAL     table_interp_lookup
                STB     A, (0018ch-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #knockwindow_next_table_tbl_11
                JBS     off(00216h).3, knockwindow_next_table_call_table_interp_lookup_3
                MOV     X1, #tbl_knockwindow_8
knockwindow_next_table_call_table_interp_lookup_3:
                CAL     table_interp_lookup
                STB     A, (0018dh-00180h)[USP]
                LB      A, r2
                MOV     X1, #Tipintempoffsetnormal
                VCAL    0
                STB     A, (00186h-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                MOV     X1, #Tipintempoffsetinitial
                VCAL    0
                STB     A, (00188h-00180h)[USP]
                LB      A, 0d9h
                MOV     X1, #knockwindow_next_table_tbl_6
                CAL     table_interp_lookup
                STB     A, (0016fh-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                MOV     X1, #knockwindow_next_table_tbl_15
                VCAL    0
                STB     A, (0014eh-00180h)[USP]
                VCAL    3
iat_map_correction_chain:
                LB      A, 0d8h
                MOV     X1, #tbl_iat_correct1
                VCAL    0
                STB     A, off(0027eh)
                LB      A, 0bch
                MOV     X1, #tbl_iat_correct2
                VCAL    1
                STB     A, off(00294h)
                VCAL    3
                LB      A, #070h
                JBS     off(00221h).0, iat_map_correction_chain_cmp_acc
                LB      A, #074h
iat_map_correction_chain_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00221h).0, C
                LB      A, #091h
                JBS     off(00221h).1, iat_map_correction_chain_cmp_acc_2
                LB      A, #09ch
iat_map_correction_chain_cmp_acc_2:
                CMPB    A, off(00237h)
                MB      off(00221h).1, C
                CLRB    A
                JGE     iat_map_correction_chain_store_ram23c
                JBR     off(00221h).0, iat_map_correction_chain_store_ram23c
                JBS     off(00213h).1, iat_map_correction_chain_store_ram23c
                LB      A, 0d8h
                MOV     X1, #iat_map_correction_chain_tbl
                CAL     table_interp_lookup
iat_map_correction_chain_store_ram23c:
                STB     A, off(0023ch)
                MOV     DP, #003d5h
                LB      A, [DP]
                SLLB    A
                MB      off(00220h).4, C
                LB      A, #066h
                JBS     off(00220h).5, iat_map_correction_chain_cmp_acc_3
                LB      A, #073h
iat_map_correction_chain_cmp_acc_3:
                CMPB    A, off(00238h)
                MB      off(00220h).5, C
                LB      A, #09ah
                JBS     off(00220h).6, iat_map_correction_chain_cmp_acc_4
                LB      A, #0a0h
iat_map_correction_chain_cmp_acc_4:
                CMPB    A, off(00238h)
                MB      off(00220h).6, C
                LB      A, #089h
                JBS     off(00220h).7, iat_map_correction_chain_cmp_acc_5
                LB      A, #09ch
iat_map_correction_chain_cmp_acc_5:
                CMPB    A, off(00237h)
                CLRB    A
                MB      off(00220h).7, C
                JGE     div_scale_store
                CLR     A
                MOV     DP, #003d2h
                LB      A, [DP]
                CMPB    A, #0fah
                JGE     div_scale_default
                SUBB    A, #007h
                JGE     div_scale_calc1
                CLRB    A
div_scale_calc1:
                MOVB    r0, #051h
                DIVB
                JBR     off(00220h).5, div_scale_gate_common
                MOVB    r0, #01bh
                LB      A, r1
                DIVB
                JBR     off(00220h).6, div_scale_gate_common
                MOVB    r0, #009h
                LB      A, r1
                DIVB
div_scale_gate_common:
                CMPB    A, #003h
                JLT     div_scale_mul_final
div_scale_default:
                LB      A, #002h
div_scale_mul_final:
                MOVB    r0, #008h
                MULB
                JBR     off(00220h).4, div_scale_store
                VCAL    6
div_scale_store:
                STB     A, off(00245h)
                LB      A, #005h
                MOV     X1, #00004h
                JBS     off(00216h).3, gear_detect_store
                LB      A, #001h
                CLR     X1
                JBS     off(00217h).5, gear_detect_store
                JBS     off(00214h).0, gear_detect_store
                JBR     off(00227h).3, div_scale_store_load_r1
                JBR     off(0022fh).3, div_scale_store_load_ram2e1
                MOVB    off(002e1h), #005h
div_scale_store_load_ram2e1:
                LB      A, off(002e1h)
                JNE     gear_detect_store_load_ram0db
div_scale_store_load_r1:
                MOVB    r1, 0cch
                CLRB    r0
                L       A, 0c4h
                MUL
                L       A, er1
                MOV     DP, #00004h
gear_detect_loop:
                CMPC    A, GearCustom[X1]
                JLT     gear_detect_index_calc
                INC     X1
                INC     X1
                JRNZ    DP, gear_detect_loop
gear_detect_index_calc:
                SRL     X1
                L       A, X1
                LB      A, ACC
                ADDB    A, #001h
gear_detect_store:
                STB     A, off(00251h)
                LCB     A, TipinGear[X1]
                STB     A, off(00252h)
gear_detect_store_load_ram0db:
                LB      A, 0dbh
                MOV     X1, #DwellBattery
                CAL     table_interp_lookup
                STB     A, off(0024dh)
                VCAL    3
                JBS     off(00217h).4, dwell_battery_check2_clear_r0
                LB      A, 0beh
                CMPB    A, #04bh
                JLT     dwell_battery_check2
                SB      (00129h-00180h)[USP].3
dwell_battery_check2:
                CMPB    A, #04bh
                JLT     dwell_battery_check2_clear_r0
                SB      (00129h-00180h)[USP].0
dwell_battery_check2_clear_r0:
                CLRB    r0
                LCB     A, dwell_battery_check2_tbl
                JNE     dwell_battery_check2_goto_4865
                L       A, #011f7h
                JBS     off(00234h).0, dwell_battery_check2_cmp_ram0ce
                L       A, #0113fh
dwell_battery_check2_cmp_ram0ce:
                CMP     0ceh, A
                MB      off(00234h).0, C
                L       A, #tbl_7b31
                JBS     off(00234h).1, dwell_battery_check2_cmp_ram0ce_2
                L       A, #0563ch
dwell_battery_check2_cmp_ram0ce_2:
                CMP     0ceh, A
                MB      off(00234h).1, C
                CLR     X1
                LB      A, #005h
                JBS     off(00234h).2, dwell_battery_check2_addb_acc
                LB      A, #00ah
dwell_battery_check2_addb_acc:
                ADDB    A, 00311h[X1]
                CMPB    A, 0d4h
                MB      off(00234h).2, C
                LB      A, off(00251h)
                SLLB    A
                EXTND
                LC      A, dwell_battery_check2_tbl_3[ACC]
                CMPB    ACC, off(00238h)
                JBS     off(00234h).3, dwell_battery_check2_store_carry_ram234_bit3
                CMPB    ACCH, off(00238h)
dwell_battery_check2_store_carry_ram234_bit3:
                MB      off(00234h).3, C
                LB      A, 003c9h[X1]
                SLLB    A
                JLT     dwell_battery_check2_load_tbl_x1
                MOVB    (001e6h-00180h)[USP], #00ah
                CLRB    A
dwell_battery_check2_store_tbl_x1:
                STB     A, 0031bh[X1]
dwell_battery_check2_goto_4865:
                SJ      dwell_battery_check2_srlb_r0
dwell_battery_check2_load_tbl_x1:
                LB      A, 0031bh[X1]
                JNE     dwell_battery_check2_srlb_r0
                LB      A, (001e6h-00180h)[USP]
                JNE     dwell_battery_check2_srlb_r0
                MB      C, 0b0h.2
                JLT     dwell_battery_check2_srlb_r0
                JBS     off(00212h).6, dwell_battery_check2_srlb_r0
                MB      C, 0b1h.4
                JLT     dwell_battery_check2_srlb_r0
                JBS     off(00214h).0, dwell_battery_check2_srlb_r0
                LB      A, #0ffh
                JBS     off(00234h).0, dwell_battery_check2_store_tbl_x1
                JBR     off(00234h).1, dwell_battery_check2_srlb_r0
                JBR     off(00234h).2, dwell_battery_check2_srlb_r0
                MOVB    r0, #001h
                JBR     off(00234h).3, dwell_battery_check2_srlb_r0
                MOVB    r0, #002h
dwell_battery_check2_srlb_r0:
                SRLB    r0
                MB      off(00234h).4, C
                SRLB    r0
                MB      (0012dh-00180h)[USP].4, C
                LB      A, #0a0h
                JBS     off(00223h).2, dwell_battery_check2_cmp_acc
                LB      A, #0d8h
dwell_battery_check2_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00223h).2, C
                CLR     A
                MOV     X1, #tbl_threshold_223_1
                MOV     X2, #Revlimiters
                JBR     off(0021fh).1, revlimit_table_select
                MOV     X1, #tbl_threshold_223_2
                MOV     X2, #dwell_battery_check2_tbl_2
revlimit_table_select:
                LC      A, 00002h[X1]
                MOV     DP, A
                LC      A, 00002h[X2]
                JBR     off(00217h).5, revlimit_table_select_if_ram214_bit0_set
                MOVB    (001ceh-00180h)[USP], #00ch
                SJ      revlimit_table_select_and_ie
revlimit_table_select_if_ram214_bit0_set:
                JBS     off(00214h).0, revlimit_table_select_and_ie
                LB      A, (001d5h-00180h)[USP]
                JNE     revlimit_table_select_load_ram0bc
                MOVB    (001d5h-00180h)[USP], #014h
                JBS     off(00212h).5, revlimit_table_select_if_ram223_bit2_clr
                CMPB    0d9h, #044h
                JGE     revlimit_table_select_load_stk
revlimit_table_select_if_ram223_bit2_clr:
                JBR     off(00223h).2, revlimit_table_select_load_stk
                LB      A, (001ceh-00180h)[USP]
                JNE     callhelper_sub37_clamp_to_er0
                L       A, (001a6h-00180h)[USP]
                CAL     add24_clamp_neg1
                MOV     DP, A
                L       A, (001a4h-00180h)[USP]
                MOV     X1, X2
                CAL     add24_clamp_neg1
                SJ      revlimit_table_select_and_ie
revlimit_table_select_load_stk:
                MOVB    (001ceh-00180h)[USP], #00ch
callhelper_sub37_clamp_to_er0:
                LC      A, 00002h[X1]
                MOV     er0, A
                L       A, (001a6h-00180h)[USP]
                CAL     sub37_clamp_to_er0
                MOV     DP, A
                LC      A, 00002h[X2]
                ST      A, er0
                L       A, (001a4h-00180h)[USP]
                CAL     sub37_clamp_to_er0
revlimit_table_select_and_ie:
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, (001a4h-00180h)[USP]
                L       A, DP
                ST      A, (001a6h-00180h)[USP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
revlimit_table_select_load_ram0bc:
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_warm3
                VCAL    1
                STB     A, (001ach-00180h)[USP]
                VCAL    3
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_warm2
                CAL     table_interp_lookup
                STB     A, (00169h-00180h)[USP]
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_cold4
                VCAL    1
                STB     A, (00183h-00180h)[USP]
                LB      A, 0bch
                MOV     X1, #tbl_revlimit_warm1
                VCAL    1
                STB     A, (00180h-00180h)[USP]
                LB      A, 0bch
                MOV     X1, #revlimit_table_select_tbl
                VCAL    1
                STB     A, (00199h-00180h)[USP]
                VCAL    3
                MOV     X1, #tbl_revlimit_cold1
                CMPB    0cch, #00fh
                JLT     iat_table_select
                MOV     X1, #tbl_revlimit_cold2
                CMPB    0cch, #00fh
                JLT     iat_table_select
                MOV     X1, #tbl_revlimit_cold3
iat_table_select:
                LB      A, 0d8h
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
                STB     A, (0015eh-00180h)[USP]
                VCAL    3
                CLR     A
                LB      A, #0aah
                JBS     off(00223h).4, iat_table_select_cmp_acc
                LB      A, #0b0h
iat_table_select_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00223h).4, C
                LCB     A, fuelmap_base_lookup_tbl
                SRLB    A
                SRLB    A
                CLRB    r2
                MOV     DP, #003cah
                LB      A, [DP]
                JLT     knock_retard_check
                CMPB    A, #0f0h
                JLT     knock_div_calc1
                LB      A, #076h
knock_div_calc1:
                MOVB    r0, #030h
                DIVB
                JBS     off(00223h).4, knock_table_index
                SRLB    A
                LB      A, r1
                JGE     knock_div_calc2
                LB      A, #02fh
                SUBB    A, r1
knock_div_calc2:
                MOVB    r0, #009h
                DIVB
                ADDB    A, #006h
knock_table_index:
                SLLB    A
                EXTND
                LC      A, knock_table_index_tbl[ACC]
                SJ      knock_result_store
knock_retard_check:
                ADDB    A, #080h
                STB     A, r2
                L       A, #08000h
knock_result_store:
                ST      A, (00162h-00180h)[USP]
                MOVB    off(00244h), r2
                MOV     DP, #003d4h
                LB      A, [DP]
                JBS     off(00219h).3, knock_result_store_addb_acc
                LB      A, 0e3h
knock_result_store_addb_acc:
                ADDB    A, #080h
                STB     A, r0
                LCB     A, idle_init_start_tbl
                JEQ     to_knock_div_calc3
                LCB     A, fuelmap_base_lookup_tbl
                SRLB    A
                CLRB    A
                XCHGB   A, r0
                JLT     to_knock_div_calc3
                CLRB    A
to_knock_div_calc3:
                STB     A, (0013fh-00180h)[USP]
                LB      A, r0
                STB     A, (00149h-00180h)[USP]
                CLRB    A
                MOV     DP, #003d3h
                LCB     A, fuelmap_base_lookup_tbl
                SRLB    A
                SRLB    A
                SRLB    A
                JGE     to_knock_div_calc3_srlb_acc
                LB      A, [DP]
                ADDB    A, #080h
                CLR     er0
                SJ      to_knock_div_calc3_store_ram29d
to_knock_div_calc3_srlb_acc:
                SRLB    A
                JGE     to_knock_div_calc3_clear_acc
                LB      A, [DP]
                MOVB    r0, #080h
                MULB
                L       A, ACC
                ADD     A, #0c000h
                ST      A, er0
                CLRB    A
to_knock_div_calc3_store_ram29d:
                STB     A, off(0029dh)
                MOV     off(00286h), er0
                CLR     A
                LB      A, #076h
                SJ      knock_div_calc3
to_knock_div_calc3_clear_acc:
                CLRB    A
                STB     A, off(0029dh)
                EXTND
                ST      A, off(00286h)
                LB      A, [DP]
                CMPB    A, #0f0h
                JLT     knock_div_calc3
                LB      A, #076h
knock_div_calc3:
                MOVB    r0, #030h
                DIVB
                STB     A, r2
                SRLB    A
                LB      A, r1
                JGE     knock_div_calc4
                LB      A, #02fh
                SUBB    A, r1
knock_div_calc4:
                MOVB    r0, #009h
                DIVB
                ADDB    A, #006h
                SLLB    A
                EXTND
                MOV     X1, #tbl_knock_div
                JBR     off(00216h).3, knock_div_calc4_if_ram216_bit0_set
                MOV     X1, #knock_div_calc4_tbl
knock_div_calc4_if_ram216_bit0_set:
                JBS     off(00216h).0, knock_table2d_lookup
                ADD     X1, #00018h
knock_table2d_lookup:
                MOV     X2, X1
                ADD     X1, A
                LC      A, [X1]
                ST      A, er0
                LB      A, r2
                SLLB    A
                EXTND
                ADD     X2, A
                LC      A, [X2]
                AND     IE, #002a0h
                ANDB    PSWH, #0feh
                ST      A, (00178h-00180h)[USP]
                L       A, er0
                ST      A, (0017ah-00180h)[USP]
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                CLR     A
                MOV     DP, #003cch
                LB      A, [DP]
                L       A, ACC
                ADD     A, #0001fh
                SLL     A
                SLL     A
                LB      A, ACCH
                EXTND
                LCB     A, knock_table2d_lookup_tbl_2[ACC]
                MOV     DP, #00392h
                LB      A, ACC
                STB     A, [DP]
                LB      A, 0dbh
                MOV     X1, #knock_table2d_lookup_tbl
                VCAL    0
                STB     A, (00144h-00180h)[USP]
                VCAL    3
                MOV     DP, #003c6h
                LB      A, [DP]
                STB     A, 0dah
                JBR     off(00219h).3, injidx_gate2
                MOV     DP, #003abh
                LB      A, [DP]
                CMPB    A, #031h
                JNE     injidx_gate1
                SB      off(00223h).3
                SB      off(00219h).0
                RB      off(00223h).1
                SJ      injidx_flag_set
injidx_gate1:   JBR     off(00223h).3, injidx_gate3
injidx_gate2:   RB      off(00223h).3
injidx_flag_clear:
                RB      off(00219h).0
                SB      off(00223h).1
injidx_flag_set:
                SB      off(00223h).0
                J       vss_ect_stamp
injidx_gate3:   JBS     off(00219h).4, injidx_flag_clear
                JBS     off(0021dh).4, injidx_flag_clear
                LB      A, off(002cdh)
                JEQ     injidx_gate4
                RB      off(00219h).0
                RB      off(00223h).1
injidx_flag_set2:
                RB      off(00223h).0
                MOVB    off(002ceh), #064h
                SJ      vss_ect_stamp
injidx_gate4:   JBS     off(00217h).5, injidx_flag_set2
                JBS     off(00219h).0, vss_ect_gate
                JBR     off(00223h).1, injidx_gate6
                JBS     off(00216h).6, injidx_gate5
                JBS     off(00218h).0, vss_ect_gate
injidx_gate5:   JBR     off(0021dh).2, vss_ect_gate
                RB      off(00219h).0
                RB      off(00223h).1
                SB      off(00223h).0
injidx_gate6:   JBR     off(00216h).6, closeloopnarrow_check
                JBS     off(00219h).0, closeloopnarrow_check
                JBS     off(00223h).1, closeloopnarrow_check
                JBS     off(00223h).0, closeloopnarrow_check
                JBR     off(00219h).2, injidx_stamp_c2
                JBR     off(00219h).1, injidx_stamp_c2
                JBS     off(0021dh).2, injidx_c2_check
injidx_stamp_c2:
                MOVB    off(002ceh), #064h
                SJ      closeloopnarrow_check
injidx_c2_check:
                LB      A, off(002ceh)
                JNE     closeloopnarrow_check
                LB      A, #02eh
                SJ      closeloopnarrow_result
closeloopnarrow_check:
                LB      A, #01ah
                JBS     off(00216h).0, closeloopnarrow_result
                LB      A, #01ah
closeloopnarrow_result:
                CMPB    A, 0dah
                JLT     vss_ect_gate
                SB      off(00219h).0
vss_ect_gate:   CMPB    0d9h, #028h
                JGE     vss_ect_stamp
                CMPB    0cch, #005h
                JGE     vss_ect_stamp
                CMPB    off(00238h), #080h
                JLT     vss_ect_stamp
                JBR     off(0021dh).2, vss_ect_stamp
                LB      A, off(002b5h)
                JNE     idle_state_defaults
                SB      off(00219h).0
                RB      off(00223h).1
                SJ      idle_state_defaults
vss_ect_stamp:  MOVB    off(002b5h), #004h
idle_state_defaults:
                MOVB    r0, #005h
                MOVB    r1, #032h
                MOVB    r2, #032h
                MOVB    r3, #01bh
                JBS     off(00216h).0, idle_state_defaults_if_ram21d_bit1_clr
                MOVB    r3, #01bh
idle_state_defaults_if_ram21d_bit1_clr:
                JBR     off(0021dh).1, idle_stage_alt_start
                JBR     off(00218h).0, idle_stage_alt_start
                MOVB    off(002cbh), r1
                MOVB    off(002cch), r2
                JBR     off(00219h).0, idle_stage_b7_store
                JBS     off(0021eh).4, idle_state_defaults_goto_78d9
                L       A, (0015ah-00180h)[USP]
                CMP     A, #0bc15h
                JGE     idle_state_defaults_goto_78d9
                CMP     A, #05e20h
                JLE     idle_state_defaults_goto_78d9
                LB      A, r3
                CMPB    A, 0dah
                JLT     idle_stage_b7_load
idle_stage_b7_store:
                MOVB    off(002b6h), r0
idle_stage_b7_load:
                LB      A, off(002b6h)
                SJ      idle_stage_c0_load_goto_78e6
idle_stage_alt_start:
                MOVB    off(002b6h), r0
                JBR     off(0021ch).2, idle_stage_c0_start
                MOVB    off(002cch), r2
                JBR     off(00219h).0, idle_stage_bf_store
                LB      A, r3
                CMPB    A, 0dah
                JLT     idle_stage_bf_load
idle_stage_bf_store:
                MOVB    off(002cbh), r1
idle_stage_bf_load:
                LB      A, off(002cbh)
                SJ      idle_stage_c0_load_goto_78e6
idle_stage_c0_start:
                MOVB    off(002cbh), r1
                JBR     off(00219h).0, idle_stage_c0_store
                JBR     off(0021ch).6, idle_stage_c0_load
idle_stage_c0_store:
                MOVB    off(002cch), r2
idle_stage_c0_load:
                LB      A, off(002cch)
idle_stage_c0_load_goto_78e6:
                J       idle_stage_c0_load_load_ram2ef
idle_state_defaults_goto_78d9:
                J       idle_state_defaults_cmp_ram0da
                DW  00000h
gio_fuelpump_dispatch:
                VCAL    3
                RC
                LB      A, off(002d1h)
                JNE     fuelpump_relay_drive
                JBS     off(00211h).0, fuelpump_relay_drive
                MB      C, off(00217h).4
fuelpump_relay_drive:
                MB      P0.7, C
                JBS     off(00210h).7, fuelpump_done
                JBS     off(00218h).6, fuelpump_state_active
                MOV     DP, #003d1h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     fuelpump_gate4
                CMPB    A, #0fch
                JGE     fuelpump_gate4_rom_load_tbl_60fb
fuelpump_gate4: JBS     off(00230h).6, fuelpump_state_active
fuelpump_gate4_rom_load_tbl_60fb:
                LCB     A, idle_init_start_tbl
                JEQ     fuelpump_gate4_if_ram211_bit0_set
                LB      A, 0afh
                JNE     fuelpump_state_active
fuelpump_gate4_if_ram211_bit0_set:
                JBS     off(00211h).0, fuelpump_state_store
                JBS     off(00217h).4, fuelpump_state_check
fuelpump_state_store:
                STB     A, off(002d1h)
fuelpump_state_check:
                RC
                LB      A, off(002d1h)
                JEQ     fuelpump_state_active_store_carry_p1_bit4
fuelpump_state_active:
                SC
fuelpump_state_active_store_carry_p1_bit4:
                MB      P1.4, C
fuelpump_done:  LB      A, #07eh
                JBS     off(00226h).0, rpm_threshold_226_0
                LB      A, #082h
rpm_threshold_226_0:
                CMPB    A, 0cch
                MB      off(00226h).0, C
                LB      A, #010h
                JBS     off(00226h).1, rpm_threshold_226_1
                LB      A, #020h
rpm_threshold_226_1:
                CMPB    A, 0cch
                MB      off(00226h).1, C
                LB      A, #033h
                JBS     off(00226h).2, tps_threshold_226_2
                LB      A, #080h
tps_threshold_226_2:
                CMPB    A, 0d1h
                MB      off(00226h).2, C
                LB      A, #0c8h
                JBS     off(00226h).3, tps_threshold_226_2_cmp_acc
                LB      A, #0d0h
tps_threshold_226_2_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00226h).3, C
                L       A, #00ea6h
                JBS     off(00226h).5, accut_rpm_gate
                L       A, #00c35h
accut_rpm_gate: CMP     0c4h, A
                MB      off(00226h).5, C
                CMPB    0f3h, #014h
                JLT     accut_reset_c3
                JBS     off(00218h).7, accut_alt_gate
                CMPB    0d9h, #015h
                JGE     accut_gate2
                JBR     off(00226h).0, accut_gate2
                JBS     off(00226h).3, accut_reset_f7
accut_gate2:    JBS     off(00226h).2, accut_check_c3
                CLRB    A
                JBS     off(00226h).1, accut_store_c3
                LB      A, #032h
accut_store_c3: STB     A, off(002cfh)
                SJ      accut_alt_gate
accut_check_c3: LB      A, off(002cfh)
                JNE     accut_reset_f7
accut_alt_gate: JBS     off(00226h).5, accut_gio_check
                RB      off(00226h).4
                SJ      accut_result_common
accut_gio_check:
                JBR     off(00211h).2, accut_common
                SB      off(00226h).4
                LB      A, off(002c4h)
                JNE     accut_result_common
                MOVB    off(002c5h), #01eh
accut_delay_check:
                SB      off(0021bh).0
                RC
                SJ      accut_output_drive
accut_reset_c3: CLRB    off(002cfh)
accut_reset_f7: CLRB    off(002c5h)
accut_common:   RB      off(00226h).4
                LB      A, off(002c5h)
                JNE     accut_delay_check
                MOVB    off(002c4h), #023h
accut_result_common:
                RB      off(0021bh).0
                SC
accut_output_drive:
                MB      P0.0, C
                J       accut_output_drive_load_imm
accut_output_drive_if_ram212_bit5_set:
                JBS     off(00212h).5, accut_output_drive_goto_purge_gate2
                CMPB    0d9h, #035h
                JGE     purge_result_clear
accut_output_drive_goto_purge_gate2:
                J       purge_gate2
                DB  0FFh,0FFh,0FFh
purge_counter_check:
                CMP     (001b8h-00180h)[USP], #005dch
                JLT     purge_result_clear
                CMPB    off(002b3h), #005h
                JNE     purge_result_set
                CMPB    off(002d2h), #019h
                JLT     purge_result_clear
purge_result_set:
                SC
                SJ      purge_invert_result
purge_result_clear:
                RC
purge_invert_result:
                MB      P0.1, C
                VCAL    3
                LB      A, #046h
                MOVB    r1, #046h
                JBS     off(00224h).0, purge_invert_result_if_ram216_bit3_set
                LB      A, #053h
                MOVB    r1, #053h
purge_invert_result_if_ram216_bit3_set:
                JBS     off(00216h).3, purge_invert_result_cmp_acc
                LB      A, r1
purge_invert_result_cmp_acc:
                CMPB    A, off(00238h)
                MB      off(00224h).0, C
                LB      A, #090h
                JBS     off(00224h).1, purge_invert_result_cmp_acc_2
                LB      A, #0a0h
purge_invert_result_cmp_acc_2:
                CMPB    A, off(00238h)
                MB      off(00224h).1, C
                MOVB    r0, 0cch
                LB      A, #00ch
                JBS     off(00224h).2, vss_band_224_2_check
                LB      A, #00fh
vss_band_224_2_check:
                CMPB    A, r0
                MB      off(00224h).2, C
                LB      A, #049h
                JBS     off(00224h).3, vss_band_224_3_check
                LB      A, #04bh
vss_band_224_3_check:
                CMPB    A, r0
                MB      off(00224h).3, C
                LB      A, #02dh
                JBS     off(00224h).4, vss_band_224_4_check
                LB      A, #02fh
vss_band_224_4_check:
                CMPB    A, r0
                MB      off(00224h).4, C
                LB      A, #088h
                JBS     off(00224h).5, vss_band_224_5_check
                LB      A, #080h
vss_band_224_5_check:
                CMPB    0dfh, A
                MB      off(00224h).5, C
                LB      A, #029h
                JBS     off(00224h).6, ect_threshold_224_6
                LB      A, #026h
ect_threshold_224_6:
                CMPB    0d9h, A
                MB      off(00224h).6, C
                SB      PSWL.4
                JBR     off(00217h).6, state225_1_set
                JBS     off(00217h).4, state225_1_set
                LCB     A, ect_threshold_224_6_tbl
                JNE     ect_threshold_224_6_if_ram218_bit7_clr
                JBS     off(00212h).5, ect_threshold_224_6_clear_pswl_bit4
                MOV     DP, #003d0h
                CMPB    [DP], #0ffh
                JLT     ect_threshold_224_6_cmp_dp_ind
                CLRB    off(002bdh)
                SJ      ect_threshold_224_6_if_ram218_bit7_clr
ect_threshold_224_6_cmp_dp_ind:
                CMPB    [DP], #0ffh
                JGE     ect_threshold_224_6_load_ram2bd
                MOVB    off(002bdh), #0ffh
ect_threshold_224_6_load_ram2bd:
                LB      A, off(002bdh)
                JEQ     ect_threshold_224_6_if_ram218_bit7_clr
ect_threshold_224_6_clear_pswl_bit4:
                RB      PSWL.4
ect_threshold_224_6_if_ram218_bit7_clr:
                JBR     off(00218h).7, state_dispatch2
state225_1_set: SB      off(00225h).1
                J       state_result_clear5
state_dispatch2:
                JBR     off(00224h).2, state_cce_set2b
                JBS     off(0021ch).2, state_dispatch3
                JBR     off(00216h).3, state_cce_set2b
                JBR     off(0021eh).1, state_cce_set2b
state_dispatch3:
                JBR     off(00224h).0, state_cce_set2b
                JBS     off(00224h).4, state_dispatch3_load_ram2d5
                JBR     off(00224h).6, state_dispatch3_load_ram2d5
                JBS     off(00225h).0, state_dispatch3_load_ram2d5
                LB      A, off(002d5h)
                JNE     state_cce_set2b_load_ram2d6
                MOVB    off(002d6h), #003h
state_cce_set2b_clear_pswl_bit4:
                RB      PSWL.4
                SJ      state_ccc_set9
state_dispatch3_load_ram2d5:
                MOVB    off(002d5h), #002h
state_ccc_set9: MOVB    off(002d3h), #005h
                SJ      state_2ba_reset
state_cce_set2b:
                MOVB    off(002d5h), #002h
state_cce_set2b_load_ram2d6:
                LB      A, off(002d6h)
                JNE     state_cce_set2b_clear_pswl_bit4
                JBR     off(00222h).6, state_cce_set2b_load_ram2d3
                RB      PSWL.4
state_cce_set2b_load_ram2d3:
                LB      A, off(002d3h)
                JEQ     state_ccc_check
                JBR     off(00225h).0, state_dispatch4
                SJ      state_2ba_reset
state_ccc_check:
                JBR     off(00224h).5, state_ccc_check_if_ram216_bit3_clr
                MOVB    off(002d4h), #014h
to_state_2ba_reset:
                SB      off(00225h).0
                SJ      state_2ba_reset
state_ccc_check_if_ram216_bit3_clr:
                JBR     off(00216h).3, state_ccc_check_load_ram2d4
                JBS     off(00211h).5, to_state_2ba_reset
state_ccc_check_load_ram2d4:
                LB      A, off(002d4h)
                JNE     state_2ba_reset
                JBS     off(00224h).2, state_225_0_clear
                JBS     off(00225h).0, state_2ba_reset
state_225_0_clear:
                RB      off(00225h).0
state_dispatch4:
                JBS     off(00224h).3, state_225_1_check
                JBS     off(00224h).1, state_225_1_check
                CMPB    0d9h, #029h
                JGE     state_225_1_check
                CMPB    0d8h, #0a9h
                JGE     state_225_1_check
                JBS     off(00211h).2, state_225_1_check
                LB      A, off(002b9h)
                JEQ     state_225_1_check
                RB      off(00225h).1
state_result_set5:
                SB      P0.2
                SJ      altc2_normal_drive
state_2ba_reset:
                MOVB    off(002b9h), #016h
state_225_1_check:
                JBS     off(00225h).1, state_225_1_check_load_ram2d7
                SB      off(00225h).1
                MOVB    off(002d7h), #003h
state_225_1_check_load_ram2d7:
                LB      A, off(002d7h)
                JNE     state_result_set5
                CMPB    off(0029bh), #000h
                JGT     state_result_set5
state_result_clear5:
                RB      P0.2
altc2_normal_drive:
                MB      C, PSWL.4
                MB      P0.3, C
                VCAL    3
                JBS     off(00227h).3, altc_normal_drive_if_ram219_bit3_clr
                JBS     off(00217h).3, altc_normal_drive_if_ram219_bit3_clr
                JBR     off(00216h).3, altc_normal_drive_if_ram219_bit3_clr
                MOVB    r0, #0feh
                JBS     off(00226h).7, altc2_normal_drive_load_adcr7h
                MOVB    r0, #0ffh
altc2_normal_drive_load_adcr7h:
                LB      A, ADCR7H
                CMPB    r0, A
                MB      off(00226h).7, C
                JBR     off(00211h).4, altc2_normal_drive_set_carry
                JBS     off(00212h).6, altc_normal_drive
                CMPB    A, #0fch
                JGE     altc_normal_drive
                CMPB    A, #005h
                JLT     altc_normal_drive
                JBR     off(00226h).7, altc_normal_drive
altc2_normal_drive_set_carry:
                SC
                SJ      altc_normal_drive_store_carry_p0_bit5
altc_normal_drive:
                RC
altc_normal_drive_store_carry_p0_bit5:
                MB      P0.5, C
altc_normal_drive_if_ram219_bit3_clr:
                JBR     off(00219h).3, flags_b8_2_set
                JBR     off(00216h).6, flags_b8_2_set
                JBR     off(00217h).4, altc_condition_check
flags_b8_2_set: SB      0b8h.2
                RB      0b3h.2
                SJ      gio_p1_2_check
altc_condition_check:
                JBS     off(00215h).2, gio_p1_2_check
                JBS     off(00212h).5, gio_p1_2_check
                MB      C, 0b0h.1
                JLT     gio_p1_2_check
                CMPB    0d9h, #0ffh
                JGE     gio_p1_2_check
                CMPB    0dbh, #0ffh
                JLT     flags_219_2_store
gio_p1_2_check: RC
                SB      P1.2
flags_219_2_store:
                MB      off(00219h).2, C
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
                JGE     flags_219_2_store_load_ram2c8
state_2fb_reset:
                MOVB    off(002c8h), #0ffh
                SJ      state_21a_7_dispatch
flags_219_2_store_load_ram2c8:
                LB      A, off(002c8h)
                JNE     state_21a_7_dispatch
                SB      off(0021ah).6
state_21a_7_dispatch:
                JBS     off(0021ah).7, state_21a_7_dispatch3
                JBS     off(00217h).5, state_21a_7_dispatch_if_ram213_bit0_set
                JBS     off(0021ah).6, state_21a_7_dispatch_if_ram224_bit7_clr
state_21a_7_dispatch_if_ram213_bit0_set:
                JBS     off(00213h).0, state_21a_7_set
state_21a_7_dispatch_load_ram2ea:
                MOVB    off(002eah), #0ffh
                SJ      state_21a_7_dispatch3
state_21a_7_dispatch_if_ram224_bit7_clr:
                JBR     off(00224h).7, state_21a_7_dispatch_load_ram2ea
                JBS     off(0021dh).4, state_21a_7_dispatch_load_ram2ea
                LB      A, off(002eah)
                JNE     state_21a_7_dispatch3
state_21a_7_set:
                SB      off(0021ah).7
state_21a_7_dispatch3:
                JBS     off(0021ah).7, state_21a_7_dispatch2
                JBR     off(0021ah).6, state_2de_reset
                JBS     off(00217h).5, state_2de_reset
                JBS     off(00215h).1, altc_p46_check
                MB      C, 0b3h.1
                JGE     state_2de_reset
altc_p46_check: MB      C, P4.6
                JGE     state_2de_reset
                JBS     off(00218h).0, altc_p46_check_load_ram2eb
                JBS     off(0021eh).2, state_2de_reset
altc_p46_check_load_ram2eb:
                LB      A, off(002ebh)
                JNE     state_21a_7_dispatch2
                SB      off(0021ah).7
                SJ      state_21a_7_dispatch2
state_2de_reset:
                MOVB    off(002ebh), #0ffh
state_21a_7_dispatch2:
                JBS     off(0021ah).7, state_21a_7_dispatch2_load_r0
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
state_dc_check2:
                CMPB    A, #0ffh
                JGT     state_dc_check2_load_ram2ec
state_2df_reset:
                MOVB    off(002ech), #0ffh
                SJ      state_21a_7_dispatch2_load_r0
state_dc_check2_load_ram2ec:
                LB      A, off(002ech)
                JNE     state_21a_7_dispatch2_load_r0
                SB      off(0021ah).7
state_21a_7_dispatch2_load_r0:
                MOVB    r0, #004h
                MOV     DP, #tbl_map_sign
                LB      A, 0d9h
state_21a_7_dispatch2_dec_dp:
                DEC     DP
                DECB    r0
                JEQ     state_21a_7_dispatch2_load_ram0fa
                CMPCB   A, [DP]
                JGE     state_21a_7_dispatch2_dec_dp
state_21a_7_dispatch2_load_ram0fa:
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, off(00233h)
                ANDB    A, #0fch
                ORB     A, r0
                STB     A, off(00233h)
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                CMPB    0d8h, #0ffh
                MB      off(00233h).2, C
                VCAL    3
                JBR     off(00227h).3, state_21a_7_dispatch2_goto_5102
                JBS     off(00216h).3, state_21a_7_dispatch2_goto_50fe
                RB      off(0022eh).4
                MB      C, off(00211h).5
                MB      off(0022eh).4, C
                JEQ     state_21a_7_dispatch2_store_carry_ram22f_bit3
                XORB    PSWH, #080h
state_21a_7_dispatch2_store_carry_ram22f_bit3:
                MB      off(0022fh).3, C
                LB      A, off(002d1h)
                JNE     state_21a_7_dispatch2_goto_50f8
                J       state_21a_7_dispatch2_if_ram235_bit3_set
state_21a_7_dispatch2_goto_50fe:
                J       state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_goto_50f8:
                J       state_21a_7_dispatch2_clear_carry
state_21a_7_dispatch2_goto_5102:
                J       state_21a_7_dispatch2_vcal_3
state_21a_7_dispatch2_load_x1:
                MOV     X1, #state_21a_7_dispatch2_tbl
                MOV     DP, #0022dh
                SB      PSWL.4
                MOV     er0, #00400h
                MOVB    r2, 0beh
                CAL     timer_or_counter_helper
                RB      PSWL.4
                MOVB    r1, #001h
                MOVB    r2, off(00237h)
                CAL     timer_or_counter_helper
                MOVB    r1, #001h
                MOVB    r2, 0d1h
                CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, off(00238h)
                CAL     timer_or_counter_helper
                MOV     DP, #0022eh
                MOV     er0, #00300h
                MOVB    r2, 0cch
                CAL     timer_or_counter_helper
                CMPB    0cch, #0ffh
                JLT     state_21a_7_dispatch2_load_dp
                CMPB    off(00238h), #0ffh
                JLT     state_21a_7_dispatch2_load_dp
                MOV     DP, #0038ah
                CLRB    A
                JBS     off(0022fh).3, state_21a_7_dispatch2_store_dp_ind
                LB      A, off(00251h)
                INC     DP
                XCHGB   A, [DP]
                CMPB    A, [DP]
                JEQ     state_21a_7_dispatch2_load_dp
                DEC     DP
                LB      A, #0ffh
                INCB    [DP]
                CMPB    A, [DP]
                JGE     state_21a_7_dispatch2_load_dp
state_21a_7_dispatch2_store_dp_ind:
                STB     A, [DP]
                MB      off(0022eh).3, C
state_21a_7_dispatch2_load_dp:
                MOV     DP, #0038dh
                LB      A, [DP]
                CMPB    A, #0ffh
                MB      off(0022eh).5, C
                JGE     state_21a_7_dispatch2_load_imm
                JBS     off(0022eh).6, state_21a_7_dispatch2_store_carry_ram22e_bit7
state_21a_7_dispatch2_load_imm:
                LB      A, #0ffh
                CMPB    A, 0beh
                MB      off(0022eh).6, C
                JLT     state_21a_7_dispatch2_load_ram251
state_21a_7_dispatch2_store_carry_ram22e_bit7:
                MB      off(0022eh).7, C
state_21a_7_dispatch2_load_ram251:
                LB      A, off(00251h)
                STB     A, r0
                JBS     off(0022dh).1, state_21a_7_dispatch2_load_ram2d8
                MOVB    off(002d8h), #0ffh
state_21a_7_dispatch2_load_ram2d8:
                LB      A, off(002d8h)
                JNE     state_21a_7_dispatch2_if_ram22f_bit1_set_2
                JBS     off(0022fh).2, state_21a_7_dispatch2_if_ram22f_bit1_set
                CMPB    r0, #003h
                JNE     state_21a_7_dispatch2_if_ram22f_bit1_set
                SB      off(0022fh).2
state_21a_7_dispatch2_if_ram22f_bit1_set:
                JBS     off(0022fh).1, state_21a_7_dispatch2_if_ram22f_bit0_set
                CMPB    r0, #002h
                JNE     state_21a_7_dispatch2_if_ram22f_bit2_clr
                SB      off(0022fh).1
                SJ      state_21a_7_dispatch2_if_ram22f_bit0_set
state_21a_7_dispatch2_if_ram22f_bit1_set_2:
                JBS     off(0022fh).1, state_21a_7_dispatch2_if_ram22f_bit0_set
state_21a_7_dispatch2_if_ram22f_bit2_clr:
                JBR     off(0022fh).2, state_21a_7_dispatch2_andb_ram22f
state_21a_7_dispatch2_if_ram22f_bit0_set:
                JBS     off(0022fh).0, state_21a_7_dispatch2_cmp_r0
                CMPB    r0, #003h
                JGE     state_21a_7_dispatch2_load_ram2d9
                MOVB    off(002d9h), #0ffh
state_21a_7_dispatch2_load_ram2d9:
                LB      A, off(002d9h)
                JNE     state_21a_7_dispatch2_load_ram2da
                SB      off(0022fh).0
state_21a_7_dispatch2_cmp_r0:
                CMPB    r0, #002h
                JEQ     state_21a_7_dispatch2_load_ram2da_2
state_21a_7_dispatch2_load_ram2da:
                MOVB    off(002dah), #0ffh
state_21a_7_dispatch2_load_ram2da_2:
                LB      A, off(002dah)
                JEQ     state_21a_7_dispatch2_andb_ram22f
                JBS     off(0022eh).0, state_21a_7_dispatch2_clear_x1
state_21a_7_dispatch2_andb_ram22f:
                ANDB    off(0022fh), #0f8h
state_21a_7_dispatch2_clear_x1:
                CLR     X1
                CMPB    0d9h, #0ffh
                JLT     state_21a_7_dispatch2_load_x1_2
                CMPB    0d8h, #0ffh
                JGE     state_21a_7_dispatch2_load_r0_2
                JBR     off(0022dh).0, state_21a_7_dispatch2_load_ram2db
                MOVB    off(002dbh), #0ffh
state_21a_7_dispatch2_load_ram2db:
                LB      A, off(002dbh)
                MOV     X1, #00004h
                JNE     state_21a_7_dispatch2_load_r0_2
                SLL     X1
                JBR     off(00216h).0, state_21a_7_dispatch2_load_r0_2
                JBS     off(00226h).6, state_21a_7_dispatch2_load_r0_2
                MOV     X1, #0000ch
                SJ      state_21a_7_dispatch2_load_r0_2
state_21a_7_dispatch2_load_x1_2:
                MOV     X1, #00004h
                LB      A, #0ffh
                JBR     off(00226h).6, state_21a_7_dispatch2_if_ram22e_bit7_set
                JBS     off(0022fh).4, state_21a_7_dispatch2_if_ram22e_bit7_set
                JBR     off(0022eh).2, state_21a_7_dispatch2_if_ram22e_bit7_clr
                JBS     off(0022fh).5, state_21a_7_dispatch2_if_ram22e_bit7_clr
                SB      off(0022fh).5
                JBS     off(0022dh).0, state_21a_7_dispatch2_if_ram22e_bit7_clr
                SB      off(0022fh).4
state_21a_7_dispatch2_if_ram22e_bit7_clr:
                JBR     off(0022eh).7, state_21a_7_dispatch2_load_r0_2
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2db_2
                STB     A, off(002dbh)
state_21a_7_dispatch2_load_ram2db_2:
                LB      A, off(002dbh)
                JNE     state_21a_7_dispatch2_load_r0_2
                MOV     X1, #00010h
                SJ      state_21a_7_dispatch2_load_r0_2
state_21a_7_dispatch2_if_ram22e_bit7_set:
                JBS     off(0022eh).7, state_21a_7_dispatch2_if_ram22d_bit2_clr
                JBR     off(00216h).0, state_21a_7_dispatch2_load_r0_2
                MOV     X1, #00018h
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2db_3
                STB     A, off(002dbh)
state_21a_7_dispatch2_load_ram2db_3:
                LB      A, off(002dbh)
                JEQ     state_21a_7_dispatch2_load_r0_2
state_21a_7_dispatch2_load_x1_3:
                MOV     X1, #00014h
                SJ      state_21a_7_dispatch2_load_r0_2
state_21a_7_dispatch2_if_ram22d_bit2_clr:
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2db_4
                STB     A, off(002dbh)
state_21a_7_dispatch2_load_ram2db_4:
                LB      A, off(002dbh)
                JEQ     state_21a_7_dispatch2_load_x1_4
                JBS     off(00216h).0, state_21a_7_dispatch2_load_x1_3
                SJ      state_21a_7_dispatch2_load_r0_2
state_21a_7_dispatch2_load_x1_4:
                MOV     X1, #0001ch
                JBS     off(00216h).0, state_21a_7_dispatch2_load_r0_2
                MOV     X1, #00022h
state_21a_7_dispatch2_load_r0_2:
                LB      A, r0
                JEQ     state_21a_7_dispatch2_extnd_acc
                CMPB    A, #005h
                JEQ     state_21a_7_dispatch2_load_ram2dc
                SUBB    A, #001h
state_21a_7_dispatch2_extnd_acc:
                EXTND
                ADD     A, X1
                CMP     X1, #0001ch
                JLT     state_21a_7_dispatch2_load_dp_2
                CMPB    r0, #003h
                JLT     state_21a_7_dispatch2_load_dp_2
                JNE     state_21a_7_dispatch2_if_ram22f_bit2_clr_2
                JBR     off(0022fh).1, state_21a_7_dispatch2_load_dp_2
                SJ      state_21a_7_dispatch2_add_acc
state_21a_7_dispatch2_if_ram22f_bit2_clr_2:
                JBR     off(0022fh).2, state_21a_7_dispatch2_load_dp_2
state_21a_7_dispatch2_add_acc:
                ADD     A, #00002h
state_21a_7_dispatch2_load_dp_2:
                MOV     DP, #0038eh
                MOVB    [DP], A
                ADD     A, #state_21a_7_dispatch2_tbl_2
                MOV     DP, A
                CLRB    A
                LCB     A, [DP]
                MOV     DP, #0038fh
                STB     A, [DP]
                SJ      state_21a_7_dispatch2_load_r1
state_21a_7_dispatch2_load_ram2dc:
                MOVB    off(002dch), #0ffh
state_21a_7_dispatch2_load_r1:
                MOVB    r1, #0ffh
                JBR     off(0022eh).1, state_21a_7_dispatch2_andb_ram22f_2
                LB      A, off(002dch)
                JNE     state_21a_7_dispatch2_set_carry
                SJ      state_21a_7_dispatch2_load_dp_3
state_21a_7_dispatch2_andb_ram22f_2:
                ANDB    off(0022fh), #0cfh
                SJ      state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_load_dp_3:
                MOV     DP, #0038fh
                LB      A, [DP]
                JBR     off(0022fh).6, state_21a_7_dispatch2_cmp_acc
                SUBB    A, #0ffh
                JGE     state_21a_7_dispatch2_cmp_acc
                CLRB    A
state_21a_7_dispatch2_cmp_acc:
                CMPB    A, 0cch
                MB      off(0022fh).6, C
                JGE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBS     off(0022dh).4, state_21a_7_dispatch2_load_ram2dd
                MOVB    off(002ddh), #0ffh
state_21a_7_dispatch2_load_ram2dd:
                LB      A, off(002ddh)
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBS     off(0022eh).3, state_21a_7_dispatch2_if_ram22d_bit3_set
                JBR     off(00211h).5, state_21a_7_dispatch2_load_ram2de
                MOVB    off(002deh), #0ffh
state_21a_7_dispatch2_load_ram2de:
                LB      A, off(002deh)
                JNE     state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_if_ram22d_bit3_set:
                JBS     off(0022dh).3, state_21a_7_dispatch2_load_ram2df
                MOVB    off(002dfh), #0ffh
                MOVB    off(002e0h), r1
                SJ      state_21a_7_dispatch2_if_ram22d_bit5_clr
state_21a_7_dispatch2_load_ram2df:
                LB      A, off(002dfh)
                JEQ     state_21a_7_dispatch2_if_ram22d_bit5_clr
                JBR     off(0022eh).5, state_21a_7_dispatch2_load_ram2e0
                MOVB    off(002e0h), r1
state_21a_7_dispatch2_load_ram2e0:
                LB      A, off(002e0h)
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBR     off(0022dh).6, state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_if_ram22d_bit5_clr:
                JBR     off(0022dh).5, state_21a_7_dispatch2_load_ram2e3
                MOVB    off(002e3h), #0ffh
state_21a_7_dispatch2_load_ram2e3:
                LB      A, off(002e3h)
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBS     off(00211h).4, state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_clear_carry:
                RC
                SJ      state_21a_7_dispatch2_store_carry_p0_bit5
state_21a_7_dispatch2_if_ram22d_bit7_set:
                JBS     off(0022dh).7, state_21a_7_dispatch2_clear_carry
state_21a_7_dispatch2_set_carry:
                SC
state_21a_7_dispatch2_store_carry_p0_bit5:
                MB      P0.5, C
state_21a_7_dispatch2_vcal_3:
                VCAL    3
                MOV     DP, #003d1h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     knock_244_recheck
                CMPB    A, #0fch
                JGE     knock_324_bit_check
knock_244_recheck:
                SC
                JBS     off(00230h).6, knock_324_bit_store
knock_324_bit_check:
                MB      C, off(00214h).7
knock_324_bit_store:
                MOV     DP, #00324h
                MB      [DP].0, C
                LB      A, [DP]
                ANDB    A, #0f1h
                STB     A, [DP]
                L       A, ADCR6
                ST      A, 0bah
                LB      A, ADCR7H
                MOV     DP, #003a0h
                STB     A, [DP]
                LB      A, ADCR2H
                MOV     DP, #003a1h
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, off(00211h).1
                XORB    PSWH, #080h
                ROLB    A
                MB      C, off(00211h).7
                ROLB    A
                MB      C, off(00211h).6
                ROLB    A
                MB      C, off(00211h).5
                ROLB    A
                MB      C, off(00211h).4
                ROLB    A
                MB      C, off(00210h).3
                XORB    PSWH, #080h
                ROLB    A
                MB      C, off(00211h).2
                ROLB    A
                MB      C, off(00211h).0
                ROLB    A
                JBS     off(00216h).3, knock_324_bit_store_load_dp
                ANDB    A, #08fh
knock_324_bit_store_load_dp:
                MOV     DP, #003ach
                STB     A, [DP]
                RC
                LCB     A, dwell_battery_check2_tbl
                JNE     knock_324_bit_store_clear_acc
                MOV     DP, #003c9h
                LB      A, [DP]
                SLLB    A
knock_324_bit_store_clear_acc:
                CLRB    A
                ROLB    A
                MB      C, P4.6
                XORB    PSWH, #080h
                ROLB    A
                MB      C, off(0022ch).2
                ROLB    A
                MB      C, off(0022ch).0
                ROLB    A
                MB      C, off(00210h).7
                ROLB    A
                ROLB    A
                JBR     off(00227h).3, knock_324_bit_store_rolb_acc
                MB      C, off(00211h).5
knock_324_bit_store_rolb_acc:
                ROLB    A
                ROLB    A
                MOV     DP, #003adh
                STB     A, [DP]
                RC
                CLRB    A
                MOV     DP, #003aeh
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, P1.2
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P1.4
                ROLB    A
                ROLB    A
                ROLB    A
                MB      C, P0.1
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.0
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.7
                XORB    PSWH, #080h
                ROLB    A
                MOV     DP, #003afh
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, P0.5
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.6
                J       knock_324_bit_store_xorb_pswh
                DB  000h
knock_324_bit_store_rolb_acc_2:
                ROLB    A
                MB      C, P0.4
                ROLB    A
                MB      C, P1.0
                ROLB    A
                ROLB    A
                MB      C, P0.3
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.2
                XORB    PSWH, #080h
                ROLB    A
                MOV     DP, #003b0h
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, P0.5
                ROLB    A
                ROLB    A
                MOV     DP, #003b1h
                STB     A, [DP]
                RC
                CLRB    A
                MOV     DP, #003b2h
                STB     A, [DP]
                RC
                CLRB    A
                MB      C, off(0021dh).0
                ROLB    A
                MOV     DP, #003b3h
                STB     A, [DP]
                J       knock_324_bit_store_clear_carry
knock_324_bit_store_store_dp_ind:
                STB     A, [DP]
                INC     X1
                INC     DP
diag_snapshot_copy_loop:
                LCB     A, [X1]
                MOVB    [DP], A
                INC     X1
                INC     DP
                CMP     X1, #crank_edge_flag_store_tbl
                JNE     diag_snapshot_copy_loop
                MOVB    r0, #040h
                JBR     off(00219h).3, diag_mode_code_store
                MOVB    r0, #020h
                LCB     A, diag_snapshot_copy_loop_tbl
                JNE     diag_mode_code_store
                LCB     A, dwell_battery_check2_tbl
                JEQ     diag_snapshot_copy_loop_load_r0
                LCB     A, diag_snapshot_copy_loop_tbl_2
                JEQ     diag_snapshot_copy_loop_load_r0
                JBS     off(00216h).0, diag_mode_code_store
diag_snapshot_copy_loop_load_r0:
                MOVB    r0, #001h
                JBS     off(00216h).2, diag_mode_code_store
                MOVB    r0, #002h
                LCB     A, dwell_battery_check2_tbl
                JEQ     diag_mode_code_store
                LCB     A, diag_snapshot_copy_loop_tbl_2
                JEQ     diag_snapshot_copy_loop_load_r0_2
                JBR     off(00216h).0, diag_mode_code_store
diag_snapshot_copy_loop_load_r0_2:
                MOVB    r0, #008h
                JBR     off(00216h).0, diag_mode_code_store
                MOVB    r0, #010h
                JBR     off(00217h).6, diag_mode_code_store
                MOVB    r0, #004h
diag_mode_code_store:
                MOV     DP, #003a7h
                LB      A, r0
                STB     A, [DP]
                CLRB    r0
                JBR     off(00216h).3, diag_mode_code_store_rom_load_tbl_60f6
                LCB     A, diag_mode_code_store_tbl_4
                SLLB    A
                ROLB    r0
diag_mode_code_store_rom_load_tbl_60f6:
                LCB     A, diag_mode_code_store_tbl_3
                SLLB    A
                ROLB    r0
                MB      C, off(00227h).5
                ROLB    r0
                MB      C, off(00216h).5
                ROLB    r0
                MB      C, off(00227h).4
                ROLB    r0
                MB      C, off(00217h).6
                ROLB    r0
                RC
                LCB     A, diag_mode_code_store_tbl
                JNE     diag_mode_code_store_rolb_r0
                MOV     DP, #003c7h
                LB      A, [DP]
                SLLB    A
                SLLB    A
diag_mode_code_store_rolb_r0:
                ROLB    r0
                MB      C, off(00216h).3
                ROLB    r0
                MOV     DP, #003a8h
                LB      A, r0
                STB     A, [DP]
                LCB     A, diag_mode_code_store_tbl_2
                MOVB    r0, A
                L       A, off(00260h)
                SLL     A
                JLT     diag_clamp_ff
                CMPB    r0, #000h
                JNE     diag_clamp_acch
                SLL     A
                JGE     diag_clamp_acch
diag_clamp_ff:  LB      A, #0ffh
                SJ      diag_store_3ad
diag_clamp_acch:
                LB      A, ACCH
diag_store_3ad: MOV     DP, #003a9h
                STB     A, [DP]
                MOV     DP, #0030ch
                L       A, [DP]
                SLL     A
                JLT     diag_clamp_ff2
                CMPB    r0, #000h
                JNE     diag_clamp_acch2
                SLL     A
                JGE     diag_clamp_acch2
diag_clamp_ff2: LB      A, #0ffh
                SJ      diag_store_3ae
diag_clamp_acch2:
                LB      A, ACCH
diag_store_3ae: MOV     DP, #003aah
                STB     A, [DP]
                LB      A, 0cch
                JBR     off(00214h).0, diag_store_39f
                CLRB    A
diag_store_39f: MOV     DP, #0039bh
                STB     A, [DP]
                MOV     DP, #003abh
                LB      A, [DP]
                CMPB    A, #033h
                JEQ     diag_3af_range_check
                CMPB    A, #034h
                JEQ     diag_3af_range_check
                CMPB    A, #035h
                JEQ     diag_3af_range_check
                CMPB    A, #036h
                JNE     diag_3af_no_match
diag_3af_range_check:
                SC
                SJ      diag_3af_flag_store
diag_3af_no_match:
                RC
diag_3af_flag_store:
                MB      off(00219h).7, C
                VCAL    3
                MOV     er1, 0b0h
                MOV     er2, 0b2h
                JBR     off(00217h).5, diag_mask_gate
                AND     er1, #0c5e2h
                AND     0b0h, #0c5e2h
                AND     er2, #0040bh
                AND     0b2h, #0040bh
diag_mask_gate: MB      C, 0b7h.1
                JGE     dtc_scan_init
                CLR     A
                ST      A, 0b0h
                ST      A, 0b2h
                ST      A, er1
                ST      A, er2
dtc_scan_init:  MOVB    r7, #001h
                MOV     DP, #002d2h
dtc_scan_loop:  SRL     er2
                ROR     er1
                JLT     dtc_scan_found_check
                LB      A, r7
                SUBB    A, off(002b3h)
                JNE     dtc_scan_f4_check
                STB     A, off(002b3h)
                STB     A, [DP]
dtc_scan_f4_check:
                LB      A, r7
                SUBB    A, 0f4h
                JNE     dtc_scan_advance
                STB     A, 0f4h
dtc_scan_advance:
                INCB    r7
                CMPB    r7, #01ch
                JNE     dtc_scan_loop
                SJ      dtc_debounce_init
dtc_scan_found_check:
                LB      A, off(002b3h)
                JEQ     dtc_scan_new_code
                CMPB    A, r7
                JNE     dtc_scan_advance
                LB      A, [DP]
                JNE     dtc_debounce_init
                SJ      dtc_debounce2_init
dtc_scan_new_code:
                CLR     A
                LB      A, r7
                STB     A, off(002b3h)
                LCB     A, dtc_scan_new_code_tbl[ACC]
                STB     A, [DP]
dtc_debounce_init:
                VCAL    3
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
dtc_debounce_mask_apply:
                ST      A, er0
                MB      C, 0b7h.1
                JGE     dtc_debounce_loop_start
                CLR     er0
dtc_debounce_loop_start:
                MOV     DP, #001adh
dtc_debounce_loop:
                SRL     er0
                JGE     dtc_debounce_check_active
                LB      A, [DP]
                JEQ     dtc_debounce2_init
                DECB    [DP]
                SJ      dtc_debounce_advance
dtc_debounce_check_active:
                CLR     A
                LB      A, r7
                CMPB    A, 0f4h
                JNE     dtc_debounce_advance
                LCB     A, dtc_scan_new_code_tbl[ACC]
                SUBB    A, [DP]
                JNE     dtc_debounce_advance
                STB     A, 0f4h
dtc_debounce_advance:
                INC     DP
                INCB    r7
                CMPB    r7, #02ch
                JNE     dtc_debounce_loop
                MOVB    r7, #030h
                MOV     DP, #001b8h
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                JLT     dtc_debounce2_check
                MOV     [DP], #00bb3h
                LB      A, 0f4h
                SUBB    A, r7
                JNE     dtc_debounce2_check_goto_7a1b
                STB     A, 0f4h
                SJ      dtc_debounce2_check_goto_7a1b
dtc_debounce2_check:
                L       A, [DP]
                JNE     dtc_debounce2_check_goto_7a1b
dtc_debounce2_init:
                LB      A, #005h
                STB     A, [DP]
                LB      A, 0f4h
                JNE     dtc_active_confirm
                LB      A, r7
                STB     A, 0f4h
                SJ      dtc_debounce2_check_goto_7a1b
dtc_active_confirm:
                SUBB    A, r7
                J       dtc_active_confirm_if_ne_goto_7a82
                DB  000h
cfgvariant_apply_gate:
                AND     IE, #00080h
                CLR     A
                LB      A, r7
                CMPB    A, #030h
                JNE     cfgvariant_apply_gate_rom_load_tbl_6f55_acc
                MOV     (001b8h-00180h)[USP], #00bb3h
                JBR     off(00216h).2, cfgvariant_apply_gate_rom_load_tbl_6f55_acc
                SB      0b8h.5
                SJ      cfgvariant_apply_done_load_ram0f8
cfgvariant_apply_gate_rom_load_tbl_6f55_acc:
                LCB     A, cfgvariant_index_lookup_tbl[ACC]
                JEQ     cfgvariant_apply_done_load_ram0f8
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
cfgvariant_apply_done:
                RB      off(00232h).4
                RB      off(00232h).5
                CLR     A
                LB      A, r7
                LCB     A, cfgvariant_index_lookup_tbl[ACC]
                CMPB    A, r6
                JNE     selftest_fail_043_checksum
cfgvariant_apply_done_load_ram0f8:
                L       A, 0f8h
                ST      A, IE
dtc_debounce2_check_goto_7a1b:
                J       dtc_debounce2_check_load_dp
dtc_debounce2_check_load_x1:
                MOV     X1, #0011eh
                NOP
                NOP
calchecksum_loop:
                DEC     DP
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
                J       calchecksum_loop_dec_dp
calchecksum_loop_if_ne_goto_selftest_fail_043_checksum:
                JNE     selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #000h
                JNE     selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #002h
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
selftest_fail_043_checksum:
                MOVB    0f5h, #043h
                BRK
freezeframe_decode_start:
                VCAL    3
                L       A, off(00212h)
                ORB     A, off(00214h)
                J       freezeframe_decode_start_load_carry_ram235_bit3
freezeframe_flag_218_7:
                MB      off(00218h).7, C
                JLT     freezeframe_flag_218_6
                ANDB    off(00218h), #0bfh
                ANDB    off(0022bh), #0efh
                ANDB    off(00225h), #07fh
                ANDB    off(00234h), #07fh
                SJ      prep_lowpower_seq
freezeframe_flag_218_6:
                L       A, off(00212h)
                AND     A, #0fffdh
                JNE     freezeframe_flag_22b_4
                L       A, off(00214h)
                AND     A, #014f5h
                JNE     freezeframe_flag_22b_4
                RC
freezeframe_flag_22b_4:
                MB      off(00218h).6, C
                SC
                L       A, off(00212h)
                AND     A, #02054h
                JNE     freezeframe_flag_22b_4_store_carry_ram22b_bit4
                JBS     off(00214h).0, freezeframe_flag_22b_4_store_carry_ram22b_bit4
                RC
freezeframe_flag_22b_4_store_carry_ram22b_bit4:
                MB      off(0022bh).4, C
                J       freezeframe_flag_22b_4_set_carry
freezeframe_flag_22b_4_if_ne_goto_freezeframe_flag_next:
                JNE     freezeframe_flag_next
                L       A, off(00214h)
                AND     A, #014fdh
                JNE     freezeframe_flag_next
                RC
freezeframe_flag_next:
                MB      off(00225h).7, C
                J       freezeframe_flag_next_set_carry
freezeframe_flag_next_if_ne_goto_54b9:
                JNE     freezeframe_flag_next_store_carry_ram234_bit7
                L       A, off(00214h)
                AND     A, #074f5h
                JNE     freezeframe_flag_next_store_carry_ram234_bit7
                RC
freezeframe_flag_next_store_carry_ram234_bit7:
                MB      off(00234h).7, C
prep_lowpower_seq:
                SB      off(00230h).3
                JNE     lowpower_trap_call
                CAL     ResetWatchDog
                L       A, TM1
                ADD     A, #00a00h
                ST      A, TMR1
                MULB
                DIV
                DIV
                MB      C, 0b7h.1
                JLT     prep_lowpower_ie_config
                CAL     port_debounce_helper
                MOVB    0f7h, #020h
prep_lowpower_ie_config:
                MOV     0fah, #002a0h
                L       A, #02babh
                ST      A, 0f8h
                CLRB    TRNSIT
                CLR     IRQ
                RB      TCON0.2
                ST      A, IE
lowpower_trap_call:
                J       regbank_selftest2_start
crank_helper2:  JBR     off(00128h).2, injtimer_shift_path
injector_timer_schedule:
                MOVB    r0, #0ffh
                L       A, off(00196h)
                ST      A, er1
                CMPB    off(00117h), #00fh
                JNE     injtimer_schedule_done
                L       A, TM0
                SUB     A, #00001h
                ST      A, TMR0
                MOV     X1, #00110h
                MOV     DP, #00190h
                L       A, [DP]
                CMP     A, #000c0h
                JGE     injtimer_bank1_check2
                CLR     A
                ST      A, [DP]
                INC     DP
                INC     DP
                L       A, [DP]
                CMP     A, #000c0h
                JGE     injtimer_bank2_zero
                CLR     A
                ST      A, [DP]
                INC     DP
                INC     DP
                L       A, [DP]
                CMP     A, #000c0h
                JLT     injtimer_bank3_check
                ST      A, er1
                LB      A, off(00116h)
                SRLB    A
                RORB    off(00116h)
                SJ      injtimer_schedule_common
injtimer_shift_path:
                LB      A, off(0018eh)
                SLLB    A
                ROLB    off(0018eh)
                LB      A, off(00116h)
                SLLB    A
                ROLB    off(00116h)
                RT
injtimer_bank2_zero:
                ST      A, er1
                LB      A, off(00116h)
                SRLB    A
                RORB    off(00116h)
                SRLB    A
                RORB    off(00116h)
                SJ      injtimer_bank_mask_calc
injtimer_bank3_check:
                CLR     A
                ST      A, [DP]
                SJ      injtimer_schedule_done
injtimer_bank1_check2:
                ST      A, er1
                LB      A, off(00116h)
                SLLB    A
                ROLB    off(00116h)
                CAL     inj_wrap_clamp_calc
                LB      A, off(0018eh)
                SRLB    A
                SRLB    A
                ANDB    r0, A
injtimer_bank_mask_calc:
                CAL     inj_wrap_clamp_calc
                LB      A, off(0018eh)
                SRLB    A
                ANDB    r0, A
injtimer_schedule_common:
                CAL     inj_wrap_clamp_calc
                ANDB    r0, off(0018eh)
injtimer_schedule_done:
                LB      A, off(0018eh)
                SLLB    A
                ROLB    off(0018eh)
                LB      A, r0
                ANDB    A, off(0018eh)
                CMP     off(00196h), #000c0h
                JLT     injenable_reset_all
                MOVB    r1, off(00117h)
                ANDB    off(00117h), A
                JBS     off(0012ah).7, injenable_p2_update
                JBS     off(00124h).5, injenable_p2_update
                ANDB    off(0018fh), A
                ORB     off(0012ah), #001h
injenable_p2_update:
                LB      A, off(0018fh)
                ORB     A, #0f0h
                ANDB    P2, A
                ANDB    TRNSIT, #0fbh
                ANDB    PSWH, #0feh
                ORB     TCON0, #004h
                L       A, TM0
                ORB     PSWH, #001h
                ANDB    TCON0, #0fbh
                CMPB    r1, #00fh
                JEQ     inj_accum2_direct
                SUB     A, TMR0
                ADD     A, er1
                JBR     off(00109h).0, inj_accum_check1
                JBR     off(00109h).2, inj_accum_check2
                J       inj_accum_check4
injenable_reset_all:
                LB      A, #00fh
                STB     A, off(00117h)
                STB     A, off(0018fh)
                ORB     P2, A
                SB      TCON0.2
                LB      A, off(0018eh)
                XORB    A, #0ffh
                MB      C, ACC.7
                ROLB    A
                STB     A, off(00116h)
                RB      TCON0.2
                L       A, #00001h
                SJ      inj_accum1_store_new
inj_accum2_direct:
                ADD     A, er1
; --- Dual-accumulator injector timing calc (0x46A3-0x4723ish): manages two 16-bit
; accumulators (0x110/0x112, capped/wrapped at 0x100) feeding TMR0 reschedule -- likely
; timing for two injector groups/banks. No calibration anchors; named at the mechanism level.
                ST      A, TMR0
                SJ      inj_p2_calc_start
inj_accum_check1:
                JBR     off(00109h).2, inj_accum_dispatch
inj_accum_check2:
                JBS     off(00109h).3, inj_accum_check5
                JBS     off(00109h).1, inj_accum_dispatch2
inj_accum_dispatch:
                JGE     inj_accum_direct_add
                SUB     A, off(00110h)
                JLT     inj_accum1_add
                SUB     A, off(00112h)
                JGE     inj_accum_check3
                ADD     A, off(00112h)
                CMP     A, #00100h
                JLT     inj_accum2_zero
                ST      A, off(00112h)
                CLR     A
                J       inj_accum_store_114
inj_accum1_add: ADD     A, off(00110h)
                CMP     A, #00100h
                JLT     inj_accum_both_zero
                ST      A, off(00110h)
inj_accum2_zero:
                CLR     A
                ST      A, off(00112h)
                J       inj_accum_store_114
inj_accum_check3:
                CMP     A, #00100h
                JGE     inj_accum_store_114
                CLR     A
                SJ      inj_accum_store_114
inj_accum_direct_add:
                ADD     TMR0, A
inj_accum_both_zero:
                CLR     A
                ST      A, off(00110h)
                ST      A, off(00112h)
                J       inj_accum_store_114
inj_accum_check4:
                JGE     inj_accum_check4_add_tmr0
                CMP     A, #00100h
                JGE     inj_accum1_store_new
                CLR     A
inj_accum1_store_new:
                ST      A, off(00110h)
                L       A, #00001h
                ST      A, off(00112h)
                J       inj_accum_store_114
inj_accum_check4_add_tmr0:
                ADD     TMR0, A
                CLR     A
                ST      A, off(00110h)
inj_accum_check4_load_imm:
                L       A, #00001h
                ST      A, off(00112h)
                J       inj_accum_store_114
inj_accum_check5:
                JBS     off(00109h).1, inj_accum_check4
inj_accum_dispatch2:
                JGE     inj_accum_dispatch2_add_tmr0
                SUB     A, off(00110h)
                JGE     inj_accum1_wrap_check
                ADD     A, off(00110h)
                CMP     A, #00100h
                JGE     inj_accum1_store2
inj_accum1_zero2:
                CLR     A
inj_accum1_store2:
                ST      A, off(00110h)
inj_accum2_zero2:
                CLR     A
inj_accum2_store2:
                ST      A, off(00112h)
                L       A, #00001h
inj_accum_store_114:
                ST      A, off(00114h)
inj_p2_calc_start:
                L       A, off(00110h)
                JNE     inj_p2_calc_alt
                L       A, off(00112h)
                JEQ     inj_p2_calc_check114
                LB      A, off(00116h)
                SRLB    A
                SRLB    A
                SRLB    A
                ORB     A, off(00116h)
                J       inj_p2_calc_or197
inj_p2_calc_alt:
                LB      A, off(00116h)
                SJ      inj_p2_calc_or197
inj_p2_calc_check114:
                L       A, off(00114h)
                JEQ     inj_p2_default_f
                LB      A, off(00116h)
                RORB    A
                XORB    A, #0ffh
inj_p2_calc_or197:
                ORB     A, off(0018fh)
                ANDB    A, #00fh
inj_p2_drive_return:
                ORB     P2, A
                RB      off(0012ah).7
                RT
inj_p2_default_f:
                LB      A, #00fh
                SJ      inj_p2_drive_return
inj_accum1_wrap_check:
                CMP     A, #00100h
                JLT     inj_accum2_zero2
                SJ      inj_accum2_store2
inj_accum_dispatch2_add_tmr0:
                ADD     TMR0, A
                SJ      inj_accum1_zero2
inj_wrap_clamp_calc:
                CLR     A
                XCHG    A, [DP]
                MOV     X2, A
                INC     DP
                INC     DP
                L       A, [DP]
                SUB     A, X2
                JLT     inj_wrap_clamp_zero
                CMP     A, #00100h
                JGE     inj_wrap_clamp_store
inj_wrap_clamp_zero:
                CLR     A
inj_wrap_clamp_store:
                ST      A, 00000h[X1]
                INC     X1
                INC     X1
                RT
knock_helper1:  MOVB    r6, #077h
                JEQ     bitreverse_return
bitreverse_loop:
                MB      C, r6.7
                ROLB    r6
                SUBB    A, #001h
                JNE     bitreverse_loop
bitreverse_return:
                LB      A, r6
                RT
tm0_resync_helper:
                L       A, TMR2
                JBR     off(0011fh).2, tm0_resync_store_er3
                L       A, 0f0h
tm0_resync_store_er3:
                ST      A, er3
                JBS     off(0010fh).7, rpm_resync_gate
                MB      C, IRQH.0
                JGE     rpm_resync_gate
                INCB    0aeh
                SB      0b6h.0
rpm_resync_gate:
                SB      off(00128h).3
                JEQ     rpm_resync_common
                SUB     A, 0eeh
                JBR     off(0011fh).2, rpm_resync_tcon2_check
                CLRB    r1
                MOVB    r0, 0aeh
                SBCB    r0, #000h
                MOV     er2, #00006h
                DIV
                CMPB    r0, #000h
                JEQ     rpm_period_reset_calc
                CLR     A
rpm_period_reset_calc:
                ST      A, off(00136h)
                MOV     X1, #0000ch
rpm_period_reset_loop:
                DEC     X1
                DEC     X1
                ST      A, 00360h[X1]
                JNE     rpm_period_reset_loop
                SJ      rpm_resync_common
rpm_resync_tcon2_check:
                MB      C, TCON2.2
                JGE     rpm_resync_store136
                CLR     A
rpm_resync_store136:
                ST      A, off(00136h)
                LB      A, 0a2h
                SLLB    A
                EXTND
                MOV     X1, A
                L       A, off(00136h)
                ST      A, 00360h[X1]
rpm_resync_common:
                L       A, er3
                ST      A, 0eeh
                CLRB    0aeh
                CMPB    0a2h, #005h
                JNE     crank_a3_gate
                SLLB    off(0019bh)
crank_a3_gate:  JBS     off(0019bh).2, crank_dp_35e
                MOV     DP, #00358h
                MB      C, 0b8h.0
                SJ      crank_pswl4_store
crank_mul_alt:  MULB
crank_mul_common:
                MULB
                SJ      crank_a2_advance
crank_dp_35e:   MOV     DP, #0035eh
                MB      C, 0b8h.1
crank_pswl4_store:
                MB      PSWL.4, C
                LB      A, 0a2h
                CMPB    A, #004h
                JEQ     crank_mul_alt
                JGE     crank_a0_update
                STB     A, r0
                INCB    r0
                LB      A, 0a0h
                ADDB    A, #001h
                CMPB    A, r0
                JLE     crank_mul_common
                LB      A, [DP]
                ADDB    A, #001h
                CMPB    A, r0
                JLE     crank_mul_common
                JBR     off(0011fh).0, crank_mul_common
crank_a0_update:
                L       A, [DP]
                ST      A, 0a0h
                DEC     DP
                LB      A, [DP]
                STB     A, 09fh
                MB      C, PSWL.4
                MB      off(0012ah).5, C
crank_a2_advance:
                CLR     A
                MOV     er0, 0a0h
                ST      A, er3
                LB      A, 0a2h
                ADDB    A, #001h
                CMPB    A, r0
                JEQ     crank_mul_common2
                CMPB    A, #006h
                JNE     crank_a2_check3
                LB      A, r0
                JEQ     crank_mul_common2
                SLLB    A
                JLT     crank_mul_common2
crank_a2_check3:
                CMPB    0a2h, #003h
                JNE     crank_mul_alt2
                CMPB    r0, #005h
                JNE     crank_mul_alt2
                MOV     er3, off(00136h)
crank_mul_common2:
                CLRB    r0
                L       A, off(00136h)
                MUL
                LB      A, 0a0h
                SLLB    A
                JGE     crank_mul_common2_load_er3
                ANDB    PSWH, #0feh
                L       A, TM3
                SUB     A, TMR2
                ADD     A, #00010h
                CMP     A, er1
                JGE     crank_mul_common2_clear_tcon3_bit2
                L       A, TMR2
                ADD     A, er1
                SJ      tmr3_reload_store2
crank_mul_alt2: MUL
                RB      r0.0
                L       A, ACC
                SJ      tmr3_reload_clamp_min
crank_mul_common2_clear_tcon3_bit2:
                RB      TCON3.2
                L       A, TM3
                SUB     A, #00001h
tmr3_reload_store2:
                ST      A, TMR3
                RB      TCON3.3
                ORB     PSWH, #001h
                J       tmr3_reload_clamp_min
crank_mul_common2_load_er3:
                L       A, er3
                ADD     A, er1
                JGE     tmr3_reload_clamp_check
                L       A, #0ffffh
tmr3_reload_clamp_check:
                CMP     A, #0001fh
                JGE     tmr3_store_e8
tmr3_reload_clamp_min:
                L       A, #0001fh
tmr3_store_e8:  ST      A, 0e8h
                MOV     DP, #00f00h
                LB      A, [DP]
                SRLB    A
                ROR     off(001a2h)
                SRLB    A
                ROR     off(001a2h)
                LB      A, 0a2h
                JNE     crank_a2_check4
                CLR     A
                XCHG    A, off(001a2h)
                ST      A, 0ech
crank_a2_check4:
                LB      A, 0a2h
                CMPB    A, #001h
                JNE     crank_a8_p1_output
                L       A, 0eah
                ST      A, off(001a0h)
crank_a8_p1_output:
                L       A, off(001a0h)
                SRL     A
                MB      P1.7, C
                SRL     A
                MB      P1.3, C
                ST      A, off(001a0h)
                MOV     DP, #02f00h
                LB      A, P1
                STB     A, [DP]
                RT
ign_angle_to_timer_convert:
                CLRB    A
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
ign_timer_clamp_store:
                ST      A, er0
                CLRB    A
                SUBB    A, r2
                SLLB    A
                JNE     ign_timer_convert_return
                LB      A, #0ffh
                SC
ign_timer_convert_return:
                RT
knockretard_helper:
                STB     A, r0
                LC      A, [X1]
                CMPB    r0, A
                JLT     knockretard_r1_store
                STB     A, r0
knockretard_r1_store:
                STB     A, r1
                LB      A, ACCH
                CMPB    r0, A
                JGE     knockretard_sub_result
                STB     A, r0
knockretard_sub_result:
                SUBB    r0, A
                SUBB    r1, A
                LB      A, r7
                J       table_interp_delta_calc
table_interp_lookup:
                CMPCB   A, 00002h[X1]
; --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found
                INC     X1
                INC     X1
                J       table_interp_lookup
table_interp_bracket_found:
                STB     A, r0
                LC      A, 00002h[X1]
                MOVB    r6, ACCH
                STB     A, r1
                SUBB    r0, A
                LC      A, [X1]
                SUBB    A, r1
                STB     A, r1
                LB      A, ACCH
table_interp_delta_calc:
                SUBB    A, r6
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
table_interp_scale_add:
                MULB
                MOVB    r0, r1
                DIVB
                ADDB    A, r6
                STB     A, r6
                RT
vcal_1:         CMPCB   A, [X1]
                JLE     vcal1_bracket_check
                LCB     A, [X1]
vcal1_bracket_check:
                CMPCB   A, 00002h[X1]
                JGE     table_interp_bracket_found
                LCB     A, 00002h[X1]
                J       table_interp_bracket_found
vcal_2:         CMPCB   A, [X1]
                JLE     vcal2_bracket_check
                LCB     A, [X1]
vcal2_bracket_check:
                CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                LCB     A, 00003h[X1]
                J       vcal_common_interp
vcal_0:         CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                ADD     X1, #00003h
                J       vcal_0
vcal_common_interp:
                STB     A, r0
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
injtimer_bank_calc3:
                SUB     A, er3
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
injtimer_bank_calc3_alt:
                MUL
                MOV     er0, er1
                DIV
                ADD     A, er3
                ST      A, er3
                RT
table_interp_lookup_4byte:
                CMPC    A, 00004h[X1]
                JGE     table_interp_4byte_bracket
                ADD     X1, #00004h
                J       table_interp_lookup_4byte
table_interp_4byte_bracket:
                ST      A, er0
                LC      A, 00004h[X1]
                ST      A, er2
                SUB     er0, A
                LC      A, [X1]
                SUB     A, er2
                ST      A, er2
                LC      A, 00006h[X1]
                ST      A, er3
                LC      A, 00002h[X1]
                J       injtimer_bank_calc3
sub_clamp_helper:
                SUBB    A, #018h
                JLT     sub_clamp_zero
                MB      C, ACCH.7
                ROLB    A
                JGE     sub_clamp_return
                LB      A, #0ffh
sub_clamp_return:
                RT
sub_clamp_zero: CLRB    A
                RT
mul_scale_helper2:
                MUL
                MOV     er2, er1
                CLR     A
                SUB     A, er0
                MOV     er0, [DP]
                MUL
                L       A, er1
                ADD     A, er2
                ST      A, [DP]
                RT
rpm_accel_track_helper:
                MUL
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
injtimer_bank_calc1:
                MOV     er2, 00000h[X1]
                SUB     A, er2
                JGE     injtimer_bank_calc1_mul
                ST      A, er1
                CLR     A
                SUB     A, er1
injtimer_bank_calc1_mul:
                MUL
                ST      A, er0
                L       A, 00002h[X1]
                SJ      injtimer_bank_calc1_sign
vcal3_leanprotect_ratelimit_sub_load_er2:
                MOV     er2, 00000h[X1]
                SUB     A, er2
                JGE     vcal3_leanprotect_ratelimit_sub_mul_acc
                ST      A, er1
                CLR     A
                SUB     A, er1
vcal3_leanprotect_ratelimit_sub_mul_acc:
                MUL
                ST      A, er0
                MOV     DP, #00384h
                L       A, [DP]
injtimer_bank_calc1_sign:
                JGE     injtimer_bank_calc1_add
                SUB     A, er0
                ST      A, er0
                L       A, er2
                SBC     A, er1
                RT
injtimer_bank_calc1_add:
                ADD     A, er0
                ST      A, er0
                L       A, er2
                ADC     A, er1
                RT
                DB  0E2h
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
vcal4_store:    ST      A, er3
                RT
vcal4_negative_path:
                ROR     A
vcal_5:         ADD     A, er3
                JGE     vcal5_store
                L       A, #0ffffh
vcal5_store:    ST      A, er3
                RT
                DB  0E2h
signextend_helper:
                ROL     A
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
signext_common_add:
                ADD     A, er3
                ST      A, er3
                RT
signext_negative_path:
                ROR     A
                MB      C, r7.7
                JGE     signext_common_add
                ADD     A, er3
                ROL     A
                JLT     signext_final_store
                L       A, #08000h
                ST      A, er3
                RT
signext_final_store:
                ROR     A
                ST      A, er3
                RT
scale_mul5_div4:
                MOV     er0, #00005h
                MUL
                SRL     er1
                ROR     A
                SRL     er1
                ROR     A
                CMPB    r2, #000h
                JEQ     scale_mul5_div4_return
                L       A, #0ffffh
scale_mul5_div4_return:
                RT
vcal_7:         XOR     A, #0ffffh
                ADD     A, #00001h
                RT
vcal_6:         XORB    A, #0ffh
                ADDB    A, #001h
                RT
newval_table3_call_sub_clear_acc:
                CLR     A
                ST      A, er0
                ST      A, er2
                LB      A, r3
                CMPB    A, r6
                JLT     scaler_table_search_start
                LB      A, r6
scaler_table_search_start:
                STB     A, r6
                ADD     X1, A
scaler_table_search_loop:
                INCB    r6
                INC     X1
                LCB     A, [X1]
                JEQ     scaler_table_interp
                CMPB    A, r2
                JLE     scaler_table_search_loop
scaler_table_interp:
                LB      A, r2
scaler_table_search_back:
                DECB    r6
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
scaler_div_final:
                DIV
                RT
table2d_lookup_interp:
                CLR     A
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
table2d_row_calc:
                ST      A, er2
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
                CAL     table2d_mul_combine
                MOV     er2, X1
                MOV     X1, A
                L       A, DP
                CAL     table2d_mul_combine
                L       A, X1
                MOV     er0, er3
table2d_mul_combine:
                SUB     A, er2
                JGE     table2d_mul_positive
                ST      A, er1
                CLR     A
                SUB     A, er1
                MUL
                L       A, er1
                SUB     er2, A
                L       A, er2
                RT
table2d_mul_positive:
                MUL
                L       A, er1
                ADD     A, er2
                ST      A, er2
                RT
knock_244_helper:
                EXTND
                ADD     DP, A
                CLR     A
                LCB     A, [DP]
                ST      A, er2
                INC     DP
                LCB     A, [DP]
                CAL     table2d_mul_combine
                LB      A, r4
                RT
map_result_postscale:
                MOVB    r0, off(0013fh)
                MOVB    r1, #001h
                CMPB    r0, #080h
                JGE     mul_scale_rotate
                INCB    r1
mul_scale_rotate:
                MUL
                LB      A, r2
                L       A, ACC
                SWAP
                SRLB    r3
                ROR     A
                CMPB    r3, #000h
                JEQ     tipin_table_diff_calc
                L       A, #0ffffh
tipin_table_diff_calc:
                RT
idle_stall_helper:
                MOV     X2, #00010h
                MOV     DP, #01000h
                SJ      clamp_range_check
injtimer_bank_calc2:
                MOV     X2, #fueltbl_range_check_tbl
                MOV     DP, #09862h
clamp_range_check:
                CMP     A, X2
                JLE     clamp_range_lowside
                CMP     A, DP
                JLT     clamp_range_store
                MOV     X2, DP
clamp_range_lowside:
                L       A, X2
                CLR     er0
clamp_range_store:
                ST      A, 00000h[X1]
                L       A, er0
                ST      A, 00002h[X1]
                RT
vcal3_leanprotect_ratelimit_sub_load_er2_2:
                MOV     er2, #00023h
                MOV     er3, #003ffh
                SJ      clamp_to_35_512_cmp_acc
clamp_to_35_512:
                MOV     er2, #00023h
                MOV     er3, #00199h
clamp_to_35_512_cmp_acc:
                CMP     A, er2
                JLT     load_er0_result
                CMP     A, er3
                JLE     load_er0_result_store_tbl_x1
                MOV     er2, er3
load_er0_result:
                L       A, er2
                CLR     er0
load_er0_result_store_tbl_x1:
                ST      A, 00000h[X1]
                L       A, er0
                ST      A, [DP]
                RT
sub37_clamp_to_er0:
                SUB     A, #00025h
                JLT     sub37_clamp_to_er0_load_er0
                CMP     A, er0
                JGE     sub37_clamp_to_er0_return
sub37_clamp_to_er0_load_er0:
                L       A, er0
sub37_clamp_to_er0_return:
                RT
add24_clamp_neg1:
                ADD     A, #00018h
                JGE     table_index_add_sub_0ce
                L       A, #0ffffh
table_index_add_sub_0ce:
                ST      A, er3
                CLR     er1
                LC      A, [X1]
                ST      A, er0
                L       A, 0ceh
                SUB     A, er0
                JLT     table_index_add_clamp_er3
                ST      A, er0
                LC      A, 00004h[X1]
                MUL
table_index_add_clamp_er3:
                LC      A, 00002h[X1]
                ADD     A, er1
                CMP     A, er3
                JLT     table_index_add_clamp_er3_return
                L       A, er3
table_index_add_clamp_er3_return:
                RT
vcal3_leanprotect_ratelimit_sub_mul_acc_2:
                MUL
                CMPB    r2, #000h
                JEQ     idle_helper2_if_ram20c_bit0_set
                L       A, #0ffffh
                SJ      idle_helper2_if_ram20c_bit0_set
idle_helper2:   MUL
                L       A, er1
idle_helper2_if_ram20c_bit0_set:
                JBS     off(0020ch).0, idle_helper2_alt_path
                XCHG    A, er3
                SUB     A, er3
                JGE     idle_pi_clamp_compare
idle_pi_clamp_setcarry:
                SC
                L       A, X1
                ST      A, er3
                RT
idle_helper2_alt_path:
                ADD     A, er3
                JLT     idle_helper2_sc_path
idle_pi_clamp_compare:
                CMP     A, X1
                JLE     idle_pi_clamp_setcarry
                CMP     X2, A
                JGT     idle_helper2_store
idle_helper2_sc_path:
                SC
                L       A, X2
idle_helper2_store:
                ST      A, er3
                RT
                DB  067h,000h,007h,0EBh,016h,003h,067h,000h
                DB  005h,001h
idle_pi_clamp_helper:
                CMP     off(0028eh), A
                JLT     idle_pi_clamp_low
                CMP     A, off(00290h)
                JGE     idle_pi_clamp_return
                L       A, off(00290h)
idle_pi_clamp_return:
                RT
idle_pi_clamp_low:
                L       A, off(0028eh)
                RT
weighted_sum_2term_trim:
                MOV     X1, A
                CLRB    r0
                MOVB    r1, r6
                MUL
                MOV     er2, er1
                L       A, X1
                MOVB    r1, r7
                MUL
                L       A, off(002a8h)
                MB      C, PSWL.4
                JLT     weighted_sum_2term_trim_sub_acc
                ADD     A, er1
                JLT     weighted_sum_2term_trim_load_imm
                CMP     A, #003ffh
                JLE     weighted_sum_2term_trim_store_ram2a8
weighted_sum_2term_trim_load_imm:
                L       A, #003ffh
weighted_sum_2term_trim_store_ram2a8:
                ST      A, off(002a8h)
                ADD     A, er2
                JLT     weighted_sum_2term_trim_load_imm_2
                CMP     A, #003ffh
                JLT     weighted_sum_2term_trim_return
weighted_sum_2term_trim_load_imm_2:
                L       A, #003ffh
weighted_sum_2term_trim_return:
                RT
weighted_sum_2term_trim_sub_acc:
                SUB     A, er1
                CLR     er0
                JLE     weighted_sum_2term_trim_load_er0
                MOV     er0, #003ffh
                CMP     A, er0
                JLT     weighted_sum_2term_trim_store_ram2a8_2
weighted_sum_2term_trim_load_er0:
                L       A, er0
weighted_sum_2term_trim_store_ram2a8_2:
                ST      A, off(002a8h)
                SUB     A, er2
                JLE     weighted_sum_2term_trim_clear_acc
                CMP     A, #003ffh
                JLT     weighted_sum_2term_trim_return_2
                L       A, #003ffh
weighted_sum_2term_trim_return_2:
                RT
weighted_sum_2term_trim_clear_acc:
                CLR     A
                RT
vcal3_leanprotect_ratelimit_sub_if_lt_goto_5b7a:
                JLT     vcal3_leanprotect_ratelimit_sub_load_imm
vcal3_leanprotect_ratelimit_sub_cmp_acc:
                CMP     A, #003ffh
                JLT     vcal3_leanprotect_ratelimit_sub_return
vcal3_leanprotect_ratelimit_sub_load_imm:
                L       A, #003ffh
vcal3_leanprotect_ratelimit_sub_return:
                RT
cfgvariant_set_flags:
                SUBB    A, #001h
                MOVB    r0, #008h
                DIVB
                MOV     X1, A
                LB      A, r1
                SBR     0011ah[X1]
                SBR     00212h[X1]
                SBR     0031eh[X1]
cfgvariant_checksum_calc:
                MOV     DP, #0031dh
                CLR     er0
cfgvariant_checksum_loop:
                LB      A, r0
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
port_debounce_helper:
                MOV     DP, #03f00h
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
decrement_timer_array:
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                LB      A, 00000h[X1]
                JEQ     decrement_timer_array_next
                DECB    00000h[X1]
decrement_timer_array_next:
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                INC     X1
                JRNZ    DP, decrement_timer_array
                RT
ResetWatchDog:  LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                MB      C, 0b7h.1
                JLT     resetwatchdog_return
                XORB    P2, #010h
resetwatchdog_return:
                RT
ect_step_helper:
                ADDB    A, #005h
                JGE     ect_step_range_check
                LB      A, #0ffh
ect_step_range_check:
                JBS     off(00217h).4, ect_step_clamp_default
                JBR     off(00230h).3, ect_step_clamp_default
                CMPB    A, 00376h[X1]
                JGE     ect_step_return
ect_step_clamp_default:
                MOVB    r0, #042h
                CMPB    A, r0
                JGE     ect_step_store
                LB      A, r0
ect_step_store: STB     A, 00376h[X1]
ect_step_return:
                RT
ect_smooth_helper:
                SUBB    A, [DP]
                JGE     ect_smooth_sub
                ADDB    A, #002h
                SJ      ect_smooth_store
ect_smooth_sub: SUBB    A, #002h
ect_smooth_store:
                JGE     ect_smooth_add_store
                CLRB    A
ect_smooth_add_store:
                ADDB    A, [DP]
                STB     A, [DP]
                RT
crank_edge_helper:
                L       A, off(00124h)
                ST      A, (0021ch-00280h)[USP]
                L       A, off(00126h)
                ST      A, (0021eh-00280h)[USP]
                RT
refresh_engine_flags_snapshot:
                L       A, (00212h-00280h)[USP]
; --- Copies a 5-word input/condition snapshot (captured elsewhere, likely synchronized with
; the crank-angle interrupt) into the working flag bytes off(0011Ah)/(0011Ch)/(0011Eh)/
; (00120h)/(00122h). These are the same flag bytes tested throughout GIO1/2/3, ignition
; timing, and elsewhere in this file (e.g. "JBR off(0011eh).5, ..."), refreshed once per call
; here rather than being live hardware registers -- worth knowing when tracing any of those
; bit tests: they reflect the state as of the last refresh_engine_flags_snapshot call, not the
; instantaneous pin state.
                ST      A, off(0011ah)
                L       A, (00214h-00280h)[USP]
                ST      A, off(0011ch)
                L       A, (00216h-00280h)[USP]
                ST      A, off(0011eh)
                L       A, (00218h-00280h)[USP]
                ST      A, off(00120h)
                L       A, (0021ah-00280h)[USP]
                ST      A, off(00122h)
                RT
timer_or_counter_helper:
                LB      A, r0
                MBR     C, [DP]
                LC      A, [X1]
                JLT     timer_or_counter_helper_load_carry_pswl_bit4
                LB      A, ACCH
timer_or_counter_helper_load_carry_pswl_bit4:
                MB      C, PSWL.4
                JLT     timer_or_counter_helper_cmp_r2
                CMPB    A, r2
                SJ      timer_or_counter_helper_load_r0
timer_or_counter_helper_cmp_r2:
                CMPB    r2, A
timer_or_counter_helper_load_r0:
                LB      A, r0
                MBR     [DP], C
                INC     X1
                INC     X1
                INCB    r0
                DECB    r1
                JNE     timer_or_counter_helper
                RT
selftest_regbank_verify:
                MOV     X2, A
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
regbank_verify_fail:
                MOVB    0f5h, #042h
                BRK
idle_helper1:   JBR     off(00230h).3, idle_helper1_alt
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                L       A, TM2
                SUB     A, off(0025ah)
                CMP     A, #000c8h
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
                JLT     idle_helper1_return
idle_helper1_alt:
                RB      IRQH.4
                JEQ     idle_helper1_alt_load_ram0f5
                LB      A, P2
                SWAPB
                SRLB    A
                ANDB    A, #007h
                EXTND
                MOV     X1, A
                LB      A, ADCR1H
                STB     A, 003ceh[X1]
                LB      A, ADCR0H
                STB     A, 003c6h[X1]
                L       A, 0fah
                ST      A, IE
                ANDB    PSWH, #0feh
                ADDB    P2, #020h
                MOV     off(0025ah), TM2
                ORB     PSWH, #001h
                L       A, 0f8h
                ST      A, IE
idle_helper1_return:
                RT
idle_helper1_alt_load_ram0f5:
                MOVB    0f5h, #04ah
                BRK
selftest_reason_range_check:
                CMPB    off(00238h), #00ah
                JLT     empty_stub_return
selftest_reason_range_check_entry:
                MOV     DP, #003d1h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     selftest_reason_range_check_entry_load_imm
                CMPB    A, #0fch
                JGE     empty_stub_return
                CMPB    A, #088h
                JGT     selftest_reason_range_check_entry_load_imm
                CMPB    A, #078h
                JGE     empty_stub_return
selftest_reason_range_check_entry_load_imm:
                LB      A, #049h
                STB     A, 0afh
                DECB    0f7h
                JNE     empty_stub_return
                STB     A, 0f5h
                BRK
empty_stub_return:
                RT
dwell_scale_helper:
                MOVB    r0, #0bdh
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
dwell_scale_default:
                LB      A, r0
dwell_scale_return:
                RT
idle_init_start_sub_load_dp:
                MOV     DP, #04700h
idle_init_start_sub_load_dp_ind:
                LB      A, [DP]
                XORB    A, #0ffh
                ROLB    A
                ROLB    off(00258h)
                ROLB    A
                ROLB    off(00258h)
                RT
cfgvariant_eval_condition:
                CLRB    r0
                CMPB    r6, #001h
                JNE     cfgvariant_check_v3
                CMPB    0dah, #01ah
                JLT     cfgvariant_result_common
                INCB    r0
cfgvariant_result_common:
                SJ      cfgvariant_eval_result
cfgvariant_check_v3:
                CMPB    r6, #003h
; --- cfgvariant_eval_condition's dispatch body: for each specific variant index (3, 6, 7, 10,
; 11, 13, 20, 26), checks the sign of that variant's associated sensor/config byte (0xBB,
; 0x3D4, 0x3A4, 0x3CC, 0x3D2, 0x3CD, 0x3D2 again, 0xD7) and increments r0 if negative --
; reads as a per-variant "is this variant's associated input plausible/connected" check,
; feeding cfgvariant_eval_result.
                JNE     cfgvariant_check_v6
                LB      A, 0bbh
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v6:
                CMPB    r6, #006h
                JNE     cfgvariant_check_v7
                MOV     DP, #003d0h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v7:
                CMPB    r6, #007h
                JNE     cfgvariant_check_v10
                MOV     DP, #003a0h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v10:
                CMPB    r6, #00ah
                JNE     cfgvariant_check_v11
                MOV     DP, #003c8h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v11:
                CMPB    r6, #00bh
                JNE     cfgvariant_check_v11_cmp_r6
                MOV     DP, #003ceh
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v11_cmp_r6:
                CMPB    r6, #00ch
                JNE     cfgvariant_check_v13
                CMPB    r7, #009h
                JNE     cfgvariant_check_v13
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v13:
                CMPB    r6, #00dh
                JNE     cfgvariant_check_v20
                MOV     DP, #003c9h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v20:
                CMPB    r6, #014h
                JNE     cfgvariant_check_v26
                MOV     DP, #003ceh
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v26:
                CMPB    r6, #01ah
                JNE     cfgvariant_check_v4
                LB      A, 0d7h
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
cfgvariant_eval_result:
                J       cfgvariant_remap_start
cfgvariant_check_v4:
                CMPB    r6, #004h
                JNE     cfgvariant_check_v8
                CMPB    r7, #021h
                JEQ     cfgvariant_eval_result2
                INCB    r0
                SJ      cfgvariant_eval_result2
cfgvariant_check_v8:
                CMPB    r6, #008h
                JNE     cfgvariant_check_v9
                CMPB    r7, #022h
                JEQ     cfgvariant_eval_result2
                INCB    r0
                CMPB    r7, #02ah
                JEQ     cfgvariant_eval_result2
                INCB    r0
                SJ      cfgvariant_eval_result2
cfgvariant_check_v9:
                CMPB    r6, #009h
                JNE     cfgvariant_check_v17
                CMPB    r7, #023h
                JEQ     cfgvariant_eval_result2
                INCB    r0
                SJ      cfgvariant_eval_result2
cfgvariant_check_v17:
                CMPB    r6, #011h
                JNE     cfgvariant_check_v14_29
cfgvariant_eval_result2:
                SJ      cfgvariant_remap_start
cfgvariant_check_v14_29:
                CMPB    r6, #00ch
                JNE     cfgvariant_check_v14_29_cmp_r6
                CMPB    r7, #00ah
                JNE     cfgvariant_check_v14_29_cmp_r6
                INCB    r0
                INCB    r0
                SB      off(0021ah).5
                SJ      cfgvariant_eval_result3
cfgvariant_check_v14_29_cmp_r6:
                CMPB    r6, #00eh
                JEQ     cfgvariant_eval_result3
                CMPB    r6, #01dh
                JNE     cfgvariant_check_v15_16_21
                L       A, (0ffd9h-0ffffh)[USP]
                CMP     A, #08000h
                JLT     cfgvariant_eval_result3
                INCB    r0
cfgvariant_eval_result3:
                SJ      cfgvariant_remap_start
cfgvariant_check_v15_16_21:
                CMPB    r6, #00fh
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #010h
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #013h
                JNE     cfgvariant_check_v15_16_21_cmp_r6
                CMPB    r7, #00fh
                JEQ     cfgvariant_eval_result4
                INCB    r0
                SJ      cfgvariant_eval_result4
cfgvariant_check_v15_16_21_cmp_r6:
                CMPB    r6, #015h
tbl_5e20        EQU     $-2
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #01bh
                JNE     cfgvariant_check_v5_16_17
cfgvariant_eval_result4:
                SJ      cfgvariant_remap_start
cfgvariant_check_v5_16_17:
                CMPB    r6, #005h
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
cfgvariant_check_v1e:
                CMPB    r6, #01fh
                JNE     cfgvariant_check_v1f
                CMPB    r7, #016h
                JNE     cfgvariant_remap_start
                INCB    r0
                SJ      cfgvariant_remap_start
cfgvariant_check_v1f:
                CMPB    r6, #019h
                JEQ     cfgvariant_remap_start
cfgvariant_check_v1f_load_r1:
                MOVB    r1, r6
                RT
cfgvariant_remap_start:
                CLR     A
                LB      A, r6
                CMPB    A, #019h
                JNE     cfgvariant_remap_1a
                LB      A, #023h
                SJ      cfgvariant_remap_store
cfgvariant_remap_1a:
                CMPB    A, #01ah
                JNE     cfgvariant_remap_1b
                LB      A, #024h
                SJ      cfgvariant_remap_store
cfgvariant_remap_1b:
                CMPB    A, #01bh
                JNE     cfgvariant_remap_1d
                LB      A, #029h
                SJ      cfgvariant_remap_store
cfgvariant_remap_1d:
                CMPB    A, #01dh
                JNE     cfgvariant_remap_store
                LB      A, #02bh
cfgvariant_remap_store:
                STB     A, r1
                SRLB    A
                MOV     X1, A
                LB      A, r0
                JGE     cfgvariant_bit_calc
                ADDB    A, #004h
cfgvariant_bit_calc:
                SBR     00324h[X1]
                RT
cfgvariant_snapshot_capture:
                MOV     DP, #00344h
                LB      A, [DP]
                JNE     cfgvariant_snapshot_capture_return
                J       cfgvariant_snapshot_capture_inc_dp
                DB  0FFh,0FFh,0FFh,0FFh
cfgvariant_snapshot_capture_inc_dp:
                INC     DP
                LB      A, 0cch
                STB     A, [DP]
                INC     DP
                L       A, 0c4h
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                MOV     X1, #003d0h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003c8h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0bbh
                STB     A, [DP]
                INC     DP
                MOV     X1, #003c9h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003a0h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0dbh
                STB     A, [DP]
                INC     DP
                MOV     X1, #003a2h
                L       A, 00000h[X1]
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                LB      A, 0dah
                STB     A, [DP]
                INC     DP
                LB      A, (0ffdah-0ffffh)[USP]
                STB     A, [DP]
                INC     DP
                LB      A, 09dh
                STB     A, [DP]
                INC     DP
                J       cfgvariant_snapshot_capture_load_ram2a1
cfgvariant_snapshot_capture_return:
                RT
cfgvariant_check_320h_bit7_sub_clear_acc:
                CLR     A
                J       cfgvariant_check_320h_bit7_sub_load_dp
cfgvariant_state_clear_loop:
                DEC     DP
                DEC     DP
                ST      A, [DP]
                CMP     DP, #0031eh
                JGT     cfgvariant_state_clear_loop
                RT
cfgvariant_ram_init:
                CLR     X1
                L       A, #08000h
                ST      A, 00300h[X1]
                ST      A, 00304h[X1]
                ST      A, 00308h[X1]
                L       A, 00382h[X1]
                ST      A, 0030ch[X1]
                CLRB    A
                STB     A, 00310h[X1]
                STB     A, 0031bh[X1]
                LB      A, #07bh
                STB     A, 00311h[X1]
                LB      A, #03bh
                STB     A, 0031ah[X1]
                L       A, #00266h
                ST      A, 00312h[X1]
                ST      A, 00314h[X1]
                L       A, #00100h
                ST      A, 00316h[X1]
                ST      A, 00318h[X1]
                MOVB    off(002a0h), #0ffh
                RT
cfgvariant_checksum2_calc:
                MOV     DP, #00324h
                LB      A, [DP]
                ANDB    A, #0f0h
                STB     A, r0
                STB     A, r1
cfgvariant_checksum2_loop:
                INC     DP
                LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                CMP     DP, #00353h
                JNE     cfgvariant_checksum2_loop
                RT
boot_completion_helper:
                CLRB    A
                LCB     A, boot_completion_helper_tbl
                SLLB    A
                MB      off(00216h).4, C
                LCB     A, boot_completion_helper_tbl_2
                SLLB    A
                MB      off(00227h).6, C
                J       boot_completion_helper_rom_load_tbl_60eb
                DB  0FFh,0FFh,0FFh,0FFh,0FFh
boot_completion_helper_rom_load_tbl_60eb:
                LCB     A, boot_completion_helper_tbl_3
                SLLB    A
                MB      off(00219h).3, C
                LCB     A, boot_completion_helper_tbl_4
                SLLB    A
                MB      off(00217h).3, C
                LCB     A, boot_completion_helper_tbl_5
                SLLB    A
                MB      off(00227h).7, C
                LCB     A, boot_completion_helper_tbl_6
                SLLB    A
                MB      off(00216h).1, C
                LCB     A, boot_completion_helper_tbl_7
                SLLB    A
                MB      off(00216h).7, C
                MOV     DP, #00356h
                MB      [DP].0, C
                LCB     A, boot_completion_helper_tbl_8
                SLLB    A
                MB      off(00227h).1, C
                MOV     DP, #003c7h
                LB      A, [DP]
                STB     A, r1
                RC
                LCB     A, idle_init_start_tbl
                STB     A, r0
                JNE     boot_completion_helper_store_carry_ram227_bit5
                LCB     A, diag_mode_code_store_tbl
                JEQ     boot_completion_helper_store_carry_ram227_bit5
                LB      A, r1
                SLLB    A
                SLLB    A
                ANDB    r1, #080h
boot_completion_helper_store_carry_ram227_bit5:
                MB      off(00227h).5, C
                MOV     DP, #003cfh
                LB      A, [DP]
                STB     A, r2
                LCB     A, diag_mode_code_store_tbl
                JEQ     boot_completion_helper_load_r2
                SLLB    r2
                MOVB    r2, #080h
                RORB    r2
boot_completion_helper_load_r2:
                LB      A, r2
                CMPB    r0, #000h
                JEQ     boot_completion_helper_sllb_acc
                LCB     A, boot_completion_helper_tbl_9
boot_completion_helper_sllb_acc:
                SLLB    A
                J       boot_completion_helper_store_carry_ram216_bit3
boot_completion_helper_cmp_r0:
                CMPB    r0, #000h
                JEQ     boot_completion_helper_goto_7b55
                LCB     A, boot_completion_helper_tbl_10
                SLLB    A
                SJ      boot_flag_iabv_common
boot_completion_helper_goto_7b55:
                J       boot_completion_helper_set_carry
                DB  0FFh,0FFh,0FFh,0FFh
boot_completion_helper_load_r2_2:
                LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h
boot_flag_iabv_common:
                MB      off(00216h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_iabv_common_goto_7b70
                LCB     A, boot_flag_iabv_common_tbl_3
                SLLB    A
                SJ      boot_flag_iabv_common_goto_7b80
boot_flag_iabv_common_goto_7b70:
                J       boot_flag_iabv_common_set_carry
boot_flag_iabv_common_xorb_pswh:
                XORB    PSWH, #080h
boot_flag_iabv_common_goto_7b80:
                J       boot_flag_iabv_common_store_carry_ram216_bit0
boot_flag_iabv_common_cmp_r0:
                CMPB    r0, #000h
tbl_6000        EQU     $-2
                JEQ     boot_flag_iabv_common_load_carry_ram216_bit2
                LCB     A, boot_flag_iabv_common_tbl_4
                SLLB    A
                SJ      boot_flag_iabv_common_store_carry_pswl_bit4
boot_flag_iabv_common_load_carry_ram216_bit2:
                MB      C, off(00216h).2
                LCB     A, dwell_battery_check2_tbl
                JEQ     boot_flag_iabv_common_store_carry_pswl_bit4
                LB      A, r1
                SLLB    A
                XORB    PSWH, #080h
boot_flag_iabv_common_store_carry_pswl_bit4:
                MB      PSWL.4, C
                CMPB    r0, #000h
                JNE     boot_flag_iabv_common_rom_load_tbl_60e9
                LCB     A, diag_mode_code_store_tbl
                JNE     boot_flag_iabv_common_clear_pswl_bit4
boot_flag_iabv_common_rom_load_tbl_60e9:
                LCB     A, boot_flag_iabv_common_tbl_2
                SLLB    A
                SJ      boot_flag_iabv_common_store_carry_ram227_bit4
boot_flag_iabv_common_clear_pswl_bit4:
                RB      PSWL.4
                LB      A, r1
                SLLB    A
                XORB    PSWH, #080h
boot_flag_iabv_common_store_carry_ram227_bit4:
                MB      off(00227h).4, C
                MB      C, PSWL.4
                MB      off(00217h).6, C
                CMPB    r0, #000h
                JEQ     boot_flag_iabv_common_clear_carry
                LCB     A, boot_flag_iabv_common_tbl_5
                SLLB    A
                SJ      boot_flag_iabv_common_store_carry_ram216_bit5
boot_flag_iabv_common_clear_carry:
                RC
                LCB     A, dwell_battery_check2_tbl
                JNE     boot_flag_iabv_common_store_carry_ram216_bit5
                LB      A, r1
                SLLB    A
boot_flag_iabv_common_store_carry_ram216_bit5:
                MB      off(00216h).5, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt
                LCB     A, boot_flag_iabv_common_tbl_6
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_pswl_bit4
boot_flag_gearpreset_alt:
                LB      A, r1
                SLLB    A
                SLLB    A
boot_flag_gearpreset_alt_store_carry_pswl_bit4:
                MB      PSWL.4, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt_clear_carry
                LCB     A, boot_flag_gearpreset_alt_tbl
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_ram227_bit3
boot_flag_gearpreset_alt_clear_carry:
                RC
                LCB     A, diag_mode_code_store_tbl_2
                JEQ     boot_flag_gearpreset_alt_store_carry_ram227_bit3
                SC
                NOP
                NOP
boot_flag_gearpreset_alt_store_carry_ram227_bit3:
                MB      off(00227h).3, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt_load_carry_pswl_bit4
                LCB     A, boot_flag_gearpreset_alt_tbl_2
                SLLB    A
                SJ      boot_flag_gearpreset_alt_goto_7b9a
boot_flag_gearpreset_alt_load_carry_pswl_bit4:
                MB      C, PSWL.4
boot_flag_gearpreset_alt_goto_7b9a:
                J       boot_flag_gearpreset_alt_if_ram227_bit0_clr
boot_flag_gearpreset_alt_cmp_r0:
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt_clear_carry_2
                LCB     A, boot_flag_gearpreset_alt_tbl_3
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_ram219_bit4
boot_flag_gearpreset_alt_clear_carry_2:
                RC
                JBS     off(00217h).6, boot_flag_gearpreset_alt_store_carry_ram219_bit4
                LCB     A, boot_flag_gearpreset_alt_tbl_3
                JNE     boot_flag_gearpreset_alt_load_dp
                LCB     A, dwell_battery_check2_tbl
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4
                LCB     A, diag_snapshot_copy_loop_tbl_2
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4
                JBR     off(00216h).0, boot_flag_gearpreset_alt_store_carry_ram219_bit4
boot_flag_gearpreset_alt_load_dp:
                MOV     DP, #003ceh
                CMPB    [DP], #09ah
boot_flag_gearpreset_alt_store_carry_ram219_bit4:
                MB      off(00219h).4, C
                CMPB    r0, #000h
                JEQ     boot_flag_3cf_check
                LCB     A, boot_flag_gearpreset_alt_tbl_4
                SLLB    A
                SJ      boot_flag_final
boot_flag_3cf_check:
                MOV     DP, #003cbh
                CMPB    [DP], #080h
                XORB    PSWH, #080h
boot_flag_final:
                MOV     DP, #00356h
                MB      [DP].1, C
                L       A, #00700h
                JBS     off(00216h).3, boot_flag_final_load_dp
                L       A, #00500h
boot_flag_final_load_dp:
                MOV     DP, #00382h
                ST      A, [DP]
                RT
fuelmap_base_lookup_tbl:       DB  000h
boot_completion_helper_tbl:       DB  0FFh
boot_completion_helper_tbl_2:       DB  000h
boot_flag_iabv_common_tbl:       DB  000h
boot_flag_iabv_common_tbl_2:       DB  000h
diag_mode_code_store_tbl:       DB  000h
boot_completion_helper_tbl_3:       DB  0FFh
boot_completion_helper_tbl_4:       DB  0FFh
boot_completion_helper_tbl_5:       DB  000h
boot_completion_helper_tbl_6:       DB  0FFh
ignition_cut_mode_check_tbl:       DB  0FFh
boot_completion_helper_tbl_7:       DB  000h
boot_completion_helper_tbl_8:       DB  000h
dwell_battery_check2_tbl:       DB  000h
diag_mode_code_store_tbl_2:       DB  000h
diag_snapshot_copy_loop_tbl:       DB  000h
diag_snapshot_copy_loop_tbl_2:       DB  000h
diag_mode_code_store_tbl_3:       DB  000h
diag_mode_code_store_tbl_4:       DB  000h
injtimer_critsection_start_tbl:       DB  000h
ect_threshold_224_6_tbl:       DB  0FFh
vtec_engage_conditions_start_tbl:       DB  000h
idle_init_start_tbl:       DB  000h
boot_completion_helper_tbl_9:       DB  000h
boot_completion_helper_tbl_10:       DB  0FFh
boot_flag_iabv_common_tbl_3:       DB  0FFh
boot_flag_iabv_common_tbl_4:       DB  0FFh
boot_flag_iabv_common_tbl_5:       DB  000h
boot_flag_iabv_common_tbl_6:       DB  000h
boot_flag_gearpreset_alt_tbl:       DB  000h
boot_flag_gearpreset_alt_tbl_2:       DB  000h
boot_flag_gearpreset_alt_tbl_3:       DB  000h
boot_flag_gearpreset_alt_tbl_4:       DB  0FFh
deadtime_voltage_flag_store_tbl:       DB  006h,006h,006h,00Ah,00Bh,00Bh
tbl_tps_custom_curve:       DB  004h,018h,004h,018h
tbl_tps_custom_curve2:       DB  030h,040h,030h,040h,030h,040h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
knockwindow_next_table_tbl:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h
                DB  044h,042h,028h,041h,000h,040h
knockwindow_next_table_tbl_2:       DB  0FFh,066h,0E6h,058h,0CFh,053h,0A1h,050h
                DB  044h,04Ch,028h,041h,000h,040h
knockwindow_next_table_tbl_3:       DB  0FFh,040h,000h,040h,000h,040h,000h,040h
                DB  000h,040h,000h,040h,000h,040h
knockwindow_next_table_tbl_4:       DB  0FFh,066h,0E6h,058h,0CFh,053h,0A1h,046h
                DB  044h,043h,02Eh,040h,000h,040h
knockwindow_next_table_tbl_5:       DB  0FFh,093h,0E6h,080h,0CFh,073h,0A1h,056h
                DB  044h,046h,02Eh,040h,000h,040h
knockwindow_next_table_tbl_6:       DB  0FFh,064h,0E6h,056h,0CFh,053h,0A1h,050h
                DB  044h,04Ch,028h,041h,000h,040h
IATFuelCorrect:       DB  0FFh,0E1h,09Ah,0F5h,0E1h,09Ah,0E1h,0A3h
                DB  090h,0BAh,0AEh,087h,087h,000h,080h,034h
                DB  052h,078h,000h,052h,078h
PostFuelDecay:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h
PostFuelDecay2:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h
PostFuelDecay3:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h
postfuel_calc_start_tbl:       DB  0FFh,0CDh,084h,0F1h,033h,083h,0E6h,09Ah
                DB  079h,0CFh,0CDh,05Ch,0A1h,000h,040h,07Ah
                DB  0D7h,033h,040h,0C2h,025h,000h,0C2h,025h
o2trim_ect_offset_lookup_tbl:       DB  001h,000h,000h,001h,001h,000h,000h,002h
                DB  001h,000h,000h,004h
tbl_revlimit_cold1:       DB  0AEh,028h,0A1h,034h
tbl_revlimit_cold2:       DB  0B5h,02Eh,0A9h,062h
tbl_revlimit_cold3:       DB  0B5h,02Eh,0A9h,062h
CloseLoopRate:       DB  06Fh,000h,06Fh,000h,06Fh,000h,06Fh,000h
                DB  030h,000h,000h,000h,06Fh,000h,06Fh,000h
                DB  06Fh,000h,06Fh,000h,030h,000h,000h,000h
CloseLoopGoose:       DB  07Ch,003h,05Ah,004h,05Ah,004h,05Ah,004h
                DB  080h,000h,000h,000h,07Ch,003h,0CAh,004h
                DB  0CAh,004h,0CAh,004h,080h,000h,000h,000h
                DB  06Fh,000h,06Fh,000h,06Fh,000h,06Fh,000h
                DB  030h,000h,000h,000h,06Fh,000h,06Fh,000h
                DB  06Fh,000h,06Fh,000h,030h,000h,000h,000h
                DB  07Ch,003h,05Ah,004h,05Ah,004h,05Ah,004h
                DB  080h,000h,000h,000h,07Ch,003h,0CAh,004h
                DB  0CAh,004h,0CAh,004h,080h,000h,000h,000h
tbl_closeloop_tps:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C5h,0D0h
                DB  0C0h,0EAh,04Dh,0EAh,040h,0AEh,000h,0AEh
tbl_revlimit_warm1:       DB  0EEh,000h,0A0h,030h
ve_adjust2_gate_tbl:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C5h,0D0h
                DB  0C0h,0EAh,04Dh,0EAh,040h,0AEh,000h,0AEh
VEFuelCorrect:       DB  0FFh,080h,01Fh,080h,018h,080h,013h,08Bh
                DB  000h,08Bh,000h,08Bh
CloseLoopTPS:       DB  0FFh,094h,0D0h,094h,0A0h,088h,080h,069h
                DB  040h,05Eh,000h,052h
OpenLoopTPS:       DB  0FFh,09Ah,0D0h,09Ah,0A0h,08Dh,080h,073h
                DB  040h,066h,000h,05Ah
tbl_ve_accel_1:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h
tbl_ve_accel_2:       DB  0FFh,080h,000h,080h,000h,080h,000h,080h
                DB  000h,080h,000h,080h
tbl_knockwindow_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
tbl_knockwindow_4:       DB  0FFh,08Eh,0A1h,08Eh,087h,071h,06Eh,05Eh
                DB  034h,04Bh,028h,03Dh,000h,03Dh
knockwindow_next_table_tbl_7:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,06Dh
                DB  034h,060h,028h,04Dh,000h,04Dh
knockwindow_next_table_tbl_8:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,050h
                DB  034h,043h,028h,030h,000h,030h
CylinderIGNCorrect:       DB  080h,080h,080h,080h
tbl_revlimit_warm2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
tbl_injtimer_finalize:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
knock_table2d_lookup_tbl:       DB  0FFh,064h,000h,0A7h,067h,000h,093h,094h
                DB  000h,07Eh,0C3h,000h,069h,054h,001h,054h
                DB  080h,002h,000h,080h,002h
tbl_tipin_enrich_rpm:       DB  050h,020h,003h,000h,000h,000h,030h,0EEh
                DB  002h,000h,019h,000h,020h,020h,003h,000h
                DB  032h,000h,030h,0EEh,002h,000h,019h,000h
                DB  030h,0E8h,003h,000h,04Bh,000h,020h,0B6h
                DB  003h,000h,019h,000h,030h,065h,004h,000h
                DB  050h,000h,030h,0E8h,003h,000h,032h,000h
                DB  040h,065h,004h,000h,050h,000h
tbl_tipin_normal_enrich:       DB  090h,001h,000h,001h,010h,000h,0FAh,000h
                DB  0FAh,000h,018h,000h,05Eh,001h,0FAh,000h
                DB  010h,000h,0C2h,001h,02Ch,001h,018h,000h
                DB  0C2h,001h,02Ch,001h,018h,000h,0F4h,001h
                DB  02Ch,001h,010h,000h,0F4h,001h,02Ch,001h
                DB  010h,000h,058h,002h,02Ch,001h,010h,000h
                DB  058h,002h,02Ch,001h,010h,000h
Tipintempoffsetnormal:       DB  0FFh,04Dh,000h,0A2h,04Dh,000h,040h,080h
                DB  000h,028h,000h,001h,000h,000h,001h,000h
                DB  000h,001h
Tipintempoffsetinitial:       DB  0FFh,04Dh,000h,0A2h,04Dh,000h,040h,080h,000h,028h
                DB  000h,001h,000h,000h,001h,000h,000h,001h,010h,0E6h
                DB  000h,002h,000h,001h,050h,0F3h,000h,008h,000h,001h
tbl_tipin_low:       DB  050h,0E6h,000h,010h,000h,001h,050h,0E6h
                DB  000h,010h,000h,001h
tbl_revlimit_cold4:       DB  0FFh,080h,000h,080h
tbl_rpm_decel:       DB  0FFh,008h,000h,08Bh,008h,000h,080h,018h
                DB  000h,060h,050h,000h,040h,070h,000h,020h
                DB  0A0h,000h,000h,0C0h,000h
tbl_knockwindow_5:       DB  0FFh,07Dh,000h,000h,07Dh,000h,000h,07Dh
                DB  000h,000h,07Dh,000h,000h,07Dh,000h
tbl_knockwindow_6:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,010h,000h,010h
knockwindow_next_table_tbl_9:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,010h,000h,010h
tbl_knockwindow_7:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  06Eh,020h,028h,008h,000h,008h
knockwindow_next_table_tbl_10:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  06Eh,020h,028h,008h,000h,008h
knockwindow_next_table_tbl_11:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,010h,000h,010h
tbl_knockwindow_8:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,010h,000h,010h
Cranking_tbl:       DB  0FFh,0D2h,05Ah,0F1h,0D2h,05Ah,0E6h,0CDh
                DB  046h,0CFh,010h,027h,0A1h,06Ah,018h,087h
                DB  09Ah,010h,040h,02Eh,009h,028h,098h,008h
                DB  000h,098h,008h,0FFh,0FFh,0FFh,0FFh
CrankFuelMap:       DB  0FFh,080h,000h,080h
Overrun_Resume_int:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
Overrun_Resume_nor:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h
                DB  034h,04Dh,028h,03Fh,000h,03Fh
knockwindow_next_table_tbl_12:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
knockwindow_next_table_tbl_13:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h
                DB  034h,04Dh,028h,03Fh,000h,03Fh
tbl_ignmap2_lo:       DB  0FFh,020h,0E0h,020h,0D0h,01Bh,0C0h,015h
                DB  0A0h,00Fh,000h,00Fh
tbl_ignmap2_hi:       DB  0FFh,018h,0E0h,018h,0D0h,013h,0C0h,00Dh
                DB  0A0h,007h,000h,007h
tbl_revlimit_warm3:       DB  0FFh,000h,000h,000h
tbl_threshold_223_1:       DB  01Eh,02Bh,001h,001h,04Eh,001h
Revlimiters:       DB  01Eh,02Bh,0FDh,000h,002h,001h
tbl_threshold_223_2:       DB  01Eh,02Bh,001h,001h,04Eh,001h
dwell_battery_check2_tbl_2:       DB  01Eh,02Bh,0FDh,000h
dwell_battery_check2_tbl_3:       DB  002h,001h,028h,05Ah,028h,04Dh,028h,040h
                DB  028h,040h,028h,040h
knock_table_index_tbl:       DB  033h,073h,09Ah,079h,000h,080h,066h,086h
                DB  0CDh,08Ch,0CDh,08Ch,033h,073h,09Ah,079h
                DB  000h,080h,066h,086h,0CDh,08Ch,0CDh,08Ch
tbl_knock_div:       DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h
                DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h
knock_div_calc4_tbl:       DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h
                DB  05Ah,004h,0CAh,004h,039h,005h,0A9h,005h
                DB  018h,006h,018h,006h,0F7h,006h,067h,007h
                DB  0D6h,007h,046h,008h,0B5h,008h,0B5h,008h
GearCustom:       DB  04Ah,000h,07Eh,000h,0B7h,000h,0ECh,000h
knock_table2d_lookup_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,080h
newval_table3_call_tbl:       DB  0FFh,0FFh,000h,0FFh
newval_table3_call_tbl_2:       DB  0FFh,0FFh,000h,0FFh
vtec_engage_gate_start_tbl:       DB  0CAh,0CDh,0D5h,0D8h
vtec_engage_gate_start_tbl_2:       DB  0CAh,0CDh,0D5h,0D8h
vtec_engage_gate_start_tbl_3:       DB  0FFh,03Fh,0D5h,03Fh,0CAh,0AEh,000h,0AEh
                DB  000h,0AEh,000h,0AEh,000h,0AEh
vtec_engage_gate_start_tbl_4:       DB  0FFh,03Fh,0D5h,03Fh,0CAh,0AEh,000h,0AEh
                DB  000h,0AEh,000h,0AEh,000h,0AEh
revlimit_table_select_tbl:       DB  0FFh,000h,000h,000h
vcal3_leanprotect_ratelimit_tbl:       DB  0FFh,001h,09Fh,001h,09Bh,013h,06Eh,013h
                DB  05Ah,013h,041h,005h,000h,005h
vcal3_leanprotect_ratelimit_tbl_2:       DB  0FFh,096h,0CFh,096h,0CEh,07Fh,088h,051h
                DB  04Eh,02Ch,041h,020h,038h,014h,02Ch,00Fh
                DB  000h,00Fh
vcal3_leanprotect_ratelimit_tbl_3:       DB  0FFh,0A5h,0CFh,0A5h,0CEh,08Fh,07Eh,064h
                DB  065h,051h,04Eh,044h,034h,033h,02Ch,02Dh
                DB  000h,02Dh
vcal3_leanprotect_ratelimit_tbl_4:       DB  0FFh,065h,0CFh,065h,0CEh,041h,08Fh,033h
                DB  068h,026h,04Eh,019h,044h,014h,02Ch,00Fh
                DB  000h,00Fh
vcal3_leanprotect_ratelimit_tbl_5:       DB  0FFh,071h,0CFh,071h,0CEh,05Fh,0ADh,052h
                DB  073h,040h,04Eh,032h,041h,02Bh,02Ch,021h
                DB  000h,021h
vcal3_leanprotect_ratelimit_tbl_6:       DB  0FFh,02Eh,0CFh,02Eh,0CEh,027h,07Ch,016h
                DB  04Eh,011h,041h,00Fh,034h,00Dh,02Ch,00Ch
                DB  000h,00Ch
vcal3_leanprotect_ratelimit_tbl_7:       DB  0FFh,03Bh,0CFh,03Bh,0CEh,033h,08Fh,028h
                DB  068h,01Eh,04Ch,016h,034h,013h,02Ch,011h
                DB  000h,011h
vcal3_leanprotect_ratelimit_tbl_8:       DB  075h,004h,0B0h,006h,0A0h,00Bh,0DEh,03Ah
                DB  02Eh,003h,053h,004h,022h,006h,051h,00Bh
vcal3_leanprotect_ratelimit_tbl_9:       DB  0FFh,0FAh,0B0h,0FAh,09Bh,0FAh,082h,0FAh
                DB  080h,09Ch,078h,092h,064h,076h,05Ah,069h
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h
vcal3_leanprotect_ratelimit_tbl_10:       DB  0FFh,0FAh,0B0h,0FAh,08Eh,0FAh,087h,0FAh
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h
vcal3_leanprotect_ratelimit_tbl_11:       DB  0FFh,0FAh,09Ch,0FAh,09Ah,0B6h,096h,0B6h
                DB  085h,0A2h,078h,092h,064h,076h,05Ah,069h
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h
vcal3_leanprotect_ratelimit_tbl_12:       DB  0FFh,0FAh,0A1h,0FAh,09Fh,0A3h,09Bh,0A3h
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h
vcal3_leanprotect_ratelimit_tbl_13:       DB  0FFh,014h,0B4h,014h,04Eh,014h,04Ch,003h,000h,003h
vcal3_leanprotect_ratelimit_tbl_14:       DB  0FFh,01Bh,0B4h,01Bh,04Eh,01Bh,04Ch,006h,000h,006h
vcal3_leanprotect_ratelimit_tbl_15:       DB  0FFh,080h,000h,010h,080h,000h,008h,060h
                DB  000h,004h,000h,001h,000h,000h,000h
vcal3_leanprotect_ratelimit_tbl_16:       DB  0FFh,080h,000h,012h,010h,000h,008h,040h
                DB  000h,004h,080h,000h,000h,000h,000h
vcal3_leanprotect_ratelimit_tbl_17:       DB  0FFh,02Ch,050h,02Ch,03Ch,01Eh,028h,01Eh
                DB  019h,01Ch,014h,01Ch,000h,01Ch
vcal3_leanprotect_ratelimit_tbl_18:       DB  0FFh,038h,050h,038h,03Ch,032h,028h,032h
                DB  019h,02Eh,014h,02Ah,000h,020h
vcal3_leanprotect_ratelimit_tbl_19:       DB  0FFh,033h,078h,033h,050h,02Eh,03Ch,01Eh
                DB  028h,01Eh,014h,01Ch,000h,01Ch
vcal3_leanprotect_ratelimit_tbl_20:       DB  0FFh,03Fh,078h,03Fh,050h,03Ah,03Ch,035h
                DB  028h,033h,014h,02Ah,000h,020h
idle_init_start_tbl_2:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh
idle_init_start_tbl_3:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh
knockwindow_next_table_tbl_14:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,000h,0FFh
tps_hysteresis_reentry_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,000h,0FFh
to_vtec_debounce_store_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
knockretard_clear_state_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,000h,0FFh
knockretard_clear_state_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,000h,0FFh
tbl_vtec_transition_retard:       DB  000h,000h,011h,055h,077h,0FFh
knockwindow_next_table_tbl_15:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh,0FFh
ignmap_alt_path_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh
ignmap_alt_path_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh
ZoneIndexTable1_SetB:       DB  0FFh,000h,014h,0F0h,000h,014h,0E0h,000h
                DB  00Ah,0CAh,000h,00Ch,080h,000h,010h,060h
                DB  000h,00Eh,035h,000h,007h,028h,000h,000h
                DB  000h,000h,000h
knockwindow_next_table_tbl_16:       DB  0FFh,000h,017h,0F0h,000h,017h,0E0h,000h
                DB  010h,0CAh,000h,011h,090h,000h,01Dh,070h
                DB  000h,01Bh,035h,000h,008h,028h,000h,000h
                DB  000h,000h,000h
idle_mode_dispatch_tbl:       DB  0FFh,000h,026h,0F0h,000h,026h,0E0h,000h
                DB  013h,0CAh,000h,013h,080h,000h,015h,060h
                DB  000h,012h,035h,000h,00Bh,028h,000h,009h
                DB  000h,000h,009h
ZoneIndexTable3_SetA:       DB  0FFh,000h,02Ah,0F0h,000h,02Ah,0E0h,000h
                DB  01Bh,0CAh,000h,019h,090h,000h,025h,070h
                DB  000h,021h,035h,000h,00Eh,028h,000h,00Ah
                DB  000h,000h,00Ah
ZoneIndexTable2_SetB:       DB  0FFh,000h,019h,0F0h,000h,019h,0E0h,000h
                DB  00Eh,0CAh,000h,010h,080h,000h,014h,060h
                DB  000h,011h,035h,000h,00Ah,028h,000h,008h
                DB  000h,000h,008h
ZoneIndexTable2_SetA:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h
                DB  015h,0CAh,000h,016h,090h,000h,024h,070h
                DB  000h,020h,035h,000h,00Dh,028h,000h,009h
                DB  000h,000h,009h
IdleVsECT:       DB  0FFh,0E2h,004h,0A1h,03Bh,005h,087h,0A2h
                DB  005h,06Eh,01Bh,006h,034h,00Bh,009h,028h
                DB  035h,00Ch,000h,035h,00Ch
idle_target_correction_done_tbl:       DB  0FFh,0E2h,004h,0A1h,0E2h,004h,087h,03Bh
                DB  005h,06Eh,0A2h,005h,034h,023h,008h,028h
                DB  00Bh,009h,000h,00Bh,009h
idle_temp_hyst3_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h
                DB  034h,050h,028h,042h,000h,042h,0FFh,09Ah
                DB  0A1h,09Ah,087h,083h,06Eh,073h,034h,066h
                DB  028h,04Dh,000h,04Dh
idle_target_correction_done_tbl_2:       DB  0FFh,092h,0A1h,092h,087h,07Ah,06Eh,073h
                DB  034h,05Dh,028h,04Dh,000h,04Dh,0FFh,09Ah
                DB  0A1h,09Ah,087h,086h,06Eh,083h,034h,070h
                DB  028h,05Ah,000h,05Ah
tbl_idle_default1:       DB  0FFh,0FFh,06Bh,000h,035h,00Ch,06Bh,000h
                DB  0C4h,009h,044h,000h,00Bh,009h,03Ah,000h
                DB  053h,007h,026h,000h,04Eh,004h,00Eh,000h
                DB  000h,000h,00Eh,000h
tbl_idle_default2:       DB  0FFh,0FFh,095h,000h,035h,00Ch,095h,000h
                DB  0C4h,009h,061h,000h,00Bh,009h,053h,000h
                DB  053h,007h,037h,000h,04Eh,004h,013h,000h
                DB  000h,000h,013h,000h
tbl_idle_lookup4:       DB  0FFh,0FFh,0BFh,001h,035h,00Ch,0BFh,001h
                DB  0C4h,009h,027h,001h,00Bh,009h,0FFh,000h
                DB  053h,007h,0ABh,000h,04Eh,004h,03Dh,000h
                DB  000h,000h,03Dh,000h
tbl_idle_lookup3:       DB  000h,080h,000h,004h,000h,008h
tbl_idle_select_default:       DB  000h,0F0h,000h,008h,000h,00Eh
tbl_idle_timer:       DB  000h,040h,000h,006h,000h,006h
idle_table_select2_tbl:       DB  000h,0F0h,0C0h,000h,050h,000h
tbl_idle_gear2:       DB  000h,000h,000h,080h,001h,000h
tbl_idle_select1:       DB  000h,0F0h,000h,040h,000h,000h
tbl_idle_select3a:       DB  0FFh,080h,001h,050h,080h,001h,030h,080h
                DB  002h,000h,000h,003h,000h,000h,003h,000h
                DB  000h,003h
idle_table_select3_tbl:       DB  0FFh,080h,001h,057h,080h,001h,03Ch,080h
                DB  002h,02Eh,000h,004h,028h,000h,00Ah,000h
                DB  000h,00Ch
tbl_idle_stall:       DB  0FFh,000h,000h,000h
tbl_ect_vecorrect:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h
                DB  034h,050h,028h,042h,000h,042h
tbl_idle_gate6:       DB  0FFh,014h,000h,034h,014h,000h,028h,030h
                DB  000h,000h,030h,000h,000h,030h,000h,000h
                DB  030h,000h,000h,030h,000h
tbl_ect_overrun_nor:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh
                DB  000h,0FFh,000h,0FFh,000h,0FFh
tbl_idle_sub1:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah
                DB  034h,009h,028h,007h,000h,007h
tbl_idle_sub2:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah
                DB  034h,009h,028h,007h,000h,007h
tbl_idle_pid_lo1:       DB  0FFh,0C0h,040h,0C0h,028h,0A5h,01Ah,080h
                DB  013h,080h,000h,06Bh
tbl_idle_pid_lo2:       DB  0FFh,0A8h,040h,0A8h,028h,08Dh,020h,080h
                DB  013h,060h,000h,040h
tbl_idle_pid_lo3:       DB  0FFh,09Ch,040h,09Ch,028h,080h,020h,074h
                DB  013h,062h,000h,05Ah
tbl_idle_pid_a:       DB  0FFh,0A8h,040h,0A8h,028h,08Dh,020h,080h
                DB  013h,060h,000h,040h
tbl_idle_pid_b:       DB  0FFh,09Ch,040h,09Ch,028h,080h,020h,074h
                DB  013h,062h,000h,05Ah
tbl_idle_pid_hi1:       DB  0FFh,000h,006h,0B0h,010h,004h,098h,0F0h
                DB  002h,080h,090h,001h,070h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_hi2:       DB  0FFh,0B0h,007h,0A0h,020h,005h,088h,0E0h
                DB  003h,070h,000h,002h,060h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_hi3:       DB  0FFh,000h,007h,0A0h,080h,004h,088h,080h
                DB  003h,068h,040h,001h,054h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_c:       DB  0FFh,0B0h,007h,0A0h,020h,005h,088h,0E0h
                DB  003h,070h,000h,002h,060h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_d:       DB  0FFh,000h,007h,0A0h,080h,004h,088h,080h
                DB  003h,068h,040h,001h,054h,000h,000h,000h
                DB  000h,000h
tbl_ect_overrun_int:       DB  0FFh,0C0h,0A1h,0C0h,044h,0ADh,028h,080h,000h,080h
tbl_idle_pid_final1:       DB  0FFh,000h,00Bh,0C0h,000h,00Ch,060h,000h
                DB  00Eh,030h,000h,013h,000h,000h,016h
idle_pid_store_final_tbl:       DB  0FFh,000h,00Bh,0C0h,000h,00Ch,060h,000h
                DB  00Eh,030h,000h,013h,000h,000h,016h
tbl_idle_pid_final2:       DB  0FFh,0C0h,0B0h,0C0h,080h,098h,053h,080h,000h,080h
inc_dp_step_tbl:       DB  0FFh,000h,00Eh,0D0h,000h,00Eh,0BAh,000h
                DB  00Eh,094h,000h,00Dh,055h,000h,008h,042h
                DB  000h,006h,028h,080h,000h,000h,080h,000h
                DB  000h,080h,000h
inc_dp_step_tbl_2:       DB  0FFh,0FFh,080h,000h,035h,00Ch,080h,000h,0C4h,009h
                DB  000h,005h,00Bh,009h,000h,007h,000h,000h,080h,007h
ModePageTable_SetA:       DB  040h,000h,010h,008h,000h,000h
ModePageTable_SetB:       DB  040h,0FFh,03Fh,008h,000h,000h
tbl_idle_pid_out2:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,066h,000h
                DB  020h,040h,000h,010h,000h,000h,006h
tbl_idle_sub_gate1:       DB  0FFh,000h,00Ah,0C0h,000h,00Ah,080h,000h
                DB  00Ah,060h,000h,008h,000h,000h,005h
tbl_idle_sub_gate2:       DB  0FFh,000h,00Bh,0C0h,000h,00Bh,080h,000h
                DB  00Bh,060h,000h,009h,000h,000h,006h
tbl_ve_map_scalar_alt:       DB  0FFh,0FFh,03Fh,055h,0FFh,03Fh,039h,000h
                DB  00Ah,02Ch,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
tbl_ve_map_scalar:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,0A0h,000h
                DB  020h,080h,000h,00Ah,064h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
idle_stall_trigger_tbl:       DB  0FFh,000h,010h,0D0h,000h,00Ah,0A0h,000h
                DB  007h,060h,000h,005h,028h,000h,003h,000h
                DB  000h,003h
idle_stall_trigger_tbl_2:       DB  0FFh,060h,000h,0D0h,040h,000h,0A0h,020h
                DB  000h,060h,010h,000h,028h,00Ch,000h,000h
                DB  00Ch,000h
idle_stall_trigger_tbl_3:       DB  0FFh,004h,000h,0D0h,003h,000h,0A0h,002h
                DB  000h,060h,002h,000h,028h,002h,000h,000h
                DB  001h,000h
tbl_iat_correct1:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h
tbl_iat_correct2:       DB  0FFh,080h,000h,080h
knockwindow_next_table_tbl_17:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
tbl_knockwindow_9:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
tbl_idle_gear_target:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,0CDh,0ACh
                DB  048h,031h,09Ah,099h,0B0h,017h,09Ah,079h
                DB  070h,00Ah,000h,060h,0E2h,004h,033h,053h
                DB  080h,001h,066h,046h,000h,000h,066h,026h
tbl_idle_dc:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h
                DB  000h,006h,08Fh,082h,080h,003h,014h,07Eh
                DB  080h,002h,00Ah,077h,080h,001h,0AEh,067h
                DB  000h,001h,0C2h,055h,000h,000h,0C2h,055h
state_21a_7_dispatch2_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
state_21a_7_dispatch2_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
DwellBaseValues:       DB  0FFh,0B8h,0ABh,09Ah,055h,05Ch,047h,055h
                DB  039h,04Dh,02Bh,03Ch,00Bh,010h,000h,010h
DwellBattery:       DB  0FFh,01Ch,0BCh,02Eh,0A7h,034h,092h,040h,07Dh,050h
                DB  068h,068h,054h,0A0h,03Fh,0D9h,000h,0D9h,000h,0D9h
dwell_base_lookup_tbl:       DB  0FFh,03Bh,0AAh,025h,071h,017h,038h,009h
                DB  01Ch,002h,013h,000h,000h,000h
tbl_knockwindow_10:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
tbl_ignmap_idle1:                 DW  064d4h
knockwindow_next_table_tbl_18:       DB  0FFh,06Fh,0E6h,067h,0BFh,049h,094h,02Ah
                DB  057h,011h,028h,000h,000h,000h
knockwindow_next_table_tbl_19:       DB  0FFh,05Ah,0E6h,051h,0BFh,033h,094h,022h
                DB  057h,011h,028h,000h,000h,000h
tbl_ignmap_idle2:       DB  077h,064h,0C1h,064h
knockwindow_next_table_tbl_20:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
tbl_ect_fuelcorrect:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,00Dh
                DB  00Fh,015h,000h,015h
iat_map_correction_chain_tbl:       DB  0FFh,000h,06Ch,000h,044h,00Ch,02Eh,015h,000h,015h
HiIdleIgnControl:       DB  0FFh,0FFh,011h,000h,000h,001h,00Ch,000h
                DB  040h,000h,008h,000h,000h,000h,000h,000h
IgnControl:       DB  0FFh,0FFh,00Ch,000h,0D9h,000h,00Ch,000h
                DB  03Dh,000h,008h,000h,000h,000h,000h,000h
dwell_scale_shift_tbl:       DB  000h,000h,000h,000h,000h,000h,000h,000h,015h,037h
                DB  03Eh,044h,048h,04Bh,060h,072h,070h,062h,062h,062h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,015h,037h,044h,060h,077h,062h
dwell_scale_shift_tbl_2:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  004h,01Dh,022h,033h,037h,02Ah,03Bh,03Bh
                DB  03Bh,04Dh,04Dh,04Dh,000h,000h,000h,000h
                DB  000h,000h,000h,000h,004h,01Dh,022h,033h
                DB  037h,02Ah,03Bh,03Bh,03Bh,04Dh,04Dh
clamp_result_store_tbl:       DB  04Dh
knockretard_clear_state_tbl_3:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h
                DB  000h,000h,000h,000h
knockretard_clear_state_tbl_4:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h
                DB  000h,000h,000h,000h
TipinTPS:       DB  0FFh,05Ah,0D0h,05Ah,0C0h,05Ah,0A0h,04Dh
                DB  080h,040h,040h,033h,000h,033h
TipinRPM:       DB  0FFh,02Ah,0A0h,040h,090h,04Ch,080h,04Ch
                DB  066h,044h,040h,040h,000h
tipin_enrich_lookup_tbl:       DB  02Ah,001h,002h,003h,002h,001h
TipinRetard:       DB  0FFh,080h,080h,080h,067h,080h,04Dh,066h
                DB  040h,040h,000h,000h
callhelper_table_interp_lookup_tbl:       DB  0FFh,000h,0D4h,000h,0D0h,00Eh,0C8h,00Ch
                DB  0B0h,00Eh,0A0h,00Eh,098h,000h,000h,000h
                DB  000h,000h
knockretard_clear_state_tbl_5:       DB  0FFh,000h,09Ah,00Ch,052h,040h,033h,040h
                DB  026h,015h,000h,000h
TipinGear:       DB  000h,080h,046h,046h,046h,0FFh,0FFh,0FFh
tbl_map_sign:       DB  060h,0F0h,020h,060h
tbl_ect_simulate_ramp:       DB  0DFh,0CFh,0A1h,057h,028h
tbl_dcode14_lo:       DB  0C2h,000h,0FAh,03Eh,000h,047h
tbl_dcode14_hi:       DB  0E5h,000h,051h,03Eh,000h,019h
revlimiter_engage_resume_check_tbl:       DB  06Bh,0A9h,02Bh,062h
tbl_knock244_a:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
tbl_knock244_b:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
int_serial_rx_tbl:       DB  000h,000h,000h,000h,000h,000h,09Dh,003h
                DB  09Ch,003h,09Bh,003h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,0ACh,003h
                DB  0ADh,003h,0AEh,003h,0AFh,003h,0B0h,003h
                DB  0B1h,003h,0B2h,003h,0B3h,003h,0D0h,003h
                DB  0C8h,003h,0BBh,000h,0C9h,003h,0A0h,003h
                DB  0DAh,000h,000h,004h,0DBh,000h,0A1h,003h
                DB  0CEh,003h,0D7h,000h,0A1h,002h,0CEh,003h
                DB  000h,004h,000h,004h,000h,004h,05Bh,001h
                DB  000h,004h,005h,003h,000h,004h,09Fh,003h
                DB  09Eh,003h,05Bh,003h,046h,002h,0A9h,003h
                DB  09Dh,000h,0AAh,003h,09Fh,002h,09Eh,002h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  0AEh,001h,0AFh,001h,0ADh,001h,0B6h,001h
                DB  0B7h,001h,0B5h,001h,0ABh,003h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,024h,003h
                DB  025h,003h,026h,003h,027h,003h,028h,003h
                DB  029h,003h,02Ah,003h,02Bh,003h,02Ch,003h
                DB  02Dh,003h,02Eh,003h,02Fh,003h,030h,003h
                DB  031h,003h,032h,003h,033h,003h,034h,003h
                DB  035h,003h,036h,003h,037h,003h,038h,003h
                DB  039h,003h,03Ah,003h,03Bh,003h,03Ch,003h
                DB  03Dh,003h,03Eh,003h,03Fh,003h,040h,003h
                DB  041h,003h,042h,003h,043h,003h,044h,003h
                DB  045h,003h,046h,003h,047h,003h,048h,003h
                DB  049h,003h,04Ah,003h,04Bh,003h,04Ch,003h
                DB  04Dh,003h,04Eh,003h,04Fh,003h,050h,003h
                DB  051h,003h,052h,003h,053h,003h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,0A4h,003h
                DB  0A5h,003h,0A6h,003h,0A7h,003h,0A8h,003h
                DB  000h,004h,000h,004h,000h,004h,02Dh,02Dh
                DB  007h,006h,0FFh,0FFh,0FFh,078h,019h,019h
                DB  019h,0B3h
dtc_scan_new_code_tbl:       DB  00Bh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh
                DB  0FFh,0FFh,0FFh,0FFh,02Dh,02Dh,0FFh,02Dh
                DB  02Dh,006h,02Dh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,02Dh,02Dh,007h,006h,0FFh,0FFh,0FFh
                DB  078h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh
                DB  0B3h
cfgvariant_index_lookup_tbl:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah
                DB  00Bh,00Ch,00Ch,00Dh,00Eh,011h,000h,013h
                DB  014h,015h,016h,017h,018h,01Eh,01Fh,000h
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h
                DB  000h,004h,008h,009h,00Fh,01Eh,01Fh,010h
                DB  013h,004h,008h,009h,000h,000h,000h,000h
                DB  01Dh
knock_324_bit_store_tbl:       DB  010h,093h,003h
crank_edge_flag_store_tbl:       DB  0FFh,0FFh,000h,0FFh,000h,0FFh,000h,0FFh
                DB  000h,0FFh,000h,0FFh
tbl_diag_snapshot_data2:       DB  0FFh,078h,019h,019h,019h
tbl_crank_sync_pattern:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FEh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FDh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FEh,0FFh,0FFh,0FFh,0FFh,0FFh,0FDh
tbl_crank_tooth_pattern:       DB  007h,008h,009h,00Ah,00Bh,000h,001h,002h,003h,004h
                DB  005h,006h,007h,008h,009h,00Ah,00Bh,000h,001h,002h
                DB  003h,004h,005h,006h,007h,008h,009h,00Ah,00Bh,000h
fueltbl_sanitize_advance_tbl:       DB  000h,000h,077h,022h,0EEh,044h,077h,044h
                DB  0DDh,088h,0FFh,0FFh,0EEh,088h,077h,088h
                DB  0BBh,011h,0BBh,022h,0FFh,0FFh,0BBh,044h
                DB  0DDh,011h,0DDh,022h,0EEh,011h,000h,000h
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
newval_table3_call_tbl_3:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,000h
crank_edge_flag_store_tbl_2:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,000h
Scaler_RpmAxis_Lo:       DB  000h,00Dh,01Ah,02Dh,040h,050h,05Ah,063h,076h,080h
                DB  083h,08Ah,093h,0ADh,0C0h,0C8h,0D0h,0E0h,0F0h,000h
rpm_avg_store_tbl:       DB  000h,011h,01Ch,02Bh,039h,047h,055h,064h,072h,080h
                DB  087h,08Eh,095h,09Ch,0ABh,0B9h,0C7h,0D5h,0E4h,000h
crank_edge_flag_store_tbl_3:       DB  000h,00Dh,01Ah,02Dh,040h,050h,05Ah,063h,076h,080h
                DB  083h,08Ah,093h,0ADh,0C0h,0C8h,0D0h,0E0h,0F0h,000h
fuelmap_base_lookup_tbl_2:       DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0AAh
                DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0ACh
                DB  044h,0B9h,0C2h,09Dh,0A3h,0A9h,0AFh,0BDh,0CDh,0B0h
                DB  047h,0BBh,0C5h,0A2h,0A5h,0ABh,0B0h,0BEh,0CEh,0B2h
                DB  048h,0C1h,0CAh,0A4h,0A9h,0AFh,0B4h,0C2h,0D2h,0B6h
                DB  048h,0CAh,0D2h,0AAh,0AFh,0B5h,0BCh,0C4h,0D2h,0B6h
                DB  048h,0CDh,0D2h,0A9h,0AEh,0B5h,0BBh,0C8h,0D9h,0BBh
                DB  048h,0CAh,0CFh,0A6h,0ADh,0B2h,0B8h,0C5h,0D4h,0B6h
                DB  04Ah,0D8h,0DCh,0B0h,0B8h,0BEh,0C2h,0CFh,0EAh,0C8h
                DB  049h,0D0h,0D4h,0A9h,0B0h,0B6h,0BBh,0C9h,0D9h,0BBh
                DB  049h,0CFh,0D4h,0A8h,0B0h,0B5h,0BBh,0C9h,0D9h,0BBh
                DB  049h,0D2h,0D5h,0A9h,0AFh,0B5h,0BBh,0C8h,0D7h,0B9h
                DB  04Dh,0DDh,0DFh,0B1h,0B7h,0BCh,0C1h,0CCh,0DCh,0BEh
                DB  04Ah,0C4h,0D1h,0ACh,0B6h,0BBh,0C1h,0CCh,0DCh,0BEh
                DB  050h,0E3h,0EBh,0BFh,0C8h,0CFh,0D5h,0E6h,0F6h,0E8h
                DB  070h,0F9h,0FDh,0CEh,0D6h,0DBh,0E1h,0ECh,0FCh,0EFh
                DB  078h,0FEh,0FFh,0CFh,0D8h,0DCh,0E0h,0EFh,0FFh,0F1h
                DB  050h,0DEh,0E5h,0BCh,0C6h,0C6h,0CFh,0DDh,0ECh,0E0h
                DB  050h,0DEh,0E5h,0BCh,0C6h,0C6h,0CFh,0DDh,0ECh,0E0h
                DB  050h,0DEh,0E3h,0BCh,0C6h,0C6h,0CFh,0DDh,0ECh,0E0h
                DB  001h,002h,003h,005h,006h,007h,008h,008h,008h,00Ah
fuelmap_base_lookup_tbl_3:       DB  028h,075h,08Ah,099h,0A2h,0ABh,09Ch,0A8h
                DB  0BCh,0C8h,028h,075h,08Ah,099h,0A2h,0ABh
                DB  09Ch
fueltbl_range_check_tbl:       DB  0A8h,0BCh,0C8h,028h,075h,08Ah,099h,0A2h
                DB  0ABh,09Ch,0A8h,0BCh,0C8h,028h,075h,08Ah
                DB  099h,0A2h,0ABh,09Ch,0A8h,0BCh,0C8h,028h
                DB  075h,08Ah,099h,0A2h,0ABh,09Ch,0A8h,0BCh
                DB  0C8h,028h,075h,08Ah,099h,0A2h,0ABh,09Ch
                DB  0A8h,0BCh,0C8h,04Dh,08Dh,0A4h,0B0h,0B5h
                DB  0BFh,0ADh,0BBh,0CEh,0E2h,017h,078h,097h
                DB  0A8h,0B0h,0BDh,0B0h,0BEh,0D5h,0E3h,016h
                DB  077h,094h,0A6h,0B2h,0BCh,0ADh,0BDh,0CEh
                DB  0DAh,014h,08Eh,0A7h,0B7h,0C2h,0CCh,0BDh
                DB  0C9h,0D6h,0E0h,03Dh,08Eh,0A8h,0BBh,0C8h
                DB  0D2h,0BFh,0CAh,0D7h,0E1h,001h,09Bh,0B3h
                DB  0C4h,0D0h,0D5h,0C4h,0D2h,0E2h,0E5h,039h
                DB  0A7h,0C1h,0D5h,0E0h,0E8h,0D5h,0E1h,0EAh
                DB  0EDh,060h,0B2h,0CCh,0DEh,0E8h,0EBh,0D4h
                DB  0E2h,0EBh,0F5h,07Bh,0B8h,0D8h,0E5h,0EBh
                DB  0EEh,0D7h,0E3h,0F1h,0F7h,049h,0BBh,0D5h
                DB  0ECh,0F3h,0F3h,0DEh,0ECh,0F7h,0F8h,05Ch
                DB  0A1h,0C7h,0EAh,0F3h,0F4h,0DAh,0F1h,0F5h
                DB  0F8h,041h,08Fh,0B6h,0CFh,0DBh,0E8h,0CAh
                DB  0D8h,0DFh,0E9h,041h,08Fh,0B6h,0CFh,0DBh
                DB  0E8h,0CAh,0D8h,0DFh,0E9h,041h,08Fh,0B6h
                DB  0CFh,0DBh,0E8h,0CAh,0D8h,0DFh,0E9h,001h
                DB  003h,004h,005h,006h,007h,009h,009h,009h
                DB  009h
fuelmap_base_lookup_tbl_4:       DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0AAh
                DB  043h,0B7h,0C1h,09Eh,0A2h,0A8h,0AFh,0BCh,0CBh,0ACh
                DB  044h,0B9h,0C2h,09Dh,0A3h,0A9h,0AFh,0BDh,0CDh,0B0h
                DB  047h,0BBh,0C5h,0A2h,0A5h,0ABh,0B0h,0BEh,0CEh,0B2h
                DB  048h,0C1h,0CAh,0A4h,0A9h,0AFh,0B4h,0C2h,0D2h,0B6h
                DB  048h,0CAh,0D2h,0AAh,0AFh,0B5h,0BCh,0C4h,0D2h,0B6h
                DB  048h,0CDh,0D2h,0A9h,0AEh,0B5h,0BBh,0C8h,0D9h,0BBh
                DB  048h,0CAh,0CFh,0A6h,0ADh,0B2h,0B8h,0C5h,0D4h,0B6h
                DB  04Ah,0D8h,0DCh,0B0h,0B8h,0BEh,0C2h,0CFh,0EAh,0C8h
                DB  049h,0D0h,0D4h,0A9h,0B0h,0B6h,0BBh,0C9h,0D9h,0BBh
                DB  049h,0CFh,0D4h,0A8h,0B0h,0B5h,0BBh,0C9h,0D9h,0BBh
                DB  001h,002h,003h,005h,006h,007h,008h,008h,008h,00Ah
fuelmap_base_lookup_tbl_5:       DB  02Dh,07Ah,097h,0A2h,0ABh,0B1h,0BBh,0B5h,0C7h,0BCh
                DB  02Dh,07Ah,097h,0A2h,0ABh,0B1h,0BBh,0B5h,0C7h,0BCh
                DB  02Dh,07Ah,097h,0A2h,0ABh,0B1h,0BBh,0B5h,0C7h,0BCh
                DB  030h,080h,098h,0A2h,0ACh,0B4h,0BEh,0B6h,0C6h,0BBh
                DB  030h,08Bh,0A0h,0ABh,0B1h,0B9h,0C0h,0B9h,0C8h,0BDh
                DB  030h,091h,0A8h,0B4h,0B8h,0C1h,0C8h,0BFh,0CEh,0C3h
                DB  030h,095h,0ABh,0B7h,0C0h,0C6h,0CDh,0C4h,0D3h,0C8h
                DB  030h,091h,0A9h,0B8h,0C0h,0C7h,0D0h,0C7h,0D7h,0CDh
                DB  03Ah,09Ah,0B1h,0BDh,0C5h,0CBh,0D3h,0C9h,0D9h,0CEh
                DB  03Ah,094h,0ADh,0BAh,0C4h,0C7h,0D0h,0C7h,0D6h,0CBh
                DB  03Ah,093h,0ABh,0B8h,0C4h,0C7h,0D0h,0C7h,0D7h,0CCh
                DB  001h,003h,004h,005h,006h,007h,008h,009h,009h,00Ah
mode_flags_pack4_tbl:       DB  066h,066h,066h,05Eh,044h,030h,020h,00Fh
                DB  000h,000h,066h,066h,066h,05Eh,044h,030h
                DB  020h,00Fh,000h,000h,066h,066h
vss_calc_skip_tbl:       DB  066h,05Eh,044h,030h,020h,00Fh,000h,000h
                DB  066h,066h,066h,05Eh,044h,030h,020h,00Fh
                DB  000h,000h,06Fh,06Fh,06Fh,069h,061h,049h
                DB  031h,022h,015h,011h,087h,087h,087h,07Dh
                DB  073h,059h,040h,033h,024h,020h,08Fh,08Fh
                DB  08Fh,085h,079h,060h,047h,03Bh,02Dh,029h
                DB  097h,097h,097h,08Bh,07Dh,066h,04Bh,043h
                DB  035h,031h,09Eh,09Eh,09Eh,091h,085h,071h
                DB  056h,04Eh,042h,03Eh,0A2h,0A2h,0A2h,095h
                DB  089h,075h,05Dh,053h,046h,041h,0A6h,0A6h
                DB  0A6h,098h,08Ch,078h,060h,055h,048h,044h
                DB  0AFh,0AFh,0AFh,0A1h,093h,07Eh,067h,05Bh
                DB  04Eh,04Ah,0B7h,0B7h,0B7h,0AAh,09Ah,086h
                DB  070h,063h,054h,050h,0C7h,0C7h,0C7h,0BEh
                DB  0B3h,0A7h,097h,088h,070h,070h,0C7h,0C7h
                DB  0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,07Ch,07Ch
                DB  0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh
                DB  07Ch,07Ch,0C7h,0C7h,0C7h,0BEh,0B3h,0ABh
                DB  09Ah,08Dh,084h,084h,0C7h,0C7h,0C7h,0BEh
                DB  0B3h,0ABh,09Ah,08Dh,084h,084h,0C7h,0C7h
                DB  0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BDh,0B3h,0ABh,09Ah,08Dh
                DB  084h,084h
mode_flags_pack4_tbl_2:       DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,010h,000h,000h
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,010h,000h,000h
                DB  078h,078h,078h,071h,065h,04Ch,031h,022h,015h,011h
                DB  095h,095h,095h,089h,07Ch,067h,04Ch,041h,033h,02Fh
                DB  0A2h,0A2h,0A2h,095h,089h,077h,061h,055h,049h,045h
                DB  0B7h,0B7h,0B7h,0A9h,09Ah,08Bh,078h,064h,051h,04Dh
                DB  0C5h,0C5h,0C5h,0B8h,0ADh,0A5h,099h,07Ah,062h,05Eh
                DB  0C7h,0C7h,0C7h,0BAh,0B3h,0ABh,0A1h,08Dh,073h,073h
                DB  0C7h,0C7h,0C7h,0BEh,0B3h,0ABh,09Ah,08Dh,07Ch,07Ch
                DB  0C7h,0C7h,0C7h,0BEh,0AFh,0ABh,09Ah,08Dh,07Ch,07Ch
                DB  0C8h,0C8h,0C8h,0C1h,0B2h,0AEh,09Ah,08Dh,080h,080h
                DB  0C8h,0C8h,0C8h,0C4h,0B5h,0B1h,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0C3h,0B4h,0AFh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0C0h,0B4h,0ADh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
                DB  0C8h,0C8h,0C8h,0BBh,0B3h,0ABh,09Ah,08Dh,084h,084h
mode_flags_pack4_tbl_3:       DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h
                DB  05Ah,05Ah,05Ah,05Ah,044h,030h,020h,00Fh,000h,000h
                DB  06Fh,06Fh,06Fh,06Fh,065h,04Ch,031h,022h,015h,011h
                DB  087h,087h,087h,07Dh,073h,05Ch,040h,033h,024h,020h
                DB  08Fh,08Fh,08Fh,085h,079h,063h,047h,03Bh,02Dh,029h
                DB  097h,097h,097h,08Bh,07Dh,069h,04Eh,043h,035h,031h
                DB  09Eh,09Eh,09Eh,091h,085h,072h,05Ah,04Fh,042h,03Eh
                DB  0A2h,0A2h,0A2h,095h,089h,077h,061h,055h,049h,045h
                DB  0A6h,0A6h,0A6h,098h,08Ch,07Bh,065h,058h,04Ah,047h
mode_flags_pack4_tbl_4:       DB  05Ah,05Ah,05Ah,05Ah,047h,03Bh,02Ch,01Dh
                DB  015h,011h,05Ah,05Ah,05Ah,05Ah,049h,03Fh
                DB  034h,024h,01Ch
freezeframe_flag_next_tbl:       DB  018h,05Ah,05Ah,05Ah,05Ah,04Bh,043h,03Bh
                DB  02Ch,023h,01Fh,05Ah,05Ah,05Ah,05Ah,04Fh
                DB  047h,041h,033h,02Ah,026h,06Fh,06Fh,06Fh
                DB  06Fh,061h,056h,04Dh,041h,039h,035h,08Ch
                DB  08Ch,08Ch,07Bh,069h,060h,059h,04Dh,046h
                DB  042h,097h,097h,097h,081h,06Fh,068h,062h
                DB  057h,050h,04Ch,0A1h,0A1h,0A1h,087h,073h
                DB  06Eh,067h,05Eh,055h,051h,0A9h,0A9h,0A9h
                DB  08Ch,077h,071h,06Bh,064h,05Ah,056h,0ABh
                DB  0ABh,0ABh,08Eh,07Ah,074h,06Eh,068h,05Eh
                DB  05Ah,0ACh,0ACh,0ACh,091h,07Eh,078h,072h
                DB  06Ch,062h,05Eh
ve_result_flag_store_tbl:       DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  086h,086h,086h,086h,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
ve_result_flag_store_tbl_2:       DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h
                DB  080h,080h,080h,080h,097h,097h,097h,0A4h,0A4h,0A4h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  080h,080h,080h,080h,097h,097h,097h,097h,097h,097h
                DB  086h,086h,086h,086h,097h,097h,097h,097h,097h,097h
                DB  086h,086h,086h,086h,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
                DB  08Bh,08Bh,08Bh,08Bh,097h,097h,097h,097h,097h,097h
crank_edge_flag_store_tbl_4:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh
vcal3_leanprotect_ratelimit_store_carry_ram22d_bit7:
                MB      off(0022dh).7, C
                LB      A, #046h
                JBS     off(0022fh).7, vcal3_leanprotect_ratelimit_cmp_acc_27
                LB      A, #04bh
vcal3_leanprotect_ratelimit_cmp_acc_27:
                CMPB    A, r0
                MB      off(0022fh).7, C
                J       vcal3_leanprotect_ratelimit_load_imm
vcal3_leanprotect_ratelimit_if_ram22f_bit7_set:
                JBS     off(0022fh).7, vcal3_leanprotect_ratelimit_goto_3ae5
                J       vcal3_leanprotect_ratelimit_clear_r0
vcal3_leanprotect_ratelimit_goto_3ae5:
                J       vcal3_leanprotect_ratelimit_goto_3cb2
battery_voltage_check_if_ge_goto_782e:
                JGE     battery_voltage_check_store_ram0e0
                VCAL    6
battery_voltage_check_store_ram0e0:
                STB     A, 0e0h
                MOVB    r0, 0dfh
                J       battery_voltage_check_load_imm
knock_324_bit_store_xorb_pswh:
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.4
                XORB    PSWH, #080h
                J       knock_324_bit_store_rolb_acc_2
injtimer_finalize_start_add_x1:
                ADD     X1, #00006h
                MOVB    r7, off(0016dh)
                MOVB    r6, off(001ffh)
                MOVB    r1, off(0016ch)
injtimer_finalize_start_load_ram132:
                LB      A, off(00132h)
                CMPCB   A, 00001h[X1]
                JGE     injtimer_finalize_start_call_knockretard_helper
                MOVB    r7, r6
                MOVB    r6, r1
                INC     X1
injtimer_finalize_start_call_knockretard_helper:
                CAL     knockretard_helper
                J       injtimer_finalize_start_store_ram165
injtimer_finalize_start_addb_acc:
                ADDB    A, off(0016fh)
                STB     A, r7
                MOVB    r6, off(0016ah)
                LCB     A, [X1]
                STB     A, r1
                LCB     A, 00002h[X1]
                STB     A, r0
                LB      A, off(00132h)
                CAL     Cranking_sub_cmp_acc
                J       injtimer_finalize_start_store_ram165
injtimer_finalize_start_load_r7:
                MOVB    r7, off(0016bh)
                MOVB    r6, off(001feh)
                MOVB    r1, off(0016ah)
                SJ      injtimer_finalize_start_load_ram132
knockwindow_next_table_load_ram0d9_5:
                LB      A, 0d9h
                STB     A, r2
                MOV     X1, #knockwindow_next_table_tbl_21
                CAL     table_interp_lookup
                STB     A, (001feh-00180h)[USP]
                LB      A, r2
                MOV     X1, #knockwindow_next_table_tbl_22
                CAL     table_interp_lookup
                STB     A, (001ffh-00180h)[USP]
                VCAL    3
                LB      A, 0d9h
                STB     A, r2
                J       knockwindow_next_table_load_x1
Cranking_sub_cmp_acc:
                CMPB    A, r1
                JLE     Cranking_sub_cmp_acc_2
                LB      A, r1
Cranking_sub_cmp_acc_2:
                CMPB    A, r0
                JGE     Cranking_sub_xchgb_acc
                LB      A, r0
Cranking_sub_xchgb_acc:
                XCHGB   A, r0
                SUBB    r0, A
                SUBB    r1, A
                LB      A, r7
                J       table_interp_delta_calc
injtimer_finalize_start_tbl:       DB  0D0h,064h,063h,0D0h,051h,050h,0D0h,064h
                DB  063h,0D0h,051h,050h
knockwindow_next_table_tbl_21:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h
                DB  044h,042h,028h,041h,000h,040h
knockwindow_next_table_tbl_22:       DB  0FFh,040h,000h,040h,000h,040h,000h,040h
                DB  000h,040h,000h,040h,000h,040h
idle_state_defaults_cmp_ram0da:
                CMPB    0dah, #04dh
                JGT     idle_state_defaults_orb_pswh
                LB      A, off(002efh)
                SJ      idle_stage_c0_load_if_ne_goto_78f2
idle_state_defaults_orb_pswh:
                ORB     PSWH, #040h
idle_stage_c0_load_load_ram2ef:
                MOVB    off(002efh), #050h
idle_stage_c0_load_if_ne_goto_78f2:
                JNE     idle_stage_c0_load_goto_gio_fuelpump_dispatch
                RB      off(00219h).0
                SB      off(00223h).1
idle_stage_c0_load_goto_gio_fuelpump_dispatch:
                J       gio_fuelpump_dispatch
idle_helper2_call1_cmp_stk:
                CMPB    (001eah-00180h)[USP], #004h
                JGE     idle_helper2_call1_call_idle_helper2
                L       A, #012c0h
idle_helper2_call1_call_idle_helper2:
                CAL     idle_helper2
                J       idle_helper2_call1_xchg_acc
Cranking_load_x1:
                MOV     X1, #Cranking_tbl_3
                LB      A, 0d9h
                VCAL    1
                STB     A, r2
                MOV     X1, #Cranking_tbl_2
                LB      A, 0d9h
                VCAL    1
                MOVB    r7, #080h
                MOVB    r0, r2
                MOVB    r1, #030h
                LB      A, 0c5h
                CAL     Cranking_sub_cmp_acc
                J       Cranking_store_ram164
Cranking_tbl_2:       DB  0FFh,05Ah,000h,05Ah
Cranking_tbl_3:       DB  0FFh,012h,000h,012h
idle_pid_output_store_store_r0:
                STB     A, r0
                CLR     A
                LB      A, #080h
                JBS     off(00216h).3, idle_pid_output_store_load_acc
                LB      A, off(00251h)
                LCB     A, idle_pid_output_store_tbl[ACC]
idle_pid_output_store_load_acc:
                L       A, ACC
                SWAP
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_sub_result_store
                L       A, #0ffffh
idle_sub_result_store:
                ST      A, er3
                J       idle_sub_result_store_load_ram2c3
idle_pid_output_store_load_ram0d5:
                LB      A, 0d5h
                VCAL    2
                J       idle_pid_output_store_store_r0
                DB  0FFh
idle_pid_output_store_tbl:       DB  0FFh,0A0h,0A0h,093h,080h,080h
knockretard_clear_state_if_ram235_bit3_set:
                JBS     off(00235h).3, knockretard_clear_state_goto_0ded
                JBS     off(00218h).6, knockretard_clear_state_goto_0ded
                J       knockretard_clear_state_if_ram21d_bit4_set
knockretard_clear_state_goto_0ded:
                J       knockretard_clear_state_store_ram23e
o2_closedloop_gate1_load_carry_stk:
                MB      C, (00235h-00280h)[USP].3
                JGE     o2_closedloop_gate1_load_ram11a
                J       o2_trim_gate_common
o2_closedloop_gate1_load_ram11a:
                L       A, off(0011ah)
                AND     A, #08075h
                J       o2_closedloop_gate1_if_ne_goto_o2_trim_gate_common
o2_trim_table_ptr_load_load_carry_stk:
                MB      C, (00235h-00280h)[USP].3
                JGE     o2_trim_table_ptr_load_load_ram11a
                J       o2_trim_table_ptr_alt
o2_trim_table_ptr_load_load_ram11a:
                L       A, off(0011ah)
                AND     A, #08061h
                J       o2_trim_table_ptr_load_if_ne_goto_o2_trim_table_ptr_alt
o2_trim_alt_path_check_set_stk:
                SB      (00235h-00280h)[USP].2
                SB      off(00125h).1
                J       o2_trim_alt_path_check_goto_o2_trim_clear_gate0_and_retu
o2_trim_alt_path_check_set_stk_2:
                SB      (00235h-00280h)[USP].2
                SB      off(00125h).1
                J       o2_trim_alt_path_check_load_ram1d3
injtimer_finalize_start_load_carry_stk:
                MB      C, (00235h-00280h)[USP].3
                JLT     injtimer_finalize_start_goto_injtimer_gate_common
                JBS     off(00120h).6, injtimer_finalize_start_goto_injtimer_gate_common
                J       injtimer_finalize_start_cmp_ram0d9
injtimer_finalize_start_goto_injtimer_gate_common:
                J       injtimer_gate_common
crank_edge_flag_store_load_carry_stk:
                MB      C, (00235h-00280h)[USP].3
                JLT     crank_edge_flag_store_goto_244c
                JBS     off(0011ah).0, crank_edge_flag_store_goto_244c
                J       crank_edge_flag_store_if_ram11d_bit2_set
crank_edge_flag_store_goto_244c:
                J       crank_edge_flag_store_if_ram125_bit2_clr
ram_clear_loop1_body_load_dp:
                MOV     DP, #0031dh
                LCB     A, boot_completion_helper_tbl_8
                JNE     cfgvariant_check_bit0
                CLRB    [DP]
                SJ      cfgvariant_set_bit0_from_2edh_3_goto_7a90
cfgvariant_check_bit0:
                MB      C, [DP].0
                JGE     cfgvariant_set_bit0_from_2edh_3
                JBR     off(00235h).1, cfgvariant_set_bit0_from_2edh_3_goto_7a90
                JBR     off(00235h).2, cfgvariant_set_bit0_from_2edh_3_goto_7a90
cfgvariant_set_bit0_from_2edh_3:
                MB      C, off(00235h).3
                MB      [DP].0, C
cfgvariant_set_bit0_from_2edh_3_goto_7a90:
                J       cfgvariant_set_bit0_from_2edh_3_if_ram232_bit4_clr
vcal_3_clear_ram235_bit2:
                RB      off(00235h).2
                RB      off(00235h).1
                RB      off(00235h).3
                CAL     cfgvariant_check_320h_bit7_sub_clear_acc
                J       vcal_3_clear_ram232_bit2
sensor_bank_ect_check_if_ram230_bit3_clr:
                JBR     off(00230h).3, sensor_bank_ect_check_load_imm
                J       sensor_bank_ect_check_load_carry_pswl_bit4
sensor_bank_ect_check_load_imm:
                LB      A, #057h
                CMPB    A, 0d9h
                MB      off(00235h).1, C
                SC
                J       sensor_bank_ect_check_store_carry_ram234_bit6
state_21a_7_dispatch2_if_ram235_bit3_set:
                JBS     off(00235h).3, state_21a_7_dispatch2_goto_4efa
                JBS     off(00218h).6, state_21a_7_dispatch2_goto_4efa
                J       state_21a_7_dispatch2_load_x1
state_21a_7_dispatch2_goto_4efa:
                J       state_21a_7_dispatch2_goto_50fe
dtc_active_confirm_if_ram227_bit1_clr:
                JBR     off(00227h).1, dtc_active_confirm_goto_cfgvariant_apply_gate
                JBS     off(00210h).7, dtc_active_confirm_goto_cfgvariant_apply_gate
                CMPB    r7, #005h
                JNE     dtc_active_confirm_goto_cfgvariant_apply_gate
                SB      off(00235h).3
                MOV     DP, #0031dh
                MB      C, [DP].0
                JGE     dtc_active_confirm_goto_5410
                JBS     off(00235h).1, dtc_active_confirm_goto_cfgvariant_apply_gate
dtc_active_confirm_goto_5410:
                J       dtc_debounce2_check_goto_7a1b
dtc_active_confirm_goto_cfgvariant_apply_gate:
                J       cfgvariant_apply_gate
                DB  000h,000h,000h,000h
dtc_debounce2_check_load_dp:
                MOV     DP, #0031dh
                JBS     off(00227h).1, dtc_debounce2_check_load_r0
                RB      off(00235h).3
                CLRB    [DP]
dtc_debounce2_check_load_r0:
                MOVB    r0, [DP]
                MOVB    r1, r0
                MOV     DP, #00322h
                J       dtc_debounce2_check_load_x1
calchecksum_loop_dec_dp:
                DEC     DP
                LB      A, [DP]
                ANDB    A, #0feh
                JNE     calchecksum_loop_goto_selftest_fail_043_checksum
                INC     DP
                LB      A, [DP]
                ANDB    A, #002h
                J       calchecksum_loop_if_ne_goto_selftest_fail_043_checksum
calchecksum_loop_goto_selftest_fail_043_checksum:
                J       selftest_fail_043_checksum
freezeframe_decode_start_load_carry_ram235_bit3:
                MB      C, off(00235h).3
                ADC     A, #0ffffh
                J       freezeframe_flag_218_7
freezeframe_flag_22b_4_set_carry:
                SC
                JBS     off(00235h).3, freezeframe_flag_22b_4_goto_freezeframe_flag_next
                L       A, off(00212h)
                J       freezeframe_flag_22b_4_if_ne_goto_freezeframe_flag_next
freezeframe_flag_22b_4_goto_freezeframe_flag_next:
                J       freezeframe_flag_next
freezeframe_flag_next_set_carry:
                SC
                JBS     off(00235h).3, freezeframe_flag_next_goto_54b9
                L       A, off(00212h)
                J       freezeframe_flag_next_if_ne_goto_54b9
freezeframe_flag_next_goto_54b9:
                J       freezeframe_flag_next_store_carry_ram234_bit7
cfgvariant_check_320h_bit7_sub_load_dp:
                MOV     DP, #0031dh
                CLRB    [DP]
                MOV     DP, #00356h
                J       cfgvariant_state_clear_loop
idle_helper2_call1_clear_acc:
                CLRB    A
                JLT     idle_helper2_call1_if_ram20c_bit1_clr
                J       idle_target_store
idle_helper2_call1_if_ram20c_bit1_clr:
                JBR     off(0020ch).1, idle_helper2_call1_goto_idle_step_store
                J       idle_step_default
idle_helper2_call1_goto_idle_step_store:
                J       idle_step_store
dtc_active_confirm_if_ne_goto_7a82:
                JNE     dtc_active_confirm_goto_5410_2
                STB     A, 0f4h
                J       dtc_active_confirm_if_ram227_bit1_clr
dtc_active_confirm_goto_5410_2:
                J       dtc_debounce2_check_goto_7a1b
int_NMI_load_dp:
                MOV     DP, #00007h
int_NMI_loop_dp:
                JRNZ    DP, int_NMI_loop_dp
                MOV     DP, #00005h
                J       nmi_poll_p4_1
cfgvariant_set_bit0_from_2edh_3_if_ram232_bit4_clr:
                JBR     off(00232h).4, cfgvariant_set_bit0_from_2edh_3_goto_cfgvariant_check_32
                J       cfgvariant_set_bit0_from_2edh_3_if_ram232_bit5_clr
cfgvariant_set_bit0_from_2edh_3_goto_cfgvariant_check_32:
                J       cfgvariant_check_320h_bit7
injtimer_mul_final_load_ram158:
                MOV     off(00158h), er1
                LB      A, #05ah
                JBS     off(00130h).6, dwell_rpm_hyst_check
                LB      A, #05dh
dwell_rpm_hyst_check:
                CMPB    A, off(00133h)
                MB      off(00130h).6, C
                J       dwell_rpm_hyst_check_if_ram125_bit4_set
dwell_rpm_gate2_load_carry_ram130_bit6:
                MB      C, off(00130h).6
                XORB    PSWH, #080h
                J       dwell_rpm_gate3
crank_sync_store_flag_andb_pswh:
                ANDB    PSWH, #0feh
                MOVB    off(0018eh), #077h
                J       crank_sync_store_flag_load_ram116
crank_sync_flag2_check_if_ne_goto_7ac7:
                JNE     crank_sync_flag2_check_goto_0564
                LB      A, 0a2h
                JNE     crank_sync_flag2_check_goto_0564
                SB      off(00128h).2
crank_sync_flag2_check_goto_0564:
                J       crank_sync_flag2_check_if_ram11f_bit7_set
crank_sync_flag2_check_load_ram0a2:
                LB      A, 0a2h
                JEQ     crank_sync_flag2_check_goto_crank_cycle_dispatch2
                J       crank_decode_exit
crank_sync_flag2_check_goto_crank_cycle_dispatch2:
                J       crank_cycle_dispatch2
crank_cycle_p4_gate_load_imm:
                LB      A, #001h
                CMPB    0f4h, #024h
                JNE     crank_cycle_p4_gate_goto_crank_cycle_counter_check
                SB      off(0012ah).4
crank_cycle_p4_gate_goto_crank_cycle_counter_check:
                J       crank_cycle_counter_check
crank_cycle_entry_gate_set_ram12a_bit2:
                SB      off(0012ah).2
                L       A, 0f8h
                ST      A, IE
                J       crank_cycle_entry_gate_call_crank_edge_helper
rpm_period_accum_load_tbl_x1:
                L       A, 00360h[X1]
                JBS     off(00217h).7, rpm_period_accum_load_tbl_x1_2
                J       rpm_period_overflow_check
rpm_period_accum_load_tbl_x1_2:
                MOV     00360h[X1], #00001h
                J       rpm_period_accum
sensor_check_vcal3_load_dp_ind:
                LB      A, [DP]
                STB     A, 0dbh
                RC
                JBS     off(00212h).3, sensor_check_gate1
                CMPB    (001b5h-00180h)[USP], #015h
                JGT     sensor_check_gate1
                SC
                JBS     off(0021ch).6, sensor_check_gate1
                MOVB    (001b5h-00180h)[USP], #014h
sensor_check_gate1:
                MB      off(00217h).7, C
                J       sensor_check_gate1_if_ram212_bit2_set
cfgvariant_snapshot_capture_load_ram2a1:
                LB      A, off(002a1h)
                STB     A, [DP]
                MOV     DP, #00344h
                LB      A, r1
                ROLB    A
                MB      C, off(0021dh).0
                RORB    A
                STB     A, [DP]
                J       cfgvariant_snapshot_capture_return
knock_324_bit_store_clear_carry:
                RC
                J       knock_324_bit_store_clear_acc_2
                DB  0FFh
knock_324_bit_store_if_eq_goto_7b36:
                JEQ     knock_324_bit_store_load_x1
                MOV     DP, #003cfh
tbl_7b31        EQU     $-2
                LB      A, [DP]
                SLLB    A
                SLLB    A
knock_324_bit_store_load_x1:
                MOV     X1, #knock_324_bit_store_tbl
                LCB     A, [X1]
                JGE     knock_324_bit_store_load_dp_2
                ADDB    A, #006h
knock_324_bit_store_load_dp_2:
                MOV     DP, #003a4h
                J       knock_324_bit_store_store_dp_ind
boot_completion_helper_store_carry_ram216_bit3:
                MB      off(00216h).3, C
                JGE     boot_completion_helper_store_carry_ram227_bit0
                LCB     A, boot_completion_helper_tbl_13
                SLLB    A
boot_completion_helper_store_carry_ram227_bit0:
                MB      off(00227h).0, C
                J       boot_completion_helper_cmp_r0
boot_completion_helper_set_carry:
                SC
                LCB     A, boot_completion_helper_tbl_11
                JNE     boot_completion_helper_goto_boot_flag_iabv_common
                RC
                LCB     A, dwell_battery_check2_tbl
                JNE     boot_completion_helper_goto_boot_flag_iabv_common
                SC
                LCB     A, boot_completion_helper_tbl_12
                JNE     boot_completion_helper_goto_boot_flag_iabv_common
                J       boot_completion_helper_load_r2_2
boot_completion_helper_goto_boot_flag_iabv_common:
                J       boot_flag_iabv_common
boot_flag_iabv_common_set_carry:
                SC
                LCB     A, boot_completion_helper_tbl_12
                JNE     boot_flag_iabv_common_goto_5ffc
                LB      A, r2
                SLLB    A
                SLLB    A
                J       boot_flag_iabv_common_xorb_pswh
boot_flag_iabv_common_goto_5ffc:
                J       boot_flag_iabv_common_goto_7b80
boot_flag_iabv_common_store_carry_ram216_bit0:
                MB      off(00216h).0, C
                LCB     A, boot_flag_iabv_common_tbl
                SLLB    A
                LCB     A, diag_mode_code_store_tbl_2
                JEQ     boot_flag_iabv_common_store_carry_ram216_bit6
                MB      C, off(00216h).0
                XORB    PSWH, #080h
boot_flag_iabv_common_store_carry_ram216_bit6:
                MB      off(00216h).6, C
                J       boot_flag_iabv_common_cmp_r0
boot_flag_gearpreset_alt_if_ram227_bit0_clr:
                JBR     off(00227h).0, boot_flag_gearpreset_alt_store_carry_ram227_bit2
                SC
boot_flag_gearpreset_alt_store_carry_ram227_bit2:
                MB      off(00227h).2, C
                J       boot_flag_gearpreset_alt_cmp_r0
boot_completion_helper_tbl_11:       DB  000h
boot_completion_helper_tbl_12:       DB  0FFh
boot_completion_helper_tbl_13:       DB  000h
accut_output_drive_load_imm:
                LB      A, #0feh
                JBS     off(00235h).4, accut_output_drive_cmp_acc
                LB      A, #0ffh
accut_output_drive_cmp_acc:
                CMPB    A, 0d1h
                MB      off(00235h).4, C
                LB      A, #000h
                JBS     off(00235h).5, accut_output_drive_cmp_acc_2
                LB      A, #001h
accut_output_drive_cmp_acc_2:
                CMPB    A, 0cch
                MB      off(00235h).5, C
                JBS     off(00217h).5, purge_gate2_goto_purge_result_clear
                J       accut_output_drive_if_ram212_bit5_set
purge_gate2:    JBR     off(00218h).0, purge_ect_check
                JBR     off(0021eh).4, purge_ect_check
                JBR     off(00219h).0, purge_gate2_goto_purge_result_clear
purge_ect_check:
                CMPB    0d9h, #000h
                JGE     purge_ect_check_load_ram2f0
                CMPB    0d8h, #000h
                JGE     purge_ect_check_load_ram2f0
                JBS     off(00235h).4, purge_ect_check_load_ram2f0
                CLRB    A
                JBS     off(00235h).5, purge_delay_store
                LB      A, #000h
purge_delay_store:
                STB     A, off(002f0h)
purge_delay_store_goto_purge_counter_check:
                J       purge_counter_check
purge_ect_check_load_ram2f0:
                LB      A, off(002f0h)
                JEQ     purge_delay_store_goto_purge_counter_check
purge_gate2_goto_purge_result_clear:
                J       purge_result_clear
ve_accel_tps_threshold_check_cmp_r0:
                CMPB    r0, off(0016bh)
                JGE     ve_accel_tps_threshold_check_goto_ve_accel_next_stage
                J       to_ve_accel_common
ve_accel_tps_threshold_check_goto_ve_accel_next_stage:
                J       ve_accel_next_stage
coldstart_full_reset_store_stk:
                STB     A, (00168h-00180h)[USP]
                MOVB    (001cch-00180h)[USP], #006h
                SB      (00126h-00180h)[USP].3
                SB      P4.0
                J       coldstart_full_reset_orb_tcon3
adc_wait_loop_load_imm:
                LB      A, #025h
                STB     A, 0dch
                STB     A, 0ddh
                J       adc_wait_loop_store_ram0df
dwell_base_lookup_rom_load_tbl_7cb8:
                LCB     A, dwell_base_lookup_tbl_2
                JEQ     dwell_base_lookup_clear_carry
                JBR     off(00216h).3, dwell_base_lookup_clear_carry
                LB      A, #0feh
                JBS     off(00236h).1, dwell_base_lookup_cmp_acc_2
                LB      A, #0ffh
dwell_base_lookup_cmp_acc_2:
                CMPB    A, off(00238h)
                MB      off(00236h).1, C
                MOVB    r0, 0d1h
                LB      A, #0feh
                JBS     off(00236h).2, dwell_base_lookup_cmp_acc_3
                LB      A, #0ffh
dwell_base_lookup_cmp_acc_3:
                CMPB    A, r0
                MB      off(00236h).2, C
                JBR     off(00211h).5, dwell_base_lookup_load_ram23e
                MOVB    off(002bfh), #000h
dwell_base_lookup_load_ram2c1:
                MOVB    off(002c1h), #000h
dwell_base_lookup_clear_carry:
                RC
                CLRB    off(002c0h)
dwell_base_lookup_store_carry_ram236_bit0:
                MB      off(00236h).0, C
                SJ      dwell_base_lookup_clear_acc
dwell_base_lookup_load_ram23e:
                LB      A, off(0023eh)
                JNE     dwell_base_lookup_clear_carry
                JBS     off(00236h).0, dwell_base_lookup_if_ram235_bit3_set
                LB      A, off(002bfh)
                JEQ     dwell_base_lookup_clear_carry
dwell_base_lookup_if_ram235_bit3_set:
                JBS     off(00235h).3, dwell_base_lookup_clear_carry
                JBS     off(00218h).6, dwell_base_lookup_clear_carry
                LB      A, (0019ch-00180h)[USP]
                JNE     dwell_base_lookup_clear_carry
                CMPB    0d9h, #001h
                JGE     dwell_base_lookup_clear_carry
                JBS     off(0021ah).2, dwell_base_lookup_clear_carry
                JBR     off(00236h).2, dwell_base_lookup_load_ram2c1
                JBR     off(00236h).1, dwell_base_lookup_clear_carry
                SC
                JBR     off(00236h).0, dwell_base_lookup_store_carry_ram236_bit0
                LB      A, off(002c1h)
                JEQ     dwell_base_lookup_load_ram2c0
                MOVB    off(002c0h), #000h
dwell_base_lookup_clear_acc:
                CLRB    A
                SJ      dwell_base_lookup_store_ram2ff
dwell_base_lookup_load_ram2c0:
                LB      A, off(002c0h)
                RC
                JEQ     dwell_base_lookup_store_carry_ram236_bit0
                LB      A, r0
                MOV     X1, #dwell_base_lookup_tbl_3
                CAL     table_interp_lookup
dwell_base_lookup_store_ram2ff:
                STB     A, off(002ffh)
                LB      A, 0c2h
                MOV     X1, #dwell_base_lookup_tbl
                J       dwell_base_lookup_call_table_interp_lookup
ignsum_er3_start_load_ram2ff:
                LB      A, off(002ffh)
                ADD     er3, A
                CLR     A
                LB      A, off(00241h)
                J       ignsum_er3_start_load_acc
coldstart_full_reset_clear_ram232_bit7:
                RB      off(00232h).7
                RB      off(00236h).0
                J       coldstart_full_reset_clear_stk
knock_324_bit_store_clear_acc_2:
                CLRB    A
                LCB     A, boot_completion_helper_tbl_12
                J       knock_324_bit_store_if_eq_goto_7b36
coldstart_full_reset_store_tbl_x1_2:
                ST      A, 003a2h[X1]
                L       A, #0ffffh
                J       coldstart_full_reset_store_tbl_x1
dwell_base_lookup_tbl_2:       DB  000h
dwell_base_lookup_tbl_3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
