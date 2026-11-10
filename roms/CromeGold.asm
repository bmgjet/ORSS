;==================================================================================================
; CromeGold.asm -- annotation pass (labels/comments only; firmware bytes unchanged)
; Assembles to the original image byte for byte.
; Label sources: HTS115-Full-Comments.asm (matched code), the custom1 ROM (secondary, where noted in the
; rename log), otherwise structural names built from what the labelled code does:
;   <context>_<action>   context = nearest named routine that reaches this block,
;                        action  = first instruction (load_/store_/cmp_/if_<ram>_b<n>_set/goto_/call_...)
;   ramXXX = RAM address XXXh, stk = user-stack frame slot.
; Comment lines tagged [H] were carried over from HTS115 (comments credited to bmgjet) onto code that
; is instruction-for-instruction identical to the HTS115 code they describe.
;==================================================================================================
; ---- RAM symbols (CromeGold previously used these names without defining them -> the file
;      did not assemble; asm662 silently used 0 for each). Values taken from the original bytes.
coolantTempByte      equ 0c1h ; processed coolant temp. RENAMED from ZoneIndex: 26 matched code sites map it to HTS115 0xD9, which HTS compares against VtecECTMin/IDLEignECT/ECTProtectC and stamps with 03Bh on ECT fault; CG does the same MOVB ...,#03bh at 0x2489
ECT_raw              equ 0c2h ; loaded from ADCR0H / [003BEh]. Name inherited, NOT independently verified (HTS115 equivalent 0xDA = filtered ADCR0H copy)
IAT_raw              equ 0c3h ; loaded from [003C5h]. Name inherited, NOT independently verified (HTS115 equivalent 0xDB)
TPS2_raw             equ 0c5h ; last ADCR2H sample (0x0721). Name inherited; ADC ch2 = TPS not independently verified
TPS2_rate            equ 0c6h ; |ADCR2H - previous| (0x0721-0x072A, VCAL 7 = negate). Name inherited
TPS_pct              equ 0a6h ; Name inherited, NOT independently verified (HTS115 equivalent 0xBE)
adc_Ch4_word         equ 0cch ; 16-bit copy of ADCR4 (0x246D)
adc_Ch5_new          equ 0bfh ; copy of ADCR5H (0x1052)
adc_Ch6_word         equ 0a2h ; 16-bit copy of ADCR6 (0x03AA, 0x2497)
;==================================================================================================
; CromeGold.asm  --  ANNOTATED AND FULLY SYMBOLISED
; Honda OBD1 ECU, OKI/MSM 66207, 32 KiB ROM
;==================================================================================================
                org 0000h   ;
int_start_vec:            DW  int_start
int_break_vec:            DW  int_break
int_WDT_vec:              DW  int_WDT
int_NMI_vec:              DW  int_NMI
int_INT0_vec:             DW  int_INT0
int_serial_rx_vec:        DW  int_serial_rx
int_serial_tx_vec:        DW  int_serial_tx
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
int_serial_tx_BRG_vec:    DW  int_spurious_irq_trap_body
int_INT1_vec:             DW  int_INT1
vcal_0_vec:               DW  table_interp_lookup
vcal_1_vec:               DW  table_interp_search_stride3
vcal_2_vec:               DW  table_interp_clamp_stride2
vcal_3_vec:               DW  table_interp_clamp_stride3
vcal_4_vec:               DW  background_task_scheduler
vcal_5_vec:               DW  signed_add_sat16_dispatch
vcal_6_vec:               DW  signed_add_sat16
vcal_7_vec:               DW  negate_if_signed
code_start:     DB  043h,000h,060h,0F3h
int_NMI:        CLR     PSW
                MOV     LRB, #00041h  ; [H] local register base = #00041h (base address 0x0208)
                RB      off(00230h).7  ; [H] test-and-reset edge-detect bit 00230h.7
                JEQ     nmi_snapshot_dp_skip  ; [H] skip snapshot if bit was already 0
                L       A, DP  ; [H] bit just transitioned 1->0: snapshot DP
                ST      A, 00084h[X1]  ; [H] ...into 00084h[X1]
nmi_snapshot_dp_skip:     MOV     DP, #00009h
nmi_poll_p4_1:     MB      C, P4.1  ; [H] sample pin P4.1 into carry
                JGE     nmi_enter_lowpower_seq  ; [H] JGE branches on Carry=0 (arch.ml) -> as soon as P4.1 reads 0, jump ahead immediately
                JRNZ    DP, nmi_poll_p4_1  ; [H] else (P4.1 still 1) keep polling until DP counts out, then fall through anyway
                J       nmi_poll_p4_1_set_p2
nmi_poll_p4_1_store_adsel:     STB     A, ADSEL  ; [H] clear A/D channel select
                MOV     IE, #00040h  ; [H] mask interrupt-enable to one source
                MOVB    TCON1, #0e0h
                CLR     IRQ  ; [H] clear pending IRQ flags
                SB      P4SF.1
                MOV     TM1, #0ffffh  ; [H] reload timer1 to max (effectively stop it counting down soon)
                SB      TCON1.4
                SB      SBYCON.2  ; [H] standby-control bit set (see routine note above)
                LB      A, #005h
; [H] STPACP = "Stop Code Acceptor" per the MSM66207 datasheet -- not a clock prescaler. Writing
; [H] N then N<<1 (5, then 10) is the write-unlock sequence this register requires before STOP/HALT
; [H] mode will actually be entered; it's a safety interlock against accidental entry, not a divider.
                STB     A, STPACP  ; [H] stop-code-acceptor unlock write, step 1: N=5
                SLLB    A  ; [H] ...step 2: N<<1=10
                STB     A, STPACP  ; [H] unlock write, step 2
                SB      SBYCON.0  ; [H] standby-control bit 0 set (likely the actual STOP-mode trigger)
                RB      09fh.1
nmi_enter_lowpower_seq:     J       nmi_enter_lowpower_seq_load_rameb
                DW  00001h
int_timer_0:    MOV     LRB, #00037h
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
                J       timer2_irq_clear_or_irq
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
                ANDB    SRSTAT, #0f3h
                CLR     A
                LB      A, SRBUF
                STB     A, r1
                CMPB    A, #0abh
                JNE     int_serial_rx_cmp_r1
                LB      A, #0bch
int_serial_rx_store_stbuf:     STB     A, STBUF
int_serial_rx_load_ramf2:     L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
int_serial_rx_cmp_r1:     CMPB    r1, #046h
                JNE     int_serial_rx_cmp_r1_2
                CLRB    r0
                STB     A, r5
                SJ      int_serial_rx_store_stbuf
int_serial_rx_cmp_r1_2:     CMPB    r1, #043h
                JNE     int_serial_rx_load_3f
                MOVB    0f5h, #046h
                RB      0b7h.1
                BRK
int_serial_rx_load_3f:     LB      A, #03fh
                SJ      int_serial_rx_store_stbuf
int_serial_tx:  L       A, 0f4h
                OR      A, #00002h
                ST      A, IE
                MOV     PSW, #00102h
                MOV     LRB, #0006fh
                CMPB    r1, #046h
                JNE     int_serial_tx_clear_a
                CMPB    r0, #000h
                JNE     int_serial_tx_load_r4
                INCB    r0
                MOV     er1, #00290h
                LB      A, #026h
                STB     A, r4
                ADDB    r5, A
                SJ      int_serial_rx_store_stbuf
int_serial_tx_load_r4:     LB      A, r4
                SUBB    A, r0
                JLT     int_serial_tx_clear_r1
                LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                MOV     DP, er1
                LC      A, [DP]
                MOV     DP, A
                LB      A, [DP]
                ADDB    r5, A
                INCB    r0
                INC     er1
                INC     er1
                SJ      int_serial_rx_store_stbuf
int_serial_tx_clear_r1:     CLRB    r1
                LB      A, r5
                SJ      int_serial_rx_store_stbuf
int_serial_tx_clear_a:     CLR     A
                MOV     er0, A
                MOV     er1, A
                MOV     er2, A
                MOV     er3, A
                SJ      int_serial_rx_load_ramf2
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0ACh,000h,0ADh
                DB  000h,0D8h,001h,0D9h,001h,0D2h,001h,0C6h
                DB  001h,0C7h,001h,05Ch,003h,043h,002h,0C2h
                DB  000h,048h,001h,049h,001h,04Ah,001h,04Bh
                DB  001h,010h,002h,011h,002h,020h,000h,022h
                DB  000h,0B4h,000h,0C3h,000h,0A3h,000h,06Fh
                DB  000h,0B9h,000h,0C0h,003h,0C1h,003h,0C2h
                DB  003h,0C3h,003h,0C4h,003h,0C5h,003h,0C6h
                DB  003h,0C7h,003h,0C8h,003h,0A0h,000h,054h
                DB  003h,012h,001h,013h,001h,014h,001h,015h
                DB  001h,0FFh
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
                LB      A, r0
                ADDB    A, #001h
                CMPB    A, #0a3h
                JLT     int_PWM_timer_store_r0
                MOVB    r1, 0dfh
                CLRB    A
int_PWM_timer_store_r0:     STB     A, r0
                CMPB    A, r1
                XORB    PSWH, #000h
                NOP
                NOP
                NOP
                L       A, 0f2h
                ANDB    PSWH, #0feh
                ST      A, IE
                RTI
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,02Bh
                DB  02Bh,02Bh,02Bh,02Bh,02Bh,02Bh,02Bh,02Bh
                DB  02Bh,02Bh,02Bh,02Bh,02Bh,02Bh,02Bh,02Bh
                DB  02Bh,02Bh,02Bh,02Bh,02Bh,02Bh,02Bh,02Bh
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
                ST      A, adc_Ch6_word
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
                J       crank_tooth_count_test_ram113_bit6
crank_tooth_count_if_ram120_bit2_set:     JBS     off(00120h).2, int1_exit_jump
                LB      A, off(00135h)
                JNE     int1_exit_jump
                J       crank_tooth_count_set_ram120_bit2
int1_exit_jump:     J       crank_cycle_dispatch2

;--------------------------------------------------------------------------------------------
; int_serial_rx_BRG  @0x03DC
;   HARDWARE-CONFIRMED entry point (vector 0x000E, per the ROM vector table) but the CODE
;   HAS NOTHING TO DO WITH SERIAL RECEPTION. Its real body (0x03DC-0x0684, properly
;   RTI-terminated - this is NOT a scoping bug) copies a USP-relative stack frame the same
;   way refresh_engine_flags_snapshot does, directly updates TMR0 (the hardware
;   injector/ignition timer register), calls tm0_resync_helper three times, calls
;   crank_helper2, and cycles a modulo-4 gear/state index at off(0x134). This
;   strongly suggests the serial baud-rate-generator timer is being repurposed as a
;   free-running periodic tick source for crank/gear housekeeping, decoupled from any
;   actual serial activity. Kept the hardware-accurate name since that correctly describes
;   when this code runs; the evidence here describes what it actually does.
;--------------------------------------------------------------------------------------------
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
int_serial_rx_BRG_clr_irqh_bit7:     RB      IRQH.7
                JNE     int_serial_rx_BRG_set_ram120_bit4
                RB      09eh.7
                JEQ     crank_sync_retry_check
int_serial_rx_BRG_set_ram120_bit4:     SB      off(00120h).4
                RB      off(00120h).6
                MOVB    off(001aah), #02dh
                L       A, 0d2h
                CMP     A, #00005h
                JEQ     crank_tooth_counter_reset
                SB      off(0011dh).6
                JLT     int_serial_rx_BRG_set_ram120_bit5
                CMP     A, #00105h
                JGE     crank_sync_flag_high
                SB      09dh.0
                SJ      crank_tooth_counter_reset
crank_sync_retry_check:     CMPB    0d2h, #005h
                JGE     crank_sync_confirm_check
                INCB    0d2h
                J       crank_tooth_counter_goto
crank_sync_confirm_check:     JBS     off(00112h).7, crank_sync_confirmed
dtc08_tdc_latch_2: SB      09ch.1
                SB      off(00120h).6
crank_sync_confirmed:     INCB    0d3h
                CLRB    0d2h
                SJ      crank_tooth_counter_goto
crank_sync_flags_clear_path:     RB      IRQH.7
                RB      09eh.7
                RB      09fh.2
                MB      C, 09fh.0
                JGE     crank_sync_exit_jump
                SB      off(00120h).4
crank_sync_exit_jump:     J       crank_decode_exit
int_serial_rx_BRG_set_ram120_bit5:     SB      off(00120h).5
                SJ      crank_tooth_counter_reset
crank_sync_flag_high:     SB      09dh.1
crank_tooth_counter_reset:     CLR     0d2h
crank_tooth_counter_goto:     J       crank_tooth_counter_if_ram113_bit0_set
crank_tooth_counter_clr_ram9f_bit2:     RB      09fh.2
                JNE     crank_tooth_counter_clr_ram120_bit7
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
                JEQ     crank_window_flag_set_ram9d_bit2
                SB      09dh.0
                SJ      crank_tooth_reset
crank_tooth_counter_set_ram9d_bit1:     SB      09dh.1
                SJ      crank_tooth_reset
crank_tooth_counter_clr_ram120_bit7:     RB      off(00120h).7
                MOVB    off(001abh), #007h
                L       A, off(0012ah)
                CMP     A, #00017h
                JNE     crank_window_flag_check2
                RB      off(00120h).5
                JNE     crank_tooth_counter_set_ram9d_bit1
                RB      off(0011dh).6
                CMPB    0d2h, #003h
                JEQ     crank_tooth_reset
crank_window_flag_set_ram9d_bit2:     SB      09dh.2
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

;--------------------------------------------------------------------------------------------
; crank_cycle_dispatch  @0x0685
;   RESCOPED (was cam_transition_detect, 878 bytes larger than originally measured; zero
;   RT/RTI found anywhere in its span): flows directly from cam-edge detection (off
;   113h.6/11Dh.6, TRNSIT SFR) into crank-edge processing (crank_edge_helper,
;   scaler_table_lookup) and a gear-cycle port output on P4.0. One continuous task, not a
;   standalone cam detector.
;--------------------------------------------------------------------------------------------
crank_cycle_dispatch:     JGE     crank_cycle_dispatch_alt
                CMPB    A, #001h
                JGE     crank_cycle_dispatch_alt2
                JBS     off(00113h).6, crank_cycle_p4_gate
                JBS     off(0011dh).6, crank_cycle_p4_gate
                MB      C, (002ffh-00280h)[USP].7
                JLT     crank_cycle_p4_gate
                NOP
                NOP
                RB      TRNSIT.1
                JNE     crank_cycle_p4_gate
dtc15_ign_output_latch: SB      09ch.3
                SJ      crank_cycle_p4_gate_if_ram117_bit2_set
crank_cycle_p4_gate:     RB      09ch.3
                MOVB    off(001ach), #006h
crank_cycle_p4_gate_if_ram117_bit2_set:     JBS     off(00117h).2, crank_cycle_dispatch_if_ram120_bit4_clr
                J       crank_cycle_p4_gate_if_ram121_bit1_clr
crank_cycle_f4_check:     LB      A, #001h
                CMPB    0eah, #024h
                JNE     crank_cycle_counter_check
                SB      off(00122h).4
crank_cycle_counter_check:     CMPB    off(001aah), #028h
                JLE     crank_cycle_result_b
                JBS     off(00117h).4, crank_cycle_result_a
                JBS     off(00122h).4, crank_cycle_result_b_shr_a
                JBS     off(00112h).5, crank_cycle_result_a
                CMPB    coolantTempByte, #020h
                JLT     crank_cycle_result_b_shr_a
crank_cycle_result_a:     LB      A, #003h
                SJ      crank_cycle_result_b_shr_a
crank_cycle_result_b:     SB      off(00120h).4
crank_cycle_result_b_shr_a:     SRLB    A
                MB      off(0011eh).0, C
                SRLB    A
                MB      P4.0, C
                SJ      crank_cycle_entry
crank_cycle_dispatch_alt:     CMPB    A, #004h
                JNE     crank_cycle_entry
                J       crank_cycle_dispatch_body
crank_cycle_bailout:     SJ      crank_cycle_entry
crank_cycle_dispatch_alt2:     JEQ     crank_cycle_entry
crank_cycle_dispatch_if_ram120_bit4_clr:     JBR     off(00120h).4, crank_cycle_bailout
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
                LB      A, TPS2_raw
                STB     A, [DP]
                LB      A, ADCR2H
                STB     A, TPS2_raw
                SUBB    A, r0
                MB      off(0022bh).5, C
                JGE     crank_cycle_adc_prep
                VCAL    7
crank_cycle_adc_prep:     STB     A, TPS2_rate
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
crank_cycle_adc_prep_load_ind:     L       A, [DP]
                JEQ     rpm_period_invalid
                ADD     er1, A
                ADCB    r0, #000h
                INC     DP
                INC     DP
                CMP     DP, #0036ch
                JLT     crank_cycle_adc_prep_load_ind
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
                MOV     DP, #rpm_decel_limit_check_data
rpm_divide_normalize_loop:     LC      A, [DP]
                CMP     er2, A
                JGE     rpm_divide_normalize_load_x1
                SRL     er0
                ROR     X1
                ADD     er3, #00040h
                INC     DP
                INC     DP
                SJ      rpm_divide_normalize_loop
rpm_divide_normalize_load_x1:     L       A, X1
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
                J       loadindex_lookup_done
loadindex_lookup_done_load_acc:     LB      A, ACC
                CMPB    A, #0ffh
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
tps_custom_clamp_store:     STB     A, TPS_pct
                MOV     er0, #04d00h
                RC
                JBS     off(00212h).6, dtc07_tps_latch
                J       tps_custom_clamp_store_load_adcr7h
tps_custom_clamp_store_load_fc:     LB      A, #0fch
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
; [H] --- Repeated rate-of-change/plausibility check pattern applied to several TPS-related raw
; [H] values (0xD0/0xD2/0xD4/0xD6) across 0x852-0x8C9: compute delta, clamp to 0xFF, trigger
; [H] VCAL 7 (erratic-sensor diagnostic, same call used for RPM plausibility earlier) if out of
; [H] range. No calibration anchors; likely dual/redundant TPS channel handling.
tps_delta_store1:     STB     A, 0bch
                L       A, er0
                XCHG    A, 0b8h
                MOV     er1, 0bah
                ST      A, 0bah
                JBR     off(00212h).7, tps_delta_check1
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
                J       tps_interp_store_set_er0
rpm_avg_range_check_store_ramb2:     ST      A, 0b2h
                LB      A, #098h
                JBS     off(0022bh).0, threshold_bank_218_5
                LB      A, #0a0h
threshold_bank_218_5:     CMPB    A, off(00236h)
                MB      off(0022bh).0, C
                LB      A, #0cdh
                JBS     off(00218h).7, threshold_bank_218_5_cmp_ram236
                LB      A, #0d0h
threshold_bank_218_5_cmp_ram236:     CMPB    A, off(00236h)
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
                CAL     scaler_table_lookup
                STB     A, (001dah-00180h)[USP]
                LB      A, r6
                STB     A, (001d8h-00180h)[USP]

;--------------------------------------------------------------------------------------------
; scaler_rpm_hi_call  @0x09F3
;   TRACED: scaler_table_lookup with tbl 0x6E86, r6=18.
;--------------------------------------------------------------------------------------------
                MOV     X1, #Scaler_RpmAxis_Hi
                MOVB    r3, (001d9h-00180h)[USP]
                MOVB    r2, off(002feh)
                MOVB    r6, #012h
                J       threshold_bank_217_0_test_rama0_bit6
threshold_bank_217_0_carry_to_pswl_bit4:     MB      PSWL.4, C
                CAL     scaler_table_lookup
                STB     A, (001dch-00180h)[USP]
                LB      A, r6
                STB     A, (001d9h-00180h)[USP]
                LB      A, 0a4h
                JBS     off(00212h).2, threshold_bank_217_0_store_r2
                JBS     off(00212h).4, threshold_bank_217_0_store_r2
                LB      A, (001a1h-00180h)[USP]
threshold_bank_217_0_store_r2:     STB     A, r2

;--------------------------------------------------------------------------------------------
; scaler_load_call1  @0x0A16
;   TRACED: scaler_table_lookup with Scaler_LoadAxis, r6=8.
;--------------------------------------------------------------------------------------------
                MOV     X1, #Scaler_LoadAxis
                MOVB    r3, (001d2h-00180h)[USP]
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     scaler_table_lookup
                STB     A, (001d4h-00180h)[USP]
                LB      A, r6
                STB     A, (001d2h-00180h)[USP]
                LB      A, (001a1h-00180h)[USP]
                STB     A, r2

;--------------------------------------------------------------------------------------------
; scaler_load_call2  @0x0A2B
;   TRACED: second Scaler_LoadAxis call, different destination.
;--------------------------------------------------------------------------------------------
                MOV     X1, #Scaler_LoadAxis
                MOVB    r3, (001d3h-00180h)[USP]
                MOVB    r6, #008h
                RB      PSWL.4
                CAL     scaler_table_lookup
                STB     A, (001d6h-00180h)[USP]
                LB      A, r6
                STB     A, (001d3h-00180h)[USP]
                JBR     off(00216h).7, threshold_bank_217_0_clr_carry
                JBR     off(00216h).3, threshold_bank_217_0_clr_carry
                MB      C, off(00226h).5
                MB      PSWL.4, C
                LB      A, #0ffh
                CMPB    A, off(002f2h)
                MB      off(00226h).5, C
                JGE     threshold_bank_217_0_ptr_386
                XORB    PSWL, #010h
threshold_bank_217_0_ptr_386:     MOV     DP, #00386h
                JBS     off(0021fh).1, threshold_bank_217_0_clear_a
                JBR     off(00214h).5, threshold_bank_217_0_load_ff
                JBS     off(00218h).7, threshold_bank_217_0_clr_carry
threshold_bank_217_0_load_ff:     LB      A, #0ffh
                JBS     off(0021dh).7, threshold_bank_217_0_store_ram2f0
                LB      A, off(002f0h)
                JNE     threshold_bank_217_0_sub_1
threshold_bank_217_0_clear_a:     CLR     A
                ST      A, [DP]
threshold_bank_217_0_clr_carry:     RC
                SJ      threshold_bank_217_0_carry_to_bit6
threshold_bank_217_0_sub_1:     SUBB    A, #001h
threshold_bank_217_0_store_ram2f0:     STB     A, off(002f0h)
                MOV     X1, #threshold_bank_217_0_data
                JBS     off(00226h).5, threshold_bank_217_0_test_pswl_bit4
                INC     DP
                MOV     X1, #threshold_bank_217_0_interp_tbl
threshold_bank_217_0_test_pswl_bit4:     MB      C, PSWL.4
                JGE     threshold_bank_217_0_test_ram226_bit5
                LB      A, off(00235h)
                VCAL    2
                STB     A, [DP]
threshold_bank_217_0_test_ram226_bit5:     MB      C, off(00226h).5
                LB      A, [DP]
                JEQ     threshold_bank_217_0_carry_to_bit6
                DECB    [DP]
                XORB    PSWH, #080h
threshold_bank_217_0_carry_to_bit6:     MB      off(00219h).6, C
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
                STB     A, ECT_raw
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
                MOVB    r0, #018h
                MOVB    r1, #014h
                MOVB    r2, (001d2h-00180h)[USP]

;--------------------------------------------------------------------------------------------
; ignmap_base_lookup  @0x0B40
;   TRACED: selects IgnMap_Hi/Lo, calls table2d_lookup_interp at 0x0B78.
;--------------------------------------------------------------------------------------------
                MOV     X2, (001d4h-00180h)[USP]
                MOVB    r3, (001d9h-00180h)[USP]
                MOV     er3, (001dch-00180h)[USP]
                MOV     X1, #IgnMap_Hi
                J       flag_dispatch_21d_212
flag_dispatch_21d_212_set_r3:     MOVB    r3, (001d8h-00180h)[USP]
                MOV     er3, (001dah-00180h)[USP]
                MOV     X1, #IgnMap_Lo
                JBR     off(00214h).5, ignmap_hi_gate2
                JBS     off(00218h).7, ignmap_2d_lookup
ignmap_hi_gate2:     SJ      ignmap_2d_lookup
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh

;--------------------------------------------------------------------------------------------
; ignmap_2d_lookup  @0x0B76
;   RESCOPED (was ignmap_do_lookup, 1667 bytes larger than originally measured): base
;   ignition map lookup (table2d_lookup_interp) flows directly, with no RT boundary, into
;   knock correction (knock_244_helper), dwell calc (dwell_scale_helper), ECT correction
;   (table_interp_lookup_4byte), the multiway_condition_select trim, and angle-to-timer conversion
;   (ign_angle_to_timer_convert) - the complete ignition timing calculation, not just the
;   map join. The original ignmap_do_lookup label is kept as the internal join-point block
;   within this larger routine.
;--------------------------------------------------------------------------------------------
ignmap_2d_lookup:     RB      PSWL.5
                CAL     table2d_lookup_interp
                LB      A, r4
                SJ      ignmap_result_common
ignmap_alt_path:     LB      A, 0aah
                MOV     X1, #ignmap_alt_path_interp_tbl
                JBS     off(0021fh).1, ignmap_alt_path_vcal0
                LB      A, off(00236h)
                MOV     X1, #ignmap_alt_path_interp_tbl_2
ignmap_alt_path_vcal0:     VCAL    0
ignmap_result_common:     STB     A, off(00244h)
                CLRB    A
                CMPB    coolantTempByte, #02eh
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
                JBR     off(00216h).2, knockretard2_clamp_set_ram2ad
                LB      A, #07ah
                JBS     off(00216h).3, knockretard2_clamp_cmp_ram236
                LB      A, #07ah
knockretard2_clamp_cmp_ram236:     CMPB    A, off(00236h)
                JLT     knockretard2_clamp_set_ram2ad
                LB      A, 0b4h
                CMPB    A, #02dh
                JGE     knockretard2_clamp_set_ram2ad
                CMPB    A, #023h
                JLT     knockretard2_clamp_set_ram2ad
                CMPB    coolantTempByte, #028h
                JGE     knockretard2_clamp_set_ram2ad
                CMPB    off(00235h), #064h
                JGE     knockretard2_clamp_set_ram2ad
                JBR     off(0021ah).4, knockretard2_clamp_cmp_ram2ad
knockretard2_clamp_set_ram2ad:     MOVB    off(002adh), #060h
                CLRB    A
                STB     A, r0
                RB      off(00220h).3
                SJ      knockretard2_clamp_store_ram251
knockretard2_clamp_cmp_ram2ad:     CMPB    off(002adh), #00ch
                JGE     knockretard2_clamp_goto
                LB      A, off(002adh)
                JEQ     knockretard2_clamp_cmp_ram2ac
                MOVB    off(002ach), #060h
                SJ      knockretard2_clamp_set_r0
knockretard2_clamp_cmp_ram2ac:     CMPB    A, off(002ach)
                MB      off(00220h).3, C
knockretard2_clamp_set_r0:     MOVB    r0, off(00239h)
                LB      A, off(00251h)
                JEQ     knockretard2_clamp_add_r0
                SUBB    A, #001h
                SJ      knockretard2_clamp_store_ram251
knockretard2_clamp_add_r0:     ADDB    r0, #002h
                LB      A, #004h
knockretard2_clamp_store_ram251:     STB     A, off(00251h)
                LB      A, #015h
                CMPB    A, r0
                JLE     knockretard2_clamp_store_ram239
                LB      A, r0
knockretard2_clamp_store_ram239:     STB     A, off(00239h)
knockretard2_clamp_goto:     J       knockretard2_clamp_load_8
                DW  00000h
knockretard2_clamp_branch:     JNE     knockretard2_clamp_goto_2
                MOV     X1, #knockretard2_clamp_data_2
                J       knockretard2_clamp_test_rama0_bit1
knockretard2_clamp_goto_2:     J       knockretard2_clamp_cmp_stk
                DB  000h,000h,000h
knockretard2_clamp_load_1d:     LB      A, #01dh
knockretard2_clamp_store_ram23b:     STB     A, off(0023bh)
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
flags_pack_sj_if_ram222_bit0_set:     JBS     off(00222h).0, flags_pack_sj_cmp_ram236
                LB      A, r0
flags_pack_sj_cmp_ram236:     CMPB    A, off(00236h)
                MB      off(00222h).0, C
                CLRB    A
                JBR     off(0021dh).5, flags_pack_sj_store_ram23e
                JGE     flags_pack_sj_store_ram23e
                MOV     X1, #flags_pack_sj_interp_tbl
                JBR     off(0021eh).3, flags_pack_sj_load_ram236
                MOV     X1, #TipinTPS
flags_pack_sj_load_ram236:     LB      A, off(00236h)
                VCAL    0
flags_pack_sj_store_ram23e:     STB     A, off(0023eh)
                LB      A, #05ah
                JBS     off(00222h).1, flags_pack_sj_cmp_ram236_2
                LB      A, #060h
flags_pack_sj_cmp_ram236_2:     CMPB    A, off(00236h)
                MB      off(00222h).1, C
                LB      A, 0b9h
                MOVB    r0, #09ah
                MOVB    r1, #024h
                JBS     off(00222h).2, flags_pack_sj_cmp_r0
                MOVB    r0, #097h
                MOVB    r1, #026h
flags_pack_sj_cmp_r0:     CMPB    A, r0
                JGE     flags_pack_sj_carry_to_ram222_bit2
                CMPB    r1, A
flags_pack_sj_carry_to_ram222_bit2:     MB      off(00222h).2, C
                CLRB    A
                JBR     off(00216h).3, flags_pack_sj_store_ram23c
                JBS     off(00211h).5, flags_pack_sj_store_ram23c
                JBS     off(00218h).5, flags_pack_sj_store_ram23c
                JBS     off(0021dh).4, flags_pack_sj_store_ram23c
                JBR     off(00211h).4, flags_pack_sj_store_ram23c
                CMPB    coolantTempByte, #02eh
                JGE     flags_pack_sj_store_ram23c
                JBS     off(0021ah).3, flags_pack_sj_store_ram23c
                JBR     off(00222h).1, flags_pack_sj_store_ram23c
                JBR     off(00222h).2, flags_pack_sj_store_ram23c
                LB      A, 0b9h
                MOV     X1, #flags_pack_sj_interp_tbl_2
                VCAL    0
flags_pack_sj_store_ram23c:     STB     A, off(0023ch)
                LB      A, #0ffh
                JBS     off(00222h).3, callhelper_table_interp_lookup
                LB      A, #0feh
callhelper_table_interp_lookup:     CMPB    TPS_pct, A
                MB      off(00222h).3, C
                CLRB    A
                JLT     callhelper_table_store_ram23d
                CMPB    coolantTempByte, #001h
                JGE     callhelper_table_store_ram23d
                JBS     off(0021dh).5, callhelper_table_store_ram23d
                LB      A, off(00236h)
                MOV     X1, #callhelper_table_interp_tbl_2
                VCAL    0
callhelper_table_store_ram23d:     STB     A, off(0023dh)
                J       callhelper_table_ptr_dat_dualmap
                DW  00000h
callhelper_table_branch:     JNE     tipin_gate_fail
                JBS     off(00214h).0, tipin_gate_fail
                JBS     off(0021dh).4, tipin_gate_fail
                JBS     off(00216h).3, tipin_gate_fail
                CMPB    coolantTempByte, #034h
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
                JLT     callhelper_table_if_ram220_bit0_set
tipin_gate_fail:     SJ      tipin_gate_fail_goto
callhelper_table_if_ram220_bit0_set:     JBS     off(00220h).0, tipin_gate_pass
                NOP
                NOP
                NOP
                NOP
                NOP
                JBR     off(00231h).6, tipin_gate2
                LB      A, off(00237h)
                JNE     tipin_decay_check
                SJ      tipin_gate_fail_goto
                DB  000h
tipin_gate2:     JBR     off(0021bh).1, tipin_gate2_clear_a
                CMPB    0bdh, #010h
                JLT     tipin_gate2_clear_a
tipin_gate_pass:     SB      off(00220h).0
                JBS     off(0021bh).6, tipin_gate_pass_goto
                CMP     0aeh, #0ffffh
                JGE     tipin_gate2_clear_a
tipin_gate_pass_goto:     J       tipin_gate_pass_load_ram24f
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
                JEQ     tipin_decay_check_goto
                DECB    off(0024eh)
                MOVB    r0, #001h
                SJ      tipin_decay_sub
tipin_decay_check_goto:     J       tipin_decay_check_if_ram21b_bit6_set
                DW  00000h
tipin_decay_common_carry_to_ram232_bit5:     MB      off(00232h).5, C
                JGE     tipin_decay_rc
                MOVB    r0, #003h
tipin_decay_sub:     SUBB    A, r0
                JLT     tipin_gate2_clear_a
                SC
                SJ      tipin_decay_store
tipin_gate_fail_goto:     J       tipin_gate_fail_clr_ram220_bit0
tipin_gate2_clear_a:     CLRB    A
tipin_decay_rc:     RC
tipin_decay_store:     STB     A, off(00237h)
                J       tipin_decay_store_carry_to_ram220_bit1
store_255_result_if_ram216_bit3_set:     JBS     off(00216h).3, vss_threshold_2ee_0
                L       A, off(00212h)
                AND     A, #001b4h
                JNE     vss_threshold_2ee_0
                JBS     off(00214h).0, vss_threshold_2ee_0
                JBS     off(0021dh).4, vss_threshold_2ee_0
                MOVB    r0, #0c0h
                MOVB    r1, #08ah
                MOVB    r2, #09ch
                MOVB    r3, #048h
                JBS     off(00221h).6, store_255_result_load_ram236
                MOVB    r0, #0bah
                MOVB    r1, #090h
                MOVB    r2, #092h
                MOVB    r3, #051h
store_255_result_load_ram236:     LB      A, off(00236h)
                CMPB    A, r0
                JGE     vss_threshold_2ee_0_carry_to_ram221_bit6
                CMPB    A, r1
                JLT     vss_threshold_2ee_0
                LB      A, off(00235h)
                CMPB    A, r2
                JGE     vss_threshold_2ee_0_carry_to_ram221_bit6
                CMPB    A, r3
                JLT     vss_threshold_2ee_0
                LB      A, off(00237h)
                JNE     vss_threshold_2ee_0
                CMPB    coolantTempByte, #001h
                JGE     vss_threshold_2ee_0_carry_to_ram221_bit6
                LCB     A, store_255_result_const
                JNE     vss_threshold_2ee_0_carry_to_ram221_bit6
                JBS     off(0021ah).3, vss_threshold_2ee_0_carry_to_ram221_bit6
vss_threshold_2ee_0:     RC
vss_threshold_2ee_0_carry_to_ram221_bit6:     MB      off(00221h).6, C
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
                JBS     off(00221h).5, vss_threshold_2ee_0_cmp_ram236
                LB      A, #051h
vss_threshold_2ee_0_cmp_ram236:     CMPB    A, off(00236h)
                MB      off(00221h).5, C
                L       A, er1
                JLT     dwell_scale_shift
                SRL     A
dwell_scale_shift:     SRL     A
                CAL     dwell_scale_helper
                ST      A, off(0024dh)
                MOV     DP, #dwell_scale_shift_data_2
                MOV     er0, (001dch-00180h)[USP]
                LB      A, (001d9h-00180h)[USP]
                JBS     off(0021fh).1, callhelper_knock_244_helper
                MOV     DP, #dwell_scale_shift_data
                MOV     er0, (001dah-00180h)[USP]
                LB      A, (001d8h-00180h)[USP]
callhelper_knock_244_helper:     CAL     multiway_condition_select
                NOP
                NOP
                CLR     A
                ST      A, er3
                JBS     off(00212h).5, ign_sum_stage4
                JBR     off(00220h).1, ign_sum_stage1
                J       callhelper_knock_244_load_ramb9
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
                J       table_result_sign_clamp
table_result_sign_store_r0:     STB     A, r0
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
                JBR     off(00207h).7, ign_sum_result_cmp_ff
                JLT     ign_sum_result_load_acc
                CLRB    A
                SJ      ign_sum_result_load_acc
ign_sum_result_cmp_ff:     CMP     A, #000ffh
                JLT     ign_sum_result_load_acc
                LB      A, #0ffh
ign_sum_result_load_acc:     LB      A, ACC
ign_sum_result_store_r5:     STB     A, r5
                LB      A, #040h
                SC
                JBS     off(00212h).5, ign_p40_flag_store
                CMPB    coolantTempByte, #0d0h
                JLT     ign_p40_flag_store
                JBS     off(00221h).7, ign_p40_flag_store_load_r4
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
ign_p40_flag_store_load_r4:     LB      A, r4
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                NOP
                RC
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
                SJ      gearcorrect_store_set_r2
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
                JGE     gearcorrect_store_store_ram247
                LB      A, #0ffh
gearcorrect_store_store_ram247:     STB     A, off(00247h)
gearcorrect_store_set_r2:     MOVB    r2, off(00246h)
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
                STB     A, adc_Ch5_new
                LB      A, #04ah
                JBS     off(0011eh).2, vtec_rawperiod_cmp_ram12c
                LB      A, #055h
vtec_rawperiod_cmp_ram12c:     CMPB    A, off(0012ch)
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
vtec_oilpressure_gate_check:     JBS     off(00115h).1, vtec_oilpressure_gate_test_p4_bit6
                CMPB    adc_Ch5_new, #0fch
                JGT     vtec_oilpressure_gate_test_p4_bit6
                CMPB    adc_Ch5_new, #004h
                JGE     vtec_oilpressure_gate_store_ram195
vtec_oilpressure_gate_test_p4_bit6:     MB      C, P4.6
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
vtec_oilpressure_gate_store_ram195:     STB     A, off(00195h)
                MOVB    r1, off(001cah)
                LB      A, off(001c8h)
                JNE     vtec_debounce_step_calc
                LB      A, #0a0h
                JBS     off(00128h).6, vtec_oilpressure_gate_cmp_ram12d
                LB      A, #0b0h
vtec_oilpressure_gate_cmp_ram12d:     CMPB    A, off(0012dh)
                MB      off(00128h).6, C
                CLRB    r0
                JGE     vtec_oilpressure_gate_load_c1
                INCB    r0
                INCB    r0
vtec_oilpressure_gate_load_c1:     LB      A, #0c1h
                JBS     off(00128h).7, vtec_oilpressure_gate_cmp_ram12c
                LB      A, #0d4h
vtec_oilpressure_gate_cmp_ram12c:     CMPB    A, off(0012ch)
                MB      off(00128h).7, C
                JGE     to_vtec_debounce_store
                INCB    r0
                NOP
                NOP
to_vtec_debounce_store:     CLRB    r1
                CMPB    adc_Ch5_new, #030h
                JLE     to_vtec_debounce_store_load_3
                LB      A, r0
                EXTND
                ADD     A, #to_vtec_debounce_store_data
                MOV     DP, A
                INCB    r1
                LB      A, adc_Ch5_new
                J       to_vtec_debounce_store_clr_rama0_bit1
                DW  00000h
to_vtec_debounce_store_inc_r1:     INCB    r1
                JBS     off(00112h).3, to_vtec_debounce_store_load_3
                JBS     off(00112h).7, to_vtec_debounce_store_load_3
to_vtec_debounce_store_rom_cmp_ind:     CMPCB   A, [DP]
                J       to_vtec_debounce_store_branch
to_vtec_debounce_store_inc_r1_2:     INCB    r1
                CMPB    r1, #007h
                JLT     to_vtec_debounce_store_rom_cmp_ind
to_vtec_debounce_store_load_3:     LB      A, #003h
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
vtec_retard_lookup_done:     SJ      vtec_engage_gate_start
vtec_state_finalize:     RB      off(0011dh).4
                CLRB    A
                STB     A, off(001c8h)
                CMPB    r1, #001h
                JNE     vtec_state_store2
                LB      A, r1
vtec_state_store2:     STB     A, off(001cah)
vtec_engage_gate_start:     JBR     off(00116h).4, vtec_engage_gate_start_goto_fuelmap
                MOV     DP, #const_0180_target2
                LC      A, [DP]
                INC     DP
                INC     DP
                JBS     off(00128h).1, vtec_rpm_vs_settings_check
                LB      A, ACCH
vtec_rpm_vs_settings_check:     CMPB    A, off(0012dh)
                MB      off(00128h).1, C
                LC      A, [DP]
                JBS     off(00128h).2, vtec_rpm_vs_settings_cmp_ram12d
                LB      A, ACCH
vtec_rpm_vs_settings_cmp_ram12d:     CMPB    A, off(0012dh)
                MB      off(00128h).2, C
                L       A, off(00112h)
                AND     A, #0c0bch
                JNE     vtec_rpm_vs_settings_clr_p1_bit1
                LB      A, off(00114h)
                ANDB    A, #031h
                JEQ     vtec_engage_conditions_start
vtec_rpm_vs_settings_clr_p1_bit1:     RB      P1.1
                SJ      vtec_highcam_output
vtec_engage_conditions_start:     SB      P1.1
                JBS     off(0011fh).1, vtec_engage_cmp_rama3
                LB      A, #000h
                JEQ     table_cond_05450_dispatch
                JBS     off(00111h).1, table_cond_0545d_dispatch
                SJ      vtec_highcam_output
table_cond_05450_dispatch:     CMPB    coolantTempByte, #044h
                JGE     vtec_highcam_output
                CMPB    0b4h, #00ah
                JLT     vtec_highcam_output
                CMPB    0b9h, #060h
                JLT     vtec_highcam_output
vtec_engage_cmp_rama3:     CMPB    0a3h, #090h
                JGE     vtec_engage_if_ram128_bit2_clr
                JBS     off(00128h).1, table_cond_0545d_dispatch
                SJ      vtec_highcam_output
vtec_engage_if_ram128_bit2_clr:     JBR     off(00128h).2, vtec_highcam_output
table_cond_0545d_dispatch:     SB      P1.0
                SB      off(0011fh).1
                RB      off(0011fh).2
                SJ      vtec_highcam_output_load_d7
vtec_engage_gate_start_goto_fuelmap:     SJ      fuelmap_base_lookup
vtec_highcam_output:     RB      P1.0
                RB      off(0011fh).1
                RB      off(0011fh).2
vtec_highcam_output_load_d7:     LB      A, #0d7h
                JBR     off(0011fh).3, vtec_highcam_output_cmp_stk
                LB      A, #0dch
vtec_highcam_output_cmp_stk:     CMPB    (00236h-00280h)[USP], A
                MB      off(0011fh).3, C
                XORB    PSWH, #080h
                MB      P0.5, C
                MB      C, P1.0
                XORB    PSWH, #080h
                NOP
                NOP
                NOP

;--------------------------------------------------------------------------------------------
; fuelmap_base_lookup  @0x11F9
;   TRACED: sets r0=24,r1=20 and axis RAM, selects FuelMap_Hi/Lo, calls
;   table2d_lookup_interp at 0x1270.
;--------------------------------------------------------------------------------------------
fuelmap_base_lookup:     MOVB    r0, #018h
                MOVB    r1, #014h
                MOVB    r2, off(001d3h)
                MOV     X2, off(001d6h)
                MOVB    r3, off(001d9h)
                MOV     er3, off(001dch)
                MOV     X1, #FuelMap_Hi
                JBS     off(0011fh).1, fuel_base_lookup_done
                JBR     off(00114h).5, fuelmap_base_lookup_set_r3
                JBS     off(00118h).7, fuel_base_lookup_done
fuelmap_base_lookup_set_r3:     MOVB    r3, off(001d8h)
                MOV     er3, off(001dah)
                MOV     X1, #FuelMap_Lo
                SJ      fuel_base_lookup_done
                DB  024h,001h,024h,001h,024h,001h,024h,001h
                DB  000h,000h

;--------------------------------------------------------------------------------------------
; cam_mode_jump_lookup  @0x122A
;   VERIFIED: indexes ROM word table at 0x121E using off(24Fh) (the cam/mode index used
;   throughout fuel/ign/VE map selection) x2, returns word in er2. A plain mode-indexed
;   pointer fetch.
;--------------------------------------------------------------------------------------------
cam_mode_jump_lookup:     LB      A, off(0024fh)
                EXTND
                SLL     A
                LC      A, 0121eh[ACC]
                ST      A, er2
                RT
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh

;--------------------------------------------------------------------------------------------
; fuel_base_lookup_done  @0x126E
;   RESCOPED (was fuelmap_do_lookup, 1042 bytes larger than originally measured): base
;   fuel map lookup flows directly into map_result_postscale, injector-array clamping
;   (injector_timer_schedule) and further scaling (scale_mul5_div4, scale_ram1e4_mul_shr2) -
;   the complete fuel pulse-width calculation. The original fuelmap_do_lookup label is
;   kept as the internal join-point block.
;--------------------------------------------------------------------------------------------
fuel_base_lookup_done:     SB      PSWL.5
                CAL     table2d_lookup_interp
                CAL     map_result_postscale
                J       multiway_apply2_prescale
                DB  000h
multiway_apply2_if_ram117_bit5_set:     JBS     off(00117h).5, accel_iac_calc
                JBS     off(0011fh).0, fuel_timer_scale
                SJ      accel_iac_clamp_min
accel_iac_calc:     LB      A, off(0015bh)
                STB     A, r0
                LB      A, #09ah
                MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     accel_iac_calc_cmp_40
                LB      A, #0ffh
accel_iac_calc_cmp_40:     CMPB    A, #040h
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
accelenrich_jump_tipin_check:     J       accelenrich_jump_load_ram13a
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
                JLT     accelenrich_jump_load_ram13a
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
                JEQ     accelenrich_jump_load_ram13a
                ADDB    A, #003h
                JGE     accelenrich_clear_0x165
accelenrich_jump_load_ram13a:     L       A, off(0013ah)
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
                LB      A, coolantTempByte
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
                JGE     crankfuel_add_adjust
                SRL     A
                SRL     A
crankfuel_add_adjust:     J       crankfuel_add_adjust_set_er0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
diag_report_finalize_store_ind:     ST      A, [DP]
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
                CMPB    coolantTempByte, #0e8h
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
                J       crankfuel_timer_wait_shl_er0
crankfuel_timer_wait_branch:     JEQ     cylinder_index_advance
                RB      TRNSIT.2
                JNE     cylinder_index_advance
dtc16_injector_latch_2: SB      09ch.6
cylinder_index_advance:     LB      A, off(00134h)
                ADDB    A, #001h
                ANDB    A, #003h
                STB     A, off(00134h)
postfuel_calc_start:     SB      off(0011fh).0
                LB      A, coolantTempByte
                CMPB    A, #0cfh
                MB      PSWL.5, C
                MOV     X1, #PostFuel
                VCAL    1
                STB     A, r0
                STB     A, r1
                JBS     off(00112h).5, postfuel_scale_apply
                JBS     off(00113h).1, postfuel_scale_apply
                CMPB    coolantTempByte, #0a2h
                JLT     postfuel_scale_apply
                MOV     DP, #00352h
                LB      A, [DP]
                SUBB    A, coolantTempByte
                JGE     postfuel_ect_rate_check
                VCAL    7
postfuel_ect_rate_check:     CMPB    A, #010h
                JGE     postfuel_scale_apply
                LB      A, 0c0h
                CMPB    A, #0bah
                JLT     postfuel_scale_apply
                SUBB    A, coolantTempByte
                JLT     postfuel_scale_apply
                CMPB    A, #006h
                JLT     postfuel_scale_apply
                L       A, #0e666h
                MUL
postfuel_scale_apply:     J       postfuel_scale_apply_load_er1
postfuel_scale_apply_clear_ram15f:     CLRB    off(0015fh)
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
                J       postfuel_hyst_lower_call_clamp_diff_15b
notcranking_entry:     RB      09fh.0
                JEQ     postfuel_decay_table_select
                CLRB    off(00135h)
postfuel_decay_table_select:     JBR     off(0011fh).0, postfuel_decay_table_load_2000
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
                CMPB    coolantTempByte, #02eh
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
postfuel_decay_table_load_2000:     L       A, #02000h
                ST      A, off(00160h)
postfuel_final_store:     ST      A, off(0014ah)
                LB      A, #0bah
                JBS     off(00127h).0, rpm_hyst_flag_12f0_store
                LB      A, #0c0h
rpm_hyst_flag_12f0_store:     CMPB    A, off(0012dh)
                MB      off(00127h).0, C
                LB      A, #0deh
                JBS     off(00127h).5, to_flag_12f_5_select_ff
                LB      A, #0e0h
to_flag_12f_5_select_ff:     CMPB    A, off(0012dh)
                MB      off(00127h).5, C
                LB      A, #017h
                JBS     off(00127h).2, to_cmp_a_0d1
                LB      A, #014h
to_cmp_a_0d1:     CMPB    coolantTempByte, A
                MB      off(00127h).2, C
                LB      A, #014h
                JBS     off(00127h).1, to_cmp_a_0d1_cmp_ramc1
                LB      A, #011h
to_cmp_a_0d1_cmp_ramc1:     CMPB    coolantTempByte, A
                MB      off(00127h).1, C
                NOP
                NOP
                NOP
                LB      A, #060h
                CMPB    A, 0b9h
                JLT     closeloop_tps_flag_store
                LB      A, #070h
                CMPB    A, 0a3h
closeloop_tps_flag_store:     MB      off(00127h).6, C
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
                JBR     off(00116h).1, closeloop_tps_flag_clear_r0
                JBR     off(00127h).0, closeloop_tps_flag_clear_r0
                MOVB    r0, #040h
                JBS     off(00118h).6, ve_adjust_add
                JBS     off(00127h).2, ve_adjust_add
                SB      PSWL.4
closeloop_tps_flag_clear_r0:     CLRB    r0
ve_adjust_add:     ADDB    r0, off(0016eh)
                JLT     ve_adjust_clamp_zero
ve_adjust_sub:     SUBB    A, r0
                JGE     ve_adjust2_gate
ve_adjust_clamp_zero:     CLRB    A
ve_adjust2_gate:     STB     A, r4
                RB      PSWL.4
                JEQ     ve_adjust2_gate_store_r0
                LB      A, off(0012dh)
                MOV     X1, #ve_adjust2_gate_interp_tbl
                VCAL    0
                SUBB    A, off(0016eh)
                JGE     ve_adjust2_gate_store_r0
                CLRB    A
ve_adjust2_gate_store_r0:     STB     A, r0
                SUBB    A, #010h
                JGE     ve_adjust2_gate_cmp_ram12c
                CLRB    A
ve_adjust2_gate_cmp_ram12c:     CMPB    A, off(0012ch)
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
                JBR     off(00128h).3, ve_result_flag_store_cmp_ram12c
                SUBB    A, r0
                JGE     ve_result_flag_store_cmp_ram12c
                CLRB    A
ve_result_flag_store_cmp_ram12c:     CMPB    A, off(0012ch)
                MB      off(00128h).3, C
                SC
                JBR     off(00116h).1, ve_result_flag_store_carry_to_bit3
                JBS     off(00118h).6, ve_result_flag_store_carry_to_bit3
                JBS     off(00128h).5, ve_result_flag_store_load_ram187
                RB      off(00121h).2
                JEQ     ve_result_flag_store_clear_ram185
                MOVB    off(00186h), off(00185h)
ve_result_flag_store_clear_ram185:     CLRB    off(00185h)
                RC
                SJ      ve_result_flag_store_carry_to_bit3
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
                J       ve_result_flag_store_branch
ve_result_flag_store_cmp_acch:     CMPB    ACCH, #000h
                JEQ     ve_result_flag_store_set_r4
                LB      A, #0ffh
ve_result_flag_store_set_r4:     MOVB    r4, #006h
                CMPB    A, r4
                JLT     ve_result_flag_store_store_ram187
                LB      A, r4
ve_result_flag_store_store_ram187:     STB     A, off(00187h)
ve_result_flag_store_clear_ram184:     CLRB    off(00184h)
                CMPB    off(00185h), A
                XORB    PSWH, #080h
ve_result_flag_store_carry_to_bit3:     MB      off(0011eh).3, C
                MOVB    r0, #00ah
                MOVB    r1, #014h
                MOVB    r2, off(001d3h)
                MOV     X2, off(001d6h)

;--------------------------------------------------------------------------------------------
; vemap_base_lookup  @0x1680
;   TRACED: selects VEMap_Hi/Lo.
;--------------------------------------------------------------------------------------------
                MOVB    r3, off(001d9h)
                MOV     er3, off(001dch)
                MOV     X1, #VEMap_Hi
                RB      PSWL.5
                JBS     off(0011fh).1, ve_and_accel_calc
                JBR     off(00114h).5, ve_table_result_store
                JBS     off(00118h).7, ve_and_accel_calc
ve_table_result_store:     MOVB    r3, off(001d8h)
                MOV     er3, off(001dah)
                MOV     X1, #VEMap_Lo

;--------------------------------------------------------------------------------------------
; ve_and_accel_calc  @0x169D
;   RESCOPED (was vemap_do_lookup): base VE map lookup flows into acceleration-enrichment
;   tracking (rpm_accel_track_helper, crank_edge_helper) and injector timer bank setup
;   (injtimer_bank_calc2). Spans up to the fixed interrupt vector at 0x21C8, so its true
;   end (versus unreachable padding) has not been confirmed - flagged honestly rather than
;   assumed. The original vemap_do_lookup label is kept as the internal join-point block.
;--------------------------------------------------------------------------------------------
ve_and_accel_calc:     J       ve_and_accel_calc_call_table2d_lookup
ve_and_accel_calc_load_80:     LB      A, #080h
                NOP
                NOP
                SRLB    A
                STB     A, r0
                JBS     off(0011dh).4, ve_accel_state_store_clr_ram11d_bit5
                JBS     off(00112h).6, ve_accel_gate1
                JBS     off(00127h).6, ve_accel_tps_threshold_check
ve_accel_gate1:     JBS     off(00127h).3, ve_accel_gate1_set_ram185
                JBS     off(00127h).1, ve_accel_gate1_set_ram185
                JBR     off(00127h).0, ve_accel_gate1_load_1
                JBR     off(00116h).1, ve_accel_gate1_set_ram185
                JBS     off(00118h).6, ve_accel_gate1_set_ram185
                JBS     off(00127h).2, ve_accel_gate1_set_ram185
                JBR     off(00128h).4, ve_accel_state_store_clr_ram11d_bit5
                JBR     off(0011eh).3, ve_accel_state_store_clr_ram11d_bit5
                SJ      ve_accel_reset_flags
ve_accel_tps_threshold_check:     LB      A, r0
                JBS     off(0011eh).3, ve_accel_reset_flags
                LB      A, #080h
                CAL     sub_clamp_helper
                SJ      ve_accel_reset_flags
ve_accel_gate1_set_ram185:     MOVB    off(00185h), #006h
                JBS     off(00128h).3, ve_accel_check_tps_rate
                CLRB    A
                SJ      ve_accel_state_store
ve_accel_gate1_load_1:     LB      A, #001h
                JBR     off(00128h).3, ve_accel_state_store
                CMPB    0b4h, #005h
                JLT     ve_accel_tps_threshold_check
                LB      A, off(0018fh)
                JEQ     ve_accel_tps_threshold_check
ve_accel_state_store:     STB     A, off(0018fh)
ve_accel_state_store_clr_ram11d_bit5:     RB      off(0011dh).5
                RB      off(00123h).6
ve_accel_common:     RB      off(00123h).4
                LB      A, #040h
                SJ      tpsaccel_store_0x162
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
tpsaccel_store_0x162:     STB     A, off(00152h)
                JBS     off(00127h).5, tpsaccel_ignitioncut_flag_copy
                J       tpsaccel_store_0x162_clear_a
                DB  000h
tpsaccel_ignitioncut_flag_copy:     MB      C, off(0011ch).4
                MB      off(00126h).4, C
                MOV     X1, #tbl_ignmap2_hi
                JBR     off(0011ch).2, tpsaccel_ignitioncut_load_ram12d
                MOV     X1, #tbl_ignmap2_lo
tpsaccel_ignitioncut_load_ram12d:     LB      A, off(0012dh)
                VCAL    0
                SUBB    A, off(0017ch)
                J       tpsaccel_ignitioncut_branch
                DB  000h
tpsaccel_ignitioncut_carry_to_bit0:     MB      off(00126h).0, C
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
                JBS     off(00126h).7, tps_hysteresis_store
                CMPB    0c4h, #07ah
tps_hysteresis_store:     J       tps_hysteresis_store_carry_to_bit7
                DW  00000h
tps_hysteresis_store_sub_a:     SUBB    A, #00ah
                JGE     rpm_threshold_adjust
                CLRB    A
rpm_threshold_adjust:     CMPB    0b4h, #000h
                JBR     off(00116h).3, bounded_add_020_0124_2
                CMPB    0b4h, #008h
bounded_add_020_0124_2:     JLT     rpm_secondary_threshold_check
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
                MOV     X1, #vss_threshold_226_3_interp_tbl
                LB      A, 0b9h
                VCAL    2
                SJ      to_store_pswl5_to_0124_5
vaccut_rpm_check:     LB      A, #080h
to_store_pswl5_to_0124_5:     CMPB    A, off(0012dh)
                JGE     to_store_pswl5_to_if_ram126_bit0_set
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
                JGE     ignition_cut_mode_load_28
                CMPB    0b4h, #0feh
                JGE     ignition_cut_mode_load_ram190
                LB      A, off(00191h)
                JNE     revlimiter_fuelcut_set
ignition_cut_mode_load_28:     LB      A, #028h
                STB     A, off(00190h)
                SJ      fuelcut_extra_gate
ignition_cut_mode_load_ram190:     LB      A, off(00190h)
                JNE     fuelcut_extra_gate
                LB      A, #002h
                STB     A, off(00191h)
revlimiter_fuelcut_set:     SB      PSWL.5
                SJ      fuelcut_result_common
fuelcut_extra_gate:     JBS     off(0011ch).2, ofc_enable_check
                JBR     off(0011ah).0, to_store_pswl5_to_if_ram126_bit0_set
ofc_enable_check:     JBR     off(00118h).2, fuelcut_tps_recheck
                RB      off(00126h).1
to_store_pswl5_to_if_ram126_bit0_set:     JBS     off(00126h).0, fuelcuttrack_store
                JBS     off(00126h).2, fuelcut_tps_recheck_if_ram11c_bit2_set
fuelcuttrack_store:     LB      A, #014h
                STB     A, off(001a3h)
fuelcut_clear_active_flag:     RB      off(0011ch).2
                SJ      fuelcut_output_flags
fuelcut_tps_recheck:     JBS     off(00126h).3, fuelcut_tps_recheck_if_ram11c_bit2_set
                SB      off(00126h).1
                SJ      fuelcuttrack_store
fuelcut_tps_recheck_if_ram11c_bit2_set:     JBS     off(0011ch).2, fuelcut_finalize_ign_flag
                J       fuelcut_tps_recheck_load_rama9
                DB  000h
to_fuelcut_clear_active_flag:     JGE     fuelcuttrack_store
                LB      A, off(001a3h)
                JEQ     fuelcut_finalize_ign_flag
                SB      off(00123h).7
                SJ      fuelcut_clear_active_flag
fuelcut_finalize_ign_flag:     JBR     off(00116h).3, fuelcut_finalize_ign_if_ram126_bit5_set
                LB      A, 0b4h
                CMPB    A, #064h
                JGE     fuelcut_finalize_ign_if_ram126_bit5_set
                LB      A, 0b5h
                SUBB    A, 0b4h
                JLT     fuelcut_finalize_ign_if_ram111_bit5_set
                CMPB    A, #004h
                JGE     fuelcut_finalize_ign_set_ram126_bit5
fuelcut_finalize_ign_if_ram111_bit5_set:     JBS     off(00111h).5, fuelcut_finalize_ign_if_ram126_bit5_set
                JBS     off(0011bh).7, fuelcut_finalize_ign_if_ram126_bit5_set
                L       A, 0b0h
                CMP     A, #00100h
                JLT     fuelcut_finalize_ign_if_ram126_bit5_set
                SB      off(00126h).6
                SJ      fuelcut_finalize_ign_if_ram126_bit5_set
fuelcut_finalize_ign_set_ram126_bit5:     SB      off(00126h).5
fuelcut_finalize_ign_if_ram126_bit5_set:     JBS     off(00126h).5, fuelcut_clear_active_flag
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
                JEQ     fuelcut_output_flags_carry_to_bit3
fuelcut_output_flags_set_carry:     SC
fuelcut_output_flags_carry_to_bit3:     MB      off(0011ch).3, C
                J       fuelcut_output_flags_load_ramc4
tps_hysteresis_reentry_set_r2:     MOVB    r2, #00ah
                JBR     off(00119h).7, tps_hysteresis_reentry_if_ram11d_bit4
                J       ignmap2_rpm_gate_clear_a
tps_hysteresis_reentry_if_ram11d_bit4:     JBR     off(0011dh).4, tps_hysteresis_reentry_if_ram124_bit3
                LB      A, off(0012ch)
                MOV     X1, #tps_hysteresis_reentry_interp_tbl
                VCAL    0
                SJ      postig_result_high_set_pswl_bit4
tps_hysteresis_reentry_if_ram124_bit3:     JBS     off(00124h).3, ignmap2_rpm_gate_clear_a
                JBS     off(0011dh).5, ignmap2_rpm_gate_clear_a
                JBR     off(0011ah).3, postig_result_default
                JBR     off(0011ah).0, postig_result_default
                J       tps_hysteresis_reentry_if_ram116_bit3
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
postig_threshold_check2:     J       postig_threshold_if_ram117_bit6_clr
                DB  000h
postig_rpm_compare_cmp_ramc1:     CMPB    coolantTempByte, #034h
                JGE     postig_result_high
                JBR     off(00116h).3, postig_result_high
                LB      A, off(001a2h)
                STB     A, r2
                JNE     ignmap2_rpm_gate_clear_a
postig_result_high:     LB      A, #0dah
                JBS     off(00116h).3, postig_result_high_set_pswl_bit5
                LB      A, #0f3h
postig_result_high_set_pswl_bit5:     SB      PSWL.5
postig_result_high_set_pswl_bit4:     SB      PSWL.4
                SJ      ignmap2_flags_store
postig_result_default:     LB      A, #080h
                MOV     X1, #tbl_ignmap2_hi
                JBR     off(00123h).5, ignmap2_rpm_gate
                LB      A, #073h
                MOV     X1, #tbl_ignmap2_lo
ignmap2_rpm_gate:     CMPB    A, off(0012dh)
                JGE     ignmap2_rpm_gate_clear_a
                LB      A, off(0012dh)
                VCAL    0
                ADDB    A, #002h
                JGE     ignmap2_result_check
                LB      A, #0ffh
ignmap2_result_check:     SUBB    A, off(0017ch)
                JLT     ignmap2_rpm_gate_clear_a
                CMPB    A, off(0012ch)
                JLE     ignmap2_rpm_gate_clear_a
                LB      A, #0f3h
                SJ      postig_result_high_set_pswl_bit4
ignmap2_rpm_gate_clear_a:     CLRB    A
ignmap2_flags_store:     STB     A, off(00154h)
                MB      C, PSWL.4
                MB      off(00123h).5, C
                MB      C, PSWL.5
                MB      off(0011eh).1, C
                MOVB    off(001a2h), r2
                LB      A, #0d5h
                JBS     off(00125h).0, ignmap2_flags_store_cmp_ram12d
                LB      A, #0d8h
ignmap2_flags_store_cmp_ram12d:     CMPB    A, off(0012dh)
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
                JNE     o2_direction_wideband
                LB      A, 0e6h
                ADDB    A, #000h
                NOP
                NOP
                NOP
                NOP
                NOP
o2_direction_wideband:     MOVB    r0, A
                CMPB    A, ECT_raw
                XORB    PSWH, #000h
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
                CMPB    coolantTempByte, #028h
                JGE     o2_trim_gate_common
                LB      A, ECT_raw
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
                JBR     off(00119h).1, o2_trim_gate3_clear_ram16c
                JBS     off(0011dh).4, o2_trim_gate3_clear_ram16c
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
o2_trim_gate3:     JBR     off(00119h).2, o2_trim_gate3_clear_ram16c
                JBS     off(0011dh).5, o2_trim_gate3_clear_ram16c
                JBS     off(00119h).0, o2_trim_tps_mode_check
                CLRB    off(0016ch)
                MOVB    off(0019fh), r0
                MOV     DP, #00304h
                JBR     off(00118h).0, o2_trim_dp_table_read
                MOV     DP, #00300h
o2_trim_dp_table_read:     L       A, [DP]
                SJ      o2_trim_clear_gate1
o2_trim_tps_mode_check:     JBS     off(00125h).0, o2_trim_gate3_clear_ram16c
                JBR     off(0011ch).6, o2_trim_alt_path_check_set_ram16c
                J       o2_trim_tps_mode_check_if_ram11c_bit2
o2_trim_alt_path_check:     JBR     off(00123h).5, o2_trim_alt_path_check_set_ram11d_bit1
o2_trim_alt_path_check_set_ram16c:     MOVB    off(0016ch), #004h
                LB      A, off(0019fh)
                JEQ     o2_trim_default_target
                L       A, off(00148h)
                SB      off(0011dh).1
                SJ      o2_trim_clear_gate0_and_return
o2_trim_gate3_clear_ram16c:     CLRB    off(0016ch)
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
                LC      A, o2_trim_step_threshold_const
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
                J       axis_clamp_c1_selector
                DB  000h,000h,000h
axis_clamp_c1_selector_branch:     JLT     o2_trim_mul_apply
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
                JLT     o2_trim_alt_gate_clr_pswl_bit5
                JBR     off(00125h).5, o2_trim_alt_gate_clr_pswl_bit5
                MOV     DP, #00304h
                CMP     [DP], off(00148h)
                JGT     o2_trim_dp304_calc
o2_trim_alt_gate_clr_pswl_bit5:     RB      PSWL.5
                JBR     off(00125h).1, o2_trim_result_check
                ST      A, off(0016ah)
o2_trim_result_check:     MB      C, PSWL.5
                JLT     o2_trim_result_check_load_acc
                JBS     off(00125h).1, o2_trim_rpm_alt_check
o2_trim_result_check_load_acc:     LB      A, ACC
                LC      A, o2_trim_step_threshold_const
                MOV     DP, #0016ah
                JBR     off(00125h).2, o2_trim_decrement_apply
                J       o2_trim_result_check_load_acch
o2_trim_result_check_inc_dp:     INC     DP
o2_trim_decrement_apply:     DECB    [DP]
                JEQ     o2_trim_decrement_store
                J       o2trim_gate_common2
o2_trim_decrement_store:     STB     A, [DP]
o2_trim_rpm_alt_check:     J       o2_trim_rpm_alt_check_ptr_5
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
                J       mul_scale_clamp_dual
                DW  00000h
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
                J       o2trim_speed_flag_set_cmp_er1
o2trim_speed_flag_set_test_pswl_bit4:     MB      C, PSWL.4
                MB      off(0011eh).4, C
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #031h
                JEQ     o2trim_gate_common2
                J       o2trim_speed_flag_set_test_p1_bit6
o2trim_speed_flag_set_branch:     JNE     o2trim_gate_common2
                J       o2trim_speed_flag_set_if_ram119_bit2_clr
o2trim_speed_flag_set_cmp_ramc0:     CMPB    0c0h, #030h
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
o2trim_ect_offset_lookup:     CMPB    coolantTempByte, #02eh
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
injtimer_finalize_start:     ST      A, off(00148h)
                J       to_injtimer_sub_common
                DW  00000h
to_injtimer_sub_common_load_40:     LB      A, #040h
                JBS     off(00123h).4, to_injtimer_sub_common_store_ram153
                JBS     off(00123h).5, to_injtimer_sub_common_store_ram153
                MOV     X1, #to_injtimer_sub_common_data
                MOV     X2, #0015ah
                JBR     off(0011dh).0, to_injtimer_sub_common_if_ram116_bit3
                ADD     X1, #00004h
                INC     X2
                INC     X2
to_injtimer_sub_common_if_ram116_bit3:     JBS     off(00116h).3, to_injtimer_sub_common_load_ram0
                INC     X1
to_injtimer_sub_common_load_ram0:     LB      A, 00000h[X2]
                STB     A, r6
                LB      A, 00001h[X2]
                J       to_injtimer_sub_common_store_r7
to_injtimer_sub_common_call_table:     CAL     table_interp_lookup_prescan
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
                JBS     off(00125h).6, to_injtimer_sub_common_cmp_ram12d
                LB      A, #040h
to_injtimer_sub_common_cmp_ram12d:     CMPB    A, off(0012dh)
                MB      off(00125h).6, C
                LB      A, #01ch
                JBS     off(00125h).7, to_injtimer_store_0x166
                LB      A, #01dh
to_injtimer_store_0x166:     CMPB    A, 0b9h
                MB      off(00125h).7, C
                JBR     off(00119h).1, injtimer_gate_common
                JBS     off(00118h).5, injtimer_gate_common
                CMPB    coolantTempByte, #0e0h
                JGE     injtimer_gate_common
                J       injtimer_sub_common
injtimer_sub_common_if_ram125_bit7_clr:     JBR     off(00125h).7, injtimer_gate_common
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
                JBS     off(00121h).0, injtimer_mul_final_load_4
                CMPB    TPS_pct, #04bh
                JLT     dwell_zero_result
                SB      off(00121h).0
injtimer_mul_final_load_4:     LB      A, #004h
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
                J       dwell_rpm_gate3_set_r0
dwell_rpm_gate3_set_r1:     MOVB    r1, #018h
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
                CMPB    coolantTempByte, #034h
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
rpm_decel_counter_check:     J       rpm_decel_counter_set_r1
rpm_decel_counter_branch:     JEQ     rpm_decel_diff_check2
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
rpm_decel_store_0x14a_branch:     JLT     idle_sub_result_store
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
                J       idle_sub_result_store_store_ram3b4
idle_sub_result_store_goto:     J       cylinder_ign_correct_goto
tipin_time_calc:     L       A, off(0013ah)
                J       tipin_time_calc_set_er0
tipin_time_calc_cmp_rame8:     CMPB    0e8h, #004h
                MB      off(00123h).3, C
                ADD     A, #0007dh
                JLT     tipin_time_clamp
tipin_time_calc_add_ram13c:     ADD     A, off(0013ch)
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
injtimer_bank_a_store_set_er0:     MOV     er0, [DP]
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
                JGE     injtimer_bank_b_store_cmp_ram178
                L       A, off(00176h)
injtimer_bank_b_store_cmp_ram178:     CMP     A, off(00178h)
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
; [H] --- Per-cylinder injector timer write (critical section, interrupts masked via IE/PSWH):
; [H] cylinder_ign_correct_loop applies CylinderIGNCorrect (real per-cylinder ignition-correction
; [H] calibration table) and a mul5/div4 scale to each cylinder's computed value, writing results
; [H] to the injector timer-compare registers up through 0x3C0 -- this is the routine referenced
; [H] back in ign_angle_to_timer_convert's comment as "programming the two ignition coil-channel
; [H] hardware timers" (the same critical-section pattern, here for injector-side output).
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
cylinder_ign_correct_goto:     J       cylinder_ign_correct_load_c5
                DB  000h
cylinder_ign_correct_load_5:     LB      A, #005h
                JBS     off(0011dh).4, deadtime_retry_store_goto_injector
                MOVB    r6, #007h
                L       A, off(00112h)
                AND     A, #01034h
                JNE     to_gio_mode_dispatch
                MOVB    r6, #006h
                JBS     off(00117h).5, to_gio_mode_dispatch
                MOVB    r6, #006h
                JBS     off(00123h).2, to_gio_mode_dispatch
                CMPB    coolantTempByte, #02eh
                JGE     deadtime_ect_offset
                MOVB    r6, #007h
                JBS     off(00118h).0, to_gio_mode_dispatch
deadtime_ect_offset:     CLR     DP
                LB      A, coolantTempByte
                CMPB    A, #0aeh
                JGE     deadtime_ect_offset_load_38
                ADD     DP, #00003h
deadtime_ect_offset_load_38:     LB      A, #038h
                JBS     off(00123h).1, deadtime_ect_offset_cmp_rama6
                LB      A, #030h
deadtime_ect_offset_cmp_rama6:     CMPB    TPS_pct, A
                MB      off(00123h).1, C
                LB      A, #077h
                JBS     off(00123h).0, deadtime_ect_offset_cmp_rama6_2
                LB      A, #070h
deadtime_ect_offset_cmp_rama6_2:     CMPB    TPS_pct, A
                MB      off(00123h).0, C
                JGE     deadtime_table_lookup
                INC     DP
                JBR     off(00123h).1, deadtime_table_lookup
                INC     DP
deadtime_table_lookup:     LCB     A, InjectorTable[DP]
                STB     A, r6
                SJ      to_gio_mode_dispatch
deadtime_retry_check:     MB      C, 09fh.0
                JGE     deadtime_retry_store
                LB      A, #005h
deadtime_retry_store:     SUBB    A, #001h
                STB     A, off(00135h)
                LB      A, #00bh
deadtime_retry_store_goto_injector:     SJ      injector_effective_pw_store
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
                J       to_gio_mode_dispatch_sub_r6
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
                JBR     off(00116h).7, crank_edge_flag_store_clear_a
                JBR     off(00116h).3, crank_edge_flag_store_clear_a
                LB      A, #001h
                JBS     off(00129h).0, crank_edge_flag_store_cmp_ramc1
                LB      A, #000h
crank_edge_flag_store_cmp_ramc1:     CMPB    coolantTempByte, A
                MB      off(00129h).0, C
                LB      A, #0ffh
                JBS     off(00129h).1, crank_edge_flag_store_cmp_ram12c
                LB      A, #0ffh
crank_edge_flag_store_cmp_ram12c:     CMPB    A, off(0012ch)
                MB      off(00129h).1, C
                LB      A, #0ffh
                JBS     off(00129h).2, crank_edge_flag_store_cmp_rama6
                LB      A, #0ffh
crank_edge_flag_store_cmp_rama6:     CMPB    TPS_pct, A
                MB      off(00129h).2, C
                LB      A, #000h
                JBS     off(0011ch).7, crank_edge_flag_store_cmp_ram12d
                LB      A, #001h
crank_edge_flag_store_cmp_ram12d:     CMPB    A, off(0012dh)
                MB      off(0011ch).7, C
                MOV     DP, #0039bh
                LB      A, [DP]
                CMPB    A, #032h
                JNE     crank_edge_flag_store_if_ram11c_bit7_set
                MOV     X1, #crank_edge_flag_store_interp_tbl
                LB      A, off(0012dh)
                VCAL    0
                SJ      crank_edge_flag_store_clr_carry
crank_edge_flag_store_if_ram11c_bit7_set:     JBS     off(0011ch).7, crank_edge_flag_store_clear_a
                JBS     off(00117h).5, crank_edge_flag_store_clear_a
                L       A, off(00112h)
                AND     A, #0907ch
                JNE     crank_edge_flag_store_clear_a
                JBR     off(00113h).3, crank_edge_flag_store_if_ram11c_bit2_set
                JBR     off(0011ah).1, crank_edge_flag_store_clear_a
                LB      A, (002f2h-00280h)[USP]
                CMPB    A, #0ffh
                JLT     crank_edge_flag_store_clear_a
                CMPB    A, #0ffh
                JGT     crank_edge_flag_store_clear_a
crank_edge_flag_store_if_ram11c_bit2_set:     JBS     off(0011ch).2, crank_edge_flag_store_clear_a
                JBS     off(0011dh).5, crank_edge_flag_store_clear_a
                JBR     off(00118h).2, crank_edge_flag_store_clear_a
                JBS     off(00112h).0, crank_edge_flag_store_if_ram11d_bit2_clr
                JBS     off(00115h).2, crank_edge_flag_store_if_ram11d_bit2_clr
                JBS     off(00115h).4, crank_edge_flag_store_if_ram11d_bit2_clr
                JBS     off(0011dh).1, crank_edge_flag_store_if_ram129_bit0_clr
crank_edge_flag_store_clear_a:     CLRB    A
crank_edge_flag_store_clr_carry:     RC
                SJ      crank_edge_flag_store_carry_to_bit7
crank_edge_flag_store_if_ram11d_bit2_clr:     JBR     off(0011dh).2, crank_edge_flag_store_clear_a
crank_edge_flag_store_if_ram129_bit0_clr:     JBR     off(00129h).0, crank_edge_flag_store_clear_a
                JBR     off(00129h).1, crank_edge_flag_store_clear_a
                JBS     off(00129h).2, crank_edge_flag_store_clear_a
                MOVB    r3, off(001d8h)
                MOV     er3, off(001dah)
                NOP
                NOP
                NOP
                LB      A, #000h
                CMPB    A, r3
                JGT     crank_edge_flag_store_clear_a
                ADDB    A, #00ah
                CMPB    A, r3
                JLE     crank_edge_flag_store_clear_a
                SUBB    r3, #000h
                MOVB    r0, #00ah
                MOVB    r1, #00bh
                MOVB    r2, off(001d3h)
                MOV     X2, off(001d6h)
                RB      PSWL.5
                CAL     table2d_lookup_interp
                LB      A, (002f1h-00280h)[USP]
                MB      C, ACC.7
                JGE     crank_edge_flag_store_add_r4
                ADDB    A, r4
                JLT     crank_edge_flag_store_store_r1
                CLRB    A
                SJ      crank_edge_flag_store_store_r1
crank_edge_flag_store_add_r4:     ADDB    A, r4
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
                LCB     A, crank_edge_flag_store_const[ACC]
                MOVB    r0, r1
                MULB
                SLL     A
                LB      A, ACCH
                JGE     crank_edge_flag_store_set_carry
                LB      A, #0ffh
crank_edge_flag_store_set_carry:     SC
crank_edge_flag_store_carry_to_bit7:     MB      off(0011dh).7, C
                STB     A, (002f3h-00280h)[USP]
                CAL     crank_edge_helper
                SB      09eh.4
                L       A, 0f4h
                ST      A, IE
                RB      PSWH.0
                J       int1_rti_epilogue
; [flow] int_spurious_irq_trap: every interrupt vector this ROM never enables points here. It stamps trap
;    reason 045h and goes through fault_retry_check (retry budget, then BRK -> int_break re-init).
int_spurious_irq_trap: NOP
                NOP
int_spurious_irq_trap_body: MOVB    0ebh, #045h
                SJ      fault_retry_check
                DB  000h
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
periph_init_delay_loop_ptr_177:     MOV     DP, #00177h
periph_init_delay_loop:     DEC     DP
                JEQ     periph_init_delay_loop_set_rameb
                MBR     C, off(P4)
                JLT     periph_init_delay_loop
                MOV     DP, #00177h
periph_init_delay_loop_dec_dp:     DEC     DP
                JEQ     periph_init_delay_loop_set_rameb
                MBR     C, off(P4)
                JGE     periph_init_delay_loop_dec_dp
                MOV     DP, #000b2h
periph_init_delay_loop_dec_dp_2:     DEC     DP
                JEQ     periph_init_delay_loop_set_rameb
                MBR     C, off(P4)
                JLT     periph_init_delay_loop_dec_dp_2
                INCB    ACC
                CMPB    A, #004h
                JNE     periph_init_delay_loop_ptr_177
                RB      off(IRQH).5
                JNE     periph_init_delay_loop_load_ffff
periph_init_delay_loop_set_rameb:     MOVB    off(000ebh), #04ch
                BRK
periph_init_delay_loop_load_ffff:     L       A, #0ffffh
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
                LCB     A, tbl_cfgvariant_map[ACC]
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
                J       cfgvariant_check_232h_call_cfgvariant
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
                ST      A, adc_Ch4_word
                LB      A, ADCR2H
                STB     A, TPS2_raw
                MOV     DP, #003d2h
                STB     A, [DP]
                MOV     DP, #003beh
                LB      A, [DP]
                STB     A, ECT_raw
                MOV     DP, #003c5h
                LB      A, [DP]
                STB     A, IAT_raw
                MOVB    0c0h, #057h
                MOVB    coolantTempByte, #03bh
                MOVB    0a4h, #0f9h
                LB      A, #025h
                STB     A, 0c4h
                STB     A, 0f7h
                L       A, ADCR6
                ST      A, adc_Ch6_word
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
                LB      A, #00fh
                STB     A, (001bfh-00180h)[USP]
                STB     A, (001b7h-00180h)[USP]
                MOVB    0e6h, #01fh
                MOV     0e4h, #00080h
                MOVB    off(002f4h), #0ffh
                MOV     DP, #003c8h
                LB      A, [DP]
                STB     A, off(002a5h)
                CAL     ect_step_helper
                CLRB    A
                MOV     DP, #001a9h
tbl6b1f_copy_loop:     LCB     A, tbl_boot_copy_block[DP]
                STB     A, [DP]
                INC     DP
                CMP     DP, #001b6h
                JNE     tbl6b1f_copy_loop
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
                MOVB    r0, #00ch
                MOVB    r1, #09ch
                LB      A, #0f8h
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

;--------------------------------------------------------------------------------------------
; config_flag_bit_decode  @0x2584
;   VERIFIED: kicks WDT, reads a calibration byte via [X1], tests ACC bit3/bit7 against
;   off(2FFh) sub-flags, returns the decoded bit in carry. Shared helper - called 3x by
;   multiway_condition_select over MultiwaySelectTable0/1/2.
;--------------------------------------------------------------------------------------------
config_flag_bit_decode:     LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                CLRB    A
                STB     A, r0
                LCB     A, [X1]
                JNE     config_flag_bit_decode_test_acc_bit3
                J       config_flag_bit_decode_shl_r0
config_flag_bit_decode_test_acc_bit3:     MB      C, ACC.3
                JGE     config_flag_bit_decode_test_acc_bit7
                MB      C, off(002ffh).0
                JLT     config_flag_bit_decode_goto
config_flag_bit_decode_test_acc_bit7:     MB      C, ACC.7
                JGE     config_flag_bit_decode_clear_a
                MB      C, off(002ffh).5
                JLT     config_flag_bit_decode_goto
config_flag_bit_decode_clear_a:     CLR     A
                LC      A, 00002h[X1]
                JEQ     config_flag_bit_decode_clear_a_2
                MOV     DP, A
                LC      A, 00004h[X1]
                ST      A, er1
                LB      A, [DP]
                XORB    A, r2
                ANDB    A, r3
                JNE     config_flag_bit_decode_clear_a_2
config_flag_bit_decode_goto:     J       config_flag_bit_decode_clear_a_3
config_flag_bit_decode_clear_a_2:     CLR     A
                LC      A, 00006h[X1]
                CMP     0ach, A
                JGT     config_flag_bit_decode_clear_a_3
                LC      A, 00008h[X1]
                CMP     0ach, A
                JLT     config_flag_bit_decode_clear_a_3
                CLRB    A
                LCB     A, 0000ah[X1]
                CMPB    0a3h, A
                JLT     config_flag_bit_decode_clear_a_3
                LCB     A, 0000bh[X1]
                CMPB    0a3h, A
                JGT     config_flag_bit_decode_clear_a_3
                LCB     A, 0000ch[X1]
                CMPB    0b4h, A
                JLT     config_flag_bit_decode_clear_a_3
                LCB     A, 0000dh[X1]
                CMPB    0b4h, A
                JGT     config_flag_bit_decode_clear_a_3
                LCB     A, 0000eh[X1]
                CMPB    0b9h, A
                JLT     config_flag_bit_decode_clear_a_3
                LCB     A, 0000fh[X1]
                CMPB    0b9h, A
                JGT     config_flag_bit_decode_clear_a_3
                LCB     A, 00010h[X1]
                CMPB    0c0h, A
                JGT     config_flag_bit_decode_clear_a_3
                LCB     A, 00011h[X1]
                CMPB    0c0h, A
                JLT     config_flag_bit_decode_clear_a_3
                LCB     A, 00012h[X1]
                CMPB    coolantTempByte, A
                JGT     config_flag_bit_decode_clear_a_3
                LCB     A, 00013h[X1]
                CMPB    coolantTempByte, A
                JLT     config_flag_bit_decode_clear_a_3
                MOVB    r0, #0ffh
config_flag_bit_decode_clear_a_3:     CLR     A
                LC      A, 00014h[X1]
                JEQ     config_flag_bit_decode_shl_r0
                MOV     DP, A
                LC      A, 00016h[X1]
                ST      A, er1
                LB      A, [DP]
                ORB     A, r3
                SUBB    A, r2
                STB     A, r1
                LB      A, r0
                ANDB    r3, A
                LB      A, r1
                XORB    A, r3
                STB     A, [DP]
config_flag_bit_decode_shl_r0:     SLLB    r0
                RT

;--------------------------------------------------------------------------------------------
; multiway_condition_select  @0x2649
;   VERIFIED mechanism: builds a 4-bit selector in off(2FFh) bits 0-3 from a load/RPM-zone
;   test plus 3 calibration-byte decodes (via config_flag_bit_decode). Continues at
;   multiway_condition_apply1 (0x78AE). HTS115's own low-confidence (30%) guess for
;   structurally similar code was "boost_dial_multi_trim" - plausible given the
;   multi-table-select shape, but NOT proven boost-specific, so that label was not
;   borrowed.
;--------------------------------------------------------------------------------------------
multiway_condition_select:     RB      off(002ffh).0
                L       A, #00000h
                AND     A, off(00212h)
                AND     A, off(00214h)
                JEQ     multiway_condition_ptr_MultiwaySelectTab
                SB      off(002ffh).0
multiway_condition_ptr_MultiwaySelectTab:     MOV     X1, #MultiwaySelectTable0
                CAL     config_flag_bit_decode
                MB      off(002ffh).1, C
                MOV     X1, #MultiwaySelectTable1
                CAL     config_flag_bit_decode
                MB      off(002ffh).2, C
                MOV     X1, #MultiwaySelectTable2
                CAL     config_flag_bit_decode
                MB      off(002ffh).3, C
                J       multiway_condition_load_55a0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh

;--------------------------------------------------------------------------------------------
; background_task_scheduler  @0x2686
;   TRACED: manages an IE interrupt-mask cycle counter (RAM 0xCE), runs housekeeping
;   (ResetWatchDog + decrement_timer_array x3), runs a divide-by-10 slow-tick generator
;   that raises off(231h).1/.2 for the two periodic decay tasks, then dispatches - by
;   unconditional JUMP, not CALL - to exactly one of five subsystem tasks per invocation
;   based on a priority-ordered chain of flag tests (off 09Eh.6/.4, off(227h).2,
;   off(216h).3, off(231h).0/.1/.2). Reached via VCAL 4, 199 call sites' worth of VCAL
;   usage total across the ROM makes this the busiest entry point in the firmware.
;--------------------------------------------------------------------------------------------
background_task_scheduler:         L       A, 0f4h
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
                J       vcal3_leanprotect_clr_stk_bit2
vcal3_leanprotect_clr_ram9e_bit6:     RB      09eh.6
                JEQ     vcal3_leanprotect_clr_ram9e_bit4
                J       adc3_sensor_task
vcal3_leanprotect_clr_ram9e_bit4:     RB      09eh.4
                JEQ     vcal3_leanprotect_if_ram227_bit2_set
                JBR     off(0022bh).0, vcal3_task_a
                RB      off(00231h).0
                JNE     vcal3_task_a
                RT
vcal3_task_a:     J       battery_voltage_check
vcal3_leanprotect_if_ram227_bit2_set:     JBS     off(00227h).2, vcal3_dispatch_check1
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
                LB      A, coolantTempByte
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
                CMPB    IAT_raw, #044h
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
vss_calc_skip:     L       A, #IGN1_Lo_Extended
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
                J       idle_init_start_clr_stk_bit2
idle_init_start_set_er0:     MOV     er0, off(002ech)
                CLR     A
                LB      A, #040h
                MUL
                MOV     X1, A
                MOV     DP, #00020h
                MOVB    r0, off(002eah)
idle_init_start_rom_load_ind:     LC      A, [X1]
                ADDB    A, ACCH
                ADDB    r0, A
                INC     X1
                INC     X1
                JRNZ    DP, idle_init_start_rom_load_ind
                LB      A, r0
                STB     A, off(002eah)
                INC     off(002ech)
                CMP     off(002ech), #00200h
                JNE     idle_mode_gate2
                CLR     off(002ech)
                LB      A, r0
                JEQ     idle_mode_gate2
                CLRB    off(002eah)
                LCB     A, idle_init_start_const
                JNE     idle_mode_gate2
                MOVB    0ebh, #048h
                J       fault_giveup_latch
idle_mode_gate2:     JBR     off(002e4h).0, idle_mode_gate2_load_ramc8
                J       transit_flag_check
idle_mode_gate2_load_ramc8:     L       A, 0c8h
                MOV     X1, #tbl_idle_dc
                CAL     table_interp_lookup_4byte
                MOV     er0, adc_Ch4_word
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

;--------------------------------------------------------------------------------------------
; transit_flag_check  @0x2964
;   TRACED: dispatch-adjacent task in the same background_task_scheduler region. Tests
;   TRNSIT (edge-detect SFR) bit 3, conditionally decrements a counter at RAM 0x2EB.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; transit_gate_check  @0x297C
;   TRACED: reads RAM 0xC4 (unnamed byte), tests off(214h).3 and SFR bit 099h.7, compares
;   the periodic counter at RAM 0xE9 (the same counter periodic_decay_task_1 increments)
;   against 50, and on threshold calls mul_scale_helper2 with the tiny table at 0x6000
;   before setting the slow-tick flag off(231h).0. Dispatch target from
;   background_task_scheduler, sandwiched between other tasks.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; adc3_sensor_task  @0x29A1
;   TRACED: dispatch target from background_task_scheduler. Reads ADCR3H, stores to RAM
;   0x2F5 (adc_Ch3), validates against off(213h).3/off(236h) and sets off(226h).7.
;   Physical sensor identity still unresolved - see the differences report.
;--------------------------------------------------------------------------------------------
adc3_sensor_task:     LB      A, ADCR3H
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
                JBS     off(00213h).3, adc3_sensor_task_load_r0
                LB      A, #0ffh
                JGE     adc3_sensor_task_if_ram21c_bit7_set
                STB     A, off(002dah)
                SJ      adc3_sensor_task_set_ram2db
adc3_sensor_task_if_ram21c_bit7_set:     JBS     off(0021ch).7, adc3_sensor_task_store_ram2da
                CMPB    off(002f3h), #000h
                JEQ     adc3_sensor_task_load_ram2da
adc3_sensor_task_store_ram2da:     STB     A, off(002dah)
adc3_sensor_task_load_ram2da:     LB      A, off(002dah)
                JNE     adc3_sensor_task_load_r0
                LB      A, #0ffh
                CMPB    A, r0
                JLT     adc3_sensor_task_store_ram2f4
                LB      A, #0ffh
                CMPB    A, r0
                JGE     adc3_sensor_task_store_ram2f4
                LB      A, r0
adc3_sensor_task_store_ram2f4:     STB     A, off(002f4h)
adc3_sensor_task_load_r0:     LB      A, r0
                SUBB    A, off(002f4h)
                JGE     adc3_sensor_task_store_ram2f2
                CLRB    A
adc3_sensor_task_store_ram2f2:     STB     A, off(002f2h)
                J       adc3_sensor_task_if_ram213_bit3_set
adc3_sensor_task_sub_ram2f3:     SUBB    A, off(002f3h)
                JGE     adc3_sensor_task_clr_ram226_bit6
                VCAL    7
                SC
adc3_sensor_task_clr_ram226_bit6:     RB      off(00226h).6
                MB      off(00226h).6, C
                JEQ     adc3_sensor_task_branch
                XORB    PSWH, #080h
adc3_sensor_task_branch:     JLT     adc3_sensor_task_set_ram2db
                CMPB    A, #006h
                JLE     adc3_sensor_task_set_ram2db
                JBR     off(00226h).7, adc3_sensor_task_set_ram2db
                CMPB    IAT_raw, #0ffh
                JLT     adc3_sensor_task_set_ram2db
                CMPB    TPS_pct, #030h
                JLT     adc3_sensor_task_set_ram2db
                CMPB    off(002f3h), #018h
                JGE     adc3_sensor_task_load_ram2db
adc3_sensor_task_set_ram2db:     MOVB    off(002dbh), #032h
adc3_sensor_task_clr_carry:     RC
                SJ      dtc12_egr_latch_2
adc3_sensor_task_load_ram2db:     LB      A, off(002dbh)
                JNE     adc3_sensor_task_clr_carry
                SC
dtc12_egr_latch_2:     MB      099h.1, C
                CLR     A
                MOV     DP, A
                ST      A, er0
                RC
                LB      A, off(002f3h)
                JEQ     adc3_sensor_task_set_ram2f8
                L       A, off(002f6h)
                JNE     adc3_sensor_task_store_er3
                L       A, #09fffh
adc3_sensor_task_store_er3:     ST      A, er3
                LB      A, off(002f2h)
                SUBB    A, off(002f3h)
                MB      r4.0, C
                JGE     adc3_sensor_task_store_r0
                VCAL    7
adc3_sensor_task_store_r0:     STB     A, r0
                L       A, #09fffh
                MOV     X1, #09fffh
                MOV     X2, #09fffh
                CAL     mul_then_clamp_x1x2_2
                MOV     DP, A
                L       A, #09fffh
                CAL     mul_then_clamp_x1x2_2
adc3_sensor_task_set_ram2f8:     MOV     off(002f8h), A
                JLT     adc3_sensor_task_load_ram2f8
                MOV     off(002f6h), DP
adc3_sensor_task_load_ram2f8:     L       A, off(002f8h)
                MOV     er0, #00050h
                MUL
                SRL     A
                SRL     A
                SRL     A
                SRL     A
                L       A, ACC
                JNE     adc3_sensor_task_vcal7
                L       A, #00001h
adc3_sensor_task_vcal7:     VCAL    7
                AND     IE, #002a0h
                RB      PSWH.0
                NOP
                NOP
                LB      A, #031h
                SUBB    A, r2
                NOP
                NOP
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                RT

;--------------------------------------------------------------------------------------------
; battery_voltage_check  @0x2A84
;   TRACED: dispatch target from background_task_scheduler, the largest of the five
;   (0x2A84-0x31DA, ~0x956 bytes). Opens by packing several condition flags (off
;   22Bh.2/.3, 21Ah.5, 210h.3, 211h.2/.5), tests TPS2_raw and idle/closed-throttle state
;   (off 217h.5), applies the CFG_DualMapSelect-gated correction pairs at
;   0x2B2D/0x2CC0/0x2D8B/0x2E5F/0x3170, and calls timer_or_counter_helper (0x5277, the
;   single most-called routine in the ROM) around a PSWL.4-guarded section - consistent
;   with injector pulse-width/timer-bank assembly.
;--------------------------------------------------------------------------------------------
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
                JBS     off(0021ah).3, battery_voltage_check_cmp_ramb4
                LB      A, #006h
battery_voltage_check_cmp_ramb4:     CMPB    A, 0b4h
                J       battery_voltage_check_carry_to_bit3
battery_voltage_store_ptr_dat_fuel:     MOV     X1, #battery_voltage_store_data
                MOV     DP, #0022ah
                MOVB    r2, TPS2_raw
                MOV     er0, #00100h
                RB      PSWL.4
                CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, off(00236h)
                CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, 0f7h
                SB      PSWL.4
                J       battery_voltage_store_call_timer_or
idle_temp_hyst1_set_carry:     SC
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
                JBR     off(00217h).5, freezeframe_flag_225_7_if_ram216_bit3
                CMPB    0c0h, #030h
                MB      off(0022ah).6, C
                RC
                SJ      freezeframe_flag_225_7_carry_to_bit0
freezeframe_flag_225_7_if_ram216_bit3:     JBR     off(00216h).3, freezeframe_flag_225_7_if_ram21a_bit3
                JBR     off(00211h).5, freezeframe_flag_225_7_set_carry
freezeframe_flag_225_7_if_ram21a_bit3:     JBS     off(0021ah).3, freezeframe_flag_225_7_set_carry
                CMPB    off(00236h), #080h
                JGE     freezeframe_flag_225_7_set_carry
                LB      A, #0feh
                JBR     off(0022ah).6, freezeframe_flag_225_7_cmp_rame9
                LB      A, #0feh
freezeframe_flag_225_7_cmp_rame9:     CMPB    A, 0e9h
                JGE     freezeframe_flag_225_7_ptr_ZoneIndexTabl
                CMPB    coolantTempByte, #03bh
                JGE     freezeframe_flag_225_7_ptr_ZoneIndexTabl
freezeframe_flag_225_7_set_carry:     SC
freezeframe_flag_225_7_carry_to_bit0:     MB      off(0021ah).0, C
freezeframe_flag_225_7_ptr_ZoneIndexTabl:     MOV     X1, #ZoneIndexTable1_SetA
                MOV     X2, #ZoneIndexTable2_SetA
                JBS     off(00216h).3, freezeframe_flag_225_7_load_ramc1
                MOV     X1, #ZoneIndexTable1_SetB
                MOV     X2, #ZoneIndexTable2_SetB
freezeframe_flag_225_7_load_ramc1:     LB      A, coolantTempByte
                VCAL    1
                STB     A, off(00276h)
                MOV     X1, X2
                LB      A, coolantTempByte
                VCAL    1
                STB     A, off(00278h)
                LB      A, coolantTempByte
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
                MOV     X2, #freezeframe_flag_225_7_data
                MOVB    r2, #034h
                CMPB    A, #016h
                JGE     idle_ectvs_check2
idle_ectvs_result1_set_r1:     MOVB    r1, r2
                L       A, #0089dh
                MOV     er3, #00480h
                SJ      idle_target_correction_start
idle_ectvs_check2:     CMPB    A, r2
                JGE     idle_ectvs_result3
                MOVB    r1, #030h
                J       cfg_selector3_dispatch
cfg_selector3_dispatch_goto:     J       cfg_selector3_dispatch_cmp_ram280
                DW  00000h
cfg_selector3_dispatch_branch:     JGE     idle_ectvs_result3
idle_ectvs_result2:     L       A, #0089dh
                MOV     er3, #00280h
                SJ      idle_target_correction_start
cfg_selector3_dispatch_goto_idle_ectvs:     J       idle_ectvs_result1
idle_ectvs_result1_cmp_r1:     CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, off(00270h)
                JEQ     idle_ectvs_flag_check
                MOVB    off(002d5h), #01eh
idle_ectvs_flag_check:     LB      A, off(002d5h)
                JNE     idle_ectvs_result2
                J       idle_ectvs_flag_check_if_ram22a_bit4_clr
idle_ectvs_flag_check_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_ectvs_flag_check_set_r1
                MOVB    r1, #02dh
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, #00a77h
                MOV     er3, #00100h
                JBS     off(00211h).5, idle_target_correction_start
idle_ectvs_flag_check_set_r1:     MOVB    r1, #02dh
                LB      A, r0
                CMPB    A, r1
                JGE     idle_ectvs_result3
                L       A, #006f9h
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
                CMPB    A, coolantTempByte
                JLE     idle_target_correction_zero
                J       idle_target_correction_done
idle_target_correction_zero:     CLR     A
                NOP
to_idle_step_condition_dispatch:     J       idle_step_flag_store
                DB  000h
idle_duty_table_lookup_diff:     LB      A, coolantTempByte
                VCAL    0
                STB     A, r2
                MOV     X1, X2
                ADD     X1, #0000eh
                LB      A, coolantTempByte
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
                MOVB    r0, TPS2_raw
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
idle_pid_recheck2:     MOVB    r2, TPS2_rate
                MB      C, off(0022bh).5
                J       idle_pid_recheck2_if_ram217_bit6_clr
                DW  00000h
idle_pid_hyst_check_if_ge_goto_idle_pid_common:     JGE     idle_pid_common
                J       idle_pid_hyst_check_load_carry_pswl_bit4
idle_pid_flag_store_clear_r5:     CLRB    r5
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
                J       idle_integrator_final_if_ram211_bit5_clr
to_idle_output_finalize:     MOVB    off(002d4h), #014h
                SJ      load_x2_result_store_ram264
idle_integrator_final_cmp_ramc1:     CMPB    coolantTempByte, #03ah
                JLT     inc_dp_step_load_ramc1
                LB      A, off(002d4h)
                JEQ     inc_dp_step
                JBS     off(0021bh).6, check_0274_zero
                CMP     0aeh, #00004h
                JGE     inc_dp_step
check_0274_zero:     L       A, off(00264h)
                JEQ     check_0274_zero_shr_dp
inc_dp_step:     INC     DP
inc_dp_step_load_ramc1:     LB      A, coolantTempByte
                MOV     X1, #inc_dp_step_interp_tbl
                VCAL    1
                MOV     X2, A
                CMPB    coolantTempByte, #034h
                JGE     load_x2_result
                MOV     X1, #inc_dp_step_interp_tbl_2
                L       A, off(00258h)
                CAL     table_interp_lookup_4byte
                CMP     A, X2
                JGE     load_x2_result_store_ram264
load_x2_result:     L       A, X2
load_x2_result_store_ram264:     ST      A, off(00264h)
check_0274_zero_shr_dp:     SRL     DP
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
idle_sub_final_store:     ST      A, off(00262h)
                MOV     X1, #idle_sub_final_store_interp_tbl_2
                LB      A, coolantTempByte
                VCAL    0
                STB     A, off(00294h)
                MB      C, off(0022bh).6
                MB      off(0022bh).7, C
                MOV     X1, #idle_sub_final_store_interp_tbl
                LB      A, coolantTempByte
                VCAL    0
                CMPB    A, off(00236h)
                MB      off(0022bh).6, C
                JBR     off(0021ah).0, idle_gate6_result
                JLT     idle_gate6_result
                JBR     off(0022bh).7, idle_gate7
                JBS     off(0021bh).7, idle_gate6_result
                MOV     X1, #tbl_idle_gate6
                LB      A, coolantTempByte
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
idle_table_lookup2:     MOV     X1, #idle_sub_final_store_interp_tbl_3
                LB      A, coolantTempByte
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
                MOV     X1, #ZoneIndexTable3_SetB
to_idle_vcal5_call:     LB      A, coolantTempByte
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
                CMPB    coolantTempByte, #02eh
                JGE     idle_gear_calc_start
                CMPB    0b4h, #005h
                JLT     idle_gear_calc_start
                JBR     off(0022ah).1, idle_gear_calc_start
                MOV     X1, #tbl_ve_map_scalar_alt
                LB      A, 0aah
                JBS     off(0021fh).1, idle_mode_dispatch3_vcal1
                MOV     X1, #tbl_ve_map_scalar
                LB      A, off(00236h)
idle_mode_dispatch3_vcal1:     VCAL    1
                STB     A, off(00274h)
                JEQ     idle_gear_calc_start
                SB      off(00228h).6
                MOV     DP, #0030ch
                L       A, [DP]
vcal5_call:     VCAL    6
                STB     A, off(0025eh)
                J       idle_vcal5_report
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
                CMPB    coolantTempByte, #034h
                JGE     idle_gear_mul_apply
                J       idle_gear_calc_start_load_ind
idle_gear_mul_apply:     MUL
                SLL     A
                L       A, er1
                J       idle_gear_mul_apply_rol_a
idle_gear_mul_apply_add_ind:     ADD     A, [DP]
                JGE     idle_gear_clamp_max
idle_gear_clamp:     L       A, #0ffffh
idle_gear_clamp_max:     SUB     A, #00a00h
                JGE     idle_gear_clamp_max_store_ram28e
                CLR     A
idle_gear_clamp_max_store_ram28e:     ST      A, off(0028eh)
                L       A, er2
                MUL
                SLL     A
                L       A, er1
                J       idle_gear_clamp_max_rol_a
idle_gear_clamp_max_add_1000:     ADD     A, #01000h
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
                MOV     DP, #idle_table_select1_data
                SJ      idle_flag_gate
idle_table_select_default:     MOV     DP, #tbl_idle_select_default
                MOV     X1, #tbl_idle_default1
                JBR     off(0021ah).5, idle_table_lookup3
                MOV     X1, #tbl_idle_default2
idle_table_lookup3:     J       idle_table_lookup3_load_ram258
idle_table_lookup3_branch:     JLT     idle_table_lookup4
                MOV     DP, #tbl_idle_lookup3
idle_table_lookup4:     J       idle_table_lookup4_ptr_dat_axis_clamp
idle_table_lookup4_if_ram21a_bit5_clr:     JBR     off(0021ah).5, idle_flag_gate
                CMP     A, 0b2h
                JGE     idle_flag_gate
                LB      A, off(00296h)
                JEQ     idle_flag_gate
                SUBB    A, #001h
                STB     A, r0
idle_table_select2:     MOV     DP, #idle_timer_gate_common_data
idle_timer_store:     MOVB    off(00296h), r0
idle_flag_gate:     J       idle_flag_gate_load_ram2dc
                DB  000h
idle_flag_gate_set_ram289:     MOVB    off(00289h), off(00288h)
                J       idle_flag_gate_set_ram22b_bit1
idle_flag_gate_if_ram228_bit5_set:     JBS     off(00228h).5, idle_flag_gate_if_ram21a_bit4_set
                JBS     off(0021ah).4, idle_mode_gate6_load_ram278
                L       A, off(00276h)
                JBS     off(00223h).5, idle_pi_mul1
                JBR     off(0021ah).0, idle_pi_mul1
                SJ      idle_mode_gate5_goto
idle_flag_gate_if_ram21a_bit4_set:     JBS     off(0021ah).4, idle_mode_gate6
                J       idle_flag_gate_set_pswl_bit4
idle_mode_gate5:     L       A, off(0027ah)
                SJ      idle_mode_gate5_goto
idle_mode_gate6:     JBR     off(00216h).3, idle_mode_gate6_if_ram229_bit5_set
                JBS     off(00229h).4, idle_mode_gate6_load_ram278
idle_mode_gate6_if_ram229_bit5_set:     JBS     off(00229h).5, idle_mode_gate6_load_ram278
                J       idle_mode_gate6_if_ram22b_bit3_clr
idle_mode_gate6_if_ram229_bit6_clr:     JBR     off(00229h).6, idle_pi_mul1
idle_mode_gate6_load_ram278:     L       A, off(00278h)
                JBR     off(0021ah).0, idle_mode_gate5_goto
                L       A, off(00276h)
                J       idle_mode_gate6_if_ram216_bit3_clr
                DB  000h,000h,000h,000h,000h,000h
idle_mode_gate6_store_er3:     ST      A, er3
                CAL     stub_or_short_helper
idle_mode_gate5_vcal6:     VCAL    6
                SJ      idle_mode_gate5_set_er3
idle_mode_gate5_goto:     J       idle_mode_gate5_store_er3
                DW  00000h
idle_mode_gate5_set_er3:     MOV     er3, off(00268h)
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
                JNE     idle_vcal5_report
                L       A, off(00214h)
                AND     A, #014fdh
                JNE     idle_vcal5_report
                JBR     off(00228h).5, idle_vcal5_report
                JBS     off(0021ah).3, idle_vcal5_report
                J       idle_vcal5_call3_if_ram21a_bit0_clr
idle_vcal5_call3_goto:     J       idle_vcal5_call3_load_ram27c
                DB  000h
idle_vcal5_call3_goto_2:     J       idle_vcal5_call3_load_ram266
idle_vcal5_call3_cmp_rama6:     CMPB    TPS_pct, #070h
                JLT     idle_vcal5_report
                CMP     0b0h, #00018h
                JGE     idle_vcal5_report
                L       A, #00040h
                JBR     off(0021ah).5, idle_stall_check2
                L       A, #00040h
idle_stall_check2:     CMP     A, 0b2h
                JLT     idle_vcal5_report
                CMPB    coolantTempByte, #067h
                J       idle_stall_check2_branch
                DB  000h
idle_stall_check2_ptr_tbl_idle_stall:     MOV     X1, #tbl_idle_stall
                VCAL    2
                LB      A, #0a8h
                JBS     off(00216h).3, sub_r6_clamp_zero
                LB      A, #0b8h
sub_r6_clamp_zero:     SUBB    A, r6
                JGE     idle_stall_er0_select1
                CLRB    A
idle_stall_er0_select1:     MOV     er0, #00040h
                CMPB    A, TPS_pct
                JLT     idle_stall_er0_select2
                MOV     er0, #00010h
idle_stall_er0_select2:     CMPB    coolantTempByte, #028h
                JLT     idle_stall_diff_calc
                MOV     er0, #00001h
idle_stall_diff_calc:     MOV     X1, #0030ch
                J       idle_stall_diff_calc_load_ram284
                DB  000h
idle_stall_diff_calc_branch:     JGE     idle_stall_trigger
idle_stall_diff_check:     CLR     A
idle_stall_trigger:     CAL     injtimer_bank_calc1
                CAL     idle_stall_helper
idle_vcal5_report:     JBR     off(00217h).5, idle_vcal5_report_cmp_rame8
                LB      A, coolantTempByte
                MOV     X1, #idle_vcal5_report_interp_tbl
                VCAL    1
                SJ      idle_vcal5_report_store_ram27c
idle_vcal5_report_cmp_rame8:     CMPB    0e8h, #00ch
                JGE     idle_vcal5_report_clear_a
                MOV     X1, #idle_vcal5_report_data
                JBR     off(00228h).5, idle_vcal5_report_ptr_dat_fuel_injector
                LB      A, off(00236h)
                CMPB    A, off(00292h)
                JGE     idle_vcal5_report_load_ramc1
idle_vcal5_report_ptr_dat_fuel_injector:     MOV     X1, #idle_vcal5_report_interp_tbl_2
idle_vcal5_report_load_ramc1:     LB      A, coolantTempByte
                VCAL    1
                L       A, off(0027ch)
                SUB     A, er3
                JGE     idle_vcal5_report_store_ram27c
idle_vcal5_report_clear_a:     CLR     A
idle_vcal5_report_store_ram27c:     ST      A, off(0027ch)
                LB      A, 0c0h
                MOV     X1, #idle_vcal5_report_interp_tbl_3
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
                JNE     idle_target_final_ptr_30c
                L       A, off(00214h)
                AND     A, #014fdh
                JEQ     idle_target_final_set_er3
idle_target_final_ptr_30c:     MOV     DP, #0030ch
                CAL     stub_or_short_helper
                ST      A, [DP]
idle_target_final_set_er3:     MOV     er3, #00600h
                CAL     stub_or_short_helper
                VCAL    6
                MB      C, 098h.1
                JLT     idle_output_common
                JBS     off(00212h).5, idle_output_common
                MOV     er3, off(00276h)
                J       idle_target_final_call_stub_or_short
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
                MOV     X1, #idle_pi_final_calc_interp_tbl
                LB      A, 0a4h
                VCAL    2
                STB     A, off(00290h)
                MOV     X1, #idle_pi_final_calc_interp_tbl_3
                JBS     off(00216h).3, idle_pi_final_calc_load_ramc1
                MOV     X1, #idle_pi_final_calc_interp_tbl_2
idle_pi_final_calc_load_ramc1:     LB      A, coolantTempByte
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

;--------------------------------------------------------------------------------------------
; ignition_timing_calc_task  @0x31DB
;   TRACED: dispatch target from background_task_scheduler (0x31DB-0x35B8, ~0x3DD bytes).
;   Reads RAM 0xB9 and 0xB4 as axes into a long chain of VCAL 0 table lookups, and
;   contains the IAT_raw/TPS_pct correction chain plus the CFG_DualMapSelect pairs at
;   0x3EF3/0x3F11/0x401E/0x402B/0x411F. The concentration of IAT and TPS corrections
;   feeding a single accumulating result is consistent with ignition timing/trim assembly,
;   distinct from battery_voltage_check.
;--------------------------------------------------------------------------------------------
ignition_timing_calc_task:     MOVB    r5, 0b9h
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_interp_tbl
                VCAL    0
                STB     A, r4
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_interp_tbl_2
                VCAL    0
                STB     A, r3
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_interp_tbl_3
                VCAL    0
                STB     A, r2
                JBS     off(0022eh).5, ignition_timing_calc_cmp_r5
                LB      A, r3
ignition_timing_calc_cmp_r5:     CMPB    A, r5
                MB      off(0022eh).5, C
                LB      A, r2
                JBS     off(0022eh).4, ignition_timing_calc_sub_r4
                LB      A, r3
ignition_timing_calc_sub_r4:     SUBB    A, r4
                J       ignition_timing_calc_branch_7
                DB  000h
ignition_timing_calc_load_ramb4:     LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_interp_tbl_4
                VCAL    0
                STB     A, r3
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_interp_tbl_5
                VCAL    0
                STB     A, r2
                JBS     off(0022eh).7, ignition_timing_calc_cmp_r5_2
                LB      A, r3
ignition_timing_calc_cmp_r5_2:     CMPB    A, r5
                MB      off(0022eh).7, C
                LB      A, r2
                JBS     off(0022eh).6, ignition_timing_calc_sub_r4_2
                LB      A, r3
ignition_timing_calc_sub_r4_2:     SUBB    A, r4
                J       ignition_timing_calc_branch_8
                DB  000h
ignition_timing_calc_load_ramb4_2:     LB      A, 0b4h
                STB     A, r4
                MOV     X1, #ignition_timing_calc_interp_tbl_8
                VCAL    0
                STB     A, off(0029fh)
                LB      A, r4
                MOV     X1, #ignition_timing_calc_interp_tbl_9
                VCAL    0
                STB     A, off(002a0h)
                CMPB    A, r5
                XORB    PSWH, #080h
                JGE     ignition_timing_calc_carry_to_bit3
                LB      A, off(0029fh)
                CMPB    A, r5
ignition_timing_calc_carry_to_bit3:     MB      off(0022fh).3, C
                LB      A, r4
                MOV     X1, #ignition_timing_calc_interp_tbl_10
                VCAL    0
                STB     A, off(002a1h)
                LB      A, r4
                MOV     X1, #ignition_timing_calc_interp_tbl_11
                VCAL    0
                STB     A, off(002a2h)
                CMPB    A, r5
                XORB    PSWH, #080h
                JGE     ignition_timing_calc_carry_to_bit4
                LB      A, off(002a1h)
                CMPB    A, r5
ignition_timing_calc_carry_to_bit4:     MB      off(0022fh).4, C
                LB      A, 0b4h
                MOV     X1, #ignition_timing_calc_interp_tbl_6
                JBS     off(0022eh).3, ignition_timing_calc_vcal0
                MOV     X1, #ignition_timing_calc_interp_tbl_7
ignition_timing_calc_vcal0:     VCAL    0
                MOV     DP, #00311h
                ADDB    A, [DP]
                CMPB    A, 0bch
                MB      off(0022eh).3, C
                MOV     DP, #0022ch
                MOV     er0, #00800h
                MOV     X1, #ignition_timing_calc_data
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
                JBS     off(00211h).5, ignition_timing_calc_load_r7
                JBS     off(00211h).6, ignition_timing_calc_if_ram22e_bit2_set
                JBR     off(00211h).7, ignition_timing_calc_load_r7
                JBS     off(0022ch).0, ignition_timing_calc_clear_r7
ignition_timing_calc_if_ram22e_bit2_set:     JBS     off(0022eh).2, ignition_timing_calc_load_r7
                JBR     off(0022fh).6, ignition_timing_calc_cmp_10
                CMPB    A, #027h
                JLT     ignition_timing_calc_load_r7
                MOVB    r7, #040h
                SJ      ignition_timing_calc_if_ram22c_bit1_clr
ignition_timing_calc_cmp_10:     CMPB    A, #010h
                JLT     ignition_timing_calc_load_r7
                MOVB    r7, #040h
                JBS     off(0022fh).7, ignition_timing_calc_if_ram22c_bit1_clr
                JBS     off(0022eh).3, ignition_timing_calc_if_ram22c_bit1_clr
                CMPB    A, #010h
                JGE     ignition_timing_calc_clear_r7
                SJ      ignition_timing_calc_load_r7
ignition_timing_calc_if_ram22c_bit1_clr:     JBR     off(0022ch).1, ignition_timing_calc_load_r7
                JBS     off(00211h).6, ignition_timing_calc_load_r7
                JBS     off(0022eh).6, ignition_timing_calc_load_r7
ignition_timing_calc_clear_r7:     CLRB    r7
ignition_timing_calc_load_r7:     LB      A, r7
                SLLB    A
                MB      off(0022fh).6, C
                SLLB    A
                MB      off(0022fh).7, C
                LB      A, off(00214h)
                STB     A, ACCH
                LB      A, off(00212h)
                AND     ACC, #00560h
                JNE     ignition_timing_calc_set_ram2ca
                CMPB    coolantTempByte, #03ch
                JGE     ignition_timing_calc_set_ram2ca
                JBR     off(0022eh).1, ignition_timing_calc_set_ram2ca
                JBS     off(00211h).7, ignition_timing_calc_set_ram2cc
                JBR     off(00211h).6, ignition_timing_calc_set_ram2ca
                JBR     off(0022fh).0, ignition_timing_calc_load_ram2cc
                MOVB    off(002c9h), #014h
ignition_timing_calc_load_ram2cc:     LB      A, off(002cch)
                JNE     ignition_timing_calc_clr_carry
                SJ      ignition_timing_calc_load_ram2ca
ignition_timing_calc_set_ram2ca:     MOVB    off(002cah), #002h
ignition_timing_calc_load_ram2ca:     LB      A, off(002cah)
                JEQ     ignition_timing_calc_if_ram21b_bit6_set
                SJ      ignition_timing_calc_clr_carry
ignition_timing_calc_set_ram2cc:     MOVB    off(002cch), #00ch
                LB      A, off(002c9h)
                JEQ     ignition_timing_calc_load_ram2ca
ignition_timing_calc_if_ram21b_bit6_set:     JBS     off(0021bh).6, ignition_timing_calc_load_ram2cb
                CMP     0aeh, #00120h
                JLT     ignition_timing_calc_load_ram2cb
                MOVB    off(002cbh), #014h
ignition_timing_calc_load_ram2cb:     LB      A, off(002cbh)
                JNE     ignition_timing_calc_clr_carry
                JBS     off(0022eh).3, ignition_timing_calc_if_ram211_bit6_set
                JBS     off(0022fh).6, ignition_timing_calc_clr_carry
                MB      C, off(0022dh).6
                JBS     off(0022fh).7, ignition_timing_calc_branch
                MB      C, off(0022dh).7
ignition_timing_calc_branch:     JGE     ignition_timing_calc_clr_carry
                JBS     off(0022eh).0, ignition_timing_calc_clr_carry
                LB      A, off(002e5h)
                JEQ     ignition_timing_calc_clr_carry
                JBS     off(0021ch).3, ignition_timing_calc_if_ram22f_bit0_set
ignition_timing_calc_clr_carry:     RC
                SJ      ignition_timing_calc_carry_to_bit0
ignition_timing_calc_if_ram211_bit6_set:     JBS     off(00211h).6, ignition_timing_calc_if_ram22c_bit2_set
                JBS     off(0022ch).4, ignition_timing_calc_if_ram22f_bit0_set
                JBR     off(0022ch).5, ignition_timing_calc_set_ram2cd
                JBR     off(0022eh).7, ignition_timing_calc_load_ram2cd
ignition_timing_calc_set_ram2cd:     MOVB    off(002cdh), #014h
                SJ      ignition_timing_calc_load_ram2cd
ignition_timing_calc_if_ram22c_bit2_set:     JBS     off(0022ch).2, ignition_timing_calc_if_ram22f_bit0_set
                JBR     off(0022ch).3, ignition_timing_calc_set_ram2cd
                JBS     off(0022eh).5, ignition_timing_calc_set_ram2cd
ignition_timing_calc_load_ram2cd:     LB      A, off(002cdh)
                JNE     ignition_timing_calc_clr_carry
ignition_timing_calc_if_ram22f_bit0_set:     JBS     off(0022fh).0, ignition_timing_calc_set_carry
                J       ignition_timing_calc_load_rambd
                DB  000h
ignition_timing_calc_branch_2:     JLE     ignition_timing_calc_load_ram2d2
ignition_timing_calc_set_ram2d2:     MOVB    off(002d2h), #002h
ignition_timing_calc_load_ram2d2:     LB      A, off(002d2h)
                JNE     ignition_timing_calc_clr_carry
ignition_timing_calc_set_carry:     SC
ignition_timing_calc_carry_to_bit0:     MB      off(0022fh).0, C
                MB      P0.4, C
                CMPB    0c0h, #0e1h
                JGE     ignition_timing_calc_load_c
                CMPB    coolantTempByte, #02eh
                JLT     ignition_timing_calc_if_ram22d_bit0_set
ignition_timing_calc_load_c:     LB      A, #00ch
                STB     A, off(002b0h)
                STB     A, off(0029eh)
                SJ      ignition_timing_calc_goto_5
ignition_timing_calc_if_ram22d_bit0_set:     JBS     off(0022dh).0, ignition_timing_calc_load_ram2b0
                LB      A, off(0029eh)
                STB     A, off(002b0h)
                SJ      ignition_timing_calc_branch_3
ignition_timing_calc_load_ram2b0:     LB      A, off(002b0h)
                STB     A, off(0029eh)
ignition_timing_calc_branch_3:     JNE     ignition_timing_calc_goto_5
                JBR     off(0022fh).0, ignition_timing_calc_goto_5
                JBS     off(0022eh).3, ignition_timing_calc_test_ram22e_bit4
                JBS     off(0022fh).7, ignition_timing_calc_goto
                JBS     off(0022fh).6, ignition_timing_calc_goto_5
ignition_timing_calc_goto:     SJ      ignition_timing_calc_goto_3
ignition_timing_calc_test_ram22e_bit4:     MB      C, off(0022eh).4
                JBS     off(00211h).6, ignition_timing_calc_branch_4
                MB      C, off(0022eh).6
ignition_timing_calc_branch_4:     JGE     ignition_timing_calc_load_ram2ce
                MOVB    off(002ceh), #00ah
ignition_timing_calc_load_ram2ce:     LB      A, off(002ceh)
                JNE     ignition_timing_calc_goto_5
                MOV     er1, #00028h
                JBR     off(00211h).6, ignition_timing_calc_if_ram22d_bit5_clr
                JBR     off(0022dh).4, ignition_timing_calc_goto_5
                SJ      ignition_timing_calc_goto_4
ignition_timing_calc_if_ram22d_bit5_clr:     JBR     off(0022dh).5, ignition_timing_calc_if_ram22d_bit1_set
                MOV     er1, #00033h
                SJ      ignition_timing_calc_goto_4
ignition_timing_calc_if_ram22d_bit1_set:     JBS     off(0022dh).1, ignition_timing_calc_goto_4
                JBS     off(0022fh).7, ignition_timing_calc_if_ram22d_bit2_clr
                JBS     off(0022fh).6, ignition_timing_calc_goto_5
                JBR     off(0022dh).3, ignition_timing_calc_goto_5
                SJ      ignition_timing_calc_test_ram22f_bit3
ignition_timing_calc_if_ram22d_bit2_clr:     JBR     off(0022dh).2, ignition_timing_calc_goto_5
ignition_timing_calc_test_ram22f_bit3:     MB      C, off(0022fh).3
                JBS     off(0022fh).7, ignition_timing_calc_branch_5
                MB      C, off(0022fh).4
ignition_timing_calc_branch_5:     JLT     ignition_timing_calc_goto_2
                MOVB    off(002cfh), #00ah
ignition_timing_calc_goto_2:     J       ignition_timing_calc_load_ram2cf
                DB  000h,003h,039h,035h
ignition_timing_calc_goto_3:     J       ignition_timing_calc_clear_r0
ignition_timing_calc_goto_4:     J       ignition_timing_calc_load_ram298
ignition_timing_calc_goto_5:     J       ignition_timing_calc_clear_a
ignition_timing_calc_load_ram29f:     LB      A, off(0029fh)
                MOVB    r0, #060h
                MOV     er1, #0332eh
                MOVB    r6, #020h
                MOVB    r7, #020h
                JBS     off(0022fh).7, ignition_timing_calc_sub_ramb9
                LB      A, off(002a1h)
                MOVB    r0, #060h
                MOV     er1, #044a1h
                MOVB    r6, #020h
                MOVB    r7, #020h
ignition_timing_calc_sub_ramb9:     SUBB    A, 0b9h
                MB      PSWL.4, C
                JGE     ignition_timing_calc_mul
                VCAL    7
ignition_timing_calc_mul:     MULB
                L       A, ACC
                MOVB    r0, #020h
                NOP
                NOP
                NOP
                NOP
                MB      C, PSWL.4
                JGE     ignition_timing_calc_add_er1
                XCHG    A, er1
                SUB     A, er1
                JGE     ignition_timing_calc_store_er0
                CLR     A
                SJ      ignition_timing_calc_store_er0
ignition_timing_calc_add_er1:     ADD     A, er1
                JGE     ignition_timing_calc_store_er0
                L       A, #0ffffh
ignition_timing_calc_store_er0:     ST      A, er0
                L       A, 0b6h
                MUL
                L       A, er1
                MOV     DP, #0038ah
                ST      A, [DP]
                SUB     A, 0ach
                MB      PSWL.4, C
                JGE     ignition_timing_calc_ptr_38c
                VCAL    7
ignition_timing_calc_ptr_38c:     MOV     DP, #0038ch
                ST      A, [DP]
                CAL     weighted_sum_2term_trim
ignition_timing_calc_branch_6:     JEQ     ignition_timing_calc_set_x2
                CMP     A, #00333h
                JLT     ignition_timing_calc_set_x2
                L       A, #00333h
ignition_timing_calc_set_x2:     MOV     X2, A
                MOV     X1, #00316h
                JBS     off(0022fh).7, ignition_timing_calc_set_er0
                INC     X1
                INC     X1
ignition_timing_calc_set_er0:     MOV     er0, #000ffh
                CAL     interp_bracket_delta_scale_2
                CAL     clamp_to_35_512
                L       A, X2
                J       ignition_timing_calc_clr_ram22f_bit2_2
ignition_timing_calc_clear_r0:     CLRB    r0
                MOV     DP, #00312h
                MOVB    r1, #090h
                MOVB    r2, #040h
                JBS     off(0022fh).7, ignition_timing_calc_load_ind
                INC     DP
                INC     DP
                MOVB    r1, #080h
                MOVB    r2, #040h
ignition_timing_calc_load_ind:     L       A, [DP]
                SUB     A, off(0029ah)
                MB      PSWL.4, C
                JGE     ignition_timing_calc_cmp_155
                VCAL    7
                MOVB    r1, r2
ignition_timing_calc_cmp_155:     CMP     A, #00155h
                SB      off(0022fh).1
                JGE     ignition_timing_calc_goto_6
                JNE     ignition_timing_calc_if_ram22f_bit5_set
                J       ignition_timing_calc_load_ind_3
ignition_timing_calc_goto_6:     J       ignition_timing_calc_mul_4
                DB  000h
ignition_timing_calc_test_pswl_bit4:     MB      C, PSWL.4
                JLT     ignition_timing_calc_sub_er1
                ADD     A, er1
                J       ignition_timing_calc_branch_9
                DW  00000h
ignition_timing_calc_goto_7:     SJ      ignition_timing_calc_store_ram29a
ignition_timing_calc_sub_er1:     SUB     A, er1
                JGE     ignition_timing_calc_store_ram29a
                CLR     A
ignition_timing_calc_store_ram29a:     ST      A, off(0029ah)
ignition_timing_calc_if_ram22f_bit5_set:     JBS     off(0022fh).5, ignition_timing_calc_set_ram2d0
                CMP     off(0029ch), #00180h
                JLT     ignition_timing_calc_set_ram2d0
                LB      A, off(002d0h)
                JNE     ignition_timing_calc_load_ramb6
                RB      off(0022fh).7
                SJ      ignition_timing_calc_load_ramb6
ignition_timing_calc_set_ram2d0:     MOVB    off(002d0h), #028h
ignition_timing_calc_load_ramb6:     L       A, 0b6h
                MOV     er0, #034c2h
                JBS     off(0022fh).7, ignition_timing_calc_mul_2
                MOV     er0, #04a55h
ignition_timing_calc_mul_2:     MUL
                L       A, er1
                MOV     DP, #0038ah
                ST      A, [DP]
                L       A, 0ach
                SUB     A, er1
                MB      off(0022fh).5, C
                MB      PSWL.4, C
                JGE     ignition_timing_calc_store_ram29c
                VCAL    7
ignition_timing_calc_store_ram29c:     ST      A, off(0029ch)
                MOVB    r6, #040h
                MOVB    r7, #040h
                CAL     weighted_sum_2term_trim
                MOV     X2, A
                JEQ     ignition_timing_calc_cmp_ram2d1
                MOVB    off(002d1h), #014h
ignition_timing_calc_cmp_ram2d1:     CMPB    off(002d1h), #000h
                JNE     ignition_timing_calc_if_ram22c_bit6_clr
                CLR     X2
                SJ      ignition_timing_calc_load_x2
ignition_timing_calc_if_ram22c_bit6_clr:     JBR     off(0022ch).6, ignition_timing_calc_load_x2
                JBS     off(0022ch).7, ignition_timing_calc_load_x2
                MOV     X1, #00312h
                JBS     off(0022fh).7, ignition_timing_calc_set_er0_2
                INC     X1
                INC     X1
ignition_timing_calc_set_er0_2:     MOV     er0, #000ffh
                CAL     interp_bracket_delta_scale_2
                CAL     clamp_to_35_1023
ignition_timing_calc_load_x2:     L       A, X2
                J       ignition_timing_calc_clr_ram22f_bit2_3
                DW  00000h
ignition_timing_calc_load_ram29f_2:     LB      A, off(0029fh)
                MOVB    r0, #0ffh
                MOV     DP, #00316h
                JBS     off(0022fh).7, ignition_timing_calc_sub_ramb9_2
                LB      A, off(002a1h)
                MOVB    r0, #0ffh
                INC     DP
                INC     DP
ignition_timing_calc_sub_ramb9_2:     SUBB    A, 0b9h
                JLT     ignition_timing_calc_vcal7
                CLRB    r0
ignition_timing_calc_vcal7:     VCAL    7
                MULB
                L       A, ACC
                J       ignition_timing_calc_shl_a
ignition_timing_calc_load_ffff:     L       A, #0ffffh
ignition_timing_calc_set_r1:     MOVB    r1, ACCH
                ADDB    r1, #040h
                J       ignition_timing_calc_branch_10
ignition_timing_calc_mul_3:     MUL
                J       ignition_timing_calc_shl_a_2
ignition_timing_calc_if_ram22f_bit2_set:     JBS     off(0022fh).2, ignition_timing_calc_store_ram29a_2
                CMP     A, off(00298h)
                MB      off(0022fh).2, C
                JLT     ignition_timing_calc_store_ram29a_2
                L       A, off(00298h)
                ADD     A, #00020h
                CAL     clamp_0_3ff_simple
                SJ      ignition_timing_calc_goto_8
                DW  to_injtimer_store_0x166
ignition_timing_calc_store_ram29a_2:     ST      A, off(0029ah)
                SJ      ignition_timing_calc_goto_8
ignition_timing_calc_load_ram298:     L       A, off(00298h)
                ADD     A, er1
                JLT     ignition_timing_calc_load_3ff
                J       ignition_timing_calc_cmp_3ff_3
ignition_timing_calc_cmp_3ff:     CMP     A, #003ffh
                JLT     ignition_timing_calc_clr_ram22f_bit2
ignition_timing_calc_load_3ff:     L       A, #003ffh
                SJ      ignition_timing_calc_clr_ram22f_bit2
ignition_timing_calc_clear_a:     CLR     A
                ST      A, off(0029ah)
ignition_timing_calc_clr_ram22f_bit2:     RB      off(0022fh).2
ignition_timing_calc_goto_8:     J       ignition_timing_calc_clr_ram22f_bit1
                DW  00000h
ignition_timing_calc_cmp_23:     CMP     A, #00023h
                JGE     ignition_timing_calc_set_er0_3
                CLR     A
ignition_timing_calc_set_er0_3:     MOV     er0, #00064h
                MUL
                MOV     er0, er1
                MOV     er2, #003ffh
                DIV
                LB      A, ACC
                NOP
                NOP
                RT

;--------------------------------------------------------------------------------------------
; periodic_decay_task_1  @0x35B9
;   TRACED: dispatch target from background_task_scheduler, runs only when the
;   divide-by-10 slow tick sets off(231h).1. Calls decrement_timer_array (0x5204) over two
;   RAM ranges, then increments a counter at RAM 0xE9.
;--------------------------------------------------------------------------------------------
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
                JNE     vcal3_task_c_msec_tick_cmp_ind
                LB      A, [DP]
                JEQ     vcal3_task_c_msec_tick_load_ram2a8
                MOVB    r6, #0ffh
                CMPB    r6, A
                MB      off(00225h).6, C
                CLRB    A
                SJ      vcal3_task_c_msec_tick_store_ind
vcal3_task_c_msec_tick_cmp_ind:     CMPB    A, [DP]
                JLT     vcal3_task_c_msec_tick_load_ram2a8
vcal3_task_c_msec_tick_store_ind:     STB     A, [DP]
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
                LCB     A, idle_init_start_const
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
                TRB     [DP]  ; [H] ;mnemonic was "TBR" (letter transposition); confirmed as TRB against HondaTuningSuiteRom120.asm, same opcode C213
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
                LCB     A, idle_init_start_const
                JEQ     set_carry_flag
                LB      A, 0e7h
                JNE     tach_output_drive2
set_carry_flag:     SC
tach_output_drive2:     MB      P1.4, C
tach_output_return:     RT

;--------------------------------------------------------------------------------------------
; vcal3_task_b_body  @0x36CE
;   TRACED: dispatch target from background_task_scheduler, runs only when the
;   divide-by-10 slow tick sets off(231h).2. Structurally identical to
;   periodic_decay_task_1 but over different RAM ranges and counter (RAM 0xE8).
;--------------------------------------------------------------------------------------------
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
                JNE     learn_retry_store_load_6
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
learn_retry_store_load_6:     LB      A, #006h
                CMPB    A, (00185h-00180h)[USP]
                JLE     learn_retry_store_cmp_stk
                INCB    (00185h-00180h)[USP]
learn_retry_store_cmp_stk:     CMPB    A, (00184h-00180h)[USP]
                JLE     learn_retry_store_return
                INCB    (00184h-00180h)[USP]
learn_retry_store_return:     RT

;--------------------------------------------------------------------------------------------
; regbank_selftest2_start  @0x3750
;   TRACED (top level; internals not yet subdivided): self-test-guarded entry point -
;   compares a ROM constant against IE and against a fixed interrupt-mask snapshot, traps
;   via BRK reason 0x4F on mismatch. Spans 0x3750-0x4B75 (~5.1 KB) and calls into every
;   major subsystem: knock_helper1, ect_step_helper, ect_smooth_helper,
;   timer_or_counter_helper, ResetWatchDog, selftest_regbank_verify, cfgvariant_checksum2_calc and
;   boot_completion_helper. This is almost certainly the top-level "run once per
;   main-loop pass" routine. Its internal fuel/knock/ECT sub-sections have not yet been
;   individually separated out - that is the next unit of work on this ROM.
;--------------------------------------------------------------------------------------------
regbank_selftest2_start:     L       A, #02bafh
                MOV     X1, #002a0h
                JBR     off(00217h).2, regbank_selftest2_ie_check
                L       A, #0a9a7h
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
                L       A, #02bafh
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
                L       A, #0a9a7h
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
                ANDB    A, #000h
                CMPB    A, #000h
                NOP
                NOP
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
                J       periph_init_verify_and_ie
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
periph_init_verify_and_ie:     AND     IE, #002a0h
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
; [H] --- Oscillator/timer cross-check: snapshots TM0/TM1/TM2 into X1/X2/DP, re-enables
; [H] interrupts briefly (IE/PSWH toggling), re-snapshots into er0/er1/er2, then verifies the
; [H] deltas fall within expected ranges (0x22, 0x80, 0x22, a ratio check against er1>>2) --
; [H] confirms the timers are actually counting at the rate the code expects (i.e. the clock
; [H] source/oscillator is running correctly) before trusting any timing-dependent logic
; [H] (ignition/injection scheduling) downstream. Out-of-range -> selftest_fail_04b.
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
                J       coldstart_full_reset_and_p1
                DW  00000h
coldstart_full_reset_goto:     J       coldstart_full_reset_clr_ram221_bit7
coldstart_full_reset_or_tcon3:     ORB     TCON3, #00ch
                CLR     A
                ST      A, (00120h-00180h)[USP]
                ST      A, (0011ch-00180h)[USP]
                ST      A, off(0021ch)
                ST      A, (001d0h-00180h)[USP]
                ST      A, (001ceh-00180h)[USP]
                J       coldstart_full_reset_store_ramf0
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
                JNE     tps_learn_vcal3_call_ptr_30c
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
                JNE     tps_learn_table_store_ptr_311
                MOV     DP, #00311h
                LB      A, r3
                STB     A, [DP]
                MOV     DP, #00310h
                LB      A, #0ffh
                STB     A, [DP]
                SJ      tps_learn_table_store_ptr_311
tps_learn_table_store:     MOV     DP, #00310h
                LB      A, [DP]
                JNE     tps_learn_table_store_load_r0
                MOVB    r0, #053h
tps_learn_table_store_load_r0:     LB      A, r0
                STB     A, off(002a3h)
                LB      A, r1
                STB     A, off(002a4h)
tps_learn_table_store_ptr_311:     MOV     DP, #00311h
                LB      A, [DP]
                CMPB    A, r2
                JLT     tps_learn_vcal3_call_ptr_30c
                LB      A, r2
                STB     A, [DP]
                SJ      tps_learn_vcal3_call_ptr_30c
tps_learn_vcal3_call_store_ram2a3:     STB     A, off(002a3h)
tps_learn_vcal3_call_ptr_30c:     MOV     DP, #0030ch
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
                LC      A, tbl_knock_sanity[ACC]
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
                STB     A, IAT_raw
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
                JLT     ect_fault_stamp
                JBS     off(00210h).7, ect_fault_range_check_ptr_c1
                SUBB    A, off(002a5h)
                JGE     ect_fault_delta_check
                VCAL    7
ect_fault_delta_check:     CMPB    A, #002h
                JGT     ect_fault_normal_store
                LB      A, off(002b9h)
                JNE     sensor_bank_ect_check_clr_carry
                LB      A, r1
                JBS     off(00217h).4, ect_fault_range_check_ptr_c1
                CMPB    A, off(002a6h)
                JGT     sensor_bank_ect_check
                SJ      ect_fault_range_check_ptr_c1
ect_simulate_ramp:     JBR     off(00217h).5, ect_fault_stamp
                CLR     A
                LB      A, off(002bah)
                MOVB    r0, #014h
                DIVB
                MOV     DP, #ZoneRemapTable
                ADD     DP, A
                LCB     A, [DP]
                STB     A, coolantTempByte
                SJ      sensor_bank_ect_check
ect_fault_stamp:     MOVB    coolantTempByte, #03bh
                SJ      sensor_bank_ect_check
ect_fault_range_check_ptr_c1:     MOV     DP, #000c1h
                CAL     ect_smooth_helper
                JBS     off(00217h).5, ect_step_call
                MOV     DP, #00352h
                STB     A, [DP]
ect_step_call:     CAL     ect_step_helper
ect_fault_normal_store:     MOVB    off(002a5h), r1
sensor_bank_ect_check:     MOVB    off(002b9h), #005h
sensor_bank_ect_check_clr_carry:     RC
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
                LB      A, IAT_raw
                MOV     X1, #tbl_dcode14_lo
                VCAL    3
                CMPB    A, off(0025ah)
                JLT     dcode14_clear
                LB      A, IAT_raw
                MOV     X1, #tbl_dcode14_hi
                VCAL    3
                CMPB    A, off(0025ah)
                JGE     dcode14_clear
                LB      A, off(002bdh)
                JEQ     dtc14_iacv_latch
dcode14_clear:     RC
dtc14_iacv_latch:     MB      099h.3, C
                LB      A, #044h
                CMPB    A, IAT_raw
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
                JBS     off(00227h).2, dcode_gate_common_load_25
                J       dcode_gate_common_if_ram216_bit3_clr
dcode_gate_common_ptr_380:     MOV     DP, #00380h
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
                JGE     dcode_gate_common_load_25
                SUBB    A, r1
                JLT     dcode_gate_common_add_a
                LB      A, r7
                JEQ     dtc19_at_lockup_latch
                SJ      dcode_gate_common_load_25
dcode_gate_common_add_a:     ADDB    A, #00ah
                JLT     dcode_gate_common_load_25
                LB      A, r7
                JEQ     dcode_gate_common_load_25
dtc19_at_lockup_latch:     SB      09ch.7
dcode_gate_common_load_25:     LB      A, #025h
                JBR     off(00219h).1, dcode_stamp_store
                JBR     off(00217h).6, dcode_stamp_store
                JBS     off(00214h).3, dcode_stamp_store
                CMPB    IAT_raw, #069h
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
                NOP
                SJ      dtc21_vtec_solenoid_latch
                DB  0ECh,014h,018h,0DAh,01Fh,00Ch,0C4h,0C0h
                DB  098h,014h,0F4h,0BFh,0EDh,010h,00Ch,085h
                DB  0CBh,009h,0C4h,0BFh,098h,014h,0F4h,0C0h
                DB  0EDh,010h,0F4h
dtc21_vtec_solenoid_latch:     MB      09ah.0, C
                NOP
                SJ      altvtec_vtps_result
                DB  0CEh,013h,0ECh,014h,010h,0CAh,00Eh,0EDh
                DB  014h,00Bh,0C4h,011h,029h,0DAh,01Fh,006h
                DB  0CAh,003h,085h,0CBh,001h
altvtec_vtps_result:     RC
dtc22_vtec_pressure_latch: MB      09ah.1, C
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
                STB     A, adc_Ch5_new
                JBR     off(00216h).5, autotcc_return
                JBS     off(00217h).5, autotcc_return
                JBS     off(00215h).1, autotcc_return
                LB      A, IAT_raw
                CMPB    A, #07dh
                JLT     autotcc_return
                LB      A, #0fch
                CMPB    A, adc_Ch5_new
                JLT     dtc26_code26_latch
                LB      A, adc_Ch5_new
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
                LB      A, IAT_raw
                CMPB    A, #07dh
                JLT     automatic_return
                LB      A, adc_Ch5_new
                CMPB    A, #030h
                JLE     Automatic_test_p4_bit6
                MB      C, P4.6
                JGE     automatic_p4_check
                SJ      automatic_return
Automatic_test_p4_bit6:     MB      C, P4.6
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
                J       table_select_6221_57fb_alt2
table_select_6221_branch:     JGE     knockwindow_clear
                JBS     off(0021ch).5, knockwindow_clear
                JBS     off(0021dh).3, knockwindow_clear
                J       table_select_6221_if_ram218_bit0_set
table_select_6221_load_stk:     L       A, (00148h-00180h)[USP]
                CMP     A, #0b333h
                JGE     knockwindow_set
                J       table_select_6221_if_ram217_bit3_set
table_select_6221_branch_2:     JLE     knockwindow_set
knockwindow_clear:     RC
                SJ      knockwindow_result
knockwindow_set:     SC
knockwindow_result:     MB      09dh.7, C
                VCAL    4
                LB      A, coolantTempByte
                MOV     X1, #tbl_ect_fuelcorrect
                MOV     X2, #knockwindow_result_data
                CMPB    A, #023h
                JLT     knockwindow_result_carry_to_ram221_bit2
                MOV     X1, #knockwindow_result_interp_tbl_3
                MOV     X2, #knockwindow_result_interp_tbl_2
knockwindow_result_carry_to_ram221_bit2:     MB      off(00221h).2, C
                VCAL    0
                STB     A, r3
                MOV     X1, X2
                LB      A, coolantTempByte
                VCAL    0
                STB     A, r2
                MOV     off(00252h), er1
                LB      A, coolantTempByte
                MOV     X1, #knockwindow_result_interp_tbl
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
                MOV     X1, #threshold_bank_220_6_interp_tbl
                VCAL    0
threshold_bank_222_6:     STB     A, off(0023ah)
                MOV     DP, #003cdh
                LB      A, [DP]
                SLLB    A
                MB      off(00220h).4, C
                LB      A, #066h
                JBS     off(00220h).5, threshold_bank_222_6_cmp_ram236
                LB      A, #073h
threshold_bank_222_6_cmp_ram236:     CMPB    A, off(00236h)
                MB      off(00220h).5, C
                LB      A, #09ah
                JBS     off(00220h).6, threshold_bank_222_6_cmp_ram236_2
                LB      A, #0a0h
threshold_bank_222_6_cmp_ram236_2:     CMPB    A, off(00236h)
                MB      off(00220h).6, C
                LB      A, #089h
                JBS     off(00220h).7, threshold_bank_222_6_cmp_ram235
                LB      A, #09ch
threshold_bank_222_6_cmp_ram235:     CMPB    A, off(00235h)
                CLRB    A
                MB      off(00220h).7, C
                JGE     div_scale_store
                CLR     A
                MOV     DP, #003cah
                J       select_dp_3d9_3d6_flag_222_6
select_dp_3d9_3d6_branch:     JGE     div_scale_calc1
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
                J       div_scale_store_ptr_4
div_scale_store_clear_x1:     CLR     X1
                JBS     off(00217h).5, gear_detect_store
                JBS     off(00214h).0, gear_detect_store
                JBR     off(00227h).3, div_scale_store_set_r1
                JBR     off(0022fh).3, div_scale_store_load_ram2d2
                MOVB    off(002d2h), #005h
div_scale_store_load_ram2d2:     LB      A, off(002d2h)
                JNE     gear_detect_store_load_ramc3
div_scale_store_set_r1:     MOVB    r1, 0b4h
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
gear_detect_store_load_ramc3:     LB      A, IAT_raw
                MOV     X1, #DwellBattery
                VCAL    0
                STB     A, off(0024bh)
                VCAL    4
                MOV     X1, #gear_detect_store_interp_tbl_5
                LB      A, 0a4h
                VCAL    2
                STB     A, (0017ch-00180h)[USP]
                MOV     X1, #Overrun_Resume_nor
                MOV     X2, #Overrun_Resume_int
                JBR     off(00216h).3, gear_detect_store_load_ramc1
                MOV     X1, #gear_detect_store_interp_tbl_4
                MOV     X2, #gear_detect_store_interp_tbl_3
gear_detect_store_load_ramc1:     LB      A, coolantTempByte
                VCAL    0
                STB     A, r2
                MOV     X1, X2
                LB      A, coolantTempByte
                VCAL    0
                STB     A, ACCH
                LB      A, r2
                J       gear_detect_store_set_stk
gear_detect_store_ptr_tbl_knockwindow_4:     MOV     X1, #tbl_knockwindow_4
                MOV     X2, #tbl_knockwindow_3
                JBR     off(00216h).3, gear_detect_store_load_ramc1_2
                MOV     X1, #gear_detect_store_interp_tbl_2
                MOV     X2, #gear_detect_store_interp_tbl
gear_detect_store_load_ramc1_2:     LB      A, coolantTempByte
                VCAL    0
                STB     A, r2
                MOV     X1, X2
                LB      A, coolantTempByte
                VCAL    0
                STB     A, ACCH
                LB      A, r2
                J       gear_detect_store_set_stk_2
threshold_bank_223_2:     LB      A, #0a0h
                JBS     off(00223h).2, threshold_bank_223_2_store
                LB      A, #0d8h
threshold_bank_223_2_store:     CMPB    A, off(00236h)
                MB      off(00223h).2, C
                MB      C, (0011ch-00180h)[USP].5
                JLT     threshold_bank_223_2_load_ramc1
                CAL     cam_mode_jump_lookup
                NOP
                MOV     er3, #00177h
                MOV     X1, #000e4h
                MOV     X2, #000dch
                JBS     off(0021fh).1, threshold_bank_223_2_load_ff
                MOV     X1, #00104h
                MOV     X2, #000fah
threshold_bank_223_2_load_ff:     LB      A, #0ffh
                JEQ     threshold_bank_223_2_set_r0
                MOVB    r0, #06fh
                MB      C, off(002ffh).0
                JLT     threshold_bank_223_2_load_r0
threshold_bank_223_2_set_r0:     MOVB    r0, #0ffh
                CMPB    coolantTempByte, #051h
                JLT     threshold_bank_223_2_load_r0
                MOVB    r0, #0e1h
threshold_bank_223_2_load_r0:     LB      A, r0
                CMPB    A, 0a3h
                MB      off(002ffh).6, C
                JLT     threshold_bank_223_2_goto_dualmap
                CMPB    0b9h, #060h
                JLT     multiway_selector_clr_carry
                MB      C, off(002ffh).0
                JLT     multiway_selector_clr_carry
                CMPB    0b4h, #005h
                JGE     threshold_bank_223_2_goto_multiway
                J       threshold_bank_223_2_load_er3
threshold_bank_223_2_goto_multiway:     J       multiway_selector_eval_masked
threshold_bank_223_2_goto_dualmap:     J       dualmap_dispatch_jump
multiway_selector_clr_carry:     RC
                MB      off(002ffh).6, C
                MB      off(002ffh).5, C
                L       A, X1
                MOV     DP, A
                L       A, X2
dualmap_dispatch_jump_and_ie:     AND     IE, #002a0h
                RB      PSWH.0
                ST      A, (00180h-00180h)[USP]
                L       A, DP
                ST      A, (00182h-00180h)[USP]
                SB      PSWH.0
                L       A, 0f2h
                ST      A, IE
                J       threshold_bank_223_2_load_ramc1
                DW  0ffffh
threshold_bank_223_2_load_ramc1:     LB      A, coolantTempByte
                MOV     X1, #threshold_bank_223_2_interp_tbl_8
                CMPCB   A, 00002h[X1]
                MB      off(00219h).5, C
                VCAL    0
                STB     A, (0016dh-00180h)[USP]
                LB      A, coolantTempByte
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
                MOV     X1, #threshold_bank_223_2_interp_tbl_13
                LB      A, 0a4h
                VCAL    2
                STB     A, (00159h-00180h)[USP]
                VCAL    4
                LB      A, coolantTempByte
                STB     A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_4
                VCAL    0
                STB     A, (0015ah-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_5
                VCAL    0
                STB     A, (0015bh-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_6
                VCAL    0
                STB     A, (0015ch-00180h)[USP]
                VCAL    4
                LB      A, coolantTempByte
                J       threshold_bank_223_2_store_r2
threshold_bank_223_2_vcal0:     VCAL    0
                STB     A, (0015dh-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_14
                VCAL    0
                STB     A, (0015eh-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_7
                VCAL    0
                STB     A, (0016fh-00180h)[USP]
                VCAL    4
                LB      A, coolantTempByte
                J       threshold_bank_223_2_store_r2_2
threshold_bank_223_2_vcal0_2:     VCAL    0
                STB     A, (00175h-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_10
                JBS     off(00216h).3, threshold_bank_223_2_vcal0_3
                MOV     X1, #threshold_bank_223_2_interp_tbl_9
threshold_bank_223_2_vcal0_3:     VCAL    0
                STB     A, (00173h-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl_12
                JBS     off(00216h).3, threshold_bank_223_2_vcal0_4
                MOV     X1, #threshold_bank_223_2_interp_tbl_11
threshold_bank_223_2_vcal0_4:     VCAL    0
                STB     A, (00174h-00180h)[USP]
                VCAL    4
                LB      A, coolantTempByte
                J       threshold_bank_223_2_store_r2_3
threshold_bank_223_2_vcal1:     VCAL    1
                STB     A, (001e6h-00180h)[USP]
                LB      A, coolantTempByte
                MOV     X1, #threshold_bank_223_2_data_3
                J       threshold_bank_223_2_vcal1_2
threshold_bank_223_2_vcal4:     VCAL    4
                MOV     X1, #tbl_revlimit_cold1
                CMPB    0b4h, #00fh
                JLT     iat_table_select
                MOV     X1, #tbl_revlimit_cold3
iat_table_select:     LB      A, 0c0h
                VCAL    2
                CMPB    coolantTempByte, A
                MB      off(00219h).2, C
                LB      A, 0c0h
                MOV     X1, #IATFuelCorrect
                VCAL    1
                STB     A, (0014ch-00180h)[USP]
                VCAL    4
                CLR     A
                LB      A, #0aah
                JBS     off(00223h).1, threshold_bank_223_4
                LB      A, #0b0h
threshold_bank_223_4:     CMPB    A, off(00236h)
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
                LC      A, tbl_knock_index[ACC]
                SJ      knock_result_store
knock_retard_check:     ADDB    A, #080h
                STB     A, r2
                L       A, #08000h
knock_result_store:     ST      A, (00150h-00180h)[USP]
                MOVB    off(00241h), r2
                MOV     DP, #003cch
                LB      A, [DP]
                JBS     off(00219h).1, bias_080_scale_table_0547e
                LB      A, 0c7h
bias_080_scale_table_0547e:     ADDB    A, #080h
                STB     A, r0
                LCB     A, idle_init_start_const
                JEQ     to_knock_div_calc3
                LCB     A, tbl_idle_pi_clamp
                SRLB    A
                CLRB    A
                J       bias_080_scale_table_swap_r0
                DB  000h
to_knock_div_calc3:     STB     A, (00137h-00180h)[USP]
                LB      A, r0
                STB     A, (00141h-00180h)[USP]
                CLRB    A
                MOV     DP, #003cbh
                LCB     A, tbl_idle_pi_clamp
                SRLB    A
                SRLB    A
                SRLB    A
                JGE     to_knock_div_calc3_shr_a
                LB      A, [DP]
                ADDB    A, #080h
                CLR     er0
                SJ      to_knock_div_calc3_store_ram2f1
to_knock_div_calc3_shr_a:     SRLB    A
                JGE     knock_clear_284
                LB      A, [DP]
                MOVB    r0, #080h
                MULB
                L       A, ACC
                ADD     A, #0c000h
                ST      A, er0
                CLRB    A
to_knock_div_calc3_store_ram2f1:     STB     A, off(002f1h)
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
                JBR     off(00216h).3, ptr_bump_0024_flag_test
                MOV     X1, #knock_div_calc4_data
ptr_bump_0024_flag_test:     JBS     off(00216h).0, knock_table2d_lookup
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
                LB      A, IAT_raw
                MOV     X1, #InjectorIndex
                J       knock_table2d_lookup_vcal1
knock_table2d_lookup_vcal4:     VCAL    4
                MOV     DP, #003beh
                LB      A, [DP]
                STB     A, ECT_raw
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
closeloopnarrow_result:     CMPB    A, ECT_raw
                JLT     vss_ect_gate
                SB      off(00219h).0
vss_ect_gate:     CMPB    coolantTempByte, #028h
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
                JGE     idle_stage_c0_load_clr_ram219_bit0
                CMP     A, #05e20h
                JLE     idle_stage_c0_load_clr_ram219_bit0
                LB      A, r3
                CMPB    A, ECT_raw
                JLT     idle_stage_b7_load
idle_stage_b7_store:     MOVB    off(002abh), r0
idle_stage_b7_load:     LB      A, off(002abh)
                SJ      idle_stage_c0_load_branch
idle_stage_alt_start:     MOVB    off(002abh), r0
                JBR     off(0021ch).2, idle_stage_c0_start
                MOVB    off(002b5h), r2
                JBR     off(00219h).0, idle_stage_bf_store
                LB      A, r3
                CMPB    A, ECT_raw
                JLT     idle_stage_bf_load
idle_stage_bf_store:     MOVB    off(002b4h), r1
idle_stage_bf_load:     LB      A, off(002b4h)
                SJ      idle_stage_c0_load_branch
idle_stage_c0_start:     MOVB    off(002b4h), r1
                JBR     off(00219h).0, idle_stage_c0_store
                JBR     off(0021ch).6, idle_stage_c0_load
idle_stage_c0_store:     MOVB    off(002b5h), r2
idle_stage_c0_load:     LB      A, off(002b5h)
idle_stage_c0_load_branch:     JNE     gio_fuelpump_dispatch
idle_stage_c0_load_clr_ram219_bit0:     RB      off(00219h).0
                SB      off(00223h).3
gio_fuelpump_dispatch:     VCAL    4
                RC
                LB      A, off(002bch)
                JNE     fuelpump_relay_drive
                JBS     off(00211h).0, fuelpump_relay_drive
                MB      C, off(00217h).4
fuelpump_relay_drive:     MB      P0.7, C
                JBS     off(00210h).7, fuelpump_done
                JBS     off(00218h).5, fuelpump_state_active
                MOV     DP, #003c9h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     fuelpump_gate4
                CMPB    A, #0fch
                JGE     fuelpump_state_clear
fuelpump_gate4:     JBS     off(00230h).6, fuelpump_state_active
fuelpump_state_clear:     LCB     A, idle_init_start_const
                JEQ     flag_dispatch_221_6_217_4
                LB      A, 0e7h
                JNE     fuelpump_state_active
flag_dispatch_221_6_217_4:     JBS     off(00211h).0, fuelpump_state_store
                JBS     off(00217h).4, fuelpump_state_check
fuelpump_state_store:     STB     A, off(002bch)
fuelpump_state_check:     RC
                LB      A, off(002bch)
                JEQ     fuelpump_state_inactive
fuelpump_state_active:     SC
fuelpump_state_inactive:     J       fuelpump_state_branch
fuelpump_done:     CMPB    0e9h, #014h
                JLT     accut_reset_c3
                CMPB    coolantTempByte, #015h
                JGE     rpm_threshold_226_0_if_ram218_bit6_set
                LB      A, #07eh
                JBS     off(00226h).1, rpm_threshold_226_0
                LB      A, #082h
rpm_threshold_226_0:     CMPB    A, 0b4h
                MB      off(00226h).1, C
                JGE     rpm_threshold_226_0_if_ram218_bit6_set
                LB      A, #0c8h
                JBS     off(00226h).0, rpm_threshold_226_0_cmp_ram236
                LB      A, #0d0h
rpm_threshold_226_0_cmp_ram236:     CMPB    A, off(00236h)
                MB      off(00226h).0, C
                JLT     accut_reset_f7
rpm_threshold_226_0_if_ram218_bit6_set:     JBS     off(00218h).6, accut_store_c3_if_ram211_bit2_clr
                LB      A, #033h
                JBS     off(00226h).3, rpm_threshold_226_0_cmp_ramb9
                LB      A, #060h
rpm_threshold_226_0_cmp_ramb9:     CMPB    A, 0b9h
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
                SJ      accut_store_c3_if_ram211_bit2_clr
accut_check_c3:     LB      A, off(002b8h)
                JNE     accut_reset_f7
accut_store_c3_if_ram211_bit2_clr:     JBR     off(00211h).2, accut_common
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
                JBS     off(00212h).5, accut_output_drive_goto_purge_counter
                CMPB    coolantTempByte, #035h
                JGE     purge_result_clear
accut_output_drive_goto_purge_counter:     J       purge_counter_check
                DW  00000h
purge_counter_check_branch:     JLT     purge_result_clear
                CMPB    off(002a7h), #005h
                JNE     purge_result_set
                CMPB    off(002c1h), #019h
                JLT     purge_result_clear
purge_result_set:     SC
                SJ      purge_result_clear_goto_vss_band
purge_result_clear:     RC
purge_result_clear_goto_vss_band:     J       vss_band_dispatch
vss_band_dispatch_set_r2:     MOVB    r2, off(00236h)
                LB      A, #046h
                MOVB    r1, #046h
                JBS     off(00224h).0, vss_band_224_0
                LB      A, #053h
                MOVB    r1, #053h
vss_band_224_0:     JBS     off(00216h).3, vss_band_224_0_check
                LB      A, r1
vss_band_224_0_check:     CMPB    A, r2
                MB      off(00224h).0, C
                MOV     X1, #vss_band_224_0_check_data
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
                MOVB    r2, coolantTempByte
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
                JBS     off(00220h).3, state_ccf_gate_carry_to_p0_bit3
                SC
state_ccf_gate_carry_to_p0_bit3:     MB      P0.3, C
                LB      A, off(002c2h)
                JEQ     state_ccc_check
                JBR     off(00225h).0, state_dispatch4
                SJ      state_2ba_reset
state_ccc_check:     JBR     off(00227h).1, flag_dispatch_216_211
                JBR     off(00211h).4, state_ccc_check_load_ram2c7
                MOVB    off(002c7h), #003h
state_ccc_check_load_ram2c7:     LB      A, off(002c7h)
                JEQ     flag_dispatch_216_211
                JBS     off(00224h).6, flag_dispatch_216_211_load_ram2c8
flag_dispatch_216_211_set_ram2c8:     MOVB    off(002c8h), #003h
flag_dispatch_216_211_load_ram2c8:     LB      A, off(002c8h)
                JEQ     to_state_2ba_reset
                JBR     off(00216h).3, state_ccd_check
                JBS     off(00211h).5, to_state_2ba_reset
state_ccd_check:     LB      A, off(002c3h)
                JNE     state_2ba_reset
                JBS     off(00224h).2, state_225_0_clear
                JBS     off(00225h).0, state_2ba_reset
state_225_0_clear:     RB      off(00225h).0
state_dispatch4:     JBS     off(00224h).3, state_225_1_check
                JBS     off(00224h).1, state_225_1_check
                CMPB    coolantTempByte, #029h
                JGE     state_225_1_check
                CMPB    0c0h, #0a9h
                JGE     state_225_1_check
                JBS     off(00211h).2, state_225_1_check
                LB      A, off(002afh)
                JEQ     state_225_1_check
                RB      off(00225h).1
state_result_set5:     SB      P0.2
                SJ      altc_gio_override_check
flag_dispatch_216_211:     JBR     off(00224h).5, flag_dispatch_216_211_set_ram2c8
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
altc_gio_override_check:     J       altc_gio_override_vcal4
altc_gio_override_if_ram216_bit3_clr:     JBR     off(00216h).3, altc_normal_drive
                MOVB    r0, #0feh
                JBS     off(00225h).7, altc_gio_override_load_ramb9
                MOVB    r0, #0ffh
altc_gio_override_load_ramb9:     LB      A, 0b9h
                CMPB    r0, A
                MB      off(00225h).7, C
                JBR     off(00211h).4, altc_gio_override_set_carry
                JBS     off(00212h).6, altc_normal_drive
                CMPB    A, #0fch
                JGE     altc_normal_drive
                CMPB    A, #005h
                JLT     altc_normal_drive
                JBR     off(00225h).7, altc_normal_drive
altc_gio_override_set_carry:     SC
                SJ      altc_disable_check
altc_normal_drive:     RC
altc_disable_check:     NOP
                NOP
                NOP
altc_disable_check_nop:     NOP
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
                CMPB    coolantTempByte, #0c5h
                JGE     gio_p1_2_check
                CMPB    IAT_raw, #0a7h
                JLT     flags_219_2_store
gio_p1_2_check:     RC
                SB      P1.2
flags_219_2_store:     MB      off(00219h).3, C
                JBR     off(00227h).1, flags_219_2_store_clear_a
                JBS     off(00216h).2, flags_219_2_store_clear_a
                JBS     off(00218h).6, flags_219_2_store_clear_a
                JBS     off(0021fh).0, flags_219_2_store_cmp_ramc0
                LB      A, off(002b1h)
                JNE     flags_219_2_store_clr_carry
flags_219_2_store_clear_a:     CLRB    A
                SC
                SJ      flags_219_2_store_carry_to_p1_bit6
flags_219_2_store_cmp_ramc0:     CMPB    0c0h, #001h
                JGE     flags_219_2_store_clear_a
                CMPB    coolantTempByte, #001h
                JGE     flags_219_2_store_clear_a
                LB      A, #000h
flags_219_2_store_clr_carry:     RC
flags_219_2_store_carry_to_p1_bit6:     MB      P1.6, C
                STB     A, off(002b1h)
                VCAL    4
                JBS     off(0021ah).6, state_21a_7_dispatch
                NOP
                NOP
                NOP
                CMPB    0adh, #012h
                JGE     state_2fb_reset
                LB      A, adc_Ch5_new
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
                SJ      state_224_7_check_load_32
state_224_7_check:     JBR     off(00223h).6, state_224_7_check_load_32
                JBR     off(0021dh).4, state_224_7_check_load_ram2d7
state_224_7_check_load_32:     LB      A, #032h
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
state_21a_7_dispatch2:     JBS     off(0021ah).7, tbl_6baf_search
                J       state_21a_7_dispatch2_if_ram21a_bit6_clr
state_21a_7_dispatch2_load_rambf:     LB      A, adc_Ch5_new
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
                SJ      tbl_6baf_search
state_2df_check:     LB      A, off(002d9h)
                JNE     tbl_6baf_search
                SB      off(0021ah).7
tbl_6baf_search:     MOV     X1, #state_21a_7_dispatch2_interp_tbl
                LB      A, coolantTempByte
                VCAL    1
                STB     A, (00144h-00180h)[USP]
                MOVB    r0, #004h
                MOV     DP, #tbl_map_sign
                LB      A, coolantTempByte
tbl_6baf_loop:     DEC     DP
                DECB    r0
                JEQ     tbl_6baf_done
                CMPCB   A, [DP]
                JGE     tbl_6baf_loop
tbl_6baf_done:     AND     IE, #002a0h
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
                JBR     off(00227h).3, tbl_6baf_done_goto_3
                JBS     off(00216h).3, tbl_6baf_done_goto
                RB      off(0022eh).4
                MB      C, off(00211h).5
                MB      off(0022eh).4, C
                JEQ     tbl_6baf_done_carry_to_ram22f_bit3
                XORB    PSWH, #080h
tbl_6baf_done_carry_to_ram22f_bit3:     MB      off(0022fh).3, C
                LB      A, off(002bch)
                JNE     tbl_6baf_done_goto_2
                JBR     off(00218h).5, tbl_6baf_done_ptr_dat_engine_calc_main
tbl_6baf_done_goto:     J       tbl_6baf_done_set_carry
tbl_6baf_done_goto_2:     J       tbl_6baf_done_clr_carry
tbl_6baf_done_goto_3:     J       tbl_6baf_done_vcal4
tbl_6baf_done_ptr_dat_engine_calc_main:     MOV     X1, #tbl_6baf_done_data
                MOV     DP, #0022dh
                SB      PSWL.4
                MOV     er0, #00400h
                MOVB    r2, TPS_pct
                CAL     timer_or_counter_helper
                RB      PSWL.4
                MOVB    r1, #001h
                J       tbl_6baf_done_set_r2
tbl_6baf_done_call_timer_or_counter_h:     CAL     timer_or_counter_helper
                MOVB    r1, #002h
                MOVB    r2, off(00236h)
                CAL     timer_or_counter_helper
                MOV     DP, #0022eh
                MOV     er0, #00300h
                MOVB    r2, 0b4h
                CAL     timer_or_counter_helper
                CMPB    0b4h, #0ffh
                JLT     tbl_6baf_done_ptr_3a7
                CMPB    off(00236h), #0ffh
                JLT     tbl_6baf_done_ptr_3a7
                MOV     DP, #003a4h
                JBS     off(0022fh).3, tbl_6baf_done_clear_ind
                LB      A, off(0024fh)
                INC     DP
                XCHGB   A, [DP]
                CMPB    A, [DP]
                JEQ     tbl_6baf_done_ptr_3a7
                DEC     DP
                LB      A, #0ffh
                INCB    [DP]
                CMPB    A, [DP]
                JGE     tbl_6baf_done_ptr_3a7
                STB     A, [DP]
                SJ      tbl_6baf_done_carry_to_ram22e_bit3
tbl_6baf_done_clear_ind:     CLRB    [DP]
tbl_6baf_done_carry_to_ram22e_bit3:     MB      off(0022eh).3, C
tbl_6baf_done_ptr_3a7:     MOV     DP, #003a7h
                LB      A, [DP]
                CMPB    A, #0ffh
                MB      off(0022eh).5, C
                JGE     tbl_6baf_done_load_ff
                JBS     off(0022eh).6, tbl_6baf_done_carry_to_ram22e_bit7
tbl_6baf_done_load_ff:     LB      A, #0ffh
                CMPB    A, TPS_pct
                MB      off(0022eh).6, C
                JLT     tbl_6baf_done_load_ram24f
tbl_6baf_done_carry_to_ram22e_bit7:     MB      off(0022eh).7, C
tbl_6baf_done_load_ram24f:     LB      A, off(0024fh)
                STB     A, r0
                JBS     off(0022dh).1, tbl_6baf_done_load_ram2c9
                MOVB    off(002c9h), #0ffh
tbl_6baf_done_load_ram2c9:     LB      A, off(002c9h)
                JNE     tbl_6baf_done_if_ram22f_bit1_set_2
                JBS     off(0022fh).2, tbl_6baf_done_if_ram22f_bit1_set
                CMPB    r0, #003h
                JNE     tbl_6baf_done_if_ram22f_bit1_set
                SB      off(0022fh).2
tbl_6baf_done_if_ram22f_bit1_set:     JBS     off(0022fh).1, tbl_6baf_done_if_ram22f_bit0_set
                CMPB    r0, #002h
                JNE     tbl_6baf_done_if_ram22f_bit2_clr
                SB      off(0022fh).1
                SJ      tbl_6baf_done_if_ram22f_bit0_set
tbl_6baf_done_if_ram22f_bit1_set_2:     JBS     off(0022fh).1, tbl_6baf_done_if_ram22f_bit0_set
tbl_6baf_done_if_ram22f_bit2_clr:     JBR     off(0022fh).2, tbl_6baf_done_and_ram22f
tbl_6baf_done_if_ram22f_bit0_set:     JBS     off(0022fh).0, tbl_6baf_done_cmp_r0
                CMPB    r0, #003h
                JLT     tbl_6baf_done_set_ram2ca
                LB      A, off(002cah)
                JNE     tbl_6baf_done_set_ram2cb
                SB      off(0022fh).0
                SJ      tbl_6baf_done_cmp_r0
tbl_6baf_done_set_ram2ca:     MOVB    off(002cah), #0ffh
                SJ      tbl_6baf_done_set_ram2cb
tbl_6baf_done_cmp_r0:     CMPB    r0, #002h
                JNE     tbl_6baf_done_set_ram2cb
                LB      A, off(002cbh)
                JEQ     tbl_6baf_done_and_ram22f
                SJ      tbl_6baf_done_if_ram22e_bit0_set
tbl_6baf_done_set_ram2cb:     MOVB    off(002cbh), #0ffh
tbl_6baf_done_if_ram22e_bit0_set:     JBS     off(0022eh).0, tbl_6baf_done_clear_x1
tbl_6baf_done_and_ram22f:     ANDB    off(0022fh), #0f8h
tbl_6baf_done_clear_x1:     CLR     X1
                CMPB    coolantTempByte, #0ffh
                JLT     tbl_6baf_done_ptr_4
                CMPB    0c0h, #0ffh
                JGE     tbl_6baf_done_load_r0
                JBR     off(0022dh).0, tbl_6baf_done_load_ram2cc
                MOVB    off(002cch), #0ffh
tbl_6baf_done_load_ram2cc:     LB      A, off(002cch)
                MOV     X1, #00004h
                JNE     tbl_6baf_done_load_r0
                SLL     X1
                JBR     off(00216h).0, tbl_6baf_done_load_r0
                JBS     off(00225h).6, tbl_6baf_done_load_r0
                MOV     X1, #0000ch
                SJ      tbl_6baf_done_load_r0
tbl_6baf_done_ptr_4:     MOV     X1, #00004h
                LB      A, #0ffh
                JBR     off(00225h).6, tbl_6baf_done_if_ram22e_bit7_set
                JBS     off(0022fh).4, tbl_6baf_done_if_ram22e_bit7_set
                JBR     off(0022eh).2, tbl_6baf_done_if_ram22e_bit7_clr
                JBS     off(0022fh).5, tbl_6baf_done_if_ram22e_bit7_clr
                SB      off(0022fh).5
                JBS     off(0022dh).0, tbl_6baf_done_if_ram22e_bit7_clr
                SB      off(0022fh).4
tbl_6baf_done_if_ram22e_bit7_clr:     JBR     off(0022eh).7, tbl_6baf_done_load_r0
                JBR     off(0022dh).2, tbl_6baf_done_load_ram2cc_2
                STB     A, off(002cch)
tbl_6baf_done_load_ram2cc_2:     LB      A, off(002cch)
                JNE     tbl_6baf_done_load_r0
                MOV     X1, #00010h
                SJ      tbl_6baf_done_load_r0
tbl_6baf_done_if_ram22e_bit7_set:     JBS     off(0022eh).7, tbl_6baf_done_if_ram22d_bit2_clr
                JBR     off(00216h).0, tbl_6baf_done_load_r0
                MOV     X1, #00018h
                JBR     off(0022dh).2, tbl_6baf_done_load_ram2cc_3
                STB     A, off(002cch)
tbl_6baf_done_load_ram2cc_3:     LB      A, off(002cch)
                JEQ     tbl_6baf_done_load_r0
tbl_6baf_done_ptr_14:     MOV     X1, #00014h
                SJ      tbl_6baf_done_load_r0
tbl_6baf_done_if_ram22d_bit2_clr:     JBR     off(0022dh).2, tbl_6baf_done_load_ram2cc_4
                STB     A, off(002cch)
tbl_6baf_done_load_ram2cc_4:     LB      A, off(002cch)
                JEQ     tbl_6baf_done_ptr_1c
                JBS     off(00216h).0, tbl_6baf_done_ptr_14
                SJ      tbl_6baf_done_load_r0
tbl_6baf_done_ptr_1c:     MOV     X1, #0001ch
                JBS     off(00216h).0, tbl_6baf_done_load_r0
                MOV     X1, #00022h
tbl_6baf_done_load_r0:     LB      A, r0
                JEQ     tbl_6baf_done_sign_extend
                CMPB    A, #005h
                JEQ     tbl_6baf_done_set_ram2cd
                SUBB    A, #001h
tbl_6baf_done_sign_extend:     EXTND
                ADD     A, X1
                CMP     X1, #0001ch
                JLT     tbl_6baf_done_ptr_3a8
                CMPB    r0, #003h
                JLT     tbl_6baf_done_ptr_3a8
                JNE     tbl_6baf_done_if_ram22f_bit2_clr_2
                JBR     off(0022fh).1, tbl_6baf_done_ptr_3a8
                SJ      tbl_6baf_done_add_2
tbl_6baf_done_if_ram22f_bit2_clr_2:     JBR     off(0022fh).2, tbl_6baf_done_ptr_3a8
tbl_6baf_done_add_2:     ADD     A, #00002h
tbl_6baf_done_ptr_3a8:     MOV     DP, #003a8h
                MOVB    [DP], A
                ADD     A, #tbl_6baf_done_data_2
                MOV     DP, A
                CLRB    A
                LCB     A, [DP]
                MOV     DP, #003a9h
                STB     A, [DP]
                SJ      tbl_6baf_done_set_r1
tbl_6baf_done_set_ram2cd:     MOVB    off(002cdh), #0ffh
tbl_6baf_done_set_r1:     MOVB    r1, #0ffh
                JBR     off(0022eh).1, tbl_6baf_done_and_ram22f_2
                LB      A, off(002cdh)
                JNE     tbl_6baf_done_goto_4
                SJ      tbl_6baf_done_ptr_3a9
tbl_6baf_done_and_ram22f_2:     ANDB    off(0022fh), #0cfh
tbl_6baf_done_goto_4:     SJ      tbl_6baf_done_set_carry
tbl_6baf_done_ptr_3a9:     MOV     DP, #003a9h
                LB      A, [DP]
                JBR     off(0022fh).6, tbl_6baf_done_cmp_ramb4
                J       tbl_6baf_done_sub_ff
                DB  000h
tbl_6baf_done_cmp_ramb4:     CMPB    A, 0b4h
                MB      off(0022fh).6, C
                JGE     tbl_6baf_done_if_ram22d_bit7_set
                JBS     off(0022dh).4, tbl_6baf_done_load_ram2ce
                MOVB    off(002ceh), #0ffh
tbl_6baf_done_load_ram2ce:     LB      A, off(002ceh)
                JNE     tbl_6baf_done_if_ram22d_bit7_set
                JBS     off(0022eh).3, tbl_6baf_done_if_ram22d_bit3_set
                JBR     off(00211h).5, tbl_6baf_done_load_ram2cf
                MOVB    off(002cfh), #0ffh
tbl_6baf_done_load_ram2cf:     LB      A, off(002cfh)
                JNE     tbl_6baf_done_set_carry
tbl_6baf_done_if_ram22d_bit3_set:     JBS     off(0022dh).3, tbl_6baf_done_load_ram2d0
                MOVB    off(002d0h), #0ffh
                MOVB    off(002d1h), r1
                SJ      tbl_6baf_done_if_ram22d_bit5_clr
tbl_6baf_done_load_ram2d0:     LB      A, off(002d0h)
                JEQ     tbl_6baf_done_if_ram22d_bit5_clr
                JBR     off(0022eh).5, tbl_6baf_done_load_ram2d1
                MOVB    off(002d1h), r1
tbl_6baf_done_load_ram2d1:     LB      A, off(002d1h)
                JNE     tbl_6baf_done_if_ram22d_bit7_set
                JBR     off(0022dh).6, tbl_6baf_done_set_carry
tbl_6baf_done_if_ram22d_bit5_clr:     JBR     off(0022dh).5, tbl_6baf_done_load_ram2d3
                MOVB    off(002d3h), #0ffh
tbl_6baf_done_load_ram2d3:     LB      A, off(002d3h)
                JNE     tbl_6baf_done_if_ram22d_bit7_set
                JBS     off(00211h).4, tbl_6baf_done_set_carry
tbl_6baf_done_clr_carry:     RC
                SJ      tbl_6baf_done_nop
tbl_6baf_done_if_ram22d_bit7_set:     JBS     off(0022dh).7, tbl_6baf_done_clr_carry
tbl_6baf_done_set_carry:     SC
tbl_6baf_done_nop:     NOP
                NOP
                NOP
tbl_6baf_done_vcal4:     VCAL    4
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
                JGE     knock_324_bit_check
knock_244_recheck:     SC
                JBS     off(00230h).6, knock_324_bit_store
knock_324_bit_check:     MB      C, off(00214h).7
knock_324_bit_store:     J       knock_324_bit_store_ptr_320
                DW  00000h
knock_324_bit_store_load_adcr6:     L       A, ADCR6
                ST      A, adc_Ch6_word
                LB      A, 0b9h
                MOV     DP, #00392h
                STB     A, [DP]
                LB      A, ADCR2H
                MOV     DP, #00393h
                STB     A, [DP]
                NOP
                CLRB    A
                J       knock_324_bit_store_test_ram211_bit1
knock_324_bit_store_rol_a:     ROLB    A
                MB      C, off(00211h).7
                ROLB    A
                MB      C, off(00211h).6
                ROLB    A
                MB      C, off(00211h).5
                ROLB    A
                MB      C, off(00211h).4
                ROLB    A
                J       knock_324_bit_store_test_ram210_bit3
knock_324_bit_store_rol_a_2:     ROLB    A
                MB      C, off(00211h).2
                ROLB    A
                MB      C, off(00211h).0
                ROLB    A
                JBS     off(00216h).3, knock_324_bit_store_ptr_39c
                ANDB    A, #08fh
knock_324_bit_store_ptr_39c:     MOV     DP, #0039ch
                STB     A, [DP]
                CLRB    A
                J       knock_324_bit_store_test_p4_bit6
knock_324_bit_store_rol_a_3:     ROLB    A
                ROLB    A
                ROLB    A
                MB      C, off(00210h).7
                ROLB    A
                ROLB    A
                JBR     off(00227h).3, knock_324_bit_store_rol_a_4
                MB      C, off(00211h).5
knock_324_bit_store_rol_a_4:     ROLB    A
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
                J       knock_324_bit_store_test_p0_bit1
knock_324_bit_store_rol_a_5:     ROLB    A
                MB      C, P0.0
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.7
                XORB    PSWH, #080h
                ROLB    A
                MOV     DP, #0039fh
                STB     A, [DP]
                CLRB    A
                J       knock_324_bit_store_test_p0_bit5
                DB  000h
knock_324_bit_store_nop:     NOP
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
                J       knock_324_bit_store_test_p0_bit2
knock_324_bit_store_rol_a_6:     ROLB    A
                MOV     DP, #003a0h
                STB     A, [DP]
                CLRB    A
                J       knock_324_bit_store_test_p0_bit5_2
                DB  000h
knock_324_bit_store_store_ind:     STB     A, [DP]
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
                LCB     A, diag_snapshot_copy_const
                JNE     diag_mode_code_store
                LCB     A, CFG_flag_216_2_and_5
                JEQ     diag_snapshot_copy_set_r0
                LCB     A, CFG_flag_219_4
                JEQ     diag_snapshot_copy_set_r0
                JBS     off(00216h).0, diag_mode_code_store
diag_snapshot_copy_set_r0:     MOVB    r0, #001h
                JBS     off(00216h).2, diag_mode_code_store
                MOVB    r0, #002h
                LCB     A, CFG_flag_216_2_and_5
                JEQ     diag_mode_code_store
                LCB     A, CFG_flag_219_4
                JEQ     diag_snapshot_copy_set_r0_2
                JBR     off(00216h).0, diag_mode_code_store
diag_snapshot_copy_set_r0_2:     MOVB    r0, #008h
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
diag_mode_code_store_rol_r0:     ROLB    r0
                MB      C, off(00216h).5
                ROLB    r0
                MB      C, off(00227h).4
                ROLB    r0
                MB      C, off(00217h).6
                ROLB    r0
                J       diag_mode_code_store_clr_carry
diag_mode_code_store_shl_a:     SLLB    A
                SLLB    A
diag_mode_code_store_rol_r0_2:     ROLB    r0
                MB      C, off(00216h).3
                ROLB    r0
                MOV     DP, #00398h
                LB      A, r0
                STB     A, [DP]
                NOP
                J       diag_mode_code_store_rom_load_CFG_flag
diag_mode_code_store_branch:     JLT     diag_clamp_ff
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
                SJ      diag_store_3ae
diag_clamp_acch2:     LB      A, ACCH
diag_store_3ae:     J       diag_store_3ae_ptr_39a
                DB  000h
diag_store_39f_ptr_39b:     MOV     DP, #0039bh
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
                LCB     A, tbl_dtc_code_map[ACC]
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
                JLT     dtc_debounce_loop_load_ind
                CLR     A
                LB      A, r7
                CMPB    A, 0eah
                JNE     dtc_debounce_advance
                LCB     A, tbl_dtc_code_map[ACC]
                SUBB    A, [DP]
                JNE     dtc_debounce_advance
                STB     A, 0eah
                SJ      dtc_debounce_advance
dtc_debounce_loop_load_ind:     LB      A, [DP]
                JNE     dtc_debounce_loop_dec_ind
                RC
                SJ      dtc_debounce2_init
dtc_debounce_loop_dec_ind:     DECB    [DP]
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
                JNE     dtc_debounce2_check_nop
                STB     A, 0eah
                SJ      dtc_debounce2_check_nop
dtc_debounce2_check:     L       A, [DP]
                JNE     dtc_debounce2_check_nop
dtc_debounce2_init:     LB      A, #005h
                STB     A, [DP]
                LB      A, 0eah
                JNE     dtc_active_confirm
                LB      A, r7
                STB     A, 0eah
                SJ      dtc_debounce2_check_nop
dtc_active_confirm:     SUBB    A, r7
                JNE     dtc_debounce2_check_nop
                AND     IE, #00080h
                STB     A, 0eah
                CLR     A
                LB      A, r7
                CMPB    A, #030h
                JNE     cfgvariant_index_lookup2
                MOV     (001b4h-00180h)[USP], #00bb3h
                JBR     off(00216h).2, cfgvariant_index_lookup2
                SB      0a0h.0
                SJ      dtc_scan_ie_restore
cfgvariant_index_lookup2:     LCB     A, tbl_cfgvariant_map[ACC]
                JEQ     dtc_scan_ie_restore
                STB     A, r6
                SB      off(00230h).0
                SB      off(00230h).1
                J       cfgvariant_index_call_cfgvariant_set_fla
                DB  000h
cfgvariant_index_branch:     JEQ     cfgvariant_apply_done
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
                LCB     A, tbl_cfgvariant_map[ACC]
                CMPB    A, r6
                JNE     selftest_fail_043_checksum
dtc_scan_ie_restore:     L       A, 0f2h
                ST      A, IE
dtc_debounce2_check_nop:     NOP
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
                J       calchecksum_loop_vcal4
calchecksum_loop_inc_dp:     INC     DP
                L       A, [DP]
                CMP     A, er0
                JEQ     freezeframe_decode_start
selftest_fail_043_checksum:     MOVB    0ebh, #043h
                BRK
freezeframe_decode_start:     VCAL    4
                J       freezeframe_decode_load_ram212
freezeframe_decode_add_ffff:     ADD     A, #0ffffh
                MB      off(00218h).6, C
                L       A, off(00212h)
                AND     A, #0fffdh
                JNE     freezeframe_flag_22b_4
                L       A, off(00214h)
                AND     A, #014f5h
                JEQ     prep_lowpower_seq
freezeframe_flag_22b_4:     SB      off(00218h).5
prep_lowpower_seq:     SB      off(00230h).3
; [H] a standby/low-power preparation sequence (watchdog reset, TMR1 reload/divide, port_debounce_
; [H] helper, then reconfigures IE/0xF8/0xFA -- structurally similar to int_NMI's low-power entry
; [H] sequence from very early this session), then lowpower_trap_gate's JBR always falls through
; [H] (target lowpower_trap_call is the very next instruction) into lowpower_trap_call
; [H] (J lowpower_abort_cond_scan) -- the unconditional jump into the restored low-power-entry
; [H] veto/validation gate (see its header comment for what it does).
                JNE     lowpower_trap_call
                CAL     ResetWatchDog
                L       A, TM1
                ADD     A, #00a00h
                J       prep_lowpower_seq_store_tmr1
                DB  000h
prep_lowpower_seq_test_ram9f_bit1:     MB      C, 09fh.1
                JLT     prep_lowpower_ie_config
                CAL     port_debounce_helper
                MOVB    0edh, #020h
prep_lowpower_ie_config:     MOV     0f4h, #002a0h
                L       A, #02bafh
                ST      A, 0f2h
                CLRB    TRNSIT
                CLR     IRQ
                RB      TCON0.2
                ST      A, IE
lowpower_trap_call:     J       regbank_selftest2_start

;--------------------------------------------------------------------------------------------
; crank_helper2  @0x4B32
;   VERIFIED: entry point that first checks off(120h).2; if set, skips straight to the
;   shared clamp body (injector_timer_schedule). If clear, also bails immediately when
;   off(1BFh)==0x0Fh (an apparent "not yet valid" sentinel).
;--------------------------------------------------------------------------------------------
crank_helper2:     JBR     off(00120h).2, injtimer_shift_path

;--------------------------------------------------------------------------------------------
; injector_timer_schedule  @0x4B35
;   VERIFIED: clamps a 3-word array based at RAM 0x1C0 to a ceiling of 0xC0 (192), one
;   word at a time. Direct-entry form of crank_helper2.
;--------------------------------------------------------------------------------------------
injector_timer_schedule:     MOVB    r0, #0ffh
                L       A, off(001c6h)
                ST      A, er1
                CMPB    off(001bfh), #00fh
                JNE     injtimer_schedule_done
                J       injector_timer_load_tm0
injector_timer_ptr_1c0:     MOV     DP, #001c0h
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

;--------------------------------------------------------------------------------------------
; injtimer_bank2_zero  @0x4B76
;   TRACED: substantial routine (~0x150 bytes, 30+ internal branches) directly
;   manipulating TMR0 (ADD TMR0,A - the hardware injector/ignition timer register) using
;   values staged in RAM 0x1B6-0x1BC, decoded through four digital input bits at
;   off(109h).0-3. Calls inj_wrap_clamp_calc twice internally. RAM 0x1B6-0x1BC sits
;   immediately before the 0x1C0 array that injector_timer_schedule/_gated operate on,
;   confirming this is the parent context for that pair - together they form the core
;   injector pulse-width timer-bank assembly.
;--------------------------------------------------------------------------------------------
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
                JBS     off(00109h).2, inj_accum_check2_branch
                JBS     off(00109h).3, inj_accum_check2_branch
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
                JBR     off(00109h).2, inj_accum_check1_branch
                JBR     off(00109h).3, inj_accum_check4
inj_accum_check2_branch:     JLT     inj_accum_check2_cmp_100
                ADD     TMR0, A
                SJ      inj_accum_check2_clear_a
inj_accum_check2_cmp_100:     CMP     A, #00100h
                JGE     inj_accum1_store_new
inj_accum_check2_clear_a:     CLR     A
inj_accum1_store_new:     ST      A, off(001b8h)
                L       A, #00001h
                ST      A, off(001bah)
                SJ      inj_accum_store_114
inj_accum_check1_if_ram109_bit2_clr:     JBR     off(00109h).2, inj_accum_check1_branch
                JBS     off(00109h).3, inj_accum_check4
inj_accum_check1_branch:     JGE     inj_accum_direct_add
                SUB     A, off(001b8h)
                JLT     inj_accum1_add
                SUB     A, off(001bah)
                JLT     inj_accum2_zero
                CMP     A, #00100h
                JGE     inj_accum_store_114
                CLR     A
                SJ      inj_accum_store_114
inj_accum_direct_add:     ADD     TMR0, A
                CLR     A
                ST      A, off(001b8h)
                ST      A, off(001bah)
                SJ      inj_accum_store_114
inj_accum1_add:     J       inj_accum1_add_add_ram1b8
                DB  000h,000h,000h,000h,000h
inj_accum2_zero:     J       inj_accum2_zero_add_ram1ba
                DB  000h,000h,000h
inj_accum_check2:     JBS     off(00109h).2, inj_accum_check2_branch
                JBR     off(00109h).3, inj_accum_check1_branch
inj_accum_check4:     JGE     inj_accum_check4_add_tmr0
                SUB     A, off(001b8h)
                JGE     inj_accum_check4_cmp_100
                J       inj_accum_check4_add_ram1b8
                DW  00000h
inj_accum_check4_add_tmr0:     ADD     TMR0, A
                CLR     A
                ST      A, off(001b8h)
                SJ      inj_accum2_store2
inj_accum_check4_cmp_100:     CMP     A, #00100h
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

;--------------------------------------------------------------------------------------------
; inj_p2_default_f  @0x4CBC
;   TRACED: alternate entry that presets A=0x0F then jumps back into inj_wrap_clamp_calc's
;   body (0x4CC0, immediately following) with a different starting value.
;--------------------------------------------------------------------------------------------
inj_p2_default_f:     LB      A, #00fh
                SJ      inj_p2_drive_return

;--------------------------------------------------------------------------------------------
; inj_wrap_clamp_calc  @0x4CC0
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; knock_helper1  @0x4CD7
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
knock_helper1:     MOVB    r6, #077h
                JEQ     bitreverse_return
bitreverse_loop:     MB      C, r6.7
                ROLB    r6
                SUBB    A, #001h
                JNE     bitreverse_loop
bitreverse_return:     LB      A, r6
                RT

;--------------------------------------------------------------------------------------------
; tm0_resync_helper  @0x4CE5
;   VERIFIED: snapshots TMR2 into er3, tests off(10Fh).7/IRQH.0, conditionally increments
;   an event counter at RAM 0xDE, then divides the captured pair by a fixed divisor of 6.
;   Called 3x around the TMR0 crank-edge adjustment code at 0x0601-0x061B.
;--------------------------------------------------------------------------------------------
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
                JLT     crank_a3_gate_ptr_35a
                CMPB    A, #013h
                JLE     crank_a3_gate_ptr_356
crank_a3_gate_ptr_35a:     MOV     DP, #0035ah
                MB      C, 0a0h.3
                J       crank_pswl4_store
crank_mul_alt:     MULB
crank_mul_alt_mul:     MULB
                SJ      crank_a2_advance
crank_dp_35e:     MOV     DP, #0035eh
                MB      C, 0a0h.4
                SJ      crank_pswl4_store
crank_a3_gate_ptr_356:     MOV     DP, #00356h
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
                J       crank_pswl4_store_cmp_r0
crank_pswl4_store_if_ram117_bit0_clr:     JBR     off(00117h).0, crank_mul_alt_mul
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
                JGE     crank_mul_common2_clr_tcon3_bit2
                L       A, TMR2
                ADD     A, er1
                SJ      tmr3_reload_store2
crank_mul_alt2:     MUL
                RB      r0.0
                L       A, ACC
                SJ      tmr3_reload_clamp_min
crank_mul_common2_clr_tcon3_bit2:     RB      TCON3.2
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

;--------------------------------------------------------------------------------------------
; ign_angle_to_timer_convert  @0x4E2F
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
ign_angle_to_timer_convert:     CLRB    A
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

;--------------------------------------------------------------------------------------------
; table_interp_lookup_prescan  @0x4E4E
;   VERIFIED: performs the identical 2-point bracket compare as table_interp_lookup
;   (CMPCB/JGE/LCB sequence matches byte-for-byte) and falls through into vcal_0's own
;   body via SJ at 0x4E6A. A fast-path variant/prefix of the validated
;   table_interp_lookup, not a different algorithm.
;--------------------------------------------------------------------------------------------
table_interp_lookup_prescan:     CMPCB   A, [X1]
                JLT     knockretard_r1_store
                LCB     A, [X1]
knockretard_r1_store:     CMPCB   A, 00002h[X1]
                JGE     knockretard_sub_result
                LCB     A, 00002h[X1]
knockretard_sub_result:     MOVB    r0, A
                SJ      table_interp_delta_calc

;--------------------------------------------------------------------------------------------
; table_interp_lookup  @0x4E62
;   VERIFIED byte-identical to HTS115. Reached via VCAL 0, 64 sites.
;--------------------------------------------------------------------------------------------
table_interp_lookup:         CMPCB   A, 00002h[X1]
; [H] --- Generic 1D linear-interpolation table lookup, used 50 times throughout the file (flex
; [H] fuel, boost/wastegate control, GIO trims, ignition/O2 corrections, etc). Given a table
; [H] pointer in X1 (entries are (X,Y) byte pairs) and an input value in A, walks the table to
; [H] find the bracketing X segment, then linearly interpolates the corresponding Y. This is the
; [H] same routine flex-fuel notes describe as "the shared interpolation helper".
                JGE     table_interp_bracket_found
                INC     X1
                INC     X1
                SJ      table_interp_lookup
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
                JGE     table_interp_delta_mul
                STB     A, r7
                CLRB    A
                SUBB    A, r7
table_interp_delta_mul:     MULB
                MOVB    r0, r1
                DIVB
                RB      PSWL.4
                JEQ     table_interp_delta_add_r6
                SUBB    r6, A
                LB      A, r6
                RT
table_interp_delta_add_r6:     ADDB    A, r6
                STB     A, r6
                RT

;--------------------------------------------------------------------------------------------
; table_interp_clamp_stride2  @0x4E9C
;   TRACED: clamps A between table[0] (floor) and table[2] (ceiling) for a 2-byte-stride
;   table, then resumes the shared interpolation loop at table_interp_lookup's midpoint.
;   Reached via VCAL 2.
;--------------------------------------------------------------------------------------------
table_interp_clamp_stride2:         CMPCB   A, [X1]
                JLT     vcal1_bracket_check
                LCB     A, [X1]
vcal1_bracket_check:     CMPCB   A, 00002h[X1]
                JGE     vcal1_bracket_check_goto_table_interp
                LCB     A, 00002h[X1]
vcal1_bracket_check_goto_table_interp:     SJ      table_interp_bracket_found

;--------------------------------------------------------------------------------------------
; table_interp_clamp_stride3  @0x4EAE
;   TRACED: identical role to table_interp_clamp_stride2 but clamps against
;   table[0]/table[3] for a 3-byte-stride table, then falls into
;   table_interp_search_stride3's completion code. Reached via VCAL 3.
;--------------------------------------------------------------------------------------------
table_interp_clamp_stride3:         CMPCB   A, [X1]
                JLT     vcal2_bracket_check
                LCB     A, [X1]
vcal2_bracket_check:     CMPCB   A, 00003h[X1]
                JGE     vcal2_bracket_check_goto_vcal_common
                LCB     A, 00003h[X1]
vcal2_bracket_check_goto_vcal_common:     SJ      vcal_common_interp

;--------------------------------------------------------------------------------------------
; table_interp_search_stride3  @0x4EC0
;   TRACED: same bracket-search loop as table_interp_lookup but for 3-byte-wide table rows
;   instead of 2. Reached via VCAL 1.
;--------------------------------------------------------------------------------------------
table_interp_search_stride3:         CMPCB   A, 00003h[X1]
                JGE     vcal_common_interp
                INC     X1
                INC     X1
                INC     X1
                SJ      table_interp_search_stride3
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

;--------------------------------------------------------------------------------------------
; injtimer_bank_calc3  @0x4EE5
;   88% HTS115 match.
;--------------------------------------------------------------------------------------------
injtimer_bank_calc3:     SUB     A, er3
                MB      PSWL.4, C
                JGE     injtimer_bank_calc3_mul
                ST      A, er1
                CLR     A
                SUB     A, er1
injtimer_bank_calc3_mul:     MUL
                MOV     er0, er1
                DIV
                RB      PSWL.4
                JEQ     injtimer_bank_calc3_add_er3
                SUB     er3, A
                L       A, er3
                RT
injtimer_bank_calc3_add_er3:     ADD     A, er3
                ST      A, er3
                RT

;--------------------------------------------------------------------------------------------
; table_interp_lookup_4byte  @0x4EFE
;   Called 6x; used at 0x0BA6 after a 0x6A79/0x6A89 table select.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; subtract24_clamp_byte  @0x4F21
;   VERIFIED: computes A-24, clamps the result to the unsigned byte range - 0 if the
;   subtraction went negative, 0xFF if it overflowed 255.
;--------------------------------------------------------------------------------------------
subtract24_clamp_byte:     SUBB    A, #018h
                JGE     subtract24_clamp_byte_test_acch_bit7
                CLRB    A
                RT
subtract24_clamp_byte_test_acch_bit7:     MB      C, ACCH.7
                ROLB    A
                JGE     subtract24_clamp_byte_return
                LB      A, #0ffh
subtract24_clamp_byte_return:     RT

;--------------------------------------------------------------------------------------------
; mul_scale_helper2  @0x4F30
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; rpm_accel_track_helper  @0x4F3E
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; injtimer_bank_calc1  @0x4F51
;   VERIFIED: subtracts a table breakpoint (00000h[X1]) from A, takes the absolute value
;   via VCAL 7 if negative, multiplies by er0. One step of a linear interpolation.
;   HTS115's low-confidence (65%) guess for similar code was "injtimer_bank_calc1" -
;   plausible caller domain, not confirmed, so left out of the name.
;--------------------------------------------------------------------------------------------
injtimer_bank_calc1:     MOV     er2, 00000h[X1]
                SUB     A, er2
                JGE     injtimer_bank_calc1_mul
                VCAL    7
                SC
injtimer_bank_calc1_mul:     MUL
                ST      A, er0
                L       A, 00002h[X1]
                SJ      injtimer_bank_calc1_sign

;--------------------------------------------------------------------------------------------
; interp_bracket_delta_scale_2  @0x4F62
;   VERIFIED: structurally identical to injtimer_bank_calc1, operating on the
;   upper breakpoint instead of the lower.
;--------------------------------------------------------------------------------------------
interp_bracket_delta_scale_2:     MOV     er2, 00000h[X1]
                SUB     A, er2
                JGE     interp_bracket_delta_mul
                VCAL    7
                SC
interp_bracket_delta_mul:     MUL
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

;--------------------------------------------------------------------------------------------
; signed_add_sat16_dispatch  @0x4F7F
;   TRACED: tests the sign of A (MB C,ACCH.7) and falls straight into signed_add_sat16
;   with the branch already resolved. Reached via VCAL 5.
;--------------------------------------------------------------------------------------------
signed_add_sat16_dispatch:         MB      C, ACCH.7
                JLT     signed_add_sat16_add_er3

;--------------------------------------------------------------------------------------------
; signed_add_sat16  @0x4F84
;   TRACED: adds er3 to A with saturation - clamps to 0xFFFF on positive overflow, to 0 on
;   negative underflow. The body signed_add_sat16_dispatch falls into. Reached via VCAL 6.
;--------------------------------------------------------------------------------------------
signed_add_sat16:         ADD     A, er3
                JGE     vcal4_store
                L       A, #0ffffh
                SJ      vcal4_store
signed_add_sat16_add_er3:     ADD     A, er3
                JLT     vcal4_store
                CLR     A
vcal4_store:     ST      A, er3
                RT
                DB  0E2h

;--------------------------------------------------------------------------------------------
; add_saturate_s16  @0x4F93
;   VERIFIED: adds er3 to A with explicit signed 16-bit saturation - clamps to 0x7FFF on
;   positive overflow, 0x8000 on negative overflow, checking ACCH.7 and r7.7 sign bits
;   before and after the add.
;--------------------------------------------------------------------------------------------
add_saturate_s16:     MB      C, ACCH.7
                JLT     add_saturate_s16_test_r7_bit7
                MB      C, r7.7
                JLT     signext_common_add
                ADD     A, er3
                MB      C, ACCH.7
                JGE     signext_common_add_store_er3
                L       A, #07fffh
                SJ      signext_common_add_store_er3
add_saturate_s16_test_r7_bit7:     MB      C, r7.7
                JGE     signext_common_add
                ADD     A, er3
                MB      C, ACCH.7
                JLT     signext_common_add_store_er3
                L       A, #08000h
                SJ      signext_common_add_store_er3
signext_common_add:     ADD     A, er3
signext_common_add_store_er3:     ST      A, er3
                RT

;--------------------------------------------------------------------------------------------
; scale_mul5_div4  @0x4FB9
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; negate_if_signed  @0x4FCE
;   TRACED: negates A (two's-complement) if the DD sign flag is set, otherwise returns it
;   unchanged - a signed-magnitude/absolute-value helper used throughout the interpolation
;   and trim code after a SUBB. Reached via VCAL 7, the busiest of the non-zero VCAL
;   slots.
;--------------------------------------------------------------------------------------------
negate_if_signed:         MB      C, PSWH.4
                JGE     negate_if_signed_xor_ff
                XORB    A, #0ffh
                BRK
                DB  086h,001h,000h,001h
negate_if_signed_xor_ff:     XORB    A, #0ffh
                ADDB    A, #001h
                RT

;--------------------------------------------------------------------------------------------
; scaler_table_lookup  @0x4FDE
;   96% HTS115 match. Converts a raw axis value to index+fraction.
;--------------------------------------------------------------------------------------------
scaler_table_lookup:     CLR     A
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

;--------------------------------------------------------------------------------------------
; table2d_lookup_interp  @0x5010
;   91% HTS115 match. The 3D map interpolator; r0=cols, r1=rows.
;--------------------------------------------------------------------------------------------
table2d_lookup_interp:     CLR     A
; [H] --- Generic 2D table lookup/interpolation helper (row x column, e.g. RPM x Load). Given a
; [H] table base in X1, row width in r0, row index in r1, column offset in r2, column count in r3.
; [H] Companion to the 1D table_interp_lookup used elsewhere.
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

;--------------------------------------------------------------------------------------------
; table2d_mul_combine  @0x5063
;   87% HTS115 match.
;--------------------------------------------------------------------------------------------
table2d_mul_combine:     SUB     A, er2
                MB      PSWL.4, C
                JGE     table2d_mul_combine_mul
                ST      A, er1
                CLR     A
                SUB     A, er1
table2d_mul_combine_mul:     MUL
                L       A, er1
                MB      C, PSWL.4
                JGE     table2d_mul_combine_add_er2
                SUB     er2, A
                L       A, er2
                RT
table2d_mul_combine_add_er2:     ADD     A, er2
                ST      A, er2
                RT

;--------------------------------------------------------------------------------------------
; knock_244_helper  @0x5079
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; map_result_postscale  @0x5088
;   Called right after table2d_lookup_interp at 0x1273.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; sub_clamp_helper  @0x50A5
;   Called 3x; used at 0x16CF.
;--------------------------------------------------------------------------------------------
sub_clamp_helper:     MULB
                L       A, ACC
                SLL     A
                LB      A, ACCH
                JGE     sub_clamp_helper_return
                LB      A, #0ffh
sub_clamp_helper_return:     RT

;--------------------------------------------------------------------------------------------
; scale_ram1e4_mul_shr2  @0x50B1
;   VERIFIED: multiplies A by RAM word 0x1E4, then shifts the 32-bit product right by 2
;   bits (two SRL/RORB pairs) before falling into mul_zero_if_r3_zero.
;--------------------------------------------------------------------------------------------
scale_ram1e4_mul_shr2:     MOV     er0, off(001e4h)
                MUL
                SRL     er1
                RORB    A
                SRL     er1
                RORB    A
                SJ      mul_zero_if_r3_zero_load_r2

;--------------------------------------------------------------------------------------------
; mul_zero_if_r3_zero  @0x50BE
;   VERIFIED: performs MUL, then forces the result to 0xFFFF if r3==0 (a "no data"
;   sentinel), otherwise returns the swapped product. Direct-entry form used both
;   standalone and as the tail of scale_ram1e4_mul_shr2.
;--------------------------------------------------------------------------------------------
mul_zero_if_r3_zero:     MUL
mul_zero_if_r3_zero_load_r2:     LB      A, r2
                L       A, ACC
                SWAP
                CMPB    r3, #000h
                JEQ     tipin_table_diff_calc
                L       A, #0ffffh
tipin_table_diff_calc:     RT

;--------------------------------------------------------------------------------------------
; idle_stall_helper  @0x50CD
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
idle_stall_helper:     MOV     X2, #00010h
                MOV     DP, #01000h
                SJ      clamp_range_check

;--------------------------------------------------------------------------------------------
; injtimer_bank_calc2  @0x50D5
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
injtimer_bank_calc2:     MOV     X2, #FUEL1_Hi_Extended
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

;--------------------------------------------------------------------------------------------
; clamp_to_35_1023  @0x50F0
;   VERIFIED: loads bounds er2=0x23(35)/er3=0x3FF(1023), then falls into the shared clamp
;   body that bounds A to [er2,er3] and stores to [X1] and [DP].
;--------------------------------------------------------------------------------------------
clamp_to_35_1023:     MOV     er2, #00023h
                MOV     er3, #003ffh
                SJ      clamp_to_35_512_cmp_er2

;--------------------------------------------------------------------------------------------
; clamp_to_35_512  @0x50FA
;   VERIFIED: identical shared clamp body to clamp_to_35_1023, but with the upper bound
;   preset to 0x200 (512) instead of 0x3FF.
;--------------------------------------------------------------------------------------------
clamp_to_35_512:     MOV     er2, #00023h
                MOV     er3, #00200h
clamp_to_35_512_cmp_er2:     CMP     A, er2
                JLT     load_er0_result
                CMP     A, er3
                JLE     load_er0_result_store_ram0
                MOV     er2, er3
load_er0_result:     L       A, er2
                CLR     er0
load_er0_result_store_ram0:     ST      A, 00000h[X1]
                L       A, er0
                ST      A, [DP]
                RT

;--------------------------------------------------------------------------------------------
; multiway_selector_eval_masked  @0x5113
;   TRACED: masked byte comparison (XOR/AND against r2/r3) against a value read via [DP],
;   sets the multiway selector bit off(2FFh).5, then dispatches to either the dual-map
;   ignition chain (dualmap_dispatch_jump_and_ie) or a TPS-adjacent handler
;   (multiway_selector_load_0) depending on a comparison against RAM 0xAC. Another
;   selector-input evaluation stage in the multiway_condition_* family.
;--------------------------------------------------------------------------------------------
multiway_selector_eval_masked:     L       A, #00000h
                JEQ     multiway_selector_goto_2
                MOV     DP, A
                MOV     er1, #00000h
                LB      A, [DP]
                XORB    A, r2
                ANDB    A, r3
                JEQ     multiway_selector_goto_2
                L       A, er2
                MOV     DP, A
                SJ      multiway_selector_goto
threshold_bank_223_2_load_er3:     L       A, er3
                ADD     A, #00028h
                CMP     0ach, A
                MB      off(002ffh).5, C
                L       A, er3
                MOV     DP, A
multiway_selector_goto:     J       dualmap_dispatch_jump_and_ie
multiway_selector_goto_2:     J       multiway_selector_load_0
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh

;--------------------------------------------------------------------------------------------
; idle_helper2  @0x5141
;   VERIFIED: MUL, then feeds into a shared bounds-check against X1/X2 register-supplied
;   limits (gated by off(20Ch).0) rather than fixed presets.
;--------------------------------------------------------------------------------------------
idle_helper2:     MUL
                L       A, er1
                SJ      idle_helper2_if_ram20c_bit0_clr

;--------------------------------------------------------------------------------------------
; mul_then_clamp_x1x2_2  @0x5146
;   VERIFIED: identical to idle_helper2 but first zeroes the product if r2==0
;   before entering the same X1/X2 bounds check.
;--------------------------------------------------------------------------------------------
mul_then_clamp_x1x2_2:     MUL
                CMPB    r2, #000h
                JEQ     idle_helper2_if_ram20c_bit0_clr
                L       A, #0ffffh
idle_helper2_if_ram20c_bit0_clr:     JBR     off(0020ch).0, idle_helper2_swap_er3
                ADD     A, er3
                JLT     idle_helper2_sc_path
idle_pi_clamp_compare:     CMP     A, X1
                JLE     idle_pi_clamp_setcarry
                CMP     X2, A
                JGT     idle_helper2_store
idle_helper2_sc_path:     SC
                L       A, X2
                SJ      idle_helper2_store
idle_helper2_swap_er3:     XCHG    A, er3
                SUB     A, er3
                JGE     idle_pi_clamp_compare
idle_pi_clamp_setcarry:     L       A, X1
                SC
idle_helper2_store:     ST      A, er3
                RT

;--------------------------------------------------------------------------------------------
; stub_or_short_helper  @0x516B
;   Called 7x; 4 instructions.
;--------------------------------------------------------------------------------------------
stub_or_short_helper:     L       A, #00700h
                JBS     off(00216h).3, stub_or_short_helper_return
                L       A, #00500h
stub_or_short_helper_return:     RT

;--------------------------------------------------------------------------------------------
; idle_pi_clamp_helper  @0x5175
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
idle_pi_clamp_helper:     CMP     off(0028ch), A
                JLT     idle_pi_clamp_low
                CMP     A, off(0028eh)
                JGE     idle_pi_clamp_return
                L       A, off(0028eh)
idle_pi_clamp_return:     RT
idle_pi_clamp_low:     L       A, off(0028ch)
                RT

;--------------------------------------------------------------------------------------------
; weighted_sum_2term_trim  @0x5184
;   VERIFIED: computes two products (r6*A and r7*X1), conditionally accumulates them into
;   a running total at off(29Ah) gated by PSWL.4, calling clamp_0_to_3ff to bound the
;   running total. A two-term weighted-blend accumulator.
;--------------------------------------------------------------------------------------------
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
                JLT     weighted_sum_2term_sub_er1
                ADD     A, er1
                CAL     clamp_0_to_3ff
                ST      A, off(0029ah)
                ADD     A, er2
                SJ      weighted_sum_2term_call_clamp_0_to_3ff
weighted_sum_2term_sub_er1:     SUB     A, er1
                CAL     clamp_0_to_3ff
                ST      A, off(0029ah)
                SUB     A, er2
weighted_sum_2term_call_clamp_0_to_3ff:     CAL     clamp_0_to_3ff
                RT

;--------------------------------------------------------------------------------------------
; clamp_0_to_3ff  @0x51AC
;   VERIFIED: clamps A to the range [0, 0x3FF] (1023). Called from
;   weighted_sum_2term_trim.
;--------------------------------------------------------------------------------------------
clamp_0_to_3ff:     CLR     er0
                JLE     clamp_0_to_3ff_load_er0
                MOV     er0, #003ffh
                CMP     A, er0
                JLT     clamp_0_to_3ff_return
clamp_0_to_3ff_load_er0:     L       A, er0
clamp_0_to_3ff_return:     RT

;--------------------------------------------------------------------------------------------
; cfgvariant_set_flags  @0x51B9
;   82% HTS115 match.
;--------------------------------------------------------------------------------------------
cfgvariant_set_flags:     SUBB    A, #001h
; [H] cfgvariant_checksum2_calc are its siblings -- referenced from both cfgvariant_apply_gate in the DTC-scan
; [H] context and the original boot-time config-variant validation block from the very start of
; [H] this session's work). Given a variant index in A, computes byte offset (A/8) and bit
; [H] position (A%8) and sets that bit in 3 separate flag arrays (0x11A, 0x212, 0x31E) --
; [H] enabling variant-specific feature flags across the ECU based on which configuration variant
; [H] is active. cfgvariant_checksum_calc then sums+XORs a small calibration block (0x31D-0x322)
; [H] -- likely a per-variant config validation checksum.
                MOVB    r0, #008h
                DIVB
                MOV     X1, A
                LB      A, r1
                SBR     00112h[X1]
                SBR     00212h[X1]
                SBR     0031ah[X1]

;--------------------------------------------------------------------------------------------
; cfgvariant_checksum_calc  @0x51CD
;   86% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; port_debounce_helper  @0x51E4
;   94% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; decrement_timer_array  @0x5204
;   61% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; ResetWatchDog  @0x521E
;   88% HTS115 match.
;--------------------------------------------------------------------------------------------
ResetWatchDog:     LB      A, #03ch
                STB     A, WDT
                SWAPB
                STB     A, WDT
                MB      C, 09fh.1
                JLT     resetwatchdog_return
                XORB    P2, #010h
resetwatchdog_return:     RT

;--------------------------------------------------------------------------------------------
; ect_step_helper  @0x522F
;   85% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; ect_smooth_helper  @0x5248
;   76% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; crank_edge_helper  @0x5259
;   60% HTS115 match.
;--------------------------------------------------------------------------------------------
crank_edge_helper:     L       A, off(0011ch)
                ST      A, (0021ch-00280h)[USP]
                L       A, off(0011eh)
                ST      A, (0021eh-00280h)[USP]
                RT

;--------------------------------------------------------------------------------------------
; refresh_engine_flags_snapshot  @0x5262
;   VERIFIED: copies 5 consecutive words from a USP-relative stack frame (0x212-0x21A)
;   into fixed RAM locations 0x112-0x11A. A pure register/stack snapshot copier, no
;   computation.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; timer_or_counter_helper  @0x5277
;   Most-called CAL in the ROM (17 sites).
;--------------------------------------------------------------------------------------------
timer_or_counter_helper:     LB      A, r0
                MBR     C, [DP]
                LC      A, [X1]
                JLT     timer_or_counter_test_pswl_bit4
                LB      A, ACCH
timer_or_counter_test_pswl_bit4:     MB      C, PSWL.4
                JLT     timer_or_counter_cmp_r2
                CMPB    A, r2
                SJ      timer_or_counter_load_r0
timer_or_counter_cmp_r2:     CMPB    r2, A
timer_or_counter_load_r0:     LB      A, r0
                MBR     [DP], C
                INC     X1
                INC     X1
                INCB    r0
                DECB    r1
                JNE     timer_or_counter_helper
                RT

;--------------------------------------------------------------------------------------------
; selftest_regbank_verify  @0x5293
;   69% HTS115 match.
;--------------------------------------------------------------------------------------------
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
                JEQ     selftest_regbank_return
                MOVB    0ebh, #042h
                BRK
selftest_regbank_return:     RT

;--------------------------------------------------------------------------------------------
; idle_helper1  @0x52BB
;   VALIDATED against HTS115: same TM2-vs-snapshot-plus-0xC8 window check, same IRQH.4
;   test, same BRK-with-reason-0x4A trap, in the same position right after the boot
;   A/D-conversion wait loop (called from 0x245D, matching HTS115's idle_helper1 call site
;   exactly). If the ADC scan has not completed within the timeout window, this traps the
;   self-test.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; selftest_reason_range_check  @0x5306
;   VERIFIED: reads a stored fault-reason byte from RAM 0x3C9, checks whether it falls in
;   one of two accepted ranges (0xFC-0xFF or 0x78-0x88); if not, forces reason code 0x49
;   and, once a retry counter at RAM 0xED reaches zero, traps via BRK. Fits the same
;   fault_retry_check pattern HTS115's header documents.
;--------------------------------------------------------------------------------------------
selftest_reason_range_check:     CMPB    off(00236h), #00ah
                JLT     empty_stub_return

;--------------------------------------------------------------------------------------------
; selftest_reason_range_check_entry  @0x530C
;   VERIFIED: identical body to selftest_reason_range_check; this is the direct-entry
;   address used when the caller has already passed the off(236)>=0x0A precondition.
;--------------------------------------------------------------------------------------------
selftest_reason_range_check_entry:     MOV     DP, #003c9h
                LB      A, [DP]
                CMPB    A, #0ffh
                JGT     selftest_reason_range_load_49
                CMPB    A, #0fch
                JGE     empty_stub_return
                CMPB    A, #088h
                JGT     selftest_reason_range_load_49
                CMPB    A, #078h
                JGE     empty_stub_return
selftest_reason_range_load_49:     LB      A, #049h
                STB     A, 0e7h
                DECB    0edh
                JNE     empty_stub_return
                STB     A, 0ebh
                BRK
empty_stub_return:     RT

;--------------------------------------------------------------------------------------------
; dwell_scale_helper  @0x532D
;   100% HTS115 match.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; cfgvariant_eval_condition  @0x5341
;   81% HTS115 match.
;--------------------------------------------------------------------------------------------
cfgvariant_eval_condition:     CLRB    r0
                CMPB    r6, #001h
                JNE     cfgvariant_check_v3
                CMPB    ECT_raw, #01ah
                JLT     cfgvariant_result_common
                INCB    r0
cfgvariant_result_common:     SJ      cfgvariant_eval_result
cfgvariant_check_v3:     CMPB    r6, #003h
; [H] --- cfgvariant_eval_condition's dispatch body: for each specific variant index (3, 6, 7, 10,
; [H] 11, 13, 20, 26), checks the sign of that variant's associated sensor/config byte (0xBB,
; [H] 0x3D4, 0x3A4, 0x3CC, 0x3D2, 0x3CD, 0x3D2 again, 0xD7) and increments r0 if negative --
; [H] reads as a per-variant "is this variant's associated input plausible/connected" check,
; [H] feeding cfgvariant_eval_result.
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
                JNE     cfgvariant_check_v11_cmp_r6_2
                CMPB    r7, #009h
                JNE     cfgvariant_check_v11_cmp_r6_2
                INCB    r0
                SJ      cfgvariant_eval_result
cfgvariant_check_v11_cmp_r6_2:     CMPB    r6, #00dh
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
                JNE     cfgvariant_check_v17_cmp_r6
cfgvariant_eval_result2:     SJ      cfgvariant_remap_start
cfgvariant_check_v17_cmp_r6:     CMPB    r6, #00ch
                JNE     cfgvariant_check_v17_cmp_r6_2
                CMPB    r7, #00ah
                JNE     cfgvariant_check_v17_cmp_r6_2
                INCB    r0
                INCB    r0
                SB      off(0021ah).1
                SJ      cfgvariant_eval_result3
cfgvariant_check_v17_cmp_r6_2:     CMPB    r6, #00eh
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
                JNE     cfgvariant_check_v15_cmp_r6
                CMPB    r7, #00fh
                JEQ     cfgvariant_eval_result4
                INCB    r0
                SJ      cfgvariant_eval_result4
cfgvariant_check_v15_cmp_r6:     CMPB    r6, #015h
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
                J       cfgvariant_check_v5_cmp_r7
                DB  000h
cfgvariant_check_v5_inc_r0:     INCB    r0
cfgvariant_check_v5_goto_cfgvariant:     SJ      cfgvariant_remap_start
cfgvariant_check_v1e:     CMPB    r6, #01fh
                JNE     cfgvariant_check_v1f
                J       cfgvariant_check_v1e_cmp_r7
                DB  000h
cfgvariant_check_v1e_inc_r0:     INCB    r0
cfgvariant_check_v1e_goto_cfgvariant:     SJ      cfgvariant_remap_start
cfgvariant_check_v1f:     CMPB    r6, #019h
                JEQ     cfgvariant_remap_start
                MOVB    r1, r6
                RT

;--------------------------------------------------------------------------------------------
; cfgvariant_remap_start  @0x547E
;   TRACED: a manual compare-chain mapping an internal state code in r6 (0x19, 0x1A, ...)
;   to output fault/reason byte constants (0x23, ...) - a switch-case-style translation
;   table used by the self-test/fault-reporting subsystem.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; cfgvariant_snapshot_capture  @0x54AB
;   VERIFIED: runs once (gated by RAM 0x340==0), then packs several live state bytes - a
;   rotated off(21Dh).0 bit, port snapshots at 0xB4/0xAC, and ADC-buffer copies read via
;   X1=0x3C8/0x3C0 - into a sequential block starting at RAM 0x340. Looks like the
;   construction of a diagnostic/serial report snapshot.
;--------------------------------------------------------------------------------------------
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
                LB      A, IAT_raw
                STB     A, [DP]
                INC     DP
                MOV     X1, #003d4h
                L       A, 00000h[X1]
                SWAP
                ST      A, [DP]
                INC     DP
                INC     DP
                LB      A, ECT_raw
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

;--------------------------------------------------------------------------------------------
; cfgvariant_state_reset  @0x5505
;   67% HTS115 match.
;--------------------------------------------------------------------------------------------
cfgvariant_state_reset:     CLR     A
                MOV     DP, #00354h
cfgvariant_state_clear_loop:     DEC     DP
                DEC     DP
                ST      A, [DP]
                CMP     DP, #0031ah
                JGT     cfgvariant_state_clear_loop
                RT

;--------------------------------------------------------------------------------------------
; cfgvariant_ram_init_0x300  @0x5513
;   VERIFIED: initializes RAM 0x300-0x31xx with default sentinel values (0x8000 words, a
;   0x7B byte, a 0x332 word). This is exactly the RAM range cfgvariant_checksum2_calc (0x5548)
;   later checksums (0x320-0x34F), so this is that subsystem's initializer.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; cfgvariant_checksum2_calc  @0x5548
;   87% HTS115 match; additive+XOR over RAM 0x0320-0x034F.
;--------------------------------------------------------------------------------------------
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

;--------------------------------------------------------------------------------------------
; boot_completion_helper  @0x5560
;   TRACED: reads CONFIG 0x6001-0x601B, bit7 -> RAM flag bits.
;--------------------------------------------------------------------------------------------
boot_completion_helper:     CLRB    A
; [H] --- Master feature-enable flag initialization: reads a whole set of calibration enable
; [H] flags (VtecEnable, AutoA, O2Heater, CloseloopO2VE, DCode16, Tablepointers, and more --
; [H] all real calibration fields) and packs each into its corresponding runtime status bit
; [H] (0x216/0x217/0x219/0x227). This is the concrete "apply calibration enable switches to
; [H] runtime state" step, likely run once during/after boot.
                LCB     A, CFG_unused_216_4
                SLLB    A
                MB      off(00216h).4, C
                LCB     A, CFG_flag_227_6
                SLLB    A
                MB      off(00227h).6, C
                LCB     A, CFG_flag_216_6
                SLLB    A
                MB      off(00216h).6, C
                LCB     A, CFG_flag_227_4
                SLLB    A
                MB      off(00227h).4, C
                LCB     A, CFG_flag_219_1
                SLLB    A
                MB      off(00219h).1, C
                LCB     A, CFG_flag_217_3
                SLLB    A
                MB      off(00217h).3, C
                LCB     A, CFG_flag_227_7
                SLLB    A
                MB      off(00227h).7, C
                LCB     A, CFG_unused_216_1
                SLLB    A
                MB      off(00216h).1, C
                LCB     A, CFG_flag_216_7
                SLLB    A
                MB      off(00216h).7, C
                MOV     DP, #00354h
                MB      [DP].0, C
                LCB     A, CFG_flag_227_1
                SLLB    A
                MB      off(00227h).1, C
                MOV     DP, #003bfh
                LB      A, [DP]
                STB     A, r1
                J       boot_completion_helper_clr_carry
boot_completion_helper_load_ind:     LB      A, [DP]
                STB     A, r2
                J       boot_completion_helper_rom_load_CFG
                DW  00000h
boot_completion_helper_load_r2:     LB      A, r2
                CMPB    r0, #000h
                JEQ     boot_completion_helper_shl_a
                LCB     A, CFG_DualMapSelect
boot_completion_helper_shl_a:     SLLB    A
                MB      off(00216h).3, C
                CMPB    r0, #000h
                JEQ     boot_flag_iabv_check
                LCB     A, CFG_DualMapSelect_alt
                SLLB    A
                SJ      boot_flag_iabv_common
boot_flag_iabv_check:     RC
                LCB     A, CFG_flag_216_2_and_5
                JNE     boot_flag_iabv_common
                LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h
boot_flag_iabv_common:     MB      off(00216h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_baro_check
                LCB     A, CFG_MapDimension2
                SLLB    A
                SJ      boot_flag_baro_common
boot_flag_baro_check:     LB      A, r2
                SLLB    A
                SLLB    A
                XORB    PSWH, #080h
boot_flag_baro_common:     MB      off(00216h).0, C
                CMPB    r0, #000h
                JEQ     boot_flag_baro_common_goto
                LCB     A, CFG_Selector3
                SLLB    A
                SJ      boot_flag_baro_common_carry_to_bit6
boot_flag_baro_common_goto:     J       boot_flag_baro_common_test_ram216_bit2
                DW  00000h
boot_flag_baro_common_branch:     JEQ     boot_flag_baro_common_carry_to_bit6
                LB      A, r1
                SLLB    A
                XORB    PSWH, #080h
boot_flag_baro_common_carry_to_bit6:     MB      off(00217h).6, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_check
                LCB     A, CFG_flag_216_5_alt
                SLLB    A
                SJ      boot_flag_gearpreset_common
boot_flag_gearpreset_check:     RC
                LCB     A, CFG_flag_216_2_and_5
                JNE     boot_flag_gearpreset_common
                LB      A, r1
                SLLB    A
boot_flag_gearpreset_common:     MB      off(00216h).5, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_alt
                LCB     A, CFG_flag_PSWL4
                SLLB    A
                SJ      boot_flag_gearpreset_carry_to_pswl_bit4
boot_flag_gearpreset_alt:     LB      A, r1
                SLLB    A
                SLLB    A
boot_flag_gearpreset_carry_to_pswl_bit4:     MB      PSWL.4, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_clr_carry
                LCB     A, boot_flag_gearpreset_const
                SLLB    A
                SJ      boot_flag_gearpreset_carry_to_bit3
boot_flag_gearpreset_clr_carry:     RC
                LCB     A, CFG_flag_227_3
                JEQ     boot_flag_gearpreset_carry_to_bit3
                MB      C, off(00216h).0
boot_flag_gearpreset_carry_to_bit3:     MB      off(00227h).3, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_test_pswl_bit4
                LCB     A, CFG_flag_227_2
                SLLB    A
                SJ      boot_flag_gearpreset_carry_to_bit2
boot_flag_gearpreset_test_pswl_bit4:     MB      C, PSWL.4
boot_flag_gearpreset_carry_to_bit2:     MB      off(00227h).2, C
                CMPB    r0, #000h
                JEQ     boot_flag_gearpreset_goto
                LCB     A, boot_flag_gearpreset_const_2
                SLLB    A
                SJ      boot_flag_gearpreset_carry_to_bit4
boot_flag_gearpreset_goto:     J       boot_flag_gearpreset_clr_carry_2
                DB  000h
boot_flag_gearpreset_branch:     JNE     boot_flag_gearpreset_ptr_3c6
                NOP
                LCB     A, CFG_flag_216_2_and_5
                JEQ     boot_flag_gearpreset_carry_to_bit4
                LCB     A, CFG_flag_219_4
                JEQ     boot_flag_gearpreset_carry_to_bit4
                JBR     off(00216h).0, boot_flag_gearpreset_carry_to_bit4
boot_flag_gearpreset_ptr_3c6:     MOV     DP, #003c6h
                CMPB    [DP], #09ah
boot_flag_gearpreset_carry_to_bit4:     MB      off(00219h).4, C
                CMPB    r0, #000h
                JEQ     boot_flag_3cf_check
                LCB     A, CFG_flag_DP_1
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

;--------------------------------------------------------------------------------------------
; dualmap_dispatch_jump  @0x56BB
;   TRACED: computes DP = RAM 0xAC + 0x45 (a table of computed-jump offsets), then jumps
;   into the shared ignition_timing_calc_task body at 0x3F93 with the offset applied - a
;   switch-style computed jump rather than a linear call. This is the dispatch surface
;   that several of the CFG_DualMapSelect table-pair sites are actually entered through.
;--------------------------------------------------------------------------------------------
dualmap_dispatch_jump:     L       A, 0ach
                ADD     A, #00045h
                MOV     DP, A
                SUB     A, #00002h
                J       dualmap_dispatch_jump_and_ie
                DB  0FFh,0FFh,0FFh,0FFh
tpsaccel_store_0x162_clear_a:     CLRB    A
                CMPB    coolantTempByte, #02eh
                JGE     tpsaccel_store_0x162_store_ram188
                LB      A, #034h
tpsaccel_store_0x162_store_ram188:     STB     A, off(00188h)
                J       tpsaccel_ignitioncut_flag_copy
rpm_decel_store_0x14a_cmp_ram12d:     CMPB    off(0012dh), #0ffh
                JGE     rpm_decel_store_0x14a_goto_idle_sub
                CMPB    coolantTempByte, #0ffh
                J       rpm_decel_store_0x14a_branch
rpm_decel_store_0x14a_goto_idle_sub:     J       idle_sub_result_store
battery_voltage_store_call_timer_or:     CAL     timer_or_counter_helper
                LB      A, #044h
                JBS     off(00225h).4, battery_voltage_store_cmp_r2
                LB      A, #030h
battery_voltage_store_cmp_r2:     CMPB    r2, A
                MB      off(00225h).4, C
                LB      A, #0b0h
                JBS     off(00225h).5, idle_temp_hyst1
                LB      A, #0c0h
idle_temp_hyst1:     CMPB    A, TPS2_raw
                MB      off(00225h).5, C
                J       idle_temp_hyst1_set_carry
idle_gear_calc_start_load_ind:     L       A, [DP]
                ADD     A, off(00268h)
                JGE     idle_gear_calc_start_goto
                L       A, #0ffffh
idle_gear_calc_start_goto:     J       idle_gear_clamp_max_store_ram28e
idle_gear_mul_apply_rol_a:     ROL     A
                JLT     idle_gear_mul_apply_goto_idle_gear_clamp
                ADD     A, off(00268h)
                JLT     idle_gear_mul_apply_goto_idle_gear_clamp
                J       idle_gear_mul_apply_add_ind
idle_gear_mul_apply_goto_idle_gear_clamp:     J       idle_gear_clamp
idle_gear_clamp_max_rol_a:     ROL     A
                JLT     idle_gear_clamp_max_goto_idle_gear2
                ADD     A, off(00268h)
                JLT     idle_gear_clamp_max_goto_idle_gear2
                J       idle_gear_clamp_max_add_1000
idle_gear_clamp_max_goto_idle_gear2:     J       idle_gear2_clamp
idle_vcal5_call3_if_ram21a_bit0_clr:     JBR     off(0021ah).0, idle_vcal5_call3_goto_idle_vcal5_report
                MB      C, off(00225h).5
                JBR     off(00217h).6, idle_vcal5_call3_branch
                MB      C, off(00225h).4
idle_vcal5_call3_branch:     JLT     idle_vcal5_call3_goto_idle_vcal5_report
                J       idle_vcal5_call3_goto
idle_vcal5_call3_goto_idle_vcal5_report:     J       idle_vcal5_report
idle_stall_diff_calc_load_ram284:     L       A, off(00284h)
                SUB     A, off(00276h)
                JGE     idle_stall_diff_calc_sub_ram268
                J       idle_stall_diff_check
idle_stall_diff_calc_sub_ram268:     SUB     A, off(00268h)
                J       idle_stall_diff_calc_branch
tbl_6baf_done_set_r2:     MOVB    r2, off(00235h)
                CAL     timer_or_counter_helper
                MOVB    r1, #001h
                MOVB    r2, 0b9h
                J       tbl_6baf_done_call_timer_or_counter_h
threshold_bank_223_2_store_r2:     STB     A, r2
                MOV     X1, #threshold_bank_223_2_data
                J       threshold_bank_223_2_vcal0
threshold_bank_223_2_store_r2_2:     STB     A, r2
                MOV     X1, #threshold_bank_223_2_data_4
                J       threshold_bank_223_2_vcal0_2
nmi_poll_p4_1_set_p2:     MOVB    P2, #0ffh
                RB      TCON0.2
                SB      TCON0.2
                CLRB    A
                STB     A, ADSCAN
                J       nmi_poll_p4_1_store_adsel
                DB  0F9h,07Eh,032h,0B9h,051h,003h,099h,023h
adc3_sensor_task_if_ram213_bit3_set:     JBS     off(00213h).3, adc3_sensor_task_goto
                JBS     off(00217h).5, adc3_sensor_task_goto
                J       adc3_sensor_task_sub_ram2f3
adc3_sensor_task_goto:     J       adc3_sensor_task_set_ram2db
idle_target_correction_done:     XCHGB   A, r4
                SUBB    r4, A
                JGT     idle_target_clear_a
                J       idle_target_correction_zero
idle_target_clear_a:     CLR     A
                CAL     injtimer_bank_calc3
                J       to_idle_step_condition_dispatch
ignition_timing_calc_branch_7:     JGE     ignition_timing_calc_cmp_r5_3
                CLRB    A
ignition_timing_calc_cmp_r5_3:     CMPB    A, r5
                MB      off(0022eh).4, C
                J       ignition_timing_calc_load_ramb4
ignition_timing_calc_branch_8:     JGE     ignition_timing_calc_cmp_r5_4
                CLRB    A
ignition_timing_calc_cmp_r5_4:     CMPB    A, r5
                MB      off(0022eh).6, C
                J       ignition_timing_calc_load_ramb4_2
tbl_6baf_done_sub_ff:     SUBB    A, #0ffh
                JGE     tbl_6baf_done_goto_5
                CLRB    A
tbl_6baf_done_goto_5:     J       tbl_6baf_done_cmp_ramb4
knock_324_bit_store_test_p0_bit1:     MB      C, P0.1
                XORB    PSWH, #080h
                J       knock_324_bit_store_rol_a_5
knock_324_bit_store_test_p0_bit5:     MB      C, P0.5
                XORB    PSWH, #080h
                ROLB    A
                MB      C, P0.6
                J       knock_324_bit_store_nop
knock_324_bit_store_test_p0_bit2:     MB      C, P0.2
                XORB    PSWH, #080h
                J       knock_324_bit_store_rol_a_6
diag_mode_code_store_rom_load_CFG_flag:     LCB     A, CFG_flag_227_3
                MOVB    r0, A
                L       A, off(0025ch)
                SLL     A
                J       diag_mode_code_store_branch
diag_mode_code_store_cmp_r0:     CMPB    r0, #000h
                JNE     diag_mode_code_store_goto_diag_clamp
                SLL     A
                JGE     diag_mode_code_store_goto_diag_clamp
                J       diag_clamp_ff
diag_mode_code_store_goto_diag_clamp:     J       diag_clamp_acch
diag_store_3ad_cmp_r0:     CMPB    r0, #000h
                JNE     diag_store_3ad_goto_diag_clamp_acch2
                SLL     A
                JGE     diag_store_3ad_goto_diag_clamp_acch2
                J       diag_clamp_ff2
diag_store_3ad_goto_diag_clamp_acch2:     J       diag_clamp_acch2
cfg_selector3_dispatch_cmp_ram280:     CMP     off(00280h), #00700h
                JGE     cfg_selector3_dispatch_goto_2
cfg_selector3_dispatch_cmp_r1:     CMPB    A, r1
                J       cfg_selector3_dispatch_branch
cfg_selector3_dispatch_goto_2:     J       idle_ectvs_result1_set_r1
knockretard2_clamp_test_rama0_bit1:     MB      C, 0a0h.1
                JGE     knockretard2_clamp_nop
                MOV     X1, #knockretard2_clamp_data
knockretard2_clamp_nop:     NOP
                NOP
                NOP
                JBR     off(00223h).4, knockretard2_clamp_load_ram236
                ADD     X1, #0002ch
knockretard2_clamp_load_ram236:     LB      A, off(00236h)
                VCAL    0
                J       knockretard2_clamp_store_ram23b
to_vtec_debounce_store_clr_rama0_bit1:     RB      0a0h.1
                CMPCB   A, [DP]
                JLE     to_vtec_debounce_store_goto
                SB      0a0h.1
                ADD     DP, #00004h
                CMPCB   A, [DP]
                JGT     to_vtec_debounce_store_add_dp
to_vtec_debounce_store_goto:     J       to_vtec_debounce_store_load_3
to_vtec_debounce_store_add_dp:     ADD     DP, #00004h
                J       to_vtec_debounce_store_inc_r1
to_vtec_debounce_store_branch:     JLE     to_vtec_debounce_store_goto
                ADD     DP, #00004h
                J       to_vtec_debounce_store_inc_r1_2
to_vtec_debounce_store_data:       DB  04Eh,04Eh,04Eh,04Eh,063h,063h,063h,063h
                DB  077h,077h,077h,077h,08Bh,08Bh,08Bh,08Bh
                DB  0A0h,0A0h,0A0h,0A0h,0B4h,0B4h,0B4h,0B4h
                DB  0C9h,0C9h,0C9h,0C9h
knockretard2_clamp_data:       DB  0FFh,017h,0F8h,017h,0F0h,031h,0E8h,037h
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
                DB  0DCh,01Dh,004h,092h,080h,014h,000h,032h
                DB  079h,050h,003h,0C8h,00Eh
state_21a_7_dispatch3_if_ram21a_bit6_clr:     JBR     off(0021ah).6, state_21a_7_dispatch3_goto_state_2de
                JBS     off(00217h).5, state_21a_7_dispatch3_goto_state_2de
                J       state_21a_7_dispatch3_if_ram215_bit1_set
state_21a_7_dispatch3_goto_state_2de:     J       state_2de_reset
state_21a_7_dispatch2_if_ram21a_bit6_clr:     JBR     off(0021ah).6, state_21a_7_dispatch2_goto_state_2df
                JBS     off(00217h).5, state_21a_7_dispatch2_goto_state_2df
                J       state_21a_7_dispatch2_load_rambf
state_21a_7_dispatch2_goto_state_2df:     J       state_2df_reset
dwell_scale_shift_data:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,020h,03Ah,063h,07Ah
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  01Dh,024h,01Dh,000h,020h,039h,04Ah,066h,084h,088h
ve_result_flag_store_branch:     JGE     ve_result_flag_store_goto
                CLRB    A
                J       ve_result_flag_store_set_r4
ve_result_flag_store_goto:     J       ve_result_flag_store_cmp_acch
idle_sub_result_store_store_ram3b4:     ST      A, 003b4h[X1]
                ST      A, 003d4h[X1]
                J       idle_sub_result_store_goto
injtimer_bank_a_calc_if_ram11c_bit5_clr:     JBR     off(0011ch).5, injtimer_bank_a_store
                CLR     A
injtimer_bank_a_store:     MOV     DP, #003d4h
                ST      A, [DP]
                L       A, er3
                MOV     DP, #003ach
                J       injtimer_bank_a_store_set_er0
bias_080_scale_table_swap_r0:     XCHGB   A, r0
                JLT     bias_080_scale_table_goto_to_knock_div
                CLRB    A
bias_080_scale_table_goto_to_knock_div:     J       to_knock_div_calc3
knock_324_bit_store_ptr_320:     MOV     DP, #00320h
                MB      [DP].0, C
                LB      A, [DP]
                ANDB    A, #0f1h
                STB     A, [DP]
                J       knock_324_bit_store_load_adcr6
diag_mode_code_store_ptr_3bf:     MOV     DP, #003bfh
                LB      A, [DP]
                J       diag_mode_code_store_shl_a
cfgvariant_index_call_cfgvariant_set_fla:     CAL     cfgvariant_set_flags
                CMPB    r6, #018h
                J       cfgvariant_index_branch
boot_flag_gearpreset_clr_carry_2:     RC
                JBS     off(00217h).6, boot_flag_gearpreset_goto_2
                LCB     A, diag_snapshot_copy_const
                J       boot_flag_gearpreset_branch
boot_flag_gearpreset_goto_2:     J       boot_flag_gearpreset_carry_to_bit4
o2trim_speed_flag_set_if_ram119_bit2_clr:     JBR     off(00119h).2, o2trim_speed_flag_set_goto_o2trim_gate
                JBS     off(0011fh).0, o2trim_speed_flag_set_goto_o2trim_gate
                J       o2trim_speed_flag_set_cmp_ramc0
o2trim_speed_flag_set_goto_o2trim_gate:     J       o2trim_gate_common2
knockretard2_clamp_load_8:     LB      A, #008h
                JBS     off(00223h).4, knockretard2_clamp_cmp_ram243
                LB      A, #015h
knockretard2_clamp_cmp_ram243:     CMPB    A, off(00243h)
                MB      off(00223h).4, C
                CLRB    A
                CMPB    (001cah-00180h)[USP], #001h
                J       knockretard2_clamp_branch
tpsaccel_ignitioncut_branch:     JGE     tpsaccel_ignitioncut_cmp_ram12c
                CLRB    A
tpsaccel_ignitioncut_cmp_ram12c:     CMPB    A, off(0012ch)
                J       tpsaccel_ignitioncut_carry_to_bit0
tps_hysteresis_store_carry_to_bit7:     MB      off(00126h).7, C
                STB     A, r0
                LB      A, #047h
                JBS     off(00127h).7, tps_hysteresis_store_cmp_r0
                LB      A, #05ah
tps_hysteresis_store_cmp_r0:     CMPB    A, r0
                MB      off(00127h).7, C
                LB      A, r0
                JLT     tps_hysteresis_store_goto_rpm_threshold
                JBS     off(00126h).7, tps_hysteresis_store_goto_rpm_threshold
                J       tps_hysteresis_store_sub_a
tps_hysteresis_store_goto_rpm_threshold:     J       rpm_threshold_adjust
fuelcut_tps_recheck_load_rama9:     LB      A, 0a9h
                CMPB    A, #060h
                JBS     off(00116h).3, fuelcut_tps_recheck_goto_to_fuelcut
                CMPB    A, #010h
fuelcut_tps_recheck_goto_to_fuelcut:     J       to_fuelcut_clear_active_flag
rpm_decel_counter_set_r1:     MOVB    r1, off(0017eh)
                CMPB    r1, #000h
                J       rpm_decel_counter_branch
idle_step_flag_store:     ST      A, off(0026eh)
                L       A, DP
                JBS     off(0021ah).0, idle_step_flag_store_store_ram258
                LB      A, coolantTempByte
                MOV     X1, #idle_step_flag_store_interp_tbl
                VCAL    1
                MOV     X2, #idle_step_flag_store_data
idle_step_flag_store_store_ram258:     STB     A, off(00258h)
                MOV     X1, X2
                J       idle_duty_table_lookup_diff
idle_flag_gate_set_ram22b_bit1:     SB      off(0022bh).1
                RB      PSWL.4
                J       idle_flag_gate_if_ram228_bit5_set
idle_flag_gate_set_pswl_bit4:     SB      PSWL.4
                JBR     off(00228h).0, idle_flag_gate_goto
                J       idle_mode_gate5
idle_flag_gate_goto:     J       idle_mode_gate6_load_ram278
idle_mode_gate6_if_ram216_bit3_clr:     JBR     off(00216h).3, idle_mode_gate6_clear_er3
                JBS     off(00211h).5, idle_mode_gate6_clear_er3
                JBR     off(00228h).3, idle_mode_gate6_clear_er3
                J       idle_mode_gate6_store_er3
idle_mode_gate6_clear_er3:     CLR     er3
                MB      C, PSWL.4
                JGE     idle_mode_gate6_vcal6
                J       idle_mode_gate6_cmp_ram2dc
                DB  000h
idle_mode_gate6_branch:     JNE     idle_mode_gate6_vcal6
idle_mode_gate6_goto:     J       idle_mode_gate6_set_x2
                DB  000h
idle_mode_gate6_set_ram2dc:     MOVB    off(002dch), #014h
idle_mode_gate6_vcal6:     VCAL    6
idle_mode_gate5_store_er3:     ST      A, er3
                MOV     DP, #0030ch
                L       A, [DP]
                J       idle_mode_gate5_vcal6
idle_stall_check2_branch:     JGE     idle_stall_check2_goto_idle_vcal5_report
                LB      A, off(002dch)
                JNE     idle_stall_check2_goto_idle_vcal5_report
                LB      A, 0a4h
                J       idle_stall_check2_ptr_tbl_idle_stall
idle_stall_check2_goto_idle_vcal5_report:     J       idle_vcal5_report
select_dp_3d9_3d6_flag_222_6:     LB      A, [DP]
                CMPB    A, #0fah
                JGE     select_dp_3d9_3d6_goto_div_scale_default
                SUBB    A, #007h
                J       select_dp_3d9_3d6_branch
select_dp_3d9_3d6_goto_div_scale_default:     J       div_scale_default
                DB  0C4h,02Ah,02Bh,0D9h,027h,003h,0C4h,026h
                DB  02Ch,0CAh,003h,003h,080h,02Bh,003h,05Ah
                DB  02Bh
fuelcut_output_flags_load_ramc4:     LB      A, 0c4h
                CMPB    A, #082h
                JBS     off(00129h).5, tps_hysteresis_reentry
                CMPB    A, #07ah
tps_hysteresis_reentry:     MB      off(00129h).5, C
                ANDB    PSWL, #0cfh
                J       tps_hysteresis_reentry_set_r2
postig_threshold_if_ram117_bit6_clr:     JBR     off(00117h).6, postig_rpm_compare
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
                JGT     postig_rpm_compare_goto
                J       postig_rpm_compare_cmp_ramc1
postig_rpm_compare_goto:     J       ignmap2_rpm_gate_clear_a
ignition_timing_calc_mul_4:     MUL
                SLL     A
                ROL     er1
                JGE     ignition_timing_calc_load_ram29a
                MOV     er1, #0ffffh
ignition_timing_calc_load_ram29a:     L       A, off(0029ah)
                J       ignition_timing_calc_test_pswl_bit4
                DB  0D5h,0F0h,0D5h,0EEh,0C4h,032h,00Fh,003h
                DB  0FBh,039h
nmi_enter_lowpower_seq_load_rameb:     LB      A, 0ebh
                JNE     nmi_enter_lowpower_seq_brk_reset
                MOVB    0ebh, #047h
nmi_enter_lowpower_seq_brk_reset:     BRK
cfgvariant_check_232h_call_cfgvariant:     CAL     cfgvariant_ram_init_0x300
                ANDB    off(00232h), #0fch
                J       restore_trapstate_after_ramclear
table_select_6221_if_ram218_bit0_set:     JBS     off(00218h).0, table_select_6221_goto_knockwindow_clear
                CMPB    0b4h, #005h
                JLT     table_select_6221_goto
                MOV     X1, #tbl_ignmap2_hi
                LB      A, off(00236h)
                VCAL    0
                ADDB    A, #010h
                JGE     table_select_6221_cmp_ram235
                LB      A, #0ffh
table_select_6221_cmp_ram235:     CMPB    A, off(00235h)
                JGE     table_select_6221_goto_knockwindow_clear
table_select_6221_goto:     J       table_select_6221_load_stk
table_select_6221_goto_knockwindow_clear:     J       knockwindow_clear
diag_store_3ae_ptr_39a:     MOV     DP, #0039ah
                STB     A, [DP]
                LB      A, 0b4h
                JBR     off(00214h).0, diag_store_39f
                CLRB    A
diag_store_39f:     MOV     DP, #003d6h
                STB     A, [DP]
                J       diag_store_39f_ptr_39b
callhelper_table_ptr_dat_dualmap:     MOV     X1, #callhelper_table_interp_tbl
                LB      A, off(00236h)
                VCAL    0
                CMPB    A, 0bbh
                MB      off(00231h).6, C
                L       A, off(00212h)
                AND     A, #08074h
                J       callhelper_table_branch
tipin_gate_pass_load_ram24f:     LB      A, off(0024fh)
                EXTND
                LCB     A, dat_dualmap_dispatch_jump_5b2e[ACC]
                MOVB    off(0024eh), A
                MOV     X1, #tipin_gate_pass_data
                J       tipin_gate_pass_load_ram236
tipin_decay_check_if_ram21b_bit6_set:     JBS     off(0021bh).6, tipin_decay_gate2
                CMP     0aeh, #00010h
                JLT     tipin_decay_gate3
                RB      off(00232h).4
tipin_decay_common:     RC
                SJ      tipin_decay_common_goto
tipin_decay_gate2:     CMP     0aeh, #00003h
                JGE     tipin_decay_gate4
tipin_decay_gate3:     JBS     off(00232h).4, tipin_decay_common
tipin_decay_gate3_set_carry:     SC
                SJ      tipin_decay_common_goto
tipin_decay_gate4:     SB      off(00232h).4
                SJ      tipin_decay_gate3_set_carry
tipin_decay_common_goto:     J       tipin_decay_common_carry_to_ram232_bit5
tipin_gate_fail_clr_ram220_bit0:     RB      off(00220h).0
                RB      off(00232h).4
                J       tipin_gate2_clear_a
callhelper_knock_244_load_ramb9:     LB      A, 0b9h
                MOV     X1, #callhelper_knock_244_interp_tbl
                VCAL    0
                MOVB    r0, off(00237h)
                MULB
                L       A, ACC
                SLL     A
                MOVB    r6, ACCH
                CLRB    r7
                CLR     A
                J       ign_sum_stage1
dat_dualmap_dispatch_jump_5b2e        EQU     $-1
                DB  001h,004h,004h,002h,001h
callhelper_knock_244_interp_tbl:       DB  0FFh,080h,04Dh,080h,040h,05Ah,030h,026h
                DB  028h,000h,000h,000h
injtimer_sub_common:     CMPB    coolantTempByte, #044h
                JLT     injtimer_sub_common_goto_injtimer_gate
                JBR     off(00125h).6, injtimer_sub_common_goto_injtimer_gate
                J       injtimer_sub_common_if_ram125_bit7_clr
injtimer_sub_common_goto_injtimer_gate:     J       injtimer_gate_common
idle_vcal5_call3_load_ram27c:     L       A, off(0027ch)
                JNE     idle_vcal5_call3_goto_idle_vcal5_2
                L       A, off(00270h)
                JNE     idle_vcal5_call3_goto_idle_vcal5_2
                J       idle_vcal5_call3_goto_2
idle_vcal5_call3_goto_idle_vcal5_2:     J       idle_vcal5_report
dwell_rpm_gate3_set_r0:     MOVB    r0, off(00173h)
                CMPB    off(0012dh), #080h
                JLT     dwell_rpm_gate3_goto
                MOVB    r0, off(001eeh)
dwell_rpm_gate3_goto:     J       dwell_rpm_gate3_set_r1
threshold_bank_223_2_store_r2_3:     STB     A, r2
                MOV     X1, #threshold_bank_223_2_interp_tbl
                JBS     off(00216h).3, threshold_bank_223_2_vcal0_5
                MOV     X1, #threshold_bank_223_2_interp_tbl_2
threshold_bank_223_2_vcal0_5:     VCAL    0
                STB     A, (001eeh-00180h)[USP]
                LB      A, r2
                MOV     X1, #threshold_bank_223_2_data_2
                J       threshold_bank_223_2_vcal1
threshold_bank_223_2_interp_tbl:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,018h,000h,018h
threshold_bank_223_2_interp_tbl_2:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,020h,028h,014h,000h,014h
postfuel_hyst_lower_call_clamp_diff_15b:     CAL     clamp_diff_15b_1ec
                J       cylinder_ign_correct_goto
to_injtimer_sub_common:     LB      A, #040h
                JBS     off(00129h).3, to_injtimer_sub_common_cmp_ram12d_2
                LB      A, #04dh
to_injtimer_sub_common_cmp_ram12d_2:     CMPB    A, off(0012dh)
                MB      off(00129h).3, C
                LB      A, #0f2h
                JBS     off(00129h).4, to_injtimer_sub_common_cmp_ram12c
                LB      A, #0f9h
to_injtimer_sub_common_cmp_ram12c:     CMPB    A, off(0012ch)
                MB      off(00129h).4, C
                LB      A, off(0015eh)
                JBS     off(0011dh).4, to_injtimer_sub_common_goto
                J       to_injtimer_sub_common_load_40
to_injtimer_sub_common_goto:     J       to_injtimer_sub_common_store_ram153
to_injtimer_sub_common_store_r7:     STB     A, r7
                JBS     off(0011dh).0, to_injtimer_sub_common_load_ram12c
                CMP     off(0014ah), #03000h
                JGE     to_injtimer_sub_common_call_clamp_diff
                JBR     off(00129h).3, to_injtimer_sub_common_call_clamp_diff
                JBS     off(00129h).4, to_injtimer_sub_common_call_clamp_diff
                LB      A, 0a8h
                JBR     off(0011bh).4, to_injtimer_sub_common_if_ram11b_bit1
                CMPB    A, #003h
                JGE     to_injtimer_sub_common_call_clamp_diff
to_injtimer_sub_common_if_ram11b_bit1:     JBR     off(0011bh).1, to_injtimer_sub_common_load_ram1ed
                LB      A, #004h
                JBS     off(00116h).3, to_injtimer_sub_common_cmp_rambd
                LB      A, #004h
to_injtimer_sub_common_cmp_rambd:     CMPB    A, 0bdh
                JGE     to_injtimer_sub_common_load_ram1ed
to_injtimer_sub_common_call_clamp_diff:     CAL     clamp_diff_15b_1ec
                SJ      to_injtimer_sub_common_load_ram12c
to_injtimer_sub_common_load_ram1ed:     LB      A, off(001edh)
                MOVB    r0, #0fah
                MULB
                LB      A, ACCH
                STB     A, off(001edh)
                ADDB    A, off(001ech)
                STB     A, r7
to_injtimer_sub_common_load_ram12c:     LB      A, off(0012ch)
                J       to_injtimer_sub_common_call_table
threshold_bank_223_2_vcal1_2:     VCAL    1
                STB     A, (001e8h-00180h)[USP]
                LB      A, coolantTempByte
                MOV     X1, #threshold_bank_223_2_interp_tbl_3
                VCAL    0
                STB     A, (001ech-00180h)[USP]
                J       threshold_bank_223_2_vcal4

;--------------------------------------------------------------------------------------------
; clamp_diff_15b_1ec  @0x5C13
;   VERIFIED: computes off(15Bh)-off(1ECh), clamps negative results to 0, stores to
;   off(1EDh). Sits immediately before threshold_bank_223_2_interp_tbl_3, called via VCAL - likely an
;   axis-prep clamp feeding that table's lookup, matching the pattern already validated
;   for the TPS/RPM scaler axes.
;--------------------------------------------------------------------------------------------
clamp_diff_15b_1ec:     LB      A, off(0015bh)
                SUBB    A, off(001ech)
                JGE     clamp_diff_15b_1ec_store_ram1ed
                CLRB    A
clamp_diff_15b_1ec_store_ram1ed:     STB     A, off(001edh)
                RT

;--------------------------------------------------------------------------------------------
; threshold_bank_223_2_interp_tbl_3  @0x5C1D
;   TRACED: referenced at 0x5C0A, immediately before clamp_diff_15b_1ec (0x5C13) - part of
;   the same axis-prep sequence. Earlier auto-attribution to boot_completion_helper
;   was a nearest-preceding-entry artifact, corrected here.
;--------------------------------------------------------------------------------------------
threshold_bank_223_2_interp_tbl_3:       DB  0FFh,060h,0E6h,052h,0CFh,051h,0A1h,050h
                DB  044h,041h,028h,040h,000h,040h

;--------------------------------------------------------------------------------------------
; axis_clamp_c1_selector  @0x5C2B
;   TRACED: loads 0x8000 sentinels into A/er1, conditionally reloads them again if
;   off(116h).3 is set, then compares RAM 0xC1 against 0x40 (64) and jumps into shared
;   axis-handling code at vemap_do_lookup_b101. An axis-selection guard ahead of a table
;   lookup, in the same family as the other 0xC1-gated axis logic traced earlier
;   (threshold_bank_223_2_interp_tbl_3).
;--------------------------------------------------------------------------------------------
axis_clamp_c1_selector:     L       A, #08000h
                MOV     er1, #08000h
                JBS     off(00116h).3, axis_clamp_c1_selector_cmp_ramc1
                L       A, #08000h
                MOV     er1, #08000h
axis_clamp_c1_selector_cmp_ramc1:     CMPB    coolantTempByte, #040h
                J       axis_clamp_c1_selector_branch
cylinder_ign_correct_load_c5:     LB      A, #0c5h
                JBS     off(00124h).5, cylinder_ign_correct_cmp_ram12d
                LB      A, #0c8h
cylinder_ign_correct_cmp_ram12d:     CMPB    A, off(0012dh)
                MB      off(00124h).5, C
                LB      A, off(00135h)
                JNE     cylinder_ign_correct_goto_deadtime
                J       cylinder_ign_correct_load_5
cylinder_ign_correct_goto_deadtime:     J       deadtime_retry_check
to_gio_mode_dispatch_sub_r6:     SUBB    A, r6
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
tipin_decay_store_carry_to_ram220_bit1:     MB      off(00220h).1, C
                LB      A, #000h
                JBS     off(00225h).3, knock244_threshold_check
                LB      A, #00bh
knock244_threshold_check:     CMPB    A, off(00243h)
                MB      off(00225h).3, C
                MOVB    r0, #040h
                MOVB    r1, #003h
                MOVB    r2, #02ah
                MOVB    r3, #00ch
                JGE     knock244_threshold_if_ram212_bit6_set
                MOVB    r0, #040h
                MOVB    r1, #006h
                MOVB    r2, #033h
                MOVB    r3, #00ch
knock244_threshold_if_ram212_bit6_set:     JBS     off(00212h).6, store_255_result_load_r2
                JBS     off(0021dh).4, store_255_result_load_r2
                CMPB    coolantTempByte, #034h
                JGE     store_255_result_load_r2
                LB      A, r0
                CMPB    A, off(00236h)
                JLT     store_255_result_load_r2
                JBS     off(00231h).6, store_255_result_load_r2
                CLRB    A
                JBR     off(0021bh).1, store_255_result
                CMPB    0bdh, #020h
                JLT     store_255_result
                LB      A, r1
                ADDB    A, #001h
store_255_result:     STB     A, off(002fbh)
store_255_result_load_r2:     LB      A, r2
                CMPB    off(002fbh), #000h
                JNE     store_255_result_dec_ram2fb
                LB      A, off(002fah)
                SUBB    A, r3
                JGE     store_255_result_store_ram2fa
                CLRB    A
                SJ      store_255_result_store_ram2fa
store_255_result_dec_ram2fb:     DECB    off(002fbh)
store_255_result_store_ram2fa:     STB     A, off(002fah)
                J       store_255_result_if_ram216_bit3_set
ign_sum_stage1_load_ram2fa:     LB      A, off(002fah)
                ADD     er3, A
                L       A, er3
                VCAL    7
                ST      A, er3
                J       ign_sum_negate
idle_integrator_final_if_ram211_bit5_clr:     JBR     off(00211h).5, idle_integrator_final_goto_2
                CMPB    coolantTempByte, #03ah
                JLT     idle_integrator_final_clear_a
                L       A, off(00264h)
                SUB     A, #00040h
                JGE     idle_integrator_final_goto
idle_integrator_final_clear_a:     CLR     A
                J       to_idle_output_finalize
idle_integrator_final_goto:     J       load_x2_result_store_ram264
idle_integrator_final_goto_2:     J       idle_integrator_final_cmp_ramc1
idle_sub_gate2_if_ram216_bit3_set:     JBS     off(00216h).3, idle_sub_gate2_cmp_dp
                JBR     off(0021ah).3, idle_sub_gate2_cmp_dp
                JBR     off(00218h).2, idle_sub_gate2_cmp_dp
                MOV     X1, #00a00h
                JBR     off(00211h).2, idle_sub_gate2_cmp_x1
                MOV     X1, #00b00h
idle_sub_gate2_cmp_x1:     CMP     A, X1
                JGE     idle_sub_gate2_cmp_dp
                L       A, X1
idle_sub_gate2_cmp_dp:     CMP     A, DP
                JLT     idle_sub_gate2_goto_idle_sub_final_sto
                J       idle_sub_alt_path
idle_sub_gate2_goto_idle_sub_final_sto:     J       idle_sub_final_store
idle_timer_gate1_if_ram218_bit2_clr:     JBR     off(00218h).2, idle_timer_gate1_goto_idle_timer_gate_co
                CLRB    off(002d6h)
                MOVB    r0, #028h
                J       idle_timer_gate1_if_ram21a_bit5_set
idle_timer_gate1_goto_idle_timer_gate_co:     J       idle_timer_gate_common
idle_table_lookup3_load_ram258:     L       A, off(00258h)
                CAL     table_interp_lookup_4byte
                CMP     A, 0b2h
                J       idle_table_lookup3_branch
tbl_idle_default1:       DB  0FFh,0FFh,06Bh,000h,035h,00Ch,06Bh,000h
                DB  0C4h,009h,044h,000h,00Bh,009h,03Ah,000h
                DB  053h,007h,026h,000h,04Eh,004h,00Eh,000h
                DB  000h,000h,00Eh,000h
tbl_idle_default2:       DB  0FFh,0FFh,095h,000h,035h,00Ch,095h,000h
                DB  0C4h,009h,061h,000h,00Bh,009h,053h,000h
                DB  053h,007h,037h,000h,04Eh,004h,013h,000h
                DB  000h,000h,013h,000h
idle_table_lookup4_ptr_dat_axis_clamp:     MOV     X1, #idle_table_lookup4_interp_tbl
                L       A, off(00258h)
                CAL     table_interp_lookup_4byte
                J       idle_table_lookup4_if_ram21a_bit5_clr
idle_table_lookup4_interp_tbl:       DB  0FFh,0FFh,0F1h,000h,035h,00Ch,0F1h,000h
                DB  0C4h,009h,09Dh,000h,00Bh,009h,087h,000h
                DB  053h,007h,05Ah,000h,04Eh,004h,01Fh,000h
                DB  000h,000h,01Fh,000h
tps_interp_store_set_er0:     MOV     er0, #00300h
                JGE     rpm_avg_range_check
                VCAL    7
                MOV     er0, #00300h
rpm_avg_range_check:     CMP     A, er0
                JLT     rpm_avg_range_check_goto
                L       A, er0
rpm_avg_range_check_goto:     J       rpm_avg_range_check_store_ramb2
idle_flag_gate_load_ram2dc:     LB      A, off(002dch)
                JNE     idle_flag_gate_set_ram286
                RB      off(00222h).7
idle_flag_gate_set_ram286:     MOV     off(00286h), off(00284h)
                J       idle_flag_gate_set_ram289
idle_mode_gate6_if_ram22b_bit3_clr:     JBR     off(0022bh).3, idle_mode_gate6_goto_idle_pi_mul1
                CMPB    coolantTempByte, #0d0h
                JLT     idle_mode_gate6_goto_2
                CMPB    0e9h, #0fah
                JLT     idle_mode_gate6_goto_idle_pi_mul1
idle_mode_gate6_goto_2:     J       idle_mode_gate6_if_ram229_bit6_clr
idle_mode_gate6_goto_idle_pi_mul1:     J       idle_pi_mul1
idle_mode_gate6_cmp_ram2dc:     CMPB    off(002dch), #000h
                JEQ     idle_mode_gate6_goto_3
                SB      off(00222h).7
                J       idle_mode_gate6_branch
idle_mode_gate6_goto_3:     J       idle_mode_gate6_goto
idle_mode_gate6_set_x2:     MOV     X2, A
                LB      A, 0c0h
                MOV     X1, #idle_mode_gate6_interp_tbl
                CAL     table_interp_search_stride3
                L       A, X2
                J       idle_mode_gate6_set_ram2dc
idle_mode_gate6_interp_tbl:       DB  0FFh,000h,000h,0C0h,000h,000h,0A0h,040h
                DB  001h,080h,080h,001h,030h,000h,002h,000h
                DB  000h,003h
battery_voltage_check_carry_to_bit3:     MB      off(0021ah).3, C
                LB      A, 0c4h
                STB     A, r0
                XCHGB   A, 0f8h
                SUBB    A, r0
                MB      off(00225h).2, C
                JGE     battery_voltage_store
                VCAL    7
battery_voltage_store:     STB     A, 0f9h
battery_voltage_store_goto:       J       battery_voltage_store_ptr_dat_fuel
idle_pid_mul_apply_store_r1:     STB     A, r1
                MOV     X1, #idle_pid_mul_apply_interp_tbl
                LB      A, coolantTempByte
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
idle_pid_mul_apply_interp_tbl:       DB  0FFh,0C0h,0A1h,0C0h,044h,0A0h,028h,080h,000h,080h
idle_pid_recheck2_if_ram217_bit6_clr:     JBR     off(00217h).6, idle_pid_hyst_check
                LB      A, #028h
                CLRB    r1
                JBS     off(00225h).2, idle_pid_recheck2_set_r2
                LB      A, #028h
                MOVB    r1, #000h
idle_pid_recheck2_set_r2:     MOVB    r2, 0f9h
                     MB      C, off(00225h).2
idle_pid_hyst_check:     MB      PSWL.4, C
                CMPB    A, r2
                J       idle_pid_hyst_check_if_ge_goto_idle_pid_common
idle_pid_hyst_check_load_carry_pswl_bit4:     MB      C, PSWL.4
                JLT     idle_pid_p0_check
                LB      A, off(00297h)
                JEQ     idle_pid_flag_store
                SJ      idle_pid_flag_store_goto
idle_pid_p0_check:     MB      C, P0.2
                JLT     idle_pid_flag_store_goto
idle_pid_flag_store:     MOVB    off(00297h), r1
idle_pid_flag_store_goto:     J       idle_pid_flag_store_clear_r5
idle_ectvs_result1:     JBR     off(00227h).1, idle_ectvs_result1_if_ram22a_bit3_clr
                JBR     off(00226h).4, idle_ectvs_result1_goto_2
                SJ      idle_ectvs_result1_goto
idle_ectvs_result1_if_ram22a_bit3_clr:     JBR     off(0022ah).3, idle_ectvs_result1_if_ram225_bit1_clr
                MOVB    off(002ddh), #014h
                MOVB    off(002deh), #05ah
idle_ectvs_result1_goto:     J       idle_ectvs_result1_set_r1
idle_ectvs_result1_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_result1_goto_2
                LB      A, off(002ddh)
                JNE     idle_ectvs_result1_goto
idle_ectvs_result1_goto_2:     J       idle_ectvs_result1_cmp_r1
idle_ectvs_flag_check_if_ram22a_bit4_clr:     JBR     off(0022ah).4, idle_ectvs_flag_check_if_ram225_bit1_clr
                MOVB    off(002deh), #05ah
idle_ectvs_flag_check_goto_idle_ectvs:     J       idle_ectvs_result2
idle_ectvs_flag_check_if_ram225_bit1_clr:     JBR     off(00225h).1, idle_ectvs_flag_check_goto
                LB      A, off(002deh)
                JNE     idle_ectvs_flag_check_goto_idle_ectvs
idle_ectvs_flag_check_goto:     J       idle_ectvs_flag_check_if_ram216_bit3_clr
knock_324_bit_store_test_ram211_bit1:     MB      C, off(00211h).1
                XORB    PSWH, #080h
                J       knock_324_bit_store_rol_a
knock_324_bit_store_test_ram210_bit3:     MB      C, off(00210h).3
                XORB    PSWH, #080h
                J       knock_324_bit_store_rol_a_2
knock_324_bit_store_test_p4_bit6:     MB      C, P4.6
                XORB    PSWH, #080h
                J       knock_324_bit_store_rol_a_3
knock_324_bit_store_test_p0_bit5_2:     MB      C, P0.5
                ROLB    A
                ROLB    A
                MOV     DP, #003a1h
                J       knock_324_bit_store_store_ind
diag_mode_code_store_if_ram216_bit3_clr:     JBR     off(00216h).3, diag_mode_code_store_test_ram227_bit5
                LCB     A, diag_mode_code_store_const
                SLLB    A
                ROLB    r0
                ROLB    r0
diag_mode_code_store_test_ram227_bit5:     MB      C, off(00227h).5
                J       diag_mode_code_store_rol_r0
                DB  000h
boot_flag_baro_common_test_ram216_bit2:     MB      C, off(00216h).2
                LCB     A, CFG_flag_216_2_and_5
                J       boot_flag_baro_common_branch
diag_mode_code_store_const:       DB  000h
o2_trim_tps_mode_check_if_ram11c_bit2:     JBR     off(0011ch).2, o2_trim_tps_mode_check_goto_o2_trim_alt
                MOVB    off(00197h), #00ah
                J       o2_trim_alt_path_check_set_ram16c
o2_trim_tps_mode_check_goto_o2_trim_alt:     J       o2_trim_alt_path_check
o2trim_speed_flag_set_test_p1_bit6:     MB      C, P1.6
                JLT     o2trim_speed_flag_set_load_ram197
                J       o2trim_gate_common2
o2trim_speed_flag_set_load_ram197:     LB      A, off(00197h)
                J       o2trim_speed_flag_set_branch
idle_vcal5_call3_load_ram266:     L       A, off(00266h)
                JNE     idle_vcal5_call3_goto_idle_vcal5_3
                J       idle_vcal5_call3_cmp_rama6
idle_vcal5_call3_goto_idle_vcal5_3:     J       idle_vcal5_report
ignition_timing_calc_load_rambd:     LB      A, 0bdh
                JBS     off(0021bh).1, ignition_timing_calc_cmp_20
                CMPB    A, #010h
                JGT     ignition_timing_calc_goto_9
ignition_timing_calc_cmp_20:     CMPB    A, #020h
                J       ignition_timing_calc_branch_2
ignition_timing_calc_goto_9:     J       ignition_timing_calc_set_ram2d2
div_scale_store_ptr_4:     MOV     X1, #00004h
                JBS     off(00216h).3, div_scale_store_goto_gear_detect_store
                LB      A, #001h
                J       div_scale_store_clear_x1
div_scale_store_goto_gear_detect_store:     J       gear_detect_store
o2trim_speed_flag_set_cmp_er1:     CMP     A, er1
                JLE     o2trim_speed_flag_set_store_er1
                L       A, #tbl_idle_pi_clamp
                CMP     A, er1
                JLT     o2trim_speed_flag_set_load_dat_engine
                JBS     off(00117h).3, o2trim_speed_flag_set_load_dat_engine
                CMPB    ECT_raw, #0ffh
                JGT     o2trim_speed_flag_set_clr_pswl_bit4
                JBR     off(00118h).0, o2trim_speed_flag_set_load_dat_engine
                J       o2trim_speed_flag_set_clr_pswl_bit4
                DB  000h,000h,000h,000h,000h,000h
o2trim_speed_flag_set_clr_pswl_bit4:     RB      PSWL.4
o2trim_speed_flag_set_load_dat_engine:     L       A, #05e20h
                CMP     A, er1
                JLT     o2trim_speed_flag_set_goto
o2trim_speed_flag_set_store_er1:     ST      A, er1
o2trim_speed_flag_set_goto:     J       o2trim_speed_flag_set_test_pswl_bit4
dcode_gate_common_if_ram216_bit3_clr:     JBR     off(00216h).3, dcode_gate_common_goto
                JBS     off(00214h).2, dcode_gate_common_goto
                J       dcode_gate_common_ptr_380
dcode_gate_common_goto:     J       dcode_gate_common_load_25
                DB  0EBh,01Dh,006h,0ECh,01Eh,003h,003h,0D5h
                DB  03Dh,003h,0E4h,03Dh
crank_tooth_count_test_ram113_bit6:     MB      C, off(00113h).6
                MB      off(00122h).1, C
                J       crank_tooth_count_if_ram120_bit2_set
vcal3_leanprotect_clr_stk_bit2:     RB      (00122h-00180h)[USP].2
                JBR     off(00216h).7, vcal3_leanprotect_goto
                J       vcal3_leanprotect_clr_ram9e_bit6
vcal3_leanprotect_goto:     J       vcal3_leanprotect_clr_ram9e_bit4
idle_init_start_clr_stk_bit2:     RB      (00122h-00180h)[USP].2
                CAL     idle_helper1
                J       idle_init_start_set_er0
coldstart_full_reset_and_p1:     ANDB    P1, #0fch
                CLR     off(00268h)
                J       coldstart_full_reset_goto
coldstart_full_reset_store_ramf0:     ST      A, 0f0h
                ST      A, 0eeh
                ANDB    (0011fh-00180h)[USP], #0f9h
                ANDB    off(0021fh), #0f9h
                RB      off(00232h).7
                J       warmrestart_tm3_resync
dtc13_baro_latch:     MB      099h.2, C
                VCAL    4
                J       dcode14_check_if_ram217_bit5_set
gear_detect_store_set_stk:     MOV     (0017ah-00180h)[USP], A
                VCAL    4
                J       gear_detect_store_ptr_tbl_knockwindow_4
gear_detect_store_set_stk_2:     MOV     (001eah-00180h)[USP], A
                VCAL    4
                J       threshold_bank_223_2
vss_band_dispatch:     MB      P0.1, C
                VCAL    4
                J       vss_band_dispatch_set_r2
altc_gio_override_vcal4:     VCAL    4
                JBS     off(00227h).3, altc_gio_override_goto
                J       altc_gio_override_if_ram216_bit3_clr
altc_gio_override_goto:     J       altc_disable_check_nop
calchecksum_loop_vcal4:     VCAL    4
                CAL     cfgvariant_checksum2_calc
                J       calchecksum_loop_inc_dp
freezeframe_decode_load_ram212:     L       A, off(00212h)
                ORB     A, off(00214h)
                J       freezeframe_decode_add_ffff
injector_timer_load_tm0:     L       A, TM0
                SUB     A, #00001h
                ST      A, TMR0
                MOV     X1, #001b8h
                J       injector_timer_ptr_1c0
inj_accum1_add_add_ram1b8:     ADD     A, off(001b8h)
                CMP     A, #00100h
                JGE     inj_accum1_add_store_ram1b8
                CLR     A
inj_accum1_add_store_ram1b8:     ST      A, off(001b8h)
                CLR     A
                ST      A, off(001bah)
                J       inj_accum_store_114
                DB  0FFh
tbl_idle_pi_clamp:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_unused_216_4  @0x6001
;   Sets off(216).4. No other reference in ROM - dead switch.
;--------------------------------------------------------------------------------------------
CFG_unused_216_4:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_flag_227_6  @0x6002
;   Sets off(227).6; tested 0x0A95, 0x0CD5, 0x27F7, 0x3D44.
;--------------------------------------------------------------------------------------------
CFG_flag_227_6:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_216_6  @0x6003
;   Sets off(216).6; tested 0x41A5, 0x41B7, 0x44A4.
;--------------------------------------------------------------------------------------------
CFG_flag_216_6:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_227_4  @0x6004
;   Sets off(227).4; tested 0x3C2A; in capability byte at 0x4930.
;--------------------------------------------------------------------------------------------
CFG_flag_227_4:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_219_1  @0x6005
;   Sets off(219).1; 7 sites; output/diagnostic gate.
;--------------------------------------------------------------------------------------------
CFG_flag_219_1:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_217_3  @0x6006
;   Sets off(217).3; single gate at 0x785D.
;--------------------------------------------------------------------------------------------
CFG_flag_217_3:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_flag_227_7  @0x6007
;   Sets off(227).7; single gate at 0x0BF7.
;--------------------------------------------------------------------------------------------
CFG_flag_227_7:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_unused_216_1  @0x6008
;   Sets off(216).1. No other reference in ROM - dead switch.
;--------------------------------------------------------------------------------------------
CFG_unused_216_1:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_flag_216_7  @0x6009
;   Sets off(216).7 and RAM 0x0354 bit 0; tested 0x0A3D, 0x5F80.
;--------------------------------------------------------------------------------------------
CFG_flag_216_7:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_227_1  @0x600A
;   Sets off(227).1; tested 0x43F3, 0x44D0, 0x5E77.
;--------------------------------------------------------------------------------------------
CFG_flag_227_1:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_216_2_and_5  @0x600B
;   Drives BOTH off(216).2 and off(216).5; read directly at 0x48EC/0x4902/0x5685.
;--------------------------------------------------------------------------------------------
CFG_flag_216_2_and_5:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_227_3  @0x600C
;   Sets off(227).3; tested 0x3EA8, 0x45C5, 0x4855, 0x5FCB.
;--------------------------------------------------------------------------------------------
CFG_flag_227_3:       DB  000h

;--------------------------------------------------------------------------------------------
; diag_snapshot_copy_const  @0x600D
;   Read directly at 0x48E6 and 0x5957 in the report-byte path.
;--------------------------------------------------------------------------------------------
diag_snapshot_copy_const:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_219_4  @0x600E
;   Sets off(219).4; read at 0x48F2/0x4908/0x568B.
;--------------------------------------------------------------------------------------------
CFG_flag_219_4:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_flag_227_5  @0x600F
;   Sets off(227).5; tested 0x76A4, 0x76B0.
;--------------------------------------------------------------------------------------------
CFG_flag_227_5:       DB  000h

;--------------------------------------------------------------------------------------------
; store_255_result_const  @0x6010
;   Read at 0x0E72.
;--------------------------------------------------------------------------------------------
store_255_result_const:       DB  0FFh

;--------------------------------------------------------------------------------------------
; idle_init_start_const  @0x6011
;   Read at 0x285A and 5 other sites.
;--------------------------------------------------------------------------------------------
idle_init_start_const:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_DualMapSelect  @0x6012
;   PRIMARY DUAL CALIBRATION MAP SELECT. 38 test sites; swaps 11+ table pairs.
;--------------------------------------------------------------------------------------------
CFG_DualMapSelect:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_DualMapSelect_alt  @0x6013
;   Alternate source for off(216).3 when variant selector r0 != 0.
;--------------------------------------------------------------------------------------------
CFG_DualMapSelect_alt:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_MapDimension2  @0x6014
;   Adds +0x18 to X1 after 0x6012 picks the base table (0x4125); 12 sites.
;--------------------------------------------------------------------------------------------
CFG_MapDimension2:       DB  0FFh

;--------------------------------------------------------------------------------------------
; CFG_Selector3  @0x6015
;   Swaps table pair at 0x2C0F, tunable immediates, P0.3 output at 0x439A.
;--------------------------------------------------------------------------------------------
CFG_Selector3:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_216_5_alt  @0x6016
;   Alternate source for off(216).5 (0x5624).
;--------------------------------------------------------------------------------------------
CFG_flag_216_5_alt:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_PSWL4  @0x6017
;   Written to CPU flag PSWL.4, not a RAM bit (0x5646).
;--------------------------------------------------------------------------------------------
CFG_flag_PSWL4:       DB  000h
boot_flag_gearpreset_const:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_227_2  @0x6019
;   Sets off(227).2; tested 0x26B8, 0x3C8F, 0x3CA9.
;--------------------------------------------------------------------------------------------
CFG_flag_227_2:       DB  000h
boot_flag_gearpreset_const_2:       DB  000h

;--------------------------------------------------------------------------------------------
; CFG_flag_DP_1  @0x601B
;   Written to a [DP]-relative bit at 0x56B5.
;--------------------------------------------------------------------------------------------
CFG_flag_DP_1:       DB  0FFh
InjectorTable:       DB  00Bh,00Bh,00Bh,006h,006h,008h
tbl_tps_custom_curve:       DB  004h,018h,004h,018h
tbl_tps_custom_curve2:       DB  028h,040h,030h,040h,030h,040h
to_injtimer_sub_common_data:       DB  0D0h,0D0h,064h,051h,0D0h,0D0h,064h,051h
threshold_bank_223_2_interp_tbl_4:       DB  0FFh,05Ah,0E6h,047h,0CFh,045h,0A1h,044h
                DB  044h,042h,028h,041h,000h,040h
threshold_bank_223_2_interp_tbl_5:       DB  0FFh,066h,0E6h,05Eh,0CFh,05Dh,0A1h,05Ch
                DB  044h,04Ch,028h,041h,000h,040h
threshold_bank_223_2_interp_tbl_6:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  044h,040h,02Eh,040h,000h,040h
threshold_bank_223_2_data:       DB  0FFh,066h,0E6h,05Eh,0CFh,05Dh,0A1h,046h
                DB  044h,043h,02Eh,040h,000h,040h
threshold_bank_223_2_interp_tbl_7:       DB  0FFh,080h,0E6h,073h,0CFh,06Ch,0A1h,060h
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
tbl_o2trim_ect_offset:       DB  001h,000h,000h,001h,001h,000h,000h,002h
                DB  001h,000h,000h,004h
tbl_revlimit_cold1:       DB  0AEh,028h,0A1h,034h
tbl_revlimit_cold3:       DB  0B5h,02Eh,0A9h,062h
o2_trim_step_threshold_const:                 DW  00404h
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
ve_adjust2_gate_interp_tbl:       DB  0FFh,050h,0E0h,050h,0D0h,0A0h,0C8h,0D0h
                DB  0C0h,0D8h,04Dh,0EAh,040h,0AEh,000h,0AEh
threshold_bank_223_2_interp_tbl_8:       DB  0FFh,080h,01Fh,080h,018h,080h,013h,08Bh
                DB  00Fh,08Bh,000h,08Bh
ve_and_accel_calc_interp_tbl:       DB  0BCh,033h,0ABh,033h,09Dh,033h,097h,033h
                DB  093h,033h,091h,033h,08Fh,033h,08Bh,033h
                DB  086h,033h,080h,033h,07Dh,033h,076h,033h
tbl_ve_accel_1:       DB  0FFh,088h,0D0h,088h,0C0h,085h,0A0h,080h
                DB  040h,080h,000h,080h
tbl_ve_accel_2:       DB  0FFh,08Ah,08Eh,08Ah,072h,088h,055h,080h
                DB  01Ch,080h,000h,080h
tbl_knockwindow_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
tbl_knockwindow_4:       DB  0FFh,08Eh,0A1h,08Eh,087h,071h,06Eh,05Eh
                DB  034h,04Bh,028h,03Dh,000h,03Dh
gear_detect_store_interp_tbl:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,06Dh
                DB  034h,060h,028h,04Dh,000h,04Dh
gear_detect_store_interp_tbl_2:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,050h
                DB  034h,043h,028h,030h,000h,030h
CylinderIGNCorrect:       DB  080h,080h,080h,080h
tbl_revlimit_warm2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
tbl_injtimer_finalize:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h
InjectorIndex:       DB  0FFh,064h,000h,0A7h,067h,000h,093h,094h
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
threshold_bank_223_2_data_2:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,0A2h,073h
                DB  000h,040h,0D0h,000h,028h,000h,001h,000h
                DB  000h,001h
threshold_bank_223_2_data_3:       DB  0FFh,04Dh,000h,0D0h,04Dh,000h,0A2h,04Dh
                DB  000h,040h,080h,000h,028h,000h,001h,000h
                DB  000h,001h
tbl_tipin_low:       DB  010h,0E6h,000h,002h,000h,001h,050h,0E6h
                DB  000h,008h,000h,001h,050h,0F3h,000h,010h
                DB  000h,001h,050h,0F3h,000h,010h,000h,001h
tbl_revlimit_cold4:       DB  0FFh,080h,000h,080h
threshold_bank_223_2_data_4:       DB  0FFh,08Ah,0C0h,08Ah,060h,040h,040h,026h
                DB  020h,020h,000h,020h
tbl_rpm_decel:       DB  0FFh,008h,000h,08Bh,008h,000h,080h,018h
                DB  000h,060h,050h,000h,040h,070h,000h,020h
                DB  0A0h,000h,000h,0C0h,000h
tbl_revlimit_warm3:       DB  0FFh,07Dh,000h,0CFh,07Dh,000h,0A2h,07Dh
                DB  000h,06Eh,07Dh,000h,000h,07Dh,000h
threshold_bank_223_2_interp_tbl_9:       DB  0FFh,070h,0E6h,060h,0CFh,050h,0A1h,040h
                DB  06Eh,030h,028h,012h,000h,012h
threshold_bank_223_2_interp_tbl_10:       DB  0FFh,090h,0E6h,080h,0CFh,070h,0A1h,040h
                DB  06Eh,030h,028h,012h,000h,012h
threshold_bank_223_2_interp_tbl_11:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
                DB  06Eh,020h,028h,008h,000h,008h
threshold_bank_223_2_interp_tbl_12:       DB  0FFh,040h,0E6h,040h,0CFh,040h,0A1h,040h
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
gear_detect_store_interp_tbl_3:       DB  0FFh,0A0h,0A1h,0A0h,087h,086h,06Eh,07Ah
                DB  034h,060h,028h,059h,000h,059h
gear_detect_store_interp_tbl_4:       DB  0FFh,090h,0A1h,090h,087h,073h,06Eh,060h
                DB  034h,04Dh,028h,03Fh,000h,03Fh
tbl_ignmap2_lo:       DB  0FFh,020h,0E0h,020h,0D0h,01Bh,0C0h,015h
                DB  0A0h,00Fh,000h,00Fh
tbl_ignmap2_hi:       DB  0FFh,018h,0E0h,018h,0D0h,013h,0C0h,00Dh
                DB  0A0h,007h,000h,007h
gear_detect_store_interp_tbl_5:       DB  0FFh,000h,000h,000h,000h
loadindex_lookup_done_interp_tbl:       DB  0FFh,0FFh,000h,000h
loadindex_lookup_done_interp_tbl_2:       DB  0A1h,050h,040h,000h
loadindex_lookup_done_interp_tbl_3:                 DW  0ffe7h
loadindex_lookup_done_const:       DB  030h,050h,0F0h,000h,0EAh,000h,0DCh,000h
                DB  0DCh,000h,0D0h,000h,011h
tbl_knock_index:       DB  033h,073h,09Ah,079h,000h,080h,066h,086h
                DB  0CDh,08Ch,0CDh,08Ch,033h,073h,09Ah,079h
                DB  000h,080h,066h,086h,0CDh,08Ch,0CDh,08Ch
tbl_knock_div:       DB  07Ch,003h,0EBh,003h,05Ah,004h,0CAh,004h
                DB  039h,005h,039h,005h,0D5h,003h,044h,004h
                DB  0B3h,004h,023h,005h,093h,005h,093h,005h
                DB  07Ch,003h,0EBh,003h,05Ah,004h,0CAh,004h
                DB  039h,005h,039h,005h,0D5h,003h,044h,004h
                DB  0B3h,004h,023h,005h,093h,005h,093h,005h
knock_div_calc4_data:       DB  0EBh,003h,05Ah,004h,0CAh,004h,039h,005h
                DB  0A9h,005h,0A9h,005h,039h,005h,0A9h,005h
                DB  018h,006h,088h,006h,0F7h,006h,0F7h,006h
                DB  0EBh,003h,05Ah,004h,0CAh,004h,039h,005h
                DB  0A9h,005h,0A9h,005h,039h,005h,0A9h,005h
                DB  018h,006h,088h,006h,0F7h,006h,0F7h,006h
GearCustom:       DB  050h,000h,07Eh,000h,0AEh,000h,0E9h,000h
crank_edge_flag_store_interp_tbl:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,000h,0FFh
crank_edge_flag_store_const:       DB  0FFh,0FFh,0FFh,0FFh,080h
threshold_bank_217_0_data:       DB  0FFh,0FFh,000h,0FFh
threshold_bank_217_0_interp_tbl:       DB  0FFh,0FFh,000h,0FFh
vss_band_224_0_check_data:       DB  090h,0A0h,00Ch,00Fh,02Dh,02Fh,02Dh,02Fh
                DB  088h,080h,088h,080h,029h,026h
const_0180_target2:       DB  0C7h,0D4h,0C7h,0D4h,0CEh,0D0h,0CEh,0D0h
                DB  0FFh,03Fh,0F8h,03Fh,0F0h,03Fh,0E8h,03Fh
                DB  0D5h,03Fh,0CAh,0AEh,000h,0AEh,0FFh,03Fh
                DB  0F8h,03Fh,0F0h,03Fh,0E8h,03Fh,0DBh,03Fh
                DB  0D6h,0AEh,000h,0AEh
threshold_bank_223_2_interp_tbl_13:       DB  0FFh,000h,000h,000h
ignition_timing_calc_data:       DB  046h,04Bh,02Bh,036h,082h,087h,05Fh,064h
                DB  09Ch,0A1h,00Fh,011h,010h,012h,044h,049h
                DB  022h,025h,039h,041h,014h,016h,028h,02Dh
                DB  05Fh,064h,07Dh,082h,014h,019h,021h,026h
                DB  04Ah,04Ch,036h,050h,0B3h,0C0h
ignition_timing_calc_interp_tbl:       DB  0FFh,001h,09Fh,001h,09Bh,013h,06Eh,013h
                DB  05Ah,013h,041h,005h,000h,005h
ignition_timing_calc_interp_tbl_2:       DB  0FFh,0FAh,0B0h,0FAh,09Bh,0FAh,082h,0FAh
                DB  080h,09Ch,078h,092h,064h,076h,05Ah,069h
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h
ignition_timing_calc_interp_tbl_3:       DB  0FFh,0FAh,0B0h,0FAh,08Eh,0FAh,087h,0FAh
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h
ignition_timing_calc_interp_tbl_4:       DB  0FFh,0FAh,09Ch,0FAh,09Ah,0B6h,096h,0B6h
                DB  085h,0A2h,078h,092h,064h,076h,05Ah,069h
                DB  046h,054h,041h,04Eh,01Eh,040h,000h,040h
ignition_timing_calc_interp_tbl_5:       DB  0FFh,0FAh,0A1h,0FAh,09Fh,0A3h,09Bh,0A3h
                DB  085h,085h,078h,073h,064h,05Bh,05Ah,04Dh
                DB  046h,03Dh,041h,038h,01Eh,038h,000h,038h
ignition_timing_calc_interp_tbl_6:       DB  0FFh,014h,0B4h,014h,04Eh,014h,04Ch,003h,000h,003h
ignition_timing_calc_interp_tbl_7:       DB  0FFh,01Bh,0B4h,01Bh,04Eh,01Bh,04Ch,006h,000h,006h
ignition_timing_calc_interp_tbl_8:       DB  0FFh,02Ch,050h,02Ch,03Ch,01Eh,028h,01Eh
                DB  019h,01Eh,014h,01Bh,000h,01Bh
ignition_timing_calc_interp_tbl_9:       DB  0FFh,038h,050h,038h,03Ch,030h,028h,030h
                DB  019h,02Bh,014h,02Ah,000h,020h
ignition_timing_calc_interp_tbl_10:       DB  0FFh,033h,078h,033h,050h,02Eh,03Ch,01Dh
                DB  028h,01Dh,014h,01Bh,000h,01Bh
ignition_timing_calc_interp_tbl_11:       DB  0FFh,03Fh,078h,03Fh,050h,03Ah,03Ch,027h
                DB  028h,025h,014h,01Fh,000h,01Bh
threshold_bank_223_2_interp_tbl_14:       DB  0FFh,057h,0CFh,057h,0A1h,051h,06Eh,04Ch
                DB  044h,046h,028h,040h,000h,040h
tps_hysteresis_reentry_interp_tbl:       DB  0FFh,0D2h,0E0h,0D2h,0C0h,0D2h,080h,0D2h
                DB  060h,0DAh,05Ch,0FFh,000h,0FFh,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h
knockretard2_clamp_data_2:       DB  0FFh,017h,0F8h,017h,0F0h,028h,0E8h,026h
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
state_21a_7_dispatch2_interp_tbl:       DB  0FFh,04Dh,008h,0CFh,04Dh,008h,0BAh,0B7h
                DB  007h,087h,059h,006h,02Eh,0EEh,002h,028h
                DB  0EEh,002h,000h,0EEh,002h
ignmap_alt_path_interp_tbl:       DB  0FFh,0ABh,0E4h,0ABh,0D5h,0A2h,0C7h,0A2h
                DB  0B9h,0A2h,0ABh,09Eh,09Dh,091h,08Eh,08Dh
                DB  080h,089h,072h,089h,064h,07Ch,056h,073h
                DB  047h,06Fh,039h,055h,02Bh,049h,01Dh,033h
                DB  000h,033h,000h,033h,000h,033h,000h,033h
                DB  000h,033h,000h,033h
ignmap_alt_path_interp_tbl_2:       DB  0FFh,0ABh,0F8h,0ABh,0F0h,0A2h,0E8h,0A2h
                DB  0E0h,09Eh,0D8h,091h,0D0h,08Dh,0C8h,089h
                DB  0C0h,089h,0B0h,07Ch,0A0h,073h,098h,071h
                DB  090h,06Fh,088h,062h,080h,055h,070h,04Dh
                DB  060h,049h,050h,040h,040h,033h,000h,033h
                DB  000h,033h,000h,033h
battery_voltage_store_data:       DB  0FEh,0FFh,066h,073h,0DDh,0E0h,044h,030h,078h,070h

;--------------------------------------------------------------------------------------------
; ZoneIndexTable1_SetB  @0x6643
;   TRACED: CFG_DualMapSelect-clear counterpart of ZoneIndexTable1_SetA - same axis (RAM
;   0xC1), same destination off(276h).
;--------------------------------------------------------------------------------------------
ZoneIndexTable1_SetB:       DB  0FFh,000h,016h,0F0h,000h,016h,0E0h,000h
                DB  010h,0CAh,000h,012h,090h,000h,015h,070h
                DB  000h,014h,035h,000h,00Ah,028h,000h,000h
                DB  000h,000h,000h

;--------------------------------------------------------------------------------------------
; ZoneIndexTable1_SetA  @0x665E
;   TRACED: looked up by coolantTempByte (RAM 0xC1) via VCAL 1, result stored to off(276h).
;   Selected when CFG_DualMapSelect (off 216h.3) is set; gated by a chain testing
;   off(211h).5/off(21Ah).3/off(236h)/off(22Ah).6 and the periodic slow-tick counter at
;   RAM 0xE9 (the same counter periodic_decay_task_1 increments), suggesting a
;   rate-limited update.
;--------------------------------------------------------------------------------------------
ZoneIndexTable1_SetA:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h
                DB  013h,0CAh,000h,016h,090h,000h,01Dh,070h
                DB  000h,018h,035h,000h,00Ah,028h,000h,000h
                DB  000h,000h,000h

;--------------------------------------------------------------------------------------------
; ZoneIndexTable3_SetB  @0x6679
;   TRACED: CFG_DualMapSelect-clear counterpart of ZoneIndexTable3_SetA.
;--------------------------------------------------------------------------------------------
ZoneIndexTable3_SetB:       DB  0FFh,000h,028h,0F0h,000h,028h,0E0h,000h
                DB  01Fh,0CAh,000h,020h,090h,000h,023h,070h
                DB  000h,020h,035h,000h,013h,028h,000h,010h
                DB  000h,000h,010h

;--------------------------------------------------------------------------------------------
; ZoneIndexTable3_SetA  @0x6694
;   TRACED: looked up by the same coolantTempByte (RAM 0xC1) via VCAL 1, result stored to
;   off(27Ah). Third distinct table keyed on coolantTempByte, alongside ZoneIndexTable1/2.
;--------------------------------------------------------------------------------------------
ZoneIndexTable3_SetA:       DB  0FFh,000h,030h,0F0h,000h,030h,0E0h,000h
                DB  024h,0CAh,000h,025h,090h,000h,028h,070h
                DB  000h,023h,035h,000h,014h,028h,000h,010h
                DB  000h,000h,010h

;--------------------------------------------------------------------------------------------
; ZoneIndexTable2_SetB  @0x66AF
;   TRACED: CFG_DualMapSelect-clear counterpart of ZoneIndexTable2_SetA.
;--------------------------------------------------------------------------------------------
ZoneIndexTable2_SetB:       DB  0FFh,000h,01Dh,0F0h,000h,01Dh,0E0h,000h
                DB  015h,0CAh,000h,016h,090h,000h,019h,070h
                DB  000h,017h,035h,000h,00Dh,028h,000h,008h
                DB  000h,000h,008h

;--------------------------------------------------------------------------------------------
; ZoneIndexTable2_SetA  @0x66CA
;   TRACED: looked up by the SAME coolantTempByte (RAM 0xC1) via VCAL 1 immediately after
;   ZoneIndexTable1_SetA, result stored to off(278h) - a second, related value derived
;   from the same zone index in the same pass.
;--------------------------------------------------------------------------------------------
ZoneIndexTable2_SetA:       DB  0FFh,000h,026h,0F0h,000h,026h,0E0h,000h
                DB  01Ch,0CAh,000h,01Dh,090h,000h,022h,070h
                DB  000h,01Dh,035h,000h,00Eh,028h,000h,00Ah
                DB  000h,000h,00Ah
IdleVsECT:       DB  0FFh,0E2h,004h,0A1h,03Bh,005h,087h,0A2h
                DB  005h,06Eh,01Bh,006h,034h,023h,008h,028h
                DB  027h,009h,000h,027h,009h
idle_step_flag_store_interp_tbl:       DB  0FFh,0E2h,004h,0A1h,0E2h,004h,087h,03Bh
                DB  005h,06Eh,0A2h,005h,034h,0B5h,007h,028h
                DB  027h,009h,000h,027h,009h
freezeframe_flag_225_7_data:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h
                DB  034h,050h,028h,042h,000h,042h,0FFh,09Ah
                DB  0A1h,09Ah,087h,083h,06Eh,073h,034h,066h
                DB  028h,04Dh,000h,04Dh
idle_step_flag_store_data:       DB  0FFh,092h,0A1h,092h,087h,07Ah,06Eh,073h
                DB  034h,05Dh,028h,04Dh,000h,04Dh,0FFh,09Ah
                DB  0A1h,09Ah,087h,086h,06Eh,083h,034h,070h
                DB  028h,05Ah,000h,05Ah
tbl_idle_lookup3:       DB  000h,0F0h,000h,002h,000h,004h
tbl_idle_select_default:       DB  000h,0F0h,000h,010h,000h,00Dh
tbl_idle_timer:       DB  000h,040h,000h,006h,000h,006h
idle_timer_gate_common_data:       DB  000h,0F0h,080h,000h,080h,001h
tbl_idle_gear2:       DB  000h,000h,000h,080h,001h,000h
idle_table_select1_data:       DB  0FFh,0FFh,0FFh,0FFh,000h,000h
tbl_idle_stall:       DB  0F5h,000h,098h,000h
idle_sub_final_store_interp_tbl:       DB  0FFh,092h,0A1h,092h,087h,077h,06Eh,063h
                DB  034h,050h,028h,042h,000h,042h
tbl_idle_gate6:       DB  0FFh,014h,000h,0A1h,014h,000h,087h,014h
                DB  000h,06Eh,014h,000h,034h,014h,000h,028h
                DB  030h,000h,000h,030h,000h
idle_sub_final_store_interp_tbl_2:       DB  0FFh,0FFh,0A1h,0FFh,087h,0FFh,06Eh,0FFh
                DB  034h,0FFh,028h,0FFh,000h,0FFh
idle_sub_final_store_interp_tbl_3:       DB  0FFh,010h,0A1h,010h,087h,00Ch,06Eh,00Ah
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

;--------------------------------------------------------------------------------------------
; ZoneCorrectionRowSelect_SetA  @0x6844
;   TRACED: looked up by RAM 0xC0 (a zone-index sibling to 0xC1, origin not yet traced)
;   via VCAL 1, then doubled (SLLB) and used as a ROW OFFSET into ZoneCorrection2DTable -
;   an indirect two-stage lookup rather than a direct 2D table.
;--------------------------------------------------------------------------------------------
ZoneCorrectionRowSelect_SetA:       DB  0FFh,080h,006h,0C0h,080h,006h,060h,000h
                DB  008h,030h,000h,00Ah,000h,000h,00Dh

;--------------------------------------------------------------------------------------------
; ZoneCorrectionRowSelect_SetB  @0x6853
;   TRACED: CFG_DualMapSelect-clear counterpart of ZoneCorrectionRowSelect_SetA.
;--------------------------------------------------------------------------------------------
ZoneCorrectionRowSelect_SetB:       DB  0FFh,080h,006h,0C0h,080h,006h,060h,000h
                DB  008h,030h,000h,00Ah,000h,000h,00Dh

;--------------------------------------------------------------------------------------------
; ZoneCorrection2DTable  @0x6862
;   TRACED: the table ZoneCorrectionRowSelect_SetA/SetB selects a row within, further
;   interpolated by off(236h) via the main table_interp_lookup (VCAL 0), then multiplied
;   against an accumulator at off(266h).
;--------------------------------------------------------------------------------------------
ZoneCorrection2DTable:       DB  0FFh,0C0h,0B0h,0C0h,080h,098h,053h,080h,000h,080h
inc_dp_step_interp_tbl:       DB  0FFh,000h,00Eh,0D0h,000h,00Eh,0BAh,000h
                DB  00Eh,094h,000h,00Dh,055h,080h,00Ah,042h
                DB  000h,008h,034h,080h,007h,028h,000h,004h
                DB  000h,000h,004h
inc_dp_step_interp_tbl_2:       DB  0FFh,0FFh,000h,004h,044h,00Bh,000h,004h,0C4h,009h
                DB  080h,007h,00Bh,009h,000h,00Ah,000h,000h,000h,00Ah

;--------------------------------------------------------------------------------------------
; ModePageTable_SetA  @0x689B
;   TRACED: looked up by RAM 0xBD (axis not yet traced) via VCAL 3, on the DP page
;   selected by ModeToPageTable. CFG_DualMapSelect-set variant.
;--------------------------------------------------------------------------------------------
ModePageTable_SetA:       DB  030h,000h,020h,004h,000h,000h

;--------------------------------------------------------------------------------------------
; ModePageTable_SetB  @0x68A1
;   TRACED: CFG_DualMapSelect-clear counterpart of ModePageTable_SetA.
;--------------------------------------------------------------------------------------------
ModePageTable_SetB:       DB  030h,0FFh,03Fh,004h,000h,000h

;--------------------------------------------------------------------------------------------
; ModeToPageTable  @0x68A7
;   TRACED: indexed by off(236h) via VCAL 1, result used as a DP (data page) selector
;   immediately before the ModePageTable_SetA/SetB lookup - a mode-to-memory-page
;   indirection.
;--------------------------------------------------------------------------------------------
ModeToPageTable:       DB  0FFh,0FFh,03Fh,0C0h,0FFh,03Fh,060h,000h
                DB  01Ch,040h,000h,006h,000h,000h,006h
tbl_ve_map_scalar_alt:       DB  0FFh,0FFh,03Fh,08Eh,0FFh,03Fh,080h,0FFh
                DB  03Fh,072h,0FFh,03Fh,055h,0FFh,03Fh,039h
                DB  000h,00Ah,02Ch,000h,000h,000h,000h,000h
tbl_ve_map_scalar:       DB  0FFh,0FFh,03Fh,0D0h,0FFh,03Fh,0C8h,000h
                DB  030h,0C0h,000h,026h,0A0h,000h,020h,080h
                DB  000h,00Ah,064h,000h,000h,000h,000h,000h
idle_vcal5_report_interp_tbl:       DB  0FFh,000h,010h,0D0h,000h,00Ah,0A0h,000h
                DB  007h,060h,000h,005h,028h,000h,003h,000h
                DB  000h,003h
idle_vcal5_report_data:       DB  0FFh,060h,000h,0D0h,040h,000h,0A0h,020h
                DB  000h,060h,010h,000h,028h,00Ch,000h,000h
                DB  00Ch,000h
idle_vcal5_report_interp_tbl_2:       DB  0FFh,004h,000h,0D0h,003h,000h,0A0h,002h
                DB  000h,060h,002h,000h,028h,002h,000h,000h
                DB  001h,000h
idle_vcal5_report_interp_tbl_3:       DB  0FFh,000h,000h,0CFh,000h,000h,0A0h,000h
                DB  000h,044h,000h,000h,028h,000h,000h,000h
                DB  000h,000h
idle_pi_final_calc_interp_tbl:       DB  0FFh,080h,000h,080h
idle_pi_final_calc_interp_tbl_2:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
idle_pi_final_calc_interp_tbl_3:       DB  0FFh,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
tbl_idle_gear_target:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,03Fh,000h,0C0h
                DB  080h,036h,066h,0A6h,0F0h,018h,000h,080h
                DB  010h,00Ah,066h,066h,000h,003h,033h,053h
                DB  0A0h,000h,066h,046h,000h,000h,0CCh,02Ch
tbl_idle_dc:       DB  0FFh,0FFh,000h,080h,000h,00Ah,000h,080h
                DB  000h,008h,01Eh,085h,080h,006h,01Eh,085h
                DB  000h,003h,085h,07Bh,000h,002h,085h,07Bh
                DB  000h,001h,028h,05Ch,000h,000h,028h,05Ch
tbl_6baf_done_data:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
tbl_6baf_done_data_2:       DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
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
knockwindow_result_interp_tbl:       DB  0FFh,000h,0AEh,000h,0A1h,02Bh,057h,015h
                DB  034h,000h,000h,000h
tbl_ignmap_idle1:       DB  0D4h,000h,0C1h
knockwindow_result_interp_tbl_2:       DB  0FFh,06Fh,0E6h,067h,0BFh,049h,094h,02Ah
                DB  057h,011h,028h,000h,000h,000h
knockwindow_result_interp_tbl_3:       DB  0FFh,05Ah,0E6h,051h,0BFh,033h,094h,022h
                DB  057h,011h,028h,000h,000h,000h
tbl_ignmap_idle2:       DB  077h,0C1h,064h,064h
knockwindow_result_data:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,000h
                DB  00Fh,000h,000h,000h
tbl_ect_fuelcorrect:       DB  0FFh,000h,023h,000h,01Ch,000h,018h,00Dh
                DB  00Fh,015h,000h,015h
threshold_bank_220_6_interp_tbl:       DB  0FFh,000h,06Ch,000h,044h,00Ch,02Eh,015h,000h,015h
HiIdleIgnControl:       DB  0FFh,0FFh,000h,000h,000h,002h,000h,000h
                DB  0F0h,000h,015h,000h,000h,000h,000h,000h
IgnControl:       DB  0FFh,0FFh,000h,000h,000h,003h,015h,000h
                DB  0CEh,000h,015h,000h,000h,000h,000h,000h
dwell_scale_shift_data_2:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,020h,02Fh,040h,03Dh,03Ah,055h
                DB  063h,072h,07Ah,07Ah,000h,000h,000h,000h
                DB  000h,000h
tbl_boot_copy_block:       DB  024h,000h,020h,039h,04Ah,050h,055h,05Eh
                DB  066h,080h,084h,088h,088h,088h
flags_pack_sj_interp_tbl:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h
                DB  040h,000h,000h,000h
TipinTPS:       DB  0FFh,00Ch,090h,00Ch,080h,004h,060h,000h
                DB  040h,000h,000h,000h
callhelper_table_interp_tbl:       DB  0FFh,040h,0D0h,040h,0C0h,038h,0A0h,030h
                DB  080h,02Ch,040h,028h,000h,028h
tipin_gate_pass_data:       DB  0FFh,02Ah,0C0h,02Ah,0A0h,02Ah,080h,048h
                DB  066h,048h,040h,02Ah,000h,015h
callhelper_table_interp_tbl_2:       DB  0FFh,000h,0D8h,000h,0D0h,000h,0C0h,000h
                DB  0B0h,000h,0A0h,000h,090h,000h,080h,000h
                DB  000h,000h
flags_pack_sj_interp_tbl_2:       DB  0FFh,000h,09Ah,00Ch,04Dh,040h,033h,02Ah
                DB  026h,015h,000h,000h
TipinGear:       DB  040h,066h,066h,047h,047h,0BAh,07Ah,028h
tbl_map_sign:       DB  060h,0F0h,020h,070h

;--------------------------------------------------------------------------------------------
; ZoneRemapTable  @0x6B1F
;   TRACED: 20-entry ROM table indexed by off(2BAh)/20 to produce coolantTempByte (RAM 0xC1).
;   The remap step from a divided raw value into this table is what turns off(2BAh) into
;   the zone index used throughout battery_voltage_check.
;--------------------------------------------------------------------------------------------
ZoneRemapTable:       DB  0DFh,0CFh,0A1h,057h,028h
tbl_dcode14_lo:       DB  0C2h,000h,0FAh,03Eh,000h,047h
tbl_dcode14_hi:       DB  0E5h,000h,051h,03Eh,000h,019h
vss_threshold_226_3_interp_tbl:       DB  06Bh,0A9h,02Bh,05Dh
tbl_knock244_a:       DB  030h,030h,030h,025h,01Bh,01Bh,01Bh,015h,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,008h,008h,008h,008h,008h
tbl_knock244_b:       DB  030h,030h,030h,030h,030h,02Ch,025h,01Bh
                DB  01Bh,01Bh,01Bh,01Bh,01Bh,015h

;--------------------------------------------------------------------------------------------
; multiway_condition_apply2  @0x6B56
;   VERIFIED: second apply stage of the SAME off(2FFh) selector subsystem (0x6B82 tests
;   the identical (2FFh-280h)[USP] bits), over MultiwayApply2Table0/1/2 - the table
;   cluster immediately adjacent to apply1's. Runs the result through VCAL 0, scales x4,
;   accumulates into X2, clamps overflow to 0xFFFF.
;--------------------------------------------------------------------------------------------
multiway_condition_apply2:     LB      A, (002feh-00280h)[USP]
                VCAL    0
                L       A, ACC
                SLL     A
                SLL     A
                ADD     A, X2
                JGE     multiway_condition_set_x2
                L       A, #0ffffh
multiway_condition_set_x2:     MOV     X2, A
                RT

;--------------------------------------------------------------------------------------------
; multiway_apply2_prescale  @0x6B66
;   TRACED: calls the validated mul_scale_clamp (0x6BA7), then applies signed clamping
;   gated by the multiway selector bit off(2FFh).5 - a stage immediately preceding
;   mul_scale_clamp_dual in the multiway_condition_apply2 pipeline.
;--------------------------------------------------------------------------------------------
multiway_apply2_prescale:     MOV     er0, #08000h
                SCAL    mul_scale_clamp
                ADDB    A, #000h
                NOP
                JGE     multiway_apply2_test_stk_bit5
                L       A, #0ffffh
multiway_apply2_test_stk_bit5:     MB      C, (002ffh-00280h)[USP].5
                JGE     multiway_apply2_set_x2
                ADD     A, #00000h
                JGE     multiway_apply2_set_x2
                L       A, #0ffffh
multiway_apply2_set_x2:     MOV     X2, A
                MB      C, (002ffh-00280h)[USP].1
                JGE     multiway_apply2_test_stk_bit2
                MOV     X1, #MultiwayApply2Table0
                SCAL    multiway_condition_apply2
multiway_apply2_test_stk_bit2:     MB      C, (002ffh-00280h)[USP].2
                JGE     multiway_apply2_test_stk_bit3
                MOV     X1, #MultiwayApply2Table1
                SCAL    multiway_condition_apply2
multiway_apply2_test_stk_bit3:     MB      C, (002ffh-00280h)[USP].3
                JGE     multiway_apply2_store_ram138
                MOV     X1, #MultiwayApply2Table2
                SCAL    multiway_condition_apply2
multiway_apply2_store_ram138:     ST      A, off(00138h)
                LB      A, off(00170h)
                J       multiway_apply2_if_ram117_bit5_set

;--------------------------------------------------------------------------------------------
; mul_scale_clamp  @0x6BA7
;   86% HTS115 match.
;--------------------------------------------------------------------------------------------
mul_scale_clamp:     MUL
                ROLB    A
                L       A, er1
                ROL     A
                JGE     idle_p0_pin_check
                L       A, #0ffffh
idle_p0_pin_check:     RT

;--------------------------------------------------------------------------------------------
; mul_scale_clamp_dual  @0x6BB2
;   TRACED: calls mul_scale_clamp (0x6BA7) twice with different er0 presets (#08000h each
;   time) and different post-processing branches gated by off(125h).2, feeding results
;   into two different downstream jump targets. A dual-path wrapper around the
;   already-validated mul_scale_clamp helper.
;--------------------------------------------------------------------------------------------
mul_scale_clamp_dual:     MOV     er3, er1
                MOV     er0, #08000h
                SCAL    mul_scale_clamp
                MOV     er1, er3
                JBS     off(00125h).2, mul_scale_clamp_dual_goto_o2trim_sub
                J       o2trim_add_clamp
mul_scale_clamp_dual_goto_o2trim_sub:     J       o2trim_sub_clamp
crankfuel_add_adjust_set_er0:     MOV     er0, #08000h
                SCAL    mul_scale_clamp
                ADD     A, off(0013ch)
                JGE     crankfuel_add_adjust_goto_diag_report
                L       A, #0ffffh
crankfuel_add_adjust_goto_diag_report:     J       diag_report_finalize
postfuel_scale_apply_load_er1:     L       A, er1
                MOV     er0, #08000h
                SCAL    mul_scale_clamp
                ST      A, off(00160h)
                J       postfuel_scale_apply_clear_ram15f
tipin_time_calc_set_er0:     MOV     er0, #08000h
                SCAL    mul_scale_clamp
                JBR     off(00123h).3, tipin_time_calc_goto
                J       tipin_time_calc_cmp_rame8
tipin_time_calc_goto:     J       tipin_time_calc_add_ram13c
knock_table2d_lookup_vcal1:     VCAL    1
                ADDB    A, #000h
                NOP
                JGE     knock_table2d_lookup_store_stk
                L       A, #0ffffh
knock_table2d_lookup_store_stk:     ST      A, (0013ch-00180h)[USP]
                J       knock_table2d_lookup_vcal4
dat_mul_scale_clamp_dual_6bfc        EQU     $-2
                DB  0F0h,000h,0F0h,000h,0E4h,000h,0E4h,000h
                DB  0E4h,000h
fuelpump_state_branch:     JLT     fuelpump_state_carry_to_p1_bit4
                LB      A, off(0024fh)
                EXTND
                SLL     A
                LC      A, dat_mul_scale_clamp_dual_6bfc[ACC]
                CMP     0ach, A
                MB      off(002ffh).4, C
fuelpump_state_carry_to_p1_bit4:     MB      P1.4, C
                J       fuelpump_done
tps_custom_clamp_store_interp_tbl:       DB  0E6h,0E7h,016h,018h
tps_custom_clamp_store_load_adcr7h:     LB      A, ADCR7H
                MOV     X1, #tps_custom_clamp_store_interp_tbl
                VCAL    2
                MOV     er0, ADCR7
                STB     A, r1
                J       tps_custom_clamp_store_load_fc
multiway_selector_load_0:     L       A, #00000h
                ST      A, er0
                JEQ     multiway_selector_goto_4
                CMPB    off(0024fh), #001h
                JNE     multiway_selector_goto_4
                L       A, X2
                CMP     0ach, A
                JLT     multiway_selector_goto_4
                DECB    (00189h-00180h)[USP]
                JGE     multiway_selector_goto_3
                L       A, (00180h-00180h)[USP]
                SUB     A, er0
                JGE     multiway_selector_set_dp
                CLR     A
multiway_selector_set_dp:     MOV     DP, A
multiway_selector_goto_3:     J       dualmap_dispatch_jump_and_ie
multiway_selector_goto_4:     J       multiway_selector_clr_carry
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh
tbl_dtc_code_map:       DB  00Bh,00Fh,00Fh,00Fh,02Dh,02Dh,04Bh,00Fh
                DB  0FFh,0FFh,0FFh,0FFh,02Dh,02Dh,0FFh,02Dh
                DB  02Dh,006h,02Dh,00Fh,00Fh,0FFh,0FFh,0FFh
                DB  0FFh,007h,007h,014h,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,02Dh,02Dh,007h,006h,0FFh,0FFh,0FFh
                DB  078h,019h,019h,019h,0FFh,0FFh,0FFh,0FFh
                DB  0B3h
tbl_cfgvariant_map:       DB  00Bh,003h,006h,007h,005h,001h,008h,00Ah
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
rpm_decel_limit_check_data:       DB  053h,007h,0A9h,003h,0D4h,001h,0EAh,000h,000h,000h
tbl_knock_sanity:       DB  000h,000h,077h,022h,0EEh,044h,077h,044h
                DB  0DDh,088h,0FFh,0FFh,0EEh,088h,077h,088h
                DB  0BBh,011h,0BBh,022h,0FFh,0FFh,0BBh,044h
                DB  0DDh,011h,0DDh,022h,0EEh,011h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwaySelectTable0  @0x6D32
;   VERIFIED: consumed by multiway_condition_select (0x2649) via config_flag_bit_decode.
;--------------------------------------------------------------------------------------------
MultiwaySelectTable0:       DB  000h,000h,000h,000h,000h,000h,0A6h,00Eh
                DB  0AAh,000h,000h,0FFh,000h,0FFh,000h,0FFh
                DB  0FFh,000h,0FFh,000h,000h,000h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwaySelectTable1  @0x6D4A
;   VERIFIED: consumed by multiway_condition_select (0x2649) via config_flag_bit_decode.
;--------------------------------------------------------------------------------------------
MultiwaySelectTable1:       DB  000h,000h,000h,000h,000h,000h,0A6h,00Eh
                DB  0AAh,000h,000h,0FFh,000h,0FFh,000h,0FFh
                DB  0FFh,000h,0FFh,000h,000h,000h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwaySelectTable2  @0x6D62
;   VERIFIED: consumed by multiway_condition_select (0x2649) via config_flag_bit_decode.
;--------------------------------------------------------------------------------------------
MultiwaySelectTable2:       DB  000h,000h,011h,002h,000h,004h,0A6h,00Eh
                DB  0AAh,000h,000h,0FFh,000h,0FFh,000h,0FFh
                DB  0FFh,000h,0FFh,000h,000h,000h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwayApply2Table0  @0x6D7A
;   VERIFIED: consumed by multiway_condition_apply2 (0x6B56).
;--------------------------------------------------------------------------------------------
MultiwayApply2Table0:       DB  0FFh,000h,0E8h,000h,0D1h,000h,0BAh,000h,0A2h,000h
                DB  08Bh,000h,080h,000h,074h,000h,068h,000h,05Dh,000h
                DB  051h,000h,046h,000h,03Ah,000h,02Eh,000h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwayApply2Table1  @0x6D98
;   VERIFIED: consumed by multiway_condition_apply2 (0x6B56).
;--------------------------------------------------------------------------------------------
MultiwayApply2Table1:       DB  0FFh,000h,0E8h,000h,0D1h,000h,0BAh,000h,0A2h,000h
                DB  08Bh,000h,080h,000h,074h,000h,068h,000h,05Dh,000h
                DB  051h,000h,046h,000h,03Ah,000h,02Eh,000h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwayApply2Table2  @0x6DB6
;   VERIFIED: consumed by multiway_condition_apply2 (0x6B56).
;--------------------------------------------------------------------------------------------
MultiwayApply2Table2:       DB  0FFh,000h,0E8h,000h,0D1h,000h,0BAh,000h,0A2h,000h
                DB  08Bh,000h,080h,000h,074h,000h,068h,000h,05Dh,000h
                DB  051h,000h,046h,000h,03Ah,000h,02Eh,000h,000h,000h

;--------------------------------------------------------------------------------------------
; MultiwayApply1Table0  @0x6DD4
;   VERIFIED: consumed by multiway_condition_apply1 (0x78AE).
;--------------------------------------------------------------------------------------------
MultiwayApply1Table0:       DB  0FFh,080h,0E8h,080h,0D1h,080h,0BAh,080h,0A2h,080h
                DB  08Bh,080h,080h,080h,074h,080h,068h,080h,05Dh,080h
                DB  0D1h,080h,046h,080h,03Ah,080h,02Eh,080h,000h,080h

;--------------------------------------------------------------------------------------------
; MultiwayApply1Table1  @0x6DF2
;   VERIFIED: consumed by multiway_condition_apply1 (0x78AE).
;--------------------------------------------------------------------------------------------
MultiwayApply1Table1:       DB  0FFh,080h,0E8h,080h,0D1h,080h,0BAh,080h,0A2h,080h
                DB  08Bh,080h,080h,080h,074h,080h,068h,080h,05Dh,080h
                DB  0D1h,080h,046h,080h,03Ah,080h,02Eh,080h,000h,080h

;--------------------------------------------------------------------------------------------
; table_result_sign_data  @0x6E10
;   PARTIAL: X1 at 0x78F1 into a scaler call; axis role not yet traced.
;--------------------------------------------------------------------------------------------
table_result_sign_data:       DB  0FFh,080h,0E8h,080h,0D1h,080h,0BAh,080h
                DB  0A2h,080h,08Bh,080h,080h,080h,074h,080h
                DB  068h,080h,05Dh,080h,0D1h,080h,046h,080h
                DB  03Ah,080h,02Eh,080h,000h,080h,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
                DB  0FFh,0FFh

;--------------------------------------------------------------------------------------------
; Scaler_LoadAxis  @0x6E5A
;   VALIDATED: X1 at 0x0A16 and 0x0A2B into scaler_table_lookup (0x4FDE, 96% HTS115 match)
;   with r6=#008h (8 breakpoints). Outputs index/fraction to RAM 0x1D2/0x1D4 and
;   0x1D3/0x1D6, which become r2/X2 of the main map lookup. == HTS115 P_MAP_Scaler.
;--------------------------------------------------------------------------------------------
Scaler_LoadAxis:       DB  018h,024h,030h,040h,058h,070h,080h,088h
                DB  090h,098h,098h,098h,098h,098h,098h,098h
                DB  098h,098h,098h,098h,098h,098h,098h,000h

;--------------------------------------------------------------------------------------------
; Scaler_RpmAxis_Lo  @0x6E72
;   VALIDATED: X1 at 0x09DB; outputs feed RAM 0x1D8/0x1DA = the r3/er3 pair used by the
;   LO-cam maps. == HTS115 P_LO_Scaler.
;--------------------------------------------------------------------------------------------
Scaler_RpmAxis_Lo:       DB  000h,00Dh,01Ah,026h,040h,050h,060h,070h,080h,088h
                DB  090h,0A0h,0A6h,0B0h,0C0h,0C8h,0D0h,0E0h,0F0h,0FFh

;--------------------------------------------------------------------------------------------
; Scaler_RpmAxis_Hi  @0x6E86
;   VALIDATED: X1 at 0x09F3, r6=#012h (18 breakpoints), outputs to RAM 0x1D9/0x1DC = the
;   r3/er3 pair used by the HI-cam maps. == HTS115 P_HI_Scaler.
;--------------------------------------------------------------------------------------------
Scaler_RpmAxis_Hi:       DB  000h,052h,05Dh,069h,06Fh,075h,07Ah,080h,085h,08Ch
                DB  097h,0A3h,0AEh,0BAh,0C6h,0D1h,0DDh,0E9h,0F4h,000h

;--------------------------------------------------------------------------------------------
; FuelMap_Lo  @0x6E9A
;   VALIDATED: X1 at 0x121B into table2d_lookup_interp with r0=24,r1=20; region
;   0x6E9A-0x7091 = exactly 504 B = 24x21, 147 distinct values, no fill. Setup code
;   structurally identical to HTS115 FUEL1_Lo.
;--------------------------------------------------------------------------------------------
FuelMap_Lo:       DB  05Eh,07Fh,088h,09Bh,09Fh,090h,099h,096h
                DB  099h,09Bh,077h,065h,054h,04Bh,041h,03Ch
                DB  035h,030h,030h,030h,030h,030h,030h,030h
                DB  067h,083h,08Bh,09Eh,0A2h,091h,09Ah,097h
                DB  09Ah,09Ch,077h,065h,055h,04Bh,042h,03Ch
                DB  036h,031h,031h,031h,031h,031h,031h,031h
                DB  070h,088h,08Fh,0A1h,0A4h,093h,09Ch,098h
                DB  09Bh,09Ch,078h,066h,055h,04Ch,042h,03Ch
                DB  036h,031h,031h,031h,031h,031h,031h,031h
                DB  073h,08Ch,092h,0A3h,0A6h,094h,09Ch,099h
                DB  09Ch,09Eh,079h,067h,056h,04Ch,043h,03Dh
                DB  036h,031h,031h,031h,031h,031h,031h,031h
                DB  072h,093h,09Bh,0A6h,0ABh,098h,0A0h,0A0h
                DB  09Fh,09Fh,07Ah,068h,056h,04Dh,043h,03Dh
                DB  037h,032h,032h,032h,032h,032h,032h,032h
                DB  07Fh,097h,09Ch,0ADh,0ADh,09Dh,09Eh,09Ah
                DB  099h,097h,074h,063h,052h,049h,040h,03Ah
                DB  034h,02Fh,02Fh,02Fh,02Fh,02Fh,02Fh,02Fh
                DB  091h,099h,09Eh,0ADh,0ADh,09Eh,09Fh,09Dh
                DB  09Bh,09Bh,077h,065h,054h,04Bh,041h,03Ch
                DB  035h,030h,030h,030h,030h,030h,030h,030h
                DB  089h,099h,0A1h,0B4h,0B6h,0A3h,0A2h,0A2h
                DB  0A1h,09Fh,07Ah,067h,056h,04Dh,043h,03Dh
                DB  037h,031h,031h,031h,031h,031h,031h,031h
                DB  08Bh,09Dh,0A5h,0B7h,0B8h,0A4h,0A5h,0A5h
                DB  0A3h,0A0h,07Bh,068h,057h,04Eh,044h,03Eh
                DB  037h,032h,032h,032h,032h,032h,032h,032h
                DB  097h,09Dh,0A5h,0B6h,0B8h,0A5h,0A7h,0A4h
                DB  0A5h,0A2h,07Ch,069h,058h,04Eh,044h,03Eh
                DB  038h,032h,032h,032h,032h,032h,032h,032h
                DB  087h,098h,0A2h,0B5h,0B8h,0A2h,0A5h,0A3h
                DB  0A5h,0A4h,07Eh,06Bh,059h,04Fh,045h,03Fh
                DB  039h,033h,033h,033h,033h,033h,033h,033h
                DB  078h,09Dh,0A6h,0BDh,0BEh,0A9h,0ADh,0ADh
                DB  0B3h,0B7h,08Ch,077h,063h,058h,04Dh,046h
                DB  03Fh,039h,039h,039h,039h,039h,039h,039h
                DB  07Dh,09Eh,0A7h,0BDh,0BEh,0A9h,0AFh,0ADh
                DB  0B2h,0B4h,08Ah,075h,062h,057h,04Ch,045h
                DB  03Eh,038h,038h,038h,038h,038h,038h,038h
                DB  087h,0A0h,0A9h,0BDh,0BEh,0A8h,0B0h,0AEh
                DB  0B0h,0ADh,085h,071h,05Eh,054h,049h,043h
                DB  03Ch,036h,036h,036h,036h,036h,036h,036h
                DB  07Eh,096h,0A1h,0B7h,0BAh,0A5h,0B0h,0ABh
                DB  0A8h,0A6h,07Fh,06Ch,05Ah,050h,046h,040h
                DB  039h,034h,034h,034h,034h,034h,034h,034h
                DB  087h,09Eh,0A5h,0BBh,0BCh,0A7h,0B0h,0ACh
                DB  0A8h,0A4h,07Dh,06Bh,059h,04Fh,045h,03Fh
                DB  038h,033h,033h,033h,033h,033h,033h,033h
                DB  0A4h,0ABh,0B2h,0C5h,0C5h,0B3h,0BAh,0B7h
                DB  0B1h,0ADh,085h,071h,05Eh,054h,049h,043h
                DB  03Ch,036h,036h,036h,036h,036h,036h,036h
                DB  0B0h,0B4h,0B7h,0CCh,0D3h,0B9h,0C8h,0C3h
                DB  0BFh,0BAh,08Fh,079h,065h,05Ah,04Eh,048h
                DB  040h,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah
                DB  088h,0A3h,0ADh,0C5h,0C5h,0ADh,0B8h,0B4h
                DB  0B1h,0ACh,083h,070h,05Dh,053h,048h,042h
                DB  03Bh,035h,035h,035h,035h,035h,035h,035h
                DB  087h,0A2h,0ACh,0C4h,0C5h,0ACh,0B8h,0B4h
                DB  0B1h,0ABh,083h,06Fh,05Dh,053h,048h,042h
                DB  03Bh,035h,035h,035h,035h,035h,035h,035h
                DB  001h,002h,003h,004h,006h,009h,00Ah,00Bh
                DB  00Ch,00Dh,011h,014h,018h,01Bh,01Fh,022h
                DB  026h,02Ah,02Ah,02Ah,02Ah,02Ah,02Ah,02Ah

;--------------------------------------------------------------------------------------------
; FuelMap_Hi  @0x7092
;   VALIDATED: X1 at 0x1209, same lookup, 504 B = 24x21. == HTS115 FUEL1_Hi.
;--------------------------------------------------------------------------------------------
FuelMap_Hi:       DB  001h,03Eh,07Ah,07Dh,097h,099h,09Ch,09Eh
                DB  09Dh,09Dh,07Ch,067h,055h,04Ah,042h,03Bh
                DB  036h,032h,032h,032h,032h,032h,032h,032h
                DB  001h,03Eh,07Ah,07Dh,097h,099h,09Ch,09Eh
                DB  09Dh,09Dh,07Ch,067h,055h,04Ah,042h,03Bh
                DB  036h,032h,032h,032h,032h,032h,032h,032h
                DB  001h,03Eh,07Ah,07Dh,097h,099h,09Ch,09Eh
                DB  09Dh,09Dh,07Ch,067h,055h,04Ah,042h,03Bh
                DB  036h,032h,032h,032h,032h,032h,032h,032h
                DB  001h,03Eh,07Ah,07Dh,097h,099h,09Ch,09Eh
                DB  09Dh,09Dh,07Ch,067h,055h,04Ah,042h,03Bh
                DB  036h,032h,032h,032h,032h,032h,032h,032h
                DB  001h,03Eh,07Ah,07Dh,097h,099h,09Ch,09Eh
                DB  09Dh,09Dh,07Ch,067h,055h,04Ah,042h,03Bh
                DB  036h,032h,032h,032h,032h,032h,032h,032h
                DB  002h,03Eh,07Ch,07Fh,098h,09Ah,09Ch,09Eh
                DB  09Dh,09Dh,07Ch,067h,054h,04Ah,042h,03Bh
                DB  036h,031h,031h,031h,031h,031h,031h,031h
                DB  004h,042h,08Ah,08Bh,09Fh,09Ah,097h,09Ah
                DB  09Ah,09Ah,07Ah,065h,053h,049h,041h,03Ah
                DB  035h
FUEL1_Hi_Extended:       DB  031h,031h,031h,031h,031h,031h,031h,001h
                DB  041h,08Ch,08Ch,0A2h,09Dh,09Ah,099h,09Ah
                DB  09Ah,07Ah,065h,053h,049h,041h,03Ah,035h
                DB  031h,031h,031h,031h,031h,031h,031h,026h
                DB  058h,096h,090h,0A6h,0A0h,09Ch,09Ch,09Fh
                DB  0A1h,07Fh,069h,056h,04Ch,043h,03Dh,037h
                DB  033h,033h,033h,033h,033h,033h,033h,042h
                DB  066h,0A6h,09Dh,0B1h,0B0h,0B4h,0B3h,0AFh
                DB  0B2h,08Dh,074h,060h,054h,04Bh,043h,03Dh
                DB  038h,038h,038h,038h,038h,038h,038h,028h
                DB  06Ah,0BFh,0B0h,0C1h,0BAh,0BBh,0BDh,0B5h
                DB  0B6h,090h,077h,062h,056h,04Ch,045h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,051h
                DB  089h,0C3h,0BCh,0C5h,0C7h,0C4h,0C3h,0BDh
                DB  0BBh,094h,07Ah,065h,058h,04Eh,047h,040h
                DB  03Bh,03Bh,03Bh,03Bh,03Bh,03Bh,03Bh,05Ah
                DB  094h,0DCh,0CCh,0DAh,0CFh,0CBh,0CAh,0BFh
                DB  0BBh,094h,07Ah,065h,058h,04Eh,047h,040h
                DB  03Bh,03Bh,03Bh,03Bh,03Bh,03Bh,03Bh,04Bh
                DB  08Bh,0D4h,0D0h,0E3h,0D5h,0CDh,0CBh,0BDh
                DB  0B9h,092h,079h,064h,057h,04Eh,046h,040h
                DB  03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,03Ah,02Fh
                DB  082h,0D7h,0D3h,0E3h,0D1h,0C9h,0C6h,0B9h
                DB  0B6h,090h,077h,062h,056h,04Ch,045h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,023h
                DB  07Eh,0D8h,0D4h,0E3h,0CFh,0C5h,0C3h,0B8h
                DB  0B5h,08Fh,076h,061h,055h,04Ch,044h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,023h
                DB  07Eh,0D8h,0D4h,0E3h,0CFh,0C3h,0C1h,0B8h
                DB  0B4h,08Fh,076h,061h,055h,04Bh,044h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,023h
                DB  07Eh,0D8h,0D4h,0E3h,0CFh,0C0h,0BFh,0B8h
                DB  0B4h,08Eh,076h,061h,055h,04Bh,044h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,023h
                DB  07Eh,0D8h,0D4h,0E3h,0CFh,0C0h,0BFh,0B8h
                DB  0B4h,08Eh,076h,061h,055h,04Bh,044h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,023h
                DB  07Eh,0D8h,0D4h,0E3h,0CFh,0C0h,0BFh,0B8h
                DB  0B4h,08Eh,076h,061h,055h,04Bh,044h,03Eh
                DB  039h,039h,039h,039h,039h,039h,039h,002h
                DB  003h,003h,005h,007h,00Ah,00Ch,00Dh,00Eh
                DB  00Fh,013h,017h,01Ch,020h,024h,028h,02Ch
                DB  030h,030h,030h,030h,030h,030h,030h

;--------------------------------------------------------------------------------------------
; IgnMap_Lo  @0x728A
;   VALIDATED: X1 at 0x0B55, 480 B = 24x20. == HTS115 IGN1_Lo.
;--------------------------------------------------------------------------------------------
IgnMap_Lo:       DB  05Ah,05Ah,05Ah,05Ah,013h,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  05Ah,05Ah,05Ah,05Ah,015h,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  05Ah,05Ah,05Ah,05Ah,016h,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  05Ah,05Ah,05Ah,05Ah,01Fh,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  05Ah,05Ah,05Ah,05Ah,03Dh,024h,017h,014h
                DB  00Fh,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
IGN1_Lo_Extended:       DB  00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch,00Ch
                DB  068h,068h,068h,065h,055h,03Bh,027h,025h
                DB  020h,01Dh,01Dh,01Dh,01Dh,01Dh,01Dh,01Dh
                DB  01Dh,01Dh,01Dh,01Dh,01Dh,01Dh,01Dh,01Dh
                DB  07Ch,07Bh,077h,071h,055h,047h,032h,030h
                DB  02Dh,02Ah,02Ah,02Ah,02Ah,02Ah,02Ah,02Ah
                DB  02Ah,02Ah,02Ah,02Ah,02Ah,02Ah,02Ah,02Ah
                DB  089h,087h,083h,07Dh,059h,049h,035h,033h
                DB  030h,02Dh,02Dh,02Dh,02Dh,02Dh,02Dh,02Dh
                DB  02Dh,02Dh,02Dh,02Dh,02Dh,02Dh,02Dh,02Dh
                DB  097h,095h,08Eh,089h,066h,054h,040h,03Bh
                DB  036h,033h,033h,033h,033h,033h,033h,033h
                DB  033h,033h,033h,033h,033h,033h,033h,033h
                DB  09Eh,09Ch,099h,090h,085h,057h,045h,041h
                DB  03Dh,039h,039h,039h,039h,039h,039h,039h
                DB  039h,039h,039h,039h,039h,039h,039h,039h
                DB  0A4h,0A2h,09Dh,093h,08Ch,05Eh,04Ah,047h
                DB  042h,03Eh,03Eh,03Eh,03Eh,03Eh,03Eh,03Eh
                DB  03Eh,03Eh,03Eh,03Eh,03Eh,03Eh,03Eh,03Eh
                DB  0ABh,0A6h,09Eh,094h,089h,080h,064h,05Ch
                DB  052h,04Bh,04Bh,04Bh,04Bh,04Bh,04Bh,04Bh
                DB  04Bh,04Bh,04Bh,04Bh,04Bh,04Bh,04Bh,04Bh
                DB  0ABh,0A7h,09Fh,095h,08Ch,084h,06Fh,062h
                DB  05Bh,053h,053h,053h,053h,053h,053h,053h
                DB  053h,053h,053h,053h,053h,053h,053h,053h
                DB  0ABh,0A8h,0A0h,097h,091h,08Bh,083h,06Eh
                DB  06Bh,063h,063h,063h,063h,063h,063h,063h
                DB  063h,063h,063h,063h,063h,063h,063h,063h
                DB  0ABh,0A9h,0A5h,0A0h,096h,096h,088h,082h
                DB  082h,07Ah,07Ah,07Ah,07Ah,07Ah,07Ah,07Ah
                DB  07Ah,07Ah,07Ah,07Ah,07Ah,07Ah,07Ah,07Ah
                DB  0ABh,0ABh,0ABh,0ABh,0A6h,09Fh,093h,089h
                DB  086h,082h,082h,082h,082h,082h,082h,082h
                DB  082h,082h,082h,082h,082h,082h,082h,082h
                DB  0ABh,0ABh,0ABh,0ABh,0ABh,0A5h,099h,08Dh
                DB  086h,082h,082h,082h,082h,082h,082h,082h
                DB  082h,082h,082h,082h,082h,082h,082h,082h
                DB  0ABh,0ABh,0ABh,0ABh,0ABh,0ABh,09Eh,096h
                DB  089h,085h,085h,085h,085h,085h,085h,085h
                DB  085h,085h,085h,085h,085h,085h,085h,085h
                DB  0ABh,0ABh,0ABh,0ABh,0ABh,0ABh,09Eh,099h
                DB  08Dh,089h,089h,089h,089h,089h,089h,089h
                DB  089h,089h,089h,089h,089h,089h,089h,089h
                DB  0ABh,0ABh,0ABh,0ABh,0ABh,0ABh,09Eh,099h
                DB  08Dh,089h,089h,089h,089h,089h,089h,089h
                DB  089h,089h,089h,089h,089h,089h,089h,089h

;--------------------------------------------------------------------------------------------
; IgnMap_Hi  @0x746A
;   VALIDATED: X1 at 0x0B49, 480 B = 24x20. == HTS115 IGN1_Hi.
;--------------------------------------------------------------------------------------------
IgnMap_Hi:       DB  05Ah,05Ah,05Ah,05Ah,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h,000h,0A7h,0A7h,0A0h,097h,090h,090h
                DB  070h,068h,058h,054h,054h,054h,054h,054h,054h,054h
                DB  054h,054h,054h,054h,054h,054h,054h,054h,0A7h,0A7h
                DB  0A5h,09Fh,096h,096h,078h,06Fh,068h,063h,063h,063h
                DB  063h,063h,063h,063h,063h,063h,063h,063h,063h,063h
                DB  063h,063h,0A7h,0A7h,0A7h,0A1h,09Bh,093h,093h,07Bh
                DB  075h,071h,071h,071h,071h,071h,071h,071h,071h,071h
                DB  071h,071h,071h,071h,071h,071h,0A7h,0A7h,0A7h,0A1h
                DB  09Dh,096h,096h,085h,073h,06Eh,06Eh,06Eh,06Eh,06Eh
                DB  06Eh,06Eh,06Eh,06Eh,06Eh,06Eh,06Eh,06Eh,06Eh,06Eh
                DB  0A7h,0A7h,0A7h,0A1h,09Eh,099h,099h,08Eh,073h,06Dh
                DB  06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh,06Dh
                DB  06Dh,06Dh,06Dh,06Dh,0A7h,0A7h,0A7h,0A1h,09Eh,09Ch
                DB  09Ch,099h,084h,07Dh,07Dh,07Dh,07Dh,07Dh,07Dh,07Dh
                DB  07Dh,07Dh,07Dh,07Dh,07Dh,07Dh,07Dh,07Dh,0A7h,0A7h
                DB  0A7h,0A1h,09Eh,09Ch,09Ch,099h,088h,081h,081h,081h
                DB  081h,081h,081h,081h,081h,081h,081h,081h,081h,081h
                DB  081h,081h,0A7h,0A7h,0A7h,0A1h,09Eh,09Ch,09Ch,09Ch
                DB  08Bh,083h,083h,083h,083h,083h,083h,083h,083h,083h
                DB  083h,083h,083h,083h,083h,083h,0A7h,0A7h,0A7h,0A1h
                DB  09Eh,09Ch,09Ah,07Dh,078h,075h,075h,075h,075h,075h
                DB  075h,075h,075h,075h,075h,075h,075h,075h,075h,075h
                DB  0A7h,0A7h,0A7h,0A1h,09Eh,09Ch,094h,089h,076h,076h
                DB  076h,076h,076h,076h,076h,076h,076h,076h,076h,076h
                DB  076h,076h,076h,076h,0A7h,0A7h,0A7h,0A1h,09Eh,09Ch
                DB  09Ch,095h,084h,07Ch,07Ch,07Ch,07Ch,07Ch,07Ch,07Ch
                DB  07Ch,07Ch,07Ch,07Ch,07Ch,07Ch,07Ch,07Ch,0A7h,0A7h
                DB  0A7h,0A1h,09Eh,09Ch,09Ch,099h,085h,080h,080h,080h
                DB  080h,080h,080h,080h,080h,080h,080h,080h,080h,080h
                DB  080h,080h,0A7h,0A7h,0A7h,0A1h,09Eh,09Ch,09Ch,099h
                DB  093h,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,08Eh
                DB  08Eh,08Eh,08Eh,08Eh,08Eh,08Eh,0A7h,0A7h,0A7h,0A1h
                DB  09Eh,09Ch,09Ch,099h,094h,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  0A7h,0A7h,0A7h,0A1h,09Eh,09Ch,09Ch,099h,094h,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,0A7h,0A7h,0A7h,0A1h,09Eh,09Ch
                DB  09Ch,099h,094h,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,0A7h,0A7h
                DB  0A7h,0A1h,09Eh,09Ch,09Ch,099h,094h,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,0A7h,0A7h,0A7h,0A1h,09Eh,09Ch,09Ch,099h
                DB  094h,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,0A7h,0A7h,0A7h,0A1h
                DB  09Eh,09Ch,09Ch,099h,094h,08Fh,08Fh,08Fh,08Fh,08Fh
                DB  08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh,08Fh
inj_accum2_zero_add_ram1ba:     ADD     A, off(001bah)
                CMP     A, #00100h
                JGE     inj_accum2_zero_store_ram1ba
                CLR     A
inj_accum2_zero_store_ram1ba:     ST      A, off(001bah)
                CLR     A
                J       inj_accum_store_114
inj_accum_check4_add_ram1b8:     ADD     A, off(001b8h)
                CMP     A, #00100h
                JGE     inj_accum_check4_store_ram1b8
                CLR     A
inj_accum_check4_store_ram1b8:     ST      A, off(001b8h)
                J       inj_accum2_zero2
crank_pswl4_store_cmp_r0:     CMPB    A, r0
                JLE     crank_pswl4_store_goto
                LB      A, [DP]
                ADDB    A, #001h
                CMPB    A, r0
                JLE     crank_pswl4_store_goto
                J       crank_pswl4_store_if_ram117_bit0_clr
crank_pswl4_store_goto:     J       crank_mul_alt_mul
timer2_irq_clear_or_irq:     ORB     off(IRQ), #008h
                RB      TRNSIT.0
                JEQ     timer2_irq_clear_reti
                SB      09fh.2
timer2_irq_clear_reti:     RTI

;--------------------------------------------------------------------------------------------
; diag_report_finalize  @0x7681
;   TRACED: writes into the diagnostic-snapshot RAM area (0x3AC/0x3D4, adjacent to
;   cfgvariant_snapshot_capture's own 0x340 block), gated by off(120h).2 and off(122h).1, and
;   hands off to fuelmap_do_lookup_b35. A second stage of the diagnostic/serial report
;   construction.
;--------------------------------------------------------------------------------------------
diag_report_finalize:     JBR     off(00122h).1, diag_report_finalize_ptr_3d4
                CLR     A
diag_report_finalize_ptr_3d4:     MOV     DP, #003d4h
                ST      A, [DP]
                MOV     DP, #003ach
                J       diag_report_finalize_store_ind
crank_tooth_count_set_ram120_bit2:     SB      off(00120h).2
                RB      PSWH.0
                MOVB    off(001b6h), #077h
                MOVB    off(001beh), #011h
                SB      PSWH.0
                J       crank_cycle_dispatch2
threshold_bank_217_0_test_rama0_bit6:     MB      C, 0a0h.6
                JBR     off(00227h).5, threshold_bank_217_0_goto
                MOVB    r2, off(00236h)
                MB      C, 0a0h.7
threshold_bank_217_0_goto:     J       threshold_bank_217_0_carry_to_pswl_bit4
flag_dispatch_21d_212:     JBS     off(00227h).5, flag_dispatch_21d_212_goto_ignmap_2d
                JBS     off(0021fh).1, flag_dispatch_21d_212_goto_ignmap_2d
                J       flag_dispatch_21d_212_set_r3
flag_dispatch_21d_212_goto_ignmap_2d:     J       ignmap_2d_lookup
diag_mode_code_store_clr_carry:     RC
                LCB     A, CFG_flag_227_5
                JNE     diag_mode_code_store_goto
                J       diag_mode_code_store_ptr_3bf
diag_mode_code_store_goto:     J       diag_mode_code_store_rol_r0_2
boot_completion_helper_clr_carry:     RC
                LCB     A, idle_init_start_const
                STB     A, r0
                JNE     boot_completion_helper_carry_to_bit5
                LCB     A, CFG_flag_227_5
                JEQ     boot_completion_helper_carry_to_bit5
                SLLB    r1
                SLLB    r1
                MOVB    r1, #080h
boot_completion_helper_carry_to_bit5:     MB      off(00227h).5, C
                MOV     DP, #003c7h
                J       boot_completion_helper_load_ind
boot_completion_helper_rom_load_CFG:     LCB     A, CFG_flag_227_5
                JEQ     boot_completion_helper_goto
                SLLB    r2
                MOVB    r2, #080h
                RORB    r2
boot_completion_helper_goto:     J       boot_completion_helper_load_r2
crankfuel_timer_wait_shl_er0:     SLL     er0
                RB      off(00122h).0
                J       crankfuel_timer_wait_branch
sensor_check_vcal3_if_ram217_bit5_set:     JBS     off(00217h).5, sensor_check_vcal3_set_ram2be
                JBS     off(00230h).5, sensor_check_vcal3_goto_sensor_check
                J       sensor_check_vcal3_cmp_ram236
sensor_check_vcal3_set_ram2be:     MOVB    off(002beh), #064h
sensor_check_vcal3_goto_sensor_check:     J       sensor_check_clear
prep_lowpower_seq_store_tmr1:     ST      A, TMR1
                SLL     er0
                DIV
                DIV
                J       prep_lowpower_seq_test_ram9f_bit1
int_serial_rx_BRG_if_ram112_bit7_set:     JBS     off(00112h).7, int_serial_rx_BRG_set_ram120_bit4_2
                J       int_serial_rx_BRG_clr_irqh_bit7
int_serial_rx_BRG_set_ram120_bit4_2:     SB      off(00120h).4
                J       crank_sync_retry_check
table_select_6221_57fb_alt2:     JBS     off(00214h).5, table_select_6221_goto_knockwindow_2
                MB      C, P1.6
                J       table_select_6221_branch
table_select_6221_goto_knockwindow_2:     J       knockwindow_clear
crank_cycle_p4_gate_if_ram121_bit1_clr:     JBR     off(00121h).1, crank_cycle_p4_gate_goto_crank_cycle_f4
                JBS     off(00112h).2, crank_cycle_p4_gate_if_ram118_bit0_set
                JBR     off(00112h).4, crank_cycle_p4_gate_goto
crank_cycle_p4_gate_if_ram118_bit0_set:     JBS     off(00118h).0, crank_cycle_p4_gate_goto_crank_cycle
crank_cycle_p4_gate_goto:     J       crank_cycle_result_b_shr_a
crank_cycle_p4_gate_goto_crank_cycle:     J       crank_cycle_result_a
crank_cycle_p4_gate_goto_crank_cycle_f4:     J       crank_cycle_f4_check
idle_target_final_call_stub_or_short:     CAL     stub_or_short_helper
                VCAL    6
                CLR     A
                JBS     off(00212h).2, idle_target_final_load_2000
                JBR     off(00212h).4, idle_target_final_goto_idle_output_vcal5
idle_target_final_load_2000:     L       A, #02000h
idle_target_final_goto_idle_output_vcal5:     J       idle_output_vcal5
ignition_timing_calc_load_ram2cf:     LB      A, off(002cfh)
                JEQ     ignition_timing_calc_set_ram222_bit6
                J       ignition_timing_calc_load_ram29f_2
ignition_timing_calc_set_ram222_bit6:     SB      off(00222h).6
                JEQ     ignition_timing_calc_ptr_316
                J       ignition_timing_calc_load_ram29f
ignition_timing_calc_ptr_316:     MOV     DP, #00316h
                JBS     off(0022fh).7, ignition_timing_calc_load_ind_2
                MOV     DP, #00318h
ignition_timing_calc_load_ind_2:     L       A, [DP]
                ST      A, off(0029ah)
                J       ignition_timing_calc_branch_6
ignition_timing_calc_clr_ram22f_bit2_2:     RB      off(0022fh).2
                RB      off(0022fh).1
                J       ignition_timing_calc_store_ram298
ignition_timing_calc_load_ind_3:     L       A, [DP]
                SJ      ignition_timing_calc_cmp_3ff_2
ignition_timing_calc_branch_9:     JLT     ignition_timing_calc_load_3ff_2
ignition_timing_calc_cmp_3ff_2:     CMP     A, #003ffh
                JLT     ignition_timing_calc_goto_10
ignition_timing_calc_load_3ff_2:     L       A, #003ffh
ignition_timing_calc_goto_10:     J       ignition_timing_calc_goto_7
ignition_timing_calc_shl_a:     SLL     A
                JLT     ignition_timing_calc_goto_11
                SLL     A
                JGE     ignition_timing_calc_goto_12
ignition_timing_calc_goto_11:     J       ignition_timing_calc_load_ffff
ignition_timing_calc_goto_12:     J       ignition_timing_calc_set_r1
ignition_timing_calc_branch_10:     JGE     ignition_timing_calc_clear_r0_2
                MOVB    r1, #0ffh
ignition_timing_calc_clear_r0_2:     CLRB    r0
                L       A, [DP]
                J       ignition_timing_calc_mul_3
ignition_timing_calc_shl_a_2:     SLL     A
                L       A, er1
                ROL     A
                CAL     clamp_0_3ff_simple
                J       ignition_timing_calc_if_ram22f_bit2_set
ignition_timing_calc_cmp_3ff_3:     CMP     A, #003ffh
                JGE     ignition_timing_calc_goto_13
                J       ignition_timing_calc_cmp_3ff
ignition_timing_calc_goto_13:     J       ignition_timing_calc_load_3ff
ignition_timing_calc_clr_ram22f_bit1:     RB      off(0022fh).1
ignition_timing_calc_clr_ram222_bit6:     RB      off(00222h).6
ignition_timing_calc_store_ram298:     ST      A, off(00298h)
                J       ignition_timing_calc_cmp_23
ignition_timing_calc_clr_ram22f_bit2_3:     RB      off(0022fh).2
                SJ      ignition_timing_calc_clr_ram222_bit6

;--------------------------------------------------------------------------------------------
; clamp_0_3ff_simple  @0x77C7
;   VERIFIED: clamps A to [0, 0x3FF] using a simpler direct-compare form than
;   clamp_0_to_3ff (no register-pair bound source, just two fixed compares).
;--------------------------------------------------------------------------------------------
clamp_0_3ff_simple:     JLT     clamp_0_3ff_simple_load_3ff
                CMP     A, #003ffh
                JLT     clamp_0_3ff_simple_return
clamp_0_3ff_simple_load_3ff:     L       A, #003ffh
clamp_0_3ff_simple_return:     RT

;--------------------------------------------------------------------------------------------
; cfg_selector3_dispatch  @0x77D2
;   TRACED: tests off(217h).6 (CFG_Selector3, the CONFIG 0x6015 feature flag from the
;   differences report), then a further threshold compare against RAM 0x280, dispatching
;   to one of three targets. Falls through into small constant lookup tables (0x77E5)
;   immediately after.
;--------------------------------------------------------------------------------------------
cfg_selector3_dispatch:     JBS     off(00217h).6, cfg_selector3_dispatch_goto_4
                CMP     off(00280h), #08000h
                JGE     cfg_selector3_dispatch_goto_3
                J       cfg_selector3_dispatch_goto
cfg_selector3_dispatch_goto_3:     J       cfg_selector3_dispatch_cmp_r1
cfg_selector3_dispatch_goto_4:     J       cfg_selector3_dispatch_goto_idle_ectvs
                DB  043h,000h,043h,000h,043h,000h,043h,000h
                DB  030h,000h,043h,000h,043h,000h,043h,000h
                DB  043h,000h,043h,000h,030h,000h,043h,000h
                DB  07Ch,003h,035h,004h,0EAh,003h,09Ch,002h
                DB  080h,000h,09Ch,002h,07Ch,003h,05Ah,004h
                DB  05Ah,004h,05Ah,004h,080h,000h,05Ah,004h
o2_trim_result_check_load_acch:     LB      A, ACCH
                JBS     off(0011eh).4, o2_trim_result_check_goto
                LB      A, #004h
o2_trim_result_check_goto:     J       o2_trim_result_check_inc_dp
o2_trim_rpm_alt_check_ptr_5:     MOV     X1, #00005h
                JBR     off(0011eh).4, o2_trim_rpm_alt_check_goto_o2_trim_rate
                JBS     off(00118h).0, o2_trim_rpm_alt_check_goto_o2_trim_bank
                J       o2_trim_rpm_alt_check_load_stk
o2_trim_rpm_alt_check_goto_o2_trim_bank:     J       o2_trim_bank_index_alt
o2_trim_rpm_alt_check_goto_o2_trim_rate:     J       o2_trim_rate_table_select
coldstart_full_reset_clr_ram221_bit7:     RB      off(00221h).7
                SB      (0011eh-00180h)[USP].4
                SB      off(0021eh).4
                J       coldstart_full_reset_or_tcon3
idle_state_defaults_if_ram219_bit0_clr:     JBR     off(00219h).0, idle_state_defaults_goto_idle_stage_b7
                JBR     off(0021eh).4, idle_state_defaults_goto
                J       idle_state_defaults_load_stk
idle_state_defaults_goto_idle_stage_b7:     J       idle_stage_b7_store
idle_state_defaults_goto:     J       idle_stage_c0_load_clr_ram219_bit0
purge_counter_check:     JBR     off(00218h).0, purge_counter_check_cmp_stk
                JBR     off(0021eh).4, purge_counter_check_goto_purge_result
purge_counter_check_cmp_stk:     CMP     (001b4h-00180h)[USP], #005dch
                J       purge_counter_check_branch
purge_counter_check_goto_purge_result:     J       purge_result_clear
table_select_6221_if_ram217_bit3_set:     JBS     off(00217h).3, table_select_6221_cmp_tbl_idle_pi_clamp
                JBS     off(0021eh).4, table_select_6221_goto_knockwindow_3
table_select_6221_cmp_tbl_idle_pi_clamp:     CMP     A, #06000h
                J       table_select_6221_branch_2
table_select_6221_goto_knockwindow_3:     J       knockwindow_clear
crank_tooth_counter_if_ram113_bit0_set:     JBS     off(00113h).0, crank_tooth_counter_clr_ram11d_bit6
                J       crank_tooth_counter_clr_ram9f_bit2
crank_tooth_counter_clr_ram11d_bit6:     RB      off(0011dh).6
                J       crank_tooth_seq_check
tps_hysteresis_reentry_if_ram116_bit3:     JBR     off(00116h).3, tps_hysteresis_reentry_goto_postig_gate
                JBS     off(00111h).5, tps_hysteresis_reentry_goto_postig
tps_hysteresis_reentry_goto_postig_gate:     J       postig_gate_chain2
tps_hysteresis_reentry_goto_postig:     J       postig_result_default
cfgvariant_check_v5_cmp_r7:     CMPB    r7, #015h
                JNE     cfgvariant_check_v5_goto
                J       cfgvariant_check_v5_inc_r0
cfgvariant_check_v5_goto:     J       cfgvariant_check_v5_goto_cfgvariant
cfgvariant_check_v1e_cmp_r7:     CMPB    r7, #016h
                JNE     cfgvariant_check_v1e_goto
                J       cfgvariant_check_v1e_inc_r0
cfgvariant_check_v1e_goto:     J       cfgvariant_check_v1e_goto_cfgvariant
knockretard2_clamp_cmp_stk:     CMPB    (001cah-00180h)[USP], #003h
                JNE     knockretard2_clamp_goto_3
                LB      A, #000h
                CMPB    coolantTempByte, #028h
                JGE     knockretard2_clamp_goto_3
                J       knockretard2_clamp_load_1d
knockretard2_clamp_goto_3:     J       knockretard2_clamp_store_ram23b

;--------------------------------------------------------------------------------------------
; multiway_condition_apply1  @0x78AE
;   VERIFIED: consumes the off(2FFh) selector bits built by multiway_condition_select,
;   looks up via VCAL 0 (table_interp_lookup) against off(2FEh), applies a signed offset
;   and clamps to 0xFF00 ceiling. First of two apply stages over MultiwayApply1Table0/1
;   (and table_result_sign_data).
;--------------------------------------------------------------------------------------------
multiway_condition_apply1:     MOV     er2, ACC
                LB      A, off(002feh)
                VCAL    0
                SUBB    A, #080h
                EXTND
                ADD     A, er2
                CMP     A, #0ff00h
                JLT     multiway_condition_load_acc
                CLR     A
multiway_condition_load_acc:     LB      A, ACC
                RT

;--------------------------------------------------------------------------------------------
; table_result_sign_clamp  @0x78C1
;   TRACED: tests RAM off(244h) against the multiway selector bit off(2FFh).5, and
;   clamps/zeroes A depending on sign - a small guard feeding into the
;   multiway_condition_apply1 pipeline (0x78AE sits immediately after this in ROM).
;--------------------------------------------------------------------------------------------
table_result_sign_clamp:     LB      A, #000h
                JEQ     table_result_sign_load_ram244
                CLR     er3
                CMPB    A, #0ffh
                CLR     A
                JLT     table_result_sign_load_ram244
                LB      A, #05ah
                SJ      table_result_sign_goto
table_result_sign_load_ram244:     LB      A, off(00244h)
                MB      C, off(002ffh).5
                JGE     table_result_sign_set_x2
                SUBB    A, #000h
                JGE     table_result_sign_set_x2
                CLRB    A
table_result_sign_set_x2:     MOV     X2, er3
                JBR     off(002ffh).1, table_result_sign_if_ram2ff_bit2_clr
                MOV     X1, #MultiwayApply1Table0
                SCAL    multiway_condition_apply1
table_result_sign_if_ram2ff_bit2_clr:     JBR     off(002ffh).2, table_result_sign_if_ram2ff_bit3_clr
                MOV     X1, #MultiwayApply1Table1
                SCAL    multiway_condition_apply1
table_result_sign_if_ram2ff_bit3_clr:     JBR     off(002ffh).3, table_result_sign_set_er3
                MOV     X1, #table_result_sign_data
                SCAL    multiway_condition_apply1
table_result_sign_set_er3:     MOV     er3, X2
table_result_sign_goto:     J       table_result_sign_store_r0
multiway_condition_load_55a0:     L       A, #055a0h
                ST      A, er2
                JNE     multiway_condition_load_r4
                LB      A, off(0024fh)
                EXTND
                MOV     X1, A
                L       A, #00000h
                JEQ     multiway_condition_rom_load_dat_table
                MOV     DP, A
                L       A, #00000h
                ST      A, er1
                LB      A, [DP]
                XORB    A, r2
                ANDB    A, r3
                JEQ     multiway_condition_rom_load_dat_table
                ADD     X1, #00005h
multiway_condition_rom_load_dat_table:     LCB     A, multiway_condition_const_2[X1]
                STB     A, r4
                LCB     A, multiway_condition_const[X1]
                MOV     X1, #multiway_condition_interp_tbl
                VCAL    0
                STB     A, r5
multiway_condition_load_r4:     LB      A, r4
                CMPB    A, 0a3h
                JLT     multiway_apply1_final_scale
multiway_apply1_final_load_ff:     LB      A, #0ffh
multiway_apply1_final_store_ramdf:     STB     A, 0dfh
                RT

;--------------------------------------------------------------------------------------------
; multiway_apply1_final_scale  @0x7932
;   TRACED: reads RAM 0xC0 (unnamed byte) as an axis into MultiwayApply1Table1 (0x7C36)
;   via VCAL 0, subtracts 0x80 and adds r5, then applies a further IAT-gated (off 217h.4)
;   scale using RAM 0xAC. The final scaling stage of the multiway_condition_apply1
;   pipeline, in the free-space-adjacent tail of the ROM (0x7815-0x799E, part of the "code
;   in the data region" noted in the differences report).
;--------------------------------------------------------------------------------------------
multiway_apply1_final_scale:     LB      A, 0c0h
                MOV     X1, #multiway_apply1_final_interp_tbl
                VCAL    0
                SUBB    A, #080h
                ADDB    A, r5
                JGE     multiway_apply1_final_store_ramdf
                SJ      multiway_apply1_final_load_ff
loadindex_lookup_done:     MB      0a0h.6, C
                CLR     A
                JBS     off(00217h).4, loadindex_lookup_done_store_ram2fe
                MOV     er2, 0ach
                MOV     er0, #0aa00h
                DIV
                SLL     A
                LB      A, r1
                RORB    A
                JNE     loadindex_lookup_done_load_ff
                SLLB    A
                LB      A, r0
                JNE     loadindex_lookup_done_store_ram2fe
                LB      A, #001h
                SJ      loadindex_lookup_done_store_ram2fe
loadindex_lookup_done_load_ff:     LB      A, #0ffh
loadindex_lookup_done_store_ram2fe:     ST      A, off(002feh)
                LB      A, 0a3h
                STB     A, (001a1h-00180h)[USP]
                MOV     X1, #loadindex_lookup_done_interp_tbl
                VCAL    2
                STB     A, r2
                LB      A, #000h
                JEQ     loadindex_lookup_done_load_r2
                LB      A, 0b9h
                CMPCB   A, loadindex_lookup_done_const
                JLT     loadindex_lookup_done_load_stk
                MOV     X1, #loadindex_lookup_done_interp_tbl_3
                VCAL    2
                SJ      loadindex_lookup_done_store_stk
loadindex_lookup_done_load_stk:     LB      A, (001a1h-00180h)[USP]
                MOV     X1, #loadindex_lookup_done_interp_tbl_2
                VCAL    2
loadindex_lookup_done_store_stk:     STB     A, (001a1h-00180h)[USP]
loadindex_lookup_done_load_r2:     LB      A, r2
                J       loadindex_lookup_done_load_acc
                DB  000h
ve_and_accel_calc_call_table2d_lookup:     CAL     table2d_lookup_interp
                MOV     X1, #ve_and_accel_calc_interp_tbl
                LB      A, r4
                VCAL    0
                MOV     er0, #0bc76h
                CMPB    A, r1
                JLT     ve_and_accel_calc_cmp_r0
                LB      A, r1
ve_and_accel_calc_cmp_r0:     CMPB    A, r0
                JGT     ve_and_accel_calc_store_rame6
                LB      A, r0
ve_and_accel_calc_store_rame6:     STB     A, 0e6h
                J       ve_and_accel_calc_load_80
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
                DB  0FFh,0FFh,0FFh
multiway_condition_interp_tbl:       DB  06Eh,07Eh,050h,06Fh,04Ah,067h,03Fh,05Fh
                DB  037h,057h,031h,04Fh,02Bh,047h,025h,03Fh
                DB  01Dh,02Fh,018h,020h,000h
multiway_condition_const:       DB  000h,000h,000h,000h,000h,000h,000h,000h,000h,000h
multiway_condition_const_2:       DB  000h,000h,000h,000h,000h,000h,000h,000h
                DB  000h,000h,000h
multiway_apply1_final_interp_tbl:       DB  0FFh,07Dh,0C0h,07Eh,080h,080h,040h,082h,000h,083h

;--------------------------------------------------------------------------------------------
; VEMap_Lo  @0x7C40
;   VALIDATED: X1 at 0x169A, 480 B = 24x20. NO HTS115 EQUIVALENT - HTS115 has only VEhi.
;--------------------------------------------------------------------------------------------
VEMap_Lo:       DB  082h,082h,082h,082h,085h,089h,089h,091h,091h,091h
                DB  091h,093h,097h,097h,097h,098h,098h,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h,085h,089h
                DB  089h,091h,091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h
                DB  082h,082h,085h,089h,089h,091h,091h,091h,091h,093h
                DB  097h,097h,097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h,098h,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h
                DB  085h,089h,089h,091h,091h,091h,091h,093h,097h,097h
                DB  097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h,091h,091h
                DB  091h,093h,097h,097h,097h,098h,098h,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h,085h,089h
                DB  089h,091h,091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h
                DB  082h,082h,085h,089h,089h,091h,091h,091h,091h,093h
                DB  097h,097h,097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h,098h,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h
                DB  085h,089h,089h,091h,091h,091h,091h,093h,097h,097h
                DB  097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h,091h,091h
                DB  091h,093h,097h,097h,097h,098h,098h,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h,085h,089h
                DB  089h,091h,091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h
                DB  082h,082h,085h,089h,089h,091h,091h,091h,091h,093h
                DB  097h,097h,097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h,098h,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h
                DB  085h,089h,089h,091h,091h,091h,091h,093h,097h,097h
                DB  097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h,091h,091h
                DB  091h,093h,097h,097h,097h,098h,098h,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h,085h,089h
                DB  089h,091h,091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h
                DB  082h,082h,085h,089h,089h,091h,091h,091h,091h,093h
                DB  097h,097h,097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  09Ah,09Ah,082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h,098h,09Ah
                DB  09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,082h,082h,082h,082h
                DB  085h,089h,089h,091h,091h,091h,091h,093h,097h,097h
                DB  097h,098h,098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah

;--------------------------------------------------------------------------------------------
; VEMap_Hi  @0x7E20
;   VALIDATED: X1 at 0x1686, 480 B = 24x20. == HTS115 VEhi (0x7E0F).
;--------------------------------------------------------------------------------------------
VEMap_Hi:       DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,091h
                DB  091h,091h,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Fh
                DB  08Fh,08Fh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Fh
                DB  08Fh,08Fh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Fh
                DB  08Fh,08Fh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah
                DB  082h,082h,082h,082h,085h,089h,089h,08Bh
                DB  08Bh,08Bh,091h,093h,097h,097h,097h,098h
                DB  098h,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah,09Ah

