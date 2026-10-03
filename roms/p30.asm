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
code_start:     DB  000h,07Fh,031h,000h
int_NMI:        CLR     PSW
                MOV     LRB, #00041h  ; local register base = #00041h (base address 0x0208)
                RB      off(00230h).7  ; test-and-reset edge-detect bit 00230h.7
                JEQ     nmi_snapshot_dp_skip  ; skip snapshot if bit was already 0
                L       A, DP  ; bit just transitioned 1->0: snapshot DP
                ST      A, 00084h[X1]  ; ...into 00084h[X1]
nmi_snapshot_dp_skip:     MOV     DP, #00009h
nmi_poll_p4_1:     MB      C, P4.1  ; sample pin P4.1 into carry
                JGE     nmi_enter_lowpower_seq  ; JGE branches on Carry=0 (arch.ml) -> as soon as P4.1 reads 0, jump ahead immediately
                JRNZ    DP, nmi_poll_p4_1  ; else (P4.1 still 1) keep polling until DP counts out, then fall through anyway
                J       nmi_poll_p4_1_load_p2
nmi_poll_p4_1_store_adsel:     STB     A, ADSEL  ; clear A/D channel select
                MOV     IE, #00040h  ; mask interrupt-enable to one source
                MOVB    TCON1, #0e0h
                CLR     IRQ  ; clear pending IRQ flags
                SB      P4SF.1
                MOV     TM1, #0ffffh  ; reload timer1 to max (effectively stop it counting down soon)
                SB      TCON1.4
                SB      SBYCON.2  ; standby-control bit set (see routine note above)
                LB      A, #005h
; STPACP = "Stop Code Acceptor" per the MSM66207 datasheet -- not a clock prescaler. Writing
; N then N<<1 (5, then 10) is the write-unlock sequence this register requires before STOP/HALT
; mode will actually be entered; it's a safety interlock against accidental entry, not a divider.
                STB     A, STPACP  ; stop-code-acceptor unlock write, step 1: N=5
                SLLB    A  ; ...step 2: N<<1=10
                STB     A, STPACP  ; unlock write, step 2
                SB      SBYCON.0  ; standby-control bit 0 set (likely the actual STOP-mode trigger)
                RB      09fh.1
nmi_enter_lowpower_seq:     J       nmi_enter_lowpower_seq_load_ram0eb
                DW  00000h
int_timer_0:    MOV     LRB, #00037h
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
                ORB     off(001b7h), A
                LB      A, r6
                SLLB    A
                ROLB    r6
                MOV     er0, er2
                L       A, #00001h
                ST      A, er1
timer0_bitshift_loop:     ST      A, er2
                L       A, er0
                JNE     timer0_bit_shift_right
                L       A, er1
                JEQ     timer0_bit_invert
                LB      A, r6
                SRLB    A
                SRLB    A
                SRLB    A
                ORB     A, r6
timer0_bit_output:     ORB     A, off(001b7h)
                ANDB    A, #00fh
                ORB     P2, A
                RTI
timer0_bit_shift_right:     LB      A, r6
                SJ      timer0_bit_output
timer0_bit_invert:     LB      A, r6
                RORB    A
                XORB    A, #0ffh
                J       timer0_bit_output
timer0_return:     RTI
timer0_bit_accumulate:     ADD     TMR0, A
                LB      A, r6
                ANDB    A, #00fh
                ORB     r7, A
                ORB     off(001b7h), A
                LB      A, r6
                SLLB    A
                ROLB    r6
                MOV     er0, er1
                MOV     er1, er2
                L       A, #00001h
                J       timer0_bitshift_loop
timer0_final_bit_check:     L       A, er2
                JEQ     timer0_sequence_done
                ADD     TMR0, A
                LB      A, r6
                MB      C, ACC.0
                RORB    A
                STB     A, r6
                XORB    A, #0ffh
                ANDB    A, #00fh
                ORB     r7, A
                ORB     off(001b7h), A
                LB      A, r6
                ANDB    A, #00fh
timer0_sequence_reset:     ORB     P2, A
                L       A, #00001h
                ST      A, er0
                ST      A, er1
                ST      A, er2
                RTI
timer0_sequence_done:     LB      A, #00fh
                STB     A, r7
                STB     A, off(001b7h)
                SJ      timer0_sequence_reset
int_timer_1:    MOV     LRB, #00019h
                JBR     off(TCON1).3, timer1_tmr1_reload
                RB      off(0009eh).5
                JNE     timer1_check_start
                CMP     er1, #0064ah
                JLT     timer1_check_start
                ORB     off(0009eh), #020h
                L       A, #003b6h
                SUB     er1, A
                ADD     off(TMR1), A
                RTI
timer1_check_start:     ANDB    off(TCON1), #0f7h
                L       A, off(ADCR4)
                ST      A, er2
                ADD     off(TMR1), off(000cah)
                RTI
timer1_tmr1_reload:     ORB     off(TCON1), #008h
                INCB    r6
                L       A, #00a00h
                SUB     A, er0
                ST      A, er1
                ADD     off(TMR1), off(000c8h)
                RTI
int_timer_2:    MOV     LRB, #0001ah
                LB      A, r2
                CMPB    A, #003h
                JGE     timer2_state1_check
                ADDB    A, #001h
                JBS     off(ACC).0, timer2_state_dispatch
                MOV     off(000a2h), off(ADCR6)
timer2_state_dispatch:     CMPB    A, r0
                JEQ     timer3_reload_add
                JLT     timer3_reload_dec
timer2_tcon3_clear:     ANDB    off(TCON3), #0fbh
timer3_reload_dec:     L       A, off(TM3)
                SUB     A, #00001h
                ST      A, off(TMR3)
timer2_irq_clear:     ANDB    off(IRQH), #0f7h
                J       timer2_irq_clear_orb_off_irq
                DW  00000h
timer2_state1_check:     JEQ     timer2_state2_check
                JBR     off(ACC).0, timer2_tcon3_check2
                JBS     off(000d0h).3, timer2_tcon3_clear
                CLRB    A
                ORB     off(TCON3), #004h
                J       timer2_state_dispatch
timer2_state2_check:     LB      A, r0
                ADDB    A, #001h
                CMPB    A, #005h
                JGE     timer2_er3_calc
                ANDB    off(TCON3), #0fbh
                L       A, er2
                CMP     A, #0001fh
                JGE     timer2_tmr2_add
                L       A, #0001fh
timer2_tmr2_add:     ADD     A, off(TMR2)
                J       timer3_reload_store
timer2_tcon3_check:     JBS     off(TCON3).3, timer3_reload_dec
timer2_er3_calc:     L       A, off(TMR2)
                ADD     A, er2
                ST      A, er3
timer3_reload_add:     L       A, off(TMR2)
                ADD     A, off(000e0h)
                ST      A, off(TMR3)
                ANDB    off(TCON3), #0f7h
                SJ      timer2_irq_clear
timer2_tcon3_check2:     JBS     off(TCON3).2, timer2_tcon3_check
                L       A, off(TM3)
                SUB     A, off(TMR2)
                ADD     A, #00006h
                CMP     A, er2
                JGE     timer3_reload_alt
                L       A, off(TMR2)
                ADD     A, er2
                SJ      timer3_reload_store
timer3_reload_alt:     L       A, off(TM3)
                ADD     A, #00004h
timer3_reload_store:     ST      A, off(TMR3)
                ORB     off(TCON3), #008h
                J       timer2_irq_clear
int_INT0:       L       A, 0f4h
                ST      A, IE
                L       A, TM2
                ORB     PSWH, #001h
                MOV     LRB, #0001bh
                JBS     off(ACCH).7, int_int0_edge_check
                JBR     off(IRQH).0, int_int0_edge_check
                INCB    r3
                ORB     off(0009eh), #002h
int_int0_edge_check:     XCHG    A, er0
                ST      A, er2
                CLRB    A
                XCHGB   A, r3
                STB     A, r2
                ORB     off(0009eh), #004h
                L       A, off(000f2h)
                ANDB    PSWH, #0feh
                ST      A, off(IE)
                RTI
int_serial_rx:  L       A, 0f4h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #0006fh
                JBR     off(00354h).1, int_serial_rx_clear_acc
                RB      off(00354h).6
                JEQ     int_serial_rx_load_r7
                CLR     A
                LB      A, r5
                CMPB    A, #002h
                JEQ     int_serial_rx_load_r2
                CMPB    A, r2
                JGE     int_serial_rx_if_ne_goto_022e
                ADDB    A, r3
                L       A, ACC
                SLL     A
                ADD     A, #int_serial_rx_tbl
                MOV     DP, A
                LC      A, [DP]
                MOV     DP, A
                LB      A, [DP]
int_serial_rx_addb_r6:     ADDB    r6, A
int_serial_rx_store_stbuf:     STB     A, STBUF
                INCB    r5
                SB      off(00354h).6
int_serial_rx_load_ram0f2:     L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_serial_rx_load_r2:     LB      A, r2
                SJ      int_serial_rx_addb_r6
int_serial_rx_if_ne_goto_022e:     JNE     int_serial_rx_load_ram0f2
                CLRB    A
                SUBB    A, r6
                SJ      int_serial_rx_store_stbuf
int_serial_rx_load_r7:     LB      A, r7
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
int_serial_rx_store_r4:     STB     A, r4
int_serial_rx_addb_r6_2:     ADDB    r6, A
                INCB    r5
int_serial_rx_load_r7_2:     MOVB    r7, #002h
                J       int_serial_rx_load_ram0f2_2
int_serial_rx_load_r0:     MOVB    r0, r1
                LB      A, SRBUF
                STB     A, r1
                STB     A, r6
                MOVB    r5, #001h
                SJ      int_serial_rx_load_r7_2
int_serial_rx_load_srbuf:     LB      A, SRBUF
                STB     A, r2
                SJ      int_serial_rx_addb_r6_2
int_serial_rx_load_srbuf_2:     LB      A, SRBUF
                ADDB    A, r6
                JNE     int_serial_rx_clear_r7
                LB      A, r1
                ANDB    A, #0e0h
                CMPB    A, #020h
                JNE     int_serial_rx_clear_r7
                SB      off(00354h).7
int_serial_rx_clear_r7:     CLRB    r7
int_serial_rx_load_ram0f2_2:     L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_serial_rx_clear_acc:     CLRB    A
                RB      SRSTAT.3
                JEQ     int_serial_rx_clear_srstat_bit2
                ADDB    A, #001h
int_serial_rx_clear_srstat_bit2:     RB      SRSTAT.2
                JEQ     int_serial_rx_store_acch
                ADDB    A, #002h
int_serial_rx_store_acch:     STB     A, ACCH
                LB      A, SRBUF
                MOV     DP, A
                L       A, DP
                JEQ     int_serial_rx_load_dp
                SRL     A
                JLT     int_serial_rx_load_dp_ind
                L       A, [DP]
                LB      A, ACC
                MOVB    off(00358h), ACCH
int_serial_rx_store_stbuf_2:     STB     A, STBUF
                SJ      int_serial_rx_load_ram0f2
int_serial_rx_load_dp:     MOV     DP, #00358h
int_serial_rx_load_dp_ind:     LB      A, [DP]
                SJ      int_serial_rx_store_stbuf_2
                DB  0E5h,0F4h,0D5h,01Ah,0B5h,004h,098h,002h
                DB  001h,067h,000h,001h,0F5h,055h,0C5h,056h
                DB  00Bh,0CEh,00Ch,0C5h,006h,02Fh,0C5h,007h
                DB  015h,0CAh,004h,0C5h,007h,098h,002h,052h
                DB  0F2h,0D5h,051h,0E5h,0F2h,0A2h,008h,0B5h
                DB  01Ah,08Ah,002h
int_timer_2_overflow: L       A, 0f4h
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #0001bh
                RB      off(0009eh).0
                JNE     timer2ovf_edge_check2
                INCB    r6
timer2ovf_edge_check2:     RB      off(0009eh).1
                JNE     timer2ovf_return
                INCB    r3
timer2ovf_return:     L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_timer_3:    L       A, 0f4h
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #0001ah
                LB      A, r0
                ADDB    A, #001h
                CMPB    A, #005h
                JLT     timer3isr_return
                JBS     off(TCON3).2, timer3isr_return
                MOV     off(TMR3), er3
                ORB     off(TCON3), #008h
timer3isr_return:     L       A, off(000f2h)
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_PWM_timer:  L       A, 0f4h
                ST      A, IE
                ORB     PSWH, #001h
                MOV     LRB, #00070h
                JBS     off(00354h).0, int_PWM_timer_load_r2
                LB      A, r0
                ADDB    A, #001h
                CMPB    A, #064h
                JLT     int_PWM_timer_store_r0
                MOVB    r1, 0dfh
                CLRB    A
int_PWM_timer_store_r0:     STB     A, r0
                CMPB    A, r1
                MB      P4.3, C
                CMPB    A, #000h
                JNE     int_PWM_timer_load_ram0f2
                ORB     09eh, #008h
int_PWM_timer_load_ram0f2:     L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_PWM_timer_load_r2:     LB      A, r2
                JNE     int_PWM_timer_subb_acc
                MOVB    r3, 0e6h
                MOV     er2, 0e4h
                LB      A, #031h
int_PWM_timer_store_r2:     STB     A, r2
                CMPB    A, #00dh
                JNE     int_PWM_timer_cmp_acc
                ORB     09eh, #040h
int_PWM_timer_cmp_acc:     CMPB    A, r3
                JEQ     int_PWM_timer_load_er2
                L       A, #00001h
                JGE     pwm_output_store
                L       A, #0ffffh
pwm_output_store:     ST      A, PWMR0
                L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_PWM_timer_subb_acc:     SUBB    A, #001h
                SJ      int_PWM_timer_store_r2
int_PWM_timer_load_er2:     L       A, er2
                SJ      pwm_output_store
int_INT1:       L       A, #000a0h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #00021h
                MOV     USP, #00280h
                CAL     refresh_engine_flags_snapshot
                SB      off(00120h).4
                JBS     off(00112h).7, int1_dispatch_main_cycle
                JBS     off(00112h).3, int1_dispatch_alt1
                RB      IRQH.1
                JEQ     dtc04_ckp_latch
                RB      09ch.0
                MOVB    off(001a9h), #02dh
int1_dispatch_main_cycle:     J       crank_cycle_entry
dtc04_ckp_latch:     SB      09ch.0
int1_dispatch_alt1:     L       A, ADCR6
                ST      A, 0a2h
                L       A, TM2
                ST      A, TMR2
                MOVB    0d2h, #000h
                LB      A, #003h
                RB      TRNSIT.0
                JNE     crank_tooth_count_store
                LB      A, off(0012ah)
                ADDB    A, #006h
                CMPB    A, #018h
                JLT     crank_tooth_count_store
                LB      A, #003h
crank_tooth_count_store:     STB     A, off(0012ah)
                SB      P4.0
                J       crank_tooth_count_store_load_carry_ram113_bit6
crank_tooth_count_store_if_ram120_bit2_set:     JBS     off(00120h).2, int1_exit_jump
                LB      A, off(00135h)
                JNE     int1_exit_jump
                J       crank_tooth_count_store_set_ram120_bit2
int1_exit_jump:     J       crank_cycle_dispatch2
int_serial_rx_BRG: L       A, #000a0h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #00021h
                MOV     USP, #00280h
                L       A, (00212h-00280h)[USP]
                ST      A, off(00112h)
                L       A, (00214h-00280h)[USP]
                ST      A, off(00114h)
                L       A, (00216h-00280h)[USP]
                ST      A, off(00116h)
                MOVB    off(001a9h), #02dh
                JBR     off(00120h).3, crank_sync_flags_clear_path
                J       int_serial_rx_BRG_if_ram112_bit7_set
int_serial_rx_BRG_clear_irqh_bit7:     RB      IRQH.7
                JNE     crank_sync_lost_path
                RB      09eh.7
                JEQ     crank_sync_retry_check
crank_sync_lost_path:     SB      off(00120h).4
                RB      off(00120h).6
                MOVB    off(001aah), #02dh
                L       A, 0d2h
                CMP     A, #00005h
                JEQ     crank_tooth_counter_reset
                SB      off(0011dh).6
                JLT     crank_sync_lost_path_set_ram120_bit5
                CMP     A, #00105h
                JGE     crank_sync_flag_high
                SB      09dh.0
                SJ      crank_tooth_counter_reset
crank_sync_retry_check:     CMPB    0d2h, #005h
                JGE     crank_sync_confirm_check
                INCB    0d2h
                J       crank_tooth_counter_reset_goto_786c
crank_sync_confirm_check:     JBS     off(00112h).7, crank_sync_confirmed
dtc08_tdc_latch_2: SB      09ch.1
                SB      off(00120h).6
crank_sync_confirmed:     INCB    0d3h
                CLRB    0d2h
                SJ      crank_tooth_counter_reset_goto_786c
crank_sync_flags_clear_path:     RB      IRQH.7
                RB      09eh.7
                RB      09fh.2
                MB      C, 09fh.0
                JGE     crank_sync_exit_jump
                SB      off(00120h).4
crank_sync_exit_jump:     J       crank_decode_exit
crank_sync_lost_path_set_ram120_bit5:     SB      off(00120h).5
                SJ      crank_tooth_counter_reset
crank_sync_flag_high:     SB      09dh.1
crank_tooth_counter_reset:     CLR     0d2h
crank_tooth_counter_reset_goto_786c:     J       crank_tooth_counter_reset_if_ram113_bit0_set
crank_tooth_counter_reset_clear_ram09f_bit2:     RB      09fh.2
                JNE     crank_tooth_counter_reset_clear_ram120_bit7
crank_tooth_seq_check:     CMPB    off(0012ah), #017h
                JGE     crank_tooth_seq_gate
                INCB    off(0012ah)
                J       crank_tooth_mod_check
crank_tooth_seq_gate:     JBS     off(00113h).0, crank_tooth_seq_advance
dtc09_cyp_latch: SB      09ch.2
                SB      off(00120h).7
crank_tooth_seq_advance:     INCB    off(0012bh)
                CLRB    off(0012ah)
                SJ      crank_tooth_mod_check
crank_window_flag_check2:     RB      off(00120h).5
                JGE     crank_tooth_reset
                JEQ     crank_window_flag_check2_set_ram09d_bit2
                SB      09dh.0
                SJ      crank_tooth_reset
crank_sync_flag_low:     SB      09dh.1
                SJ      crank_tooth_reset
crank_tooth_counter_reset_clear_ram120_bit7:     RB      off(00120h).7
                MOVB    off(001abh), #007h
                L       A, off(0012ah)
                CMP     A, #00017h
                JNE     crank_window_flag_check2
                RB      off(00120h).5
                JNE     crank_sync_flag_low
                RB      off(0011dh).6
                CMPB    0d2h, #003h
                JEQ     crank_tooth_reset
crank_window_flag_check2_set_ram09d_bit2:     SB      09dh.2
crank_tooth_reset:     CLR     off(0012ah)
crank_tooth_mod_check:     JBS     off(00112h).7, crank_tooth_mod6_calc
                JBS     off(00120h).6, crank_tooth_mod6_calc
crank_tooth_range_check:     JBS     off(00113h).0, crank_tooth_wrap_calc
                JBS     off(00120h).7, crank_tooth_wrap_calc
crank_tooth_carry_clear:     RC
                JBR     off(00113h).6, crank_sync_store_flag
                SJ      crank_sync_confirmed_flag
crank_tooth_mod6_calc:     CLR     A
                MOVB    r0, #006h
                LB      A, off(0012ah)
                ADDB    A, #003h
                DIVB
                LB      A, r1
                STB     A, 0d2h
                SJ      crank_tooth_range_check
crank_tooth_wrap_calc:     MOVB    r0, #006h
                LB      A, 0d2h
                ADDB    A, #003h
                SUBB    A, r0
                JGE     crank_tooth_wrap_store
                ADDB    A, r0
crank_tooth_wrap_store:     STB     A, r2
                CLR     A
                LB      A, off(0012ah)
                DIVB
                MULB
                ADDB    A, r2
                STB     A, off(0012ah)
                JBS     off(00112h).7, crank_sync_confirmed_flag
                JBR     off(00120h).6, crank_tooth_carry_clear
crank_sync_confirmed_flag:     SC
                SB      off(0011ch).2
crank_sync_store_flag:     MB      off(00122h).1, C
                LB      A, off(0012ah)
                EXTND
                MOV     X1, A
                LCB     A, tbl_crank_sync_pattern[X1]
                ANDB    off(00120h), A
                LB      A, off(0012ah)
                JNE     crank_sync_flag2_check
                JBR     off(00120h).2, crank_resync_reset
                JBS     off(00120h).0, crank_tooth_alt_flag
                RB      off(00120h).1
                SJ      crank_tooth_alt_store
crank_resync_reset:     RB      PSWH.0
                MOVB    off(001b6h), #077h
                MOVB    off(001beh), #011h
                ANDB    off(00120h), #0fch
                SB      PSWH.0
                SJ      crank_tooth_alt_store
crank_tooth_alt_flag:     LB      A, #001h
                JBR     off(00120h).1, crank_tooth_alt_store
                LB      A, #002h
crank_tooth_alt_store:     STB     A, off(00134h)
crank_sync_flag2_check:     JBS     off(00120h).2, crank_sync_bit_check
                CMPB    off(00135h), #004h
                JEQ     crank_cycle_exit_early
                LB      A, off(00135h)
                JNE     crank_sync_bit_check
                LB      A, 0d2h
                JNE     crank_sync_bit_check
                SB      off(00120h).2
crank_sync_bit_check:     LB      A, off(00134h)
                ANDB    A, #001h
                TRB     off(00120h)
                JNE     crank_cycle_exit_early
                CLR     A
                LB      A, off(0012ah)
                JBR     off(00134h).0, crank_tooth_pattern_lookup
                ADDB    A, #006h
crank_tooth_pattern_lookup:     MOV     X1, A
                LCB     A, tbl_crank_tooth_pattern[X1]
                CMPB    A, off(00133h)
                JGE     crank_cycle_dispatch2
crank_cycle_exit_early:     J       crank_decode_exit
crank_cycle_dispatch2:     LB      A, off(00134h)
                SLLB    A
                EXTND
                MOV     X1, A
                JBS     off(0011dh).4, injtimer_countdown_check
                CLR     A
                MOV     X2, A
                ST      A, 003b6h[X2]
                ST      A, 003b8h[X2]
                ST      A, 003bah[X2]
                ST      A, 003bch[X2]
                CLRB    A
                STB     A, off(001cbh)
                J       injtimer_bit_clear
injtimer_clear_path1:     SBR     off(001cdh)
                SB      off(00122h).7
                SB      off(001c9h).0
                SJ      injbase_calc_start
injtimer_clear_path2:     L       A, off(00144h)
                SJ      injtimer_clamp_store
injtimer_countdown_check:     LB      A, off(001cch)
                SUBB    A, #001h
                JGE     injtimer_countdown_store
                LB      A, #007h
injtimer_countdown_store:     STB     A, off(001cch)
                CMPB    A, #007h
                JGT     injtimer_bit_clear
                MBR     C, off(001cbh)
                JLT     injtimer_clear_path1
                ADDB    A, #004h
                RBR     off(001cdh)
                JNE     injtimer_clear_path2
                L       A, 003b6h[X1]
                SUB     A, #00096h
                JGE     injtimer_clamp_store
                CLR     A
injtimer_clamp_store:     ST      A, 003b6h[X1]
injtimer_bit_clear:     RB      off(001c9h).0
injbase_calc_start:     CLR     A
                JBS     off(0011ch).4, injbase_store
                JBS     off(00122h).1, injbase_store
                L       A, 003aeh[X1]
                ADD     A, 003b6h[X1]
                JGE     injbase_store
                L       A, #0ffffh
injbase_store:     ST      A, off(001c6h)
                LB      A, off(00134h)
                RB      PSWH.0
                TRB     off(001bfh)
                JEQ     injbase_store_if_ram120_bit2_clr
                L       A, TMR0
                SUB     A, TM0
                CMP     A, #00005h
                JLT     injbase_store_set_pswh_bit0
                CMP     A, #00021h
                JLT     injbase_store_set_pswh_bit0_2
injbase_store_set_pswh_bit0:     SB      PSWH.0
                RB      off(00122h).3
                J       crank_tooth_flag_update
injbase_store_if_ram120_bit2_clr:     JBR     off(00120h).2, tm0_sync_common
                L       A, TM0
                SUB     A, TMR0
                JEQ     tm0_sync_common
                MB      C, IRQ.5
                JLT     tm0_sync_common
                ADD     A, #00005h
                JLT     tm0_sync_common
                ADD     TMR0, A
tm0_sync_common:     SB      PSWH.0
                CAL     tm0_resync_helper
                SB      off(00122h).3
                SJ      crank_tooth_flag_update
injbase_store_set_pswh_bit0_2:     SB      PSWH.0
                CAL     tm0_resync_helper
                SB      off(00122h).3
crank_tooth_flag_update:     CAL     crank_helper2
                LB      A, off(00134h)
                STB     A, r0
                ANDB    A, #001h
                SBR     off(00120h)
                INCB    r0
                LB      A, r0
                ANDB    A, #003h
                STB     A, off(00134h)
                JBS     off(00117h).3, crank_decode_exit
                JBS     off(00113h).7, crank_decode_exit
                RB      off(00122h).0
                JEQ     crank_decode_exit
                RB      TRNSIT.2
                JNE     crank_decode_exit
dtc16_injector_latch: SB      09ch.6
crank_decode_exit:     RB      off(00122h).3
                JNE     crank_decode_final_check
                CAL     tm0_resync_helper
crank_decode_final_check:     LB      A, 0d2h
                CMPB    A, #003h
                JNE     crank_cycle_dispatch
crank_cycle_dispatch_body:     JBS     off(0011eh).0, crank_cycle_period_saturate
                JBS     off(00117h).1, crank_cycle_period_saturate
                CMPB    A, #003h
                CLR     er2
                JBS     off(00122h).5, crank_cycle_alt_dp
                MOV     DP, #00366h
                JEQ     crank_cycle_dp_common
                CLR     A
                SJ      crank_cycle_er2_store
crank_cycle_alt_dp:     MOV     DP, #00362h
                JNE     crank_cycle_dp_common
                MOV     er2, [DP]
crank_cycle_dp_common:     L       A, [DP]
                CLR     er0
                MOVB    r1, 0cfh
                MUL
                L       A, er2
                ADD     A, er1
                JGE     crank_cycle_er2_store
crank_cycle_period_saturate:     L       A, #0ffffh
crank_cycle_er2_store:     ST      A, 0d4h
crank_cycle_entry:     L       A, off(0011ch)
                ST      A, (0021ch-00280h)[USP]
                RB      PSWH.0
int1_rti_epilogue:     L       A, 0f2h
                ST      A, IE
                RTI
crank_cycle_dispatch:     JGE     crank_cycle_dispatch_alt
                CMPB    A, #001h
                JGE     crank_cycle_dispatch_alt2
                JBS     off(00113h).6, crank_cycle_p4_gate
                JBS     off(0011dh).6, crank_cycle_p4_gate
                CMP     0ach, #000e2h
                JLT     crank_cycle_p4_gate
                RB      TRNSIT.1
                JNE     crank_cycle_p4_gate
dtc15_ign_output_latch: SB      09ch.3
                SJ      crank_cycle_p4_gate_if_ram117_bit2_set
crank_cycle_p4_gate:     RB      09ch.3
                MOVB    off(001ach), #006h
crank_cycle_p4_gate_if_ram117_bit2_set:     JBS     off(00117h).2, crank_cycle_dispatch_alt2_if_ram120_bit4_clr
                J       crank_cycle_p4_gate_if_ram121_bit1_clr
crank_cycle_f4_check:     LB      A, #001h
                CMPB    0eah, #024h
                JNE     crank_cycle_counter_check
                SB      off(00122h).4
crank_cycle_counter_check:     CMPB    off(001aah), #028h
                JLE     crank_cycle_result_b
                JBS     off(00117h).4, crank_cycle_result_a
                JBS     off(00122h).4, crank_cycle_result_common
                JBS     off(00112h).5, crank_cycle_result_a
                CMPB    0c1h, #020h
                JLT     crank_cycle_result_common
crank_cycle_result_a:     LB      A, #003h
                SJ      crank_cycle_result_common
crank_cycle_result_b:     SB      off(00120h).4
crank_cycle_result_common:     SRLB    A
                MB      off(0011eh).0, C
                SRLB    A
                MB      P4.0, C
                SJ      crank_cycle_entry
crank_cycle_dispatch_alt:     CMPB    A, #004h
                JNE     crank_cycle_entry
                J       crank_cycle_dispatch_body
crank_cycle_bailout:     SJ      crank_cycle_entry
crank_cycle_dispatch_alt2:     JEQ     crank_cycle_entry
crank_cycle_dispatch_alt2_if_ram120_bit4_clr:     JBR     off(00120h).4, crank_cycle_bailout
                INCB    off(00136h)
                JBS     off(00122h).2, crank_cycle_bailout
                LB      A, off(0011ch)
                ANDB    A, #003h
                ANDB    off(00136h), A
                JNE     crank_cycle_bailout
                L       A, 0f2h
                RB      PSWH.0
                SB      off(00122h).2
                SB      PSWH.0
                ST      A, IE
                CAL     crank_edge_helper
                MOV     PSW, #01101h
                MOV     LRB, #00040h
                MOV     USP, #00180h
                MOV     DP, #003d2h
                MOVB    r0, [DP]
                LB      A, 0c5h
                STB     A, [DP]
                LB      A, ADCR2H
                STB     A, 0c5h
                SUBB    A, r0
                MB      off(0022bh).5, C
                JGE     crank_cycle_adc_prep
                VCAL    7
crank_cycle_adc_prep:     STB     A, 0c6h
                LB      A, P2
                ANDB    A, #0e0h
                STB     A, off(00255h)
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                RB      ADSCAN.4
                ANDB    P2, #01fh
                SB      ADSCAN.4
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MOV     DP, #00360h
                CLR     A
                ST      A, er0
                ST      A, er1
crank_cycle_adc_prep_load_dp_ind:     L       A, [DP]
                JEQ     rpm_period_invalid
                ADD     er1, A
                ADCB    r0, #000h
                INC     DP
                INC     DP
                CMP     DP, #0036ch
                JLT     crank_cycle_adc_prep_load_dp_ind
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
                MOV     DP, #0036ch
                XCHG    A, 0ach
                ST      A, er1
                XCHG    A, [DP]
                INC     DP
                INC     DP
                XCHG    A, [DP]
                INC     DP
                INC     DP
                XCHG    A, [DP]
                ST      A, er2
                L       A, er0
                SUB     A, er2
                MB      off(0021bh).7, C
                JGE     rpm_accel_limit_check
                VCAL    7
rpm_accel_limit_check:     ST      A, 0b0h
                L       A, er0
                SUB     A, er1
                MB      off(0021bh).6, C
                JGE     rpm_decel_limit_check
                VCAL    7
rpm_decel_limit_check:     ST      A, 0aeh
                L       A, 0ach
                CMP     A, #000eah
                JLT     rpm_period_normalize_lowrange
                CMP     A, #00ea6h
                JGE     rpm_period_normalize_highrange
                ST      A, er2
                MOV     er3, #0ffc0h
                MOV     er0, #00007h
                MOV     X1, #05300h
                MOV     DP, #rpm_decel_limit_check_tbl
rpm_divide_normalize_loop:     LC      A, [DP]
                CMP     er2, A
                JGE     rpm_divide_normalize_loop_load_x1
                SRL     er0
                ROR     X1
                ADD     er3, #00040h
                INC     DP
                INC     DP
                SJ      rpm_divide_normalize_loop
rpm_divide_normalize_loop_load_x1:     L       A, X1
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
                MB      0a0h.7, C
                STB     A, (0012dh-00180h)[USP]
                XCHGB   A, off(00236h)
                STB     A, 0abh
                CLRB    r7
                JBS     off(00217h).4, loadindex_flag_default
                DECB    r7
                MOV     er2, 0ach
                MOV     er0, #0d000h
                CLR     A
                DIV
                SLL     A
                SB      PSWL.4
                LB      A, r1
                JNE     loadindex_flag_load
                MB      PSWL.4, C
                LB      A, r0
                JNE     loadindex_store
                MOVB    r7, #001h
loadindex_flag_default:     RB      PSWL.4
loadindex_flag_load:     LB      A, r7
loadindex_store:     STB     A, 0aah
                MB      C, PSWL.4
                MB      0a0h.6, C
                JBS     off(00212h).2, map_sign_flag_clear
                L       A, 0a2h
                SWAP
                LB      A, ACC
                CMPB    A, #0a1h
                JGT     dtc03_map_latch
                CMPB    A, #00bh
                JGE     map_neg_helper_call
dtc03_map_latch:     SB      098h.0
                LB      A, off(00235h)
                SJ      map_sign_gate2
map_neg_helper_call:     CAL     subtract24_clamp_byte
map_sign_flag_clear:     RB      098h.0
                JBS     off(00212h).2, map_sign_gate3
map_sign_gate2:     JBR     off(00212h).4, map_sign_gate4
map_sign_gate3:     LB      A, 0b9h
                MOV     X1, #tbl_map_sign
                VCAL    2
map_sign_gate4:     STB     A, r0
                LB      A, off(00235h)
                SUBB    A, r0
                MB      off(0021bh).4, C
                JGE     map_delta_store
                VCAL    7
map_delta_store:     STB     A, 0a8h
                MOV     DP, #00373h
                LB      A, [DP]
                SUBB    A, r0
                MB      off(0021bh).5, C
                JGE     map_delta2_store
                VCAL    7
map_delta2_store:     STB     A, 0a9h
                LB      A, r0
                STB     A, (0012ch-00180h)[USP]
                XCHGB   A, off(00235h)
                XCHGB   A, 0a5h
                DEC     DP
                XCHGB   A, [DP]
                INC     DP
                STB     A, [DP]
                LB      A, #059h
                JBS     off(00212h).2, tps_custom_clamp_store
                JBS     off(00212h).4, tps_custom_clamp_store
                LB      A, 0a4h
                SUBB    A, off(00235h)
                JGE     tps_custom_clamp_store
                CLRB    A
tps_custom_clamp_store:     STB     A, 0a6h
                MOV     er0, #04d00h
                RC
                JBS     off(00212h).6, dtc07_tps_latch
                MOV     er0, ADCR7
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc07_tps_latch
                CMPB    r1, #005h
dtc07_tps_latch:     MB      098h.2, C
                JLT     tps_delta_alt_path
                L       A, er0
                SLL     A
                JLT     tps_delta_clamp1
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store1
tps_delta_clamp1:     LB      A, #0ffh
tps_delta_store1:     STB     A, 0bch
                L       A, er0
                XCHG    A, 0b8h
                MOV     er1, 0bah
                ST      A, 0bah
                JBR     off(00212h).6, tps_delta_check1
tps_delta_alt_path:     L       A, er0
                MOV     er1, 0b8h
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
                XCHGB   A, 0bdh
                JEQ     tps_delta_sign_check
                XORB    PSWH, #080h
tps_delta_sign_check:     JLT     tps_delta_flag_store
                CMPB    A, r0
tps_delta_flag_store:     MB      off(0021bh).3, C
                L       A, er1
                SUB     A, 0b8h
                MB      off(0021bh).2, C
                JGE     tps_delta_clamp3
                VCAL    7
tps_delta_clamp3:     SLL     A
                JLT     tps_delta_clamp3_max
                SLL     A
                LB      A, ACCH
                JGE     tps_delta_store3
tps_delta_clamp3_max:     LB      A, #0ffh
tps_delta_store3:     STB     A, 0beh
                L       A, off(00292h)
                ST      A, er0
                LB      A, r1
                JBR     off(0021ah).2, tps_delta_compare_final
                LB      A, r0
tps_delta_compare_final:     CMPB    A, off(00236h)
                MB      off(0021ah).2, C
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
                CMPB    A, 0bch
                MB      off(00218h).2, C
                LB      A, #004h
                JBS     off(00218h).4, tps_window_calc3
                LB      A, #007h
tps_window_calc3:     ADDB    A, r4
                CMPB    A, 0bch
                MB      off(00218h).4, C
                LB      A, r2
                MB      C, off(00218h).0
                MB      off(00218h).1, C
                JGE     tps_window_calc4
                MOVB    r0, r1
                LB      A, r3
tps_window_calc4:     ADDB    A, r4
                CMPB    0bch, A
                JGE     tps_window_store2
                LB      A, off(00236h)
                CMPB    A, r0
tps_window_store2:     MB      off(00218h).0, C
                MOVB    r0, 0a8h
                MOVB    r1, off(00235h)
                JBS     off(0021ch).0, tps_interp_exact_match
                JBR     off(0021ah).2, tps_interp_exact_match
                JBS     off(00210h).7, tps_interp_exact_match
                JBS     off(00212h).2, tps_interp_exact_match
                JBS     off(00212h).4, tps_interp_exact_match
                MOVB    r4, #0ffh
                LB      A, 0a5h
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
tps_table_offset_check:     JBS     off(0021bh).4, tps_table_lookup
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
                JBR     off(0021bh).4, tps_interp_sub_check
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
                JBS     off(0021bh).4, tps_interp_clamp_result
tps_interp_store:     STB     A, 0a7h
                L       A, 0ach
                SUB     A, off(00258h)
                MB      off(0021ah).5, C
                J       tps_interp_store_load_er0
rpm_avg_range_check_store_ram0b2:     ST      A, 0b2h
                LB      A, #098h
                JBS     off(0022bh).0, threshold_bank_218_5
                LB      A, #0a0h
threshold_bank_218_5:     CMPB    A, off(00236h)
                MB      off(0022bh).0, C
                LB      A, #0cdh
                JBS     off(00218h).7, threshold_bank_218_5_cmp_acc
                LB      A, #0d0h
threshold_bank_218_5_cmp_acc:     CMPB    A, off(00236h)
                MB      off(00218h).7, C
                LB      A, #03ah
                JBS     off(00217h).0, threshold_bank_217_0
                LB      A, #040h
threshold_bank_217_0:     CMPB    A, off(00236h)
                MB      off(00217h).0, C
                MOV     X1, #Scaler_RpmAxis_Lo
                MOVB    r3, (001d8h-00180h)[USP]
                MOVB    r2, off(00236h)
                MOVB    r6, #012h
                MB      C, 0a0h.7
                MB      PSWL.4, C
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001dah-00180h)[USP]
                LB      A, r6
                STB     A, (001d8h-00180h)[USP]
                MOV     X1, #Scaler_RpmAxis_Hi
                MOVB    r3, (001d9h-00180h)[USP]
                MOVB    r2, 0aah
                MOVB    r6, #012h
                J       threshold_bank_217_0_load_carry_ram0a0_bit6
threshold_bank_217_0_store_carry_pswl_bit4:     MB      PSWL.4, C
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001dch-00180h)[USP]
                LB      A, r6
                STB     A, (001d9h-00180h)[USP]
                LB      A, 0a4h
                JBS     off(00212h).2, newval_table3_call
                JBS     off(00212h).4, newval_table3_call
                LB      A, 0a7h
newval_table3_call:     STB     A, r2
                MOV     X1, #newval_table3_call_tbl_3
                MOVB    r3, (001d2h-00180h)[USP]
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001d4h-00180h)[USP]
                LB      A, r6
                STB     A, (001d2h-00180h)[USP]
                LB      A, 0a7h
                STB     A, r2
                MOV     X1, #newval_table3_call_tbl_3
                MOVB    r3, (001d3h-00180h)[USP]
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     newval_table3_call_sub_clear_acc
                STB     A, (001d6h-00180h)[USP]
                LB      A, r6
                STB     A, (001d3h-00180h)[USP]
                JBR     off(00216h).7, newval_table3_call_clear_carry
                JBR     off(00216h).3, newval_table3_call_clear_carry
                MB      C, off(00226h).5
                MB      PSWL.4, C
                LB      A, #0ffh
                CMPB    A, off(002f2h)
                MB      off(00226h).5, C
                JGE     newval_table3_call_load_dp
                XORB    PSWL, #010h
newval_table3_call_load_dp:     MOV     DP, #00386h
                JBS     off(0021fh).1, newval_table3_call_clear_acc
                JBR     off(00214h).5, newval_table3_call_load_imm
                JBS     off(00218h).7, newval_table3_call_clear_carry
newval_table3_call_load_imm:     LB      A, #0ffh
                JBS     off(0021dh).7, newval_table3_call_store_ram2f0
                LB      A, off(002f0h)
                JNE     newval_table3_call_subb_acc
newval_table3_call_clear_acc:     CLR     A
                ST      A, [DP]
newval_table3_call_clear_carry:     RC
                SJ      newval_table3_call_store_carry_ram219_bit6
newval_table3_call_subb_acc:     SUBB    A, #001h
newval_table3_call_store_ram2f0:     STB     A, off(002f0h)
                MOV     X1, #newval_table3_call_tbl
                JBS     off(00226h).5, newval_table3_call_load_carry_pswl_bit4
                INC     DP
                MOV     X1, #newval_table3_call_tbl_2
newval_table3_call_load_carry_pswl_bit4:     MB      C, PSWL.4
                JGE     newval_table3_call_load_carry_ram226_bit5
                LB      A, off(00235h)
                VCAL    2
                STB     A, [DP]
newval_table3_call_load_carry_ram226_bit5:     MB      C, off(00226h).5
                LB      A, [DP]
                JEQ     newval_table3_call_store_carry_ram219_bit6
                DECB    [DP]
                XORB    PSWH, #080h
newval_table3_call_store_carry_ram219_bit6:     MB      off(00219h).6, C
                CLR     er2
                SC
                JBR     off(00227h).6, mode_flags_pack4
                LB      A, (001d2h-00180h)[USP]
                ADDB    A, #001h
                CMPB    0a7h, #000h
                JNE     mode_flags_pack_start
                CLRB    A
mode_flags_pack_start:     MOV     er0, off(00212h)
                AND     er0, #0c3bch
                JNE     mode_flags_pack_alt
                MB      C, off(00214h).5
                JGE     mode_flags_pack_store
mode_flags_pack_alt:     LB      A, #00fh
mode_flags_pack_store:     STB     A, r1
                RC
                JBS     off(00214h).5, mode_flags_pack2
                MB      C, off(00211h).1
mode_flags_pack2:     MB      off(00233h).3, C
                MB      C, off(0021ch).2
                MB      off(00233h).4, C
                SC
                LB      A, (001cah-00180h)[USP]
                JNE     mode_flags_pack3
                LB      A, off(0023ch)
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
                LB      A, (001abh-00180h)[USP]
                CMPB    A, #007h
                JLT     mode_flags_pack4
                LB      A, (001b3h-00180h)[USP]
                CMPB    A, #019h
                JLT     mode_flags_pack4
                MB      C, off(0021dh).6
mode_flags_pack4:     MB      off(00233h).6, C
                L       A, er2
                ST      A, 0eeh
                MOV     DP, #003beh
                LB      A, ADCR0H
                STB     A, [DP]
                STB     A, 0c2h
                MOV     DP, #003c6h
                LB      A, ADCR1H
                STB     A, [DP]
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                RB      ADSCAN.4
                ORB     P2, off(00255h)
                RB      IRQH.4
                SB      ADSCAN.4
                MOV     off(00256h), TM2
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                JBS     off(0021dh).4, ignmap_alt_path
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, (001d2h-00180h)[USP]
                MOV     X2, (001d4h-00180h)[USP]
                MOVB    r3, (001d9h-00180h)[USP]
                MOV     er3, (001dch-00180h)[USP]
                MOV     X1, #mode_flags_pack4_tbl
                J       flag_dispatch_21d_212
flag_dispatch_21d_212_load_r3:     MOVB    r3, (001d8h-00180h)[USP]
                MOV     er3, (001dah-00180h)[USP]
                MOV     X1, #flag_dispatch_21d_212_tbl
                JBR     off(00214h).5, flag_dispatch_21d_212_if_ram213_bit3_set
                JBS     off(00218h).7, ignmap_2d_lookup
flag_dispatch_21d_212_if_ram213_bit3_set:     JBS     off(00213h).3, flag_dispatch_21d_212_load_imm
                JBR     off(00219h).6, ignmap_2d_lookup
flag_dispatch_21d_212_load_imm:     LB      A, #000h
                CMPB    A, r3
                JGT     ignmap_2d_lookup
                ADDB    A, #00ah
                CMPB    A, r3
                JLE     ignmap_2d_lookup
                SUBB    r3, #000h
                MOVB    r1, #00bh
                MOV     X1, #flag_dispatch_21d_212_tbl_2
ignmap_2d_lookup:     RB      PSWL.5
                CAL     table2d_lookup_interp
                LB      A, r4
                SJ      ignmap_result_common
ignmap_alt_path:     LB      A, 0aah
                MOV     X1, #ignmap_alt_path_tbl
                JBS     off(0021fh).1, ignmap_alt_path_vcal_0
                LB      A, off(00236h)
                MOV     X1, #ignmap_alt_path_tbl_2
ignmap_alt_path_vcal_0:     VCAL    0
ignmap_result_common:     STB     A, off(00244h)
                CLRB    A
                CMPB    0c1h, #02eh
                JGE     idleign_result_store
                JBR     off(00218h).0, idleign_result_store
                JBS     off(00210h).7, idleign_result_store
                L       A, 0b2h
                MOV     X1, #IgnControl
                JBS     off(0021ah).5, idleign_table_lookup
                MOV     X1, #HiIdleIgnControl
idleign_table_lookup:     CAL     table_interp_lookup_4byte
                MOVB    r0, #008h
                LB      A, r6
                CMPB    A, r0
                JLT     idleign_vcal6_check
                LB      A, r0
idleign_vcal6_check:     JBR     off(0021ah).5, idleign_result_store
                VCAL    7
idleign_result_store:     STB     A, off(00240h)
                LB      A, #012h
                JBS     off(00221h).3, rpm_threshold_221_3
                LB      A, #010h
rpm_threshold_221_3:     CMPB    0adh, A
                MB      off(00221h).3, C
                LB      A, #000h
                JBS     off(00221h).4, rpm_threshold_221_4
                LB      A, #001h
rpm_threshold_221_4:     CMPB    A, off(00236h)
                MB      off(00221h).4, C
                CLRB    A
                MOV     X1, #tbl_ignmap_idle2
                JBS     off(00221h).2, knockretard_table_gate
                INC     X1
                MB      C, off(00221h).3
knockretard_table_gate:     JGE     knockretard_store
                L       A, off(00252h)
                ST      A, er3
                LB      A, off(00235h)
                CAL     table_interp_lookup_prescan
                JBR     off(00221h).2, knockretard_store
                VCAL    7
knockretard_store:     STB     A, off(0023fh)
                LB      A, #05ah
                JBS     off(00220h).2, rpm_threshold_222_5
                LB      A, #060h
rpm_threshold_222_5:     CMPB    A, off(00236h)
                MB      off(00220h).2, C
                CLRB    A
                JBR     off(00227h).7, knockretard2_clamp_store_ram238
                JBS     off(00213h).1, knockretard2_clamp_store_ram238
                JGE     knockretard2_clamp_store_ram238
                CMPB    0c0h, #0b5h
                JGE     knockretard2_clamp_store_ram238
                JBS     off(0021dh).5, knockretard2_clamp_store_ram238
                JBS     off(0021ah).4, knockretard2_clamp_store_ram238
                JBR     off(0021ah).3, knockretard2_clamp_store_ram238
                CLR     A
                LB      A, off(00254h)
                MOV     er3, A
                LB      A, off(00235h)
                MOV     X1, #tbl_ignmap_idle1
                CAL     table_interp_lookup_prescan
                LB      A, off(00238h)
                ADDB    A, #001h
                JLT     knockretard2_clamp
                CMPB    A, r6
                JLT     knockretard2_clamp_store_ram238
knockretard2_clamp:     LB      A, r6
knockretard2_clamp_store_ram238:     STB     A, off(00238h)
                JBR     off(00216h).2, overrev_hardcap_compare_load_ram2ad
                LB      A, #07ah
                JBS     off(00216h).3, overrev_hardcap_compare
                LB      A, #07ah
overrev_hardcap_compare:     CMPB    A, off(00236h)
                JLT     overrev_hardcap_compare_load_ram2ad
                LB      A, 0b4h
                CMPB    A, #02dh
                JGE     overrev_hardcap_compare_load_ram2ad
                CMPB    A, #023h
                JLT     overrev_hardcap_compare_load_ram2ad
                CMPB    0c1h, #028h
                JGE     overrev_hardcap_compare_load_ram2ad
                CMPB    off(00235h), #064h
                JGE     overrev_hardcap_compare_load_ram2ad
                JBR     off(0021ah).4, overrev_hardcap_compare_cmp_ram2ad
overrev_hardcap_compare_load_ram2ad:     MOVB    off(002adh), #060h
                CLRB    A
                STB     A, r0
                RB      off(00220h).3
                SJ      overrev_hardcap_compare_store_ram251
overrev_hardcap_compare_cmp_ram2ad:     CMPB    off(002adh), #00ch
                JGE     overrev_hardcap_compare_goto_596d
                LB      A, off(002adh)
                JEQ     overrev_hardcap_compare_cmp_acc
                MOVB    off(002ach), #060h
                SJ      overrev_hardcap_compare_load_r0
overrev_hardcap_compare_cmp_acc:     CMPB    A, off(002ach)
                MB      off(00220h).3, C
overrev_hardcap_compare_load_r0:     MOVB    r0, off(00239h)
                LB      A, off(00251h)
                JEQ     overrev_hardcap_compare_addb_r0
                SUBB    A, #001h
                SJ      overrev_hardcap_compare_store_ram251
overrev_hardcap_compare_addb_r0:     ADDB    r0, #002h
                LB      A, #004h
overrev_hardcap_compare_store_ram251:     STB     A, off(00251h)
                LB      A, #015h
                CMPB    A, r0
                JLE     overrev_hardcap_compare_store_ram239
                LB      A, r0
overrev_hardcap_compare_store_ram239:     STB     A, off(00239h)
overrev_hardcap_compare_goto_596d:     J       overrev_hardcap_compare_load_imm_2
                DW  00000h
overrev_hardcap_compare_if_ne_goto_0c95:     JNE     overrev_hardcap_compare_goto_789a
                MOV     X1, #overrev_hardcap_compare_tbl_2
                J       overrev_hardcap_compare_load_carry_ram0a0_bit1
overrev_hardcap_compare_goto_789a:     J       overrev_hardcap_compare_cmp_stk
                DB  000h,000h,000h
overrev_hardcap_compare_load_imm:     LB      A, #01dh
knockretard2_store:     STB     A, off(0023bh)
                CLRB    A
                RC
                JBS     off(00233h).6, flags_pack_233_7
                JBS     off(00212h).3, flags_pack_233_7
                JBS     off(00213h).0, flags_pack_233_7
                L       A, 0f0h
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
                CMPB    0adh, #00dh
                JGT     knock_244_store
                JBS     off(00212h).3, knock_244_table_select
                JBS     off(00213h).0, knock_244_table_select
                JBS     off(00214h).7, knock_244_table_select
                JBS     off(00233h).6, flags_pack_sj
                JBS     off(00233h).7, flags_pack_sj
                LB      A, r5
                SJ      knock_244_store
knock_244_table_select:     LB      A, (001d9h-00180h)[USP]
                MOV     er0, (001dch-00180h)[USP]
                MOV     DP, #tbl_knock244_a
                JBS     off(0021fh).1, knock_244_lookup
                LB      A, (001d8h-00180h)[USP]
                MOV     er0, (001dah-00180h)[USP]
                MOV     DP, #tbl_knock244_b
knock_244_lookup:     CAL     knock_244_helper
knock_244_store:     STB     A, off(00243h)
flags_pack_sj:     LB      A, #03ah
                MOVB    r0, #040h
                CMPB    0a4h, #0dbh
                JGE     flags_pack_sj_if_ram222_bit0_set
                LB      A, #093h
                MOVB    r0, #097h
flags_pack_sj_if_ram222_bit0_set:     JBS     off(00222h).0, flags_pack_sj_cmp_acc
                LB      A, r0
flags_pack_sj_cmp_acc:     CMPB    A, off(00236h)
                MB      off(00222h).0, C
                CLRB    A
                JBR     off(0021dh).5, flags_pack_sj_store_ram23e
                JGE     flags_pack_sj_store_ram23e
                MOV     X1, #flags_pack_sj_tbl
                JBR     off(0021eh).3, flags_pack_sj_load_ram236
                MOV     X1, #TipinTPS
flags_pack_sj_load_ram236:     LB      A, off(00236h)
                VCAL    0
flags_pack_sj_store_ram23e:     STB     A, off(0023eh)
                LB      A, #05ah
                JBS     off(00222h).1, flags_pack_sj_cmp_acc_2
                LB      A, #060h
flags_pack_sj_cmp_acc_2:     CMPB    A, off(00236h)
                MB      off(00222h).1, C
                LB      A, 0b9h
                MOVB    r0, #09ah
                MOVB    r1, #024h
                JBS     off(00222h).2, flags_pack_sj_cmp_acc_3
                MOVB    r0, #097h
                MOVB    r1, #026h
flags_pack_sj_cmp_acc_3:     CMPB    A, r0
                JGE     flags_pack_sj_store_carry_ram222_bit2
                CMPB    r1, A
flags_pack_sj_store_carry_ram222_bit2:     MB      off(00222h).2, C
                CLRB    A
                JBR     off(00216h).3, flags_pack_sj_store_ram23c
                JBS     off(00211h).5, flags_pack_sj_store_ram23c
                JBS     off(00218h).5, flags_pack_sj_store_ram23c
                JBS     off(0021dh).4, flags_pack_sj_store_ram23c
                JBR     off(00211h).4, flags_pack_sj_store_ram23c
                CMPB    0c1h, #02eh
                JGE     flags_pack_sj_store_ram23c
                JBS     off(0021ah).3, flags_pack_sj_store_ram23c
                JBR     off(00222h).1, flags_pack_sj_store_ram23c
                JBR     off(00222h).2, flags_pack_sj_store_ram23c
                LB      A, 0b9h
                MOV     X1, #flags_pack_sj_tbl_2
                VCAL    0
flags_pack_sj_store_ram23c:     STB     A, off(0023ch)
                LB      A, #0ffh
                JBS     off(00222h).3, callhelper_table_interp_lookup
                LB      A, #0feh
callhelper_table_interp_lookup:     CMPB    0a6h, A
                MB      off(00222h).3, C
                CLRB    A
                JLT     callhelper_table_interp_lookup_store_ram23d
                CMPB    0c1h, #001h
                JGE     callhelper_table_interp_lookup_store_ram23d
                JBS     off(0021dh).5, callhelper_table_interp_lookup_store_ram23d
                LB      A, off(00236h)
                MOV     X1, #callhelper_table_interp_lookup_tbl_2
                VCAL    0
callhelper_table_interp_lookup_store_ram23d:     STB     A, off(0023dh)
                J       callhelper_table_interp_lookup_load_x1
                DW  00000h
callhelper_table_interp_lookup_if_ne_goto_tipin_gate_fai:     JNE     tipin_gate_fail
                JBS     off(00214h).0, tipin_gate_fail
                JBS     off(0021dh).4, tipin_gate_fail
                JBS     off(00216h).3, tipin_gate_fail
                CMPB    0c1h, #034h
                JGE     tipin_gate_fail
                LB      A, 0b4h
                CMPB    A, #005h
                JLT     tipin_gate_fail
                CMPB    A, #078h
                JGE     tipin_gate_fail
                LB      A, off(00236h)
                CMPB    A, #040h
                JLT     tipin_gate_fail
                CMPB    A, #0a0h
                JLT     callhelper_table_interp_lookup_if_ram220_bit0_set
tipin_gate_fail:     SJ      tipin_gate_fail_goto_5b0f
callhelper_table_interp_lookup_if_ram220_bit0_set:     JBS     off(00220h).0, tipin_gate_pass
                NOP
                NOP
                NOP
                NOP
                NOP
                JBR     off(00231h).6, tipin_gate2
                LB      A, off(00237h)
                JNE     tipin_decay_check
                SJ      tipin_gate_fail_goto_5b0f
                DB  000h
tipin_gate2:     JBR     off(0021bh).1, tipin_decay_zero
                CMPB    0bdh, #010h
                JLT     tipin_decay_zero
tipin_gate_pass:     SB      off(00220h).0
                JBS     off(0021bh).6, tipin_gate_pass_goto_5ad9
                CMP     0aeh, #0ffffh
                JGE     tipin_decay_zero
tipin_gate_pass_goto_5ad9:     J       tipin_gate_pass_load_ram24f
tipin_gate_pass_load_ram236:     LB      A, off(00236h)
                VCAL    0
                MOVB    r0, off(00250h)
                MULB
                L       A, ACC
                SLL     A
                JGE     tipin_enrich_clamp
                L       A, #0ffffh
tipin_enrich_clamp:     LB      A, ACCH
                RB      off(00220h).0
                NOP
                NOP
                NOP
                NOP
tipin_decay_check:     CMPB    off(0024eh), #000h
                JEQ     tipin_decay_check_goto_5aea
                DECB    off(0024eh)
                MOVB    r0, #001h
                SJ      tipin_decay_sub
tipin_decay_check_goto_5aea:     J       tipin_decay_check_if_ram21b_bit6_set
                DW  00000h
tipin_decay_common_store_carry_ram232_bit5:     MB      off(00232h).5, C
                JGE     tipin_decay_rc
                MOVB    r0, #003h
tipin_decay_sub:     SUBB    A, r0
                JLT     tipin_decay_zero
                SC
                SJ      tipin_decay_store
tipin_gate_fail_goto_5b0f:     J       tipin_gate_fail_clear_ram220_bit0
tipin_decay_zero:     CLRB    A
tipin_decay_rc:     RC
tipin_decay_store:     STB     A, off(00237h)
                J       tipin_decay_store_store_carry_ram220_bit1
gate_255_common_if_ram216_bit3_set:     JBS     off(00216h).3, vss_threshold_2ee_0
                L       A, off(00212h)
                AND     A, #001b4h
                JNE     vss_threshold_2ee_0
                JBS     off(00214h).0, vss_threshold_2ee_0
                JBS     off(0021dh).4, vss_threshold_2ee_0
                MOVB    r0, #0c0h
                MOVB    r1, #08ah
                MOVB    r2, #09ch
                MOVB    r3, #048h
                JBS     off(00221h).6, gate_255_common_load_ram236
                MOVB    r0, #0bah
                MOVB    r1, #090h
                MOVB    r2, #092h
                MOVB    r3, #051h
gate_255_common_load_ram236:     LB      A, off(00236h)
                CMPB    A, r0
                JGE     vss_threshold_2ee_0_store_carry_ram221_bit6
                CMPB    A, r1
                JLT     vss_threshold_2ee_0
                LB      A, off(00235h)
                CMPB    A, r2
                JGE     vss_threshold_2ee_0_store_carry_ram221_bit6
                CMPB    A, r3
                JLT     vss_threshold_2ee_0
                LB      A, off(00237h)
                JNE     vss_threshold_2ee_0
                CMPB    0c1h, #001h
                JGE     vss_threshold_2ee_0_store_carry_ram221_bit6
                LCB     A, gate_255_common_tbl
                JNE     vss_threshold_2ee_0_store_carry_ram221_bit6
                JBS     off(0021ah).3, vss_threshold_2ee_0_store_carry_ram221_bit6
vss_threshold_2ee_0:     RC
vss_threshold_2ee_0_store_carry_ram221_bit6:     MB      off(00221h).6, C
                LB      A, 0aah
                MOV     X1, #tbl_iat_correct1
                VCAL    0
                STB     A, off(00245h)
                LB      A, 0aah
                MOV     X1, #tbl_iat_correct2
                VCAL    0
                STB     A, off(0024ah)
                STB     A, r0
                LB      A, off(0024bh)
                MULB
                L       A, ACC
                ST      A, er1
                CAL     dwell_scale_helper
                ST      A, off(0024ch)
                LB      A, #050h
                JBS     off(00221h).5, vss_threshold_2ee_0_cmp_acc
                LB      A, #051h
vss_threshold_2ee_0_cmp_acc:     CMPB    A, off(00236h)
                MB      off(00221h).5, C
                L       A, er1
                JLT     dwell_scale_shift
                SRL     A
dwell_scale_shift:     SRL     A
                CAL     dwell_scale_helper
                ST      A, off(0024dh)
                MOV     DP, #dwell_scale_shift_tbl_3
                MOV     er0, (001dch-00180h)[USP]
                LB      A, (001d9h-00180h)[USP]
                JBS     off(0021fh).1, dwell_scale_shift_goto_58c1
                MOV     DP, #dwell_scale_shift_tbl
                MOV     er0, (001dah-00180h)[USP]
                LB      A, (001d8h-00180h)[USP]
dwell_scale_shift_goto_58c1:     J       dwell_scale_shift_if_ram21d_bit4_clr
dwell_scale_shift_store_ram249:     STB     A, off(00249h)
                CLR     A
                ST      A, er3
                JBS     off(00212h).5, ign_sum_stage4
                JBR     off(00220h).1, ign_sum_stage1
                J       dwell_scale_shift_load_ram0b9
ign_sum_stage1:     LB      A, off(00238h)
                ADD     er3, A
                LB      A, off(00239h)
                ADD     er3, A
                LB      A, off(0023ah)
                ADD     er3, A
                LB      A, off(0023bh)
                ADD     er3, A
                LB      A, off(0023ch)
                ADD     er3, A
                LB      A, off(0023dh)
                ADD     er3, A
                J       ign_sum_stage1_load_ram2fa
ign_sum_negate:     CLR     A
                LB      A, off(0023eh)
                ADD     er3, A
                LB      A, off(0023fh)
                EXTND
                ADD     er3, A
                LB      A, off(00240h)
                EXTND
                ADD     er3, A
                LB      A, off(00241h)
                EXTND
                ADD     er3, A
ign_sum_stage4:     LB      A, off(00242h)
                EXTND
                ADD     er3, A
                CLR     A
                LB      A, off(00243h)
                SUB     er3, A
                CLR     A
                LB      A, off(00244h)
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
                JBR     off(00221h).6, ign_sum_result_store_r5
                LB      A, #0ffh
                MULB
                CLRB    A
                L       A, ACC
                SWAP
                ADD     A, er3
                JBR     off(00207h).7, ign_sum_result_cmp_acc
                JLT     ign_sum_result_load_acc
                CLRB    A
                SJ      ign_sum_result_load_acc
ign_sum_result_cmp_acc:     CMP     A, #000ffh
                JLT     ign_sum_result_load_acc
                LB      A, #0ffh
ign_sum_result_load_acc:     LB      A, ACC
ign_sum_result_store_r5:     STB     A, r5
                LB      A, #040h
                SC
                JBS     off(00212h).5, ign_p40_flag_store
                CMPB    0c1h, #0d0h
                JLT     ign_p40_flag_store
                JBS     off(00221h).7, ign_result_clamp249
                MB      C, P4.0
                JLT     ign_p40_store
                LB      A, #000h
                MB      C, off(0021eh).0
                JLT     ign_p40_store
                JBR     off(00218h).0, ign_p40_toggle
                LB      A, off(00248h)
                ADDB    A, #004h
                JGE     ign_p40_clamp
                LB      A, #0ffh
ign_p40_clamp:     CMPB    A, r4
                JGE     ign_p40_toggle
                STB     A, r4
                STB     A, r5
ign_p40_store:     STB     A, off(00248h)
ign_p40_toggle:     XORB    PSWH, #080h
ign_p40_flag_store:     MB      off(00221h).7, C
ign_result_clamp249:     MOVB    r3, off(00249h)
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
                MOV     DP, #0035ch
                JBS     off(0021eh).0, ign_result_zero
                JBR     off(00217h).1, ign_result_add_247
ign_result_zero:     CLRB    A
                STB     A, [DP]
                STB     A, off(00246h)
                STB     A, off(00247h)
                SJ      gearcorrect_store_result_load_r2
ign_result_add_247:     STB     A, [DP]
                ADDB    A, off(00245h)
                JGE     ignmap_disable_check
                LB      A, #0ffh
ignmap_disable_check:     STB     A, off(00246h)
                LB      A, r5
                CMPB    A, r3
                JGE     gearcorrect_store_result
                LB      A, r3
gearcorrect_store_result:     ADDB    A, off(00245h)
                JGE     gearcorrect_store_result_store_ram247
                LB      A, #0ffh
gearcorrect_store_result_store_ram247:     STB     A, off(00247h)
gearcorrect_store_result_load_r2:     MOVB    r2, off(00246h)
                MOVB    r4, off(0024ch)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #00355h
                AND     IE, #002a0h
                RB      PSWH.0
                MB      0a0h.2, C
                STB     A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MOVB    r2, off(00247h)
                MOVB    r4, off(0024ch)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #00359h
                AND     IE, #002a0h
                RB      PSWH.0
                MB      0a0h.3, C
                ST      A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MOVB    r2, off(00246h)
                MOVB    r4, off(0024dh)
                CAL     ign_angle_to_timer_convert
                MOV     DP, #0035dh
                AND     IE, #002a0h
                RB      PSWH.0
                MB      0a0h.4, C
                ST      A, [DP]
                INC     DP
                L       A, er0
                ST      A, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MOV     LRB, #00020h
                MOV     USP, #00280h
                CAL     refresh_engine_flags_snapshot
                SC
                JBR     off(00116h).6, igntiming_enable_pin_drive
                JBR     off(00119h).3, igntiming_enable_pin_drive
                MB      C, 0a0h.5
                XORB    PSWH, #080h
igntiming_enable_pin_drive:     MB      P1.2, C
                AND     IE, #002a0h
                RB      PSWH.0
                LB      A, P1
                MOV     DP, #02f00h
                STB     A, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                L       A, #01d4ch
                JBS     off(00121h).1, vtec_rawperiod_threshold_check
                L       A, #00ea6h
vtec_rawperiod_threshold_check:     CMP     0ach, A
                MB      off(00121h).1, C
                JBR     off(00116h).5, vtec_state_reset_low_rpm
                LB      A, ADCR5H
                STB     A, 0bfh
                LB      A, #04ah
                JBS     off(0011eh).2, vtec_rawperiod_threshold_check_cmp_acc
                LB      A, #055h
vtec_rawperiod_threshold_check_cmp_acc:     CMPB    A, off(0012ch)
                MB      off(0011eh).2, C
                LB      A, #032h
                JBS     off(00117h).5, vtec_state_reset_low_rpm
                JBR     off(0011ah).6, vtec_state_reset_low_rpm
                JBS     off(0011ah).7, vtec_state_reset_low_rpm
                JBR     off(0011eh).2, vtec_state_reset_low_rpm
                JBS     off(00118h).2, vtec_oilpressure_gate_check
vtec_state_reset_low_rpm:     MOVB    off(00195h), #032h
vtec_state_clear:     CLRB    r1
                J       vtec_state_finalize
vtec_oilpressure_gate_check:     JBS     off(00115h).1, vtec_oilpressure_pin_check
                CMPB    0bfh, #0fch
                JGT     vtec_oilpressure_pin_check
                CMPB    0bfh, #004h
                JGE     vtec_oilpressure_gate_check_store_ram195
vtec_oilpressure_pin_check:     MB      C, P4.6
                JGE     vtec_state_dispatch
                STB     A, off(00195h)
vtec_state_reset_no_pressure:     MOVB    off(00196h), #01eh
                MOVB    r1, #004h
                SJ      vtec_rpm_valid_check
vtec_state_dispatch:     LB      A, off(00195h)
                JNE     vtec_state_reset_no_pressure
                LB      A, off(00196h)
                JEQ     vtec_state_clear
                MOVB    r1, #002h
                SJ      vtec_rpm_valid_check
vtec_oilpressure_gate_check_store_ram195:     STB     A, off(00195h)
                MOVB    r1, off(001cah)
                LB      A, off(001c8h)
                JNE     vtec_debounce_step_calc
                LB      A, #0a0h
                JBS     off(00128h).6, vtec_oilpressure_gate_check_cmp_acc
                LB      A, #0b0h
vtec_oilpressure_gate_check_cmp_acc:     CMPB    A, off(0012dh)
                MB      off(00128h).6, C
                CLRB    r0
                JGE     vtec_oilpressure_gate_check_load_imm
                INCB    r0
                INCB    r0
vtec_oilpressure_gate_check_load_imm:     LB      A, #0c1h
                JBS     off(00128h).7, vtec_oilpressure_gate_check_cmp_acc_2
                LB      A, #0d4h
vtec_oilpressure_gate_check_cmp_acc_2:     CMPB    A, off(0012ch)
                MB      off(00128h).7, C
                JGE     to_vtec_debounce_store
                INCB    r0
                NOP
                NOP
to_vtec_debounce_store:     CLRB    r1
                CMPB    0bfh, #030h
                JLE     to_vtec_debounce_store_load_imm
                LB      A, r0
                EXTND
                ADD     A, #to_vtec_debounce_store_tbl
                MOV     DP, A
                INCB    r1
                LB      A, 0bfh
                J       to_vtec_debounce_store_clear_ram0a0_bit1
                DW  00000h
to_vtec_debounce_store_incb_r1:     INCB    r1
                JBS     off(00112h).3, to_vtec_debounce_store_load_imm
                JBS     off(00112h).7, to_vtec_debounce_store_load_imm
to_vtec_debounce_store_cmp_acc:     CMPCB   A, [DP]
                J       to_vtec_debounce_store_if_le_goto_583a
to_vtec_debounce_store_incb_r1_2:     INCB    r1
                CMPB    r1, #007h
                JLT     to_vtec_debounce_store_cmp_acc
to_vtec_debounce_store_load_imm:     LB      A, #003h
                SJ      vtec_debounce_store
vtec_debounce_step_calc:     SUBB    A, #001h
                JBR     off(0011ch).0, vtec_debounce_store
                SUBB    A, #001h
                JLT     vtec_debounce_zero
                JBR     off(0011ch).1, vtec_debounce_store
                SUBB    A, #002h
                JGE     vtec_debounce_store
vtec_debounce_zero:     CLRB    A
vtec_debounce_store:     STB     A, off(001c8h)
vtec_rpm_valid_check:     CMPB    off(0012dh), #053h
                JLT     vtec_state_hold_check
                LB      A, r1
                CMPB    A, #001h
                JLE     vtec_state_active_check
                MOVB    off(001a6h), #00ah
                SJ      vtec_state_store
vtec_state_hold_check:     JBS     off(0011dh).4, vtec_state_confirm
                J       vtec_state_clear
vtec_state_active_check:     JBR     off(0011dh).4, vtec_state_finalize
vtec_state_confirm:     LB      A, off(001a6h)
                JEQ     vtec_state_finalize
                MOVB    r1, #002h
                CLRB    off(001c8h)
vtec_state_store:     LB      A, r1
                STB     A, off(001cah)
                SB      off(0011dh).4
                JNE     vtec_retard_timer_check
                MOVB    off(001cch), #00ch
                CLRB    off(001cbh)
vtec_retard_timer_check:     CMPB    off(001cch), #008h
                JGT     vtec_retard_lookup_done
                CLR     A
                LB      A, r1
                SUBB    A, #002h
                MOV     DP, #tbl_vtec_transition_retard
                ADD     DP, A
                LCB     A, [DP]
                STB     A, off(001cbh)
vtec_retard_lookup_done:     SJ      vtec_state_store2_load_imm
vtec_state_finalize:     RB      off(0011dh).4
                CLRB    A
                STB     A, off(001c8h)
                CMPB    r1, #001h
                JNE     vtec_state_store2
                LB      A, r1
vtec_state_store2:     STB     A, off(001cah)
vtec_state_store2_load_imm:     LB      A, #005h
                MOVB    r0, #014h
                JBS     off(00128h).0, vtec_state_store2_if_ram116_bit3_set
                LB      A, #00ah
                MOVB    r0, #019h
vtec_state_store2_if_ram116_bit3_set:     JBS     off(00116h).3, vtec_state_store2_cmp_acc
                LB      A, r0
vtec_state_store2_cmp_acc:     CMPB    A, 0b4h
                MB      off(00128h).0, C
                MOV     DP, #vtec_state_store2_tbl
                MOV     X1, #vtec_state_store2_tbl_3
                JBS     off(00116h).3, vtec_state_store2_rom_load_dp_ind
                MOV     DP, #vtec_state_store2_tbl_2
                MOV     X1, #vtec_state_store2_tbl_4
vtec_state_store2_rom_load_dp_ind:     LC      A, [DP]
                INC     DP
                INC     DP
                JBS     off(00128h).1, vtec_rpm_vs_settings_check
                LB      A, ACCH
vtec_rpm_vs_settings_check:     CMPB    A, off(0012dh)
                MB      off(00128h).1, C
                LC      A, [DP]
                JBS     off(00128h).2, vtec_rpm_vs_settings_check_cmp_acc
                LB      A, ACCH
vtec_rpm_vs_settings_check_cmp_acc:     CMPB    A, off(0012dh)
                MB      off(00128h).2, C
                LB      A, off(0012dh)
                VCAL    0
                STB     A, off(00158h)
                JBR     off(00116h).4, vtec_disengage_output
                L       A, off(00112h)
                AND     A, #0c0bch
                JNE     vtec_disengage_output
                LB      A, off(00114h)
                ANDB    A, #031h
                JEQ     vtec_engage_conditions_start
vtec_disengage_output:     RB      P1.1
                SJ      vtec_highcam_output
vtec_engage_conditions_start:     SB      P1.1
                CMPB    0e9h, #032h
                JLT     vtec_highcam_output
                CMPB    0c1h, #044h
                JGE     vtec_highcam_output
                LCB     A, gate_255_common_tbl
                JNE     vtec_engage_conditions_start_if_ram116_bit3_clr
                JBR     off(00128h).0, vtec_highcam_output
vtec_engage_conditions_start_if_ram116_bit3_clr:     JBR     off(00116h).3, vtec_engage_conditions_start_if_ram128_bit1_set
                JBS     off(00111h).5, vtec_engage_conditions_start_if_ram11f_bit1_set
vtec_engage_conditions_start_if_ram128_bit1_set:     JBS     off(00128h).1, vtec_engage_conditions_start_load_ram158
vtec_engage_conditions_start_if_ram11f_bit1_set:     JBS     off(0011fh).1, vtec_engage_conditions_start_clear_ram192
vtec_highcam_output:     RB      P1.0
                RB      off(0011fh).2
                SJ      vtec_highcam_output_load_ram1a4
vtec_engage_conditions_start_load_ram158:     LB      A, off(00158h)
                SUBB    A, off(00159h)
                JLT     vtec_engage_conditions_start_clear_acc
                JBR     off(0011fh).2, vtec_engage_conditions_start_cmp_acc
                SUBB    A, #008h
                JGE     vtec_engage_conditions_start_cmp_acc
vtec_engage_conditions_start_clear_acc:     CLRB    A
vtec_engage_conditions_start_cmp_acc:     CMPB    A, off(0012ch)
                JLT     vtec_engage_conditions_start_load_ram192
                JBS     off(00128h).2, vtec_engage_conditions_start_load_ram192
                LB      A, off(00192h)
                JNE     vtec_engage_conditions_start_set_p1_bit0
vtec_engage_conditions_start_clear_ram192:     CLRB    off(00192h)
                RB      P1.0
                RB      off(0011fh).2
                JBS     off(00111h).1, vtec_engage_conditions_start_load_ram1a4
vtec_engage_conditions_start_load_ram1a5:     LB      A, off(001a5h)
                JNE     vtec_engage_conditions_start_set_ram11f_bit1
vtec_highcam_output_load_ram1a4:     MOVB    off(001a4h), #00ah
vtec_highcam_output_clear_ram11f_bit1:     RB      off(0011fh).1
                SJ      fuelmap_base_lookup
vtec_engage_conditions_start_load_ram192:     MOVB    off(00192h), #014h
vtec_engage_conditions_start_set_p1_bit0:     SB      P1.0
                SB      off(0011fh).2
                JBR     off(00111h).1, vtec_engage_conditions_start_load_ram1a5
vtec_engage_conditions_start_load_ram1a4:     LB      A, off(001a4h)
                JNE     vtec_highcam_output_clear_ram11f_bit1
                MOVB    off(001a5h), #00ah
vtec_engage_conditions_start_set_ram11f_bit1:     SB      off(0011fh).1
fuelmap_base_lookup:     MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, off(001d3h)
                MOV     X2, off(001d6h)
                MOVB    r3, off(001d9h)
                MOV     er3, off(001dch)
                MOV     X1, #fuelmap_base_lookup_tbl_2
                JBS     off(0011fh).1, fuel_base_lookup_done
                JBR     off(00114h).5, fuelmap_base_lookup_load_r3
                JBS     off(00118h).7, fuel_base_lookup_done
fuelmap_base_lookup_load_r3:     MOVB    r3, off(001d8h)
                MOV     er3, off(001dah)
                MOV     X1, #fuelmap_base_lookup_tbl
                JBR     off(00119h).6, fuel_base_lookup_done
                LB      A, #000h
                CMPB    A, r3
                JGT     fuel_base_lookup_done
                ADDB    A, #00ah
                CMPB    A, r3
                JLE     fuel_base_lookup_done
                SUBB    r3, #000h
                MOVB    r1, #00bh
                MOV     X1, #fuelmap_base_lookup_tbl_3
fuel_base_lookup_done:     SB      PSWL.5
                CAL     table2d_lookup_interp
                CAL     map_result_postscale
                STB     A, off(00138h)
                LB      A, off(00170h)
                JBS     off(00117h).5, accel_iac_calc
                JBS     off(0011fh).0, fuel_timer_scale
                SJ      accel_iac_clamp_min
accel_iac_calc:     LB      A, off(0015bh)
                STB     A, r0
                LB      A, #09ah
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     accel_iac_calc_cmp_acc
                LB      A, #0ffh
accel_iac_calc_cmp_acc:     CMPB    A, #040h
                JGE     accel_iac_store
accel_iac_clamp_min:     LB      A, #040h
accel_iac_store:     STB     A, off(00170h)
fuel_timer_scale:     MOVB    r0, off(00171h)
                MULB
                MOVB    r1, off(0016fh)
                CLRB    r0
                MUL
                MOV     er0, er1
                L       A, off(0014ch)
                MUL
                MOV     off(001e4h), er1
                CMPB    off(0012dh), #0b4h
                RB      PSWH.7
                MOVB    r0, 0beh
                MB      C, off(0011bh).2
                JEQ     accelenrich_rpm_mode_check
                MOVB    r0, 0bdh
                MB      C, off(0011bh).1
accelenrich_rpm_mode_check:     JLT     accelenrich_flags_clear
                LB      A, #00ah
                CMPB    A, r0
                MB      off(00124h).1, C
                LB      A, #00ah
                CMPB    A, r0
                MB      off(00124h).2, C
                RC
                SJ      accelenrich_mode_flag_store
accelenrich_flags_clear:     RB      off(00124h).1
                RB      off(00124h).2
                LB      A, #004h
                CMPB    A, r0
accelenrich_mode_flag_store:     MB      off(00124h).0, C
                JBS     off(0011dh).4, accelenrich_jump_cranking_path
                JBS     off(00111h).0, accelenrich_jump_cranking_path
                JBR     off(00124h).0, accelenrich_clear_pulse_check
                JBR     off(0011bh).3, accelenrich_jump_tipin_check
                LB      A, off(00172h)
                JBS     off(00124h).3, accelenrich_table_lookup
                CMPB    0a5h, #0dah
                JGE     accelenrich_jump_cranking_path
                CMPB    0bbh, #0b3h
                JLT     accelenrich_base_calc
accelenrich_jump_cranking_path:     J       accelenrich_clear_and_cranking_prep
accelenrich_jump_tipin_check:     J       accelenrich_jump_tipin_check_load_ram13a
accelenrich_base_calc:     CLRB    A
                JBR     off(00118h).1, accelenrich_base_adjust
                CMPB    0b4h, #005h
                JLT     accelenrich_result_store
accelenrich_base_adjust:     ADDB    A, #02ah
                JBR     off(00126h).4, accelenrich_rpm_tier1
                ADDB    A, #006h
accelenrich_rpm_tier1:     CMPB    off(0012dh), #0b4h
                JGE     accelenrich_result_store
                SUBB    A, #00ch
                CMPB    off(0012dh), #08dh
                JGE     accelenrich_result_store
                SUBB    A, #00ch
                CMPB    off(0012dh), #066h
                JGE     accelenrich_result_store
                SUBB    A, #00ch
accelenrich_result_store:     STB     A, off(00172h)
accelenrich_table_lookup:     CLRB    ACCH
                MOV     X1, A
                ADD     X1, #tbl_tipin_enrich_rpm
                LB      A, r0
                VCAL    3
                STB     A, off(001e2h)
                CAL     scale_ram1e4_mul_shr2
                J       cranking_flag_check
accelenrich_clear_pulse_check:     JBR     off(00124h).2, tipin_rpm_gate
                CLR     off(0013ah)
tipin_rpm_gate:     CMPB    off(0012dh), #060h
                JLT     accelenrich_jump_tipin_check_load_ram13a
                JBR     off(00124h).1, tipin_gate_common
                JBR     off(0011bh).3, tipin_gate_common
                MOV     X1, #tbl_tipin_low
                CMPB    (0024fh-00280h)[USP], #003h
                JGE     tipin_table_gear_adjust
                ADD     X1, #00006h
tipin_table_gear_adjust:     CMPB    off(0012dh), #08dh
                JLT     tipin_table_lookup
                ADD     X1, #0000ch
tipin_table_lookup:     LB      A, r0
                VCAL    3
                LB      A, ACC
                SJ      accelenrich_clear_0x165
tipin_gate_common:     LB      A, off(00155h)
                JEQ     accelenrich_jump_tipin_check_load_ram13a
                ADDB    A, #003h
                JGE     accelenrich_clear_0x165
accelenrich_jump_tipin_check_load_ram13a:     L       A, off(0013ah)
                JEQ     accelenrich_clear_and_cranking_prep
                ST      A, er3
                LB      A, off(00172h)
                EXTND
                MOV     DP, #tbl_tipin_normal_enrich
                ADD     DP, A
                LC      A, [DP]
                ST      A, er2
                CMP     A, er3
                L       A, #00096h
                JLT     tipin_table_result_alt
                LC      A, 00002h[DP]
                ST      A, er2
                CMP     A, er3
                JLT     tipin_table_row2
                MOV     er0, off(001e8h)
                LC      A, 00004h[DP]
                CAL     mul_zero_if_r3_zero
                XCHG    A, er3
                SUB     A, er3
                SJ      tipin_table_final
tipin_table_row2:     MOV     er0, off(001e6h)
                L       A, #00040h
                CAL     mul_zero_if_r3_zero
tipin_table_result_alt:     XCHG    A, er3
                SUB     A, er3
                JLT     tipin_table_result_common
                CMP     A, er2
                JGE     tipin_table_final
tipin_table_result_common:     L       A, er2
                RC
tipin_table_final:     JGE     cranking_flag_check
accelenrich_clear_and_cranking_prep:     CLRB    A
accelenrich_clear_0x165:     STB     A, off(00155h)
                RB      off(00124h).3
                CLR     A
                ST      A, off(001e2h)
                SJ      SetCranking
cranking_flag_check:     CLRB    off(00155h)
                SB      off(00124h).3
SetCranking:     STB     A, off(0013ah)
                JBS     off(00117h).5, Cranking
                J       notcranking_entry
Cranking:     MOV     X1, #CrankFuel
                LB      A, 0c1h
                VCAL    1
                STB     A, off(00138h)
                MOV     X1, #CrankFuelComp
                LB      A, 0adh
                VCAL    2
                STB     A, off(00153h)
                MOV     X1, #CrankFuelMap
                LB      A, 0a4h
                VCAL    2
                STB     A, off(00152h)
                MOVB    r0, off(00153h)
                MULB
                MOV     er0, off(00138h)
                MUL
                L       A, ACC
                SLL     A
                ROL     er1
                JLT     crankfuel_clamp_max
                SLL     A
                L       A, er1
                ROL     A
                JLT     crankfuel_clamp_max
                ADD     A, off(0013ah)
                JGE     crankfuel_halve_check
crankfuel_clamp_max:     L       A, #0ffffh
crankfuel_halve_check:     MB      C, 09fh.0
                JGE     crankfuel_halve_check_add_acc
                SRL     A
                SRL     A
crankfuel_halve_check_add_acc:     ADD     A, off(0013ch)
                JGE     crankfuel_halve_check_goto_diag_report_finalize
                L       A, #0ffffh
crankfuel_halve_check_goto_diag_report_finalize:     J       diag_report_finalize
diag_report_finalize_store_dp_ind:     ST      A, [DP]
                CLR     X1
                CAL     scale_mul5_div4
                AND     IE, #002a0h
                RB      PSWH.0
                ST      A, 003aeh[X1]
                ST      A, 003b0h[X1]
                ST      A, 003b2h[X1]
                ST      A, 003b4h[X1]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MB      C, 09fh.0
                JLT     crankfuel_output_apply_start
                CMPB    off(00135h), #004h
                JNE     postfuel_calc_start
                CMPB    0c1h, #0e8h
                JGE     postfuel_calc_start
crankfuel_output_apply_start:     L       A, 003aeh[X1]
                ST      A, off(001c6h)
                ST      A, off(001c4h)
                ST      A, off(001c2h)
                ST      A, off(001c0h)
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                L       A, TM0
                SUB     A, TMR0
                MB      C, IRQ.5
                JLT     crankfuel_timer_sync_done
                ADD     A, #00005h
                JLT     crankfuel_timer_sync_done
                ADD     TMR0, A
crankfuel_timer_sync_done:     SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MOV     DP, #00010h
crankfuel_timer_wait_loop:     L       A, off(001c6h)
                JRNZ    DP, crankfuel_timer_wait_loop
                CAL     injector_timer_schedule
                JBS     off(00117h).3, cylinder_index_advance
                JBS     off(00113h).7, cylinder_index_advance
                J       crankfuel_timer_wait_loop_sll_er0
crankfuel_timer_wait_loop_if_eq_goto_cylinder_index_adva:     JEQ     cylinder_index_advance
                RB      TRNSIT.2
                JNE     cylinder_index_advance
dtc16_injector_latch_2: SB      09ch.6
cylinder_index_advance:     LB      A, off(00134h)
                ADDB    A, #001h
                ANDB    A, #003h
                STB     A, off(00134h)
postfuel_calc_start:     SB      off(0011fh).0
                LB      A, 0c1h
                CMPB    A, #0cfh
                MB      PSWL.5, C
                MOV     X1, #PostFuel
                VCAL    1
                STB     A, r0
                STB     A, r1
                JBS     off(00112h).5, postfuel_scale_apply
                JBS     off(00113h).1, postfuel_scale_apply
                CMPB    0c1h, #0a2h
                JLT     postfuel_scale_apply
                MOV     DP, #00352h
                LB      A, [DP]
                SUBB    A, 0c1h
                JGE     postfuel_ect_rate_check
                VCAL    7
postfuel_ect_rate_check:     CMPB    A, #010h
                JGE     postfuel_scale_apply
                LB      A, 0c0h
                CMPB    A, #0bah
                JLT     postfuel_scale_apply
                SUBB    A, 0c1h
                JLT     postfuel_scale_apply
                CMPB    A, #006h
                JLT     postfuel_scale_apply
                L       A, #0e666h
                MUL
postfuel_scale_apply:     L       A, er1
                ST      A, off(00160h)
                CLRB    off(0015fh)
                MOV     er2, #02000h
                SUB     A, er2
                ST      A, er3
                CLRB    r0
                MOVB    r1, #073h
                MB      C, PSWL.5
                JLT     postfuel_hyst_upper_calc
                MOVB    r1, #05ah
postfuel_hyst_upper_calc:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(00162h)
                L       A, er3
                MOVB    r1, #04dh
                MB      C, PSWL.5
                JLT     postfuel_hyst_lower_calc
                MOVB    r1, #033h
postfuel_hyst_lower_calc:     MUL
                L       A, er1
                ADD     A, er2
                ST      A, off(00164h)
                CMPB    0c0h, #030h
                MB      off(00123h).3, C
                J       postfuel_hyst_lower_calc_call_clamp_diff_15b_1ec
notcranking_entry:     RB      09fh.0
                JEQ     postfuel_decay_table_select
                CLRB    off(00135h)
postfuel_decay_table_select:     JBR     off(0011fh).0, postfuel_decay_zero_reset_load_imm
                MOV     DP, #PostFuelDecay
                JBR     off(00116h).3, postfuel_decay_table_index_adjust
                MOV     DP, #PostFuelDecay2
                JBS     off(00111h).5, postfuel_decay_table_index_adjust
                MOV     DP, #PostFuelDecay3
postfuel_decay_table_index_adjust:     CMPB    off(00161h), #026h
                JLE     postfuel_decay_table_index_adjust2
                CMP     off(00160h), off(00162h)
                JGT     postfuel_decay_apply
postfuel_decay_table_index_adjust2:     INC     DP
                INC     DP
                CMP     off(00160h), off(00164h)
                JGT     postfuel_decay_apply
                INC     DP
                INC     DP
                CMPB    0c0h, #044h
                JGE     postfuel_decay_apply
                INC     DP
                INC     DP
postfuel_decay_apply:     LC      A, [DP]
                SUBB    off(0015fh), A
                CLRB    A
                L       A, ACC
                SWAP
                ST      A, er0
                L       A, off(00160h)
                SBC     A, er0
                CMP     A, #02000h
                JLE     postfuel_decay_zero_reset
                ST      A, off(00160h)
                CMPB    0c1h, #02eh
                JLT     postfuel_final_store
                JBR     off(00111h).2, postfuel_final_store
                CLRB    r0
                MOVB    r1, #08dh
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     postfuel_final_store
                L       A, #0ffffh
                SJ      postfuel_final_store
postfuel_decay_zero_reset:     RB      off(0011fh).0
postfuel_decay_zero_reset_load_imm:     L       A, #02000h
                ST      A, off(00160h)
postfuel_final_store:     ST      A, off(0014ah)
                LB      A, #0bah
                JBS     off(00127h).0, postfuel_final_store_cmp_acc
                LB      A, #0c0h
postfuel_final_store_cmp_acc:     CMPB    A, off(0012dh)
                MB      off(00127h).0, C
                LB      A, #0deh
                JBS     off(00127h).5, to_flag_12f_5_select_ff
                LB      A, #0e0h
to_flag_12f_5_select_ff:     CMPB    A, off(0012dh)
                MB      off(00127h).5, C
                LB      A, #017h
                JBS     off(00127h).2, to_flag_12f_5_select_ff_cmp_ram0c1
                LB      A, #014h
to_flag_12f_5_select_ff_cmp_ram0c1:     CMPB    0c1h, A
                MB      off(00127h).2, C
                LB      A, #014h
                JBS     off(00127h).1, to_flag_12f_5_select_ff_cmp_ram0c1_2
                LB      A, #011h
to_flag_12f_5_select_ff_cmp_ram0c1_2:     CMPB    0c1h, A
                MB      off(00127h).1, C
                LB      A, off(0012dh)
                MOV     X1, #to_flag_12f_5_select_ff_tbl
                JBS     off(00127h).6, to_flag_12f_5_select_ff_vcal_0
                MOV     X1, #to_flag_12f_5_select_ff_tbl_2
to_flag_12f_5_select_ff_vcal_0:     VCAL    0
                CMPB    A, 0b9h
                MB      off(00127h).6, C
                LB      A, off(0012dh)
                MOV     X1, #tbl_closeloop_tps
                CMPCB   A, 0000ch[X1]
                MB      off(00127h).3, C
                VCAL    0
                CLRB    r0
                RB      PSWL.4
                JBS     off(00127h).3, ve_adjust_sub
                MOVB    r0, #020h
                JBS     off(00127h).1, ve_adjust_sub
                JBR     off(00116h).1, to_flag_12f_5_select_ff_clear_r0
                JBR     off(00127h).0, to_flag_12f_5_select_ff_clear_r0
                MOVB    r0, #040h
                JBS     off(00118h).6, ve_adjust_add
                JBS     off(00127h).2, ve_adjust_add
                SB      PSWL.4
to_flag_12f_5_select_ff_clear_r0:     CLRB    r0
ve_adjust_add:     ADDB    r0, off(0016eh)
                JLT     ve_adjust_clamp_zero
ve_adjust_sub:     SUBB    A, r0
                JGE     ve_adjust2_gate
ve_adjust_clamp_zero:     CLRB    A
ve_adjust2_gate:     STB     A, r4
                RB      PSWL.4
                JEQ     ve_adjust2_gate_store_r0
                LB      A, off(0012dh)
                MOV     X1, #ve_adjust2_gate_tbl
                VCAL    0
                SUBB    A, off(0016eh)
                JGE     ve_adjust2_gate_store_r0
                CLRB    A
ve_adjust2_gate_store_r0:     STB     A, r0
                SUBB    A, #010h
                JGE     ve_adjust2_gate_cmp_acc
                CLRB    A
ve_adjust2_gate_cmp_acc:     CMPB    A, off(0012ch)
                MB      off(00128h).5, C
                LB      A, r0
                MOVB    r0, #008h
                JBR     off(00128h).4, ve_result_flag_store
                SUBB    A, r0
                JGE     ve_result_flag_store
                CLRB    A
ve_result_flag_store:     CMPB    A, off(0012ch)
                MB      off(00128h).4, C
                LB      A, r4
                JBR     off(00128h).3, ve_result_flag_store_cmp_acc
                SUBB    A, r0
                JGE     ve_result_flag_store_cmp_acc
                CLRB    A
ve_result_flag_store_cmp_acc:     CMPB    A, off(0012ch)
                MB      off(00128h).3, C
                SC
                JBR     off(00116h).1, ve_result_flag_store_store_carry_ram11e_bit3
                JBS     off(00118h).6, ve_result_flag_store_store_carry_ram11e_bit3
                JBS     off(00128h).5, ve_result_flag_store_load_ram187
                RB      off(00121h).2
                JEQ     ve_result_flag_store_clear_ram185
                MOVB    off(00186h), off(00185h)
ve_result_flag_store_clear_ram185:     CLRB    off(00185h)
                RC
                SJ      ve_result_flag_store_store_carry_ram11e_bit3
ve_result_flag_store_load_ram187:     LB      A, off(00187h)
                SB      off(00121h).2
                JNE     ve_result_flag_store_clear_ram184
                CLR     A
                LB      A, off(00184h)
                MOV     er0, A
                LB      A, off(00186h)
                MOV     er1, A
                LB      A, off(00187h)
                L       A, ACC
                ADD     A, er0
                SUB     A, er1
                LB      A, ACC
                J       ve_result_flag_store_if_ge_goto_5914
ve_result_flag_store_cmp_acch:     CMPB    ACCH, #000h
                JEQ     ve_result_flag_store_load_r4
                LB      A, #0ffh
ve_result_flag_store_load_r4:     MOVB    r4, #006h
                CMPB    A, r4
                JLT     ve_result_flag_store_store_ram187
                LB      A, r4
ve_result_flag_store_store_ram187:     STB     A, off(00187h)
ve_result_flag_store_clear_ram184:     CLRB    off(00184h)
                CMPB    off(00185h), A
                XORB    PSWH, #080h
ve_result_flag_store_store_carry_ram11e_bit3:     MB      off(0011eh).3, C
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, off(001d3h)
                MOV     X2, off(001d6h)
                MOVB    r3, off(001d9h)
                MOV     er3, off(001dch)
                MOV     X1, #ve_result_flag_store_tbl
                RB      PSWL.5
                JBS     off(0011fh).1, ve_table_result_store_call_table2d_lookup_interp
                JBR     off(00114h).5, ve_table_result_store
                JBS     off(00118h).7, ve_table_result_store_call_table2d_lookup_interp
ve_table_result_store:     MOVB    r3, off(001d8h)
                MOV     er3, off(001dah)
                MOV     X1, #ve_table_result_store_tbl
ve_table_result_store_call_table2d_lookup_interp:     CAL     table2d_lookup_interp
                LB      A, r4
                SRLB    A
                STB     A, r0
                JBS     off(0011dh).4, ve_accel_state_store_clear_ram11d_bit5
                JBS     off(00112h).6, ve_accel_gate1
                JBS     off(00127h).6, ve_accel_tps_threshold_check
ve_accel_gate1:     JBS     off(00127h).3, ve_accel_gate1_load_ram185
                JBS     off(00127h).1, ve_accel_gate1_load_ram185
                JBR     off(00127h).0, ve_accel_gate1_load_imm
                JBR     off(00116h).1, ve_accel_gate1_load_ram185
                JBS     off(00118h).6, ve_accel_gate1_load_ram185
                JBS     off(00127h).2, ve_accel_gate1_load_ram185
                JBR     off(00128h).4, ve_accel_state_store_clear_ram11d_bit5
                JBS     off(00128h).3, ve_accel_tps_threshold_check
                JBR     off(0011eh).3, ve_accel_state_store_clear_ram11d_bit5
                SJ      ve_accel_reset_flags
ve_accel_tps_threshold_check:     LB      A, r0
                JBS     off(0011eh).3, ve_accel_reset_flags
                LB      A, #080h
                CAL     sub_clamp_helper
                SJ      ve_accel_reset_flags
ve_accel_gate1_load_ram185:     MOVB    off(00185h), #006h
                JBS     off(00128h).3, ve_accel_check_tps_rate
                CLRB    A
                SJ      ve_accel_state_store
ve_accel_gate1_load_imm:     LB      A, #001h
                JBR     off(00128h).3, ve_accel_state_store
                CMPB    0b4h, #005h
                JLT     ve_accel_tps_threshold_check
                LB      A, off(0018fh)
                JEQ     ve_accel_tps_threshold_check
ve_accel_state_store:     STB     A, off(0018fh)
ve_accel_state_store_clear_ram11d_bit5:     RB      off(0011dh).5
                RB      off(00123h).6
ve_accel_common:     RB      off(00123h).4
                LB      A, #040h
                SJ      tpsaccel_result_common_store_ram152
ve_accel_check_tps_rate:     JBS     off(00119h).5, ve_accel_next_stage
ve_accel_reset_flags:     CMPB    A, off(0015bh)
                JGE     ve_accel_next_stage
                SB      off(0011dh).5
                CLRB    off(0018fh)
                SJ      ve_accel_common
ve_accel_next_stage:     MOVB    r0, off(0016dh)
                CAL     sub_clamp_helper
                STB     A, r2
                LB      A, (00243h-00280h)[USP]
                CMPB    A, #015h
                JBS     off(00123h).6, tpsaccel_hyst_check
                JLT     tpsaccel_hyst_check
                SB      off(00123h).6
                SJ      tpsaccel_table_select
tpsaccel_hyst_check:     CMPB    A, #00ch
                JGE     tpsaccel_table_select
                LB      A, r2
                RB      off(00123h).6
                SJ      tpsaccel_clamp_0xa0
tpsaccel_table_select:     LB      A, off(0012dh)
                MOV     X1, #tbl_ve_accel_1
                JBR     off(0011fh).1, tpsaccel_table_lookup
                LB      A, 0aah
                MOV     X1, #tbl_ve_accel_2
tpsaccel_table_lookup:     VCAL    0
                MOVB    r0, r2
                CAL     sub_clamp_helper
tpsaccel_clamp_0xa0:     MOVB    r0, #056h
                CMPB    A, r0
                JLT     to_flag_dispatch_130_1_130_2
                LB      A, r0
to_flag_dispatch_130_1_130_2:     CMPB    off(00188h), #000h
                JNE     tpsaccel_result_common
                MOVB    r0, #056h
                CMPB    A, r0
                JGE     tpsaccel_result_common
                LB      A, r0
tpsaccel_result_common:     SB      off(0011dh).5
                SB      off(00123h).4
                CLRB    off(0018fh)
tpsaccel_result_common_store_ram152:     STB     A, off(00152h)
                JBS     off(00127h).5, tpsaccel_ignitioncut_flag_copy
                J       tpsaccel_result_common_clear_acc
                DB  000h
tpsaccel_ignitioncut_flag_copy:     MB      C, off(0011ch).4
                MB      off(00126h).4, C
                MOV     X1, #tbl_ignmap2_hi
                JBR     off(0011ch).2, tpsaccel_ignitioncut_flag_copy_load_ram12d
                MOV     X1, #tbl_ignmap2_lo
tpsaccel_ignitioncut_flag_copy_load_ram12d:     LB      A, off(0012dh)
                VCAL    0
                SUBB    A, off(0017ch)
                J       tpsaccel_ignitioncut_flag_copy_if_ge_goto_5984
                DB  000h
tpsaccel_ignitioncut_flag_copy_store_carry_ram126_bit0:     MB      off(00126h).0, C
                LB      A, off(0017bh)
                MOVB    r0, #05ah
                JBR     off(0011ch).2, tpsaccel_threshold_pick
                LB      A, off(0017ah)
                MOVB    r0, #047h
tpsaccel_threshold_pick:     JBR     off(0011bh).0, tps_hysteresis_check
                CMPB    A, r0
                JGE     tps_hysteresis_check
                LB      A, r0
tps_hysteresis_check:     JBR     off(00117h).6, rpm_threshold_adjust
                CMPB    0c4h, #082h
                JBS     off(00126h).7, tps_hysteresis_check_goto_tps_hysteresis_store
                CMPB    0c4h, #07ah
tps_hysteresis_check_goto_tps_hysteresis_store:     J       tps_hysteresis_store
                DW  00000h
tps_hysteresis_flag2_subb_acc:     SUBB    A, #00ah
                JGE     rpm_threshold_adjust
                CLRB    A
rpm_threshold_adjust:     CMPB    0b4h, #000h
                JBR     off(00116h).3, rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold
                CMPB    0b4h, #008h
rpm_threshold_adjust_if_lt_goto_rpm_secondary_threshold:     JLT     rpm_secondary_threshold_check
                JBR     off(00126h).1, rpm_secondary_threshold_check
                JBS     off(0011ch).2, rpm_secondary_threshold_check
                ADDB    A, #030h
                JGE     rpm_secondary_threshold_check
                LB      A, #0ffh
rpm_secondary_threshold_check:     CMPB    A, off(0012dh)
                MB      off(00126h).3, C
                LB      A, #073h
                JBS     off(00126h).2, vss_threshold_226_3
                LB      A, #080h
vss_threshold_226_3:     CMPB    A, off(0012dh)
                MB      off(00126h).2, C
                RB      PSWL.4
                RB      PSWL.5
                RB      off(00123h).7
                JBS     off(00113h).5, vss_threshold_226_3_if_ram112_bit6_set
                MB      C, 099h.3
                JLT     vss_threshold_226_3_if_ram112_bit6_set
                LB      A, 0cdh
                CMPB    A, #010h
                JGE     doubleup_limiter_gate
vss_threshold_226_3_if_ram112_bit6_set:     JBS     off(00112h).6, vaccut_rpm_check
                MB      C, 098h.2
                JLT     vaccut_rpm_check
                CMPB    0b9h, #02bh
                JGE     doubleup_limiter_gate
                MOV     X1, #vss_threshold_226_3_tbl
                LB      A, 0b9h
                VCAL    2
                SJ      vaccut_rpm_check_cmp_acc
vaccut_rpm_check:     LB      A, #080h
vaccut_rpm_check_cmp_acc:     CMPB    A, off(0012dh)
                JGE     ofc_enable_check_if_ram126_bit0_set
                SJ      revlimiter_fuelcut_set
doubleup_limiter_gate:     MOV     DP, #00228h
                L       A, #00218h
                MB      C, P4.0
                JLT     doubleup_limiter_cont
                JBS     off(00113h).7, doubleup_limiter_cont
                MOV     DP, off(00182h)
                L       A, off(00180h)
doubleup_limiter_cont:     JBR     off(0011ch).5, ignition_cut_mode_check
                L       A, DP
ignition_cut_mode_check:     CMP     0ach, A
                MB      off(0011ch).5, C
                JLT     revlimiter_fuelcut_set
                JBS     off(00119h).7, fuelcuttrack_store
                JBR     off(00116h).2, fuelcut_extra_gate
                LB      A, #0c8h
                CMPB    A, off(0012dh)
                JGE     ignition_cut_mode_check_load_imm
                CMPB    0b4h, #0b9h
                JGE     ignition_cut_mode_check_load_ram190
                LB      A, off(00191h)
                JNE     revlimiter_fuelcut_set
ignition_cut_mode_check_load_imm:     LB      A, #028h
                STB     A, off(00190h)
                SJ      fuelcut_extra_gate
ignition_cut_mode_check_load_ram190:     LB      A, off(00190h)
                JNE     fuelcut_extra_gate
                LB      A, #002h
                STB     A, off(00191h)
revlimiter_fuelcut_set:     SB      PSWL.5
                SJ      fuelcut_result_common
fuelcut_extra_gate:     JBS     off(0011ch).2, ofc_enable_check
                JBR     off(0011ah).0, ofc_enable_check_if_ram126_bit0_set
ofc_enable_check:     JBR     off(00118h).2, fuelcut_tps_recheck
                RB      off(00126h).1
ofc_enable_check_if_ram126_bit0_set:     JBS     off(00126h).0, fuelcuttrack_store
                JBS     off(00126h).2, fuelcut_tps_recheck_if_ram11c_bit2_set
fuelcuttrack_store:     LB      A, #014h
                STB     A, off(001a3h)
fuelcut_clear_active_flag:     RB      off(0011ch).2
                SJ      fuelcut_output_flags
fuelcut_tps_recheck:     JBS     off(00126h).3, fuelcut_tps_recheck_if_ram11c_bit2_set
                SB      off(00126h).1
                SJ      fuelcuttrack_store
fuelcut_tps_recheck_if_ram11c_bit2_set:     JBS     off(0011ch).2, fuelcut_finalize_ign_flag
                J       fuelcut_tps_recheck_load_ram0a9
                DB  000h
to_fuelcut_clear_active_flag:     JGE     fuelcuttrack_store
                LB      A, off(001a3h)
                JEQ     fuelcut_finalize_ign_flag
                SB      off(00123h).7
                SJ      fuelcut_clear_active_flag
fuelcut_finalize_ign_flag:     JBR     off(00116h).3, fuelcut_finalize_ign_flag_if_ram126_bit5_set
                LB      A, 0b4h
                CMPB    A, #064h
                JGE     fuelcut_finalize_ign_flag_if_ram126_bit5_set
                LB      A, 0b5h
                SUBB    A, 0b4h
                JLT     fuelcut_finalize_ign_flag_if_ram111_bit5_set
                CMPB    A, #004h
                JGE     fuelcut_finalize_ign_flag_set_ram126_bit5
fuelcut_finalize_ign_flag_if_ram111_bit5_set:     JBS     off(00111h).5, fuelcut_finalize_ign_flag_if_ram126_bit5_set
                JBS     off(0011bh).7, fuelcut_finalize_ign_flag_if_ram126_bit5_set
                L       A, 0b0h
                CMP     A, #00100h
                JLT     fuelcut_finalize_ign_flag_if_ram126_bit5_set
                SB      off(00126h).6
                SJ      fuelcut_finalize_ign_flag_if_ram126_bit5_set
fuelcut_finalize_ign_flag_set_ram126_bit5:     SB      off(00126h).5
fuelcut_finalize_ign_flag_if_ram126_bit5_set:     JBS     off(00126h).5, fuelcut_clear_active_flag
                JBS     off(00126h).6, fuelcut_clear_active_flag
                JBS     off(00124h).3, fuelcut_clear_active_flag
                SB      PSWL.4
fuelcut_result_common:     SB      off(0011ch).2
fuelcut_output_flags:     MB      C, PSWL.5
                MB      off(0011ch).5, C
                MB      C, PSWL.4
                MB      off(0011ch).4, C
                RC
                RB      off(00123h).7
                JBS     off(0011ch).2, fuelcut_output_flags_set_carry
                JEQ     fuelcut_output_flags_store_carry_ram11c_bit3
fuelcut_output_flags_set_carry:     SC
fuelcut_output_flags_store_carry_ram11c_bit3:     MB      off(0011ch).3, C
                J       fuelcut_output_flags_load_ram0c4
tps_hysteresis_reentry_load_r2:     MOVB    r2, #00ah
                JBR     off(00119h).7, tps_hysteresis_reentry_if_ram11d_bit4_clr
                J       ignmap2_result_check_clear_acc
tps_hysteresis_reentry_if_ram11d_bit4_clr:     JBR     off(0011dh).4, tps_hysteresis_reentry_if_ram124_bit3_set
                LB      A, off(0012ch)
                MOV     X1, #tps_hysteresis_reentry_tbl
                VCAL    0
                SJ      to_set_pswl4_flag_b_set_pswl_bit4
tps_hysteresis_reentry_if_ram124_bit3_set:     JBS     off(00124h).3, ignmap2_result_check_clear_acc
                JBS     off(0011dh).5, ignmap2_result_check_clear_acc
                JBR     off(0011ah).3, postig_result_default
                JBR     off(0011ah).0, postig_result_default
                J       tps_hysteresis_reentry_if_ram116_bit3_clr
postig_gate_chain2:     JBS     off(00118h).4, postig_result_default
                LB      A, off(001eah)
                MOVB    r0, #045h
                JBS     off(00123h).5, postig_threshold_check1
                LB      A, off(001ebh)
                MOVB    r0, #05ah
postig_threshold_check1:     JBR     off(0011bh).0, postig_threshold_check2
                CMPB    A, r0
                JGE     postig_threshold_check2
                LB      A, r0
postig_threshold_check2:     J       postig_threshold_check2_if_ram117_bit6_clr
                DB  000h
postig_rpm_compare_cmp_ram0c1:     CMPB    0c1h, #034h
                JGE     postig_result_high
                JBR     off(00116h).3, postig_result_high
                LB      A, off(001a2h)
                STB     A, r2
                JNE     ignmap2_result_check_clear_acc
postig_result_high:     LB      A, #0dah
                JBS     off(00116h).3, to_set_pswl4_flag_b
                LB      A, #0f3h
to_set_pswl4_flag_b:     SB      PSWL.5
to_set_pswl4_flag_b_set_pswl_bit4:     SB      PSWL.4
                SJ      ignmap2_flags_store
postig_result_default:     LB      A, #080h
                MOV     X1, #tbl_ignmap2_hi
                JBR     off(00123h).5, ignmap2_rpm_gate
                LB      A, #073h
                MOV     X1, #tbl_ignmap2_lo
ignmap2_rpm_gate:     CMPB    A, off(0012dh)
                JGE     ignmap2_result_check_clear_acc
                LB      A, off(0012dh)
                VCAL    0
                ADDB    A, #002h
                JGE     ignmap2_result_check
                LB      A, #0ffh
ignmap2_result_check:     SUBB    A, off(0017ch)
                JLT     ignmap2_result_check_clear_acc
                CMPB    A, off(0012ch)
                JLE     ignmap2_result_check_clear_acc
                LB      A, #0f3h
                SJ      to_set_pswl4_flag_b_set_pswl_bit4
ignmap2_result_check_clear_acc:     CLRB    A
ignmap2_flags_store:     STB     A, off(00154h)
                MB      C, PSWL.4
                MB      off(00123h).5, C
                MB      C, PSWL.5
                MB      off(0011eh).1, C
                MOVB    off(001a2h), r2
                LB      A, #0d5h
                JBS     off(00125h).0, ignmap2_flags_store_cmp_acc
                LB      A, #0d8h
ignmap2_flags_store_cmp_acc:     CMPB    A, off(0012dh)
                MB      off(00125h).0, C
                LB      A, #012h
                JBS     off(0011ch).6, knock_window_check
                LB      A, #010h
knock_window_check:     CMPB    0adh, A
                MB      off(0011ch).6, C
                JGE     knock_window_gate_common
                RC
                JBS     off(0011dh).5, knock_window_gate_common
                JBS     off(00125h).0, knock_window_gate_common
                JBS     off(00123h).5, knock_window_gate_common
                JBS     off(0011ch).2, knock_window_gate_common
                SC
knock_window_gate_common:     MB      off(0011dh).2, C
                LB      A, #0bah
                JBS     off(0011dh).3, rpm_gate_final_check
                LB      A, #0c0h
rpm_gate_final_check:     CMPB    A, off(0012dh)
                MB      off(0011dh).3, C
                JBR     off(00118h).0, o2_closedloop_read_and_select
                MOVB    off(0018eh), #019h
o2_closedloop_read_and_select:     LB      A, #01fh
                MOVB    r0, #01fh
                CMPB    0a4h, #0dbh
                JLT     o2_closedloop_read_and_select_if_ram116_bit0_set
                LB      A, #01fh
                MOVB    r0, #01fh
o2_closedloop_read_and_select_if_ram116_bit0_set:     JBS     off(00116h).0, o2_closedloop_read_and_select_cmp_acc
                LB      A, r0
o2_closedloop_read_and_select_cmp_acc:     CMPB    A, 0c2h
                RB      off(00125h).2
                MB      off(00125h).2, C
                JEQ     o2_closedloop_delay_dec
                XORB    PSWH, #080h
o2_closedloop_delay_dec:     MB      off(00125h).1, C
                L       A, off(001b4h)
                JEQ     o2_closedloop_gate1
                DEC     off(001b4h)
o2_closedloop_gate1:     JBR     off(00119h).1, o2_trim_gate_common
                JBS     off(00119h).4, o2_trim_gate_common
                JBS     off(0011dh).4, o2_trim_gate_common
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2_trim_gate_common
                CMPB    0e8h, #00ch
                JLT     o2_trim_gate_common
                L       A, off(00112h)
                AND     A, #08075h
                JNE     o2_trim_gate_common
                L       A, off(00114h)
                AND     A, #01420h
                JNE     o2_trim_gate_common
                CMPB    0c1h, #028h
                JGE     o2_trim_gate_common
                LB      A, 0c2h
                STB     A, r0
                JBS     off(0011ch).4, o2_store_prev_reading
                CMPB    off(0012dh), #062h
                JGE     o2_gate_tps_check
                MOVB    off(00193h), #032h
o2_gate_tps_check:     LB      A, off(00193h)
                JNE     o2_gate_dp_set
                SB      off(00125h).3
o2_gate_dp_set:     RC
                JBS     off(0011ch).5, dtc01_o2_latch
                JBR     off(0011dh).5, dtc01_o2_latch
                LB      A, #04bh
                CMPB    A, off(00152h)
                JGE     dtc01_o2_latch
                CMPB    r0, #003h
                SJ      dtc01_o2_latch
o2_store_prev_reading:     JBS     off(00126h).4, o2_narrowband_check
                LB      A, r0
                STB     A, off(0017fh)
o2_narrowband_check:     JBR     off(00125h).3, o2_trim_gate_reset_dp
                LB      A, #04dh
                CMPB    A, r0
                JGE     o2_trim_gate_common
                JBS     off(00118h).2, o2_trim_gate_common
                LB      A, off(0017fh)
                SUBB    A, r0
                JGE     o2_delta_magnitude_check
                VCAL    7
o2_delta_magnitude_check:     CMPB    A, #002h
                JLT     dtc01_o2_latch
o2_trim_gate_common:     RB      off(00125h).3
o2_trim_gate_reset_dp:     MOVB    off(00193h), #032h
                RC
dtc01_o2_latch:     MB      098h.4, C
                MOVB    r0, #032h
                JBR     off(00119h).1, o2_trim_tps_mode_check_clear_ram16c
                JBS     off(0011dh).4, o2_trim_tps_mode_check_clear_ram16c
                MOV     er1, #08666h
                JBR     off(00116h).2, o2_trim_table_ptr_load
                MB      C, 0a0h.0
                JGE     o2_trim_table_ptr_load
                JBR     off(00125h).1, o2_trim_table_ptr_alt
                RB      0a0h.0
o2_trim_table_ptr_load:     L       A, #08666h
                JBS     off(00112h).2, o2_trim_clear_gate1
                JBS     off(00112h).4, o2_trim_clear_gate1
                L       A, off(00112h)
                AND     A, #08061h
                JNE     o2_trim_table_ptr_alt
                JBS     off(00115h).2, o2_trim_table_ptr_alt
                JBR     off(00115h).4, o2_trim_gate3
                NOP
o2_trim_table_ptr_alt:     L       A, er1
                SJ      o2_trim_clear_gate1
o2_trim_gate3:     JBR     off(00119h).2, o2_trim_tps_mode_check_clear_ram16c
                JBS     off(0011dh).5, o2_trim_tps_mode_check_clear_ram16c
                JBS     off(00119h).0, o2_trim_tps_mode_check
                CLRB    off(0016ch)
                MOVB    off(0019fh), r0
                MOV     DP, #00304h
                JBR     off(00118h).0, o2_trim_dp_table_read
                MOV     DP, #00300h
o2_trim_dp_table_read:     L       A, [DP]
                SJ      o2_trim_clear_gate1
o2_trim_tps_mode_check:     JBS     off(00125h).0, o2_trim_tps_mode_check_clear_ram16c
                JBR     off(0011ch).6, o2_trim_alt_path_check_load_ram16c
                J       o2_trim_tps_mode_check_if_ram11c_bit2_clr
o2_trim_alt_path_check:     JBR     off(00123h).5, o2_trim_alt_path_check_set_ram11d_bit1
o2_trim_alt_path_check_load_ram16c:     MOVB    off(0016ch), #004h
                LB      A, off(0019fh)
                JEQ     o2_trim_default_target
                L       A, off(00148h)
                SB      off(0011dh).1
                SJ      o2_trim_clear_gate0_and_return
o2_trim_tps_mode_check_clear_ram16c:     CLRB    off(0016ch)
                MOVB    off(0019fh), r0
o2_trim_default_target:     L       A, #08000h
o2_trim_clear_gate1:     RB      off(0011dh).1
o2_trim_clear_gate0_and_return:     RB      off(0011dh).0
                J       injtimer_finalize_start
o2_trim_alt_path_check_set_ram11d_bit1:     SB      off(0011dh).1
                MOVB    off(0019fh), r0
                MB      C, off(00125h).5
                MB      PSWL.4, C
                LB      A, #052h
                JLT     o2_trim_step_threshold
                LB      A, #064h
o2_trim_step_threshold:     CMPB    A, off(0012ch)
                MB      off(00125h).5, C
                CLR     A
                LC      A, o2_trim_step_threshold_tbl
                SB      off(0011dh).0
                JEQ     o2_trim_dp300_read
                JBS     off(00118h).3, o2_trim_alt_gate
                JBR     off(00118h).2, o2_trim_alt_gate
                ST      A, off(0016ah)
                JBR     off(00118h).1, o2_trim_dp304_calc
                MOV     DP, #00308h
                MOV     er1, [DP]
                SJ      o2_trim_step_finalize2
o2_trim_dp300_read:     ST      A, off(0016ah)
                MOV     DP, #00300h
                MOV     er1, [DP]
                JBS     off(00118h).0, o2_trim_step_finalize2
o2_trim_dp304_calc:     MOV     DP, #00304h
                MOV     er0, [DP]
                J       o2_trim_dp304_calc_load_imm
                DB  000h,000h,000h
o2_trim_dp304_calc_if_lt_goto_o2_trim_mul_apply:     JLT     o2_trim_mul_apply
                L       A, er1
o2_trim_mul_apply:     MUL
                SLL     A
                ROL     er1
                JGE     o2_trim_step_finalize2
                MOV     er1, #0ffffh
o2_trim_step_finalize2:     SB      PSWL.5
                SJ      o2_trim_result_check
o2_trim_alt_gate:     MOV     er1, off(00148h)
                MB      C, PSWL.4
                JLT     o2_trim_alt_gate_clear_pswl_bit5
                JBR     off(00125h).5, o2_trim_alt_gate_clear_pswl_bit5
                MOV     DP, #00304h
                CMP     [DP], off(00148h)
                JGT     o2_trim_dp304_calc
o2_trim_alt_gate_clear_pswl_bit5:     RB      PSWL.5
                JBR     off(00125h).1, o2_trim_result_check
                ST      A, off(0016ah)
o2_trim_result_check:     MB      C, PSWL.5
                JLT     o2_trim_result_check_load_acc
                JBS     off(00125h).1, o2_trim_rpm_alt_check
o2_trim_result_check_load_acc:     LB      A, ACC
                LC      A, o2_trim_step_threshold_tbl
                MOV     DP, #0016ah
                JBR     off(00125h).2, o2_trim_decrement_apply
                J       o2_trim_result_check_load_acch
o2_trim_result_check_inc_dp:     INC     DP
o2_trim_decrement_apply:     DECB    [DP]
                JEQ     o2_trim_decrement_store
                J       o2trim_gate_common2
o2_trim_decrement_store:     STB     A, [DP]
o2_trim_rpm_alt_check:     J       o2_trim_rpm_alt_check_load_x1
o2_trim_rpm_alt_check_load_stk:     LB      A, (00292h-00280h)[USP]
                CMPB    A, off(0012dh)
                LB      A, #004h
                JLT     o2_trim_flag_store2
                CLRB    A
o2_trim_flag_store2:     STB     A, off(0016ch)
o2_trim_bank_index_calc:     CLR     X1
                JBS     off(00127h).0, o2_trim_rate_table_select
                INC     X1
                LB      A, off(0012dh)
                CMPB    A, #07ah
                JGE     o2_trim_rate_table_select
                INC     X1
                CMPB    A, #040h
                JGE     o2_trim_rate_table_select
                INC     X1
                SJ      o2_trim_rate_table_select
o2_trim_bank_index_alt:     MOV     X1, #00004h
                LB      A, off(0016ch)
                JEQ     o2_trim_rate_table_select
                JBR     off(00125h).1, o2_trim_bank_index_calc
                DECB    off(0016ch)
                JNE     o2_trim_bank_index_calc
o2_trim_rate_table_select:     SLL     X1
                MOV     DP, #CloseLoopRate
                MB      C, PSWL.5
                JLT     o2_trim_table_offset_calc
                JBR     off(00125h).1, o2_trim_table_offset_calc
                MOV     DP, #CloseLoopGoose
                JBS     off(00125h).2, o2_trim_table_offset_calc
                LB      A, off(001a0h)
                JEQ     o2trim_apply_start
o2_trim_table_offset_calc:     L       A, X1
                JBR     off(00116h).3, o2_trim_table_offset_calc2
                ADD     A, #0000ch
o2_trim_table_offset_calc2:     JBS     off(00116h).0, o2_trim_rate_table_read
                ADD     A, #01713h
o2_trim_rate_table_read:     ADD     DP, A
                LC      A, [DP]
                JBS     off(00125h).2, o2trim_sub_clamp
                SJ      o2trim_add_clamp
o2trim_apply_start:     MOVB    off(001a0h), #014h
                L       A, #00b00h
                JBS     off(00127h).0, o2trim_add_clamp
                L       A, #00000h
                JBS     off(00116h).3, cmp_x1_bound8_dispatch
                L       A, #00000h
cmp_x1_bound8_dispatch:     CMP     X1, #00008h
                JEQ     o2trim_add_clamp
                MOVB    r0, #087h
                MOV     er2, #006f7h
                MOV     er3, #006f7h
                LB      A, #064h
                JBS     off(00116h).3, to_o2trim_add_clamp
                MOVB    r0, #087h
                MOV     er2, #00600h
                MOV     er3, #00600h
                LB      A, #051h
to_o2trim_add_clamp:     CMPB    A, off(0012ch)
                JGT     to_o2trim_add_clamp_load_ram168
                L       A, er2
                JBS     off(00116h).0, to_o2trim_add_clamp_cmp_r0
                L       A, er3
to_o2trim_add_clamp_cmp_r0:     CMPB    r0, off(0012dh)
                JLE     o2trim_add_clamp
to_o2trim_add_clamp_load_ram168:     L       A, off(00168h)
                CMPB    off(0012ch), #064h
                JGE     o2trim_add_clamp
                L       A, off(00166h)
o2trim_add_clamp:     ADD     er1, A
                JGE     o2trim_speed_flag_set
                MOV     er1, #0ffffh
                SJ      o2trim_speed_flag_set
o2trim_sub_clamp:     SUB     er1, A
                JGE     o2trim_speed_flag_set
                CLR     er1
o2trim_speed_flag_set:     SB      PSWL.4
                L       A, #0bc15h
                J       o2trim_speed_flag_set_cmp_acc
o2trim_speed_flag_set_load_carry_pswl_bit4:     MB      C, PSWL.4
                MB      off(0011eh).4, C
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2trim_gate_common2
                J       o2trim_speed_flag_set_load_carry_p1_bit6
o2trim_speed_flag_set_if_ne_goto_o2trim_gate_common2:     JNE     o2trim_gate_common2
                J       o2trim_speed_flag_set_if_ram119_bit2_clr
o2trim_speed_flag_set_cmp_ram0c0:     CMPB    0c0h, #030h
                JLT     o2trim_gate_common2
                CLR     A
                CLRB    A
                MB      C, PSWL.5
                JLT     o2trim_bank_select_check
                JBR     off(00125h).1, o2trim_bank_select_check
                JBS     off(0011dh).3, o2trim_gate_common2
                MOV     X1, #00300h
                JBS     off(00118h).0, o2trim_ect_offset_lookup
                MOV     X1, #00304h
                LB      A, #004h
                SJ      o2trim_ect_offset_lookup
o2trim_bank_select_check:     JBS     off(00118h).0, o2trim_gate_common2
                LB      A, off(0018eh)
                JEQ     o2trim_gate_common2
                MOV     X1, #00308h
                LB      A, #008h
o2trim_ect_offset_lookup:     CMPB    0c1h, #02eh
                JGE     o2trim_ect_offset_lookup_rom_load_tbl_60bc_acc
                ADDB    A, #002h
o2trim_ect_offset_lookup_rom_load_tbl_60bc_acc:     LC      A, o2trim_ect_offset_lookup_tbl[ACC]
                L       A, ACC
                ST      A, er0
                L       A, er1
                ST      A, er3
                CAL     injtimer_bank_calc1
                CAL     injtimer_bank_calc2
                MOV     er1, er3
o2trim_gate_common2:     L       A, er1
injtimer_finalize_start:     ST      A, off(00148h)
                J       to_injtimer_sub_common
                DW  00000h
to_injtimer_sub_common_load_imm:     LB      A, #040h
                JBS     off(00123h).4, to_injtimer_sub_common_store_ram153
                JBS     off(00123h).5, to_injtimer_sub_common_store_ram153
                MOV     X1, #to_injtimer_sub_common_tbl
                MOV     X2, #0015ah
                JBR     off(0011dh).0, to_injtimer_sub_common_if_ram116_bit3_set
                ADD     X1, #00004h
                INC     X2
                INC     X2
to_injtimer_sub_common_if_ram116_bit3_set:     JBS     off(00116h).3, to_injtimer_sub_common_load_tbl_x2
                INC     X1
to_injtimer_sub_common_load_tbl_x2:     LB      A, 00000h[X2]
                STB     A, r6
                LB      A, 00001h[X2]
                J       to_injtimer_sub_common_store_r7
to_injtimer_sub_common_call_table_interp_lookup_prescan:     CAL     table_interp_lookup_prescan
to_injtimer_sub_common_store_ram153:     STB     A, off(00153h)
                LB      A, off(0012ch)
                MOV     X1, #tbl_injtimer_finalize
                VCAL    0
                MOVB    ACCH, #002h
                MOVB    r0, off(00156h)
                CLRB    r1
                MUL
                SRL     er1
                RORB    ACCH
                LB      A, r2
                L       A, ACC
                SWAP
                ADD     A, #00200h
                ST      A, off(0014eh)
                LB      A, #03ah
                JBS     off(00125h).6, to_injtimer_sub_common_cmp_acc
                LB      A, #040h
to_injtimer_sub_common_cmp_acc:     CMPB    A, off(0012dh)
                MB      off(00125h).6, C
                LB      A, #01ch
                JBS     off(00125h).7, to_injtimer_store_0x166
                LB      A, #01dh
to_injtimer_store_0x166:     CMPB    A, 0b9h
                MB      off(00125h).7, C
                JBR     off(00119h).1, injtimer_gate_common
                JBS     off(00118h).5, injtimer_gate_common
                CMPB    0c1h, #0e0h
                JGE     injtimer_gate_common
                J       to_injtimer_store_0x166_cmp_ram0c1
to_injtimer_store_0x166_if_ram125_bit7_clr:     JBR     off(00125h).7, injtimer_gate_common
                JBR     off(00119h).0, injtimer_gate_common
                JBS     off(00123h).5, injtimer_gate_common
                JBS     off(0011dh).1, injtimer_gate_common
                JBS     off(00125h).2, injtimer_gate_common
                LB      A, #014h
                SJ      injtimer_store_0x166
injtimer_gate_common:     LB      A, off(00157h)
                SUBB    A, #001h
                JGE     injtimer_store_0x166
                CLRB    A
injtimer_store_0x166:     STB     A, off(00157h)
                LB      A, off(00152h)
                JBS     off(00123h).4, injtimer_store_0x166_store_r1
                LB      A, off(00153h)
injtimer_store_0x166_store_r1:     STB     A, r1
                CLRB    r0
                SRL     er0
                LB      A, off(00154h)
                JEQ     injtimer_store_0x166_load_ram155
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1
injtimer_store_0x166_load_ram155:     LB      A, off(00155h)
                JEQ     injtimer_mul_chain1
                STB     A, ACCH
                CLRB    A
                MUL
                MOV     er0, er1
injtimer_mul_chain1:     MOVB    ACCH, #001h
                LB      A, off(00157h)
                MUL
                MOVB    r1, r2
                MOVB    r0, ACCH
                L       A, off(00150h)
                MUL
                MOV     er0, er1
                L       A, off(0014eh)
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
injtimer_mul_chain2:     L       A, off(0014ch)
                MUL
                MOV     er0, er1
                NOP
                NOP
                NOP
                JBR     off(0011fh).0, injtimer_mul_final
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
injtimer_mul_chain3:     L       A, off(0014ah)
                MUL
                MOV     er0, er1
injtimer_mul_final:     L       A, off(00148h)
                MUL
                MOV     off(00146h), er1
                JBS     off(0011dh).4, dwell_zero_result
                LB      A, off(0012dh)
                CMPB    A, #0c0h
                JGE     dwell_zero_result
                JBS     off(00121h).0, injtimer_mul_final_load_imm
                CMPB    0a6h, #04bh
                JLT     dwell_zero_result
                SB      off(00121h).0
injtimer_mul_final_load_imm:     LB      A, #004h
                JBS     off(0011bh).5, dwell_rpm_gate2
                LB      A, #004h
                CMPB    0e9h, #096h
                JLT     dwell_zero_result
dwell_rpm_gate2:     CMPB    off(0012dh), #002h
                JBS     off(0011bh).5, dwell_rpm_gate3
                CMPB    off(0012dh), #05ah
dwell_rpm_gate3:     JLT     dwell_zero_result
                CMPB    A, 0a9h
                JGE     dwell_zero_result
                J       dwell_rpm_gate3_load_r0
dwell_value_select:     MOVB    r1, #018h
                JBS     off(0011bh).5, dwell_clamp_check
                MOVB    r0, off(00174h)
                MOVB    r1, #010h
dwell_clamp_check:     LB      A, 0a9h
                CMPB    A, r1
                JLE     dwell_mul_apply
                LB      A, r1
dwell_mul_apply:     MULB
                L       A, ACC
                SRL     A
                JBS     off(0011bh).5, dwell_store_result
                VCAL    7
                SJ      dwell_store_result
dwell_zero_result:     CLR     A
dwell_store_result:     ST      A, off(0013eh)
                CLRB    r4
                RC
                JBS     off(0011dh).4, rpm_accel_skip
                JBR     off(0011ah).4, rpm_accel_skip
                JBS     off(00124h).7, rpm_accel_track_calc
                JBS     off(0011ah).5, rpm_accel_alt_path
                L       A, (00258h-00280h)[USP]
                CLRB    r5
                SJ      rpm_accel_track_store
rpm_accel_track_calc:     MOV     er3, off(00130h)
                MOVB    r5, off(00132h)
                CLRB    r0
                MOVB    r1, #033h
                L       A, 0ach
                CAL     rpm_accel_track_helper
rpm_accel_track_store:     ST      A, off(00130h)
                MOVB    off(00132h), r5
                CLRB    r4
                SUB     A, 0ach
                MB      off(00124h).6, C
                JLT     rpm_accel_fault_path
                JBS     off(0011bh).6, rpm_accel_secondary_calc
                CMP     0aeh, #0001ah
                SJ      rpm_accel_gate_result
rpm_accel_fault_path:     VCAL    7
                JBR     off(0011bh).6, rpm_accel_secondary_calc
                CMP     0aeh, #0001ah
rpm_accel_gate_result:     JGE     rpm_accel_clamp
rpm_accel_secondary_calc:     CLRB    r0
                MOVB    r1, #020h
                CMPB    0c1h, #034h
                JGE     rpm_accel_mul_apply
                JBS     off(00116h).3, rpm_accel_mul_apply
                CMPB    0b4h, #005h
                JLT     rpm_accel_mul_apply
                MOVB    r1, #020h
rpm_accel_mul_apply:     MUL
                MOVB    r4, #032h
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
rpm_accel_skip:     MB      off(00124h).7, C
rpm_accel_alt_path:     LB      A, r4
                JEQ     rpm_accel_store_0x148
                JBS     off(00124h).6, rpm_accel_store_0x148
                VCAL    7
rpm_accel_store_0x148:     STB     A, off(00140h)
                CLR     A
                CLRB    r0
                JBS     off(0011dh).4, rpm_decel_flags_clear
                JBS     off(0011ch).0, rpm_decel_flags_clear
                MOVB    r0, #004h
                JBS     off(0011ch).2, rpm_decel_flags_clear
                MOVB    r0, off(0017dh)
                CMPB    r0, #000h
                JNE     rpm_decel_table_lookup
                JBR     off(0011bh).1, rpm_decel_counter_check
                CMPB    0bdh, #008h
                JGE     rpm_decel_flags_clear
rpm_decel_counter_check:     J       rpm_decel_counter_check_load_r1
rpm_decel_counter_check_if_eq_goto_rpm_decel_diff_check2:     JEQ     rpm_decel_diff_check2
                DECB    r1
                JNE     rpm_decel_store_0x14a
rpm_decel_diff_check2:     L       A, off(001deh)
                JEQ     rpm_decel_flags_clear
                SUB     A, off(001e0h)
                JGE     rpm_decel_flags_clear
                CLR     A
                SJ      rpm_decel_flags_clear
rpm_decel_table_lookup:     LB      A, off(0012dh)
                MOV     X1, #tbl_rpm_decel
                VCAL    1
                ; warning: had to flip DD
                CMP     A, 0b0h
                CLR     A
                MOVB    r0, off(0017dh)
                DECB    r0
                JBS     off(0011bh).7, rpm_decel_store_0x150
                JGE     rpm_decel_store_0x150
                L       A, #00145h
                JBS     off(00126h).5, rpm_decel_mul_final
                L       A, #000fah
                JBS     off(00126h).6, rpm_decel_mul_final
                L       A, #0004bh
                JBR     off(00116h).3, rpm_decel_mul_final
                L       A, #0007dh
rpm_decel_mul_final:     CAL     scale_ram1e4_mul_shr2
                CLRB    r0
rpm_decel_flags_clear:     RB      off(00126h).5
                RB      off(00126h).6
rpm_decel_store_0x150:     ST      A, off(001deh)
                MOVB    r1, #004h
rpm_decel_store_0x14a:     ST      A, off(00142h)
                MOVB    off(0017dh), r0
                MOVB    off(0017eh), r1
                CLR     A
                J       rpm_decel_store_0x14a_cmp_ram12d
                DB  000h
rpm_decel_store_0x14a_if_lt_goto_idle_sub_result_store:     JLT     idle_sub_result_store
                L       A, off(001e2h)
                JEQ     idle_sub_result_store
                CLRB    r0
                MOVB    r1, off(00175h)
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_sub_result_store
                L       A, #0ffffh
idle_sub_result_store:     ST      A, off(00176h)
                JBR     off(0011ch).4, tipin_time_calc
                CLR     A
                MOV     X1, A
                ST      A, 003ach[X1]
                ST      A, 003aeh[X1]
                ST      A, 003b0h[X1]
                ST      A, 003b2h[X1]
                J       idle_sub_result_store_store_tbl_x1
idle_sub_result_store_goto_1fe6:     J       cylinder_ign_correct_apply_goto_5c43
tipin_time_calc:     L       A, off(0013ah)
                JBR     off(00123h).3, tipin_time_calc_add_acc
                CMPB    0e8h, #004h
                MB      off(00123h).3, C
                ADD     A, #0007dh
                JLT     tipin_time_clamp
tipin_time_calc_add_acc:     ADD     A, off(0013ch)
                JLT     tipin_time_clamp
                ADD     A, off(00142h)
                JGE     tipin_time_finalize
tipin_time_clamp:     L       A, #0ffffh
tipin_time_finalize:     ST      A, er0
                LB      A, off(00140h)
                EXTND
                MOV     er3, off(0013eh)
                CAL     add_saturate_s16
                LB      A, off(00141h)
                EXTND
                CAL     add_saturate_s16
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
                L       A, off(00138h)
                MOV     er0, off(00146h)
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
                VCAL    5
                J       injtimer_bank_a_calc_if_ram11c_bit5_clr
injtimer_bank_a_store_load_er0:     MOV     er0, [DP]
                ST      A, [DP]
                JBS     off(0011dh).4, injtimer_bank_b_zero
                JBS     off(00126h).4, injtimer_bank_b_zero
                CMPB    off(0012dh), #0a0h
                JGE     injtimer_bank_b_zero
                CMP     off(00142h), #00000h
                JNE     injtimer_bank_b_zero
                SUB     A, er0
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
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     injtimer_bank_b_store
                L       A, #0ffffh
injtimer_bank_b_store:     ST      A, off(00178h)
                L       A, off(00142h)
                CMP     A, off(00176h)
                JGE     injtimer_bank_b_store_cmp_acc
                L       A, off(00176h)
injtimer_bank_b_store_cmp_acc:     CMP     A, off(00178h)
                MB      off(00123h).2, C
                JGE     injtimer_bank_c_check
                L       A, off(00178h)
injtimer_bank_c_check:     L       A, ACC
                JEQ     injtimer_bank_c_store
                ADD     A, off(0013ch)
                JGE     injtimer_bank_c_scale
                L       A, #0ffffh
injtimer_bank_c_scale:     CAL     scale_mul5_div4
injtimer_bank_c_store:     MOV     X1, A
                JBR     off(00123h).2, injtimer_critsection_start
                CLR     A
injtimer_critsection_start:     AND     IE, #002a0h
; --- Per-cylinder injector timer write (critical section, interrupts masked via IE/PSWH):
; cylinder_ign_correct_loop applies CylinderIGNCorrect (real per-cylinder ignition-correction
; calibration table) and a mul5/div4 scale to each cylinder's computed value, writing results
; to the injector timer-compare registers up through 0x3C0 -- this is the routine referenced
; back in ign_angle_to_timer_convert's comment as "programming the two ignition coil-channel
; hardware timers" (the same critical-section pattern, here for injector-side output).
                RB      PSWH.0
                MOV     off(001c4h), X1
                ST      A, off(001c0h)
                ST      A, off(001c2h)
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                MOV     X1, #CylinderIGNCorrect
cylinder_ign_correct_loop:     INC     DP
                INC     DP
                L       A, er2
                JBR     off(0011dh).1, cylinder_ign_correct_apply
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
                VCAL    5
                CAL     scale_mul5_div4
                ST      A, [DP]
                INC     X1
                CMP     DP, #003b4h
                JLT     cylinder_ign_correct_loop
cylinder_ign_correct_apply_goto_5c43:     J       cylinder_ign_correct_apply_load_imm_2
                DB  000h
cylinder_ign_correct_apply_load_imm:     LB      A, #005h
                JBS     off(0011dh).4, deadtime_retry_store_goto_injector_effective_pw_store
                MOVB    r6, #007h
                L       A, off(00112h)
                AND     A, #01034h
                JNE     to_gio_mode_dispatch
                MOVB    r6, #006h
                JBS     off(00117h).5, to_gio_mode_dispatch
                MOVB    r6, #006h
                JBS     off(00123h).2, to_gio_mode_dispatch
                CMPB    0c1h, #02eh
                JGE     deadtime_ect_offset
                MOVB    r6, #007h
                JBS     off(00118h).0, to_gio_mode_dispatch
deadtime_ect_offset:     CLR     DP
                LB      A, 0c1h
                CMPB    A, #0aeh
                JGE     deadtime_ect_offset_load_imm
                ADD     DP, #00003h
deadtime_ect_offset_load_imm:     LB      A, #038h
                JBS     off(00123h).1, deadtime_ect_offset_cmp_ram0a6
                LB      A, #030h
deadtime_ect_offset_cmp_ram0a6:     CMPB    0a6h, A
                MB      off(00123h).1, C
                LB      A, #077h
                JBS     off(00123h).0, deadtime_voltage_flag_store
                LB      A, #070h
deadtime_voltage_flag_store:     CMPB    0a6h, A
                MB      off(00123h).0, C
                JGE     deadtime_voltage_flag_store_rom_load_tbl_601c_dp
                INC     DP
                JBR     off(00123h).1, deadtime_voltage_flag_store_rom_load_tbl_601c_dp
                INC     DP
deadtime_voltage_flag_store_rom_load_tbl_601c_dp:     LCB     A, deadtime_voltage_flag_store_tbl[DP]
                STB     A, r6
                SJ      to_gio_mode_dispatch
deadtime_retry_check:     MB      C, 09fh.0
                JGE     deadtime_retry_store
                LB      A, #005h
deadtime_retry_store:     SUBB    A, #001h
                STB     A, off(00135h)
                LB      A, #00bh
deadtime_retry_store_goto_injector_effective_pw_store:     SJ      injector_effective_pw_store
to_gio_mode_dispatch:     MOV     DP, #003ach
                L       A, [DP]
                CAL     scale_mul5_div4
                CLR     er0
                MOV     er2, off(0012eh)
                DIV
                JLT     injector_effective_pw_skip
                CMP     A, #0000bh
                JGT     injector_effective_pw_skip
                LB      A, ACC
                XCHGB   A, r6
                J       to_gio_mode_dispatch_subb_acc
injector_effective_pw_skip:     CLRB    A
injector_effective_pw_store:     STB     A, off(00133h)
                LB      A, #0c2h
                JBS     off(0011ch).0, rpm_hyst_flag_124_0
                LB      A, #0c5h
rpm_hyst_flag_124_0:     CMPB    A, off(0012dh)
                MB      off(0011ch).0, C
                LB      A, #0edh
                JBS     off(0011ch).1, rpm_hyst_flag_124_1
                LB      A, #0f0h
rpm_hyst_flag_124_1:     CMPB    A, off(0012dh)
                MB      off(0011ch).1, C
                JBR     off(00119h).1, crank_edge_carry_clear
                JBR     off(00116h).6, crank_edge_carry_clear
                LB      A, off(00194h)
                JNE     crank_edge_carry_clear
                JBR     off(00119h).3, crank_edge_carry_clear
                MOV     DP, #00f00h
                LB      A, [DP]
                ANDB    A, #040h
                MB      C, 0a0h.5
                JLT     crank_edge_sync_check
                JNE     crank_edge_carry_set
                RB      P1.2
                AND     IE, #002a0h
                RB      PSWH.0
                LB      A, P1
                MOV     DP, #02f00h
                STB     A, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                SJ      crank_edge_direction_toggle
crank_edge_sync_check:     JEQ     crank_edge_carry_set
crank_edge_direction_toggle:     XORB    PSWH, #080h
                MB      0a0h.5, C
                JGE     crank_edge_carry_clear
                MOVB    off(00194h), #019h
crank_edge_carry_clear:     RC
                SJ      dtc27_code27_latch
crank_edge_carry_set:     SC
dtc27_code27_latch:     MB      09bh.2, C
                JBR     off(00116h).7, crank_edge_flag_store_clear_acc
                JBR     off(00116h).3, crank_edge_flag_store_clear_acc
                LB      A, #001h
                JBS     off(00129h).0, crank_edge_flag_store_cmp_ram0c1
                LB      A, #000h
crank_edge_flag_store_cmp_ram0c1:     CMPB    0c1h, A
                MB      off(00129h).0, C
                LB      A, #0ffh
                JBS     off(00129h).1, crank_edge_flag_store_cmp_acc
                LB      A, #0ffh
crank_edge_flag_store_cmp_acc:     CMPB    A, off(0012ch)
                MB      off(00129h).1, C
                LB      A, #0ffh
                JBS     off(00129h).2, crank_edge_flag_store_cmp_ram0a6
                LB      A, #0ffh
crank_edge_flag_store_cmp_ram0a6:     CMPB    0a6h, A
                MB      off(00129h).2, C
                LB      A, #000h
                JBS     off(0011ch).7, crank_edge_flag_store_cmp_acc_2
                LB      A, #001h
crank_edge_flag_store_cmp_acc_2:     CMPB    A, off(0012dh)
                MB      off(0011ch).7, C
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #032h
                JNE     crank_edge_flag_store_if_ram11c_bit7_set
                MOV     X1, #crank_edge_flag_store_tbl
                LB      A, off(0012dh)
                VCAL    0
                SJ      crank_edge_flag_store_clear_carry
crank_edge_flag_store_if_ram11c_bit7_set:     JBS     off(0011ch).7, crank_edge_flag_store_clear_acc
                JBS     off(00117h).5, crank_edge_flag_store_clear_acc
                L       A, off(00112h)
                AND     A, #0907ch
                JNE     crank_edge_flag_store_clear_acc
                JBR     off(00113h).3, crank_edge_flag_store_if_ram11c_bit2_set
                JBR     off(0011ah).1, crank_edge_flag_store_clear_acc
                LB      A, (002f2h-00280h)[USP]
                CMPB    A, #0ffh
                JLT     crank_edge_flag_store_clear_acc
                CMPB    A, #0ffh
                JGT     crank_edge_flag_store_clear_acc
crank_edge_flag_store_if_ram11c_bit2_set:     JBS     off(0011ch).2, crank_edge_flag_store_clear_acc
                JBS     off(0011dh).5, crank_edge_flag_store_clear_acc
                JBR     off(00118h).2, crank_edge_flag_store_clear_acc
                JBS     off(00112h).0, crank_edge_flag_store_if_ram11d_bit2_clr
                JBS     off(00115h).2, crank_edge_flag_store_if_ram11d_bit2_clr
                JBS     off(00115h).4, crank_edge_flag_store_if_ram11d_bit2_clr
                JBS     off(0011dh).1, crank_edge_flag_store_if_ram129_bit0_clr
crank_edge_flag_store_clear_acc:     CLRB    A
crank_edge_flag_store_clear_carry:     RC
                SJ      crank_edge_flag_store_store_carry_ram11d_bit7
crank_edge_flag_store_if_ram11d_bit2_clr:     JBR     off(0011dh).2, crank_edge_flag_store_clear_acc
crank_edge_flag_store_if_ram129_bit0_clr:     JBR     off(00129h).0, crank_edge_flag_store_clear_acc
                JBR     off(00129h).1, crank_edge_flag_store_clear_acc
                JBS     off(00129h).2, crank_edge_flag_store_clear_acc
                MOVB    r3, off(001d8h)
                MOV     er3, off(001dah)
                MOV     X1, #crank_edge_flag_store_tbl_3
                LB      A, #000h
                CMPB    A, r3
                JGT     crank_edge_flag_store_clear_acc
                ADDB    A, #00ah
                CMPB    A, r3
                JLE     crank_edge_flag_store_clear_acc
                SUBB    r3, #000h
                MOVB    r0, #00ah
                MOVB    r1, #00bh
                MOVB    r2, off(001d3h)
                MOV     X2, off(001d6h)
                RB      PSWL.5
                CAL     table2d_lookup_interp
                LB      A, (002f1h-00280h)[USP]
                MB      C, ACC.7
                JGE     crank_edge_flag_store_addb_acc
                ADDB    A, r4
                JLT     crank_edge_flag_store_store_r1
                CLRB    A
                SJ      crank_edge_flag_store_store_r1
crank_edge_flag_store_addb_acc:     ADDB    A, r4
                JGE     crank_edge_flag_store_store_r1
                LB      A, #0ffh
crank_edge_flag_store_store_r1:     STB     A, r1
                MOVB    r0, #004h
                MOVB    ACCH, #004h
                MOV     DP, #003c4h
                LB      A, [DP]
                ADDB    A, #01fh
                JLT     crank_edge_flag_store_load_acch
                MULB
crank_edge_flag_store_load_acch:     LB      A, ACCH
                EXTND
                LCB     A, crank_edge_flag_store_tbl_2[ACC]
                MOVB    r0, r1
                MULB
                SLL     A
                LB      A, ACCH
                JGE     crank_edge_flag_store_set_carry
                LB      A, #0ffh
crank_edge_flag_store_set_carry:     SC
crank_edge_flag_store_store_carry_ram11d_bit7:     MB      off(0011dh).7, C
                STB     A, (002f3h-00280h)[USP]
                CAL     crank_edge_helper
                SB      09eh.4
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                NOP
                NOP
                NOP
                J       int1_rti_epilogue
; [flow] int_spurious_irq_trap: every interrupt vector this ROM never enables points here. It stamps trap
;    reason 045h and goes through fault_retry_check (retry budget, then BRK -> int_break re-init).
int_spurious_irq_trap:  MOVB    0ebh, #045h
                SJ      fault_retry_check
int_WDT:        MOVB    0ebh, #044h
fault_retry_check:     LB      A, 0ech
                JEQ     fault_giveup_latch
                DECB    0ech
                JNE     fault_trigger_brk
fault_giveup_latch:     SB      09fh.1
fault_trigger_brk:     BRK
int_start:      MOVB    0ebh, #046h
                RB      09fh.1
int_break:      MOVB    WDT, #03ch
                MOV     SSP, #0047eh
                MOV     LRB, #00010h
                CLR     off(PSW)
                LB      A, off(000ebh)
                STB     A, off(000e7h)
                JNE     breset_check_reason_46_47
                MOVB    off(000ebh), #04eh
                SJ      fault_retry_check
breset_check_reason_46_47:     CMPB    A, #046h
                JEQ     breset_reason_46_or_47_common
                CMPB    A, #047h
                JNE     breset_check_p4_1
breset_reason_46_or_47_common:     CLRB    off(000e7h)
                MOV     DP, #04700h
                LB      A, [DP]
                SRLB    A
                MB      off(0009fh).0, C
                JBS     off(0009fh).1, breset_check_p4_1
                MOVB    off(000ech), #020h
breset_check_p4_1:     JBR     off(P4).1, selftest_reg_stuckbit_check
                J       int_NMI
selftest_reg_stuckbit_check:     L       A, #05555h
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
                ST      A, 0f2h
                ST      A, 0f4h
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
selftest_fail_041:     MOVB    0ebh, #041h
                BRK
periph_init_start:     CLRB    off(PRPHF)
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
periph_init_delay_loop_load_dp:     MOV     DP, #00177h
periph_init_delay_loop:     DEC     DP
                JEQ     periph_init_delay_loop_load_ram0eb
                MBR     C, off(P4)
                JLT     periph_init_delay_loop
                MOV     DP, #00177h
periph_init_delay_loop_dec_dp:     DEC     DP
                JEQ     periph_init_delay_loop_load_ram0eb
                MBR     C, off(P4)
                JGE     periph_init_delay_loop_dec_dp
                MOV     DP, #000b2h
periph_init_delay_loop_dec_dp_2:     DEC     DP
                JEQ     periph_init_delay_loop_load_ram0eb
                MBR     C, off(P4)
                JLT     periph_init_delay_loop_dec_dp_2
                INCB    ACC
                CMPB    A, #004h
                JNE     periph_init_delay_loop_load_dp
                RB      off(IRQH).5
                JNE     periph_init_delay_loop_load_imm
periph_init_delay_loop_load_ram0eb:     MOVB    off(000ebh), #04ch
                BRK
periph_init_delay_loop_load_imm:     L       A, #0ffffh
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
selftest_fail_042:     MOVB    off(000ebh), #042h
                BRK
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
                CMPB    0ebh, #047h
                JNE     restore_trapstate_after_ramclear
                JBR     off(00230h).0, cfgvariant_check_320h_bit7
                JBR     off(00230h).1, cfgvariant_check_320h_bit7
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
                LCB     A, cfgvariant_index_lookup_tbl[ACC]
                CMPB    A, r6
                JEQ     cfgvariant_clear_232h_bits45
                MOVB    0ebh, #043h
                BRK
cfgvariant_clear_232h_bits45:     ANDB    off(00230h), #0fch
cfgvariant_check_320h_bit7:     MOV     DP, #0031ch
                RB      [DP].7
                CAL     cfgvariant_checksum_calc
                JBR     off(00232h).2, cfgvariant_check_232h_bits01
                JBR     off(00232h).3, cfgvariant_check_232h_bits01
                CAL     cfgvariant_state_reset
                ANDB    off(00232h), #0f3h
cfgvariant_check_232h_bits01:     JBR     off(00232h).0, restore_trapstate_after_ramclear
                JBR     off(00232h).1, restore_trapstate_after_ramclear
                J       cfgvariant_check_232h_bits01_call_cfgvariant_ram_init_0x
                DW  00000h
restore_trapstate_after_ramclear:     MOV     LRB, #00010h
                MB      C, off(0009fh).0
                MB      r0.0, C
                MB      C, off(0009fh).1
                MB      r0.1, C
                MOVB    r1, off(000e7h)
                MOVB    r2, off(000ech)
                MOVB    r3, off(000ebh)
                CLR     A
                MOV     USP, #00354h
                MOV     DP, #00480h
ram_clear_loop2:     DEC     DP
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
clear_0x324_high_nibble:     MOV     DP, #00320h
                LB      A, [DP]
                ANDB    A, #0f0h
                STB     A, [DP]
                MB      C, r0.0
                MB      off(0009fh).0, C
                MB      C, r0.1
                MB      off(0009fh).1, C
                MOVB    off(000e7h), r1
                MOVB    off(000ech), r2
                MOVB    off(000ebh), r3
                MOV     LRB, #00041h
                SC
                LB      A, 0e7h
                JNE     fuelpump_prime_check
                MOVB    off(002bch), #014h
                RC
fuelpump_prime_check:     MB      off(00230h).5, C
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
adc_wait_loop:     MB      r0.0, C
                JRNZ    DP, adc_wait_loop
                CAL     idle_helper1
                LB      A, P2
                ANDB    A, #0e0h
                JNE     adc_wait_loop
                MOVB    0edh, #001h
                CAL     selftest_reason_range_check_entry
                L       A, ADCR4
                ST      A, 0cch
                LB      A, ADCR2H
                STB     A, 0c5h
                MOV     DP, #003d2h
                STB     A, [DP]
                MOV     DP, #003beh
                LB      A, [DP]
                STB     A, 0c2h
                MOV     DP, #003c5h
                LB      A, [DP]
                STB     A, 0c3h
                MOVB    0c0h, #057h
                MOVB    0c1h, #03bh
                MOVB    0a4h, #0f9h
                LB      A, #025h
                STB     A, 0c4h
                STB     A, 0f7h
                L       A, ADCR6
                ST      A, 0a2h
                LB      A, ACCH
                STB     A, off(00234h)
                LB      A, #0a0h
                STB     A, off(00235h)
                STB     A, (0012ch-00180h)[USP]
                STB     A, 0a5h
                MOV     DP, #00372h
                STB     A, [DP]
                INC     DP
                STB     A, [DP]
                L       A, #04d00h
                ST      A, 0b8h
                ST      A, 0bah
                ST      A, er0
                SLL     A
                JLT     clamp_to_0xff
                SLL     A
                LB      A, ACCH
                JGE     clamp_result_store
clamp_to_0xff:     LB      A, #0ffh
clamp_result_store:     STB     A, 0bch
                LB      A, r1
                STB     A, 0bbh
                CAL     boot_completion_helper
                SB      off(00231h).5
                MOV     0b6h, #0ffffh
                SB      off(00231h).3
                MOV     0c8h, #000e1h
                MOV     0cah, #0091fh
                L       A, #00001h
                ST      A, (001bch-00180h)[USP]
                ST      A, (001bah-00180h)[USP]
                ST      A, (001b8h-00180h)[USP]
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                LB      A, #00fh
                STB     A, (001bfh-00180h)[USP]
                STB     A, (001b7h-00180h)[USP]
                MOVB    0e6h, #031h
                MOV     0e4h, #0ffffh
                MOVB    off(002f4h), #0ffh
                MOV     DP, #003c8h
                LB      A, [DP]
                STB     A, off(002a5h)
                CAL     ect_step_helper
                CLRB    A
                MOV     DP, #001a9h
clamp_result_store_rom_load_tbl_6ab3_dp:     LCB     A, clamp_result_store_tbl[DP]
                STB     A, [DP]
                INC     DP
                CMP     DP, #001b6h
                JNE     clamp_result_store_rom_load_tbl_6ab3_dp
                MOVB    off(002ebh), #0ffh
                MOVB    off(002e4h), #0f9h
                MOVB    off(002aeh), #002h
                MOVB    off(002b2h), #002h
                MOVB    off(002a3h), #053h
                MOV     DP, #00310h
                LB      A, [DP]
                MOVB    ACC, #07bh
                JNE     serial_baud_store_common
                INC     DP
                STB     A, [DP]
serial_baud_store_common:     STB     A, off(002a4h)
                SB      off(00225h).1
                CMPB    0ebh, #047h
                JEQ     serial_baud_select_done
                MOV     DP, #00312h
                L       A, #00332h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOV     DP, #00352h
                MOVB    [DP], #03bh
serial_baud_select_done:     MOVB    off(002b6h), #032h
                NOP
                NOP
                NOP
                NOP
                MOVB    r0, #01ch
                MOVB    r1, #08ch
                LB      A, #0dfh
                MOV     DP, #00354h
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
                STB     A, (00111h-00180h)[USP]
                CLR     A
                MOV     DP, #003fch
                LC      A, 00038h
                ST      A, [DP]
                INC     DP
                INC     DP
                LC      A, 0003ah
                ST      A, [DP]
                CLRB    0ebh
                J       stack_sanity_check
vcal_4:         NOP
                NOP
                NOP
                MOV     DP, #00354h
                MB      C, [DP].1
                JLT     vcal_4_load_dp
                J       background_task_scheduler
vcal_4_load_dp:     MOV     DP, #00354h
                RB      [DP].7
                JNE     vcal_4_load_dp_2
                J       background_task_scheduler
vcal_4_load_dp_2:     MOV     DP, #00379h
                LB      A, [DP]
                CMPB    A, #020h
                JNE     vcal_4_cmp_acc
                L       A, 0ach
                MOV     DP, #0038eh
                ST      A, [DP]
                MOV     DP, #003d4h
                L       A, [DP]
                MOV     DP, #00390h
                ST      A, [DP]
                MOV     DP, #0037ch
                LB      A, [DP]
                ADDB    A, #003h
                J       vcal_4_load_dp_4
vcal_4_cmp_acc:     CMPB    A, #030h
                JLT     vcal_4_cmp_acc_2
                CMPB    A, #036h
                JGT     vcal_4_cmp_acc_2
                CMPB    A, #030h
                JEQ     vcal_4_clear_acc
                JBR     off(00210h).7, vcal_4_clear_acc
                MOV     DP, #00378h
                CMPB    A, [DP]
                JNE     vcal_4_cmp_ram2e6
                MOV     DP, #0039bh
                STB     A, [DP]
vcal_4_load_imm:     LB      A, #028h
                SJ      vcal_4_store_ram2e6
vcal_4_cmp_ram2e6:     CMPB    off(002e6h), #000h
                JNE     vcal_4_load_imm
vcal_4_clear_acc:     CLRB    A
                MOV     DP, #0039bh
                STB     A, [DP]
vcal_4_store_ram2e6:     STB     A, off(002e6h)
                SJ      vcal_4_load_imm_2
vcal_4_cmp_acc_2:     CMPB    A, #021h
                JNE     background_task_scheduler
                MOV     DP, #0037bh
                LB      A, [DP]
                SRLB    A
                JGE     vcal_4_load_dp_3
                CLR     A
                ST      A, (00112h-00180h)[USP]
                ST      A, (00114h-00180h)[USP]
                ST      A, off(00212h)
                ST      A, off(00214h)
                RB      off(0021ah).1
                ST      A, 098h
                ST      A, 09ah
                ST      A, 09ch
                CLRB    A
                STB     A, 0eah
                STB     A, off(002a7h)
                STB     A, off(002a8h)
                MOV     DP, #001a9h
vcal_4_rom_load_tbl_6ab3_dp:     LCB     A, clamp_result_store_tbl[DP]
                STB     A, [DP]
                INC     DP
                CMP     DP, #001b6h
                JNE     vcal_4_rom_load_tbl_6ab3_dp
                RB      off(00218h).5
                RB      off(00218h).6
                SB      off(00232h).2
                SB      off(00232h).3
                CAL     cfgvariant_state_reset
                RB      off(00232h).2
                RB      off(00232h).3
vcal_4_load_dp_3:     MOV     DP, #0037bh
                LB      A, [DP]
                SRLB    A
                SRLB    A
                JGE     vcal_4_load_imm_2
                SB      off(00232h).0
                SB      off(00232h).1
                CAL     cfgvariant_ram_init_0x300
                RB      off(00232h).0
                RB      off(00232h).1
vcal_4_load_imm_2:     LB      A, #003h
vcal_4_load_dp_4:     MOV     DP, #0037ah
                STB     A, [DP]
                MOV     DP, #00354h
                SB      [DP].6
                MOV     DP, #0037dh
                LB      A, #002h
                STB     A, [DP]
                MOV     DP, #00379h
                LB      A, [DP]
                ANDB    A, #01fh
                MOV     DP, #0037eh
                STB     A, [DP]
                SJ      vcal_4_store_stbuf
                DB  000h,000h,000h,000h
vcal_4_store_stbuf:     STB     A, STBUF
; [CG] background_task_scheduler  @0x2686
; [CG] TRACED: manages an IE interrupt-mask cycle counter (RAM 0xCE), runs housekeeping
; [CG] (ResetWatchDog + decrement_timer_array x3), runs a divide-by-10 slow-tick generator
; [CG] that raises off(231h).1/.2 for the two periodic decay tasks, then dispatches - by
; [CG] unconditional JUMP, not CALL - to exactly one of five subsystem tasks per invocation
; [CG] based on a priority-ordered chain of flag tests (off 09Eh.6/.4, off(227h).2,
; [CG] off(216h).3, off(231h).0/.1/.2). Reached via VCAL 4, 199 call sites' worth of VCAL
; [CG] usage total across the ROM makes this the busiest entry point in the firmware.
background_task_scheduler:     L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                LB      A, 0ceh
                SUBB    A, #005h
                JLT     vcal3_leanprotect_ratelimit
                STB     A, 0ceh
vcal3_leanprotect_ratelimit:     SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                JGE     vcal3_main_task
                J       vcal3_leanprotect_ratelimit_clear_stk
vcal3_leanprotect_ratelimit_clear_ram09e_bit6:     RB      09eh.6
                JEQ     vcal3_leanprotect_ratelimit_clear_ram09e_bit4
                J       vcal3_leanprotect_ratelimit_load_adcr3h
vcal3_leanprotect_ratelimit_clear_ram09e_bit4:     RB      09eh.4
                JEQ     vcal3_leanprotect_ratelimit_if_ram227_bit2_set
                JBR     off(0022bh).0, vcal3_task_a
                RB      off(00231h).0
                JNE     vcal3_task_a
                RT
vcal3_task_a:     J       battery_voltage_check
vcal3_leanprotect_ratelimit_if_ram227_bit2_set:     JBS     off(00227h).2, vcal3_dispatch_check1
                JBR     off(00216h).3, vcal3_dispatch_check1
                RB      09eh.3
                JEQ     vcal3_dispatch_check1
                J       ignition_timing_calc_task
vcal3_dispatch_check1:     RB      off(00231h).1
                JEQ     vcal3_dispatch_check2
                J       periodic_decay_task_1
vcal3_dispatch_check2:     RB      off(00231h).2
                JNE     vcal3_task_b
                RT
vcal3_task_b:     J       vcal3_task_b_body
vcal3_main_task:     CAL     ResetWatchDog
                MOV     DP, #0000ah
                MOV     X1, #0019fh
                CAL     decrement_timer_array
                MOV     DP, #0000bh
                MOV     X1, #002dfh
                CAL     decrement_timer_array
                MOV     DP, #00001h
                MOV     X1, #0037fh
                CAL     decrement_timer_array
                LB      A, off(002e6h)
                JNE     scheduler_slowflag_check
                MOV     DP, #0039bh
                STB     A, [DP]
scheduler_slowflag_check:     CLR     A
                LB      A, off(002e4h)
                JNE     scheduler_divider_check
                LB      A, #0fah
                STB     A, off(002e4h)
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
                NOP
                NOP
                L       A, off(00214h)
                AND     A, #00320h
                JNE     scheduler_gate_common
                L       A, off(00212h)
                AND     A, #001bch
                JNE     scheduler_gate_common
                JBR     off(0021ah).6, scheduler_gate_common
                JBS     off(0021ah).7, scheduler_gate_common
                LB      A, 0c1h
                CMPB    A, #00ch
                JLE     scheduler_ect_sign_check
                CMPB    A, #0d0h
                JGE     scheduler_ect_sign_check
                RB      off(00223h).6
                XORB    P0, #040h
                SJ      scheduler_task_done
scheduler_gate_common:     SB      P0.6
                SB      off(00223h).6
                SJ      scheduler_task_done
scheduler_ect_sign_check:     RB      P0.6
                RB      off(00223h).6
scheduler_task_done:     MOV     DP, #000b6h
                JBS     off(00214h).0, vss_calc_skip
                RB      09eh.2
                JEQ     vss_calc_gate2
                JBS     off(00217h).5, vss_calc_gate3
                CMPB    0c3h, #044h
                JLT     vss_calc_skip
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                MOVB    r0, 0dah
                L       A, 0d8h
                SUB     A, 0dch
                ST      A, er1
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                SBCB    r0, #000h
                SRLB    r0
                L       A, er1
                ROR     A
                CMPB    r0, #000h
                JNE     vss_calc_gate3
                RB      off(00231h).3
                JNE     vss_calc_gate2_if_ram231_bit3_set
                RB      off(00231h).4
                JNE     vss_calc_gate2_if_ram231_bit3_set
                CMP     A, #00373h
                MB      off(00231h).4, C
                JLT     vss_calc_gate2_if_ram231_bit3_set
                CMP     A, #0397dh
                JGE     vss_result_store
                MOV     er0, #01000h
                CMP     A, #005c0h
                JLT     vss_scale_apply
                MOV     er0, #04000h
vss_scale_apply:     CAL     mul_scale_helper2
vss_result_store:     ST      A, [DP]
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
vss_clamp_max:     MOVB    r2, #0ffh
vss_clamp_common:     LB      A, r2
vss_final_store:     STB     A, r2
                MOVB    r3, 0b4h
                L       A, er1
                ST      A, 0b4h
                SJ      vss_calc_gate2_if_ram231_bit3_set
vss_calc_skip:     L       A, #vss_calc_skip_tbl
                RB      off(00231h).3
                SJ      vss_result_store
vss_calc_gate2:     LB      A, #003h
                CMPB    0dbh, A
                JLT     vss_calc_gate2_if_ram231_bit3_set
                STB     A, 0dbh
vss_calc_gate3:     RB      off(00231h).4
                SB      off(00231h).3
                MOV     [DP], #0ffffh
                CLRB    A
                SJ      vss_final_store
vss_calc_gate2_if_ram231_bit3_set:     JBS     off(00231h).3, vss_calc_gate2_if_ram227_bit6_clr
                MOVB    off(002e5h), #008h
vss_calc_gate2_if_ram227_bit6_clr:     JBR     off(00227h).6, idle_gate1_clear
                JBS     off(00214h).7, idle_gate1_clear
                MOV     DP, #00f00h
                MB      C, [DP].2
                RB      off(00232h).6
                MB      off(00232h).6, C
                JEQ     idle_gate1
                XORB    PSWH, #080h
idle_gate1:     JGE     idle_gate1_timer_check
                CMPB    0adh, #00dh
                JGT     idle_gate1_trigger
                JBS     off(00233h).7, idle_gate1_timer_check
idle_gate1_trigger:     MOVB    off(002e8h), #00ah
idle_gate1_clear:     RC
                SJ      dtc24_code24_latch
idle_gate1_timer_check:     LB      A, off(002e8h)
                JNE     idle_gate1_clear
                SC
dtc24_code24_latch:     MB      09ah.3, C
                J       idle_init_start_clear_stk
idle_init_start_load_er0:     MOV     er0, off(002ech)
                CLR     A
                LB      A, #040h
                MUL
                MOV     X1, A
                MOV     DP, #00020h
                MOVB    r0, off(002eah)
idle_init_start_rom_load_tbl_x1:     LC      A, [X1]
                ADDB    A, ACCH
                ADDB    r0, A
                INC     X1
                INC     X1
                JRNZ    DP, idle_init_start_rom_load_tbl_x1
                LB      A, r0
                STB     A, off(002eah)
                INC     off(002ech)
                CMP     off(002ech), #00200h
                JNE     idle_mode_gate2
                CLR     off(002ech)
                LB      A, r0
                JEQ     idle_mode_gate2
                CLRB    off(002eah)
                LCB     A, idle_init_start_tbl
                JNE     idle_mode_gate2
                MOVB    0ebh, #048h
                J       fault_giveup_latch
idle_mode_gate2:     JBR     off(002e4h).0, idle_mode_gate2_load_ram0c8
                J       transit_flag_check
idle_mode_gate2_load_ram0c8:     L       A, 0c8h
                MOV     X1, #tbl_idle_dc
                CAL     table_interp_lookup_4byte
                MOV     er0, 0cch
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_dc_result_store
                L       A, #0ffffh
idle_dc_result_store:     MOV     DP, #003ceh
                ST      A, [DP]
                MOV     er3, off(0028ah)
                SUB     A, off(0025ah)
                MB      r4.0, C
                JEQ     idle_delta_flag_set
                RB      off(0022ah).5
                MB      off(0022ah).5, C
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
                L       A, #00580h
                CAL     idle_helper2
                MOV     DP, A
                L       A, #000f0h
                CAL     idle_helper2
                XCHG    A, 0c8h
                ST      A, er0
                CLRB    A
                JLT     idle_step_default_store_ram2bd
                L       A, DP
                ST      A, off(0028ah)
                L       A, er0
                CMP     A, 0c8h
                JEQ     idle_step_default
                JBR     off(0020ch).1, idle_debounce_gate
idle_step_default:     LB      A, #00ah
idle_step_default_store_ram2bd:     STB     A, off(002bdh)
idle_debounce_gate:     MB      C, 09fh.1
                JLT     idle_debounce_disabled
                JBR     off(00230h).2, idle_debounce_skip
                MOV     DP, #01f00h
                AND     IE, #002a0h
                RB      PSWH.0
                LB      A, P0
                STB     A, [DP]
                STB     A, r0
                MOVB    r1, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                LB      A, r1
                CMPB    A, r0
                JNE     idle_port_p1_check
                MOV     DP, #02f00h
                AND     IE, #002a0h
                RB      PSWH.0
                LB      A, P1
                STB     A, [DP]
                STB     A, r0
                MOVB    r1, [DP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                LB      A, r1
                CMPB    A, r0
                JNE     idle_port_p1_check
                MOV     DP, #00f00h
                LB      A, [DP]
                XORB    A, #038h
                AND     IE, #002a0h
                RB      PSWH.0
                STB     A, off(00210h)
                STB     A, (00110h-00180h)[USP]
                SB      PSWH.0
                SJ      idle_debounce_ie_restore
idle_port_p1_check:     LB      A, #04dh
                STB     A, 0e7h
                DECB    0edh
                JNE     idle_debounce_skip
                STB     A, 0ebh
                CLRB    0ech
                J       fault_retry_check
idle_debounce_skip:     AND     IE, #002a0h
                RB      PSWH.0
                CAL     port_debounce_helper
                SB      PSWH.0
idle_debounce_ie_restore:     L       A, 0f2h
                ST      A, IE
idle_debounce_disabled:     MOV     DP, #04700h
                LB      A, [DP]
                XORB    A, #01ah
                MB      C, off(00211h).4
                AND     IE, #002a0h
                RB      PSWH.0
                STB     A, off(00211h)
                STB     A, (00111h-00180h)[USP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                JGE     idle_debounce_return
                JBS     off(00211h).4, idle_debounce_return
                MOVB    off(002d6h), #00fh
idle_debounce_return:     RT
; [CG] transit_flag_check  @0x2964
; [CG] TRACED: dispatch-adjacent task in the same background_task_scheduler region. Tests
; [CG] TRNSIT (edge-detect SFR) bit 3, conditionally decrements a counter at RAM 0x2EB.
transit_flag_check:     LB      A, #0ffh
                RB      TRNSIT.3
                JNE     transit_flag_common
                SC
                LB      A, off(002ebh)
                JEQ     transit_flag_store
                SUBB    A, #001h
transit_flag_common:     RC
transit_flag_store:     MB      off(00230h).6, C
                STB     A, off(002ebh)
                JBR     off(002e4h).1, transit_gate_check
                RT
; [CG] transit_gate_check  @0x297C
; [CG] TRACED: reads RAM 0xC4 (unnamed byte), tests off(214h).3 and SFR bit 099h.7, compares
; [CG] the periodic counter at RAM 0xE9 (the same counter periodic_decay_task_1 increments)
; [CG] against 50, and on threshold calls mul_scale_helper2 with the tiny table at 0x6000
; [CG] before setting the slow-tick flag off(231h).0. Dispatch target from
; [CG] background_task_scheduler, sandwiched between other tasks.
transit_gate_check:     MOV     DP, #000f6h
                LB      A, 0c4h
                STB     A, ACCH
                CLRB    A
                JBS     off(00214h).3, idle_scratch_store
                MB      C, 099h.7
                JLT     idle_task_done
                CMPB    0e9h, #032h
                JGE     idle_scratch_scale
idle_scratch_store:     MOV     [DP], A
                SJ      idle_task_done
idle_scratch_scale:     MOV     er0, #tbl_idle_pi_clamp
                CAL     mul_scale_helper2
idle_task_done:     SB      off(00231h).0
                RT
vcal3_leanprotect_ratelimit_load_adcr3h:     LB      A, ADCR3H
                STB     A, off(002f5h)
                STB     A, r0
                RC
                JBS     off(00213h).3, dtc12_egr_latch
                CMPB    off(00236h), #000h
                MB      off(00226h).7, C
                JGE     dtc12_egr_latch
                LB      A, #0ffh
                CMPB    A, r0
dtc12_egr_latch:     MB      099h.0, C
                JBS     off(00213h).3, vcal3_leanprotect_ratelimit_load_r0
                LB      A, #0ffh
                JGE     vcal3_leanprotect_ratelimit_if_ram21c_bit7_set
                STB     A, off(002dah)
                SJ      vcal3_leanprotect_ratelimit_load_ram2db
vcal3_leanprotect_ratelimit_if_ram21c_bit7_set:     JBS     off(0021ch).7, vcal3_leanprotect_ratelimit_store_ram2da
                CMPB    off(002f3h), #000h
                JEQ     vcal3_leanprotect_ratelimit_load_ram2da
vcal3_leanprotect_ratelimit_store_ram2da:     STB     A, off(002dah)
vcal3_leanprotect_ratelimit_load_ram2da:     LB      A, off(002dah)
                JNE     vcal3_leanprotect_ratelimit_load_r0
                LB      A, #0ffh
                CMPB    A, r0
                JLT     vcal3_leanprotect_ratelimit_store_ram2f4
                LB      A, #0ffh
                CMPB    A, r0
                JGE     vcal3_leanprotect_ratelimit_store_ram2f4
                LB      A, r0
vcal3_leanprotect_ratelimit_store_ram2f4:     STB     A, off(002f4h)
vcal3_leanprotect_ratelimit_load_r0:     LB      A, r0
                SUBB    A, off(002f4h)
                JGE     vcal3_leanprotect_ratelimit_store_ram2f2
                CLRB    A
vcal3_leanprotect_ratelimit_store_ram2f2:     STB     A, off(002f2h)
                J       vcal3_leanprotect_ratelimit_if_ram213_bit3_set
vcal3_leanprotect_ratelimit_subb_acc:     SUBB    A, off(002f3h)
                JGE     vcal3_leanprotect_ratelimit_clear_ram226_bit6
                VCAL    7
                SC
vcal3_leanprotect_ratelimit_clear_ram226_bit6:     RB      off(00226h).6
                MB      off(00226h).6, C
                JEQ     vcal3_leanprotect_ratelimit_if_lt_goto_2a17
                XORB    PSWH, #080h
vcal3_leanprotect_ratelimit_if_lt_goto_2a17:     JLT     vcal3_leanprotect_ratelimit_load_ram2db
                CMPB    A, #006h
                JLE     vcal3_leanprotect_ratelimit_load_ram2db
                JBR     off(00226h).7, vcal3_leanprotect_ratelimit_load_ram2db
                CMPB    0c3h, #0ffh
                JLT     vcal3_leanprotect_ratelimit_load_ram2db
                CMPB    0a6h, #030h
                JLT     vcal3_leanprotect_ratelimit_load_ram2db
                CMPB    off(002f3h), #018h
                JGE     vcal3_leanprotect_ratelimit_load_ram2db_2
vcal3_leanprotect_ratelimit_load_ram2db:     MOVB    off(002dbh), #032h
vcal3_leanprotect_ratelimit_clear_carry:     RC
                SJ      dtc12_egr_latch_2
vcal3_leanprotect_ratelimit_load_ram2db_2:     LB      A, off(002dbh)
                JNE     vcal3_leanprotect_ratelimit_clear_carry
                SC
dtc12_egr_latch_2:     MB      099h.1, C
                CLR     A
                MOV     DP, A
                ST      A, er0
                RC
                LB      A, off(002f3h)
                JEQ     vcal3_leanprotect_ratelimit_load_ram2f8
                L       A, off(002f6h)
                JNE     vcal3_leanprotect_ratelimit_store_er3
                L       A, #09fffh
vcal3_leanprotect_ratelimit_store_er3:     ST      A, er3
                LB      A, off(002f2h)
                SUBB    A, off(002f3h)
                MB      r4.0, C
                JGE     vcal3_leanprotect_ratelimit_store_r0
                VCAL    7
vcal3_leanprotect_ratelimit_store_r0:     STB     A, r0
                L       A, #09fffh
                MOV     X1, #09fffh
                MOV     X2, #09fffh
                CAL     mul_then_clamp_x1x2_2
                MOV     DP, A
                L       A, #09fffh
                CAL     mul_then_clamp_x1x2_2
vcal3_leanprotect_ratelimit_load_ram2f8:     MOV     off(002f8h), A
                JLT     vcal3_leanprotect_ratelimit_load_ram2f8_2
                MOV     off(002f6h), DP
vcal3_leanprotect_ratelimit_load_ram2f8_2:     L       A, off(002f8h)
                MOV     er0, #00050h
                MUL
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                L       A, ACC
                JNE     vcal3_leanprotect_ratelimit_vcal_7
                L       A, #00001h
vcal3_leanprotect_ratelimit_vcal_7:     VCAL    7
                AND     IE, #002a0h
                RB      PSWH.0
                ST      A, 0e4h
                LB      A, #031h
                SUBB    A, r2
                STB     A, 0e6h
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                RT
battery_voltage_check:     MB      C, off(0022bh).2
                MB      off(0022bh).3, C
                CLRB    A
                MB      C, off(0021ah).5
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
                LB      A, #005h
                JBS     off(0021ah).3, battery_voltage_check_cmp_acc
                LB      A, #006h
battery_voltage_check_cmp_acc:     CMPB    A, 0b4h
                J       battery_voltage_check_store_carry_ram21a_bit3
battery_voltage_store_load_x1:     MOV     X1, #battery_voltage_store_tbl
                MOV     DP, #0022ah
                MOVB    r2, 0c5h
                MOV     er0, #00100h
                RB      PSWL.4
                CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, off(00236h)
                CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, 0f7h
                SB      PSWL.4
                J       battery_voltage_store_call_timer_or_counter_helper
battery_voltage_store_set_carry:     SC
                L       A, off(00212h)
                AND     A, #02054h
                JNE     freezeframe_flag_225_7
                JBS     off(00214h).0, freezeframe_flag_225_7
                RC
freezeframe_flag_225_7:     MB      off(0022bh).4, C
                MB      C, off(0021ah).0
                MB      off(00223h).5, C
                JBS     off(0022bh).4, freezeframe_flag_225_7_set_carry
                MB      C, 098h.1
                JLT     freezeframe_flag_225_7_set_carry
                JBS     off(00212h).5, freezeframe_flag_225_7_set_carry
                JBR     off(00217h).5, freezeframe_flag_225_7_if_ram216_bit3_clr
                CMPB    0c0h, #030h
                MB      off(0022ah).6, C
                RC
                SJ      freezeframe_flag_225_7_store_carry_ram21a_bit0
freezeframe_flag_225_7_if_ram216_bit3_clr:     JBR     off(00216h).3, freezeframe_flag_225_7_if_ram21a_bit3_set
                JBR     off(00211h).5, freezeframe_flag_225_7_set_carry
freezeframe_flag_225_7_if_ram21a_bit3_set:     JBS     off(0021ah).3, freezeframe_flag_225_7_set_carry
                CMPB    off(00236h), #080h
                JGE     freezeframe_flag_225_7_set_carry
                LB      A, #0feh
                JBR     off(0022ah).6, freezeframe_flag_225_7_cmp_acc
                LB      A, #0feh
freezeframe_flag_225_7_cmp_acc:     CMPB    A, 0e9h
                JGE     freezeframe_flag_225_7_load_x1
                CMPB    0c1h, #03bh
                JGE     freezeframe_flag_225_7_load_x1
freezeframe_flag_225_7_set_carry:     SC
freezeframe_flag_225_7_store_carry_ram21a_bit0:     MB      off(0021ah).0, C
freezeframe_flag_225_7_load_x1:     MOV     X1, #ZoneIndexTable1_SetA
                MOV     X2, #ZoneIndexTable2_SetA
                JBS     off(00216h).3, freezeframe_flag_225_7_load_ram0c1
                MOV     X1, #ZoneIndexTable1_SetB
                MOV     X2, #ZoneIndexTable2_SetB
freezeframe_flag_225_7_load_ram0c1:     LB      A, 0c1h
                VCAL    1
                STB     A, off(00276h)
                MOV     X1, X2
                LB      A, 0c1h
                VCAL    1
                STB     A, off(00278h)
                LB      A, 0c1h
                STB     A, r0
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                MOV     X1, #IdleVsECT
                MOV     X2, #freezeframe_flag_225_7_tbl
                MOVB    r2, #034h
                CMPB    A, #016h
                JGE     idle_ectvs_check2
idle_ectvs_result1_load_r1:     MOVB    r1, r2
                L       A, #0090bh
                MOV     er3, #00480h
                SJ      idle_target_correction_start
idle_ectvs_check2:     CMPB    A, r2
                JGE     idle_ectvs_result3
                MOVB    r1, #030h
                J       cfg_selector3_dispatch
cfg_selector3_dispatch_goto_5802:     J       cfg_selector3_dispatch_cmp_ram280
                DW  00000h
cfg_selector3_dispatch_if_ge_goto_idle_ectvs_result3:     JGE     idle_ectvs_result3
idle_ectvs_result2:     L       A, #009c4h
                MOV     er3, #00280h
                SJ      idle_target_correction_start
cfg_selector3_dispatch_goto_idle_ectvs_result1:     J       idle_ectvs_result1
idle_ectvs_result1_cmp_acc:     CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, off(00270h)
                JEQ     idle_ectvs_flag_check
                MOVB    off(002d5h), #01eh
idle_ectvs_flag_check:     LB      A, off(002d5h)
                JNE     idle_ectvs_result2
                J       idle_ectvs_flag_check_if_ram22a_bit4_clr
idle_ectvs_flag_check_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_ectvs_flag_check_load_r1
                MOVB    r1, #02dh
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, #00a77h
                MOV     er3, #00100h
                JBS     off(00211h).5, idle_target_correction_start
idle_ectvs_flag_check_load_r1:     MOVB    r1, #02dh
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, #00a77h
                MOV     er3, #00100h
                JBS     off(00225h).1, idle_target_correction_start
idle_ectvs_result3:     LB      A, r0
                VCAL    1
                CLR     er3
idle_target_correction_start:     MOV     DP, A
                NOP
                L       A, er3
                JEQ     to_idle_step_condition_dispatch
                MOV     X1, #IdleVsECT
                LCB     A, 0000fh[X1]
                MOVB    r4, A
                SUBB    r0, A
                L       A, er3
                JLE     to_idle_step_condition_dispatch
                CLRB    A
                STB     A, r5
                XCHGB   A, r1
                CMPB    A, 0c1h
                JLE     idle_target_correction_done_clear_acc
                J       idle_target_correction_done
idle_target_correction_done_clear_acc:     CLR     A
                NOP
to_idle_step_condition_dispatch:     J       idle_step_flag_store
                DB  000h
idle_step_flag_store_load_ram0c1:     LB      A, 0c1h
                VCAL    0
                STB     A, r2
                MOV     X1, X2
                ADD     X1, #0000eh
                LB      A, 0c1h
                VCAL    0
                STB     A, ACCH
                LB      A, r2
                MOV     off(00292h), A
                L       A, off(00258h)
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
idle_pid_table_select2:     JBS     off(00217h).6, idle_pid_table_lookup
                MOV     X1, #tbl_idle_pid_b
                MOV     X2, #tbl_idle_pid_d
                CMP     A, #00964h
                JLT     idle_pid_table_lookup
                MOV     X1, #tbl_idle_pid_a
                MOV     X2, #tbl_idle_pid_c
idle_pid_table_lookup:     LB      A, off(00236h)
                VCAL    0
                MOVB    r0, 0c5h
                MULB
                L       A, ACC
                ROL     A
                LB      A, ACCH
                JGE     idle_pid_mul_apply
                LB      A, #0ffh
idle_pid_mul_apply:     MOV     X1, X2
                VCAL    1
                J       idle_pid_mul_apply_store_r1
idle_pid_mul_apply_resume:     JGE     idle_pid_er3_store
                MOVB    r1, #040h
                CLRB    r0
                MUL
                L       A, er1
idle_pid_er3_store:     ST      A, er3
                JBS     off(0022bh).4, idle_pid_common
                JBS     off(00211h).2, idle_pid_common
                JBS     off(0022ah).0, idle_pid_common
                LB      A, #028h
                CLRB    r1
                JBS     off(0022bh).5, idle_pid_recheck2
                LB      A, #028h
                MOVB    r1, #000h
idle_pid_recheck2:     MOVB    r2, 0c6h
                MB      C, off(0022bh).5
                J       idle_pid_recheck2_if_ram217_bit6_clr
                DW  00000h
idle_pid_hyst_check_if_ge_goto_idle_pid_common:     JGE     idle_pid_common
                J       idle_pid_hyst_check_load_carry_pswl_bit4
idle_pid_flag_clear:     CLRB    r5
                SJ      idle_pid_diff_calc
idle_pid_common:     L       A, off(00268h)
                XCHG    A, er3
                MOVB    r5, off(00291h)
                CLRB    r4
                MOVB    r1, #030h
                JBS     off(00217h).6, idle_pid_track_call
                MOVB    r1, #030h
idle_pid_track_call:     CLRB    r0
                CAL     rpm_accel_track_helper
                ST      A, er3
idle_pid_diff_calc:     L       A, er3
                SUB     A, off(00268h)
                ST      A, er0
                JGE     idle_pid_diff_clamp
                VCAL    7
idle_pid_diff_clamp:     CMP     A, #00030h
                JBS     off(00217h).6, idle_pid_diff_zero
                CMP     A, #00030h
idle_pid_diff_zero:     CLR     A
                JLT     idle_pid_diff_store
                L       A, er0
idle_pid_diff_store:     ST      A, off(0026ch)
                L       A, off(0026ah)
                SUB     A, #00000h
                JGE     idle_pid_flag_recheck
                CLR     A
idle_pid_flag_recheck:     CMPB    off(00297h), #000h
                JEQ     idle_pid_store_final
                L       A, #00000h
                JBS     off(00217h).6, idle_pid_decrement
                L       A, #00000h
idle_pid_decrement:     DECB    off(00297h)
idle_pid_store_final:     MOV     off(00268h), er3
                ST      A, off(0026ah)
                MOVB    off(00291h), r5
                JBR     off(00226h).4, idle_integrator_check2
                MOV     X1, #ZoneCorrectionRowSelect_SetA
                JBS     off(00216h).3, to_idle_integrator_store
                MOV     X1, #ZoneCorrectionRowSelect_SetB
to_idle_integrator_store:     LB      A, 0c0h
                VCAL    1
                SLLB    A
                MOV     X2, A
                MOV     X1, #ZoneCorrection2DTable
                LB      A, off(00236h)
                VCAL    0
                L       A, ACC
                SWAP
                CLRB    A
                MOV     er0, X2
                MUL
                L       A, off(00266h)
                MOV     DP, #003d0h
                JEQ     idle_integrator_reset
                JBS     off(00267h).7, idle_integrator_reset
                L       A, [DP]
                SUB     A, #00004h
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
idle_integrator_check2:     L       A, off(00266h)
                JEQ     idle_integrator_final_store
                JBR     off(00267h).7, idle_integrator_fault
                ADD     A, #00008h
                JGE     idle_integrator_final_store
                CLR     A
                SJ      idle_integrator_final_store
idle_integrator_fault:     L       A, #00180h
                VCAL    7
idle_integrator_final_store:     ST      A, off(00266h)
                CLR     A
                MOV     DP, A
                JBR     off(00216h).3, to_idle_output_finalize
                J       idle_integrator_final_store_if_ram211_bit5_clr
to_idle_output_finalize:     MOVB    off(002d4h), #014h
                SJ      idle_output_finalize
idle_integrator_final_store_cmp_ram0c1:     CMPB    0c1h, #03ah
                JLT     inc_dp_step_load_ram0c1
                LB      A, off(002d4h)
                JEQ     inc_dp_step
                JBS     off(0021bh).6, idle_integrator_final_store_load_ram264
                CMP     0aeh, #00004h
                JGE     inc_dp_step
idle_integrator_final_store_load_ram264:     L       A, off(00264h)
                JEQ     idle_output_finalize_srl_dp
inc_dp_step:     INC     DP
inc_dp_step_load_ram0c1:     LB      A, 0c1h
                MOV     X1, #inc_dp_step_tbl
                VCAL    1
                MOV     X2, A
                CMPB    0c1h, #034h
                JGE     load_x2_result
                MOV     X1, #inc_dp_step_tbl_2
                L       A, off(00258h)
                CAL     table_interp_lookup_4byte
                CMP     A, X2
                JGE     idle_output_finalize
load_x2_result:     L       A, X2
idle_output_finalize:     ST      A, off(00264h)
idle_output_finalize_srl_dp:     SRL     DP
                MB      off(0022ah).7, C
                CLRB    A
                RC
                JBS     off(00217h).5, idle_pid_result_store
                JBR     off(0022bh).2, idle_pid_gate4
                JBR     off(00210h).3, idle_pid_gate5
                MOV     X1, #00100h
                LB      A, off(00295h)
                JEQ     idle_pid_x1_select
                DECB    off(00295h)
                MOV     X1, #00800h
idle_pid_x1_select:     L       A, X1
                SJ      idle_pid_output_store
idle_pid_gate4:     JBS     off(00210h).3, idle_pid_zero_flag
idle_pid_gate5:     SC
                LB      A, #005h
idle_pid_result_store:     MB      off(0022bh).2, C
                STB     A, off(00295h)
idle_pid_zero_flag:     CLR     A
idle_pid_output_store:     ST      A, off(00270h)
                MOV     X1, #ModeToPageTable
                LB      A, off(00236h)
                VCAL    1
                MOV     DP, A
                MOV     X1, #ModePageTable_SetA
                JBS     off(00216h).3, vcal2_scale_multiply
                MOV     X1, #ModePageTable_SetB
vcal2_scale_multiply:     LB      A, 0bdh
                VCAL    3
                LB      A, off(002e1h)
                MOV     A, off(00262h)
                JNE     idle_sub_gate2
                MOVB    off(002e1h), #003h
                JBR     off(0021ah).3, idle_sub_common
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
idle_sub_gate2:     J       idle_sub_gate2_if_ram216_bit3_set
                DB  000h
idle_sub_alt_path:     L       A, DP
idle_sub_alt_path_store_ram262:     ST      A, off(00262h)
                MOV     X1, #idle_sub_alt_path_tbl_2
                LB      A, 0c1h
                VCAL    0
                STB     A, off(00294h)
                MB      C, off(0022bh).6
                MB      off(0022bh).7, C
                MOV     X1, #idle_sub_alt_path_tbl
                LB      A, 0c1h
                VCAL    0
                CMPB    A, off(00236h)
                MB      off(0022bh).6, C
                JBR     off(0021ah).0, idle_gate6_result
                JLT     idle_gate6_result
                JBR     off(0022bh).7, idle_gate7
                JBS     off(0021bh).7, idle_gate6_result
                MOV     X1, #tbl_idle_gate6
                LB      A, 0c1h
                VCAL    1
                ; warning: had to flip DD
                CMP     A, 0b0h
                JLT     idle_table_lookup2
idle_gate6_result:     MOVB    off(002e0h), off(00294h)
                SJ      idle_flag_zero
idle_gate7:     L       A, off(00260h)
                SUB     A, #00040h
                JLT     idle_flag_zero
                SJ      idle_flag_check3
idle_table_lookup2:     MOV     X1, #idle_table_lookup2_tbl
                LB      A, 0c1h
                VCAL    0
                STB     A, r0
                CLRB    r1
                L       A, 0b0h
                MUL
                MOV     er0, #02000h
                CMP     er1, #00000h
                JNE     idle_clamp_min
                CMP     A, er0
                JLT     idle_flag_check3
idle_clamp_min:     L       A, er0
idle_flag_check3:     CMPB    off(002e0h), #000h
                JNE     idle_flag_store
idle_flag_zero:     CLR     A
idle_flag_store:     ST      A, off(00260h)
                JBR     off(00219h).7, idle_mode_dispatch
                MOV     DP, #0039bh
                MOVB    r0, [DP]
                L       A, #01400h
                CMPB    r0, #033h
                JEQ     idle_gear_select_done
                L       A, #02000h
                CMPB    r0, #034h
                JEQ     idle_gear_select_done
                L       A, #02c00h
                CMPB    r0, #035h
                JEQ     idle_gear_select_done
                L       A, #03fffh
idle_gear_select_done:     L       A, ACC
                J       idle_gear_target_check
idle_mode_dispatch:     JBR     off(00217h).5, idle_mode_dispatch2
                SB      off(00228h).4
                MOV     X1, #ZoneIndexTable3_SetA
                JBS     off(00216h).3, to_idle_vcal5_call
                MOV     X1, #idle_mode_dispatch_tbl
to_idle_vcal5_call:     LB      A, 0c1h
                VCAL    1
                STB     A, off(0027ah)
                SJ      idle_vcal5_call
idle_mode_dispatch2:     JBR     off(00218h).2, idle_mode_dispatch3
                JBR     off(0022ah).2, idle_gear_calc_start
                L       A, #011ebh
                J       idle_gear_target_final
idle_mode_dispatch3:     JBS     off(0021ah).2, idle_mode_dispatch3_if_ram21c_bit4_clr
                CLR     off(00262h)
                JBR     off(00216h).3, carry_set_flag_gate_0b0
                JBS     off(00211h).5, carry_set_flag_gate_0b0
                JBR     off(0022ah).7, carry_set_flag_gate_0b0
                SB      off(00228h).7
                MOV     er3, off(00260h)
                L       A, off(00276h)
                VCAL    6
idle_vcal5_call:     CAL     stub_or_short_helper
                SJ      vcal5_call
idle_mode_dispatch3_if_ram21c_bit4_clr:     JBR     off(0021ch).4, idle_gear_calc_start
                CMPB    0c1h, #02eh
                JGE     idle_gear_calc_start
                CMPB    0b4h, #005h
                JLT     idle_gear_calc_start
                JBR     off(0022ah).1, idle_gear_calc_start
                MOV     X1, #tbl_ve_map_scalar_alt
                LB      A, 0aah
                JBS     off(0021fh).1, idle_mode_dispatch3_vcal_1
                MOV     X1, #tbl_ve_map_scalar
                LB      A, off(00236h)
idle_mode_dispatch3_vcal_1:     VCAL    1
                STB     A, off(00274h)
                JEQ     idle_gear_calc_start
                SB      off(00228h).6
                MOV     DP, #0030ch
                L       A, [DP]
vcal5_call:     VCAL    6
                STB     A, off(0025eh)
                J       idle_stall_check2_if_ram217_bit5_clr
carry_set_flag_gate_0b0:     SC
                JBS     off(0022bh).4, idle_direction_toggle
                JBS     off(00212h).5, idle_direction_toggle
                MB      C, 098h.1
idle_direction_toggle:     XORB    PSWH, #080h
                MB      off(00228h).5, C
idle_gear_calc_start:     CLR     A
                ST      A, er2
                MOV     DP, #0030ch
                MOV     er0, off(00278h)
                MOVB    ACCH, #025h
                MOVB    r5, #099h
                JBR     off(0021ah).0, idle_gear_mul_apply
                MOV     er0, off(00276h)
                MOVB    ACCH, #052h
                MOVB    r5, #090h
                JBR     off(00228h).5, idle_gear_mul_apply
                JBR     off(0021ah).3, idle_gear_mul_apply
                CMPB    0c1h, #034h
                JGE     idle_gear_mul_apply
                J       idle_gear_calc_start_load_dp_ind
idle_gear_mul_apply:     MUL
                SLL     A
                L       A, er1
                J       idle_gear_mul_apply_rol_acc
idle_gear_mul_apply_add_acc:     ADD     A, [DP]
                JGE     idle_gear_clamp_max
idle_gear_clamp:     L       A, #0ffffh
idle_gear_clamp_max:     SUB     A, #00a00h
                JGE     idle_gear_result_store
                CLR     A
idle_gear_result_store:     ST      A, off(0028eh)
                L       A, er2
                MUL
                SLL     A
                L       A, er1
                J       idle_gear_result_store_rol_acc
idle_gear_result_store_add_acc:     ADD     A, #01000h
                JGE     idle_gear2_store
idle_gear2_clamp:     L       A, #0ffffh
idle_gear2_store:     ST      A, off(0028ch)
                MOVB    r0, #030h
                MOV     DP, #tbl_idle_gear2
                JBR     off(00228h).5, idle_timer_gate1
                JBS     off(0021ah).4, idle_timer_gate_common
                MOVB    off(00296h), #028h
                SJ      idle_timer_gate_common
idle_timer_gate1:     J       idle_timer_gate1_if_ram218_bit2_clr
idle_timer_gate1_if_ram21a_bit5_set:     JBS     off(0021ah).5, idle_table_select2
                SJ      idle_timer_store
idle_timer_gate_common:     JBS     off(0021ah).3, idle_table_select2
                JBS     off(0021ah).0, idle_table_select1
                CMPB    0e9h, #032h
                JGE     idle_table_select1
                JBR     off(0021ah).5, idle_timer_store
                MOV     DP, #tbl_idle_timer
                SJ      idle_timer_store
idle_table_select1:     LB      A, off(002d6h)
                JEQ     idle_table_select_default
                MOV     DP, #idle_table_select1_tbl
                SJ      idle_flag_gate
idle_table_select_default:     MOV     DP, #tbl_idle_select_default
                MOV     X1, #tbl_idle_default1
                JBR     off(0021ah).5, idle_table_lookup3
                MOV     X1, #tbl_idle_default2
idle_table_lookup3:     J       idle_table_lookup3_load_ram258
idle_table_lookup3_if_lt_goto_idle_table_lookup4:     JLT     idle_table_lookup4
                MOV     DP, #tbl_idle_lookup3
idle_table_lookup4:     J       idle_table_lookup4_load_x1
idle_table_lookup4_if_ram21a_bit5_clr:     JBR     off(0021ah).5, idle_flag_gate
                CMP     A, 0b2h
                JGE     idle_flag_gate
                LB      A, off(00296h)
                JEQ     idle_flag_gate
                SUBB    A, #001h
                STB     A, r0
idle_table_select2:     MOV     DP, #tbl_idle_select1
idle_timer_store:     MOVB    off(00296h), r0
idle_flag_gate:     J       idle_flag_gate_load_ram2dc
                DB  000h
idle_flag_gate_load_ram289:     MOVB    off(00289h), off(00288h)
                J       idle_flag_gate_set_ram22b_bit1
idle_flag_gate_if_ram228_bit5_set:     JBS     off(00228h).5, idle_flag_gate_if_ram21a_bit4_set
                JBS     off(0021ah).4, idle_mode_gate6_load_ram278
                L       A, off(00276h)
                JBS     off(00223h).5, idle_pi_mul1
                JBR     off(0021ah).0, idle_pi_mul1
                SJ      idle_mode_gate5_goto_5a03
idle_flag_gate_if_ram21a_bit4_set:     JBS     off(0021ah).4, idle_mode_gate6
                J       idle_flag_gate_set_pswl_bit4
idle_mode_gate5:     L       A, off(0027ah)
                SJ      idle_mode_gate5_goto_5a03
idle_mode_gate6:     JBR     off(00216h).3, idle_mode_gate6_if_ram229_bit5_set
                JBS     off(00229h).4, idle_mode_gate6_load_ram278
idle_mode_gate6_if_ram229_bit5_set:     JBS     off(00229h).5, idle_mode_gate6_load_ram278
                J       idle_mode_gate6_if_ram22b_bit3_clr
idle_mode_gate6_if_ram229_bit6_clr:     JBR     off(00229h).6, idle_pi_mul1
idle_mode_gate6_load_ram278:     L       A, off(00278h)
                JBR     off(0021ah).0, idle_mode_gate5_goto_5a03
                L       A, off(00276h)
                J       idle_mode_gate6_if_ram216_bit3_clr
                DB  000h,000h,000h,000h,000h,000h
idle_mode_gate6_store_er3:     ST      A, er3
                CAL     stub_or_short_helper
idle_mode_gate5_vcal_6:     VCAL    6
                SJ      idle_mode_gate5_load_er3
idle_mode_gate5_goto_5a03:     J       idle_mode_gate5_store_er3
                DW  00000h
idle_mode_gate5_load_er3:     MOV     er3, off(00268h)
                VCAL    6
                ST      A, off(00284h)
                ST      A, off(00286h)
                CLRB    A
                STB     A, off(00288h)
                STB     A, off(00289h)
                CLR     A
                ST      A, er1
                ST      A, er2
                MOV     X1, A
                MOV     X2, A
                SJ      idle_vcal4_call
idle_pi_mul1:     MOV     er0, 0b0h
                LC      A, [DP]
                MUL
                L       A, er1
                JBR     off(0021bh).7, idle_pi_mul2
                VCAL    7
idle_pi_mul2:     MOV     X1, A
                MOV     er0, 0b2h
                INC     DP
                INC     DP
                LC      A, [DP]
                MUL
                L       A, er1
                JBR     off(0021ah).5, idle_pi_mul3
                VCAL    7
idle_pi_mul3:     MOV     X2, A
                INC     DP
                INC     DP
                LC      A, [DP]
                MUL
                ST      A, er2
                L       A, off(0026ch)
idle_vcal4_call:     MOV     er3, off(00284h)
                VCAL    5
                LB      A, off(00288h)
                JBS     off(0021ah).5, idle_integrator_sub
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
                VCAL    5
                L       A, X2
                VCAL    5
                CAL     idle_pi_clamp_helper
                JLT     idle_pi_result_common
                MOVB    off(00288h), r5
idle_pi_store_p:     MOV     off(00284h), er1
idle_pi_result_common:     ST      A, er3
                L       A, off(00260h)
                JBS     off(00228h).5, idle_vcal5_call3
                L       A, off(00262h)
idle_vcal5_call3:     VCAL    6
                ST      A, off(0025eh)
                L       A, off(00212h)
                JNE     idle_stall_check2_if_ram217_bit5_clr
                L       A, off(00214h)
                AND     A, #014fdh
                JNE     idle_stall_check2_if_ram217_bit5_clr
                JBR     off(00228h).5, idle_stall_check2_if_ram217_bit5_clr
                JBS     off(0021ah).3, idle_stall_check2_if_ram217_bit5_clr
                J       idle_vcal5_call3_if_ram21a_bit0_clr
idle_vcal5_call3_goto_5b4f:     J       idle_vcal5_call3_load_ram27c
                DB  000h
idle_vcal5_call3_goto_5f09:     J       idle_vcal5_call3_load_ram266
idle_vcal5_call3_cmp_ram0a6:     CMPB    0a6h, #070h
                JLT     idle_stall_check2_if_ram217_bit5_clr
                CMP     0b0h, #00018h
                JGE     idle_stall_check2_if_ram217_bit5_clr
                L       A, #00040h
                JBR     off(0021ah).5, idle_stall_check2
                L       A, #00040h
idle_stall_check2:     CMP     A, 0b2h
                JLT     idle_stall_check2_if_ram217_bit5_clr
                CMPB    0c1h, #067h
                J       idle_stall_check2_if_ge_goto_5a16
                DB  000h
idle_stall_check2_load_x1:     MOV     X1, #tbl_idle_stall
                VCAL    2
                LB      A, #0a8h
                JBS     off(00216h).3, sub_r6_clamp_zero
                LB      A, #0b8h
sub_r6_clamp_zero:     SUBB    A, r6
                JGE     idle_stall_er0_select1
                CLRB    A
idle_stall_er0_select1:     MOV     er0, #00040h
                CMPB    A, 0a6h
                JLT     idle_stall_er0_select2
                MOV     er0, #00010h
idle_stall_er0_select2:     CMPB    0c1h, #028h
                JLT     idle_stall_diff_calc
                MOV     er0, #00001h
idle_stall_diff_calc:     MOV     X1, #0030ch
                J       idle_stall_diff_calc_load_ram284
                DB  000h
idle_stall_diff_calc_if_ge_goto_30bc:     JGE     idle_stall_diff_calc_call_injtimer_bank_calc1
idle_stall_diff_calc_clear_acc:     CLR     A
idle_stall_diff_calc_call_injtimer_bank_calc1:     CAL     injtimer_bank_calc1
                CAL     idle_stall_helper
idle_stall_check2_if_ram217_bit5_clr:     JBR     off(00217h).5, idle_stall_check2_cmp_ram0e8
                LB      A, 0c1h
                MOV     X1, #idle_stall_check2_tbl
                VCAL    1
                SJ      idle_stall_check2_store_ram27c
idle_stall_check2_cmp_ram0e8:     CMPB    0e8h, #00ch
                JGE     idle_stall_check2_clear_acc
                MOV     X1, #idle_stall_check2_tbl_2
                JBR     off(00228h).5, idle_stall_check2_load_x1_2
                LB      A, off(00236h)
                CMPB    A, off(00292h)
                JGE     idle_stall_check2_load_ram0c1
idle_stall_check2_load_x1_2:     MOV     X1, #idle_stall_check2_tbl_3
idle_stall_check2_load_ram0c1:     LB      A, 0c1h
                VCAL    1
                L       A, off(0027ch)
                SUB     A, er3
                JGE     idle_stall_check2_store_ram27c
idle_stall_check2_clear_acc:     CLR     A
idle_stall_check2_store_ram27c:     ST      A, off(0027ch)
                LB      A, 0c0h
                MOV     X1, #idle_stall_check2_tbl_4
                VCAL    1
                STB     A, off(0027eh)
                L       A, off(00264h)
                MOV     er3, off(0026ah)
                VCAL    6
                L       A, off(0026eh)
                VCAL    6
                L       A, off(00270h)
                VCAL    6
                L       A, off(0027eh)
                VCAL    6
                L       A, off(0027ch)
                VCAL    6
                L       A, off(00266h)
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
idle_target_final_store:     ST      A, off(00280h)
                JBS     off(00217h).5, idle_output_gate2
                L       A, off(00212h)
                JNE     idle_target_final_store_load_dp
                L       A, off(00214h)
                AND     A, #014fdh
                JEQ     idle_target_final_store_load_er3
idle_target_final_store_load_dp:     MOV     DP, #0030ch
                CAL     stub_or_short_helper
                ST      A, [DP]
idle_target_final_store_load_er3:     MOV     er3, #00600h
                CAL     stub_or_short_helper
                VCAL    6
                MB      C, 098h.1
                JLT     idle_output_common
                JBS     off(00212h).5, idle_output_common
                MOV     er3, off(00276h)
                J       idle_target_final_store_call_stub_or_short_helper
idle_output_vcal5:     VCAL    6
                JBS     off(0022bh).4, idle_output_common
idle_output_gate2:     L       A, off(0025eh)
                JBS     off(00228h).6, idle_pi_final_calc
                CLR     off(00274h)
                JBS     off(0022bh).1, idle_output_gate3
idle_output_common:     MOV     er3, off(00268h)
                VCAL    6
idle_output_gate3:     MOV     er3, off(00280h)
                XCHG    A, er3
                VCAL    5
idle_pi_final_calc:     MOV     X2, A
                MOV     X1, #idle_pi_final_calc_tbl
                LB      A, 0a4h
                VCAL    2
                STB     A, off(00290h)
                MOV     X1, #idle_pi_final_calc_tbl_3
                JBS     off(00216h).3, idle_pi_final_calc_load_ram0c1
                MOV     X1, #idle_pi_final_calc_tbl_2
idle_pi_final_calc_load_ram0c1:     LB      A, 0c1h
                VCAL    1
                MOV     DP, #0030ch
                ; warning: had to flip DD
                SUB     A, [DP]
                SLL     A
                ST      A, er0
                CLR     A
                JLT     idle_pi_scale_store
                LB      A, off(00290h)
                ANDB    A, #07fh
                STB     A, ACCH
                CLRB    A
                MUL
                L       A, er1
idle_pi_scale_store:     ST      A, off(00272h)
                L       A, X2
                CLRB    r0
                MOVB    r1, off(00290h)
                MUL
                SLL     A
                L       A, er1
                ROL     A
                JGE     idle_pi_result_clamp
                L       A, #0ffffh
idle_pi_result_clamp:     ST      A, er3
                L       A, off(00272h)
                VCAL    6
                L       A, off(00282h)
                VCAL    5
idle_gear_target_check:     JNE     idle_gear_target_clamp
                JBS     off(0021ah).5, idle_gear_target_reset
                SJ      idle_gear_target_store
idle_gear_target_clamp:     MOV     er3, #03fffh
                CMP     A, er3
                JLT     idle_gear_target_store
                L       A, er3
                JBS     off(0021ah).5, idle_gear_target_store
idle_gear_target_reset:     MOV     off(00284h), off(00286h)
                MOVB    off(00288h), off(00289h)
idle_gear_target_store:     ST      A, off(0025ch)
                MOV     X1, #tbl_idle_gear_target
                CAL     table_interp_lookup_4byte
idle_gear_target_final:     ST      A, off(0025ah)
                RB      off(0022bh).1
                MB      C, off(00228h).5
                MB      off(0021ah).4, C
                LB      A, off(00228h)
                ANDB    A, #0f0h
                SWAPB
                STB     A, off(00228h)
                RT
ignition_timing_calc_task:     MOVB    r5, 0b9h
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_task_tbl_2
                VCAL    0
                STB     A, r4
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_task_tbl_3
                VCAL    0
                STB     A, r3
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_task_tbl_4
                VCAL    0
                STB     A, r2
                JBS     off(0022eh).5, ignition_timing_calc_task_cmp_acc
                LB      A, r3
ignition_timing_calc_task_cmp_acc:     CMPB    A, r5
                MB      off(0022eh).5, C
                LB      A, r2
                JBS     off(0022eh).4, ignition_timing_calc_task_subb_acc
                LB      A, r3
ignition_timing_calc_task_subb_acc:     SUBB    A, r4
                J       ignition_timing_calc_task_if_ge_goto_57a2
                DB  000h
ignition_timing_calc_task_load_ram0b4:     LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_task_tbl_5
                VCAL    0
                STB     A, r3
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_task_tbl_6
                VCAL    0
                STB     A, r2
                JBS     off(0022eh).7, ignition_timing_calc_task_cmp_acc_2
                LB      A, r3
ignition_timing_calc_task_cmp_acc_2:     CMPB    A, r5
                MB      off(0022eh).7, C
                LB      A, r2
                JBS     off(0022eh).6, ignition_timing_calc_task_subb_acc_2
                LB      A, r3
ignition_timing_calc_task_subb_acc_2:     SUBB    A, r4
                J       ignition_timing_calc_task_if_ge_goto_57ac
                DB  000h
ignition_timing_calc_task_load_ram0b4_2:     LB      A, 0b4h
                STB     A, r4
                MOV     X1, #ignition_timing_calc_task_tbl_9
                VCAL    0
                STB     A, off(0029fh)
                LB      A, r4
                MOV     X1, #ignition_timing_calc_task_tbl_10
                VCAL    0
                STB     A, off(002a0h)
                CMPB    A, r5
                XORB    PSWH, #080h
                JGE     ignition_timing_calc_task_store_carry_ram22f_bit3
                LB      A, off(0029fh)
                CMPB    A, r5
ignition_timing_calc_task_store_carry_ram22f_bit3:     MB      off(0022fh).3, C
                LB      A, r4
                MOV     X1, #ignition_timing_calc_task_tbl_11
                VCAL    0
                STB     A, off(002a1h)
                LB      A, r4
                MOV     X1, #ignition_timing_calc_task_tbl_12
                VCAL    0
                STB     A, off(002a2h)
                CMPB    A, r5
                XORB    PSWH, #080h
                JGE     ignition_timing_calc_task_store_carry_ram22f_bit4
                LB      A, off(002a1h)
                CMPB    A, r5
ignition_timing_calc_task_store_carry_ram22f_bit4:     MB      off(0022fh).4, C
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_task_tbl_7
                JBS     off(0022eh).3, ignition_timing_calc_task_vcal_0
                MOV     X1, #ignition_timing_calc_task_tbl_8
ignition_timing_calc_task_vcal_0:     VCAL    0
                MOV     DP, #00311h
                ADDB    A, [DP]
                CMPB    A, 0bch
                MB      off(0022eh).3, C
                MOV     DP, #0022ch
                MOV     er0, #00800h
                MOV     X1, #ignition_timing_calc_task_tbl
                MOVB    r2, 0b4h
                RB      PSWL.4
                CAL     timer_or_counter_helper
                INC     DP
                MOV     er0, #00800h
                CAL     timer_or_counter_helper
                INC     DP
                MOV     er0, #00100h
                CAL     timer_or_counter_helper
                MOVB    r1, #001h
                MOVB    r2, off(00236h)
                CAL     timer_or_counter_helper
                MOVB    r1, #001h
                MOVB    r2, 0b9h
                CAL     timer_or_counter_helper
                LB      A, 0b4h
                MOVB    r7, #080h
                JBS     off(00211h).5, ignition_timing_calc_task_load_r7
                JBS     off(00211h).6, ignition_timing_calc_task_if_ram22e_bit2_set
                JBR     off(00211h).7, ignition_timing_calc_task_load_r7
                JBS     off(0022ch).0, ignition_timing_calc_task_clear_r7
ignition_timing_calc_task_if_ram22e_bit2_set:     JBS     off(0022eh).2, ignition_timing_calc_task_load_r7
                JBR     off(0022fh).6, ignition_timing_calc_task_cmp_acc_3
                CMPB    A, #027h
                JLT     ignition_timing_calc_task_load_r7
                MOVB    r7, #040h
                SJ      ignition_timing_calc_task_if_ram22c_bit1_clr
ignition_timing_calc_task_cmp_acc_3:     CMPB    A, #010h
                JLT     ignition_timing_calc_task_load_r7
                MOVB    r7, #040h
                JBS     off(0022fh).7, ignition_timing_calc_task_if_ram22c_bit1_clr
                JBS     off(0022eh).3, ignition_timing_calc_task_if_ram22c_bit1_clr
                CMPB    A, #010h
                JGE     ignition_timing_calc_task_clear_r7
                SJ      ignition_timing_calc_task_load_r7
ignition_timing_calc_task_if_ram22c_bit1_clr:     JBR     off(0022ch).1, ignition_timing_calc_task_load_r7
                JBS     off(00211h).6, ignition_timing_calc_task_load_r7
                JBS     off(0022eh).6, ignition_timing_calc_task_load_r7
ignition_timing_calc_task_clear_r7:     CLRB    r7
ignition_timing_calc_task_load_r7:     LB      A, r7
                SLLB    A
                MB      off(0022fh).6, C
                SLLB    A
                MB      off(0022fh).7, C
                LB      A, off(00214h)
                STB     A, ACCH
                LB      A, off(00212h)
                AND     ACC, #00560h
                JNE     ignition_timing_calc_task_load_ram2ca
                CMPB    0c1h, #03ch
                JGE     ignition_timing_calc_task_load_ram2ca
                JBR     off(0022eh).1, ignition_timing_calc_task_load_ram2ca
                JBS     off(00211h).7, ignition_timing_calc_task_load_ram2cc_2
                JBR     off(00211h).6, ignition_timing_calc_task_load_ram2ca
                JBR     off(0022fh).0, ignition_timing_calc_task_load_ram2cc
                MOVB    off(002c9h), #014h
ignition_timing_calc_task_load_ram2cc:     LB      A, off(002cch)
                JNE     ignition_timing_calc_task_clear_carry
                SJ      ignition_timing_calc_task_load_ram2ca_2
ignition_timing_calc_task_load_ram2ca:     MOVB    off(002cah), #002h
ignition_timing_calc_task_load_ram2ca_2:     LB      A, off(002cah)
                JEQ     ignition_timing_calc_task_if_ram21b_bit6_set
                SJ      ignition_timing_calc_task_clear_carry
ignition_timing_calc_task_load_ram2cc_2:     MOVB    off(002cch), #00ch
                LB      A, off(002c9h)
                JEQ     ignition_timing_calc_task_load_ram2ca_2
ignition_timing_calc_task_if_ram21b_bit6_set:     JBS     off(0021bh).6, ignition_timing_calc_task_load_ram2cb
                CMP     0aeh, #00120h
                JLT     ignition_timing_calc_task_load_ram2cb
                MOVB    off(002cbh), #014h
ignition_timing_calc_task_load_ram2cb:     LB      A, off(002cbh)
                JNE     ignition_timing_calc_task_clear_carry
                JBS     off(0022eh).3, ignition_timing_calc_task_if_ram211_bit6_set
                JBS     off(0022fh).6, ignition_timing_calc_task_clear_carry
                MB      C, off(0022dh).6
                JBS     off(0022fh).7, ignition_timing_calc_task_if_ge_goto_3350
                MB      C, off(0022dh).7
ignition_timing_calc_task_if_ge_goto_3350:     JGE     ignition_timing_calc_task_clear_carry
                JBS     off(0022eh).0, ignition_timing_calc_task_clear_carry
                LB      A, off(002e5h)
                JEQ     ignition_timing_calc_task_clear_carry
                JBS     off(0021ch).3, ignition_timing_calc_task_if_ram22f_bit0_set
ignition_timing_calc_task_clear_carry:     RC
                SJ      ignition_timing_calc_task_store_carry_ram22f_bit0
ignition_timing_calc_task_if_ram211_bit6_set:     JBS     off(00211h).6, ignition_timing_calc_task_if_ram22c_bit2_set
                JBS     off(0022ch).4, ignition_timing_calc_task_if_ram22f_bit0_set
                JBR     off(0022ch).5, ignition_timing_calc_task_load_ram2cd
                JBR     off(0022eh).7, ignition_timing_calc_task_load_ram2cd_2
ignition_timing_calc_task_load_ram2cd:     MOVB    off(002cdh), #014h
                SJ      ignition_timing_calc_task_load_ram2cd_2
ignition_timing_calc_task_if_ram22c_bit2_set:     JBS     off(0022ch).2, ignition_timing_calc_task_if_ram22f_bit0_set
                JBR     off(0022ch).3, ignition_timing_calc_task_load_ram2cd
                JBS     off(0022eh).5, ignition_timing_calc_task_load_ram2cd
ignition_timing_calc_task_load_ram2cd_2:     LB      A, off(002cdh)
                JNE     ignition_timing_calc_task_clear_carry
ignition_timing_calc_task_if_ram22f_bit0_set:     JBS     off(0022fh).0, ignition_timing_calc_task_set_carry
                J       ignition_timing_calc_task_load_ram0bd
                DB  000h
ignition_timing_calc_task_if_le_goto_337f:     JLE     ignition_timing_calc_task_load_ram2d2_2
ignition_timing_calc_task_load_ram2d2:     MOVB    off(002d2h), #002h
ignition_timing_calc_task_load_ram2d2_2:     LB      A, off(002d2h)
                JNE     ignition_timing_calc_task_clear_carry
ignition_timing_calc_task_set_carry:     SC
ignition_timing_calc_task_store_carry_ram22f_bit0:     MB      off(0022fh).0, C
                MB      P0.4, C
                CMPB    0c0h, #0e1h
                JGE     ignition_timing_calc_task_load_imm
                CMPB    0c1h, #02eh
                JLT     ignition_timing_calc_task_if_ram22d_bit0_set
ignition_timing_calc_task_load_imm:     LB      A, #00ch
                STB     A, off(002b0h)
                STB     A, off(0029eh)
                SJ      ignition_timing_calc_task_goto_3595
ignition_timing_calc_task_if_ram22d_bit0_set:     JBS     off(0022dh).0, ignition_timing_calc_task_load_ram2b0
                LB      A, off(0029eh)
                STB     A, off(002b0h)
                SJ      ignition_timing_calc_task_if_ne_goto_3410
ignition_timing_calc_task_load_ram2b0:     LB      A, off(002b0h)
                STB     A, off(0029eh)
ignition_timing_calc_task_if_ne_goto_3410:     JNE     ignition_timing_calc_task_goto_3595
                JBR     off(0022fh).0, ignition_timing_calc_task_goto_3595
                JBS     off(0022eh).3, ignition_timing_calc_task_load_carry_ram22e_bit4
                JBS     off(0022fh).7, ignition_timing_calc_task_goto_340a
                JBS     off(0022fh).6, ignition_timing_calc_task_goto_3595
ignition_timing_calc_task_goto_340a:     SJ      ignition_timing_calc_task_goto_348c
ignition_timing_calc_task_load_carry_ram22e_bit4:     MB      C, off(0022eh).4
                JBS     off(00211h).6, ignition_timing_calc_task_if_ge_goto_33ca
                MB      C, off(0022eh).6
ignition_timing_calc_task_if_ge_goto_33ca:     JGE     ignition_timing_calc_task_load_ram2ce
                MOVB    off(002ceh), #00ah
ignition_timing_calc_task_load_ram2ce:     LB      A, off(002ceh)
                JNE     ignition_timing_calc_task_goto_3595
                MOV     er1, #00028h
                JBR     off(00211h).6, ignition_timing_calc_task_if_ram22d_bit5_clr
                JBR     off(0022dh).4, ignition_timing_calc_task_goto_3595
                SJ      ignition_timing_calc_task_goto_3583
ignition_timing_calc_task_if_ram22d_bit5_clr:     JBR     off(0022dh).5, ignition_timing_calc_task_if_ram22d_bit1_set
                MOV     er1, #00033h
                SJ      ignition_timing_calc_task_goto_3583
ignition_timing_calc_task_if_ram22d_bit1_set:     JBS     off(0022dh).1, ignition_timing_calc_task_goto_3583
                JBS     off(0022fh).7, ignition_timing_calc_task_if_ram22d_bit2_clr
                JBS     off(0022fh).6, ignition_timing_calc_task_goto_3595
                JBR     off(0022dh).3, ignition_timing_calc_task_goto_3595
                SJ      ignition_timing_calc_task_load_carry_ram22f_bit3
ignition_timing_calc_task_if_ram22d_bit2_clr:     JBR     off(0022dh).2, ignition_timing_calc_task_goto_3595
ignition_timing_calc_task_load_carry_ram22f_bit3:     MB      C, off(0022fh).3
                JBS     off(0022fh).7, ignition_timing_calc_task_if_lt_goto_3403
                MB      C, off(0022fh).4
ignition_timing_calc_task_if_lt_goto_3403:     JLT     ignition_timing_calc_task_goto_7756
                MOVB    off(002cfh), #00ah
ignition_timing_calc_task_goto_7756:     J       ignition_timing_calc_task_load_ram2cf
                DB  000h,003h,039h,035h
ignition_timing_calc_task_goto_348c:     J       ignition_timing_calc_task_clear_r0
ignition_timing_calc_task_goto_3583:     J       ignition_timing_calc_task_load_ram298
ignition_timing_calc_task_goto_3595:     J       ignition_timing_calc_task_clear_acc
ignition_timing_calc_task_load_ram29f:     LB      A, off(0029fh)
                MOVB    r0, #060h
                MOV     er1, #0332eh
                MOVB    r6, #020h
                MOVB    r7, #020h
                JBS     off(0022fh).7, ignition_timing_calc_task_subb_acc_3
                LB      A, off(002a1h)
                MOVB    r0, #060h
                MOV     er1, #044a1h
                MOVB    r6, #020h
                MOVB    r7, #020h
ignition_timing_calc_task_subb_acc_3:     SUBB    A, 0b9h
                MB      PSWL.4, C
                JGE     ignition_timing_calc_task_mulb_acc
                VCAL    7
ignition_timing_calc_task_mulb_acc:     MULB
                L       A, ACC
                MOVB    r0, #020h
                NOP
                NOP
                NOP
                NOP
                MB      C, PSWL.4
                JGE     ignition_timing_calc_task_add_acc
                XCHG    A, er1
                SUB     A, er1
                JGE     ignition_timing_calc_task_store_er0
                CLR     A
                SJ      ignition_timing_calc_task_store_er0
ignition_timing_calc_task_add_acc:     ADD     A, er1
                JGE     ignition_timing_calc_task_store_er0
                L       A, #0ffffh
ignition_timing_calc_task_store_er0:     ST      A, er0
                L       A, 0b6h
                MUL
                L       A, er1
                MOV     DP, #0038ah
                ST      A, [DP]
                SUB     A, 0ach
                MB      PSWL.4, C
                JGE     ignition_timing_calc_task_load_dp
                VCAL    7
ignition_timing_calc_task_load_dp:     MOV     DP, #0038ch
                ST      A, [DP]
                CAL     weighted_sum_2term_trim
ignition_timing_calc_task_if_eq_goto_3475:     JEQ     ignition_timing_calc_task_load_x2
                CMP     A, #00333h
                JLT     ignition_timing_calc_task_load_x2
                L       A, #00333h
ignition_timing_calc_task_load_x2:     MOV     X2, A
                MOV     X1, #00316h
                JBS     off(0022fh).7, ignition_timing_calc_task_load_er0
                INC     X1
                INC     X1
ignition_timing_calc_task_load_er0:     MOV     er0, #000ffh
                CAL     interp_bracket_delta_scale_2
                CAL     clamp_to_35_512
                L       A, X2
                J       ignition_timing_calc_task_clear_ram22f_bit2_2
ignition_timing_calc_task_clear_r0:     CLRB    r0
                MOV     DP, #00312h
                MOVB    r1, #090h
                MOVB    r2, #040h
                JBS     off(0022fh).7, ignition_timing_calc_task_load_dp_ind
                INC     DP
                INC     DP
                MOVB    r1, #080h
                MOVB    r2, #040h
ignition_timing_calc_task_load_dp_ind:     L       A, [DP]
                SUB     A, off(0029ah)
                MB      PSWL.4, C
                JGE     ignition_timing_calc_task_cmp_acc_4
                VCAL    7
                MOVB    r1, r2
ignition_timing_calc_task_cmp_acc_4:     CMP     A, #00155h
                SB      off(0022fh).1
                JGE     ignition_timing_calc_task_goto_5a68
                JNE     ignition_timing_calc_task_if_ram22f_bit5_set
                J       ignition_timing_calc_task_load_dp_ind_3
ignition_timing_calc_task_goto_5a68:     J       ignition_timing_calc_task_mul_acc_3
                DB  000h
ignition_timing_calc_task_load_carry_pswl_bit4:     MB      C, PSWL.4
                JLT     ignition_timing_calc_task_sub_acc
                ADD     A, er1
                J       ignition_timing_calc_task_if_lt_goto_7787
                DW  00000h
ignition_timing_calc_task_goto_34c9:     SJ      ignition_timing_calc_task_store_ram29a
ignition_timing_calc_task_sub_acc:     SUB     A, er1
                JGE     ignition_timing_calc_task_store_ram29a
                CLR     A
ignition_timing_calc_task_store_ram29a:     ST      A, off(0029ah)
ignition_timing_calc_task_if_ram22f_bit5_set:     JBS     off(0022fh).5, ignition_timing_calc_task_load_ram2d0
                CMP     off(0029ch), #00180h
                JLT     ignition_timing_calc_task_load_ram2d0
                LB      A, off(002d0h)
                JNE     ignition_timing_calc_task_load_ram0b6
                RB      off(0022fh).7
                SJ      ignition_timing_calc_task_load_ram0b6
ignition_timing_calc_task_load_ram2d0:     MOVB    off(002d0h), #028h
ignition_timing_calc_task_load_ram0b6:     L       A, 0b6h
                MOV     er0, #034c2h
                JBS     off(0022fh).7, ignition_timing_calc_task_mul_acc
                MOV     er0, #04a55h
ignition_timing_calc_task_mul_acc:     MUL
                L       A, er1
                MOV     DP, #0038ah
                ST      A, [DP]
                L       A, 0ach
                SUB     A, er1
                MB      off(0022fh).5, C
                MB      PSWL.4, C
                JGE     ignition_timing_calc_task_store_ram29c
                VCAL    7
ignition_timing_calc_task_store_ram29c:     ST      A, off(0029ch)
                MOVB    r6, #040h
                MOVB    r7, #040h
                CAL     weighted_sum_2term_trim
                MOV     X2, A
                JEQ     ignition_timing_calc_task_cmp_ram2d1
                MOVB    off(002d1h), #014h
ignition_timing_calc_task_cmp_ram2d1:     CMPB    off(002d1h), #000h
                JNE     ignition_timing_calc_task_if_ram22c_bit6_clr
                CLR     X2
                SJ      ignition_timing_calc_task_load_x2_2
ignition_timing_calc_task_if_ram22c_bit6_clr:     JBR     off(0022ch).6, ignition_timing_calc_task_load_x2_2
                JBS     off(0022ch).7, ignition_timing_calc_task_load_x2_2
                MOV     X1, #00312h
                JBS     off(0022fh).7, ignition_timing_calc_task_load_er0_2
                INC     X1
                INC     X1
ignition_timing_calc_task_load_er0_2:     MOV     er0, #000ffh
                CAL     interp_bracket_delta_scale_2
                CAL     ignition_timing_calc_task_sub_load_er2
ignition_timing_calc_task_load_x2_2:     L       A, X2
                J       ignition_timing_calc_task_clear_ram22f_bit2_3
                DW  00000h
ignition_timing_calc_task_load_ram29f_2:     LB      A, off(0029fh)
                MOVB    r0, #0ffh
                MOV     DP, #00316h
                JBS     off(0022fh).7, ignition_timing_calc_task_subb_acc_4
                LB      A, off(002a1h)
                MOVB    r0, #0ffh
                INC     DP
                INC     DP
ignition_timing_calc_task_subb_acc_4:     SUBB    A, 0b9h
                JLT     ignition_timing_calc_task_vcal_7
                CLRB    r0
ignition_timing_calc_task_vcal_7:     VCAL    7
                MULB
                L       A, ACC
                J       ignition_timing_calc_task_sll_acc
ignition_timing_calc_task_load_imm_2:     L       A, #0ffffh
ignition_timing_calc_task_load_r1:     MOVB    r1, ACCH
                ADDB    r1, #040h
                J       ignition_timing_calc_task_if_ge_goto_779d
ignition_timing_calc_task_mul_acc_2:     MUL
                J       ignition_timing_calc_task_sll_acc_2
ignition_timing_calc_task_if_ram22f_bit2_set:     JBS     off(0022fh).2, ignition_timing_calc_task_store_ram29a_2
                CMP     A, off(00298h)
                MB      off(0022fh).2, C
                JLT     ignition_timing_calc_task_store_ram29a_2
                L       A, off(00298h)
                ADD     A, #00020h
                CAL     clamp_0_3ff_simple
                SJ      ignition_timing_calc_task_goto_77b7
                DW  to_injtimer_store_0x166
ignition_timing_calc_task_store_ram29a_2:     ST      A, off(0029ah)
                SJ      ignition_timing_calc_task_goto_77b7
ignition_timing_calc_task_load_ram298:     L       A, off(00298h)
                ADD     A, er1
                JLT     ignition_timing_calc_task_load_imm_3
                J       ignition_timing_calc_task_cmp_acc_11
ignition_timing_calc_task_cmp_acc_5:     CMP     A, #003ffh
                JLT     ignition_timing_calc_task_clear_ram22f_bit2
ignition_timing_calc_task_load_imm_3:     L       A, #003ffh
                SJ      ignition_timing_calc_task_clear_ram22f_bit2
ignition_timing_calc_task_clear_acc:     CLR     A
                ST      A, off(0029ah)
ignition_timing_calc_task_clear_ram22f_bit2:     RB      off(0022fh).2
ignition_timing_calc_task_goto_77b7:     J       ignition_timing_calc_task_clear_ram22f_bit1
                DW  00000h
ignition_timing_calc_task_cmp_acc_6:     CMP     A, #00023h
                JGE     ignition_timing_calc_task_load_er0_3
                CLR     A
ignition_timing_calc_task_load_er0_3:     MOV     er0, #00064h
                MUL
                MOV     er0, er1
                MOV     er2, #003ffh
                DIV
                LB      A, ACC
                STB     A, 0dfh
                RT
; [CG] periodic_decay_task_1  @0x35B9
; [CG] TRACED: dispatch target from background_task_scheduler, runs only when the
; [CG] divide-by-10 slow tick sets off(231h).1. Calls decrement_timer_array (0x5204) over two
; [CG] RAM ranges, then increments a counter at RAM 0xE9.
periodic_decay_task_1:     MOV     DP, #00011h
                MOV     X1, #0018eh
                CAL     decrement_timer_array
                MOV     DP, #0002bh
                MOV     X1, #002b4h
                CAL     decrement_timer_array
                LB      A, 0e9h
                ADDB    A, #001h
                JEQ     vcal3_task_c_msec_tick
                STB     A, 0e9h
vcal3_task_c_msec_tick:     CAL     selftest_reason_range_check
                MOV     er2, 0b6h
                MOV     er0, #00021h
                L       A, #0af7ah
                DIV
                CMP     er0, #00000h
                JEQ     vcal3_task_c_msec_tick_store_er0
                L       A, #0ffffh
vcal3_task_c_msec_tick_store_er0:     ST      A, er0
                MOV     DP, #003aah
                XCHG    A, [DP]
                SUB     er0, A
                JGE     vcal3_task_c_msec_tick_load_r1
                CLR     A
                SUB     A, er0
                ST      A, er0
vcal3_task_c_msec_tick_load_r1:     LB      A, r1
                JEQ     vcal3_task_c_msec_tick_load_r0
                MOVB    r0, #0ffh
vcal3_task_c_msec_tick_load_r0:     LB      A, r0
                MOV     DP, #003a7h
                STB     A, [DP]
                MOV     DP, #003a6h
                LB      A, 0b4h
                JNE     vcal3_task_c_msec_tick_cmp_acc
                LB      A, [DP]
                JEQ     vcal3_task_c_msec_tick_load_ram2a8
                MOVB    r6, #0ffh
                CMPB    r6, A
                MB      off(00225h).6, C
                CLRB    A
                SJ      vcal3_task_c_msec_tick_store_dp_ind
vcal3_task_c_msec_tick_cmp_acc:     CMPB    A, [DP]
                JLT     vcal3_task_c_msec_tick_load_ram2a8
vcal3_task_c_msec_tick_store_dp_ind:     STB     A, [DP]
vcal3_task_c_msec_tick_load_ram2a8:     LB      A, off(002a8h)
                JEQ     percyl_counter_gate
                CMPB    off(002bbh), #000h
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
percyl_counter_loop:     LB      A, off(002a9h)
                CMPB    A, #020h
                JLT     percyl_counter_dp_select
                CLRB    off(002a9h)
                LCB     A, idle_init_start_tbl
                JEQ     tach_output_drive
                LB      A, 0e7h
                JEQ     tach_output_drive
                SJ      percyl_bcd_convert
percyl_counter_dp_select:     MOV     DP, #0031dh
                CMPB    A, #018h
                JGE     percyl_counter_increment
                DEC     DP
                JBS     off(002a9h).4, percyl_counter_increment
                DEC     DP
                JBS     off(002a9h).3, percyl_counter_increment
                DEC     DP
percyl_counter_increment:     INCB    off(002a9h)
                TRB     [DP]  ; ;mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C213
                JNE     percyl_wrap_check1
                LB      A, off(002a9h)
                ANDB    A, #007h
                RC
                JNE     percyl_counter_loop
                SJ      tach_output_drive
percyl_wrap_check1:     ADDB    A, #001h
                CMPB    A, #01dh
                JNE     percyl_wrap_check2
                LB      A, #02bh
percyl_wrap_check2:     CMPB    A, #01bh
                JNE     percyl_wrap_check3
                LB      A, #029h
percyl_wrap_check3:     CMPB    A, #01ah
                JNE     percyl_wrap_check4
                LB      A, #024h
percyl_wrap_check4:     CMPB    A, #019h
                JNE     percyl_bcd_convert
                LB      A, #023h
percyl_bcd_convert:     MOVB    r0, #00ah
                DIVB
                SWAPB
                ORB     A, r1
                MOV     er1, #02b20h
percyl_store_result:     STB     A, off(002a8h)
                CMPB    A, #010h
                JLT     percyl_result_final
                MOVB    r2, r3
percyl_result_final:     MOVB    off(002bbh), r2
percyl_alt_check:     CMPB    A, #010h
                L       A, #00206h
                JLT     percyl_alt_store
                L       A, #00311h
percyl_alt_store:     ST      A, er1
                LB      A, off(002bbh)
                CMPB    A, r2
                JGE     tach_output_drive
                CMPB    r3, A
tach_output_drive:     MB      P1.5, C
                JBR     off(00210h).7, tach_output_return
                MOV     DP, #0031ah
                L       A, [DP]
                JNE     tach_output_drive2
                INC     DP
                INC     DP
                L       A, [DP]
                JNE     tach_output_drive2
                LCB     A, idle_init_start_tbl
                JEQ     set_carry_flag
                LB      A, 0e7h
                JNE     tach_output_drive2
set_carry_flag:     SC
tach_output_drive2:     MB      P1.4, C
tach_output_return:     RT
; [CG] vcal3_task_b_body  @0x36CE
; [CG] TRACED: dispatch target from background_task_scheduler, runs only when the
; [CG] divide-by-10 slow tick sets off(231h).2. Structurally identical to
; [CG] periodic_decay_task_1 but over different RAM ranges and counter (RAM 0xE8).
vcal3_task_b_body:     MOV     DP, #00006h
                MOV     X1, #00188h
                CAL     decrement_timer_array
                MOV     DP, #0000ah
                MOV     X1, #002aah
                CAL     decrement_timer_array
                LB      A, 0e8h
                ADDB    A, #001h
                JEQ     learn_table1_check
                STB     A, 0e8h
learn_table1_check:     LB      A, off(002aeh)
                JNE     learn_table2_check
                MOVB    off(002aeh), #002h
                MOV     X1, #tbl_diag_snapshot_data2
                MOV     DP, #001afh
                MOVB    r6, #027h
learn_table1_loop:     LB      A, [DP]
                ADDB    A, #001h
                CMPCB   A, [X1]
                JLT     learn_table1_store
                LCB     A, [X1]
learn_table1_store:     STB     A, [DP]
                LB      A, r6
                SUBB    A, 0eah
                JNE     learn_table1_advance
                STB     A, 0eah
learn_table1_advance:     INC     X1
                INC     DP
                INCB    r6
                CMP     DP, #001b3h
                JLE     learn_table1_loop
learn_table2_check:     LB      A, off(002b2h)
                JNE     learn_retry_store_load_imm
                MOVB    off(002b2h), #002h
                LB      A, #001h
                MB      C, 09fh.1
                JLT     learn_counter_store
                LB      A, 0edh
                ADDB    A, #001h
                CMPB    A, #020h
                JLT     learn_counter_store
                LB      A, #020h
learn_counter_store:     STB     A, 0edh
                LB      A, 0ech
                ADDB    A, #001h
                CMPB    A, #020h
                JLT     learn_retry_store
                RB      09fh.1
                LB      A, #020h
learn_retry_store:     STB     A, 0ech
learn_retry_store_load_imm:     LB      A, #006h
                CMPB    A, (00185h-00180h)[USP]
                JLE     learn_retry_store_cmp_acc
                INCB    (00185h-00180h)[USP]
learn_retry_store_cmp_acc:     CMPB    A, (00184h-00180h)[USP]
                JLE     vcal3_task_a_return
                INCB    (00184h-00180h)[USP]
vcal3_task_a_return:     RT
regbank_selftest2_start:     L       A, #02babh
                MOV     X1, #002a0h
                JBR     off(00217h).2, regbank_selftest2_ie_check
                L       A, #0a9a3h
                MOV     X1, #000a0h
regbank_selftest2_ie_check:     CMP     A, 0f2h
                JNE     selftest_fail_04f
                CMP     A, IE
                JNE     selftest_fail_04f
                L       A, X1
                CMP     A, 0f4h
                JEQ     regbank_selftest2_range_check
selftest_fail_04f:     MOVB    0ebh, #04fh
                J       fault_retry_check
regbank_selftest2_range_check:     L       A, off(002eeh)
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
selftest_fail_042_alt:     MOVB    0ebh, #042h
                BRK
regbank_selftest2_check3:     MOV     X2, A
                CMP     A, X2
                JNE     selftest_fail_042_alt
regbank_selftest2_default:     L       A, #003fah
irqmode_dispatch:     ST      A, off(002eeh)
                VCAL    4
                AND     IE, #002a0h
                RB      PSWH.0
                JBS     off(00212h).3, irqmode_select_b
                JBS     off(00217h).2, irqmode_check1
                RB      IRQH.7
                JEQ     irqmode_check1
                SB      09eh.7
dtc04_ckp_latch_2: SB      09ch.0
irqmode_check1:     SB      PSWH.0
                CMPB    (001a9h-00180h)[USP], #029h
                RB      PSWH.0
                JLT     irqmode_select_b
                JBR     off(00217h).2, irqmode_done
                L       A, #02babh
                ST      A, IE
                ST      A, 0f2h
                MOV     0f4h, #002a0h
                RB      off(00217h).2
                MOVB    TCON2, #082h
                MOV     TM2, #00001h
                MOVB    TCON3, #08fh
                MOV     TM3, #00002h
                SC
                MB      TCON2.4, C
                L       A, ACC
                MB      TCON3.4, C
                SJ      irqmode_done
irqmode_select_b:     JBS     off(00217h).2, irqmode_done
                L       A, #0a9a3h
                ST      A, IE
                ST      A, 0f2h
                MOV     0f4h, #000a0h
                SB      off(00217h).2
                RB      (0011dh-00180h)[USP].6
                RB      off(0021dh).6
                SB      TCON3.2
irqmode_done:     SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                NOP
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
selftest_fail_050:     MOVB    0ebh, #050h
                BRK
periph_init_verify_pwm_adc:     LB      A, PWCON0
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
                MOV     DP, #00354h
                MB      C, [DP].1
                JGE     periph_init_verify_pwm_adc_and_ie
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
periph_init_verify_pwm_adc_and_ie:     AND     IE, #002a0h
                RB      PSWH.0
                MOV     er0, TM0
                MOV     er1, TM1
                MOV     er2, TM2
                MOV     er3, TM3
                SB      PSWH.0
                NOP
                RB      PSWH.0
                MOV     X1, TM0
                MOV     X2, TM1
                MOV     DP, TM2
                SB      PSWH.0
                L       A, 0f2h
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
                CMP     A, #00021h
                JGE     selftest_fail_04b
                L       A, X2
                SUB     A, er1
                ST      A, er1
                JEQ     selftest_fail_04b
                CMP     A, #0007fh
                JGE     selftest_fail_04b
                L       A, DP
                SUB     A, er2
                MOV     X2, A
                JEQ     selftest_fail_04b
                CMP     A, #00021h
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
selftest_fail_04b:     MOVB    0ebh, #04bh
                BRK
clock_selftest_passed:     VCAL    4
                CAL     boot_completion_helper
                MOVB    r0, #001h
                JBR     off(00217h).2, warmcold_ie_setup
                MOVB    r0, #006h
warmcold_ie_setup:     L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                RB      off(00231h).5
                JBR     off(00217h).4, warmcold_tm2_check
                J       warmrestart_tm3_resync
warmcold_tm2_check:     JNE     coldstart_full_reset
                LB      A, r0
                CMPB    A, 0deh
                JLT     coldstart_full_reset
                JNE     warmrestart_path
                L       A, TM2
                CMP     A, 0e2h
                JGE     coldstart_full_reset
warmrestart_path:     J       warmcold_reconverge
coldstart_full_reset:     SB      off(00217h).4
                CLRB    A
                MOVB    0d2h, #002h
                STB     A, 0d3h
                MOVB    (0012ah-00180h)[USP], #005h
                STB     A, (0012bh-00180h)[USP]
                MOVB    (00135h-00180h)[USP], #004h
                MOV     USP, #00380h
                L       A, #0ffffh
                ST      A, (0036ch-00380h)[USP]
                ST      A, (0036eh-00380h)[USP]
                ST      A, (00370h-00380h)[USP]
                ST      A, 0ach
                CLR     A
                ST      A, (00360h-00380h)[USP]
                ST      A, (00362h-00380h)[USP]
                ST      A, (00364h-00380h)[USP]
                ST      A, (00366h-00380h)[USP]
                ST      A, (00368h-00380h)[USP]
                ST      A, (0036ah-00380h)[USP]
                MOV     USP, #00180h
                CLRB    A
                STB     A, off(00236h)
                STB     A, (0012dh-00180h)[USP]
                STB     A, 0abh
                SB      P4.0
                SB      (0011eh-00180h)[USP].0
                MOVB    0d0h, #004h
                SB      (00122h-00180h)[USP].5
                L       A, #0ffffh
                ST      A, 0d4h
                ST      A, 0e0h
                CLR     X1
                L       A, #0ff04h
                ST      A, 00356h[X1]
                ST      A, 0035ah[X1]
                ST      A, 0035eh[X1]
                LB      A, #0ffh
                STB     A, 00355h[X1]
                STB     A, 00359h[X1]
                STB     A, 0035dh[X1]
                ORB     0a0h, #01ch
                J       coldstart_full_reset_andb_p1
                DW  00000h
coldstart_full_reset_goto_7831:     J       coldstart_full_reset_clear_ram221_bit7
coldstart_full_reset_orb_tcon3:     ORB     TCON3, #00ch
                CLR     A
                ST      A, (00120h-00180h)[USP]
                ST      A, (0011ch-00180h)[USP]
                ST      A, off(0021ch)
                ST      A, (001d0h-00180h)[USP]
                ST      A, (001ceh-00180h)[USP]
                J       coldstart_full_reset_store_ram0f0
                DB  000h
warmrestart_tm3_resync:     L       A, TM3
                SUB     A, #00001h
                ST      A, TMR3
warmcold_reconverge:     SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                SC
                JBS     off(00217h).4, warmcold_deg_flag
                JBS     off(00211h).0, warmcold_deg_select
                JBR     off(00217h).5, warmcold_state_stamp
warmcold_deg_select:     LB      A, #012h
                JBS     off(00217h).5, warmcold_deg_check
                LB      A, #01dh
warmcold_deg_check:     CMPB    A, 0adh
warmcold_deg_flag:     MB      off(00217h).5, C
                JGE     warmcold_state_stamp
                JBR     off(00211h).0, warmcold_msec_reset
                SB      off(00230h).4
warmcold_msec_reset:     ANDB    098h, #0e2h
                ANDB    099h, #0cdh
                ANDB    09ah, #008h
                ANDB    09bh, #007h
                CLRB    A
                STB     A, 0e9h
                STB     A, 0e8h
                NOP
                NOP
                NOP
                JBR     off(00217h).4, tps_learn_vcal3_call
warmcold_state_stamp:     MOVB    off(002bah), #063h
tps_learn_vcal3_call:     VCAL    4
                LB      A, off(002dfh)
                JNE     tps_learn_vcal3_call_load_dp
                MOVB    off(002dfh), #006h
                LB      A, #0fah
                JBS     off(00217h).4, tps_learn_vcal3_call_store_ram2a3
                STB     A, r0
                LB      A, #07bh
                STB     A, r1
                STB     A, r2
                JBS     off(0021ah).2, tps_learn_table_store_load_r0
                JBS     off(0021ah).3, tps_learn_table_store_load_r0
                LB      A, 0bch
                CMPB    A, r1
                JGE     tps_learn_table_store_load_r0
                STB     A, r1
                MOVB    r3, off(002a4h)
                SUBB    A, r3
                JLT     tps_learn_table_store
                CMPB    A, #004h
                JGE     tps_learn_table_store_load_r0
                SUBB    off(002a3h), #001h
                JNE     tps_learn_table_store_load_dp
                MOV     DP, #00311h
                LB      A, r3
                STB     A, [DP]
                MOV     DP, #00310h
                LB      A, #0ffh
                STB     A, [DP]
                SJ      tps_learn_table_store_load_dp
tps_learn_table_store:     MOV     DP, #00310h
                LB      A, [DP]
                JNE     tps_learn_table_store_load_r0
                MOVB    r0, #053h
tps_learn_table_store_load_r0:     LB      A, r0
                STB     A, off(002a3h)
                LB      A, r1
                STB     A, off(002a4h)
tps_learn_table_store_load_dp:     MOV     DP, #00311h
                LB      A, [DP]
                CMPB    A, r2
                JLT     tps_learn_vcal3_call_load_dp
                LB      A, r2
                STB     A, [DP]
                SJ      tps_learn_vcal3_call_load_dp
tps_learn_vcal3_call_store_ram2a3:     STB     A, off(002a3h)
tps_learn_vcal3_call_load_dp:     MOV     DP, #0030ch
                L       A, [DP]
                CMP     A, #00010h
                JLT     fueltbl_default_load
                CMP     A, #01000h
                JLE     fueltbl_sanitize_loop
fueltbl_default_load:     CAL     stub_or_short_helper
                ST      A, [DP]
fueltbl_sanitize_loop:     MOV     DP, #00300h
fueltbl_sanitize_check:     JBR     off(00216h).2, fueltbl_range_check
                MB      C, 0a0h.0
                JLT     fueltbl_default_value
fueltbl_range_check:     CMP     [DP], #09862h
                JGT     fueltbl_default_value
                CMP     [DP], #07133h
                JGE     fueltbl_sanitize_advance
fueltbl_default_value:     MOV     [DP], #08000h
fueltbl_sanitize_advance:     ADD     DP, #00004h
                CMP     DP, #0030ch
                JLT     fueltbl_sanitize_check
                LB      A, (00120h-00180h)[USP]
                MB      C, ACC.2
                JGE     sensor_check_vcal3
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                MOVB    r0, (001b6h-00180h)[USP]
                MOVB    r1, (001beh-00180h)[USP]
                MOVB    r2, (001bfh-00180h)[USP]
                MOVB    r3, (00134h-00180h)[USP]
                SB      PSWH.0
                L       A, 0f2h
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
knock_check_alt_path:     L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                RB      TCON0.4
                RB      TCON0.2
                LB      A, #00fh
                STB     A, (001bfh-00180h)[USP]
                STB     A, (001b7h-00180h)[USP]
                ORB     P2, A
                SB      TCON0.2
                LB      A, (00134h-00180h)[USP]
                CAL     knock_helper1
                STB     A, (001b6h-00180h)[USP]
                XORB    A, #0ffh
                MB      C, ACC.7
                ROLB    A
                STB     A, (001beh-00180h)[USP]
                RB      TCON0.2
                SB      TCON0.4
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
sensor_check_vcal3:     VCAL    4
                MOV     DP, #003c5h
                LB      A, [DP]
                STB     A, 0c3h
                JBS     off(00212h).2, sensor_check_clear
                JBS     off(00212h).4, sensor_check_clear
                J       sensor_check_vcal3_if_ram217_bit5_set
sensor_check_vcal3_cmp_ram236:     CMPB    off(00236h), #002h
                JGE     sensor_check_vcal3_if_ram230_bit4_clr
                MOVB    off(002beh), #064h
sensor_check_vcal3_if_ram230_bit4_clr:     JBR     off(00230h).4, sensor_check_clear
                LB      A, off(00234h)
                SUBB    A, ADCR6H
                JGE     sensor_check_result
                VCAL    7
sensor_check_result:     CMPB    A, #002h
                JGE     sensor_check_set
                LB      A, off(002beh)
                JEQ     dtc05_map_range_latch
sensor_check_clear:     RC
                SJ      dtc05_map_range_latch
sensor_check_set:     SB      off(00230h).5
dtc05_map_range_latch:     MB      098h.3, C
                MOV     DP, #003c8h
                LB      A, [DP]
                STB     A, r1
                RC
                JBS     off(00212h).5, dtc06_ect_latch
                LB      A, #0fch
                CMPB    A, r1
                JLT     dtc06_ect_latch
                LB      A, r1
                CMPB    A, #004h
dtc06_ect_latch:     MB      098h.1, C
                JBS     off(00212h).5, ect_simulate_ramp
                JLT     ect_simulate_ramp_load_ram0c1
                JBS     off(00210h).7, ect_fault_range_check_load_dp
                SUBB    A, off(002a5h)
                JGE     ect_fault_delta_check
                VCAL    7
ect_fault_delta_check:     CMPB    A, #002h
                JGT     ect_fault_normal_store
                LB      A, off(002b9h)
                JNE     sensor_bank_ect_check_clear_carry
                LB      A, r1
                JBS     off(00217h).4, ect_fault_range_check_load_dp
                CMPB    A, off(002a6h)
                JGT     sensor_bank_ect_check
                SJ      ect_fault_range_check_load_dp
ect_simulate_ramp:     JBR     off(00217h).5, ect_simulate_ramp_load_ram0c1
                CLR     A
                LB      A, off(002bah)
                MOVB    r0, #014h
                DIVB
                MOV     DP, #ect_simulate_ramp_tbl
                ADD     DP, A
                LCB     A, [DP]
                STB     A, 0c1h
                SJ      sensor_bank_ect_check
ect_simulate_ramp_load_ram0c1:     MOVB    0c1h, #03bh
                SJ      sensor_bank_ect_check
ect_fault_range_check_load_dp:     MOV     DP, #000c1h
                CAL     ect_smooth_helper
                JBS     off(00217h).5, ect_step_call
                MOV     DP, #00352h
                STB     A, [DP]
ect_step_call:     CAL     ect_step_helper
ect_fault_normal_store:     MOVB    off(002a5h), r1
sensor_bank_ect_check:     MOVB    off(002b9h), #005h
sensor_bank_ect_check_clear_carry:     RC
                JBS     off(00212h).7, dtc08_tdc_latch
                JBR     off(00217h).4, dtc08_tdc_latch
                MB      C, off(00211h).0
                JBR     off(00216h).3, dtc08_tdc_latch
                JGE     dtc08_tdc_latch
                MB      C, off(00211h).5
dtc08_tdc_latch:     MB      098h.5, C
                JBR     off(00213h).1, iat_range_check
                MOVB    0c0h, #057h
                SJ      iat_check_return
iat_range_check:     LB      A, #0fch
                MOV     DP, #003c0h
                CMPB    A, [DP]
                JLT     dtc10_iat_latch
                LB      A, [DP]
                CMPB    A, #004h
                JLT     dtc10_iat_latch
                MOV     DP, #000c0h
                CAL     ect_smooth_helper
iat_check_return:     RC
dtc10_iat_latch:     MB      098h.6, C
                LB      A, #080h
                RC
                JBS     off(00217h).6, sensor_bank_store_e3
                JBS     off(00219h).1, sensor_bank_store_e3
                JBS     off(00213h).2, sensor_bank_store_e3
                MOV     DP, #003c6h
                LB      A, #0ffh
                CMPB    A, [DP]
                JLT     dtc_bit08_latch
                LB      A, [DP]
                CMPB    A, #000h
                JLT     dtc_bit08_latch
sensor_bank_store_e3:     STB     A, 0c7h
dtc_bit08_latch:     MB      098h.7, C
                JBR     off(00227h).4, sensor_bank_stamp_bc
                JBR     off(00213h).4, sensor_bank_bc_alt
sensor_bank_stamp_bc:     MOVB    0a4h, #0f9h
                SJ      dcode14_return
sensor_bank_bc_alt:     CLR     A
                LB      A, #0ffh
                MOV     DP, #003c1h
                CMPB    A, [DP]
                JLT     dcode14_check
                LB      A, [DP]
                CMPB    A, #000h
                JLT     dcode14_check
                CAL     subtract24_clamp_byte
                MOV     DP, #000a4h
                CAL     ect_smooth_helper
dcode14_return:     RC
dcode14_check:     J       dtc13_baro_latch
dcode14_check_if_ram217_bit5_set:     JBS     off(00217h).5, dcode14_clear
                JBS     off(00213h).5, dcode14_clear
                LB      A, 0c3h
                MOV     X1, #tbl_dcode14_lo
                VCAL    3
                CMPB    A, off(0025ah)
                JLT     dcode14_clear
                LB      A, 0c3h
                MOV     X1, #tbl_dcode14_hi
                VCAL    3
                CMPB    A, off(0025ah)
                JGE     dcode14_clear
                LB      A, off(002bdh)
                JEQ     dtc14_iacv_latch
dcode14_clear:     RC
dtc14_iacv_latch:     MB      099h.3, C
                LB      A, #044h
                CMPB    A, 0c3h
                JGE     dtc17_vss_latch
                CMPB    off(00236h), #0b0h
                JGE     dtc17_vss_latch
                RC
                JBS     off(00214h).0, dtc17_vss_latch
                JBR     off(00231h).3, dtc17_vss_latch
                MB      C, off(0021ch).4
dtc17_vss_latch:     MB      099h.4, C
                RC
                JBS     off(00227h).2, dtc_bit0F_latch
                JBR     off(00216h).3, dtc_bit0F_latch
                JBS     off(00214h).2, dtc_bit0F_latch
                MOV     DP, #00f00h
                LB      A, [DP]
                MB      C, ACC.4
                JBS     off(0022fh).0, dtc_bit0F_latch
                XORB    PSWH, #080h
dtc_bit0F_latch:     MB      099h.6, C
                VCAL    4
                JBS     off(00227h).2, dcode_gate_common2
                J       dcode_gate_common_if_ram216_bit3_clr
dcode_gate_common_load_dp:     MOV     DP, #00380h
                AND     IE, #002a0h
                RB      PSWH.0
                L       A, [DP]
                ST      A, er0
                MOV     DP, #04700h
                LB      A, [DP]
                STB     A, r7
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                ANDB    r7, #008h
                LB      A, r0
                CMPB    A, #0f6h
                JGE     dcode_gate_common2
                SUBB    A, r1
                JLT     dcode_gate_common_addb_acc
                LB      A, r7
                JEQ     dtc19_at_lockup_latch
                SJ      dcode_gate_common2
dcode_gate_common_addb_acc:     ADDB    A, #00ah
                JLT     dcode_gate_common2
                LB      A, r7
                JEQ     dcode_gate_common2
dtc19_at_lockup_latch:     SB      09ch.7
dcode_gate_common2:     LB      A, #025h
                JBR     off(00219h).1, dcode_stamp_store
                JBR     off(00217h).6, dcode_stamp_store
                JBS     off(00214h).3, dcode_stamp_store
                CMPB    0c3h, #069h
                JLT     dcode_stamp_store
                MOV     DP, #003c6h
                LB      A, #0dch
                CMPB    A, [DP]
                JLT     dtc20_eld_latch
                LB      A, [DP]
                CMPB    A, #00eh
                JLT     dtc20_eld_latch
dcode_stamp_store:     STB     A, 0c4h
                RC
dtc20_eld_latch:     MB      099h.7, C
                RC
                JBR     off(00216h).4, dtc21_vtec_solenoid_latch
                JBS     off(00214h).4, dtc21_vtec_solenoid_latch
                JBR     off(0021fh).2, altvtec_vtsf_check_load_ram2bf
                MOVB    off(002c0h), #014h
                LB      A, off(002bfh)
                JBS     off(00210h).5, dtc21_vtec_solenoid_latch
altvtec_vtsf_check_set_carry:     SC
                SJ      dtc21_vtec_solenoid_latch
altvtec_vtsf_check_load_ram2bf:     MOVB    off(002bfh), #014h
                LB      A, off(002c0h)
                JBS     off(00210h).5, altvtec_vtsf_check_set_carry
dtc21_vtec_solenoid_latch:     MB      09ah.0, C
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
dtc22_vtec_pressure_latch:     MB      09ah.1, C
                RC
                JBR     off(00227h).6, dtc23_knock_latch
                JBS     off(00214h).6, dtc23_knock_latch
                JBS     off(00233h).6, dtc23_knock_latch
                L       A, off(00212h)
                AND     A, #0c3bch
                JNE     dtc23_knock_latch
                JBS     off(00214h).5, dtc23_knock_latch
                LB      A, off(002e8h)
                JEQ     dtc23_knock_latch
                JBS     off(00233h).7, dtc23_knock_latch
                MB      C, off(00232h).7
dtc23_knock_latch:     MB      09ah.2, C
                LB      A, ADCR5H
                STB     A, 0bfh
                JBR     off(00216h).5, autotcc_return
                JBS     off(00217h).5, autotcc_return
                JBS     off(00215h).1, autotcc_return
                LB      A, 0c3h
                CMPB    A, #07dh
                JLT     autotcc_return
                LB      A, #0fch
                CMPB    A, 0bfh
                JLT     dtc26_code26_latch
                LB      A, 0bfh
                CMPB    A, #004h
                SJ      dtc26_code26_latch
autotcc_return:     RC
dtc26_code26_latch:     MB      09bh.1, C
                JBR     off(00216h).5, automatic_return
                JBS     off(00217h).5, automatic_return
                JBS     off(00215h).0, automatic_return
                JBS     off(00215h).1, automatic_return
                MB      C, 09bh.1
                JLT     automatic_return
                LB      A, 0c3h
                CMPB    A, #07dh
                JLT     automatic_return
                LB      A, 0bfh
                CMPB    A, #030h
                JLE     Automatic_load_carry_p4_bit6
                MB      C, P4.6
                JGE     automatic_p4_check
                SJ      automatic_return
Automatic_load_carry_p4_bit6:     MB      C, P4.6
                JLT     automatic_p4_check
automatic_return:     RC
                SJ      dtc25_code25_latch
automatic_p4_check:     SC
dtc25_code25_latch:     MB      09bh.0, C
                JBR     off(00219h).1, knockwindow_clear
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     knockwindow_clear
                L       A, off(00212h)
                AND     A, #01808h
                JNE     knockwindow_clear
                J       knockwindow_gate_start_if_ram214_bit5_set
knockwindow_gate_start_if_ge_goto_knockwindow_clear:     JGE     knockwindow_clear
                JBS     off(0021ch).5, knockwindow_clear
                JBS     off(0021dh).3, knockwindow_clear
                J       knockwindow_gate_start_if_ram218_bit0_set
knockwindow_gate_start_load_stk:     L       A, (00148h-00180h)[USP]
                CMP     A, #0b333h
                JGE     knockwindow_set
                J       knockwindow_gate_start_if_ram217_bit3_set
knockwindow_gate_start_if_le_goto_knockwindow_set:     JLE     knockwindow_set
knockwindow_clear:     RC
                SJ      knockwindow_result
knockwindow_set:     SC
knockwindow_result:     MB      09dh.7, C
                VCAL    4
                LB      A, 0c1h
                MOV     X1, #tbl_ect_fuelcorrect
                MOV     X2, #knockwindow_result_tbl_4
                CMPB    A, #023h
                JLT     knockwindow_result_store_carry_ram221_bit2
                MOV     X1, #knockwindow_result_tbl_3
                MOV     X2, #knockwindow_result_tbl_2
knockwindow_result_store_carry_ram221_bit2:     MB      off(00221h).2, C
                VCAL    0
                STB     A, r3
                MOV     X1, X2
                LB      A, 0c1h
                VCAL    0
                STB     A, r2
                MOV     off(00252h), er1
                LB      A, 0c1h
                MOV     X1, #knockwindow_result_tbl
                VCAL    0
                STB     A, off(00254h)
                VCAL    4
                LB      A, #03ah
                JBS     off(00221h).0, threshold_bank_220_5
                LB      A, #040h
threshold_bank_220_5:     CMPB    A, off(00236h)
                MB      off(00221h).0, C
                LB      A, #088h
                JBS     off(00221h).1, threshold_bank_220_6
                LB      A, #090h
threshold_bank_220_6:     CMPB    A, off(00235h)
                MB      off(00221h).1, C
                CLRB    A
                JGE     threshold_bank_222_6
                JBR     off(00221h).0, threshold_bank_222_6
                JBS     off(00213h).1, threshold_bank_222_6
                LB      A, 0c0h
                MOV     X1, #threshold_bank_220_6_tbl
                VCAL    0
threshold_bank_222_6:     STB     A, off(0023ah)
                MOV     DP, #003cdh
                LB      A, [DP]
                SLLB    A
                MB      off(00220h).4, C
                LB      A, #066h
                JBS     off(00220h).5, threshold_bank_222_6_cmp_acc
                LB      A, #073h
threshold_bank_222_6_cmp_acc:     CMPB    A, off(00236h)
                MB      off(00220h).5, C
                LB      A, #09ah
                JBS     off(00220h).6, threshold_bank_222_6_cmp_acc_2
                LB      A, #0a0h
threshold_bank_222_6_cmp_acc_2:     CMPB    A, off(00236h)
                MB      off(00220h).6, C
                LB      A, #089h
                JBS     off(00220h).7, threshold_bank_222_6_cmp_acc_3
                LB      A, #09ch
threshold_bank_222_6_cmp_acc_3:     CMPB    A, off(00235h)
                CLRB    A
                MB      off(00220h).7, C
                JGE     div_scale_store
                CLR     A
                MOV     DP, #003cah
                J       select_dp_3d9_3d6_flag_222_6
select_dp_3d9_3d6_flag_222_6_if_ge_goto_div_scale_calc1:     JGE     div_scale_calc1
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
                JBR     off(00220h).4, div_scale_store
                VCAL    7
div_scale_store:     STB     A, off(00242h)
                LB      A, #005h
                J       div_scale_store_load_x1
div_scale_store_clear_x1:     CLR     X1
                JBS     off(00217h).5, gear_detect_store
                JBS     off(00214h).0, gear_detect_store
                JBR     off(00227h).3, div_scale_store_load_r1
                JBR     off(0022fh).3, div_scale_store_load_ram2d2
                MOVB    off(002d2h), #005h
div_scale_store_load_ram2d2:     LB      A, off(002d2h)
                JNE     gear_detect_store_load_ram0c3
div_scale_store_load_r1:     MOVB    r1, 0b4h
                CLRB    r0
                L       A, 0ach
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
gear_detect_store_load_ram0c3:     LB      A, 0c3h
                MOV     X1, #DwellBattery
                VCAL    0
                STB     A, off(0024bh)
                VCAL    4
                MOV     X1, #gear_detect_store_tbl_5
                LB      A, 0a4h
                VCAL    2
                STB     A, (0017ch-00180h)[USP]
                MOV     X1, #Overrun_Resume_nor
                MOV     X2, #Overrun_Resume_int
                JBR     off(00216h).3, gear_detect_store_load_ram0c1
                MOV     X1, #gear_detect_store_tbl_4
                MOV     X2, #gear_detect_store_tbl_3
gear_detect_store_load_ram0c1:     LB      A, 0c1h
                VCAL    0
                STB     A, r2
                MOV     X1, X2
                LB      A, 0c1h
                VCAL    0
                STB     A, ACCH
                LB      A, r2
                J       gear_detect_store_load_stk
gear_detect_store_load_x1:     MOV     X1, #tbl_knockwindow_4
                MOV     X2, #tbl_knockwindow_3
                JBR     off(00216h).3, gear_detect_store_load_ram0c1_2
                MOV     X1, #gear_detect_store_tbl_2
                MOV     X2, #gear_detect_store_tbl
gear_detect_store_load_ram0c1_2:     LB      A, 0c1h
                VCAL    0
                STB     A, r2
                MOV     X1, X2
                LB      A, 0c1h
                VCAL    0
                STB     A, ACCH
                LB      A, r2
                J       gear_detect_store_load_stk_2
threshold_bank_223_2:     LB      A, #0a0h
                JBS     off(00223h).2, threshold_bank_223_2_store
                LB      A, #0d8h
threshold_bank_223_2_store:     CMPB    A, off(00236h)
                MB      off(00223h).2, C
                CLR     A
                MOV     X1, #tbl_threshold_223_1
                MOV     X2, #Revlimiters
                JBR     off(0021fh).1, revlimit_table_select
                MOV     X1, #tbl_threshold_223_2
                MOV     X2, #tbl_threshold_223_3
revlimit_table_select:     LC      A, 00002h[X1]
                MOV     DP, A
                LC      A, 00002h[X2]
                J       revlimit_table_select_if_ram217_bit5_set
revlimit_table_select_load_stk:     LB      A, (001a1h-00180h)[USP]
                JNE     revlimit_table_select_load_ram0c1
                MOVB    (001a1h-00180h)[USP], #014h
                JBS     off(00212h).5, revlimit_table_select_if_ram223_bit2_clr
                CMPB    0c1h, #044h
                JGE     revlimit_table_select_load_stk_2
revlimit_table_select_if_ram223_bit2_clr:     JBR     off(00223h).2, revlimit_table_select_load_stk_2
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                LB      A, (00189h-00180h)[USP]
                JNE     callhelper_sub37_clamp_to_er0
                L       A, (00182h-00180h)[USP]
                CAL     add24_clamp_neg1
                MOV     DP, A
                L       A, (00180h-00180h)[USP]
                MOV     X1, X2
                CAL     add24_clamp_neg1
                SJ      revlimit_table_select_and_ie
revlimit_table_select_load_stk_2:     MOVB    (00189h-00180h)[USP], #00ch
callhelper_sub37_clamp_to_er0:     LC      A, 00002h[X1]
                MOV     er0, A
                L       A, (00182h-00180h)[USP]
                CAL     sub37_clamp_to_er0
                MOV     DP, A
                LC      A, 00002h[X2]
                ST      A, er0
                L       A, (00180h-00180h)[USP]
                CAL     sub37_clamp_to_er0
revlimit_table_select_and_ie:     AND     IE, #002a0h
                RB      PSWH.0
                ST      A, (00180h-00180h)[USP]
                L       A, DP
                ST      A, (00182h-00180h)[USP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
revlimit_table_select_load_ram0c1:     LB      A, 0c1h
                MOV     X1, #revlimit_table_select_tbl_9
                CMPCB   A, 00002h[X1]
                MB      off(00219h).5, C
                VCAL    0
                STB     A, (0016dh-00180h)[USP]
                LB      A, 0c1h
                MOV     X1, #tbl_revlimit_warm3
                VCAL    1
                STB     A, (001e0h-00180h)[USP]
                VCAL    4
                LB      A, 0a4h
                MOV     X1, #tbl_revlimit_warm2
                VCAL    0
                STB     A, (00156h-00180h)[USP]
                LB      A, 0a4h
                MOV     X1, #tbl_revlimit_cold4
                VCAL    2
                STB     A, (00171h-00180h)[USP]
                LB      A, 0a4h
                MOV     X1, #tbl_revlimit_warm1
                VCAL    2
                STB     A, (0016eh-00180h)[USP]
                MOV     X1, #revlimit_table_select_tbl_17
                LB      A, 0a4h
                VCAL    2
                STB     A, (00159h-00180h)[USP]
                VCAL    4
                LB      A, 0c1h
                STB     A, r2
                MOV     X1, #revlimit_table_select_tbl_4
                VCAL    0
                STB     A, (0015ah-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_5
                VCAL    0
                STB     A, (0015bh-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_6
                VCAL    0
                STB     A, (0015ch-00180h)[USP]
                VCAL    4
                LB      A, 0c1h
                J       revlimit_table_select_store_r2
revlimit_table_select_vcal_0:     VCAL    0
                STB     A, (0015dh-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_18
                VCAL    0
                STB     A, (0015eh-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_8
                VCAL    0
                STB     A, (0016fh-00180h)[USP]
                VCAL    4
                LB      A, 0c1h
                J       revlimit_table_select_store_r2_2
revlimit_table_select_vcal_0_2:     VCAL    0
                STB     A, (00175h-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_14
                JBS     off(00216h).3, revlimit_table_select_vcal_0_3
                MOV     X1, #revlimit_table_select_tbl_13
revlimit_table_select_vcal_0_3:     VCAL    0
                STB     A, (00173h-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_16
                JBS     off(00216h).3, revlimit_table_select_vcal_0_4
                MOV     X1, #revlimit_table_select_tbl_15
revlimit_table_select_vcal_0_4:     VCAL    0
                STB     A, (00174h-00180h)[USP]
                VCAL    4
                LB      A, 0c1h
                J       revlimit_table_select_store_r2_3
revlimit_table_select_vcal_1:     VCAL    1
                STB     A, (001e6h-00180h)[USP]
                LB      A, 0c1h
                MOV     X1, #revlimit_table_select_tbl_11
                J       revlimit_table_select_vcal_1_2
revlimit_table_select_vcal_4:     VCAL    4
                MOV     X1, #tbl_revlimit_cold1
                CMPB    0b4h, #00fh
                JLT     iat_table_select
                MOV     X1, #tbl_revlimit_cold3
iat_table_select:     LB      A, 0c0h
                VCAL    2
                CMPB    0c1h, A
                MB      off(00219h).2, C
                LB      A, 0c0h
                MOV     X1, #IATFuelCorrect
                VCAL    1
                STB     A, (0014ch-00180h)[USP]
                VCAL    4
                CLR     A
                LB      A, #0aah
                JBS     off(00223h).1, iat_table_select_cmp_acc
                LB      A, #0b0h
iat_table_select_cmp_acc:     CMPB    A, off(00236h)
                MB      off(00223h).1, C
                LCB     A, tbl_idle_pi_clamp
                SRLB    A
                SRLB    A
                CLRB    r2
                MOV     DP, #003c2h
                LB      A, [DP]
                JLT     knock_retard_check
                CMPB    A, #0f0h
                JLT     knock_div_calc1
                LB      A, #076h
knock_div_calc1:     MOVB    r0, #030h
                DIVB
                JBS     off(00223h).1, knock_table_index
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
                LC      A, knock_table_index_tbl[ACC]
                SJ      knock_result_store
knock_retard_check:     ADDB    A, #080h
                STB     A, r2
                L       A, #08000h
knock_result_store:     ST      A, (00150h-00180h)[USP]
                MOVB    off(00241h), r2
                MOV     DP, #003cch
                LB      A, [DP]
                JBS     off(00219h).1, knock_result_store_addb_acc
                LB      A, 0c7h
knock_result_store_addb_acc:     ADDB    A, #080h
                STB     A, r0
                LCB     A, idle_init_start_tbl
                JEQ     knock_result_store_store_stk
                LCB     A, tbl_idle_pi_clamp
                SRLB    A
                CLRB    A
                J       knock_result_store_xchgb_acc
                DB  000h
knock_result_store_store_stk:     STB     A, (00137h-00180h)[USP]
                LB      A, r0
                STB     A, (00141h-00180h)[USP]
                CLRB    A
                MOV     DP, #003cbh
                LCB     A, tbl_idle_pi_clamp
                SRLB    A
                SRLB    A
                SRLB    A
                JGE     knock_result_store_srlb_acc
                LB      A, [DP]
                ADDB    A, #080h
                CLR     er0
                SJ      knock_result_store_store_ram2f1
knock_result_store_srlb_acc:     SRLB    A
                JGE     knock_clear_284
                LB      A, [DP]
                MOVB    r0, #080h
                MULB
                L       A, ACC
                ADD     A, #0c000h
                ST      A, er0
                CLRB    A
knock_result_store_store_ram2f1:     STB     A, off(002f1h)
                MOV     off(00282h), er0
                CLR     A
                LB      A, #076h
                SJ      knock_div_calc3
knock_clear_284:     CLRB    A
                STB     A, off(002f1h)
                EXTND
                ST      A, off(00282h)
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
                JBR     off(00216h).3, knock_div_calc4_if_ram216_bit0_set
                MOV     X1, #knock_div_calc4_tbl
knock_div_calc4_if_ram216_bit0_set:     JBS     off(00216h).0, knock_table2d_lookup
                ADD     X1, #00018h
knock_table2d_lookup:     MOV     X2, X1
                ADD     X1, A
                LC      A, [X1]
                ST      A, er0
                LB      A, r2
                SLLB    A
                EXTND
                ADD     X2, A
                LC      A, [X2]
                AND     IE, #002a0h
                RB      PSWH.0
                ST      A, (00166h-00180h)[USP]
                L       A, er0
                ST      A, (00168h-00180h)[USP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                LB      A, 0c3h
                MOV     X1, #knock_table2d_lookup_tbl
                VCAL    1
                STB     A, (0013ch-00180h)[USP]
                VCAL    4
                MOV     DP, #003beh
                LB      A, [DP]
                STB     A, 0c2h
                JBR     off(00219h).1, injidx_gate2
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #031h
                JNE     injidx_gate1
                SB      off(00223h).7
                SB      off(00219h).0
                RB      off(00223h).3
                SJ      injidx_flag_set
injidx_gate1:     JBR     off(00223h).7, injidx_gate3
injidx_gate2:     RB      off(00223h).7
injidx_flag_clear:     RB      off(00219h).0
                SB      off(00223h).3
injidx_flag_set:     SB      off(00223h).0
                J       vss_ect_stamp
injidx_gate3:     JBS     off(00219h).4, injidx_flag_clear
                JBS     off(0021dh).4, injidx_flag_clear
                LB      A, off(002b6h)
                JEQ     injidx_gate4
                RB      off(00219h).0
                RB      off(00223h).3
injidx_flag_set2:     RB      off(00223h).0
                MOVB    off(002b7h), #064h
                SJ      vss_ect_stamp
injidx_gate4:     JBS     off(00217h).5, injidx_flag_set2
                JBS     off(00219h).0, vss_ect_gate
                JBR     off(00223h).3, injidx_gate6
                JBS     off(00216h).6, injidx_gate5
                JBS     off(00218h).0, vss_ect_gate
injidx_gate5:     JBR     off(0021dh).2, vss_ect_gate
                RB      off(00219h).0
                RB      off(00223h).3
                SB      off(00223h).0
injidx_gate6:     JBR     off(00216h).6, closeloopnarrow_check
                JBS     off(00219h).0, closeloopnarrow_check
                JBS     off(00223h).3, closeloopnarrow_check
                JBS     off(00223h).0, closeloopnarrow_check
                JBR     off(00219h).3, injidx_stamp_c2
                JBR     off(00219h).2, injidx_stamp_c2
                JBS     off(0021dh).2, injidx_c2_check
injidx_stamp_c2:     MOVB    off(002b7h), #064h
                SJ      closeloopnarrow_check
injidx_c2_check:     LB      A, off(002b7h)
                JNE     closeloopnarrow_check
                LB      A, #02eh
                SJ      closeloopnarrow_result
closeloopnarrow_check:     LB      A, #01ah
                JBS     off(00216h).0, closeloopnarrow_result
                LB      A, #01ah
closeloopnarrow_result:     CMPB    A, 0c2h
                JLT     vss_ect_gate
                SB      off(00219h).0
vss_ect_gate:     CMPB    0c1h, #028h
                JGE     vss_ect_stamp
                CMPB    0b4h, #005h
                JGE     vss_ect_stamp
                CMPB    off(00236h), #080h
                JLT     vss_ect_stamp
                JBR     off(0021dh).2, vss_ect_stamp
                LB      A, off(002aah)
                JNE     idle_state_defaults
                SB      off(00219h).0
                RB      off(00223h).3
                SJ      idle_state_defaults
vss_ect_stamp:     MOVB    off(002aah), #004h
idle_state_defaults:     MOVB    r0, #005h
                MOVB    r1, #032h
                MOVB    r2, #032h
                MOVB    r3, #01bh
                JBS     off(00216h).0, idle_state_defaults_if_ram21d_bit1_clr
                MOVB    r3, #01bh
idle_state_defaults_if_ram21d_bit1_clr:     JBR     off(0021dh).1, idle_stage_alt_start
                JBR     off(00218h).0, idle_stage_alt_start
                MOVB    off(002b4h), r1
                MOVB    off(002b5h), r2
                J       idle_state_defaults_if_ram219_bit0_clr
idle_state_defaults_load_stk:     L       A, (00148h-00180h)[USP]
                CMP     A, #0bc15h
                JGE     idle_stage_c0_load_clear_ram219_bit0
                CMP     A, #05e20h
                JLE     idle_stage_c0_load_clear_ram219_bit0
                LB      A, r3
                CMPB    A, 0c2h
                JLT     idle_stage_b7_load
idle_stage_b7_store:     MOVB    off(002abh), r0
idle_stage_b7_load:     LB      A, off(002abh)
                SJ      idle_stage_c0_load_if_ne_goto_gio_fuelpump_dispatch
idle_stage_alt_start:     MOVB    off(002abh), r0
                JBR     off(0021ch).2, idle_stage_c0_start
                MOVB    off(002b5h), r2
                JBR     off(00219h).0, idle_stage_bf_store
                LB      A, r3
                CMPB    A, 0c2h
                JLT     idle_stage_bf_load
idle_stage_bf_store:     MOVB    off(002b4h), r1
idle_stage_bf_load:     LB      A, off(002b4h)
                SJ      idle_stage_c0_load_if_ne_goto_gio_fuelpump_dispatch
idle_stage_c0_start:     MOVB    off(002b4h), r1
                JBR     off(00219h).0, idle_stage_c0_store
                JBR     off(0021ch).6, idle_stage_c0_load
idle_stage_c0_store:     MOVB    off(002b5h), r2
idle_stage_c0_load:     LB      A, off(002b5h)
idle_stage_c0_load_if_ne_goto_gio_fuelpump_dispatch:     JNE     gio_fuelpump_dispatch
idle_stage_c0_load_clear_ram219_bit0:     RB      off(00219h).0
                SB      off(00223h).3
gio_fuelpump_dispatch:     VCAL    4
                RC
                LB      A, off(002bch)
                JNE     fuelpump_relay_drive
                JBS     off(00211h).0, fuelpump_relay_drive
                MB      C, off(00217h).4
fuelpump_relay_drive:     MB      P0.7, C
                JBS     off(00210h).7, fuelpump_state_active_cmp_ram0e9
                JBS     off(00218h).5, fuelpump_state_active
                MOV     DP, #003c9h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     fuelpump_gate4
                CMPB    A, #0fch
                JGE     fuelpump_gate4_rom_load_tbl_6011
fuelpump_gate4:     JBS     off(00230h).6, fuelpump_state_active
fuelpump_gate4_rom_load_tbl_6011:     LCB     A, idle_init_start_tbl
                JEQ     flag_dispatch_221_6_217_4
                LB      A, 0e7h
                JNE     fuelpump_state_active
flag_dispatch_221_6_217_4:     JBS     off(00211h).0, fuelpump_state_store
                JBS     off(00217h).4, fuelpump_state_check
fuelpump_state_store:     STB     A, off(002bch)
fuelpump_state_check:     RC
                LB      A, off(002bch)
                JEQ     fuelpump_state_active_store_carry_p1_bit4
fuelpump_state_active:     SC
fuelpump_state_active_store_carry_p1_bit4:     MB      P1.4, C
fuelpump_state_active_cmp_ram0e9:     CMPB    0e9h, #014h
                JLT     accut_reset_c3
                CMPB    0c1h, #015h
                JGE     rpm_threshold_226_0_if_ram218_bit6_set
                LB      A, #07eh
                JBS     off(00226h).1, rpm_threshold_226_0
                LB      A, #082h
rpm_threshold_226_0:     CMPB    A, 0b4h
                MB      off(00226h).1, C
                JGE     rpm_threshold_226_0_if_ram218_bit6_set
                LB      A, #0c8h
                JBS     off(00226h).0, rpm_threshold_226_0_cmp_acc
                LB      A, #0d0h
rpm_threshold_226_0_cmp_acc:     CMPB    A, off(00236h)
                MB      off(00226h).0, C
                JLT     accut_reset_f7
rpm_threshold_226_0_if_ram218_bit6_set:     JBS     off(00218h).6, accut_check_c3_if_ram211_bit2_clr
                LB      A, #033h
                JBS     off(00226h).3, rpm_threshold_226_0_cmp_acc_2
                LB      A, #080h
rpm_threshold_226_0_cmp_acc_2:     CMPB    A, 0b9h
                MB      off(00226h).3, C
                JLT     accut_check_c3
                LB      A, #010h
                JBS     off(00226h).2, rpm_threshold_226_1
                LB      A, #020h
rpm_threshold_226_1:     CMPB    A, 0b4h
                MB      off(00226h).2, C
                CLRB    A
                JLT     accut_store_c3
                LB      A, #032h
accut_store_c3:     STB     A, off(002b8h)
                SJ      accut_check_c3_if_ram211_bit2_clr
accut_check_c3:     LB      A, off(002b8h)
                JNE     accut_reset_f7
accut_check_c3_if_ram211_bit2_clr:     JBR     off(00211h).2, accut_common
                SB      off(00226h).4
                LB      A, off(002e2h)
                JNE     accut_result_common
                MOVB    off(002e3h), #032h
accut_delay_check:     SB      off(0021bh).0
                RC
                SJ      accut_output_drive
accut_reset_c3:     CLRB    off(002b8h)
accut_reset_f7:     CLRB    off(002e3h)
accut_common:     RB      off(00226h).4
                LB      A, off(002e3h)
                JNE     accut_delay_check
                MOVB    off(002e2h), #032h
accut_result_common:     RB      off(0021bh).0
                SC
accut_output_drive:     MB      P0.0, C
                JBS     off(00217h).5, purge_result_clear
                JBS     off(00212h).5, accut_output_drive_goto_purge_counter_check
                CMPB    0c1h, #035h
                JGE     purge_result_clear
accut_output_drive_goto_purge_counter_check:     J       purge_counter_check
                DW  00000h
purge_counter_check_if_lt_goto_purge_result_clear:     JLT     purge_result_clear
                CMPB    off(002a7h), #005h
                JNE     purge_result_set
                CMPB    off(002c1h), #019h
                JLT     purge_result_clear
purge_result_set:     SC
                SJ      purge_result_clear_goto_vss_band_dispatch
purge_result_clear:     RC
purge_result_clear_goto_vss_band_dispatch:     J       vss_band_dispatch
vss_band_dispatch_load_r2:     MOVB    r2, off(00236h)
                LB      A, #046h
                MOVB    r1, #046h
                JBS     off(00224h).0, vss_band_224_0
                LB      A, #053h
                MOVB    r1, #053h
vss_band_224_0:     JBS     off(00216h).3, vss_band_224_0_check
                LB      A, r1
vss_band_224_0_check:     CMPB    A, r2
                MB      off(00224h).0, C
                MOV     X1, #vss_band_224_0_check_tbl
                MOV     DP, #00224h
                MOV     er0, #00101h
                RB      PSWL.4
                CAL     timer_or_counter_helper
                MOVB    r1, #003h
                MOVB    r2, 0b4h
                CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, 0f7h
                SB      PSWL.4
                CAL     timer_or_counter_helper
                MOVB    r1, #001h
                MOVB    r2, 0c1h
                CAL     timer_or_counter_helper
                JBS     off(00218h).6, vss_band_224_0_check_set_p0_bit3
                JBR     off(00217h).6, vss_band_224_0_check_set_p0_bit3
                JBR     off(00217h).4, state_dispatch2
vss_band_224_0_check_set_p0_bit3:     SB      P0.3
                SB      off(00225h).1
                J       state_result_clear5
state_dispatch2:     JBR     off(00224h).2, state_cce_set2b
                JBS     off(0021ch).2, state_dispatch3
                JBR     off(00216h).3, state_cce_set2b
                JBR     off(0021eh).1, state_cce_set2b
state_dispatch3:     JBR     off(00224h).0, state_cce_set2b
                JBS     off(00224h).4, state_cce_set2
                JBR     off(00224h).7, state_cce_set2
                JBS     off(00225h).0, state_cce_set2
                LB      A, off(002c4h)
                JNE     state_ccf_gate
                MOVB    off(002c5h), #003h
state_ccf_check:     RC
                SJ      state_ccc_set9
state_cce_set2:     MOVB    off(002c4h), #002h
                SC
state_ccc_set9:     MB      P0.3, C
                MOVB    off(002c2h), #005h
                SJ      state_2ba_reset
state_cce_set2b:     MOVB    off(002c4h), #002h
state_ccf_gate:     LB      A, off(002c5h)
                JNE     state_ccf_check
                RC
                JBS     off(00220h).3, state_ccf_gate_store_carry_p0_bit3
                SC
state_ccf_gate_store_carry_p0_bit3:     MB      P0.3, C
                LB      A, off(002c2h)
                JEQ     state_ccc_check
                JBR     off(00225h).0, state_dispatch4
                SJ      state_2ba_reset
state_ccc_check:     JBR     off(00227h).1, flag_dispatch_216_211
                JBR     off(00211h).4, state_ccc_check_load_ram2c7
                MOVB    off(002c7h), #003h
state_ccc_check_load_ram2c7:     LB      A, off(002c7h)
                JEQ     flag_dispatch_216_211
                JBS     off(00224h).6, flag_dispatch_216_211_load_ram2c8_2
flag_dispatch_216_211_load_ram2c8:     MOVB    off(002c8h), #003h
flag_dispatch_216_211_load_ram2c8_2:     LB      A, off(002c8h)
                JEQ     to_state_2ba_reset
                JBR     off(00216h).3, state_ccd_check
                JBS     off(00211h).5, to_state_2ba_reset
state_ccd_check:     LB      A, off(002c3h)
                JNE     state_2ba_reset
                JBS     off(00224h).2, state_ccd_check_clear_ram225_bit0
                JBS     off(00225h).0, state_2ba_reset
state_ccd_check_clear_ram225_bit0:     RB      off(00225h).0
state_dispatch4:     JBS     off(00224h).3, state_225_1_check
                JBS     off(00224h).1, state_225_1_check
                CMPB    0c1h, #029h
                JGE     state_225_1_check
                CMPB    0c0h, #0a9h
                JGE     state_225_1_check
                JBS     off(00211h).2, state_225_1_check
                LB      A, off(002afh)
                JEQ     state_225_1_check
                RB      off(00225h).1
state_result_set5:     SB      P0.2
                SJ      altc_gio_override_check
flag_dispatch_216_211:     JBR     off(00224h).5, flag_dispatch_216_211_load_ram2c8
                MOVB    off(002c3h), #014h
to_state_2ba_reset:     SB      off(00225h).0
state_2ba_reset:     MOVB    off(002afh), #016h
state_225_1_check:     JBS     off(00225h).1, state_2d0_check
                SB      off(00225h).1
                MOVB    off(002c6h), #003h
state_2d0_check:     LB      A, off(002c6h)
                JNE     state_result_set5
                CMPB    off(00297h), #0ffh
                JGT     state_result_set5
state_result_clear5:     RB      P0.2
altc_gio_override_check:     J       altc_gio_override_check_vcal_4
altc_gio_override_check_if_ram216_bit3_clr:     JBR     off(00216h).3, altc_normal_drive
                MOVB    r0, #0feh
                JBS     off(00225h).7, altc_gio_override_check_load_adcr7h
                MOVB    r0, #0ffh
altc_gio_override_check_load_adcr7h:     LB      A, ADCR7H
                CMPB    r0, A
                MB      off(00225h).7, C
                JBR     off(00211h).4, altc_gio_override_check_set_carry
                JBS     off(00212h).6, altc_normal_drive
                CMPB    A, #0fch
                JGE     altc_normal_drive
                CMPB    A, #005h
                JLT     altc_normal_drive
                JBR     off(00225h).7, altc_normal_drive
altc_gio_override_check_set_carry:     SC
                SJ      altc_normal_drive_store_carry_p0_bit5
altc_normal_drive:     RC
altc_normal_drive_store_carry_p0_bit5:     MB      P0.5, C
altc_normal_drive_nop_acc:     NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                JBR     off(00219h).1, flags_b8_2_set
                JBR     off(00216h).6, flags_b8_2_set
                JBR     off(00217h).4, altc_condition_check
flags_b8_2_set:     SB      0a0h.5
                RB      09bh.2
                SJ      gio_p1_2_check
altc_condition_check:     JBS     off(00215h).2, gio_p1_2_check
                JBS     off(00212h).5, gio_p1_2_check
                MB      C, 098h.1
                JLT     gio_p1_2_check
                CMPB    0c1h, #0c5h
                JGE     gio_p1_2_check
                CMPB    0c3h, #0a7h
                JLT     flags_219_2_store
gio_p1_2_check:     RC
                SB      P1.2
flags_219_2_store:     MB      off(00219h).3, C
                JBR     off(00227h).1, flags_219_2_store_clear_acc
                JBS     off(00216h).2, flags_219_2_store_clear_acc
                JBS     off(00218h).6, flags_219_2_store_clear_acc
                JBS     off(0021fh).0, flags_219_2_store_cmp_ram0c0
                LB      A, off(002b1h)
                JNE     flags_219_2_store_clear_carry
flags_219_2_store_clear_acc:     CLRB    A
                SC
                SJ      flags_219_2_store_store_carry_p1_bit6
flags_219_2_store_cmp_ram0c0:     CMPB    0c0h, #001h
                JGE     flags_219_2_store_clear_acc
                CMPB    0c1h, #001h
                JGE     flags_219_2_store_clear_acc
                LB      A, #000h
flags_219_2_store_clear_carry:     RC
flags_219_2_store_store_carry_p1_bit6:     MB      P1.6, C
                STB     A, off(002b1h)
                VCAL    4
                JBS     off(0021ah).6, state_21a_7_dispatch
                NOP
                NOP
                NOP
                CMPB    0adh, #012h
                JGE     state_2fb_reset
                LB      A, 0bfh
                CMPB    A, #030h
                JGT     state_2fb_reset
                CMPB    A, #004h
                JLT     state_2fb_reset
                MB      C, P4.6
                JGE     state_2fb_check
state_2fb_reset:     LB      A, #032h
                STB     A, off(002e7h)
                SJ      state_21a_7_dispatch
state_2fb_check:     LB      A, off(002e7h)
                JNE     state_21a_7_dispatch
                SB      off(0021ah).6
state_21a_7_dispatch:     JBS     off(0021ah).7, state_21a_7_dispatch3
                JBS     off(00217h).5, state_213_0_check
                JBS     off(0021ah).6, state_224_7_check
state_213_0_check:     JBS     off(00213h).0, state_21a_7_set
                SJ      state_224_7_check_load_imm
state_224_7_check:     JBR     off(00223h).6, state_224_7_check_load_imm
                JBR     off(0021dh).4, state_224_7_check_load_ram2d7
state_224_7_check_load_imm:     LB      A, #032h
                STB     A, off(002d7h)
                SJ      state_21a_7_dispatch3
state_224_7_check_load_ram2d7:     LB      A, off(002d7h)
                JNE     state_21a_7_dispatch3
state_21a_7_set:     SB      off(0021ah).7
state_21a_7_dispatch3:     JBS     off(0021ah).7, state_21a_7_dispatch2
                J       state_21a_7_dispatch3_if_ram21a_bit6_clr
state_21a_7_dispatch3_if_ram215_bit1_set:     JBS     off(00215h).1, altc_p46_check
                MB      C, 09bh.1
                JGE     state_2de_reset
altc_p46_check:     MB      C, P4.6
                JGE     state_2de_reset
                JBS     off(00218h).0, state_2de_check
                JBS     off(0021eh).2, state_2de_reset
state_2de_check:     LB      A, off(002d8h)
                JNE     state_21a_7_dispatch2
                SB      off(0021ah).7
                SJ      state_21a_7_dispatch2
state_2de_reset:     LB      A, #033h
                STB     A, off(002d8h)
state_21a_7_dispatch2:     JBS     off(0021ah).7, state_21a_7_dispatch2_load_x1
                J       state_21a_7_dispatch2_if_ram21a_bit6_clr
state_21a_7_dispatch2_load_ram0bf:     LB      A, 0bfh
                CMPB    A, #0fch
                JGT     state_2df_reset
                CMPB    A, #004h
                JLT     state_2df_reset
                JBR     off(00215h).0, state_2df_reset
                JBS     off(00218h).0, state_dc_check2
                JBS     off(0021eh).2, state_2df_reset
state_dc_check2:     CMPB    A, #030h
                JGT     state_2df_check
state_2df_reset:     LB      A, #033h
                STB     A, off(002d9h)
                SJ      state_21a_7_dispatch2_load_x1
state_2df_check:     LB      A, off(002d9h)
                JNE     state_21a_7_dispatch2_load_x1
                SB      off(0021ah).7
state_21a_7_dispatch2_load_x1:     MOV     X1, #state_21a_7_dispatch2_tbl
                LB      A, 0c1h
                VCAL    1
                STB     A, (00144h-00180h)[USP]
                MOVB    r0, #004h
                MOV     DP, #tbl_map_sign
                LB      A, 0c1h
state_21a_7_dispatch2_dec_dp:     DEC     DP
                DECB    r0
                JEQ     state_21a_7_dispatch2_and_ie
                CMPCB   A, [DP]
                JGE     state_21a_7_dispatch2_dec_dp
state_21a_7_dispatch2_and_ie:     AND     IE, #002a0h
                RB      PSWH.0
                LB      A, off(00233h)
                ANDB    A, #0fch
                ORB     A, r0
                STB     A, off(00233h)
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                CMPB    0c0h, #028h
                MB      off(00233h).2, C
                VCAL    4
                JBR     off(00227h).3, state_21a_7_dispatch2_goto_47eb
                JBS     off(00216h).3, state_21a_7_dispatch2_goto_47e7
                RB      off(0022eh).4
                MB      C, off(00211h).5
                MB      off(0022eh).4, C
                JEQ     state_21a_7_dispatch2_store_carry_ram22f_bit3
                XORB    PSWH, #080h
state_21a_7_dispatch2_store_carry_ram22f_bit3:     MB      off(0022fh).3, C
                LB      A, off(002bch)
                JNE     state_21a_7_dispatch2_goto_47e1
                JBR     off(00218h).5, state_21a_7_dispatch2_load_x1_2
state_21a_7_dispatch2_goto_47e7:     J       state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_goto_47e1:     J       state_21a_7_dispatch2_clear_carry
state_21a_7_dispatch2_goto_47eb:     J       state_21a_7_dispatch2_vcal_4
state_21a_7_dispatch2_load_x1_2:     MOV     X1, #state_21a_7_dispatch2_tbl_2
                MOV     DP, #0022dh
                SB      PSWL.4
                MOV     er0, #00400h
                MOVB    r2, 0a6h
                CAL     timer_or_counter_helper
                RB      PSWL.4
                MOVB    r1, #001h
                J       state_21a_7_dispatch2_load_r2
state_21a_7_dispatch2_call_timer_or_counter_helper:     CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, off(00236h)
                CAL     timer_or_counter_helper
                MOV     DP, #0022eh
                MOV     er0, #00300h
                MOVB    r2, 0b4h
                CAL     timer_or_counter_helper
                CMPB    0b4h, #0ffh
                JLT     state_21a_7_dispatch2_load_dp
                CMPB    off(00236h), #0ffh
                JLT     state_21a_7_dispatch2_load_dp
                MOV     DP, #003a4h
                JBS     off(0022fh).3, state_21a_7_dispatch2_clear_dp_ind
                LB      A, off(0024fh)
                INC     DP
                XCHGB   A, [DP]
                CMPB    A, [DP]
                JEQ     state_21a_7_dispatch2_load_dp
                DEC     DP
                LB      A, #0ffh
                INCB    [DP]
                CMPB    A, [DP]
                JGE     state_21a_7_dispatch2_load_dp
                STB     A, [DP]
                SJ      state_21a_7_dispatch2_store_carry_ram22e_bit3
state_21a_7_dispatch2_clear_dp_ind:     CLRB    [DP]
state_21a_7_dispatch2_store_carry_ram22e_bit3:     MB      off(0022eh).3, C
state_21a_7_dispatch2_load_dp:     MOV     DP, #003a7h
                LB      A, [DP]
                CMPB    A, #0ffh
                MB      off(0022eh).5, C
                JGE     state_21a_7_dispatch2_load_imm
                JBS     off(0022eh).6, state_21a_7_dispatch2_store_carry_ram22e_bit7
state_21a_7_dispatch2_load_imm:     LB      A, #0ffh
                CMPB    A, 0a6h
                MB      off(0022eh).6, C
                JLT     state_21a_7_dispatch2_load_ram24f
state_21a_7_dispatch2_store_carry_ram22e_bit7:     MB      off(0022eh).7, C
state_21a_7_dispatch2_load_ram24f:     LB      A, off(0024fh)
                STB     A, r0
                JBS     off(0022dh).1, state_21a_7_dispatch2_load_ram2c9
                MOVB    off(002c9h), #0ffh
state_21a_7_dispatch2_load_ram2c9:     LB      A, off(002c9h)
                JNE     state_21a_7_dispatch2_if_ram22f_bit1_set_2
                JBS     off(0022fh).2, state_21a_7_dispatch2_if_ram22f_bit1_set
                CMPB    r0, #003h
                JNE     state_21a_7_dispatch2_if_ram22f_bit1_set
                SB      off(0022fh).2
state_21a_7_dispatch2_if_ram22f_bit1_set:     JBS     off(0022fh).1, state_21a_7_dispatch2_if_ram22f_bit0_set
                CMPB    r0, #002h
                JNE     state_21a_7_dispatch2_if_ram22f_bit2_clr
                SB      off(0022fh).1
                SJ      state_21a_7_dispatch2_if_ram22f_bit0_set
state_21a_7_dispatch2_if_ram22f_bit1_set_2:     JBS     off(0022fh).1, state_21a_7_dispatch2_if_ram22f_bit0_set
state_21a_7_dispatch2_if_ram22f_bit2_clr:     JBR     off(0022fh).2, state_21a_7_dispatch2_andb_ram22f
state_21a_7_dispatch2_if_ram22f_bit0_set:     JBS     off(0022fh).0, state_21a_7_dispatch2_cmp_r0
                CMPB    r0, #003h
                JLT     state_21a_7_dispatch2_load_ram2ca
                LB      A, off(002cah)
                JNE     state_21a_7_dispatch2_load_ram2cb
                SB      off(0022fh).0
                SJ      state_21a_7_dispatch2_cmp_r0
state_21a_7_dispatch2_load_ram2ca:     MOVB    off(002cah), #0ffh
                SJ      state_21a_7_dispatch2_load_ram2cb
state_21a_7_dispatch2_cmp_r0:     CMPB    r0, #002h
                JNE     state_21a_7_dispatch2_load_ram2cb
                LB      A, off(002cbh)
                JEQ     state_21a_7_dispatch2_andb_ram22f
                SJ      state_21a_7_dispatch2_if_ram22e_bit0_set
state_21a_7_dispatch2_load_ram2cb:     MOVB    off(002cbh), #0ffh
state_21a_7_dispatch2_if_ram22e_bit0_set:     JBS     off(0022eh).0, state_21a_7_dispatch2_clear_x1
state_21a_7_dispatch2_andb_ram22f:     ANDB    off(0022fh), #0f8h
state_21a_7_dispatch2_clear_x1:     CLR     X1
                CMPB    0c1h, #0ffh
                JLT     state_21a_7_dispatch2_load_x1_3
                CMPB    0c0h, #0ffh
                JGE     state_21a_7_dispatch2_load_r0
                JBR     off(0022dh).0, state_21a_7_dispatch2_load_ram2cc
                MOVB    off(002cch), #0ffh
state_21a_7_dispatch2_load_ram2cc:     LB      A, off(002cch)
                MOV     X1, #00004h
                JNE     state_21a_7_dispatch2_load_r0
                SLL     X1
                JBR     off(00216h).0, state_21a_7_dispatch2_load_r0
                JBS     off(00225h).6, state_21a_7_dispatch2_load_r0
                MOV     X1, #0000ch
                SJ      state_21a_7_dispatch2_load_r0
state_21a_7_dispatch2_load_x1_3:     MOV     X1, #00004h
                LB      A, #0ffh
                JBR     off(00225h).6, state_21a_7_dispatch2_if_ram22e_bit7_set
                JBS     off(0022fh).4, state_21a_7_dispatch2_if_ram22e_bit7_set
                JBR     off(0022eh).2, state_21a_7_dispatch2_if_ram22e_bit7_clr
                JBS     off(0022fh).5, state_21a_7_dispatch2_if_ram22e_bit7_clr
                SB      off(0022fh).5
                JBS     off(0022dh).0, state_21a_7_dispatch2_if_ram22e_bit7_clr
                SB      off(0022fh).4
state_21a_7_dispatch2_if_ram22e_bit7_clr:     JBR     off(0022eh).7, state_21a_7_dispatch2_load_r0
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2cc_2
                STB     A, off(002cch)
state_21a_7_dispatch2_load_ram2cc_2:     LB      A, off(002cch)
                JNE     state_21a_7_dispatch2_load_r0
                MOV     X1, #00010h
                SJ      state_21a_7_dispatch2_load_r0
state_21a_7_dispatch2_if_ram22e_bit7_set:     JBS     off(0022eh).7, state_21a_7_dispatch2_if_ram22d_bit2_clr
                JBR     off(00216h).0, state_21a_7_dispatch2_load_r0
                MOV     X1, #00018h
                JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2cc_3
                STB     A, off(002cch)
state_21a_7_dispatch2_load_ram2cc_3:     LB      A, off(002cch)
                JEQ     state_21a_7_dispatch2_load_r0
state_21a_7_dispatch2_load_x1_4:     MOV     X1, #00014h
                SJ      state_21a_7_dispatch2_load_r0
state_21a_7_dispatch2_if_ram22d_bit2_clr:     JBR     off(0022dh).2, state_21a_7_dispatch2_load_ram2cc_4
                STB     A, off(002cch)
state_21a_7_dispatch2_load_ram2cc_4:     LB      A, off(002cch)
                JEQ     state_21a_7_dispatch2_load_x1_5
                JBS     off(00216h).0, state_21a_7_dispatch2_load_x1_4
                SJ      state_21a_7_dispatch2_load_r0
state_21a_7_dispatch2_load_x1_5:     MOV     X1, #0001ch
                JBS     off(00216h).0, state_21a_7_dispatch2_load_r0
                MOV     X1, #00022h
state_21a_7_dispatch2_load_r0:     LB      A, r0
                JEQ     state_21a_7_dispatch2_extnd_acc
                CMPB    A, #005h
                JEQ     state_21a_7_dispatch2_load_ram2cd
                SUBB    A, #001h
state_21a_7_dispatch2_extnd_acc:     EXTND
                ADD     A, X1
                CMP     X1, #0001ch
                JLT     state_21a_7_dispatch2_load_dp_2
                CMPB    r0, #003h
                JLT     state_21a_7_dispatch2_load_dp_2
                JNE     state_21a_7_dispatch2_if_ram22f_bit2_clr_2
                JBR     off(0022fh).1, state_21a_7_dispatch2_load_dp_2
                SJ      state_21a_7_dispatch2_add_acc
state_21a_7_dispatch2_if_ram22f_bit2_clr_2:     JBR     off(0022fh).2, state_21a_7_dispatch2_load_dp_2
state_21a_7_dispatch2_add_acc:     ADD     A, #00002h
state_21a_7_dispatch2_load_dp_2:     MOV     DP, #003a8h
                MOVB    [DP], A
                ADD     A, #state_21a_7_dispatch2_tbl_3
                MOV     DP, A
                CLRB    A
                LCB     A, [DP]
                MOV     DP, #003a9h
                STB     A, [DP]
                SJ      state_21a_7_dispatch2_load_r1
state_21a_7_dispatch2_load_ram2cd:     MOVB    off(002cdh), #0ffh
state_21a_7_dispatch2_load_r1:     MOVB    r1, #0ffh
                JBR     off(0022eh).1, state_21a_7_dispatch2_andb_ram22f_2
                LB      A, off(002cdh)
                JNE     state_21a_7_dispatch2_goto_47e7_2
                SJ      state_21a_7_dispatch2_load_dp_3
state_21a_7_dispatch2_andb_ram22f_2:     ANDB    off(0022fh), #0cfh
state_21a_7_dispatch2_goto_47e7_2:     SJ      state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_load_dp_3:     MOV     DP, #003a9h
                LB      A, [DP]
                JBR     off(0022fh).6, state_21a_7_dispatch2_cmp_acc
                J       state_21a_7_dispatch2_subb_acc
                DB  000h
state_21a_7_dispatch2_cmp_acc:     CMPB    A, 0b4h
                MB      off(0022fh).6, C
                JGE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBS     off(0022dh).4, state_21a_7_dispatch2_load_ram2ce
                MOVB    off(002ceh), #0ffh
state_21a_7_dispatch2_load_ram2ce:     LB      A, off(002ceh)
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBS     off(0022eh).3, state_21a_7_dispatch2_if_ram22d_bit3_set
                JBR     off(00211h).5, state_21a_7_dispatch2_load_ram2cf
                MOVB    off(002cfh), #0ffh
state_21a_7_dispatch2_load_ram2cf:     LB      A, off(002cfh)
                JNE     state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_if_ram22d_bit3_set:     JBS     off(0022dh).3, state_21a_7_dispatch2_load_ram2d0
                MOVB    off(002d0h), #0ffh
                MOVB    off(002d1h), r1
                SJ      state_21a_7_dispatch2_if_ram22d_bit5_clr
state_21a_7_dispatch2_load_ram2d0:     LB      A, off(002d0h)
                JEQ     state_21a_7_dispatch2_if_ram22d_bit5_clr
                JBR     off(0022eh).5, state_21a_7_dispatch2_load_ram2d1
                MOVB    off(002d1h), r1
state_21a_7_dispatch2_load_ram2d1:     LB      A, off(002d1h)
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBR     off(0022dh).6, state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_if_ram22d_bit5_clr:     JBR     off(0022dh).5, state_21a_7_dispatch2_load_ram2d3
                MOVB    off(002d3h), #0ffh
state_21a_7_dispatch2_load_ram2d3:     LB      A, off(002d3h)
                JNE     state_21a_7_dispatch2_if_ram22d_bit7_set
                JBS     off(00211h).4, state_21a_7_dispatch2_set_carry
state_21a_7_dispatch2_clear_carry:     RC
                SJ      state_21a_7_dispatch2_store_carry_p0_bit5
state_21a_7_dispatch2_if_ram22d_bit7_set:     JBS     off(0022dh).7, state_21a_7_dispatch2_clear_carry
state_21a_7_dispatch2_set_carry:     SC
state_21a_7_dispatch2_store_carry_p0_bit5:     MB      P0.5, C
state_21a_7_dispatch2_vcal_4:     VCAL    4
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                MOV     DP, #003c9h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     knock_244_recheck
                CMPB    A, #0fch
                JGE     knock_244_recheck_load_carry_ram214_bit7
knock_244_recheck:     SC
                JBS     off(00230h).6, knock_244_recheck_goto_5937
knock_244_recheck_load_carry_ram214_bit7:     MB      C, off(00214h).7
knock_244_recheck_goto_5937:     J       knock_244_recheck_load_dp_2
                DW  00000h
knock_244_recheck_load_adcr6:     L       A, ADCR6
                ST      A, 0a2h
                LB      A, ADCR7H
                MOV     DP, #00392h
                STB     A, [DP]
                LB      A, ADCR2H
                MOV     DP, #00393h
                STB     A, [DP]
                NOP
                CLRB    A
                J       knock_244_recheck_load_carry_ram211_bit1
knock_244_recheck_rolb_acc:     ROLB    A
                MB      C, off(00211h).7
                ROLB    A
                MB      C, off(00211h).6
                ROLB    A
                MB      C, off(00211h).5
                ROLB    A
                MB      C, off(00211h).4
                ROLB    A
                J       knock_244_recheck_load_carry_ram210_bit3
knock_244_recheck_rolb_acc_2:     ROLB    A
                MB      C, off(00211h).2
                ROLB    A
                MB      C, off(00211h).0
                ROLB    A
                JBS     off(00216h).3, knock_244_recheck_load_dp
                ANDB    A, #08fh
knock_244_recheck_load_dp:     MOV     DP, #0039ch
                STB     A, [DP]
                CLRB    A
                J       knock_244_recheck_load_carry_p4_bit6
knock_244_recheck_rolb_acc_3:     ROLB    A
                ROLB    A
                ROLB    A
                MB      C, off(00210h).7
                ROLB    A
                ROLB    A
                JBR     off(00227h).3, knock_244_recheck_rolb_acc_4
                MB      C, off(00211h).5
knock_244_recheck_rolb_acc_4:     ROLB    A
                ROLB    A
                MOV     DP, #0039dh
                STB     A, [DP]
                CLRB    A
                MOV     DP, #0039eh
                STB     A, [DP]
                NOP
                CLRB    A
                NOP
                MB      C, P1.2
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P1.4
                ROLB    A
                ROLB    A
                MB      C, P1.6
                XORB    PSWH, #080h
                ROLB    A
                J       knock_244_recheck_load_carry_p0_bit1
knock_244_recheck_rolb_acc_5:     ROLB    A
                MB      C, P0.0
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.7
                XORB    PSWH, #080h
                ROLB    A
                MOV     DP, #0039fh
                STB     A, [DP]
                CLRB    A
                J       knock_244_recheck_load_carry_p0_bit5
                DB  000h
knock_244_recheck_nop_acc:     NOP
                NOP
                NOP
                ROLB    A
                ROLB    A
                MB      C, P0.4
                ROLB    A
                MB      C, P1.0
                ROLB    A
                ROLB    A
                MB      C, P0.3
                XORB    PSWH, #080h
                ROLB    A
                J       knock_244_recheck_load_carry_p0_bit2
knock_244_recheck_rolb_acc_6:     ROLB    A
                MOV     DP, #003a0h
                STB     A, [DP]
                CLRB    A
                J       knock_244_recheck_load_carry_p0_bit5_2
                DB  000h
knock_244_recheck_store_dp_ind:     STB     A, [DP]
                CLRB    A
                MOV     DP, #003a2h
                STB     A, [DP]
                CLRB    A
                NOP
                NOP
                NOP
                NOP
                MB      C, off(0021dh).0
                ROLB    A
                MOV     DP, #003a3h
                STB     A, [DP]
                NOP
                MOV     X1, #tbl_diag_snapshot_data1
                MOV     DP, #00394h
diag_snapshot_copy_loop:     LCB     A, [X1]
                MOVB    [DP], A
                INC     X1
                INC     DP
                CMP     X1, #tbl_diag_snapshot_data2
                JNE     diag_snapshot_copy_loop
                MOVB    r0, #040h
                JBR     off(00219h).1, diag_mode_code_store
                MOVB    r0, #020h
                LCB     A, diag_snapshot_copy_loop_tbl_2
                JNE     diag_mode_code_store
                LCB     A, diag_snapshot_copy_loop_tbl
                JEQ     diag_snapshot_copy_loop_load_r0
                LCB     A, diag_snapshot_copy_loop_tbl_3
                JEQ     diag_snapshot_copy_loop_load_r0
                JBS     off(00216h).0, diag_mode_code_store
diag_snapshot_copy_loop_load_r0:     MOVB    r0, #001h
                JBS     off(00216h).2, diag_mode_code_store
                MOVB    r0, #002h
                LCB     A, diag_snapshot_copy_loop_tbl
                JEQ     diag_mode_code_store
                LCB     A, diag_snapshot_copy_loop_tbl_3
                JEQ     diag_snapshot_copy_loop_load_r0_2
                JBR     off(00216h).0, diag_mode_code_store
diag_snapshot_copy_loop_load_r0_2:     MOVB    r0, #008h
                JBR     off(00216h).0, diag_mode_code_store
                MOVB    r0, #010h
                JBR     off(00217h).6, diag_mode_code_store
                MOVB    r0, #004h
diag_mode_code_store:     MOV     DP, #00397h
                LB      A, r0
                STB     A, [DP]
                CLRB    r0
                J       diag_mode_code_store_if_ram216_bit3_clr
                DW  00000h
diag_mode_code_store_rolb_r0:     ROLB    r0
                MB      C, off(00216h).5
                ROLB    r0
                MB      C, off(00227h).4
                ROLB    r0
                MB      C, off(00217h).6
                ROLB    r0
                J       diag_mode_code_store_clear_carry
diag_mode_code_store_sllb_acc:     SLLB    A
                SLLB    A
diag_mode_code_store_rolb_r0_2:     ROLB    r0
                MB      C, off(00216h).3
                ROLB    r0
                MOV     DP, #00398h
                LB      A, r0
                STB     A, [DP]
                NOP
                J       diag_mode_code_store_rom_load_tbl_600c
diag_mode_code_store_if_lt_goto_diag_clamp_ff:     JLT     diag_clamp_ff
                J       diag_mode_code_store_cmp_r0
diag_clamp_ff:     LB      A, #0ffh
                SJ      diag_store_3ad
diag_clamp_acch:     LB      A, ACCH
diag_store_3ad:     MOV     DP, #00399h
                STB     A, [DP]
                MOV     DP, #0030ch
                L       A, [DP]
                SLL     A
                JLT     diag_clamp_ff2
                J       diag_store_3ad_cmp_r0
diag_clamp_ff2:     LB      A, #0ffh
                SJ      diag_clamp_acch2_goto_5ab4
diag_clamp_acch2:     LB      A, ACCH
diag_clamp_acch2_goto_5ab4:     J       diag_clamp_acch2_load_dp
                DB  000h
diag_store_39f_load_dp:     MOV     DP, #0039bh
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
                VCAL    4
                MOV     er1, 098h
                MOV     er2, 09ah
                MB      C, 09fh.1
                JGE     dtc_scan_init
                CLR     A
                ST      A, 098h
                ST      A, 09ah
                ST      A, er1
                ST      A, er2
dtc_scan_init:     MOVB    r7, #001h
                MOV     DP, #002c1h
dtc_scan_loop:     SRL     er2
                ROR     er1
                JLT     dtc_scan_found_check
                LB      A, r7
                SUBB    A, off(002a7h)
                JNE     dtc_scan_f4_check
                STB     A, off(002a7h)
                STB     A, [DP]
dtc_scan_f4_check:     LB      A, r7
                SUBB    A, 0eah
                JNE     dtc_scan_advance
                STB     A, 0eah
dtc_scan_advance:     INCB    r7
                CMPB    r7, #01ch
                JNE     dtc_scan_loop
                SJ      dtc_debounce_init
dtc_scan_found_check:     LB      A, off(002a7h)
                JEQ     dtc_scan_new_code
                CMPB    A, r7
                JNE     dtc_scan_advance
                LB      A, [DP]
                JNE     dtc_debounce_init
                SJ      dtc_debounce2_init
dtc_scan_new_code:     CLR     A
                LB      A, r7
                STB     A, off(002a7h)
                LCB     A, dtc_scan_new_code_tbl[ACC]
                STB     A, [DP]
dtc_debounce_init:     VCAL    4
                MOVB    r7, #021h
                CLR     A
                XCHG    A, 09ch
                JBS     off(0021ch).6, dtc_debounce_mask_apply
                AND     A, #080ffh
dtc_debounce_mask_apply:     ST      A, er0
                MB      C, 09fh.1
                JGE     dtc_debounce_loop_start
                CLR     er0
dtc_debounce_loop_start:     MOV     DP, #001a9h
dtc_debounce_loop:     SRL     er0
                JLT     dtc_debounce_loop_load_dp_ind
                CLR     A
                LB      A, r7
                CMPB    A, 0eah
                JNE     dtc_debounce_advance
                LCB     A, dtc_scan_new_code_tbl[ACC]
                SUBB    A, [DP]
                JNE     dtc_debounce_advance
                STB     A, 0eah
                SJ      dtc_debounce_advance
dtc_debounce_loop_load_dp_ind:     LB      A, [DP]
                JNE     dtc_debounce_loop_decb_dp_ind
                RC
                SJ      dtc_debounce2_init
dtc_debounce_loop_decb_dp_ind:     DECB    [DP]
dtc_debounce_advance:     INC     DP
                INCB    r7
                CMPB    r7, #02ch
                JNE     dtc_debounce_loop
                MOVB    r7, #030h
                MOV     DP, #001b4h
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                SRL     er0
                JLT     dtc_debounce2_check
                MOV     [DP], #00bb3h
                LB      A, 0eah
                SUBB    A, r7
                JNE     dtc_scan_ie_restore_nop_acc
                STB     A, 0eah
                SJ      dtc_scan_ie_restore_nop_acc
dtc_debounce2_check:     L       A, [DP]
                JNE     dtc_scan_ie_restore_nop_acc
dtc_debounce2_init:     LB      A, #005h
                STB     A, [DP]
                LB      A, 0eah
                JNE     dtc_active_confirm
                LB      A, r7
                STB     A, 0eah
                SJ      dtc_scan_ie_restore_nop_acc
dtc_active_confirm:     SUBB    A, r7
                JNE     dtc_scan_ie_restore_nop_acc
                AND     IE, #00080h
                STB     A, 0eah
                CLR     A
                LB      A, r7
                CMPB    A, #030h
                JNE     dtc_active_confirm_rom_load_tbl_6c99_acc
                MOV     (001b4h-00180h)[USP], #00bb3h
                JBR     off(00216h).2, dtc_active_confirm_rom_load_tbl_6c99_acc
                SB      0a0h.0
                SJ      dtc_scan_ie_restore
dtc_active_confirm_rom_load_tbl_6c99_acc:     LCB     A, cfgvariant_index_lookup_tbl[ACC]
                JEQ     dtc_scan_ie_restore
                STB     A, r6
                SB      off(00230h).0
                SB      off(00230h).1
                J       dtc_active_confirm_call_cfgvariant_set_flags
                DB  000h
dtc_active_confirm_if_eq_goto_cfgvariant_apply_done:     JEQ     cfgvariant_apply_done
                CAL     cfgvariant_eval_condition
                CAL     cfgvariant_snapshot_capture
                CAL     cfgvariant_checksum2_calc
                INC     DP
                L       A, er0
                ST      A, [DP]
cfgvariant_apply_done:     RB      off(00230h).0
                RB      off(00230h).1
                CLR     A
                LB      A, r7
                LCB     A, cfgvariant_index_lookup_tbl[ACC]
                CMPB    A, r6
                JNE     selftest_fail_043_checksum
dtc_scan_ie_restore:     L       A, 0f2h
                ST      A, IE
dtc_scan_ie_restore_nop_acc:     NOP
                MOV     DP, #0031eh
                MOV     X1, #00116h
                CLR     er0
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
                CMP     DP, #0031ah
                JNE     calchecksum_loop
                LB      A, [DP]
                ANDB    A, #002h
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
                ANDB    A, #0e8h
                JNE     selftest_fail_043_checksum
                INC     DP
                L       A, [DP]
                CMP     A, er0
                JNE     selftest_fail_043_checksum
                J       calchecksum_loop_vcal_4
calchecksum_loop_inc_dp:     INC     DP
                L       A, [DP]
                CMP     A, er0
                JEQ     freezeframe_decode_start
selftest_fail_043_checksum:     MOVB    0ebh, #043h
                BRK
freezeframe_decode_start:     VCAL    4
                J       freezeframe_decode_start_load_ram212
freezeframe_decode_start_add_acc:     ADD     A, #0ffffh
                MB      off(00218h).6, C
                L       A, off(00212h)
                AND     A, #0fffdh
                JNE     freezeframe_flag_22b_4
                L       A, off(00214h)
                AND     A, #014f5h
                JEQ     prep_lowpower_seq
freezeframe_flag_22b_4:     SB      off(00218h).5
prep_lowpower_seq:     SB      off(00230h).3
                JNE     lowpower_trap_call
                CAL     ResetWatchDog
                L       A, TM1
                ADD     A, #00a00h
                J       prep_lowpower_seq_store_tmr1
                DB  000h
prep_lowpower_seq_load_carry_ram09f_bit1:     MB      C, 09fh.1
                JLT     prep_lowpower_ie_config
                CAL     port_debounce_helper
                MOVB    0edh, #020h
prep_lowpower_ie_config:     MOV     0f4h, #002a0h
                L       A, #02babh
                ST      A, 0f2h
                CLRB    TRNSIT
                CLR     IRQ
                RB      TCON0.2
                ST      A, IE
lowpower_trap_call:     J       regbank_selftest2_start
; [CG] crank_helper2  @0x4B32
; [CG] VERIFIED: entry point that first checks off(120h).2; if set, skips straight to the
; [CG] shared clamp body (injector_timer_schedule). If clear, also bails immediately when
; [CG] off(1BFh)==0x0Fh (an apparent "not yet valid" sentinel).
crank_helper2:     JBR     off(00120h).2, injtimer_shift_path
; [CG] injector_timer_schedule  @0x4B35
; [CG] VERIFIED: clamps a 3-word array based at RAM 0x1C0 to a ceiling of 0xC0 (192), one
; [CG] word at a time. Direct-entry form of crank_helper2.
injector_timer_schedule:     MOVB    r0, #0ffh
                L       A, off(001c6h)
                ST      A, er1
                CMPB    off(001bfh), #00fh
                JNE     injtimer_schedule_done
                J       injector_timer_schedule_load_tm0
injector_timer_schedule_load_dp:     MOV     DP, #001c0h
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
                LB      A, off(001beh)
                SRLB    A
                RORB    off(001beh)
                SJ      injtimer_schedule_common
injtimer_shift_path:     LB      A, off(001b6h)
                SLLB    A
                ROLB    off(001b6h)
                LB      A, off(001beh)
                SLLB    A
                ROLB    off(001beh)
                RT
; [CG] injtimer_bank2_zero  @0x4B76
; [CG] TRACED: substantial routine (~0x150 bytes, 30+ internal branches) directly
; [CG] manipulating TMR0 (ADD TMR0,A - the hardware injector/ignition timer register) using
; [CG] values staged in RAM 0x1B6-0x1BC, decoded through four digital input bits at
; [CG] off(109h).0-3. Calls inj_wrap_clamp_calc twice internally. RAM 0x1B6-0x1BC sits
; [CG] immediately before the 0x1C0 array that injector_timer_schedule/_gated operate on,
; [CG] confirming this is the parent context for that pair - together they form the core
; [CG] injector pulse-width timer-bank assembly.
injtimer_bank2_zero:     ST      A, er1
                LB      A, off(001beh)
                SRLB    A
                RORB    off(001beh)
                SRLB    A
                RORB    off(001beh)
                SJ      injtimer_bank_mask_calc
injtimer_bank3_check:     CLR     A
                ST      A, [DP]
                SJ      injtimer_schedule_done
injtimer_bank1_check2:     ST      A, er1
                LB      A, off(001beh)
                SLLB    A
                ROLB    off(001beh)
                CAL     inj_wrap_clamp_calc
                LB      A, off(001b6h)
                SRLB    A
                SRLB    A
                ANDB    r0, A
injtimer_bank_mask_calc:     CAL     inj_wrap_clamp_calc
                LB      A, off(001b6h)
                SRLB    A
                ANDB    r0, A
injtimer_schedule_common:     CAL     inj_wrap_clamp_calc
                ANDB    r0, off(001b6h)
injtimer_schedule_done:     LB      A, off(001b6h)
                SLLB    A
                ROLB    off(001b6h)
                LB      A, r0
                ANDB    A, off(001b6h)
                CMP     off(001c6h), #000c0h
                JLT     injenable_reset_all
                MOVB    r1, off(001bfh)
                ANDB    off(001bfh), A
                JBS     off(00122h).7, injenable_p2_update
                JBS     off(0011ch).5, injenable_p2_update
                ANDB    off(001b7h), A
                ORB     off(00122h), #001h
injenable_p2_update:     LB      A, off(001b7h)
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
                JBR     off(00109h).1, inj_accum_check2
                JBS     off(00109h).2, inj_accum_check2_if_lt_goto_4c2d
                JBS     off(00109h).3, inj_accum_check2_if_lt_goto_4c2d
                SJ      inj_accum_check4
injenable_reset_all:     LB      A, #00fh
                STB     A, off(001bfh)
                STB     A, off(001b7h)
                ORB     P2, A
                SB      TCON0.2
                LB      A, off(001b6h)
                XORB    A, #0ffh
                MB      C, ACC.7
                ROLB    A
                STB     A, off(001beh)
                RB      TCON0.2
                L       A, #00001h
                SJ      inj_accum1_store_new
inj_accum2_direct:     ADD     A, er1
                ST      A, TMR0
                SJ      inj_p2_calc_start
inj_accum_check1:     JBR     off(00109h).1, inj_accum_check1_if_ram109_bit2_clr
                JBR     off(00109h).2, inj_accum_check1_if_ge_goto_inj_accum_direct_add
                JBR     off(00109h).3, inj_accum_check4
inj_accum_check2_if_lt_goto_4c2d:     JLT     inj_accum_check2_cmp_acc
                ADD     TMR0, A
                SJ      inj_accum_check2_clear_acc
inj_accum_check2_cmp_acc:     CMP     A, #00100h
                JGE     inj_accum1_store_new
inj_accum_check2_clear_acc:     CLR     A
inj_accum1_store_new:     ST      A, off(001b8h)
                L       A, #00001h
                ST      A, off(001bah)
                SJ      inj_accum_store_114
inj_accum_check1_if_ram109_bit2_clr:     JBR     off(00109h).2, inj_accum_check1_if_ge_goto_inj_accum_direct_add
                JBS     off(00109h).3, inj_accum_check4
inj_accum_check1_if_ge_goto_inj_accum_direct_add:     JGE     inj_accum_direct_add
                SUB     A, off(001b8h)
                JLT     inj_accum1_add
                SUB     A, off(001bah)
                JLT     inj_accum_check2_goto_764a
                CMP     A, #00100h
                JGE     inj_accum_store_114
                CLR     A
                SJ      inj_accum_store_114
inj_accum_direct_add:     ADD     TMR0, A
                CLR     A
                ST      A, off(001b8h)
                ST      A, off(001bah)
                SJ      inj_accum_store_114
inj_accum1_add:     J       inj_accum1_add_add_acc
                DB  000h,000h,000h,000h,000h
inj_accum_check2_goto_764a:     J       inj_accum_check2_add_acc
                DB  000h,000h,000h
inj_accum_check2:     JBS     off(00109h).2, inj_accum_check2_if_lt_goto_4c2d
                JBR     off(00109h).3, inj_accum_check1_if_ge_goto_inj_accum_direct_add
inj_accum_check4:     JGE     inj_accum_check4_add_tmr0
                SUB     A, off(001b8h)
                JGE     inj_accum_check4_cmp_acc
                J       inj_accum_check4_add_acc
                DW  00000h
inj_accum_check4_add_tmr0:     ADD     TMR0, A
                CLR     A
                ST      A, off(001b8h)
                SJ      inj_accum2_store2
inj_accum_check4_cmp_acc:     CMP     A, #00100h
                JGE     inj_accum2_store2
inj_accum2_zero2:     CLR     A
inj_accum2_store2:     ST      A, off(001bah)
                L       A, #00001h
inj_accum_store_114:     ST      A, off(001bch)
inj_p2_calc_start:     L       A, off(001b8h)
                JNE     inj_p2_calc_alt
                L       A, off(001bah)
                JEQ     inj_p2_calc_check114
                LB      A, off(001beh)
                SRLB    A
                SRLB    A
                SRLB    A
                ORB     A, off(001beh)
                J       inj_p2_calc_or197
inj_p2_calc_alt:     LB      A, off(001beh)
                SJ      inj_p2_calc_or197
inj_p2_calc_check114:     L       A, off(001bch)
                JEQ     inj_p2_default_f
                LB      A, off(001beh)
                RORB    A
                XORB    A, #0ffh
inj_p2_calc_or197:     ORB     A, off(001b7h)
                ANDB    A, #00fh
inj_p2_drive_return:     ORB     P2, A
                RB      off(00122h).7
                RT
; [CG] inj_p2_default_f  @0x4CBC
; [CG] TRACED: alternate entry that presets A=0x0F then jumps back into inj_wrap_clamp_calc's
; [CG] body (0x4CC0, immediately following) with a different starting value.
inj_p2_default_f:     LB      A, #00fh
                SJ      inj_p2_drive_return
inj_wrap_clamp_calc:     CLR     A
                XCHG    A, [DP]
                MOV     X2, A
                INC     DP
                INC     DP
                L       A, [DP]
                SUB     A, X2
                JLT     inj_wrap_clamp_zero
                CMP     A, #00100h
                JGE     inj_wrap_clamp_store
inj_wrap_clamp_zero:     CLR     A
inj_wrap_clamp_store:     ST      A, 00000h[X1]
                INC     X1
                INC     X1
                RT
knock_helper1:     MOVB    r6, #077h
                JEQ     bitreverse_return
bitreverse_loop:     MB      C, r6.7
                ROLB    r6
                SUBB    A, #001h
                JNE     bitreverse_loop
bitreverse_return:     LB      A, r6
                RT
; [CG] tm0_resync_helper  @0x4CE5
; [CG] VERIFIED: snapshots TMR2 into er3, tests off(10Fh).7/IRQH.0, conditionally increments
; [CG] an event counter at RAM 0xDE, then divides the captured pair by a fixed divisor of 6.
; [CG] Called 3x around the TMR0 crank-edge adjustment code at 0x0601-0x061B.
tm0_resync_helper:     L       A, TMR2
                ST      A, er3
                JBS     off(0010fh).7, rpm_resync_gate
                MB      C, IRQH.0
                JGE     rpm_resync_gate
                INCB    0deh
                SB      09eh.0
rpm_resync_gate:     SB      off(00120h).3
                JEQ     rpm_resync_common
                SUB     A, 0e2h
                JBR     off(00117h).2, rpm_resync_tcon2_check
                CLRB    r1
                MOVB    r0, 0deh
                SBCB    r0, #000h
                MOV     er2, #00006h
                DIV
                CMPB    r0, #000h
                JEQ     rpm_period_reset_calc
                CLR     A
rpm_period_reset_calc:     ST      A, off(0012eh)
                MOV     X1, #0000ch
rpm_period_reset_loop:     DEC     X1
                DEC     X1
                ST      A, 00360h[X1]
                JNE     rpm_period_reset_loop
                SJ      rpm_resync_common
rpm_resync_tcon2_check:     MB      C, TCON2.2
                JGE     rpm_resync_store136
                CLR     A
rpm_resync_store136:     ST      A, off(0012eh)
                LB      A, 0d2h
                SLLB    A
                EXTND
                MOV     X1, A
                L       A, off(0012eh)
                ST      A, 00360h[X1]
rpm_resync_common:     L       A, er3
                ST      A, 0e2h
                CLRB    0deh
                CMPB    0d2h, #005h
                JNE     crank_a3_gate
                SLLB    off(001c9h)
crank_a3_gate:     LB      A, off(0012ah)
                CMPB    A, #002h
                JBS     off(001c9h).2, crank_dp_35e
                JLT     crank_a3_gate_load_dp
                CMPB    A, #013h
                JLE     crank_a3_gate_load_dp_2
crank_a3_gate_load_dp:     MOV     DP, #0035ah
                MB      C, 0a0h.3
                J       crank_pswl4_store
crank_mul_alt:     MULB
crank_mul_alt_mulb_acc:     MULB
                SJ      crank_a2_advance
crank_dp_35e:     MOV     DP, #0035eh
                MB      C, 0a0h.4
                SJ      crank_pswl4_store
crank_a3_gate_load_dp_2:     MOV     DP, #00356h
                MB      C, 0a0h.2
crank_pswl4_store:     MB      PSWL.4, C
                LB      A, 0d2h
                CMPB    A, #004h
                JEQ     crank_mul_alt
                JGE     crank_a0_update
                STB     A, r0
                INCB    r0
                LB      A, 0d0h
                ADDB    A, #001h
                J       crank_pswl4_store_cmp_acc
crank_pswl4_store_if_ram117_bit0_clr:     JBR     off(00117h).0, crank_mul_alt_mulb_acc
crank_a0_update:     L       A, [DP]
                ST      A, 0d0h
                DEC     DP
                LB      A, [DP]
                STB     A, 0cfh
                MB      C, PSWL.4
                MB      off(00122h).5, C
crank_a2_advance:     CLR     A
                MOV     er0, 0d0h
                ST      A, er3
                LB      A, 0d2h
                ADDB    A, #001h
                CMPB    A, r0
                JEQ     crank_mul_common2
                CMPB    A, #006h
                JNE     crank_a2_check3
                LB      A, r0
                JEQ     crank_mul_common2
                SLLB    A
                JLT     crank_mul_common2
crank_a2_check3:     CMPB    0d2h, #003h
                JNE     crank_mul_alt2
                CMPB    r0, #005h
                JNE     crank_mul_alt2
                MOV     er3, off(0012eh)
crank_mul_common2:     CLRB    r0
                L       A, off(0012eh)
                MUL
                LB      A, 0d0h
                SLLB    A
                JGE     crank_mul_common2_load_er3
                RB      PSWH.0
                L       A, TM3
                SUB     A, TMR2
                ADD     A, #00010h
                CMP     A, er1
                JGE     crank_mul_common2_clear_tcon3_bit2
                L       A, TMR2
                ADD     A, er1
                SJ      tmr3_reload_store2
crank_mul_alt2:     MUL
                RB      r0.0
                L       A, ACC
                SJ      tmr3_reload_clamp_min
crank_mul_common2_clear_tcon3_bit2:     RB      TCON3.2
                L       A, TM3
                SUB     A, #00001h
tmr3_reload_store2:     ST      A, TMR3
                RB      TCON3.3
                SB      PSWH.0
                J       tmr3_reload_clamp_min
crank_mul_common2_load_er3:     L       A, er3
                ADD     A, er1
                JGE     tmr3_reload_clamp_check
                L       A, #0ffffh
tmr3_reload_clamp_check:     CMP     A, #0001fh
                JGE     tmr3_store_e8
tmr3_reload_clamp_min:     L       A, #0001fh
tmr3_store_e8:     ST      A, 0e0h
                MOV     DP, #00f00h
                LB      A, [DP]
                SRLB    A
                ROR     off(001d0h)
                SRLB    A
                ROR     off(001d0h)
                LB      A, 0d2h
                JNE     crank_a2_check4
                CLR     A
                XCHG    A, off(001d0h)
                ST      A, 0f0h
crank_a2_check4:     LB      A, 0d2h
                CMPB    A, #001h
                JNE     crank_a8_p1_output
                L       A, 0eeh
                ST      A, off(001ceh)
crank_a8_p1_output:     L       A, off(001ceh)
                SRL     A
                MB      P1.7, C
                SRL     A
                MB      P1.3, C
                ST      A, off(001ceh)
                MOV     DP, #02f00h
                LB      A, P1
                STB     A, [DP]
                RT
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
table_interp_lookup_prescan:     CMPCB   A, [X1]
                JLT     knockretard_r1_store
                LCB     A, [X1]
knockretard_r1_store:     CMPCB   A, 00002h[X1]
                JGE     knockretard_sub_result
                LCB     A, 00002h[X1]
knockretard_sub_result:     MOVB    r0, A
                SJ      table_interp_delta_calc
vcal_0:         CMPCB   A, 00002h[X1]
; --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found
                INC     X1
                INC     X1
                SJ      vcal_0
table_interp_bracket_found:     STB     A, r0
                LCB     A, 00003h[X1]
                STB     A, r6
                LCB     A, 00001h[X1]
                STB     A, r7
table_interp_delta_calc:     LCB     A, 00002h[X1]
                STB     A, r1
                SUBB    r0, A
                LCB     A, [X1]
                SUBB    A, r1
                STB     A, r1
                LB      A, r7
                SUBB    A, r6
                MB      PSWL.4, C
                JGE     table_interp_delta_calc_mulb_acc
                STB     A, r7
                CLRB    A
                SUBB    A, r7
table_interp_delta_calc_mulb_acc:     MULB
                MOVB    r0, r1
                DIVB
                RB      PSWL.4
                JEQ     table_interp_delta_calc_addb_acc
                SUBB    r6, A
                LB      A, r6
                RT
table_interp_delta_calc_addb_acc:     ADDB    A, r6
                STB     A, r6
                RT
vcal_2:         CMPCB   A, [X1]
                JLT     vcal1_bracket_check
                LCB     A, [X1]
vcal1_bracket_check:     CMPCB   A, 00002h[X1]
                JGE     vcal1_bracket_check_goto_table_interp_bracket_found
                LCB     A, 00002h[X1]
vcal1_bracket_check_goto_table_interp_bracket_found:     SJ      table_interp_bracket_found
vcal_3:         CMPCB   A, [X1]
                JLT     vcal2_bracket_check
                LCB     A, [X1]
vcal2_bracket_check:     CMPCB   A, 00003h[X1]
                JGE     vcal2_bracket_check_goto_vcal_common_interp
                LCB     A, 00003h[X1]
vcal2_bracket_check_goto_vcal_common_interp:     SJ      vcal_common_interp
vcal_1:         CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                INC     X1
                INC     X1
                INC     X1
                SJ      vcal_1
vcal_common_interp:     STB     A, r0
                LCB     A, 00003h[X1]
                STB     A, r4
                SUBB    r0, A
                CLRB    r1
                LCB     A, [X1]
                SUBB    A, r4
                STB     A, r4
                CLRB    r5
                CLR     A
                LC      A, 00004h[X1]
                ST      A, er3
                LC      A, 00001h[X1]
injtimer_bank_calc3:     SUB     A, er3
                MB      PSWL.4, C
                JGE     injtimer_bank_calc3_mul_acc
                ST      A, er1
                CLR     A
                SUB     A, er1
injtimer_bank_calc3_mul_acc:     MUL
                MOV     er0, er1
                DIV
                RB      PSWL.4
                JEQ     injtimer_bank_calc3_add_acc
                SUB     er3, A
                L       A, er3
                RT
injtimer_bank_calc3_add_acc:     ADD     A, er3
                ST      A, er3
                RT
; [CG] table_interp_lookup_4byte  @0x4EFE
; [CG] Called 6x; used at 0x0BA6 after a 0x6A79/0x6A89 table select.
table_interp_lookup_4byte:     CMPC    A, 00004h[X1]
                JGE     table_interp_4byte_bracket
                ADD     X1, #00004h
                SJ      table_interp_lookup_4byte
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
                SJ      injtimer_bank_calc3
; [CG] subtract24_clamp_byte  @0x4F21
; [CG] VERIFIED: computes A-24, clamps the result to the unsigned byte range - 0 if the
; [CG] subtraction went negative, 0xFF if it overflowed 255.
subtract24_clamp_byte:     SUBB    A, #018h
                JGE     subtract24_clamp_byte_load_carry_ramacc_bit7
                CLRB    A
                RT
subtract24_clamp_byte_load_carry_ramacc_bit7:     MB      C, ACCH.7
                ROLB    A
                JGE     subtract24_clamp_byte_return
                LB      A, #0ffh
subtract24_clamp_byte_return:     RT
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
                VCAL    7
                SC
injtimer_bank_calc1_mul:     MUL
                ST      A, er0
                L       A, 00002h[X1]
                SJ      injtimer_bank_calc1_sign
; [CG] interp_bracket_delta_scale_2  @0x4F62
; [CG] VERIFIED: structurally identical to injtimer_bank_calc1, operating on the
; [CG] upper breakpoint instead of the lower.
interp_bracket_delta_scale_2:     MOV     er2, 00000h[X1]
                SUB     A, er2
                JGE     interp_bracket_delta_scale_2_mul_acc
                VCAL    7
                SC
interp_bracket_delta_scale_2_mul_acc:     MUL
                ST      A, er0
                MOV     DP, #00388h
                L       A, [DP]
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
                DB  0E2h
vcal_5:         MB      C, ACCH.7
                JLT     vcal_5_add_acc
vcal_6:         ADD     A, er3
                JGE     vcal4_store
                L       A, #0ffffh
                SJ      vcal4_store
vcal_5_add_acc:     ADD     A, er3
                JLT     vcal4_store
                CLR     A
vcal4_store:     ST      A, er3
                RT
                DB  0E2h
; [CG] add_saturate_s16  @0x4F93
; [CG] VERIFIED: adds er3 to A with explicit signed 16-bit saturation - clamps to 0x7FFF on
; [CG] positive overflow, 0x8000 on negative overflow, checking ACCH.7 and r7.7 sign bits
; [CG] before and after the add.
add_saturate_s16:     MB      C, ACCH.7
                JLT     add_saturate_s16_load_carry_r7_bit7
                MB      C, r7.7
                JLT     signext_common_add
                ADD     A, er3
                MB      C, ACCH.7
                JGE     signext_common_add_store_er3
                L       A, #07fffh
                SJ      signext_common_add_store_er3
add_saturate_s16_load_carry_r7_bit7:     MB      C, r7.7
                JGE     signext_common_add
                ADD     A, er3
                MB      C, ACCH.7
                JLT     signext_common_add_store_er3
                L       A, #08000h
                SJ      signext_common_add_store_er3
signext_common_add:     ADD     A, er3
signext_common_add_store_er3:     ST      A, er3
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
vcal_7:         MB      C, PSWH.4
                JGE     vcal_7_xorb_acc
                XORB    A, #0ffh
                BRK
                DB  086h,001h,000h,001h
vcal_7_xorb_acc:     XORB    A, #0ffh
                ADDB    A, #001h
                RT
newval_table3_call_sub_clear_acc:     CLR     A
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
                CAL     table2d_mul_combine
                MOV     er2, X1
                MOV     X1, A
                L       A, DP
                CAL     table2d_mul_combine
                L       A, X1
                MOV     er0, er3
                CAL     table2d_mul_combine
                RT
table2d_mul_combine:     SUB     A, er2
                MB      PSWL.4, C
                JGE     table2d_mul_combine_mul_acc
                ST      A, er1
                CLR     A
                SUB     A, er1
table2d_mul_combine_mul_acc:     MUL
                L       A, er1
                MB      C, PSWL.4
                JGE     table2d_mul_combine_add_acc
                SUB     er2, A
                L       A, er2
                RT
table2d_mul_combine_add_acc:     ADD     A, er2
                ST      A, er2
                RT
knock_244_helper:     EXTND
                ADD     DP, A
                CLR     A
                LCB     A, [DP]
                ST      A, er2
                INC     DP
                LCB     A, [DP]
                CAL     table2d_mul_combine
                LB      A, r4
                RT
; [CG] map_result_postscale  @0x5088
; [CG] Called right after table2d_lookup_interp at 0x1273.
map_result_postscale:     MOVB    r0, off(00137h)
                MOVB    r1, #001h
                CMPB    r0, #080h
                JGE     mul_scale_rotate
                INCB    r1
mul_scale_rotate:     MUL
                LB      A, r2
                L       A, ACC
                SWAP
                SRLB    r3
                ROR     A
                CMPB    r3, #000h
                JEQ     stub_return_short
                L       A, #0ffffh
stub_return_short:     RT
; [CG] sub_clamp_helper  @0x50A5
; [CG] Called 3x; used at 0x16CF.
sub_clamp_helper:     MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     sub_clamp_helper_return
                LB      A, #0ffh
sub_clamp_helper_return:     RT
; [CG] scale_ram1e4_mul_shr2  @0x50B1
; [CG] VERIFIED: multiplies A by RAM word 0x1E4, then shifts the 32-bit product right by 2
; [CG] bits (two SRL/RORB pairs) before falling into mul_zero_if_r3_zero.
scale_ram1e4_mul_shr2:     MOV     er0, off(001e4h)
                MUL
                SRL     er1
                RORB    A
                SRL     er1
                RORB    A
                SJ      mul_zero_if_r3_zero_load_r2
; [CG] mul_zero_if_r3_zero  @0x50BE
; [CG] VERIFIED: performs MUL, then forces the result to 0xFFFF if r3==0 (a "no data"
; [CG] sentinel), otherwise returns the swapped product. Direct-entry form used both
; [CG] standalone and as the tail of scale_ram1e4_mul_shr2.
mul_zero_if_r3_zero:     MUL
mul_zero_if_r3_zero_load_r2:     LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     tipin_table_diff_calc
                L       A, #0ffffh
tipin_table_diff_calc:     RT
idle_stall_helper:     MOV     X2, #00010h
                MOV     DP, #01000h
                SJ      clamp_range_check
injtimer_bank_calc2:     MOV     X2, #fueltbl_range_check_tbl
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
ignition_timing_calc_task_sub_load_er2:     MOV     er2, #00023h
                MOV     er3, #003ffh
                SJ      clamp_to_35_512_cmp_acc
clamp_to_35_512:     MOV     er2, #00023h
                MOV     er3, #00200h
clamp_to_35_512_cmp_acc:     CMP     A, er2
                JLT     load_er0_result
                CMP     A, er3
                JLE     load_er0_result_store_tbl_x1
                MOV     er2, er3
load_er0_result:     L       A, er2
                CLR     er0
load_er0_result_store_tbl_x1:     ST      A, 00000h[X1]
                L       A, er0
                ST      A, [DP]
                RT
sub37_clamp_to_er0:     SUB     A, #00025h
                JLT     sub37_clamp_to_er0_load_er0
                CMP     A, er0
                JGE     sub37_clamp_to_er0_return
sub37_clamp_to_er0_load_er0:     L       A, er0
sub37_clamp_to_er0_return:     RT
add24_clamp_neg1:     ADD     A, #00018h
                JGE     table_index_add_sub_0ce
                L       A, #0ffffh
table_index_add_sub_0ce:     ST      A, er3
                CLR     er1
                LC      A, [X1]
                ST      A, er0
                L       A, 0b6h
                SUB     A, er0
                JLT     table_index_add_clamp_er3
                ST      A, er0
                LC      A, 00004h[X1]
                MUL
table_index_add_clamp_er3:     LC      A, 00002h[X1]
                ADD     A, er1
                CMP     A, er3
                JLT     table_index_add_clamp_er3_return
                L       A, er3
table_index_add_clamp_er3_return:     RT
; [CG] idle_helper2  @0x5141
; [CG] VERIFIED: MUL, then feeds into a shared bounds-check against X1/X2 register-supplied
; [CG] limits (gated by off(20Ch).0) rather than fixed presets.
idle_helper2:     MUL
                L       A, er1
                SJ      mul_then_clamp_x1x2_2_if_ram20c_bit0_clr
; [CG] mul_then_clamp_x1x2_2  @0x5146
; [CG] VERIFIED: identical to idle_helper2 but first zeroes the product if r2==0
; [CG] before entering the same X1/X2 bounds check.
mul_then_clamp_x1x2_2:     MUL
                CMPB    r2, #000h
                JEQ     mul_then_clamp_x1x2_2_if_ram20c_bit0_clr
                L       A, #0ffffh
mul_then_clamp_x1x2_2_if_ram20c_bit0_clr:     JBR     off(0020ch).0, mul_then_clamp_x1x2_2_xchg_acc
                ADD     A, er3
                JLT     idle_helper2_sc_path
idle_pi_clamp_compare:     CMP     A, X1
                JLE     idle_pi_clamp_setcarry
                CMP     X2, A
                JGT     idle_helper2_store
idle_helper2_sc_path:     SC
                L       A, X2
                SJ      idle_helper2_store
mul_then_clamp_x1x2_2_xchg_acc:     XCHG    A, er3
                SUB     A, er3
                JGE     idle_pi_clamp_compare
idle_pi_clamp_setcarry:     L       A, X1
                SC
idle_helper2_store:     ST      A, er3
                RT
; [CG] stub_or_short_helper  @0x516B
; [CG] Called 7x; 4 instructions.
stub_or_short_helper:     L       A, #00700h
                JBS     off(00216h).3, stub_or_short_helper_return
                L       A, #00500h
stub_or_short_helper_return:     RT
idle_pi_clamp_helper:     CMP     off(0028ch), A
                JLT     idle_pi_clamp_low
                CMP     A, off(0028eh)
                JGE     idle_pi_clamp_return
                L       A, off(0028eh)
idle_pi_clamp_return:     RT
idle_pi_clamp_low:     L       A, off(0028ch)
                RT
; [CG] weighted_sum_2term_trim  @0x5184
; [CG] VERIFIED: computes two products (r6*A and r7*X1), conditionally accumulates them into
; [CG] a running total at off(29Ah) gated by PSWL.4, calling clamp_0_to_3ff to bound the
; [CG] running total. A two-term weighted-blend accumulator.
weighted_sum_2term_trim:     MOV     X1, A
                CLRB    r0
                MOVB    r1, r6
                MUL
                MOV     er2, er1
                L       A, X1
                MOVB    r1, r7
                MUL
                L       A, off(0029ah)
                MB      C, PSWL.4
                JLT     weighted_sum_2term_trim_sub_acc
                ADD     A, er1
                CAL     clamp_0_to_3ff
                ST      A, off(0029ah)
                ADD     A, er2
                SJ      weighted_sum_2term_trim_call_clamp_0_to_3ff
weighted_sum_2term_trim_sub_acc:     SUB     A, er1
                CAL     clamp_0_to_3ff
                ST      A, off(0029ah)
                SUB     A, er2
weighted_sum_2term_trim_call_clamp_0_to_3ff:     CAL     clamp_0_to_3ff
                RT
; [CG] clamp_0_to_3ff  @0x51AC
; [CG] VERIFIED: clamps A to the range [0, 0x3FF] (1023). Called from
; [CG] weighted_sum_2term_trim.
clamp_0_to_3ff:     CLR     er0
                JLE     clamp_0_to_3ff_load_er0
                MOV     er0, #003ffh
                CMP     A, er0
                JLT     clamp_0_to_3ff_return
clamp_0_to_3ff_load_er0:     L       A, er0
clamp_0_to_3ff_return:     RT
cfgvariant_set_flags:     SUBB    A, #001h
                MOVB    r0, #008h
                DIVB
                MOV     X1, A
                LB      A, r1
                SBR     00112h[X1]
                SBR     00212h[X1]
                SBR     0031ah[X1]
cfgvariant_checksum_calc:     MOV     DP, #0031ah
                CLR     er0
cfgvariant_checksum_loop:     LB      A, r0
                ADDB    A, [DP]
                STB     A, r0
                LB      A, r1
                XORB    A, [DP]
                STB     A, r1
                INC     DP
                CMP     DP, #0031eh
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
                STB     A, (00110h-00180h)[USP]
                SB      off(00230h).2
                RT
decrement_timer_array:     AND     IE, #002a0h
                RB      PSWH.0
                LB      A, 00000h[X1]
                JEQ     decrement_timer_array_next
                DECB    00000h[X1]
decrement_timer_array_next:     SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                INC     X1
                JRNZ    DP, decrement_timer_array
                RT
ResetWatchDog:     LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                MB      C, 09fh.1
                JLT     resetwatchdog_return
                XORB    P2, #010h
resetwatchdog_return:     RT
ect_step_helper:     ADDB    A, #005h
                JGE     ect_step_range_check
                LB      A, #0ffh
ect_step_range_check:     JBS     off(00217h).4, ect_step_clamp_default
                JBR     off(00230h).3, ect_step_clamp_default
                CMPB    A, off(002a6h)
                JGE     ect_step_return
ect_step_clamp_default:     MOVB    r0, #042h
                CMPB    A, r0
                JGE     ect_step_store
                LB      A, r0
ect_step_store:     STB     A, off(002a6h)
ect_step_return:     RT
ect_smooth_helper:     MOVB    r0, #002h
                SUBB    A, [DP]
                JGE     ect_smooth_sub
                ADDB    A, r0
                SJ      ect_smooth_store
ect_smooth_sub:     SUBB    A, r0
ect_smooth_store:     JGE     ect_smooth_add_store
                CLRB    A
ect_smooth_add_store:     ADDB    A, [DP]
                STB     A, [DP]
                RT
crank_edge_helper:     L       A, off(0011ch)
                ST      A, (0021ch-00280h)[USP]
                L       A, off(0011eh)
                ST      A, (0021eh-00280h)[USP]
                RT
; [CG] refresh_engine_flags_snapshot  @0x5262
; [CG] VERIFIED: copies 5 consecutive words from a USP-relative stack frame (0x212-0x21A)
; [CG] into fixed RAM locations 0x112-0x11A. A pure register/stack snapshot copier, no
; [CG] computation.
refresh_engine_flags_snapshot:     L       A, (00212h-00280h)[USP]
                ST      A, off(00112h)
                L       A, (00214h-00280h)[USP]
                ST      A, off(00114h)
                L       A, (00216h-00280h)[USP]
                ST      A, off(00116h)
                L       A, (00218h-00280h)[USP]
                ST      A, off(00118h)
                L       A, (0021ah-00280h)[USP]
                ST      A, off(0011ah)
                RT
; [CG] timer_or_counter_helper  @0x5277
; [CG] Most-called CAL in the ROM (17 sites).
timer_or_counter_helper:     LB      A, r0
                MBR     C, [DP]
                LC      A, [X1]
                JLT     timer_or_counter_helper_load_carry_pswl_bit4
                LB      A, ACCH
timer_or_counter_helper_load_carry_pswl_bit4:     MB      C, PSWL.4
                JLT     timer_or_counter_helper_cmp_r2
                CMPB    A, r2
                SJ      timer_or_counter_helper_load_r0
timer_or_counter_helper_cmp_r2:     CMPB    r2, A
timer_or_counter_helper_load_r0:     LB      A, r0
                MBR     [DP], C
                INC     X1
                INC     X1
                INCB    r0
                DECB    r1
                JNE     timer_or_counter_helper
                RT
selftest_regbank_verify:     MOV     X2, A
                SB      off(00230h).7
                AND     IE, #002a0h
                RB      PSWH.0
                XCHG    A, 00084h[X1]
                XCHG    A, 00084h[X1]
                ST      A, er3
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                RB      off(00230h).7
                L       A, er3
                CMP     A, X2
                JEQ     selftest_regbank_verify_return
                MOVB    0ebh, #042h
                BRK
selftest_regbank_verify_return:     RT
idle_helper1:     JBR     off(00230h).3, idle_helper1_alt
                AND     IE, #002a0h
                RB      PSWH.0
                L       A, TM2
                SUB     A, off(00256h)
                CMP     A, #000c8h
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                JLT     idle_helper1_return
idle_helper1_alt:     RB      IRQH.4
                JNE     idle_helper1_alt_load_p2
                MOVB    0ebh, #04ah
                BRK
idle_helper1_alt_load_p2:     LB      A, P2
                SWAPB
                SRLB    A
                ANDB    A, #007h
                EXTND
                MOV     X1, A
                LB      A, ADCR1H
                STB     A, 003c6h[X1]
                LB      A, ADCR0H
                STB     A, 003beh[X1]
                AND     IE, #002a0h
                RB      PSWH.0
                ADDB    P2, #020h
                MOV     off(00256h), TM2
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
idle_helper1_return:     RT
selftest_reason_range_check:     CMPB    off(00236h), #00ah
                JLT     empty_stub_return
; [CG] selftest_reason_range_check_entry  @0x530C
; [CG] VERIFIED: identical body to selftest_reason_range_check; this is the direct-entry
; [CG] address used when the caller has already passed the off(236)>=0x0A precondition.
selftest_reason_range_check_entry:     MOV     DP, #003c9h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     selftest_reason_range_check_entry_load_imm
                CMPB    A, #0fch
                JGE     empty_stub_return
                CMPB    A, #088h
                JGT     selftest_reason_range_check_entry_load_imm
                CMPB    A, #078h
                JGE     empty_stub_return
selftest_reason_range_check_entry_load_imm:     LB      A, #049h
                STB     A, 0e7h
                DECB    0edh
                JNE     empty_stub_return
                STB     A, 0ebh
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
                CMPB    0c2h, #01ah
                JLT     cfgvariant_result_common
                INCB    r0
cfgvariant_result_common:     SJ      cfgvariant_eval_result
cfgvariant_check_v3:     CMPB    r6, #003h
; --- cfgvariant_eval_condition's dispatch body: for each specific variant index (3, 6, 7, 10,
; 11, 13, 20, 26), checks the sign of that variant's associated sensor/config byte (0xBB,
; 0x3D4, 0x3A4, 0x3CC, 0x3D2, 0x3CD, 0x3D2 again, 0xD7) and increments r0 if negative --
; reads as a per-variant "is this variant's associated input plausible/connected" check,
; feeding cfgvariant_eval_result.
                JNE     cfgvariant_check_v6
                LB      A, 0a3h
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v6:     CMPB    r6, #006h
                JNE     cfgvariant_check_v7
                MOV     DP, #003c8h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v7:     CMPB    r6, #007h
                JNE     cfgvariant_check_v10
                MOV     DP, #00392h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v10:     CMPB    r6, #00ah
                JNE     cfgvariant_check_v11
                MOV     DP, #003c0h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v11:     CMPB    r6, #00bh
                JNE     cfgvariant_check_v11_cmp_r6
                MOV     DP, #003c6h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v11_cmp_r6:     CMPB    r6, #00ch
                JNE     cfgvariant_check_v13
                CMPB    r7, #009h
                JNE     cfgvariant_check_v13
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v13:     CMPB    r6, #00dh
                JNE     cfgvariant_check_v20
                MOV     DP, #003c1h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v20:     CMPB    r6, #014h
                JNE     cfgvariant_check_v26
                MOV     DP, #003c6h
                LB      A, [DP]
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v26:     CMPB    r6, #01ah
                JNE     cfgvariant_check_v4
                LB      A, ADCR5H
                SLLB    A
                JGE     cfgvariant_eval_result
                INCB    r0
cfgvariant_eval_result:     J       cfgvariant_remap_start
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
cfgvariant_check_v14_29:     CMPB    r6, #00ch
                JNE     cfgvariant_check_v14_29_cmp_r6
                CMPB    r7, #00ah
                JNE     cfgvariant_check_v14_29_cmp_r6
                INCB    r0
                INCB    r0
                SB      off(0021ah).1
                SJ      cfgvariant_eval_result3
cfgvariant_check_v14_29_cmp_r6:     CMPB    r6, #00eh
                JEQ     cfgvariant_eval_result3
                CMPB    r6, #01dh
                JNE     cfgvariant_check_v15_16_21
                L       A, (0ffc7h-0ffffh)[USP]
                CMP     A, #08000h
                JLT     cfgvariant_eval_result3
                INCB    r0
cfgvariant_eval_result3:     SJ      cfgvariant_remap_start
cfgvariant_check_v15_16_21:     CMPB    r6, #00fh
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #010h
                JEQ     cfgvariant_eval_result4
                CMPB    r6, #013h
                JNE     cfgvariant_check_v15_16_21_cmp_r6
                CMPB    r7, #00fh
                JEQ     cfgvariant_eval_result4
                INCB    r0
                SJ      cfgvariant_eval_result4
cfgvariant_check_v15_16_21_cmp_r6:     CMPB    r6, #015h
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
                JNE     cfgvariant_check_v5_16_17_cmp_r6
                J       cfgvariant_check_v5_16_17_cmp_r7
                DB  000h
cfgvariant_check_v5_16_17_incb_r0:     INCB    r0
cfgvariant_check_v5_16_17_goto_cfgvariant_remap_start:     SJ      cfgvariant_remap_start
cfgvariant_check_v5_16_17_cmp_r6:     CMPB    r6, #01fh
                JNE     cfgvariant_check_v1f
                J       cfgvariant_check_v5_16_17_cmp_r7_2
                DB  000h
cfgvariant_check_v5_16_17_incb_r0_2:     INCB    r0
cfgvariant_check_v5_16_17_goto_cfgvariant_remap_start_2:     SJ      cfgvariant_remap_start
cfgvariant_check_v1f:     CMPB    r6, #019h
                JEQ     cfgvariant_remap_start
                MOVB    r1, r6
                RT
; [CG] cfgvariant_remap_start  @0x547E
; [CG] TRACED: a manual compare-chain mapping an internal state code in r6 (0x19, 0x1A, ...)
; [CG] to output fault/reason byte constants (0x23, ...) - a switch-case-style translation
; [CG] table used by the self-test/fault-reporting subsystem.
cfgvariant_remap_start:     CLR     A
                LB      A, r6
                CMPB    A, #019h
                JNE     cfgvariant_remap_1a
                LB      A, #023h
                SJ      cfgvariant_remap_store
cfgvariant_remap_1a:     CMPB    A, #01ah
                JNE     cfgvariant_remap_1b
                LB      A, #024h
                SJ      cfgvariant_remap_store
cfgvariant_remap_1b:     CMPB    A, #01bh
                JNE     cfgvariant_remap_1d
                LB      A, #029h
                SJ      cfgvariant_remap_store
cfgvariant_remap_1d:     CMPB    A, #01dh
                JNE     cfgvariant_remap_store
                LB      A, #02bh
cfgvariant_remap_store:     STB     A, r1
                SRLB    A
                MOV     X1, A
                LB      A, r0
                JGE     cfgvariant_bit_calc
                ADDB    A, #004h
cfgvariant_bit_calc:     SBR     00320h[X1]
                RT
; [CG] cfgvariant_snapshot_capture  @0x54AB
; [CG] VERIFIED: runs once (gated by RAM 0x340==0), then packs several live state bytes - a
; [CG] rotated off(21Dh).0 bit, port snapshots at 0xB4/0xAC, and ADC-buffer copies read via
; [CG] X1=0x3C8/0x3C0 - into a sequential block starting at RAM 0x340. Looks like the
; [CG] construction of a diagnostic/serial report snapshot.
cfgvariant_snapshot_capture:     MOV     DP, #00340h
                LB      A, [DP]
                JNE     cfgvariant_snapshot_return
                LB      A, r1
                ROLB    A
                MB      C, off(0021dh).0
                RORB    A
                STB     A, [DP]
                INC     DP
                LB      A, 0b4h
                STB     A, [DP]
                INC     DP
                L       A, 0ach
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                MOV     X1, #003c8h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #003c0h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0a3h
                STB     A, [DP]
                INC     DP
                MOV     X1, #003c1h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                MOV     X1, #00392h
                LB      A, 00000h[X1]
                STB     A, [DP]
                INC     DP
                LB      A, 0c3h
                STB     A, [DP]
                INC     DP
                MOV     X1, #003d4h
                L       A, 00000h[X1]
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                LB      A, 0c2h
                STB     A, [DP]
                INC     DP
                LB      A, (0ffc8h-0ffffh)[USP]
                STB     A, [DP]
                INC     DP
                LB      A, 0cdh
                STB     A, [DP]
                INC     DP
                LB      A, off(002f5h)
                STB     A, [DP]
cfgvariant_snapshot_return:     RT
cfgvariant_state_reset:     CLR     A
                MOV     DP, #00354h
cfgvariant_state_clear_loop:     DEC     DP
                DEC     DP
                ST      A, [DP]
                CMP     DP, #0031ah
                JGT     cfgvariant_state_clear_loop
                RT
; [CG] cfgvariant_ram_init_0x300  @0x5513
; [CG] VERIFIED: initializes RAM 0x300-0x31xx with default sentinel values (0x8000 words, a
; [CG] 0x7B byte, a 0x332 word). This is exactly the RAM range cfgvariant_checksum2_calc (0x5548)
; [CG] later checksums (0x320-0x34F), so this is that subsystem's initializer.
cfgvariant_ram_init_0x300:     L       A, #08000h
                MOV     DP, #00300h
                ST      A, [DP]
                MOV     DP, #00304h
                ST      A, [DP]
                MOV     DP, #00308h
                ST      A, [DP]
                CAL     stub_or_short_helper
                MOV     DP, #0030ch
                ST      A, [DP]
                CLRB    A
                MOV     DP, #00310h
                STB     A, [DP]
                LB      A, #07bh
                INC     DP
                STB     A, [DP]
                MOV     DP, #00312h
                L       A, #00332h
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                CLR     A
                INC     DP
                INC     DP
                ST      A, [DP]
                INC     DP
                INC     DP
                ST      A, [DP]
                MOVB    off(002f4h), #0ffh
                RT
cfgvariant_checksum2_calc:     MOV     DP, #00320h
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
                CMP     DP, #0034fh
                JNE     cfgvariant_checksum2_loop
                RT
boot_completion_helper:     CLRB    A
                LCB     A, boot_completion_helper_tbl
                SLLB    A
                MB      off(00216h).4, C
                LCB     A, boot_completion_helper_tbl_2
                SLLB    A
                MB      off(00227h).6, C
                LCB     A, boot_completion_helper_tbl_3
                SLLB    A
                MB      off(00216h).6, C
                LCB     A, boot_completion_helper_tbl_4
                SLLB    A
                MB      off(00227h).4, C
                LCB     A, boot_completion_helper_tbl_5
                SLLB    A
                MB      off(00219h).1, C
                LCB     A, boot_completion_helper_tbl_6
                SLLB    A
                MB      off(00217h).3, C
                LCB     A, boot_completion_helper_tbl_7
                SLLB    A
                MB      off(00227h).7, C
                LCB     A, boot_completion_helper_tbl_8
                SLLB    A
                MB      off(00216h).1, C
                LCB     A, boot_completion_helper_tbl_9
                SLLB    A
                MB      off(00216h).7, C
                MOV     DP, #00354h
                MB      [DP].0, C
                LCB     A, boot_completion_helper_tbl_10
                SLLB    A
                MB      off(00227h).1, C
                MOV     DP, #003bfh
                LB      A, [DP]
                STB     A, r1
                J       boot_completion_helper_clear_carry_2
boot_completion_helper_load_dp_ind:     LB      A, [DP]
                STB     A, r2
                J       boot_completion_helper_rom_load_tbl_600f
                DW  00000h
boot_completion_helper_load_r2:     LB      A, r2
                CMPB    r0, #000h
                JEQ     boot_completion_helper_sllb_acc
                LCB     A, boot_completion_helper_tbl_11
boot_completion_helper_sllb_acc:     SLLB    A
                MB      off(00216h).3, C
                CMPB    r0, #000h
                JEQ     boot_completion_helper_clear_carry
                LCB     A, boot_completion_helper_tbl_12
                SLLB    A
                SJ      boot_flag_iabv_common
boot_completion_helper_clear_carry:     RC
                LCB     A, diag_snapshot_copy_loop_tbl
                JNE     boot_flag_iabv_common
                LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h
boot_flag_iabv_common:     MB      off(00216h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_baro_check
                LCB     A, boot_flag_iabv_common_tbl
                SLLB    A
                SJ      boot_flag_baro_common
boot_flag_baro_check:     LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h
boot_flag_baro_common:     MB      off(00216h).0, C
                CMPB    r0, #000h
                JEQ     boot_flag_baro_common_goto_5ee4
                LCB     A, boot_flag_baro_common_tbl
                SLLB    A
                SJ      boot_flag_baro_common_store_carry_ram217_bit6
boot_flag_baro_common_goto_5ee4:     J       boot_flag_baro_common_load_carry_ram216_bit2
                DW  00000h
boot_flag_baro_common_if_eq_goto_561c:     JEQ     boot_flag_baro_common_store_carry_ram217_bit6
                LB      A, r1
                SLLB    A
                XORB    PSWH, #080h
boot_flag_baro_common_store_carry_ram217_bit6:     MB      off(00217h).6, C
                CMPB    r0, #000h
                JEQ     boot_flag_baro_common_clear_carry
                LCB     A, boot_flag_baro_common_tbl_2
                SLLB    A
                SJ      boot_flag_baro_common_store_carry_ram216_bit5
boot_flag_baro_common_clear_carry:     RC
                LCB     A, diag_snapshot_copy_loop_tbl
                JNE     boot_flag_baro_common_store_carry_ram216_bit5
                LB      A, r1
                SLLB    A
boot_flag_baro_common_store_carry_ram216_bit5:     MB      off(00216h).5, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt
                LCB     A, boot_flag_baro_common_tbl_3
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_pswl_bit4
boot_flag_gearpreset_alt:     LB      A, r1
                SLLB    A
                SLLB    A
boot_flag_gearpreset_alt_store_carry_pswl_bit4:     MB      PSWL.4, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt_clear_carry
                LCB     A, boot_flag_gearpreset_alt_tbl_2
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_ram227_bit3
boot_flag_gearpreset_alt_clear_carry:     RC
                LCB     A, boot_flag_gearpreset_alt_tbl
                JEQ     boot_flag_gearpreset_alt_store_carry_ram227_bit3
                MB      C, off(00216h).0
boot_flag_gearpreset_alt_store_carry_ram227_bit3:     MB      off(00227h).3, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt_load_carry_pswl_bit4
                LCB     A, boot_flag_gearpreset_alt_tbl_3
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_ram227_bit2
boot_flag_gearpreset_alt_load_carry_pswl_bit4:     MB      C, PSWL.4
boot_flag_gearpreset_alt_store_carry_ram227_bit2:     MB      off(00227h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt_goto_5953
                LCB     A, boot_flag_gearpreset_alt_tbl_4
                SLLB    A
                SJ      boot_flag_gearpreset_alt_store_carry_ram219_bit4
boot_flag_gearpreset_alt_goto_5953:     J       boot_flag_gearpreset_alt_clear_carry_2
                DB  000h
boot_flag_gearpreset_alt_if_ne_goto_5694:     JNE     boot_flag_gearpreset_alt_load_dp
                NOP
                LCB     A, diag_snapshot_copy_loop_tbl
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4
                LCB     A, diag_snapshot_copy_loop_tbl_3
                JEQ     boot_flag_gearpreset_alt_store_carry_ram219_bit4
                JBR     off(00216h).0, boot_flag_gearpreset_alt_store_carry_ram219_bit4
boot_flag_gearpreset_alt_load_dp:     MOV     DP, #003c6h
                CMPB    [DP], #09ah
boot_flag_gearpreset_alt_store_carry_ram219_bit4:     MB      off(00219h).4, C
                CMPB    r0, #000h
                JEQ     boot_flag_3cf_check
                LCB     A, boot_flag_gearpreset_alt_tbl_5
                SLLB    A
                SJ      boot_flag_final
boot_flag_3cf_check:     MOV     DP, #003c3h
                CMPB    [DP], #080h
                XORB    PSWH, #080h
boot_flag_final:     MOV     DP, #00354h
                MB      [DP].1, C
                NOP
                NOP
                NOP
                RT
revlimit_table_select_if_ram217_bit5_set:     JBS     off(00217h).5, revlimit_table_select_load_stk_3
                JBS     off(00214h).0, revlimit_table_select_goto_3f98
                J       revlimit_table_select_load_stk
revlimit_table_select_load_stk_3:     MOVB    (00189h-00180h)[USP], #00ch
revlimit_table_select_goto_3f98:     J       revlimit_table_select_and_ie
tpsaccel_result_common_clear_acc:     CLRB    A
                CMPB    0c1h, #02eh
                JGE     tpsaccel_result_common_store_ram188
                LB      A, #034h
tpsaccel_result_common_store_ram188:     STB     A, off(00188h)
                J       tpsaccel_ignitioncut_flag_copy
rpm_decel_store_0x14a_cmp_ram12d:     CMPB    off(0012dh), #0ffh
                JGE     rpm_decel_store_0x14a_goto_idle_sub_result_store
                CMPB    0c1h, #0ffh
                J       rpm_decel_store_0x14a_if_lt_goto_idle_sub_result_store
rpm_decel_store_0x14a_goto_idle_sub_result_store:     J       idle_sub_result_store
battery_voltage_store_call_timer_or_counter_helper:     CAL     timer_or_counter_helper
                LB      A, #044h
                JBS     off(00225h).4, battery_voltage_store_cmp_r2
                LB      A, #030h
battery_voltage_store_cmp_r2:     CMPB    r2, A
                MB      off(00225h).4, C
                LB      A, #0b0h
                JBS     off(00225h).5, battery_voltage_store_cmp_acc
                LB      A, #0c0h
battery_voltage_store_cmp_acc:     CMPB    A, 0c5h
                MB      off(00225h).5, C
                J       battery_voltage_store_set_carry
idle_gear_calc_start_load_dp_ind:     L       A, [DP]
                ADD     A, off(00268h)
                JGE     idle_gear_calc_start_goto_idle_gear_result_store
                L       A, #0ffffh
idle_gear_calc_start_goto_idle_gear_result_store:     J       idle_gear_result_store
idle_gear_mul_apply_rol_acc:     ROL     A
                JLT     idle_gear_mul_apply_goto_idle_gear_clamp
                ADD     A, off(00268h)
                JLT     idle_gear_mul_apply_goto_idle_gear_clamp
                J       idle_gear_mul_apply_add_acc
idle_gear_mul_apply_goto_idle_gear_clamp:     J       idle_gear_clamp
idle_gear_result_store_rol_acc:     ROL     A
                JLT     idle_gear_result_store_goto_idle_gear2_clamp
                ADD     A, off(00268h)
                JLT     idle_gear_result_store_goto_idle_gear2_clamp
                J       idle_gear_result_store_add_acc
idle_gear_result_store_goto_idle_gear2_clamp:     J       idle_gear2_clamp
idle_vcal5_call3_if_ram21a_bit0_clr:     JBR     off(0021ah).0, idle_vcal5_call3_goto_30c2
                MB      C, off(00225h).5
                JBR     off(00217h).6, idle_vcal5_call3_if_lt_goto_573e
                MB      C, off(00225h).4
idle_vcal5_call3_if_lt_goto_573e:     JLT     idle_vcal5_call3_goto_30c2
                J       idle_vcal5_call3_goto_5b4f
idle_vcal5_call3_goto_30c2:     J       idle_stall_check2_if_ram217_bit5_clr
idle_stall_diff_calc_load_ram284:     L       A, off(00284h)
                SUB     A, off(00276h)
                JGE     idle_stall_diff_calc_sub_acc
                J       idle_stall_diff_calc_clear_acc
idle_stall_diff_calc_sub_acc:     SUB     A, off(00268h)
                J       idle_stall_diff_calc_if_ge_goto_30bc
state_21a_7_dispatch2_load_r2:     MOVB    r2, off(00235h)
                CAL     timer_or_counter_helper
                MOVB    r1, #001h
                MOVB    r2, 0b9h
                J       state_21a_7_dispatch2_call_timer_or_counter_helper
revlimit_table_select_store_r2:     STB     A, r2
                MOV     X1, #revlimit_table_select_tbl_7
                J       revlimit_table_select_vcal_0
revlimit_table_select_store_r2_2:     STB     A, r2
                MOV     X1, #revlimit_table_select_tbl_12
                J       revlimit_table_select_vcal_0_2
nmi_poll_p4_1_load_p2:     MOVB    P2, #0ffh
                RB      TCON0.2
                SB      TCON0.2
                CLRB    A
                STB     A, ADSCAN
                J       nmi_poll_p4_1_store_adsel
                DB  0F9h,07Eh,032h,0B9h,051h,003h,099h,023h
vcal3_leanprotect_ratelimit_if_ram213_bit3_set:     JBS     off(00213h).3, vcal3_leanprotect_ratelimit_goto_2a17
                JBS     off(00217h).5, vcal3_leanprotect_ratelimit_goto_2a17
                J       vcal3_leanprotect_ratelimit_subb_acc
vcal3_leanprotect_ratelimit_goto_2a17:     J       vcal3_leanprotect_ratelimit_load_ram2db
idle_target_correction_done:     XCHGB   A, r4
                SUBB    r4, A
                JGT     idle_target_correction_done_clear_acc_2
                J       idle_target_correction_done_clear_acc
idle_target_correction_done_clear_acc_2:     CLR     A
                CAL     injtimer_bank_calc3
                J       to_idle_step_condition_dispatch
ignition_timing_calc_task_if_ge_goto_57a2:     JGE     ignition_timing_calc_task_cmp_acc_7
                CLRB    A
ignition_timing_calc_task_cmp_acc_7:     CMPB    A, r5
                MB      off(0022eh).4, C
                J       ignition_timing_calc_task_load_ram0b4
ignition_timing_calc_task_if_ge_goto_57ac:     JGE     ignition_timing_calc_task_cmp_acc_8
                CLRB    A
ignition_timing_calc_task_cmp_acc_8:     CMPB    A, r5
                MB      off(0022eh).6, C
                J       ignition_timing_calc_task_load_ram0b4_2
state_21a_7_dispatch2_subb_acc:     SUBB    A, #0ffh
                JGE     state_21a_7_dispatch2_goto_4795
                CLRB    A
state_21a_7_dispatch2_goto_4795:     J       state_21a_7_dispatch2_cmp_acc
knock_244_recheck_load_carry_p0_bit1:     MB      C, P0.1
                XORB    PSWH, #080h
                J       knock_244_recheck_rolb_acc_5
knock_244_recheck_load_carry_p0_bit5:     MB      C, P0.5
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.6
                J       knock_244_recheck_nop_acc
knock_244_recheck_load_carry_p0_bit2:     MB      C, P0.2
                XORB    PSWH, #080h
                J       knock_244_recheck_rolb_acc_6
diag_mode_code_store_rom_load_tbl_600c:     LCB     A, boot_flag_gearpreset_alt_tbl
                MOVB    r0, A
                L       A, off(0025ch)
                SLL     A
                J       diag_mode_code_store_if_lt_goto_diag_clamp_ff
diag_mode_code_store_cmp_r0:     CMPB    r0, #000h
                JNE     diag_mode_code_store_goto_diag_clamp_acch
                SLL     A
                JGE     diag_mode_code_store_goto_diag_clamp_acch
                J       diag_clamp_ff
diag_mode_code_store_goto_diag_clamp_acch:     J       diag_clamp_acch
diag_store_3ad_cmp_r0:     CMPB    r0, #000h
                JNE     diag_store_3ad_goto_diag_clamp_acch2
                SLL     A
                JGE     diag_store_3ad_goto_diag_clamp_acch2
                J       diag_clamp_ff2
diag_store_3ad_goto_diag_clamp_acch2:     J       diag_clamp_acch2
cfg_selector3_dispatch_cmp_ram280:     CMP     off(00280h), #00700h
                JGE     cfg_selector3_dispatch_goto_2b5a
cfg_selector3_dispatch_cmp_acc:     CMPB    A, r1
                J       cfg_selector3_dispatch_if_ge_goto_idle_ectvs_result3
cfg_selector3_dispatch_goto_2b5a:     J       idle_ectvs_result1_load_r1
overrev_hardcap_compare_load_carry_ram0a0_bit1:     MB      C, 0a0h.1
                JGE     overrev_hardcap_compare_nop_acc
                MOV     X1, #overrev_hardcap_compare_tbl
overrev_hardcap_compare_nop_acc:     NOP
                NOP
                NOP
                JBR     off(00223h).4, overrev_hardcap_compare_load_ram236
                ADD     X1, #0002ch
overrev_hardcap_compare_load_ram236:     LB      A, off(00236h)
                VCAL    0
                J       knockretard2_store
to_vtec_debounce_store_clear_ram0a0_bit1:     RB      0a0h.1
                CMPCB   A, [DP]
                JLE     to_vtec_debounce_store_goto_10fa
                SB      0a0h.1
                ADD     DP, #00004h
                CMPCB   A, [DP]
                JGT     to_vtec_debounce_store_add_dp
to_vtec_debounce_store_goto_10fa:     J       to_vtec_debounce_store_load_imm
to_vtec_debounce_store_add_dp:     ADD     DP, #00004h
                J       to_vtec_debounce_store_incb_r1
to_vtec_debounce_store_if_le_goto_583a:     JLE     to_vtec_debounce_store_goto_10fa
                ADD     DP, #00004h
                J       to_vtec_debounce_store_incb_r1_2
to_vtec_debounce_store_tbl:       DB  04Eh,04Eh,04Eh,04Eh,063h,063h,063h,063h
                DB  077h,077h,077h,077h,08Bh,08Bh,08Bh,08Bh
                DB  0A0h,0A0h,0A0h,0A0h,0B4h,0B4h,0B4h,0B4h
                DB  0C9h,0C9h,0C9h,0C9h
overrev_hardcap_compare_tbl:       DB  0FFh,017h,0F8h,017h,0F0h,031h,0E8h,037h
                DB  0E0h,035h,0D8h,03Ah,0D0h,042h,0C8h,042h
                DB  0C0h,042h,0B0h,042h,0A0h,03Eh,098h,03Ch
                DB  090h,03Ch,088h,037h,080h,038h,070h,033h
                DB  060h,031h,050h,028h,040h,000h,000h,000h
                DB  000h,000h,000h,000h,0FFh,017h,0F8h,017h
                DB  0F0h,024h,0E8h,02Ah,0E0h,029h,0D8h,02Fh
                DB  0D0h,03Ah,0C8h,03Ah,0C0h,03Ah,0B0h,024h
                DB  0A0h,015h,098h,013h,090h,011h,088h,008h
                DB  080h,000h,070h,000h,060h,000h,050h,000h
                DB  040h,000h,000h,000h,000h,000h,000h,000h
dwell_scale_shift_if_ram21d_bit4_clr:     JBR     off(0021dh).4, dwell_scale_shift_call_knock_244_helper
                ADD     DP, #00014h
dwell_scale_shift_call_knock_244_helper:     CAL     knock_244_helper
                J       dwell_scale_shift_store_ram249
state_21a_7_dispatch3_if_ram21a_bit6_clr:     JBR     off(0021ah).6, state_21a_7_dispatch3_goto_state_2de_reset
                JBS     off(00217h).5, state_21a_7_dispatch3_goto_state_2de_reset
                J       state_21a_7_dispatch3_if_ram215_bit1_set
state_21a_7_dispatch3_goto_state_2de_reset:     J       state_2de_reset
state_21a_7_dispatch2_if_ram21a_bit6_clr:     JBR     off(0021ah).6, state_21a_7_dispatch2_goto_state_2df_reset
                JBS     off(00217h).5, state_21a_7_dispatch2_goto_state_2df_reset
                J       state_21a_7_dispatch2_load_ram0bf
state_21a_7_dispatch2_goto_state_2df_reset:     J       state_2df_reset
dwell_scale_shift_tbl:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,020h,03Ah,063h,07Ah
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  01Dh,024h,01Dh,000h,020h,039h,04Ah,066h,084h,088h
ve_result_flag_store_if_ge_goto_5914:     JGE     ve_result_flag_store_goto_165a
                CLRB    A
                J       ve_result_flag_store_load_r4
ve_result_flag_store_goto_165a:     J       ve_result_flag_store_cmp_acch
idle_sub_result_store_store_tbl_x1:     ST      A, 003b4h[X1]
                ST      A, 003d4h[X1]
                J       idle_sub_result_store_goto_1fe6
injtimer_bank_a_calc_if_ram11c_bit5_clr:     JBR     off(0011ch).5, injtimer_bank_a_store
                CLR     A
injtimer_bank_a_store:     MOV     DP, #003d4h
                ST      A, [DP]
                L       A, er3
                MOV     DP, #003ach
                J       injtimer_bank_a_store_load_er0
knock_result_store_xchgb_acc:     XCHGB   A, r0
                JLT     knock_result_store_goto_40c9
                CLRB    A
knock_result_store_goto_40c9:     J       knock_result_store_store_stk
knock_244_recheck_load_dp_2:     MOV     DP, #00320h
                MB      [DP].0, C
                LB      A, [DP]
                ANDB    A, #0f1h
                STB     A, [DP]
                J       knock_244_recheck_load_adcr6
diag_mode_code_store_load_dp:     MOV     DP, #003bfh
                LB      A, [DP]
                J       diag_mode_code_store_sllb_acc
dtc_active_confirm_call_cfgvariant_set_flags:     CAL     cfgvariant_set_flags
                CMPB    r6, #018h
                J       dtc_active_confirm_if_eq_goto_cfgvariant_apply_done
boot_flag_gearpreset_alt_clear_carry_2:     RC
                JBS     off(00217h).6, boot_flag_gearpreset_alt_goto_569a
                LCB     A, diag_snapshot_copy_loop_tbl_2
                J       boot_flag_gearpreset_alt_if_ne_goto_5694
boot_flag_gearpreset_alt_goto_569a:     J       boot_flag_gearpreset_alt_store_carry_ram219_bit4
o2trim_speed_flag_set_if_ram119_bit2_clr:     JBR     off(00119h).2, o2trim_speed_flag_set_goto_o2trim_gate_common2
                JBS     off(0011fh).0, o2trim_speed_flag_set_goto_o2trim_gate_common2
                J       o2trim_speed_flag_set_cmp_ram0c0
o2trim_speed_flag_set_goto_o2trim_gate_common2:     J       o2trim_gate_common2
overrev_hardcap_compare_load_imm_2:     LB      A, #008h
                JBS     off(00223h).4, overrev_hardcap_compare_cmp_acc_2
                LB      A, #015h
overrev_hardcap_compare_cmp_acc_2:     CMPB    A, off(00243h)
                MB      off(00223h).4, C
                CLRB    A
                CMPB    (001cah-00180h)[USP], #001h
                J       overrev_hardcap_compare_if_ne_goto_0c95
tpsaccel_ignitioncut_flag_copy_if_ge_goto_5984:     JGE     tpsaccel_ignitioncut_flag_copy_cmp_acc
                CLRB    A
tpsaccel_ignitioncut_flag_copy_cmp_acc:     CMPB    A, off(0012ch)
                J       tpsaccel_ignitioncut_flag_copy_store_carry_ram126_bit0
tps_hysteresis_store:     MB      off(00126h).7, C
                STB     A, r0
                LB      A, #047h
                JBS     off(00127h).7, tps_hysteresis_flag2
                LB      A, #05ah
tps_hysteresis_flag2:     CMPB    A, r0
                MB      off(00127h).7, C
                LB      A, r0
                JLT     tps_hysteresis_flag2_goto_rpm_threshold_adjust
                JBS     off(00126h).7, tps_hysteresis_flag2_goto_rpm_threshold_adjust
                J       tps_hysteresis_flag2_subb_acc
tps_hysteresis_flag2_goto_rpm_threshold_adjust:     J       rpm_threshold_adjust
fuelcut_tps_recheck_load_ram0a9:     LB      A, 0a9h
                CMPB    A, #060h
                JBS     off(00116h).3, fuelcut_tps_recheck_goto_to_fuelcut_clear_active_flag
                CMPB    A, #010h
fuelcut_tps_recheck_goto_to_fuelcut_clear_active_flag:     J       to_fuelcut_clear_active_flag
rpm_decel_counter_check_load_r1:     MOVB    r1, off(0017eh)
                CMPB    r1, #000h
                J       rpm_decel_counter_check_if_eq_goto_rpm_decel_diff_check2
idle_step_flag_store:     ST      A, off(0026eh)
                L       A, DP
                JBS     off(0021ah).0, idle_step_flag_store_store_ram258
                LB      A, 0c1h
                MOV     X1, #idle_step_flag_store_tbl
                VCAL    1
                MOV     X2, #idle_step_flag_store_tbl_2
idle_step_flag_store_store_ram258:     STB     A, off(00258h)
                MOV     X1, X2
                J       idle_step_flag_store_load_ram0c1
idle_flag_gate_set_ram22b_bit1:     SB      off(0022bh).1
                RB      PSWL.4
                J       idle_flag_gate_if_ram228_bit5_set
idle_flag_gate_set_pswl_bit4:     SB      PSWL.4
                JBR     off(00228h).0, idle_flag_gate_goto_2fbd
                J       idle_mode_gate5
idle_flag_gate_goto_2fbd:     J       idle_mode_gate6_load_ram278
idle_mode_gate6_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_mode_gate6_clear_er3
                JBS     off(00211h).5, idle_mode_gate6_clear_er3
                JBR     off(00228h).3, idle_mode_gate6_clear_er3
                J       idle_mode_gate6_store_er3
idle_mode_gate6_clear_er3:     CLR     er3
                MB      C, PSWL.4
                JGE     idle_mode_gate6_vcal_6
                J       idle_mode_gate6_cmp_ram2dc
                DB  000h
idle_mode_gate6_if_ne_goto_5a02:     JNE     idle_mode_gate6_vcal_6
idle_mode_gate6_goto_5def:     J       idle_mode_gate6_load_x2
                DB  000h
idle_mode_gate6_load_ram2dc:     MOVB    off(002dch), #014h
idle_mode_gate6_vcal_6:     VCAL    6
idle_mode_gate5_store_er3:     ST      A, er3
                MOV     DP, #0030ch
                L       A, [DP]
                J       idle_mode_gate5_vcal_6
idle_stall_check2_if_ge_goto_5a16:     JGE     idle_stall_check2_goto_30c2
                LB      A, off(002dch)
                JNE     idle_stall_check2_goto_30c2
                LB      A, 0a4h
                J       idle_stall_check2_load_x1
idle_stall_check2_goto_30c2:     J       idle_stall_check2_if_ram217_bit5_clr
select_dp_3d9_3d6_flag_222_6:     LB      A, [DP]
                CMPB    A, #0fah
                JGE     select_dp_3d9_3d6_flag_222_6_goto_div_scale_default
                SUBB    A, #007h
                J       select_dp_3d9_3d6_flag_222_6_if_ge_goto_div_scale_calc1
select_dp_3d9_3d6_flag_222_6_goto_div_scale_default:     J       div_scale_default
                DB  0C4h,02Ah,02Bh,0D9h,027h,003h,0C4h,026h
                DB  02Ch,0CAh,003h,003h,080h,02Bh,003h,05Ah
                DB  02Bh
fuelcut_output_flags_load_ram0c4:     LB      A, 0c4h
                CMPB    A, #082h
                JBS     off(00129h).5, tps_hysteresis_reentry
                CMPB    A, #07ah
tps_hysteresis_reentry:     MB      off(00129h).5, C
                ANDB    PSWL, #0cfh
                J       tps_hysteresis_reentry_load_r2
postig_threshold_check2_if_ram117_bit6_clr:     JBR     off(00117h).6, postig_rpm_compare
                MOVB    r0, #032h
                JBS     off(00123h).5, postig_threshold_check3
                MOVB    r0, #050h
postig_threshold_check3:     CMPB    A, r0
                JGE     postig_rpm_compare
                JBS     off(00129h).5, postig_rpm_compare
                SUBB    A, #00ah
                JGE     postig_rpm_compare
                CLRB    A
postig_rpm_compare:     CMPB    A, off(0012dh)
                JGT     postig_rpm_compare_goto_194c
                J       postig_rpm_compare_cmp_ram0c1
postig_rpm_compare_goto_194c:     J       ignmap2_result_check_clear_acc
ignition_timing_calc_task_mul_acc_3:     MUL
                SLL     A
                ROL     er1
                JGE     ignition_timing_calc_task_load_ram29a
                MOV     er1, #0ffffh
ignition_timing_calc_task_load_ram29a:     L       A, off(0029ah)
                J       ignition_timing_calc_task_load_carry_pswl_bit4
                DB  0D5h,0F0h,0D5h,0EEh,0C4h,032h,00Fh,003h
                DB  0FBh,039h
nmi_enter_lowpower_seq_load_ram0eb:     LB      A, 0ebh
                JNE     nmi_enter_lowpower_seq_brk
                MOVB    0ebh, #047h
nmi_enter_lowpower_seq_brk:     BRK
cfgvariant_check_232h_bits01_call_cfgvariant_ram_init_0x:     CAL     cfgvariant_ram_init_0x300
                ANDB    off(00232h), #0fch
                J       restore_trapstate_after_ramclear
knockwindow_gate_start_if_ram218_bit0_set:     JBS     off(00218h).0, knockwindow_gate_start_goto_knockwindow_clear
                CMPB    0b4h, #005h
                JLT     knockwindow_gate_start_goto_3dd8
                MOV     X1, #tbl_ignmap2_hi
                LB      A, off(00236h)
                VCAL    0
                ADDB    A, #010h
                JGE     knockwindow_gate_start_cmp_acc
                LB      A, #0ffh
knockwindow_gate_start_cmp_acc:     CMPB    A, off(00235h)
                JGE     knockwindow_gate_start_goto_knockwindow_clear
knockwindow_gate_start_goto_3dd8:     J       knockwindow_gate_start_load_stk
knockwindow_gate_start_goto_knockwindow_clear:     J       knockwindow_clear
diag_clamp_acch2_load_dp:     MOV     DP, #0039ah
                STB     A, [DP]
                LB      A, 0b4h
                JBR     off(00214h).0, diag_store_39f
                CLRB    A
diag_store_39f:     MOV     DP, #003d6h
                STB     A, [DP]
                J       diag_store_39f_load_dp
callhelper_table_interp_lookup_load_x1:     MOV     X1, #callhelper_table_interp_lookup_tbl
                LB      A, off(00236h)
                VCAL    0
                CMPB    A, 0bbh
                MB      off(00231h).6, C
                L       A, off(00212h)
                AND     A, #08074h
                J       callhelper_table_interp_lookup_if_ne_goto_tipin_gate_fai
tipin_gate_pass_load_ram24f:     LB      A, off(0024fh)
                EXTND
                LCB     A, tbl_5b2e[ACC]
                MOVB    off(0024eh), A
                MOV     X1, #tipin_gate_pass_tbl
                J       tipin_gate_pass_load_ram236
tipin_decay_check_if_ram21b_bit6_set:     JBS     off(0021bh).6, tipin_decay_gate2
                CMP     0aeh, #00010h
                JLT     tipin_decay_gate3
                RB      off(00232h).4
tipin_decay_common:     RC
                SJ      tipin_decay_common_goto_0e1e
tipin_decay_gate2:     CMP     0aeh, #00003h
                JGE     tipin_decay_gate4
tipin_decay_gate3:     JBS     off(00232h).4, tipin_decay_common
tipin_decay_gate3_set_carry:     SC
                SJ      tipin_decay_common_goto_0e1e
tipin_decay_gate4:     SB      off(00232h).4
                SJ      tipin_decay_gate3_set_carry
tipin_decay_common_goto_0e1e:     J       tipin_decay_common_store_carry_ram232_bit5
tipin_gate_fail_clear_ram220_bit0:     RB      off(00220h).0
                RB      off(00232h).4
                J       tipin_decay_zero
dwell_scale_shift_load_ram0b9:     LB      A, 0b9h
                MOV     X1, #dwell_scale_shift_tbl_2
                VCAL    0
                MOVB    r0, off(00237h)
                MULB
                L       A, ACC
                SLL     A
                MOVB    r6, ACCH
                CLRB    r7
                CLR     A
                J       ign_sum_stage1
tbl_5b2e        EQU     $-1
                DB  001h,004h,004h,002h,001h
dwell_scale_shift_tbl_2:       DB  0FFh,080h,04Dh,080h,040h,05Ah,030h,026h
                DB  028h,000h,000h,000h
to_injtimer_store_0x166_cmp_ram0c1:     CMPB    0c1h, #044h
                JLT     to_injtimer_store_0x166_goto_injtimer_gate_common
                JBR     off(00125h).6, to_injtimer_store_0x166_goto_injtimer_gate_common
                J       to_injtimer_store_0x166_if_ram125_bit7_clr
to_injtimer_store_0x166_goto_injtimer_gate_common:     J       injtimer_gate_common
idle_vcal5_call3_load_ram27c:     L       A, off(0027ch)
                JNE     idle_vcal5_call3_goto_30c2_2
                L       A, off(00270h)
                JNE     idle_vcal5_call3_goto_30c2_2
                J       idle_vcal5_call3_goto_5f09
idle_vcal5_call3_goto_30c2_2:     J       idle_stall_check2_if_ram217_bit5_clr
dwell_rpm_gate3_load_r0:     MOVB    r0, off(00173h)
                CMPB    off(0012dh), #080h
                JLT     dwell_rpm_gate3_goto_dwell_value_select
                MOVB    r0, off(001eeh)
dwell_rpm_gate3_goto_dwell_value_select:     J       dwell_value_select
revlimit_table_select_store_r2_3:     STB     A, r2
                MOV     X1, #revlimit_table_select_tbl
                JBS     off(00216h).3, revlimit_table_select_vcal_0_5
                MOV     X1, #revlimit_table_select_tbl_2
revlimit_table_select_vcal_0_5:     VCAL    0
                STB     A, (001eeh-00180h)[USP]
                LB      A, r2
                MOV     X1, #revlimit_table_select_tbl_10
                J       revlimit_table_select_vcal_1
revlimit_table_select_tbl:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,018h,000h,018h
revlimit_table_select_tbl_2:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,014h,000h,014h
postfuel_hyst_lower_calc_call_clamp_diff_15b_1ec:     CAL     clamp_diff_15b_1ec
                J       cylinder_ign_correct_apply_goto_5c43
to_injtimer_sub_common:     LB      A, #040h
                JBS     off(00129h).3, to_injtimer_sub_common_cmp_acc_2
                LB      A, #04dh
to_injtimer_sub_common_cmp_acc_2:     CMPB    A, off(0012dh)
                MB      off(00129h).3, C
                LB      A, #0f2h
                JBS     off(00129h).4, to_injtimer_sub_common_cmp_acc_3
                LB      A, #0f9h
to_injtimer_sub_common_cmp_acc_3:     CMPB    A, off(0012ch)
                MB      off(00129h).4, C
                LB      A, off(0015eh)
                JBS     off(0011dh).4, to_injtimer_sub_common_goto_1c97
                J       to_injtimer_sub_common_load_imm
to_injtimer_sub_common_goto_1c97:     J       to_injtimer_sub_common_store_ram153
to_injtimer_sub_common_store_r7:     STB     A, r7
                JBS     off(0011dh).0, to_injtimer_sub_common_load_ram12c
                CMP     off(0014ah), #03000h
                JGE     to_injtimer_sub_common_call_clamp_diff_15b_1ec
                JBR     off(00129h).3, to_injtimer_sub_common_call_clamp_diff_15b_1ec
                JBS     off(00129h).4, to_injtimer_sub_common_call_clamp_diff_15b_1ec
                LB      A, 0a8h
                JBR     off(0011bh).4, to_injtimer_sub_common_if_ram11b_bit1_clr
                CMPB    A, #003h
                JGE     to_injtimer_sub_common_call_clamp_diff_15b_1ec
to_injtimer_sub_common_if_ram11b_bit1_clr:     JBR     off(0011bh).1, to_injtimer_sub_common_load_ram1ed
                LB      A, #004h
                JBS     off(00116h).3, to_injtimer_sub_common_cmp_acc_4
                LB      A, #004h
to_injtimer_sub_common_cmp_acc_4:     CMPB    A, 0bdh
                JGE     to_injtimer_sub_common_load_ram1ed
to_injtimer_sub_common_call_clamp_diff_15b_1ec:     CAL     clamp_diff_15b_1ec
                SJ      to_injtimer_sub_common_load_ram12c
to_injtimer_sub_common_load_ram1ed:     LB      A, off(001edh)
                MOVB    r0, #0fah
                MULB
                LB      A, ACCH
                STB     A, off(001edh)
                ADDB    A, off(001ech)
                STB     A, r7
to_injtimer_sub_common_load_ram12c:     LB      A, off(0012ch)
                J       to_injtimer_sub_common_call_table_interp_lookup_prescan
revlimit_table_select_vcal_1_2:     VCAL    1
                STB     A, (001e8h-00180h)[USP]
                LB      A, 0c1h
                MOV     X1, #revlimit_table_select_tbl_3
                VCAL    0
                STB     A, (001ech-00180h)[USP]
                J       revlimit_table_select_vcal_4
clamp_diff_15b_1ec:     LB      A, off(0015bh)
                SUBB    A, off(001ech)
                JGE     clamp_diff_15b_1ec_store_ram1ed
                CLRB    A
clamp_diff_15b_1ec_store_ram1ed:     STB     A, off(001edh)
                RT
revlimit_table_select_tbl_3:       DB  0FFh,060h,0E6h,052h,0CFh,051h,0A1h,050h
                DB  044h,041h,028h,040h,000h,040h
o2_trim_dp304_calc_load_imm:     L       A, #08000h
                MOV     er1, #08000h
                JBS     off(00116h).3, o2_trim_dp304_calc_cmp_ram0c1
                L       A, #08000h
                MOV     er1, #08000h
o2_trim_dp304_calc_cmp_ram0c1:     CMPB    0c1h, #040h
                J       o2_trim_dp304_calc_if_lt_goto_o2_trim_mul_apply
cylinder_ign_correct_apply_load_imm_2:     LB      A, #0c5h
                JBS     off(00124h).5, cylinder_ign_correct_apply_cmp_acc
                LB      A, #0c8h
cylinder_ign_correct_apply_cmp_acc:     CMPB    A, off(0012dh)
                MB      off(00124h).5, C
                LB      A, off(00135h)
                JNE     cylinder_ign_correct_apply_goto_deadtime_retry_check
                J       cylinder_ign_correct_apply_load_imm
cylinder_ign_correct_apply_goto_deadtime_retry_check:     J       deadtime_retry_check
to_gio_mode_dispatch_subb_acc:     SUBB    A, r6
                JGE     to_gio_mode_dispatch_if_ram124_bit5_set
                J       injector_effective_pw_skip
to_gio_mode_dispatch_if_ram124_bit5_set:     JBS     off(00124h).5, injector_effective_pw_calc
                MOVB    r6, off(00133h)
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
injector_effective_pw_calc:     J       injector_effective_pw_store
                DB  0D9h,01Bh,007h,0C5h,0BDh,0C0h,020h,003h
                DB  079h,033h,003h,07Bh,033h
tipin_decay_store_store_carry_ram220_bit1:     MB      off(00220h).1, C
                LB      A, #000h
                JBS     off(00225h).3, knock244_threshold_check
                LB      A, #00bh
knock244_threshold_check:     CMPB    A, off(00243h)
                MB      off(00225h).3, C
                MOVB    r0, #040h
                MOVB    r1, #003h
                MOVB    r2, #02ah
                MOVB    r3, #00ch
                JGE     dwellbase_gate1
                MOVB    r0, #040h
                MOVB    r1, #006h
                MOVB    r2, #033h
                MOVB    r3, #00ch
dwellbase_gate1:     JBS     off(00212h).6, gate_255_common
                JBS     off(0021dh).4, gate_255_common
                CMPB    0c1h, #034h
                JGE     gate_255_common
                LB      A, r0
                CMPB    A, off(00236h)
                JLT     gate_255_common
                JBS     off(00231h).6, gate_255_common
                CLRB    A
                JBR     off(0021bh).1, store_255_result
                CMPB    0bdh, #020h
                JLT     store_255_result
                LB      A, r1
                ADDB    A, #001h
store_255_result:     STB     A, off(002fbh)
gate_255_common:     LB      A, r2
                CMPB    off(002fbh), #000h
                JNE     gate_255_common_decb_ram2fb
                LB      A, off(002fah)
                SUBB    A, r3
                JGE     gate_255_common_store_ram2fa
                CLRB    A
                SJ      gate_255_common_store_ram2fa
gate_255_common_decb_ram2fb:     DECB    off(002fbh)
gate_255_common_store_ram2fa:     STB     A, off(002fah)
                J       gate_255_common_if_ram216_bit3_set
ign_sum_stage1_load_ram2fa:     LB      A, off(002fah)
                ADD     er3, A
                L       A, er3
                VCAL    7
                ST      A, er3
                J       ign_sum_negate
idle_integrator_final_store_if_ram211_bit5_clr:     JBR     off(00211h).5, idle_integrator_final_store_goto_2d1e
                CMPB    0c1h, #03ah
                JLT     idle_integrator_final_store_clear_acc
                L       A, off(00264h)
                SUB     A, #00040h
                JGE     idle_integrator_final_store_goto_idle_output_finalize
idle_integrator_final_store_clear_acc:     CLR     A
                J       to_idle_output_finalize
idle_integrator_final_store_goto_idle_output_finalize:     J       idle_output_finalize
idle_integrator_final_store_goto_2d1e:     J       idle_integrator_final_store_cmp_ram0c1
idle_sub_gate2_if_ram216_bit3_set:     JBS     off(00216h).3, idle_sub_gate2_cmp_acc_2
                JBR     off(0021ah).3, idle_sub_gate2_cmp_acc_2
                JBR     off(00218h).2, idle_sub_gate2_cmp_acc_2
                MOV     X1, #00a00h
                JBR     off(00211h).2, idle_sub_gate2_cmp_acc
                MOV     X1, #00b00h
idle_sub_gate2_cmp_acc:     CMP     A, X1
                JGE     idle_sub_gate2_cmp_acc_2
                L       A, X1
idle_sub_gate2_cmp_acc_2:     CMP     A, DP
                JLT     idle_sub_gate2_goto_2dca
                J       idle_sub_alt_path
idle_sub_gate2_goto_2dca:     J       idle_sub_alt_path_store_ram262
idle_timer_gate1_if_ram218_bit2_clr:     JBR     off(00218h).2, idle_timer_gate1_goto_idle_timer_gate_common
                CLRB    off(002d6h)
                MOVB    r0, #028h
                J       idle_timer_gate1_if_ram21a_bit5_set
idle_timer_gate1_goto_idle_timer_gate_common:     J       idle_timer_gate_common
idle_table_lookup3_load_ram258:     L       A, off(00258h)
                CAL     table_interp_lookup_4byte
                CMP     A, 0b2h
                J       idle_table_lookup3_if_lt_goto_idle_table_lookup4
tbl_idle_default1:       DB  0FFh,0FFh,06Bh,000h,035h,00Ch,06Bh,000h
                DB  0C4h,009h,044h,000h,00Bh,009h,03Ah,000h
                DB  053h,007h,026h,000h,04Eh,004h,00Eh,000h
                DB  000h,000h,00Eh,000h
tbl_idle_default2:       DB  0FFh,0FFh,095h,000h,035h,00Ch,095h,000h
                DB  0C4h,009h,061h,000h,00Bh,009h,053h,000h
                DB  053h,007h,037h,000h,04Eh,004h,013h,000h
                DB  000h,000h,013h,000h
idle_table_lookup4_load_x1:     MOV     X1, #idle_table_lookup4_tbl
                L       A, off(00258h)
                CAL     table_interp_lookup_4byte
                J       idle_table_lookup4_if_ram21a_bit5_clr
idle_table_lookup4_tbl:       DB  0FFh,0FFh,0F1h,000h,035h,00Ch,0F1h,000h
                DB  0C4h,009h,09Dh,000h,00Bh,009h,087h,000h
                DB  053h,007h,05Ah,000h,04Eh,004h,01Fh,000h
                DB  000h,000h,01Fh,000h
tps_interp_store_load_er0:     MOV     er0, #00300h
                JGE     rpm_avg_range_check
                VCAL    7
                MOV     er0, #00300h
rpm_avg_range_check:     CMP     A, er0
                JLT     rpm_avg_range_check_goto_09b5
                L       A, er0
rpm_avg_range_check_goto_09b5:     J       rpm_avg_range_check_store_ram0b2
idle_flag_gate_load_ram2dc:     LB      A, off(002dch)
                JNE     idle_flag_gate_load_ram286
                RB      off(00222h).7
idle_flag_gate_load_ram286:     MOV     off(00286h), off(00284h)
                J       idle_flag_gate_load_ram289
idle_mode_gate6_if_ram22b_bit3_clr:     JBR     off(0022bh).3, idle_mode_gate6_goto_idle_pi_mul1
                CMPB    0c1h, #0d0h
                JLT     idle_mode_gate6_goto_2fba
                CMPB    0e9h, #0fah
                JLT     idle_mode_gate6_goto_idle_pi_mul1
idle_mode_gate6_goto_2fba:     J       idle_mode_gate6_if_ram229_bit6_clr
idle_mode_gate6_goto_idle_pi_mul1:     J       idle_pi_mul1
idle_mode_gate6_cmp_ram2dc:     CMPB    off(002dch), #000h
                JEQ     idle_mode_gate6_goto_59fa
                SB      off(00222h).7
                J       idle_mode_gate6_if_ne_goto_5a02
idle_mode_gate6_goto_59fa:     J       idle_mode_gate6_goto_5def
idle_mode_gate6_load_x2:     MOV     X2, A
                LB      A, 0c0h
                MOV     X1, #idle_mode_gate6_tbl
                CAL     vcal_1
                L       A, X2
                J       idle_mode_gate6_load_ram2dc
idle_mode_gate6_tbl:       DB  0FFh,000h,000h,0C0h,000h,000h,0A0h,040h
                DB  001h,080h,080h,001h,030h,000h,002h,000h
                DB  000h,003h
battery_voltage_check_store_carry_ram21a_bit3:     MB      off(0021ah).3, C
                LB      A, 0c4h
                STB     A, r0
                XCHGB   A, 0f8h
                SUBB    A, r0
                MB      off(00225h).2, C
                JGE     battery_voltage_store
                VCAL    7
battery_voltage_store:     STB     A, 0f9h
battery_voltage_store_goto_2ab1:       J       battery_voltage_store_load_x1
idle_pid_mul_apply_store_r1:     STB     A, r1
                MOV     X1, #idle_pid_mul_apply_tbl
                LB      A, 0c1h
                VCAL    0
                STB     A, r1
                CLRB    r0
                L       A, er1
                MUL
                ROL     A
                L       A, er1
                ROL     A
                JGE     idle_pid_mul_apply_p02_check
                L       A, #0ffffh
idle_pid_mul_apply_p02_check:     MB      C, P0.2
                J       idle_pid_mul_apply_resume
idle_pid_mul_apply_tbl:       DB  0FFh,0C0h,0A1h,0C0h,044h,0A0h,028h,080h,000h,080h
idle_pid_recheck2_if_ram217_bit6_clr:     JBR     off(00217h).6, idle_pid_hyst_check
                LB      A, #028h
                CLRB    r1
                JBS     off(00225h).2, idle_pid_hyst_calc
                LB      A, #028h
                MOVB    r1, #000h
idle_pid_hyst_calc:     MOVB    r2, 0f9h
                     MB      C, off(00225h).2
idle_pid_hyst_check:     MB      PSWL.4, C
                CMPB    A, r2
                J       idle_pid_hyst_check_if_ge_goto_idle_pid_common
idle_pid_hyst_check_load_carry_pswl_bit4:     MB      C, PSWL.4
                JLT     idle_pid_p0_check
                LB      A, off(00297h)
                JEQ     idle_pid_flag_store
                SJ      idle_pid_flag_store_goto_idle_pid_flag_clear
idle_pid_p0_check:     MB      C, P0.2
                JLT     idle_pid_flag_store_goto_idle_pid_flag_clear
idle_pid_flag_store:     MOVB    off(00297h), r1
idle_pid_flag_store_goto_idle_pid_flag_clear:     J       idle_pid_flag_clear
idle_ectvs_result1:     JBR     off(00227h).1, idle_ectvs_result1_if_ram22a_bit3_clr
                JBR     off(00226h).4, idle_ectvs_result1_goto_2b80
                SJ      idle_ectvs_result1_goto_2b5a
idle_ectvs_result1_if_ram22a_bit3_clr:     JBR     off(0022ah).3, idle_ectvs_result1_if_ram225_bit1_clr
                MOVB    off(002ddh), #014h
                MOVB    off(002deh), #05ah
idle_ectvs_result1_goto_2b5a:     J       idle_ectvs_result1_load_r1
idle_ectvs_result1_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_result1_goto_2b80
                LB      A, off(002ddh)
                JNE     idle_ectvs_result1_goto_2b5a
idle_ectvs_result1_goto_2b80:     J       idle_ectvs_result1_cmp_acc
idle_ectvs_flag_check_if_ram22a_bit4_clr:     JBR     off(0022ah).4, idle_ectvs_flag_check_if_ram225_bit1_clr
                MOVB    off(002deh), #05ah
idle_ectvs_flag_check_goto_idle_ectvs_result2:     J       idle_ectvs_result2
idle_ectvs_flag_check_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_flag_check_goto_2b92
                LB      A, off(002deh)
                JNE     idle_ectvs_flag_check_goto_idle_ectvs_result2
idle_ectvs_flag_check_goto_2b92:     J       idle_ectvs_flag_check_if_ram216_bit3_clr
knock_244_recheck_load_carry_ram211_bit1:     MB      C, off(00211h).1
                XORB    PSWH, #080h
                J       knock_244_recheck_rolb_acc
knock_244_recheck_load_carry_ram210_bit3:     MB      C, off(00210h).3
                XORB    PSWH, #080h
                J       knock_244_recheck_rolb_acc_2
knock_244_recheck_load_carry_p4_bit6:     MB      C, P4.6
                XORB    PSWH, #080h
                J       knock_244_recheck_rolb_acc_3
knock_244_recheck_load_carry_p0_bit5_2:     MB      C, P0.5
                ROLB    A
                ROLB    A
                MOV     DP, #003a1h
                J       knock_244_recheck_store_dp_ind
diag_mode_code_store_if_ram216_bit3_clr:     JBR     off(00216h).3, diag_mode_code_store_load_carry_ram227_bit5
                LCB     A, diag_mode_code_store_tbl
                SLLB    A
                ROLB    r0
                ROLB    r0
diag_mode_code_store_load_carry_ram227_bit5:     MB      C, off(00227h).5
                J       diag_mode_code_store_rolb_r0
                DB  000h
boot_flag_baro_common_load_carry_ram216_bit2:     MB      C, off(00216h).2
                LCB     A, diag_snapshot_copy_loop_tbl
                J       boot_flag_baro_common_if_eq_goto_561c
diag_mode_code_store_tbl:       DB  000h
o2_trim_tps_mode_check_if_ram11c_bit2_clr:     JBR     off(0011ch).2, o2_trim_tps_mode_check_goto_o2_trim_alt_path_check
                MOVB    off(00197h), #00ah
                J       o2_trim_alt_path_check_load_ram16c
o2_trim_tps_mode_check_goto_o2_trim_alt_path_check:     J       o2_trim_alt_path_check
o2trim_speed_flag_set_load_carry_p1_bit6:     MB      C, P1.6
                JLT     o2trim_speed_flag_set_load_ram197
                J       o2trim_gate_common2
o2trim_speed_flag_set_load_ram197:     LB      A, off(00197h)
                J       o2trim_speed_flag_set_if_ne_goto_o2trim_gate_common2
idle_vcal5_call3_load_ram266:     L       A, off(00266h)
                JNE     idle_vcal5_call3_goto_30c2_3
                J       idle_vcal5_call3_cmp_ram0a6
idle_vcal5_call3_goto_30c2_3:     J       idle_stall_check2_if_ram217_bit5_clr
ignition_timing_calc_task_load_ram0bd:     LB      A, 0bdh
                JBS     off(0021bh).1, ignition_timing_calc_task_cmp_acc_9
                CMPB    A, #010h
                JGT     ignition_timing_calc_task_goto_337b
ignition_timing_calc_task_cmp_acc_9:     CMPB    A, #020h
                J       ignition_timing_calc_task_if_le_goto_337f
ignition_timing_calc_task_goto_337b:     J       ignition_timing_calc_task_load_ram2d2
div_scale_store_load_x1:     MOV     X1, #00004h
                JBS     off(00216h).3, div_scale_store_goto_gear_detect_store
                LB      A, #001h
                J       div_scale_store_clear_x1
div_scale_store_goto_gear_detect_store:     J       gear_detect_store
o2trim_speed_flag_set_cmp_acc:     CMP     A, er1
                JLE     o2trim_speed_flag_set_store_er1
                L       A, #tbl_idle_pi_clamp
                CMP     A, er1
                JLT     o2trim_speed_flag_set_load_imm
                JBS     off(00117h).3, o2trim_speed_flag_set_load_imm
                CMPB    0c2h, #0ffh
                JGT     o2trim_speed_flag_set_clear_pswl_bit4
                JBR     off(00118h).0, o2trim_speed_flag_set_load_imm
                J       o2trim_speed_flag_set_clear_pswl_bit4
                DB  000h,000h,000h,000h,000h,000h
o2trim_speed_flag_set_clear_pswl_bit4:     RB      PSWL.4
o2trim_speed_flag_set_load_imm:     L       A, #05e20h
                CMP     A, er1
                JLT     o2trim_speed_flag_set_goto_1c0d
o2trim_speed_flag_set_store_er1:     ST      A, er1
o2trim_speed_flag_set_goto_1c0d:     J       o2trim_speed_flag_set_load_carry_pswl_bit4
dcode_gate_common_if_ram216_bit3_clr:     JBR     off(00216h).3, dcode_gate_common_goto_dcode_gate_common2
                JBS     off(00214h).2, dcode_gate_common_goto_dcode_gate_common2
                J       dcode_gate_common_load_dp
dcode_gate_common_goto_dcode_gate_common2:     J       dcode_gate_common2
                DB  0EBh,01Dh,006h,0ECh,01Eh,003h,003h,0D5h
                DB  03Dh,003h,0E4h,03Dh
crank_tooth_count_store_load_carry_ram113_bit6:     MB      C, off(00113h).6
                MB      off(00122h).1, C
                J       crank_tooth_count_store_if_ram120_bit2_set
vcal3_leanprotect_ratelimit_clear_stk:     RB      (00122h-00180h)[USP].2
                JBR     off(00216h).7, vcal3_leanprotect_ratelimit_goto_26a7
                J       vcal3_leanprotect_ratelimit_clear_ram09e_bit6
vcal3_leanprotect_ratelimit_goto_26a7:     J       vcal3_leanprotect_ratelimit_clear_ram09e_bit4
idle_init_start_clear_stk:     RB      (00122h-00180h)[USP].2
                CAL     idle_helper1
                J       idle_init_start_load_er0
coldstart_full_reset_andb_p1:     ANDB    P1, #0fch
                CLR     off(00268h)
                J       coldstart_full_reset_goto_7831
coldstart_full_reset_store_ram0f0:     ST      A, 0f0h
                ST      A, 0eeh
                ANDB    (0011fh-00180h)[USP], #0f9h
                ANDB    off(0021fh), #0f9h
                RB      off(00232h).7
                J       warmrestart_tm3_resync
dtc13_baro_latch:     MB      099h.2, C
                VCAL    4
                J       dcode14_check_if_ram217_bit5_set
gear_detect_store_load_stk:     MOV     (0017ah-00180h)[USP], A
                VCAL    4
                J       gear_detect_store_load_x1
gear_detect_store_load_stk_2:     MOV     (001eah-00180h)[USP], A
                VCAL    4
                J       threshold_bank_223_2
vss_band_dispatch:     MB      P0.1, C
                VCAL    4
                J       vss_band_dispatch_load_r2
altc_gio_override_check_vcal_4:     VCAL    4
                JBS     off(00227h).3, altc_gio_override_check_goto_4491
                J       altc_gio_override_check_if_ram216_bit3_clr
altc_gio_override_check_goto_4491:     J       altc_normal_drive_nop_acc
calchecksum_loop_vcal_4:     VCAL    4
                CAL     cfgvariant_checksum2_calc
                J       calchecksum_loop_inc_dp
freezeframe_decode_start_load_ram212:     L       A, off(00212h)
                ORB     A, off(00214h)
                J       freezeframe_decode_start_add_acc
injector_timer_schedule_load_tm0:     L       A, TM0
                SUB     A, #00001h
                ST      A, TMR0
                MOV     X1, #001b8h
                J       injector_timer_schedule_load_dp
inj_accum1_add_add_acc:     ADD     A, off(001b8h)
                CMP     A, #00100h
                JGE     inj_accum1_store2
                CLR     A
inj_accum1_store2:     ST      A, off(001b8h)
                CLR     A
                ST      A, off(001bah)
                J       inj_accum_store_114
                DB  0FFh
tbl_idle_pi_clamp:       DB  000h
boot_completion_helper_tbl:       DB  0FFh
boot_completion_helper_tbl_2:       DB  0FFh
boot_completion_helper_tbl_3:       DB  0FFh
boot_completion_helper_tbl_4:       DB  000h
boot_completion_helper_tbl_5:       DB  0FFh
boot_completion_helper_tbl_6:       DB  0FFh
boot_completion_helper_tbl_7:       DB  0FFh
boot_completion_helper_tbl_8:       DB  0FFh
boot_completion_helper_tbl_9:       DB  000h
boot_completion_helper_tbl_10:       DB  000h
diag_snapshot_copy_loop_tbl:       DB  000h
boot_flag_gearpreset_alt_tbl:       DB  000h
diag_snapshot_copy_loop_tbl_2:       DB  000h
diag_snapshot_copy_loop_tbl_3:       DB  0FFh
diag_mode_code_store_tbl_2:       DB  000h
gate_255_common_tbl:       DB  000h
idle_init_start_tbl:       DB  000h
boot_completion_helper_tbl_11:       DB  000h
boot_completion_helper_tbl_12:       DB  0FFh
boot_flag_iabv_common_tbl:       DB  0FFh
boot_flag_baro_common_tbl:       DB  0FFh
boot_flag_baro_common_tbl_2:       DB  000h
boot_flag_baro_common_tbl_3:       DB  000h
boot_flag_gearpreset_alt_tbl_2:       DB  000h
boot_flag_gearpreset_alt_tbl_3:       DB  000h
boot_flag_gearpreset_alt_tbl_4:       DB  000h
boot_flag_gearpreset_alt_tbl_5:       DB  0FFh
deadtime_voltage_flag_store_tbl:       DB  00Bh,00Bh,00Bh,006h,006h,008h
tbl_tps_custom_curve:       DB  004h,018h,004h,018h
tbl_tps_custom_curve2:       DB  028h,040h,030h,040h,030h,040h
to_injtimer_sub_common_tbl:       DB  0D0h,0D0h,064h,051h,0D0h,0D0h,064h,051h
revlimit_table_select_tbl_4:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h
                DB  044h,042h,028h,041h,000h,040h
revlimit_table_select_tbl_5:       DB  0FFh,066h,0E6h,05Eh,0CFh,05Dh,0A1h,05Ch
                DB  044h,04Ch,028h,041h,000h,040h
revlimit_table_select_tbl_6:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  044h,040h,02Eh,040h,000h,040h
revlimit_table_select_tbl_7:       DB  0FFh,066h,0E6h,05Eh,0CFh,05Dh,0A1h,046h
                DB  044h,043h,02Eh,040h,000h,040h
revlimit_table_select_tbl_8:       DB  0FFh,080h,0E6h,073h,0CFh,06Ch,0A1h,060h
                DB  044h,04Dh,02Eh,040h,000h,040h
IATFuelCorrect:       DB  0FFh,0E1h,09Ah,0F5h,0E1h,09Ah,0E1h,0A3h
                DB  090h,0BAh,0AEh,087h,087h,000h,080h,034h
                DB  052h,078h,000h,052h,078h
PostFuelDecay:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h
PostFuelDecay2:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h
PostFuelDecay3:       DB  0D7h,0A3h,000h,00Ch,000h,002h,040h,000h
PostFuel:       DB  0FFh,000h,090h,0E6h,000h,070h,0CFh,000h
                DB  058h,0A1h,099h,049h,07Ah,09Ah,039h,040h
                DB  000h,028h,000h,000h,028h
o2trim_ect_offset_lookup_tbl:       DB  001h,000h,000h,001h,001h,000h,000h,002h
                DB  001h,000h,000h,004h
tbl_revlimit_cold1:       DB  0AEh,028h,0A1h,034h
tbl_revlimit_cold3:       DB  0B5h,02Eh,0A9h,062h
o2_trim_step_threshold_tbl:                 DW  00404h
CloseLoopRate:       DB  043h,000h,043h,000h,043h,000h,043h,000h
                DB  030h,000h,043h,000h,043h,000h,043h,000h
                DB  043h,000h,043h,000h,030h,000h,043h,000h
CloseLoopGoose:       DB  07Ch,003h,035h,004h,0EAh,003h,09Ch,002h
                DB  080h,000h,09Ch,002h,07Ch,003h,05Ah,004h
                DB  05Ah,004h,05Ah,004h,080h,000h,05Ah,004h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
tbl_closeloop_tps:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C8h,0D0h
                DB  0C0h,0D8h,04Dh,0EAh,040h,0AEh,000h,0AEh
tbl_revlimit_warm1:       DB  0EEh,000h,0A0h,030h
ve_adjust2_gate_tbl:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C8h,0D0h
                DB  0C0h,0D8h,04Dh,0EAh,040h,0AEh,000h,0AEh
revlimit_table_select_tbl_9:       DB  0FFh,080h,01Fh,080h,018h,080h,013h,08Bh
                DB  00Fh,08Bh,000h,08Bh
to_flag_12f_5_select_ff_tbl:       DB  0FFh,094h,0D0h,094h,0A0h,088h,080h,069h
                DB  040h,05Eh,000h,052h
to_flag_12f_5_select_ff_tbl_2:       DB  0FFh,09Ah,0D0h,09Ah,0A0h,08Dh,080h,073h
                DB  040h,066h,000h,05Ah
tbl_ve_accel_1:       DB  0FFh,088h,0D0h,088h,0C0h,085h,0A0h,080h
                DB  040h,080h,000h,080h
tbl_ve_accel_2:       DB  0FFh,08Ah,08Eh,08Ah,072h,088h,055h,080h
                DB  01Ch,080h,000h,080h
tbl_knockwindow_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
tbl_knockwindow_4:       DB  0FFh,08Eh,0A1h,08Eh,087h,071h,06Eh,05Eh
                DB  034h,04Bh,028h,03Dh,000h,03Dh
gear_detect_store_tbl:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,06Dh
                DB  034h,060h,028h,04Dh,000h,04Dh
gear_detect_store_tbl_2:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,050h
                DB  034h,043h,028h,030h,000h,030h
CylinderIGNCorrect:       DB  080h,080h,080h,080h
tbl_revlimit_warm2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
tbl_injtimer_finalize:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
knock_table2d_lookup_tbl:       DB  0FFh,064h,000h,0A7h,067h,000h,093h,094h
                DB  000h,07Eh,0C3h,000h,069h,054h,001h,054h
                DB  080h,002h,000h,080h,002h
tbl_tipin_enrich_rpm:       DB  060h,065h,004h,000h,026h,000h,060h,020h
                DB  003h,000h,000h,000h,060h,020h,003h,000h
                DB  02Dh,000h,058h,039h,003h,000h,000h,000h
                DB  058h,0E8h,003h,000h,032h,000h,040h,06Bh
                DB  003h,000h,000h,000h,040h,065h,004h,000h
                DB  03Eh,000h,040h,084h,003h,000h,000h,000h
                DB  040h,065h,004h,000h,04Bh,000h
tbl_tipin_normal_enrich:       DB  0E1h,000h,0AFh,000h,004h,000h,0FAh,000h
                DB  0AFh,000h,006h,000h,0C2h,001h,02Ch,001h
                DB  008h,000h,013h,001h,0C8h,000h,006h,000h
                DB  0C2h,001h,02Ch,001h,008h,000h,02Ch,001h
                DB  0E1h,000h,008h,000h,0C2h,001h,02Ch,001h
                DB  008h,000h,02Ch,001h,0E1h,000h,008h,000h
                DB  0C2h,001h,02Ch,001h,008h,000h
revlimit_table_select_tbl_10:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,0A2h,073h
                DB  000h,040h,0D0h,000h,028h,000h,001h,000h
                DB  000h,001h
revlimit_table_select_tbl_11:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,0A2h,04Dh
                DB  000h,040h,080h,000h,028h,000h,001h,000h
                DB  000h,001h
tbl_tipin_low:       DB  010h,0E6h,000h,002h,000h,001h,050h,0E6h
                DB  000h,008h,000h,001h,050h,0F3h,000h,010h
                DB  000h,001h,050h,0F3h,000h,010h,000h,001h
tbl_revlimit_cold4:       DB  0FFh,080h,000h,080h
revlimit_table_select_tbl_12:       DB  0FFh,08Ah,0C0h,08Ah,060h,040h,040h,026h
                DB  020h,020h,000h,020h
tbl_rpm_decel:       DB  0FFh,008h,000h,08Bh,008h,000h,080h,018h
                DB  000h,060h,050h,000h,040h,070h,000h,020h
                DB  0A0h,000h,000h,0C0h,000h
tbl_revlimit_warm3:       DB  0FFh,07Dh,000h,0CFh,07Dh,000h,0A2h,07Dh
                DB  000h,06Eh,07Dh,000h,000h,07Dh,000h
revlimit_table_select_tbl_13:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,030h,028h,012h,000h,012h
revlimit_table_select_tbl_14:       DB  0FFh,090h,0E6h,080h,0CFh,070h,0A1h,040h
                DB  06Eh,030h,028h,012h,000h,012h
revlimit_table_select_tbl_15:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  06Eh,020h,028h,008h,000h,008h
revlimit_table_select_tbl_16:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  06Eh,020h,028h,008h,000h,008h
CrankFuel:       DB  0FFh,0A8h,061h,0F1h,0A8h,061h,0E6h,020h
                DB  04Eh,0CFh,010h,027h,0A1h,0DBh,01Ah,087h
                DB  011h,012h,028h,04Dh,008h,000h,04Dh,008h
CrankFuelComp:       DB  030h,080h,012h,05Ah
CrankFuelMap:       DB  0FFh,080h,000h,080h
Overrun_Resume_int:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
Overrun_Resume_nor:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h
                DB  034h,04Dh,028h,03Fh,000h,03Fh
gear_detect_store_tbl_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
gear_detect_store_tbl_4:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h
                DB  034h,04Dh,028h,03Fh,000h,03Fh
tbl_ignmap2_lo:       DB  0FFh,020h,0E0h,020h,0D0h,01Bh,0C0h,015h
                DB  0A0h,00Fh,000h,00Fh
tbl_ignmap2_hi:       DB  0FFh,018h,0E0h,018h,0D0h,013h,0C0h,00Dh
                DB  0A0h,007h,000h,007h
gear_detect_store_tbl_5:       DB  0FFh,000h,000h,000h
tbl_threshold_223_1:       DB  01Eh,02Bh,0E4h,000h,06Fh,001h
Revlimiters:       DB  01Eh,02Bh,0E2h,000h,023h,001h
tbl_threshold_223_2:       DB  01Eh,02Bh,0E4h,000h,06Fh,001h
tbl_threshold_223_3:       DB  01Eh,02Bh,0E2h,000h,023h,001h
knock_table_index_tbl:       DB  033h,073h,09Ah,079h,000h,080h,066h,086h
                DB  0CDh,08Ch,0CDh,08Ch,033h,073h,09Ah,079h
                DB  000h,080h,066h,086h,0CDh,08Ch,0CDh,08Ch
tbl_knock_div:       DB  07Ch,003h,0EBh,003h,05Ah,004h,0CAh,004h
                DB  039h,005h,039h,005h,0D5h,003h,044h,004h
                DB  0B3h,004h,023h,005h,093h,005h,093h,005h
                DB  07Ch,003h,0EBh,003h,05Ah,004h,0CAh,004h
                DB  039h,005h,039h,005h,0D5h,003h,044h,004h
                DB  0B3h,004h,023h,005h,093h,005h,093h,005h
knock_div_calc4_tbl:       DB  0EBh,003h,05Ah,004h,0CAh,004h,039h,005h
                DB  0A9h,005h,0A9h,005h,039h,005h,0A9h,005h
                DB  018h,006h,088h,006h,0F7h,006h,0F7h,006h
                DB  0EBh,003h,05Ah,004h,0CAh,004h,039h,005h
                DB  0A9h,005h,0A9h,005h,039h,005h,0A9h,005h
                DB  018h,006h,088h,006h,0F7h,006h,0F7h,006h
GearCustom:       DB  046h,000h,067h,000h,08Eh,000h,0B8h,000h
crank_edge_flag_store_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh
crank_edge_flag_store_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,080h
newval_table3_call_tbl:       DB  0FFh,0FFh,000h,0FFh
newval_table3_call_tbl_2:       DB  0FFh,0FFh,000h,0FFh
vss_band_224_0_check_tbl:       DB  090h,0A0h,00Ch,00Fh,02Dh,02Fh,02Dh,02Fh
                DB  088h,080h,088h,080h,029h,026h
vtec_state_store2_tbl:       DB  0CAh,0CDh,0D5h,0D8h
vtec_state_store2_tbl_2:       DB  0D6h,0DAh,0DBh,0DEh
vtec_state_store2_tbl_3:       DB  0FFh,03Fh,0F8h,03Fh,0F0h,03Fh,0E8h,03Fh
                DB  0D5h,03Fh,0CAh,0AEh,000h,0AEh
vtec_state_store2_tbl_4:       DB  0FFh,03Fh,0F8h,03Fh,0F0h,03Fh,0E8h,03Fh
                DB  0DBh,03Fh,0D6h,0AEh,000h,0AEh
revlimit_table_select_tbl_17:       DB  0FFh,000h,000h,000h
ignition_timing_calc_task_tbl:       DB  046h,04Bh,02Bh,036h,082h,087h,05Fh,064h
                DB  09Ch,0A1h,00Fh,011h,010h,012h,044h,049h
                DB  022h,025h,039h,041h,014h,016h,028h,02Dh
                DB  05Fh,064h,07Dh,082h,014h,019h,021h,026h
                DB  04Ah,04Ch,036h,050h,0B3h,0C0h
ignition_timing_calc_task_tbl_2:       DB  0FFh,001h,09Fh,001h,09Bh,013h,06Eh,013h
                DB  05Ah,013h,041h,005h,000h,005h
ignition_timing_calc_task_tbl_3:       DB  0FFh,0FAh,0B0h,0FAh,09Bh,0FAh,082h,0FAh
                DB  080h,09Ch,078h,092h,064h,076h,05Ah,069h
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h
ignition_timing_calc_task_tbl_4:       DB  0FFh,0FAh,0B0h,0FAh,08Eh,0FAh,087h,0FAh
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h
ignition_timing_calc_task_tbl_5:       DB  0FFh,0FAh,09Ch,0FAh,09Ah,0B6h,096h,0B6h
                DB  085h,0A2h,078h,092h,064h,076h,05Ah,069h
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h
ignition_timing_calc_task_tbl_6:       DB  0FFh,0FAh,0A1h,0FAh,09Fh,0A3h,09Bh,0A3h
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h
ignition_timing_calc_task_tbl_7:       DB  0FFh,014h,0B4h,014h,04Eh,014h,04Ch,003h,000h,003h
ignition_timing_calc_task_tbl_8:       DB  0FFh,01Bh,0B4h,01Bh,04Eh,01Bh,04Ch,006h,000h,006h
ignition_timing_calc_task_tbl_9:       DB  0FFh,02Ch,050h,02Ch,03Ch,01Eh,028h,01Eh
                DB  019h,01Eh,014h,01Bh,000h,01Bh
ignition_timing_calc_task_tbl_10:       DB  0FFh,038h,050h,038h,03Ch,030h,028h,030h
                DB  019h,02Bh,014h,02Ah,000h,020h
ignition_timing_calc_task_tbl_11:       DB  0FFh,033h,078h,033h,050h,02Eh,03Ch,01Dh
                DB  028h,01Dh,014h,01Bh,000h,01Bh
ignition_timing_calc_task_tbl_12:       DB  0FFh,03Fh,078h,03Fh,050h,03Ah,03Ch,027h
                DB  028h,025h,014h,01Fh,000h,01Bh
revlimit_table_select_tbl_18:       DB  0FFh,057h,0CFh,057h,0A1h,051h,06Eh,04Ch
                DB  044h,046h,028h,040h,000h,040h
tps_hysteresis_reentry_tbl:       DB  0FFh,0D2h,0E0h,0D2h,0C0h,0D2h,080h,0D2h
                DB  060h,0DAh,05Ch,0FFh,000h,0FFh,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
overrev_hardcap_compare_tbl_2:       DB  0FFh,017h,0F8h,017h,0F0h,028h,0E8h,026h
                DB  0E0h,024h,0D8h,024h,0D0h,02Dh,0C8h,031h
                DB  0C0h,02Dh,0B0h,02Dh,0A0h,029h,098h,02Ah
                DB  090h,02Ah,088h,026h,080h,026h,070h,020h
                DB  060h,018h,050h,00Eh,040h,000h,000h,000h
                DB  000h,000h,000h,000h,0FFh,017h,0F8h,017h
                DB  0F0h,01Ch,0E8h,019h,0E0h,017h,0D8h,01Ah
                DB  0D0h,024h,0C8h,029h,0C0h,024h,0B0h,00Fh
                DB  0A0h,000h,098h,000h,090h,000h,088h,000h
                DB  080h,000h,070h,000h,060h,000h,050h,000h
                DB  040h,000h,000h,000h,000h,000h,000h,000h
tbl_vtec_transition_retard:       DB  000h,000h,011h,055h,077h,0FFh
state_21a_7_dispatch2_tbl:       DB  0FFh,04Dh,008h,0CFh,04Dh,008h,0BAh,0B7h
                DB  007h,087h,059h,006h,02Eh,0EEh,002h,028h
                DB  0EEh,002h,000h,0EEh,002h
ignmap_alt_path_tbl:       DB  0FFh,0ABh,0E4h,0ABh,0D5h,0A2h,0C7h,0A2h
                DB  0B9h,0A2h,0ABh,09Eh,09Dh,091h,08Eh,08Dh
                DB  080h,089h,072h,089h,064h,07Ch,056h,073h
                DB  047h,06Fh,039h,055h,02Bh,049h,01Dh,033h
                DB  000h,033h,000h,033h,000h,033h,000h,033h
                DB  000h,033h,000h,033h
ignmap_alt_path_tbl_2:       DB  0FFh,0ABh,0F8h,0ABh,0F0h,0A2h,0E8h,0A2h
                DB  0E0h,09Eh,0D8h,091h,0D0h,08Dh,0C8h,089h
                DB  0C0h,089h,0B0h,07Ch,0A0h,073h,098h,071h
                DB  090h,06Fh,088h,062h,080h,055h,070h,04Dh
                DB  060h,049h,050h,040h,040h,033h,000h,033h
                DB  000h,033h,000h,033h
battery_voltage_store_tbl:       DB  0FEh,0FFh,066h,073h,0DDh,0E0h,044h,030h,078h,070h
ZoneIndexTable1_SetB:       DB  0FFh,000h,016h,0F0h,000h,016h,0E0h,000h
                DB  010h,0CAh,000h,012h,090h,000h,015h,070h
                DB  000h,014h,035h,000h,00Ah,028h,000h,000h
                DB  000h,000h,000h
ZoneIndexTable1_SetA:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h
                DB  013h,0CAh,000h,016h,090h,000h,01Dh,070h
                DB  000h,018h,035h,000h,00Ah,028h,000h,000h
                DB  000h,000h,000h
idle_mode_dispatch_tbl:       DB  0FFh,000h,028h,0F0h,000h,028h,0E0h,000h
                DB  01Fh,0CAh,000h,020h,090h,000h,023h,070h
                DB  000h,020h,035h,000h,013h,028h,000h,010h
                DB  000h,000h,010h
ZoneIndexTable3_SetA:       DB  0FFh,000h,030h,0F0h,000h,030h,0E0h,000h
                DB  024h,0CAh,000h,025h,090h,000h,028h,070h
                DB  000h,023h,035h,000h,014h,028h,000h,010h
                DB  000h,000h,010h
ZoneIndexTable2_SetB:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h
                DB  015h,0CAh,000h,016h,090h,000h,019h,070h
                DB  000h,017h,035h,000h,00Dh,028h,000h,008h
                DB  000h,000h,008h
ZoneIndexTable2_SetA:       DB  0FFh,000h,026h,0F0h,000h,026h,0E0h,000h
                DB  01Ch,0CAh,000h,01Dh,090h,000h,022h,070h
                DB  000h,01Dh,035h,000h,00Eh,028h,000h,00Ah
                DB  000h,000h,00Ah
IdleVsECT:       DB  0FFh,0E2h,004h,0A1h,03Bh,005h,087h,0A2h
                DB  005h,06Eh,01Bh,006h,034h,00Bh,009h,028h
                DB  044h,00Bh,000h,044h,00Bh
idle_step_flag_store_tbl:       DB  0FFh,0E2h,004h,0A1h,0E2h,004h,087h,03Bh
                DB  005h,06Eh,0A2h,005h,034h,023h,008h,028h
                DB  00Bh,009h,000h,00Bh,009h
freezeframe_flag_225_7_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h
                DB  034h,050h,028h,042h,000h,042h,0FFh,09Ah
                DB  0A1h,09Ah,087h,083h,06Eh,073h,034h,066h
                DB  028h,04Dh,000h,04Dh
idle_step_flag_store_tbl_2:       DB  0FFh,092h,0A1h,092h,087h,07Ah,06Eh,073h
                DB  034h,05Dh,028h,04Dh,000h,04Dh,0FFh,09Ah
                DB  0A1h,09Ah,087h,086h,06Eh,083h,034h,070h
                DB  028h,05Ah,000h,05Ah
tbl_idle_lookup3:       DB  000h,0F0h,000h,002h,000h,004h
tbl_idle_select_default:       DB  000h,0F0h,000h,010h,000h,00Dh
tbl_idle_timer:       DB  000h,040h,000h,006h,000h,006h
tbl_idle_select1:       DB  000h,0F0h,080h,000h,080h,001h
tbl_idle_gear2:       DB  000h,000h,000h,080h,001h,000h
idle_table_select1_tbl:       DB  0FFh,0FFh,0FFh,0FFh,000h,000h
tbl_idle_stall:       DB  0F5h,000h,098h,000h
idle_sub_alt_path_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h
                DB  034h,050h,028h,042h,000h,042h
tbl_idle_gate6:       DB  0FFh,014h,000h,0A1h,014h,000h,087h,014h
                DB  000h,06Eh,014h,000h,034h,014h,000h,028h
                DB  030h,000h,000h,030h,000h
idle_sub_alt_path_tbl_2:       DB  0FFh,0FFh,0A1h,0FFh,087h,0FFh,06Eh,0FFh
                DB  034h,0FFh,028h,0FFh,000h,0FFh
idle_table_lookup2_tbl:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah
                DB  034h,006h,028h,002h,000h,002h
tbl_idle_pid_lo1:       DB  0FFh,0CCh,040h,0CCh,028h,0A7h,020h,097h
                DB  013h,080h,000h,060h
tbl_idle_pid_lo2:       DB  0FFh,0A9h,040h,0A9h,028h,090h,020h,080h
                DB  013h,068h,000h,060h
tbl_idle_pid_lo3:       DB  0FFh,097h,040h,097h,028h,080h,020h,071h
                DB  013h,04Fh,000h,04Fh
tbl_idle_pid_a:       DB  0FFh,0A9h,040h,0A9h,028h,090h,020h,080h
                DB  013h,068h,000h,060h
tbl_idle_pid_b:       DB  0FFh,097h,040h,097h,028h,080h,020h,071h
                DB  013h,04Fh,000h,04Fh
tbl_idle_pid_hi1:       DB  0FFh,040h,005h,0A0h,040h,002h,098h,0E0h
                DB  001h,080h,0D0h,000h,078h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_hi2:       DB  0FFh,090h,006h,0B0h,0E0h,003h,0A0h,020h
                DB  003h,080h,090h,001h,070h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_hi3:       DB  0FFh,000h,007h,0B0h,000h,004h,0A0h,090h
                DB  003h,080h,0C0h,001h,060h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_c:       DB  0FFh,090h,006h,0B0h,0E0h,003h,0A0h,020h
                DB  003h,080h,090h,001h,070h,000h,000h,000h
                DB  000h,000h
tbl_idle_pid_d:       DB  0FFh,000h,007h,0B0h,000h,004h,0A0h,090h
                DB  003h,080h,0C0h,001h,060h,000h,000h,000h
                DB  000h,000h
ZoneCorrectionRowSelect_SetA:       DB  0FFh,080h,006h,0C0h,080h,006h,060h,000h
                DB  008h,030h,000h,00Ah,000h,000h,00Dh
ZoneCorrectionRowSelect_SetB:       DB  0FFh,080h,006h,0C0h,080h,006h,060h,000h
                DB  008h,030h,000h,00Ah,000h,000h,00Dh
ZoneCorrection2DTable:       DB  0FFh,0C0h,0B0h,0C0h,080h,098h,053h,080h,000h,080h
inc_dp_step_tbl:       DB  0FFh,000h,00Eh,0D0h,000h,00Eh,0BAh,000h
                DB  00Eh,094h,000h,00Dh,055h,080h,00Ah,042h
                DB  000h,008h,034h,080h,007h,028h,000h,004h
                DB  000h,000h,004h
inc_dp_step_tbl_2:       DB  0FFh,0FFh,000h,004h,044h,00Bh,000h,004h,0C4h,009h
                DB  080h,007h,00Bh,009h,000h,00Ah,000h,000h,000h,00Ah
ModePageTable_SetA:       DB  030h,000h,020h,004h,000h,000h
ModePageTable_SetB:       DB  030h,0FFh,03Fh,004h,000h,000h
ModeToPageTable:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,060h,000h
                DB  01Ch,040h,000h,006h,000h,000h,006h
tbl_ve_map_scalar_alt:       DB  0FFh,0FFh,03Fh,08Eh,0FFh,03Fh,080h,0FFh
                DB  03Fh,072h,0FFh,03Fh,055h,0FFh,03Fh,039h
                DB  000h,00Ah,02Ch,000h,000h,000h,000h,000h
tbl_ve_map_scalar:       DB  0FFh,0FFh,03Fh,0D0h,0FFh,03Fh,0C8h,000h
                DB  030h,0C0h,000h,026h,0A0h,000h,020h,080h
                DB  000h,00Ah,064h,000h,000h,000h,000h,000h
idle_stall_check2_tbl:       DB  0FFh,000h,010h,0D0h,000h,00Ah,0A0h,000h
                DB  007h,060h,000h,005h,028h,000h,003h,000h
                DB  000h,003h
idle_stall_check2_tbl_2:       DB  0FFh,060h,000h,0D0h,040h,000h,0A0h,020h
                DB  000h,060h,010h,000h,028h,00Ch,000h,000h
                DB  00Ch,000h
idle_stall_check2_tbl_3:       DB  0FFh,004h,000h,0D0h,003h,000h,0A0h,002h
                DB  000h,060h,002h,000h,028h,002h,000h,000h
                DB  001h,000h
idle_stall_check2_tbl_4:       DB  0FFh,000h,000h,0CFh,000h,000h,0A0h,000h
                DB  000h,044h,000h,000h,028h,000h,000h,000h
                DB  000h,000h
idle_pi_final_calc_tbl:       DB  0FFh,080h,000h,080h
idle_pi_final_calc_tbl_2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
idle_pi_final_calc_tbl_3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
tbl_idle_gear_target:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,000h,0C0h
                DB  080h,036h,066h,0A6h,0F0h,018h,000h,080h
                DB  010h,00Ah,066h,066h,000h,003h,033h,053h
                DB  0A0h,000h,066h,046h,000h,000h,0CCh,02Ch
tbl_idle_dc:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h
                DB  000h,008h,01Eh,085h,080h,006h,01Eh,085h
                DB  000h,003h,085h,07Bh,000h,002h,033h,073h
                DB  000h,001h,028h,05Ch,000h,000h,028h,05Ch
state_21a_7_dispatch2_tbl_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
state_21a_7_dispatch2_tbl_3:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
tbl_iat_correct2:       DB  0FFh,0B8h,0ABh,09Ah,055h,05Ch,047h,055h
                DB  039h,04Dh,02Bh,03Ch,00Bh,010h,000h,010h
DwellBattery:       DB  0FFh,01Ch,0BCh,02Eh,0A7h,034h,092h,040h
                DB  07Dh,050h,068h,068h,054h,0A0h,03Fh,0D9h
                DB  000h,0D9h,000h,0D9h,000h,0D9h,000h,0D9h
                DB  000h,0D9h,000h,0D9h,000h,0D9h,000h,0D9h
                DB  000h,0D9h,000h,0D9h
tbl_iat_correct1:       DB  0FFh,03Bh,0AAh,025h,071h,017h,038h,009h
                DB  01Ch,002h,013h,000h,000h,000h
knockwindow_result_tbl:       DB  0FFh,000h,0AEh,000h,0A1h,02Bh,057h,015h
                DB  034h,000h,000h,000h
tbl_ignmap_idle1:       DB  0D4h,000h,0C1h
knockwindow_result_tbl_2:       DB  0FFh,06Fh,0E6h,067h,0BFh,049h,094h,02Ah
                DB  057h,011h,028h,000h,000h,000h
knockwindow_result_tbl_3:       DB  0FFh,05Ah,0E6h,051h,0BFh,033h,094h,022h
                DB  057h,011h,028h,000h,000h,000h
tbl_ignmap_idle2:       DB  077h,0C1h,064h,064h
knockwindow_result_tbl_4:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,000h
                DB  00Fh,000h,000h,000h
tbl_ect_fuelcorrect:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,00Dh
                DB  00Fh,015h,000h,015h
threshold_bank_220_6_tbl:       DB  0FFh,000h,06Ch,000h,044h,00Ch,02Eh,015h,000h,015h
HiIdleIgnControl:       DB  0FFh,0FFh,000h,000h,000h,002h,000h,000h
                DB  0F0h,000h,015h,000h,000h,000h,000h,000h
IgnControl:       DB  0FFh,0FFh,000h,000h,000h,003h,015h,000h
                DB  0CEh,000h,015h,000h,000h,000h,000h,000h
dwell_scale_shift_tbl_3:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,020h,02Fh,040h,03Dh,03Ah,055h
                DB  063h,072h,07Ah,07Ah,000h,000h,000h,000h
                DB  000h,000h
clamp_result_store_tbl:       DB  024h,000h,020h,039h,04Ah,050h,055h,05Eh
                DB  066h,080h,084h,088h,088h,088h
flags_pack_sj_tbl:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h
                DB  040h,000h,000h,000h
TipinTPS:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h
                DB  040h,000h,000h,000h
callhelper_table_interp_lookup_tbl:       DB  0FFh,040h,0D0h,040h,0C0h,038h,0A0h,030h
                DB  080h,02Ch,040h,028h,000h,028h
tipin_gate_pass_tbl:       DB  0FFh,02Ah,0C0h,02Ah,0A0h,02Ah,080h,055h
                DB  066h,055h,040h,02Ah,000h,015h
callhelper_table_interp_lookup_tbl_2:       DB  0FFh,000h,0D8h,000h,0D0h,000h,0C0h,000h
                DB  0B0h,000h,0A0h,000h,090h,000h,080h,000h
                DB  000h,000h
flags_pack_sj_tbl_2:       DB  0FFh,000h,09Ah,00Ch,04Dh,040h,033h,02Ah
                DB  026h,015h,000h,000h
TipinGear:       DB  040h,080h,066h,047h,047h,0BAh,07Ah,028h
tbl_map_sign:       DB  060h,0F0h,020h,070h
ect_simulate_ramp_tbl:       DB  0DFh,0CFh,0A1h,057h,028h
tbl_dcode14_lo:       DB  0C2h,000h,0FAh,03Eh,000h,047h
tbl_dcode14_hi:       DB  0E5h,000h,051h,03Eh,000h,019h
vss_threshold_226_3_tbl:       DB  06Bh,0A9h,02Bh,062h
tbl_knock244_a:       DB  030h,030h,030h,025h,01Bh,01Bh,01Bh,015h,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,008h,008h,008h,008h,008h
tbl_knock244_b:       DB  030h,030h,030h,030h,030h,02Ch,025h,01Bh
                DB  01Bh,01Bh,01Bh,01Bh,01Bh,015h
int_serial_rx_tbl:       DB  00Ch,00Ch,00Ch,00Ch,008h,008h,08Fh,003h
                DB  08Eh,003h,0D6h,003h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,09Ch,003h
                DB  09Dh,003h,09Eh,003h,09Fh,003h,0A0h,003h
                DB  0A1h,003h,0A2h,003h,0A3h,003h,0C8h,003h
                DB  0C0h,003h,0A3h,000h,0C1h,003h,092h,003h
                DB  0C2h,000h,000h,004h,0C3h,000h,093h,003h
                DB  0C6h,003h,0BFh,000h,0F5h,002h,0C6h,003h
                DB  000h,004h,000h,004h,000h,004h,049h,001h
                DB  000h,004h,005h,003h,000h,004h,091h,003h
                DB  090h,003h,05Ch,003h,043h,002h,099h,003h
                DB  0CDh,000h,09Ah,003h,0F3h,002h,0F2h,002h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  0AAh,001h,0ABh,001h,0A9h,001h,0B2h,001h
                DB  0B3h,001h,0B1h,001h,09Bh,003h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,020h,003h
                DB  021h,003h,022h,003h,023h,003h,024h,003h
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
                DB  04Dh,003h,04Eh,003h,04Fh,003h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,000h,004h
                DB  000h,004h,000h,004h,000h,004h,094h,003h
                DB  095h,003h,096h,003h,097h,003h,098h,003h
                DB  000h,004h,000h,004h,000h,004h,02Dh,02Dh
                DB  007h,006h,0FFh,0FFh,0FFh,078h,019h,019h
                DB  019h,0B3h
dtc_scan_new_code_tbl:       DB  00Bh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh
                DB  0FFh,0FFh,0FFh,0FFh,02Dh,02Dh,0FFh,02Dh
                DB  02Dh,006h,02Dh,00Fh,00Fh,0FFh,0FFh,0FFh
                DB  0FFh,007h,007h,014h,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,02Dh,02Dh,007h,006h,0FFh,0FFh,0FFh
                DB  078h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh
                DB  0B3h
cfgvariant_index_lookup_tbl:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah
                DB  00Bh,00Ch,00Ch,00Dh,00Eh,011h,000h,013h
                DB  014h,015h,016h,017h,018h,000h,000h,000h
                DB  000h,019h,01Ah,01Bh,000h,000h,000h,000h
                DB  000h,004h,008h,009h,00Fh,000h,000h,010h
                DB  013h,004h,008h,009h,000h,000h,000h,000h
                DB  01Dh
tbl_diag_snapshot_data1:       DB  000h,092h,007h
tbl_diag_snapshot_data2:       DB  0FFh,078h,019h,019h,019h
tbl_crank_sync_pattern:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FEh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FDh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FEh,0FFh,0FFh,0FFh,0FFh,0FFh,0FDh
tbl_crank_tooth_pattern:       DB  007h,008h,009h,00Ah,00Bh,000h,001h,002h,003h,004h
                DB  005h,006h,007h,008h,009h,00Ah,00Bh,000h,001h,002h
                DB  003h,004h,005h,006h,007h,008h,009h,00Ah,00Bh,000h
rpm_decel_limit_check_tbl:       DB  053h,007h,0A9h,003h,0D4h,001h,0EAh,000h,000h,000h
fueltbl_sanitize_advance_tbl:       DB  000h,000h,077h,022h,0EEh,044h,077h,044h,0DDh,088h
                DB  0FFh,0FFh,0EEh,088h,077h,088h,0BBh,011h,0BBh,022h
                DB  0FFh,0FFh,0BBh,044h,0DDh,011h,0DDh,022h,0EEh,011h
                DB  000h,000h,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
newval_table3_call_tbl_3:       DB  000h,030h,050h,070h,090h,0B0h,0D0h,0E0h,0F0h,000h
Scaler_RpmAxis_Lo:       DB  000h,00Dh,01Ah,026h,040h,050h,060h,070h,080h,088h
                DB  090h,0A0h,0A6h,0B0h,0C0h,0C8h,0D0h,0E0h,0F0h,000h
Scaler_RpmAxis_Hi:       DB  000h,011h,01Ch,02Bh,039h,047h,055h,064h,072h,080h
                DB  08Eh,095h,09Ch,0A3h,0ABh,0B9h,0C7h,0D5h,0E4h,000h
fuelmap_base_lookup_tbl:       DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D2h
                DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D3h
                DB  030h,07Fh,099h,0A6h,0ACh,0B2h,0B9h,0C7h,0C6h,0D4h
                DB  030h,080h,099h,0A7h,0ACh,0B3h,0B9h,0CAh,0C7h,0D6h
                DB  030h,089h,0A1h,0ABh,0B1h,0B7h,0BDh,0CEh,0C5h,0D2h
                DB  042h,090h,0A9h,0B4h,0BBh,0BEh,0C3h,0D2h,0CCh,0D7h
                DB  045h,096h,0A9h,0B6h,0BCh,0C0h,0C5h,0D4h,0CFh,0DDh
                DB  042h,093h,0A8h,0B5h,0BCh,0C3h,0C8h,0D8h,0CEh,0DDh
                DB  042h,096h,0ABh,0B8h,0BFh,0C6h,0CCh,0DBh,0D4h,0DFh
                DB  042h,096h,0ABh,0B9h,0C0h,0C4h,0CAh,0DAh,0D0h,0DFh
                DB  03Dh,092h,0A7h,0B5h,0BEh,0C3h,0C9h,0DAh,0D2h,0E1h
                DB  04Fh,0A1h,0BAh,0C6h,0CEh,0D3h,0D7h,0E9h,0E0h,0EEh
                DB  04Fh,0A0h,0B8h,0C7h,0CFh,0D4h,0DAh,0EAh,0E0h,0EDh
                DB  053h,09Ah,0B4h,0C0h,0C9h,0CFh,0D4h,0E4h,0E0h,0EDh
                DB  046h,097h,0B3h,0C0h,0CAh,0D2h,0DDh,0EDh,0E2h,0EBh
                DB  053h,09Dh,0B5h,0C4h,0CEh,0D4h,0DAh,0EEh,0E1h,0EEh
                DB  064h,0ACh,0C6h,0D3h,0DAh,0E2h,0E6h,0F9h,0EBh,0F6h
                DB  06Ch,0BBh,0D0h,0DBh,0EAh,0EEh,0F1h,0FFh,0F4h,0FEh
                DB  06Ch,0BBh,0D0h,0DBh,0EAh,0EEh,0F1h,0FFh,0F4h,0FEh
                DB  06Ch,0BBh,0D0h,0DBh,0EAh,0EEh,0F1h,0FFh,0F4h,0FEh
                DB  001h,003h,004h,005h,006h,007h,008h,008h,009h,009h
fuelmap_base_lookup_tbl_2:       DB  018h,046h,05Dh,05Ch,069h,075h,074h,081h
                DB  08Dh,09Ch,018h,046h,05Dh,05Ch,069h,075h
                DB  074h,081h,08Dh,09Ch,018h,046h,05Dh,05Ch
                DB  069h,075h,074h,081h,08Dh,09Ch,018h,046h
                DB  05Dh,05Ch,069h,075h,074h,081h,08Dh,09Ch
                DB  018h,046h,05Dh,05Ch,069h,075h,074h
fueltbl_range_check_tbl:       DB  081h,08Dh,09Ch,01Bh,04Fh,071h,06Eh,07Ch
                DB  087h,083h,091h,08Fh,09Ch,01Bh,05Eh,081h
                DB  07Fh,095h,0A8h,0A6h,0B6h,0B4h,0C5h,03Dh
                DB  07Dh,09Ch,097h,0A7h,0B6h,0AFh,0BEh,0C1h
                DB  0CFh,01Bh,05Eh,084h,083h,098h,0A7h,0A2h
                DB  0B8h,0BBh,0C9h,020h,05Dh,086h,087h,09Ch
                DB  0AFh,0ACh,0BEh,0BBh,0C6h,025h,06Ch,08Eh
                DB  08Ch,09Eh,0AFh,0A8h,0B7h,0B2h,0B9h,02Ch
                DB  073h,093h,08Eh,0A1h,0AFh,0A9h,0B9h,0B4h
                DB  0BDh,03Bh,07Fh,0A2h,096h,0A8h,0B6h,0AFh
                DB  0C0h,0BDh,0C7h,063h,093h,0B0h,0A3h,0B4h
                DB  0C1h,0B7h,0C6h,0C1h,0CBh,06Eh,09Bh,0B8h
                DB  0A7h,0B6h,0C2h,0B7h,0C5h,0C1h,0CDh,063h
                DB  0A2h,0C3h,0B2h,0C5h,0D5h,0CBh,0DAh,0D4h
                DB  0E2h,07Ch,0C6h,0E6h,0D2h,0E2h,0EDh,0DCh
                DB  0EEh,0E7h,0F4h,078h,0C3h,0E5h,0D2h,0E7h
                DB  0F6h,0E8h,0F8h,0EDh,0F6h,07Ah,0C4h,0EBh
                DB  0D9h,0ECh,0F6h,0E5h,0F4h,0EAh,0F2h,07Ah
                DB  0C4h,0EBh,0D9h,0ECh,0F6h,0E5h,0F4h,0EAh
                DB  0F2h,001h,003h,004h,006h,007h,008h,00Ah
                DB  00Ah,00Bh,00Bh
fuelmap_base_lookup_tbl_3:       DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D2h
                DB  029h,07Ah,096h,0A3h,0AAh,0B2h,0B8h,0C9h,0C3h,0D3h
                DB  030h,07Fh,099h,0A6h,0ACh,0B2h,0B9h,0C7h,0C6h,0D4h
                DB  030h,080h,099h,0A7h,0ACh,0B3h,0B9h,0CAh,0C7h,0D6h
                DB  030h,089h,0A1h,0ABh,0B1h,0B7h,0BDh,0CEh,0C5h,0D2h
                DB  042h,090h,0A9h,0B4h,0BBh,0BEh,0C3h,0D2h,0CCh,0D7h
                DB  045h,096h,0A9h,0B6h,0BCh,0C0h,0C5h,0D4h,0CFh,0DDh
                DB  042h,093h,0A8h,0B5h,0BCh,0C3h,0C8h,0D8h,0CEh,0DDh
                DB  042h,096h,0ABh,0B8h,0BFh,0C6h,0CCh,0DBh,0D4h,0DFh
                DB  042h,096h,0ABh,0B9h,0C0h,0C4h,0CAh,0DAh,0D0h,0DFh
                DB  03Dh,092h,0A7h,0B5h,0BEh,0C3h,0C9h,0DAh,0D2h,0E1h
                DB  001h,003h,004h,005h,006h,007h,008h,008h,009h,009h
flag_dispatch_21d_212_tbl:       DB  05Ah,05Ah,05Ah,05Ah,047h,03Bh,02Ch,01Dh
                DB  015h,011h,05Ah,05Ah,05Ah,05Ah,049h,03Fh
                DB  034h,024h,01Ch,018h,05Ah,05Ah,05Ah,05Ah
                DB  04Bh,043h,03Bh,02Ch,023h,01Fh,05Ah,05Ah
                DB  05Ah,05Ah,04Fh,047h,041h,033h,02Ah,026h
                DB  06Fh,06Fh,06Fh,06Fh,061h,056h,04Dh,041h
                DB  039h,035h,08Ch,08Ch,08Ch,07Bh,069h,060h
                DB  059h,04Dh,046h,042h,097h,097h,097h,081h
                DB  06Fh,068h,062h,057h,050h,04Ch,0A1h,0A1h
                DB  0A1h,087h,073h,06Eh,067h,05Eh,055h,051h
                DB  0A9h,0A9h,0A9h,08Ch,077h,071h,06Bh,064h
                DB  05Ah,056h,0ABh,0ABh,0ABh,08Eh,07Ah,074h
                DB  06Eh,068h,05Eh,05Ah,0ACh,0ACh,0ACh,091h
                DB  07Eh,078h,072h,06Ch,062h,05Eh,0B3h,0B3h
                DB  0B3h,09Bh,08Ah,083h,07Ch,074h,068h,064h
                DB  0B5h,0B5h,0B5h,0A2h,093h,08Ah,081h,078h
                DB  06Dh,069h,0B8h,0B8h,0B8h,0ABh,09Dh,092h
                DB  089h,07Fh,075h,071h,0C0h,0C0h,0C0h,0B5h
                DB  0A6h,099h,08Eh,085h,07Dh,079h,0C2h,0C2h
                DB  0C2h,0B7h,0A8h,09Bh,090h,087h,07Dh,079h
                DB  0C2h,0C2h,0C2h,0B8h,0A9h,09Ch,090h,087h
                DB  07Dh,079h,0C4h,0C4h
vss_calc_skip_tbl:       DB  0C4h,0BAh,0ABh,09Ch,090h,087h,07Dh,079h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,09Ch,090h,087h
                DB  07Dh,079h,0C4h,0C4h,0C4h,0BAh,0ABh,09Ch
                DB  090h,087h,07Dh,079h
mode_flags_pack4_tbl:       DB  05Ah,05Ah,05Ah,05Ah,031h,01Ah,00Ch,000h,000h,000h
                DB  05Ah,05Ah,05Ah,05Ah,039h,023h,015h,006h,000h,000h
                DB  06Fh,06Fh,06Fh,06Fh,05Ah,040h,02Fh,023h,01Bh,017h
                DB  097h,097h,097h,081h,06Fh,060h,04Ch,03Eh,036h,032h
                DB  0A9h,0A9h,0A9h,08Ch,077h,06Eh,062h,055h,04Bh,046h
                DB  0ACh,0ACh,0ACh,091h,07Eh,076h,06Ch,062h,056h,052h
                DB  0B3h,0B3h,0B3h,09Bh,08Ah,082h,076h,069h,05Ch,058h
                DB  0B8h,0B8h,0B8h,0ABh,09Dh,091h,082h,074h,069h,065h
                DB  0C0h,0C0h,0C0h,0B5h,0A6h,099h,08Ah,07Ch,071h,06Dh
                DB  0C2h,0C2h,0C2h,0B7h,0A8h,09Bh,090h,085h,07Bh,077h
                DB  0C2h,0C2h,0C2h,0B8h,0A9h,09Ch,090h,087h,07Dh,079h
                DB  0C2h,0C2h,0C2h,0B8h,0A9h,09Ch,090h,087h,07Dh,079h
                DB  0C3h,0C3h,0C3h,0B9h,0AAh,09Ch,090h,087h,07Dh,079h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,09Ch,090h,087h,07Dh,079h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,09Ch,090h,087h,07Dh,079h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A2h,098h,08Eh,084h,081h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A3h,099h,091h,087h,083h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A0h,095h,089h,07Eh,07Ah
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A0h,094h,088h,07Dh,079h
                DB  0C4h,0C4h,0C4h,0BAh,0ABh,0A1h,098h,08Ch,081h,07Dh
flag_dispatch_21d_212_tbl_2:       DB  05Ah,05Ah,05Ah,05Ah,047h,03Bh,02Ch,01Dh,015h,011h
                DB  05Ah,05Ah,05Ah,05Ah,049h,03Fh,034h,024h,01Ch,018h
                DB  05Ah,05Ah,05Ah,05Ah,04Bh,043h,03Bh,02Ch,023h,01Fh
                DB  05Ah,05Ah,05Ah,05Ah,04Fh,047h,041h,033h,02Ah,026h
                DB  06Fh,06Fh,06Fh,06Fh,061h,056h,04Dh,041h,039h,035h
                DB  08Ch,08Ch,08Ch,07Bh,069h,060h,059h,04Dh,046h,042h
                DB  097h,097h,097h,081h,06Fh,068h,062h,057h,050h,04Ch
                DB  0A1h,0A1h,0A1h,087h,073h,06Eh,067h,05Eh,055h,051h
                DB  0A9h,0A9h,0A9h,08Ch,077h,071h,06Bh,064h,05Ah,056h
                DB  0ABh,0ABh,0ABh,08Eh,07Ah,074h,06Eh,068h,05Eh,05Ah
                DB  0ACh,0ACh,0ACh,091h,07Eh,078h,072h,06Ch,062h,05Eh
ve_table_result_store_tbl:       DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,09Bh,09Bh,09Bh
                DB  08Eh,08Eh,08Eh,08Eh,097h,097h,097h,09Bh,09Bh,09Bh
ve_result_flag_store_tbl:       DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,093h,093h,093h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,097h,097h,097h
                DB  08Eh,08Eh,08Eh,097h,097h,097h,097h,09Bh,09Bh,09Bh
                DB  08Eh,08Eh,08Eh,097h,097h,09Bh,09Bh,09Bh,09Bh,09Eh
                DB  08Eh,08Eh,08Eh,097h,09Bh,09Bh,09Bh,09Bh,09Eh,09Eh
                DB  08Eh,08Eh,097h,09Bh,09Bh,09Bh,09Bh,09Bh,09Eh,09Eh
crank_edge_flag_store_tbl_3:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
inj_accum_check2_add_acc:     ADD     A, off(001bah)
                CMP     A, #00100h
                JGE     inj_accum_check2_store_ram1ba
                CLR     A
inj_accum_check2_store_ram1ba:     ST      A, off(001bah)
                CLR     A
                J       inj_accum_store_114
inj_accum_check4_add_acc:     ADD     A, off(001b8h)
                CMP     A, #00100h
                JGE     inj_accum_check4_store_ram1b8
                CLR     A
inj_accum_check4_store_ram1b8:     ST      A, off(001b8h)
                J       inj_accum2_zero2
crank_pswl4_store_cmp_acc:     CMPB    A, r0
                JLE     crank_pswl4_store_goto_4d5c
                LB      A, [DP]
                ADDB    A, #001h
                CMPB    A, r0
                JLE     crank_pswl4_store_goto_4d5c
                J       crank_pswl4_store_if_ram117_bit0_clr
crank_pswl4_store_goto_4d5c:     J       crank_mul_alt_mulb_acc
timer2_irq_clear_orb_off_irq:     ORB     off(IRQ), #008h
                RB      TRNSIT.0
                JEQ     timer2_irq_clear_return
                SB      09fh.2
timer2_irq_clear_return:     RTI
; [CG] diag_report_finalize  @0x7681
; [CG] TRACED: writes into the diagnostic-snapshot RAM area (0x3AC/0x3D4, adjacent to
; [CG] cfgvariant_snapshot_capture's own 0x340 block), gated by off(120h).2 and off(122h).1, and
; [CG] hands off to fuelmap_do_lookup_b35. A second stage of the diagnostic/serial report
; [CG] construction.
diag_report_finalize:     JBR     off(00122h).1, diag_report_finalize_load_dp
                CLR     A
diag_report_finalize_load_dp:     MOV     DP, #003d4h
                ST      A, [DP]
                MOV     DP, #003ach
                J       diag_report_finalize_store_dp_ind
crank_tooth_count_store_set_ram120_bit2:     SB      off(00120h).2
                RB      PSWH.0
                MOVB    off(001b6h), #077h
                MOVB    off(001beh), #011h
                SB      PSWH.0
                J       crank_cycle_dispatch2
threshold_bank_217_0_load_carry_ram0a0_bit6:     MB      C, 0a0h.6
                JBR     off(00227h).5, threshold_bank_217_0_goto_0a01
                MOVB    r2, off(00236h)
                MB      C, 0a0h.7
threshold_bank_217_0_goto_0a01:     J       threshold_bank_217_0_store_carry_pswl_bit4
flag_dispatch_21d_212:     JBS     off(00227h).5, flag_dispatch_21d_212_goto_ignmap_2d_lookup
                JBS     off(0021fh).1, flag_dispatch_21d_212_goto_ignmap_2d_lookup
                J       flag_dispatch_21d_212_load_r3
flag_dispatch_21d_212_goto_ignmap_2d_lookup:     J       ignmap_2d_lookup
diag_mode_code_store_clear_carry:     RC
                LCB     A, diag_mode_code_store_tbl_2
                JNE     diag_mode_code_store_goto_493f
                J       diag_mode_code_store_load_dp
diag_mode_code_store_goto_493f:     J       diag_mode_code_store_rolb_r0_2
boot_completion_helper_clear_carry_2:     RC
                LCB     A, idle_init_start_tbl
                STB     A, r0
                JNE     boot_completion_helper_store_carry_ram227_bit5
                LCB     A, diag_mode_code_store_tbl_2
                JEQ     boot_completion_helper_store_carry_ram227_bit5
                SLLB    r1
                SLLB    r1
                MOVB    r1, #080h
boot_completion_helper_store_carry_ram227_bit5:     MB      off(00227h).5, C
                MOV     DP, #003c7h
                J       boot_completion_helper_load_dp_ind
boot_completion_helper_rom_load_tbl_600f:     LCB     A, diag_mode_code_store_tbl_2
                JEQ     boot_completion_helper_goto_55c5
                SLLB    r2
                MOVB    r2, #080h
                RORB    r2
boot_completion_helper_goto_55c5:     J       boot_completion_helper_load_r2
crankfuel_timer_wait_loop_sll_er0:     SLL     er0
                RB      off(00122h).0
                J       crankfuel_timer_wait_loop_if_eq_goto_cylinder_index_adva
sensor_check_vcal3_if_ram217_bit5_set:     JBS     off(00217h).5, sensor_check_vcal3_load_ram2be
                JBS     off(00230h).5, sensor_check_vcal3_goto_sensor_check_clear
                J       sensor_check_vcal3_cmp_ram236
sensor_check_vcal3_load_ram2be:     MOVB    off(002beh), #064h
sensor_check_vcal3_goto_sensor_check_clear:     J       sensor_check_clear
prep_lowpower_seq_store_tmr1:     ST      A, TMR1
                SLL     er0
                DIV
                DIV
                J       prep_lowpower_seq_load_carry_ram09f_bit1
int_serial_rx_BRG_if_ram112_bit7_set:     JBS     off(00112h).7, int_serial_rx_BRG_set_ram120_bit4
                J       int_serial_rx_BRG_clear_irqh_bit7
int_serial_rx_BRG_set_ram120_bit4:     SB      off(00120h).4
                J       crank_sync_retry_check
knockwindow_gate_start_if_ram214_bit5_set:     JBS     off(00214h).5, knockwindow_gate_start_goto_knockwindow_clear_2
                MB      C, P1.6
                J       knockwindow_gate_start_if_ge_goto_knockwindow_clear
knockwindow_gate_start_goto_knockwindow_clear_2:     J       knockwindow_clear
crank_cycle_p4_gate_if_ram121_bit1_clr:     JBR     off(00121h).1, crank_cycle_p4_gate_goto_crank_cycle_f4_check
                JBS     off(00112h).2, crank_cycle_p4_gate_if_ram118_bit0_set
                JBR     off(00112h).4, crank_cycle_p4_gate_goto_crank_cycle_result_common
crank_cycle_p4_gate_if_ram118_bit0_set:     JBS     off(00118h).0, crank_cycle_p4_gate_goto_crank_cycle_result_a
crank_cycle_p4_gate_goto_crank_cycle_result_common:     J       crank_cycle_result_common
crank_cycle_p4_gate_goto_crank_cycle_result_a:     J       crank_cycle_result_a
crank_cycle_p4_gate_goto_crank_cycle_f4_check:     J       crank_cycle_f4_check
idle_target_final_store_call_stub_or_short_helper:     CAL     stub_or_short_helper
                VCAL    6
                CLR     A
                JBS     off(00212h).2, idle_target_final_store_load_imm
                JBR     off(00212h).4, idle_target_final_store_goto_idle_output_vcal5
idle_target_final_store_load_imm:     L       A, #02000h
idle_target_final_store_goto_idle_output_vcal5:     J       idle_output_vcal5
ignition_timing_calc_task_load_ram2cf:     LB      A, off(002cfh)
                JEQ     ignition_timing_calc_task_set_ram222_bit6
                J       ignition_timing_calc_task_load_ram29f_2
ignition_timing_calc_task_set_ram222_bit6:     SB      off(00222h).6
                JEQ     ignition_timing_calc_task_load_dp_2
                J       ignition_timing_calc_task_load_ram29f
ignition_timing_calc_task_load_dp_2:     MOV     DP, #00316h
                JBS     off(0022fh).7, ignition_timing_calc_task_load_dp_ind_2
                MOV     DP, #00318h
ignition_timing_calc_task_load_dp_ind_2:     L       A, [DP]
                ST      A, off(0029ah)
                J       ignition_timing_calc_task_if_eq_goto_3475
ignition_timing_calc_task_clear_ram22f_bit2_2:     RB      off(0022fh).2
                RB      off(0022fh).1
                J       ignition_timing_calc_task_store_ram298
ignition_timing_calc_task_load_dp_ind_3:     L       A, [DP]
                SJ      ignition_timing_calc_task_cmp_acc_10
ignition_timing_calc_task_if_lt_goto_7787:     JLT     ignition_timing_calc_task_load_imm_4
ignition_timing_calc_task_cmp_acc_10:     CMP     A, #003ffh
                JLT     ignition_timing_calc_task_goto_34c3
ignition_timing_calc_task_load_imm_4:     L       A, #003ffh
ignition_timing_calc_task_goto_34c3:     J       ignition_timing_calc_task_goto_34c9
ignition_timing_calc_task_sll_acc:     SLL     A
                JLT     ignition_timing_calc_task_goto_3558
                SLL     A
                JGE     ignition_timing_calc_task_goto_355b
ignition_timing_calc_task_goto_3558:     J       ignition_timing_calc_task_load_imm_2
ignition_timing_calc_task_goto_355b:     J       ignition_timing_calc_task_load_r1
ignition_timing_calc_task_if_ge_goto_779d:     JGE     ignition_timing_calc_task_clear_r0_2
                MOVB    r1, #0ffh
ignition_timing_calc_task_clear_r0_2:     CLRB    r0
                L       A, [DP]
                J       ignition_timing_calc_task_mul_acc_2
ignition_timing_calc_task_sll_acc_2:     SLL     A
                L       A, er1
                ROL     A
                CAL     clamp_0_3ff_simple
                J       ignition_timing_calc_task_if_ram22f_bit2_set
ignition_timing_calc_task_cmp_acc_11:     CMP     A, #003ffh
                JGE     ignition_timing_calc_task_goto_3590
                J       ignition_timing_calc_task_cmp_acc_5
ignition_timing_calc_task_goto_3590:     J       ignition_timing_calc_task_load_imm_3
ignition_timing_calc_task_clear_ram22f_bit1:     RB      off(0022fh).1
ignition_timing_calc_task_clear_ram222_bit6:     RB      off(00222h).6
ignition_timing_calc_task_store_ram298:     ST      A, off(00298h)
                J       ignition_timing_calc_task_cmp_acc_6
ignition_timing_calc_task_clear_ram22f_bit2_3:     RB      off(0022fh).2
                SJ      ignition_timing_calc_task_clear_ram222_bit6
; [CG] clamp_0_3ff_simple  @0x77C7
; [CG] VERIFIED: clamps A to [0, 0x3FF] using a simpler direct-compare form than
; [CG] clamp_0_to_3ff (no register-pair bound source, just two fixed compares).
clamp_0_3ff_simple:     JLT     clamp_0_3ff_simple_load_imm
                CMP     A, #003ffh
                JLT     clamp_0_3ff_simple_return
clamp_0_3ff_simple_load_imm:     L       A, #003ffh
clamp_0_3ff_simple_return:     RT
cfg_selector3_dispatch:     JBS     off(00217h).6, cfg_selector3_dispatch_goto_2b7d
                CMP     off(00280h), #08000h
                JGE     cfg_selector3_dispatch_goto_5809
                J       cfg_selector3_dispatch_goto_5802
cfg_selector3_dispatch_goto_5809:     J       cfg_selector3_dispatch_cmp_acc
cfg_selector3_dispatch_goto_2b7d:     J       cfg_selector3_dispatch_goto_idle_ectvs_result1
                DB  043h,000h,043h,000h,043h,000h,043h,000h
                DB  030h,000h,043h,000h,043h,000h,043h,000h
                DB  043h,000h,043h,000h,030h,000h,043h,000h
                DB  07Ch,003h,035h,004h,0EAh,003h,09Ch,002h
                DB  080h,000h,09Ch,002h,07Ch,003h,05Ah,004h
                DB  05Ah,004h,05Ah,004h,080h,000h,05Ah,004h
o2_trim_result_check_load_acch:     LB      A, ACCH
                JBS     off(0011eh).4, o2_trim_result_check_goto_1b43
                LB      A, #004h
o2_trim_result_check_goto_1b43:     J       o2_trim_result_check_inc_dp
o2_trim_rpm_alt_check_load_x1:     MOV     X1, #00005h
                JBR     off(0011eh).4, o2_trim_rpm_alt_check_goto_o2_trim_rate_table_select
                JBS     off(00118h).0, o2_trim_rpm_alt_check_goto_o2_trim_bank_index_alt
                J       o2_trim_rpm_alt_check_load_stk
o2_trim_rpm_alt_check_goto_o2_trim_bank_index_alt:     J       o2_trim_bank_index_alt
o2_trim_rpm_alt_check_goto_o2_trim_rate_table_select:     J       o2_trim_rate_table_select
coldstart_full_reset_clear_ram221_bit7:     RB      off(00221h).7
                SB      (0011eh-00180h)[USP].4
                SB      off(0021eh).4
                J       coldstart_full_reset_orb_tcon3
idle_state_defaults_if_ram219_bit0_clr:     JBR     off(00219h).0, idle_state_defaults_goto_idle_stage_b7_store
                JBR     off(0021eh).4, idle_state_defaults_goto_426c
                J       idle_state_defaults_load_stk
idle_state_defaults_goto_idle_stage_b7_store:     J       idle_stage_b7_store
idle_state_defaults_goto_426c:     J       idle_stage_c0_load_clear_ram219_bit0
purge_counter_check:     JBR     off(00218h).0, purge_counter_check_cmp_stk
                JBR     off(0021eh).4, purge_counter_check_goto_purge_result_clear
purge_counter_check_cmp_stk:     CMP     (001b4h-00180h)[USP], #005dch
                J       purge_counter_check_if_lt_goto_purge_result_clear
purge_counter_check_goto_purge_result_clear:     J       purge_result_clear
knockwindow_gate_start_if_ram217_bit3_set:     JBS     off(00217h).3, knockwindow_gate_start_cmp_acc_2
                JBS     off(0021eh).4, knockwindow_gate_start_goto_knockwindow_clear_3
knockwindow_gate_start_cmp_acc_2:     CMP     A, #06000h
                J       knockwindow_gate_start_if_le_goto_knockwindow_set
knockwindow_gate_start_goto_knockwindow_clear_3:     J       knockwindow_clear
crank_tooth_counter_reset_if_ram113_bit0_set:     JBS     off(00113h).0, crank_tooth_counter_reset_clear_ram11d_bit6
                J       crank_tooth_counter_reset_clear_ram09f_bit2
crank_tooth_counter_reset_clear_ram11d_bit6:     RB      off(0011dh).6
                J       crank_tooth_seq_check
tps_hysteresis_reentry_if_ram116_bit3_clr:     JBR     off(00116h).3, tps_hysteresis_reentry_goto_postig_gate_chain2
                JBS     off(00111h).5, tps_hysteresis_reentry_goto_postig_result_default
tps_hysteresis_reentry_goto_postig_gate_chain2:     J       postig_gate_chain2
tps_hysteresis_reentry_goto_postig_result_default:     J       postig_result_default
cfgvariant_check_v5_16_17_cmp_r7:     CMPB    r7, #015h
                JNE     cfgvariant_check_v5_16_17_goto_5468
                J       cfgvariant_check_v5_16_17_incb_r0
cfgvariant_check_v5_16_17_goto_5468:     J       cfgvariant_check_v5_16_17_goto_cfgvariant_remap_start
cfgvariant_check_v5_16_17_cmp_r7_2:     CMPB    r7, #016h
                JNE     cfgvariant_check_v5_16_17_goto_5474
                J       cfgvariant_check_v5_16_17_incb_r0_2
cfgvariant_check_v5_16_17_goto_5474:     J       cfgvariant_check_v5_16_17_goto_cfgvariant_remap_start_2
overrev_hardcap_compare_cmp_stk:     CMPB    (001cah-00180h)[USP], #003h
                JNE     overrev_hardcap_compare_goto_knockretard2_store
                LB      A, #000h
                CMPB    0c1h, #028h
                JGE     overrev_hardcap_compare_goto_knockretard2_store
                J       overrev_hardcap_compare_load_imm
overrev_hardcap_compare_goto_knockretard2_store:     J       knockretard2_store
